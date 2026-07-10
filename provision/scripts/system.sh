#!/bin/bash
# Runs as root. Installs system-level packages required by user-level tools.
set -e

export DEBIAN_FRONTEND=noninteractive

# Fix /etc/resolv.conf if it is a dangling symlink (Ubuntu 24.04 cloud image ships
# /etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf, but systemd-resolved
# is not installed). Without a real resolv.conf, apt-get update fails with NXDOMAIN.
if [ ! -f /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    printf 'nameserver 192.168.5.3\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi

# Skip apt-get update only when the lists are fresh (<24 h) AND packages are installed
# (i.e. an idempotent re-run, not a first boot where the lists may be empty).
echo "--- system: apt update"
if command -v curl >/dev/null && \
   [ -f /var/lib/apt/lists/.devbox-updated ] && \
   [ "$(find /var/lib/apt/lists/.devbox-updated -mmin +1440 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "--- system: apt lists fresh, skipping update"
else
    apt-get update -qq
    touch /var/lib/apt/lists/.devbox-updated
fi

echo "--- system: installing packages"
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

echo "--- system: done"

# Fix Ubuntu network interface naming issue that causes boot hangs with Lima/QEMU
# (no-op on VZ driver, but safe to apply)
if [ -f /etc/netplan/50-cloud-init.yaml ]; then
    sed -i 's/enp0s0/eth0/g' /etc/netplan/50-cloud-init.yaml 2>/dev/null || true
fi
