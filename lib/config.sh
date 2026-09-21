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

validate_env_file() {
    local env_file="$DEVBOX_DIR/.env"
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
        is_allowed_env_key "$key" || die "$env_file:$line_number contains unsupported variable $key"
    done <"$env_file"
}

load_env() {
    local key line value_expression

    validate_env_file
    for key in "${ENV_KEYS[@]}"; do
        unset "$key"
    done
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]]
        key="${BASH_REMATCH[2]}"
        value_expression="${line#*=}"
        printf -v "$key" '%s' "$(env_value "$value_expression")"
    done <"$DEVBOX_DIR/.env"

    if [ -z "${GIT_NAME:-}" ] || [ "$GIT_NAME" = "Your Name" ]; then
        die "Set GIT_NAME in $DEVBOX_DIR/.env"
    fi
    if [ -z "${GIT_EMAIL:-}" ] || [ "$GIT_EMAIL" = "you@personal.com" ]; then
        die "Set GIT_EMAIL in $DEVBOX_DIR/.env"
    fi

    DEVBOX_CPU="${DEVBOX_CPU:-4}"
    DEVBOX_MEMORY="${DEVBOX_MEMORY:-4}"
    DEVBOX_DISK="${DEVBOX_DISK:-60}"
    POSTGRES_USER="${POSTGRES_USER:-dev}"
    POSTGRES_DB="${POSTGRES_DB:-dev}"
    POSTGRES_PORT="${POSTGRES_PORT:-15432}"
}

initialize_local_config() {
    check_host_platform

    if [ ! -f "$DEVBOX_DIR/.env" ]; then
        cp "$DEVBOX_DIR/.env.example" "$DEVBOX_DIR/.env"
        chmod 600 "$DEVBOX_DIR/.env"
        log "Created $DEVBOX_DIR/.env"
        die "Fill in $DEVBOX_DIR/.env, then run 'devbox init' again"
    fi

    load_env
    log "devbox initialization complete."
}
