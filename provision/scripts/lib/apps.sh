#!/bin/bash

install_claude() {
    local package_root

    stage "Claude Code $CLAUDE_CODE_VERSION"
    npm install --global --silent --include=optional \
        --allow-scripts=@anthropic-ai/claude-code \
        "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION"
    package_root="$(npm root --global)/@anthropic-ai/claude-code"
    [ -f "$package_root/install.cjs" ]
    (cd "$package_root" && node install.cjs)
    claude --version | grep -qF "$CLAUDE_CODE_VERSION"
}

install_opencode() {
    local archive directory

    stage "OpenCode $OPENCODE_VERSION"
    if command -v opencode >/dev/null 2>&1 &&
        version_equals "$(opencode --version | sed 's/^opencode v//')" "$OPENCODE_VERSION"; then
        return
    fi

    npm uninstall --global --silent opencode-ai >/dev/null 2>&1 || true
    archive="$(mktemp)"
    directory="$(mktemp -d)"
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        "https://opencode.ai/files/bin/$OPENCODE_VERSION/opencode-linux-arm64.tar.gz" \
        -o "$archive"
    printf '%s  %s\n' "$OPENCODE_SHA256" "$archive" | sha256sum -c -
    tar -xzf "$archive" -C "$directory"
    [ -f "$directory/opencode" ]
    mkdir -p "$HOME/.local/bin"
    install -m 755 "$directory/opencode" "$HOME/.local/bin/opencode"
    rm -rf "$archive" "$directory"
    version_equals "$(opencode --version | sed 's/^opencode v//')" "$OPENCODE_VERSION"
}

# Runs as root from system.sh; the unprivileged tools.sh run cannot write
# /usr/local/bin.
install_databricks() {
    local installer
    stage "Databricks CLI $DATABRICKS_VERSION"
    if command -v databricks >/dev/null 2>&1 && databricks version | grep -qF "v$DATABRICKS_VERSION"; then
        return
    fi
    installer="$(mktemp)"
    download_verified \
        "https://raw.githubusercontent.com/databricks/setup-cli/v$DATABRICKS_VERSION/install.sh" \
        "$DATABRICKS_INSTALL_SHA256" "$installer"
    rm -f /usr/local/bin/databricks
    sh "$installer"
    rm -f "$installer"
    databricks version | grep -qF "v$DATABRICKS_VERSION"
}

install_yq() {
    local archive
    stage "yq $YQ_VERSION"
    mkdir -p "$HOME/.local/bin"
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
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH"
    install_claude
    install_opencode
    install_yq
    install_shell_sources
}
