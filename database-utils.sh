#!/bin/bash
# Database utility functions for MongoDB operations
# This script contains reusable functions for database cleanup and import operations

# Function to clean up orphaned collections from MongoDB
# This script removes collections that are not in the expected collections list
cleanup_orphaned_collections() {
    local mongo_uri="$1"
    local expected_collections=("${@:2}")

    log "Checking for orphaned collections..."

    # Get list of existing collections (excluding system collections)
    existing_collections=$(mongosh "$mongo_uri" --quiet --eval "
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
        for expected in "${expected_collections[@]}"; do
            if [ "$collection" = "$expected" ]; then
                is_expected=true
                break
            fi
        done

        if [ "$is_expected" = false ]; then
            warn "Found orphaned collection: $collection - removing..."

            # Try to drop the collection with simple error handling
            if mongosh "$mongo_uri" --eval "db.getCollection('$collection').drop()" >/dev/null 2>&1; then
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

# Function to import a collection with error checking
import_collection() {
    local mongo_uri="$1"
    local collection="$2"
    local file="$3"
    local flags="${4:-"--jsonArray"}"

    if [ ! -f "$file" ]; then
        warn "File $file not found, skipping collection $collection"
        return 0
    fi

    log "Replacing collection: $collection from $file"
    # Drop just this collection to ensure clean state
    mongosh "$mongo_uri" --eval "db.getCollection('$collection').drop()" >/dev/null 2>&1

    if ! mongoimport --uri="$mongo_uri" --collection "$collection" $flags --file "$file"; then
        error "Failed to import collection $collection"
        exit 1
    fi
}

# Function to test database connectivity
test_database_connection() {
    local mongo_uri="$1"

    log "Testing database connectivity..."
    if ! mongosh "$mongo_uri" --eval "db.runCommand('ping')" --quiet >/dev/null 2>&1; then
        error "Failed to connect to database"
        return 1
    fi
    log "Database connection successful"
    return 0
}

# Function to create indexes from a JavaScript file
create_database_indexes() {
    local mongo_uri="$1"
    local index_file="$2"

    if [ -f "$index_file" ]; then
        log "Creating database indexes from $index_file..."
        if ! mongosh "$mongo_uri" "$index_file"; then
            error "Failed to create indexes"
            return 1
        fi
        log "Database indexes created successfully"
    else
        warn "Index file $index_file not found, skipping index creation"
    fi
    return 0
}
