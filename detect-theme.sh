#!/usr/bin/env bash
# detect-theme.sh — prints "light" or "dark" based on terminal background.
#
# Fallback chain (first confident answer wins):
#   1. $SERVER_CONFIGS_THEME if already set to light|dark.
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

set -uo pipefail

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

# 1. Explicit override.
case "${SERVER_CONFIGS_THEME:-}" in
    light|dark) printf '%s\n' "$SERVER_CONFIGS_THEME"; exit 0 ;;
esac

# 2. OSC 11. Skip inside tmux (response is eaten) and when not on a tty
# (we're being called from nvim's vim.fn.system, tmux's if-shell, etc.).
if [ -z "${TMUX:-}" ] && [ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '\e]11;?\e\\' > /dev/tty 2>/dev/null
    resp=""
    IFS= read -rs -t 0.5 -d $'\a' resp < /dev/tty 2>/dev/null || true
    if [[ "$resp" =~ rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+) ]]; then
        rh="${BASH_REMATCH[1]:0:2}"; gh="${BASH_REMATCH[2]:0:2}"; bh="${BASH_REMATCH[3]:0:2}"
        # Pad single-digit channels (rgb:f/f/f form).
        [ "${#rh}" -lt 2 ] && rh="${rh}0"
        [ "${#gh}" -lt 2 ] && gh="${gh}0"
        [ "${#bh}" -lt 2 ] && bh="${bh}0"
        classify_hex "#${rh}${gh}${bh}" && exit 0
    fi
fi

# 3. VS Code: themeBackground in storage.json is the actual rendered colour,
# regardless of theme name, high-contrast mode, profile, or sync state.
if [ "${TERM_PROGRAM:-}" = "vscode" ]; then
    for storage in \
        "$HOME/Library/Application Support/Code/User/globalStorage/storage.json" \
        "$HOME/Library/Application Support/Code - Insiders/User/globalStorage/storage.json" \
        "$HOME/.config/Code/User/globalStorage/storage.json" \
        "$HOME/.config/Code - Insiders/User/globalStorage/storage.json"
    do
        [ -r "$storage" ] || continue
        bg=$(sed -n 's/.*"themeBackground"[[:space:]]*:[[:space:]]*"\(#[0-9a-fA-F]\{6\}\)".*/\1/p' "$storage" | head -n1)
        [ -n "$bg" ] || continue
        classify_hex "$bg" && exit 0
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
                echo light; exit 0
            else
                echo dark; exit 0
            fi
        fi
    fi
fi

# 5. COLORFGBG: rxvt-style "fg;bg".
if [ -n "${COLORFGBG:-}" ]; then
    case "${COLORFGBG##*;}" in
        0|1|2|3|4|5|6|8)         echo dark;  exit 0 ;;
        7|9|10|11|12|13|14|15)   echo light; exit 0 ;;
    esac
fi

# 6. Default.
echo dark
