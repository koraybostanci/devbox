#!/bin/bash

set -Eeuo pipefail

set -a
source /provision/versions.env
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

login_shell_is_clean() {
    [ -z "$(zsh -lic 'true' 2>&1)" ]
}

check "guest environment permissions" has_mode "$HOME/.config/devbox/env" 600
check "projects mount is writable" test -w /mnt/devbox/projects
check "data mount is writable" test -w /mnt/devbox/data
check "Docker daemon" docker info
check "Docker Compose" docker compose version
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
