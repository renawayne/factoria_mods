#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /factorio/config

if [ -n "${ADMIN_LIST:-}" ]; then
  printf '%s' "$ADMIN_LIST" | tr ',' '\n' | jq -Rsc '
    split("\n")
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0))
  ' > /factorio/config/server-adminlist.json
fi

echo "[Factorio] Synchronizing GitHub-managed mods..."
/usr/local/bin/sync-github-mods.sh

# The sync script writes managed mod names to a file because exports from a
# child process do not propagate back to this entrypoint.
IGNORE_FILE="/factorio/.github-mod-sync/update-ignore"
if [ -f "$IGNORE_FILE" ]; then
  github_ignore="$(paste -sd, "$IGNORE_FILE" | sed 's/,$//')"
  if [ -n "$github_ignore" ]; then
    if [ -n "${UPDATE_IGNORE:-}" ]; then
      UPDATE_IGNORE="${UPDATE_IGNORE},${github_ignore}"
    else
      UPDATE_IGNORE="$github_ignore"
    fi
  fi
fi
export UPDATE_IGNORE

echo "[Factorio] Starting official Factorio entrypoint..."
exec /docker-entrypoint.sh "$@"
