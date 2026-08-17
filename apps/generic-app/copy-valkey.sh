#!/bin/sh
# Copy Job for the Valkey generic branch: reads every key matching COPY_PATTERN from the
# SOURCE (MIRRORD_PARAM_*) and writes it into the BRANCH (MIRRORD_BRANCH_*). String values
# only - fine for the sandbox seed data. COPY_PATTERN unset = full copy; the filtered
# config sets it to a glob so only matching keys land in the branch.
set -e

src() {
  valkey-cli -h "$MIRRORD_PARAM_HOST" -p "$MIRRORD_PARAM_PORT" \
    -a "$MIRRORD_PARAM_PASSWORD" --no-auth-warning "$@"
}
dst() {
  valkey-cli -h "$MIRRORD_BRANCH_HOST" -p "$MIRRORD_BRANCH_PORT" \
    -a "$MIRRORD_PARAM_PASSWORD" --no-auth-warning "$@"
}

echo "copying keys matching '${COPY_PATTERN:-*}' from $MIRRORD_PARAM_HOST:$MIRRORD_PARAM_PORT to $MIRRORD_BRANCH_HOST:$MIRRORD_BRANCH_PORT"

src KEYS "${COPY_PATTERN:-*}" | while read -r key; do
  [ -z "$key" ] && continue
  dst SET "$key" "$(src GET "$key")" > /dev/null
  echo "  copied: $key"
done

echo "branch now holds $(dst DBSIZE) keys"
