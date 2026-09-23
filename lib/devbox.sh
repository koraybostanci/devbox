#!/bin/bash

DEVBOX_PROFILE="devbox"
DEVBOX_GUEST_USER="devbox"
DEVBOX_GUEST_HOME="/home/$DEVBOX_GUEST_USER"
DEVBOX_GUEST_CONFIG_ROOT="$DEVBOX_GUEST_HOME/.config/devbox"
DEVBOX_GUEST_ROOT="/var/lib/devbox"
DEVBOX_GUEST_PROVISION_ROOT="$DEVBOX_GUEST_ROOT/provision"

configure_devbox_paths() {
    local colima_home state_root

    colima_home="${COLIMA_HOME:-$HOME/.colima}"
    [ "$colima_home" = "$HOME/.colima" ] ||
        die "devbox requires the standard Colima home $HOME/.colima; unset COLIMA_HOME"
    DEVBOX_COLIMA_HOME="$HOME/.colima"
    DEVBOX_LIMA_HOME="$DEVBOX_COLIMA_HOME/_lima"
    case "${LIMA_HOME:-}" in
        '' | "$DEVBOX_LIMA_HOME") ;;
        *) die "devbox requires LIMA_HOME to be unset or $DEVBOX_LIMA_HOME" ;;
    esac
    DEVBOX_CONFIG_ROOT="$HOME/.config/devbox"
    DEVBOX_COLIMA_PROFILE="$DEVBOX_COLIMA_HOME/$DEVBOX_PROFILE"
    DEVBOX_COLIMA_CONFIG="$DEVBOX_COLIMA_PROFILE/colima.yaml"
    DEVBOX_DOCKER_CONFIG="$DEVBOX_CONFIG_ROOT/docker"
    state_root="${XDG_STATE_HOME:-$HOME/.local/state}/devbox"
    DEVBOX_LOCK_DIR="$state_root/locks"
    export DEVBOX_LOCK_DIR
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

devbox_profile_exists() {
    [ -e "$DEVBOX_COLIMA_PROFILE" ]
}

prepare_devbox_docker_config() {
    mkdir -p "$DEVBOX_DOCKER_CONFIG"
    chmod 700 "$DEVBOX_DOCKER_CONFIG"
}

# Run Colima against the devbox profile with an isolated Docker configuration,
# so the VM's Docker context never leaks into the host Docker CLI.
devbox_colima() {
    local colima_bin

    prepare_devbox_docker_config
    colima_bin="$(command -v colima 2>/dev/null || true)"
    [ -n "$colima_bin" ] && [ -x "$colima_bin" ] ||
        die "Missing host dependency: colima"
    COLIMA_HOME="$DEVBOX_COLIMA_HOME" \
        LIMA_HOME="$DEVBOX_LIMA_HOME" \
        DOCKER_CONFIG="$DEVBOX_DOCKER_CONFIG" \
        "$colima_bin" "$@"
}

# Print the `colima list` record for the devbox profile.
devbox_profile_record() {
    devbox_colima list |
        awk -v profile="$DEVBOX_PROFILE" '$1 == profile { print; exit }'
}

devbox_state() {
    local record

    record="$(devbox_profile_record)" || {
        die "could not determine the devbox VM state"
    }
    awk '{ print $2 }' <<<"$record"
}

validate_devbox_colima_config() {
    local file="$1"

    # The rendered colima.yaml is the single source of truth for the remaining
    # profile settings (autoActivate, sshConfig, forwardAgent, portForwarder);
    # only the invariants that must never drift are asserted here.
    grep -qE '^runtime:[[:space:]]*docker$' "$file" &&
        grep -qE '^vmType:[[:space:]]*vz$' "$file" &&
        ! grep -qE '^mounts:' "$file"
}

render_devbox_colima_config() {
    local content temporary

    load_env
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

devbox_as_guest() {
    devbox_admin_guest sudo -u "$DEVBOX_GUEST_USER" -- env \
        HOME="$DEVBOX_GUEST_HOME" \
        PWD="$DEVBOX_GUEST_HOME" \
        bash -c '
        set -Eeuo pipefail
        home="$1"
        shift
        [ -d "$home" ] && [ ! -L "$home" ] || {
            printf "ERROR: devbox guest home is invalid: %s\\n" "$home" >&2
            exit 1
        }
        cd -- "$home"
        export HOME="$home"
        export PWD="$PWD"
        exec "$@"
    ' _ "$DEVBOX_GUEST_HOME" "$@"
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
        cd "$provision_root"
        find . -type f ! -path './.devbox-bundle.sha256' -print | LC_ALL=C sort | while IFS= read -r path; do
            printf '%s\t%s\n' "${path#./}" "$(shasum -a 256 "$path" | awk '{print $1}')"
        done | shasum -a 256 | awk '{print $1}'
    )
}

# Archive the provisioning tree and digest the same bytes. The guest re-computes
# the digest before executing anything, so a tree that changes mid-command fails
# closed instead of shipping unverified content.
create_devbox_bundle_archive() {
    DEVBOX_BUNDLE_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/devbox-bundle.XXXXXX")"
    DEVBOX_BUNDLE_DIGEST="$(devbox_bundle_digest "$DEVBOX_DIR/provision")"
    (
        cd "$DEVBOX_DIR"
        if [ "$(uname -s)" = "Darwin" ]; then
            COPYFILE_DISABLE=1 tar --no-mac-metadata -cf "$DEVBOX_BUNDLE_ARCHIVE" provision
        else
            COPYFILE_DISABLE=1 tar -cf "$DEVBOX_BUNDLE_ARCHIVE" provision
        fi
    )
    chmod 400 "$DEVBOX_BUNDLE_ARCHIVE"
}

# Stream the provisioning tree to the guest and install it as the single
# root-owned, read-only input at /var/lib/devbox/provision. The tree digest is
# re-computed inside the guest before anything is executed.
stream_devbox_bundle() {
    local digest="$1" archive="$2"

    devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        digest="$1"
        root=/var/lib/devbox
        target="$root/provision"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
            printf "ERROR: devbox bundle digest is invalid\n" >&2
            exit 1
        }
        { [ ! -e "$root" ] && [ ! -L "$root" ]; } ||
            { [ -d "$root" ] && [ ! -L "$root" ]; } || {
            printf "ERROR: devbox root directory is invalid\n" >&2
            exit 1
        }
        install -d -o root -g root -m 755 "$root"
        temporary="$(mktemp -d "$root/.provision.XXXXXX")"
        trap "rm -rf \"$temporary\"" EXIT
        tar --warning=no-unknown-keyword -xf - -C "$temporary"
        [ ! -L "$temporary/provision" ] &&
            ! find "$temporary/provision" -type l -print -quit | grep -q . || {
            printf "ERROR: transferred devbox bundle contains a symlink\n" >&2
            exit 1
        }
        [ -f "$temporary/provision/scripts/system.sh" ]
        [ -f "$temporary/provision/scripts/state.sh" ]
        [ -f "$temporary/provision/scripts/tools.sh" ]
        [ -f "$temporary/provision/scripts/verify.sh" ]
        [ -f "$temporary/provision/scripts/authorize-key.sh" ]
        [ -f "$temporary/provision/scripts/services.sh" ]
        bundle_digest() {
            local provision_root="$1"

            (
                cd "$provision_root"
                find . -type f ! -path "./.devbox-bundle.sha256" -print | LC_ALL=C sort | while IFS= read -r path; do
                    printf "%s\\t%s\\n" "${path#./}" "$(sha256sum "$path" | awk "{print \$1}")"
                done | sha256sum | awk "{print \$1}"
            )
        }
        actual="$(bundle_digest "$temporary/provision")"
        [ "$actual" = "$digest" ] || {
            printf "ERROR: transferred devbox bundle digest does not match\n" >&2
            exit 1
        }
        printf "%s\n" "$digest" >"$temporary/provision/.devbox-bundle.sha256"
        find "$temporary/provision" -type d -exec chmod 755 {} +
        find "$temporary/provision" -type f -exec chmod 644 {} +
        chown -R root:root "$temporary/provision"
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ -d "$target" ] && [ ! -L "$target" ] || {
                printf "ERROR: existing devbox provisioning input is not a directory\n" >&2
                exit 1
            }
            rm -rf "$target"
        fi
        mv "$temporary/provision" "$target"
    ' _ "$digest" <"$archive"
}

# Quietly re-verify the installed provisioning tree against its digest, so a
# matching marker never skips over a corrupted or tampered tree.
devbox_guest_bundle_is_valid() {
    local digest="$1"

    devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        digest="$1"
        target=/var/lib/devbox/provision
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 1
        [ -d "$target" ] && [ ! -L "$target" ] || exit 1
        ! find "$target" -type l -print -quit | grep -q . || exit 1
        [ "$(cat "$target/.devbox-bundle.sha256" 2>/dev/null || true)" = "$digest" ] || exit 1
        bundle_digest() {
            local provision_root="$1"

            (
                cd "$provision_root"
                find . -type f ! -path "./.devbox-bundle.sha256" -print | LC_ALL=C sort | while IFS= read -r path; do
                    printf "%s\\t%s\\n" "${path#./}" "$(sha256sum "$path" | awk "{print \$1}")"
                done | sha256sum | awk "{print \$1}"
            )
        }
        [ "$(bundle_digest "$target")" = "$digest" ]
    ' _ "$digest"
}

render_devbox_guest_config() {
    local key value
    local -a guest_keys=(
        GIT_NAME GIT_EMAIL
        POSTGRES_USER POSTGRES_DB POSTGRES_PORT
    )

    for key in "${guest_keys[@]}"; do
        value="${!key:-}"
        printf 'export %s=%s\n' "$key" "$(shell_quote "$value")"
    done
}

# Seed the guest-local configuration and stage the service definition from the
# provisioning bundle. Runs as root; the guest copy is authoritative after the
# first seed.
stage_devbox_guest_state() {
    load_env
    render_devbox_guest_config | devbox_admin_guest sudo env \
        DEVBOX_PROVISION_ROOT="$DEVBOX_GUEST_PROVISION_ROOT" \
        bash "$DEVBOX_GUEST_PROVISION_ROOT/scripts/state.sh"
}

# start/stop/status for the staged services, run as root in the guest.
devbox_services_compose() {
    local action="$1"

    devbox_admin_guest sudo \
        bash "$DEVBOX_GUEST_PROVISION_ROOT/scripts/services.sh" "$action"
}

devbox_guest_provision_digest() {
    devbox_admin_guest sudo bash -c 'cat /home/devbox/.local/state/devbox/provision.sha256 2>/dev/null || true'
}

run_devbox_guest_provisioning() {
    local digest="$1" archive="$2"

    stream_devbox_bundle "$digest" "$archive" || return
    log "Provisioning devbox guest tools from bundle $digest..."
    devbox_admin_guest sudo env \
        DEVBOX_PROVISION_ROOT="$DEVBOX_GUEST_PROVISION_ROOT" \
        DEVBOX_GUEST_USER="$DEVBOX_GUEST_USER" \
        bash "$DEVBOX_GUEST_PROVISION_ROOT/scripts/system.sh" || return
    stage_devbox_guest_state || return
    # verify.sh records the digest marker once every check passes.
    devbox_as_guest env \
        DEVBOX_PROVISION_ROOT="$DEVBOX_GUEST_PROVISION_ROOT" \
        DEVBOX_GUEST_CONFIG_ROOT="$DEVBOX_GUEST_CONFIG_ROOT" \
        DEVBOX_BUNDLE_DIGEST="$digest" \
        bash -c '
        set -Eeuo pipefail
        bash "$DEVBOX_PROVISION_ROOT/scripts/tools.sh"
        bash "$DEVBOX_PROVISION_ROOT/scripts/verify.sh"
    ' || return
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
    case "$identity_file" in
        "~/"*) identity_file="$HOME/${identity_file#\~/}" ;;
    esac
    [ -n "$identity_file" ] && [ -r "$identity_file" ] || return 1
    printf '%s\n' "$identity_file"
}

devbox_host_public_key() {
    local colima_config="$1" identity_file

    identity_file="$(devbox_identity_file "$colima_config")" ||
        die "Colima SSH configuration has no readable identity file for $DEVBOX_PROFILE"
    ssh-keygen -y -f "$identity_file"
}

# Authorize the host's Colima SSH key for the unprivileged devbox guest user.
# Colima's own administrative access is untouched.
authorize_devbox_host_key() {
    local colima_config="$1" key

    key="$(devbox_host_public_key "$colima_config")" || return
    printf '%s\n' "$key" | devbox_admin_guest sudo \
        bash "$DEVBOX_GUEST_PROVISION_ROOT/scripts/authorize-key.sh"
}

# Remove the old devbox marker block while preserving the user's SSH config.
filter_devbox_ssh_config() {
    local config="$1"

    [ -e "$config" ] || return 0
    awk '
        /^# BEGIN devbox[[:space:]]*$/ {
            inside = 1
            next
        }
        /^# END devbox[[:space:]]*$/ {
            if (inside) {
                inside = 0
                next
            }
        }
        inside { next }
        { print }
        END { if (inside) exit 1 }
    ' "$config"
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
# at the top of ~/.ssh/config; devbox only updates its own file afterwards.
write_devbox_ssh_config() {
    local colima_config="$1"
    local ssh_dir="$HOME/.ssh" managed stage_dir staged_managed temporary

    stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/devbox-ssh.XXXXXX")" ||
        die "failed to stage the devbox SSH configuration"
    staged_managed="$stage_dir/devbox.conf"
    render_devbox_ssh_managed_block "$colima_config" >"$staged_managed" || {
        command rm -rf "$stage_dir"
        die "Colima failed to generate the devbox SSH configuration"
    }
    if ! grep -q '^Host devbox$' "$staged_managed" ||
        ! grep -Eqi '^[[:space:]]*HostName[[:space:]]+' "$colima_config" ||
        ! grep -Eqi '^[[:space:]]*Port[[:space:]]+' "$colima_config" ||
        ! grep -q '^[[:space:]]*IdentityFile[[:space:]]' "$staged_managed"; then
        command rm -rf "$stage_dir"
        die "Colima returned an invalid devbox SSH configuration"
    fi
    chmod 600 "$staged_managed" || {
        command rm -rf "$stage_dir"
        die "failed to secure the staged devbox SSH configuration"
    }
    if ! ssh -F "$staged_managed" -o BatchMode=yes -o ConnectTimeout=10 devbox true >/dev/null 2>&1; then
        command rm -rf "$stage_dir"
        die "generated SSH host 'devbox' is not reachable; inspect 'ssh -G devbox' and rerun 'devbox start'"
    fi

    mkdir -p "$ssh_dir" || {
        command rm -rf "$stage_dir"
        die "failed to create the devbox SSH configuration directory"
    }
    [ -d "$ssh_dir" ] && [ ! -L "$ssh_dir" ] || {
        command rm -rf "$stage_dir"
        die "devbox SSH configuration directory is invalid"
    }
    managed="$ssh_dir/devbox.conf"
    temporary="$(mktemp "$ssh_dir/.devbox.conf.XXXXXX")" || {
        command rm -rf "$stage_dir"
        die "failed to stage the devbox SSH configuration"
    }
    cp "$staged_managed" "$temporary" && chmod 600 "$temporary" && mv "$temporary" "$managed" || {
        command rm -rf "$stage_dir" "$temporary"
        die "failed to update $managed"
    }
    command rm -rf "$stage_dir"
}

ensure_devbox_guest_ssh_access() {
    local stage_dir

    stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/devbox-ssh.XXXXXX")" ||
        die "failed to stage the devbox SSH configuration"
    if ! devbox_colima ssh-config "$DEVBOX_PROFILE" >"$stage_dir/colima.conf"; then
        command rm -rf "$stage_dir"
        die "Colima failed to generate the devbox SSH configuration"
    fi
    authorize_devbox_host_key "$stage_dir/colima.conf" || {
        command rm -rf "$stage_dir"
        return 1
    }
    write_devbox_ssh_config "$stage_dir/colima.conf" || {
        command rm -rf "$stage_dir"
        return 1
    }
    command rm -rf "$stage_dir"
}

remove_devbox_ssh_config() {
    local ssh_dir="$HOME/.ssh" config="$HOME/.ssh/config" temporary

    # Remove marker blocks left by older versions, but leave the one-time
    # Include line in place so a later start works without editing user config.
    if [ -f "$config" ] && [ ! -L "$config" ] && grep -q '^# BEGIN devbox[[:space:]]*$' "$config"; then
        temporary="$(mktemp "$ssh_dir/.config.XXXXXX")" || return 1
        if ! filter_devbox_ssh_config "$config" >"$temporary"; then
            command rm -f "$temporary"
            die "$config contains malformed devbox markers"
        fi
        chmod "$(file_mode "$config")" "$temporary" && mv "$temporary" "$config" || {
            command rm -f "$temporary"
            die "failed to update $config"
        }
    fi
    command rm -f "$ssh_dir/devbox.conf"
}

provision_devbox_guest() (
    local force="${1:-false}" host_digest guest_digest

    create_devbox_bundle_archive || return
    trap 'command rm -f "$DEVBOX_BUNDLE_ARCHIVE"' EXIT
    host_digest="$DEVBOX_BUNDLE_DIGEST"
    guest_digest="$(devbox_guest_provision_digest)" || return
    if [ "$force" = false ] && [ "$host_digest" = "$guest_digest" ]; then
        if devbox_guest_bundle_is_valid "$host_digest"; then
            log "devbox provisioning is current."
            stage_devbox_guest_state || return
            ensure_devbox_guest_ssh_access || return
            return
        fi
        log "devbox provisioning bundle is missing or invalid; refreshing."
    fi
    # Only authorize direct SSH once the guest passed the provisioning checks;
    # a failed run removes any previously managed access.
    if ! run_devbox_guest_provisioning "$host_digest" "$DEVBOX_BUNDLE_ARCHIVE"; then
        remove_devbox_ssh_config || true
        return 1
    fi
    ensure_devbox_guest_ssh_access || return
)

stop_devbox_vm() {
    local force="${1:-false}" state

    if [ ! -e "$DEVBOX_COLIMA_PROFILE" ]; then
        log "devbox VM is already stopped."
        return
    fi
    state="$(devbox_state)"
    case "$state" in
        '' | Stopped) log "devbox VM is already stopped." ;;
        Running)
            if [ "$force" = true ]; then
                devbox_colima stop --force "$DEVBOX_PROFILE"
            else
                devbox_colima stop "$DEVBOX_PROFILE"
            fi
            ;;
        *) die "devbox VM is in state '$state'; wait for it to settle and retry" ;;
    esac
}

show_devbox_status() {
    local record

    if [ ! -e "$DEVBOX_COLIMA_PROFILE" ]; then
        log "devbox: Not created"
        return
    fi
    record="$(devbox_profile_record)" || {
        die "could not determine the devbox VM state"
    }
    if [ -z "$record" ]; then
        log "devbox: Not created"
        return
    fi
    printf 'devbox: %s\n' "${record#* }"
}

run_devbox() {
    local action="${1:-}" force=false status
    shift || true
    configure_devbox_paths

    case "$action" in
        start | provision)
            [ $# -eq 0 ] || die "Usage: devbox <start|provision|connect|exec|status|services|auth|db|stop|destroy>"
            check_host_platform
            check_devbox_dependencies
            acquire_lock lifecycle
            start_devbox_vm
            if provision_devbox_guest "$([ "$action" = provision ] && printf true || printf false)"; then
                release_lock
            else
                status=$?
                release_lock
                return "$status"
            fi
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
            case "${1:-}" in
                start | stop | status) ;;
                *) die "Usage: devbox services <start|stop|status>" ;;
            esac
            [ $# -eq 1 ] || die "Usage: devbox services <start|stop|status>"
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
            case "${1:-}" in
                '') ;;
                --force) force=true; shift ;;
                *) die "Usage: devbox stop [--force]" ;;
            esac
            [ $# -eq 0 ] || die "Usage: devbox stop [--force]"
            acquire_lock lifecycle
            stop_devbox_vm "$force"
            release_lock
            ;;
        destroy)
            [ $# -eq 0 ] || die "Usage: devbox destroy"
            acquire_lock lifecycle
            if ! devbox_profile_exists; then
                remove_devbox_ssh_config
                release_lock
                log "devbox: Not created"
                return
            fi
            printf "Type '%s' to delete the devbox VM and all its guest data (the workspace, installed toolchains and caches, service data, and credentials): " "$DEVBOX_PROFILE"
            read -r confirm
            [ "$confirm" = "$DEVBOX_PROFILE" ] || die "Aborted"
            devbox_colima delete --data --force "$DEVBOX_PROFILE" || {
                status=$?
                release_lock
                return "$status"
            }
            remove_devbox_ssh_config
            release_lock
            log "Destroyed devbox VM runtime data. No host project or data directories were used."
            ;;
        *) die "Usage: devbox <start|provision|connect|exec|status|services|auth|db|stop|destroy>" ;;
    esac
}
