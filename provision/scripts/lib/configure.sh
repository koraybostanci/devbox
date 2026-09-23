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

    stage "OpenCode configuration"
    mkdir -p "$config_directory/agents" "$config_directory/skills"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/opencode/opencode.jsonc" "$config_directory/opencode.jsonc"
    cp -R "$DEVBOX_PROVISION_ROOT/config/opencode/agents/." "$config_directory/agents/"
    cp -R "$DEVBOX_PROVISION_ROOT/config/skills/." "$config_directory/skills/"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/opencode/AGENTS.md" "$config_directory/AGENTS.md" 644
}

configure_claude() {
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
}

configure_shell() {
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/zsh/zshrc" "$HOME/.zshrc" 644
    zsh -n "$HOME/.zshrc"
}

configure_guest() {
    configure_git
    configure_opencode
    configure_claude
    configure_shell
}
