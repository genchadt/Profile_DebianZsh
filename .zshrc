# ==========================================
# 1. ZSH CORE CONFIGURATION
# ==========================================

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load
ZSH_THEME="agnoster"

# Plugins
# Add wisely, as too many plugins slow down shell startup.
plugins=(git nmap sudo tailscale)

source $ZSH/oh-my-zsh.sh

# ==========================================
# 2. ENVIRONMENT & PATHS
# ==========================================

# Set Language Environment
# export LANG=en_US.UTF-8

# PATH Configuration
# Note: ZSH often loads /usr/local/bin automatically, but explicit ordering helps.
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:/usr/local/go/bin:/snap/bin:$PATH"

# Editor Configuration
# Prioritize VS Code Insiders, then Neovim, then standard Vi
if command -v code-insiders &> /dev/null; then
    export EDITOR='code --wait'
elif command -v nvim &> /dev/null; then
    export EDITOR='nvim'
else
    export EDITOR='vi'
fi

# Load NVM (Node Version Manager)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# Initialize Zoxide (Better cd)
if command -v zoxide &> /dev/null; then
    eval "$(zoxide init zsh)"
fi

# ==========================================
# 3. ALIASES
# ==========================================

# System
alias cls='clear'
alias py='python3'
alias vi='nvim'
alias p='ps aux | grep -v grep' # search processes
alias ps='ps auxf'              # tree view processes
alias top='htop'
alias topcpu='/bin/ps -eo pcpu,pid,user,args | sort -k 1 -r | head -10'

# Function
alias myip='whatsmyip'
alias cs='checksmtp'
alias testmail='checksmtp'
alias checkmail='checksmtp'

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias ~='cd ~'
alias home='cd ~'
alias bd='cd $OLDPWD' # Back directory

# SMTP
alias csgo='checksmtp smtp2go'
alias csgmail='checksmtp gmail'
alias cses='checksmtp ses'
alias cso365='checksmtp office365'
alias csmailgun='checksmtp mailgun'
alias cssendgrid='checksmtp sendgrid'
alias cspostmark='checksmtp postmark'
alias csbrevo='checksmtp brevo'

# Quick Directories
alias config='cd ~/.config'
alias desk='cd ~/Desktop'
alias docs='cd ~/Documents'
alias dl='cd ~/Downloads'
alias apache='cd /etc/apache2'
alias web='cd /var/www/html'

# ZSH Maintenance
alias ep='$EDITOR ~/.zshrc'
alias reload-zsh='source ~/.zshrc'

# LS Replacement (Use eza if available, fallback to ls with color)
if command -v eza &> /dev/null; then
    alias ls='eza --icons'
    alias ll='eza -l --icons'
    alias la='eza -la --icons'
else
    alias ls='ls --color=auto'
    alias ll='ls -l'
    alias la='ls -la'
fi

# Zoxide Aliases (if needed explicitly, though 'z' covers most)
alias z..='zoxide query ..'

# ==========================================
# 4. FUNCTIONS
# ==========================================

# --- Check SMTP Connectivity ---
# --- Check SMTP Connectivity ---
function checksmtp() {
    local HOST_ARG="$1"

    # 1. Input Validation
    if [[ -z "$HOST_ARG" ]]; then
        echo -n "Enter SMTP server hostname (or alias): "
        read HOST_ARG
    fi

    # 2. Configuration & Colors
    local PORTS=(587 465 2525 25)
    local TIMEOUT=1
    local GREEN='\033[0;32m'
    local RED='\033[0;31m'
    local YELLOW='\033[0;33m'
    local BLUE='\033[0;34m'
    local NC='\033[0m'

    # 3. Tailscale Detection
    if ! command -v tailscale &> /dev/null; then
        echo -e "${BLUE}Tailscale not installed: Checking all ports including 25.${NC}"
    elif ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}Warning: 'jq' not installed. Cannot reliably check Exit Node status. Checking all ports including 25.${NC}"
    else
        # Capture status
        local TS_STATUS
        if TS_STATUS=$(tailscale status --json 2>/dev/null); then
            # First, verify Tailscale is actually running
            local STATE
            STATE=$(echo "$TS_STATUS" | jq -r '.BackendState')

            if [[ "$STATE" == "Running" ]]; then
                # Check .ExitNodeStatus.ID (Active Connection) first, fall back to .ExitNodeID (Configured Preference)
                local EXIT_NODE_ID
                EXIT_NODE_ID=$(echo "$TS_STATUS" | jq -r '.ExitNodeStatus.ID // .ExitNodeID')

                if [[ -n "$EXIT_NODE_ID" && "$EXIT_NODE_ID" != "null" ]]; then
                    echo -e "${YELLOW}Tailscale Exit Node Detected (${EXIT_NODE_ID}): Skipping Port 25 (Policy Blocked)${NC}"
                    PORTS=(587 465 2525)
                else
                    echo -e "${BLUE}Tailscale Running (No Exit Node): Checking all ports including 25.${NC}"
                fi
            else
                echo -e "${BLUE}Tailscale installed but stopped ($STATE): Checking all ports including 25.${NC}"
            fi
        else
            echo -e "${YELLOW}Warning: Tailscale status check failed. Checking all ports including 25.${NC}"
        fi
    fi

    # 4. Alias Expansion
    local HOST_LOWER=$(echo "$HOST_ARG" | tr '[:upper:]' '[:lower:]')
    local HOST=""
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

    # 5. DNS Resolution Check
    echo -n "DNS Resolution... "
    local RESOLVED_IP
    if RESOLVED_IP=$(getent hosts "$HOST" | awk '{print $1}' | head -n 1); then
        if [[ -n "$RESOLVED_IP" ]]; then
            echo -e "[${GREEN}OK${NC}] -> $RESOLVED_IP"
        else
            echo -e "[${RED}FAIL${NC}]"
            echo "Error: Hostname exists but returned no IP address."
            return 1
        fi
    else
        echo -e "[${RED}FAIL${NC}]"
        echo "Error: Could not resolve hostname. Check DNS or spelling."
        return 1
    fi

    # 6. Sequential Connectivity Check
    echo "Starting port checks (Timeout: ${TIMEOUT}s)..."

    for PORT in "${PORTS[@]}"; do
        echo -n "Checking port $PORT... "
        nc -z -w $TIMEOUT "$HOST" "$PORT" &> /dev/null
        local RESULT=$?

        if [ $RESULT -eq 0 ]; then
            echo -e "[${GREEN}OPEN${NC}]"
        elif [ $RESULT -eq 1 ]; then
            echo -e "[${RED}CLOSED${NC}]"
        else
            echo -e "[${YELLOW}TIMEOUT${NC}]"
        fi
    done
}

# --- What is my IP? ---
function whatsmyip() {
    echo "--- Local (Internal) IPs ---"
    if command -v ip > /dev/null; then
        ip -4 addr show scope global | grep -oP 'inet \K[\d.]+'
    else
        ifconfig | grep -Eo 'inet (addr:)?([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}' | grep -v '127.0.0.1'
    fi

    echo ""
    echo "--- External (Public) IPs ---"
    if command -v curl > /dev/null; then
        echo -n "IPv4: "
        curl -4 -s ifconfig.me || echo "Unavailable"
        echo ""
        echo -n "IPv6: "
        curl -6 -s checkip.amazonaws.com || echo "Unavailable"
        echo ""
    else
        echo "curl required for public IP check."
    fi
}
alias myip='whatsmyip'

# --- Archive Extractor ---
function extract() {
    if [ -f "$1" ]; then
        case "$1" in
            *.tar.bz2)  tar xvjf "$1" ;;
            *.tar.gz)   tar xvzf "$1" ;;
            *.tar.xz)   tar xvJf "$1" ;;
            *.tar)      tar xvf "$1" ;;
            *.zip)      unzip "$1" ;;
            *.rar)      unrar x "$1" ;;
            *.7z)       7z x "$1" ;;
            *)          echo "Unsupported format." ;;
        esac
    else
        echo "'$1' is not a valid file."
    fi
}

# --- Utilities ---
cheat() { clear && curl cheat.sh/"$1" ; }
weather() { clear && curl wttr.in/"$1" ; }


# ==========================================
# 5. AUTOSTART ZELLIJ
# ==========================================
# Only launch if not inside a zellij session and not inside a VS Code terminal
if command -v zellij &> /dev/null; then
    if [[ -z "$ZELLIJ" ]]; then
        if [[ "$TERM_PROGRAM" != "vscode" ]]; then
            eval "$(zellij setup --generate-auto-start zsh)"
        fi
    fi
fi

# ==========================================
# 6. PERSONAL SCRIPTS
# ==========================================
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi
alias format-usb='sudo /home/user/bin/format32.sh'
