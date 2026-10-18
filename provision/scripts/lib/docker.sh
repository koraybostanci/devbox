#!/bin/bash
# Docker helpers shared by root provisioning, the devbox-user setup, and
# readiness checks. The rootful Colima Engine remains managed by Colima and is
# reserved for root-managed services.

devbox_docker_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

# Run the Docker CLI against one endpoint, ignoring inherited context and TLS
# settings. An empty endpoint selects the CLI's current context.
devbox_docker() {
    local endpoint="$1"
    shift
    if [ -n "$endpoint" ]; then
        env -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
            DOCKER_HOST="$endpoint" docker "$@"
    else
        env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
            docker "$@"
    fi
}

devbox_rootless_endpoint() {
    printf 'unix:///run/user/%s/docker.sock\n' "$(id -u)"
}

# Bind a user-systemd invocation to the manager of the invoking user: both the
# runtime directory and the session bus derive from the UID, not from an
# inherited environment. Callers that need the same context while running
# something other than `systemctl --user` (e.g. dockerd-rootless-setuptools)
# must still export these variables themselves before that command.
devbox_user_systemctl() {
    # Split so a failed `id -u` cannot mask the export's return value.
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    systemctl --user "$@"
}

# useradd allocates subordinate IDs from SUB_UID_MIN (100000). Require at least
# 65,536 for the account in each file, never starting below 100000 where they
# could map real users.
devbox_has_subid_ranges() {
    local account="$1" file
    shift
    [ $# -gt 0 ] || set -- /etc/subuid /etc/subgid
    for file in "$@"; do
        awk -F: -v account="$account" '
            $1 == account && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ &&
                $2 >= 100000 && $3 >= 65536 { found = 1 }
            END { exit !found }
        ' "$file" || return 1
    done
}

# Load Ubuntu's packaged RootlessKit AppArmor profile only when unprivileged
# user namespaces are restricted. Never change the kernel restriction.
devbox_prepare_rootlesskit_apparmor_profile() {
    local setting_file="${1:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"
    local profile_file="${2:-/etc/apparmor.d/rootlesskit}"

    if [ "$(cat "$setting_file" 2>/dev/null)" = 1 ]; then
        apparmor_parser -r "$profile_file"
    fi
}

# Root phase. Install the rootless extras matching Colima's Engine from its
# already-configured APT source, without changing the rootful Engine.
devbox_prepare_rootless_docker() {
    local engine_version

    [ "$(dpkg-query -W -f='${db:Status-Status}' docker-ce 2>/dev/null)" = installed ] || {
        devbox_docker_error "expected Colima's docker-ce package; refusing to install another Docker Engine"
        return 1
    }
    engine_version="$(dpkg-query -W -f='${Version}' docker-ce)"
    if [ "$(dpkg-query -W -f='${db:Status-Status} ${Version}' docker-ce-rootless-extras 2>/dev/null)" != \
        "installed $engine_version" ]; then
        apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
            -y --no-install-recommends --no-upgrade \
            install "docker-ce-rootless-extras=$engine_version"
    fi
    # --no-upgrade silently skips an installed extras package at another version.
    [ "$(dpkg-query -W -f='${Version}' docker-ce-rootless-extras)" = "$engine_version" ] || {
        devbox_docker_error "docker-ce-rootless-extras does not match Docker Engine $engine_version"
        return 1
    }

    # The packaged profile grants user namespaces to /usr/bin/rootlesskit only.
    devbox_prepare_rootlesskit_apparmor_profile || return 1

    devbox_has_subid_ranges devbox || {
        devbox_docker_error 'devbox has no subordinate UID/GID range of 65,536 IDs from 100000; recreate the VM'
        return 1
    }
    loginctl enable-linger devbox
    # Start the user manager, not Docker, so the unprivileged phase can
    # configure and start its own service.
    systemctl start "user@$(id -u devbox).service"
}

# Unprivileged tools phase, run as devbox. The rootful daemon stays enabled for
# root-managed services; --force permits a second, per-user systemd service.
devbox_configure_rootless_docker() {
    # Split so a failed `id -u` cannot mask the export's return value. The
    # exports stay here because dockerd-rootless-setuptool.sh below runs
    # outside devbox_user_systemctl and needs the same context.
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    # A working daemon (rootless context present, user service active) is not
    # reinstalled: `install --force` would redefine it on every re-provision.
    # This is a simplification, not an added layer: less work per run, no
    # markers, no new state. Re-assert the enablement, keep the context.
    if devbox_docker '' context inspect rootless >/dev/null 2>&1 &&
        devbox_user_systemctl is-active --quiet docker.service; then
        devbox_user_systemctl enable --now docker.service
        devbox_docker '' context use rootless >/dev/null
        return
    fi
    env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
        /usr/bin/dockerd-rootless-setuptool.sh install --force
    devbox_user_systemctl daemon-reload
    devbox_user_systemctl enable --now docker.service
    devbox_docker '' context use rootless >/dev/null
}
