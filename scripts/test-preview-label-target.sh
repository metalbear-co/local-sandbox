#!/usr/bin/env bash
#
# End-to-end test for a preview environment whose target is a label selector:
# ONE preview session takes filtered traffic from every pod carrying the label,
# whichever workloads own those pods.
#
# The setup: two separate Deployments (echo-label-a, echo-label-b), each behind
# its own Service, whose pods share the label preview-group=echo-label. The
# preview is started from apps/echo-app/mirrord-preview-label.json, which
# targets that label and steals requests carrying `X-Preview: <key>`.
#
# Every request is identified by the hostname /info reports: preview pods are
# named <session>-*, the workloads' own pods echo-label-a-* and echo-label-b-*.
#
# Cases and the expected verdict:
#   1. preview start with a label target reaches Ready, as one session whose
#      spec.target is the label selector, backed by one preview pod
#   2. an X-Preview request through Service A is answered by the preview pod
#   3. an X-Preview request through Service B is answered by the SAME preview pod
#   4. requests without the header are answered by each workload's own pod
#   5. mirrord preview status lists the session
#   6. after preview stop, X-Preview requests go back to the workloads' own pods
#   7. a selector matching no pod fails the start instead of going Ready
#
# Prerequisites:
#   - bearkube minikube running, the echo-app image loaded: task preview:deploy
#   - CRDs from the branch applied: task operator:crds
#   - task operator:dev running from the feature branch (an older operator does
#     not accept label targets, the CLI refuses to start against it)
#
# Usage:
#   task preview:test:label
#
# Env knobs (all optional):
#   MIRRORD_BIN    mirrord CLI (default: local debug build, then PATH)
#   NAMESPACE      target namespace (default test-mirrord)
#   PREVIEW_KEY    session key (default test-label)
#   READY_TIMEOUT  seconds for preview start to reach Ready (default 300)
#   FAIL_TIMEOUT   seconds given to the no-match start to fail (default 90)
#   KEEP=1         leave the workloads and the preview running for inspection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$SANDBOX_DIR/apps/echo-app"

NAMESPACE="${NAMESPACE:-test-mirrord}"
PREVIEW_KEY="${PREVIEW_KEY:-test-label}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
FAIL_TIMEOUT="${FAIL_TIMEOUT:-90}"
KEEP="${KEEP:-0}"
GROUP_LABEL="preview-group=echo-label"
WORKLOADS="echo-label-a echo-label-b"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ] || [ "$MIRRORD_BIN" = "mirrord" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/preview-label-target.XXXXXX)"
# The workloads have fixed names, so two concurrent runs would delete each other's pods.
LOCK_DIR="/tmp/preview-label-target.lock"

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

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [ "$KEEP" = "1" ]; then
    warn "KEEP=1 - leaving the workloads and any preview for key '$PREVIEW_KEY' running"
    return
  fi
  stop_preview "$WORKDIR/label.json" "$PREVIEW_KEY"
  stop_preview "$WORKDIR/nomatch.json" "$PREVIEW_KEY-nomatch"
  for workload in $WORKLOADS; do
    kubectl delete deploy,svc "$workload" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# Without -f the CLI looks for sessions in the kubeconfig's default namespace, not in the
# config's target namespace, so every status/stop call passes the config it started with.
stop_preview() { # stop_preview <config> <key>
  [ -f "$1" ] || return 0
  "$MIRRORD_BIN" preview stop -f "$1" -k "$2" >/dev/null 2>&1 || true
}

# macOS has no `timeout`; bound the mirrord run that is expected to fail with a watchdog.
run_with_timeout() { # run_with_timeout <secs> <cmd...>
  local secs="$1"
  shift
  "$@" &
  local pid=$!
  (
    sleep "$secs"
    kill "$pid" 2>/dev/null
  ) &
  local watchdog=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$rc"
}

# Prints the hostname that answered one GET /info sent through <service>, optionally
# carrying the X-Preview header. Sent from inside the cluster so it takes the Service path.
answered_by() { # answered_by <service> [preview-key]
  local service="$1" key="${2:-}"
  # bash 3.2 (macOS) treats an empty array as unset under `set -u`, hence the guarded expansion.
  local header=()
  [ -n "$key" ] && header=(--header="X-Preview: $key")
  kubectl exec -n "$NAMESPACE" deploy/echo-label-a -c echo -- \
    wget -q -O- -T 30 ${header[@]+"${header[@]}"} "http://$service:8080/info" 2>/dev/null \
    | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4
}

# The steal subscription can lag the Ready phase by a moment on a loaded laptop, so a
# request expected to reach the preview gets a few tries before it counts as a miss.
answered_by_preview() { # answered_by_preview <service> <session>
  local service="$1" session="$2" host=""
  for _ in 1 2 3 4 5; do
    host="$(answered_by "$service" "$PREVIEW_KEY")"
    case "$host" in "$session"-*) echo "$host"; return 0 ;; esac
    sleep 2
  done
  echo "${host:-<no response>}"
  return 1
}

header "Preview label target e2e (one session, several workloads)"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run appears active ($LOCK_DIR exists) - remove it if that's stale"
  exit 1
fi

info "mirrord CLI: $MIRRORD_BIN"

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
  || { fail "namespace $NAMESPACE not found - run 'task preview:deploy' first"; exit 1; }

# The API server drops fields the installed CRD does not declare, so with a CRD from before
# label targets the session would arrive with an empty target and fail in a confusing way.
kubectl get crd previewsessions.preview.mirrord.metalbear.co -o json 2>/dev/null \
  | grep -q '"labelSelector"' \
  || { fail "the installed PreviewSession CRD has no target.labelSelector - run 'task operator:crds' from the feature branch"; exit 1; }

# Unlabeled sessions go to the deployed operator, which does not know label targets.
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ]; then
  if pgrep -qf 'target/debug/operator-service'; then
    export OPERATOR_ISOLATION_MARKER=local-dev
    info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
  else
    warn "operator:dev is not running - the deployed operator will reconcile the sessions; start 'task operator:dev' from the feature branch unless the deployed one already has label targets"
  fi
fi

sed "s/\"test-mirrord\"/\"$NAMESPACE\"/" "$APP_DIR/mirrord-preview-label.json" > "$WORKDIR/label.json"
sed 's/"echo-label"/"echo-label-matches-nothing"/' "$WORKDIR/label.json" > "$WORKDIR/nomatch.json"

header "Deploying two workloads that share $GROUP_LABEL"

stop_preview "$WORKDIR/label.json" "$PREVIEW_KEY"
stop_preview "$WORKDIR/nomatch.json" "$PREVIEW_KEY-nomatch"

for workload in $WORKLOADS; do
  kubectl apply -n "$NAMESPACE" -f - >/dev/null <<EOF || { fail "failed to apply $workload"; exit 1; }
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $workload
  template:
    metadata:
      labels:
        app: $workload
        preview-group: echo-label
    spec:
      containers:
      - name: echo
        image: echo-app:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
---
apiVersion: v1
kind: Service
metadata:
  name: $workload
spec:
  selector:
    app: $workload
  ports:
  - port: 8080
    targetPort: 8080
EOF
done

for workload in $WORKLOADS; do
  kubectl wait --for=condition=available "deploy/$workload" -n "$NAMESPACE" --timeout=120s >/dev/null \
    || { fail "deploy/$workload never became available - is the echo-app image loaded? run 'task preview:deploy'"; exit 1; }
done
info "pods carrying $GROUP_LABEL:"
kubectl get pods -n "$NAMESPACE" -l "$GROUP_LABEL" -o wide

header "Case 1: preview start with a label target"

"$MIRRORD_BIN" preview start \
  -f "$WORKDIR/label.json" \
  -i "echo-app:latest" \
  -k "$PREVIEW_KEY" \
  --timeout "$READY_TIMEOUT"
START_RC=$?
check "preview start with a label target reaches Ready" "$([ "$START_RC" = 0 ] && echo 0 || echo 1)"
if [ "$START_RC" != 0 ]; then
  fail "the session never went Ready, the traffic cases cannot run. Session state:"
  kubectl get previewsessions -n "$NAMESPACE" -o wide
  exit 1
fi

SESSIONS=$(kubectl get previewsessions -n "$NAMESPACE" \
  -o jsonpath="{.items[?(@.spec.key==\"$PREVIEW_KEY\")].metadata.name}")
SESSION_COUNT=$(echo "$SESSIONS" | wc -w | tr -d ' ')
SESSION=$(echo "$SESSIONS" | awk '{print $1}')
check "exactly one PreviewSession serves both workloads (found $SESSION_COUNT)" \
  "$([ "$SESSION_COUNT" = 1 ] && echo 0 || echo 1)"

SELECTOR_VALUE=$(kubectl get previewsession "$SESSION" -n "$NAMESPACE" \
  -o jsonpath='{.spec.target.labelSelector.matchLabels.preview-group}')
check "spec.target is the label selector (preview-group=$SELECTOR_VALUE)" \
  "$([ "$SELECTOR_VALUE" = "echo-label" ] && echo 0 || echo 1)"

SESSION_UID=$(kubectl get previewsession "$SESSION" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')
PREVIEW_PODS=$(kubectl get pods -n "$NAMESPACE" \
  -l "preview.metalbear.co/session-uid=$SESSION_UID" \
  --field-selector=status.phase=Running -o name | wc -l | tr -d ' ')
check "one preview pod backs the session (found $PREVIEW_PODS)" \
  "$([ "$PREVIEW_PODS" = 1 ] && echo 0 || echo 1)"
info "session: $SESSION"

header "Cases 2 and 3: X-Preview traffic through either workload reaches the one preview"

HOST_A=$(answered_by_preview echo-label-a "$SESSION"); RC_A=$?
check "X-Preview through Service echo-label-a answered by the preview pod ($HOST_A)" "$RC_A"
HOST_B=$(answered_by_preview echo-label-b "$SESSION"); RC_B=$?
check "X-Preview through Service echo-label-b answered by the preview pod ($HOST_B)" "$RC_B"
check "both workloads were served by the same preview pod" \
  "$([ "$RC_A" = 0 ] && [ "$HOST_A" = "$HOST_B" ] && echo 0 || echo 1)"

header "Case 4: traffic without the header stays with each workload"

for workload in $WORKLOADS; do
  HOST=$(answered_by "$workload")
  case "$HOST" in
    "$workload"-*) RC=0 ;;
    *) RC=1 ;;
  esac
  check "plain request through Service $workload answered by its own pod (${HOST:-<no response>})" "$RC"
done

header "Case 5: mirrord preview status lists the session"

"$MIRRORD_BIN" preview status -f "$WORKDIR/label.json" -k "$PREVIEW_KEY" | tee "$WORKDIR/status.log"
grep -q "$SESSION" "$WORKDIR/status.log"
check "preview status shows session $SESSION" "$?"

header "Case 6: after preview stop the workloads get their traffic back"

"$MIRRORD_BIN" preview stop -f "$WORKDIR/label.json" -k "$PREVIEW_KEY"
check "preview stop with the label config finds and deletes the session" "$?"
for workload in $WORKLOADS; do
  HOST=$(answered_by "$workload" "$PREVIEW_KEY")
  case "$HOST" in
    "$workload"-*) RC=0 ;;
    *) RC=1 ;;
  esac
  check "X-Preview through Service $workload answered by its own pod again (${HOST:-<no response>})" "$RC"
done

header "Case 7: a selector matching no pod fails the start"

run_with_timeout "$FAIL_TIMEOUT" "$MIRRORD_BIN" preview start \
  -f "$WORKDIR/nomatch.json" \
  -i "echo-app:latest" \
  -k "$PREVIEW_KEY-nomatch" \
  --timeout "$FAIL_TIMEOUT" 2>&1 | tee "$WORKDIR/nomatch.log"
NOMATCH_RC=${PIPESTATUS[0]}
check "preview start fails when the selector matches no pod (exit $NOMATCH_RC)" \
  "$([ "$NOMATCH_RC" != 0 ] && echo 0 || echo 1)"

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
