#!/bin/sh
# The app's migration entrypoint: pre-flight checks, then the migration run. Applied files
# are tracked in a rails-style schema_migrations table, so re-runs (branch reuse) apply
# only the delta.
set -e

. /home/app/config/db_env.sh

echo "running pre-migration checks"
for _ in $(seq 30); do
  if run_sql -e "SELECT 1" >/dev/null 2>&1; then break; fi
  echo "waiting for database at $DB_HOST:$DB_PORT..."
  sleep 2
done
run_sql -e "SELECT 1" >/dev/null

echo "migrating database"
run_sql -e "CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(255) PRIMARY KEY)"

for f in /home/app/db/migrate/*.sql; do
  version="$(basename "$f" .sql)"
  applied="$(run_sql -N -e "SELECT COUNT(*) FROM schema_migrations WHERE version='$version'")"
  if [ "$applied" = "0" ]; then
    echo "applying $version"
    run_sql <"$f"
    run_sql -e "INSERT INTO schema_migrations (version) VALUES ('$version')"
  else
    echo "skipping $version (already applied)"
  fi
done

echo "migrations complete"
