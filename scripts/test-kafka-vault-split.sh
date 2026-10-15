#!/usr/bin/env bash
#
# End-to-end test for Kafka queue splitting with queue names injected by REAL
# HashiCorp Vault (vault-agent-injector) - `podFile` sources in
# MirrordSplitConfig instead of env vars or ConfigMap volumes.
#
# The customer shape on the local minikube sandbox: the topic and consumer
# group live in a Vault KV secret; vault-agent-injector renders them into
# /vault/secrets/kafka-config inside the pod, and the consumer parses that
# file at startup. Nothing in the pod spec or any ConfigMap carries the names.
#
#   1. (optional, DEPLOY=1) deploy the Kafka broker overlay first.
#   2. write a per-run topic+group into Vault, create the topic, and deploy an
#      annotated consumer whose only source of the names is the injected file.
#   3. apply a MirrordSplitConfig whose appConfig uses `podFile` sources with
#      valueSelectors into the rendered yaml.
#   4. run a local consumer under mirrord that ALSO reads the injected file
#      (through mirrord's remote fs) to learn its topic.
#   5. verify the whole mechanism:
#        - the operator reads the original names through a mirrord agent for a
#          running pod (resolution succeeds even though no API object holds
#          them) - with `pods/exec` stripped from the operator's ClusterRole
#          for the run (STRIP_EXEC_RBAC=1, the default), proving the split
#          needs no exec permission
#        - an operator-owned qs-pf Secret appears carrying the rewritten
#          (fallback) content plus the cached original
#        - the restarted pods shadow-mount that Secret over the exact file
#          path in the app container - and NOT in the vault-agent sidecar
#        - the deployed consumer reads the fallback topic, the local app
#          reads a THIRD content with its session topic, Vault stays untouched
#        - messages route by filter: match -> local, no-match -> deployed
#        - on session end the Secret is deleted and the shadow mount is gone
#
# Prerequisites:
#   - minikube (bearkube) running with an operator built from a branch that
#     supports `podFile` sources, with the matching CRDs applied
#     (task operator:crds; task operator:dev applies them itself)
#   - Vault installed in dev mode with the injector enabled, configured with
#     the `kafka-app` kubernetes-auth role and policy (see the setup block in
#     this script's header commit, or run with VAULT_SETUP=1 to do it here)
#   - `task kafka:deploy` done at least once (or run with DEPLOY=1)
#
# Usage:
#   ./test-kafka-vault-split.sh
#   DEPLOY=1 ./test-kafka-vault-split.sh       # (re)deploy the kafka overlay first
#   VAULT_SETUP=1 ./test-kafka-vault-split.sh  # (re)configure vault auth/policy/role
#   KEEP=1 ./test-kafka-vault-split.sh         # leave the session running at the end
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE       kafka overlay namespace (default test-mirrord)
#   VAULT_NS        namespace vault runs in (default vault)
#   SETTLE_WAIT     seconds to let messages drain after producing (default 15)
#   READY_TIMEOUT   seconds to wait for the split session to go Ready (default 120)
#   STRIP_EXEC_RBAC 1 (default) removes the pods/exec rule from the operator's
#                   ClusterRole for the run and restores it on exit; 0 leaves RBAC alone
#   OPERATOR_CLUSTERROLE  name of the operator's ClusterRole (default mirrord-operator)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="${NAMESPACE:-test-mirrord}"
VAULT_NS="${VAULT_NS:-vault}"
SETTLE_WAIT="${SETTLE_WAIT:-15}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
KEEP="${KEEP:-0}"
DEPLOY="${DEPLOY:-0}"
VAULT_SETUP="${VAULT_SETUP:-0}"
STRIP_EXEC_RBAC="${STRIP_EXEC_RBAC:-1}"
OPERATOR_CLUSTERROLE="${OPERATOR_CLUSTERROLE:-mirrord-operator}"
# Set once the pods/exec rule has been stripped; cleanup puts it back from here.
CLUSTERROLE_BACKUP=""

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/kafka-vault-split.XXXXXX)"
SESSION_LOG="$WORKDIR/session.log"
SESSION_PID=""
# The cluster resources (deployment, vault secret, split config) have fixed
# names, so two concurrent runs rewrite each other's config and tear down each
# other's splits - refuse to start instead.
LOCK_DIR="/tmp/kafka-vault-split.lock"
# Per-run tag: topic and messages are unique per run so a fresh session's
# forwarder cannot replay another run's leftovers into its fallback.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"
TOPIC="vault-topic-$RUN_TAG"
GROUP="vault-group-$RUN_TAG"
CONSUMER="kafka-vault-consumer"
SERVICE_ACCOUNT="kafka-vault-consumer"
VAULT_KV_PATH="secret/kafka-app"
INJECTED_FILE="/vault/secrets/kafka-config"

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
  if [ -n "$CLUSTERROLE_BACKUP" ] && [ -f "$CLUSTERROLE_BACKUP" ]; then
    # The backup carries the resourceVersion from before the strip; replace
    # refuses a stale one, so drop it and let the server assign a fresh one.
    if jq 'del(.metadata.resourceVersion)' "$CLUSTERROLE_BACKUP" | kubectl replace -f - >/dev/null 2>&1; then
      info "restored the pods/exec rule on ClusterRole $OPERATOR_CLUSTERROLE"
    else
      warn "failed to restore ClusterRole $OPERATOR_CLUSTERROLE - reapply it from $CLUSTERROLE_BACKUP or re-run task operator:use"
    fi
  fi
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

# The subPath volume mount shadowing the injected file in the consumer
# container of the newest pod, if any: prints the backing volume name.
shadow_mount_volume() { # shadow_mount_volume <container-name>
  local pod
  pod=$(get_consumer_pod)
  [ -n "$pod" ] || return 1
  kubectl get pod -n "$NAMESPACE" "$pod" -o json 2>/dev/null | jq -r --arg c "$1" --arg p "$INJECTED_FILE" \
    '.spec.containers[] | select(.name == $c) | (.volumeMounts // [])[] | select(.mountPath == $p) | .name'
}

# The operator-owned qs-pf Secret in the namespace (found by label, since its
# name prefix depends on the operator's isolation marker).
pod_file_secret() {
  kubectl get secrets -n "$NAMESPACE" \
    -l operator.metalbear.co/queue-split-pod-file=true \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

vault_exec() { # vault_exec <vault cli args...>
  kubectl exec -n "$VAULT_NS" vault-0 -- vault "$@"
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
header "Kafka Vault-injected (podFile) split test"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run of this script is active (its lock: $LOCK_DIR; rmdir it if stale)"
  exit 1
fi
command -v kubectl >/dev/null 2>&1 || { fail "kubectl is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not runnable: $MIRRORD_BIN"; exit 1; }
info "mirrord CLI: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | tr -d '\n'))"
info "workdir: $WORKDIR"
info "topic: $TOPIC  group: $GROUP"

kubectl get pod -n "$VAULT_NS" vault-0 >/dev/null 2>&1 || {
  fail "vault-0 not found in namespace $VAULT_NS - install it first:"
  echo "  helm repo add hashicorp https://helm.releases.hashicorp.com"
  echo "  helm install vault hashicorp/vault -n vault --create-namespace \\"
  echo "    --set server.dev.enabled=true --set injector.enabled=true"
  exit 1
}

if [ "$VAULT_SETUP" = 1 ]; then
  info "configuring vault kubernetes auth, policy and role..."
  kubectl exec -n "$VAULT_NS" vault-0 -- sh -c '
    set -e
    vault auth enable kubernetes 2>/dev/null || true
    vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
    vault policy write kafka-app - <<POLICY
path "secret/data/kafka-app" {
  capabilities = ["read"]
}
POLICY
    vault write auth/kubernetes/role/kafka-app \
      bound_service_account_names='"$SERVICE_ACCOUNT"' \
      bound_service_account_namespaces='"$NAMESPACE"' \
      policies=kafka-app ttl=24h
  ' || { fail "vault setup failed"; exit 1; }
fi

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

# The in-cluster CRD must know `podFile`, or the server prunes it silently
# from the applied split config and resolution fails with a confusing miss.
# `grep` without -q so it consumes the whole (large) JSON: under pipefail,
# an early -q exit SIGPIPEs kubectl and fails the pipeline on a match.
kubectl get crd mirrordsplitconfigs.queues.mirrord.metalbear.co -o json 2>/dev/null | grep podFile >/dev/null || {
  fail "the installed MirrordSplitConfig CRD has no podFile field - apply the local CRDs first: task operator:crds"
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
# Take pods/exec away from the operator for the run. The dev operator reads
# the deployed pod's service-account token through mirrord's remote fs, so it
# authenticates as that service account and this bites it too. A split that
# still goes Ready proves the podFile read needs no exec permission.
# ---------------------------------------------------------------------------
if [ "$STRIP_EXEC_RBAC" = 1 ]; then
  header "Stripping pods/exec from the operator ClusterRole"
  if ! kubectl get clusterrole "$OPERATOR_CLUSTERROLE" -o json >"$WORKDIR/clusterrole.json" 2>/dev/null; then
    fail "ClusterRole $OPERATOR_CLUSTERROLE not found - set OPERATOR_CLUSTERROLE, or STRIP_EXEC_RBAC=0 to skip"
    exit 1
  fi
  if jq -e '.rules[] | select(.resources == ["pods/exec"])' "$WORKDIR/clusterrole.json" >/dev/null; then
    CLUSTERROLE_BACKUP="$WORKDIR/clusterrole.json"
    jq 'del(.rules[] | select(.resources == ["pods/exec"]))' "$CLUSTERROLE_BACKUP" | kubectl replace -f - >/dev/null || {
      fail "could not strip the pods/exec rule from ClusterRole $OPERATOR_CLUSTERROLE"
      exit 1
    }
    info "pods/exec removed from ClusterRole $OPERATOR_CLUSTERROLE for this run (restored on exit)"
  else
    info "ClusterRole $OPERATOR_CLUSTERROLE grants no pods/exec - nothing to strip (chart from the agent-read branch)"
  fi
  # `pods/exec` as a positional would be read as a pod NAMED exec; the
  # subresource needs the flag. kube-rs exec upgrades with GET, so both verbs
  # must be denied for the proof to hold. `can-i` exits 1 on "no", so the
  # answer is captured instead of piped (pipefail would flag the deny).
  exec_denied=0
  for verb in get create; do
    answer=$(kubectl auth can-i "$verb" pods --subresource=exec \
      --as="system:serviceaccount:mirrord:$OPERATOR_CLUSTERROLE" -n "$NAMESPACE" 2>/dev/null || true)
    [ "$answer" = no ] || exec_denied=1
  done
  check "operator service account cannot exec into pods during this run (get + create denied)" "$exec_denied"
fi

# ---------------------------------------------------------------------------
# Cluster resources: topic, Vault secret, injected consumer, split config
# ---------------------------------------------------------------------------
header "Creating the Vault-configured consumer"

run_with_timeout 45 kubectl exec -n "$NAMESPACE" "$(get_kafka_pod)" -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --if-not-exists --topic "$TOPIC" --partitions 1 >/dev/null || {
  fail "topic creation timed out - the broker is likely still starting; rerun in a minute"
  exit 1
}
info "topic created"

vault_exec kv put "$VAULT_KV_PATH" topic="$TOPIC" group="$GROUP" >/dev/null || {
  fail "writing the per-run topic+group into vault failed"
  exit 1
}
info "vault secret written: $VAULT_KV_PATH topic=$TOPIC group=$GROUP"

# The customer shape: vault-agent-injector renders the KV secret into
# $INJECTED_FILE via the template annotation. The consumer deployment has NO
# topic/group env vars and NO config volume - the wrapper parses the names out
# of the injected file at startup, so only `podFile` sources can resolve them.
kubectl apply -n "$NAMESPACE" -f - <<EOF >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT
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
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "kafka-app"
        vault.hashicorp.com/agent-inject-secret-kafka-config: "secret/data/kafka-app"
        vault.hashicorp.com/agent-inject-template-kafka-config: |
          {{- with secret "secret/data/kafka-app" -}}
          kafka:
            consumer:
              group: {{ .Data.data.group }}
              topic:
                main:
                  name: {{ .Data.data.topic }}
          {{- end -}}
    spec:
      serviceAccountName: $SERVICE_ACCOUNT
      containers:
      - name: consumer
        image: kafka-consumer:local
        imagePullPolicy: Never
        command: ["/bin/sh", "-c"]
        args:
        - |
          topic=\$(sed -n 's/^ *name: //p' $INJECTED_FILE | head -1)
          group=\$(sed -n 's/^ *group: //p' $INJECTED_FILE | head -1)
          echo "vault consumer starting: topic=\$topic group=\$group"
          export KAFKA_TOPIC_NAME="\$topic" KAFKA_GROUP_ID="\$group"
          exec /app/consumer
        env:
        - name: KAFKA_BOOTSTRAP_SERVERS
          value: "kafka-cluster.$NAMESPACE.svc.cluster.local:9092"
---
apiVersion: queues.mirrord.metalbear.co/v1
kind: MirrordSplitConfig
metadata:
  name: kafka-vault-split-config
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $CONSUMER
  drainTimeout: 0
  queues:
  - id: vault-topic
    kind: kafka
    clientConfig: kafka-test-config
    appConfig:
      topic:
      - podFile:
          path: $INJECTED_FILE
        valueSelector: .kafka.consumer.topic.main.name
      groupId:
      - podFile:
          path: $INJECTED_FILE
        valueSelector: .kafka.consumer.group
EOF
info "ServiceAccount + deployment + MirrordSplitConfig applied"

# The vault secret content is per-run (new topic), so make sure the running
# pod's injected file was rendered from the fresh secret rather than an older
# run's.
kubectl rollout restart -n "$NAMESPACE" "deployment/$CONSUMER" >/dev/null
kubectl rollout status -n "$NAMESPACE" "deployment/$CONSUMER" --timeout=180s >/dev/null || {
  fail "consumer deployment never became ready - check the vault injector: kubectl logs -n $VAULT_NS deploy/vault-agent-injector"
  exit 1
}
POD_BEFORE=$(get_consumer_pod)
kubectl get pod -n "$NAMESPACE" "$POD_BEFORE" -o jsonpath='{.spec.containers[*].name}' | grep -q vault-agent || {
  fail "the consumer pod has no vault-agent sidecar - injector annotations were not picked up"
  exit 1
}
info "consumer running (pod $POD_BEFORE) with vault-agent injected, reading topic+group from $INJECTED_FILE"

# ---------------------------------------------------------------------------
# Local session: an app that reads the SAME injected file through mirrord
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
            "vault-topic": {
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

# Mirrors the deployed wrapper: read the injected file (remotely, through the
# operator), parse topic+group out of it, run the consumer with them. The file
# content it sees is the proxy-served session content, not the pod's.
cat >"$WORKDIR/local-app.sh" <<EOF
#!/bin/sh
echo "--- injected file as seen locally ---"
cat $INJECTED_FILE
echo "--- end of file ---"
topic=\$(sed -n 's/^ *name: //p' $INJECTED_FILE | head -1)
group=\$(sed -n 's/^ *group: //p' $INJECTED_FILE | head -1)
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
    fail "if resolution failed, check that the operator supports podFile sources and could spawn an agent for the pod"
    exit 1
  fi
  if kubectl get mirrordclustersplitsessions.queues.mirrord.metalbear.co -o json 2>/dev/null \
    | grep '"ready"' >/dev/null; then
    ready=0
    break
  fi
  sleep 1
done
check "split session reached Ready (operator read the names through a mirrord agent, no pods/exec)" "$ready"
[ "$ready" = 0 ] || { tail -20 "$SESSION_LOG"; exit 1; }

# ---------------------------------------------------------------------------
# Verify the qs-pf Secret, the shadow mount, and the three file views
# ---------------------------------------------------------------------------
header "Verifying the copy Secret, the shadow mount, and the three file views"

secret_name=$(pod_file_secret)
[ -n "$secret_name" ]; check "operator-owned qs-pf Secret exists (label queue-split-pod-file)" $?
[ -n "$secret_name" ] || exit 1
info "copy Secret: $secret_name"

# The Secret holds two keys per file: the rewritten content (mounted) and the
# cached original (read back on restart/refresh instead of reading a
# patched pod).
keys=$(kubectl get secret -n "$NAMESPACE" "$secret_name" -o json | jq -r '.data | keys[]')
echo "$keys" | grep -q '\.orig$'; check "Secret caches the original content (.orig key)" $?
rewritten_key=$(echo "$keys" | grep -v '\.orig$' | head -1)

orig_content=$(kubectl get secret -n "$NAMESPACE" "$secret_name" -o json \
  | jq -r ".data[\"${rewritten_key}.orig\"]" | base64 -d)
echo "$orig_content" | grep -q "name: $TOPIC"
check "cached original carries the original topic" $?

fallback_topic=$(kubectl get secret -n "$NAMESPACE" "$secret_name" -o json \
  | jq -r ".data[\"$rewritten_key\"]" | base64 -d | sed -n 's/^ *name: //p' | head -1)
info "fallback topic in the rewritten content: $fallback_topic"
[ -n "$fallback_topic" ] && [ "$fallback_topic" != "$TOPIC" ]
check "rewritten content carries a fallback topic different from the original" $?

info "waiting for the consumer pod to restart onto the shadow mount..."
shadow_volume=""
for _ in $(seq 1 120); do
  if [ "$(get_consumer_pod)" != "$POD_BEFORE" ]; then
    shadow_volume=$(shadow_mount_volume consumer)
    [ -n "$shadow_volume" ] && break
  fi
  sleep 2
done
[ -n "$shadow_volume" ]; check "consumer container shadow-mounts the Secret over $INJECTED_FILE" $?
[ -n "$shadow_volume" ] || { fail "newest pod: $(get_consumer_pod)"; exit 1; }
info "shadow mount backed by volume: $shadow_volume"

vault_agent_shadow=$(shadow_mount_volume vault-agent)
[ -z "$vault_agent_shadow" ]
check "vault-agent sidecar keeps its original view (no shadow mount)" $?

vault_exec kv get -field=topic "$VAULT_KV_PATH" 2>/dev/null | grep -q "^$TOPIC$"
check "Vault secret still carries the original topic (never modified)" $?

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
kubectl logs -n "$NAMESPACE" "$(get_consumer_pod)" -c consumer --tail=50 >"$CLUSTER_LOGS" 2>/dev/null
grep -q "topic=$fallback_topic" "$CLUSTER_LOGS"
check "deployed consumer read the fallback topic through the shadow mount" $?

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

kubectl logs -n "$NAMESPACE" "$(get_consumer_pod)" -c consumer --tail=200 >"$CLUSTER_LOGS" 2>/dev/null

grep -q "tolocal-$RUN_TAG" "$SESSION_LOG"; check "local session received the matching message" $?
! grep -q "tocluster-$RUN_TAG" "$SESSION_LOG"; check "local session did NOT receive the non-matching message" $?
grep -q "tocluster-$RUN_TAG" "$CLUSTER_LOGS"; check "deployed consumer received the non-matching message" $?
! grep -q "tolocal-$RUN_TAG" "$CLUSTER_LOGS"; check "deployed consumer did NOT receive the stolen message" $?

# ---------------------------------------------------------------------------
# Teardown: the Secret must disappear and the shadow mount must be gone
# ---------------------------------------------------------------------------
if [ "$KEEP" = 1 ]; then
  header "Result (KEEP=1 - skipping teardown checks)"
else
  header "Stopping the session and verifying cleanup"

  kill "$SESSION_PID" 2>/dev/null || true
  wait "$SESSION_PID" 2>/dev/null || true
  SESSION_PID=""
  info "session stopped, waiting for teardown (Secret deletion + unshadowed pod)..."

  restored=1
  for _ in $(seq 1 120); do
    if [ -z "$(pod_file_secret)" ] && [ -z "$(shadow_mount_volume consumer)" ]; then
      restored=0
      break
    fi
    sleep 2
  done
  check "Secret deleted and the pod restarted without the shadow mount" "$restored"

  header "Result"
fi

if [ "$FAILURES" = 0 ]; then
  pass "Vault-injected (podFile) splitting worked end to end against real vault-agent-injector"
  info "cluster resources ($CONSUMER, the split config, the vault secret) are left for reuse"
else
  fail "$FAILURES check(s) failed - session log: $SESSION_LOG, cluster log: $CLUSTER_LOGS"
  exit 1
fi
