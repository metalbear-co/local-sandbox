#!/bin/bash
#
# Proves what a `mirrord.temporary_group_id` split reports when the app does not
# read its consumer group from the env var the operator patches.
#
# Background: the split moves the deployed pods to a temporary group by
# rewriting the env var under appConfig.groupId. If the app builds its group id
# from somewhere else, the pods restart on the original group, the operator can
# never join it, and the join wait runs out. On operator >= 3.204.0 the error
# says the previous pods were still members and, if they had already been
# replaced, that the app does not read its group id from the patched env var.
#
# Case:
#   1. The split config's groupId points at KAFKA_GROUP_ID_UNUSED, which the
#      KafkaJS consumer never reads. With the temporary group on and a short
#      mirrord.group_join_timeout, the session must fail and the error must say
#      the app does not read its group id from the env var.
#
# Prerequisites: a sandbox cluster and an operator >= 3.204.0 (deployed release
# or `task operator:dev`).
#
# Usage:
#   ./test-kafkajs-patch-ignored.sh
#
# Env knobs:
#   SHORT_TIMEOUT     mirrord.group_join_timeout for the run (default 30)
#   MIRRORD_BIN       mirrord binary (default: mirrord)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kafkajs-lib.sh"

SHORT_TIMEOUT="${SHORT_TIMEOUT:-30}"
PROPERTY_LIST="mirrordpropertylist/kafkajs-kafka-connection"

set_join_timeout() {
    kubectl patch -n "$NAMESPACE" "$PROPERTY_LIST" --type=json -p "[
        {\"op\": \"add\", \"path\": \"/spec/properties/-\", \"value\": {\"name\": \"mirrord.group_join_timeout\", \"value\": \"$1\"}}
    ]" >/dev/null
}

on_exit() {
    stop_local_consumer
    (cd "$SANDBOX_DIR" && task kafkajs:ignored-env:off >/dev/null 2>&1) || true
    fix_on >/dev/null 2>&1 || true
}
trap on_exit EXIT

require_cluster
wait_for_operator_api
deploy_env

say "Pointing the split's groupId at an env var the app never reads"
(cd "$SANDBOX_DIR" && task kafkajs:ignored-env:on)
fix_on >/dev/null
set_join_timeout "$SHORT_TIMEOUT"

# ---------------------------------------------------------------- case 1
say "Case 1: temporary group on, app ignores the patch - expecting a failure that says so"
CASE_START=$(now_utc)
start_local_consumer
# The session goes Ready while the operator is still retrying the join, so
# wait for the failure itself, not for the first status.
ERROR_TEXT=$(wait_for_session_failure $((SHORT_TIMEOUT + 240)) "$CASE_START") || ERROR_TEXT=""
if [ -z "$ERROR_TEXT" ]; then
    bad "case 1: expected the session to fail within $((SHORT_TIMEOUT + 240))s"
    print_diagnostics
    exit 1
fi
if echo "$ERROR_TEXT" | grep -q "does not read its group id"; then
    ok "error explains the app is not reading the patched group env var"
else
    bad "session failed but the error does not explain the ignored patch (operator older than 3.204.0?)"
    echo "$ERROR_TEXT" | tail -15
    print_diagnostics
    exit 1
fi
show_error_excerpt "$ERROR_TEXT" "does not read its group id"

stop_local_consumer
say "Waiting for the failed session to clean up"
wait_for_sessions_gone 300 || true

echo ""
say "Summary"
echo "  case 1  PASS  ignored patch fails after ${SHORT_TIMEOUT}s with a message naming the cause"
