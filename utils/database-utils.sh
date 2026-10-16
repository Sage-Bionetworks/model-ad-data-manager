#!/bin/bash
# Database utility functions for MongoDB operations
# This script contains reusable functions for database cleanup and import operations
# Requires logging-utils.sh to be sourced for log, warn, and error functions

# SECURITY NOTE: All functions accept credentials as separate parameters
# instead of embedded in URIs to prevent credential exposure in process lists

# Suffix for the staging collections used by the atomic import. Staging
# collections hold the incoming release while the previous release stays live.
readonly STAGING_SUFFIX="_staging"

# Function to run a mongosh script and echo its output
run_mongo_eval() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"
    local script="$4"

    mongosh "$mongo_uri" --username "$mongo_user" --password "$mongo_pass" --quiet --eval "$script"
}

# Function to render arguments as a JavaScript array literal of strings
to_js_string_array() {
    local quoted
    quoted=$(printf '"%s",' "$@")
    echo "[${quoted%,}]"
}

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

# Function to drop the staging collections left behind by a failed import
# A run that fails partway can leave staging collections behind, so they are
# cleared before the next import.
drop_staging_collections() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"

    log "Checking for leftover staging collections (*${STAGING_SUFFIX})..."

    local dropped
    if ! dropped=$(run_mongo_eval "$mongo_uri" "$mongo_user" "$mongo_pass" "
        const names = db.getCollectionNames()
            .filter(name => name.endsWith('${STAGING_SUFFIX}'));
        names.forEach(name => db.getCollection(name).drop());
        print(names.join(' '));
    "); then
        error "Failed to drop leftover staging collections"
        exit 1
    fi

    if [ -n "$dropped" ]; then
        warn "Dropped leftover staging collections: $dropped"
    else
        log "No leftover staging collections found"
    fi
}

# Function to import a collection into its staging collection with error checking
# The live collection is left untouched so it keeps serving the previous release
# until swap_staging_collections renames the staging collection over it.
import_staging_collection() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"
    local collection="$4"
    local file="$5"
    # Only default when the argument is omitted: the dataversion import passes
    # an empty value on purpose when its source file holds a single document
    local flags="${6-"--jsonArray"}"
    local staging_collection="${collection}${STAGING_SUFFIX}"

    if [ ! -f "$file" ]; then
        error "File $file not found for collection $collection"
        exit 1
    fi

    log "Importing staging collection: $staging_collection from $file"

    # Use --maintainInsertionOrder for ui_config to preserve order of UI elements
    local order_flag=""
    if [ "$collection" = "ui_config" ]; then
        order_flag="--maintainInsertionOrder"
    fi

    # --drop targets the staging collection, never the live one, so it only
    # guarantees a clean target in case a leftover staging collection survived
    if ! mongoimport --uri="$mongo_uri" --username "$mongo_user" --password "$mongo_pass" --collection "$staging_collection" --drop $flags --file "$file" $order_flag; then
        error "Failed to import collection $staging_collection"
        exit 1
    fi
}

# Function to verify that every staging collection loaded before swapping
# Guards against swapping in a collection that is missing or silently empty
verify_staging_collections() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"
    local collections=("${@:4}")

    log "Verifying staging collections before swap..."

    local empty
    if ! empty=$(run_mongo_eval "$mongo_uri" "$mongo_user" "$mongo_pass" "
        const empty = $(to_js_string_array "${collections[@]}")
            .map(name => name + '${STAGING_SUFFIX}')
            .filter(name => db.getCollection(name).countDocuments() === 0);
        print(empty.join(' '));
    "); then
        error "Failed to verify staging collections"
        exit 1
    fi

    if [ -n "$empty" ]; then
        error "Staging collections are missing or empty: $empty"
        error "Aborting before the swap - the previous release is still live"
        exit 1
    fi

    log "All staging collections contain documents"
}

# Function to swap staging collections in as the live collections
# renameCollection with dropTarget replaces the live collection in a single
# metadata-only operation, so it goes straight from the previous release to the
# new one (verified on DocumentDB 8.0.0, see MG-1171). All renames run in one
# mongosh session so the window of mixed releases stays as short as possible.
# The caller must list dataversion last so it only changes once every other
# collection is live.
swap_staging_collections() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"
    local collections=("${@:4}")

    log "Swapping ${#collections[@]} staging collections into place..."

    # Each rename prints SWAPPED or FAILED, so a failure partway through can
    # still report exactly which collections are on which release
    # The || keeps set -e from exiting before the swapped collections are reported
    local output
    local status=0
    output=$(run_mongo_eval "$mongo_uri" "$mongo_user" "$mongo_pass" "
        for (const name of $(to_js_string_array "${collections[@]}")) {
            try {
                db.getCollection(name + '${STAGING_SUFFIX}').renameCollection(name, true);
                print('SWAPPED ' + name);
            } catch (e) {
                print('FAILED ' + name + ' ' + e.message);
                quit(1);
            }
        }
    ") || status=$?

    local swapped=()
    local line
    while IFS= read -r line; do
        case "$line" in
            "SWAPPED "*)
                swapped+=("${line#SWAPPED }")
                log "Swapped in collection: ${line#SWAPPED }"
                ;;
            "FAILED "*)
                error "Failed to swap staging collection into ${line#FAILED }"
                ;;
        esac
    done <<< "$output"

    if [ $status -ne 0 ] || [ ${#swapped[@]} -ne ${#collections[@]} ]; then
        if [ ${#swapped[@]} -eq 0 ]; then
            error "Swap failed before any collection was swapped, so the previous release is still fully live"
            error "Check the error above, then re-run the failed deploy job in GitHub Actions"
            exit 1
        fi

        local remaining=()
        local collection
        for collection in "${collections[@]}"; do
            [[ " ${swapped[*]} " == *" $collection "* ]] || remaining+=("$collection")
        done

        error "Swap failed partway: ${#swapped[@]} of ${#collections[@]} collections were swapped before the error"
        error "On the new release: ${swapped[*]}"
        error "Still on the previous release: ${remaining[*]}"
        error "The APIs are now serving a mix of the two releases. dataversion was not updated, so the API caches"
        error "were not cleared: responses cached before the swap show the previous release, and the rest come from"
        error "the database, which now has a mix of new and old collections"
        error "To fix it, check the error above, then re-run the failed deploy job in GitHub Actions."
        error "The re-run starts the import over, including the Synapse download"
        exit 1
    fi

    log "All collections swapped in successfully"
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

# Function to create indexes on the staging collections
# renameCollection carries indexes over with the collection, so building them
# here means a collection is never served unindexed after it is swapped in.
create_staging_indexes() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"
    local index_file="$4"

    log "Creating staging collection indexes from $index_file"
    if [ -f "$index_file" ]; then
        if ! COLLECTION_SUFFIX="$STAGING_SUFFIX" mongosh "$mongo_uri" --username "$mongo_user" --password "$mongo_pass" "$index_file"; then
            error "Failed to create staging collection indexes"
            exit 1
        fi
        log "Staging collection indexes created successfully"
    else
        warn "Index file $index_file not found, skipping index creation"
    fi
}

# Function to log database storage use
# The staging collections roughly double the imported data until they are
# swapped in, so the sizes are logged either side of the swap.
log_database_storage() {
    local mongo_uri="$1"
    local mongo_user="$2"
    local mongo_pass="$3"
    local label="$4"

    local stats
    if ! stats=$(run_mongo_eval "$mongo_uri" "$mongo_user" "$mongo_pass" "
        const stats = db.stats(1024 * 1024);
        print([
            'collections=' + stats.collections,
            'dataSize=' + Math.round(stats.dataSize || 0) + 'MB',
            'storageSize=' + Math.round(stats.storageSize || 0) + 'MB',
            'indexSize=' + Math.round(stats.indexSize || 0) + 'MB',
        ].join(' '));
    "); then
        warn "Could not read database storage stats ($label)"
        return 0
    fi

    log "Database storage ($label): $stats"
}
