# ==========================================
# 1. ENVIRONMENT & PATH INITIALIZATION
# ==========================================

# --- ZSH Installation Path ---
export ZSH="$HOME/.oh-my-zsh"

# --- PATH Construction ---
# Rationale: User binaries ($HOME/bin) take precedence over system binaries.
# /usr/local/go/bin included for Go development environments.
export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:/usr/local/go/bin:/snap/bin:$PATH"

# --- Editor Selection Strategy ---
# Priority: VS Code (if GUI/Remote) > Neovim (Modern CLI) > Vi (Universal Fallback)
if command -v code-insiders &> /dev/null; then
    export EDITOR='code --wait'
elif command -v nvim &> /dev/null; then
    export EDITOR='nvim'
else
    export EDITOR='vi'
fi

# --- Runtime Version Managers ---
# Node Version Manager (NVM)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# ==========================================
# 2. ZSH CORE & THEME
# ==========================================

ZSH_THEME="agnoster"

# --- Plugins ---
# Performance Note: Keep minimal. 'sudo' allows double-esc to prepend sudo.
plugins=(git nmap sudo tailscale)

source $ZSH/oh-my-zsh.sh

# --- Navigation Enhancements ---
# Zoxide: Smarter 'cd' replacement
if command -v zoxide &> /dev/null; then
    eval "$(zoxide init zsh)"
fi

# ==========================================
# 3. ALIASES: SYSTEM & MAINTENANCE
# ==========================================

# --- Shell Management ---
alias cls='clear'
alias reload-zsh='source ~/.zshrc && echo "ZSH config reloaded."'
alias ep='$EDITOR ~/.zshrc'

# --- Hardware & Utilities ---
# Relies on custom script in /bin
alias format-usb='sudo $HOME/bin/format32.sh'

# --- Process Management ---
alias p='ps aux | grep -v grep'                  # Quick search
alias ps='ps auxf'                               # Tree view
alias top='htop'
alias topcpu='/bin/ps -eo pcpu,pid,user,args | sort -k 1 -r | head -10'

# ==========================================
# 4. ALIASES: NAVIGATION & DIRECTORIES
# ==========================================

# --- Traversal ---
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias bd='cd $OLDPWD'
alias z..='zoxide query ..'

# --- Bookmarks ---
alias config='cd ~/.config'
alias desk='cd ~/Desktop'
alias docs='cd ~/Documents'
alias dl='cd ~/Downloads'
alias apache='cd /etc/apache2'
alias web='cd /var/www/html'

# --- Modern Listing (EZA) ---
# Detects if eza is installed, falls back to ls if not.
if command -v eza &> /dev/null; then
    alias ls='eza --icons'
    alias ll='eza -l --icons'
    alias la='eza -la --icons'
else
    alias ls='ls --color=auto'
    alias ll='ls -l'
    alias la='ls -la'
fi

# ==========================================
# 5. ALIASES: NETWORK & DIAGNOSTICS
# ==========================================

# --- Core Networking ---
alias myip='whatsmyip'
# Ping Google DNS (Internet Connectivity Test)
alias pingg='ping 8.8.8.8'
# Ping Default Gateway (Local Connectivity Test)
alias pinggw='ping $(ip route show | grep default | awk "{print $3}" | head -n 1)'
# Flush DNS Cache (Critical for Printer/SMTP troubleshooting on Debian 13)
alias flushdns='sudo resolvectl flush-caches && echo "DNS Caches Flushed"'

# --- SMTP Connectivity Tools ---
# Base Command
alias cs='checksmtp'
alias testmail='checksmtp'
alias checkmail='checksmtp'

# --- Provider Library (Scan-to-Email Targets) ---
# NOTE: We pass the FQDN directly to bypass the script's internal dictionary.

# 1. Major Providers
alias csgmail='checksmtp smtp.gmail.com'
alias cso365='checksmtp smtp.office365.com'
alias csoutlook='checksmtp smtp-mail.outlook.com'
alias csyahoo='checksmtp smtp.mail.yahoo.com'
alias csaol='checksmtp smtp.aol.com'
alias csicloud='checksmtp smtp.mail.me.com'
alias cszoho='checksmtp smtp.zoho.com'

# 2. Transactional / Dev
alias csgo='checksmtp smtp.smtp2go.com'
alias cssendgrid='checksmtp smtp.sendgrid.net'
alias csmailgun='checksmtp smtp.mailgun.org'
alias cspostmark='checksmtp smtp.postmarkapp.com'
alias csmandrill='checksmtp smtp.mandrillapp.com'
alias csbrevo='checksmtp smtp-relay.sendinblue.com'
alias csmailjet='checksmtp in-v3.mailjet.com'
alias csses='checksmtp email-smtp.us-east-1.amazonaws.com'

# 3. ISP / Telecom (Common Legacy Setups)
alias cscomcast='checksmtp smtp.comcast.net'
alias csatt='checksmtp outbound.att.net'
alias csverizon='checksmtp smtp.verizon.net'
alias csspectrum='checksmtp mail.twc.com'
alias cscox='checksmtp smtp.cox.net'
alias cscentury='checksmtp smtp.centurylink.net'

# 4. Web Hosting
alias csgodaddy='checksmtp smtpout.secureserver.net'
alias csrackspace='checksmtp secure.emailsrvr.com'
alias csionos='checksmtp smtp.ionos.com'
alias csbluehost='checksmtp smtp.bluehost.com'

# ==========================================
# 6. MICRO FUNCTIONS
# ==========================================

cheat() { clear && curl cheat.sh/"$1" ; }
weather() { clear && curl wttr.in/"$1" ; }

# ==========================================
# 7. SESSION MANAGEMENT (ZELLIJ)
# ==========================================

if command -v zellij &> /dev/null; then
    # Prevent nested sessions and do not launch inside VS Code terminal
    if [[ -z "$ZELLIJ" && "$TERM_PROGRAM" != "vscode" ]]; then
        eval "$(zellij setup --generate-auto-start zsh)"
    fi
fi
