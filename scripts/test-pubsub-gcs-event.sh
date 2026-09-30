#!/usr/bin/env bash
#
# End-to-end test for GCP Pub/Sub splitting of CLOUD STORAGE NOTIFICATIONS
# (`gcs_event: "true"` in a queue's queueConfig) on the local minikube sandbox.
#
# The gcs-notifications queue (deployment/pubsub-gcs-consumer) receives Pub/Sub
# notifications for objects in the fake-gcs-server bucket `uploads`. A local
# session with jq filter `.gcsMetadata.env == "dev"` must claim exactly the
# notifications for objects whose custom metadata says env=dev:
#
#   1. JSON_API_V1 notification, object metadata env=dev
#        -> local session (metadata read from the notification payload)
#   2. JSON_API_V1 notification, object metadata env=prod
#        -> cluster consumer
#   3. NONE notification, object metadata env=dev
#        -> local session (operator reads the metadata from fake-gcs-server)
#   4. NONE notification, object metadata env=prod
#        -> cluster consumer
#   5. NONE notification for an object that does not exist
#        -> cluster consumer (no gcsMetadata, the jq filter is false)
#   6. message on the same topic that is not a Cloud Storage notification
#        -> cluster consumer
#
# Prerequisites:
#   - minikube (bearkube) running, Pub/Sub env deployed (`task pubsub:deploy`)
#     and the gcs_event queue deployed (`task pubsub:gcs:deploy`), or run with
#     DEPLOY=1 to run both
#   - the local operator from the feature branch running (`task operator:dev`);
#     a released operator does not know gcs_event, so cases 1 and 3 fail
#   - go, jq and kubectl on PATH
#
# Usage:
#   ./test-pubsub-gcs-event.sh
#   DEPLOY=1 ./test-pubsub-gcs-event.sh   # (re)deploy the Pub/Sub env and gcs_event queue first
#
# Env knobs (all optional):
#   MIRRORD_BIN       mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE         Pub/Sub overlay namespace (default test-mirrord)
#   READY_TIMEOUT     seconds to wait for the split session to go Ready (default 120)
#   DELIVERY_TIMEOUT  seconds to wait for a message to reach its consumer (default 60)
#   QUIET_PERIOD      seconds a message must stay away from the wrong consumer (default 10)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="${NAMESPACE:-test-mirrord}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
DELIVERY_TIMEOUT="${DELIVERY_TIMEOUT:-60}"
QUIET_PERIOD="${QUIET_PERIOD:-10}"
DEPLOY="${DEPLOY:-0}"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

TARGET="pubsub-gcs-consumer"
EMULATOR_NAMESPACE="pubsub-emulator"
MIRRORD_CONFIG="$SANDBOX_DIR/k8s/overlays/pubsub-emulator/mirrord-gcs-event.json"
WORKDIR="$(mktemp -d /tmp/pubsub-gcs-event.XXXXXX)"
SESSION_LOG="$WORKDIR/session.log"
CONSUMER_BIN="$WORKDIR/pubsub-consumer"
SESSION_PID=""
# Object names are unique per run, so leftovers from an earlier run never
# satisfy a check. The `/` also exercises object name encoding.
RUN_ID="run-$(date +%s)"

# ---------------------------------------------------------------------------
# Output helpers - gum when installed, plain ANSI otherwise
# ---------------------------------------------------------------------------
HAVE_GUM=0
command -v gum >/dev/null 2>&1 && HAVE_GUM=1
header() {
  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border rounded --padding "0 2" --margin "1 0" --bold "$1"
  else
    printf '\n\033[1m=== %s ===\033[0m\n' "$1"
  fi
}
info() { printf '\033[0;32m[INFO]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; }
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }

FAILURES=0
RESULTS=()
record() { # record <case> <PASS|FAIL> <detail>
  RESULTS+=("$1|$2|$3")
  if [ "$2" = PASS ]; then pass "$1: $3"; else fail "$1: $3"; FAILURES=$((FAILURES + 1)); fi
}

cleanup() {
  if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
    info "mirrord session stopped"
  fi
}
trap cleanup EXIT

sandbox_task() { (cd "$SANDBOX_DIR" && task "$@"); }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Pub/Sub gcs_event e2e (Cloud Storage notifications, jq on .gcsMetadata)"

for tool in kubectl jq go task; do
  command -v "$tool" >/dev/null 2>&1 || { fail "$tool not found on PATH"; exit 1; }
done

if [ "$DEPLOY" = 1 ]; then
  info "DEPLOY=1 - deploying the Pub/Sub env and the gcs_event queue first"
  sandbox_task pubsub:deploy || { fail "task pubsub:deploy failed"; exit 1; }
  sandbox_task pubsub:gcs:deploy || { fail "task pubsub:gcs:deploy failed"; exit 1; }
fi

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
  || { fail "namespace $NAMESPACE not found - run 'task pubsub:deploy' (or DEPLOY=1)"; exit 1; }
kubectl rollout status deployment/pubsub-emulator -n "$EMULATOR_NAMESPACE" --timeout=5s >/dev/null 2>&1 \
  || { fail "the Pub/Sub emulator is not running - run 'task pubsub:deploy' (or DEPLOY=1)"; exit 1; }
kubectl rollout status deployment/fake-gcs-server -n "$EMULATOR_NAMESPACE" --timeout=5s >/dev/null 2>&1 \
  || { fail "fake-gcs-server is not running - run 'task pubsub:gcs:deploy' (or DEPLOY=1)"; exit 1; }
kubectl get deployment -n "$NAMESPACE" "$TARGET" >/dev/null 2>&1 \
  || { fail "deployment/$TARGET not found - run 'task pubsub:gcs:deploy' (or DEPLOY=1)"; exit 1; }
queue_config=$(kubectl get mirrordsplitconfigs.queues.mirrord.metalbear.co -n "$NAMESPACE" \
  pubsub-gcs-split-config -o jsonpath='{.spec.queues[0].queueConfig}' 2>/dev/null)
[ "$queue_config" = "pubsub-gcs-event-queue-config" ] \
  || { fail "MirrordSplitConfig pubsub-gcs-split-config with a gcs_event queueConfig not found - run 'task pubsub:gcs:deploy'"; exit 1; }
kubectl get mirrordpropertylists.mirrord.metalbear.co -n "$NAMESPACE" pubsub-gcs-event-queue-config \
  -o jsonpath='{.spec.properties[?(@.name=="gcs_event")].value}' 2>/dev/null | grep -qx true \
  || { fail "queueConfig pubsub-gcs-event-queue-config does not set gcs_event: \"true\" - run 'task pubsub:gcs:deploy'"; exit 1; }

info "make sure 'task operator:dev' from the feature branch is running - a released operator ignores gcs_event"
info "mirrord CLI: $MIRRORD_BIN"
info "workdir: $WORKDIR"
info "objects of this run: gs://uploads/gcs-e2e/$RUN_ID/*"

info "building the local consumer"
(cd "$SANDBOX_DIR/apps/pubsub-consumer" && go build -o "$CONSUMER_BIN" main.go) \
  || { fail "go build of apps/pubsub-consumer failed"; exit 1; }

# ---------------------------------------------------------------------------
# Objects in fake-gcs-server
# ---------------------------------------------------------------------------
header "Uploading objects with custom metadata"
OBJ_PAYLOAD_DEV="gcs-e2e/$RUN_ID/payload-dev.csv"
OBJ_PAYLOAD_PROD="gcs-e2e/$RUN_ID/payload-prod.csv"
OBJ_FETCH_DEV="gcs-e2e/$RUN_ID/fetch-dev.csv"
OBJ_FETCH_PROD="gcs-e2e/$RUN_ID/fetch-prod.csv"
OBJ_MISSING="gcs-e2e/$RUN_ID/missing.csv"
PLAIN_TENANT="gcs-plain-$RUN_ID"

for pair in "$OBJ_PAYLOAD_DEV:dev" "$OBJ_PAYLOAD_PROD:prod" "$OBJ_FETCH_DEV:dev" "$OBJ_FETCH_PROD:prod"; do
  sandbox_task pubsub:gcs:upload OBJECT="${pair%%:*}" ENV="${pair##*:}" \
    || { fail "upload of ${pair%%:*} failed - is fake-gcs-server healthy? ('kubectl logs -n $EMULATOR_NAMESPACE deploy/fake-gcs-server')"; exit 1; }
done

# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------
header "Starting the local session (jq: .gcsMetadata.env == \"dev\")"

split_session_phases() {
  kubectl get mirrordclustersplitsessions.queues.mirrord.metalbear.co \
    -o jsonpath="{range .items[?(@.spec.target.name==\"$TARGET\")]}{.status.phase}{\"\\n\"}{end}" \
    2>/dev/null
}
if [ -n "$(split_session_phases)" ]; then
  warn "a $TARGET split session already exists - waiting for it to drain first"
  for _ in $(seq 1 60); do
    [ -z "$(split_session_phases)" ] && break
    sleep 2
  done
fi

"$MIRRORD_BIN" exec -f "$MIRRORD_CONFIG" -- "$CONSUMER_BIN" >"$SESSION_LOG" 2>&1 &
SESSION_PID=$!
info "session pid: $SESSION_PID (log: $SESSION_LOG)"

ready=1
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    fail "mirrord session died - last log lines:"
    tail -10 "$SESSION_LOG"
    break
  fi
  if split_session_phases | grep -q Ready; then
    ready=0
    break
  fi
  sleep 1
done
if [ "$ready" != 0 ]; then
  fail "the split session did not reach Ready within ${READY_TIMEOUT}s - is 'task operator:dev' serving?"
  tail -10 "$SESSION_LOG"
  exit 1
fi
info "split session Ready"

# The operator points the deployed consumer at the main output subscription,
# which restarts its pod; wait so the cluster checks read the new pod's logs.
kubectl rollout status deployment/"$TARGET" -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 \
  || warn "deployment/$TARGET did not finish rolling out - cluster checks may time out"

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
local_has() { grep -qF -- "$1" "$SESSION_LOG"; }
cluster_has() {
  kubectl logs -n "$NAMESPACE" -l app="$TARGET" --tail=-1 2>/dev/null | grep -qF -- "$1"
}

# expect_route <case> <needle> <local|cluster>
expect_route() {
  local name="$1" needle="$2" where="$3" arrived=1
  for _ in $(seq 1 "$DELIVERY_TIMEOUT"); do
    if { [ "$where" = local ] && local_has "$needle"; } \
      || { [ "$where" = cluster ] && cluster_has "$needle"; }; then
      arrived=0
      break
    fi
    sleep 1
  done
  if [ "$arrived" != 0 ]; then
    record "$name" FAIL "'$needle' did not reach the $where consumer within ${DELIVERY_TIMEOUT}s"
    return
  fi
  # A message delivered to one side must never show up on the other.
  sleep "$QUIET_PERIOD"
  if [ "$where" = cluster ] && local_has "$needle"; then
    record "$name" FAIL "'$needle' reached the cluster consumer AND the local session"
  elif [ "$where" = local ] && cluster_has "$needle"; then
    record "$name" FAIL "'$needle' reached the local session AND the cluster consumer"
  else
    record "$name" PASS "reached the $where consumer only"
  fi
}

header "1/6 JSON_API_V1, env=dev -> local"
sandbox_task pubsub:gcs:send OBJECT="$OBJ_PAYLOAD_DEV" FORMAT=JSON_API_V1
expect_route "1 JSON_API_V1 env=dev" "objectId=$OBJ_PAYLOAD_DEV" local

header "2/6 JSON_API_V1, env=prod -> cluster"
sandbox_task pubsub:gcs:send OBJECT="$OBJ_PAYLOAD_PROD" FORMAT=JSON_API_V1
expect_route "2 JSON_API_V1 env=prod" "objectId=$OBJ_PAYLOAD_PROD" cluster

header "3/6 NONE, env=dev (metadata read from fake-gcs-server) -> local"
sandbox_task pubsub:gcs:send OBJECT="$OBJ_FETCH_DEV" FORMAT=NONE
expect_route "3 NONE env=dev" "objectId=$OBJ_FETCH_DEV" local

header "4/6 NONE, env=prod (metadata read from fake-gcs-server) -> cluster"
sandbox_task pubsub:gcs:send OBJECT="$OBJ_FETCH_PROD" FORMAT=NONE
expect_route "4 NONE env=prod" "objectId=$OBJ_FETCH_PROD" cluster

header "5/6 NONE, object does not exist -> cluster"
sandbox_task pubsub:gcs:send OBJECT="$OBJ_MISSING" FORMAT=NONE
expect_route "5 NONE missing object" "objectId=$OBJ_MISSING" cluster

header "6/6 not a Cloud Storage notification -> cluster"
sandbox_task pubsub:gcs:send:plain TENANT="$PLAIN_TENANT"
expect_route "6 plain message" "tenant=$PLAIN_TENANT" cluster

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
header "Result"
if [ "$HAVE_GUM" = 1 ]; then
  {
    echo "case,verdict,detail"
    for row in "${RESULTS[@]}"; do
      IFS='|' read -r name verdict detail <<<"$row"
      printf '%s,%s,"%s"\n' "$name" "$verdict" "${detail//\"/\'}"
    done
  } | gum table --print --separator ","
else
  for row in "${RESULTS[@]}"; do
    IFS='|' read -r name verdict detail <<<"$row"
    printf '%-26s %-5s %s\n' "$name" "$verdict" "$detail"
  done
fi

if [ "$FAILURES" = 0 ]; then
  pass "all gcs_event checks passed"
else
  fail "$FAILURES check(s) failed - session log: $SESSION_LOG"
  info "operator side: look for 'Cloud Storage' lines in the 'task operator:dev' output"
  exit 1
fi
