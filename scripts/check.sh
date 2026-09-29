#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export ROOT
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

validation_root="$(mktemp -d)"
trap 'command rm -rf "$validation_root"' EXIT

# Make the Homebrew Docker Compose plugin discoverable (macOS layout).
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
done < <(find . \( -type f -name '*.sh' -o -path ./devbox -o -path ./provision/config/guest/devbox \) -print | sort)
bash -n "${shell_files[@]}"

# The host runs macOS /bin/bash 3.2; keep bash 4+ constructs out of host code.
if grep -nE 'mapfile|readarray|coproc|(declare|local|typeset) -[gAn]|\$\{[A-Za-z_]+(,,|\^\^|@[QEPAa])|;;&|;&|\[\[ -v ' devbox lib/*.sh; then
    fail "host scripts must stay compatible with bash 3.2"
fi

# --- launcher ---------------------------------------------------------------
[ -x devbox ] || fail "devbox launcher must be executable"
"$ROOT/devbox" help | grep -q 'Usage: devbox <command>' ||
    fail "devbox help must print 'Usage: devbox <command>'"
if "$ROOT/devbox" bogus >/dev/null 2>&1; then
    fail "unknown command was accepted"
fi
for bad_args in 'services bogus' 'stop --bogus' 'stop --force extra'; do
    # shellcheck disable=SC2086
    if bad_output="$(PATH=/usr/bin:/bin "$ROOT/devbox" $bad_args 2>&1)" ||
        [[ "$bad_output" != *Usage:* ]]; then
        fail "'devbox $bad_args' was not rejected with a usage message"
    fi
done
# Commands that need no VM work without Colima installed.
[ "$(HOME="$validation_root/no-colima" PATH=/usr/bin:/bin "$ROOT/devbox" status)" = 'devbox: Not created' ] ||
    fail "devbox status required Colima for a VM that does not exist"
launcher_version="$("$ROOT/devbox" version)" || fail "devbox version failed"
[ "$launcher_version" = "$(cat "$ROOT/VERSION")" ] ||
    fail "devbox version printed '$launcher_version' instead of the VERSION contents"

# --- guest companion --------------------------------------------------------
companion_home="$validation_root/guest-home"
mkdir -p "$companion_home/.config/devbox"
printf 'export POSTGRES_USER=dev\nexport POSTGRES_DB=dev\nexport POSTGRES_PORT=15432\n' \
    >"$companion_home/.config/devbox/config"
companion() {
    HOME="$1" PATH="$2" "$(command -v bash)" provision/config/guest/devbox "${@:3}"
}
companion_status="$(companion "$companion_home" /nonexistent auth status)" ||
    fail "companion 'auth status' failed"
printf '%s\n' "$companion_status" | grep -q '^github: not configured$' ||
    fail "companion did not report github as unconfigured"
printf '%s\n' "$companion_status" | grep -q '^databricks: not configured$' ||
    fail "companion did not report databricks as unconfigured"

# `gh auth status` exits 0 for an invalid token, so a stubbed failure must not
# be reported as authenticated.
stub_bin="$validation_root/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/gh" <<'EOF'
#!/bin/bash
[ "$1" = auth ] && [ "$2" = status ] && printf 'X Failed to log in to github.com\n'
exit 0
EOF
chmod +x "$stub_bin/gh"
[[ "$(companion "$companion_home" "$stub_bin:/usr/bin:/bin" auth status)" == *'github: not configured'* ]] ||
    fail "companion reported an invalid GitHub token as authenticated"

# ~/.claude.json is onboarding metadata that exists before login; only the
# credentials file means signed in.
claude_home="$validation_root/claude-home"
mkdir -p "$claude_home/.claude"
printf '{}\n' >"$claude_home/.claude.json"
[[ "$(companion "$claude_home" /nonexistent auth status)" == *'claude: not configured'* ]] ||
    fail "companion reported Claude as configured from onboarding metadata"
printf '{}\n' >"$claude_home/.claude/.credentials.json"
[[ "$(companion "$claude_home" /nonexistent auth status)" == *$'\nclaude: configured\n'* ]] ||
    fail "companion did not report Claude credentials as configured"

[[ "$(companion "$companion_home" /usr/bin:/bin db info)" == *'postgres port: 15432'* ]] ||
    fail "companion did not report PostgreSQL settings"

# --- devbox must not need host jq or yq ----------------------------------------
for scan_target in lib/devbox.sh lib/config.sh devbox; do
    [ -f "$scan_target" ] || fail "scan target is missing: $scan_target"
done
if grep -nE '(^|[^[:alnum:]_])(jq|yq)([^[:alnum:]_]|$)' lib/devbox.sh lib/config.sh; then
    fail "devbox must not require host jq or yq"
fi

# --- provisioning version pins ----------------------------------------------
# Every downloaded installer or artifact must carry a SHA-256 pin; a malformed
# value would disable checksum verification inside the guest.
for pin in GO_SHA256 NVM_INSTALL_SHA256 PYENV_INSTALLER_SHA256 UV_INSTALL_SHA256 \
    OPENCODE_SHA256 DATABRICKS_INSTALL_SHA256 YQ_SHA256 OH_MY_ZSH_INSTALL_SHA256; do
    pin_value="$(awk -F= -v key="$pin" '$1 == key { gsub(/"/, "", $2); print $2 }' provision/versions.env)"
    [[ "$pin_value" =~ ^[0-9a-f]{64}$ ]] ||
        fail "provision/versions.env: $pin must be a SHA-256"
done

# --- guest privilege boundaries ----------------------------------------------
# verify.sh runs as the unprivileged devbox user and cannot traverse the
# root-only services directory; file-level checks belong in root scripts.
if grep -q '/var/lib/devbox/services/' provision/scripts/verify.sh; then
    fail "verify.sh must not inspect files inside the root-only services directory"
fi
if grep -R -nE \
    'kernel\.apparmor_restrict_unprivileged_userns[[:space:]]*=[[:space:]]*0|sysctl[[:space:]].*apparmor_restrict_unprivileged_userns' \
    provision/scripts; then
    fail "RootlessKit provisioning must not disable AppArmor's user-namespace restriction"
fi

# User Docker and Puppeteer defaults must be isolated from the root-managed
# services daemon and project-specific browser download settings.
rootless_zshenv=provision/config/zsh/zshenv
grep -qF 'export PUPPETEER_EXECUTABLE_PATH="${PUPPETEER_EXECUTABLE_PATH:-/snap/bin/chromium}"' \
    "$rootless_zshenv" ||
    fail "zsh startup must default Puppeteer to Chromium without replacing an existing path"
grep -qF 'export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"' "$rootless_zshenv" ||
    fail "zsh startup must route Docker to the per-user socket"
grep -qF 'unset DOCKER_CONTEXT' "$rootless_zshenv" ||
    fail "zsh startup must prevent an inherited Docker context from overriding the rootless socket"
if grep -R -nE '^[[:space:]]*(export[[:space:]]+)?PUPPETEER_SKIP_DOWNLOAD=' provision/config/zsh; then
    fail "PUPPETEER_SKIP_DOWNLOAD must remain project-scoped, not global"
fi
grep -qF 'snap install chromium --channel=stable' provision/scripts/system.sh ||
    fail "system provisioning must install actual Ubuntu Chromium from the stable snap"
grep -qF 'devbox_configure_rootless_docker' provision/scripts/tools.sh ||
    fail "the unprivileged tools phase must configure rootless Docker"
grep -qF 'cd "$package_root" && node install.cjs' provision/scripts/lib/apps.sh ||
    fail "Claude Code provisioning must run its installer script"
grep -qE '^[[:space:]]+vim$' provision/scripts/system.sh ||
    fail "system provisioning must install the Vim command-line editor"
grep -qF 'export EDITOR=vim' provision/config/zsh/zshrc ||
    fail "the guest shell must default to Vim for command-line editing"
grep -qE '^[[:space:]]+apparmor$' provision/scripts/system.sh ||
    fail "system provisioning must install Ubuntu's AppArmor package"
grep -qF 'version **29.5 or newer**' docs/architecture.md ||
    fail "the rootless host-network Engine version requirement must be documented"
grep -qF 'read-only `/:/host:ro,rslave` mount' docs/architecture.md ||
    fail "Finsights' read-only guest-root mount semantics must be documented"
grep -qF 'node exporter' docs/architecture.md || grep -qF 'Node Exporter' docs/architecture.md ||
    fail "Finsights Node Exporter least-privilege guidance must be documented"
grep -qF 'depend on the Engine server version and rootless runtime' docs/architecture.md ||
    fail "rootless host namespace behavior must be qualified"
grep -qF 'does not elevate access' docs/architecture.md ||
    fail "rootless guest-root bind-mount permission limits must be documented"
grep -qF 'VM smoke test against the actual rootless daemon is required' docs/architecture.md ||
    fail "actual guest metrics must require a rootless VM smoke test"
for readiness_check in \
    devbox_rootless_context_is_selected devbox_rootless_docker_is_ready \
    devbox_rootful_docker_is_denied chromium_launches_headlessly \
    devbox_rootlesskit_apparmor_profile_is_ready; do
    grep -q "$readiness_check" provision/scripts/verify.sh ||
        fail "guest readiness check is missing: $readiness_check"
done
if grep -R -nE \
    'kernel\.apparmor_restrict_unprivileged_userns[[:space:]]*=[[:space:]]*0|sysctl[[:space:]].*apparmor_restrict_unprivileged_userns' \
    provision/scripts; then
    fail "RootlessKit provisioning must not disable AppArmor's user-namespace restriction"
fi

# Exercise Ubuntu's packaged RootlessKit profile loading without a VM or a
# system AppArmor policy: only an enabled restriction should trigger the load.
apparmor_unit_root="$validation_root/apparmor-unit"
mkdir -p "$apparmor_unit_root/usr/bin" "$apparmor_unit_root/usr/local/bin"
apparmor_setting="$apparmor_unit_root/restrict-userns"
apparmor_profile="$apparmor_unit_root/rootlesskit-profile"
apparmor_profiles="$apparmor_unit_root/loaded-profiles"
apparmor_rootlesskit="$apparmor_unit_root/usr/bin/rootlesskit"
apparmor_shadow="$apparmor_unit_root/usr/local/bin/rootlesskit"
apparmor_error="$apparmor_unit_root/error"
cat >"$apparmor_profile" <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>

profile rootlesskit /usr/bin/rootlesskit flags=(unconfined) {
  userns,
  include if exists <local/rootlesskit>
}
PROFILE
printf '#!/bin/sh\nexit 0\n' >"$apparmor_rootlesskit"
printf '#!/bin/sh\nexit 0\n' >"$apparmor_shadow"
chmod 755 "$apparmor_rootlesskit" "$apparmor_shadow"
: >"$apparmor_profiles"
(
    source "$ROOT/provision/scripts/lib/docker.sh"
    package_query_count=0
    parser_call_count=0
    dpkg-query() {
        package_query_count=$((package_query_count + 1))
        case "$1" in
            -W) [ "$3" = apparmor ] && printf 'installed\n' ;;
            -S) printf 'apparmor: %s\n' "$2" ;;
            *) return 1 ;;
        esac
    }
    apparmor_parser() {
        [ "$1" = -r ] && [ "$2" = "$apparmor_profile" ] || return 1
        parser_call_count=$((parser_call_count + 1))
        printf 'rootlesskit (unconfined)\n' >>"$apparmor_profiles"
    }

    printf '0\n' >"$apparmor_setting"
    devbox_prepare_rootlesskit_apparmor_profile \
        "$apparmor_setting" "$apparmor_profile" "$apparmor_profiles" || exit 1
    [ "$package_query_count" -eq 0 ] && [ "$parser_call_count" -eq 0 ] &&
        [ ! -s "$apparmor_profiles" ] || exit 1

    printf '1\n' >"$apparmor_setting"
    devbox_prepare_rootlesskit_apparmor_profile \
        "$apparmor_setting" "$apparmor_profile" "$apparmor_profiles" || exit 1
    [ "$parser_call_count" -eq 1 ] || exit 1
    grep -Fqx 'rootlesskit (unconfined)' "$apparmor_profiles" || exit 1
    devbox_rootlesskit_apparmor_profile_is_ready \
        "$apparmor_setting" "$apparmor_profile" "$apparmor_profiles" \
        "$apparmor_rootlesskit" "$apparmor_rootlesskit" || exit 1
    if [ "$(id -u)" -ne 0 ]; then
        devbox_rootlesskit_apparmor_profile_is_ready \
            "$apparmor_setting" "$apparmor_profile" "$apparmor_unit_root/unreadable-profiles" \
            "$apparmor_rootlesskit" "$apparmor_rootlesskit" || exit 1
    fi
    devbox_rootlesskit_path_is_profiled "$apparmor_shadow" "$apparmor_rootlesskit" && exit 1

    mv "$apparmor_profile" "$apparmor_profile.saved"
    if devbox_prepare_rootlesskit_apparmor_profile \
        "$apparmor_setting" "$apparmor_profile" "$apparmor_profiles" 2>"$apparmor_error"; then
        exit 1
    fi
    grep -q "Ubuntu's packaged RootlessKit AppArmor profile is unavailable" \
        "$apparmor_error" || exit 1
) || fail "RootlessKit AppArmor profile checks failed"

# The managed .zshenv block precedes, and preserves, existing user settings.
zshenv_unit_root="$validation_root/zshenv-unit"
zshenv_unit_home="$zshenv_unit_root/home"
zshenv_stub_bin="$zshenv_unit_root/bin"
mkdir -p "$zshenv_unit_home" "$zshenv_stub_bin"
cat >"$zshenv_unit_home/.zshenv" <<'EOF'
# Existing user settings must survive provisioning and remain later overrides.
export DEVBOX_ZSHENV_USER_SETTING=preserved
export DOCKER_HOST=unix:///tmp/user-selected-docker.sock
export PUPPETEER_EXECUTABLE_PATH=/project/browser
EOF
chmod 600 "$zshenv_unit_home/.zshenv"
cp "$zshenv_unit_home/.zshenv" "$zshenv_unit_root/.zshenv-original"
cat >"$zshenv_stub_bin/zsh" <<'EOF'
#!/bin/bash
[ "$1" = -n ] && [ -f "$2" ]
EOF
chmod +x "$zshenv_stub_bin/zsh"
configure_shell_unit() {
    HOME="$zshenv_unit_home" DEVBOX_PROVISION_ROOT="$ROOT/provision" \
        PATH="$zshenv_stub_bin:/usr/bin:/bin" /bin/bash -c '
        set -Eeuo pipefail
        source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"
        source "$DEVBOX_PROVISION_ROOT/scripts/lib/configure.sh"
        configure_shell
    '
}
configure_shell_unit || fail "shell configuration failed with a pre-existing .zshenv"
{
    printf '%s\n' '# >>> devbox managed zshenv >>>'
    cat "$ROOT/$rootless_zshenv"
    printf '%s\n' '# <<< devbox managed zshenv <<<'
    cat "$zshenv_unit_root/.zshenv-original"
} >"$zshenv_unit_root/.zshenv-expected"
cmp -s "$zshenv_unit_root/.zshenv-expected" "$zshenv_unit_home/.zshenv" ||
    fail "configure_shell changed or misplaced existing .zshenv content"
[ "$(file_mode "$zshenv_unit_home/.zshenv")" = 600 ] ||
    fail "configure_shell changed the existing .zshenv permissions"
configure_shell_unit || fail "repeat shell configuration failed"
cmp -s "$zshenv_unit_root/.zshenv-expected" "$zshenv_unit_home/.zshenv" ||
    fail "repeat shell configuration changed the managed .zshenv"
printf '%s\n' '# >>> devbox managed zshenv >>>' >>"$zshenv_unit_home/.zshenv"
if configure_shell_unit 2>/dev/null; then
    fail "configure_shell accepted a malformed managed block"
fi

if command -v zsh >/dev/null 2>&1; then
    [ "$(env -u PUPPETEER_EXECUTABLE_PATH zsh -f -c 'source "$1"; printenv PUPPETEER_EXECUTABLE_PATH' \
        _ "$ROOT/$rootless_zshenv")" = /snap/bin/chromium ] ||
        fail "an unset Puppeteer path did not default to /snap/bin/chromium"
    shell_config_output="$(env DOCKER_HOST=unix:///tmp/inherited.sock DOCKER_CONTEXT=inherited \
        PUPPETEER_EXECUTABLE_PATH=/project/browser PUPPETEER_SKIP_DOWNLOAD=true zsh -f -c '
        source "$1"
        printf "%s\n%s\n%s\n%s\n" "$DOCKER_HOST" "${DOCKER_CONTEXT-<unset>}" \
            "${PUPPETEER_EXECUTABLE_PATH-<unset>}" "${PUPPETEER_SKIP_DOWNLOAD-<unset>}"
    ' _ "$ROOT/$rootless_zshenv")" || fail "zsh startup config could not be loaded"
    [ "$shell_config_output" = "unix:///run/user/$(id -u)/docker.sock
<unset>
/project/browser
true" ] || fail "zsh startup changed a project Puppeteer setting or missed the rootless Docker default"
    cp "$zshenv_unit_root/.zshenv-expected" "$zshenv_unit_home/.zshenv"
    merged_zshenv_output="$(env -u PUPPETEER_EXECUTABLE_PATH zsh -f -c '
        source "$1"
        printf "%s\n%s\n%s\n" "$DEVBOX_ZSHENV_USER_SETTING" "$DOCKER_HOST" "$PUPPETEER_EXECUTABLE_PATH"
    ' _ "$zshenv_unit_home/.zshenv")" || fail "managed .zshenv could not be sourced by zsh"
    [ "$merged_zshenv_output" = "preserved
unix:///tmp/user-selected-docker.sock
/project/browser" ] || fail "managed .zshenv did not preserve effective user and project settings"
fi

# --- managed services use the rootful daemon only ---------------------------
services_stub_bin="$validation_root/services-stub-bin"
services_capture="$validation_root/services-capture"
mkdir -p "$services_stub_bin"
cat >"$services_stub_bin/docker" <<'EOF'
#!/bin/bash
{
    printf 'host=%s\n' "${DOCKER_HOST:-}"
    printf 'context=%s\n' "${DOCKER_CONTEXT-<unset>}"
    printf 'arg=%s\n' "$@"
} >"$SERVICE_CAPTURE"
EOF
chmod +x "$services_stub_bin/docker"
PATH="$services_stub_bin:/usr/bin:/bin" SERVICE_CAPTURE="$services_capture" \
    DOCKER_HOST=unix:///tmp/inherited-rootless.sock DOCKER_CONTEXT=inherited \
    /bin/bash -c '
        set -Eeuo pipefail
        source "$1"
        devbox_services_docker compose ps
    ' _ "$ROOT/provision/scripts/services.sh" || fail "services Docker helper failed"
grep -qx 'host=unix:///var/run/docker.sock' "$services_capture" ||
    fail "devbox services did not force the rootful Docker socket"
grep -qx 'context=<unset>' "$services_capture" ||
    fail "devbox services inherited a Docker context"
grep -qx 'arg=compose' "$services_capture" && grep -qx 'arg=ps' "$services_capture" ||
    fail "devbox services did not route its Compose command through Docker"

# --- focused guest state and sync checks -----------------------------------
source "$ROOT/scripts/check-guest-state.sh"

# --- prohibited provisioning patterns --------------------------------------
# Fail closed on a missing scan target: grep -R exits 2 for a missing path,
# which would silently satisfy the non-match test below.
for scan_target in \
    devbox lib provision/scripts provision/config/zsh provision/config/guest; do
    [ -e "$scan_target" ] || fail "scan target is missing: $scan_target"
done
if grep -R -E -- \
    '^[[:space:]]*eval[[:space:]]|curl[^|]*\|[[:space:]]*(ba)?sh|SSH_AUTH_SOCK=/run/host-services|chmod 0777|rm -rf "\$HOME/(projects|data)|/etc/environment|readlink -f' \
    devbox lib provision/scripts provision/config/zsh provision/config/guest; then
    fail "prohibited provisioning pattern found"
fi

# --- devbox remote payloads -------------------------------------------------
# Inline bash -c payloads sent to the guest must be valid Bash.
payloads_dir="$validation_root/payloads"
mkdir -p "$payloads_dir"
: >"$validation_root/payload.tar"
DEVBOX_REMOTE_PAYLOADS_DIR="$payloads_dir" DEVBOX_DIR="$ROOT" \
    DEVBOX_PAYLOAD_ARCHIVE="$validation_root/payload.tar" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    devbox_admin_guest() {
        local i j
        for ((i = 1; i <= $#; i++)); do
            if [ "${!i}" = "-c" ]; then
                j=$((i + 1))
                printf "%s" "${!j}" >"$(mktemp "$DEVBOX_REMOTE_PAYLOADS_DIR/payload.XXXXXX")"
            fi
        done
    }
    digest="$(printf "0%.0s" {1..64})"
    stream_devbox_bundle "$digest" "$DEVBOX_PAYLOAD_ARCHIVE"
    devbox_guest_bundle_is_valid "$digest"
' || fail "devbox remote payload capture failed"
payload_count=0
for payload in "$payloads_dir"/payload.*; do
    bash -n "$payload" || fail "a devbox remote payload is not valid Bash: $payload"
    payload_count=$((payload_count + 1))
done
[ "$payload_count" -eq 2 ] || fail "expected 2 devbox remote payloads, captured $payload_count"

# The guest must hash the bundle exactly as the host does.
if command -v shasum >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
    host_digest="$(DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/devbox.sh"
        devbox_bundle_digest "$ROOT/provision"
    ')" || fail "host bundle digest failed"
    guest_digest="$(/bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/devbox.sh"
        eval "$DEVBOX_GUEST_BUNDLE_DIGEST"
        bundle_digest "$ROOT/provision"
    ')" || fail "guest bundle digest failed"
    [[ "$host_digest" =~ ^[0-9a-f]{64}$ ]] && [ "$host_digest" = "$guest_digest" ] ||
        fail "host and guest bundle digests differ"
else
    printf 'WARN: shasum or sha256sum is unavailable; skipping bundle digest parity\n' >&2
fi

# --- devbox SSH config rendering and managed alias ---------------------------
ssh_unit_root="$validation_root/ssh-unit"
mkdir -p "$ssh_unit_root/home/.ssh" "$ssh_unit_root/ok-bin" "$ssh_unit_root/fail-bin"
printf '#!/bin/bash\nexit 0\n' >"$ssh_unit_root/ok-bin/ssh"
printf '#!/bin/bash\nexit 1\n' >"$ssh_unit_root/fail-bin/ssh"
chmod +x "$ssh_unit_root/ok-bin/ssh" "$ssh_unit_root/fail-bin/ssh"
cat >"$ssh_unit_root/colima.conf" <<'CONFIG'
Host colima-devbox
  HostName 127.0.0.1
  User lima
  Port 51234
  IdentityFile /tmp/devbox-key
  ControlMaster auto
  ForwardAgent yes
CONFIG
printf 'Include ~/.ssh/devbox.conf\nHost other\n  HostName other.example.com\n' \
    >"$ssh_unit_root/home/.ssh/config"
cp "$ssh_unit_root/home/.ssh/config" "$ssh_unit_root/config-before"
ssh_unit() {
    HOME="$ssh_unit_root/home" PATH="$1:/usr/bin:/bin" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/devbox.sh"
        "$@"
    ' _ "${@:2}"
}
managed="$ssh_unit_root/home/.ssh/devbox.conf"
ssh_unit "$ssh_unit_root/ok-bin" write_devbox_ssh_config "$ssh_unit_root/colima.conf" ||
    fail "write_devbox_ssh_config failed"
for line in 'Host devbox' '  User devbox' '  IdentitiesOnly yes' '  ForwardAgent no' \
    '  HostName 127.0.0.1' '  Port 51234' '  IdentityFile /tmp/devbox-key'; do
    grep -qxF "$line" "$managed" || fail "managed SSH block lacks '$line'"
done
if grep -qE 'User lima|ForwardAgent yes|ControlMaster' "$managed"; then
    fail "managed SSH block kept an overridden option"
fi
[ "$(file_mode "$managed")" = 600 ] || fail "managed SSH file has the wrong mode"
cmp -s "$ssh_unit_root/home/.ssh/config" "$ssh_unit_root/config-before" ||
    fail "write_devbox_ssh_config modified the user's SSH config"
cp "$managed" "$ssh_unit_root/managed-before"
if ssh_unit "$ssh_unit_root/fail-bin" write_devbox_ssh_config "$ssh_unit_root/colima.conf" 2>/dev/null; then
    fail "write_devbox_ssh_config accepted an unreachable alias"
fi
cmp -s "$managed" "$ssh_unit_root/managed-before" ||
    fail "a failed SSH refresh changed the existing managed file"
[ -z "$(find "$ssh_unit_root/home/.ssh" -name '.devbox.conf.*')" ] ||
    fail "a failed SSH refresh left a staging file behind"
ssh_unit "$ssh_unit_root/ok-bin" remove_devbox_ssh_config || fail "remove_devbox_ssh_config failed"
[ ! -e "$managed" ] || fail "managed SSH file was not removed"
cmp -s "$ssh_unit_root/home/.ssh/config" "$ssh_unit_root/config-before" ||
    fail "SSH cleanup modified the user's SSH config"

printf 'key\n' >"$ssh_unit_root/identity-key"
printf 'Host colima-devbox\n  IdentityFile "%s"\n' "$ssh_unit_root/identity-key" >"$ssh_unit_root/lima.conf"
[ "$(ssh_unit /usr/bin devbox_identity_file "$ssh_unit_root/lima.conf")" = "$ssh_unit_root/identity-key" ] ||
    fail "devbox_identity_file did not read the quoted identity file"
mkdir -p "$ssh_unit_root/links"
printf 'target\n' >"$ssh_unit_root/links/real"
ln -s real "$ssh_unit_root/links/one"
ln -s one "$ssh_unit_root/links/two"
[ "$(resolve_symlink_target "$ssh_unit_root/links/two")" = "$ssh_unit_root/links/real" ] ||
    fail "resolve_symlink_target did not follow a symlink chain"

# --- lifecycle lock ---------------------------------------------------------
# Lifecycle commands rely on the EXIT trap to release the lock, even on failure.
lock_dir="$validation_root/locks"
lock_status=0
lock_output="$(DEVBOX_LOCK_DIR="$lock_dir" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    acquire_lock lifecycle
    [ -f "$DEVBOX_LOCK_DIR/lifecycle/pid" ] || exit 3
    die "simulated failure"
' 2>&1)" || lock_status=$?
[ "$lock_status" = 1 ] && [[ "$lock_output" == *'simulated failure'* ]] ||
    fail "the lock test did not fail as expected ($lock_status: $lock_output)"
[ ! -e "$lock_dir/lifecycle" ] || fail "a failed lifecycle command left its lock behind"

# --- host configuration -------------------------------------------------------
[ "$(DEVBOX_ENV_FILE="$validation_root/override.env" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    devbox_env_file
')" = "$validation_root/override.env" ] || fail "DEVBOX_ENV_FILE did not override the configuration path"
[ "$(DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    devbox_env_file
')" = "$ROOT/.env" ] || fail "devbox_env_file did not return the checkout .env"

# Run load_env on a file holding a Git identity plus the given lines, and print
# one variable. ENV_CASE_MODE overrides the file mode.
env_case() {
    local file="$validation_root/case.env"

    printf 'export GIT_NAME="Case Test"\nexport GIT_EMAIL="case@example.com"\n%s\n' "$1" >"$file"
    chmod "${ENV_CASE_MODE:-600}" "$file"
    DEVBOX_ENV_FILE="$file" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        load_env
        printf "%s\n" "${!1}"
    ' _ "${2:-GIT_NAME}"
}
expect_env() {
    [ "$(env_case "$1" "$2")" = "$3" ] || fail "load_env did not load $2=$3 from '$1'"
}
reject_env() {
    if env_case "$1" >/dev/null 2>&1; then
        fail "load_env accepted '$1'"
    fi
}
source "$ROOT/scripts/check-host-config.sh"

# --- devbox init prompting and .env writing ---------------------------------
init_unit_root="$validation_root/init-unit"
mkdir -p "$init_unit_root/home"
init_env="$init_unit_root/config/devbox/env"
prompt_unit() {
    HOME="$init_unit_root/home" DEVBOX_ENV_FILE="$1" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        unset_env_keys
        prompt_env_values
        write_env_file "$DEVBOX_ENV_FILE"
    '
}
printf 'Devbox Test\ndevbox@example.com\n\n\n\n\n\n\n' | prompt_unit "$init_env" 2>/dev/null ||
    fail "devbox init prompting failed"
[ "$(file_mode "$init_env")" = 600 ] ||
    fail "devbox init wrote the configuration with the wrong mode"
grep -q '^export GIT_NAME="Devbox Test"$' "$init_env" ||
    fail "devbox init did not write the answered value"
grep -q '^export DEVBOX_CPU="4"$' "$init_env" ||
    fail "devbox init did not write the optional default"
grep -q '^# devbox configuration' "$init_env" ||
    fail "devbox init did not write the configuration header comment"
# Required and invalid values fail without a terminal instead of writing a
# partial file.
if printf '\n\n' | prompt_unit "$init_unit_root/missing.env" >/dev/null 2>&1; then
    fail "devbox init accepted empty required values"
fi
if printf 'Name\ne@x.com\ndev\ndev\n70000\n' | prompt_unit "$init_unit_root/bad-port.env" >/dev/null 2>&1; then
    fail "devbox init accepted an invalid port"
fi
[ ! -e "$init_unit_root/missing.env" ] && [ ! -e "$init_unit_root/bad-port.env" ] ||
    fail "devbox init wrote the configuration after a failed prompt"

# A symlinked configuration is updated through the link, not replaced.
symlink_root="$validation_root/env-symlink"
mkdir -p "$symlink_root/home" "$symlink_root/dotfiles"
printf 'export GIT_NAME="Old"\n' >"$symlink_root/dotfiles/env"
ln -s "$symlink_root/dotfiles/env" "$symlink_root/home/.env"
HOME="$symlink_root/home" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    GIT_NAME="New"; GIT_EMAIL="e@x.com"; POSTGRES_USER=dev; POSTGRES_DB=dev
    POSTGRES_PORT=15432; DEVBOX_CPU=4; DEVBOX_MEMORY=4; DEVBOX_DISK=60
    DEVBOX_USE_HOST_PROXY=false
    write_env_file "$HOME/.env"
' || fail "write_env_file failed for a symlinked configuration"
[ -L "$symlink_root/home/.env" ] || fail "write_env_file replaced a symlinked .env"
grep -q '^export GIT_NAME="New"$' "$symlink_root/dotfiles/env" ||
    fail "write_env_file did not update the symlink target"

# `devbox init` reads the existing file leniently and reports lines it drops.
warning_env="$validation_root/warning.env"
printf 'export GIT_NAME="X"\nexport POSTGRES_PASSWORD=secret\nnot an assignment\n' >"$warning_env"
warning_output="$(/bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    read_env_file "$1" lenient
    printf "GIT_NAME=%s\n" "$GIT_NAME"
' _ "$warning_env" 2>&1)" || fail "lenient configuration reading failed"
[[ "$warning_output" == *'removes unsupported variable POSTGRES_PASSWORD'* ]] ||
    fail "lenient configuration reading did not report the unsupported key"
[[ "$warning_output" == *'is not a KEY=value assignment'* ]] ||
    fail "lenient configuration reading did not report the malformed line"
[[ "$warning_output" == *'GIT_NAME=X'* ]] ||
    fail "lenient configuration reading did not keep the valid value"

# --- devbox CLI symlink -------------------------------------------------------
cli_unit_root="$validation_root/cli-unit"
mkdir -p "$cli_unit_root/home/bin"
HOME="$cli_unit_root/home" PATH="/usr/bin:/bin" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    install_cli "$ROOT/devbox"
    [ -L "$HOME/.local/bin/devbox" ]
    uninstall_cli "$ROOT/devbox"
' >/dev/null || fail "devbox CLI install/uninstall failed"
[ ! -e "$cli_unit_root/home/.local/bin/devbox" ] || fail "uninstall kept the devbox symlink"
ln -s "$ROOT/devbox" "$cli_unit_root/home/bin/devbox"
HOME="$cli_unit_root/home" PATH="$cli_unit_root/home/bin:/usr/bin:/bin" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    install_cli "$ROOT/devbox"
    uninstall_cli "$ROOT/devbox"
' >/dev/null || fail "devbox CLI did not reuse its existing symlink"
[ ! -e "$cli_unit_root/home/bin/devbox" ] || fail "uninstall kept the existing devbox symlink"
[ ! -e "$cli_unit_root/home/.local/bin/devbox" ] || fail "CLI migration created a second symlink"

# --- managed services -------------------------------------------------------
compose_command=()
if docker compose version >/dev/null 2>&1; then
    compose_command=(docker compose)
elif docker-compose version >/dev/null 2>&1; then
    compose_command=(docker-compose)
fi
if [ "${#compose_command[@]}" -gt 0 ]; then
    POSTGRES_PASSWORD=test POSTGRES_USER=test POSTGRES_DB=test POSTGRES_PORT=15432 \
        VALKEY_PASSWORD=test VALKEY_PORT=16379 \
        "${compose_command[@]}" -f provision/config/services/compose.yaml config -q ||
        fail "devbox service definition is invalid"
    grep -q '"127.0.0.1:' provision/config/services/compose.yaml ||
        fail "devbox services must publish to loopback only"
elif [ -n "${CI:-}" ]; then
    fail "docker compose is required in CI"
else
    printf 'WARN: docker compose is unavailable; skipping service-definition validation\n' >&2
fi

# --- devbox init against the checkout (macOS only) --------------------------
if [ "$(uname -s)" = "Darwin" ]; then
    init_root="$validation_root/init"
    init_env="$init_root/config/devbox/env"
    mkdir -p "$init_root/home"
    printf 'Devbox Test\ndevbox@example.com\n\n\n\n\n\n\n' |
        DEVBOX_ENV_FILE="$init_env" HOME="$init_root/home" PATH="/usr/bin:/bin" \
        "$ROOT/devbox" init >"$init_root/init.log" 2>&1 ||
        fail "devbox init did not complete with piped answers"
    grep -q '^export GIT_NAME="Devbox Test"$' "$init_env" ||
        fail "devbox init did not write the answered Git name"
    grep -q "Configuration: $init_env" "$init_root/init.log" ||
        fail "devbox init did not report the configuration location"
    # A repeat run with no input keeps the existing values as defaults.
    DEVBOX_ENV_FILE="$init_env" HOME="$init_root/home" PATH="/usr/bin:/bin" \
        "$ROOT/devbox" init </dev/null >/dev/null 2>&1 ||
        fail "repeat devbox init failed"
    grep -q '^export GIT_NAME="Devbox Test"$' "$init_env" ||
        fail "repeat devbox init changed existing values"
else
    printf 'WARN: devbox init smoke test requires macOS; skipping\n' >&2
fi

printf 'All checks passed.\n'
