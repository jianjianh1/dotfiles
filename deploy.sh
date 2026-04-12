#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Prerequisite checks ---
missing=()
for cmd in ssh scp ssh-copy-id git; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: missing required commands: ${missing[*]}"
    exit 1
fi

# --- Flags ---
AUTO_YES=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=true ;;
        -h|--help)
            echo "Usage: deploy.sh [-y|--yes] [-h|--help]"
            echo "  -y, --yes   Skip all interactive confirmations"
            echo "  -h, --help  Show this help"
            exit 0 ;;
    esac
done

# --- Colors (respect NO_COLOR and non-tty) ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'
    BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BOLD=''; DIM=''; RESET=''
fi

# --- Output helpers ---
info()    { printf "${BOLD}%s${RESET}\n" "$*"; }
success() { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()    { printf "  ${YELLOW}⚠${RESET} %s\n" "$*"; }
error()   { printf "  ${RED}✗${RESET} %s\n" "$*"; }
section() { printf "\n${BOLD}--- %s ---${RESET}\n" "$*"; }

confirm() {
    if [ "$AUTO_YES" = true ]; then return 0; fi
    local prompt="$1" default="${2:-n}"
    local hint
    if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -rp "  $prompt $hint: " answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

# --- Error tracking ---
FAILURES=()

run_step() {
    local name="$1"; shift
    if ! "$@"; then
        FAILURES+=("$name")
        if [ "$AUTO_YES" = false ]; then
            confirm "Step '$name' failed. Continue?" "y" || exit 1
        fi
    fi
}

# --- Retry wrapper for network operations ---
retry() {
    local attempts=3 delay=2 n=0
    while ! "$@"; do
        n=$((n + 1))
        if [ "$n" -ge "$attempts" ]; then return 1; fi
        warn "Retrying ($n/$attempts)..."
        sleep "$delay"
    done
}

# --- SSH helpers ---
SSH_OPTS=()
SSH_SOCKET=""
REMOTE_HOST=""

remote_exec() {
    if [ -n "$SSH_SOCKET" ] && ! ssh -O check -o "ControlPath=$SSH_SOCKET" "$REMOTE_HOST" &>/dev/null; then
        error "SSH connection dropped. Try re-running the script."
        return 1
    fi
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "$@"
}

remote_copy() {
    retry scp -r "${SSH_OPTS[@]}" "$@"
}

cleanup() {
    if [ -n "$SSH_SOCKET" ]; then
        ssh -O exit -o "ControlPath=$SSH_SOCKET" "$REMOTE_HOST" &>/dev/null || true
        rm -f "$SSH_SOCKET"
    fi
}
trap cleanup EXIT

# ============================================================
# Connection Setup
# ============================================================

printf "\n${BOLD}=== Remote Server Deploy ===${RESET}\n\n"

# --- Host ---
read -rp "Remote host (user@hostname or SSH config alias): " REMOTE_HOST
if [ -z "$REMOTE_HOST" ]; then
    echo "Error: host is required"; exit 1
fi
if [[ "$REMOTE_HOST" =~ [[:space:]] ]]; then
    echo "Error: invalid host (contains spaces)"; exit 1
fi

# --- Auth method ---
echo ""
info "How do you connect to this server?"
echo "  1) Password (fresh server, no key yet)"
echo "  2) SSH key (already authorized)"
echo "  3) SSH key at custom path"
echo "  4) Password + 2FA/DUO (university/HPC systems)"
echo "  5) SSH config alias (Host entry in ~/.ssh/config)"
echo ""
read -rp "Auth method [1-5, default=2]: " AUTH_METHOD
AUTH_METHOD="${AUTH_METHOD:-2}"
# Normalize text input to number (case-insensitive)
case "${AUTH_METHOD,,}" in
    password)       AUTH_METHOD=1 ;;
    key|ssh)        AUTH_METHOD=2 ;;
    custom)         AUTH_METHOD=3 ;;
    2fa|duo|mfa)    AUTH_METHOD=4 ;;
    alias|config)   AUTH_METHOD=5 ;;
esac

SSH_PORT="22"
IDENTITY_FILE=""
CONNECT_TIMEOUT=15

case "$AUTH_METHOD" in
    1)
        # Password auth
        read -rp "SSH port [22]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-22}"
        SSH_OPTS=(-o ConnectTimeout="$CONNECT_TIMEOUT" -o Port="$SSH_PORT")
        ;;
    2)
        # Default key auth
        read -rp "SSH port [22]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-22}"
        SSH_OPTS=(-o ConnectTimeout="$CONNECT_TIMEOUT" -o Port="$SSH_PORT")
        ;;
    3)
        # Custom key path
        read -rp "Path to SSH key: " IDENTITY_FILE
        if [ ! -f "$IDENTITY_FILE" ]; then
            echo "Error: key file not found: $IDENTITY_FILE"; exit 1
        fi
        read -rp "SSH port [22]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-22}"
        SSH_OPTS=(-o ConnectTimeout="$CONNECT_TIMEOUT" -o Port="$SSH_PORT" -i "$IDENTITY_FILE")
        ;;
    4)
        # Password + 2FA/DUO — keyboard-interactive, longer timeout
        read -rp "SSH port [22]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-22}"
        CONNECT_TIMEOUT=90
        SSH_OPTS=(-o ConnectTimeout="$CONNECT_TIMEOUT" -o PreferredAuthentications=keyboard-interactive,password -o NumberOfPasswordPrompts=3 -o Port="$SSH_PORT")
        echo ""
        warn "2FA/DUO mode: you will be prompted for password + 2FA approval."
        echo "    Approve the push when prompted. Timeout: ${CONNECT_TIMEOUT}s."
        ;;
    5)
        # SSH config alias — let SSH config handle everything
        SSH_OPTS=(-o ConnectTimeout=30)
        ;;
    *)
        echo "Error: invalid choice"; exit 1
        ;;
esac

# --- Jump host ---
echo ""
read -rp "Connect through a jump/bastion host? [N/user@host]: " JUMP_HOST
if [ -n "$JUMP_HOST" ]; then
    SSH_OPTS+=(-J "$JUMP_HOST")
fi

# --- Establish ControlMaster (authenticates once, reuses for all commands) ---
SSH_SOCKET="/tmp/deploy-$$-socket"

echo ""
info "Connecting to $REMOTE_HOST..."
echo "  (Authenticate now — this is the only time you'll be prompted)"
echo ""

# ControlMaster runs in background after auth. User interacts with password/DUO here.
if ssh -fNM -o "ControlPath=$SSH_SOCKET" \
    -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
    "${SSH_OPTS[@]}" "$REMOTE_HOST"; then

    # Switch to multiplexed mode — no more interactive auth needed
    SSH_OPTS+=(-o "ControlPath=$SSH_SOCKET" -o BatchMode=yes)

    # Verify we can actually run commands
    if ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "echo ok" &>/dev/null; then
        success "Connected (session multiplexed — no more auth prompts)"
    else
        error "Connection established but cannot run commands on remote"
        echo "    The server may restrict non-interactive command execution."
        echo "    Try: ssh $REMOTE_HOST 'echo test' — manually to diagnose."
        cleanup
        exit 1
    fi
else
    SSH_SOCKET=""
    error "Cannot connect to $REMOTE_HOST"
    echo ""
    echo "  Troubleshooting:"
    if [ "$AUTH_METHOD" = "5" ]; then
        echo "    • Can you SSH manually?  ssh $REMOTE_HOST"
    else
        echo "    • Can you SSH manually?  ssh -p $SSH_PORT $REMOTE_HOST"
    fi
    echo "    • Is the hostname/port correct?"
    case "$AUTH_METHOD" in
        4) echo "    • Did you approve the DUO/2FA push in time? (timeout: ${CONNECT_TIMEOUT}s)" ;;
        1) echo "    • Is the password correct?" ;;
        2|3) echo "    • Is your SSH key authorized on the server?" ;;
        5) echo "    • Is your SSH config (~/.ssh/config) correct for this host?" ;;
    esac
    echo "    • Are you on the right network/VPN?"
    [ -n "$JUMP_HOST" ] && echo "    • Is the jump host ($JUMP_HOST) reachable?"
    echo ""
    if [ "$AUTH_METHOD" = "5" ]; then
        echo "  To debug: ssh -v $REMOTE_HOST"
    else
        echo "  To debug: ssh -v -p $SSH_PORT $REMOTE_HOST"
    fi
    exit 1
fi

# ============================================================
# Detect Available Items
# ============================================================

section "Scanning local credentials"

# SSH keys
LOCAL_SSH_KEYS=()
for f in ~/.ssh/id_*.pub; do
    [ -f "$f" ] && LOCAL_SSH_KEYS+=("${f%.pub}")
done

# GitHub CLI
HAS_GH_AUTH=false
[ -f ~/.config/gh/hosts.yml ] && HAS_GH_AUTH=true

# Claude Code
HAS_CLAUDE_AUTH=false
{ [ -f ~/.claude/credentials.json ] || [ -f ~/.claude/.credentials ] || [ -f ~/.claude/.credentials.json ]; } && HAS_CLAUDE_AUTH=true

# Codex
HAS_CODEX_AUTH=false
[ -f ~/.codex/auth.json ] && HAS_CODEX_AUTH=true

# API keys
HAS_API_KEYS=false
{ [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${OPENAI_API_KEY:-}" ]; } && HAS_API_KEYS=true

# Print scan results
[ ${#LOCAL_SSH_KEYS[@]} -gt 0 ] && success "${#LOCAL_SSH_KEYS[@]} SSH key pair(s) found" || warn "No SSH keys found"
[ "$HAS_GH_AUTH" = true ]      && success "GitHub CLI authenticated" || printf "  ${DIM}- GitHub CLI: not found${RESET}\n"
[ "$HAS_CLAUDE_AUTH" = true ]  && success "Claude Code credentials found" || printf "  ${DIM}- Claude Code: not found${RESET}\n"
[ "$HAS_CODEX_AUTH" = true ]   && success "Codex auth found" || printf "  ${DIM}- Codex auth: not found${RESET}\n"
[ "$HAS_API_KEYS" = true ]     && success "API keys detected in env" || printf "  ${DIM}- API keys: not set${RESET}\n"

# ============================================================
# Step Selection Menu
# ============================================================

# Define steps: name, available, default-on
STEPS=()
STEPS_AVAILABLE=()
STEPS_SELECTED=()

add_step() {
    STEPS+=("$1")
    STEPS_AVAILABLE+=("$2")     # "yes" or "no"
    STEPS_SELECTED+=("$3")      # "on" or "off"
}

add_step "SSH keys"              "$([ ${#LOCAL_SSH_KEYS[@]} -gt 0 ] && echo yes || echo no)" "off"
add_step "GitHub CLI auth"       "$([ "$HAS_GH_AUTH" = true ] && echo yes || echo no)"      "on"
add_step "Clone repo & setup.sh" "yes"                                                      "on"
add_step "Claude Code auth"      "$([ "$HAS_CLAUDE_AUTH" = true ] && echo yes || echo no)"  "on"
add_step "Codex auth"            "$([ "$HAS_CODEX_AUTH" = true ] && echo yes || echo no)"   "on"
add_step "API keys (env vars)"   "$([ "$HAS_API_KEYS" = true ] && echo yes || echo no)"    "on"

# Auto-deselect unavailable items
for i in "${!STEPS[@]}"; do
    if [ "${STEPS_AVAILABLE[$i]}" = "no" ]; then
        STEPS_SELECTED[$i]="off"
    fi
done

if [ "$AUTO_YES" = false ]; then
    echo ""
    info "What would you like to deploy?"
    echo ""

    display_menu() {
        for i in "${!STEPS[@]}"; do
            local marker avail_note=""
            if [ "${STEPS_AVAILABLE[$i]}" = "no" ]; then
                marker=" "
                avail_note=" ${DIM}(not available)${RESET}"
            elif [ "${STEPS_SELECTED[$i]}" = "on" ]; then
                marker="x"
            else
                marker=" "
            fi
            printf "  [%s] %d) %s%b\n" "$marker" "$((i+1))" "${STEPS[$i]}" "$avail_note"
        done
    }

    display_menu
    echo ""
    echo "  Enter numbers to toggle, 'a' for all, 'n' for none, or Enter to confirm:"

    while true; do
        read -rp "  > " selection
        if [ -z "$selection" ]; then
            break
        fi
        case "${selection,,}" in
            a|all)
                for i in "${!STEPS[@]}"; do
                    [ "${STEPS_AVAILABLE[$i]}" = "yes" ] && STEPS_SELECTED[$i]="on"
                done
                ;;
            n|none)
                for i in "${!STEPS[@]}"; do
                    STEPS_SELECTED[$i]="off"
                done
                ;;
            *)
                for num in $selection; do
                    if [[ "$num" =~ ^[0-9]+$ ]]; then
                        idx=$((num - 1))
                        if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#STEPS[@]} ] && [ "${STEPS_AVAILABLE[$idx]}" = "yes" ]; then
                            if [ "${STEPS_SELECTED[$idx]}" = "on" ]; then
                                STEPS_SELECTED[$idx]="off"
                            else
                                STEPS_SELECTED[$idx]="on"
                            fi
                        fi
                    fi
                done
                ;;
        esac
        echo ""
        display_menu
        echo ""
        echo "  Enter numbers to toggle, or Enter to confirm:"
    done
fi

# ============================================================
# Pre-flight Summary
# ============================================================

selected_names=()
for i in "${!STEPS[@]}"; do
    [ "${STEPS_SELECTED[$i]}" = "on" ] && selected_names+=("${STEPS[$i]}")
done

if [ ${#selected_names[@]} -eq 0 ]; then
    echo ""
    warn "Nothing selected. Exiting."
    exit 0
fi

echo ""
printf "${BOLD}=== Deploy Summary ===${RESET}\n"
printf "  Target:  %s" "$REMOTE_HOST"
[ "$AUTH_METHOD" != "5" ] && printf ":%s" "$SSH_PORT"
echo ""
[ -n "$JUMP_HOST" ] && echo "  Jump:    $JUMP_HOST"
printf "  Auth:    "
case "$AUTH_METHOD" in
    1) echo "password (session multiplexed)" ;;
    2) echo "SSH key" ;;
    3) echo "SSH key ($IDENTITY_FILE)" ;;
    4) echo "password + 2FA/DUO (session multiplexed)" ;;
    5) echo "SSH config alias" ;;
esac
echo "  Steps:   ${selected_names[*]}"
echo ""

if ! confirm "Proceed?" "y"; then
    echo "Aborted."; exit 0
fi

# ============================================================
# Step Implementations
# ============================================================

step_ssh_keys() {
    section "SSH Keys"

    # Authorize local public key on remote
    echo "  Authorizing local public key on remote..."
    ssh-copy-id "${SSH_OPTS[@]}" "$REMOTE_HOST" 2>&1 | grep -v "^$" || warn "ssh-copy-id failed (key may already be authorized)"

    # Confirm before copying private keys
    if ! confirm "Copy private SSH keys to remote?" "n"; then
        success "Public key authorized (private keys not copied)"
        return 0
    fi

    # Copy key pairs to remote
    remote_exec "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

    local copied=0
    for priv in "${LOCAL_SSH_KEYS[@]}"; do
        local pub="${priv}.pub"
        echo "  Copying $(basename "$priv")..."
        if remote_copy "$priv" "$pub" "$REMOTE_HOST:~/.ssh/"; then
            remote_exec "chmod 600 ~/.ssh/$(basename "$priv") && chmod 644 ~/.ssh/$(basename "$pub")"
            copied=$((copied + 1))
        else
            error "Failed to copy $(basename "$priv")"
        fi
    done

    # Copy known_hosts so remote trusts github.com etc.
    if [ -f ~/.ssh/known_hosts ]; then
        remote_copy ~/.ssh/known_hosts "$REMOTE_HOST:~/.ssh/known_hosts"
    fi

    success "$copied key pair(s) copied"
}

step_gh_auth() {
    section "GitHub CLI Auth"
    remote_exec "mkdir -p ~/.config/gh"
    if remote_copy ~/.config/gh/hosts.yml "$REMOTE_HOST:~/.config/gh/"; then
        success "GitHub CLI credentials copied"
    else
        error "Failed to copy GitHub CLI auth"
        return 1
    fi
}

step_claude_auth() {
    section "Claude Code Auth"
    remote_exec "mkdir -p ~/.claude"
    local copied=false
    for cred_file in credentials.json .credentials .credentials.json; do
        if [ -f ~/.claude/"$cred_file" ]; then
            remote_copy ~/.claude/"$cred_file" "$REMOTE_HOST:~/.claude/" && copied=true
        fi
    done
    if [ "$copied" = false ]; then
        error "Failed to copy Claude Code credentials"
        return 1
    fi
    success "Claude Code credentials copied"
    if remote_exec "command -v claude &>/dev/null" && remote_exec "claude auth status --json 2>/dev/null | grep -q '\"loggedIn\": *true'"; then
        success "Claude Code authenticated on remote"
    else
        warn "Credentials copied but auth not verified"
        if confirm "Open interactive SSH session to run 'claude auth login'?" "y"; then
            echo "  Run 'claude auth login' in the remote shell, then 'exit' to continue deploy."
            ssh -o "ControlPath=$SSH_SOCKET" -o BatchMode=no -t "$REMOTE_HOST" || true
        fi
    fi
}

step_codex_auth() {
    section "Codex Auth"
    remote_exec "mkdir -p ~/.codex"
    if remote_copy ~/.codex/auth.json "$REMOTE_HOST:~/.codex/"; then
        success "Codex auth copied"
    else
        error "Failed to copy Codex auth"
        return 1
    fi
}

step_api_keys() {
    section "API Keys"

    local env_keys=""
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        env_keys+="export ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY//\'/\'\\\'\'}'"$'\n'
        echo "  • ANTHROPIC_API_KEY"
    fi
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        env_keys+="export OPENAI_API_KEY='${OPENAI_API_KEY//\'/\'\\\'\'}'"$'\n'
        echo "  • OPENAI_API_KEY"
    fi

    # Use base64 to safely transfer (avoids shell quoting issues)
    if printf "%s" "$env_keys" | base64 | remote_exec "base64 -d > ~/.env_keys && chmod 600 ~/.env_keys"; then
        remote_exec "grep -qF '.env_keys' ~/.bashrc 2>/dev/null || echo '[ -f ~/.env_keys ] && source ~/.env_keys' >> ~/.bashrc"
        success "API keys written to ~/.env_keys"
    else
        error "Failed to write API keys"
        return 1
    fi
}

step_clone_setup() {
    section "Clone Repo & Run Setup"

    # Derive repo slug and HTTPS URL from local remote
    local REPO_URL REPO_SLUG
    REPO_URL="$(git -C "$DIR" remote get-url origin 2>/dev/null | sed 's|git@github.com:|https://github.com/|')"
    if [ -z "$REPO_URL" ]; then
        REPO_URL="https://github.com/jianjianh1/server-configs.git"
    fi
    # Extract owner/repo slug (e.g. "jianjianh1/server-configs")
    REPO_SLUG="$(echo "$REPO_URL" | sed 's|.*github\.com/||; s|\.git$||')"

    local REMOTE_DIR="\$HOME/repos/server-configs"

    if remote_exec "[ -d $REMOTE_DIR/.git ]"; then
        echo "  Repo exists — pulling latest..."
        remote_exec "cd $REMOTE_DIR && git pull"
    else
        echo "  Cloning $REPO_SLUG..."
        if remote_exec "command -v gh &>/dev/null && gh auth status &>/dev/null"; then
            # Prefer gh repo clone (uses gh's own auth)
            if ! remote_exec "mkdir -p \$HOME/repos && cd \$HOME/repos && gh repo clone $REPO_SLUG"; then
                error "gh repo clone failed — verify GitHub auth (run 'gh auth login' on the remote)"
                return 1
            fi
        else
            # Fallback to git clone over HTTPS
            if ! remote_exec "mkdir -p \$HOME/repos && git clone $REPO_URL $REMOTE_DIR"; then
                error "git clone failed — verify GitHub auth (run 'gh auth login' on the remote)"
                return 1
            fi
        fi
    fi

    echo "  Running setup.sh..."
    if remote_exec "cd $REMOTE_DIR && ./setup.sh"; then
        success "setup.sh completed"
    else
        warn "setup.sh exited with errors (check output above)"
        return 1
    fi
}

# ============================================================
# Execute Selected Steps
# ============================================================

echo ""

[ "${STEPS_SELECTED[0]}" = "on" ] && run_step "SSH keys"         step_ssh_keys
[ "${STEPS_SELECTED[1]}" = "on" ] && run_step "GitHub CLI auth"  step_gh_auth
[ "${STEPS_SELECTED[2]}" = "on" ] && run_step "Clone & setup"    step_clone_setup
[ "${STEPS_SELECTED[3]}" = "on" ] && run_step "Claude Code auth" step_claude_auth
[ "${STEPS_SELECTED[4]}" = "on" ] && run_step "Codex auth"       step_codex_auth
[ "${STEPS_SELECTED[5]}" = "on" ] && run_step "API keys"         step_api_keys

# ============================================================
# Summary
# ============================================================

echo ""
printf "${BOLD}===============================${RESET}\n"
if [ ${#FAILURES[@]} -gt 0 ]; then
    printf "${RED}Deploy complete with ${#FAILURES[@]} failure(s):${RESET}\n"
    for f in "${FAILURES[@]}"; do
        error "$f"
    done
    exit 1
else
    printf "${GREEN}Deploy complete! Remote server is ready.${RESET}\n"
    printf "  ssh"
    [ -n "$JUMP_HOST" ] && printf " -J %s" "$JUMP_HOST"
    [ "$AUTH_METHOD" != "5" ] && printf " -p %s" "$SSH_PORT"
    [ -n "$IDENTITY_FILE" ] && printf " -i %s" "$IDENTITY_FILE"
    printf " %s\n" "$REMOTE_HOST"
fi
