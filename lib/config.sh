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

# Resolve the host configuration file: an explicit DEVBOX_ENV_FILE wins,
# otherwise the checkout-local .env.
devbox_env_file() {
    if [ -n "${DEVBOX_ENV_FILE:-}" ]; then
        printf '%s\n' "$DEVBOX_ENV_FILE"
        return
    fi
    printf '%s/.env\n' "${DEVBOX_DIR:-$PWD}"
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
    local key line value_expression env_file resource_key resource_value

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

    # These values are rendered straight into the Colima configuration and
    # passed as `colima start` flags, so reject anything that is not a positive
    # integer before it can reach the VM.
    for resource_key in DEVBOX_CPU DEVBOX_MEMORY DEVBOX_DISK; do
        resource_value="${!resource_key}"
        [[ "$resource_value" =~ ^[1-9][0-9]*$ ]] ||
            die "$env_file: $resource_key must be a positive integer (found '$resource_value')"
    done
}

# Quote a value for a `KEY="value"` line that env_value can read back. Values
# mixing both quote styles are rejected by the caller.
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

host_git_config() {
    local key="$1" fallback="$2" value=""

    if command -v git >/dev/null 2>&1; then
        value="$(git config --global "$key" 2>/dev/null || true)"
    fi
    printf '%s\n' "${value:-$fallback}"
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
        *) printf '%s' "$1" ;;
    esac
}

# Default for a prompt: the value already in the configuration file, otherwise
# the host Git identity or the built-in default.
env_default() {
    local key="$1" current="${!key:-}"

    if [ -n "$current" ]; then
        printf '%s\n' "$current"
        return
    fi
    case "$key" in
        GIT_NAME) host_git_config user.name "Your Name" ;;
        GIT_EMAIL) host_git_config user.email "you@personal.com" ;;
        POSTGRES_USER) printf 'dev\n' ;;
        POSTGRES_DB) printf 'dev\n' ;;
        POSTGRES_PORT) printf '15432\n' ;;
        DEVBOX_CPU) printf '4\n' ;;
        DEVBOX_MEMORY) printf '4\n' ;;
        DEVBOX_DISK) printf '60\n' ;;
        *) printf '\n' ;;
    esac
}

# Read the existing configuration leniently, so `devbox init` can offer current
# values as defaults even when the file needs repair.
load_env_defaults() {
    local env_file="$1" line key value_expression

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]]
        key="${BASH_REMATCH[2]}"
        is_allowed_env_key "$key" || continue
        value_expression="${line#*=}"
        printf -v "$key" '%s' "$(env_value "$value_expression")"
    done <"$env_file"
}

# Print `label [default]: ` and read one value; empty input or EOF keeps the
# default.
prompt_value() {
    local label="$1" default="$2" value

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
    printf '%s' "$value"
}

# Required text value. On a terminal an invalid answer is re-prompted; without
# one (piped or closed stdin) the caller reports the failure.
prompt_required() {
    local label="$1" default="$2" value

    while :; do
        value="$(prompt_value "$label" "$default")"
        case "$value" in
            '' | 'Your Name' | 'you@personal.com')
                if [ -t 0 ]; then
                    warn "$label is required"
                    continue
                fi
                return 1
                ;;
        esac
        printf '%s' "$value"
        return 0
    done
}

prompt_number() {
    local label="$1" default="$2" value

    while :; do
        value="$(prompt_value "$label" "$default")"
        if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
            printf '%s' "$value"
            return 0
        fi
        if [ -t 0 ]; then
            warn "$label must be a positive integer"
            continue
        fi
        return 1
    done
}

write_env_file() {
    local env_file="$1" config_root temporary key quoted

    config_root="$(dirname "$env_file")"
    if [ ! -d "$config_root" ]; then
        mkdir -p "$config_root"
        chmod 700 "$config_root"
    fi
    temporary="$(mktemp "$config_root/.env.XXXXXX")"
    {
        printf "# devbox configuration - edit this file and run 'devbox init' again.\n"
        printf "# Service secrets are generated inside the guest and never live here.\n"
        printf '\n'
        for key in "${ENV_KEYS[@]}"; do
            quoted="$(env_quote "${!key}")" ||
                die "$key must not mix single and double quotes"
            printf 'export %s=%s\n' "$key" "$quoted"
        done
    } >"$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$env_file"
}

# Prompt for every supported key, keeping existing values as defaults.
prompt_env_values() {
    local key value label

    for key in "${ENV_KEYS[@]}"; do
        label="$(env_label "$key")"
        value="$(env_default "$key")"
        case "$key" in
            DEVBOX_CPU | DEVBOX_MEMORY | DEVBOX_DISK | POSTGRES_PORT)
                value="$(prompt_number "$label" "$value")" ||
                    die "$label must be a positive integer"
                ;;
            *)
                value="$(prompt_required "$label" "$value")" ||
                    die "$label is required"
                ;;
        esac
        printf -v "$key" '%s' "$value"
    done
}

initialize_local_config() {
    local env_file key

    check_host_platform

    env_file="$(devbox_env_file)"
    for key in "${ENV_KEYS[@]}"; do
        unset "$key"
    done
    if [ -f "$env_file" ]; then
        load_env_defaults "$env_file"
    fi

    log "Configure devbox (press Enter to keep the value in brackets):"
    prompt_env_values

    write_env_file "$env_file"
    load_env
    log "devbox initialization complete."
    log "Configuration: $env_file"
    log "Edit that file and run 'devbox init' again to change settings."
}
