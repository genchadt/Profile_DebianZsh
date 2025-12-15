#!/bin/bash

# --- CONFIGURATION & ROBUSTNESS ---
# Exit immediately if a command exits with a non-zero status.
# Exit immediately if an unset variable is used.
# The exit status of a pipeline is the status of the last command to exit non-zero.
set -euo pipefail

TARGET_LABEL="PRINT_TECH"
QUICK_MODE=0 # Use 0/1 for boolean flags
FORCED_FORMAT=0

# Colors (Output directed to stderr for professional logging)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- HELPER FUNCTIONS (Output directed to STDERR >&2) ---
log_info() { echo -e "${CYAN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_crit() { echo -e "${RED}[CRIT]${NC} $1" >&2; exit 1; }
log_success() { echo -e "${GREEN}[DONE]${NC} $1" >&2; }

usage() {
    echo "Usage: $0 [OPTIONS]" >&2
    echo "" >&2
    echo "This script formats a selected USB drive to FAT32 with label '$TARGET_LABEL'." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  -q, --quick   Run in quick mode (implies -y)." >&2
    echo "  -y, --forced  Automatically confirm the formatting prompt." >&2
    echo "  -h, --help    Show this help message." >&2
    exit 1
}

# --- ARGUMENT PARSING ---
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -q|--quick)
            QUICK_MODE=1
            FORCED_FORMAT=1
            shift
            ;;
        -y|--forced)
            FORCED_FORMAT=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_crit "Unknown parameter: $1"
            ;; # log_crit handles exit
    esac
done

# --- PRE-CHECKS ---
if [[ $EUID -ne 0 ]]; then
    log_crit "This script must be run as root (use sudo)."
fi

# Define required commands
REQUIRED_CMDS="lsblk mkfs.vfat parted wipefs"

for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then
        log_crit "Dependency not found: '$cmd'. Please install it."
    fi
done

# --- DETECTION LOGIC ---
echo -e "----------------------------------------" >&2
echo -e "    USB AUTO-FORMATTER -> ${YELLOW}FAT32${NC}" >&2
[[ "$QUICK_MODE" -eq 1 ]] && echo -e "${GREEN}    QUICK MODE ENABLED (-q)${NC}" >&2
echo -e "----------------------------------------" >&2

# 1. Check for existing device with the target label
EXISTING_DEV=$(lsblk -n -o PKNAME,LABEL 2>/dev/null | awk -v label="$TARGET_LABEL" '$2 == label {print $1; exit}')
CANDIDATE=""

if [[ -n "$EXISTING_DEV" ]]; then
    CANDIDATE="/dev/$EXISTING_DEV"
    log_success "Detected existing '$TARGET_LABEL' drive at: ${CANDIDATE}"
else
    log_info "Label '$TARGET_LABEL' not found. Scanning for USB devices..."

    # Extract all USB disk devices
    # Filter for disks (TYPE=disk) that use a USB TRANsport
    mapfile -t USB_DEVICES < <(lsblk -d -n -o NAME,SIZE,MODEL,TRAN,TYPE 2>/dev/null | awk '/usb/ && /disk/ {print}')

    NUM_FOUND=${#USB_DEVICES[@]}

    if [[ $NUM_FOUND -eq 0 ]]; then
        log_crit "No USB storage devices detected."
    elif [[ $NUM_FOUND -eq 1 ]]; then
        RAW_LINE="${USB_DEVICES[0]}"
        DEV_NAME=$(echo "$RAW_LINE" | awk '{print $1}')
        CANDIDATE="/dev/$DEV_NAME"
        log_info "Heuristic match: Found single USB device: $CANDIDATE"
    else
        log_warn "Multiple USB devices found. Please select one:"
        PS3="Select device number: "

        select opt in "${USB_DEVICES[@]}"; do
            if [[ -n "$opt" ]]; then
                DEV_NAME=$(echo "$opt" | awk '{print $1}')
                CANDIDATE="/dev/$DEV_NAME"
                break
            fi
            echo "Invalid selection." >&2
        done
    fi
fi

# --- SAFETY CHECKS ---
[[ -z "$CANDIDATE" ]] && log_crit "No device selected. Exiting."

# Check if device is the system root ('/') or currently mounted
DEVICE_INFO=$(lsblk -dn -o NAME,MOUNTPOINT "$CANDIDATE" 2>/dev/null)
IS_ROOT=$(echo "$DEVICE_INFO" | awk '$2=="/"')
IS_MOUNTED=$(echo "$DEVICE_INFO" | awk '$2!=""')
MODEL=$(lsblk -dn -o MODEL "$CANDIDATE" 2>/dev/null)
SIZE=$(lsblk -dn -o SIZE "$CANDIDATE" 2>/dev/null)

if [[ -n "$IS_ROOT" ]]; then
    log_crit "SAFETY TRIGGERED: $CANDIDATE appears to be the system root. Aborting."
fi

# Display Confirmation
echo "" >&2
echo -e "${RED}!!! WARNING !!!${NC}" >&2
echo -e "Device:    ${YELLOW}$CANDIDATE${NC} ($MODEL, $SIZE)" >&2
echo -e "Action:    Format to FAT32, Label '$TARGET_LABEL'" >&2
echo "" >&2

CONFIRM_FORMAT="n"
if [[ "$FORCED_FORMAT" -eq 1 ]]; then
    log_info "FORCED MODE: Auto-confirming format."
    CONFIRM_FORMAT="y"
else
    read -r -p "Proceed with FORMATTING? [y/N]: " INPUT
    CONFIRM_FORMAT=$(echo "${INPUT:-N}" | tr '[:upper:]' '[:lower:]')
fi

[[ "$CONFIRM_FORMAT" != "y" ]] && log_info "Cancelled." && exit 0

# --- EXECUTION ---

# 1. Unmount all partitions on the candidate device
log_info "Unmounting partitions on $CANDIDATE..."
# Only try to unmount partitions that actually have a mountpoint
for part_name in $(lsblk -n -o NAME,MOUNTPOINT "$CANDIDATE" | grep -v "$(basename "$CANDIDATE")" | awk '$2 != "" {print $1}'); do
    # Try standard unmount, then lazy unmount if standard fails
    if ! umount "/dev/$part_name" 2>/dev/null; then
        umount -l "/dev/$part_name" 2>/dev/null
    fi
done

# 2. Wipe signatures and create partition table
log_info "Wiping existing signatures and creating partition table..."
wipefs --all --force "$CANDIDATE" > /dev/null
parted -s "$CANDIDATE" mklabel msdos || log_crit "Failed to create partition label."
parted -s "$CANDIDATE" mkpart primary fat32 0% 100% || log_crit "Failed to create partition."

# Force kernel reload (robustness)
if command -v partprobe &> /dev/null; then
    partprobe "$CANDIDATE" 2>/dev/null
fi
sleep 2 # Give the kernel time to recognize the new partition

# 3. Define and verify the new partition name
PARTITION="${CANDIDATE}1"
# Handle complex naming like /dev/nvme0n1p1
if [[ ! -e "$PARTITION" ]]; then
    PARTITION="${CANDIDATE}p1"
fi

if [[ ! -b "$PARTITION" ]]; then
    log_crit "Partition $PARTITION not found after creation. Aborting."
fi

# 4. Format the partition
log_info "Formatting $PARTITION to FAT32..."
if ! mkfs.vfat -F 32 -n "$TARGET_LABEL" "$PARTITION" > /dev/null 2>&1; then
    log_crit "FAT32 formatting failed. Check device size or status."
fi

# --- COMPLETION ---
echo "" >&2
log_success "Drive successfully formatted and ready."
echo "" >&2
# Output the final status to STDOUT (standard output) for review/piping
lsblk -o NAME,LABEL,SIZE,FSTYPE,MOUNTPOINT "$CANDIDATE"
