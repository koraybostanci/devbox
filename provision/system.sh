#!/bin/bash
# Runs as root. Installs system-level packages required by user-level tools.
set -eux

export DEBIAN_FRONTEND=noninteractive

# Only update apt lists if they are older than 24 hours
if [ ! -f /var/lib/apt/lists/.devbox-updated ] || \
   [ "$(find /var/lib/apt/lists/.devbox-updated -mmin +1440 2>/dev/null | wc -l)" -gt 0 ]; then
    apt-get update -qq
    touch /var/lib/apt/lists/.devbox-updated
fi

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
    liblzma-dev \
    jq \
    fzf \
    bat \
    git-delta \
    gh

# Fix Ubuntu network interface naming issue that causes boot hangs with Lima/QEMU
# (no-op on VZ driver, but safe to apply)
if [ -f /etc/netplan/50-cloud-init.yaml ]; then
    sed -i 's/enp0s0/eth0/g' /etc/netplan/50-cloud-init.yaml 2>/dev/null || true
fi
