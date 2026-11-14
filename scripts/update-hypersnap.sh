#!/usr/bin/env bash
#
# Hypersnap Docker Image Updater
# ==============================
#
# Author: arfonzo [AT] imgnai [DOT] com
#
# Automatically checks for updated Docker images and recreates
# Hypersnap containers when an image has changed.
#
# INSTALLATION
# ------------
#
# 1. Save this script as:
#      $HOME/hypersnap/update-hypersnap.sh
#
# 2. Make it executable:
#      chmod +x "$HOME/hypersnap/update-hypersnap.sh"
#
# 3. Test it manually:
#      "$HOME/hypersnap/update-hypersnap.sh"
#
# 4. Add to your user's crontab:
#      crontab -e
#
#    Example: run every day at 04:00:
#      0 4 * * * $HOME/hypersnap/update-hypersnap.sh >> $HOME/hypersnap/update.log 2>&1
#
#    View the update log:
#      tail -f "$HOME/hypersnap/update.log"
#
# REQUIREMENTS
# ------------
#   - Docker Engine
#   - Docker Compose v2 (docker compose)
#   - flock (util-linux)
#   - Access to the Docker daemon
#
# CONFIGURATION
# -------------
#   HYPERSNAP_DIR
#     Defaults to "$HOME/hypersnap".
#     Can be overridden through an environment variable.
#
#   COMPOSE_FILE
#     Defaults to docker-compose.yml.
#
# SAFETY
# ------
#   - Never removes Docker volumes or images.
#   - Never removes orphaned containers.
#   - Never runs docker compose down.
#   - Does not recreate containers if images are unchanged.
#   - Uses a lock to prevent concurrent executions.
#   - Preserves a pending-update marker after failures.
#   - Does not use --renew-anon-volumes.
#
#   NOTE: Container recreation can cause downtime.
#   Updated application images may introduce bugs or database
#   migrations. No automatic rollback is provided.
#
# =====================================================================

set -Eeuo pipefail

# Timestamped messages from this script.
# Docker output is left untouched to preserve console colours.
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

HYPERSNAP_DIR="${HYPERSNAP_DIR:-${HOME:?HOME is not set}/hypersnap}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

PENDING_FILE="$HYPERSNAP_DIR/.update-pending"
LOCK_FILE="$HYPERSNAP_DIR/.update.lock"

# Ensure the working directory exists.
if [[ ! -d "$HYPERSNAP_DIR" ]]; then
    log "ERROR: Directory does not exist: $HYPERSNAP_DIR"
    exit 1
fi

cd "$HYPERSNAP_DIR"

# Prevent overlapping executions.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another update is already running. Skipping."
    exit 0
fi

# Validate required commands.
for cmd in docker flock sort cmp mktemp date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

# Confirm Docker is available.
if ! docker info >/dev/null 2>&1; then
    log "ERROR: Docker daemon is unavailable."
    exit 1
fi

# Validate Compose configuration.
if ! docker compose -f "$COMPOSE_FILE" config --quiet; then
    log "ERROR: Invalid Compose configuration."
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Retrieve all image references used by the Compose project.
if ! docker compose -f "$COMPOSE_FILE" config --images | sort -u > "$TMP_DIR/images"; then
    log "ERROR: Could not retrieve Compose image list."
    exit 1
fi

if [[ ! -s "$TMP_DIR/images" ]]; then
    log "ERROR: No images found in Compose configuration."
    exit 1
fi

# Snapshot current local image IDs.
snapshot_images() {
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue

        id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || printf 'MISSING')
        printf '%s %s\n' "$image" "$id"
    done < "$TMP_DIR/images"
}

if ! snapshot_images > "$TMP_DIR/before"; then
    log "ERROR: Could not snapshot existing images."
    exit 1
fi

# Check whether a previous execution left an incomplete update.
RETRY_PENDING=0
if [[ -f "$PENDING_FILE" ]]; then
    RETRY_PENDING=1
fi

log "Checking for Hypersnap image updates..."

# Mark the operation as pending BEFORE pulling.
touch "$PENDING_FILE"

# Pull images. Never deploy after a failed pull.
if ! docker compose -f "$COMPOSE_FILE" pull; then
    log "ERROR: Image pull failed. Deployment deferred."
    exit 1
fi

# Snapshot images again.
if ! snapshot_images > "$TMP_DIR/after"; then
    log "ERROR: Could not inspect updated images."
    exit 1
fi

# Compare image IDs or recover an interrupted deployment.
if ! cmp -s "$TMP_DIR/before" "$TMP_DIR/after" || (( RETRY_PENDING )); then

    log "Image updates detected (or previous deployment pending)."
    log "Recreating containers..."

    if docker compose -f "$COMPOSE_FILE" up -d --force-recreate --pull never; then
        rm -f "$PENDING_FILE"
        log "SUCCESS: Hypersnap updated successfully."
    else
        log "ERROR: Container recreation failed."
        log "Deployment remains pending for the next execution."
        exit 1
    fi

else
    rm -f "$PENDING_FILE"
    log "Images are already up to date. Nothing to do."
fi
