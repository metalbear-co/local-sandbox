#!/usr/bin/env bash
#
# End-to-end test for previews built from a Helm chart (`mirrord preview start --chart`,
# `--values`, `--release-name`, `feature.preview.helm`) and for `mirrord preview diff --chart`.
#
# The setup: a small chart (Deployment + ConfigMap + Service) installed as release echo-helm,
# so the live Deployment echo-helm reads CLUSTER_ID from the ConfigMap echo-helm-config through
# envFrom. echo-app reports CLUSTER_ID on GET /info, so every request shows which spec the pod
# that answered was built from: requests with `X-Preview: <key>` reach the preview, plain
# requests the real app.
#
# Cases and the expected verdict:
#   1. --values without --chart is refused by the CLI before anything runs
#   2. a chart helm cannot render fails with helm's message and "Nothing was created."; no session
#   3. preview diff --chart --values prints the changed env var and creates no session
#   4. --chart without --values prints the default-values notice, the chart's default
#      ConfigMap value becomes the preview's own copy and reaches the preview; live untouched
#   5. --chart --values: the env var from the values file reaches the preview, the real app
#      keeps the live value
#   6. --release-name that does not match the target: "No definition for" plus the release
#      name hint, the preview runs the live spec
#   7. feature.preview.helm in the config, no flags: same result as case 5
#   8. --chart combined with --resource: the ConfigMap from the file and the Deployment from
#      the chart are both in scope
#   9. preview stop deletes the ConfigMap copy and leaves the live ConfigMap untouched
#
# Prerequisites:
#   - bearkube minikube running, the echo-app image loaded: task preview:deploy
#   - helm on PATH
#   - CRDs applied: task operator:crds
#   - task operator:dev running, or a deployed operator with PreviewSpecResources
#   - the mirrord CLI from the feature branch (task mirrord:cli:build)
#
# Usage:
#   task preview:test:helm
#
# Env knobs (all optional):
#   MIRRORD_BIN    mirrord CLI (default: local debug build, then PATH)
#   NAMESPACE      target namespace (default test-mirrord)
#   PREVIEW_KEY    session key (default test-helm)
#   READY_TIMEOUT  seconds for preview start to reach Ready (default 300)
#   KEEP=1         leave the workload and the last preview running for inspection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"

NAMESPACE="${NAMESPACE:-test-mirrord}"
PREVIEW_KEY="${PREVIEW_KEY:-test-helm}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
KEEP="${KEEP:-0}"
# The release name doubles as the Deployment name, which is what the CLI renders under by default.
APP="echo-helm"
CONFIG_MAP="$APP-config"
LIVE_VALUE="live-configmap"
CHART_DEFAULT_VALUE="from-chart-default"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ] || [ "$MIRRORD_BIN" = "mirrord" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/preview-helm.XXXXXX)"
# The workload has a fixed name, so two concurrent runs would break each other.
LOCK_DIR="/tmp/preview-helm.lock"
CONFIG="$WORKDIR/preview.json"
CHART="$WORKDIR/chart"

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
    warn "KEEP=1 - leaving $APP and any preview for key '$PREVIEW_KEY' running (chart in $WORKDIR)"
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

start_preview() { # start_preview <log> <extra args...>
  local log="$1"
  shift
  "$MIRRORD_BIN" preview start -f "$CONFIG" -i echo-app:latest -k "$PREVIEW_KEY" \
    --timeout "$READY_TIMEOUT" "$@" 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

live_config_map_value() {
  kubectl get configmap "$CONFIG_MAP" -n "$NAMESPACE" -o jsonpath='{.data.CLUSTER_ID}'
}

# The chart a team would keep for the service: object names come from the release name, the
# ConfigMap value and an optional explicit CLUSTER_ID env come from values.
write_chart() { # write_chart <dir>
  mkdir -p "$1/templates"
  cat > "$1/Chart.yaml" <<EOF
apiVersion: v2
name: echo
version: 0.1.0
EOF
  cat > "$1/values.yaml" <<EOF
configMapClusterId: "$CHART_DEFAULT_VALUE"
# When set, an explicit CLUSTER_ID env var that wins over the ConfigMap's.
envClusterId: ""
# Off when the ConfigMap is kept as a plain manifest next to the chart (case 8).
manageConfigMap: true
EOF
  cat > "$1/templates/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
      - name: echo
        image: echo-app:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
        envFrom:
        - configMapRef:
            name: {{ .Release.Name }}-config
        env:
        - name: PORT
          value: "8080"
        {{- if .Values.envClusterId }}
        - name: CLUSTER_ID
          value: {{ .Values.envClusterId | quote }}
        {{- end }}
EOF
  cat > "$1/templates/configmap.yaml" <<'EOF'
{{- if .Values.manageConfigMap }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
data:
  CLUSTER_ID: {{ .Values.configMapClusterId | quote }}
{{- end }}
EOF
  cat > "$1/templates/service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  selector:
    app: {{ .Release.Name }}
  ports:
  - port: 8080
    targetPort: 8080
EOF
}

header "Preview from a Helm chart e2e (--chart, --values, --release-name, preview diff)"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run appears active ($LOCK_DIR exists) - remove it if that's stale"
  exit 1
fi

info "mirrord CLI: $MIRRORD_BIN"

command -v helm >/dev/null 2>&1 \
  || { fail "helm is not on PATH - install it (brew install helm)"; exit 1; }

"$MIRRORD_BIN" preview start --help 2>/dev/null | grep -q -- '--chart' \
  || { fail "$MIRRORD_BIN has no 'preview start --chart' - build the CLI from the feature branch (task mirrord:cli:build)"; exit 1; }

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
  || { fail "namespace $NAMESPACE not found - run 'task preview:deploy' first"; exit 1; }

# The API server drops fields the installed CRD does not declare: with an old CRD the session
# would silently run the live spec.
kubectl get crd previewsessions.preview.mirrord.metalbear.co -o json 2>/dev/null \
  | grep -q '"specResources"' \
  || { fail "the installed PreviewSession CRD has no spec.specResources - run 'task operator:crds'"; exit 1; }

if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ]; then
  if pgrep -qf 'target/debug/operator-service'; then
    export OPERATOR_ISOLATION_MARKER=local-dev
    info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
  else
    warn "operator:dev is not running - the deployed operator will reconcile the sessions; it needs PreviewSpecResources (operator 3.213.0 or later)"
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

header "Installing release $APP from the chart"

write_chart "$CHART"
printf 'configMapClusterId: "%s"\n' "$LIVE_VALUE" > "$WORKDIR/values-live.yaml"
printf 'envClusterId: "from-values"\n' > "$WORKDIR/values-env.yaml"

stop_preview
helm template "$APP" "$CHART" --namespace "$NAMESPACE" --values "$WORKDIR/values-live.yaml" \
  | kubectl apply -n "$NAMESPACE" -f - >/dev/null \
  || { fail "failed to apply the rendered chart"; exit 1; }
kubectl rollout status "deploy/$APP" -n "$NAMESPACE" --timeout=120s >/dev/null \
  || { fail "deploy/$APP never rolled out - is the echo-app image loaded? run 'task preview:deploy'"; exit 1; }
LIVE_SEEN="$(cluster_id)"
info "the real app reports CLUSTER_ID=$LIVE_SEEN"

header "Case 1: --values without --chart is refused"

"$MIRRORD_BIN" preview diff -f "$CONFIG" --values "$WORKDIR/values-env.yaml" > "$WORKDIR/case1.log" 2>&1
RC=$?
check "the CLI exits non-zero (exit $RC)" "$([ "$RC" != 0 ] && echo 0 || echo 1)"
check "the error names --chart" "$(ok_if grep -q -- '--chart' "$WORKDIR/case1.log")"

header "Case 2: a chart helm cannot render creates nothing"

cp -R "$CHART" "$WORKDIR/broken-chart"
printf 'kind: {{ .Values.missing.deep }}\n' > "$WORKDIR/broken-chart/templates/broken.yaml"
start_preview "$WORKDIR/case2.log" --chart "$WORKDIR/broken-chart" --values "$WORKDIR/values-live.yaml" >/dev/null
RC=$?
check "preview start fails (exit $RC)" "$([ "$RC" != 0 ] && echo 0 || echo 1)"
check "the error quotes the helm command" \
  "$(ok_if log_has "$WORKDIR/case2.log" "helm template $APP $WORKDIR/broken-chart --namespace $NAMESPACE")"
check "the error names the broken template" "$(ok_if log_has "$WORKDIR/case2.log" "templates/broken.yaml")"
check "the error says nothing was created" "$(ok_if log_has "$WORKDIR/case2.log" "Nothing was created.")"
check "no session was created" "$(ok_if test -z "$(sessions_for_key)")"

header "Case 3: preview diff --chart shows the change and creates nothing"

"$MIRRORD_BIN" preview diff -f "$CONFIG" --chart "$CHART" --values "$WORKDIR/values-live.yaml" \
  --values "$WORKDIR/values-env.yaml" 2>&1 | tee "$WORKDIR/case3.log"
check "the CLI reports what it rendered and the release name" \
  "$(ok_if log_has "$WORKDIR/case3.log" "rendered 3 objects from $CHART as release $APP")"
check "diff names the changed env var" "$(ok_if log_has "$WORKDIR/case3.log" "env[CLUSTER_ID]")"
check "diff attributes the Deployment to its template" \
  "$(ok_if log_has "$WORKDIR/case3.log" "deployment/$APP from $CHART/templates/deployment.yaml: changed")"
check "diff reports the ConfigMap unchanged" \
  "$(ok_if log_has "$WORKDIR/case3.log" "configmap/$CONFIG_MAP from $CHART/templates/configmap.yaml: unchanged")"
check "the Service is outside the target's scope" \
  "$(ok_if log_has "$WORKDIR/case3.log" "service/$APP from $CHART/templates/service.yaml: outside the target's scope")"
check "diff created no session" "$(ok_if test -z "$(sessions_for_key)")"

header "Case 4: --chart without --values renders the chart defaults"

start_preview "$WORKDIR/case4.log" --chart "$CHART"
RC=$?
check "preview start reaches Ready" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
check "the CLI warns about rendering with the default values.yaml" \
  "$(ok_if log_has "$WORKDIR/case4.log" "Rendering $CHART with its default values.yaml only (no --values given).")"
check "the ConfigMap is listed as changed and the Deployment as unchanged" \
  "$(ok_if log_has "$WORKDIR/case4.log" "Applying 1 of 2 in-scope resources")"
SESSION="$(sessions_for_key)"
COPY="$SESSION-rcm0"
check "the preview's ConfigMap copy $COPY exists" "$(ok_if config_map_exists "$COPY")"
VALUE="$(preview_cluster_id "$CHART_DEFAULT_VALUE")"
check "X-Preview request answered with the chart's default value ($VALUE)" "$(ok_if test "$VALUE" = "$CHART_DEFAULT_VALUE")"
VALUE="$(cluster_id)"
check "plain request still answered with the live value ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"
VALUE="$(live_config_map_value)"
check "the live ConfigMap is untouched ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"

header "Case 5: --chart --values: the values file reaches the preview"

start_preview "$WORKDIR/case5.log" --chart "$CHART" --values "$WORKDIR/values-live.yaml" --values "$WORKDIR/values-env.yaml"
RC=$?
check "preview start reaches Ready" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
check "no default-values warning when values are given" \
  "$(ok_if test "$(ok_if log_has "$WORKDIR/case5.log" "default values.yaml only")" = 1)"
check "the CLI says it uses the chart's pod spec" \
  "$(ok_if log_has "$WORKDIR/case5.log" "Using deployment/$APP from $CHART/templates/deployment.yaml as the preview pod spec.")"
SESSIONS="$(sessions_for_key)"
check "exactly one session for the key ($SESSIONS)" \
  "$(ok_if test "$(echo "$SESSIONS" | wc -w | tr -d ' ')" = 1)"
VALUE="$(preview_cluster_id from-values)"
check "X-Preview request answered with the values file's value ($VALUE)" "$(ok_if test "$VALUE" = from-values)"
VALUE="$(cluster_id)"
check "plain request still answered with the live value ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"

header "Case 6: a release name that does not match the target"

start_preview "$WORKDIR/case6.log" --chart "$CHART" --values "$WORKDIR/values-live.yaml" \
  --values "$WORKDIR/values-env.yaml" --release-name wrong-release
RC=$?
check "preview start reaches Ready" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
check "the CLI says the chart defines no $APP" \
  "$(ok_if log_has "$WORKDIR/case6.log" "No definition for deployment/$APP found in the supplied manifests ($CHART).")"
check "the CLI names the release it rendered and the fix" \
  "$(ok_if log_has "$WORKDIR/case6.log" "$CHART was rendered as release \`wrong-release\`. If the chart names deployment/$APP after a different release, pass \`--release-name <name>\`")"
check "the renamed objects are outside the target's scope" \
  "$(ok_if log_has "$WORKDIR/case6.log" "deployment/wrong-release")"
VALUE="$(preview_cluster_id "$LIVE_VALUE")"
check "the preview runs the live spec ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"

header "Case 7: feature.preview.helm in the config, no flags"

HELM_CONFIG="$WORKDIR/preview-helm.json"
cat > "$HELM_CONFIG" <<EOF
{
  "target": {"path": "deploy/$APP", "namespace": "$NAMESPACE"},
  "feature": {
    "preview": {
      "ttl_mins": 30,
      "helm": {
        "chart": "$CHART",
        "values": ["$WORKDIR/values-live.yaml", "$WORKDIR/values-env.yaml"]
      }
    },
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
"$MIRRORD_BIN" preview start -f "$HELM_CONFIG" -i echo-app:latest -k "$PREVIEW_KEY" \
  --timeout "$READY_TIMEOUT" 2>&1 | tee "$WORKDIR/case7.log"
RC="${PIPESTATUS[0]}"
check "preview start from the config reaches Ready" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
check "the chart from the config was rendered" \
  "$(ok_if log_has "$WORKDIR/case7.log" "rendered 3 objects from $CHART as release $APP")"
VALUE="$(preview_cluster_id from-values)"
check "X-Preview request answered with the values file's value ($VALUE)" "$(ok_if test "$VALUE" = from-values)"

header "Case 8: --chart combined with --resource"

# The chart renders only the Deployment here; the ConfigMap is a plain manifest next to it.
printf 'manageConfigMap: false\n' > "$WORKDIR/values-nocm.yaml"
mkdir -p "$WORKDIR/files"
cat > "$WORKDIR/files/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIG_MAP
data:
  CLUSTER_ID: "from-file"
EOF
start_preview "$WORKDIR/case8.log" --chart "$CHART" --values "$WORKDIR/values-live.yaml" \
  --values "$WORKDIR/values-nocm.yaml" --resource "$WORKDIR/files"
RC=$?
check "preview start reaches Ready" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
check "the chart rendered without the ConfigMap" \
  "$(ok_if log_has "$WORKDIR/case8.log" "rendered 2 objects from $CHART as release $APP")"
check "both sources are named together" \
  "$(ok_if log_has "$WORKDIR/case8.log" "in-scope resources from $WORKDIR/files, $CHART")"
check "the ConfigMap comes from the file" \
  "$(ok_if log_has "$WORKDIR/case8.log" "configmap/$CONFIG_MAP changed")"
SESSION="$(sessions_for_key)"
COPY="$SESSION-rcm0"
check "the preview's ConfigMap copy $COPY exists" "$(ok_if config_map_exists "$COPY")"
VALUE="$(preview_cluster_id from-file)"
check "X-Preview request answered with the file's value ($VALUE)" "$(ok_if test "$VALUE" = from-file)"
VALUE="$(live_config_map_value)"
check "the live ConfigMap is untouched ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"

header "Case 9: preview stop deletes the copy, not the live ConfigMap"

"$MIRRORD_BIN" preview stop -f "$CONFIG" -k "$PREVIEW_KEY"
check "preview stop succeeds" "$?"
GONE=1
for _ in $(seq 1 30); do
  if ! config_map_exists "$COPY"; then GONE=0; break; fi
  sleep 2
done
check "the copy $COPY is deleted with the preview" "$GONE"
VALUE="$(live_config_map_value)"
check "the live ConfigMap still holds its value ($VALUE)" "$(ok_if test "$VALUE" = "$LIVE_VALUE")"

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
