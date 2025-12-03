#!/bin/bash
#===============================================================================
# backup.sh - Automated Backup Script with Rotation
# Author: Mikhail Miasnikou
# Description: Creates compressed backups of specified directories with 
#              automatic rotation (keeps last N backups)
# Usage: ./backup.sh [config_file]
#===============================================================================

set -euo pipefail

# === CONFIGURATION ===
BACKUP_SOURCE="${BACKUP_SOURCE:-/home/user/data}"          # What to backup
BACKUP_DEST="${BACKUP_DEST:-/backup}"                       # Where to store
BACKUP_PREFIX="${BACKUP_PREFIX:-backup}"                    # Filename prefix
RETENTION_DAYS="${RETENTION_DAYS:-7}"                       # Keep backups for N days
LOG_FILE="${LOG_FILE:-/var/log/backup.log}"                 # Log file path
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"                # Optional: Telegram alerts
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"                    # Optional: Telegram chat ID

# === COLORS FOR OUTPUT ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# === FUNCTIONS ===

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

send_telegram() {
    local message="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$message" \
            -d parse_mode="HTML" > /dev/null 2>&1 || true
    fi
}

check_requirements() {
    local missing=()
    for cmd in tar gzip find df; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR" "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

check_disk_space() {
    local dest_dir="$1"
    local required_mb="$2"
    
    local available_mb=$(df -m "$dest_dir" | awk 'NR==2 {print $4}')
    
    if [[ $available_mb -lt $required_mb ]]; then
        log "ERROR" "Not enough disk space. Available: ${available_mb}MB, Required: ${required_mb}MB"
        send_telegram "🔴 <b>Backup Failed</b>%0ANot enough disk space on ${dest_dir}%0AAvailable: ${available_mb}MB"
        exit 1
    fi
    
    log "INFO" "Disk space OK. Available: ${available_mb}MB"
}

create_backup() {
    local source="$1"
    local dest="$2"
    local prefix="$3"
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_name="${prefix}_${timestamp}.tar.gz"
    local backup_path="${dest}/${backup_name}"
    
    log "INFO" "Starting backup: ${source} -> ${backup_path}"
    
    # Create backup directory if not exists
    mkdir -p "$dest"
    
    # Create compressed archive
    if tar -czf "$backup_path" -C "$(dirname "$source")" "$(basename "$source")" 2>> "$LOG_FILE"; then
        local size=$(du -h "$backup_path" | cut -f1)
        log "INFO" "Backup created successfully: ${backup_name} (${size})"
        send_telegram "✅ <b>Backup Completed</b>%0AFile: ${backup_name}%0ASize: ${size}"
        echo "$backup_path"
    else
        log "ERROR" "Backup creation failed"
        send_telegram "🔴 <b>Backup Failed</b>%0ASource: ${source}%0ACheck logs for details"
        exit 1
    fi
}

rotate_backups() {
    local dest="$1"
    local prefix="$2"
    local retention="$3"
    
    log "INFO" "Rotating backups older than ${retention} days"
    
    local deleted=0
    while IFS= read -r -d '' file; do
        log "INFO" "Deleting old backup: $(basename "$file")"
        rm -f "$file"
        ((deleted++))
    done < <(find "$dest" -name "${prefix}_*.tar.gz" -mtime +"$retention" -print0 2>/dev/null)
    
    log "INFO" "Rotation complete. Deleted ${deleted} old backup(s)"
}

show_backup_status() {
    local dest="$1"
    local prefix="$2"
    
    echo ""
    echo "=== Current Backups ==="
    local count=0
    local total_size=0
    
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            local size=$(du -h "$file" | cut -f1)
            local date=$(stat -c %y "$file" | cut -d' ' -f1)
            echo "  $(basename "$file") - ${size} - ${date}"
            ((count++))
        fi
    done < <(find "$dest" -name "${prefix}_*.tar.gz" -type f 2>/dev/null | sort -r)
    
    echo "=== Total: ${count} backup(s) ==="
    echo ""
}

# === MAIN ===

main() {
    log "INFO" "========== Backup Started =========="
    
    # Load config file if provided
    if [[ -n "${1:-}" && -f "$1" ]]; then
        log "INFO" "Loading config: $1"
        source "$1"
    fi
    
    # Validate configuration
    if [[ ! -d "$BACKUP_SOURCE" ]]; then
        log "ERROR" "Source directory does not exist: $BACKUP_SOURCE"
        exit 1
    fi
    
    # Check requirements
    check_requirements
    
    # Check disk space (estimate: source size * 1.5)
    local source_size_mb=$(du -sm "$BACKUP_SOURCE" | cut -f1)
    local required_mb=$((source_size_mb * 3 / 2))
    check_disk_space "$BACKUP_DEST" "$required_mb"
    
    # Create backup
    create_backup "$BACKUP_SOURCE" "$BACKUP_DEST" "$BACKUP_PREFIX"
    
    # Rotate old backups
    rotate_backups "$BACKUP_DEST" "$BACKUP_PREFIX" "$RETENTION_DAYS"
    
    # Show status
    show_backup_status "$BACKUP_DEST" "$BACKUP_PREFIX"
    
    log "INFO" "========== Backup Finished =========="
}

# Run main function
main "$@"
