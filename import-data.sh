#!/bin/bash
# Exit on error, treat unset variables as an error, fail if any command in a pipeline fails
set -euo pipefail

################################################################################
# SCRIPT DESCRIPTION AND REQUIREMENTS
################################################################################
# This script gets data from synapse then imports the data to an model-ad DB.
# This script needs to be run from an model-ad bastion machine, it assumes that
# the bastion is already setup with synapse, mongoimport and mongofiles
# command line clients

################################################################################
# CONFIGURATION SECTION - Modify these values as needed
################################################################################

# Collections Configuration
# Add or remove collection names as needed for your import
# Note: dataversion collection is handled separately and automatically included
readonly COLLECTIONS=(
    "model_details"
    "ui_config"
    "model_overview"
    "disease_correlation"
)

# Database Configuration
readonly DB_NAME="model-ad"  # Target database name

# Don't forget to add indexes in create-indexes.js

################################################################################
# SCRIPT ARGUMENTS AND VALIDATION
################################################################################

# Validate required arguments
if [ $# -ne 5 ]; then
    echo "Usage: $0 <BRANCH> <SYNAPSE_PASSWORD> <DB_HOST> <DB_USER> <DB_PASS>"
    echo ""
    echo "Arguments:"
    echo "  BRANCH           - Git branch name"
    echo "  SYNAPSE_PASSWORD - Synapse authentication password or PAT"
    echo "  DB_HOST          - MongoDB host address"
    echo "  DB_USER          - MongoDB username"
    echo "  DB_PASS          - MongoDB password"
    exit 1
fi

# Assign and validate arguments
readonly BRANCH="$1"
readonly SYNAPSE_PASSWORD="$2"
readonly DB_HOST="$3"
readonly DB_USER="$4"
readonly DB_PASS="$5"

# Validate non-empty arguments
for arg_name in BRANCH SYNAPSE_PASSWORD DB_HOST DB_USER DB_PASS; do
    if [ -z "${!arg_name}" ]; then
        echo "Error: $arg_name cannot be empty"
        exit 1
    fi
done

################################################################################
# SETUP AND INITIALIZATION
################################################################################

# Create secure MongoDB connection string - connect to target database
MONGO_URI="mongodb://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}?authSource=admin"

# Setup paths and directories (needed early for sourcing utilities)
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKING_DIR="${SCRIPT_DIR}"
readonly DATA_DIR="${WORKING_DIR}/data"

# Source logging utilities
if [ -f "${SCRIPT_DIR}/logging-utils.sh" ]; then
    source "${SCRIPT_DIR}/logging-utils.sh"
else
    echo "Error: logging-utils.sh not found"
    exit 1
fi

################################################################################
# ERROR HANDLING AND CLEANUP
################################################################################

# Cleanup function for graceful exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Script failed with exit code $exit_code"
    fi
    # Add any cleanup operations here if needed
    exit $exit_code
}

# Set trap for cleanup on script exit
trap cleanup EXIT

################################################################################
# MAIN SCRIPT EXECUTION
################################################################################

log "Starting data import for branch: $BRANCH"

# Start timing
SCRIPT_START_TIME=$(date +%s)

################################################################################
# FILE SYSTEM PREPARATION
################################################################################

# Create data directory with error checking
if ! mkdir -p "$DATA_DIR"; then
    error "Failed to create data directory $DATA_DIR"
    exit 1
fi

# Validate data-manifest file exists
if [ ! -f "$WORKING_DIR/data-manifest.json" ]; then
    error "data-manifest.json not found in $WORKING_DIR"
    exit 1
fi

################################################################################
# MANIFEST PARSING AND CONFIGURATION
################################################################################

# Parse JSON data from manifest with improved error handling
parse_manifest_data() {
    local manifest_file="$1"

    log "Parsing JSON manifest using built-in tools"
    DATA_VERSION=$(grep -o '"data_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest_file" | sed 's/.*"\([^"]*\)".*/\1/' | head -1)
    DATA_FILE=$(grep -o '"data_file"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest_file" | sed 's/.*"\([^"]*\)".*/\1/' | head -1)

    if [ -z "$DATA_VERSION" ] || [ -z "$DATA_FILE" ]; then
        error "Could not parse data_version or data_file from manifest"
        error "Please ensure the manifest file contains valid JSON with data_version and data_file fields"
        exit 1
    fi

    log "Parsed: DATA_VERSION = $DATA_VERSION, DATA_FILE = $DATA_FILE"
}

parse_manifest_data "$WORKING_DIR/data-manifest.json"

# Expected collections that will be cross-checked before import
readonly EXPECTED_COLLECTIONS=("${COLLECTIONS[@]}" "dataversion")

log "$BRANCH branch, DATA_VERSION = $DATA_VERSION, manifest id = $DATA_FILE"

# Display what will be processed
log "=== Import Configuration ==="
log "Collections to import: ${COLLECTIONS[*]}"
log "Target database: $DB_NAME on $DB_HOST"
log "Expected collections after import: ${EXPECTED_COLLECTIONS[*]}"
log "==============================="

################################################################################
# SYNAPSE DATA DOWNLOAD
################################################################################

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
failed_downloads=0
while IFS=, read -r id version; do
    current_file=$((current_file + 1))
    progress_percent=$((current_file * 100 / total_files))
    log "[$progress_percent%] Downloading file $current_file/$total_files: $id,$version"

    if ! synapse -p "$SYNAPSE_PASSWORD" get --downloadLocation "$DATA_DIR" -v "$version" "$id"; then
        error "Failed to download file $id,$version"
        failed_downloads=$((failed_downloads + 1))

        # Allow a few failed downloads before giving up
        if [ $failed_downloads -gt 3 ]; then
            error "Too many download failures ($failed_downloads). Aborting."
            exit 1
        fi
        warn "Continuing despite download failure ($failed_downloads/3 allowed failures)"
    fi
done < <(tail -n +2 "$DATA_DIR/data_manifest.csv")

if [ $failed_downloads -gt 0 ]; then
    warn "Completed downloads with $failed_downloads failures"
fi

# Calculate synapse download time
SYNAPSE_END_TIME=$(date +%s)
SYNAPSE_DURATION=$((SYNAPSE_END_TIME - SYNAPSE_START_TIME))

log "Data download completed. Listing files:"
ls -al "$WORKING_DIR"
ls -al "$DATA_DIR"

################################################################################
# DATABASE OPERATIONS
################################################################################

# Check if dataversion exists and handle different data format
DATAVERSION_PATH="${DATA_DIR}/dataversion.json"
DATAVERSION_FLAG="--jsonArray"
if [ ! -f "${DATAVERSION_PATH}" ]; then
  DATAVERSION_PATH="${WORKING_DIR}/data-manifest.json"
  DATAVERSION_FLAG=""
fi

# Source the database utility functions
if [ -f "${SCRIPT_DIR}/database-utils.sh" ]; then
    source "${SCRIPT_DIR}/database-utils.sh"
else
    error "database-utils.sh not found"
    exit 1
fi

# Test database connectivity
if ! test_database_connection "$MONGO_URI"; then
    exit 1
fi

# Start database operations timing
DB_START_TIME=$(date +%s)

# Clean up orphaned collections before import
cleanup_orphaned_collections "$MONGO_URI" "${EXPECTED_COLLECTIONS[@]}"

################################################################################
# DATA IMPORT
################################################################################

# Import synapse data to database
log "Starting MongoDB data import..."

# Import collections from array
for collection in "${COLLECTIONS[@]}"; do
    file="${DATA_DIR}/${collection}.json"
    import_collection "$MONGO_URI" "$collection" "$file" "--jsonArray"
done

log "Importing dataversion from ${DATAVERSION_PATH}"
import_collection "$MONGO_URI" "dataversion" "$DATAVERSION_PATH" "$DATAVERSION_FLAG"

# Create database indexes
create_database_indexes "$MONGO_URI" "$WORKING_DIR/create-indexes.js"

################################################################################
# COMPLETION AND SUMMARY
################################################################################

# Calculate database operations time
DB_END_TIME=$(date +%s)
DB_DURATION=$((DB_END_TIME - DB_START_TIME))

# Calculate total script time
SCRIPT_END_TIME=$(date +%s)
SCRIPT_DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

log "=== Execution Time Summary ==="
log_time "$SYNAPSE_DURATION" "Synapse downloads"
log_time "$DB_DURATION" "Database operations"
log_time "$SCRIPT_DURATION" "Total script execution"
log "=============================="
log "Data import completed successfully!"
