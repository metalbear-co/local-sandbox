#!/usr/bin/env bash
# Verifies the reworked copy-target lifecycle (staleness-driven, controller-owned
# deletion, no owner refs, restart adoption). Traces every state change with
# timestamps so you can watch what the operator does at each step.
#
# Scenarios (verdict each, exit code = number of failures):
#
#   A. cleanup-after-stop - session up, Ctrl-C: the entry must leave
#                           `copytargets` and the pod must be deleted by the
#                           CONTROLLER within ~2min, deployment scaled back.
#                           (COR-1680: no more stuck entries, no operator
#                           restart needed.)
#   B. quick-restart      - restart ~45s after Ctrl-C (after the session close,
#                           before staleness): the new session must serve
#                           traffic. Reusing the previous pod here is CORRECT
#                           in the new design (nothing dooms the pod anymore) -
#                           the script logs whether it reused or built fresh.
#   C. fresh-copy-after-cleanup - restart long after staleness: must get a FRESH pod.
#   D. pod-deleted-mid-session - delete the copy pod mid-session (COR-1680's literal
#                           repro): entry goes Failed, then disappears from
#                           status and memory on its own within ~2.5min.
#   E. operator-restart   - INTERACTIVE (skipped when not a tty or
#                           SKIP_RESTART=1): kill the client, then YOU restart
#                           operator:dev; the new operator must adopt the
#                           leftover pod and reap it. This is the InstanceId
#                           gate removal working.
#
# Prereqs: cluster up, operator:dev running the reworked branch, echo-app
# deployed (auto-deployed unless SKIP_DEPLOY=1), no other mirrord sessions
# against echo-app.
#
# Usage:
#   ./scripts/test-copy-target-restart.sh
#   SKIP_RESTART=1 ./scripts/test-copy-target-restart.sh   # skip scenario E
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="test-mirrord"
IDLE_TTL=30          # spec default; staleness clock starts when the session closes
SESSION_CLOSE=35     # observed operator-side session linger after client death
READY_TIMEOUT=120
LOGDIR="$(mktemp -d /tmp/copy-target-lifecycle.XXXXXX)" || { echo "mktemp failed"; exit 1; }
CONFIG="$LOGDIR/copy-target.json"
TRACE="$LOGDIR/state-trace.log"
FAILURES=0

echo "Session logs and state trace: $LOGDIR"

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

log() { # timestamped narrator line, also into the trace file
  echo "[$(date +%H:%M:%S)] $*" | tee -a "$TRACE"
}

verdict() { # verdict <name> <0|1> <detail>
  if [ "$2" -eq 0 ]; then
    log "✅ $1: $3"
  else
    log "❌ $1: $3"
    FAILURES=$((FAILURES + 1))
  fi
}

copy_pods() {
  kubectl get pods -n "$NS" --no-headers -o custom-columns=:metadata.name 2>/dev/null \
    | grep '^mirrord-copy-' || true
}

newest_copy_pod() { # leftovers from earlier sessions may coexist; take the newest
  kubectl get pods -n "$NS" --sort-by=.metadata.creationTimestamp -o name 2>/dev/null \
    | grep mirrord-copy | tail -1 | cut -d/ -f2
}

copytargets() {
  kubectl get copytargets -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{" "}{end}' 2>/dev/null || true
}

deploy_replicas() {
  kubectl get deploy echo-app -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?"
}

snapshot() { # one trace line with the full observable state
  log "   state: pods=[$(copy_pods | tr '\n' ' ')] copytargets=[$(copytargets)] replicas=$(deploy_replicas)"
}

cluster_curl() {
  kubectl exec -n "$NS" deploy/curl-client -- \
    curl -s --max-time 3 http://echo-app:8080/ 2>/dev/null || true
}

start_session() { # start_session <id>; sets SESSION_PID
  local id="$1"
  log "starting session $id (mirrord exec, copy_target+scale_down)"
  CLUSTER_ID="local-$id" PORT=8080 \
    "$MIRRORD_BIN" exec -f "$CONFIG" -- "$LOCAL_APP" \
    >"$LOGDIR/session-$id.log" 2>&1 &
  SESSION_PID=$!
  SESSION_PIDS+=("$SESSION_PID")
}

stop_session() { # scripted Ctrl-C (TERM: &-children ignore INT in non-interactive shells)
  log "killing the client (Ctrl-C equivalent)"
  kill -TERM "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

wait_for_local() { # wait_for_local <id> -> 0 when cluster traffic reaches local-<id>
  local id="$1" deadline=$((SECONDS + READY_TIMEOUT)) reply
  while [ "$SECONDS" -lt "$deadline" ]; do
    reply="$(cluster_curl)"
    if echo "$reply" | grep -q "\"cluster_id\":\"local-$id\""; then
      # show the actual response: a request sent to the in-cluster service,
      # answered by the LOCAL process (cluster_id proves who replied)
      log "   traffic proof: request to echo-app.$NS answered by the local app: $(echo "$reply" | head -1 | cut -c1-140)"
      return 0
    fi
    sleep 3
  done
  return 1
}

# watch_until <what> <timeout_s> <check-fn> -> 0 on success; snapshots every poll
watch_until() {
  local what="$1" timeout="$2" check="$3" t0=$SECONDS
  log "waiting for: $what (up to ${timeout}s)"
  while [ $((SECONDS - t0)) -lt "$timeout" ]; do
    if "$check"; then
      log "   -> $what after $((SECONDS - t0))s"
      return 0
    fi
    snapshot
    sleep 10
  done
  log "   -> TIMEOUT (${timeout}s) waiting for: $what"
  return 1
}

no_copy_pods() { [ -z "$(copy_pods)" ]; }
no_copytargets() { [ -z "$(copytargets)" ]; }
replicas_restored() { [ "$(deploy_replicas)" = "1" ]; }
fully_clean() { no_copy_pods && no_copytargets && replicas_restored; }

# A dead client's session lingers awaiting reconnect, and even a CLOSED session
# CR blocks a new same-identity session (the operator finds the closed CR under
# the same deterministic session id and answers 410 ReconnectNotPossible instead
# of starting fresh - tracked as the quick-restart gap). Only the CR's deletion
# unblocks, so wait until no session CR remains at all.
session_crs() {
  kubectl get mirrordclustersessions --no-headers 2>/dev/null | grep -c . || true
}

wait_reconnect_grace() {
  local deadline=$((SECONDS + 180))
  log "waiting until no session CR remains (reconnect grace + closed-CR cleanup)..."
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(session_crs)" = "0" ]; then
      log "   -> no session CRs"
      sleep 5
      return 0
    fi
    sleep 5
  done
  log "   -> WARN: session CRs still present after 180s; continuing anyway"
}

# brief <title>  (body from stdin): explains the upcoming scenario in the
# terminal - the steps it will take and what the runner should look for -
# then waits for Enter on a tty (NO_PAUSE=1 skips the pause).
brief() {
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────────"
  echo "│ NEXT: $1"
  echo "├─────────────────────────────────────────────────────────────────────"
  sed 's/^/│ /'
  echo "└─────────────────────────────────────────────────────────────────────"
  if [ -t 0 ] && [ -z "${NO_PAUSE:-}" ]; then
    read -rp ">>> Press Enter to run this scenario... "
  fi
}

# ── preflight ────────────────────────────────────────────────────────────────
kubectl cluster-info >/dev/null 2>&1 || { echo "cluster unreachable"; exit 1; }
kubectl get apiservice v1.operator.metalbear.co >/dev/null 2>&1 \
  || { echo "mirrord operator APIService missing"; exit 1; }
pgrep -qf "target/debug/operator-service" \
  || log "note: no operator:dev process - assuming the DEPLOYED operator runs the build under test"

if ! kubectl get deploy echo-app -n "$NS" >/dev/null 2>&1; then
  [ -n "${SKIP_DEPLOY:-}" ] && { echo "echo-app missing and SKIP_DEPLOY set"; exit 1; }
  log "deploying echo-app..."
  (cd "$ROOT" && task preview:deploy) || { echo "echo-app deploy failed"; exit 1; }
fi

if ! kubectl get deploy curl-client -n "$NS" >/dev/null 2>&1; then
  kubectl create deployment curl-client -n "$NS" --image=curlimages/curl -- sleep infinity
fi
kubectl wait --for=condition=available deploy/curl-client -n "$NS" --timeout=120s >/dev/null

LOCAL_APP="$LOGDIR/echo-app"
if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/apps/echo-app" && go build -o "$LOCAL_APP" .) || { echo "echo-app build failed"; exit 1; }
elif [ -x "$ROOT/apps/echo-app/echo-app" ]; then
  LOCAL_APP="$ROOT/apps/echo-app/echo-app"
else
  echo "need go or a prebuilt apps/echo-app/echo-app binary"; exit 1
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
  log "deleting leftover copy pods: $leftovers"
  echo "$leftovers" | xargs -n1 kubectl delete pod -n "$NS" --wait=false 2>/dev/null || true
  kubectl scale deploy echo-app -n "$NS" --replicas=1 >/dev/null 2>&1 || true
  sleep 5
fi

# ── scenario A: lifecycle-gc (COR-1680: nothing sticks, no restart needed) ───
brief "scenario A: cleanup after a normal stop (COR-1680 core)" <<'EOF'
Steps: start a session (copy_target+scale_down), confirm traffic reaches the
local process, then stop the client (like Ctrl-C).
What should happen after the stop:
  ~35-50s  the operator notices the client is gone and closes the session
  ~65-90s  the copy target disappears from the list AND the operator itself
           deletes the copy pod (nothing else deletes it - this is the operator's job now)
  <150s    echo-app is scaled back to 1 replica; everything is clean,
           WITHOUT restarting the operator
FAIL looks like: the copy target is still listed after ~2min (the old
stuck-forever bug).
EOF
log ""
log "── scenario A: cleanup after a normal stop ──"
start_session A; pidA=$SESSION_PID
if wait_for_local A; then
  podA="$(newest_copy_pod)"
  log "session A serving locally via $podA"; snapshot
  stop_session "$pidA"
  # session closes ~35s after the kill, staleness idle_ttl later; controller
  # deletes the pod and the status hides the entry; memory entry removed
  # ~60s after that. End-to-end budget: generous 150s.
  if watch_until "entry gone from copytargets AND pod deleted AND replicas restored" 150 fully_clean; then
    verdict "cleanup-after-stop" 0 "copy fully cleaned up by the operator alone (no restart)"
  else
    snapshot
    verdict "cleanup-after-stop" 1 "something is stuck: pods=[$(copy_pods | tr '\n' ' ')] copytargets=[$(copytargets)] replicas=$(deploy_replicas)"
  fi
else
  tail -5 "$LOGDIR/session-A.log" | tee -a "$TRACE"
  verdict "cleanup-after-stop" 1 "baseline session never served local traffic (see session-A.log)"
  stop_session "$pidA"
fi

# ── scenario B: reuse-window (restart between session close and staleness) ──
brief "scenario B: quick restart (before the old copy times out)" <<'EOF'
Steps: session up, stop the client, start again 45s later - after the session
closed but before the old copy's unused-timeout runs out. In the new design it
is OK for the new session to pick up the previous copy pod (it is healthy and
nothing will delete it under us anymore).
One of three outcomes is fine:
  SAME pod picked up + traffic works    -> best case
  NEW pod built + traffic works         -> timing ran past the timeout, also fine
  410 "failed to reconnect"             -> the KNOWN quick-restart problem
                                           (separate ticket, session handling,
                                           not this PR) - logged as pass-with-note
FAIL looks like: any other error, or traffic never works again.
EOF
log ""
log "── scenario B: quick restart ──"
wait_reconnect_grace
start_session B1; pidB1=$SESSION_PID
if wait_for_local B1; then
  podB1="$(newest_copy_pod)"
  log "session B1 serving via $podB1"
  stop_session "$pidB1"
  log "starting again in 45s - after the session closed, before the old copy times out"
  sleep 45
  start_session B2; pidB2=$SESSION_PID
  if wait_for_local B2; then
    podB2="$(newest_copy_pod)"
    if [ "$podB2" = "$podB1" ]; then
      verdict "quick-restart" 0 "picked up the same pod $podB1 and traffic works (allowed in the new design)"
    else
      verdict "quick-restart" 0 "built a new pod $podB2 and traffic works (also fine - timing)"
    fi
  elif grep -qE "failed to reconnect|ReconnectNotPossible" "$LOGDIR/session-B2.log"; then
    # The CLI used to send the old session's id when reusing a copy, and the
    # operator refused to "reconnect" to a closed session. Fixed in mirrord OSS
    # (reused copies connect as a NEW session) - a 410 here means MIRRORD_BIN is
    # built without that fix.
    verdict "quick-restart" 1 "410 on quick restart - rebuild the mirrord CLI with the reused-copy session fix (MIRRORD_BIN=$MIRRORD_BIN)"
  else
    tail -5 "$LOGDIR/session-B2.log" | tee -a "$TRACE"
    verdict "quick-restart" 1 "restart never got traffic working again"
  fi
  stop_session "${pidB2:-}"
else
  tail -5 "$LOGDIR/session-B1.log" | tee -a "$TRACE"
  verdict "quick-restart" 1 "baseline session never served local traffic"
  stop_session "$pidB1"
fi

# ── scenario C: fresh-after-stale ────────────────────────────────────────────
brief "scenario C: restart after full cleanup" <<'EOF'
Steps: wait until the previous copy is completely cleaned up (unlisted and
pod deleted), then start a new session.
What should happen: a copy pod with a NEW name is created and traffic works.
FAIL looks like: the old pod name showing up again after it was cleaned up.
EOF
log ""
log "── scenario C: restart after full cleanup ──"
lastpod="$(newest_copy_pod)"
log "waiting until the previous copy (${lastpod:-none}) is fully cleaned up..."
watch_until "previous copy cleaned up" 150 fully_clean || true
start_session C; pidC=$SESSION_PID
if wait_for_local C; then
  podC="$(newest_copy_pod)"
  if [ -n "$lastpod" ] && [ "$podC" = "$lastpod" ]; then
    verdict "fresh-copy-after-cleanup" 1 "restart after cleanup picked up the OLD pod $lastpod - should be impossible"
  else
    verdict "fresh-copy-after-cleanup" 0 "restart after cleanup built a new pod ($podC)"
  fi
else
  tail -5 "$LOGDIR/session-C.log" | tee -a "$TRACE"
  verdict "fresh-copy-after-cleanup" 1 "session never served local traffic"
fi
stop_session "${pidC:-}"

# ── scenario D: pod deleted mid-session (COR-1680 literal repro) ─────────────
brief "scenario D: copy pod deleted while the session runs (COR-1680 repro)" <<'EOF'
Steps: session up and serving, then the script DELETES the copy pod while the
session is still using it (the exact steps from the customer ticket).
What should happen:
  - the copy target shows as Failed ("copied pod is being deleted")
  - the client errors out (expected - its pod is gone)
  - after the session closes, the Failed copy target disappears from the list
    on its own; everything clean well under 3min, WITHOUT restarting the operator
FAIL looks like: the Failed copy target still listed after ~3min (the customer
had it stuck for 14h and only an operator restart cleared it).
EOF
log ""
log "── scenario D: copy pod deleted mid-session ──"
wait_reconnect_grace
start_session D; pidD=$SESSION_PID
if wait_for_local D; then
  podD="$(newest_copy_pod)"
  log "deleting the copy pod $podD out from under the live session"
  kubectl delete pod "$podD" -n "$NS" --wait=false >/dev/null
  # the client is expected to die; what we assert is the OPERATOR's cleanup
  if watch_until "Failed entry aged out of copytargets, everything clean" 180 fully_clean; then
    verdict "pod-deleted-mid-session" 0 "Failed copy target cleaned up on its own, no operator restart (COR-1680)"
  else
    snapshot
    verdict "pod-deleted-mid-session" 1 "copy target still stuck after pod deletion: copytargets=[$(copytargets)]"
  fi
  log "client outcome (expected to error out): $(tail -2 "$LOGDIR/session-D.log" | head -1 | cut -c1-120)"
else
  tail -5 "$LOGDIR/session-D.log" | tee -a "$TRACE"
  verdict "pod-deleted-mid-session" 1 "baseline session never served local traffic"
fi
stop_session "${pidD:-}" 2>/dev/null || true

# ── scenario E: restart-adoption (interactive) ───────────────────────────────
if [ -t 0 ] && [ -z "${SKIP_RESTART:-}" ]; then
  brief "scenario E: operator restart with a leftover copy pod (interactive)" <<'EOF'
Steps: session up, stop the client, then the script asks YOU to restart the
operator (deployed image: kubectl rollout restart deploy/mirrord-operator
-n mirrord; operator:dev: Ctrl-C it and rerun task operator:dev).
What should happen after the restart:
  - operator log shows "Recovering CopyTarget ..." - the new operator finds
    the leftover pod and takes it over (the old code ignored such pods forever)
  - since no session uses it, the new operator deletes it; clean within ~3min
FAIL looks like: the pod still Running 3min after the restart - that is the
old leak (we saw one live 11 hours on the previous code).
EOF
  log ""
  log "── scenario E: operator restart with a leftover pod ──"
  wait_reconnect_grace
  start_session E; pidE=$SESSION_PID
  if wait_for_local E; then
    podE="$(newest_copy_pod)"
    log "session E serving via $podE"
    stop_session "$pidE"
    echo ""
    echo ">>> ACTION REQUIRED: restart the operator NOW."
    echo ">>>   deployed image:  kubectl rollout restart deploy/mirrord-operator -n mirrord"
    echo ">>>   operator:dev:    Ctrl-C it and rerun 'task operator:dev'"
    echo ">>> Press Enter here once it is back up..."
    read -r
    log "operator restarted by user; the new process must ADOPT $podE and reap it"
    if watch_until "leftover pod $podE deleted by the restarted operator" 180 fully_clean; then
      verdict "operator-restart" 0 "restarted operator found the leftover pod and deleted it"
    else
      snapshot
      verdict "operator-restart" 1 "pod survived the operator restart - the new operator never took it over"
      kubectl delete pod "$podE" -n "$NS" --wait=false 2>/dev/null || true
    fi
  else
    tail -5 "$LOGDIR/session-E.log" | tee -a "$TRACE"
    verdict "operator-restart" 1 "baseline session never served local traffic"
    stop_session "$pidE"
  fi
else
  log ""
  log "scenario E (operator restart) skipped: interactive tty required (or SKIP_RESTART=1 set)"
fi

log ""
log "Failures: $FAILURES  (full trace: $TRACE)"
exit "$FAILURES"
