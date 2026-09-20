#!/bin/bash

install_claude() {
    stage "Claude Code $CLAUDE_CODE_VERSION"
    npm install --global --silent --include=optional \
        --allow-scripts=@anthropic-ai/claude-code \
        "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION"
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

install_databricks() {
    local installer
    stage "Databricks CLI $DATABRICKS_VERSION"
    rm -f "$HOME/.local/bin/databricks"
    if command -v databricks >/dev/null 2>&1 && databricks version | grep -qF "v$DATABRICKS_VERSION"; then
        return
    fi
    installer="$(mktemp)"
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        "https://raw.githubusercontent.com/databricks/setup-cli/v$DATABRICKS_VERSION/install.sh" \
        -o "$installer"
    sudo rm -f /usr/local/bin/databricks
    sudo sh "$installer"
    rm -f "$installer"
    databricks version | grep -qF "v$DATABRICKS_VERSION"
}

install_yq() {
    stage "yq $YQ_VERSION"
    mkdir -p "$HOME/.local/bin"
    GOBIN="$HOME/.local/bin" go install "github.com/mikefarah/yq/v4@$YQ_VERSION"
    yq --version | grep -qF "$YQ_VERSION"
}

install_shell_sources() {
    local installer
    stage "Shell framework"
    if [ ! -r "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
        installer="$(mktemp)"
        curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
            https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh \
            -o "$installer"
        ZSH="$HOME/.oh-my-zsh" RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$installer" --unattended
        rm -f "$installer"
    fi
}

install_apps() {
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH"
    install_claude
    install_opencode
    install_databricks
    install_yq
    install_shell_sources
}
