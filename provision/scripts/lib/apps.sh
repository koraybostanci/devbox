#!/bin/bash

install_claude() {
    local package_root

    stage "Claude Code $CLAUDE_CODE_VERSION"
    if command -v claude >/dev/null 2>&1 &&
        ensure_installed bash -c "claude --version | grep -oF '$CLAUDE_CODE_VERSION'" "$CLAUDE_CODE_VERSION"; then
        return
    fi
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

install_playwright() {
    stage "Playwright $PLAYWRIGHT_VERSION"
    if ! npm ls --global --depth=0 playwright 2>/dev/null | grep -qF "playwright@$PLAYWRIGHT_VERSION"; then
        # The npm package never downloads browsers; scripts launch the system
        # Chromium through CHROMIUM_PATH (set in the managed .zshenv block).
        npm install --global --silent "playwright@$PLAYWRIGHT_VERSION"
        npm ls --global --depth=0 playwright | grep -qF "playwright@$PLAYWRIGHT_VERSION"
    fi
    # Node resolves bare imports (ESM and CJS) up the directory tree, and
    # never consults global modules for ESM. Linking into ~/node_modules makes
    # `import "playwright"` work from any script under $HOME; a project's own
    # node_modules still wins. The link follows the nvm-versioned global root.
    mkdir -p "$HOME/node_modules"
    ln -sfn "$(npm root --global)/playwright" "$HOME/node_modules/playwright"
}

install_opencode() {
    local archive directory binary_directory

    stage "OpenCode $OPENCODE_VERSION"
    # The binary lives at ~/.opencode/bin/opencode, the layout the official
    # installer uses, so opencode's built-in `opencode upgrade` self-updater
    # auto-detects the install (it only recognizes that path -- method
    # "curl") and can update in place between pinned re-provisions. The
    # installer never lands in ~/.local/bin; a stale copy there is removed
    # so PATH never resolves a shadowed version.
    binary_directory="$HOME/.opencode/bin"
    if command -v opencode >/dev/null 2>&1 &&
        ensure_installed bash -c 'opencode --version | sed "s/^opencode v//"' "$OPENCODE_VERSION"; then
        rm -f "$HOME/.local/bin/opencode"
        return
    fi

    archive="$(mktemp)"
    directory="$(mktemp -d)"
    download_verified \
        "https://opencode.ai/files/bin/$OPENCODE_VERSION/opencode-linux-arm64.tar.gz" \
        "$OPENCODE_SHA256" "$archive"
    tar -xzf "$archive" -C "$directory"
    install -m 755 "$directory/opencode" "$binary_directory/opencode"
    rm -rf "$archive" "$directory" "$HOME/.local/bin/opencode"
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
    if command -v yq >/dev/null 2>&1 &&
        ensure_installed bash -c "yq --version | awk '{print \$NF}'" "$YQ_VERSION"; then
        return
    fi
    archive="$(mktemp)"
    download_verified \
        "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_arm64" \
        "$YQ_SHA256" "$archive"
    install -m 755 "$archive" "$HOME/.local/bin/yq"
    rm -f "$archive"
    yq --version | grep -qF "$YQ_VERSION"
}

install_shell_sources() {
    local commit tree_state
    stage "Shell framework"
    commit="$OH_MY_ZSH_COMMIT"
    if [ ! -r "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
        # Clone upstream master, then converge to the pinned commit below: git
        # object hashes authenticate the checkout, so no artifact pin applies.
        git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
    fi
    tree_state="$(git -C "$HOME/.oh-my-zsh" rev-parse HEAD)"
    if [ "$tree_state" != "$commit" ]; then
        git -C "$HOME/.oh-my-zsh" fetch --depth 1 origin "$commit"
        git -C "$HOME/.oh-my-zsh" checkout --detach --quiet "$commit"
    fi
}

install_apps() {
    install_claude
    install_playwright
    install_opencode
    install_yq
    install_databricks
    install_shell_sources
}
