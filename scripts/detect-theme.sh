#!/usr/bin/env bash
# detect-theme.sh — prints "light" or "dark" based on terminal background.
#
# Fallback chain (first confident answer wins):
#   1. $DOTFILES_THEME if already set to light|dark.
#   2. OSC 11 probe of /dev/tty (interactive shell context only).
#   3. VS Code: storage.json themeBackground (the *actual* rendered bg colour,
#      independent of theme name / high-contrast / sync state).
#   4. Apple Terminal: osascript query of current window's background colour
#      (one-time Automation permission prompt; falls through if denied).
#   5. COLORFGBG (rxvt-style fg;bg).
#   6. Default: dark.
#
# Called from bashrc/zshrc (where step 2 usually wins) and from tmux/vim/nvim
# (where steps 3 and 4 cover the OSC-11-deaf terminals). Single source of truth.
#
# `detect-theme --debug` also prints `detect-theme: step=NAME result=light|dark`
# to stderr, naming which signal won — handy for diagnosing wrong-theme reports.
# `detect-theme --force` skips the env-override (step 1) and tmux-env cache
# (step 2a's first branch) so a stale cached value can't shadow a fresh probe;
# used by `theme auto` and nvim's FocusGained hook.

set -uo pipefail

DEBUG=0
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--debug) DEBUG=1 ;;
        -f|--force) FORCE=1 ;;
        --) shift; break ;;
        *) break ;;
    esac
    shift
done

emit() {
    [ "$DEBUG" = "1" ] && printf 'detect-theme: step=%s result=%s\n' "$1" "$2" >&2
    printf '%s\n' "$2"
    exit 0
}

# tmux unconditionally rewrites TERM_PROGRAM=tmux for shells it spawns. When
# we're called from inside tmux, recover the launching shell's original value
# from tmux's global env so the VS Code / Apple Terminal branches below can
# still tell which terminal we're really in.
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    orig_tp=$(tmux show-environment -g TERM_PROGRAM 2>/dev/null | sed -n 's/^TERM_PROGRAM=//p')
    [ -n "$orig_tp" ] && [ "$orig_tp" != "tmux" ] && TERM_PROGRAM="$orig_tp"
fi

# Print "light" or "dark" if $1 is "#RRGGBB" and return 0; else return 1.
# Rec.601 luminance: 0.299·R + 0.587·G + 0.114·B, threshold at 128 (≈ 0.5),
# computed ×1000 to stay in integer arithmetic.
classify_hex() {
    local hex="${1#\#}"
    [ "${#hex}" -eq 6 ] || return 1
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    if [ "$(( (299*r + 587*g + 114*b) / 1000 ))" -gt 128 ]; then
        echo light
    else
        echo dark
    fi
}

# 1. Explicit override. Skipped under --force (callers like `theme auto`
# and nvim's FocusGained hook need a fresh probe regardless of stale env).
if [ "$FORCE" != "1" ]; then
    case "${DOTFILES_THEME:-}" in
        light|dark) emit env-override "$DOTFILES_THEME" ;;
    esac
fi

# 2a. Inside tmux: ask tmux. First read DOTFILES_THEME from the server's
# global env — populated by `theme light|dark|auto`, by _dotfiles_detect_theme,
# or by a previous run of this script. Faster and more reliable than re-probing,
# and avoids if-shell env-forwarding quirks on tmux < 3.4. Then try #{client_theme}
# (tmux 3.6+ probes OSC 11 on the client tty and caches it). On older tmux the
# format is empty and we fall through to the existing chain.
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    if [ "$FORCE" != "1" ]; then
        cached=$(tmux show-environment -g DOTFILES_THEME 2>/dev/null | sed -n 's/^DOTFILES_THEME=//p')
        case "$cached" in
            light|dark) emit tmux-cache "$cached" ;;
        esac
    fi
    ct=$(tmux display -p '#{client_theme}' 2>/dev/null)
    case "$ct" in
        light|dark)
            tmux set-environment -g DOTFILES_THEME "$ct" 2>/dev/null || true
            emit tmux-client-theme "$ct"
            ;;
    esac
fi

# 2. OSC 11. Skip inside tmux (response is eaten) and when not on a tty
# (we're being called from nvim's vim.fn.system, tmux's if-shell, etc.).
# Poll byte-by-byte up to ~1.5s. xterm.js (VS Code's renderer, incl.
# Remote-SSH) terminates the reply with ST (ESC \); Apple Terminal and
# iTerm2 use BEL. `read -d` only accepts one delimiter, so we loop and
# break on either. Fast terminals exit in milliseconds once the
# terminator arrives; a laggy SSH link gets the full budget — still
# better than missing the answer and defaulting to dark.
#
# Precondition is just `-t 0` (a controlling terminal exists). We
# DON'T also check `-t 1`: when called via command substitution
# `DOTFILES_THEME="$(detect-theme)"` from shell init, stdout is
# a pipe even though /dev/tty is perfectly accessible — checking `-t 1`
# would skip OSC 11 exactly in the load-bearing case. The OSC 11
# block writes to /dev/tty directly and reads via the loop's
# `</dev/tty` redirect, both with `2>/dev/null || true`, so stdout
# being a pipe is irrelevant and a non-existent /dev/tty falls through
# harmlessly. Likewise we don't test `-r /dev/tty` — some sandboxes
# make /dev/tty functional for read/write but report it unreadable.
if [ -z "${TMUX:-}" ] && [ -t 0 ]; then
    printf '\e]11;?\e\\' > /dev/tty 2>/dev/null
    resp=""
    # Redirect /dev/tty into the loop's stdin exactly once for the whole
    # probe. We DON'T use `exec 3</dev/tty` for this — `exec` with only a
    # redirect, in a script, exits the whole shell if open() fails (POSIX
    # 2.14 special-builtin rule), and `2>/dev/null` only swallows the
    # error message, not the exit. Re-opening `< /dev/tty` per iteration
    # was also empirically dropping bytes on at least one VS Code
    # Remote-SSH setup, so neither alternative is acceptable. A compound-
    # command redirect on `while ... done` opens /dev/tty once at loop
    # entry and falls through harmlessly if the open fails.
    i=0
    while [ "$i" -lt 30 ]; do
        i=$((i + 1))
        ch=""
        IFS= read -rs -t 0.1 -n 1 ch 2>/dev/null || true
        if [ -z "$ch" ]; then
            # If nothing has arrived after ~0.5s the terminal isn't going
            # to answer; bail rather than burning the full budget on every
            # shell startup. Once any byte is in resp we keep waiting for
            # the terminator (OSC 11 over SSH delivers ~1 byte per 100ms,
            # so a ~26-byte reply needs the full 30-poll window).
            [ -z "$resp" ] && [ "$i" -ge 5 ] && break
            continue
        fi
        resp="${resp}${ch}"
        if [[ "$resp" =~ rgb:[0-9a-fA-F]+/[0-9a-fA-F]+/[0-9a-fA-F]+ ]]; then
            case "$ch" in
                $'\a') break ;;
                $'\e')
                    # Drain the trailing \ of ST so it doesn't leak into the next read.
                    IFS= read -rs -t 0.05 -n 1 _drain 2>/dev/null || true
                    break
                    ;;
            esac
        fi
    done </dev/tty
    if [[ "$resp" =~ rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+) ]]; then
        rh="${BASH_REMATCH[1]:0:2}"; gh="${BASH_REMATCH[2]:0:2}"; bh="${BASH_REMATCH[3]:0:2}"
        # Pad single-digit channels (rgb:f/f/f form).
        [ "${#rh}" -lt 2 ] && rh="${rh}0"
        [ "${#gh}" -lt 2 ] && gh="${gh}0"
        [ "${#bh}" -lt 2 ] && bh="${bh}0"
        res=$(classify_hex "#${rh}${gh}${bh}") && emit osc11 "$res"
    fi
fi

# 3. VS Code: themeBackground in storage.json is the actual rendered colour,
# regardless of theme name, high-contrast mode, profile, or sync state.
# The .vscode-server[-insiders] paths cover Remote-SSH hosts where the editor
# UI lives on a different machine; the file is only present once VS Code has
# synced state to the remote (some hosts have an empty globalStorage and will
# fall through to the next signal).
if [ "${TERM_PROGRAM:-}" = "vscode" ]; then
    for storage in \
        "$HOME/Library/Application Support/Code/User/globalStorage/storage.json" \
        "$HOME/Library/Application Support/Code - Insiders/User/globalStorage/storage.json" \
        "$HOME/.config/Code/User/globalStorage/storage.json" \
        "$HOME/.config/Code - Insiders/User/globalStorage/storage.json" \
        "$HOME/.vscode-server/data/User/globalStorage/storage.json" \
        "$HOME/.vscode-server-insiders/data/User/globalStorage/storage.json"
    do
        [ -r "$storage" ] || continue
        bg=$(sed -n 's/.*"themeBackground"[[:space:]]*:[[:space:]]*"\(#[0-9a-fA-F]\{6\}\)".*/\1/p' "$storage" | head -n1)
        [ -n "$bg" ] || continue
        res=$(classify_hex "$bg") && emit vscode-storage "$res"
    done
fi

# 4. Apple Terminal: osascript the current window's background. First call
# triggers a one-time Automation permission prompt; subsequent calls are
# fast. Denied permission → silent fall-through to the next signal.
if [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ] && command -v osascript >/dev/null 2>&1; then
    rgb=$(osascript -e 'tell application "Terminal" to get background color of selected tab of front window' 2>/dev/null)
    if [ -n "$rgb" ]; then
        # rgb format: "65535, 65535, 65535" (16-bit per channel)
        read -r r g b < <(printf '%s\n' "$rgb" | awk -F'[,[:space:]]+' '{print int($1/256), int($2/256), int($3/256)}')
        if [ -n "${r:-}" ] && [ -n "${g:-}" ] && [ -n "${b:-}" ]; then
            if [ "$(( (299*r + 587*g + 114*b) / 1000 ))" -gt 128 ]; then
                emit apple-terminal light
            else
                emit apple-terminal dark
            fi
        fi
    fi
fi

# 5. COLORFGBG: rxvt-style "fg;bg".
if [ -n "${COLORFGBG:-}" ]; then
    case "${COLORFGBG##*;}" in
        0|1|2|3|4|5|6|8)         emit colorfgbg dark  ;;
        7|9|10|11|12|13|14|15)   emit colorfgbg light ;;
    esac
fi

# 6. Default — exits non-zero so callers can distinguish a confident detection
# from this fallback (used by nvim's FocusGained hook to avoid flipping
# &background away from a correct value when no signal fired). Stdout still
# prints "dark" for the existing exit-status-blind callers (bashrc_exports,
# nvim's startup detection).
[ "$DEBUG" = "1" ] && printf 'detect-theme: step=default result=dark\n' >&2
printf 'dark\n'
exit 1
