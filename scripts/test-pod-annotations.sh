#!/usr/bin/env bash
#
# End-to-end test: admin labels and annotations land on the pods DB branching and
# preview environments create (INT-815, the Karpenter `do-not-disrupt` case: Karpenter
# consolidates an underutilized node and deletes the branch or preview pod mid-session
# unless the pod carries `karpenter.sh/do-not-disrupt: "true"`).
#
# Cases, each PASS/FAIL:
#   1. BRANCH:  a `mirrord exec` session with a pg branch and a container-flavor migration.
#               The branch database pod AND the migration Job's pod template carry the
#               `dbPod.labels` / `dbPod.annotations` from configs/pg-branch-config.yaml,
#               and the branch still reaches Ready with a Succeeded migration.
#   2. PREVIEW: a `mirrord preview start` session against deploy/echo-app. Every preview
#               pod carries the labels / annotations from configs/preview-config.yaml on
#               top of the target template's own `app` label.
#
# Prerequisites:
#   - minikube (bearkube) running, `task migrations:deploy` (postgres-test source) and
#     `task preview:deploy` (echo-app target) applied
#   - `task operator:crds`, then `task operator:dev` from the INT-815 branch - restarted
#     after .mirrord/operator-dev.yaml gained OPERATOR_PREVIEW_CONFIG (read at start only)
#   - a released operator covers everything but the migration Job pods: case 1's Job
#     check FAILS there by design, that is the behavior INT-815 adds
#
# Usage:
#   ./test-pod-annotations.sh
#   SKIP_PREVIEW=1 ./test-pod-annotations.sh    # branch case only
#   SKIP_BRANCH=1 ./test-pod-annotations.sh     # preview case only
#   KEEP=1 ./test-pod-annotations.sh            # leave the session resources in place
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE       namespace for the targets (default test-mirrord)
#   READY_TIMEOUT   seconds for a branch or preview to come up (default 300)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-test-mirrord}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
SKIP_PREVIEW="${SKIP_PREVIEW:-0}"
SKIP_BRANCH="${SKIP_BRANCH:-0}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"
PG_CONFIG="$ROOT_DIR/configs/pg-branch-config.yaml"
PREVIEW_CONFIG_FILE="$ROOT_DIR/configs/preview-config.yaml"

# The admin metadata both config files set; the preflight checks the files still carry
# it, so a config edit cannot silently turn the asserts into no-ops.
ANNOTATION_KEY="karpenter.sh/do-not-disrupt"
ANNOTATION_VALUE="true"
LABEL_KEY="sandbox.mirrord.metalbear.co/admin-pod-metadata"
BRANCH_LABEL_VALUE="db-branch"
PREVIEW_LABEL_VALUE="preview"
# Labels the operator stamps: the branch's current database pod, and every preview pod.
BRANCH_OWNER_LABEL="db-owner-name"
PREVIEW_UID_LABEL="preview.metalbear.co/session-uid"

LOCAL_MIRRORD=""
for candidate in "$ROOT_DIR/../mirrord/target/debug/mirrord" \
                 "$ROOT_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"; do
  [ -x "$candidate" ] && { LOCAL_MIRRORD="$candidate"; break; }
done
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -n "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/pod-annotations.XXXXXX)"
# Per-run tag so a stale branch or pod from an earlier run cannot satisfy this run's checks.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"

TARGET_POD="pg-podmeta-target-$RUN_TAG"
BRANCH_ID="pg-podmeta-$RUN_TAG"
PREVIEW_KEY="podmeta-$RUN_TAG"
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
RESULTS=()
check() { # check <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then pass "$1"; RESULTS+=("PASS  $1"); else fail "$1"; RESULTS+=("FAIL  $1"); FAILURES=$((FAILURES + 1)); fi
}

branch_name_by_id() { # <branch-id>
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg id "$1" '.items[] | select(.spec.id == $id) | .metadata.name' | head -1
}

branch_field() { # <branch-name> <jsonpath>
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" "$1" -o jsonpath="$2" 2>/dev/null
}

cleanup() {
  [ -n "$SESSION_PID" ] && kill "$SESSION_PID" >/dev/null 2>&1
  [ -n "$PREVIEW_PID" ] && kill "$PREVIEW_PID" >/dev/null 2>&1
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1 - leaving the branch, target pod, and preview in place"
    warn "  branch id: $BRANCH_ID   stop the preview with: $MIRRORD_BIN preview stop -k $PREVIEW_KEY"
    return
  fi
  "$MIRRORD_BIN" preview stop -k "$PREVIEW_KEY" >/dev/null 2>&1 || true
  local name
  name="$(branch_name_by_id "$BRANCH_ID")"
  [ -n "$name" ] && kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" "$name" --ignore-not-found >/dev/null 2>&1
  kubectl delete -n "$NAMESPACE" "pod/$TARGET_POD" --ignore-not-found >/dev/null 2>&1 || true
  info "cleaned up the branch, target pod, and preview session"
}
trap cleanup EXIT

# Asserts that the object's metadata (a JSON document on stdin) carries the admin label
# and annotation; prints what it found so a FAIL is its own diagnosis.
assert_metadata() { # <description> <label-value>   (metadata JSON on stdin)
  local what="$1" label_value="$2" meta label annotation
  meta="$(cat)"
  label="$(printf '%s' "$meta" | jq -r --arg k "$LABEL_KEY" '.labels[$k] // ""')"
  annotation="$(printf '%s' "$meta" | jq -r --arg k "$ANNOTATION_KEY" '.annotations[$k] // ""')"
  info "$what: $LABEL_KEY=${label:-<missing>} $ANNOTATION_KEY=${annotation:-<missing>}"
  if [ "$label" = "$label_value" ] && [ "$annotation" = "$ANNOTATION_VALUE" ]; then
    check "$what carries the admin label and annotation" 0
  else
    check "$what carries the admin label and annotation" 1
  fi
}

# Waits for the branch CRD with the given id; fails the run if the watched process dies
# first (its log tail is the diagnosis).
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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Pod labels and annotations - preflight"

command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq not found"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not usable: $MIRRORD_BIN (build it with: task mirrord:cli:build)"; exit 1; }
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "workdir: $WORKDIR (mirrord configs + session logs live here)"

grep -q "$ANNOTATION_KEY" "$PG_CONFIG" \
  || { fail "$PG_CONFIG no longer sets $ANNOTATION_KEY under dbPod.annotations"; exit 1; }
grep -q "$ANNOTATION_KEY" "$PREVIEW_CONFIG_FILE" \
  || { fail "$PREVIEW_CONFIG_FILE no longer sets $ANNOTATION_KEY under annotations"; exit 1; }
kubectl get crd "$BRANCH_CRD" >/dev/null 2>&1 \
  || { fail "CRD $BRANCH_CRD missing - run: task operator:crds"; exit 1; }

if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
else
  warn "no operator:dev process found - the DEPLOYED operator reconciles these sessions;"
  warn "it reads the chart's configmap, not configs/*.yaml, and a released one skips the Job pods"
fi

if [ "$SKIP_BRANCH" != 1 ]; then
  kubectl get pod postgres-test -n "$NAMESPACE" >/dev/null 2>&1 \
    || { fail "postgres-test source pod missing - run: task migrations:deploy"; exit 1; }
fi
if [ "$SKIP_PREVIEW" != 1 ]; then
  kubectl get deploy echo-app -n "$NAMESPACE" >/dev/null 2>&1 \
    || { fail "echo-app target missing - run: task preview:deploy"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Case 1 - BRANCH: database pod + migration Job pod template
# ---------------------------------------------------------------------------
if [ "$SKIP_BRANCH" != 1 ]; then
  header "Case 1 (branch): database pod + migration Job carry dbPod labels/annotations"

  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $TARGET_POD
  namespace: $NAMESPACE
  labels:
    test-scenario: pod-annotations
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'pod-annotations scenario target running' && sleep 3600"]
    env:
    - name: DATABASE_URL
      value: "postgresql://postgres:postgres@postgres-test:5432/source_db"
EOF
  kubectl wait --for=condition=ready "pod/$TARGET_POD" -n "$NAMESPACE" --timeout=120s >/dev/null \
    || { fail "target pod not ready"; exit 1; }
  info "exec target ready (pod/$TARGET_POD)"

  EXEC_CONFIG="$WORKDIR/mirrord-exec.json"
  cat > "$EXEC_CONFIG" <<EOF
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
        "name": "podmeta_branch",
        "type": "pg",
        "version": "17",
        "ttl_secs": 300,
        "creation_timeout_secs": 180,
        "connection": { "url": "DATABASE_URL" },
        "copy": { "mode": "empty" },
        "migrations": {
          "flavor": "container",
          "image": "postgres:17",
          "command": ["sh", "-c", "psql -c 'CREATE TABLE IF NOT EXISTS pod_metadata_migrated (id INT)'"],
          "env": {
            "PGHOST": "\$(MIRRORD_DB_HOST)",
            "PGPORT": "\$(MIRRORD_DB_PORT)",
            "PGUSER": "\$(MIRRORD_DB_USER)",
            "PGPASSWORD": "\$(MIRRORD_DB_PASSWORD)",
            "PGDATABASE": "\$(MIRRORD_DB_NAME)"
          }
        }
      }
    ]
  }
}
EOF

  SESSION_LOG="$WORKDIR/exec-session.log"
  "$MIRRORD_BIN" exec -f "$EXEC_CONFIG" -- sh -c 'echo "SESSION READY"; sleep 240' \
    > "$SESSION_LOG" 2>&1 &
  SESSION_PID=$!
  disown "$SESSION_PID" 2>/dev/null || true
  info "exec session starting in the background (pid $SESSION_PID)"
  info "follow it with: tail -f $SESSION_LOG"

  if BRANCH="$(wait_branch "$BRANCH_ID" "$SESSION_PID" "$SESSION_LOG")"; then
    info "branch CRD: $BRANCH"

    # The database pod exists before it is ready; its metadata is set at creation.
    waited=0; db_pod=""
    while [ "$waited" -lt "$READY_TIMEOUT" ]; do
      db_pod="$(kubectl get pods -n "$NAMESPACE" -l "$BRANCH_OWNER_LABEL=$BRANCH" -o name 2>/dev/null | head -1)"
      [ -n "$db_pod" ] && break
      sleep 3; waited=$((waited + 3))
    done
    if [ -n "$db_pod" ]; then
      info "branch database pod: $db_pod"
      kubectl get -n "$NAMESPACE" "$db_pod" -o json | jq '.metadata' \
        | assert_metadata "branch database pod" "$BRANCH_LABEL_VALUE"
    else
      check "branch database pod exists" 1
    fi

    # The migration Job is named mirrord-migrations-<branch uid>-<generation>; its pod
    # template is what every attempt's pod is stamped from.
    uid="$(branch_field "$BRANCH" '{.metadata.uid}')"
    waited=0; job=""
    while [ "$waited" -lt "$READY_TIMEOUT" ]; do
      job="$(kubectl get jobs -n "$NAMESPACE" -o name 2>/dev/null | grep "mirrord-migrations-$uid" | head -1)"
      [ -n "$job" ] && break
      [ "$(branch_field "$BRANCH" '{.status.phase}')" = "Failed" ] && break
      sleep 3; waited=$((waited + 3))
    done
    if [ -n "$job" ]; then
      info "migration job: $job"
      kubectl get -n "$NAMESPACE" "$job" -o json | jq '.spec.template.metadata // {}' \
        | assert_metadata "migration Job pod template" "$BRANCH_LABEL_VALUE"
    else
      check "migration Job exists" 1
      warn "branch phase: $(branch_field "$BRANCH" '{.status.phase}') error: $(branch_field "$BRANCH" '{.status.error}')"
    fi

    # The metadata must not get in the way: Ready branch + Succeeded migration.
    waited=0
    while [ "$waited" -lt "$READY_TIMEOUT" ]; do
      phase="$(branch_field "$BRANCH" '{.status.phase}')"
      mig="$(branch_field "$BRANCH" '{.status.migrations.phase}')"
      { [ "$phase" = "Failed" ] || [ "$mig" = "Failed" ]; } && break
      [ "$phase" = "Ready" ] && [ "$mig" = "Succeeded" ] && break
      sleep 5; waited=$((waited + 5))
    done
    if [ "$(branch_field "$BRANCH" '{.status.phase}')" = "Ready" ] \
       && [ "$(branch_field "$BRANCH" '{.status.migrations.phase}')" = "Succeeded" ]; then
      check "branch Ready with Succeeded migration" 0
    else
      check "branch Ready with Succeeded migration" 1
      warn "branch phase: $(branch_field "$BRANCH" '{.status.phase}'), migrations: $(branch_field "$BRANCH" '{.status.migrations.phase}'), error: $(branch_field "$BRANCH" '{.status.error}')"
    fi
  else
    FAILURES=$((FAILURES + 1)); RESULTS+=("FAIL  branch CRD appeared")
  fi

  kill "$SESSION_PID" >/dev/null 2>&1
  SESSION_PID=""
fi

# ---------------------------------------------------------------------------
# Case 2 - PREVIEW: every preview pod
# ---------------------------------------------------------------------------
if [ "$SKIP_PREVIEW" != 1 ]; then
  header "Case 2 (preview): preview pods carry operator.preview labels/annotations"

  PREVIEW_CONFIG="$WORKDIR/mirrord-preview.json"
  cat > "$PREVIEW_CONFIG" <<EOF
{
  "target": { "path": "deploy/echo-app", "namespace": "$NAMESPACE" },
  "feature": {
    "preview": { "ttl_mins": 10, "creation_timeout_secs": 300 },
    "network": {
      "incoming": {
        "mode": "steal",
        "ports": [8080],
        "http_filter": { "header_filter": "X-Preview: $PREVIEW_KEY" }
      }
    }
  }
}
EOF

  PREVIEW_LOG="$WORKDIR/preview-start.log"
  "$MIRRORD_BIN" preview start -f "$PREVIEW_CONFIG" -k "$PREVIEW_KEY" -i echo-app:latest --timeout 300 \
    > "$PREVIEW_LOG" 2>&1 &
  PREVIEW_PID=$!
  disown "$PREVIEW_PID" 2>/dev/null || true
  info "preview starting in the background (pid $PREVIEW_PID, key $PREVIEW_KEY)"
  info "follow it with: tail -f $PREVIEW_LOG"

  # `preview start --timeout` exits on its own once the session is Ready or failed.
  waited=0
  while kill -0 "$PREVIEW_PID" 2>/dev/null && [ "$waited" -lt "$READY_TIMEOUT" ]; do
    sleep 3; waited=$((waited + 3))
  done
  if kill -0 "$PREVIEW_PID" 2>/dev/null; then
    check "preview start finished within ${READY_TIMEOUT}s" 1
    tail -10 "$PREVIEW_LOG"
  elif grep -qi "error\|failed" "$PREVIEW_LOG" && ! grep -qi "ready" "$PREVIEW_LOG"; then
    check "preview start succeeded" 1
    tail -10 "$PREVIEW_LOG"
  else
    PREVIEW_PID=""
    pods_json="$(kubectl get pods -n "$NAMESPACE" -l "$PREVIEW_UID_LABEL" -o json 2>/dev/null)"
    # Only this run's preview: echo-app is the sole target here, and older sessions were
    # stopped by their own runs, but filter on the key-derived name defensively.
    count="$(printf '%s' "$pods_json" | jq '[.items[] | select(.metadata.name | test("'"$PREVIEW_KEY"'|echo-app"))] | length')"
    if [ "${count:-0}" -ge 1 ]; then
      info "preview pods: $count"
      printf '%s' "$pods_json" | jq -c '.items[] | select(.metadata.name | test("'"$PREVIEW_KEY"'|echo-app")) | .metadata' \
        | while IFS= read -r meta; do
            name="$(printf '%s' "$meta" | jq -r '.name')"
            printf '%s' "$meta" | assert_metadata "preview pod $name" "$PREVIEW_LABEL_VALUE"
            app="$(printf '%s' "$meta" | jq -r '.labels.app // ""')"
            [ "$app" = "echo-app" ] && check "preview pod $name keeps the template's app label" 0 \
              || check "preview pod $name keeps the template's app label" 1
          done
      # The while loop runs in a subshell; recount failures from the pods directly.
      bad="$(printf '%s' "$pods_json" | jq --arg lk "$LABEL_KEY" --arg lv "$PREVIEW_LABEL_VALUE" \
        --arg ak "$ANNOTATION_KEY" --arg av "$ANNOTATION_VALUE" \
        '[.items[] | select((.metadata.labels[$lk] != $lv) or (.metadata.annotations[$ak] != $av) or (.metadata.labels.app != "echo-app"))] | length')"
      [ "${bad:-1}" = 0 ] && check "all preview pods carry the admin metadata" 0 \
        || check "all preview pods carry the admin metadata" 1
    else
      check "preview pods exist" 1
    fi
  fi

  "$MIRRORD_BIN" preview stop -k "$PREVIEW_KEY" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"
for line in "${RESULTS[@]}"; do printf '  %s\n' "$line"; done
if [ "$FAILURES" = 0 ]; then
  pass "all checks passed"
else
  fail "$FAILURES check(s) failed"
fi
exit "$FAILURES"
