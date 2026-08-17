#!/bin/sh
# The SNAPSHOT_JOB variant of the migration entrypoint: same migration run, plus a snapshot
# marker so the two code paths are distinguishable from the branch's contents.
set -e

echo "snapshot job mode"
/home/app/config/db_setup.sh

. /home/app/config/db_env.sh

run_sql -e "CREATE TABLE IF NOT EXISTS snapshot_info (taken_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, note VARCHAR(255))"
run_sql -e "INSERT INTO snapshot_info (note) VALUES ('created by db_snapshot.sh')"

echo "snapshot recorded"
