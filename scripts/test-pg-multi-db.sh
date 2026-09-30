#!/usr/bin/env bash
#
# End-to-end test for PostgreSQL branches that copy several databases from one
# source server into ONE branch pod (`additional_databases` on a `pg` entry of
# feature.db_branches, INT-790).
#
# The script deploys its own source server (databases app_main, analytics and
# audit) and a target deployment whose env points DATABASE_URL, ANALYTICS_URL
# and AUDIT_URL at it, then runs local sessions that print what the operator
# rewrote those variables to. Cases:
#
#   1. two-dbs      app_main (`all`) + analytics (`all`, own connection)
#                     -> exactly one branch CR and one branch pod; DATABASE_URL
#                        and ANALYTICS_URL point at the same branch host:port with
#                        their own database names; both URLs connect from inside
#                        the cluster and see every source row
#   2. copy-modes   app_main (`all`) + analytics (`schema`) + audit (`all`, no
#                   connection)
#                     -> analytics has its tables but no rows, audit exists on the
#                        branch pod with its rows, AUDIT_URL is left pointing at the
#                        source (no connection means no redirect)
#   3. duplicate    analytics listed twice
#                     -> the CLI refuses the config before creating anything and
#                        names the duplicate
#   4. old-operator only when the operator does NOT advertise
#                   PgBranchAdditionalDatabases (a released operator)
#                     -> the CLI refuses with "not supported in mirrord operator"
#                        instead of creating a branch that silently lacks the
#                        additional databases
#   Cases 1-3 run when the operator advertises the feature, case 4 when it does
#   not, so the same script is the compat check: run it once under
#   `task operator:dev` and once under `task operator:use VERSION=<released>`.
#
# Prerequisites:
#   - minikube (bearkube) running
#   - CRDs from the feature branch (`task operator:crds OPERATOR_DIR=<operator
#     worktree> CHARTS_DIR=<operator worktree>/public/charts/mirrord-operator`);
#     the preflight fails fast when the CRD has no `additionalDatabases`
#   - `task operator:dev` from the feature branch with OPERATOR_IMAGE pointing at
#     an init image built from it (`mirrord-branch-init:local`, see
#     `task redis:tls:build:init-image`): the released image's pg-branch-init
#     rejects `--additional-databases`
#   - a mirrord CLI built from the feature branch (`task mirrord:cli:build`)
#   - jq
#
# Usage:
#   scripts/test-pg-multi-db.sh                # every case that applies
#   scripts/test-pg-multi-db.sh two-dbs        # one case
#   scripts/test-pg-multi-db.sh copy-modes
#   scripts/test-pg-multi-db.sh duplicate
#   scripts/test-pg-multi-db.sh old-operator
#
# Env knobs:
#   MIRRORD_BIN            CLI to run (default: the local debug build, then PATH)
#   NAMESPACE              namespace the script owns (default pg-multi-db)
#   READY_TIMEOUT          seconds to wait for a session's env or a pod (default 300)
#   REJECT_TIMEOUT         seconds to wait for the CLI to refuse a config (default 60)
#   OPERATOR_DEV_CONFIG    operator:dev mirrord config the init image check reads
#                          (default .mirrord/operator-dev.yaml of this checkout)
#   CLUSTER_NAME           minikube profile holding the init image (default bearkube)
#   SKIP_INIT_IMAGE_CHECK  1 skips the init image preflight
#   KEEP=1                 leave the namespace and branches in place for poking
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="${NAMESPACE:-pg-multi-db}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
REJECT_TIMEOUT="${REJECT_TIMEOUT:-60}"
OPERATOR_DEV_CONFIG="${OPERATOR_DEV_CONFIG:-$SANDBOX_DIR/.mirrord/operator-dev.yaml}"
CLUSTER_NAME="${CLUSTER_NAME:-bearkube}"
SKIP_INIT_IMAGE_CHECK="${SKIP_INIT_IMAGE_CHECK:-0}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"
FEATURE="PgBranchAdditionalDatabases"
SOURCE_POD="pg-multi-db-source"
TARGET="pg-multi-db-app"

ONLY_CASE="${1:-all}"
case "$ONLY_CASE" in all|two-dbs|copy-modes|duplicate|old-operator) ;; *)
  printf 'usage: %s [two-dbs|copy-modes|duplicate|old-operator]\n' "$0"; exit 2 ;;
esac

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/pg-multi-db.XXXXXX)"
# Per-run tag: branch names derive from the id, so a branch left over from an
# earlier run must not be able to satisfy this run's checks.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"
SESSION_PID=""
USED_IDS=""

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
RESULTS=""
check() { # <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; FAILURES=$((FAILURES + 1)); fi
}
record() { # <case> <PASS|FAIL|SKIP> <note>
  RESULTS="${RESULTS}$1|$2|$3
"
}

branch_refs_by_id() { # <branch-id> -> one "<namespace> <name>" per line
  kubectl get "$BRANCH_CRD" -A -o json 2>/dev/null \
    | jq -r --arg id "$1" '.items[] | select(.spec.id == $id) | "\(.metadata.namespace) \(.metadata.name)"'
}

stop_session() {
  if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
  fi
  SESSION_PID=""
}

cleanup() {
  stop_session
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1 - leaving namespace $NAMESPACE and branches (ids:$USED_IDS) in place"
    return
  fi
  local id ns name
  for id in $USED_IDS; do
    branch_refs_by_id "$id" | while read -r ns name; do
      [ -n "$name" ] && kubectl delete "$BRANCH_CRD" -n "$ns" "$name" --ignore-not-found >/dev/null 2>&1
    done
  done
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1
  info "cleaned up branches and namespace $NAMESPACE (logs kept in $WORKDIR)"
}
trap cleanup EXIT

# macOS has no `timeout`; bound every blocking mirrord run with a watchdog.
run_with_timeout() { # <secs> <cmd...>
  local secs="$1"
  shift
  "$@" &
  local pid=$!
  (
    sleep "$secs"
    kill "$pid" 2>/dev/null
  ) &
  local watchdog=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$rc"
}

# Runs one SQL statement in the source pod (unaligned, tuples only). Inside the pod
# psql trusts the loopback socket, so no password is needed.
source_sql() { # <database> <sql>
  kubectl exec -n "$NAMESPACE" "$SOURCE_POD" -- psql -v ON_ERROR_STOP=1 -U postgres -d "$1" -tAc "$2"
}

# Runs one SQL statement against a connection URL from inside the source pod, so the
# branch is reached over the pod network with the credentials the session got.
url_sql() { # <url> <sql>
  kubectl exec -n "$NAMESPACE" "$SOURCE_POD" -- psql "$1" -v ON_ERROR_STOP=1 -tAc "$2"
}

branch_sql() { # <pod> <database> <sql>
  kubectl exec -n "$NAMESPACE" "$1" -c postgres -- psql -v ON_ERROR_STOP=1 -U postgres -d "$2" -tAc "$3"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "PostgreSQL branch with additional databases (INT-790)"

command -v jq >/dev/null 2>&1 || { fail "jq not found - brew install jq"; exit 1; }
command -v "$MIRRORD_BIN" >/dev/null 2>&1 || [ -x "$MIRRORD_BIN" ] \
  || { fail "mirrord CLI not found at $MIRRORD_BIN - run 'task mirrord:cli:build' or set MIRRORD_BIN"; exit 1; }

if ! run_with_timeout 20 kubectl get ns default >/dev/null 2>&1; then
  fail "the cluster does not answer - is minikube ($CLUSTER_NAME) up? A kubectl EOF usually means the colima disk needs 'colima stop --force && colima start'"
  exit 1
fi

FEATURES="$(kubectl get mirrordoperators.operator.metalbear.co operator -o json 2>/dev/null \
  | jq -r '.spec.supported_features // [] | .[]')"
if [ -z "$FEATURES" ]; then
  fail "could not read the operator's features - is an operator installed (task operator:use / operator:dev)?"
  exit 1
fi
FEATURE_PRESENT=1
echo "$FEATURES" | grep -qx "$FEATURE" && FEATURE_PRESENT=0
OPERATOR_VERSION="$(kubectl get mirrordoperators.operator.metalbear.co operator \
  -o jsonpath='{.spec.operator_version}' 2>/dev/null)"
if [ "$FEATURE_PRESENT" = 0 ]; then
  info "operator $OPERATOR_VERSION advertises $FEATURE - running cases 1-3"
else
  info "operator $OPERATOR_VERSION does not advertise $FEATURE - running case 4 (old-operator refusal)"
fi

if pgrep -qf 'target/debug/operator-service'; then
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=${OPERATOR_ISOLATION_MARKER:-local-dev}"
  export OPERATOR_ISOLATION_MARKER="${OPERATOR_ISOLATION_MARKER:-local-dev}"
elif [ "$FEATURE_PRESENT" = 0 ]; then
  info "no local operator-service process - using the deployed operator"
fi

if [ "$FEATURE_PRESENT" = 0 ]; then
  # The API server silently prunes a field its CRD schema does not declare, which
  # would leave the operator building a branch with only the first database.
  if ! kubectl get crd "$BRANCH_CRD" -o json 2>/dev/null | grep -q '"additionalDatabases"'; then
    fail "the BranchDatabase CRD has no additionalDatabases - run 'task operator:crds' with OPERATOR_DIR/CHARTS_DIR of the feature branch"
    exit 1
  fi
  info "BranchDatabase CRD carries additionalDatabases"

  # Branch pods copy pg-branch-init out of OPERATOR_IMAGE; the released image does not
  # know --additional-databases, and the failure would only show as a Failed branch.
  if [ "$SKIP_INIT_IMAGE_CHECK" != 1 ]; then
    INIT_IMAGE="$(grep -E '^[[:space:]]*OPERATOR_IMAGE:' "$OPERATOR_DEV_CONFIG" 2>/dev/null \
      | head -1 | sed -E 's/^[^:]*:[[:space:]]*"?([^"]*)"?.*/\1/')"
    if [ -z "$INIT_IMAGE" ]; then
      fail "OPERATOR_IMAGE is not set in $OPERATOR_DEV_CONFIG - build the init image from the feature branch, set OPERATOR_IMAGE: \"mirrord-branch-init:local\" + OPERATOR_IMAGE_PULL_POLICY: \"Never\", restart operator:dev (or SKIP_INIT_IMAGE_CHECK=1)"
      exit 1
    fi
    if [ "$INIT_IMAGE" = "mirrord-branch-init:local" ] \
      && ! minikube -p "$CLUSTER_NAME" image ls 2>/dev/null | grep -q 'mirrord-branch-init:local'; then
      fail "mirrord-branch-init:local is not on the $CLUSTER_NAME node - run 'minikube -p $CLUSTER_NAME image load mirrord-branch-init:local'"
      exit 1
    fi
    info "branch init image: $INIT_IMAGE (from $OPERATOR_DEV_CONFIG)"
  fi
fi
info "mirrord CLI: $MIRRORD_BIN"
info "workdir: $WORKDIR"

# ---------------------------------------------------------------------------
# Fixtures: source server with three databases, and the target deployment
# ---------------------------------------------------------------------------
header "Deploying the source server and the target into $NAMESPACE"
source_url() { echo "postgresql://postgres:postgres@$SOURCE_POD.$NAMESPACE.svc.cluster.local:5432/$1"; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $SOURCE_POD
  namespace: $NAMESPACE
  labels: { app: $SOURCE_POD }
spec:
  containers:
    - name: postgres
      image: postgres:17
      env: [{ name: POSTGRES_PASSWORD, value: postgres }]
      ports: [{ containerPort: 5432 }]
      readinessProbe:
        exec: { command: ["pg_isready", "-h", "127.0.0.1", "-U", "postgres"] }
        periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: $SOURCE_POD
  namespace: $NAMESPACE
spec:
  selector: { app: $SOURCE_POD }
  ports: [{ port: 5432, targetPort: 5432 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TARGET
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector: { matchLabels: { app: $TARGET } }
  template:
    metadata: { labels: { app: $TARGET } }
    spec:
      containers:
        - name: app
          image: postgres:17
          command: ["sleep", "infinity"]
          env:
            - { name: DATABASE_URL, value: "$(source_url app_main)" }
            - { name: ANALYTICS_URL, value: "$(source_url analytics)" }
            - { name: AUDIT_URL, value: "$(source_url audit)" }
EOF

if ! kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$SOURCE_POD" --timeout="${READY_TIMEOUT}s" >/dev/null \
  || ! kubectl rollout status -n "$NAMESPACE" "deployment/$TARGET" --timeout="${READY_TIMEOUT}s" >/dev/null; then
  fail "source pod or target deployment did not become ready - kubectl get pods -n $NAMESPACE"
  exit 1
fi

for db in app_main analytics audit; do
  source_sql postgres "DROP DATABASE IF EXISTS $db WITH (FORCE)" >/dev/null
  source_sql postgres "CREATE DATABASE $db" >/dev/null
done
source_sql app_main "CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT NOT NULL)" >/dev/null
source_sql app_main "INSERT INTO users (name) VALUES ('alice'), ('bob'), ('carol')" >/dev/null
source_sql analytics "CREATE TABLE events (id SERIAL PRIMARY KEY, kind TEXT NOT NULL)" >/dev/null
source_sql analytics "INSERT INTO events (kind) VALUES ('a'), ('b'), ('c'), ('d')" >/dev/null
source_sql audit "CREATE TABLE entries (id SERIAL PRIMARY KEY, what TEXT NOT NULL)" >/dev/null
source_sql audit "INSERT INTO entries (what) VALUES ('x'), ('y')" >/dev/null
info "source seeded: app_main.users=3, analytics.events=4, audit.entries=2"

# write_config <file> <branch-id> <additional_databases-json>
write_config() {
  cat >"$1" <<EOF
{
  "operator": true,
  "target": { "path": "deployment/$TARGET", "namespace": "$NAMESPACE" },
  "feature": {
    "env": true,
    "fs": "local",
    "network": { "incoming": "off", "outgoing": true },
    "db_branches": [
      {
        "id": "$2",
        "type": "pg",
        "name": "app_main",
        "ttl_secs": 300,
        "creation_timeout_secs": 240,
        "connection": { "url": { "type": "env", "variable": "DATABASE_URL" } },
        "copy": { "mode": "all" },
        "additional_databases": $3
      }
    ]
  }
}
EOF
}

# start_session <config> <log>: runs a local shell that prints the rewritten env and
# stays up, so the branch is inspected while the session holds it.
start_session() {
  env -u DATABASE_URL -u ANALYTICS_URL -u AUDIT_URL "$MIRRORD_BIN" exec -f "$1" -- \
    sh -c 'echo "MAIN_URL=$DATABASE_URL"; echo "ANALYTICS_URL=$ANALYTICS_URL"; echo "AUDIT_URL=$AUDIT_URL"; sleep 600' \
    >"$2" 2>&1 &
  SESSION_PID=$!
  info "session pid: $SESSION_PID (log: $2)"
}

# wait_for_env <log>: waits until the session printed its env; non-zero on timeout/death.
wait_for_env() {
  local _
  for _ in $(seq 1 "$READY_TIMEOUT"); do
    grep -q '^AUDIT_URL=' "$1" 2>/dev/null && return 0
    if ! kill -0 "$SESSION_PID" 2>/dev/null; then
      fail "the session exited before printing its env - last log lines:"
      tail -15 "$1"
      if grep -q "additional-databases" "$1"; then
        warn "the branch init rejected --additional-databases: OPERATOR_IMAGE is not an init image built from the feature branch"
      fi
      return 1
    fi
    sleep 1
  done
  fail "no env from the session after ${READY_TIMEOUT}s - last log lines:"
  tail -15 "$1"
  return 1
}

env_value() { grep "^$2=" "$1" | head -1 | cut -d= -f2-; }
url_host_port() { echo "$1" | sed -E 's#^[a-z]+://[^@]*@([^/]*)/.*#\1#'; }
url_db() { echo "$1" | sed -E 's#^[a-z]+://[^/]*/([^?]*).*#\1#'; }

# check_single_branch <branch-id>: checks there is one branch CR and one branch pod
# for the id, and sets BRANCH_POD to that pod (empty when either check fails). Called
# directly, not in $( ), so its check results count.
BRANCH_POD=""
check_single_branch() {
  local refs count name pods
  BRANCH_POD=""
  refs="$(branch_refs_by_id "$1")"
  count="$(printf '%s' "$refs" | grep -c .)"
  check "exactly one branch CR for id $1 (found $count)" "$([ "$count" = 1 ] && echo 0 || echo 1)"
  [ "$count" = 1 ] || return 0
  name="${refs#* }"
  pods="$(kubectl get pods -n "$NAMESPACE" -l "db-owner-name=$name" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  count="$(printf '%s' "$pods" | grep -c .)"
  check "exactly one branch pod for branch $name (found $count)" "$([ "$count" = 1 ] && echo 0 || echo 1)"
  [ "$count" = 1 ] && BRANCH_POD="$pods"
  return 0
}

should_run() { [ "$ONLY_CASE" = all ] || [ "$ONLY_CASE" = "$1" ]; }

# ---------------------------------------------------------------------------
# 1. Two databases in one branch
# ---------------------------------------------------------------------------
if should_run two-dbs; then
  header "1/4 two-dbs: app_main + analytics in one branch pod"
  if [ "$FEATURE_PRESENT" != 0 ]; then
    record two-dbs SKIP "operator lacks $FEATURE"
  else
    before=$FAILURES
    id="pg-multi-two-$RUN_TAG"; USED_IDS="$USED_IDS $id"
    write_config "$WORKDIR/two-dbs.json" "$id" \
      '[{ "name": "analytics", "connection": { "url": { "type": "env", "variable": "ANALYTICS_URL" } }, "copy": { "mode": "all" } }]'
    start_session "$WORKDIR/two-dbs.json" "$WORKDIR/two-dbs.log"
    if wait_for_env "$WORKDIR/two-dbs.log"; then
      main="$(env_value "$WORKDIR/two-dbs.log" MAIN_URL)"
      analytics="$(env_value "$WORKDIR/two-dbs.log" ANALYTICS_URL)"
      info "DATABASE_URL  -> $main"
      info "ANALYTICS_URL -> $analytics"
      check "DATABASE_URL no longer points at the source" \
        "$(echo "$main" | grep -q "$SOURCE_POD" && echo 1 || echo 0)"
      check "both URLs point at the same branch host:port" \
        "$([ "$(url_host_port "$main")" = "$(url_host_port "$analytics")" ] && echo 0 || echo 1)"
      check "DATABASE_URL names app_main" "$([ "$(url_db "$main")" = app_main ] && echo 0 || echo 1)"
      check "ANALYTICS_URL names analytics" "$([ "$(url_db "$analytics")" = analytics ] && echo 0 || echo 1)"
      check_single_branch "$id"
      users="$(url_sql "$main" 'SELECT COUNT(*) FROM users' 2>&1)"
      events="$(url_sql "$analytics" 'SELECT COUNT(*) FROM events' 2>&1)"
      check "DATABASE_URL connects and sees 3 users (got: $users)" "$([ "$users" = 3 ] && echo 0 || echo 1)"
      check "ANALYTICS_URL connects and sees 4 events (got: $events)" "$([ "$events" = 4 ] && echo 0 || echo 1)"
    else
      FAILURES=$((FAILURES + 1))
    fi
    stop_session
    [ "$FAILURES" = "$before" ] && record two-dbs PASS "one pod, both URLs reach their own database" \
      || record two-dbs FAIL "see $WORKDIR/two-dbs.log"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Per-database copy modes, and a database without a connection
# ---------------------------------------------------------------------------
if should_run copy-modes; then
  header "2/4 copy-modes: analytics as schema, audit copied without a connection"
  if [ "$FEATURE_PRESENT" != 0 ]; then
    record copy-modes SKIP "operator lacks $FEATURE"
  else
    before=$FAILURES
    id="pg-multi-modes-$RUN_TAG"; USED_IDS="$USED_IDS $id"
    write_config "$WORKDIR/copy-modes.json" "$id" \
      '[{ "name": "analytics", "connection": { "url": { "type": "env", "variable": "ANALYTICS_URL" } }, "copy": { "mode": "schema" } }, { "name": "audit", "copy": { "mode": "all" } }]'
    start_session "$WORKDIR/copy-modes.json" "$WORKDIR/copy-modes.log"
    if wait_for_env "$WORKDIR/copy-modes.log"; then
      audit="$(env_value "$WORKDIR/copy-modes.log" AUDIT_URL)"
      check "AUDIT_URL (no connection configured) still points at the source" \
        "$(echo "$audit" | grep -q "$SOURCE_POD" && echo 0 || echo 1)"
      check_single_branch "$id"
      pod="$BRANCH_POD"
      if [ -n "$pod" ]; then
        users="$(branch_sql "$pod" app_main 'SELECT COUNT(*) FROM users' 2>&1)"
        events="$(branch_sql "$pod" analytics 'SELECT COUNT(*) FROM events' 2>&1)"
        entries="$(branch_sql "$pod" audit 'SELECT COUNT(*) FROM entries' 2>&1)"
        check "app_main (all) has 3 users (got: $users)" "$([ "$users" = 3 ] && echo 0 || echo 1)"
        check "analytics (schema) has the events table and no rows (got: $events)" \
          "$([ "$events" = 0 ] && echo 0 || echo 1)"
        check "audit (all, no connection) exists with 2 entries (got: $entries)" \
          "$([ "$entries" = 2 ] && echo 0 || echo 1)"
      fi
    else
      FAILURES=$((FAILURES + 1))
    fi
    stop_session
    [ "$FAILURES" = "$before" ] && record copy-modes PASS "all/schema per database, audit copied unredirected" \
      || record copy-modes FAIL "see $WORKDIR/copy-modes.log"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Duplicate name -> refused by the CLI before anything is created
# ---------------------------------------------------------------------------
if should_run duplicate; then
  header "3/4 duplicate: analytics listed twice -> refused"
  if [ "$FEATURE_PRESENT" != 0 ]; then
    record duplicate SKIP "operator lacks $FEATURE"
  else
    before=$FAILURES
    id="pg-multi-dup-$RUN_TAG"; USED_IDS="$USED_IDS $id"
    write_config "$WORKDIR/duplicate.json" "$id" '[{ "name": "analytics" }, { "name": "analytics" }]'
    if run_with_timeout "$REJECT_TIMEOUT" "$MIRRORD_BIN" exec -f "$WORKDIR/duplicate.json" -- sh -c 'exit 0' \
      >"$WORKDIR/duplicate.log" 2>&1; then
      check "the CLI refuses a duplicate additional database" 1
    else
      check "the CLI refuses a duplicate additional database" 0
      check "the error names the duplicate" \
        "$(grep -q '`analytics` more than once' "$WORKDIR/duplicate.log" && echo 0 || echo 1)"
    fi
    check "no branch CR was created for id $id" \
      "$([ -z "$(branch_refs_by_id "$id")" ] && echo 0 || echo 1)"
    [ "$FAILURES" = "$before" ] && record duplicate PASS "refused before any branch" \
      || record duplicate FAIL "see $WORKDIR/duplicate.log"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Operator without the feature -> the CLI refuses instead of half-branching
# ---------------------------------------------------------------------------
if should_run old-operator; then
  header "4/4 old-operator: refusal on an operator without $FEATURE"
  if [ "$FEATURE_PRESENT" = 0 ]; then
    record old-operator SKIP "operator has $FEATURE; rerun under 'task operator:use VERSION=<released>'"
  else
    before=$FAILURES
    id="pg-multi-old-$RUN_TAG"; USED_IDS="$USED_IDS $id"
    write_config "$WORKDIR/old-operator.json" "$id" \
      '[{ "name": "analytics", "connection": { "url": { "type": "env", "variable": "ANALYTICS_URL" } } }]'
    if run_with_timeout "$REJECT_TIMEOUT" "$MIRRORD_BIN" exec -f "$WORKDIR/old-operator.json" -- sh -c 'exit 0' \
      >"$WORKDIR/old-operator.log" 2>&1; then
      check "the CLI refuses additional databases on this operator" 1
    else
      check "the CLI refuses additional databases on this operator" 0
      check "the error says the operator does not support it" \
        "$(grep -q 'not supported in mirrord operator' "$WORKDIR/old-operator.log" && echo 0 || echo 1)"
    fi
    check "no branch CR was created for id $id" \
      "$([ -z "$(branch_refs_by_id "$id")" ] && echo 0 || echo 1)"
    [ "$FAILURES" = "$before" ] && record old-operator PASS "refused with an upgrade hint" \
      || record old-operator FAIL "see $WORKDIR/old-operator.log"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"
printf '%s' "$RESULTS" | while IFS='|' read -r name verdict note; do
  [ -n "$name" ] || continue
  printf '  %-13s %-5s %s\n' "$name" "$verdict" "$note"
done

if [ "$FAILURES" -gt 0 ]; then
  fail "$FAILURES check(s) failed - logs in $WORKDIR"
  exit 1
fi
pass "all checks passed"
