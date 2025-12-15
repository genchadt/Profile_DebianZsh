#!/usr/bin/env bash

# File: smtp_port_checker.sh
# Description: This script checks common SMTP ports (587, 465, 2525, 25) for a given
#              hostname or a predefined service alias. It performs DNS resolution,
#              port connection tests, banner grabbing, and includes logic for
#              Tailscale Exit Node policy enforcement on port 25.
# Usage: ./smtp_port_checker.sh [hostname | alias]
# Dependencies: nc, openssl, jq, timeout

# Exit immediately if a command exits with a non-zero status.
set -e
# Use set -o pipefail for robust error checking within pipelines.
set -o pipefail

# --- Configuration & Constants ------------------------------------------------

# Default timeout for network operations (in seconds).
DEFAULT_TIMEOUT=3
# Standard SMTP ports to check:
# 587 (Submission/STARTTLS), 465 (Implicit SSL/SMTPS), 2525 (Alternative), 25 (Relay/Legacy).
PORTS=(587 465 2525 25)

# --- Formatting Variables -----------------------------------------------------

# Base Color Definitions
readonly BOLD='\033[1m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[1;35m'
readonly NC='\033[0m' # No Color

# Semantic Color Assignments
readonly COLOR_HIGHLIGHT=$CYAN
readonly COLOR_INFO=$BLUE
readonly COLOR_DETAIL=$MAGENTA
readonly COLOR_SUCCESS=$GREEN
readonly COLOR_WARNING=$YELLOW
readonly COLOR_ERROR=$RED
readonly COLOR_HEADING=$BOLD

# Global associative array to store check results for the final summary.
declare -A RESULTS

# --- Utility Functions --------------------------------------------------------

##
# @brief Lists all built-in provider aliases supported by the script.
#
list_providers() {
    local aliases=(
        "gmail, google, gsuite, workspace"
        "outlook, office365, o365, microsoft"
        "yahoo, aol, verizon"
        "icloud, apple"
        "proton (Note: resolves to 127.0.0.1 for local testing)"
        "zoho"
        "fastmail"
        "aws, ses"
        "sendgrid"
        "mailgun"
        "postmark"
        "brevo"
        "smtp2go"
        "comcast, xfinity"
    )
    echo -e "${COLOR_HEADING}Built-in Provider Aliases:${NC}"
    for item in "${aliases[@]}"; do
        echo -e "  * ${item}"
    done
}

##
# @brief Displays the script's usage information and examples.
#
usage() {
    echo -e "${COLOR_HEADING}SMTP Port Checker Utility${NC}"
    echo -e "This utility checks common SMTP ports (587, 465, 2525, 25) for a given hostname or service alias."
    echo ""
    echo -e "Usage: $0 [hostname | alias | -h | --help]"
    echo -e "Examples:"
    echo -e "  $0 ${COLOR_HIGHLIGHT}smtp.example.com${NC}"
    echo -e "  $0 ${COLOR_HIGHLIGHT}gmail${NC}"
    echo -e "  $0 ${COLOR_HIGHLIGHT}outlook${NC}"
    echo ""
    echo -e "Interactive Mode: Run without arguments. Type 'exit' or 'quit' to end."
    echo ""
    list_providers
    echo ""
    echo -e "Dependencies: nc, openssl, jq, timeout"
}

##
# @brief Checks for the presence of all required external commands (dependencies).
# @exit 1 if a critical dependency is missing.
#
check_deps() {
    local deps=("nc" "openssl" "jq" "timeout")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${COLOR_ERROR}Error: Critical dependency '$cmd' is missing.${NC}"
            exit 1
        fi
    done
}

# --- Provider Alias Database --------------------------------------------------

##
# @brief Translates a provider alias (like 'gmail') into its corresponding SMTP hostname.
# @param $1 The input string (hostname or alias).
# @return The resolved hostname to stdout.
#
resolve_provider() {
    local input_host
    input_host=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    case "$input_host" in
        "gmail"|"google"|"gsuite"|"workspace") echo "smtp.gmail.com" ;;
        "outlook"|"office365"|"o365"|"microsoft") echo "smtp.office365.com" ;;
        "yahoo"|"aol"|"verizon") echo "smtp.mail.yahoo.com" ;;
        "icloud"|"apple") echo "smtp.mail.me.com" ;;
        "proton") echo "127.0.0.1" ;;
        "zoho") echo "smtp.zoho.com" ;;
        "fastmail") echo "smtp.fastmail.com" ;;
        "aws"|"ses") echo "email-smtp.us-east-1.amazonaws.com" ;;
        "sendgrid") echo "smtp.sendgrid.net" ;;
        "mailgun") echo "smtp.mailgun.org" ;;
        "postmark") echo "smtp.postmarkapp.com" ;;
        "brevo") echo "smtp-relay.brevo.com" ;;
        "smtp2go") echo "mail.smtp2go.com" ;;
        "comcast"|"xfinity") echo "smtp.comcast.net" ;;
        *) echo "$1" ;;
    esac
}

# --- Tailscale Policy Check ---------------------------------------------------

##
# @brief Checks Tailscale status to determine if port 25 should be skipped.
# Tailscale clients often block port 25 traffic when an Exit Node is active.
# @retval 0 if check should proceed (Tailscale not installed or no Exit Node).
# @retval 1 if check should be skipped (Tailscale Exit Node is active).
#
check_tailscale_policy() {
    if ! command -v tailscale &> /dev/null; then
        echo -e "${COLOR_DETAIL}Info: Tailscale not detected. Port 25 check allowed.${NC}"
        return 0
    fi

    if ! TS_JSON=$(tailscale status --json 2>/dev/null); then
        echo -e "${COLOR_WARNING}Warning: Tailscale installed but daemon unreachable.${NC}"
        return 0
    fi

    local backend_state
    backend_state=$(echo "$TS_JSON" | jq -r '.BackendState')

    if [[ "$backend_state" != "Running" ]]; then
          echo -e "${COLOR_INFO}Tailscale State: ${backend_state}. Port 25 check allowed.${NC}"
          return 0
    fi

    # Check for active Exit Node
    local exit_node
    # Use // empty for robust null/missing key handling
    exit_node=$(echo "$TS_JSON" | jq -r '.ExitNodeStatus.ID // .ExitNodeID // empty')

    if [[ -n "$exit_node" && "$exit_node" != "null" ]]; then
        echo -e "${COLOR_WARNING}Security: Tailscale Exit Node Active ($exit_node).${NC}"
        echo -e "${COLOR_ERROR}Policy Enforcement: Port 25 check suppressed.${NC}"
        return 1
    else
        echo -e "${COLOR_INFO}Tailscale Active (No Exit Node). Port 25 check allowed.${NC}"
        return 0
    fi
}

# --- Banner Grabbing Logic ----------------------------------------------------

##
# @brief Attempts to connect to the host:port and grab the initial banner.
# Uses openssl for implicit SSL (port 465) and netcat (nc) for others.
# @param $1 The target hostname.
# @param $2 The target port.
# @return The banner text on success (stdout).
# @retval 1 on failure (timeout or connection error).
#
get_banner() {
    local host=$1
    local port=$2
    local banner=""

    if [[ "$port" == "465" ]]; then
        # FIX APPLIED:
        # 1. Added '-crlf' : Sends proper line endings for SMTP.
        # 2. Replaced '<<< "QUIT"' with a piped sleep :
        #    This keeps the connection open for 2 seconds, allowing the SSL
        #    handshake to finish and the '220' banner to arrive before we hang up.
        # 3. filtered with 'grep 220' : Ensures we capture the actual SMTP banner
        #    and not OpenSSL session info (which sometimes leaks even with -quiet).

        banner=$( (sleep 2; echo "QUIT") | \
            timeout "$DEFAULT_TIMEOUT" openssl s_client -quiet -crlf -connect "${host}:${port}" 2>/dev/null | \
            grep "220" | head -n 1 )
    else
        # Use netcat (nc) for standard/STARTTLS ports
        # Note: Added -w (wait) to ensure nc doesn't hang indefinitely if timeout fails
        banner=$(echo "QUIT" | timeout "$DEFAULT_TIMEOUT" nc -w "$DEFAULT_TIMEOUT" "$host" "$port" 2>/dev/null | head -n 1)
    fi

    if [[ -n "$banner" ]]; then
        # Remove carriage return character for clean output
        echo "${banner//$'\r'/}"
    else
        return 1
    fi
}

# --- Core Logic ---------------------------------------------------------------

##
# @brief Executes the full port check analysis for a given target.
# @param $1 The hostname or alias to check.
#
run_check() {
    local target_arg="$1"
    # Reset results for a new check
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
        # Check if getent returned an IP (could fail for a known host with no IP)
        [[ -z "$target_ip" ]] && { echo -e "[${COLOR_ERROR}FAIL${NC}] - No IP Address found"; return; }
        echo -e "[${COLOR_SUCCESS}OK${NC}] -> $target_ip"
    else
        echo -e "[${COLOR_ERROR}FAIL${NC}] - NXDOMAIN (Name resolution failure)"
        return
    fi

    # Tailscale Logic
    local skip_25=false
    if ! check_tailscale_policy; then
        skip_25=true
    fi

    echo -e "\n${COLOR_HEADING}Starting Port Analysis (Timeout: ${DEFAULT_TIMEOUT}s)...${NC}"

    for port in "${PORTS[@]}"; do
        # 1. Prepare the Protocol Label
        local protocol_type="SMTP"
        if [[ "$port" == "465" ]]; then
            protocol_type="SMTPS (Implicit SSL)"
        elif [[ "$port" == "587" ]]; then
            protocol_type="Submission (STARTTLS)"
        fi

        local label="  Port $port ($protocol_type)"

        # 2. Check for Skipped Ports (Tailscale Policy)
        if [[ "$port" == "25" && "$skip_25" == "true" ]]; then
            # Use printf for precise column alignment
            printf "%-35s : [${COLOR_WARNING}SKIPPED${NC}] (Exit Node Policy)\n" "$label"
            RESULTS["$port"]="SKIPPED"
            continue
        fi

        # 3. Print the Label (Aligned)
        printf "%-35s : " "$label"

        # 4. Perform Connection and Banner Grab
        local banner_text
        if banner_text=$(get_banner "$target_host" "$port"); then
            echo -e "[${COLOR_SUCCESS}OPEN${NC}]"
            echo -e "      └─ Banner: ${COLOR_DETAIL}${banner_text}${NC}"
            RESULTS["$port"]="${COLOR_SUCCESS}OPEN${NC}"
        else
            # If banner grab fails, check if the port is open at all (using short timeout nc -z)
            if nc -z -w 1 "$target_host" "$port" 2>/dev/null; then
                echo -e "[${COLOR_SUCCESS}OPEN${NC}] ${COLOR_WARNING}(No Banner: Port open, but communication failed/timed out)${NC}"
                RESULTS["$port"]="${COLOR_SUCCESS}OPEN*${NC}" # Asterisk denotes open but no banner
            else
                echo -e "[${COLOR_ERROR}CLOSED${NC}]"
                RESULTS["$port"]="${COLOR_ERROR}CLOSED${NC}"
            fi
        fi
    done

    # Final Summary
    echo -e "\n${COLOR_HEADING}Summary for ${target_host}:${NC}"
    echo -e "---"
    for port in "${PORTS[@]}"; do
        if [[ -n "${RESULTS[$port]}" ]]; then
            printf "  ${BOLD}%-6s${NC} | " "$port"
            echo -e "${RESULTS[$port]}"
        fi
    done
    echo -e "---"
}

# --- Interactive Loop ---------------------------------------------------------

##
# @brief Runs the check utility in a continuous interactive loop.
#
interactive_loop() {
    while true; do
        echo -ne "${COLOR_HEADING}Enter hostname or alias (or 'exit'):${NC} > "
        read -r input_host
        # Remove leading/trailing whitespace
        input_host=$(echo "$input_host" | xargs)
        [[ -z "$input_host" ]] && continue
        if [[ "$input_host" == "exit" || "$input_host" == "quit" ]]; then
            echo -e "${COLOR_INFO}Exiting interactive mode.${NC}"
            break
        fi
        run_check "$input_host"
    done
}

# --- Main Execution -----------------------------------------------------------

##
# @brief Main function to handle command-line arguments and script execution flow.
#
main() {
    local target_arg="${1:-}"

    if [[ "$target_arg" == "-h" || "$target_arg" == "--help" ]]; then
        usage
        return 0
    fi

    # Ensure all required tools are present before starting
    check_deps

    if [[ -z "$target_arg" ]]; then
        echo -e "${COLOR_INFO}No argument provided. Entering interactive mode.${NC}"
        interactive_loop
    else
        run_check "$target_arg"
    fi
}

# Execute the main function with all script arguments
main "$@"
