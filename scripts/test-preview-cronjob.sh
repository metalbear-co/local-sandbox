#!/usr/bin/env bash
# E2E for previews of a CronJob target (`mirrord preview start -t cronjob/<name>`).
#
# The preview of a CronJob is an isolated CronJob named after the session, running the preview
# image, with the source's job settings. The operator triggers it once right after creating it
# and it then runs on its schedule. Cases:
#
#   1. inherit    - no `feature.preview.cronjob.schedule`: the preview CronJob carries the
#                   SOURCE schedule and is not suspended even though the source is; the
#                   `<session>-start` Job exists, is marked as a manual trigger, and its pod
#                   ran the PREVIEW image; the source CronJob is untouched
#   2. override   - `schedule: "*/1 * * * *"`: the preview CronJob carries the override, and
#                   within ~90s a SCHEDULED job (named `<session>-<timestamp>`) shows up next
#                   to the trigger job
#   3. stop       - `preview stop` removes the session, its CronJob, and its jobs
#   4. invalid    - a malformed schedule ("* * *") is rejected by the CLI before anything is
#                   created
#   5. idle       - `feature.preview.idle` with a cronjob target is rejected by the CLI
#   6. no-trigger - `trigger_on_start: false`: the session is Ready with the preview CronJob
#                   but no `<session>-start` Job exists
#
# Prereqs:
#   - sandbox cluster up, operator with previewEnv (operator:dev from the feature branch, or
#     a deployed operator that advertises CronJob preview targets)
#   - `task`, `kubectl`, python3; mirrord CLI from the branch (MIRRORD_BIN or .env)
#
# Usage:
#   ./scripts/test-preview-cronjob.sh
#   SKIP_DEPLOY=1 ./scripts/test-preview-cronjob.sh   # target already deployed
#   ONLY=1,3 ./scripts/test-preview-cronjob.sh        # run a subset
#
# Env knobs:
#   NS            namespace (default test-mirrord)
#   CRONJOB       source CronJob name (default echo-cron, deployed by preview:cronjob:deploy)
#   PREVIEW_IMAGE image for the preview (default echo-app:latest)
#   SCHEDULE_WAIT seconds to wait for a scheduled run in case 2 (default 100)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NS:-test-mirrord}"
CRONJOB="${CRONJOB:-echo-cron}"
PREVIEW_IMAGE="${PREVIEW_IMAGE:-echo-app:latest}"
SCHEDULE_WAIT="${SCHEDULE_WAIT:-100}"
KEY_INHERIT="cron-inherit"
KEY_OVERRIDE="cron-override"
KEY_INVALID="cron-invalid"
KEY_IDLE="cron-idle"
KEY_NOTRIGGER="cron-notrigger"
CONFIG_DIR="$(mktemp -d /tmp/mirrord-preview-cronjob.XXXXXX)" || { echo "mktemp failed"; exit 1; }
FAILURES=0
ONLY="${ONLY:-1,2,3,4,5,6}"

if [ -z "${MIRRORD_BIN:-}" ] && [ -f "$ROOT/.env" ]; then
  MIRRORD_BIN=$(grep -E '^MIRRORD_BIN=' "$ROOT/.env" | tail -1 | cut -d= -f2-)
fi
MIRRORD_BIN="${MIRRORD_BIN:-$(command -v mirrord || true)}"
if [ -z "$MIRRORD_BIN" ] || [ ! -x "$MIRRORD_BIN" ]; then
  echo "mirrord CLI not found - set MIRRORD_BIN or add it to $ROOT/.env"; exit 1
fi

if command -v gum >/dev/null 2>&1; then
  say()  { echo; gum style --bold --foreground 212 "==> $*"; }
  ok()   { gum log --level info "PASS $*"; }
  bug()  { gum log --level error "FAIL $*"; FAILURES=$((FAILURES + 1)); }
  info() { gum log --level debug "$*"; }
else
  bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
  say()  { echo; echo "${bold}==> $*${reset}"; }
  ok()   { echo "  PASS $*"; }
  bug()  { echo "  FAIL $*"; FAILURES=$((FAILURES + 1)); }
  info() { echo "     $*"; }
fi
runs() { case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac }

# `preview stop` needs the config for the namespace: without it the CLI looks in the
# kubeconfig's default namespace and reports "no sessions found".
stop_preview() {
  MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview stop -k "$1" \
    -f "$ROOT/apps/echo-app/mirrord-preview-cronjob.json"
}

cleanup() {
  say "Cleaning up sessions"
  local key
  for key in "$KEY_INHERIT" "$KEY_OVERRIDE" "$KEY_INVALID" "$KEY_IDLE" "$KEY_NOTRIGGER"; do
    stop_preview "$key" >/dev/null 2>&1 || true
  done
  rm -rf "$CONFIG_DIR"
}
trap cleanup EXIT

# ------------------------------------------------------------------ helpers

session_of() {
  kubectl get previewsessions -n "$NS" -o json 2>/dev/null | python3 -c '
import json, sys
key = sys.argv[1]
for item in json.load(sys.stdin).get("items", []):
    if item["spec"].get("key") == key:
        print(item["metadata"]["name"]); break
' "$1"
}
phase_of()   { kubectl get previewsession "$1" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null; }
failure_of() { kubectl get previewsession "$1" -n "$NS" -o jsonpath='{.status.failureMessage}' 2>/dev/null; }
cron_field() { kubectl get cronjob "$1" -n "$NS" -o jsonpath="{$2}" 2>/dev/null; }

# Writes a config derived from the sandbox one with the given JSON patch applied
# (python dict merge of `feature.preview`).
write_config() {
  python3 - "$ROOT/apps/echo-app/mirrord-preview-cronjob.json" "$1" "$2" <<'PY'
import json, sys
src, out, patch = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
cfg = json.load(open(src))
preview = cfg["feature"]["preview"]
for k, v in patch.items():
    if v is None:
        preview.pop(k, None)
    else:
        preview[k] = v
json.dump(cfg, open(out, "w"), indent=2)
PY
}

wait_for() { # <seconds> <description> <command...>
  local secs=$1 desc=$2; shift 2
  local end=$((SECONDS + secs))
  while [ $SECONDS -lt $end ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  info "timed out after ${secs}s waiting for: $desc"
  return 1
}

start_preview() { # <key> <config>
  MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview start \
    -f "$2" -i "$PREVIEW_IMAGE" -k "$1" --timeout 300
}

expect_start_failure() { # <key> <config> <expected substring>
  local out
  out=$(MIRRORD_CHECK_VERSION=false "$MIRRORD_BIN" preview start \
    -f "$2" -i "$PREVIEW_IMAGE" -k "$1" --timeout 60 2>&1)
  if echo "$out" | grep -q "$3"; then
    ok "rejected as expected (message mentions '$3')"
  else
    bug "expected a rejection mentioning '$3', got:"; echo "$out" | tail -5
  fi
  if [ -n "$(session_of "$1")" ]; then
    bug "a session was created for key $1 although the config was rejected"
  else
    ok "nothing was created"
  fi
}

# ------------------------------------------------------------------ preflight

say "Checking prerequisites"
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "namespace $NS unreachable"; exit 1; }
kubectl get crd previewsessions.preview.mirrord.metalbear.co >/dev/null 2>&1 \
  || { echo "PreviewSession CRD missing - enable operator.previewEnv"; exit 1; }
kubectl get crd previewsessions.preview.mirrord.metalbear.co -o json \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); v=s["spec"]["versions"][0]; sys.exit(0 if "cronjob" in v["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"] else 1)' \
  || { echo "installed PreviewSession CRD has no spec.cronjob - run: task operator:crds"; exit 1; }

if [ -z "${SKIP_DEPLOY:-}" ]; then
  info "deploying the source CronJob (SKIP_DEPLOY=1 to skip)"
  task -d "$ROOT" preview:cronjob:deploy >/dev/null || { echo "cronjob target deploy failed"; exit 1; }
fi
kubectl get cronjob "$CRONJOB" -n "$NS" >/dev/null 2>&1 \
  || { echo "cronjob $CRONJOB missing - run: task preview:cronjob:deploy"; exit 1; }
SOURCE_SCHEDULE=$(cron_field "$CRONJOB" .spec.schedule)
info "source schedule: $SOURCE_SCHEDULE (suspended: $(cron_field "$CRONJOB" .spec.suspend))"

if [ -z "${OPERATOR_ISOLATION_MARKER:-}" ] && pgrep -qf 'target/debug/operator-service'; then
  export OPERATOR_ISOLATION_MARKER=local-dev
  info "operator:dev detected -> OPERATOR_ISOLATION_MARKER=local-dev"
fi

# ------------------------------------------------------------------ case 1

if runs 1; then
  say "[1/6] inherit: no schedule override -> preview CronJob carries the source schedule"
  write_config "$CONFIG_DIR/inherit.json" '{"cronjob": null}'
  if start_preview "$KEY_INHERIT" "$CONFIG_DIR/inherit.json"; then
    SESSION=$(session_of "$KEY_INHERIT")
    info "session: $SESSION (phase $(phase_of "$SESSION"))"
    [ "$(phase_of "$SESSION")" = "Ready" ] && ok "phase Ready" || bug "expected Ready, got $(phase_of "$SESSION")"

    if kubectl get cronjob "$SESSION" -n "$NS" >/dev/null 2>&1; then
      ok "preview CronJob $SESSION exists"
      [ "$(cron_field "$SESSION" .spec.schedule)" = "$SOURCE_SCHEDULE" ] \
        && ok "schedule inherited: $SOURCE_SCHEDULE" \
        || bug "schedule is '$(cron_field "$SESSION" .spec.schedule)', expected '$SOURCE_SCHEDULE'"
      [ "$(cron_field "$SESSION" .spec.suspend)" = "false" ] \
        && ok "preview CronJob is not suspended (source is)" \
        || bug "preview CronJob suspend=$(cron_field "$SESSION" .spec.suspend)"
      [ "$(cron_field "$SESSION" '.spec.jobTemplate.spec.template.spec.containers[0].image')" = "$PREVIEW_IMAGE" ] \
        && ok "job template runs the preview image" \
        || bug "job template image is $(cron_field "$SESSION" '.spec.jobTemplate.spec.template.spec.containers[0].image')"
    else
      bug "preview CronJob $SESSION missing"
    fi

    JOB="$SESSION-start"
    if kubectl get job "$JOB" -n "$NS" >/dev/null 2>&1; then
      ok "trigger Job $JOB exists"
      [ "$(kubectl get job "$JOB" -n "$NS" -o jsonpath='{.metadata.annotations.cronjob\.kubernetes\.io/instantiate}')" = "manual" ] \
        && ok "trigger Job is annotated as a manual run" || bug "trigger Job lacks the manual annotation"
      if wait_for 90 "trigger pod" sh -c "kubectl get pod -n '$NS' -l job-name='$JOB' -o name | grep -q ."; then
        POD_IMAGE=$(kubectl get pod -n "$NS" -l "job-name=$JOB" -o jsonpath='{.items[0].spec.containers[0].image}')
        [ "$POD_IMAGE" = "$PREVIEW_IMAGE" ] && ok "trigger pod ran $POD_IMAGE" || bug "trigger pod image is $POD_IMAGE"
        info "trigger pod logs: $(kubectl logs -n "$NS" -l "job-name=$JOB" --tail=3 2>/dev/null | tr '\n' ' ')"
      else
        bug "no pod appeared for the trigger Job"
      fi
    else
      bug "trigger Job $JOB missing - the CronJob was not triggered on start"
    fi

    [ "$(cron_field "$CRONJOB" .spec.suspend)" = "true" ] \
      && ok "source CronJob untouched (still suspended)" || bug "source CronJob was modified"
  else
    bug "preview start failed"
    SESSION=$(session_of "$KEY_INHERIT"); [ -n "$SESSION" ] && info "failure: $(failure_of "$SESSION")"
  fi
fi

# ------------------------------------------------------------------ case 2

if runs 2; then
  say "[2/6] override: schedule */1 * * * * -> a scheduled run appears next to the trigger"
  if start_preview "$KEY_OVERRIDE" "$ROOT/apps/echo-app/mirrord-preview-cronjob.json"; then
    SESSION=$(session_of "$KEY_OVERRIDE")
    info "session: $SESSION"
    [ "$(cron_field "$SESSION" .spec.schedule)" = "*/1 * * * *" ] \
      && ok "schedule overridden: */1 * * * *" \
      || bug "schedule is '$(cron_field "$SESSION" .spec.schedule)', expected '*/1 * * * *'"
    if wait_for "$SCHEDULE_WAIT" "a scheduled job" sh -c \
        "kubectl get jobs -n '$NS' -o name | grep -v -- '-start\$' | grep -q '^job.batch/$SESSION-'"; then
      ok "scheduled job created: $(kubectl get jobs -n "$NS" -o name | grep "^job.batch/$SESSION-" | grep -v -- '-start$' | head -1)"
    else
      bug "no scheduled job within ${SCHEDULE_WAIT}s"
    fi
  else
    bug "preview start failed"
    SESSION=$(session_of "$KEY_OVERRIDE"); [ -n "$SESSION" ] && info "failure: $(failure_of "$SESSION")"
  fi
fi

# ------------------------------------------------------------------ case 3

if runs 3; then
  say "[3/6] stop: preview stop removes the CronJob and its jobs"
  SESSION=$(session_of "$KEY_OVERRIDE")
  [ -z "$SESSION" ] && SESSION=$(session_of "$KEY_INHERIT")
  if [ -z "$SESSION" ]; then
    bug "no session to stop (run cases 1 or 2 first)"
  else
    KEY=$(kubectl get previewsession "$SESSION" -n "$NS" -o jsonpath='{.spec.key}')
    if stop_preview "$KEY" >"$CONFIG_DIR/stop.log" 2>&1; then
      ok "preview stop -k $KEY succeeded"
    else
      bug "preview stop -k $KEY failed:"; tail -5 "$CONFIG_DIR/stop.log"
    fi
    wait_for 60 "session gone" sh -c "! kubectl get previewsession '$SESSION' -n '$NS' >/dev/null 2>&1" \
      && ok "session $SESSION deleted" || bug "session $SESSION still present"
    wait_for 60 "cronjob gone" sh -c "! kubectl get cronjob '$SESSION' -n '$NS' >/dev/null 2>&1" \
      && ok "preview CronJob garbage collected" || bug "preview CronJob $SESSION still present"
    wait_for 60 "jobs gone" sh -c "! kubectl get jobs -n '$NS' -o name | grep -q '^job.batch/$SESSION'" \
      && ok "preview jobs garbage collected" || bug "jobs of $SESSION still present"
  fi
fi

# ------------------------------------------------------------------ case 4

if runs 4; then
  say "[4/6] invalid schedule is rejected by the CLI"
  write_config "$CONFIG_DIR/invalid.json" '{"cronjob": {"schedule": "* * *"}}'
  expect_start_failure "$KEY_INVALID" "$CONFIG_DIR/invalid.json" "feature.preview.cronjob.schedule"
fi

# ------------------------------------------------------------------ case 5

if runs 5; then
  say "[5/6] idle mode with a cronjob target is rejected by the CLI"
  write_config "$CONFIG_DIR/idle.json" '{"idle": {"start_idle": true}}'
  expect_start_failure "$KEY_IDLE" "$CONFIG_DIR/idle.json" "feature.preview.idle"
fi

# ------------------------------------------------------------------ case 6

if runs 6; then
  say "[6/6] trigger_on_start false: Ready with the CronJob but no -start Job"
  write_config "$CONFIG_DIR/notrigger.json" '{"cronjob": {"schedule": "0 3 * * *", "trigger_on_start": false}}'
  if start_preview "$KEY_NOTRIGGER" "$CONFIG_DIR/notrigger.json"; then
    SESSION=$(session_of "$KEY_NOTRIGGER")
    info "session: $SESSION (phase $(phase_of "$SESSION"))"
    kubectl get cronjob "$SESSION" -n "$NS" >/dev/null 2>&1 \
      && ok "preview CronJob $SESSION exists" || bug "preview CronJob $SESSION missing"
    # The trigger Job is created in the same step as the CronJob, so its absence now is final.
    if kubectl get job "$SESSION-start" -n "$NS" >/dev/null 2>&1; then
      bug "trigger Job $SESSION-start exists although trigger_on_start is false"
    else
      ok "no trigger Job, the preview runs on its schedule alone"
    fi
    stop_preview "$KEY_NOTRIGGER" >/dev/null 2>&1 || true
  else
    bug "preview start failed"
    SESSION=$(session_of "$KEY_NOTRIGGER"); [ -n "$SESSION" ] && info "failure: $(failure_of "$SESSION")"
  fi
fi

# ------------------------------------------------------------------ verdict

say "Verdict"
if [ "$FAILURES" -eq 0 ]; then
  ok "CronJob previews: all cases passed"
else
  bug "$FAILURES check(s) failed - see above"
  exit 1
fi
