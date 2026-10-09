#!/usr/bin/env bash
#
# End-to-end test for Kafka queue splitting with queue names in a MOUNTED
# CONFIGMAP FILE (`volume` sources in MirrordSplitConfig) instead of env vars.
#
# Simulates the customer shape on the local minikube sandbox: a Spring-style
# application.yaml in a centrally managed ConfigMap holds the topic name and
# consumer group under nested keys, and the consumer reads them from the file.
#
#   1. (optional, DEPLOY=1) deploy the Kafka broker overlay first.
#   2. create a per-run topic, the application.yaml ConfigMap, and a consumer
#      deployment that parses topic+group OUT OF THE MOUNTED FILE at startup
#      (no topic/group env vars anywhere in its pod spec).
#   3. apply a MirrordSplitConfig whose appConfig uses `volume` sources with
#      valueSelectors into the yaml.
#   4. run a local consumer under mirrord that ALSO reads the mounted file
#      (through mirrord's remote fs) to learn its topic.
#   5. verify the whole mechanism:
#        - the deployment's pods are re-pointed at a labeled ConfigMap COPY
#          whose yaml carries a fallback topic; the original CM is untouched
#        - the local app's read of the same file returns a THIRD content with
#          its session topic (served in-flight by the operator proxy)
#        - messages route by filter: match -> local, no-match -> deployed
#        - on session end the copy is deleted and the volume restored
#
# Prerequisites:
#   - minikube (bearkube) running with an operator built from a branch that
#     supports `volume` sources (vladr/int-159 or later)
#   - `task kafka:deploy` done at least once (or run with DEPLOY=1) - the
#     broker and the kafka-consumer:local image are reused
#
# Usage:
#   ./test-kafka-configmap-split.sh
#   DEPLOY=1 ./test-kafka-configmap-split.sh  # (re)deploy the kafka overlay first
#   KEEP=1 ./test-kafka-configmap-split.sh    # leave the session running at the end
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE       kafka overlay namespace (default test-mirrord)
#   SETTLE_WAIT     seconds to let messages drain after producing (default 15)
#   READY_TIMEOUT   seconds to wait for the split session to go Ready (default 120)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="${NAMESPACE:-test-mirrord}"
SETTLE_WAIT="${SETTLE_WAIT:-15}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
KEEP="${KEEP:-0}"
DEPLOY="${DEPLOY:-0}"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/kafka-configmap-split.XXXXXX)"
SESSION_LOG="$WORKDIR/session.log"
SESSION_PID=""
# The cluster resources (deployment, ConfigMap, split config) have fixed
# names, so two concurrent runs rewrite each other's config and tear down each
# other's splits - refuse to start instead.
LOCK_DIR="/tmp/kafka-configmap-split.lock"
# Per-run tag: topic and messages are unique per run so a fresh session's
# forwarder cannot replay another run's leftovers into its fallback.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"
TOPIC="file-topic-$RUN_TAG"
GROUP="file-group-$RUN_TAG"
CONSUMER="kafka-file-consumer"
CONFIG_MAP="file-worker-config"
VOLUME="app-config"
MOUNT_PATH="/app-config"

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

# macOS has no `timeout`, and the Kafka CLI tools retry forever against a
# broker that is mid-restart, so bound every broker exec with a watchdog.
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

# The pod being Running does not mean the broker accepts connections yet (it
# restarts on its own sometimes); wait until the admin API actually answers.
wait_for_broker() {
  local pod deadline=$((SECONDS + 90))
  while [ "$SECONDS" -lt "$deadline" ]; do
    pod=$(get_kafka_pod)
    if [ -n "$pod" ] && run_with_timeout 15 kubectl exec -n "$NAMESPACE" "$pod" -- \
      /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

get_consumer_pod() {
  kubectl get pod -n "$NAMESPACE" -l "app=$CONSUMER" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null
}

# The ConfigMap name the consumer's newest pod mounts through the volume.
mounted_config_map() {
  local pod
  pod=$(get_consumer_pod)
  [ -n "$pod" ] || return 1
  kubectl get pod -n "$NAMESPACE" "$pod" \
    -o jsonpath="{.spec.volumes[?(@.name=='$VOLUME')].configMap.name}" 2>/dev/null
}

# Bounded and retried: the sandbox broker restarts under host load, which can
# kill the pod mid-exec. The payload travels via a file with an explicit
# redirect because `run_with_timeout` backgrounds its command, and background
# commands get stdin from /dev/null - a pipe into it would feed the producer
# nothing while still exiting 0.
produce() { # produce <user_id-or-empty> <message>
  local user_id="$1" message="$2" pod attempt payload="$WORKDIR/payload.txt"
  if [ -n "$user_id" ]; then
    printf 'user_id:%s|%s' "$user_id" "$message" >"$payload"
  else
    printf '%s' "$message" >"$payload"
  fi
  for attempt in 1 2 3; do
    wait_for_broker || break
    pod=$(get_kafka_pod)
    if [ -n "$user_id" ]; then
      if run_with_timeout 60 bash -c "kubectl exec -i -n '$NAMESPACE' '$pod' -- \
        /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
        --topic '$TOPIC' --property parse.headers=true --property 'headers.delimiter=|' \
        <'$payload'" 2>/dev/null; then
        return 0
      fi
    else
      if run_with_timeout 60 bash -c "kubectl exec -i -n '$NAMESPACE' '$pod' -- \
        /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
        --topic '$TOPIC' <'$payload'" 2>/dev/null; then
        return 0
      fi
    fi
    warn "producing attempt $attempt failed (broker restarted?), retrying..."
  done
  return 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Kafka mounted-configmap split test"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run of this script is active (its lock: $LOCK_DIR; rmdir it if stale)"
  exit 1
fi
command -v kubectl >/dev/null 2>&1 || { fail "kubectl is required"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not runnable: $MIRRORD_BIN"; exit 1; }
info "mirrord CLI: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | tr -d '\n'))"
info "workdir: $WORKDIR"
info "topic: $TOPIC  group: $GROUP"

if [ "$DEPLOY" = 1 ]; then
  info "deploying the kafka overlay (task kafka:deploy)..."
  (cd "$SANDBOX_DIR" && task kafka:deploy)
fi

if [ -z "$(get_kafka_pod)" ]; then
  fail "no kafka broker pod in namespace $NAMESPACE - run 'task kafka:deploy' or rerun with DEPLOY=1"
  exit 1
fi

info "waiting for the broker to answer (it restarts on its own sometimes)..."
wait_for_broker || {
  fail "broker never answered on the admin API - check: kubectl logs -n $NAMESPACE -l app=kafka-cluster"
  exit 1
}

kubectl get crd mirrordsplitconfigs.queues.mirrord.metalbear.co >/dev/null 2>&1 || {
  fail "MirrordSplitConfig CRD not installed - the deployed operator predates the unified splitting CRDs"
  exit 1
}

# `mirrord exec` dies with a generic "operator unreachable" error if the
# operator (or `task operator:dev`) is still starting, so wait for its
# APIService to answer before opening a session.
info "waiting for the operator APIService to answer..."
operator_up=1
for _ in $(seq 1 60); do
  if kubectl get --raw /apis/operator.metalbear.co/v1 >/dev/null 2>&1; then
    operator_up=0
    break
  fi
  sleep 2
done
if [ "$operator_up" != 0 ]; then
  fail "the operator APIService never answered - is the operator (or 'task operator:dev') running?"
  exit 1
fi

# ---------------------------------------------------------------------------
# Cluster resources: topic, ConfigMap, file-reading consumer, split config
# ---------------------------------------------------------------------------
header "Creating the file-configured consumer"

run_with_timeout 45 kubectl exec -n "$NAMESPACE" "$(get_kafka_pod)" -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --if-not-exists --topic "$TOPIC" --partitions 1 >/dev/null || {
  fail "topic creation timed out - the broker is likely still starting; rerun in a minute"
  exit 1
}
info "topic created"

# The customer shape: nested keys inside application.yaml, mounted as a file.
# The consumer deployment has NO topic/group env vars - the wrapper parses them
# out of the mounted file at startup, so only the `volume` sources can resolve
# them.
kubectl apply -n "$NAMESPACE" -f - <<EOF >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIG_MAP
data:
  application.yaml: |
    kafka:
      consumer:
        group: $GROUP
        topic:
          main:
            name: $TOPIC
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $CONSUMER
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $CONSUMER
  template:
    metadata:
      labels:
        app: $CONSUMER
    spec:
      volumes:
      - name: $VOLUME
        configMap:
          name: $CONFIG_MAP
      containers:
      - name: consumer
        image: kafka-consumer:local
        imagePullPolicy: Never
        command: ["/bin/sh", "-c"]
        args:
        - |
          topic=\$(sed -n 's/^ *name: //p' $MOUNT_PATH/application.yaml | head -1)
          group=\$(sed -n 's/^ *group: //p' $MOUNT_PATH/application.yaml | head -1)
          echo "file consumer starting: topic=\$topic group=\$group"
          export KAFKA_TOPIC_NAME="\$topic" KAFKA_GROUP_ID="\$group"
          exec /app/consumer
        env:
        - name: KAFKA_BOOTSTRAP_SERVERS
          value: "kafka-cluster.$NAMESPACE.svc.cluster.local:9092"
        volumeMounts:
        - name: $VOLUME
          mountPath: $MOUNT_PATH
---
apiVersion: queues.mirrord.metalbear.co/v1
kind: MirrordSplitConfig
metadata:
  name: kafka-file-split-config
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $CONSUMER
  drainTimeout: 0
  queues:
  - id: file-topic
    kind: kafka
    clientConfig: kafka-test-config
    appConfig:
      topic:
      - volume:
          name: $VOLUME
          file: application.yaml
        valueSelector: .kafka.consumer.topic.main.name
      groupId:
      - volume:
          name: $VOLUME
          file: application.yaml
        valueSelector: .kafka.consumer.group
EOF
info "ConfigMap + deployment + MirrordSplitConfig applied"

# The ConfigMap content is per-run (new topic), so make sure the running pod
# read the fresh file rather than an older run's.
kubectl rollout restart -n "$NAMESPACE" "deployment/$CONSUMER" >/dev/null
kubectl rollout status -n "$NAMESPACE" "deployment/$CONSUMER" --timeout=120s >/dev/null || {
  fail "consumer deployment never became ready"
  exit 1
}
POD_BEFORE=$(get_consumer_pod)
info "consumer running (pod $POD_BEFORE), reading topic+group from the mounted file"

# ---------------------------------------------------------------------------
# Local session: an app that reads the SAME mounted file through mirrord
# ---------------------------------------------------------------------------
header "Starting the mirrord session"

cat >"$WORKDIR/mirrord.json" <<EOF
{
    "operator": true,
    "target": {
        "path": "deployment/$CONSUMER",
        "namespace": "$NAMESPACE"
    },
    "feature": {
        "split_queues": {
            "file-topic": {
                "queue_type": "Kafka",
                "message_filter": {
                    "user_id": "test-user"
                }
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

# Mirrors the deployed wrapper: read the mounted file (remotely, through the
# operator), parse topic+group out of it, run the consumer with them. The file
# content it sees is the proxy-served session content, not the pod's.
cat >"$WORKDIR/local-app.sh" <<EOF
#!/bin/sh
echo "--- mounted file as seen locally ---"
cat $MOUNT_PATH/application.yaml
echo "--- end of file ---"
topic=\$(sed -n 's/^ *name: //p' $MOUNT_PATH/application.yaml | head -1)
group=\$(sed -n 's/^ *group: //p' $MOUNT_PATH/application.yaml | head -1)
echo "local consumer starting: topic=\$topic group=\$group"
KAFKA_TOPIC_NAME="\$topic" KAFKA_GROUP_ID="\$group" \\
  KAFKA_BOOTSTRAP_SERVERS="kafka-cluster.$NAMESPACE.svc.cluster.local:9092" \\
  exec /tmp/kafka-consumer
EOF
chmod +x "$WORKDIR/local-app.sh"

info "session log streams to: $SESSION_LOG (tail -f it in another terminal)"
"$MIRRORD_BIN" exec -f "$WORKDIR/mirrord.json" -- sh "$WORKDIR/local-app.sh" >"$SESSION_LOG" 2>&1 &
SESSION_PID=$!
info "session pid: $SESSION_PID"

info "waiting for the split session to go Ready (up to ${READY_TIMEOUT}s)..."
ready=1
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    fail "mirrord session died - last log lines:"
    tail -20 "$SESSION_LOG"
    fail "if resolution failed, the deployed operator likely predates volume sources"
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

# ---------------------------------------------------------------------------
# Verify the three views of the file
# ---------------------------------------------------------------------------
header "Verifying the ConfigMap copy and the three file views"

info "waiting for the consumer pod to restart onto the copy..."
copy_name=""
for _ in $(seq 1 120); do
  mounted=$(mounted_config_map)
  if [ -n "$mounted" ] && [ "$mounted" != "$CONFIG_MAP" ] && [ "$(get_consumer_pod)" != "$POD_BEFORE" ]; then
    copy_name="$mounted"
    break
  fi
  sleep 2
done
[ -n "$copy_name" ]; check "consumer volume re-pointed at an operator copy" $?
[ -n "$copy_name" ] || { fail "volume still mounts: $(mounted_config_map)"; exit 1; }
info "copy ConfigMap: $copy_name"

kubectl get configmap -n "$NAMESPACE" "$copy_name" \
  -o jsonpath='{.metadata.labels.operator\.metalbear\.co/queue-split-cm-copy}' 2>/dev/null \
  | grep -q true
check "copy carries the queue-split-cm-copy ownership label" $?

fallback_topic=$(kubectl get configmap -n "$NAMESPACE" "$copy_name" \
  -o jsonpath='{.data.application\.yaml}' | sed -n 's/^ *name: //p' | head -1)
info "fallback topic in the copy: $fallback_topic"
[ -n "$fallback_topic" ] && [ "$fallback_topic" != "$TOPIC" ]
check "copy carries a fallback topic different from the original" $?

kubectl get configmap -n "$NAMESPACE" "$CONFIG_MAP" -o jsonpath='{.data.application\.yaml}' \
  | grep -q "name: $TOPIC"
check "original ConfigMap still carries the original topic (never modified)" $?

info "waiting for the local app to read the file..."
session_topic=""
for _ in $(seq 1 60); do
  session_topic=$(sed -n 's/^local consumer starting: topic=\([^ ]*\).*/\1/p' "$SESSION_LOG" | head -1)
  [ -n "$session_topic" ] && break
  sleep 1
done
info "session topic the local app read: ${session_topic:-<none>}"
[ -n "$session_topic" ] && [ "$session_topic" != "$TOPIC" ] && [ "$session_topic" != "$fallback_topic" ]
check "local app read a session-specific topic (not the original, not the fallback)" $?

CLUSTER_LOGS="$WORKDIR/cluster-consumer.log"
kubectl logs -n "$NAMESPACE" "$(get_consumer_pod)" --tail=50 >"$CLUSTER_LOGS" 2>/dev/null
grep -q "topic=$fallback_topic" "$CLUSTER_LOGS"
check "deployed consumer read the fallback topic from the copy" $?

# ---------------------------------------------------------------------------
# Produce and verify routing
# ---------------------------------------------------------------------------
header "Producing messages"

# Give the local consumer a moment to join its per-session topic.
sleep 5

produce "test-user" "tolocal-$RUN_TAG: hello local session"
info "produced matching message (user_id=test-user)"
produce "" "tocluster-$RUN_TAG: hello cluster consumer"
info "produced non-matching message (no header)"

info "letting messages drain for ${SETTLE_WAIT}s..."
sleep "$SETTLE_WAIT"

header "Verifying routing"

kubectl logs -n "$NAMESPACE" "$(get_consumer_pod)" --tail=200 >"$CLUSTER_LOGS" 2>/dev/null

grep -q "tolocal-$RUN_TAG" "$SESSION_LOG"; check "local session received the matching message" $?
! grep -q "tocluster-$RUN_TAG" "$SESSION_LOG"; check "local session did NOT receive the non-matching message" $?
grep -q "tocluster-$RUN_TAG" "$CLUSTER_LOGS"; check "deployed consumer received the non-matching message" $?
! grep -q "tolocal-$RUN_TAG" "$CLUSTER_LOGS"; check "deployed consumer did NOT receive the stolen message" $?

# ---------------------------------------------------------------------------
# Teardown: the copy must disappear and the volume must be restored
# ---------------------------------------------------------------------------
if [ "$KEEP" = 1 ]; then
  header "Result (KEEP=1 - skipping teardown checks)"
else
  header "Stopping the session and verifying cleanup"

  kill "$SESSION_PID" 2>/dev/null || true
  wait "$SESSION_PID" 2>/dev/null || true
  SESSION_PID=""
  info "session stopped, waiting for teardown (copy deletion + volume restore)..."

  restored=1
  for _ in $(seq 1 120); do
    if ! kubectl get configmap -n "$NAMESPACE" "$copy_name" >/dev/null 2>&1 \
      && [ "$(mounted_config_map)" = "$CONFIG_MAP" ]; then
      restored=0
      break
    fi
    sleep 2
  done
  check "copy deleted and volume restored to $CONFIG_MAP" "$restored"

  header "Result"
fi

if [ "$FAILURES" = 0 ]; then
  pass "mounted-configmap splitting worked end to end"
  info "cluster resources ($CONSUMER, $CONFIG_MAP, the split config) are left for reuse"
else
  fail "$FAILURES check(s) failed - session log: $SESSION_LOG, cluster log: $CLUSTER_LOGS"
  exit 1
fi
