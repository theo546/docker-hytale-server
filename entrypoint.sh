#!/bin/bash
set -e

# Logging functions
log_info() {
    local message="$1"
    local timestamp=$(date '+%Y/%m/%d %H:%M:%S')
    printf "[%s   INFO] [Entrypoint] %s\n" "$timestamp" "$message"
}

log_warn() {
    local message="$1"
    local timestamp=$(date '+%Y/%m/%d %H:%M:%S')
    printf "\033[33m[%s   WARN] [Entrypoint] %s\033[0m\n" "$timestamp" "$message"
}

log_severe() {
    local message="$1"
    local timestamp=$(date '+%Y/%m/%d %H:%M:%S')
    printf "\033[31m[%s SEVERE] [Entrypoint] %s\033[0m\n" "$timestamp" "$message"
}

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
    log_info "Generating new persistent machine-id..."
    if command -v dbus-uuidgen >/dev/null 2>&1; then
        dbus-uuidgen > "$MACHINE_ID_FILE"
    else
        cat /proc/sys/kernel/random/uuid | tr -d '-' > "$MACHINE_ID_FILE"
    fi
fi

# Apply to system location (writable thanks to Dockerfile permissions)
cp "$MACHINE_ID_FILE" /var/lib/dbus/machine-id

# Downloader CLI Caching
log_info "Checking for Hytale Downloader CLI updates..."
REMOTE_LAST_MODIFIED=$(curl -sI "$DOWNLOADER_URL" | grep -i "Last-Modified" | tr -d '\r' | cut -d' ' -f2-)
LOCAL_LAST_MODIFIED=""

if [ -f "$CACHE_FILE" ]; then
    LOCAL_LAST_MODIFIED=$(cat "$CACHE_FILE")
fi

if [ "$REMOTE_LAST_MODIFIED" != "$LOCAL_LAST_MODIFIED" ] || [ ! -f "$CLI_EXECUTABLE" ]; then
    log_info "Downloading Hytale Downloader CLI..."
    curl -sL "$DOWNLOADER_URL" -o "$DOWNLOADER_DIR/downloader.zip"
    unzip -q -o "$DOWNLOADER_DIR/downloader.zip" "hytale-downloader-linux-amd64" -d "$DOWNLOADER_DIR"
    chmod +x "$CLI_EXECUTABLE"
    echo "$REMOTE_LAST_MODIFIED" > "$CACHE_FILE"
    log_info "Hytale Downloader CLI updated."
else
    log_info "Hytale Downloader CLI is up-to-date."
fi

# Download/update Game
log_info "Checking for Hytale Server updates..."
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
MAX_RETRIES=5
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    SHOULD_RETRY=false
    OUTPUT=""
    
    log_info "Executing Hytale CLI (Attempt $RETRY_COUNT/$MAX_RETRIES)..."
    
    # Process substitution allows us to read output while keeping variable scope
    while IFS= read -r line; do
        # Accumulate output
        OUTPUT="${OUTPUT}${line}
"
        # Check for Auth URL (Supports lowercase now: [a-zA-Z0-9-])
        if [[ "$line" =~ https://oauth.accounts.hytale.com/oauth2/device/verify\?user_code=([a-zA-Z0-9-]+) ]]; then
             log_warn "ACTION REQUIRED: Please authenticate the server by visiting the link below:"
             log_warn "${BASH_REMATCH[0]}"
        fi
        
        # Check for invalid credentials error
        if [[ "$line" == *"403"* ]] || [[ "$line" == *"invalid_grant"* ]]; then
            log_warn "Invalid credentials detected ($line)."
            rm -f "$GAME_DIR/.hytale-downloader-credentials.json"
            SHOULD_RETRY=true
        fi

        # Check for network/server errors
        elif [[ "$line" == *"Client.Timeout"* ]] || [[ "$line" == *"error fetching server manifest"* ]] || [[ "$line" == *"request canceled"* ]]; then
             log_warn "Network/API error detected: $line"
             SHOULD_RETRY=true
             sleep 2
        fi
    done < <($CLI_EXECUTABLE -print-version $PATCHLINE_ARG 2>&1)
    
    if [ "$SHOULD_RETRY" = "true" ]; then
        log_info "Retrying authentication/version check..."
        continue
    else
        break
    fi
done

# Fallback check (if no output or other error)
# We can't get the accurate exit code from process substitution easily in this structure
# but we rely on the output content for validation logic below
EXIT_CODE=0 
if [ -z "$OUTPUT" ]; then EXIT_CODE=1; fi

# Extract version from output (last non-empty line)
REMOTE_VERSION=$(echo "$OUTPUT" | awk 'NF' | tail -n 1 | tr -d '\r')
    
NEEDS_UPDATE=false
if [ -z "$REMOTE_VERSION" ]; then
    log_severe "Error: Could not determine remote version."
    exit 1
elif [ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]; then
    log_info "New version available: $REMOTE_VERSION (Current: ${CURRENT_VERSION:-"None"})"
    NEEDS_UPDATE=true
elif [ ! -f "$GAME_DIR/assets/Server/HytaleServer.jar" ]; then
    log_info "Server files missing. Downloading..."
    NEEDS_UPDATE=true
else
    log_info "Game is up to date ($CURRENT_VERSION)."
fi

if [ "$NEEDS_UPDATE" = "true" ]; then
    # Determine patchline name for logging
    PATCHLINE_NAME="release"
    if [ ! -z "$HYTALE_PATCHLINE_PRE_RELEASE" ]; then
        PATCHLINE_NAME="pre-release"
    fi

    # Run downloader silently with custom log
    log_info "Downloading latest (\"$PATCHLINE_NAME\" patchline) to \"$GAME_DIR/game.zip\""
    $CLI_EXECUTABLE -download-path "$GAME_DIR/game.zip" $PATCHLINE_ARG -skip-update-check >/dev/null 2>&1

    # Extract game.zip to /server/assets
    if [ -f "$GAME_DIR/game.zip" ]; then
        log_info "Extracting game.zip..."
        # Ensure target directory exists
        mkdir -p "$GAME_DIR/assets"
        
        # Cleanup old assets (preserve installed_version.txt)
        find "$GAME_DIR/assets" -mindepth 1 -not -name "installed_version.txt" -delete
        
        # Extract game.zip to /server/assets
        unzip -q -o "$GAME_DIR/game.zip" -d "$GAME_DIR/assets"
        
        # Save version
        if [ ! -z "$REMOTE_VERSION" ]; then
            echo "$REMOTE_VERSION" > "$VERSION_FILE"
        fi
        
        # Clean up zip
        rm "$GAME_DIR/game.zip" 
    else
        log_severe "Error: game.zip not found after download attempt."
        exit 1
    fi
fi

# Construct server arguments
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

if [ -n "$HYTALE_BACKUP_MAX_COUNT" ]; then
    SERVER_ARGS+=("--backup-max-count" "$HYTALE_BACKUP_MAX_COUNT")
fi

if [ "$HYTALE_ACCEPT_EARLY_PLUGINS" == "true" ]; then
    SERVER_ARGS+=("--accept-early-plugins")
fi

if [ "$HYTALE_DISABLE_SENTRY" == "true" ]; then
    SERVER_ARGS+=("--disable-sentry")
fi

if [ -n "$HYTALE_SERVER_OWNER_NAME" ]; then
    SERVER_ARGS+=("--owner-name" "$HYTALE_SERVER_OWNER_NAME")
fi

if [ -n "$HYTALE_SERVER_OWNER_UUID" ]; then
    SERVER_ARGS+=("--owner-uuid" "$HYTALE_SERVER_OWNER_UUID")
fi

if [ -n "$HYTALE_IDENTITY_TOKEN" ]; then
    SERVER_ARGS+=("--identity-token" "$HYTALE_IDENTITY_TOKEN")
fi

if [ -n "$HYTALE_SESSION_TOKEN" ]; then
    SERVER_ARGS+=("--session-token" "$HYTALE_SESSION_TOKEN")
fi

# Add any other passed arguments
SERVER_ARGS+=("$@")

# Update config.json with environment variables
CONFIG_FILE="$GAME_DIR/hytale/config.json"
mkdir -p "$(dirname "$CONFIG_FILE")"

# Initialize config if it doesn't exist or is empty
if [ ! -s "$CONFIG_FILE" ] || [ "$(cat "$CONFIG_FILE")" == "{}" ]; then
    log_info "Initializing configuration..."
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

# Force AuthCredentialStore to use encrypted auth with auth.enc
tmp=$(mktemp)
jq '.AuthCredentialStore = {"Type": "Encrypted", "Path": "auth.enc"}' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

# Prepare to run the server
log_info "Starting Hytale Server..."
mkdir -p "$GAME_DIR/hytale"
cd "$GAME_DIR/hytale"

JAR_PATH=$(find "$GAME_DIR/assets" -name "HytaleServer.jar" | head -n 1)

if [ -z "$JAR_PATH" ]; then
    log_severe "Error: HytaleServer.jar not found."
    exit 1
fi

# Construct safe logging string (mask sensitive tokens)
SERVER_ARGS_LOG="${SERVER_ARGS[*]}"
SERVER_ARGS_LOG=$(echo "$SERVER_ARGS_LOG" | sed -E 's/--identity-token [^ ]+/--identity-token ***/g')
SERVER_ARGS_LOG=$(echo "$SERVER_ARGS_LOG" | sed -E 's/--session-token [^ ]+/--session-token ***/g')

# Determine mode
STREAM_LOGS=true
if [ ! -f "$GAME_DIR/hytale/auth.enc" ]; then
    log_info "auth.enc missing. Starting server in background to monitor authentication..."
    # Add auth commands
    SERVER_ARGS+=("--boot-command" "auth login device")
    SERVER_ARGS+=("--boot-command" "auth persistence Encrypted")
    STREAM_LOGS=false # Don't stream initially, wait for auth
else
    log_info "Running: java -jar $JAR_PATH $SERVER_ARGS_LOG"
fi

# Capture existing logs in a map/associative array to identify the new one later
declare -A PRE_EXISTING_LOGS
shopt -s nullglob
for f in "$GAME_DIR/hytale/logs/"*.log; do
    PRE_EXISTING_LOGS["$f"]=1
done
shopt -u nullglob

# Start in background
# We silence it for BOTH modes because we rely on the tail loop for output
java -jar "$JAR_PATH" "${SERVER_ARGS[@]}" >/dev/null 2>&1 &
SERVER_PID=$!

# Trap SIGTERM to pass to server
trap 'kill -SIGTERM "$SERVER_PID"; wait "$SERVER_PID"' SIGTERM SIGINT

# Wait for new log file (must be one that wasn't in our pre-existing list)
log_info "Waiting for new log file to be created..."
LOG_FILE=""
RETRIES=0
while [ -z "$LOG_FILE" ] && [ $RETRIES -lt 30 ]; do
    sleep 1
    
    # Check for any log file not in PRE_EXISTING_LOGS
    shopt -s nullglob
    for f in "$GAME_DIR/hytale/logs/"*.log; do
        if [ -z "${PRE_EXISTING_LOGS[$f]}" ]; then
            LOG_FILE="$f"
            break
        fi
    done
    shopt -u nullglob
    
    RETRIES=$((RETRIES+1))
done

if [ -z "$LOG_FILE" ]; then
    log_severe "Timed out waiting for log file. Showing server output directly:"
    wait "$SERVER_PID"
    exit 1
fi

log_info "Monitoring log file: $LOG_FILE"

BOOTED=false
TOKEN_ERROR_COUNT=0

# Tail the log file
while IFS= read -r line; do
    
    # 1. Output logic
    if [ "$STREAM_LOGS" = "true" ]; then
        if [[ "$line" == *"WARN"* ]]; then
            printf "\033[33m%s\033[0m\n" "$line"
        elif [[ "$line" == *"SEVERE"* ]]; then
             printf "\033[31m%s\033[0m\n" "$line"
        else
            echo "$line"
        fi
    fi
    
    # 2. Global error checks (active in all modes)
    if [[ "$line" == *"No server tokens configured"* ]]; then
        TOKEN_ERROR_COUNT=$((TOKEN_ERROR_COUNT+1))
        
        if [ "$TOKEN_ERROR_COUNT" -gt 1 ]; then
            if [ -f "$GAME_DIR/hytale/auth.enc" ]; then
                log_severe "Invalid token detected (Persistent). Resetting authentication..."
                kill -SIGTERM "$SERVER_PID"
                rm -f "$GAME_DIR/hytale/auth.enc"
                wait "$SERVER_PID"
                exit 1
            fi
        fi
    fi
    
    if [[ "$line" == *"Device authorization request failed"* ]]; then
         log_severe "Device authorization failed. Stopping server..."
         kill -SIGTERM "$SERVER_PID"
         wait "$SERVER_PID"
         exit 1
    fi
    
    # 3. Auth flow logic (only if not streaming yet)
    if [ "$STREAM_LOGS" = "false" ]; then
        # Wait for boot
        if [ "$BOOTED" = "false" ]; then
            if [[ "$line" == *"Hytale Server Booted!"* ]]; then
                BOOTED=true
                log_info "Hytale Server started! Waiting for authentication prompt..."
            fi
        else
            # Check for auth URL
            shopt -s nocasematch
            if [[ "$line" =~ https://oauth.accounts.hytale.com/oauth2/device/verify\?user_code=([a-z0-9-]+) ]]; then
                 log_warn "ACTION REQUIRED: Please authenticate the server by visiting the link below:"
                 log_warn "${BASH_REMATCH[0]}"
            fi
            
            # Check for auth timeout announcement
            if [[ "$line" =~ Waiting\ for\ authorization\ \(expires\ in\ ([0-9]+)\ seconds\)\.\.\. ]]; then
                TIMEOUT_SEC="${BASH_REMATCH[1]}"
                
                # Start background timer
                (
                    sleep "$TIMEOUT_SEC"
                    log_severe "Authentication timed out after ${TIMEOUT_SEC}s. Killing server..."
                    kill -SIGTERM "$SERVER_PID"
                ) &
                AUTH_TIMEOUT_PID=$!
            fi
            
            # Check for success
            if [[ "$line" == *"Authentication successful"* ]]; then
                log_info "Authentication successful! Streaming logs..."
                echo "$line" # Echo this specific line
                STREAM_LOGS=true
                
                # Kill timer
                if [ ! -z "$AUTH_TIMEOUT_PID" ]; then
                    kill "$AUTH_TIMEOUT_PID" 2>/dev/null || true
                fi
            fi
            shopt -u nocasematch
        fi
    fi
done < <(tail -F --pid=$SERVER_PID "$LOG_FILE")

# Wait for server to exit
wait "$SERVER_PID"
