#!/bin/bash
# Runs as the lima user (non-interactive, non-login shell).
# Idempotent: check-before-install throughout.
set -eux

# ─── Version pins ────────────────────────────────────────────────────────────
set -a; source /provision/versions.env; set +a
# ─────────────────────────────────────────────────────────────────────────────

# ─── Claude Code plugins ─────────────────────────────────────────────────────
# Format: "<name>@<marketplace>"
CLAUDE_PLUGINS=(
    # "impeccable@marketplace"   # example
)

# ─── Skill install commands ──────────────────────────────────────────────────
# Format: "<sentinel-name>|<install command>"
SKILL_INSTALLS=(
    # "impeccable|curl -fsSL https://impeccable.style/install | bash"
)
# ─────────────────────────────────────────────────────────────────────────────

# HOME is set correctly by Lima — do not override it.
# Do NOT export XDG_CONFIG_HOME: nvm uses it to pick its install dir,
# and setting it causes nvm to install to ~/.config/nvm instead of ~/.nvm.

# ─── SSH config ──────────────────────────────────────────────────────────────
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if ! grep -qF 'github-personal' "$HOME/.ssh/config" 2>/dev/null; then
    cat >> "$HOME/.ssh/config" << 'EOF'
Host github-personal
    HostName github.com
    User git
EOF
    chmod 600 "$HOME/.ssh/config"
fi

# Pre-populate GitHub host key to avoid interactive prompt on first connect
if ! grep -qF 'github.com' "$HOME/.ssh/known_hosts" 2>/dev/null; then
    ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
    chmod 600 "$HOME/.ssh/known_hosts"
fi

# ─── Git identity ─────────────────────────────────────────────────────────────
if [ -n "${GIT_NAME:-}" ] && [ -n "${GIT_EMAIL:-}" ]; then
    git config --global user.name  "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
fi
git config --global init.defaultBranch main

# ─── zsh + oh-my-zsh ─────────────────────────────────────────────────────────
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

if command -v zsh >/dev/null && [ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]; then
    sudo chsh -s "$(command -v zsh)" "$USER" || true
fi

# ─── SSH agent socket (Lima VZ path) ─────────────────────────────────────────
# Must come AFTER oh-my-zsh install — oh-my-zsh replaces .zshrc on first run.
SSH_SOCK_EXPR='export SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock'
grep -qF 'SSH_AUTH_SOCK' "$HOME/.zshrc" 2>/dev/null || echo "$SSH_SOCK_EXPR" >> "$HOME/.zshrc"
eval "$SSH_SOCK_EXPR" || true

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

# ─── Rust ────────────────────────────────────────────────────────────────────
if ! command -v rustc >/dev/null; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$PATH"

if ! grep -qF '.cargo/bin' "$HOME/.zshrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.zshrc"
fi

# ─── Claude Code CLI ─────────────────────────────────────────────────────────
if ! command -v claude >/dev/null; then
    npm install -g @anthropic-ai/claude-code
fi

# Source /etc/environment in .zshrc so ANTHROPIC_API_KEY is available in interactive shells
# without writing the literal key value into .zshrc
if ! grep -qF '/etc/environment' "$HOME/.zshrc" 2>/dev/null; then
    echo 'set -a; source /etc/environment 2>/dev/null || true; set +a' >> "$HOME/.zshrc"
fi

# Claude Code user config
mkdir -p "$HOME/.claude/skills"
cp /provision/config/claude/CLAUDE.md "$HOME/.claude/CLAUDE.md"
cp /provision/config/claude/settings.json "$HOME/.claude/settings.json"

if [ -d /provision/config/claude/skills ] && [ "$(ls -A /provision/config/claude/skills 2>/dev/null)" ]; then
    cp -r /provision/config/claude/skills/. "$HOME/.claude/skills/"
fi

# User-scoped MCPs — substitute username and node version for absolute npx path
NPX_BIN="$NVM_DIR/versions/node/v${NODE_VERSION}/bin/npx"
sed -e "s|\$USER|$USER|g" -e "s|\"npx\"|\"$NPX_BIN\"|g" /provision/config/mcp.json > "$HOME/.mcp.json"

# ─── opencode ────────────────────────────────────────────────────────────────
if [ ! -f "$HOME/.opencode/bin/opencode" ]; then
    curl -fsSL https://opencode.ai/install | bash
fi
export PATH="$HOME/.opencode/bin:$PATH"

if ! grep -qF '.opencode/bin' "$HOME/.zshrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> "$HOME/.zshrc"
fi

mkdir -p "$HOME/.config/opencode"
sed -e "s|\$USER|$USER|g" -e "s|\"npx\"|\"$NPX_BIN\"|g" /provision/config/opencode/opencode.json > "$HOME/.config/opencode/opencode.json"

# ─── Databricks CLI ──────────────────────────────────────────────────────────
if ! databricks --version 2>/dev/null | grep -q "$DATABRICKS_VERSION"; then
    mkdir -p "$HOME/.local/bin"
    curl -fsSL "https://github.com/databricks/cli/releases/download/v${DATABRICKS_VERSION}/databricks_cli_${DATABRICKS_VERSION}_linux_arm64.zip" -o /tmp/databricks.zip
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

# ─── yq ──────────────────────────────────────────────────────────────────────
if ! yq --version 2>/dev/null | grep -q "${YQ_VERSION#v}"; then
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_arm64" -o "$HOME/.local/bin/yq"
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

if grep -q "^plugins=(git)" "$HOME/.zshrc" 2>/dev/null; then
    sed -i 's/^plugins=(git)/plugins=(git fzf zsh-autosuggestions zsh-syntax-highlighting)/' "$HOME/.zshrc"
fi

# ─── Claude Code plugins ─────────────────────────────────────────────────────
for plugin in "${CLAUDE_PLUGINS[@]+${CLAUDE_PLUGINS[@]}}"; do
    claude plugin install "$plugin" --scope user 2>/dev/null || true
done

# ─── Skill installs ──────────────────────────────────────────────────────────
for entry in "${SKILL_INSTALLS[@]+${SKILL_INSTALLS[@]}}"; do
    [ -z "$entry" ] && continue
    sentinel="${entry%%|*}"
    cmd="${entry#*|}"
    if [ ! -f "$HOME/.claude/skills/.installed-${sentinel}" ]; then
        eval "$cmd"
        touch "$HOME/.claude/skills/.installed-${sentinel}"
    fi
done

# ─── Container setup ─────────────────────────────────────────────────────────
# Enable linger so containerd-rootless.service starts at boot without a login session.
loginctl enable-linger "$USER" 2>/dev/null || true
# Pre-create Postgres data dir (mode 0777: works around VZ+virtiofs transient root:root race at container start).
mkdir -p "$HOME/data/postgres"
chmod 0777 "$HOME/data/postgres"
# docker compat aliases (VM-only)
grep -qF 'alias docker=' "$HOME/.zshrc" 2>/dev/null || echo 'alias docker="nerdctl"' >> "$HOME/.zshrc"
grep -qF 'alias docker-compose=' "$HOME/.zshrc" 2>/dev/null || echo 'alias docker-compose="nerdctl compose"' >> "$HOME/.zshrc"

echo "=== devbox provisioning complete ==="
echo "Node: $(node --version)"
echo "Python: $(python --version 2>&1)"
echo "Go: $(go version)"
echo "Claude Code: $(claude --version 2>&1 || echo 'installed')"
echo "Databricks CLI: $(databricks --version 2>&1 || echo 'installed')"
