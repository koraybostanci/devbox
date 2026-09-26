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
done < <(find . -path ./dist -prune -o \( -type f -name '*.sh' -o -path './devbox' \) -print | sort)
bash -n "${shell_files[@]}"

# --- .env.example is gone; `devbox init` prompts and writes .env -------------
if [ -e .env.example ]; then
    fail ".env.example must not exist; devbox init writes the configuration"
fi

# --- launcher ---------------------------------------------------------------
[ -x devbox ] || fail "devbox launcher must be executable"
"$ROOT/devbox" help | grep -q 'Usage: devbox <command>' ||
    fail "devbox help must print 'Usage: devbox <command>'"
if "$ROOT/devbox" bogus >/dev/null 2>&1; then
    fail "unknown command was accepted"
fi
if "$ROOT/devbox" services bogus >/dev/null 2>&1; then
    fail "an unknown services action was accepted"
fi
if "$ROOT/devbox" stop --bogus >/dev/null 2>&1; then
    fail "an unknown stop flag was accepted"
fi

# `devbox version` reports the trimmed VERSION file and needs no host checks.
launcher_version="$("$ROOT/devbox" version)" || fail "devbox version failed"
[ "$launcher_version" = "$(cat "$ROOT/VERSION")" ] ||
    fail "devbox version printed '$launcher_version' instead of the VERSION contents"

# --- guest companion --------------------------------------------------------
[ -f provision/config/guest/devbox ]
bash -n provision/config/guest/devbox
grep -q 'config/guest/devbox' provision/scripts/system.sh
grep -q 'devbox_guest_interactive' lib/devbox.sh
companion_home="$validation_root/guest-home"
mkdir -p "$companion_home/.config/devbox"
printf 'export POSTGRES_USER=dev\nexport POSTGRES_DB=dev\nexport POSTGRES_PORT=15432\n' \
    >"$companion_home/.config/devbox/config"
printf 'export POSTGRES_PASSWORD=test\nexport VALKEY_PASSWORD=test\n' \
    >"$companion_home/.config/devbox/secrets"
companion_status="$(HOME="$companion_home" PATH=/nonexistent "$(command -v bash)" \
    provision/config/guest/devbox auth status)" || fail "companion 'auth status' failed"
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
invalid_gh_status="$(HOME="$companion_home" PATH="$stub_bin:/usr/bin:/bin" \
    "$(command -v bash)" provision/config/guest/devbox auth status)" ||
    fail "companion 'auth status' failed with a stubbed gh"
printf '%s\n' "$invalid_gh_status" | grep -q '^github: not configured$' ||
    fail "companion reported an invalid GitHub token as authenticated"

# ~/.claude.json is onboarding metadata that exists before login; only the
# credentials file means signed in.
claude_home="$validation_root/claude-home"
mkdir -p "$claude_home"
printf '{}\n' >"$claude_home/.claude.json"
claude_status="$(HOME="$claude_home" PATH=/nonexistent "$(command -v bash)" \
    provision/config/guest/devbox auth status)" || fail "companion 'auth status' failed"
printf '%s\n' "$claude_status" | grep -q '^claude: not configured$' ||
    fail "companion reported Claude as configured from onboarding metadata"
mkdir -p "$claude_home/.claude"
printf '{}\n' >"$claude_home/.claude/.credentials.json"
claude_status="$(HOME="$claude_home" PATH=/nonexistent "$(command -v bash)" \
    provision/config/guest/devbox auth status)" || fail "companion 'auth status' failed"
printf '%s\n' "$claude_status" | grep -q '^claude: configured$' ||
    fail "companion did not report Claude credentials as configured"

companion_db="$(HOME="$companion_home" bash provision/config/guest/devbox db info)" ||
    fail "companion 'db info' failed"
printf '%s\n' "$companion_db" | grep -q 'postgres port: 15432' ||
    fail "companion did not report PostgreSQL settings"

# --- devbox must not need host jq or yq ----------------------------------------
# The scans below must fail closed when a target disappears: without these
# checks a missing file would make grep exit 2 and trip the wrong assertion.
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

# --- guest script privilege boundaries --------------------------------------
# verify.sh runs as the unprivileged devbox user. The services directory is
# root-owned mode 700, so verify.sh cannot traverse into it; file-level checks
# belong in the root-run scripts.
if grep -q '/var/lib/devbox/services/' provision/scripts/verify.sh; then
    fail "verify.sh must not inspect files inside the root-only services directory"
fi

# User Docker and Puppeteer defaults must be isolated from the root-managed
# services daemon and project-specific browser download settings.
rootless_zshenv=provision/config/zsh/zshenv
[ -f "$rootless_zshenv" ] || fail "rootless Docker/Chromium shell configuration is missing"
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
    devbox_rootlesskit_path_is_profiled "$apparmor_shadow" "$apparmor_rootlesskit" && exit 1

    mv "$apparmor_profile" "$apparmor_profile.saved"
    if devbox_prepare_rootlesskit_apparmor_profile \
        "$apparmor_setting" "$apparmor_profile" "$apparmor_profiles" 2>"$apparmor_error"; then
        exit 1
    fi
    grep -q "Ubuntu's packaged RootlessKit AppArmor profile is unavailable" \
        "$apparmor_error" || exit 1
) || fail "RootlessKit AppArmor profile checks failed"

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
ROOT="$ROOT" HOME="$zshenv_unit_home" DEVBOX_PROVISION_ROOT="$ROOT/provision" \
    PATH="$zshenv_stub_bin:/usr/bin:/bin" /bin/bash -c '
        set -Eeuo pipefail
        source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"
        source "$DEVBOX_PROVISION_ROOT/scripts/lib/configure.sh"
        configure_shell
    ' || fail "shell configuration failed with a pre-existing .zshenv"
{
    printf '%s\n' '# >>> devbox managed zshenv >>>'
    cat "$ROOT/$rootless_zshenv"
    printf '%s\n' '# <<< devbox managed zshenv <<<'
    cat "$zshenv_unit_root/.zshenv-original"
} >"$zshenv_unit_root/.zshenv-expected"
cmp -s "$zshenv_unit_root/.zshenv-expected" "$zshenv_unit_home/.zshenv" ||
    fail "configure_shell changed or misplaced existing .zshenv content"
grep -qF 'export DEVBOX_ZSHENV_USER_SETTING=preserved' "$zshenv_unit_home/.zshenv" ||
    fail "configure_shell removed pre-existing .zshenv content"
grep -qF 'export DOCKER_HOST=unix:///tmp/user-selected-docker.sock' "$zshenv_unit_home/.zshenv" ||
    fail "configure_shell did not preserve the user's Docker override"
grep -qF 'export PUPPETEER_EXECUTABLE_PATH=/project/browser' "$zshenv_unit_home/.zshenv" ||
    fail "configure_shell did not preserve project Puppeteer configuration"
[ "$(grep -Fxc '# >>> devbox managed zshenv >>>' "$zshenv_unit_home/.zshenv")" = 1 ] ||
    fail "configure_shell did not install exactly one managed .zshenv block"
[ "$(file_mode "$zshenv_unit_home/.zshenv")" = 600 ] ||
    fail "configure_shell changed the existing .zshenv permissions"
cp "$zshenv_unit_home/.zshenv" "$zshenv_unit_root/.zshenv-first-run"
ROOT="$ROOT" HOME="$zshenv_unit_home" DEVBOX_PROVISION_ROOT="$ROOT/provision" \
    PATH="$zshenv_stub_bin:/usr/bin:/bin" /bin/bash -c '
        set -Eeuo pipefail
        source "$DEVBOX_PROVISION_ROOT/scripts/lib/common.sh"
        source "$DEVBOX_PROVISION_ROOT/scripts/lib/configure.sh"
        configure_shell
    ' || fail "repeat shell configuration failed"
cmp -s "$zshenv_unit_root/.zshenv-first-run" "$zshenv_unit_home/.zshenv" ||
    fail "repeat shell configuration changed the managed .zshenv"

if command -v zsh >/dev/null 2>&1; then
    default_puppeteer_path="$(env -u PUPPETEER_EXECUTABLE_PATH -u PUPPETEER_SKIP_DOWNLOAD \
        zsh -f -c '
        source "$1"
        printenv PUPPETEER_EXECUTABLE_PATH
    ' _ "$ROOT/$rootless_zshenv")" || fail "zsh startup could not set the Puppeteer default"
    [ "$default_puppeteer_path" = /snap/bin/chromium ] ||
        fail "an unset Puppeteer path did not default to /snap/bin/chromium"

    inherited_puppeteer_path="$(env PUPPETEER_EXECUTABLE_PATH=/project/inherited-browser \
        zsh -f -c '
        source "$1"
        printenv PUPPETEER_EXECUTABLE_PATH
    ' _ "$ROOT/$rootless_zshenv")" || fail "zsh startup could not read an inherited Puppeteer path"
    [ "$inherited_puppeteer_path" = /project/inherited-browser ] ||
        fail "zsh startup replaced an inherited Puppeteer path"

    shell_docker_host="unix:///run/user/$(id -u)/docker.sock"
    shell_config_output="$(env DOCKER_HOST=unix:///tmp/inherited.sock DOCKER_CONTEXT=inherited \
        PUPPETEER_EXECUTABLE_PATH=/project/browser PUPPETEER_SKIP_DOWNLOAD=true zsh -f -c '
        source "$1"
        printf "%s\n%s\n%s\n%s\n" "$DOCKER_HOST" "${DOCKER_CONTEXT-<unset>}" \
            "${PUPPETEER_EXECUTABLE_PATH-<unset>}" "${PUPPETEER_SKIP_DOWNLOAD-<unset>}"
    ' _ "$ROOT/$rootless_zshenv")" || fail "zsh startup config could not be loaded"
    expected_shell_config="$shell_docker_host
<unset>
/project/browser
true"
    [ "$shell_config_output" = "$expected_shell_config" ] ||
        fail "zsh startup changed a project Puppeteer setting or missed the rootless Docker default"
    merged_zshenv_output="$(env -u PUPPETEER_EXECUTABLE_PATH zsh -f -c '
        source "$1"
        printf "%s\n%s\n%s\n" "$DEVBOX_ZSHENV_USER_SETTING" "$DOCKER_HOST" \
            "$PUPPETEER_EXECUTABLE_PATH"
    ' _ "$zshenv_unit_home/.zshenv")" || fail "managed .zshenv could not be sourced by zsh"
    expected_merged_zshenv="preserved
unix:///tmp/user-selected-docker.sock
/project/browser"
    [ "$merged_zshenv_output" = "$expected_merged_zshenv" ] ||
        fail "managed .zshenv did not preserve effective user and project settings"
fi

services_stub_bin="$validation_root/services-stub-bin"
services_capture="$validation_root/services-capture"
mkdir -p "$services_stub_bin"
cat >"$services_stub_bin/docker" <<'EOF'
#!/bin/bash
printf 'host=%s\n' "${DOCKER_HOST:-}" >"$SERVICE_CAPTURE"
if [ "${DOCKER_CONTEXT+x}" = x ]; then
    printf 'context=%s\n' "$DOCKER_CONTEXT" >>"$SERVICE_CAPTURE"
else
    printf 'context=<unset>\n' >>"$SERVICE_CAPTURE"
fi
printf 'arg=%s\n' "$@" >>"$SERVICE_CAPTURE"
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

# --- focused guest state, migration, and sync checks -----------------------
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

# --- devbox remote payloads must be valid Bash ---------------------------------
devbox_home="$validation_root/home"
mkdir -p "$devbox_home"
payloads_dir="$validation_root/payloads"
mkdir -p "$payloads_dir"
payload_archive="$validation_root/payload-provision.tar"
mkdir -p "$validation_root/payload-tree/provision/scripts"
: >"$validation_root/payload-tree/provision/scripts/system.sh"
: >"$validation_root/payload-tree/provision/scripts/tools.sh"
: >"$validation_root/payload-tree/provision/scripts/verify.sh"
tar -cf "$payload_archive" -C "$validation_root/payload-tree" provision
payload_digest="$(printf '0%.0s' {1..64})"
HOME="$devbox_home" DEVBOX_REMOTE_PAYLOADS_DIR="$payloads_dir" ROOT="$ROOT" DEVBOX_DIR="$ROOT" \
    DEVBOX_PAYLOAD_ARCHIVE="$payload_archive" DEVBOX_PAYLOAD_DIGEST="$payload_digest" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    capture_payloads() {
        local i j target
        for ((i = 1; i <= $#; i++)); do
            if [ "${!i}" = "-c" ]; then
                j=$((i + 1))
                target="$(mktemp "$DEVBOX_REMOTE_PAYLOADS_DIR/payload.XXXXXX")"
                printf "%s" "${!j}" >"$target"
            fi
        done
        return 0
    }
    devbox_admin_guest() { capture_payloads "$@"; }
    devbox_as_guest() { capture_payloads "$@"; }
    # Fail loudly instead of capturing nothing: a future payload sent through
    # these transports must be given an explicit capture path above.
    devbox_colima() {
        printf "ERROR: devbox_colima payload was not captured for syntax checking\n" >&2
        exit 1
    }
    devbox_guest() {
        printf "ERROR: devbox_guest payload was not captured for syntax checking\n" >&2
        exit 1
    }
    stream_devbox_bundle "$DEVBOX_PAYLOAD_DIGEST" "$DEVBOX_PAYLOAD_ARCHIVE" || true
    devbox_guest_bundle_is_valid "$DEVBOX_PAYLOAD_DIGEST" || true
' || fail "devbox remote payload capture failed"
payload_count=0
for payload in "$payloads_dir"/payload.*; do
    [ -s "$payload" ] || continue
    payload_count=$((payload_count + 1))
    bash -n "$payload" || fail "a devbox remote payload is not valid Bash: $payload"
done
# Only the two bootstrap payloads remain inline; every other guest step lives
# in provision/scripts and is covered by the shell-syntax scan above.
[ "$payload_count" -ge 2 ] || fail "expected at least 2 devbox remote payloads, captured $payload_count"

# --- devbox SSH config rendering and managed alias ---------------------------
ssh_config_unit_root="$validation_root/ssh-config-unit"
mkdir -p "$ssh_config_unit_root"
cat >"$validation_root/ssh-config-unit.sh" <<'EOF'
#!/bin/bash
set -Eeuo pipefail

unit_root="$1"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/devbox.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cat >"$unit_root/colima.conf" <<'CONFIG'
Host colima-devbox
  HostName 127.0.0.1
  User lima
  Port 51234
  IdentityFile /tmp/devbox-key
  ControlMaster auto
  ForwardAgent yes
CONFIG
render_devbox_ssh_managed_block "$unit_root/colima.conf" >"$unit_root/managed-rendered" ||
    fail "rendering the managed block failed"
grep -qx 'Host devbox' "$unit_root/managed-rendered" || fail "managed block has no Host"
grep -qx '  User devbox' "$unit_root/managed-rendered" || fail "managed block did not force User devbox"
grep -qx '  IdentitiesOnly yes' "$unit_root/managed-rendered" || fail "managed block lacks IdentitiesOnly"
grep -qx '  ForwardAgent no' "$unit_root/managed-rendered" || fail "managed block did not force ForwardAgent no"
grep -qx '  HostName 127.0.0.1' "$unit_root/managed-rendered" || fail "managed block lost HostName"
grep -qx '  Port 51234' "$unit_root/managed-rendered" || fail "managed block lost Port"
grep -qx '  IdentityFile /tmp/devbox-key' "$unit_root/managed-rendered" ||
    fail "managed block lost IdentityFile"
if grep -qE 'User lima|ForwardAgent yes|ControlMaster' "$unit_root/managed-rendered"; then
    fail "managed block kept an overridden option"
fi

cat >"$unit_root/config-in" <<'CONFIG'
Include ~/.ssh/devbox.conf
# user config
# BEGIN devbox
Host devbox
  Port 1
# END devbox
Host other
  HostName other.example.com
CONFIG
filter_devbox_ssh_config "$unit_root/config-in" >"$unit_root/config-out" ||
    fail "filter_devbox_ssh_config failed"
grep -qx 'Include ~/.ssh/devbox.conf' "$unit_root/config-out" ||
    fail "filter_devbox_ssh_config dropped the persistent Include"
grep -qx '# user config' "$unit_root/config-out" || fail "filter dropped user content"
grep -qx 'Host other' "$unit_root/config-out" || fail "filter dropped the trailing Host entry"
if grep -qE 'BEGIN devbox|END devbox|Port 1' "$unit_root/config-out"; then
    fail "filter kept an old devbox marker block"
fi
printf '# BEGIN devbox\nHost devbox\n' >"$unit_root/config-bad"
if filter_devbox_ssh_config "$unit_root/config-bad" > /dev/null 2>&1; then
    fail "filter accepted an unterminated marker block"
fi

printf 'key\n' >"$unit_root/identity-key"
cat >"$unit_root/lima.conf" <<CONFIG
Host colima-devbox
  IdentityFile "$unit_root/identity-key"
CONFIG
[ "$(devbox_identity_file "$unit_root/lima.conf")" = "$unit_root/identity-key" ] ||
    fail "devbox_identity_file did not read the quoted identity file"
mkdir -p "$unit_root/links"
printf 'target\n' >"$unit_root/links/real"
ln -s real "$unit_root/links/one"
ln -s one "$unit_root/links/two"
[ "$(resolve_symlink_target "$unit_root/links/two")" = "$unit_root/links/real" ] ||
    fail "resolve_symlink_target did not follow a symlink chain"

include_unit_root="$unit_root/ssh-include"
mkdir -p "$include_unit_root/home/.ssh" "$include_unit_root/bin"
printf '#!/bin/bash\nexit 0\n' >"$include_unit_root/bin/ssh"
chmod +x "$include_unit_root/bin/ssh"
cat >"$include_unit_root/colima.conf" <<'CONFIG'
Host colima-devbox
  HostName 127.0.0.1
  Port 51234
  IdentityFile /tmp/devbox-key
CONFIG
cat >"$include_unit_root/home/.ssh/config" <<'CONFIG'
Include ~/.ssh/devbox.conf
Host other
  HostName other.example.com
# BEGIN devbox
Host old-devbox
  Port 1
# END devbox
CONFIG
cp "$include_unit_root/home/.ssh/config" "$include_unit_root/config-before"
HOME="$include_unit_root/home" PATH="$include_unit_root/bin:/usr/bin:/bin" \
    ROOT="$ROOT" DEVBOX_INCLUDE_CONFIG="$include_unit_root/colima.conf" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    write_devbox_ssh_config "$DEVBOX_INCLUDE_CONFIG"
' || fail "write_devbox_ssh_config failed"
[ -f "$include_unit_root/home/.ssh/devbox.conf" ] || fail "managed SSH file was not written"
[ "$(file_mode "$include_unit_root/home/.ssh/devbox.conf")" = 600 ] ||
    fail "managed SSH file has the wrong mode"
cmp -s "$include_unit_root/home/.ssh/config" "$include_unit_root/config-before" ||
    fail "write_devbox_ssh_config modified the user's SSH config"
cp "$include_unit_root/home/.ssh/devbox.conf" "$include_unit_root/first-managed"
HOME="$include_unit_root/home" PATH="$include_unit_root/bin:/usr/bin:/bin" \
    ROOT="$ROOT" DEVBOX_INCLUDE_CONFIG="$include_unit_root/colima.conf" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    write_devbox_ssh_config "$DEVBOX_INCLUDE_CONFIG"
' || fail "repeat write_devbox_ssh_config failed"
cmp -s "$include_unit_root/home/.ssh/devbox.conf" "$include_unit_root/first-managed" ||
    fail "managed SSH file is not stable"
HOME="$include_unit_root/home" PATH="$include_unit_root/bin:/usr/bin:/bin" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    remove_devbox_ssh_config
' || fail "remove_devbox_ssh_config failed"
[ ! -e "$include_unit_root/home/.ssh/devbox.conf" ] || fail "managed SSH file was not removed"
grep -qx 'Include ~/.ssh/devbox.conf' "$include_unit_root/home/.ssh/config" ||
    fail "cleanup removed the persistent Include"
grep -qx 'Host other' "$include_unit_root/home/.ssh/config" ||
    fail "cleanup dropped user SSH configuration"
if grep -q 'BEGIN devbox' "$include_unit_root/home/.ssh/config"; then
    fail "cleanup kept an old devbox marker block"
fi
EOF
ROOT="$ROOT" /bin/bash "$validation_root/ssh-config-unit.sh" "$ssh_config_unit_root" ||
    fail "devbox SSH config tests failed"

# --- host configuration resolution and validation ----------------------------
env_output="$(
    DEVBOX_ENV_FILE="$validation_root/override.env" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        devbox_env_file
    '
)" || fail "devbox_env_file failed with DEVBOX_ENV_FILE"
[ "$env_output" = "$validation_root/override.env" ] ||
    fail "DEVBOX_ENV_FILE did not override the configuration path"
env_output="$(
    DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        devbox_env_file
    '
)" || fail "devbox_env_file failed for a checkout"
[ "$env_output" = "$ROOT/.env" ] ||
    fail "devbox_env_file did not return the checkout .env"

# VM resource values are rendered into the Colima configuration, so a typo must
# fail before it can reach the VM.
resource_env="$validation_root/resources.env"
printf 'export GIT_NAME="Resource Test"\nexport GIT_EMAIL="resource@example.com"\nexport DEVBOX_CPU=four\n' \
    >"$resource_env"
chmod 600 "$resource_env"
if DEVBOX_ENV_FILE="$resource_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    load_env
' 2>"$validation_root/resources.err"; then
    fail "load_env accepted a non-numeric DEVBOX_CPU"
fi
grep -q 'DEVBOX_CPU' "$validation_root/resources.err" ||
    fail "invalid DEVBOX_CPU rejection did not name the key"
grep -q 'four' "$validation_root/resources.err" ||
    fail "invalid DEVBOX_CPU rejection did not name the value"
printf 'export GIT_NAME="Resource Test"\nexport GIT_EMAIL="resource@example.com"\nexport DEVBOX_DISK=0\n' \
    >"$resource_env"
chmod 600 "$resource_env"
if DEVBOX_ENV_FILE="$resource_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    load_env
' 2>/dev/null; then
    fail "load_env accepted a zero DEVBOX_DISK"
fi
printf 'export GIT_NAME="Resource Test"\nexport GIT_EMAIL="resource@example.com"\nexport DEVBOX_CPU=8\n' \
    >"$resource_env"
chmod 600 "$resource_env"
resource_output="$(
    DEVBOX_ENV_FILE="$resource_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        load_env
        printf "%s\n" "$DEVBOX_CPU"
    '
)" || fail "load_env rejected a valid DEVBOX_CPU"
[ "$resource_output" = "8" ] || fail "load_env did not load the valid DEVBOX_CPU"

# --- focused host config, proxy, and Colima checks -------------------------
source "$ROOT/scripts/check-host-config.sh"

# A world-readable configuration file is rejected.
chmod 644 "$resource_env"
if DEVBOX_ENV_FILE="$resource_env" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    load_env
' 2>/dev/null; then
    fail "load_env accepted a world-readable configuration file"
fi

# --- devbox init prompting and .env writing ---------------------------------
init_unit_root="$validation_root/init-unit"
mkdir -p "$init_unit_root/home"
init_env="$init_unit_root/config/devbox/env"
printf 'Devbox Test\ndevbox@example.com\n\n\n\n\n\n\n' |
    HOME="$init_unit_root/home" DEVBOX_ENV_FILE="$init_env" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    for key in "${ENV_KEYS[@]}"; do unset "$key"; done
    prompt_env_values
    write_env_file "$DEVBOX_ENV_FILE"
' 2>/dev/null || fail "devbox init prompting failed"
[ "$(file_mode "$init_env")" = 600 ] ||
    fail "devbox init wrote the configuration with the wrong mode"
grep -q '^export GIT_NAME="Devbox Test"$' "$init_env" ||
    fail "devbox init did not write the answered value"
grep -q '^export DEVBOX_CPU="4"$' "$init_env" ||
    fail "devbox init did not write the optional default"
grep -q '^# devbox configuration' "$init_env" ||
    fail "devbox init did not write the configuration header comment"
# Required values fail without a terminal instead of writing a partial file.
if printf '\n\n' | HOME="$init_unit_root/home" DEVBOX_ENV_FILE="$init_unit_root/missing.env" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    for key in "${ENV_KEYS[@]}"; do unset "$key"; done
    prompt_env_values
    write_env_file "$DEVBOX_ENV_FILE"
' >/dev/null 2>&1; then
    fail "devbox init accepted empty required values"
fi
[ ! -e "$init_unit_root/missing.env" ] ||
    fail "devbox init wrote the configuration after a failed prompt"

# A symlinked configuration is updated through the link, not replaced.
symlink_root="$validation_root/env-symlink"
mkdir -p "$symlink_root/home" "$symlink_root/dotfiles"
printf 'export GIT_NAME="Old"\n' >"$symlink_root/dotfiles/env"
ln -s "$symlink_root/dotfiles/env" "$symlink_root/home/.env"
HOME="$symlink_root/home" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    for key in "${ENV_KEYS[@]}"; do unset "$key"; done
    GIT_NAME="New"; GIT_EMAIL="e@x.com"; POSTGRES_USER=dev; POSTGRES_DB=dev
    POSTGRES_PORT=15432; DEVBOX_CPU=4; DEVBOX_MEMORY=4; DEVBOX_DISK=60
    DEVBOX_USE_HOST_PROXY=false
    write_env_file "$HOME/.env"
' || fail "write_env_file failed for a symlinked configuration"
[ -L "$symlink_root/home/.env" ] || fail "write_env_file replaced a symlinked .env"
grep -q '^export GIT_NAME="New"$' "$symlink_root/dotfiles/env" ||
    fail "write_env_file did not update the symlink target"

# Unsupported and malformed lines are reported before the rewrite drops them.
warning_env="$validation_root/warning.env"
printf 'export GIT_NAME="X"\nexport POSTGRES_PASSWORD=secret\nnot an assignment\n' >"$warning_env"
chmod 600 "$warning_env"
HOME="$init_unit_root/home" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    for key in "${ENV_KEYS[@]}"; do unset "$key"; done
    load_env_defaults "$1"
' _ "$warning_env" 2>"$validation_root/warning.err" ||
    fail "load_env_defaults failed on an unsupported key"
grep -q 'removes unsupported variable POSTGRES_PASSWORD' "$validation_root/warning.err" ||
    fail "load_env_defaults did not report the unsupported key"
grep -q 'is not a KEY=value assignment' "$validation_root/warning.err" ||
    fail "load_env_defaults did not report the malformed line"

# --- devbox CLI symlink -------------------------------------------------------
cli_unit_root="$validation_root/cli-unit"
mkdir -p "$cli_unit_root/home"
printf 'export EDITOR=vim\n' >"$cli_unit_root/home/.zshrc"
cp "$cli_unit_root/home/.zshrc" "$cli_unit_root/zshrc-before"
HOME="$cli_unit_root/home" PATH="/usr/bin:/bin" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    install_cli "$ROOT/devbox"
    uninstall_cli "$ROOT/devbox"
' >/dev/null || fail "devbox CLI install/uninstall failed"
[ ! -e "$cli_unit_root/home/.local/bin/devbox" ] || fail "uninstall kept the devbox symlink"
cmp -s "$cli_unit_root/home/.zshrc" "$cli_unit_root/zshrc-before" ||
    fail "CLI installation modified the user's shell config"
mkdir -p "$cli_unit_root/home/bin"
ln -s "$ROOT/devbox" "$cli_unit_root/home/bin/devbox"
HOME="$cli_unit_root/home" PATH="$cli_unit_root/home/bin:/usr/bin:/bin" ROOT="$ROOT" /bin/bash -c '
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
    # Answers: Git name and email, then Enter for the six optional values.
    printf 'Devbox Test\ndevbox@example.com\n\n\n\n\n\n' |
        DEVBOX_ENV_FILE="$init_env" HOME="$init_root/home" PATH="/usr/bin:/bin" \
        "$ROOT/devbox" init >"$init_root/init.log" 2>&1 ||
        fail "devbox init did not complete with piped answers"
    [ -f "$init_env" ] || fail "devbox init did not create the host configuration"
    [ "$(file_mode "$init_env")" = 600 ] ||
        fail "devbox init created the host configuration with the wrong mode"
    grep -q '^export GIT_NAME="Devbox Test"$' "$init_env" ||
        fail "devbox init did not write the answered Git name"
    grep -q '^export DEVBOX_CPU="4"$' "$init_env" ||
        fail "devbox init did not write the optional defaults"
    grep -q '^# devbox configuration' "$init_env" ||
        fail "devbox init did not add the configuration header comment"
    grep -q "Configuration: $init_env" "$init_root/init.log" ||
        fail "devbox init did not report the configuration location"
    # A repeat run with no input keeps the existing values as defaults.
    DEVBOX_ENV_FILE="$init_env" HOME="$init_root/home" PATH="/usr/bin:/bin" \
        "$ROOT/devbox" init </dev/null >/dev/null ||
        fail "repeat devbox init failed"
    grep -q '^export GIT_NAME="Devbox Test"$' "$init_env" ||
        fail "repeat devbox init changed existing values"
else
    printf 'WARN: devbox init smoke test requires macOS; skipping\n' >&2
fi

printf 'All checks passed.\n'
