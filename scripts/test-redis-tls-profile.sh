#!/usr/bin/env bash
#
# End-to-end test: Redis TLS under a NAMED PROFILE (the Teladoc INT shape).
#
# Customer setup being simulated: the admin keeps the TLS Redis baseline in
# `redisBranchConfig.profiles.<name>` and branches select it with
# `"profile": "<name>"`. Two cases:
#
#   1. PROFILE-TLS:  tls/dbServerArgs correctly nested under the profile's
#                    dbPod -> the branch reaches Ready and the pod is TLS-only
#                    (plain PING rejected, TLS PING answers PONG).
#   2. MISPLACED:    `tls: true` written BESIDE the profile's dbPod - the exact
#                    misconfiguration Teladoc hit. An operator without the
#                    unknown-key validation silently drops the key and the
#                    branch hangs forever; with it, the branch fails fast with
#                    a did-you-mean error naming `profiles.<name>.dbPod.tls`.
#
# The script deploys the redis test env and builds the TLS redis image itself
# when they are missing, swaps configs/redis-branch-config.yaml for each case
# (the operator re-reads it every 60s), and restores everything on exit.
#
# Prerequisites:
#   - minikube (bearkube) running with an operator that carries the fix:
#     `task operator:dev` from the current operator checkout is the usual way
#     (the script labels its sessions for it, like the redis:* tasks do), and
#     needs mirrord-branch-init:local loaded (task redis:tls:build:init-image -
#     the script offers to build it, SLOW first run)
#
# Usage:
#   scripts/test-redis-tls-profile.sh              # both cases
#   scripts/test-redis-tls-profile.sh good         # only case 1
#   scripts/test-redis-tls-profile.sh misplaced    # only case 2, and shows the
#                                                  # error the way a developer and
#                                                  # an admin each see it; the
#                                                  # Failed CR is left to inspect
#                                                  # (TTL deletes it in ~5 min)
#   task redis:tls:test:profile                    # both cases
#   task redis:tls:show:error                      # the misplaced demo
#   KEEP=1 scripts/test-redis-tls-profile.sh    # leave branches + config in place
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI to use (default: local debug build, then PATH)
#   READY_TIMEOUT   seconds for a branch to reach Ready/Failed (default 300)
#   RELOAD_WAIT     seconds to wait after swapping the branch config (default 70,
#                   the operator re-reads the file every 60s)
#   CLUSTER_NAME    minikube profile (default bearkube)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="redis-test"
CLUSTER_NAME="${CLUSTER_NAME:-bearkube}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
RELOAD_WAIT="${RELOAD_WAIT:-70}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"
BRANCH_CONFIG="$ROOT_DIR/configs/redis-branch-config.yaml"
BRANCH_PASS="mirrord-redis-branch-pod-pass"
PROFILE_NAME="tls-baseline"

# all | good | misplaced. The misplaced-only mode is the "show me the error"
# demo: it keeps the Failed CR around for inspection (the branch's own TTL
# deletes it within ~5 minutes) while still restoring the branch config.
ONLY_CASE="${1:-all}"
case "$ONLY_CASE" in all|good|misplaced) ;; *)
  printf 'usage: %s [good|misplaced]\n' "$0"; exit 2 ;;
esac
KEEP_BAD=0
[ "$ONLY_CASE" = "misplaced" ] && KEEP_BAD=1

LOCAL_MIRRORD="$SCRIPT_DIR/../../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/redis-tls-profile.XXXXXX)"
# Per-run tag so a stale branch from an earlier run cannot satisfy this run's
# checks (branch CRD names derive from the id).
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"

TLS_BRANCH_ID="redis-tls-profile-$RUN_TAG"
BAD_BRANCH_ID="redis-tls-misplaced-$RUN_TAG"
SESSION_PID=""
SAVED_CONFIG="$WORKDIR/redis-branch-config.original.yaml"

# ---------------------------------------------------------------------------
# Output helpers - gum when installed, plain ANSI otherwise
# ---------------------------------------------------------------------------
HAVE_GUM=0
command -v gum >/dev/null 2>&1 && HAVE_GUM=1
# gum's spin/confirm need a terminal; fall back to plain output when piped.
[ -t 1 ] || HAVE_GUM=0

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

spin() { # <title> <command...>
  local title="$1"; shift
  if [ "$HAVE_GUM" = 1 ]; then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    info "$title"
    "$@"
  fi
}

confirm() { # <question>  -> 0 yes / 1 no
  if [ "$HAVE_GUM" = 1 ]; then
    gum confirm "$1" </dev/tty
  else
    printf '%s [y/N] ' "$1"
    local answer; read -r answer </dev/tty
    [ "$answer" = y ] || [ "$answer" = Y ]
  fi
}

FAILURES=0
check() { # <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; FAILURES=$((FAILURES + 1)); fi
}

branch_name_by_id() { # <branch-id>
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg id "$1" \
        '.items[] | select(.spec.id == $id) | .metadata.name' | head -1
}

branch_field() { # <branch-name> <jsonpath>
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" "$1" -o jsonpath="$2" 2>/dev/null
}

kill_session() {
  [ -n "$SESSION_PID" ] && kill "$SESSION_PID" >/dev/null 2>&1
  SESSION_PID=""
}

cleanup() {
  kill_session
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1 - leaving the branches and the swapped branch config in place"
    warn "  branch ids: $TLS_BRANCH_ID $BAD_BRANCH_ID"
    warn "  restore the config with: cp $SAVED_CONFIG $BRANCH_CONFIG"
    return
  fi
  local id name
  for id in "$TLS_BRANCH_ID" "$BAD_BRANCH_ID"; do
    if [ "$id" = "$BAD_BRANCH_ID" ] && [ "$KEEP_BAD" = 1 ]; then
      name="$(branch_name_by_id "$id")"
      if [ -n "$name" ]; then
        warn "leaving the Failed branch for inspection (its TTL deletes it in ~5 min):"
        printf '  kubectl get %s -n %s %s -o jsonpath={.status.error}\n' \
          "$BRANCH_CRD" "$NAMESPACE" "$name"
      fi
      continue
    fi
    name="$(branch_name_by_id "$id")"
    [ -n "$name" ] && kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" "$name" \
      --ignore-not-found >/dev/null 2>&1
  done
  if [ -f "$SAVED_CONFIG" ]; then
    cp "$SAVED_CONFIG" "$BRANCH_CONFIG"
    info "restored $BRANCH_CONFIG (the operator re-reads it within ~60s)"
  fi
  info "cleaned up branches and session"
}
trap cleanup EXIT

# Swap the live branch config and sit out the operator's 60s re-read cycle.
swap_config() { # <new-config-file> <label>
  cp "$1" "$BRANCH_CONFIG"
  spin "branch config -> $2 (waiting ${RELOAD_WAIT}s for the operator re-read)" \
    sleep "$RELOAD_WAIT"
}

# Waits for the branch CRD with the given id; fails the run if the watched
# process dies first (its log tail is the diagnosis).
wait_branch() { # <branch-id> <watched-pid> <log>  -> prints branch name
  local branch="" waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    branch="$(branch_name_by_id "$1")"
    [ -n "$branch" ] && { printf '%s' "$branch"; return 0; }
    if [ -n "$2" ] && ! kill -0 "$2" 2>/dev/null; then
      fail "mirrord exited before the branch CRD (id=$1) appeared - log tail:" >&2
      tail -20 "$3" >&2
      return 1
    fi
    sleep 3; waited=$((waited + 3))
  done
  fail "branch CRD (id=$1) never appeared - is an operator watching? See $3" >&2
  return 1
}

wait_branch_phase() { # <branch-name> <wanted-phase>  -> 0 when reached
  local phase="" waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    phase="$(branch_field "$1" '{.status.phase}')"
    [ "$phase" = "$2" ] && return 0
    # The other terminal phase means the case already went the wrong way; stop
    # waiting so the caller reports with the CRD's own error attached.
    case "$phase" in Ready|Failed) return 1 ;; esac
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

# Render the misplaced-key failure from both angles: the miette error the
# developer's `mirrord exec` printed, and the CR's status.error the admin reads.
show_error_views() { # <branch-name> <session-log>
  local branch="$1" log="$2" cli_error
  cli_error="$(sed -n '/^Error:/,/help:/p' "$log" | sed '/help:/,$d')"

  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border double --padding "0 2" --margin "1 0" --border-foreground 212 \
      "What the DEVELOPER sees (mirrord exec):" "" "$cli_error"
    gum style --border double --padding "0 2" --margin "1 0" --border-foreground 99 \
      "What the ADMIN sees on the CR:" "" \
      "$(branch_field "$branch" '{.status.error}')"
  else
    printf '\n\033[1m-- what the DEVELOPER sees (mirrord exec) --\033[0m\n%s\n' "$cli_error"
    printf '\n\033[1m-- what the ADMIN sees on the CR --\033[0m\n%s\n' \
      "$(branch_field "$branch" '{.status.error}')"
  fi
  info "see it yourself:"
  printf '  kubectl get %s -n %s %s -o jsonpath={.status.error}\n' \
    "$BRANCH_CRD" "$NAMESPACE" "$branch"
}

launch_session() { # <mirrord-config> <log>
  "$MIRRORD_BIN" exec -f "$1" -- sh -c 'echo "SESSION READY"; sleep 240' \
    > "$2" 2>&1 &
  SESSION_PID=$!
  disown "$SESSION_PID" 2>/dev/null || true
  info "session starting in the background (pid $SESSION_PID)"
  info "follow it with: tail -f $2"
}

mirrord_config() { # <branch-id> <extra-branch-json-lines (may be empty)>
  cat <<EOF
{
  "operator": true,
  "target": {
    "path": "deploy/redis-app",
    "namespace": "$NAMESPACE"
  },
  "feature": {
    "env": true,
    "fs": "local",
    "network": { "incoming": "off", "outgoing": true },
    "db_branches": [
      {
        "id": "$1",
        "type": "redis",
        "location": "remote",
        "profile": "$PROFILE_NAME",
        "ttl_secs": 300,
        "creation_timeout_secs": 180,
        "connection": { "url": "REDIS_URL" },
        "copy": { "mode": "empty" }
      }
    ]
  }
}
EOF
}

# ---------------------------------------------------------------------------
# The two branch configs under test. Same TLS pod baseline as
# configs/redis-branch-config.tls.yaml, moved into a named profile.
# ---------------------------------------------------------------------------
GOOD_CONFIG="$WORKDIR/profile-tls.yaml"
cat > "$GOOD_CONFIG" <<EOF
# Case 1: TLS baseline correctly nested under the profile's dbPod.
dbPod: {}
profiles:
  $PROFILE_NAME:
    dbPod:
      image:
        registry: "redis-tls-local"
      imagePullPolicy: "Never"
      dbServerArgs:
        - "--tls-port"
        - "6379"
        - "--port"
        - "0"
        - "--tls-cert-file"
        - "/certs/server.crt"
        - "--tls-key-file"
        - "/certs/server.key"
        - "--tls-auth-clients"
        - "no"
      tls: true
EOF

BAD_CONFIG="$WORKDIR/profile-misplaced.yaml"
cat > "$BAD_CONFIG" <<EOF
# Case 2: the Teladoc misconfiguration - \`tls\` beside the profile's dbPod.
dbPod: {}
profiles:
  $PROFILE_NAME:
    tls: true
    dbPod:
      image:
        registry: "redis-tls-local"
      imagePullPolicy: "Never"
      dbServerArgs:
        - "--tls-port"
        - "6379"
        - "--port"
        - "0"
        - "--tls-cert-file"
        - "/certs/server.crt"
        - "--tls-key-file"
        - "/certs/server.key"
        - "--tls-auth-clients"
        - "no"
EOF

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Redis TLS named-profile e2e - preflight"

command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq not found"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not usable: $MIRRORD_BIN"; exit 1; }
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "workdir: $WORKDIR (mirrord configs + session logs live here)"
[ "$HAVE_GUM" = 1 ] || warn "gum not installed (brew install gum) - plain output"

# Sessions labeled with an isolation marker are reconciled by a locally
# running operator:dev instead of the deployed one - same convention as the
# redis:* tasks.
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
else
  warn "no operator:dev process detected - the DEPLOYED operator will reconcile"
  warn "the branches, and case 2 only passes if it carries the unknown-key fix"
  confirm "Continue against the deployed operator?" || exit 0
fi

cp "$BRANCH_CONFIG" "$SAVED_CONFIG"
info "saved current branch config -> $SAVED_CONFIG"

# ---------------------------------------------------------------------------
# Deploy what's missing: redis test env + the TLS redis image
# ---------------------------------------------------------------------------
header "Deploy (only what's missing)"

if kubectl get deploy redis-main redis-app -n "$NAMESPACE" >/dev/null 2>&1; then
  info "redis test env already deployed (deploy/redis-main + deploy/redis-app)"
else
  info "redis test env missing - deploying via task redis:deploy"
  (cd "$ROOT_DIR" && task redis:deploy) || { fail "task redis:deploy failed"; exit 1; }
fi
kubectl wait --for=condition=ready pod -l app=redis-app -n "$NAMESPACE" --timeout=120s >/dev/null \
  || { fail "redis-app target pod not ready"; exit 1; }
info "target ready (deploy/redis-app)"

if minikube -p "$CLUSTER_NAME" image ls 2>/dev/null | grep -q "redis-tls-local"; then
  info "TLS redis image already loaded (redis-tls-local:7-alpine)"
else
  info "TLS redis image missing - building via task redis:tls:build:redis-image"
  (cd "$ROOT_DIR" && task redis:tls:build:redis-image) \
    || { fail "task redis:tls:build:redis-image failed"; exit 1; }
fi

if [ "${OPERATOR_ISOLATION_MARKER:-}" = "local-dev" ] \
   && ! minikube -p "$CLUSTER_NAME" image ls 2>/dev/null | grep -q "mirrord-branch-init"; then
  warn "mirrord-branch-init:local is not loaded - operator:dev branch pods copy"
  warn "their init binaries from it (see OPERATOR_IMAGE in .mirrord/operator-dev.yaml)"
  if confirm "Build it now? (task redis:tls:build:init-image, SLOW first run)"; then
    (cd "$ROOT_DIR" && task redis:tls:build:init-image) \
      || { fail "init image build failed"; exit 1; }
  else
    fail "cannot run branch pods without the init image"; exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Case 1 - TLS under the profile's dbPod: branch Ready, pod TLS-only
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" != "misplaced" ]; then
header "Case 1/2: profiles.$PROFILE_NAME.dbPod.tls -> Ready + TLS-only"

swap_config "$GOOD_CONFIG" "named profile with TLS under dbPod"

GOOD_MIRRORD="$WORKDIR/mirrord-good.json"
mirrord_config "$TLS_BRANCH_ID" > "$GOOD_MIRRORD"
GOOD_LOG="$WORKDIR/good-session.log"
launch_session "$GOOD_MIRRORD" "$GOOD_LOG"

if BRANCH="$(wait_branch "$TLS_BRANCH_ID" "$SESSION_PID" "$GOOD_LOG")"; then
  info "branch CRD: $BRANCH"
  if wait_branch_phase "$BRANCH" "Ready"; then
    check "profile branch reaches Ready" 0

    POD="$(kubectl get pod -n "$NAMESPACE" -l "db-owner-name=$BRANCH" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [ -z "$POD" ]; then
      check "branch pod running" 1
    else
      info "branch pod: $POD"
      TLS_ANNOT="$(kubectl get pod -n "$NAMESPACE" "$POD" \
        -o jsonpath='{.metadata.annotations.operator\.metalbear\.co/db-branch-tls}' 2>/dev/null)"
      check "pod carries the db-branch-tls annotation (app gets rediss://)" \
        "$([ "$TLS_ANNOT" = "true" ] && echo 0 || echo 1)"

      if kubectl exec -n "$NAMESPACE" "$POD" -- \
           redis-cli --no-auth-warning -a "$BRANCH_PASS" PING 2>/dev/null | grep -q PONG; then
        check "plaintext PING is rejected (TLS-only listener)" 1
      else
        check "plaintext PING is rejected (TLS-only listener)" 0
      fi
      if kubectl exec -n "$NAMESPACE" "$POD" -- \
           redis-cli --no-auth-warning --tls --insecure -a "$BRANCH_PASS" PING 2>/dev/null | grep -q PONG; then
        check "TLS PING answers PONG (seeding sidecar used --target-tls)" 0
      else
        check "TLS PING answers PONG (seeding sidecar used --target-tls)" 1
      fi
    fi
  else
    check "profile branch reaches Ready" 1
    warn "phase: $(branch_field "$BRANCH" '{.status.phase}'), error: $(branch_field "$BRANCH" '{.status.error}')"
    warn "an operator WITHOUT the profile TLS handling leaves this branch stuck -"
    warn "make sure operator:dev runs the current operator checkout"
  fi
else
  FAILURES=$((FAILURES + 1))
fi
kill_session
fi # ONLY_CASE != misplaced

# ---------------------------------------------------------------------------
# Case 2 - `tls` beside the profile's dbPod: fails fast with a did-you-mean
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" != "good" ]; then
header "Case 2/2: misplaced profiles.$PROFILE_NAME.tls -> fast Failed + hint"

swap_config "$BAD_CONFIG" "named profile with tls MISPLACED beside dbPod"

BAD_MIRRORD="$WORKDIR/mirrord-bad.json"
mirrord_config "$BAD_BRANCH_ID" > "$BAD_MIRRORD"
BAD_LOG="$WORKDIR/bad-session.log"
launch_session "$BAD_MIRRORD" "$BAD_LOG"

if BRANCH="$(wait_branch "$BAD_BRANCH_ID" "$SESSION_PID" "$BAD_LOG")"; then
  info "branch CRD: $BRANCH"
  if wait_branch_phase "$BRANCH" "Failed"; then
    check "misplaced-key branch fails fast (no silent hang)" 0
    ERROR="$(branch_field "$BRANCH" '{.status.error}')"
    if printf '%s' "$ERROR" | grep -q "profiles.$PROFILE_NAME.dbPod.tls"; then
      check "error names the intended placement (did-you-mean)" 0
    else
      check "error names the intended placement (did-you-mean)" 1
    fi
    # The CLI has printed its miette error by now; give it a moment to flush.
    sleep 2
    show_error_views "$BRANCH" "$BAD_LOG"
  else
    check "misplaced-key branch fails fast (no silent hang)" 1
    warn "phase: $(branch_field "$BRANCH" '{.status.phase}') - an operator without"
    warn "the unknown-key validation silently drops the key; the branch either goes"
    warn "Ready as PLAINTEXT or hangs until the creation timeout"
  fi
else
  FAILURES=$((FAILURES + 1))
fi
kill_session
fi # ONLY_CASE != good

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
header "Result"
if [ "$FAILURES" = 0 ]; then
  pass "all checks passed"
  exit 0
else
  fail "$FAILURES check(s) failed"
  exit 1
fi
