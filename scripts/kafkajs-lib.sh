#!/bin/bash
#
# Shared helpers for the Kafka split proof scripts (test-kafkajs-*.sh,
# test-confluent-*.sh). Defaults drive the kafkajs module; a script for another
# module sets MODULE / APP_LABEL / LOCAL_* before sourcing this file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="test-mirrord"
MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"
# Taskfile namespace (task <MODULE>:deploy, :fix:on, :send:match, ...) and the
# consumer Deployment's `app` label.
MODULE="${MODULE:-kafkajs}"
APP_LABEL="${APP_LABEL:-kafkajs-consumer}"
MIRRORD_CONFIG="${MIRRORD_CONFIG:-$SANDBOX_DIR/k8s/overlays/$MODULE/mirrord.json}"
# Where and how the consumer runs locally under mirrord.
LOCAL_APP_DIR="${LOCAL_APP_DIR:-$SANDBOX_DIR/apps/$APP_LABEL}"
LOCAL_PREPARE="${LOCAL_PREPARE:-test -d node_modules || npm install --omit=dev}"
LOCAL_CMD="${LOCAL_CMD:-node consumer.js}"
LOCAL_LOG="/tmp/$MODULE-local-consumer.log"
LOCAL_PID=""

HAVE_GUM=0
command -v gum >/dev/null 2>&1 && HAVE_GUM=1

say() {
    if [ "$HAVE_GUM" = 1 ]; then
        gum style --foreground 212 "==> $1"
    else
        echo -e "\033[1;35m==>\033[0m $1"
    fi
}
ok()   { echo -e "\033[0;32m[OK]\033[0m $1"; }
bad()  { echo -e "\033[0;31m[XX]\033[0m $1"; }
info() { echo -e "\033[0;36m[..]\033[0m $1"; }

confirm() {
    if [ "$HAVE_GUM" = 1 ]; then
        gum confirm "$1"
    else
        read -r -p "$1 [y/N] " answer
        [ "$answer" = "y" ] || [ "$answer" = "Y" ]
    fi
}

# The cluster lifecycle stays in the user's hands (task cluster:create /
# task cluster:delete); the scripts only verify it is reachable.
require_cluster() {
    if ! kubectl get nodes >/dev/null 2>&1; then
        bad "Kubernetes cluster not reachable"
        echo "  start it with:  cd $SANDBOX_DIR && task cluster:create"
        exit 1
    fi
}

# The operator deployment turning "available" does not mean its session API is
# answering yet - a session started in that window fails with a misleading
# "license expired" error. Poll the API through the CLI until it responds.
wait_for_operator_api() {
    require_mirrord
    say "Waiting for the operator API to answer"
    local waited=0
    while [ "$waited" -lt 90 ]; do
        if "$MIRRORD_BIN" operator status >/dev/null 2>&1; then
            ok "operator API is up"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    bad "operator API did not answer within 90s; check: task operator:status"
    exit 1
}

deploy_env() {
    say "Deploying the $MODULE test env (broker + consumer)"
    (cd "$SANDBOX_DIR" && task "$MODULE:deploy")
}

fix_on()  { (cd "$SANDBOX_DIR" && task "$MODULE:fix:on"); }
fix_off() { (cd "$SANDBOX_DIR" && task "$MODULE:fix:off"); }

send_match()   { (cd "$SANDBOX_DIR" && task "$MODULE:send:match" MESSAGE="$1"); }
send_nomatch() { (cd "$SANDBOX_DIR" && task "$MODULE:send:nomatch" MESSAGE="$1"); }

require_mirrord() {
    if command -v "$MIRRORD_BIN" >/dev/null 2>&1; then
        return 0
    fi
    # Not on PATH (common when `mirrord` is a shell alias, invisible to
    # scripts); fall back to the sibling mirrord repo's local builds - the
    # sandbox convention `task mirrord:cli:build` produces.
    local candidate
    for candidate in \
        "$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/release/mirrord" \
        "$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord" \
        "$SANDBOX_DIR/../mirrord/target/release/mirrord" \
        "$SANDBOX_DIR/../mirrord/target/debug/mirrord"; do
        if [ -x "$candidate" ]; then
            MIRRORD_BIN="$candidate"
            info "using mirrord from the sibling repo build: $MIRRORD_BIN"
            return 0
        fi
    done
    bad "mirrord binary '$MIRRORD_BIN' not found on PATH and no local build exists"
    echo "  build one with:      cd $SANDBOX_DIR && task mirrord:cli:build"
    echo "  or point directly:   MIRRORD_BIN=/path/to/mirrord $0"
    echo "  (note: 'which mirrord' reports aliases as text, not a path - use the alias target)"
    exit 1
}

local_consumer_alive() {
    [ -n "$LOCAL_PID" ] && kill -0 "$LOCAL_PID" 2>/dev/null
}

start_local_consumer() {
    require_mirrord
    say "Starting the local $APP_LABEL under mirrord (log: $LOCAL_LOG)"
    (cd "$LOCAL_APP_DIR" && eval "$LOCAL_PREPARE")
    : > "$LOCAL_LOG"
    (
        cd "$LOCAL_APP_DIR" &&
        eval "exec \"\$MIRRORD_BIN\" exec -f \"\$MIRRORD_CONFIG\" -- $LOCAL_CMD"
    ) > "$LOCAL_LOG" 2>&1 &
    LOCAL_PID=$!
    # mirrord SIGKILLs the app when the session dies; disowning keeps bash from
    # printing a "Killed: 9" job notice in the middle of the case output.
    disown "$LOCAL_PID" 2>/dev/null || true
    sleep 3
    if ! local_consumer_alive; then
        # A case that expects the session to be refused at start (the operator
        # rejects the split before the CLI gets going) sets LOCAL_MAY_FAIL_FAST;
        # the caller then reads the error from the log. Anything else dying
        # this early is a broken setup.
        if [ "${LOCAL_MAY_FAIL_FAST:-0}" = 1 ]; then
            info "local mirrord run exited right away; the case reads its error from the log"
            return 0
        fi
        bad "the local mirrord run died right after starting:"
        tail -15 "$LOCAL_LOG" || true
        exit 1
    fi
    info "local consumer PID $LOCAL_PID; follow with: tail -f $LOCAL_LOG"
}

stop_local_consumer() {
    if [ -n "$LOCAL_PID" ] && kill -0 "$LOCAL_PID" 2>/dev/null; then
        kill "$LOCAL_PID" 2>/dev/null || true
        # Disowned, so `wait` cannot reap it; poll instead.
        local waited=0
        while kill -0 "$LOCAL_PID" 2>/dev/null && [ "$waited" -lt 15 ]; do
            sleep 1
            waited=$((waited + 1))
        done
    fi
    LOCAL_PID=""
}

# Prints the human-readable error out of collected error text: the `error`
# field of an operator JSON log line, or the lines around `needle` otherwise.
show_error_excerpt() {
    local text="$1" needle="$2"
    echo ""
    echo "--- the error, as the user sees it ---"
    if echo "$text" | grep -q '^{"timestamp"'; then
        echo "$text" | grep '^{"timestamp"' | grep -F "$needle" | tail -1 | python3 -c '
import json, sys, textwrap
for line in sys.stdin:
    try:
        error = json.loads(line).get("fields", {}).get("error", "")
    except Exception:
        continue
    print(textwrap.fill(error, 100))
'
    else
        echo "$text" | grep -B1 -A8 -F "$needle" | head -14
    fi
    echo "--------------------------------------"
}

sessions_json() {
    kubectl get mirrordclustersplitsession -o json 2>/dev/null || echo '{"items":[]}'
}

# Extracts a session error message from the sessions JSON, empty when none.
# startError carries a plain string, cleanupError an object with an `error` key.
session_error_message() {
    sessions_json | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in doc.get("items", []):
    status = item.get("status") or {}
    for key in ("startError", "cleanupError"):
        error = status.get(key)
        if isinstance(error, dict):
            error = error.get("error") or str(error)
        if error:
            print(f"{key}: {error}")
            sys.exit(0)
' || true
}

# Waits until any split session settles: prints "ready", the error message, or
# "local-exited" the moment the local mirrord process dies (a session can no
# longer appear then, so waiting on is pointless). Fails only when nothing
# happens within the timeout.
wait_for_session_settled() {
    local timeout="${1:-180}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        local error
        error=$(session_error_message)
        if [ -n "$error" ]; then
            echo "$error"
            return 0
        fi
        if sessions_json | grep -q '"ready"'; then
            echo "ready"
            return 0
        fi
        if ! local_consumer_alive; then
            echo "local-exited"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# Waits for a session that is expected to fail AFTER going Ready (the operator
# reports Ready before its forwarder joined the group). Prints the error text
# found on the session, in the local log, or in the operator log since
# `since` (the CLI exits on the failure and the session is cleaned up, so the
# operator log is often the only place the cause survives). Fails on timeout.
wait_for_session_failure() {
    local timeout="${1:-180}" since="$2" waited=0 error
    while [ "$waited" -lt "$timeout" ]; do
        error=$(session_error_message)
        if [ -n "$error" ]; then
            echo "$error"
            return 0
        fi
        if ! local_consumer_alive; then
            error=$(operator_logs_since "$since" | grep -F "Split runtime error" | tail -1)
            if [ -z "$error" ]; then
                error=$(cat "$LOCAL_LOG" 2>/dev/null)
            fi
            echo "$error"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

wait_for_sessions_gone() {
    local timeout="${1:-120}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        local count
        count=$(kubectl get mirrordclustersplitsession -o name 2>/dev/null | wc -l | tr -d ' ')
        [ "$count" = "0" ] && return 0
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# Waits until the local consumer log contains the given string.
wait_for_local_message() {
    local needle="$1" timeout="${2:-60}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if grep -qF "$needle" "$LOCAL_LOG" 2>/dev/null; then return 0; fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

cluster_consumer_logs() {
    kubectl logs -n "$NAMESPACE" -l "app=$APP_LABEL" --tail=200 2>/dev/null || true
}

operator_logs() {
    kubectl logs -n mirrord -l app=mirrord-operator --tail=500 2>/dev/null || true
}

# Operator log lines written since an RFC3339 UTC timestamp (see now_utc).
# With a label selector kubectl silently keeps only the last 10 lines per pod
# unless told otherwise, hence --tail=-1.
operator_logs_since() {
    kubectl logs -n mirrord -l app=mirrord-operator --since-time="$1" --tail=-1 2>/dev/null || true
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The env value the workload patch sets for KAFKA_GROUP_ID, empty when unpatched.
patched_group_value() {
    kubectl get mirrordclusterworkloadpatchrequest -o json 2>/dev/null | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in doc.get("items", []):
    for env in item.get("spec", {}).get("envVars", []):
        if env.get("variable") == "KAFKA_GROUP_ID":
            print(env.get("value", ""))
            sys.exit(0)
' || true
}

cleanup_env() {
    stop_local_consumer
    (cd "$SANDBOX_DIR" && task "$MODULE:clean") || true
}

# Dumps everything needed to debug an inconclusive run. The test env is left
# in place on failure precisely so this (and manual kubectl) has data to show.
print_diagnostics() {
    echo ""
    say "Diagnostics"
    echo "--- split sessions ---"
    kubectl get mirrordclustersplitsession -o yaml 2>/dev/null | head -60 || true
    echo "--- workload patches ---"
    kubectl get mirrordclusterworkloadpatchrequest -o yaml 2>/dev/null | head -40 || true
    echo "--- local consumer log (tail) ---"
    tail -30 "$LOCAL_LOG" 2>/dev/null || true
    echo "--- operator log (kafka/group lines) ---"
    operator_logs | grep -iE "kafka|group|forwarder|split" | tail -30 || true
    echo "--- cluster consumer log (tail) ---"
    cluster_consumer_logs | tail -20 || true
    echo ""
    info "the env is left deployed for inspection; clean with: task $MODULE:clean"
}
