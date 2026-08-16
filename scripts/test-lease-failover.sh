#!/usr/bin/env bash
# Verifies the leadership lease rework: the lease is released on graceful
# shutdown, reclaimed after a container crash in the same pod, and handed over
# to a standby in seconds instead of the old 30-60s (or 120s after a crash).
#
# Scenarios (verdict each, exit code = number of failures):
#
#   A. standby-handover   - 2 replicas, delete the LEADER pod: the standby must
#                           hold the lease and carry the leader label within
#                           30s (drain + release). Old behavior: 30-60s GC wait
#                           collection.
#   B. crash-reclaim      - overwrite the lease holder with a ghost id: the
#                           leader notices within ~2s, error-exits, and the
#                           SAME pod's restarted container must reclaim the
#                           lease (owner reference check) within 45s. Old
#                           behavior: up to 120s waiting for the ghost to
#                           expire.
#   C. graceful-release   - scale the operator to 0: the lease must be left
#                           with NO holder (or deleted by garbage collection)
#                           within 30s (after the task drain). Old behavior: set until
#                           expiry.
#   D. rollout-downtime   - rollout restart while probing the operator API
#                           twice a second: total downtime must stay under 20s
#                           (expected a few seconds). The upgrade experience.
#
# Prereqs: an operator built from the branch with the lease rework, deployed in
# the "mirrord" namespace. Run nothing else against the operator meanwhile.
#
# Usage:
#   ./scripts/test-lease-failover.sh                # briefs pause for Enter
#   NO_PAUSE=1 ./scripts/test-lease-failover.sh     # no pauses
#   CTX=my-context ./scripts/test-lease-failover.sh # explicit kube context
set -uo pipefail

NS="mirrord"
DEPLOY="mirrord-operator"
LEASE="mirrord-operator-leader"
FAILURES=0

if [ -z "${CTX:-}" ]; then
  if kubectl config get-contexts mirrord-primary >/dev/null 2>&1; then
    CTX="mirrord-primary"
  else
    CTX="$(kubectl config current-context)"
  fi
fi

k() { kubectl --context "$CTX" "$@"; }

log() { echo "[$(date +%H:%M:%S)] $*"; }

verdict() { # verdict <name> <0|1> <detail>
  if [ "$2" -eq 0 ]; then
    log "✅ $1: $3"
  else
    log "❌ $1: $3"
    FAILURES=$((FAILURES + 1))
  fi
}

brief() { # boxed explanation of the next scenario; Enter to continue on a tty
  echo
  echo "┌──────────────────────────────────────────────────────────────────────"
  while [ $# -gt 0 ]; do echo "│ $1"; shift; done
  echo "└──────────────────────────────────────────────────────────────────────"
  if [ -t 0 ] && [ -z "${NO_PAUSE:-}" ]; then
    read -r -p "Press Enter to run this scenario... "
  fi
}

holder() { k get lease "$LEASE" -n "$NS" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }

leader_pod() {
  k get pods -n "$NS" -l mirrord-operator-leader=true \
    --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -1
}

pod_restarts() { # pod_restarts <pod>
  k get pod "$1" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0
}

api_ok() { k get mirrordoperators operator -o name >/dev/null 2>&1; }

replicas() { k get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1; }

scale_and_wait() { # scale_and_wait <n>
  k scale deploy "$DEPLOY" -n "$NS" --replicas="$1" >/dev/null
  if [ "$1" -gt 0 ]; then
    k rollout status deploy "$DEPLOY" -n "$NS" --timeout=180s >/dev/null 2>&1
  fi
}

wait_for() { # wait_for <timeout_s> <check-fn...> -> sets ELAPSED, returns 0/1
  local timeout="$1" start="$SECONDS"
  shift
  while true; do
    if "$@"; then ELAPSED=$((SECONDS - start)); return 0; fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then ELAPSED=$((SECONDS - start)); return 1; fi
    sleep 1
  done
}

# ── Preflight ────────────────────────────────────────────────────────────────
log "context: $CTX"
k get deploy "$DEPLOY" -n "$NS" >/dev/null 2>&1 || { echo "operator deployment not found on $CTX"; exit 1; }
IMAGE=$(k get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
GRACE=$(k get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')
log "operator image: $IMAGE (terminationGracePeriodSeconds: ${GRACE:-<default 30>})"
case "$IMAGE" in
  *custom*) : ;;
  *) log "WARNING: image does not look like a local build - old operators FAIL these scenarios" ;;
esac
ORIGINAL_REPLICAS=$(replicas)
restore() { scale_and_wait "$ORIGINAL_REPLICAS"; }
trap restore EXIT

# ── A. standby-handover ─────────────────────────────────────────────────────
brief \
  "A. standby-handover" \
  "   Scale to 2 replicas, then delete the LEADER pod." \
  "   Watch for: the dying pod logs 'Released the leadership lease', and the" \
  "   OTHER pod takes the lease + leader label within 30 seconds (the dying leader drains its tasks first)." \
  "   Old behavior: the standby waited 30-60s for pod garbage collection."

scale_and_wait 2
OLD_LEADER=$(leader_pod)
if [ -z "$OLD_LEADER" ]; then
  verdict "standby-handover" 1 "no leader pod found before the test"
else
  log "leader is $OLD_LEADER - deleting it"
  START=$SECONDS
  k delete pod "$OLD_LEADER" -n "$NS" --wait=false >/dev/null
  new_leader_up() { local l; l=$(leader_pod); [ -n "$l" ] && [ "$l" != "$OLD_LEADER" ]; }
  if wait_for 60 new_leader_up; then
    TOOK=$((SECONDS - START))
    # The dying leader drains its tasks (up to 15s) before releasing, so the
    # ceiling is drain + release + standby poll; idle operators hand over in seconds.
    if [ "$TOOK" -le 30 ]; then
      verdict "standby-handover" 0 "new leader $(leader_pod) in ${TOOK}s"
    else
      verdict "standby-handover" 1 "took ${TOOK}s (expected under 30s - lease probably not released)"
    fi
  else
    verdict "standby-handover" 1 "no new leader within 60s"
  fi
fi

# ── B. crash-reclaim ────────────────────────────────────────────────────────
brief \
  "B. crash-reclaim" \
  "   Overwrite the lease holder with a ghost id (valid for the full 120s)." \
  "   Watch for: the leader logs 'Leader election failed' and exits; the SAME" \
  "   pod restarts (RESTARTS +1) and logs 'Reclaiming the leadership lease'," \
  "   then holds it again - all within 45 seconds." \
  "   Old behavior: the restarted container waited up to 120s for the ghost" \
  "   holder to expire."

LEADER=$(leader_pod)
if [ -z "$LEADER" ]; then
  verdict "crash-reclaim" 1 "no leader pod found before the test"
else
  RESTARTS_BEFORE=$(pod_restarts "$LEADER")
  NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)
  log "leader is $LEADER (restarts: $RESTARTS_BEFORE) - writing ghost holder"
  START=$SECONDS
  k patch lease "$LEASE" -n "$NS" --type merge \
    -p "{\"spec\":{\"holderIdentity\":\"ghost-instance\",\"renewTime\":\"$NOW\"}}" >/dev/null
  reclaimed() {
    [ "$(leader_pod)" = "$LEADER" ] \
      && [ "$(pod_restarts "$LEADER")" -gt "$RESTARTS_BEFORE" ] \
      && [ "$(holder)" != "ghost-instance" ] && [ -n "$(holder)" ]
  }
  if wait_for 90 reclaimed; then
    TOOK=$((SECONDS - START))
    if [ "$TOOK" -le 45 ]; then
      verdict "crash-reclaim" 0 "same pod restarted and reclaimed in ${TOOK}s"
    else
      verdict "crash-reclaim" 1 "took ${TOOK}s (expected under 45s - reclaim probably missing)"
    fi
    k logs -n "$NS" "$LEADER" 2>/dev/null | grep -i "Reclaiming the leadership lease" >/dev/null \
      && log "   log line confirmed: 'Reclaiming the leadership lease...'" \
      || log "   note: reclaim log line not found (log may have rotated)"
  else
    verdict "crash-reclaim" 1 "pod did not reclaim within 90s (holder: $(holder))"
  fi
fi

# ── C. graceful-release ─────────────────────────────────────────────────────
brief \
  "C. graceful-release" \
  "   Scale the operator to 0." \
  "   Watch for: the lease holder becomes EMPTY (or the lease disappears)" \
  "   within 30 seconds (after the task drain) - that empty holder is the release." \
  "   Old behavior: the dead process's id stayed on the lease until expiry."

log "scaling $DEPLOY to 0"
START=$SECONDS
k scale deploy "$DEPLOY" -n "$NS" --replicas=0 >/dev/null
released() {
  local h
  h=$(holder)
  [ -z "$h" ]
}
if wait_for 40 released; then
  TOOK=$((SECONDS - START))
  if [ "$TOOK" -le 30 ]; then
    verdict "graceful-release" 0 "holder cleared in ${TOOK}s"
  else
    verdict "graceful-release" 1 "took ${TOOK}s (expected under 30s)"
  fi
else
  verdict "graceful-release" 1 "holder still '$(holder)' after 40s"
fi
log "scaling back to $ORIGINAL_REPLICAS"
scale_and_wait "$ORIGINAL_REPLICAS"

# ── D. rollout-downtime ─────────────────────────────────────────────────────
brief \
  "D. rollout-downtime" \
  "   Rollout-restart the operator while probing its API twice a second." \
  "   Watch for: total API downtime under 20 seconds (a few when idle)." \
  "   This is what a customer upgrade feels like. Old behavior: 30-60s."

PROBE_LOG=$(mktemp /tmp/lease-probe.XXXXXX)
probe() {
  while true; do
    if api_ok; then echo OK; else echo DOWN; fi >> "$PROBE_LOG"
    sleep 0.5
  done
}
probe &
PROBE_PID=$!
sleep 2
log "rollout restart"
k rollout restart deploy "$DEPLOY" -n "$NS" >/dev/null
k rollout status deploy "$DEPLOY" -n "$NS" --timeout=180s >/dev/null 2>&1
# let the API settle and the probe catch the tail
sleep 5
kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null
DOWN_SAMPLES=$(grep -c DOWN "$PROBE_LOG" || true)
DOWNTIME=$(( DOWN_SAMPLES / 2 ))
if [ "$DOWN_SAMPLES" -le 40 ]; then
  verdict "rollout-downtime" 0 "~${DOWNTIME}s of API downtime ($DOWN_SAMPLES samples of 0.5s)"
else
  verdict "rollout-downtime" 1 "~${DOWNTIME}s of API downtime (expected under 20s)"
fi
rm -f "$PROBE_LOG"

# ── Summary ─────────────────────────────────────────────────────────────────
echo
log "Failures: $FAILURES"
exit "$FAILURES"
