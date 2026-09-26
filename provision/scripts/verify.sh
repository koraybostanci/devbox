#!/bin/bash

set -Eeuo pipefail

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/var/lib/devbox/provision}"
export DEVBOX_GUEST_CONFIG_ROOT="${DEVBOX_GUEST_CONFIG_ROOT:-$HOME/.config/devbox}"
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

has_mode() {
    local path="$1" expected="$2"

    [ -f "$path" ] && [ "$(stat -c '%a' "$path")" = "$expected" ]
}

has_verified_devbox_bundle() {
    local root="$1" digest actual

    digest="$(cat "$root/.devbox-bundle.sha256" 2>/dev/null || true)"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual="$(
        cd "$root"
        find . -type f ! -path './.devbox-bundle.sha256' -print | LC_ALL=C sort | while IFS= read -r path; do
            printf '%s\t%s\n' "${path#./}" "$(sha256sum "$path" | cut -d ' ' -f1)"
        done | sha256sum | cut -d ' ' -f1
    )"
    [ "$actual" = "$digest" ]
}

login_shell_is_clean() {
    [ -z "$(zsh -lic 'true' 2>&1)" ]
}

login_shell_uses_rootless_docker() {
    local expected actual context

    expected="$(devbox_rootless_endpoint)" || return 1
    actual="$(zsh -lic 'printf "%s" "${DOCKER_HOST:-}"')" || return 1
    context="$(zsh -lic 'printf "%s" "${DOCKER_CONTEXT:-}"')" || return 1
    [ "$actual" = "$expected" ] && [ -z "$context" ]
}

chromium_launches_headlessly() {
    local executable=/snap/bin/chromium html

    [ -x "$executable" ] || return 1
    html="$("$executable" --headless --disable-gpu --dump-dom about:blank 2>/dev/null)" || return 1
    [[ "$html" == *'<html'* ]]
}

guest_home_uses_lima_data_disk() {
    local data_root

    data_root="$(devbox_lima_data_root)" || return 1
    [ -n "$data_root" ] &&
        devbox_home_is_on_lima_data_disk /home/devbox "$data_root/devbox-home" "$data_root"
}

check "devbox guest config permissions" has_mode "$DEVBOX_GUEST_CONFIG_ROOT/config" 600
check "devbox guest secrets permissions" has_mode "$DEVBOX_GUEST_CONFIG_ROOT/secrets" 600
check "guest-local provisioning bundle" has_verified_devbox_bundle "$DEVBOX_PROVISION_ROOT"
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
check "devbox guest is not in Docker group" bash -c '! id -nG | tr " " "\n" | grep -qx docker'
check "devbox has 65,536 subordinate UID/GID mappings" devbox_user_has_rootless_subid_ranges
check "devbox has systemd lingering enabled" devbox_user_lingering_is_enabled
check "RootlessKit uses its Ubuntu-profiled executable and profile" \
    devbox_rootlesskit_apparmor_profile_is_ready
check "rootless Docker user service is enabled" devbox_rootless_user_service_is_enabled
check "rootless Docker user service is active" devbox_rootless_user_service_is_active
check "rootless Docker context points to the per-user socket" devbox_rootless_context_is_selected
check "rootless Docker endpoint is reachable" devbox_rootless_docker_is_ready
check "devbox cannot access the rootful Docker socket" devbox_rootful_docker_is_denied
check "devbox shell defaults to the rootless Docker socket" login_shell_uses_rootless_docker
check "guest package architecture is ARM64" test "$(dpkg --print-architecture)" = arm64
check "Ubuntu Chromium launches headlessly" chromium_launches_headlessly
# Services are staged during provisioning but stay stopped until the user runs
# `devbox services start`. This check runs as the devbox user, so it can only
# assert the directory's ownership and mode; state.sh validates the staged
# files (compose.yaml, env) as root where it writes them.
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

if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    printf 'FAIL: host SSH agent is exposed at %s\n' "$SSH_AUTH_SOCK" >&2
    failures=$((failures + 1))
else
    printf 'PASS: host SSH agent is not exposed\n'
fi

((failures == 0)) || exit "$failures"

# Record the provisioned bundle digest only after every check passed, so a
# matching marker always means this exact tree was verified.
if [ -n "${DEVBOX_BUNDLE_DIGEST:-}" ]; then
    umask 077
    state_directory="$HOME/.local/state/devbox"
    mkdir -p "$state_directory"
    temporary="$(mktemp "$state_directory/.provision.XXXXXX")"
    printf '%s\n' "$DEVBOX_BUNDLE_DIGEST" >"$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$state_directory/provision.sha256"
fi

printf 'Guest readiness checks passed.\n'
