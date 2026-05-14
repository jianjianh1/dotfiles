# shellcheck shell=bash
# Full-screen TUI helpers for deploy.sh. Provides an alt-screen window with a
# top banner that updates per phase, plus a status panel that drives a row
# per deploy step with a spinner while it runs.
#
# All helpers degrade to no-ops when stdout isn't a tty, tput can't drive
# the terminal, NO_TUI=1, or NO_ALT_SCREEN=1 — so the caller can sprinkle
# tui_* calls unconditionally.

if [ "${_SERVER_CONFIGS_TUI_SH:-}" = 1 ]; then
    return 0
fi
_SERVER_CONFIGS_TUI_SH=1

TUI_WINDOW_ACTIVE=0
TUI_SPIN_PID=""
TUI_STEPS=()
TUI_STEP_STATES=()
TUI_STEP_ROW0=0
TUI_FAILURE_LOG_NAMES=()
TUI_FAILURE_LOGS=()
TUI_BANNER_HEIGHT=3

TUI_SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

tui_window_supported() {
    [ "${NO_TUI:-0}" != 1 ] && [ "${NO_ALT_SCREEN:-0}" != 1 ] \
        && [ -t 1 ] && [ -n "${TERM:-}" ] \
        && tput cup 0 0 >/dev/null 2>&1
}

tui_window_enter() {
    tui_window_supported || return 1
    tput smcup 2>/dev/null || return 1
    clear
    TUI_WINDOW_ACTIVE=1
}

# Idempotent — safe to call from EXIT trap even if enter never succeeded.
tui_window_exit() {
    [ "$TUI_WINDOW_ACTIVE" = 1 ] || return 0
    tui_spin_stop
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
    TUI_WINDOW_ACTIVE=0
    local i log
    for i in "${!TUI_FAILURE_LOG_NAMES[@]}"; do
        log="${TUI_FAILURE_LOGS[$i]}"
        if [ -s "$log" ]; then
            printf "\n--- %s (failure log) ---\n" "${TUI_FAILURE_LOG_NAMES[$i]}"
            cat "$log" 2>/dev/null
        fi
        rm -f "$log"
    done
    TUI_FAILURE_LOG_NAMES=()
    TUI_FAILURE_LOGS=()
}

# tui_banner TITLE [SUBTITLE] — clears the alt-screen and redraws a single
# boxed header at the top. Cursor lands below the banner.
tui_banner() {
    [ "$TUI_WINDOW_ACTIVE" = 1 ] || return 0
    local title="$1" sub="${2:-}" cols
    cols="$(tput cols 2>/dev/null || echo 60)"
    clear
    if command -v gum >/dev/null 2>&1; then
        local lines=("$title")
        [ -n "$sub" ] && lines+=("$sub")
        gum style --border rounded --padding "0 1" --width $((cols - 4)) \
            --foreground 212 "${lines[@]}" 2>/dev/null || _tui_banner_ascii "$title" "$sub" "$cols"
    else
        _tui_banner_ascii "$title" "$sub" "$cols"
    fi
    tput cup "$TUI_BANNER_HEIGHT" 0
}

_tui_banner_ascii() {
    local title="$1" sub="$2" cols="$3" inner=$(($3 - 4))
    local bar="" k
    for ((k = 0; k < cols - 2; k++)); do bar+="─"; done
    if [ -n "$sub" ]; then
        printf "┌%s┐\n│ %-*s │\n│ %-*s │\n└%s┘\n" \
            "$bar" "$inner" "$title" "$inner" "$sub" "$bar"
    else
        printf "┌%s┐\n│ %-*s │\n└%s┘\n" "$bar" "$inner" "$title" "$bar"
    fi
}

# tui_status_init NAME1 NAME2 ... — register step names and anchor the panel
# one row below the banner (one blank line of spacing).
tui_status_init() {
    [ "$TUI_WINDOW_ACTIVE" = 1 ] || return 0
    TUI_STEPS=("$@")
    TUI_STEP_STATES=()
    local i
    for i in "${!TUI_STEPS[@]}"; do
        TUI_STEP_STATES[$i]="pending"
    done
    TUI_STEP_ROW0=$((TUI_BANNER_HEIGHT + 1))
    tui_status_draw
}

tui_status_draw_row() {
    [ "$TUI_WINDOW_ACTIVE" = 1 ] || return 0
    local i="$1"
    local state="${TUI_STEP_STATES[$i]}" icon color
    case "$state" in
        done)    icon="✓"; color=$'\e[32m' ;;
        running) icon="${TUI_SPIN_FRAMES[0]}"; color=$'\e[33m' ;;
        failed)  icon="✗"; color=$'\e[31m' ;;
        *)       icon="·"; color=$'\e[2m' ;;
    esac
    tput cup $((TUI_STEP_ROW0 + i)) 0
    tput el
    printf "  %s%s\e[0m %s" "$color" "$icon" "${TUI_STEPS[$i]}"
}

tui_status_draw() {
    [ "$TUI_WINDOW_ACTIVE" = 1 ] || return 0
    tput sc
    local i
    for i in "${!TUI_STEPS[@]}"; do tui_status_draw_row "$i"; done
    tput rc
}

tui_spin_start() {
    [ "$TUI_WINDOW_ACTIVE" = 1 ] || return 0
    local row="$1"
    tui_spin_stop
    # Hide the terminal cursor while the spinner is animating so it doesn't
    # jump around alongside the spinner frame. tui_spin_stop restores it.
    tput civis 2>/dev/null || true
    (
        local n=${#TUI_SPIN_FRAMES[@]} i=0
        while :; do
            tput cup "$row" 2 2>/dev/null
            printf "\e[33m%s\e[0m" "${TUI_SPIN_FRAMES[$i]}"
            sleep 0.1
            i=$(((i + 1) % n))
        done
    ) &
    TUI_SPIN_PID=$!
    disown "$TUI_SPIN_PID" 2>/dev/null || true
}

tui_spin_stop() {
    [ -n "$TUI_SPIN_PID" ] || return 0
    kill "$TUI_SPIN_PID" 2>/dev/null || true
    wait "$TUI_SPIN_PID" 2>/dev/null || true
    TUI_SPIN_PID=""
    tput cnorm 2>/dev/null || true
}

# tui_status_run INDEX NAME CMD [ARGS...] — animate the row for INDEX while
# CMD runs (output captured to a tempfile). On failure, the tempfile is
# retained so tui_window_exit can flush it to the user's scrollback after
# rmcup. Returns CMD's exit code.
tui_status_run() {
    local idx="$1" name="$2"; shift 2
    if [ "$TUI_WINDOW_ACTIVE" != 1 ]; then
        "$@"
        return $?
    fi
    local log
    log="$(mktemp "${TMPDIR:-/tmp}/deploy.step.$$.XXXXXX")"
    TUI_STEP_STATES[$idx]="running"
    tui_status_draw_row "$idx"
    tui_spin_start $((TUI_STEP_ROW0 + idx))
    local rc=0
    "$@" >"$log" 2>&1 || rc=$?
    tui_spin_stop
    if [ "$rc" -eq 0 ]; then
        TUI_STEP_STATES[$idx]="done"
        rm -f "$log"
    else
        TUI_STEP_STATES[$idx]="failed"
        TUI_FAILURE_LOG_NAMES+=("$name")
        TUI_FAILURE_LOGS+=("$log")
    fi
    tui_status_draw_row "$idx"
    return "$rc"
}

# ----- Bash-native arrow-key menus -------------------------------------------
#
# Used when gum isn't available. Render to stderr, return the result on
# stdout. Bash 3.2 compatible: arrow detection uses `read -rsn2 -t 1` (the
# smallest integer timeout 3.2 accepts), so plain Esc has up to a 1-second
# delay before it's treated as cancel — `q` / `Q` is the documented instant
# cancel.

# _tui_read_key — one keystroke → mnemonic ("up" / "down" / "left" / "right"
# / "enter" / "space" / "quit") or the raw char.
_tui_read_key() {
    local k rest
    IFS= read -rsn1 k </dev/tty || return 1
    case "$k" in
        $'\e')
            IFS= read -rsn2 -t 1 rest </dev/tty 2>/dev/null || rest=""
            case "$rest" in
                '[A') printf "up" ;;
                '[B') printf "down" ;;
                '[C') printf "right" ;;
                '[D') printf "left" ;;
                *)    printf "quit" ;;
            esac
            ;;
        "")  printf "enter" ;;
        " ") printf "space" ;;
        q|Q) printf "quit" ;;
        *)   printf "%s" "$k" ;;
    esac
}

# _tui_arrow_choose HEADER OPT1 OPT2 … — single-select. Exit 1 = cancelled.
_tui_arrow_choose() {
    local header="$1"; shift
    local options=("$@") n=$# sel=0 i k
    [ "$n" -gt 0 ] || return 1

    tput civis 2>/dev/null || true
    printf "%s\n" "$header" >&2
    for ((i = 0; i < n; i++)); do printf "\n" >&2; done

    while :; do
        printf "\e[%dA" "$n" >&2
        for ((i = 0; i < n; i++)); do
            if [ "$i" -eq "$sel" ]; then
                printf "\e[K\e[36m> %s\e[0m\n" "${options[$i]}" >&2
            else
                printf "\e[K  %s\n" "${options[$i]}" >&2
            fi
        done
        k="$(_tui_read_key)"
        case "$k" in
            up)    sel=$(( (sel - 1 + n) % n )) ;;
            down)  sel=$(( (sel + 1) % n )) ;;
            enter) break ;;
            quit)  tput cnorm 2>/dev/null || true; return 1 ;;
        esac
    done
    tput cnorm 2>/dev/null || true
    printf "%s" "${options[$sel]}"
}

# _tui_arrow_multi HEADER PRESELECTED_CSV OPT1 OPT2 … — multi-select.
# Space toggles, Enter confirms. Exit 1 = cancelled.
_tui_arrow_multi() {
    local header="$1" preselected="$2"; shift 2
    local options=("$@") n=$# sel=0 i k
    [ "$n" -gt 0 ] || return 1
    local picked=()
    for ((i = 0; i < n; i++)); do picked[$i]=0; done
    local IFSorig="$IFS" item
    IFS=,
    for item in $preselected; do
        for ((i = 0; i < n; i++)); do
            [ "${options[$i]}" = "$item" ] && picked[$i]=1
        done
    done
    IFS="$IFSorig"

    tput civis 2>/dev/null || true
    printf "%s\n" "$header" >&2
    printf "  (Up/Down to move, Space to toggle, Enter to confirm, q to cancel)\n" >&2
    for ((i = 0; i < n; i++)); do printf "\n" >&2; done

    while :; do
        printf "\e[%dA" "$n" >&2
        for ((i = 0; i < n; i++)); do
            local mark="[ ]"; [ "${picked[$i]}" = 1 ] && mark="[x]"
            if [ "$i" -eq "$sel" ]; then
                printf "\e[K\e[36m> %s %s\e[0m\n" "$mark" "${options[$i]}" >&2
            else
                printf "\e[K  %s %s\n" "$mark" "${options[$i]}" >&2
            fi
        done
        k="$(_tui_read_key)"
        case "$k" in
            up)    sel=$(( (sel - 1 + n) % n )) ;;
            down)  sel=$(( (sel + 1) % n )) ;;
            space) picked[$sel]=$(( 1 - picked[$sel] )) ;;
            enter) break ;;
            quit)  tput cnorm 2>/dev/null || true; return 1 ;;
        esac
    done
    tput cnorm 2>/dev/null || true
    for ((i = 0; i < n; i++)); do
        [ "${picked[$i]}" = 1 ] && printf "%s\n" "${options[$i]}"
    done
}
