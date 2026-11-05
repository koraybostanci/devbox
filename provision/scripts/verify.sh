#!/bin/bash

# Sources resolve at runtime from $DEVBOX_PROVISION_ROOT and /var/lib/devbox,
# never statically followable paths. This file-wide disable must stay before
# the first command to have effect.
# shellcheck disable=SC1091

set -Eeuo pipefail

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/docker.sh"

set -a
source "$DEVBOX_PROVISION_ROOT/versions.env"
set +a

failures=0

login_shell_is_clean() {
    # The shared probe (fed by one zsh -lic invocation) stores the login
    # shell's Docker defaults plus the character count of its startup output;
    # a clean start answers zero.
    [ "${login_shell_probe##*'|'}" = 0 ]
}

login_shell_uses_rootless_docker() {
    [ "${login_shell_probe%"|"*}" = "$(devbox_rootless_endpoint)|" ]
}

rootless_context_is_selected() {
    [ "$(devbox_docker '' context show)" = rootless ] &&
        [ "$(devbox_docker '' context inspect rootless --format '{{.Endpoints.docker.Host}}')" = \
            "$(devbox_rootless_endpoint)" ]
}

rootless_docker_is_ready() {
    [[ "$(devbox_docker "$(devbox_rootless_endpoint)" info --format '{{json .SecurityOptions}}')" == *rootless* ]]
}

rootful_docker_is_denied() {
    [ -S /var/run/docker.sock ] && [ ! -r /var/run/docker.sock ] && [ ! -w /var/run/docker.sock ] &&
        ! devbox_docker unix:///var/run/docker.sock info
}

chromium_launches_headlessly() {
    [[ "$(/snap/bin/chromium --headless --disable-gpu --dump-dom about:blank 2>/dev/null)" == *'<html'* ]]
}

chrome_channel_shim_launches_headlessly() {
    [[ "$(/opt/google/chrome/chrome --headless --disable-gpu --dump-dom about:blank 2>/dev/null)" == *'<html'* ]]
}

guest_home_uses_lima_data_disk() {
    local data_root

    data_root="$(devbox_lima_data_root)" || return 1
    [ -n "$data_root" ] &&
        devbox_home_is_on_lima_data_disk /home/devbox "$data_root/devbox-home" "$data_root"
}

# The staged bundle is the trust root for repeated provisioning: no entry may
# be owned by anyone else, and no entry may be world-writable (which stands in
# for the removed per-file `! -w` assertions, tree-wide, in either dimension a
# guest user could gain write access).
provisioning_tree_is_root_owned_and_closed() {
    [ -d "$DEVBOX_PROVISION_ROOT" ] && [ ! -L "$DEVBOX_PROVISION_ROOT" ] || return 1
    [ "$(stat -c '%U' "$DEVBOX_PROVISION_ROOT")" = root ] || return 1
    if find "$DEVBOX_PROVISION_ROOT" \( ! -user root -o -perm -o+w \) -print -quit |
        grep -q .; then
        return 1
    fi
}

state_root_is_root_owned() {
    [ -d /var/lib/devbox ] && [ ! -L /var/lib/devbox ] &&
        [ "$(stat -c '%U' /var/lib/devbox)" = root ]
}

provisioning_input_is_root_owned_and_readable() {
    [ -d "$DEVBOX_PROVISION_ROOT" ] && [ ! -L "$DEVBOX_PROVISION_ROOT" ] &&
        [ "$(stat -c '%U' "$DEVBOX_PROVISION_ROOT")" = root ] &&
        [ -r "$DEVBOX_PROVISION_ROOT/scripts/tools.sh" ]
}

workspace_is_writable_and_real() {
    [ -d /home/devbox/workspace ] && [ ! -L /home/devbox/workspace ] &&
        [ -w /home/devbox/workspace ]
}

guest_has_no_passwordless_sudo() {
    ! sudo -n true >/dev/null 2>&1
}

services_root_is_root_owned_and_closed() {
    [ -d /var/lib/devbox/services ] && [ ! -L /var/lib/devbox/services ] &&
        [ "$(stat -c '%U' /var/lib/devbox/services)" = root ] &&
        [ "$(stat -c '%a' /var/lib/devbox/services)" = 700 ]
}

# One zsh login-shell probe feeds both startup assertions: the same shell must
# default to the rootless Docker socket (first two fields) and start cleanly
# (a nested `true` whose output length is the last field).
login_shell_probe="$(zsh -lic '
    noise="$(zsh -lic true 2>&1)"
    printf "%s|%s|%s" "${DOCKER_HOST:-}" "${DOCKER_CONTEXT:-}" "${#noise}"
')"

check "devbox guest config permissions" devbox_path_is_safe f "$HOME/.config/devbox/config" devbox devbox 600
check "devbox guest secrets permissions" devbox_path_is_safe f "$HOME/.config/devbox/secrets" devbox devbox 600
check "devbox guest config directory permissions" \
    devbox_path_is_safe d "$HOME/.config/devbox" devbox devbox 700
check "devbox root provisioning directory is root-owned" state_root_is_root_owned
check "devbox provisioning input is root-owned and readable" \
    provisioning_input_is_root_owned_and_readable
check "devbox provisioning tree has no non-root or writable entries" \
    provisioning_tree_is_root_owned_and_closed
check "devbox active user" test "$(id -un)" = devbox
check "devbox guest home" test "$HOME" = /home/devbox
check "devbox guest home is on the Lima data disk" guest_home_uses_lima_data_disk
check "devbox workspace is writable and real" workspace_is_writable_and_real
check "devbox guest has no passwordless sudo" guest_has_no_passwordless_sudo
check "devbox guest belongs only to its own group" test "$(id -nG)" = devbox
check "devbox has 65,536 subordinate UID/GID mappings" devbox_has_subid_ranges devbox
check "devbox has systemd lingering enabled" \
    test "$(loginctl show-user devbox -p Linger --value 2>/dev/null)" = yes
check "RootlessKit resolves to Ubuntu's profiled executable" \
    test "$(type -P rootlesskit)" = /usr/bin/rootlesskit
check "rootless Docker user service is enabled" devbox_user_systemctl is-enabled --quiet docker.service
check "rootless Docker user service is active" devbox_user_systemctl is-active --quiet docker.service
check "rootless Docker context points to the per-user socket" rootless_context_is_selected
check "rootless Docker endpoint is reachable" rootless_docker_is_ready
check "devbox cannot access the rootful Docker socket" rootful_docker_is_denied
check "devbox shell defaults to the rootless Docker socket" login_shell_uses_rootless_docker
check "guest package architecture is ARM64" test "$(dpkg --print-architecture)" = arm64
check "Ubuntu Chromium launches headlessly" chromium_launches_headlessly
check "Chrome stable-channel path launches Chromium" chrome_channel_shim_launches_headlessly
# Services are staged during provisioning but stay stopped until the user runs
# `devbox services start`. This check runs as the devbox user, so it can only
# assert the directory's ownership and mode.
check "devbox services root is root-owned and closed" services_root_is_root_owned_and_closed
check "devbox Claude Code configuration" test -f "$HOME/.claude/CLAUDE.md"
check "Git identity" test -n "$(git config --global user.name)"
check "Git email" test -n "$(git config --global user.email)"
check "zsh login shell starts cleanly" login_shell_is_clean
check "OpenCode v2 config" test -f "$HOME/.config/opencode/opencode.jsonc"
check "OpenCode global guidance" test -f "$HOME/.config/opencode/AGENTS.md"
check "OpenCode multiphase skill" test -f "$HOME/.config/opencode/skills/multiphase/SKILL.md"
check "OpenCode multiphase command" test -f "$HOME/.config/opencode/commands/multiphase.md"

# The tool battery runs through the same check dispatcher, sourced as a
# shared implementation; tool_failures is bridged by the battery's exit code.
tool_failures=0
zsh -lic '
    failures=0
    source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"

    check "git is available" command -v git
    check "gh is available" command -v gh
    check "zsh is available" command -v zsh
    check "pyenv is available" command -v pyenv
    check "jq is available" command -v jq
    check "vim is available" command -v vim
    check "Node.js version" test "$(node --version 2>/dev/null)" = "v$NODE_VERSION"
    check "npm version" test "$(npm --version 2>/dev/null)" = "$NPM_VERSION"
    check "Python version" test "$(python --version 2>/dev/null | awk "{print \$2}")" = "$PYTHON_VERSION"
    check "uv version" test "$(uv --version 2>/dev/null | awk "{print \$2}")" = "$UV_VERSION"
    check "Java version" grep -qF "version \"${JAVA_VERSION%%.*}." < <(java -version 2>&1)
    check "Go version" test "$(go version 2>/dev/null | awk "{print \$3}" | sed "s/^go//")" = "$GO_VERSION"
    check "Rust version" test "$(rustc --version 2>/dev/null | awk "{print \$2}")" = "$RUST_VERSION"
    check "Claude Code version" grep -qF "$CLAUDE_CODE_VERSION" < <(claude --version 2>/dev/null)
    check "opencode version" test "$(opencode --version 2>/dev/null | sed "s/^opencode v//")" = "$OPENCODE_VERSION"
    check "OpenCode MCP configuration" opencode mcp list
    check "Databricks CLI version" grep -qF "v$DATABRICKS_VERSION" < <(databricks version 2>/dev/null)
    check "yq version" grep -qF "$YQ_VERSION" < <(yq --version 2>/dev/null)
    exit "$failures"
' || tool_failures=$?
failures=$((failures + tool_failures))

((failures == 0)) || exit "$failures"

# Record the provisioned bundle digest only after every check passed, so a
# matching marker always means this exact tree was verified.
if [ -n "${DEVBOX_BUNDLE_DIGEST:-}" ]; then
    umask 077
    state_directory="$HOME/.local/state/devbox"
    mkdir -p "$state_directory"
    devbox_publish_atomic "$state_directory/provision.sha256" 600 --skip-if-same -- \
        printf '%s\n' "$DEVBOX_BUNDLE_DIGEST"
fi

printf 'Guest readiness checks passed.\n'
