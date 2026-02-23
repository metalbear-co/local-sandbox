#!/bin/bash
#
# Test SQS filter behavior on fast disconnect/reconnect
#
# This test verifies what happens when:
# 1. Session 1 starts with SQS filter
# 2. Session 1 disconnects
# 3. Session 2 immediately starts with same filter
# 4. Messages are sent - which session receives them?
#
# Usage:
#   For single-cluster: ./test-sqs-reconnect.sh single
#   For multi-cluster:  ./test-sqs-reconnect.sh multi
#

set -e

MODE="${1:-single}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$SANDBOX_DIR/apps/sqs-consumer"
MIRRORD_BIN="${MIRRORD_BIN:-$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord}"

# Configuration based on mode
if [ "$MODE" = "multi" ]; then
    CONTEXT="mirrord-primary"
    CONFIG_FILE="$SANDBOX_DIR/k8s/overlays/multicluster-sqs/mirrord.json"
    LOCALSTACK_CONTEXT="mirrord-remote-1"
    NAMESPACE="test-multicluster"
    FILTER_FIELD="type"
    FILTER_VALUE="premium"
elif [ "$MODE" = "single" ]; then
    # Use remote-1 directly as a single-cluster test
    CONTEXT="mirrord-remote-1"
    CONFIG_FILE="/tmp/mirrord-single-cluster-test.json"
    LOCALSTACK_CONTEXT="mirrord-remote-1"
    NAMESPACE="test-multicluster"
    FILTER_FIELD="type"
    FILTER_VALUE="premium"
    
    # Create a config file for single-cluster test
    cat > "$CONFIG_FILE" << 'EOF'
{
  "target": {
    "path": "deployment/sqs-consumer",
    "namespace": "test-multicluster"
  },
  "operator": true,
  "feature": {
    "split_queues": {
      "test-queue": {
        "queue_type": "SQS",
        "message_filter": {
          "type": "^premium$"
        }
      }
    },
    "env": true,
    "fs": "local"
  }
}
EOF
    echo "Created single-cluster config at $CONFIG_FILE"
else
    echo "Usage: $0 [single|multi]"
    exit 1
fi

echo "=== SQS Fast Reconnect Test ==="
echo "Mode: $MODE"
echo "Context: $CONTEXT"
echo "Config: $CONFIG_FILE"
echo ""

# Build the consumer
echo "Building SQS consumer..."
cd "$APPS_DIR"
go build -o /tmp/sqs-consumer main.go 2>/dev/null || echo "Build may have failed"

# Set environment
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_REGION=us-east-1
export QUEUE_NAME=test-queue

# Purge queue first
echo "Purging test-queue..."
kubectl --context "$LOCALSTACK_CONTEXT" exec -n localstack deploy/localstack -- \
    awslocal sqs purge-queue --queue-url http://localhost:4566/000000000000/test-queue 2>/dev/null || echo "Queue not found"

# Function to send a test message
send_message() {
    local msg_id="$1"
    local body="{\"$FILTER_FIELD\": \"$FILTER_VALUE\", \"msg_id\": \"$msg_id\", \"timestamp\": \"$(date +%s)\"}"
    echo "Sending message: $body"
    kubectl --context "$LOCALSTACK_CONTEXT" exec -n localstack deploy/localstack -- \
        awslocal sqs send-message \
            --queue-url http://localhost:4566/000000000000/test-queue \
            --message-body "$body" \
            --message-attributes "$FILTER_FIELD={DataType=String,StringValue=$FILTER_VALUE}" \
            --output json 2>/dev/null | jq -r '.MessageId'
}

echo ""
echo "=== Step 1: Start Session 1 ==="
echo "Starting mirrord session 1 in background..."

# Start session 1 in background, capture its output
SESSION1_LOG="/tmp/sqs-session1.log"
$MIRRORD_BIN exec \
    --context "$CONTEXT" \
    -f "$CONFIG_FILE" \
    -- /tmp/sqs-consumer > "$SESSION1_LOG" 2>&1 &
SESSION1_PID=$!

echo "Session 1 PID: $SESSION1_PID"
echo "Waiting for session 1 to connect (10 seconds)..."
sleep 10

# Check if session 1 is still running
if ! kill -0 $SESSION1_PID 2>/dev/null; then
    echo "ERROR: Session 1 died prematurely"
    cat "$SESSION1_LOG"
    exit 1
fi

# Send a test message to session 1
echo ""
echo "=== Step 2: Send message to Session 1 ==="
MSG1_ID=$(send_message "msg-session1-test")
echo "Message ID: $MSG1_ID"
sleep 3

# Check session 1 received it
echo "Session 1 log:"
cat "$SESSION1_LOG" | tail -10

echo ""
echo "=== Step 3: Kill Session 1 (simulating disconnect) ==="
echo "Killing session 1 (PID: $SESSION1_PID)..."
kill $SESSION1_PID 2>/dev/null || true
wait $SESSION1_PID 2>/dev/null || true
echo "Session 1 terminated"

echo ""
echo "=== Step 4: Immediately start Session 2 ==="
echo "Starting mirrord session 2 in background..."

SESSION2_LOG="/tmp/sqs-session2.log"
$MIRRORD_BIN exec \
    --context "$CONTEXT" \
    -f "$CONFIG_FILE" \
    -- /tmp/sqs-consumer > "$SESSION2_LOG" 2>&1 &
SESSION2_PID=$!

echo "Session 2 PID: $SESSION2_PID"
echo "Waiting for session 2 to connect (10 seconds)..."
sleep 10

# Check if session 2 is still running
if ! kill -0 $SESSION2_PID 2>/dev/null; then
    echo "ERROR: Session 2 died prematurely"
    cat "$SESSION2_LOG"
    exit 1
fi

echo ""
echo "=== Step 5: Send messages - which session receives them? ==="

# Send multiple test messages
for i in 1 2 3; do
    MSG_ID=$(send_message "msg-after-reconnect-$i")
    echo "  Message $i ID: $MSG_ID"
    sleep 1
done

echo ""
echo "Waiting for messages to be processed (10 seconds)..."
sleep 10

echo ""
echo "=== Results ==="
echo ""
echo "--- Session 1 Log (should only have msg-session1-test) ---"
cat "$SESSION1_LOG"
echo ""
echo "--- Session 2 Log (should have msg-after-reconnect-*) ---"
cat "$SESSION2_LOG"
echo ""

# Count messages received by each session
SESSION1_COUNT=$(grep -c "\[MSG #" "$SESSION1_LOG" 2>/dev/null || echo "0")
SESSION2_COUNT=$(grep -c "\[MSG #" "$SESSION2_LOG" 2>/dev/null || echo "0")

echo "=== Summary ==="
echo "Session 1 received: $SESSION1_COUNT messages"
echo "Session 2 received: $SESSION2_COUNT messages"
echo ""

# Check for the issue: if old session filter is still active, messages might not reach session 2
# Or they might go to the wrong consumer (in-cluster)
echo "Checking for stale filters..."

if [ "$MODE" = "multi" ]; then
    echo "Checking MirrordSqsSession on remote clusters..."
    echo "Remote-1:"
    kubectl --context mirrord-remote-1 get mirrordsqssession -n mirrord 2>/dev/null || echo "  (none)"
    echo "Remote-2:"
    kubectl --context mirrord-remote-2 get mirrordsqssession -n mirrord 2>/dev/null || echo "  (none)"
    echo ""
    echo "Checking MirrordMultiClusterSession..."
    kubectl --context mirrord-primary get mirrordmulticlustersession -n mirrord 2>/dev/null || echo "  (none)"
elif [ "$MODE" = "single" ]; then
    echo "Checking MirrordSqsSession on remote-1 (single-cluster mode)..."
    kubectl --context mirrord-remote-1 get mirrordsqssession -n mirrord 2>/dev/null || echo "  (none)"
    echo ""
    echo "Checking MirrordClusterSession on remote-1..."
    kubectl --context mirrord-remote-1 get mirrordclustersession -n mirrord 2>/dev/null || echo "  (none)"
fi

echo ""
echo "=== Cleanup ==="
kill $SESSION2_PID 2>/dev/null || true
echo "Test complete!"
