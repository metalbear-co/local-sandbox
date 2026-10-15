#!/usr/bin/env bash
#
# End-to-end test: a database branch survives its pod being deleted.
#
# Before the fix the controller deleted the branch as soon as its pod was gone
# ("DB pod no longer exists, deleting the branch"), so a Karpenter eviction or a
# node drain threw away the branch's data and every session attached to it. Now
# the branch gets a new pod on the same volumes, sits behind a Service whose IP
# does not change, and sessions keep talking to it. Cases:
#
#   1. RECOVER: a session creates a pg branch and writes a row. The branch pod
#               is deleted. Expected: the branch returns to Ready with a new pod,
#               the row is still there, both claims are unchanged, the Service
#               IP is unchanged, and the session's DATABASE_URL points at it.
#   2. SESSION: the session from case 1 is still running; a query through its
#               own env URL (the Service) succeeds after the replacement.
#
# The script reuses the postgres test env (task postgres:deploy: source DB
# `postgres-test`, target pod `pg-server-env-val`) and cleans up on exit.
#
# Prerequisites:
#   - minikube (bearkube) running with an operator that has pg branching
#     (`task operator:dev` from the INT-816 branch, the script labels its
#     session for it like the postgres:* tasks do)
#   - a mirrord CLI (task mirrord:cli:build), psql on this machine for case 2
#
# Usage:
#   scripts/test-branch-pod-recovery.sh
#
# Env knobs:
#   MIRRORD_BIN     CLI to run (default: the local debug build, then PATH)
#   READY_TIMEOUT   seconds to wait for a session or branch (default 300)
#   KEEP=1          leave the branch in place for poking
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="test-mirrord"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"
TARGET_POD="pg-server-env-val"

LOCAL_MIRRORD="$SCRIPT_DIR/../../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/branch-pod-recovery.XXXXXX)"
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"
BRANCH_ID="pg-recover-$RUN_TAG"
SESSION_PID=""

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

branch_name() {
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg id "$BRANCH_ID" '.items[] | select(.spec.id == $id) | .metadata.name' | head -1
}

branch_field() { # <name> <jsonpath>
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" "$1" -o jsonpath="$2" 2>/dev/null
}

wait_for() { # <description> <seconds> <command...>
  local desc="$1" secs="$2"; shift 2
  local start=$SECONDS
  until "$@"; do
    if [ $((SECONDS - start)) -ge "$secs" ]; then fail "timed out waiting for $desc"; return 1; fi
    sleep 2
  done
}

cleanup() {
  [ -n "$SESSION_PID" ] && kill "$SESSION_PID" >/dev/null 2>&1
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1 - leaving the branch in place (id: $BRANCH_ID)"
    return
  fi
  local name
  name="$(branch_name)"
  [ -n "$name" ] && kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" "$name" --ignore-not-found >/dev/null 2>&1
  info "cleaned up (logs kept in $WORKDIR)"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Preflight"
kubectl get pod -n "$NAMESPACE" "$TARGET_POD" >/dev/null 2>&1 \
  || { fail "target pod $TARGET_POD missing in $NAMESPACE; run: task postgres:deploy"; exit 1; }
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
fi
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null || echo unknown))"

CONFIG="$WORKDIR/mirrord.json"
cat > "$CONFIG" <<CFG
{
  "operator": true,
  "target": { "path": { "pod": "$TARGET_POD" }, "namespace": "$NAMESPACE" },
  "feature": {
    "env": true,
    "fs": "local",
    "network": { "incoming": "off", "outgoing": true },
    "db_branches": [
      {
        "id": "$BRANCH_ID",
        "name": "recover_db",
        "type": "pg",
        "version": "17",
        "ttl_secs": 900,
        "creation_timeout_secs": 180,
        "connection": { "url": "DATABASE_URL" },
        "copy": { "mode": "empty" }
      }
    ]
  }
}
CFG

# ---------------------------------------------------------------------------
# Case 1: RECOVER
# ---------------------------------------------------------------------------
header "Case 1: the branch gets a new pod on its volumes"
info "starting a session that prints its DATABASE_URL and keeps running"
"$MIRRORD_BIN" exec -f "$CONFIG" -- sh -c 'echo SESSION_ENV=$DATABASE_URL; sleep 600' \
  > "$WORKDIR/session.log" 2>&1 &
SESSION_PID=$!

session_url() { grep -m1 '^SESSION_ENV=' "$WORKDIR/session.log" | cut -d= -f2-; }
wait_for "the session to print DATABASE_URL" "$READY_TIMEOUT" sh -c "grep -q '^SESSION_ENV=' '$WORKDIR/session.log'" || exit 1
URL="$(session_url)"
info "session DATABASE_URL: $URL"

NAME="$(branch_name)"
check "branch CR exists for id $BRANCH_ID" "$([ -n "$NAME" ] && echo 0 || echo 1)"
[ -z "$NAME" ] && exit 1
SERVICE="mirrord-branch-$NAME"
SERVICE_IP="$(kubectl get svc -n "$NAMESPACE" "$SERVICE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
check "Service $SERVICE exists with a cluster IP ($SERVICE_IP)" "$([ -n "$SERVICE_IP" ] && echo 0 || echo 1)"
case "$URL" in *"$SERVICE_IP"*) check "the session URL points at the Service IP" 0 ;; *) check "the session URL points at the Service IP (got $URL)" 1 ;; esac

FIRST_POD="$(branch_field "$NAME" '{.status.podName}')"
DATA_UID="$(kubectl get pvc -n "$NAMESPACE" "mirrord-branch-$NAME-data" -o jsonpath='{.metadata.uid}')"
INIT_UID="$(kubectl get pvc -n "$NAMESPACE" "mirrord-branch-$NAME-init" -o jsonpath='{.metadata.uid}')"
info "first pod: $FIRST_POD"

info "writing a row the replacement must still hold"
kubectl exec -n "$NAMESPACE" "$FIRST_POD" -c postgres -- \
  psql -U postgres -d recover_db -c "CREATE TABLE IF NOT EXISTS survivors(id INT); INSERT INTO survivors VALUES (42);" >/dev/null
check "row written on the first pod" $?

info "deleting the branch pod"
kubectl delete pod -n "$NAMESPACE" "$FIRST_POD" --wait=false >/dev/null
is_ready_on_new_pod() {
  local phase pod
  phase="$(branch_field "$NAME" '{.status.phase}')"
  pod="$(branch_field "$NAME" '{.status.podName}')"
  [ "$phase" = Failed ] && { fail "branch failed: $(branch_field "$NAME" '{.status.error}')"; return 0; }
  [ "$phase" = Ready ] && [ -n "$pod" ] && [ "$pod" != "$FIRST_POD" ]
}
wait_for "the branch to be Ready on a new pod" "$READY_TIMEOUT" is_ready_on_new_pod
SECOND_POD="$(branch_field "$NAME" '{.status.podName}')"
check "branch is Ready again on a new pod ($SECOND_POD)" "$([ "$(branch_field "$NAME" '{.status.phase}')" = Ready ] && [ "$SECOND_POD" != "$FIRST_POD" ] && echo 0 || echo 1)"
check "branch CR was not deleted" "$([ -n "$(branch_name)" ] && echo 0 || echo 1)"
check "data claim unchanged" "$([ "$(kubectl get pvc -n "$NAMESPACE" "mirrord-branch-$NAME-data" -o jsonpath='{.metadata.uid}')" = "$DATA_UID" ] && echo 0 || echo 1)"
check "init claim unchanged" "$([ "$(kubectl get pvc -n "$NAMESPACE" "mirrord-branch-$NAME-init" -o jsonpath='{.metadata.uid}')" = "$INIT_UID" ] && echo 0 || echo 1)"
check "Service IP unchanged" "$([ "$(kubectl get svc -n "$NAMESPACE" "$SERVICE" -o jsonpath='{.spec.clusterIP}')" = "$SERVICE_IP" ] && echo 0 || echo 1)"
ROW="$(kubectl exec -n "$NAMESPACE" "$SECOND_POD" -c postgres -- psql -U postgres -d recover_db -tAc "SELECT id FROM survivors" 2>/dev/null | tr -d '[:space:]')"
check "the row survived on the new pod (got '$ROW')" "$([ "$ROW" = 42 ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Case 2: SESSION
# ---------------------------------------------------------------------------
header "Case 2: the running session still reaches the branch"
if command -v psql >/dev/null 2>&1; then
  QUERY_OUT="$("$MIRRORD_BIN" exec -f "$CONFIG" -- psql "$URL" -tAc "SELECT id FROM survivors" 2>>"$WORKDIR/query.log" | tr -d '[:space:]')"
  check "a query through the session's URL reads the row (got '$QUERY_OUT')" "$([ "$QUERY_OUT" = 42 ] && echo 0 || echo 1)"
else
  warn "psql not installed locally, skipping the in-session query"
fi

# ---------------------------------------------------------------------------
header "Summary"
printf '%-46s %s\n' "branch id" "$BRANCH_ID"
printf '%-46s %s\n' "first pod / second pod" "$FIRST_POD / $SECOND_POD"
printf '%-46s %s\n' "service ip" "$SERVICE_IP"
printf '%-46s %s\n' "failures" "$FAILURES"
[ "$FAILURES" = 0 ]
