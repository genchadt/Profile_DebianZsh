#!/usr/bin/env bash

# set -o pipefail # Commented out for easier copy/paste behavior

# --- Configuration & Constants ---
DEFAULT_TIMEOUT=3
# Standard Ports: 25 (Relay), 465 (Implicit SSL), 587 (Submission), 2525 (Alternative)
PORTS=(587 465 2525 25)

# --- Formatting ---
# Base Color Definitions
BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[1;35m'
NC='\033[0m' # No Color

# Semantic Color Assignments
COLOR_HIGHLIGHT=$CYAN       # For the target host
COLOR_INFO=$BLUE            # For informational messages (e.g., Tailscale state)
COLOR_DETAIL=$MAGENTA       # For displaying verbose/banner text
COLOR_SUCCESS=$GREEN        # For successful operations (e.g., OK, OPEN)
COLOR_WARNING=$YELLOW       # For warnings and skips (e.g., SKIPPED, No Banner)
COLOR_ERROR=$RED            # For fatal errors and failures (e.g., FAIL, CLOSED)
COLOR_HEADING=$BOLD         # For main headers/titles

# Store results for the final summary
declare -A RESULTS
RESULTS=()

# --- Utility Functions ---

function usage() {
    echo -e "${COLOR_HEADING}SMTP Port Checker Utility${NC}"
    echo -e "Usage: $0 [hostname | alias]"
    echo -e "Interactive: Run without arguments."
}

function check_deps() {
    local deps=("nc" "openssl" "jq" "timeout")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${COLOR_ERROR}Error: Critical dependency '$cmd' is missing.${NC}"
            exit 1
        fi
    done
}

# --- Provider Alias Database ---
function resolve_provider() {
    local input_host
    input_host=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    case "$input_host" in
        # --- Major Tech / Productivity ---
        "gmail"|"google"|"gsuite"|"workspace") echo "smtp.gmail.com" ;;
        "outlook"|"office365"|"o365"|"microsoft"|"live"|"hotmail") echo "smtp.office365.com" ;;
        "yahoo"|"aol"|"verizon") echo "smtp.mail.yahoo.com" ;;
        "icloud"|"apple"|"me"|"mac") echo "smtp.mail.me.com" ;;
        "proton"|"protonmail") echo "127.0.0.1" ;;
        "zoho") echo "smtp.zoho.com" ;;
        "fastmail") echo "smtp.fastmail.com" ;;
        "rackspace") echo "secure.emailsrvr.com" ;;
        "godaddy") echo "smtpout.secureserver.net" ;;
        "gmx") echo "mail.gmx.com" ;;

        # --- Transactional Email APIs ---
        "aws"|"ses"|"amazon") echo "email-smtp.us-east-1.amazonaws.com" ;;
        "sendgrid") echo "smtp.sendgrid.net" ;;
        "mailgun") echo "smtp.mailgun.org" ;;
        "postmark") echo "smtp.postmarkapp.com" ;;
        "brevo"|"sendinblue") echo "smtp-relay.brevo.com" ;;
        "mailchimp"|"mandrill") echo "smtp.mandrillapp.com" ;;
        "smtp2go") echo "mail.smtp2go.com" ;;
        "sparkpost") echo "smtp.sparkpostmail.com" ;;
        "mailjet") echo "in-v3.mailjet.com" ;;
        "elastic"|"elasticemail") echo "smtp.elasticemail.com" ;;
        "socketlabs") echo "smtp.socketlabs.com" ;;
        "pepipost"|"netcore") echo "smtp.pepipost.com" ;;
        "amazon-eu") echo "email-smtp.eu-west-1.amazonaws.com" ;;

        # --- ISPs / Legacy ---
        "comcast"|"xfinity") echo "smtp.comcast.net" ;;
        "att") echo "outbound.att.net" ;;
        "spectrum"|"charter") echo "mobile.charter.net" ;;
        "cox") echo "smtp.cox.net" ;;
        "centurylink") echo "smtp.centurylink.net" ;;

        # --- Default ---
        *) echo "$1" ;;
    esac
}

# --- Tailscale Policy Check ---
function check_tailscale_policy() {
    if ! command -v tailscale &> /dev/null; then
        echo -e "${COLOR_DETAIL}Info: Tailscale not detected. Port 25 allowed.${NC}"
        return 0
    fi

    if ! TS_JSON=$(tailscale status --json 2>/dev/null); then
        echo -e "${COLOR_WARNING}Warning: Tailscale installed but daemon unreachable.${NC}"
        return 0
    fi

    local backend_state
    backend_state=$(echo "$TS_JSON" | jq -r '.BackendState')

    if [[ "$backend_state" != "Running" ]]; then
          echo -e "${COLOR_INFO}Tailscale State: ${backend_state}. Port 25 allowed.${NC}"
          return 0
    fi

    local exit_node
    exit_node=$(echo "$TS_JSON" | jq -r '.ExitNodeStatus.ID // .ExitNodeID // empty')

    if [[ -n "$exit_node" && "$exit_node" != "null" ]]; then
        echo -e "${COLOR_WARNING}Security: Tailscale Exit Node Active ($exit_node).${NC}"
        echo -e "${COLOR_ERROR}Policy Enforcement: Port 25 check suppressed.${NC}"
        return 1
    else
        echo -e "${COLOR_INFO}Tailscale Active (No Exit Node). Port 25 allowed.${NC}"
        return 0
    fi
}

# --- Banner Grabbing Logic ---
function get_banner() {
    local host=$1
    local port=$2
    local banner=""

    if [[ "$port" == "465" ]]; then
        banner=$(timeout "$DEFAULT_TIMEOUT" openssl s_client -quiet -connect "${host}:${port}" -no_ign_eof <<< "QUIT" 2>/dev/null | head -n 1)
    else
        banner=$(echo "QUIT" | timeout "$DEFAULT_TIMEOUT" nc -w "$DEFAULT_TIMEOUT" "$host" "$port" 2>/dev/null | head -n 1)
    fi

    if [[ -n "$banner" ]]; then
        echo "${banner//$'\r'/}"
    else
        return 1
    fi
}

# --- Core Logic ---
function run_check() {
    local target_arg="$1"
    RESULTS=()

    local target_host
    target_host=$(resolve_provider "$target_arg")

    echo -e "\n${COLOR_HEADING}------------------------------------------------------------${NC}"
    echo -e " Target Host: ${COLOR_HIGHLIGHT}${target_host}${NC}"
    echo -e "${COLOR_HEADING}------------------------------------------------------------${NC}"

    # DNS Check
    local target_ip
    echo -ne "Resolving DNS... "
    if target_ip=$(getent hosts "$target_host" | awk '{print $1}' | head -n 1); then
        [[ -z "$target_ip" ]] && { echo -e "[${COLOR_ERROR}FAIL${NC}] - No IP"; return; }
        echo -e "[${COLOR_SUCCESS}OK${NC}] -> $target_ip"
    else
        echo -e "[${COLOR_ERROR}FAIL${NC}] - NXDOMAIN"
        return
    fi

    # Tailscale Logic
    local skip_25=false
    if ! check_tailscale_policy; then
        skip_25=true
    fi

    echo -e "\n${COLOR_HEADING}Starting Analysis...${NC}"

    for port in "${PORTS[@]}"; do
        if [[ "$port" == "25" && "$skip_25" == "true" ]]; then
            echo -e "  Port ${port}\t: [${COLOR_WARNING}SKIPPED${NC}] (Exit Node Policy)"
            RESULTS["$port"]="SKIPPED"
            continue
        fi

        echo -ne "  Port ${port}\t: "
        local banner_text
        if banner_text=$(get_banner "$target_host" "$port"); then
            echo -e "[${COLOR_SUCCESS}OPEN${NC}]"
            echo -e "     └─ Banner: ${COLOR_DETAIL}${banner_text}${NC}"
            RESULTS["$port"]="${COLOR_SUCCESS}OPEN${NC}"
        else
            if nc -z -w 1 "$target_host" "$port" 2>/dev/null; then
                 echo -e "[${COLOR_SUCCESS}OPEN${NC}] ${COLOR_WARNING}(No Banner)${NC}"
                 RESULTS["$port"]="${COLOR_SUCCESS}OPEN*${NC}"
            else
                 echo -e "[${COLOR_ERROR}CLOSED${NC}]"
                 RESULTS["$port"]="${COLOR_ERROR}CLOSED${NC}"
            fi
        fi
    done

    # Final Summary Table (Fixed output format)
    echo -e "\n${COLOR_HEADING}Summary for ${target_host}:${NC}"
    for port in "${PORTS[@]}"; do
        if [[ -n "${RESULTS[$port]}" ]]; then
            # Use echo -e instead of printf to ensure colors in variables are interpreted
            echo -e "  ${BOLD}${port}${NC}\t| ${RESULTS[$port]}"
        fi
    done
}

# --- Interactive Loop ---
function interactive_loop() {
    while true; do
        echo -ne "> "
        read -r input_host

        # Trim spaces
        input_host=$(echo "$input_host" | xargs)

        # Handle empty enter (re-prompt)
        if [[ -z "$input_host" ]]; then
            continue
        fi

        # Exit condition
        if [[ "$input_host" == "exit" || "$input_host" == "quit" ]]; then
            break
        fi

        run_check "$input_host"
    done
}

# --- Main ---
function main() {
    check_deps

    local target_arg="${1:-}"

    if [[ -z "$target_arg" ]]; then
        interactive_loop
    elif [[ "$target_arg" == "-h" || "$target_arg" == "--help" ]]; then
        usage
    else
        run_check "$target_arg"
    fi
}

main "$@"
