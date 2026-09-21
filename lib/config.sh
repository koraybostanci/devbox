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

# Parse `KEY=value` (optionally `export KEY=value`), stripping one layer of
# matching single or double quotes. No escape sequences are interpreted.
env_value() {
    local expression="$1"

    expression="${expression#"${expression%%[![:space:]]*}"}"
    expression="${expression%"${expression##*[![:space:]]}"}"
    case "$expression" in
        \"*\") expression="${expression#\"}"; expression="${expression%\"}" ;;
        \'*\') expression="${expression#\'}"; expression="${expression%\'}" ;;
    esac
    printf '%s' "$expression"
}

# Resolve the host configuration file. An explicit DEVBOX_ENV_FILE wins.
# Release installs live under the data root's releases/ tree, so their
# configuration must stay outside the versioned directory; checkouts keep the
# repository-local .env. The release-tree detection compares canonical
# directories because the launcher reports DEVBOX_DIR physically while the
# data root may be reached through a symlinked $HOME.
devbox_env_file() {
    local directory data_root

    if [ -n "${DEVBOX_ENV_FILE:-}" ]; then
        printf '%s\n' "$DEVBOX_ENV_FILE"
        return
    fi
    directory="$(canonicalize_path "${DEVBOX_DIR:-$PWD}")"
    data_root="$(devbox_data_root)"
    case "$directory" in
        "$data_root"/releases/*) printf '%s\n' "$HOME/.config/devbox/env" ;;
        *) printf '%s\n' "$directory/.env" ;;
    esac
}

# Warn once when a release install still carries the superseded in-tree .env.
devbox_warn_legacy_env_file() {
    local directory data_root release_env

    [ "${DEVBOX_ENV_FILE_WARNED:-}" = true ] && return 0
    directory="$(canonicalize_path "${DEVBOX_DIR:-$PWD}")"
    data_root="$(devbox_data_root)"
    case "$directory" in
        "$data_root"/releases/*) ;;
        *) return 0 ;;
    esac
    release_env="$HOME/.config/devbox/env"
    if [ -f "$release_env" ] && [ -f "$directory/.env" ]; then
        DEVBOX_ENV_FILE_WARNED=true
        warn "ignoring legacy $directory/.env; release configurations live at $release_env"
    fi
}

validate_env_file() {
    local env_file="${1:-$(devbox_env_file)}"
    local line key line_number=0

    [ -f "$env_file" ] || die "Missing $env_file; run 'devbox init' first"
    [ "$(file_mode "$env_file")" = "600" ] ||
        die "$env_file must have mode 0600 (run: chmod 600 '$env_file')"

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]]; then
            die "$env_file:$line_number must be a KEY=value assignment"
        fi
        key="${BASH_REMATCH[2]}"
        is_allowed_env_key "$key" ||
            warn "$env_file:$line_number ignores unsupported variable $key"
    done <"$env_file"
}

load_env() {
    local key line value_expression env_file

    devbox_warn_legacy_env_file
    env_file="$(devbox_env_file)"
    validate_env_file "$env_file"
    for key in "${ENV_KEYS[@]}"; do
        unset "$key"
    done
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]]
        key="${BASH_REMATCH[2]}"
        is_allowed_env_key "$key" || continue
        value_expression="${line#*=}"
        printf -v "$key" '%s' "$(env_value "$value_expression")"
    done <"$env_file"

    if [ -z "${GIT_NAME:-}" ] || [ "$GIT_NAME" = "Your Name" ]; then
        die "Set GIT_NAME in $env_file"
    fi
    if [ -z "${GIT_EMAIL:-}" ] || [ "$GIT_EMAIL" = "you@personal.com" ]; then
        die "Set GIT_EMAIL in $env_file"
    fi

    DEVBOX_CPU="${DEVBOX_CPU:-4}"
    DEVBOX_MEMORY="${DEVBOX_MEMORY:-4}"
    DEVBOX_DISK="${DEVBOX_DISK:-60}"
    POSTGRES_USER="${POSTGRES_USER:-dev}"
    POSTGRES_DB="${POSTGRES_DB:-dev}"
    POSTGRES_PORT="${POSTGRES_PORT:-15432}"
}

initialize_local_config() {
    local env_file config_root

    check_host_platform

    devbox_warn_legacy_env_file
    env_file="$(devbox_env_file)"
    if [ ! -f "$env_file" ]; then
        [ -f "$DEVBOX_DIR/.env.example" ] ||
            die "Missing $DEVBOX_DIR/.env.example; reinstall devbox"
        config_root="$(dirname "$env_file")"
        if [ ! -d "$config_root" ]; then
            mkdir -p "$config_root"
            chmod 700 "$config_root"
        fi
        cp "$DEVBOX_DIR/.env.example" "$env_file"
        chmod 600 "$env_file"
        log "Created $env_file"
        die "Fill in $env_file, then run 'devbox init' again"
    fi

    load_env
    log "devbox initialization complete."
}
