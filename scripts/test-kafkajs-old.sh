#!/bin/bash
#
# Reproduces the KafkaJS Kafka-splitting bug on a RELEASED operator (old code).
#
# The operator's librdkafka forwarder joins the KafkaJS app's consumer group,
# but the two share no partition-assignment protocol name (librdkafka:
# range/roundrobin/cooperative-sticky, KafkaJS: RoundRobinAssigner). The broker
# rejects the join with INCONSISTENT_GROUP_PROTOCOL, and on old operators the
# result is a broken split: either a cryptic startup error, or a "healthy"
# session that never delivers a message while the repointed app starves.
#
# Spawns the cluster if needed, deploys a released operator, deploys the env,
# runs the flow, and asserts the failure is present. On an inconclusive result
# the env is left deployed and diagnostics are printed.
#
# Usage:
#   ./test-kafkajs-old.sh                 uses OPERATOR_VERSION=latest
#   OPERATOR_VERSION=3.248.0 ./test-kafkajs-old.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kafkajs-lib.sh"

# Only reap the local process on exit; the env is cleaned on success and kept
# for inspection on failure.
trap stop_local_consumer EXIT

require_cluster

say "Deploying a RELEASED operator (${OPERATOR_VERSION:-latest}) - the code WITHOUT the fix"
(cd "$SANDBOX_DIR" && task operator:use VERSION="${OPERATOR_VERSION:-latest}")

wait_for_operator_api
deploy_env
fix_off >/dev/null # released operators do not know the property; keep it off

start_local_consumer

say "Waiting for the split session to settle (Ready or error, up to 3 min)"
SESSION_ERROR=""
if outcome=$(wait_for_session_settled 180); then
    case "$outcome" in
        ready)
            info "split session reports Ready - checking whether messages actually flow"
            ;;
        local-exited)
            info "local mirrord run exited; its output may carry the error"
            SESSION_ERROR=$(grep -i "inconsistent" "$LOCAL_LOG" | head -1 || true)
            ;;
        *)
            SESSION_ERROR="$outcome"
            ok "split session failed to start: $outcome"
            ;;
    esac
else
    info "split session settled on neither Ready nor an error within 3 min"
fi

MSG="old-code-probe-$RANDOM"
say "Sending a message that matches the split filter (should reach the local consumer)"
send_match "$MSG"

if wait_for_local_message "$MSG" 45; then
    bad "local consumer received the message - the bug did NOT reproduce on this operator"
    cleanup_env
    exit 1
fi
ok "local consumer received nothing within 45s"

# The old operator can surface the error late (after its restart wait), so
# check the session status again now.
if [ -z "$SESSION_ERROR" ]; then
    SESSION_ERROR=$(session_error_message)
fi

say "Looking for the protocol clash in operator, session, and app logs"
EVIDENCE=""
ERROR_EXCERPT=""
if [ -n "$SESSION_ERROR" ]; then
    EVIDENCE="session/CLI error: $SESSION_ERROR"
elif grep -qi "inconsistent" "$LOCAL_LOG" 2>/dev/null; then
    EVIDENCE="local mirrord output mentions the inconsistent group protocol"
    ERROR_EXCERPT=$(grep -i "inconsistent" "$LOCAL_LOG" | tail -2)
elif operator_logs | grep -qi "inconsistent"; then
    EVIDENCE="operator logs mention the inconsistent group protocol"
    ERROR_EXCERPT=$(operator_logs | grep -i "inconsistent" | tail -2)
elif cluster_consumer_logs | grep -qi "inconsistent"; then
    EVIDENCE="cluster consumer logs mention the inconsistent group protocol"
    ERROR_EXCERPT=$(cluster_consumer_logs | grep -i "inconsistent" | tail -2)
elif [ -z "$(sessions_json | grep '"items": \[\]')" ] && sessions_json | grep -q '"ready"'; then
    # A Ready session that delivers nothing IS the silent-starvation variant,
    # even when the logs are quiet.
    EVIDENCE="session claims Ready while no message was delivered (silent starvation)"
fi

echo ""
if [ -n "$EVIDENCE" ]; then
    say "BUG REPRODUCED on the released operator"
    echo "  - matching message never reached the local session"
    echo "  - $EVIDENCE"
    echo "  - cause: INCONSISTENT_GROUP_PROTOCOL between the forwarder (librdkafka) and KafkaJS"
    if [ -n "$ERROR_EXCERPT" ]; then
        echo ""
        echo "--- the error, as the operator saw it ---"
        echo "$ERROR_EXCERPT"
        echo "-----------------------------------------"
    fi
    echo ""
    echo "Now run ./test-kafkajs-new.sh against your local operator to see the fix."
    cleanup_env
else
    bad "message did not arrive, but the failure mode is unclear from logs alone"
    print_diagnostics
    exit 1
fi
