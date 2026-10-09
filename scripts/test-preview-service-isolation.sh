#!/usr/bin/env bash
#
# End-to-end test for preview pod isolation from the TARGET's Service on
# dataplanes that ignore pod readiness (the GKE container-native LB /
# playground.metalbear.dev incident).
#
# The leak being tested:
#   Preview pods inherit the target pod template's labels, so the target's
#   Service selects them. The operator's never-Ready readiness gate keeps
#   them out of kube-proxy routing, but a dataplane that programs endpoints
#   straight from the selector (GKE NEG controller) routes the target's
#   stable traffic to the preview build anyway.
#
# How the leak is made observable on minikube (no NEG controller here):
#   - EndpointSlice membership: the slice controller lists not-Ready pods
#     (with ready=false) - exactly the feed the NEG controller consumes.
#   - A second Service with publishNotReadyAddresses: true and the same
#     selector, which makes kube-proxy behave like a readiness-ignoring
#     dataplane: real requests hit the preview pod.
#
# Modes:
#   EXPECT=broken  against an operator WITHOUT the selector-label strip:
#                  asserts the leak IS observable (proves the bug existed)
#   EXPECT=fixed   against an operator WITH the fix (default):
#                  asserts the preview pod carries no selector labels, is in
#                  no EndpointSlice of the target's Services, receives none
#                  of the unfiltered traffic - and still serves stolen
#                  X-Preview traffic (the fix must not break preview routing)
#
# Prerequisites:
#   - bearkube minikube running, mirrord operator with previews enabled
#   - the echo-app target deployed: task preview:deploy
#
# Usage:
#   task preview:test:service-isolation                 # EXPECT=fixed
#   task preview:test:service-isolation EXPECT=broken   # pre-fix operator
#
# Env knobs (all optional):
#   MIRRORD_BIN    mirrord CLI (default: mirrord from PATH)
#   NAMESPACE      target namespace (default test-mirrord)
#   PREVIEW_KEY    session key (default test-svc-isolation)
#   READY_TIMEOUT  seconds for preview start to reach Ready (default 300)
#   KEEP=1         leave the preview + sim Service running for inspection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${ROOT_DIR}/apps/echo-app"

MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"
NAMESPACE="${NAMESPACE:-test-mirrord}"
PREVIEW_KEY="${PREVIEW_KEY:-test-svc-isolation}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
EXPECT="${EXPECT:-fixed}"
KEEP="${KEEP:-0}"
SIM_SVC="echo-app-neg-sim"
TRAFFIC_REQUESTS=20

case "$EXPECT" in
  broken|fixed) ;;
  *) echo "EXPECT must be 'broken' or 'fixed', got '$EXPECT'"; exit 2 ;;
esac

fail() { echo "FAIL: $*"; exit 1; }

kubectl get deploy echo-app -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "echo-app target not found in $NAMESPACE - run 'task preview:deploy' first"

cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo "KEEP=1 - leaving the preview and $SIM_SVC running"
    return
  fi
  "$MIRRORD_BIN" preview stop -k "$PREVIEW_KEY" >/dev/null 2>&1 || true
  kubectl delete svc "$SIM_SVC" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> [1/6] creating the readiness-ignoring Service ($SIM_SVC) BEFORE the preview"
# publishNotReadyAddresses makes kube-proxy route to not-Ready pods, standing in for a
# NEG-style dataplane. It must exist before the preview starts: the operator strips
# selector labels against the Services present at preview creation.
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $SIM_SVC
spec:
  publishNotReadyAddresses: true
  selector:
    app: echo-app
  ports:
  - port: 8080
    targetPort: 8080
EOF

echo
echo "==> [2/6] starting the preview (key: $PREVIEW_KEY)"
# Route the session to a local operator:dev build when one is running, like the other
# preview:* tasks do - unlabeled sessions go to the deployed operator.
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  echo "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
fi
"$MIRRORD_BIN" preview start \
  -f "$APP_DIR/mirrord-preview-single.json" \
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
POD_IP=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
echo "preview session: $SESSION, pod: $POD ($POD_IP)"

echo
echo "==> [3/6] preview pod labels: does it still carry the target's selector label?"
APP_LABEL=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}')
echo "    app label on the preview pod: '${APP_LABEL:-<absent>}'"

echo
echo "==> [4/6] EndpointSlice membership (the feed a NEG controller consumes)"
# Both the target's real Service and the sim Service select app=echo-app; the preview
# pod IP showing up in either slice is the leak.
SLICE_IPS=$(kubectl get endpointslices -n "$NAMESPACE" \
  -l "kubernetes.io/service-name in (echo-app, $SIM_SVC)" \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}')
if echo "$SLICE_IPS" | grep -qx "$POD_IP"; then
  IN_SLICES=1
  echo "    preview pod IP $POD_IP IS in the Services' EndpointSlices"
else
  IN_SLICES=0
  echo "    preview pod IP $POD_IP is NOT in any EndpointSlice of the target's Services"
fi

echo
echo "==> [5/6] live traffic through the readiness-ignoring Service ($TRAFFIC_REQUESTS unfiltered requests)"
LEAKED=0
for _ in $(seq 1 "$TRAFFIC_REQUESTS"); do
  HOST=$(kubectl exec -n "$NAMESPACE" deploy/echo-app -- \
    wget -q -O- -T 15 "http://$SIM_SVC:8080/info" 2>/dev/null \
    | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4)
  case "$HOST" in
    "$SESSION"-*) LEAKED=$((LEAKED + 1)) ;;
  esac
done
echo "    $LEAKED/$TRAFFIC_REQUESTS answered by the PREVIEW pod (stable traffic leaking into the preview build)"

echo
echo "==> [6/6] control: X-Preview traffic must still reach the preview (stolen from the target)"
STOLEN_HOST=$(kubectl exec -n "$NAMESPACE" deploy/echo-app -- \
  wget -q -O- -T 30 --header="X-Preview: $PREVIEW_KEY" \
  "http://echo-app:8080/info" 2>/dev/null \
  | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4)
echo "    answered by: ${STOLEN_HOST:-<no response>}"
case "$STOLEN_HOST" in
  "$SESSION"-*) ;;
  *) fail "filtered traffic no longer reaches the preview - preview routing broke" ;;
esac

echo
if [ "$EXPECT" = "broken" ]; then
  [ -n "$APP_LABEL" ] || fail "expected the pre-fix operator to copy the app label, but it is absent - is this operator already fixed?"
  [ "$IN_SLICES" = "1" ] || fail "expected the preview pod in the EndpointSlices on a pre-fix operator"
  [ "$LEAKED" -gt 0 ] || fail "expected some unfiltered traffic to leak into the preview on a pre-fix operator"
  echo "PASS (EXPECT=broken): the leak is real - the preview pod carries the selector label,"
  echo "sits in the EndpointSlices, and answered $LEAKED/$TRAFFIC_REQUESTS stable requests."
else
  [ -z "$APP_LABEL" ] || fail "the preview pod still carries app=$APP_LABEL - the selector-label strip did not run"
  [ "$IN_SLICES" = "0" ] || fail "the preview pod is still in the target Services' EndpointSlices"
  [ "$LEAKED" = "0" ] || fail "$LEAKED/$TRAFFIC_REQUESTS unfiltered requests leaked into the preview"
  echo "PASS (EXPECT=fixed): no selector label, no EndpointSlice membership, zero leaked"
  echo "requests - and X-Preview traffic still reaches the preview."
fi
