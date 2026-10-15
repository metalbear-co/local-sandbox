#!/bin/bash
#
# Proves the `mirrord.group_join_timeout` property on a `mirrord.temporary_group_id`
# Kafka split.
#
# Background: the operator can only join the app's original consumer group once
# every pod of the previous generation has left it. It waits a configurable time
# for that (default 180s). A customer's Deployment rolled out slower than that,
# and the session died with the same INCONSISTENT_GROUP_PROTOCOL error as before
# the property was set, which pointed nowhere useful.
#
# Cases (the consumer Deployment is made slow to roll: a preStop hook keeps each
# old pod, and its KafkaJS group membership, alive for PRESTOP_SECONDS). The
# customer hit this with the 180s default; the script uses shorter values so a
# run takes a few minutes, the mechanics are identical:
#   1. mirrord.group_join_timeout=SHORT_TIMEOUT, below the rollout - the session
#      must fail, and the error must name mirrord.group_join_timeout as the fix
#      instead of the property already set.
#   2. mirrord.group_join_timeout raised above the rollout - the session must
#      survive the rollout, then split traffic: matching message -> local
#      session, non-matching -> cluster consumer.
#
# Prerequisites: a sandbox cluster and an operator >= 3.204.0 (deployed release
# or `task operator:dev`); older operators reject mirrord.group_join_timeout as
# an unknown property.
#
# Usage:
#   ./test-kafkajs-slow-rollout.sh
#
# Env knobs:
#   PRESTOP_SECONDS   how long each old pod lingers in the group (default 60)
#   SHORT_TIMEOUT     the too-short join wait for case 1 (default 30, must be
#                     below PRESTOP_SECONDS)
#   MIRRORD_BIN       mirrord binary (default: mirrord)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kafkajs-lib.sh"

PRESTOP_SECONDS="${PRESTOP_SECONDS:-60}"
SHORT_TIMEOUT="${SHORT_TIMEOUT:-30}"
DEPLOYMENT="deployment/kafkajs-consumer"
PROPERTY_LIST="mirrordpropertylist/kafkajs-kafka-connection"

# Undo the slow-rollout patch so later runs of the other proofs roll fast.
restore_rollout_speed() {
    kubectl patch -n "$NAMESPACE" "$DEPLOYMENT" --type=json -p '[
        {"op": "remove", "path": "/spec/template/spec/containers/0/lifecycle"},
        {"op": "remove", "path": "/spec/template/spec/terminationGracePeriodSeconds"}
    ]' >/dev/null 2>&1 || true
}

# Sets mirrord.group_join_timeout on the client config (seconds), appending it
# after mirrord.temporary_group_id which `task kafkajs:fix:on` put there.
set_join_timeout() {
    kubectl patch -n "$NAMESPACE" "$PROPERTY_LIST" --type=json -p "[
        {\"op\": \"add\", \"path\": \"/spec/properties/-\", \"value\": {\"name\": \"mirrord.group_join_timeout\", \"value\": \"$1\"}}
    ]" >/dev/null
}

on_exit() {
    stop_local_consumer
    restore_rollout_speed
    fix_on >/dev/null 2>&1 || true
}
trap on_exit EXIT

require_cluster
wait_for_operator_api
deploy_env
fix_on >/dev/null

say "Making the consumer's rollout last ${PRESTOP_SECONDS}s per old pod"
# preStop runs before SIGTERM, so the KafkaJS consumer inside the old pod keeps
# running (and keeps its group membership) for the whole sleep - exactly what a
# slow customer rollout looks like to the operator.
kubectl patch -n "$NAMESPACE" "$DEPLOYMENT" --type=strategic -p "{
  \"spec\": {\"template\": {\"spec\": {
    \"terminationGracePeriodSeconds\": $((PRESTOP_SECONDS + 30)),
    \"containers\": [{\"name\": \"consumer\", \"lifecycle\": {\"preStop\": {\"exec\": {\"command\": [\"sleep\", \"$PRESTOP_SECONDS\"]}}}}]
  }}}
}" >/dev/null
kubectl rollout status -n "$NAMESPACE" "$DEPLOYMENT" --timeout=$((PRESTOP_SECONDS + 120))s >/dev/null
ok "consumer redeployed with the slow-rollout hook"

# ---------------------------------------------------------------- case 1
say "Case 1: mirrord.group_join_timeout=${SHORT_TIMEOUT}, below the rollout - expecting a failure that names the property"
set_join_timeout "$SHORT_TIMEOUT"
CASE_START=$(now_utc)
start_local_consumer
# The session goes Ready while the operator is still retrying the join, so
# wait for the failure itself, not for the first status.
ERROR_TEXT=$(wait_for_session_failure $((PRESTOP_SECONDS + 120)) "$CASE_START") || ERROR_TEXT=""
if [ -z "$ERROR_TEXT" ]; then
    bad "case 1: expected the session to fail on the ${SHORT_TIMEOUT}s wait within $((PRESTOP_SECONDS + 120))s"
    print_diagnostics
    exit 1
fi
if echo "$ERROR_TEXT" | grep -q "group_join_timeout"; then
    ok "session failed and the error points at mirrord.group_join_timeout"
else
    bad "session failed but the error does not mention mirrord.group_join_timeout"
    echo "$ERROR_TEXT" | tail -15
    print_diagnostics
    exit 1
fi
show_error_excerpt "$ERROR_TEXT" "group_join_timeout"

stop_local_consumer
say "Waiting for the failed session and its rollout to clean up"
wait_for_sessions_gone 300 || true
kubectl rollout status -n "$NAMESPACE" "$DEPLOYMENT" --timeout=$((PRESTOP_SECONDS + 120))s >/dev/null

# ---------------------------------------------------------------- case 2
JOIN_TIMEOUT=$((PRESTOP_SECONDS + 90))
say "Case 2: mirrord.group_join_timeout=${JOIN_TIMEOUT} - expecting the split to outlast the rollout"
fix_on >/dev/null
set_join_timeout "$JOIN_TIMEOUT"

start_local_consumer
START_TS=$(date +%s)
status=$(wait_for_session_settled $((JOIN_TIMEOUT + 120))) || status=""
if [ "$status" != "ready" ]; then
    bad "case 2: expected Ready, got '${status:-nothing}'"
    print_diagnostics
    exit 1
fi
kubectl rollout status -n "$NAMESPACE" "$DEPLOYMENT" --timeout=$((JOIN_TIMEOUT + 120))s >/dev/null
# rollout status returns once the old pod is Terminating, but its preStop keeps
# it in the consumer group until it is actually gone; that is the wait the
# operator has to outlast, so measure until no Terminating pod is left.
waited=0
while kubectl get pods -n "$NAMESPACE" -l "app=$APP_LABEL" --no-headers 2>/dev/null | grep -q Terminating; do
    if [ "$waited" -ge $((JOIN_TIMEOUT + 120)) ]; then
        bad "old pod still terminating after $((JOIN_TIMEOUT + 120))s"
        print_diagnostics
        exit 1
    fi
    sleep 3
    waited=$((waited + 3))
done
ELAPSED=$(( $(date +%s) - START_TS ))
if [ "$ELAPSED" -lt "$SHORT_TIMEOUT" ]; then
    bad "the old pod left the group after ${ELAPSED}s, which does not exceed the ${SHORT_TIMEOUT}s wait case 1 used; raise PRESTOP_SECONDS"
    exit 1
fi
error=$(session_error_message)
if [ -n "$error" ]; then
    bad "session failed during the ${ELAPSED}s rollout: $error"
    print_diagnostics
    exit 1
fi
if ! local_consumer_alive; then
    bad "the local mirrord run exited during the rollout"
    print_diagnostics
    exit 1
fi
ok "session alive after a ${ELAPSED}s rollout (case 1 gave up at ${SHORT_TIMEOUT}s)"

MSG_LOCAL="slow-rollout-local-$RANDOM"
MSG_CLUSTER="slow-rollout-cluster-$RANDOM"

say "Sending a matching message (should reach the LOCAL session)"
send_match "$MSG_LOCAL"
if wait_for_local_message "$MSG_LOCAL" 120; then
    ok "local session received it"
else
    bad "local session did not receive the matching message within 120s"
    print_diagnostics
    exit 1
fi

say "Sending a non-matching message (should reach the CLUSTER consumer)"
send_nomatch "$MSG_CLUSTER"
waited=0
until cluster_consumer_logs | grep -qF "$MSG_CLUSTER"; do
    if [ "$waited" -ge 120 ]; then
        bad "cluster consumer did not receive the non-matching message within 120s"
        print_diagnostics
        exit 1
    fi
    sleep 3
    waited=$((waited + 3))
done
ok "cluster consumer received it"

stop_local_consumer
say "Waiting for the session to clean up"
wait_for_sessions_gone 300 || true

echo ""
say "Summary"
echo "  case 1  PASS  ${SHORT_TIMEOUT}s wait fails loudly, error names mirrord.group_join_timeout"
echo "  case 2  PASS  mirrord.group_join_timeout=${JOIN_TIMEOUT} outlasts a ${ELAPSED}s rollout, traffic splits"
