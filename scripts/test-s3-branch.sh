#!/usr/bin/env bash
#
# End-to-end test: S3 bucket branching against LocalStack (no real AWS account
# needed).
#
# Customer setup being simulated: the app reads the name of its S3 bucket from
# an env var (TEST_BUCKET). A mirrord session with a `type: "s3"` db branch
# makes the operator clone that bucket in the customer's account (here:
# LocalStack) and point the same env var at the clone, so the app reads and
# writes the branch bucket with no code change. Unlike the pod-backed engines
# there is no branch pod - the operator does the cloning itself with its own
# AWS env (chart `extraEnv` in this sandbox; IRSA on a real cluster).
#
# Scenarios:
#
#   copy     `copy: { mode: "all", objects: ["^fixtures/"] }` - the branch
#            bucket carries exactly the matching objects, clones the source's
#            settings (versioning, tags), the bucket is tracked in a
#            MirrordClusterExternalResource, and the session's TEST_BUCKET is
#            rewritten to the branch bucket.
#   empty    `copy: { mode: "empty" }` - branch bucket exists with no objects.
#   failure  the `bucket` param names a bucket that does not exist - the
#            branch goes Failed with an error naming the source bucket, and
#            nothing is created or recorded.
#
# After the scenarios, killing the sessions must take everything away again:
# the operator closes the dead session (unused TTL), the BranchDatabase CRDs
# expire by their own TTL, then the bucket records (DynamicOwner GC tick) and
# the branch buckets themselves. operator-dev.yaml shortens both operator
# timers for this loop.
#
# Prerequisites:
#   - minikube (bearkube) running, operator deployed with the sandbox values
#     (operator-values.yaml sets `s3Branching: true` and the LocalStack AWS
#     env). For a local operator use `task operator:dev`; the script labels
#     its sessions for it, like the postgres:* tasks do.
#
# Usage:
#   scripts/test-s3-branch.sh            # all scenarios
#   scripts/test-s3-branch.sh copy       # only the copy scenario
#   scripts/test-s3-branch.sh empty
#   scripts/test-s3-branch.sh failure
#   task s3:test                         # all scenarios
#   KEEP=1 scripts/test-s3-branch.sh     # leave branches, buckets and target
#
# Env knobs (all optional):
#   MIRRORD_BIN      mirrord CLI to use (default: local debug build, then PATH)
#   READY_TIMEOUT    seconds for a branch to reach Ready/Failed (default 300)
#   CLEANUP_TIMEOUT  seconds for the post-kill cleanup chain (default 360)
#   CLUSTER_NAME     minikube profile (default bearkube)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="test-mirrord"
LOCALSTACK_NS="localstack"
LOCALSTACK_OVERLAY="$ROOT_DIR/k8s/overlays/sqs-localstack"
CLUSTER_NAME="${CLUSTER_NAME:-bearkube}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
CLEANUP_TIMEOUT="${CLEANUP_TIMEOUT:-360}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"
RECORD_CRD="mirrordclusterexternalresources.mirrord.metalbear.co"
BUCKET_ANNOTATION="operator.metalbear.co/s3-branch-bucket"

# Must match the region in the operator's env (operator-values.yaml) and the
# LocalStack deployment - S3 rejects bucket operations sent to another
# region's endpoint, and the branch bucket follows its source's region.
REGION="eu-north-1"
TARGET="s3-app"
BUCKET_ENV_VAR="TEST_BUCKET"
# Short TTL so the cleanup chain is observable within the script's run.
# Expiry is a precise requeue in the operator, so this can go low safely.
TTL_SECS=20

ONLY_CASE="${1:-all}"
case "$ONLY_CASE" in all|copy|empty|failure) ;; *)
  printf 'usage: %s [copy|empty|failure]\n' "$0"; exit 2 ;;
esac

LOCAL_MIRRORD="$SCRIPT_DIR/../../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/s3-branch.XXXXXX)"
# Per-run tag so a stale branch or bucket from an earlier run cannot satisfy
# this run's checks.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"

SOURCE_BUCKET="mirrord-s3-src-$RUN_TAG"
COPY_BRANCH_ID="s3-copy-$RUN_TAG"
EMPTY_BRANCH_ID="s3-empty-$RUN_TAG"
FAIL_BRANCH_ID="s3-fail-$RUN_TAG"
SESSION_PID=""
# Branch CRD names and branch buckets created by the scenarios, verified gone
# in the cleanup phase and swept by the exit trap.
CREATED_BRANCH_IDS=()
CREATED_BUCKETS=()

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

# ---------------------------------------------------------------------------
# kubectl / LocalStack helpers
# ---------------------------------------------------------------------------
awslocal() { # aws cli inside the LocalStack pod, region preset by its env
  kubectl exec -n "$LOCALSTACK_NS" deploy/localstack -- awslocal "$@"
}

branch_name_by_id() { # <branch-id>
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg id "$1" \
        '.items[] | select(.spec.id == $id) | .metadata.name' | head -1
}

branch_json() { # <branch-name> <jq-filter>
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" "$1" -o json 2>/dev/null | jq -r "$2"
}

branch_bucket() { # <branch-name>  -> annotation value or empty
  branch_json "$1" ".metadata.annotations[\"$BUCKET_ANNOTATION\"] // empty"
}

bucket_exists() { # <bucket>
  awslocal s3api head-bucket --bucket "$1" >/dev/null 2>&1
}

bucket_keys() { # <bucket>  -> sorted object keys, one per line
  awslocal s3api list-objects-v2 --bucket "$1" --output json 2>/dev/null \
    | jq -r '.Contents // [] | .[].Key' | sort
}

# Kill a pid and all its descendants, children first. Killing only the
# mirrord process leaves the `sh -c "...; sleep 300"` workload and the
# intproxy alive, so the operator keeps the session (and the branch) open
# until the sleep runs out - minutes of extra cleanup wait.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child"; done
  kill "$1" >/dev/null 2>&1
}

kill_session() {
  [ -n "$SESSION_PID" ] && kill_tree "$SESSION_PID"
  SESSION_PID=""
}

cleanup() {
  kill_session
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1 - leaving the branches, buckets and target in place"
    warn "  branch ids: ${CREATED_BRANCH_IDS[*]:-none}, source bucket: $SOURCE_BUCKET"
    warn "  remove with: task s3:clean"
    return
  fi
  local id name bucket
  for id in "${CREATED_BRANCH_IDS[@]:-}"; do
    [ -n "$id" ] || continue
    name="$(branch_name_by_id "$id")"
    [ -n "$name" ] && kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" "$name" \
      --ignore-not-found >/dev/null 2>&1
  done
  kubectl delete "deploy/$TARGET" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  # Sweep whatever buckets the operator's own cleanup did not get to (a
  # versioned bucket needs its versions deleted before rb).
  for bucket in "$SOURCE_BUCKET" "${CREATED_BUCKETS[@]:-}"; do
    [ -n "$bucket" ] || continue
    bucket_exists "$bucket" || continue
    awslocal s3api delete-objects --bucket "$bucket" --delete \
      "$(awslocal s3api list-object-versions --bucket "$bucket" --output json 2>/dev/null \
        | jq -c '{Objects: ([.Versions // [], .DeleteMarkers // []] | add
                            | map({Key: .Key, VersionId: .VersionId}))}' )" \
      >/dev/null 2>&1
    awslocal s3 rb "s3://$bucket" >/dev/null 2>&1
  done
  info "cleaned up branches, target, session and test buckets (LocalStack stays)"
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
  fail "branch CRD (id=$1) never appeared - is an operator with s3Branching watching? See $3" >&2
  return 1
}

wait_branch_phase() { # <branch-name> <wanted-phase>  -> 0 when reached
  local phase="" waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    phase="$(branch_json "$1" '.status.phase // empty')"
    [ "$phase" = "$2" ] && return 0
    case "$phase" in Ready|Failed) return 1 ;; esac
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

launch_session() { # <mirrord-config> <log>
  # The marker line proves what the app actually sees: mirrord waits for the
  # branch, applies the env override, then runs the command.
  "$MIRRORD_BIN" exec -f "$1" -- \
    sh -c "echo \"SESSION_ENV $BUCKET_ENV_VAR=\$$BUCKET_ENV_VAR\"; sleep 300" \
    > "$2" 2>&1 &
  SESSION_PID=$!
  disown "$SESSION_PID" 2>/dev/null || true
  info "session starting in the background (pid $SESSION_PID)"
  info "follow it with: tail -f $2"
}

session_bucket_env() { # <log>  -> value the session saw, or empty
  local waited=0 value=""
  while [ "$waited" -lt 60 ]; do
    value="$(sed -n "s/^SESSION_ENV $BUCKET_ENV_VAR=//p" "$1" | head -1)"
    [ -n "$value" ] && { printf '%s' "$value"; return 0; }
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

record_name() { # <branch-name>  -> bucket record's cluster-scoped name
  printf 's3-branch-bucket.%s' "$(branch_json "$1" '.metadata.uid')"
}

mirrord_config() { # <branch-id> <copy-json> [<bucket-param-json>]
  local bucket_param="${3:-\"$BUCKET_ENV_VAR\"}"
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
        "type": "s3",
        "provider": "AWS",
        "ttl_secs": $TTL_SECS,
        "creation_timeout_secs": 180,
        "source": { "params": { "bucket": $bucket_param } },
        "copy": $2
      }
    ]
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "S3 bucket branching e2e - preflight"

command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq not found"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not usable: $MIRRORD_BIN"; exit 1; }
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "workdir: $WORKDIR (mirrord configs + session logs live here)"
[ "$HAVE_GUM" = 1 ] || warn "gum not installed (brew install gum) - plain output"

# Sessions labeled with an isolation marker are reconciled by a locally
# running operator:dev instead of the deployed one - same convention as the
# postgres:* tasks. The dev operator gets OPERATOR_S3_BRANCHING from the env
# override in .mirrord/operator-dev.yaml (the deployed released chart does not
# render the flag yet); the deployed operator needs it in its own env.
if pgrep -qf 'target/debug/operator-service'; then
  [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=$OPERATOR_ISOLATION_MARKER"
  info "(its s3 flag comes from the .mirrord/operator-dev.yaml env override)"
else
  info "no operator:dev process detected - the deployed operator reconciles the branches"
  S3_FLAG="$(kubectl get deploy mirrord-operator -n mirrord -o json 2>/dev/null \
    | jq -r '.spec.template.spec.containers[0].env[]?
             | select(.name == "OPERATOR_S3_BRANCHING") | .value')"
  if [ "$S3_FLAG" != "true" ]; then
    warn "the deployed operator has no OPERATOR_S3_BRANCHING=true, and its image is"
    warn "a release without the S3 controller anyway - run 'task operator:dev' from"
    warn "the s3-branching operator checkout, or deploy an image that carries it."
    confirm "Continue anyway?" || exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Deploy: LocalStack, target pod, source bucket
# ---------------------------------------------------------------------------
header "Deploy (only what's missing)"

if kubectl get deploy localstack -n "$LOCALSTACK_NS" >/dev/null 2>&1; then
  info "LocalStack already deployed ($LOCALSTACK_NS namespace)"
else
  info "deploying LocalStack from the sqs-localstack overlay (localstack parts only)"
  kubectl apply -f "$LOCALSTACK_OVERLAY/localstack-namespace.yaml" >/dev/null
  kubectl create configmap localstack-init -n "$LOCALSTACK_NS" \
    --from-file=init.sh="$LOCALSTACK_OVERLAY/init.sh" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "$LOCALSTACK_OVERLAY/localstack.yaml" >/dev/null
fi
kubectl rollout status deploy/localstack -n "$LOCALSTACK_NS" --timeout=180s >/dev/null \
  || { fail "LocalStack never became ready"; exit 1; }
info "LocalStack ready (this is the 'customer AWS account' the operator clones in)"

info "seeding source bucket $SOURCE_BUCKET (versioning, tags, 3 objects)"
awslocal s3api create-bucket --bucket "$SOURCE_BUCKET" \
  --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null \
  || { fail "creating the source bucket failed"; exit 1; }
awslocal s3api put-bucket-versioning --bucket "$SOURCE_BUCKET" \
  --versioning-configuration Status=Enabled >/dev/null
awslocal s3api put-bucket-tagging --bucket "$SOURCE_BUCKET" \
  --tagging "TagSet=[{Key=team,Value=sandbox}]" >/dev/null
seed_object() { # <key> <content>
  printf '%s' "$2" | kubectl exec -i -n "$LOCALSTACK_NS" deploy/localstack -- \
    awslocal s3 cp - "s3://$SOURCE_BUCKET/$1" >/dev/null
}
seed_object "fixtures/a.txt" "alpha" || { fail "seeding objects failed"; exit 1; }
seed_object "fixtures/b.json" '{"b": true}'
seed_object "other/skip.bin" "must not be copied"

# The target carries only the bucket env var; the operator clones with its own
# AWS env, so the pod needs no credentials at all.
info "deploying target (deploy/$TARGET) with $BUCKET_ENV_VAR=$SOURCE_BUCKET"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$NAMESPACE" -f - <<EOF >/dev/null
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
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "echo 's3 branch scenario target running' && sleep 86400"]
        env:
        - { name: $BUCKET_ENV_VAR, value: "$SOURCE_BUCKET" }
EOF
kubectl rollout status "deploy/$TARGET" -n "$NAMESPACE" --timeout=120s >/dev/null \
  || { fail "$TARGET target never became ready"; exit 1; }
info "target ready (deploy/$TARGET)"

# ---------------------------------------------------------------------------
# Scenario: copy mode "all" with object patterns
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" = all ] || [ "$ONLY_CASE" = copy ]; then
header "Scenario: copy mode 'all' with object patterns"
CREATED_BRANCH_IDS+=("$COPY_BRANCH_ID")

COPY_MIRRORD="$WORKDIR/mirrord-copy.json"
mirrord_config "$COPY_BRANCH_ID" '{ "mode": "all", "objects": ["^fixtures/"] }' \
  > "$COPY_MIRRORD"
COPY_LOG="$WORKDIR/copy-session.log"
launch_session "$COPY_MIRRORD" "$COPY_LOG"

if BRANCH="$(wait_branch "$COPY_BRANCH_ID" "$SESSION_PID" "$COPY_LOG")"; then
  info "branch CRD: $BRANCH"
  if wait_branch_phase "$BRANCH" "Ready"; then
    check "copy-mode branch reaches Ready" 0

    BRANCH_BUCKET="$(branch_bucket "$BRANCH")"
    info "branch bucket (from the $BUCKET_ANNOTATION annotation): ${BRANCH_BUCKET:-<missing>}"
    # [[ ]] instead of case: macOS bash 3.2 cannot parse a case pattern's
    # closing paren inside $() and dies with "unexpected token newline".
    check "branch carries the bucket annotation (mirrord-* name)" \
      "$([[ "$BRANCH_BUCKET" == mirrord-* ]] && echo 0 || echo 1)"
    [ -n "$BRANCH_BUCKET" ] && CREATED_BUCKETS+=("$BRANCH_BUCKET")

    if [ -n "$BRANCH_BUCKET" ]; then
      check "branch bucket exists in LocalStack" \
        "$(bucket_exists "$BRANCH_BUCKET" && echo 0 || echo 1)"

      KEYS="$(bucket_keys "$BRANCH_BUCKET")"
      info "objects in the branch bucket: $(printf '%s' "$KEYS" | tr '\n' ' ')"
      check "only the objects matching ^fixtures/ were copied" \
        "$([ "$KEYS" = "$(printf 'fixtures/a.txt\nfixtures/b.json')" ] && echo 0 || echo 1)"

      VERSIONING="$(awslocal s3api get-bucket-versioning --bucket "$BRANCH_BUCKET" \
        --output json 2>/dev/null | jq -r '.Status // empty')"
      check "source's versioning setting was cloned (Enabled)" \
        "$([ "$VERSIONING" = "Enabled" ] && echo 0 || echo 1)"

      TAG="$(awslocal s3api get-bucket-tagging --bucket "$BRANCH_BUCKET" \
        --output json 2>/dev/null | jq -r '.TagSet[]? | select(.Key=="team") | .Value')"
      check "source's tags were cloned (team=sandbox)" \
        "$([ "$TAG" = "sandbox" ] && echo 0 || echo 1)"
    fi

    RECORD="$(record_name "$BRANCH")"
    check "bucket record exists ($RECORD)" \
      "$(kubectl get "$RECORD_CRD" "$RECORD" >/dev/null 2>&1 && echo 0 || echo 1)"

    SEEN="$(session_bucket_env "$COPY_LOG")"
    info "session saw $BUCKET_ENV_VAR=${SEEN:-<never printed>}"
    check "session's $BUCKET_ENV_VAR was rewritten to the branch bucket" \
      "$([ -n "$SEEN" ] && [ "$SEEN" = "$BRANCH_BUCKET" ] && echo 0 || echo 1)"
  else
    check "copy-mode branch reaches Ready" 1
    warn "phase: $(branch_json "$BRANCH" '.status.phase // empty'), error: $(branch_json "$BRANCH" '.status.error // empty')"
  fi
else
  FAILURES=$((FAILURES + 1))
fi
kill_session
fi

# ---------------------------------------------------------------------------
# Scenario: copy mode "empty"
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" = all ] || [ "$ONLY_CASE" = empty ]; then
header "Scenario: copy mode 'empty'"
CREATED_BRANCH_IDS+=("$EMPTY_BRANCH_ID")

EMPTY_MIRRORD="$WORKDIR/mirrord-empty.json"
mirrord_config "$EMPTY_BRANCH_ID" '{ "mode": "empty" }' > "$EMPTY_MIRRORD"
EMPTY_LOG="$WORKDIR/empty-session.log"
launch_session "$EMPTY_MIRRORD" "$EMPTY_LOG"

if BRANCH="$(wait_branch "$EMPTY_BRANCH_ID" "$SESSION_PID" "$EMPTY_LOG")"; then
  info "branch CRD: $BRANCH"
  if wait_branch_phase "$BRANCH" "Ready"; then
    check "empty-mode branch reaches Ready" 0
    BRANCH_BUCKET="$(branch_bucket "$BRANCH")"
    [ -n "$BRANCH_BUCKET" ] && CREATED_BUCKETS+=("$BRANCH_BUCKET")
    check "branch bucket exists in LocalStack" \
      "$([ -n "$BRANCH_BUCKET" ] && bucket_exists "$BRANCH_BUCKET" && echo 0 || echo 1)"
    KEYS="$(bucket_keys "$BRANCH_BUCKET")"
    check "branch bucket has no objects" \
      "$([ -z "$KEYS" ] && echo 0 || echo 1)"
  else
    check "empty-mode branch reaches Ready" 1
    warn "phase: $(branch_json "$BRANCH" '.status.phase // empty'), error: $(branch_json "$BRANCH" '.status.error // empty')"
  fi
else
  FAILURES=$((FAILURES + 1))
fi
kill_session
fi

# ---------------------------------------------------------------------------
# Scenario: source bucket does not exist -> Failed, nothing created
# ---------------------------------------------------------------------------
if [ "$ONLY_CASE" = all ] || [ "$ONLY_CASE" = failure ]; then
header "Scenario: missing source bucket fails the branch"
CREATED_BRANCH_IDS+=("$FAIL_BRANCH_ID")

MISSING_BUCKET="no-such-bucket-$RUN_TAG"
FAIL_MIRRORD="$WORKDIR/mirrord-fail.json"
# A literal param value overrides what the target's env var holds, pointing
# the branch at a bucket that does not exist.
mirrord_config "$FAIL_BRANCH_ID" '{ "mode": "empty" }' \
  "{ \"variable\": \"$BUCKET_ENV_VAR\", \"value\": \"$MISSING_BUCKET\" }" \
  > "$FAIL_MIRRORD"
FAIL_LOG="$WORKDIR/fail-session.log"
launch_session "$FAIL_MIRRORD" "$FAIL_LOG"

if BRANCH="$(wait_branch "$FAIL_BRANCH_ID" "$SESSION_PID" "$FAIL_LOG")"; then
  info "branch CRD: $BRANCH"
  if wait_branch_phase "$BRANCH" "Failed"; then
    check "branch with a missing source bucket goes Failed" 0
    ERROR="$(branch_json "$BRANCH" '.status.error // empty')"
    info "status.error: ${ERROR:-<empty>}"
    check "the error names the source bucket (diagnosable failure)" \
      "$(printf '%s' "$ERROR" | grep -q "$MISSING_BUCKET" && echo 0 || echo 1)"
    check "no branch bucket was created" \
      "$([ -z "$(branch_bucket "$BRANCH")" ] && echo 0 || echo 1)"
    check "no bucket record was left behind" \
      "$(kubectl get "$RECORD_CRD" "$(record_name "$BRANCH")" >/dev/null 2>&1 && echo 1 || echo 0)"
  else
    check "branch with a missing source bucket goes Failed" 1
    warn "phase: $(branch_json "$BRANCH" '.status.phase // empty') - expected Failed"
  fi
else
  FAILURES=$((FAILURES + 1))
fi
kill_session
fi

# ---------------------------------------------------------------------------
# Cleanup chain: sessions gone -> TTL deletes branches -> records + buckets go
# ---------------------------------------------------------------------------
header "Cleanup chain after the sessions ended"

info "waiting for the cleanup chain (session close, then branch TTL=${TTL_SECS}s,"
info "then a DynamicOwner GC tick; ~1min total under operator:dev)"
info "- up to ${CLEANUP_TIMEOUT}s"

wait_gone() { # <check-cmd...>  -> 0 when the check stops passing
  local waited=0
  while [ "$waited" -lt "$CLEANUP_TIMEOUT" ]; do
    if ! "$@" >/dev/null 2>&1; then return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

branch_exists_by_id() { [ -n "$(branch_name_by_id "$1")" ]; }
record_exists() { kubectl get "$RECORD_CRD" "$1" >/dev/null 2>&1; }

for id in "${CREATED_BRANCH_IDS[@]:-}"; do
  [ -n "$id" ] || continue
  # Resolve the record name while the branch still exists; it is needed after.
  name="$(branch_name_by_id "$id")"
  record=""
  [ -n "$name" ] && record="$(record_name "$name")"
  check "BranchDatabase (id=$id) deleted by TTL" \
    "$(wait_gone branch_exists_by_id "$id" && echo 0 || echo 1)"
  if [ -n "$record" ]; then
    check "bucket record $record garbage-collected" \
      "$(wait_gone record_exists "$record" && echo 0 || echo 1)"
  fi
done

for bucket in "${CREATED_BUCKETS[@]:-}"; do
  [ -n "$bucket" ] || continue
  check "branch bucket $bucket emptied and deleted" \
    "$(wait_gone bucket_exists "$bucket" && echo 0 || echo 1)"
done

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
