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

# Canonicalize a path without creating anything: walk up to the nearest
# existing ancestor, resolve it physically with cd -P, and re-append the
# remaining components. The final component is resolved too when it already
# exists, including when it is itself a symlink. Canonicalization keeps
# identity comparisons (data root, install root, activation target) from mixing
# logical paths such as macOS $HOME under /var with physical paths under
# /private/var.
canonicalize_path() {
    local path="$1" depth="${2:-0}" suffix="" base parent target directory

    case "$path" in
        /*) ;;
        *) path="$PWD/$path" ;;
    esac
    while [ "${path%/}" != "$path" ] && [ -n "${path#/}" ]; do
        path="${path%/}"
    done

    while [ ! -e "$path" ] && [ ! -L "$path" ]; do
        base="${path##*/}"
        parent="${path%/*}"
        [ -n "$parent" ] || parent="/"
        [ "$base" != "$path" ] || break
        suffix="/$base$suffix"
        path="${parent%/}"
        [ -n "$path" ] || path="/"
    done

    if [ -L "$path" ]; then
        if [ "$depth" -lt 40 ]; then
            target="$(readlink "$path")"
            case "$target" in
                /*) ;;
                *) target="$(dirname "$path")/$target" ;;
            esac
            path="$(canonicalize_path "$target" "$((depth + 1))")"
        fi
    else
        directory="$(dirname "$path")"
        if [ "$directory" != "$path" ]; then
            directory="$(cd -P "$directory" && pwd)"
            if [ "$directory" = "/" ]; then
                path="/$(basename "$path")"
            else
                path="$directory/$(basename "$path")"
            fi
        fi
    fi

    if [ "$path" = "/" ]; then
        printf '/%s\n' "${suffix#/}"
    else
        printf '%s%s\n' "$path" "$suffix"
    fi
}

# Canonical host data root shared by release installs and locks. The launcher
# always reports physical directories (it resolves itself with cd -P), so this
# must be physical too: on macOS a sandbox HOME below /var/folders resolves to
# /private/var/folders, and a logical data root would never match release
# paths reported by the launcher.
devbox_data_root() {
    canonicalize_path "${XDG_DATA_HOME:-$HOME/.local/share}/devbox"
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

    target="$(canonicalize_path "$installed")"
    source_path="$(canonicalize_path "$source_path")"
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
