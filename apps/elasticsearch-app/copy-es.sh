#!/bin/sh
# Copy Job for the Elasticsearch generic branch: server-side `_reindex` from remote - the
# BRANCH pulls the `sandbox` index from the SOURCE itself, so the Job only orchestrates
# with curl. Requires `reindex.remote.whitelist` on the branch env (set in the copy
# configs). COPY_QUERY (a JSON query object) makes it a filtered copy; unset = everything.
set -e

SRC="http://$MIRRORD_PARAM_HOST:$MIRRORD_PARAM_PORT"
DST="http://$MIRRORD_BRANCH_HOST:$MIRRORD_BRANCH_PORT"

if ! curl -fsS -u "elastic:$MIRRORD_PARAM_PASSWORD" "$SRC/sandbox" > /dev/null 2>&1; then
  echo "no 'sandbox' index on the source - nothing to copy"
  exit 0
fi

QUERY_CLAUSE=""
if [ -n "${COPY_QUERY:-}" ]; then
  QUERY_CLAUSE=", \"query\": $COPY_QUERY"
  echo "filtered reindex with query: $COPY_QUERY"
else
  echo "full reindex of the 'sandbox' index"
fi

curl -fsS -u "elastic:$MIRRORD_PARAM_PASSWORD" -X POST "$DST/_reindex?refresh=true&pretty" \
  -H 'Content-Type: application/json' -d "{
    \"source\": {
      \"remote\": {
        \"host\": \"$SRC\",
        \"username\": \"elastic\",
        \"password\": \"$MIRRORD_PARAM_PASSWORD\"
      },
      \"index\": \"sandbox\"$QUERY_CLAUSE
    },
    \"dest\": { \"index\": \"sandbox\" }
  }"
