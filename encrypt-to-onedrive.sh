#!/bin/sh
#
# encrypt-to-onedrive.sh
#
# Encrypt local files with GPG and copy them to OneDrive for off-site backup.
#
# Requires:
#   - gpg        (GNU Privacy Guard)
#   - jq         (JSON processor, install with: brew install jq)
#   - YubiKey    (or any GPG smart card / key available to gpg-agent)
#
# Configuration is read from encrypt-config.json in the same directory.
# See encrypt.md for full usage instructions.
#

set -eu

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Resolve the directory where this script lives so that config and log paths
# are always relative to the script, regardless of where it is called from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/encrypt-config.json"

# ---------------------------------------------------------------------------
# Terminal colours (used only when stdout is a terminal)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'   # reset / no colour

# ---------------------------------------------------------------------------
# Counters – updated throughout processing
# ---------------------------------------------------------------------------
encrypted_count=0
skipped_count=0
copied_count=0
error_count=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Return current date-time in a log-friendly format.
timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

# Log an informational message to terminal and log file.
log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
    echo "[$(timestamp)] [INFO] $1" >> "$LOG_FILE"
}

# Log a skip/warning message.
log_warn() {
    printf "${YELLOW}[SKIP]${NC} %s\n" "$1"
    echo "[$(timestamp)] [SKIP] $1" >> "$LOG_FILE"
}

# Log an error message.
log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
    echo "[$(timestamp)] [ERROR] $1" >> "$LOG_FILE"
}

# Log a success message.
log_success() {
    printf "${BLUE}[OK]${NC} %s\n" "$1"
    echo "[$(timestamp)] [OK] $1" >> "$LOG_FILE"
}

# Expand a leading tilde (~) to the user's home directory.
expand_path() {
    echo "$1" | sed "s|^~|$HOME|"
}

# ---------------------------------------------------------------------------
# Configuration loader
# ---------------------------------------------------------------------------

# Read all settings from encrypt-config.json and initialise global variables.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED}[ERROR]${NC} Config file not found: %s\n" "$CONFIG_FILE"
        exit 1
    fi

    # OneDrive destination root; a /Documents sub-folder is appended automatically
    # to mirror the typical layout expected on the remote side.
    DEST_DIR=$(expand_path "$(jq -r '.dest_dir' "$CONFIG_FILE")")/Documents

    # Directory and filename for the log file.
    LOG_DIR=$(expand_path "$(jq -r '.log_dir' "$CONFIG_FILE")")
    LOG_FILENAME=$(jq -r '.log_file' "$CONFIG_FILE")
    LOG_FILE="$LOG_DIR/$LOG_FILENAME"

    # GPG key identifier (e-mail address or key fingerprint) used for encryption.
    # The public key for this recipient must be imported in the local GPG keyring.
    GPG_RECIPIENT=$(jq -r '.gpg_recipient' "$CONFIG_FILE")

    # Lists loaded from the JSON arrays.
    SOURCE_DIRS=$(jq -r '.source_dirs[]'    "$CONFIG_FILE" 2>/dev/null || echo "")
    COPY_ONLY_DIRS=$(jq -r '.copy_only_dirs[]' "$CONFIG_FILE" 2>/dev/null || echo "")
    EXCLUDED_DIRS=$(jq -r '.excluded_dirs[]'  "$CONFIG_FILE" 2>/dev/null || echo "")
    EXCLUDED_FILES=$(jq -r '.excluded_files[]' "$CONFIG_FILE" 2>/dev/null || echo "")

    # Create log directory if it does not exist yet.
    mkdir -p "$LOG_DIR"

    # Write a session header to the log file.
    echo ""                                          >> "$LOG_FILE"
    echo "==========================================" >> "$LOG_FILE"
    echo "[$(timestamp)] ENCRYPT SESSION STARTED"    >> "$LOG_FILE"
    echo "==========================================" >> "$LOG_FILE"

    log_info "Config loaded from:     $CONFIG_FILE"
    log_info "Destination (OneDrive): $DEST_DIR"
    log_info "GPG recipient:          $GPG_RECIPIENT"
    log_info "Log file:               $LOG_FILE"
}

# ---------------------------------------------------------------------------
# YubiKey / smart-card check
# ---------------------------------------------------------------------------

# Abort early if no GPG smart card (YubiKey) is accessible.
check_yubikey() {
    if ! gpg --card-status >/dev/null 2>&1; then
        log_error "YubiKey not detected. Please insert your YubiKey and try again."
        exit 1
    fi
    log_info "YubiKey detected and ready."
}

# ---------------------------------------------------------------------------
# Core encryption logic
# ---------------------------------------------------------------------------

# Encrypt a single source file and write it to the OneDrive destination tree
# with a .gpg extension appended.  Skips the file if the destination already
# exists and is newer than the source (i.e. nothing changed since last run).
encrypt_file() {
    _src_file="$1"
    _src_base="$2"   # root of the source directory tree (used to compute relative path)

    _relative_path="${_src_file#$_src_base/}"
    _dest_file="$DEST_DIR/${_relative_path}.gpg"
    _dest_dir=$(dirname "$_dest_file")

    # Skip if an up-to-date encrypted copy already exists in OneDrive.
    if [ -f "$_dest_file" ]; then
        if [ "$_dest_file" -nt "$_src_file" ]; then
            log_warn "Up to date: $_relative_path"
            skipped_count=$((skipped_count + 1))
            return
        fi
    fi

    mkdir -p "$_dest_dir"

    log_info "Encrypting: $_relative_path"

    # --batch --yes allows overwriting an existing (older) encrypted file
    # without interactive confirmation.
    if gpg --batch --yes --encrypt --recipient "$GPG_RECIPIENT" \
           --output "$_dest_file" "$_src_file" 2>/dev/null; then
        log_success "Encrypted: $_dest_file"
        encrypted_count=$((encrypted_count + 1))
    else
        log_error "Failed to encrypt: $_relative_path"
        error_count=$((error_count + 1))
    fi
}

# Copy a single file verbatim (no encryption) to OneDrive.
# Intended for directories whose content is already encrypted, such as a
# pass(1) password store (.password-store).
copy_file() {
    _src_file="$1"
    _src_base="$2"

    _relative_path="${_src_file#$_src_base/}"
    _base_name=$(basename "$_src_base")
    _dest_file="$DEST_DIR/$_base_name/$_relative_path"
    _dest_dir=$(dirname "$_dest_file")

    # Skip if an up-to-date copy already exists.
    if [ -f "$_dest_file" ]; then
        if [ "$_dest_file" -nt "$_src_file" ]; then
            log_warn "Up to date: $_base_name/$_relative_path"
            skipped_count=$((skipped_count + 1))
            return
        fi
    fi

    mkdir -p "$_dest_dir"

    if cp "$_src_file" "$_dest_file" 2>/dev/null; then
        log_success "Copied: $_base_name/$_relative_path"
        copied_count=$((copied_count + 1))
    else
        log_error "Failed to copy: $_relative_path"
        error_count=$((error_count + 1))
    fi
}

# Recursively walk a directory tree.
# _mode is either "encrypt" (GPG-encrypt each file) or "copy" (plain copy).
process_directory() {
    _dir="$1"
    _base="$2"
    _mode="$3"

    for _item in "$_dir"/*; do
        [ -e "$_item" ] || continue

        _basename=$(basename "$_item")

        if [ -d "$_item" ]; then
            # Check whether this directory name appears in excluded_dirs.
            _skip=false
            echo "$EXCLUDED_DIRS" | while IFS= read -r _excl; do
                [ -z "$_excl" ] && continue
                if [ "$_basename" = "$_excl" ]; then
                    echo "skip"
                    break
                fi
            done | grep -q "skip" && _skip=true

            if [ "$_skip" = "true" ]; then
                log_warn "Excluded dir: $_item"
                continue
            fi

            process_directory "$_item" "$_base" "$_mode"

        elif [ -f "$_item" ]; then
            # Check whether this filename matches any pattern in excluded_files.
            _skip_file=false
            echo "$EXCLUDED_FILES" | while IFS= read -r _pattern; do
                [ -z "$_pattern" ] && continue
                case "$_basename" in
                    $_pattern)
                        echo "skip"
                        break
                        ;;
                esac
            done | grep -q "skip" && _skip_file=true

            if [ "$_skip_file" = "true" ]; then
                continue
            fi

            if [ "$_mode" = "encrypt" ]; then
                encrypt_file "$_item" "$_base"
            else
                copy_file "$_item" "$_base"
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# Entry point for encryption
# ---------------------------------------------------------------------------

# Process all directories listed in source_dirs (encrypt) and
# copy_only_dirs (plain copy).
encrypt_files() {
    log_info "Starting encryption..."
    printf "\n"

    mkdir -p "$DEST_DIR"

    # --- Encrypt source directories ---
    echo "$SOURCE_DIRS" | while IFS= read -r _src_dir; do
        [ -z "$_src_dir" ] && continue
        _expanded=$(expand_path "$_src_dir")

        if [ -d "$_expanded" ]; then
            log_info "Processing source: $_src_dir"
            process_directory "$_expanded" "$_expanded" "encrypt"
        else
            log_warn "Source not found: $_src_dir"
        fi
    done

    # --- Copy-only directories (already encrypted, copied verbatim) ---
    echo "$COPY_ONLY_DIRS" | while IFS= read -r _copy_dir; do
        [ -z "$_copy_dir" ] && continue
        _expanded=$(expand_path "$_copy_dir")

        if [ -d "$_expanded" ]; then
            log_info "Copying (no encrypt): $_copy_dir"
            process_directory "$_expanded" "$_expanded" "copy"
        else
            log_warn "Copy dir not found: $_copy_dir"
        fi
    done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
    printf "\n"
    printf "==========================================\n"
    printf "           ENCRYPTION SUMMARY\n"
    printf "==========================================\n"
    printf "${GREEN}Files encrypted:  %d${NC}\n" "$encrypted_count"
    printf "${BLUE}Files copied:     %d${NC}\n" "$copied_count"
    printf "${YELLOW}Files skipped:    %d${NC}\n" "$skipped_count"
    printf "${RED}Errors:           %d${NC}\n" "$error_count"
    printf "==========================================\n"
    printf "\n"
    log_info "Encrypted files saved to: $DEST_DIR"

    echo "==========================================" >> "$LOG_FILE"
    echo "[$(timestamp)] SUMMARY: Encrypted=$encrypted_count, Copied=$copied_count, Skipped=$skipped_count, Errors=$error_count" >> "$LOG_FILE"
    echo "[$(timestamp)] ENCRYPT SESSION ENDED"       >> "$LOG_FILE"
    echo "==========================================" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    printf "\n"
    printf "==========================================\n"
    printf "   GPG File Encryption to OneDrive\n"
    printf "==========================================\n"
    printf "\n"

    # Verify that jq is available before doing anything else.
    if ! command -v jq >/dev/null 2>&1; then
        printf "${RED}[ERROR]${NC} jq is required but not installed.\n"
        printf "Install it with:  brew install jq\n"
        exit 1
    fi

    load_config
    check_yubikey
    encrypt_files
    print_summary
}

main "$@"
