#!/usr/bin/env bash
#
# Author: arfonzo [AT] imgnai [DOT] com
#
# Automatically update Hypersnap validators.toml and Docker images.
#
# Installation:
#   chmod +x ~/hypersnap/update-hypersnap.sh
#
# Test manually:
#   ~/hypersnap/update-hypersnap.sh
#
# Run every 15 minutes via cron:
#   */15 * * * * $HOME/hypersnap/update-hypersnap.sh >> $HOME/hypersnap/update.log 2>&1
#
# View log:
#   tail -f ~/hypersnap/update.log
#
# Requirements:
#   Docker Engine, Docker Compose v2, curl with ETag support,
#   Python 3.11+, flock and standard GNU utilities.
#
# Safety:
#   - Uses conditional HTTP requests to avoid downloading unchanged validators.toml.
#   - Backs up the previous validators.toml before replacing it.
#   - Validates TOML before installation.
#   - Replaces validators.toml atomically.
#   - Only restarts Hypersnap when validators.toml changes.
#   - Compose recreates services whose images have changed.
#   - Does not run compose down, remove volumes, prune images or remove orphans.
#   - Uses separate pending markers to recover from interrupted updates.
#   - Prevents concurrent executions with flock.

set -Eeuo pipefail

HYPERSNAP_DIR="${HYPERSNAP_DIR:-${HOME:?HOME is not set}/hypersnap}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
VALIDATORS_URL="https://raw.githubusercontent.com/farcasterorg/hypersnap/main/validators.toml"

VALIDATORS_FILE="$HYPERSNAP_DIR/validators.toml"
ETAG_FILE="$HYPERSNAP_DIR/.validators.toml.etag"

VALIDATORS_PENDING="$HYPERSNAP_DIR/.validators-restart-pending"
IMAGES_PENDING="$HYPERSNAP_DIR/.images-update-pending"

LOCK_FILE="$HYPERSNAP_DIR/.update.lock"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Check dependencies.
for cmd in docker curl python3 flock sort cmp mktemp date cp chmod mv rm touch grep; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

curl --help all | grep -q -- '--etag-compare' ||
    die "Installed curl does not support ETag conditional requests."

[[ -d "$HYPERSNAP_DIR" ]] || die "Directory not found: $HYPERSNAP_DIR"

cd "$HYPERSNAP_DIR"

[[ -f "$VALIDATORS_FILE" ]] || die "Missing local validators.toml: $VALIDATORS_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "Missing Compose file: $COMPOSE_FILE"

# Prevent overlapping executions.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

COMPOSE=(docker compose -f "$COMPOSE_FILE")
if [[ -f docker-compose.override.yml ]]; then
    COMPOSE+=(-f docker-compose.override.yml)
fi

# Verify Docker and Compose.
docker info >/dev/null 2>&1 || die "Docker is unavailable."

"${COMPOSE[@]}" config --quiet ||
    die "Compose configuration is invalid."

"${COMPOSE[@]}" config --services | grep -Fxq hypersnap ||
    die "Compose service 'hypersnap' was not found."

# Create temporary working files.
TMP_DIR=$(mktemp -d)
NEW_VALIDATORS=$(mktemp "$HYPERSNAP_DIR/.validators.toml.XXXXXXXX")
TMP_ETAG="$TMP_DIR/validators.etag"

cleanup() {
    rm -rf -- "$TMP_DIR"
    [[ -z "${NEW_VALIDATORS:-}" ]] || rm -f -- "$NEW_VALIDATORS"
}
trap cleanup EXIT

# ----------------------------------------------------------------------
# 1. Check validators.toml using HTTP ETag conditional requests.
# ----------------------------------------------------------------------

log "Checking upstream validators.toml..."

CURL_ARGS=(
    --fail
    --location
    --silent
    --show-error
    --retry 3
    --retry-delay 2
    --connect-timeout 15
    --max-time 120
    --etag-save "$TMP_ETAG"
    --output "$NEW_VALIDATORS"
    --write-out '%{http_code}'
)

# Send If-None-Match when we have a previously saved ETag.
if [[ -s "$ETAG_FILE" ]]; then
    CURL_ARGS+=(--etag-compare "$ETAG_FILE")
fi

HTTP_STATUS=$(curl "${CURL_ARGS[@]}" "$VALIDATORS_URL") ||
    die "Failed to check/download validators.toml."

case "$HTTP_STATUS" in
    304)
        log "validators.toml is unchanged (HTTP 304)."
        ;;

    200)
        # Validate downloaded TOML before installing it.
        if ! python3 - "$NEW_VALIDATORS" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)

validator_sets = data.get("consensus", {}).get("validator_sets")

if not isinstance(validator_sets, list) or not validator_sets:
    raise ValueError("Missing or empty consensus.validator_sets")
PY
        then
            die "Downloaded validators.toml failed validation."
        fi

        if cmp -s "$VALIDATORS_FILE" "$NEW_VALIDATORS"; then
            log "validators.toml content is unchanged."
        else
            BACKUP_FILE="$VALIDATORS_FILE.backup.$(date '+%Y%m%d-%H%M%S').$$"

            [[ ! -e "$BACKUP_FILE" ]] ||
                die "Backup already exists: $BACKUP_FILE"

            log "Backing up current validators.toml to $BACKUP_FILE"

            cp -p -- "$VALIDATORS_FILE" "$BACKUP_FILE"

            cmp -s "$VALIDATORS_FILE" "$BACKUP_FILE" ||
                die "Backup verification failed."

            # Record pending work before replacing the file.
            touch "$VALIDATORS_PENDING"

            chmod --reference="$VALIDATORS_FILE" "$NEW_VALIDATORS"

            # Atomic replacement on the same filesystem.
            mv -f -- "$NEW_VALIDATORS" "$VALIDATORS_FILE"
            NEW_VALIDATORS=""

            log "Installed updated validators.toml."
        fi

        # Save the new ETag only after successful validation.
        if [[ -s "$TMP_ETAG" ]]; then
            mv -f -- "$TMP_ETAG" "$ETAG_FILE"
        else
            rm -f -- "$ETAG_FILE"
        fi
        ;;

    *)
        die "Unexpected HTTP status checking validators.toml: $HTTP_STATUS"
        ;;
esac

# ----------------------------------------------------------------------
# 2. Check Docker images.
# ----------------------------------------------------------------------

log "Checking Docker images..."

"${COMPOSE[@]}" config --images | sort -u > "$TMP_DIR/images"

# Remember whether a previous run left an incomplete image update.
IMAGES_WERE_PENDING=0

if [[ -e "$IMAGES_PENDING" ]]; then
    IMAGES_WERE_PENDING=1
    log "Found a pending image update from a previous run."
fi

snapshot_images() {
    local image
    local image_id

    while IFS= read -r image; do
        [[ -n "$image" ]] || continue

        if image_id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null); then
            printf '%s %s\n' "$image" "$image_id"
        else
            printf '%s MISSING\n' "$image"
        fi
    done < "$TMP_DIR/images" | sort
}

snapshot_images > "$TMP_DIR/images-before"

# Mark the operation pending before pulling.
touch "$IMAGES_PENDING"

"${COMPOSE[@]}" pull ||
    die "Docker image pull failed."

snapshot_images > "$TMP_DIR/images-after"

IMAGES_CHANGED=0

if ! cmp -s "$TMP_DIR/images-before" "$TMP_DIR/images-after"; then
    IMAGES_CHANGED=1
    log "Docker image changes detected."
else
    log "All Docker images are already up to date."
fi

# Apply changed images, or recover an interrupted previous update.
if [[ "$IMAGES_CHANGED" -eq 1 || "$IMAGES_WERE_PENDING" -eq 1 ]]; then
    log "Applying Docker image updates..."

    "${COMPOSE[@]}" up -d --pull never ||
        die "Failed to apply Docker image updates."

    rm -f -- "$IMAGES_PENDING"

    log "Docker image updates applied."
else
    rm -f -- "$IMAGES_PENDING"
fi

# ----------------------------------------------------------------------
# 3. Restart Hypersnap if validators.toml changed or restart was pending.
# ----------------------------------------------------------------------

if [[ -e "$VALIDATORS_PENDING" ]]; then
    log "Restarting Hypersnap to load validators.toml..."

    "${COMPOSE[@]}" restart hypersnap ||
        die "Failed to restart Hypersnap."

    rm -f -- "$VALIDATORS_PENDING"

    log "Hypersnap restarted successfully."
fi

# ----------------------------------------------------------------------
# 4. Finish.
# ----------------------------------------------------------------------

log "Update check completed."

