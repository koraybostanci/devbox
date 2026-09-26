#!/bin/bash
# Sourced by check.sh after ROOT, validation_root, fail, and file_mode are set.

# PostgreSQL's published host port is restricted to the TCP port range.
port_env="$validation_root/postgres-port.env"
for invalid_port in 0 65536 999999; do
    printf 'export GIT_NAME="Port Test"\nexport GIT_EMAIL="port@example.com"\nexport POSTGRES_PORT=%s\n' \
        "$invalid_port" >"$port_env"
    chmod 600 "$port_env"
    if DEVBOX_ENV_FILE="$port_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        load_env
    ' 2>/dev/null; then
        fail "load_env accepted PostgreSQL port $invalid_port"
    fi
done
for valid_port in 1 65535; do
    printf 'export GIT_NAME="Port Test"\nexport GIT_EMAIL="port@example.com"\nexport POSTGRES_PORT=%s\n' \
        "$valid_port" >"$port_env"
    chmod 600 "$port_env"
    port_output="$(DEVBOX_ENV_FILE="$port_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        load_env
        printf "%s\n" "$POSTGRES_PORT"
    ')" || fail "load_env rejected boundary PostgreSQL port $valid_port"
    [ "$port_output" = "$valid_port" ] || fail "load_env changed PostgreSQL port $valid_port"
done
for invalid_identifier in 'has space' 'bad$value' 'overlong_identifier_name_that_is_more_than_sixty_three_characters_long'; do
    printf 'export GIT_NAME="Port Test"\nexport GIT_EMAIL="port@example.com"\nexport POSTGRES_USER="%s"\n' \
        "$invalid_identifier" >"$port_env"
    chmod 600 "$port_env"
    if DEVBOX_ENV_FILE="$port_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        load_env
    ' 2>/dev/null; then
        fail "load_env accepted unsafe PostgreSQL user '$invalid_identifier'"
    fi
done
printf 'export GIT_NAME="Port Test"\nexport GIT_EMAIL="port@example.com"\nexport POSTGRES_DB="bad name"\n' \
    >"$port_env"
chmod 600 "$port_env"
if DEVBOX_ENV_FILE="$port_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    load_env
' 2>/dev/null; then
    fail "load_env accepted an unsafe PostgreSQL database name"
fi

# Proxy forwarding is opt-in, applies only to the devbox Colima start command,
# and the host .env boolean is parsed as data.
proxy_env="$validation_root/proxy.env"
printf 'export GIT_NAME="Proxy Test"\nexport GIT_EMAIL="proxy@example.com"\nexport DEVBOX_USE_HOST_PROXY=true\n' \
    >"$proxy_env"
chmod 600 "$proxy_env"
proxy_config_output="$(DEVBOX_ENV_FILE="$proxy_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    load_env
    printf "%s\n" "$DEVBOX_USE_HOST_PROXY"
')" || fail "load_env rejected the host proxy opt-in"
[ "$proxy_config_output" = true ] || fail "load_env did not load the proxy opt-in"
printf 'export GIT_NAME="Proxy Test"\nexport GIT_EMAIL="proxy@example.com"\nexport DEVBOX_USE_HOST_PROXY=maybe\n' \
    >"$proxy_env"
chmod 600 "$proxy_env"
if DEVBOX_ENV_FILE="$proxy_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    load_env
' 2>/dev/null; then
    fail "load_env accepted an invalid host proxy opt-in"
fi

proxy_root="$validation_root/proxy-unit"
proxy_bin="$proxy_root/bin"
mkdir -p "$proxy_bin" "$proxy_root/home"
cat >"$proxy_bin/colima" <<'EOF'
#!/bin/bash
{
    for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY WS_PROXY NO_PROXY \
        http_proxy https_proxy all_proxy ftp_proxy ws_proxy no_proxy; do
        if value="$(printenv "$key" 2>/dev/null)"; then
            if [ -n "$value" ]; then
                printf '%s=present\n' "$key"
            else
                printf '%s=empty\n' "$key"
            fi
        else
            printf '%s=unset\n' "$key"
        fi
    done
} >"$DEVBOX_COLIMA_CAPTURE"
EOF
chmod +x "$proxy_bin/colima"
proxy_host_env=(
    "HTTP_PROXY=http://user:secret@proxy.example:8080"
    "HTTPS_PROXY=http://user:secret@proxy.example:8080"
    "ALL_PROXY=socks5://user:secret@proxy.example:1080"
    "http_proxy=http://user:secret@proxy.example:8080"
    "https_proxy=http://user:secret@proxy.example:8080"
    "no_proxy=localhost,127.0.0.1"
)
env "${proxy_host_env[@]}" HOME="$proxy_root/home" PATH="$proxy_bin:/usr/bin:/bin" \
    ROOT="$ROOT" DEVBOX_COLIMA_CAPTURE="$proxy_root/default.capture" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    configure_devbox_paths
    devbox_colima list
' || fail "default proxy-scrubbed Colima invocation failed"
for proxy_key in HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY WS_PROXY NO_PROXY \
    http_proxy https_proxy all_proxy ftp_proxy ws_proxy no_proxy; do
    grep -qx "$proxy_key=empty" "$proxy_root/default.capture" ||
        fail "default proxy policy did not explicitly clear $proxy_key"
done
env "${proxy_host_env[@]}" HOME="$proxy_root/home" PATH="$proxy_bin:/usr/bin:/bin" \
    ROOT="$ROOT" DEVBOX_COLIMA_CAPTURE="$proxy_root/optin-list.capture" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    configure_devbox_paths
    DEVBOX_COLIMA_PROXY_OPT_IN=true
    devbox_colima list
' || fail "proxy-scrubbed Colima list with opt-in failed"
for proxy_key in HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY WS_PROXY NO_PROXY \
    http_proxy https_proxy all_proxy ftp_proxy ws_proxy no_proxy; do
    grep -qx "$proxy_key=empty" "$proxy_root/optin-list.capture" ||
        fail "proxy opt-in leaked to non-start Colima command $proxy_key"
done
env "${proxy_host_env[@]}" HOME="$proxy_root/home" PATH="$proxy_bin:/usr/bin:/bin" \
    ROOT="$ROOT" DEVBOX_COLIMA_CAPTURE="$proxy_root/optin-start.capture" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    configure_devbox_paths
    DEVBOX_COLIMA_PROXY_OPT_IN=true
    devbox_colima start devbox
' || fail "explicit proxy-enabled Colima start failed"
for proxy_key in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy no_proxy; do
    grep -qx "$proxy_key=present" "$proxy_root/optin-start.capture" ||
        fail "explicit proxy opt-in did not preserve $proxy_key for Colima start"
done

# The rendered profile must explicitly disable mounts and host-inherited env;
# deleting either invariant makes config validation fail.
ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    validate_devbox_colima_config "$ROOT/colima.yaml"
' || fail "devbox Colima template did not explicitly disable mounts and host env"
for required_setting in runtime arch vmType autoActivate forwardAgent portForwarder sshConfig mounts env; do
    grep -v "^$required_setting:" "$ROOT/colima.yaml" \
        >"$validation_root/colima-missing-$required_setting.yaml"
    if ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/devbox.sh"
        validate_devbox_colima_config "$1"
    ' _ "$validation_root/colima-missing-$required_setting.yaml"; then
        fail "Colima validation accepted a config without $required_setting"
    fi
done
for setting in 'autoActivate:false' 'forwardAgent:false' 'portForwarder:none' 'sshConfig:false'; do
    key="${setting%%:*}"
    value="${setting#*:}"
    sed "s/^$key:.*/$key: true/" "$ROOT/colima.yaml" >"$validation_root/colima-$key-enabled.yaml"
    if ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/devbox.sh"
        validate_devbox_colima_config "$1"
    ' _ "$validation_root/colima-$key-enabled.yaml"; then
        fail "Colima validation accepted unsafe $key=$value"
    fi
done
