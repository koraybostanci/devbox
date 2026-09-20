#!/bin/bash

V2_PROFILE="devbox-v2"
V2_OWNER_VERSION="devbox-v2-profile-v1"

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
    DEVBOX_V2_LOCK_DIR="$DEVBOX_V2_STATE_ROOT/locks"
    DEVBOX_V2_COLIMA_PROFILE="$DEVBOX_V2_COLIMA_HOME/$V2_PROFILE"
    DEVBOX_V2_COLIMA_CONFIG="$DEVBOX_V2_COLIMA_PROFILE/colima.yaml"
    DEVBOX_V2_COLIMA_OWNER="$DEVBOX_V2_COLIMA_PROFILE/.devbox-owner"
    DEVBOX_V2_DOCKER_CONFIG="$DEVBOX_V2_CONFIG_ROOT/docker"
    DEVBOX_LOCK_DIR="$DEVBOX_V2_LOCK_DIR"
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

v2_guest() {
    v2_colima ssh -p "$V2_PROFILE" -- "$@"
}

require_running_v2_vm() {
    [ "$(v2_state)" = Running ] || die "v2 VM is not running; run 'devbox v2 start' first"
}

wait_for_v2_ssh() {
    local attempts=60 attempt

    log "Waiting for v2 VM SSH readiness..."
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if v2_guest true >/dev/null 2>&1; then
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

    v2_guest bash -c '
        set -Eeuo pipefail
        digest="$1"
        root="$HOME/.local/share/devbox-v2/bundles"
        target="$root/$digest"
        mkdir -p "$root"
        temporary="$(mktemp -d "$root/.bundle.XXXXXX")"
        trap "rm -rf \"$temporary\"" EXIT
        tar -xf - -C "$temporary"
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
        chmod 600 "$temporary/provision/.devbox-bundle.sha256"
        if [ -d "$target" ]; then
            [ ! -L "$target" ] || {
                printf "ERROR: existing v2 bundle is not a directory\n" >&2
                exit 1
            }
            cached="$(bundle_digest "$target")"
            if [ "$(cat "$target/.devbox-bundle.sha256" 2>/dev/null || true)" = "$digest" ] && [ "$cached" = "$digest" ]; then
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

    v2_guest bash -c '
        set -Eeuo pipefail
        digest="$1"
        target="$HOME/.local/share/devbox-v2/bundles/$digest"
        [ -d "$target" ] && [ ! -L "$target" ] || exit 1
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

sync_v2_guest_env() {
    load_env v2
    render_guest_env | v2_guest bash -c '
        set -Eeuo pipefail
        umask 077
        directory="$HOME/.config/devbox-v2"
        mkdir -p "$directory"
        temporary="$(mktemp "$directory/.env.XXXXXX")"
        cat >"$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$directory/env"
    '
}

v2_guest_provision_digest() {
    v2_guest bash -c 'cat "$HOME/.local/state/devbox-v2/provision.sha256" 2>/dev/null || true'
}

run_v2_guest_provisioning() {
    local digest="$1" archive="$2"

    stream_v2_bundle "$digest" "$archive"
    log "Provisioning v2 guest tools from bundle $digest..."
    v2_guest bash -c '
        set -Eeuo pipefail
        export DEVBOX_PROVISION_ROOT="$HOME/.local/share/devbox-v2/bundles/$1"
        export DEVBOX_GUEST_CONFIG_ROOT="$HOME/.config/devbox-v2"
        export DEVBOX_NO_MOUNTS=true
        sudo bash "$DEVBOX_PROVISION_ROOT/scripts/system.sh"
        bash "$DEVBOX_PROVISION_ROOT/scripts/tools.sh"
        bash "$DEVBOX_PROVISION_ROOT/scripts/verify.sh"
    ' _ "$digest"
    printf '%s\n' "$digest" | v2_guest bash -c '
        set -Eeuo pipefail
        umask 077
        directory="$HOME/.local/state/devbox-v2"
        mkdir -p "$directory"
        temporary="$(mktemp "$directory/.provision.XXXXXX")"
        cat >"$temporary"
        chmod 600 "$temporary"
        mv "$temporary" "$directory/provision.sha256"
    '
}

provision_v2_guest() (
    local force="${1:-false}" host_digest guest_digest

    create_v2_bundle_snapshot
    trap 'command rm -rf "$V2_BUNDLE_SNAPSHOT"' EXIT
    host_digest="$V2_BUNDLE_DIGEST"
    guest_digest="$(v2_guest_provision_digest)"
    if [ "$force" = false ] && [ "$host_digest" = "$guest_digest" ]; then
        if v2_guest_bundle_is_valid "$host_digest"; then
            log "v2 provisioning is current."
            return
        fi
        log "v2 provisioning bundle is missing or invalid; refreshing."
    fi
    run_v2_guest_provisioning "$host_digest" "$V2_BUNDLE_ARCHIVE"
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
    local action="${1:-}" force=false
    shift || true
    configure_v2_paths

    case "$action" in
        start | provision)
            [ $# -eq 0 ] || die "Usage: devbox v2 <start|provision|connect|exec|status|stop|destroy>"
            check_host_platform
            check_v2_dependencies
            acquire_lock lifecycle
            start_v2_vm
            sync_v2_guest_env
            provision_v2_guest "$([ "$action" = provision ] && printf true || printf false)"
            release_lock
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
            if [ ! -e "$DEVBOX_V2_COLIMA_PROFILE" ]; then
                log "devbox-v2: Not created"
                return
            fi
            check_v2_ownership
            printf "Type '%s' to delete the v2 VM and all its container runtime data: " "$V2_PROFILE"
            read -r confirm
            [ "$confirm" = "$V2_PROFILE" ] || die "Aborted"
            acquire_lock lifecycle
            [ -z "$(v2_state)" ] || v2_colima delete --data --force "$V2_PROFILE"
            release_lock
            log "Destroyed v2 VM runtime data. No host project or data directories were used."
            ;;
        *) die "Usage: devbox v2 <start|provision|connect|exec|status|stop|destroy>" ;;
    esac
}
