#!/bin/sh
# Copy Job for the Cassandra generic branch: schema first (DESCRIBE piped into the branch -
# the "schema mode" of a generic copy), then data via client-side COPY TO/FROM staged on
# the Job's /scratch disk.
set -e

if ! cqlsh "$MIRRORD_PARAM_HOST" "$MIRRORD_PARAM_PORT" -e 'DESCRIBE KEYSPACE sandbox' > /scratch/schema.cql 2>/dev/null; then
  echo "no 'sandbox' keyspace on the source - nothing to copy"
  exit 0
fi

echo "recreating schema on the branch"
cqlsh "$MIRRORD_BRANCH_HOST" "$MIRRORD_BRANCH_PORT" -f /scratch/schema.cql

echo "copying sandbox.msgs rows through /scratch"
cqlsh "$MIRRORD_PARAM_HOST" "$MIRRORD_PARAM_PORT" -e "COPY sandbox.msgs TO '/scratch/msgs.csv'"
cqlsh "$MIRRORD_BRANCH_HOST" "$MIRRORD_BRANCH_PORT" -e "COPY sandbox.msgs FROM '/scratch/msgs.csv'"

echo "branch now holds:"
cqlsh "$MIRRORD_BRANCH_HOST" "$MIRRORD_BRANCH_PORT" -e "SELECT COUNT(*) FROM sandbox.msgs;"
