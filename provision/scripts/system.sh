#!/bin/bash

set -Eeuo pipefail
trap 'printf "ERROR: system provisioning failed at line %s\n" "$LINENO" >&2' ERR

export DEBIAN_FRONTEND=noninteractive

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

configure_v2_guest_identity() {
    local guest_user="${DEVBOX_V2_GUEST_USER:-devbox}"
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
        printf 'ERROR: invalid v2 guest user\n' >&2
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
        printf 'ERROR: v2 guest user group membership is unavailable\n' >&2
        return 1
    }
    uid_matches="$(getent passwd | awk -F: -v uid="$guest_uid" '$3 == uid { count++ } END { print count + 0 }')"
    gid_matches="$(getent group | awk -F: -v gid="$guest_gid" '$3 == gid { count++ } END { print count + 0 }')"
    v2_guest_identity_is_safe \
        "$guest_user" "$guest_uid" "$guest_gid" "$group_name" "$group_gid" "$group_members" "$group_names" \
        "$uid_matches" "$gid_matches" || {
        if [ "$existing_user" = true ]; then
            printf 'ERROR: existing v2 guest user has an unsafe identity or group\n' >&2
        else
            printf 'ERROR: new v2 guest user has an unsafe identity or group\n' >&2
        fi
        return 1
    }
    if [ "$existing_user" = true ]; then
        [ "$(printf '%s\n' "$passwd_entry" | cut -d: -f6)" = "$guest_home" ] || {
            printf 'ERROR: existing v2 guest user has an unexpected home\n' >&2
            return 1
        }
        usermod --shell "$zsh_path" "$guest_user"
    fi

    [ ! -L "$guest_home" ] && [ -d "$guest_home" ] || {
        printf 'ERROR: v2 guest home must be a real directory: %s\n' "$guest_home" >&2
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
        printf 'ERROR: v2 guest workspace must be a real directory: %s\n' "$workspace" >&2
        return 1
    }
}

packages=(
    bat
    build-essential
    ca-certificates
    curl
    fzf
    gh
    git
    git-delta
    golang-go
    gnupg
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
    tk-dev
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

configure_v2_guest_identity
