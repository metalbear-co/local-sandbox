#!/usr/bin/env bash
#
# End-to-end test: AWS Secrets Manager connection sources for DB branching,
# against LocalStack (no real AWS account needed).
#
# Customer setup being simulated: the app reads its database credentials from
# AWS Secrets Manager, so the mirrord config points the branch's connection at
# a secret instead of a pod env var. The branch init container fetches the
# value at data-copy time using the AWS env it inherits from the target pod
# (here: LocalStack test keys + AWS_ENDPOINT_URL; on a real cluster: IRSA /
# EKS Pod Identity or static keys). Two cases:
#
#   1. PARAM:  params mode, password from `{"aws_secrets_manager": ...}` -
#              branch reaches Ready and carries the source data.
#   2. URL:    URL mode, the whole connection URL from
#              `{"type": "aws_secrets_manager", "secret_ref": ...}`.
#
# Both cases also assert that the init container was given the target's AWS
# env (static keys, region, endpoint override) - the operator-side propagation
# that makes ASM sources work for static-key targets at all. An operator
# without it leaves the init container credential-less and the branch Failed.
#
# The script deploys LocalStack and a target pod itself, seeds the secrets,
# reuses the postgres test env (task postgres:deploy) for the source DB, and
# cleans everything up on exit.
#
# Prerequisites:
#   - minikube (bearkube) running with an operator that carries the ASM
#     support: `task operator:dev` from the current operator checkout (the
#     script labels its sessions for it, like the postgres:* tasks do), and
#     mirrord-branch-init:local loaded for the branch init binaries
#
# Usage:
#   scripts/test-asm-pg-branch.sh          # both cases
#   scripts/test-asm-pg-branch.sh param    # only case 1
#   scripts/test-asm-pg-branch.sh url      # only case 2
#   task postgres:asm:test                 # both cases
#   KEEP=1 scripts/test-asm-pg-branch.sh   # leave branches + LocalStack in place
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
SOURCE_URL="postgresql://postgres:postgres@postgres-test:5432/source_db"
SOURCE_PASSWORD="postgres"

# Secret names seeded into LocalStack; the param case reads the password, the
# URL case reads the whole URL. Plain names on purpose - region and endpoint
# must then come from the propagated AWS env, which is exactly what this test
# guards.
PASSWORD_SECRET="pg-branch-password"
URL_SECRET="pg-branch-url"

ONLY_CASE="${1:-all}"
case "$ONLY_CASE" in all|param|url) ;; *)
  printf 'usage: %s [param|url]\n' "$0"; exit 2 ;;
esac

LOCAL_MIRRORD="$SCRIPT_DIR/../../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/asm-pg-branch.XXXXXX)"
# Per-run tag so a stale branch from an earlier run cannot satisfy this run's
# checks (branch CRD names derive from the id).
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"

PARAM_BRANCH_ID="pg-asm-param-$RUN_TAG"
URL_BRANCH_ID="pg-asm-url-$RUN_TAG"
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
    warn "KEEP=1 - leaving the branches, target pod and LocalStack in place"
    warn "  branch ids: $PARAM_BRANCH_ID $URL_BRANCH_ID"
    warn "  remove with: kubectl delete deploy/pg-asm-app deploy/localstack svc/localstack -n $NAMESPACE"
    return
  fi
  local id name
  for id in "$PARAM_BRANCH_ID" "$URL_BRANCH_ID"; do
    name="$(branch_name_by_id "$id")"
    [ -n "$name" ] && kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" "$name" \
      --ignore-not-found >/dev/null 2>&1
  done
  kubectl delete deploy/pg-asm-app deploy/localstack svc/localstack -n "$NAMESPACE" \
    --ignore-not-found >/dev/null 2>&1
  info "cleaned up branches, target pod, LocalStack and session"
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

launch_session() { # <mirrord-config> <log>
  "$MIRRORD_BIN" exec -f "$1" -- sh -c 'echo "SESSION READY"; sleep 240' \
    > "$2" 2>&1 &
  SESSION_PID=$!
  disown "$SESSION_PID" 2>/dev/null || true
  info "session starting in the background (pid $SESSION_PID)"
  info "follow it with: tail -f $2"
}

# The branch init container must have inherited the target's AWS env - keys,
# region and the LocalStack endpoint - or the fetch had no credentials at all.
check_init_aws_env() { # <branch-name>
  local pod init_env
  pod="$(kubectl get pod -n "$NAMESPACE" -l "db-owner-name=$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [ -z "$pod" ]; then
    check "branch pod exists for init-env inspection" 1
    return
  fi
  init_env="$(kubectl get pod -n "$NAMESPACE" "$pod" \
    -o jsonpath='{range .spec.initContainers[*].env[*]}{.name}{"\n"}{end}' 2>/dev/null)"
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_ENDPOINT_URL; do
    if printf '%s\n' "$init_env" | grep -qx "$var"; then
      check "init container inherits $var from the target" 0
    else
      check "init container inherits $var from the target" 1
    fi
  done
}

# The copy must have actually run: the branch database carries the source rows.
check_branch_data() { # <branch-name>
  local pod count
  pod="$(kubectl get pod -n "$NAMESPACE" -l "db-owner-name=$1" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [ -z "$pod" ]; then
    check "branch pod running" 1
    return
  fi
  info "branch pod: $pod"
  # The branch database name depends on the connection: derived from the URL /
  # params (source_db here) unless the config names one. Try both conventions.
  local db count=""
  for db in source_db branch_db; do
    count="$(kubectl exec -n "$NAMESPACE" "$pod" -- \
      psql -U postgres -d "$db" -tAc 'SELECT count(*) FROM users;' 2>/dev/null \
      | tr -d '[:space:]')"
    [ -n "$count" ] && { info "users rows in branch db '$db': $count"; break; }
  done
  [ -n "$count" ] || info "users rows in branch: <query failed>"
  check "branch carries the copied source data (users > 0)" \
    "$([ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null && echo 0 || echo 1)"
}

report_branch_failure() { # <branch-name>
  warn "phase: $(branch_field "$1" '{.status.phase}'), error: $(branch_field "$1" '{.status.error}')"
  warn "a credential-less fetch shows up here as an ASM error naming the cause"
  warn "(no region / no credentials) - that is the propagation gap this test guards"
}

mirrord_config() { # <branch-id> <connection-json>
  cat <<EOF
{
  "operator": true,
  "target": {
    "path": "deploy/pg-asm-app",
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
        "ttl_secs": 300,
        "creation_timeout_secs": 180,
        "copy": { "mode": "all" },
        "connection": $2
      }
    ]
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "AWS Secrets Manager pg-branch e2e - preflight"

command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq not found"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not usable: $MIRRORD_BIN"; exit 1; }
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "workdir: $WORKDIR (mirrord configs + session logs live here)"
[ "$HAVE_GUM" = 1 ] || warn "gum not installed (brew install gum) - plain output"

# Sessions labeled with an isolation marker are reconciled by a locally
# running operator:dev instead of the deployed one - same convention as the
# postgres:* tasks.
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
else
  warn "no operator:dev process detected - the DEPLOYED operator will reconcile the"
  warn "branches, and it must carry the ASM support incl. the AWS env propagation"
  confirm "Continue against the deployed operator?" || exit 0
fi

# ---------------------------------------------------------------------------
# Deploy: source DB (postgres test env), LocalStack, target pod, secrets
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

info "deploying LocalStack (secretsmanager only)"
kubectl apply -n "$NAMESPACE" -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: localstack
  labels: { app: localstack }
spec:
  replicas: 1
  selector: { matchLabels: { app: localstack } }
  template:
    metadata: { labels: { app: localstack } }
    spec:
      containers:
      - name: localstack
        image: localstack/localstack:3
        env:
        - { name: SERVICES, value: "secretsmanager" }
        ports: [ { containerPort: 4566 } ]
        readinessProbe:
          httpGet: { path: /_localstack/health, port: 4566 }
          initialDelaySeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: localstack
spec:
  selector: { app: localstack }
  ports: [ { port: 4566, targetPort: 4566 } ]
EOF
kubectl rollout status deploy/localstack -n "$NAMESPACE" --timeout=180s >/dev/null \
  || { fail "LocalStack never became ready"; exit 1; }

LOCALSTACK_POD="$(kubectl get pod -n "$NAMESPACE" -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}')"
seed_secret() { # <name> <value>
  kubectl exec -n "$NAMESPACE" "$LOCALSTACK_POD" -- \
    awslocal secretsmanager create-secret --name "$1" --secret-string "$2" >/dev/null 2>&1 \
  || kubectl exec -n "$NAMESPACE" "$LOCALSTACK_POD" -- \
    awslocal secretsmanager put-secret-value --secret-id "$1" --secret-string "$2" >/dev/null
}
seed_secret "$PASSWORD_SECRET" "$SOURCE_PASSWORD" || { fail "seeding $PASSWORD_SECRET failed"; exit 1; }
seed_secret "$URL_SECRET" "$SOURCE_URL" || { fail "seeding $URL_SECRET failed"; exit 1; }
info "secrets seeded in LocalStack: $PASSWORD_SECRET, $URL_SECRET"

# The target pod carries the AWS env the branch init container must inherit
# (LocalStack test keys + endpoint override), the way a real static-key target
# carries its own. The connection params reference its DB_* vars; the password
# is deliberately NOT in the pod env - only in Secrets Manager.
info "deploying target pod (deploy/pg-asm-app)"
kubectl apply -n "$NAMESPACE" -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pg-asm-app
  labels: { app: pg-asm-app }
spec:
  replicas: 1
  selector: { matchLabels: { app: pg-asm-app } }
  template:
    metadata: { labels: { app: pg-asm-app } }
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "echo 'pg ASM scenario target running' && sleep 86400"]
        env:
        - { name: DB_HOST, value: "postgres-test" }
        - { name: DB_PORT, value: "5432" }
        - { name: DB_USER, value: "postgres" }
        - { name: DB_NAME, value: "source_db" }
        - { name: AWS_ACCESS_KEY_ID, value: "test" }
        - { name: AWS_SECRET_ACCESS_KEY, value: "test" }
        - { name: AWS_REGION, value: "us-east-1" }
        - { name: AWS_ENDPOINT_URL, value: "http://localstack:4566" }
EOF
kubectl rollout status deploy/pg-asm-app -n "$NAMESPACE" --timeout=120s >/dev/null \
  || { fail "pg-asm-app target never became ready"; exit 1; }
info "target ready (deploy/pg-asm-app)"

# ---------------------------------------------------------------------------
# Case 1 - params mode, password fetched from Secrets Manager
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" != "url" ]; then
header "Case 1/2: params mode, password from aws_secrets_manager"

PARAM_MIRRORD="$WORKDIR/mirrord-param.json"
mirrord_config "$PARAM_BRANCH_ID" "$(cat <<EOF
{
  "params": {
    "host": "DB_HOST",
    "port": "DB_PORT",
    "user": "DB_USER",
    "database": "DB_NAME",
    "password": {
      "aws_secrets_manager": "$PASSWORD_SECRET",
      "env_var_name": "DB_PASSWORD"
    }
  }
}
EOF
)" > "$PARAM_MIRRORD"
PARAM_LOG="$WORKDIR/param-session.log"
launch_session "$PARAM_MIRRORD" "$PARAM_LOG"

if BRANCH="$(wait_branch "$PARAM_BRANCH_ID" "$SESSION_PID" "$PARAM_LOG")"; then
  info "branch CRD: $BRANCH"
  if wait_branch_phase "$BRANCH" "Ready"; then
    check "param-mode ASM branch reaches Ready" 0
    check_init_aws_env "$BRANCH"
    check_branch_data "$BRANCH"
  else
    check "param-mode ASM branch reaches Ready" 1
    report_branch_failure "$BRANCH"
  fi
else
  FAILURES=$((FAILURES + 1))
fi
kill_session
fi # ONLY_CASE != url

# ---------------------------------------------------------------------------
# Case 2 - URL mode, the whole connection URL fetched from Secrets Manager
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" != "param" ]; then
header "Case 2/2: URL mode from aws_secrets_manager"

URL_MIRRORD="$WORKDIR/mirrord-url.json"
mirrord_config "$URL_BRANCH_ID" "$(cat <<EOF
{
  "url": {
    "type": "aws_secrets_manager",
    "secret_ref": "$URL_SECRET",
    "env_var_name": "DATABASE_URL"
  }
}
EOF
)" > "$URL_MIRRORD"
URL_LOG="$WORKDIR/url-session.log"
launch_session "$URL_MIRRORD" "$URL_LOG"

if BRANCH="$(wait_branch "$URL_BRANCH_ID" "$SESSION_PID" "$URL_LOG")"; then
  info "branch CRD: $BRANCH"
  if wait_branch_phase "$BRANCH" "Ready"; then
    check "URL-mode ASM branch reaches Ready" 0
    check_init_aws_env "$BRANCH"
    check_branch_data "$BRANCH"
  else
    check "URL-mode ASM branch reaches Ready" 1
    report_branch_failure "$BRANCH"
  fi
else
  FAILURES=$((FAILURES + 1))
fi
kill_session
fi # ONLY_CASE != param

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
