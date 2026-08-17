#!/usr/bin/env bash
# Interactive runner for the linkerd-repro module (Torq "no live mirrord-agents"
# incident). Wraps the task targets in a gum menu, streams every command's
# output live, and records each repro run under .linkerd-repro-logs/.
#
#   ./scripts/linkerd-repro.sh          (or: task linkerd-repro:ui)
#
# Requires: gum (brew install gum), task, kubectl, mirrord.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"
NS="torq-repro"
CONFIG="$ROOT/configs/linkerd-repro.mirrord.json"
LOG_ROOT="$ROOT/.linkerd-repro-logs"

# ── style helpers ────────────────────────────────────────────────────────────

title() { gum style --foreground 212 --bold "$*"; }
ok()    { gum style --foreground 42 "$*"; }
bad()   { gum style --foreground 196 "$*"; }
dim()   { gum style --foreground 245 "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "missing dependency: $1  ($2)" >&2
  exit 1
}

need gum "brew install gum"
need task "brew install go-task"
need kubectl "brew install kubectl"
command -v "$MIRRORD_BIN" >/dev/null 2>&1 || { echo "mirrord binary '$MIRRORD_BIN' not found (set MIRRORD_BIN)"; exit 1; }

k() { kubectl --request-timeout=4s "$@" 2>/dev/null; }

# ── state header ─────────────────────────────────────────────────────────────

operator_tag() {
  k get deploy mirrord-operator -n mirrord -o jsonpath='{.spec.template.spec.containers[0].image}' | awk -F: '{print $NF}'
}

operator_meshed() {
  # Reads the running pod, not the deployment: the answer must reflect what is
  # actually serving sessions right now. linkerd edge injects the proxy as a
  # native sidecar, so initContainers count too.
  local pod containers
  pod=$(k get pods -n mirrord -l app=mirrord-operator --sort-by=.metadata.creationTimestamp -o name | tail -1)
  [[ -z "$pod" ]] && { echo "no pod"; return; }
  containers=$(k get "$pod" -n mirrord -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}')
  [[ -z "$containers" ]] && { echo "no pod"; return; }
  case "$containers" in
    *linkerd-proxy*) echo "MESHED" ;;
    *) echo "unmeshed" ;;
  esac
}

header() {
  local ctx op mesh linkerd target agents
  ctx=$(kubectl config current-context 2>/dev/null || echo "?")
  op=$(operator_tag); [[ -z "$op" ]] && op="not installed"
  mesh=$(operator_meshed)
  linkerd=$(k get ns linkerd -o name >/dev/null && echo "installed" || echo "absent")
  target=$(k get pods -n "$NS" -l app=alert-triage --no-headers | awk '$3=="Running"' | wc -l | tr -d ' ')
  agents=$(k get pods -A --no-headers | grep -c mirrord-agent || true)

  local mesh_line
  if [[ "$mesh" == "MESHED" ]]; then
    mesh_line="$(bad "operator $op  |  $mesh (customer's failing setup)")"
  else
    mesh_line="$(ok "operator $op  |  $mesh")"
  fi

  gum style --border rounded --border-foreground 212 --padding "0 2" --margin "1 0" \
    "$(title "linkerd repro - Torq incident")" \
    "context $ctx  |  linkerd $linkerd  |  target pods $target/2  |  agent pods now: $agents" \
    "$mesh_line"
}

# ── agent watcher (background, logs to file) ─────────────────────────────────

WATCHER_PID=""

start_watcher() {
  local log="$1"
  (
    while true; do
      ts=$(date +%H:%M:%S)
      pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep mirrord-agent || true)
      count=0; [[ -n "$pods" ]] && count=$(printf '%s\n' "$pods" | wc -l | tr -d ' ')
      echo "[$ts] count=$count"
      [[ -n "$pods" ]] && printf '%s\n' "$pods" | awk '{printf "  %s/%s %s %s\n", $1, $2, $4, $5}'
      sleep 0.4
    done
  ) >"$log" &
  WATCHER_PID=$!
}

stop_watcher() {
  [[ -n "$WATCHER_PID" ]] && kill "$WATCHER_PID" 2>/dev/null
  WATCHER_PID=""
}
trap stop_watcher EXIT

# ── actions ──────────────────────────────────────────────────────────────────

action_deploy() {
  title "Deploying the full meshed environment (streams everything, takes a while)"
  task -d "$ROOT" linkerd-repro:deploy
}

action_repro() {
  local attempts
  attempts=$(gum input --header "How many back-to-back attempts?" --value "12") || return
  [[ -z "$attempts" ]] && return

  local run_dir="$LOG_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$run_dir"
  local agent_log="$run_dir/agent-pods.log"

  title "Repro: $attempts attempts | mesh: $(operator_meshed) | operator: $(operator_tag)"
  dim  "logs: $run_dir  (agent watcher: tail -f $agent_log)"
  start_watcher "$agent_log"

  local pass=0 fail=0 rows="attempt,result,seconds,error"
  for i in $(seq 1 "$attempts"); do
    local out="$run_dir/attempt-$i.log" start end secs result err=""
    echo ""
    title "── attempt $i/$attempts ──"
    start=$(date +%s)
    if MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" exec -f "$CONFIG" -- \
         sh -c 'curl -sf --max-time 10 "$BACKEND_URL" >/dev/null && echo "outgoing OK"' 2>&1 | tee "$out"; then
      result=SUCCESS; pass=$((pass+1))
    else
      result=FAIL; fail=$((fail+1))
      if grep -q "no live mirrord-agents" "$out"; then err="timeout: no live agents (variant A)"
      elif grep -q "no response received" "$out"; then err="no response during version check (variant B)"
      else err=$(grep -m1 -oE "Error:.*" "$out" | cut -c1-60); fi
      err=${err//,/;}   # keep the summary CSV parseable
    fi
    end=$(date +%s); secs=$((end-start))
    rows="$rows
$i,$result,$secs,$err"
    if [[ "$result" == SUCCESS ]]; then ok "attempt $i: SUCCESS in ${secs}s"; else bad "attempt $i: FAIL in ${secs}s  $err"; fi
    dim "running total: $pass pass / $fail fail"
  done

  stop_watcher
  local distinct
  distinct=$(grep -oE 'mirrord-agent-[a-z0-9-]+' "$agent_log" | sort -u | wc -l | tr -d ' ')

  echo ""
  title "Summary"
  echo "$rows" | gum table --print
  echo ""
  [[ "$fail" -gt 0 ]] && bad "$pass/$attempts succeeded" || ok "$pass/$attempts succeeded"
  echo "distinct agent pods observed during the run: $distinct  (customer saw ~20 per failed attempt)"
  dim "customer baseline: ~1/3 degrading to 0/12, every failure ~63s"
  dim "full logs: $run_dir"
  echo ""
  gum confirm "Check sessions for ghosts now (status vs CRs)?" && action_sessions
}

action_single() {
  title "Single attempt (streaming)"
  MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" exec -f "$CONFIG" -- \
    sh -c 'echo "BACKEND_URL=$BACKEND_URL"; curl -sf --max-time 10 "$BACKEND_URL" >/dev/null && echo "outgoing OK"'
}

action_watch() {
  title "Agent pod watcher (0.4s poll). Ctrl-C to return to the menu."
  task -d "$ROOT" linkerd-repro:watch:agents || true
}

action_sessions() {
  title "operator status (in-memory watch cache) vs session CRs (apiserver)"
  local status_out crd_out status_n crd_n
  status_out=$("$MIRRORD_BIN" operator status 2>&1 || true)
  crd_out=$(kubectl get mirrordclustersessions 2>&1 || true)
  echo "$status_out"
  echo ""
  echo "=== mirrordclustersessions ==="
  echo "$crd_out"
  echo ""
  status_n=$(echo "$status_out" | grep -cE '^\| [0-9A-F]{16} ' || true)
  crd_n=$(echo "$crd_out" | grep -cv -e '^NAME' -e 'No resources found' -e '^$' || true)
  if [[ "$status_n" -gt "$crd_n" ]]; then
    bad "GHOSTS: status lists $status_n session(s), apiserver has $crd_n CR(s) - the operator's watch cache is stale (the customer's leak)"
  else
    ok "consistent: status=$status_n crs=$crd_n"
  fi
}

action_mesh_toggle() {
  local mesh; mesh=$(operator_meshed)
  if [[ "$mesh" == "MESHED" ]]; then
    gum confirm "Operator is MESHED. Un-mesh it (the proposed fix)?" || return
    task -d "$ROOT" linkerd-repro:mesh:off
  else
    gum confirm "Operator is unmeshed. Mesh it (reproduce the customer setup)?" || return
    task -d "$ROOT" linkerd-repro:mesh:on
  fi
}

action_switch_operator() {
  local ver
  ver=$(gum choose --header "Operator version" "3.190.0 (customer's, has the bug context)" "3.193.0 (latest, with the session fixes)" "other") || return
  case "$ver" in
    3.190.0*) ver=3.190.0 ;;
    3.193.0*) ver=3.193.0 ;;
    other) ver=$(gum input --header "version" --value "3.191.0") || return ;;
  esac
  [[ -z "$ver" ]] && return
  title "Deploying operator $ver (helm upgrade resets the mesh annotation)"
  task -d "$ROOT" linkerd-repro:operator:deploy OPERATOR_VERSION="$ver"
  if gum confirm "Mesh the new operator pod (customer setup)?"; then
    task -d "$ROOT" linkerd-repro:mesh:on
  else
    task -d "$ROOT" linkerd-repro:mesh:off
  fi
}

action_logs() {
  title "Operator log lines relevant to the incident"
  task -d "$ROOT" linkerd-repro:logs:operator || true
}

action_clean() {
  gum confirm "Delete namespace $NS? (operator and linkerd stay)" || return
  task -d "$ROOT" linkerd-repro:clean
}

# ── menu loop ────────────────────────────────────────────────────────────────

while true; do
  header
  choice=$(gum choose --header "What now?" \
    "repro loop (back-to-back attempts)" \
    "single attempt" \
    "watch agent pods" \
    "sessions: ghosts check" \
    "mesh toggle (A/B experiment)" \
    "switch operator version" \
    "operator incident logs" \
    "deploy full environment" \
    "clean target namespace" \
    "quit") || exit 0

  case "$choice" in
    "repro loop"*) action_repro ;;
    "single attempt") action_single ;;
    "watch agent pods") action_watch ;;
    "sessions"*) action_sessions ;;
    "mesh toggle"*) action_mesh_toggle ;;
    "switch operator"*) action_switch_operator ;;
    "operator incident logs") action_logs ;;
    "deploy full"*) action_deploy ;;
    "clean"*) action_clean ;;
    quit) exit 0 ;;
  esac

  echo ""
  gum input --placeholder "enter to continue..." >/dev/null || true
done
