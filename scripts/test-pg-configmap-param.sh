#!/usr/bin/env bash
#
# End-to-end test: `configmap` connection param sources for DB branching.
#
# Customer setup being simulated: the app has no DB env vars at all - host,
# port and database name live in a config file mounted from a ConfigMap whose
# name carries a release suffix that changes on every deploy. The mirrord
# config reaches the file through the pod's volume (stable name) and digs the
# values out with `value_selector` / `value_pattern`; `env_var_name` hands the
# branch's values to the local process. Two cases:
#
#   1. RESOLVE: host/port via `{"configmap": {"volume": ...}}` + selector,
#               database via `{"configmap": "<name>"}` + pattern (the branch
#               declares `name`, which is what makes the operator redirect the
#               database var at all - same as for every other source). Expected:
#               branch Ready, init container got the source host the operator
#               read from the file, branch carries the copied rows, and the
#               local session sees DB_HOST/DB_PORT/DB_NAME pointing at the
#               branch instead of the source.
#   2. MISS:    a selector that matches nothing. Expected: branch Failed with
#               an error naming the selector and the key, so a typo in the
#               mirrord config is diagnosed instead of silently defaulting.
#   3. PROFILE: the selector params carry nothing but their selector; the
#               ConfigMap volume and key come from the `app-config` profile in
#               configs/pg-branch-config.yaml (the file operator:dev loads).
#               The pattern param keeps `key` (a pattern plus env_var_name
#               alone is an env-var pattern source). Expected: same as case 1.
#
# The script deploys the target pod + ConfigMap itself, reuses the postgres
# test env (task postgres:deploy) for the source DB, and cleans up on exit.
#
# Prerequisites:
#   - minikube (bearkube) running with an operator that carries the configmap
#     source: `task operator:dev` from the current operator checkout (the
#     script labels its sessions for it, like the postgres:* tasks do)
#   - a mirrord CLI built from the matching mirrord checkout (the config shape
#     is new on the CLI side too)
#
# Usage:
#   scripts/test-pg-configmap-param.sh          # both cases
#   scripts/test-pg-configmap-param.sh resolve  # only case 1
#   scripts/test-pg-configmap-param.sh miss     # only case 2
#   scripts/test-pg-configmap-param.sh profile  # only case 3
#   task postgres:configmap:test                # both cases
#   KEEP=1 scripts/test-pg-configmap-param.sh   # leave branches + target in place
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI to use (default: local debug build, then PATH)
#   READY_TIMEOUT   seconds for a branch to reach Ready/Failed (default 300)
#   CLUSTER_NAME    minikube profile (default bearkube)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="test-mirrord"
CLUSTER_NAME="${CLUSTER_NAME:-bearkube}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"

# The postgres test env's source DB (task postgres:deploy).
SOURCE_HOST="postgres-test"
SOURCE_DB="source_db"

ONLY_CASE="${1:-all}"
case "$ONLY_CASE" in all|resolve|miss|profile) ;; *)
  printf 'usage: %s [resolve|miss|profile]\n' "$0"; exit 2 ;;
esac

LOCAL_MIRRORD="$SCRIPT_DIR/../../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/pg-cm-branch.XXXXXX)"
# Per-run tag so a stale branch from an earlier run cannot satisfy this run's
# checks (branch CRD names derive from the id), and so the ConfigMap name
# changes per run the way a deploy tool would bump it.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"

TARGET="pg-cm-app"
CONFIG_MAP="$TARGET-config-1.0.0-$RUN_TAG"
RESOLVE_BRANCH_ID="pg-cm-resolve-$RUN_TAG"
MISS_BRANCH_ID="pg-cm-miss-$RUN_TAG"
PROFILE_BRANCH_ID="pg-cm-profile-$RUN_TAG"
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
    warn "KEEP=1 - leaving the branches, target pod and ConfigMap in place"
    warn "  branch ids: $RESOLVE_BRANCH_ID $MISS_BRANCH_ID $PROFILE_BRANCH_ID"
    warn "  remove with: kubectl delete deploy/$TARGET cm/$CONFIG_MAP -n $NAMESPACE"
    return
  fi
  local id name
  for id in "$RESOLVE_BRANCH_ID" "$MISS_BRANCH_ID" "$PROFILE_BRANCH_ID"; do
    name="$(branch_name_by_id "$id")"
    [ -n "$name" ] && kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" "$name" \
      --ignore-not-found >/dev/null 2>&1
  done
  kubectl delete "deploy/$TARGET" "cm/$CONFIG_MAP" -n "$NAMESPACE" \
    --ignore-not-found >/dev/null 2>&1
  info "cleaned up branches, target pod, ConfigMap and session"
}
trap cleanup EXIT

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
    case "$phase" in Ready|Failed) return 1 ;; esac
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

# The local process prints the connection vars it was handed, then idles so
# the branch stays owned by a live session while the checks run.
launch_session() { # <mirrord-config> <log>
  "$MIRRORD_BIN" exec -f "$1" -- sh -c \
    'echo "SESSION READY DB_HOST=$DB_HOST DB_PORT=$DB_PORT DB_NAME=$DB_NAME"; sleep 240' \
    > "$2" 2>&1 &
  SESSION_PID=$!
  disown "$SESSION_PID" 2>/dev/null || true
  info "session starting in the background (pid $SESSION_PID)"
  info "follow it with: tail -f $2"
}

wait_session_ready() { # <log>  -> 0 when the local process printed its env
  local waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    grep -q "SESSION READY" "$1" 2>/dev/null && return 0
    kill -0 "$SESSION_PID" 2>/dev/null || return 1
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

branch_pod() { # <branch-name> -> pod name (running)
  kubectl get pod -n "$NAMESPACE" -l "db-owner-name=$1" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# The operator resolved the host out of the mounted file: the init container
# was handed it as a literal, the way pattern-extracted values travel.
check_init_extracted_host() { # <branch-name>
  local pod value
  pod="$(kubectl get pod -n "$NAMESPACE" -l "db-owner-name=$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [ -z "$pod" ]; then
    check "branch pod exists for init-env inspection" 1
    return
  fi
  value="$(kubectl get pod -n "$NAMESPACE" "$pod" -o json \
    | jq -r '.spec.initContainers[].env[]? | select(.name == "MIRRORD_EXTRACTED_HOST") | .value' \
    | head -1)"
  info "init container MIRRORD_EXTRACTED_HOST=$value"
  check "init container got the source host read from config.yml" \
    "$([ "$value" = "$SOURCE_HOST" ] && echo 0 || echo 1)"
}

# The copy must have actually run: the branch database carries the source rows.
check_branch_data() { # <branch-name>
  local pod count=""
  pod="$(branch_pod "$1")"
  if [ -z "$pod" ]; then
    check "branch pod running" 1
    return
  fi
  info "branch pod: $pod"
  count="$(kubectl exec -n "$NAMESPACE" "$pod" -- \
    psql -U postgres -d "$SOURCE_DB" -tAc 'SELECT count(*) FROM users;' 2>/dev/null \
    | tr -d '[:space:]')"
  info "users rows in branch db '$SOURCE_DB': ${count:-<query failed>}"
  check "branch carries the copied source data (users > 0)" \
    "$([ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null && echo 0 || echo 1)"
}

# The local process must have been pointed at the branch: env_var_name on a
# configmap source delivers the branch host/port/database, never the source's.
check_local_env() { # <branch-name> <log>
  local line host port db pod pod_ip
  line="$(grep "SESSION READY" "$2" | head -1)"
  host="$(printf '%s' "$line" | sed -n 's/.*DB_HOST=\([^ ]*\).*/\1/p')"
  port="$(printf '%s' "$line" | sed -n 's/.*DB_PORT=\([^ ]*\).*/\1/p')"
  db="$(printf '%s' "$line" | sed -n 's/.*DB_NAME=\([^ ]*\).*/\1/p')"
  info "local process env: DB_HOST=$host DB_PORT=$port DB_NAME=$db"
  pod="$(branch_pod "$1")"
  pod_ip="$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.podIP}' 2>/dev/null)"
  check "local DB_HOST is the branch pod, not the source ($SOURCE_HOST)" \
    "$([ -n "$host" ] && [ "$host" != "$SOURCE_HOST" ] && printf '%s' "$host" | grep -q "$pod_ip\|$pod" && echo 0 || echo 1)"
  check "local DB_PORT is set from the branch" "$([ -n "$port" ] && echo 0 || echo 1)"
  check "local DB_NAME is the database read from config.yml" \
    "$([ "$db" = "$SOURCE_DB" ] && echo 0 || echo 1)"
}

report_branch_failure() { # <branch-name>
  warn "phase: $(branch_field "$1" '{.status.phase}'), error: $(branch_field "$1" '{.status.error}')"
}

# With a third argument (a profile name) the params carry no `configmap`/`key`
# at all - the profile's `sourceConfigMap` supplies both.
mirrord_config() { # <branch-id> <host-selector> [profile]
  local profile_line="" host_locator="" port_locator="" db_locator=""
  if [ -n "${3:-}" ]; then
    profile_line="\"profile\": \"$3\","
    # A pattern-only param would read as an env-var pattern source, so the
    # `database` param keeps its `key` to stay a configmap source; the
    # ConfigMap itself still comes from the profile.
    db_locator='"key": "config.yml",'
  else
    host_locator='"configmap": { "volume": "app-config" }, "key": "config.yml",'
    port_locator="$host_locator"
    db_locator="\"configmap\": \"$CONFIG_MAP\", \"key\": \"config.yml\","
  fi
  cat <<EOF
{
  "operator": true,
  "target": {
    "path": "deploy/$TARGET",
    "namespace": "$NAMESPACE"
  },
  "feature": {
    "env": true,
    "fs": "local",
    "network": { "incoming": "off", "outgoing": true },
    "db_branches": [
      {
        "id": "$1",
        "type": "pg",
        "version": "17",
        "name": "$SOURCE_DB",
        $profile_line
        "ttl_secs": 300,
        "creation_timeout_secs": 180,
        "copy": { "mode": "all" },
        "connection": {
          "params": {
            "host": {
              $host_locator
              "value_selector": "$2",
              "env_var_name": "DB_HOST"
            },
            "port": {
              $port_locator
              "value_selector": ".database.port",
              "env_var_name": "DB_PORT"
            },
            "database": {
              $db_locator
              "value_pattern": "name: '(?P<database>[^']+)'",
              "env_var_name": "DB_NAME"
            },
            "user": "DB_USER",
            "password": "DB_PASSWORD"
          }
        }
      }
    ]
  }
}
EOF
}

# Runs the happy-path checks for one branch: Ready, source host extracted from
# the file, rows copied, and the local process pointed at the branch.
run_resolve_case() { # <branch-id> <mirrord-config> <log> <label>
  launch_session "$2" "$3"
  if BRANCH="$(wait_branch "$1" "$SESSION_PID" "$3")"; then
    info "branch CRD: $BRANCH"
    if wait_branch_phase "$BRANCH" "Ready"; then
      check "$4 branch reaches Ready" 0
      check_init_extracted_host "$BRANCH"
      check_branch_data "$BRANCH"
      if wait_session_ready "$3"; then
        check_local_env "$BRANCH" "$3"
      else
        check "local process started under the session" 1
        tail -20 "$3"
      fi
    else
      check "$4 branch reaches Ready" 1
      report_branch_failure "$BRANCH"
    fi
  else
    FAILURES=$((FAILURES + 1))
  fi
  kill_session
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "ConfigMap-sourced pg-branch e2e - preflight"

command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq not found"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not usable: $MIRRORD_BIN"; exit 1; }
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "workdir: $WORKDIR (mirrord configs + session logs live here)"
[ "$HAVE_GUM" = 1 ] || warn "gum not installed (brew install gum) - plain output"

# A CLI without the configmap source rejects the config before the operator
# ever sees it; fail fast with the reason instead of a confusing session log.
printf '%s' "$(mirrord_config preflight .database.host)" > "$WORKDIR/preflight.json"
if ! "$MIRRORD_BIN" verify-config "$WORKDIR/preflight.json" >/dev/null 2>&1; then
  fail "this mirrord CLI rejects the configmap param source - build it from the mirrord checkout carrying it"
  "$MIRRORD_BIN" verify-config "$WORKDIR/preflight.json" 2>&1 | tail -5
  exit 1
fi
info "mirrord CLI accepts the configmap param source"

# Sessions labeled with an isolation marker are reconciled by a locally
# running operator:dev instead of the deployed one - same convention as the
# postgres:* tasks.
if [ -n "${OPERATOR_ISOLATION_MARKER:-}" ]; then
  info "using OPERATOR_ISOLATION_MARKER=$OPERATOR_ISOLATION_MARKER from the environment"
elif pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
else
  warn "no operator:dev process detected - the DEPLOYED operator will reconcile the"
  warn "branches, and it must carry the configmap source support"
  confirm "Continue against the deployed operator?" || exit 0
fi

# ---------------------------------------------------------------------------
# Deploy: source DB (postgres test env), mounted ConfigMap, target pod
# ---------------------------------------------------------------------------
header "Deploy (only what's missing)"

if kubectl get pod postgres-test -n "$NAMESPACE" >/dev/null 2>&1; then
  info "postgres test env already deployed (pod/postgres-test)"
else
  info "postgres test env missing - deploying via task postgres:deploy"
  (cd "$ROOT_DIR" && task postgres:deploy) || { fail "task postgres:deploy failed"; exit 1; }
fi
kubectl wait --for=condition=ready pod -l app=postgres-test -n "$NAMESPACE" --timeout=120s >/dev/null \
  || { fail "postgres-test source pod not ready"; exit 1; }
info "source DB ready (pod/postgres-test)"

# The app's config file: quoted host, bare-number port, unrelated keys around
# the database block - the selector has to walk the nested block and turn the
# number into a string. The ConfigMap's release-style name is what a deploy
# tool would bump; only the volume name below is stable.
info "deploying config ConfigMap ($CONFIG_MAP) and target pod (deploy/$TARGET)"
kubectl apply -n "$NAMESPACE" -f - <<EOF >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIG_MAP
data:
  config.yml: |
    debug: false
    stage: 'DEVO'
    port: '9200'
    database:
      host: '$SOURCE_HOST'
      port: 5432
      name: '$SOURCE_DB'
    redis:
      host: 'cache.redis.db'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TARGET
  labels: { app: $TARGET }
spec:
  replicas: 1
  selector: { matchLabels: { app: $TARGET } }
  template:
    metadata: { labels: { app: $TARGET } }
    spec:
      volumes:
      - name: app-config
        configMap: { name: $CONFIG_MAP }
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "echo 'pg configmap scenario target running' && sleep 86400"]
        volumeMounts:
        - { name: app-config, mountPath: /etc/app }
        env:
        - { name: DB_USER, value: "postgres" }
        - { name: DB_PASSWORD, value: "postgres" }
EOF
kubectl rollout status "deploy/$TARGET" -n "$NAMESPACE" --timeout=120s >/dev/null \
  || { fail "$TARGET target never became ready"; exit 1; }
info "target ready (deploy/$TARGET), no DB host/port/name in its env"

# ---------------------------------------------------------------------------
# Case 1 - values resolved out of the mounted file
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" = "all" ] || [ "$ONLY_CASE" = "resolve" ]; then
header "Case 1/3: host/port/database read from config.yml"

RESOLVE_MIRRORD="$WORKDIR/mirrord-resolve.json"
mirrord_config "$RESOLVE_BRANCH_ID" ".database.host" > "$RESOLVE_MIRRORD"
run_resolve_case "$RESOLVE_BRANCH_ID" "$RESOLVE_MIRRORD" "$WORKDIR/resolve-session.log" "configmap-sourced"
fi # case 1

# ---------------------------------------------------------------------------
# Case 2 - a selector that matches nothing is diagnosed, not defaulted
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" = "all" ] || [ "$ONLY_CASE" = "miss" ]; then
header "Case 2/3: selector miss fails the branch with a named error"

MISS_MIRRORD="$WORKDIR/mirrord-miss.json"
mirrord_config "$MISS_BRANCH_ID" ".database.hostname" > "$MISS_MIRRORD"
MISS_LOG="$WORKDIR/miss-session.log"
launch_session "$MISS_MIRRORD" "$MISS_LOG"

if BRANCH="$(wait_branch "$MISS_BRANCH_ID" "$SESSION_PID" "$MISS_LOG")"; then
  info "branch CRD: $BRANCH"
  if wait_branch_phase "$BRANCH" "Failed"; then
    check "selector miss leaves the branch Failed" 0
    ERROR="$(branch_field "$BRANCH" '{.status.error}')"
    info "error: $ERROR"
    check "error names the selector and the key" \
      "$(printf '%s' "$ERROR" | grep -q "database.hostname" && printf '%s' "$ERROR" | grep -q "config.yml" && echo 0 || echo 1)"
  else
    check "selector miss leaves the branch Failed" 1
    report_branch_failure "$BRANCH"
  fi
else
  FAILURES=$((FAILURES + 1))
fi
kill_session
fi # case 2

# ---------------------------------------------------------------------------
# Case 3 - ConfigMap volume and key come from the admin profile
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" = "all" ] || [ "$ONLY_CASE" = "profile" ]; then
header "Case 3/3: params carry only selectors, profile app-config supplies the ConfigMap"

PROFILE_MIRRORD="$WORKDIR/mirrord-profile.json"
mirrord_config "$PROFILE_BRANCH_ID" ".database.host" "app-config" > "$PROFILE_MIRRORD"
warn "needs the app-config profile from configs/pg-branch-config.yaml loaded by operator:dev"
warn "(restart operator:dev if it started before that profile was added)"
run_resolve_case "$PROFILE_BRANCH_ID" "$PROFILE_MIRRORD" "$WORKDIR/profile-session.log" "profile-sourced"
fi # case 3

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
