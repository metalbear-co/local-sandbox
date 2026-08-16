#!/usr/bin/env bash
# Interactive walkthrough of every PostgreSQL roles/credentials case.
#
# Runs each scenario, shows what to look at, pauses so you can inspect (or run
# your own kubectl commands in another terminal), and advances on Enter.
# Everything is also appended to the log file.
#
# Uses charmbracelet/gum for the UI when installed (brew install gum) and falls
# back to plain ANSI otherwise.
#
# Usage:
#   scripts/pg-roles-walkthrough.sh            # all cases
#   scripts/pg-roles-walkthrough.sh 3          # start at case 3
#
# Prerequisites: `task postgres:roles:deploy` once. Full-mode cases need an
# operator with the roles feature: either `task op:custom` (deployed build) or
# `task operator:dev` with a dev OPERATOR_IMAGE.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-test-mirrord}"
MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"
LOG="${LOG:-$ROOT_DIR/pg-roles-walkthrough.log}"
APP_BIN=/tmp/postgres-app
APP_LOG=/tmp/pg-roles-app.log
START_CASE="${1:-1}"
TOTAL_CASES=6

exec > >(tee -a "$LOG") 2>&1

HAS_GUM=0
command -v gum >/dev/null 2>&1 && HAS_GUM=1

# ── UI helpers (gum when available, ANSI fallback) ────────────────────────────

C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'

banner() { # case-number title
  if [ "$HAS_GUM" = 1 ]; then
    gum style --border double --padding "0 2" --margin "1 0" --border-foreground 212 \
      "CASE $1/$TOTAL_CASES" "$2"
  else
    printf '\n%s╔══ CASE %s/%s ═══════════════════════════════════════════════╗%s\n' "$C_BOLD" "$1" "$TOTAL_CASES" "$C_OFF"
    printf '%s║%s  %s\n' "$C_BOLD" "$C_OFF" "$2"
    printf '%s╚═══════════════════════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_OFF"
  fi
}

section() {
  if [ "$HAS_GUM" = 1 ]; then
    gum style --foreground 212 --bold "▸ $*"
  else
    printf '\n%s▸ %s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_OFF"
  fi
}

expect() { printf '%s  ⚑ expect: %s%s\n' "$C_YELLOW" "$*" "$C_OFF"; }
ok()     { printf '%s  ✓ %s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
fail()   { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_OFF"; }
note()   { printf '%s  · %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
how()    { printf '%s  ⌕ inspect yourself: %s%s\n' "$C_DIM$C_CYAN" "$*" "$C_OFF"; }

run() { printf '%s  $ %s%s\n' "$C_DIM" "$*" "$C_OFF"; eval "$@"; }

pause() {
  local msg="${1:-inspect away, then continue}"
  if [ "$HAS_GUM" = 1 ]; then
    gum confirm --affirmative "Continue" --negative "Quit" "$msg" </dev/tty || exit 0
  else
    printf '%s── %s (Enter to continue, Ctrl-C to quit) ──%s' "$C_YELLOW" "$msg" "$C_OFF"
    read -r </dev/tty
  fi
}

spin() { # message -- command...
  local msg="$1"; shift
  if [ "$HAS_GUM" = 1 ]; then
    gum spin --spinner dot --title "$msg" -- "$@"
  else
    note "$msg"
    "$@"
  fi
}

# ── Cluster helpers ───────────────────────────────────────────────────────────

# The pod belonging to the newest unified BranchDatabase CR - not just the newest pod,
# which can be a recreation of an older CR's pod and mislead the inspection.
branch_pod() {
  local cr
  cr=$(kubectl get branchdatabases -n "$NAMESPACE" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
  if [ -n "$cr" ]; then
    kubectl get pod -n "$NAMESPACE" -l "db-owner-name=$cr" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null
  else
    kubectl get pod -n "$NAMESPACE" -l db-owner-name \
      --field-selector=status.phase=Running \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null
  fi
}

set_mode() {
  section "Switching roles mode to \"$1\""
  ( cd "$ROOT_DIR" && task "postgres:roles:$1" ) | sed 's/^/  /'
}

clean_branches() {
  section "Clearing existing branches (both CRD kinds)"
  ( cd "$ROOT_DIR" && task postgres:roles:clean ) 2>/dev/null | grep -v "^task:" | sed 's/^/  /'
}

run_app() {
  local key_flag=""
  [ -n "${1:-}" ] && key_flag="--key $1"
  : > "$APP_LOG"
  if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
    export OPERATOR_ISOLATION_MARKER=local-dev
    note "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
  fi
  section "Running the app under mirrord ${key_flag:+(key: ${1})}"
  note "full app log: $APP_LOG"
  # env -u: a DATABASE_URL exported in the developer's shell would leak into the app,
  # which prefers it over the DB_* vars - the app would silently talk to the SOURCE
  # database with source credentials instead of the branch.
  # shellcheck disable=SC2086
  env -u DATABASE_URL "$MIRRORD_BIN" exec -f "$ROOT_DIR/k8s/overlays/postgres/mirrord-roles.json" $key_flag -- "$APP_BIN" >"$APP_LOG" 2>&1 &
  local pid=$!
  spin "waiting for the branch and the app's identity line..." bash -c '
    for _ in $(seq 1 80); do
      grep -q "Session identity\|Error" "'"$APP_LOG"'" 2>/dev/null && exit 0
      sleep 3
    done'
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  if grep -q "Session identity" "$APP_LOG"; then
    ok "$(grep "Session identity" "$APP_LOG" | head -1 | sed 's/.*Session/Session/')"
    note "$(grep "Total users" "$APP_LOG" | head -1 || true)"
  else
    fail "app did not report an identity; last error:"
    grep -E "Error|error" "$APP_LOG" | head -4 | sed 's/^/    /'
  fi
}

inspect_branch() {
  local pod
  pod=$(branch_pod)
  if [ -z "$pod" ]; then
    fail "No running branch pod - nothing to inspect."
    return 1
  fi
  section "Inspecting branch pod: $pod"
  how "export POD=$pod NS=$NAMESPACE   # then paste any command below"

  section "Branch CRs"
  how "kubectl get branchdatabases -n $NAMESPACE"
  kubectl get branchdatabases -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /'

  section "Pod annotations (db-branch-source-credentials only in full mode)"
  how "kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.metadata.annotations}'"
  kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep -i "db-branch" | sed 's/^/  /' || note "no db-branch annotations"

  section "Init container log (roles + login lines)"
  how "kubectl logs -n $NAMESPACE $pod -c pg-branch-init"
  kubectl logs -n "$NAMESPACE" "$pod" -c pg-branch-init 2>/dev/null | grep -E "roles|login|Wrote|Skipping|Not installing" | sed 's/^/  /' || note "no matching log lines"

  section "Bootstrap SQL the init container wrote"
  how "kubectl exec -n $NAMESPACE $pod -c postgres -- ls /docker-entrypoint-initdb.d/"
  how "kubectl exec -n $NAMESPACE $pod -c postgres -- cat /docker-entrypoint-initdb.d/00-roles.sql"
  kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- ls /docker-entrypoint-initdb.d/ 2>/dev/null | sed 's/^/  /'
  note "00-roles.sql (first lines):"
  kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- sh -c 'head -4 /docker-entrypoint-initdb.d/00-roles.sql 2>/dev/null' | cut -c1-110 | sed 's/^/    /' || true
  if kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- test -f /docker-entrypoint-initdb.d/90-branch-login.sql 2>/dev/null; then
    how "kubectl exec -n $NAMESPACE $pod -c postgres -- cat /docker-entrypoint-initdb.d/90-branch-login.sql"
    local leaks
    leaks=$(kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- sh -c 'grep -c app_pass /docker-entrypoint-initdb.d/90-branch-login.sql || true' 2>/dev/null)
    ok "90-branch-login.sql present, SCRAM-SHA-256 verifier, plaintext occurrences: ${leaks:-0}"
  else
    note "no 90-branch-login.sql (old init binary, or the source user was skipped)"
  fi

  section "Role attributes and membership on the branch"
  how "kubectl exec -n $NAMESPACE $pod -c postgres -- psql -U postgres -d source_db -c '\\du'"
  kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- psql -U postgres -d source_db -Atc \
    "SELECT rolname || ': login=' || rolcanlogin || ' super=' || rolsuper FROM pg_roles WHERE rolname IN ('app_user','readonly_grp','writer_user') ORDER BY rolname" 2>/dev/null | sed 's/^/  /' || true
  kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- psql -U postgres -d source_db -Atc \
    "SELECT 'membership: ' || g.rolname || ' -> ' || m.rolname FROM pg_auth_members am JOIN pg_roles g ON g.oid=am.roleid JOIN pg_roles m ON m.oid=am.member WHERE g.rolname='readonly_grp'" 2>/dev/null | sed 's/^/  /' || true
}

# Authenticates over the pod network from postgres-test: the postgres image trusts
# loopback (pg_hba `127.0.0.1/32 trust`), so an in-pod psql would skip password auth
# entirely. Only a remote connection exercises the SCRAM rule - like the real app does.
login_as() { # user password label expect_success(1|0)
  local pod ip out
  pod=$(branch_pod) || return 1
  ip=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.podIP}' 2>/dev/null)
  [ -n "$ip" ] || { fail "could not resolve the branch pod IP"; return 1; }
  section "Login attempt (real SCRAM auth, from postgres-test -> $ip): $3"
  how "kubectl exec -n $NAMESPACE postgres-test -- env PGPASSWORD=$2 psql -h $ip -U $1 -d source_db"
  if out=$(kubectl exec -n "$NAMESPACE" postgres-test -- env PGPASSWORD="$2" psql -h "$ip" -U "$1" -d source_db -Atc \
      "SELECT 'as ' || current_user || ', superuser=' || rolsuper FROM pg_roles WHERE rolname = current_user" 2>&1); then
    [ "$4" = 1 ] && ok "$out" || fail "unexpectedly succeeded: $out"
  else
    [ "$4" = 0 ] && ok "rejected, as expected" || { fail "login failed:"; echo "$out" | head -2 | sed 's/^/    /'; }
  fi
}

probe_permissions() {
  local pod
  pod=$(branch_pod) || return 1
  note "identity here comes via loopback (trusted by the postgres image); permission checks are identical either way - case 2/5 prove real password auth over the network"
  section "as app_user: SELECT roles_report (granted via readonly_grp)"
  how "kubectl exec -n $NAMESPACE $pod -c postgres -- env PGPASSWORD=app_pass psql -h 127.0.0.1 -U app_user -d source_db -c 'SELECT * FROM roles_report;'"
  kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- env PGPASSWORD=app_pass psql -h 127.0.0.1 -U app_user -d source_db -c "SELECT * FROM roles_report LIMIT 3;" 2>&1 | sed 's/^/  /' || true
  section "as app_user: INSERT roles_report (full mode: denied - group grant is SELECT-only)"
  how "kubectl exec -n $NAMESPACE $pod -c postgres -- env PGPASSWORD=app_pass psql -h 127.0.0.1 -U app_user -d source_db -c \"INSERT INTO roles_report (body) VALUES ('probe');\""
  kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- env PGPASSWORD=app_pass psql -h 127.0.0.1 -U app_user -d source_db -c "INSERT INTO roles_report (body) VALUES ('probe');" 2>&1 | sed 's/^/  /' || true
  section "as superuser via SET ROLE writer_user: INSERT (owner rights survive)"
  how "kubectl exec -n $NAMESPACE $pod -c postgres -- psql -U postgres -d source_db -c 'SET ROLE writer_user; ...'"
  kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- psql -U postgres -d source_db -c "SET ROLE writer_user; INSERT INTO roles_report (body) VALUES ('from writer'); SELECT count(*) FROM roles_report;" 2>&1 | sed 's/^/  /' || true
}

# ── Post-run summary table ────────────────────────────────────────────────────

q_source() { # scalar SQL against the source DB, "-" when it fails
  kubectl exec -n "$NAMESPACE" postgres-test -- psql -U postgres -d source_db -Atc "$1" 2>/dev/null || echo "-"
}

q_branch() { # scalar SQL against the branch DB, "-" when it fails
  local pod
  pod=$(branch_pod)
  [ -n "$pod" ] || { echo "-"; return; }
  kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- psql -U postgres -d source_db -Atc "$1" 2>/dev/null || echo "-"
}

# Renders what just happened as one table: session facts on top, then a
# source-vs-branch comparison so the isolation and the mode's effect are visible
# side by side.
case_summary() {
  local pod ip mode identity conn_host conn_label annotation roles_style login_file
  pod=$(branch_pod)
  ip=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.podIP}' 2>/dev/null)
  mode=$(grep -o '"[a-z]*"' "$ROOT_DIR/configs/pg-branch-config.yaml" | tr -d '"')
  identity=$(grep "Session identity" "$APP_LOG" | tail -1 | sed 's/.*Session identity: //')
  conn_host=$(grep "Connecting to database" "$APP_LOG" | tail -1 | sed -E 's|.*@([^:/]+):.*|\1|')
  if [ "$conn_host" = "$ip" ]; then
    conn_label="branch pod ($ip)"
  elif [ -n "$conn_host" ]; then
    conn_label="!! $conn_host (NOT the branch)"
  else
    conn_label="-"
  fi
  if kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.metadata.annotations}' 2>/dev/null | grep -q db-branch-source-credentials; then
    annotation="source-credentials"
  else
    annotation="none"
  fi
  case "$(kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- head -1 /docker-entrypoint-initdb.d/00-roles.sql 2>/dev/null)" in
    *Shell*)  roles_style="NOLOGIN shells" ;;
    *Source*) roles_style="real attributes + memberships" ;;
    *)        roles_style="-" ;;
  esac
  if kubectl exec -n "$NAMESPACE" "$pod" -c postgres -- test -f /docker-entrypoint-initdb.d/90-branch-login.sql 2>/dev/null; then
    login_file="yes (SCRAM hash)"
  else
    login_file="no"
  fi

  local role_q="SELECT CASE WHEN rolcanlogin THEN 'login' ELSE 'nologin' END || ', super=' || rolsuper FROM pg_roles WHERE rolname='app_user'"
  local table
  table=$(
    printf '%-22s │ %s\n' "roles mode"        "$mode"
    printf '%-22s │ %s\n' "app connected to"  "$conn_label"
    printf '%-22s │ %s\n' "app identity"      "${identity:--}"
    printf '%-22s │ %s\n' "branch pod"        "${pod:--}"
    printf '%-22s │ %s\n' "pod annotation"    "$annotation"
    printf '%-22s │ %s\n' "roles recreated as" "$roles_style"
    printf '%-22s │ %s\n' "source-user login"  "$login_file"
    printf '%s\n' "───────────────────────┼──────────────────────────────────────"
    printf '%-22s │ %-18s │ %s\n' ""                    "SOURCE"                          "BRANCH"
    printf '%-22s │ %-18s │ %s\n' "app_user role"       "$(q_source "$role_q")"           "$(q_branch "$role_q")"
    printf '%-22s │ %-18s │ %s\n' "app_users rows"      "$(q_source 'SELECT count(*) FROM app_users')" "$(q_branch 'SELECT count(*) FROM app_users')"
    printf '%-22s │ %-18s │ %s\n' "roles_report rows"   "$(q_source 'SELECT count(*) FROM roles_report')" "$(q_branch 'SELECT count(*) FROM roles_report')"
  )
  echo ""
  if [ "$HAS_GUM" = 1 ]; then
    gum style --border rounded --padding "0 1" --border-foreground 51 "WHAT JUST HAPPENED" "$table"
  else
    bold "┌─ WHAT JUST HAPPENED ─────────────────────────────────────────┐"
    printf '%s\n' "$table" | sed 's/^/  /'
  fi
}

# ── Cases ─────────────────────────────────────────────────────────────────────

case_1() {
  banner 1 "empty mode (default): env overrides -> branch superuser"
  expect "Session identity: user=postgres superuser=true"
  set_mode empty
  clean_branches
  run_app
  inspect_branch
  case_summary
  pause
}

case_2() {
  banner 2 "empty mode: the source user's real password also works"
  expect "app_user/app_pass logs in (superuser on the scratch copy); wrong password rejected"
  login_as app_user app_pass "app_user with its real source password" 1
  login_as app_user wrong_password "app_user with a wrong password" 0
  pause
}

case_3() {
  banner 3 "full mode: app connects as its real role, permissions enforced"
  expect "Session identity: user=app_user superuser=false + source-credentials annotation"
  set_mode full
  clean_branches
  run_app
  inspect_branch
  case_summary
  pause
}

case_4() {
  banner 4 "full mode: grants, denials, and SET ROLE"
  expect "SELECT via group works, INSERT denied, SET ROLE writer_user can write"
  probe_permissions
  pause
}

case_5() {
  banner 5 "undeclared roles cannot authenticate"
  expect "writer_user login fails (other roles' passwords are never copied); use SET ROLE"
  login_as writer_user anything "writer_user (no declared password)" 0
  pause
}

case_6() {
  banner 6 "branch sharing: same key -> same branch across runs"
  expect "two runs with KEY=walkthrough report the same branch pod UID"
  clean_branches
  run_app walkthrough
  local uid1 uid2
  uid1=$(kubectl get pod -n "$NAMESPACE" "$(branch_pod)" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  note "first run  -> branch pod uid: $uid1"
  run_app walkthrough
  uid2=$(kubectl get pod -n "$NAMESPACE" "$(branch_pod)" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  note "second run -> branch pod uid: $uid2"
  if [ -n "$uid1" ] && [ "$uid1" = "$uid2" ]; then
    ok "same pod uid: the branch was reused"
  else
    fail "different pod uids: the branch was NOT reused (check the operator/TTL)"
  fi
  run "kubectl get branchdatabases -n $NAMESPACE" | sed 's/^/  /'
  case_summary
  pause
}

# ── Main ──────────────────────────────────────────────────────────────────────

if [ "$HAS_GUM" = 1 ]; then
  gum style --border rounded --padding "0 2" --border-foreground 212 --bold \
    "PostgreSQL roles & credentials walkthrough" "log: $LOG"
else
  printf '%s%s\nPostgreSQL roles & credentials walkthrough%s\n' "$C_BOLD" "$C_CYAN" "$C_OFF"
  note "log: $LOG   (tip: 'brew install gum' for a nicer UI)"
fi
note "namespace: $NAMESPACE | mirrord: $MIRRORD_BIN | $(date '+%H:%M:%S')"

section "Preflight"
if [ -n "${DATABASE_URL:-}" ]; then
  note "your shell exports DATABASE_URL - unsetting it for the app runs so it cannot shadow the branch connection"
fi
kubectl get pod -n "$NAMESPACE" postgres-test pg-server-roles >/dev/null 2>&1 \
  || { fail "source/target pods missing - run 'task postgres:roles:deploy' first"; exit 1; }
ok "source DB and target pod are running"
spin "clearing leftover branches from earlier runs..." bash -c "cd '$ROOT_DIR' && task postgres:roles:clean >/dev/null 2>&1"
ok "state is clean - no stale branches or cached failures carry into the cases"
spin "seeding roles and grants (idempotent)..." bash -c "cd '$ROOT_DIR' && task postgres:roles:seed >/dev/null"
ok "seed applied (roles, grants incl. read access for the dump user)"
spin "building the app..." bash -c "cd '$ROOT_DIR/apps/postgres-app' && go build -o '$APP_BIN' main.go"
ok "app built"
if pgrep -qf 'target/debug/operator-service'; then
  ok "operator:dev running locally"
elif kubectl get deploy mirrord-operator -n mirrord >/dev/null 2>&1; then
  note "using the deployed operator (roles modes switch via its configmap; needs your op:custom build for full mode)"
else
  fail "no operator found (deploy one or run operator:dev)"
fi
pause "starting with case $START_CASE"

for n in 1 2 3 4 5 6; do
  [ "$n" -lt "$START_CASE" ] && continue
  "case_$n"
done

echo ""
ok "Walkthrough complete. Full log: $LOG"
note "cleanup: task postgres:roles:clean   (branches also expire on their TTL)"
