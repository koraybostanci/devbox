#!/bin/bash

ISOLATION_POC_PROFILE="devbox-isolation-poc"
ISOLATION_POC_OWNER_VERSION="devbox-isolation-poc-v1"
ISOLATION_POC_COLIMA_VERSION="0.10.3"

configure_isolation_poc_paths() {
    local colima_home

    colima_home="${COLIMA_HOME:-$HOME/.colima}"
    [ "$colima_home" = "$HOME/.colima" ] ||
        die "isolation-poc requires the standard Colima home $HOME/.colima; unset COLIMA_HOME"
    ISOLATION_POC_LIMA_HOME="$colima_home/_lima"
    case "${LIMA_HOME:-}" in
        '' | "$ISOLATION_POC_LIMA_HOME") ;;
        *) die "isolation-poc requires LIMA_HOME to be unset or $ISOLATION_POC_LIMA_HOME" ;;
    esac
    ISOLATION_POC_COLIMA_PROFILE="$colima_home/$ISOLATION_POC_PROFILE"
    ISOLATION_POC_COLIMA_CONFIG="$ISOLATION_POC_COLIMA_PROFILE/colima.yaml"
    ISOLATION_POC_COLIMA_OWNER="$ISOLATION_POC_COLIMA_PROFILE/.devbox-owner"
    ISOLATION_POC_LIMA_CONFIG="$ISOLATION_POC_LIMA_HOME/$ISOLATION_POC_PROFILE/lima.yaml"
    ISOLATION_POC_DOCKER_CONFIG="$DEVBOX_CONFIG_ROOT/isolation-poc/docker"
}

check_isolation_poc_dependencies() {
    local command_name colima_version
    local -a missing=()

    for command_name in colima jq yq; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    [ "${#missing[@]}" -eq 0 ] ||
        die "Missing host dependencies for isolation-poc. Review and run: brew install ${missing[*]}"
    colima_version="$(isolation_poc_colima version | awk 'NR == 1 {print $3}')"
    [ "$colima_version" = "$ISOLATION_POC_COLIMA_VERSION" ] ||
        die "isolation-poc requires Colima $ISOLATION_POC_COLIMA_VERSION exactly (found $colima_version)"
}

prepare_isolation_poc_docker_config() {
    mkdir -p "$ISOLATION_POC_DOCKER_CONFIG"
    chmod 700 "$ISOLATION_POC_DOCKER_CONFIG"
}

isolation_poc_colima() {
    LIMA_HOME="$ISOLATION_POC_LIMA_HOME" \
        DOCKER_CONFIG="$ISOLATION_POC_DOCKER_CONFIG" \
        command colima "$@"
}

load_isolation_poc_config() {
    local line key value_expression

    validate_env_file
    unset DEVBOX_ISOLATION_POC_INTERFACE DEVBOX_ISOLATION_POC_DNS DEVBOX_ISOLATION_POC_DENY_TARGETS
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]]
        key="${BASH_REMATCH[2]}"
        case "$key" in
            DEVBOX_ISOLATION_POC_INTERFACE | DEVBOX_ISOLATION_POC_DNS | DEVBOX_ISOLATION_POC_DENY_TARGETS)
                value_expression="${line#*=}"
                printf -v "$key" '%s' "$(printf '%s\n' "$value_expression" | jq -Rr fromjson)"
                ;;
        esac
    done <"$DEVBOX_DIR/.env"

    [ -n "${DEVBOX_ISOLATION_POC_INTERFACE:-}" ] ||
        die "Set DEVBOX_ISOLATION_POC_INTERFACE in $DEVBOX_DIR/.env"
    [ -n "${DEVBOX_ISOLATION_POC_DNS:-}" ] ||
        die "Set DEVBOX_ISOLATION_POC_DNS in $DEVBOX_DIR/.env"
    [ -n "${DEVBOX_ISOLATION_POC_DENY_TARGETS:-}" ] ||
        die "Set DEVBOX_ISOLATION_POC_DENY_TARGETS in $DEVBOX_DIR/.env"

    validate_isolation_poc_interface
    validate_isolation_poc_dns
    validate_isolation_poc_deny_targets
}

valid_ipv4() {
    local address="$1" octet
    local -a octets
    local IFS=.

    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    read -r -a octets <<<"$address"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

validate_isolation_poc_interface() {
    [[ "$DEVBOX_ISOLATION_POC_INTERFACE" =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "DEVBOX_ISOLATION_POC_INTERFACE contains unsupported characters"
    ifconfig "$DEVBOX_ISOLATION_POC_INTERFACE" >/dev/null 2>&1 ||
        die "DEVBOX_ISOLATION_POC_INTERFACE does not exist: $DEVBOX_ISOLATION_POC_INTERFACE"
}

validate_isolation_poc_dns() {
    local resolver host_resolver
    local -a resolvers host_resolvers
    local IFS=,

    [[ "$DEVBOX_ISOLATION_POC_DNS" != *,,* && "$DEVBOX_ISOLATION_POC_DNS" != ,* && "$DEVBOX_ISOLATION_POC_DNS" != *, ]] ||
        die "DEVBOX_ISOLATION_POC_DNS must be a comma-separated IPv4 list without empty entries"
    read -r -a resolvers <<<"$DEVBOX_ISOLATION_POC_DNS"
    [ "${#resolvers[@]}" -gt 0 ] || die "DEVBOX_ISOLATION_POC_DNS must not be empty"
    for resolver in "${resolvers[@]}"; do
        valid_ipv4 "$resolver" || die "DEVBOX_ISOLATION_POC_DNS contains an invalid IPv4 address: $resolver"
        case "$resolver" in
            0.* | 127.* | 169.254.* | 255.255.255.255)
                die "DEVBOX_ISOLATION_POC_DNS must use routable non-host resolvers"
                ;;
        esac
    done

    while IFS= read -r host_resolver; do
        [ -n "$host_resolver" ] && host_resolvers+=("$host_resolver")
    done < <(scutil --dns | awk '$1 ~ /^nameserver\[[0-9]+\]$/ && $2 == ":" { print $3 }' | sort -u)
    for resolver in "${resolvers[@]}"; do
        for host_resolver in "${host_resolvers[@]:-}"; do
            [ "$resolver" != "$host_resolver" ] ||
                die "DEVBOX_ISOLATION_POC_DNS must not reuse the host resolver: $resolver"
        done
    done
}

validate_isolation_poc_deny_targets() {
    local target address port
    local -a targets
    local IFS=,

    [[ "$DEVBOX_ISOLATION_POC_DENY_TARGETS" != *,,* && "$DEVBOX_ISOLATION_POC_DENY_TARGETS" != ,* && "$DEVBOX_ISOLATION_POC_DENY_TARGETS" != *, ]] ||
        die "DEVBOX_ISOLATION_POC_DENY_TARGETS must be a comma-separated IPv4:port list without empty entries"
    read -r -a targets <<<"$DEVBOX_ISOLATION_POC_DENY_TARGETS"
    [ "${#targets[@]}" -gt 0 ] || die "DEVBOX_ISOLATION_POC_DENY_TARGETS must not be empty"
    for target in "${targets[@]}"; do
        [[ "$target" =~ ^[0-9.]+:[0-9]+$ ]] ||
            die "DEVBOX_ISOLATION_POC_DENY_TARGETS entries must be IPv4:port: $target"
        address="${target%:*}"
        port="${target##*:}"
        valid_ipv4 "$address" || die "DEVBOX_ISOLATION_POC_DENY_TARGETS contains an invalid IPv4 address: $address"
        ((10#$port >= 1 && 10#$port <= 65535)) ||
            die "DEVBOX_ISOLATION_POC_DENY_TARGETS contains an invalid port: $port"
    done
}

check_isolation_poc_ownership() {
    local owner_version owner_checkout

    [ -e "$ISOLATION_POC_COLIMA_PROFILE" ] || return 0
    [ -f "$ISOLATION_POC_COLIMA_OWNER" ] ||
        die "Colima profile '$ISOLATION_POC_PROFILE' already exists but is not owned by this checkout"
    owner_version="$(sed -n '1p' "$ISOLATION_POC_COLIMA_OWNER")"
    owner_checkout="$(sed -n '2p' "$ISOLATION_POC_COLIMA_OWNER")"
    [ "$owner_version" = "$ISOLATION_POC_OWNER_VERSION" ] ||
        die "Invalid ownership marker in $ISOLATION_POC_COLIMA_OWNER"
    [ "$owner_checkout" = "$DEVBOX_DIR" ] ||
        die "Colima profile '$ISOLATION_POC_PROFILE' is owned by another devbox checkout: $owner_checkout"
}

render_isolation_poc_config() {
    local temporary resolver
    local -a resolvers
    local IFS=,

    check_isolation_poc_ownership
    mkdir -p "$ISOLATION_POC_COLIMA_PROFILE"
    read -r -a resolvers <<<"$DEVBOX_ISOLATION_POC_DNS"
    temporary="$(mktemp "$ISOLATION_POC_COLIMA_PROFILE/.colima.yaml.XXXXXX")"
    {
        cat <<EOF
cpu: 2
memory: 2
disk: 20
arch: host
runtime: docker
autoActivate: false
network:
  address: true
  mode: bridged
  interface: $(json_string "$DEVBOX_ISOLATION_POC_INTERFACE")
  preferredRoute: true
  dns:
EOF
        for resolver in "${resolvers[@]}"; do
            printf '    - %s\n' "$resolver"
        done
        cat <<'EOF'
vmType: vz
mountType: virtiofs
portForwarder: none
forwardAgent: false
sshConfig: false
EOF
    } >"$temporary"
    yq eval '.' "$temporary" >/dev/null || {
        command rm -f "$temporary"
        die "Generated isolation POC Colima configuration is invalid"
    }
    chmod 600 "$temporary"
    mv "$temporary" "$ISOLATION_POC_COLIMA_CONFIG"
    printf '%s\n%s\n' "$ISOLATION_POC_OWNER_VERSION" "$DEVBOX_DIR" >"$ISOLATION_POC_COLIMA_OWNER"
    chmod 600 "$ISOLATION_POC_COLIMA_OWNER"
}

isolation_poc_state() {
    isolation_poc_colima list --json 2>/dev/null |
        jq -r --arg profile "$ISOLATION_POC_PROFILE" 'select(.name == $profile) | .status' |
        head -n 1
}

isolation_poc_guest() {
    isolation_poc_colima ssh -p "$ISOLATION_POC_PROFILE" -- "$@"
}

verify_isolation_poc_config() {
    local actual_interface actual_dns

    [ -f "$ISOLATION_POC_COLIMA_CONFIG" ] ||
        die "Isolation POC profile has not been configured; run 'devbox isolation-poc'"
    yq -e '
        .runtime == "docker" and
        .vmType == "vz" and
        .autoActivate == false and
        .forwardAgent == false and
        .sshConfig == false and
        .portForwarder == "none" and
        (.mounts == null) and
        .network.address == true and
        .network.mode == "bridged" and
        .network.preferredRoute == true
    ' "$ISOLATION_POC_COLIMA_CONFIG" >/dev/null ||
        die "Isolation POC configuration no longer satisfies the strict profile requirements"
    actual_interface="$(yq eval '.network.interface' "$ISOLATION_POC_COLIMA_CONFIG")" ||
        die "Unable to read the isolation POC network interface"
    [ "$actual_interface" = "$DEVBOX_ISOLATION_POC_INTERFACE" ] ||
        die "Isolation POC configuration has an unexpected network interface"
    actual_dns="$(yq eval '.network.dns | join(",")' "$ISOLATION_POC_COLIMA_CONFIG")" ||
        die "Unable to read the isolation POC DNS configuration"
    [ "$actual_dns" = "$DEVBOX_ISOLATION_POC_DNS" ] ||
        die "Isolation POC configuration has unexpected DNS resolvers"
}

verify_isolation_poc_no_user_network() {
    [ -f "$ISOLATION_POC_LIMA_CONFIG" ] ||
        die "Colima did not create the expected Lima configuration: $ISOLATION_POC_LIMA_CONFIG"
    if yq -e '.networks[]? | select(.lima == "user-v2")' "$ISOLATION_POC_LIMA_CONFIG" >/dev/null; then
        printf '%s\n' "ERROR: Strict isolation failed: Colima generated a user-v2 network alongside the bridge; Colima 0.10.3 has no supported setting to remove this fallback" >&2
        return 1
    fi
}

verify_isolation_poc_guest() {
    local target
    local -a targets
    local IFS=,

    read -r -a targets <<<"$DEVBOX_ISOLATION_POC_DENY_TARGETS"
    isolation_poc_guest env EXPECTED_DNS="$DEVBOX_ISOLATION_POC_DNS" bash -s -- "${targets[@]}" <<'EOF'
set -Eeuo pipefail

command -v findmnt >/dev/null || { echo "findmnt is unavailable in the guest" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is unavailable in the guest" >&2; exit 1; }
command -v timeout >/dev/null || { echo "timeout is unavailable in the guest" >&2; exit 1; }
findmnt -rn -t virtiofs,9p,fuse.sshfs,reverse-sshfs | grep -q . && {
    echo "host-backed mount detected in guest" >&2
    exit 1
}
ip -4 route show default | grep -Eq '^default .* dev [^ ]+' || {
    echo "guest has no IPv4 default route" >&2
    exit 1
}
ip -4 addr show scope global | grep -q 'inet ' || {
    echo "guest has no global IPv4 address" >&2
    exit 1
}

IFS=, read -r -a expected_dns <<<"$EXPECTED_DNS"
mapfile -t actual_dns < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf)
[ "${#actual_dns[@]}" -gt 0 ] || { echo "guest has no DNS resolver" >&2; exit 1; }
for resolver in "${actual_dns[@]}"; do
    case ",${EXPECTED_DNS}," in
        *",${resolver},"*) ;;
        *) echo "guest DNS includes an unexpected resolver: $resolver" >&2; exit 1 ;;
    esac
done
for resolver in "${expected_dns[@]}"; do
    case " ${actual_dns[*]} " in
        *" $resolver "*) ;;
        *) echo "guest DNS is missing configured resolver: $resolver" >&2; exit 1 ;;
    esac
done

curl -4 --fail --silent --show-error --max-time 15 https://example.com/ >/dev/null
for target in "$@"; do
    address="${target%:*}"
    port="${target##*:}"
    if timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$address" "$port"; then
        echo "configured deny target is reachable: $target" >&2
        exit 1
    fi
done
docker info >/dev/null
EOF
}

run_isolation_poc() {
    local action="$1" state strict_network=true

    case "$action" in
        start | check) ;;
        *) die "Usage: devbox isolation-poc [check]" ;;
    esac
    configure_isolation_poc_paths
    load_isolation_poc_config
    check_host_platform
    prepare_isolation_poc_docker_config
    check_isolation_poc_dependencies
    check_isolation_poc_ownership

    if [ "$action" = check ]; then
        [ "$(isolation_poc_state)" = Running ] ||
            die "Isolation POC VM is not running; run 'devbox isolation-poc'"
    else
        render_isolation_poc_config
        state="$(isolation_poc_state)"
        case "$state" in
            Running) ;;
            '' | Stopped)
                isolation_poc_colima start "$ISOLATION_POC_PROFILE" \
                    --activate=false \
                    --ssh-config=false \
                    --ssh-agent=false \
                    --port-forwarder=none \
                    --save-config=false
                ;;
            *) die "Isolation POC VM is in state '$state'; wait for it to settle and retry" ;;
        esac
    fi

    verify_isolation_poc_config
    verify_isolation_poc_no_user_network || strict_network=false
    verify_isolation_poc_guest
    [ "$strict_network" = true ] ||
        die "Isolation POC did not meet the strict no-user-mode-networking precondition"
    log "Isolation POC checks passed. This verifies only the configured preconditions, not external firewall enforcement."
}
