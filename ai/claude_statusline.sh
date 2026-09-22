#!/usr/bin/env bash
set -uo pipefail

# Claude Code status-line command. Claude sends one JSON object on stdin.
# Keep this dependency-light: install.sh ensures jq is available before the
# script is linked into ~/.claude/statusline.sh.

append_segment() {
    local target="$1" value="$2" separator="${3:-  ·  }" current
    [ -n "$value" ] || return 0
    current="${!target:-}"
    if [ -n "$current" ]; then
        printf -v "$target" '%s%s%s' "$current" "$separator" "$value"
    else
        printf -v "$target" '%s' "$value"
    fi
}

percent_int() {
    local value="${1%%.*}"
    case "$value" in
        ''|*[!0-9]*) value=0 ;;
    esac
    [ "$value" -gt 100 ] && value=100
    printf '%s' "$value"
}

remaining_percent() {
    local used
    used="$(percent_int "${1:-0}")"
    printf '%s' "$((100 - used))"
}

context_bar() {
    local used filled i bar=""
    used="$(percent_int "${1:-0}")"
    filled="$(((used + 9) / 10))"
    i=0
    while [ "$i" -lt 10 ]; do
        if [ "$i" -lt "$filled" ]; then
            bar="${bar}█"
        else
            bar="${bar}░"
        fi
        i=$((i + 1))
    done
    printf '%s' "$bar"
}

format_duration() {
    local milliseconds="${1%%.*}" seconds hours minutes
    case "$milliseconds" in
        ''|*[!0-9]*) return 0 ;;
    esac
    seconds=$((milliseconds / 1000))
    hours=$((seconds / 3600))
    minutes=$(((seconds % 3600) / 60))
    seconds=$((seconds % 60))
    if [ "$hours" -gt 0 ]; then
        printf '%dh%02dm' "$hours" "$minutes"
    elif [ "$minutes" -gt 0 ]; then
        printf '%dm%02ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

input="$(cat 2>/dev/null || true)"
if ! command -v jq >/dev/null 2>&1 || ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
    printf 'Claude\n'
    exit 0
fi

field_separator=$'\034'
fields="$(printf '%s' "$input" | jq -r '
    def clean: tostring | gsub("\u001c|\r|\n"; " ");
    [
        (.model.display_name // .model.id // "Claude"),
        (.effort_level // .effortLevel // ""),
        (.session_name // .agent.name // ""),
        (.workspace.current_dir // .cwd // ""),
        (.worktree.branch // ""),
        (.pull_request.number // .pull_request // ""),
        (.context_window.used_percentage // ""),
        (.rate_limits.five_hour.used_percentage // ""),
        (.rate_limits.seven_day.used_percentage // ""),
        (.context_window.current_usage.cache_read_input_tokens // .prompt_cache.cache_read_input_tokens // 0),
        (.context_window.current_usage.input_tokens // .prompt_cache.input_tokens // 0),
        (.cost.total_cost_usd // .total_cost_usd // ""),
        (.cost.total_duration_ms // .duration_ms // ""),
        (.cost.total_lines_added // .total_lines_added // ""),
        (.cost.total_lines_removed // .total_lines_removed // "")
    ] | map(clean) | join("\u001c")
' 2>/dev/null)" || fields=""

model="Claude"
effort=""
session_name=""
current_dir=""
branch=""
pull_request=""
context_used=""
five_hour_used=""
seven_day_used=""
cache_read=0
input_tokens=0
cost_usd=""
duration_ms=""
lines_added=""
lines_removed=""
IFS="$field_separator" read -r model effort session_name current_dir branch pull_request \
    context_used five_hour_used seven_day_used cache_read input_tokens cost_usd \
    duration_ms lines_added lines_removed <<<"$fields"

if [ -n "$current_dir" ] && command -v git >/dev/null 2>&1 && \
        git -C "$current_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    [ -n "$branch" ] || branch="$(git -C "$current_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || \
        git -C "$current_dir" rev-parse --short HEAD 2>/dev/null || true)"
    git_state="$(git -C "$current_dir" status --porcelain --untracked-files=no 2>/dev/null || true)"
    [ -n "$git_state" ] && branch="${branch}*"
fi

columns="${COLUMNS:-120}"
case "$columns" in
    ''|*[!0-9]*) columns=120 ;;
esac

reset=""
cyan=""
blue=""
green=""
yellow=""
magenta=""
dim=""
if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    printf -v reset '\033[0m'
    printf -v cyan '\033[36m'
    printf -v blue '\033[34m'
    printf -v green '\033[32m'
    printf -v yellow '\033[33m'
    printf -v magenta '\033[35m'
    printf -v dim '\033[2m'
fi

line_one=""
line_two=""
append_segment line_one "${cyan}${model}${reset}"
[ -n "$effort" ] && append_segment line_one "${dim}effort${reset} ${effort}"

if [ "$columns" -ge 120 ] && [ -n "$session_name" ]; then
    append_segment line_one "${magenta}${session_name}${reset}"
fi
if [ -n "$current_dir" ]; then
    project="${current_dir%/}"
    project="${project##*/}"
    [ -n "$project" ] || project="/"
    append_segment line_one "${blue}${project}${reset}"
fi
[ -n "$branch" ] && append_segment line_one "${green}git:${branch}${reset}"
if [ "$columns" -ge 100 ] && [ -n "$pull_request" ]; then
    append_segment line_one "${magenta}PR #${pull_request}${reset}"
fi

if [ -n "$context_used" ]; then
    context_value="$(percent_int "$context_used")"
    context_color="$green"
    [ "$context_value" -ge 50 ] && context_color="$yellow"
    [ "$context_value" -ge 80 ] && context_color="$magenta"
    append_segment line_two "ctx ${context_color}$(context_bar "$context_value") ${context_value}%${reset}"
else
    append_segment line_two "ctx ${dim}unknown${reset}"
fi
[ -n "$five_hour_used" ] && append_segment line_two "5h $(remaining_percent "$five_hour_used")% left"
[ -n "$seven_day_used" ] && append_segment line_two "7d $(remaining_percent "$seven_day_used")% left"

if [ "$columns" -ge 120 ]; then
    cache_total=$((cache_read + input_tokens))
    if [ "$cache_total" -gt 0 ]; then
        cache_percent=$((cache_read * 100 / cache_total))
        append_segment line_two "cache ${cache_percent}%"
    fi
fi
if [ "$columns" -ge 100 ] && [ -n "$cost_usd" ]; then
    formatted_cost="$(awk -v value="$cost_usd" 'BEGIN { printf "%.2f", value }')"
    append_segment line_two "\$${formatted_cost}"
fi
if [ "$columns" -ge 120 ] && [ -n "$duration_ms" ]; then
    elapsed="$(format_duration "$duration_ms")"
    [ -n "$elapsed" ] && append_segment line_two "$elapsed"
fi
if [ "$columns" -ge 140 ] && { [ -n "$lines_added" ] || [ -n "$lines_removed" ]; }; then
    append_segment line_two "+${lines_added:-0}/-${lines_removed:-0}"
fi

printf '%s\n%s\n' "$line_one" "$line_two"
