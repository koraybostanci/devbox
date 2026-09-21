#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

validation_root="$(mktemp -d)"
trap 'command rm -rf "$validation_root"' EXIT

# Make the Homebrew Docker Compose plugin discoverable (macOS CI layout).
if command -v brew >/dev/null 2>&1; then
    compose_plugin_dir="$(brew --prefix)/lib/docker/cli-plugins"
    if [ -d "$compose_plugin_dir" ]; then
        export DOCKER_CONFIG="$validation_root/docker"
        mkdir -p "$DOCKER_CONFIG"
        printf '{"cliPluginsExtraDirs":["%s"]}\n' "$compose_plugin_dir" \
            >"$DOCKER_CONFIG/config.json"
    fi
fi

# --- shell syntax -----------------------------------------------------------
shell_files=()
while IFS= read -r shell_file; do
    shell_files+=("$shell_file")
done < <(find . \( -type f -name '*.sh' -o -path './devbox' \) | sort)
bash -n "${shell_files[@]}"

# --- the legacy mounted profile is gone ------------------------------------
for legacy_path in \
    lib/colima.sh lib/containers.sh lib/doctor.sh lib/guest.sh \
    lib/isolation-poc.sh colima.yaml provision/config/containers; do
    [ ! -e "$legacy_path" ] || fail "legacy path still present: $legacy_path"
done
if grep -q 'migrate' lib/v2.sh; then
    fail "obsolete legacy migration command still present"
fi

# --- .env.example -----------------------------------------------------------
grep -q '^export GIT_NAME=' .env.example
grep -q '^export GIT_EMAIL=' .env.example
if grep -q 'POSTGRES_PASSWORD' .env.example; then
    fail ".env.example must not carry POSTGRES_PASSWORD (it is generated in the guest)"
fi

# --- launcher ---------------------------------------------------------------
[ -x devbox ]
"$ROOT/devbox" help | grep -q 'Usage: devbox <command>'
if "$ROOT/devbox" bogus >/dev/null 2>&1; then
    fail "unknown command was accepted"
fi

# --- v2 must not need host jq or yq ----------------------------------------
if grep -nE '(^|[^[:alnum:]_])(jq|yq)([^[:alnum:]_]|$)' lib/v2.sh lib/config.sh; then
    fail "v2 must not require host jq or yq"
fi

# --- prohibited provisioning patterns --------------------------------------
if grep -R -E -- \
    '^[[:space:]]*eval[[:space:]]|curl[^|]*\|[[:space:]]*(ba)?sh|SSH_AUTH_SOCK=/run/host-services|chmod 0777|rm -rf "\$HOME/(projects|data)|/etc/environment|readlink -f' \
    devbox lib provision/scripts provision/config/zsh; then
    fail "prohibited provisioning pattern found"
fi

# --- v2 remote payloads must be valid Bash ---------------------------------
v2_home="$validation_root/home"
mkdir -p "$v2_home"
payloads_dir="$validation_root/payloads"
mkdir -p "$payloads_dir"
HOME="$v2_home" V2_REMOTE_PAYLOADS_DIR="$payloads_dir" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_host_ssh_user() { printf "admin\n"; }
    v2_host_public_key() {
        printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test\n"
    }
    v2_sshd_authorized_keys_config() { printf "AuthorizedKeysFile /etc/ssh/authorized_keys/%%u\n"; }
    capture_payloads() {
        local i j target
        for ((i = 1; i <= $#; i++)); do
            if [ "${!i}" = "-c" ]; then
                j=$((i + 1))
                target="$(mktemp "$V2_REMOTE_PAYLOADS_DIR/payload.XXXXXX")"
                printf "%s" "${!j}" >"$target"
            fi
        done
        return 0
    }
    v2_admin_guest() { capture_payloads "$@"; }
    v2_as_guest() { capture_payloads "$@"; }
    authorize_v2_host_key || true
    validate_v2_guest_identity || true
    validate_v2_guest_privileges || true
    remove_v2_managed_guest_ssh_authorization || true
' || fail "v2 remote payload capture failed"
payload_count=0
for payload in "$payloads_dir"/payload.*; do
    [ -f "$payload" ] || continue
    payload_count=$((payload_count + 1))
    bash -n "$payload" || fail "a v2 remote payload is not valid Bash: $payload"
done
[ "$payload_count" -ge 3 ] || fail "expected at least 3 v2 remote payloads, captured $payload_count"

# --- v2 privilege parser behavior ------------------------------------------
v2_privileges_remote="$validation_root/privileges.sh"
HOME="$v2_home" V2_REMOTE="$v2_privileges_remote" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() {
        [ "$1" = sudo ] && [ "$2" = bash ] && [ "$3" = -c ] || exit 1
        printf "%s" "$4" >"$V2_REMOTE"
    }
    validate_v2_guest_privileges
' || fail "v2 privilege parser capture failed"
bash -n "$v2_privileges_remote" || fail "v2 privilege parser is not valid Bash"

HOME="$v2_home" V2_REMOTE="$v2_privileges_remote" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() { "$@"; }
    sudo() {
        case "$1" in
            bash) shift; command bash "$@" ;;
            -n)
                [ "$2" = -l ] && [ "$3" = -U ] && [ "$4" = devbox ] || return 1
                printf "User devbox is not allowed to run sudo on guest.\n"
                return 1
                ;;
            -u)
                [ "$2" = devbox ] && [ "$3" = -- ] || return 1
                return 1
                ;;
            *) return 1 ;;
        esac
    }
    export -f sudo
    validate_v2_guest_privileges
' || fail "v2 privilege parser rejected the no-sudo guest output"
HOME="$v2_home" V2_REMOTE="$v2_privileges_remote" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() { "$@"; }
    sudo() {
        case "$1" in
            bash) shift; command bash "$@" ;;
            -n)
                [ "$2" = -l ] && [ "$3" = -U ] && [ "$4" = devbox ] || return 1
                printf "User devbox may run the following commands on guest:\n    (root) NOPASSWD: ALL\n"
                ;;
            -u) return 1 ;;
            *) return 1 ;;
        esac
    }
    export -f sudo
    ! validate_v2_guest_privileges
' || fail "v2 privilege parser accepted sudo privileges"

# --- v2 identity validator --------------------------------------------------
v2_identity_script="$validation_root/identity.sh"
HOME="$v2_home" V2_IDENTITY="$v2_identity_script" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() {
        [ "$1" = bash ] && [ "$2" = -c ] || exit 1
        printf "%s" "$3" >"$V2_IDENTITY"
    }
    validate_v2_guest_identity
' || true
bash -n "$v2_identity_script" || fail "v2 identity validator is not valid Bash"

# --- managed services -------------------------------------------------------
if docker compose version >/dev/null 2>&1; then
    POSTGRES_PASSWORD=test POSTGRES_USER=test POSTGRES_DB=test POSTGRES_PORT=15432 \
        VALKEY_PASSWORD=test VALKEY_PORT=16379 \
        docker compose -f provision/config/services/compose.yaml config -q ||
        fail "v2 service definition is invalid"
    grep -q '"127.0.0.1:' provision/config/services/compose.yaml ||
        fail "v2 services must publish to loopback only"
else
    printf 'WARN: docker compose is unavailable; skipping service-definition validation\n' >&2
fi

# --- release tooling --------------------------------------------------------
release_root="$validation_root/release"
mkdir -p "$release_root/home"
"$ROOT/scripts/release.sh" build 0.0.0 >/dev/null || fail "release build failed"
release_archive="$ROOT/dist/devbox-0.0.0.tar.gz"
"$ROOT/scripts/release.sh" verify "$release_archive" >/dev/null || fail "release verification failed"
HOME="$release_root/home" "$ROOT/scripts/release.sh" install "$release_archive" >/dev/null ||
    fail "release installation failed"
[ -x "$release_root/home/.local/share/devbox/releases/0.0.0/devbox" ] ||
    fail "release launcher was not installed"
[ -L "$release_root/home/.local/share/devbox/current" ] || fail "release was not activated"

release_key="$release_root/signing-key.pem"
openssl ecparam -name prime256v1 -genkey -noout -out "$release_key" || fail "could not generate test key"
openssl ec -in "$release_key" -pubout -out "$release_root/signing-key.pub.pem" 2>/dev/null
"$ROOT/scripts/release.sh" sign "$release_archive" --key "$release_key" >/dev/null || fail "release signing failed"
DEVBOX_RELEASE_PUBKEY="$release_root/signing-key.pub.pem" \
    "$ROOT/scripts/release.sh" verify "$release_archive" >/dev/null || fail "signed release verification failed"
printf 'tampered\n' >"$ROOT/dist/SHA256SUMS.sig"
if DEVBOX_RELEASE_PUBKEY="$release_root/signing-key.pub.pem" \
    "$ROOT/scripts/release.sh" verify "$release_archive" >/dev/null 2>&1; then
    fail "tampered release signature was accepted"
fi
command rm -f "$ROOT/dist/SHA256SUMS.sig"

printf 'All checks passed.\n'
