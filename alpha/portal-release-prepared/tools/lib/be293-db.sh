# shellcheck shell=bash
# Read-only SQL against the be293 Portal PostgreSQL. Source this file; the caller defines K as the kubectl
# command with explicit --kubeconfig/--context/-n be293. SQL is read from stdin and must start with
# BEGIN READ ONLY; default_transaction_read_only=on is forced as a second guard. The superuser password is
# expanded inside the pod from its own environment and never appears on a command line or in output.
# Extra arguments go to psql (e.g. -A -t -F '|' for machine-readable rows).

BE293_PG_POD=be293-portal-postgresql-0
BE293_PG_CONTAINER=postgresql

psql_ro() {
  "${K[@]}" exec -i "$BE293_PG_POD" -c "$BE293_PG_CONTAINER" -- sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" PGOPTIONS="-c default_transaction_read_only=on" exec psql -X -q -v ON_ERROR_STOP=1 -P pager=off -U postgres -d postgres "$@" -f -' \
    psql "$@"
}
