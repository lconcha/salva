#!/usr/bin/env bash
# Init/start/stop/status a Postgres instance for SALVA dev, running as the
# invoking user inside the salva-dev container (no 'postgres' system user
# needed since PGDATA lives in a plain bind-mounted directory).
#
# 'start' runs postgres inside a persistent `apptainer instance` (not a
# one-shot `apptainer exec`). pg_ctl daemonizes (double-forks) the actual
# postgres process, which then outlives whatever exec launched it; if that
# exec was a one-shot `apptainer exec`, the SIF's squashfs mount backing the
# postgres binary/libs disappears once the exec's process exits, and the
# server SIGBUSes a few seconds later the first time it touches an unmapped
# page. An `apptainer instance` keeps the mount alive for as long as the
# instance runs, which postgres then lives safely inside of.
#
# Usage: apptainer/dev-db.sh {init|start|stop|status|psql|createdb}

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SIF="$HERE/salva-dev.sif"
PGDATA_HOST="$REPO_ROOT/apptainer/pgdata"
SOCKDIR_HOST="$REPO_ROOT/apptainer/pgsock"
INSTANCE=salva-pg

command -v module >/dev/null 2>&1 && module load singularity >/dev/null 2>&1 || true

mkdir -p "$PGDATA_HOST" "$SOCKDIR_HOST"

PGBIN=/usr/lib/postgresql/15/bin

# Ad hoc, self-contained exec (fine for short-lived client tools: psql,
# createdb, pg_ctl status/stop -- they don't outlive this process).
run() {
    apptainer exec \
        --bind "$PGDATA_HOST:/opt/pgdata" \
        --bind "$SOCKDIR_HOST:/opt/pgsock" \
        "$SIF" "$@"
}

instance_running() {
    apptainer instance list "$INSTANCE" 2>/dev/null | grep -q "$INSTANCE"
}

case "${1:-}" in
    init)
        if [ -f "$PGDATA_HOST/PG_VERSION" ]; then
            echo "Already initialized: $PGDATA_HOST"
        else
            run "$PGBIN/initdb" -D /opt/pgdata -U salva -A trust --encoding=UTF8
        fi
        ;;
    start)
        if instance_running; then
            echo "Instance '$INSTANCE' already running"
        else
            apptainer instance start \
                --bind "$PGDATA_HOST:/opt/pgdata" \
                --bind "$SOCKDIR_HOST:/opt/pgsock" \
                "$SIF" "$INSTANCE"
        fi
        apptainer exec "instance://$INSTANCE" \
            "$PGBIN/pg_ctl" -D /opt/pgdata -l /opt/pgdata/postgres.log \
            -o "-k /opt/pgsock -h 127.0.0.1 -p 5432" start
        ;;
    stop)
        if instance_running; then
            apptainer exec "instance://$INSTANCE" \
                "$PGBIN/pg_ctl" -D /opt/pgdata stop -m fast || true
        fi
        apptainer instance stop "$INSTANCE" 2>/dev/null || true
        ;;
    status)
        if instance_running; then
            apptainer exec "instance://$INSTANCE" "$PGBIN/pg_ctl" -D /opt/pgdata status
        else
            echo "Instance '$INSTANCE' not running"
        fi
        ;;
    createdb)
        run "$PGBIN/createdb" -h 127.0.0.1 -p 5432 -U salva "${2:?db name required}"
        ;;
    psql)
        shift
        run "$PGBIN/psql" -h 127.0.0.1 -p 5432 -U salva "$@"
        ;;
    *)
        echo "Usage: $0 {init|start|stop|status|createdb <name>|psql [args]}" >&2
        exit 1
        ;;
esac
