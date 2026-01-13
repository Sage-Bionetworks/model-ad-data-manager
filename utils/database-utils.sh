#!/bin/bash
# Database utility functions for MongoDB operations
# This script contains reusable functions for database cleanup and import operations
# Requires logging-utils.sh to be sourced for log, warn, and error functions

# SECURITY NOTE: All functions accept credentials as separate parameters
# instead of embedded in URIs to prevent credential exposure in process lists

# Function to clean up orphaned collections from MongoDB
# This script removes collections that are not in the expected collections list
cleanup_orphaned_collections() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"
    local expected_collections=("${@:4}")

    log "Checking for orphaned collections..."

    # Get list of existing collections (excluding system collections)
    existing_collections=$(mongosh "$mongo_uri" --username "$mongo_user" --password "$mongo_pass" --quiet --eval "
        db.getCollectionNames()
            .filter(name => !name.startsWith('system.'))
            .join(' ')
    " 2>/dev/null || echo "")

    if [ -z "$existing_collections" ]; then
        log "No existing collections found"
        return 0
    fi

    # Log all found collections
    log "Found existing collections: $existing_collections"

    # Track cleanup results
    cleanup_warnings=0
    cleaned_collections=()
    failed_collections=()
    expected_found=()

    # Check each existing collection against expected list
    for collection in $existing_collections; do
        is_expected=false
        for expected in "${expected_collections[@]}"; do
            if [ "$collection" = "$expected" ]; then
                is_expected=true
                expected_found+=("$collection")
                break
            fi
        done

        if [ "$is_expected" = false ]; then
            warn "Found orphaned collection: $collection - removing..."

            # Try to drop the collection with simple error handling
            if mongosh "$mongo_uri" --username "$mongo_user" --password "$mongo_pass" --eval "db.getCollection('$collection').drop()" >/dev/null 2>&1; then
                log "Removed orphaned collection: $collection"
                cleaned_collections+=("$collection")
            else
                warn "Failed to remove orphaned collection: $collection (may be system-managed)"
                failed_collections+=("$collection")
                cleanup_warnings=$((cleanup_warnings + 1))
            fi
        fi
    done

    # Report expected collections found
    if [ ${#expected_found[@]} -gt 0 ]; then
        log "Expected collections found: ${expected_found[*]}"
    fi

    # Report cleanup results
    if [ ${#cleaned_collections[@]} -gt 0 ]; then
        log "Successfully cleaned up collections: ${cleaned_collections[*]}"
    fi

    if [ ${#failed_collections[@]} -gt 0 ]; then
        warn "Failed to clean up collections: ${failed_collections[*]}"
    fi

    # Final summary
    if [ $cleanup_warnings -gt 0 ]; then
        warn "Orphaned collection cleanup completed with $cleanup_warnings warnings (${#cleaned_collections[@]} removed, ${#failed_collections[@]} failed)"
    elif [ ${#cleaned_collections[@]} -gt 0 ]; then
        log "Orphaned collection cleanup completed successfully (${#cleaned_collections[@]} collections removed)"
    else
        log "No orphaned collections found - database is clean"
    fi
}

# Function to import a collection with error checking
import_collection() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"
    local collection="$4"
    local file="$5"
    local flags="${6:-"--jsonArray"}"

    if [ ! -f "$file" ]; then
        error "File $file not found for collection $collection"
        exit 1
    fi

    log "Replacing collection: $collection from $file"
    # Use --drop flag to let mongoimport handle dropping the collection if it exists
    # Use --maintainInsertionOrder to insert documents in the order they appear in the file
    if ! mongoimport --uri="$mongo_uri" --username "$mongo_user" --password "$mongo_pass" --collection "$collection" --drop $flags --file "$file" --maintainInsertionOrder; then
        error "Failed to import collection $collection"
        exit 1
    fi
}

# Function to test database connectivity
test_database_connection() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"

    log "Testing database connectivity..."
    if ! mongosh "$mongo_uri" --username "$mongo_user" --password "$mongo_pass" --eval "db.runCommand('ping')" --quiet >/dev/null 2>&1; then
        error "Failed to connect to database"
        return 1
    fi
    log "Database connection successful"
    return 0
}

# Function to create database indexes
create_database_indexes() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"
    local index_file="$4"

    log "Creating database indexes from $index_file"
    if [ -f "$index_file" ]; then
        if ! mongosh "$mongo_uri" --username "$mongo_user" --password "$mongo_pass" "$index_file"; then
            error "Failed to create database indexes"
            exit 1
        fi
        log "Database indexes created successfully"
    else
        warn "Index file $index_file not found, skipping index creation"
    fi
}
