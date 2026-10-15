#!/usr/bin/env bash
#
# Reproduces a customer setup (INT-707 follow-up): one mirrord session with TWO db branches -
# a CockroachDB branch whose host/port/database are carved out of a single `DATABASE_URL`
# with `value_pattern`, and a Redis branch from a plain URL env var. The report was that only
# redis showed in `mirrord db-branches connections` while the cockroach one was missing.
#
# This stands up a cockroach source, a redis source, and a target pod carrying BOTH
# `DATABASE_URL` and `OUR_REDIS_URL`, runs a session with the customer's branch shapes, and
# checks that BOTH branches appear in `connections` with a forwarded local address.
#
#   task cockroachdb-tls:multi:portforward:test
#   task cockroachdb-tls:multi:portforward:test MIRRORD_BIN=/path/to/mirrord
#
# Needs kubectl, jq, gum, and the mirrord binary. AUTO=1 (or no TTY) runs unattended.

set -euo pipefail

NS="${NS:-crdb-redis-multi}"
MIRRORD_BIN="${MIRRORD_BIN:-${MIRRORD_BINARY:-mirrord}}"
CRDB_IMAGE="${CRDB_IMAGE:-cockroachdb/cockroach:latest-v26.2}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
# The DATABASE_URL shape on the target pod. Override to test other shapes (e.g. drop the
# `root@` to see the credential-requiring patterns stop matching).
DB_URL_SHAPE="${DB_URL_SHAPE:-postgresql://root@cockroachdb-source.${NS}:26257/appdb?sslmode=disable}"
# The operator aborts the whole session if any branch cannot be created, and some operators
# have redis branching disabled - set INCLUDE_REDIS=false to test the cockroach branch alone.
INCLUDE_REDIS="${INCLUDE_REDIS:-true}"

CRDB_ID="our-db-cockroachdb-db"
REDIS_ID="our-redis"
TARGET_POD="app-target"

WORKDIR="$(mktemp -d)"
SESSION_LOG="$WORKDIR/session.log"
CONFIG="$WORKDIR/multi.json"
SESSION_PID=""

say()  { gum style --foreground 212 "$1"; }
ok()   { gum style --foreground 82  "  PASS  $1"; }
bad()  { gum style --foreground 196 "  FAIL  $1"; }
info() { gum style --foreground 245 "  $1"; }

cleanup() {
  [[ -n "$SESSION_PID" ]] && kill "$SESSION_PID" 2>/dev/null || true
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

require() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1"; exit 1; }; }
for dep in kubectl jq gum "$MIRRORD_BIN"; do require "$dep"; done

AUTO="${AUTO:-}"; [[ -t 0 ]] || AUTO=1

say "Multi-branch portforward repro: cockroach (value_pattern) + redis, one session"
info "mirrord: $($MIRRORD_BIN --version 2>/dev/null || echo "$MIRRORD_BIN")"
info "DATABASE_URL on target: $DB_URL_SHAPE"

# ---------- fixtures ----------
say "deploying cockroach source, redis source, and the target pod..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: cockroachdb-source, labels: { app: cockroachdb-source } }
spec:
  replicas: 1
  selector: { matchLabels: { app: cockroachdb-source } }
  template:
    metadata: { labels: { app: cockroachdb-source } }
    spec:
      containers:
        - name: cockroach
          image: ${CRDB_IMAGE}
          args: ["start-single-node", "--insecure", "--store=type=mem,size=1GiB"]
          ports: [{ containerPort: 26257 }, { containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata: { name: cockroachdb-source }
spec:
  selector: { app: cockroachdb-source }
  ports: [{ name: sql, port: 26257 }, { name: http, port: 8080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: redis-source, labels: { app: redis-source } }
spec:
  replicas: 1
  selector: { matchLabels: { app: redis-source } }
  template:
    metadata: { labels: { app: redis-source } }
    spec:
      containers:
        - name: redis
          image: ${REDIS_IMAGE}
          ports: [{ containerPort: 6379 }]
---
apiVersion: v1
kind: Service
metadata: { name: redis-source }
spec:
  selector: { app: redis-source }
  ports: [{ port: 6379 }]
---
apiVersion: v1
kind: Pod
metadata: { name: ${TARGET_POD}, labels: { app: ${TARGET_POD} } }
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sleep 100000"]
      env:
        - { name: DATABASE_URL,  value: "${DB_URL_SHAPE}" }
        - { name: OUR_REDIS_URL, value: "redis://redis-source.${NS}:6379" }
EOF

kubectl -n "$NS" rollout status deploy/cockroachdb-source --timeout=180s >/dev/null
kubectl -n "$NS" rollout status deploy/redis-source --timeout=120s >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/"$TARGET_POD" --timeout=120s >/dev/null

# start-single-node accepts SQL a few seconds after the pod is Running - wait for it.
info "waiting for cockroach SQL to accept connections..."
for _ in $(seq 1 60); do
  kubectl -n "$NS" exec deploy/cockroachdb-source -- cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 && break
  sleep 2
done

# Seed the source: a db + table + the branch admin user the customer's `user` param names.
kubectl -n "$NS" exec deploy/cockroachdb-source -- cockroach sql --insecure -e \
  "CREATE DATABASE IF NOT EXISTS appdb;
   CREATE TABLE IF NOT EXISTS appdb.public.items (id INT8 PRIMARY KEY, name STRING);
   UPSERT INTO appdb.public.items VALUES (1,'a'),(2,'b'),(3,'c');
   CREATE USER IF NOT EXISTS \"mirrord-branching\";
   GRANT admin TO \"mirrord-branching\";" >/dev/null
ok "fixtures ready (cockroach + redis sources, target pod with both env vars)"

# ---------- config: the customer's exact branch shapes ----------
redis_branch=""
if [[ "$INCLUDE_REDIS" == "true" ]]; then
  redis_branch=$(cat <<EOF
,
      {
        "id": "${REDIS_ID}",
        "type": "redis",
        "ttl_secs": 900,
        "connection": { "url": { "type": "env", "variable": "OUR_REDIS_URL" } }
      }
EOF
)
fi

cat > "$CONFIG" <<EOF
{
  "operator": true,
  "target": { "path": { "pod": "${TARGET_POD}" }, "namespace": "${NS}" },
  "feature": {
    "env": true,
    "fs": "local",
    "network": { "incoming": "off", "outgoing": true },
    "db_branches": [
      {
        "id": "${CRDB_ID}",
        "type": "cockroachdb",
        "version": "latest-v26.2",
        "name": "appdb",
        "connection": {
          "params": {
            "host":     { "env_var_name": "DATABASE_URL", "value_pattern": "^[a-zA-Z]+://[^@]*@(?P<host>[^:/]+)" },
            "port":     { "env_var_name": "DATABASE_URL", "value_pattern": "^[a-zA-Z]+://[^@]*@[^:/]+:(?P<port>\\\\d+)" },
            "database": { "env_var_name": "DATABASE_URL", "value_pattern": "^[a-zA-Z]+://[^@]*@[^:/]+:\\\\d+/(?P<database>[^?]+)" },
            "user":     { "env_var_name": "MIRRORD_BRANCH_DB_USER", "value": "mirrord-branching" }
          }
        },
        "copy": { "mode": "schema" },
        "creation_timeout_secs": 600,
        "ttl_secs": 900
      }${redis_branch}
    ]
  }
}
EOF

# ---------- run the session ----------
say "starting mirrord session (creates both branches + portforwards)..."
"$MIRRORD_BIN" exec -f "$CONFIG" -- sh -c 'sleep 600' >"$SESSION_LOG" 2>&1 &
SESSION_PID=$!
disown "$SESSION_PID" 2>/dev/null || true

# Report a branch's fate: forwarded (address), or why not (CRD failure reason, or created but
# not in the connections file). Keeps environment failures (feature disabled, flaky node)
# distinct from the thing under test - the value_pattern forward being absent.
branch_state() {
  local id="$1" opts_field="$2" conns="$3"
  local addr phase err
  addr="$(jq -r --arg id "$id" '.[]|select(.db_id==$id)|.connection_string' <<<"$conns" | head -1)"
  if [[ -n "$addr" ]]; then echo "forwarded|$addr"; return; fi
  phase="$(kubectl -n "$NS" get branchdatabases -o jsonpath="{.items[?(@.spec.$opts_field)].status.phase}" 2>/dev/null || true)"
  err="$(kubectl -n "$NS" get branchdatabases -o jsonpath="{.items[?(@.spec.$opts_field)].status.error}" 2>/dev/null || true)"
  echo "missing|phase=${phase:-none}${err:+ error=$err}"
}

say "waiting for the branches to forward (up to ~6m)..."
crdb_addr=""; redis_addr=""
for _ in $(seq 1 120); do
  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    bad "mirrord session exited early"; sed -n '1,40p' "$SESSION_LOG"; exit 1
  fi
  conns="$($MIRRORD_BIN db-branches connections --format json 2>/dev/null || echo '[]')"
  crdb_addr="$(jq -r --arg id "$CRDB_ID"  '.[]|select(.db_id==$id)|.connection_string' <<<"$conns" | head -1)"
  redis_addr="$(jq -r --arg id "$REDIS_ID" '.[]|select(.db_id==$id)|.connection_string' <<<"$conns" | head -1)"
  # Stop early if cockroach forwarded, or if its branch already failed (no point waiting).
  [[ -n "$crdb_addr" ]] && break
  cphase="$(kubectl -n "$NS" get branchdatabases -o jsonpath='{.items[?(@.spec.cockroachdbOptions)].status.phase}' 2>/dev/null || true)"
  [[ "$cphase" == "Failed" ]] && break
  sleep 3
done

conns="$($MIRRORD_BIN db-branches connections --format json 2>/dev/null || echo '[]')"
echo
say "branch CRDs:"; kubectl -n "$NS" get branchdatabases 2>/dev/null || true
echo
say "db-branches connections:"; $MIRRORD_BIN db-branches connections 2>/dev/null || true
echo

# ---------- verdict ----------
# The branch under test is cockroach (value_pattern). Redis is a secondary control and may be
# disabled on some operators, so it does not fail the run on its own.
crdb_state="$(branch_state "$CRDB_ID" cockroachdbOptions "$conns")"
redis_state="$(branch_state "$REDIS_ID" redisOptions "$conns")"

case "$redis_state" in
  forwarded\|*) ok "redis branch forwarded: ${redis_state#*|}" ;;
  *"Redis branching is disabled"*) info "redis branch skipped: disabled on this operator (control only, ignored)" ;;
  *) info "redis branch not forwarded: ${redis_state#*|} (control only, ignored)" ;;
esac

rc=0
case "$crdb_state" in
  forwarded\|*)
    ok "cockroach (value_pattern) branch forwarded: ${crdb_state#*|}"
    say "RESULT: the value_pattern branch forwards - the fix works for this DATABASE_URL shape."
    ;;
  *phase=Ready*)
    bad "cockroach branch is Ready but has NO forward  <-- real portforward bug, not env"
    info "intproxy log:"; grep -i "pattern\|portforward" "$SESSION_LOG" 2>/dev/null | tail -5 || true
    rc=1
    ;;
  *)
    bad "cockroach branch never became Ready: ${crdb_state#*|}"
    info "This is a branch-CREATION failure (source auth, schema copy, node startup), NOT the"
    info "portforward. The pod's cockroachdb-branch-init env shows MIRRORD_EXTRACTED_HOST/PORT/"
    info "DATABASE - if those are correct, the value_pattern extraction worked."
    rc=1
    ;;
esac
exit $rc
