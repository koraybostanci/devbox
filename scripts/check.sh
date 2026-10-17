#!/bin/bash

# The grep patterns below are intentionally literal and the `A && B || C`
# forms end in fail()/diagnosis blocks that always exit, so both info findings
# are declared once instead of suppressing them per line. Sources resolve at
# runtime, never statically followable paths (SC1091), and apparmor_parser
# shadows an external tool that a sourced library invokes indirectly (SC2329).
# This file-wide disable must stay before the first command to have effect.
# shellcheck disable=SC2016,SC2015,SC1091,SC2329

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

# --- shellcheck ---------------------------------------------------------------
# bash -n only proves parseability; linting the same list also rejects
# unquoted-expansion- and capture-into-`[[`-class bugs that parse cleanly.
# Suppression is allowed only through # shellcheck directives in the files.
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${shell_files[@]}"
else
    printf 'Warning: shellcheck is unavailable; skipping shell lint\n' >&2
    if [ -n "${CI:-}" ]; then
        fail "shellcheck is required in CI"
    fi
fi

# The host runs macOS /bin/bash 3.2; keep bash 4+ constructs out of host code,
# including the gate files themselves, which execute under macOS /bin/bash when
# reused there. Tokens like `[;][&]` are bracketed so this grep never matches
# its own literal text.
if grep -nE \
    '[m]apfile|[r]eadarray|[c]oproc|(declare|local|typeset) -[gAn]|\$\{[A-Za-z_]+(,,|\^\^|@[QEPAa])|\[\[ -v |[;][;][&]|[;][&]' \
    devbox lib/*.sh scripts/*.sh; then
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

# --- devbox version edge cases ------------------------------------------------
# A missing or empty VERSION must exit nonzero with an ERROR line, not print
# an empty version silently. The launcher tree is copied without VERSION (and with an
# emptied one) under a HOME-isolated fixture; the launcher resolves its own
# directory, so the copies prove the behavior without touching the checkout.
version_fixture="$validation_root/version-fixture"
version_home="$version_fixture/home"
mkdir -p "$version_home"
cp "$ROOT/devbox" "$version_fixture/devbox"
cp -R "$ROOT/lib" "$version_fixture/lib"
version_fixture_run() {
    HOME="$version_home" "$version_fixture/devbox" "$@"
}
if version_edge_output="$(version_fixture_run version 2>&1)"; then
    fail "devbox version accepted a missing VERSION file"
fi
[[ "$version_edge_output" == *'ERROR:'* ]] ||
    fail "a missing VERSION file did not exit with an ERROR line ($version_edge_output)"
: >"$version_fixture/VERSION"
if version_edge_output="$(version_fixture_run version 2>&1)"; then
    fail "devbox version accepted an empty VERSION file"
fi
[[ "$version_edge_output" == *'ERROR:'* ]] ||
    fail "an empty VERSION file did not exit with an ERROR line ($version_edge_output)"

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

# --- scan target guard ---------------------------------------------------------
# Fail closed on a missing scan target: grep -R exits 2 for a missing path,
# which would silently satisfy the non-match tests below.
require_paths=(
    devbox lib provision/scripts provision/config/zsh provision/config/guest
    provision/config/claude provision/config/opencode provision/config/services
    provision/config/skills
)
for scan_target in "${require_paths[@]}"; do
    [ -e "$scan_target" ] || fail "scan target is missing: $scan_target"
done

# --- devbox must not need host jq or yq ----------------------------------------
# The launcher (`devbox`) and the common library are scanned as well: the
# launcher delegates to both of them.
if grep -nE '(^|[^[:alnum:]_])(jq|yq)([^[:alnum:]_]|$)' \
    devbox lib/devbox.sh lib/config.sh lib/common.sh; then
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
if grep -R -nE \
    'kernel\.apparmor_restrict_unprivileged_userns[[:space:]]*=[[:space:]]*0|sysctl[[:space:]].*apparmor_restrict_unprivileged_userns' \
    provision/scripts; then
    fail "RootlessKit provisioning must not disable AppArmor's user-namespace restriction"
fi

# verify.sh runs as the unprivileged devbox user and cannot traverse the
# root-only services directory; file-level checks belong in root scripts.
verify_forbidden_strings=('/var/lib/devbox/services/')
for verify_forbidden_string in "${verify_forbidden_strings[@]}"; do
    if grep -qF -- "$verify_forbidden_string" provision/scripts/verify.sh; then
        fail "verify.sh must not inspect files inside the root-only services directory"
    fi
done
# Readiness tripwire: assert the `check` CALL sites, never a bare function
# name. A bare-name match also hits the definitions, so removing an
# invocation while its definition remains would be a false pass.
for readiness_check in \
    rootless_context_is_selected rootless_docker_is_ready \
    rootful_docker_is_denied chromium_launches_headlessly; do
    if ! grep -Eq "^[[:space:]]*check \".*\"[[:space:]]$readiness_check\$" provision/scripts/verify.sh; then
        fail "guest readiness check call is missing: $readiness_check"
    fi
done

# User Docker and Puppeteer defaults must be isolated from the root-managed
# services daemon and project-specific browser download settings. The dynamic
# zsh battery below proves those startup behaviors stay effective, so no static
# greps pin them here. Only the global-download prohibition needs a grep: a
# global `export PUPPETEER_SKIP_DOWNLOAD=true` would be indistinguishable from
# an inherited value inside the dynamic test.
rootless_zshenv=provision/config/zsh/zshenv
if grep -R -nE '^[[:space:]]*(export[[:space:]]+)?PUPPETEER_SKIP_DOWNLOAD=' provision/config/zsh; then
    fail "PUPPETEER_SKIP_DOWNLOAD must remain project-scoped, not global"
fi
grep -qF 'snap install chromium --channel=stable' provision/scripts/system.sh ||
    fail "system provisioning must install actual Ubuntu Chromium from the stable snap"
grep -qF 'devbox_configure_rootless_docker' provision/scripts/tools.sh ||
    fail "the unprivileged tools phase must configure rootless Docker"
grep -qF 'cd "$package_root" && node install.cjs' provision/scripts/lib/apps.sh ||
    fail "Claude Code provisioning must run its installer script"
grep -qF '"@anthropic-ai/claude-code-linux-arm64@$CLAUDE_CODE_VERSION"' provision/scripts/lib/apps.sh ||
    fail "Claude Code provisioning must explicitly install the Linux ARM64 native package"
grep -qF '[ -x "$package_root/bin/claude.exe" ]' provision/scripts/lib/apps.sh ||
    fail "Claude Code provisioning must verify that its native binary was installed"
grep -qE '^[[:space:]]+vim$' provision/scripts/system.sh ||
    fail "system provisioning must install the Vim command-line editor"
grep -qF 'export EDITOR=vim' provision/config/zsh/zshrc ||
    fail "the guest shell must default to Vim for command-line editing"
grep -qE '^[[:space:]]+apparmor$' provision/scripts/system.sh ||
    fail "system provisioning must install Ubuntu's AppArmor package"
# Docs policy tripwires: these exact-prose greps pin architecture.md wording
# deliberately, including the Finsights section requirements below.
# A docs edit touching these sentences must update the matching greps in the
# same commit.
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

# Exercise RootlessKit AppArmor profile loading without a VM or system policy:
# only an enabled user-namespace restriction should trigger the load.
apparmor_unit_root="$validation_root/apparmor-unit"
mkdir -p "$apparmor_unit_root"
apparmor_setting="$apparmor_unit_root/restrict-userns"
apparmor_profile="$apparmor_unit_root/rootlesskit-profile"
apparmor_calls="$apparmor_unit_root/parser-calls"
(
    source "$ROOT/provision/scripts/lib/docker.sh"
    parser_call_count=0
    apparmor_parser() {
        [ "$1" = -r ] && [ "$2" = "$apparmor_profile" ] || return 1
        parser_call_count=$((parser_call_count + 1))
        printf '%s %s\n' "$1" "$2" >>"$apparmor_calls"
    }

    printf '0\n' >"$apparmor_setting"
    devbox_prepare_rootlesskit_apparmor_profile \
        "$apparmor_setting" "$apparmor_profile" || exit 1
    [ "$parser_call_count" -eq 0 ] && [ ! -s "$apparmor_calls" ] || exit 1

    printf '1\n' >"$apparmor_setting"
    devbox_prepare_rootlesskit_apparmor_profile \
        "$apparmor_setting" "$apparmor_profile" || exit 1
    [ "$parser_call_count" -eq 1 ] || exit 1
    grep -Fqx -- '-r '"$apparmor_profile" "$apparmor_calls" || exit 1
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
        PUPPETEER_EXECUTABLE_PATH=/project/browser PUPPETEER_SKIP_DOWNLOAD=true \
        DISABLE_AUTOUPDATER=no NPM_CONFIG_ALLOW_SCRIPTS=anything NPM_CONFIG_INCLUDE=stripped \
        zsh -f -c '
        source "$1"
        printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n" "$DOCKER_HOST" "${DOCKER_CONTEXT-<unset>}" \
            "${PUPPETEER_EXECUTABLE_PATH-<unset>}" "${PUPPETEER_SKIP_DOWNLOAD-<unset>}" \
            "${DISABLE_AUTOUPDATER-<unset>}" "${NPM_CONFIG_ALLOW_SCRIPTS-<unset>}" \
            "${NPM_CONFIG_INCLUDE-<unset>}"
    ' _ "$ROOT/$rootless_zshenv")" || fail "zsh startup config could not be loaded"
    [ "$shell_config_output" = "unix:///run/user/$(id -u)/docker.sock
<unset>
/project/browser
true
1
@anthropic-ai/claude-code
optional" ] || fail "zsh startup changed a project setting or missed a rootless Docker or Claude Code default"
    cp "$zshenv_unit_root/.zshenv-expected" "$zshenv_unit_home/.zshenv"
    merged_zshenv_output="$(env -u PUPPETEER_EXECUTABLE_PATH zsh -f -c '
        source "$1"
        printf "%s\n%s\n%s\n" "$DEVBOX_ZSHENV_USER_SETTING" "$DOCKER_HOST" "$PUPPETEER_EXECUTABLE_PATH"
    ' _ "$zshenv_unit_home/.zshenv")" || fail "managed .zshenv could not be sourced by zsh"
    [ "$merged_zshenv_output" = "preserved
unix:///tmp/user-selected-docker.sock
/project/browser" ] || fail "managed .zshenv did not preserve effective user and project settings"
else
    # No silent skip: this battery is the only proof of the zshenv behaviors.
    if [ -n "${CI:-}" ]; then
        fail "zsh is required in CI"
    fi
    printf 'WARN: zsh is unavailable; skipping the zsh startup battery\n' >&2
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
# The scan targets were existence-checked against `require_paths` above, so
# no missing-path `grep -R` trap can report a false pass here; the four
# provision/config agent trees are covered too.
if grep -R -E -- \
    '^[[:space:]]*eval[[:space:]]|curl[^|]*\|[[:space:]]*(ba)?sh|SSH_AUTH_SOCK=/run/host-services|chmod 0777|rm -rf "\$HOME/(projects|data)|/etc/environment|readlink -f' \
    "${require_paths[@]}"; then
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

# --- devbox_guest argument quoting ---------------------------------------------
# OpenSSH space-joins the remote argv and the guest shell re-parses it, so
# devbox_guest pre-quotes each host argument with printf '%q'. The stub below
# records its argv; re-parsing the remote string the way the guest shell would
# must reproduce every argument verbatim — spaces and shell metacharacters
# included — proving host args are no longer re-expanded by the guest shell.
quote_bin="$ssh_unit_root/quote-bin"
mkdir -p "$quote_bin"
cat >"$quote_bin/ssh" <<'STUB'
#!/bin/bash
for arg in "$@"; do
    printf '%s\n' "$arg"
done
STUB
chmod +x "$quote_bin/ssh"
ssh_unit "$quote_bin" devbox_guest touch 'a b;cd /tmp' \
    >"$ssh_unit_root/quote-args" || fail "devbox_guest did not invoke ssh"
remote_cmd="$(tail -n 1 "$ssh_unit_root/quote-args")"
[ "$remote_cmd" != "" ] || fail "devbox_guest sent an empty remote command"
remote_cmd="$remote_cmd" /bin/bash -c '
    set -eu
    eval "remote_argv=($remote_cmd)"
    printf '\''%s\n'\'' "${remote_argv[@]}"
' >"$ssh_unit_root/parsed-args" ||
    fail "guest-shell re-parse of the quoted argv failed"
printf '%s\n' 'touch' 'a b;cd /tmp' >"$ssh_unit_root/expected-args"
cmp -s "$ssh_unit_root/parsed-args" "$ssh_unit_root/expected-args" ||
    fail "devbox_guest quoting did not survive the guest shell re-parse"

# --- version comparison and dependency hardening ----------------------------
# version_at_least must strip an optional leading 'v' and trailing '-suffix',
# require dotted-numeric input on both sides, and fail closed on anything
# else. The grep gates above cannot prove ordering behavior; these units can.
version_at_least '0.10.3-1' '0.10.3' ||
    fail "version_at_least false-rejected the suffixed version 0.10.3-1"
if version_at_least '0.10.2' '0.10.3'; then
    fail "version_at_least accepted 0.10.2 as newer than 0.10.3"
fi
version_at_least '0.10.3' '0.10.3' || fail "version_at_least rejected equal versions"
if version_at_least 'junk' '0.10.3'; then
    fail "version_at_least did not fail closed on junk input"
fi

# check_devbox_dependencies must demand ssh-keygen and shasum alongside colima
# and ssh, and must die embedding the raw first line of 'colima version' when
# it does not parse. Stub colima to exercise each path without a host install.
dep_stub_bin="$validation_root/dep-stub-bin"
mkdir -p "$dep_stub_bin"
for dep_stub in ssh ssh-keygen shasum; do
    printf '#!/bin/bash\nexit 0\n' >"$dep_stub_bin/$dep_stub"
    chmod +x "$dep_stub_bin/$dep_stub"
done
cat >"$dep_stub_bin/colima" <<'EOF'
#!/bin/bash
printf '%s\n' "${DEP_COLIMA_VERSION:-}"
EOF
chmod +x "$dep_stub_bin/colima"
dep_unit() {
    PATH="$dep_stub_bin:/usr/bin:/bin" DEP_COLIMA_VERSION="$1" \
        DEVBOX_COLIMA_HOME="$validation_root/dep-colima-home" \
        DEVBOX_LIMA_HOME="$validation_root/dep-colima-home/_lima" \
        DEVBOX_DOCKER_CONFIG="$validation_root/dep-docker-config" \
        /bin/bash -c '
        set -Eeuo pipefail
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        source "$ROOT/lib/devbox.sh"
        check_devbox_dependencies
    '
}
dep_unit 'colima version 0.10.3' >/dev/null ||
    fail "check_devbox_dependencies rejected a current Colima install"
if dep_output="$(dep_unit 'colima version 0.10.2' 2>&1)"; then
    fail "check_devbox_dependencies accepted a too-old Colima install"
fi
[[ "$dep_output" == *'Colima 0.10.3 or newer is required (found 0.10.2)'* ]] ||
    fail "a too-old Colima version produced the wrong diagnosis ($dep_output)"
if dep_output="$(dep_unit 'colima version unparseable-x' 2>&1)"; then
    fail "check_devbox_dependencies accepted an unparseable Colima version"
fi
[[ "$dep_output" == *'colima version unparseable-x'* ]] ||
    fail "an unparseable Colima version did not embed the raw version line ($dep_output)"
dep_unit 'colima version 0.10.3-1' >/dev/null ||
    fail "check_devbox_dependencies false-rejected the suffixed Colima version 0.10.3-1"

# --- stop ordering -----------------------------------------------------------
# Managed services must stop before the VM, and an unclean services stop must
# never block the VM stop. Stubs record the call sequence; the guard proves the
# services stop is attempted only when the bundle is installed in the guest.
stop_unit_root="$validation_root/stop-unit"
mkdir -p "$stop_unit_root/home/.colima/devbox"
stop_scenario() {
    env -u COLIMA_HOME -u LIMA_HOME \
        HOME="$stop_unit_root/home" STOP_UNIT_ROOT="$stop_unit_root" \
        STOP_UNIT_GUARD="$1" STOP_UNIT_SERVICES="$2" \
        /bin/bash -c '
        set -Eeuo pipefail
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        source "$ROOT/lib/devbox.sh"
        configure_devbox_paths
        : >"$STOP_UNIT_ROOT/calls"
        devbox_state() { printf "Running\n"; }
        devbox_admin_guest() {
            printf "guard\n" >>"$STOP_UNIT_ROOT/calls"
            [ "$STOP_UNIT_GUARD" = ok ]
        }
        devbox_services_compose() {
            printf "services stop\n" >>"$STOP_UNIT_ROOT/calls"
            [ "$STOP_UNIT_SERVICES" = ok ]
        }
        devbox_colima() {
            printf "colima %s\n" "$*" >>"$STOP_UNIT_ROOT/calls"
        }
        stop_devbox_vm ""
    '
}
stop_services_then_vm="$stop_unit_root/services-then-vm"
printf 'guard\nservices stop\ncolima stop devbox\n' >"$stop_services_then_vm"
stop_out="$(stop_scenario ok ok 2>&1)" ||
    fail "stop_devbox_vm failed with the services bundle installed ($stop_out)"
cmp -s "$stop_unit_root/calls" "$stop_services_then_vm" ||
    fail "stop_devbox_vm did not stop services before the VM ($(tr '\n' ' ' \
        <"$stop_unit_root/calls"))"
stop_out="$(stop_scenario ok fail 2>&1)" ||
    fail "an unclean services stop blocked the VM stop ($stop_out)"
[[ "$stop_out" == *'WARNING:'* ]] ||
    fail "an unclean services stop did not warn before the VM stop ($stop_out)"
cmp -s "$stop_unit_root/calls" "$stop_services_then_vm" ||
    fail "an unclean services stop changed the stop sequence ($(tr '\n' ' ' \
        <"$stop_unit_root/calls"))"
printf 'guard\ncolima stop devbox\n' >"$stop_unit_root/guard-then-vm"
stop_out="$(stop_scenario fail ok 2>&1)" ||
    fail "stop_devbox_vm failed when the services bundle was absent ($stop_out)"
cmp -s "$stop_unit_root/calls" "$stop_unit_root/guard-then-vm" ||
    fail "stop_devbox_vm stopped services without the services bundle ($(tr '\n' ' ' \
        <"$stop_unit_root/calls"))"

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

# A live owner seen through a missing/empty/truncated pid file must be treated
# as stale and recovered, not as a silent set -e exit wedging the lock. Run
# acquisitions against an empty pid file and one naming a guaranteed-dead pid.
stale_dir="$lock_dir"
/bin/bash -c 'exit 0' & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
for stale_case in "empty:" "dead-pid:$dead_pid"; do
    stale_name=${stale_case%%:*}
    stale_pid=${stale_case#*:}
    mkdir -p "$stale_dir/lifecycle-stale"
    : >"$stale_dir/lifecycle-stale/pid"
    [ "$stale_name" = empty ] || printf '%s\n' "$stale_pid" >"$stale_dir/lifecycle-stale/pid"
    stale_status=0
    stale_output="$(DEVBOX_LOCK_DIR="$stale_dir" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        acquire_lock lifecycle-stale
        [ "$(cat "$DEVBOX_LOCK_DIR/lifecycle-stale/pid")" = "$$" ] || exit 4
    ' 2>&1)" || stale_status=$?
    if [ "$stale_status" != 0 ] ||
        [[ "$stale_output" != *'removing stale lock'* ]]; then
        fail "the $stale_name-pid lock test failed ($stale_status: $stale_output)"
    fi
done

# release_lock must be identity-guarded: a contender that overwrote the pid
# file with a foreign pid (a losing double-hold contender) must not destroy
# the directory on release. Use the gate shell's own pid as the
# guaranteed-live foreign pid; the tree-wide validation_root teardown
# (trap at check.sh start) cleans the surviving directory up afterwards.
guard_status=0
guard_output="$(GUARD_PID=$$ DEVBOX_LOCK_DIR="$lock_dir" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    acquire_lock lifecycle-guard
    printf '"'"'%s\n'"'"' "$GUARD_PID" >"$DEVBOX_LOCK_DIR/lifecycle-guard/pid"
' 2>&1)" || guard_status=$?
[ "$guard_status" = 0 ] ||
    fail "the release-guard lock test failed ($guard_status: $guard_output)"
[[ "$guard_output" == *'WARNING: not removing lock'* ]] ||
    fail "release_lock did not warn on a foreign recorded pid ($guard_output)"
[ -f "$lock_dir/lifecycle-guard/pid" ] &&
    [ "$(cat "$lock_dir/lifecycle-guard/pid")" = "$$" ] ||
    fail "release_lock disturbed a live owner's lock directory"

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
reject_env 'export GIT_NAME="John" # "Doe"'
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

# A mixed-quote ` #` value is an error in strict and is truncated before the
# first ` #` in lenient; the stripper then removes the now-matching outer
# quotes, so the kept value is the clean `John`, not the mangled `"Doe"` tail.
lenient_name_env="$validation_root/lenient-name.env"
printf 'export GIT_NAME="John" # "Doe"\nexport DEVBOX_CPU=4\n' >"$lenient_name_env"
lenient_name_output="$(/bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    unset_env_keys
    read_env_file "$1" lenient
    printf "GIT_NAME=%s\n" "$GIT_NAME"
' _ "$lenient_name_env" 2>&1)" || fail "lenient configuration reading failed on a mangled quote"
[[ "$lenient_name_output" == *'contains an unquoted space-hash'* ]] ||
    fail "lenient configuration reading did not report the unquoted space-hash"
[[ "$lenient_name_output" == *'GIT_NAME=John'* ]] ||
    fail "lenient configuration reading did not truncate before the first space-hash"

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
