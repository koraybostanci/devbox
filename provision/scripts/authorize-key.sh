#!/bin/bash
# Authorize the host's SSH public key (stdin) for the unprivileged devbox guest
# user. Runs as root; Colima's own administrative access is untouched.

set -Eeuo pipefail
trap 'printf "ERROR: devbox key authorization failed at line %s\n" "$LINENO" >&2' ERR

home=/home/devbox
user=devbox
key="$(cat)"
[ -n "$key" ] && [ "$(printf '%s\n' "$key" | wc -l | tr -d ' ')" = 1 ] || {
    printf 'ERROR: invalid devbox host SSH public key\n' >&2
    exit 1
}
[ -d "$home" ] && [ ! -L "$home" ] || {
    printf 'ERROR: devbox guest home is invalid\n' >&2
    exit 1
}
[ ! -L "$home/.ssh" ] || {
    printf 'ERROR: devbox guest SSH directory is invalid\n' >&2
    exit 1
}
install -d -o "$user" -g "$user" -m 700 "$home/.ssh"
[ -d "$home/.ssh" ] && [ ! -L "$home/.ssh" ] || {
    printf 'ERROR: devbox guest SSH directory is invalid\n' >&2
    exit 1
}
authorized="$home/.ssh/authorized_keys"
temporary="$(mktemp "$home/.ssh/.authorized_keys.XXXXXX")"
printf '%s\n' "$key" >"$temporary"
chown "$user":"$user" "$temporary"
chmod 600 "$temporary"
mv "$temporary" "$authorized"
# Older devbox versions configured sshd to read /etc/ssh/authorized_keys/%u.
# Keep that file current when the directory exists so an existing VM converges
# without being recreated.
if [ -d /etc/ssh/authorized_keys ] && [ ! -L /etc/ssh/authorized_keys ]; then
    temporary="$(mktemp "/etc/ssh/authorized_keys/.${user}.XXXXXX")"
    printf '%s\n' "$key" >"$temporary"
    chown root:root "$temporary"
    chmod 644 "$temporary"
    mv "$temporary" "/etc/ssh/authorized_keys/$user"
fi
