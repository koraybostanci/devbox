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

# Dumb argument-shape guard for CLI dispatch. A numeric shape demands exactly
# that many arguments, "+" demands at least one, and any other shape is a
# "|"-separated list of options ("start|stop|status", "|--force") the joined
# arguments must equal verbatim; a leading "|" admits the empty argument
# list. Every rejection dies with the exact documented usage line, so callers
# pass that text verbatim instead of re-deriving it.
require_args() {
    local shape="$1" usage="$2" option matched=1
    shift 2
    case "$shape" in
        +)
            [ "$#" -gt 0 ] || die "Usage: $usage"
            ;;
        [0-9]*)
            [ "$#" -eq "$shape" ] || die "Usage: $usage"
            ;;
        *)
            # Split the alternatives; option words are fixed dispatch shapes,
            # so no glob expansion protection is needed here.
            local IFS='|'
            for option in $shape; do
                [ "$option" = "$*" ] && matched=0
            done
            [ "$matched" = 0 ] || die "Usage: $usage"
            ;;
    esac
}

# Compare two versions as "current is at least minimum". An optional leading
# 'v' and trailing '-suffix' are stripped, then both inputs must be
# dotted-numeric with 1 to 3 components — anything else fails closed and the
# caller dies with its own message. No component ever reaches bash arithmetic
# unvalidated: "(( 10#3-1 ))" subtracts, which is how the old compare
# false-rejected "0.10.3-1" against "0.10.3".
version_at_least() {
    local current="${1#v}" minimum="${2#v}"
    local index current_part minimum_part
    local -a current_parts minimum_parts
    current="${current%%-*}"
    minimum="${minimum%%-*}"
    [[ "$current" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
    [[ "$minimum" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
    local IFS='.'
    read -r -a current_parts <<<"$current"
    read -r -a minimum_parts <<<"$minimum"
    # Missing components count as 0, so "2.10" < "2.10.1".
    for index in 0 1 2; do
        current_part="${current_parts[$index]:-0}"
        minimum_part="${minimum_parts[$index]:-0}"
        [[ "$current_part" =~ ^[0-9]+$ && "$minimum_part" =~ ^[0-9]+$ ]] || return 1
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

# Describe the installed devbox command relative to the launcher source. The
# caller passes the checkout's launcher path and receives three lines on
# stdout — "<installed>", "<installed target>", "<ours>" — where <installed>
# is the PATH entry for `devbox` (empty when it is not on PATH), <installed
# target> is that entry's resolved symlink target (empty when the entry is
# missing or not a symlink), and <ours> is the shared ownership rule as 1
# exactly when the entry is a symlink to the launcher source. A second
# argument evaluates a candidate path instead of the PATH lookup (the
# uninstall fallback to the documented install location). One value per line
# because an empty first field must survive the trip without IFS-style
# leading-delimiter stripping, which would corrupt separator-based records.
devbox_cli_target() {
    local source_path="$1" candidate="${2-}"
    local installed="" installed_target="" source_target ours=0

    source_target="$(resolve_symlink_target "$source_path")"
    if [ -n "$candidate" ]; then
        installed="$candidate"
    else
        installed="$(command -v devbox 2>/dev/null || true)"
    fi
    if [ -n "$installed" ] && [ -L "$installed" ]; then
        installed_target="$(resolve_symlink_target "$installed")"
        if [ "$installed_target" = "$source_target" ]; then
            ours=1
        fi
    fi
    printf '%s\n%s\n%s\n' "$installed" "$installed_target" "$ours"
}

install_cli() {
    local source_path="$1" installed installed_target ours bin_dir target record

    record="$(devbox_cli_target "$source_path")"
    {
        read -r installed
        read -r installed_target
        read -r ours
    } <<<"$record"
    bin_dir="$HOME/.local/bin"
    if [ "$ours" = 1 ]; then
        bin_dir="$(dirname "$installed")"
    elif [ -n "$installed" ]; then
        warn "$installed is not a symlink to this checkout; PATH resolves 'devbox' there instead of $bin_dir/devbox"
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

# Uninstall removes the symlink pointing at this checkout. When `devbox` is
# absent from PATH or not a launcher symlink, the fallback silently re-checks
# the documented install location $HOME/.local/bin/devbox before reporting
# "not installed"; a launcher symlink belonging to another checkout is fatal.
uninstall_cli() {
    local source_path="$1" installed installed_target ours record

    record="$(devbox_cli_target "$source_path")"
    {
        read -r installed
        read -r installed_target
        read -r ours
    } <<<"$record"
    if [ "$ours" != 1 ] && [ -z "$installed_target" ]; then
        record="$(devbox_cli_target "$source_path" "$HOME/.local/bin/devbox")"
        {
            read -r installed
            read -r installed_target
            read -r ours
        } <<<"$record"
    fi
    if [ "$ours" = 1 ]; then
        command rm "$installed"
        log "Removed: $installed"
    elif [ -z "$installed_target" ]; then
        log "devbox is not installed at $installed."
    else
        die "$installed belongs to another checkout: $installed_target"
    fi
}

acquire_lock() {
    local lock_name="$1"
    local lock_path="$DEVBOX_LOCK_DIR/$lock_name"
    local owner_pid="" confirmed_pid=""

    mkdir -p "$DEVBOX_LOCK_DIR"
    if ! mkdir "$lock_path" 2>/dev/null; then
        # A missing, empty, or truncated pid file does not by itself prove the
        # lock is stale: the owner may simply be between the mkdir above and
        # the pid write below, and a failed read must never kill this process
        # before the EXIT trap is armed. Treat an unparseable pid as "unknown"
        # and decide via kill -0, which is the only recovery that works after
        # an owner crash.
        if [ -f "$lock_path/pid" ]; then
            read -r owner_pid <"$lock_path/pid" 2>/dev/null || owner_pid=""
        fi
        if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
            die "another devbox command is running (PID $owner_pid)"
        fi

        warn "removing stale lock $lock_path"
        command rm -rf "$lock_path"
        mkdir "$lock_path" || die "could not acquire lock $lock_path"
    fi

    printf '%s\n' "$$" >"$lock_path/pid"

    # Settle re-verification after the pid write, on BOTH the fresh-mkdir and
    # the stale-recovery path: between our mkdir and our pid write a contender
    # may rm -rf the directory and re-create it with its own pid. This is
    # bounded last-writer-wins, not perfect atomicity: after we write our pid
    # we settle briefly and re-read the file; a contender's pid written after
    # ours wins the read on their side (or ours persists), and the loser's
    # re-read no longer matches and dies here. Do not remove the directory in
    # that case — it no longer belongs to us, and unlinking it would strip
    # the current owner's pid file.
    sleep 0.2
    confirmed_pid=""
    read -r confirmed_pid <"$lock_path/pid" 2>/dev/null || confirmed_pid=""
    if [ "$confirmed_pid" != "$$" ]; then
        die "lock acquisition contended at $lock_path: another command holds it"
    fi

    DEVBOX_ACTIVE_LOCK="$lock_path"
    trap release_lock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

release_lock() {
    if [ -n "${DEVBOX_ACTIVE_LOCK:-}" ]; then
        local recorded_pid=""
        if [ -f "$DEVBOX_ACTIVE_LOCK/pid" ]; then
            read -r recorded_pid <"$DEVBOX_ACTIVE_LOCK/pid" 2>/dev/null ||
                recorded_pid=""
        fi
        # Only delete the directory while it still records our pid. A losing
        # contender may have overwritten the pid file with its own; removing
        # anyway would destroy a live owner's lock and let a third command
        # acquire while the real owner still runs. (Bounded constraint: this
        # identity check is spoofable by overwrite, which is accepted — the
        # point is that a LOSING contender never deletes the shared dir; a
        # genuinely dead owner is recovered by the next acquire's stale path.)
        if [ "$recorded_pid" = "$$" ]; then
            command rm -rf "$DEVBOX_ACTIVE_LOCK"
        else
            warn "not removing lock $DEVBOX_ACTIVE_LOCK: recorded pid ${recorded_pid:-<none>} is not ours ($$)"
        fi
        DEVBOX_ACTIVE_LOCK=""
    fi
    trap - EXIT INT TERM
}
