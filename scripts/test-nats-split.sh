#!/usr/bin/env bash
#
# End-to-end test for NATS JetStream queue splitting on the local minikube
# sandbox, against the k8s/overlays/nats overlay (stream ORDERS, durable pull
# consumer orders-app, split config nats-test-config).
#
#   1. (optional, DEPLOY=1) deploy the nats overlay first.
#   2. start a local consumer under mirrord with the header filter
#      tenant=^acme$ (steal mode) and wait for the split session to go Ready.
#   3. publish a matching (tenant=acme) and a non-matching (tenant=other)
#      message through the nats CLI in the nats-box pod.
#   4. verify routing: the local app got ONLY the matching message, the
#      deployed consumer got ONLY the non-matching one.
#   5. stop the session and verify every mirrord-tmp-* stream is deleted.
#
# Prerequisites:
#   - minikube (bearkube) running with an operator that has natsSplitting on
#   - `task nats:deploy` done at least once (or run with DEPLOY=1)
#
# Usage:
#   ./test-nats-split.sh
#   DEPLOY=1 ./test-nats-split.sh   # (re)deploy the nats overlay first
#   KEEP=1 ./test-nats-split.sh     # leave the session running at the end
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE       consumer namespace (default test-mirrord)
#   NATS_NAMESPACE  NATS namespace (default nats-sandbox)
#   SETTLE_WAIT     seconds to let messages drain after publishing (default 15)
#   READY_TIMEOUT   seconds to wait for the split session to go Ready (default 120)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="${NAMESPACE:-test-mirrord}"
NATS_NAMESPACE="${NATS_NAMESPACE:-nats-sandbox}"
SETTLE_WAIT="${SETTLE_WAIT:-15}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
KEEP="${KEEP:-0}"
DEPLOY="${DEPLOY:-0}"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/nats-split.XXXXXX)"
SESSION_LOG="$WORKDIR/session.log"
CLUSTER_LOGS="$WORKDIR/cluster-consumer.log"
SESSION_PID=""
# The cluster resources (deployment, split config) have fixed names, so two
# concurrent runs tear down each other's splits - refuse to start instead.
LOCK_DIR="/tmp/nats-split.lock"
# Per-run tag: message bodies are unique per run so a fresh session cannot be
# fooled by another run's leftovers still parked in the stream.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"
SUBJECT="orders.new"
CONSUMER="nats-consumer"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
info() { printf '\033[0;32m[INFO]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; }
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
header() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

FAILURES=0
check() { # check <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; FAILURES=$((FAILURES + 1)); fi
}

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
    if [ "$KEEP" = 1 ]; then
      warn "KEEP=1 - leaving the mirrord session running (pid $SESSION_PID, log $SESSION_LOG)"
      return
    fi
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
    info "mirrord session stopped"
  fi
}
trap cleanup EXIT

get_natsbox_pod() {
  kubectl get pod -n "$NATS_NAMESPACE" -l app.kubernetes.io/name=nats-box \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

get_consumer_pod() {
  kubectl get pod -n "$NAMESPACE" -l "app=$CONSUMER" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null
}

nats_cli() { # nats_cli <args...>
  local pod
  pod=$(get_natsbox_pod)
  [ -n "$pod" ] || return 1
  kubectl exec -n "$NATS_NAMESPACE" "$pod" -- \
    nats --server nats://nats:4222 "$@"
}

publish() { # publish <tenant> <body>
  local tenant="$1" body="$2" attempt
  for attempt in 1 2 3; do
    if nats_cli pub "$SUBJECT" -H "tenant:$tenant" \
      "{\"tenant\":\"$tenant\",\"message\":\"$body\"}" >/dev/null 2>&1; then
      return 0
    fi
    warn "publish attempt $attempt failed, retrying..."
    sleep 2
  done
  return 1
}

# Names of every stream, one per line (empty when JetStream has none).
list_streams() {
  nats_cli stream ls --names 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "NATS queue split test"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run of this script is active (its lock: $LOCK_DIR; rmdir it if stale)"
  exit 1
fi
command -v kubectl >/dev/null 2>&1 || { fail "kubectl is required"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not runnable: $MIRRORD_BIN"; exit 1; }
info "mirrord CLI: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | tr -d '\n'))"
info "workdir: $WORKDIR"
info "run tag: $RUN_TAG"

if [ "$DEPLOY" = 1 ]; then
  info "deploying the nats overlay (task nats:deploy)..."
  (cd "$SANDBOX_DIR" && task nats:deploy)
fi

if [ -z "$(get_natsbox_pod)" ]; then
  fail "no nats-box pod in namespace $NATS_NAMESPACE - run 'task nats:deploy' or rerun with DEPLOY=1"
  exit 1
fi
if [ -z "$(get_consumer_pod)" ]; then
  fail "no $CONSUMER pod in namespace $NAMESPACE - run 'task nats:deploy' or rerun with DEPLOY=1"
  exit 1
fi

kubectl get crd mirrordsplitconfigs.queues.mirrord.metalbear.co >/dev/null 2>&1 || {
  fail "MirrordSplitConfig CRD not installed - the deployed operator predates the unified splitting CRDs"
  exit 1
}

# `mirrord exec` dies with a generic "operator unreachable" error if the
# operator (or `task operator:dev`) is still starting, so wait for its
# APIService to answer before opening a session.
info "waiting for the operator APIService to answer..."
operator_up=1
for _ in $(seq 1 60); do
  if kubectl get --raw /apis/operator.metalbear.co/v1 >/dev/null 2>&1; then
    operator_up=0
    break
  fi
  sleep 2
done
if [ "$operator_up" != 0 ]; then
  fail "the operator APIService never answered - is the operator (or 'task operator:dev') running?"
  exit 1
fi

info "waiting for the ORDERS stream (the deployed consumer creates it on startup)..."
stream_up=1
for _ in $(seq 1 30); do
  if list_streams | grep -qx "ORDERS"; then
    stream_up=0
    break
  fi
  sleep 2
done
if [ "$stream_up" != 0 ]; then
  fail "stream ORDERS never appeared - check: kubectl logs -n $NAMESPACE -l app=$CONSUMER"
  exit 1
fi

# ---------------------------------------------------------------------------
# Local session with the header filter (steal mode)
# ---------------------------------------------------------------------------
header "Starting the mirrord session"

cat >"$WORKDIR/mirrord.json" <<EOF
{
    "operator": true,
    "target": {
        "path": "deployment/$CONSUMER",
        "namespace": "$NAMESPACE"
    },
    "feature": {
        "split_queues": {
            "orders": {
                "queue_type": "NATS",
                "message_filter": {
                    "tenant": "^acme$"
                }
            }
        }
    }
}
EOF

info "building the consumer..."
(cd "$SANDBOX_DIR/apps/nats-consumer" && go build -o /tmp/nats-consumer main.go) || {
  fail "go build failed"
  exit 1
}

info "session log streams to: $SESSION_LOG (tail -f it in another terminal)"
"$MIRRORD_BIN" exec -f "$WORKDIR/mirrord.json" -- /tmp/nats-consumer >"$SESSION_LOG" 2>&1 &
SESSION_PID=$!
info "session pid: $SESSION_PID"

info "waiting for the split session to go Ready (up to ${READY_TIMEOUT}s)..."
ready=1
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    fail "mirrord session died - last log lines:"
    tail -20 "$SESSION_LOG"
    fail "if the queue kind was rejected, the deployed operator likely predates NATS splitting"
    exit 1
  fi
  if kubectl get mirrordclustersplitsessions.queues.mirrord.metalbear.co -o json 2>/dev/null \
    | grep -q '"ready"'; then
    ready=0
    break
  fi
  sleep 1
done
check "split session reached Ready" "$ready"
if [ "$ready" != 0 ]; then tail -20 "$SESSION_LOG"; exit 1; fi

info "temporary streams now in JetStream:"
list_streams | grep '^mirrord-tmp-' || warn "no mirrord-tmp-* stream listed (yet?)"

# ---------------------------------------------------------------------------
# Publish and verify routing
# ---------------------------------------------------------------------------
header "Publishing messages"

# Give the local consumer a moment to attach to its per-session consumer.
sleep 5

publish "acme" "tolocal-$RUN_TAG: hello local session" || { fail "publishing the matching message failed"; exit 1; }
info "published matching message (tenant=acme)"
publish "other" "tocluster-$RUN_TAG: hello cluster consumer" || { fail "publishing the non-matching message failed"; exit 1; }
info "published non-matching message (tenant=other)"

info "letting messages drain for ${SETTLE_WAIT}s..."
sleep "$SETTLE_WAIT"

header "Verifying routing"

kubectl logs -n "$NAMESPACE" "$(get_consumer_pod)" --tail=200 >"$CLUSTER_LOGS" 2>/dev/null || true

grep -q "tolocal-$RUN_TAG" "$SESSION_LOG" \
  && r=0 || r=1
check "local session received the matching message" "$r"
! grep -q "tocluster-$RUN_TAG" "$SESSION_LOG" \
  && r=0 || r=1
check "local session did NOT receive the non-matching message" "$r"
grep -q "tocluster-$RUN_TAG" "$CLUSTER_LOGS" \
  && r=0 || r=1
check "deployed consumer received the non-matching message" "$r"
! grep -q "tolocal-$RUN_TAG" "$CLUSTER_LOGS" \
  && r=0 || r=1
check "deployed consumer did NOT receive the stolen message" "$r"

# ---------------------------------------------------------------------------
# Teardown: every mirrord-tmp-* stream must disappear
# ---------------------------------------------------------------------------
if [ "$KEEP" = 1 ]; then
  header "Result (KEEP=1 - skipping teardown checks)"
else
  header "Stopping the session and verifying tmp stream cleanup"

  kill "$SESSION_PID" 2>/dev/null || true
  wait "$SESSION_PID" 2>/dev/null || true
  SESSION_PID=""
  info "session stopped, waiting for tmp stream deletion..."

  cleaned=1
  for _ in $(seq 1 60); do
    if ! list_streams | grep -q '^mirrord-tmp-'; then
      cleaned=0
      break
    fi
    sleep 2
  done
  check "all mirrord-tmp-* streams deleted" "$cleaned"
  if [ "$cleaned" != 0 ]; then
    warn "streams still present:"
    list_streams | sed 's/^/  /'
  fi

  header "Result"
fi

if [ "$FAILURES" = 0 ]; then
  pass "NATS queue splitting worked end to end"
  info "cluster resources (the overlay, the split config) are left for reuse"
else
  fail "$FAILURES check(s) failed - session log: $SESSION_LOG, cluster log: $CLUSTER_LOGS"
  exit 1
fi
