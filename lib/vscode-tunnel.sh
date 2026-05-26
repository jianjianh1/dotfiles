# shellcheck shell=bash
# vscode-tunnel: subcommand router around `code tunnel`. Sourced by both
# bashrc_aliases and zshrc_aliases — POSIX-ish so bash 3.2 (macOS) and zsh
# both load it. Linted by .githooks/pre-commit via the lib/*.sh glob.

if [ "${_DOTFILES_VSCODE_TUNNEL_SH:-}" = 1 ]; then
    return 0 2>/dev/null || true
fi
_DOTFILES_VSCODE_TUNNEL_SH=1

# Enforce lowercase to dodge VS Code's case-insensitive duplicate footgun:
# `MyHost` and `myhost` register as separate tunnels but route ambiguously.
_vscode_tunnel_valid_name() {
    local n="${1:-}"
    local len=${#n}
    [ "$len" -ge 3 ] && [ "$len" -le 20 ] || return 1
    case "$n" in
        [a-z0-9]*) ;;
        *) return 1 ;;
    esac
    case "$n" in
        *[!a-z0-9-]*) return 1 ;;
    esac
    return 0
}

# Aggressive sanitization for the hostname-derived default. Explicit user
# input goes through _vscode_tunnel_normalize_user_name instead so we never
# silently rewrite a name the user typed.
_vscode_tunnel_sanitize_name() {
    printf '%s' "${1:-}" \
        | LC_ALL=C tr 'A-Z' 'a-z' \
        | LC_ALL=C tr -c 'a-z0-9-\n' '-' \
        | LC_ALL=C sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' \
        | cut -c1-20
}

_vscode_tunnel_lowercase() {
    printf '%s' "${1:-}" | LC_ALL=C tr 'A-Z' 'a-z'
}

# Lowercase $1 and validate strictly. On stdout: the normalized name. On
# stderr: a one-line lowercase warning if the input changed; a validation
# error and non-zero exit if it doesn't match the regex. $2 is a short
# label (e.g. "tunnel name", "new name") used in messages.
_vscode_tunnel_normalize_user_name() {
    local raw="${1:-}"
    local label="${2:-tunnel name}"
    local norm
    norm="$(_vscode_tunnel_lowercase "$raw")"
    if [ "$norm" != "$raw" ]; then
        echo "vscode-tunnel: lowercased $label '$raw' -> '$norm' (VS Code tunnel names are case-insensitive)" >&2
    fi
    if ! _vscode_tunnel_valid_name "$norm"; then
        echo "vscode-tunnel: invalid $label '$raw'" >&2
        echo "  (need 3-20 chars, [a-z0-9-], starting alnum)" >&2
        return 1
    fi
    printf '%s' "$norm"
}

# Percent-encode path bytes for vscode.dev URLs. The ASCII whitelist covers
# real-world paths; non-ASCII bytes are %XX-encoded — RFC 3986 correct.
_vscode_tunnel_urlencode() {
    local s="${1:-}"
    local out=""
    local i=0
    local len=${#s}
    local c
    while [ "$i" -lt "$len" ]; do
        c="${s:$i:1}"
        case "$c" in
            [A-Za-z0-9._~/-]) out="$out$c" ;;
            *) out="$out$(printf '%%%02X' "'$c")" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

_vscode_tunnel_resolve_dir() {
    local d="${1:-}"
    [ -n "$d" ] || { echo "vscode-tunnel: empty directory argument" >&2; return 1; }
    ( cd "$d" 2>/dev/null && pwd ) || {
        echo "vscode-tunnel: not a directory or unreadable: $d" >&2
        return 1
    }
}

_vscode_tunnel_usage() {
    cat >&2 <<'EOF'
vscode-tunnel — manage `code tunnel` on this host.

Usage:
  vscode-tunnel [start] [<dir>] [-n NAME]   Start tunnel (default).
  vscode-tunnel url   [<dir>] [-n NAME]     Print vscode.dev URL only.
  vscode-tunnel status                      Show tunnel status.
  vscode-tunnel stop | kill                 Kill the running tunnel.
  vscode-tunnel restart                     Restart the running tunnel.
  vscode-tunnel rename <new-name>           Rename registered tunnel.
  vscode-tunnel unregister                  Unregister this tunnel.
  vscode-tunnel login [--provider P]        Login (github | microsoft).
  vscode-tunnel logout                      Logout of the tunnel account.
  vscode-tunnel whoami                      Show the logged-in account.
  vscode-tunnel service <install|uninstall|log>
                                            Manage the background service.
  vscode-tunnel -h | --help                 This help.

Notes:
  * NAME defaults to the short hostname, lowercased and sanitized.
  * <dir> can be passed without `start`, e.g. `vscode-tunnel ~/proj`.
  * URLs are always printed; deep-link if <dir> was given.
EOF
}

_vscode_tunnel_is_subcmd() {
    case "${1:-}" in
        start|url|status|stop|kill|restart|rename|unregister|login|logout|whoami|service|help|-h|--help)
            return 0 ;;
    esac
    return 1
}

vscode-tunnel() {
    command -v code >/dev/null 2>&1 || {
        echo "vscode-tunnel: code CLI not installed (run install.sh)" >&2
        return 1
    }

    local sub="start"
    if _vscode_tunnel_is_subcmd "${1:-}"; then
        sub="$1"
        shift
    fi

    if [ "$sub" = help ] || [ "$sub" = -h ] || [ "$sub" = --help ]; then
        _vscode_tunnel_usage
        return 0
    fi

    local name=""
    local positional=""
    local provider=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--name)
                [ $# -ge 2 ] || { echo "vscode-tunnel: $1 needs an argument" >&2; return 2; }
                name="$2"
                shift 2
                ;;
            --provider)
                [ $# -ge 2 ] || { echo "vscode-tunnel: --provider needs an argument" >&2; return 2; }
                provider="$2"
                shift 2
                ;;
            -h|--help)
                _vscode_tunnel_usage
                return 0
                ;;
            -*)
                echo "vscode-tunnel: unknown flag: $1" >&2
                _vscode_tunnel_usage
                return 2
                ;;
            *)
                if [ -n "$positional" ]; then
                    echo "vscode-tunnel: unexpected extra argument: $1" >&2
                    _vscode_tunnel_usage
                    return 2
                fi
                positional="$1"
                shift
                ;;
        esac
    done

    case "$sub" in
        start|url)
            local resolved_name=""
            if [ -n "$name" ]; then
                resolved_name="$(_vscode_tunnel_normalize_user_name "$name" "tunnel name")" || return 1
            else
                local raw_name
                raw_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo '')"
                resolved_name="$(_vscode_tunnel_sanitize_name "$raw_name")"
                if ! _vscode_tunnel_valid_name "$resolved_name"; then
                    echo "vscode-tunnel: cannot derive a valid tunnel name from hostname '$raw_name'" >&2
                    echo "  (need 3-20 chars, [a-z0-9-], starting alnum)" >&2
                    echo "  Pass one explicitly: vscode-tunnel -n NAME" >&2
                    return 1
                fi
            fi
            local url="https://vscode.dev/tunnel/$resolved_name"
            if [ -n "$positional" ]; then
                local abs
                abs="$(_vscode_tunnel_resolve_dir "$positional")" || return 1
                url="$url$(_vscode_tunnel_urlencode "$abs")"
            fi
            echo "Open in browser: $url"
            [ "$sub" = url ] && return 0
            command code tunnel --name "$resolved_name" --accept-server-license-terms
            ;;
        status)
            command code tunnel status
            ;;
        stop|kill)
            command code tunnel kill
            ;;
        restart)
            command code tunnel restart
            ;;
        rename)
            [ -n "$positional" ] || { echo "vscode-tunnel: rename needs <new-name>" >&2; return 2; }
            local new_name
            new_name="$(_vscode_tunnel_normalize_user_name "$positional" "new name")" || return 1
            command code tunnel rename "$new_name"
            ;;
        unregister)
            command code tunnel unregister
            ;;
        login)
            if [ -n "$provider" ]; then
                case "$provider" in
                    github|microsoft) ;;
                    *) echo "vscode-tunnel: --provider must be github|microsoft" >&2; return 2 ;;
                esac
                command code tunnel user login --provider "$provider"
            else
                command code tunnel user login
            fi
            ;;
        logout)
            command code tunnel user logout
            ;;
        whoami)
            command code tunnel user show
            ;;
        service)
            case "$positional" in
                install|uninstall|log)
                    command code tunnel service "$positional"
                    ;;
                "")
                    echo "vscode-tunnel: service needs <install|uninstall|log>" >&2
                    return 2
                    ;;
                *)
                    echo "vscode-tunnel: unknown service action: $positional" >&2
                    return 2
                    ;;
            esac
            ;;
        *)
            _vscode_tunnel_usage
            return 2
            ;;
    esac
}
