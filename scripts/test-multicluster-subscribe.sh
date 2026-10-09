#!/usr/bin/env bash
# Multi-cluster `mirrord subscribe` suite (INT-745): ONE subscription against
# the PRIMARY streams the events of EVERY cluster, each event naming the cluster
# that intercepted it, and a cluster the primary cannot reach is reported in the
# stream instead of breaking it.
#
# Works with both topologies (MC_NUM_CLUSTERS, same as `task multicluster:up`):
#   2 (default): primary + remote-1, both workload clusters
#   3:           management-only primary + remote-1 + remote-2
#
# Cases (verdict each, exit code = number of failures):
#   1. per-cluster   - a stolen request on EACH workload cluster shows up on the
#                      one primary subscription with "cluster":"<that cluster>"
#   2. no-key        - `mirrord subscribe` without -k streams the session too;
#                      events carry both session_key and cluster
#   3. unreachable   - drop a member's `events` grant: the stream reports that
#                      cluster as cluster_unavailable (naming the missing
#                      permission) while the other clusters keep flowing; restore
#                      the grant and that cluster's events resume on the same
#                      subscription (the primary retries every 30s)
#
# Prereqs:
#   task multicluster:up                 clusters + released operators
#   task multicluster:crds               local-chart CRDs + member envoy roles
#                                        (the `events` grant the primary needs)
#   task multicluster:http:deploy        echo-app on every workload cluster
#   task multicluster:operator:primary   YOUR operator from this branch on the
#                                        primary (or `task op:custom` for images)
#   cargo xtask build-cli (in ../mirrord) for case 2: an older CLI insists on -k
#
# Usage:
#   ./scripts/test-multicluster-subscribe.sh            # all cases, 2 clusters
#   MC_NUM_CLUSTERS=3 ./scripts/test-multicluster-subscribe.sh
#   CASES="1 3" ./scripts/test-multicluster-subscribe.sh
#
# Env knobs (defaults): MIRRORD_BIN (.env / ../mirrord debug build / PATH),
#   NAMESPACE=test-mirrord, CASES="1 2 3", EVENT_TIMEOUT=60 (s to wait for one
#   event), RECONNECT_TIMEOUT=120 (s for a restored cluster to resume),
#   MC_PRIMARY / MC_REMOTE_1 / MC_REMOTE_2 (kube contexts, which are also the
#   operator's cluster names here), KEEP=1 keeps the session and logs around.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NS="${NAMESPACE:-test-mirrord}"
MC="${MC_NUM_CLUSTERS:-2}"
PRIMARY="${MC_PRIMARY:-mirrord-primary}"
REMOTE1="${MC_REMOTE_1:-mirrord-remote-1}"
REMOTE2="${MC_REMOTE_2:-mirrord-remote-2}"
if [ "$MC" = "3" ]; then
  WORKLOAD_CTXS="$REMOTE1 $REMOTE2"; ALL_CTXS="$PRIMARY $REMOTE1 $REMOTE2"
  DEFAULT_CTX="${MC_DEFAULT_CTX:-$REMOTE1}"
else
  WORKLOAD_CTXS="$PRIMARY $REMOTE1"; ALL_CTXS="$PRIMARY $REMOTE1"
  DEFAULT_CTX="${MC_DEFAULT_CTX:-$PRIMARY}"
fi
CASES="${CASES:-1 2 3}"
EVENT_TIMEOUT="${EVENT_TIMEOUT:-60}"
RECONNECT_TIMEOUT="${RECONNECT_TIMEOUT:-120}"
MEMBER_ROLE="mirrord-operator-envoy-remote"

if [ -z "${MIRRORD_BIN:-}" ] && [ -f "$SANDBOX_DIR/.env" ]; then
  MIRRORD_BIN=$(grep -E '^MIRRORD_BIN=' "$SANDBOX_DIR/.env" | tail -1 | cut -d= -f2-)
fi
if [ -z "${MIRRORD_BIN:-}" ]; then
  for candidate in "$SANDBOX_DIR/../mirrord/target/debug/mirrord" \
                   "$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"; do
    [ -x "$candidate" ] && MIRRORD_BIN="$candidate" && break
  done
fi
MIRRORD_BIN="${MIRRORD_BIN:-$(command -v mirrord || true)}"

WORKDIR="$(mktemp -d /tmp/mc-subscribe.XXXXXX)" || { echo "mktemp failed"; exit 1; }
RUN_TAG="${WORKDIR##*.}"
KEY="mc-sub-$(echo "$RUN_TAG" | tr '[:upper:]' '[:lower:]')"
LOCK_DIR=/tmp/mc-subscribe.lock

# ── output ──────────────────────────────────────────────────────────────────
HAVE_GUM=0
command -v gum >/dev/null 2>&1 && HAVE_GUM=1
[ -t 1 ] || HAVE_GUM=0
header() {
  if [ "$HAVE_GUM" = 1 ]; then gum style --border rounded --padding "0 2" --margin "1 0" --bold "$*"
  else printf '\n\033[1m== %s ==\033[0m\n' "$*"; fi
}
info() { if [ "$HAVE_GUM" = 1 ]; then gum log --level info "$*"; else printf '  %s\n' "$*"; fi; }
warn() { if [ "$HAVE_GUM" = 1 ]; then gum log --level warn "$*"; else printf '  \033[33mWARN\033[0m %s\n' "$*"; fi; }
pass() { if [ "$HAVE_GUM" = 1 ]; then gum log --level info "PASS $*"; else printf '  \033[32mPASS\033[0m %s\n' "$*"; fi; }
fail() { if [ "$HAVE_GUM" = 1 ]; then gum log --level error "FAIL $*"; else printf '  \033[31mFAIL\033[0m %s\n' "$*"; fi; }

FAILURES=0
RESULTS=()
check() {
  if [ "$2" = 0 ]; then pass "$1"; RESULTS+=("PASS  $1")
  else fail "$1"; RESULTS+=("FAIL  $1"); FAILURES=$((FAILURES + 1)); fi
}
skip() { warn "SKIP $1"; RESULTS+=("SKIP  $1"); }

# ── helpers ─────────────────────────────────────────────────────────────────
kp() { kubectl --context "$PRIMARY" "$@"; }

# Sends one request the session steals through CTX's own echo-app, from inside
# that cluster, so the request is intercepted by THAT cluster's agent.
send_via() {
  kubectl --context "$1" exec -n "$NS" deploy/echo-app -- \
    wget -q -O- -T 20 --header="x-mc-subscribe: $KEY" "http://echo-app:8080/echo?from=$RUN_TAG" \
    >/dev/null 2>&1 || true
}

# Waits up to $2 seconds for a line of $1 matching every remaining pattern.
wait_for_line() {
  local file="$1" timeout="$2"; shift 2
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if [ -s "$file" ]; then
      local matched
      matched=$(cat "$file")
      for pattern in "$@"; do matched=$(printf '%s\n' "$matched" | grep -F -- "$pattern" || true); done
      [ -n "$matched" ] && return 0
    fi
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

# Starts `mirrord subscribe` against the primary in the background; $1 = log
# file, remaining args go to the CLI (e.g. -k KEY).
SUBSCRIBE_PIDS=()
start_subscribe() {
  local out="$1"; shift
  MIRRORD_KUBE_CONTEXT="$PRIMARY" MIRRORD_CHECK_VERSION=false \
    "$MIRRORD_BIN" subscribe "$@" > "$out" 2> "$out.err" &
  SUBSCRIBE_PIDS+=("$!")
  sleep 3
  if ! kill -0 "$!" 2>/dev/null; then
    warn "subscribe exited early: $(tail -3 "$out.err" | tr '\n' ' ')"
    return 1
  fi
}

SESSION_PID=""
ROLE_BACKUP=""
ROLE_CTX=""
cleanup() {
  if [ -n "$ROLE_BACKUP" ] && [ -f "$ROLE_BACKUP" ]; then
    kubectl --context "$ROLE_CTX" replace -f "$ROLE_BACKUP" >/dev/null 2>&1 \
      && info "restored $MEMBER_ROLE on $ROLE_CTX"
  fi
  # `wait` after each kill keeps bash from printing a "Terminated" line per job.
  for pid in "${SUBSCRIBE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  done
  # The session runs in its own process group so this reaches its intproxy too.
  # Never `pkill -f "mirrord intproxy"` here: that also kills the intproxies of the
  # operator:dev steals and takes both dev operators down with them.
  if [ -n "$SESSION_PID" ]; then
    kill -TERM -- "-$SESSION_PID" 2>/dev/null || kill -TERM "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [ "${KEEP:-0}" = 1 ]; then info "KEEP=1: logs stay in $WORKDIR"; fi
}
trap cleanup EXIT

# ── preflight ───────────────────────────────────────────────────────────────
header "Preflight"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another run holds $LOCK_DIR (remove it if no run is active)"; exit 1
fi
[ -x "$MIRRORD_BIN" ] || { fail "mirrord CLI not found (set MIRRORD_BIN in .env or PATH)"; exit 1; }
info "topology: $MC clusters | primary: $PRIMARY | workload: $WORKLOAD_CTXS | default: $DEFAULT_CTX"
info "CLI: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "session key: $KEY | logs: $WORKDIR"

for CTX in $WORKLOAD_CTXS; do
  kubectl --context "$CTX" get deploy echo-app -n "$NS" >/dev/null 2>&1 \
    || { fail "echo-app missing on $CTX - run 'task multicluster:http:deploy'"; exit 1; }
done

OPERATOR_JSON=$(kp get mirrordoperators operator -o json 2>/dev/null) \
  || { fail "cannot read the operator status on $PRIMARY - is an operator serving there?"; exit 1; }
printf '%s' "$OPERATOR_JSON" | grep -q '"MultiClusterPrimary"\|"multi_cluster_primary"\|"multiClusterPrimary"' \
  || { fail "the operator on $PRIMARY is not a multi-cluster primary"; exit 1; }
if ! printf '%s' "$OPERATOR_JSON" | grep -q '"MultiClusterSubscribe"\|"multi_cluster_subscribe"\|"multiClusterSubscribe"'; then
  fail "the operator on $PRIMARY does not advertise MultiClusterSubscribe - run 'task multicluster:operator:primary' from the INT-745 branch (or 'task op:custom')"
  exit 1
fi
if pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER="${OPERATOR_ISOLATION_MARKER:-local-dev}"
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=$OPERATOR_ISOLATION_MARKER"
  # The marker makes a DEPLOYED member ignore the dev primary's child sessions,
  # so every cluster must be served locally (task multicluster:operator:<name>).
  for CTX in $ALL_CTXS; do
    kubectl --context "$CTX" get deploy mirrord-operator -n mirrord -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -q busybox \
      || warn "$CTX runs a deployed operator while the primary is operator:dev - sessions will not route there (run 'task multicluster:operator:${CTX#mirrord-}')"
  done
fi

for CTX in $WORKLOAD_CTXS; do
  [ "$CTX" = "$PRIMARY" ] && continue
  kubectl --context "$CTX" get clusterrole "$MEMBER_ROLE" -o json 2>/dev/null | grep -q '"events"' \
    || { fail "$MEMBER_ROLE on $CTX grants no 'events' - run 'task multicluster:crds'"; exit 1; }
done

# ── session: one steal session through the primary, header-filtered ─────────
header "Session"
cat > "$WORKDIR/mirrord.json" <<JSON
{
  "key": "$KEY",
  "target": { "path": "deployment/echo-app", "namespace": "$NS" },
  "feature": {
    "network": {
      "incoming": {
        "mode": "steal",
        "http_filter": { "header_filter": "x-mc-subscribe: $KEY" }
      }
    }
  }
}
JSON
# A local listener answers the stolen requests so wget returns at once; the
# events are published by the operator as it routes the request, so even a
# refused local connection would still produce them, only slower.
if command -v python3 >/dev/null 2>&1; then
  LOCAL_APP=(python3 -m http.server 8080 --bind 127.0.0.1)
else
  LOCAL_APP=(sh -c 'sleep 900')
fi
# Own process group (pgid = pid), so cleanup can stop exec + intproxy + app together.
MIRRORD_KUBE_CONTEXT="$PRIMARY" MIRRORD_CHECK_VERSION=false \
  perl -e 'setpgrp(0, 0); exec @ARGV' -- "$MIRRORD_BIN" exec -f "$WORKDIR/mirrord.json" -- "${LOCAL_APP[@]}" \
  > "$WORKDIR/session.log" 2>&1 &
SESSION_PID=$!
info "waiting for the session to subscribe on every cluster..."
waited=0
while [ "$waited" -lt 150 ]; do
  kill -0 "$SESSION_PID" 2>/dev/null || { fail "session exited: $(tail -5 "$WORKDIR/session.log" | tr '\n' ' ')"; exit 1; }
  READY=$(kp get mirrordmulticlustersessions -o json 2>/dev/null \
    | grep -c "\"phase\": *\"Ready\"" || true)
  [ "$READY" -gt 0 ] && break
  sleep 5; waited=$((waited + 5))
done
[ "$READY" -gt 0 ] || { fail "no Ready MirrordMultiClusterSession on $PRIMARY after ${waited}s"; exit 1; }
# Members confirm the port subscription a bit after the parent turns Ready.
sleep 10
info "session ready (pid $SESSION_PID)"

# ── case 1: per-cluster ──────────────────────────────────────────────────────
case " $CASES " in *" 1 "*)
  header "1/3 per-cluster: one subscription, an event per cluster"
  EVENTS="$WORKDIR/keyed.jsonl"
  if start_subscribe "$EVENTS" -k "$KEY"; then
    for CTX in $WORKLOAD_CTXS; do
      send_via "$CTX"
      if wait_for_line "$EVENTS" "$EVENT_TIMEOUT" "\"cluster\":\"$CTX\"" '"http_request"'; then
        check "stolen request on $CTX arrived with cluster=$CTX" 0
      else
        info "events so far: $(wc -l < "$EVENTS" | tr -d ' ') line(s), $(tail -2 "$EVENTS")"
        check "stolen request on $CTX arrived with cluster=$CTX" 1
      fi
    done
    if grep -q '"cluster_unavailable"' "$EVENTS"; then
      check "no cluster reported unavailable" 1
    else
      check "no cluster reported unavailable" 0
    fi
    if grep -q '"session_key"' "$EVENTS"; then
      check "keyed stream omits session_key (no --session-key-field)" 1
    else
      check "keyed stream omits session_key (no --session-key-field)" 0
    fi
  else
    check "keyed subscribe stays open" 1
  fi
  ;;
esac

# ── case 2: no key ───────────────────────────────────────────────────────────
case " $CASES " in *" 2 "*)
  header "2/3 no-key: every session, each event naming session and cluster"
  EVENTS="$WORKDIR/nokey.jsonl"
  if start_subscribe "$EVENTS"; then
    send_via "$DEFAULT_CTX"
    if wait_for_line "$EVENTS" "$EVENT_TIMEOUT" "\"session_key\":\"$KEY\"" "\"cluster\":\"$DEFAULT_CTX\"" '"http_request"'; then
      check "keyless stream names session $KEY and cluster $DEFAULT_CTX" 0
    else
      check "keyless stream names session $KEY and cluster $DEFAULT_CTX" 1
    fi
  else
    if grep -q "Session key is required\|every session" "$EVENTS.err"; then
      info "this CLI refuses a keyless subscribe - build it from the branch: cd ../mirrord && cargo xtask build-cli"
    fi
    check "keyless subscribe stays open" 1
  fi
  ;;
esac

# ── case 3: unreachable member ───────────────────────────────────────────────
case " $CASES " in *" 3 "*)
  header "3/3 unreachable: a member without the events grant"
  MEMBER=""
  for CTX in $WORKLOAD_CTXS; do [ "$CTX" != "$PRIMARY" ] && MEMBER="$CTX" && break; done
  if [ -z "$MEMBER" ]; then
    skip "no member workload cluster in this topology"
  elif ! command -v jq >/dev/null 2>&1; then
    skip "jq is needed to edit the member role (brew install jq)"
  else
    ROLE_CTX="$MEMBER"
    ROLE_BACKUP="$WORKDIR/$MEMBER_ROLE.$MEMBER.json"
    kubectl --context "$MEMBER" get clusterrole "$MEMBER_ROLE" -o json \
      | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)' \
      > "$ROLE_BACKUP"
    jq '.rules |= map(select((.resources // []) | index("events") | not))' "$ROLE_BACKUP" \
      | kubectl --context "$MEMBER" replace -f - >/dev/null
    info "dropped the events grant from $MEMBER_ROLE on $MEMBER"

    # RBAC is checked when a stream is opened, so a fresh subscription is what
    # hits the 403; the primary reports it once and keeps retrying.
    EVENTS="$WORKDIR/unreachable.jsonl"
    if start_subscribe "$EVENTS" -k "$KEY"; then
      if wait_for_line "$EVENTS" "$EVENT_TIMEOUT" "\"cluster\":\"$MEMBER\"" '"cluster_unavailable"'; then
        check "$MEMBER reported as cluster_unavailable" 0
        if grep -F "\"cluster\":\"$MEMBER\"" "$EVENTS" | grep -q "$MEMBER_ROLE"; then
          check "the notice names the missing $MEMBER_ROLE grant" 0
        else
          info "notice: $(grep -F '"cluster_unavailable"' "$EVENTS" | head -1)"
          check "the notice names the missing $MEMBER_ROLE grant" 1
        fi
      else
        check "$MEMBER reported as cluster_unavailable" 1
      fi

      OTHER=""
      for CTX in $WORKLOAD_CTXS; do [ "$CTX" != "$MEMBER" ] && OTHER="$CTX" && break; done
      if [ -n "$OTHER" ]; then
        send_via "$OTHER"
        if wait_for_line "$EVENTS" "$EVENT_TIMEOUT" "\"cluster\":\"$OTHER\"" '"http_request"'; then
          check "$OTHER keeps streaming meanwhile" 0
        else
          check "$OTHER keeps streaming meanwhile" 1
        fi
      fi

      kubectl --context "$MEMBER" replace -f "$ROLE_BACKUP" >/dev/null && ROLE_BACKUP=""
      info "restored the grant; waiting up to ${RECONNECT_TIMEOUT}s for $MEMBER to resume"
      resumed=1; waited=0
      while [ "$waited" -lt "$RECONNECT_TIMEOUT" ]; do
        send_via "$MEMBER"
        if wait_for_line "$EVENTS" 8 "\"cluster\":\"$MEMBER\"" '"http_request"'; then resumed=0; break; fi
        waited=$((waited + 10))
      done
      check "$MEMBER events resume on the same subscription after the grant is back" "$resumed"
    else
      check "subscribe stays open with a member unreachable" 1
    fi
  fi
  ;;
esac

# ── summary ──────────────────────────────────────────────────────────────────
header "Summary"
for line in "${RESULTS[@]:-}"; do [ -n "$line" ] && printf '  %s\n' "$line"; done
echo
if [ "$FAILURES" = 0 ]; then
  pass "all checks passed - logs in $WORKDIR"
else
  fail "$FAILURES check(s) failed - logs in $WORKDIR"
fi
exit "$FAILURES"
