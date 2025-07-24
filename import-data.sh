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

# Expected collections that will be cross-checked before import (including dataversion)
readonly EXPECTED_COLLECTIONS=("${COLLECTIONS[@]}" "dataversion")

# Don't forget to add indexes in create-indexes.js

################################################################################
# PATH CONFIGURATION
################################################################################

# Setup paths and directories (needed early for sourcing utilities)
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKING_DIR="${SCRIPT_DIR}"
readonly DATA_DIR="${WORKING_DIR}/data"

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
BRANCH="$1"
SYNAPSE_PASSWORD="$2"
DB_HOST="$3"
DB_USER="$4"
DB_PASS="$5"

# Validate non-empty arguments
for arg_name in BRANCH SYNAPSE_PASSWORD DB_HOST DB_USER DB_PASS; do
    if [ -z "${!arg_name}" ]; then
        echo "Error: $arg_name cannot be empty"
        exit 1
    fi
done

# Security: Prevent credential variables from being exported to child processes
export -n SYNAPSE_PASSWORD DB_USER DB_PASS 2>/dev/null || true

################################################################################
# SETUP AND INITIALIZATION
################################################################################

# Create secure MongoDB connection string - credentials passed separately
readonly MONGO_URI="mongodb://${DB_HOST}/${DB_NAME}?authSource=admin"
readonly MONGO_USER="$DB_USER"
readonly MONGO_PASS="$DB_PASS"

# Clear original credential variables for security
unset DB_USER DB_PASS

# Source logging utilities
if [ -f "${SCRIPT_DIR}/utils/logging-utils.sh" ]; then
    source "${SCRIPT_DIR}/utils/logging-utils.sh"
else
    echo "Error: utils/logging-utils.sh not found"
    exit 1
fi

# Source synapse utilities
if [ -f "${SCRIPT_DIR}/utils/synapse-utils.sh" ]; then
    source "${SCRIPT_DIR}/utils/synapse-utils.sh"
else
    error "utils/synapse-utils.sh not found"
    exit 1
fi

# Source database utilities
if [ -f "${SCRIPT_DIR}/utils/database-utils.sh" ]; then
    source "${SCRIPT_DIR}/utils/database-utils.sh"
else
    error "utils/database-utils.sh not found"
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

parse_manifest_data "$WORKING_DIR/data-manifest.json"

log "$BRANCH branch, DATA_VERSION = $DATA_VERSION, manifest id = $DATA_FILE"

# Display what will be processed
log "=== Import Configuration ==="
log "Collections to import: ${COLLECTIONS[*]}"
log "Expected collections after import: ${EXPECTED_COLLECTIONS[*]}"
log "==============================="

################################################################################
# SYNAPSE DATA DOWNLOAD
################################################################################

# Validate Synapse CLI is available
if ! validate_synapse_cli; then
    exit 1
fi

# Start synapse operations timing
SYNAPSE_START_TIME=$(date +%s)

# Download all Synapse data
if ! download_synapse_data "$SYNAPSE_PASSWORD" "$DATA_DIR" "$DATA_VERSION" "$DATA_FILE"; then
    exit 1
fi

# Calculate synapse download time
SYNAPSE_END_TIME=$(date +%s)
SYNAPSE_DURATION=$((SYNAPSE_END_TIME - SYNAPSE_START_TIME))

# List downloaded files for verification
list_downloaded_files "$WORKING_DIR" "$DATA_DIR"

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

# Test database connectivity
if ! test_database_connection "$MONGO_URI" "$MONGO_USER" "$MONGO_PASS"; then
    exit 1
fi

# Start database operations timing
DB_START_TIME=$(date +%s)

# Clean up orphaned collections before import
cleanup_orphaned_collections "$MONGO_URI" "$MONGO_USER" "$MONGO_PASS" "${EXPECTED_COLLECTIONS[@]}"

################################################################################
# DATA IMPORT
################################################################################

# Import synapse data to database
log "Starting MongoDB data import..."

# Import collections from array
for collection in "${COLLECTIONS[@]}"; do
    file="${DATA_DIR}/${collection}.json"
    import_collection "$MONGO_URI" "$MONGO_USER" "$MONGO_PASS" "$collection" "$file" "--jsonArray"
done

log "Importing dataversion from ${DATAVERSION_PATH}"
import_collection "$MONGO_URI" "$MONGO_USER" "$MONGO_PASS" "dataversion" "$DATAVERSION_PATH" "$DATAVERSION_FLAG"

# Create database indexes
create_database_indexes "$MONGO_URI" "$MONGO_USER" "$MONGO_PASS" "$WORKING_DIR/create-indexes.js"

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
