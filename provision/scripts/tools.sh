#!/bin/bash

set -Eeuo pipefail
trap 'printf "ERROR: guest provisioning failed at line %s\n" "$LINENO" >&2' ERR

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"

source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/runtimes.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/apps.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/docker.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/configure.sh"

set -a
source "$HOME/.config/devbox/config"
source "$DEVBOX_PROVISION_ROOT/versions.env"
set +a

mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.pyenv/bin:$HOME/.pyenv/shims:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH"

install_runtimes
install_apps
devbox_configure_rootless_docker
configure_guest

printf 'Guest provisioning complete.\n'
