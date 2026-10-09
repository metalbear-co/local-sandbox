#!/usr/bin/env bash
#
# Interactive proof for INT-275: a DB branch whose connection params are carved out of a
# URL-shaped env var with `value_pattern` must show up in `mirrord db-branches connections`
# AND its forwarded port must reach the branch.
#
# The bug: `resolve_port_mappings` read the whole env var value as a bare host/port, so a
# `value_pattern` param never parsed and the forward was dropped silently - the session file
# was written with `"portforwards": []` and the listing said "No active portforward sessions"
# even though the branch was Ready. URL-source and plain-variable params were never affected;
# only `value_pattern` params were.
#
# This drives the exact reporter shape: `type: cockroachdb` with host/port/database patterns
# over one DATABASE_URL. Run it against a build WITH the fix (pass MIRRORD_BIN) to see it
# pass, or against a released mirrord <= 3.253.x to watch it reproduce the empty listing.
#
#   task cockroachdb-tls:portforward:test
#   task cockroachdb-tls:portforward:test MIRRORD_BIN=/path/to/fixed/mirrord
#
# Reuses the crdb-tls source (task cockroachdb-tls:deploy); nothing to install beyond
# kubectl, jq, gum, cockroach, and the mirrord binary.

set -euo pipefail

NAMESPACE="${NAMESPACE:-crdb-tls-test}"
MIRRORD_BIN="${MIRRORD_BIN:-${MIRRORD_BINARY:-mirrord}}"
TARGET_POD="${TARGET_POD:-cockroachdb-server-tls}"
DB_ID="crdb-pattern-branch"

WORKDIR="$(mktemp -d)"
SESSION_LOG="$WORKDIR/session.log"
CONFIG="$WORKDIR/pattern-mirrord.json"
SESSION_PID=""

say()  { gum style --foreground 212 "$1"; }
ok()   { gum style --foreground 82  "  PASS  $1"; }
bad()  { gum style --foreground 196 "  FAIL  $1"; }
info() { gum style --foreground 245 "  $1"; }

cleanup() {
  [[ -n "$SESSION_PID" ]] && kill "$SESSION_PID" 2>/dev/null || true
  # Drop the branch this run created so a rerun starts clean; TTL would sweep it anyway.
  kubectl -n "$NAMESPACE" delete branchdatabases.dbs.mirrord.metalbear.co \
    -l "mirrord-branch-id=$DB_ID" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

require() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1"; exit 1; }; }
for dep in kubectl jq gum cockroach "$MIRRORD_BIN"; do require "$dep"; done

if ! kubectl -n "$NAMESPACE" get pod "$TARGET_POD" >/dev/null 2>&1; then
  bad "target pod $TARGET_POD not found in $NAMESPACE"
  info "run: task cockroachdb-tls:deploy"
  exit 1
fi

say "INT-275: value_pattern connection params must produce a portforward"
info "mirrord binary: $($MIRRORD_BIN --version 2>/dev/null || echo "$MIRRORD_BIN")"
info "target: $TARGET_POD in $NAMESPACE (DATABASE_URL is the source connection)"

# The reporter's shape: one URL-valued env var, host/port/database carved out with regex.
# The operator rewrites exactly those spans to the branch pod address; the CLI must read
# them back through the same patterns.
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
        "name": "pattern_branch",
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

# A tiny long-lived process is enough of an "app": the branch and its portforward are set up
# by the mirrord session itself, independent of what the local process does.
say "starting mirrord session (creates the branch + portforward)..."
"$MIRRORD_BIN" exec -f "$CONFIG" -- sh -c 'sleep 600' >"$SESSION_LOG" 2>&1 &
SESSION_PID=$!
# Drop it from the job table so its termination on cleanup does not print a stray
# "Terminated" line over the test summary.
disown "$SESSION_PID" 2>/dev/null || true

# Wait for the branch pod to go Ready (data copy finished) - up to the config's timeout.
say "waiting for the branch to come up..."
phase=""
for _ in $(seq 1 120); do
  phase="$(kubectl -n "$NAMESPACE" get branchdatabases.dbs.mirrord.metalbear.co \
    -o jsonpath='{.items[?(@.spec.cockroachdbOptions)].status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Ready" ]] && break
  kill -0 "$SESSION_PID" 2>/dev/null || { bad "mirrord session exited early"; cat "$SESSION_LOG"; exit 1; }
  sleep 2
done
[[ "$phase" == "Ready" ]] || { bad "branch never became Ready (phase=$phase)"; cat "$SESSION_LOG"; exit 1; }
ok "branch is Ready"

# --- assertion 1: the branch appears in `connections` ---
# The CLI writes the portforward session file during session setup, which finishes shortly
# after the branch turns Ready - poll the actual `connections` output (JSON form, so the
# check is exact) rather than racing the CRD phase. A branch that never appears within the
# window is the INT-275 bug: its pattern params were dropped and the forward was skipped.
say "waiting for the portforward to be registered..."
address=""
for _ in $(seq 1 30); do
  conns="$($MIRRORD_BIN db-branches connections --format json 2>/dev/null || echo '[]')"
  address="$(jq -r --arg id "$DB_ID" '.[] | select(.db_id == $id) | .connection_string' <<<"$conns" | head -1)"
  [[ -n "$address" ]] && break
  kill -0 "$SESSION_PID" 2>/dev/null || { bad "mirrord session exited early"; cat "$SESSION_LOG"; exit 1; }
  sleep 2
done

if [[ -z "$address" ]]; then
  bad "branch '$DB_ID' is NOT listed in db-branches connections"
  info "session file contents:"
  cat ~/.mirrord/db_branch_portforwards/*.json 2>/dev/null | jq . || true
  info "^ empty \"portforwards\" here is the INT-275 bug - the pattern params were dropped."
  exit 1
fi
ok "branch is listed: $DB_ID -> $address"

# --- assertion 2: the forwarded port actually reaches the branch database ---
# Split host:port off the listed address; a bare host:port is expected here since the config
# declares no user/password params.
host="${address%%:*}"
port="${address##*:}"
rows="$(cockroach sql --insecure \
  --url "postgresql://root@${host}:${port}/pattern_branch" \
  --format csv -e "SELECT count(*) FROM events" 2>/dev/null | tail -1 || echo "")"

if [[ "$rows" == "3" ]]; then
  ok "queried the branch through $address: events has $rows rows (source copied)"
else
  bad "could not read the branch through $address (got '$rows', expected 3)"
  exit 1
fi

say "INT-275 fix verified: value_pattern params are forwarded and reachable."
