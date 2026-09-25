#!/usr/bin/env bash
#
# End-to-end test: a session that joins an existing database branch says so.
#
# Before the fix, the CLI looked existing branches up by label and target
# namespace annotation, while the create collided on the deterministic resource
# name. When the two disagreed the user saw "0 ready, 0 pending" followed by a
# silent reuse on the create conflict, so it was unclear whether the session ran
# against the existing branch at all. Now the lookup uses the same name the
# create uses, and every session ends its branch setup with one line per branch
# saying where it came from. Two cases:
#
#   1. SEQUENTIAL: session A creates branch X and keeps running. Session B starts
#                  with the same id. Expected: A reports "1 to create" and
#                  "created by this session"; B reports "1 ready to reuse" and
#                  "reused"; both name the same branch; exactly one branch CR
#                  with id X exists.
#   2. CONCURRENT: sessions A and B start at the same moment with a fresh id Y.
#                  Expected: exactly one branch CR with id Y, both sessions name
#                  it, and whichever session did not mint it says so explicitly -
#                  either it saw the branch "still initializing" and waited, or
#                  it hit the create conflict and reports "created by another
#                  session meanwhile". No session may claim "created by this
#                  session" unless it actually minted the branch (one creator).
#
# The script reuses the postgres test env (task postgres:deploy: source DB
# `postgres-test` and target pod `pg-server-env-val`) and cleans up on exit.
#
# Prerequisites:
#   - minikube (bearkube) running with an operator that has pg branching
#     (`task operator:dev`, the script labels its sessions for it like the
#     postgres:* tasks do)
#   - a mirrord CLI built from the matching mirrord checkout (task mirrord:cli:build)
#
# Usage:
#   scripts/test-db-branch-reuse.sh              # both cases
#   scripts/test-db-branch-reuse.sh sequential   # one case
#   scripts/test-db-branch-reuse.sh concurrent
#
# Env knobs:
#   MIRRORD_BIN     CLI to run (default: the local debug build, then PATH)
#   READY_TIMEOUT   seconds to wait for a session or branch (default 300)
#   KEEP=1          leave the branches in place for poking
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="test-mirrord"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"
TARGET_POD="pg-server-env-val"

ONLY_CASE="${1:-all}"
case "$ONLY_CASE" in all|sequential|concurrent) ;; *)
  printf 'usage: %s [sequential|concurrent]\n' "$0"; exit 2 ;;
esac

LOCAL_MIRRORD="$SCRIPT_DIR/../../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/db-branch-reuse.XXXXXX)"
# Per-run tag: branch CR names derive from the id, so a stale branch from an
# earlier run must not be able to satisfy this run's checks.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"
SEQ_ID="pg-reuse-seq-$RUN_TAG"
CONC_ID="pg-reuse-conc-$RUN_TAG"
SESSION_PIDS=""

# ---------------------------------------------------------------------------
# Output helpers - gum when installed, plain ANSI otherwise
# ---------------------------------------------------------------------------
HAVE_GUM=0
command -v gum >/dev/null 2>&1 && HAVE_GUM=1
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

FAILURES=0
check() { # <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; FAILURES=$((FAILURES + 1)); fi
}

branch_names_by_id() { # <branch-id> -> one name per line
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg id "$1" '.items[] | select(.spec.id == $id) | .metadata.name'
}

kill_sessions() {
  local pid
  for pid in $SESSION_PIDS; do kill "$pid" >/dev/null 2>&1; done
  SESSION_PIDS=""
}

cleanup() {
  kill_sessions
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1 - leaving the branches in place (ids: $SEQ_ID $CONC_ID)"
    return
  fi
  local id name
  for id in "$SEQ_ID" "$CONC_ID"; do
    for name in $(branch_names_by_id "$id"); do
      kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" "$name" --ignore-not-found >/dev/null 2>&1
    done
  done
  info "cleaned up branches and sessions (logs kept in $WORKDIR)"
}
trap cleanup EXIT

write_config() { # <branch-id> <path>
  cat > "$2" <<EOF
{
  "operator": true,
  "target": { "path": { "pod": "$TARGET_POD" }, "namespace": "$NAMESPACE" },
  "feature": {
    "env": true,
    "fs": "local",
    "network": { "incoming": "off", "outgoing": true },
    "db_branches": [
      {
        "id": "$1",
        "name": "my_database_name_etc",
        "type": "pg",
        "version": "17",
        "ttl_secs": 600,
        "creation_timeout_secs": 120,
        "connection": { "url": "DATABASE_URL" },
        "copy": { "mode": "empty" }
      }
    ]
  }
}
EOF
}

# Plain-line progress so the log can be grepped; the local process announces
# itself, then idles so the branch stays owned by a live session.
launch_session() { # <mirrord-config> <log> -> pid
  MIRRORD_PROGRESS_MODE=simple "$MIRRORD_BIN" exec -f "$1" -- sh -c \
    'echo "SESSION READY DATABASE_URL=$DATABASE_URL"; sleep 240' \
    > "$2" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  SESSION_PIDS="$SESSION_PIDS $pid"
  printf '%s' "$pid"
}

wait_session_ready() { # <log> <pid> -> 0 when the local process printed its env
  local waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    grep -q "SESSION READY" "$1" 2>/dev/null && return 0
    if ! kill -0 "$2" 2>/dev/null; then
      fail "session exited before it was ready - log tail:" >&2
      tail -20 "$1" >&2
      return 1
    fi
    sleep 2; waited=$((waited + 2))
  done
  fail "session never became ready within ${READY_TIMEOUT}s - see $1" >&2
  return 1
}

branch_line() { # <log> -> the "using branch database" line
  grep -o 'using branch database [^ ]* for id [^:]*: .*' "$1" | head -1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "DB branch reuse visibility"
[ "$HAVE_GUM" = 1 ] || warn "gum not installed (brew install gum) - plain output"
info "mirrord: $MIRRORD_BIN"
info "workdir: $WORKDIR (session logs)"

if ! kubectl get pod "$TARGET_POD" -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "target pod $TARGET_POD not found in $NAMESPACE - run: task postgres:deploy"; exit 1
fi
if ! kubectl get crd "$BRANCH_CRD" >/dev/null 2>&1; then
  fail "CRD $BRANCH_CRD missing - run: task operator:crds"; exit 1
fi
if [ -n "${OPERATOR_ISOLATION_MARKER:-}" ]; then
  info "using OPERATOR_ISOLATION_MARKER=$OPERATOR_ISOLATION_MARKER from the environment"
elif pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
else
  warn "no operator:dev running - the deployed operator handles the branches"
fi

# ---------------------------------------------------------------------------
# Case 1: sequential reuse
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" = all ] || [ "$ONLY_CASE" = sequential ]; then
  header "Case 1: second session joins a Ready branch (id $SEQ_ID)"
  write_config "$SEQ_ID" "$WORKDIR/seq.json"

  PID_A="$(launch_session "$WORKDIR/seq.json" "$WORKDIR/seq-a.log")"
  info "session A starting (pid $PID_A) - follow with: tail -f $WORKDIR/seq-a.log"
  if wait_session_ready "$WORKDIR/seq-a.log" "$PID_A"; then
    check "session A reports nothing to reuse and one branch to create" \
      "$(grep -q '0 ready to reuse, 0 still initializing, 1 to create' "$WORKDIR/seq-a.log"; echo $?)"
    check "session A reports the branch as created by this session" \
      "$(grep -q 'created by this session' "$WORKDIR/seq-a.log"; echo $?)"

    PID_B="$(launch_session "$WORKDIR/seq.json" "$WORKDIR/seq-b.log")"
    info "session B starting (pid $PID_B) - follow with: tail -f $WORKDIR/seq-b.log"
    if wait_session_ready "$WORKDIR/seq-b.log" "$PID_B"; then
      check "session B reports one branch ready to reuse and none to create" \
        "$(grep -q '1 ready to reuse, 0 still initializing, 0 to create' "$WORKDIR/seq-b.log"; echo $?)"
      check "session B reports the branch as reused" \
        "$(grep -q "using branch database .* for id $SEQ_ID: reused$" "$WORKDIR/seq-b.log"; echo $?)"
      NAME_A="$(branch_line "$WORKDIR/seq-a.log" | awk '{print $4}')"
      NAME_B="$(branch_line "$WORKDIR/seq-b.log" | awk '{print $4}')"
      info "A: $(branch_line "$WORKDIR/seq-a.log")"
      info "B: $(branch_line "$WORKDIR/seq-b.log")"
      check "both sessions name the same branch ($NAME_A)" \
        "$([ -n "$NAME_A" ] && [ "$NAME_A" = "$NAME_B" ]; echo $?)"
      COUNT="$(branch_names_by_id "$SEQ_ID" | grep -c .)"
      check "exactly one branch CR carries id $SEQ_ID (found $COUNT)" "$([ "$COUNT" = 1 ]; echo $?)"
    else
      check "session B became ready" 1
    fi
  else
    check "session A became ready" 1
  fi
  kill_sessions
fi

# ---------------------------------------------------------------------------
# Case 2: concurrent start
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" = all ] || [ "$ONLY_CASE" = concurrent ]; then
  header "Case 2: two sessions start at once with a fresh id ($CONC_ID)"
  write_config "$CONC_ID" "$WORKDIR/conc.json"

  PID_A="$(launch_session "$WORKDIR/conc.json" "$WORKDIR/conc-a.log")"
  PID_B="$(launch_session "$WORKDIR/conc.json" "$WORKDIR/conc-b.log")"
  info "sessions A ($PID_A) and B ($PID_B) starting - logs: $WORKDIR/conc-{a,b}.log"

  READY_A=1; READY_B=1
  wait_session_ready "$WORKDIR/conc-a.log" "$PID_A" && READY_A=0
  wait_session_ready "$WORKDIR/conc-b.log" "$PID_B" && READY_B=0
  check "session A became ready" "$READY_A"
  check "session B became ready" "$READY_B"

  if [ "$READY_A" = 0 ] && [ "$READY_B" = 0 ]; then
    info "A: $(branch_line "$WORKDIR/conc-a.log")"
    info "B: $(branch_line "$WORKDIR/conc-b.log")"
    NAME_A="$(branch_line "$WORKDIR/conc-a.log" | awk '{print $4}')"
    NAME_B="$(branch_line "$WORKDIR/conc-b.log" | awk '{print $4}')"
    check "both sessions name the same branch ($NAME_A)" \
      "$([ -n "$NAME_A" ] && [ "$NAME_A" = "$NAME_B" ]; echo $?)"
    COUNT="$(branch_names_by_id "$CONC_ID" | grep -c .)"
    check "exactly one branch CR carries id $CONC_ID (found $COUNT)" "$([ "$COUNT" = 1 ]; echo $?)"

    CREATORS=0; EXPLAINED=0
    for log in "$WORKDIR/conc-a.log" "$WORKDIR/conc-b.log"; do
      if grep -q 'created by this session' "$log"; then
        CREATORS=$((CREATORS + 1))
      elif grep -q 'created by another session meanwhile' "$log" \
        || grep -q 'reused once it finished initializing' "$log" \
        || grep -q "for id $CONC_ID: reused$" "$log"; then
        EXPLAINED=$((EXPLAINED + 1))
      fi
    done
    check "exactly one session minted the branch (creators: $CREATORS)" "$([ "$CREATORS" = 1 ]; echo $?)"
    check "the other session explains that it joined an existing branch" "$([ "$EXPLAINED" = 1 ]; echo $?)"
  fi
  kill_sessions
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"
if [ "$FAILURES" = 0 ]; then
  pass "all checks passed"
else
  fail "$FAILURES check(s) failed - session logs are in $WORKDIR"
  exit 1
fi
