#!/usr/bin/env bash
#
# End-to-end test for the composable queue message filter (`filter` with
# `metadata` / `any_of` / `all_of` in `feature.split_queues`) on the local
# minikube sandbox, against the SQS LocalStack overlay
# (deployment/sqs-consumer splitting queue id `test-queue`).
#
# Every case starts the sandbox consumer locally under mirrord with one config,
# sends messages with different `tenant` attributes, and checks where each one
# lands: the local consumer's log (matched) or the cluster consumer's log
# (unmatched).
#
#   1. legacy `message_filter` map (the stock overlay config)
#        -> tenant=Avi.Test local, tenant=Basic cluster
#   2. `filter: { metadata }` naming the attribute
#        -> tenant=Avi.Test local, tenant=Basic cluster
#   3. `filter: { any_of }` of two metadata regexes
#        -> tenant=Avi.Test AND tenant=Vip.Gold local, tenant=Basic cluster
#   4. `filter: { all_of }` of a name regex and a value regex
#        -> tenant=Avi.Test local, tenant=Avi.Nope cluster
#   5. `filter` next to `message_filter` on one entry
#        -> rejected by the CLI before any session starts
#   6. (only with EXPECT_UNSUPPORTED=1, against a released operator)
#      any `filter` config -> rejected by the CLI with the feature error,
#      while case 1 still passes
#
# Prerequisites:
#   - minikube (bearkube) running, SQS overlay deployed (`task sqs:deploy`, or
#     run with DEPLOY=1)
#   - CRDs from the feature branch applied (`task operator:crds`)
#   - the local operator from the feature branch running (`task operator:dev`),
#     or a released one with EXPECT_UNSUPPORTED=1 for the compat run
#   - a mirrord CLI built from the feature branch (MIRRORD_BIN, or the local
#     debug build)
#
# Usage:
#   ./test-queue-filter-shape.sh
#   DEPLOY=1 ./test-queue-filter-shape.sh
#   EXPECT_UNSUPPORTED=1 ./test-queue-filter-shape.sh   # released operator
#
# Env knobs (all optional):
#   MIRRORD_BIN         mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE           overlay namespace (default test-mirrord)
#   READY_TIMEOUT       seconds to wait for the split session to go Ready (default 120)
#   MESSAGE_TIMEOUT     seconds to wait for a message to show up in a log (default 60)
#   EXPECT_UNSUPPORTED  1 when the operator does not support composed filters
#   CASES               space separated case numbers to run (default: all), e.g. CASES="1 5"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="${NAMESPACE:-test-mirrord}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
MESSAGE_TIMEOUT="${MESSAGE_TIMEOUT:-60}"
DEPLOY="${DEPLOY:-0}"
EXPECT_UNSUPPORTED="${EXPECT_UNSUPPORTED:-0}"
CASES="${CASES:-1 2 3 4 5}"
REGION="${SQS_REGION:-eu-north-1}"
QUEUE_URL="${SQS_QUEUE_URL:-http://localhost:4566/000000000000/TestQueue}"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/queue-filter-shape.XXXXXX)"
SESSION_LOG="$WORKDIR/session.log"
SESSION_PID=""
CONSUMER_BIN="$WORKDIR/sqs-consumer"
# The overlay has one consumer and one queue, so two runs would steal each
# other's messages - refuse to start instead.
LOCK_DIR="/tmp/queue-filter-shape.lock"

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
record() { # record <case> <PASS|FAIL>
  RESULTS+=("$1|$2")
  [ "$2" = PASS ] || FAILURES=$((FAILURES + 1))
}

stop_session() {
  if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
    info "mirrord session stopped"
  fi
  SESSION_PID=""
}

cleanup() {
  stop_session
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Composable queue filter e2e (feature.split_queues[].filter)"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run appears active ($LOCK_DIR exists) - remove it if that's stale"
  exit 1
fi

if [ "$DEPLOY" = 1 ]; then
  info "DEPLOY=1 - deploying the SQS overlay first"
  (cd "$SANDBOX_DIR" && task sqs:deploy) || { fail "task sqs:deploy failed"; exit 1; }
fi

kubectl get deployment -n "$NAMESPACE" sqs-consumer >/dev/null 2>&1 \
  || { fail "deployment/sqs-consumer not found - run 'task sqs:deploy' (or DEPLOY=1)"; exit 1; }
kubectl get deployment -n localstack localstack >/dev/null 2>&1 \
  || { fail "LocalStack not found - run 'task sqs:deploy' (or DEPLOY=1)"; exit 1; }

# The CLI must know the `filter` field: an older CLI rejects it as an unknown
# field and every composed case would fail for the wrong reason.
if ! "$MIRRORD_BIN" --version >/dev/null 2>&1; then
  fail "mirrord CLI not runnable: $MIRRORD_BIN"
  exit 1
fi
info "mirrord CLI: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "operator: $("$MIRRORD_BIN" operator status 2>/dev/null | head -1 || echo unknown)"
[ "$EXPECT_UNSUPPORTED" = 1 ] && info "EXPECT_UNSUPPORTED=1 - composed cases must be rejected by the CLI"
info "workdir: $WORKDIR"

(cd "$SANDBOX_DIR/apps/sqs-consumer" && go build -o "$CONSUMER_BIN" main.go) \
  || { fail "failed to build the sandbox SQS consumer"; exit 1; }
kubectl exec -n localstack deploy/localstack -- awslocal sqs create-queue \
  --queue-name TestQueue --region "$REGION" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Fixtures: one mirrord config per case
# ---------------------------------------------------------------------------
mirrord_config() { # mirrord_config <file> <split_queues-json>
  cat >"$WORKDIR/$1" <<EOC
{
  "operator": true,
  "target": { "path": "deployment/sqs-consumer", "namespace": "$NAMESPACE" },
  "feature": { "split_queues": $2 }
}
EOC
}

mirrord_config legacy.json \
  '{ "test-queue": { "queue_type": "SQS", "message_filter": { "tenant": "^Avi\\." } } }'
mirrord_config metadata.json \
  '{ "test-queue": { "queue_type": "SQS", "filter": { "metadata": "^tenant: Avi\\..*$" } } }'
mirrord_config any-of.json \
  '[ { "queue_id": "test-queue", "queue_type": "SQS", "filter": { "any_of": [
        { "metadata": "^tenant: Avi\\..*$" },
        { "metadata": "^tenant: Vip\\..*$" } ] } } ]'
mirrord_config all-of.json \
  '{ "test-queue": { "queue_type": "SQS", "filter": { "all_of": [
        { "metadata": "^tenant: " },
        { "metadata": "Avi\\.Test$" } ] } } }'
mirrord_config both-shapes.json \
  '{ "test-queue": { "queue_type": "SQS", "message_filter": { "tenant": "^Avi\\." },
      "filter": { "metadata": "^tenant: Avi\\..*$" } } }'

# ---------------------------------------------------------------------------
# Session and message helpers
# ---------------------------------------------------------------------------
ready_split_session_count() {
  kubectl get mirrordclustersplitsessions.queues.mirrord.metalbear.co \
    -o jsonpath='{range .items[?(@.spec.target.name=="sqs-consumer")]}{.status.phase}{"\n"}{end}' \
    2>/dev/null | grep -c Ready
}
split_session_count() {
  kubectl get mirrordclustersplitsessions.queues.mirrord.metalbear.co \
    -o jsonpath='{range .items[?(@.spec.target.name=="sqs-consumer")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep -c .
}

wait_for_no_split_session() {
  for _ in $(seq 1 45); do
    [ "$(split_session_count)" = 0 ] && return 0
    sleep 2
  done
  warn "a sqs-consumer split session is still tearing down"
  return 1
}

# start_session <config> -> 0 when the split session reached Ready. Each case keeps its own
# session log so a failure can be read after the next case started.
start_session() {
  SESSION_LOG="$WORKDIR/session-${1%.json}.log"
  : >"$SESSION_LOG"
  AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION="$REGION" \
    QUEUE_NAME=test-queue MIRRORD_CHECK_VERSION=false \
    "$MIRRORD_BIN" exec -f "$WORKDIR/$1" -- "$CONSUMER_BIN" >"$SESSION_LOG" 2>&1 &
  SESSION_PID=$!
  info "session pid: $SESSION_PID (log: $SESSION_LOG)"
  for _ in $(seq 1 "$READY_TIMEOUT"); do
    if ! kill -0 "$SESSION_PID" 2>/dev/null; then
      fail "mirrord session died - last log lines:"
      tail -10 "$SESSION_LOG"
      SESSION_PID=""
      return 1
    fi
    if [ "$(ready_split_session_count)" != 0 ]; then
      wait_for_single_consumer_pod
      return 0
    fi
    sleep 1
  done
  fail "split session did not reach Ready in ${READY_TIMEOUT}s"
  tail -10 "$SESSION_LOG"
  return 1
}

# The split patches the consumer's queue name and restarts its pods. Until the old pod is gone
# it still reads the source queue directly and would swallow the first message, so sending is
# held until exactly one consumer pod is left and ready.
wait_for_single_consumer_pod() {
  for _ in $(seq 1 60); do
    local pods
    # Terminating pods keep a deletionTimestamp; only the live ones count.
    pods="$(kubectl get pods -n "$NAMESPACE" -l app=sqs-consumer \
      -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"/"}{.status.phase}{"\n"}{end}' 2>/dev/null \
      | grep "^/")"
    if [ "$(printf '%s\n' "$pods" | grep -c .)" = 1 ] && printf '%s' "$pods" | grep -q "^/Running$"; then
      sleep 3 # let the new pod finish its own startup poll before the message lands
      return 0
    fi
    sleep 2
  done
  warn "consumer pods did not settle to one running pod; sending anyway"
}

# send <tenant> <body>
send() {
  kubectl exec -n localstack deploy/localstack -- awslocal sqs send-message \
    --queue-url "$QUEUE_URL" --region "$REGION" \
    --message-body "$2" \
    --message-attributes "tenant={StringValue=$1,DataType=String}" >/dev/null
}

# cluster_log -> the deployed consumer's recent log lines
cluster_log() {
  kubectl logs -n "$NAMESPACE" -l app=sqs-consumer --tail=200 2>/dev/null
}

# expect_local <tenant> <case-tag> - the message must reach the local consumer
expect_local() {
  local body="local-$2-$RANDOM"
  send "$1" "$body"
  for _ in $(seq 1 "$MESSAGE_TIMEOUT"); do
    if grep -qF "$body" "$SESSION_LOG"; then
      pass "tenant=$1 reached the local session"
      return 0
    fi
    sleep 1
  done
  fail "tenant=$1 did not reach the local session in ${MESSAGE_TIMEOUT}s"
  return 1
}

# expect_cluster <tenant> <case-tag> - the message must stay with the deployed consumer
expect_cluster() {
  local body="cluster-$2-$RANDOM"
  send "$1" "$body"
  for _ in $(seq 1 "$MESSAGE_TIMEOUT"); do
    if grep -qF "$body" "$SESSION_LOG"; then
      fail "tenant=$1 was stolen by the local session"
      return 1
    fi
    if cluster_log | grep -qF "$body"; then
      pass "tenant=$1 stayed with the cluster consumer"
      return 0
    fi
    sleep 1
  done
  fail "tenant=$1 reached neither consumer in ${MESSAGE_TIMEOUT}s"
  return 1
}

# selected <case-name> - whether the case's leading number is in CASES
selected() {
  case " $CASES " in *" ${1%% *} "*) return 0 ;; *) return 1 ;; esac
}

# routing_case <name> <config> <local-tenants...> -- <cluster-tenants...>
routing_case() {
  local name="$1" config="$2" ok=0
  shift 2
  selected "$name" || return 0
  header "$name"
  if start_session "$config"; then
    local side=local
    for tenant in "$@"; do
      if [ "$tenant" = "--" ]; then side=cluster; continue; fi
      if [ "$side" = local ]; then
        expect_local "$tenant" "$name" || ok=1
      else
        expect_cluster "$tenant" "$name" || ok=1
      fi
    done
  else
    ok=1
  fi
  stop_session
  wait_for_no_split_session || true
  record "$name" "$([ "$ok" = 0 ] && echo PASS || echo FAIL)"
}

# rejected_case <name> <config> <needle> - the CLI must refuse before any session starts
rejected_case() {
  local name="$1" config="$2" needle="$3"
  selected "$name" || return 0
  header "$name"
  if "$MIRRORD_BIN" exec -f "$WORKDIR/$config" -- sh -c 'exit 0' >"$WORKDIR/last-run.log" 2>&1; then
    fail "the CLI accepted $config, expected a rejection"
    record "$name" FAIL
    return
  fi
  if grep -qi "$needle" "$WORKDIR/last-run.log"; then
    pass "rejected (error mentions: $needle)"
    record "$name" PASS
  else
    fail "rejected without the expected message; last lines:"
    tail -5 "$WORKDIR/last-run.log"
    record "$name" FAIL
  fi
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------
if [ "$(split_session_count)" != 0 ]; then
  warn "a sqs-consumer split session already exists - waiting for it to drain first"
  wait_for_no_split_session || true
fi

routing_case "1 legacy message_filter" legacy.json Avi.Test -- Basic

if [ "$EXPECT_UNSUPPORTED" = 1 ]; then
  rejected_case "2 metadata filter on an old operator" metadata.json "composable message filters"
  rejected_case "3 any_of filter on an old operator" any-of.json "composable message filters"
  rejected_case "4 all_of filter on an old operator" all-of.json "composable message filters"
else
  routing_case "2 metadata filter" metadata.json Avi.Test -- Basic
  routing_case "3 any_of filter" any-of.json Avi.Test Vip.Gold -- Basic
  routing_case "4 all_of filter" all-of.json Avi.Test -- Avi.Nope
fi

rejected_case "5 filter next to message_filter" both-shapes.json "both"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"
for entry in "${RESULTS[@]}"; do
  case="${entry%|*}"
  verdict="${entry#*|}"
  if [ "$verdict" = PASS ]; then pass "$case"; else fail "$case"; fi
done
if [ "$FAILURES" = 0 ]; then
  info "all cases passed"
  exit 0
fi
fail "$FAILURES case(s) failed - logs in $WORKDIR"
exit 1
