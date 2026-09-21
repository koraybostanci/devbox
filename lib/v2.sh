#!/bin/bash

V2_PROFILE="devbox-v2"
V2_OWNER_VERSION="devbox-v2-profile-v1"
V2_GUEST_USER="devbox"
V2_GUEST_HOME="/home/$V2_GUEST_USER"
V2_GUEST_WORKSPACE="$V2_GUEST_HOME/workspace"
V2_GUEST_CONFIG_ROOT="$V2_GUEST_HOME/.config/devbox-v2"
V2_GUEST_ROOT="/var/lib/devbox-v2"
V2_GUEST_BUNDLE_ROOT="$V2_GUEST_ROOT/bundles"
V2_GUEST_PROVISIONING_ROOT="$V2_GUEST_ROOT/provisioning"
V2_SSH_AUTHORIZED_KEYS_FILE='/etc/ssh/authorized_keys/%u'

configure_v2_paths() {
    local colima_home

    colima_home="${COLIMA_HOME:-$HOME/.colima}"
    [ "$colima_home" = "$HOME/.colima" ] ||
        die "v2 requires the standard Colima home $HOME/.colima; unset COLIMA_HOME"
    DEVBOX_V2_COLIMA_HOME="$HOME/.colima"
    DEVBOX_V2_LIMA_HOME="$DEVBOX_V2_COLIMA_HOME/_lima"
    case "${LIMA_HOME:-}" in
        '' | "$DEVBOX_V2_LIMA_HOME") ;;
        *) die "v2 requires LIMA_HOME to be unset or $DEVBOX_V2_LIMA_HOME" ;;
    esac
    DEVBOX_V2_STATE_ROOT="$HOME/.local/share/devbox/v2"
    DEVBOX_V2_CONFIG_ROOT="$HOME/.config/devbox/v2"
    DEVBOX_SHARED_LOCK_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/devbox/locks"
    DEVBOX_V2_COLIMA_PROFILE="$DEVBOX_V2_COLIMA_HOME/$V2_PROFILE"
    DEVBOX_V2_COLIMA_CONFIG="$DEVBOX_V2_COLIMA_PROFILE/colima.yaml"
    DEVBOX_V2_COLIMA_OWNER="$DEVBOX_V2_COLIMA_PROFILE/.devbox-owner"
    DEVBOX_V2_DOCKER_CONFIG="$DEVBOX_V2_CONFIG_ROOT/docker"
    DEVBOX_LOCK_DIR="$DEVBOX_SHARED_LOCK_DIR"
    export DEVBOX_LOCK_DIR
}

check_v2_dependencies() {
    local command_name colima_version
    local -a missing=()

    for command_name in colima jq yq ssh; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    [ "${#missing[@]}" -eq 0 ] ||
        die "Missing host dependencies for v2. Review and run: brew install ${missing[*]}"
    colima_version="$(v2_colima version | awk 'NR == 1 {print $3}')"
    version_at_least "$colima_version" "$MINIMUM_COLIMA_VERSION" ||
        die "Colima $MINIMUM_COLIMA_VERSION or newer is required (found $colima_version)"
}

check_v2_ownership() {
    local owner_version owner_checkout

    [ -e "$DEVBOX_V2_COLIMA_PROFILE" ] || return 0
    [ -f "$DEVBOX_V2_COLIMA_OWNER" ] ||
        die "Colima profile '$V2_PROFILE' already exists but is not owned by this devbox checkout"
    owner_version="$(sed -n '1p' "$DEVBOX_V2_COLIMA_OWNER")"
    owner_checkout="$(sed -n '2p' "$DEVBOX_V2_COLIMA_OWNER")"
    [ "$owner_version" = "$V2_OWNER_VERSION" ] ||
        die "Invalid ownership marker in $DEVBOX_V2_COLIMA_OWNER"
    [ "$owner_checkout" = "$DEVBOX_DIR" ] ||
        die "Colima profile '$V2_PROFILE' is owned by another devbox checkout: $owner_checkout"
}

v2_profile_exists() {
    [ -e "$DEVBOX_V2_COLIMA_PROFILE" ]
}

mark_v2_profile_owned() {
    local temporary

    temporary="$(mktemp "$DEVBOX_V2_COLIMA_PROFILE/.devbox-owner.XXXXXX")"
    printf '%s\n%s\n' "$V2_OWNER_VERSION" "$DEVBOX_DIR" >"$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$DEVBOX_V2_COLIMA_OWNER"
}

prepare_v2_docker_config() {
    mkdir -p "$DEVBOX_V2_DOCKER_CONFIG"
    chmod 700 "$DEVBOX_V2_DOCKER_CONFIG"
}

v2_colima() {
    local colima_bin

    check_v2_ownership
    prepare_v2_docker_config
    colima_bin="$(command -v colima 2>/dev/null || true)"
    [ -n "$colima_bin" ] && [ -x "$colima_bin" ] ||
        die "Missing host dependency: colima"
    COLIMA_HOME="$DEVBOX_V2_COLIMA_HOME" \
        LIMA_HOME="$DEVBOX_V2_LIMA_HOME" \
        DOCKER_CONFIG="$DEVBOX_V2_DOCKER_CONFIG" \
        "$colima_bin" "$@"
}

v2_state() {
    v2_colima list --json 2>/dev/null |
        jq -r --arg profile "$V2_PROFILE" 'select(.name == $profile) | .status' |
        head -n 1
}

render_v2_colima_config() {
    local content temporary

    load_env v2
    check_v2_ownership
    mkdir -p "$DEVBOX_V2_COLIMA_PROFILE"
    content="$(<"$DEVBOX_DIR/colima-v2.yaml")"
    content="${content//'{{CPU}}'/$DEVBOX_CPU}"
    content="${content//'{{MEMORY}}'/$DEVBOX_MEMORY}"
    content="${content//'{{DISK}}'/$DEVBOX_DISK}"
    [[ "$content" != *'{{'* ]] || die "Unresolved placeholder in rendered v2 Colima configuration"

    temporary="$(mktemp "$DEVBOX_V2_COLIMA_PROFILE/.colima.yaml.XXXXXX")"
    printf '%s\n' "$content" >"$temporary"
    if ! yq eval '.' "$temporary" >/dev/null; then
        command rm -f "$temporary"
        die "Generated v2 Colima configuration is invalid"
    fi
    yq -e '
        .runtime == "docker" and
        .vmType == "vz" and
        .autoActivate == false and
        .sshConfig == false and
        .forwardAgent == false and
        .portForwarder == "none" and
        (.mounts == null)
    ' "$temporary" >/dev/null || {
        command rm -f "$temporary"
        die "Generated v2 Colima configuration must not contain mounts"
    }
    chmod 600 "$temporary"
    mv "$temporary" "$DEVBOX_V2_COLIMA_CONFIG"
    mark_v2_profile_owned
}

v2_admin_guest() {
    v2_colima ssh -p "$V2_PROFILE" -- "$@"
}

v2_guest() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 devbox-v2 -- "$@"
}

v2_as_guest() {
    v2_admin_guest sudo -u "$V2_GUEST_USER" -- env \
        HOME="$V2_GUEST_HOME" \
        PWD="$V2_GUEST_HOME" \
        bash -c '
        set -Eeuo pipefail
        home="$1"
        shift
        [ -d "$home" ] && [ ! -L "$home" ] || {
            printf "ERROR: v2 guest home is invalid: %s\\n" "$home" >&2
            exit 1
        }
        cd -- "$home"
        export HOME="$home"
        export PWD="$PWD"
        exec "$@"
    ' _ "$V2_GUEST_HOME" "$@"
}

require_running_v2_vm() {
    [ "$(v2_state)" = Running ] || die "v2 VM is not running; run 'devbox v2 start' first"
}

wait_for_v2_ssh() {
    local attempts=60 attempt

    log "Waiting for v2 VM SSH readiness..."
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if v2_admin_guest true >/dev/null 2>&1; then
            return
        fi
        sleep 2
    done
    die "v2 VM SSH did not become ready within $((attempts * 2)) seconds"
}

start_v2_vm() {
    local state

    render_v2_colima_config
    state="$(v2_state)"
    case "$state" in
        Running) ;;
        '' | Stopped)
            v2_colima start "$V2_PROFILE" \
                --activate=false \
                --ssh-config=false \
                --ssh-agent=false \
                --port-forwarder=none \
                --save-config=false
            ;;
        *) die "v2 VM is in state '$state'; wait for it to settle and retry" ;;
    esac
    wait_for_v2_ssh
}

v2_bundle_digest() {
    local provision_root="$1"

    (
        cd "$provision_root"
        find . -type f ! -path './.devbox-bundle.sha256' -print | LC_ALL=C sort | while IFS= read -r path; do
            printf '%s\t%s\n' "${path#./}" "$(shasum -a 256 "$path" | awk '{print $1}')"
        done | shasum -a 256 | awk '{print $1}'
    )
}

create_v2_bundle_snapshot() {
    V2_BUNDLE_SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/devbox-v2-bundle.XXXXXX")"
    V2_BUNDLE_ARCHIVE="$V2_BUNDLE_SNAPSHOT/provision.tar"
    (
        cd "$DEVBOX_DIR"
        COPYFILE_DISABLE=1 tar -cf - provision
    ) | COPYFILE_DISABLE=1 tar -xf - -C "$V2_BUNDLE_SNAPSHOT"
    find "$V2_BUNDLE_SNAPSHOT/provision" -type f -exec chmod a-w {} +
    V2_BUNDLE_DIGEST="$(v2_bundle_digest "$V2_BUNDLE_SNAPSHOT/provision")"
    (
        cd "$V2_BUNDLE_SNAPSHOT"
        COPYFILE_DISABLE=1 tar -cf "$V2_BUNDLE_ARCHIVE" provision
    )
    chmod 400 "$V2_BUNDLE_ARCHIVE"
}

stream_v2_bundle() {
    local digest="$1" archive="$2"

    v2_admin_guest sudo bash -c '
        set -Eeuo pipefail
        digest="$1"
        root=/var/lib/devbox-v2/bundles
        target="$root/$digest"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
            printf "ERROR: v2 bundle digest is invalid\n" >&2
            exit 1
        }
        { [ ! -e /var/lib/devbox-v2 ] && [ ! -L /var/lib/devbox-v2 ]; } ||
            { [ -d /var/lib/devbox-v2 ] && [ ! -L /var/lib/devbox-v2 ]; } || {
            printf "ERROR: v2 root bundle directory is invalid\n" >&2
            exit 1
        }
        install -d -o root -g root -m 755 /var/lib/devbox-v2
        { [ ! -e "$root" ] && [ ! -L "$root" ]; } ||
            { [ -d "$root" ] && [ ! -L "$root" ]; } || {
            printf "ERROR: v2 root bundle directory is invalid\n" >&2
            exit 1
        }
        install -d -o root -g root -m 700 "$root"
        [ -d "$root" ] && [ ! -L "$root" ] || {
            printf "ERROR: v2 root bundle directory is invalid\n" >&2
            exit 1
        }
        chmod 700 "$root"
        temporary="$(mktemp -d "$root/.bundle.XXXXXX")"
        trap "rm -rf \"$temporary\"" EXIT
        tar -xf - -C "$temporary"
        [ ! -L "$temporary/provision" ] &&
            ! find "$temporary/provision" -type l -print -quit | grep -q . || {
            printf "ERROR: transferred v2 bundle contains a symlink\n" >&2
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
            printf "ERROR: transferred v2 bundle digest does not match\n" >&2
            exit 1
        }
        printf "%s\n" "$digest" >"$temporary/provision/.devbox-bundle.sha256"
        find "$temporary/provision" -type d -exec chmod 700 {} +
        find "$temporary/provision" -type f -exec chmod 600 {} +
        chown -R root:root "$temporary/provision"
        if [ -d "$target" ]; then
            [ ! -L "$target" ] || {
                printf "ERROR: existing v2 bundle is not a directory\n" >&2
                exit 1
            }
            ! find "$target" -type l -print -quit | grep -q . || {
                printf "ERROR: existing v2 bundle contains a symlink\n" >&2
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
                printf "ERROR: unable to replace corrupt cached v2 bundle\n" >&2
                exit 1
            }
            mv "$temporary/provision" "$target" || {
                mv "$backup" "$target" || true
                printf "ERROR: verified v2 bundle could not be installed\n" >&2
                exit 1
            }
            rm -rf "$backup"
        elif [ -e "$target" ] || [ -L "$target" ]; then
            printf "ERROR: existing v2 bundle is not a directory\n" >&2
            exit 1
        else
            mv "$temporary/provision" "$target"
        fi
    ' _ "$digest" <"$archive"
}

v2_guest_bundle_is_valid() {
    local digest="$1"

    v2_admin_guest sudo bash -c '
        set -Eeuo pipefail
        digest="$1"
        target="/var/lib/devbox-v2/bundles/$digest"
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

render_v2_guest_config() {
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

# Establish the guest-local v2 configuration:
#   config  - non-secret defaults; seeded once, then the guest is authoritative.
#   secrets - service secrets; always generated inside the guest, never seeded
#             from the host.
sync_v2_guest_config() {
    load_env v2
    render_v2_guest_config | v2_as_guest env \
        DEVBOX_GUEST_CONFIG_ROOT="$V2_GUEST_CONFIG_ROOT" \
        bash -c '
        set -Eeuo pipefail
        umask 077
        directory="$DEVBOX_GUEST_CONFIG_ROOT"
        mkdir -p "$directory"
        config="$directory/config"
        secrets="$directory/secrets"
        # Drop the superseded host-seeded env file from earlier v2 guests.
        rm -f "$directory/env"
        if [ ! -e "$config" ]; then
            temporary="$(mktemp "$directory/.config.XXXXXX")"
            cat >"$temporary"
            chmod 600 "$temporary"
            mv "$temporary" "$config"
        else
            cat >/dev/null
        fi
        if [ ! -e "$secrets" ]; then
            temporary="$(mktemp "$directory/.secrets.XXXXXX")"
            printf "export POSTGRES_PASSWORD=%s\\n" \
                "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d " \\n")" >"$temporary"
            chmod 600 "$temporary"
            mv "$temporary" "$secrets"
        fi
    '
}

v2_guest_provision_digest() {
    v2_admin_guest bash -c 'cat "$HOME/.local/state/devbox-v2/provision.sha256" 2>/dev/null || true'
}

run_v2_guest_provisioning() {
    local digest="$1" archive="$2"

    stream_v2_bundle "$digest" "$archive" || return
    log "Provisioning v2 guest tools from bundle $digest..."
    if ! v2_admin_guest bash -c '
        set -Eeuo pipefail
        export DEVBOX_PROVISION_ROOT="/var/lib/devbox-v2/bundles/$1"
        sudo env DEVBOX_NO_MOUNTS=true DEVBOX_V2_GUEST_USER=devbox \
            bash "$DEVBOX_PROVISION_ROOT/scripts/system.sh"
    ' _ "$digest"; then
        validate_v2_guest_preflight || {
            revoke_v2_guest_ssh_access ||
                die "v2 guest user has unsafe identity or privileges; managed direct SSH access could not be fully removed"
            die "v2 guest user has unsafe identity or privileges; managed direct SSH access was removed"
        }
        return 1
    fi
    validate_v2_guest_preflight || {
        revoke_v2_guest_ssh_access ||
            die "v2 guest user has unsafe identity or privileges; managed direct SSH access could not be fully removed"
        die "v2 guest user has unsafe identity or privileges; managed direct SSH access was removed"
    }
    run_v2_root_apps "$digest" || return
    stage_v2_guest_provisioning_input "$digest" || return
    sync_v2_guest_config || return
    ensure_v2_guest_ssh_access || return
    v2_as_guest env \
        DEVBOX_PROVISION_ROOT="$V2_GUEST_PROVISIONING_ROOT/$digest" \
        DEVBOX_GUEST_CONFIG_ROOT="$V2_GUEST_CONFIG_ROOT" \
        DEVBOX_NO_MOUNTS=true \
        bash -c '
        set -Eeuo pipefail
        bash "$DEVBOX_PROVISION_ROOT/scripts/tools.sh"
        bash "$DEVBOX_PROVISION_ROOT/scripts/verify.sh"
    ' || return
    printf '%s\n' "$digest" | v2_admin_guest bash -c '
        set -Eeuo pipefail
        umask 077
        directory="$HOME/.local/state/devbox-v2"
        mkdir -p "$directory"
        temporary="$(mktemp "$directory/.provision.XXXXXX")"
        cat >"$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$directory/provision.sha256"
    ' || return
}

run_v2_root_apps() {
    local digest="$1"

    v2_admin_guest bash -c '
        set -Eeuo pipefail
        export DEVBOX_PROVISION_ROOT="/var/lib/devbox-v2/bundles/$1"
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

stage_v2_guest_provisioning_input() {
    local digest="$1"

    v2_admin_guest sudo bash -c '
        set -Eeuo pipefail
        digest="$1"
        root=/var/lib/devbox-v2
        source_root="$root/bundles/$digest"
        parent="$root/provisioning"
        target_root="$parent/$digest"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
            printf "ERROR: v2 provisioning digest is invalid\n" >&2
            exit 1
        }
        [ -d "$root" ] && [ ! -L "$root" ] || {
            printf "ERROR: v2 root provisioning directory is invalid\\n" >&2
            exit 1
        }
        [ -d "$source_root" ] && [ ! -L "$source_root" ] || {
            printf "ERROR: v2 root provisioning bundle is invalid\\n" >&2
            exit 1
        }
        ! find "$source_root" -type l -print -quit | grep -q . || {
            printf "ERROR: v2 root provisioning bundle contains a symlink\\n" >&2
            exit 1
        }
        [ -d "$parent" ] && [ ! -L "$parent" ] || {
            [ ! -e "$parent" ] && [ ! -L "$parent" ] || {
                printf "ERROR: v2 root provisioning input directory is invalid\\n" >&2
                exit 1
            }
            install -d -o root -g root -m 755 "$parent"
        }
        temporary="$(mktemp -d "$parent/.provision.XXXXXX")"
        trap "rm -rf \"$temporary\"" EXIT
        tar -C "$source_root" -cf - . | tar -xf - -C "$temporary"
        ! find "$temporary" -type l -print -quit | grep -q . || {
            printf "ERROR: v2 root provisioning input contains a symlink\\n" >&2
            exit 1
        }
        find "$temporary" -type d -exec chmod 755 {} +
        find "$temporary" -type f -exec chmod 644 {} +
        chown -R root:root "$temporary"
        if [ -d "$target_root" ]; then
            [ ! -L "$target_root" ] || {
                printf "ERROR: v2 guest provisioning input is not a directory\\n" >&2
                exit 1
            }
            rm -rf "$target_root"
        elif [ -e "$target_root" ] || [ -L "$target_root" ]; then
            printf "ERROR: v2 guest provisioning input is not a directory\\n" >&2
            exit 1
        fi
        mv "$temporary" "$target_root"
    ' _ "$digest"
}

v2_host_public_key() {
    local identity_file

    identity_file="$(v2_colima ssh-config "$V2_PROFILE" | awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            directive = line
            sub(/[[:space:]].*$/, "", directive)
            if (tolower(directive) != "identityfile") next
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
    ')"
    [ -n "$identity_file" ] && [ -r "$identity_file" ] ||
        die "Colima SSH configuration has no readable identity file for $V2_PROFILE"
    ssh-keygen -y -f "$identity_file"
}

v2_host_ssh_user() {
    local user

    user="$(v2_colima ssh-config "$V2_PROFILE" | awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            directive = line
            sub(/[[:space:]].*$/, "", directive)
            if (tolower(directive) != "user") next
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
    ')"
    [ -n "$user" ] || die "Colima SSH configuration has no user for $V2_PROFILE"
    printf '%s\n' "$user"
}

v2_sshd_authorized_keys_config() {
    printf "AuthorizedKeysFile %s\n" "$V2_SSH_AUTHORIZED_KEYS_FILE"
}

v2_guest_identity_is_safe() {
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

validate_v2_guest_identity() {
    local identity
    local guest_uid guest_gid group_name group_gid group_members group_names uid_matches gid_matches extra

    identity="$(v2_admin_guest bash -c '
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
    ' _ "$V2_GUEST_USER")" || return 1
    IFS=: read -r guest_uid guest_gid group_name group_gid group_members group_names uid_matches gid_matches extra <<<"$identity"
    [ -z "$extra" ] || return 1
    v2_guest_identity_is_safe \
        "$V2_GUEST_USER" "$guest_uid" "$guest_gid" "$group_name" "$group_gid" "$group_members" "$group_names" \
        "$uid_matches" "$gid_matches"
}

validate_v2_guest_privileges() {
    v2_admin_guest sudo bash -c '
        set -Eeuo pipefail
        user="$1"
        sudo_status=0
        sudo_listing="$(LC_ALL=C sudo -n -l -U "$user" 2>&1)" || sudo_status=$?
        { [ "$sudo_status" -eq 0 ] || [ "$sudo_status" -eq 1 ]; } || {
            printf "ERROR: failed to inspect v2 guest sudo privileges\n" >&2
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
            printf "ERROR: v2 guest user has sudo privileges\n" >&2
            exit 1
        }
        if sudo -u "$user" -- sudo -n true >/dev/null 2>&1; then
            printf "ERROR: v2 guest user can execute passwordless sudo\n" >&2
            exit 1
        fi
        if [ -S /var/run/docker.sock ] && sudo -u "$user" -- test -w /var/run/docker.sock; then
            printf "ERROR: v2 guest user can write the Docker socket\n" >&2
            exit 1
        fi
    ' _ "$V2_GUEST_USER"
}

validate_v2_guest_preflight() {
    validate_v2_guest_identity && validate_v2_guest_privileges
}

reconcile_v2_guest_workspace() {
    v2_as_guest bash -c '
        set -Eeuo pipefail
        workspace="$HOME/workspace"
        [ -d "$HOME" ] && [ ! -L "$HOME" ] || {
            printf "ERROR: v2 guest home is invalid: %s\\n" "$HOME" >&2
            exit 1
        }
        [ ! -L "$workspace" ] || {
            printf "ERROR: v2 guest workspace must be a real directory: %s\\n" "$workspace" >&2
            exit 1
        }
        [ ! -e "$workspace" ] || [ -d "$workspace" ] || {
            printf "ERROR: v2 guest workspace must be a real directory: %s\\n" "$workspace" >&2
            exit 1
        }
        mkdir -p "$workspace"
        [ -d "$workspace" ] && [ ! -L "$workspace" ] && [ -O "$workspace" ] && [ -G "$workspace" ] || {
            printf "ERROR: v2 guest workspace has unsafe ownership: %s\\n" "$workspace" >&2
            exit 1
        }
        chmod 700 "$workspace"
    '
}

authorize_v2_host_key() {
    local sshd_settings admin_user

    sshd_settings="$(v2_sshd_authorized_keys_config)"
    admin_user="$(v2_host_ssh_user)" || return
    v2_host_public_key | v2_admin_guest sudo bash -c '
        set -Eeuo pipefail
        guest_user="$2"
        admin_user="$3"
        sshd_settings="$1"
        keys_dir=/etc/ssh/authorized_keys
        sshd_config=/etc/ssh/sshd_config.d/00-devbox-v2.conf
        key="$(cat)"
        [ -n "$key" ] && [ "$(printf "%s\\n" "$key" | wc -l | tr -d " ")" = 1 ] || {
            printf "ERROR: invalid v2 host SSH public key\\n" >&2
            exit 1
        }
        for user in "$guest_user" "$admin_user"; do
            [[ "$user" =~ ^[A-Za-z0-9_.-]+$ ]] || {
                printf "ERROR: invalid v2 SSH user: %s\\n" "$user" >&2
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
        temporary="$(mktemp /etc/ssh/sshd_config.d/.devbox-v2.XXXXXX)"
        printf "%s\\n" "$sshd_settings" >"$temporary"
        chown root:root "$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$sshd_config"
        sshd -t
        for user in "$guest_user" "$admin_user"; do
            effective="$(sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null)" || {
                printf "ERROR: v2 SSH configuration test failed for %s\\n" "$user" >&2
                sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" >&2 || true
                exit 1
            }
            printf "%s\\n" "$effective" | grep -Fqx "authorizedkeysfile /etc/ssh/authorized_keys/%u" || {
                printf "ERROR: v2 SSH authorized-keys policy is not effective for %s\\n" "$user" >&2
                printf "  drop-in %s: %s\\n" "$sshd_config" "$(cat "$sshd_config" 2>&1 || true)" >&2
                printf "  effective: %s\\n" "$(printf "%s\\n" "$effective" | grep -i authorizedkeysfile || true)" >&2
                printf "  include: %s\\n" "$(grep -n "Include" /etc/ssh/sshd_config 2>&1 || true)" >&2
                printf "  drop-ins: %s\\n" "$(ls -1 /etc/ssh/sshd_config.d 2>&1 | tr "\\n" " " || true)" >&2
                printf "  run-sshd: %s\\n" "$([ -d /run/sshd ] && printf present || printf missing)" >&2
                exit 1
            }
        done
        systemctl reload ssh
    ' _ "$sshd_settings" "$V2_GUEST_USER" "$admin_user"
}

remove_v2_managed_guest_ssh_authorization() {
    v2_admin_guest sudo bash -c '
        set -Eeuo pipefail
        authorized=/etc/ssh/authorized_keys/devbox
        [ ! -e "$authorized" ] && [ ! -L "$authorized" ] && exit 0
        [ -f "$authorized" ] && [ ! -L "$authorized" ] &&
            [ "$(stat -c "%u:%g" "$authorized")" = 0:0 ] || {
            printf "ERROR: managed v2 SSH authorization is invalid: %s\\n" "$authorized" >&2
            exit 1
        }
        rm -f -- "$authorized"
    '
}

stage_v2_host_ssh_config() {
    local managed_config="$1"
    local config="$2"
    local temporary="$3"
    local begin_marker='# BEGIN devbox-v2' end_marker='# END devbox-v2'
    local begin_count end_count

    if [ -e "$config" ]; then
        begin_count="$(grep -Fxc "$begin_marker" "$config" || true)"
        end_count="$(grep -Fxc "$end_marker" "$config" || true)"
    else
        begin_count=0
        end_count=0
    fi
    [ "$begin_count" -eq "$end_count" ] && [ "$begin_count" -le 1 ] ||
        return 1

    if [ -e "$config" ]; then
        awk -v managed_config="$managed_config" '
            function insert_managed_config(    line) {
                print "# BEGIN devbox-v2"
                while ((getline line < managed_config) > 0) print line
                close(managed_config)
                print "# END devbox-v2"
                print ""
                inserted = 1
            }
            $0 == "# BEGIN devbox-v2" { skipping = 1; next }
            skipping && $0 == "# END devbox-v2" { skipping = 0; next }
            skipping { next }
            !inserted && $0 == "# BEGIN devbox" {
                insert_managed_config()
            }
            !inserted && /^[[:space:]]*([Hh][Oo][Ss][Tt]|[Mm][Aa][Tt][Cc][Hh])[[:space:]]/ {
                insert_managed_config()
            }
            { print }
            END {
                if (skipping) exit 1
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

v2_effective_ssh_value() {
    local configuration="$1" key="$2"

    awk -v key="$key" '
        $1 == key {
            $1 = ""
            sub(/^[[:space:]]+/, "")
            print
        }
    ' <<<"$configuration"
}

validate_v2_effective_ssh_config() {
    local source_config="$1" managed_config="$2" effective_config
    local expected_hostname expected_port expected_identity actual_identity
    local controlmaster controlpath proxycommand proxyjump value

    effective_config="$(ssh -F "$managed_config" -G devbox-v2 2>/dev/null)" || {
        printf 'ERROR: v2 SSH effective configuration could not be computed\n' >&2
        return 1
    }
    expected_hostname="$(v2_effective_ssh_value "$source_config" hostname)"
    expected_port="$(v2_effective_ssh_value "$source_config" port)"
    expected_identity="$(v2_effective_ssh_value "$source_config" identityfile)"
    actual_identity="$(v2_effective_ssh_value "$effective_config" identityfile)"
    [ -n "$expected_hostname" ] && [ -n "$expected_port" ] && [ -n "$expected_identity" ] || {
        printf 'ERROR: Colima v2 SSH configuration lacks hostname, port, or identity\n' >&2
        return 1
    }
    value="$(v2_effective_ssh_value "$effective_config" user)"
    [ "$value" = "$V2_GUEST_USER" ] || {
        printf 'ERROR: v2 SSH effective user is %s, expected %s\n' "$value" "$V2_GUEST_USER" >&2
        return 1
    }
    value="$(v2_effective_ssh_value "$effective_config" identitiesonly)"
    [ "$value" = yes ] || {
        printf 'ERROR: v2 SSH effective IdentitiesOnly is %s\n' "$value" >&2
        return 1
    }
    value="$(v2_effective_ssh_value "$effective_config" forwardagent)"
    [ "$value" = no ] || {
        printf 'ERROR: v2 SSH effective ForwardAgent is %s\n' "$value" >&2
        return 1
    }
    controlmaster="$(v2_effective_ssh_value "$effective_config" controlmaster)"
    case "$controlmaster" in no | false) ;; *)
        printf 'ERROR: v2 SSH effective ControlMaster is %s\n' "$controlmaster" >&2
        return 1
        ;;
    esac
    controlpath="$(v2_effective_ssh_value "$effective_config" controlpath)"
    case "$controlpath" in '' | none) ;; *)
        printf 'ERROR: v2 SSH effective ControlPath is %s\n' "$controlpath" >&2
        return 1
        ;;
    esac
    proxycommand="$(v2_effective_ssh_value "$effective_config" proxycommand)"
    [ -n "$proxycommand" ] || proxycommand=none
    [ "$proxycommand" = none ] || {
        printf 'ERROR: v2 SSH effective ProxyCommand is %s\n' "$proxycommand" >&2
        return 1
    }
    proxyjump="$(v2_effective_ssh_value "$effective_config" proxyjump)"
    [ -n "$proxyjump" ] || proxyjump=none
    [ "$proxyjump" = none ] || {
        printf 'ERROR: v2 SSH effective ProxyJump is %s\n' "$proxyjump" >&2
        return 1
    }
    value="$(v2_effective_ssh_value "$effective_config" hostname)"
    [ "$value" = "$expected_hostname" ] || {
        printf 'ERROR: v2 SSH effective hostname is %s, expected %s\n' "$value" "$expected_hostname" >&2
        return 1
    }
    value="$(v2_effective_ssh_value "$effective_config" port)"
    [ "$value" = "$expected_port" ] || {
        printf 'ERROR: v2 SSH effective port is %s, expected %s\n' "$value" "$expected_port" >&2
        return 1
    }
    # OpenSSH accumulates IdentityFile across every matching block, so a
    # `Host *` block in the user configuration legitimately appends extra
    # identities after the managed one. Require the managed identity (or
    # identities) to come first, which is what makes the dedicated v2 key win;
    # do not reject inherited extras that follow it.
    case "$actual_identity" in
        "$expected_identity") ;;
        "$expected_identity"$'\n'*) ;;
        *)
            printf 'ERROR: v2 SSH effective identity does not start with the managed identity\n' >&2
            printf '  expected first: %s\n' "$expected_identity" >&2
            printf '  effective: %s\n' "$actual_identity" >&2
            return 1
            ;;
    esac
}

recover_v2_ssh_config_transaction() {
    local managed_config="$1" config="$2" managed_dir="$3" config_dir="$4"
    local journal="$managed_dir/.devbox-v2-transaction"
    local managed_existed config_existed managed_backup config_backup extra
    local managed_restore config_restore

    [ ! -e "$journal" ] && [ ! -L "$journal" ] && return 0
    [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
    {
        IFS= read -r managed_existed
        IFS= read -r config_existed
        IFS= read -r managed_backup
        IFS= read -r config_backup
    } <"$journal" || return 1
    if IFS= read -r extra < <(sed -n '5p' "$journal"); then
        [ -z "$extra" ] || return 1
    fi
    case "$managed_existed:$config_existed" in
        true:true | true:false | false:true | false:false) ;;
        *) return 1 ;;
    esac
    if [ "$managed_existed" = true ]; then
        case "$managed_backup" in "$managed_dir"/.devbox-v2-backup.*) ;; *) return 1 ;; esac
        [ -f "$managed_backup" ] && [ ! -L "$managed_backup" ] || return 1
    else
        [ -z "$managed_backup" ] || return 1
    fi
    if [ "$config_existed" = true ]; then
        case "$config_backup" in "$config_dir"/.config-backup.*) ;; *) return 1 ;; esac
        [ -f "$config_backup" ] && [ ! -L "$config_backup" ] || return 1
    else
        [ -z "$config_backup" ] || return 1
    fi

    if [ "$managed_existed" = true ]; then
        managed_restore="$(mktemp "$managed_dir/.devbox-v2-restore.XXXXXX")" || return 1
        cp -p "$managed_backup" "$managed_restore" &&
            mv "$managed_restore" "$managed_config" || {
            command rm -f "$managed_restore"
            return 1
        }
    else
        command rm -f "$managed_config" || return 1
    fi
    if [ "$config_existed" = true ]; then
        config_restore="$(mktemp "$config_dir/.config-restore.XXXXXX")" || return 1
        cp -p "$config_backup" "$config_restore" &&
            mv "$config_restore" "$config" || {
            command rm -f "$config_restore"
            return 1
        }
    else
        command rm -f "$config" || return 1
    fi
    command rm -f "$managed_backup" "$config_backup" "$journal"
}

write_v2_ssh_config() {
    local staged_source staged_managed staged_config managed_temporary config_temporary
    local managed_backup config_backup journal journal_temporary
    local ssh_dir managed_dir managed_config config config_dir config_mode
    local ssh_dir_existed=false managed_dir_existed=false config_dir_existed=false
    local managed_existed=false config_existed=false source_host reachability_error

    staged_source="$(mktemp "${TMPDIR:-/tmp}/devbox-v2-source.XXXXXX")"
    staged_managed="$(mktemp "${TMPDIR:-/tmp}/devbox-v2.XXXXXX")"
    staged_config="$(mktemp "${TMPDIR:-/tmp}/devbox-v2-config.XXXXXX")"
    if ! v2_colima ssh-config "$V2_PROFILE" >"$staged_source"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "Colima failed to generate the v2 SSH configuration"
    fi
    if ! awk '
         /^Host[[:space:]]/ {
            print "Host devbox-v2"
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
        die "Colima failed to generate the v2 SSH configuration"
    fi
    if ! grep -q '^Host devbox-v2$' "$staged_managed" ||
        ! grep -Eqi '^[[:space:]]*HostName[[:space:]]+' "$staged_source" ||
        ! grep -Eqi '^[[:space:]]*Port[[:space:]]+' "$staged_source"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "Colima returned an invalid v2 SSH configuration"
    fi
    if ! grep -q '^[[:space:]]*IdentityFile[[:space:]]' "$staged_managed"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "Colima v2 SSH configuration has no identity file"
    fi
    chmod 600 "$staged_source"
    chmod 600 "$staged_managed"

    ssh_dir="$HOME/.ssh"
    managed_dir="$ssh_dir/config.d"
    managed_config="$managed_dir/devbox-v2"
    config="$ssh_dir/config"
    [ -L "$config" ] && config="$(resolve_path "$config")"
    config_dir="$(dirname "$config")"
    if ! stage_v2_host_ssh_config "$staged_managed" "$config" "$staged_config"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "$config contains malformed devbox-v2 markers"
    fi
    chmod 600 "$staged_config"
    if ! ssh -F "$staged_source" -G devbox-v2 >/dev/null 2>&1 ||
        ! ssh -F "$staged_managed" -G devbox-v2 >/dev/null 2>&1 ||
        ! ssh -F "$staged_config" -G devbox-v2 >/dev/null 2>&1; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "generated v2 SSH configuration is invalid"
    fi
    source_host="$(awk 'toupper($1) == "HOST" { print $2; exit }' "$staged_source")"
    [ -n "$source_host" ] || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "Colima returned an invalid v2 SSH configuration"
    }
    if ! validate_v2_effective_ssh_config \
        "$(ssh -F "$staged_source" -G "$source_host" 2>/dev/null)" "$staged_config"; then
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "generated v2 SSH configuration has conflicting effective settings"
    fi
    if ! reachability_error="$(ssh -F "$staged_config" -o BatchMode=yes -o ConnectTimeout=10 devbox-v2 true 2>&1)"; then
        printf 'ERROR: generated SSH host '\''devbox-v2'\'' is not reachable\n' >&2
        printf '  ssh: %s\n' "$reachability_error" >&2
        printf '  effective: hostname=%s port=%s user=%s identitiesonly=%s\n' \
            "$(v2_effective_ssh_value "$(ssh -F "$staged_config" -G devbox-v2 2>/dev/null)" hostname | head -n 1)" \
            "$(v2_effective_ssh_value "$(ssh -F "$staged_config" -G devbox-v2 2>/dev/null)" port | head -n 1)" \
            "$(v2_effective_ssh_value "$(ssh -F "$staged_config" -G devbox-v2 2>/dev/null)" user | head -n 1)" \
            "$(v2_effective_ssh_value "$(ssh -F "$staged_config" -G devbox-v2 2>/dev/null)" identitiesonly | head -n 1)" >&2
        printf '  managed block:\n' >&2
        sed -n '/^# BEGIN devbox-v2$/,/^# END devbox-v2$/p' "$staged_config" >&2 || true
        printf '  colima source config:\n' >&2
        cat "$staged_source" >&2 || true
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "generated SSH host 'devbox-v2' is not reachable"
    fi

    [ -d "$ssh_dir" ] && ssh_dir_existed=true
    [ -d "$managed_dir" ] && managed_dir_existed=true
    [ -d "$config_dir" ] && config_dir_existed=true
    mkdir -p "$ssh_dir" "$managed_dir" "$config_dir" || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "failed to create the v2 SSH configuration directories"
    }
    [ -d "$ssh_dir" ] && [ ! -L "$ssh_dir" ] &&
        [ -d "$managed_dir" ] && [ ! -L "$managed_dir" ] &&
        [ -d "$config_dir" ] && [ ! -L "$config_dir" ] || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "v2 SSH configuration directories are invalid"
    }
    [ "$ssh_dir_existed" = true ] || chmod 700 "$ssh_dir"
    [ "$managed_dir_existed" = true ] || chmod 700 "$managed_dir"
    [ "$config_dir_existed" = true ] || chmod 700 "$config_dir"
    recover_v2_ssh_config_transaction "$managed_config" "$config" "$managed_dir" "$config_dir" || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config"
        die "failed to recover the interrupted v2 SSH configuration update"
    }
    [ -e "$managed_config" ] && managed_existed=true
    if [ -e "$config" ]; then
        config_existed=true
        config_mode="$(stat -f '%Lp' "$config" 2>/dev/null || stat -c '%a' "$config")"
    else
        config_mode=600
    fi
    managed_temporary="$(mktemp "$managed_dir/.devbox-v2.XXXXXX")"
    config_temporary="$(mktemp "$config_dir/.config.XXXXXX")"
    cp "$staged_managed" "$managed_temporary" && chmod 600 "$managed_temporary" &&
        cp "$staged_config" "$config_temporary" && chmod "$config_mode" "$config_temporary" || {
        command rm -f "$staged_source" "$staged_managed" "$staged_config" "$managed_temporary" "$config_temporary"
        die "failed to stage the v2 SSH configuration update"
    }
    command rm -f "$staged_source" "$staged_managed" "$staged_config"
    if [ "$managed_existed" = true ]; then
        managed_backup="$(mktemp "$managed_dir/.devbox-v2-backup.XXXXXX")"
        cp -p "$managed_config" "$managed_backup" || {
            command rm -f "$managed_temporary" "$config_temporary" "$managed_backup"
            die "failed to back up the managed v2 SSH configuration"
        }
    fi
    if [ "$config_existed" = true ]; then
        config_backup="$(mktemp "$config_dir/.config-backup.XXXXXX")"
        cp -p "$config" "$config_backup" || {
            command rm -f "$managed_temporary" "$config_temporary" "$managed_backup" "$config_backup"
            die "failed to back up $config"
        }
    fi
    journal="$managed_dir/.devbox-v2-transaction"
    journal_temporary="$(mktemp "$managed_dir/.devbox-v2-transaction.XXXXXX")"
    printf '%s\n%s\n%s\n%s\n' \
        "$managed_existed" "$config_existed" "$managed_backup" "$config_backup" >"$journal_temporary" &&
        chmod 600 "$journal_temporary" &&
        mv "$journal_temporary" "$journal" || {
        command rm -f "$managed_temporary" "$config_temporary" "$managed_backup" "$config_backup" "$journal_temporary"
        die "failed to journal the v2 SSH configuration update"
    }
    if ! mv "$managed_temporary" "$managed_config"; then
        recover_v2_ssh_config_transaction "$managed_config" "$config" "$managed_dir" "$config_dir" ||
            die "failed to roll back the v2 SSH configuration update"
        command rm -f "$config_temporary"
        die "failed to update the managed v2 SSH configuration"
    fi
    if ! mv "$config_temporary" "$config"; then
        recover_v2_ssh_config_transaction "$managed_config" "$config" "$managed_dir" "$config_dir" ||
            die "failed to roll back the v2 SSH configuration update"
        die "failed to update $config"
    fi
    command rm -f "$managed_backup" "$config_backup" "$journal"
}

ensure_v2_guest_ssh_access() {
    validate_v2_guest_preflight || {
        revoke_v2_guest_ssh_access ||
            die "v2 guest user has unsafe identity or privileges; managed direct SSH access could not be fully removed"
        die "v2 guest user has unsafe identity or privileges; managed direct SSH access was removed"
    }
    reconcile_v2_guest_workspace || {
        revoke_v2_guest_ssh_access ||
            die "v2 guest workspace is invalid; managed direct SSH access could not be fully removed"
        die "v2 guest workspace is invalid; managed direct SSH access was removed"
    }
    authorize_v2_host_key || return
    write_v2_ssh_config
}

revoke_v2_guest_ssh_access() {
    local status=0

    remove_v2_managed_guest_ssh_authorization || status=1
    remove_v2_ssh_config || status=1
    return "$status"
}

remove_v2_ssh_config() {
    local ssh_dir="$HOME/.ssh" managed_dir managed_config
    local config="$HOME/.ssh/config" config_dir temporary config_mode
    local managed_backup config_backup journal journal_temporary
    local begin_marker='# BEGIN devbox-v2' end_marker='# END devbox-v2'
    local begin_count end_count
    local managed_existed=false

    managed_dir="$ssh_dir/config.d"
    managed_config="$managed_dir/devbox-v2"
    [ -L "$config" ] && config="$(resolve_path "$config")"
    config_dir="$(dirname "$config")"
    recover_v2_ssh_config_transaction "$managed_config" "$config" "$managed_dir" "$config_dir" ||
        die "failed to recover the interrupted v2 SSH configuration update"
    [ -e "$managed_config" ] && managed_existed=true
    [ -e "$config" ] || {
        command rm -f "$managed_config"
        return
    }
    begin_count="$(grep -Fxc "$begin_marker" "$config" || true)"
    end_count="$(grep -Fxc "$end_marker" "$config" || true)"
    [ "$begin_count" -eq "$end_count" ] && [ "$begin_count" -le 1 ] ||
        die "$config contains malformed devbox-v2 markers"
    temporary="$(mktemp "$config_dir/.config.XXXXXX")"
    if ! awk '
        $0 == "# BEGIN devbox-v2" { skipping = 1; next }
        skipping && $0 == "# END devbox-v2" { skipping = 0; next }
        skipping { next }
        { print }
        END { if (skipping) exit 1 }
    ' "$config" >"$temporary"; then
        command rm -f "$temporary"
        die "failed to remove the managed v2 SSH configuration from $config"
    fi
    config_mode="$(stat -f '%Lp' "$config" 2>/dev/null || stat -c '%a' "$config")"
    chmod "$config_mode" "$temporary" || {
        command rm -f "$temporary"
        die "failed to preserve the mode of $config"
    }
    if [ "$managed_existed" = false ]; then
        mv "$temporary" "$config" || {
            command rm -f "$temporary"
            die "failed to update $config"
        }
        return
    fi

    managed_backup="$(mktemp "$managed_dir/.devbox-v2-backup.XXXXXX")"
    config_backup="$(mktemp "$config_dir/.config-backup.XXXXXX")"
    cp -p "$managed_config" "$managed_backup" &&
        cp -p "$config" "$config_backup" || {
        command rm -f "$temporary" "$managed_backup" "$config_backup"
        die "failed to back up the v2 SSH configuration cleanup"
    }
    journal="$managed_dir/.devbox-v2-transaction"
    journal_temporary="$(mktemp "$managed_dir/.devbox-v2-transaction.XXXXXX")"
    printf '%s\n%s\n%s\n%s\n' true true "$managed_backup" "$config_backup" >"$journal_temporary" &&
        chmod 600 "$journal_temporary" &&
        mv "$journal_temporary" "$journal" || {
        command rm -f "$temporary" "$managed_backup" "$config_backup" "$journal_temporary"
        die "failed to journal the v2 SSH configuration cleanup"
    }
    if ! mv "$temporary" "$config"; then
        recover_v2_ssh_config_transaction "$managed_config" "$config" "$managed_dir" "$config_dir" ||
            die "failed to roll back the v2 SSH configuration cleanup"
        die "failed to update $config"
    fi
    if ! rm -f -- "$managed_config"; then
        recover_v2_ssh_config_transaction "$managed_config" "$config" "$managed_dir" "$config_dir" ||
            die "failed to roll back the v2 SSH configuration cleanup"
        die "failed to remove the managed v2 SSH configuration"
    fi
    command rm -f "$managed_backup" "$config_backup" "$journal"
}

provision_v2_guest() (
    local force="${1:-false}" host_digest guest_digest

    create_v2_bundle_snapshot || return
    trap 'command rm -rf "$V2_BUNDLE_SNAPSHOT"' EXIT
    host_digest="$V2_BUNDLE_DIGEST"
    guest_digest="$(v2_guest_provision_digest)" || return
    if [ "$force" = false ] && [ "$host_digest" = "$guest_digest" ]; then
        if v2_guest_bundle_is_valid "$host_digest"; then
            log "v2 provisioning is current."
            validate_v2_guest_preflight || {
                revoke_v2_guest_ssh_access ||
                    die "v2 guest user has unsafe identity or privileges; managed direct SSH access could not be fully removed"
                die "v2 guest user has unsafe identity or privileges; managed direct SSH access was removed"
            }
            sync_v2_guest_config || return
            ensure_v2_guest_ssh_access || return
            return
        fi
        log "v2 provisioning bundle is missing or invalid; refreshing."
    fi
    run_v2_guest_provisioning "$host_digest" "$V2_BUNDLE_ARCHIVE" || return
)

stop_v2_vm() {
    local force="${1:-false}" state

    if [ ! -e "$DEVBOX_V2_COLIMA_PROFILE" ]; then
        log "v2 VM is already stopped."
        return
    fi
    state="$(v2_state)"
    case "$state" in
        '' | Stopped) log "v2 VM is already stopped." ;;
        Running)
            if [ "$force" = true ]; then
                v2_colima stop --force "$V2_PROFILE"
            else
                v2_colima stop "$V2_PROFILE"
            fi
            ;;
        *) die "v2 VM is in state '$state'; wait for it to settle and retry" ;;
    esac
}

show_v2_status() {
    local record

    if [ ! -e "$DEVBOX_V2_COLIMA_PROFILE" ]; then
        log "devbox-v2: Not created"
        return
    fi
    record="$(v2_colima list --json 2>/dev/null | jq -c --arg profile "$V2_PROFILE" 'select(.name == $profile)' | head -n 1)"
    if [ -z "$record" ]; then
        log "devbox-v2: Not created"
        return
    fi
    jq -r '"devbox-v2: \(.status) | \(.arch) | \(.cpus) CPU | \(.memory / 1073741824) GiB memory | \(.disk / 1073741824) GiB disk"' <<<"$record"
}

run_v2() {
    local action="${1:-}" force=false status
    shift || true
    configure_v2_paths

    case "$action" in
        start | provision)
            [ $# -eq 0 ] || die "Usage: devbox v2 <start|provision|connect|exec|status|stop|destroy>"
            check_host_platform
            check_v2_dependencies
            acquire_lock lifecycle
            start_v2_vm
            if provision_v2_guest "$([ "$action" = provision ] && printf true || printf false)"; then
                release_lock
            else
                status=$?
                release_lock
                return "$status"
            fi
            ;;
        connect)
            [ $# -eq 0 ] || die "Usage: devbox v2 connect"
            require_running_v2_vm
            v2_guest zsh -l
            ;;
        exec)
            [ $# -gt 0 ] || die "Usage: devbox v2 exec <command> [args...]"
            require_running_v2_vm
            v2_guest "$@"
            ;;
        status)
            [ $# -eq 0 ] || die "Usage: devbox v2 status"
            show_v2_status
            ;;
        stop)
            case "${1:-}" in
                '') ;;
                --force) force=true; shift ;;
                *) die "Usage: devbox v2 stop [--force]" ;;
            esac
            [ $# -eq 0 ] || die "Usage: devbox v2 stop [--force]"
            acquire_lock lifecycle
            stop_v2_vm "$force"
            release_lock
            ;;
        destroy)
            [ $# -eq 0 ] || die "Usage: devbox v2 destroy"
            acquire_lock lifecycle
            if ! v2_profile_exists; then
                remove_v2_ssh_config
                release_lock
                log "devbox-v2: Not created"
                return
            fi
            check_v2_ownership
            printf "Type '%s' to delete the v2 VM and all its container runtime data: " "$V2_PROFILE"
            read -r confirm
            [ "$confirm" = "$V2_PROFILE" ] || die "Aborted"
            if [ "$(v2_state)" = Running ]; then
                remove_v2_managed_guest_ssh_authorization || {
                    status=$?
                    release_lock
                    return "$status"
                }
            fi
            v2_colima delete --data --force "$V2_PROFILE" || {
                status=$?
                release_lock
                return "$status"
            }
            remove_v2_ssh_config
            release_lock
            log "Destroyed v2 VM runtime data. No host project or data directories were used."
            ;;
        *) die "Usage: devbox v2 <start|provision|connect|exec|status|stop|destroy>" ;;
    esac
}
