#!/bin/bash

set -Eeuo pipefail
trap 'printf "ERROR: guest provisioning failed at line %s\n" "$LINENO" >&2' ERR

source /provision/scripts/lib/common.sh
source /provision/scripts/lib/runtimes.sh
source /provision/scripts/lib/apps.sh
source /provision/scripts/lib/configure.sh
source /provision/scripts/lib/addons.sh

set -a
source "$HOME/.config/devbox/env"
source /provision/versions.env
set +a

install_runtimes
install_apps
configure_guest
install_addons

printf 'Guest provisioning complete.\n'
