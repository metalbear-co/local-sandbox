#!/usr/bin/env bash
#
# Zero-pod preview split, OLD operator side of the A/B:
# runs the scenario against the operator DEPLOYED in the cluster (the session is
# created without an ownership label, so the in-cluster operator reconciles it even
# while `task operator:dev` is running).
#
# Scenario: scale the kafka overlay's consumer to 0 replicas, then create a
# queue-split-only PreviewSession against it.
#
# Expected with a pre-fix operator (<= 3.193.0): the session goes Failed within
# seconds with "no Pod is ready to be a session target: no pods found".
# If it goes Ready instead, the deployed operator already carries the zero-pod fix.
#
# Prerequisites:
#   - minikube (bearkube) with the kafka overlay: task kafka:deploy
#   - deployed operator chart with operator.previewEnv=true and kafkaSplitting=true
#
# Usage:
#   ./test-preview-zero-pod-old.sh
#   KEEP=1 ./test-preview-zero-pod-old.sh    # leave the session + scaled-down consumer around
#
# Env knobs: NAMESPACE (test-mirrord), TOPIC (test-topic), READY_TIMEOUT (120)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/preview-zero-pod-lib.sh"

SESSION_NAME="${SESSION_NAME:-preview-zero-pod-old}"

banner "Zero-pod preview split vs the DEPLOYED (old) operator" \
       "session: $SESSION_NAME  target: deploy/$CONSUMER_DEPLOY (0 replicas)"

main() {
  preflight || return 1

  local deployed_tag
  deployed_tag=$(kubectl get deploy mirrord-operator -n mirrord \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  say "Deployed operator image: ${deployed_tag:-unknown}"

  record_and_scale_to_zero || return 1

  say "Creating unlabeled PreviewSession (reconciled by the deployed operator)"
  create_preview_session "$SESSION_NAME" "" || return 1

  say "Waiting up to ${READY_TIMEOUT}s for the session to settle"
  wait_for_settled_phase "$SESSION_NAME" "$READY_TIMEOUT"

  local phase="$WAIT_PHASE" elapsed="$WAIT_ELAPSED" failure
  failure=$(session_failure_message "$SESSION_NAME")

  case "$phase" in
    Failed)
      if printf '%s' "$failure" | grep -q "no Pod is ready"; then
        ok "session Failed after ${elapsed}s with the expected target-resolution error"
        verdict pass \
          "Old operator behaves as documented: a queue-split-only preview against a" \
          "zero-replica target is rejected at target resolution." \
          "failureMessage: $failure"
      else
        err "session Failed after ${elapsed}s, but not on target resolution"
        verdict fail "Unexpected failure: ${failure:-<no failureMessage>}"
        return 1
      fi
      ;;
    Ready)
      warn "session went Ready after ${elapsed}s - the deployed operator already has the zero-pod fix"
      verdict pass \
        "The deployed operator supports zero-pod queue-split previews." \
        "Run test-preview-zero-pod-new.sh for the full message-flow verification."
      ;;
    *)
      err "session did not settle within ${READY_TIMEOUT}s (last phase: ${phase:-<none>})"
      [ -z "$phase" ] && warn "no status at all - is the deployed operator running with previewEnv=true?"
      verdict fail "Session stuck; inspect: kubectl describe previewsession $SESSION_NAME -n $NAMESPACE"
      return 1
      ;;
  esac
}

rc=0
main || rc=1
cleanup_scenario "$SESSION_NAME"
exit "$rc"
