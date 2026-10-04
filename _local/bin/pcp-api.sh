#!/bin/sh
# Paperclip API helper — avoids Tirith subshell issues with Bearer tokens.
# During Paperclip heartbeat runs: uses PAPERCLIP_API_KEY and PAPERCLIP_RUN_ID from env.
# During interactive sessions: reads key from file, uses X_RUN_ID env if set.
#
# Usage: pcp-api.sh METHOD /api/path [json-body]
#   pcp-api.sh GET /api/agents/me
#   pcp-api.sh PATCH /api/issues/<id> '{"status":"done"}'

set -e
KEY_FILE="${HERMES_HOME:-${HOME}/.hermes}/.paperclip-api-key"
BASE="${PAPERCLIP_API_URL:-https://paperclip.gautier.org}"
# Strip trailing /api if present (some envs include it)
BASE="${BASE%/api}"
BASE="${BASE%/}"

METHOD="${1:?Usage: pcp-api.sh METHOD /path [body]}"
PATH_PART="${2:?Usage: pcp-api.sh METHOD /path [body]}"
BODY="$3"

# Prefer env-injected key (heartbeat runs), fall back to file (interactive)
if [ -n "${PAPERCLIP_API_KEY:-}" ]; then
  PKEY="$PAPERCLIP_API_KEY"
elif [ -f "$KEY_FILE" ]; then
  PKEY="$(cat "$KEY_FILE")"
else
  echo "ERROR: No Paperclip API key found (env PAPERCLIP_API_KEY or $KEY_FILE)" >&2
  exit 1
fi

# Prefer PAPERCLIP_RUN_ID (heartbeat), fall back to X_RUN_ID (manual)
RUN_ID="${PAPERCLIP_RUN_ID:-$X_RUN_ID}"

if [ -n "$BODY" ]; then
  curl -fsS -X "$METHOD" \
    -H "Authorization: Bearer $PKEY" \
    -H "Content-Type: application/json" \
    ${RUN_ID:+-H "X-Paperclip-Run-Id: $RUN_ID"} \
    -d "$BODY" \
    "${BASE}${PATH_PART}"
else
  curl -fsS \
    -H "Authorization: Bearer $PKEY" \
    ${RUN_ID:+-H "X-Paperclip-Run-Id: $RUN_ID"} \
    "${BASE}${PATH_PART}"
fi
