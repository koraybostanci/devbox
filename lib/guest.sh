#!/bin/bash
guest_exec() {
    colima_cmd ssh -p "$PROFILE" -- "$@"
}

shell_quote() {
    printf '%q' "$1"
}

render_guest_env() {
    local key value
    local -a guest_keys=(
        GIT_NAME GIT_EMAIL ANTHROPIC_API_KEY
        POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_PORT
    )

    for key in "${guest_keys[@]}"; do
        value="${!key:-}"
        printf 'export %s=%s\n' "$key" "$(shell_quote "$value")"
    done
}

render_service_env() {
    printf 'POSTGRES_USER=%s\n' "$(printf '%s' "$POSTGRES_USER" | jq -Rs '.')"
    printf 'POSTGRES_PASSWORD=%s\n' "$(printf '%s' "$POSTGRES_PASSWORD" | jq -Rs '.')"
    printf 'POSTGRES_DB=%s\n' "$(printf '%s' "$POSTGRES_DB" | jq -Rs '.')"
    printf 'POSTGRES_PORT=%s\n' "$(printf '%s' "$POSTGRES_PORT" | jq -Rs '.')"
}

sync_guest_env() {
    load_env
    render_guest_env | guest_exec bash -c '
        set -Eeuo pipefail
        umask 077
        directory="$HOME/.config/devbox"
        mkdir -p "$directory"
        temporary="$(mktemp "$directory/.env.XXXXXX")"
        cat > "$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$directory/env"
    '
    render_service_env | guest_exec bash -c '
        set -Eeuo pipefail
        umask 077
        directory="$HOME/.config/devbox"
        temporary="$(mktemp "$directory/.service.XXXXXX")"
        cat > "$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$directory/service.env"
    '
}

provision_digest() {
    {
        printf '%s\n' "colima.yaml"
        shasum -a 256 "$DEVBOX_DIR/colima.yaml"
        find "$DEVBOX_DIR/provision" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
            printf '%s\n' "${file#"$DEVBOX_DIR/"}"
            shasum -a 256 "$file"
        done
    } | shasum -a 256 | awk '{print $1}'
}

guest_provision_digest() {
    guest_exec bash -c 'cat "$HOME/.local/state/devbox/provision.sha256" 2>/dev/null || true'
}

run_guest_provisioning() {
    local digest="$1"

    log "Provisioning guest tools..."
    guest_exec bash -c '
        set -Eeuo pipefail
        set -a
        source "$HOME/.config/devbox/env"
        set +a
        sudo bash /provision/scripts/system.sh
        bash /provision/scripts/tools.sh
        bash /provision/scripts/verify.sh
    '
    printf '%s\n' "$digest" | guest_exec bash -c '
        set -Eeuo pipefail
        umask 077
        directory="$HOME/.local/state/devbox"
        mkdir -p "$directory"
        temporary="$(mktemp "$directory/.provision.XXXXXX")"
        cat > "$temporary"
        mv "$temporary" "$directory/provision.sha256"
    '
}

provision_guest() {
    local force="${1:-false}"
    local host_digest guest_digest

    host_digest="$(provision_digest)"
    guest_digest="$(guest_provision_digest)"
    if [ "$force" = "false" ] && [ "$host_digest" = "$guest_digest" ]; then
        log "Provisioning is current."
        return
    fi
    run_guest_provisioning "$host_digest"
}

rotate_guest_credentials() {
    require_running_vm
    sync_guest_env
    guest_exec bash -c '
        set -Eeuo pipefail
        set -a
        source "$HOME/.config/devbox/env"
        set +a
        git config --global user.name "$GIT_NAME"
        git config --global user.email "$GIT_EMAIL"
    '
    log "Credentials updated without restarting the VM."
}

databricks_command() {
    local action="${1:-status}"

    require_running_vm
    load_env
    case "$action" in
        login)
            [ -n "${DATABRICKS_HOST:-}" ] || die "Set DATABRICKS_HOST in $DEVBOX_DIR/.env"
            guest_exec databricks auth login --host "$DATABRICKS_HOST" --profile DEFAULT
            ;;
        status) guest_exec databricks auth describe --profile DEFAULT ;;
        logout) guest_exec databricks auth logout --profile DEFAULT ;;
        *) die "Usage: devbox databricks [login|status|logout]" ;;
    esac
}

github_command() {
    local action="${1:-status}"
    require_running_vm
    case "$action" in
        login)
            open https://github.com/login/device >/dev/null 2>&1 ||
                warn "Could not open GitHub in the host browser; visit https://github.com/login/device"
            guest_exec env GH_BROWSER=true gh auth login --hostname github.com --git-protocol https --web
            guest_exec gh auth setup-git
            guest_exec gh config set git_protocol https --host github.com
            ;;
        status)
            guest_exec bash -c '
                gh auth status --hostname github.com
                gh api user --silent >/dev/null 2>&1
            '
            ;;
        logout) guest_exec gh auth logout --hostname github.com ;;
        *) die "Usage: devbox github [login|status|logout]" ;;
    esac
}
