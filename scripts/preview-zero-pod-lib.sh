# Shared plumbing for the zero-pod preview split A/B scripts:
#   test-preview-zero-pod-old.sh   scenario against the DEPLOYED operator (unlabeled session)
#   test-preview-zero-pod-new.sh   scenario against a LOCAL `task operator:dev` (marker-labeled)
#
# The scenario in both: scale the kafka overlay's consumer to zero replicas (the
# autoscaler-at-rest state), then create a queue-split-only PreviewSession CR against it,
# exactly like the CLI would. Operators without zero-pod support fail target resolution
# with "no Pod is ready to be a session target"; operators with it come up Ready and split.
#
# Not executable on its own - source it.

set -uo pipefail

NAMESPACE="${NAMESPACE:-test-mirrord}"
TOPIC="${TOPIC:-test-topic}"
CONSUMER_DEPLOY="${CONSUMER_DEPLOY:-kafka-consumer}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
KEEP="${KEEP:-0}"
RUN_TAG="$(date +%s)-$RANDOM"

# ---------------------------------------------------------------------------
# Output helpers: gum when available, plain text otherwise.
# ---------------------------------------------------------------------------
HAVE_GUM=0
command -v gum >/dev/null 2>&1 && [ -t 1 ] && HAVE_GUM=1

banner() {
  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border rounded --padding "0 2" --margin "1 0" --bold --foreground 212 "$@"
  else
    echo; printf '== %s\n' "$@"; echo
  fi
}
say()  { if [ "$HAVE_GUM" = 1 ]; then gum style --bold --foreground 39 "==> $*"; else echo "==> $*"; fi; }
ok()   { if [ "$HAVE_GUM" = 1 ]; then gum style --foreground 42 "  ✓ $*"; else echo "  OK: $*"; fi; }
warn() { if [ "$HAVE_GUM" = 1 ]; then gum style --foreground 214 "  ! $*"; else echo "  WARN: $*"; fi; }
err()  { if [ "$HAVE_GUM" = 1 ]; then gum style --bold --foreground 196 "  ✗ $*"; else echo "  FAIL: $*"; fi; }

verdict() { # verdict <pass|fail> <lines...>
  local color=42 title="PASS"
  [ "$1" = fail ] && { color=196; title="FAIL"; }
  shift
  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border double --padding "0 2" --margin "1 0" --bold --foreground "$color" "$title" "$@"
  else
    echo; echo "== $title =="; printf '%s\n' "$@"; echo
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  say "Preflight: cluster, kafka overlay, operator"

  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
    || { err "namespace $NAMESPACE not found - run: task kafka:deploy"; return 1; }
  kubectl get deploy "$CONSUMER_DEPLOY" -n "$NAMESPACE" >/dev/null 2>&1 \
    || { err "deployment $CONSUMER_DEPLOY not found in $NAMESPACE - run: task kafka:deploy"; return 1; }
  kubectl get pod -n "$NAMESPACE" -l app=kafka-cluster \
    -o jsonpath='{.items[0].metadata.name}' >/dev/null 2>&1 \
    || { err "kafka broker pod not found in $NAMESPACE - run: task kafka:deploy"; return 1; }
  kubectl get crd previewsessions.preview.mirrord.metalbear.co >/dev/null 2>&1 \
    || { err "PreviewSession CRD missing - the operator chart needs operator.previewEnv=true (and task operator:crds for local dev)"; return 1; }
  kubectl get pods -n mirrord -l app=mirrord-operator --no-headers 2>/dev/null | grep -q Running \
    || warn "no Running mirrord-operator pod found in ns mirrord"

  ok "namespace, consumer deployment, broker, and PreviewSession CRD present"
}

# ---------------------------------------------------------------------------
# Scaling
# ---------------------------------------------------------------------------
ORIGINAL_REPLICAS=1

record_and_scale_to_zero() {
  ORIGINAL_REPLICAS=$(kubectl get deploy "$CONSUMER_DEPLOY" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}')
  ORIGINAL_REPLICAS="${ORIGINAL_REPLICAS:-1}"

  say "Scaling $CONSUMER_DEPLOY to 0 replicas (the autoscaler-at-rest state)"
  kubectl scale deploy "$CONSUMER_DEPLOY" -n "$NAMESPACE" --replicas=0 >/dev/null || return 1
  wait_for_consumer_pods 0 90 || return 1
  ok "target has zero pods"
}

scale_consumer() { # scale_consumer <replicas>
  kubectl scale deploy "$CONSUMER_DEPLOY" -n "$NAMESPACE" --replicas="$1" >/dev/null
}

wait_for_consumer_pods() { # wait_for_consumer_pods <count> <timeout-secs>
  local want="$1" timeout="$2" deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # For want>0 count Ready, non-terminating pods. For want==0 count every pod,
    # terminating ones included - a dying pod still shows up in target resolution and
    # muddies the "no pods found" state the scenario is about.
    local n
    n=$(kubectl get pods -n "$NAMESPACE" -l "app=$CONSUMER_DEPLOY" -o json 2>/dev/null | python3 -c '
import json, sys
want_ready = int(sys.argv[1]) > 0
n = 0
for p in json.load(sys.stdin).get("items", []):
    if want_ready:
        if (p.get("metadata") or {}).get("deletionTimestamp"):
            continue
        conds = ((p.get("status") or {}).get("conditions")) or []
        if not any(c.get("type") == "Ready" and c.get("status") == "True" for c in conds):
            continue
    n += 1
print(n)' "$want" 2>/dev/null || echo -1)
    [ "$n" = "$want" ] && return 0
    sleep 2
  done
  err "timed out waiting for $want consumer pod(s) after ${timeout}s"
  return 1
}

# ---------------------------------------------------------------------------
# PreviewSession lifecycle
# ---------------------------------------------------------------------------
create_preview_session() { # create_preview_session <name> [owner-marker] [user-id-filter-regex]
  local name="$1" marker="${2:-}" filter="${3:-^test-user$}"
  local labels=""
  if [ -n "$marker" ]; then
    labels=$'\n  labels:\n    operator.metalbear.co/owner: '"$marker"
  fi

  kubectl delete previewsession "$name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  wait_for_session_gone "$name" 60 || return 1

  cat <<EOF | kubectl apply -f - >/dev/null || return 1
apiVersion: preview.mirrord.metalbear.co/v1alpha
kind: PreviewSession
metadata:
  name: $name
  namespace: $NAMESPACE$labels
spec:
  image: kafka-consumer:local
  key: $name
  target:
    apiVersion: apps/v1
    kind: Deployment
    name: $CONSUMER_DEPLOY
    container: consumer
  ttlSecs: 3600
  replicas: 1
  queueSplitting:
    kafkaQueueFilters:
      $TOPIC:
        user_id: "$filter"
EOF
  ok "PreviewSession $name created${marker:+ (labeled for operator '$marker')}"
}

session_phase() { # session_phase <name>
  kubectl get previewsession "$1" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null
}

session_failure_message() { # session_failure_message <name>
  kubectl get previewsession "$1" -n "$NAMESPACE" \
    -o jsonpath='{.status.failureMessage}' 2>/dev/null
}

# Waits until the session leaves the pending/booting phases. Prints nothing; sets
# WAIT_PHASE (last observed phase, possibly empty) and WAIT_ELAPSED (seconds).
wait_for_settled_phase() { # wait_for_settled_phase <name> <timeout-secs>
  local name="$1" timeout="$2"
  local start=$(date +%s) deadline=$(( $(date +%s) + $2 ))
  WAIT_PHASE=""
  WAIT_ELAPSED=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    WAIT_PHASE=$(session_phase "$name")
    WAIT_ELAPSED=$(( $(date +%s) - start ))
    case "$WAIT_PHASE" in
      Ready|Failed|Idle) return 0 ;;
    esac
    sleep 2
  done
  WAIT_ELAPSED=$(( $(date +%s) - start ))
  return 1
}

wait_for_session_gone() { # wait_for_session_gone <name> <timeout-secs>
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    kubectl get previewsession "$1" -n "$NAMESPACE" >/dev/null 2>&1 || return 0
    sleep 2
  done
  err "PreviewSession $1 still present after ${2}s"
  return 1
}

# ---------------------------------------------------------------------------
# Workload patch assertions
# ---------------------------------------------------------------------------

# Prints the KAFKA_TOPIC_NAME value the split's workload patch wants to inject, or nothing.
patched_topic_env() {
  kubectl get mirrordclusterworkloadpatchrequests -o json 2>/dev/null | python3 -c '
import json, sys
ns = sys.argv[1]
for r in json.load(sys.stdin).get("items", []):
    spec = r.get("spec") or {}
    if (spec.get("workloadRef") or {}).get("namespace") != ns:
        continue
    for env in spec.get("envVars") or []:
        if env.get("variable") == "KAFKA_TOPIC_NAME":
            print(env.get("value", ""))
            sys.exit(0)
' "$NAMESPACE"
}

wait_for_unpatch() { # wait_for_unpatch <timeout-secs>
  local deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -z "$(patched_topic_env)" ] && return 0
    sleep 2
  done
  err "workload patch still sets KAFKA_TOPIC_NAME after ${1}s"
  return 1
}

# ---------------------------------------------------------------------------
# Kafka traffic
# ---------------------------------------------------------------------------
send_kafka_message() { # send_kafka_message <user_id-or-empty> <message>
  local user_id="$1" message="$2" pod
  pod=$(kubectl get pod -n "$NAMESPACE" -l app=kafka-cluster \
    -o jsonpath='{.items[0].metadata.name}') || return 1
  if [ -n "$user_id" ]; then
    printf 'user_id:%s|%s' "$user_id" "$message" | kubectl exec -i -n "$NAMESPACE" "$pod" -- \
      /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
      --topic "$TOPIC" --property 'parse.headers=true' --property 'headers.delimiter=|' 2>/dev/null
  else
    printf '%s' "$message" | kubectl exec -i -n "$NAMESPACE" "$pod" -- \
      /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
      --topic "$TOPIC" 2>/dev/null
  fi
}

wait_for_log_line() { # wait_for_log_line <deployment> <needle> <timeout-secs>
  local deploy="$1" needle="$2" deadline=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if kubectl logs "deploy/$deploy" -n "$NAMESPACE" --all-containers --tail=-1 2>/dev/null \
        | grep -qF "$needle"; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup_scenario() { # cleanup_scenario <session-name>...
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1: leaving session(s) '$*' and the scaled-down consumer in place"
    return 0
  fi
  say "Cleanup: deleting session(s) and restoring $CONSUMER_DEPLOY to $ORIGINAL_REPLICAS replica(s)"
  local name
  for name in "$@"; do
    kubectl delete previewsession "$name" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
    wait_for_session_gone "$name" 90 || true
  done
  wait_for_unpatch 90 || true
  scale_consumer "$ORIGINAL_REPLICAS" || true
}
