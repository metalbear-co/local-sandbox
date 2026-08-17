#!/usr/bin/env bash
# Idle-watch-stream reaper: the local stand-in for a cloud LB / NAT that
# silently forgets quiet connections. Cloud managed-Kubernetes (GKE master LB,
# EKS NLB with its 350s idle timeout) drops state for idle flows and then
# blackholes their packets - no FIN, no RST. Long-lived-but-quiet apiserver
# watch streams die that way while busy request connections stay alive, which
# is the operator behaviour the Torq report describes (healthy operator, stale
# watch cache, ghost sessions).
#
# minikube/kind/k3d have no such middlebox, so we inject the exact mechanism on
# the node:
#   1. enable conntrack accounting so every flow carries packet counters
#   2. each round, snapshot the operator's ESTABLISHED apiserver flows, wait
#      SAMPLE seconds, snapshot again
#   3. any flow whose packet delta <= IDLE_THRESHOLD is "idle" - blackhole it
#      with a raw-table DROP on its exact 4-tuple (operator's egress packets
#      vanish; the socket stays open, believing all is well, until the
#      operator's own timeout fires)
#
#   scripts/linkerd-repro-idle-reap.sh start   # run the reaper loop (foreground)
#   scripts/linkerd-repro-idle-reap.sh stop    # remove every blackhole + acct
#   scripts/linkerd-repro-idle-reap.sh status  # show active blackholes
#
# Tunables (env): SAMPLE=20  IDLE_THRESHOLD=6  MAX_KILL_PER_ROUND=1  CLUSTER_NAME=bearkube
# MAX_KILL_PER_ROUND=1 blackholes one idle stream per round, so degradation
# accumulates over minutes the way the customer's success rate did, rather than
# killing every watch at once.

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-bearkube}"
SAMPLE="${SAMPLE:-20}"
IDLE_THRESHOLD="${IDLE_THRESHOLD:-6}"
MAX_KILL_PER_ROUND="${MAX_KILL_PER_ROUND:-1}"
API_HOST="192.168.49.2"
API_PORT="8443"
TAG="linkerd-repro-idle"

# </dev/null is load-bearing: without it `minikube ssh` swallows the caller's
# stdin, which corrupts any `while read` loop that calls this.
ssh_node() { minikube -p "$CLUSTER_NAME" ssh -- "$1" </dev/null 2>/dev/null; }

operator_ip() {
  kubectl get pods -n mirrord -l app=mirrord-operator \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].status.podIP}' 2>/dev/null
}

# sport<TAB>packets for the operator's apiserver flows, one line per flow.
# Reads only the original direction (client ephemeral sport + its packet count),
# so the reply direction's sport=API_PORT never becomes a bogus bucket.
snapshot() {
  local op="$1"
  ssh_node "sudo conntrack -L -p tcp" \
    | grep "src=$op " | grep "dport=$API_PORT" | grep ESTABLISHED \
    | sed -nE 's/.*sport=([0-9]+) dport='"$API_PORT"' packets=([0-9]+).*/\1\t\2/p'
}

cmd_start() {
  local op; op=$(operator_ip)
  [[ -z "$op" ]] && { echo "no operator pod found"; exit 1; }
  echo "idle-reaper: operator $op -> apiserver $API_HOST:$API_PORT"
  echo "  SAMPLE=${SAMPLE}s  IDLE_THRESHOLD=${IDLE_THRESHOLD} pkts  MAX_KILL_PER_ROUND=${MAX_KILL_PER_ROUND}"
  echo ""

  # Accounting on, and recreate existing flows so they carry counters.
  ssh_node "sudo sysctl -w net.netfilter.nf_conntrack_acct=1 >/dev/null"
  ssh_node "sudo conntrack -D -p tcp --orig-src $op --orig-dst $API_HOST >/dev/null 2>&1" || true
  echo "conntrack accounting on; operator apiserver flows recreated with counters."
  echo "Ctrl-C to stop the loop (run '$0 stop' to remove blackholes)."
  echo ""

  local KILLED=" "      # space-delimited " sport " list (bash 3.2 has no assoc arrays)
  local round=0
  while true; do
    round=$((round+1))
    op=$(operator_ip)   # re-derive: a restart changes the pod IP
    [[ -z "$op" ]] && { echo "[round $round] operator pod gone, waiting"; sleep "$SAMPLE"; continue; }

    local before after
    before=$(snapshot "$op")
    sleep "$SAMPLE"
    after=$(snapshot "$op")

    # Build "sport delta" for streams present in BOTH snapshots (long-lived).
    # A small delta means the stream was quiet over the sample = idle watch.
    local idle_sports=() live=0 idle_count=0
    while IFS=$'\t' read -r sport pkt_after; do
      [[ -z "$sport" ]] && continue
      live=$((live+1))
      [[ "$KILLED" == *" $sport "* ]] && continue
      local pkt_before
      pkt_before=$(printf '%s\n' "$before" | awk -F'\t' -v s="$sport" '$1==s {print $2; exit}')
      [[ -z "$pkt_before" ]] && continue          # not long-lived, skip
      if (( pkt_after - pkt_before <= IDLE_THRESHOLD )); then
        idle_count=$((idle_count+1))
        idle_sports+=("$sport:$((pkt_after - pkt_before))")
      fi
    done <<< "$after"

    # Blackhole up to MAX_KILL_PER_ROUND distinct idle streams this round.
    local killed=0 entry sport delta
    for entry in ${idle_sports[@]+"${idle_sports[@]}"}; do
      (( killed >= MAX_KILL_PER_ROUND )) && break
      sport=${entry%%:*}; delta=${entry##*:}
      ssh_node "sudo iptables -t raw -I PREROUTING 1 -s $op -d $API_HOST -p tcp --sport $sport --dport $API_PORT -m comment --comment $TAG -j DROP"
      KILLED="$KILLED$sport "
      echo "[round $round] BLACKHOLE idle stream sport=$sport (delta=${delta} pkts over ${SAMPLE}s)"
      killed=$((killed+1))
    done

    local blackholes
    blackholes=$(ssh_node "sudo iptables -t raw -L PREROUTING -n" | grep -c "$TAG" || true)
    echo "[round $round] live=$live idle=$idle_count blackholed_total=$blackholes"
  done
}

cmd_stop() {
  echo "removing idle-reaper blackholes..."
  while true; do
    local line
    line=$(ssh_node "sudo iptables -t raw -L PREROUTING -n --line-numbers 2>/dev/null" | grep "$TAG" | head -1 | awk '{print $1}')
    [[ -z "$line" ]] && break
    ssh_node "sudo iptables -t raw -D PREROUTING $line"
  done
  local op; op=$(operator_ip)
  [[ -n "$op" ]] && ssh_node "sudo conntrack -D -p tcp --orig-src $op >/dev/null 2>&1" || true
  echo "idle-reaper stopped. Restart the operator to fully heal any hung watches:"
  echo "  task operator:restart"
}

cmd_status() {
  echo "=== idle-reaper blackholes (raw PREROUTING) ==="
  ssh_node "sudo iptables -t raw -L PREROUTING -n --line-numbers 2>/dev/null" | grep "$TAG" || echo "  none"
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  *) echo "usage: $0 {start|stop|status}"; exit 1 ;;
esac
