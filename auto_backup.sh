#!/bin/bash

# --- Configuration ---
CONFIG_FILE="$HOME/.sentinel_db.conf"
CRON_TAG="# SENTINEL_DB_BACKUP"
BACKUP_DIR="$HOME/db_backups"
RETENTION_DAYS=30

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# Safely extract values from config
get_cfg() {
    grep "^$1=" "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/^"//;s/"$//'
}

check_deps() {
    for cmd in mysql mysqldump crontab; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd is not installed."
            exit 1
        fi
    done
}

validate_and_save() {
    echo "--- Database Credentials Setup ---"
    read -p "MySQL Host (default: localhost): " db_host
    db_host=${db_host:-localhost}
    read -p "MySQL User: " db_user
    read -sp "MySQL Password (leave blank if none): " db_pass; echo ""
    read -p "Database Name: " db_name

    # Test connection
    TMP_CONF=$(mktemp)
    printf "[client]\nhost=\"%s\"\nuser=\"%s\"\npassword=\"%s\"\n" "$db_host" "$db_user" "$db_pass" > "$TMP_CONF"

    if mysql --defaults-extra-file="$TMP_CONF" "$db_name" -e "exit" 2>&1; then
        log_success "Credentials validated!"
        printf "DB_HOST=\"%s\"\nDB_USER=\"%s\"\nDB_PASS=\"%s\"\nDB_NAME=\"%s\"\n" "$db_host" "$db_user" "$db_pass" "$db_name" > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        log_error "Connection failed. Credentials not saved."
    fi
    rm -f "$TMP_CONF"
}

run_backup_logic() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration not found. Run Option 1."; return 1
    fi

    DB_HOST=$(get_cfg "DB_HOST")
    DB_USER=$(get_cfg "DB_USER")
    DB_PASS=$(get_cfg "DB_PASS")
    DB_NAME=$(get_cfg "DB_NAME")

    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    FILE="$BACKUP_DIR/${DB_NAME}_$TIMESTAMP.sql"

    # Temporary login config
    CNF=$(mktemp)
    printf "[client]\nhost=\"%s\"\nuser=\"%s\"\npassword=\"%s\"\n" "$DB_HOST" "$DB_USER" "$DB_PASS" > "$CNF"

    log_info "Backing up $DB_NAME..."
    if mysqldump --defaults-extra-file="$CNF" --single-transaction --quick --lock-tables=false "$DB_NAME" > "$FILE"; then
        log_success "Backup created: $FILE"
        
        # --- Housekeeping: Delete files older than 30 days ---
        log_info "Cleaning up old backups (older than $RETENTION_DAYS days)..."
        find "$BACKUP_DIR" -type f -name "${DB_NAME}_*.sql" -mtime +$RETENTION_DAYS -exec rm {} \;
        log_success "Retention policy applied."
    else
        log_error "Backup failed!"
        rm -f "$FILE"
    fi
    rm -f "$CNF"
}

manage_cron() {
    echo -e "\n--- Schedule Management ---"
    echo "1) Daily (00:00)"
    echo "2) Weekly (Sunday 00:00)"
    echo "3) Disable / Remove Auto-Backup"
    read -p "Choice: " c_opt

    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -

    case $c_opt in
        1) (crontab -l 2>/dev/null; echo "0 0 * * * $(realpath $0) --internal-run $CRON_TAG") | crontab - 
           log_success "Scheduled: Daily" ;;
        2) (crontab -l 2>/dev/null; echo "0 0 * * 0 $(realpath $0) --internal-run $CRON_TAG") | crontab - 
           log_success "Scheduled: Weekly" ;;
        3) log_success "Cron jobs removed." ;;
    esac
}

# --- Entry Point ---
if [[ "$1" == "--internal-run" ]]; then
    run_backup_logic
    exit 0
fi

check_deps
while true; do
    echo -e "\n--- Sentinel-DB Backup Manager ---"
    echo "1) Setup/Update Credentials"
    echo "2) Run Manual Backup (with 30-day cleanup)"
    echo "3) Configure/Disable Cron"
    echo "4) Uninstall (Wipe everything)"
    echo "5) Exit"
    read -p "Option: " opt
    case $opt in
        1) validate_and_save ;;
        2) run_backup_logic ;;
        3) manage_cron ;;
        4) 
            rm -f "$CONFIG_FILE"
            crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
            log_success "Credentials and schedules removed." 
            ;;
        5) exit 0 ;;
    esac
done
