#!/bin/sh
#
# decrypt-from-onedrive.sh
#
# Selectively decrypt GPG-encrypted files from an OneDrive folder
# back to the local filesystem.
#
# Requires:
#   - gpg        (GNU Privacy Guard)
#   - jq         (JSON processor, install with: brew install jq)
#   - YubiKey    (or any GPG smart card / key available to gpg-agent)
#
# Configuration is read from decrypt-config.json in the same directory.
# See decrypt.md for full usage instructions.
#

set -eu

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Resolve the directory where this script lives so that config and log paths
# are always relative to the script, regardless of where it is called from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/decrypt-config.json"

# ---------------------------------------------------------------------------
# Terminal colours (used only when stdout is a terminal)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'   # reset / no colour

# ---------------------------------------------------------------------------
# Counters – updated by process_gpg_file()
# ---------------------------------------------------------------------------
decrypted_count=0
skipped_count=0
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

# Read all settings from decrypt-config.json and initialise global variables.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED}[ERROR]${NC} Config file not found: %s\n" "$CONFIG_FILE"
        exit 1
    fi

    # Directory inside OneDrive that holds encrypted (.gpg) files.
    SOURCE_DIR=$(expand_path "$(jq -r '.source_dir' "$CONFIG_FILE")")

    # Local directory where decrypted files will be written.
    DEST_DIR=$(expand_path "$(jq -r '.dest_dir' "$CONFIG_FILE")")

    # Directory and filename for the log file.
    LOG_DIR=$(expand_path "$(jq -r '.log_dir' "$CONFIG_FILE")")
    LOG_FILENAME=$(jq -r '.log_file' "$CONFIG_FILE")
    LOG_FILE="$LOG_DIR/$LOG_FILENAME"

    # Create log directory if it does not exist yet.
    mkdir -p "$LOG_DIR"

    # Comma- / newline-separated list of relative paths inside SOURCE_DIR to process.
    # Leave the array empty in the JSON to process nothing (safe default).
    INCLUDED_DIRS=$(jq -r '.included_dirs[]' "$CONFIG_FILE" 2>/dev/null || echo "")

    # Write a session header to the log file.
    echo ""                                          >> "$LOG_FILE"
    echo "==========================================" >> "$LOG_FILE"
    echo "[$(timestamp)] DECRYPT SESSION STARTED"    >> "$LOG_FILE"
    echo "==========================================" >> "$LOG_FILE"

    log_info "Config loaded from: $CONFIG_FILE"
    log_info "Source (OneDrive):  $SOURCE_DIR"
    log_info "Destination:        $DEST_DIR"
    log_info "Log file:           $LOG_FILE"
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
# macOS OneDrive Files On Demand helper
# ---------------------------------------------------------------------------

# Release the local copy of an OneDrive file after decryption so OneDrive
# can evict it from disk (macOS brctl / Files On Demand).
# Silently ignored on non-macOS systems or when brctl is unavailable.
free_local_copy() {
    _file="$1"
    if command -v brctl >/dev/null 2>&1; then
        brctl evict "$_file" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Core decryption logic
# ---------------------------------------------------------------------------

# Decrypt a single .gpg file to the destination tree, preserving the relative
# directory structure found under SOURCE_DIR.
process_gpg_file() {
    _gpg_file="$1"

    # Compute the path of this file relative to the OneDrive source root.
    _relative_path="${_gpg_file#$SOURCE_DIR/}"

    # Build the destination path by stripping the .gpg extension.
    _dest_file="$DEST_DIR/${_relative_path%.gpg}"
    _dest_dir=$(dirname "$_dest_file")

    # Skip files that have already been decrypted locally.
    if [ -f "$_dest_file" ]; then
        log_warn "Already exists: ${_relative_path%.gpg}"
        skipped_count=$((skipped_count + 1))
        return
    fi

    # Ensure destination directory exists.
    mkdir -p "$_dest_dir"

    log_info "Decrypting: $_relative_path"

    if gpg --decrypt --output "$_dest_file" "$_gpg_file" 2>/dev/null; then
        log_success "Decrypted: $_dest_file"
        decrypted_count=$((decrypted_count + 1))

        # Optionally free the local OneDrive copy after a successful decrypt.
        free_local_copy "$_gpg_file"
    else
        log_error "Failed to decrypt: $_relative_path"
        error_count=$((error_count + 1))
    fi
}

# Recursively walk a directory and decrypt every .gpg file found.
process_directory() {
    _dir="$1"

    for _item in "$_dir"/*; do
        [ -e "$_item" ] || continue

        if [ -d "$_item" ]; then
            # Recurse into sub-directories.
            process_directory "$_item"
        elif [ -f "$_item" ]; then
            case "$_item" in
                *.gpg)
                    process_gpg_file "$_item"
                    ;;
                # Non-.gpg files are silently ignored.
            esac
        fi
    done
}

# ---------------------------------------------------------------------------
# Entry point for decryption
# ---------------------------------------------------------------------------

# Iterate over every path listed in included_dirs and decrypt its contents.
decrypt_files() {
    log_info "Starting decryption..."
    printf "\n"

    # Ensure destination root exists.
    mkdir -p "$DEST_DIR"

    if [ -z "$INCLUDED_DIRS" ]; then
        log_error "included_dirs is empty in $CONFIG_FILE"
        log_error "Add at least one path relative to source_dir and re-run."
        exit 1
    fi

    echo "$INCLUDED_DIRS" | while IFS= read -r _rel_dir; do
        [ -z "$_rel_dir" ] && continue

        _full_path="$SOURCE_DIR/$_rel_dir"

        if [ -d "$_full_path" ]; then
            log_info "Processing directory: $_rel_dir"
            process_directory "$_full_path"
        elif [ -f "$_full_path" ]; then
            # Support specifying a single .gpg file directly.
            case "$_full_path" in
                *.gpg)
                    process_gpg_file "$_full_path"
                    ;;
            esac
        else
            log_warn "Not found in OneDrive: $_rel_dir"
        fi
    done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
    printf "\n"
    printf "==========================================\n"
    printf "           DECRYPTION SUMMARY\n"
    printf "==========================================\n"
    printf "${GREEN}Files decrypted:  %d${NC}\n" "$decrypted_count"
    printf "${YELLOW}Files skipped:    %d${NC}\n" "$skipped_count"
    printf "${RED}Errors:           %d${NC}\n" "$error_count"
    printf "==========================================\n"
    printf "\n"
    log_info "Files restored to: $DEST_DIR"

    echo "==========================================" >> "$LOG_FILE"
    echo "[$(timestamp)] SUMMARY: Decrypted=$decrypted_count, Skipped=$skipped_count, Errors=$error_count" >> "$LOG_FILE"
    echo "[$(timestamp)] DECRYPT SESSION ENDED"       >> "$LOG_FILE"
    echo "==========================================" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    printf "\n"
    printf "==========================================\n"
    printf "   Selective GPG Decrypt from OneDrive\n"
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

    # Verify that the OneDrive source directory is accessible.
    if [ ! -d "$SOURCE_DIR" ]; then
        log_error "Source directory not found: $SOURCE_DIR"
        log_error "Make sure OneDrive is mounted and synced."
        exit 1
    fi

    decrypt_files
    print_summary
}

main "$@"
