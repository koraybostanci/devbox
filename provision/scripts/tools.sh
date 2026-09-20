#!/bin/bash

set -Eeuo pipefail
trap 'printf "ERROR: guest provisioning failed at line %s\n" "$LINENO" >&2' ERR

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/provision}"
export DEVBOX_GUEST_CONFIG_ROOT="${DEVBOX_GUEST_CONFIG_ROOT:-$HOME/.config/devbox}"

source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/runtimes.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/apps.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/configure.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/addons.sh"

set -a
source "$DEVBOX_GUEST_CONFIG_ROOT/env"
source "$DEVBOX_PROVISION_ROOT/versions.env"
set +a

install_runtimes
install_apps
configure_guest
install_addons

printf 'Guest provisioning complete.\n'
