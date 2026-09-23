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
# exist. Used before atomically replacing a file the user may have symlinked
# (for example ~/.ssh/config in a dotfiles setup).
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

choose_install_bin() {
    local candidate

    # Keep using an existing devbox location when it is writable, so repeat
    # installs are stable.
    if command -v devbox >/dev/null 2>&1; then
        candidate="$(dirname "$(command -v devbox)")"
        [ -w "$candidate" ] && printf '%s\n' "$candidate" && return
    fi

    # Prefer a conventional user bin directory that is already on PATH, so the
    # command works in the current shell; otherwise fall back to ~/.local/bin
    # and let ensure_devbox_path update the login shell.
    case ":$PATH:" in
        *":$HOME/.local/bin:"*)
            printf '%s/.local/bin\n' "$HOME"
            return
            ;;
    esac
    if [ -d "$HOME/bin" ] && [ -w "$HOME/bin" ]; then
        case ":$PATH:" in
            *":$HOME/bin:"*)
                printf '%s/bin\n' "$HOME"
                return
                ;;
        esac
    fi
    printf '%s/.local/bin\n' "$HOME"
}

# Login-shell rc that should receive the PATH entry, when one can be
# determined.
devbox_shell_rc() {
    case "${SHELL:-}" in
        */zsh) printf '%s/.zshrc\n' "$HOME" ;;
        */bash) printf '%s/.bash_profile\n' "$HOME" ;;
        *) return 1 ;;
    esac
}

# Make `devbox` resolvable in new shells by adding the install directory to
# PATH through a marked block in the login shell rc. Returns nonzero when the
# rc cannot be updated; the caller then prints the line to add by hand.
ensure_devbox_path() {
    local bin_dir="$1" rc rc_dir temporary rc_mode

    case ":$PATH:" in
        *":$bin_dir:"*) return 0 ;;
    esac
    case "$bin_dir" in
        *'"'* | *'$'* | *'`'* | *'\'*) return 1 ;;
    esac
    rc="$(devbox_shell_rc)" || return 1
    rc_dir="$(dirname "$rc")"
    [ -d "$rc_dir" ] && [ ! -L "$rc" ] || return 1
    temporary="$(mktemp "$rc_dir/.devbox-rc.XXXXXX")" || return 1
    if [ -e "$rc" ]; then
        rc_mode="$(file_mode "$rc")" || {
            command rm -f "$temporary"
            return 1
        }
        awk -v bin_dir="$bin_dir" '
            /^# BEGIN devbox[[:space:]]*$/ {
                if (inside) bad = 1
                inside = 1
                if (!inserted) {
                    print "# BEGIN devbox"
                    print "export PATH=\"" bin_dir ":$PATH\""
                    print "# END devbox"
                    inserted = 1
                }
                next
            }
            /^# END devbox[[:space:]]*$/ {
                if (!inside) bad = 1
                inside = 0
                next
            }
            inside { next }
            { print }
            END {
                if (inside) bad = 1
                if (bad) exit 1
                if (!inserted) {
                    print "# BEGIN devbox"
                    print "export PATH=\"" bin_dir ":$PATH\""
                    print "# END devbox"
                }
            }
        ' "$rc" >"$temporary" || {
            command rm -f "$temporary"
            return 1
        }
    else
        rc_mode=644
        {
            printf '%s\n' "# BEGIN devbox"
            printf 'export PATH="%s:$PATH"\n' "$bin_dir"
            printf '%s\n' "# END devbox"
        } >"$temporary" || {
            command rm -f "$temporary"
            return 1
        }
    fi
    chmod "$rc_mode" "$temporary" || {
        command rm -f "$temporary"
        return 1
    }
    mv "$temporary" "$rc" || {
        command rm -f "$temporary"
        return 1
    }
    log "Added $bin_dir to PATH in $rc; open a new shell to use devbox."
}

# Remove the devbox PATH block written by ensure_devbox_path.
remove_devbox_path() {
    local rc rc_dir temporary rc_mode

    rc="$(devbox_shell_rc)" || return 0
    [ -f "$rc" ] && [ ! -L "$rc" ] || return 0
    grep -qE '^# BEGIN devbox[[:space:]]*$' "$rc" || return 0
    rc_dir="$(dirname "$rc")"
    temporary="$(mktemp "$rc_dir/.devbox-rc.XXXXXX")" || return 0
    rc_mode="$(file_mode "$rc")" || {
        command rm -f "$temporary"
        return 0
    }
    awk '
        /^# BEGIN devbox[[:space:]]*$/ {
            if (inside) bad = 1
            inside = 1
            next
        }
        /^# END devbox[[:space:]]*$/ {
            if (!inside) bad = 1
            inside = 0
            next
        }
        inside { next }
        { print }
        END {
            if (inside) bad = 1
            if (bad) exit 1
        }
    ' "$rc" >"$temporary" || {
        command rm -f "$temporary"
        return 0
    }
    chmod "$rc_mode" "$temporary" || {
        command rm -f "$temporary"
        return 0
    }
    mv "$temporary" "$rc" || {
        command rm -f "$temporary"
        return 0
    }
    log "Removed the devbox PATH entry from $rc."
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

    if ! ensure_devbox_path "$bin_dir"; then
        log "Add $bin_dir to PATH before using devbox from other directories:"
        log "    export PATH=\"$bin_dir:\$PATH\""
    fi
}

uninstall_cli() {
    local source_path="$1" installed target

    installed="$(command -v devbox 2>/dev/null || true)"
    [ -n "$installed" ] || {
        log "devbox is not installed on PATH."
        remove_devbox_path
        return
    }
    [ -L "$installed" ] || die "$installed is not a symlink; refusing to remove it"

    target="$(resolve_symlink_target "$installed")"
    source_path="$(resolve_symlink_target "$source_path")"
    [ "$target" = "$source_path" ] ||
        die "$installed belongs to another checkout: $target"

    command rm "$installed"
    log "Removed: $installed"
    remove_devbox_path
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
