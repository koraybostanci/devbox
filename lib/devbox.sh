#!/bin/bash

DEVBOX_PROFILE="devbox"
DEVBOX_OWNER_VERSION="devbox-profile-v2"
DEVBOX_OWNER_LEGACY_VERSION="devbox-profile-v1"
DEVBOX_GUEST_USER="devbox"
DEVBOX_GUEST_HOME="/home/$DEVBOX_GUEST_USER"
DEVBOX_GUEST_CONFIG_ROOT="$DEVBOX_GUEST_HOME/.config/devbox"
DEVBOX_GUEST_ROOT="/var/lib/devbox"
DEVBOX_GUEST_PROVISIONING_ROOT="$DEVBOX_GUEST_ROOT/provisioning"
DEVBOX_SSH_AUTHORIZED_KEYS_FILE='/etc/ssh/authorized_keys/%u'

# A release tree records the data root as the install root; a checkout records
# its own directory. Both the candidate and the data root are canonicalized so
# the comparison is physical on both sides (macOS $HOME below /var versus the
# launcher's /private/var).
devbox_install_root_for() {
    local directory data_root

    directory="$(canonicalize_path "$1")"
    data_root="$(devbox_data_root)"
    case "$directory" in
        "$data_root"/releases/*) printf '%s\n' "$data_root" ;;
        *) printf '%s\n' "$directory" ;;
    esac
}

configure_devbox_paths() {
    local colima_home

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
    DEVBOX_INSTALL_ROOT="$(devbox_install_root_for "$DEVBOX_DIR")"
    DEVBOX_COLIMA_PROFILE="$DEVBOX_COLIMA_HOME/$DEVBOX_PROFILE"
    DEVBOX_COLIMA_CONFIG="$DEVBOX_COLIMA_PROFILE/colima.yaml"
    DEVBOX_COLIMA_OWNER="$DEVBOX_COLIMA_PROFILE/.devbox-owner"
    DEVBOX_DOCKER_CONFIG="$DEVBOX_CONFIG_ROOT/docker"
    DEVBOX_LOCK_DIR="$(devbox_data_root)/locks"
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
    colima_version="$(devbox_colima_raw version | awk 'NR == 1 {print $3}')"
    version_at_least "$colima_version" "$MINIMUM_COLIMA_VERSION" ||
        die "Colima $MINIMUM_COLIMA_VERSION or newer is required (found $colima_version)"
}

check_devbox_ownership() {
    local owner_version owner_path owner_root

    [ -e "$DEVBOX_COLIMA_PROFILE" ] || return 0
    [ -f "$DEVBOX_COLIMA_OWNER" ] ||
        die "Colima profile '$DEVBOX_PROFILE' already exists but is not owned by this devbox installation"
    owner_version="$(sed -n '1p' "$DEVBOX_COLIMA_OWNER")"
    owner_path="$(sed -n '2p' "$DEVBOX_COLIMA_OWNER")"
    case "$owner_version" in
        "$DEVBOX_OWNER_VERSION")
            # Markers written before the data root was canonicalized can hold a
            # logical path; compare physically on the side of the marker too.
            [ "$(canonicalize_path "$owner_path")" = "$DEVBOX_INSTALL_ROOT" ] ||
                die "Colima profile '$DEVBOX_PROFILE' is owned by another devbox installation: $owner_path"
            ;;
        "$DEVBOX_OWNER_LEGACY_VERSION")
            # Legacy markers recorded the exact versioned directory. They still
            # match when both directories resolve to the same install root;
            # rewrite the marker in place and continue.
            owner_root="$(devbox_install_root_for "$owner_path")"
            [ "$owner_root" = "$DEVBOX_INSTALL_ROOT" ] ||
                die "Colima profile '$DEVBOX_PROFILE' was created by $owner_path; stop the VM and run 'devbox install --adopt' to claim it for $DEVBOX_INSTALL_ROOT"
            mark_devbox_profile_owned
            ;;
        *)
            die "Unsupported ownership marker in $DEVBOX_COLIMA_OWNER; stop the VM and run 'devbox install --adopt' to claim it for $DEVBOX_INSTALL_ROOT"
            ;;
    esac
}

devbox_profile_exists() {
    [ -e "$DEVBOX_COLIMA_PROFILE" ]
}

mark_devbox_profile_owned() {
    local temporary

    temporary="$(mktemp "$DEVBOX_COLIMA_PROFILE/.devbox-owner.XXXXXX")"
    printf '%s\n%s\n' "$DEVBOX_OWNER_VERSION" "$DEVBOX_INSTALL_ROOT" >"$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$DEVBOX_COLIMA_OWNER"
}

prepare_devbox_docker_config() {
    mkdir -p "$DEVBOX_DOCKER_CONFIG"
    chmod 700 "$DEVBOX_DOCKER_CONFIG"
}

# Run Colima without consulting the ownership marker, so an unclaimed profile
# can still be inspected (and adopted).
devbox_colima_raw() {
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

devbox_colima() {
    check_devbox_ownership
    devbox_colima_raw "$@"
}

# Claim an existing Colima profile for the current install root. The VM must be
# stopped so the marker never refers to a running profile.
adopt_devbox_profile() {
    local state

    check_host_platform
    check_devbox_dependencies
    # The ownership marker is protocol state shared with start/provision, so
    # write it under the same lock those commands hold.
    acquire_lock lifecycle
    devbox_profile_exists ||
        die "devbox VM profile does not exist yet; run 'devbox start' first"
    state="$(devbox_state_raw)"
    case "$state" in
        Running) die "devbox VM is Running; run 'devbox stop' before adopting the profile" ;;
        '' | Stopped) ;;
        *) die "devbox VM is in state '$state'; wait for it to settle and retry" ;;
    esac
    mark_devbox_profile_owned
    log "Adopted Colima profile '$DEVBOX_PROFILE' for $DEVBOX_INSTALL_ROOT"
}

# Print the `colima list` record for the devbox profile, read through the given
# runner: devbox_colima applies the ownership gate, devbox_colima_raw does not.
devbox_profile_record() {
    local runner="$1"

    "$runner" list |
        awk -v profile="$DEVBOX_PROFILE" '$1 == profile { print; exit }'
}

# Print the state (the second list column) read through the given runner.
devbox_profile_state() {
    local record

    record="$(devbox_profile_record "$1")" || {
        die "could not determine the devbox VM state"
    }
    awk '{ print $2 }' <<<"$record"
}

# Ownership-gated state lookup for commands that must belong to this install.
devbox_state() {
    devbox_profile_state devbox_colima
}

# Ownership-free state lookup, for reporting and for stopping a profile whose
# marker still names another install root (`devbox stop; devbox install --adopt`).
devbox_state_raw() {
    devbox_profile_state devbox_colima_raw
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
    check_devbox_ownership
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
    mark_devbox_profile_owned
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

create_devbox_bundle_snapshot() {
    DEVBOX_BUNDLE_SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/devbox-bundle.XXXXXX")"
    DEVBOX_BUNDLE_ARCHIVE="$DEVBOX_BUNDLE_SNAPSHOT/provision.tar"
    (
        cd "$DEVBOX_DIR"
        COPYFILE_DISABLE=1 tar -cf - provision
    ) | COPYFILE_DISABLE=1 tar -xf - -C "$DEVBOX_BUNDLE_SNAPSHOT"
    find "$DEVBOX_BUNDLE_SNAPSHOT/provision" -type f -exec chmod a-w {} +
    DEVBOX_BUNDLE_DIGEST="$(devbox_bundle_digest "$DEVBOX_BUNDLE_SNAPSHOT/provision")"
    (
        cd "$DEVBOX_BUNDLE_SNAPSHOT"
        if [ "$(uname -s)" = "Darwin" ]; then
            COPYFILE_DISABLE=1 tar --no-mac-metadata -cf "$DEVBOX_BUNDLE_ARCHIVE" provision
        else
            COPYFILE_DISABLE=1 tar -cf "$DEVBOX_BUNDLE_ARCHIVE" provision
        fi
    )
    chmod 400 "$DEVBOX_BUNDLE_ARCHIVE"
}

stream_devbox_bundle() {
    local digest="$1" archive="$2"

    devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        digest="$1"
        root=/var/lib/devbox/bundles
        target="$root/$digest"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
            printf "ERROR: devbox bundle digest is invalid\n" >&2
            exit 1
        }
        { [ ! -e /var/lib/devbox ] && [ ! -L /var/lib/devbox ]; } ||
            { [ -d /var/lib/devbox ] && [ ! -L /var/lib/devbox ]; } || {
            printf "ERROR: devbox root bundle directory is invalid\n" >&2
            exit 1
        }
        install -d -o root -g root -m 755 /var/lib/devbox
        { [ ! -e "$root" ] && [ ! -L "$root" ]; } ||
            { [ -d "$root" ] && [ ! -L "$root" ]; } || {
            printf "ERROR: devbox root bundle directory is invalid\n" >&2
            exit 1
        }
        install -d -o root -g root -m 700 "$root"
        [ -d "$root" ] && [ ! -L "$root" ] || {
            printf "ERROR: devbox root bundle directory is invalid\n" >&2
            exit 1
        }
        chmod 700 "$root"
        temporary="$(mktemp -d "$root/.bundle.XXXXXX")"
        trap "rm -rf \"$temporary\"" EXIT
        tar --warning=no-unknown-keyword -xf - -C "$temporary"
        [ ! -L "$temporary/provision" ] &&
            ! find "$temporary/provision" -type l -print -quit | grep -q . || {
            printf "ERROR: transferred devbox bundle contains a symlink\n" >&2
            exit 1
        }
        [ -f "$temporary/provision/scripts/system.sh" ]
        [ -f "$temporary/provision/scripts/tools.sh" ]
        [ -f "$temporary/provision/scripts/verify.sh" ]
        bundle_digest() {
            local provision_root="$1"

            (
                cd "$provision_root"
                find . -type f ! -path "./.devbox-bundle.sha256" -print | LC_ALL=C sort | while IFS= read -r path; do
                    printf "%s\\t%s\\n" "${path#./}" "$(sha256sum "$path" | awk "{print \$1}")"
                done | sha256sum | awk "{print \$1}"
            )
        }
        actual="$(
            bundle_digest "$temporary/provision"
        )"
        [ "$actual" = "$digest" ] || {
            printf "ERROR: transferred devbox bundle digest does not match\n" >&2
            exit 1
        }
        printf "%s\n" "$digest" >"$temporary/provision/.devbox-bundle.sha256"
        find "$temporary/provision" -type d -exec chmod 700 {} +
        find "$temporary/provision" -type f -exec chmod 600 {} +
        chown -R root:root "$temporary/provision"
        if [ -d "$target" ]; then
            [ ! -L "$target" ] || {
                printf "ERROR: existing devbox bundle is not a directory\n" >&2
                exit 1
            }
            ! find "$target" -type l -print -quit | grep -q . || {
                printf "ERROR: existing devbox bundle contains a symlink\n" >&2
                exit 1
            }
            cached="$(bundle_digest "$target")"
            if [ "$(cat "$target/.devbox-bundle.sha256" 2>/dev/null || true)" = "$digest" ] && [ "$cached" = "$digest" ]; then
                find "$target" -type d -exec chmod 700 {} +
                find "$target" -type f -exec chmod 600 {} +
                chown -R root:root "$target"
                exit 0
            fi
            backup="$(mktemp -d "$root/.bundle-corrupt.XXXXXX")"
            rmdir "$backup"
            mv "$target" "$backup" || {
                printf "ERROR: unable to replace corrupt cached devbox bundle\n" >&2
                exit 1
            }
            mv "$temporary/provision" "$target" || {
                mv "$backup" "$target" || true
                printf "ERROR: verified devbox bundle could not be installed\n" >&2
                exit 1
            }
            rm -rf "$backup"
        elif [ -e "$target" ] || [ -L "$target" ]; then
            printf "ERROR: existing devbox bundle is not a directory\n" >&2
            exit 1
        else
            mv "$temporary/provision" "$target"
        fi
    ' _ "$digest" <"$archive"
}

devbox_guest_bundle_is_valid() {
    local digest="$1"

    devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        digest="$1"
        target="/var/lib/devbox/bundles/$digest"
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
        actual="$(
            bundle_digest "$target"
        )"
        [ "$actual" = "$digest" ]
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

# Establish the guest-local devbox configuration:
#   config  - non-secret defaults; seeded once, then the guest is authoritative.
#   secrets - service secrets; always generated inside the guest, never seeded
#             from the host.
sync_devbox_guest_config() {
    load_env
    render_devbox_guest_config | devbox_as_guest env \
        DEVBOX_GUEST_CONFIG_ROOT="$DEVBOX_GUEST_CONFIG_ROOT" \
        bash -c '
        set -Eeuo pipefail
        umask 077
        directory="$DEVBOX_GUEST_CONFIG_ROOT"
        mkdir -p "$directory"
        config="$directory/config"
        secrets="$directory/secrets"
        # Drop the superseded host-seeded env file from earlier devbox guests.
        rm -f "$directory/env"
        if [ ! -s "$config" ] || ! grep -q "^export POSTGRES_USER=" "$config" 2>/dev/null; then
            temporary="$(mktemp "$directory/.config.XXXXXX")"
            cat >"$temporary"
            chmod 600 "$temporary"
            mv "$temporary" "$config"
        else
            cat >/dev/null
        fi
        if [ ! -e "$secrets" ]; then
            temporary="$(mktemp "$directory/.secrets.XXXXXX")"
            : >"$temporary"
        else
            temporary="$(mktemp "$directory/.secrets.XXXXXX")"
            cat "$secrets" >"$temporary"
        fi
        # Generate any missing service secret, preserving existing values.
        grep -q "^export POSTGRES_PASSWORD=" "$temporary" ||
            printf "export POSTGRES_PASSWORD=%s\\n" \
                "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d " \\n")" >>"$temporary"
        grep -q "^export VALKEY_PASSWORD=" "$temporary" ||
            printf "export VALKEY_PASSWORD=%s\\n" \
                "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d " \\n")" >>"$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$secrets"
    '
}

# Bring up the root-managed devbox services (PostgreSQL and Valkey) in the guest.
# The definition and credentials stay root-owned; the devbox user only reads
# its client credentials from ~/.config/devbox/secrets.
run_devbox_services() {
    local digest="$1"

    devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        digest="$1"
        provisioning="/var/lib/devbox/provisioning/$digest"
        services=/var/lib/devbox/services
        config=/home/devbox/.config/devbox/config
        secrets=/home/devbox/.config/devbox/secrets
        compose_source="$provisioning/config/services/compose.yaml"
        [ -d "$provisioning" ] && [ ! -L "$provisioning" ] || {
            printf "ERROR: devbox provisioning input is unavailable\\n" >&2
            exit 1
        }
        [ -f "$compose_source" ] && [ ! -L "$compose_source" ] || {
            printf "ERROR: devbox service definition is unavailable\\n" >&2
            exit 1
        }
        [ -r "$config" ] && [ -r "$secrets" ] || {
            printf "ERROR: devbox guest configuration or secrets are unavailable\\n" >&2
            exit 1
        }
        mkdir -p "$services/data/postgres" "$services/data/valkey"
        chmod 700 "$services"
        set -a
        . "$config"
        . "$secrets"
        set +a
        missing=
        [ -n "${POSTGRES_USER:-}" ] || missing="$missing POSTGRES_USER"
        [ -n "${POSTGRES_DB:-}" ] || missing="$missing POSTGRES_DB"
        [ -n "${POSTGRES_PORT:-}" ] || missing="$missing POSTGRES_PORT"
        [ -n "${POSTGRES_PASSWORD:-}" ] || missing="$missing POSTGRES_PASSWORD"
        [ -n "${VALKEY_PASSWORD:-}" ] || missing="$missing VALKEY_PASSWORD"
        [ -z "$missing" ] || {
            printf "ERROR: devbox service credentials are missing:%s\\n" "$missing" >&2
            printf "devbox guest config:\\n" >&2
            cat "$config" >&2 || true
            exit 1
        }
        VALKEY_PORT="${VALKEY_PORT:-16379}"
        umask 077
        envfile="$services/env"
        temporary="$(mktemp "$services/.env.XXXXXX")"
        {
            printf "POSTGRES_USER=%s\\n" "$POSTGRES_USER"
            printf "POSTGRES_DB=%s\\n" "$POSTGRES_DB"
            printf "POSTGRES_PORT=%s\\n" "$POSTGRES_PORT"
            printf "POSTGRES_PASSWORD=%s\\n" "$POSTGRES_PASSWORD"
            printf "VALKEY_PORT=%s\\n" "$VALKEY_PORT"
            printf "VALKEY_PASSWORD=%s\\n" "$VALKEY_PASSWORD"
        } >"$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$envfile"
        compose="$services/compose.yaml"
        temporary="$(mktemp "$services/.compose.XXXXXX")"
        cat "$compose_source" >"$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$compose"
        docker compose --project-name devbox --env-file "$envfile" -f "$compose" up -d --wait
    ' _ "$digest"
}

show_devbox_services_status() {
    devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        services=/var/lib/devbox/services
        [ -f "$services/compose.yaml" ] || {
            printf "devbox services are not provisioned\\n" >&2
            exit 1
        }
        docker compose --project-name devbox \
            --env-file "$services/env" -f "$services/compose.yaml" ps
    '
}

devbox_guest_provision_digest() {
    devbox_admin_guest bash -c 'cat "$HOME/.local/state/devbox/provision.sha256" 2>/dev/null || true'
}

run_devbox_guest_provisioning() {
    local digest="$1" archive="$2"

    stream_devbox_bundle "$digest" "$archive" || return
    log "Provisioning devbox guest tools from bundle $digest..."
    if ! devbox_admin_guest bash -c '
        set -Eeuo pipefail
        export DEVBOX_PROVISION_ROOT="/var/lib/devbox/bundles/$1"
        sudo env DEVBOX_PROVISION_ROOT="$DEVBOX_PROVISION_ROOT" \
            DEVBOX_GUEST_USER=devbox \
            bash "$DEVBOX_PROVISION_ROOT/scripts/system.sh"
    ' _ "$digest"; then
        require_devbox_guest_preflight
        return 1
    fi
    require_devbox_guest_preflight
    run_devbox_root_apps "$digest" || return
    stage_devbox_guest_provisioning_input "$digest" || return
    sync_devbox_guest_config || return
    ensure_devbox_guest_ssh_access || return
    run_devbox_services "$digest" || return
    devbox_as_guest env \
        DEVBOX_PROVISION_ROOT="$DEVBOX_GUEST_PROVISIONING_ROOT/$digest" \
        DEVBOX_GUEST_CONFIG_ROOT="$DEVBOX_GUEST_CONFIG_ROOT" \
        bash -c '
        set -Eeuo pipefail
        bash "$DEVBOX_PROVISION_ROOT/scripts/tools.sh"
        bash "$DEVBOX_PROVISION_ROOT/scripts/verify.sh"
    ' || return
    printf '%s\n' "$digest" | devbox_admin_guest bash -c '
        set -Eeuo pipefail
        umask 077
        directory="$HOME/.local/state/devbox"
        mkdir -p "$directory"
        temporary="$(mktemp "$directory/.provision.XXXXXX")"
        cat >"$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$directory/provision.sha256"
    ' || return
}

run_devbox_root_apps() {
    local digest="$1"

    devbox_admin_guest bash -c '
        set -Eeuo pipefail
        export DEVBOX_PROVISION_ROOT="/var/lib/devbox/bundles/$1"
        sudo env DEVBOX_PROVISION_ROOT="$DEVBOX_PROVISION_ROOT" bash -s <<'"'"'ROOT_APPS'"'"'
set -Eeuo pipefail
source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/apps.sh"
set -a
source "$DEVBOX_PROVISION_ROOT/versions.env"
set +a
install_databricks
ROOT_APPS
    ' _ "$digest"
}

stage_devbox_guest_provisioning_input() {
    local digest="$1"

    devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        digest="$1"
        root=/var/lib/devbox
        source_root="$root/bundles/$digest"
        parent="$root/provisioning"
        target_root="$parent/$digest"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
            printf "ERROR: devbox provisioning digest is invalid\n" >&2
            exit 1
        }
        [ -d "$root" ] && [ ! -L "$root" ] || {
            printf "ERROR: devbox root provisioning directory is invalid\\n" >&2
            exit 1
        }
        [ -d "$source_root" ] && [ ! -L "$source_root" ] || {
            printf "ERROR: devbox root provisioning bundle is invalid\\n" >&2
            exit 1
        }
        ! find "$source_root" -type l -print -quit | grep -q . || {
            printf "ERROR: devbox root provisioning bundle contains a symlink\\n" >&2
            exit 1
        }
        [ -d "$parent" ] && [ ! -L "$parent" ] || {
            [ ! -e "$parent" ] && [ ! -L "$parent" ] || {
                printf "ERROR: devbox root provisioning input directory is invalid\\n" >&2
                exit 1
            }
            install -d -o root -g root -m 755 "$parent"
        }
        temporary="$(mktemp -d "$parent/.provision.XXXXXX")"
        trap "rm -rf \"$temporary\"" EXIT
        tar -C "$source_root" -cf - . | tar -xf - -C "$temporary"
        ! find "$temporary" -type l -print -quit | grep -q . || {
            printf "ERROR: devbox root provisioning input contains a symlink\\n" >&2
            exit 1
        }
        find "$temporary" -type d -exec chmod 755 {} +
        find "$temporary" -type f -exec chmod 644 {} +
        chown -R root:root "$temporary"
        if [ -d "$target_root" ]; then
            [ ! -L "$target_root" ] || {
                printf "ERROR: devbox guest provisioning input is not a directory\\n" >&2
                exit 1
            }
            rm -rf "$target_root"
        elif [ -e "$target_root" ] || [ -L "$target_root" ]; then
            printf "ERROR: devbox guest provisioning input is not a directory\\n" >&2
            exit 1
        fi
        mv "$temporary" "$target_root"
    ' _ "$digest"
}

# Print the value of an SSH configuration directive from Colima's devbox SSH
# configuration. The directive matches case-insensitively, a quoted value may
# only be followed by whitespace or a comment, and the first match wins.
# Fails when the directive is absent.
devbox_colima_ssh_config_value() {
    local directive="$1" value

    value="$(devbox_colima ssh-config "$DEVBOX_PROFILE" | awk -v wanted="$directive" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            field = line
            sub(/[[:space:]].*$/, "", field)
            if (tolower(field) != tolower(wanted)) next
            if (line !~ /^[^[:space:]]+[[:space:]]+/) next
            sub(/^[^[:space:]]+[[:space:]]+/, "", line)
            if (substr(line, 1, 1) == "\"") {
                line = substr(line, 2)
                closing_quote = index(line, "\"")
                if (closing_quote == 0) next
                suffix = substr(line, closing_quote + 1)
                if (suffix !~ /^[[:space:]]*(#.*)?$/) next
                print substr(line, 1, closing_quote - 1)
                exit
            }
            sub(/[[:space:]].*$/, "", line)
            if (length(line) > 0) {
                print line
                exit
            }
        }
    ')" || return
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

devbox_host_public_key() {
    local identity_file

    identity_file="$(devbox_colima_ssh_config_value identityfile)" || true
    [ -n "$identity_file" ] && [ -r "$identity_file" ] ||
        die "Colima SSH configuration has no readable identity file for $DEVBOX_PROFILE"
    ssh-keygen -y -f "$identity_file"
}

devbox_host_ssh_user() {
    local user

    user="$(devbox_colima_ssh_config_value user)" || true
    [ -n "$user" ] || die "Colima SSH configuration has no user for $DEVBOX_PROFILE"
    printf '%s\n' "$user"
}

devbox_sshd_authorized_keys_config() {
    printf "AuthorizedKeysFile %s\n" "$DEVBOX_SSH_AUTHORIZED_KEYS_FILE"
}

devbox_guest_identity_is_safe() {
    local guest_user="$1"
    local guest_uid="$2"
    local guest_gid="$3"
    local group_name="$4"
    local group_gid="$5"
    local group_members="$6"
    local group_names="$7"
    local uid_matches="$8"
    local gid_matches="$9"

    [ "$guest_uid" -gt 0 ] 2>/dev/null &&
        [ "$guest_gid" -gt 0 ] 2>/dev/null &&
        [ "$group_name" = "$guest_user" ] &&
        [ "$group_gid" = "$guest_gid" ] &&
        [ "$uid_matches" -eq 1 ] 2>/dev/null &&
        [ "$gid_matches" -eq 1 ] 2>/dev/null || return 1
    case "$group_members" in ''|"$guest_user") ;; *) return 1 ;; esac
    [ "$group_names" = "$guest_user" ] || return 1
}

validate_devbox_guest_identity() {
    local identity
    local guest_uid guest_gid group_name group_gid group_members group_names uid_matches gid_matches extra

    identity="$(devbox_admin_guest bash -c '
        user="$1"
        passwd_entry="$(getent passwd "$user" || true)"
        guest_uid="$(printf "%s\\n" "$passwd_entry" | cut -d: -f3)"
        guest_gid="$(printf "%s\\n" "$passwd_entry" | cut -d: -f4)"
        group_entry="$(getent group "$guest_gid" || true)"
        group_name="$(printf "%s\\n" "$group_entry" | cut -d: -f1)"
        group_gid="$(printf "%s\\n" "$group_entry" | cut -d: -f3)"
        group_members="$(printf "%s\\n" "$group_entry" | cut -d: -f4)"
        group_names="$(id -nG "$user")"
        uid_matches="$(getent passwd | awk -F: -v uid="$guest_uid" '\''$3 == uid { count++ } END { print count + 0 }'\'')"
        gid_matches="$(getent group | awk -F: -v gid="$guest_gid" '\''$3 == gid { count++ } END { print count + 0 }'\'')"
        printf "%s:%s:%s:%s:%s:%s:%s:%s\\n" \
            "$guest_uid" "$guest_gid" "$group_name" "$group_gid" "$group_members" "$group_names" "$uid_matches" "$gid_matches"
    ' _ "$DEVBOX_GUEST_USER")" || return 1
    IFS=: read -r guest_uid guest_gid group_name group_gid group_members group_names uid_matches gid_matches extra <<<"$identity"
    [ -z "$extra" ] || return 1
    devbox_guest_identity_is_safe \
        "$DEVBOX_GUEST_USER" "$guest_uid" "$guest_gid" "$group_name" "$group_gid" "$group_members" "$group_names" \
        "$uid_matches" "$gid_matches"
}

validate_devbox_guest_privileges() {
    devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        user="$1"
        sudo_status=0
        sudo_listing="$(LC_ALL=C sudo -n -l -U "$user" 2>&1)" || sudo_status=$?
        { [ "$sudo_status" -eq 0 ] || [ "$sudo_status" -eq 1 ]; } || {
            printf "ERROR: failed to inspect devbox guest sudo privileges\n" >&2
            exit 1
        }
        expected="User $user is not allowed to run sudo on "
        no_sudo_privileges=false
        case "$sudo_listing" in
            "$expected"*.)
                sudo_host="${sudo_listing#"$expected"}"
                sudo_host="${sudo_host%.}"
                case "$sudo_host" in
                    "" | *[![:alnum:]._-]*) ;;
                    *) no_sudo_privileges=true ;;
                esac
                ;;
        esac
        [ "$no_sudo_privileges" = true ] || {
            printf "ERROR: devbox guest user has sudo privileges\n" >&2
            exit 1
        }
        if sudo -u "$user" -- sudo -n true >/dev/null 2>&1; then
            printf "ERROR: devbox guest user can execute passwordless sudo\n" >&2
            exit 1
        fi
        if [ -S /var/run/docker.sock ] && sudo -u "$user" -- test -w /var/run/docker.sock; then
            printf "ERROR: devbox guest user can write the Docker socket\n" >&2
            exit 1
        fi
    ' _ "$DEVBOX_GUEST_USER"
}

validate_devbox_guest_preflight() {
    validate_devbox_guest_identity && validate_devbox_guest_privileges
}

# Fail closed when the guest identity or privileges are unsafe: revoke the
# managed direct SSH access this installation granted before aborting.
require_devbox_guest_preflight() {
    validate_devbox_guest_preflight || {
        revoke_devbox_guest_ssh_access ||
            die "devbox guest user has unsafe identity or privileges; managed direct SSH access could not be fully removed"
        die "devbox guest user has unsafe identity or privileges; managed direct SSH access was removed"
    }
}

reconcile_devbox_guest_workspace() {
    devbox_as_guest bash -c '
        set -Eeuo pipefail
        workspace="$HOME/workspace"
        [ -d "$HOME" ] && [ ! -L "$HOME" ] || {
            printf "ERROR: devbox guest home is invalid: %s\\n" "$HOME" >&2
            exit 1
        }
        [ ! -L "$workspace" ] || {
            printf "ERROR: devbox guest workspace must be a real directory: %s\\n" "$workspace" >&2
            exit 1
        }
        [ ! -e "$workspace" ] || [ -d "$workspace" ] || {
            printf "ERROR: devbox guest workspace must be a real directory: %s\\n" "$workspace" >&2
            exit 1
        }
        mkdir -p "$workspace"
        [ -d "$workspace" ] && [ ! -L "$workspace" ] && [ -O "$workspace" ] && [ -G "$workspace" ] || {
            printf "ERROR: devbox guest workspace has unsafe ownership: %s\\n" "$workspace" >&2
            exit 1
        }
        chmod 700 "$workspace"
    '
}

authorize_devbox_host_key() {
    local sshd_settings admin_user

    sshd_settings="$(devbox_sshd_authorized_keys_config)"
    admin_user="$(devbox_host_ssh_user)" || return
    devbox_host_public_key | devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        guest_user="$2"
        admin_user="$3"
        sshd_settings="$1"
        keys_dir=/etc/ssh/authorized_keys
        sshd_config=/etc/ssh/sshd_config.d/00-devbox.conf
        key="$(cat)"
        [ -n "$key" ] && [ "$(printf "%s\\n" "$key" | wc -l | tr -d " ")" = 1 ] || {
            printf "ERROR: invalid devbox host SSH public key\\n" >&2
            exit 1
        }
        for user in "$guest_user" "$admin_user"; do
            [[ "$user" =~ ^[A-Za-z0-9_.-]+$ ]] || {
                printf "ERROR: invalid devbox SSH user: %s\\n" "$user" >&2
                exit 1
            }
        done
        [ -d /etc/ssh ] && [ ! -L /etc/ssh ] || {
            printf "ERROR: OpenSSH configuration directory is invalid\\n" >&2
            exit 1
        }
        { [ ! -e "$keys_dir" ] && [ ! -L "$keys_dir" ]; } ||
            { [ -d "$keys_dir" ] && [ ! -L "$keys_dir" ]; } || {
            printf "ERROR: OpenSSH authorized keys directory is invalid\\n" >&2
            exit 1
        }
        install -d -o root -g root -m 755 "$keys_dir"
        for user in "$guest_user" "$admin_user"; do
            authorized="$keys_dir/$user"
            temporary="$(mktemp "$keys_dir/.${user}.XXXXXX")"
            printf "%s\\n" "$key" >"$temporary"
            chown root:root "$temporary"
            # sshd reads AuthorizedKeysFile as the target user, not as root, so
            # the file must be readable by that user; it holds only a public key.
            chmod 644 "$temporary"
            mv "$temporary" "$authorized"
        done
        [ -d /etc/ssh/sshd_config.d ] && [ ! -L /etc/ssh/sshd_config.d ] &&
            [ ! -L "$sshd_config" ] || {
            printf "ERROR: OpenSSH drop-in directory is invalid\\n" >&2
            exit 1
        }
        temporary="$(mktemp /etc/ssh/sshd_config.d/.devbox.XXXXXX)"
        printf "%s\\n" "$sshd_settings" >"$temporary"
        chown root:root "$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$sshd_config"
        sshd -t
        for user in "$guest_user" "$admin_user"; do
            effective="$(sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null)" || {
                printf "ERROR: devbox SSH configuration test failed for %s\\n" "$user" >&2
                sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" >&2 || true
                exit 1
            }
            printf "%s\\n" "$effective" | grep -Fqx "authorizedkeysfile /etc/ssh/authorized_keys/%u" || {
                printf "ERROR: devbox SSH authorized-keys policy is not effective for %s\\n" "$user" >&2
                printf "  drop-in %s: %s\\n" "$sshd_config" "$(cat "$sshd_config" 2>&1 || true)" >&2
                printf "  effective: %s\\n" "$(printf "%s\\n" "$effective" | grep -i authorizedkeysfile || true)" >&2
                printf "  include: %s\\n" "$(grep -n "Include" /etc/ssh/sshd_config 2>&1 || true)" >&2
                printf "  drop-ins: %s\\n" "$(ls -1 /etc/ssh/sshd_config.d 2>&1 | tr "\\n" " " || true)" >&2
                printf "  run-sshd: %s\\n" "$([ -d /run/sshd ] && printf present || printf missing)" >&2
                exit 1
            }
        done
        systemctl reload ssh
    ' _ "$sshd_settings" "$DEVBOX_GUEST_USER" "$admin_user"
}

remove_devbox_managed_guest_ssh_authorization() {
    devbox_admin_guest sudo bash -c '
        set -Eeuo pipefail
        authorized=/etc/ssh/authorized_keys/devbox
        [ ! -e "$authorized" ] && [ ! -L "$authorized" ] && exit 0
        [ -f "$authorized" ] && [ ! -L "$authorized" ] &&
            [ "$(stat -c "%u:%g" "$authorized")" = 0:0 ] || {
            printf "ERROR: managed devbox SSH authorization is invalid: %s\\n" "$authorized" >&2
            exit 1
        }
        rm -f -- "$authorized"
    '
}

stage_devbox_host_ssh_config() {
    local managed_config="$1"
    local config="$2"
    local temporary="$3"
    local begin_marker='# BEGIN devbox' end_marker='# END devbox'

    if [ -e "$config" ]; then
        awk -v managed_config="$managed_config" '
            function insert_managed_config(    line) {
                print "# BEGIN devbox"
                while ((getline line < managed_config) > 0) print line
                close(managed_config)
                print "# END devbox"
                print ""
                inserted = 1
            }
            /^[[:space:]]*#+[[:space:]]*BEGIN[[:space:]]+devbox[[:space:]]*$/ {
                if (skipping) bad = 1
                skipping = 1
                next
            }
            /^[[:space:]]*#+[[:space:]]*END[[:space:]]+devbox[[:space:]]*$/ {
                if (!skipping) bad = 1
                skipping = 0
                next
            }
            skipping { next }
            !inserted && /^[[:space:]]*([Hh][Oo][Ss][Tt]|[Mm][Aa][Tt][Cc][Hh])[[:space:]]/ {
                insert_managed_config()
            }
            { print }
            END {
                if (skipping) bad = 1
                if (bad) exit 1
                if (!inserted) insert_managed_config()
            }
        ' "$config" >"$temporary" || return 1
    else
        {
            printf '%s\n' "$begin_marker"
            cat "$managed_config"
            printf '%s\n' "$end_marker"
        } >"$temporary" || return 1
    fi
}

# Remove the managed devbox block from a source configuration into a
# destination file. Markers are recognized tolerantly (leading whitespace,
# extra '#', trailing whitespace), so duplicate and legacy-spelled blocks are
# all removed and the result is normalized. Returns nonzero when the structure
# is malformed -- a BEGIN inside a block (nested), an END outside a block
# (orphan), or EOF while inside a block (unterminated) -- or when the source
# cannot be read; the caller discards the destination on failure.
strip_devbox_ssh_block() {
    local config="$1" destination="$2"

    [ -e "$config" ] || return 1
    awk '
        /^[[:space:]]*#+[[:space:]]*BEGIN[[:space:]]+devbox[[:space:]]*$/ {
            if (skipping) bad = 1
            skipping = 1
            next
        }
        /^[[:space:]]*#+[[:space:]]*END[[:space:]]+devbox[[:space:]]*$/ {
            if (!skipping) bad = 1
            skipping = 0
            next
        }
        skipping { next }
        { print }
        END {
            if (skipping) bad = 1
            if (bad) exit 1
        }
    ' "$config" >"$destination"
}

devbox_effective_ssh_value() {
    local configuration="$1" key="$2"

    awk -v key="$key" '
        $1 == key {
            $1 = ""
            sub(/^[[:space:]]+/, "")
            print
        }
    ' <<<"$configuration"
}

validate_devbox_effective_ssh_config() {
    local source_config="$1" managed_config="$2" effective_config
    local expected_hostname expected_port expected_identity actual_identity
    local controlmaster controlpath proxycommand proxyjump value

    effective_config="$(ssh -F "$managed_config" -G devbox 2>/dev/null)" || {
        printf 'ERROR: devbox SSH effective configuration could not be computed\n' >&2
        return 1
    }
    expected_hostname="$(devbox_effective_ssh_value "$source_config" hostname)"
    expected_port="$(devbox_effective_ssh_value "$source_config" port)"
    expected_identity="$(devbox_effective_ssh_value "$source_config" identityfile)"
    actual_identity="$(devbox_effective_ssh_value "$effective_config" identityfile)"
    [ -n "$expected_hostname" ] && [ -n "$expected_port" ] && [ -n "$expected_identity" ] || {
        printf 'ERROR: Colima devbox SSH configuration lacks hostname, port, or identity\n' >&2
        return 1
    }
    value="$(devbox_effective_ssh_value "$effective_config" user)"
    [ "$value" = "$DEVBOX_GUEST_USER" ] || {
        printf 'ERROR: devbox SSH effective user is %s, expected %s\n' "$value" "$DEVBOX_GUEST_USER" >&2
        return 1
    }
    value="$(devbox_effective_ssh_value "$effective_config" identitiesonly)"
    [ "$value" = yes ] || {
        printf 'ERROR: devbox SSH effective IdentitiesOnly is %s\n' "$value" >&2
        return 1
    }
    value="$(devbox_effective_ssh_value "$effective_config" forwardagent)"
    [ "$value" = no ] || {
        printf 'ERROR: devbox SSH effective ForwardAgent is %s\n' "$value" >&2
        return 1
    }
    controlmaster="$(devbox_effective_ssh_value "$effective_config" controlmaster)"
    case "$controlmaster" in no | false) ;; *)
        printf 'ERROR: devbox SSH effective ControlMaster is %s\n' "$controlmaster" >&2
        return 1
        ;;
    esac
    controlpath="$(devbox_effective_ssh_value "$effective_config" controlpath)"
    case "$controlpath" in '' | none) ;; *)
        printf 'ERROR: devbox SSH effective ControlPath is %s\n' "$controlpath" >&2
        return 1
        ;;
    esac
    proxycommand="$(devbox_effective_ssh_value "$effective_config" proxycommand)"
    [ -n "$proxycommand" ] || proxycommand=none
    [ "$proxycommand" = none ] || {
        printf 'ERROR: devbox SSH effective ProxyCommand is %s\n' "$proxycommand" >&2
        return 1
    }
    proxyjump="$(devbox_effective_ssh_value "$effective_config" proxyjump)"
    [ -n "$proxyjump" ] || proxyjump=none
    [ "$proxyjump" = none ] || {
        printf 'ERROR: devbox SSH effective ProxyJump is %s\n' "$proxyjump" >&2
        return 1
    }
    value="$(devbox_effective_ssh_value "$effective_config" hostname)"
    [ "$value" = "$expected_hostname" ] || {
        printf 'ERROR: devbox SSH effective hostname is %s, expected %s\n' "$value" "$expected_hostname" >&2
        return 1
    }
    value="$(devbox_effective_ssh_value "$effective_config" port)"
    [ "$value" = "$expected_port" ] || {
        printf 'ERROR: devbox SSH effective port is %s, expected %s\n' "$value" "$expected_port" >&2
        return 1
    }
    # OpenSSH accumulates IdentityFile across every matching block, so a
    # `Host *` block in the user configuration legitimately appends extra
    # identities after the managed one. Require the managed identity (or
    # identities) to come first, which is what makes the dedicated devbox key win;
    # do not reject inherited extras that follow it.
    case "$actual_identity" in
        "$expected_identity") ;;
        "$expected_identity"$'\n'*) ;;
        *)
            printf 'ERROR: devbox SSH effective identity does not start with the managed identity\n' >&2
            printf '  expected first: %s\n' "$expected_identity" >&2
            printf '  effective: %s\n' "$actual_identity" >&2
            return 1
            ;;
    esac
}

# Remove the legacy ~/.ssh/config.d/devbox mirror written by older devbox
# versions. It is deleted only when it is a regular file that contains the
# devbox Host entry; any other content under config.d is left untouched.
cleanup_devbox_ssh_config_mirror() {
    local mirror_dir="$HOME/.ssh/config.d" mirror="$HOME/.ssh/config.d/devbox"

    if [ -f "$mirror" ] && [ ! -L "$mirror" ] && grep -q '^Host devbox$' "$mirror"; then
        command rm -f "$mirror"
    fi
    [ -d "$mirror_dir" ] && [ ! -L "$mirror_dir" ] && rmdir "$mirror_dir" 2>/dev/null || true
    return 0
}

write_devbox_ssh_config() {
    local staged_source staged_managed staged_config
    local ssh_dir config config_dir temporary config_mode
    local ssh_dir_existed=false config_dir_existed=false
    local source_host reachability_error

    staged_source="$(mktemp "${TMPDIR:-/tmp}/devbox-source.XXXXXX")" ||
        die "failed to stage the devbox SSH configuration"
    staged_managed="$(mktemp "${TMPDIR:-/tmp}/devbox.XXXXXX")" || {
        command rm -f "$staged_source"
        die "failed to stage the devbox SSH configuration"
    }
    staged_config="$(mktemp "${TMPDIR:-/tmp}/devbox-config.XXXXXX")" || {
        command rm -f "$staged_source" "$staged_managed"
        die "failed to stage the devbox SSH configuration"
    }
    if ! devbox_colima ssh-config "$DEVBOX_PROFILE" >"$staged_source"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "Colima failed to generate the devbox SSH configuration"
    fi
    if ! awk '
         /^Host[[:space:]]/ {
            print "Host devbox"
            print "  User devbox"
            print "  IdentitiesOnly yes"
             print "  ForwardAgent no"
             print "  ControlMaster no"
             print "  ControlPath none"
             print "  ProxyCommand none"
             print "  ProxyJump none"
             next
         }
         /^[[:space:]]*(User|IdentitiesOnly|ForwardAgent|ControlMaster|ControlPath|ControlPersist|ProxyCommand|ProxyJump)[[:space:]]/ { next }
         { print }
    ' "$staged_source" >"$staged_managed"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "Colima failed to generate the devbox SSH configuration"
    fi
    if ! grep -q '^Host devbox$' "$staged_managed" ||
        ! grep -Eqi '^[[:space:]]*HostName[[:space:]]+' "$staged_source" ||
        ! grep -Eqi '^[[:space:]]*Port[[:space:]]+' "$staged_source"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "Colima returned an invalid devbox SSH configuration"
    fi
    if ! grep -q '^[[:space:]]*IdentityFile[[:space:]]' "$staged_managed"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "Colima devbox SSH configuration has no identity file"
    fi
    chmod 600 "$staged_source" "$staged_managed" || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "failed to secure the staged devbox SSH configuration"
    }

    ssh_dir="$HOME/.ssh"
    config="$ssh_dir/config"
    [ -L "$config" ] && config="$(canonicalize_path "$config")"
    config_dir="$(dirname "$config")"
    if ! stage_devbox_host_ssh_config "$staged_managed" "$config" "$staged_config"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "$config contains malformed devbox markers"
    fi
    chmod 600 "$staged_config" || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "failed to secure the staged devbox SSH configuration"
    }
    if ! ssh -F "$staged_source" -G devbox >/dev/null 2>&1 ||
        ! ssh -F "$staged_managed" -G devbox >/dev/null 2>&1 ||
        ! ssh -F "$staged_config" -G devbox >/dev/null 2>&1; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "generated devbox SSH configuration is invalid"
    fi
    source_host="$(awk 'toupper($1) == "HOST" { print $2; exit }' "$staged_source")"
    [ -n "$source_host" ] || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "Colima returned an invalid devbox SSH configuration"
    }
    if ! validate_devbox_effective_ssh_config \
        "$(ssh -F "$staged_source" -G "$source_host" 2>/dev/null)" "$staged_config"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "generated devbox SSH configuration has conflicting effective settings"
    fi
    if ! reachability_error="$(ssh -F "$staged_config" -o BatchMode=yes -o ConnectTimeout=10 devbox true 2>&1)"; then
        printf 'ERROR: generated SSH host '\''devbox'\'' is not reachable\n' >&2
        printf '  ssh: %s\n' "$reachability_error" >&2
        printf '  effective: hostname=%s port=%s user=%s identitiesonly=%s\n' \
            "$(devbox_effective_ssh_value "$(ssh -F "$staged_config" -G devbox 2>/dev/null)" hostname | head -n 1)" \
            "$(devbox_effective_ssh_value "$(ssh -F "$staged_config" -G devbox 2>/dev/null)" port | head -n 1)" \
            "$(devbox_effective_ssh_value "$(ssh -F "$staged_config" -G devbox 2>/dev/null)" user | head -n 1)" \
            "$(devbox_effective_ssh_value "$(ssh -F "$staged_config" -G devbox 2>/dev/null)" identitiesonly | head -n 1)" >&2
        printf '  managed block:\n' >&2
        sed -n '/^# BEGIN devbox$/,/^# END devbox$/p' "$staged_config" >&2 || true
        printf '  colima source config:\n' >&2
        cat "$staged_source" >&2 || true
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "generated SSH host 'devbox' is not reachable"
    fi

    [ -d "$ssh_dir" ] && ssh_dir_existed=true
    [ -d "$config_dir" ] && config_dir_existed=true
    mkdir -p "$ssh_dir" "$config_dir" || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "failed to create the devbox SSH configuration directories"
    }
    [ -d "$ssh_dir" ] && [ ! -L "$ssh_dir" ] &&
        [ -d "$config_dir" ] && [ ! -L "$config_dir" ] || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "devbox SSH configuration directories are invalid"
    }
    if [ "$ssh_dir_existed" = false ]; then
        chmod 700 "$ssh_dir" || {
            command rm -f "$staged_source" "$staged_managed" "$staged_config"
            die "failed to secure the devbox SSH configuration directories"
        }
    fi
    if [ "$config_dir_existed" = false ]; then
        chmod 700 "$config_dir" || {
            command rm -f "$staged_source" "$staged_managed" "$staged_config"
            die "failed to secure the devbox SSH configuration directories"
        }
    fi
    if [ -e "$config" ]; then
        config_mode="$(file_mode "$config")" || {
            command rm -f "$staged_source" "$staged_managed" "$staged_config"
            die "failed to inspect $config"
        }
    else
        config_mode=600
    fi
    temporary="$(mktemp "$config_dir/.config.XXXXXX")" || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "failed to stage the devbox SSH configuration update"
    }
    # Stage next to ~/.ssh/config and rename into place, so the final update is
    # a single atomic replacement and readers never see a partial file.
    if ! cp "$staged_config" "$temporary" ||
        ! chmod "$config_mode" "$temporary"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config" "$temporary"
        die "failed to stage the devbox SSH configuration update"
    fi
    command rm -f "$staged_source" "$staged_managed" "$staged_config"
    if ! mv "$temporary" "$config"; then
        command rm -f "$temporary"
        die "failed to update $config"
    fi
    cleanup_devbox_ssh_config_mirror
}

ensure_devbox_guest_ssh_access() {
    require_devbox_guest_preflight
    reconcile_devbox_guest_workspace || {
        revoke_devbox_guest_ssh_access ||
            die "devbox guest workspace is invalid; managed direct SSH access could not be fully removed"
        die "devbox guest workspace is invalid; managed direct SSH access was removed"
    }
    authorize_devbox_host_key || return
    write_devbox_ssh_config
}

revoke_devbox_guest_ssh_access() {
    local status=0

    remove_devbox_managed_guest_ssh_authorization || status=1
    remove_devbox_ssh_config || status=1
    return "$status"
}

remove_devbox_ssh_config() {
    local ssh_dir="$HOME/.ssh"
    local config="$ssh_dir/config" config_dir temporary config_mode

    [ -L "$config" ] && config="$(canonicalize_path "$config")"
    config_dir="$(dirname "$config")"
    if [ ! -e "$config" ]; then
        cleanup_devbox_ssh_config_mirror
        return 0
    fi
    temporary="$(mktemp "$config_dir/.config.XXXXXX")" ||
        die "failed to stage the devbox SSH configuration cleanup"
    if ! strip_devbox_ssh_block "$config" "$temporary"; then
        command rm -f "$temporary"
        die "$config contains malformed devbox markers"
    fi
    config_mode="$(file_mode "$config")" || {
        command rm -f "$temporary"
        die "failed to inspect $config"
    }
    chmod "$config_mode" "$temporary" || {
        command rm -f "$temporary"
        die "failed to preserve the mode of $config"
    }
    mv "$temporary" "$config" || {
        command rm -f "$temporary"
        die "failed to update $config"
    }
    cleanup_devbox_ssh_config_mirror
}

provision_devbox_guest() (
    local force="${1:-false}" host_digest guest_digest

    create_devbox_bundle_snapshot || return
    trap 'command rm -rf "$DEVBOX_BUNDLE_SNAPSHOT"' EXIT
    host_digest="$DEVBOX_BUNDLE_DIGEST"
    guest_digest="$(devbox_guest_provision_digest)" || return
    if [ "$force" = false ] && [ "$host_digest" = "$guest_digest" ]; then
        if devbox_guest_bundle_is_valid "$host_digest"; then
            log "devbox provisioning is current."
            require_devbox_guest_preflight
            sync_devbox_guest_config || return
            ensure_devbox_guest_ssh_access || return
            return
        fi
        log "devbox provisioning bundle is missing or invalid; refreshing."
    fi
    run_devbox_guest_provisioning "$host_digest" "$DEVBOX_BUNDLE_ARCHIVE" || return
)

stop_devbox_vm() {
    local force="${1:-false}" state

    if [ ! -e "$DEVBOX_COLIMA_PROFILE" ]; then
        log "devbox VM is already stopped."
        return
    fi
    # Stopping is not destructive and must work for a profile claimed by
    # another install root, so the adoption path is reachable.
    state="$(devbox_state_raw)"
    case "$state" in
        '' | Stopped) log "devbox VM is already stopped." ;;
        Running)
            if [ "$force" = true ]; then
                devbox_colima_raw stop --force "$DEVBOX_PROFILE"
            else
                devbox_colima_raw stop "$DEVBOX_PROFILE"
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
    record="$(devbox_profile_record devbox_colima_raw)" || {
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
            [ "${1:-}" = status ] && [ $# -eq 1 ] || die "Usage: devbox services status"
            require_running_devbox_vm
            show_devbox_services_status
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
            check_devbox_ownership
            printf "Type '%s' to delete the devbox VM and all its guest data (the workspace, installed toolchains and caches, service data, and credentials): " "$DEVBOX_PROFILE"
            read -r confirm
            [ "$confirm" = "$DEVBOX_PROFILE" ] || die "Aborted"
            if [ "$(devbox_state)" = Running ]; then
                remove_devbox_managed_guest_ssh_authorization || {
                    status=$?
                    release_lock
                    return "$status"
                }
            fi
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
