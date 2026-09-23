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

# --- devbox SSH config filtering and rendering --------------------------------
# filter_devbox_ssh_config, render_devbox_ssh_managed_block, and
# resolve_symlink_target are pure: exercise them outside any VM.
ssh_config_unit_root="$validation_root/ssh-config-unit"
mkdir -p "$ssh_config_unit_root"
cat >"$validation_root/ssh-config-unit.sh" <<'EOF'
#!/bin/bash
set -Eeuo pipefail

unit_root="$1"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/devbox.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# render_devbox_ssh_managed_block rewrites Colima's output into the managed
# block: the unprivileged user and disabled agent forwarding are forced, and
# overriding options are dropped.
cat >"$unit_root/colima.conf" <<'CONFIG'
Host devbox
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

# filter_devbox_ssh_config drops devbox includes and previous marker blocks
# while preserving everything else.
cat >"$unit_root/config-in" <<'CONFIG'
# user config
Include devbox.conf
SetEnv KEEP=1
# BEGIN devbox
Host devbox
  Port 1
# END devbox
Include /tmp/other/devbox.conf
Host other
  HostName other.example.com
CONFIG
filter_devbox_ssh_config "$unit_root/config-in" >"$unit_root/config-out" ||
    fail "filter_devbox_ssh_config failed"
grep -qx '# user config' "$unit_root/config-out" ||
    fail "filter_devbox_ssh_config dropped the leading comment"
grep -qx 'SetEnv KEEP=1' "$unit_root/config-out" ||
    fail "filter_devbox_ssh_config dropped user content"
grep -qx 'Host other' "$unit_root/config-out" ||
    fail "filter_devbox_ssh_config dropped the trailing Host entry"
if grep -qE 'devbox\.conf|BEGIN devbox|END devbox|Port 1' "$unit_root/config-out"; then
    fail "filter_devbox_ssh_config kept a devbox include or marker block"
fi

# A missing configuration yields no output.
[ -z "$(filter_devbox_ssh_config "$unit_root/does-not-exist")" ] ||
    fail "filter_devbox_ssh_config produced output for a missing config"

# An unterminated marker block is refused.
printf '# head\n# BEGIN devbox\nHost devbox\n' >"$unit_root/config-bad"
if filter_devbox_ssh_config "$unit_root/config-bad" >"$unit_root/config-bad-out"; then
    fail "filter_devbox_ssh_config accepted an unterminated block"
fi

# resolve_symlink_target follows a chain and leaves missing paths unchanged.
mkdir -p "$unit_root/links"
printf 'target\n' >"$unit_root/links/real"
ln -s real "$unit_root/links/one"
ln -s one "$unit_root/links/two"
[ "$(resolve_symlink_target "$unit_root/links/two")" = "$unit_root/links/real" ] ||
    fail "resolve_symlink_target did not follow a symlink chain"
[ "$(resolve_symlink_target "$unit_root/links/missing")" = "$unit_root/links/missing" ] ||
    fail "resolve_symlink_target changed a missing path"
EOF
ROOT="$ROOT" /bin/bash "$validation_root/ssh-config-unit.sh" "$ssh_config_unit_root" ||
    fail "devbox SSH config filtering and rendering tests failed"

# write_devbox_ssh_config/remove_devbox_ssh_config manage ~/.ssh/devbox.conf
# and the include line; exercise them with a stubbed ssh connection test.
include_unit_root="$validation_root/ssh-include"
mkdir -p "$include_unit_root/home/.ssh" "$include_unit_root/bin"
printf '#!/bin/bash\nexit 0\n' >"$include_unit_root/bin/ssh"
chmod +x "$include_unit_root/bin/ssh"
cat >"$include_unit_root/colima.conf" <<'CONFIG'
Host devbox
  HostName 127.0.0.1
  User lima
  Port 51234
  IdentityFile /tmp/devbox-key
CONFIG
cat >"$include_unit_root/home/.ssh/config" <<'CONFIG'
# user config
# BEGIN devbox
Host devbox
  Port 1
# END devbox
Host other
  HostName other.example.com
CONFIG
chmod 640 "$include_unit_root/home/.ssh/config"
HOME="$include_unit_root/home" PATH="$include_unit_root/bin:/usr/bin:/bin" \
    ROOT="$ROOT" DEVBOX_INCLUDE_CONFIG="$include_unit_root/colima.conf" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    write_devbox_ssh_config "$DEVBOX_INCLUDE_CONFIG"
' || fail "write_devbox_ssh_config failed"
[ "$(head -1 "$include_unit_root/home/.ssh/config")" = "Include devbox.conf" ] ||
    fail "write_devbox_ssh_config did not prepend the include"
[ -f "$include_unit_root/home/.ssh/devbox.conf" ] ||
    fail "write_devbox_ssh_config did not write devbox.conf"
grep -qx 'Host other' "$include_unit_root/home/.ssh/config" ||
    fail "write_devbox_ssh_config dropped user content"
if grep -q 'BEGIN devbox' "$include_unit_root/home/.ssh/config"; then
    fail "write_devbox_ssh_config kept the old marker block"
fi
[ "$(file_mode "$include_unit_root/home/.ssh/config")" = 640 ] ||
    fail "write_devbox_ssh_config changed the config mode"
cp "$include_unit_root/home/.ssh/config" "$include_unit_root/first-config"
HOME="$include_unit_root/home" PATH="$include_unit_root/bin:/usr/bin:/bin" \
    ROOT="$ROOT" DEVBOX_INCLUDE_CONFIG="$include_unit_root/colima.conf" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    write_devbox_ssh_config "$DEVBOX_INCLUDE_CONFIG"
' || fail "repeat write_devbox_ssh_config failed"
cmp -s "$include_unit_root/home/.ssh/config" "$include_unit_root/first-config" ||
    fail "write_devbox_ssh_config is not idempotent"
HOME="$include_unit_root/home" PATH="$include_unit_root/bin:/usr/bin:/bin" \
    ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/devbox.sh"
    remove_devbox_ssh_config
' || fail "remove_devbox_ssh_config failed"
if grep -q 'devbox.conf' "$include_unit_root/home/.ssh/config"; then
    fail "remove_devbox_ssh_config kept the include"
fi
[ ! -e "$include_unit_root/home/.ssh/devbox.conf" ] ||
    fail "remove_devbox_ssh_config kept devbox.conf"
grep -qx 'Host other' "$include_unit_root/home/.ssh/config" ||
    fail "remove_devbox_ssh_config dropped user content"

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
printf 'Devbox Test\ndevbox@example.com\n\n\n\n\n\n' |
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

# --- devbox PATH block in the login shell rc --------------------------------
path_unit_root="$validation_root/path-unit"
mkdir -p "$path_unit_root/home"
path_rc="$path_unit_root/home/.zshrc"
printf 'export EDITOR=vim\n' >"$path_rc"
chmod 640 "$path_rc"
HOME="$path_unit_root/home" SHELL=/bin/zsh PATH="/usr/bin:/bin" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    ensure_devbox_path "$HOME/.local/bin" || exit 1
    ensure_devbox_path "$HOME/.local/bin" || exit 1
' >/dev/null || fail "ensure_devbox_path failed"
[ "$(grep -c '^# BEGIN devbox$' "$path_rc")" -eq 1 ] ||
    fail "ensure_devbox_path did not write exactly one block"
[ "$(file_mode "$path_rc")" = 640 ] ||
    fail "ensure_devbox_path changed the rc mode"
grep -qx 'export EDITOR=vim' "$path_rc" ||
    fail "ensure_devbox_path dropped existing rc content"
grep -q "export PATH=\"$path_unit_root/home/.local/bin:" "$path_rc" ||
    fail "ensure_devbox_path wrote the wrong PATH entry"
HOME="$path_unit_root/home" SHELL=/bin/zsh PATH="/usr/bin:/bin" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    remove_devbox_path
' >/dev/null || fail "remove_devbox_path failed"
if grep -q '^# BEGIN devbox$' "$path_rc"; then
    fail "remove_devbox_path kept the block"
fi
grep -qx 'export EDITOR=vim' "$path_rc" ||
    fail "remove_devbox_path dropped existing rc content"
# Malformed markers are left untouched.
printf '# BEGIN devbox\n' >"$path_rc"
if HOME="$path_unit_root/home" SHELL=/bin/zsh PATH="/usr/bin:/bin" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    ensure_devbox_path "$HOME/.local/bin"
' >/dev/null 2>&1; then
    fail "ensure_devbox_path accepted malformed markers"
fi
[ "$(cat "$path_rc")" = "# BEGIN devbox" ] ||
    fail "ensure_devbox_path modified an rc with malformed markers"

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
