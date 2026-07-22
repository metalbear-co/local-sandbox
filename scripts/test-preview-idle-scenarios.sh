#!/usr/bin/env bash
# Exercises preview environment IDLE MODE scenario by scenario against the
# sandbox cluster, with a verdict per scenario:
#
#   1. auto-idle     - a Ready preview with sleep_after_secs=30 scales to zero
#                      after silence (phase Idle, 0 replicas, idleSince set)
#   2. no-wake       - a request WITHOUT the preview header is answered by the
#                      ORIGINAL app and must NOT wake the idle preview
#   3. wake + hold   - the first header request wakes it; the request is held
#                      while the pod boots and answered by the PREVIEW pod
#                      (CLUSTER_ID=preview-pod proves who answered); idleSince
#                      is cleared on Ready
#   4. hysteresis    - right after the wake the session stays Ready (a fresh
#                      wake buys a full idle timeout - no flapping)
#   5. re-idle       - silence again -> back to Idle (Ready <-> Idle cycles)
#   6. start-idle    - a second session created with start_idle=true reaches
#                      Idle with 0 replicas and NO pod ever booting; its first
#                      header request wakes it
#   7. cli status    - `mirrord preview status` reports the idle session as
#                      "idle (waiting for traffic)"
#
# Prereqs:
#   - sandbox cluster up, echo-app deployed (auto-deployed unless SKIP_DEPLOY=1)
#   - operator:dev running the CURRENT branch build (idle support), or a
#     deployed operator with idle support + previewEnv enabled
#   - `task`, `kubectl` available; mirrord CLI from the branch (MIRRORD_BIN or .env)
#
# Usage:
#   ./scripts/test-preview-idle-scenarios.sh
#   SKIP_DEPLOY=1 ./scripts/test-preview-idle-scenarios.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="test-mirrord"
KEY_AUTO="idle-scenarios-auto"
KEY_START="idle-scenarios-start"
IDLE_TIMEOUT=30
# BSD/macOS mktemp only substitutes TRAILING X's, so a ".json"-suffixed template creates a
# literal file (and fails outright on the next run). Use a temp dir and a fixed name inside.
CONFIG_DIR="$(mktemp -d /tmp/mirrord-preview-idle-scenarios.XXXXXX)" \
  || { echo "mktemp failed"; exit 1; }
CONFIG="$CONFIG_DIR/preview.json"
FAILURES=0

# The sandbox keeps MIRRORD_BIN in .env (task reads it; plain shells do not).
if [ -z "${MIRRORD_BIN:-}" ] && [ -f "$ROOT/.env" ]; then
  MIRRORD_BIN=$(grep -E '^MIRRORD_BIN=' "$ROOT/.env" | tail -1 | cut -d= -f2-)
fi
MIRRORD_BIN="${MIRRORD_BIN:-$(command -v mirrord || true)}"
if [ -z "$MIRRORD_BIN" ] || [ ! -x "$MIRRORD_BIN" ]; then
  echo "mirrord CLI not found - set MIRRORD_BIN or add it to $ROOT/.env"; exit 1
fi

bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
say()  { echo; echo "${bold}==> $*${reset}"; }
ok()   { echo "  ✅ $*"; }
bug()  { echo "  ❌ FAIL: $*"; FAILURES=$((FAILURES + 1)); }
info() { echo "     $*"; }

cleanup() {
  say "Cleaning up preview sessions"
  MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview stop -k "$KEY_AUTO"  >/dev/null 2>&1 || true
  MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview stop -k "$KEY_START" >/dev/null 2>&1 || true
  rm -rf "$CONFIG_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------- helpers

session_of() { # key -> session name
  kubectl get previewsessions -n "$NS" \
    -o jsonpath="{.items[?(@.spec.key==\"$1\")].metadata.name}" 2>/dev/null | awk '{print $1}'
}
phase_of()      { kubectl get previewsession "$1" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null; }
replicas_of()   { kubectl get deploy "$1" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null; }
idle_since_of() { kubectl get previewsession "$1" -n "$NS" -o jsonpath='{.status.idleSince}' 2>/dev/null; }
session_pod_count() { # session -> number of pods belonging to it
  local uid
  uid=$(kubectl get previewsession "$1" -n "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  kubectl get pods -n "$NS" -l "preview.metalbear.co/session-uid=$uid" \
    -o name 2>/dev/null | wc -l | tr -d ' '
}

wait_for_phase() { # session expected timeout_secs -> 0/1
  local session="$1" expected="$2" deadline=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(phase_of "$session")" = "$expected" ] && return 0
    sleep 3
  done
  return 1
}

send_request() { # extra wget args... -> first line of the response
  kubectl exec -n "$NS" deploy/echo-app -- \
    wget -q -O- -T 120 "$@" "http://echo-app:8080/echo?from=idle-scenarios" 2>/dev/null | head -1
}

# ---------------------------------------------------------------- prereqs

say "Checking prerequisites"
kubectl get ns >/dev/null 2>&1 || { echo "cluster unreachable"; exit 1; }

if [ -z "${SKIP_DEPLOY:-}" ]; then
  info "deploying echo-app (SKIP_DEPLOY=1 to skip)"
  task -d "$ROOT" preview:deploy >/dev/null || { echo "echo-app deploy failed"; exit 1; }
fi
kubectl get deploy echo-app -n "$NS" >/dev/null 2>&1 || { echo "echo-app missing in $NS"; exit 1; }

# Same marker rule as the sandbox tasks - with operator:dev running, sessions
# must be labeled so YOUR operator handles them.
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
fi

# The preview pod overrides CLUSTER_ID so every /echo response names its
# responder: "cluster_id":"preview-pod" vs "cluster_id":"bearkube".
python3 - "$ROOT/apps/echo-app/mirrord-preview-idle.json" "$CONFIG" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
config["feature"].setdefault("env", {})["override"] = {"CLUSTER_ID": "preview-pod"}
json.dump(config, open(sys.argv[2], "w"), indent=2)
PY

# ---------------------------------------------------------------- scenario 1

say "[1/7] auto-idle: Ready -> Idle after ${IDLE_TIMEOUT}s of silence"
MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview start \
  -f "$CONFIG" -i echo-app:latest -k "$KEY_AUTO" --timeout 300 \
  || { bug "preview start failed"; exit 1; }

AUTO=$(session_of "$KEY_AUTO")
[ -n "$AUTO" ] || { bug "session for key $KEY_AUTO not found"; exit 1; }
info "session: $AUTO (phase $(phase_of "$AUTO"))"

if wait_for_phase "$AUTO" Idle $((IDLE_TIMEOUT + 60)); then
  ok "phase Idle after silence"
else
  bug "never reached Idle (phase: $(phase_of "$AUTO"))"
fi
[ "$(replicas_of "$AUTO")" = "0" ] \
  && ok "deployment scaled to 0 replicas" \
  || bug "expected 0 replicas, got $(replicas_of "$AUTO")"
[ -n "$(idle_since_of "$AUTO")" ] \
  && ok "idleSince set ($(idle_since_of "$AUTO"))" \
  || bug "idleSince not set on the idle session"

# ---------------------------------------------------------------- scenario 2

say "[2/7] no-wake: a request WITHOUT the preview header must not wake it"
RESPONSE=$(send_request)
info "response: ${RESPONSE:-<none>}"
case "$RESPONSE" in
  *'"cluster_id":"preview-pod"'*) bug "the PREVIEW answered a request without the header" ;;
  *'"cluster_id":"'*)             ok "answered by the original app" ;;
  *)                              bug "unexpected response from the original app" ;;
esac
sleep 5
[ "$(phase_of "$AUTO")" = "Idle" ] && [ "$(replicas_of "$AUTO")" = "0" ] \
  && ok "session still Idle at 0 replicas" \
  || bug "non-matching traffic changed the session (phase $(phase_of "$AUTO"), replicas $(replicas_of "$AUTO"))"

# ---------------------------------------------------------------- scenario 3

say "[3/7] wake + hold: first header request boots the pod and is answered by it"
START=$(date +%s)
RESPONSE=$(send_request --header="X-Preview: $KEY_AUTO")
ELAPSED=$(( $(date +%s) - START ))
info "response after ${ELAPSED}s: ${RESPONSE:-<none>}"
case "$RESPONSE" in
  *preview-pod*) ok "held during the ${ELAPSED}s boot and answered by the PREVIEW pod" ;;
  *)             bug "expected the preview to answer the wake-up request" ;;
esac
if wait_for_phase "$AUTO" Ready 90; then
  ok "phase Ready after wake"
else
  bug "never returned to Ready (phase: $(phase_of "$AUTO"))"
fi
[ -z "$(idle_since_of "$AUTO")" ] \
  && ok "idleSince cleared on wake" \
  || bug "idleSince still set after wake"

# ---------------------------------------------------------------- scenario 4

say "[4/7] hysteresis: a fresh wake buys a full idle timeout"
sleep 15
[ "$(phase_of "$AUTO")" = "Ready" ] \
  && ok "still Ready 15s after the wake (no premature re-idle)" \
  || bug "re-idled too early (phase: $(phase_of "$AUTO"))"

# ---------------------------------------------------------------- scenario 5

say "[5/7] re-idle: silence again -> back to Idle (Ready <-> Idle cycles)"
if wait_for_phase "$AUTO" Idle $((IDLE_TIMEOUT + 60)); then
  ok "cycled back to Idle"
else
  bug "did not re-idle (phase: $(phase_of "$AUTO"))"
fi

# ---------------------------------------------------------------- scenario 6

say "[6/7] start-idle: born with zero pods, first request wakes it"
MIRRORD_PREVIEW_START_IDLE=true MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview start \
  -f "$CONFIG" -i echo-app:latest -k "$KEY_START" --timeout 300 \
  || bug "start-idle preview start failed"

STARTED=$(session_of "$KEY_START")
if [ -n "$STARTED" ]; then
  wait_for_phase "$STARTED" Idle 60 \
    && ok "reached Idle on creation (CLI treated it as success)" \
    || bug "start-idle session never reached Idle (phase: $(phase_of "$STARTED"))"
  [ "$(replicas_of "$STARTED")" = "0" ] \
    && ok "deployment created with 0 replicas" \
    || bug "expected 0 replicas, got $(replicas_of "$STARTED")"
  [ "$(session_pod_count "$STARTED")" = "0" ] \
    && ok "no preview pod booted on creation" \
    || bug "a pod booted for a start-idle session"

  RESPONSE=$(send_request --header="X-Preview: $KEY_START")
  case "$RESPONSE" in
    *preview-pod*) ok "first request woke it and was answered by the preview" ;;
    *)             bug "start-idle wake failed (response: ${RESPONSE:-<none>})" ;;
  esac
else
  bug "session for key $KEY_START not found"
fi

# ---------------------------------------------------------------- scenario 7

say "[7/7] cli status: the auto session (idle again) reports as idle"
STATUS=$(MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview status -k "$KEY_AUTO" 2>/dev/null)
if echo "$STATUS" | grep -q "idle (waiting for traffic)"; then
  ok "'mirrord preview status' shows: idle (waiting for traffic)"
else
  bug "status output does not mention the idle state"
  info "$STATUS"
fi

# ---------------------------------------------------------------- verdict

say "Verdict"
if [ "$FAILURES" -eq 0 ]; then
  ok "all 7 idle-mode scenarios passed"
else
  bug "$FAILURES check(s) failed - see above"
  exit 1
fi
