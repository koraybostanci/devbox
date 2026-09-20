#!/bin/bash

ensure_managed_link() {
    local link_path="$1" target="$2"
    if [ -L "$link_path" ]; then
        [ "$(readlink "$link_path")" = "$target" ] || {
            printf 'ERROR: %s points somewhere unexpected\n' "$link_path" >&2
            return 1
        }
        return
    fi
    [ ! -e "$link_path" ] || {
        printf 'ERROR: %s already exists; move it aside before provisioning\n' "$link_path" >&2
        return 1
    }
    ln -s "$target" "$link_path"
}

configure_mounts() {
    stage "Persistent mounts"
    [ -d /mnt/devbox/projects ] && [ -w /mnt/devbox/projects ]
    [ -d /mnt/devbox/data ] && [ -w /mnt/devbox/data ]
    ensure_managed_link "$HOME/projects" /mnt/devbox/projects
    ensure_managed_link "$HOME/data" /mnt/devbox/data
}

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
    atomic_copy /provision/config/opencode/opencode.jsonc "$config_directory/opencode.jsonc"
    cp -R /provision/config/opencode/agents/. "$config_directory/agents/"
    cp -R /provision/config/skills/. "$config_directory/skills/"
    atomic_copy /provision/config/opencode/AGENTS.md "$config_directory/AGENTS.md" 644

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
    atomic_copy /provision/config/claude/CLAUDE.md "$HOME/.claude/CLAUDE.md"
    atomic_copy /provision/config/claude/settings.json "$HOME/.claude/settings.json"
    if [ -d /provision/config/skills ]; then
        cp -R /provision/config/skills/. "$HOME/.claude/skills/"
    fi
}

configure_shell() {
    atomic_copy /provision/config/zsh/zshrc "$HOME/.zshrc" 644
    zsh -n "$HOME/.zshrc"
    if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]; then
        sudo chsh -s "$(command -v zsh)" "$USER"
    fi
}

configure_guest() {
    configure_mounts
    configure_git
    configure_opencode
    configure_claude
    configure_shell
}
