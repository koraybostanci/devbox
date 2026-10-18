#!/bin/bash
# Authorize the host's SSH public key (stdin) for the unprivileged devbox guest
# user. Runs as root but writes as devbox, so no devbox-controlled path is
# followed with root privileges. Colima's own administrative access is
# untouched.

set -Eeuo pipefail
trap 'printf "ERROR: devbox key authorization failed at line %s\n" "$LINENO" >&2' ERR

# The publish helper lives in common.sh; sources resolve from this file's own
# directory so standalone unit runs see the same shared implementation.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Install the single-line key on stdin as HOME/.ssh/authorized_keys.
devbox_install_authorized_key() (
    local home="$1" key

    key="$(cat)"
    [ -n "$key" ] && [[ "$key" != *$'\n'* ]] || {
        printf 'ERROR: invalid devbox host SSH public key\n' >&2
        exit 1
    }
    umask 077
    mkdir -p "$home/.ssh"
    chmod 700 "$home/.ssh"
    devbox_publish_atomic "$home/.ssh/authorized_keys" 600 -- \
        printf '%s\n' "$key"
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cd /
    sudo -u devbox -- /bin/bash -c '
        set -Eeuo pipefail
        source "$1"
        devbox_install_authorized_key /home/devbox
    ' _ "${BASH_SOURCE[0]}"
fi
