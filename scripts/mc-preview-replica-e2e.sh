#!/usr/bin/env bash
#
# End-to-end test for PER-CLUSTER PREVIEW REPLICAS in multicluster.
#
# ONE app (preview-probe: HTTP + SQS + PG in a single binary, every action logged
# with its CLUSTER_ID), ONE preview config (steal + split + db branch), replicated
# to every workload cluster. The test then proves, with per-cluster data printed:
#
#   [TOPOLOGY] a replica pod runs on every WORKLOAD cluster (and, with a
#              management-only primary, NOT on the primary); copies carry the
#              replica label; the primary CR is annotated with the cluster list.
#   [HTTP]     baggage requests entering a cluster are served by THAT cluster's
#              own replica; plain requests stay with the deployed app.
#   [DB]       every replica reads/writes the SAME branch: non-default clusters
#              through their local branch proxy, the default directly. A write
#              from one cluster is read back from another, and nothing leaks
#              into the source DB.
#   [SQS]      matched messages are compete-consumed EXACTLY once across the
#              replicas (per-cluster tally printed); unmatched messages reach
#              the deployed apps.
#   [IDLE]     (IDLE=1) every cluster's replica idles INDEPENDENTLY after
#              silence (phase Idle, zero preview pods everywhere, branch
#              proxies scaled to zero WITH the preview), a matched queue
#              message wakes exactly the routing cluster's replica and is
#              consumed exactly once, the wake scales its proxy back up and
#              the replica reaches the shared branch through it, and silence
#              cycles everything back to Idle. Then an HTTP wake: a held
#              baggage request wakes ONLY its target cluster (the others stay
#              Idle) and is served by the woken replica. Replaces the
#              HTTP/DB/SQS traffic sections - those poll continuously, which
#              is exactly what idle mode removes.
#   [BULK]     (BULK=1) a 100k-row result set streamed from the shared branch
#              through the tunnel to every replica CONCURRENTLY arrives
#              byte-complete - the data-plane integrity single-row probes miss.
#   [STALE]    (STALE=1) a sidecar TLS Secret corrupted into the interrupted-
#              teardown shape (garbage material, no owner) is REPLACED when the
#              copy is recreated; reused, every replica DB stream would die.
#   [BLIP]     (BLIP=1) deleting the branch DB pod must not revoke running
#              replicas: the replica-clusters annotation (read by tunnel authz
#              per stream open) holds steady and the DB path recovers.
#   [FAIL]     (TEARDOWN=fail, the default) a copy patched to Failed on ONE
#              cluster fails the preview EVERYWHERE: the primary goes Failed
#              naming that cluster and every remote copy is deleted.
#   [DEAD]     (TEARDOWN=dead-cluster) one workload cluster is PAUSED, then
#              preview stop - the primary CR must still disappear within the
#              operator's cleanup-confirm window instead of wedging in
#              Terminating on the unreachable cluster.
#   [TEARDOWN] preview stop removes every CR, pod, proxy and secret everywhere.
#
# The topology section also pins two wire contracts the failure semantics depend
# on: every copy carries the split-only label AND a tmp-resources annotation
# even without queues (empty "[]") - an operator predating the replica flow
# fails a copy whose annotation is MISSING, and through fail-anywhere that one
# old cluster would kill the preview fleet-wide. The DB section additionally
# asserts no replica env still contains the branch-host placeholder (the URL
# spec lowercases hosts of http-scheme URLs; a case-changed placeholder would
# skip substitution silently).
#
# Topologies: works unchanged against 2 clusters (primary = default = workload)
# and 3 clusters (management-only primary, default = mirrord-remote-1) - the
# contexts and the default cluster are derived from MC_NUM_CLUSTERS.
#
# Usage:
#   SUITE=1 DEPLOY_OPERATOR=1 ./mc-preview-replica-e2e.sh   # EVERY scenario, one scoreboard:
#       1. replicas DISABLED (the shipped default): pods on default only, split-only
#          copies, no interception on members, direct DB, Degraded message, no CLI stall
#       2. replicas ENABLED: topology + HTTP locality + proxied branch + SQS + fail-anywhere
#       3. idle lifecycle (replicas): independent idling, queue wake
#       4. tunnel outage: primary restart leaves replicas untouched, DB path recovers
#       5. dead cluster: preview stop bounded, never wedged
#   ./mc-preview-replica-e2e.sh                     # single run, fail-anywhere teardown
#   REPLICAS=0 ./mc-preview-replica-e2e.sh          # single run in disabled mode
#   HTTP=0 DB=1 SQS=1 ./mc-preview-replica-e2e.sh   # skip sections
#   IDLE=1 ./mc-preview-replica-e2e.sh              # idle scenario (uses SQS wake if deployed)
#   TUNNEL=1 DB=1 ./mc-preview-replica-e2e.sh       # add the tunnel-outage section
#   BULK=1 DB=1 ./mc-preview-replica-e2e.sh         # bulk-data integrity through the tunnel
#   STALE=1 DB=1 ./mc-preview-replica-e2e.sh        # stale sidecar Secret replaced on copy recreation
#   BLIP=1 DB=1 SQS=1 ./mc-preview-replica-e2e.sh   # branch-resolution blip must not revoke replicas
#   TEARDOWN=stop|fail|dead-cluster ...             # teardown scenario
#   DEPLOY_OPERATOR=1 ./mc-preview-replica-e2e.sh   # swap in mirrord-operator:custom first
#   REDEPLOY_SQS=1 ./mc-preview-replica-e2e.sh      # (re)deploy localstack + queue first
#   KEEP=1 ./mc-preview-replica-e2e.sh              # leave the preview running afterwards
#
# Env knobs: NUM (messages/requests per class, default 5), MC_NUM_CLUSTERS (auto),
# PROBE_IMAGE (default preview-probe:mc, auto-built + loaded), OPERATOR_IMAGE,
# CLEANUP_TIMEOUT, MIRRORD_BIN, TEARDOWN (fail | stop | dead-cluster),
# REPLICAS (1 | 0 | empty = leave operators as-is), TUNNEL, SUITE.
#
# Prereqs: operators on all clusters run YOUR build with previewEnv (+ pgBranching
# for [DB]); [SQS] needs the shared localstack (task multicluster:sqs:deploy or
# REDEPLOY_SQS=1). Missing infra skips that section instead of failing.

set -uo pipefail

SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SANDBOX_DIR"

NUM="${NUM:-5}"
if [ -z "${MC_NUM_CLUSTERS:-}" ]; then
  if minikube status -p mirrord-remote-2 >/dev/null 2>&1; then MC_NUM_CLUSTERS=3; else MC_NUM_CLUSTERS=2; fi
fi
HTTP="${HTTP:-1}"; SQS="${SQS:-1}"; DB="${DB:-1}"
PROBE_IMAGE="${PROBE_IMAGE:-preview-probe:mc}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-mirrord-operator:custom}"
DEPLOY_OPERATOR="${DEPLOY_OPERATOR:-0}"
REDEPLOY_SQS="${REDEPLOY_SQS:-0}"
CLEANUP_TIMEOUT="${CLEANUP_TIMEOUT:-120}"
KEEP="${KEEP:-0}"
MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"
# fail: fail one copy first and require the fail-anywhere semantics, then stop (default).
# stop: plain preview stop. dead-cluster: pause a cluster, stop must not wedge on it.
TEARDOWN="${TEARDOWN:-fail}"
case "$TEARDOWN" in fail|stop|dead-cluster) ;; *) echo "TEARDOWN must be fail|stop|dead-cluster, got '$TEARDOWN'" >&2; exit 1 ;; esac
# IDLE=1 runs the idle scenario: the preview keeps its split/branch FEATURES (per SQS/DB),
# but the traffic sections are skipped - they poll continuously, keeping the preview awake.
# 45s stays above the operator's 30s floor while keeping the run short.
IDLE="${IDLE:-0}"
IDLE_AFTER="${IDLE_AFTER:-45}"
# REPLICAS configures the fleet switch on the operators before the run and flips the
# assertions to match: 1 = full replicas (the suite's classic mode), 0 = the shipped
# DEFAULT (pods only on the default cluster, split-only copies for queue previews).
# Empty = leave the operators as they are.
REPLICAS="${REPLICAS:-}"
# TUNNEL=1 (replicas mode, DB=1): after the traffic sections, prove the tunnel-outage
# guarantee - restart the primary (killing every branch-tunnel WebSocket mid-preview) and
# require every replica pod to KEEP RUNNING untouched and the DB path to recover once the
# envoy re-dials.
TUNNEL="${TUNNEL:-0}"
# BULK=1 (replicas mode, DB=1): stream a multi-MB result set from the shared branch through
# the tunnel and require it back byte-complete. Single-row probes cannot catch data-plane
# bugs that only fire under sustained flow (a dropped mux chunk, a stalled credit window).
BULK="${BULK:-0}"
# STALE=1 (replicas mode, DB=1): corrupt a member's sidecar TLS Secret into the shape an
# interrupted teardown leaves behind (garbage material, no owner), recreate the copy, and
# require the operator to REPLACE the Secret - reusing it would reject every DB stream.
STALE="${STALE:-0}"
# BLIP=1 (replicas mode, DB=1, SQS=1): kill the branch DB pod and require the preserve-
# existing guarantee - the replica-clusters annotation (tunnel authorization reads it per
# stream open) must never collapse to just the default cluster during the blip, and the
# DB path must recover once the pod is back.
BLIP="${BLIP:-0}"

PRIMARY_CTX="${MC_PRIMARY:-mirrord-primary}"
REMOTE1_CTX="${MC_REMOTE_1:-mirrord-remote-1}"
REMOTE2_CTX="${MC_REMOTE_2:-mirrord-remote-2}"
NS="test-multicluster"
APP=combo-app
KEY="prev-combo-e2e"
PROBE_DIR="$SANDBOX_DIR/k8s/overlays/multicluster-probe"
export MC_NUM_CLUSTERS

RUN_ID="r$(date +%s)"
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; BLD=$'\033[1m'; RST=$'\033[0m'
say()  { printf '%s\n' "${BLU}==>${RST} ${BLD}$*${RST}"; }
ok()   { OK_COUNT=$((OK_COUNT+1)); printf '%s\n' "  ${GRN}✅${RST} $*"; }
warn() { printf '%s\n' "  ${YEL}⚠️ ${RST} $*"; }
err()  { printf '%s\n' "  ${RED}❌${RST} $*"; }

# One icon per section family so a scrolling log reads at a glance.
section_icon() {
  case "$1" in
    \[TOPOLOGY\]*) printf '🌐' ;;
    \[HTTP\]*)     printf '🔀' ;;
    \[DB\]*)       printf '💾' ;;
    \[SQS\]*)      printf '📬' ;;
    \[IDLE\]*)     printf '😴' ;;
    \[TUNNEL\]*)   printf '🔌' ;;
    \[DEAD\]*)     printf '💀' ;;
    \[FAIL\]*)     printf '💥' ;;
    \[BULK\]*)     printf '📦' ;;
    \[STALE\]*)    printf '🔏' ;;
    \[BLIP\]*)     printf '🩹' ;;
    \[TEARDOWN\]*) printf '🧹' ;;
    log\ excerpts*) printf '📜' ;;
    SUITE*)        printf '🏁' ;;
    *)             printf '▸' ;;
  esac
}

# Every hdr() opens a summary row: check counts are attributed to the most recent
# header, and the run-summary table at the end prints one row per header that
# actually recorded checks. No per-section bookkeeping calls needed in the body.
hdr()  {
  section_close
  CURRENT_SECTION="$*"; SECTION_OK_BASE=$OK_COUNT; SECTION_FAIL_BASE=$FAILURES
  SECTION_KNOWN_BASE=$KNOWN_COUNT
  echo; printf '%s\n' "${BLD}$(section_icon "$*") $*${RST}"
}
section_close() {
  [ -n "${CURRENT_SECTION:-}" ] || return 0
  SECTION_NAMES+=("$CURRENT_SECTION")
  SECTION_OKS+=($((OK_COUNT - SECTION_OK_BASE)))
  SECTION_FAILS+=($((FAILURES - SECTION_FAIL_BASE)))
  SECTION_KNOWNS+=($((KNOWN_COUNT - SECTION_KNOWN_BASE)))
  CURRENT_SECTION=""
}
run_summary_table() {
  section_close
  local rule="  ──────────────────────────────────────────────────────────────────────────────"
  echo
  printf '%s\n' "${BLD}📊 RUN SUMMARY${RST}  ·  ${MC_NUM_CLUSTERS} clusters · replicas=${REPLICAS:-as-is} · teardown=$TEARDOWN"
  printf '%s\n' "$rule"
  local i
  # macOS bash 3.2 aborts on empty-array expansion under set -u; same guard as elsewhere.
  for i in ${SECTION_NAMES[@]+"${!SECTION_NAMES[@]}"}; do
    [ "$(( SECTION_OKS[i] + SECTION_FAILS[i] + SECTION_KNOWNS[i] ))" = 0 ] && continue
    if [ "${SECTION_FAILS[$i]}" != 0 ]; then
      printf '  %s %-58s %2s checks  %s\n' "$(section_icon "${SECTION_NAMES[$i]}")" \
        "${SECTION_NAMES[$i]:0:58}" "$(( SECTION_OKS[i] + SECTION_FAILS[i] + SECTION_KNOWNS[i] ))" \
        "${RED}❌ ${SECTION_FAILS[$i]} FAILED${RST}"
    elif [ "${SECTION_KNOWNS[$i]}" != 0 ]; then
      printf '  %s %-58s %2s checks  %s\n' "$(section_icon "${SECTION_NAMES[$i]}")" \
        "${SECTION_NAMES[$i]:0:58}" "$(( SECTION_OKS[i] + SECTION_KNOWNS[i] ))" \
        "${YEL}🐞 ${SECTION_KNOWNS[$i]} KNOWN BUG${RST}"
    else
      printf '  %s %-58s %2s checks  %s\n' "$(section_icon "${SECTION_NAMES[$i]}")" \
        "${SECTION_NAMES[$i]:0:58}" "${SECTION_OKS[$i]}" "${GRN}✅ PASS${RST}"
    fi
  done
  printf '%s\n' "$rule"
  skipped=""
  [ "$HTTP" != 1 ] && skipped="$skipped http"
  [ "$DB" != 1 ] && skipped="$skipped db"
  [ "$SQS" != 1 ] && skipped="$skipped sqs"
  [ "$IDLE" != 1 ] && skipped="$skipped idle"
  [ "${TUNNEL:-0}" != 1 ] && skipped="$skipped tunnel"
  [ -n "$skipped" ] && printf '  %s\n' "⏭️  not enabled this run:$skipped"
}

FAILURES=0; OK_COUNT=0; KNOWN_COUNT=0
CURRENT_SECTION=""; SECTION_NAMES=(); SECTION_OKS=(); SECTION_FAILS=(); SECTION_KNOWNS=()
fail() { err "$*"; FAILURES=$((FAILURES+1)); }
# A check failing because of an already-tracked bug: reported distinctly (🐞, not ❌) so a
# red run always means something NEW, and counted separately so the scenario can exit 2
# (known-only) instead of 1. Callers must verify the bug's SIGNATURE before downgrading a
# failure to known - a matching symptom with a different cause must stay red.
known() { KNOWN_COUNT=$((KNOWN_COUNT+1)); printf '%s\n' "  ${YEL}🐞${RST} $* ${YEL}[known bug]${RST}"; }

# `mirrord` is often a shell ALIAS pointing at a local build - aliases don't reach scripts.
if ! command -v "$MIRRORD_BIN" >/dev/null 2>&1 && [ ! -x "$MIRRORD_BIN" ]; then
  for candidate in \
    "$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord" \
    "$SANDBOX_DIR/../mirrord/target/debug/mirrord" \
    "$SANDBOX_DIR/../mirrord/target/aarch64-apple-darwin/release/mirrord" \
    "$SANDBOX_DIR/../mirrord/target/release/mirrord"; do
    [ -x "$candidate" ] && MIRRORD_BIN="$candidate" && break
  done
fi
if ! command -v "$MIRRORD_BIN" >/dev/null 2>&1 && [ ! -x "$MIRRORD_BIN" ]; then
  err "mirrord CLI not found - set MIRRORD_BIN=/path/to/mirrord"; exit 1
fi
# Several candidate paths can hold a mirrord binary; print which one won (and its build time)
# so a stale build shadowing a fresh one is visible instead of silently tested.
if [ -f "$MIRRORD_BIN" ]; then
  warn "mirrord CLI: $MIRRORD_BIN (built $(stat -f '%Sm' "$MIRRORD_BIN" 2>/dev/null || stat -c '%y' "$MIRRORD_BIN" 2>/dev/null))"
fi

if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  warn "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
fi

# ---------------------------------------------------------------------------
# SUITE=1: run EVERY scenario back to back by re-invoking this script with the
# right knobs, then print one scoreboard. The image is deployed once (pass
# DEPLOY_OPERATOR=1 to the suite) and the operators are reconfigured between
# scenarios via the REPLICAS knob.
# ---------------------------------------------------------------------------
# Two runs against the same fleet destroy each other: `pre_clean` deletes every
# PreviewSession on every cluster, so a second run scrubs the first run's preview
# mid-scenario. The victim then reports its preview "absent" with its pods and sidecar
# Secret gone - a failure that looks exactly like a product bug and is not one. Only the
# outermost invocation takes the lock; suite children inherit the marker.
LOCK_DIR="${TMPDIR:-/tmp}/mc-preview-replica-e2e.lock"
release_lock() { :; }
if [ -z "${E2E_LOCK_HELD:-}" ]; then
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      printf '%s\n' "  ${RED}❌${RST} another run of this suite is in progress (pid $holder)."
      printf '%s\n' "     Concurrent runs scrub each other's previews - wait for it, or kill it."
      exit 1
    fi
    # The holder is gone: its lock is stale (killed run, crashed shell).
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || { printf '%s\n' "cannot take the run lock at $LOCK_DIR"; exit 1; }
  fi
  echo "$$" > "$LOCK_DIR/pid"
  export E2E_LOCK_HELD=1
  release_lock() { rm -rf "$LOCK_DIR"; }
  # Armed here because a suite run exits inside the dispatch below, before the trap that
  # cleans up port-forwards is installed; that later trap also releases the lock.
  trap release_lock EXIT
fi

if [ "${SUITE:-0}" = 1 ]; then
  declare -a SUITE_NAMES SUITE_RESULTS
  # Short ids so a run can be narrowed without retyping knob soup:
  #   ONLY=tunnel,idle   run just those      SKIP=idle          run all but those
  #   PICK=1             choose interactively (gum, when installed)
  # A full suite is ~30 minutes; most iterations only need one scenario.
  SUITE_IDS=(disabled replicas resilience idle tunnel dead)

  if [ "${PICK:-0}" = 1 ]; then
    if command -v gum >/dev/null 2>&1; then
      chosen=$(printf '%s\n' "${SUITE_IDS[@]}" \
        | gum choose --no-limit --header "Scenarios to run (space to toggle, enter to confirm)" </dev/tty)
      [ -z "$chosen" ] && { echo "Nothing selected."; exit 0; }
      ONLY=$(echo "$chosen" | paste -sd',' -)
    else
      warn "PICK=1 needs gum (brew install gum) - running every scenario"
    fi
  fi

  # Returns 0 when the scenario should run, per ONLY / SKIP.
  wants_scenario() { # id
    case ",${SKIP:-}," in *",$1,"*) return 1 ;; esac
    [ -z "${ONLY:-}" ] && return 0
    case ",${ONLY}," in *",$1,"*) return 0 ;; *) return 1 ;; esac
  }

  run_scenario() { # id name VAR=VALUE...
    local scenario_id="$1"; local scenario_name="$2"; shift 2
    wants_scenario "$scenario_id" || return 0
    say "SCENARIO [$scenario_id]: $scenario_name"
    local status=0
    env SUITE=0 "$@" "$0" || status=$?
    SUITE_NAMES+=("$scenario_name")
    case "$status" in
      0) SUITE_RESULTS+=("PASS") ;;
      # Exit 2 = every failure matched an already-tracked bug's signature.
      2) SUITE_RESULTS+=("KNOWN") ;;
      *) SUITE_RESULTS+=("FAIL") ;;
    esac
  }

  # Scenario 1 carries the one-time image deploy when the suite was asked to deploy;
  # every later scenario reuses it.
  run_scenario disabled "default mode: replicas DISABLED (pods on default only, split-only copies)" \
    "DEPLOY_OPERATOR=$DEPLOY_OPERATOR" REPLICAS=0 HTTP=1 DB=1 SQS=1 TEARDOWN=stop
  run_scenario replicas "full replicas: topology + HTTP locality + shared branch + SQS + fail-anywhere" \
    DEPLOY_OPERATOR=0 REPLICAS=1 HTTP=1 DB=1 SQS=1 TEARDOWN=fail
  run_scenario resilience "resilience: bulk tunnel data + stale sidecar secret + branch blip + fast stop" \
    DEPLOY_OPERATOR=0 REPLICAS=1 HTTP=0 DB=1 SQS=1 BULK=1 STALE=1 BLIP=1 TEARDOWN=stop
  run_scenario idle "idle lifecycle: independent idling, queue + HTTP wake" \
    DEPLOY_OPERATOR=0 REPLICAS=1 IDLE=1 TEARDOWN=stop
  run_scenario tunnel "tunnel outage: primary restart must not touch replicas, DB path recovers" \
    DEPLOY_OPERATOR=0 REPLICAS=1 HTTP=0 DB=1 SQS=1 TUNNEL=1 TEARDOWN=stop
  run_scenario dead "dead cluster: preview stop must not wedge on a paused member" \
    DEPLOY_OPERATOR=0 REPLICAS=1 HTTP=0 DB=0 SQS=0 TEARDOWN=dead-cluster

  hdr "SUITE RESULTS"
  suite_failed=0; suite_known=0
  for i in "${!SUITE_NAMES[@]}"; do
    case "${SUITE_RESULTS[$i]}" in
      PASS) ok "${SUITE_NAMES[$i]}" ;;
      KNOWN)
        printf '%s\n' "  ${YEL}🐞${RST} ${SUITE_NAMES[$i]} ${YEL}[known bug - tracked, not a regression]${RST}"
        suite_known=1
        ;;
      *)
        err "${SUITE_NAMES[$i]}"
        suite_failed=1
        ;;
    esac
  done
  [ "$suite_known" = 1 ] && [ "$suite_failed" = 0 ] && \
    printf '%s\n' "  ${YEL}⚠️  known-bug scenarios fail by design until their tracked fix lands${RST}"
  exit "$suite_failed"
fi

# One kubectl invocation per attempt, retried: concurrent kubectl/minikube activity can make
# a single `config get-contexts` read come back partial mid-rewrite, and each context used to
# be probed with its OWN invocation - so one flaky read silently dropped one context and the
# topology check aborted a healthy setup.
ALL_CTXS=()
for _attempt in 1 2 3; do
  ALL_CTXS=()
  ctx_list=$(kubectl config get-contexts -o name 2>/dev/null)
  for c in "$PRIMARY_CTX" "$REMOTE1_CTX" "$REMOTE2_CTX"; do
    [ "$c" = "$REMOTE2_CTX" ] && [ "$MC_NUM_CLUSTERS" != "3" ] && continue
    echo "$ctx_list" | grep -qx "$c" && ALL_CTXS+=("$c")
  done
  [ "${#ALL_CTXS[@]}" = "$MC_NUM_CLUSTERS" ] && break
  sleep 2
done

# Check the topology BEFORE deriving anything from ALL_CTXS: a "passing" 1-cluster run proves
# nothing about replicas, and on bash 3.2 (the macOS default) expanding an EMPTY array under
# `set -u` aborts with "unbound variable" before any friendly error could print.
if [ "${#ALL_CTXS[@]}" != "$MC_NUM_CLUSTERS" ]; then
  err "expected $MC_NUM_CLUSTERS cluster contexts, found ${#ALL_CTXS[@]} (${ALL_CTXS[*]:-none})."
  err "this is a MULTICLUSTER test - bring the clusters up first: 'task multicluster:up'"
  err "(MC_NUM_CLUSTERS=3 for the management-only topology). If they are up, this was a"
  err "kubeconfig hiccup - rerun."
  exit 1
fi

WORKLOAD_CTXS=()
if [ "$MC_NUM_CLUSTERS" = "3" ]; then
  # management-only topology: the primary runs no workloads; remote-1 is the default cluster.
  for c in "${ALL_CTXS[@]}"; do [ "$c" = "$PRIMARY_CTX" ] || WORKLOAD_CTXS+=("$c"); done
  DEFAULT_CTX="$REMOTE1_CTX"
else
  WORKLOAD_CTXS=("${ALL_CTXS[@]}")
  DEFAULT_CTX="$PRIMARY_CTX"
fi
NON_DEFAULT_CTXS=()
for c in "${WORKLOAD_CTXS[@]}"; do [ "$c" = "$DEFAULT_CTX" ] || NON_DEFAULT_CTXS+=("$c"); done

PF_PIDS=(); BG_PIDS=()

trap 'for p in "${PF_PIDS[@]:-}" "${BG_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done; release_lock' EXIT

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
deploy_operator() {
  # Same-tag `minikube image load` does NOT replace an image the node already has, and even
  # a UNIQUE tag can arrive pointing at a stale image (minikube's daemon-export cache), so a
  # run can quietly test a STALE build. Export the image to a tarball ourselves and load the
  # FILE - deterministic, no cache in the path - then verify the running pod's imageID.
  local tag="mirrord-operator:e2e-$RUN_ID"
  local tar="/tmp/mirrord-operator-e2e-$RUN_ID.tar"
  say "Deploying custom operator image ($OPERATOR_IMAGE as $tag) to all clusters"
  docker tag "$OPERATOR_IMAGE" "$tag" || { err "cannot tag $OPERATOR_IMAGE - build it first"; exit 1; }
  docker save "$tag" -o "$tar" || { err "docker save failed"; exit 1; }
  pgrep -f 'target/debug/operator-service' >/dev/null 2>&1 && { warn "stopping operator:dev"; pkill -f 'target/debug/operator-service' || true; sleep 3; }
  for c in "${ALL_CTXS[@]}"; do
    say "loading image into $c"
    minikube -p "$c" image load "$tar"
    kubectl --context "$c" -n mirrord set image deploy/mirrord-operator "mirrord-operator=$tag"
    # The operator ALSO spawns pods from its own image (the branch proxy) via its
    # OPERATOR_IMAGE env - point that at the fresh tag too, or those pods run whatever
    # stale image the node has cached under the old name.
    kubectl --context "$c" -n mirrord set env deploy/mirrord-operator "OPERATOR_IMAGE=$tag"
    # Retired branch-proxy knobs: the tunnel needs no default-apiserver endpoint or CA.
    # Unset both so overrides from runs of the old design cannot linger on the Deployment.
    kubectl --context "$c" -n mirrord set env deploy/mirrord-operator \
      "OPERATOR_MC_DEFAULT_API_SERVER-" "OPERATOR_MC_DEFAULT_API_SERVER_CA-" >/dev/null
    # Full replicas are a fleet-wide opt-in (chart: multiCluster.preview.replicas); the
    # REPLICAS knob decides per run, defaulting to enabled for this suite's classic mode.
    # A pure deploy (DEPLOY_ONLY, e.g. via `task op:custom`) with no explicit REPLICAS
    # leaves the fleet's flag untouched - swapping the image must not flip features.
    if [ "$REPLICAS" = 0 ]; then
      kubectl --context "$c" -n mirrord set env deploy/mirrord-operator \
        "OPERATOR_MC_PREVIEW_MODE=default-cluster" >/dev/null
    elif [ -n "$REPLICAS" ] || [ "${DEPLOY_ONLY:-0}" != 1 ]; then
      kubectl --context "$c" -n mirrord set env deploy/mirrord-operator \
        "OPERATOR_MC_PREVIEW_MODE=replicas"
    fi
    # The tunnel's `branchtunnels` envoy-remote rule and the v1alpha1 APIService ship with
    # the LOCAL chart - the released chart the cluster was installed from predates them,
    # and without them the envoy's tunnel dial into this cluster is Forbidden (RBAC) or 404
    # (no aggregation route), so branching replicas never get a DB path. Render with THIS
    # cluster's own install values: a hand-picked --set list renders a narrower role set,
    # and the forced server-side apply then REPLACES the installed roles with it, silently
    # dropping rules the running operator depends on.
    if ! helm --kube-context "$c" get values mirrord-operator -n mirrord -o yaml \
      > "/tmp/mc-operator-values-$c.yaml" 2>/dev/null || [ ! -s "/tmp/mc-operator-values-$c.yaml" ]; then
      err "$c: cannot read the installed helm values (cluster down?) - RBAC not re-rendered"
      exit 1
    fi
    # The dummy license only satisfies the chart's render-time assertion (it lives in
    # deployment.yaml, which helm evaluates even when only the roles template is selected);
    # nothing from it is applied - only multi-cluster-roles.yaml is.
    helm template mirrord-operator "$SANDBOX_DIR/../operator/public/charts/mirrord-operator" \
      -n mirrord -f "/tmp/mc-operator-values-$c.yaml" \
      --set license.key=render-only-placeholder \
      -s templates/multi-cluster-roles.yaml -s templates/api-service.yaml \
      | kubectl --context "$c" apply --server-side --force-conflicts -f - >/dev/null \
      && ok "$c: multi-cluster RBAC re-rendered from the local chart + this cluster's values" \
      || err "$c: failed to apply the local chart's multi-cluster RBAC"
    kubectl --context "$c" -n mirrord patch deploy mirrord-operator --type=strategic \
      -p '{"spec":{"template":{"spec":{"containers":[{"name":"mirrord-operator","imagePullPolicy":"Never"}]}}}}'
    kubectl --context "$c" -n mirrord delete lease mirrord-operator-leader >/dev/null 2>&1 || true
    kubectl --context "$c" -n mirrord delete pod -l app.kubernetes.io/name=mirrord-operator --force --grace-period=0 >/dev/null 2>&1 || true
  done
  for c in "${ALL_CTXS[@]}"; do
    kubectl --context "$c" -n mirrord rollout status deploy/mirrord-operator --timeout=150s >/dev/null 2>&1 \
      && ok "$c operator ready" || err "$c operator not ready"
    # Prove the pod runs the image we just loaded. Compare against the NODE's ID for the
    # fresh tag - the host's ID is NOT comparable (containerd image store vs the node's
    # classic docker store compute different IDs for the same image).
    local want got
    want=$(minikube -p "$c" ssh "docker image inspect $tag --format '{{.Id}}'" 2>/dev/null | tr -d '\r[:space:]')
    got=$(kubectl --context "$c" -n mirrord get pods -l app.kubernetes.io/name=mirrord-operator -o jsonpath='{.items[*].status.containerStatuses[0].imageID}' 2>/dev/null)
    case "$got" in
      *"${want#sha256:}"*) ok "$c runs the freshly loaded image" ;;
      *) err "$c operator pod is NOT on the loaded image (node tag: ${want:-<missing>} pod: $got)"; exit 1 ;;
    esac
  done
  rm -f "$tar"
}

ensure_probe_image() {
  if ! docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1; then
    say "Building $PROBE_IMAGE from apps/preview-probe"
    docker build --platform linux/arm64 -t "$PROBE_IMAGE" "$SANDBOX_DIR/apps/preview-probe" >/dev/null || { err "probe image build failed"; exit 1; }
  fi
  for c in "${WORKLOAD_CTXS[@]}"; do
    if ! minikube -p "$c" image ls 2>/dev/null | grep -q "${PROBE_IMAGE##*/}"; then
      say "Loading $PROBE_IMAGE into $c"
      minikube -p "$c" image load "$PROBE_IMAGE"
    fi
  done
  ok "probe image present on all workload clusters"
}

# Converges the fleet onto the requested replicas mode (REPLICAS knob) without a full image
# redeploy: sets/unsets the opt-in env on every operator and waits for the rollouts. Only the
# primary's fan-out reads it, but a consistent fleet keeps surprises out of debugging.
ensure_replicas_mode() {
  [ -z "$REPLICAS" ] && return
  local want_env
  [ "$REPLICAS" = 1 ] && want_env="OPERATOR_MC_PREVIEW_MODE=replicas" \
    || want_env="OPERATOR_MC_PREVIEW_MODE=default-cluster"
  say "Configuring the fleet: preview replicas $([ "$REPLICAS" = 1 ] && echo ENABLED || echo DISABLED)"
  local changed=0
  for c in "${ALL_CTXS[@]}"; do
    current=$(kubectl --context "$c" -n mirrord get deploy mirrord-operator \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPERATOR_MC_PREVIEW_MODE")].value}' 2>/dev/null)
    if { [ "$REPLICAS" = 1 ] && [ "$current" != "replicas" ]; } \
      || { [ "$REPLICAS" = 0 ] && [ "$current" != "default-cluster" ]; }; then
      kubectl --context "$c" -n mirrord set env deploy/mirrord-operator "$want_env" >/dev/null
      changed=1
    fi
  done
  if [ "$changed" = 1 ]; then
    for c in "${ALL_CTXS[@]}"; do
      kubectl --context "$c" -n mirrord rollout status deploy/mirrord-operator --timeout=150s >/dev/null 2>&1 \
        && ok "$c operator reconfigured" || err "$c operator did not roll out"
    done
  else
    ok "fleet already in the requested mode"
  fi
}

# Everything a previous run (including an INTERRUPTED one) may have left behind. The
# workload-patch CRs matter as much as the sessions: a stale accepted request in a
# MirrordClusterWorkloadPatch rejects the next run's patch with a 409 Conflict, failing
# `preview start` before anything else happens.
PRE_CLEAN_KINDS="previewsessions.preview.mirrord.metalbear.co,mirrordclustersplitsessions.queues.mirrord.metalbear.co,mirrordclusterworkloadpatchrequests.mirrord.metalbear.co,mirrordclusterworkloadpatches.mirrord.metalbear.co"

pre_clean() {
  say "Pre-clean: removing leftover preview state"
  for c in "${ALL_CTXS[@]}"; do
    while read -r item; do
      [ -z "$item" ] && continue
      kubectl --context "$c" -n "$NS" patch "$item" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || \
      kubectl --context "$c" patch "$item" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      kubectl --context "$c" -n "$NS" delete "$item" --ignore-not-found >/dev/null 2>&1 || \
      kubectl --context "$c" delete "$item" --ignore-not-found >/dev/null 2>&1 || true
    done < <(kubectl --context "$c" get "$PRE_CLEAN_KINDS" -A -o name 2>/dev/null)
  done
  # Deletes above are async (controllers run their finalizers) - a new preview starting
  # while yesterday's teardown is still in flight hits the same 409 the scrub exists to
  # prevent, so wait until the state is REALLY gone.
  local deadline=$((SECONDS + 60))
  for c in "${ALL_CTXS[@]}"; do
    while [ "$SECONDS" -lt "$deadline" ]; do
      leftover=$(kubectl --context "$c" get "$PRE_CLEAN_KINDS" -A -o name 2>/dev/null | head -1)
      [ -z "$leftover" ] && break
      sleep 2
    done
    if [ -n "${leftover:-}" ]; then
      err "$c still holds leftover preview state after 60s: $leftover"
      exit 1
    fi
  done
  ok "clusters scrubbed"
}

# Previews-API convergence probe, one aggregated call - the same view `mirrord preview
# start` itself waits on. Prints "ready" when the top-level phase AND every workload
# cluster's phase are within the accepted set, "failed <msg>" on Failed, "absent" when the
# key is not listed, "waiting ..." (naming the lagging clusters) otherwise. Prints nothing
# when the API is not served (older operator build) - callers fall back to the primary CR.
previews_state() { # accepted-phases (space separated, e.g. "Ready" or "Idle")
  kubectl --context "$PRIMARY_CTX" get --raw "/apis/operator.metalbear.co/v1alpha1/previews" 2>/dev/null \
    | KEYX="$KEY" OKP="$1" python3 -c '
import json, os, sys
key = os.environ["KEYX"]; accepted = os.environ["OKP"].split()
try:
    items = [it for it in json.load(sys.stdin).get("items", [])
             if (it.get("spec") or {}).get("key") == key]
except Exception:
    sys.exit()
if not items:
    print("absent"); sys.exit()
status = items[0].get("status") or {}
phase = status.get("phase"); clusters = status.get("clusters") or {}
# The view itself carries the expected cluster set (stamped by the fan-out): with replicas
# disabled only the default cluster appears, and demanding every configured workload
# cluster here would wait forever on clusters that were never meant to serve.
lagging = [c for c, p in clusters.items() if p not in accepted]
if phase == "Failed":
    print("failed %s" % ((status.get("message") or {}).get("text") or "<no message>"))
elif phase in accepted and not lagging:
    print("ready")
else:
    print("waiting phase=%s lagging=%s" % (phase, ",".join(sorted(lagging)) or "-"))' 2>/dev/null
}

# Per-cluster phase map from the previews API, one "cluster=phase" line per cluster.
previews_clusters() {
  kubectl --context "$PRIMARY_CTX" get --raw "/apis/operator.metalbear.co/v1alpha1/previews" 2>/dev/null \
    | KEYX="$KEY" python3 -c '
import json, os, sys
key = os.environ["KEYX"]
try:
    items = [it for it in json.load(sys.stdin).get("items", [])
             if (it.get("spec") or {}).get("key") == key]
except Exception:
    sys.exit()
for cluster, phase in (((items[0].get("status") or {}).get("clusters")) or {}).items() if items else []:
    print("%s=%s" % (cluster, phase))' 2>/dev/null
}

wait_preview_ready() { # bg_pid
  # With IDLE=1 a cluster may legitimately reach Idle before the last one boots (no
  # traffic flows during creation), so both phases count as converged there.
  local accepted="Ready"
  [ "$IDLE" = 1 ] && accepted="Ready Idle"
  local deadline=$(( $(date +%s) + 300 )) state=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state=$(previews_state "$accepted")
    if [ -n "$state" ]; then
      case "$state" in
        ready)
          ok "previews API: phase converged ($accepted) on the primary and every workload cluster"
          return 0 ;;
        failed*)
          err "preview Failed: ${state#failed }"
          return 1 ;;
      esac
    else
      state=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
      [ "$state" = "Ready" ] && return 0
      [ "$state" = "Failed" ] && {
        err "preview Failed: $(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A -o jsonpath='{.items[0].status.failureMessage}' 2>/dev/null)"
        return 1
      }
    fi
    case "$state" in
      absent|"")
        if [ -n "${1:-}" ] && ! kill -0 "$1" 2>/dev/null; then
          err "mirrord preview start exited without creating the session:"
          tail -15 /tmp/mc-replica-start.log 2>/dev/null | sed 's/^/    /'
          return 1
        fi ;;
    esac
    sleep 4
  done
  err "preview never reached Ready on every cluster (last: ${state:-none})"; return 1
}

replica_logs() { # ctx
  kubectl --context "$1" -n "$NS" logs -l "preview.metalbear.co/session-uid,app=$APP" --tail=4000 2>/dev/null
}
deployed_logs() { # ctx
  kubectl --context "$1" -n "$NS" logs -l "app=$APP,!preview.metalbear.co/session-uid" --tail=4000 2>/dev/null
}

wait_for_queuesplits_ready() { # want-rows
  say "Waiting for the queuesplits API: $1 Ready split(s) for $APP, target pods patched"
  local deadline=$(( $(date +%s) + 180 )) out="" total="" ready="" bad=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    out=$(kubectl --context "$PRIMARY_CTX" get queuesplits -A -o json 2>/dev/null | TGT="$APP" QNS="$NS" python3 -c '
import json, os, sys
tgt = os.environ["TGT"]; ns = os.environ["QNS"]
try:
    items = [it for it in json.load(sys.stdin).get("items", [])
             if (it.get("metadata") or {}).get("namespace") == ns
             and ((it.get("spec") or {}).get("target") or {}).get("name") == tgt]
except Exception:
    print("0 0 1"); sys.exit()
total = len(items)
ready = sum(1 for it in items if ((it.get("status") or {}).get("phase")) == "Ready")
bad = sum(1 for it in items for p in ((it.get("status") or {}).get("targetPods") or [])
          if not (p.get("patched") and p.get("ready")))
print(total, ready, bad)' 2>/dev/null)
    read -r total ready bad <<< "${out:-0 0 1}"
    if [ "${total:-0}" -ge "$1" ] && [ "$ready" = "$total" ] && [ "${bad:-1}" = 0 ]; then
      ok "queuesplits API: $total/$total Ready, all target pods patched"
      return 0
    fi
    sleep 3
  done
  err "queue splits never fully Ready (last: total=$total ready=$ready unpatched=$bad)"
  return 1
}

# With `fast` as $1, additionally asserts the stop completed inside STOP_FAST_BOUND - on a
# healthy fleet the operator confirms copy deletion on a short recheck, so a slow stop means
# the confirmation wait regressed onto an error backoff (a 30s+ stall on EVERY stop, which
# "stop eventually succeeded" alone can never catch).
STOP_FAST_BOUND=25
stop_preview() {
  local t0=$(date +%s)
  MIRRORD_KUBE_CONTEXT="$PRIMARY_CTX" MIRRORD_CHECK_VERSION=false \
    "$MIRRORD_BIN" preview stop -k "$KEY" >/dev/null 2>&1 || true
  local deadline=$(( t0 + CLEANUP_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local left=0
    for c in "${ALL_CTXS[@]}"; do
      left=$(( left + $(kubectl --context "$c" get previewsessions.preview.mirrord.metalbear.co -A --no-headers 2>/dev/null | grep -c -- "$KEY" || true) ))
    done
    if [ "$left" = 0 ]; then
      local elapsed=$(( $(date +%s) - t0 ))
      ok "preview '$KEY' cleaned up on all clusters (${elapsed}s)"
      if [ "${1:-}" = "fast" ]; then
        [ "$elapsed" -le "$STOP_FAST_BOUND" ] \
          && ok "healthy stop stayed under ${STOP_FAST_BOUND}s - no error-backoff stall in the confirm wait" \
          || { err "healthy stop took ${elapsed}s (> ${STOP_FAST_BOUND}s) - copy-deletion confirm is pacing on an error backoff"; return 1; }
      fi
      return 0
    fi
    sleep 2
  done
  err "preview '$KEY' left resources behind"; return 1
}

# Port-forward to a deploy/pod and wait for /health; echoes nothing, sets $PF_PORT.
# Re-establishes the forward between attempts: kubectl pins the pod it attached to, so a
# forward opened while a rollout replaces pods (e.g. right after the queue-split patch)
# points at a terminating pod forever and polling it can never succeed.
pf_up() { # ctx target port
  local attempt pid
  for attempt in 1 2 3; do
    # A forward leaked by an earlier section or suite scenario (its pod is long gone)
    # squats the local port: kubectl then cannot bind, and the health polls below hit the
    # corpse listener - every attempt fails against a perfectly healthy pod.
    lsof -ti "tcp:$3" 2>/dev/null | while read -r squatter; do kill "$squatter" 2>/dev/null || true; done
    kubectl --context "$1" -n "$NS" port-forward "$2" "$3:80" >/dev/null 2>&1 &
    pid=$!
    PF_PIDS+=("$pid")
    for _ in $(seq 1 10); do
      curl -sf -m 2 "http://127.0.0.1:$3/health" >/dev/null 2>&1 && return 0
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  done
  return 1
}

# Forward to the CURRENT newest pod matching a label selector, re-resolving between
# attempts and setting $PF_POD. The HTTP-steal and queue-split patches ROLL the preview
# deployment, so a pod name fetched moments earlier may be terminating by the time the
# forward binds - a forward pinned to it never serves, and retrying against the same name
# (what a plain pf_up does) cannot recover.
pf_up_current() { # ctx label-selector port
  local attempt
  for attempt in 1 2 3 4; do
    PF_POD=$(kubectl --context "$1" -n "$NS" get pods -l "$2" --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
    [ -n "$PF_POD" ] && pf_up "$1" "pod/$PF_POD" "$3" && return 0
    sleep 4
  done
  return 1
}

# ---------------------------------------------------------------------------
# infra: sqs env (optional), pg-source (optional), the probe app everywhere
# ---------------------------------------------------------------------------
# Every operator must run YOUR build or the run silently tests the released image: the
# released operator handles queue previews the old way (split-only copies, no
# replica-clusters annotation, no /previews route), so the behavioral checks pass while
# every new-feature check fails with confusing '<absent>' / '<no response>'. This is not
# hypothetical - `task multicluster:sqs:deploy` helm-upgrades the released chart to inject
# the AWS env and clobbers a kubectl-set custom image in the process.
verify_operator_build() {
  [ "${ALLOW_ANY_OPERATOR:-0}" = 1 ] && return 0
  local bad=0
  for c in "${ALL_CTXS[@]}"; do
    img=$(kubectl --context "$c" -n mirrord get deploy mirrord-operator \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    case "$img" in
      mirrord-operator:e2e-*) ;;
      *) err "$c operator runs '$img' - NOT your custom build (something helm-upgraded it?)"; bad=1 ;;
    esac
  done
  if [ "$bad" = 1 ]; then
    err "rerun with DEPLOY_OPERATOR=1 to swap your build back in (or ALLOW_ANY_OPERATOR=1 to test whatever runs)"
    exit 1
  fi
  ok "all operators run your custom build"
}

say "Topology: contexts=${ALL_CTXS[*]}  workloads=${WORKLOAD_CTXS[*]}  default=$DEFAULT_CTX  primary=$PRIMARY_CTX  (NUM=$NUM)"
[ "$MC_NUM_CLUSTERS" = "3" ] && ok "management-only mode: $PRIMARY_CTX runs no workloads"
# The sqs taskfile helm-upgrades the operators (see verify_operator_build), so it must run
# BEFORE the custom image goes in - never after.
[ "$REDEPLOY_SQS" = 1 ] && task multicluster:sqs:deploy
[ "$DEPLOY_OPERATOR" = 1 ] && deploy_operator
if [ "${DEPLOY_ONLY:-0}" = 1 ]; then
  say "DEPLOY_ONLY=1 - operators deployed and verified, skipping the tests"
  exit 0
fi
verify_operator_build
ensure_probe_image
ensure_replicas_mode
pre_clean
AWS_EP=""
if [ "$SQS" = 1 ]; then
  AWS_EP=$(kubectl --context "$DEFAULT_CTX" -n "$NS" get deploy sqs-consumer -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_ENDPOINT_URL")].value}' 2>/dev/null)
  if [ -z "$AWS_EP" ]; then
    warn "SQS env not deployed (task multicluster:sqs:deploy or REDEPLOY_SQS=1) - skipping [SQS]"
    SQS=0
  else
    # The standalone sqs-consumer reads the same queue and would steal matched messages
    # before the split - park it, restore on the way out.
    for c in "${WORKLOAD_CTXS[@]}"; do kubectl --context "$c" -n "$NS" scale deploy/sqs-consumer --replicas=0 >/dev/null 2>&1 || true; done
  fi
fi
restore_sqs_consumer() { for c in "${WORKLOAD_CTXS[@]}"; do kubectl --context "$c" -n "$NS" scale deploy/sqs-consumer --replicas=1 >/dev/null 2>&1 || true; done; }

# DB infra
if [ "$DB" = 1 ] && ! kubectl --context "$DEFAULT_CTX" get crd branchdatabases.dbs.mirrord.metalbear.co >/dev/null 2>&1; then
  warn "BranchDatabase CRD missing on $DEFAULT_CTX (pgBranching not enabled?) - skipping [DB]"
  DB=0
fi
if [ "$DB" = 1 ]; then
  say "Deploying pg-source (source DB) on the default cluster"
  kubectl --context "$DEFAULT_CTX" create namespace "$NS" >/dev/null 2>&1 || true
  kubectl --context "$DEFAULT_CTX" -n "$NS" apply -f "$PROBE_DIR/pg-source.yaml" >/dev/null
  kubectl --context "$DEFAULT_CTX" -n "$NS" rollout status deploy/pg-source --timeout=120s >/dev/null 2>&1 || { err "pg-source not ready"; exit 1; }
  seeded=0
  for _ in $(seq 1 15); do
    if kubectl --context "$DEFAULT_CTX" -n "$NS" exec deploy/pg-source -- \
      psql -U postgres -d source_db -c "SELECT 1" >/dev/null 2>&1; then seeded=1; break; fi
    sleep 3
  done
  [ "$seeded" = 1 ] && ok "source DB up" || { err "source DB never came up"; exit 1; }
fi

say "Deploying the $APP probe workload on every workload cluster"
for c in "${WORKLOAD_CTXS[@]}"; do
  kubectl --context "$c" create namespace "$NS" >/dev/null 2>&1 || true
  sed -e "s|__IMG__|$PROBE_IMAGE|g" -e "s|__CLUSTER__|$c|g" -e "s|__AWS_EP__|${AWS_EP:-http://unset}|g" \
    "$PROBE_DIR/combo-app.yaml" | kubectl --context "$c" -n "$NS" apply -f - >/dev/null
  kubectl --context "$c" -n "$NS" rollout status deploy/$APP --timeout=120s >/dev/null 2>&1 \
    && ok "$c $APP ready" || { err "$c $APP not ready"; exit 1; }
done
# The split config must live on the PRIMARY - the broadcast sync controller replicates it
# from there to every member cluster. Applying it to the default cluster only (as this
# script once did) works in the 2-cluster topology by accident (primary == default) and
# breaks management-only mode: remote members never see the config, their replicas fail
# split resolution, and fail-anywhere kills the whole preview. In management-only mode the
# primary has no test namespace, so the CR goes into the operator namespace carrying the
# target-namespace annotation - same recipe as the SQS taskfile's queue registry.
if [ "$SQS" = 1 ]; then
  if [ "$MC_NUM_CLUSTERS" = "3" ]; then
    sed -e "s|namespace: $NS|namespace: mirrord|" \
      -e "/namespace: mirrord/a\\
  annotations:\\
    mirrord.metalbear.co/target-namespace: $NS" \
      "$PROBE_DIR/split-config.yaml" | kubectl --context "$PRIMARY_CTX" apply -f - >/dev/null
  else
    kubectl --context "$PRIMARY_CTX" -n "$NS" apply -f "$PROBE_DIR/split-config.yaml" >/dev/null
  fi

  # Gate on the broadcast sync delivering the config to EVERY workload cluster before the
  # preview starts. A replica whose split initializes before its cluster received the config
  # fails with "no MirrordSplitConfig found" and fail-anywhere kills the whole preview - a
  # race the 2-cluster topology hits reliably right after the fleet-mode bounce, because the
  # default cluster's tmp-resources gate (which implicitly covered member sync in 3-cluster
  # mode, where the default is itself a member) passes as fast as the primary's own split.
  for c in "${WORKLOAD_CTXS[@]}"; do
    synced=0; deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if kubectl --context "$c" -n "$NS" get mirrordsplitconfig combo-split-config >/dev/null 2>&1; then
        synced=1; break
      fi
      sleep 2
    done
    [ "$synced" = 1 ] || { err "split config never synced to $c - replicas would fail their splits"; exit 1; }
  done
fi

# ---------------------------------------------------------------------------
# the ONE preview: steal (+ split) (+ branch), assembled from the enabled sections
# ---------------------------------------------------------------------------
MATCH="combo-$RUN_ID"
SQS_ON="$SQS" DB_ON="$DB" IDLE_ON="$IDLE" IDLE_AFTER="$IDLE_AFTER" \
  MATCH_PREFIX="$MATCH" NSX="$NS" APPX="$APP" python3 - > /tmp/mirrord-combo.json <<'PYEOF'
import json, os
feature = {
    "preview": {"ttl_mins": 30, "creation_timeout_secs": 300},
    "network": {"incoming": {"mode": "steal"}},
}
if os.environ["IDLE_ON"] == "1":
    feature["preview"]["idle"] = {"sleep_after_secs": int(os.environ["IDLE_AFTER"])}
if os.environ["SQS_ON"] == "1":
    feature["split_queues"] = {"test-queue": {
        "queue_type": "SQS",
        "message_filter": {"type": f"^{os.environ['MATCH_PREFIX']}-"},
    }}
if os.environ["DB_ON"] == "1":
    feature["db_branches"] = [{
        "id": "combo-db", "type": "pg", "version": "16", "name": "source_db",
        "ttl_secs": 3600, "creation_timeout_secs": 180,
        "connection": {"url": {"type": "env", "variable": "DATABASE_URL"}},
        "copy": {"mode": "all"},
    }]
print(json.dumps({
    "target": {"path": f"deployment/{os.environ['APPX']}", "namespace": os.environ["NSX"]},
    "operator": True,
    "feature": feature,
}, indent=2))
PYEOF

say "Starting preview '$KEY' (steal$([ "$SQS" = 1 ] && printf ' + split type=^%s-' "$MATCH")$([ "$DB" = 1 ] && printf ' + pg branch'))"
( MIRRORD_KUBE_CONTEXT="$PRIMARY_CTX" MIRRORD_CHECK_VERSION=false \
    "$MIRRORD_BIN" preview start -f /tmp/mirrord-combo.json -i "$PROBE_IMAGE" -k "$KEY" --timeout 300 \
    >/tmp/mc-replica-start.log 2>&1 ) &
BG_PIDS+=($!)
wait_preview_ready $! || { FAILURES=$((FAILURES+1)); stop_preview; exit 1; }
ok "preview Ready on the primary"

# ---------------------------------------------------------------------------
# [TOPOLOGY]
# ---------------------------------------------------------------------------
if [ "$REPLICAS" = 0 ]; then
  hdr "[TOPOLOGY] replicas DISABLED - pods on the default cluster ONLY"
  for c in ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"}; do
    n=$(kubectl --context "$c" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "${n:-0}" = 0 ] && ok "$c: NO preview pods (as configured)" \
      || fail "$c: $n preview pod(s) despite replicas being disabled"

    if [ "$SQS" = 1 ]; then
      lab=$(kubectl --context "$c" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.labels.operator\.metalbear\.co/preview-replica}' 2>/dev/null)
      so=$(kubectl --context "$c" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.labels.operator\.metalbear\.co/preview-split-only}' 2>/dev/null)
      if [ "$so" = "true" ] && [ "$lab" != "true" ]; then
        ok "$c: copy is SPLIT-ONLY (queue split applied, no replica label)"
      else
        fail "$c: copy labels wrong for disabled mode (split-only=$so replica=$lab)"
      fi
    else
      copies=$(kubectl --context "$c" -n "$NS" get previewsessions.preview.mirrord.metalbear.co --no-headers 2>/dev/null | wc -l | tr -d ' ')
      [ "${copies:-0}" = 0 ] && ok "$c: no copy at all (nothing to split)" \
        || fail "$c: unexpected copy without queues in disabled mode"
    fi
  done

  # Poll: the previews wait converges on the DEFAULT cluster's phase, which can land a
  # reconcile or two before the annotation stamp - a single-shot read here races the
  # controller and flakes with '<absent>'.
  ann=""; deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ann=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A \
      -o jsonpath='{.items[0].metadata.annotations.operator\.metalbear\.co/preview-replica-clusters}' 2>/dev/null)
    [ "$ann" = "[\"$DEFAULT_CTX\"]" ] && break
    sleep 5
  done
  [ "$ann" = "[\"$DEFAULT_CTX\"]" ] && ok "replica-clusters annotation lists ONLY the default cluster" \
    || fail "replica-clusters annotation should be [\"$DEFAULT_CTX\"], got: ${ann:-<absent>}"

  # Split-only copies never enter the replica-clusters stamp (it means "where pods RUN"),
  # so cleanup finds them through the separate copy-clusters stamp - without it, a cluster
  # dropped from the registry keeps its orphaned split stealing queue messages until the
  # TTL. Wire contract, so an exact match.
  if [ "$SQS" = 1 ]; then
    expected_copy_ann=$(printf '%s\n' ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"} | sort | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split(), separators=(",",":")))')
    copy_ann=""; deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      copy_ann=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A \
        -o jsonpath='{.items[0].metadata.annotations.operator\.metalbear\.co/preview-copy-clusters}' 2>/dev/null)
      [ "$copy_ann" = "$expected_copy_ann" ] && break
      sleep 5
    done
    [ "$copy_ann" = "$expected_copy_ann" ] && ok "copy-clusters annotation records the split-only fan-out (cleanup can reach it)" \
      || fail "copy-clusters annotation should be $expected_copy_ann, got: ${copy_ann:-<absent>}"
  fi

  # The view must not stall anyone: only the default cluster in the map (no phantom
  # 'Missing'), and the degradation spelled out as a Degraded message. Same poll as
  # above - the map and the message both derive from controller-stamped annotations.
  verdict=""; deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    verdict=$(kubectl --context "$PRIMARY_CTX" get --raw "/apis/operator.metalbear.co/v1alpha1/previews" 2>/dev/null \
      | KEYX="$KEY" DEFX="$DEFAULT_CTX" python3 -c '
import json, os, sys
items = [it for it in json.load(sys.stdin).get("items", [])
         if (it.get("spec") or {}).get("key") == os.environ["KEYX"]]
if len(items) != 1:
    print("entries=%d" % len(items)); sys.exit()
status = items[0].get("status") or {}
clusters = status.get("clusters") or {}
message = status.get("message") or {}
problems = []
if set(clusters) - {os.environ["DEFX"]}:
    problems.append("phantom clusters: %s" % sorted(set(clusters) - {os.environ["DEFX"]}))
if message.get("kind") != "Degraded":
    problems.append("message kind: %r" % message.get("kind"))
print("; ".join(problems) if problems else "ok: %s" % (message.get("text") or "")[:80])' 2>/dev/null)
    case "$verdict" in ok:*) break ;; esac
    sleep 5
  done
  case "$verdict" in
    ok:*) ok "previews API: default-only cluster map + Degraded message"; echo "    ${verdict#ok: }" ;;
    *) fail "previews API wrong in disabled mode: ${verdict:-<no response>}" ;;
  esac
else

hdr "[TOPOLOGY] replicas on every workload cluster"
# In the idle scenario pods may legitimately already be scaled to zero by the time this
# runs; the [IDLE] section asserts the pod lifecycle instead.
if [ "$IDLE" != 1 ]; then
  for c in "${WORKLOAD_CTXS[@]}"; do
    n=0; deadline=$(( $(date +%s) + 180 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      n=$(kubectl --context "$c" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" --no-headers 2>/dev/null | grep -c Running || true)
      [ "$n" -ge 1 ] && break
      sleep 3
    done
    [ "$n" -ge 1 ] && ok "$c: replica pod Running" || fail "$c: NO replica pod"
  done
fi
if [ "$MC_NUM_CLUSTERS" = "3" ]; then
  np=$(kubectl --context "$PRIMARY_CTX" -n "$NS" get pods -l "preview.metalbear.co/session-uid" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${np:-0}" = 0 ] && ok "management-only primary runs NO preview pods" || fail "primary unexpectedly runs $np preview pod(s)"
fi
for c in ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"}; do
  lab=$(kubectl --context "$c" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.labels.operator\.metalbear\.co/preview-replica}' 2>/dev/null)
  [ "$lab" = "true" ] && ok "$c: copy carries the replica label" || fail "$c: copy missing the replica label"

  # The split-only label is the OLD operators' dispatch key; a replica copy without it would
  # be treated as a user-created preview by a pre-replica operator (own pods, seat counted).
  so=$(kubectl --context "$c" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.labels.operator\.metalbear\.co/preview-split-only}' 2>/dev/null)
  [ "$so" = "true" ] && ok "$c: copy carries the split-only label (old-operator compat)" || fail "$c: copy missing the split-only label"

  # The tmp-resources annotation must be PRESENT on every copy: old operators fail a
  # split-only copy without it, and through fail-anywhere that one cluster kills the
  # preview everywhere. With queues it carries the shared temp resources; without queues
  # it must be exactly the empty list.
  tmp=$(kubectl --context "$c" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.annotations.operator\.metalbear\.co/preview-split-tmp-resources}' 2>/dev/null)
  if [ -z "$tmp" ]; then
    fail "$c: copy has NO tmp-resources annotation - a pre-replica operator would fail it, killing the preview fleet-wide"
  elif [ "$SQS" = 1 ]; then
    [ "$tmp" != "[]" ] && ok "$c: tmp-resources annotation carries the shared queue resources" \
      || fail "$c: tmp-resources annotation is EMPTY despite queue splitting"
  else
    [ "$tmp" = "[]" ] && ok "$c: no-queue copy carries the EMPTY tmp-resources annotation" \
      || fail "$c: no-queue copy carries unexpected tmp resources: $tmp"
  fi
done
# Poll: the annotation stamp can trail the phase the previews wait converged on.
ann=""; deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  ann=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A \
    -o jsonpath='{.items[0].metadata.annotations.operator\.metalbear\.co/preview-replica-clusters}' 2>/dev/null)
  [ -n "$ann" ] && break
  sleep 5
done
if [ -n "$ann" ]; then
  ok "primary CR annotated with replica clusters: $ann"
  for c in "${WORKLOAD_CTXS[@]}"; do
    echo "$ann" | grep -q "$c" || fail "annotation is missing workload cluster $c"
  done
else
  warn "primary CR has no replica-clusters annotation (older operator build?)"
fi

# The copy-clusters stamp (cleanup's map of every fanned-out copy) must cover the replica
# fan-out too - it is what lets cleanup reach copies on clusters that later drop out of
# the registry.
copy_ann=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A \
  -o jsonpath='{.items[0].metadata.annotations.operator\.metalbear\.co/preview-copy-clusters}' 2>/dev/null)
if [ -n "$copy_ann" ]; then
  miss=0
  for c in ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"}; do
    echo "$copy_ann" | grep -q "$c" || { fail "copy-clusters annotation is missing $c"; miss=1; }
  done
  [ "$miss" = 0 ] && ok "copy-clusters annotation records every fanned-out copy: $copy_ann"
else
  fail "primary CR has no copy-clusters annotation - cleanup cannot survive a registry drop"
fi

# The previews API on the primary: ONE entry per logical preview, per-cluster phases joined
# live from the copies (copies themselves must never be listed). Queried cluster-scope: in the
# management-only topology the primary CRs live in the OPERATOR namespace, not $NS.
api=$(kubectl --context "$PRIMARY_CTX" get --raw "/apis/operator.metalbear.co/v1alpha1/previews" 2>/dev/null)
if [ -n "$api" ]; then
  entry=$(echo "$api" | KEYX="$KEY" python3 -c '
import json, os, sys
items = [item for item in json.load(sys.stdin).get("items", [])
         if (item.get("spec") or {}).get("key") == os.environ["KEYX"]]
if len(items) == 1:
    status = items[0].get("status") or {}
    print("phase=%s clusters=%s" % (status.get("phase"), json.dumps(status.get("clusters"))))
else:
    print("ENTRIES=%d" % len(items))' 2>/dev/null)
  case "$entry" in
    phase=*)
      ok "previews API lists exactly 1 logical preview for key $KEY (copies folded in)"
      echo "    $entry"
      for c in "${WORKLOAD_CTXS[@]}"; do
        echo "$entry" | grep -q "\"$c\"" || fail "previews API entry is missing cluster $c"
      done
      ;;
    ENTRIES=*)
      fail "previews API listed ${entry#ENTRIES=} entries for key $KEY (want 1 - copies leaking into the view?)"
      ;;
    *)
      fail "previews API response was not parseable: $api"
      ;;
  esac
else
  warn "previews API not served (older operator build?)"
fi

fi  # end replicas-mode topology (the disabled branch is above)

# ---------------------------------------------------------------------------
# [HTTP] per-cluster steal locality (replicas) / no interception on members (disabled)
# ---------------------------------------------------------------------------
if [ "$HTTP" = 1 ] && [ "$IDLE" != 1 ] && [ "$REPLICAS" = 0 ]; then
  hdr "[HTTP] replicas disabled - baggage on a MEMBER cluster is NOT intercepted"
  member="${NON_DEFAULT_CTXS[0]:-}"
  if [ -n "$member" ]; then
    # The queue-split patch just rolled the deployed app; settle before attaching.
    kubectl --context "$member" -n "$NS" rollout status "deploy/$APP" --timeout=90s >/dev/null 2>&1 || true
    if pf_up "$member" "deploy/$APP" 17390; then
      marker="noreplica-$RUN_ID"
      for n in $(seq 1 3); do
        curl -sf -m 10 -H "baggage: mirrord-session=$KEY" "http://127.0.0.1:17390/log/$marker-$n" >/dev/null 2>&1
      done
      sleep 3
      served=$(deployed_logs "$member" | grep -c "$marker" || true)
      stolen=$(replica_logs "$member" | grep -c "$marker" || true)
      [ "$served" -ge 1 ] && ok "$member: baggage → 🏠 ORIGINAL app (replicas disabled here - the documented trade-off)" \
        || fail "$member: baggage requests vanished (deployed app never saw them)"
      [ "$stolen" = 0 ] && ok "$member: 🎯 nothing intercepted (no preview replica on this cluster)" \
        || fail "$member: traffic intercepted despite replicas being disabled"
    else
      fail "$member: port-forward never came up"
    fi
  fi
fi
if [ "$HTTP" = 1 ] && [ "$IDLE" != 1 ] && [ "$REPLICAS" != 0 ]; then
  hdr "[HTTP] baggage -> the LOCAL replica; plain -> the deployed app"
  i=0
  for c in "${WORKLOAD_CTXS[@]}"; do
    port=$((17300 + i)); i=$((i + 1))
    pf_up "$c" "deploy/$APP" "$port" || { fail "$c: port-forward never came up"; continue; }

    # Warm-up gated on the marker reaching the LOCAL replica logs (both apps echo the body,
    # so only the logs prove WHO served it).
    warm=0
    for n in $(seq 1 30); do
      curl -sf -m 5 -H "baggage: mirrord-session=$KEY" "http://127.0.0.1:$port/log/warm-$RUN_ID-$c-$n" >/dev/null 2>&1
      sleep 2
      replica_logs "$c" | grep -q "warm-$RUN_ID-$c-$n" && { warm=1; break; }
    done
    [ "$warm" = 1 ] || { fail "$c: steal never became active"; continue; }

    for n in $(seq 1 "$NUM"); do
      curl -sf -m 10 -H "baggage: mirrord-session=$KEY" "http://127.0.0.1:$port/log/steal-$RUN_ID-$c-$n" >/dev/null 2>&1
      curl -sf -m 10 "http://127.0.0.1:$port/log/plain-$RUN_ID-$c-$n" >/dev/null 2>&1
    done
  done
  sleep 5

  printf '  %s\n' "🚦 HTTP routing · who served what ($NUM baggage + $NUM plain requests per cluster):"
  for c in "${WORKLOAD_CTXS[@]}"; do
    own=$(replica_logs "$c" | grep -c "steal-$RUN_ID-$c-" || true)
    foreign=$(replica_logs "$c" | grep -oE "steal-$RUN_ID-[a-z0-9-]+-[0-9]+" | grep -cv "steal-$RUN_ID-$c-" || true)
    leaks=$(replica_logs "$c" | grep -c "plain-$RUN_ID-" || true)
    dp=$(deployed_logs "$c" | grep -c "plain-$RUN_ID-$c-" || true)
    printf '     🖥  %s\n' "$c"
    printf '        🎯 PREVIEW replica ⟵ baggage requests  %s/%s   (foreign-cluster: %s, un-baggaged leaks: %s)\n' "$own" "$NUM" "$foreign" "$leaks"
    printf '        🏠 ORIGINAL app    ⟵ plain requests    %s/%s\n' "$dp" "$NUM"
    [ "$own" = "$NUM" ]   || fail "$c: replica missed its own baggage traffic ($own/$NUM)"
    [ "$foreign" = 0 ]     || fail "$c: replica served ANOTHER cluster's traffic - locality broken"
    [ "$leaks" = 0 ]       || fail "$c: replica stole un-baggaged traffic"
    [ "$dp" = "$NUM" ]     || fail "$c: deployed app served $dp/$NUM plain requests"
  done
fi

# ---------------------------------------------------------------------------
# [DB] every replica -> the SAME branch (default direct, others via the proxy)
# ---------------------------------------------------------------------------
if [ "$DB" = 1 ] && [ "$IDLE" != 1 ] && [ "$REPLICAS" = 0 ]; then
  hdr "[DB] replicas disabled - the branch is DIRECT (no tunnel artifacts anywhere)"
  for c in ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"}; do
    sidecars=$(kubectl --context "$c" -n "$NS" get secret -o name 2>/dev/null | grep -c -- "-db-sidecar-tls" || true)
    [ "${sidecars:-0}" = 0 ] && ok "$c: no sidecar TLS Secrets" \
      || fail "$c: $sidecars sidecar TLS Secret(s) despite replicas being disabled"
  done

  durl=$(kubectl --context "$DEFAULT_CTX" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" \
    -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="DATABASE_URL")].value}' 2>/dev/null)
  case "$durl" in
    *127.0.0.1*) fail "default cluster's preview pod uses a loopback (tunnel) URL in disabled mode: $durl" ;;
    "") fail "default cluster's preview pod has no DATABASE_URL" ;;
    *) ok "default preview pod connects DIRECTLY ($(echo "$durl" | sed -E 's|postgres://[^@]+@||'))" ;;
  esac

  if pf_up_current "$DEFAULT_CTX" "preview.metalbear.co/session-uid,app=$APP" 17400; then
    db_ok=0
    for _ in $(seq 1 40); do
      curl -sf -m 5 "http://127.0.0.1:17400/db/select" >/dev/null 2>&1 && { db_ok=1; break; }
      sleep 3
    done
    if [ "$db_ok" = 1 ]; then
      ok "default preview pod reads the branch"
      curl -sf -m 10 "http://127.0.0.1:17400/db/insert/write-$RUN_ID-default" >/dev/null 2>&1 \
        && ok "default preview pod writes the branch" || fail "insert via the branch failed"
    else
      fail "default preview pod never connected to the branch"
    fi
  else
    fail "no default preview pod to exercise the branch with"
  fi

  insrc=$(kubectl --context "$DEFAULT_CTX" -n "$NS" exec deploy/pg-source -- \
    psql -U postgres -d source_db -t -A -c "SELECT count(*) FROM probe WHERE val LIKE 'write-$RUN_ID-%';" 2>/dev/null | tr -d '[:space:]')
  case "$insrc" in
    0|"") ok "branch isolation holds: nothing leaked into the source DB" ;;
    *) fail "branch isolation BROKEN: $insrc write(s) leaked into the source DB" ;;
  esac
fi

if [ "$DB" = 1 ] && [ "$IDLE" != 1 ] && [ "$REPLICAS" != 0 ]; then
  hdr "[DB] all replicas share ONE branch; non-default clusters go through the tunnel sidecar"

  # Sidecar chain present on every non-default cluster; and the security claim of the
  # design: NO Secret in the customer namespace holds a cluster credential - the only
  # tunnel artifact is a per-preview mTLS leaf valid solely against the LOCAL operator.
  for c in ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"}; do
    pname=$(kubectl --context "$c" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    kubectl --context "$c" -n "$NS" get secret "${pname}-db-sidecar-tls" >/dev/null 2>&1 \
      && ok "$c: sidecar TLS Secret present" || fail "$c: sidecar TLS Secret missing"
    kubectl --context "$c" -n "$NS" get secret -o name 2>/dev/null | grep -q "branch-proxy-access" \
      && fail "$c: a branch-proxy access Secret (cluster credential) exists in the preview namespace" \
      || ok "$c: no cluster credential in the preview namespace"
    rpod=$(kubectl --context "$c" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$rpod" ]; then
      screstart=$(kubectl --context "$c" -n "$NS" get pod "$rpod" \
        -o jsonpath='{.spec.initContainers[?(@.name=="mirrord-db-sidecar")].restartPolicy}' 2>/dev/null)
      [ "$screstart" = "Always" ] && ok "$c: native DB sidecar injected (init container, restartPolicy Always)" \
        || fail "$c: DB sidecar init container missing or not native (restartPolicy: ${screstart:-<none>})"
      scready=$(kubectl --context "$c" -n "$NS" get pod "$rpod" \
        -o jsonpath='{.status.initContainerStatuses[?(@.name=="mirrord-db-sidecar")].ready}' 2>/dev/null)
      [ "$scready" = "true" ] && ok "$c: DB sidecar is Ready (gateway validation passed)" \
        || fail "$c: DB sidecar not ready (ready: ${scready:-<none>}) - gateway dial or cert validation failed"
    else
      fail "$c: no replica pod to inspect the sidecar on"
    fi
    url=$(kubectl --context "$c" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" \
      -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="DATABASE_URL")].value}' 2>/dev/null)
    case "$url" in
      *127.0.0.1:*) ok "$c: replica DATABASE_URL -> sidecar loopback ($(echo "$url" | sed -E 's|postgres://[^@]+@||'))" ;;
      *) fail "$c: replica DATABASE_URL does not use the sidecar loopback: ${url:-<unset>}" ;;
    esac

    # No env value may still contain the branch-host placeholder in ANY casing: URL parsing
    # lowercases the host of http-scheme URLs (DynamoDB/Spanner), and a case-changed
    # placeholder silently skips substitution - the app then dials a host that never
    # resolves, with nothing failing on the operator side.
    stray=$(kubectl --context "$c" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" \
      -o jsonpath='{.items[0].spec.containers[0].env[*].value}' 2>/dev/null | grep -io "__mirrord_branch_host__" | head -1)
    [ -z "$stray" ] && ok "$c: no branch-host placeholder survived env substitution" \
      || fail "$c: replica env still contains the branch-host placeholder ($stray) - substitution skipped"
  done

  # Deterministic per-cluster DB port: 17400 + the cluster's index (bash 3.2 has no
  # associative arrays).
  db_port_for() {
    local idx=0 c
    for c in "${WORKLOAD_CTXS[@]}"; do
      [ "$c" = "$1" ] && { echo $((17400 + idx)); return; }
      idx=$((idx + 1))
    done
  }

  # Each cluster's replica INSERTs a row tagged with its cluster id.
  for c in "${WORKLOAD_CTXS[@]}"; do
    port=$(db_port_for "$c")
    pf_up_current "$c" "preview.metalbear.co/session-uid,app=$APP" "$port" \
      || { fail "$c: replica port-forward never came up"; continue; }

    # /db/select returns 200 only once the app is CONNECTED (503 before).
    ready=0
    for _ in $(seq 1 60); do curl -sf -m 5 "http://127.0.0.1:$port/db/select" >/dev/null 2>&1 && { ready=1; break; }; sleep 3; done
    [ "$ready" = 1 ] || { fail "$c: replica app never connected to the branch"; continue; }
    ok "$c: connected to the branch via $(curl -s "http://127.0.0.1:$port/db/host")"

    ins=""
    for _ in $(seq 1 5); do ins=$(curl -sf -m 10 "http://127.0.0.1:$port/db/insert/write-$RUN_ID-$c" 2>/dev/null) && break; sleep 2; done
    [ -n "$ins" ] && ok "$c: INSERT write-$RUN_ID-$c -> branch" || fail "$c: insert failed"
  done

  # Cross-cluster read: ONE replica must see EVERY cluster's write - proves one shared branch.
  reader="${NON_DEFAULT_CTXS[0]:-$DEFAULT_CTX}"
  reader_port=$(db_port_for "$reader")
  if [ -n "$reader_port" ]; then
    got=""
    for _ in $(seq 1 10); do
      got=$(curl -sf -m 10 "http://127.0.0.1:$reader_port/db/select" 2>/dev/null)
      miss=0
      for c in "${WORKLOAD_CTXS[@]}"; do echo "$got" | grep -q "write-$RUN_ID-$c" || miss=1; done
      [ "$miss" = 0 ] && break
      sleep 2
    done
    printf '  branch contents as read from %s:\n' "$reader"
    echo "$got" | python3 -m json.tool 2>/dev/null | grep -E "\"val\"|\"cluster\"" | head -$((${#WORKLOAD_CTXS[@]} * 2 + 4)) | sed 's/^/    /'
    for c in "${WORKLOAD_CTXS[@]}"; do
      if echo "$got" | grep -q "\"val\":\"write-$RUN_ID-$c\""; then
        ok "$reader sees $c's write (one shared branch)"
      else
        fail "$reader cannot see $c's write - branch not shared?"
      fi
    done
  fi

  # Isolation: nothing leaked into the SOURCE database.
  insrc=$(kubectl --context "$DEFAULT_CTX" -n "$NS" exec deploy/pg-source -- \
    psql -U postgres -d source_db -t -A -c "SELECT count(*) FROM probe WHERE val LIKE 'write-$RUN_ID-%';" 2>/dev/null | tr -d '[:space:]')
  case "$insrc" in
    0|"") ok "branch isolation holds: no replica write reached the source DB" ;;
    *) fail "branch isolation BROKEN: $insrc replica write(s) leaked into the source DB" ;;
  esac
fi

# ---------------------------------------------------------------------------
# [BULK] a multi-MB result set through the tunnel arrives byte-complete
# ---------------------------------------------------------------------------
if [ "$BULK" = 1 ] && [ "$DB" = 1 ] && [ "$IDLE" != 1 ] && [ "$REPLICAS" != 0 ]; then
  hdr "[BULK] bulk data through the tunnel: every seeded row comes back, none lost"
  BULK_ROWS=100000
  branch_pod=$(kubectl --context "$DEFAULT_CTX" -n "$NS" get pods -l db-owner-name \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$branch_pod" ]; then
    fail "no branch DB pod found on $DEFAULT_CTX (label db-owner-name)"
  else
    kubectl --context "$DEFAULT_CTX" -n "$NS" exec "$branch_pod" -- \
      psql -U postgres -d source_db -q -c \
      "INSERT INTO probe (val, cluster, ts) SELECT 'bulk-$RUN_ID-'||i, 'seed', now() FROM generate_series(1,$BULK_ROWS) i;" \
      >/dev/null 2>&1 && ok "seeded $BULK_ROWS rows into the branch" || fail "bulk seed failed"

    # Read the whole table back from every non-default replica CONCURRENTLY - each pull
    # streams megabytes over its own mux stream, so the streams compete for the shared
    # session window exactly the way real traffic does. A single dropped or reordered
    # chunk breaks the JSON body or the row count.
    declare -a BULK_TMP BULK_CTX BULK_PIDS
    for c in ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"}; do
      port=$(db_port_for "$c")
      tmp=$(mktemp)
      BULK_TMP+=("$tmp"); BULK_CTX+=("$c")
      ( curl -sf -m 120 "http://127.0.0.1:$port/db/select" -o "$tmp" ) &
      BULK_PIDS+=($!)
    done
    wait ${BULK_PIDS[@]+"${BULK_PIDS[@]}"} 2>/dev/null || true
    for i in ${BULK_TMP[@]+"${!BULK_TMP[@]}"}; do
      c="${BULK_CTX[$i]}"; tmp="${BULK_TMP[$i]}"
      got=$(RUNX="$RUN_ID" WANT="$BULK_ROWS" python3 -c '
import json, os, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception as e:
    print("PARSE_FAIL %s" % e); sys.exit()
n = sum(1 for r in rows if r.get("val","").startswith("bulk-%s-" % os.environ["RUNX"]))
print("OK" if n == int(os.environ["WANT"]) else "COUNT %d" % n)' "$tmp" 2>/dev/null)
      size=$(wc -c < "$tmp" | tr -d ' ')
      case "$got" in
        OK) ok "$c: all $BULK_ROWS rows arrived intact through the tunnel (${size} bytes)" ;;
        *) fail "$c: bulk read incomplete or corrupted ($got, ${size:-0} bytes)" ;;
      esac
      rm -f "$tmp"
    done
    # Keep later sections' row expectations unaffected.
    kubectl --context "$DEFAULT_CTX" -n "$NS" exec "$branch_pod" -- \
      psql -U postgres -d source_db -q -c "DELETE FROM probe WHERE val LIKE 'bulk-$RUN_ID-%';" >/dev/null 2>&1 || true
  fi
fi

# ---------------------------------------------------------------------------
# [STALE] a leftover sidecar Secret must be REPLACED when the copy is recreated
# ---------------------------------------------------------------------------
if [ "$STALE" = 1 ] && [ "$DB" = 1 ] && [ "$IDLE" != 1 ] && [ "$REPLICAS" != 0 ] && [ -n "${NON_DEFAULT_CTXS[0]:-}" ]; then
  hdr "[STALE] stale sidecar Secret: copy recreation must replace it, not reuse it"
  victim="${NON_DEFAULT_CTXS[0]}"
  vname=$(kubectl --context "$victim" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  vsecret="${vname}-db-sidecar-tls"
  if [ -z "$vname" ]; then
    fail "$victim: no copy to recreate"
  else
    # The shape an interrupted teardown leaves: same name, garbage material, no owner (so
    # nothing garbage-collects it before the new copy arrives). Reused as-is, the sidecar
    # cannot pass the gateway handshake and every replica DB stream dies.
    kubectl --context "$victim" -n "$NS" patch secret "$vsecret" --type=merge -p \
      '{"metadata":{"ownerReferences":null},"stringData":{"client.crt":"e2e-stale-garbage","client.key":"e2e-stale-garbage","ca.crt":"e2e-stale-garbage"}}' \
      >/dev/null 2>&1 && ok "$victim: Secret $vsecret corrupted into the stale-leftover shape" \
      || fail "$victim: could not corrupt the Secret"
    old_uid=$(kubectl --context "$victim" -n "$NS" get previewsessions.preview.mirrord.metalbear.co "$vname" -o jsonpath='{.metadata.uid}' 2>/dev/null)
    kubectl --context "$victim" -n "$NS" delete previewsessions.preview.mirrord.metalbear.co "$vname" --wait=true >/dev/null 2>&1 \
      && ok "$victim: copy deleted - the fan-out must recreate it against the stale Secret" \
      || fail "$victim: copy deletion failed"

    recreated=0; deadline=$(( $(date +%s) + 120 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      new_uid=$(kubectl --context "$victim" -n "$NS" get previewsessions.preview.mirrord.metalbear.co "$vname" -o jsonpath='{.metadata.uid}' 2>/dev/null)
      [ -n "$new_uid" ] && [ "$new_uid" != "$old_uid" ] && { recreated=1; break; }
      sleep 4
    done
    [ "$recreated" = 1 ] && ok "$victim: copy recreated (new uid)" || fail "$victim: copy never recreated"

    # Compare base64-encoded to stay portable (macOS base64 has no reliable -d flag).
    garbage_b64=$(printf 'e2e-stale-garbage' | base64)
    fresh=0; deadline=$(( $(date +%s) + 180 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      cert=$(kubectl --context "$victim" -n "$NS" get secret "$vsecret" -o jsonpath='{.data.client\.crt}' 2>/dev/null)
      if [ -n "$cert" ] && [ "$cert" != "$garbage_b64" ]; then fresh=1; break; fi
      sleep 4
    done
    [ "$fresh" = 1 ] && ok "$victim: Secret material replaced (or_insert would have kept the garbage)" \
      || fail "$victim: Secret still holds the stale garbage - copy recreation reused it"

    # Exactly one pod AND its sidecar ready: mid-transition the old pod may linger, and
    # its already-started sidecar would read as a false pass.
    scready=0; deadline=$(( $(date +%s) + 180 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      pods=$(kubectl --context "$victim" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" --no-headers 2>/dev/null | wc -l | tr -d ' ')
      ready=$(kubectl --context "$victim" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" \
        -o jsonpath='{.items[0].status.initContainerStatuses[?(@.name=="mirrord-db-sidecar")].ready}' 2>/dev/null)
      [ "$pods" = 1 ] && [ "$ready" = "true" ] && { scready=1; break; }
      sleep 5
    done
    [ "$scready" = 1 ] && ok "$victim: recreated replica's sidecar passed gateway validation with the fresh cert" \
      || fail "$victim: sidecar never became ready after recreation"
  fi
fi

# ---------------------------------------------------------------------------
# [BLIP] branch-resolution blip: running replicas keep their authorization
# ---------------------------------------------------------------------------
if [ "$BLIP" = 1 ] && [ "$DB" = 1 ] && [ "$SQS" = 1 ] && [ "$IDLE" != 1 ] && [ "$REPLICAS" != 0 ]; then
  hdr "[BLIP] branch-resolution blip: replica authorization must survive it"
  # The blip is simulated by stripping the db-owner-name label the resolver selects the
  # branch pod with - resolution fails exactly as with a restarting pod, but the DB itself
  # stays up (the branching controller has no pod watch, so a DELETED branch pod is not
  # recreated - killing it would end the branch, not blip it) and relabeling ends the blip
  # deterministically.
  branch_pod=$(kubectl --context "$DEFAULT_CTX" -n "$NS" get pods -l db-owner-name \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  owner_label=$(kubectl --context "$DEFAULT_CTX" -n "$NS" get pod "$branch_pod" \
    -o jsonpath='{.metadata.labels.db-owner-name}' 2>/dev/null)
  if [ -z "$branch_pod" ] || [ -z "$owner_label" ]; then
    fail "no labeled branch DB pod found on $DEFAULT_CTX"
  else
    kubectl --context "$DEFAULT_CTX" -n "$NS" label pod "$branch_pod" db-owner-name- >/dev/null 2>&1 \
      && ok "branch pod $branch_pod unlabeled (resolution blip begins)" \
      || fail "could not unlabel the branch DB pod"

    # While resolution is down the reconciler takes the preserve-existing arm; the
    # replica-clusters annotation is what tunnel authz checks PER STREAM OPEN, so the one
    # failure mode that matters is it collapsing to just the default cluster. 25s covers
    # at least two reconciles (10s resync).
    collapsed=0; deadline=$(( $(date +%s) + 25 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      ann=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A \
        -o jsonpath='{.items[0].metadata.annotations.operator\.metalbear\.co/preview-replica-clusters}' 2>/dev/null)
      [ "$ann" = "[\"$DEFAULT_CTX\"]" ] && { collapsed=1; break; }
      sleep 1
    done
    [ "$collapsed" = 0 ] && ok "replica-clusters annotation held steady through the blip (authz never revoked)" \
      || fail "annotation collapsed to [\"$DEFAULT_CTX\"] during the blip - running replicas lost tunnel authorization"

    kubectl --context "$DEFAULT_CTX" -n "$NS" label pod "$branch_pod" "db-owner-name=$owner_label" --overwrite >/dev/null 2>&1 \
      && ok "branch pod relabeled (blip over)" || fail "could not restore the branch pod label"

    # Recovery: a NEW DB stream from a replica still works (a fresh request re-dials
    # through sidecar -> tunnel -> the re-resolvable branch pod). Forward on a FRESH port
    # to the CURRENT pod: the DB section's forward points at whatever pod existed then,
    # and [STALE] deliberately replaces the pod right before this section in the suite.
    probe_ctx="${NON_DEFAULT_CTXS[0]:-}"
    if [ -n "$probe_ctx" ]; then
      port=$(( $(db_port_for "$probe_ctx") + 40 ))
      recovered=0
      if pf_up_current "$probe_ctx" "preview.metalbear.co/session-uid,app=$APP" "$port"; then
        for _ in $(seq 1 20); do
          curl -sf -m 5 "http://127.0.0.1:$port/db/select" >/dev/null 2>&1 && { recovered=1; break; }
          sleep 3
        done
      fi
      [ "$recovered" = 1 ] && ok "$probe_ctx: replica DB path live after the blip" \
        || fail "$probe_ctx: replica DB path dead after the blip"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# [SQS] matched -> exactly one replica each; unmatched -> the deployed apps
# ---------------------------------------------------------------------------
if [ "$SQS" = 1 ] && [ "$IDLE" != 1 ]; then
  hdr "[SQS] compete-consume across replicas (numbered messages)"
  wait_for_queuesplits_ready "${#WORKLOAD_CTXS[@]}" || FAILURES=$((FAILURES+1))

  say "Sending $NUM matched (type=$MATCH-M<n>) + $NUM unmatched (type=basic-...)"
  for n in $(seq 1 "$NUM"); do
    task multicluster:sqs:send TYPE="${MATCH}-M${n}" MESSAGE="matched #$n" >/dev/null 2>&1
    task multicluster:sqs:send TYPE="basic-${RUN_ID}-U${n}" MESSAGE="unmatched #$n" >/dev/null 2>&1
    sleep 1
  done

  deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    seen=$(for c in "${WORKLOAD_CTXS[@]}"; do replica_logs "$c" | grep -oE "type=${MATCH}-M[0-9]+"; done | sort -u | wc -l | tr -d ' ')
    [ "$seen" -ge "$NUM" ] && break
    sleep 5
  done

  printf '  %s\n' "📬 matched messages → 🎯 PREVIEW replicas · each consumed EXACTLY once (compete-consume):"
  for c in "${WORKLOAD_CTXS[@]}"; do
    got=$(replica_logs "$c" | grep -oE "type=${MATCH}-M[0-9]+" | sed "s/type=${MATCH}-//" | sort -u | paste -sd',' -)
    cnt=$(replica_logs "$c" | grep -oE "type=${MATCH}-M[0-9]+" | sort -u | wc -l | tr -d ' ')
    printf '     🖥  %-20s 🎯 replica ⟵  %-24s (%s of %s)\n' "$c" "${got:-<none>}" "$cnt" "$NUM"
  done
  total=$(for c in "${WORKLOAD_CTXS[@]}"; do replica_logs "$c" | grep -oE "type=${MATCH}-M[0-9]+"; done | wc -l | tr -d ' ')
  uniq=$(for c in "${WORKLOAD_CTXS[@]}"; do replica_logs "$c" | grep -oE "type=${MATCH}-M[0-9]+"; done | sort -u | wc -l | tr -d ' ')
  if [ "$uniq" = "$NUM" ] && [ "$total" = "$NUM" ]; then
    ok "all $NUM matched messages consumed EXACTLY once across the replicas (no loss, no duplication)"
  else
    fail "matched: $uniq distinct / $total total (want $NUM/$NUM)"
  fi

  # Unmatched delivery can trail by one SQS visibility-timeout replay (the queue is
  # created with VisibilityTimeout=30): a message the forwarder received but returned
  # unacked reappears ~30s later. Wait past that before declaring one missing.
  deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    nomatch=$(for c in "${WORKLOAD_CTXS[@]}"; do deployed_logs "$c" | grep -oE "type=basic-${RUN_ID}-U[0-9]+"; done | sort -u | wc -l | tr -d ' ')
    [ "$nomatch" -ge "$NUM" ] && break
    sleep 5
  done

  printf '  %s\n' "📭 unmatched messages → 🏠 ORIGINAL apps · never stolen by a replica:"
  for c in "${WORKLOAD_CTXS[@]}"; do
    got=$(deployed_logs "$c" | grep -oE "type=basic-${RUN_ID}-U[0-9]+" | sed "s/type=basic-${RUN_ID}-//" | sort -u | paste -sd',' -)
    printf '     🖥  %-20s 🏠 original ⟵  %s\n' "$c" "${got:-<none>}"
  done
  nomatch=$(for c in "${WORKLOAD_CTXS[@]}"; do deployed_logs "$c" | grep -oE "type=basic-${RUN_ID}-U[0-9]+"; done | sort -u | wc -l | tr -d ' ')
  [ "$nomatch" -ge "$NUM" ] && ok "all $NUM unmatched messages reached the DEPLOYED apps" \
    || fail "only $nomatch/$NUM unmatched reached the deployed apps"
fi

# ---------------------------------------------------------------------------
# per-cluster evidence: what each replica actually did, in its own words
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# [TUNNEL] primary restart kills every tunnel WS - replicas untouched, DB recovers
# ---------------------------------------------------------------------------
if [ "$TUNNEL" = 1 ] && [ "$REPLICAS" != 0 ] && [ "$DB" = 1 ]; then
  hdr "[TUNNEL] primary restart mid-preview: replicas survive, the DB path re-dials"
  member="${NON_DEFAULT_CTXS[0]:-}"
  if [ -z "$member" ]; then
    warn "needs a non-default member cluster - skipping"
  else
    pod_sel="preview.metalbear.co/session-uid,app=$APP"
    # A single-shot read can come back empty on a transient apiserver hiccup, and an empty
    # snapshot is indistinguishable from "all pods replaced" - retry so the comparison
    # only ever sees real state.
    pods_snapshot() { # ctx
      local try out
      for try in 1 2 3; do
        out=$(kubectl --context "$1" -n "$NS" get pods -l "$pod_sel" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null | sort)
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
        sleep 3
      done
    }
    pods_before=$(pods_snapshot "$member")

    say "Restarting the primary operator (kills every branch-tunnel WebSocket and the envoy's port-forwards)"
    kubectl --context "$PRIMARY_CTX" -n mirrord delete pod -l app.kubernetes.io/name=mirrord-operator --force --grace-period=0 >/dev/null 2>&1
    kubectl --context "$PRIMARY_CTX" -n mirrord rollout status deploy/mirrord-operator --timeout=150s >/dev/null 2>&1 \
      && ok "primary operator restarted (tunnel pool starts from zero)" || fail "primary operator did not come back"

    # Several reconcile cycles with no tunnel to the member; the guarantee is that the
    # outage stays in the DATA path - the fan-out must not downgrade or respawn anything.
    sleep 45

    # KNOWN BUG (split-recovery re-mint, chip task_517f35c0): when the restarted primary
    # is ALSO the default cluster (2-cluster topology), its queue-split recovery drops the
    # persisted mapping ("Recovered queue mapping not found in current config"), mints new
    # tmp resources, members mismatch, and fail-anywhere tears the preview down. Report
    # those failures as 🐞 so a red here always means a NEW regression - but ONLY when the
    # signature is actually in the restarted operator's log.
    remint_bug() {
      [ "$PRIMARY_CTX" = "$DEFAULT_CTX" ] && [ "$SQS" = 1 ] || return 1
      # grep -c, not -q: under pipefail, -q's early pipe close SIGPIPEs the still-
      # streaming kubectl and fails the pipeline even when the signature matched.
      local hits
      hits=$(kubectl --context "$PRIMARY_CTX" -n mirrord logs deploy/mirrord-operator 2>/dev/null \
        | grep -c "Recovered queue mapping not found in current config") || true
      [ "${hits:-0}" -gt 0 ]
    }
    fail_or_known() {
      if remint_bug; then known "$* - split-recovery re-mint"; else fail "$*"; fi
    }

    pods_after=$(pods_snapshot "$member")
    if [ -n "$pods_before" ] && [ "$pods_before" = "$pods_after" ]; then
      ok "$member: replica pods UNTOUCHED through the outage (identical pod UIDs)"
    elif [ -z "$pods_before" ]; then
      fail "$member: could not snapshot replica pods before the restart"
    else
      fail_or_known "$member: replica pods changed during the tunnel outage (before: $(echo "$pods_before" | tr '\n' ' ')/ after: $(echo "$pods_after" | tr '\n' ' '))"
    fi
    lab=$(kubectl --context "$member" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.labels.operator\.metalbear\.co/preview-replica}' 2>/dev/null)
    [ "$lab" = "true" ] && ok "$member: copy kept its replica label" \
      || fail_or_known "$member: copy lost the replica label (downgraded during outage)"

    # Recovery: once the restarted envoy re-dials its tunnel pool, a member replica's DB
    # connections must work again - drivers reconnect through the sidecar, no pod churn.
    if pf_up_current "$member" "$pod_sel" 17600; then
      db_ok=0; deadline=$(( $(date +%s) + 180 ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        curl -sf -m 5 "http://127.0.0.1:17600/db/select" >/dev/null 2>&1 && { db_ok=1; break; }
        sleep 5
      done
      if [ "$db_ok" = 1 ]; then
        ok "$member: DB path recovered after the restart (tunnel re-dialed)"
        curl -sf -m 10 "http://127.0.0.1:17600/db/insert/write-$RUN_ID-tunnel-recovery" >/dev/null 2>&1 \
          && ok "$member: post-recovery write reached the branch" \
          || fail "$member: post-recovery insert failed"
      else
        fail "$member: DB path never recovered after the primary restart"
      fi
    else
      fail_or_known "$member: no replica pod to verify DB recovery on"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# [IDLE] independent per-cluster idling, queue-message wake, branch survival
# ---------------------------------------------------------------------------
if [ "$IDLE" = 1 ]; then
  hdr "[IDLE] replicas idle independently; a matched message wakes and is consumed"

  # 1. No traffic flows after creation, so every cluster's copy must reach Idle with
  #    zero preview pods - each replica runs its OWN idle gate off its local event bus.
  idle_ok=0; deadline=$(( $(date +%s) + IDLE_AFTER + 240 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(previews_state "Idle")" = "ready" ] && { idle_ok=1; break; }
    sleep 5
  done
  if [ "$idle_ok" = 1 ]; then
    ok "previews API: phase Idle on the primary and on every workload cluster"
  else
    fail "preview never idled everywhere (state: $(previews_state Idle))"
  fi
  for c in "${WORKLOAD_CTXS[@]}"; do
    n=$(kubectl --context "$c" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" --no-headers 2>/dev/null | grep -vc Terminating || true)
    [ "${n:-0}" = 0 ] && ok "$c: zero preview pods while idle" \
      || fail "$c: $n preview pod(s) still up while idle"
  done
  idle_since=$(kubectl --context "$DEFAULT_CTX" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].status.idleSince}' 2>/dev/null)
  [ -n "$idle_since" ] && ok "idleSince set on the default cluster's session ($idle_since)" \
    || fail "idleSince not set while idle"
  if [ "$DB" = 1 ]; then
    # The DB sidecar rides inside the preview pod, so idling the pod idles the whole DB
    # path for free - but the sidecar TLS Secret must survive the idle window (it is
    # garbage-collected only with the copy), or the wake respawn has nothing to mount.
    for c in ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"}; do
      pname=$(kubectl --context "$c" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      kubectl --context "$c" -n "$NS" get secret "${pname}-db-sidecar-tls" >/dev/null 2>&1 \
        && ok "$c: sidecar TLS Secret survives the idle window" \
        || fail "$c: sidecar TLS Secret gone while idle (wake respawn would have nothing to mount)"
    done
  fi

  # 2. Wake: a matched queue message routed by whichever cluster's splitter picks it up
  #    must wake a replica and be consumed EXACTLY once - messages buffer in the shared
  #    temp queue while the pod boots, so nothing is lost to the idle window.
  if [ "$SQS" = 1 ]; then
    # The wake message only reaches the temp queue through a PATCHED deployed consumer;
    # sending before the split lands would consume it as unmatched and prove nothing.
    wait_for_queuesplits_ready "${#WORKLOAD_CTXS[@]}" || FAILURES=$((FAILURES+1))
    say "Sending ONE matched message (type=${MATCH}-WAKE1) to wake the preview"
    task multicluster:sqs:send TYPE="${MATCH}-WAKE1" MESSAGE="wake" >/dev/null 2>&1
    consumed_by=""; deadline=$(( $(date +%s) + 300 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      for c in "${WORKLOAD_CTXS[@]}"; do
        if replica_logs "$c" | grep -q "type=${MATCH}-WAKE1"; then consumed_by="$c"; break; fi
      done
      [ -n "$consumed_by" ] && break
      sleep 5
    done
    if [ -n "$consumed_by" ]; then
      ok "wake message consumed by $consumed_by's 🎯 PREVIEW replica"

      # 3. The woken replica must still reach the shared branch through its sidecar - the
      #    branched env plus the tunnel chain have to survive the idle cycle, and the
      #    native sidecar must revalidate against the gateway before the app starts.
      #    Checked FIRST: the wake only buys IDLE_AFTER seconds of pod lifetime, and on a
      #    slow host the log/API polls below can outlast it - the pod then re-idles away
      #    mid-section, which is correct operator behavior, not a broken DB path.
      if [ "$DB" = 1 ]; then
        wpod=$(kubectl --context "$consumed_by" -n "$NS" get pods -l "preview.metalbear.co/session-uid,app=$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$wpod" ]; then
          if [ "$consumed_by" != "$DEFAULT_CTX" ]; then
            wsc=$(kubectl --context "$consumed_by" -n "$NS" get pod "$wpod" \
              -o jsonpath='{.status.initContainerStatuses[?(@.name=="mirrord-db-sidecar")].ready}' 2>/dev/null)
            [ "$wsc" = "true" ] && ok "$consumed_by: DB sidecar came back Ready on wake" \
              || fail "$consumed_by: DB sidecar not ready after wake (ready: ${wsc:-<none>})"
          fi
          if pf_up_current "$consumed_by" "preview.metalbear.co/session-uid,app=$APP" 17500; then
            db_ok=0
            for _ in $(seq 1 10); do
              curl -sf -m 5 "http://127.0.0.1:17500/db/select" >/dev/null 2>&1 && { db_ok=1; break; }
              sleep 3
            done
            [ "$db_ok" = 1 ] && ok "$consumed_by: woken replica reads the branch through the tunnel" \
              || fail "$consumed_by: woken replica cannot reach the branch"
          else
            fail "$consumed_by: port-forward to the woken replica never came up"
          fi
        else
          # Ready with no pod is a real failure; Idle with no pod means the idle window
          # elapsed before we got here - correct behavior, nothing left to probe.
          phase_now=$(previews_clusters | grep "^$consumed_by=" | cut -d= -f2)
          [ "$phase_now" = "Idle" ] \
            && warn "$consumed_by re-idled before the branch-path probe (slow host) - skipping it" \
            || fail "$consumed_by: no woken replica pod to check the branch path on (phase: ${phase_now:-unknown})"
        fi
      fi

      total=$(for c in "${WORKLOAD_CTXS[@]}"; do replica_logs "$c" | grep -o "type=${MATCH}-WAKE1"; done | wc -l | tr -d ' ')
      [ "$total" = 1 ] && ok "consumed exactly once across the replicas" \
        || fail "wake message consumed $total times (want 1)"
      woken=$(previews_clusters | grep "^$consumed_by=" | cut -d= -f2)
      # The wake window is short - by now the cluster may have legitimately re-idled.
      case "$woken" in
        Ready|Idle) ok "$consumed_by woke (phase now: $woken)" ;;
        *) fail "$consumed_by phase after wake: ${woken:-unknown} (want Ready or Idle)" ;;
      esac
      echo "    per-cluster phases: $(previews_clusters | paste -sd' ' -)"
    else
      fail "wake message never consumed by any replica"
    fi
  else
    warn "SQS infra not deployed - skipping the queue wake (only auto-idle verified)"
  fi

  # 4. Silence again cycles the woken replica back to Idle - no flapping, no stuck Ready.
  reidle_ok=0; deadline=$(( $(date +%s) + IDLE_AFTER + 240 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(previews_state "Idle")" = "ready" ] && { reidle_ok=1; break; }
    sleep 5
  done
  [ "$reidle_ok" = 1 ] && ok "silence cycled the preview back to Idle everywhere" \
    || fail "preview did not re-idle (state: $(previews_state Idle))"

  # 5. HTTP wake: a baggage request to ONE cluster's deployed app is parked by the
  #    operator (up to wake_timeout) while that cluster's proxy and replica boot, then
  #    served by the woken replica. Every OTHER cluster must stay Idle - wake is
  #    per-cluster, never fleet-wide. Runs off the re-idled state from step 4.
  if [ "$HTTP" = 1 ] && [ "$reidle_ok" = 1 ]; then
    hdr "[IDLE] HTTP wake: a held baggage request wakes ONLY the target cluster"
    wake_ctx="${NON_DEFAULT_CTXS[0]:-$DEFAULT_CTX}"
    if pf_up "$wake_ctx" "deploy/$APP" 17510; then
      hmarker="httpwake-$RUN_ID"
      hwoke=0
      for n in 1 2 3; do
        curl -sf -m 110 -H "baggage: mirrord-session=$KEY" \
          "http://127.0.0.1:17510/log/$hmarker-$n" >/dev/null 2>&1 && { hwoke=1; break; }
      done
      if [ "$hwoke" = 1 ]; then
        ok "$wake_ctx: held baggage request answered after the wake"
        # The response proves the app served it; the log line trails by kubelet log
        # propagation, so a single-shot grep right after the response flakes.
        hlogged=0
        for _ in $(seq 1 8); do
          replica_logs "$wake_ctx" | grep -q "$hmarker" && { hlogged=1; break; }
          sleep 2
        done
        [ "$hlogged" = 1 ] \
          && ok "$wake_ctx: request served by the WOKEN 🎯 PREVIEW replica (marker in its logs)" \
          || fail "$wake_ctx: response came back but the replica logs never saw the marker"
        hphase=$(previews_clusters | grep "^$wake_ctx=" | cut -d= -f2)
        [ "$hphase" = "Ready" ] && ok "$wake_ctx woke to Ready" \
          || fail "$wake_ctx phase after HTTP wake: ${hphase:-unknown} (want Ready)"
        for c in "${WORKLOAD_CTXS[@]}"; do
          [ "$c" = "$wake_ctx" ] && continue
          ophase=$(previews_clusters | grep "^$c=" | cut -d= -f2)
          [ "$ophase" = "Idle" ] && ok "$c untouched by the wake (still Idle)" \
            || fail "$c phase changed to ${ophase:-unknown} - HTTP wake must stay per-cluster"
        done
      else
        fail "$wake_ctx: baggage request never answered - HTTP wake failed (wake_timeout exceeded or steal not held while idle)"
      fi
    else
      fail "$wake_ctx: port-forward to the deployed app never came up"
    fi
  fi
fi

hdr "log excerpts · what the 🎯 PREVIEW replicas vs the 🏠 ORIGINAL apps actually served"
for c in "${WORKLOAD_CTXS[@]}"; do
  printf '  %s🖥  %s%s\n' "$BLD" "$c" "$RST"
  excerpt=$(replica_logs "$c" | grep -E "HTTP marker|DB (insert|select|connected)|SQS #" | tail -8 \
    | awk '{icon="·"} /HTTP marker/{icon="🔀"} /DB (insert|select|connected)/{icon="💾"} /SQS #/{icon="📬"} {print "        " icon " " $0}')
  if [ -n "$excerpt" ]; then
    printf '     %s\n' "🎯 PREVIEW replica served:"
    printf '%s\n' "$excerpt"
  else
    printf '     %s\n' "🎯 PREVIEW replica: (no traffic this run)"
  fi
  dexcerpt=$(deployed_logs "$c" | grep -E "HTTP marker|SQS #" | tail -4 \
    | awk '{icon="·"} /HTTP marker/{icon="🔀"} /SQS #/{icon="📬"} {print "        " icon " " $0}')
  if [ -n "$dexcerpt" ]; then
    printf '     %s\n' "🏠 ORIGINAL app served:"
    printf '%s\n' "$dexcerpt"
  fi
done

# ---------------------------------------------------------------------------
# [TEARDOWN]
# ---------------------------------------------------------------------------
if [ "$KEEP" = 1 ]; then
  warn "KEEP=1 - leaving the preview running (sqs-consumer stays scaled to 0)"
else
  # Fail-anywhere needs a copy to fail; with replicas disabled and no queues none exist.
  if [ "$TEARDOWN" = "fail" ] && [ "$REPLICAS" = 0 ] && [ "$SQS" = 0 ]; then
    warn "TEARDOWN=fail needs a copy (none in disabled no-queue mode) - plain stop instead"
    TEARDOWN=stop
  fi
  if [ "$TEARDOWN" = "fail" ] && [ -n "${NON_DEFAULT_CTXS[0]:-}" ]; then
    hdr "[FAIL] a copy failing on ONE cluster fails the preview EVERYWHERE"
    victim="${NON_DEFAULT_CTXS[0]}"
    vname=$(kubectl --context "$victim" -n "$NS" get previewsessions.preview.mirrord.metalbear.co -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$vname" ]; then
      fail "$victim: no copy to fail"
    else
      now=$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)
      kubectl --context "$victim" -n "$NS" patch previewsessions.preview.mirrord.metalbear.co "$vname" \
        --subresource=status --type=merge \
        -p "{\"status\":{\"phase\":\"Failed\",\"failureMessage\":\"e2e: simulated replica failure\",\"failedAt\":\"$now\"}}" >/dev/null 2>&1 \
        && ok "$victim: copy status patched to Failed" || fail "$victim: status patch failed"

      deadline=$(( $(date +%s) + 180 )); pphase=""
      while [ "$(date +%s)" -lt "$deadline" ]; do
        pphase=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        [ "$pphase" = "Failed" ] && break
        sleep 4
      done
      if [ "$pphase" = "Failed" ]; then
        pmsg=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A -o jsonpath='{.items[0].status.failureMessage}' 2>/dev/null)
        ok "primary preview Failed after the copy failure"
        echo "    failureMessage: $pmsg"
        # The operator names the failing cluster by its REGISTRY name; in this sandbox that
        # matches the kubectl context, so a mismatch is only warned about, not failed.
        echo "$pmsg" | grep -q "$victim" && ok "failure message names the failing cluster" \
          || warn "failure message does not name cluster $victim"
      else
        fail "primary never became Failed after $victim's copy failed (last: ${pphase:-none})"
      fi

      for c in ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"}; do
        gone=0; deadline=$(( $(date +%s) + 120 ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
          kubectl --context "$c" -n "$NS" get previewsessions.preview.mirrord.metalbear.co "$vname" >/dev/null 2>&1 || { gone=1; break; }
          sleep 4
        done
        [ "$gone" = 1 ] && ok "$c: copy deleted after the preview failed" \
          || fail "$c: copy still exists after the preview failed"
      done
    fi
  elif [ "$TEARDOWN" = "fail" ]; then
    warn "TEARDOWN=fail needs a non-default workload cluster - falling back to plain stop"
  fi

  if [ "$TEARDOWN" = "dead-cluster" ]; then
    hdr "[DEAD] preview stop must not wedge on an unreachable cluster"
    victim="${NON_DEFAULT_CTXS[0]:-}"
    if [ -z "$victim" ]; then
      warn "no non-default workload cluster - falling back to plain stop"
    elif minikube pause -p "$victim" >/dev/null 2>&1; then
      ok "$victim paused (apiserver unreachable)"
      t0=$(date +%s)
      ( MIRRORD_KUBE_CONTEXT="$PRIMARY_CTX" MIRRORD_CHECK_VERSION=false \
          "$MIRRORD_BIN" preview stop -k "$KEY" >/dev/null 2>&1 ) &
      BG_PIDS+=($!)
      # The operator holds the primary's finalizer only within its cleanup-confirm window
      # (90s) when a cluster cannot confirm its copy deletion; the deadline adds reconcile
      # backoff slack on top. Before that window existed this wedged in Terminating for as
      # long as the cluster stayed down.
      gone=0; deadline=$(( t0 + 180 ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        n=$(kubectl --context "$PRIMARY_CTX" get previewsessions.preview.mirrord.metalbear.co -A --no-headers 2>/dev/null | grep -c -- "$KEY" || true)
        [ "$n" = 0 ] && { gone=1; break; }
        sleep 5
      done
      elapsed=$(( $(date +%s) - t0 ))
      [ "$gone" = 1 ] && ok "primary CR gone ${elapsed}s after stop - a dead cluster does not wedge deletion" \
        || fail "primary CR still present ${elapsed}s after stop - deletion wedged on the paused cluster"

      say "Unpausing $victim and scrubbing its leftover copy (TTL would expire it in production)"
      minikube unpause -p "$victim" >/dev/null 2>&1 || warn "unpause failed - run 'minikube unpause -p $victim' manually"
      for _ in $(seq 1 20); do
        kubectl --context "$victim" -n "$NS" get previewsessions.preview.mirrord.metalbear.co >/dev/null 2>&1 && break
        sleep 3
      done
      kubectl --context "$victim" -n "$NS" delete previewsessions.preview.mirrord.metalbear.co --all --ignore-not-found --wait=false >/dev/null 2>&1 || true
    else
      fail "could not pause $victim - dead-cluster scenario not exercised"
    fi
  fi

  hdr "[TEARDOWN] preview stop cleans every cluster"
  # Only plain stop asserts the timing bound: fail teardown already deleted the copies
  # (nothing to confirm) and dead-cluster measures its own, longer bound.
  stop_preview "$([ "$TEARDOWN" = stop ] && echo fast)" || FAILURES=$((FAILURES+1))
  sleep 10
  for c in ${NON_DEFAULT_CTXS[@]+"${NON_DEFAULT_CTXS[@]}"}; do
    if kubectl --context "$c" -n "$NS" get secret -o name 2>/dev/null | grep -q -- "-db-sidecar-tls"; then
      fail "$c: sidecar TLS Secret leaked after teardown"
    else
      ok "$c: sidecar TLS Secret garbage-collected with the copy"
    fi
  done
  if [ "$SQS" = 1 ]; then
    kubectl --context "$PRIMARY_CTX" -n mirrord delete mirrordsplitconfig combo-split-config --ignore-not-found >/dev/null 2>&1
    kubectl --context "$PRIMARY_CTX" -n "$NS" delete mirrordsplitconfig combo-split-config --ignore-not-found >/dev/null 2>&1
    # Broadcast copies on the members are cleaned by the sync on source deletion; sweep
    # them anyway so a stopped operator cannot leak them into the next run.
    for c in "${WORKLOAD_CTXS[@]}"; do
      kubectl --context "$c" -n "$NS" delete mirrordsplitconfig combo-split-config --ignore-not-found >/dev/null 2>&1
    done
  fi
  restore_sqs_consumer
fi

run_summary_table
echo
if [ "$FAILURES" != 0 ]; then
  say "${RED}$FAILURES CHECK(S) FAILED${RST} ($OK_COUNT passed)"
  exit 1
elif [ "$KNOWN_COUNT" != 0 ]; then
  say "${YEL}PASSED WITH $KNOWN_COUNT KNOWN-BUG CHECK(S)${RST} ($OK_COUNT passed) - tracked, not a regression"
  exit 2
else
  say "${GRN}ALL CHECKS PASSED${RST} ($OK_COUNT checks)"
  exit 0
fi
