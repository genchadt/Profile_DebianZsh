#!/bin/bash

# --- CONFIGURATION ---
TARGET_LABEL="PRINT_TECH"
QUICK_MODE="N"
FORCED_FORMAT="N"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- HELPER FUNCTIONS ---
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_crit() { echo -e "${RED}[CRIT]${NC} $1"; }
log_success() { echo -e "${GREEN}[DONE]${NC} $1"; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script formats a selected USB drive to FAT32 with label '$TARGET_LABEL'."
    echo ""
    echo "Options:"
    echo "  -q, --quick   Run in quick mode (implies -y)."
    echo "  -y, --forced  Automatically confirm the formatting prompt."
    exit 1
}

# --- ARGUMENT PARSING ---
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -q|--quick)
            QUICK_MODE="Y"
            FORCED_FORMAT="Y"
            shift
            ;;
        -y|--forced)
            FORCED_FORMAT="Y"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_crit "Unknown parameter: $1"
            usage
            ;;
    esac
done

# --- PRE-CHECKS ---
if [[ $EUID -ne 0 ]]; then
    log_crit "This script must be run as root (use sudo)."
    exit 1
fi

for cmd in lsblk mkfs.vfat parted wipefs; do
    if ! command -v $cmd &> /dev/null; then
        log_crit "Command '$cmd' not found. Please install it."
        exit 1
    fi
done

# --- DETECTION LOGIC ---
echo -e "----------------------------------------"
echo -e "    USB AUTO-FORMATTER -> ${YELLOW}FAT32${NC}"
[[ "$QUICK_MODE" == "Y" ]] && echo -e "${GREEN}    QUICK MODE ENABLED (-q)${NC}"
echo -e "----------------------------------------"

EXISTING_DEV=$(lsblk -no PKNAME,LABEL | grep "$TARGET_LABEL" | awk '{print $1}' | head -n 1)
CANDIDATE=""

if [[ -n "$EXISTING_DEV" ]]; then
    CANDIDATE="/dev/$EXISTING_DEV"
    log_success "Detected existing '$TARGET_LABEL' drive at: ${CANDIDATE}"
else
    log_info "Label '$TARGET_LABEL' not found. Scanning for USB devices..."
    IFS=$'\n'
    USB_DEVICES=($(lsblk -d -o NAME,SIZE,MODEL,TRAN,TYPE | grep "usb" | grep "disk"))
    unset IFS
    NUM_FOUND=${#USB_DEVICES[@]}

    if [[ $NUM_FOUND -eq 0 ]]; then
        log_crit "No USB storage devices detected."
        exit 0
    elif [[ $NUM_FOUND -eq 1 ]]; then
        RAW_LINE="${USB_DEVICES[0]}"
        DEV_NAME=$(echo "$RAW_LINE" | awk '{print $1}')
        CANDIDATE="/dev/$DEV_NAME"
        log_info "Heuristic match: Found single USB device."
    else
        log_warn "Multiple USB devices found. Please select one:"
        PS3="Select device number: "
        select opt in "${USB_DEVICES[@]}"; do
            [[ -n "$opt" ]] && CANDIDATE="/dev/$(echo "$opt" | awk '{print $1}')" && break
            echo "Invalid selection."
        done
    fi
fi

# --- SAFETY CHECKS ---
[[ -z "$CANDIDATE" ]] && log_crit "No device selected. Exiting." && exit 1

IS_ROOT=$(lsblk "$CANDIDATE" -o MOUNTPOINT | grep -w "/")
if [[ -n "$IS_ROOT" ]]; then
    log_crit "SAFETY TRIGGERED: $CANDIDATE appears to be the system root. Aborting."
    exit 1
fi

MODEL=$(lsblk -dn -o MODEL "$CANDIDATE")
SIZE=$(lsblk -dn -o SIZE "$CANDIDATE")

echo ""
echo -e "${RED}!!! WARNING !!!${NC}"
echo -e "Device:    ${YELLOW}$CANDIDATE${NC} ($MODEL, $SIZE)"
echo -e "Action:    Format to FAT32, Label '$TARGET_LABEL'"
echo ""

CONFIRM_FORMAT="N"
if [[ "$FORCED_FORMAT" == "Y" ]]; then
    log_info "FORCED MODE: Auto-confirming format."
    CONFIRM_FORMAT="y"
else
    read -r -p "Proceed with FORMATTING? [y/N]: " INPUT
    CONFIRM_FORMAT=$(echo "${INPUT:-N}" | tr '[:upper:]' '[:lower:]')
fi

[[ "$CONFIRM_FORMAT" != "y" ]] && log_info "Cancelled." && exit 0

# --- EXECUTION ---
log_info "Unmounting partitions on $CANDIDATE..."
for part in $(lsblk -n -o NAME "$CANDIDATE" | grep -v "$(basename "$CANDIDATE")"); do
    umount "/dev/$part" 2>/dev/null
done

log_info "Wiping signatures and creating partition table..."
wipefs --all --force "$CANDIDATE" > /dev/null
parted -s "$CANDIDATE" mklabel msdos
parted -s "$CANDIDATE" mkpart primary fat32 0% 100%

# Robustness: Force kernel reload
if command -v partprobe &> /dev/null; then
    partprobe "$CANDIDATE" 2>/dev/null
fi
sleep 2

# Robustness: Lazy unmount
for part in $(lsblk -n -o NAME "$CANDIDATE" | grep -v "$(basename "$CANDIDATE")"); do
    umount -l "/dev/$part" 2>/dev/null
done
umount -l "$CANDIDATE" 2>/dev/null

# Define partition
PARTITION="${CANDIDATE}1"
[[ ! -e "$PARTITION" ]] && PARTITION="${CANDIDATE}p1"

[[ ! -b "$PARTITION" ]] && log_crit "Partition $PARTITION not found after creation." && exit 1

log_info "Formatting $PARTITION to FAT32..."
mkfs.vfat -F 32 -n "$TARGET_LABEL" "$PARTITION"

echo ""
log_success "Drive ready: $PARTITION ($TARGET_LABEL)"
lsblk -o NAME,LABEL,SIZE,FSTYPE "$CANDIDATE"
