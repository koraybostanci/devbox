#!/bin/bash
# Runs as root. Installs system-level packages required by user-level tools.
set -eux

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends \
    curl \
    git \
    wget \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    zsh \
    build-essential \
    libssl-dev \
    libffi-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncursesw5-dev \
    xz-utils \
    tk-dev \
    libxml2-dev \
    libxmlsec1-dev \
    libffi-dev \
    liblzma-dev \
    jq \
    fzf \
    bat \
    git-delta \
    gh

# Fix .guest home directory suffix — Lima cloud-init appends .guest or .linux
# when the macOS UID conflicts. Normalize to /home/<user>.
LIMA_USER=$(id -nu 1000 2>/dev/null || true)
if [ -n "$LIMA_USER" ]; then
    CURRENT_HOME=$(getent passwd "$LIMA_USER" | cut -d: -f6)
    DESIRED_HOME="/home/$LIMA_USER"
    if [ "$CURRENT_HOME" != "$DESIRED_HOME" ] && [ -d "$CURRENT_HOME" ]; then
        mv "$CURRENT_HOME" "$DESIRED_HOME"
        usermod -d "$DESIRED_HOME" "$LIMA_USER"
    fi
fi

# Fix Ubuntu network interface naming issue that causes boot hangs with Lima/QEMU
# (no-op on VZ driver, but safe to apply)
if [ -f /etc/netplan/50-cloud-init.yaml ]; then
    sed -i 's/enp0s0/eth0/g' /etc/netplan/50-cloud-init.yaml 2>/dev/null || true
fi
