#!/bin/bash

# Sources resolve at runtime from $DEVBOX_PROVISION_ROOT; none is statically
# followable, and the guest config is parsed as data rather than sourced. This
# file-wide disable must stay before the first command to have effect.
# shellcheck disable=SC1091

set -Eeuo pipefail
trap 'printf "ERROR: guest provisioning failed at line %s\n" "$LINENO" >&2' ERR

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"

source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/runtimes.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/apps.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/docker.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/configure.sh"

set -a
source "$DEVBOX_PROVISION_ROOT/versions.env"
set +a

# The guest user owns the config, so it must not be sourced as shell code:
# parse it as validated literal data with the same parser the seed used, then
# export only the validated Git identity.
git_config="$HOME/.config/devbox/config"
if [ ! -e "$git_config" ]; then
    printf 'ERROR: guest config is missing: %s\n' "$git_config" >&2
    exit 1
fi
unset GIT_NAME GIT_EMAIL
# The parser consumes stdin only; the second "$git_config" is the error label
# printed by the parser, never a write.
# shellcheck disable=SC2094
devbox_parse_state_file "$git_config" config <"$git_config" || {
    printf 'ERROR: guest config was rejected by the state parser: %s\n' "$git_config" >&2
    exit 1
}
[ -n "${GIT_NAME:-}" ] && [ -n "${GIT_EMAIL:-}" ] || {
    printf 'ERROR: guest config has no validated Git identity: %s\n' "$git_config" >&2
    exit 1
}
export GIT_NAME GIT_EMAIL

mkdir -p "$HOME/.local/bin" "$HOME/.opencode/bin"
export PATH="$HOME/.pyenv/bin:$HOME/.pyenv/shims:$HOME/.opencode/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH"

install_runtimes
install_apps
devbox_configure_rootless_docker
configure_guest

printf 'Guest provisioning complete.\n'
