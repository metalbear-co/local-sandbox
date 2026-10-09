#!/usr/bin/env bash
#
# End-to-end test for the QUEUE FILTER POLICY (`spec.splitQueues` in
# MirrordPolicy / MirrordClusterPolicy) on the local minikube sandbox.
#
# The policy protects a queue-consuming target from sessions that would
# compete with it for messages. This script drives every verdict against the
# kafka overlay (deployment/kafka-consumer with a legacy
# MirrordKafkaTopicsConsumer for test-topic):
#
#   1. policy applied, but the target has NO split config
#        -> a session without split_queues still connects (policy is a no-op)
#   2. split config back in place, session without split_queues
#        -> rejected: requireFilter demands the session splits the Kafka queues
#   3. session filtering on the wrong header key
#        -> rejected: the policy requires a `user_id` filter on test-topic
#   4. session with a `user_id` pattern the policy regex does not accept
#        -> rejected: pattern conflict
#   5. session with the stock kafka overlay filter (user_id: test-user)
#        -> accepted, split session goes Ready
#   6. copy-target session without split_queues
#        -> rejected: the policy sets appliesToCopyTargets, so copies are held
#           to the same bar (enforced at CopyTarget creation)
#   7. copy-target session with a `*` queue id and a compliant filter
#        -> accepted: `*` is expanded to the CONFIGURED queues before the rules
#           run, so the policy's rule for a queue this target does not have
#           (ghost-queue) stays inert instead of rejecting the wildcard
#   8. policy with a broken queueId regex
#        -> its Accepted condition turns False (rule reported, not enforced)
#
# Prerequisites:
#   - minikube (bearkube) running, kafka overlay deployed (`task kafka:deploy`,
#     or run with DEPLOY=1)
#   - CRDs from the feature branch applied (`task operator:crds`) - the
#     preflight fails fast if `splitQueues` is missing from the policy CRD
#   - the local operator from the feature branch running (`task operator:dev`);
#     a released operator ignores the policy and cases 2-4 will fail
#
# Usage:
#   ./test-queue-filter-policy.sh
#   DEPLOY=1 ./test-queue-filter-policy.sh   # (re)deploy the kafka overlay first
#
# Env knobs (all optional):
#   MIRRORD_BIN      mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE        kafka overlay namespace (default test-mirrord)
#   REJECT_TIMEOUT   seconds to wait for the operator to reject a session (default 90)
#   READY_TIMEOUT    seconds to wait for the split session to go Ready (default 120)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="${NAMESPACE:-test-mirrord}"
REJECT_TIMEOUT="${REJECT_TIMEOUT:-90}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
DEPLOY="${DEPLOY:-0}"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/queue-filter-policy.XXXXXX)"
SESSION_LOG="$WORKDIR/session.log"
SESSION_PID=""
POLICY_NAME="queue-filter-policy-test"
BROKEN_POLICY_NAME="queue-filter-policy-test-broken"
TOPICS_CONSUMER_FILE="$SANDBOX_DIR/k8s/kafka/kafka-topics-consumer.yaml"
TOPICS_CONSUMER_DELETED=0
# The policy and the topics consumer have fixed names, so two concurrent runs
# would flip each other's cluster state - refuse to start instead.
LOCK_DIR="/tmp/queue-filter-policy.lock"

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
check() { # check <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; FAILURES=$((FAILURES + 1)); fi
}

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
    info "mirrord session stopped"
  fi
  kubectl delete mirrordpolicy -n "$NAMESPACE" "$POLICY_NAME" --ignore-not-found >/dev/null 2>&1
  kubectl delete mirrordpolicy -n "$NAMESPACE" "$BROKEN_POLICY_NAME" --ignore-not-found >/dev/null 2>&1
  if [ "$TOPICS_CONSUMER_DELETED" = 1 ]; then
    kubectl apply -f "$TOPICS_CONSUMER_FILE" >/dev/null 2>&1 \
      || warn "failed to restore $TOPICS_CONSUMER_FILE - re-apply it manually"
  fi
}
trap cleanup EXIT

# macOS has no `timeout`; bound every mirrord run with a watchdog.
run_with_timeout() { # run_with_timeout <secs> <cmd...>
  local secs="$1"
  shift
  "$@" &
  local pid=$!
  (
    sleep "$secs"
    kill "$pid" 2>/dev/null
  ) &
  local watchdog=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$rc"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Queue filter policy e2e (splitQueues)"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run appears active ($LOCK_DIR exists) - remove it if that's stale"
  exit 1
fi

if [ "$DEPLOY" = 1 ]; then
  info "DEPLOY=1 - deploying the kafka overlay first"
  (cd "$SANDBOX_DIR" && task kafka:deploy) || { fail "task kafka:deploy failed"; exit 1; }
fi

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
  || { fail "namespace $NAMESPACE not found - run 'task kafka:deploy' (or DEPLOY=1)"; exit 1; }
kubectl get deployment -n "$NAMESPACE" kafka-consumer >/dev/null 2>&1 \
  || { fail "deployment/kafka-consumer not found - run 'task kafka:deploy' (or DEPLOY=1)"; exit 1; }

# The API server silently prunes `splitQueues` from applied policies when the
# CRDs predate the feature, which would turn every deny case below into a
# confusing pass-through - fail fast instead.
if ! kubectl get crd mirrordpolicies.policies.mirrord.metalbear.co \
  -o jsonpath='{.spec.versions[-1].schema.openAPIV3Schema.properties.spec.properties.splitQueues}' \
  2>/dev/null | grep -q requireFilter; then
  fail "the MirrordPolicy CRD has no splitQueues field - run 'task operator:crds' from the feature branch"
  exit 1
fi
info "policy CRD carries splitQueues"
info "make sure 'task operator:dev' from the feature branch is running - a released operator ignores this policy"
info "mirrord CLI: $MIRRORD_BIN"
info "workdir: $WORKDIR"

# ---------------------------------------------------------------------------
# Fixtures: the policy and one mirrord config per verdict
# ---------------------------------------------------------------------------
cat >"$WORKDIR/policy.yaml" <<EOF
apiVersion: policies.mirrord.metalbear.co/v1alpha
kind: MirrordPolicy
metadata:
  name: $POLICY_NAME
  namespace: $NAMESPACE
spec:
  block: []
  appliesToCopyTargets: true
  splitQueues:
    requireFilter: true
    filters:
      - queueId: "^test-topic$"
        queueType: kafka
        rules:
          allOf:
            - key: user_id
              pattern: "^test-user$"
      # No queue with this id exists in the target's split config. Rules whose
      # queueId matches none of the session's (expanded) queues must stay inert,
      # including for `*` wildcard requests.
      - queueId: "^ghost-queue$"
        queueType: kafka
        rules:
          allOf:
            - key: never_set
EOF

mirrord_config() { # mirrord_config <file> <split_queues-json-or-empty>
  local file="$1" split="$2"
  if [ -n "$split" ]; then
    cat >"$file" <<EOF
{
  "operator": true,
  "target": { "path": "deployment/kafka-consumer", "namespace": "$NAMESPACE" },
  "feature": { "split_queues": $split }
}
EOF
  else
    cat >"$file" <<EOF
{
  "operator": true,
  "target": { "path": "deployment/kafka-consumer", "namespace": "$NAMESPACE" }
}
EOF
  fi
}

mirrord_config "$WORKDIR/no-split.json" ""
mirrord_config "$WORKDIR/wrong-key.json" \
  '{ "test-topic": { "queue_type": "Kafka", "message_filter": { "tenant": "test-user" } } }'
mirrord_config "$WORKDIR/bad-pattern.json" \
  '{ "test-topic": { "queue_type": "Kafka", "message_filter": { "user_id": ".*" } } }'
mirrord_config "$WORKDIR/compliant.json" \
  '{ "test-topic": { "queue_type": "Kafka", "message_filter": { "user_id": "test-user" } } }'

mirrord_copy_config() { # mirrord_copy_config <file> <split_queues-json-or-empty>
  local file="$1" split="$2" split_field=""
  [ -n "$split" ] && split_field=", \"split_queues\": $split"
  cat >"$file" <<EOF
{
  "operator": true,
  "target": { "path": "deployment/kafka-consumer", "namespace": "$NAMESPACE" },
  "feature": { "copy_target": { "scale_down": false }$split_field }
}
EOF
}

mirrord_copy_config "$WORKDIR/copy-no-split.json" ""
mirrord_copy_config "$WORKDIR/copy-wildcard.json" \
  '{ "*": { "queue_type": "Kafka", "message_filter": { "user_id": "test-user" } } }'

# run_session <config> -> exit code; output lands in $WORKDIR/last-run.log
run_session() {
  run_with_timeout "$REJECT_TIMEOUT" \
    "$MIRRORD_BIN" exec -f "$WORKDIR/$1" -- sh -c 'exit 0' >"$WORKDIR/last-run.log" 2>&1
}

expect_rejected() { # expect_rejected <config> <needle> <description>
  local config="$1" needle="$2" description="$3"
  if run_session "$config"; then
    fail "$description: session was accepted, expected a policy rejection"
    tail -5 "$WORKDIR/last-run.log"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q "$needle" "$WORKDIR/last-run.log"; then
    pass "$description (error mentions: $needle)"
  else
    fail "$description: session failed or timed out without the expected policy message"
    tail -5 "$WORKDIR/last-run.log"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------------------
# 1. No split config on the target -> the policy is a no-op
# ---------------------------------------------------------------------------
header "1/8 policy applied, target has no split config -> session connects"
kubectl apply -f "$WORKDIR/policy.yaml" >/dev/null || { fail "failed to apply the policy"; exit 1; }
info "policy $POLICY_NAME applied"

kubectl delete -f "$TOPICS_CONSUMER_FILE" --ignore-not-found >/dev/null 2>&1
TOPICS_CONSUMER_DELETED=1
sleep 3 # let the operator's reflector observe the delete
if run_session "no-split.json"; then
  pass "session without split_queues connects while no split config exists"
else
  fail "session was rejected although the target has no split config"
  tail -5 "$WORKDIR/last-run.log"
  FAILURES=$((FAILURES + 1))
fi

kubectl apply -f "$TOPICS_CONSUMER_FILE" >/dev/null
TOPICS_CONSUMER_DELETED=0
sleep 3 # let the operator's reflector observe the re-add
info "split config (MirrordKafkaTopicsConsumer) restored"

# ---------------------------------------------------------------------------
# 2-4. The deny verdicts
# ---------------------------------------------------------------------------
header "2/8 no split_queues at all -> rejected (requireFilter)"
expect_rejected "no-split.json" "requires this session to split" \
  "session without split_queues is rejected"

header "3/8 filter on the wrong key -> rejected"
expect_rejected "wrong-key.json" "requires a message filter for" \
  "session filtering on 'tenant' instead of 'user_id' is rejected"

header "4/8 user_id pattern conflicts with the policy -> rejected"
expect_rejected "bad-pattern.json" "to match" \
  "session with user_id pattern '.*' is rejected"

# ---------------------------------------------------------------------------
# 5. Compliant session -> split goes Ready
# ---------------------------------------------------------------------------
header "5/8 compliant filter (user_id: test-user) -> split session Ready"

# A Ready session left over from an earlier run would satisfy the wait below
# before this run's session even connects - count only sessions of our target.
split_session_count() {
  kubectl get mirrordclustersplitsessions.queues.mirrord.metalbear.co \
    -o jsonpath='{range .items[?(@.spec.target.name=="kafka-consumer")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep -c .
}
ready_split_session_count() {
  kubectl get mirrordclustersplitsessions.queues.mirrord.metalbear.co \
    -o jsonpath='{range .items[?(@.spec.target.name=="kafka-consumer")]}{.status.phase}{"\n"}{end}' \
    2>/dev/null | grep -c Ready
}
if [ "$(split_session_count)" != 0 ]; then
  warn "a kafka-consumer split session already exists - waiting for it to drain first"
  for _ in $(seq 1 60); do
    [ "$(split_session_count)" = 0 ] && break
    sleep 2
  done
fi

"$MIRRORD_BIN" exec -f "$WORKDIR/compliant.json" -- sh -c 'sleep 600' >"$SESSION_LOG" 2>&1 &
SESSION_PID=$!
info "session pid: $SESSION_PID (log: $SESSION_LOG)"

ready=1
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    fail "mirrord session died - last log lines:"
    tail -10 "$SESSION_LOG"
    break
  fi
  if [ "$(ready_split_session_count)" != 0 ]; then
    ready=0
    break
  fi
  sleep 1
done
check "compliant session was accepted and the split session reached Ready" "$ready"
[ "$ready" = 0 ] || tail -10 "$SESSION_LOG"

if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
  kill "$SESSION_PID" 2>/dev/null || true
  wait "$SESSION_PID" 2>/dev/null || true
fi
SESSION_PID=""

# Let the operator drain and delete the split before the next check (bounded:
# the linger keeps the tmp topic around for a bit; leftovers only mean the
# next run waits at its own precondition).
for _ in $(seq 1 45); do
  [ "$(split_session_count)" = 0 ] && break
  sleep 2
done
[ "$(split_session_count)" = 0 ] && info "split session drained and deleted" \
  || warn "split session still tearing down - the next run will wait for it"

# ---------------------------------------------------------------------------
# 6-7. Copy target sessions
# ---------------------------------------------------------------------------
header "6/8 copy target without split_queues -> rejected"
expect_rejected "copy-no-split.json" "requires this session to split" \
  "copy-target session without split_queues is rejected"

header "7/8 copy target with '*' + compliant filter -> accepted, ghost rule stays inert"
"$MIRRORD_BIN" exec -f "$WORKDIR/copy-wildcard.json" -- sh -c 'sleep 600' >"$SESSION_LOG" 2>&1 &
SESSION_PID=$!
info "copy-target session pid: $SESSION_PID (log: $SESSION_LOG)"

ready=1
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    fail "copy-target session died - a rule for a queue this target does not have must stay inert:"
    tail -10 "$SESSION_LOG"
    break
  fi
  if [ "$(ready_split_session_count)" != 0 ]; then
    ready=0
    break
  fi
  sleep 1
done
check "copy-target wildcard session was accepted and the split reached Ready" "$ready"
[ "$ready" = 0 ] || tail -10 "$SESSION_LOG"

if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
  kill "$SESSION_PID" 2>/dev/null || true
  wait "$SESSION_PID" 2>/dev/null || true
fi
SESSION_PID=""

for _ in $(seq 1 45); do
  [ "$(split_session_count)" = 0 ] && break
  sleep 2
done
[ "$(split_session_count)" = 0 ] && info "copy-target split drained and deleted" \
  || warn "copy-target split still tearing down - the next run will wait for it"

# ---------------------------------------------------------------------------
# 8. Broken policy regex -> Accepted condition turns False
# ---------------------------------------------------------------------------
header "8/8 policy with a broken queueId regex -> Accepted=False"
cat >"$WORKDIR/broken-policy.yaml" <<EOF
apiVersion: policies.mirrord.metalbear.co/v1alpha
kind: MirrordPolicy
metadata:
  name: $BROKEN_POLICY_NAME
  namespace: $NAMESPACE
spec:
  block: []
  splitQueues:
    filters:
      - queueId: "["
        queueType: kafka
EOF
kubectl apply -f "$WORKDIR/broken-policy.yaml" >/dev/null

accepted=""
for _ in $(seq 1 30); do
  accepted=$(kubectl get mirrordpolicy -n "$NAMESPACE" "$BROKEN_POLICY_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  [ "$accepted" = "False" ] && break
  sleep 1
done
[ "$accepted" = "False" ]
check "broken policy reports Accepted=False" $?
kubectl get mirrordpolicy -n "$NAMESPACE" "$BROKEN_POLICY_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].message}' 2>/dev/null \
  | grep -q "splitQueues"
check "the condition names the splitQueues field" $?
kubectl delete mirrordpolicy -n "$NAMESPACE" "$BROKEN_POLICY_NAME" --ignore-not-found >/dev/null

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
header "Result"
if [ "$FAILURES" = 0 ]; then
  pass "all queue filter policy checks passed"
  info "next: 'task kafka:run:local' + 'task kafka:send:match' still work with the policy gone"
else
  fail "$FAILURES check(s) failed - logs in $WORKDIR"
  exit 1
fi
