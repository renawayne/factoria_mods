#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="${GITHUB_REPOSITORY:-renawayne/factoria_mods}"
BRANCH="${GITHUB_BRANCH:-main}"
PACK_PATH="${GITHUB_PACK_PATH:-Death_train/mods}"
MODS_DIR="${MODS:-/factorio/mods}"
STATE_DIR="/factorio/.github-mod-sync"
STATE_FILE="${STATE_DIR}/managed.tsv"
API_URL="https://api.github.com/repos/${REPOSITORY}/contents/${PACK_PATH}?ref=${BRANCH}"

log() { echo "[GitHub Mod Sync] $*"; }
fail() { log "ERROR: $*"; exit 1; }
skip_update() {
  log "WARNING: $*"
  log "Keeping the last installed mod set and continuing server startup."
  exit 0
}

mkdir -p "$MODS_DIR" "$STATE_DIR"

command -v curl >/dev/null || fail "curl is not installed"
command -v jq >/dev/null || fail "jq is not installed"
command -v unzip >/dev/null || fail "unzip is not installed"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log "Reading ${REPOSITORY}/${PACK_PATH} (${BRANCH})"

curl --fail --silent --show-error --location \
  --retry 3 --retry-delay 2 \
  -H "Accept: application/vnd.github+json" \
  -H "User-Agent: Factorio-Death-train-Server" \
  "$API_URL" -o "$WORK_DIR/list.json" \
  || skip_update "GitHub request failed."

jq -e 'type == "array"' "$WORK_DIR/list.json" >/dev/null \
  || skip_update "GitHub path is not a directory or API returned an error."

mapfile -t ENTRIES < <(
  jq -r '.[] | select(.type == "file" and (.name | ascii_downcase | endswith(".zip"))) | [.name, .download_url] | @tsv' "$WORK_DIR/list.json"
)

if [ "${#ENTRIES[@]}" -eq 0 ]; then
  log "No ZIP files found. Existing managed mods are left untouched."
  exit 0
fi

declare -A NEW_FILES=()
declare -A NEW_NAMES=()
declare -A OLD_FILES=()
declare -A OLD_NAMES=()

if [ -f "$STATE_FILE" ]; then
  while IFS=$'\t' read -r filename modname; do
    [ -n "${filename:-}" ] && OLD_FILES["$filename"]=1
    [ -n "${modname:-}" ] && OLD_NAMES["$modname"]=1
  done < "$STATE_FILE"
fi

for entry in "${ENTRIES[@]}"; do
  IFS=$'\t' read -r filename download_url <<< "$entry"
  [[ -n "${filename:-}" && -n "${download_url:-}" ]] || skip_update "Invalid GitHub directory entry."
  [[ "$filename" != */* ]] || skip_update "Unexpected filename: $filename"
  [[ "$filename" =~ \.zip$ ]] || continue

  target="$WORK_DIR/$filename"
  log "Downloading $filename"
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    "$download_url" -o "$target" \
    || skip_update "Download failed for $filename."

  unzip -tqq "$target" >/dev/null \
    || skip_update "$filename is not a valid ZIP archive."

  modname="$(unzip -p "$target" info.json 2>/dev/null | jq -er '.name' 2>/dev/null)" \
    || skip_update "$filename does not contain a valid root-level info.json with a name."

  [[ "$modname" =~ ^[A-Za-z0-9_-]+$ ]] || skip_update "Invalid Factorio mod name in $filename: $modname"
  [ -z "${NEW_NAMES[$modname]+x}" ] || skip_update "More than one ZIP declares mod name '$modname'."
  NEW_FILES["$filename"]="$modname"
  NEW_NAMES["$modname"]=1
done

# Do not overwrite a ZIP that this synchronizer does not own.
for filename in "${!NEW_FILES[@]}"; do
  target="$MODS_DIR/$filename"
  if [ -e "$target" ] && [ -z "${OLD_FILES[$filename]+x}" ]; then
    if ! cmp -s "$WORK_DIR/$filename" "$target"; then
      skip_update "$filename already exists but is not managed by GitHub sync. Rename or move the conflicting file first."
    fi
  fi
done

changed=0
for filename in "${!NEW_FILES[@]}"; do
  target="$MODS_DIR/$filename"
  if [ ! -f "$target" ] || ! cmp -s "$WORK_DIR/$filename" "$target"; then
    changed=1
  fi
done
for filename in "${!OLD_FILES[@]}"; do
  [ -n "${NEW_FILES[$filename]+x}" ] || changed=1
done

if [ "$changed" -eq 0 ]; then
  log "No changes detected."
else
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="/factorio/backups/github-mod-sync/$timestamp"
  mkdir -p "$backup_dir/mods" "$backup_dir/saves"

  [ ! -f "$MODS_DIR/mod-list.json" ] || cp -a "$MODS_DIR/mod-list.json" "$backup_dir/mod-list.json"

  for filename in "${!OLD_FILES[@]}"; do
    [ ! -f "$MODS_DIR/$filename" ] || cp -a "$MODS_DIR/$filename" "$backup_dir/mods/"
  done

  latest_save="$(find /factorio/saves -maxdepth 1 -type f -name '*.zip' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)"
  if [ -n "$latest_save" ] && [ -f "$latest_save" ]; then
    cp -a "$latest_save" "$backup_dir/saves/"
  fi

  # Downloaded archives are already staged and validated; apply them now.
  for filename in "${!NEW_FILES[@]}"; do
    install -m 0644 "$WORK_DIR/$filename" "$MODS_DIR/$filename.tmp"
    mv -f "$MODS_DIR/$filename.tmp" "$MODS_DIR/$filename"
  done

  # Remove only files previously recorded as managed by this synchronizer.
  for filename in "${!OLD_FILES[@]}"; do
    [ -n "${NEW_FILES[$filename]+x}" ] || rm -f -- "$MODS_DIR/$filename"
  done

  # Preserve the existing mod list and update only GitHub-managed mod entries.
  if [ ! -f "$MODS_DIR/mod-list.json" ]; then
    printf '%s\n' '{"mods":[{"name":"base","enabled":true}]}' > "$MODS_DIR/mod-list.json"
  fi

  for old_name in "${!OLD_NAMES[@]}"; do
    [ -n "${NEW_NAMES[$old_name]+x}" ] || \
      jq --arg name "$old_name" '.mods |= map(select(.name != $name))' \
        "$MODS_DIR/mod-list.json" > "$WORK_DIR/mod-list.json" \
      && mv "$WORK_DIR/mod-list.json" "$MODS_DIR/mod-list.json"
  done

  for modname in "${!NEW_NAMES[@]}"; do
    jq --arg name "$modname" '
      if any(.mods[]?; .name == $name) then
        .mods |= map(if .name == $name then .enabled = true else . end)
      else
        .mods += [{"name":$name,"enabled":true}]
      end
    ' "$MODS_DIR/mod-list.json" > "$WORK_DIR/mod-list.json" \
      && mv "$WORK_DIR/mod-list.json" "$MODS_DIR/mod-list.json"
  done

  : > "$WORK_DIR/managed.tsv"
  for filename in "${!NEW_FILES[@]}"; do
    printf '%s\t%s\n' "$filename" "${NEW_FILES[$filename]}" >> "$WORK_DIR/managed.tsv"
  done
  sort -o "$WORK_DIR/managed.tsv" "$WORK_DIR/managed.tsv"
  install -m 0644 "$WORK_DIR/managed.tsv" "$STATE_FILE"

  # Keep the three most recent sync backups.
  if [ -d /factorio/backups/github-mod-sync ]; then
    mapfile -t backup_dirs < <(find /factorio/backups/github-mod-sync -mindepth 1 -maxdepth 1 -type d | sort -r)
    for ((i=3; i<${#backup_dirs[@]}; i++)); do
      rm -rf -- "${backup_dirs[$i]}"
    done
  fi

  log "GitHub-managed mods updated. Backup: $backup_dir"
fi

# Prevent the official Mod Portal updater from replacing GitHub-managed mods.
managed_names=""
for modname in "${!NEW_NAMES[@]}"; do
  if [ -n "$managed_names" ]; then managed_names+=","
  fi
  managed_names+="$modname"
done
if [ -n "$managed_names" ]; then
  if [ -n "${UPDATE_IGNORE:-}" ]; then
    export UPDATE_IGNORE="${UPDATE_IGNORE},${managed_names}"
  else
    export UPDATE_IGNORE="$managed_names"
  fi
fi

# The official image runs Factorio as UID/GID 845 by default.
chown -R 845:845 "$MODS_DIR" "$STATE_DIR" /factorio/backups 2>/dev/null || true

log "Synchronization complete."
