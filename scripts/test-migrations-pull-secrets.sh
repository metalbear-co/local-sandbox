#!/usr/bin/env bash
#
# End-to-end test: a DB branch migration Job inherits the TARGET pod's
# imagePullSecrets (the Teladoc/Artifactory shape from INT support).
#
# Customer setup being simulated:
#   - the target workload's pod template carries imagePullSecrets for a
#     private registry (Helm injects them; the namespace default SA has none)
#   - migrations.flavor=container with migrations.image from that registry
#   - without the fix the migration Job pod has NO pull secrets and dies with
#     ImagePullBackOff / 401 on the anonymous token fetch
#
# Two phases, because Teladoc hits this from a preview environment:
#   1. EXEC:    a plain `mirrord exec` session against a pod target
#   2. PREVIEW: a `mirrord preview` session against a deployment target -
#               same branch controller path, driven the way the customer does
#
# Each phase proves:
#   - the migration Job's pod template contains the target's pull secret name
#     (merged with whatever the operator's branch config sets)
#   - the branch still reaches Ready and the migration run Succeeds - the
#     copied secret points at a registry that never matches the public
#     migration image, so it is inert and must not break the pull
#
# The pull secret is a fake dockerconfigjson for registry.example.com on
# purpose: it can never match the busybox/postgres pulls, so the test needs no
# real private registry while still proving the propagation.
#
# Prerequisites:
#   - minikube (bearkube) running with the mirrord operator installed, built
#     WITH the pull-secret fix (task operator:dev works - the script labels the
#     session for it like the migrations:* tasks do)
#
# Usage:
#   ./test-migrations-pull-secrets.sh
#   SKIP_PREVIEW=1 ./test-migrations-pull-secrets.sh   # exec phase only
#   SKIP_EXEC=1 ./test-migrations-pull-secrets.sh      # preview phase only
#   KEEP=1 ./test-migrations-pull-secrets.sh           # leave everything running
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE       namespace for the targets (default test-mirrord)
#   READY_TIMEOUT   seconds for a branch to reach Ready (default 300)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-test-mirrord}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
SKIP_PREVIEW="${SKIP_PREVIEW:-0}"
SKIP_EXEC="${SKIP_EXEC:-0}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"

LOCAL_MIRRORD="$SCRIPT_DIR/../../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/migrations-pull-secrets.XXXXXX)"
# Per-run tag so a stale branch/pod from an earlier run cannot satisfy this
# run's checks.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"

TARGET_POD="pg-pullsecret-target-$RUN_TAG"
TARGET_DEPLOY="pg-pullsecret-preview-$RUN_TAG"
PULL_SECRET="target-pull-secret-$RUN_TAG"
EXEC_BRANCH_ID="pg-migrations-pullsecret-$RUN_TAG"
PREVIEW_BRANCH_ID="pg-migrations-pullsecret-pv-$RUN_TAG"
PREVIEW_KEY="pullsec-$RUN_TAG"
SESSION_PID=""
PREVIEW_PID=""

# ---------------------------------------------------------------------------
# Output helpers - gum when installed, plain ANSI otherwise
# ---------------------------------------------------------------------------
HAVE_GUM=0
command -v gum >/dev/null 2>&1 && HAVE_GUM=1

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
check() { # check <description> <0-ok/1-bad>
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

cleanup() {
  [ -n "$SESSION_PID" ] && kill "$SESSION_PID" >/dev/null 2>&1
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1 - leaving the branches, targets, preview, and secret in place"
    warn "  branch ids: $EXEC_BRANCH_ID $PREVIEW_BRANCH_ID"
    warn "  stop the preview with: $MIRRORD_BIN preview stop -k $PREVIEW_KEY"
    return
  fi
  "$MIRRORD_BIN" preview stop -k "$PREVIEW_KEY" >/dev/null 2>&1 || true
  local id name
  for id in "$EXEC_BRANCH_ID" "$PREVIEW_BRANCH_ID"; do
    name="$(branch_name_by_id "$id")"
    [ -n "$name" ] && kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" "$name" \
      --ignore-not-found >/dev/null 2>&1
  done
  kubectl delete -n "$NAMESPACE" "pod/$TARGET_POD" "deploy/$TARGET_DEPLOY" \
    "secret/$PULL_SECRET" --ignore-not-found >/dev/null 2>&1 || true
  info "cleaned up branches, targets, preview session, and pull secret"
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

# Waits for the branch's migration Job and asserts its pod template carries the
# target's pull secret.
assert_job_secrets() { # <branch-name> <phase-label>
  local branch="$1" label="$2" uid job="" phase waited=0
  uid="$(branch_field "$branch" '{.metadata.uid}')"

  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    job="$(kubectl get jobs -n "$NAMESPACE" -o name 2>/dev/null \
      | grep "mirrord-migrations-$uid" | head -1)"
    [ -n "$job" ] && break
    phase="$(branch_field "$branch" '{.status.phase}')"
    if [ "$phase" = "Failed" ]; then
      fail "branch Failed before the migration job was created: $(branch_field "$branch" '{.status.error}')"
      return 1
    fi
    sleep 3; waited=$((waited + 3))
  done
  if [ -z "$job" ]; then
    fail "migration job never appeared (branch phase: $(branch_field "$branch" '{.status.phase}'))"
    return 1
  fi
  info "migration job: $job"

  local secrets
  secrets="$(kubectl get -n "$NAMESPACE" "$job" \
    -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}')"
  info "job imagePullSecrets: [${secrets:-<none>}]"
  if printf '%s' "$secrets" | grep -qw "$PULL_SECRET"; then
    check "$label: migration Job inherits the target's pull secret" 0
  else
    check "$label: migration Job inherits the target's pull secret" 1
    warn "an operator WITHOUT the fix leaves the target's secrets off the Job -"
    warn "rebuild + redeploy the operator (or run task operator:dev) and rerun"
  fi
}

# Waits for Ready branch + Succeeded migration, failing fast on Failed.
assert_branch_ready() { # <branch-name> <phase-label>
  local branch="$1" label="$2" phase mig waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    phase="$(branch_field "$branch" '{.status.phase}')"
    mig="$(branch_field "$branch" '{.status.migrations.phase}')"
    if [ "$phase" = "Failed" ] || [ "$mig" = "Failed" ]; then
      fail "branch phase=$phase migrations=$mig - error: $(branch_field "$branch" '{.status.error}')"
      return 1
    fi
    [ "$phase" = "Ready" ] && [ "$mig" = "Succeeded" ] && break
    sleep 5; waited=$((waited + 5))
  done

  if [ "$(branch_field "$branch" '{.status.phase}')" = "Ready" ] \
     && [ "$(branch_field "$branch" '{.status.migrations.phase}')" = "Succeeded" ]; then
    check "$label: branch Ready with Succeeded migration (inert secret broke nothing)" 0
  else
    check "$label: branch Ready with Succeeded migration (inert secret broke nothing)" 1
    warn "branch phase: $(branch_field "$branch" '{.status.phase}'), migrations: $(branch_field "$branch" '{.status.migrations.phase}')"
  fi
}

# The container-flavor migrations block, shared by both phases' configs.
migrations_block() { # <branch-id>
  cat <<EOF
      {
        "id": "$1",
        "name": "pullsecret_branch",
        "type": "pg",
        "version": "17",
        "ttl_secs": 300,
        "creation_timeout_secs": 180,
        "connection": { "url": "DATABASE_URL" },
        "copy": { "mode": "empty" },
        "migrations": {
          "flavor": "container",
          "image": "postgres:17",
          "command": [
            "sh", "-c",
            "psql -c 'CREATE TABLE IF NOT EXISTS pull_secret_migrated (id INT)'"
          ],
          "env": {
            "PGHOST": "\$(MIRRORD_DB_HOST)",
            "PGPORT": "\$(MIRRORD_DB_PORT)",
            "PGUSER": "\$(MIRRORD_DB_USER)",
            "PGPASSWORD": "\$(MIRRORD_DB_PASSWORD)",
            "PGDATABASE": "\$(MIRRORD_DB_NAME)"
          }
        }
      }
EOF
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Migration Job pull secrets - preflight"

command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq not found"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not usable: $MIRRORD_BIN"; exit 1; }
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "workdir: $WORKDIR (mirrord configs + session logs live here)"

# Sessions labeled with an isolation marker are reconciled by a locally
# running operator:dev instead of the deployed one - same convention as the
# migrations:* tasks.
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
fi

# ---------------------------------------------------------------------------
# Deploy: source DB, fake pull secret, targets carrying it
# ---------------------------------------------------------------------------
header "Deploy source DB + targets with imagePullSecrets"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -k "$ROOT_DIR/k8s/postgres" >/dev/null
kubectl wait --for=condition=ready pod postgres-test -n "$NAMESPACE" --timeout=180s >/dev/null \
  || { fail "postgres-test source pod not ready"; exit 1; }
info "source DB ready (postgres-test)"

# registry.example.com never matches busybox/postgres, so kubelet ignores the
# bogus credentials for every pull this test performs.
kubectl create secret docker-registry "$PULL_SECRET" -n "$NAMESPACE" \
  --docker-server=registry.example.com \
  --docker-username=fake --docker-password=fake \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
info "fake pull secret created ($PULL_SECRET -> registry.example.com)"

if [ "$SKIP_EXEC" != 1 ]; then
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $TARGET_POD
  namespace: $NAMESPACE
  labels:
    test-scenario: migrations-pull-secrets
spec:
  imagePullSecrets:
  - name: $PULL_SECRET
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'pull-secret scenario target running' && sleep 3600"]
    env:
    - name: DATABASE_URL
      value: "postgresql://postgres:postgres@postgres-test:5432/source_db"
EOF
  kubectl wait --for=condition=ready "pod/$TARGET_POD" -n "$NAMESPACE" --timeout=120s >/dev/null \
    || { fail "target pod not ready"; exit 1; }
  info "exec target ready (pod/$TARGET_POD, imagePullSecrets=[$PULL_SECRET])"
fi

if [ "$SKIP_PREVIEW" != 1 ]; then
  kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TARGET_DEPLOY
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $TARGET_DEPLOY
  template:
    metadata:
      labels:
        app: $TARGET_DEPLOY
        test-scenario: migrations-pull-secrets
    spec:
      imagePullSecrets:
      - name: $PULL_SECRET
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "echo 'pull-secret preview target running' && sleep 3600"]
        env:
        - name: DATABASE_URL
          value: "postgresql://postgres:postgres@postgres-test:5432/source_db"
EOF
  kubectl wait --for=condition=available "deploy/$TARGET_DEPLOY" -n "$NAMESPACE" --timeout=120s >/dev/null \
    || { fail "preview target deployment not ready"; exit 1; }
  info "preview target ready (deploy/$TARGET_DEPLOY, imagePullSecrets=[$PULL_SECRET])"
fi

# ---------------------------------------------------------------------------
# Phase 1 - EXEC: plain mirrord session against the pod target
# ---------------------------------------------------------------------------
if [ "$SKIP_EXEC" != 1 ]; then
  header "Phase 1 (exec): session + Job pull-secret checks"

  EXEC_CONFIG="$WORKDIR/mirrord-exec.json"
  cat > "$EXEC_CONFIG" <<EOF
{
  "operator": true,
  "target": {
    "path": { "pod": "$TARGET_POD" },
    "namespace": "$NAMESPACE"
  },
  "feature": {
    "env": true,
    "fs": "local",
    "network": { "incoming": "off", "outgoing": true },
    "db_branches": [
$(migrations_block "$EXEC_BRANCH_ID")
    ]
  }
}
EOF

  SESSION_LOG="$WORKDIR/exec-session.log"
  "$MIRRORD_BIN" exec -f "$EXEC_CONFIG" -- sh -c 'echo "SESSION READY"; sleep 240' \
    > "$SESSION_LOG" 2>&1 &
  SESSION_PID=$!
  # Detached so the cleanup kill does not print a job-control "Terminated" line.
  disown "$SESSION_PID" 2>/dev/null || true
  info "exec session starting in the background (pid $SESSION_PID)"
  info "follow it with: tail -f $SESSION_LOG"

  if BRANCH="$(wait_branch "$EXEC_BRANCH_ID" "$SESSION_PID" "$SESSION_LOG")"; then
    info "branch CRD: $BRANCH"
    assert_job_secrets "$BRANCH" "exec" \
      && assert_branch_ready "$BRANCH" "exec"
  else
    FAILURES=$((FAILURES + 1))
  fi

  # The exec session has served its purpose; end it so the preview phase
  # starts from a quiet cluster.
  kill "$SESSION_PID" >/dev/null 2>&1
  SESSION_PID=""
fi

# ---------------------------------------------------------------------------
# Phase 2 - PREVIEW: preview environment against the deployment target
# (the Teladoc shape: feature.preview + db_branches in one config)
# ---------------------------------------------------------------------------
if [ "$SKIP_PREVIEW" != 1 ]; then
  header "Phase 2 (preview): preview env + Job pull-secret checks"

  PREVIEW_CONFIG="$WORKDIR/mirrord-preview.json"
  cat > "$PREVIEW_CONFIG" <<EOF
{
  "target": {
    "path": "deploy/$TARGET_DEPLOY",
    "namespace": "$NAMESPACE"
  },
  "feature": {
    "preview": {
      "ttl_mins": 10,
      "creation_timeout_secs": 300
    },
    "network": {
      "incoming": {
        "mode": "steal",
        "http_filter": {
          "header_filter": "X-Preview: $PREVIEW_KEY"
        }
      }
    },
    "db_branches": [
$(migrations_block "$PREVIEW_BRANCH_ID")
    ]
  }
}
EOF

  PREVIEW_LOG="$WORKDIR/preview-start.log"
  # The preview pod copies the target's pod spec (command included), only the
  # image is swapped in - busybox runs the target's sleep command fine.
  "$MIRRORD_BIN" preview start -f "$PREVIEW_CONFIG" -k "$PREVIEW_KEY" -i busybox --timeout 300 \
    > "$PREVIEW_LOG" 2>&1 &
  PREVIEW_PID=$!
  disown "$PREVIEW_PID" 2>/dev/null || true
  info "preview starting in the background (pid $PREVIEW_PID, key $PREVIEW_KEY)"
  info "follow it with: tail -f $PREVIEW_LOG"

  if BRANCH="$(wait_branch "$PREVIEW_BRANCH_ID" "$PREVIEW_PID" "$PREVIEW_LOG")"; then
    info "branch CRD: $BRANCH"
    assert_job_secrets "$BRANCH" "preview" \
      && assert_branch_ready "$BRANCH" "preview"
  else
    FAILURES=$((FAILURES + 1))
  fi

  # `preview start --timeout` exits on its own once the session is Ready (or
  # failed); let it finish, then stop the session so cleanup is deterministic.
  waited=0
  while kill -0 "$PREVIEW_PID" 2>/dev/null && [ "$waited" -lt 120 ]; do
    sleep 3; waited=$((waited + 3))
  done
  kill "$PREVIEW_PID" >/dev/null 2>&1
  "$MIRRORD_BIN" preview stop -k "$PREVIEW_KEY" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"
if [ "$FAILURES" = 0 ]; then
  pass "all checks passed"
else
  fail "$FAILURES check(s) failed"
fi
exit "$FAILURES"
