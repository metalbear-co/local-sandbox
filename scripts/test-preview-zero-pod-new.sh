#!/usr/bin/env bash
#
# Zero-pod preview split, NEW operator side of the A/B:
# runs the scenario against a LOCAL operator started with `task operator:dev`.
# The session is labeled with the operator's isolation marker
# (operator.metalbear.co/owner=local-dev by default), so the local build - not the
# deployed operator - reconciles it. Run the dev operator from the operator repo
# working tree that contains the zero-pod fix.
#
# Scenario and expectations:
#   1. scale the kafka overlay's consumer to 0 replicas (autoscaler-at-rest state)
#   2. create a queue-split-only PreviewSession against it
#      -> must go Ready, well under the old 120s target-pod wait
#   3. the workload env patch must exist (KAFKA_TOPIC_NAME -> mirrord-tmp-*)
#      even though there is no pod to roll
#   4. a message matching the filter (user_id=test-user) must reach the preview pod
#   5. a non-matching message waits on the fallback topic; scaling the consumer
#      back to 1 must produce a pod with the webhook-injected fallback env that
#      consumes it
#   6. deleting the session must restore the workload env
#
# Prerequisites:
#   - minikube (bearkube) with the kafka overlay: task kafka:deploy
#   - `task operator:dev` running from the operator checkout with the fix
#     (auto-detected; an explicit OPERATOR_ISOLATION_MARKER always wins)
#
# Usage:
#   ./test-preview-zero-pod-new.sh
#   KEEP=1 ./test-preview-zero-pod-new.sh    # leave everything running at the end
#
# Env knobs: NAMESPACE (test-mirrord), TOPIC (test-topic), READY_TIMEOUT (90),
#            OPERATOR_ISOLATION_MARKER (local-dev when operator:dev is detected)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The fix must beat the old 120s target-pod-readiness stall, so default tighter than the lib.
READY_TIMEOUT="${READY_TIMEOUT:-90}"
source "$SCRIPT_DIR/preview-zero-pod-lib.sh"

SESSION_NAME="${SESSION_NAME:-preview-zero-pod-new}"

banner "Zero-pod preview split vs a LOCAL operator:dev (new) operator" \
       "session: $SESSION_NAME  target: deploy/$CONSUMER_DEPLOY (0 replicas)"

resolve_marker() {
  # Same convention as the db-branching tasks: an explicit OPERATOR_ISOLATION_MARKER
  # always wins; otherwise detect a running `task operator:dev` process.
  if [ -n "${OPERATOR_ISOLATION_MARKER:-}" ]; then
    MARKER="$OPERATOR_ISOLATION_MARKER"
    ok "using explicit OPERATOR_ISOLATION_MARKER=$MARKER"
    return 0
  fi
  if pgrep -qf 'target/debug/operator-service'; then
    MARKER=local-dev
    ok "operator:dev detected -> labeling the session for marker '$MARKER'"
    return 0
  fi
  err "no local dev operator found: start 'task operator:dev' from the operator repo with the fix,"
  err "or export OPERATOR_ISOLATION_MARKER=<marker> to target a specific isolated operator"
  return 1
}

main() {
  preflight || return 1
  resolve_marker || return 1
  record_and_scale_to_zero || return 1

  # --- Session creation against a podless target -----------------------------
  say "Creating marker-labeled PreviewSession (reconciled by the local dev operator)"
  create_preview_session "$SESSION_NAME" "$MARKER" || return 1

  say "Waiting up to ${READY_TIMEOUT}s for Ready (old operators burn a 120s pod wait here)"
  wait_for_settled_phase "$SESSION_NAME" "$READY_TIMEOUT"
  case "$WAIT_PHASE" in
    Ready) ok "session Ready after ${WAIT_ELAPSED}s with zero target pods" ;;
    Failed)
      err "session Failed after ${WAIT_ELAPSED}s: $(session_failure_message "$SESSION_NAME")"
      err "is operator:dev running the branch with the zero-pod fix?"
      return 1
      ;;
    *)
      err "session did not settle within ${READY_TIMEOUT}s (last phase: ${WAIT_PHASE:-<none>})"
      [ -z "$WAIT_PHASE" ] && warn "no status at all - is the dev operator running with marker '$MARKER'?"
      return 1
      ;;
  esac

  # --- Workload patched without any pod to roll ------------------------------
  local patched
  patched=$(patched_topic_env)
  if [ -z "$patched" ]; then
    err "no workload patch sets KAFKA_TOPIC_NAME - the split did not patch the workload"
    return 1
  fi
  case "$patched" in
    mirrord-*) ok "workload patched: KAFKA_TOPIC_NAME -> $patched (applies to future pods)" ;;
    *) err "workload patch sets KAFKA_TOPIC_NAME to unexpected value '$patched'"; return 1 ;;
  esac

  # --- Matching message -> preview pod --------------------------------------
  local match_msg="zero-pod-match-$RUN_TAG"
  say "Sending a matching message (user_id=test-user): $match_msg"
  send_kafka_message "test-user" "$match_msg" || { err "failed to produce to kafka"; return 1; }
  if wait_for_log_line "$SESSION_NAME" "$match_msg" 60; then
    ok "preview pod received the matching message"
  else
    err "matching message never showed up in the preview pod logs (deploy/$SESSION_NAME)"
    return 1
  fi

  # --- Non-matching message survives until the target scales up -------------
  local nomatch_msg="zero-pod-nomatch-$RUN_TAG"
  say "Sending a non-matching message: $nomatch_msg (no consumer exists yet)"
  send_kafka_message "someone-else" "$nomatch_msg" || { err "failed to produce to kafka"; return 1; }

  say "Scaling $CONSUMER_DEPLOY back to 1 (the autoscaler reacting to lag)"
  scale_consumer 1 || return 1
  wait_for_consumer_pods 1 120 || return 1

  local pod_topic
  pod_topic=$(kubectl get pods -n "$NAMESPACE" -l "app=$CONSUMER_DEPLOY" \
    -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="KAFKA_TOPIC_NAME")].value}' 2>/dev/null)
  case "$pod_topic" in
    mirrord-*) ok "fresh consumer pod got the webhook-injected fallback topic: $pod_topic" ;;
    *) err "fresh consumer pod reads '$pod_topic' instead of a mirrord fallback topic"; return 1 ;;
  esac

  if wait_for_log_line "$CONSUMER_DEPLOY" "$nomatch_msg" 90; then
    ok "deployed consumer received the non-matching message after scale-up"
  else
    err "non-matching message never reached the deployed consumer (deploy/$CONSUMER_DEPLOY)"
    return 1
  fi

  # --- Teardown restores the env ---------------------------------------------
  if [ "$KEEP" = 1 ]; then
    warn "KEEP=1: skipping the teardown-restores-env check"
  else
    say "Deleting the session; the workload env must be restored"
    kubectl delete previewsession "$SESSION_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null
    wait_for_session_gone "$SESSION_NAME" 90 || return 1
    wait_for_unpatch 90 || return 1
    ok "workload unpatched after session deletion"
  fi

  verdict pass \
    "Zero-pod queue-split preview works end to end on the new operator:" \
    "Ready in ${WAIT_ELAPSED}s with 0 target pods, filtered routing verified," \
    "scale-up picked up the fallback env, teardown restored it."
}

rc=0
main || rc=1
cleanup_scenario "$SESSION_NAME"
exit "$rc"
