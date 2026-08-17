# Parses DATABASE_URL (mysql2://user:pass@host:port/db) into DB_* vars and defines run_sql.
# Sourced by db_setup.sh and db_snapshot.sh - the app reads a single URL like Rails does.

if [ -z "$DATABASE_URL" ]; then
  echo "DATABASE_URL is not set" >&2
  exit 1
fi

_rest="${DATABASE_URL#*://}"
_userpass="${_rest%%@*}"
_hostportdb="${_rest#*@}"
_hostport="${_hostportdb%%/*}"

DB_USER="${_userpass%%:*}"
DB_PASS="${_userpass#*:}"
DB_HOST="${_hostport%%:*}"
DB_PORT="${_hostport#*:}"
DB_NAME="${_hostportdb#*/}"

# Password via env, not -p on the command line - the client prints an insecure-password
# warning per invocation otherwise, drowning the migration log.
export MYSQL_PWD="$DB_PASS"

run_sql() {
  mysql -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" "$DB_NAME" "$@"
}
