#!/usr/bin/env bash
#
# End-to-end test: Redis `copy.mode: all` from a TLS-only SOURCE via the
# `redis-source-tls` MirrordPropertyList (the Teladoc INT shape).
#
# Runs against the DEPLOYED operator on purpose - the real operator image runs
# as a non-root user, and that is what exposed the source-TLS file-permission
# bug: the operator mounted `/source-tls` with `defaultMode: 0600`, secret
# files without an `fsGroup` are owned root:root, so the non-root setup
# sidecar died with `Permission denied` on the CA. operator:dev cannot show
# any of this (its branch pods copy init binaries from a root debian image),
# so the script refuses to run while operator:dev is up.
#
# What it does:
#   1. deploys a TLS-only source redis (stock redis:7-alpine + a per-run
#      self-signed cert with the service name in its SAN) and seeds keys
#   2. creates the CA Secret + the `redis-source-tls` MirrordPropertyList
#   3. starts a mirrord session with `copy.mode: all` against a plain
#      `redis://` source URL (proving the operator upgrades it to TLS)
#   4. asserts by outcome:
#        EXPECT=fixed (default)  branch Ready + seeded keys present in it
#        EXPECT=bug              branch Failed with `Permission denied` on
#                                /source-tls/ca.crt (run against operator
#                                <= 3.202.x to demonstrate the customer bug)
#
# With/without comparison:
#   task op:released VERSION=3.202.0 && EXPECT=bug   scripts/test-redis-source-tls.sh
#   task op:custom                   && scripts/test-redis-source-tls.sh
#
# Usage:
#   scripts/test-redis-source-tls.sh
#   task redis:tls:test:source          # EXPECT=fixed
#   task redis:tls:test:source:repro    # EXPECT=bug
#   KEEP=1 ... leaves everything in place
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI (default: local debug build, then PATH)
#   READY_TIMEOUT   seconds for a branch to reach Ready/Failed (default 300)
#   EXPECT          fixed | bug (default fixed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="redis-test"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
EXPECT="${EXPECT:-fixed}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"
BRANCH_PASS="mirrord-redis-branch-pod-pass"
SOURCE_NAME="redis-tls-source"

case "$EXPECT" in fixed|bug) ;; *)
  printf 'EXPECT must be "fixed" or "bug", got: %s\n' "$EXPECT"; exit 2 ;;
esac

LOCAL_MIRRORD="$SCRIPT_DIR/../../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/redis-source-tls.XXXXXX)"
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"

BRANCH_ID="redis-src-tls-$RUN_TAG"
TARGET_POD="redis-src-tls-target-$RUN_TAG"
SEED_KEY="seed:$RUN_TAG"
SEED_VALUE="tls-copy-$RUN_TAG"
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
    warn "KEEP=1 - leaving the source, property list, target, and branch in place"
    warn "  branch id: $BRANCH_ID"
    return
  fi
  local name
  name="$(branch_name_by_id "$BRANCH_ID")"
  [ -n "$name" ] && kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" "$name" \
    --ignore-not-found >/dev/null 2>&1
  kubectl delete -n "$NAMESPACE" "pod/$TARGET_POD" \
    mirrordpropertylist/redis-source-tls \
    secret/redis-source-tls-ca secret/redis-tls-source-cert \
    "deploy/$SOURCE_NAME" "service/$SOURCE_NAME" \
    --ignore-not-found >/dev/null 2>&1 || true
  info "cleaned up branch, target, property list, and the TLS source"
}
trap cleanup EXIT

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
  fail "branch CRD (id=$1) never appeared - is the deployed operator healthy? See $3" >&2
  return 1
}

wait_terminal_phase() { # <branch-name>  -> prints Ready|Failed|<last phase>
  local phase="" waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    phase="$(branch_field "$1" '{.status.phase}')"
    case "$phase" in Ready|Failed) printf '%s' "$phase"; return 0 ;; esac
    sleep 3; waited=$((waited + 3))
  done
  printf '%s' "$phase"
  return 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Redis source-TLS copy e2e - preflight (deployed operator)"

command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq not found"; exit 1; }
command -v openssl >/dev/null 2>&1 || { fail "openssl not found"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not usable: $MIRRORD_BIN"; exit 1; }
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "workdir: $WORKDIR (certs, mirrord config, session log)"
info "expectation: $EXPECT"

# operator:dev steals the deployed operator's API traffic, and its branch pods
# copy init binaries from a root debian image - both would invalidate this test.
if pgrep -qf 'target/debug/operator-service'; then
  fail "operator:dev is running - stop it first; this test must exercise the"
  fail "deployed operator's own non-root image (that is what the bug needs)"
  exit 1
fi
unset OPERATOR_ISOLATION_MARKER

OPERATOR_IMAGE_DEPLOYED="$(kubectl get deploy mirrord-operator -n mirrord \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
if [ -z "$OPERATOR_IMAGE_DEPLOYED" ]; then
  fail "no deployed operator found (deploy/mirrord-operator in ns mirrord)"
  fail "deploy one first: 'task op:custom' (your build) or 'task op:released VERSION=...'"
  exit 1
fi
info "deployed operator image: $OPERATOR_IMAGE_DEPLOYED"
case "$EXPECT" in
  fixed) info "expecting: branch Ready + keys copied (image must carry the 0444 file-mode fix)" ;;
  bug)   info "expecting: branch Failed with Permission denied on /source-tls/ca.crt (image <= 3.202.x)" ;;
esac

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------------------------------------------------------------------------
# TLS-only source redis: per-run self-signed cert with the service DNS name in
# its SAN (rustls ignores CN and verifies the URL host against the SAN).
# ---------------------------------------------------------------------------
header "Deploy the TLS-only source redis + seed data"

openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
  -keyout "$WORKDIR/server.key" -out "$WORKDIR/server.crt" \
  -subj "/CN=$SOURCE_NAME" \
  -addext "subjectAltName=DNS:$SOURCE_NAME,DNS:$SOURCE_NAME.$NAMESPACE.svc.cluster.local" \
  2>/dev/null || { fail "openssl cert generation failed"; exit 1; }
info "generated self-signed cert (SAN: $SOURCE_NAME)"

kubectl create secret generic redis-tls-source-cert -n "$NAMESPACE" \
  --from-file=server.crt="$WORKDIR/server.crt" \
  --from-file=server.key="$WORKDIR/server.key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $SOURCE_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $SOURCE_NAME
  template:
    metadata:
      labels:
        app: $SOURCE_NAME
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        command: ["redis-server"]
        args:
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
        volumeMounts:
        - name: certs
          mountPath: /certs
          readOnly: true
      volumes:
      - name: certs
        secret:
          secretName: redis-tls-source-cert
---
apiVersion: v1
kind: Service
metadata:
  name: $SOURCE_NAME
  namespace: $NAMESPACE
spec:
  selector:
    app: $SOURCE_NAME
  ports:
  - port: 6379
    targetPort: 6379
EOF

kubectl rollout status "deploy/$SOURCE_NAME" -n "$NAMESPACE" --timeout=120s >/dev/null \
  || { fail "TLS source redis not ready"; exit 1; }
SOURCE_POD="$(kubectl get pod -n "$NAMESPACE" -l "app=$SOURCE_NAME" \
  -o jsonpath='{.items[0].metadata.name}')"
info "TLS source ready (pod $SOURCE_POD)"

kubectl exec -n "$NAMESPACE" "$SOURCE_POD" -- \
  redis-cli --tls --insecure SET "$SEED_KEY" "$SEED_VALUE" >/dev/null \
  || { fail "seeding the source over TLS failed"; exit 1; }
kubectl exec -n "$NAMESPACE" "$SOURCE_POD" -- \
  redis-cli --tls --insecure SET "other:$RUN_TAG" "second-key" >/dev/null
info "seeded $SEED_KEY (and one more key) over TLS"

# ---------------------------------------------------------------------------
# The documented customer setup: CA in a Secret + the property list
# ---------------------------------------------------------------------------
header "Create the redis-source-tls MirrordPropertyList"

kubectl create secret generic redis-source-tls-ca -n "$NAMESPACE" \
  --from-file=ca.crt="$WORKDIR/server.crt" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - >/dev/null <<EOF
apiVersion: mirrord.metalbear.co/v1
kind: MirrordPropertyList
metadata:
  name: redis-source-tls
  namespace: $NAMESPACE
spec:
  properties:
    - name: tlsCaCert
      valueFrom:
        secretKeyRef:
          name: redis-source-tls-ca
          key: ca.crt
EOF
info "property list created (tlsCaCert from secret redis-source-tls-ca)"

# The target's REDIS_URL uses the PLAIN scheme on purpose: the property list's
# presence must upgrade the copy connection to rediss://.
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $TARGET_POD
  namespace: $NAMESPACE
  labels:
    test-scenario: redis-source-tls
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'source-tls scenario target running' && sleep 3600"]
    env:
    - name: REDIS_URL
      value: "redis://$SOURCE_NAME:6379/0"
EOF
kubectl wait --for=condition=ready "pod/$TARGET_POD" -n "$NAMESPACE" --timeout=120s >/dev/null \
  || { fail "target pod not ready"; exit 1; }
info "target ready (pod/$TARGET_POD, REDIS_URL=redis://$SOURCE_NAME:6379/0)"

# ---------------------------------------------------------------------------
# The session: copy.mode all against the TLS source
# ---------------------------------------------------------------------------
header "Session: copy.mode all from the TLS source"

MIRRORD_CONFIG="$WORKDIR/mirrord.json"
cat > "$MIRRORD_CONFIG" <<EOF
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
      {
        "id": "$BRANCH_ID",
        "type": "redis",
        "location": "remote",
        "ttl_secs": 300,
        "creation_timeout_secs": 180,
        "connection": { "url": "REDIS_URL" },
        "copy": { "mode": "all" }
      }
    ]
  }
}
EOF

SESSION_LOG="$WORKDIR/session.log"
"$MIRRORD_BIN" exec -f "$MIRRORD_CONFIG" -- sh -c 'echo "SESSION READY"; sleep 240' \
  > "$SESSION_LOG" 2>&1 &
SESSION_PID=$!
disown "$SESSION_PID" 2>/dev/null || true
info "session starting in the background (pid $SESSION_PID)"
info "follow it with: tail -f $SESSION_LOG"

BRANCH="$(wait_branch "$BRANCH_ID" "$SESSION_PID" "$SESSION_LOG")" || { exit 1; }
info "branch CRD: $BRANCH"

PHASE="$(wait_terminal_phase "$BRANCH")"
ERROR="$(branch_field "$BRANCH" '{.status.error}')"
info "terminal phase: ${PHASE:-<none>}"
[ -n "$ERROR" ] && info "status.error: $ERROR"

# ---------------------------------------------------------------------------
# Verdict by expectation
# ---------------------------------------------------------------------------
header "Result"

if [ "$PHASE" = "Ready" ]; then
  COPIED="$(kubectl exec -n "$NAMESPACE" \
    "$(kubectl get pod -n "$NAMESPACE" -l "db-owner-name=$BRANCH" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}')" -- \
    redis-cli --no-auth-warning -a "$BRANCH_PASS" GET "$SEED_KEY" 2>/dev/null)"
  if [ "$EXPECT" = "fixed" ]; then
    check "branch reaches Ready with copy.mode all from the TLS source" 0
    check "seeded key copied into the branch ($SEED_KEY -> $SEED_VALUE)" \
      "$([ "$COPIED" = "$SEED_VALUE" ] && echo 0 || echo 1)"
  else
    check "EXPECT=bug, but the copy succeeded - this operator already carries the fix" 1
  fi
elif printf '%s' "$ERROR" | grep -q "Permission denied"; then
  if [ "$EXPECT" = "bug" ]; then
    check "reproduced the customer bug: non-root sidecar cannot read the 0600-mounted CA" 0
    info "this is exactly the Teladoc failure; an operator with the 0444 file-mode fix copies fine"
  else
    check "branch failed with Permission denied on /source-tls - operator image lacks the file-mode fix" 1
    warn "deploy a build that mounts source TLS files world-readable (task op:custom), then rerun"
  fi
else
  check "branch reached a useful terminal state (phase=$PHASE)" 1
  warn "session log tail:"
  tail -10 "$SESSION_LOG"
fi

if [ "$FAILURES" = 0 ]; then
  pass "all checks passed"
  exit 0
else
  fail "$FAILURES check(s) failed"
  exit 1
fi
