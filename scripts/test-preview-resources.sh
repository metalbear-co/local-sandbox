#!/usr/bin/env bash
#
# End-to-end test for previews built from manifest files (`mirrord preview start --resource`)
# and for `mirrord preview diff`.
#
# The setup: one Deployment, echo-res, whose pod reads CLUSTER_ID from the ConfigMap
# echo-res-config through envFrom. echo-app reports CLUSTER_ID on GET /info, so every
# request shows which spec and which ConfigMap the pod that answered was built from:
# requests with `X-Preview: <key>` reach the preview, plain requests the real app.
#
# Cases and the expected verdict:
#   1. invalid YAML fails locally with file, line and column; nothing is created
#   2. a directory without manifests and a non-YAML file fail with their own messages
#   3. preview diff prints the changed env var and creates no session
#   4. an env var changed in the Deployment manifest reaches the preview pod, the
#      real app keeps the live value
#   5. same key again with a changed manifest replaces the preview: one session,
#      new value
#   6. a changed ConfigMap becomes the preview's own copy: the preview reads it, the
#      live ConfigMap and the real app keep the live value
#   7. preview stop deletes the copy and leaves the live ConfigMap untouched
#   8. manifests identical to the live objects: "unchanged, skipped", no
#      spec.specResources on the session, the preview runs the live spec
#   9. a ConfigMap the cluster rejects fails the start with the API server's reason
#      and "Nothing was created."; no session exists afterwards
#  10. an unrelated Ingress in the same directory is reported as outside the scope
#
# Prerequisites:
#   - bearkube minikube running, the echo-app image loaded: task preview:deploy
#   - CRDs from the branch applied: task operator:crds
#   - task operator:dev running from the feature branch (an operator without
#     PreviewSpecResources makes the CLI refuse --resource)
#   - the mirrord CLI from the feature branch (task mirrord:cli:build)
#
# Usage:
#   task preview:test:resources
#
# Env knobs (all optional):
#   MIRRORD_BIN    mirrord CLI (default: local debug build, then PATH)
#   NAMESPACE      target namespace (default test-mirrord)
#   PREVIEW_KEY    session key (default test-resources)
#   READY_TIMEOUT  seconds for preview start to reach Ready (default 300)
#   KEEP=1         leave the workload and the last preview running for inspection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"

NAMESPACE="${NAMESPACE:-test-mirrord}"
PREVIEW_KEY="${PREVIEW_KEY:-test-resources}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
KEEP="${KEEP:-0}"
APP="echo-res"
CONFIG_MAP="echo-res-config"
LIVE_VALUE="live-configmap"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ] || [ "$MIRRORD_BIN" = "mirrord" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/preview-resources.XXXXXX)"
# The workload has a fixed name, so two concurrent runs would break each other.
LOCK_DIR="/tmp/preview-resources.lock"
CONFIG="$WORKDIR/preview.json"

# The default spinner prints nothing when output is not a terminal; the plain mode prints the
# same lines CI sees, so the checks below can read them from the logs.
export MIRRORD_PROGRESS_MODE=simple

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

RESULTS=()
FAILURES=0
check() { # check <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then
    pass "$1"
    RESULTS+=("PASS|$1")
  else
    fail "$1"
    RESULTS+=("FAIL|$1")
    FAILURES=$((FAILURES + 1))
  fi
}
ok_if() { if "$@"; then echo 0; else echo 1; fi; }

config_map_exists() { kubectl get configmap "$1" -n "$NAMESPACE" >/dev/null 2>&1; }

# Errors are wrapped at the terminal width, so a message can span lines (with a `│` gutter).
# Compares with all whitespace and gutters removed on both sides.
log_has() { # log_has <log> <text>
  tr -d ' \n\t│' < "$1" | grep -qF -- "$(printf '%s' "$2" | tr -d ' \n\t')"
}

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [ "$KEEP" = "1" ]; then
    warn "KEEP=1 - leaving $APP and any preview for key '$PREVIEW_KEY' running (manifests in $WORKDIR)"
    return
  fi
  stop_preview
  kubectl delete deploy,svc "$APP" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete configmap "$CONFIG_MAP" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Without -f the CLI looks for sessions in the kubeconfig's default namespace, not in the
# config's target namespace, so every status/stop call passes the config.
stop_preview() {
  [ -f "$CONFIG" ] || return 0
  "$MIRRORD_BIN" preview stop -f "$CONFIG" -k "$PREVIEW_KEY" >/dev/null 2>&1 || true
}

sessions_for_key() {
  kubectl get previewsessions -n "$NAMESPACE" \
    -o jsonpath="{.items[?(@.spec.key==\"$PREVIEW_KEY\")].metadata.name}" 2>/dev/null
}

# CLUSTER_ID reported by the pod that answered GET /info, sent from inside the cluster so it
# takes the Service path. With a key, the request carries the preview header.
cluster_id() { # cluster_id [preview-key]
  local header=()
  [ -n "${1:-}" ] && header=(--header="X-Preview: $1")
  kubectl exec -n "$NAMESPACE" "deploy/$APP" -c echo -- \
    wget -q -O- -T 30 ${header[@]+"${header[@]}"} "http://$APP:8080/info" 2>/dev/null \
    | grep -o '"cluster_id":"[^"]*"' | cut -d'"' -f4
}

# The steal subscription can lag Ready by a moment, so a request expected to reach the
# preview gets a few tries.
preview_cluster_id() { # preview_cluster_id <expected>
  local value=""
  for _ in 1 2 3 4 5 6; do
    value="$(cluster_id "$PREVIEW_KEY")"
    [ "$value" = "$1" ] && break
    sleep 2
  done
  echo "${value:-<no response>}"
}

start_preview() { # start_preview <manifest dir> <log>
  "$MIRRORD_BIN" preview start -f "$CONFIG" -i echo-app:latest -k "$PREVIEW_KEY" \
    --resource "$1" --timeout "$READY_TIMEOUT" 2>&1 | tee "$2"
  return "${PIPESTATUS[0]}"
}

# The manifests a user would keep for the service. `$1` is the directory, `$2` an extra
# `env` entry for the container (empty for none), `$3` the ConfigMap's CLUSTER_ID.
write_manifests() { # write_manifests <dir> <env CLUSTER_ID or ""> <configmap CLUSTER_ID>
  mkdir -p "$1"
  local env_block=""
  if [ -n "$2" ]; then
    env_block="        - name: CLUSTER_ID
          value: \"$2\""
  fi
  cat > "$1/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $APP
  template:
    metadata:
      labels:
        app: $APP
    spec:
      containers:
      - name: echo
        image: echo-app:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
        envFrom:
        - configMapRef:
            name: $CONFIG_MAP
        env:
        - name: PORT
          value: "8080"
$env_block
EOF
  cat > "$1/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIG_MAP
data:
  CLUSTER_ID: "$3"
EOF
}

header "Preview from manifests e2e (--resource and preview diff)"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run appears active ($LOCK_DIR exists) - remove it if that's stale"
  exit 1
fi

info "mirrord CLI: $MIRRORD_BIN"

"$MIRRORD_BIN" preview diff --help >/dev/null 2>&1 \
  || { fail "$MIRRORD_BIN has no 'preview diff' - build the CLI from the feature branch (task mirrord:cli:build)"; exit 1; }

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
  || { fail "namespace $NAMESPACE not found - run 'task preview:deploy' first"; exit 1; }

# The API server drops fields the installed CRD does not declare: with an old CRD the session
# would silently run the live spec.
kubectl get crd previewsessions.preview.mirrord.metalbear.co -o json 2>/dev/null \
  | grep -q '"specResources"' \
  || { fail "the installed PreviewSession CRD has no spec.specResources - run 'task operator:crds' from the feature branch"; exit 1; }

if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ]; then
  if pgrep -qf 'target/debug/operator-service'; then
    export OPERATOR_ISOLATION_MARKER=local-dev
    info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
  else
    warn "operator:dev is not running - the deployed operator will reconcile the sessions; start 'task operator:dev' from the feature branch unless the deployed one already supports --resource"
  fi
fi

cat > "$CONFIG" <<EOF
{
  "target": {"path": "deploy/$APP", "namespace": "$NAMESPACE"},
  "feature": {
    "preview": {"ttl_mins": 30},
    "network": {
      "incoming": {
        "mode": "steal",
        "ports": [8080],
        "http_filter": {"header_filter": "X-Preview: {{ key }}"}
      }
    }
  }
}
EOF

header "Deploying $APP reading CLUSTER_ID from $CONFIG_MAP"

stop_preview
write_manifests "$WORKDIR/live" "" "$LIVE_VALUE"
kubectl apply -n "$NAMESPACE" -f "$WORKDIR/live/configmap.yaml" -f "$WORKDIR/live/deployment.yaml" >/dev/null \
  || { fail "failed to apply the live workload"; exit 1; }
kubectl apply -n "$NAMESPACE" -f - >/dev/null <<EOF || { fail "failed to apply the Service"; exit 1; }
apiVersion: v1
kind: Service
metadata:
  name: $APP
spec:
  selector:
    app: $APP
  ports:
  - port: 8080
    targetPort: 8080
EOF
kubectl rollout status "deploy/$APP" -n "$NAMESPACE" --timeout=120s >/dev/null \
  || { fail "deploy/$APP never rolled out - is the echo-app image loaded? run 'task preview:deploy'"; exit 1; }
LIVE_SEEN="$(cluster_id)"
info "the real app reports CLUSTER_ID=$LIVE_SEEN"

header "Case 1: invalid YAML fails locally"

mkdir -p "$WORKDIR/broken"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\ndata:\n  a: b\n  c: d: e\n' > "$WORKDIR/broken/configmap.yaml"
start_preview "$WORKDIR/broken" "$WORKDIR/case1.log" >/dev/null
RC=$?
check "invalid YAML fails the start (exit $RC)" "$([ "$RC" != 0 ] && echo 0 || echo 1)"
check "the error names the file, line and column" \
  "$(ok_if log_has "$WORKDIR/case1.log" "Failed to parse $WORKDIR/broken/configmap.yaml: line 7, column")"
check "no session was created" "$(ok_if test -z "$(sessions_for_key)")"

header "Case 2: missing manifests are reported"

mkdir -p "$WORKDIR/empty"
echo "notes" > "$WORKDIR/empty/notes.txt"
"$MIRRORD_BIN" preview diff -f "$CONFIG" --resource "$WORKDIR/empty" > "$WORKDIR/case2a.log" 2>&1
check "a directory without YAML says so" \
  "$(ok_if log_has "$WORKDIR/case2a.log" "No Kubernetes manifests found in $WORKDIR/empty (looked for *.yaml, *.yml).")"
"$MIRRORD_BIN" preview diff -f "$CONFIG" --resource "$WORKDIR/empty/notes.txt" > "$WORKDIR/case2b.log" 2>&1
check "a non-YAML file says so" \
  "$(ok_if log_has "$WORKDIR/case2b.log" "$WORKDIR/empty/notes.txt is not a YAML file.")"
"$MIRRORD_BIN" preview diff -f "$CONFIG" --resource "$WORKDIR/nowhere/" > "$WORKDIR/case2c.log" 2>&1
check "a missing path says so" \
  "$(ok_if log_has "$WORKDIR/case2c.log" "Path $WORKDIR/nowhere/ does not exist.")"

header "Case 3: preview diff shows the change and creates nothing"

write_manifests "$WORKDIR/env" "from-deployment" "$LIVE_VALUE"
"$MIRRORD_BIN" preview diff -f "$CONFIG" --resource "$WORKDIR/env" 2>&1 | tee "$WORKDIR/case3.log"
check "diff names the changed env var" \
  "$(ok_if log_has "$WORKDIR/case3.log" "env[CLUSTER_ID]")"
check "diff reports the ConfigMap unchanged" \
  "$(ok_if log_has "$WORKDIR/case3.log" "configmap/$CONFIG_MAP from $WORKDIR/env/configmap.yaml: unchanged")"
check "diff created no session" "$(ok_if test -z "$(sessions_for_key)")"

header "Case 4: an env var changed in the Deployment reaches the preview"

start_preview "$WORKDIR/env" "$WORKDIR/case4.log"
RC=$?
check "preview start with the changed Deployment reaches Ready" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
check "the CLI says it uses the manifest's pod spec" \
  "$(ok_if log_has "$WORKDIR/case4.log" "Using deployment/$APP from $WORKDIR/env/deployment.yaml as the preview pod spec.")"
FIRST_SESSION="$(sessions_for_key)"
VALUE="$(preview_cluster_id from-deployment)"
check "X-Preview request answered with the manifest's value ($VALUE)" "$(ok_if test "$VALUE" = from-deployment)"
VALUE="$(cluster_id)"
check "plain request still answered with the live value ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"

header "Case 5: the same key again replaces the preview"

write_manifests "$WORKDIR/env2" "from-deployment-v2" "$LIVE_VALUE"
start_preview "$WORKDIR/env2" "$WORKDIR/case5.log" >/dev/null
RC=$?
check "second preview start reaches Ready" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
SESSIONS="$(sessions_for_key)"
check "exactly one session for the key ($SESSIONS)" \
  "$(ok_if test "$(echo "$SESSIONS" | wc -w | tr -d ' ')" = 1)"
check "the first session was replaced" "$(ok_if test "$SESSIONS" != "$FIRST_SESSION")"
VALUE="$(preview_cluster_id from-deployment-v2)"
check "X-Preview request answered with the new value ($VALUE)" "$(ok_if test "$VALUE" = from-deployment-v2)"

header "Case 6: a changed ConfigMap becomes the preview's own copy"

write_manifests "$WORKDIR/cm" "" "from-configmap"
cp "$WORKDIR/live/deployment.yaml" "$WORKDIR/cm/deployment.yaml"
cat > "$WORKDIR/cm/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $APP-web
spec:
  defaultBackend:
    service:
      name: $APP
      port:
        number: 8080
EOF
start_preview "$WORKDIR/cm" "$WORKDIR/case6.log"
RC=$?
check "preview start with the changed ConfigMap reaches Ready" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
check "the CLI lists the ConfigMap as changed and the Deployment as unchanged" \
  "$(ok_if log_has "$WORKDIR/case6.log" "Applying 1 of 2 in-scope resources")"
check "the Ingress is reported as outside the target's scope (case 10)" \
  "$(ok_if log_has "$WORKDIR/case6.log" "Skipped 1 resource outside the target's scope: ingress/$APP-web.")"
check "the Ingress was not created" \
  "$(ok_if test -z "$(kubectl get ingress "$APP-web" -n "$NAMESPACE" -o name 2>/dev/null)")"
SESSION="$(sessions_for_key)"
COPY="$SESSION-rcm0"
check "the preview's copy $COPY exists" \
  "$(ok_if config_map_exists "$COPY")"
VALUE="$(preview_cluster_id from-configmap)"
check "X-Preview request answered with the copy's value ($VALUE)" "$(ok_if test "$VALUE" = from-configmap)"
VALUE="$(cluster_id)"
check "plain request still answered with the live value ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"
VALUE="$(kubectl get configmap "$CONFIG_MAP" -n "$NAMESPACE" -o jsonpath='{.data.CLUSTER_ID}')"
check "the live ConfigMap is untouched ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"

header "Case 7: preview stop deletes the copy, not the live ConfigMap"

"$MIRRORD_BIN" preview stop -f "$CONFIG" -k "$PREVIEW_KEY"
check "preview stop succeeds" "$?"
GONE=1
for _ in $(seq 1 30); do
  if [ -z "$(kubectl get configmap "$COPY" -n "$NAMESPACE" -o name 2>/dev/null)" ]; then GONE=0; break; fi
  sleep 2
done
check "the copy $COPY is deleted with the preview" "$GONE"
VALUE="$(kubectl get configmap "$CONFIG_MAP" -n "$NAMESPACE" -o jsonpath='{.data.CLUSTER_ID}')"
check "the live ConfigMap still holds its value ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"

header "Case 8: manifests identical to the live objects"

start_preview "$WORKDIR/live" "$WORKDIR/case8.log"
RC=$?
check "preview start with unchanged manifests reaches Ready" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
check "both objects are reported unchanged, skipped" \
  "$(ok_if log_has "$WORKDIR/case8.log" "Applying 0 of 2 in-scope resources")"
SESSION="$(sessions_for_key)"
SPEC_RESOURCES="$(kubectl get previewsession "$SESSION" -n "$NAMESPACE" -o jsonpath='{.spec.specResources}')"
check "the session carries no spec.specResources" "$(ok_if test -z "$SPEC_RESOURCES")"
VALUE="$(preview_cluster_id "$LIVE_VALUE")"
check "the preview runs the live spec ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"
stop_preview

header "Case 9: a ConfigMap the cluster rejects creates nothing"

write_manifests "$WORKDIR/rejected" "" "$LIVE_VALUE"
cat > "$WORKDIR/rejected/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIG_MAP
data:
  "not a valid key!": "x"
EOF
start_preview "$WORKDIR/rejected" "$WORKDIR/case9.log" >/dev/null
RC=$?
check "preview start fails (exit $RC)" "$([ "$RC" != 0 ] && echo 0 || echo 1)"
check "the error quotes the cluster's rejection" \
  "$(ok_if log_has "$WORKDIR/case9.log" "The cluster rejected ConfigMap/$CONFIG_MAP from $WORKDIR/rejected/configmap.yaml")"
check "the error says nothing was created" "$(ok_if log_has "$WORKDIR/case9.log" "Nothing was created.")"
check "no session exists" "$(ok_if test -z "$(sessions_for_key)")"
VALUE="$(kubectl get configmap "$CONFIG_MAP" -n "$NAMESPACE" -o jsonpath='{.data.CLUSTER_ID}')"
check "the live ConfigMap is untouched ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"

header "Summary"
for result in "${RESULTS[@]}"; do
  case "${result%%|*}" in
    PASS) pass "${result#*|}" ;;
    *) fail "${result#*|}" ;;
  esac
done

if [ "$FAILURES" -gt 0 ]; then
  fail "$FAILURES check(s) failed - logs in $WORKDIR"
  exit 1
fi
pass "all checks passed"
