#!/usr/bin/env bash
#
# End-to-end test for the share-ingress not-found page (INT-783,
# `shareIngress.notFound.redirect`) on the local minikube sandbox.
#
# A share host with no live preview (expired link, mistyped host) gets a 404 page. By default
# that page redirects to `shareIngress.appDomain` after five seconds. With the redirect off it
# stays a plain "Preview not found" page with no refresh and no JavaScript, and `appDomain`
# is optional. Cases:
#
#   1. helm template, appDomain set, redirect left at its default
#        -> renders OPERATOR_SHARE_INGRESS_NOT_FOUND_REDIRECT="true" and the app domain env
#   2. helm template, redirect=false, no appDomain
#        -> renders, with redirect "false" and no app domain env
#   3. helm template, redirect=true, no appDomain
#        -> fails, naming shareIngress.notFound.redirect as the way out
#   4. share-ingress binary, redirect on, curl an unknown host
#        -> 404, meta refresh + countdown script pointing at the app domain
#   5. share-ingress binary, redirect off, no app domain, curl an unknown host
#        -> 404, "Preview not found", no meta refresh, no script, no "no longer available"
#   6. share-ingress binary, redirect on, no app domain
#        -> exits non-zero at startup, naming shareIngress.notFound.redirect
#
# Cases 4-6 run the real binary on this machine against the current kube context (it watches
# PreviewSession resources), so no image build or chart install is needed.
#
# Prerequisites:
#   - minikube (bearkube) running with the mirrord CRDs applied (`task operator:crds`)
#   - helm, curl, cargo; the operator checkout on the INT-783 branch
#
# Usage:
#   ./test-share-ingress-not-found.sh
#   task preview:test:share-not-found
#
# Env knobs (all optional):
#   OPERATOR_DIR    operator checkout (default ../operator)
#   PORT            local port for the share-ingress binary (default 18783)
#   START_TIMEOUT   seconds to wait for /health (default 60)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
OPERATOR_DIR="${OPERATOR_DIR:-$SANDBOX_DIR/../operator}"
CHART_DIR="$OPERATOR_DIR/public/charts/mirrord-share-ingress"
PORT="${PORT:-18783}"
START_TIMEOUT="${START_TIMEOUT:-60}"
SHARE_DOMAIN="preview.localhost"
APP_DOMAIN="app.example.com"
BINARY="$OPERATOR_DIR/target/debug/share-ingress"

WORKDIR="$(mktemp -d /tmp/share-ingress-not-found.XXXXXX)"
RAND="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
UNKNOWN_HOST="never-minted-$RAND.$SHARE_DOMAIN"
SERVER_PID=""

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

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
  fi
}
trap stop_server EXIT

render() { # render <out> <helm --set args...>: helm template, 0 when it renders
  local out="$1"
  shift
  helm template share-ingress "$CHART_DIR" --set "shareIngress.shareDomain=$SHARE_DOMAIN" "$@" \
    >"$out" 2>&1
}

# start_server <log> <env assignments...>: runs the binary in the background, waits for /health
start_server() {
  local log="$1"
  shift
  env -u OPERATOR_SHARE_INGRESS_APP_DOMAIN -u OPERATOR_SHARE_INGRESS_NOT_FOUND_REDIRECT \
    RUST_LOG=mirrord=info,share_ingress=info,warn \
    OPERATOR_SHARE_INGRESS_ADDRESS="127.0.0.1:$PORT" \
    OPERATOR_SHARE_INGRESS_SHARE_DOMAIN="$SHARE_DOMAIN" \
    OPERATOR_SHARE_INGRESS_JSON_LOG=false \
    "$@" "$BINARY" >"$log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 "$START_TIMEOUT"); do
    curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    kill -0 "$SERVER_PID" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

fetch_unknown() { # fetch_unknown <body file> -> prints the HTTP status
  curl -s -o "$1" -w '%{http_code}' -H "Host: $UNKNOWN_HOST" "http://127.0.0.1:$PORT/some/path"
}

# Preflight

header "Share-ingress not-found page e2e (INT-783)"
info "workdir: $WORKDIR"

for tool in helm curl cargo kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail "$tool is not installed"
    exit 1
  fi
done
if ! grep -q 'notFound' "$CHART_DIR/values.yaml" 2>/dev/null; then
  fail "$CHART_DIR has no shareIngress.notFound - check out the INT-783 branch in $OPERATOR_DIR"
  exit 1
fi
if ! kubectl get crd previewsessions.preview.mirrord.metalbear.co >/dev/null 2>&1; then
  fail "PreviewSession CRD missing on $(kubectl config current-context) - run 'task operator:crds'"
  exit 1
fi
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "port $PORT is taken - rerun with PORT=<free port>"
  exit 1
fi

info "building share-ingress (debug)"
if ! (cd "$OPERATOR_DIR" && cargo build -p operator-share-ingress); then
  fail "cargo build -p operator-share-ingress failed"
  exit 1
fi

# Chart

header "Chart rendering"

render "$WORKDIR/helm-default.yaml" --set "shareIngress.appDomain=$APP_DOMAIN"
rc=$?
grep -A1 'OPERATOR_SHARE_INGRESS_NOT_FOUND_REDIRECT' "$WORKDIR/helm-default.yaml" | grep -q '"true"' \
  && grep -A1 'OPERATOR_SHARE_INGRESS_APP_DOMAIN' "$WORKDIR/helm-default.yaml" | grep -q "\"$APP_DOMAIN\""
check "1. default renders redirect=true with the app domain" $((rc || $?))

render "$WORKDIR/helm-off.yaml" --set shareIngress.notFound.redirect=false
rc=$?
grep -A1 'OPERATOR_SHARE_INGRESS_NOT_FOUND_REDIRECT' "$WORKDIR/helm-off.yaml" | grep -q '"false"' \
  && ! grep -q 'OPERATOR_SHARE_INGRESS_APP_DOMAIN' "$WORKDIR/helm-off.yaml"
check "2. redirect=false renders without appDomain" $((rc || $?))

if render "$WORKDIR/helm-missing.yaml" --set shareIngress.notFound.redirect=true; then
  check "3. redirect=true without appDomain fails" 1
else
  grep -q 'shareIngress.notFound.redirect=false' "$WORKDIR/helm-missing.yaml"
  check "3. redirect=true without appDomain fails, naming the redirect option" $?
fi

# Binary

header "share-ingress binary, redirect on"
if start_server "$WORKDIR/server-redirect.log" OPERATOR_SHARE_INGRESS_APP_DOMAIN="$APP_DOMAIN"; then
  status="$(fetch_unknown "$WORKDIR/body-redirect.html")"
  body="$WORKDIR/body-redirect.html"
  [ "$status" = 404 ] \
    && grep -q "http-equiv=\"refresh\" content=\"5;url=https://$APP_DOMAIN\"" "$body" \
    && grep -q '<script>' "$body" \
    && grep -q 'no longer available' "$body"
  check "4. unknown host -> 404 with refresh + countdown to https://$APP_DOMAIN (got $status)" $?
else
  check "4. share-ingress started with redirect on (see $WORKDIR/server-redirect.log)" 1
fi
stop_server

header "share-ingress binary, redirect off, no app domain"
if start_server "$WORKDIR/server-plain.log" OPERATOR_SHARE_INGRESS_NOT_FOUND_REDIRECT=false; then
  status="$(fetch_unknown "$WORKDIR/body-plain.html")"
  body="$WORKDIR/body-plain.html"
  [ "$status" = 404 ] \
    && grep -q '<h1>Preview not found</h1>' "$body" \
    && ! grep -q 'http-equiv' "$body" \
    && ! grep -q '<script' "$body" \
    && ! grep -q 'no longer available' "$body"
  check "5. unknown host -> plain 404 'Preview not found', no refresh, no script (got $status)" $?
  info "plain page body:"
  sed 's/^/    /' "$body"
else
  check "5. share-ingress started with redirect off (see $WORKDIR/server-plain.log)" 1
fi
stop_server

header "share-ingress binary, redirect on, no app domain"
start_server "$WORKDIR/server-missing.log"
started=$?
stop_server
[ "$started" != 0 ] && grep -q 'shareIngress.notFound.redirect: false' "$WORKDIR/server-missing.log"
check "6. startup refuses redirect without an app domain, naming the option" $?
info "startup error:"
sed 's/^/    /' "$WORKDIR/server-missing.log"

# Summary

header "Summary"
for line in "${RESULTS[@]}"; do echo "  $line"; done
echo
info "logs and bodies: $WORKDIR"
if [ "$FAILURES" -gt 0 ]; then
  fail "$FAILURES check(s) failed"
  exit 1
fi
pass "all checks passed"
