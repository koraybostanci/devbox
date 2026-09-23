#!/bin/bash

set -Eeuo pipefail

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

version_at_least() {
    local current="$1"
    local minimum="$2"
    local current_part minimum_part index
    local IFS=.
    local -a current_parts minimum_parts

    read -r -a current_parts <<<"$current"
    read -r -a minimum_parts <<<"$minimum"
    for index in 0 1 2; do
        current_part="${current_parts[$index]:-0}"
        minimum_part="${minimum_parts[$index]:-0}"
        ((10#$current_part > 10#$minimum_part)) && return 0
        ((10#$current_part < 10#$minimum_part)) && return 1
    done
    return 0
}

file_mode() {
    if [ "$(uname -s)" = Darwin ]; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

shell_quote() {
    printf '%q' "$1"
}

# Follow a symlink chain to its final target without requiring the path to
# exist. Used for checkout and configuration symlinks.
resolve_symlink_target() {
    local path="$1" depth=0 target

    while [ -L "$path" ] && [ "$depth" -lt 40 ]; do
        target="$(readlink "$path")"
        case "$target" in
            /*) ;;
            *) target="$(dirname "$path")/$target" ;;
        esac
        path="$target"
        depth=$((depth + 1))
    done
    printf '%s\n' "$path"
}

install_cli() {
    local source_path="$1"
    local bin_dir target installed installed_target source_target

    bin_dir="$HOME/.local/bin"
    installed="$(command -v devbox 2>/dev/null || true)"
    source_target="$(resolve_symlink_target "$source_path")"
    if [ -n "$installed" ] && [ -L "$installed" ]; then
        installed_target="$(resolve_symlink_target "$installed")"
        [ "$installed_target" = "$source_target" ] && bin_dir="$(dirname "$installed")"
    fi
    target="$bin_dir/devbox"
    mkdir -p "$bin_dir"

    if [ -e "$target" ] && [ ! -L "$target" ]; then
        die "$target exists and is not a symlink"
    fi

    ln -sfn "$source_path" "$target"
    log "Installed: $target -> $source_path"

    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *)
            log "Add $bin_dir to PATH before using devbox from other directories:"
            log "    export PATH=\"$bin_dir:\$PATH\""
            ;;
    esac
}

uninstall_cli() {
    local source_path="$1" installed target

    installed="$(command -v devbox 2>/dev/null || true)"
    if [ -z "$installed" ] || [ ! -L "$installed" ]; then
        installed="$HOME/.local/bin/devbox"
    fi
    [ -L "$installed" ] || {
        log "devbox is not installed at $installed."
        return
    }

    target="$(resolve_symlink_target "$installed")"
    source_path="$(resolve_symlink_target "$source_path")"
    [ "$target" = "$source_path" ] ||
        die "$installed belongs to another checkout: $target"

    command rm "$installed"
    log "Removed: $installed"
}

acquire_lock() {
    local lock_name="$1"
    local lock_path="$DEVBOX_LOCK_DIR/$lock_name"
    local owner_pid=""

    mkdir -p "$DEVBOX_LOCK_DIR"
    if ! mkdir "$lock_path" 2>/dev/null; then
        [ -f "$lock_path/pid" ] && read -r owner_pid <"$lock_path/pid"
        if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
            die "another devbox command is running (PID $owner_pid)"
        fi

        warn "removing stale lock $lock_path"
        command rm -rf "$lock_path"
        mkdir "$lock_path" || die "could not acquire lock $lock_path"
    fi

    printf '%s\n' "$$" >"$lock_path/pid"
    DEVBOX_ACTIVE_LOCK="$lock_path"
    trap release_lock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

release_lock() {
    if [ -n "${DEVBOX_ACTIVE_LOCK:-}" ]; then
        command rm -rf "$DEVBOX_ACTIVE_LOCK"
        DEVBOX_ACTIVE_LOCK=""
    fi
    trap - EXIT INT TERM
}
