#!/usr/bin/env bash
# E2E for database branching WITHOUT a live source pod (the "start_idle + db_branches"
# issue: sessions used to fail target resolution with
# "no Pod is ready to be a session target: no pods found").
#
# Scenario matrix, all against targets scaled to ZERO replicas:
#
#   1. branch-only     - db branch with plain env-var params, incoming off, no queues:
#                        session Ready, branch provisioned from the pod TEMPLATE, branch
#                        env injected into the preview pod, target never scaled up
#   2. idle + split    - db branch + split_queues + idle.start_idle: session reaches
#                        Idle with zero preview pods AND zero target pods, branch env on
#                        the preview deployment spec; a matching kafka message wakes it
#                        to Ready and the booted pod carries the branch env
#   3. incoming steal  - db branch + network.incoming (steal) needs an agent on a target
#                        pod: the session must FAIL naming `network.incoming`, not with
#                        the generic "no Pod is ready" error
#   4. value_pattern   - a pattern-based branch param reads the target's RUNTIME env
#                        through an agent: the session must FAIL naming `value_pattern`
#
# Prereqs:
#   - sandbox cluster up, operator with previewEnv + db branching + kafka splitting
#     (operator:dev on the current branch, or a deployed operator with the fix)
#   - kafka overlay for scenario 2: task kafka:deploy   (broker, kafka-consumer app,
#     MirrordKafkaTopicsConsumer for topic id "test-topic")
#   - `task`, `kubectl`, python3; mirrord CLI from the branch (MIRRORD_BIN or .env)
#
# Usage:
#   ./scripts/test-preview-db-branch-podless.sh
#   SKIP_DEPLOY=1 ./scripts/test-preview-db-branch-podless.sh   # targets already deployed
#   ONLY=1,3 ./scripts/test-preview-db-branch-podless.sh        # run a subset
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="test-mirrord"
KEY_BASIC="podless-basic"
KEY_IDLE="podless-idle"
KEY_STEAL="podless-steal"
KEY_PATTERN="podless-pattern"
CONSUMER_DEPLOY="kafka-consumer"
TOPIC="test-topic"
# BSD/macOS mktemp only substitutes TRAILING X's, so use a temp dir with fixed names inside.
CONFIG_DIR="$(mktemp -d /tmp/mirrord-preview-db-branch-podless.XXXXXX)" \
  || { echo "mktemp failed"; exit 1; }
FAILURES=0
ONLY="${ONLY:-1,2,3,4}"

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
runs() { case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac }

CONSUMER_ORIGINAL_REPLICAS=""
PATTERN_ORIGINAL_REPLICAS=""

cleanup() {
  say "Cleaning up sessions, branches, and replica counts"
  local key
  for key in "$KEY_BASIC" "$KEY_IDLE" "$KEY_STEAL" "$KEY_PATTERN"; do
    MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview stop -k "$key" >/dev/null 2>&1 || true
  done
  # Branch CRs outlive failed sessions until their TTL - delete the ones this run minted.
  local branch
  for branch in $(kubectl get branchdatabases -n "$NS" -o json 2>/dev/null | python3 -c '
import json, sys
for item in json.load(sys.stdin).get("items", []):
    if (item.get("spec") or {}).get("id", "").startswith("pg-preview-podless-"):
        print(item["metadata"]["name"])
' 2>/dev/null); do
    kubectl delete branchdatabase "$branch" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
  done
  [ -n "$CONSUMER_ORIGINAL_REPLICAS" ] \
    && kubectl scale deploy "$CONSUMER_DEPLOY" -n "$NS" --replicas="$CONSUMER_ORIGINAL_REPLICAS" >/dev/null 2>&1
  [ -n "$PATTERN_ORIGINAL_REPLICAS" ] \
    && kubectl scale deploy echo-app-pattern -n "$NS" --replicas="$PATTERN_ORIGINAL_REPLICAS" >/dev/null 2>&1
  rm -rf "$CONFIG_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------- helpers

session_of() { # key -> session name
  kubectl get previewsessions -n "$NS" \
    -o jsonpath="{.items[?(@.spec.key==\"$1\")].metadata.name}" 2>/dev/null | awk '{print $1}'
}
phase_of()   { kubectl get previewsession "$1" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null; }
failure_of() { kubectl get previewsession "$1" -n "$NS" -o jsonpath='{.status.failureMessage}' 2>/dev/null; }
replicas_of() { kubectl get deploy "$1" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null; }

wait_for_phase() { # session expected timeout_secs -> 0/1
  local session="$1" expected="$2" deadline=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(phase_of "$session")" = "$expected" ] && return 0
    sleep 3
  done
  return 1
}

wait_for_no_pods() { # label-selector timeout_secs -> 0/1
  local selector="$1" deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -z "$(kubectl get pods -n "$NS" -l "$selector" -o name 2>/dev/null)" ] && return 0
    sleep 2
  done
  return 1
}

# The target must never have been scaled up: a scaled-up target proves nothing about
# podless resolution.
assert_target_stayed_at_zero() { # deployment
  local ready
  ready=$(kubectl get deploy "$1" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "$(replicas_of "$1")" = "0" ] && [ -z "$ready" ]; then
    ok "target $1 still has zero pods"
  else
    bug "target $1 was scaled up (replicas $(replicas_of "$1"), ready ${ready:-0})"
  fi
}

branch_of() { # branch-id -> branchdatabase CR name
  kubectl get branchdatabases -n "$NS" \
    -o jsonpath="{range .items[?(@.spec.id==\"$1\")]}{.metadata.name}{end}" 2>/dev/null
}

assert_branch_exists() { # branch-id
  local branch
  branch=$(branch_of "$1")
  if [ -n "$branch" ]; then
    ok "branchdatabase $branch ($(kubectl get branchdatabase "$branch" -n "$NS" \
      -o jsonpath='{.status.phase}' 2>/dev/null)) provisioned without a source pod"
  else
    bug "no branchdatabase with spec.id=$1"
  fi
}

# DB_HOST on a preview pod (runtime) or the preview deployment spec (idle - no pod yet).
preview_runtime_db_host() { # session
  kubectl exec -n "$NS" "deploy/$1" -- sh -c 'echo $DB_HOST' 2>/dev/null
}
preview_spec_db_host() { # session
  kubectl get deploy "$1" -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DB_HOST")].value}' 2>/dev/null
}

assert_branch_host() { # value source-description
  if [ -n "$1" ] && [ "$1" != "postgres-test" ]; then
    ok "$2 DB_HOST points at the branch ($1), not the source"
  else
    bug "$2 DB_HOST is '${1:-<empty>}' - the branch override was not injected"
  fi
}

expect_start_failure() { # config key timeout expected-needle... -> asserts
  local config="$1" key="$2" timeout="$3"; shift 3
  if MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview start \
      -f "$config" -i echo-app:latest -k "$key" --timeout "$timeout" >/dev/null 2>&1; then
    bug "preview start for key $key succeeded, but this scenario needs an agent on a live pod"
    return
  fi
  local session message needle
  session=$(session_of "$key")
  if [ -z "$session" ]; then
    bug "no session found for key $key after the expected failure"
    return
  fi
  wait_for_phase "$session" Failed 30 || true
  message=$(failure_of "$session")
  info "failure message: ${message:-<empty>}"
  for needle in "$@"; do
    case "$message" in
      *"$needle"*) ok "failure names '$needle'" ;;
      *) bug "failure message does not mention '$needle'" ;;
    esac
  done
  kubectl delete previewsession "$session" -n "$NS" --ignore-not-found >/dev/null 2>&1
}

send_kafka_message() { # user_id message
  local pod
  pod=$(kubectl get pod -n "$NS" -l app=kafka-cluster \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || return 1
  printf 'user_id:%s|%s' "$1" "$2" | kubectl exec -i -n "$NS" "$pod" -- \
    /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
    --topic "$TOPIC" --property 'parse.headers=true' --property 'headers.delimiter=|' 2>/dev/null
}

# ---------------------------------------------------------------- prereqs

say "Checking prerequisites"
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "namespace $NS unreachable"; exit 1; }
kubectl get crd previewsessions.preview.mirrord.metalbear.co >/dev/null 2>&1 \
  || { echo "PreviewSession CRD missing - enable operator.previewEnv"; exit 1; }

if [ -z "${SKIP_DEPLOY:-}" ]; then
  info "deploying the podless target (SKIP_DEPLOY=1 to skip)"
  task -d "$ROOT" preview:podless:deploy >/dev/null || { echo "podless target deploy failed"; exit 1; }
fi
kubectl get deploy echo-app-podless -n "$NS" >/dev/null 2>&1 \
  || { echo "echo-app-podless missing - run: task preview:podless:deploy"; exit 1; }

# Same marker rule as the sandbox tasks - with operator:dev running, sessions must be
# labeled so YOUR operator handles them.
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
fi

# ---------------------------------------------------------------- scenario 1

if runs 1; then
  say "[1/4] branch-only: db branch against a zero-pod target reaches Ready"
  if MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview start \
      -f "$ROOT/apps/echo-app/mirrord-preview-podless.json" \
      -i echo-app:latest -k "$KEY_BASIC" --timeout 300; then
    SESSION=$(session_of "$KEY_BASIC")
    info "session: $SESSION (phase $(phase_of "$SESSION"))"
    [ "$(phase_of "$SESSION")" = "Ready" ] \
      && ok "phase Ready with zero target pods (used to fail with 'no Pod is ready')" \
      || bug "expected Ready, got $(phase_of "$SESSION")"
    assert_target_stayed_at_zero echo-app-podless
    assert_branch_exists "pg-preview-podless-$KEY_BASIC"
    assert_branch_host "$(preview_runtime_db_host "$SESSION")" "preview pod runtime"
    MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview stop -k "$KEY_BASIC" >/dev/null 2>&1 || true
  else
    bug "preview start failed - the podless db branch session did not come up"
    SESSION=$(session_of "$KEY_BASIC")
    [ -n "$SESSION" ] && info "failure message: $(failure_of "$SESSION")"
  fi
fi

# ---------------------------------------------------------------- scenario 2

if runs 2; then
  say "[2/4] idle + split: start_idle + db branch + split_queues against a zero-pod target"
  if ! kubectl get deploy "$CONSUMER_DEPLOY" -n "$NS" >/dev/null 2>&1 \
     || ! kubectl get pod -n "$NS" -l app=kafka-cluster -o name 2>/dev/null | grep -q .; then
    bug "kafka overlay missing - run: task kafka:deploy (needed for the idle wake source)"
  else
    # The branch source resolves from the target's pod template, so the consumer needs the
    # DB_* vars there. They are inert for the consumer app itself.
    kubectl set env "deploy/$CONSUMER_DEPLOY" -n "$NS" \
      DB_HOST=postgres-test DB_PORT=5432 DB_NAME=source_db DB_USER=postgres DB_PASSWORD=postgres \
      >/dev/null
    kubectl apply -k "$ROOT/k8s/postgres" >/dev/null
    CONSUMER_ORIGINAL_REPLICAS=$(replicas_of "$CONSUMER_DEPLOY")
    kubectl scale deploy "$CONSUMER_DEPLOY" -n "$NS" --replicas=0 >/dev/null
    wait_for_no_pods "app=$CONSUMER_DEPLOY" 90 || bug "consumer pods still around after scale to 0"

    python3 - "$ROOT/apps/echo-app/mirrord-preview-podless.json" "$CONFIG_DIR/idle.json" \
        "$CONSUMER_DEPLOY" "$TOPIC" "$KEY_IDLE" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
config["target"]["path"] = f"deploy/{sys.argv[3]}"
config["feature"]["preview"]["idle"] = {"start_idle": True, "wake_timeout_secs": 120}
config["feature"]["split_queues"] = {
    sys.argv[4]: {"queue_type": "Kafka", "message_filter": {"user_id": f"^{sys.argv[5]}$"}}
}
json.dump(config, open(sys.argv[2], "w"), indent=2)
PY

    if MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview start \
        -f "$CONFIG_DIR/idle.json" -i kafka-consumer:local -k "$KEY_IDLE" --timeout 300; then
      SESSION=$(session_of "$KEY_IDLE")
      info "session: $SESSION (phase $(phase_of "$SESSION"))"
      wait_for_phase "$SESSION" Idle 60 \
        && ok "born Idle: zero preview pods AND zero target pods" \
        || bug "start_idle session never reached Idle (phase $(phase_of "$SESSION"))"
      [ "$(replicas_of "$SESSION")" = "0" ] \
        && ok "preview deployment created with 0 replicas" \
        || bug "expected 0 preview replicas, got $(replicas_of "$SESSION")"
      assert_target_stayed_at_zero "$CONSUMER_DEPLOY"
      assert_branch_exists "pg-preview-podless-$KEY_IDLE"
      assert_branch_host "$(preview_spec_db_host "$SESSION")" "preview deployment spec"

      info "sending a matching kafka message (user_id=$KEY_IDLE) to wake the session"
      send_kafka_message "$KEY_IDLE" "wake up, branch" || bug "failed to produce the kafka message"
      wait_for_phase "$SESSION" Ready 180 \
        && ok "queue message woke the idle session to Ready" \
        || bug "session never woke (phase $(phase_of "$SESSION"))"
      assert_branch_host "$(preview_runtime_db_host "$SESSION")" "woken preview pod runtime"
      MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview stop -k "$KEY_IDLE" >/dev/null 2>&1 || true
    else
      bug "preview start failed for the idle + split + branch session"
      SESSION=$(session_of "$KEY_IDLE")
      [ -n "$SESSION" ] && info "failure message: $(failure_of "$SESSION")"
    fi
  fi
fi

# ---------------------------------------------------------------- scenario 3

if runs 3; then
  say "[3/4] incoming steal against a zero-pod target must fail naming network.incoming"
  python3 - "$ROOT/apps/echo-app/mirrord-preview-podless.json" "$CONFIG_DIR/steal.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
config["feature"]["network"]["incoming"] = {
    "mode": "steal",
    "http_filter": {"header_filter": "X-Preview: {{ key }}"},
}
json.dump(config, open(sys.argv[2], "w"), indent=2)
PY
  expect_start_failure "$CONFIG_DIR/steal.json" "$KEY_STEAL" 120 \
    "requires a mirrord agent" "network.incoming"
fi

# ---------------------------------------------------------------- scenario 4

if runs 4; then
  say "[4/4] value_pattern branch against a zero-pod target must fail naming value_pattern"
  if [ -z "${SKIP_DEPLOY:-}" ]; then
    task -d "$ROOT" preview:pattern:deploy >/dev/null || { echo "pattern target deploy failed"; exit 1; }
  fi
  if kubectl get deploy echo-app-pattern -n "$NS" >/dev/null 2>&1; then
    PATTERN_ORIGINAL_REPLICAS=$(replicas_of echo-app-pattern)
    kubectl scale deploy echo-app-pattern -n "$NS" --replicas=0 >/dev/null
    wait_for_no_pods "app=echo-app-pattern" 90 || bug "pattern pods still around after scale to 0"
    expect_start_failure "$ROOT/apps/echo-app/mirrord-preview-pattern.json" "$KEY_PATTERN" 120 \
      "requires a mirrord agent" "value_pattern"
  else
    bug "echo-app-pattern missing - run: task preview:pattern:deploy"
  fi
fi

# ---------------------------------------------------------------- verdict

say "Verdict"
if [ "$FAILURES" -eq 0 ]; then
  ok "db branching without a live source pod: all scenarios passed"
else
  bug "$FAILURES check(s) failed - see above"
  exit 1
fi
