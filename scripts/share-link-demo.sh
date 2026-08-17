#!/usr/bin/env bash
# Interactive demo of the agent's share link handling (INT-549).
#
# Walks through every share link flow against the real cluster, pausing between
# phases so you can also open the URLs in a browser and watch the behavior:
#   A. dead key   - session-ended countdown page, cookie expiry
#   B. live key   - request joins the local steal session, join cookie
#   C. key death  - the "operator" dies, viewers fall back to the ended page
#
# The operator half of the feature does not exist yet, so a tiny stand-in
# client (built on the fly from the local mirrord checkout) registers the key
# with the agent over ClientMessage::ShareLink - exactly what the operator
# will do.
#
# Prerequisites:
#   - minikube cluster running (task cluster:create)
#   - locally built agent image loaded (task mirrord:agent:build)
#   - locally built mirrord CLI (task mirrord:cli:build), or MIRRORD_BIN=...
#
# Usage: scripts/share-link-demo.sh [key]   (default key: sharekey)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIRRORD_DIR="${MIRRORD_DIR:-$ROOT/../mirrord}"
MIRRORD_BIN="${MIRRORD_BIN:-$MIRRORD_DIR/target/aarch64-apple-darwin/debug/mirrord}"
CLUSTER_NAME="${CLUSTER_NAME:-bearkube}"
KEY="${1:-sharekey}"
NS="share-link-demo"
ECHO_PORT=8090
WORKDIR="${TMPDIR:-/tmp}/share-link-demo"
BASE_URL="http://127.0.0.1:$ECHO_PORT"
SHARE_LINK="$BASE_URL/products?mirrord-session=$KEY&page=2"

PIDS=()
REGISTRAR_PID=""

say()    { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
note()   { printf '\033[0;33m%s\033[0m\n' "$*"; }
expect() { printf '\033[0;32m    you should see: %s\033[0m\n' "$*"; }
pause()  { printf '\n'; read -r -p "--- press Enter to continue ---"; }

hit() {
  # hit <description> [curl args...] <url>
  local desc="$1"; shift
  printf '\n\033[1m$ curl -i %s\033[0m   # %s\n' "$*" "$desc"
  curl -s -i --max-time 15 "$@" | sed -e 's/^/    /' -e 's/\r$//' | head -40
}

cleanup() {
  say "cleaning up"
  [ -n "$REGISTRAR_PID" ] && kill "$REGISTRAR_PID" 2>/dev/null || true
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  read -r -p "delete the '$NS' namespace? [y/N] " answer || true
  case "${answer:-n}" in
    y|Y) kubectl delete namespace "$NS" --wait=false ;;
    *)   note "namespace '$NS' kept" ;;
  esac
}
trap cleanup EXIT

say "preflight"
[ -x "$MIRRORD_BIN" ] || { echo "mirrord binary missing at $MIRRORD_BIN (task mirrord:cli:build, or set MIRRORD_BIN)"; exit 1; }
minikube -p "$CLUSTER_NAME" image ls 2>/dev/null | grep -q "library/test:" \
  || { echo "agent image 'test' not in minikube - run: task mirrord:agent:build"; exit 1; }
kubectl version --request-timeout=5s >/dev/null || { echo "cluster unreachable"; exit 1; }
mkdir -p "$WORKDIR"
note "mirrord: $MIRRORD_BIN"
note "workdir: $WORKDIR (logs live here)"

say "deploying the echo app (reflects the request back, so rewrites are visible)"
# A rerun right after answering 'y' to the cleanup prompt races the namespace
# deletion; nothing can be created in a terminating namespace, so wait it out.
if kubectl get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; then
  note "namespace '$NS' is still terminating from the previous run, waiting..."
  kubectl wait --for=delete "namespace/$NS" --timeout=120s \
    || { echo "namespace '$NS' is stuck terminating - is an APIService unavailable? (kubectl get apiservices)"; exit 1; }
fi
kubectl apply -f - <<APP
apiVersion: v1
kind: Namespace
metadata: { name: $NS }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: echo, namespace: $NS }
spec:
  replicas: 1
  selector: { matchLabels: { app: echo } }
  template:
    metadata: { labels: { app: echo } }
    spec:
      containers:
      - name: echo
        image: ealen/echo-server:latest
        ports: [ { containerPort: 80 } ]
---
apiVersion: v1
kind: Service
metadata: { name: echo, namespace: $NS }
spec:
  selector: { app: echo }
  ports: [ { port: 80, targetPort: 80 } ]
APP
kubectl -n "$NS" rollout status deployment/echo --timeout=180s

say "building the operator stand-in (registers the key over ClientMessage::ShareLink)"
mkdir -p "$WORKDIR/registrar/src"
cat > "$WORKDIR/registrar/Cargo.toml" <<TOML
[package]
name = "share-link-registrar"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "macros", "net", "time"] }
mirrord-protocol = { path = "$MIRRORD_DIR/mirrord/protocol" }
mirrord-protocol-io = { path = "$MIRRORD_DIR/mirrord/protocol-io" }
TOML
cat > "$WORKDIR/registrar/src/main.rs" <<'RS'
use mirrord_protocol::{ClientMessage, share_link::ShareLinkRequest};
use mirrord_protocol_io::{Client, Connection};
use tokio::{net::TcpStream, time::Duration};

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let addr = args.next().expect("usage: share-link-registrar <addr> <key>");
    let key = args.next().expect("usage: share-link-registrar <addr> <key>");

    let stream = TcpStream::connect(&addr).await.expect("connect failed");
    let mut conn = Connection::<Client>::from_stream(stream);

    conn.send(ClientMessage::SwitchProtocolVersion(
        mirrord_protocol::VERSION.clone(),
    ))
    .await;
    conn.send(ClientMessage::ShareLink(ShareLinkRequest::RegisterKey(
        key.clone(),
    )))
    .await;
    eprintln!("registered {key:?}; holding the connection - killing me releases the key");

    let mut ping = tokio::time::interval(Duration::from_secs(15));
    loop {
        tokio::select! {
            _ = ping.tick() => conn.send(ClientMessage::Ping).await,
            msg = conn.recv() => match msg {
                Some(msg) => eprintln!("agent: {msg:?}"),
                None => return eprintln!("agent closed the connection"),
            },
        }
    }
}
RS
(cd "$WORKDIR/registrar" && cargo build --quiet)

say "starting the steal session (filter: baggage contains mirrord-session=$KEY)"
cat > "$WORKDIR/local_server.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(
            {"answered_by": "YOUR LAPTOP", "path": self.path, "headers": dict(self.headers)},
            indent=2,
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("LOCAL SERVER got:", fmt % args, flush=True)


HTTPServer(("0.0.0.0", 80), Handler).serve_forever()
PY
cat > "$WORKDIR/mirrord.json" <<CFG
{
  "target": { "path": "deployment/echo", "namespace": "$NS" },
  "operator": false,
  "agent": { "image": "test", "image_pull_policy": "Never" },
  "feature": {
    "network": {
      "incoming": {
        "mode": "steal",
        "http_filter": { "header_filter": "baggage: .*mirrord-session=$KEY.*" }
      }
    },
    "fs": "local",
    "env": false
  }
}
CFG
"$MIRRORD_BIN" exec -f "$WORKDIR/mirrord.json" -- python3 "$WORKDIR/local_server.py" \
  > "$WORKDIR/session.log" 2>&1 &
PIDS+=($!)

# Newest running agent pod as "namespace name". Resolved again wherever it is used:
# stale agents from earlier runs linger for a bit, so a name cached early can be gone
# (or the wrong pod) by the time it is needed.
find_agent_pod() {
  kubectl get pods -A --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null \
    | awk '$2 ~ /^mirrord-agent/ && $4 == "Running" { print $1, $2 }' | tail -1
}

note "waiting for the agent pod..."
line=""
for _ in $(seq 1 60); do
  line="$(find_agent_pod)"
  [ -n "$line" ] && break
  sleep 2
done
[ -n "$line" ] || { echo "no agent pod appeared; see $WORKDIR/session.log"; exit 1; }
note "agent: $line"

kubectl -n "$NS" port-forward svc/echo "$ECHO_PORT:80" >/dev/null 2>&1 &
PIDS+=($!)

# The agent only starts redirecting once the steal subscription is in; probe with a key
# nobody will ever register until the session-ended page proves our codepath is live.
note "waiting for the steal session to become active..."
for _ in $(seq 1 45); do
  if curl -s --max-time 5 "$BASE_URL/?mirrord-session=__probe__" 2>/dev/null | grep -q "Session ended"; then
    break
  fi
  sleep 2
done
curl -s --max-time 5 "$BASE_URL/?mirrord-session=__probe__" | grep -q "Session ended" \
  || { echo "steal session never became active; see $WORKDIR/session.log"; exit 1; }

say "PHASE A - the key is NOT registered (no live session for it)"
hit "no key at all: passes through to the cluster app untouched" "$BASE_URL/products?page=2"
expect "the echo pod's JSON (its env vars, HOSTNAME=echo-...), NOT 'YOUR LAPTOP'"
expect "no Set-Cookie header, no baggage header in the echoed request"

hit "share link with a dead key: the session-ended countdown page" "$SHARE_LINK"
expect "HTTP 200 with an HTML body saying the session ended and a countdown"
expect "after 5s it continues to /products?page=2 - the key is stripped"

hit "stale cookie: passes through, and the response expires the cookie" \
  -H "Cookie: mirrord-session=$KEY" "$BASE_URL/products"
expect "the echo pod answers normally (no interstitial for cookies)"
expect "Set-Cookie: mirrord-session=; ...; Max-Age=0 - the browser drops the dead cookie"
note ""
note ">>> open this in your browser to SEE the countdown page tick down and continue:"
note ">>>   $SHARE_LINK"
pause

say "PHASE B - registering '$KEY' with the agent, like the operator will"
line="$(find_agent_pod)"
[ -n "$line" ] || { echo "the agent pod is gone - did the steal session die? see $WORKDIR/session.log"; exit 1; }
AGENT_NS="${line%% *}"; AGENT_POD="${line##* }"
note "agent: $AGENT_NS/$AGENT_POD"
AGENT_PORT="$(kubectl -n "$AGENT_NS" get pod "$AGENT_POD" -o jsonpath='{.spec.containers[0].args[1]}')"
kubectl -n "$AGENT_NS" port-forward "pod/$AGENT_POD" "$AGENT_PORT:$AGENT_PORT" >/dev/null 2>&1 &
PIDS+=($!)
sleep 3
"$WORKDIR/registrar/target/debug/share-link-registrar" "127.0.0.1:$AGENT_PORT" "$KEY" \
  > "$WORKDIR/registrar.log" 2>&1 &
REGISTRAR_PID=$!
sleep 3
grep registered "$WORKDIR/registrar.log" || { echo "registrar failed; see $WORKDIR/registrar.log"; exit 1; }

hit "share link with the LIVE key: stolen to your laptop, join cookie set" "$SHARE_LINK"
expect "\"answered_by\": \"YOUR LAPTOP\" - the request was stolen to the local server"
expect "\"path\": \"/products?page=2\" - the mirrord-session param is gone from the URL"
expect "a \"baggage\": \"mirrord-session=$KEY\" entry in the echoed headers"
expect "Set-Cookie: mirrord-session=$KEY; Path=/; HttpOnly; SameSite=Lax (no Max-Age)"

hit "cookie only (the browser after the first click): still your laptop" \
  -H "Cookie: mirrord-session=$KEY" "$BASE_URL/cart"
expect "YOUR LAPTOP again, baggage added - the cookie alone keeps the viewer in"
expect "no Set-Cookie this time: the cookie is already in place, nothing to rewrite"
note ""
note ">>> in the browser: open the share link again - YOUR LAPTOP answers, the param"
note ">>> is gone from what the app sees, and plain URLs keep hitting you (cookie)."
note ">>>   $SHARE_LINK"
pause

say "PHASE C - the 'operator' dies, the key dies with its connection"
kill "$REGISTRAR_PID"; REGISTRAR_PID=""
sleep 2
hit "same share link: back to the session-ended page" "$SHARE_LINK"
expect "the HTML countdown page again - the registrar's death released the key"

hit "the now-dead cookie: passed through, expired on the way out" \
  -H "Cookie: mirrord-session=$KEY" "$BASE_URL/products"
expect "the echo pod answers (not YOUR LAPTOP - the steal filter no longer matches)"
expect "Set-Cookie: mirrord-session=; ...; Max-Age=0 - the viewer's browser forgets the session"
note ""
note ">>> reload the browser tab: countdown page again, then it lands on the plain app."
pause

say "done - the trap will now stop the session and port-forwards"
