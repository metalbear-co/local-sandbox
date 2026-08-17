#!/usr/bin/env bash
# Automated repro of Ari's kafka-demo preview-idle findings on the local sandbox.
#
# Phase SHORT (sleep_after_secs=30): the preview pod is woken by a matched message but
#   the idle window is too short to boot + join the consumer group + commit, so the
#   message stays unconsumed (CURRENT-OFFSET=- with growing lag) - his issue 1.
# Phase LONG (sleep_after_secs=300): his fix - same flow, the message must be consumed.
# Phase CROSSWAKE: two idle previews (service-b-ev + service-c-ev) share the session key;
#   one message routed for B must wake only B. The unpatched operator wakes every idle
#   preview sharing the key (it matches events on key alone, not the target workload),
#   so C scaling up before B has even consumed = the cross-wake bug.
#
# Exit 0 = LONG delivered and no cross-wake. Exit 2 = cross-wake reproduced (deploy an
# operator with the wake-scoping fix). The SHORT phase result is reported as
# REPRODUCED / NOT REPRODUCED (it is timing-dependent by nature).
#
# Requires: kafka-demo deployed (task kafka-demo:deploy) and a local mirrord CLI build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
PLAYGROUND_DIR="${PLAYGROUND_DIR:-$ROOT_DIR/../playground}"
CONTEXT="${CONTEXT:-bearkube}"
NS=kafka-demo-event
INFRA_NS=infra
KEY="${KEY:-changed-responce}"
SLEEP_SHORT="${SLEEP_SHORT:-30}"
SLEEP_LONG="${SLEEP_LONG:-300}"
# Space-separated subset of "short long crosswake" for running one phase at a time;
# a skipped phase counts as passed in the exit code.
PHASES="${PHASES:-short long crosswake}"
LOG_DIR="${TMPDIR:-/tmp}/kafka-demo-idle-test"
mkdir -p "$LOG_DIR"

if [ -z "${MIRRORD_BIN:-}" ]; then
  for candidate in "$ROOT_DIR"/../mirrord/target/*/debug/mirrord; do
    [ -x "$candidate" ] && MIRRORD_BIN="$candidate" && break
  done
fi
MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"

REGISTRY="${REGISTRY:-ghcr.io/metalbear-co}"

PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  pkill -f '/tmp/kafka-demo-service-b' 2>/dev/null || true
  pkill -f '/tmp/kafka-demo-service-c' 2>/dev/null || true
}
trap cleanup EXIT

kafka_exec() {
  kubectl --context "$CONTEXT" -n "$INFRA_NS" exec kafka-0 -- "$@" 2>/dev/null
}

temp_topic() { # temp_topic <b|c> - the split's temp topic for that service's input
  kafka_exec /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list \
    | grep -E "^mirrord-tmp-.*ev\.$1" | head -1
}

# Prints "<current-offset> <log-end>" for the app group on the given topic, "-" if absent.
group_position() {
  kafka_exec /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
    --describe --all-groups 2>/dev/null \
    | awk -v t="$1" '$2 == t { print $4, $5; found=1 } END { if (!found) print "- -" }'
}

trigger_matched() {
  kubectl --context "$CONTEXT" -n "$NS" port-forward svc/gateway-ev 18092:80 >/dev/null 2>&1 &
  local pf=$!
  for i in $(seq 1 20); do curl -sf http://localhost:18092/health >/dev/null 2>&1 && break; sleep 1; done
  curl -sf -X POST http://localhost:18092/kafka-demo-ev/produce \
    -H 'Content-Type: application/json' \
    -d "{\"payload\":\"$1\",\"session\":\"$KEY\"}" >/dev/null
  kill "$pf" 2>/dev/null || true
}

render_config() { # render_config <b|c> <sleep_secs> -> /tmp/kafka-demo-preview-idle-<svc>.json
  python3 - "$1" "$2" << 'PYEOF'
import json, os, sys
svc, sleep_secs = sys.argv[1], int(sys.argv[2])
root = os.environ["SANDBOX_ROOT"]
cfg = json.load(open(f"{root}/configs/kafka-demo/mirrord-event-prev-idle-service-{svc}.json"))
cfg["key"] = os.environ["KEY"]
cfg["feature"]["preview"]["idle"]["sleep_after_secs"] = sleep_secs
# Only :latest is loaded into minikube; any other tag would hit GHCR.
cfg["feature"]["preview"]["image"] = f"{os.environ['REGISTRY']}/playground-kafka-demo-service-{svc}:latest"
cfg["feature"].pop("db_branches", None)
json.dump(cfg, open(f"/tmp/kafka-demo-preview-idle-{svc}.json", "w"), indent=2)
PYEOF
}

start_session() { # start_session <b|c> <log_file> -> echoes the pid
  MIRRORD_KUBE_CONTEXT="$CONTEXT" "$MIRRORD_BIN" exec -f "/tmp/kafka-demo-preview-idle-$1.json" \
    -- "/tmp/kafka-demo-service-$1" >"$2" 2>&1 &
  echo $!
}

# The preview deployment is named after the session, so it is found by image: the only
# non "-ev" deployment running the service's image.
preview_deploy() { # preview_deploy <b|c>
  kubectl --context "$CONTEXT" -n "$NS" get deploy \
    -o jsonpath='{range .items[*]}{.metadata.name} {.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
    | awk -v img="kafka-demo-service-$1" '$1 !~ /-ev$/ && $2 ~ img { print $1; exit }'
}

preview_replicas() { # preview_replicas <deploy_name> -> spec.replicas, "-" if gone or unset
  local replicas
  replicas="$(kubectl --context "$CONTEXT" -n "$NS" get deploy "$1" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)" || replicas=""
  echo "${replicas:--}"
}

wait_temp_topic_gone() { # wait_temp_topic_gone <b|c>
  for i in $(seq 1 40); do
    [ -z "$(temp_topic "$1" || true)" ] && break
    sleep 3
  done
}

run_phase() { # run_phase <name> <sleep_secs> <consume_deadline_s> -> sets PHASE_DELIVERED
  local name=$1 sleep_secs=$2 deadline=$3
  echo ""
  echo "==> PHASE $name: preview-idle session with sleep_after_secs=$sleep_secs"

  render_config b "$sleep_secs"

  local session_log="$LOG_DIR/session-$name.log"
  : > "$session_log"
  local mm
  mm=$(start_session b "$session_log")
  PIDS+=("$mm")

  echo "    waiting for the split's temp topic to appear (session log: $session_log)"
  local topic=""
  for i in $(seq 1 60); do
    topic="$(temp_topic b || true)"
    [ -n "$topic" ] && break
    if ! kill -0 "$mm" 2>/dev/null; then
      echo "    mirrord session exited early - last log lines:"
      tail -5 "$session_log" | sed 's/^/      /'
      exit 1
    fi
    sleep 3
  done
  [ -z "$topic" ] && { echo "    temp topic never appeared"; tail -5 "$session_log" | sed 's/^/      /'; exit 1; }
  echo "    temp topic: $topic"
  sleep 5

  local marker="idle-test-$name-$(date +%s)"
  echo "    producing 1 matched message ($marker) - this should wake the preview"
  trigger_matched "$marker"

  local delivered=no start now current end
  start=$(date +%s)
  while :; do
    read -r current end <<< "$(group_position "$topic")"
    now=$(( $(date +%s) - start ))
    echo "    t+${now}s: group offset on temp topic: current=$current log-end=$end"
    if [ "$current" != "-" ] && [ "$current" -ge 1 ] 2>/dev/null; then
      delivered=yes
      break
    fi
    [ "$now" -ge "$deadline" ] && break
    sleep 10
  done
  PHASE_DELIVERED=$delivered

  echo "    stopping the session"
  kill "$mm" 2>/dev/null || true
  wait "$mm" 2>/dev/null || true
  # Let the operator tear down the split before the next phase reuses the topic name.
  wait_temp_topic_gone b
}

run_crosswake() { # -> sets CROSSWAKE_RESULT to fixed | reproduced | inconclusive
  echo ""
  echo "==> PHASE crosswake: idle previews for B and C share the key; a message for B must wake only B"

  render_config b "$SLEEP_LONG"
  render_config c "$SLEEP_LONG"

  local log_b="$LOG_DIR/session-crosswake-b.log" log_c="$LOG_DIR/session-crosswake-c.log"
  : > "$log_b"; : > "$log_c"
  local pid_b pid_c
  pid_b=$(start_session b "$log_b")
  pid_c=$(start_session c "$log_c")
  PIDS+=("$pid_b" "$pid_c")

  echo "    waiting for both splits' temp topics (logs: $log_b, $log_c)"
  local topic_b="" topic_c=""
  for i in $(seq 1 60); do
    topic_b="$(temp_topic b || true)"
    topic_c="$(temp_topic c || true)"
    [ -n "$topic_b" ] && [ -n "$topic_c" ] && break
    for pid in "$pid_b" "$pid_c"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "    a mirrord session exited early - session log tails:"
        tail -5 "$log_b" "$log_c" | sed 's/^/      /'
        exit 1
      fi
    done
    sleep 3
  done
  if [ -z "$topic_b" ] || [ -z "$topic_c" ]; then
    echo "    temp topics never appeared (b='$topic_b' c='$topic_c')"
    tail -5 "$log_b" "$log_c" | sed 's/^/      /'
    exit 1
  fi

  local deploy_b="" deploy_c=""
  for i in $(seq 1 20); do
    deploy_b="$(preview_deploy b || true)"
    deploy_c="$(preview_deploy c || true)"
    [ -n "$deploy_b" ] && [ -n "$deploy_c" ] && break
    sleep 3
  done
  if [ -z "$deploy_b" ] || [ -z "$deploy_c" ]; then
    echo "    preview deployments not found (b='$deploy_b' c='$deploy_c')"
    exit 1
  fi
  echo "    preview deployments: B=$deploy_b C=$deploy_c (both start idle at 0 replicas)"
  sleep 5

  local marker="crosswake-$(date +%s)"
  echo "    producing 1 matched message ($marker) - routed for B's split only"
  trigger_matched "$marker"

  # The cross-wake fires when B's forwarder routes the message, seconds after the
  # trigger and long before B's cold preview consumes it. A legitimate C wake needs
  # B to consume first (B writes the row, cronjob-z produces C's input), so
  # "C scaled up while B had consumed nothing" can only be the cross-wake.
  CROSSWAKE_RESULT=inconclusive
  local start now rep_b rep_c cur end
  start=$(date +%s)
  while :; do
    rep_b="$(preview_replicas "$deploy_b")"
    rep_c="$(preview_replicas "$deploy_c")"
    read -r cur end <<< "$(group_position "$topic_b")"
    now=$(( $(date +%s) - start ))
    echo "    t+${now}s: B replicas=$rep_b consumed=$cur/$end | C replicas=$rep_c"
    if [ "$rep_c" != "0" ] && [ "$rep_c" != "-" ]; then
      CROSSWAKE_RESULT=reproduced
      break
    fi
    if [ "$cur" != "-" ] && [ "$cur" -ge 1 ] 2>/dev/null; then
      CROSSWAKE_RESULT=fixed
      break
    fi
    [ "$now" -ge 240 ] && break
    sleep 3
  done

  echo "    stopping both sessions"
  kill "$pid_b" "$pid_c" 2>/dev/null || true
  wait "$pid_b" "$pid_c" 2>/dev/null || true
  wait_temp_topic_gone b
  wait_temp_topic_gone c
}

echo "==> Sanity: unmatched message through the deployed chain"
SANITY="sanity-$(date +%s)"
kubectl --context "$CONTEXT" -n "$NS" port-forward svc/gateway-ev 18092:80 >/dev/null 2>&1 &
PF=$!
for i in $(seq 1 20); do curl -sf http://localhost:18092/health >/dev/null 2>&1 && break; sleep 1; done
curl -sf -X POST http://localhost:18092/kafka-demo-ev/produce \
  -H 'Content-Type: application/json' -d "{\"payload\":\"$SANITY\"}" >/dev/null
kill "$PF" 2>/dev/null || true
for i in $(seq 1 15); do
  kubectl --context "$CONTEXT" -n "$NS" logs deploy/service-b-ev --since=2m 2>/dev/null | grep -q "$SANITY" && break
  sleep 2
done
if kubectl --context "$CONTEXT" -n "$NS" logs deploy/service-b-ev --since=2m 2>/dev/null | grep -q "$SANITY"; then
  echo "    OK - deployed service-b-ev consumed the unmatched message"
else
  echo "    FAILED - the base chain is not working; fix that before testing sessions"
  exit 1
fi

export SANDBOX_ROOT="$ROOT_DIR" KEY REGISTRY

for svc in b c; do
  (cd "$PLAYGROUND_DIR" && go build -o "/tmp/kafka-demo-service-$svc" "./apps/kafka-demo/service-$svc")
done

SHORT_DELIVERED=skipped LONG_DELIVERED=skipped CROSSWAKE_RESULT=skipped

case " $PHASES " in *" short "*)
  run_phase short "$SLEEP_SHORT" 90
  SHORT_DELIVERED=$PHASE_DELIVERED ;;
esac
case " $PHASES " in *" long "*)
  run_phase long "$SLEEP_LONG" 240
  LONG_DELIVERED=$PHASE_DELIVERED ;;
esac
case " $PHASES " in *" crosswake "*)
  run_crosswake ;;
esac

echo ""
echo "===================== VERDICTS ====================="
case "$SHORT_DELIVERED" in
  no)  echo "ISSUE 1 REPRODUCED  sleep_after_secs=$SLEEP_SHORT: the woken preview never consumed (group offset stayed '-')" ;;
  yes) echo "NOT REPRODUCED      sleep_after_secs=$SLEEP_SHORT: message was consumed anyway (this machine joins the group fast enough)" ;;
esac
case "$LONG_DELIVERED" in
  yes) echo "FIX VERIFIED        sleep_after_secs=$SLEEP_LONG: message consumed by the preview" ;;
  no)  echo "FIX FAILED          sleep_after_secs=$SLEEP_LONG: message was NOT consumed - inspect $LOG_DIR/session-long.log and 'task kafka-demo:offsets'" ;;
esac
case "$CROSSWAKE_RESULT" in
  fixed)        echo "CROSS-WAKE FIXED    B consumed while C's preview stayed at 0 replicas - wakes are scoped to the target workload" ;;
  reproduced)   echo "CROSS-WAKE BUG      C's preview scaled up before B consumed anything - key-only wake matching (deploy an operator with the wake-scoping fix)" ;;
  inconclusive) echo "CROSS-WAKE UNKNOWN  B never consumed within the window - inspect $LOG_DIR/session-crosswake-*.log" ;;
esac
echo "===================================================="
[ "$LONG_DELIVERED" = no ] && exit 1
[ "$CROSSWAKE_RESULT" = reproduced ] || [ "$CROSSWAKE_RESULT" = inconclusive ] && exit 2
exit 0
