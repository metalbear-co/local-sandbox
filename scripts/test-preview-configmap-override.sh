#!/usr/bin/env bash
#
# End-to-end test for overriding a WHOLE-DIRECTORY mounted ConfigMap in a
# preview pod (the Cashfree shape from mirrord-help).
#
# Customer setup being simulated:
#   - config is a VERSIONED ConfigMap (name carries the version, like
#     qa-workflowsvc-1.0.0-318.1319-gh-qa) mounted as a whole directory:
#         volumeMounts: [{mountPath: /home/app/config, name: config-volume}]
#         volumes: [{configMap: {name: wfsim-config-<version>}, ...}]
#   - the app locates config through SPRING_CONFIG_ADDITIONAL_LOCATION
#     (optional:file:/home/app/config/), Spring Boot style
#   - CI builds a NEW config version as an artifact; at preview time that
#     version does NOT exist in the cluster, only as a local file
#
# What the script proves:
#   1. REPRO: a config_mount whose mount_at points INSIDE the mounted
#      ConfigMap directory fails at pod start with the runc
#      "not a directory" error (files in a ConfigMap volume are symlinks
#      into ..data/, a file bind mount cannot overlay them).
#   2. WORKAROUND: mounting the new file at a SIBLING directory and
#      overriding SPRING_CONFIG_ADDITIONAL_LOCATION via feature.env.override
#      starts fine, and:
#        - the preview app loads the NEW config version
#        - the original ConfigMap and its mount are untouched (old content
#          still visible at /home/app/config inside the preview pod)
#        - the deployed (non-preview) pod keeps running the OLD version
#   3. HARDCODED-PATH WORKAROUND: for apps that cannot be redirected via an
#      env var, the deployment change that makes config_mounts work at the
#      REAL path: mount the CM at a staging path, initContainer copies it
#      into an emptyDir mounted where the app looks. The emptyDir holds
#      real files (not ConfigMap symlinks), so the file overlay is legal.
#      Verifies replacing an existing file, ADDING a brand-new file, and
#      that sibling files copied from the CM survive.
#
# Prerequisites:
#   - minikube (bearkube) running with the mirrord operator installed
#     (preview feature enabled) - same setup the other preview:* tasks use
#
# Usage:
#   ./test-preview-configmap-override.sh
#   SKIP_REPRO=1 ./test-preview-configmap-override.sh  # workaround phase only
#   KEEP=1 ./test-preview-configmap-override.sh        # leave preview + target running
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE       namespace for the target (default test-mirrord)
#   APP_IMAGE       image for target and preview (default busybox:1.36)
#   READY_TIMEOUT   seconds for preview start to reach Ready (default 300)
#   REPRO_TIMEOUT   seconds to wait for the expected repro failure (default 180)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-test-mirrord}"
APP_IMAGE="${APP_IMAGE:-busybox:1.36}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
REPRO_TIMEOUT="${REPRO_TIMEOUT:-180}"
SKIP_REPRO="${SKIP_REPRO:-0}"
KEEP="${KEEP:-0}"

LOCAL_MIRRORD="$SCRIPT_DIR/../../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/preview-cm-override.XXXXXX)"
# The target deployment has a fixed name, so two concurrent runs would tear
# down each other's target - refuse to start instead.
LOCK_DIR="/tmp/preview-cm-override.lock"
# Per-run tag so the "new version" marker and preview keys are unique and a
# stale pod from an earlier run cannot satisfy this run's checks.
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"

DEPLOY="wfsim"
DEPLOY_HARD="wfhard"
OLD_VERSION="1.0.0-100.500-gh-qa"
NEW_VERSION="2.0.0-$RUN_TAG-gh-qa"
CM_OLD="$DEPLOY-config-$OLD_VERSION"
CM_HARD="$DEPLOY_HARD-config-$OLD_VERSION"
KEY_BROKEN="cm-broken-$RUN_TAG"
KEY_OK="cm-override-$RUN_TAG"
KEY_HARD="cm-hardcoded-$RUN_TAG"
CONFIG_MOUNT_PATH="/home/app/config"
PREVIEW_MOUNT_PATH="/home/app/preview-config"

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

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1 - leaving the preview and target running"
    warn "  stop later with: $MIRRORD_BIN preview stop -k $KEY_OK"
    warn "  remove target:   kubectl delete -n $NAMESPACE deploy/$DEPLOY cm/$CM_OLD"
    return
  fi
  "$MIRRORD_BIN" preview stop -k "$KEY_BROKEN" >/dev/null 2>&1 || true
  "$MIRRORD_BIN" preview stop -k "$KEY_OK" >/dev/null 2>&1 || true
  "$MIRRORD_BIN" preview stop -k "$KEY_HARD" >/dev/null 2>&1 || true
  kubectl delete -n "$NAMESPACE" "deploy/$DEPLOY" "cm/$CM_OLD" \
    "deploy/$DEPLOY_HARD" "cm/$CM_HARD" \
    --ignore-not-found >/dev/null 2>&1 || true
  info "cleaned up preview sessions and target"
}
trap cleanup EXIT

# Polls the deployment's logs until a pattern shows up. The app prints its
# config version every 5s, so a short poll is enough once the pod is Ready.
wait_for_log() { # wait_for_log <deploy> <pattern> <timeout-secs>
  local target="$1" pattern="$2" timeout="$3" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if kubectl logs -n "$NAMESPACE" "deploy/$target" --tail=5 2>/dev/null \
        | grep -q "$pattern"; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
header "Preview ConfigMap override - preflight"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run holds $LOCK_DIR - remove it if that run is dead"
  trap - EXIT
  exit 1
fi

command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not usable: $MIRRORD_BIN"; exit 1; }
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "workdir: $WORKDIR (mirrord configs + preview start logs live here)"

# Sessions labeled with an isolation marker are reconciled by a locally
# running operator:dev instead of the deployed one - same convention as the
# preview:* tasks.
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
fi

# ---------------------------------------------------------------------------
# Deploy the customer-shaped target
# ---------------------------------------------------------------------------
header "Deploy target ($DEPLOY, versioned CM mounted as a directory)"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CM_OLD
data:
  application.yaml: |
    version: $OLD_VERSION
    server:
      port: 8080
  logging.yaml: |
    level: info
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY
  labels:
    app: $DEPLOY
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY
  template:
    metadata:
      labels:
        app: $DEPLOY
    spec:
      containers:
        - name: app
          image: $APP_IMAGE
          command: ["sh", "-c"]
          # Simulates Spring Boot: the config directory comes from
          # SPRING_CONFIG_ADDITIONAL_LOCATION, not a hardcoded path, which is
          # what makes the env-override workaround possible.
          args:
            - |
              loc="\${SPRING_CONFIG_ADDITIONAL_LOCATION#optional:file:}"
              echo "app starting - config location: \$loc"
              while true; do
                v=\$(sed -n 's/^version: *//p' "\$loc/application.yaml" 2>/dev/null)
                echo "config-version=\${v:-missing} location=\$loc"
                sleep 5
              done
          env:
            - name: SPRING_CONFIG_ADDITIONAL_LOCATION
              value: optional:file:$CONFIG_MOUNT_PATH/
          volumeMounts:
            - mountPath: $CONFIG_MOUNT_PATH
              name: config-volume
      volumes:
        - configMap:
            name: $CM_OLD
          name: config-volume
EOF

kubectl rollout status -n "$NAMESPACE" "deploy/$DEPLOY" --timeout=120s
check "target deployment is ready" $?

wait_for_log "$DEPLOY" "config-version=$OLD_VERSION" 30
check "deployed app reads the OLD config version from the mounted CM" $?

# ---------------------------------------------------------------------------
# Stage the "new version" config artifact locally
# ---------------------------------------------------------------------------
header "Stage new config version locally (simulating extract-config from ECR)"

mkdir -p "$WORKDIR/preview-config"
cat > "$WORKDIR/preview-config/application.yaml" <<EOF
version: $NEW_VERSION
server:
  port: 8080
preview: true
EOF
info "new config staged at $WORKDIR/preview-config/application.yaml (version: $NEW_VERSION)"

# ---------------------------------------------------------------------------
# Phase 1 - reproduce the customer's failure
# ---------------------------------------------------------------------------
if [ "$SKIP_REPRO" != 1 ]; then
  header "Phase 1 - repro: mount_at INSIDE the CM directory (expected to fail)"

  cat > "$WORKDIR/mirrord-broken.json" <<EOF
{
  "target": { "path": "deploy/$DEPLOY", "namespace": "$NAMESPACE" },
  "feature": {
    "preview": {
      "ttl_mins": 30,
      "config_mounts": [
        {
          "mount_at": "$CONFIG_MOUNT_PATH/application.yaml",
          "from_file": "$WORKDIR/preview-config/application.yaml"
        }
      ]
    }
  }
}
EOF

  "$MIRRORD_BIN" preview start \
    -f "$WORKDIR/mirrord-broken.json" \
    -i "$APP_IMAGE" \
    -k "$KEY_BROKEN" \
    --timeout "$REPRO_TIMEOUT" 2>&1 | tee "$WORKDIR/repro-start.log"
  REPRO_RC=$?

  if [ "$REPRO_RC" = 0 ]; then
    warn "preview started fine with mount_at inside the CM directory"
    warn "the operator apparently handles the overlay - the repro phase is obsolete, retire it"
  else
    check "preview start fails (as the customer saw)" 0
    # The CLI's error renderer word-wraps the message with box-drawing
    # decoration, so the phrase can be split across lines - unwrap before
    # matching.
    tr -d '\n│' < "$WORKDIR/repro-start.log" | tr -s ' ' | grep -q "not a directory"
    check "failure is the runc 'not a directory' bind-over-CM-symlink error" $?
  fi
  "$MIRRORD_BIN" preview stop -k "$KEY_BROKEN" >/dev/null 2>&1 || true
else
  warn "SKIP_REPRO=1 - skipping the failure repro phase"
fi

# ---------------------------------------------------------------------------
# Phase 2 - the workaround
# ---------------------------------------------------------------------------
header "Phase 2 - workaround: sibling mount + SPRING_CONFIG_ADDITIONAL_LOCATION override"

cat > "$WORKDIR/mirrord-workaround.json" <<EOF
{
  "target": { "path": "deploy/$DEPLOY", "namespace": "$NAMESPACE" },
  "feature": {
    "env": {
      "override": {
        "SPRING_CONFIG_ADDITIONAL_LOCATION": "optional:file:$PREVIEW_MOUNT_PATH/"
      }
    },
    "preview": {
      "ttl_mins": 30,
      "config_mounts": [
        {
          "mount_at": "$PREVIEW_MOUNT_PATH/application.yaml",
          "from_file": "$WORKDIR/preview-config/application.yaml"
        }
      ]
    }
  }
}
EOF

"$MIRRORD_BIN" preview start \
  -f "$WORKDIR/mirrord-workaround.json" \
  -i "$APP_IMAGE" \
  -k "$KEY_OK" \
  --timeout "$READY_TIMEOUT" 2>&1 | tee "$WORKDIR/workaround-start.log"
check "preview start succeeds with the workaround config" $?

SESSION=$(kubectl get previewsessions -n "$NAMESPACE" \
  -o jsonpath="{.items[?(@.spec.key==\"$KEY_OK\")].metadata.name}" 2>/dev/null | awk '{print $1}')
if [ -z "$SESSION" ]; then
  fail "no preview session found for key $KEY_OK"
  exit 1
fi
info "preview session: $SESSION"

header "Verify"

wait_for_log "$SESSION" "config-version=$NEW_VERSION" 45
check "preview app loads the NEW config version ($NEW_VERSION)" $?

kubectl exec -n "$NAMESPACE" "deploy/$SESSION" -- sh -c \
  "grep -q 'version: $NEW_VERSION' $PREVIEW_MOUNT_PATH/application.yaml"
check "new file is projected at $PREVIEW_MOUNT_PATH/application.yaml" $?

kubectl exec -n "$NAMESPACE" "deploy/$SESSION" -- sh -c \
  "grep -q 'version: $OLD_VERSION' $CONFIG_MOUNT_PATH/application.yaml"
check "original CM directory mount is untouched inside the preview pod" $?

PREVIEW_LOC=$(kubectl exec -n "$NAMESPACE" "deploy/$SESSION" -- sh -c \
  'echo "$SPRING_CONFIG_ADDITIONAL_LOCATION"' 2>/dev/null)
[ "$PREVIEW_LOC" = "optional:file:$PREVIEW_MOUNT_PATH/" ]
check "env override landed in the preview pod ($PREVIEW_LOC)" $?

kubectl logs -n "$NAMESPACE" "deploy/$DEPLOY" --tail=3 | grep -q "config-version=$OLD_VERSION"
check "deployed (non-preview) app still runs the OLD version" $?

kubectl get cm "$CM_OLD" -n "$NAMESPACE" -o jsonpath='{.data.application\.yaml}' \
  | grep -q "version: $OLD_VERSION"
check "versioned ConfigMap in the cluster is unmodified" $?

# ---------------------------------------------------------------------------
# Phase 3 - hardcoded-path workaround: emptyDir + initContainer copy
# ---------------------------------------------------------------------------
header "Phase 3 - hardcoded path: CM staged into an emptyDir, overlay at the real path"

kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CM_HARD
data:
  application.yaml: |
    version: $OLD_VERSION
  logging.yaml: |
    level: info
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_HARD
  labels:
    app: $DEPLOY_HARD
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY_HARD
  template:
    metadata:
      labels:
        app: $DEPLOY_HARD
    spec:
      # The CM is mounted at a staging path only; an initContainer copies it
      # into an emptyDir mounted at the app's path. The app then sees real
      # files instead of ConfigMap symlinks, which is what makes a file
      # overlay at the real path legal.
      initContainers:
        - name: config-copy
          image: $APP_IMAGE
          command: ["sh", "-c", "cp /staging-config/* $CONFIG_MOUNT_PATH/"]
          volumeMounts:
            - mountPath: /staging-config
              name: config-volume
            - mountPath: $CONFIG_MOUNT_PATH
              name: config-dir
      containers:
        - name: app
          image: $APP_IMAGE
          command: ["sh", "-c"]
          # The config path is HARDCODED - no env var redirect possible.
          args:
            - |
              while true; do
                v=\$(sed -n 's/^version: *//p' $CONFIG_MOUNT_PATH/application.yaml 2>/dev/null)
                extra=\$(cat $CONFIG_MOUNT_PATH/extra.yaml 2>/dev/null || echo none)
                echo "config-version=\${v:-missing} extra=\$extra"
                sleep 5
              done
          volumeMounts:
            - mountPath: $CONFIG_MOUNT_PATH
              name: config-dir
      volumes:
        - configMap:
            name: $CM_HARD
          name: config-volume
        - emptyDir: {}
          name: config-dir
EOF

kubectl rollout status -n "$NAMESPACE" "deploy/$DEPLOY_HARD" --timeout=120s
check "hardcoded-path target deployment is ready" $?

wait_for_log "$DEPLOY_HARD" "config-version=$OLD_VERSION" 30
check "hardcoded-path app reads the OLD version from the emptyDir copy" $?

printf 'preview-extra: %s\n' "$RUN_TAG" > "$WORKDIR/preview-config/extra.yaml"

cat > "$WORKDIR/mirrord-hardcoded.json" <<EOF
{
  "target": { "path": "deploy/$DEPLOY_HARD", "namespace": "$NAMESPACE" },
  "feature": {
    "preview": {
      "ttl_mins": 30,
      "config_mounts": [
        {
          "mount_at": "$CONFIG_MOUNT_PATH/application.yaml",
          "from_file": "$WORKDIR/preview-config/application.yaml"
        },
        {
          "mount_at": "$CONFIG_MOUNT_PATH/extra.yaml",
          "from_file": "$WORKDIR/preview-config/extra.yaml"
        }
      ]
    }
  }
}
EOF

"$MIRRORD_BIN" preview start \
  -f "$WORKDIR/mirrord-hardcoded.json" \
  -i "$APP_IMAGE" \
  -k "$KEY_HARD" \
  --timeout "$READY_TIMEOUT" 2>&1 | tee "$WORKDIR/hardcoded-start.log"
check "preview start succeeds overlaying at the REAL (hardcoded) path" $?

SESSION_HARD=$(kubectl get previewsessions -n "$NAMESPACE" \
  -o jsonpath="{.items[?(@.spec.key==\"$KEY_HARD\")].metadata.name}" 2>/dev/null | awk '{print $1}')
if [ -z "$SESSION_HARD" ]; then
  fail "no preview session found for key $KEY_HARD"
  exit 1
fi
info "preview session: $SESSION_HARD"

wait_for_log "$SESSION_HARD" "config-version=$NEW_VERSION" 45
check "hardcoded-path preview app loads the NEW config version" $?

wait_for_log "$SESSION_HARD" "extra=preview-extra: $RUN_TAG" 30
check "a brand-new file can be ADDED to the emptyDir directory too" $?

kubectl exec -n "$NAMESPACE" "deploy/$SESSION_HARD" -- sh -c \
  "grep -q 'level: info' $CONFIG_MOUNT_PATH/logging.yaml"
check "sibling file copied from the CM survives next to the overlay" $?

kubectl logs -n "$NAMESPACE" "deploy/$DEPLOY_HARD" --tail=3 | grep -q "config-version=$OLD_VERSION"
check "deployed hardcoded-path app still runs the OLD version" $?

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"
if [ "$FAILURES" = 0 ]; then
  pass "all checks passed"
  info "logs and mirrord configs kept in $WORKDIR"
else
  fail "$FAILURES check(s) failed - see $WORKDIR for preview start logs"
fi
exit "$FAILURES"
