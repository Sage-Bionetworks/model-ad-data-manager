#!/bin/bash

################################################################################
# SYNAPSE UTILITIES
################################################################################
# This file contains utility functions for interacting with Synapse data
# Requires logging-utils.sh to be sourced for log, warn, and error functions

################################################################################
# MANIFEST PARSING FUNCTIONS
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
        return 1
    fi

    log "Parsed: DATA_VERSION = $DATA_VERSION, DATA_FILE = $DATA_FILE"
    return 0
}

################################################################################
# SYNAPSE DOWNLOAD FUNCTIONS
################################################################################

# Download manifest file from Synapse
download_manifest_file() {
    local synapse_password="$1"
    local data_dir="$2"
    local data_version="$3"
    local data_file="$4"

    log "Downloading manifest file from Synapse..."

    if ! synapse -p "$synapse_password" get --downloadLocation "$data_dir" -v "$data_version" "$data_file"; then
        error "Failed to download manifest file"
        return 1
    fi

    # Validate manifest CSV exists
    if [ ! -f "$data_dir/data_manifest.csv" ]; then
        error "data_manifest.csv not found after download"
        return 1
    fi

    return 0
}

# Download all files referenced in the manifest from Synapse
download_manifest_files() {
    local synapse_password="$1"
    local data_dir="$2"

    local manifest_csv="$data_dir/data_manifest.csv"

    if [ ! -f "$manifest_csv" ]; then
        error "Manifest CSV file not found: $manifest_csv"
        return 1
    fi

    # Download all files referenced in the manifest from synapse
    local total_files=$(tail -n +2 "$manifest_csv" | wc -l)
    log "Downloading $total_files files from manifest..."

    local current_file=0

    while IFS=, read -r id version; do
        current_file=$((current_file + 1))
        local progress_percent=$((current_file * 100 / total_files))
        log "[$progress_percent%] Downloading file $current_file/$total_files: $id,$version"

        if ! synapse -p "$synapse_password" get --downloadLocation "$data_dir" -v "$version" "$id"; then
            error "Failed to download file $id,$version"
            error "Download failed. Aborting."
            return 1
        fi
    done < <(tail -n +2 "$manifest_csv")

    return 0
}

# Complete Synapse data download workflow
download_synapse_data() {
    local synapse_password="$1"
    local data_dir="$2"
    local data_version="$3"
    local data_file="$4"

    # Download manifest file
    if ! download_manifest_file "$synapse_password" "$data_dir" "$data_version" "$data_file"; then
        return 1
    fi

    # Download all files from manifest
    if ! download_manifest_files "$synapse_password" "$data_dir"; then
        return 1
    fi

    log "Data download completed"
    return 0
}

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Validate Synapse CLI is available
validate_synapse_cli() {
    if ! command -v synapse &> /dev/null; then
        error "Synapse CLI not found. Please ensure it is installed and in PATH"
        return 1
    fi
    return 0
}

# List downloaded files for verification
list_downloaded_files() {
    local working_dir="$1"
    local data_dir="$2"

    log "Data download completed. Listing files:"
    ls -al "$working_dir"
    ls -al "$data_dir"
}
