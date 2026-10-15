#!/usr/bin/env bash
# Brings the local multicluster sandbox to a ready state for the INT-745
# `mirrord subscribe` suite WITHOUT tearing anything down: every step looks
# first and acts only on what is missing or stale.
#
#   1. clusters      - minikube profiles Running? resume stopped ones, create
#                      only when none exist (task multicluster:up)
#   2. operators     - mirrord-operator deployed on every cluster? else
#                      task multicluster:operator:use VERSION=<VERSION>
#   3. credentials   - primary reports every linked cluster Connected? else
#                      task multicluster:secrets:refresh (tokens die when idle)
#   4. CRDs + roles  - task multicluster:crds (server-side apply, seconds; this
#                      is what gives members the `events` grant)
#   5. echo-app      - deployed on every workload cluster? else
#                      task multicluster:http:deploy
#   6. CLI           - the mirrord binary knows keyless subscribe? else
#                      task mirrord:cli:build (arm64-only, from ../mirrord)
#   7. operators     - the primary advertises MultiClusterSubscribe AND every
#                      cluster is served by a local operator:dev? else starts the
#                      missing ones as background steals via
#                      scripts/multicluster-dev-operators.sh (logs under
#                      /tmp/mc-operator-dev/<cluster>.log). Both must be local:
#                      the isolation marker makes a deployed member ignore the
#                      dev primary's child sessions. DEV=wait prints the
#                      commands and waits for you instead; OPERATOR=custom
#                      deploys your image everywhere instead.
#
# Usage:
#   ./scripts/multicluster-prepare.sh                 # 2 clusters, released operators
#   MC_NUM_CLUSTERS=3 ./scripts/multicluster-prepare.sh
#   OPERATOR=custom ./scripts/multicluster-prepare.sh  # task op:custom instead of operator:dev
#
# Env knobs (defaults): VERSION=latest (released operator for a fresh install),
#   MIRRORD_BIN / MIRRORD_DIR, NAMESPACE=test-mirrord, BUILD_CLI=1 forces the
#   CLI build, SKIP_CRDS=1 skips step 4, WAIT_OPERATOR=900 seconds to wait for
#   the dev operator, MC_PRIMARY / MC_REMOTE_1 / MC_REMOTE_2 contexts.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MIRRORD_DIR="${MIRRORD_DIR:-$SANDBOX_DIR/../mirrord}"
NS="${NAMESPACE:-test-mirrord}"
MC="${MC_NUM_CLUSTERS:-2}"
export MC_NUM_CLUSTERS="$MC"
VERSION="${VERSION:-latest}"
PRIMARY="${MC_PRIMARY:-mirrord-primary}"
REMOTE1="${MC_REMOTE_1:-mirrord-remote-1}"
REMOTE2="${MC_REMOTE_2:-mirrord-remote-2}"
if [ "$MC" = "3" ]; then
  ALL_CTXS="$PRIMARY $REMOTE1 $REMOTE2"; WORKLOAD_CTXS="$REMOTE1 $REMOTE2"
else
  ALL_CTXS="$PRIMARY $REMOTE1"; WORKLOAD_CTXS="$PRIMARY $REMOTE1"
fi
WAIT_OPERATOR="${WAIT_OPERATOR:-900}"

if [ -z "${MIRRORD_BIN:-}" ] && [ -f "$SANDBOX_DIR/.env" ]; then
  MIRRORD_BIN=$(grep -E '^MIRRORD_BIN=' "$SANDBOX_DIR/.env" | tail -1 | cut -d= -f2-)
fi
MIRRORD_BIN="${MIRRORD_BIN:-$MIRRORD_DIR/target/debug/mirrord}"

# ── output ──────────────────────────────────────────────────────────────────
HAVE_GUM=0
command -v gum >/dev/null 2>&1 && HAVE_GUM=1
[ -t 1 ] || HAVE_GUM=0
header() {
  if [ "$HAVE_GUM" = 1 ]; then gum style --border rounded --padding "0 2" --margin "1 0" --bold "$*"
  else printf '\n\033[1m== %s ==\033[0m\n' "$*"; fi
}
info() { if [ "$HAVE_GUM" = 1 ]; then gum log --level info "$*"; else printf '  %s\n' "$*"; fi; }
warn() { if [ "$HAVE_GUM" = 1 ]; then gum log --level warn "$*"; else printf '  \033[33mWARN\033[0m %s\n' "$*"; fi; }
fail() { if [ "$HAVE_GUM" = 1 ]; then gum log --level error "$*"; else printf '  \033[31mFAIL\033[0m %s\n' "$*"; fi; }
ok()   { if [ "$HAVE_GUM" = 1 ]; then gum log --level info "OK   $*"; else printf '  \033[32mOK\033[0m   %s\n' "$*"; fi; }
run()  { info "-> $*"; "$@"; }
DONE=()
note() { DONE+=("$1"); }

t() { task -d "$SANDBOX_DIR" "$@"; }

# ── 1. clusters ──────────────────────────────────────────────────────────────
header "1/7 clusters ($MC): $ALL_CTXS"
MISSING=""
for CTX in $ALL_CTXS; do
  STATE=$(minikube status -p "$CTX" --format '{{.Host}}' 2>/dev/null || true)
  case "$STATE" in
    Running) ok "$CTX running" ;;
    Stopped)
      run minikube start -p "$CTX" >/dev/null || { fail "could not resume $CTX"; exit 1; }
      ok "$CTX resumed"; note "resumed $CTX" ;;
    *) warn "$CTX missing"; MISSING="$MISSING $CTX" ;;
  esac
done
if [ -n "$MISSING" ]; then
  # multicluster:up is safe on a partial set: `minikube start` is a no-op for a
  # profile that already runs, and every install step is an upgrade-or-install.
  info "creating:$MISSING (task multicluster:up, keeps the running ones)"
  t multicluster:up VERSION="$VERSION" || { fail "task multicluster:up failed"; exit 1; }
  note "created clusters:$MISSING"
fi

# ── 2. operators ─────────────────────────────────────────────────────────────
header "2/7 operators"
NEED_OPERATORS=0
for CTX in $ALL_CTXS; do
  if kubectl --context "$CTX" get deploy mirrord-operator -n mirrord >/dev/null 2>&1; then
    ok "$CTX has mirrord-operator"
  else
    warn "$CTX has no mirrord-operator"; NEED_OPERATORS=1
  fi
done
if [ "$NEED_OPERATORS" = 1 ]; then
  t multicluster:operator:use VERSION="$VERSION" || { fail "task multicluster:operator:use failed"; exit 1; }
  note "installed released operators ($VERSION)"
fi
for CTX in $ALL_CTXS; do
  kubectl --context "$CTX" rollout status deploy/mirrord-operator -n mirrord --timeout=180s >/dev/null 2>&1 \
    || warn "$CTX: mirrord-operator not available yet (operator:dev replaces its pod with a sleeper, that is fine)"
done

# ── 3. credentials ───────────────────────────────────────────────────────────
header "3/7 cross-cluster credentials"
DEV_RUNNING=0
pgrep -qf 'target/debug/operator-service' && DEV_RUNNING=1
cluster_errors() {
  local json
  json=$(kubectl --context "$PRIMARY" get mirrordoperators operator -o json 2>/dev/null) || return 2
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '(.status.connectedClusters // .status.connected_clusters // [])[] | select(.error != null or .message != null) | .name' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"name":"[^"]*","lastCheck":"[^"]*","error"' | cut -d'"' -f4
  fi
}
ERRS=$(cluster_errors); RC=$?
if [ "$RC" = 2 ]; then
  warn "cannot read the operator status on $PRIMARY yet"
elif [ -n "$ERRS" ]; then
  warn "linked clusters in error: $(echo "$ERRS" | tr '\n' ' ')"
  if [ "$DEV_RUNNING" = 1 ]; then
    warn "operator:dev is serving: restart it (it re-mints the tokens on start) - task multicluster:operator:primary"
  else
    t multicluster:secrets:refresh || warn "task multicluster:secrets:refresh failed"
    note "refreshed remote-cluster tokens"
    waited=0
    while [ "$waited" -lt 120 ]; do
      [ -z "$(cluster_errors)" ] && break
      sleep 10; waited=$((waited + 10))
    done
    [ -z "$(cluster_errors)" ] && ok "every linked cluster connected" || warn "still in error after ${waited}s: $(cluster_errors | tr '\n' ' ')"
  fi
else
  ok "every linked cluster connected"
fi

# ── 4. CRDs + member roles ───────────────────────────────────────────────────
header "4/7 local-chart CRDs and envoy roles"
if [ "${SKIP_CRDS:-0}" = 1 ]; then
  info "SKIP_CRDS=1"
else
  t multicluster:crds >/dev/null || { fail "task multicluster:crds failed"; exit 1; }
  for CTX in $ALL_CTXS; do
    [ "$CTX" = "$PRIMARY" ] && continue
    if kubectl --context "$CTX" get clusterrole mirrord-operator-envoy-remote -o json 2>/dev/null | grep -q '"events"'; then
      ok "$CTX: mirrord-operator-envoy-remote grants events"
    else
      fail "$CTX: mirrord-operator-envoy-remote still lacks events (is ../operator on the INT-745 branch?)"; exit 1
    fi
  done
  note "applied local-chart CRDs and roles"
fi

# ── 5. echo-app ──────────────────────────────────────────────────────────────
header "5/7 echo-app on $WORKLOAD_CTXS"
NEED_APP=0
for CTX in $WORKLOAD_CTXS; do
  if kubectl --context "$CTX" get deploy echo-app -n "$NS" >/dev/null 2>&1; then
    ok "$CTX has echo-app"
  else
    warn "$CTX has no echo-app"; NEED_APP=1
  fi
done
if [ "$NEED_APP" = 1 ]; then
  t multicluster:http:deploy || { fail "task multicluster:http:deploy failed"; exit 1; }
  note "deployed echo-app"
fi

# ── 6. CLI ───────────────────────────────────────────────────────────────────
header "6/7 mirrord CLI"
cli_is_current() {
  [ -x "$MIRRORD_BIN" ] && "$MIRRORD_BIN" subscribe --help 2>/dev/null | grep -q "every session"
}
if [ "${BUILD_CLI:-0}" != 1 ] && cli_is_current; then
  ok "$MIRRORD_BIN knows keyless subscribe"
else
  [ -d "$MIRRORD_DIR" ] || { fail "mirrord checkout not found at $MIRRORD_DIR"; exit 1; }
  # arm64-only build for this Mac (xtask build-cli wants the x86_64 target too);
  # CI=true answers pnpm's interactive purge prompt in the UI asset step.
  info "building the CLI from $MIRRORD_DIR (task mirrord:cli:build)"
  (cd "$SANDBOX_DIR" && CI=true task mirrord:cli:build) || { fail "task mirrord:cli:build failed"; exit 1; }
  cli_is_current || { fail "$MIRRORD_BIN still lacks keyless subscribe - is ../mirrord on the INT-745 branch, and MIRRORD_BIN pointing at its build?"; exit 1; }
  note "built the CLI"
fi

# ── 7. operators from the branch on every cluster ───────────────────────────
header "7/7 operators from the branch on: $ALL_CTXS"
primary_advertises() {
  kubectl --context "$PRIMARY" get mirrordoperators operator -o json 2>/dev/null \
    | grep -q '"MultiClusterSubscribe"\|"multi_cluster_subscribe"\|"multiClusterSubscribe"'
}
# operator:dev swaps the deployed pod for a sleeper and steals its port from a
# local operator-service, so "dev on this cluster" = sleeper image + a local
# process for it. One process per dev-patched cluster is the sign all are up.
dev_patched() { kubectl --context "$1" get deploy mirrord-operator -n mirrord -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -q busybox; }
dev_processes() { pgrep -f 'target/debug/operator-service' 2>/dev/null | wc -l | tr -d ' '; }
missing_dev() {
  local want=0 names=""
  for CTX in $ALL_CTXS; do
    if dev_patched "$CTX"; then want=$((want + 1)); else names="$names $CTX"; fi
  done
  [ "$(dev_processes)" -ge "$want" ] && [ -z "$names" ] && return 1
  [ -n "$names" ] && echo "$names" || echo " (a dev-patched cluster has no local operator-service process)"
}
all_ready() { primary_advertises && ! missing_dev >/dev/null; }

if all_ready; then
  ok "primary advertises MultiClusterSubscribe and every cluster runs a local operator:dev"
elif [ "${OPERATOR:-dev}" = "custom" ]; then
  info "OPERATOR=custom: building the image if missing and deploying it everywhere (task op:custom)"
  t op:custom || { fail "task op:custom failed"; exit 1; }
  note "deployed mirrord-operator:custom"
  waited=0
  until primary_advertises || [ "$waited" -ge 180 ]; do sleep 10; waited=$((waited + 10)); done
  primary_advertises || { fail "the custom operator does not advertise MultiClusterSubscribe"; exit 1; }
else
  if primary_advertises; then
    warn "the primary is served from the branch, but these clusters are not:$(missing_dev)"
  elif [ "$(dev_processes)" -gt 0 ]; then
    warn "a local operator:dev runs but the primary does not advertise MultiClusterSubscribe - restart it from the INT-745 branch"
  else
    warn "no operator from the branch is serving yet"
  fi
  if [ "${DEV:-start}" = "start" ]; then
    info "starting the missing dev operators in the background (DEV=wait to do it yourself)"
    "$SCRIPT_DIR/multicluster-dev-operators.sh" start || { fail "could not start every dev operator"; exit 1; }
    note "started dev operators (logs under ${MC_DEV_LOG_DIR:-/tmp/mc-operator-dev})"
  fi
  echo
  echo "  Run these in SEPARATE terminals, one after the other (the first cargo build holds the target lock):"
  for CTX in $ALL_CTXS; do
    case "$CTX" in
      "$PRIMARY") echo "      cd $SANDBOX_DIR && task multicluster:operator:primary" ;;
      "$REMOTE1") echo "      cd $SANDBOX_DIR && task multicluster:operator:remote-1" ;;
      "$REMOTE2") echo "      cd $SANDBOX_DIR && task multicluster:operator:remote-2" ;;
    esac
  done
  echo
  info "waiting up to ${WAIT_OPERATOR}s (OPERATOR=custom deploys your image instead)"
  waited=0
  until all_ready || [ "$waited" -ge "$WAIT_OPERATOR" ]; do sleep 10; waited=$((waited + 10)); done
  all_ready || { fail "gave up after ${WAIT_OPERATOR}s; still missing:$(missing_dev)"; exit 1; }
  ok "primary advertises MultiClusterSubscribe and every cluster runs a local operator:dev"
fi

# ── summary ──────────────────────────────────────────────────────────────────
header "Ready"
if [ "${#DONE[@]}" = 0 ]; then
  info "nothing to do, everything was already in place"
else
  for line in "${DONE[@]}"; do printf '  %s\n' "$line"; done
fi
echo
echo "Next:"
echo "  task multicluster:test:subscribe          # the INT-745 suite"
echo "  task multicluster:subscribe KEY=<key>     # watch a session across clusters by hand"
