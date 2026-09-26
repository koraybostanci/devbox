#!/bin/bash
# Data-only helpers for guest state and the Lima-backed home directory.

devbox_state_file_owner() {
    if [ "$(uname -s)" = Darwin ]; then
        stat -f '%Su' "$1"
    else
        stat -c '%U' "$1"
    fi
}

devbox_state_file_group() {
    if [ "$(uname -s)" = Darwin ]; then
        stat -f '%Sg' "$1"
    else
        stat -c '%G' "$1"
    fi
}

devbox_state_file_mode() {
    if [ "$(uname -s)" = Darwin ]; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

devbox_state_file_is_safe() {
    local path="$1" expected_owner="$2" expected_group="$3" expected_mode="$4"
    local owner group mode

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    owner="$(devbox_state_file_owner "$path")" || return 1
    group="$(devbox_state_file_group "$path")" || return 1
    mode="$(devbox_state_file_mode "$path")" || return 1
    [ "$owner" = "$expected_owner" ] && [ "$group" = "$expected_group" ] &&
        [ "$mode" = "$expected_mode" ]
}

devbox_state_directory_is_safe() {
    local path="$1" expected_owner="$2" expected_group="$3" expected_mode="$4"
    local owner group mode

    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    owner="$(devbox_state_file_owner "$path")" || return 1
    group="$(devbox_state_file_group "$path")" || return 1
    mode="$(devbox_state_file_mode "$path")" || return 1
    [ "$owner" = "$expected_owner" ] && [ "$group" = "$expected_group" ] &&
        [ "$mode" = "$expected_mode" ]
}

devbox_state_valid_port() {
    local port="$1"

    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ]
}

# Read only the service values needed by root as literal data. Other valid
# assignments (for example the guest Git identity) are ignored; no input is
# ever evaluated as shell code.
devbox_parse_state_file() {
    local path="$1" kind="$2" line key value line_number=0 seen_keys=" "

    case "$kind" in
        config | secrets) ;;
        *) printf 'ERROR: invalid devbox state file kind: %s\n' "$kind" >&2; return 1 ;;
    esac

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]]; then
            printf 'ERROR: invalid assignment in %s:%s\n' "$path" "$line_number" >&2
            return 1
        fi
        key="${BASH_REMATCH[2]}"
        case "$kind:$key" in
            config:POSTGRES_USER | config:POSTGRES_DB | config:POSTGRES_PORT | config:VALKEY_PORT) ;;
            secrets:POSTGRES_PASSWORD | secrets:VALKEY_PASSWORD) ;;
            *) continue ;;
        esac
        case "$seen_keys" in
            *" $key "*)
                printf 'ERROR: duplicate %s in %s:%s\n' "$key" "$path" "$line_number" >&2
                return 1
                ;;
        esac
        seen_keys="$seen_keys$key "

        value="${line#*=}"
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac

        case "$kind:$key" in
            config:POSTGRES_USER | config:POSTGRES_DB)
                [[ "$value" =~ ^[A-Za-z0-9_.-]{1,63}$ ]] || {
                    printf 'ERROR: invalid %s in %s:%s\n' "$key" "$path" "$line_number" >&2
                    return 1
                }
                ;;
            config:POSTGRES_PORT | config:VALKEY_PORT)
                devbox_state_valid_port "$value" || {
                    printf 'ERROR: %s in %s:%s must be a port from 1 to 65535\n' \
                        "$key" "$path" "$line_number" >&2
                    return 1
                }
                ;;
            secrets:POSTGRES_PASSWORD | secrets:VALKEY_PASSWORD)
                [[ "$value" =~ ^[A-Fa-f0-9]{32,128}$ ]] || {
                    printf 'ERROR: invalid %s in %s:%s\n' "$key" "$path" "$line_number" >&2
                    return 1
                }
                ;;
        esac
        printf -v "$key" '%s' "$value"
    done <"$path"
}

devbox_state_config_is_complete() {
    [ -n "${POSTGRES_USER:-}" ] && [ -n "${POSTGRES_DB:-}" ] &&
        [ -n "${POSTGRES_PORT:-}" ]
}

# Seed user-owned config and secrets without root ever writing into the
# guest-writable home. stdin is the host seed; it is copied verbatim as data,
# then checked by the same allowlisted parser used by the root state phase.
devbox_seed_guest_state() {
    local directory="$1" config_root config secrets owner group
    local config_exists=false config_temporary="" secrets_temporary=""

    owner="$(id -un)" || return 1
    group="$(id -gn)" || return 1
    config_root="$(dirname "$directory")"
    config="$directory/config"
    secrets="$directory/secrets"
    unset POSTGRES_USER POSTGRES_DB POSTGRES_PORT VALKEY_PORT POSTGRES_PASSWORD VALKEY_PASSWORD

    [ ! -L "$config_root" ] && { [ ! -e "$config_root" ] || [ -d "$config_root" ]; } || return 1
    [ ! -L "$directory" ] && { [ ! -e "$directory" ] || [ -d "$directory" ]; } || return 1
    mkdir -p "$config_root" "$directory" || return 1
    chmod 700 "$config_root" "$directory" || return 1
    devbox_state_directory_is_safe "$config_root" "$owner" "$group" 700 || return 1
    devbox_state_directory_is_safe "$directory" "$owner" "$group" 700 || return 1
    umask 077

    if [ -e "$config" ] || [ -L "$config" ]; then
        devbox_state_file_is_safe "$config" "$owner" "$group" 600 || return 1
        unset POSTGRES_USER POSTGRES_DB POSTGRES_PORT VALKEY_PORT
        devbox_parse_state_file "$config" config || return 1
        if ! devbox_state_config_is_complete; then
            printf 'ERROR: existing guest config is incomplete; refusing to overwrite: %s\n' \
                "$config" >&2
            return 1
        fi
        config_exists=true
    fi

    if [ "$config_exists" = true ]; then
        cat >/dev/null || return 1
    else
        config_temporary="$(mktemp "$directory/.config.XXXXXX")" || return 1
        if ! cat >"$config_temporary"; then
            rm -f -- "$config_temporary"
            return 1
        fi
        unset POSTGRES_USER POSTGRES_DB POSTGRES_PORT VALKEY_PORT
        if ! devbox_parse_state_file "$config_temporary" config ||
            ! devbox_state_config_is_complete; then
            rm -f -- "$config_temporary"
            return 1
        fi
        chmod 600 "$config_temporary" && mv -f -- "$config_temporary" "$config" || {
            rm -f -- "$config_temporary"
            return 1
        }
        config_temporary=""
    fi

    unset POSTGRES_PASSWORD VALKEY_PASSWORD
    if [ -e "$secrets" ] || [ -L "$secrets" ]; then
        devbox_state_file_is_safe "$secrets" "$owner" "$group" 600 || return 1
        devbox_parse_state_file "$secrets" secrets || return 1
    fi
    if [ -z "${POSTGRES_PASSWORD:-}" ] || [ -z "${VALKEY_PASSWORD:-}" ]; then
        POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
        VALKEY_PASSWORD="${VALKEY_PASSWORD:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
        secrets_temporary="$(mktemp "$directory/.secrets.XXXXXX")" || return 1
        if ! {
            printf 'export POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
            printf 'export VALKEY_PASSWORD=%s\n' "$VALKEY_PASSWORD"
        } >"$secrets_temporary"; then
            rm -f -- "$secrets_temporary"
            return 1
        fi
        chmod 600 "$secrets_temporary" && mv -f -- "$secrets_temporary" "$secrets" || {
            rm -f -- "$secrets_temporary"
            return 1
        }
        secrets_temporary=""
    fi
}

devbox_lima_data_root() {
    findmnt -rno TARGET -t ext4 2>/dev/null |
        awk 'index($0, "/mnt/lima-") == 1 { print; exit }'
}

# Confirm that the guest home is the expected bind mount into Lima's ext4 data
# disk, not merely a directory that happens to exist on the fixed-size root.
devbox_home_is_on_lima_data_disk() {
    local guest_home="$1" target="$2" data_root="$3"
    local data_target home_target data_source home_source data_device home_device
    local data_fsroot home_fsroot expected_fsroot

    [ "$target" = "$data_root/devbox-home" ] || return 1
    [ -d "$guest_home" ] && [ ! -L "$guest_home" ] || return 1
    [ -d "$target" ] && [ ! -L "$target" ] || return 1
    data_target="$(findmnt -n -o TARGET -T "$target" 2>/dev/null)" || return 1
    [ "$data_target" = "$data_root" ] || return 1
    [ "$(findmnt -n -o FSTYPE -T "$target" 2>/dev/null)" = ext4 ] || return 1
    home_target="$(findmnt -n -o TARGET -T "$guest_home" 2>/dev/null)" || return 1
    [ "$home_target" = "$guest_home" ] || return 1

    data_source="$(findmnt -n -o SOURCE -T "$target" 2>/dev/null)" || return 1
    home_source="$(findmnt -n -o SOURCE -T "$guest_home" 2>/dev/null)" || return 1
    data_device="${data_source%%\[*}"
    home_device="${home_source%%\[*}"
    [ -n "$data_device" ] && [ "$home_device" = "$data_device" ] || return 1

    data_fsroot="$(findmnt -n -o FSROOT -T "$target" 2>/dev/null)" || return 1
    home_fsroot="$(findmnt -n -o FSROOT -T "$guest_home" 2>/dev/null)" || return 1
    if [ "$data_fsroot" = / ]; then
        expected_fsroot=/devbox-home
    else
        expected_fsroot="${data_fsroot%/}/devbox-home"
    fi
    [ "$home_fsroot" = "$expected_fsroot" ]
}

# Copy a root-disk home onto the data disk. Root drops to devbox before it
# inspects tree contents or writes either tree: chmodding only the destination
# root cannot revoke writable descendants or already-open handles, and the
# guest can restore its mode. Reject unsafe destination symlinks before copying.
# Copying top-level entries separately keeps cp -a from changing the target
# directory's mode and retains data that exists only on the data disk.
devbox_migrate_guest_home_contents() {
    local source="$1" target="$2"
    local destination_symlink="" first_source_entry="" state_library
    local source_root target_root source_prefix target_prefix destination_relative
    local source_parent source_remaining source_component source_symlink source_path_state

    [ ! -L "$source" ] && [ -d "$source" ] || return 1
    [ ! -L "$target" ] && [ -d "$target" ] || return 1

    if [ "$EUID" -eq 0 ]; then
        state_library="${BASH_SOURCE[0]}"
        case "$state_library" in
            /*) ;;
            *) state_library="$PWD/$state_library" ;;
        esac
        if ! sudo -u devbox -H -- /bin/bash -c '
            set -Eeuo pipefail
            source "$1"
            devbox_migrate_guest_home_contents "$2" "$3"
        ' _ "$state_library" "$source" "$target"; then
            return 1
        fi
        return 0
    fi

    # The parent directory is handed to devbox by the root provisioner. Set
    # its mode only after privilege has been dropped, and before inspecting
    # descendants or copying any contents.
    if ! chmod 700 "$target"; then
        printf 'ERROR: could not prepare guest-owned home migration target: %s\n' \
            "$target" >&2
        return 1
    fi

    # Find does not follow symlinks by default. Allow links already copied from
    # the source at the same relative path with the same target, plus links at
    # paths absent from the source. Other destination links could redirect a
    # source entry during cp.
    source_root="$source"
    target_root="$target"
    while [ "$source_root" != / ] && [[ "$source_root" == */ ]]; do
        source_root="${source_root%/}"
    done
    while [ "$target_root" != / ] && [[ "$target_root" == */ ]]; do
        target_root="${target_root%/}"
    done
    source_prefix="$source_root/"
    target_prefix="$target_root/"
    [ "$source_root" = / ] && source_prefix=/
    [ "$target_root" = / ] && target_prefix=/

    if ! (
        set -o pipefail
        find "$target" -type l -print0 |
            while IFS= read -r -d '' destination_symlink; do
                case "$destination_symlink" in
                    "$target_prefix"*)
                        destination_relative="${destination_symlink#"$target_prefix"}"
                        ;;
                    *)
                        printf 'ERROR: could not identify destination symlink path: %s\n' \
                            "$destination_symlink" >&2
                        exit 1
                        ;;
                esac

                # Do not let a source-side symlink ancestor make a link from
                # outside the source tree appear to match this destination.
                source_parent="$source_root"
                source_remaining="$destination_relative"
                source_path_state=present
                while [[ "$source_remaining" == */* ]]; do
                    source_component="${source_remaining%%/*}"
                    source_remaining="${source_remaining#*/}"
                    if [ "$source_parent" = / ]; then
                        source_parent="/$source_component"
                    else
                        source_parent="$source_parent/$source_component"
                    fi
                    if [ -L "$source_parent" ]; then
                        source_path_state=unsafe
                        break
                    elif [ ! -e "$source_parent" ]; then
                        source_path_state=missing
                        break
                    elif [ ! -d "$source_parent" ]; then
                        source_path_state=unsafe
                        break
                    fi
                done
                if [ "$source_path_state" = unsafe ]; then
                    printf 'ERROR: refusing guest home migration; destination contains a symlink that does not match the source: %s\n' \
                        "$destination_symlink" >&2
                    exit 1
                elif [ "$source_path_state" = missing ]; then
                    # This destination-only link cannot collide with a source
                    # entry. Leave it and its referent untouched.
                    continue
                fi

                if [ "$source_parent" = / ]; then
                    source_symlink="/$source_remaining"
                else
                    source_symlink="$source_parent/$source_remaining"
                fi

                if [ -L "$source_symlink" ]; then
                    if cmp -s <(readlink "$source_symlink") \
                        <(readlink "$destination_symlink"); then
                        continue
                    fi
                    printf 'ERROR: refusing guest home migration; destination contains a symlink that does not match the source: %s\n' \
                        "$destination_symlink" >&2
                    exit 1
                elif [ -e "$source_symlink" ]; then
                    printf 'ERROR: refusing guest home migration; destination contains a symlink that does not match the source: %s\n' \
                        "$destination_symlink" >&2
                    exit 1
                fi
            done
    ); then
        return 1
    fi

    if ! first_source_entry="$(find "$source" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"; then
        printf 'ERROR: could not inspect root-disk guest home: %s\n' "$source" >&2
        return 1
    fi

    if [ -n "$first_source_entry" ]; then
        printf 'Moving existing guest home onto the data disk...\n'
        # cp -a is safely repeatable after a partial copy. Do not remove any
        # root-disk entries unless every top-level entry copied successfully.
        if ! find "$source" -mindepth 1 -maxdepth 1 \
            -exec sh -c 'target=$1; shift; cp -a -- "$@" "$target/"' _ "$target" '{}' +; then
            printf 'ERROR: guest home copy to the data disk failed; keeping the root-disk source\n' >&2
            return 1
        elif ! find "$source" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; then
            printf 'ERROR: could not clear the copied root-disk guest home: %s\n' "$source" >&2
            return 1
        fi
    fi

    return 0
}
