#!/bin/bash
# Minecraft world manager for GCP-hosted Paper server
#
# Supports:
# - save: snapshot current live world into a named archive
# - import-zip: import a vanilla/Realms zip into a named archive
# - switch: switch live world to a named archive (with automatic pre-switch backup)
# - list: show available archives and active world sizes
#
# Usage:
#   ./scripts/world-manager.sh list
#   ./scripts/world-manager.sh save <archive-name> [--force]
#   ./scripts/world-manager.sh import-zip /path/to/world.zip <archive-name> [world-folder-name] [--force]
#   ./scripts/world-manager.sh switch <archive-name>

set -euo pipefail

if [ -f .env.local ]; then
  export $(grep -v '^#' .env.local | xargs)
elif [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

ZONE="${GCP_ZONE:-us-east1-b}"
INSTANCE="${GCP_INSTANCE:-mc}"
SERVER_DIR="/opt/minecraft/server"
WORLD_STORE="/opt/minecraft/world-library"
IMPORT_ROOT="/tmp/world-import"
SWITCH_STAGE="/tmp/world-switch-stage"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/world-manager.sh list
  ./scripts/world-manager.sh save <archive-name> [--force]
  ./scripts/world-manager.sh import-zip /path/to/world.zip <archive-name> [world-folder-name] [--force]
  ./scripts/world-manager.sh switch <archive-name>

Examples:
  ./scripts/world-manager.sh save fitcraft-main
  ./scripts/world-manager.sh import-zip ~/Downloads/realms.zip realms-jan "My Realm World"
  ./scripts/world-manager.sh switch fitcraft-main
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_archive_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid archive name '$name'. Allowed: letters, numbers, ., _, -"
}

remote() {
  gcloud compute ssh "$INSTANCE" --zone "$ZONE" --command "$1"
}

space_check() {
  local label="$1"
  echo ""
  echo "=== Disk Check: $label ==="
  remote "
set -e
echo 'Filesystem free space (/opt/minecraft):'
df -h /opt/minecraft | sed -n '1,2p'
echo
echo 'Key path sizes:'
sudo du -sh \
  ${SERVER_DIR}/world \
  ${SERVER_DIR}/world_nether \
  ${SERVER_DIR}/world_the_end \
  ${WORLD_STORE} \
  /tmp 2>/dev/null || true
"
}

archive_exists() {
  local archive="$1"
  remote "[ -f '${WORLD_STORE}/${archive}.tar.gz' ] && echo yes || echo no"
}

list_worlds() {
  remote "
set -e
echo 'Active world directories:'
sudo du -sh \
  ${SERVER_DIR}/world \
  ${SERVER_DIR}/world_nether \
  ${SERVER_DIR}/world_the_end 2>/dev/null || true
echo
echo 'World archives:'
if sudo test -d '${WORLD_STORE}'; then
  sudo ls -lh '${WORLD_STORE}'/*.tar.gz 2>/dev/null || echo '(none)'
else
  echo '(none)'
fi
"
}

save_world() {
  local archive="$1"
  local force="${2:-false}"
  validate_archive_name "$archive"

  if [ "$(archive_exists "$archive")" = "yes" ] && [ "$force" != "true" ]; then
    die "Archive '${archive}' already exists. Re-run with --force to overwrite."
  fi

  echo "Saving current live world as '${archive}'..."
  space_check "Before live-world archive creation"

  remote "sudo systemctl stop minecraft"
  remote "
set -e
sudo mkdir -p '${WORLD_STORE}'
sudo tar -C '${SERVER_DIR}' -czf '${WORLD_STORE}/${archive}.tar.gz' \
  world world_nether world_the_end
sudo chown minecraft:minecraft '${WORLD_STORE}/${archive}.tar.gz'
"
  remote "sudo systemctl start minecraft"

  space_check "After live-world archive creation"
  echo "Saved: ${WORLD_STORE}/${archive}.tar.gz"
}

import_zip() {
  local zip_file="$1"
  local archive="$2"
  local world_folder="${3:-}"
  local force="${4:-false}"
  local world_folder_b64=""

  validate_archive_name "$archive"
  [ -f "$zip_file" ] || die "Zip file not found: $zip_file"

  if [ "$(archive_exists "$archive")" = "yes" ] && [ "$force" != "true" ]; then
    die "Archive '${archive}' already exists. Re-run with --force to overwrite."
  fi

  if [ -n "$world_folder" ]; then
    world_folder_b64="$(printf '%s' "$world_folder" | base64 | tr -d '\n')"
  fi

  echo "Uploading zip to VM..."
  space_check "Before zip upload to /tmp"
  gcloud compute scp "$zip_file" "${INSTANCE}:/tmp/world-import.zip" --zone "$ZONE"
  space_check "After zip upload to /tmp"

  echo "Importing zip into archive '${archive}'..."
  space_check "Before zip extraction/staging"

  remote "
set -euo pipefail
ARCHIVE='${archive}'
WORLD_STORE='${WORLD_STORE}'
IMPORT_ROOT='${IMPORT_ROOT}'
WF_B64='${world_folder_b64}'

sudo rm -rf \"\${IMPORT_ROOT}\"
sudo mkdir -p \"\${IMPORT_ROOT}/extracted\" \"\${IMPORT_ROOT}/staged\"
sudo unzip -q -o /tmp/world-import.zip -d \"\${IMPORT_ROOT}/extracted\"

if [ -n \"\${WF_B64}\" ]; then
  WORLD_FOLDER=\$(printf '%s' \"\${WF_B64}\" | base64 -d)
  SRC=\"\${IMPORT_ROOT}/extracted/\${WORLD_FOLDER}\"
else
  WORLD_FOLDER=\$(cd \"\${IMPORT_ROOT}/extracted\" && find . -name level.dat | head -1 | sed 's|^\\./||; s|/level.dat\$||')
  SRC=\"\${IMPORT_ROOT}/extracted/\${WORLD_FOLDER}\"
fi

[ -n \"\${WORLD_FOLDER}\" ] || { echo 'Could not detect world folder in zip'; exit 1; }
[ -d \"\${SRC}\" ] || { echo \"Detected world folder not found: \${SRC}\"; exit 1; }

sudo cp -a \"\${SRC}\" \"\${IMPORT_ROOT}/staged/world\"

if [ -d \"\${IMPORT_ROOT}/staged/world/DIM-1\" ]; then
  sudo mkdir -p \"\${IMPORT_ROOT}/staged/world_nether\"
  sudo mv \"\${IMPORT_ROOT}/staged/world/DIM-1\" \"\${IMPORT_ROOT}/staged/world_nether/\"
fi

if [ -d \"\${IMPORT_ROOT}/staged/world/DIM1\" ]; then
  sudo mkdir -p \"\${IMPORT_ROOT}/staged/world_the_end\"
  sudo mv \"\${IMPORT_ROOT}/staged/world/DIM1\" \"\${IMPORT_ROOT}/staged/world_the_end/\"
fi

sudo mkdir -p \"\${WORLD_STORE}\"
sudo rm -f \"\${WORLD_STORE}/\${ARCHIVE}.tar.gz\"

cd \"\${IMPORT_ROOT}/staged\"
PARTS='world'
[ -d world_nether ] && PARTS=\"\${PARTS} world_nether\"
[ -d world_the_end ] && PARTS=\"\${PARTS} world_the_end\"
sudo tar -czf \"\${WORLD_STORE}/\${ARCHIVE}.tar.gz\" \${PARTS}
sudo chown minecraft:minecraft \"\${WORLD_STORE}/\${ARCHIVE}.tar.gz\"

sudo rm -rf \"\${IMPORT_ROOT}\" /tmp/world-import.zip
echo \"Imported archive: \${WORLD_STORE}/\${ARCHIVE}.tar.gz\"
"

  space_check "After zip extraction/staging and archive creation"
}

switch_world() {
  local target="$1"
  validate_archive_name "$target"

  if [ "$(archive_exists "$target")" != "yes" ]; then
    die "Archive '${target}' not found in ${WORLD_STORE}."
  fi

  local auto_backup
  auto_backup="auto-before-${target}-$(date +%Y%m%d-%H%M%S)"

  echo "Switching live world to '${target}'..."
  space_check "Before pre-switch backup"
  remote "sudo systemctl stop minecraft"

  remote "
set -e
sudo mkdir -p '${WORLD_STORE}'
sudo tar -C '${SERVER_DIR}' -czf '${WORLD_STORE}/${auto_backup}.tar.gz' \
  world world_nether world_the_end
sudo chown minecraft:minecraft '${WORLD_STORE}/${auto_backup}.tar.gz'
"
  space_check "After pre-switch backup"

  space_check "Before target extraction to staging"
  remote "
set -e
sudo rm -rf '${SWITCH_STAGE}'
sudo mkdir -p '${SWITCH_STAGE}'
sudo tar -xzf '${WORLD_STORE}/${target}.tar.gz' -C '${SWITCH_STAGE}'
sudo test -d '${SWITCH_STAGE}/world'
"
  space_check "After target extraction to staging"

  remote "
set -e
sudo rm -rf '${SERVER_DIR}/world' '${SERVER_DIR}/world_nether' '${SERVER_DIR}/world_the_end'
sudo cp -a '${SWITCH_STAGE}/world' '${SERVER_DIR}/'
if [ -d '${SWITCH_STAGE}/world_nether' ]; then
  sudo cp -a '${SWITCH_STAGE}/world_nether' '${SERVER_DIR}/'
fi
if [ -d '${SWITCH_STAGE}/world_the_end' ]; then
  sudo cp -a '${SWITCH_STAGE}/world_the_end' '${SERVER_DIR}/'
fi
sudo chown -R minecraft:minecraft '${SERVER_DIR}/world' '${SERVER_DIR}/world_nether' '${SERVER_DIR}/world_the_end' 2>/dev/null || true
sudo rm -rf '${SWITCH_STAGE}'
"
  space_check "After live world replacement"

  remote "sudo systemctl start minecraft"
  echo "Switch complete. Auto-backup created: ${WORLD_STORE}/${auto_backup}.tar.gz"
}

require_cmd gcloud
require_cmd base64

cmd="${1:-}"
case "$cmd" in
  list)
    list_worlds
    ;;
  save)
    [ $# -ge 2 ] || die "Usage: ./scripts/world-manager.sh save <archive-name> [--force]"
    force="false"
    [ "${3:-}" = "--force" ] && force="true"
    save_world "$2" "$force"
    ;;
  import-zip)
    [ $# -ge 3 ] || die "Usage: ./scripts/world-manager.sh import-zip /path/to/world.zip <archive-name> [world-folder-name] [--force]"
    force="false"
    world_folder=""
    if [ "${4:-}" = "--force" ]; then
      force="true"
    elif [ -n "${4:-}" ]; then
      world_folder="$4"
      [ "${5:-}" = "--force" ] && force="true"
    fi
    import_zip "$2" "$3" "$world_folder" "$force"
    ;;
  switch)
    [ $# -eq 2 ] || die "Usage: ./scripts/world-manager.sh switch <archive-name>"
    switch_world "$2"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    die "Unknown command: $cmd"
    ;;
esac
