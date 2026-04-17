#!/bin/bash

# --- Configuration ---
CONFIG_FILE="$HOME/.sentinel_db.conf"
CRON_TAG="# SENTINEL_DB_BACKUP"
BACKUP_DIR="$HOME/db_backups"
RETENTION_DAYS=10

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

set_cfg() {
    local key=$1 val=$2
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=\"${val}\"|" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
    else
        echo "${key}=\"${val}\"" >> "$CONFIG_FILE"
    fi
}

check_deps() {
    for cmd in mysql mysqldump crontab curl base64; do
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

load_retention() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local saved=$(get_cfg "RETENTION_DAYS")
        [[ -n "$saved" ]] && RETENTION_DAYS=$saved
    fi
}

configure_retention() {
    load_retention
    echo -e "\n--- Retention Policy ---"
    echo "Current: $([ "$RETENTION_DAYS" -eq 0 ] && echo "Disabled" || echo "$RETENTION_DAYS days")"
    echo "Set to 0 to disable automatic cleanup."
    read -p "Retention days (default: $RETENTION_DAYS): " new_days
    new_days=${new_days:-$RETENTION_DAYS}

    if ! [[ "$new_days" =~ ^[0-9]+$ ]]; then
        log_error "Invalid number."; return 1
    fi

    RETENTION_DAYS=$new_days

    if [[ -f "$CONFIG_FILE" ]]; then
        grep -q "^RETENTION_DAYS=" "$CONFIG_FILE" \
            && sed -i.bak "s/^RETENTION_DAYS=.*/RETENTION_DAYS=\"$RETENTION_DAYS\"/" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak" \
            || echo "RETENTION_DAYS=\"$RETENTION_DAYS\"" >> "$CONFIG_FILE"
    else
        echo "RETENTION_DAYS=\"$RETENTION_DAYS\"" > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    fi

    if [[ "$RETENTION_DAYS" -eq 0 ]]; then
        log_success "Old backup cleanup disabled."
    else
        log_success "Old backups will be deleted after $RETENTION_DAYS days."
    fi
}

run_backup_logic() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration not found. Run Option 1."; return 1
    fi

    load_retention

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
        
        if [[ "$RETENTION_DAYS" -gt 0 ]]; then
            log_info "Cleaning up backups older than $RETENTION_DAYS days..."
            find "$BACKUP_DIR" -type f -name "${DB_NAME}_*.sql" -mtime +$RETENTION_DAYS -exec rm {} \;
            log_success "Retention policy applied."
        else
            log_info "Retention cleanup disabled."
        fi
    else
        log_error "Backup failed!"
        rm -f "$FILE"
    fi
    rm -f "$CNF"
}

configure_email() {
    echo -e "\n--- Email Notification Setup ---"
    local current_enabled=$(get_cfg "EMAIL_ENABLED")
    local current_email=$(get_cfg "BACKUP_EMAIL")

    if [[ "$current_enabled" == "true" ]]; then
        echo "Status: ENABLED (sending to $current_email)"
        echo "1) Update settings"
        echo "2) Disable email notifications"
        echo "3) Back"
        read -p "Choice: " e_opt
        case $e_opt in
            1) ;; # fall through to setup below
            2)
                sed -i.bak 's/^EMAIL_ENABLED=.*/EMAIL_ENABLED="false"/' "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
                log_success "Email notifications disabled."
                return ;;
            *) return ;;
        esac
    fi

    read -p "Resend API Key: " api_key
    if [[ -z "$api_key" ]]; then
        log_error "API key cannot be empty."; return 1
    fi

    read -p "Recipient email address: " email_addr
    if [[ -z "$email_addr" ]]; then
        log_error "Email cannot be empty."; return 1
    fi

    set_cfg "RESEND_API_KEY" "$api_key"
    set_cfg "BACKUP_EMAIL" "$email_addr"
    set_cfg "EMAIL_ENABLED" "true"
    chmod 600 "$CONFIG_FILE"

    log_success "Email notifications enabled — backups will be sent to $email_addr"
}

send_backup_email() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration not found. Run Option 1."; return 1
    fi

    local enabled=$(get_cfg "EMAIL_ENABLED")
    if [[ "$enabled" != "true" ]]; then
        log_error "Email notifications are not enabled. Enable them first."; return 1
    fi

    local api_key=$(get_cfg "RESEND_API_KEY")
    local email=$(get_cfg "BACKUP_EMAIL")
    local db_name=$(get_cfg "DB_NAME")

    local today=$(date +"%Y%m%d")
    local latest_file=$(ls -t "$BACKUP_DIR"/${db_name}_${today}*.sql 2>/dev/null | head -1)

    if [[ -z "$latest_file" ]]; then
        log_error "No backup found for today ($today). Run a backup first."; return 1
    fi

    log_info "Sending $(basename "$latest_file") to $email..."

    local filename=$(basename "$latest_file")
    local subject="Sentinel-DB Backup — $db_name — $(date +"%Y-%m-%d")"

    local payload_file=$(mktemp)
    local encoded_file=$(mktemp)

    base64 < "$latest_file" | tr -d '\n' > "$encoded_file"

    printf '{"from":"Sentinel-DB <onboarding@resend.dev>","to":["%s"],"subject":"%s","text":"Attached is today'\''s database backup for %s.\\nFile: %s","attachments":[{"filename":"%s","content":"' \
        "$email" "$subject" "$db_name" "$filename" "$filename" > "$payload_file"
    cat "$encoded_file" >> "$payload_file"
    printf '"}]}' >> "$payload_file"

    rm -f "$encoded_file"

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST 'https://api.resend.com/emails' \
        -H "Authorization: Bearer $api_key" \
        -H 'Content-Type: application/json' \
        -d @"$payload_file")

    rm -f "$payload_file"

    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        log_success "Backup emailed to $email"
    else
        log_error "Failed to send email (HTTP $http_code): $body"
    fi
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
    [[ "$(get_cfg "EMAIL_ENABLED")" == "true" ]] && send_backup_email
    exit 0
fi

check_deps
while true; do
    load_retention
    retention_label=$([ "$RETENTION_DAYS" -eq 0 ] && echo "disabled" || echo "${RETENTION_DAYS}-day cleanup")
    email_enabled=$(get_cfg "EMAIL_ENABLED")
    email_label=$([[ "$email_enabled" == "true" ]] && echo "enabled" || echo "disabled")

    echo -e "\n--- Sentinel-DB Backup Manager ---"
    echo "1) Setup/Update Credentials"
    echo "2) Run Manual Backup ($retention_label)"
    echo "3) Configure Retention Policy (currently: $retention_label)"
    echo "4) Configure/Disable Cron"
    echo "5) Email Notifications (currently: $email_label)"
    echo "6) Send Today's Backup via Email Now"
    echo "7) Uninstall (Wipe everything)"
    echo "8) Exit"
    read -p "Option: " opt
    case $opt in
        1) validate_and_save ;;
        2) run_backup_logic ;;
        3) configure_retention ;;
        4) manage_cron ;;
        5) configure_email ;;
        6) send_backup_email ;;
        7) 
            rm -f "$CONFIG_FILE"
            crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
            log_success "Credentials and schedules removed." 
            ;;
        8) exit 0 ;;
    esac
done
