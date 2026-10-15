#!/usr/bin/env bash
# Times how long the operator's startup telemetry event takes to leave the process, with and
# without the immediate startup flush in operator-telemetry's event sender.
#
# Each case runs `task operator:dev` against a small HTTP sink on this machine that stands in
# for the analytics server. The analytics URL is compiled into the operator, so the sink address
# is passed as OPERATOR_EVENTS_SERVER at build time, and a copy of the dev mirrord config keeps
# that one connection local and sets the flush interval. The delay is the gap between the
# operator's "mirrord operator version" log line and the sink's first POST.
#
# The fix must be an uncommitted diff in ../operator: "old" checks the file out of HEAD, "new"
# applies the diff back. The diff is restored on exit no matter what.
#
#   FLUSH_SECS=60 CASES="old new" scripts/telemetry-startup-flush.sh
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OPERATOR_DIR=${OPERATOR_DIR:-$ROOT_DIR/../operator}
FLUSH_SECS=${FLUSH_SECS:-60}
SINK_PORT=${SINK_PORT:-9911}
CASES=${CASES:-old new}
FIX_FILE=crates/operator-telemetry/src/event_sender.rs
WORK=$(mktemp -d /tmp/telemetry-startup-flush.XXXXXX)

for tool in gum task python3 ruby kubectl; do
  command -v "$tool" >/dev/null || { echo "missing $tool"; exit 1; }
done

# gum spin needs a terminal; without one the command runs plainly so logs still make sense.
spin() {
  local title=$1; shift
  if [ -t 1 ]; then gum spin --title "$title" -- "$@"; else echo "$title"; "$@"; fi
}

gum style --border rounded --padding "0 1" --margin "1 0" \
  "Operator startup event: old vs new" \
  "flush interval ${FLUSH_SECS}s, sink 127.0.0.1:${SINK_PORT}, cases: ${CASES}" \
  "work dir $WORK"

PATCH=$WORK/fix.patch
(cd "$OPERATOR_DIR" && git diff -- "$FIX_FILE") > "$PATCH"
if [ ! -s "$PATCH" ]; then
  gum log --level error "no uncommitted change in $OPERATOR_DIR/$FIX_FILE; the old case needs the fix as a working-tree diff"
  exit 1
fi

restore_fix() { (cd "$OPERATOR_DIR" && git checkout -q -- "$FIX_FILE" && git apply "$PATCH"); }
stop_all() {
  pkill -f "target/debug/operator-service" 2>/dev/null || true
  pkill -f "$WORK/sink.py" 2>/dev/null || true
}
trap 'stop_all; restore_fix; gum log --level info "fix restored in $FIX_FILE"' EXIT

cat > "$WORK/sink.py" <<'PY'
import datetime, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")

class Sink(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        try:
            events = [r.get("event", {}).get("type", "?") for r in json.loads(body)]
        except Exception:
            events = ["<unparsed>"]
        print(now(), "POST", self.path, events, flush=True)
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"rejected":[]}')

    def log_message(self, *args):
        pass

print(now(), "sink listening", flush=True)
HTTPServer(("127.0.0.1", int(sys.argv[1])), Sink).serve_forever()
PY

ruby -ryaml -e '
cfg = YAML.load_file(ARGV[0])
cfg["feature"]["network"]["outgoing"] = {"filter" => {"local" => ["127.0.0.1:#{ARGV[2]}"]}}
cfg["feature"]["env"]["override"]["OPERATOR_TELEMETRY_ENABLED"] = "true"
cfg["feature"]["env"]["override"]["OPERATOR_TELEMETRY_FLUSH_INTERVAL_SECS"] = ARGV[3]
File.write(ARGV[1], cfg.to_yaml)
' "$ROOT_DIR/.mirrord/operator-dev.yaml" "$WORK/config.yaml" "$SINK_PORT" "$FLUSH_SECS"

RESULTS=$WORK/results.csv
echo "case,operator started (UTC),first flush at sink (UTC),delay" > "$RESULTS"

run_case() {
  local label=$1
  local oplog=$WORK/operator-$label.log sinklog=$WORK/sink-$label.log
  stop_all; sleep 2

  python3 "$WORK/sink.py" "$SINK_PORT" > "$sinklog" 2>&1 &
  disown
  (cd "$ROOT_DIR" && OPERATOR_EVENTS_SERVER="http://127.0.0.1:$SINK_PORT" SANDBOX_LICENSE=1 \
    OPERATOR_LICENSE_ISSUER_PUBLIC_KEY="$(cat "$ROOT_DIR/scripts/license-issuer.pem")" \
    task operator:dev CONFIG="$WORK/config.yaml" > "$oplog" 2>&1) &
  local task_pid=$!
  # Disowned so the shell stays quiet about the job when it is killed at the end of the case.
  disown
  gum log --level info "[$label] operator log: $oplog"

  spin "[$label] building and starting the local operator" \
    bash -c "until grep -q 'mirrord operator version' '$oplog' || ! kill -0 $task_pid 2>/dev/null; do sleep 1; done"
  if ! grep -q 'mirrord operator version' "$oplog"; then
    gum log --level error "[$label] operator:dev did not start"
    tail -n 20 "$oplog"
    return 1
  fi

  local limit=$((FLUSH_SECS + 30))
  spin "[$label] waiting up to ${limit}s for the first flush at the sink" \
    bash -c "for i in \$(seq 1 $limit); do grep -q 'POST /api/v1/events' '$sinklog' && exit 0; sleep 1; done; exit 0"

  python3 - "$label" "$oplog" "$sinklog" >> "$RESULTS" <<'PY'
import datetime, json, sys
label, oplog, sinklog = sys.argv[1:]
start = flush = None
for line in open(oplog):
    if "mirrord operator version" in line:
        try:
            start = json.loads(line)["timestamp"]
        except Exception:
            pass
        break
for line in open(sinklog):
    if "POST /api/v1/events" in line:
        flush = line.split()[0]
        break
def parse(ts):
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
delay = f"{(parse(flush) - parse(start)).total_seconds():.1f}s" if start and flush else "not within the wait window"
print(f"{label},{start or '?'},{flush or 'never'},{delay}")
PY
  gum log --level info "[$label] $(tail -n 1 "$RESULTS")"

  kill "$task_pid" 2>/dev/null || true
  stop_all
  wait "$task_pid" 2>/dev/null || true
}

for label in $CASES; do
  case $label in
    old) (cd "$OPERATOR_DIR" && git checkout -q -- "$FIX_FILE"); gum log --level info "old: fix reverted from the working tree" ;;
    new) restore_fix; gum log --level info "new: fix applied" ;;
    *) gum log --level error "unknown case $label"; exit 1 ;;
  esac
  run_case "$label" || true
done

gum style --bold --margin "1 0" "Result"
gum table --print < "$RESULTS"
