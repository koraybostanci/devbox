#!/bin/bash
# Sourced by check.sh after ROOT, validation_root, fail, file_mode, and the
# env_case helpers are set.
# Sourced-fixture model: `validation_root` and the env_case helpers exist only
# in check.sh, and the rejection patterns below are intentionally literal, so
# both findings are declared once instead of suppressing them per line.
# shellcheck disable=SC2016,SC2154

# Standalone execution has no fixtures or helpers; insist on the gate.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'ERROR: scripts/check-host-config.sh must be sourced by scripts/check.sh\n' >&2
    exit 1
fi

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

# Git identities seeded for the guest must be real values: the validator
# rejects empty values and the documented placeholders for both keys, and
# accepts a valid pair.
for git_placeholder in '' 'Your Name' 'you@personal.com'; do
    reject_env "export GIT_NAME=\"$git_placeholder\""
    reject_env "export GIT_EMAIL=\"$git_placeholder\""
done
expect_env 'export GIT_NAME="Real Name"' GIT_NAME 'Real Name'
expect_env 'export GIT_EMAIL=you@example.com' GIT_EMAIL you@example.com

# The proxy-key list is single-sourced from the runtime loop in lib/devbox.sh:
# the stub iterates the sourced array, and this shell expands the array for the
# count assertions below, so a new key becomes covered by construction. The
# source is assignment-only at load time (all behavior lives in functions), and
# the launcher already runs it under the same environment. shellcheck 0.11
# cannot follow a computed path without -x, so the follow warning is disabled
# beside the single runtime source.
# shellcheck disable=SC1091
source "$ROOT/lib/devbox.sh"

# Proxy forwarding is opt-in and applies only to the devbox Colima start
# command; otherwise every proxy variable is passed explicitly empty.
proxy_root="$validation_root/proxy-unit"
mkdir -p "$proxy_root/bin" "$proxy_root/home"
cat >"$proxy_root/bin/colima" <<'EOF'
#!/bin/bash
source "$ROOT/lib/devbox.sh"
for key in "${DEVBOX_PROXY_KEYS[@]}"; do
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
[ "$(grep -c '=$' "$proxy_root/capture")" = "${#DEVBOX_PROXY_KEYS[@]}" ] ||
    fail "default proxy policy did not explicitly clear every proxy variable"
proxy_capture true list
[ "$(grep -c '=$' "$proxy_root/capture")" = "${#DEVBOX_PROXY_KEYS[@]}" ] ||
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
for required_setting in runtime arch vmType autoActivate forwardAgent portForwarder sshPort sshConfig mounts env; do
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
# Dangerous setting shapes: a static SSH port breaks the dynamic-port contract,
# and non-null env or mounts maps would re-open the host boundary.
for colima_override in \
    's#^sshPort:.*#sshPort: 2222#' \
    's#^mounts:.*#mounts: {"/home/devbox": null}#' \
    's#^env:.*#env: {FOO: bar}#'; do
    sed "$colima_override" "$ROOT/colima.yaml" >"$validation_root/colima-test.yaml"
    if colima_valid "$validation_root/colima-test.yaml"; then
        fail "Colima validation accepted an unsafe template setting: $colima_override"
    fi
done
