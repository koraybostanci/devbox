#!/bin/bash

configure_git() {
    stage "Git identity and HTTPS defaults"
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    git config --global init.defaultBranch main
    gh config set git_protocol https --host github.com
}

configure_opencode() {
    local config_directory="$HOME/.config/opencode"
    local legacy_mcp="$HOME/.mcp.json" temporary

    stage "OpenCode v2 configuration"
    mkdir -p "$config_directory/agents" "$config_directory/skills"
    command rm -f "$config_directory/opencode.json"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/opencode/opencode.jsonc" "$config_directory/opencode.jsonc"
    cp -R "$DEVBOX_PROVISION_ROOT/config/opencode/agents/." "$config_directory/agents/"
    cp -R "$DEVBOX_PROVISION_ROOT/config/skills/." "$config_directory/skills/"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/opencode/AGENTS.md" "$config_directory/AGENTS.md" 644

    if [ -f "$legacy_mcp" ] && jq -e '
        .mcpServers.filesystem |
        .command == "npx" and (.args | index("@modelcontextprotocol/server-filesystem"))
    ' "$legacy_mcp" >/dev/null 2>&1; then
        temporary="$(mktemp "$HOME/.mcp.XXXXXX")"
        jq 'del(.mcpServers.filesystem) | if .mcpServers == {} then del(.mcpServers) else . end' \
            "$legacy_mcp" >"$temporary"
        if jq -e 'length == 0' "$temporary" >/dev/null; then
            command rm -f "$legacy_mcp" "$temporary"
        else
            chmod 600 "$temporary"
            mv "$temporary" "$legacy_mcp"
        fi
    fi
}

configure_claude() {
    mkdir -p "$HOME/.claude/skills"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/claude/settings.json" "$HOME/.claude/settings.json"
    if [ -d "$DEVBOX_PROVISION_ROOT/config/skills" ]; then
        cp -R "$DEVBOX_PROVISION_ROOT/config/skills/." "$HOME/.claude/skills/"
    fi
}

configure_shell() {
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/zsh/zshrc" "$HOME/.zshrc" 644
    zsh -n "$HOME/.zshrc"
    if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]; then
        sudo chsh -s "$(command -v zsh)" "$USER"
    fi
}

configure_guest() {
    configure_git
    configure_opencode
    configure_claude
    configure_shell
}
