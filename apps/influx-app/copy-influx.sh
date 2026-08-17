#!/bin/sh
# Copy Job for the InfluxDB generic branch: exports the source bucket as annotated CSV,
# stages it on the Job's /scratch disk (the dump-to-disk-then-restore pattern), and writes
# it into the branch. The branch's setup-mode bootstrap already created the same
# org/bucket/token, so the copy authenticates with the app's own credentials on both sides.
set -e

echo "exporting bucket '$MIRRORD_PARAM_BUCKET' from http://$MIRRORD_PARAM_HOST:$MIRRORD_PARAM_PORT"
influx query \
  --host "http://$MIRRORD_PARAM_HOST:$MIRRORD_PARAM_PORT" \
  --org "$MIRRORD_PARAM_ORG" --token "$MIRRORD_PARAM_TOKEN" --raw \
  "from(bucket:\"$MIRRORD_PARAM_BUCKET\") |> range(start:${COPY_RANGE_START:--30d})" \
  > /scratch/points.csv

if grep -q '^[^#]' /scratch/points.csv; then
  influx write \
    --host "http://$MIRRORD_BRANCH_HOST:$MIRRORD_BRANCH_PORT" \
    --org "$MIRRORD_PARAM_ORG" --token "$MIRRORD_PARAM_TOKEN" \
    --bucket "$MIRRORD_PARAM_BUCKET" --format csv --file /scratch/points.csv
  echo "copied $(grep -c '^[^#]' /scratch/points.csv) csv rows into the branch"
else
  echo "source bucket is empty in range ${COPY_RANGE_START:--30d} - nothing to copy"
fi
