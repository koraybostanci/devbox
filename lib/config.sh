#!/bin/bash

MINIMUM_COLIMA_VERSION="0.10.3"
ENV_KEYS=(
    GIT_NAME
    GIT_EMAIL
    ANTHROPIC_API_KEY
    DATABRICKS_HOST
    DATABRICKS_TOKEN
    POSTGRES_USER
    POSTGRES_PASSWORD
    POSTGRES_DB
    POSTGRES_PORT
    DEVBOX_CPU
    DEVBOX_MEMORY
    DEVBOX_DISK
    DEVBOX_PROJECTS_DIR
    DEVBOX_DATA_DIR
)

configure_paths() {
    local colima_home

    DEVBOX_STATE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/devbox"
    DEVBOX_CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/devbox"
    DEVBOX_LEGACY_COLIMA_HOME="$DEVBOX_STATE_ROOT/colima"
    colima_home="${COLIMA_HOME:-$HOME/.colima}"
    DOCKER_CONFIG="$DEVBOX_CONFIG_ROOT/docker"
    DEVBOX_LOCK_DIR="$DEVBOX_STATE_ROOT/locks"
    DEVBOX_COLIMA_PROFILE="$colima_home/$PROFILE"
    DEVBOX_COLIMA_CONFIG="$DEVBOX_COLIMA_PROFILE/colima.yaml"
    DEVBOX_COLIMA_OWNER="$DEVBOX_COLIMA_PROFILE/.devbox-owner"
    DEVBOX_LEGACY_COLIMA_PROFILE="$DEVBOX_LEGACY_COLIMA_HOME/$PROFILE"
    export DOCKER_CONFIG DEVBOX_LOCK_DIR
}

check_colima_home() {
    case "$(dirname "$DEVBOX_COLIMA_PROFILE")" in
        "$HOME/.colima" | "$DEVBOX_LEGACY_COLIMA_HOME") ;;
        *) die "COLIMA_HOME must point to $HOME/.colima; unset it to use the standard Colima home" ;;
    esac
}

check_legacy_colima_profile() {
    check_colima_home
    [ "$DEVBOX_LEGACY_COLIMA_PROFILE" = "$DEVBOX_COLIMA_PROFILE" ] && return
    [ ! -e "$DEVBOX_LEGACY_COLIMA_PROFILE" ] ||
        die "Legacy private Colima profile found at $DEVBOX_LEGACY_COLIMA_PROFILE; migrate it before continuing (see $DEVBOX_DIR/docs/troubleshooting.md)"
}

check_colima_profile_ownership() {
    local owner_checkout owner_version provision_location runtime

    [ "$DEVBOX_LEGACY_COLIMA_PROFILE" = "$DEVBOX_COLIMA_PROFILE" ] && return
    check_legacy_colima_profile
    [ -e "$DEVBOX_COLIMA_PROFILE" ] || return
    if [ -f "$DEVBOX_COLIMA_OWNER" ]; then
        owner_version="$(sed -n '1p' "$DEVBOX_COLIMA_OWNER")"
        owner_checkout="$(sed -n '2p' "$DEVBOX_COLIMA_OWNER")"
        [ "$owner_version" = "devbox-profile-v1" ] ||
            die "Invalid ownership marker in $DEVBOX_COLIMA_OWNER"
        [ "$owner_checkout" = "$DEVBOX_DIR" ] ||
            die "Colima profile '$PROFILE' is owned by another devbox checkout: $owner_checkout (see $DEVBOX_DIR/docs/troubleshooting.md#checkout-moved-or-renamed)"
        return
    fi

    if [ -f "$DEVBOX_COLIMA_CONFIG" ] && command -v yq >/dev/null 2>&1; then
        runtime="$(yq eval '.runtime // ""' "$DEVBOX_COLIMA_CONFIG" 2>/dev/null || true)"
        provision_location="$(yq eval '.mounts[] | select(.mountPoint == "/provision") | .location' "$DEVBOX_COLIMA_CONFIG" 2>/dev/null || true)"
        if [ "$runtime" = "docker" ] && [ "$provision_location" = "$DEVBOX_DIR/provision" ]; then
            return
        fi
    fi

    die "Colima profile '$PROFILE' already exists but is not owned by this devbox checkout; inspect it with 'colima list' before continuing"
}

mark_colima_profile_owned() {
    local temporary

    temporary="$(mktemp "$DEVBOX_COLIMA_PROFILE/.devbox-owner.XXXXXX")"
    printf '%s\n%s\n' "devbox-profile-v1" "$DEVBOX_DIR" >"$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$DEVBOX_COLIMA_OWNER"
}

check_host_platform() {
    [ "$(uname -s)" = "Darwin" ] || die "devbox supports macOS only"
    [ "$(uname -m)" = "arm64" ] || die "devbox supports Apple Silicon only"

    local macos_version
    macos_version="$(sw_vers -productVersion)"
    version_at_least "$macos_version" "13.0.0" || die "macOS 13 or newer is required (found $macos_version)"
}

check_host_dependencies() {
    local command_name colima_version homebrew_prefix compose_plugin_dir
    local -a missing

    command -v brew >/dev/null 2>&1 || die "Homebrew is required: https://brew.sh"
    for command_name in colima docker jq yq ssh; do
        command -v "$command_name" >/dev/null 2>&1 && continue
        case "$command_name" in
            ssh) missing+=(openssh) ;;
            *) missing+=("$command_name") ;;
        esac
    done
    homebrew_prefix="$(brew --prefix)"
    compose_plugin_dir="$homebrew_prefix/lib/docker/cli-plugins"
    [ -x "$compose_plugin_dir/docker-compose" ] || missing+=(docker-compose)

    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing host dependencies. Review and run: brew install ${missing[*]}"
    fi

    configure_docker_cli "$compose_plugin_dir"
    docker compose version >/dev/null 2>&1 ||
        die "Docker Compose is required. Review and run: brew install docker-compose"

    colima_version="$(colima version | awk 'NR == 1 {print $3}')"
    version_at_least "$colima_version" "$MINIMUM_COLIMA_VERSION" ||
        die "Colima $MINIMUM_COLIMA_VERSION or newer is required (found $colima_version)"
}

configure_docker_cli() {
    local compose_plugin_dir="$1"
    local config_file temporary

    mkdir -p "$DOCKER_CONFIG"
    config_file="$DOCKER_CONFIG/config.json"
    temporary="$(mktemp "$DOCKER_CONFIG/.config.XXXXXX")"
    if [ -f "$config_file" ]; then
        if ! jq -e 'type == "object"' "$config_file" >/dev/null; then
            rm -f "$temporary"
            die "$config_file must contain a JSON object"
        fi
        if ! jq --arg directory "$compose_plugin_dir" '
            (.cliPluginsExtraDirs // []) as $directories |
            if ($directories | type) != "array" then
                error("cliPluginsExtraDirs must be an array")
            elif ($directories | index($directory)) == null then
                .cliPluginsExtraDirs = ($directories + [$directory])
            else
                .
            end
        ' "$config_file" >"$temporary"; then
            rm -f "$temporary"
            die "Unable to update $config_file"
        fi
    else
        jq -n --arg directory "$compose_plugin_dir" \
            '{cliPluginsExtraDirs: [$directory]}' >"$temporary"
    fi
    chmod 600 "$temporary"
    mv "$temporary" "$config_file"
}

is_allowed_env_key() {
    local candidate="$1"
    local allowed

    for allowed in "${ENV_KEYS[@]}"; do
        [ "$candidate" = "$allowed" ] && return 0
    done
    return 1
}

validate_env_file() {
    local env_file="$DEVBOX_DIR/.env"
    local line key value_expression line_number=0

    [ -f "$env_file" ] || die "Missing $env_file; run 'devbox init' first"
    [ "$(file_mode "$env_file")" = "600" ] || die "$env_file must have mode 0600 (run: chmod 600 '$env_file')"

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]]; then
            die "$env_file:$line_number must be a simple environment assignment"
        fi
        key="${BASH_REMATCH[2]}"
        is_allowed_env_key "$key" || die "$env_file:$line_number contains unsupported variable $key"
        value_expression="${line#*=}"
        printf '%s\n' "$value_expression" | jq -eR 'fromjson | type == "string"' >/dev/null ||
            die "$env_file:$line_number value must be a JSON-compatible quoted string"
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
        printf -v "$key" '%s' "$(printf '%s\n' "$value_expression" | jq -Rr fromjson)"
    done <"$DEVBOX_DIR/.env"

    if [ -z "${GIT_NAME:-}" ] || [ "$GIT_NAME" = "Your Name" ]; then
        die "Set GIT_NAME in $DEVBOX_DIR/.env"
    fi
    if [ -z "${GIT_EMAIL:-}" ] || [ "$GIT_EMAIL" = "you@personal.com" ]; then
        die "Set GIT_EMAIL in $DEVBOX_DIR/.env"
    fi
    if [ -z "${ANTHROPIC_API_KEY:-}" ] || [ "$ANTHROPIC_API_KEY" = "sk-ant-..." ]; then
        die "Set ANTHROPIC_API_KEY in $DEVBOX_DIR/.env"
    fi
    [ -z "${DATABRICKS_TOKEN:-}" ] ||
        warn "DATABRICKS_TOKEN is ignored; remove it from $DEVBOX_DIR/.env because Databricks uses OAuth login"

    DEVBOX_CPU="${DEVBOX_CPU:-4}"
    DEVBOX_MEMORY="${DEVBOX_MEMORY:-4}"
    DEVBOX_DISK="${DEVBOX_DISK:-60}"
    DEVBOX_PROJECTS_DIR="${DEVBOX_PROJECTS_DIR:-$(dirname "$DEVBOX_DIR")/projects}"
    DEVBOX_DATA_DIR="${DEVBOX_DATA_DIR:-$(dirname "$DEVBOX_DIR")/data}"
    POSTGRES_USER="${POSTGRES_USER:-dev}"
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-devpass}"
    POSTGRES_DB="${POSTGRES_DB:-dev}"
    POSTGRES_PORT="${POSTGRES_PORT:-15432}"

    validate_integer_range DEVBOX_CPU "$DEVBOX_CPU" 2 16
    validate_integer_range DEVBOX_MEMORY "$DEVBOX_MEMORY" 2 32
    validate_integer_range DEVBOX_DISK "$DEVBOX_DISK" 20 512
    validate_integer_range POSTGRES_PORT "$POSTGRES_PORT" 1024 65535
    validate_local_path DEVBOX_PROJECTS_DIR "$DEVBOX_PROJECTS_DIR"
    validate_local_path DEVBOX_DATA_DIR "$DEVBOX_DATA_DIR"
}

validate_integer_range() {
    local name="$1" value="$2" minimum="$3" maximum="$4"
    [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an integer"
    ((value >= minimum && value <= maximum)) || die "$name must be between $minimum and $maximum"
}

validate_local_path() {
    local name="$1" value="$2"
    [ -n "$value" ] || die "$name cannot be empty"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$name contains a control character"
    case "$value" in
        /*) ;;
        *) die "$name must be an absolute path" ;;
    esac
}

initialize_local_config() {
    check_host_platform
    check_host_dependencies
    configure_paths

    mkdir -p "$DEVBOX_STATE_ROOT" "$DEVBOX_CONFIG_ROOT" "$DOCKER_CONFIG"
    if [ ! -f "$DEVBOX_DIR/.env" ]; then
        cp "$DEVBOX_DIR/.env.example" "$DEVBOX_DIR/.env"
        chmod 600 "$DEVBOX_DIR/.env"
        log "Created $DEVBOX_DIR/.env"
        die "Fill in $DEVBOX_DIR/.env, then run 'devbox init' again"
    fi

    load_env
    mkdir -p "$DEVBOX_PROJECTS_DIR" "$DEVBOX_DATA_DIR"
    [ -w "$DEVBOX_PROJECTS_DIR" ] || die "$DEVBOX_PROJECTS_DIR is not writable"
    [ -w "$DEVBOX_DATA_DIR" ] || die "$DEVBOX_DATA_DIR is not writable"
    log "devbox initialization complete."
}

json_string() {
    jq -Rn --arg value "$1" '$value'
}

render_colima_config() {
    local content temporary
    local devbox_path projects_path data_path

    load_env
    configure_paths
    check_colima_profile_ownership
    mkdir -p "$DEVBOX_PROJECTS_DIR" "$DEVBOX_DATA_DIR" "$DEVBOX_COLIMA_PROFILE"

    devbox_path="$(json_string "$DEVBOX_DIR/provision")"
    projects_path="$(json_string "$DEVBOX_PROJECTS_DIR")"
    data_path="$(json_string "$DEVBOX_DATA_DIR")"
    content="$(<"$DEVBOX_DIR/colima.yaml")"
    content="${content//'{{CPU}}'/$DEVBOX_CPU}"
    content="${content//'{{MEMORY}}'/$DEVBOX_MEMORY}"
    content="${content//'{{DISK}}'/$DEVBOX_DISK}"
    content="${content//'{{PROVISION_PATH}}'/$devbox_path}"
    content="${content//'{{PROJECTS_PATH}}'/$projects_path}"
    content="${content//'{{DATA_PATH}}'/$data_path}"
    [[ "$content" != *'{{'* ]] || die "Unresolved placeholder in rendered Colima configuration"

    temporary="$(mktemp "$(dirname "$DEVBOX_COLIMA_CONFIG")/.colima.yaml.XXXXXX")"
    printf '%s\n' "$content" >"$temporary"
    if ! yq eval '.' "$temporary" >/dev/null; then
        command rm -f "$temporary"
        die "Generated Colima configuration is invalid"
    fi
    chmod 600 "$temporary"
    mv "$temporary" "$DEVBOX_COLIMA_CONFIG"
    mark_colima_profile_owned
    log "Rendered $DEVBOX_COLIMA_CONFIG"
}
