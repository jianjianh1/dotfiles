#!/usr/bin/env bash
# Shared by install.sh and uninstall.sh. Callers provide DIR and common.sh.

WRITING_BLOCK_BEGIN='<!-- dotfiles:writing-guidance:start -->'
WRITING_BLOCK_END='<!-- dotfiles:writing-guidance:end -->'

writing_block_counts_valid() {
    local path="$1" begins ends
    begins="$(grep -Fxc "$WRITING_BLOCK_BEGIN" "$path" 2>/dev/null || true)"
    ends="$(grep -Fxc "$WRITING_BLOCK_END" "$path" 2>/dev/null || true)"
    if [ "$begins" -gt 1 ] || [ "$ends" -gt 1 ] || [ "$begins" -ne "$ends" ]; then
        echo "  Invalid writing-guidance markers in $path; leaving it unchanged" >&2
        return 1
    fi
    if [ "$begins" -eq 1 ] && ! awk -v begin="$WRITING_BLOCK_BEGIN" -v end="$WRITING_BLOCK_END" '
        $0 == begin { begin_line = NR }
        $0 == end { end_line = NR }
        END { exit !(begin_line < end_line) }
    ' "$path"; then
        echo "  Misordered writing-guidance markers in $path; leaving it unchanged" >&2
        return 1
    fi
}

writing_block_without_guidance() {
    local path="$1"
    awk -v begin="$WRITING_BLOCK_BEGIN" -v end="$WRITING_BLOCK_END" '
        $0 == begin { inside = 1; next }
        $0 == end { inside = 0; next }
        !inside { print }
    ' "$path"
}

install_codex_writing_file() {
    local path="$1" source="$DIR/ai/writing-guidance.md" temp

    if [ -L "$path" ]; then
        if [ "$(portable_realpath "$path" 2>/dev/null || true)" = "$(portable_realpath "$source")" ]; then
            manifest_add_path "$path" || return 1
            return 0
        fi
        if [ ! -f "$path" ]; then
            echo "  $path is a broken or non-file link; cannot add writing guidance" >&2
            return 1
        fi
        temp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
        if ! cp "$path" "$temp" || ! _backup_existing "$source" "$path" link; then
            rm -f "$temp"
            return 1
        fi
        if ! mv "$temp" "$path"; then
            mv "${path}.bak" "$path" 2>/dev/null || true
            rm -f "$temp"
            return 1
        fi
    elif [ ! -e "$path" ]; then
        backup_and_link "$source" "$path" || return 1
        manifest_add_path "$path" || return 1
        return 0
    fi
    if [ ! -f "$path" ]; then
        echo "  $path is not a regular file; cannot add writing guidance" >&2
        return 1
    fi
    writing_block_counts_valid "$path" || return 1
    temp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
    if ! writing_block_without_guidance "$path" > "$temp"; then
        rm -f "$temp"
        return 1
    fi
    printf '%s\n' "$WRITING_BLOCK_BEGIN" >> "$temp"
    cat "$source" >> "$temp" || { rm -f "$temp"; return 1; }
    printf '%s\n' "$WRITING_BLOCK_END" >> "$temp"
    if ! cat "$temp" > "$path"; then
        rm -f "$temp"
        return 1
    fi
    rm -f "$temp"
    echo "  Updated writing guidance in $path"
}

remove_codex_writing_file() {
    local path="$1" temp
    [ -f "$path" ] && [ ! -L "$path" ] || return 0
    writing_block_counts_valid "$path" || return 1
    grep -Fqx "$WRITING_BLOCK_BEGIN" "$path" || return 0
    temp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
    if ! writing_block_without_guidance "$path" > "$temp"; then
        rm -f "$temp"
        return 1
    fi
    if ! cat "$temp" > "$path"; then
        rm -f "$temp"
        return 1
    fi
    rm -f "$temp"
    echo "  Removed writing guidance from $path"
    if [ -L "${path}.bak" ] && cmp -s "$path" "${path}.bak"; then
        rm -f "$path" || return 1
        mv "${path}.bak" "$path" || return 1
        echo "  Restored original link at $path"
    fi
}
