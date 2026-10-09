#!/usr/bin/env bash
#
# Before/after repro for the Temporal activity task-queue bug (customer report):
# a split worker's workflow schedules an activity WITHOUT naming a task queue,
# the SDK fills in the worker's own (mirrord-patched, virtual) queue and marks
# it UseCompatibleVersion, and the server rejects the whole workflow task
# completion:
#
#   BadScheduleActivityAttributes: Activity with UseCompatibleVersion
#   cannot run on different task queue.
#
# The workflow then spins (WorkflowTaskScheduled/Started repeating) and the
# activity is never scheduled. The fix makes the operator's Temporal proxy
# rewrite virtual queue names in RespondWorkflowTaskCompleted commands back to
# the original queue.
#
# The LOCAL worker must be the PYTHON one (apps/temporal-worker-py). The Go SDK
# reads the workflow's task queue from the WorkflowExecutionStarted history
# event (the origin queue), so Go workers - the deployed sandbox worker and the
# operator e2e workers - never trip the bug. sdk-core (Python/TypeScript) uses
# the worker's configured queue, the patched virtual name, and hits it every
# time, which is why the customer sees it and the e2e suite does not.
#
# Modes:
#   before   run against the DEPLOYED operator (a release without the fix) and
#            verify the bug reproduces: workflow stuck, completion rejected.
#   after    run against a LOCAL `task operator:dev` (built from the branch
#            with the fix) and verify the same flow completes end to end.
#   both     before, then a prompt to start operator:dev, then after.
#
# Usage:
#   ./test-temporal-activity-queue.sh                # gum-pick a mode
#   ./test-temporal-activity-queue.sh before
#   ./test-temporal-activity-queue.sh after
#   ./test-temporal-activity-queue.sh both
#   DEPLOY=1 ./test-temporal-activity-queue.sh both  # (re)deploy the temporal overlay first
#
# Prerequisites:
#   - minikube (bearkube) with an operator deployed (task operator:use)
#   - task temporal:deploy done at least once (or run with DEPLOY=1)
#   - for after/both: the operator checkout on the fix branch, started with
#       SANDBOX_LICENSE=1 task operator:dev
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI (default: local debug build, then PATH)
#   NAMESPACE       worker namespace (default test-mirrord)
#   TEMPORAL_NS_K8S k8s namespace of the temporal server (default temporal)
#   READY_TIMEOUT   seconds to wait for the split to patch the worker (default 120)
#   VERDICT_WAIT    seconds to wait for the workflow verdict (default 60)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$SANDBOX_DIR/apps/temporal-worker-py"
VENV="$APP_DIR/.venv"
OVERLAY="$SANDBOX_DIR/k8s/overlays/temporal"
NAMESPACE="${NAMESPACE:-test-mirrord}"
TEMPORAL_NS_K8S="${TEMPORAL_NS_K8S:-temporal}"
TEMPORAL_NS="${TEMPORAL_NS:-temporal}"
TASK_QUEUE="order-checkout"
WORKER_DEPLOY="temporal-worker"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
VERDICT_WAIT="${VERDICT_WAIT:-60}"
DEPLOY="${DEPLOY:-0}"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/temporal-activity-queue.XXXXXX)"
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"
SESSION_PID=""
SESSION_LOG=""
ACTIVE_WF_ID=""
# One split at a time: two runs patch the same deployment and split config.
LOCK_DIR="/tmp/temporal-activity-queue.lock"

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

confirm() { # confirm <prompt> - returns when the user says go
  if [ "$HAVE_GUM" = 1 ]; then
    gum confirm --affirmative "Continue" --negative "Abort" "$1" || exit 1
  else
    printf '%s [Enter to continue, Ctrl-C to abort] ' "$1"
    read -r _
  fi
}

# ---------------------------------------------------------------------------
# Cluster helpers
# ---------------------------------------------------------------------------
tctl_exec() {
  local pod_ip
  pod_ip=$(kubectl get pod -n "$TEMPORAL_NS_K8S" -l app=temporal \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  [ -n "$pod_ip" ] || { fail "temporal server pod not found"; return 1; }
  kubectl exec -n "$TEMPORAL_NS_K8S" deploy/temporal -- \
    tctl --address "${pod_ip}:7233" --namespace "$TEMPORAL_NS" "$@" 2>&1
}

# The operator never edits the deployment spec: it records the split's env in a
# MirrordClusterWorkloadPatchRequest and the pod mutator injects it at pod
# admission. So "split active" is read off the patch request, same as the other
# split scripts.
patched_task_queue() {
  kubectl get mirrordclusterworkloadpatchrequests -o json 2>/dev/null | python3 -c '
import json, sys
ns, name = sys.argv[1], sys.argv[2]
for r in json.load(sys.stdin).get("items", []):
    ref = (r.get("spec") or {}).get("workloadRef") or {}
    if ref.get("namespace") != ns or ref.get("name") != name:
        continue
    for env in (r.get("spec") or {}).get("envVars") or []:
        if env.get("variable") == "TEMPORAL_TASK_QUEUE":
            print(env.get("value", ""))
            sys.exit(0)
' "$NAMESPACE" "$WORKER_DEPLOY"
}

dev_operator_running() { pgrep -qf 'target/debug/operator-service'; }

start_workflow() { # start_workflow <wf_id> <message>
  local input
  input=$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  tctl_exec workflow start \
    --taskqueue "$TASK_QUEUE" \
    --workflow_type CheckoutWorkflow \
    --workflow_id "$1" \
    --input "$input" >/dev/null
}

workflow_history() { tctl_exec workflow show --workflow_id "$1"; }

terminate_workflow() {
  [ -n "$1" ] || return 0
  tctl_exec workflow terminate --workflow_id "$1" --reason "repro cleanup" >/dev/null 2>&1 || true
}

stop_session() {
  if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
    info "mirrord session stopped"
  fi
  SESSION_PID=""
}

# The operator removes the patch request when the session ends; the next phase
# must not start until it is gone, or its "patched" wait would pass on the
# previous phase's leftovers.
wait_for_unpatch() {
  local waited=0
  while [ "$waited" -lt 60 ]; do
    [ -z "$(patched_task_queue)" ] && return 0
    sleep 2; waited=$((waited + 2))
  done
  warn "workload patch request still present 60s after the session ended"
  return 1
}

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  stop_session
  terminate_workflow "$ACTIVE_WF_ID"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# One phase = one mirrord session + one matching workflow + a verdict
# ---------------------------------------------------------------------------
run_phase() { # run_phase <before|after>
  local mode="$1"
  local wf_id="test-alice-actq-$mode-$RUN_TAG"
  SESSION_LOG="$WORKDIR/worker-$mode.log"

  header "Phase: $mode"

  info "starting local PYTHON worker under mirrord (split on $TASK_QUEUE)"
  info "worker log: $SESSION_LOG (tail -f to watch)"
  "$MIRRORD_BIN" exec -f "$OVERLAY/mirrord.json" -- \
    "$VENV/bin/python" "$APP_DIR/worker.py" \
    >"$SESSION_LOG" 2>&1 &
  SESSION_PID=$!

  local waited=0 patched=""
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    if ! kill -0 "$SESSION_PID" 2>/dev/null; then
      fail "mirrord session died during startup; last log lines:"
      tail -15 "$SESSION_LOG"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
    patched="$(patched_task_queue)"
    [ -n "$patched" ] && break
    sleep 2; waited=$((waited + 2))
  done
  if [ -n "$patched" ]; then
    info "split active: workload patch points the cluster worker at '$patched' (${waited}s)"
  else
    fail "no workload patch request appeared within ${READY_TIMEOUT}s - split did not start"
    tail -15 "$SESSION_LOG"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  # Give the local worker's pollers a moment to attach to the session queue.
  sleep 8

  info "starting matching workflow $wf_id (filter: ^test-alice-)"
  ACTIVE_WF_ID="$wf_id"
  start_workflow "$wf_id" "activity-queue repro ($mode)" || { FAILURES=$((FAILURES + 1)); return 1; }

  local history completed=1
  waited=0
  while [ "$waited" -lt "$VERDICT_WAIT" ]; do
    history="$(workflow_history "$wf_id")"
    if printf '%s' "$history" | grep -q "WorkflowExecutionCompleted"; then
      completed=0
      break
    fi
    sleep 3; waited=$((waited + 3))
  done

  local scheduled=1 rejected=1 activity_ran=1
  printf '%s' "$history" | grep -q "ActivityTaskScheduled" && scheduled=0
  grep -qiE "BadScheduleActivityAttributes|cannot run on different task queue" "$SESSION_LOG" && rejected=0
  grep -q "\[ACTIVITY\]" "$SESSION_LOG" && activity_ran=0

  echo ""
  if [ "$mode" = before ]; then
    header "Verdict (before: bug expected to reproduce)"
    check "workflow is stuck (no WorkflowExecutionCompleted after ${VERDICT_WAIT}s)" \
      "$([ "$completed" = 1 ] && echo 0 || echo 1)"
    check "no ActivityTaskScheduled ever written to history" \
      "$([ "$scheduled" = 1 ] && echo 0 || echo 1)"
    check "worker log shows the completion rejection (BadScheduleActivityAttributes)" "$rejected"
    if [ "$completed" = 0 ]; then
      warn "workflow completed against the deployed operator - is a fixed operator:dev stealing?"
    fi
  else
    header "Verdict (after: fix expected to work)"
    check "workflow completed within ${waited}s" "$completed"
    check "ActivityTaskScheduled written to history" "$scheduled"
    if [ "$scheduled" = 0 ]; then
      # tctl wraps event attributes across lines, so collect the whole
      # ActivityTaskScheduled block (header line + wrapped attribute lines)
      # before looking for the task queue name.
      local activity_block
      activity_block=$(printf '%s\n' "$history" \
        | awk '/^[[:space:]]*[0-9]+[[:space:]]/{inblock=/ActivityTaskScheduled/} inblock{print}')
      check "activity scheduled on the ORIGINAL queue ($TASK_QUEUE)" \
        "$(printf '%s' "$activity_block" | grep -q "Name:$TASK_QUEUE" && echo 0 || echo 1)"
    fi
    check "local worker executed the activity ([ACTIVITY] in log)" "$activity_ran"
    check "no completion rejection in the worker log" \
      "$([ "$rejected" = 1 ] && echo 0 || echo 1)"
  fi

  if [ "$FAILURES" -gt 0 ]; then
    echo ""
    warn "worker log tail ($SESSION_LOG):"
    tail -20 "$SESSION_LOG"
  fi

  # Leave the cluster the way we found it before the next phase runs.
  terminate_workflow "$wf_id"
  ACTIVE_WF_ID=""
  stop_session
  wait_for_unpatch || true
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  mkdir "$LOCK_DIR" 2>/dev/null \
    || { fail "another run holds $LOCK_DIR (rmdir it if stale)"; exit 1; }

  command -v kubectl >/dev/null || { fail "kubectl not found"; exit 1; }
  command -v python3 >/dev/null || { fail "python3 not found (runs the local worker)"; exit 1; }
  [ "$HAVE_GUM" = 1 ] || warn "gum not installed - falling back to plain output (brew install gum)"

  if [ "$DEPLOY" = 1 ]; then
    info "DEPLOY=1 - deploying the temporal overlay first"
    (cd "$SANDBOX_DIR" && task temporal:deploy) || { fail "task temporal:deploy failed"; exit 1; }
  fi

  kubectl get deploy mirrord-operator -n mirrord >/dev/null 2>&1 \
    || { fail "no operator deployed (task operator:use)"; exit 1; }
  kubectl get deploy "$WORKER_DEPLOY" -n "$NAMESPACE" >/dev/null 2>&1 \
    || { fail "temporal overlay not deployed (task temporal:deploy, or DEPLOY=1)"; exit 1; }
  kubectl get mirrordsplitconfig temporal-test-config -n "$NAMESPACE" >/dev/null 2>&1 \
    || { fail "MirrordSplitConfig temporal-test-config missing (task temporal:deploy)"; exit 1; }
  if [ -n "$(patched_task_queue)" ]; then
    if pgrep -qf "temporal-worker-py/worker.py"; then
      fail "another local run is splitting $WORKER_DEPLOY right now"
      exit 1
    fi
    # A Ctrl-C'd run can die before deregistering; the session then lingers in
    # its reconnect window and keeps the patch request alive. Nobody local owns
    # it anymore, so reap it instead of refusing to run.
    warn "orphaned split session found for $WORKER_DEPLOY - clearing it"
    kubectl get mirrordclustersplitsession -o name 2>/dev/null \
      | grep "\.$WORKER_DEPLOY\.deployment" \
      | xargs -r kubectl delete 2>/dev/null || true
    wait_for_unpatch || { fail "stale patch request did not clear"; exit 1; }
    info "stale split cleared"
  fi

  if [ ! -x "$VENV/bin/python" ]; then
    info "creating venv for the python worker (one-time)"
    python3 -m venv "$VENV" || { fail "venv creation failed"; exit 1; }
  fi
  if ! "$VENV/bin/python" -c 'import temporalio' 2>/dev/null; then
    info "installing temporalio into the venv"
    "$VENV/bin/pip" install -q -r "$APP_DIR/requirements.txt" \
      || { fail "pip install failed"; exit 1; }
  fi
  info "mirrord: $MIRRORD_BIN"
}

require_deployed_operator_only() {
  if dev_operator_running; then
    fail "a local operator:dev is running - it steals the proxy traffic, so this would test the FIXED code"
    fail "stop it (Ctrl-C in its terminal) and rerun the before phase"
    exit 1
  fi
  local image
  image=$(kubectl get deploy mirrord-operator -n mirrord \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  info "deployed operator: $image (expected to LACK the fix)"
}

require_dev_operator() {
  if dev_operator_running; then
    info "local operator:dev detected (steals the deployed operator's traffic)"
    return 0
  fi
  fail "no local operator:dev running - start it from the fix branch in another terminal:"
  fail "  (cd $SANDBOX_DIR && SANDBOX_LICENSE=1 task operator:dev)"
  exit 1
}

wait_for_dev_operator() {
  header "Switch to the fixed operator"
  echo "In another terminal, start the local operator built from the fix branch:"
  echo ""
  echo "  cd $SANDBOX_DIR && SANDBOX_LICENSE=1 task operator:dev"
  echo ""
  echo "Wait for it to log that it is serving, then continue."
  confirm "Is operator:dev up and serving?"
  require_dev_operator
  # The steal session needs a moment to take over the operator's traffic.
  sleep 10
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
MODE="${1:-}"
if [ -z "$MODE" ]; then
  if [ "$HAVE_GUM" = 1 ]; then
    MODE=$(gum choose --header "Which scenario?" before after both) || exit 1
  else
    MODE=both
  fi
fi
case "$MODE" in before|after|both) ;; *) fail "usage: $0 [before|after|both]"; exit 1 ;; esac

header "Temporal activity task-queue repro ($MODE)"
echo "Workflow schedules an activity with NO explicit task queue - the customer shape."
echo "before: deployed operator rejects the completion; after: operator:dev with the fix completes it."

preflight

case "$MODE" in
  before)
    require_deployed_operator_only
    run_phase before
    ;;
  after)
    require_dev_operator
    run_phase after
    ;;
  both)
    require_deployed_operator_only
    run_phase before
    wait_for_dev_operator
    run_phase after
    ;;
esac

echo ""
if [ "$FAILURES" = 0 ]; then
  header "ALL CHECKS PASSED"
else
  header "$FAILURES CHECK(S) FAILED"
fi
echo "Logs kept under $WORKDIR"
echo ""
echo "Next steps:"
echo "  task temporal:status                       split/session state"
echo "  tail -f $WORKDIR/worker-*.log              worker output"
exit "$([ "$FAILURES" = 0 ] && echo 0 || echo 1)"
