#!/usr/bin/env bash
# Re-check a state.db backup's canonical-table readability at any time.
# Never opens the source directly, never writes anything - pure diagnostic.
#
# Usage: 02_inspect_backup.sh /mnt/volumes/data/state.db.malformed-backup-YYYYMMDD_HHMMSS

set -euo pipefail

SOURCE="${1:?Usage: $0 <path-to-backup-db>}"

hermes sessions recover --source "$SOURCE" --inspect-only
