#!/bin/bash
# Authorize the host's SSH public key (stdin) for the unprivileged devbox guest
# user. Runs as root but writes as devbox, so no devbox-controlled path is
# followed with root privileges. Colima's own administrative access is
# untouched.

set -Eeuo pipefail
trap 'printf "ERROR: devbox key authorization failed at line %s\n" "$LINENO" >&2' ERR

# Install the single-line key on stdin as HOME/.ssh/authorized_keys.
devbox_install_authorized_key() (
    local home="$1" key temporary

    key="$(cat)"
    [ -n "$key" ] && [[ "$key" != *$'\n'* ]] || {
        printf 'ERROR: invalid devbox host SSH public key\n' >&2
        exit 1
    }
    umask 077
    mkdir -p "$home/.ssh"
    chmod 700 "$home/.ssh"
    temporary="$(mktemp "$home/.ssh/.authorized_keys.XXXXXX")"
    printf '%s\n' "$key" >"$temporary"
    mv -f "$temporary" "$home/.ssh/authorized_keys"
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cd /
    sudo -u devbox -- /bin/bash -c '
        set -Eeuo pipefail
        source "$1"
        devbox_install_authorized_key /home/devbox
    ' _ "${BASH_SOURCE[0]}"
fi
