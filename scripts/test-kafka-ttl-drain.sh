#!/bin/bash
#
# Test Kafka split TTL forwarding behavior.
#
# Verifies that during the split TTL window (after last session closes), the
# forwarder keeps copying messages to the fallback topic so the patched
# workload is not starved.
#
# Prerequisites:
#   - minikube running with operator deployed
#   - task kafka:ttl-drain:deploy   (sets up the kafka-ttl-drain overlay)
#
# Usage:
#   ./test-kafka-ttl-drain.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$SANDBOX_DIR/apps/kafka-consumer"
MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"
NAMESPACE="test-mirrord"
CONFIG_FILE="$SANDBOX_DIR/k8s/overlays/kafka-ttl-drain/mirrord.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

get_kafka_pod() {
    kubectl get pod -n "$NAMESPACE" -l app=kafka-cluster -o jsonpath='{.items[0].metadata.name}'
}

send_message() {
    local msg="$1"
    local user_id="$2"
    local pod
    pod=$(get_kafka_pod)

    if [ -n "$user_id" ]; then
        printf 'user_id:%s|%s' "$user_id" "$msg" | \
            kubectl exec -i -n "$NAMESPACE" "$pod" -- \
            /opt/kafka/bin/kafka-console-producer.sh \
            --bootstrap-server localhost:9092 \
            --topic test-topic \
            --property 'parse.headers=true' \
            --property 'headers.delimiter=|' 2>/dev/null
    else
        printf '%s' "$msg" | \
            kubectl exec -i -n "$NAMESPACE" "$pod" -- \
            /opt/kafka/bin/kafka-console-producer.sh \
            --bootstrap-server localhost:9092 \
            --topic test-topic 2>/dev/null
    fi
}

count_consumer_messages_single() {
    local since="$1"
    local count
    count=$(kubectl logs -n "$NAMESPACE" -l app=kafka-consumer --since="${since}s" 2>/dev/null | \
        grep -c "Message Received" 2>/dev/null || true)
    echo "${count:-0}" | tr -d '[:space:]'
}

info "Building Kafka consumer..."
cd "$APPS_DIR"
go build -o /tmp/kafka-consumer main.go 2>/dev/null

info ""
info "=== TEST: TTL Forwarding ==="
info "Verifies that after the last session closes, messages still arrive"
info "at the consumer pod during the split TTL window (30s)."
info ""

info "Starting mirrord session..."
SESSION_LOG="/tmp/kafka-ttl-session.log"
$MIRRORD_BIN exec -f "$CONFIG_FILE" -- /tmp/kafka-consumer > "$SESSION_LOG" 2>&1 &
SESSION_PID=$!
info "Session PID: $SESSION_PID"
sleep 20

if ! kill -0 $SESSION_PID 2>/dev/null; then
    fail "Session died prematurely:"
    cat "$SESSION_LOG"
    exit 1
fi

info "Sending matched message (should go to local consumer)..."
send_message "matched-msg-1" "test-user"
sleep 3

if grep -q "matched-msg-1" "$SESSION_LOG"; then
    info "Local consumer received matched message."
else
    warn "Local consumer did not receive matched message (may need more time)."
fi

info "Sending unmatched message (should go to remote consumer)..."
BEFORE_COUNT=$(count_consumer_messages_single 30)
send_message "unmatched-before-kill" ""
sleep 3
AFTER_COUNT=$(count_consumer_messages_single 30)

if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
    info "Remote consumer received unmatched message while session active."
else
    warn "Remote consumer did not pick up unmatched message yet."
fi

info ""
info "Killing session (TTL window starts now, 30s)..."
kill $SESSION_PID 2>/dev/null || true
wait $SESSION_PID 2>/dev/null || true
info "Session terminated."

sleep 10

info ""
info "Sending messages during TTL window (forwarder should still be active)..."
BEFORE_TTL_COUNT=$(count_consumer_messages_single 20)

for i in 1 2 3; do
    send_message "ttl-window-msg-$i" ""
    sleep 1
done

sleep 5
AFTER_TTL_COUNT=$(count_consumer_messages_single 20)
TTL_RECEIVED=$((AFTER_TTL_COUNT - BEFORE_TTL_COUNT))

info ""
if [ "$TTL_RECEIVED" -ge 3 ]; then
    info "PASS: Consumer received $TTL_RECEIVED messages during TTL window."
    info "(Forwarder stayed active after session closed.)"
elif [ "$TTL_RECEIVED" -gt 0 ]; then
    warn "PARTIAL: Consumer received $TTL_RECEIVED/3+ messages during TTL window."
else
    fail "FAIL: Consumer received 0 messages during TTL window."
    fail "The forwarder may have stopped when the session closed (old bug)."
fi

info ""
info "Test complete."
