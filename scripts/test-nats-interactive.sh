#!/usr/bin/env bash
#
# Interactive, gum-driven verification of NATS JetStream queue splitting on
# the local sandbox. One command that checks the whole chain and fixes what
# it can along the way:
#
#   1. Preflight: cluster reachable, mirrord CLI, operator APIService up,
#      natsSplitting enabled, split CRDs installed. Offers to deploy the
#      NATS overlay (task nats:deploy) when it is missing.
#   2. Scenarios (pick any, default all): header filter (steal), jq filter,
#      mirror mode. Each starts a real mirrord session, publishes tagged
#      match/no-match messages through nats-box, and asserts the routing on
#      both the local session log and the deployed consumer's log.
#   3. After every scenario the session is stopped and the mirrord-tmp-*
#      stream cleanup is asserted, so each scenario starts from a clean slate.
#
# Usage:
#   ./test-nats-interactive.sh          # or: task nats:test
#   YES=1 ./test-nats-interactive.sh    # no prompts: deploy if needed, run all
#
# Env knobs: MIRRORD_BIN, NAMESPACE (test-mirrord), NATS_NAMESPACE
# (nats-sandbox), SETTLE_WAIT (15), READY_TIMEOUT (120).
#
# The non-interactive CI-style variant of this flow is
# scripts/test-nats-split.sh (task nats:test:split).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(dirname "$SCRIPT_DIR")"
OVERLAY="$SANDBOX_DIR/k8s/overlays/nats"
NAMESPACE="${NAMESPACE:-test-mirrord}"
NATS_NAMESPACE="${NATS_NAMESPACE:-nats-sandbox}"
SETTLE_WAIT="${SETTLE_WAIT:-15}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
YES="${YES:-0}"
SUBJECT="orders.new"
CONSUMER="nats-consumer"

LOCAL_MIRRORD="$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"
if [ -z "${MIRRORD_BIN:-}" ]; then
  if [ -x "$LOCAL_MIRRORD" ]; then MIRRORD_BIN="$LOCAL_MIRRORD"; else MIRRORD_BIN="mirrord"; fi
fi

WORKDIR="$(mktemp -d /tmp/nats-interactive.XXXXXX)"
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"
SESSION_PID=""
SESSION_A_PID=""
SESSION_LOG=""
# Same lock as test-nats-split.sh: both drive the same fixed-name deployment
# and split config, so concurrent runs would tear each other down.
LOCK_DIR="/tmp/nats-split.lock"

# ---------------------------------------------------------------------------
# gum-aware output helpers (plain-terminal fallbacks, kafkajs-lib.sh style)
# ---------------------------------------------------------------------------
HAVE_GUM=0
command -v gum >/dev/null 2>&1 && HAVE_GUM=1

say() {
  if [ "$HAVE_GUM" = 1 ]; then gum style --foreground 212 --bold "==> $1"
  else printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$1"; fi
}
ok()   { printf '\033[0;32m  ✔\033[0m %s\n' "$1"; }
bad()  { printf '\033[0;31m  ✘\033[0m %s\n' "$1"; }
info() { printf '\033[0;36m  ·\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$1"; }

banner() {
  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border rounded --margin "1 0" --padding "0 2" \
      --border-foreground 212 "$@"
  else
    printf '\n=== %s ===\n' "$*"
  fi
}

confirm() { # confirm <question>; YES=1 auto-accepts
  [ "$YES" = 1 ] && return 0
  if [ "$HAVE_GUM" = 1 ]; then gum confirm "$1"
  else read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; fi
}

spin() { # spin <title> <command...>; keeps output on failure
  local title="$1"; shift
  local out="$WORKDIR/spin.$$.log"
  if [ "$HAVE_GUM" = 1 ]; then
    if gum spin --spinner dot --title "$title" -- bash -c "$* >'$out' 2>&1"; then
      return 0
    fi
  else
    info "$title"
    if bash -c "$* >'$out' 2>&1"; then return 0; fi
  fi
  bad "$title failed:"
  tail -15 "$out" | sed 's/^/    /'
  return 1
}

RESULTS=()
FAILURES=0
check() { # check <description> <0-ok/1-bad>
  if [ "$2" = 0 ]; then ok "$1"; RESULTS+=("PASS  $1")
  else bad "$1"; RESULTS+=("FAIL  $1"); FAILURES=$((FAILURES + 1)); fi
}

stop_session() {
  if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
  fi
  SESSION_PID=""
  if [ -n "$SESSION_A_PID" ] && kill -0 "$SESSION_A_PID" 2>/dev/null; then
    kill "$SESSION_A_PID" 2>/dev/null || true
    wait "$SESSION_A_PID" 2>/dev/null || true
  fi
  SESSION_A_PID=""
}

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  stop_session
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Cluster helpers (aligned with test-nats-split.sh)
# ---------------------------------------------------------------------------
get_natsbox_pod() {
  kubectl get pod -n "$NATS_NAMESPACE" -l app.kubernetes.io/name=nats-box \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

get_consumer_pod() {
  kubectl get pod -n "$NAMESPACE" -l "app=$CONSUMER" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null
}

nats_cli() {
  local pod
  pod=$(get_natsbox_pod)
  [ -n "$pod" ] || return 1
  kubectl exec -n "$NATS_NAMESPACE" "$pod" -- nats --server nats://nats:4222 "$@"
}

publish_to() { # publish_to <subject> <tenant> <type> <body>
  local subject="$1" tenant="$2" type="$3" body="$4" attempt
  for attempt in 1 2 3; do
    if nats_cli pub "$subject" -H "tenant:$tenant" -H "type:$type" \
      "{\"tenant\":\"$tenant\",\"type\":\"$type\",\"message\":\"$body\"}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

publish() { publish_to "$SUBJECT" "$@"; } # publish <tenant> <type> <body>

list_streams() { nats_cli stream ls --names 2>/dev/null || true; }

split_sessions() {
  kubectl get mirrordclustersplitsessions.queues.mirrord.metalbear.co \
    -o jsonpath='{.items[*].status.phase}' 2>/dev/null || true
}

wait_for_clean_slate() { # no session CRs, no mirrord-tmp streams
  local waited=0
  while [ "$waited" -lt 90 ]; do
    if [ -z "$(split_sessions)" ] && ! list_streams | grep -q '^mirrord-tmp-'; then
      return 0
    fi
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

ready_count() { split_sessions | tr ' ' '\n' | grep -cw Ready || true; }

tmp_stream_count() { list_streams | grep -c '^mirrord-tmp-' || true; }

start_session() { # start_session <mirrord config path> <log path> [ready sessions to wait for]
  SESSION_LOG="$2"
  local want_ready="${3:-1}"
  "$MIRRORD_BIN" exec -f "$1" -- /tmp/nats-consumer >"$SESSION_LOG" 2>&1 &
  SESSION_PID=$!

  local waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    if ! kill -0 "$SESSION_PID" 2>/dev/null; then
      bad "mirrord session died - last log lines:"
      tail -15 "$SESSION_LOG" | sed 's/^/    /'
      return 1
    fi
    if [ "$(ready_count)" -ge "$want_ready" ]; then return 0; fi
    sleep 1; waited=$((waited + 1))
  done
  bad "split session never reached Ready - last log lines:"
  tail -15 "$SESSION_LOG" | sed 's/^/    /'
  return 1
}

settle() {
  if [ "$HAVE_GUM" = 1 ]; then
    gum spin --spinner dot --title "letting messages drain (${SETTLE_WAIT}s)" -- sleep "$SETTLE_WAIT"
  else
    info "letting messages drain (${SETTLE_WAIT}s)..."; sleep "$SETTLE_WAIT"
  fi
}

# Splitting patches the deployment (restart) at session start, and unpatches
# it (another restart) at session end. A grep against one pod's log races
# that churn - a message can be consumed and logged by a pod whose log is
# gone by grep time, and a leftover unpatched pod can even compete with the
# forwarder on the original consumer. So: settle the rollout before every
# publish, and collect logs from every live pod of the deployment.
wait_for_stable_deploy() { # wait_for_stable_deploy <deployment>
  kubectl rollout status "deployment/$1" -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 \
    || warn "$1 rollout did not settle in 120s, results may race pod churn"
  # The freshly rolled pod still needs a beat to bind its (tmp) consumer.
  sleep 5
}

wait_for_stable_consumer() { wait_for_stable_deploy "$CONSUMER"; }

fresh_cluster_log() { # fresh_cluster_log <out file>
  kubectl logs -n "$NAMESPACE" -l "app=$CONSUMER" --prefix --tail=300 >"$1" 2>/dev/null || true
}

assert_cleanup() { # assert_cleanup <scenario name>
  stop_session
  # Waits for the session CRs too, so the next scenario's Ready poll cannot
  # be fooled by this scenario's split session lingering in Ready.
  local cleaned=1 waited=0
  while [ "$waited" -lt 120 ]; do
    if [ -z "$(split_sessions)" ] && ! list_streams | grep -q '^mirrord-tmp-'; then
      cleaned=0
      break
    fi
    sleep 2; waited=$((waited + 2))
  done
  check "$1: mirrord-tmp-* streams cleaned up after the session" "$cleaned"
  if [ "$cleaned" != 0 ]; then
    warn "streams still present:"; list_streams | sed 's/^/    /'
  fi
  # Let the unpatch rollout finish before the next scenario patches again.
  wait_for_stable_consumer
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
banner "NATS queue splitting - interactive check" "run tag: $RUN_TAG"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  bad "another NATS split test run is active (lock: $LOCK_DIR; rmdir it if stale)"
  exit 1
fi

say "Preflight"

command -v kubectl >/dev/null 2>&1 || { bad "kubectl is required"; exit 1; }

if ! kubectl get nodes >/dev/null 2>&1; then
  bad "Kubernetes cluster not reachable"
  info "start it with:  cd $SANDBOX_DIR && task cluster:create"
  exit 1
fi
ok "cluster reachable"

if ! "$MIRRORD_BIN" --version >/dev/null 2>&1; then
  bad "mirrord CLI not runnable: $MIRRORD_BIN"
  info "build it with:  cd $SANDBOX_DIR/../mirrord && cargo build -p mirrord"
  exit 1
fi
ok "mirrord CLI: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | tr -d '\n'))"

if ! kubectl get crd mirrordsplitconfigs.queues.mirrord.metalbear.co >/dev/null 2>&1; then
  bad "MirrordSplitConfig CRD not installed - the deployed operator predates unified splitting"
  info "deploy a current operator:  task op:build   (or task op:custom)"
  exit 1
fi
ok "split CRDs installed"

operator_up=1
for _ in $(seq 1 45); do
  if kubectl get --raw /apis/operator.metalbear.co/v1 >/dev/null 2>&1; then operator_up=0; break; fi
  sleep 2
done
if [ "$operator_up" != 0 ]; then
  bad "the operator APIService never answered"
  info "deploy or restart it:  task op:build   (or 'task operator:dev' for a local run)"
  exit 1
fi
ok "operator APIService answering"

# A session against an operator with a broken license dies with "license
# expired" long after preflight, so catch it here. The sandbox drift: `task
# operator:dev` rebuilds operator-service on every start, and a build without
# the sandbox issuer baked in rejects configs/company-license.pem and falls
# back to the expired online key (status then shows the 1970 epoch).
status_out="$("$MIRRORD_BIN" operator status 2>&1 || true)"
if printf '%s' "$status_out" | grep -qiE "license expired|expire at:[[:space:]]+1-Jan-1970"; then
  bad "the serving operator's license is expired/broken - sessions will die with 'license expired'"
  info "restart the dev operator with the sandbox issuer baked into the build:"
  info "  SANDBOX_LICENSE=1 OPERATOR_LICENSE_ISSUER_PUBLIC_KEY=\"\$(cat scripts/license-issuer.pem)\" task operator:dev"
  confirm "Continue anyway?" || exit 1
else
  ok "operator license valid"
fi

# natsSplitting must be on or the session fails with a disabled-queue-kind
# error. Where the serving operator gets its flags depends on how it runs:
# `task operator:dev` steals the deployed pod's traffic and forces extra
# flags through .mirrord/operator-dev.yaml's env override, so a local dev
# process is checked against that file, not against the deployment's env.
dev_operator_pid="$(pgrep -f 'target/debug/operator-service' 2>/dev/null | head -1 || true)"
if [ -n "$dev_operator_pid" ]; then
  if grep -q 'OPERATOR_NATS_SPLITTING: "true"' "$SANDBOX_DIR/.mirrord/operator-dev.yaml" 2>/dev/null; then
    ok "local dev operator running (pid $dev_operator_pid) with natsSplitting forced in .mirrord/operator-dev.yaml"
    info "if it was started before that override was added, restart 'task operator:dev'"
  else
    bad "local dev operator running, but .mirrord/operator-dev.yaml does not force OPERATOR_NATS_SPLITTING"
    info "add 'OPERATOR_NATS_SPLITTING: \"true\"' to feature.env.override and restart 'task operator:dev'"
    confirm "Continue anyway (sessions will likely fail)?" || exit 1
  fi
else
  nats_flag="$(kubectl get deploy -A -l app=mirrord-operator \
    -o jsonpath='{.items[0].spec.template.spec.containers[0].env[?(@.name=="OPERATOR_NATS_SPLITTING")].value}' 2>/dev/null || true)"
  if [ "$nats_flag" = "true" ]; then
    ok "operator has natsSplitting enabled"
  elif kubectl get deploy -A -l app=mirrord-operator -o name 2>/dev/null | grep -q .; then
    bad "the deployed operator does NOT have natsSplitting enabled"
    info "operator-values.yaml carries natsSplitting: true - redeploy with:  task op:build && task op:custom"
    confirm "Continue anyway (sessions will likely fail)?" || exit 1
  else
    warn "no operator found (neither in-cluster nor a local operator:dev) - cannot verify natsSplitting"
  fi
fi

if [ -z "$(get_natsbox_pod)" ] || [ -z "$(get_consumer_pod)" ]; then
  warn "the NATS test env is not (fully) deployed in $NATS_NAMESPACE / $NAMESPACE"
  if confirm "Deploy it now (task nats:deploy - builds the consumer image, ~1 min)?"; then
    say "Deploying the NATS test env"
    (cd "$SANDBOX_DIR" && task nats:deploy)
  else
    bad "cannot continue without the NATS overlay"
    exit 1
  fi
fi
ok "nats-box and $CONSUMER pods are running"

stream_up=1
for _ in $(seq 1 30); do
  if list_streams | grep -qx "ORDERS"; then stream_up=0; break; fi
  sleep 2
done
if [ "$stream_up" != 0 ]; then
  bad "stream ORDERS never appeared - check: kubectl logs -n $NAMESPACE -l app=$CONSUMER"
  exit 1
fi
ok "stream ORDERS exists (durable consumer orders-app)"

if list_streams | grep -q '^mirrord-tmp-' || [ -n "$(split_sessions)" ]; then
  warn "leftover split sessions / mirrord-tmp streams from an earlier run - waiting for cleanup"
  if ! wait_for_clean_slate; then
    bad "the cluster still has split leftovers - stop other sessions first (task nats:status)"
    exit 1
  fi
  ok "previous split cleaned up"
fi

spin "building the local consumer" "cd '$SANDBOX_DIR/apps/nats-consumer' && go build -o /tmp/nats-consumer main.go" || exit 1
ok "local consumer built (/tmp/nats-consumer)"

# ---------------------------------------------------------------------------
# Scenario selection
# ---------------------------------------------------------------------------
ALL_SCENARIOS="header filter (steal)
jq filter
mirror mode
two users (parallel sessions)
config file (volume split)
pubsub (core NATS)"

if [ -n "${ONLY:-}" ]; then
  SCENARIOS="$ONLY"
elif [ "$YES" = 1 ] || [ "$HAVE_GUM" = 0 ]; then
  SCENARIOS="$ALL_SCENARIOS"
else
  say "Pick scenarios (space to toggle, enter to run; default: all)"
  SCENARIOS="$(printf '%s\n' "$ALL_SCENARIOS" | gum choose --no-limit \
    --selected "header filter (steal)" --selected "jq filter" --selected "mirror mode" \
    --selected "two users (parallel sessions)" --selected "config file (volume split)" \
    --selected "pubsub (core NATS)" || true)"
  [ -n "$SCENARIOS" ] || SCENARIOS="$ALL_SCENARIOS"
fi

picked() { printf '%s\n' "$SCENARIOS" | grep -q "^$1"; }

# ---------------------------------------------------------------------------
# Scenario: header filter, steal mode
# ---------------------------------------------------------------------------
if picked "header filter"; then
  banner "Scenario: header filter (steal)" "tenant=^acme\$ -> local; everything else -> cluster"

  say "Starting the mirrord session (log: $WORKDIR/steal.log)"
  if start_session "$OVERLAY/mirrord.json" "$WORKDIR/steal.log"; then
    ok "split session Ready"
    wait_for_stable_consumer

    publish acme premium "steal-local-$RUN_TAG" && ok "sent tenant=acme (should be stolen)" \
      || check "steal: publishing the matching message" 1
    publish other basic "steal-cluster-$RUN_TAG" && ok "sent tenant=other (should stay in cluster)" \
      || check "steal: publishing the non-matching message" 1
    settle

    fresh_cluster_log "$WORKDIR/steal-cluster.log"
    grep -q "steal-local-$RUN_TAG" "$WORKDIR/steal.log" && r=0 || r=1
    check "steal: local session received the matching message" "$r"
    ! grep -q "steal-cluster-$RUN_TAG" "$WORKDIR/steal.log" && r=0 || r=1
    check "steal: local session did NOT get the non-matching message" "$r"
    grep -q "steal-cluster-$RUN_TAG" "$WORKDIR/steal-cluster.log" && r=0 || r=1
    check "steal: deployed consumer received the non-matching message" "$r"
    ! grep -q "steal-local-$RUN_TAG" "$WORKDIR/steal-cluster.log" && r=0 || r=1
    check "steal: deployed consumer did NOT get the stolen message" "$r"
  else
    check "steal: split session reached Ready" 1
  fi
  assert_cleanup "steal"
fi

# ---------------------------------------------------------------------------
# Scenario: jq filter on the JSON payload
# ---------------------------------------------------------------------------
if picked "jq filter"; then
  banner "Scenario: jq filter" '.payload.type == "premium" -> local'

  say "Starting the mirrord session (log: $WORKDIR/jq.log)"
  if start_session "$OVERLAY/mirrord-jq.json" "$WORKDIR/jq.log"; then
    ok "split session Ready"
    wait_for_stable_consumer

    publish nobody premium "jq-local-$RUN_TAG" && ok "sent type=premium (should be stolen by jq)" \
      || check "jq: publishing the premium message" 1
    publish nobody basic "jq-cluster-$RUN_TAG" && ok "sent type=basic (should stay in cluster)" \
      || check "jq: publishing the basic message" 1
    settle

    fresh_cluster_log "$WORKDIR/jq-cluster.log"
    grep -q "jq-local-$RUN_TAG" "$WORKDIR/jq.log" && r=0 || r=1
    check "jq: local session received the premium message" "$r"
    ! grep -q "jq-cluster-$RUN_TAG" "$WORKDIR/jq.log" && r=0 || r=1
    check "jq: local session did NOT get the basic message" "$r"
    grep -q "jq-cluster-$RUN_TAG" "$WORKDIR/jq-cluster.log" && r=0 || r=1
    check "jq: deployed consumer received the basic message" "$r"
  else
    check "jq: split session reached Ready" 1
  fi
  assert_cleanup "jq"
fi

# ---------------------------------------------------------------------------
# Scenario: mirror mode - both sides get a copy of the match
# ---------------------------------------------------------------------------
if picked "mirror mode"; then
  banner "Scenario: mirror mode" "tenant=^acme\$ -> local AND cluster"

  say "Starting the mirrord session (log: $WORKDIR/mirror.log)"
  if start_session "$OVERLAY/mirrord-mirror.json" "$WORKDIR/mirror.log"; then
    ok "split session Ready"
    wait_for_stable_consumer

    publish acme premium "mirror-both-$RUN_TAG" && ok "sent tenant=acme (both should get a copy)" \
      || check "mirror: publishing the matching message" 1
    publish other basic "mirror-cluster-$RUN_TAG" && ok "sent tenant=other (cluster only)" \
      || check "mirror: publishing the non-matching message" 1
    settle

    fresh_cluster_log "$WORKDIR/mirror-cluster.log"
    grep -q "mirror-both-$RUN_TAG" "$WORKDIR/mirror.log" && r=0 || r=1
    check "mirror: local session received the matching message" "$r"
    grep -q "mirror-both-$RUN_TAG" "$WORKDIR/mirror-cluster.log" && r=0 || r=1
    check "mirror: deployed consumer ALSO received the matching message" "$r"
    grep -q "mirror-cluster-$RUN_TAG" "$WORKDIR/mirror-cluster.log" && r=0 || r=1
    check "mirror: deployed consumer received the non-matching message" "$r"
    ! grep -q "mirror-cluster-$RUN_TAG" "$WORKDIR/mirror.log" && r=0 || r=1
    check "mirror: local session did NOT get the non-matching message" "$r"
  else
    check "mirror: split session reached Ready" 1
  fi
  assert_cleanup "mirror"
fi

# ---------------------------------------------------------------------------
# Scenario: two parallel sessions sharing one split
# ---------------------------------------------------------------------------
if picked "two users"; then
  banner "Scenario: two users (parallel sessions)" \
    "A: tenant=^acme\$; B: tenant=^globex\$; other -> cluster"

  # User B needs its own filter; the overlay only ships user A's.
  cat >"$WORKDIR/mirrord-b.json" <<EOF
{
  "target": { "path": "deployment/$CONSUMER", "namespace": "$NAMESPACE" },
  "operator": true,
  "feature": {
    "split_queues": {
      "orders": {
        "queue_type": "NATS",
        "message_filter": { "tenant": "^globex\$" }
      }
    }
  }
}
EOF

  say "Starting session A (log: $WORKDIR/two-a.log)"
  if start_session "$OVERLAY/mirrord.json" "$WORKDIR/two-a.log" 1; then
    ok "session A Ready"
    SESSION_A_PID="$SESSION_PID"
    SESSION_PID=""
    A_LOG="$SESSION_LOG"

    say "Starting session B (log: $WORKDIR/two-b.log)"
    if start_session "$WORKDIR/mirrord-b.json" "$WORKDIR/two-b.log" 2; then
      ok "session B Ready (two sessions live)"
      B_LOG="$SESSION_LOG"
      streams_with_two="$(tmp_stream_count)"
      info "temporary streams with two sessions: $streams_with_two"
      wait_for_stable_consumer

      publish acme premium "two-a-$RUN_TAG" && ok "sent tenant=acme (for A)" \
        || check "two users: publishing A's message" 1
      publish globex premium "two-b-$RUN_TAG" && ok "sent tenant=globex (for B)" \
        || check "two users: publishing B's message" 1
      publish other basic "two-cluster-$RUN_TAG" && ok "sent tenant=other (for the cluster)" \
        || check "two users: publishing the cluster message" 1
      settle

      fresh_cluster_log "$WORKDIR/two-cluster.log"
      grep -q "two-a-$RUN_TAG" "$A_LOG" && r=0 || r=1
      check "two users: session A received its message" "$r"
      grep -q "two-b-$RUN_TAG" "$B_LOG" && r=0 || r=1
      check "two users: session B received its message" "$r"
      ! grep -q "two-b-$RUN_TAG" "$A_LOG" && ! grep -q "two-a-$RUN_TAG" "$B_LOG" && r=0 || r=1
      check "two users: sessions did NOT get each other's messages" "$r"
      grep -q "two-cluster-$RUN_TAG" "$WORKDIR/two-cluster.log" && r=0 || r=1
      check "two users: deployed consumer received the unmatched message" "$r"
      ! grep -q "two-a-$RUN_TAG" "$WORKDIR/two-cluster.log" \
        && ! grep -q "two-b-$RUN_TAG" "$WORKDIR/two-cluster.log" && r=0 || r=1
      check "two users: deployed consumer did NOT get either stolen message" "$r"

      # Detach A only: its per-session stream must go while the split (main
      # output + B's stream) stays up, and B must keep receiving.
      say "Stopping session A only"
      kill "$SESSION_A_PID" 2>/dev/null || true
      wait "$SESSION_A_PID" 2>/dev/null || true
      SESSION_A_PID=""

      a_cleaned=1
      waited=0
      while [ "$waited" -lt 90 ]; do
        now="$(tmp_stream_count)"
        if [ "$(ready_count)" = 1 ] && [ "$now" -lt "$streams_with_two" ] && [ "$now" -gt 0 ]; then
          a_cleaned=0
          break
        fi
        sleep 2; waited=$((waited + 2))
      done
      check "two users: A's per-session stream cleaned up while the split stayed alive" "$a_cleaned"

      publish globex premium "two-b2-$RUN_TAG" && ok "sent another tenant=globex (B still live)" \
        || check "two users: publishing B's second message" 1
      settle
      grep -q "two-b2-$RUN_TAG" "$B_LOG" && r=0 || r=1
      check "two users: session B kept receiving after A detached" "$r"
    else
      check "two users: session B reached Ready" 1
    fi
  else
    check "two users: session A reached Ready" 1
  fi
  assert_cleanup "two users"
fi

# ---------------------------------------------------------------------------
# Scenario: names resolved from a mounted ConfigMap file
# ---------------------------------------------------------------------------
if picked "config file"; then
  banner "Scenario: config file (volume split)" \
    "stream/consumer names live in /config/nats.yaml, not env vars"

  FILE_CONSUMER="nats-file-consumer"
  FILE_CM="nats-file-config"
  FILE_SUBJECT="filecfg.new"

  # The deployed app creates ORDERS-FILE on first start; make sure it exists
  # before the operator resolves the split against it.
  file_ready=1
  waited=0
  while [ "$waited" -lt 90 ]; do
    if list_streams | grep -q '^ORDERS-FILE$'; then file_ready=0; break; fi
    sleep 3; waited=$((waited + 3))
  done
  check "config file: stream ORDERS-FILE exists (created by $FILE_CONSUMER)" "$file_ready"

  say "Starting the mirrord session (log: $WORKDIR/file.log)"
  if start_session "$OVERLAY/mirrord-file.json" "$WORKDIR/file.log"; then
    ok "split session Ready"
    wait_for_stable_deploy "$FILE_CONSUMER"

    # The local app announces where its names came from and what they are;
    # session temp names prove the file read went through the operator's
    # content override, not the ConfigMap on disk.
    grep -q "Names:    from /config/nats.yaml" "$SESSION_LOG" && r=0 || r=1
    check "config file: local app read its names from the mounted file" "$r"
    grep -qE "Stream:   mirrord-tmp-" "$SESSION_LOG" && r=0 || r=1
    check "config file: the file served locally carries the session stream" "$r"

    # The cluster pod must be running on a rewritten ConfigMap copy while the
    # user's original stays untouched. The swap is injected into the PODS by
    # the pod mutator - the deployment object stays clean by design - so the
    # running pod's volume is what to inspect.
    current_cm=""
    waited=0
    while [ "$waited" -lt 90 ]; do
      current_cm="$(kubectl get pod -n "$NAMESPACE" -l "app=$FILE_CONSUMER" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].spec.volumes[?(@.name=="app-config")].configMap.name}' 2>/dev/null || true)"
      if [ -n "$current_cm" ] && [ "$current_cm" != "$FILE_CM" ]; then break; fi
      sleep 3; waited=$((waited + 3))
    done
    [ -n "$current_cm" ] && [ "$current_cm" != "$FILE_CM" ] && r=0 || r=1
    check "config file: cluster pod swapped onto a ConfigMap copy ($current_cm)" "$r"
    copy_content="$(kubectl get cm "$current_cm" -n "$NAMESPACE" -o jsonpath='{.data.nats\.yaml}' 2>/dev/null || true)"
    # BOTH lines must be rewritten: a fallback map missing one entity leaves a
    # half-rewritten copy whose pod then competes with the forwarder on the
    # original stream.
    printf '%s' "$copy_content" | grep -q "stream: mirrord-tmp-" \
      && printf '%s' "$copy_content" | grep -q "consumer: mirrord-tmp-" && r=0 || r=1
    check "config file: the copy points the cluster pod at the fallback names" "$r"
    orig_content="$(kubectl get cm "$FILE_CM" -n "$NAMESPACE" -o jsonpath='{.data.nats\.yaml}' 2>/dev/null || true)"
    printf '%s' "$orig_content" | grep -q "ORDERS-FILE" && r=0 || r=1
    check "config file: the original ConfigMap is untouched" "$r"

    publish_to "$FILE_SUBJECT" acme premium "file-acme-$RUN_TAG" && ok "sent tenant=acme (should be stolen)" \
      || check "config file: publishing the matching message" 1
    publish_to "$FILE_SUBJECT" other basic "file-other-$RUN_TAG" && ok "sent tenant=other (should stay in cluster)" \
      || check "config file: publishing the non-matching message" 1
    settle

    grep -q "file-acme-$RUN_TAG" "$SESSION_LOG" && r=0 || r=1
    check "config file: local session received the matching message" "$r"
    kubectl logs -n "$NAMESPACE" -l "app=$FILE_CONSUMER" --prefix --tail=300 >"$WORKDIR/file-cluster.log" 2>/dev/null || true
    grep -q "file-other-$RUN_TAG" "$WORKDIR/file-cluster.log" && r=0 || r=1
    check "config file: deployed consumer received the non-matching message" "$r"
    ! grep -q "file-acme-$RUN_TAG" "$WORKDIR/file-cluster.log" && r=0 || r=1
    check "config file: deployed consumer did NOT get the stolen message" "$r"
  else
    check "config file: split session reached Ready" 1
  fi
  assert_cleanup "config file"

  # Teardown must hand the pods their original ConfigMap back (the unpatch
  # replaces the mutated pods, so check the running pod like above).
  restored=1
  waited=0
  while [ "$waited" -lt 120 ]; do
    current_cm="$(kubectl get pod -n "$NAMESPACE" -l "app=$FILE_CONSUMER" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].spec.volumes[?(@.name=="app-config")].configMap.name}' 2>/dev/null || true)"
    if [ "$current_cm" = "$FILE_CM" ]; then restored=0; break; fi
    sleep 3; waited=$((waited + 3))
  done
  check "config file: volume restored to the original ConfigMap" "$restored"
  wait_for_stable_deploy "$FILE_CONSUMER"
fi


# ---------------------------------------------------------------------------
# Scenario: core NATS pub/sub (no JetStream, best-effort)
# ---------------------------------------------------------------------------
if picked "pubsub"; then
  banner "Scenario: pubsub (core NATS)" \
    "plain subject subscription - no streams, nothing persisted on the server"

  PUBSUB_CONSUMER="nats-pubsub-consumer"
  PUBSUB_SUBJECT="pubsub-orders.new"

  say "Starting the mirrord session (log: $WORKDIR/pubsub.log)"
  if start_session "$OVERLAY/mirrord-pubsub.json" "$WORKDIR/pubsub.log"; then
    ok "split session Ready"
    wait_for_stable_deploy "$PUBSUB_CONSUMER"

    # The local app must be subscribed before publishing: core pub/sub keeps
    # nothing for late subscribers.
    sub_ready=1
    waited=0
    while [ "$waited" -lt 60 ]; do
      if grep -q "Listening for messages" "$SESSION_LOG"; then sub_ready=0; break; fi
      sleep 2; waited=$((waited + 2))
    done
    check "pubsub: local app subscribed (core mode)" "$sub_ready"
    grep -q "core pub/sub mode" "$SESSION_LOG" && r=0 || r=1
    check "pubsub: local app runs in core pub/sub mode on a rewritten subject" "$r"

    # The defining property of this broker: the server holds NO temporary
    # streams - subjects are just names.
    [ "$(tmp_stream_count)" = 0 ] && r=0 || r=1
    check "pubsub: no mirrord-tmp streams exist on the server" "$r"

    publish_to "$PUBSUB_SUBJECT" acme premium "pubsub-acme-$RUN_TAG" && ok "sent tenant=acme (should be stolen)" \
      || check "pubsub: publishing the matching message" 1
    publish_to "$PUBSUB_SUBJECT" other basic "pubsub-other-$RUN_TAG" && ok "sent tenant=other (should stay in cluster)" \
      || check "pubsub: publishing the non-matching message" 1
    settle

    grep -q "pubsub-acme-$RUN_TAG" "$SESSION_LOG" && r=0 || r=1
    check "pubsub: local session received the matching message" "$r"
    ! grep -q "pubsub-other-$RUN_TAG" "$SESSION_LOG" && r=0 || r=1
    check "pubsub: local session did NOT get the non-matching message" "$r"
    kubectl logs -n "$NAMESPACE" -l "app=$PUBSUB_CONSUMER" --prefix --tail=300 >"$WORKDIR/pubsub-cluster.log" 2>/dev/null || true
    grep -q "pubsub-other-$RUN_TAG" "$WORKDIR/pubsub-cluster.log" && r=0 || r=1
    check "pubsub: deployed consumer received the non-matching message" "$r"
    ! grep -q "pubsub-acme-$RUN_TAG" "$WORKDIR/pubsub-cluster.log" && r=0 || r=1
    check "pubsub: deployed consumer did NOT get the stolen message" "$r"
  else
    check "pubsub: split session reached Ready" 1
  fi
  assert_cleanup "pubsub"

  # Teardown must hand the pod its original subject back.
  restored=1
  waited=0
  while [ "$waited" -lt 120 ]; do
    current_subject="$(kubectl get pod -n "$NAMESPACE" -l "app=$PUBSUB_CONSUMER" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="NATS_SUBJECT")].value}' 2>/dev/null || true)"
    if [ "$current_subject" = "pubsub-orders.>" ]; then restored=0; break; fi
    sleep 3; waited=$((waited + 3))
  done
  check "pubsub: subject restored to the original on the cluster pod" "$restored"
  wait_for_stable_deploy "$PUBSUB_CONSUMER"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "Summary"
# ${arr[@]+...} guards the expansion: macOS bash 3.2 + `set -u` errors on an
# empty array otherwise.
for line in ${RESULTS[@]+"${RESULTS[@]}"}; do
  case "$line" in
    PASS*) printf '\033[0;32m%s\033[0m\n' "$line" ;;
    *)     printf '\033[0;31m%s\033[0m\n' "$line" ;;
  esac
done
echo

if [ "$FAILURES" = 0 ]; then
  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border double --padding "0 2" --border-foreground 82 --foreground 82 \
      "NATS queue splitting works end to end 🎉"
  else
    printf '\033[0;32mNATS queue splitting works end to end\033[0m\n'
  fi
  info "logs kept in $WORKDIR"
else
  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border double --padding "0 2" --border-foreground 196 --foreground 196 \
      "$FAILURES check(s) failed - logs in $WORKDIR"
  else
    printf '\033[0;31m%s check(s) failed - logs in %s\033[0m\n' "$FAILURES" "$WORKDIR"
  fi
  exit 1
fi
