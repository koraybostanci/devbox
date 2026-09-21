#!/bin/bash

set -Eeuo pipefail

export DEVBOX_PROVISION_ROOT="${DEVBOX_PROVISION_ROOT:-/provision}"
export DEVBOX_GUEST_CONFIG_ROOT="${DEVBOX_GUEST_CONFIG_ROOT:-$HOME/.config/devbox}"

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

has_verified_v2_bundle() {
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

check "guest environment permissions" has_mode "$DEVBOX_GUEST_CONFIG_ROOT/env" 600
if [ "${DEVBOX_NO_MOUNTS:-false}" = true ]; then
    check "guest-local provisioning bundle" has_verified_v2_bundle "$DEVBOX_PROVISION_ROOT"
    check "v2 root bundle state is inaccessible" bash -c '
        [ ! -r /var/lib/devbox-v2/bundles ] &&
            [ ! -w /var/lib/devbox-v2/bundles ]
    '
    check "v2 staged provisioning input is root-owned, readable, and read-only" bash -c '
        [ -d "$DEVBOX_PROVISION_ROOT" ] && [ ! -L "$DEVBOX_PROVISION_ROOT" ] &&
            [ "$(stat -c "%U" "$DEVBOX_PROVISION_ROOT")" = root ] &&
            [ -r "$DEVBOX_PROVISION_ROOT/scripts/tools.sh" ] &&
            [ ! -w "$DEVBOX_PROVISION_ROOT" ] &&
            [ ! -w "$DEVBOX_PROVISION_ROOT/scripts/tools.sh" ]
    '
    check "v2 active user" test "$(id -un)" = devbox
    check "v2 guest home" test "$HOME" = /home/devbox
    check "v2 workspace is writable and real" bash -c '
        [ -d /home/devbox/workspace ] && [ ! -L /home/devbox/workspace ] &&
            [ -w /home/devbox/workspace ]
    '
    check "v2 guest has no passwordless sudo" bash -c '! sudo -n true >/dev/null 2>&1'
    check "v2 guest is not in Docker group" bash -c '! id -nG | tr " " "\n" | grep -qx docker'
    check "v2 guest cannot access Docker socket" bash -c '! test -w /var/run/docker.sock'
    check "v2 has no legacy mounts" bash -c '
        [ ! -e /mnt/devbox/projects ] && [ ! -e /mnt/devbox/data ]
    '
    check "v2 Claude Code configuration" test -f "$HOME/.claude/CLAUDE.md" -a -f "$HOME/.claude/settings.json"
else
    check "projects mount is writable" test -w /mnt/devbox/projects
    check "data mount is writable" test -w /mnt/devbox/data
    check "Docker daemon" docker info
    check "Docker Compose" docker compose version
fi
check "Git identity" test -n "$(git config --global user.name)"
check "Git email" test -n "$(git config --global user.email)"
check "zsh login shell starts cleanly" login_shell_is_clean
check "OpenCode v2 config" test -f "$HOME/.config/opencode/opencode.jsonc"
check "OpenCode global guidance" test -f "$HOME/.config/opencode/AGENTS.md"
check "OpenCode v1 config is absent" test ! -e "$HOME/.config/opencode/opencode.json"
check "OpenCode loop agents" test -f "$HOME/.config/opencode/agents/loop-implementer.md" -a \
    -f "$HOME/.config/opencode/agents/loop-reviewer.md" -a \
    -f "$HOME/.config/opencode/agents/loop-reviewer-deep.md"
check "legacy filesystem MCP is absent" bash -c '
    [ ! -f "$HOME/.mcp.json" ] || ! jq -e "
        .mcpServers.filesystem |
        .command == \"npx\" and (.args | index(\"@modelcontextprotocol/server-filesystem\"))
    " "$HOME/.mcp.json" >/dev/null 2>&1
'

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

if gh api user --silent >/dev/null 2>&1; then
    printf 'PASS: GitHub CLI is authenticated\n'
else
    printf "WARN: GitHub CLI is not authenticated; run 'devbox github login'\n"
fi

((failures == 0)) || exit "$failures"
printf 'Guest readiness checks passed.\n'
