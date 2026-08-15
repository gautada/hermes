#!/usr/bin/env bash
# Install a recovered state.db in place of the live one and restart hermes.
# Run this INSIDE the pod (`kubectl exec -n ai deploy/hermes -it -- zsh`), as root.
#
# Safety gates that are NOT skippable:
#   - the recovered candidate must pass PRAGMA integrity_check before anything else runs
#   - the current live db is backed up before it is overwritten
#   - stale -wal/-shm/-journal sidecars are cleared so they can't get replayed
#     against unrelated data after the swap
#   - the swapped-in live file is re-verified before the service is restarted
#
# Usage:
#   01_cutover.sh --recovered /mnt/volumes/data/recovered-state-v2.db
#
# Optional overrides:
#   --live      path to the live db (default: /mnt/volumes/data/state.db)
#   --service   s6 service dir     (default: /etc/services.d/hermes)

set -euo pipefail

LIVE="/mnt/volumes/data/state.db"
SERVICE="/etc/services.d/hermes"
RECOVERED=""

while [ $# -gt 0 ]; do
    case "$1" in
        --recovered) RECOVERED="$2"; shift 2 ;;
        --live) LIVE="$2"; shift 2 ;;
        --service) SERVICE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$RECOVERED" ]; then
    echo "Usage: $0 --recovered <path-to-recovered-db> [--live <path>] [--service <s6-dir>]" >&2
    exit 2
fi
if [ ! -f "$RECOVERED" ]; then
    echo "Error: recovered candidate not found: $RECOVERED" >&2
    exit 1
fi

echo "== 1/7: verifying candidate integrity: $RECOVERED"
RESULT="$(sqlite3 -readonly "$RECOVERED" "PRAGMA integrity_check;")"
if [ "$RESULT" != "ok" ]; then
    echo "Error: candidate failed integrity_check:" >&2
    echo "$RESULT" >&2
    exit 1
fi
FK="$(sqlite3 -readonly "$RECOVERED" "PRAGMA foreign_key_check;")"
if [ -n "$FK" ]; then
    echo "Error: candidate has foreign key violations:" >&2
    echo "$FK" >&2
    exit 1
fi
echo "   ok. sessions=$(sqlite3 -readonly "$RECOVERED" 'SELECT COUNT(*) FROM sessions;') messages=$(sqlite3 -readonly "$RECOVERED" 'SELECT COUNT(*) FROM messages;')"

echo "== 2/7: holding hermes service down: $SERVICE"
s6-svc -d "$SERVICE"
for _ in $(seq 1 10); do
    if ! pgrep -f "hermes gateway run" > /dev/null 2>&1; then
        break
    fi
    sleep 1
done
if pgrep -f "hermes gateway run" > /dev/null 2>&1; then
    echo "Error: hermes gateway process still running after hold-down; aborting." >&2
    exit 1
fi
echo "   stopped."

BACKUP="${LIVE}.pre-install-backup-$(date +%Y%m%d_%H%M%S)"
echo "== 3/7: backing up current live db to: $BACKUP"
cp "$LIVE" "$BACKUP"

echo "== 4/7: clearing stale WAL/SHM/journal sidecars for: $LIVE"
for suffix in -wal -shm -journal; do
    if [ -f "${LIVE}${suffix}" ]; then
        echo "   removing ${LIVE}${suffix}"
        rm -f "${LIVE}${suffix}"
    fi
done

echo "== 5/7: installing recovered db"
cp "$RECOVERED" "$LIVE"

echo "== 6/7: verifying installed live db"
RESULT="$(sqlite3 -readonly "$LIVE" "PRAGMA integrity_check;")"
if [ "$RESULT" != "ok" ]; then
    echo "Error: installed db failed integrity_check - restoring backup." >&2
    echo "$RESULT" >&2
    cp "$BACKUP" "$LIVE"
    exit 1
fi
echo "   ok. sessions=$(sqlite3 -readonly "$LIVE" 'SELECT COUNT(*) FROM sessions;') messages=$(sqlite3 -readonly "$LIVE" 'SELECT COUNT(*) FROM messages;')"

echo "== 7/7: restarting hermes service"
s6-svc -u "$SERVICE"
sleep 2
if pgrep -f "hermes gateway run" > /dev/null 2>&1; then
    echo "   hermes is running."
else
    echo "Warning: hermes did not appear to start - check logs." >&2
    exit 1
fi

echo
echo "Done. Backup of the prior live db is at: $BACKUP"
echo "Keep it, the .malformed-backup, and every recovered-*.db + .recovery.json around for now."
