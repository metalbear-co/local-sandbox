#!/usr/bin/env bash
#
# Interactive proof for INT-732: a MirrordClusterPolicy that excludes DATABASE_URL must not
# break db branching once `allowMirrordOverrides` is on, and must keep hiding the variable
# when it is off.
#
# The customer shape: `env.exclude: [DATABASE_URL]` in a cluster policy, plus a branch whose
# connection params are carved out of DATABASE_URL with `value_pattern`. Without the flag
# the exclusion applies to every env request the session makes, so the operator's rewrite
# has nothing to work on and the CLI's portforward never finds the variable: the branch is
# Ready but `mirrord db-branches connections` lists nothing. With the flag the operator keeps
# the variable off the agent-side filter, rewrites the patterned spans, and delivers only the
# rewritten value; the portforward sees it and registers.
#
# Two phases against the same target and branch, each with its own policy:
#   1. flag off - the app sees DATABASE_URL=UNSET, no portforward listed (policy wins)
#   2. flag on  - the app sees a rewritten DATABASE_URL (never the source host), the
#                 portforward is listed, and the forwarded port reaches the branch
#
#   task cockroachdb-tls:policy:portforward:test
#   task cockroachdb-tls:policy:portforward:test MIRRORD_BIN=/path/to/mirrord
#
# Needs an operator that knows the flag (task operator:dev from a branch with it, CRDs
# applied via task operator:crds). Reuses the crdb-tls source (task cockroachdb-tls:deploy).

set -euo pipefail

NAMESPACE="${NAMESPACE:-crdb-tls-test}"
MIRRORD_BIN="${MIRRORD_BIN:-${MIRRORD_BINARY:-mirrord}}"
TARGET_POD="${TARGET_POD:-cockroachdb-server-tls}"
DB_ID="crdb-policy-branch"
POLICY_NAME="crdb-policy-portforward-test"

WORKDIR="$(mktemp -d)"
CONFIG="$WORKDIR/policy-mirrord.json"
SESSION_LOG=""
SESSION_PID=""

say()  { gum style --foreground 212 "$1"; }
ok()   { gum style --foreground 82  "  PASS  $1"; }
bad()  { gum style --foreground 196 "  FAIL  $1"; }
info() { gum style --foreground 245 "  $1"; }

stop_session() {
  [[ -n "$SESSION_PID" ]] && kill "$SESSION_PID" 2>/dev/null || true
  SESSION_PID=""
}

cleanup() {
  stop_session
  kubectl delete mirrordclusterpolicies.policies.mirrord.metalbear.co "$POLICY_NAME" \
    >/dev/null 2>&1 || true
  # Drop the branch this run created so a rerun starts clean; TTL would sweep it anyway.
  kubectl -n "$NAMESPACE" delete branchdatabases.dbs.mirrord.metalbear.co \
    -l "mirrord-branch-id=$DB_ID" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

require() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1"; exit 1; }; }
for dep in kubectl jq gum cockroach python3 "$MIRRORD_BIN"; do require "$dep"; done

if ! kubectl -n "$NAMESPACE" get pod "$TARGET_POD" >/dev/null 2>&1; then
  bad "target pod $TARGET_POD not found in $NAMESPACE"
  info "run: task cockroachdb-tls:deploy"
  exit 1
fi

# The flag must exist in the installed CRD, otherwise the API server silently drops it and
# phase 2 fails for the wrong reason.
if ! kubectl get crd mirrordclusterpolicies.policies.mirrord.metalbear.co -o json \
    | jq -e '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.env.properties.allowMirrordOverrides' >/dev/null; then
  bad "the installed MirrordClusterPolicy CRD has no env.allowMirrordOverrides"
  info "apply the branch's CRDs: task operator:crds"
  exit 1
fi

source_url="$(kubectl -n "$NAMESPACE" get pod "$TARGET_POD" \
  -o jsonpath='{.spec.containers[0].env[?(@.name=="DATABASE_URL")].value}')"
source_host="$(sed -E 's#.*@([^:/]+).*#\1#' <<<"$source_url")"

say "INT-732: env policy excluding DATABASE_URL vs db branching"
info "mirrord binary: $($MIRRORD_BIN --version 2>/dev/null || echo "$MIRRORD_BIN")"
info "target: $TARGET_POD in $NAMESPACE"
info "source DATABASE_URL on the pod: $source_url"

# Same reporter shape as crdb-pattern-portforward-e2e.sh: host/port/database carved out of
# one DATABASE_URL. user/password are not patterned, which is exactly the shape the flag's
# leftover-span caveat is about; the source URL here carries neither, so nothing can leak.
cat > "$CONFIG" <<EOF
{
  "target": { "path": { "pod": "$TARGET_POD" }, "namespace": "$NAMESPACE" },
  "operator": true,
  "feature": {
    "env": true,
    "fs": "local",
    "network": { "incoming": "off", "outgoing": true },
    "db_branches": [
      {
        "id": "$DB_ID",
        "type": "cockroachdb",
        "version": "latest-v26.2",
        "name": "policy_branch",
        "ttl_secs": 300,
        "creation_timeout_secs": 180,
        "connection": {
          "params": {
            "host":     { "env_var_name": "DATABASE_URL", "value_pattern": "@(?P<host>[^:/]+)" },
            "port":     { "env_var_name": "DATABASE_URL", "value_pattern": ":(?P<port>[0-9]+)/" },
            "database": { "env_var_name": "DATABASE_URL", "value_pattern": "[0-9]/(?P<database>[^?]+)" }
          }
        },
        "copy": { "mode": "all" }
      }
    ]
  }
}
EOF

apply_policy() {
  local allow="$1"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: policies.mirrord.metalbear.co/v1alpha
kind: MirrordClusterPolicy
metadata:
  name: $POLICY_NAME
spec:
  targetPath: "*${TARGET_POD}*"
  block: []
  env:
    exclude:
      - DATABASE_URL
    allowMirrordOverrides: $allow
EOF
}

# The app prints what it sees, then idles so the session (and its portforward) stays up.
# python3 rather than sh: on a Mac /bin/sh is an arm64e binary that mirrord can only run
# under Rosetta, which needs an x86_64 layer slice a local build does not have.
# DATABASE_URL is unset locally first: mirrord layers the remote env over the local one,
# so a value exported in the developer's shell would show through whenever the remote
# one is hidden and fake a leak.
start_session() {
  SESSION_LOG="$WORKDIR/session-$1.log"
  env -u DATABASE_URL "$MIRRORD_BIN" exec -f "$CONFIG" -- python3 -c \
    "import os, time; print('DATABASE_URL=' + os.environ.get('DATABASE_URL', 'UNSET'), flush=True); time.sleep(600)" \
    >"$SESSION_LOG" 2>&1 &
  SESSION_PID=$!
  disown "$SESSION_PID" 2>/dev/null || true
}

wait_branch_ready() {
  local phase=""
  for _ in $(seq 1 120); do
    phase="$(kubectl -n "$NAMESPACE" get branchdatabases.dbs.mirrord.metalbear.co \
      -l "mirrord-branch-id=$DB_ID" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Ready" ]] && return 0
    kill -0 "$SESSION_PID" 2>/dev/null || { bad "mirrord session exited early"; cat "$SESSION_LOG"; return 1; }
    sleep 2
  done
  bad "branch never became Ready (phase=$phase)"; cat "$SESSION_LOG"; return 1
}

wait_app_line() {
  local line=""
  for _ in $(seq 1 60); do
    line="$(grep -m1 '^DATABASE_URL=' "$SESSION_LOG" 2>/dev/null || true)"
    [[ -n "$line" ]] && { echo "${line#DATABASE_URL=}"; return 0; }
    kill -0 "$SESSION_PID" 2>/dev/null || { bad "mirrord session exited early"; cat "$SESSION_LOG" >&2; return 1; }
    sleep 2
  done
  bad "the app never printed DATABASE_URL"; cat "$SESSION_LOG" >&2; return 1
}

listed_address() {
  "$MIRRORD_BIN" db-branches connections --format json 2>/dev/null \
    | jq -r --arg id "$DB_ID" '.[] | select(.db_id == $id) | .connection_string' | head -1
}

# ---------------------------------------------------------------- phase 1: flag off
say "phase 1/2: policy excludes DATABASE_URL, allowMirrordOverrides: false"
apply_policy false
start_session off
say "  waiting for the branch..."
wait_branch_ready
ok "branch is Ready (the operator reads the source server-side, the policy does not stop that)"

seen="$(wait_app_line)"
if [[ "$seen" == "UNSET" ]]; then
  ok "app sees DATABASE_URL=UNSET: the exclusion holds"
else
  bad "app sees DATABASE_URL=$seen, expected UNSET with the flag off"
  exit 1
fi

# Give the CLI the same window phase 2 gets, then expect nothing: the portforward could
# not resolve host/port from a hidden variable. `connections` warns about it in the
# session log (mirrord >= 3.255).
sleep 10
address="$(listed_address)"
if [[ -z "$address" ]]; then
  ok "no portforward listed for $DB_ID (nothing to forward from a hidden variable)"
  grep -i "missing from the target's environment" "$SESSION_LOG" >/dev/null 2>&1 \
    && info "CLI warned: db branch connection env var is missing from the target's environment"
else
  bad "portforward listed with the flag off: $DB_ID -> $address"
  exit 1
fi
stop_session

# ---------------------------------------------------------------- phase 2: flag on
say "phase 2/2: same policy, allowMirrordOverrides: true"
apply_policy true
start_session on
say "  waiting for the branch..."
wait_branch_ready
ok "branch is Ready"

seen="$(wait_app_line)"
if [[ "$seen" == "UNSET" ]]; then
  bad "app sees DATABASE_URL=UNSET with the flag on: the operator did not deliver the rewrite"
  info "is operator:dev running from a branch with allowMirrordOverrides?"
  exit 1
elif [[ "$seen" == *"@${source_host}:"* ]]; then
  bad "app sees the SOURCE host inside DATABASE_URL: $seen"
  exit 1
else
  ok "app sees the rewritten DATABASE_URL=$seen"
  info "no '@${source_host}:' in it: the excluded original never reached the app"
fi

say "  waiting for the portforward to be registered..."
address=""
for _ in $(seq 1 30); do
  address="$(listed_address)"
  [[ -n "$address" ]] && break
  kill -0 "$SESSION_PID" 2>/dev/null || { bad "mirrord session exited early"; cat "$SESSION_LOG"; exit 1; }
  sleep 2
done
if [[ -z "$address" ]]; then
  bad "branch '$DB_ID' is NOT listed in db-branches connections with the flag on"
  cat ~/.mirrord/db_branch_portforwards/*.json 2>/dev/null | jq . || true
  exit 1
fi
ok "branch is listed: $DB_ID -> $address"

host="${address%%:*}"
port="${address##*:}"
rows="$(cockroach sql --insecure \
  --url "postgresql://root@${host}:${port}/policy_branch" \
  --format csv -e "SELECT count(*) FROM events" 2>/dev/null | tail -1 || echo "")"
if [[ "$rows" == "3" ]]; then
  ok "queried the branch through $address: events has $rows rows (source copied)"
else
  bad "could not read the branch through $address (got '$rows', expected 3)"
  exit 1
fi

say "INT-732 verified: the policy hides DATABASE_URL until allowMirrordOverrides lets the rewrite through."
