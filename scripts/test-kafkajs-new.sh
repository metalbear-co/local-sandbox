#!/bin/bash
#
# Proves the KafkaJS Kafka-splitting fix on your LOCAL operator code.
#
# Two phases:
#   A. fix OFF  - the split session must fail LOUDLY with a diagnosable error
#                 naming INCONSISTENT_GROUP_PROTOCOL and pointing at
#                 mirrord.temporary_group_id (old code starved silently).
#   B. fix ON   - the split works end-to-end: the workload's group env is
#                 patched to a mirrord-tmp-* group, a matching message reaches
#                 the local session, a non-matching one reaches the cluster
#                 consumer.
#
# Spawns the cluster if needed. The LOCAL operator must be running via
# `task operator:dev` in another terminal (it steals from the deployed one).
#
# Usage:
#   ./test-kafkajs-new.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kafkajs-lib.sh"

trap stop_local_consumer EXIT

require_cluster

say "This test runs against your LOCAL operator build"
echo "  In another terminal:  cd $SANDBOX_DIR && task operator:dev"
if ! confirm "Is 'task operator:dev' running and ready?"; then
    bad "start the local operator first, then re-run this script"
    exit 1
fi

wait_for_operator_api
deploy_env

# ---------------------------------------------------------------- phase A
say "Phase A: fix OFF - expecting a LOUD, diagnosable session error"
fix_off >/dev/null

start_local_consumer

# The error can surface two ways: on the session CR (startError), or - when the
# CLI exits on it and the session is already cleaned up - in the local mirrord
# output. Accept either, but insist on the diagnosable message.
status=$(wait_for_session_settled 120) || status=""
ERROR_TEXT=""
case "$status" in
    ready | "")
        bad "phase A failed: expected a session error, got '${status:-nothing within 120s}'"
        print_diagnostics
        exit 1
        ;;
    local-exited)
        info "local mirrord run exited; checking its output for the error"
        ERROR_TEXT=$(cat "$LOCAL_LOG" 2>/dev/null)
        ;;
    *)
        ok "split session failed instead of hanging: $status"
        ERROR_TEXT="$status"
        ;;
esac
if echo "$ERROR_TEXT" | grep -q "INCONSISTENT_GROUP_PROTOCOL"; then
    ok "error names the protocol clash"
else
    bad "error does not mention INCONSISTENT_GROUP_PROTOCOL"
    print_diagnostics
    exit 1
fi
if echo "$ERROR_TEXT" | grep -q "temporary_group_id"; then
    ok "error points at the mirrord.temporary_group_id fix"
else
    bad "error does not point at mirrord.temporary_group_id"
    print_diagnostics
    exit 1
fi
echo ""
echo "--- the error, as the user sees it ---"
echo "$ERROR_TEXT" | grep -B1 -A6 "INCONSISTENT_GROUP_PROTOCOL" | head -15
echo "--------------------------------------"

stop_local_consumer
say "Waiting for the failed session to clean up"
wait_for_sessions_gone 120 || true

# ---------------------------------------------------------------- phase B
say "Phase B: fix ON - expecting a working split"
fix_on

start_local_consumer

status=$(wait_for_session_settled 300) || status=""
if [ "$status" != "ready" ]; then
    bad "phase B failed: expected Ready, got '${status:-nothing within 5 min}'"
    print_diagnostics
    exit 1
fi
ok "split session is Ready"

say "Checking the workload was repointed to a temporary group"
PATCHED_GROUP=$(patched_group_value)
case "$PATCHED_GROUP" in
    mirrord-tmp-*)
        ok "KAFKA_GROUP_ID patched to '$PATCHED_GROUP'"
        ;;
    "")
        bad "no KAFKA_GROUP_ID patch found on the workload"
        print_diagnostics
        exit 1
        ;;
    *)
        bad "KAFKA_GROUP_ID patched to unexpected value '$PATCHED_GROUP'"
        print_diagnostics
        exit 1
        ;;
esac

say "Waiting for the patched consumer pod to come up"
kubectl rollout status -n "$NAMESPACE" deployment/kafkajs-consumer --timeout=180s

MSG_LOCAL="new-code-local-$RANDOM"
MSG_CLUSTER="new-code-cluster-$RANDOM"

say "Sending a matching message (should reach the LOCAL session)"
send_match "$MSG_LOCAL"
if wait_for_local_message "$MSG_LOCAL" 90; then
    ok "local session received it"
else
    bad "local session did not receive the matching message within 90s"
    print_diagnostics
    exit 1
fi

say "Sending a non-matching message (should reach the CLUSTER consumer)"
send_nomatch "$MSG_CLUSTER"
waited=0
until cluster_consumer_logs | grep -qF "$MSG_CLUSTER"; do
    if [ "$waited" -ge 90 ]; then
        bad "cluster consumer did not receive the non-matching message within 90s"
        print_diagnostics
        exit 1
    fi
    sleep 3
    waited=$((waited + 3))
done
ok "cluster consumer received it"

echo ""
say "FIX PROVEN on your local operator"
echo "  - fix OFF: loud diagnosable error (phase A)"
echo "  - fix ON : group patched to '$PATCHED_GROUP', filtering works both ways (phase B)"
cleanup_env
