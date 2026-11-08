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

echo "[Factorio] Starting official Factorio entrypoint..."
exec /docker-entrypoint.sh "$@"
