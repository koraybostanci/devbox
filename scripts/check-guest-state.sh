#!/bin/bash
# Sourced by check.sh after ROOT, validation_root, fail, and file_mode are set.

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
export GIT_NAME=\$(touch "$state_marker")
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
devbox_parse_state_file config config <"$fixture/config"
devbox_state_config_is_complete
[ "$POSTGRES_USER" = dev ]
[ "$POSTGRES_PORT" = 65535 ]
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
export GIT_NAME=\$(touch "$state_marker")
EOF
/bin/bash -c '
    set -Eeuo pipefail
    source "$1"
    devbox_seed_guest_state "$2"
' _ "$ROOT/provision/scripts/lib/state.sh" "$seed_directory" \
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
/bin/bash -c '
    set -Eeuo pipefail
    source "$1"
    devbox_seed_guest_state "$2"
' _ "$ROOT/provision/scripts/lib/state.sh" "$seed_directory" \
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
if /bin/bash -c '
    set -Eeuo pipefail
    source "$1"
    devbox_seed_guest_state "$2"
' _ "$ROOT/provision/scripts/lib/state.sh" "$incomplete_seed_directory" \
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
    TARGET:"$DEVBOX_DATA_ROOT/devbox-home") printf '%s\n' "$DEVBOX_DATA_ROOT" ;;
    TARGET:"$DEVBOX_GUEST_HOME") printf '%s\n' "$DEVBOX_GUEST_HOME" ;;
    FSTYPE:*) printf 'ext4\n' ;;
    SOURCE:"$DEVBOX_DATA_ROOT/devbox-home") printf '/dev/vdb\n' ;;
    SOURCE:"$DEVBOX_GUEST_HOME")
        if [ "${DEVBOX_BAD_HOME_SOURCE:-false}" = true ]; then
            printf '/dev/vdc[/devbox-home]\n'
        else
            printf '/dev/vdb[/devbox-home]\n'
        fi
        ;;
    FSROOT:"$DEVBOX_DATA_ROOT/devbox-home") printf '/\n' ;;
    FSROOT:"$DEVBOX_GUEST_HOME") printf '%s\n' "${DEVBOX_HOME_FSROOT:-/devbox-home}" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$mount_stub/findmnt"
mount_fixture="$validation_root/mount-fixture"
mkdir -p "$mount_fixture/data/devbox-home" "$mount_fixture/home"
PATH="$mount_stub:/usr/bin:/bin" ROOT="$ROOT" DEVBOX_DATA_ROOT="$mount_fixture/data" \
    DEVBOX_GUEST_HOME="$mount_fixture/home" /bin/bash -c '
    set -Eeuo pipefail
    source "$ROOT/provision/scripts/lib/state.sh"
    devbox_home_is_on_lima_data_disk "$DEVBOX_GUEST_HOME" \
        "$DEVBOX_DATA_ROOT/devbox-home" "$DEVBOX_DATA_ROOT"
' || fail "Lima data-disk home readiness check rejected the intended mount"
if PATH="$mount_stub:/usr/bin:/bin" ROOT="$ROOT" DEVBOX_DATA_ROOT="$mount_fixture/data" \
    DEVBOX_GUEST_HOME="$mount_fixture/home" DEVBOX_HOME_FSROOT=/ /bin/bash -c '
    source "$ROOT/provision/scripts/lib/state.sh"
    devbox_home_is_on_lima_data_disk "$DEVBOX_GUEST_HOME" \
        "$DEVBOX_DATA_ROOT/devbox-home" "$DEVBOX_DATA_ROOT"
'; then
    fail "Lima data-disk home readiness accepted the wrong bind source"
fi
lima_root_stub="$validation_root/lima-root-bin"
mkdir -p "$lima_root_stub"
printf '#!/bin/bash\nprintf "/\\n/boot\\n/mnt/lima-colima-devbox\\n"\n' >"$lima_root_stub/findmnt"
chmod +x "$lima_root_stub/findmnt"
[ "$(PATH="$lima_root_stub:/usr/bin:/bin" /bin/bash -c '
    source "$1"
    devbox_lima_data_root
' _ "$ROOT/provision/scripts/lib/state.sh")" = /mnt/lima-colima-devbox ] ||
    fail "the Lima data root was not selected from the ext4 mounts"
no_data_stub="$validation_root/no-data-bin"
mkdir -p "$no_data_stub"
printf '#!/bin/bash\nexit 0\n' >"$no_data_stub/findmnt"
chmod +x "$no_data_stub/findmnt"
if PATH="$no_data_stub:/usr/bin:/bin" DEVBOX_PROVISION_ROOT="$ROOT/provision" ROOT="$ROOT" \
    /bin/bash -c 'source "$ROOT/provision/scripts/system.sh"; relocate_guest_home' \
    >"$validation_root/no-data.out" 2>&1; then
    fail "guest-home setup silently accepted a missing Lima data disk"
fi
grep -q 'refusing to leave /home/devbox on the root disk' "$validation_root/no-data.out" ||
    fail "missing Lima data disk did not fail with a clear error"

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
ROOT="$ROOT" /bin/bash -c '
    set -Eeuo pipefail
    source "$ROOT/provision/scripts/lib/configure.sh"
    sync_managed_opencode_tree "$1" "$2" "$3"
    sync_managed_opencode_tree "$4" "$5" "$6"
' _ "$opencode_sync_root/source/agents" "$opencode_sync_root/target/agents" \
    "$opencode_sync_root/agents.manifest" "$opencode_sync_root/source/skills" \
    "$opencode_sync_root/target/skills" "$opencode_sync_root/skills.manifest" ||
    fail "OpenCode managed-file sync failed"
[ ! -e "$opencode_sync_root/target/agents/removed.md" ] || fail "stale managed agent was kept"
[ ! -e "$opencode_sync_root/target/skills/removed.md" ] || fail "stale managed skill was kept"
[ -f "$opencode_sync_root/target/agents/user-added.md" ] || fail "user-added agent file was removed"
[ -f "$opencode_sync_root/target/skills/user-added.md" ] || fail "user-added skill file was removed"
[ -f "$opencode_sync_root/target/agents/current.md" ] || fail "current managed agent was not copied"
[ -f "$opencode_sync_root/target/skills/current.md" ] || fail "current managed skill was not copied"
rm "$opencode_sync_root/source/agents/current.md" "$opencode_sync_root/source/skills/current.md"
ROOT="$ROOT" /bin/bash -c '
    set -Eeuo pipefail
    source "$ROOT/provision/scripts/lib/configure.sh"
    sync_managed_opencode_tree "$1" "$2" "$3"
    sync_managed_opencode_tree "$4" "$5" "$6"
' _ "$opencode_sync_root/source/agents" "$opencode_sync_root/target/agents" \
    "$opencode_sync_root/agents.manifest" "$opencode_sync_root/source/skills" \
    "$opencode_sync_root/target/skills" "$opencode_sync_root/skills.manifest" ||
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
ROOT="$ROOT" /bin/bash -c '
    set -Eeuo pipefail
    source "$ROOT/provision/scripts/lib/docker.sh"
    devbox_has_subid_ranges devbox "$1/valid" "$1/valid"
    for file in short low missing; do
        if devbox_has_subid_ranges devbox "$1/valid" "$1/$file"; then exit 1; fi
    done
' _ "$subid_root" || fail "subordinate UID/GID range checks failed"

# The host key is written as the guest user: private directory and file, one
# key line, and anything but a single non-empty line is rejected.
key_home="$validation_root/key-home"
mkdir -p "$key_home"
ROOT="$ROOT" /bin/bash -c '
    set -Eeuo pipefail
    source "$ROOT/provision/scripts/authorize-key.sh"
    printf "ssh-ed25519 AAAA devbox\n" | devbox_install_authorized_key "$1"
    printf "ssh-ed25519 BBBB devbox\n" | devbox_install_authorized_key "$1"
    if printf "one\ntwo\n" | devbox_install_authorized_key "$1" 2>/dev/null; then exit 1; fi
    if printf "" | devbox_install_authorized_key "$1" 2>/dev/null; then exit 1; fi
' _ "$key_home" || fail "authorized key installation accepted or rejected the wrong key"
[ "$(file_mode "$key_home/.ssh")" = 700 ] || fail "guest SSH directory has the wrong mode"
[ "$(file_mode "$key_home/.ssh/authorized_keys")" = 600 ] || fail "authorized_keys has the wrong mode"
[ "$(cat "$key_home/.ssh/authorized_keys")" = 'ssh-ed25519 BBBB devbox' ] ||
    fail "authorized_keys does not hold exactly the latest key"
[ -z "$(find "$key_home/.ssh" -name '.authorized_keys.*')" ] || fail "authorized key staging file was left behind"
