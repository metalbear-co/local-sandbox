#!/usr/bin/env bash
# Copy-target lifecycle tests for MULTICLUSTER setups. Works with both
# topologies (set MC_NUM_CLUSTERS, same variable as `task multicluster:up`):
#
#   MC_NUM_CLUSTERS=2: primary + remote-1. Copy pods live on the PRIMARY
#     (it is the "default cluster"), so the operator's own controller manages
#     them: cleanup on a timer, reuse allowed, pickup after operator restart.
#   MC_NUM_CLUSTERS=3: management-only primary + remote-1 (default) + remote-2.
#     Copy pods live on REMOTE-1, another cluster than the operator. They are
#     cleaned through the session owner reference instead of the controller,
#     and REUSE IS DELIBERATELY DISABLED (the served spec carries idle_ttl=0
#     so the CLI's spec comparison never matches).
#
# Scenarios (verdict each, exit code = number of failures):
#   A. cleanup-after-stop      - stop the client, everything cleans up on its own
#   B. quick-restart           - start again ~45s after stopping:
#                                  2 clusters: same pod picked up OR fresh - both fine
#                                  3 clusters: MUST be a fresh pod (reuse disabled)
#   C. fresh-copy-after-cleanup- restart after full cleanup builds a new pod
#   D. pod-deleted-mid-session - delete the copy pod under a live session,
#                                the Failed entry must clean up on its own
#   E. operator-restart        - INTERACTIVE: restart the PRIMARY operator;
#                                  2 clusters: new operator finds and deletes the pod
#                                  3 clusters: pod goes away via the session record
#                                  cleanup (may take longer, but must go away)
#
# Prereqs: `task multicluster:up` done for the chosen MC_NUM_CLUSTERS, no other
# mirrord sessions against echo-app.
#
# Usage:
#   ./scripts/test-copy-target-multicluster.sh                  # 2 clusters
#   MC_NUM_CLUSTERS=3 ./scripts/test-copy-target-multicluster.sh
#   SKIP_RESTART=1 ... / NO_PAUSE=1 ...   same switches as the single-cluster suite
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="test-mirrord"
MC="${MC_NUM_CLUSTERS:-2}"
PRIMARY="${MC_PRIMARY:-mirrord-primary}"
if [ "$MC" = "3" ]; then
  DEFAULT_CTX="${MC_DEFAULT_CTX:-mirrord-remote-1}"
  REUSE_ALLOWED=0
else
  DEFAULT_CTX="${MC_DEFAULT_CTX:-$PRIMARY}"
  REUSE_ALLOWED=1
fi
READY_TIMEOUT=150
LOGDIR="$(mktemp -d /tmp/copy-target-mc.XXXXXX)" || { echo "mktemp failed"; exit 1; }
CONFIG="$LOGDIR/copy-target.json"
TRACE="$LOGDIR/state-trace.log"
FAILURES=0

echo "Topology: $MC clusters | operator on: $PRIMARY | copy pods on: $DEFAULT_CTX"
echo "Session logs and state trace: $LOGDIR"

if [ -z "${MIRRORD_BIN:-}" ] && [ -f "$ROOT/.env" ]; then
  MIRRORD_BIN=$(grep -E '^MIRRORD_BIN=' "$ROOT/.env" | tail -1 | cut -d= -f2-)
fi
MIRRORD_BIN="${MIRRORD_BIN:-$(command -v mirrord || true)}"
if [ -z "$MIRRORD_BIN" ] || [ ! -x "$MIRRORD_BIN" ]; then
  echo "mirrord CLI not found (set MIRRORD_BIN in .env or PATH)"; exit 1
fi

# kp = the cluster the operator runs on; kd = the cluster the copy pods live on
kp() { kubectl --context "$PRIMARY" "$@"; }
kd() { kubectl --context "$DEFAULT_CTX" "$@"; }

SESSION_PIDS=()
cleanup() {
  for pid in "${SESSION_PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 2
  for pid in "${SESSION_PIDS[@]:-}"; do kill -9 "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$TRACE"; }

verdict() {
  if [ "$2" -eq 0 ]; then
    log "✅ $1: $3"
  else
    log "❌ $1: $3"
    FAILURES=$((FAILURES + 1))
  fi
}

copy_pods() {
  kd get pods -n "$NS" --no-headers -o custom-columns=:metadata.name 2>/dev/null \
    | grep '^mirrord-copy-' || true
}

newest_copy_pod() {
  kd get pods -n "$NS" --sort-by=.metadata.creationTimestamp -o name 2>/dev/null \
    | grep mirrord-copy | tail -1 | cut -d/ -f2
}

copytargets() {
  kp get copytargets -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{" "}{end}' 2>/dev/null || true
}

deploy_replicas() {
  kd get deploy echo-app -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?"
}

snapshot() {
  log "   state: pods($DEFAULT_CTX)=[$(copy_pods | tr '\n' ' ')] copytargets($PRIMARY)=[$(copytargets)] replicas=$(deploy_replicas)"
}

cluster_curl() {
  kd exec -n "$NS" deploy/curl-client -- \
    curl -s --max-time 3 http://echo-app:8080/ 2>/dev/null || true
}

start_session() { # start_session <id>; sets SESSION_PID. Always talks to the PRIMARY operator.
  local id="$1"
  log "starting session $id via the $PRIMARY operator (copy_target+scale_down)"
  CLUSTER_ID="local-$id" PORT=8080 MIRRORD_KUBE_CONTEXT="$PRIMARY" MIRRORD_CHECK_VERSION=false \
    "$MIRRORD_BIN" exec -f "$CONFIG" -- "$LOCAL_APP" \
    >"$LOGDIR/session-$id.log" 2>&1 &
  SESSION_PID=$!
  SESSION_PIDS+=("$SESSION_PID")
}

stop_session() {
  log "killing the client (Ctrl-C equivalent)"
  kill -TERM "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

wait_for_local() {
  local id="$1" deadline=$((SECONDS + READY_TIMEOUT)) reply
  while [ "$SECONDS" -lt "$deadline" ]; do
    reply="$(cluster_curl)"
    if echo "$reply" | grep -q "\"cluster_id\":\"local-$id\""; then
      log "   traffic proof: request to echo-app on $DEFAULT_CTX answered by the local app: $(echo "$reply" | head -1 | cut -c1-140)"
      return 0
    fi
    sleep 3
  done
  return 1
}

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

# Old session records (even closed ones) block a new same-identity session
# until they are deleted. Count both session kinds the primary may have.
session_crs() {
  {
    kp get mirrordclustersessions --no-headers 2>/dev/null
    kp get mirrordmulticlustersessions --no-headers 2>/dev/null
  } | grep -c . || true
}

wait_reconnect_grace() {
  local deadline=$((SECONDS + 240))
  log "waiting until no session record remains on $PRIMARY..."
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(session_crs)" = "0" ]; then
      log "   -> no session records"
      sleep 5
      return 0
    fi
    sleep 5
  done
  log "   -> WARN: session records still present after 240s; continuing anyway"
}

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
for ctx in "$PRIMARY" "$DEFAULT_CTX"; do
  kubectl --context "$ctx" cluster-info >/dev/null 2>&1 \
    || { echo "cluster context '$ctx' unreachable - run: MC_NUM_CLUSTERS=$MC task multicluster:up"; exit 1; }
done
kp get apiservice v1.operator.metalbear.co >/dev/null 2>&1 \
  || { echo "operator APIService missing on $PRIMARY"; exit 1; }

if ! kd get deploy echo-app -n "$NS" >/dev/null 2>&1; then
  [ -n "${SKIP_DEPLOY:-}" ] && { echo "echo-app missing on $DEFAULT_CTX and SKIP_DEPLOY set"; exit 1; }
  log "deploying echo-app on $DEFAULT_CTX..."
  docker build -t echo-app:latest "$ROOT/apps/echo-app" >/dev/null
  minikube -p "$DEFAULT_CTX" image load echo-app:latest
  kd create namespace "$NS" --dry-run=client -o yaml | kd apply -f - >/dev/null
  kd apply -n "$NS" -f - <<'EOF' >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-app
  labels: { app: echo-app }
spec:
  replicas: 1
  selector: { matchLabels: { app: echo-app } }
  template:
    metadata: { labels: { app: echo-app } }
    spec:
      containers:
      - name: echo
        image: echo-app:latest
        imagePullPolicy: Never
        ports: [ { containerPort: 8080 } ]
        env:
        - { name: CLUSTER_ID, value: "in-cluster" }
        - { name: PORT, value: "8080" }
---
apiVersion: v1
kind: Service
metadata: { name: echo-app }
spec:
  selector: { app: echo-app }
  ports: [ { port: 8080, targetPort: 8080 } ]
EOF
  kd wait --for=condition=available deploy/echo-app -n "$NS" --timeout=120s >/dev/null
fi

if ! kd get deploy curl-client -n "$NS" >/dev/null 2>&1; then
  kd create deployment curl-client -n "$NS" --image=curlimages/curl -- sleep infinity >/dev/null
fi
kd wait --for=condition=available deploy/curl-client -n "$NS" --timeout=120s >/dev/null

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
  log "deleting leftover copy pods on $DEFAULT_CTX: $leftovers"
  echo "$leftovers" | xargs -n1 kd delete pod -n "$NS" --wait=false 2>/dev/null || true
  kd scale deploy echo-app -n "$NS" --replicas=1 >/dev/null 2>&1 || true
  sleep 5
fi

# ── scenario A ───────────────────────────────────────────────────────────────
brief "scenario A: cleanup after a normal stop ($MC clusters)" <<EOF
Steps: start a session through the $PRIMARY operator (the copy pod is created
on $DEFAULT_CTX), confirm traffic reaches the local app, stop the client.
What should happen: the copy target leaves the list, the pod on $DEFAULT_CTX
is deleted, echo-app scales back to 1 - all on its own, within ~3min.
$( [ "$REUSE_ALLOWED" = "1" ] \
  && echo "2-cluster note: the operator's own controller does the deleting." \
  || echo "3-cluster note: the pod goes away with the session record (owner reference), not via the controller." )
FAIL looks like: the copy target still listed / pod still there after ~3min.
EOF
log ""
log "── scenario A: cleanup after a normal stop ──"
start_session A; pidA=$SESSION_PID
if wait_for_local A; then
  podA="$(newest_copy_pod)"
  log "session A serving via $podA (on $DEFAULT_CTX)"; snapshot
  stop_session "$pidA"
  if watch_until "everything cleaned up" 210 fully_clean; then
    verdict "cleanup-after-stop" 0 "copy pod, copy target and scale-down all cleaned up on their own"
  else
    snapshot
    verdict "cleanup-after-stop" 1 "something is stuck: pods=[$(copy_pods | tr '\n' ' ')] copytargets=[$(copytargets)] replicas=$(deploy_replicas)"
  fi
else
  tail -5 "$LOGDIR/session-A.log" | tee -a "$TRACE"
  verdict "cleanup-after-stop" 1 "baseline session never served local traffic (see session-A.log)"
  stop_session "$pidA"
fi

# ── scenario B ───────────────────────────────────────────────────────────────
brief "scenario B: quick restart ($MC clusters)" <<EOF
Steps: session up, stop the client, start again 45s later.
$( [ "$REUSE_ALLOWED" = "1" ] \
  && echo "2 clusters: picking up the SAME pod or building a fresh one are both
fine - what matters is traffic works." \
  || echo "3 clusters: reuse is DELIBERATELY DISABLED for copies on another
cluster (their pod dies with the old session record, so picking it up would
break). The restart MUST build a FRESH pod - same pod picked up = FAIL." )
FAIL looks like: any error, or traffic never works again.
EOF
log ""
log "── scenario B: quick restart ──"
wait_reconnect_grace
start_session B1; pidB1=$SESSION_PID
if wait_for_local B1; then
  podB1="$(newest_copy_pod)"
  log "session B1 serving via $podB1"
  stop_session "$pidB1"
  log "starting again in 45s"
  sleep 45
  start_session B2; pidB2=$SESSION_PID
  if wait_for_local B2; then
    podB2="$(newest_copy_pod)"
    if [ "$podB2" = "$podB1" ]; then
      if [ "$REUSE_ALLOWED" = "1" ]; then
        verdict "quick-restart" 0 "picked up the same pod $podB1 and traffic works"
      else
        verdict "quick-restart" 1 "picked up $podB1 - but reuse must be disabled for copies on another cluster"
      fi
    else
      verdict "quick-restart" 0 "built a new pod $podB2 and traffic works"
    fi
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

# ── scenario C ───────────────────────────────────────────────────────────────
brief "scenario C: restart after full cleanup" <<'EOF'
Steps: wait until the previous copy is completely gone, then start a new session.
What should happen: a copy pod with a NEW name, traffic works.
EOF
log ""
log "── scenario C: restart after full cleanup ──"
lastpod="$(newest_copy_pod)"
watch_until "previous copy fully cleaned up" 210 fully_clean || true
start_session C; pidC=$SESSION_PID
if wait_for_local C; then
  podC="$(newest_copy_pod)"
  if [ -n "$lastpod" ] && [ "$podC" = "$lastpod" ]; then
    verdict "fresh-copy-after-cleanup" 1 "the old pod name $lastpod came back - should be impossible"
  else
    verdict "fresh-copy-after-cleanup" 0 "new pod ($podC), traffic works"
  fi
else
  tail -5 "$LOGDIR/session-C.log" | tee -a "$TRACE"
  verdict "fresh-copy-after-cleanup" 1 "session never served local traffic"
fi
stop_session "${pidC:-}"

# ── scenario D ───────────────────────────────────────────────────────────────
brief "scenario D: copy pod deleted while the session runs" <<EOF
Steps: session up and serving, then the script DELETES the copy pod on
$DEFAULT_CTX while the session is still using it.
What should happen: the copy target shows Failed, the client errors out
(expected), and the Failed entry disappears on its own within ~4min -
WITHOUT restarting anything.
EOF
log ""
log "── scenario D: copy pod deleted mid-session ──"
wait_reconnect_grace
start_session D; pidD=$SESSION_PID
if wait_for_local D; then
  podD="$(newest_copy_pod)"
  log "deleting the copy pod $podD on $DEFAULT_CTX out from under the live session"
  kd delete pod "$podD" -n "$NS" --wait=false >/dev/null
  if watch_until "Failed entry cleaned up, everything clean" 240 fully_clean; then
    verdict "pod-deleted-mid-session" 0 "Failed copy target cleaned up on its own"
  else
    snapshot
    verdict "pod-deleted-mid-session" 1 "copy target still stuck: copytargets=[$(copytargets)]"
  fi
else
  tail -5 "$LOGDIR/session-D.log" | tee -a "$TRACE"
  verdict "pod-deleted-mid-session" 1 "baseline session never served local traffic"
fi
stop_session "${pidD:-}" 2>/dev/null || true

# ── scenario E ───────────────────────────────────────────────────────────────
if [ -t 0 ] && [ -z "${SKIP_RESTART:-}" ]; then
  brief "scenario E: operator restart with a leftover copy pod ($MC clusters)" <<EOF
Steps: session up, stop the client, then YOU restart the PRIMARY operator:
  kubectl --context $PRIMARY rollout restart deploy/mirrord-operator -n mirrord
What should happen after the restart:
$( [ "$REUSE_ALLOWED" = "1" ] \
  && echo "2 clusters: the new operator finds the leftover pod on its own
cluster and deletes it within ~3min." \
  || echo "3 clusters: the pod on $DEFAULT_CTX goes away when the new operator
cleans up the old session record (owner reference kicks in). May take a few
minutes, but the pod MUST go away." )
FAIL looks like: the pod still Running well past the timeout.
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
    echo ">>> ACTION REQUIRED: restart the PRIMARY operator NOW:"
    echo ">>>   kubectl --context $PRIMARY rollout restart deploy/mirrord-operator -n mirrord"
    echo ">>> Press Enter here once it is back up..."
    read -r
    log "operator restarted by user"
    if watch_until "leftover pod $podE gone after the operator restart" 300 fully_clean; then
      verdict "operator-restart" 0 "leftover copy pod cleaned up after the restart"
    else
      snapshot
      verdict "operator-restart" 1 "pod survived the operator restart"
      kd delete pod "$podE" -n "$NS" --wait=false 2>/dev/null || true
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
