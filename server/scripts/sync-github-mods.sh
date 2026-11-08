#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="${GITHUB_REPOSITORY:-renawayne/factoria_mods}"
BRANCH="${GITHUB_BRANCH:-main}"
PACK_PATH="${GITHUB_PACK_PATH:-Death_train/mods}"
MODS_DIR="${MODS:-/factorio/mods}"
STATE_DIR="/factorio/.github-mod-sync"
STATE_FILE="${STATE_DIR}/managed.tsv"
IGNORE_FILE="${STATE_DIR}/update-ignore"
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

# Load the previously managed mods before contacting GitHub.
declare -A OLD_FILES=()
declare -A OLD_NAMES=()

if [ -f "$STATE_FILE" ]; then
  while IFS=$'\t' read -r filename modname; do
    [[ "${filename:-}" =~ ^[A-Za-z0-9._-]+\.zip$ ]] || continue
    [[ "${modname:-}" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    OLD_FILES["$filename"]=1
    OLD_NAMES["$modname"]=1
  done < "$STATE_FILE"
fi

# The child sync process cannot export variables back to its parent entrypoint.
# Persist managed mod names so factorio-entrypoint.sh can pass them to Factorio.
write_ignore_file() {
  : > "$IGNORE_FILE"
  local name
  for name in "$@"; do
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    printf '%s\n' "$name" >> "$IGNORE_FILE"
  done
}

write_ignore_file "${!OLD_NAMES[@]}"

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

mapfile -t ZIP_NAMES < <(
  jq -r '.[] | select(.type == "file" and (.name | ascii_downcase | endswith(".zip"))) | .name' "$WORK_DIR/list.json"
)

if [ "${#ZIP_NAMES[@]}" -eq 0 ]; then
  skip_update "No ZIP files found in the GitHub mod folder."
fi

declare -A NEW_FILES=()
declare -A NEW_NAMES=()

# GitHub mod-list.json is the source of truth for this pack.
mod_list_url="$(jq -r '.[] | select(.type == "file" and .name == "mod-list.json") | .download_url' "$WORK_DIR/list.json" | head -n1)"
if [ -n "$mod_list_url" ] && [ "$mod_list_url" != "null" ]; then
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    "$mod_list_url" -o "$WORK_DIR/mod-list.json" \
    || skip_update "Could not download mod-list.json from GitHub."
elif [ -f "$MODS_DIR/mod-list.json" ]; then
  cp "$MODS_DIR/mod-list.json" "$WORK_DIR/mod-list.json"
  log "GitHub has no mod-list.json; keeping the existing server mod-list."
else
  printf '%s\n' '{"mods":[{"name":"base","enabled":true}]}' > "$WORK_DIR/mod-list.json"
  log "No mod-list.json found; creating a minimal list."
fi

jq -e '(.mods | type == "array") and any(.mods[]?; .name == "base")' \
  "$WORK_DIR/mod-list.json" >/dev/null \
  || skip_update "mod-list.json is invalid or does not contain the base mod."

for filename in "${ZIP_NAMES[@]}"; do
  [[ "$filename" =~ ^[A-Za-z0-9._-]+\.zip$ ]] \
    || skip_update "Unexpected ZIP filename: $filename"

  download_url="$(jq -r --arg name "$filename" '.[] | select(.type == "file" and .name == $name) | .download_url' "$WORK_DIR/list.json" | head -n1)"
  [[ -n "$download_url" && "$download_url" != "null" ]] \
    || skip_update "No download URL for $filename."

  target="$WORK_DIR/$filename"
  log "Downloading $filename"
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    "$download_url" -o "$target" \
    || skip_update "Download failed for $filename."

  unzip -tqq "$target" >/dev/null \
    || skip_update "$filename is not a valid ZIP archive."

  mapfile -t info_entries < <(
    unzip -Z1 "$target" | awk '
      {
        original = $0
        normalized = tolower($0)
        sub(/^\.\//, "", normalized)
        if (normalized == "info.json" || normalized ~ /\/info\.json$/) print original
      }
    '
  )

  [ "${#info_entries[@]}" -eq 1 ] \
    || skip_update "$filename must contain exactly one info.json."

  modname="$(unzip -p "$target" "${info_entries[0]}" 2>/dev/null | jq -er '.name' 2>/dev/null)" \
    || skip_update "$filename contains an invalid info.json or no mod name."

  [[ "$modname" =~ ^[A-Za-z0-9_-]+$ ]] \
    || skip_update "Invalid Factorio mod name in $filename: $modname"

  [ -z "${NEW_NAMES[$modname]+x}" ] \
    || skip_update "More than one ZIP declares mod name '$modname'."

  NEW_FILES["$filename"]="$modname"
  NEW_NAMES["$modname"]=1
done

# Add missing GitHub-managed mods to mod-list.json.
# Existing enabled/disabled values are kept as authored in GitHub.
for modname in "${!NEW_NAMES[@]}"; do
  jq --arg name "$modname" '
    if any(.mods[]?; .name == $name) then
      .
    else
      .mods += [{"name":$name,"enabled":true}]
    end
  ' "$WORK_DIR/mod-list.json" > "$WORK_DIR/mod-list.next.json" \
    || skip_update "Could not update mod-list.json."
  mv "$WORK_DIR/mod-list.next.json" "$WORK_DIR/mod-list.json"
done

# Never overwrite an existing ZIP unless this synchronizer owns it.
for filename in "${!NEW_FILES[@]}"; do
  target="$MODS_DIR/$filename"
  if [ -e "$target" ] && [ -z "${OLD_FILES[$filename]+x}" ]; then
    if ! cmp -s "$WORK_DIR/$filename" "$target"; then
      skip_update "$filename already exists but is not managed by GitHub sync. Move or rename the conflicting file first."
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
if [ ! -f "$MODS_DIR/mod-list.json" ] || ! cmp -s "$WORK_DIR/mod-list.json" "$MODS_DIR/mod-list.json"; then
  changed=1
fi

if [ "$changed" -eq 1 ]; then
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

  # Apply only after every download and validation has succeeded.
  for filename in "${!NEW_FILES[@]}"; do
    install -m 0644 "$WORK_DIR/$filename" "$MODS_DIR/$filename.tmp"
    mv -f "$MODS_DIR/$filename.tmp" "$MODS_DIR/$filename"
  done

  for filename in "${!OLD_FILES[@]}"; do
    [ -n "${NEW_FILES[$filename]+x}" ] || rm -f -- "$MODS_DIR/$filename"
  done

  install -m 0644 "$WORK_DIR/mod-list.json" "$MODS_DIR/mod-list.json.tmp"
  mv -f "$MODS_DIR/mod-list.json.tmp" "$MODS_DIR/mod-list.json"

  log "GitHub mod pack updated. Backup: $backup_dir"

  mapfile -t backup_dirs < <(find /factorio/backups/github-mod-sync -mindepth 1 -maxdepth 1 -type d | sort -r)
  for ((i=3; i<${#backup_dirs[@]}; i++)); do
    rm -rf -- "${backup_dirs[$i]}"
  done
else
  log "No changes detected."
fi

# Record managed ZIPs and the names to protect from the official Mod Portal updater.
: > "$WORK_DIR/managed.tsv"
for filename in "${!NEW_FILES[@]}"; do
  printf '%s\t%s\n' "$filename" "${NEW_FILES[$filename]}" >> "$WORK_DIR/managed.tsv"
done
sort -o "$WORK_DIR/managed.tsv" "$WORK_DIR/managed.tsv"
install -m 0644 "$WORK_DIR/managed.tsv" "$STATE_FILE"
write_ignore_file "${!NEW_NAMES[@]}"

chown -R 845:845 "$MODS_DIR" "$STATE_DIR" /factorio/backups 2>/dev/null || true

log "Synchronization complete."
log "Protected GitHub-managed mods: $(paste -sd, "$IGNORE_FILE" 2>/dev/null || true)"
