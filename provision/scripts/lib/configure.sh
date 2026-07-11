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

configure_json() {
    local npx_bin="$HOME/.nvm/versions/node/v$NODE_VERSION/bin/npx"
    [ -x "$npx_bin" ]

    jq --arg npx "$npx_bin" --arg projects "$HOME/projects" \
        '.mcpServers.filesystem.command = $npx | .mcpServers.filesystem.args[-1] = $projects' \
        /provision/config/mcp.json >"$HOME/.mcp.json.tmp"
    jq empty "$HOME/.mcp.json.tmp"
    chmod 600 "$HOME/.mcp.json.tmp"
    mv "$HOME/.mcp.json.tmp" "$HOME/.mcp.json"

    mkdir -p "$HOME/.config/opencode"
    jq --arg npx "$npx_bin" --arg projects "$HOME/projects" \
        '.mcp.filesystem.command[0] = $npx | .mcp.filesystem.command[-1] = $projects' \
        /provision/config/opencode/opencode.json >"$HOME/.config/opencode/opencode.json.tmp"
    jq empty "$HOME/.config/opencode/opencode.json.tmp"
    chmod 600 "$HOME/.config/opencode/opencode.json.tmp"
    mv "$HOME/.config/opencode/opencode.json.tmp" "$HOME/.config/opencode/opencode.json"
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
    configure_json
    configure_claude
    configure_shell
}
