#!/bin/bash

install_node() {
    local installer
    stage "Node.js $NODE_VERSION"
    export NVM_DIR="$HOME/.nvm"
    installer="$(mktemp)"
    download_verified \
        "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" \
        "$NVM_INSTALL_SHA256" "$installer"
    PROFILE=/dev/null bash "$installer"
    rm -f "$installer"
    # nvm.sh is third-party code installed by the pinned installer above and
    # only exists on the already-provisioned guest, so it cannot be followed.
    # shellcheck disable=SC1091
    source "$NVM_DIR/nvm.sh"
    nvm install "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    [ "$(node --version)" = "v$NODE_VERSION" ]
    npm install --global --silent "npm@$NPM_VERSION"
    [ "$(npm --version)" = "$NPM_VERSION" ]
}

install_python() {
    stage "Python $PYTHON_VERSION"
    export PYENV_ROOT="$HOME/.pyenv"
    if [ ! -x "$PYENV_ROOT/bin/pyenv" ]; then
        # Clone upstream master, then converge to the pinned commit below: git
        # object hashes authenticate the checkout, so no artifact pin applies.
        git clone --depth 1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
    fi
    if [ "$(git -C "$PYENV_ROOT" rev-parse HEAD)" != "$PYENV_REPO_COMMIT" ]; then
        git -C "$PYENV_ROOT" fetch --depth 1 origin "$PYENV_REPO_COMMIT"
        git -C "$PYENV_ROOT" checkout --detach --quiet "$PYENV_REPO_COMMIT"
    fi
    # The pinned tree already carries the requested interpreter definition, so
    # a converged guest (HEAD at the pin) never needs the git remote again.
    if ! pyenv versions --bare | grep -qx "$PYTHON_VERSION"; then
        pyenv install "$PYTHON_VERSION"
    fi
    pyenv global "$PYTHON_VERSION"
    pyenv rehash
    [ "$(python --version | awk '{print $2}')" = "$PYTHON_VERSION" ]
}

install_uv() {
    local installer
    stage "uv $UV_VERSION"
    installer="$(mktemp)"
    download_verified \
        "https://astral.sh/uv/$UV_VERSION/install.sh" \
        "$UV_INSTALL_SHA256" "$installer"
    UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh "$installer"
    rm -f "$installer"
    [ "$(uv --version | awk '{print $2}')" = "$UV_VERSION" ]
}

install_go() {
    local archive directory launcher
    stage "Go $GO_VERSION"
    launcher="$HOME/.local/bin/go"
    if [ -x "$launcher" ] && [ "$(go version | awk '{print $3}' | sed 's/^go//')" = "$GO_VERSION" ]; then
        return
    fi
    archive="$(mktemp)"
    directory="$(mktemp -d)"
    download_verified \
        "https://go.dev/dl/go$GO_VERSION.linux-arm64.tar.gz" \
        "$GO_SHA256" "$archive"
    tar -xzf "$archive" -C "$directory"
    [ -x "$directory/go/bin/go" ]
    rm -rf "$HOME/.local/go"
    mv "$directory/go" "$HOME/.local/go"
    ln -sfn "$HOME/.local/go/bin/go" "$HOME/.local/bin/go"
    ln -sfn "$HOME/.local/go/bin/gofmt" "$HOME/.local/bin/gofmt"
    rm -rf "$archive" "$directory"
    hash -r
    [ "$(go version | awk '{print $3}' | sed 's/^go//')" = "$GO_VERSION" ]
}

install_rust() {
    stage "Rust $RUST_VERSION"
    rustup toolchain install "$RUST_VERSION" --profile default
    rustup default "$RUST_VERSION"
    [ "$(rustc --version | awk '{print $2}')" = "$RUST_VERSION" ]
}

install_runtimes() {
    install_node
    install_python
    install_uv
    install_go
    install_rust
}
