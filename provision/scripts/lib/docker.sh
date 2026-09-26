#!/bin/bash
# Docker helpers shared by root provisioning, the devbox-user setup, and
# readiness checks. The rootful Colima Engine remains managed by Colima.

DEVBOX_SUBID_RANGE_SIZE=65536
DEVBOX_SUBID_RANGE_MIN=100000
DEVBOX_SUBID_RANGE_MAX=600100000
DEVBOX_ROOTLESSKIT_EXECUTABLE=/usr/bin/rootlesskit
DEVBOX_ROOTLESSKIT_APPARMOR_PROFILE=/etc/apparmor.d/rootlesskit
DEVBOX_APPARMOR_USERNS_RESTRICTION=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
DEVBOX_APPARMOR_PROFILES=/sys/kernel/security/apparmor/profiles

devbox_docker_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

# Ubuntu's packaged rootlesskit profile is attached to /usr/bin/rootlesskit.
# Do not let PATH select an unprofiled copy from /usr/local/bin or elsewhere.
devbox_rootlesskit_path_is_profiled() {
    local actual_path="${1:-$(type -P rootlesskit 2>/dev/null || true)}"
    local expected_path="${2:-$DEVBOX_ROOTLESSKIT_EXECUTABLE}"

    [ "$actual_path" = "$expected_path" ] &&
        [ -x "$expected_path" ] && [ ! -L "$expected_path" ]
}

devbox_require_rootlesskit_profiled_path() {
    local actual_path

    actual_path="$(type -P rootlesskit 2>/dev/null || true)"
    devbox_rootlesskit_path_is_profiled "$actual_path" || {
        devbox_docker_error \
            "RootlessKit must resolve to the Ubuntu-profiled executable $DEVBOX_ROOTLESSKIT_EXECUTABLE (found ${actual_path:-not found})"
        return 1
    }
}

# Return 0 when the Ubuntu AppArmor user-namespace restriction is enabled, 1
# when it is absent or disabled, and 2 when its state cannot be determined.
devbox_apparmor_userns_restriction_is_enabled() {
    local setting_file="${1:-$DEVBOX_APPARMOR_USERNS_RESTRICTION}" value

    [ -e "$setting_file" ] || return 1
    [ -r "$setting_file" ] || return 2
    value="$(<"$setting_file")" || return 2
    case "$value" in
        1) return 0 ;;
        0) return 1 ;;
        *) return 2 ;;
    esac
}

devbox_ubuntu_rootlesskit_profile_is_supported() {
    local profile_file="${1:-$DEVBOX_ROOTLESSKIT_APPARMOR_PROFILE}"

    [ -f "$profile_file" ] && [ ! -L "$profile_file" ] || return 1
    grep -Eq '^[[:space:]]*profile[[:space:]]+rootlesskit[[:space:]]+/usr/bin/rootlesskit[[:space:]]+flags=\(unconfined\)[[:space:]]*\{' \
        "$profile_file" &&
        grep -Eq '^[[:space:]]*userns,[[:space:]]*(#.*)?$' "$profile_file"
}

devbox_apparmor_package_has_rootlesskit_profile() {
    local profile_file="${1:-$DEVBOX_ROOTLESSKIT_APPARMOR_PROFILE}"
    local package_status profile_owner

    package_status="$(dpkg-query -W -f='${db:Status-Status}' apparmor 2>/dev/null || true)"
    [ "$package_status" = installed ] || return 1
    devbox_ubuntu_rootlesskit_profile_is_supported "$profile_file" || return 1
    profile_owner="$(dpkg-query -S "$profile_file" 2>/dev/null)" || return 1
    [ "$profile_owner" = "apparmor: $profile_file" ]
}

devbox_rootlesskit_apparmor_profile_is_loaded() {
    local loaded_profiles="${1:-$DEVBOX_APPARMOR_PROFILES}"

    [ -r "$loaded_profiles" ] || return 1
    grep -Fqx 'rootlesskit (unconfined)' "$loaded_profiles"
}

# Load only Ubuntu's packaged profile; never relax the sysctl or create a
# catch-all policy. The profile itself grants userns to /usr/bin/rootlesskit.
devbox_prepare_rootlesskit_apparmor_profile() {
    local setting_file="${1:-$DEVBOX_APPARMOR_USERNS_RESTRICTION}"
    local profile_file="${2:-$DEVBOX_ROOTLESSKIT_APPARMOR_PROFILE}"
    local loaded_profiles="${3:-$DEVBOX_APPARMOR_PROFILES}"
    local restriction_status

    if devbox_apparmor_userns_restriction_is_enabled "$setting_file"; then
        :
    else
        restriction_status=$?
        if [ "$restriction_status" -eq 1 ]; then
            return 0
        fi
        devbox_docker_error \
            "could not determine whether $DEVBOX_APPARMOR_USERNS_RESTRICTION is enabled; refusing rootless Docker setup"
        return 1
    fi

    devbox_apparmor_package_has_rootlesskit_profile "$profile_file" || {
        devbox_docker_error \
            "kernel.apparmor_restrict_unprivileged_userns=1, but Ubuntu's packaged RootlessKit AppArmor profile is unavailable at $profile_file; install or restore the apparmor package profile for /usr/bin/rootlesskit"
        return 1
    }
    command -v apparmor_parser >/dev/null 2>&1 || {
        devbox_docker_error "apparmor_parser is unavailable; cannot load Ubuntu's RootlessKit AppArmor profile"
        return 1
    }
    apparmor_parser -r "$profile_file" || {
        devbox_docker_error "failed to load Ubuntu's RootlessKit AppArmor profile from $profile_file"
        return 1
    }
    devbox_rootlesskit_apparmor_profile_is_loaded "$loaded_profiles" || {
        devbox_docker_error \
            "Ubuntu's RootlessKit AppArmor profile was not loaded as rootlesskit (unconfined) for /usr/bin/rootlesskit"
        return 1
    }
}

devbox_rootlesskit_apparmor_profile_is_ready() {
    local setting_file="${1:-$DEVBOX_APPARMOR_USERNS_RESTRICTION}"
    local profile_file="${2:-$DEVBOX_ROOTLESSKIT_APPARMOR_PROFILE}"
    local loaded_profiles="${3:-$DEVBOX_APPARMOR_PROFILES}"
    local actual_path="${4:-$(type -P rootlesskit 2>/dev/null || true)}"
    local expected_path="${5:-$DEVBOX_ROOTLESSKIT_EXECUTABLE}"
    local restriction_status

    devbox_rootlesskit_path_is_profiled "$actual_path" "$expected_path" || return 1
    if devbox_apparmor_userns_restriction_is_enabled "$setting_file"; then
        devbox_apparmor_package_has_rootlesskit_profile "$profile_file" &&
            devbox_rootlesskit_apparmor_profile_is_loaded "$loaded_profiles"
    else
        restriction_status=$?
        [ "$restriction_status" -eq 1 ]
    fi
}

devbox_subid_system_file_is_safe() {
    local file="$1" metadata owner mode mode_value

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    metadata="$(stat -c '%u %a' "$file" 2>/dev/null)" || return 1
    read -r owner mode <<<"$metadata"
    [ "$owner" = 0 ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0022) == 0 ))
}

devbox_subid_file_is_valid() {
    local file="$1"

    if [ -e "$file" ] || [ -L "$file" ]; then
        [ -f "$file" ] && [ ! -L "$file" ] || return 1
    else
        return 0
    fi
    awk -F: -v minimum="$DEVBOX_SUBID_RANGE_MIN" -v maximum="$DEVBOX_SUBID_RANGE_MAX" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF != 3 || $1 == "" || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $3 < 1 {
            exit 1
        }
        {
            first = $2 + 0
            count = $3 + 0
            if (first < minimum || first > maximum || count > maximum - first + 1) {
                exit 1
            }
        }
    ' "$file"
}

# Existing devbox ranges must not overlap another account's subordinate IDs.
devbox_subid_user_ranges_are_safe() {
    local file="$1" account="$2"

    [ -f "$file" ] || return 0
    awk -F: -v account="$account" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            owner[++n] = $1
            first[n] = $2 + 0
            last[n] = $2 + $3 - 1
        }
        END {
            for (i = 1; i <= n; i++) {
                for (j = i + 1; j <= n; j++) {
                    if ((owner[i] == account || owner[j] == account) &&
                        first[i] <= last[j] && first[j] <= last[i]) {
                        exit 1
                    }
                }
            }
            exit 0
        }
    ' "$file"
}

devbox_subid_file_avoids_system_identities() {
    local file="$1" kind="$2" passwd_file="${3:-/etc/passwd}" group_file="${4:-/etc/group}"

    case "$kind" in
        uid | gid) ;;
        *) return 1 ;;
    esac
    [ -f "$file" ] && [ -f "$passwd_file" ] && [ -r "$passwd_file" ] &&
        [ -f "$group_file" ] && [ -r "$group_file" ] || return 1
    awk -F: -v kind="$kind" -v passwd_file="$passwd_file" \
        -v group_file="$group_file" -v mapping_file="$file" '
        function remember_identity(raw, value) {
            if (raw ~ /^[0-9]+$/) {
                value = raw + 0
                identities[value] = 1
            }
        }
        FILENAME == passwd_file {
            if (kind == "uid") {
                remember_identity($3)
            } else {
                remember_identity($4)
            }
            next
        }
        FILENAME == group_file {
            if (kind == "gid") {
                remember_identity($3)
            }
            next
        }
        FILENAME == mapping_file {
            if (/^[[:space:]]*#/ || /^[[:space:]]*$/) {
                next
            }
            first = $2 + 0
            last = first + $3 - 1
            for (identity in identities) {
                value = identity + 0
                if (value >= first && value <= last) {
                    overlap = 1
                    exit 1
                }
            }
        }
        END { if (overlap) exit 1 }
    ' "$passwd_file" "$group_file" "$file"
}

devbox_subid_system_identity_conflict_end() {
    local first="$1" last="$2" kind="$3"
    local passwd_file="${4:-/etc/passwd}" group_file="${5:-/etc/group}"

    case "$kind" in
        uid | gid) ;;
        *) return 1 ;;
    esac
    [ -f "$passwd_file" ] && [ -r "$passwd_file" ] &&
        [ -f "$group_file" ] && [ -r "$group_file" ] || return 1
    awk -F: -v first="$first" -v last="$last" -v kind="$kind" \
        -v passwd_file="$passwd_file" -v group_file="$group_file" '
        function consider_identity(raw, value) {
            if (raw ~ /^[0-9]+$/) {
                value = raw + 0
                if (value >= first && value <= last && (!found || value > conflict)) {
                    conflict = value
                    found = 1
                }
            }
        }
        FILENAME == passwd_file {
            if (kind == "uid") {
                consider_identity($3)
            } else {
                consider_identity($4)
            }
            next
        }
        FILENAME == group_file {
            if (kind == "gid") {
                consider_identity($3)
            }
            next
        }
        END { if (found) print conflict }
    ' "$passwd_file" "$group_file"
}

devbox_subid_file_has_usable_range() {
    local file="$1" account="$2" required="${3:-$DEVBOX_SUBID_RANGE_SIZE}"
    local kind="${4:-}" passwd_file="${5:-/etc/passwd}" group_file="${6:-/etc/group}"

    case "$file" in
        /etc/subuid | /etc/subgid)
            devbox_subid_system_file_is_safe "$file" || return 2
            ;;
    esac
    [ -f "$file" ] || return 2
    devbox_subid_file_is_valid "$file" &&
        devbox_subid_user_ranges_are_safe "$file" "$account" || return 2
    if [ -n "$kind" ]; then
        devbox_subid_file_avoids_system_identities \
            "$file" "$kind" "$passwd_file" "$group_file" || return 2
    fi
    awk -F: -v account="$account" -v required="$required" '
        $1 == account && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 >= required {
            found = 1
        }
        END { exit !found }
    ' "$file"
}

devbox_find_free_subid_start() {
    local file="$1" kind="${2:-}" candidate="$DEVBOX_SUBID_RANGE_MIN"
    local end conflict_end identity_conflict_end scan_file
    local passwd_file="${3:-/etc/passwd}" group_file="${4:-/etc/group}"

    if [ -n "$kind" ]; then
        case "$kind" in
            uid | gid) ;;
            *) return 1 ;;
        esac
    fi

    scan_file="$file"
    [ -f "$scan_file" ] || scan_file=/dev/null
    while :; do
        end=$((candidate + DEVBOX_SUBID_RANGE_SIZE - 1))
        [ "$end" -le "$DEVBOX_SUBID_RANGE_MAX" ] || return 1
        conflict_end="$(awk -F: -v first="$candidate" -v last="$end" '
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            {
                range_first = $2 + 0
                range_last = range_first + $3 - 1
                if (range_first <= last && range_last >= first && range_last > conflict) {
                    conflict = range_last
                }
            }
            END { if (conflict) print conflict }
        ' "$scan_file")" || return 1
        if [ -z "$conflict_end" ]; then
            if [ -n "$kind" ]; then
                identity_conflict_end="$(devbox_subid_system_identity_conflict_end \
                    "$candidate" "$end" "$kind" "$passwd_file" "$group_file")" || return 1
                if [ -n "$identity_conflict_end" ]; then
                    candidate=$((identity_conflict_end + 1))
                    continue
                fi
            fi
            printf '%s\n' "$candidate"
            return 0
        fi
        candidate=$((conflict_end + 1))
    done
}

# Ensure one non-overlapping 65,536-ID map for devbox without editing the
# subordinate-ID files directly; usermod owns those databases.
devbox_ensure_subordinate_range() {
    local kind="$1" account="$2" file="$3"
    local option start end range_status

    [ "${EUID:-$(id -u)}" -eq 0 ] || {
        devbox_docker_error 'subordinate UID/GID ranges must be configured as root'
        return 1
    }
    case "$kind" in
        uid) option=--add-subuids ;;
        gid) option=--add-subgids ;;
        *) devbox_docker_error "invalid subordinate ID kind: $kind"; return 1 ;;
    esac
    devbox_subid_system_file_is_safe "$file" || {
        devbox_docker_error "unsafe subordinate ID file: $file"
        return 1
    }
    if devbox_subid_file_has_usable_range \
        "$file" "$account" "$DEVBOX_SUBID_RANGE_SIZE" "$kind"; then
        return 0
    else
        range_status=$?
    fi
    [ "$range_status" -eq 1 ] || {
        devbox_docker_error "unsafe or conflicting subordinate ID mappings in $file"
        return 1
    }

    start="$(devbox_find_free_subid_start "$file" "$kind")" || {
        devbox_docker_error "no free $DEVBOX_SUBID_RANGE_SIZE-ID range is available in $file"
        return 1
    }
    end=$((start + DEVBOX_SUBID_RANGE_SIZE - 1))
    usermod "$option" "$start-$end" "$account" || return 1
    devbox_subid_system_file_is_safe "$file" &&
        devbox_subid_file_has_usable_range \
            "$file" "$account" "$DEVBOX_SUBID_RANGE_SIZE" "$kind" || {
        devbox_docker_error "usermod did not configure a usable range in $file for $account"
        return 1
    }
}

devbox_rootless_runtime_dir() {
    printf '/run/user/%s\n' "$(id -u)"
}

devbox_rootless_endpoint() {
    printf 'unix://%s/docker.sock\n' "$(devbox_rootless_runtime_dir)"
}

devbox_find_rootless_setup_tool() {
    local tool

    tool="$(command -v dockerd-rootless-setuptool.sh 2>/dev/null)" && {
        printf '%s\n' "$tool"
        return 0
    }
    for tool in /usr/bin/dockerd-rootless-setuptool.sh \
        /usr/local/bin/dockerd-rootless-setuptool.sh \
        /usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh; do
        if [ -x "$tool" ]; then
            printf '%s\n' "$tool"
            return 0
        fi
    done
    return 1
}

devbox_install_matching_rootless_extras() {
    local engine_package_version="$1" simulation

    apt-cache madison docker-ce-rootless-extras 2>/dev/null |
        awk -v wanted="$engine_package_version" '$3 == wanted { found = 1 } END { exit !found }' || {
        devbox_docker_error \
            "docker-ce-rootless-extras $engine_package_version is unavailable from configured APT sources; refusing to add a repository or change Engine distributions"
        return 1
    }
    simulation="$(apt-get -s --no-install-recommends --no-upgrade \
        install "docker-ce-rootless-extras=$engine_package_version")" || {
        devbox_docker_error 'could not simulate installation of matching Docker rootless extras'
        return 1
    }
    if printf '%s\n' "$simulation" |
        grep -Eq '^(Inst|Remv) (docker-ce|docker-ce-cli|containerd|containerd\.io|docker\.io|runc)([[:space:]:]|$)'; then
        devbox_docker_error \
            'matching rootless extras would change the installed rootful Engine; refusing the package transaction'
        return 1
    fi
    apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
        -y --no-install-recommends --no-upgrade \
        install "docker-ce-rootless-extras=$engine_package_version"
}

# Root phase. Only the rootless-extras package from the already-configured
# Docker Engine source may be added, and it must match the installed Engine.
devbox_prepare_rootless_docker() {
    local engine_package_version cli_package_version server_version extras_status extras_version
    local setup_tool devbox_uid

    [ "${EUID:-$(id -u)}" -eq 0 ] || {
        devbox_docker_error 'rootless Docker prerequisites must be prepared as root'
        return 1
    }
    for package in docker-ce docker-ce-cli; do
        [ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" = installed ] || {
            devbox_docker_error "expected Colima's existing $package package; refusing to install another Docker Engine"
            return 1
        }
    done
    engine_package_version="$(dpkg-query -W -f='${Version}' docker-ce)" || return 1
    cli_package_version="$(dpkg-query -W -f='${Version}' docker-ce-cli)" || return 1
    [ "$cli_package_version" = "$engine_package_version" ] || {
        devbox_docker_error 'installed Docker Engine and CLI package versions differ; refusing to change the rootful Engine'
        return 1
    }
    server_version="$(env -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
        DOCKER_HOST=unix:///var/run/docker.sock \
        docker version --format '{{.Server.Version}}' 2>/dev/null)" || {
        devbox_docker_error 'could not read the existing rootful Docker Engine version'
        return 1
    }
    case "$engine_package_version" in
        *:"$server_version"-* | "$server_version"-*) ;;
        *)
            devbox_docker_error \
                "running Docker Engine $server_version does not match installed package $engine_package_version; refusing rootless extras"
            return 1
            ;;
    esac

    extras_status="$(dpkg-query -W -f='${db:Status-Status}' \
        docker-ce-rootless-extras 2>/dev/null || true)"
    extras_version=""
    if [ "$extras_status" = installed ]; then
        extras_version="$(dpkg-query -W -f='${Version}' docker-ce-rootless-extras)" || return 1
        [ "$extras_version" = "$engine_package_version" ] || {
            devbox_docker_error \
                "installed rootless extras $extras_version do not match Docker Engine $engine_package_version"
            return 1
        }
    else
        setup_tool="$(devbox_find_rootless_setup_tool || true)"
        [ -z "$setup_tool" ] || {
            devbox_docker_error \
                "unpackaged rootless setup tool found at $setup_tool; refusing to use tooling outside the matching Engine package"
            return 1
        }
        devbox_install_matching_rootless_extras "$engine_package_version" || return 1
        extras_status="$(dpkg-query -W -f='${db:Status-Status}' \
            docker-ce-rootless-extras 2>/dev/null || true)"
        extras_version="$(dpkg-query -W -f='${Version}' \
            docker-ce-rootless-extras 2>/dev/null || true)"
        [ "$extras_status" = installed ] && [ "$extras_version" = "$engine_package_version" ] || {
            devbox_docker_error 'matching Docker rootless extras were not installed'
            return 1
        }
    fi

    setup_tool="$(devbox_find_rootless_setup_tool || true)"
    [ -n "$setup_tool" ] || {
        devbox_docker_error 'the matching Engine distribution does not provide dockerd-rootless-setuptool.sh'
        return 1
    }
    for binary in newuidmap newgidmap rootlesskit slirp4netns dockerd-rootless.sh; do
        command -v "$binary" >/dev/null 2>&1 || {
            devbox_docker_error "required rootless Docker tool is missing: $binary"
            return 1
        }
    done
    devbox_require_rootlesskit_profiled_path || return 1
    devbox_prepare_rootlesskit_apparmor_profile || return 1

    devbox_ensure_subordinate_range uid devbox /etc/subuid || return 1
    devbox_ensure_subordinate_range gid devbox /etc/subgid || return 1
    loginctl enable-linger devbox || return 1
    [ "$(loginctl show-user devbox -p Linger --value 2>/dev/null)" = yes ] || {
        devbox_docker_error 'systemd lingering is not enabled for devbox'
        return 1
    }
    devbox_uid="$(id -u devbox)" || return 1
    # Start the user manager, not Docker, so the later unprivileged phase can
    # configure and start its own service even when invoked through sudo -u.
    systemctl start "user@$devbox_uid.service"
}

devbox_rootless_docker_is_ready() {
    local endpoint socket security_options

    endpoint="$(devbox_rootless_endpoint)" || return 1
    socket="${endpoint#unix://}"
    [ -S "$socket" ] || return 1
    security_options="$(env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS -u DOCKER_TLS_VERIFY \
        -u DOCKER_CERT_PATH DOCKER_HOST="$endpoint" \
        docker info --format '{{json .SecurityOptions}}' 2>/dev/null)" || return 1
    [[ "$security_options" == *rootless* ]]
}

devbox_rootless_context_is_selected() {
    local endpoint current_context context_endpoint

    endpoint="$(devbox_rootless_endpoint)" || return 1
    current_context="$(env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS -u DOCKER_TLS_VERIFY \
        -u DOCKER_CERT_PATH docker context show 2>/dev/null)" || return 1
    context_endpoint="$(env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS -u DOCKER_TLS_VERIFY \
        -u DOCKER_CERT_PATH docker context inspect rootless \
        --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" || return 1
    [ "$current_context" = rootless ] && [ "$context_endpoint" = "$endpoint" ]
}

devbox_rootful_docker_is_denied() {
    [ -S /var/run/docker.sock ] || return 1
    [ ! -r /var/run/docker.sock ] && [ ! -w /var/run/docker.sock ] || return 1
    ! env -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
        DOCKER_HOST=unix:///var/run/docker.sock \
        docker info >/dev/null 2>&1
}

devbox_rootless_user_service_is_active() {
    local runtime_dir uid

    uid="$(id -u)"
    runtime_dir="/run/user/$uid"
    [ -d "$runtime_dir" ] && [ ! -L "$runtime_dir" ] || return 1
    [ "$(stat -c '%u' "$runtime_dir" 2>/dev/null)" = "$uid" ] || return 1
    XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user is-active --quiet docker.service
}

devbox_rootless_user_service_is_enabled() {
    local runtime_dir uid

    uid="$(id -u)"
    runtime_dir="/run/user/$uid"
    [ -d "$runtime_dir" ] && [ ! -L "$runtime_dir" ] || return 1
    XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user is-enabled --quiet docker.service
}

devbox_user_lingering_is_enabled() {
    [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ]
}

devbox_user_has_rootless_subid_ranges() {
    devbox_subid_system_file_is_safe /etc/subuid &&
        devbox_subid_file_has_usable_range /etc/subuid "$(id -un)" \
            "$DEVBOX_SUBID_RANGE_SIZE" uid &&
        devbox_subid_system_file_is_safe /etc/subgid &&
        devbox_subid_file_has_usable_range /etc/subgid "$(id -un)" \
            "$DEVBOX_SUBID_RANGE_SIZE" gid
}

# Unprivileged tools phase. All setup and service operations here run as devbox.
devbox_configure_rootless_docker() {
    local account uid runtime_dir endpoint setup_tool context_endpoint

    account="$(id -un)"
    [ "$account" = devbox ] || {
        devbox_docker_error 'rootless Docker setup must run as devbox'
        return 1
    }
    uid="$(id -u)"
    runtime_dir="/run/user/$uid"
    [ -z "${XDG_RUNTIME_DIR:-}" ] || [ "$XDG_RUNTIME_DIR" = "$runtime_dir" ] || {
        devbox_docker_error 'XDG_RUNTIME_DIR does not match the devbox systemd user runtime directory'
        return 1
    }
    [ -d "$runtime_dir" ] && [ ! -L "$runtime_dir" ] || {
        devbox_docker_error 'systemd did not create the lingering devbox runtime directory'
        return 1
    }
    [ "$(stat -c '%u' "$runtime_dir" 2>/dev/null)" = "$uid" ] || {
        devbox_docker_error 'the devbox runtime directory is not owned by devbox'
        return 1
    }
    export XDG_RUNTIME_DIR="$runtime_dir"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus"
    systemctl --user show-environment >/dev/null 2>&1 || {
        devbox_docker_error 'the lingering devbox systemd user manager is unavailable'
        return 1
    }
    setup_tool="$(devbox_find_rootless_setup_tool)" || {
        devbox_docker_error 'dockerd-rootless-setuptool.sh is unavailable'
        return 1
    }
    devbox_rootlesskit_apparmor_profile_is_ready || {
        devbox_docker_error \
            "RootlessKit must use /usr/bin/rootlesskit with Ubuntu's AppArmor profile loaded when unprivileged user namespaces are restricted"
        return 1
    }

    # The rootful daemon is intentionally left enabled for root-managed
    # services. --force permits a second, per-user systemd service.
    env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS -u DOCKER_TLS_VERIFY \
        -u DOCKER_CERT_PATH "$setup_tool" install --force || return 1
    systemctl --user daemon-reload
    systemctl --user enable --now docker.service
    env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS -u DOCKER_TLS_VERIFY \
        -u DOCKER_CERT_PATH docker context use rootless >/dev/null

    endpoint="$(devbox_rootless_endpoint)"
    context_endpoint="$(env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS -u DOCKER_TLS_VERIFY \
        -u DOCKER_CERT_PATH docker context inspect rootless \
        --format '{{.Endpoints.docker.Host}}')" || return 1
    [ "$context_endpoint" = "$endpoint" ] || {
        devbox_docker_error "rootless Docker context points to $context_endpoint, expected $endpoint"
        return 1
    }
    devbox_rootless_docker_is_ready || {
        devbox_docker_error 'rootless Docker did not become reachable on its per-user socket'
        return 1
    }
}
