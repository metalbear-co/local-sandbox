#!/usr/bin/env bash
#
# End-to-end test: `feature.db_branches: "*"` / `["id"]` resolve against the `dbBranches` on
# the target's MirrordSplitConfig, and sessions under one key share the branches
# (INT-796 operator side, INT-801 CLI side).
#
# Cases, each PASS/FAIL:
#   1. WILDCARD: cake-maker's SplitConfig has two pg entries (orders-pg, pg-main) that both
#               read DATABASE_URL. A session with "*" gets DATABASE_URL rewritten, one
#               BranchDatabase per entry named <entry>-<key> labeled with the key, each
#               recording its source host/port/database, and a same-source warning.
#   2. SHARE:   orders' SplitConfig has orders-pg too. A session on orders with ["orders-pg"]
#               under the same key lands on the SAME branch (same rewritten URL, no new CR).
#   3. UNKNOWN: ["nope"] fails before anything is created, naming `nope` and the ids there.
#   4. INLINE:  inline db_branches on cake-maker win, with the "ignoring dbBranches on
#               MirrordSplitConfig `...`" warning, and only the inline branch exists.
#   5. MISMATCH: a workload whose entry says copy mode "schema" attaching to the "empty"
#               branch fails with the copy-mode message naming the creator.
#
# Prerequisites:
#   - minikube (bearkube) running, `task migrations:deploy` (postgres-test source) applied
#   - `task operator:crds` from the INT-796 operator worktree, then `task operator:dev`
#   - a mirrord CLI built from the INT-801 branch (MIRRORD_BIN or ../mirrord/.worktrees/INT-801)
#
# Usage:
#   ./test-split-config-db-branches.sh
#   CASES="1 2" ./test-split-config-db-branches.sh    # a subset (1-5)
#   KEEP=1 ./test-split-config-db-branches.sh         # leave the resources in place
#
# Env knobs (all optional):
#   MIRRORD_BIN     mirrord CLI (default: INT-801 worktree build, then main build, then PATH)
#   NAMESPACE       namespace for the targets (default test-mirrord)
#   READY_TIMEOUT   seconds for a branch to come up (default 300)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-test-mirrord}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
CASES="${CASES:-1 2 3 4 5}"
KEEP="${KEEP:-0}"
BRANCH_CRD="branchdatabases.dbs.mirrord.metalbear.co"
SPLIT_CRD="mirrordsplitconfigs.queues.mirrord.metalbear.co"
SESSION_KEY_LABEL="mirrord-session-key"

if [ -z "${MIRRORD_BIN:-}" ]; then
  for candidate in "$ROOT_DIR/../mirrord/.worktrees/INT-801/target/debug/mirrord" \
                   "$ROOT_DIR/../mirrord/target/debug/mirrord" \
                   "$ROOT_DIR/../mirrord/target/aarch64-apple-darwin/debug/mirrord"; do
    [ -x "$candidate" ] && { MIRRORD_BIN="$candidate"; break; }
  done
  MIRRORD_BIN="${MIRRORD_BIN:-mirrord}"
fi

WORKDIR="$(mktemp -d /tmp/split-config-db-branches.XXXXXX)"
RUN_TAG="$(basename "$WORKDIR" | tr -cd 'a-zA-Z0-9' | tail -c 6 | tr 'A-Z' 'a-z')"
KEY="k$RUN_TAG"
CAKE="cake-maker-$RUN_TAG"
ORDERS="orders-$RUN_TAG"
SOURCE_URL="postgresql://postgres:postgres@postgres-test:5432/source_db"
PIDS=()

HAVE_GUM=0
command -v gum >/dev/null 2>&1 && HAVE_GUM=1
header() {
  if [ "$HAVE_GUM" = 1 ]; then gum style --border rounded --padding "0 2" --margin "1 0" --bold "$1"
  else printf '\n\033[1m=== %s ===\033[0m\n' "$1"; fi
}
info() { printf '\033[0;32m[INFO]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; }
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
FAILURES=0
RESULTS=()
check() { if [ "$2" = 0 ]; then pass "$1"; RESULTS+=("PASS  $1"); else fail "$1"; RESULTS+=("FAIL  $1"); FAILURES=$((FAILURES + 1)); fi; }

cleanup() {
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1; done
  if [ "$KEEP" = 1 ]; then warn "KEEP=1 - leaving deployments, SplitConfigs, and branches (key $KEY)"; return; fi
  kubectl delete "$SPLIT_CRD" -n "$NAMESPACE" "$CAKE" "$ORDERS" --ignore-not-found >/dev/null 2>&1
  kubectl get "$BRANCH_CRD" -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg k "$KEY" '.items[] | select((.spec.id | endswith($k)) or (.metadata.labels["'"$SESSION_KEY_LABEL"'"] == $k)) | .metadata.name' \
    | xargs -r kubectl delete "$BRANCH_CRD" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl delete deploy -n "$NAMESPACE" "$CAKE" "$ORDERS" --ignore-not-found >/dev/null 2>&1
  info "cleaned up"
}
trap cleanup EXIT

deploy_workload() { # <name>
  kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: $1, namespace: $NAMESPACE }
spec:
  replicas: 1
  selector: { matchLabels: { app: $1 } }
  template:
    metadata: { labels: { app: $1, test-scenario: split-config-db-branches } }
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "sleep 3600"]
        env:
        - { name: DATABASE_URL, value: "$SOURCE_URL" }
EOF
  kubectl wait --for=condition=available "deploy/$1" -n "$NAMESPACE" --timeout=120s >/dev/null \
    || { fail "deploy/$1 not ready"; exit 1; }
}

split_config() { # <workload> <mode> [second-entry-id]
  local second=""
  [ -n "${3:-}" ] && second="
    - id: $3
      type: pg
      version: \"17\"
      ttlSecs: 300
      creationTimeoutSecs: 180
      connection: { url: DATABASE_URL }
      copy: { mode: $2, allowedModes: [empty, schema] }"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: queues.mirrord.metalbear.co/v1alpha
kind: MirrordSplitConfig
metadata: { name: $1, namespace: $NAMESPACE }
spec:
  targetRef: { apiVersion: apps/v1, kind: Deployment, name: $1 }
  dbBranches:
    - id: orders-pg
      type: pg
      version: "17"
      ttlSecs: 300
      creationTimeoutSecs: 180
      connection: { url: DATABASE_URL }
      copy: { mode: $2, allowedModes: [empty, schema] }$second
EOF
  local waited=0
  while [ "$waited" -lt 60 ]; do
    [ "$(kubectl get "$SPLIT_CRD" -n "$NAMESPACE" "$1" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" = "True" ] && return 0
    sleep 2; waited=$((waited + 2))
  done
  fail "MirrordSplitConfig $1 never became Accepted: $(kubectl get "$SPLIT_CRD" -n "$NAMESPACE" "$1" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].message}')"
  return 1
}

# Writes a mirrord config for <workload> with the given db_branches JSON and starts a shell
# session that prints its DATABASE_URL; the log path is echoed.
start_session() { # <workload> <db_branches-json> <log-name>
  local config="$WORKDIR/$3.json" log="$WORKDIR/$3.log"
  cat > "$config" <<EOF
{
  "operator": true,
  "key": "$KEY",
  "target": { "path": "deploy/$1", "namespace": "$NAMESPACE" },
  "feature": {
    "env": true,
    "fs": "local",
    "network": { "incoming": "off", "outgoing": true },
    "db_branches": $2
  }
}
EOF
  "$MIRRORD_BIN" exec -f "$config" -- sh -c 'echo "SESSION_ENV=$DATABASE_URL"; sleep 240' > "$log" 2>&1 &
  PIDS+=($!)
  disown "${PIDS[-1]}" 2>/dev/null || true
  printf '%s' "$log"
}

wait_session_env() { # <log> -> prints the DATABASE_URL the session saw
  local waited=0 line
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    line="$(grep -m1 '^SESSION_ENV=' "$1" 2>/dev/null)"
    [ -n "$line" ] && { printf '%s' "${line#SESSION_ENV=}"; return 0; }
    grep -qi "^Error:" "$1" 2>/dev/null && { fail "session failed - log tail:" >&2; tail -8 "$1" >&2; return 1; }
    sleep 3; waited=$((waited + 3))
  done
  fail "session never printed its env (see $1)" >&2
  return 1
}

wait_log_contains() { # <log> <needle> [timeout]
  local waited=0 limit="${3:-$READY_TIMEOUT}"
  while [ "$waited" -lt "$limit" ]; do
    grep -q -- "$2" "$1" 2>/dev/null && return 0
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

branches_under_key() { kubectl get "$BRANCH_CRD" -n "$NAMESPACE" -l "$SESSION_KEY_LABEL=$KEY" -o json 2>/dev/null; }

# ---------------------------------------------------------------------------
header "SplitConfig db_branches - preflight"
command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq not found"; exit 1; }
"$MIRRORD_BIN" --version >/dev/null 2>&1 || { fail "mirrord CLI not usable: $MIRRORD_BIN (build the INT-801 branch: task mirrord:cli:build)"; exit 1; }
info "mirrord: $MIRRORD_BIN ($("$MIRRORD_BIN" --version 2>/dev/null | head -1))"
info "workdir: $WORKDIR   key: $KEY"
kubectl get crd "$SPLIT_CRD" >/dev/null 2>&1 || { fail "CRD $SPLIT_CRD missing - run: task operator:crds"; exit 1; }
kubectl get crd "$SPLIT_CRD" -o json | jq -e '.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.dbBranches' >/dev/null 2>&1 \
  || { fail "the installed MirrordSplitConfig CRD has no dbBranches - run: task operator:crds from the INT-796 worktree"; exit 1; }
kubectl get pod postgres-test -n "$NAMESPACE" >/dev/null 2>&1 || { fail "postgres-test source missing - run: task migrations:deploy"; exit 1; }
if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
else
  warn "no operator:dev found - the deployed operator must support db_branches from SplitConfig"
fi

header "Deploy: two workloads reading DATABASE_URL + their SplitConfigs"
deploy_workload "$CAKE"
deploy_workload "$ORDERS"
split_config "$CAKE" empty pg-main || exit 1
split_config "$ORDERS" empty || exit 1
info "deploy/$CAKE (entries orders-pg, pg-main) and deploy/$ORDERS (entry orders-pg) ready"

FIRST_URL=""
case " $CASES " in *" 1 "*)
  header "Case 1 (wildcard): one branch per entry, named <entry>-<key>, source recorded"
  LOG1="$(start_session "$CAKE" '"*"' case1-wildcard)"
  info "follow it with: tail -f $LOG1"
  if FIRST_URL="$(wait_session_env "$LOG1")"; then
    [ "$FIRST_URL" != "$SOURCE_URL" ] && check "wildcard: DATABASE_URL rewritten to a branch" 0 || check "wildcard: DATABASE_URL rewritten to a branch" 1
    ids="$(branches_under_key | jq -r '.items[].spec.id' | sort | tr '\n' ' ')"
    info "branches under key: $ids"
    [ "$ids" = "orders-pg-$KEY pg-main-$KEY " ] && check "wildcard: branches orders-pg-<key> and pg-main-<key> carry the key label" 0 \
      || check "wildcard: branches orders-pg-<key> and pg-main-<key> carry the key label" 1
    sources="$(branches_under_key | jq -r '.items[].status.source | "\(.host):\(.port)/\(.database)"' | sort -u | tr '\n' ' ')"
    info "recorded sources: $sources"
    [ "$sources" = "postgres-test:5432/source_db " ] && check "wildcard: each branch records host:port/database" 0 || check "wildcard: each branch records host:port/database" 1
    wait_log_contains "$LOG1" "resolved to the same database as" 30 && check "wildcard: same-source warning names the sibling branch" 0 \
      || check "wildcard: same-source warning names the sibling branch" 1
    grep -q "using 2 dbBranches entries from MirrordSplitConfig" "$LOG1" && info "$(grep -m1 'dbBranches entries' "$LOG1")"
  else
    check "wildcard: session came up" 1
  fi
  ;;
esac

case " $CASES " in *" 2 "*)
  header "Case 2 (share): orders attaches to the branch cake-maker created"
  if [ -z "$FIRST_URL" ]; then warn "case 1 did not run or failed; starting the creator first"; LOG1="$(start_session "$CAKE" '"*"' case2-creator)"; FIRST_URL="$(wait_session_env "$LOG1")" || true; fi
  before="$(branches_under_key | jq '.items | length')"
  LOG2="$(start_session "$ORDERS" '["orders-pg"]' case2-share)"
  if SECOND_URL="$(wait_session_env "$LOG2")"; then
    [ "$SECOND_URL" = "$FIRST_URL" ] && check "share: both services see the same branch URL" 0 || { check "share: both services see the same branch URL" 1; warn "first=$FIRST_URL second=$SECOND_URL"; }
    after="$(branches_under_key | jq '.items | length')"
    [ "$after" = "$before" ] && check "share: attaching created no new branch ($after)" 0 || check "share: attaching created no new branch ($before -> $after)" 1
  else
    check "share: session came up" 1
  fi
  ;;
esac

case " $CASES " in *" 3 "*)
  header "Case 3 (unknown id): fails naming the id and the ids the workload has"
  LOG3="$(start_session "$CAKE" '["nope"]' case3-unknown)"
  if wait_log_contains "$LOG3" '`nope`' 60 && grep -q '`orders-pg`' "$LOG3"; then
    check "unknown id: error names \`nope\` and the available ids" 0
  else
    check "unknown id: error names \`nope\` and the available ids" 1; tail -6 "$LOG3"
  fi
  ;;
esac

case " $CASES " in *" 4 "*)
  header "Case 4 (inline wins): warning names the ignored SplitConfig"
  LOG4="$(start_session "$CAKE" "[{\"id\": \"inline-$KEY\", \"type\": \"pg\", \"version\": \"17\", \"ttl_secs\": 300, \"creation_timeout_secs\": 180, \"connection\": {\"url\": \"DATABASE_URL\"}, \"copy\": {\"mode\": \"empty\"}}]" case4-inline)"
  if wait_log_contains "$LOG4" "ignoring dbBranches on MirrordSplitConfig \`$CAKE\`" 60; then
    check "inline: warning names MirrordSplitConfig \`$CAKE\`" 0
  else
    check "inline: warning names MirrordSplitConfig \`$CAKE\`" 1; tail -6 "$LOG4"
  fi
  if url="$(wait_session_env "$LOG4")" && [ "$url" != "$SOURCE_URL" ]; then
    check "inline: the inline branch is used" 0
  else
    check "inline: the inline branch is used" 1
  fi
  ;;
esac

case " $CASES " in *" 5 "*)
  header "Case 5 (copy mode mismatch): schema entry cannot attach to the empty branch"
  split_config "$ORDERS" schema || exit 1
  if [ -z "$FIRST_URL" ]; then LOG1="$(start_session "$CAKE" '"*"' case5-creator)"; FIRST_URL="$(wait_session_env "$LOG1")" || true; fi
  LOG5="$(start_session "$ORDERS" '"*"' case5-mismatch)"
  if wait_log_contains "$LOG5" "exists with copy mode \"empty\", this service asked for \"schema\"" 90 && grep -q "created it" "$LOG5"; then
    check "mismatch: error names the branch, both modes, and the creator" 0
  else
    check "mismatch: error names the branch, both modes, and the creator" 1; tail -6 "$LOG5"
  fi
  ;;
esac

header "Summary"
for line in "${RESULTS[@]}"; do printf '  %s\n' "$line"; done
[ "$FAILURES" = 0 ] && pass "all checks passed" || fail "$FAILURES check(s) failed"
exit "$FAILURES"
