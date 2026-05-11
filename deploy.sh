#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR

# --- Flags ---
AUTO_YES="${AUTO_YES:-false}"
FORCE_COPY="${FORCE_COPY:-0}"

usage() {
    echo "Usage: deploy.sh [-y|--yes] [--force-copy] [-h|--help]"
    echo "  -y, --yes     Skip all interactive confirmations"
    echo "  --force-copy  Re-copy files even when the remote already matches"
    echo "  -h, --help    Show this help"
}

parse_args() {
    local arg

    AUTO_YES=false
    FORCE_COPY=0
    for arg in "$@"; do
        case "$arg" in
            -y|--yes) AUTO_YES=true ;;
            --force-copy) FORCE_COPY=1 ;;
            -h|--help) usage; return 2 ;;
            *)
                echo "Unknown option: $arg"
                usage
                return 1
                ;;
        esac
    done
    export FORCE_COPY
}

check_prereqs() {
    local missing=() cmd

    for cmd in ssh scp git base64; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: missing required commands: ${missing[*]}"
        return 1
    fi
}

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

# --- Shared helpers (run_step, retry) ---
# Export AUTO_YES so the library's run_step sees it.
export AUTO_YES
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

local_claude_credentials_file() {
    printf "%s/.credentials.json" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

local_codex_auth_file() {
    printf "%s/auth.json" "${CODEX_HOME:-$HOME/.codex}"
}

local_gh_config_dir() {
    if [ -n "${GH_CONFIG_DIR:-}" ]; then
        printf "%s" "$GH_CONFIG_DIR"
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf "%s/gh" "$XDG_CONFIG_HOME"
    else
        printf "%s/.config/gh" "$HOME"
    fi
}

local_gh_hosts_file() {
    printf "%s/hosts.yml" "$(local_gh_config_dir)"
}

local_gh_hosts_has_token() {
    local hosts_file="$1"

    [ -f "$hosts_file" ] || return 1
    grep -q '^[[:space:]]*oauth_token:' "$hosts_file"
}

local_gh_token_available() {
    command -v gh >/dev/null 2>&1 || return 1
    [ -n "$(gh auth token 2>/dev/null || true)" ]
}

auth_state_gh() {
    local hosts_file="${1:-$(local_gh_hosts_file)}"

    if ! command -v gh >/dev/null 2>&1; then
        printf "missing|gh CLI not installed locally"
    elif ! gh auth status >/dev/null 2>&1; then
        printf "missing|gh CLI is not authenticated locally"
    elif local_gh_token_available; then
        printf "deployable|token from gh auth token -> gh auth login --with-token on remote"
    elif local_gh_hosts_has_token "$hosts_file"; then
        printf "deployable|plaintext hosts.yml -> \$HOME/.config/gh/hosts.yml"
    else
        printf "blocked|gh is authenticated, but no readable token or plaintext hosts.yml token is available"
    fi
}

auth_state_claude() {
    local credentials_file="${1:-$(local_claude_credentials_file)}"

    if [ -f "$credentials_file" ]; then
        printf "deployable|%s -> \$HOME/.claude/.credentials.json" "$credentials_file"
    elif command -v claude >/dev/null 2>&1 && claude auth status >/dev/null 2>&1; then
        printf "blocked|Claude is logged in locally, but auth is not in a copyable credentials file; run 'claude auth login' or 'claude setup-token' on the remote"
    else
        printf "missing|Claude credentials file not found at %s" "$credentials_file"
    fi
}

auth_state_codex() {
    local auth_file="${1:-$(local_codex_auth_file)}"

    if [ -f "$auth_file" ]; then
        printf "deployable|%s -> \$HOME/.codex/auth.json" "$auth_file"
    else
        printf "missing|Codex auth file not found at %s" "$auth_file"
    fi
}

auth_state_api_keys() {
    local names=()

    [ -n "${ANTHROPIC_API_KEY:-}" ] && names+=("ANTHROPIC_API_KEY")
    [ -n "${OPENAI_API_KEY:-}" ] && names+=("OPENAI_API_KEY")
    if [ ${#names[@]} -gt 0 ]; then
        printf "deployable|%s -> \$HOME/.env_keys" "${names[*]}"
    else
        printf "missing|ANTHROPIC_API_KEY and OPENAI_API_KEY are not set"
    fi
}

auth_state_status() {
    printf "%s" "$1" | cut -d '|' -f 1
}

auth_state_detail() {
    printf "%s" "$1" | cut -d '|' -f 2-
}

shell_quote_env_value() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

copy_local_file_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    local mode="${3:-600}"

    [ -f "$local_path" ] || return 1

    # Idempotency: skip copy if remote file is byte-identical. FORCE_COPY=1
    # bypasses this (e.g. to rewrite permissions). The sha256 sum is compared
    # over the remote path using the same shell expansion the write uses below.
    if [ "${FORCE_COPY:-0}" != 1 ]; then
        local local_sum remote_sum
        local_sum="$(sha256_file "$local_path" 2>/dev/null || true)"
        remote_sum="$(remote_exec "
            dest=\"$remote_path\"
            if [ -f \"\$dest\" ]; then
                if command -v sha256sum >/dev/null 2>&1; then
                    sha256sum \"\$dest\" 2>/dev/null | awk '{print \$1}'
                elif command -v shasum >/dev/null 2>&1; then
                    shasum -a 256 \"\$dest\" 2>/dev/null | awk '{print \$1}'
                fi
            fi
        " 2>/dev/null || true)"
        if [ -n "$local_sum" ] && [ "$local_sum" = "$remote_sum" ]; then
            echo "    (unchanged — skipping)"
            return 0
        fi
    fi

    base64 < "$local_path" | remote_exec "
        set -eu
        umask 077
        dest=\"$remote_path\"
        dest_dir=\$(dirname \"\$dest\")
        mkdir -p \"\$dest_dir\" || exit 1
        tmp=\$(mktemp \"\$dest_dir/.deploy.XXXXXX\") || exit 1
        cleanup_tmp() { rm -f \"\$tmp\"; }
        trap cleanup_tmp EXIT HUP INT TERM
        if printf '' | base64 -d >/dev/null 2>&1; then
            base64_decode='base64 -d'
        elif printf '' | base64 -D >/dev/null 2>&1; then
            base64_decode='base64 -D'
        else
            echo 'base64 decode is unavailable' >&2
            exit 1
        fi
        \$base64_decode > \"\$tmp\" &&
        chmod $mode \"\$tmp\" &&
        mv -f \"\$tmp\" \"\$dest\"
        status=\$?
        [ \$status -eq 0 ] || cleanup_tmp
        trap - EXIT HUP INT TERM
        exit \$status
    "
}

ensure_remote_env_keys_loader() {
    remote_exec "
        touch ~/.env_keys && chmod 600 ~/.env_keys
        grep -qF '[ -f ~/.env_keys ] && . ~/.env_keys' ~/.bashrc 2>/dev/null || echo '[ -f ~/.env_keys ] && . ~/.env_keys' >> ~/.bashrc
        grep -qF '[ -f ~/.env_keys ] && . ~/.env_keys' ~/.profile 2>/dev/null || echo '[ -f ~/.env_keys ] && . ~/.env_keys' >> ~/.profile
    "
}

remote_upsert_env_exports() {
    printf "%s" "$1" | base64 | remote_exec '
        set -eu
        umask 077
        dest="$HOME/.env_keys"
        dest_dir=$(dirname "$dest")
        mkdir -p "$dest_dir"
        tmp_in=$(mktemp "$dest_dir/.env_keys.in.XXXXXX")
        tmp_out=$(mktemp "$dest_dir/.env_keys.out.XXXXXX")
        cleanup_tmp() { rm -f "$tmp_in" "$tmp_out" "${tmp_out}.next"; }
        trap cleanup_tmp EXIT HUP INT TERM
        if printf "" | base64 -d >/dev/null 2>&1; then
            base64_decode="base64 -d"
        elif printf "" | base64 -D >/dev/null 2>&1; then
            base64_decode="base64 -D"
        else
            echo "base64 decode is unavailable" >&2
            exit 1
        fi
        $base64_decode > "$tmp_in"
        touch "$dest"
        chmod 600 "$dest"
        cp "$dest" "$tmp_out"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            var=${line#export }
            var=${var%%=*}
            grep -v "^export ${var}=" "$tmp_out" > "${tmp_out}.next" || true
            mv "${tmp_out}.next" "$tmp_out"
            printf "%s\n" "$line" >> "$tmp_out"
        done < "$tmp_in"
        chmod 600 "$tmp_out"
        mv "$tmp_out" "$dest"
        status=$?
        [ $status -eq 0 ] || cleanup_tmp
        trap - EXIT HUP INT TERM
        exit $status
    '
}

# --- SSH helpers ---
SSH_OPTS=()
SSH_SOCKET=""
SSH_SOCKET_DIR=""
REMOTE_HOST=""

remote_exec() {
    if [ -n "$SSH_SOCKET" ] && ! ssh -O check -o "ControlPath=$SSH_SOCKET" "$REMOTE_HOST" &>/dev/null; then
        error "SSH connection dropped. Try re-running the script."
        return 1
    fi
    local cmd="$1" quoted_cmd
    quoted_cmd="$(quote_for_bash_lc "$cmd")"
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "export TERM=dumb PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"; bash -lc $quoted_cmd"
}

# Like remote_exec, but captures stdout reliably even when the remote's login
# shell prints an MOTD or `~/.profile` echoes before our command runs. The
# remote command runs under `bash -c` (no login) and is bracketed by sentinel
# markers; we extract the lines between them locally. Banner noise printed by
# the outer login shell ends up outside the markers and is stripped.
remote_capture() {
    if [ -n "$SSH_SOCKET" ] && ! ssh -O check -o "ControlPath=$SSH_SOCKET" "$REMOTE_HOST" &>/dev/null; then
        error "SSH connection dropped. Try re-running the script."
        return 1
    fi
    local cmd="$1" quoted_cmd raw
    # Per-call nonce: a remote command that legitimately echoes a static
    # marker can't misalign the extractor.
    local nonce="$$_${RANDOM}_${RANDOM}"
    local begin="__DEPLOY_CAPTURE_${nonce}_BEGIN__"
    local end="__DEPLOY_CAPTURE_${nonce}_END__"
    quoted_cmd="$(quote_for_bash_lc "$cmd")"
    raw="$(ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "
        export TERM=dumb PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"
        printf '%s\n' '$begin'
        bash -c $quoted_cmd
        printf '%s\n' '$end'
    " 2>/dev/null)" || return 1
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { inside = 1; next }
        $0 == end   { found_end = 1; inside = 0; next }
        inside      { print }
        END         { exit (found_end ? 0 : 2) }
    ' <<<"$raw"
}

remote_copy() {
    retry scp -r "${SSH_OPTS[@]}" "$@"
}

# Like remote_copy, but skips the transfer if the single local file already
# matches the remote at $remote_path (by sha256). Respects FORCE_COPY=1.
# Usage: remote_copy_if_changed <local_file> <remote_path>
remote_copy_if_changed() {
    local local_path="$1" remote_path="$2"
    if [ "${FORCE_COPY:-0}" != 1 ] && [ -f "$local_path" ]; then
        local local_sum remote_sum
        local_sum="$(sha256_file "$local_path" 2>/dev/null || true)"
        # Use remote_capture so any login banner/MOTD on the remote shell
        # cannot pollute the captured sha (which is then string-compared).
        remote_sum="$(remote_capture "
            if [ -f \"$remote_path\" ]; then
                if command -v sha256sum >/dev/null 2>&1; then
                    sha256sum \"$remote_path\" 2>/dev/null | awk '{print \$1}'
                elif command -v shasum >/dev/null 2>&1; then
                    shasum -a 256 \"$remote_path\" 2>/dev/null | awk '{print \$1}'
                fi
            fi
        " 2>/dev/null || true)"
        if [ -n "$local_sum" ] && [ "$local_sum" = "$remote_sum" ]; then
            echo "    (unchanged — skipping $remote_path)"
            return 0
        fi
    fi
    remote_copy "$local_path" "$REMOTE_HOST:$remote_path"
}

remote_claude_supports_print() {
    remote_exec "claude --help 2>/dev/null | grep -q -- '-p, --print'"
}

remote_codex_supports_login_status() {
    remote_exec "codex login --help 2>/dev/null | grep -q '^[[:space:]]*status[[:space:]]'"
}

bootstrap_remote_gh_cli() {
    remote_exec '
        if command -v gh >/dev/null 2>&1; then
            exit 0
        fi

        if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
            echo "curl and tar are required to bootstrap gh" >&2
            exit 1
        fi

        os="$(uname -s 2>/dev/null || true)"
        arch="$(uname -m 2>/dev/null || true)"
        case "$os:$arch" in
            Linux:x86_64|Linux:amd64) gh_arch=amd64 ;;
            Linux:aarch64|Linux:arm64) gh_arch=arm64 ;;
            *) echo "unsupported remote platform for gh bootstrap: $os $arch" >&2; exit 1 ;;
        esac

        tmp="$(mktemp -d)"
        trap '\''rm -rf "$tmp"'\'' EXIT
        latest_url="$(curl -fsIL -o /dev/null -w "%{url_effective}" https://github.com/cli/cli/releases/latest)"
        version="${latest_url##*/v}"
        case "$version" in
            ""|"$latest_url") echo "could not determine latest gh version" >&2; exit 1 ;;
        esac

        mkdir -p "$HOME/.local/bin"
        curl -sfL -o "$tmp/gh.tar.gz" "https://github.com/cli/cli/releases/download/v${version}/gh_${version}_linux_${gh_arch}.tar.gz"
        tar -xzf "$tmp/gh.tar.gz" -C "$tmp"
        bin="$(find "$tmp" -type f -path "*/bin/gh" | head -1)"
        [ -n "$bin" ] || { echo "gh binary not found in archive" >&2; exit 1; }
        cp "$bin" "$HOME/.local/bin/gh"
        chmod 755 "$HOME/.local/bin/gh"
    '
}

cleanup() {
    if [ -n "$SSH_SOCKET" ]; then
        ssh -O exit -o "ControlPath=$SSH_SOCKET" "$REMOTE_HOST" &>/dev/null || true
        rm -f "$SSH_SOCKET"
    fi
    if [ -n "$SSH_SOCKET_DIR" ]; then
        rmdir "$SSH_SOCKET_DIR" 2>/dev/null || rm -rf "$SSH_SOCKET_DIR" 2>/dev/null || true
    fi
}

# ============================================================
# Connection Setup
# ============================================================

deploy_main() {
parse_args "$@"
case "$?" in
    0) ;;
    2) return 0 ;;
    *) return 1 ;;
esac
export AUTO_YES
check_prereqs || return 1
trap cleanup EXIT

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
case "$(to_lower "$AUTH_METHOD")" in
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
        SSH_OPTS=(-o ConnectTimeout="$CONNECT_TIMEOUT" -o "PreferredAuthentications=keyboard-interactive,password" -o NumberOfPasswordPrompts=3 -o Port="$SSH_PORT")
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
# mktemp -d creates a mode-700 dir with a random suffix; the socket lives
# inside it so other users on the box can't predict the path or race the
# bind. cleanup() removes the dir on exit.
SSH_SOCKET_DIR="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/deploy.XXXXXX")" || {
    error "Failed to create SSH socket directory under ${TMPDIR:-/tmp}"
    exit 1
}
SSH_SOCKET="$SSH_SOCKET_DIR/socket"

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
LOCAL_GH_HOSTS_FILE="$(local_gh_hosts_file)"
GH_AUTH_STATE="$(auth_state_gh "$LOCAL_GH_HOSTS_FILE")"
GH_AUTH_STATUS="$(auth_state_status "$GH_AUTH_STATE")"
GH_AUTH_DETAIL="$(auth_state_detail "$GH_AUTH_STATE")"
HAS_GH_AUTH=false
[ "$GH_AUTH_STATUS" = "deployable" ] && HAS_GH_AUTH=true

# Claude Code
LOCAL_CLAUDE_CREDENTIALS_FILE="$(local_claude_credentials_file)"
CLAUDE_AUTH_STATE="$(auth_state_claude "$LOCAL_CLAUDE_CREDENTIALS_FILE")"
CLAUDE_AUTH_STATUS="$(auth_state_status "$CLAUDE_AUTH_STATE")"
CLAUDE_AUTH_DETAIL="$(auth_state_detail "$CLAUDE_AUTH_STATE")"
HAS_CLAUDE_AUTH=false
[ "$CLAUDE_AUTH_STATUS" = "deployable" ] && HAS_CLAUDE_AUTH=true

# Codex
LOCAL_CODEX_AUTH_FILE="$(local_codex_auth_file)"
CODEX_AUTH_STATE="$(auth_state_codex "$LOCAL_CODEX_AUTH_FILE")"
CODEX_AUTH_STATUS="$(auth_state_status "$CODEX_AUTH_STATE")"
CODEX_AUTH_DETAIL="$(auth_state_detail "$CODEX_AUTH_STATE")"
HAS_CODEX_AUTH=false
[ "$CODEX_AUTH_STATUS" = "deployable" ] && HAS_CODEX_AUTH=true

# API keys
API_KEYS_STATE="$(auth_state_api_keys)"
API_KEYS_STATUS="$(auth_state_status "$API_KEYS_STATE")"
API_KEYS_DETAIL="$(auth_state_detail "$API_KEYS_STATE")"
HAS_API_KEYS=false
[ "$API_KEYS_STATUS" = "deployable" ] && HAS_API_KEYS=true

# Print scan results
[ ${#LOCAL_SSH_KEYS[@]} -gt 0 ] && success "${#LOCAL_SSH_KEYS[@]} SSH key pair(s) found" || warn "No SSH keys found"
case "$GH_AUTH_STATUS" in
    deployable) success "GitHub CLI auth deployable ($GH_AUTH_DETAIL)" ;;
    blocked) warn "GitHub CLI auth not transferable: $GH_AUTH_DETAIL" ;;
    *) printf "  ${DIM}- GitHub CLI auth: %s${RESET}\n" "$GH_AUTH_DETAIL" ;;
esac
case "$CLAUDE_AUTH_STATUS" in
    deployable) success "Claude Code auth deployable ($CLAUDE_AUTH_DETAIL)" ;;
    blocked) warn "Claude Code auth not transferable: $CLAUDE_AUTH_DETAIL" ;;
    *) printf "  ${DIM}- Claude Code auth: %s${RESET}\n" "$CLAUDE_AUTH_DETAIL" ;;
esac
case "$CODEX_AUTH_STATUS" in
    deployable) success "Codex auth deployable ($CODEX_AUTH_DETAIL)" ;;
    blocked) warn "Codex auth not transferable: $CODEX_AUTH_DETAIL" ;;
    *) printf "  ${DIM}- Codex auth: %s${RESET}\n" "$CODEX_AUTH_DETAIL" ;;
esac
case "$API_KEYS_STATUS" in
    deployable) success "API keys deployable ($API_KEYS_DETAIL)" ;;
    blocked) warn "API keys not transferable: $API_KEYS_DETAIL" ;;
    *) printf "  ${DIM}- API keys: %s${RESET}\n" "$API_KEYS_DETAIL" ;;
esac

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
        case "$(to_lower "$selection")" in
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
echo "  Auth transfer:"
auth_transfer_count=0
if [ "${STEPS_SELECTED[0]}" = "on" ]; then
    echo "    - SSH public key authorization via ssh-copy-id"
    if [ -f ~/.ssh/known_hosts ]; then
        echo "    - ~/.ssh/known_hosts -> \$HOME/.ssh/known_hosts"
    fi
    echo "    - Private SSH keys: never copied"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "${STEPS_SELECTED[1]}" = "on" ]; then
    echo "    - GitHub CLI: $GH_AUTH_DETAIL"
    echo "      verify: gh auth status"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "${STEPS_SELECTED[3]}" = "on" ]; then
    echo "    - Claude Code: $CLAUDE_AUTH_DETAIL"
    echo "      verify: claude auth status / claude -p 'ping'"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "${STEPS_SELECTED[4]}" = "on" ]; then
    echo "    - Codex: $CODEX_AUTH_DETAIL"
    echo "      verify: codex login status"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "${STEPS_SELECTED[5]}" = "on" ]; then
    echo "    - API keys: $API_KEYS_DETAIL"
    echo "      values are never printed"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "$auth_transfer_count" -eq 0 ]; then
    echo "    - none selected"
fi
echo ""

if ! confirm "Proceed?" "y"; then
    echo "Aborted."; exit 0
fi

# ============================================================
# Step Implementations
# ============================================================

step_ssh_keys() {
    section "SSH Keys"

    if ! command -v ssh-copy-id &>/dev/null; then
        error "ssh-copy-id is required for this step"
        echo "    Install openssh-client tools locally or skip the SSH keys step."
        return 1
    fi

    # Authorize local public key on remote
    echo "  Authorizing local public key on remote..."
    ssh-copy-id "${SSH_OPTS[@]}" "$REMOTE_HOST" 2>&1 | grep -v "^$" || warn "ssh-copy-id failed (key may already be authorized)"

    # Copy known_hosts so remote trusts github.com etc.
    if [ -f ~/.ssh/known_hosts ]; then
        remote_exec "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
        # shellcheck disable=SC2088 # Remote scp target; tilde expands on the server.
        if remote_copy_if_changed ~/.ssh/known_hosts '~/.ssh/known_hosts'; then
            remote_exec "chmod 644 ~/.ssh/known_hosts"
        else
            warn "Failed to copy known_hosts"
        fi
    fi

    echo "  Private SSH key copying is intentionally disabled."
    echo "    Use agent forwarding or generate a dedicated key on the remote if needed."
    success "Public key authorized"
}

step_gh_auth() {
    section "GitHub CLI Auth"
    local gh_token=""

    if [ "${GH_AUTH_STATUS:-missing}" != "deployable" ]; then
        error "GitHub CLI auth is not deployable"
        echo "    ${GH_AUTH_DETAIL:-not detected}"
        return 1
    fi

    if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
        error "Local gh is not authenticated"
        echo "    Run 'gh auth login' locally first."
        return 1
    fi

    if ! remote_exec "command -v gh &>/dev/null"; then
        echo "  GitHub CLI not found on remote; bootstrapping to ~/.local/bin..."
        if ! bootstrap_remote_gh_cli; then
            error "GitHub CLI not found on remote and bootstrap failed"
            echo "    Install gh on the remote manually or skip this step."
            return 1
        fi
    fi

    if ! remote_exec "command -v gh &>/dev/null"; then
        error "GitHub CLI not found on remote after bootstrap"
        return 1
    fi

    gh_token="$(gh auth token 2>/dev/null || true)"
    # Validate against GitHub's known token prefixes so we never pipe
    # arbitrary content (banners, error messages, accidentally-captured
    # whitespace) into `gh auth login --with-token` on the remote.
    # ghp_ PAT classic, gho_ OAuth, ghu_ user-server, ghs_ server,
    # github_pat_ fine-grained PAT.
    if [ -n "$gh_token" ] && ! [[ "$gh_token" =~ ^(ghp_|gho_|ghu_|ghs_|github_pat_)[A-Za-z0-9_]+$ ]]; then
        warn "Local gh token failed shape validation; falling back to hosts.yml"
        gh_token=""
    fi
    if [ -n "$gh_token" ] && printf "%s" "$gh_token" | remote_exec '
        set -eu -o pipefail
        umask 077
        mkdir -p "$HOME/.config/gh"
        chmod 700 "$HOME/.config" "$HOME/.config/gh" 2>/dev/null || true
        GH_PROMPT_DISABLED=1 gh auth login --hostname github.com --git-protocol https --with-token >/dev/null
        gh auth setup-git >/dev/null 2>&1 || true
    '; then
        :
    elif local_gh_hosts_has_token "$LOCAL_GH_HOSTS_FILE" &&
        copy_local_file_to_remote "$LOCAL_GH_HOSTS_FILE" '$HOME/.config/gh/hosts.yml' 600; then
        remote_exec "
            set -u
            chmod 700 \"\$HOME/.config\" \"\$HOME/.config/gh\" 2>/dev/null || true
            gh auth setup-git >/dev/null 2>&1 || true
        "
    else
        error "Failed to copy GitHub CLI auth"
        echo "    Local gh token is not readable, and $LOCAL_GH_HOSTS_FILE has no plaintext token fallback."
        return 1
    fi

    if remote_exec "gh auth status >/dev/null 2>&1"; then
        success "GitHub CLI credentials copied and verified"
    else
        error "GitHub CLI credentials copied but auth did not verify"
        return 1
    fi
}

step_claude_auth() {
    section "Claude Code Auth"

    if [ "${CLAUDE_AUTH_STATUS:-missing}" != "deployable" ]; then
        error "Claude Code auth is not deployable"
        echo "    ${CLAUDE_AUTH_DETAIL:-not detected}"
        return 1
    fi

    if [ ! -f "$LOCAL_CLAUDE_CREDENTIALS_FILE" ]; then
        error "Local Claude Code auth file not found"
        echo "    Expected: $LOCAL_CLAUDE_CREDENTIALS_FILE"
        return 1
    fi

    if ! remote_exec "command -v claude &>/dev/null"; then
        error "Claude Code CLI not found on remote"
        echo "    Run the clone/setup step before Claude Code auth."
        return 1
    fi

    if ! remote_exec "[ -f ~/.claude/settings.json ]"; then
        error "Claude Code settings not found on remote"
        echo "    Run the clone/setup step from this repo before Claude Code auth."
        return 1
    fi

    if copy_local_file_to_remote "$LOCAL_CLAUDE_CREDENTIALS_FILE" '$HOME/.claude/.credentials.json' 600; then
        success "Claude Code credentials copied to remote"
    else
        error "Failed to copy Claude Code credentials"
        return 1
    fi

    if remote_claude_supports_print; then
        if remote_exec "claude -p 'ping' >/dev/null 2>&1"; then
            success "Claude Code auth verified on remote"
        else
            warn "Claude Code credentials copied but auth did not verify"
        fi
    else
        warn "Claude Code credentials copied, but this remote Claude Code build has no print mode for verification"
    fi
}

step_codex_auth() {
    section "Codex Auth"
    if [ "${CODEX_AUTH_STATUS:-missing}" != "deployable" ]; then
        error "Codex auth is not deployable"
        echo "    ${CODEX_AUTH_DETAIL:-not detected}"
        return 1
    fi

    if [ ! -f "$LOCAL_CODEX_AUTH_FILE" ]; then
        error "Local Codex auth file not found"
        echo "    Expected: $LOCAL_CODEX_AUTH_FILE"
        return 1
    fi

    if ! remote_exec "command -v codex &>/dev/null"; then
        error "Codex CLI not found on remote"
        echo "    Run the clone/setup step before Codex auth."
        return 1
    fi

    if ! remote_exec "[ -f ~/.codex/config.toml ]"; then
        error "Codex config not found on remote"
        echo "    Run the clone/setup step from this repo before Codex auth."
        return 1
    fi

    if copy_local_file_to_remote "$LOCAL_CODEX_AUTH_FILE" '$HOME/.codex/auth.json' 600; then
        success "Codex auth file copied to remote"
    else
        error "Failed to copy Codex auth file"
        return 1
    fi

    if remote_codex_supports_login_status; then
        if remote_exec "codex login status >/dev/null 2>&1"; then
            success "Codex auth verified on remote"
        else
            warn "Codex auth file copied but login status did not verify"
        fi
    else
        warn "Codex auth file copied, but this remote Codex build has no 'login status' command for verification"
    fi
}

step_api_keys() {
    section "API Keys"

    local env_keys=""
    if [ "${API_KEYS_STATUS:-missing}" != "deployable" ]; then
        error "API keys are not deployable"
        echo "    ${API_KEYS_DETAIL:-not detected}"
        return 1
    fi

    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        env_keys+="export ANTHROPIC_API_KEY=$(shell_quote_env_value "$ANTHROPIC_API_KEY")"$'\n'
        echo "  • ANTHROPIC_API_KEY"
    fi
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        env_keys+="export OPENAI_API_KEY=$(shell_quote_env_value "$OPENAI_API_KEY")"$'\n'
        echo "  • OPENAI_API_KEY"
    fi

    # Use base64 to safely transfer (avoids shell quoting issues)
    if remote_upsert_env_exports "$env_keys"; then
        ensure_remote_env_keys_loader
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
        local FALLBACK_REPO_URL="https://github.com/jianjianh1/server-configs.git"
        warn "Could not read 'origin' remote from $DIR"
        echo "    Default: $FALLBACK_REPO_URL"
        if ! confirm "Use the default repo URL above?" "n"; then
            error "Aborted. Re-run from inside the intended git clone, or set 'origin' first."
            return 1
        fi
        REPO_URL="$FALLBACK_REPO_URL"
    fi
    # Extract owner/repo slug (e.g. "jianjianh1/server-configs")
    REPO_SLUG="$(echo "$REPO_URL" | sed 's|.*github\.com/||; s|\.git$||')"

    local REMOTE_DIR='$HOME/.server-configs'

    if remote_exec "[ -d $REMOTE_DIR/.git ]"; then
        echo "  Repo exists — pulling latest..."
        # Refuse to clobber local changes on the remote. A dirty working
        # tree usually means someone edited a config in place; surface it
        # instead of silently merging or losing work.
        if ! remote_exec "cd $REMOTE_DIR && [ -z \"\$(git status --porcelain)\" ]"; then
            error "Remote $REMOTE_DIR has uncommitted changes"
            echo "    SSH in and resolve them (commit, stash, or revert), then re-run."
            return 1
        fi
        # --ff-only avoids accidental merge commits when remote/local diverge.
        if ! remote_exec "cd $REMOTE_DIR && git pull --ff-only"; then
            error "git pull --ff-only failed on $REMOTE_DIR"
            echo "    The remote branch has diverged. Reconcile manually on the remote."
            return 1
        fi
    else
        echo "  Cloning $REPO_SLUG..."
        if remote_exec "command -v gh &>/dev/null && gh auth status &>/dev/null"; then
            # Prefer gh repo clone (uses gh's own auth)
            if ! remote_exec "cd \$HOME && gh repo clone $REPO_SLUG .server-configs"; then
                error "gh repo clone failed — verify GitHub auth (run 'gh auth login' on the remote)"
                return 1
            fi
        else
            # Fallback to git clone over HTTPS
            if ! remote_exec "git clone $REPO_URL $REMOTE_DIR"; then
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
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    deploy_main "$@"
fi
