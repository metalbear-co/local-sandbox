#!/usr/bin/env bash
#
# End-to-end test for PREVIEW ENVIRONMENTS composing with mounted-configmap
# queue splitting (the Cashfree shape): the app reads its Kafka topic + group
# from a mounted application.yaml, the split config resolves them with
# `volume` sources, and the preview session overrides config through
# `config_mounts` with PR-specific content.
#
# What the script proves, with two concurrent preview sessions:
#   1. A session WITH a config mount (mounted at a sibling path, like the
#      customer's pipeline) gets its mount content REWRITTEN: the session
#      topic replaces the original, every other user value survives.
#   2. Both sessions get the bound `app-config` volume RETARGETED at a
#      session-rendered ConfigMap copy ({session}-split-vol0) carrying that
#      session's topic - distinct per session, original CM untouched.
#   3. Messages route by filter: each preview pod receives only its own
#      matching message; unmatched messages reach the deployed consumer via
#      the fallback topic.
#   4. Teardown: deleting the sessions garbage-collects the copies and
#      restores the target.
#
# Prerequisites:
#   - minikube (bearkube) with the kafka overlay (task kafka:deploy)
#   - an operator with previewEnv + kafkaSplitting and volume-source support,
#     e.g. `task operator:dev` running the INT-616 branch
#
# Usage:
#   ./test-preview-configmap-split.sh
#   GUIDED=1 ./test-preview-configmap-split.sh # stop at each step and say where to look
#   KEEP=1 ./test-preview-configmap-split.sh   # leave sessions running
#
# Env knobs (all optional):
#   NAMESPACE       kafka overlay namespace (default test-mirrord)
#   READY_TIMEOUT   seconds for a preview session to go Ready (default 300)
#   OPERATOR_ISOLATION_MARKER  marker of the isolated operator to target

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
GUIDED="${GUIDED:-0}"

# Names must not collide with test-kafka-configmap-split.sh, which shares the
# namespace.
CONSUMER_DEPLOY="preview-file-consumer"
CONFIG_MAP="preview-worker-config"
VOLUME="app-config"
MOUNT_PATH="/config"

# shellcheck source=preview-zero-pod-lib.sh
. "$SCRIPT_DIR/preview-zero-pod-lib.sh"

TAG="$(echo "$RUN_TAG" | tr -cd 'a-z0-9' | tail -c 6)"
TOPIC="preview-file-topic-$TAG"
GROUP="preview-file-group-$TAG"
SESSION_A="pcm-mount-$TAG"
SESSION_B="pcm-plain-$TAG"

LOCK_DIR="/tmp/preview-configmap-split.lock"

FAILURES=0
check() { # check <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then ok "$1"; else err "$1"; FAILURES=$((FAILURES + 1)); fi
}

resolve_marker() {
  if [ -n "${OPERATOR_ISOLATION_MARKER:-}" ]; then
    MARKER="$OPERATOR_ISOLATION_MARKER"
    ok "using explicit OPERATOR_ISOLATION_MARKER=$MARKER"
    return 0
  fi
  if pgrep -qf 'target/debug/operator-service'; then
    MARKER=local-dev
    ok "operator:dev detected -> labeling sessions for marker '$MARKER'"
    return 0
  fi
  MARKER=""
  warn "no local dev operator detected - sessions go to the DEPLOYED operator"
}

cleanup() {
  [ "${SHOW_ONLY:-0}" = 1 ] && return 0
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1: leaving sessions and the consumer in place"
    return 0
  fi
  say "Cleanup"
  kubectl delete previewsession "$SESSION_A" "$SESSION_B" -n "$NAMESPACE" \
    --ignore-not-found >/dev/null 2>&1
  wait_for_session_gone "$SESSION_A" 90 || true
  wait_for_session_gone "$SESSION_B" 90 || true
  kubectl delete mirrordsplitconfig preview-file-split-config -n "$NAMESPACE" \
    --ignore-not-found >/dev/null 2>&1
  kubectl delete deployment "$CONSUMER_DEPLOY" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl delete configmap "$CONFIG_MAP" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

create_preview() { # create_preview <name> <user-id-filter> [config-mount-data-file]
  local name="$1" filter="$2" mount_file="${3:-}"
  local labels=""
  if [ -n "$MARKER" ]; then
    labels=$'\n  labels:\n    operator.metalbear.co/owner: '"$MARKER"
  fi

  local mounts=""
  if [ -n "$mount_file" ]; then
    # A sibling path on purpose: a file INSIDE the ConfigMap volume directory
    # cannot be overlaid (runc "not a directory"), so pipelines mount beside
    # it - and the operator must still bake session names into the content.
    mounts=$'\n  configMounts:\n  - path: /config-pr/application.yaml\n    type: text\n    data: |\n'"$(sed 's/^/      /' "$mount_file")"
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
      file-topic:
        user_id: "$filter"$mounts
EOF
  ok "PreviewSession $name created${mount_file:+ (with a config mount)}"
}

topic_in() { # topic_in <content> - the `name:` scalar of the test yaml shape
  printf '%s\n' "$1" | sed -n 's/^ *name: //p' | head -1
}

print_file() { # print_file <title> <content>
  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border normal --padding "0 1" --margin "0 2" --foreground 250 --border-foreground 240 "$2"
  else
    printf '%s\n' "$2" | sed 's/^/    | /'
  fi
}

# GUIDED=1: stop here, print where to look (concrete commands, real names), and
# wait for Enter. A no-op otherwise, so the automated flow is untouched.
step() { # step <title> <look-line>...
  [ "$GUIDED" = 1 ] || return 0
  local title="$1"
  shift
  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border rounded --padding "0 2" --margin "1 0" --bold --foreground 213 \
      "STOP: $title" "" "Look at (run these in another terminal):" "$@"
  else
    echo; echo "== STOP: $title =="
    echo "Look at (run these in another terminal):"
    printf '  %s\n' "$@"
  fi
  printf '  press Enter to continue... '
  read -r _ </dev/tty || true
}

# Prints every ConfigMap in play so the whole mechanism is visible at a glance:
# the untouched original, the fallback copy the deployed pods read, and each
# session's rewritten mount + retargeted volume copy. Also runnable on its own
# against a KEEP=1 run: ./test-preview-configmap-split.sh show
show_state() {
  banner "State of the world (namespace $NAMESPACE)"

  local original
  original=$(kubectl get cm "$CONFIG_MAP" -n "$NAMESPACE" \
    -o jsonpath='{.data.application\.yaml}' 2>/dev/null)
  if [ -n "$original" ]; then
    say "1. Original ConfigMap $CONFIG_MAP - yours, must never change (topic: $(topic_in "$original"))"
    print_file "$CONFIG_MAP" "$original"
  else
    warn "original ConfigMap $CONFIG_MAP not found"
  fi

  local fallback_cm fallback
  fallback_cm=$(kubectl get pod -n "$NAMESPACE" -l "app=$CONSUMER_DEPLOY,!preview.metalbear.co/session-uid" \
    -o jsonpath="{.items[0].spec.volumes[?(@.name=='$VOLUME')].configMap.name}" 2>/dev/null)
  if [ -n "$fallback_cm" ] && [ "$fallback_cm" != "$CONFIG_MAP" ]; then
    fallback=$(kubectl get cm "$fallback_cm" -n "$NAMESPACE" \
      -o jsonpath='{.data.application\.yaml}' 2>/dev/null)
    say "2. Fallback copy $fallback_cm - what the DEPLOYED pods read (topic: $(topic_in "$fallback"))"
    print_file "$fallback_cm" "$fallback"
  else
    say "2. Deployed pods read: ${fallback_cm:-<no pod>} (no split active -> the original)"
  fi

  local n=3 session mount copy copy_cm started
  for session in $(kubectl get previewsessions -n "$NAMESPACE" -o name 2>/dev/null \
      | sed 's|.*/||' | grep '^pcm-'); do
    mount=$(kubectl get cm "$session-config-mounts" -n "$NAMESPACE" \
      -o jsonpath='{.data.k0}' 2>/dev/null)
    if [ -n "$mount" ]; then
      say "$n. Session $session - REWRITTEN user mount at /config-pr/application.yaml (topic: $(topic_in "$mount"))"
      print_file "$session-config-mounts" "$mount"
      n=$((n + 1))
    fi
    copy_cm=$(kubectl get deploy "$session" -n "$NAMESPACE" \
      -o jsonpath="{.spec.template.spec.volumes[?(@.name=='$VOLUME')].configMap.name}" 2>/dev/null)
    copy=$(kubectl get cm "$copy_cm" -n "$NAMESPACE" \
      -o jsonpath='{.data.application\.yaml}' 2>/dev/null)
    if [ -n "$copy" ]; then
      say "$n. Session $session - retargeted volume copy $copy_cm, what its pod reads at /config (topic: $(topic_in "$copy"))"
      print_file "$copy_cm" "$copy"
      n=$((n + 1))
    fi
    started=$(kubectl logs "deploy/$session" -n "$NAMESPACE" --tail=-1 2>/dev/null \
      | grep -m1 "file consumer starting")
    [ -n "$started" ] && ok "$session app parsed: ${started#*: }"
  done

  say "Poke around yourself:"
  echo "    kubectl get cm -n $NAMESPACE | grep -E 'split-vol|config-mounts|qs-cm|$CONFIG_MAP'"
  echo "    kubectl exec -n $NAMESPACE deploy/<session> -- cat /config/application.yaml"
  echo "    kubectl logs -n $NAMESPACE deploy/<session>"
}

if [ "${1:-}" = show ]; then
  SHOW_ONLY=1
  show_state
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
banner "Preview + mounted-configmap split test"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  err "another run of this script is active (its lock: $LOCK_DIR; rmdir it if stale)"
  exit 1
fi

say "Preflight"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || { err "namespace $NAMESPACE missing - task kafka:deploy"; exit 1; }
kubectl get pod -n "$NAMESPACE" -l app=kafka-cluster -o name >/dev/null 2>&1 \
  || { err "kafka broker missing - task kafka:deploy"; exit 1; }
kubectl get crd previewsessions.preview.mirrord.metalbear.co >/dev/null 2>&1 \
  || { err "PreviewSession CRD missing - operator needs previewEnv=true"; exit 1; }
kubectl get crd mirrordsplitconfigs.queues.mirrord.metalbear.co >/dev/null 2>&1 \
  || { err "MirrordSplitConfig CRD missing"; exit 1; }
resolve_marker

leftovers=$(kubectl get previewsessions -n "$NAMESPACE" -o name 2>/dev/null \
  | sed 's|.*/||' | grep '^pcm-' || true)
if [ -n "$leftovers" ]; then
  warn "deleting leftover sessions from earlier runs (they pin the old split): $leftovers"
  # shellcheck disable=SC2086
  kubectl delete previewsession $leftovers -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  for leftover in $leftovers; do
    wait_for_session_gone "$leftover" 90 || true
  done
fi
ok "preflight done"

# ---------------------------------------------------------------------------
# Cluster resources: topic, ConfigMap, file-reading consumer, split config
# ---------------------------------------------------------------------------
say "Creating the file-configured consumer"

BROKER_POD=$(kubectl get pod -n "$NAMESPACE" -l app=kafka-cluster -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NAMESPACE" "$BROKER_POD" -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --if-not-exists --topic "$TOPIC" --partitions 1 >/dev/null \
  || { err "topic creation failed - broker still starting?"; exit 1; }
ok "topic $TOPIC created"

ORIGINAL_CONTENT="kafka:
  consumer:
    group: $GROUP
    topic:
      main:
        name: $TOPIC"

kubectl apply -n "$NAMESPACE" -f - <<EOF >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIG_MAP
data:
  application.yaml: |
$(printf '%s\n' "$ORIGINAL_CONTENT" | sed 's/^/    /')
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $CONSUMER_DEPLOY
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $CONSUMER_DEPLOY
  template:
    metadata:
      labels:
        app: $CONSUMER_DEPLOY
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
  name: preview-file-split-config
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $CONSUMER_DEPLOY
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
ok "ConfigMap + deployment + MirrordSplitConfig applied"

kubectl rollout status -n "$NAMESPACE" "deployment/$CONSUMER_DEPLOY" --timeout=120s >/dev/null \
  || { err "consumer never became ready"; exit 1; }

step "Baseline - before any session exists" \
  "the original ConfigMap (topic is $TOPIC):" \
  "  kubectl get cm $CONFIG_MAP -n $NAMESPACE -o jsonpath='{.data.application\\.yaml}'" \
  "the deployed pod still mounts it directly:" \
  "  kubectl get pod -n $NAMESPACE -l 'app=$CONSUMER_DEPLOY,!preview.metalbear.co/session-uid' -o jsonpath='{.items[0].spec.volumes[?(@.name==\"$VOLUME\")].configMap.name}'" \
  "and its startup line parsed the original topic:" \
  "  kubectl logs -n $NAMESPACE deploy/$CONSUMER_DEPLOY | grep 'file consumer starting'"

# ---------------------------------------------------------------------------
# Two preview sessions: with and without a config mount
# ---------------------------------------------------------------------------
say "Creating preview sessions"

# The "PR ConfigMap" the pipeline would generate: same queue names, plus a
# PR-specific value that must survive the rewrite.
USER_CONTENT_FILE=$(mktemp /tmp/preview-cm-split.XXXXXX)
printf '%s\nlogLevel: debug\n' "$ORIGINAL_CONTENT" >"$USER_CONTENT_FILE"

create_preview "$SESSION_A" "^preview-a$" "$USER_CONTENT_FILE" || exit 1
create_preview "$SESSION_B" "^preview-b$" || exit 1
rm -f "$USER_CONTENT_FILE"

for session in "$SESSION_A" "$SESSION_B"; do
  say "Waiting up to ${READY_TIMEOUT}s for $session to go Ready"
  wait_for_settled_phase "$session" "$READY_TIMEOUT"
  case "$WAIT_PHASE" in
    Ready) ok "$session Ready after ${WAIT_ELAPSED}s" ;;
    Failed) err "$session Failed: $(session_failure_message "$session")"; exit 1 ;;
    *) err "$session did not settle (last phase: ${WAIT_PHASE:-<none>})"; exit 1 ;;
  esac
done

step "Split is live - the operator made its copies" \
  "the DEPLOYED pod was repointed at a fallback copy (topic is now mirrord-tmp-...fallback...):" \
  "  kubectl get pod -n $NAMESPACE -l 'app=$CONSUMER_DEPLOY,!preview.metalbear.co/session-uid' -o jsonpath='{.items[0].spec.volumes[?(@.name==\"$VOLUME\")].configMap.name}'" \
  "  kubectl get cm -n $NAMESPACE -l operator.metalbear.co/queue-split-cm-copy -o jsonpath='{.items[0].data.application\\.yaml}'" \
  "while the ORIGINAL stayed byte-identical:" \
  "  kubectl get cm $CONFIG_MAP -n $NAMESPACE -o jsonpath='{.data.application\\.yaml}'"

step "Session $SESSION_A - your 'PR ConfigMap' was rewritten" \
  "the mount you provided, with the session topic swapped in and logLevel kept:" \
  "  kubectl get cm $SESSION_A-config-mounts -n $NAMESPACE -o jsonpath='{.data.k0}'" \
  "its volume was ALSO retargeted at a session copy (same topic as the mount):" \
  "  kubectl get cm $SESSION_A-split-vol0 -n $NAMESPACE -o jsonpath='{.data.application\\.yaml}'" \
  "what the app inside the pod actually reads and parsed:" \
  "  kubectl exec -n $NAMESPACE deploy/$SESSION_A -- cat $MOUNT_PATH/application.yaml" \
  "  kubectl logs -n $NAMESPACE deploy/$SESSION_A | grep 'file consumer starting'"

step "Session $SESSION_B - no user mount, volume retarget only" \
  "its own session copy, with a DIFFERENT topic than $SESSION_A's:" \
  "  kubectl get cm $SESSION_B-split-vol0 -n $NAMESPACE -o jsonpath='{.data.application\\.yaml}'" \
  "  kubectl logs -n $NAMESPACE deploy/$SESSION_B | grep 'file consumer starting'"

# ---------------------------------------------------------------------------
# Checks: rewritten mount, retargeted volumes, untouched original
# ---------------------------------------------------------------------------
say "Verifying the rewritten config mount"

MOUNT_CONTENT=$(kubectl get configmap "$SESSION_A-config-mounts" -n "$NAMESPACE" \
  -o jsonpath='{.data.k0}' 2>/dev/null)
MOUNT_TOPIC=$(topic_in "$MOUNT_CONTENT")
[ -n "$MOUNT_CONTENT" ]; check "config-mounts ConfigMap exists for $SESSION_A" $?
[ -n "$MOUNT_TOPIC" ] && [ "$MOUNT_TOPIC" != "$TOPIC" ]
check "mount topic rewritten to a session topic ($MOUNT_TOPIC)" $?
printf '%s\n' "$MOUNT_CONTENT" | grep -q '^logLevel: debug$'
check "user's own values survive the rewrite" $?
printf '%s\n' "$MOUNT_CONTENT" | grep -q "group: $GROUP"
check "group stays untouched (not repointed in this split)" $?

say "Verifying the retargeted volumes"

SESSION_TOPICS=()
for session in "$SESSION_A" "$SESSION_B"; do
  vol_cm=$(kubectl get deployment "$session" -n "$NAMESPACE" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name=='$VOLUME')].configMap.name}" 2>/dev/null)
  [ "$vol_cm" = "$session-split-vol0" ]
  check "$session mounts the session-rendered copy ($vol_cm)" $?
  copy_content=$(kubectl get configmap "$session-split-vol0" -n "$NAMESPACE" \
    -o jsonpath='{.data.application\.yaml}' 2>/dev/null)
  copy_topic=$(topic_in "$copy_content")
  [ -n "$copy_topic" ] && [ "$copy_topic" != "$TOPIC" ]
  check "$session copy carries a session topic ($copy_topic)" $?
  SESSION_TOPICS+=("$copy_topic")
done
[ "${SESSION_TOPICS[0]}" != "${SESSION_TOPICS[1]}" ]
check "sessions read distinct topics" $?
[ "${SESSION_TOPICS[0]}" = "$MOUNT_TOPIC" ]
check "rewritten mount and volume copy agree on $SESSION_A's topic" $?

ORIGINAL_NOW=$(kubectl get configmap "$CONFIG_MAP" -n "$NAMESPACE" \
  -o jsonpath='{.data.application\.yaml}')
[ "$(topic_in "$ORIGINAL_NOW")" = "$TOPIC" ]
check "original ConfigMap untouched" $?

# ---------------------------------------------------------------------------
# Routing: each preview gets its own message, unmatched goes to the fallback
# ---------------------------------------------------------------------------
step "About to produce 3 messages" \
  "one for each session filter (user_id=preview-a / preview-b) and one unmatched;" \
  "tail the three consumers while the script sends them:" \
  "  kubectl logs -n $NAMESPACE deploy/$SESSION_A -f" \
  "  kubectl logs -n $NAMESPACE deploy/$SESSION_B -f" \
  "  kubectl logs -n $NAMESPACE deploy/$CONSUMER_DEPLOY -f"

say "Verifying message routing"

MSG_A="to-preview-a-$TAG"
MSG_B="to-preview-b-$TAG"
MSG_FALLBACK="to-deployed-$TAG"
send_kafka_message "preview-a" "$MSG_A" || warn "producing $MSG_A failed"
send_kafka_message "preview-b" "$MSG_B" || warn "producing $MSG_B failed"
send_kafka_message "nobody" "$MSG_FALLBACK" || warn "producing $MSG_FALLBACK failed"

wait_for_log_line "$SESSION_A" "$MSG_A" 90
check "$SESSION_A received its matching message" $?
wait_for_log_line "$SESSION_B" "$MSG_B" 90
check "$SESSION_B received its matching message" $?
wait_for_log_line "$CONSUMER_DEPLOY" "$MSG_FALLBACK" 90
check "deployed consumer received the unmatched message (fallback)" $?

show_state

# ---------------------------------------------------------------------------
# Teardown: session deletion GCs the copies
# ---------------------------------------------------------------------------
if [ "$KEEP" != 1 ]; then
  step "About to delete both sessions" \
    "watch the copies get garbage-collected and the target restored:" \
    "  kubectl get cm -n $NAMESPACE -w | grep -E 'split-vol|config-mounts|qs-cm'" \
    "  kubectl get pod -n $NAMESPACE -l app=$CONSUMER_DEPLOY -w"

  say "Verifying teardown"
  kubectl delete previewsession "$SESSION_A" "$SESSION_B" -n "$NAMESPACE" >/dev/null 2>&1
  wait_for_session_gone "$SESSION_A" 90 || true
  wait_for_session_gone "$SESSION_B" 90 || true

  gone=1
  for _ in $(seq 1 30); do
    if ! kubectl get configmap "$SESSION_A-split-vol0" -n "$NAMESPACE" >/dev/null 2>&1 \
      && ! kubectl get configmap "$SESSION_B-split-vol0" -n "$NAMESPACE" >/dev/null 2>&1; then
      gone=0
      break
    fi
    sleep 2
  done
  check "session ConfigMap copies garbage-collected" "$gone"

  restored=1
  for _ in $(seq 1 45); do
    vol_cm=$(kubectl get pod -n "$NAMESPACE" -l "app=$CONSUMER_DEPLOY,!preview.metalbear.co/session-uid" \
      -o jsonpath="{.items[0].spec.volumes[?(@.name=='$VOLUME')].configMap.name}" 2>/dev/null)
    if [ "$vol_cm" = "$CONFIG_MAP" ]; then
      restored=0
      break
    fi
    sleep 2
  done
  check "target restored to the original ConfigMap" "$restored"
fi

# ---------------------------------------------------------------------------
if [ "$FAILURES" = 0 ]; then
  verdict pass "preview config mounts compose with mounted-configmap splitting" \
    "rewritten mount + retargeted volumes + per-session routing all verified"
  [ "$KEEP" = 1 ] && say "sessions kept - inspect anytime with: $0 show"
else
  verdict fail "$FAILURES check(s) failed - scroll up for the ✗ lines"
  exit 1
fi
