#!/bin/bash

# Upload to Modoboa IMAP Script v42.0.11
# Changes from v41:
# - Fixed verification to prevent duplicate uploads
# - Changed to file-based locks instead of directories
# - Added better message existence checking
# - Improved error detection and handling
# Security Requirements:
# - SSL/TLS required for all connections
# - Secure credential handling
# - Atomic operations for all file updates
# - Clean error handling

# Command line options
RESET_MODE=false
FORCE_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --reset)
            RESET_MODE=true
            shift
            ;;
        --force)
            FORCE_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--reset] [--force]"
            echo "  --reset  Clear all progress and start fresh"
            echo "  --force  Force upload even if messages exist"
            exit 1
            ;;
    esac
done

# Configuration
SOURCE_EMAIL="username@domain.tld"
DEST_SERVER="mailhost.subdomain.domain.tld" # can be just mailhost.domain.tld too
DEST_PORT="993"
DEST_USER="$SOURCE_EMAIL"
DEST_PASS="passwordhere"
LOGFILE="upload.log"
STATS_FILE="upload_stats.json"
VALIDATION_FILE="upload_validation.json"
STATS_DIR="stats"
TEMP_DIR="/tmp/modoboa_upload_$$"  # Process-specific temp directory
PROCESSED_DIR="$STATS_DIR/processed"
JOBS_DIR="$STATS_DIR/jobs"
LOCK_DIR="$STATS_DIR/locks"
UPLOAD_TRACKING_DIR="$STATS_DIR/uploads"
MESSAGE_CACHE_DIR="$STATS_DIR/message_cache"  # New: Cache for message states




# IMAP connection configuration
OPENSSL_OPTS="-quiet -verify_hostname -verify_peer -tls1_2"

# Processing configuration
MAX_RETRIES=2  # Reduced to prevent excessive retries
REQUEST_DELAY=0.5
RETRY_DELAY=2  # Reduced to speed up retries
VERIFY_DELAY=1  # New: Delay before verification

# Stats file paths
TOTAL_MESSAGES_FILE="$STATS_DIR/upload_total_messages"
TOTAL_SIZE_FILE="$STATS_DIR/upload_total_size"
TOTAL_FAILED_FILE="$STATS_DIR/upload_total_failed"
TOTAL_SKIPPED_FILE="$STATS_DIR/upload_total_skipped"

# ====================
# Core Utility Functions
# ====================

# Function to log messages with timestamps and tee to logfile
log_message() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOGFILE"
}

# Cleanup function for temp files and processes
cleanup() {
    local exit_code=$?
    log_message "Performing cleanup..."
    
    # Kill any remaining background jobs
    local running_jobs
    running_jobs=$(jobs -p)
    if [ ! -z "$running_jobs" ]; then
        log_message "Terminating remaining background jobs..."
        kill -9 $running_jobs 2>/dev/null || true
    fi
    
    # Remove temporary directory and files
    if [ -d "$TEMP_DIR" ]; then
        log_message "Removing temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
    
    # Release any remaining locks
    find "$LOCK_DIR" -type f -name "*.lock" -exec flock -u {} \; 2>/dev/null || true
    
    exit $exit_code
}

# Function to acquire lock with timeout
acquire_lock() {
    local lock_file="$1"
    local timeout="${2:-5}"  # Default timeout 5 seconds
    local start_time=$(date +%s)
    
    # Ensure parent directory exists
    mkdir -p "$(dirname "$lock_file")"
    
    while true; do
        if (set -o noclobber; echo $$ > "$lock_file") 2>/dev/null; then
            # Lock acquired successfully
            chmod 600 "$lock_file"
            return 0
        fi
        
        # Check if lock is stale
        if [ -f "$lock_file" ]; then
            local lock_pid
            lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
            if [ ! -z "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
                # Remove stale lock
                rm -f "$lock_file"
                continue
            fi
        fi
        
        # Check timeout
        if [ $(($(date +%s) - start_time)) -ge "$timeout" ]; then
            return 1
        fi
        
        sleep 0.1
    done
}

# # Function to release lock
# release_lock() {
#     local lock_file="$1"
#     if [ -f "$lock_file" ] && [ "$(cat "$lock_file" 2>/dev/null)" = "$$" ]; then
#         flock -u "$lock_file" 2>/dev/null
#         rm -f "$lock_file"
#     fi
# }
# Function to release lock
release_lock() {
    local lock_file="$1"
    if [ -f "$lock_file" ] && [ "$(cat "$lock_file" 2>/dev/null)" = "$$" ]; then
        rm -f "$lock_file"
    fi
}



# Function to reset all progress
reset_progress() {
    log_message "Resetting all progress..."
    
    # Remove statistics directory and all contents
    if [ -d "$STATS_DIR" ]; then
        rm -rf "$STATS_DIR"
        log_message "Removed statistics directory"
    fi
    
    # Remove tracking files
    rm -f "$STATS_FILE" "$VALIDATION_FILE"
    log_message "Removed tracking files"
    
    # Remove any temporary files
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log_message "Removed temporary directory"
    fi
    
    log_message "Reset complete"
}

# Function to initialize directories with proper permissions
init_directories() {
    log_message "Initializing directory structure..."
    
    # Reset if requested
    if [ "$RESET_MODE" = "true" ]; then
        reset_progress
    fi
    
    # Create main directories with proper permissions
    mkdir -p "$STATS_DIR" "$PROCESSED_DIR" "$JOBS_DIR" "$LOCK_DIR" "$UPLOAD_TRACKING_DIR" "$MESSAGE_CACHE_DIR"
    chmod 755 "$STATS_DIR" "$PROCESSED_DIR" "$JOBS_DIR" "$LOCK_DIR" "$UPLOAD_TRACKING_DIR" "$MESSAGE_CACHE_DIR"
    
    # Create temp directory with secure permissions
    rm -rf "$TEMP_DIR"  # Clean up any existing temp dir
    mkdir -p "$TEMP_DIR"
    chmod 700 "$TEMP_DIR"
    
    # Create and initialize counter files atomically
    for counter_file in "$TOTAL_MESSAGES_FILE" "$TOTAL_SIZE_FILE" "$TOTAL_FAILED_FILE" "$TOTAL_SKIPPED_FILE"; do
        echo "0" > "$counter_file"
        chmod 644 "$counter_file"
    done
    
    # Create subdirectories
    mkdir -p "$STATS_DIR/upload_folders"
    mkdir -p "$STATS_DIR/upload_validation"
    chmod 755 "$STATS_DIR/upload_folders" "$STATS_DIR/upload_validation"
    
    # Initialize tracking files with proper permissions
    echo "{}" > "$STATS_FILE"
    chmod 644 "$STATS_FILE"
    
    log_message "Directory structure initialized"
    if [ "$RESET_MODE" = "true" ]; then
        log_message "Starting fresh upload process"
    fi
    if [ "$FORCE_MODE" = "true" ]; then
        log_message "Force mode enabled - will upload even if messages exist"
    fi
}

# Set cleanup trap
trap cleanup EXIT INT TERM

# End of Part 1# Beginning of Part 2

# ====================
# File Operation Functions
# ====================

# Function to write job status with atomic operation
write_job_status() {
    local job_id="$1"
    local status="$2"
    local message="$3"
    local job_file="$JOBS_DIR/job_${job_id}"
    local lock_file="$LOCK_DIR/job_${job_id}.lock"
    
    # Write status atomically with proper locking
    if acquire_lock "$lock_file" 5; then
        echo "${status}:${message}:$(date '+%Y-%m-%d %H:%M:%S')" > "$job_file"
        chmod 644 "$job_file"
        release_lock "$lock_file"
        return 0
    else
        log_message "Failed to acquire lock for job status update: $job_id"
        return 1
    fi
}

# Function to increment counter with proper locking
increment_counter() {
    local counter_file="$1"
    local increment_value="$2"
    local lock_file="$LOCK_DIR/$(basename "$counter_file").lock"
    local success=false
    local retries=0
    
    while [ $retries -lt $MAX_RETRIES ] && [ "$success" = "false" ]; do
        if acquire_lock "$lock_file" 5; then
            local current_value
            current_value=$(cat "$counter_file" 2>/dev/null || echo 0)
            echo "$((current_value + increment_value))" > "$counter_file"
            chmod 644 "$counter_file"
            success=true
            release_lock "$lock_file"
        else
            log_message "Failed to acquire lock for counter increment, attempt $((retries + 1))"
            retries=$((retries + 1))
            sleep 1
        fi
    done
    
    if [ "$success" = "false" ]; then
        log_message "Failed to increment counter after $MAX_RETRIES attempts: $counter_file"
        return 1
    fi
    
    return 0
}


# Function to cache message state
cache_message_state() {
    local folder_name="$1"
    local message_id="$2"
    local state="$3"  # "uploaded", "skipped", or "failed"
    local cache_file="$MESSAGE_CACHE_DIR/${folder_name}_${message_id}"
    local lock_file="$LOCK_DIR/cache_${folder_name}_${message_id}.lock"
    
    if acquire_lock "$lock_file" 5; then
        echo "${state}:$(date '+%Y-%m-%d %H:%M:%S')" > "$cache_file"
        chmod 644 "$cache_file"
        release_lock "$lock_file"
        return 0
    else
        log_message "Failed to acquire lock for message cache: $message_id"
        return 1
    fi
}

# Function to check cached message state
check_message_state() {
    local folder_name="$1"
    local message_id="$2"
    local cache_file="$MESSAGE_CACHE_DIR/${folder_name}_${message_id}"
    
    if [ -f "$cache_file" ]; then
        local state
        state=$(head -n 1 "$cache_file" | cut -d: -f1)
        echo "$state"
        return 0
    fi
    echo "unknown"
    return 0
}

# ====================
# Folder Tracking Functions
# ====================

# Function to mark folder as processed
mark_folder_processed() {
    local folder_name="$1"
    local processed_file="$PROCESSED_DIR/${folder_name}"
    local lock_file="$LOCK_DIR/processed_${folder_name}.lock"
    
    if acquire_lock "$lock_file" 5; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$processed_file"
        chmod 644 "$processed_file"
        release_lock "$lock_file"
        return 0
    else
        log_message "Failed to acquire lock for marking folder processed: $folder_name"
        return 1
    fi
}

# Function to check if folder was processed
check_folder_processed() {
    local folder_name="$1"
    [ -f "$PROCESSED_DIR/${folder_name}" ]
}

# Function to start folder processing
start_folder_processing() {
    local folder_name="$1"
    local folder_track_file="$FOLDER_TRACKING_DIR/${folder_name}"
    local lock_file="$LOCK_DIR/tracking_${folder_name}.lock"
    
    # Clear any existing state files for this folder if in reset mode
    if [ "$RESET_MODE" = "true" ]; then
        rm -f "${MESSAGE_CACHE_DIR}/${folder_name}_"*
    fi
    
    if acquire_lock "$lock_file" 5; then
        echo "start:$(date '+%Y-%m-%d %H:%M:%S')" > "$folder_track_file"
        chmod 644 "$folder_track_file"
        release_lock "$lock_file"
        return 0
    else
        log_message "Failed to acquire lock for starting folder processing: $folder_name"
        return 1
    fi
}

# Function to complete folder processing
complete_folder_processing() {
    local folder_name="$1"
    local folder_track_file="$FOLDER_TRACKING_DIR/${folder_name}"
    local lock_file="$LOCK_DIR/tracking_${folder_name}.lock"
    
    if acquire_lock "$lock_file" 5; then
        echo "complete:$(date '+%Y-%m-%d %H:%M:%S')" > "$folder_track_file"
        chmod 644 "$folder_track_file"
        release_lock "$lock_file"
        return 0
    else
        log_message "Failed to acquire lock for completing folder processing: $folder_name"
        return 1
    fi
}

# Function to check if folder is being processed
is_folder_being_processed() {
    local folder_name="$1"
    local folder_track_file="$FOLDER_TRACKING_DIR/${folder_name}"
    
    if [ -f "$folder_track_file" ]; then
        grep -q "^start:" "$folder_track_file"
        return $?
    fi
    return 1
}

# End of Part 2# Beginning of Part 3

# ====================
# IMAP Operations
# ====================

# Function to test IMAP connection with SSL/TLS
test_imap_connection() {
    log_message "Testing IMAP connection to $DEST_SERVER:$DEST_PORT..."
    
    local temp_file="$TEMP_DIR/imap_test_$$_${RANDOM}.txt"
    local success=false
    
    # Create temp file with secure permissions
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    # Try to establish SSL/TLS connection
    if echo "a001 LOGOUT" | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"; then
        if grep -q "* OK" "$temp_file"; then
            success=true
        fi
    fi
    
    rm -f "$temp_file"
    
    if [ "$success" = "true" ]; then
        log_message "IMAP connection test successful"
        return 0
    else
        log_message "Failed to establish SSL/TLS connection to IMAP server"
        return 1
    fi
}

# Function to authenticate IMAP connection
authenticate_imap() {
    local retries=0
    local temp_file="$TEMP_DIR/imap_auth_$$_${RANDOM}.txt"
    
    # Create temp file with secure permissions
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    while [ $retries -lt $MAX_RETRIES ]; do
        log_message "Attempting IMAP authentication (attempt $((retries + 1))/$MAX_RETRIES)..."
        
        # Try to authenticate
        (
            printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
            sleep 1
            printf "a002 LOGOUT\r\n"
        ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
        
        if grep -q "^a001 OK" "$temp_file"; then
            rm -f "$temp_file"
            log_message "IMAP authentication successful"
            return 0
        fi
        
        log_message "Authentication failed, retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
        retries=$((retries + 1))
    done
    
    rm -f "$temp_file"
    log_message "IMAP authentication failed after $MAX_RETRIES attempts"
    return 1
}




# Function to clean paths consistently
clean_path() {
    local path="$1"
    echo "${path//\/\//\/}" | sed 's/\/$//'
}


# Function to get Message-ID with proper carriage return handling and clean output
get_message_id() {
    local message_file="$1"
    local msg_id
    
    # Try to get Message-ID header first - clean any line breaks
    msg_id=$(grep -i "^Message-ID:" "$message_file" | head -1 | sed 's/^Message-ID: *//i' | tr -d '<>' | tr -d '\r' | tr -d '\n')
    
    # If no Message-ID found, generate clean hash without logging text
    if [ -z "$msg_id" ]; then
        msg_id=$(md5sum "$message_file" | cut -d' ' -f1)
        log_message "No Message-ID found, using content hash: $msg_id"
    fi
    
    echo "$msg_id"
}



# Function to check message existence on IMAP server with improved reliability
# check_message_exists() {
#     local folder_path="$1"
#     local message_id="$2"
#     local folder_name="$3"
#     local temp_file="$TEMP_DIR/check_msg_$$_${RANDOM}.txt"
    
#     # Check state cache first
#     local cached_state
#     cached_state=$(check_message_state "$folder_name" "$message_id")
#     if [ "$cached_state" = "uploaded" ] || [ "$cached_state" = "skipped" ]; then
#         log_message "Message found in cache (state: $cached_state): $message_id"
#         return 0
#     fi
    
#     # Skip server check if in force mode
#     if [ "$FORCE_MODE" = "true" ]; then
#         return 1
#     fi
    
#     # Create temp file with secure permissions
#     touch "$temp_file"
#     chmod 600 "$temp_file"
    
#     # Clean message ID and folder path
#     message_id=$(echo "$message_id" | tr -d '\r' | tr -d '\n')
#     folder_path=$(clean_path "$folder_path")
    
#     # Search for message on server
#     (
#         printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
#         sleep 1
#         printf "a002 SELECT \"%s\"\r\n" "$folder_path"
#         sleep 1
#         printf "a003 SEARCH HEADER Message-ID \"%s\"\r\n" "$message_id"
#         sleep 1
#         printf "a004 LOGOUT\r\n"
#     ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
    
#     # Check if message exists using SEARCH response
#     if grep -q "^\* SEARCH [1-9][0-9]*" "$temp_file"; then
#         rm -f "$temp_file"
#         log_message "Message found on server: $message_id"
#         cache_message_state "$folder_name" "$message_id" "uploaded"
#         return 0
#     fi
    
#     rm -f "$temp_file"
#     return 1
# }


# Function to upload message with proper Dovecot folder handling
upload_message() {
    local message_file="$1"
    local folder_path="$2"
    local folder_name="$3"
    local retries=0
    local job_id="$$_${RANDOM}"
    local temp_file="$TEMP_DIR/upload_msg_${job_id}.txt"
    local cmd_file="$TEMP_DIR/upload_cmd_${job_id}.txt"
    
    # Get Dovecot's separator and convert path
    local separator
    separator=$(get_dovecot_separator)
    local imap_folder="${folder_path//\//$separator}"
    
    write_job_status "$job_id" "start" "Beginning upload process"
    
    # Get message ID first for duplicate checking
    local message_id
    message_id=$(get_message_id "$message_file")
    if [ -z "$message_id" ]; then
        log_message "Failed to get message identifier, skipping upload"
        write_job_status "$job_id" "failed" "No Message-ID available"
        update_upload_stats "$folder_name" 1 0 "false"
        return 1
    fi
    
    # Check if message already exists before doing anything else
    if check_message_exists "$imap_folder" "$message_id" "$folder_name"; then
        local message_size
        message_size=$(stat -c%s "$message_file")
        log_message "Message already exists, skipping (ID: $message_id)"
        write_job_status "$job_id" "skipped" "Message already exists"
        update_upload_stats "$folder_name" 1 "$message_size" "skipped"
        return 0
    fi
    
    # Verify message integrity
    if ! verify_message_integrity "$message_file"; then
        log_message "Message integrity check failed: $message_file"
        write_job_status "$job_id" "failed" "Integrity check failed"
        update_upload_stats "$folder_name" 1 0 "false"
        return 1
    fi
    
    # Get message size
    local message_size
    message_size=$(stat -c%s "$message_file")
    
    log_message "Uploading message to $imap_folder (size: $message_size bytes, ID: $message_id)"
    write_job_status "$job_id" "uploading" "Size: $message_size bytes, ID: $message_id"
    
    # Create temp files with secure permissions
    touch "$temp_file" "$cmd_file"
    chmod 600 "$temp_file" "$cmd_file"
    
    local upload_success=false
    
    while [ $retries -lt $MAX_RETRIES ] && [ "$upload_success" = "false" ]; do
        # Check again if message exists before each attempt
        if check_message_exists "$imap_folder" "$message_id" "$folder_name"; then
            log_message "Message appeared on server during retry, skipping (ID: $message_id)"
            write_job_status "$job_id" "skipped" "Message appeared during retry"
            update_upload_stats "$folder_name" 1 "$message_size" "skipped"
            rm -f "$temp_file" "$cmd_file"
            return 0
        fi
        
        # Create command file for upload with proper folder separator
        {
            printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
            sleep 1
            printf "a002 SELECT \"%s\"\r\n" "$imap_folder"
            sleep 1
            printf "a003 APPEND \"%s\" (\\Seen) {%d}\r\n" "$imap_folder" "$message_size"
            sleep 1
            cat "$message_file"
            printf "\r\n"
            sleep 1
            printf "a004 LOGOUT\r\n"
        } > "$cmd_file"
        
        # Execute upload with timeout
        if timeout 30 cat "$cmd_file" | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"; then
            if grep -q "^a003 OK" "$temp_file"; then
                # Mark success if OK response received
                upload_success=true
            else
                log_message "Upload command failed, retrying..."
            fi
        else
            log_message "Upload timed out or connection failed, retrying..."
        fi
        
        if [ "$upload_success" = "false" ]; then
            retries=$((retries + 1))
            if [ $retries -lt $MAX_RETRIES ]; then
                sleep $RETRY_DELAY
            fi
        fi
    done
    
    rm -f "$temp_file" "$cmd_file"
    
    if [ "$upload_success" = "true" ]; then
        # Verify upload and update stats
        if verify_message_upload "$imap_folder" "$message_id" "$folder_name"; then
            update_upload_stats "$folder_name" 1 "$message_size" "true"
            write_job_status "$job_id" "completed" "Successfully uploaded and verified"
            log_message "Successfully uploaded and verified message (size: $message_size bytes, ID: $message_id)"
            return 0
        else
            log_message "Upload appeared successful but verification failed (ID: $message_id)"
        fi
    fi
    
    log_message "Failed to upload message after $MAX_RETRIES attempts (ID: $message_id)"
    write_job_status "$job_id" "failed" "Failed after $MAX_RETRIES attempts"
    update_upload_stats "$folder_name" 1 0 "false"
    return 1
}

# Update check_message_exists to use Dovecot separator
check_message_exists() {
    local folder_path="$1"
    local message_id="$2"
    local folder_name="$3"
    local temp_file="$TEMP_DIR/check_msg_$$_${RANDOM}.txt"
    
    # Get Dovecot's separator and convert path
    local separator
    separator=$(get_dovecot_separator)
    local imap_folder="${folder_path//\//$separator}"
    
    # Check state cache first
    local cached_state
    cached_state=$(check_message_state "$folder_name" "$message_id")
    if [ "$cached_state" = "uploaded" ] || [ "$cached_state" = "skipped" ]; then
        log_message "Message found in cache (state: $cached_state): $message_id"
        return 0
    fi
    
    # Skip server check if in force mode
    if [ "$FORCE_MODE" = "true" ]; then
        return 1
    fi
    
    # Create temp file with secure permissions
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    # Clean message ID
    message_id=$(echo "$message_id" | tr -d '\r' | tr -d '\n')
    
    # Search for message on server
    (
        printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
        sleep 1
        printf "a002 SELECT \"%s\"\r\n" "$imap_folder"
        sleep 1
        printf "a003 SEARCH HEADER Message-ID \"%s\"\r\n" "$message_id"
        sleep 1
        printf "a004 LOGOUT\r\n"
    ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
    
    # Check if message exists using SEARCH response
    if grep -q "^\* SEARCH [1-9][0-9]*" "$temp_file"; then
        rm -f "$temp_file"
        log_message "Message found on server: $message_id"
        cache_message_state "$folder_name" "$message_id" "uploaded"
        return 0
    fi
    
    rm -f "$temp_file"
    return 1
}

# Function to verify folder exists and has expected content
verify_folder_exists() {
    local folder_path="$1"
    local temp_file="$TEMP_DIR/verify_folder_$$_${RANDOM}.txt"
    
    # Create temp file with secure permissions
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    # Try to select folder
    (
        printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
        sleep 1
        printf "a002 SELECT \"%s\"\r\n" "$folder_path"
        sleep 1
        printf "a003 LOGOUT\r\n"
    ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
    
    # Check if folder exists and can be selected
    if grep -q "^a002 OK" "$temp_file"; then
        rm -f "$temp_file"
        return 0
    fi
    
    rm -f "$temp_file"
    return 1
}

# Function to verify message upload success
verify_message_upload() {
    local folder_path="$1"
    local message_id="$2"
    local folder_name="$3"
    local temp_file="$TEMP_DIR/verify_upload_$$_${RANDOM}.txt"
    local retries=0
    
    # Check if folder exists first
    if ! verify_folder_exists "$folder_path"; then
        log_message "Folder does not exist or cannot be selected: $folder_path"
        return 1
    fi
    
    # Create temp file with secure permissions
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    # Give IMAP server a moment to process the upload
    sleep $VERIFY_DELAY
    
    while [ $retries -lt $MAX_RETRIES ]; do
        # Verify message existence
        if check_message_exists "$folder_path" "$message_id" "$folder_name"; then
            log_message "Upload verified successfully: $message_id"
            cache_message_state "$folder_name" "$message_id" "uploaded"
            return 0
        fi
        
        log_message "Message not found in destination, retrying verification in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
        retries=$((retries + 1))
    done
    
    log_message "Failed to verify message upload after $MAX_RETRIES attempts"
    cache_message_state "$folder_name" "$message_id" "failed"
    return 1
}




# Function to verify message integrity
verify_message_integrity() {
    local message_file="$1"
    local temp_file="$TEMP_DIR/verify_msg_$$_${RANDOM}.txt"
    
    # Check if file exists and is readable
    if [ ! -f "$message_file" ] || [ ! -r "$message_file" ]; then
        log_message "Message file not accessible: $message_file"
        return 1
    fi
    
    # Check for minimum size
    local size
    size=$(stat -c%s "$message_file")
    if [ "$size" -lt 100 ]; then
        log_message "Message file too small: $size bytes"
        return 1
    fi
    
    # Create temp copy for verification with secure permissions
    cp "$message_file" "$temp_file"
    chmod 600 "$temp_file"
    
    # Verify MIME structure
    local valid=true
    
    # Check required headers
    for header in "Content-Type:" "From:" "Date:" "Subject:"; do
        if ! grep -qi "^$header" "$temp_file"; then
            log_message "Missing required header: $header"
            valid=false
            break
        fi
    done
    
    # Check MIME boundaries if multipart
    if [ "$valid" = "true" ] && grep -qi "^Content-Type: multipart/" "$temp_file"; then
        local boundary
        boundary=$(grep -i "^Content-Type: multipart/" "$temp_file" | sed -n 's/.*boundary="\([^"]*\)".*/\1/p')
        if [ ! -z "$boundary" ]; then
            if ! grep -q "^--${boundary}--" "$temp_file"; then
                log_message "Invalid MIME structure: Missing closing boundary"
                valid=false
            fi
        fi
    fi
    
    rm -f "$temp_file"
    
    if [ "$valid" = "true" ]; then
        return 0
    else
        return 1
    fi
}

# End of Part 3# Beginning of Part 4

# ====================
# Processing Functions
# ====================

# Function to upload message with retry and validation
# upload_message() {
#     local message_file="$1"
#     local folder_path="$2"
#     local folder_name="$3"
#     local retries=0
#     local job_id="$$_${RANDOM}"
#     local temp_file="$TEMP_DIR/upload_msg_${job_id}.txt"
#     local cmd_file="$TEMP_DIR/upload_cmd_${job_id}.txt"
    
#     write_job_status "$job_id" "start" "Beginning upload process"
    
#     # Get message ID first for duplicate checking
#     local message_id
#     message_id=$(get_message_id "$message_file")
#     if [ -z "$message_id" ]; then
#         log_message "Failed to get message identifier, skipping upload"
#         write_job_status "$job_id" "failed" "No Message-ID available"
#         update_upload_stats "$folder_name" 1 0 "false"
#         return 1
#     fi
    
#     # Check if message already exists before doing anything else
#     if check_message_exists "$folder_path" "$message_id" "$folder_name"; then
#         local message_size
#         message_size=$(stat -c%s "$message_file")
#         log_message "Message already exists, skipping (ID: $message_id)"
#         write_job_status "$job_id" "skipped" "Message already exists"
#         update_upload_stats "$folder_name" 1 "$message_size" "skipped"
#         return 0
#     fi
    
#     # Verify message integrity
#     if ! verify_message_integrity "$message_file"; then
#         log_message "Message integrity check failed: $message_file"
#         write_job_status "$job_id" "failed" "Integrity check failed"
#         update_upload_stats "$folder_name" 1 0 "false"
#         return 1
#     fi
    
#     # Get message size
#     local message_size
#     message_size=$(stat -c%s "$message_file")
    
#     log_message "Uploading message to $folder_path (size: $message_size bytes, ID: $message_id)"
#     write_job_status "$job_id" "uploading" "Size: $message_size bytes, ID: $message_id"
    
#     # Create temp files with secure permissions
#     touch "$temp_file" "$cmd_file"
#     chmod 600 "$temp_file" "$cmd_file"
    
#     local upload_success=false
    
#     while [ $retries -lt $MAX_RETRIES ] && [ "$upload_success" = "false" ]; do
#         # Check again if message exists before each attempt
#         if check_message_exists "$folder_path" "$message_id" "$folder_name"; then
#             log_message "Message appeared on server during retry, skipping (ID: $message_id)"
#             write_job_status "$job_id" "skipped" "Message appeared during retry"
#             update_upload_stats "$folder_name" 1 "$message_size" "skipped"
#             rm -f "$temp_file" "$cmd_file"
#             return 0
#         fi
        
#         # Create command file for upload
#         {
#             printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
#             sleep 1
#             printf "a002 APPEND \"%s\" (\\Seen) {%d}\r\n" "$folder_path" "$message_size"
#             sleep 1
#             cat "$message_file"
#             printf "\r\n"
#             sleep 1
#             printf "a003 LOGOUT\r\n"
#         } > "$cmd_file"
        
#         # Execute upload with timeout
#         if timeout 30 cat "$cmd_file" | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"; then
#             if grep -q "^a002 OK" "$temp_file"; then
#                 # Mark success if OK response received
#                 upload_success=true
#             else
#                 log_message "Upload command failed, retrying..."
#             fi
#         else
#             log_message "Upload timed out or connection failed, retrying..."
#         fi
        
#         if [ "$upload_success" = "false" ]; then
#             retries=$((retries + 1))
#             if [ $retries -lt $MAX_RETRIES ]; then
#                 sleep $RETRY_DELAY
#             fi
#         fi
#     done
    
#     rm -f "$temp_file" "$cmd_file"
    
#     if [ "$upload_success" = "true" ]; then
#         # Verify upload and update stats
#         if verify_message_upload "$folder_path" "$message_id" "$folder_name"; then
#             update_upload_stats "$folder_name" 1 "$message_size" "true"
#             write_job_status "$job_id" "completed" "Successfully uploaded and verified"
#             log_message "Successfully uploaded and verified message (size: $message_size bytes, ID: $message_id)"
#             return 0
#         else
#             log_message "Upload appeared successful but verification failed (ID: $message_id)"
#         fi
#     fi
    
#     log_message "Failed to upload message after $MAX_RETRIES attempts (ID: $message_id)"
#     write_job_status "$job_id" "failed" "Failed after $MAX_RETRIES attempts"
#     update_upload_stats "$folder_name" 1 0 "false"
#     return 1
# }


# Function to verify folder content
verify_folder_content() {
    local source_folder="$1"
    local dest_folder="$2"
    local folder_name=$(basename "$dest_folder")
    local temp_file="$TEMP_DIR/verify_folder_$$_${RANDOM}.txt"
    local verification_file="$STATS_DIR/verification/${folder_name}"
    local lock_file="$LOCK_DIR/verify_${folder_name}.lock"
    local retries=0
    
    log_message "Verifying content for folder: $dest_folder"
    
    # Create temp file with secure permissions
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    # Acquire verification lock
    if ! acquire_lock "$lock_file" 10; then
        log_message "Failed to acquire verification lock for folder: $folder_name"
        rm -f "$temp_file"
        return 1
    fi
    
    # Get source count
    local source_count=0
    if [ -d "$source_folder" ]; then
        source_count=$(find "$source_folder" -type f -name "*.eml" | wc -l)
    fi
    
    local verify_success=false
    while [ $retries -lt $MAX_RETRIES ] && [ "$verify_success" = "false" ]; do
        # Get destination count and status
        (
            printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
            sleep 1
            printf "a002 SELECT \"%s\"\r\n" "$dest_folder"
            sleep 1
            printf "a003 STATUS \"%s\" (MESSAGES)\r\n" "$dest_folder"
            sleep 1
            printf "a004 LOGOUT\r\n"
        ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
        
        if grep -q "^a002 OK" "$temp_file"; then
            local dest_count
            dest_count=$(grep "EXISTS" "$temp_file" | awk '{print $2}')
            
            # Read skipped count
            local skipped_count=0
            local skipped_file="$STATS_DIR/upload_folders/$folder_name/skipped"
            if [ -f "$skipped_file" ]; then
                skipped_count=$(cat "$skipped_file")
            fi
            
            # Record verification results
            mkdir -p "$(dirname "$verification_file")"
            {
                echo "source_count=$source_count"
                echo "destination_count=$dest_count"
                echo "skipped_count=$skipped_count"
                echo "verification_time=$(date '+%Y-%m-%d %H:%M:%S')"
            } > "$verification_file"
            chmod 644 "$verification_file"
            
            log_message "Folder verification completed:"
            log_message "  Source messages: $source_count"
            log_message "  Destination messages: $dest_count"
            log_message "  Skipped messages: $skipped_count"
            
            verify_success=true
        else
            log_message "Verification attempt $((retries + 1)) failed, retrying..."
            sleep $RETRY_DELAY
            retries=$((retries + 1))
        fi
    done
    
    # Release verification lock
    release_lock "$lock_file"
    rm -f "$temp_file"
    
    if [ "$verify_success" = "false" ]; then
        log_message "Failed to verify folder content after $MAX_RETRIES attempts: $dest_folder"
        return 1
    fi
    
    return 0
}



# Function to preserve folder hierarchy in stats
update_upload_stats() {
    local folder_path="$1"  # Now using full path
    local message_count="$2"
    local message_size="$3"
    local status="$4"  # "true", "skipped", or "false"
    
    # Preserve folder hierarchy in stats
    local stats_folder="${folder_path#messages/}"  # Remove 'messages/' prefix
    local folder_dir="$STATS_DIR/folders/$stats_folder"
    local lock_file="$LOCK_DIR/stats_${stats_folder//\//_}.lock"
    
    # Create folder directory preserving hierarchy
    mkdir -p "$folder_dir"
    chmod 755 "$folder_dir"
    
    if acquire_lock "$lock_file" 5; then
        if [ "$status" = "true" ]; then
            # Update folder-specific stats for successful upload
            increment_counter "$folder_dir/count" "$message_count"
            increment_counter "$folder_dir/size" "$message_size"
            increment_counter "$TOTAL_MESSAGES_FILE" "$message_count"
            increment_counter "$TOTAL_SIZE_FILE" "$message_size"
            success=true
        elif [ "$status" = "skipped" ]; then
            # Update skipped counts
            increment_counter "$folder_dir/skipped" "$message_count"
            increment_counter "$TOTAL_SKIPPED_FILE" "$message_count"
            success=true
        else
            # Update failed counts
            increment_counter "$folder_dir/failed" "$message_count"
            increment_counter "$TOTAL_FAILED_FILE" "$message_count"
            success=true
        fi
        release_lock "$lock_file"
    else
        log_message "Failed to acquire lock for stats update: $folder_path"
        return 1
    fi
    
    return 0
}

# Function to create IMAP folder hierarchy
create_imap_folder_hierarchy() {
    local folder_path="$1"
    local current_path=""
    
    # Split path and create each level
    IFS='/' read -ra FOLDERS <<< "$folder_path"
    for folder in "${FOLDERS[@]}"; do
        if [ ! -z "$current_path" ]; then
            current_path="$current_path/$folder"
        else
            current_path="$folder"
        fi
        
        # Try to create current level
        if ! create_imap_folder "$current_path"; then
            log_message "Failed to create folder level: $current_path"
            return 1
        fi
        
        # Small delay between folder creations
        sleep $REQUEST_DELAY
    done
    
    return 0
}


# Function to get IMAP folder delimiter
get_folder_delimiter() {
    local temp_file="$TEMP_DIR/folder_delimiter_$$_${RANDOM}.txt"
    local delimiter="/"  # Default delimiter
    
    # Create temp file with secure permissions
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    # Get folder delimiter from server
    (
        printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
        sleep 1
        printf "a002 LIST \"\" \"\"\r\n"
        sleep 1
        printf "a003 LOGOUT\r\n"
    ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
    
    # Extract delimiter from response
    local server_delimiter
    server_delimiter=$(grep -o 'LIST.*"".*""' "$temp_file" | grep -o '"\([^"]*\)"' | tail -1 | tr -d '"')
    
    if [ ! -z "$server_delimiter" ]; then
        delimiter="$server_delimiter"
    fi
    
    rm -f "$temp_file"
    echo "$delimiter"
}

# Function to get Dovecot's folder separator
get_dovecot_separator() {
    local temp_file="$TEMP_DIR/separator_$$_${RANDOM}.txt"
    local separator="."  # Default for Dovecot
    
    # Create temp file with secure permissions
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    # Query server for separator
    (
        printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
        sleep 1
        printf "a002 LIST \"\" \"\"\r\n"
        sleep 1
        printf "a003 LOGOUT\r\n"
    ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
    
    # Extract separator - Dovecot usually shows it in LIST response
    local found_sep
    found_sep=$(grep "LIST.*(\"|\")" "$temp_file" | grep -o '"\([^"]*\)"' | tail -1 | tr -d '"')
    
    if [ ! -z "$found_sep" ]; then
        separator="$found_sep"
    fi
    
    rm -f "$temp_file"
    echo "$separator"
}

# Function to list existing IMAP folders
list_imap_folders() {
    local temp_file="$TEMP_DIR/list_folders_$$_${RANDOM}.txt"
    
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    (
        printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
        sleep 1
        printf "a002 LIST \"\" \"*\"\r\n"
        sleep 1
        printf "a003 LOGOUT\r\n"
    ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
    
    # Get list of existing folders
    grep "^* LIST" "$temp_file" | sed 's/^* LIST.*"\([^"]*\)"$/\1/' > "$TEMP_DIR/folder_list"
    
    rm -f "$temp_file"
}

# Function to create IMAP folder with Dovecot specifics
create_imap_folder() {
    local folder_path="$1"
    local retries=0
    local temp_file="$TEMP_DIR/create_folder_$$_${RANDOM}.txt"
    
    # Clean path
    folder_path=$(clean_path "$folder_path")
    
    # Get Dovecot's separator
    local separator
    separator=$(get_dovecot_separator)
    
    # Convert path separator to Dovecot's
    local imap_path="${folder_path//\//$separator}"
    
    touch "$temp_file"
    chmod 600 "$temp_file"
    
    log_message "Creating Dovecot IMAP folder: $imap_path"
    
    # First check if it exists
    list_imap_folders
    if grep -Fq "$imap_path" "$TEMP_DIR/folder_list"; then
        log_message "Folder already exists: $imap_path"
        rm -f "$temp_file"
        return 0
    fi
    
    # If this is a nested folder, ensure parent exists
    if [[ "$folder_path" == *"/"* ]]; then
        local parent_folder="${folder_path%/*}"
        local parent_imap="${parent_folder//\//$separator}"
        
        log_message "Checking parent folder: $parent_imap"
        
        # Create parent if needed
        if ! grep -Fq "$parent_imap" "$TEMP_DIR/folder_list"; then
            if ! create_imap_folder "$parent_folder"; then
                log_message "Failed to create parent folder: $parent_folder"
                rm -f "$temp_file"
                return 1
            fi
        fi
    fi
    
    # Create the folder
    while [ $retries -lt $MAX_RETRIES ]; do
        (
            printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
            sleep 1
            printf "a002 CREATE \"%s\"\r\n" "$imap_path"
            sleep 1
            # Verify creation
            printf "a003 LIST \"\" \"%s\"\r\n" "$imap_path"
            sleep 1
            printf "a004 LOGOUT\r\n"
        ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
        
        # Check if creation was successful
        if grep -q "^a002 OK\|ALREADYEXISTS" "$temp_file" || grep -q "^* LIST.*\"$imap_path\"" "$temp_file"; then
            rm -f "$temp_file"
            log_message "Folder created successfully: $imap_path"
            return 0
        fi
        
        log_message "Failed to create folder, retrying in $RETRY_DELAY seconds..."
        cat "$temp_file" | grep "^a002" | log_message
        sleep $RETRY_DELAY
        retries=$((retries + 1))
    done
    
    rm -f "$temp_file"
    log_message "Failed to create folder after $MAX_RETRIES attempts: $imap_path"
    return 1
}

# Function to create IMAP folder with proper delimiter handling
# create_imap_folder() {
#     local folder_path="$1"
#     local retries=0
#     local temp_file="$TEMP_DIR/create_folder_$$_${RANDOM}.txt"
    
#     # Clean path
#     folder_path=$(clean_path "$folder_path")
    
#     # Get IMAP folder delimiter
#     local delimiter
#     delimiter=$(get_folder_delimiter)
    
#     # Convert path delimiter to IMAP delimiter
#     local imap_path="${folder_path//\//$delimiter}"
    
#     # Create temp file with secure permissions
#     touch "$temp_file"
#     chmod 600 "$temp_file"
    
#     log_message "Creating IMAP folder: $folder_path"
    
#     # Create parent folders first if needed
#     if [[ "$folder_path" == *"/"* ]]; then
#         local parent_folder="${folder_path%/*}"
#         log_message "Creating parent folder: $parent_folder"
        
#         # Create parent first
#         if ! create_imap_folder "$parent_folder"; then
#             rm -f "$temp_file"
#             return 1
#         fi
#     fi
    
#     # Now create the actual folder
#     while [ $retries -lt $MAX_RETRIES ]; do
#         (
#             printf "a001 LOGIN \"%s\" \"%s\"\r\n" "$DEST_USER" "$DEST_PASS"
#             sleep 1
#             printf "a002 CREATE \"%s\"\r\n" "$imap_path"
#             sleep 1
#             printf "a003 LOGOUT\r\n"
#         ) | openssl s_client -connect "$DEST_SERVER:$DEST_PORT" $OPENSSL_OPTS 2>/dev/null > "$temp_file"
        
#         if grep -q "^a002 OK\|ALREADYEXISTS" "$temp_file"; then
#             rm -f "$temp_file"
#             log_message "Folder ready: $folder_path"
#             return 0
#         fi
        
#         log_message "Failed to create folder, retrying in $RETRY_DELAY seconds..."
#         sleep $RETRY_DELAY
#         retries=$((retries + 1))
#     done
    
#     rm -f "$temp_file"
#     log_message "Failed to create folder after $MAX_RETRIES attempts: $folder_path"
#     return 1
# }








# Function to process folder uploads with proper hierarchy preservation
process_folder_uploads() {
    local source_folder="$1"
    local dest_folder="$2"
    local depth="${3:-0}"
    local max_depth=10
    
    # Clean paths
    source_folder=$(clean_path "$source_folder")
    dest_folder=$(clean_path "$dest_folder")
    
    # Get relative path for stats
    local relative_path="${source_folder#messages/}"
    local lock_file="$LOCK_DIR/folder_${relative_path//\//_}.lock"
    
    log_message "Processing folder uploads for: $relative_path (depth: $depth)"
    
    # Create stats directory maintaining hierarchy
    local stats_path="$STATS_DIR/folders/$relative_path"
    mkdir -p "$stats_path"
    
    # Prevent infinite recursion
    if [ "$depth" -ge "$max_depth" ]; then
        log_message "WARNING: Maximum folder depth reached for $relative_path"
        return 0
    fi
    
    # Create IMAP folder
    if ! create_imap_folder "$dest_folder"; then
        log_message "Failed to create folder: $dest_folder"
        return 1
    fi
    
    # Process messages in current folder
    local message_processed=0
    for message_file in "$source_folder"/*.eml; do
        if [ -f "$message_file" ]; then
            # Get clean message ID
            local message_id
            message_id=$(get_message_id "$message_file")
            
            if [ -z "$message_id" ]; then
                log_message "Failed to get message identifier, skipping: $message_file"
                continue
            fi
            
            # Check for duplicates
            if check_message_exists "$dest_folder" "$message_id" "$relative_path"; then
                local message_size
                message_size=$(stat -c%s "$message_file")
                log_message "Message already exists, skipping (ID: $message_id)"
                update_upload_stats "$relative_path" 1 "$message_size" "skipped"
                continue
            fi
            
            # Upload message
            if upload_message "$message_file" "$dest_folder" "$relative_path"; then
                message_processed=1
            fi
            sleep $REQUEST_DELAY
        fi
    done
    
    # Process subfolders recursively while maintaining hierarchy
    for subfolder in "$source_folder"/*/; do
        if [ -d "$subfolder" ]; then
            local sub_name=$(basename "$subfolder")
            local sub_dest="$dest_folder/$sub_name"
            local sub_source="$source_folder/$sub_name"
            
            process_folder_uploads "$sub_source" "$sub_dest" "$((depth + 1))"
            sleep $REQUEST_DELAY
        fi
    done
    
    return 0
}







# Update main function to handle hierarchy properly
main() {
    log_message "Starting upload to Modoboa script v42.0.7..."
    
    # Initialize directories
    init_directories
    
    # Check source directory
    if [ ! -d "messages" ]; then
        log_message "Source 'messages' directory not found"
        exit 1
    fi
    
    # Test IMAP connection
    if ! test_imap_connection; then
        log_message "IMAP connection test failed"
        exit 1
    fi
    
    # Verify authentication
    if ! authenticate_imap; then
        log_message "IMAP authentication failed"
        exit 1
    fi
    
    # Process root folders with full hierarchy
    for root_folder in messages/*/; do
        if [ -d "$root_folder" ]; then
            local folder_name=$(basename "$root_folder")
            log_message "Processing root folder and hierarchy: $folder_name"
            
            if ! process_folder_uploads "$root_folder" "$folder_name" 0; then
                log_message "Failed to process folder hierarchy: $folder_name"
                continue
            fi
            
            # Rate limiting delay between root folders
            sleep $REQUEST_DELAY
        fi
    done
    
    log_message "Upload process completed"
}




# Run main function
main
