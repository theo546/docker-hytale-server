#!/bin/bash
set -e

# Set a few variables
DOWNLOADER_URL="https://downloader.hytale.com/hytale-downloader.zip"
DOWNLOADER_DIR="/tmp/hytale-downloader"
CACHE_FILE="$DOWNLOADER_DIR/cache.txt"
GAME_DIR="/server"
CLI_EXECUTABLE="$DOWNLOADER_DIR/hytale-downloader-linux-amd64"

# Ensure directories exist
mkdir -p "$DOWNLOADER_DIR"

# Handle persistent machine-id (required for encrypted auth persistence)
MACHINE_ID_FILE="$GAME_DIR/machine-id"
if [ ! -f "$MACHINE_ID_FILE" ]; then
    echo "Generating new persistent machine-id..."
    if command -v dbus-uuidgen >/dev/null 2>&1; then
        dbus-uuidgen > "$MACHINE_ID_FILE"
    else
        cat /proc/sys/kernel/random/uuid | tr -d '-' > "$MACHINE_ID_FILE"
    fi
fi

# Apply to system location (writable thanks to Dockerfile permissions)
cp "$MACHINE_ID_FILE" /var/lib/dbus/machine-id

# Downloader CLI Caching
echo "Checking for Hytale Downloader CLI updates..."
REMOTE_LAST_MODIFIED=$(curl -sI "$DOWNLOADER_URL" | grep -i "Last-Modified" | tr -d '\r' | cut -d' ' -f2-)
LOCAL_LAST_MODIFIED=""

if [ -f "$CACHE_FILE" ]; then
    LOCAL_LAST_MODIFIED=$(cat "$CACHE_FILE")
fi

if [ "$REMOTE_LAST_MODIFIED" != "$LOCAL_LAST_MODIFIED" ] || [ ! -f "$CLI_EXECUTABLE" ]; then
    echo "Downloading Hytale Downloader CLI..."
    curl -sL "$DOWNLOADER_URL" -o "$DOWNLOADER_DIR/downloader.zip"
    unzip -q -o "$DOWNLOADER_DIR/downloader.zip" "hytale-downloader-linux-amd64" -d "$DOWNLOADER_DIR"
    chmod +x "$CLI_EXECUTABLE"
    echo "$REMOTE_LAST_MODIFIED" > "$CACHE_FILE"
    echo "Hytale Downloader CLI updated."
else
    echo "Hytale Downloader CLI is up-to-date."
fi

# Download/Update Game
echo 'Checking for Hytale Server updates...'
PATCHLINE_ARG=""
if [ ! -z "$HYTALE_PATCHLINE_PRE_RELEASE" ]; then
    PATCHLINE_ARG="-patchline pre-release"
fi

VERSION_FILE="$GAME_DIR/assets/installed_version.txt"
CURRENT_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE")
fi

# Get remote version
# Capture output with a timeout to detect hangs (likely auth requests)
# < /dev/null ensures it usually fails fast, but timeout is the ultimate fallback
OUTPUT=$(timeout 5s $CLI_EXECUTABLE -print-version $PATCHLINE_ARG < /dev/null 2>&1 || true)
EXIT_CODE=$?

# Check for authentication prompts OR timeout (124)
if [ $EXIT_CODE -eq 124 ] || echo "$OUTPUT" | grep -qi "oauth"; then
    echo "Authentication required (or check timed out)."
    # Run interactively (without capture) to allow user input
    $CLI_EXECUTABLE -print-version $PATCHLINE_ARG

    # Retry capturing version after (presumed) successful login
    OUTPUT=$($CLI_EXECUTABLE -print-version $PATCHLINE_ARG < /dev/null 2>&1 || true)
fi

# Extract version from output
REMOTE_VERSION=$(echo "$OUTPUT" | tail -n 1 | tr -d '\r')
    
NEEDS_UPDATE=false
if [ -z "$REMOTE_VERSION" ]; then
    echo "Error: Could not determine remote version."
    exit 1
elif [ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]; then
    echo "New version available: $REMOTE_VERSION (Current: ${CURRENT_VERSION:-"None"})"
    NEEDS_UPDATE=true
elif [ ! -f "$GAME_DIR/assets/Server/HytaleServer.jar" ]; then
    echo "Server files missing. Downloading..."
    NEEDS_UPDATE=true
else
    echo "Game is up to date ($CURRENT_VERSION)."
fi

if [ "$NEEDS_UPDATE" = "true" ]; then
    # Run downloader
    $CLI_EXECUTABLE -download-path "$GAME_DIR/game.zip" $PATCHLINE_ARG -skip-update-check

    # Extract game.zip to /server/assets
    if [ -f "$GAME_DIR/game.zip" ]; then
        echo 'Extracting game.zip...'
        # Ensure target directory exists
        mkdir -p "$GAME_DIR/assets"
        unzip -q -o "$GAME_DIR/game.zip" -d "$GAME_DIR/assets"
        
        # Save version
        if [ ! -z "$REMOTE_VERSION" ]; then
            echo "$REMOTE_VERSION" > "$VERSION_FILE"
        fi
        
        # Clean up zip
        rm "$GAME_DIR/game.zip" 
    else
        echo 'Error: game.zip not found after download attempt.'
        exit 1
    fi
fi

# Construct Server Arguments
declare -a SERVER_ARGS
SERVER_ARGS=("--assets" "$GAME_DIR/assets/Assets.zip")

if [ ! -z "$HYTALE_BIND" ]; then
    SERVER_ARGS+=("--bind" "$HYTALE_BIND")
fi

if [ ! -z "$HYTALE_AUTH_MODE" ]; then
    SERVER_ARGS+=("--auth-mode" "$HYTALE_AUTH_MODE")
fi

if [ "$HYTALE_ALLOW_OP" == "true" ]; then
    SERVER_ARGS+=("--allow-op")
fi

if [ "$HYTALE_BACKUP_ENABLED" != "false" ]; then
    SERVER_ARGS+=("--backup")
fi

if [ ! -z "$HYTALE_BACKUP_DIR" ]; then
    SERVER_ARGS+=("--backup-dir" "$HYTALE_BACKUP_DIR")
else
     SERVER_ARGS+=("--backup-dir" "$GAME_DIR/backups")
fi

if [ ! -z "$HYTALE_BACKUP_FREQ" ]; then
    SERVER_ARGS+=("--backup-frequency" "$HYTALE_BACKUP_FREQ")
fi

if [ "$HYTALE_ACCEPT_EARLY_PLUGINS" == "true" ]; then
    SERVER_ARGS+=("--accept-early-plugins")
fi

if [ ! -z "$HYTALE_SERVER_OWNER_NAME" ]; then
    SERVER_ARGS+=("--owner-name" "$HYTALE_SERVER_OWNER_NAME")
fi

# Add any other passed arguments
SERVER_ARGS+=("$@")

# Update config.json with environment variables
CONFIG_FILE="$GAME_DIR/hytale/config.json"
mkdir -p "$(dirname "$CONFIG_FILE")"

# Initialize config if it doesn't exist or is empty
if [ ! -s "$CONFIG_FILE" ] || [ "$(cat "$CONFIG_FILE")" == "{}" ]; then
    echo "Initializing configuration..."
    JAR_PATH=$(find "$GAME_DIR/assets" -name "HytaleServer.jar" | head -n 1)
    if [ ! -z "$JAR_PATH" ]; then
        # Run with --generate-schema to populate default config files
        # We pass SERVER_ARGS so that any relevant flags (like --assets) are respected
        (cd "$GAME_DIR/hytale" && java -jar "$JAR_PATH" --generate-schema "${SERVER_ARGS[@]}" >/dev/null 2>&1) || true
    fi
fi

# Configure config.json with environment variables
if [ ! -f "$CONFIG_FILE" ]; then
    echo "{}" > "$CONFIG_FILE"
fi

if [ ! -z "$HYTALE_SERVER_NAME" ]; then
    tmp=$(mktemp)
    jq --arg v "$HYTALE_SERVER_NAME" '.ServerName = $v' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
fi

if [ ! -z "$HYTALE_SERVER_MOTD" ]; then
    tmp=$(mktemp)
    jq --arg v "$HYTALE_SERVER_MOTD" '.MOTD = $v' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
fi

if [ ! -z "$HYTALE_SERVER_PASSWORD" ]; then
    tmp=$(mktemp)
    jq --arg v "$HYTALE_SERVER_PASSWORD" '.Password = $v' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
fi

if [ ! -z "$HYTALE_SERVER_MAX_PLAYERS" ]; then
    tmp=$(mktemp)
    jq --argjson v "$HYTALE_SERVER_MAX_PLAYERS" '.MaxPlayers = $v' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
fi

if [ ! -z "$HYTALE_SERVER_MAX_VIEW_RADIUS" ]; then
    tmp=$(mktemp)
    jq --argjson v "$HYTALE_SERVER_MAX_VIEW_RADIUS" '.MaxViewRadius = $v' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
fi

# Prepare to run the server
echo 'Starting Hytale Server...'
mkdir -p "$GAME_DIR/hytale"
cd "$GAME_DIR/hytale"

JAR_PATH=$(find "$GAME_DIR/assets" -name "HytaleServer.jar" | head -n 1)

if [ -z "$JAR_PATH" ]; then
    echo 'Error: HytaleServer.jar not found.'
    exit 1
fi

if [ ! -f "$GAME_DIR/hytale/auth.enc" ]; then
    echo "No auth.enc found. Initiating device authentication flow..."
    SERVER_ARGS+=("--boot-command" "auth login device")
    SERVER_ARGS+=("--boot-command" "auth persistence Encrypted")
fi

# Run server
echo "Running: java -jar $JAR_PATH ${SERVER_ARGS[@]}"
exec java -jar "$JAR_PATH" "${SERVER_ARGS[@]}"
