#!/bin/sh
# Starts TravelAgency inside the container:
#   1. builds the JDBC URL from DB_HOST / DB_PORT / DB_NAME (unless DB_TRAVELAGENCY_URL is given),
#   2. waits until MySQL accepts the application user,
#   3. DB_SEED=auto: loads the demo data only if the database has no tables yet,
#   4. starts Tomcat (the CMD of the image).
set -eu

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-travelagency}"
: "${DB_TRAVELAGENCY_USER:?DB_TRAVELAGENCY_USER is not set}"
: "${DB_TRAVELAGENCY_PASSWORD:?DB_TRAVELAGENCY_PASSWORD is not set}"
export DB_TRAVELAGENCY_URL="${DB_TRAVELAGENCY_URL:-jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}?useSSL=false&allowPublicKeyRetrieval=true}"

# MYSQL_PWD is set only for the mysql client: it accepts any characters in the
# password and keeps it off the command line (the process already has it in its environment)
sql() {
  MYSQL_PWD="$DB_TRAVELAGENCY_PASSWORD" mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" \
    -u "$DB_TRAVELAGENCY_USER" --get-server-public-key -N -B -e "$1" "$DB_NAME"
}

echo "entrypoint: waiting for MySQL at ${DB_HOST}:${DB_PORT}..."
tries=0
until err=$(sql "SELECT 1" 2>&1 >/dev/null); do
  tries=$((tries + 1))
  if [ "$tries" -ge "${DB_WAIT_TRIES:-90}" ]; then
    echo "entrypoint: MySQL is not reachable: ${err}" >&2
    exit 1
  fi
  sleep 2
done

case "${DB_SEED:-auto}" in
  auto)
    tables=$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")
    if [ "$tables" -eq 0 ]; then DB_SEED=true; else DB_SEED=false; fi
    echo "entrypoint: ${tables} tables in ${DB_NAME} -> DB_SEED=${DB_SEED}"
    ;;
  true|false)
    echo "entrypoint: DB_SEED=${DB_SEED} (set explicitly)"
    ;;
  *)
    echo "entrypoint: DB_SEED must be auto, true or false, got '${DB_SEED}'" >&2
    exit 1
    ;;
esac
export DB_SEED

exec "$@"
