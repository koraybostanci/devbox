#!/bin/bash

install_claude() {
    local package_root

    stage "Claude Code $CLAUDE_CODE_VERSION"
    npm install --global --silent --include=optional \
        --allow-scripts=@anthropic-ai/claude-code \
        "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" \
        "@anthropic-ai/claude-code-linux-arm64@$CLAUDE_CODE_VERSION"
    package_root="$(npm root --global)/@anthropic-ai/claude-code"
    [ -f "$package_root/install.cjs" ]
    [ -x "$(npm root --global)/@anthropic-ai/claude-code-linux-arm64/claude" ]
    (cd "$package_root" && node install.cjs)
    [ -x "$package_root/bin/claude.exe" ]
    claude --version | grep -qF "$CLAUDE_CODE_VERSION"
}

install_opencode() {
    local archive directory

    stage "OpenCode $OPENCODE_VERSION"
    if command -v opencode >/dev/null 2>&1 &&
        [ "$(opencode --version | sed 's/^opencode v//')" = "$OPENCODE_VERSION" ]; then
        return
    fi

    archive="$(mktemp)"
    directory="$(mktemp -d)"
    download_verified \
        "https://opencode.ai/files/bin/$OPENCODE_VERSION/opencode-linux-arm64.tar.gz" \
        "$OPENCODE_SHA256" "$archive"
    tar -xzf "$archive" -C "$directory"
    install -m 755 "$directory/opencode" "$HOME/.local/bin/opencode"
    rm -rf "$archive" "$directory"
    [ "$(opencode --version | sed 's/^opencode v//')" = "$OPENCODE_VERSION" ]
}

# Installs direct from the pinned release zip, unprivileged, into the user's
# PATH; no upstream installer script is involved.
install_databricks() {
    local directory
    stage "Databricks CLI $DATABRICKS_VERSION"
    if command -v databricks >/dev/null 2>&1 && databricks version | grep -qF "v$DATABRICKS_VERSION"; then
        return
    fi
    directory="$(mktemp -d)"
    run_pinned_installer \
        "https://github.com/databricks/cli/releases/download/v$DATABRICKS_VERSION/databricks_cli_${DATABRICKS_VERSION}_linux_arm64.zip" \
        "$DATABRICKS_CLI_SHA256" unzip -q -d "$directory"
    install -m 755 "$directory/databricks" "$HOME/.local/bin/databricks"
    rm -rf "$directory"
    databricks version | grep -qF "v$DATABRICKS_VERSION"
}

install_yq() {
    local archive
    stage "yq $YQ_VERSION"
    archive="$(mktemp)"
    download_verified \
        "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_arm64" \
        "$YQ_SHA256" "$archive"
    install -m 755 "$archive" "$HOME/.local/bin/yq"
    rm -f "$archive"
    yq --version | grep -qF "$YQ_VERSION"
}

install_shell_sources() {
    local installer
    stage "Shell framework"
    if [ ! -r "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
        installer="$(mktemp)"
        download_verified \
            "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/$OH_MY_ZSH_COMMIT/tools/install.sh" \
            "$OH_MY_ZSH_INSTALL_SHA256" "$installer"
        ZSH="$HOME/.oh-my-zsh" RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$installer" --unattended
        rm -f "$installer"
    fi
}

install_apps() {
    install_claude
    install_opencode
    install_yq
    install_databricks
    install_shell_sources
}
