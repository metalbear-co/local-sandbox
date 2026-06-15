#!/bin/bash
#
# Test that a running mirrord SQS-splitting session survives an operator change.
#
# It covers two operator changes, both while one session stays connected:
#   upgrade  - start under an OLD released operator, then swap in the local build
#              mid-session (the real cross-version upgrade). This is the only way
#              to check that a new operator takes over a split an old operator set up.
#   restart  - start under the local build, then replace the operator pod in place
#              (same build). This checks plain recovery from persisted state.
#
# The session is driven by an old-style MirrordWorkloadQueueRegistry only (no
# MirrordSplitConfig). A correct operator reads that registry read-only and never
# writes a converted MirrordSplitConfig/MirrordPropertyList for it - the script
# asserts that nothing gets persisted.
#
# Usage (normally via `task sqs:test:live-upgrade`):
#   MODE=both|upgrade|restart   which scenarios to run (default: both)
#   OLD_VERSION=3.165.0         released operator for the upgrade scenario
#                               (default: newest cached version that is not local)
#   RESTORE_TAG=latest          saved local build tag to swap back to (default: latest)
#
# Region note: the operator pod has no AWS_REGION, so its SQS client uses the AWS
# default us-east-1. mirrord copies the target pod's env into the local process, so
# the consumer must use us-east-1 too or it waits forever for a temp queue in the
# wrong region. The script pins everything to us-east-1, matching test-sqs-reconnect.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
OPERATOR_DIR="$SANDBOX_DIR/../operator"
VERSIONS_DIR="$SANDBOX_DIR/.versions"
APPS_DIR="$SANDBOX_DIR/apps/sqs-consumer"
CONFIG="$SANDBOX_DIR/k8s/overlays/sqs-localstack/mirrord.json"

NS="test-mirrord"
QUEUE_NAME_REAL="TestQueue"
QUEUE_URL="http://localhost:4566/000000000000/$QUEUE_NAME_REAL"
SOURCE_REGION="us-east-1"
FILTER_TENANT="Avi.Test"      # matches the mirrord.json filter ^Avi\.
PLAIN_TENANT="Basic"          # does not match -> stays in cluster

MIRRORD_BIN="${MIRRORD_BIN:-$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord}"
MODE="${MODE:-both}"
OLD_VERSION="${OLD_VERSION:-}"
RESTORE_TAG="${RESTORE_TAG:-latest}"
RELEASE_LICENSE_KEY="${RELEASE_LICENSE_KEY:-}"

UPGRADE_RESULT="skipped"
RESTART_RESULT="skipped"
SESSION_LOG="/tmp/live-upgrade-session.log"

note()  { echo "[live-upgrade] $*"; }
fail()  { echo "[live-upgrade] FAIL: $*" >&2; }
hr()    { echo "------------------------------------------------------------"; }

local_chart_version() {
  grep "appVersion:" "$OPERATOR_DIR/public/charts/mirrord-operator/Chart.yaml" \
    | awk '{print $2}' | tr -d '"'
}

cached_versions() {
  ls "$VERSIONS_DIR/operator/"*.tar 2>/dev/null \
    | xargs -n1 basename 2>/dev/null | sed 's/\.tar$//'
}

# Preflight checks. Each missing prerequisite prints exactly what to run, then we exit.
preflight() {
  local ok=1
  hr; note "Preflight checks"; hr

  if ! command -v kubectl >/dev/null 2>&1; then
    fail "kubectl not found on PATH"; ok=0
  elif ! kubectl get ns >/dev/null 2>&1; then
    fail "cannot reach a cluster."
    echo "       -> start your sandbox cluster and select its context, e.g.:"
    echo "          minikube start -p bearkube   (or: kubectl config use-context bearkube)"
    ok=0
  else
    note "cluster reachable, context: $(kubectl config current-context)"
  fi

  if [ ! -x "$MIRRORD_BIN" ]; then
    fail "mirrord CLI not found at: $MIRRORD_BIN"
    echo "       -> build it:   cd $SANDBOX_DIR/../mirrord && cargo build -p mirrord"
    echo "          or set MIRRORD_BIN to your binary, or 'task mirrord:use:local'."
    ok=0
  else
    note "mirrord CLI: $MIRRORD_BIN"
  fi

  for tool in go jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "$tool not found on PATH (needed to build/inspect)."; ok=0
    fi
  done

  # The local build must be saved so we can swap back to it.
  if ! docker image inspect "mirrord-operator:$RESTORE_TAG" >/dev/null 2>&1; then
    fail "local operator image 'mirrord-operator:$RESTORE_TAG' not found."
    echo "       -> build and save it first:"
    echo "          (cd $SANDBOX_DIR && task operator:update)   # build + deploy"
    echo "          (cd $SANDBOX_DIR && task operator:save TAG=$RESTORE_TAG)"
    ok=0
  else
    note "local build saved as mirrord-operator:$RESTORE_TAG"
  fi

  # The upgrade scenario needs an OLD released operator (and a license to fetch it).
  if [ "$MODE" = "both" ] || [ "$MODE" = "upgrade" ]; then
    local cached
    cached="$(cached_versions)"
    local localver
    localver="$(local_chart_version)"

    if [ -z "$OLD_VERSION" ]; then
      OLD_VERSION="$(echo "$cached" | grep -v "^${localver}$" | sort -V | tail -1)"
    fi

    if [ -z "$OLD_VERSION" ]; then
      fail "no OLD operator version available for the upgrade scenario."
      if [ -z "$cached" ]; then
        echo "       -> no versions cached under $VERSIONS_DIR/operator/."
      else
        echo "       -> cached versions: $(echo $cached | tr '\n' ' ')"
      fi
      echo "          Pick one explicitly:  task sqs:test:live-upgrade OLD_VERSION=3.165.0"
      echo "          Downloading a new one needs RELEASE_LICENSE_KEY in $SANDBOX_DIR/.env"
      echo "          (then 'task operator:use VERSION=<x>' caches it)."
      echo "          Or run only the in-place test:  task sqs:test:live-upgrade MODE=restart"
      ok=0
    elif ! ls "$VERSIONS_DIR/operator/${OLD_VERSION}.tar" >/dev/null 2>&1 && [ -z "$RELEASE_LICENSE_KEY" ]; then
      fail "OLD_VERSION=$OLD_VERSION is not cached and RELEASE_LICENSE_KEY is unset."
      echo "       -> set RELEASE_LICENSE_KEY in $SANDBOX_DIR/.env so it can be downloaded,"
      echo "          or choose a cached version: $(echo $cached | tr '\n' ' ')"
      ok=0
    else
      note "upgrade scenario will use OLD operator: $OLD_VERSION (local build is $localver)"
    fi
  fi

  hr
  if [ "$ok" -ne 1 ]; then
    fail "preflight failed - fix the items above and re-run."
    exit 1
  fi
  note "preflight OK"
}

# Bring up localstack + consumer + the legacy registry, pin region to us-east-1,
# and make sure the source queue exists there. Removes any stray real split config
# so the run is truly registry-only.
prepare_env() {
  hr; note "Preparing legacy SQS env (registry-only)"; hr

  ( cd "$SANDBOX_DIR" && task sqs:deploy:legacy ) || { fail "sqs:deploy:legacy failed"; exit 1; }

  note "building consumer"
  ( cd "$APPS_DIR" && go build -o /tmp/sqs-consumer main.go ) || { fail "consumer build failed"; exit 1; }

  note "pinning sqs-consumer deployment to $SOURCE_REGION"
  kubectl set env deployment/sqs-consumer -n "$NS" \
    AWS_REGION="$SOURCE_REGION" AWS_DEFAULT_REGION="$SOURCE_REGION" >/dev/null
  kubectl rollout status deployment/sqs-consumer -n "$NS" --timeout=120s >/dev/null \
    || { fail "consumer rollout did not complete"; exit 1; }

  note "ensuring source queue $QUEUE_NAME_REAL in $SOURCE_REGION"
  kubectl exec -n localstack deploy/localstack -- \
    awslocal sqs create-queue --queue-name "$QUEUE_NAME_REAL" --region "$SOURCE_REGION" >/dev/null 2>&1

  # Registry-only means no real MirrordSplitConfig for the target; drop a known leftover.
  if kubectl get mirrordsplitconfig sqs-test-split-config -n "$NS" >/dev/null 2>&1; then
    note "removing stray real MirrordSplitConfig 'sqs-test-split-config' (keeps the run registry-only)"
    kubectl delete mirrordsplitconfig sqs-test-split-config -n "$NS" >/dev/null 2>&1
  fi

  ( cd "$SANDBOX_DIR" && task sqs:test:split:cleanup ) >/dev/null 2>&1 || true
}

start_session() {
  rm -f "$SESSION_LOG"
  AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION="$SOURCE_REGION" \
    QUEUE_NAME=test-queue MIRRORD_CHECK_VERSION=false \
    "$MIRRORD_BIN" exec -f "$CONFIG" -- /tmp/sqs-consumer > "$SESSION_LOG" 2>&1 &
  echo $!
}

# Make sure the split actually delivers to THIS session before we start counting.
#
# When a split starts there is a short window where the in-cluster consumer still
# reads the source queue directly (until the operator patches it onto a temp
# queue), so the very first messages can be eaten by the cluster pod and look lost.
# Instead of guessing readiness from k8s state (stale pods make that unreliable),
# we probe end-to-end: keep sending a filtered warm-up message until one lands in
# the local session, then purge the source queue and let any already-forwarded
# probes drain so they do not inflate the real count.
establish_pipe() {
  local pid="$1" timeout="${2:-60}" waited=0 before last cur
  note "confirming the split delivers to this session (warm-up probe)"
  before="$(msg_count)"
  while [ "$waited" -lt "$timeout" ]; do
    kubectl exec -n localstack deploy/localstack -- \
      awslocal sqs send-message --region "$SOURCE_REGION" --queue-url "$QUEUE_URL" \
        --message-body "warmup-probe" \
        --message-attributes "{\"tenant\":{\"DataType\":\"String\",\"StringValue\":\"$FILTER_TENANT\"}}" \
        >/dev/null 2>&1
    sleep 3; waited=$((waited + 3))
    if ! kill -0 "$pid" 2>/dev/null; then fail "session died during warm-up"; return 1; fi
    if [ "$(msg_count)" -gt "$before" ]; then
      note "split pipe confirmed end-to-end after ${waited}s"
      kubectl exec -n localstack deploy/localstack -- \
        awslocal sqs purge-queue --region "$SOURCE_REGION" --queue-url "$QUEUE_URL" >/dev/null 2>&1 || true
      # Drain: wait until the received count stops rising so leftover probes do not
      # get counted against the next batch.
      last=-1; cur="$(msg_count)"
      while [ "$cur" != "$last" ]; do last="$cur"; sleep 3; cur="$(msg_count)"; done
      return 0
    fi
  done
  fail "split never delivered a warm-up message within ${timeout}s"
  tail -15 "$SESSION_LOG"; return 1
}

# Poll the session log until the consumer reports it is listening. Quiet on
# failure (no FAIL prints) so callers can retry; returns 1 on early exit, on a
# stuck NonExistentQueue, or on timeout.
poll_listening() {
  local pid="$1" timeout="${2:-50}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if grep -q "Listening for messages" "$SESSION_LOG" 2>/dev/null; then return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then return 1; fi
    if grep -q "NonExistentQueue" "$SESSION_LOG" 2>/dev/null && [ "$waited" -ge 20 ]; then
      return 1
    fi
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

# Start a session and wait until it is listening, retrying a few times. A
# freshly-rolled operator sometimes rejects the very first CLI connection while
# it is still booting, which makes the session exit immediately, so one early
# exit is not a real failure. On success sets SESSION_PID to the live process.
bring_up_session() {
  local attempt
  for attempt in 1 2 3; do
    SESSION_PID="$(start_session)"
    if poll_listening "$SESSION_PID" 50; then return 0; fi
    stop_session "$SESSION_PID"
    note "session did not come up (attempt $attempt/3); letting the operator settle"
    sleep 8
  done
  SESSION_PID=""
  tail -20 "$SESSION_LOG"
  return 1
}

msg_count() {
  # grep -c prints "0" and exits 1 on no match; capturing it keeps the result a
  # single number so the arithmetic below never sees a doubled "0\n0".
  local c
  c="$(grep -c "\[MSG #" "$SESSION_LOG" 2>/dev/null)"
  echo "${c:-0}"
}

send_msgs() {
  local count="$1" tenant="$2" label="$3" i
  for i in $(seq 1 "$count"); do
    kubectl exec -n localstack deploy/localstack -- \
      awslocal sqs send-message --region "$SOURCE_REGION" --queue-url "$QUEUE_URL" \
        --message-body "${label}-${i}" \
        --message-attributes "{\"tenant\":{\"DataType\":\"String\",\"StringValue\":\"$tenant\"}}" \
        >/dev/null 2>&1 && echo "    sent ${label}-${i} (tenant=$tenant)"
  done
}

count_split_configs() { kubectl get mirrordsplitconfig  -n "$NS" --no-headers 2>/dev/null | grep -c . ; }
count_prop_lists()     { kubectl get mirrordpropertylist -n "$NS" --no-headers 2>/dev/null | grep -c . ; }

# Assert the operator persisted nothing derived from the registry while a split is live.
assert_nothing_persisted() {
  local sc pl ok=0
  sc="$(count_split_configs)"; pl="$(count_prop_lists)"
  if [ "$sc" = "0" ] && [ "$pl" = "0" ]; then
    note "invariant OK: no MirrordSplitConfig and no MirrordPropertyList persisted from the registry"
  else
    fail "operator persisted converted resources from the registry: split_configs=$sc property_lists=$pl"
    kubectl get mirrordsplitconfig,mirrordpropertylist -n "$NS" 2>/dev/null
    ok=1
  fi
  if kubectl get mirrordworkloadqueueregistry sqs-test-registry -n "$NS" >/dev/null 2>&1; then
    note "invariant OK: legacy registry still present and untouched"
  else
    fail "legacy registry disappeared"; ok=1
  fi
  return $ok
}

# Core check: with a live session, send filtered messages and confirm THIS session
# receives all of them. The forwarder delivers in bursts and right after an
# operator change it needs a moment to re-establish, so we poll instead of
# checking once.
#
# A single message can still be lost to a competing in-cluster consumer or during
# a reconnect window, so we send in up to three rounds and resend only the
# shortfall rather than failing on the first miss. Counting is "received >= sent",
# so leftover warm-up probes or a resent message never cause a false pass/fail;
# only a real (near-total) loss across all rounds fails. Returns 0 on success.
verify_routing() {
  local pid="$1" n="${2:-3}" timeout="${3:-60}" before after round wait_for waited got deficit
  before="$(msg_count)"
  for round in 1 2 3; do
    got=$(( $(msg_count) - before ))
    deficit=$(( n - got ))
    if [ "$deficit" -le 0 ]; then break; fi
    if [ "$round" -eq 1 ]; then
      note "sending $n filtered + 1 unfiltered message"
      send_msgs "$n" "$FILTER_TENANT" "filtered"
      send_msgs 1 "$PLAIN_TENANT" "unfiltered"
      wait_for="$timeout"
    else
      note "only $got/$n arrived so far; resending $deficit filtered (round $round)"
      send_msgs "$deficit" "$FILTER_TENANT" "filtered"
      wait_for=25
    fi
    note "waiting (up to ${wait_for}s, returns as soon as they arrive) ..."
    waited=0
    while [ "$waited" -lt "$wait_for" ]; do
      sleep 1; waited=$((waited + 1))
      if ! kill -0 "$pid" 2>/dev/null; then fail "session process died"; return 1; fi
      after="$(msg_count)"
      if [ "$((after - before))" -ge "$n" ]; then
        note "routing OK: session received $((after - before)) filtered messages (sent $n) after round $round"
        return 0
      fi
    done
  done
  after="$(msg_count)"
  fail "session received only $((after - before)) of $n filtered messages after 3 rounds"
  tail -15 "$SESSION_LOG"; return 1
}

stop_session() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

scenario_upgrade() {
  hr; note "SCENARIO upgrade: OLD operator ($OLD_VERSION) -> local build, mid-session"; hr

  note "deploying OLD operator $OLD_VERSION"
  ( cd "$SANDBOX_DIR" && task operator:use VERSION="$OLD_VERSION" ) \
    || { fail "could not deploy operator $OLD_VERSION"; UPGRADE_RESULT="fail"; return; }

  prepare_env

  note "starting session under OLD operator"
  if ! bring_up_session; then
    fail "OLD operator $OLD_VERSION could not establish a working split (no baseline)."
    echo "       This is an old-operator/env issue, not a regression in the new build."
    UPGRADE_RESULT="fail"; return
  fi
  local pid="$SESSION_PID"
  note "session PID $pid"
  if ! establish_pipe "$pid"; then
    fail "OLD operator $OLD_VERSION never delivered to the session (no baseline)."
    stop_session "$pid"; UPGRADE_RESULT="fail"; return
  fi

  note "baseline routing under OLD operator"
  if ! verify_routing "$pid" 2; then stop_session "$pid"; UPGRADE_RESULT="fail"; return; fi

  note "UPGRADING to local build (TAG=$RESTORE_TAG) without stopping the session"
  # Swap the operator the way a real `helm upgrade` does: a graceful rolling
  # restart, not a force-kill + lease wipe. The harsh replacement cuts the live
  # session's connection so hard that the client reconnects as a brand-new
  # session and the running consumer is orphaned from its split queue. A graceful
  # roll lets the old pod drain and hand over leadership, so the session can
  # reconnect and the new operator recovers the in-flight split.
  ( cd "$SANDBOX_DIR" && task operator:load:graceful TAG="$RESTORE_TAG" ) \
    || { fail "operator:load:graceful TAG=$RESTORE_TAG failed"; stop_session "$pid"; UPGRADE_RESULT="fail"; return; }

  if ! kill -0 "$pid" 2>/dev/null; then
    fail "session died across the upgrade"; tail -20 "$SESSION_LOG"; UPGRADE_RESULT="fail"; return
  fi
  note "session PID $pid still alive after the upgrade"

  # The new operator needs a moment to reconnect the session and recover the
  # persisted split, so probe until delivery resumes before the strict count.
  note "waiting for the session to recover routing after the upgrade"
  if ! establish_pipe "$pid" 150; then
    fail "session did not recover routing within 150s after the upgrade"
    stop_session "$pid"; UPGRADE_RESULT="fail"; return
  fi

  note "post-upgrade routing on the SAME session"
  local rc=0
  verify_routing "$pid" 3 || rc=1
  assert_nothing_persisted || rc=1

  if kubectl logs -n mirrord -l app=mirrord-operator --tail=200 2>/dev/null \
       | grep -qiE "resume_recovered_sqs_split|adopt"; then
    note "operator log shows it recovered/adopted the in-flight split"
  fi

  stop_session "$pid"
  if [ "$rc" -eq 0 ]; then UPGRADE_RESULT="pass"; else UPGRADE_RESULT="fail"; fi
}

scenario_restart() {
  hr; note "SCENARIO restart: local build, replace operator pod in place"; hr

  note "ensuring local build (TAG=$RESTORE_TAG) is deployed"
  ( cd "$SANDBOX_DIR" && task operator:load TAG="$RESTORE_TAG" ) \
    || { fail "operator:load TAG=$RESTORE_TAG failed"; RESTART_RESULT="fail"; return; }

  prepare_env

  note "starting session under local build"
  if ! bring_up_session; then RESTART_RESULT="fail"; return; fi
  local pid="$SESSION_PID"
  note "session PID $pid"
  if ! establish_pipe "$pid"; then stop_session "$pid"; RESTART_RESULT="fail"; return; fi

  note "baseline routing"
  if ! verify_routing "$pid" 2; then stop_session "$pid"; RESTART_RESULT="fail"; return; fi

  note "RESTARTING operator pod in place (session stays connected)"
  kubectl rollout restart deployment/mirrord-operator -n mirrord >/dev/null
  kubectl rollout status deployment/mirrord-operator -n mirrord --timeout=120s >/dev/null \
    || { fail "operator did not come back Ready"; stop_session "$pid"; RESTART_RESULT="fail"; return; }

  if ! kill -0 "$pid" 2>/dev/null; then
    fail "session died across the restart"; tail -20 "$SESSION_LOG"; RESTART_RESULT="fail"; return
  fi
  note "session PID $pid still alive after the restart"

  note "waiting for the session to recover routing after the restart"
  if ! establish_pipe "$pid" 90; then
    fail "session did not recover routing within 90s after the restart"
    stop_session "$pid"; RESTART_RESULT="fail"; return
  fi

  note "post-restart routing on the SAME session"
  local rc=0
  verify_routing "$pid" 3 || rc=1
  assert_nothing_persisted || rc=1

  stop_session "$pid"
  if [ "$rc" -eq 0 ]; then RESTART_RESULT="pass"; else RESTART_RESULT="fail"; fi
}

cleanup() {
  hr; note "Cleanup"; hr
  pkill -f "/tmp/sqs-consumer" 2>/dev/null || true
  ( cd "$SANDBOX_DIR" && task sqs:test:split:cleanup ) >/dev/null 2>&1 || true
  note "restoring local build (TAG=$RESTORE_TAG)"
  ( cd "$SANDBOX_DIR" && task operator:load TAG="$RESTORE_TAG" ) >/dev/null 2>&1 || true
}

main() {
  preflight

  hr
  note "Watch the live session and operator in OTHER terminals while this runs:"
  echo "    tail -f $SESSION_LOG"
  echo "    kubectl logs -n mirrord -l app=mirrord-operator -f"
  note "The session runs in the background here; its output goes to the log above,"
  note "not to this terminal. This terminal shows step-by-step progress and the summary."
  hr

  case "$MODE" in
    both)    scenario_upgrade; scenario_restart ;;
    upgrade) scenario_upgrade ;;
    restart) scenario_restart ;;
    *) fail "unknown MODE='$MODE' (use both|upgrade|restart)"; exit 1 ;;
  esac

  cleanup

  hr; note "SUMMARY"; hr
  echo "  upgrade (old -> new):     $UPGRADE_RESULT"
  echo "  restart (in place):       $RESTART_RESULT"
  hr

  if [ "$UPGRADE_RESULT" = "fail" ] || [ "$RESTART_RESULT" = "fail" ]; then
    exit 1
  fi
}

main "$@"
