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

resolve_path() {
    local path="$1"
    local directory

    while [ -L "$path" ]; do
        directory="$(cd -P "$(dirname "$path")" && pwd)"
        path="$(readlink "$path")"
        case "$path" in
            /*) ;;
            *) path="$directory/$path" ;;
        esac
    done

    directory="$(cd -P "$(dirname "$path")" && pwd)"
    printf '%s/%s\n' "$directory" "$(basename "$path")"
}

shell_quote() {
    printf '%q' "$1"
}

# Canonical host data root shared by release installs and locks.
devbox_data_root() {
    printf '%s/devbox\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

choose_install_bin() {
    local candidate

    if command -v devbox >/dev/null 2>&1; then
        candidate="$(dirname "$(command -v devbox)")"
        [ -w "$candidate" ] && printf '%s\n' "$candidate" && return
    fi

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if [ ! -d "$candidate" ] || [ ! -w "$candidate" ]; then
            continue
        fi
        case "$candidate" in
            "$HOME"/*)
                printf '%s\n' "$candidate"
                return
                ;;
        esac
    done < <(printf '%s' "$PATH" | tr ':' '\n')

    printf '%s/.local/bin\n' "$HOME"
}

install_cli() {
    local source_path="$1"
    local bin_dir target

    bin_dir="$(choose_install_bin)"
    target="$bin_dir/devbox"
    mkdir -p "$bin_dir"

    if [ -e "$target" ] && [ ! -L "$target" ]; then
        die "$target exists and is not a symlink"
    fi

    ln -sfn "$source_path" "$target"
    log "Installed: $target -> $source_path"

    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) log "Add $bin_dir to PATH before using devbox from other directories." ;;
    esac
}

uninstall_cli() {
    local source_path="$1"
    local installed target data_root release_current accepted=false

    installed="$(command -v devbox 2>/dev/null || true)"
    [ -n "$installed" ] || {
        log "devbox is not installed on PATH."
        return
    }
    [ -L "$installed" ] || die "$installed is not a symlink; refusing to remove it"

    target="$(resolve_path "$installed")"
    data_root="$(devbox_data_root)"
    release_current="$data_root/current"
    if [ "$target" = "$source_path" ]; then
        accepted=true
    else
        case "$target" in
            "$release_current" | "$release_current"/*) accepted=true ;;
            "$data_root"/releases/*) accepted=true ;;
        esac
    fi
    [ "$accepted" = true ] || die "$installed belongs to another checkout: $target"

    command rm "$installed"
    log "Removed: $installed"

    # Running from a release tree also drops the activation symlink. This
    # command never deletes installed release trees.
    case "$source_path" in
        "$data_root"/releases/*)
            if [ -L "$release_current" ]; then
                command rm "$release_current"
                log "Removed: $release_current"
            fi
            ;;
    esac
}

acquire_lock() {
    local lock_name="$1"
    local lock_path="$DEVBOX_LOCK_DIR/$lock_name"
    local owner_pid=""

    mkdir -p "$DEVBOX_LOCK_DIR"
    if mkdir "$lock_path" 2>/dev/null; then
        printf '%s\n' "$$" >"$lock_path/pid"
        DEVBOX_ACTIVE_LOCK="$lock_path"
        trap release_lock EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        return
    fi

    [ -f "$lock_path/pid" ] && read -r owner_pid <"$lock_path/pid"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        die "another devbox command is running (PID $owner_pid)"
    fi

    warn "removing stale lock $lock_path"
    command rm -rf "$lock_path"
    mkdir "$lock_path" || die "could not acquire lock $lock_path"
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
