#!/usr/bin/env bash
#
# End-to-end test for preview traffic delivery on Istio-injected targets
# (INT-702).
#
# The bug being tested:
#   The preview pod copies the target's pod template, so the Istio injector
#   gives it a sidecar too. The operator delivers stolen requests by dialing
#   the preview pod directly - a plaintext connection from outside the mesh.
#   The sidecar captures all inbound traffic, and under STRICT mTLS it resets
#   that connection: every preview-matched request dies while everything else
#   works, which makes it look like mirrord ate the request.
#
# The fix being verified:
#   The operator stamps traffic.sidecar.istio.io/excludeInboundPorts with the
#   session's subscribed ports on the preview pod template, so the injector
#   leaves those ports uncaptured. The sidecar itself stays - the preview
#   app's outgoing traffic still goes through the mesh.
#
# Modes:
#   EXPECT=broken  against an operator WITHOUT the fix: asserts the preview
#                  pod has a sidecar, NO exclude annotation, and that a
#                  preview-matched request gets no answer from the preview
#   EXPECT=fixed   against an operator WITH the fix (default): asserts the
#                  annotation names the subscribed port, the sidecar is still
#                  there, and the preview-matched request is answered by the
#                  preview pod
#
# Prerequisites:
#   - bearkube minikube with the mirrord operator (previews enabled)
#   - istiod installed: task istio:install
#   - the echo-app image loaded into the cluster (task preview:deploy does it)
#
# Usage:
#   task preview:test:istio                 # EXPECT=fixed
#   task preview:test:istio EXPECT=broken   # pre-fix operator
#
# Env knobs (all optional):
#   MIRRORD_BIN    mirrord CLI (default: mirrord from PATH)
#   PREVIEW_KEY    session key (default test-istio-inbound)
#   READY_TIMEOUT  seconds for preview start to reach Ready (default 300)
#   KEEP=1         leave the preview + namespace running for inspection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${ROOT_DIR}/apps/echo-app"

MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"
# The namespace is fixed: mirrord-preview-istio.json targets it by name.
NAMESPACE="test-istio"
PREVIEW_KEY="${PREVIEW_KEY:-test-istio-inbound}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
EXPECT="${EXPECT:-fixed}"
KEEP="${KEEP:-0}"
EXCLUDE_ANNOTATION="traffic.sidecar.istio.io/excludeInboundPorts"

case "$EXPECT" in
  broken|fixed) ;;
  *) echo "EXPECT must be 'broken' or 'fixed', got '$EXPECT'"; exit 2 ;;
esac

fail() { echo "FAIL: $*"; exit 1; }

kubectl get deploy istiod -n istio-system >/dev/null 2>&1 \
  || fail "istiod not found - run 'task istio:install' first"

cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo "KEEP=1 - leaving the preview and the $NAMESPACE namespace running"
    return
  fi
  "$MIRRORD_BIN" preview stop -k "$PREVIEW_KEY" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> [1/7] deploying the echo-app target into an injection-enabled namespace ($NAMESPACE)"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite
kubectl apply -n "$NAMESPACE" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-app
  labels:
    app: echo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo-app
  template:
    metadata:
      labels:
        app: echo-app
    spec:
      containers:
      - name: echo
        image: echo-app:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
        env:
        - name: CLUSTER_ID
          value: "bearkube"
        - name: PORT
          value: "8080"
---
apiVersion: v1
kind: Service
metadata:
  name: echo-app
spec:
  selector:
    app: echo-app
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
spec:
  mtls:
    mode: STRICT
EOF
# The target must be freshly injected: a pod created before the namespace label
# would have no sidecar and prove nothing.
kubectl rollout restart deploy/echo-app -n "$NAMESPACE" >/dev/null
kubectl rollout status deploy/echo-app -n "$NAMESPACE" --timeout=180s \
  || fail "echo-app target never became ready - is the echo-app image loaded? (task preview:deploy)"
TARGET_CONTAINERS=$(kubectl get pods -n "$NAMESPACE" -l app=echo-app \
  -o jsonpath='{.items[0].spec.containers[*].name}')
echo "    target containers: $TARGET_CONTAINERS"
case "$TARGET_CONTAINERS" in
  *istio-proxy*) ;;
  *) fail "target pod has no istio-proxy sidecar - injection is not working" ;;
esac

fetch_hostname() {
  kubectl exec -n "$NAMESPACE" deploy/echo-app -c echo -- \
    wget -q -O- -T 30 "$@" http://echo-app:8080/info 2>/dev/null \
    | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4
}

echo
echo "==> [2/7] sanity: in-mesh request under STRICT mTLS reaches the target"
HOST_PLAIN=$(fetch_hostname)
echo "    answered by: ${HOST_PLAIN:-<no response>}"
[ -n "$HOST_PLAIN" ] || fail "the mesh itself is broken - no response without any preview involved"

echo
echo "==> [3/7] starting the preview (key: $PREVIEW_KEY)"
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  echo "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
fi
"$MIRRORD_BIN" preview start \
  -f "$APP_DIR/mirrord-preview-istio.json" \
  -i "echo-app:latest" \
  -k "$PREVIEW_KEY" \
  --timeout "$READY_TIMEOUT" \
  || fail "preview start did not reach Ready"

SESSION=$(kubectl get previewsessions -n "$NAMESPACE" \
  -o jsonpath="{.items[?(@.spec.key==\"$PREVIEW_KEY\")].metadata.name}" | awk '{print $1}')
[ -n "$SESSION" ] || fail "no preview session found for key '$PREVIEW_KEY'"
SESSION_UID=$(kubectl get previewsession "$SESSION" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')
POD=$(kubectl get pods -n "$NAMESPACE" \
  -l "preview.metalbear.co/session-uid=$SESSION_UID" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] || fail "no running preview pod for session $SESSION"
echo "preview session: $SESSION, pod: $POD"

echo
echo "==> [4/7] the preview pod keeps its sidecar (outgoing traffic must stay in the mesh)"
PREVIEW_CONTAINERS=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}')
echo "    preview containers: $PREVIEW_CONTAINERS"
case "$PREVIEW_CONTAINERS" in
  *istio-proxy*) ;;
  *) fail "the preview pod lost its istio-proxy sidecar - the fix must exclude ports, not strip the mesh" ;;
esac

echo
echo "==> [5/7] the inbound-exclude annotation on the preview pod"
ANNOTATION=$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath="{.metadata.annotations.traffic\.sidecar\.istio\.io/excludeInboundPorts}")
echo "    $EXCLUDE_ANNOTATION: '${ANNOTATION:-<absent>}'"

echo
echo "==> [6/7] a preview-matched request (X-Preview header) through the target"
FILTERED_HOST=$(fetch_hostname --header="X-Preview: $PREVIEW_KEY")
echo "    answered by: ${FILTERED_HOST:-<no response>}"

echo
echo "==> [7/7] control: unmatched traffic still reaches the original app"
CONTROL_HOST=$(fetch_hostname)
echo "    answered by: ${CONTROL_HOST:-<no response>}"
case "$CONTROL_HOST" in
  "$SESSION"-*) fail "unmatched traffic reached the preview?!" ;;
  "") fail "unmatched traffic got no answer - the target broke" ;;
esac

echo
if [ "$EXPECT" = "broken" ]; then
  [ -z "$ANNOTATION" ] || fail "expected no exclude annotation on a pre-fix operator, got '$ANNOTATION' - is this operator already fixed?"
  case "$FILTERED_HOST" in
    "$SESSION"-*) fail "the preview answered - the sidecar did not break delivery, this run proves nothing" ;;
  esac
  echo "PASS (EXPECT=broken): the bug is real - the sidecar-injected preview pod never"
  echo "answered a preview-matched request (got '${FILTERED_HOST:-no response}'), while"
  echo "unmatched traffic worked. This is the INT-702 report."
else
  case "$ANNOTATION" in
    *8080*) ;;
    *) fail "the exclude annotation does not name port 8080 - the operator fix did not run" ;;
  esac
  case "$FILTERED_HOST" in
    "$SESSION"-*) ;;
    *) fail "the preview-matched request was not answered by the preview pod (got '${FILTERED_HOST:-no response}')" ;;
  esac
  echo "PASS (EXPECT=fixed): the annotation excludes the subscribed port, the sidecar"
  echo "is still present, preview-matched requests reach the preview, and unmatched"
  echo "traffic still reaches the original app under STRICT mTLS."
fi
