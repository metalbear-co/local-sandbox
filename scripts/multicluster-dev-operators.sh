#!/usr/bin/env bash
# Runs YOUR operator (../operator, current branch) on every multicluster
# cluster as background `task multicluster:operator:<cluster>` steals, with one
# log file per cluster, so a test run never needs a terminal per operator.
#
#   start   - start the missing ones (idempotent), wait until each serves its
#             cluster's operator API, print the log paths
#   stop    - stop them all (the deployed pods stay patched to a sleeper;
#             `task multicluster:operator:use` restores a released operator)
#   status  - which cluster is served by a dev operator, with pid + log
#   logs    - tail -f every log (Ctrl-C to stop tailing, operators keep running)
#
# Logs: $MC_DEV_LOG_DIR (default /tmp/mc-operator-dev)/<cluster>.log
# Env: MC_NUM_CLUSTERS=2|3, MC_PRIMARY / MC_REMOTE_1 / MC_REMOTE_2,
#      START_TIMEOUT=900 seconds per operator (the first one also cargo-builds)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MC="${MC_NUM_CLUSTERS:-2}"
export MC_NUM_CLUSTERS="$MC"
PRIMARY="${MC_PRIMARY:-mirrord-primary}"
REMOTE1="${MC_REMOTE_1:-mirrord-remote-1}"
REMOTE2="${MC_REMOTE_2:-mirrord-remote-2}"
if [ "$MC" = "3" ]; then ALL_CTXS="$PRIMARY $REMOTE1 $REMOTE2"; else ALL_CTXS="$PRIMARY $REMOTE1"; fi
LOG_DIR="${MC_DEV_LOG_DIR:-/tmp/mc-operator-dev}"
START_TIMEOUT="${START_TIMEOUT:-900}"
mkdir -p "$LOG_DIR"

HAVE_GUM=0; command -v gum >/dev/null 2>&1 && HAVE_GUM=1; [ -t 1 ] || HAVE_GUM=0
info() { if [ "$HAVE_GUM" = 1 ]; then gum log --level info "$*"; else printf '  %s\n' "$*"; fi; }
warn() { if [ "$HAVE_GUM" = 1 ]; then gum log --level warn "$*"; else printf '  \033[33mWARN\033[0m %s\n' "$*"; fi; }
fail() { if [ "$HAVE_GUM" = 1 ]; then gum log --level error "$*"; else printf '  \033[31mFAIL\033[0m %s\n' "$*"; fi; }
ok()   { if [ "$HAVE_GUM" = 1 ]; then gum log --level info "OK   $*"; else printf '  \033[32mOK\033[0m   %s\n' "$*"; fi; }

# The task name is the context without the shared "mirrord-" prefix.
task_for() { echo "multicluster:operator:${1#mirrord-}"; }
pid_file() { echo "$LOG_DIR/$1.pid"; }
log_file() { echo "$LOG_DIR/$1.log"; }

# A dev operator for CTX is alive when the task we started still runs.
alive() { local pid; pid=$(cat "$(pid_file "$1")" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
# operator:dev swaps the deployed pod for a sleeper and the local process takes
# over its API. "serving" = sleeper in place AND our process group (the task was
# started as its own group, so pgid = pid) runs operator-service AND the API
# answers. The process check matters: the released pod keeps answering for a
# while after the patch, which would otherwise pass during the cargo build.
dev_patched() { kubectl --context "$1" get deploy mirrord-operator -n mirrord -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -q busybox; }
api_answers() { kubectl --context "$1" --request-timeout=10s get mirrordoperators operator >/dev/null 2>&1; }
process_up() { local pid; pid=$(cat "$(pid_file "$1")" 2>/dev/null) && [ -n "$pid" ] && pgrep -g "$pid" -f 'target/debug/operator-service' >/dev/null 2>&1; }
serving() { alive "$1" && process_up "$1" && dev_patched "$1" && api_answers "$1"; }

start_one() {
  local ctx="$1" log pidf
  log=$(log_file "$ctx"); pidf=$(pid_file "$ctx")
  if serving "$ctx"; then ok "$ctx already served by a dev operator (pid $(cat "$pidf"), log $log)"; return 0; fi
  if alive "$ctx"; then
    info "$ctx: dev operator starting (pid $(cat "$pidf")), waiting for it"
  else
    : > "$log"
    # Own session and process group (pgid = pid), so `stop` can take down task + mirrord +
    # operator-service together, and a hangup or timeout of the shell that started them
    # (a backgrounded command, a closed terminal) never reaches them.
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- task -d "$SANDBOX_DIR" "$(task_for "$ctx")" < /dev/null >> "$log" 2>&1 &
    echo $! > "$pidf"
    info "$ctx: started $(task_for "$ctx") (pid $!) -> $log"
  fi
  local waited=0
  until serving "$ctx" || ! alive "$ctx" || [ "$waited" -ge "$START_TIMEOUT" ]; do
    sleep 5; waited=$((waited + 5))
  done
  if serving "$ctx"; then ok "$ctx served by your operator after ${waited}s"; return 0; fi
  if ! alive "$ctx"; then fail "$ctx: the dev operator exited, last lines of $log:"; tail -15 "$log" | sed 's/^/      /'; return 1; fi
  fail "$ctx: not serving after ${START_TIMEOUT}s, see $log"; return 1
}

stop_one() {
  local ctx="$1" pid
  pid=$(cat "$(pid_file "$ctx")" 2>/dev/null) || { info "$ctx: nothing to stop"; return 0; }
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 2; kill -KILL -- "-$pid" 2>/dev/null || true
    ok "$ctx: stopped (pid $pid)"
  else
    info "$ctx: already stopped"
  fi
  rm -f "$(pid_file "$ctx")"
}

status_one() {
  local ctx="$1" state
  if serving "$ctx"; then state="SERVING   pid $(cat "$(pid_file "$ctx")")"
  elif alive "$ctx"; then state="STARTING  pid $(cat "$(pid_file "$ctx")")"
  elif dev_patched "$ctx"; then state="DEAD      (pod is the sleeper but no dev operator runs - start again)"
  else state="DEPLOYED  (released operator, no dev steal)"; fi
  printf '  %-18s %-60s %s\n' "$ctx" "$state" "$(log_file "$ctx")"
}

CMD="${1:-status}"; shift || true
CTXS="${*:-$ALL_CTXS}"
case "$CMD" in
  start)
    rc=0
    # One after the other: the first cargo build holds the target-dir lock anyway.
    for ctx in $CTXS; do start_one "$ctx" || rc=1; done
    echo
    echo "Operator logs (tail -f them, or: task multicluster:dev:logs):"
    for ctx in $CTXS; do echo "  $(log_file "$ctx")"; done
    exit $rc ;;
  stop)   for ctx in $CTXS; do stop_one "$ctx"; done ;;
  status) for ctx in $CTXS; do status_one "$ctx"; done ;;
  logs)   exec tail -n 30 -f $(for ctx in $CTXS; do log_file "$ctx"; done) ;;
  *) echo "usage: $0 start|stop|status|logs [cluster...]"; exit 2 ;;
esac
