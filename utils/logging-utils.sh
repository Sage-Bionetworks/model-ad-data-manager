#!/bin/bash
# Logging utility functions for consistent output formatting
# Provides colored log messages with timestamps

# Setup logging functions
log() {
    echo -e "\033[32m[LOG][$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m"
}

warn() {
    echo -e "\033[33m[WARN][$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m" >&2
}

error() {
    echo -e "\033[31m[ERROR][$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m" >&2
}

# Additional logging functions for different levels
info() {
    echo -e "\033[36m[INFO][$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m"
}

debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo -e "\033[35m[DEBUG][$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m" >&2
    fi
}

# Function to log execution time
log_time() {
    local duration=$1
    local description=$2
    log "$description: ${duration} seconds"
}
