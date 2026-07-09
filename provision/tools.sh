#!/bin/bash
# Runs as the lima user (non-interactive, non-login shell).
# Idempotent: check-before-install throughout.
set -eux

# ─── Version pins ────────────────────────────────────────────────────────────
GO_VERSION="1.22.4"
NODE_VERSION="20.19.0"
PYTHON_VERSION="3.12.4"
JAVA_VERSION="21.0.3-tem"
UV_VERSION="0.4.18"
# ─────────────────────────────────────────────────────────────────────────────

# ─── Claude Code plugins ─────────────────────────────────────────────────────
# Add plugin names here to install them on every provision.
# Format: "<name>@<marketplace>"
CLAUDE_PLUGINS=(
    # "impeccable@marketplace"   # example
)

# ─── Skill install commands ──────────────────────────────────────────────────
# For skills that have their own install command (e.g. curl-based installers).
# Each entry is a shell command. Use a sentinel file in ~/.claude/skills/ to
# make each entry idempotent — name it after the skill.
# Format: "<sentinel-name>|<install command>"
SKILL_INSTALLS=(
    # "impeccable|curl -fsSL https://impeccable.style/install | bash"
)
# ─────────────────────────────────────────────────────────────────────────────

# HOME is set correctly by Lima — do not override it.
# Do NOT export XDG_CONFIG_HOME: nvm uses it to pick its install dir,
# and setting it causes nvm to install to ~/.config/nvm instead of ~/.nvm.

# ─── Git identity ─────────────────────────────────────────────────────────────
if [ -n "${GIT_NAME:-}" ] && [ -n "${GIT_EMAIL:-}" ]; then
    git config --global user.name  "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
fi
git config --global init.defaultBranch main

# ─── SSH agent socket (Lima VZ path) ─────────────────────────────────────────
# Lima exposes the host agent at this socket. Add to .zshrc so interactive
# sessions pick it up; also set for this provisioning run.
SSH_SOCK_EXPR='export SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock'
grep -qF 'SSH_AUTH_SOCK' "$HOME/.zshrc" 2>/dev/null || echo "$SSH_SOCK_EXPR" >> "$HOME/.zshrc"
eval "$SSH_SOCK_EXPR" || true

# ─── zsh + oh-my-zsh ──────────────────────────────────────────────────────────
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# Set zsh as default shell (requires root — Lima runs this block as the user
# but chsh needs the entry to exist in /etc/shells)
if command -v zsh >/dev/null && [ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]; then
    sudo chsh -s "$(command -v zsh)" "$USER" || true
fi

# ─── nvm + Node.js ───────────────────────────────────────────────────────────
if [ ! -d "$HOME/.nvm" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

if ! node --version 2>/dev/null | grep -q "^v$NODE_VERSION"; then
    nvm install "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
fi
nvm use "$NODE_VERSION"

# Persist nvm init in .zshrc
if ! grep -qF 'NVM_DIR' "$HOME/.zshrc" 2>/dev/null; then
    cat >> "$HOME/.zshrc" <<'ZSHEOF'

# nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
ZSHEOF
fi

# ─── pyenv + Python ──────────────────────────────────────────────────────────
if [ ! -d "$HOME/.pyenv" ]; then
    curl -fsSL https://pyenv.run | bash
fi

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

if ! pyenv versions --bare | grep -qx "$PYTHON_VERSION"; then
    pyenv install "$PYTHON_VERSION"
fi
pyenv global "$PYTHON_VERSION"
export PATH="$PYENV_ROOT/shims:$PATH"

if ! grep -qF 'PYENV_ROOT' "$HOME/.zshrc" 2>/dev/null; then
    cat >> "$HOME/.zshrc" <<'ZSHEOF'

# pyenv
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
eval "$(pyenv init -)"
ZSHEOF
fi

# ─── uv (Python package / venv manager) ─────────────────────────────────────
if ! command -v uv >/dev/null || [ "$(uv --version | awk '{print $2}')" != "$UV_VERSION" ]; then
    curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" | sh
fi
export PATH="$HOME/.local/bin:$PATH"

if ! grep -qF '.local/bin' "$HOME/.zshrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
fi

# ─── sdkman + Java ───────────────────────────────────────────────────────────
if [ ! -d "$HOME/.sdkman" ]; then
    curl -fsSL https://get.sdkman.io | bash
fi

export SDKMAN_DIR="$HOME/.sdkman"
# sdkman uses unbound variables internally — disable set -u for all sdkman operations
set +u
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
if ! sdk current java 2>/dev/null | grep -q "$JAVA_VERSION"; then
    sdk install java "$JAVA_VERSION" || true
fi
set -u

if ! grep -qF 'SDKMAN_DIR' "$HOME/.zshrc" 2>/dev/null; then
    cat >> "$HOME/.zshrc" <<'ZSHEOF'

# sdkman
export SDKMAN_DIR="$HOME/.sdkman"
set +u
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
set -u
ZSHEOF
fi

# ─── Go ──────────────────────────────────────────────────────────────────────
GO_ARCHIVE="go${GO_VERSION}.linux-arm64.tar.gz"
if ! command -v go >/dev/null || [ "$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//')" != "$GO_VERSION" ]; then
    curl -fsSL "https://go.dev/dl/$GO_ARCHIVE" -o "/tmp/$GO_ARCHIVE"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/$GO_ARCHIVE"
    rm -f "/tmp/$GO_ARCHIVE"
fi
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

if ! grep -qF '/usr/local/go/bin' "$HOME/.zshrc" 2>/dev/null; then
    cat >> "$HOME/.zshrc" <<'ZSHEOF'

# Go
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
ZSHEOF
fi

# ─── Claude Code CLI ─────────────────────────────────────────────────────────
if ! command -v claude >/dev/null; then
    npm install -g @anthropic-ai/claude-code
fi

# Write ANTHROPIC_API_KEY to .zshrc so Claude Code picks it up in interactive shells
if [ -n "${ANTHROPIC_API_KEY:-}" ] && ! grep -qF 'ANTHROPIC_API_KEY' "$HOME/.zshrc" 2>/dev/null; then
    echo "export ANTHROPIC_API_KEY=\"$ANTHROPIC_API_KEY\"" >> "$HOME/.zshrc"
fi

# Claude Code user config
mkdir -p "$HOME/.claude"
cp /provision/config/claude/CLAUDE.md "$HOME/.claude/CLAUDE.md"
cp /provision/config/claude/settings.json "$HOME/.claude/settings.json"

# Skills (both Claude Code and opencode read ~/.claude/skills/)
if [ -d /provision/config/claude/skills ] && [ "$(ls -A /provision/config/claude/skills 2>/dev/null)" ]; then
    cp -r /provision/config/claude/skills/. "$HOME/.claude/skills/"
fi

# User-scoped MCPs (~/.mcp.json) — substitute $USER in the filesystem path
mkdir -p "$HOME/.claude"
sed "s|\$USER|$USER|g" /provision/config/mcp.json > "$HOME/.mcp.json"

# ─── opencode ────────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.opencode/bin/opencode" ]; then
    curl -fsSL https://opencode.ai/install | bash
fi
export PATH="$HOME/.opencode/bin:$PATH"

if ! grep -qF '.opencode/bin' "$HOME/.zshrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> "$HOME/.zshrc"
fi

mkdir -p "$HOME/.config/opencode"
sed "s|\$USER|$USER|g" /provision/config/opencode/opencode.json > "$HOME/.config/opencode/opencode.json"

# ─── Databricks CLI ──────────────────────────────────────────────────────────
if ! command -v databricks >/dev/null; then
    mkdir -p "$HOME/.local/bin"
    DATABRICKS_LATEST=$(curl -fsSL https://api.github.com/repos/databricks/cli/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')
    curl -fsSL "https://github.com/databricks/cli/releases/download/v${DATABRICKS_LATEST}/databricks_cli_${DATABRICKS_LATEST}_linux_arm64.zip" -o /tmp/databricks.zip
    unzip -o /tmp/databricks.zip databricks -d "$HOME/.local/bin"
    chmod +x "$HOME/.local/bin/databricks"
    rm /tmp/databricks.zip
fi

if [ -n "${DATABRICKS_HOST:-}" ] && [ -n "${DATABRICKS_TOKEN:-}" ]; then
    cat > "$HOME/.databrickscfg" <<EOF
[DEFAULT]
host  = ${DATABRICKS_HOST}
token = ${DATABRICKS_TOKEN}
EOF
    chmod 600 "$HOME/.databrickscfg"
fi

# ─── ANTHROPIC_API_KEY for non-interactive provisioner runs ──────────────────
# (already in /etc/environment; this export covers the current session only)
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    export ANTHROPIC_API_KEY
fi

# ─── yq ──────────────────────────────────────────────────────────────────────
if ! command -v yq >/dev/null; then
    YQ_LATEST=$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_LATEST}/yq_linux_arm64" -o "$HOME/.local/bin/yq"
    chmod +x "$HOME/.local/bin/yq"
fi

# ─── zsh plugins ─────────────────────────────────────────────────────────────
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

# Enable plugins in .zshrc (replace default plugins line)
if grep -q "^plugins=(git)" "$HOME/.zshrc" 2>/dev/null; then
    sed -i 's/^plugins=(git)/plugins=(git fzf zsh-autosuggestions zsh-syntax-highlighting)/' "$HOME/.zshrc"
fi

# ─── Claude Code plugins ─────────────────────────────────────────────────────
for plugin in "${CLAUDE_PLUGINS[@]:-}"; do
    [ -z "$plugin" ] && continue
    claude plugin install "$plugin" --scope user 2>/dev/null || true
done

# ─── Skill installs ──────────────────────────────────────────────────────────
mkdir -p "$HOME/.claude/skills"
for entry in "${SKILL_INSTALLS[@]:-}"; do
    [ -z "$entry" ] && continue
    sentinel="${entry%%|*}"
    cmd="${entry#*|}"
    if [ ! -f "$HOME/.claude/skills/.installed-${sentinel}" ]; then
        eval "$cmd"
        touch "$HOME/.claude/skills/.installed-${sentinel}"
    fi
done

# ─── Create projects directory ───────────────────────────────────────────────
mkdir -p "$HOME/projects"

echo "=== devbox provisioning complete ==="
echo "Node: $(node --version)"
echo "Python: $(python --version 2>&1)"
echo "Go: $(go version)"
echo "Claude Code: $(claude --version 2>&1 || echo 'installed')"
echo "Databricks CLI: $(databricks --version 2>&1 || echo 'installed')"
