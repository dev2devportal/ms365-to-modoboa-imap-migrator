#!/bin/bash

# MS365 to Modoboa Migration Script v29.0.4 - Download Phase
# Changes from v28:
# - Fixed statistics tracking using temporary files
# - Added atomic updates for counters
# - Added checkpointing for statistics
# - Added detailed progress tracking
# - Uses $top=100 to get maximum folders per request
# - Follows pagination with @odata.nextLink
# - Attempt to improve rate limiting and retry logic
# - Attempt to improve folder processing logic
# - Attempt to improve security measures
# - Better detection of child folders using the expanded data
# - Explicit depth tracking to handle deep nesting safely
# - More detailed logging to diagnose issues
# - Safer recursion with depth limits
# - Better pagination handling at root level
# - Fixed numeric comparison bugs
# - More thorough folder hierarchy scanning
# - Better error detection and logging
# - Attempt to improve null handling in pagination
# - Depth tracking to prevent infinite recursion
# - Better folder hierarchy handling
# - Improved logging for debugging
# - Process all folders including deeply nested ones
# - Better path handling to prevent double slashes
# - Security Requirements:
# - Routes through Azure B2C servers
# - No direct curl to Azure infrastructure
# - Uses SSL/TLS
# - Modern Authentication only
# - Secure credential handling

# Configuration
ADMIN_EMAIL="mailadminusername@domain.tld"
SOURCE_EMAIL="migratingemailusername@domain.tld"
SUBSCRIPTION_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxx"
TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
CLIENT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
CLIENT_SECRET="secret"
LOGFILE="migration.log"
STATS_FILE="migration_stats.json"
TEMP_DIR="temp_downloads"
STATS_DIR="stats"

# Parallel processing configuration
MAX_PARALLEL_DOWNLOADS=3
REQUEST_DELAY=0.5
RETRY_DELAY=5
MAX_RETRIES=3

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# Function to initialize statistics directory
init_stats() {
    mkdir -p "$STATS_DIR"
    echo "0" > "$STATS_DIR/total_messages"
    echo "0" > "$STATS_DIR/total_size"
    echo "0" > "$STATS_DIR/total_failed"
    mkdir -p "$STATS_DIR/folders"
    chmod 755 "$STATS_DIR"
    chmod 644 "$STATS_DIR/total_messages" "$STATS_DIR/total_size" "$STATS_DIR/total_failed"
}

# Function to update folder statistics atomically
update_folder_stats() {
    local folder_name="$1"
    local message_count="$2"
    local message_size="$3"
    local success="$4"
    local folder_dir="$STATS_DIR/folders/${folder_name}"
    
    mkdir -p "$folder_dir"
    chmod 755 "$folder_dir"
    
    if [ "$success" = "true" ]; then
        # Update folder-specific stats
        local count_file="$folder_dir/count"
        local size_file="$folder_dir/size"
        
        # Initialize files if they don't exist
        touch "$count_file" "$size_file"
        chmod 644 "$count_file" "$size_file"
        
        # Update message count with locking
        (
            flock -x 200
            count=$(($(cat "$count_file" 2>/dev/null || echo 0) + message_count))
            echo "$count" > "$count_file"
        ) 200>"$folder_dir/count.lock"
        
        # Update size with locking
        (
            flock -x 200
            size=$(($(cat "$size_file" 2>/dev/null || echo 0) + message_size))
            echo "$size" > "$size_file"
        ) 200>"$folder_dir/size.lock"
        
        # Update global message count with locking
        (
            flock -x 200
            total=$(($(cat "$STATS_DIR/total_messages" 2>/dev/null || echo 0) + message_count))
            echo "$total" > "$STATS_DIR/total_messages"
        ) 200>"$STATS_DIR/total_messages.lock"
        
        # Update global size with locking
        (
            flock -x 200
            total=$(($(cat "$STATS_DIR/total_size" 2>/dev/null || echo 0) + message_size))
            echo "$total" > "$STATS_DIR/total_size"
        ) 200>"$STATS_DIR/total_size.lock"
    else
        # Update failed count with locking
        (
            flock -x 200
            failed=$(($(cat "$STATS_DIR/total_failed" 2>/dev/null || echo 0) + message_count))
            echo "$failed" > "$STATS_DIR/total_failed"
        ) 200>"$STATS_DIR/total_failed.lock"
    fi
}

# Function to read current statistics
read_stats() {
    local total_messages=$(cat "$STATS_DIR/total_messages" 2>/dev/null || echo 0)
    local total_size=$(cat "$STATS_DIR/total_size" 2>/dev/null || echo 0)
    local total_failed=$(cat "$STATS_DIR/total_failed" 2>/dev/null || echo 0)
    
    echo "$total_messages:$total_size:$total_failed"
}

# Function to print download summary
print_summary() {
    log_message "Download Summary:"
    log_message "=================="
    
    # Read global stats
    local stats
    IFS=':' read -r messages size failed < <(read_stats)
    
    log_message "Total Messages: $messages"
    log_message "Total Size: $(numfmt --to=iec-i --suffix=B $size)"
    log_message "Failed Downloads: $failed"
    log_message ""
    log_message "Folder Statistics:"
    
    # Read folder-specific stats
    if [ -d "$STATS_DIR/folders" ]; then
        for folder_dir in "$STATS_DIR/folders"/*; do
            if [ -d "$folder_dir" ]; then
                local folder_name=$(basename "$folder_dir")
                local count=$(cat "$folder_dir/count" 2>/dev/null || echo 0)
                local size=$(cat "$folder_dir/size" 2>/dev/null || echo 0)
                local size_formatted=$(numfmt --to=iec-i --suffix=B "$size")
                
                log_message "  $folder_name:"
                log_message "    Messages: $count"
                log_message "    Size: $size_formatted"
            fi
        done
    fi
}

# Function to check Azure CLI authentication with retry
check_azure_auth() {
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log_message "Authentication attempt $attempt of $max_attempts..."
        
        # Clear existing credentials
        az account clear || true
        
        # Try to authenticate with service principal
        log_message "Attempting service principal authentication..."
        local login_output
        login_output=$(az login --service-principal \
            --username "$CLIENT_ID" \
            --password "$CLIENT_SECRET" \
            --tenant "$TENANT_ID" \
            2>&1)
        
        local login_status=$?
        log_message "Authentication output: $login_output"
        
        if [ $login_status -eq 0 ]; then
            # Try to set subscription but don't fail if it's not available
            log_message "Attempting to set subscription (optional)..."
            az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1 && \
                log_message "Successfully set subscription"
            
            log_message "Successfully authenticated using service principal"
            return 0
        fi
        
        log_message "Authentication attempt $attempt failed"
        attempt=$((attempt + 1))
        
        if [ $attempt -le $max_attempts ]; then
            log_message "Waiting 5 seconds before retry..."
            sleep 5
        fi
    done
    
    log_message "All authentication attempts failed"
    return 1
}

# Function to verify Graph API access
verify_graph_access() {
    log_message "Verifying Graph API access..."
    
    # Try to get tenant info as a basic access test
    local tenant_info
    tenant_info=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/organization" \
        2>&1)
    
    if [ $? -ne 0 ]; then
        log_message "Failed to access Microsoft Graph API"
        log_message "Error: $tenant_info"
        return 1
    fi
    
    log_message "Successfully verified Graph API access"
    return 0
}

# Function to test mailbox existence
test_mailbox_existence() {
    log_message "Testing mailbox existence for $SOURCE_EMAIL..."
    
    # Use Graph API to query the user
    local response
    response=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/users/$SOURCE_EMAIL" \
        --headers "ConsistencyLevel=eventual" \
        2>&1)
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        local mail
        mail=$(echo "$response" | jq -r '.mail')
        if [ "$mail" = "$SOURCE_EMAIL" ]; then
            log_message "Successfully verified mailbox existence"
            return 0
        fi
    fi
    
    log_message "Failed to verify mailbox existence"
    log_message "API Response: $response"
    return 1
}

# End of Part 1# Beginning of Part 2

# Function to download message with retry
download_message() {
    local message_id="$1"
    local subject="$2"
    local folder_path="$3"
    local folder_name="$4"
    local retries=0
    local message_file="${folder_path}/${message_id}.eml"
    
    while [ $retries -lt $MAX_RETRIES ]; do
        log_message "Downloading message: $subject"
        
        # Rate limiting delay
        sleep $REQUEST_DELAY
        
        # Use --output-file for proper binary content handling
        if az rest --method GET \
            --url "https://graph.microsoft.com/v1.0/users/$SOURCE_EMAIL/messages/$message_id/\$value" \
            --headers "ConsistencyLevel=eventual" \
            --output-file "$message_file" 2>/dev/null; then
            
            # Get actual file size for statistics
            local message_size
            message_size=$(stat -c%s "$message_file")
            
            # Verify the file exists and has content
            if [ -f "$message_file" ] && [ "$message_size" -gt 0 ]; then
                update_folder_stats "$folder_name" 1 "$message_size" "true"
                log_message "Successfully downloaded: $subject"
                return 0
            else
                log_message "Downloaded file is empty or missing: $subject"
                rm -f "$message_file"
            fi
        else
            # Check for throttling in stderr output
            if az rest --method GET \
                --url "https://graph.microsoft.com/v1.0/users/$SOURCE_EMAIL/messages/$message_id" \
                2>&1 | grep -q "ApplicationThrottled"; then
                log_message "Rate limited, waiting before retry..."
                sleep $RETRY_DELAY
                retries=$((retries + 1))
                continue
            fi
        fi
        
        log_message "Failed to download message: $subject"
        rm -f "$message_file"
        update_folder_stats "$folder_name" 1 0 "false"
        return 1
    done
    
    log_message "Failed to download message after $MAX_RETRIES retries: $subject"
    update_folder_stats "$folder_name" 1 0 "false"
    return 1
}

# Function to process a single folder
process_folder() {
    local folder_id="$1"
    local folder_name="$2"
    local folder_path="${3:-messages/${folder_name// /_}}"
    
    log_message "Processing folder: $folder_name"
    mkdir -p "$folder_path"
    
    # Get messages from the folder with pagination
    local next_link="https://graph.microsoft.com/v1.0/users/$SOURCE_EMAIL/mailFolders/$folder_id/messages?\$select=id,subject"
    local active_jobs=0
    local retry_count=0
    
    while [ ! -z "$next_link" ] && [ $retry_count -lt $MAX_RETRIES ]; do
        log_message "Fetching batch of messages..."
        
        # Rate limiting delay
        sleep $REQUEST_DELAY
        
        local response
        response=$(az rest --method GET \
            --url "$next_link" \
            --headers "ConsistencyLevel=eventual" \
            2>&1)
        
        if [ $? -ne 0 ]; then
            if echo "$response" | grep -q "ApplicationThrottled"; then
                log_message "Rate limited, waiting before retry..."
                sleep $RETRY_DELAY
                retry_count=$((retry_count + 1))
                continue
            else
                log_message "Failed to fetch messages batch: $response"
                return 1
            fi
        fi
        
        retry_count=0  # Reset retry counter on success
        
        # Process messages in parallel with controlled concurrency
        echo "$response" | jq -c '.value[]' | while read -r message; do
            local message_id subject
            message_id=$(echo "$message" | jq -r '.id')
            subject=$(echo "$message" | jq -r '.subject')
            
            # Control parallel processing
            while [ $active_jobs -ge $MAX_PARALLEL_DOWNLOADS ]; do
                wait -n
                active_jobs=$((active_jobs - 1))
            done
            
            # Download message in background
            (download_message "$message_id" "$subject" "$folder_path" "$folder_name") &
            active_jobs=$((active_jobs + 1))
            
            # Small delay between spawning jobs
            sleep $REQUEST_DELAY
        done
        
        # Get next batch link
        next_link=$(echo "$response" | jq -r '."@odata.nextLink"')
        if [ "$next_link" = "null" ]; then
            next_link=""
        fi
    done
    
    # Wait for all downloads to complete
    while [ $active_jobs -gt 0 ]; do
        wait -n
        active_jobs=$((active_jobs - 1))
    done
    
    if [ $retry_count -eq $MAX_RETRIES ]; then
        log_message "Failed to process folder after maximum retries: $folder_name"
        return 1
    fi
    
    return 0
}

# Function to get all root folders with pagination and expanded info
get_all_root_folders() {
    local next_link="https://graph.microsoft.com/v1.0/users/$SOURCE_EMAIL/mailFolders?\$top=999&\$expand=childFolders"
    local retry_count=0
    local folders=()
    
    while [ ! -z "$next_link" ] && [ "$retry_count" -lt "$MAX_RETRIES" ]; do
        log_message "Fetching batch of root folders..."
        
        # Rate limiting delay
        sleep $REQUEST_DELAY
        
        local response
        response=$(az rest --method GET \
            --url "$next_link" \
            --headers "ConsistencyLevel=eventual" \
            2>&1)
        
        if [ $? -ne 0 ]; then
            if echo "$response" | grep -q "ApplicationThrottled"; then
                log_message "Rate limited, waiting before retry..."
                sleep $RETRY_DELAY
                retry_count=$((retry_count + 1))
                continue
            else
                log_message "Failed to fetch root folders: $response"
                return 1
            fi
        fi
        
        # Log the raw response for debugging
        log_message "Retrieved folder data. Processing..."
        
        # Process folders in this batch
        echo "$response" | jq -c '.value[]' | while read -r folder; do
            local folder_id folder_name has_children
            folder_id=$(echo "$folder" | jq -r '.id')
            folder_name=$(echo "$folder" | jq -r '.displayName')
            has_children=$(echo "$folder" | jq -r '.childFolders | length')
            
            log_message "Found root folder: $folder_name (has $has_children children)"
            
            # Process the folder
            if ! process_folder "$folder_id" "$folder_name"; then
                log_message "Failed to process folder: $folder_name"
                continue
            fi
            
            # Process nested folders if we have children
            if [ "$has_children" -gt 0 ]; then
                log_message "Processing child folders for: $folder_name"
                process_nested_folders "$folder_id" "messages/${folder_name// /_}" 0
            fi
            
            # Rate limiting delay between root folders
            sleep $REQUEST_DELAY
        done
        
        # Get next batch link - ensure we handle null properly
        next_link=$(echo "$response" | jq -r '."@odata.nextLink" // empty')
        
        if [ -z "$next_link" ]; then
            log_message "No more folder pages to process"
            break
        else
            log_message "Found next page of folders to process"
        fi
    done
    
    if [ "$retry_count" -ge "$MAX_RETRIES" ]; then
        log_message "Failed to get all root folders after $MAX_RETRIES retries"
        return 1
    fi
    
    return 0
}

# Function to process nested folders with retry and better logging
process_nested_folders() {
    local parent_id="$1"
    local parent_path="$2"
    local depth="${3:-0}"
    local max_depth=10  # Prevent infinite recursion
    local retries=0
    
    log_message "Processing nested folders under: $parent_path (depth: $depth)"
    
    # Prevent infinite recursion
    if [ "$depth" -ge "$max_depth" ]; then
        log_message "WARNING: Maximum folder depth reached for $parent_path"
        return 0
    fi
    
    while [ "$retries" -lt "$MAX_RETRIES" ]; do
        # Rate limiting delay
        sleep $REQUEST_DELAY
        
        # Get child folders with expanded info
        local response
        response=$(az rest --method GET \
            --url "https://graph.microsoft.com/v1.0/users/$SOURCE_EMAIL/mailFolders/$parent_id/childFolders?\$expand=childFolders&\$top=999" \
            --headers "ConsistencyLevel=eventual" \
            2>&1)
        
        if [ $? -eq 0 ]; then
            # Log number of child folders found
            local folder_count
            folder_count=$(echo "$response" | jq -r '.value | length')
            log_message "Found $folder_count child folders under $parent_path"
            
            # Process each child folder
            echo "$response" | jq -c '.value[]' | while read -r folder; do
                local folder_id folder_name has_children
                folder_id=$(echo "$folder" | jq -r '.id')
                folder_name=$(echo "$folder" | jq -r '.displayName')
                has_children=$(echo "$folder" | jq -r '.childFolders | length')
                
                log_message "Processing child folder: $folder_name (has $has_children subfolders)"
                
                # Create folder path
                local folder_path="$parent_path/${folder_name// /_}"
                
                # Process this folder's messages
                if ! process_folder "$folder_id" "$folder_name" "$folder_path"; then
                    log_message "Failed to process folder: $folder_name"
                    continue
                fi
                
                # If folder has children, process them recursively
                if [ "$has_children" -gt 0 ]; then
                    log_message "Recursing into subfolder: $folder_name"
                    process_nested_folders "$folder_id" "$folder_path" "$((depth + 1))"
                fi
                
                # Rate limiting delay between folders
                sleep $REQUEST_DELAY
            done
            return 0
        elif echo "$response" | grep -q "ApplicationThrottled"; then
            log_message "Rate limited while getting child folders, waiting before retry..."
            sleep $RETRY_DELAY
            retries=$((retries + 1))
            continue
        else
            log_message "Failed to get child folders: $response"
            return 1
        fi
    done
    
    log_message "Failed to process nested folders after $MAX_RETRIES retries for $parent_path"
    return 1
}



# Main execution
main() {
    log_message "Starting migration script v29 - Download Phase..."
    
    # Create base messages directory and initialize statistics
    mkdir -p messages
    init_stats
    
    # Check Azure authentication with retry
    if ! check_azure_auth; then
        log_message "Authentication failed after all attempts"
        exit 1
    fi
    
    # Verify Graph API access
    if ! verify_graph_access; then
        log_message "Failed to verify Graph API access"
        log_message "Please ensure application has necessary permissions"
        exit 1
    fi
    
    # Test mailbox existence
    if ! test_mailbox_existence; then
        log_message "Failed to verify mailbox existence"
        log_message "Please verify:"
        log_message "1. The mailbox $SOURCE_EMAIL exists"
        log_message "2. Application has necessary permissions"
        log_message "3. The mailbox is properly licensed"
        exit 1
    fi
    
    # Get root folders with retry
    # local retries=0
    # local response=""
    if ! get_all_root_folders; then
    log_message "Failed to get all root folders"
    exit 1
fi
    
    while [ $retries -lt $MAX_RETRIES ]; do
        response=$(az rest --method GET \
            --url "https://graph.microsoft.com/v1.0/users/$SOURCE_EMAIL/mailFolders" \
            --headers "ConsistencyLevel=eventual" \
            2>&1)
        
        if [ $? -eq 0 ]; then
            break
        elif echo "$response" | grep -q "ApplicationThrottled"; then
            log_message "Rate limited, waiting before retry..."
            sleep $RETRY_DELAY
            retries=$((retries + 1))
            continue
        else
            log_message "Failed to get root folders: $response"
            exit 1
        fi
    done
    
    if [ $retries -eq $MAX_RETRIES ]; then
        log_message "Failed to get root folders after $MAX_RETRIES retries"
        exit 1
    fi
    
    # Process each root folder
    echo "$response" | jq -c '.value[]' | while read -r folder; do
        local folder_id folder_name
        folder_id=$(echo "$folder" | jq -r '.id')
        folder_name=$(echo "$folder" | jq -r '.displayName')
        
        # Process the folder
        if ! process_folder "$folder_id" "$folder_name"; then
            log_message "Failed to process folder: $folder_name"
            continue
        fi
        
        # Process nested folders
        process_nested_folders "$folder_id" "messages/${folder_name// /_}"
        
        # Rate limiting delay between root folders
        sleep $REQUEST_DELAY
    done
    
    # Ensure all background jobs are complete
    wait
    
    # Print final statistics
    print_summary
    
    # Save statistics to file
    jq -n --arg total "$total_messages" \
          --arg size "$total_size" \
          --arg failed "$total_failed" \
          --arg time "$(date '+%Y-%m-%d %H:%M:%S')" \
          '{"total_messages": $total, "total_size": $size, "failed_downloads": $failed, "completed_at": $time}' > "$STATS_FILE"
    
    log_message "Download phase completed successfully"
}



# Run main function
main
