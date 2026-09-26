#!/bin/bash

set -Eeuo pipefail
trap 'printf "ERROR: system provisioning failed at line %s\n" "$LINENO" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/docker.sh"

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

# Keep the guest user's toolchain and caches on the large Lima data disk
# (mounted under /mnt/lima-*), not the fixed-size root disk.
relocate_guest_home() {
    local guest_user="$1"
    local guest_home="/home/$1"
    local data_root target fstab_entry temporary

    [ "$guest_user" = devbox ] || return 1
    data_root="$(devbox_lima_data_root)" || data_root=""
    [ -n "$data_root" ] && mountpoint -q "$data_root" || {
        printf 'ERROR: Lima ext4 data disk not found; refusing to leave /home/devbox on the root disk\n' >&2
        return 1
    }
    target="$data_root/devbox-home"
    [ ! -L "$target" ] || {
        printf 'ERROR: devbox data-disk home target is a symlink: %s\n' "$target" >&2
        return 1
    }
    mkdir -p "$target"
    # Hand the destination root to devbox before migration. The state helper
    # drops to that user for chmod, copying, and source cleanup; root must not
    # write through the guest-controlled destination tree.
    chown -h "$guest_user":"$guest_user" "$target"
    if ! mountpoint -q "$guest_home"; then
        # A symlinked home is unsafe; reject it rather than following it.
        [ ! -L "$guest_home" ] || {
            printf 'ERROR: devbox guest home is a symlink: %s\n' "$guest_home" >&2
            return 1
        }
        mkdir -p "$guest_home"
        devbox_migrate_guest_home_contents "$guest_home" "$target"
        mount --bind "$target" "$guest_home" || return 1
    fi
    if ! devbox_home_is_on_lima_data_disk "$guest_home" "$target" "$data_root"; then
        printf 'ERROR: %s is not bind-mounted from the Lima data disk at %s\n' \
            "$guest_home" "$target" >&2
        return 1
    fi
    fstab_entry="$target $guest_home none bind,nofail,x-systemd.requires-mounts-for=$data_root 0 0"
    temporary="$(mktemp /etc/.fstab.XXXXXX)"
    awk -v home="$guest_home" 'NF < 2 || $1 ~ /^#/ || $2 != home { print }' /etc/fstab >"$temporary"
    printf '%s\n' "$fstab_entry" >>"$temporary"
    if ! cmp -s "$temporary" /etc/fstab; then
        chown root:root "$temporary"
        chmod 644 "$temporary"
        mv "$temporary" /etc/fstab
    else
        rm -f "$temporary"
    fi
    chown "$guest_user":"$guest_user" "$guest_home"
    chmod 700 "$guest_home"
}

configure_devbox_guest_identity() {
    local guest_user="${DEVBOX_GUEST_USER:-devbox}"
    local guest_home="/home/$guest_user"
    local workspace="$guest_home/workspace"
    local passwd_entry
    local guest_uid
    local guest_gid
    local group_entry
    local group_name
    local group_gid
    local group_members
    local group_names
    local uid_matches
    local gid_matches
    local zsh_path
    local existing_user=false

    [ "$guest_user" = devbox ] || {
        printf 'ERROR: invalid devbox guest user\n' >&2
        return 1
    }
    zsh_path="$(command -v zsh)"
    if getent passwd "$guest_user" >/dev/null; then
        existing_user=true
    else
        useradd --create-home --home-dir "$guest_home" --shell "$zsh_path" --user-group "$guest_user"
    fi
    passwd_entry="$(getent passwd "$guest_user")"
    guest_uid="$(printf '%s\n' "$passwd_entry" | cut -d: -f3)"
    guest_gid="$(printf '%s\n' "$passwd_entry" | cut -d: -f4)"
    group_entry="$(getent group "$guest_gid" || true)"
    group_name="$(printf '%s\n' "$group_entry" | cut -d: -f1)"
    group_gid="$(printf '%s\n' "$group_entry" | cut -d: -f3)"
    group_members="$(printf '%s\n' "$group_entry" | cut -d: -f4)"
    group_names="$(id -nG "$guest_user")" || {
        printf 'ERROR: devbox guest user group membership is unavailable\n' >&2
        return 1
    }
    uid_matches="$(getent passwd | awk -F: -v uid="$guest_uid" '$3 == uid { count++ } END { print count + 0 }')"
    gid_matches="$(getent group | awk -F: -v gid="$guest_gid" '$3 == gid { count++ } END { print count + 0 }')"
    devbox_guest_identity_is_safe \
        "$guest_user" "$guest_uid" "$guest_gid" "$group_name" "$group_gid" "$group_members" "$group_names" \
        "$uid_matches" "$gid_matches" || {
        if [ "$existing_user" = true ]; then
            printf 'ERROR: existing devbox guest user has an unsafe identity or group\n' >&2
        else
            printf 'ERROR: new devbox guest user has an unsafe identity or group\n' >&2
        fi
        return 1
    }
    if [ "$existing_user" = true ]; then
        [ "$(printf '%s\n' "$passwd_entry" | cut -d: -f6)" = "$guest_home" ] || {
            printf 'ERROR: existing devbox guest user has an unexpected home\n' >&2
            return 1
        }
        usermod --shell "$zsh_path" "$guest_user"
    fi

    relocate_guest_home "$guest_user" || return 1
    [ ! -L "$guest_home" ] && [ -d "$guest_home" ] || {
        printf 'ERROR: devbox guest home must be a real directory: %s\n' "$guest_home" >&2
        return 1
    }
    sudo -u "$guest_user" -- env HOME="$guest_home" PWD="$guest_home" bash -c '
        set -Eeuo pipefail
        guest_home="$1"
        workspace="$2"
        [ -d "$guest_home" ] && [ ! -L "$guest_home" ] || exit 1
        cd -- "$guest_home"
        export HOME="$guest_home"
        export PWD="$PWD"
        [ ! -L "$workspace" ] || exit 1
        [ ! -e "$workspace" ] || [ -d "$workspace" ] || exit 1
        mkdir -p "$workspace"
        chmod 700 "$HOME" "$workspace"
    ' _ "$guest_home" "$workspace" || {
        printf 'ERROR: devbox guest workspace must be a real directory: %s\n' "$workspace" >&2
        return 1
    }
}

install_guest_chromium() {
    local architecture

    architecture="$(dpkg --print-architecture)"
    [ "$architecture" = arm64 ] || {
        printf 'ERROR: devbox requires Ubuntu ARM64 Chromium; found package architecture %s\n' \
            "$architecture" >&2
        return 1
    }
    command -v snap >/dev/null 2>&1 || {
        printf 'ERROR: snapd is required to install Ubuntu Chromium\n' >&2
        return 1
    }
    systemctl enable --now snapd.socket
    snap wait system seed.loaded
    if ! snap list chromium >/dev/null 2>&1; then
        snap install chromium --channel=stable
    fi
    [ -x /snap/bin/chromium ] || {
        printf 'ERROR: Ubuntu Chromium snap did not install /snap/bin/chromium\n' >&2
        return 1
    }
    snap run chromium --version 2>&1 | grep -q '^Chromium '
}

# Keep the helpers above sourceable by the static gate without running the
# package installation and provisioning stages below.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

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
    openjdk-21-jdk-headless
    rustup
    slirp4netns
    snapd
    tk-dev
    uidmap
    unzip
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

for package in "${packages[@]}"; do
    dpkg-query -W -f='${db:Status-Status}\n' "$package" | grep -qx installed || {
        printf 'ERROR: required package was not installed: %s\n' "$package" >&2
        exit 1
    }
done

configure_devbox_guest_identity
devbox_prepare_rootless_docker
install_guest_chromium

install -m 0755 "$DEVBOX_PROVISION_ROOT/config/guest/devbox" /usr/local/bin/devbox

# Root-only tools run from this root phase; the unprivileged tools phase cannot
# write /usr/local/bin.
source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/apps.sh"
set -a
source "$DEVBOX_PROVISION_ROOT/versions.env"
set +a
install_databricks
