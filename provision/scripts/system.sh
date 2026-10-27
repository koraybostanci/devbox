#!/bin/bash

# Sources resolve at runtime from $DEVBOX_PROVISION_ROOT, a root-owned bundled
# tree that is not statically followable. This file-wide disable must stay
# before the first command to have effect.
# shellcheck disable=SC1091

set -Eeuo pipefail
trap 'printf "ERROR: system provisioning failed at line %s\n" "$LINENO" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/docker.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/apps.sh"

# Keep the guest user's toolchain and caches on the large Lima data disk
# (mounted under /mnt/lima-*), not the fixed-size root disk. A home that already
# holds data on the root disk predates this layout; recreate the VM instead.
relocate_guest_home() {
    local home=/home/devbox data_root target fstab_entry

    data_root="$(devbox_lima_data_root)" || data_root=""
    # `|| { ... }` is the intended failure branch: it only runs when the data
    # root is missing or is not a mountpoint.
    # shellcheck disable=SC2015
    [ -n "$data_root" ] && mountpoint -q "$data_root" || {
        printf 'ERROR: Lima ext4 data disk not found; refusing to leave /home/devbox on the root disk\n' >&2
        return 1
    }
    target="$data_root/devbox-home"
    mkdir -p "$target"
    chown devbox:devbox "$target"
    chmod 700 "$target"
    if ! mountpoint -q "$home"; then
        [ -z "$(ls -A "$home" 2>/dev/null)" ] || {
            printf 'ERROR: %s holds data on the root disk; back it up, then run devbox destroy and devbox start\n' \
                "$home" >&2
            return 1
        }
        mkdir -p "$home"
        mount --bind "$target" "$home"
        sudo -u devbox cp -rT --update=none /etc/skel "$home"
    fi
    devbox_home_is_on_lima_data_disk "$home" "$target" "$data_root" || {
        printf 'ERROR: %s is not bind-mounted from the Lima data disk at %s\n' "$home" "$target" >&2
        return 1
    }
    fstab_entry="$target $home none bind,nofail,x-systemd.requires-mounts-for=$data_root 0 0"
    # The rewrite is published from /etc's own directory with mode 644 applied
    # before the mv, and an unchanged content keeps the current /etc/fstab.
    devbox_publish_atomic /etc/fstab 644 --skip-if-same -- \
        devbox_fstab_content /etc/fstab "$home" "$fstab_entry"
}

# Emit the fstab as-is apart from the managed home entry, replacing any prior
# entry for that home, then re-adding the single managed entry.
devbox_fstab_content() {
    local fstab_file="$1" home="$2" fstab_entry="$3"

    awk -v home="$home" 'NF < 2 || $1 ~ /^#/ || $2 != home { print }' "$fstab_file"
    printf '%s\n' "$fstab_entry"
}

configure_devbox_guest_identity() {
    local zsh_path

    zsh_path="$(command -v zsh)"
    getent passwd devbox >/dev/null ||
        useradd --no-create-home --home-dir /home/devbox --shell "$zsh_path" --user-group devbox
    usermod --shell "$zsh_path" devbox
    [ "$(getent passwd devbox | cut -d: -f6)" = /home/devbox ] || {
        printf 'ERROR: existing devbox guest user has an unexpected home\n' >&2
        return 1
    }
    relocate_guest_home
    sudo -u devbox mkdir -p -m 700 /home/devbox/workspace
}

install_guest_chromium() {
    local attempt status=1

    systemctl enable --now snapd.socket
    # snap wait has no timeout option; use coreutils to bound the seed wait
    # so a stalled seed cannot hang provisioning forever.
    timeout 45m snap wait system seed.loaded
    # snapd can transiently reject installs while the seed is still settling:
    # retry, capture the last status, and fail closed on a final failure.
    for attempt in 1 2 3; do
        if snap list chromium >/dev/null 2>&1; then
            status=0
            break
        fi
        snap install chromium --channel=stable && status=0 || status=$?
    done
    [ "$status" = 0 ] || {
        printf 'ERROR: chromium snap installation failed after %s attempts\n' "$attempt" >&2
        return 1
    }
    # snapd otherwise auto-refreshes Chromium between provisioning cycles,
    # silently moving the guest's browser ahead of the smoke-tested channel
    # state; hold the refresh so the pinned channel install stays in place.
    snap refresh --hold chromium
}

# Keep the helpers above sourceable by the static gate without running the
# package installation and provisioning stages below.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi
cd /

packages=(
    apparmor
    bat
    build-essential
    ca-certificates
    curl
    dbus-user-session
    fuse-overlayfs
    fzf
    gh
    git
    git-delta
    gnupg
    iptables
    jq
    libbz2-dev
    libffi-dev
    liblzma-dev
    libncurses-dev
    libreadline-dev
    libsqlite3-dev
    libssl-dev
    libxml2-dev
    libxmlsec1-dev
    openjdk-25-jdk-headless
    rustup
    slirp4netns
    snapd
    tk-dev
    uidmap
    unzip
    vim
    wget
    xz-utils
    zip
    zlib1g-dev
    zsh
    zsh-autosuggestions
    zsh-syntax-highlighting
)

getent hosts archive.ubuntu.com >/dev/null || {
    printf 'ERROR: DNS resolution failed. Configure Colima DNS and retry provisioning.\n' >&2
    exit 1
}

marker=/var/lib/apt/lists/.devbox-updated
if [ ! -f "$marker" ] || find "$marker" -mmin +1440 -print -quit | grep -q .; then
    apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 update -qq
    touch "$marker"
fi

apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 install \
    -y --no-install-recommends "${packages[@]}"

configure_devbox_guest_identity
devbox_prepare_rootless_docker
install_guest_chromium

install -m 0755 "$DEVBOX_PROVISION_ROOT/config/guest/devbox" /usr/local/bin/devbox
