#!/usr/bin/env bash
#
# End-to-end test for STABLE preview share hosts (INT-722,
# `operator.shareIngress.stableSlugs`) on the local minikube sandbox.
#
# With stable slugs the operator mints the share host as <sanitized key>.<shareDomain>
# with no random suffix, so a PR bot can build the link from the key alone. The price
# is one live session per host on the cluster. Three cases against the echo-app target:
#
#   1. preview with key stable-<rand>
#        -> Ready, and the first label of status.shareHost is the key itself
#   2. second preview with key Stable_<rand> while the first is live
#        (a different key that sanitizes to the SAME slug - the CLI would replace a
#        session with the identical key on the same target instead of starting a new one)
#        -> `preview start` fails, the session is Failed, and failureMessage names
#           the first session and the contested host
#   3. stop the first preview, start a third one with key stable-<rand>
#        -> Ready with exactly the host the first one had
#
# Prerequisites:
#   - minikube (bearkube) running, the echo-app target deployed (`task preview:deploy`)
#   - the local operator from the feature branch running (`task operator:dev`) with
#     OPERATOR_SHARE_INGRESS_STABLE_SLUGS=true - .mirrord/operator-dev.yaml sets it,
#     and the preflight fails fast when that line is missing
#
# Usage:
#   ./test-preview-stable-slugs.sh
#   task preview:test:stable-slugs
#
# Env knobs (all optional):
#   MIRRORD_BIN      mirrord CLI to use (default: local debug build, then PATH)
#   NAMESPACE        echo-app namespace (default test-mirrord)
#   READY_TIMEOUT    seconds for `preview start` to reach Ready (default 300)
#   FAIL_TIMEOUT     seconds to wait for the operator to fail the second session (default 90)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="${NAMESPACE:-test-mirrord}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
FAIL_TIMEOUT="${FAIL_TIMEOUT:-90}"
PREVIEW_CONFIG="$SANDBOX_DIR/apps/echo-app/mirrord-preview-single.json"
OPERATOR_DEV_CONFIG="$SANDBOX_DIR/.mirrord/operator-dev.yaml"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/preview-stable-slugs.XXXXXX)"

# A fresh key per run: a stable host is held per key, so a leftover from an earlier run
# must not be able to fail this one. Case 2 needs a key that sanitizes to the same slug,
# and uppercase plus an underscore does exactly that (lowercased, `_` becomes `-`).
RAND="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
KEY="stable-$RAND"
KEY_SAME_SLUG="Stable_$RAND"
CREATED_KEYS=()

# Output helpers - gum when installed, plain ANSI otherwise
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
RESULTS=()
check() { # check <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then
    pass "$1"
    RESULTS+=("PASS  $1")
  else
    fail "$1"
    RESULTS+=("FAIL  $1")
    FAILURES=$((FAILURES + 1))
  fi
}

session_of() { # session_of <key> -> name of the PreviewSession with that spec.key
  kubectl get previewsessions -n "$NAMESPACE" \
    -o jsonpath="{.items[?(@.spec.key==\"$1\")].metadata.name}" 2>/dev/null | awk '{print $1}'
}
field_of() { # field_of <session> <jsonpath>
  kubectl get previewsession "$1" -n "$NAMESPACE" -o jsonpath="$2" 2>/dev/null
}
stop_key() { # stop_key <key>: CLI stop first, then whatever the CLI left behind
  MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview stop -k "$1" >/dev/null 2>&1 || true
  local session
  session="$(session_of "$1")"
  [ -n "$session" ] && kubectl delete previewsession "$session" -n "$NAMESPACE" \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
}
# Waits until no session with the key is left, so the next session with the same key
# is not refused by a holder that is merely still being finalized.
wait_gone() { # wait_gone <key>
  for _ in $(seq 1 60); do
    [ -z "$(session_of "$1")" ] && return 0
    sleep 1
  done
  return 1
}
start_key() { # start_key <key> <log>: `mirrord preview start`, Ready or non-zero
  CREATED_KEYS+=("$1")
  MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview start \
    -f "$PREVIEW_CONFIG" -i echo-app:latest -k "$1" --timeout "$READY_TIMEOUT" >"$2" 2>&1
}

cleanup() {
  for key in "${CREATED_KEYS[@]:-}"; do
    [ -n "$key" ] && stop_key "$key"
  done
}
trap cleanup EXIT

# Preflight

header "Stable preview share hosts e2e (INT-722)"

if ! grep -q '^ *OPERATOR_SHARE_INGRESS_STABLE_SLUGS: *"true"' "$OPERATOR_DEV_CONFIG"; then
  fail "OPERATOR_SHARE_INGRESS_STABLE_SLUGS: \"true\" is not set in $OPERATOR_DEV_CONFIG - add it next to OPERATOR_SHARE_INGRESS_SHARE_DOMAIN and restart 'task operator:dev'"
  exit 1
fi
if ! pgrep -qf 'target/debug/operator-service'; then
  fail "operator:dev is not running - start it ('task operator:dev') from the INT-722 checkout so the stable-slug operator reconciles these sessions"
  exit 1
fi
export OPERATOR_ISOLATION_MARKER="${OPERATOR_ISOLATION_MARKER:-local-dev}"
info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=$OPERATOR_ISOLATION_MARKER"

# One status call, no retries: a dev operator that is not serving yet is the user's to fix.
if ! MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" operator status >"$WORKDIR/operator-status.log" 2>&1; then
  fail "'mirrord operator status' failed - the operator is not serving (log: $WORKDIR/operator-status.log)"
  exit 1
fi
kubectl get deploy echo-app -n "$NAMESPACE" >/dev/null 2>&1 \
  || { fail "echo-app target not found in $NAMESPACE - run 'task preview:deploy' first"; exit 1; }
[ -f "$PREVIEW_CONFIG" ] || { fail "missing $PREVIEW_CONFIG"; exit 1; }
info "keys for this run: $KEY (cases 1 and 3), $KEY_SAME_SLUG (case 2, same slug)"

# 1. Stable host is the key itself

header "1/3 preview '$KEY' -> shareHost is <key>.<domain>"
if start_key "$KEY" "$WORKDIR/start-1.log"; then
  SESSION_1="$(session_of "$KEY")"
  HOST_1="$(field_of "$SESSION_1" '{.status.shareHost}')"
  info "session: $SESSION_1, shareHost: ${HOST_1:-<none>}"
  [ -n "$HOST_1" ]
  check "the session was minted a share host (needs OPERATOR_SHARE_INGRESS_SHARE_DOMAIN)" $?
  [ "${HOST_1%%.*}" = "$KEY" ]
  check "the host's first label is the key with no random suffix (${HOST_1%%.*})" $?
else
  SESSION_1="$(session_of "$KEY")"
  HOST_1=""
  fail "preview start for '$KEY' did not reach Ready - $(tail -3 "$WORKDIR/start-1.log" | tr '\n' ' ')"
  [ -n "$SESSION_1" ] && info "failure message: $(field_of "$SESSION_1" '{.status.failureMessage}')"
  check "case 1 session reaches Ready" 1
fi

# 2. A second live session on the same host is refused, naming the holder

header "2/3 preview '$KEY_SAME_SLUG' while '$KEY' is live -> Failed, naming the holder"
if [ -z "$HOST_1" ]; then
  warn "skipping: case 1 minted no host to contest"
  check "second session is refused" 1
else
  if start_key "$KEY_SAME_SLUG" "$WORKDIR/start-2.log"; then
    check "'preview start' exits non-zero for the contested host" 1
    info "the second session came up as $(session_of "$KEY_SAME_SLUG") with host $(field_of "$(session_of "$KEY_SAME_SLUG")" '{.status.shareHost}')"
  else
    check "'preview start' exits non-zero for the contested host" 0
  fi
  SESSION_2="$(session_of "$KEY_SAME_SLUG")"
  PHASE_2=""
  for _ in $(seq 1 "$FAIL_TIMEOUT"); do
    PHASE_2="$(field_of "$SESSION_2" '{.status.phase}')"
    [ "$PHASE_2" = "Failed" ] && break
    sleep 1
  done
  [ "$PHASE_2" = "Failed" ]
  check "the second session is Failed (phase: ${PHASE_2:-<none>})" $?
  MESSAGE_2="$(field_of "$SESSION_2" '{.status.failureMessage}')"
  info "failure message: ${MESSAGE_2:-<none>}"
  case "$MESSAGE_2" in
    *"$SESSION_1"*) check "the failure message names the holder ($SESSION_1)" 0 ;;
    *) check "the failure message names the holder ($SESSION_1)" 1 ;;
  esac
  case "$MESSAGE_2" in
    *"$HOST_1"*) check "the failure message names the contested host ($HOST_1)" 0 ;;
    *) check "the failure message names the contested host ($HOST_1)" 1 ;;
  esac
  grep -q "preview session failed\|$HOST_1" "$WORKDIR/start-2.log"
  check "the CLI printed the failure to the user (log: $WORKDIR/start-2.log)" $?
  stop_key "$KEY_SAME_SLUG"
fi

# 3. Once the holder is gone the host is reused

header "3/3 stop '$KEY', start it again -> Ready with the same host"
if [ -z "$HOST_1" ]; then
  warn "skipping: case 1 minted no host to reuse"
  check "the host is reused after the holder stops" 1
else
  stop_key "$KEY"
  wait_gone "$KEY"
  check "the first session is gone" $?
  if start_key "$KEY" "$WORKDIR/start-3.log"; then
    SESSION_3="$(session_of "$KEY")"
    HOST_3="$(field_of "$SESSION_3" '{.status.shareHost}')"
    info "session: $SESSION_3, shareHost: ${HOST_3:-<none>}"
    [ "$HOST_3" = "$HOST_1" ]
    check "the new session got the exact host the stopped one had" $?
  else
    fail "preview start for '$KEY' did not reach Ready - $(tail -3 "$WORKDIR/start-3.log" | tr '\n' ' ')"
    SESSION_3="$(session_of "$KEY")"
    [ -n "$SESSION_3" ] && info "failure message: $(field_of "$SESSION_3" '{.status.failureMessage}')"
    check "a new session with the same key reaches Ready once the holder is gone" 1
  fi
fi

# Verdict

header "Result"
for line in "${RESULTS[@]}"; do echo "  $line"; done
echo
if [ "$FAILURES" = 0 ]; then
  pass "all stable share host checks passed"
  info "next: 'task preview:test:share' still passes (it only checks a host exists)"
else
  fail "$FAILURES check(s) failed - logs in $WORKDIR"
  exit 1
fi
