#!/usr/bin/env bash
#
# Interactive test drive for the GENERIC BRANCH COPY JOB against the current cluster.
#
# Proves, per scenario (pick any subset from the menu):
#
#   [COPY]    a user-authored copy Job in mirrord.json fills the branch before it turns
#             Ready: the branch valkey holds the source's 3 seeded keys, not 0.
#   [EMPTY]   no `copy` anywhere still gives today's empty branch (regression guard).
#   [FAIL]    a copy Job that exits non-zero fails the branch FAST, and mirrord's error
#             carries the Job's own stderr (the marker line), not a bare timeout.
#   [TTL]     a copy that sleeps ~40s under ttl_secs=45 is not swept mid-Job - the
#             operator refreshes expire_time when the Job starts.
#   [PROFILE] mirrord.json shrunk to type/id/profile/connection; branch image/port/args
#             AND the copy Job come from the operator profile (needs the profile deployed,
#             the script checks and tells you how if missing).
#
# Fixtures: a password-protected valkey source pod (3 seeded keys) + service + secret,
# and a busybox target pod whose env carries VALKEY_ADDR / VALKEY_PASSWORD (secretKeyRef).
# Verification reads the branch pod directly with valkey-cli, so nothing needs to be
# installed locally beyond kubectl, jq, gum, and the mirrord binary.
#
# Env overrides:
#   NAMESPACE     target namespace for fixtures and branches   (default: default)
#   OPERATOR_NS   namespace the operator runs in               (default: mirrord)
#   MIRRORD_BIN   mirrord CLI to use                           (default: $MIRRORD_BINARY or `mirrord` on PATH)
#   PROFILE_NAME  operator profile for the PROFILE scenario    (default: e2e-valkey-full)

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
OPERATOR_NS="${OPERATOR_NS:-mirrord}"
MIRRORD_BIN="${MIRRORD_BIN:-${MIRRORD_BINARY:-mirrord}}"
PROFILE_NAME="${PROFILE_NAME:-e2e-valkey-full}"

PASSWORD="copy-e2e-pass"
SECRET_NAME="generic-copy-creds"
SOURCE_NAME="generic-copy-source"
# openssl instead of tr</dev/urandom | head: head's early close sends tr a SIGPIPE,
# which pipefail turns into exit 141 under set -e.
SUFFIX="$(openssl rand -hex 3)"
TARGET_POD="generic-copy-target-${SUFFIX}"
BRANCH_IMAGE="valkey/valkey:8-alpine"
CRD="branchdatabases.dbs.mirrord.metalbear.co"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# The same env contract a customer copy image gets: read the source via MIRRORD_PARAM_*,
# write into the branch via MIRRORD_BRANCH_HOST/PORT. MIGRATE ... COPY keeps the source
# intact; the final DBSIZE comparison fails the Job if any key was missed.
# Shell command substitutions are written `$$(...)`: Kubernetes expands `$(VAR)` in
# command/args itself and turns `$$` into a literal `$`, so the shell sees `$(...)`.
COPY_SCRIPT='set -e
export REDISCLI_AUTH="$MIRRORD_PARAM_PASSWORD"
for key in $$(valkey-cli --no-auth-warning -h "$MIRRORD_PARAM_HOST" -p "$MIRRORD_PARAM_PORT" --scan); do
  valkey-cli --no-auth-warning -h "$MIRRORD_PARAM_HOST" -p "$MIRRORD_PARAM_PORT" \
    MIGRATE "$MIRRORD_BRANCH_HOST" "$MIRRORD_BRANCH_PORT" "$key" 0 5000 COPY AUTH "$MIRRORD_PARAM_PASSWORD"
done
src=$$(valkey-cli --no-auth-warning -h "$MIRRORD_PARAM_HOST" -p "$MIRRORD_PARAM_PORT" DBSIZE)
dst=$$(valkey-cli --no-auth-warning -h "$MIRRORD_BRANCH_HOST" -p "$MIRRORD_BRANCH_PORT" DBSIZE)
echo "copied $dst of $src keys"
test "$src" = "$dst"'

FAIL_MARKER="copy-script-exploded"

PASS=()
FAILED=()

say()  { gum style --foreground 212 "$1"; }
ok()   { gum style --foreground 82  "  PASS  $1"; PASS+=("$1"); }
bad()  { gum style --foreground 196 "  FAIL  $1"; FAILED+=("$1"); }
info() { gum style --foreground 245 "  $1"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1 ($2)"; exit 1; }
}

# AUTO=1 (or no TTY): skip the prompts, run everything, clean up at the end - so the
# script also works piped to a log. gum spin needs a TTY, so steps print plainly there.
AUTO="${AUTO:-}"
[[ -t 0 ]] || AUTO=1

# spin <title> <command string>: gum spinner on a TTY, plain streaming output otherwise
spin() {
  if [[ -n "$AUTO" ]]; then
    say "$1"
    bash -c "$2"
  else
    gum spin --title "$1" -- bash -c "$2"
  fi
}

# ---------- fixtures ----------

deploy_fixtures() {
  kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
    --from-literal=password="$PASSWORD" --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${SOURCE_NAME}
  namespace: ${NAMESPACE}
  labels: { app: ${SOURCE_NAME} }
spec:
  containers:
    - name: valkey
      image: ${BRANCH_IMAGE}
      command:
        - sh
        - -c
        - >
          valkey-server --requirepass "\$VALKEY_PASSWORD" --save '' --appendonly no &
          SERVER=\$!;
          until valkey-cli -a "\$VALKEY_PASSWORD" --no-auth-warning ping 2>/dev/null | grep -q PONG; do sleep 1; done;
          valkey-cli -a "\$VALKEY_PASSWORD" --no-auth-warning MSET user:1 alice user:2 bob counter 42;
          wait \$SERVER
      env:
        - name: VALKEY_PASSWORD
          valueFrom: { secretKeyRef: { name: ${SECRET_NAME}, key: password } }
      ports: [{ containerPort: 6379 }]
---
apiVersion: v1
kind: Service
metadata:
  name: ${SOURCE_NAME}
  namespace: ${NAMESPACE}
spec:
  selector: { app: ${SOURCE_NAME} }
  ports: [{ port: 6379, targetPort: 6379 }]
---
apiVersion: v1
kind: Pod
metadata:
  name: ${TARGET_POD}
  namespace: ${NAMESPACE}
  labels: { app: ${TARGET_POD} }
spec:
  containers:
    - name: app
      image: busybox:latest
      imagePullPolicy: IfNotPresent
      command: ["sleep", "7200"]
      env:
        - name: VALKEY_ADDR
          value: "${SOURCE_NAME}:6379"
        - name: VALKEY_PASSWORD
          valueFrom: { secretKeyRef: { name: ${SECRET_NAME}, key: password } }
EOF

  kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${SOURCE_NAME}" "pod/${TARGET_POD}" --timeout=120s >/dev/null
  # The source reports Ready as soon as the shell starts; give the seed a moment.
  sleep 5
}

cleanup_fixtures() {
  kubectl -n "$NAMESPACE" delete pod "$TARGET_POD" "$SOURCE_NAME" --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete service "$SOURCE_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete secret "$SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
}

# ---------- config building ----------

# base_branch_json <id> -> the shared generic branch skeleton (no copy, no profile)
base_branch_json() {
  jq -n --arg id "$1" --arg image "$BRANCH_IMAGE" '{
    type: "generic", id: $id, ttl_secs: 300, creation_timeout_secs: 240,
    image: $image, port: 6379,
    connection: { params: {
      host: { env_var_name: "VALKEY_ADDR", value_pattern: "^(?P<host>[^:]+):" },
      port: { env_var_name: "VALKEY_ADDR", value_pattern: ":(?P<port>[0-9]+)$" },
      password: "VALKEY_PASSWORD"
    }},
    args: ["valkey-server", "--requirepass", "$(MIRRORD_PARAM_PASSWORD)"]
  }'
}

# write_config <file> <branch-json>
write_config() {
  jq -n --arg pod "$TARGET_POD" --arg ns "$NAMESPACE" --argjson branch "$2" '{
    target: { path: { pod: $pod }, namespace: $ns },
    operator: true,
    feature: {
      env: true, fs: "local",
      network: { incoming: "off", outgoing: false },
      db_branches: [$branch]
    }
  }' > "$1"
}

# ---------- verification helpers ----------

# branch_cr_name <branch-id> -> CR name, or empty
branch_cr_name() {
  kubectl -n "$NAMESPACE" get "$CRD" -o json 2>/dev/null \
    | jq -r --arg id "$1" '.items[] | select(.spec.id == $id) | .metadata.name' | head -1
}

# branch_dbsize <cr-name> -> DBSIZE of the branch pod's valkey
branch_dbsize() {
  local pod
  pod="$(kubectl -n "$NAMESPACE" get pods -l "db-owner-name=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || { echo "no-branch-pod"; return; }
  kubectl -n "$NAMESPACE" exec "$pod" -- valkey-cli --no-auth-warning -a "$PASSWORD" DBSIZE 2>/dev/null | tr -d '[:space:]' || true
}

# cr_field <cr-name> <jsonpath>
cr_field() {
  [[ -n "$1" ]] || return 0
  kubectl -n "$NAMESPACE" get "$CRD" "$1" -o jsonpath="$2" 2>/dev/null || true
}

delete_branch() {
  local cr="$1"
  [[ -n "$cr" ]] || return 0
  kubectl -n "$NAMESPACE" delete "$CRD" "$cr" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete pods -l "db-owner-name=${cr}" --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
}

# ---------- scenarios ----------

scenario_copy() {
  local id="copy-e2e-copy-${SUFFIX}" cfg="$WORKDIR/copy.json" log="$WORKDIR/copy.log"
  write_config "$cfg" "$(base_branch_json "$id" | jq --arg img "$BRANCH_IMAGE" --arg s "$COPY_SCRIPT" \
    '.copy = { image: $img, command: ["sh", "-c", $s] }')"

  spin "[COPY] session with a copy Job (waits for pod + Job)..." \
    "'$MIRRORD_BIN' exec -f '$cfg' -- /bin/sh -c 'echo session-up' >'$log' 2>&1" \
    || { bad "[COPY] mirrord exec failed"; sed 's/^/    /' "$log" | tail -5; return; }

  local cr size copy_phase
  cr="$(branch_cr_name "$id")"
  size="$(branch_dbsize "$cr")"
  copy_phase="$(cr_field "$cr" '{.status.copy.phase}')"

  [[ "$copy_phase" == "Succeeded" ]] \
    && ok "[COPY] status.copy.phase = Succeeded" \
    || bad "[COPY] status.copy.phase = '${copy_phase}' (want Succeeded)"
  [[ "$size" == "3" ]] \
    && ok "[COPY] branch DBSIZE = 3 (source keys copied before Ready)" \
    || bad "[COPY] branch DBSIZE = '${size}' (want 3)"

  delete_branch "$cr"
}

scenario_empty() {
  local id="copy-e2e-empty-${SUFFIX}" cfg="$WORKDIR/empty.json" log="$WORKDIR/empty.log"
  write_config "$cfg" "$(base_branch_json "$id")"

  spin "[EMPTY] session with no copy configured..." \
    "'$MIRRORD_BIN' exec -f '$cfg' -- /bin/sh -c 'echo session-up' >'$log' 2>&1" \
    || { bad "[EMPTY] mirrord exec failed"; sed 's/^/    /' "$log" | tail -5; return; }

  local cr size
  cr="$(branch_cr_name "$id")"
  size="$(branch_dbsize "$cr")"
  [[ "$size" == "0" ]] \
    && ok "[EMPTY] branch DBSIZE = 0 (no copy = empty branch, unchanged behavior)" \
    || bad "[EMPTY] branch DBSIZE = '${size}' (want 0)"

  delete_branch "$cr"
}

scenario_fail() {
  local id="copy-e2e-fail-${SUFFIX}" cfg="$WORKDIR/fail.json" log="$WORKDIR/fail.log"
  # creation_timeout far above what the failure should take: passing fast proves the
  # branch failed via the Job, not by burning the timeout.
  write_config "$cfg" "$(base_branch_json "$id" | jq --arg img "$BRANCH_IMAGE" --arg m "$FAIL_MARKER" \
    '.creation_timeout_secs = 600 | .copy = { image: $img, command: ["sh", "-c", ("echo " + $m + " >&2; exit 1")] }')"

  if spin "[FAIL] session whose copy Job exits 1..." \
    "'$MIRRORD_BIN' exec -f '$cfg' -- /bin/sh -c 'echo session-up' >'$log' 2>&1"; then
    bad "[FAIL] mirrord exec succeeded but the copy Job must fail the branch"
  else
    ok "[FAIL] mirrord exec failed as expected"
    grep -q "$FAIL_MARKER" "$log" \
      && ok "[FAIL] error carries the Job's own stderr ('${FAIL_MARKER}')" \
      || { bad "[FAIL] Job stderr marker missing from mirrord's error"; sed 's/^/    /' "$log" | tail -8; }
  fi

  local cr phase
  cr="$(branch_cr_name "$id")"
  phase="$(cr_field "$cr" '{.status.phase}')"
  [[ "$phase" == "Failed" ]] \
    && ok "[FAIL] branch phase = Failed" \
    || bad "[FAIL] branch phase = '${phase}' (want Failed)"

  delete_branch "$cr"
}

scenario_ttl() {
  local id="copy-e2e-ttl-${SUFFIX}" cfg="$WORKDIR/ttl.json" log="$WORKDIR/ttl.log"
  # The copy sleeps for almost the whole ttl_secs before copying: without the
  # expire_time refresh at Job start, pod boot + 40s crosses the 45s TTL and the
  # pending sweep deletes the branch mid-Job.
  write_config "$cfg" "$(base_branch_json "$id" | jq --arg img "$BRANCH_IMAGE" --arg s "sleep 40
$COPY_SCRIPT" '.ttl_secs = 45 | .copy = { image: $img, command: ["sh", "-c", $s] }')"

  spin "[TTL] copy sleeps 40s under ttl_secs=45 (takes ~1min)..." \
    "'$MIRRORD_BIN' exec -f '$cfg' -- /bin/sh -c 'echo session-up' >'$log' 2>&1" \
    || { bad "[TTL] mirrord exec failed - branch likely swept mid-Job"; sed 's/^/    /' "$log" | tail -5; return; }

  local cr size
  cr="$(branch_cr_name "$id")"
  size="$(branch_dbsize "$cr")"
  [[ "$size" == "3" ]] \
    && ok "[TTL] slow copy finished and filled the branch (expire_time was refreshed)" \
    || bad "[TTL] branch DBSIZE = '${size}' (want 3)"

  delete_branch "$cr"
}

scenario_profile() {
  local generic_config
  generic_config="$(kubectl -n "$OPERATOR_NS" get configmap mirrord-configmap \
    -o jsonpath='{.data.generic-branch-config\.yaml}' 2>/dev/null || true)"
  if ! grep -q "$PROFILE_NAME" <<<"$generic_config"; then
    bad "[PROFILE] profile '${PROFILE_NAME}' is not in the operator's generic branch config"
    info "deploy it with the e2e values file, e.g.:"
    info "  helm upgrade ... --values operator/public/charts/e2e_values/generic_copy_profiles.yaml"
    info "(or add an equivalent profiles.${PROFILE_NAME}.dbPod.{branch,copy} to your operator values)"
    return
  fi

  local id="copy-e2e-profile-${SUFFIX}" cfg="$WORKDIR/profile.json" log="$WORKDIR/profile.log"
  # The whole point: no image, no port, no args, no copy in mirrord.json.
  write_config "$cfg" "$(jq -n --arg id "$id" --arg profile "$PROFILE_NAME" '{
    type: "generic", id: $id, ttl_secs: 300, creation_timeout_secs: 240, profile: $profile,
    connection: { params: {
      host: { env_var_name: "VALKEY_ADDR", value_pattern: "^(?P<host>[^:]+):" },
      port: { env_var_name: "VALKEY_ADDR", value_pattern: ":(?P<port>[0-9]+)$" },
      password: "VALKEY_PASSWORD"
    }}
  }')"

  spin "[PROFILE] profile-only mirrord.json (branch defaults + copy from operator)..." \
    "'$MIRRORD_BIN' exec -f '$cfg' -- /bin/sh -c 'echo session-up' >'$log' 2>&1" \
    || { bad "[PROFILE] mirrord exec failed"; sed 's/^/    /' "$log" | tail -5; return; }

  local cr size
  cr="$(branch_cr_name "$id")"
  size="$(branch_dbsize "$cr")"
  [[ "$size" == "3" ]] \
    && ok "[PROFILE] profile supplied image/port/args AND the copy Job (DBSIZE = 3)" \
    || bad "[PROFILE] branch DBSIZE = '${size}' (want 3)"

  delete_branch "$cr"
}

# ---------- main ----------

require gum "brew install gum"
require kubectl "kubernetes CLI"
require jq "brew install jq"
command -v "$MIRRORD_BIN" >/dev/null 2>&1 || [[ -x "$MIRRORD_BIN" ]] \
  || { echo "mirrord binary not found: $MIRRORD_BIN (set MIRRORD_BIN)"; exit 1; }

gum style --border rounded --padding "0 2" --border-foreground 212 \
  "generic branch copy Job - cluster test drive" \
  "context:   $(kubectl config current-context)" \
  "namespace: ${NAMESPACE}    operator: ${OPERATOR_NS}" \
  "mirrord:   ${MIRRORD_BIN}"

[[ -n "$AUTO" ]] || gum confirm "Run against this context?" || exit 0

# The installed CRD must already carry the new fields, or the API server silently
# prunes `copy` from specs and every scenario chases a ghost.
if ! kubectl get crd "$CRD" -o json 2>/dev/null \
    | jq -e '.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.genericOptions.properties.copy' >/dev/null; then
  gum style --foreground 196 "The installed BranchDatabase CRD has no genericOptions.copy - redeploy the operator chart first."
  exit 1
fi

if [[ -n "$AUTO" ]]; then
  CHOICES="[COPY] [EMPTY] [FAIL] [TTL] [PROFILE]"
else
  CHOICES="$(gum choose --no-limit --selected='[COPY],[EMPTY],[FAIL],[TTL],[PROFILE]' \
    --header "Scenarios to run:" "[COPY]" "[EMPTY]" "[FAIL]" "[TTL]" "[PROFILE]")"
fi
[[ -n "$CHOICES" ]] || exit 0

say "Deploying fixtures (valkey source + target pod) into ${NAMESPACE}..."
spin "creating source, service, secret, target..." \
  "$(declare -f deploy_fixtures); NAMESPACE='$NAMESPACE' PASSWORD='$PASSWORD' SECRET_NAME='$SECRET_NAME' SOURCE_NAME='$SOURCE_NAME' TARGET_POD='$TARGET_POD' BRANCH_IMAGE='$BRANCH_IMAGE' deploy_fixtures"

if grep -q '\[COPY\]'    <<<"$CHOICES"; then scenario_copy;    fi
if grep -q '\[EMPTY\]'   <<<"$CHOICES"; then scenario_empty;   fi
if grep -q '\[FAIL\]'    <<<"$CHOICES"; then scenario_fail;    fi
if grep -q '\[TTL\]'     <<<"$CHOICES"; then scenario_ttl;     fi
if grep -q '\[PROFILE\]' <<<"$CHOICES"; then scenario_profile; fi

echo
gum style --border rounded --padding "0 2" \
  "passed: ${#PASS[@]}    failed: ${#FAILED[@]}"
for f in "${FAILED[@]:-}"; do [[ -n "$f" ]] && gum style --foreground 196 "  - $f"; done

if [[ -n "$AUTO" ]] || gum confirm "Delete fixtures (source pod/service/secret + target pod)?"; then
  cleanup_fixtures
  say "fixtures deleted"
else
  info "kept: pod/${SOURCE_NAME} svc/${SOURCE_NAME} secret/${SECRET_NAME} pod/${TARGET_POD} in ${NAMESPACE}"
fi

[[ ${#FAILED[@]} -eq 0 ]]
