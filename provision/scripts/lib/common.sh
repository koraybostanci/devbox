#!/bin/bash

stage() {
    printf '\n--- %s\n' "$1"
}

download_verified() {
    local url="$1" sha256="$2" destination="$3"

    # Stalled-transfer hardening applies to every verified download: abort on
    # a 10s connect failure or a transfer stalled below 1 KiB/s for 30s.
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        --connect-timeout 10 --speed-limit 1024 --speed-time 30 \
        --retry 3 --retry-connrefused --retry-all-errors "$url" -o "$destination"
    if ! printf '%s  %s\n' "$sha256" "$destination" | sha256sum -c - >/dev/null; then
        printf 'ERROR: checksum verification failed for %s\n' "$url" >&2
        return 1
    fi
}

# One copy of the mktemp/download_verified/run/rm ceremony. With no runner
# arguments the artifact is only downloaded and hash-verified; otherwise the
# arguments (a runner plus its flags, e.g. `sh <installer-flags>` or
# `unzip -d "$dir"`) are executed with the verified file appended as the
# final argument, and the temporary file is removed afterwards.
run_pinned_installer() {
    local url="$1" sha256="$2" file run_status=0
    shift 2
    file="$(mktemp)"
    # `|| run_status=1` keeps the failure explicit even inside an `if`
    # condition, where `set -e` is suspended and `rm` below would mask it.
    download_verified "$url" "$sha256" "$file" || run_status=1
    if [ "$run_status" = 0 ] && [ "$#" -gt 0 ]; then
        "$@" "$file" || run_status=1
    fi
    rm -f "$file"
    return "$run_status"
}

# Early-exit guard shared by the version installers: run the version command
# and return 0 only when its stdout answers exactly with `expected`, so a
# converged re-provision skips the download. Like the pre-existing opencode
# and go guards, the check trusts the binary's self-reported version -- the
# same assumption those installers already make, no new weakening. A failing
# command yields no output, so an absent or broken binary behaves like a
# version mismatch and the caller falls back to a full (re)install.
ensure_installed() {
    local expected="${*: -1}"
    set -- "${@:1:$#-1}"
    [ "$("$@")" = "$expected" ]
}

atomic_copy() {
    local source_file="$1" destination="$2" mode="${3:-600}"
    local temporary

    mkdir -p "$(dirname "$destination")"
    temporary="$(mktemp "$(dirname "$destination")/.deploy.XXXXXX")"
    cp "$source_file" "$temporary"
    chmod "$mode" "$temporary"
    mv "$temporary" "$destination"
}

# One copy of the mktemp/write/chmod/mv publish ceremony. With no `--`
# producer arguments, stdin becomes the file at <destination>. With
# `-- <producer> [args...]`, the producer's stdout is staged instead, and a
# failing producer is cleaned up before anything is published. The temporary
# file is created in the destination's own directory so the mv never crosses
# filesystems, and it gets its final mode before the mv so no window exposes
# the content at another permission. The invoking user performs every step,
# so the published file is owned by that user and the caller must never pair
# this helper with sudo or chown across ownership boundaries. With
# --skip-if-same, content identical to the current destination is discarded
# instead of published: the destination keeps its inode and mtime and the
# helper still reports success.
devbox_publish_atomic() {
    local destination="$1" mode="$2" temporary skip_same=0 status=0

    shift 2
    while [ $# -gt 0 ]; do
        case "$1" in
            --skip-if-same) skip_same=1 ;;
            --) shift; break ;;
            *)
                printf 'usage: devbox_publish_atomic <destination> <mode> [--skip-if-same] [-- <producer>...]\n' >&2
                return 2
                ;;
        esac
        shift
    done
    temporary="$(mktemp "$(dirname "$destination")/.devbox-publish.XXXXXX")" || return 1
    if [ $# -eq 0 ]; then
        if ! cat >"$temporary"; then
            rm -f -- "$temporary"
            return 1
        fi
    else
        "$@" >"$temporary" || status=$?
        if [ "$status" -ne 0 ]; then
            rm -f -- "$temporary"
            return "$status"
        fi
    fi
    chmod "$mode" "$temporary"
    if [ "$skip_same" = 1 ] && cmp -s "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 0
    fi
    mv -f "$temporary" "$destination"
}

# The readiness-gate dispatcher shared by verify.sh and its zsh battery:
# print one PASS/FAIL line per named check and count failures in the caller's
# `failures` variable. Failures print on stderr; a failing command's own
# output is discarded.
check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS: %s\n' "$description"
    else
        printf 'FAIL: %s\n' "$description" >&2
        failures=$((failures + 1))
    fi
}
