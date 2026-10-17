#!/bin/bash
# Data-only helpers for guest state and the Lima-backed home directory.

# devbox_path_is_safe <f|d> PATH OWNER GROUP MODE: a regular file or directory,
# never a symlink, with exactly this ownership and mode.
# The test operator is built from the `<f|d>` contract; shellcheck cannot
# parse the concatenation inside `[`, so `test` receives it as one word.
devbox_path_is_safe() {
    local type="$1" path="$2" metadata

    [ ! -L "$path" ] && test "-$type" "$path" || return 1
    if [ "$(uname -s)" = Darwin ]; then
        metadata="$(stat -f '%Su %Sg %Lp' "$path")" || return 1
    else
        metadata="$(stat -c '%U %G %a' "$path")" || return 1
    fi
    [ "$metadata" = "$3 $4 $5" ]
}

devbox_state_valid_port() {
    local port="$1"

    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ]
}

# Read the service values root needs from stdin as literal data; LABEL names
# the source in errors. In the config kind, the guest Git identity is captured
# with the service values so the unprivileged tools phase can consume the same
# file as data. Other valid assignments are ignored, and no input is ever
# evaluated as shell code.
devbox_parse_state_file() {
    local label="$1" kind="$2" line key value line_number=0 seen_keys=" "

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]]; then
            printf 'ERROR: invalid assignment in %s:%s\n' "$label" "$line_number" >&2
            return 1
        fi
        key="${BASH_REMATCH[2]}"
        case "$kind:$key" in
            config:POSTGRES_USER | config:POSTGRES_DB | config:POSTGRES_PORT | \
                config:VALKEY_PORT | config:GIT_NAME | config:GIT_EMAIL) ;;
            secrets:POSTGRES_PASSWORD | secrets:VALKEY_PASSWORD) ;;
            *) continue ;;
        esac
        case "$seen_keys" in
            *" $key "*)
                printf 'ERROR: duplicate %s in %s:%s\n' "$key" "$label" "$line_number" >&2
                return 1
                ;;
        esac
        seen_keys="$seen_keys$key "

        value="${line#*=}"
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac

        case "$key" in
            GIT_NAME | GIT_EMAIL)
                # Host seeding renders the identity with
                # `printf 'export %s=%q\n'`, so a space arrives as a
                # backslash-space pair and a literal backslash as a double
                # backslash. Reverse exactly those two mechanical forms as
                # data on printable input: park each double backslash with a
                # control-character sentinel first so it survives adjacency
                # with a backslash-space form, then turn backslash-space into
                # a space. Any other backslash escape (`\z`, octal, `\;`, ...)
                # is rejected loudly rather
                # than rewritten, and the sentinel cannot collide with input
                # because non-printable input is turned away before it exists.
                if ! [[ "$value" =~ ^[[:print:]]+$ ]]; then
                    printf 'ERROR: invalid %s in %s:%s\n' \
                        "$key" "$label" "$line_number" >&2
                    return 1
                fi
                if [[ "$value" == *\\* ]]; then
                    local doubled=$'\x01' slash_space="\\ "
                    value="${value//\\\\/$doubled}"
                    value="${value//"$slash_space"/ }"
                    case "$value" in
                        *\\*)
                            printf 'ERROR: invalid %s in %s:%s\n' \
                                "$key" "$label" "$line_number" >&2
                            return 1
                            ;;
                    esac
                    value="${value//"$doubled"/\\}"
                fi

                # A Git identity is printable single-line data: no control
                # characters, no leading or terminal whitespace, and no `$` or
                # backtick, so a seeded value can never even look like shell
                # command substitution.
                if ! [[ "$value" =~ ^[[:print:]]+$ ]] ||
                    [[ "$value" == ' '* || "$value" == *' ' ||
                        "$value" == *'$'* || "$value" == *'`'* ]]; then
                    printf 'ERROR: invalid %s in %s:%s\n' "$key" "$label" "$line_number" >&2
                    return 1
                fi
                ;;
            POSTGRES_USER | POSTGRES_DB)
                [[ "$value" =~ ^[A-Za-z0-9_.-]{1,63}$ ]] || {
                    printf 'ERROR: invalid %s in %s:%s\n' "$key" "$label" "$line_number" >&2
                    return 1
                }
                ;;
            POSTGRES_PORT | VALKEY_PORT)
                devbox_state_valid_port "$value" || {
                    printf 'ERROR: %s in %s:%s must be a port from 1 to 65535\n' \
                        "$key" "$label" "$line_number" >&2
                    return 1
                }
                ;;
            POSTGRES_PASSWORD | VALKEY_PASSWORD)
                [[ "$value" =~ ^[A-Fa-f0-9]{32,128}$ ]] || {
                    printf 'ERROR: invalid %s in %s:%s\n' "$key" "$label" "$line_number" >&2
                    return 1
                }
                ;;
        esac
        printf -v "$key" '%s' "$value"
    done
}

devbox_state_config_is_complete() {
    [ -n "${POSTGRES_USER:-}" ] && [ -n "${POSTGRES_DB:-}" ] &&
        [ -n "${POSTGRES_PORT:-}" ]
}

devbox_random_secret() {
    head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Seed the guest user's config and secrets. Runs as that user, so nothing here
# crosses a privilege boundary. stdin is the host seed: it is kept verbatim on
# the first provision only, after the allowlisted parser accepts it.
devbox_seed_guest_state() {
    local directory="$1" config="$1/config" secrets="$1/secrets" owner group temporary
    # The allowlisted keys captured by devbox_parse_state_file are locked to
    # this function's scope; they are set through `printf -v`, never read
    # here directly.
    # shellcheck disable=SC2034
    local POSTGRES_USER POSTGRES_DB POSTGRES_PORT VALKEY_PORT POSTGRES_PASSWORD VALKEY_PASSWORD
    # shellcheck disable=SC2034
    local GIT_NAME GIT_EMAIL

    owner="$(id -un)"
    group="$(id -gn)"
    umask 077
    mkdir -p "$directory"
    chmod 700 "$(dirname "$directory")" "$directory"
    devbox_path_is_safe d "$directory" "$owner" "$group" 700 || return 1

    if [ -e "$config" ] || [ -L "$config" ]; then
        devbox_path_is_safe f "$config" "$owner" "$group" 600 || return 1
        # devbox_parse_state_file only consumes stdin; the second "$config" is
        # the error-label wording printed by the parser, never a write.
        # shellcheck disable=SC2094
        devbox_parse_state_file "$config" config <"$config" || return 1
        devbox_state_config_is_complete || {
            printf 'ERROR: existing guest config is incomplete; refusing to overwrite: %s\n' \
                "$config" >&2
            return 1
        }
        cat >/dev/null
    else
        temporary="$(mktemp "$directory/.config.XXXXXX")"
        cat >"$temporary"
        if ! devbox_parse_state_file "host seed" config <"$temporary" ||
            ! devbox_state_config_is_complete; then
            rm -f -- "$temporary"
            return 1
        fi
        mv -f -- "$temporary" "$config"
    fi

    if [ -e "$secrets" ] || [ -L "$secrets" ]; then
        devbox_path_is_safe f "$secrets" "$owner" "$group" 600 || return 1
        # Same as the config parse: stdin-only consumption, "$secrets" is the
        # parser's error label.
        # shellcheck disable=SC2094
        devbox_parse_state_file "$secrets" secrets <"$secrets" || return 1
    fi
    if [ -z "${POSTGRES_PASSWORD:-}" ] || [ -z "${VALKEY_PASSWORD:-}" ]; then
        temporary="$(mktemp "$directory/.secrets.XXXXXX")"
        printf 'export POSTGRES_PASSWORD=%s\nexport VALKEY_PASSWORD=%s\n' \
            "${POSTGRES_PASSWORD:-$(devbox_random_secret)}" \
            "${VALKEY_PASSWORD:-$(devbox_random_secret)}" >"$temporary"
        mv -f -- "$temporary" "$secrets"
    fi
}

devbox_lima_data_root() {
    findmnt -rno TARGET -t ext4 2>/dev/null |
        awk 'index($0, "/mnt/lima-") == 1 { print; exit }'
}

# findmnt can report multiple entries for a path when mounts are stacked. The
# last entry is the visible mount and is the one the home check must validate.
devbox_findmnt_visible() {
    local field="$1" path="$2" output

    output="$(findmnt -n -o "$field" -T "$path" 2>/dev/null)" || return 1
    [ -n "$output" ] || return 1
    printf '%s\n' "$output" | awk 'NF { value = $0 } END { if (value != "") print value; else exit 1 }'
}

# Confirm that the guest home is the expected bind mount into Lima's ext4 data
# disk, not merely a directory that happens to exist on the fixed-size root.
devbox_home_is_on_lima_data_disk() {
    local guest_home="$1" target="$2" data_root="$3"
    local data_root_target data_target home_target data_root_source data_source home_source
    local data_root_device data_device home_device data_root_fsroot data_fsroot home_fsroot expected_fsroot

    [ "$target" = "$data_root/devbox-home" ] || return 1
    [ -d "$guest_home" ] && [ ! -L "$guest_home" ] || return 1
    [ -d "$target" ] && [ ! -L "$target" ] || return 1

    data_root_target="$(devbox_findmnt_visible TARGET "$data_root")" || return 1
    [ "$data_root_target" = "$data_root" ] || return 1
    [ "$(devbox_findmnt_visible FSTYPE "$data_root")" = ext4 ] || return 1
    data_root_source="$(devbox_findmnt_visible SOURCE "$data_root")" || return 1
    data_root_device="${data_root_source%%\[*}"
    [ -n "$data_root_device" ] || return 1
    data_root_fsroot="$(devbox_findmnt_visible FSROOT "$data_root")" || return 1

    data_target="$(devbox_findmnt_visible TARGET "$target")" || return 1
    case "$data_target" in
        "$data_root" | "$target") ;;
        *) return 1 ;;
    esac
    [ "$(devbox_findmnt_visible FSTYPE "$target")" = ext4 ] || return 1
    data_source="$(devbox_findmnt_visible SOURCE "$target")" || return 1
    data_device="${data_source%%\[*}"
    [ "$data_device" = "$data_root_device" ] || return 1
    data_fsroot="$(devbox_findmnt_visible FSROOT "$target")" || return 1

    if [ "$data_root_fsroot" = / ]; then
        expected_fsroot=/devbox-home
    else
        expected_fsroot="${data_root_fsroot%/}/devbox-home"
    fi
    if [ "$data_target" = "$target" ]; then
        [ "$data_fsroot" = "$expected_fsroot" ] || return 1
        expected_fsroot="$data_fsroot"
    else
        [ "$data_fsroot" = "$data_root_fsroot" ] || return 1
    fi

    home_target="$(devbox_findmnt_visible TARGET "$guest_home")" || return 1
    [ "$home_target" = "$guest_home" ] || return 1

    home_source="$(devbox_findmnt_visible SOURCE "$guest_home")" || return 1
    home_device="${home_source%%\[*}"
    [ "$home_device" = "$data_device" ] || return 1

    home_fsroot="$(devbox_findmnt_visible FSROOT "$guest_home")" || return 1
    [ "$home_fsroot" = "$expected_fsroot" ]
}
