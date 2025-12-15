#!/usr/bin/env bash

# --- Configuration & Colors ---
HOST_ARG="$1"
PORTS=(587 465 2525 25)
TIMEOUT=2
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Input Validation ---
if [[ -z "$HOST_ARG" ]]; then
    echo -n "Enter SMTP server hostname (or alias): "
    read -r HOST_ARG
fi

# --- Tailscale Detection logic ---
if ! command -v tailscale &> /dev/null; then
    echo -e "${BLUE}Tailscale not installed: Checking all ports including 25.${NC}"
elif ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Warning: 'jq' missing. Cannot verify Exit Node. Checking all ports including 25.${NC}"
else
    # Capture status
    if TS_STATUS=$(tailscale status --json 2>/dev/null); then
        STATE=$(echo "$TS_STATUS" | jq -r '.BackendState')

        if [[ "$STATE" == "Running" ]]; then
            # Check Active Connection first, fall back to Configured Preference
            EXIT_NODE_ID=$(echo "$TS_STATUS" | jq -r '.ExitNodeStatus.ID // .ExitNodeID')

            if [[ -n "$EXIT_NODE_ID" && "$EXIT_NODE_ID" != "null" ]]; then
                echo -e "${YELLOW}Tailscale Exit Node Detected (${EXIT_NODE_ID}): Skipping Port 25 (Policy Blocked)${NC}"
                PORTS=(587 465 2525)
            else
                echo -e "${BLUE}Tailscale Running (No Exit Node): Checking all ports including 25.${NC}"
            fi
        else
            echo -e "${BLUE}Tailscale stopped ($STATE): Checking all ports including 25.${NC}"
        fi
    else
        echo -e "${YELLOW}Warning: Tailscale status check failed. Checking all ports including 25.${NC}"
    fi
fi

# --- Alias Expansion ---
HOST_LOWER=$(echo "$HOST_ARG" | tr '[:upper:]' '[:lower:]')
case "$HOST_LOWER" in
    "smtp2go") HOST="smtp.smtp2go.com" ;;
    "sendgrid") HOST="smtp.sendgrid.net" ;;
    "mailgun") HOST="smtp.mailgun.org" ;;
    "postmark") HOST="smtp.postmarkapp.com" ;;
    "amazon" | "ses") HOST="email-smtp.us-east-1.amazonaws.com" ;;
    "brevo" | "sendinblue") HOST="smtp-relay.sendinblue.com" ;;
    "gmail") HOST="smtp.gmail.com" ;;
    "office365" | "o365" | "outlook" | "microsoft") HOST="smtp.office365.com" ;;
    *) HOST="$HOST_ARG" ;;
esac

echo -e "--- Testing Target: ${BLUE}$HOST${NC} ---"

# --- DNS Resolution Check ---
echo -n "DNS Resolution... "
if RESOLVED_IP=$(getent hosts "$HOST" | awk '{print $1}' | head -n 1); then
    if [[ -n "$RESOLVED_IP" ]]; then
        echo -e "[${GREEN}OK${NC}] -> $RESOLVED_IP"
    else
        echo -e "[${RED}FAIL${NC}]"
        echo "Error: Hostname exists but returned no IP address."
        exit 1
    fi
else
    echo -e "[${RED}FAIL${NC}]"
    echo "Error: Could not resolve hostname. Check DNS or spelling."
    exit 1
fi

# --- Connectivity Check ---
echo "Starting port checks (Timeout: ${TIMEOUT}s)..."

for PORT in "${PORTS[@]}"; do
    echo -n "Checking port $PORT... "
    nc -z -w $TIMEOUT "$HOST" "$PORT" &> /dev/null
    RESULT=$?

    if [ $RESULT -eq 0 ]; then
        echo -e "[${GREEN}OPEN${NC}]"
    elif [ $RESULT -eq 1 ]; then
        echo -e "[${RED}CLOSED${NC}]"
    else
        echo -e "[${YELLOW}TIMEOUT${NC}]"
    fi
done
