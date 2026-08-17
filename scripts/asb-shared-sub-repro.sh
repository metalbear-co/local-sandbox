#!/usr/bin/env bash
# Reproduces the Azure Service Bus shared-subscription-env bug (client case)
# against a REAL Azure Service Bus namespace, on the topics the sandbox
# already uses (test-topic, test-topic-2):
#
# a split config where EVERY topic's subscription resolves from the SAME env
# var (their Service.ServiceName). The operator creates a different
# per-session mirrord-s-* subscription per topic, but can only write ONE name
# into that env var - and the app (NServiceBus-style auto-provisioning) then
# creates that one name on the other topics itself: unfiltered, unowned by
# any CR, leaked after the session ends.
#
# Prereqs:
#   - sandbox cluster up with the mirrord operator deployed (ASB splitting on)
#   - the Azure connection secret:  task servicebus:multi:secret CONN='Endpoint=sb://...'
#   - `task`, `kubectl`, `go` available; mirrord CLI (MIRRORD_BIN or .env)
#
# Usage:
#   ./scripts/asb-shared-sub-repro.sh            # deploy + run + verdicts
#   SKIP_DEPLOY=1 ./scripts/asb-shared-sub-repro.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/k8s/overlays/servicebus-emulator"
NS="test-mirrord"
# Mixed shape: test-topic + test-topic-2 share ONE subscription env var
# (SERVICEBUS_SERVICE_NAME), test-topic-3 has its OWN (SERVICEBUS_SUBSCRIPTION_1).
TOPICS="test-topic,test-topic-2,test-topic-3"
LOCAL_LOG="$(mktemp /tmp/asb-shared-sub-local.XXXXXX)"
CONSUMER_PID=""

# The sandbox keeps MIRRORD_BIN in .env (task reads it; plain shells do not).
if [ -z "${MIRRORD_BIN:-}" ] && [ -f "$ROOT/.env" ]; then
  MIRRORD_BIN=$(grep -E '^MIRRORD_BIN=' "$ROOT/.env" | tail -1 | cut -d= -f2-)
fi
MIRRORD_BIN="${MIRRORD_BIN:-$(command -v mirrord || true)}"
if [ -z "$MIRRORD_BIN" ] || [ ! -x "$MIRRORD_BIN" ]; then
  echo "mirrord CLI not found - set MIRRORD_BIN or add it to $ROOT/.env"; exit 1
fi

bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
say()  { echo "${bold}==> $*${reset}"; }
ok()   { echo "  ✅ $*"; }
bug()  { echo "  ❌ BUG: $*"; }
info() { echo "     $*"; }

cleanup() {
  if [ -n "$CONSUMER_PID" ] && kill -0 "$CONSUMER_PID" 2>/dev/null; then
    say "Stopping the local mirrord session"
    kill "$CONSUMER_PID" 2>/dev/null
    wait "$CONSUMER_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

if ! kubectl get secret servicebus-azure-conn -n "$NS" >/dev/null 2>&1; then
  echo "Secret servicebus-azure-conn missing. Run first:"
  echo "  task servicebus:multi:secret CONN='Endpoint=sb://...'"
  exit 1
fi
AZURE_CONN=$(kubectl get secret servicebus-azure-conn -n "$NS" -o jsonpath='{.data.connection_string}' | base64 -d)

# The mixed shape needs a third topic; subscriptions are auto-provisioned by
# the app, but topics are not - create it once via az (coordinates from .env).
AZ_RG=$(grep -E '^AZURE_SB_RG=' "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
AZ_NS=$(grep -E '^AZURE_SB_NAMESPACE=' "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
if [ -n "$AZ_RG" ] && [ -n "$AZ_NS" ] && az account show >/dev/null 2>&1; then
  az servicebus topic create -g "$AZ_RG" --namespace-name "$AZ_NS" --name test-topic-3 -o none 2>/dev/null || true
else
  echo "NOTE: make sure topic test-topic-3 exists (az not available to create it)"
fi

# Run the lister as a detached pod and read `kubectl logs` afterwards:
# `kubectl run -i` attaches after the container starts, silently losing the
# first output lines.
list_subs() {
  local name="sb-subs-lister-$RANDOM"
  kubectl run "$name" --restart=Never \
    --image=servicebus-consumer:local --image-pull-policy=Never \
    --namespace="$NS" \
    --env="LIST_MODE=true" \
    --env="SERVICEBUS_CONNECTION_STRING=$AZURE_CONN" \
    --env="SERVICEBUS_TOPICS=$TOPICS" \
    -- /app/consumer >/dev/null 2>&1
  local i phase
  for i in $(seq 1 30); do
    phase=$(kubectl get pod "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
    sleep 2
  done
  kubectl logs -n "$NS" "$name" 2>/dev/null
  kubectl delete pod "$name" -n "$NS" --wait=false >/dev/null 2>&1
}

# Send one message and VERIFY it was accepted by the broker (a swallowed send
# failure would fake a "correctly filtered" verdict). The unique token goes in
# order_id because that's the field the consumer prints.
send_msg() { # topic tenant token
  local name="sb-sender-$RANDOM"
  kubectl run "$name" --restart=Never \
    --image=servicebus-consumer:local --image-pull-policy=Never \
    --namespace="$NS" \
    --env="SEND_MODE=true" \
    --env="SERVICEBUS_CONNECTION_STRING=$AZURE_CONN" \
    --env="SEND_TOPIC=$1" \
    --env="MESSAGE_BODY={\"order_id\":\"$3\",\"tenant\":\"$2\",\"type\":\"repro\"}" \
    --env="MESSAGE_PROPERTIES=tenant=$2" \
    -- /app/consumer >/dev/null 2>&1
  local i phase
  for i in $(seq 1 30); do
    phase=$(kubectl get pod "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
    sleep 2
  done
  if ! kubectl logs -n "$NS" "$name" 2>/dev/null | grep -q "Sent to"; then
    info "⚠️  send of '$3' to $1 FAILED:"
    kubectl logs -n "$NS" "$name" 2>/dev/null | tail -3 | sed 's/^/       /'
  fi
  kubectl delete pod "$name" -n "$NS" --wait=false >/dev/null 2>&1
}

# ── 1. deploy (also builds the image the cleaner pod needs) ─────────────────
if [ "${SKIP_DEPLOY:-}" != "1" ]; then
  say "Deploying the repro (shared-service-name consumer + split config on the real topics)"
  (cd "$ROOT" && task servicebus:sharedsub:deploy) || { echo "deploy failed"; exit 1; }
  # The deployed consumer auto-provisions its `test-service` subscription on
  # both topics at startup; give it a moment before the baseline listing.
  sleep 10
else
  say "SKIP_DEPLOY=1 - using the already-deployed repro"
fi

# ── 2. pre-clean: leftovers from previous runs would taint every verdict ────
# (after deploy so the cleaner pod uses the freshly built image)
say "Pre-clean: removing split CRs and broker leftovers from previous runs"
kubectl delete mirrordclustersplitsessions --all -A >/dev/null 2>&1 || true
kubectl delete mirrordclusterworkloadpatchrequests --all -A >/dev/null 2>&1 || true
kubectl delete mirrordclusterexternalresources --all >/dev/null 2>&1 || true
# Give the operator a moment to finish any in-flight teardown before we
# repair the broker state underneath it.
deadline=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  count=$(kubectl get mirrordclustersplitsession -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" = "0" ] && break
  sleep 3
done
CLEAN_NAME="sb-cleaner-$RANDOM"
kubectl run "$CLEAN_NAME" --restart=Never \
  --image=servicebus-consumer:local --image-pull-policy=Never \
  --namespace="$NS" \
  --env="CLEAN_MODE=true" \
  --env="SERVICEBUS_CONNECTION_STRING=$AZURE_CONN" \
  --env="SERVICEBUS_TOPICS=$TOPICS" \
  -- /app/consumer >/dev/null 2>&1
for i in $(seq 1 30); do
  phase=$(kubectl get pod "$CLEAN_NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
  sleep 2
done
kubectl logs -n "$NS" "$CLEAN_NAME" 2>/dev/null | sed 's/^/     /'
kubectl delete pod "$CLEAN_NAME" -n "$NS" --wait=false >/dev/null 2>&1

say "Baseline subscriptions (before any mirrord session)"
BASELINE=$(list_subs)
echo "$BASELINE" | sed 's/^/     /'
if echo "$BASELINE" | grep -q "mirrord-"; then
  echo "  ⚠️  mirrord-* leftovers survived the pre-clean - results may be tainted"
fi

# ── 3. start the local session (filters on BOTH topics) ─────────────────────
say "Building the consumer and starting it under mirrord (filters on both topics)"
(cd "$ROOT/apps/servicebus-consumer" && go build -o /tmp/servicebus-consumer main.go) || exit 1
"$MIRRORD_BIN" exec -f "$OVERLAY/mirrord-shared-sub.json" -- /tmp/servicebus-consumer \
  >"$LOCAL_LOG" 2>&1 &
CONSUMER_PID=$!
info "local consumer log: $LOCAL_LOG"

say "Waiting for the split session to become Ready (up to 180s)"
deadline=$(( $(date +%s) + 180 ))
ready=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  if kubectl get mirrordclustersplitsession -A -o json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any("ready" in {k.lower() for k in (i.get("status") or {})} for i in d.get("items",[])) else 1)'; then
    ready=1; break
  fi
  if ! kill -0 "$CONSUMER_PID" 2>/dev/null; then
    echo "mirrord exec exited early - log tail:"; tail -20 "$LOCAL_LOG"; exit 1
  fi
  sleep 3
done
[ -n "$ready" ] || { echo "split session never became Ready - log tail:"; tail -20 "$LOCAL_LOG"; exit 1; }
ok "split session Ready"

say "Waiting for the local consumer to start (it logs its resolved service name)"
deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  grep -q 'ServiceName mode: subscription' "$LOCAL_LOG" && break
  sleep 2
done

REDIRECTED=$(grep -o 'ServiceName mode: subscription "[^"]*"' "$LOCAL_LOG" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -z "$REDIRECTED" ]; then
  echo "local consumer never logged its service name - log tail:"; tail -20 "$LOCAL_LOG"; exit 1
fi
say "The SHARED env var (SERVICEBUS_SERVICE_NAME) was redirected to: $REDIRECTED"
if [[ "$REDIRECTED" != mirrord-s-* ]]; then
  info "expected a mirrord-s-* name; got $REDIRECTED - operator did not rewrite the env var?"
  exit 1
fi
info "the app reads this subscription on test-topic AND test-topic-2."

OWN_NAME=$(grep -o 'TopicSub: test-topic-3/[^ ]*' "$LOCAL_LOG" | head -1 | cut -d/ -f2)
say "The OWN env var (SERVICEBUS_SUBSCRIPTION_1, only test-topic-3) was redirected to: ${OWN_NAME:-<not found>}"
if [[ "$OWN_NAME" == mirrord-s-* ]] && [ "$OWN_NAME" != "$REDIRECTED" ]; then
  ok "different env var -> its OWN independent session name (the name follows the env var, not the topic)"
elif [ "$OWN_NAME" = "$REDIRECTED" ]; then
  bug "test-topic-3 got the SHARED name despite having its own env var - grouping is broken"
else
  bug "test-topic-3's subscription env var was not redirected to a mirrord-s-* name"
fi

# ── 4. ownership: who created the subscription the app reads, per topic ─────
# Healthy (fixed operator): the SAME mirrord-s-* name on every topic, each
# operator-created with a mirrord_route routing rule; the app creates nothing.
# Buggy operator: a different name per topic, so the app auto-creates the
# redirected name on the losing topics - visible as CREATED lines and a
# match-all rule.
sleep 5
say "Auto-provision activity in the local consumer (the client's framework does this on startup)"
grep 'Auto-provision' "$LOCAL_LOG" | sed 's/^/     /' || info "(none logged yet)"

ORPHAN_TOPICS=$(grep -o 'Auto-provision: CREATED [^ ]*' "$LOCAL_LOG" | awk '{print $3}' | cut -d/ -f1 | sort -u)
say "Subscriptions while the session is live"
LIVE_LIST=$(list_subs)
echo "$LIVE_LIST" | sed 's/^/     /'

REDIRECTED_TOPICS=$(echo "$LIVE_LIST" | grep -c "  $REDIRECTED " || true)
UNFILTERED=$(echo "$LIVE_LIST" | grep "mirrord-s-" | grep -c "match-all" || true)
if [ -n "$ORPHAN_TOPICS" ]; then
  for t in $ORPHAN_TOPICS; do
    bug "the app CREATED a subscription on '$t' itself - unfiltered (default rule), no operator CR owns it"
  done
elif [ "${UNFILTERED:-0}" -gt 0 ]; then
  bug "$UNFILTERED mirrord-s-* subscription(s) carry a match-all rule - unfiltered orphan(s) not owned by the operator"
elif [ "${REDIRECTED_TOPICS:-0}" -eq 2 ]; then
  ok "shared group: $REDIRECTED exists on test-topic AND test-topic-2, operator-created with routing rules"
else
  bug "$REDIRECTED exists on $REDIRECTED_TOPICS topic(s), expected exactly 2 (the shared group)"
fi
if [ -n "$OWN_NAME" ] && echo "$LIVE_LIST" | grep -q "  $OWN_NAME "; then
  ok "own group: $OWN_NAME exists on test-topic-3 only, with its own routing rule"
fi

# ── 5. routing proof: all three topics, matched and unmatched ───────────────
say "Routing proof: sending a NON-matching message (tenant=other) to each topic"
send_msg test-topic   other "nomatch-t1-$$"
send_msg test-topic-2 other "nomatch-t2-$$"
send_msg test-topic-3 other "nomatch-t3-$$"
sleep 20
for m in "nomatch-t1-$$" "nomatch-t2-$$" "nomatch-t3-$$"; do
  hits=$(grep -c "order=$m" "$LOCAL_LOG" || true)
  if [ "${hits:-0}" -gt 0 ]; then
    bug "local session received '$m' ${hits}x - a message that does NOT match its filter (came through the unfiltered orphan)"
  else
    ok "'$m' did not reach the local session (correctly filtered on this topic)"
  fi
done

say "And matching messages (tenant=test-user)"
send_msg test-topic   test-user "match-t1-$$"
send_msg test-topic-2 test-user "match-t2-$$"
send_msg test-topic-3 test-user "match-t3-$$"
sleep 20
for m in "match-t1-$$" "match-t2-$$" "match-t3-$$"; do
  hits=$(grep -c "order=$m" "$LOCAL_LOG" || true)
  case "${hits:-0}" in
    0) bug "local session NEVER received '$m' - matched messages lost on this topic" ;;
    1) ok "local session received '$m' exactly once" ;;
    *) bug "local session received '$m' ${hits}x - duplicated (raw + forwarder copies through the unfiltered orphan)" ;;
  esac
done

# ── 6. teardown: the orphan outlives the session ─────────────────────────────
say "Ending the session and waiting for the split to tear down (linger is ~60s)"
cleanup
CONSUMER_PID=""
deadline=$(( $(date +%s) + 240 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  count=$(kubectl get mirrordclustersplitsession -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" = "0" ] && break
  sleep 5
done
ok "split session gone"

FINAL_LIST=$(list_subs)
echo "$FINAL_LIST" | sed 's/^/     /'
if echo "$FINAL_LIST" | grep -q "mirrord-s-"; then
  bug "mirrord-s-* subscription(s) survived the session teardown - leaked (the operator only deletes what its CRs own)"
  info "clean them up with: az servicebus topic subscription delete --topic-name <topic> --name <sub> ..."
else
  ok "no mirrord-s-* subscriptions left behind"
fi

say "Summary - the name follows the ENV VAR, not the topic"
info "shared group  (test-topic, test-topic-2 <- SERVICEBUS_SERVICE_NAME): one name  -> $REDIRECTED"
info "own group     (test-topic-3            <- SERVICEBUS_SUBSCRIPTION_1): own name -> ${OWN_NAME:-<none>}"
info "each (topic, name) pair is a separate Azure subscription with its own rule and its own cleanup CR"

say "Done - full local session log: $LOCAL_LOG"
