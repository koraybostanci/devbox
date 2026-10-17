#!/bin/bash
# Sourced by check.sh after ROOT, validation_root, fail, file_mode, and the
# env_case helpers are set.
# Sourced-fixture model: `validation_root` and the env_case helpers exist only
# in check.sh, and the rejection patterns below are intentionally literal, so
# both findings are declared once instead of suppressing them per line.
# shellcheck disable=SC2016,SC2154

# Host .env values are validated before they reach Colima or the guest.
for value in 0 65536 999999; do
    reject_env "export POSTGRES_PORT=$value"
done
for value in 1 65535; do
    expect_env "export POSTGRES_PORT=$value" POSTGRES_PORT "$value"
done
for value in 'has space' 'bad$value' 'overlong_identifier_name_that_is_more_than_sixty_three_characters_long'; do
    reject_env "export POSTGRES_USER=\"$value\""
done
reject_env 'export POSTGRES_DB="bad name"'
reject_env 'export DEVBOX_USE_HOST_PROXY=maybe'
reject_env 'export DEVBOX_DISK=0'
reject_env 'not an assignment'
expect_env 'export DEVBOX_USE_HOST_PROXY=true' DEVBOX_USE_HOST_PROXY true
expect_env 'export DEVBOX_CPU=8' DEVBOX_CPU 8
expect_env '' DEVBOX_CPU 4
expect_env "export POSTGRES_DB='quoted'" POSTGRES_DB quoted
cpu_error="$(env_case 'export DEVBOX_CPU=four' 2>&1 >/dev/null || true)"
[[ "$cpu_error" == *DEVBOX_CPU*four* ]] || fail "invalid DEVBOX_CPU rejection did not name the key and value"
if ENV_CASE_MODE=644 env_case '' >/dev/null 2>&1; then
    fail "load_env accepted a world-readable configuration file"
fi

# Proxy forwarding is opt-in and applies only to the devbox Colima start
# command; otherwise every proxy variable is passed explicitly empty.
proxy_root="$validation_root/proxy-unit"
mkdir -p "$proxy_root/bin" "$proxy_root/home"
cat >"$proxy_root/bin/colima" <<'EOF'
#!/bin/bash
for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY WS_PROXY NO_PROXY \
    http_proxy https_proxy all_proxy ftp_proxy ws_proxy no_proxy; do
    if value="$(printenv "$key")"; then
        printf '%s=%s\n' "$key" "${value:+present}"
    else
        printf '%s=unset\n' "$key"
    fi
done >"$DEVBOX_COLIMA_CAPTURE"
EOF
chmod +x "$proxy_root/bin/colima"
proxy_capture() {
    env HTTP_PROXY=http://user:secret@proxy.example:8080 \
        HTTPS_PROXY=http://user:secret@proxy.example:8080 \
        http_proxy=http://user:secret@proxy.example:8080 \
        https_proxy=http://user:secret@proxy.example:8080 \
        no_proxy=localhost,127.0.0.1 \
        HOME="$proxy_root/home" PATH="$proxy_root/bin:/usr/bin:/bin" ROOT="$ROOT" \
        DEVBOX_COLIMA_CAPTURE="$proxy_root/capture" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/devbox.sh"
        configure_devbox_paths
        DEVBOX_COLIMA_PROXY_OPT_IN="$1"
        shift
        devbox_colima "$@"
    ' _ "$@" || fail "proxy capture Colima invocation failed"
}
proxy_capture false list
[ "$(grep -c '=$' "$proxy_root/capture")" = 12 ] ||
    fail "default proxy policy did not explicitly clear every proxy variable"
proxy_capture true list
[ "$(grep -c '=$' "$proxy_root/capture")" = 12 ] ||
    fail "proxy opt-in leaked to a non-start Colima command"
proxy_capture true start devbox
for proxy_key in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy no_proxy; do
    grep -qx "$proxy_key=present" "$proxy_root/capture" ||
        fail "explicit proxy opt-in did not preserve $proxy_key for Colima start"
done

# The rendered profile must explicitly disable mounts, forwarding, and
# host-inherited env; removing or enabling any of them fails validation.
colima_valid() {
    ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/devbox.sh"
        validate_devbox_colima_config "$1"
    ' _ "$1"
}
colima_valid "$ROOT/colima.yaml" || fail "devbox Colima template failed validation"
for required_setting in runtime arch vmType autoActivate forwardAgent portForwarder sshConfig mounts env; do
    grep -v "^$required_setting:" "$ROOT/colima.yaml" >"$validation_root/colima-test.yaml"
    if colima_valid "$validation_root/colima-test.yaml"; then
        fail "Colima validation accepted a config without $required_setting"
    fi
done
for key in autoActivate forwardAgent portForwarder sshConfig; do
    sed "s/^$key:.*/$key: true/" "$ROOT/colima.yaml" >"$validation_root/colima-test.yaml"
    if colima_valid "$validation_root/colima-test.yaml"; then
        fail "Colima validation accepted unsafe $key"
    fi
done
