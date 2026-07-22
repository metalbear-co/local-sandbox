#!/usr/bin/env bash
# Proves the copy-target restart fix (operator: CopyState::mark_as_orphaned on
# creator-session 404 during recovery), reconstructing the customer report:
# Ctrl-C a copy_target+scale_down session, restart quickly, and the new run
# either died with "no response received from agent connection during agent
# version check" or came up without traffic, until the operator advertised a
# stale copy target as Ready long after its session was gone.
#
# Scenarios (verdict each, exit code = number of failures):
#
#   1. cooldown-restart  - the customer flow: session up (traffic proven local),
#                          Ctrl-C, wait RESTART_DELAY (default 40s, inside the
#                          old zombie window), restart. Must come up serving
#                          local traffic on a FRESH copy pod, with no
#                          version-check error, and the deployment must scale
#                          back up after the final Ctrl-C.
#   2. orphan-recovery   - THE deterministic regression proof. The customer hit
#                          a window where k8s GC lagged ~60s behind session
#                          deletion; local clusters GC too fast to reproduce it
#                          naturally, so we manufacture the lag by stripping the
#                          copy pod's ownerReferences before Ctrl-C. The
#                          operator's in-memory state expires ~30s later, the
#                          pod controller re-recovers the pod from its
#                          annotation, and the creator session 404s:
#                            fixed operator  -> copy marked Failed, pod reaped
#                                               within ~60s, next session gets a
#                                               fresh copy
#                            broken operator -> pod survives forever, copytarget
#                                               stays Ready, next session REUSES
#                                               the zombie (same pod name)
#   3. immediate-restart - EXTENDED=1 only, informational (not counted): restart
#                          ~2s after Ctrl-C. The old session is still lingering,
#                          so the CLI reuses its copy target and the pod dies
#                          under the new session once GC catches up. This gap is
#                          CLI-side (retry-with-fresh-copy follow-up), not
#                          covered by the operator fix.
#
# Prereqs:
#   - sandbox cluster up, operator deployed (task operator:use) or operator:dev
#     running the fixed branch; whichever operator serves the sessions must stay
#     up for the whole run
#   - echo-app deployed in test-mirrord (auto-deployed unless SKIP_DEPLOY=1)
#   - no other mirrord sessions targeting echo-app while this runs
#
# Usage:
#   ./scripts/test-copy-target-restart.sh
#   EXTENDED=1 ./scripts/test-copy-target-restart.sh
#   RESTART_DELAY=90 ./scripts/test-copy-target-restart.sh
#
# To see the pre-fix behavior, run against a released operator
# (task operator:use VERSION=3.166.0): scenario 2 fails there.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="test-mirrord"
RESTART_DELAY="${RESTART_DELAY:-40}"
READY_TIMEOUT=120
ORPHAN_TIMEOUT=120
SCALE_RESTORE_TIMEOUT=180
LOGDIR="$(mktemp -d /tmp/copy-target-restart.XXXXXX)" || { echo "mktemp failed"; exit 1; }
CONFIG="$LOGDIR/copy-target.json"
FAILURES=0
CUSTOMER_ERROR="no response received from agent connection during agent version check"

# Session logs (mirrord CLI + local echo-app output) stream to $LOGDIR/session-*.log.
echo "Session logs: $LOGDIR"

# The sandbox keeps MIRRORD_BIN in .env (task reads it; plain shells do not).
if [ -z "${MIRRORD_BIN:-}" ] && [ -f "$ROOT/.env" ]; then
  MIRRORD_BIN=$(grep -E '^MIRRORD_BIN=' "$ROOT/.env" | tail -1 | cut -d= -f2-)
fi
MIRRORD_BIN="${MIRRORD_BIN:-$(command -v mirrord || true)}"
if [ -z "$MIRRORD_BIN" ] || [ ! -x "$MIRRORD_BIN" ]; then
  echo "mirrord CLI not found (set MIRRORD_BIN in .env or PATH)"; exit 1
fi

SESSION_PIDS=()
cleanup() {
  for pid in "${SESSION_PIDS[@]:-}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in "${SESSION_PIDS[@]:-}"; do
    kill -9 "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

verdict() { # verdict <name> <0|1> <detail>
  if [ "$2" -eq 0 ]; then
    echo "✅ $1: $3"
  else
    echo "❌ $1: $3"
    FAILURES=$((FAILURES + 1))
  fi
}

copy_pods() {
  kubectl get pods -n "$NS" --no-headers -o custom-columns=:metadata.name 2>/dev/null \
    | grep '^mirrord-copy-' || true
}

copytarget_phases() {
  kubectl get copytargets -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{" "}{end}' 2>/dev/null || true
}

deploy_replicas() {
  kubectl get deploy echo-app -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?"
}

cluster_curl() {
  kubectl exec -n "$NS" deploy/curl-client -- \
    curl -s --max-time 3 http://echo-app:8080/ 2>/dev/null || true
}

start_session() { # start_session <id>; sets SESSION_PID
  local id="$1"
  CLUSTER_ID="local-$id" PORT=8080 \
    "$MIRRORD_BIN" exec -f "$CONFIG" -- "$LOCAL_APP" \
    >"$LOGDIR/session-$id.log" 2>&1 &
  SESSION_PID=$!
  SESSION_PIDS+=("$SESSION_PID")
}

stop_session() { # stop_session <pid> - the Ctrl-C
  # SIGTERM, not SIGINT: children started with & in a non-interactive shell
  # ignore SIGINT (POSIX), so a scripted "Ctrl-C" must use TERM. The observable
  # teardown is identical - the process dies without notifying the operator.
  kill -TERM "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

wait_for_local() { # wait_for_local <id> -> 0 when cluster traffic reaches local-<id>
  local id="$1" deadline=$((SECONDS + READY_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if cluster_curl | grep -q "\"cluster_id\":\"local-$id\""; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# After the client dies the operator keeps its session OPEN ~35s awaiting a
# reconnect. A same-identity session started while the old one is still open is
# treated as a reconnect and rejected with 410 ReconnectNotPossible (the new
# run's session key differs). Scenarios must wait for the old session to close
# before starting the next one, or they fail on this unrelated quick-restart gap.
wait_reconnect_grace() {
  echo "waiting for the previous session to close (reconnect grace, 45s)..."
  sleep 45
}

# ── preflight ────────────────────────────────────────────────────────────────
kubectl cluster-info >/dev/null 2>&1 || { echo "cluster unreachable"; exit 1; }
kubectl get apiservice v1.operator.metalbear.co >/dev/null 2>&1 \
  || { echo "mirrord operator APIService missing (task operator:use)"; exit 1; }

if ! kubectl get deploy echo-app -n "$NS" >/dev/null 2>&1; then
  [ -n "${SKIP_DEPLOY:-}" ] && { echo "echo-app missing and SKIP_DEPLOY set"; exit 1; }
  echo "Deploying echo-app..."
  (cd "$ROOT" && task preview:deploy) || { echo "echo-app deploy failed"; exit 1; }
fi

# In-cluster prober: with scale_down the deployment is at 0, so requests must
# originate inside the cluster to hit the copy pod's stolen port.
if ! kubectl get deploy curl-client -n "$NS" >/dev/null 2>&1; then
  kubectl create deployment curl-client -n "$NS" --image=curlimages/curl -- sleep infinity
fi
kubectl wait --for=condition=available deploy/curl-client -n "$NS" --timeout=120s >/dev/null

# Local process for the sessions: the echo-app itself, so responses prove who answered.
LOCAL_APP="$LOGDIR/echo-app"
if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/apps/echo-app" && go build -o "$LOCAL_APP" .) || { echo "echo-app build failed"; exit 1; }
elif [ -x "$ROOT/apps/echo-app/echo-app" ]; then
  LOCAL_APP="$ROOT/apps/echo-app/echo-app"
else
  echo "need go or a prebuilt apps/echo-app/echo-app binary"; exit 1
fi

# A leftover session may have the deployment scaled to 0 right now; a baseline
# of 0 would make the scale-restore verdict vacuous. echo-app deploys with 1.
ORIGINAL_REPLICAS="$(deploy_replicas)"
if [ "$ORIGINAL_REPLICAS" = "0" ] || [ "$ORIGINAL_REPLICAS" = "?" ]; then
  ORIGINAL_REPLICAS=1
fi

cat >"$CONFIG" <<EOF
{
  "target": { "path": "deployment/echo-app", "namespace": "$NS" },
  "operator": true,
  "feature": {
    "copy_target": { "enabled": true, "scale_down": true },
    "network": { "incoming": { "mode": "steal" }, "outgoing": false, "dns": false },
    "env": false,
    "fs": "local",
    "hostname": false
  }
}
EOF

leftovers="$(copy_pods)"
if [ -n "$leftovers" ]; then
  echo "Deleting leftover copy pods from previous runs: $leftovers"
  echo "$leftovers" | xargs -n1 kubectl delete pod -n "$NS" --wait=false 2>/dev/null || true
  sleep 5
fi

# ── scenario 1: cooldown-restart (the customer flow) ─────────────────────────
echo ""
echo "── scenario 1: cooldown-restart (Ctrl-C, wait ${RESTART_DELAY}s, restart) ──"

start_session 1; pid1=$SESSION_PID
if wait_for_local 1; then
  copy1="$(copy_pods | head -1)"
  echo "session 1 serving locally via copy pod: $copy1 (replicas now: $(deploy_replicas))"
  stop_session "$pid1"
  echo "Ctrl-C sent; waiting ${RESTART_DELAY}s before restart..."
  sleep "$RESTART_DELAY"

  start_session 2; pid2=$SESSION_PID
  if wait_for_local 2; then
    copy2_all="$(copy_pods | tr '\n' ' ')"
    if grep -q "$CUSTOMER_ERROR" "$LOGDIR/session-2.log"; then
      verdict "cooldown-restart" 1 "restart hit the customer error: $CUSTOMER_ERROR"
    elif [ -n "$copy1" ] && copy_pods | grep -qvx "$copy1"; then
      verdict "cooldown-restart" 0 "restart serves local traffic on a fresh copy pod ($copy2_all)"
    else
      verdict "cooldown-restart" 1 "restart reused the old copy pod $copy1"
    fi
  else
    tail -5 "$LOGDIR/session-2.log"
    verdict "cooldown-restart" 1 "restarted session never served local traffic (see session-2.log)"
  fi
  stop_session "${pid2:-}"

  deadline=$((SECONDS + SCALE_RESTORE_TIMEOUT))
  restored=1
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(deploy_replicas)" = "$ORIGINAL_REPLICAS" ] && { restored=0; break; }
    sleep 5
  done
  verdict "scale-restore" "$restored" \
    "deployment back to $ORIGINAL_REPLICAS replicas after the last Ctrl-C (now: $(deploy_replicas))"
else
  tail -5 "$LOGDIR/session-1.log"
  verdict "cooldown-restart" 1 "baseline session never served local traffic (see session-1.log)"
  stop_session "$pid1"
fi

# ── scenario 2: orphan-recovery (deterministic proof of the operator fix) ────
echo ""
echo "── scenario 2: orphan-recovery (manufactured GC lag) ──"

wait_reconnect_grace
start_session 3; pid3=$SESSION_PID
if wait_for_local 3; then
  copy3="$(copy_pods | head -1)"
  echo "session 3 serving locally via copy pod: $copy3"

  # Manufacture the customer's GC lag: without owner references, deleting the
  # session CR no longer deletes the pod, exactly like slow GC left it alive.
  kubectl patch pod "$copy3" -n "$NS" --type=json \
    -p '[{"op":"remove","path":"/metadata/ownerReferences"}]' >/dev/null
  stop_session "$pid3"
  echo "Ctrl-C sent; waiting for the operator to expire, re-recover, and reap the orphan..."

  deadline=$((SECONDS + ORPHAN_TIMEOUT))
  reaped=1
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! copy_pods | grep -qx "$copy3"; then reaped=0; break; fi
    sleep 5
  done

  if [ "$reaped" -eq 0 ]; then
    verdict "orphan-reaped" 0 "zombie copy pod $copy3 deleted within ${ORPHAN_TIMEOUT}s"
  else
    verdict "orphan-reaped" 1 \
      "zombie copy pod $copy3 still alive after ${ORPHAN_TIMEOUT}s (copytargets: $(copytarget_phases)) - operator lacks the orphan fix"
    kubectl delete pod "$copy3" -n "$NS" --wait=false 2>/dev/null || true
  fi

  # Best-effort log probe; absent when the operator runs via operator:dev
  # (its logs stream to that terminal, not to kubectl).
  if kubectl logs -n mirrord deploy/mirrord-operator --since=5m 2>/dev/null \
    | grep -q "no longer exists"; then
    echo "   operator log confirms: creator session gone -> copy target failed"
  fi

  start_session 4; pid4=$SESSION_PID
  if wait_for_local 4; then
    if copy_pods | grep -qx "$copy3"; then
      verdict "fresh-after-orphan" 1 "new session reused the zombie pod $copy3"
    else
      verdict "fresh-after-orphan" 0 "new session got a fresh copy pod ($(copy_pods | tr '\n' ' '))"
    fi
  else
    tail -5 "$LOGDIR/session-4.log"
    verdict "fresh-after-orphan" 1 "session after orphan never served local traffic (see session-4.log)"
  fi
  stop_session "${pid4:-}"
else
  tail -5 "$LOGDIR/session-3.log"
  verdict "orphan-reaped" 1 "baseline session never served local traffic (see session-3.log)"
  stop_session "$pid3"
fi

# ── scenario 3 (EXTENDED): immediate-restart, informational only ─────────────
if [ -n "${EXTENDED:-}" ]; then
  echo ""
  echo "── scenario 3 (informational): immediate restart, known CLI-side gap ──"
  start_session 5; pid5=$SESSION_PID
  if wait_for_local 5; then
    copy5="$(copy_pods | head -1)"
    stop_session "$pid5"
    sleep 2
    start_session 6; pid6=$SESSION_PID
    if wait_for_local 6; then
      if copy_pods | grep -qx "$copy5"; then
        echo "ℹ️  immediate restart REUSED $copy5 (doomed once the old session is GC'd)"
        sleep 45
        if copy_pods | grep -qx "$copy5"; then
          echo "ℹ️  ...and the pod is still alive 45s in"
        else
          echo "ℹ️  ...and the pod died under the new session, as predicted (CLI follow-up needed)"
        fi
      else
        echo "ℹ️  immediate restart got a fresh copy pod (GC beat the reuse window on this cluster)"
      fi
    else
      if grep -q "$CUSTOMER_ERROR" "$LOGDIR/session-6.log"; then
        echo "ℹ️  immediate restart hit the customer error (CLI follow-up needed)"
      else
        echo "ℹ️  immediate restart never served local traffic (see session-6.log)"
      fi
    fi
    stop_session "${pid6:-}"
  else
    echo "ℹ️  baseline for immediate-restart never came up; skipping"
    stop_session "$pid5"
  fi
fi

echo ""
echo "Failures: $FAILURES (logs in $LOGDIR)"
exit "$FAILURES"
