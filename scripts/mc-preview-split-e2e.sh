#!/usr/bin/env bash
#
# End-to-end test for multi-cluster preview-environment queue splitting.
#
# It runs the whole flow against the local minikube multi-cluster sandbox:
#   1. (optional) swap every in-cluster operator to the locally-built image so
#      all clusters run YOUR code - a released operator with the old sync logic
#      would fight the fix and wedge the default cluster copy (see the split
#      controller / crd_sync finalizer handling).
#   2. deploy / ensure the shared-LocalStack SQS test env on all clusters.
#   3. start a preview env, wait for it to go Ready and fan out to every
#      workload cluster.
#   4. send N matched + N unmatched messages, each tagged so it can be traced.
#   5. print who received what (preview pod vs the deployed consumers).
#   6. stop the preview and verify nothing is left behind on any cluster.
#
# Every message carries a unique `type` attribute so each one is identifiable
# in the logs: matched types start with the preview filter prefix (routed to
# the preview pod), unmatched types do not (routed to a deployed consumer).
#
# Usage:
#   ./mc-preview-split-e2e.sh                 # 20 matched + 20 unmatched
#   NUM=5 ./mc-preview-split-e2e.sh           # 5 of each
#   MC_NUM_CLUSTERS=2 ./mc-preview-split-e2e.sh   # force the 2-cluster topology
#   DEPLOY_OPERATOR=1 ./mc-preview-split-e2e.sh   # also swap in the custom image
#   REDEPLOY_SQS=1 ./mc-preview-split-e2e.sh  # (re)deploy the SQS env first
#   KEEP=1 ./mc-preview-split-e2e.sh          # leave the preview running at the end
#
# Env knobs (all optional):
#   NUM                messages per class (default 20)
#   MC_NUM_CLUSTERS    2 or 3 (default: auto-detected from running minikube profiles).
#                      2 = primary is the default+workload cluster + remote-1.
#                      3 = management-only primary + remote-1 (default) + remote-2.
#   PREVIEW_NAME       preview key + filter prefix (default prev)
#   OPERATOR_IMAGE     custom image tag (default mirrord-operator:custom)
#   DEPLOY_OPERATOR    1 = load custom image + point deployments at it (default 0)
#   REDEPLOY_SQS       1 = run multicluster:sqs:deploy first (default 0)
#   CONSUME_WAIT       seconds to wait for messages to drain (default 40)
#   WARMUP             optional extra settle after the queuesplits API reports
#                      Ready, on top of that gate (default 0; needs operator 3.223.0+)
#   SEND_INTERVAL      seconds between sends; 0 = burst (default 0). Spacing sends
#                      spreads unmatched across clusters instead of one draining all.
#   CLEANUP_TIMEOUT    seconds to poll for teardown to complete (default 120)
#   KEEP               1 = skip teardown at the end (default 0)

set -uo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SANDBOX_DIR"

NUM="${NUM:-20}"
# Topology: honour an explicit MC_NUM_CLUSTERS, otherwise infer it from the
# running minikube profiles. A running mirrord-remote-2 is the 3-cluster
# install (management-only primary + remote-1 default + remote-2). Without it
# the primary itself is the default+workload cluster (2-cluster).
if [ -z "${MC_NUM_CLUSTERS:-}" ]; then
  if minikube status -p mirrord-remote-2 >/dev/null 2>&1; then
    MC_NUM_CLUSTERS=3
  else
    MC_NUM_CLUSTERS=2
  fi
fi
PREVIEW_NAME="${PREVIEW_NAME:-prev}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-mirrord-operator:custom}"
DEPLOY_OPERATOR="${DEPLOY_OPERATOR:-0}"
REDEPLOY_SQS="${REDEPLOY_SQS:-0}"
CONSUME_WAIT="${CONSUME_WAIT:-40}"
WARMUP="${WARMUP:-0}"
SEND_INTERVAL="${SEND_INTERVAL:-0}"
CLEANUP_TIMEOUT="${CLEANUP_TIMEOUT:-120}"
KEEP="${KEEP:-0}"

PRIMARY_CTX="${MC_PRIMARY:-mirrord-primary}"
REMOTE1_CTX="${MC_REMOTE_1:-mirrord-remote-1}"
REMOTE2_CTX="${MC_REMOTE_2:-mirrord-remote-2}"
NS="test-multicluster"
export MC_NUM_CLUSTERS

# Matched types start with "<name>-" so they hit the preview filter (^<name>-);
# unmatched types start with "basic-" so they never match and reach the
# deployed consumer. The numeric suffix makes each message unique in the logs.
MATCH_PREFIX="${PREVIEW_NAME}-M"
NOMATCH_PREFIX="basic-U"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; BLD=$'\033[1m'; RST=$'\033[0m'
say()  { printf '%s\n' "${BLU}==>${RST} ${BLD}$*${RST}"; }
ok()   { printf '%s\n' "${GRN}  ok${RST} $*"; }
warn() { printf '%s\n' "${YEL}  !!${RST} $*"; }
err()  { printf '%s\n' "${RED}  XX${RST} $*"; }

# All cluster contexts that actually exist, honouring MC_NUM_CLUSTERS.
ALL_CTXS=()
for c in "$PRIMARY_CTX" "$REMOTE1_CTX" "$REMOTE2_CTX"; do
  [ "$c" = "$REMOTE2_CTX" ] && [ "$MC_NUM_CLUSTERS" != "3" ] && continue
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$c" && ALL_CTXS+=("$c")
done

# Workload clusters run the deployed sqs-consumer; the preview pod lands on
# whichever workload cluster is the operator's default.
workload_ctxs() {
  local out=()
  for c in "${ALL_CTXS[@]}"; do
    kubectl --context "$c" -n "$NS" get deploy sqs-consumer >/dev/null 2>&1 && out+=("$c")
  done
  printf '%s\n' "${out[@]}"
}

# ---------------------------------------------------------------------------
# Step 0: point every in-cluster operator at the locally-built image (optional)
# ---------------------------------------------------------------------------
deploy_operator() {
  say "Deploying custom operator image ($OPERATOR_IMAGE) to all clusters"

  # A running operator:dev (local binary via mirrord steal) would run its
  # controllers alongside the in-cluster one and race on finalizers. Stop it.
  if pgrep -f 'target/debug/operator-service' >/dev/null 2>&1; then
    warn "stopping running operator:dev processes"
    pkill -f 'target/debug/operator-service' 2>/dev/null || true
    sleep 3
  fi

  for c in "${ALL_CTXS[@]}"; do
    # minikube caches images by name; drop the old copy so the fresh build is
    # the one that gets loaded.
    minikube -p "$c" ssh "docker rmi $OPERATOR_IMAGE --force" >/dev/null 2>&1 || true
    say "loading image into $c"
    minikube -p "$c" image load "$OPERATOR_IMAGE"
    # Swap the deployment to the local image with pullPolicy=Never so it uses
    # the minikube-loaded copy instead of pulling the released tag from GHCR.
    kubectl --context "$c" -n mirrord set image deploy/mirrord-operator "mirrord-operator=$OPERATOR_IMAGE"
    kubectl --context "$c" -n mirrord patch deploy mirrord-operator --type=strategic \
      -p '{"spec":{"template":{"spec":{"containers":[{"name":"mirrord-operator","imagePullPolicy":"Never"}]}}}}'
    kubectl --context "$c" -n mirrord delete lease mirrord-operator-leader >/dev/null 2>&1 || true
    kubectl --context "$c" -n mirrord delete pod -l app.kubernetes.io/name=mirrord-operator --force --grace-period=0 >/dev/null 2>&1 || true
  done

  for c in "${ALL_CTXS[@]}"; do
    if kubectl --context "$c" -n mirrord rollout status deploy/mirrord-operator --timeout=150s >/dev/null 2>&1; then
      local img
      img=$(kubectl --context "$c" -n mirrord get deploy mirrord-operator -o jsonpath='{.spec.template.spec.containers[0].image}')
      ok "$c operator ready ($img)"
    else
      err "$c operator did not become ready"
      kubectl --context "$c" -n mirrord get pods -l app.kubernetes.io/name=mirrord-operator
    fi
  done
}

# ---------------------------------------------------------------------------
# Cleanup helpers
# ---------------------------------------------------------------------------
# Force-remove finalizers and delete any leftovers so a wedged run does not
# poison the next one. Best-effort: ignore missing resources.
scrub_cluster() {
  local c="$1"
  local kinds=(
    "previewsessions.preview.mirrord.metalbear.co"
    "mirrordclustersplitsessions.queues.mirrord.metalbear.co"
    "mirrordclusterworkloadpatchrequests.mirrord.metalbear.co"
    "mirrordclusterworkloadpatches.mirrord.metalbear.co"
  )
  for k in "${kinds[@]}"; do
    while read -r item; do
      [ -z "$item" ] && continue
      kubectl --context "$c" patch "$item" --all-namespaces=false -n "$NS" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || \
      kubectl --context "$c" patch "$item" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      kubectl --context "$c" delete "$item" --ignore-not-found >/dev/null 2>&1 || true
    done < <(kubectl --context "$c" get "$k" -A -o name 2>/dev/null)
  done
  # Pod-mutator webhooks are namespaced by name (local-dev.*.mirrord-pods-mutator).
  kubectl --context "$c" get mutatingwebhookconfiguration -o name 2>/dev/null \
    | grep -i 'mirrord-pods' \
    | xargs -r -I{} kubectl --context "$c" delete {} >/dev/null 2>&1 || true
}

pre_clean() {
  say "Pre-clean: removing any leftover preview/split/patch state"
  for c in "${ALL_CTXS[@]}"; do scrub_cluster "$c"; done
  ok "clusters scrubbed"
}

# ---------------------------------------------------------------------------
# Step 3: start the preview and wait for it to be Ready + fanned out
# ---------------------------------------------------------------------------
PREVIEW_BG_PID=""
start_preview() {
  say "Starting preview '$PREVIEW_NAME' (filter type=^${PREVIEW_NAME}-)"
  # preview start creates the in-cluster session and returns, but it can take a
  # while (image loads, pod scheduling). Run it in the background and poll the
  # primary PreviewSession for Ready so the script stays in control.
  ( task multicluster:sqs:preview:start NAME="$PREVIEW_NAME" >/tmp/mc-preview-start.log 2>&1 ) &
  PREVIEW_BG_PID=$!

  # The PreviewSession namespace differs by topology: the 3-cluster management
  # primary creates it in `mirrord`, but a 2-cluster primary (which is also the
  # default) creates it in the target namespace. Poll across all namespaces so
  # either layout is found.
  local deadline=$(( $(date +%s) + 240 ))
  local phase=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    phase=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    [ "$phase" = "Ready" ] && break
    [ "$phase" = "Failed" ] && { err "preview failed on primary"; return 1; }
    sleep 4
  done
  if [ "$phase" != "Ready" ]; then
    err "preview did not reach Ready (last phase: ${phase:-none})"
    tail -20 /tmp/mc-preview-start.log 2>/dev/null || true
    return 1
  fi
  ok "primary preview session Ready"

  wait_for_splits_ready || return 1

  # The queuesplits API reporting Ready already means every target pod is
  # patched and messages are being split, so no fixed settle is needed. WARMUP
  # stays as an optional extra cushion for the impatient.
  if [ "$WARMUP" != 0 ]; then
    say "Extra settle (${WARMUP}s)"
    sleep "$WARMUP"
  fi
}

# Wait until the operator's live queuesplits API reports every cluster's split
# Ready with its target pods patched. The primary aggregates all clusters, so a
# single -A query covers remote splits too. Gating on `patched` is what keeps
# the deployed consumer from stealing matched messages off the source queue
# before it has been moved onto the split's output queue.
# The queuesplits API reports the split's view of the target pods, but a pod
# admitted in the gap between webhook teardown (pre-clean revert) and the new
# session's webhook creation is invisible to it: it runs unpatched, reads the
# raw source queue directly and steals matched messages off it. Assert POD
# reality: every running, non-terminating consumer pod on every workload
# cluster must read a mirrord output queue (QUEUE_NAME=mirrord-*), and the old
# raw-queue pods must be fully gone.
wait_for_consumer_pods_moved() {
  local deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local raw=0
    for c in $(workload_ctxs); do
      local n
      n=$(kubectl --context "$c" -n "$NS" get pods -l app=sqs-consumer -o json 2>/dev/null         | python3 -c '
import json, sys
n = 0
for p in json.load(sys.stdin).get("items", []):
    labels = (p.get("metadata") or {}).get("labels") or {}
    if "preview.metalbear.co/session-uid" in labels:
        continue
    envs = ((p.get("spec") or {}).get("containers") or [{}])[0].get("env") or []
    q = next((e.get("value", "") for e in envs if e.get("name") == "QUEUE_NAME"), "")
    if not q.startswith("mirrord-"):
        n += 1
        print("RAW " + p["metadata"]["name"] + " QUEUE_NAME=" + (q or "?"), file=sys.stderr)
print(n)' 2>/dev/null || echo 1)
      raw=$(( raw + n ))
    done
    if [ "$raw" = 0 ]; then
      ok "all consumer pods read mirrord output queues (no raw-queue pods left)"
      return 0
    fi
    sleep 3
  done
  for c in $(workload_ctxs); do
    kubectl --context "$c" -n "$NS" get pods -l app=sqs-consumer \
      -o custom-columns='POD:.metadata.name,QUEUE:.spec.containers[0].env[?(@.name=="QUEUE_NAME")].value,DELETING:.metadata.deletionTimestamp' 2>/dev/null | sed "s/^/  [$c] /"
  done
  err "consumer pod(s) still reading the raw source queue after 120s - they would steal matched messages"
  return 1
}

wait_for_splits_ready() {
  local want; want=$(workload_ctxs | grep -c .)
  say "Waiting for $want queue split(s) to report Ready (queuesplits API)"
  local deadline=$(( $(date +%s) + 180 ))
  local total ready bad
  while [ "$(date +%s)" -lt "$deadline" ]; do
    read -r total ready bad < <(
      kubectl --context "$PRIMARY_CTX" get queuesplits -A -o json 2>/dev/null \
        | NS="$NS" TGT=sqs-consumer python3 -c '
import json, os, sys
ns = os.environ["NS"]; tgt = os.environ["TGT"]
try:
    items = [it for it in json.load(sys.stdin).get("items", [])
             if (it.get("metadata") or {}).get("namespace") == ns
             and ((it.get("spec") or {}).get("target") or {}).get("name") == tgt]
except Exception:
    print("0 0 0"); sys.exit()
total = len(items)
ready = sum(1 for it in items if ((it.get("status") or {}).get("phase")) == "Ready")
bad = sum(1 for it in items for p in ((it.get("status") or {}).get("targetPods") or [])
          if not (p.get("patched") and p.get("ready")))
print(total, ready, bad)
'
    )
    total="${total:-0}"; ready="${ready:-0}"; bad="${bad:-0}"
    if [ "$total" -ge "$want" ] && [ "$total" -gt 0 ] && [ "$ready" = "$total" ] && [ "$bad" = 0 ]; then
      ok "$total/$total queue splits Ready, all target pods patched"
      wait_for_consumer_pods_moved || return 1
      return 0
    fi
    sleep 3
  done
  err "queue splits never fully ready (want>=$want, last: total=$total ready=$ready unpatched_or_notready_pods=$bad)"
  return 1
}

# ---------------------------------------------------------------------------
# Step 4: send messages
# ---------------------------------------------------------------------------
send_messages() {
  if [ "$SEND_INTERVAL" != 0 ]; then
    say "Sending $NUM matched + $NUM unmatched messages, ${SEND_INTERVAL}s apart"
  else
    say "Sending $NUM matched + $NUM unmatched messages (burst)"
  fi
  # A burst lets whichever cluster's forwarder engages first drain the whole
  # backlog, so unmatched traffic piles onto one cluster. Spacing the sends
  # gives each cluster's forwarder poll a fresh shot at every message, which is
  # what spreads unmatched across clusters on a shared queue.
  for i in $(seq 1 "$NUM"); do
    task multicluster:sqs:send TYPE="${MATCH_PREFIX}${i}" MESSAGE="matched #$i" >/dev/null 2>&1
    task multicluster:sqs:send TYPE="${NOMATCH_PREFIX}${i}" MESSAGE="unmatched #$i" >/dev/null 2>&1
    [ "$SEND_INTERVAL" != 0 ] && sleep "$SEND_INTERVAL"
  done
  ok "sent $((NUM*2)) messages"
  say "Waiting ${CONSUME_WAIT}s for consumption"
  sleep "$CONSUME_WAIT"
}

# ---------------------------------------------------------------------------
# Step 5: routing summary
# ---------------------------------------------------------------------------
# Pull the "type=" values seen in a set of pod logs, filtered to our prefix.
types_in_logs() {  # ctx  label  prefix
  kubectl --context "$1" -n "$NS" logs -l "$2" --tail=1000 --prefix=false 2>/dev/null \
    | grep -oE "type=${3}[0-9]+" | sed 's/type=//' | sort -u
}

routing_summary() {
  say "Routing summary"
  local wl; wl=$(workload_ctxs)

  # Preview pod runs on the default workload cluster.
  local preview_ctx="" 
  for c in $wl; do
    if kubectl --context "$c" -n "$NS" get pods -l preview.metalbear.co/session-uid --no-headers 2>/dev/null | grep -q .; then
      preview_ctx="$c"; break
    fi
  done

  echo
  printf '%s\n' "${BLD}MATCHED messages (expected -> preview pod)${RST}"
  local pv_match="" pv_leak=""
  if [ -n "$preview_ctx" ]; then
    pv_match=$(types_in_logs "$preview_ctx" "preview.metalbear.co/session-uid" "$MATCH_PREFIX")
    pv_leak=$(types_in_logs "$preview_ctx" "preview.metalbear.co/session-uid" "$NOMATCH_PREFIX")
    printf '  preview pod (%s) received %s/%s matched: %s\n' \
      "$preview_ctx" "$(count "$pv_match")" "$NUM" "$(join "$pv_match")"
    [ -n "$pv_leak" ] && err "preview pod ALSO got unmatched: $(join "$pv_leak")"
  else
    err "no preview pod found on any workload cluster"
  fi

  echo
  printf '%s\n' "${BLD}UNMATCHED messages (expected -> deployed consumer)${RST}"
  local total_nomatch=""
  for c in $wl; do
    local cm cn
    # The preview pod is a copy of this deployment and carries app=sqs-consumer
    # too, so exclude it by its session-uid label to read only the real consumer.
    cn=$(types_in_logs "$c" "app=sqs-consumer,!preview.metalbear.co/session-uid" "$NOMATCH_PREFIX")
    cm=$(types_in_logs "$c" "app=sqs-consumer,!preview.metalbear.co/session-uid" "$MATCH_PREFIX")
    printf '  consumer on %-18s unmatched: %-3s %s\n' "$c" "$(count "$cn")" "$(join "$cn")"
    [ -n "$cm" ] && err "  consumer on $c ALSO got matched (should have gone to preview): $(join "$cm")"
    total_nomatch+="$cn"$'\n'
  done
  local uniq_nomatch
  uniq_nomatch=$(printf '%s' "$total_nomatch" | grep -E '.' | sort -u)
  echo
  printf '  total distinct unmatched delivered to consumers: %s/%s\n' "$(count "$uniq_nomatch")" "$NUM"

  # Verdict
  echo
  if [ "$(count "$pv_match")" = "$NUM" ] && [ -z "${pv_leak}" ] && [ "$(count "$uniq_nomatch")" = "$NUM" ]; then
    ok "${GRN}ROUTING OK${RST} - all matched hit the preview, all unmatched hit consumers"
  else
    warn "routing did not fully match expectations (see above)"
  fi
}

count() { printf '%s' "$1" | grep -cE '.' || true; }
join()  { printf '%s' "$1" | paste -sd',' - 2>/dev/null || printf '%s' "$1" | tr '\n' ',' ; }

# ---------------------------------------------------------------------------
# Step 6: stop + verify cleanup
# ---------------------------------------------------------------------------
stop_and_verify() {
  say "Stopping preview '$PREVIEW_NAME'"
  task multicluster:sqs:preview:stop NAME="$PREVIEW_NAME" >/dev/null 2>&1 || true
  [ -n "$PREVIEW_BG_PID" ] && kill "$PREVIEW_BG_PID" >/dev/null 2>&1 || true

  # Preview teardown is synchronous (finalizers), but the queue-split workload
  # patch is torn down asynchronously and can lag by a minute, so poll instead
  # of judging on a single early snapshot.
  say "Waiting for teardown to propagate (up to ${CLEANUP_TIMEOUT}s)"
  local deadline=$(( $(date +%s) + CLEANUP_TIMEOUT ))
  local leaks=0
  while :; do
    leaks=0
    for c in "${ALL_CTXS[@]}"; do
      local ps ss wp
      ps=$(kubectl --context "$c" get previewsessions.preview.mirrord.metalbear.co -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
      ss=$(kubectl --context "$c" get mirrordclustersplitsessions.queues.mirrord.metalbear.co -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
      wp=$(kubectl --context "$c" get mirrordclusterworkloadpatch,mirrordclusterworkloadpatchrequest -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
      [ "$ps" = 0 ] && [ "$ss" = 0 ] && [ "$wp" = 0 ] || leaks=$((leaks+1))
    done
    { [ "$leaks" = 0 ] || [ "$(date +%s)" -ge "$deadline" ]; } && break
    sleep 6
  done

  for c in "${ALL_CTXS[@]}"; do
    local ps ss wp
    ps=$(kubectl --context "$c" get previewsessions.preview.mirrord.metalbear.co -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ss=$(kubectl --context "$c" get mirrordclustersplitsessions.queues.mirrord.metalbear.co -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    wp=$(kubectl --context "$c" get mirrordclusterworkloadpatch,mirrordclusterworkloadpatchrequest -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$ps" = 0 ] && [ "$ss" = 0 ] && [ "$wp" = 0 ]; then
      ok "$c clean (no preview/split/patch resources)"
    else
      err "$c leftovers: previewsessions=$ps splitsessions=$ss patches=$wp"
      kubectl --context "$c" get previewsessions.preview.mirrord.metalbear.co -A \
        -o custom-columns='NAME:.metadata.name,DEL:.metadata.deletionTimestamp,FIN:.metadata.finalizers' 2>/dev/null | sed 's/^/      /'
    fi
  done

  # Consumers should be back on the original queue (unpatched).
  local wl; wl=$(workload_ctxs)
  for c in $wl; do
    local q
    q=$(kubectl --context "$c" -n "$NS" get deploy sqs-consumer -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="QUEUE_NAME")].value}' 2>/dev/null)
    [ "$q" = "test-queue" ] && ok "$c consumer unpatched (QUEUE_NAME=$q)" || warn "$c consumer QUEUE_NAME=$q (expected test-queue)"
  done

  echo
  if [ "$leaks" = 0 ]; then
    ok "${GRN}CLEANUP OK${RST} - no dangling resources on any cluster"
  else
    err "${RED}CLEANUP FAILED${RST} - $leaks cluster(s) had leftovers"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
say "Contexts: ${ALL_CTXS[*]}  (MC_NUM_CLUSTERS=$MC_NUM_CLUSTERS, NUM=$NUM)"

[ "$DEPLOY_OPERATOR" = 1 ] && deploy_operator

if [ "$REDEPLOY_SQS" = 1 ]; then
  say "Deploying SQS test env"
  task multicluster:sqs:deploy
fi

pre_clean
start_preview || { err "aborting - preview did not start"; stop_and_verify; exit 1; }
send_messages
routing_summary

if [ "$KEEP" = 1 ]; then
  warn "KEEP=1 set - leaving preview '$PREVIEW_NAME' running; stop it with:"
  echo "    task multicluster:sqs:preview:stop NAME=$PREVIEW_NAME"
else
  stop_and_verify
fi

say "Done."
