#!/bin/bash

install_node() {
    local installer
    stage "Node.js $NODE_VERSION"
    export NVM_DIR="$HOME/.nvm"
    installer="$(mktemp)"
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh -o "$installer"
    PROFILE=/dev/null bash "$installer"
    rm -f "$installer"
    source "$NVM_DIR/nvm.sh"
    nvm install "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    version_equals "$(node --version)" "v$NODE_VERSION"
    npm install --global --silent "npm@$NPM_VERSION"
    version_equals "$(npm --version)" "$NPM_VERSION"
}

install_python() {
    local installer
    stage "Python $PYTHON_VERSION"
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
    if [ ! -x "$PYENV_ROOT/bin/pyenv" ]; then
        installer="$(mktemp)"
        curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
            https://pyenv.run -o "$installer"
        bash "$installer"
        rm -f "$installer"
    fi
    pyenv versions --bare | grep -qx "$PYTHON_VERSION" || pyenv install "$PYTHON_VERSION"
    pyenv global "$PYTHON_VERSION"
    pyenv rehash
    version_equals "$(python --version | awk '{print $2}')" "$PYTHON_VERSION"
}

install_uv() {
    local installer
    stage "uv $UV_VERSION"
    mkdir -p "$HOME/.local/bin"
    installer="$(mktemp)"
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
        "https://astral.sh/uv/$UV_VERSION/install.sh" -o "$installer"
    UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh "$installer"
    rm -f "$installer"
    version_equals "$(uv --version | awk '{print $2}')" "$UV_VERSION"
}

install_java() {
    stage "Java $JAVA_VERSION"
    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-arm64
    export PATH="$JAVA_HOME/bin:$PATH"
    java -version 2>&1 | grep -qF "version \"$JAVA_VERSION"
}

install_go() {
    local launcher
    stage "Go $GO_VERSION"
    launcher="$HOME/.local/bin/go$GO_VERSION"
    export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"
    if [ -x "$launcher" ] && version_equals "$(go version | awk '{print $3}' | sed 's/^go//')" "$GO_VERSION"; then
        return
    fi
    mkdir -p "$HOME/.local/bin"
    GOBIN="$HOME/.local/bin" /usr/bin/go install "golang.org/dl/go$GO_VERSION@latest"
    "$launcher" download
    ln -sfn "go$GO_VERSION" "$HOME/.local/bin/go"
    version_equals "$(go version | awk '{print $3}' | sed 's/^go//')" "$GO_VERSION"
}

install_rust() {
    stage "Rust $RUST_VERSION"
    export PATH="$HOME/.cargo/bin:$PATH"
    rustup toolchain install "$RUST_VERSION" --profile default
    rustup default "$RUST_VERSION"
    version_equals "$(rustc --version | awk '{print $2}')" "$RUST_VERSION"
}

install_runtimes() {
    export PATH="$HOME/.local/bin:$PATH"
    install_node
    install_python
    install_uv
    install_java
    install_go
    install_rust
}
