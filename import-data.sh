# This script gets data from synapse then imports the data to an model-ad DB.
# This script needs to be run from an model-ad bastion machine, it assumes that
# the bastion is already setup with synapse, mongoimport and mongofiles
# command line clients
#!/bin/bash
set -euo pipefail  # -e (exit on error), -u (treat unset variables as an error), -o pipefail (fail if any command in a pipeline fails)

# Validate required arguments
if [ $# -ne 5 ]; then
    echo "Usage: $0 <BRANCH> <SYNAPSE_PASSWORD> <DB_HOST> <DB_USER> <DB_PASS>"
    exit 1
fi

BRANCH=$1
SYNAPSE_PASSWORD=$2
DB_HOST=$3
DB_USER=$4
DB_PASS=$5

# Database configuration
readonly DB_NAME="model-ad"

# Create secure MongoDB connection string - connect to target database
MONGO_URI="mongodb://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}?authSource=admin"

# Setup logging
log() {
    echo -e "\033[32m[LOG][$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m"
}

warn() {
    echo -e "\033[33m[WARN][$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m" >&2
}

error() {
    echo -e "\033[31m[ERROR][$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m" >&2
}

# Setup paths and directories
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKING_DIR="${SCRIPT_DIR}"
readonly DATA_DIR="${WORKING_DIR}/data"

# Define collections to import (dataversion collection is handled separately)
readonly COLLECTIONS=(
    "model_details"
    "ui_config"
    "model_overview"
    "disease_correlation"
)

# Expected collections for orphaned cleanup (includes dataversion)
readonly EXPECTED_COLLECTIONS=("${COLLECTIONS[@]}" "dataversion")

log "Starting data import for branch: $BRANCH"

# Start timing
SCRIPT_START_TIME=$(date +%s)

# Create data directory with error checking
if ! mkdir -p "$DATA_DIR"; then
    error "Failed to create data directory $DATA_DIR"
    exit 1
fi

# Validate required files exist
if [ ! -f "$WORKING_DIR/data-manifest.json" ]; then
    error "data-manifest.json not found in $WORKING_DIR"
    exit 1
fi

# Parse JSON data from manifest (try jq first, fallback to grep/awk)
if command -v jq &> /dev/null; then
    log "Using jq for JSON parsing"
    DATA_VERSION=$(jq -r '.data_version' "$WORKING_DIR/data-manifest.json")
    DATA_FILE=$(jq -r '.data_file' "$WORKING_DIR/data-manifest.json")

    if [ "$DATA_VERSION" = "null" ] || [ "$DATA_FILE" = "null" ]; then
        error "Could not parse data_version or data_file from manifest"
        exit 1
    fi
else
    warn "jq not found, using grep/awk parsing"
    # Version key/value should be on his own line
    DATA_VERSION=$(cat "$WORKING_DIR/data-manifest.json" | grep data_version | head -1 | awk -F: '{ print $2 }' | sed 's/[",]//g' | tr -d '[[:space:]]')
    DATA_FILE=$(cat "$WORKING_DIR/data-manifest.json" | grep data_file | head -1 | awk -F: '{ print $2 }' | sed 's/[",]//g' | tr -d '[[:space:]]')
fi

log "$BRANCH branch, DATA_VERSION = $DATA_VERSION, manifest id = $DATA_FILE"

# Download the manifest file from synapse
log "Downloading manifest file from Synapse..."

# Start synapse operations timing
SYNAPSE_START_TIME=$(date +%s)

if ! synapse -p "$SYNAPSE_PASSWORD" get --downloadLocation "$DATA_DIR" -v "$DATA_VERSION" "$DATA_FILE"; then
    error "Failed to download manifest file"
    exit 1
fi

# Validate manifest CSV exists
if [ ! -f "$DATA_DIR/data_manifest.csv" ]; then
    error "data_manifest.csv not found after download"
    exit 1
fi

# Download all files referenced in the manifest from synapse
total_files=$(tail -n +2 "$DATA_DIR/data_manifest.csv" | wc -l)
log "Downloading $total_files files from manifest..."

current_file=0
while IFS=, read -r id version; do
    current_file=$((current_file + 1))
    log "Downloading file $current_file/$total_files: $id,$version"
    if ! synapse -p "$SYNAPSE_PASSWORD" get --downloadLocation "$DATA_DIR" -v "$version" "$id"; then
        error "Failed to download file $id,$version"
        exit 1
    fi
done < <(tail -n +2 "$DATA_DIR/data_manifest.csv")

# Calculate synapse download time
SYNAPSE_END_TIME=$(date +%s)
SYNAPSE_DURATION=$((SYNAPSE_END_TIME - SYNAPSE_START_TIME))

log "Data download completed. Listing files:"
ls -al "$WORKING_DIR"
ls -al "$DATA_DIR"

# Check if dataversion exists and handle different data format
DATAVERSION_PATH="${DATA_DIR}/dataversion.json"
DATAVERSION_FLAG="--jsonArray"
if [ ! -f "${DATAVERSION_PATH}" ]; then
  DATAVERSION_PATH="${WORKING_DIR}/data-manifest.json"
  DATAVERSION_FLAG=""
fi

# Test database connectivity
log "Testing database connectivity..."
if ! mongosh "$MONGO_URI" --eval "db.runCommand('ping')" --quiet >/dev/null 2>&1; then
    error "Failed to connect to database"
    exit 1
fi

# Start database operations timing
DB_START_TIME=$(date +%s)

# Function to clean up orphaned collections
cleanup_orphaned_collections() {
    log "Checking for orphaned collections..."

    # Get list of existing collections (excluding system collections)
    existing_collections=$(mongosh "$MONGO_URI" --quiet --eval "
        db.getCollectionNames()
            .filter(name => !name.startsWith('system.'))
            .join(' ')
    " 2>/dev/null || echo "")

    if [ -z "$existing_collections" ]; then
        log "No existing collections found"
        return 0
    fi

    # Track cleanup issues but don't fail the entire script
    cleanup_warnings=0

    # Check each existing collection against expected list
    for collection in $existing_collections; do
        is_expected=false
        for expected in "${EXPECTED_COLLECTIONS[@]}"; do
            if [ "$collection" = "$expected" ]; then
                is_expected=true
                break
            fi
        done

        if [ "$is_expected" = false ]; then
            warn "Found orphaned collection: $collection - removing..."

            # Try to drop the collection with simple error handling
            if mongosh "$MONGO_URI" --eval "db.getCollection('$collection').drop()" >/dev/null 2>&1; then
                log "Removed orphaned collection: $collection"
            else
                warn "Failed to remove orphaned collection: $collection (may be system-managed)"
                cleanup_warnings=$((cleanup_warnings + 1))
            fi
        fi
    done

    if [ $cleanup_warnings -gt 0 ]; then
        warn "Orphaned collection cleanup completed with $cleanup_warnings warnings"
    else
        log "Orphaned collection cleanup completed successfully"
    fi
}

# Clean up orphaned collections before import
cleanup_orphaned_collections

# Function to import a collection with error checking
import_collection() {
    local collection=$1
    local file=$2
    local flags=${3:-"--jsonArray"}

    if [ ! -f "$file" ]; then
        warn "File $file not found, skipping collection $collection"
        return 0
    fi

    log "Replacing collection: $collection from $file"
    # Drop just this collection to ensure clean state
    mongosh "$MONGO_URI" --eval "db.getCollection('$collection').drop()" >/dev/null 2>&1

    if ! mongoimport --uri="$MONGO_URI" --collection "$collection" $flags --file "$file"; then
        error "Failed to import collection $collection"
        exit 1
    fi
}

# Import synapse data to database
log "Starting MongoDB data import..."

# Import collections from array
for collection in "${COLLECTIONS[@]}"; do
    file="${DATA_DIR}/${collection}.json"
    import_collection "$collection" "$file" "--jsonArray"
done

log "Importing dataversion from ${DATAVERSION_PATH}"
import_collection "dataversion" "$DATAVERSION_PATH" "$DATAVERSION_FLAG"

# Create database indexes
if [ -f "$WORKING_DIR/create-indexes.js" ]; then
    log "Creating database indexes..."
    if ! mongosh "$MONGO_URI" "$WORKING_DIR/create-indexes.js"; then
        error "Failed to create indexes"
        exit 1
    fi
else
    warn "create-indexes.js not found, skipping index creation"
fi

# Calculate database operations time
DB_END_TIME=$(date +%s)
DB_DURATION=$((DB_END_TIME - DB_START_TIME))

# Calculate total script time
SCRIPT_END_TIME=$(date +%s)
SCRIPT_DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

log "=== Execution Time Summary ==="
log "Synapse downloads: ${SYNAPSE_DURATION} seconds"
log "Database operations: ${DB_DURATION} seconds"
log "Total script execution: ${SCRIPT_DURATION} seconds"
log "=============================="
log "Data import completed successfully!"
