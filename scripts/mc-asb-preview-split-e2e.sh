#!/usr/bin/env bash
#
# End-to-end test for multi-cluster preview-environment queue splitting on
# AZURE SERVICE BUS (real Azure namespace), including the shared
# subscription-name fix: the target consumer reads test-topic + test-topic-2
# through ONE service-name env var and test-topic-3 through its OWN var.
#
# Unlike SQS, Service Bus is one global broker shared by every cluster: the
# default cluster owns all physical resources (ingest subs, forwarders,
# rules), and the rule swap on the app's subscriptions covers the deployed
# consumers on EVERY cluster at once. Remote split sessions are passive.
#
# Flow:
#   1. (optional) swap every in-cluster operator to the locally-built image
#      (build it from the branch with the ASB shared-name fix!).
#   2. deploy the shared-service-name consumer + split config on all workload
#      clusters, secret + topics ensured, broker state pre-cleaned.
#   3. start a preview env via the primary; the pod lands on the default
#      cluster.
#   4. assert the subscription layout: ONE shared mirrord-s-* name on
#      test-topic + test-topic-2, a DIFFERENT one on test-topic-3, all with
#      routing rules, none match-all, nothing app-created.
#   5. send matched + unmatched messages to all three topics; matched must
#      reach the preview pod exactly once, unmatched must reach the deployed
#      consumers (on whichever cluster wins the competing consume).
#   6. stop the preview and verify CRs on every cluster and subscriptions in
#      Azure are cleaned up.
#
# Usage:
#   ./mc-asb-preview-split-e2e.sh
#   NUM=5 ./mc-asb-preview-split-e2e.sh            # messages per class per topic
#   MC_NUM_CLUSTERS=2 ./mc-asb-preview-split-e2e.sh
#   DEPLOY_OPERATOR=1 ./mc-asb-preview-split-e2e.sh # swap in mirrord-operator:custom
#   REDEPLOY_SB=1 ./mc-asb-preview-split-e2e.sh    # (re)deploy consumer + configs
#   KEEP=1 ./mc-asb-preview-split-e2e.sh           # leave the preview running
#
# Prereqs: minikube multicluster up with ASB splitting enabled on all
# operators; az login + AZURE_SB_RG/AZURE_SB_NAMESPACE in .env (or the
# servicebus-azure-conn secret already present on some cluster).

set -uo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SANDBOX_DIR"

NUM="${NUM:-3}"
if [ -z "${MC_NUM_CLUSTERS:-}" ]; then
  if minikube status -p mirrord-remote-2 >/dev/null 2>&1; then
    MC_NUM_CLUSTERS=3
  else
    MC_NUM_CLUSTERS=2
  fi
fi
PREVIEW_NAME="${PREVIEW_NAME:-asbprev}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-mirrord-operator:custom}"
DEPLOY_OPERATOR="${DEPLOY_OPERATOR:-0}"
REDEPLOY_SB="${REDEPLOY_SB:-0}"
CONSUME_WAIT="${CONSUME_WAIT:-40}"
CLEANUP_TIMEOUT="${CLEANUP_TIMEOUT:-240}"
KEEP="${KEEP:-0}"

PRIMARY_CTX="${MC_PRIMARY:-mirrord-primary}"
REMOTE1_CTX="${MC_REMOTE_1:-mirrord-remote-1}"
REMOTE2_CTX="${MC_REMOTE_2:-mirrord-remote-2}"
NS="test-mirrord"
OVERLAY="$SANDBOX_DIR/k8s/overlays/servicebus-emulator"
TOPICS="test-topic,test-topic-2,test-topic-3"
export MC_NUM_CLUSTERS

if [ "$MC_NUM_CLUSTERS" = "3" ]; then
  DEFAULT_CTX="${MC_DEFAULT_CTX:-$REMOTE1_CTX}"
  WORKLOAD_CTXS_LIST=("$REMOTE1_CTX" "$REMOTE2_CTX")
else
  DEFAULT_CTX="${MC_DEFAULT_CTX:-$PRIMARY_CTX}"
  WORKLOAD_CTXS_LIST=("$PRIMARY_CTX" "$REMOTE1_CTX")
fi

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; BLD=$'\033[1m'; RST=$'\033[0m'
say()  { printf '%s\n' "${BLU}==>${RST} ${BLD}$*${RST}"; }
ok()   { printf '%s\n' "${GRN}  ok${RST} $*"; }
warn() { printf '%s\n' "${YEL}  !!${RST} $*"; }
err()  { printf '%s\n' "${RED}  XX${RST} $*"; }

if [ -z "${MIRRORD_BIN:-}" ] && [ -f "$SANDBOX_DIR/.env" ]; then
  MIRRORD_BIN=$(grep -E '^MIRRORD_BIN=' "$SANDBOX_DIR/.env" | tail -1 | cut -d= -f2-)
fi
MIRRORD_BIN="${MIRRORD_BIN:-$(command -v mirrord || true)}"
[ -x "$MIRRORD_BIN" ] || { err "mirrord CLI not found (MIRRORD_BIN / .env)"; exit 1; }

ALL_CTXS=()
for c in "$PRIMARY_CTX" "$REMOTE1_CTX" "$REMOTE2_CTX"; do
  [ "$c" = "$REMOTE2_CTX" ] && [ "$MC_NUM_CLUSTERS" != "3" ] && continue
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$c" && ALL_CTXS+=("$c")
done

# Same convention as every sandbox task: when local operator:dev processes are
# running (task multicluster:operator:primary / :remote), the session must be
# labeled with the isolation marker so YOUR local operators own it end to end.
# Without the marker the IN-CLUSTER operator picks the preview up while the
# dev operators steal the webhook traffic with a different TLS cert - the
# apiserver then fails open and the pod mutator replaces unpatched consumer
# pods in an endless loop.
if [ "$DEPLOY_OPERATOR" != 1 ] && [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] \
   && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  warn "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev (your local operators own the session)"
fi

# Never leave the preview running behind an interrupt: stop it on any exit
# unless KEEP=1 or the normal teardown already ran.
PREVIEW_STARTED=0
PREVIEW_STOPPED=0
on_exit() {
  [ "$PREVIEW_STARTED" = 1 ] && [ "$PREVIEW_STOPPED" = 0 ] && [ "$KEEP" != 1 ] || return 0
  warn "stopping preview '$PREVIEW_NAME' (interrupted run)"
  MIRRORD_KUBE_CONTEXT="$PRIMARY_CTX" MIRRORD_CHECK_VERSION=false \
    "$MIRRORD_BIN" preview stop -k "$PREVIEW_NAME" >/dev/null 2>&1 || true
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Azure connection: secret from any cluster, else fetched via az. Topics too.
# ---------------------------------------------------------------------------
AZURE_CONN=""
for c in "${ALL_CTXS[@]}"; do
  AZURE_CONN=$(kubectl --context "$c" get secret servicebus-azure-conn -n "$NS" \
    -o jsonpath='{.data.connection_string}' 2>/dev/null | base64 -d) && [ -n "$AZURE_CONN" ] && break
done
AZ_RG=$(grep -E '^AZURE_SB_RG=' "$SANDBOX_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
AZ_NS=$(grep -E '^AZURE_SB_NAMESPACE=' "$SANDBOX_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
if [ -z "$AZURE_CONN" ]; then
  if [ -n "$AZ_RG" ] && [ -n "$AZ_NS" ] && az account show >/dev/null 2>&1; then
    say "Fetching Azure connection string via az ($AZ_NS)"
    AZURE_CONN=$(az servicebus namespace authorization-rule keys list \
      -g "$AZ_RG" --namespace-name "$AZ_NS" \
      --name RootManageSharedAccessKey --query primaryConnectionString -o tsv)
  fi
fi
[ -n "$AZURE_CONN" ] || { err "no Azure connection string (secret or az + .env)"; exit 1; }
if [ -n "$AZ_RG" ] && [ -n "$AZ_NS" ] && az account show >/dev/null 2>&1; then
  for t in test-topic test-topic-2 test-topic-3; do
    az servicebus topic create -g "$AZ_RG" --namespace-name "$AZ_NS" --name "$t" -o none 2>/dev/null || true
  done
fi

# ---------------------------------------------------------------------------
# One-shot pods on the default cluster: list / clean / send
# ---------------------------------------------------------------------------
run_oneshot() { # ctx name-prefix env-args... -- reads logs after completion
  local ctx="$1" prefix="$2"; shift 2
  local name="${prefix}-$RANDOM"
  kubectl --context "$ctx" run "$name" --restart=Never \
    --image=servicebus-consumer:local --image-pull-policy=Never \
    --namespace="$NS" "$@" -- /app/consumer >/dev/null 2>&1
  local i phase
  for i in $(seq 1 30); do
    phase=$(kubectl --context "$ctx" get pod "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
    sleep 2
  done
  kubectl --context "$ctx" logs -n "$NS" "$name" 2>/dev/null
  kubectl --context "$ctx" delete pod "$name" -n "$NS" --wait=false >/dev/null 2>&1
}

list_subs() {
  run_oneshot "$DEFAULT_CTX" sb-lister \
    --env="LIST_MODE=true" \
    --env="SERVICEBUS_CONNECTION_STRING=$AZURE_CONN" \
    --env="SERVICEBUS_TOPICS=$TOPICS"
}

clean_broker() {
  run_oneshot "$DEFAULT_CTX" sb-cleaner \
    --env="CLEAN_MODE=true" \
    --env="SERVICEBUS_CONNECTION_STRING=$AZURE_CONN" \
    --env="SERVICEBUS_TOPICS=$TOPICS"
}

send_msg() { # topic tenant token
  local out
  out=$(run_oneshot "$DEFAULT_CTX" sb-sender \
    --env="SEND_MODE=true" \
    --env="SERVICEBUS_CONNECTION_STRING=$AZURE_CONN" \
    --env="SEND_TOPIC=$1" \
    --env="MESSAGE_BODY={\"order_id\":\"$3\",\"tenant\":\"$2\",\"type\":\"mc-repro\"}" \
    --env="MESSAGE_PROPERTIES=tenant=$2")
  echo "$out" | grep -q "Sent to" || warn "send of '$3' to $1 may have failed"
}

# ---------------------------------------------------------------------------
# Optional: swap all operators to the locally built image
# ---------------------------------------------------------------------------
deploy_operator() {
  say "Deploying custom operator image ($OPERATOR_IMAGE) to all clusters"
  if pgrep -f 'target/debug/operator-service' >/dev/null 2>&1; then
    warn "stopping running operator:dev processes"
    pkill -f 'target/debug/operator-service' 2>/dev/null || true
    sleep 3
  fi
  for c in "${ALL_CTXS[@]}"; do
    minikube -p "$c" ssh "docker rmi $OPERATOR_IMAGE --force" >/dev/null 2>&1 || true
    say "loading image into $c"
    minikube -p "$c" image load "$OPERATOR_IMAGE"
    kubectl --context "$c" -n mirrord set image deploy/mirrord-operator "mirrord-operator=$OPERATOR_IMAGE"
    kubectl --context "$c" -n mirrord patch deploy mirrord-operator --type=strategic \
      -p '{"spec":{"template":{"spec":{"containers":[{"name":"mirrord-operator","imagePullPolicy":"Never"}]}}}}'
    kubectl --context "$c" -n mirrord delete lease mirrord-operator-leader >/dev/null 2>&1 || true
    kubectl --context "$c" -n mirrord delete pod -l app.kubernetes.io/name=mirrord-operator --force --grace-period=0 >/dev/null 2>&1 || true
  done
  for c in "${ALL_CTXS[@]}"; do
    if kubectl --context "$c" -n mirrord rollout status deploy/mirrord-operator --timeout=150s >/dev/null 2>&1; then
      ok "$c operator ready"
    else
      err "$c operator did not become ready"
    fi
  done
}

# ---------------------------------------------------------------------------
# Pre-clean: CRs on every cluster, then broker state in Azure
# ---------------------------------------------------------------------------
scrub_cluster() {
  local c="$1"
  local kinds=(
    "previewsessions.preview.mirrord.metalbear.co"
    "mirrordclustersplitsessions.queues.mirrord.metalbear.co"
    "mirrordclusterworkloadpatchrequests.mirrord.metalbear.co"
    "mirrordclusterworkloadpatches.mirrord.metalbear.co"
    "mirrordclusterexternalresources.mirrord.metalbear.co"
  )
  for k in "${kinds[@]}"; do
    while read -r item; do
      [ -z "$item" ] && continue
      kubectl --context "$c" patch "$item" -n "$NS" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || \
      kubectl --context "$c" patch "$item" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      kubectl --context "$c" delete "$item" --ignore-not-found >/dev/null 2>&1 || true
    done < <(kubectl --context "$c" get "$k" -A -o name 2>/dev/null)
  done
}

pre_clean() {
  say "Pre-clean: CRs on every cluster + broker state in Azure"
  for c in "${ALL_CTXS[@]}"; do
    kubectl --context "$c" get mutatingwebhookconfiguration -o name 2>/dev/null \
      | grep -i 'mirrord-pods' \
      | xargs -r -I{} kubectl --context "$c" delete {} >/dev/null 2>&1 || true
  done
  for c in "${ALL_CTXS[@]}"; do scrub_cluster "$c"; done
  sleep 5
  clean_broker | sed 's/^/     /'
  ok "clusters + broker scrubbed"
}

# ---------------------------------------------------------------------------
# Deploy the mixed shared/own-subscription test env on all workload clusters
# ---------------------------------------------------------------------------
ensure_env() {
  say "Deploying the shared-service-name consumer on: ${WORKLOAD_CTXS_LIST[*]}"
  docker build -t servicebus-consumer:local "$SANDBOX_DIR/apps/servicebus-consumer" >/dev/null
  for c in "${ALL_CTXS[@]}"; do
    minikube -p "$c" image load servicebus-consumer:local
    kubectl --context "$c" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$c" apply -f - >/dev/null
    kubectl --context "$c" create secret generic servicebus-azure-conn -n "$NS" \
      --from-literal=connection_string="$AZURE_CONN" \
      --dry-run=client -o yaml | kubectl --context "$c" apply -f - >/dev/null
  done
  for c in "${WORKLOAD_CTXS_LIST[@]}"; do
    kubectl --context "$c" apply -f "$OVERLAY/property-list-azure.yaml" >/dev/null
    kubectl --context "$c" apply -f "$OVERLAY/consumer-topic-shared.yaml" >/dev/null
    kubectl --context "$c" apply -f "$OVERLAY/split-config-shared.yaml" >/dev/null
    kubectl --context "$c" rollout restart deploy/servicebus-shared-consumer -n "$NS" >/dev/null
  done
  for c in "${WORKLOAD_CTXS_LIST[@]}"; do
    kubectl --context "$c" rollout status deploy/servicebus-shared-consumer -n "$NS" --timeout=180s >/dev/null \
      && ok "$c consumer ready" || err "$c consumer not ready"
  done
}

env_present() {
  for c in "${WORKLOAD_CTXS_LIST[@]}"; do
    kubectl --context "$c" -n "$NS" get deploy servicebus-shared-consumer >/dev/null 2>&1 || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Start the preview via the primary and wait for Ready
# ---------------------------------------------------------------------------
PREVIEW_BG_PID=""
start_preview() {
  say "Starting preview '$PREVIEW_NAME' (filter tenant=^${PREVIEW_NAME}- on all 3 topics)"
  local cfg="/tmp/mirrord-mc-asb-preview-${PREVIEW_NAME}.json"
  python3 - "$OVERLAY/mirrord-shared-sub.json" "$cfg" "$PREVIEW_NAME" <<'PY'
import json, sys
src, dst, name = sys.argv[1], sys.argv[2], sys.argv[3]
c = json.load(open(src))
c["feature"]["preview"] = {"ttl_mins": 30, "creation_timeout_secs": 300}
for split in c["feature"]["split_queues"].values():
    split["message_filter"] = {"tenant": f"^{name}-"}
json.dump(c, open(dst, "w"), indent=2)
PY

  ( MIRRORD_KUBE_CONTEXT="$PRIMARY_CTX" MIRRORD_CHECK_VERSION=false \
      "$MIRRORD_BIN" preview start -f "$cfg" -i servicebus-consumer:local \
      -k "$PREVIEW_NAME" --timeout 300 >/tmp/mc-asb-preview-start.log 2>&1 ) &
  PREVIEW_BG_PID=$!
  PREVIEW_STARTED=1

  local deadline=$(( $(date +%s) + 300 ))
  local phase=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    phase=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    [ "$phase" = "Ready" ] && break
    [ "$phase" = "Failed" ] && { err "preview Failed on primary"; tail -20 /tmp/mc-asb-preview-start.log; return 1; }
    sleep 4
  done
  [ "$phase" = "Ready" ] || { err "preview never Ready (last: ${phase:-none})"; tail -20 /tmp/mc-asb-preview-start.log; return 1; }
  ok "primary preview session Ready"

  local d2=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$d2" ]; do
    local n
    n=$(kubectl --context "$DEFAULT_CTX" get mirrordclustersplitsessions.queues.mirrord.metalbear.co -A -o json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for i in d.get("items",[]) if "ready" in {k.lower() for k in (i.get("status") or {})}))' 2>/dev/null)
    [ "${n:-0}" -ge 1 ] && { ok "split session Ready on default cluster ($DEFAULT_CTX)"; return 0; }
    sleep 4
  done
  err "no Ready split session on the default cluster"
  return 1
}

# ---------------------------------------------------------------------------
# Subscription layout assertions (the shared-name fix, seen from Azure)
# ---------------------------------------------------------------------------
SHARED_NAME=""
OWN_NAME=""
verify_subscriptions() {
  say "Subscription layout in Azure while the preview is live"
  local live; live=$(list_subs)
  echo "$live" | sed 's/^/     /'

  SHARED_NAME=$(echo "$live" | awk '/=== topic test-topic ===/{f=1;next} /=== topic/{f=0} f && /mirrord-s-/{print $1}' | head -1)
  OWN_NAME=$(echo "$live" | awk '/=== topic test-topic-3 ===/{f=1;next} /=== topic/{f=0} f && /mirrord-s-/{print $1}' | head -1)

  local shared_count unfiltered
  shared_count=$(echo "$live" | grep -c "  ${SHARED_NAME:-none} " || true)
  unfiltered=$(echo "$live" | grep "mirrord-s-" | grep -c "match-all" || true)

  if [ -n "$SHARED_NAME" ] && [ "${shared_count:-0}" -eq 2 ]; then
    ok "shared group: $SHARED_NAME on test-topic AND test-topic-2 (one name, one env var)"
  else
    err "shared name not on exactly 2 topics (name=${SHARED_NAME:-none} count=${shared_count:-0}) - shared-name fix missing in the operator image?"
  fi
  if [ -n "$OWN_NAME" ] && [ "$OWN_NAME" != "$SHARED_NAME" ]; then
    ok "own group: $OWN_NAME on test-topic-3 (its own env var, its own name)"
  else
    err "test-topic-3 session subscription wrong (own=${OWN_NAME:-none})"
  fi
  if [ "${unfiltered:-0}" -gt 0 ]; then
    err "$unfiltered mirrord-s-* subscription(s) with match-all rules - app-created orphans present"
  else
    ok "every mirrord-s-* subscription carries a routing rule (nothing app-created)"
  fi
}

# ---------------------------------------------------------------------------
# Send + routing summary
# ---------------------------------------------------------------------------
send_messages() {
  say "Sending $NUM matched + $NUM unmatched per topic (3 topics)"
  local t i n=0
  for t in test-topic test-topic-2 test-topic-3; do
    n=$((n+1))
    for i in $(seq 1 "$NUM"); do
      send_msg "$t" "${PREVIEW_NAME}-user" "${PREVIEW_NAME}-M-t${n}-${i}"
      send_msg "$t" "other" "basic-U-t${n}-${i}"
      printf '     %s: %s/%s pairs sent\n' "$t" "$i" "$NUM"
    done
  done
  ok "sent $((NUM*6)) messages"
  say "Waiting ${CONSUME_WAIT}s for consumption"
  sleep "$CONSUME_WAIT"
}

orders_in_logs() { # ctx label prefix
  kubectl --context "$1" -n "$NS" logs -l "$2" --tail=2000 --prefix=false 2>/dev/null \
    | grep -oE "order=${3}-t[0-9]+-[0-9]+" | sed 's/order=//' | sort
}

count_u() { printf '%s' "$1" | grep -cE '.' || true; }
join_u()  { printf '%s' "$1" | paste -sd',' - 2>/dev/null; }

routing_summary() {
  say "Routing summary"
  local preview_ctx=""
  for c in "${WORKLOAD_CTXS_LIST[@]}"; do
    if kubectl --context "$c" -n "$NS" get pods -l preview.metalbear.co/session-uid --no-headers 2>/dev/null | grep -q .; then
      preview_ctx="$c"; break
    fi
  done

  echo
  printf '%s\n' "${BLD}MATCHED (expected -> preview pod, exactly once each)${RST}"
  local pv_all pv_uniq pv_leak
  if [ -n "$preview_ctx" ]; then
    pv_all=$(orders_in_logs "$preview_ctx" "preview.metalbear.co/session-uid" "$PREVIEW_NAME-M")
    pv_uniq=$(echo "$pv_all" | grep -E '.' | sort -u)
    pv_leak=$(orders_in_logs "$preview_ctx" "preview.metalbear.co/session-uid" "basic-U" | sort -u)
    printf '  preview pod (%s): %s/%s matched: %s\n' \
      "$preview_ctx" "$(count_u "$pv_uniq")" "$((NUM*3))" "$(join_u "$pv_uniq")"
    [ "$(count_u "$pv_all")" != "$(count_u "$pv_uniq")" ] && err "duplicates in the preview pod (raw vs unique differ)"
    [ -n "$pv_leak" ] && err "preview pod ALSO got unmatched: $(join_u "$pv_leak")"
  else
    err "no preview pod found on any workload cluster"
  fi

  echo
  printf '%s\n' "${BLD}UNMATCHED (expected -> deployed consumers; ASB is global, one winner per message)${RST}"
  local total="" leaks=""
  for c in "${WORKLOAD_CTXS_LIST[@]}"; do
    local cn cm
    cn=$(orders_in_logs "$c" "app=servicebus-shared-consumer,!preview.metalbear.co/session-uid" "basic-U" | sort -u)
    cm=$(orders_in_logs "$c" "app=servicebus-shared-consumer,!preview.metalbear.co/session-uid" "$PREVIEW_NAME-M" | sort -u)
    printf '  consumer on %-18s unmatched: %-3s %s\n' "$c" "$(count_u "$cn")" "$(join_u "$cn")"
    [ -n "$cm" ] && { err "  consumer on $c ALSO got matched: $(join_u "$cm")"; leaks=1; }
    total+="$cn"$'\n'
  done
  local uniq_nomatch; uniq_nomatch=$(printf '%s' "$total" | grep -E '.' | sort -u)
  printf '  total distinct unmatched delivered: %s/%s\n' "$(count_u "$uniq_nomatch")" "$((NUM*3))"

  echo
  if [ "$(count_u "${pv_uniq:-}")" = "$((NUM*3))" ] && [ -z "${pv_leak:-}" ] && [ -z "$leaks" ] \
     && [ "$(count_u "$uniq_nomatch")" = "$((NUM*3))" ]; then
    ok "${GRN}ROUTING OK${RST} - matched -> preview (once each, all topics), unmatched -> consumers"
  else
    warn "routing did not fully match expectations (see above)"
  fi
}

# ---------------------------------------------------------------------------
# Stop + verify cleanup (clusters and Azure)
# ---------------------------------------------------------------------------
stop_and_verify() {
  PREVIEW_STOPPED=1
  say "Stopping preview '$PREVIEW_NAME'"
  MIRRORD_KUBE_CONTEXT="$PRIMARY_CTX" MIRRORD_CHECK_VERSION=false \
    "$MIRRORD_BIN" preview stop -k "$PREVIEW_NAME" >/dev/null 2>&1 || true
  [ -n "$PREVIEW_BG_PID" ] && kill "$PREVIEW_BG_PID" >/dev/null 2>&1 || true

  say "Waiting for CR teardown on every cluster (up to ${CLEANUP_TIMEOUT}s)"
  local deadline=$(( $(date +%s) + CLEANUP_TIMEOUT ))
  local leaks=0
  while :; do
    leaks=0
    for c in "${ALL_CTXS[@]}"; do
      local ps ss
      ps=$(kubectl --context "$c" get previewsessions.preview.mirrord.metalbear.co -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
      ss=$(kubectl --context "$c" get mirrordclustersplitsessions.queues.mirrord.metalbear.co -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
      [ "$ps" = 0 ] && [ "$ss" = 0 ] || leaks=$((leaks+1))
    done
    { [ "$leaks" = 0 ] || [ "$(date +%s)" -ge "$deadline" ]; } && break
    sleep 6
  done
  for c in "${ALL_CTXS[@]}"; do
    local ps ss
    ps=$(kubectl --context "$c" get previewsessions.preview.mirrord.metalbear.co -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ss=$(kubectl --context "$c" get mirrordclustersplitsessions.queues.mirrord.metalbear.co -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$ps" = 0 ] && [ "$ss" = 0 ] && ok "$c clean" || err "$c leftovers: previewsessions=$ps splitsessions=$ss"
  done

  say "Waiting for Azure subscription cleanup (session subs; drain may lag)"
  local d2=$(( $(date +%s) + CLEANUP_TIMEOUT ))
  local final=""
  while [ "$(date +%s)" -lt "$d2" ]; do
    final=$(list_subs)
    echo "$final" | grep -q "mirrord-s-" || break
    sleep 10
  done
  echo "$final" | sed 's/^/     /'
  if echo "$final" | grep -q "mirrord-s-"; then
    err "mirrord-s-* subscription(s) left in Azure after teardown"
  else
    ok "no mirrord-s-* subscriptions left in Azure"
  fi
  echo "$final" | grep -q "mirrord-ingest-" \
    && warn "ingest subscription(s) still draining (removed when the drain finishes)" || true

  echo
  [ "$leaks" = 0 ] && ok "${GRN}CLEANUP OK${RST}" || err "${RED}CLEANUP FAILED${RST} - $leaks cluster(s) had leftovers"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
say "Contexts: ${ALL_CTXS[*]} (MC_NUM_CLUSTERS=$MC_NUM_CLUSTERS, default=$DEFAULT_CTX, NUM=$NUM/class/topic)"

[ "$DEPLOY_OPERATOR" = 1 ] && deploy_operator
if [ "$REDEPLOY_SB" = 1 ] || ! env_present; then
  ensure_env
fi
pre_clean

start_preview || { err "aborting - preview did not start"; stop_and_verify; exit 1; }
verify_subscriptions
send_messages
routing_summary

if [ "$KEEP" = 1 ]; then
  warn "KEEP=1 - preview left running; stop with: MIRRORD_KUBE_CONTEXT=$PRIMARY_CTX $MIRRORD_BIN preview stop -k $PREVIEW_NAME"
else
  stop_and_verify
fi

say "Done."
