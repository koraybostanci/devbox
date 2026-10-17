#!/bin/bash

DEVBOX_PROFILE="devbox"
DEVBOX_GUEST_USER="devbox"
DEVBOX_GUEST_HOME="/home/$DEVBOX_GUEST_USER"
DEVBOX_GUEST_PROVISION_ROOT="/var/lib/devbox/provision"
DEVBOX_COLIMA_PROXY_OPT_IN=false
DEVBOX_PROXY_KEYS=(
    HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY WS_PROXY NO_PROXY
    http_proxy https_proxy all_proxy ftp_proxy ws_proxy no_proxy
)

configure_devbox_paths() {
    [ "${COLIMA_HOME:-$HOME/.colima}" = "$HOME/.colima" ] ||
        die "devbox requires the standard Colima home $HOME/.colima; unset COLIMA_HOME"
    DEVBOX_COLIMA_HOME="$HOME/.colima"
    DEVBOX_LIMA_HOME="$DEVBOX_COLIMA_HOME/_lima"
    case "${LIMA_HOME:-}" in
        '' | "$DEVBOX_LIMA_HOME") ;;
        *) die "devbox requires LIMA_HOME to be unset or $DEVBOX_LIMA_HOME" ;;
    esac
    DEVBOX_COLIMA_PROFILE="$DEVBOX_COLIMA_HOME/$DEVBOX_PROFILE"
    DEVBOX_COLIMA_CONFIG="$DEVBOX_COLIMA_PROFILE/colima.yaml"
    DEVBOX_DOCKER_CONFIG="$HOME/.config/devbox/docker"
    # Default consumed by lib/common.sh's acquire_lock; the gate overrides it
    # through the environment for its lock unit test.
    # shellcheck disable=SC2034
    DEVBOX_LOCK_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/devbox/locks"
}

check_devbox_dependencies() {
    local command_name colima_version
    local -a missing=()

    for command_name in colima ssh; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    [ "${#missing[@]}" -eq 0 ] ||
        die "Missing host dependencies for devbox: ${missing[*]}. Install Colima from https://colima.run."
    colima_version="$(devbox_colima version | awk 'NR == 1 {print $3}')"
    version_at_least "$colima_version" "$MINIMUM_COLIMA_VERSION" ||
        die "Colima $MINIMUM_COLIMA_VERSION or newer is required (found $colima_version)"
}

# Run Colima against the devbox profile with an isolated Docker configuration,
# so the VM's Docker context never leaks into the host Docker CLI. Lima treats
# an empty proxy variable as an instruction to remove any previously propagated
# proxy from the guest, so every proxy variable is cleared unless this is a
# `start` with the explicit opt-in.
devbox_colima() {
    local key
    local -a proxy_env=()

    for key in "${DEVBOX_PROXY_KEYS[@]}"; do
        if [ "${1:-}" = start ] && [ "$DEVBOX_COLIMA_PROXY_OPT_IN" = true ]; then
            proxy_env+=("$key=${!key-}")
        else
            proxy_env+=("$key=")
        fi
    done
    command -v colima >/dev/null 2>&1 || die "Missing host dependency: colima"
    mkdir -p "$DEVBOX_DOCKER_CONFIG"
    chmod 700 "$DEVBOX_DOCKER_CONFIG"
    env "${proxy_env[@]}" \
        COLIMA_HOME="$DEVBOX_COLIMA_HOME" \
        LIMA_HOME="$DEVBOX_LIMA_HOME" \
        DOCKER_CONFIG="$DEVBOX_DOCKER_CONFIG" \
        colima "$@"
}

# Print the `colima list` record for the devbox profile.
devbox_profile_record() {
    devbox_colima list |
        awk -v profile="$DEVBOX_PROFILE" '$1 == profile { print; exit }'
}

devbox_state() {
    local record

    record="$(devbox_profile_record)" || die "could not determine the devbox VM state"
    awk '{ print $2 }' <<<"$record"
}

validate_devbox_colima_config() {
    local file="$1"

    # Assert every setting that defines the host/guest boundary so a config
    # edit cannot silently turn on mounts, forwarding, or host context changes.
    grep -qE '^runtime:[[:space:]]*docker$' "$file" &&
        grep -qE '^arch:[[:space:]]*aarch64$' "$file" &&
        grep -qE '^vmType:[[:space:]]*vz$' "$file" &&
        grep -qE '^autoActivate:[[:space:]]*false$' "$file" &&
        grep -qE '^forwardAgent:[[:space:]]*false$' "$file" &&
        grep -qE '^portForwarder:[[:space:]]*none$' "$file" &&
        grep -qE '^sshConfig:[[:space:]]*false$' "$file" &&
        grep -qE '^mounts:[[:space:]]*null$' "$file" &&
        [ "$(grep -cE '^mounts:' "$file" || true)" -eq 1 ] &&
        grep -qE '^env:[[:space:]]*\{\}$' "$file"
}

render_devbox_colima_config() {
    local content temporary

    mkdir -p "$DEVBOX_COLIMA_PROFILE"
    content="$(<"$DEVBOX_DIR/colima.yaml")"
    content="${content//'{{CPU}}'/$DEVBOX_CPU}"
    content="${content//'{{MEMORY}}'/$DEVBOX_MEMORY}"
    content="${content//'{{DISK}}'/$DEVBOX_DISK}"
    [[ "$content" != *'{{'* ]] || die "Unresolved placeholder in rendered devbox Colima configuration"

    temporary="$(mktemp "$DEVBOX_COLIMA_PROFILE/.colima.yaml.XXXXXX")"
    printf '%s\n' "$content" >"$temporary"
    validate_devbox_colima_config "$temporary" || {
        command rm -f "$temporary"
        die "Generated devbox Colima configuration is invalid"
    }
    chmod 600 "$temporary"
    mv "$temporary" "$DEVBOX_COLIMA_CONFIG"
}

devbox_admin_guest() {
    devbox_colima ssh -p "$DEVBOX_PROFILE" -- "$@"
}

devbox_guest() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 devbox -- "$@"
}

# Interactive variant for prompts (provider login, portable shell).
devbox_guest_interactive() {
    ssh -t -o BatchMode=yes -o ConnectTimeout=10 devbox -- "$@"
}

# The payload is single-quoted so it is expanded inside the guest, not here.
# shellcheck disable=SC2016
devbox_as_guest() {
    devbox_admin_guest sudo -u "$DEVBOX_GUEST_USER" -- env HOME="$DEVBOX_GUEST_HOME" \
        bash -c 'cd -- "$HOME" && exec "$@"' _ "$@"
}

require_running_devbox_vm() {
    [ "$(devbox_state)" = Running ] || die "devbox VM is not running; run 'devbox start' first"
}

wait_for_devbox_ssh() {
    local attempts=60 attempt

    log "Waiting for devbox VM SSH readiness..."
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if devbox_admin_guest true >/dev/null 2>&1; then
            return
        fi
        sleep 2
    done
    die "devbox VM SSH did not become ready within $((attempts * 2)) seconds"
}

start_devbox_vm() {
    local state

    render_devbox_colima_config
    DEVBOX_COLIMA_PROXY_OPT_IN="$DEVBOX_USE_HOST_PROXY"
    state="$(devbox_state)"
    case "$state" in
        Running) ;;
        '' | Stopped)
            # Every profile setting is rendered into colima.yaml before the
            # start; only --save-config stays a flag because it must keep Colima
            # from rewriting the rendered file.
            devbox_colima start "$DEVBOX_PROFILE" --save-config=false
            ;;
        *) die "devbox VM is in state '$state'; wait for it to settle and retry" ;;
    esac
    wait_for_devbox_ssh
}

devbox_bundle_digest() {
    local provision_root="$1"

    (
        cd "$provision_root" || exit
        find . -type f ! -path './.devbox-bundle.sha256' -print | LC_ALL=C sort | while IFS= read -r path; do
            printf '%s\t%s\n' "${path#./}" "$(shasum -a 256 "$path" | awk '{print $1}')"
        done | shasum -a 256 | awk '{print $1}'
    )
}

# The guest-side equivalent of devbox_bundle_digest, prepended to the remote
# payloads below. Single-quoted: every expansion happens inside the guest.
# shellcheck disable=SC2016
DEVBOX_GUEST_BUNDLE_DIGEST='
bundle_digest() (
    cd "$1"
    find . -type f ! -path ./.devbox-bundle.sha256 -print | LC_ALL=C sort | while IFS= read -r path; do
        printf "%s\t%s\n" "${path#./}" "$(sha256sum "$path" | cut -d " " -f1)"
    done | sha256sum | cut -d " " -f1
)
'

create_devbox_bundle_archive() {
    local archive="$1"

    if [ "$(uname -s)" = "Darwin" ]; then
        COPYFILE_DISABLE=1 tar --no-mac-metadata -cf "$archive" -C "$DEVBOX_DIR" provision
    else
        tar -cf "$archive" -C "$DEVBOX_DIR" provision
    fi
}

# Stream the provisioning tree to the guest and install it as the single
# root-owned, read-only input at /var/lib/devbox/provision. The digest is
# re-computed inside the guest before anything is executed, so a tree that
# changed after hashing fails closed. The payload stays single-quoted so it is
# expanded inside the guest, not here.
# shellcheck disable=SC2016
stream_devbox_bundle() {
    local digest="$1" archive="$2"

    devbox_admin_guest sudo bash -c "$DEVBOX_GUEST_BUNDLE_DIGEST"'
        set -Eeuo pipefail
        digest="$1"
        root=/var/lib/devbox
        target="$root/provision"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
            printf "ERROR: devbox bundle digest is invalid\n" >&2
            exit 1
        }
        install -d -o root -g root -m 755 "$root"
        temporary="$(mktemp -d "$root/.provision.XXXXXX")"
        trap "rm -rf \"$temporary\"" EXIT
        tar --warning=no-unknown-keyword -xf - -C "$temporary"
        # The digest covers regular files only; reject links outright.
        if [ -L "$temporary/provision" ] ||
            find "$temporary/provision" -type l -print -quit | grep -q .; then
            printf "ERROR: transferred devbox bundle contains a symlink\n" >&2
            exit 1
        fi
        [ "$(bundle_digest "$temporary/provision")" = "$digest" ] || {
            printf "ERROR: transferred devbox bundle digest does not match\n" >&2
            exit 1
        }
        printf "%s\n" "$digest" >"$temporary/provision/.devbox-bundle.sha256"
        find "$temporary/provision" -type d -exec chmod 755 {} +
        find "$temporary/provision" -type f -exec chmod 644 {} +
        chown -R root:root "$temporary/provision"
        rm -rf "$target"
        mv "$temporary/provision" "$target"
    ' _ "$digest" <"$archive"
}

# Re-verify the installed provisioning tree against its digest, so a matching
# marker never skips over a corrupted or tampered tree. The payload stays
# single-quoted so it is expanded inside the guest, not here.
# shellcheck disable=SC2016
devbox_guest_bundle_is_valid() {
    local digest="$1"

    devbox_admin_guest sudo bash -c "$DEVBOX_GUEST_BUNDLE_DIGEST"'
        set -Eeuo pipefail
        target=/var/lib/devbox/provision
        [ "$(cat "$target/.devbox-bundle.sha256" 2>/dev/null)" = "$1" ] &&
            ! find "$target" -type l -print -quit | grep -q . &&
            [ "$(bundle_digest "$target")" = "$1" ]
    ' _ "$digest"
}

render_devbox_guest_config() {
    local key

    for key in GIT_NAME GIT_EMAIL POSTGRES_USER POSTGRES_DB POSTGRES_PORT; do
        printf 'export %s=%q\n' "$key" "${!key:-}"
    done
}

# Seed the guest-local configuration and stage the service definition from the
# provisioning bundle. The guest copy is authoritative after the first seed.
stage_devbox_guest_state() {
    render_devbox_guest_config |
        devbox_admin_guest sudo bash "$DEVBOX_GUEST_PROVISION_ROOT/scripts/state.sh"
}

# start/stop/status for the staged services, run as root in the guest.
devbox_services_compose() {
    devbox_admin_guest sudo bash "$DEVBOX_GUEST_PROVISION_ROOT/scripts/services.sh" "$1"
}

devbox_guest_provision_digest() {
    devbox_admin_guest sudo -u "$DEVBOX_GUEST_USER" \
        cat "$DEVBOX_GUEST_HOME/.local/state/devbox/provision.sha256" 2>/dev/null || true
}

run_devbox_guest_provisioning() {
    local digest="$1" archive="$2"

    stream_devbox_bundle "$digest" "$archive" || return
    log "Provisioning devbox guest tools from bundle $digest..."
    devbox_admin_guest sudo bash "$DEVBOX_GUEST_PROVISION_ROOT/scripts/system.sh" || return
    stage_devbox_guest_state || return
    # verify.sh records the digest marker once every check passes. The payload
    # below is single-quoted so it is expanded inside the guest, not here.
    # shellcheck disable=SC2016
    devbox_as_guest env DEVBOX_BUNDLE_DIGEST="$digest" bash -c '
        set -Eeuo pipefail
        bash "$1/tools.sh"
        bash "$1/verify.sh"
    ' _ "$DEVBOX_GUEST_PROVISION_ROOT/scripts"
}

# Print the identity file from Colima's SSH configuration. Colima rewrites the
# Host line to `colima-<profile>`, so resolving it through `ssh -G` with the
# short profile name is unreliable; read the option directly instead. The path
# is quoted by Lima, and a leading ~/ is expanded.
devbox_identity_file() {
    local colima_config="$1" identity_file

    identity_file="$(awk '
        tolower($1) == "identityfile" {
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            if ($0 ~ /^".*"$/) $0 = substr($0, 2, length($0) - 2)
            print
            exit
        }
    ' "$colima_config")"
    # Lima quotes the identity path; the leading ~ is a literal prefix that is
    # stripped string-wise and replaced with $HOME, never expanded as a tilde.
    # shellcheck disable=SC2088
    case "$identity_file" in
        "~/"*) identity_file="$HOME/${identity_file#\~/}" ;;
    esac
    [ -n "$identity_file" ] && [ -r "$identity_file" ] || return 1
    printf '%s\n' "$identity_file"
}

# Authorize the host's Colima SSH key for the unprivileged devbox guest user.
# Colima's own administrative access is untouched.
authorize_devbox_host_key() {
    local colima_config="$1" identity_file

    identity_file="$(devbox_identity_file "$colima_config")" ||
        die "Colima SSH configuration has no readable identity file for $DEVBOX_PROFILE"
    ssh-keygen -y -f "$identity_file" |
        devbox_admin_guest sudo bash "$DEVBOX_GUEST_PROVISION_ROOT/scripts/authorize-key.sh"
}

# Rewrite Colima's SSH configuration into the managed `Host devbox` block: force
# the unprivileged user and disabled agent forwarding, and drop options that
# would override the managed values.
render_devbox_ssh_managed_block() {
    local colima_config="$1"

    awk '
        /^Host[[:space:]]/ {
            print "Host devbox"
            print "  User devbox"
            print "  IdentitiesOnly yes"
            print "  ForwardAgent no"
            next
        }
        /^[[:space:]]*(User|IdentitiesOnly|ForwardAgent|ControlMaster|ControlPath|ControlPersist|ProxyCommand|ProxyJump)[[:space:]]/ { next }
        { print }
    ' "$colima_config"
}

# Write the managed SSH alias. The user adds `Include ~/.ssh/devbox.conf` once
# at the top of ~/.ssh/config; devbox only replaces its own file, and only with
# an alias that is reachable.
write_devbox_ssh_config() {
    local colima_config="$1" staged

    mkdir -p "$HOME/.ssh"
    staged="$(mktemp "$HOME/.ssh/.devbox.conf.XXXXXX")"
    if ! render_devbox_ssh_managed_block "$colima_config" >"$staged" ||
        ! grep -qx 'Host devbox' "$staged" ||
        ! grep -Eqi '^[[:space:]]*HostName[[:space:]]' "$staged" ||
        ! grep -Eqi '^[[:space:]]*Port[[:space:]]' "$staged" ||
        ! grep -Eqi '^[[:space:]]*IdentityFile[[:space:]]' "$staged"; then
        command rm -f "$staged"
        die "Colima returned an invalid devbox SSH configuration"
    fi
    chmod 600 "$staged"
    if ! ssh -F "$staged" -o BatchMode=yes -o ConnectTimeout=10 devbox true >/dev/null 2>&1; then
        command rm -f "$staged"
        die "generated SSH host 'devbox' is not reachable; inspect 'ssh -G devbox' and rerun 'devbox start'"
    fi
    mv "$staged" "$HOME/.ssh/devbox.conf"
}

remove_devbox_ssh_config() {
    command rm -f "$HOME/.ssh/devbox.conf"
}

# Converge the guest from the provisioning bundle, then refresh direct SSH
# access. `start` skips an unchanged, intact bundle; `provision` always runs.
provision_devbox_guest() (
    local mode="$1" work digest

    work="$(mktemp -d "${TMPDIR:-/tmp}/devbox.XXXXXX")"
    # `$work` is final at this point, so expanding it into the trap is safe.
    trap 'command rm -rf "$work"' EXIT
    digest="$(devbox_bundle_digest "$DEVBOX_DIR/provision")"
    if [ "$mode" = start ] && [ "$(devbox_guest_provision_digest)" = "$digest" ] &&
        devbox_guest_bundle_is_valid "$digest"; then
        log "devbox provisioning is current."
        stage_devbox_guest_state
    else
        create_devbox_bundle_archive "$work/bundle.tar"
        # Only authorize direct SSH once the guest passed the provisioning
        # checks; a failed run removes any previously managed access.
        if ! run_devbox_guest_provisioning "$digest" "$work/bundle.tar"; then
            remove_devbox_ssh_config
            return 1
        fi
    fi
    devbox_colima ssh-config "$DEVBOX_PROFILE" >"$work/colima.conf" ||
        die "Colima failed to generate the devbox SSH configuration"
    authorize_devbox_host_key "$work/colima.conf"
    write_devbox_ssh_config "$work/colima.conf"
)

stop_devbox_vm() {
    local force="$1" state=""

    if [ -e "$DEVBOX_COLIMA_PROFILE" ]; then
        state="$(devbox_state)"
    fi
    case "$state" in
        '' | Stopped) log "devbox VM is already stopped." ;;
        Running) devbox_colima stop ${force:+--force} "$DEVBOX_PROFILE" ;;
        *) die "devbox VM is in state '$state'; wait for it to settle and retry" ;;
    esac
}

show_devbox_status() {
    local record=""

    if [ -e "$DEVBOX_COLIMA_PROFILE" ]; then
        record="$(devbox_profile_record)" || die "could not determine the devbox VM state"
    fi
    if [ -z "$record" ]; then
        log "devbox: Not created"
        return
    fi
    printf 'devbox: %s\n' "${record#* }"
}

# Lifecycle commands hold the lock until the process exits; acquire_lock's EXIT
# trap releases it on success and failure alike.
run_devbox() {
    local action="${1:-}" force="" confirm
    shift || true
    configure_devbox_paths

    case "$action" in
        start | provision)
            [ $# -eq 0 ] || die "Usage: devbox $action"
            check_host_platform
            check_devbox_dependencies
            load_env
            acquire_lock lifecycle
            start_devbox_vm
            provision_devbox_guest "$action"
            ;;
        connect)
            [ $# -eq 0 ] || die "Usage: devbox connect"
            require_running_devbox_vm
            devbox_guest_interactive zsh -l
            ;;
        exec)
            [ $# -gt 0 ] || die "Usage: devbox exec <command> [args...]"
            require_running_devbox_vm
            devbox_guest "$@"
            ;;
        status)
            [ $# -eq 0 ] || die "Usage: devbox status"
            show_devbox_status
            ;;
        services)
            case "$*" in
                start | stop | status) ;;
                *) die "Usage: devbox services <start|stop|status>" ;;
            esac
            require_running_devbox_vm
            devbox_services_compose "$1"
            ;;
        auth)
            require_running_devbox_vm
            devbox_guest_interactive devbox auth "$@"
            ;;
        db)
            require_running_devbox_vm
            devbox_guest devbox db "$@"
            ;;
        stop)
            case "$*" in
                '') ;;
                --force) force=1 ;;
                *) die "Usage: devbox stop [--force]" ;;
            esac
            acquire_lock lifecycle
            stop_devbox_vm "$force"
            ;;
        destroy)
            [ $# -eq 0 ] || die "Usage: devbox destroy"
            acquire_lock lifecycle
            if [ -e "$DEVBOX_COLIMA_PROFILE" ]; then
                printf "Type '%s' to delete the devbox VM and all its guest data (the workspace, installed toolchains and caches, service data, and credentials): " "$DEVBOX_PROFILE"
                read -r confirm
                [ "$confirm" = "$DEVBOX_PROFILE" ] || die "Aborted"
                devbox_colima delete --data --force "$DEVBOX_PROFILE"
                log "Destroyed devbox VM runtime data. No host project or data directories were used."
            else
                log "devbox: Not created"
            fi
            remove_devbox_ssh_config
            ;;
        *) die "Usage: devbox <start|provision|connect|exec|status|services|auth|db|stop|destroy>" ;;
    esac
}
