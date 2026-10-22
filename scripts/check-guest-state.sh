#!/bin/bash
# Sourced by check.sh after ROOT, validation_root, fail, and file_mode are set.
# Sourced-fixture model: `validation_root` and the helper functions exist only
# in check.sh, and the `|| fail` chains below always exit through fail(), so
# both info findings are declared once instead of suppressing them per line.
# shellcheck disable=SC2016,SC2154

# Standalone execution has no fixtures or helpers; insist on the gate.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'ERROR: scripts/check-guest-state.sh must be sourced by scripts/check.sh\n' >&2
    exit 1
fi

# Run provision-side fixture commands through one code path (ssh_unit-style
# helper): source the script path relative to provision/scripts, then call the
# remaining arguments as a command with the checkout root exported.
run_prov_lib() {
    # `ROOT="$ROOT"` re-asserts the exported checkout root; the expansions
    # still happen in this shell before /bin/bash is forked, so the tool's
    # note does not apply.
    # shellcheck disable=SC2097,SC2098
    ROOT="$ROOT" /bin/bash -c '
        set -Eeuo pipefail
        source "$ROOT/provision/scripts/$1"
        shift
        "$@"
    ' _ "$1" "${@:2}"
}

# Root state handling reads guest-writable config and secrets strictly as data.
if grep -qE '^[[:space:]]*(source|\.)[[:space:]]+.*\$(config|secrets)' provision/scripts/state.sh; then
    fail "root state.sh must not source guest-writable config or secrets"
fi
state_fixture="$validation_root/state-fixture"
mkdir -p "$state_fixture"
state_marker="$state_fixture/executed"
cat >"$state_fixture/config" <<EOF
export POSTGRES_USER="dev"
export POSTGRES_DB=dev
export POSTGRES_PORT=65535
export VALKEY_PORT=16379
export GIT_NAME="Devbox Fixture"
export GIT_EMAIL=fixture@devbox.invalid
export UNRELATED=\$(touch "$state_marker")
EOF
cat >"$state_fixture/secrets" <<EOF
export POSTGRES_PASSWORD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export VALKEY_PASSWORD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export UNRELATED=\$(touch "$state_marker")
EOF
chmod 600 "$state_fixture/config" "$state_fixture/secrets"
cat >"$validation_root/state-unit.sh" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
root="$1"
fixture="$2"
marker="$3"
source "$root/provision/scripts/lib/state.sh"
owner="$(id -un)"
group="$(id -gn)"
devbox_path_is_safe f "$fixture/config" "$owner" "$group" 600
devbox_path_is_safe f "$fixture/secrets" "$owner" "$group" 600
if devbox_path_is_safe f "$fixture/config" wrong-owner "$group" 600; then
    printf 'state file owner validation was bypassed\n' >&2
    exit 1
fi
unset POSTGRES_USER POSTGRES_DB POSTGRES_PORT VALKEY_PORT POSTGRES_PASSWORD VALKEY_PASSWORD
unset GIT_NAME GIT_EMAIL
devbox_parse_state_file config config <"$fixture/config"
devbox_state_config_is_complete
[ "$POSTGRES_USER" = dev ]
[ "$POSTGRES_PORT" = 65535 ]
# The Git identity in the same file is captured from it as literal data.
[ "$GIT_NAME" = "Devbox Fixture" ]
[ "$GIT_EMAIL" = fixture@devbox.invalid ]
devbox_parse_state_file secrets secrets <"$fixture/secrets"
[ "$POSTGRES_PASSWORD" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]
[ "$VALKEY_PASSWORD" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]
[ ! -e "$marker" ] || {
    printf 'shell text from a guest state fixture was executed\n' >&2
    exit 1
}
ln -s "$fixture/config" "$fixture/config-link"
if devbox_path_is_safe f "$fixture/config-link" "$owner" "$group" 600; then
    printf 'state file symlink validation was bypassed\n' >&2
    exit 1
fi
chmod 644 "$fixture/config"
if devbox_path_is_safe f "$fixture/config" "$owner" "$group" 600; then
    printf 'state file mode validation was bypassed\n' >&2
    exit 1
fi
chmod 600 "$fixture/config"
printf 'export POSTGRES_PORT=65536\n' >"$fixture/invalid-port"
if devbox_parse_state_file invalid-port config <"$fixture/invalid-port" 2>/dev/null; then
    printf 'state parser accepted a port above 65535\n' >&2
    exit 1
fi
printf 'export POSTGRES_USER=$(touch %s)\n' "$marker" >"$fixture/invalid-user"
if devbox_parse_state_file invalid-user config <"$fixture/invalid-user" 2>/dev/null; then
    printf 'state parser accepted shell syntax as a service value\n' >&2
    exit 1
fi
printf 'export GIT_NAME=$(touch %s)\n' "$marker" >"$fixture/invalid-git"
if devbox_parse_state_file invalid-git config <"$fixture/invalid-git" 2>/dev/null; then
    printf 'state parser accepted shell syntax as a Git identity\n' >&2
    exit 1
fi
# A host-seeded identity arrives %q-rendered: the backslash-space form
# unescapes to a real space and a backslashed escape sequence stays literal,
# while escapes the parser does not model fail loudly.
unset GIT_NAME
printf 'export GIT_NAME=Jane\\ Doe\n' >"$fixture/git-name-space"
devbox_parse_state_file git-name-space config <"$fixture/git-name-space"
[ "$GIT_NAME" = 'Jane Doe' ]
unset GIT_NAME
printf 'export GIT_NAME=a\\\\b\n' >"$fixture/git-name-backslash"
devbox_parse_state_file git-name-backslash config <"$fixture/git-name-backslash"
[ "$GIT_NAME" = 'a\b' ]
printf 'export GIT_NAME=\\z\n' >"$fixture/git-name-escape"
if devbox_parse_state_file git-name-escape config <"$fixture/git-name-escape" 2>/dev/null; then
    printf 'state parser rewrote an unsupported Git identity escape\n' >&2
    exit 1
fi
[ ! -e "$marker" ]
EOF
/bin/bash "$validation_root/state-unit.sh" "$ROOT" "$state_fixture" "$state_marker" ||
    fail "guest state parser safety tests failed"

seed_directory="$state_fixture/home/.config/devbox"
mkdir -p "$state_fixture/home"
cat >"$state_fixture/host-seed" <<EOF
export POSTGRES_USER=dev
export POSTGRES_DB=dev
export POSTGRES_PORT=15432
export GIT_NAME="Devbox Seed"
EOF
run_prov_lib lib/state.sh devbox_seed_guest_state "$seed_directory" \
    <"$state_fixture/host-seed" || fail "guest-owned config and secret seeding failed"
[ "$(file_mode "$seed_directory")" = 700 ] || fail "guest state directory has the wrong mode"
[ "$(file_mode "$(dirname "$seed_directory")")" = 700 ] ||
    fail "guest XDG config directory has the wrong mode"
[ "$(file_mode "$seed_directory/config")" = 600 ] || fail "guest config has the wrong mode"
[ "$(file_mode "$seed_directory/secrets")" = 600 ] || fail "guest secrets have the wrong mode"
seeded_config="$validation_root/seeded-config-before"
seeded_secrets="$validation_root/seeded-secrets-before"
cp "$seed_directory/config" "$seeded_config"
cp "$seed_directory/secrets" "$seeded_secrets"
printf 'export POSTGRES_USER=changed\nexport POSTGRES_DB=changed\nexport POSTGRES_PORT=5432\n' \
    >"$state_fixture/second-seed"
run_prov_lib lib/state.sh devbox_seed_guest_state "$seed_directory" \
    <"$state_fixture/second-seed" || fail "repeat guest state seeding failed"
cmp -s "$seeded_config" "$seed_directory/config" ||
    fail "guest-owned config was overwritten after its initial seed"
cmp -s "$seeded_secrets" "$seed_directory/secrets" ||
    fail "guest-owned secrets changed during repeat provisioning"

# An incomplete config already owned by the guest must not be replaced by the
# host seed; report the missing settings and leave the customized file intact.
incomplete_seed_directory="$state_fixture/incomplete-home/.config/devbox"
mkdir -p "$incomplete_seed_directory"
printf 'export POSTGRES_USER=guest-custom\n' >"$incomplete_seed_directory/config"
chmod 600 "$incomplete_seed_directory/config"
cp "$incomplete_seed_directory/config" "$validation_root/incomplete-config-before"
if run_prov_lib lib/state.sh devbox_seed_guest_state "$incomplete_seed_directory" \
    <"$state_fixture/host-seed" >"$state_fixture/incomplete-config.out" 2>&1; then
    fail "guest state seeding replaced an incomplete guest config"
fi
cmp -s "$validation_root/incomplete-config-before" "$incomplete_seed_directory/config" ||
    fail "failed guest state seeding changed the incomplete config"
[ "$(file_mode "$incomplete_seed_directory/config")" = 600 ] ||
    fail "failed guest state seeding changed the incomplete config mode"
grep -q 'existing guest config is incomplete; refusing to overwrite' \
    "$state_fixture/incomplete-config.out" ||
    fail "incomplete guest config failure was not reported clearly"
[ ! -e "$state_marker" ] || fail "shell text from a host seed was executed"

# Readiness must identify the bind mount's source as the Lima ext4 data-disk
# directory, and setup must refuse to leave the home on the root disk.
mount_stub="$validation_root/mount-bin"
mkdir -p "$mount_stub"
cat >"$mount_stub/findmnt" <<'EOF'
#!/bin/bash
field=
path=
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; field="${1:-}" ;;
        -T) shift; path="${1:-}" ;;
    esac
    shift || true
done
if [ -z "$path" ]; then
    [ "${DEVBOX_FINDMNT_EMPTY:-false}" = false ] && printf '%s\n' "$DEVBOX_DATA_ROOT"
    exit 0
fi
case "$field:$path" in
    TARGET:"$DEVBOX_DATA_ROOT") printf '%s\n' "$DEVBOX_DATA_ROOT" ;;
    TARGET:"$DEVBOX_DATA_ROOT/devbox-home")
        if [ "${DEVBOX_TARGET_IS_MOUNT:-false}" = true ]; then
            printf '%s\n' "$DEVBOX_DATA_ROOT/devbox-home"
        else
            printf '%s\n' "$DEVBOX_DATA_ROOT"
        fi
        ;;
    TARGET:"$DEVBOX_GUEST_HOME")
        if [ "${DEVBOX_STACKED_HOME:-false}" = true ]; then
            printf '%s\n%s\n' "$DEVBOX_GUEST_HOME" "$DEVBOX_GUEST_HOME"
        else
            printf '%s\n' "$DEVBOX_GUEST_HOME"
        fi
        ;;
    FSTYPE:*) printf 'ext4\n' ;;
    SOURCE:"$DEVBOX_DATA_ROOT") printf '/dev/vdb\n' ;;
    SOURCE:"$DEVBOX_DATA_ROOT/devbox-home")
        if [ "${DEVBOX_TARGET_IS_MOUNT:-false}" = true ]; then
            printf '/dev/vdb[/devbox-home]\n'
        else
            printf '/dev/vdb\n'
        fi
        ;;
    SOURCE:"$DEVBOX_GUEST_HOME")
        if [ "${DEVBOX_BAD_HOME_SOURCE:-false}" = true ]; then
            printf '/dev/vdc[/devbox-home]\n'
        elif [ "${DEVBOX_STACKED_HOME:-false}" = true ]; then
            printf '/dev/vda1[/mnt/lima-colima-devbox/devbox-home]\n/dev/vdb[/devbox-home]\n'
        else
            printf '/dev/vdb[/devbox-home]\n'
        fi
        ;;
    FSROOT:"$DEVBOX_DATA_ROOT") printf '/\n' ;;
    FSROOT:"$DEVBOX_DATA_ROOT/devbox-home")
        if [ "${DEVBOX_TARGET_IS_MOUNT:-false}" = true ]; then
            printf '/devbox-home\n'
        else
            printf '/\n'
        fi
        ;;
    FSROOT:"$DEVBOX_GUEST_HOME")
        if [ "${DEVBOX_STACKED_HOME:-false}" = true ]; then
            printf '/mnt/lima-colima-devbox/devbox-home\n/devbox-home\n'
        else
            printf '%s\n' "${DEVBOX_HOME_FSROOT:-/devbox-home}"
        fi
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$mount_stub/findmnt"
mount_fixture="$validation_root/mount-fixture"
mkdir -p "$mount_fixture/data/devbox-home" "$mount_fixture/home"
PATH="$mount_stub:/usr/bin:/bin" DEVBOX_DATA_ROOT="$mount_fixture/data" \
    DEVBOX_GUEST_HOME="$mount_fixture/home" run_prov_lib lib/state.sh \
    devbox_home_is_on_lima_data_disk "$mount_fixture/home" \
    "$mount_fixture/data/devbox-home" "$mount_fixture/data" ||
    fail "Lima data-disk home readiness check rejected the intended mount"
PATH="$mount_stub:/usr/bin:/bin" DEVBOX_DATA_ROOT="$mount_fixture/data" \
    DEVBOX_GUEST_HOME="$mount_fixture/home" DEVBOX_STACKED_HOME=true \
    DEVBOX_TARGET_IS_MOUNT=true run_prov_lib lib/state.sh \
    devbox_home_is_on_lima_data_disk "$mount_fixture/home" \
    "$mount_fixture/data/devbox-home" "$mount_fixture/data" ||
    fail "Lima data-disk home readiness rejected the visible mount in a stacked mount table"
if PATH="$mount_stub:/usr/bin:/bin" DEVBOX_DATA_ROOT="$mount_fixture/data" \
    DEVBOX_GUEST_HOME="$mount_fixture/home" DEVBOX_HOME_FSROOT=/ \
    run_prov_lib lib/state.sh devbox_home_is_on_lima_data_disk \
    "$mount_fixture/home" "$mount_fixture/data/devbox-home" "$mount_fixture/data"; then
    fail "Lima data-disk home readiness accepted the wrong bind source"
fi
lima_root_stub="$validation_root/lima-root-bin"
mkdir -p "$lima_root_stub"
printf '#!/bin/bash\nprintf "/\\n/boot\\n/mnt/lima-colima-devbox\\n"\n' >"$lima_root_stub/findmnt"
chmod +x "$lima_root_stub/findmnt"
[ "$(PATH="$lima_root_stub:/usr/bin:/bin" run_prov_lib lib/state.sh devbox_lima_data_root)" = /mnt/lima-colima-devbox ] ||
    fail "the Lima data root was not selected from the ext4 mounts"
no_data_stub="$validation_root/no-data-bin"
mkdir -p "$no_data_stub"
printf '#!/bin/bash\nexit 0\n' >"$no_data_stub/findmnt"
chmod +x "$no_data_stub/findmnt"
# The helper exports the checkout root; `run_prov_lib system.sh` sources the
# system phase script itself rather than a provision library.
if PATH="$no_data_stub:/usr/bin:/bin" DEVBOX_PROVISION_ROOT="$ROOT/provision" \
    run_prov_lib system.sh relocate_guest_home >"$validation_root/no-data.out" 2>&1; then
    fail "guest-home setup silently accepted a missing Lima data disk"
fi
grep -q 'refusing to leave /home/devbox on the root disk' "$validation_root/no-data.out" ||
    fail "missing Lima data disk did not fail with a clear error"

# Reject unsupported snap wait flags, require an external deadline, and stop
# before touching Chromium when the seed wait fails or times out.
chromium_unit_root="$validation_root/chromium-unit"
mkdir -p "$chromium_unit_root"
cat >"$chromium_unit_root/probe.sh" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
source "$DEVBOX_PROVISION_ROOT/scripts/system.sh"
systemctl() {
    [ "$*" = 'enable --now snapd.socket' ]
}
timeout() {
    printf 'timeout %s\n' "$*" >>"$CHROMIUM_CALLS"
    [ "$#" = 5 ] && [ "$1" = 45m ] || return 2
    shift
    "$@"
}
snap() {
    printf 'snap %s\n' "$*" >>"$CHROMIUM_CALLS"
    case "$*" in
        'wait system seed.loaded') return "$CHROMIUM_WAIT_STATUS" ;;
        'list chromium'|'refresh --hold chromium') return 0 ;;
        *) printf 'unsupported snap arguments: %s\n' "$*" >&2; return 64 ;;
    esac
}
install_guest_chromium
EOF
for chromium_wait_status in 0 1 124; do
    : >"$chromium_unit_root/calls"
    chromium_status=0
    DEVBOX_PROVISION_ROOT="$ROOT/provision" \
        CHROMIUM_CALLS="$chromium_unit_root/calls" CHROMIUM_WAIT_STATUS="$chromium_wait_status" \
        /bin/bash "$chromium_unit_root/probe.sh" >"$chromium_unit_root/output" 2>&1 || chromium_status=$?
    [ "$chromium_status" = "$chromium_wait_status" ] ||
        fail "Chromium provisioning returned $chromium_status for seed wait status $chromium_wait_status: $(cat "$chromium_unit_root/output")"
    printf '%s\n' 'timeout 45m snap wait system seed.loaded' 'snap wait system seed.loaded' \
        >"$chromium_unit_root/expected"
    if [ "$chromium_wait_status" = 0 ]; then
        printf '%s\n' 'snap list chromium' 'snap refresh --hold chromium' \
            >>"$chromium_unit_root/expected"
    fi
    cmp -s "$chromium_unit_root/expected" "$chromium_unit_root/calls" ||
        fail "Chromium provisioning used an unbounded seed wait or continued after wait failure ($chromium_wait_status)"
done

# Managed agent/skill manifests remove stale provisioned files without taking
# ownership of unrelated files in the guest user's OpenCode directories.
opencode_sync_root="$validation_root/opencode-sync"
mkdir -p "$opencode_sync_root/source/agents" "$opencode_sync_root/source/skills" \
    "$opencode_sync_root/target/agents" "$opencode_sync_root/target/skills"
printf 'new agent\n' >"$opencode_sync_root/source/agents/current.md"
printf 'new skill\n' >"$opencode_sync_root/source/skills/current.md"
printf 'stale managed agent\n' >"$opencode_sync_root/target/agents/removed.md"
printf 'user agent\n' >"$opencode_sync_root/target/agents/user-added.md"
printf 'stale managed skill\n' >"$opencode_sync_root/target/skills/removed.md"
printf 'user skill\n' >"$opencode_sync_root/target/skills/user-added.md"
printf 'removed.md\n' >"$opencode_sync_root/agents.manifest"
printf 'removed.md\n' >"$opencode_sync_root/skills.manifest"
run_prov_lib lib/configure.sh sync_managed_opencode_tree \
    "$opencode_sync_root/source/agents" "$opencode_sync_root/target/agents" \
    "$opencode_sync_root/agents.manifest" ||
    fail "OpenCode managed-file sync failed"
run_prov_lib lib/configure.sh sync_managed_opencode_tree \
    "$opencode_sync_root/source/skills" "$opencode_sync_root/target/skills" \
    "$opencode_sync_root/skills.manifest" ||
    fail "OpenCode managed-file sync failed"
[ ! -e "$opencode_sync_root/target/agents/removed.md" ] || fail "stale managed agent was kept"
[ ! -e "$opencode_sync_root/target/skills/removed.md" ] || fail "stale managed skill was kept"
[ -f "$opencode_sync_root/target/agents/user-added.md" ] || fail "user-added agent file was removed"
[ -f "$opencode_sync_root/target/skills/user-added.md" ] || fail "user-added skill file was removed"
[ -f "$opencode_sync_root/target/agents/current.md" ] || fail "current managed agent was not copied"
[ -f "$opencode_sync_root/target/skills/current.md" ] || fail "current managed skill was not copied"
rm "$opencode_sync_root/source/agents/current.md" "$opencode_sync_root/source/skills/current.md"
run_prov_lib lib/configure.sh sync_managed_opencode_tree \
    "$opencode_sync_root/source/agents" "$opencode_sync_root/target/agents" \
    "$opencode_sync_root/agents.manifest" ||
    fail "OpenCode managed-file cleanup after source removal failed"
run_prov_lib lib/configure.sh sync_managed_opencode_tree \
    "$opencode_sync_root/source/skills" "$opencode_sync_root/target/skills" \
    "$opencode_sync_root/skills.manifest" ||
    fail "OpenCode managed-file cleanup after source removal failed"
[ ! -e "$opencode_sync_root/target/agents/current.md" ] || fail "removed managed agent was kept"
[ ! -e "$opencode_sync_root/target/skills/current.md" ] || fail "removed managed skill was kept"
[ -f "$opencode_sync_root/target/agents/user-added.md" ] || fail "user agent was removed on a later sync"
[ -f "$opencode_sync_root/target/skills/user-added.md" ] || fail "user skill was removed on a later sync"

# Rootless Docker needs at least 65,536 subordinate IDs, never below 100000.
subid_root="$validation_root/subordinate-ids"
mkdir -p "$subid_root"
printf 'lima:524288:1073741824\ndevbox:100000:65536\n' >"$subid_root/valid"
printf 'devbox:100000:65535\n' >"$subid_root/short"
printf 'devbox:99999:65536\n' >"$subid_root/low"
printf 'other:100000:65536\n' >"$subid_root/missing"
run_prov_lib lib/docker.sh devbox_has_subid_ranges devbox \
    "$subid_root/valid" "$subid_root/valid" ||
    fail "subordinate UID/GID range checks failed"
for subid_file in short low missing; do
    if run_prov_lib lib/docker.sh devbox_has_subid_ranges devbox \
        "$subid_root/valid" "$subid_root/$subid_file"; then
        fail "subordinate UID/GID check accepted an invalid range: $subid_file"
    fi
done

# The host key is written as the guest user: private directory and file, one
# key line, and anything but a single non-empty line is rejected.
key_home="$validation_root/key-home"
mkdir -p "$key_home"
printf 'ssh-ed25519 AAAA devbox\n' | run_prov_lib authorize-key.sh \
    devbox_install_authorized_key "$key_home" ||
    fail "authorized key installation accepted or rejected the wrong key"
printf 'ssh-ed25519 BBBB devbox\n' | run_prov_lib authorize-key.sh \
    devbox_install_authorized_key "$key_home" ||
    fail "authorized key installation accepted or rejected the wrong key"
if printf 'one\ntwo\n' | run_prov_lib authorize-key.sh \
    devbox_install_authorized_key "$key_home" 2>/dev/null; then
    fail "authorized key installation accepted multiple lines"
fi
if printf '' | run_prov_lib authorize-key.sh \
    devbox_install_authorized_key "$key_home" 2>/dev/null; then
    fail "authorized key installation accepted an empty key"
fi
[ "$(file_mode "$key_home/.ssh")" = 700 ] || fail "guest SSH directory has the wrong mode"
[ "$(file_mode "$key_home/.ssh/authorized_keys")" = 600 ] || fail "authorized_keys has the wrong mode"
[ "$(cat "$key_home/.ssh/authorized_keys")" = 'ssh-ed25519 BBBB devbox' ] ||
    fail "authorized_keys does not hold exactly the latest key"
[ -z "$(find "$key_home/.ssh" -name '.authorized_keys.*')" ] || fail "authorized key staging file was left behind"
