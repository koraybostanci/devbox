#!/bin/bash

set -Eeuo pipefail

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/state.sh"
source "$DEVBOX_PROVISION_ROOT/scripts/lib/docker.sh"

set -a
source "$DEVBOX_PROVISION_ROOT/versions.env"
set +a

failures=0

check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS: %s\n' "$description"
    else
        printf 'FAIL: %s\n' "$description" >&2
        failures=$((failures + 1))
    fi
}

login_shell_is_clean() {
    [ -z "$(zsh -lic 'true' 2>&1)" ]
}

login_shell_uses_rootless_docker() {
    [ "$(zsh -lic 'printf "%s|%s" "${DOCKER_HOST:-}" "${DOCKER_CONTEXT:-}"')" = \
        "$(devbox_rootless_endpoint)|" ]
}

user_systemctl() {
    XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" \
        systemctl --user "$@"
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

guest_home_uses_lima_data_disk() {
    local data_root

    data_root="$(devbox_lima_data_root)" || return 1
    [ -n "$data_root" ] &&
        devbox_home_is_on_lima_data_disk /home/devbox "$data_root/devbox-home" "$data_root"
}

check "devbox guest config permissions" devbox_path_is_safe f "$HOME/.config/devbox/config" devbox devbox 600
check "devbox guest secrets permissions" devbox_path_is_safe f "$HOME/.config/devbox/secrets" devbox devbox 600
check "devbox root provisioning directory is root-owned" bash -c '
    [ -d /var/lib/devbox ] && [ ! -L /var/lib/devbox ] &&
        [ "$(stat -c "%U" /var/lib/devbox)" = root ]
'
check "devbox provisioning input is root-owned, readable, and read-only" bash -c '
    [ -d "$DEVBOX_PROVISION_ROOT" ] && [ ! -L "$DEVBOX_PROVISION_ROOT" ] &&
        [ "$(stat -c "%U" "$DEVBOX_PROVISION_ROOT")" = root ] &&
        [ -r "$DEVBOX_PROVISION_ROOT/scripts/tools.sh" ] &&
        [ ! -w "$DEVBOX_PROVISION_ROOT" ] &&
        [ ! -w "$DEVBOX_PROVISION_ROOT/scripts/tools.sh" ]
'
check "devbox active user" test "$(id -un)" = devbox
check "devbox guest home" test "$HOME" = /home/devbox
check "devbox guest home is on the Lima data disk" guest_home_uses_lima_data_disk
check "devbox workspace is writable and real" bash -c '
    [ -d /home/devbox/workspace ] && [ ! -L /home/devbox/workspace ] &&
        [ -w /home/devbox/workspace ]
'
check "devbox guest has no passwordless sudo" bash -c '! sudo -n true >/dev/null 2>&1'
check "devbox guest belongs only to its own group" test "$(id -nG)" = devbox
check "devbox has 65,536 subordinate UID/GID mappings" devbox_has_subid_ranges devbox
check "devbox has systemd lingering enabled" \
    test "$(loginctl show-user devbox -p Linger --value 2>/dev/null)" = yes
check "RootlessKit resolves to Ubuntu's profiled executable" \
    test "$(type -P rootlesskit)" = /usr/bin/rootlesskit
check "rootless Docker user service is enabled" user_systemctl is-enabled --quiet docker.service
check "rootless Docker user service is active" user_systemctl is-active --quiet docker.service
check "rootless Docker context points to the per-user socket" rootless_context_is_selected
check "rootless Docker endpoint is reachable" rootless_docker_is_ready
check "devbox cannot access the rootful Docker socket" rootful_docker_is_denied
check "devbox shell defaults to the rootless Docker socket" login_shell_uses_rootless_docker
check "guest package architecture is ARM64" test "$(dpkg --print-architecture)" = arm64
check "Ubuntu Chromium launches headlessly" chromium_launches_headlessly
# Services are staged during provisioning but stay stopped until the user runs
# `devbox services start`. This check runs as the devbox user, so it can only
# assert the directory's ownership and mode.
check "devbox services root is root-owned and closed" bash -c '
    [ -d /var/lib/devbox/services ] && [ ! -L /var/lib/devbox/services ] &&
        [ "$(stat -c "%U" /var/lib/devbox/services)" = root ] &&
        [ "$(stat -c "%a" /var/lib/devbox/services)" = 700 ]
'
check "devbox Claude Code configuration" test -f "$HOME/.claude/CLAUDE.md"
check "Git identity" test -n "$(git config --global user.name)"
check "Git email" test -n "$(git config --global user.email)"
check "zsh login shell starts cleanly" login_shell_is_clean
check "OpenCode v2 config" test -f "$HOME/.config/opencode/opencode.jsonc"
check "OpenCode global guidance" test -f "$HOME/.config/opencode/AGENTS.md"
check "OpenCode loop agents" test -f "$HOME/.config/opencode/agents/loop-implementer.md" -a \
    -f "$HOME/.config/opencode/agents/loop-reviewer.md" -a \
    -f "$HOME/.config/opencode/agents/loop-reviewer-deep.md"

tool_failures=0
zsh -lic '
    tool_check() {
        local description="$1"
        shift
        if "$@" >/dev/null 2>&1; then
            printf "PASS: %s\n" "$description"
        else
            printf "FAIL: %s\n" "$description" >&2
            tool_failures=$((tool_failures + 1))
        fi
    }

    for binary in git gh zsh pyenv jq; do
        tool_check "$binary is available" command -v "$binary"
    done
    tool_check "Node.js version" test "$(node --version 2>/dev/null)" = "v$NODE_VERSION"
    tool_check "npm version" test "$(npm --version 2>/dev/null)" = "$NPM_VERSION"
    tool_check "Python version" test "$(python --version 2>/dev/null | awk "{print \$2}")" = "$PYTHON_VERSION"
    tool_check "uv version" test "$(uv --version 2>/dev/null | awk "{print \$2}")" = "$UV_VERSION"
    tool_check "Java version" grep -qF "version \"${JAVA_VERSION%%.*}." < <(java -version 2>&1)
    tool_check "Go version" test "$(go version 2>/dev/null | awk "{print \$3}" | sed "s/^go//")" = "$GO_VERSION"
    tool_check "Rust version" test "$(rustc --version 2>/dev/null | awk "{print \$2}")" = "$RUST_VERSION"
    tool_check "Claude Code version" grep -qF "$CLAUDE_CODE_VERSION" < <(claude --version 2>/dev/null)
    tool_check "opencode version" test "$(opencode --version 2>/dev/null | sed "s/^opencode v//")" = "$OPENCODE_VERSION"
    tool_check "OpenCode MCP configuration" opencode mcp list
    tool_check "Databricks CLI version" grep -qF "v$DATABRICKS_VERSION" < <(databricks version 2>/dev/null)
    tool_check "yq version" grep -qF "$YQ_VERSION" < <(yq --version 2>/dev/null)
    exit "$tool_failures"
' || tool_failures=$?
failures=$((failures + tool_failures))

((failures == 0)) || exit "$failures"

# Record the provisioned bundle digest only after every check passed, so a
# matching marker always means this exact tree was verified.
if [ -n "${DEVBOX_BUNDLE_DIGEST:-}" ]; then
    umask 077
    state_directory="$HOME/.local/state/devbox"
    mkdir -p "$state_directory"
    temporary="$(mktemp "$state_directory/.provision.XXXXXX")"
    printf '%s\n' "$DEVBOX_BUNDLE_DIGEST" >"$temporary"
    mv "$temporary" "$state_directory/provision.sha256"
fi

printf 'Guest readiness checks passed.\n'
