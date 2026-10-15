#!/bin/bash
#
# Proves how Kafka splitting behaves when the app's consumer group uses the
# cooperative-sticky assignment protocol (quix-streams / confluent-kafka apps).
#
# Background: the operator's forwarder joins the app's consumer group with
# librdkafka's default range,roundrobin. Kafka only admits members whose
# protocol list overlaps the group's, so a cooperative-sticky group rejects the
# forwarder with INCONSISTENT_GROUP_PROTOCOL - no KafkaJS involved. There are two
# ways out, and this script runs all three states against one deployment:
#   1. Plain client config - the session must fail at once with
#      INCONSISTENT_GROUP_PROTOCOL.
#   2. partition.assignment.strategy=cooperative-sticky on the client config -
#      the forwarder speaks the group's protocol, joins it directly with the
#      cluster pod still inside, and traffic splits (matching -> local,
#      non-matching -> cluster). No temporary group, no rollout wait.
#   3. mirrord.temporary_group_id=true, plain strategy - the pod moves to a
#      temporary group, leaves the original cleanly on SIGTERM, and the forwarder
#      joins it well within the default wait. Traffic splits.
#
# Prerequisites: a sandbox cluster; works against the deployed release
# (>= 3.195.0) or `task operator:dev`.
#
# Usage:
#   ./test-confluent-cooperative.sh
#
# Env knobs:
#   MIRRORD_BIN       mirrord binary (default: mirrord)

MODULE=confluent
APP_LABEL=confluent-consumer
LOCAL_PREPARE='test -d .venv || python3 -m venv .venv; .venv/bin/pip install -q -r requirements.txt'
LOCAL_CMD='.venv/bin/python consumer.py'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kafkajs-lib.sh"

DEPLOYMENT="deployment/confluent-consumer"

strategy_on()  { (cd "$SANDBOX_DIR" && task confluent:strategy:on >/dev/null); }
strategy_off() { (cd "$SANDBOX_DIR" && task confluent:strategy:off >/dev/null); }

on_exit() {
    stop_local_consumer
    strategy_off || true
}
trap on_exit EXIT

# Sends one matching and one non-matching message and asserts where each lands.
assert_traffic_splits() {
    local tag="$1"
    local msg_local="$tag-local-$RANDOM" msg_cluster="$tag-cluster-$RANDOM"

    say "Sending a matching message (should reach the LOCAL session)"
    send_match "$msg_local"
    if wait_for_local_message "$msg_local" 120; then
        ok "local session received it"
    else
        bad "local session did not receive the matching message within 120s"
        print_diagnostics
        exit 1
    fi

    say "Sending a non-matching message (should reach the CLUSTER consumer)"
    send_nomatch "$msg_cluster"
    local waited=0
    until cluster_consumer_logs | grep -qF "$msg_cluster"; do
        if [ "$waited" -ge 120 ]; then
            bad "cluster consumer did not receive the non-matching message within 120s"
            print_diagnostics
            exit 1
        fi
        sleep 3
        waited=$((waited + 3))
    done
    ok "cluster consumer received it"
}

expect_ready() {
    local status
    status=$(wait_for_session_settled 300) || status=""
    if [ "$status" != "ready" ]; then
        bad "expected Ready, got '${status:-nothing within 5 min}'"
        print_diagnostics
        exit 1
    fi
    ok "split session is Ready"
}

finish_case() {
    stop_local_consumer
    say "Waiting for the session to clean up"
    wait_for_sessions_gone 300 || true
    kubectl rollout status -n "$NAMESPACE" "$DEPLOYMENT" --timeout=180s >/dev/null
}

require_cluster
wait_for_operator_api
deploy_env
strategy_off
fix_off >/dev/null

# ---------------------------------------------------------------- case 1
say "Case 1: plain client config - expecting INCONSISTENT_GROUP_PROTOCOL at once"
CASE_START=$(now_utc)
LOCAL_MAY_FAIL_FAST=1 start_local_consumer
status=$(wait_for_session_settled 180) || status=""
ERROR_TEXT=""
case "$status" in
    ready | "")
        bad "case 1: expected a protocol error, got '${status:-nothing within 180s}'"
        print_diagnostics
        exit 1
        ;;
    local-exited) ERROR_TEXT=$(cat "$LOCAL_LOG" 2>/dev/null) ;;
    *) ERROR_TEXT="$status" ;;
esac
# The forwarder can die right after the session went Ready; the session is then
# torn down before the CLI connects, the CLI only sees a 410, and the real
# cause survives only in the operator log.
if ! echo "$ERROR_TEXT" | grep -q "INCONSISTENT_GROUP_PROTOCOL"; then
    info "CLI output has no Kafka error (got: $(echo "$ERROR_TEXT" | grep -m1 -oE 'ReconnectNotPossible|StartFailed|[A-Za-z]+Error' || echo none)); checking the operator log"
    ERROR_TEXT=$(operator_logs_since "$CASE_START" | grep -F "Split runtime error" | grep -F "confluent-consumer-group" | tail -1)
fi
if echo "$ERROR_TEXT" | grep -q "INCONSISTENT_GROUP_PROTOCOL"; then
    ok "cooperative-sticky group rejected the range,roundrobin forwarder"
else
    bad "session failed for another reason"
    echo "$ERROR_TEXT" | tail -15
    print_diagnostics
    exit 1
fi
finish_case

# ---------------------------------------------------------------- case 2
say "Case 2: partition.assignment.strategy=cooperative-sticky - expecting a shared group with no wait"
strategy_on
start_local_consumer
START_TS=$(date +%s)
expect_ready
info "ready after $(( $(date +%s) - START_TS ))s"
assert_traffic_splits "strategy"
finish_case
strategy_off

# ---------------------------------------------------------------- case 3
say "Case 3: mirrord.temporary_group_id=true - expecting the join once the old pod leaves"
fix_on >/dev/null
start_local_consumer
START_TS=$(date +%s)
expect_ready
PATCHED_GROUP=$(patched_group_value)
case "$PATCHED_GROUP" in
    mirrord-tmp-*) ok "KAFKA_GROUP_ID patched to '$PATCHED_GROUP'" ;;
    *)
        bad "KAFKA_GROUP_ID patch missing or unexpected: '$PATCHED_GROUP'"
        print_diagnostics
        exit 1
        ;;
esac
kubectl rollout status -n "$NAMESPACE" "$DEPLOYMENT" --timeout=180s >/dev/null
info "ready and rolled out after $(( $(date +%s) - START_TS ))s"
assert_traffic_splits "tmpgroup"
finish_case
fix_off >/dev/null

echo ""
say "Summary"
echo "  case 1  PASS  plain config fails with INCONSISTENT_GROUP_PROTOCOL"
echo "  case 2  PASS  partition.assignment.strategy=cooperative-sticky shares the group, traffic splits"
echo "  case 3  PASS  mirrord.temporary_group_id works, traffic splits"
