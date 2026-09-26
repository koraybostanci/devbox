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
devbox_state_file_is_safe "$fixture/config" "$owner" "$group" 600
devbox_state_file_is_safe "$fixture/secrets" "$owner" "$group" 600
if devbox_state_file_is_safe "$fixture/config" wrong-owner "$group" 600; then
    printf 'state file owner validation was bypassed\n' >&2
    exit 1
fi
unset POSTGRES_USER POSTGRES_DB POSTGRES_PORT VALKEY_PORT POSTGRES_PASSWORD VALKEY_PASSWORD
devbox_parse_state_file "$fixture/config" config
devbox_state_config_is_complete
[ "$POSTGRES_USER" = dev ]
[ "$POSTGRES_PORT" = 65535 ]
devbox_parse_state_file "$fixture/secrets" secrets
[ "$POSTGRES_PASSWORD" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]
[ "$VALKEY_PASSWORD" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]
[ ! -e "$marker" ] || {
    printf 'shell text from a guest state fixture was executed\n' >&2
    exit 1
}
ln -s "$fixture/config" "$fixture/config-link"
if devbox_state_file_is_safe "$fixture/config-link" "$owner" "$group" 600; then
    printf 'state file symlink validation was bypassed\n' >&2
    exit 1
fi
chmod 644 "$fixture/config"
if devbox_state_file_is_safe "$fixture/config" "$owner" "$group" 600; then
    printf 'state file mode validation was bypassed\n' >&2
    exit 1
fi
chmod 600 "$fixture/config"
printf 'export POSTGRES_PORT=65536\n' >"$fixture/invalid-port"
if devbox_parse_state_file "$fixture/invalid-port" config 2>/dev/null; then
    printf 'state parser accepted a port above 65535\n' >&2
    exit 1
fi
printf 'export POSTGRES_USER=$(touch %s)\n' "$marker" >"$fixture/invalid-user"
if devbox_parse_state_file "$fixture/invalid-user" config 2>/dev/null; then
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

# Home migration resumes over a partially copied target, while readiness must
# identify the bind mount's source as the Lima ext4 data-disk directory.
home_migration_root="$validation_root/home-migration"
mkdir -p "$home_migration_root/source/nested" "$home_migration_root/target"
printf 'complete source data\n' >"$home_migration_root/source/file"
printf 'nested data\n' >"$home_migration_root/source/nested/file"
printf 'partial' >"$home_migration_root/target/file"
printf 'keep target-only data\n' >"$home_migration_root/target/target-only"
DEVBOX_PROVISION_ROOT="$ROOT/provision" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/provision/scripts/system.sh"
    devbox_migrate_guest_home_contents "$1" "$2"
' _ "$home_migration_root/source" "$home_migration_root/target" ||
    fail "retry-safe guest home migration failed"
[ "$(cat "$home_migration_root/target/file")" = 'complete source data' ] ||
    fail "home migration did not replace the partial file copy"
[ "$(cat "$home_migration_root/target/nested/file")" = 'nested data' ] ||
    fail "home migration did not copy nested data"
[ "$(cat "$home_migration_root/target/target-only")" = 'keep target-only data' ] ||
    fail "home migration removed data already present on the data disk"
[ -z "$(find "$home_migration_root/source" -mindepth 1 -print -quit)" ] ||
    fail "home migration did not clear the root-disk source after copying"

# A partial copy may already contain a legitimate source symlink. Retrying
# must preserve it while completing the remaining entries.
matching_symlink_migration_root="$validation_root/home-migration-matching-symlink"
mkdir -p "$matching_symlink_migration_root/source/.cache" \
    "$matching_symlink_migration_root/target/.cache"
printf 'copied cache payload\n' >"$matching_symlink_migration_root/source/.cache/payload"
ln -s payload "$matching_symlink_migration_root/source/.cache/current"
ln -s payload "$matching_symlink_migration_root/target/.cache/current"
printf 'remaining source data\n' >"$matching_symlink_migration_root/source/remaining"
DEVBOX_PROVISION_ROOT="$ROOT/provision" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/provision/scripts/system.sh"
    devbox_migrate_guest_home_contents "$1" "$2"
' _ "$matching_symlink_migration_root/source" "$matching_symlink_migration_root/target" ||
    fail "home migration rejected a matching partially copied source symlink"
[ "$(readlink "$matching_symlink_migration_root/target/.cache/current")" = payload ] ||
    fail "home migration changed a matching destination symlink"
[ "$(cat "$matching_symlink_migration_root/target/.cache/current")" = 'copied cache payload' ] ||
    fail "home migration did not finish copying the matching symlink's referent"
[ -f "$matching_symlink_migration_root/target/remaining" ] ||
    fail "home migration did not copy entries alongside a matching symlink"
[ -z "$(find "$matching_symlink_migration_root/source" -mindepth 1 -print -quit)" ] ||
    fail "home migration did not clear the source after retrying a matching symlink"

# A destination-only symlink has no source entry to collide with. Migration
# must preserve the link and its referent without following the link.
target_only_symlink_root="$validation_root/home-migration-target-only-symlink"
mkdir -p "$target_only_symlink_root/source" "$target_only_symlink_root/target" \
    "$target_only_symlink_root/referent"
printf 'new source data\n' >"$target_only_symlink_root/source/file"
printf 'target-only referent data\n' >"$target_only_symlink_root/referent/file"
cp "$target_only_symlink_root/referent/file" "$target_only_symlink_root/referent-before"
ln -s "$target_only_symlink_root/referent/file" \
    "$target_only_symlink_root/target/target-only-link"
target_only_link_before="$(readlink "$target_only_symlink_root/target/target-only-link")"
DEVBOX_PROVISION_ROOT="$ROOT/provision" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/provision/scripts/system.sh"
    devbox_migrate_guest_home_contents "$1" "$2"
' _ "$target_only_symlink_root/source" "$target_only_symlink_root/target" ||
    fail "home migration rejected a destination-only symlink"
[ -L "$target_only_symlink_root/target/target-only-link" ] ||
    fail "home migration replaced a destination-only symlink"
[ "$(readlink "$target_only_symlink_root/target/target-only-link")" = "$target_only_link_before" ] ||
    fail "home migration changed a destination-only symlink"
cmp -s "$target_only_symlink_root/referent-before" "$target_only_symlink_root/referent/file" ||
    fail "home migration changed a destination-only symlink referent"
[ "$(cat "$target_only_symlink_root/target/file")" = 'new source data' ] ||
    fail "home migration did not copy source data alongside a destination-only symlink"
[ -z "$(find "$target_only_symlink_root/source" -mindepth 1 -print -quit)" ] ||
    fail "home migration did not clear the source after preserving a destination-only symlink"

# A failed copy must not clean up any of the root-disk source entries.
failed_migration_root="$validation_root/home-migration-copy-failure"
mkdir -p "$failed_migration_root/source/collision" "$failed_migration_root/target"
printf 'source file must remain\n' >"$failed_migration_root/source/preserved"
printf 'source directory must remain\n' >"$failed_migration_root/source/collision/file"
printf 'blocking target file\n' >"$failed_migration_root/target/collision"
if DEVBOX_PROVISION_ROOT="$ROOT/provision" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/provision/scripts/system.sh"
    devbox_migrate_guest_home_contents "$1" "$2"
' _ "$failed_migration_root/source" "$failed_migration_root/target" \
    >"$failed_migration_root/migration.out" 2>&1; then
    fail "home migration accepted an incompatible destination entry"
fi
[ "$(cat "$failed_migration_root/source/preserved")" = 'source file must remain' ] ||
    fail "failed home migration removed a root-disk source file"
[ "$(cat "$failed_migration_root/source/collision/file")" = 'source directory must remain' ] ||
    fail "failed home migration removed a root-disk source directory"
[ "$(cat "$failed_migration_root/target/collision")" = 'blocking target file' ] ||
    fail "failed home migration changed the incompatible target entry"

# A destination symlink must be rejected before copying; its referent and the
# root-disk source must remain intact.
symlink_migration_root="$validation_root/home-migration-symlink"
mkdir -p "$symlink_migration_root/source" "$symlink_migration_root/target" \
    "$symlink_migration_root/referent"
printf 'root-disk source data\n' >"$symlink_migration_root/source/file"
printf 'referent must stay unchanged\n' >"$symlink_migration_root/referent/file"
ln -s "$symlink_migration_root/referent/file" "$symlink_migration_root/target/file"
if DEVBOX_PROVISION_ROOT="$ROOT/provision" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/provision/scripts/system.sh"
    devbox_migrate_guest_home_contents "$1" "$2"
' _ "$symlink_migration_root/source" "$symlink_migration_root/target" \
    >"$symlink_migration_root/migration.out" 2>&1; then
    fail "home migration accepted a destination symlink"
fi
[ "$(cat "$symlink_migration_root/referent/file")" = 'referent must stay unchanged' ] ||
    fail "home migration modified a destination symlink referent"
[ -f "$symlink_migration_root/source/file" ] ||
    fail "home migration deleted its source after rejecting a destination symlink"
[ -L "$symlink_migration_root/target/file" ] ||
    fail "home migration replaced the rejected destination symlink"
grep -q 'destination contains a symlink' "$symlink_migration_root/migration.out" ||
    fail "home migration did not report the destination symlink"

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
    source "$ROOT/provision/scripts/lib/state.sh"
    [ "$(devbox_lima_data_root)" = "$DEVBOX_DATA_ROOT" ]
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
no_data_stub="$validation_root/no-data-bin"
mkdir -p "$no_data_stub"
printf '#!/bin/bash\nexit 0\n' >"$no_data_stub/findmnt"
chmod +x "$no_data_stub/findmnt"
if PATH="$no_data_stub:/usr/bin:/bin" DEVBOX_PROVISION_ROOT="$ROOT/provision" ROOT="$ROOT" \
    /bin/bash -c 'source "$ROOT/provision/scripts/system.sh"; relocate_guest_home devbox' \
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
