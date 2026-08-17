#!/usr/bin/env bash
#
# End-to-end test for Kafka queue splitting with protobuf payload decoding
# (`payload_protobuf` in the split queues config).
#
# Simulates a CDC-style flow on the local minikube sandbox:
#   1. (optional, DEPLOY=1) deploy the Kafka broker + consumer overlay.
#   2. write a .proto schema and hand-encode raw protobuf messages (no JSON
#      envelope, no schema registry prefix) with python3 - no protoc needed.
#   3. run the consumer locally under mirrord with a `payload_protobuf` +
#      `jq_filter` split config targeting decoded fields
#      (.payload_decoded.merchant_id / .payload_decoded.metadata.transactionType).
#   4. produce matching and non-matching protobuf messages plus a non-protobuf
#      payload, then verify: matching ones reach ONLY the local session, the
#      rest (merchant miss, transaction-type miss, undecodable) stay with the
#      deployed consumer.
#
# Prerequisites:
#   - minikube (bearkube) running with an operator built from a branch that
#     advertises KafkaQueueSplittingWithProtobufDecoding
#   - `task kafka:deploy` done (or run with DEPLOY=1)
#   - a mirrord CLI built with payload_protobuf support (released CLIs reject
#     the config key). Defaults to the locally-built debug binary.
#
# Usage:
#   ./test-kafka-protobuf-split.sh
#   DEPLOY=1 ./test-kafka-protobuf-split.sh   # (re)deploy the kafka overlay first
#   KEEP=1 ./test-kafka-protobuf-split.sh     # leave the session running at the end
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE       kafka overlay namespace (default test-mirrord)
#   TOPIC           topic to split (default test-topic)
#   SETTLE_WAIT     seconds to let messages drain after producing (default 15)
#   READY_TIMEOUT   seconds to wait for the split session to go Ready (default 120)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="${NAMESPACE:-test-mirrord}"
TOPIC="${TOPIC:-test-topic}"
SETTLE_WAIT="${SETTLE_WAIT:-15}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
KEEP="${KEEP:-0}"
DEPLOY="${DEPLOY:-0}"

# A released CLI rejects the new `payload_protobuf` key (deny_unknown_fields),
# so prefer the locally-built binary from the sibling mirrord checkout.
LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/kafka-protobuf-split.XXXXXX)"
SESSION_LOG="$WORKDIR/session.log"
SESSION_PID=""
# Message identifiers carry a per-run tag: the original topic keeps messages from earlier
# runs, and a fresh session's forwarder can replay them into its fallback topic, so an
# untagged grep would match stale copies.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6)"

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

get_kafka_pod() {
  kubectl get pod -n "$NAMESPACE" -l app=kafka-cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Streams a raw payload file into the topic as a single record. The console
# producer is line-based, which is why the generator below guarantees the
# payloads carry no 0x0a byte.
produce() {
  local payload_file="$1" pod
  pod=$(get_kafka_pod)
  kubectl exec -i -n "$NAMESPACE" "$pod" -- \
    /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server localhost:9092 \
    --topic "$TOPIC" <"$payload_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Kafka protobuf split test"

command -v python3 >/dev/null 2>&1 || { fail "python3 is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { fail "kubectl is required"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not runnable: $MIRRORD_BIN"; exit 1; }
info "mirrord CLI: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | tr -d '\n'))"
info "workdir: $WORKDIR"

if [ "$DEPLOY" = 1 ]; then
  info "deploying the kafka overlay (task kafka:deploy)..."
  (cd "$SANDBOX_DIR" && task kafka:deploy)
fi

if [ -z "$(get_kafka_pod)" ]; then
  fail "no kafka broker pod in namespace $NAMESPACE - run 'task kafka:deploy' or rerun with DEPLOY=1"
  exit 1
fi

# ---------------------------------------------------------------------------
# Schema + payloads
# ---------------------------------------------------------------------------
header "Generating schema and protobuf payloads"

# Field numbers start at 2 on purpose: field 1 with wire type 2 has tag byte
# 0x0a (newline), which the line-based console producer would split on. The
# generator additionally asserts no payload byte is 0x0a or 0x0d (string and
# nested-message lengths of 10 or 13 would smuggle one in).
cat >"$WORKDIR/record.proto" <<'EOF'
syntax = "proto3";
package test.cdc;
message Metadata { string transactionType = 2; }
message Record {
    string custom_record_identifier = 2;
    int64 merchant_id = 3;
    Metadata metadata = 4;
}
EOF

python3 - "$WORKDIR" "$RUN_TAG" <<'EOF'
import sys

workdir = sys.argv[1]
tag = sys.argv[2]

def varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)

def record(identifier: str, merchant_id: int, transaction_type: str) -> bytes:
    meta = bytes([0x12, len(transaction_type)]) + transaction_type.encode()
    body = bytes([0x12, len(identifier)]) + identifier.encode()
    body += b"\x18" + varint(merchant_id)
    body += bytes([0x22, len(meta)]) + meta
    # The console producer decodes each line as UTF-8 text, so every byte must be plain
    # ASCII or it gets replaced with U+FFFD and the decoded fields are silently wrong.
    # In particular varints must stay below 128 (one ASCII byte).
    assert b"\n" not in body and b"\r" not in body, f"payload for {identifier} contains a line break"
    assert all(b < 0x80 for b in body), f"payload for {identifier} contains a non-ASCII byte"
    return body

payloads = {
    # merchant + transaction type match the jq program -> local session
    "match-a": record(f"proto-{tag}-match-aa", 77, "PAYMENT"),
    "match-b": record(f"proto-{tag}-match-bb", 77, "PAYMENT"),
    # decodes fine but the merchant does not match -> deployed consumer
    "merchant-miss": record(f"proto-{tag}-merchant-miss", 42, "PAYMENT"),
    # merchant matches but the nested transaction type does not -> deployed consumer
    "type-miss": record(f"proto-{tag}-type-miss", 77, "REFUND"),
    # not protobuf at all - decoding fails, never matches -> deployed consumer
    "not-protobuf": f"proto-{tag}-not-protobuf".encode(),
}

for name, payload in payloads.items():
    with open(f"{workdir}/{name}.bin", "wb") as f:
        f.write(payload)
    print(f"  {name}: {payload.hex()}")
EOF
[ $? -eq 0 ] || { fail "payload generation failed"; exit 1; }
info "schema: $WORKDIR/record.proto"

# ---------------------------------------------------------------------------
# mirrord config + local session
# ---------------------------------------------------------------------------
header "Starting the mirrord session"

cat >"$WORKDIR/mirrord.json" <<EOF
{
    "operator": true,
    "target": {
        "path": "deployment/kafka-consumer",
        "namespace": "$NAMESPACE"
    },
    "feature": {
        "split_queues": {
            "$TOPIC": {
                "queue_type": "Kafka",
                "payload_protobuf": {
                    "schema_file": "$WORKDIR/record.proto",
                    "message_type": "test.cdc.Record"
                },
                "jq_filter": ".payload_decoded.merchant_id == 77 and .payload_decoded.metadata.transactionType == \"PAYMENT\""
            }
        }
    }
}
EOF

info "building the consumer..."
(cd "$SANDBOX_DIR/apps/kafka-consumer" && go build -o /tmp/kafka-consumer main.go) || {
  fail "go build failed"
  exit 1
}

info "session log streams to: $SESSION_LOG (tail -f it in another terminal)"
"$MIRRORD_BIN" exec -f "$WORKDIR/mirrord.json" -- /tmp/kafka-consumer >"$SESSION_LOG" 2>&1 &
SESSION_PID=$!
info "session pid: $SESSION_PID"

info "waiting for the split session to go Ready (up to ${READY_TIMEOUT}s)..."
ready=1
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    fail "mirrord session died - last log lines:"
    tail -20 "$SESSION_LOG"
    fail "if the error mentions an unsupported feature, the deployed operator predates protobuf decoding"
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
[ "$ready" = 0 ] || { tail -20 "$SESSION_LOG"; exit 1; }

# Give the local consumer a moment to join its per-session topic.
sleep 5

# ---------------------------------------------------------------------------
# Produce and verify
# ---------------------------------------------------------------------------
header "Producing protobuf messages"

for name in match-a merchant-miss type-miss match-b not-protobuf; do
  produce "$WORKDIR/$name.bin"
  info "produced $name"
done

info "letting messages drain for ${SETTLE_WAIT}s..."
sleep "$SETTLE_WAIT"

header "Verifying routing"

# The Go consumer logs each record's value verbatim; the ASCII identifier
# strings embedded in the binary payloads make them greppable on both sides.
CLUSTER_LOGS="$WORKDIR/cluster-consumer.log"
kubectl logs -n "$NAMESPACE" -l app=kafka-consumer --tail=200 >"$CLUSTER_LOGS" 2>/dev/null

grep -q "proto-$RUN_TAG-match-aa" "$SESSION_LOG"; check "local session received match-a" $?
grep -q "proto-$RUN_TAG-match-bb" "$SESSION_LOG"; check "local session received match-b" $?
! grep -Eq "proto-$RUN_TAG-(merchant-miss|type-miss|not-protobuf)" "$SESSION_LOG"
check "local session received ONLY matching messages" $?
grep -q "proto-$RUN_TAG-merchant-miss" "$CLUSTER_LOGS"; check "deployed consumer received merchant-miss" $?
grep -q "proto-$RUN_TAG-type-miss" "$CLUSTER_LOGS"; check "deployed consumer received type-miss (nested field decoded)" $?
grep -q "proto-$RUN_TAG-not-protobuf" "$CLUSTER_LOGS"; check "deployed consumer received the undecodable payload" $?
! grep -Eq "proto-$RUN_TAG-match-(aa|bb)" "$CLUSTER_LOGS"
check "deployed consumer did NOT receive the stolen messages" $?

header "Result"
if [ "$FAILURES" = 0 ]; then
  pass "protobuf payload decoding routed every message correctly"
else
  fail "$FAILURES check(s) failed - session log: $SESSION_LOG, cluster log: $CLUSTER_LOGS"
  exit 1
fi
