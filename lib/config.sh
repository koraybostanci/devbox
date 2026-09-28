#!/bin/bash

MINIMUM_COLIMA_VERSION="0.10.3"
ENV_KEYS=(
    GIT_NAME
    GIT_EMAIL
    POSTGRES_USER
    POSTGRES_DB
    POSTGRES_PORT
    DEVBOX_CPU
    DEVBOX_MEMORY
    DEVBOX_DISK
    DEVBOX_USE_HOST_PROXY
)

check_host_platform() {
    [ "$(uname -s)" = "Darwin" ] || die "devbox supports macOS only"
    [ "$(uname -m)" = "arm64" ] || die "devbox supports Apple Silicon only"

    local macos_version
    macos_version="$(sw_vers -productVersion)"
    version_at_least "$macos_version" "13.0.0" || die "macOS 13 or newer is required (found $macos_version)"
}

is_allowed_env_key() {
    local candidate="$1"
    local allowed

    for allowed in "${ENV_KEYS[@]}"; do
        [ "$candidate" = "$allowed" ] && return 0
    done
    return 1
}

unset_env_keys() {
    local key

    for key in "${ENV_KEYS[@]}"; do
        unset "$key"
    done
}

env_label() {
    case "$1" in
        GIT_NAME) printf 'Git name' ;;
        GIT_EMAIL) printf 'Git email' ;;
        POSTGRES_USER) printf 'PostgreSQL user' ;;
        POSTGRES_DB) printf 'PostgreSQL database' ;;
        POSTGRES_PORT) printf 'PostgreSQL port' ;;
        DEVBOX_CPU) printf 'VM CPUs' ;;
        DEVBOX_MEMORY) printf 'VM memory in GiB' ;;
        DEVBOX_DISK) printf 'VM disk in GiB' ;;
        DEVBOX_USE_HOST_PROXY) printf 'Pass host proxy settings into the guest (true/false)' ;;
        *) printf '%s' "$1" ;;
    esac
}

env_builtin_default() {
    case "$1" in
        POSTGRES_USER | POSTGRES_DB) printf 'dev' ;;
        POSTGRES_PORT) printf '15432' ;;
        DEVBOX_CPU | DEVBOX_MEMORY) printf '4' ;;
        DEVBOX_DISK) printf '60' ;;
        DEVBOX_USE_HOST_PROXY) printf 'false' ;;
    esac
}

# Print why a value is invalid for its key, or nothing when it is valid. VM
# resources are rendered into the Colima configuration and service identifiers
# into the guest, so anything unexpected is rejected here.
env_value_error() {
    local key="$1" value="$2"

    case "$key" in
        GIT_NAME | GIT_EMAIL)
            case "$value" in
                '' | 'Your Name' | 'you@personal.com') printf 'is required' ;;
            esac
            ;;
        POSTGRES_USER | POSTGRES_DB)
            [[ "$value" =~ ^[A-Za-z0-9_.-]{1,63}$ ]] ||
                printf 'must be 1-63 ASCII letters, digits, dots, dashes, or underscores'
            ;;
        POSTGRES_PORT)
            [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$value" -le 65535 ] ||
                printf 'must be a port from 1 to 65535'
            ;;
        DEVBOX_CPU | DEVBOX_MEMORY | DEVBOX_DISK)
            [[ "$value" =~ ^[1-9][0-9]*$ ]] || printf 'must be a positive integer'
            ;;
        DEVBOX_USE_HOST_PROXY)
            case "$value" in
                true | false) ;;
                *) printf 'must be true or false' ;;
            esac
            ;;
    esac
}

# Resolve the host configuration file: an explicit DEVBOX_ENV_FILE wins,
# otherwise the checkout-local .env.
devbox_env_file() {
    if [ -n "${DEVBOX_ENV_FILE:-}" ]; then
        printf '%s\n' "$DEVBOX_ENV_FILE"
        return
    fi
    printf '%s/.env\n' "${DEVBOX_DIR:-$PWD}"
}

# Read `KEY=value` lines (optionally `export KEY=value`) as data, stripping one
# layer of matching single or double quotes; no escape sequences are
# interpreted. Strict mode rejects malformed lines; lenient mode (used by
# `devbox init`, which rewrites the file) reports and skips them.
read_env_file() {
    local env_file="$1" mode="$2" line key value line_number=0

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]]; then
            [ "$mode" = lenient ] || die "$env_file:$line_number must be a KEY=value assignment"
            warn "$env_file:$line_number is not a KEY=value assignment; ignoring"
            continue
        fi
        key="${BASH_REMATCH[2]}"
        if ! is_allowed_env_key "$key"; then
            if [ "$mode" = lenient ]; then
                warn "$env_file:$line_number removes unsupported variable $key"
            else
                warn "$env_file:$line_number ignores unsupported variable $key"
            fi
            continue
        fi
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        printf -v "$key" '%s' "$value"
    done <"$env_file"
}

load_env() {
    local env_file key error

    env_file="$(devbox_env_file)"
    [ -f "$env_file" ] || die "Missing $env_file; run 'devbox init' first"
    [ "$(file_mode "$env_file")" = "600" ] ||
        die "$env_file must have mode 0600 (run: chmod 600 '$env_file')"
    unset_env_keys
    read_env_file "$env_file" strict
    for key in "${ENV_KEYS[@]}"; do
        [ -n "${!key:-}" ] || printf -v "$key" '%s' "$(env_builtin_default "$key")"
        error="$(env_value_error "$key" "${!key}")"
        [ -z "$error" ] || die "$env_file: $key $error (found '${!key}')"
    done
}

# Quote a value for a `KEY="value"` line that read_env_file can read back.
# Values mixing both quote styles are rejected by the caller.
env_quote() {
    local value="$1"

    case "$value" in
        *'"'*)
            case "$value" in
                *"'"*) return 1 ;;
                *) printf "'%s'" "$value" ;;
            esac
            ;;
        *) printf '"%s"' "$value" ;;
    esac
}

# Default for a prompt: the value already in the configuration file, otherwise
# the host Git identity or the built-in default.
env_default() {
    local key="$1"

    if [ -n "${!key:-}" ]; then
        printf '%s' "${!key}"
        return
    fi
    case "$key" in
        GIT_NAME) git config --global user.name 2>/dev/null || true ;;
        GIT_EMAIL) git config --global user.email 2>/dev/null || true ;;
        *) env_builtin_default "$key" ;;
    esac
}

# Prompt until the answer is valid; empty input or EOF keeps the default. On a
# terminal an invalid answer is re-prompted; without one it is fatal.
prompt_env_value() {
    local key="$1" label default value error

    label="$(env_label "$key")"
    default="$(env_default "$key")"
    while :; do
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$label" "$default" >&2
        else
            printf '%s: ' "$label" >&2
        fi
        if IFS= read -r value; then
            [ -n "$value" ] || value="$default"
        else
            value="$default"
            printf '\n' >&2
        fi
        error="$(env_value_error "$key" "$value")"
        if [ -z "$error" ]; then
            printf -v "$key" '%s' "$value"
            return
        fi
        [ -t 0 ] || die "$label $error"
        warn "$label $error"
    done
}

prompt_env_values() {
    local key

    for key in "${ENV_KEYS[@]}"; do
        prompt_env_value "$key"
    done
}

write_env_file() {
    local env_file="$1" config_root temporary key quoted

    # Follow a symlinked configuration to its target, so a dotfiles-managed
    # .env is updated in place instead of being replaced by a regular file.
    [ -L "$env_file" ] && env_file="$(resolve_symlink_target "$env_file")"
    config_root="$(dirname "$env_file")"
    if [ ! -d "$config_root" ]; then
        mkdir -p "$config_root"
        chmod 700 "$config_root"
    fi
    temporary="$(mktemp "$config_root/.env.XXXXXX")"
    {
        printf "# devbox configuration - edit this file and run 'devbox init' again.\n"
        printf "# Service secrets are generated inside the guest and never live here.\n"
        printf "# Host proxy variables are not passed to the guest unless explicitly enabled.\n"
        printf '\n'
        for key in "${ENV_KEYS[@]}"; do
            if ! quoted="$(env_quote "${!key}")"; then
                command rm -f "$temporary"
                die "$key must not mix single and double quotes"
            fi
            printf 'export %s=%s\n' "$key" "$quoted"
        done
    } >"$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$env_file"
}

initialize_local_config() {
    local env_file

    check_host_platform

    env_file="$(devbox_env_file)"
    unset_env_keys
    [ ! -f "$env_file" ] || read_env_file "$env_file" lenient

    log "Configure devbox (press Enter to keep the value in brackets):"
    prompt_env_values

    write_env_file "$env_file"
    load_env
    log "devbox initialization complete."
    log "Configuration: $env_file"
    log "Edit that file and run 'devbox init' again to change settings."
}
