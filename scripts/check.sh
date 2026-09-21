#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

missing=()
for tool in brew jq yq docker; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
    printf 'ERROR: missing contributor tools: %s\n' "${missing[*]}" >&2
    printf 'Review and run: brew install jq yq docker docker-compose\n' >&2
    exit 1
fi

validation_root="$(mktemp -d)"
rendered_colima="$validation_root/colima.yaml"
rendered_v2_colima="$validation_root/colima-v2.yaml"
service_env="$validation_root/service.env"
DOCKER_CONFIG="$validation_root/docker"
export DOCKER_CONFIG
trap 'rm -rf "$validation_root"' EXIT
mkdir -p "$DOCKER_CONFIG"
compose_plugin_dir="$(brew --prefix)/lib/docker/cli-plugins"
[ -x "$compose_plugin_dir/docker-compose" ] || {
    printf 'ERROR: Docker Compose plugin is unavailable. Review and run: brew install docker-compose\n' >&2
    exit 1
}
jq -n --arg directory "$compose_plugin_dir" \
    '{cliPluginsExtraDirs: [$directory]}' >"$DOCKER_CONFIG/config.json"
docker compose version >/dev/null 2>&1 || {
    printf 'ERROR: Docker Compose plugin is unavailable. Review and run: brew install docker-compose\n' >&2
    exit 1
}

shell_files=()
while IFS= read -r shell_file; do
    shell_files+=("$shell_file")
done < <(find . \( -type f -name '*.sh' -o -path './devbox' \) | sort)
bash -n "${shell_files[@]}"
[ "$(tail -c 1 provision/config/zsh/zshrc | wc -l | tr -d ' ')" = 1 ] || {
    printf 'ERROR: provision/config/zsh/zshrc must end with a newline\n' >&2
    exit 1
}
zsh_profile_home="$validation_root/zsh-profile-home"
mkdir -p "$zsh_profile_home/.config/devbox" "$zsh_profile_home/.config/devbox-v2"
printf 'DEVBOX_ENV_SOURCE=legacy\n' >"$zsh_profile_home/.config/devbox/env"
HOME="$zsh_profile_home" ROOT="$ROOT" zsh -dfc '
    source "$ROOT/provision/config/zsh/zshrc"
    [ "$DEVBOX_ENV_SOURCE" = legacy ]
' || {
    printf 'ERROR: zsh did not retain legacy guest environment selection\n' >&2
    exit 1
}
printf 'DEVBOX_ENV_SOURCE=v2\n' >"$zsh_profile_home/.config/devbox-v2/config"
HOME="$zsh_profile_home" ROOT="$ROOT" zsh -dfc '
    source "$ROOT/provision/config/zsh/zshrc"
    [ "$DEVBOX_ENV_SOURCE" = v2 ]
' || {
    printf 'ERROR: zsh did not select the v2 guest environment\n' >&2
    exit 1
}

profile_home="$validation_root/home"
profile_path="$profile_home/.colima/devbox/colima.yaml"
profile_root="$profile_home/.colima/devbox"
actual_profile_path="$(
    env -u COLIMA_HOME -u XDG_DATA_HOME -u XDG_CONFIG_HOME \
        HOME="$profile_home" PROFILE=devbox ROOT="$ROOT" /bin/bash -c '
            source "$ROOT/lib/common.sh"
            source "$ROOT/lib/config.sh"
            configure_paths
            printf "%s" "$DEVBOX_COLIMA_CONFIG"
        '
)"
[ "$actual_profile_path" = "$profile_path" ] || {
    printf 'ERROR: devbox must use the standard Colima profile path\n' >&2
    exit 1
}
COLIMA_HOME="$profile_home/.colima" HOME="$profile_home" PROFILE=devbox ROOT="$ROOT" \
    /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        configure_paths
        [ "$DEVBOX_COLIMA_CONFIG" = "$HOME/.colima/devbox/colima.yaml" ]
    '
if COLIMA_HOME="$profile_home/custom-colima" HOME="$profile_home" PROFILE=devbox ROOT="$ROOT" \
    /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        configure_paths
        check_colima_profile_ownership
    ' >/dev/null 2>&1; then
    printf 'ERROR: nonstandard COLIMA_HOME override was not rejected\n' >&2
    exit 1
fi
COLIMA_HOME="$profile_home/custom-colima" HOME="$profile_home" "$ROOT/devbox" help >/dev/null
mkdir -p "$profile_home/.local/share/devbox/colima/devbox"
if env -u COLIMA_HOME -u XDG_DATA_HOME -u XDG_CONFIG_HOME \
    HOME="$profile_home" PROFILE=devbox ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        configure_paths
        check_legacy_colima_profile
    ' >/dev/null 2>&1; then
    printf 'ERROR: legacy private Colima profile was not rejected\n' >&2
    exit 1
fi
COLIMA_HOME="$profile_home/.local/share/devbox/colima" \
    HOME="$profile_home" PROFILE=devbox ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        configure_paths
        check_colima_profile_ownership
    '
rm -rf "$profile_home/.local/share/devbox/colima"
mkdir -p "$profile_root"
printf 'runtime: containerd\nmounts: []\n' >"$profile_path"
unowned_profile_digest="$(shasum -a 256 "$profile_path" | awk '{print $1}')"
if env -u COLIMA_HOME -u XDG_DATA_HOME -u XDG_CONFIG_HOME \
    HOME="$profile_home" "$ROOT/devbox" status >/dev/null 2>&1; then
    printf 'ERROR: CLI accepted an unrelated standard Colima profile\n' >&2
    exit 1
fi
[ "$(shasum -a 256 "$profile_path" | awk '{print $1}')" = "$unowned_profile_digest" ] || {
    printf 'ERROR: CLI modified an unrelated standard Colima profile\n' >&2
    exit 1
}
if env -u COLIMA_HOME -u XDG_DATA_HOME -u XDG_CONFIG_HOME \
    HOME="$profile_home" PROFILE=devbox ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        configure_paths
        check_colima_profile_ownership
    ' >/dev/null 2>&1; then
    printf 'ERROR: unrelated standard Colima profile was not rejected\n' >&2
    exit 1
fi
cat >"$profile_path" <<EOF
runtime: docker
mounts:
  - location: "$ROOT/provision"
    mountPoint: /provision
    writable: false
EOF
env -u COLIMA_HOME -u XDG_DATA_HOME -u XDG_CONFIG_HOME \
    HOME="$profile_home" PROFILE=devbox ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        configure_paths
        check_colima_profile_ownership
        mark_colima_profile_owned
    '
[ "$(sed -n '1p' "$profile_root/.devbox-owner")" = "devbox-profile-v1" ] &&
    [ "$(sed -n '2p' "$profile_root/.devbox-owner")" = "$ROOT" ] || {
    printf 'ERROR: devbox profile ownership marker was not written\n' >&2
    exit 1
}
if env -u COLIMA_HOME -u XDG_DATA_HOME -u XDG_CONFIG_HOME \
    HOME="$profile_home" PROFILE=devbox ROOT="$ROOT" DEVBOX_DIR="$ROOT/other-checkout" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        configure_paths
        check_colima_profile_ownership
    ' >/dev/null 2>&1; then
    printf 'ERROR: another checkout was allowed to use the owned devbox profile\n' >&2
    exit 1
fi
printf 'invalid\n' >"$profile_root/.devbox-owner"
if env -u COLIMA_HOME -u XDG_DATA_HOME -u XDG_CONFIG_HOME \
    HOME="$profile_home" PROFILE=devbox ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        configure_paths
        check_colima_profile_ownership
    ' >/dev/null 2>&1; then
    printf 'ERROR: invalid devbox profile ownership marker was accepted\n' >&2
    exit 1
fi

jq empty \
    provision/config/claude/settings.json \
    provision/config/opencode/opencode.jsonc
jq -e '
    .update == "disable" and
    .server.hostname == "127.0.0.1" and
    .server.mdns == false and
    (.agents.build.permissions | length == 4)
' provision/config/opencode/opencode.jsonc >/dev/null
[ -f provision/config/opencode/AGENTS.md ]
[ -f provision/config/opencode/agents/loop-implementer.md ]
[ -f provision/config/opencode/agents/loop-reviewer.md ]
[ -f provision/config/opencode/agents/loop-reviewer-deep.md ]

sed \
    -e 's/{{CPU}}/4/g' \
    -e 's/{{MEMORY}}/4/g' \
    -e 's/{{DISK}}/60/g' \
    -e 's|{{PROVISION_PATH}}|"/tmp/devbox/provision"|g' \
    -e 's|{{PROJECTS_PATH}}|"/tmp/devbox/projects"|g' \
    -e 's|{{DATA_PATH}}|"/tmp/devbox/data"|g' \
    colima.yaml >"$rendered_colima"
yq eval '.' "$rendered_colima" >/dev/null
[ "$(yq eval '.runtime' "$rendered_colima")" = docker ]
[ "$(yq eval '.mountType' "$rendered_colima")" = virtiofs ]
[ "$(yq eval '.autoActivate' "$rendered_colima")" = false ]
[ "$(yq eval '.sshConfig' "$rendered_colima")" = false ]
[ "$(yq eval '.forwardAgent' "$rendered_colima")" = false ]
[ "$(yq eval '.mounts[0].mountPoint' "$rendered_colima")" = /provision ]
[ "$(yq eval '.mounts[0].writable' "$rendered_colima")" = false ]
[ "$(yq eval '.mounts[1].mountPoint' "$rendered_colima")" = /mnt/devbox/projects ]
[ "$(yq eval '.mounts[2].mountPoint' "$rendered_colima")" = /mnt/devbox/data ]

sed \
    -e 's/{{CPU}}/4/g' \
    -e 's/{{MEMORY}}/4/g' \
    -e 's/{{DISK}}/60/g' \
    colima-v2.yaml >"$rendered_v2_colima"
yq eval '.' "$rendered_v2_colima" >/dev/null
yq -e '
    .runtime == "docker" and
    .vmType == "vz" and
    .autoActivate == false and
    .sshConfig == false and
    .forwardAgent == false and
    .portForwarder == "none" and
    (.mounts == null)
' "$rendered_v2_colima" >/dev/null || {
    printf 'ERROR: v2 Colima configuration must be a mount-free VZ/Docker profile\n' >&2
    exit 1
}
if grep -q 'mounts:' colima-v2.yaml; then
    printf 'ERROR: v2 template must omit, not empty, the mounts key\n' >&2
    exit 1
fi

v2_home="$validation_root/v2-home"
v2_colima_bin="$validation_root/v2-bin"
v2_guest_bin="$validation_root/v2-guest-bin"
v2_colima_capture="$validation_root/v2-colima-env"
v2_archive_capture="$validation_root/v2-provision.tar"
v2_dispatch_capture="$validation_root/v2-dispatch"
mkdir -p "$v2_colima_bin" "$v2_guest_bin"
cat >"$v2_colima_bin/colima" <<'EOF'
#!/bin/bash
printf '%s\n%s\n%s\n' "$COLIMA_HOME" "$LIMA_HOME" "$DOCKER_CONFIG" >"$V2_COLIMA_CAPTURE"
if [ "$1" = list ]; then
    printf '%s\n' '{"name":"devbox-v2","status":"Running","arch":"aarch64","cpus":4,"memory":4294967296,"disk":64424509440}'
fi
EOF
chmod 700 "$v2_colima_bin/colima"
cat >"$v2_guest_bin/sha256sum" <<'EOF'
#!/bin/bash
exec shasum -a 256 "$@"
EOF
chmod 700 "$v2_guest_bin/sha256sum"
env -u COLIMA_HOME -u LIMA_HOME -u DOCKER_CONFIG \
    XDG_DATA_HOME="$validation_root/v2-xdg-data" XDG_CONFIG_HOME="$validation_root/v2-xdg-config" \
    HOME="$v2_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    configure_v2_paths
    [ "$DEVBOX_V2_COLIMA_PROFILE" = "$HOME/.colima/devbox-v2" ]
    [ "$DEVBOX_V2_STATE_ROOT" = "$HOME/.local/share/devbox/v2" ]
    [ "$DEVBOX_V2_LIMA_HOME" = "$HOME/.colima/_lima" ]
    [ "$DEVBOX_V2_DOCKER_CONFIG" = "$HOME/.config/devbox/v2/docker" ]
    [ "$DEVBOX_V2_STATE_ROOT" = "$HOME/.local/share/devbox/v2" ]
    [ "$DEVBOX_LOCK_DIR" = "$XDG_DATA_HOME/devbox/locks" ]
    [ "${DOCKER_CONFIG+x}" != x ]
' || {
    printf 'ERROR: v2 paths are not separate from legacy paths\n' >&2
    exit 1
}
if HOME="$v2_home" LIMA_HOME="$v2_home/custom-lima" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    configure_v2_paths
' >/dev/null 2>&1; then
    printf 'ERROR: v2 accepted a redirected LIMA_HOME\n' >&2
    exit 1
fi
XDG_DATA_HOME="$validation_root/v2-xdg-data" XDG_CONFIG_HOME="$validation_root/v2-xdg-config" \
    HOME="$v2_home" PATH="$v2_colima_bin:$PATH" V2_COLIMA_CAPTURE="$v2_colima_capture" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    configure_v2_paths
    if ! check_v2_ownership; then
        printf "ERROR: a missing v2 profile was not accepted\n" >&2
        exit 1
    fi
    show_v2_status
    stop_v2_vm
    mkdir -p "$HOME/.ssh/config.d"
    cat >"$HOME/.ssh/config" <<CONFIG
# BEGIN devbox
Host devbox
  User legacy-admin
# END devbox
# BEGIN devbox-v2
Host devbox-v2
  User devbox
# END devbox-v2
CONFIG
    : >"$HOME/.ssh/config.d/devbox-v2"
    eval "$(declare -f remove_v2_ssh_config | sed "1s/remove_v2_ssh_config/remove_v2_ssh_config_impl/")"
    remove_v2_ssh_config() {
        [ -d "$DEVBOX_LOCK_DIR/lifecycle" ] || {
            printf "ERROR: absent-profile v2 SSH cleanup ran without the lifecycle lock\n" >&2
            return 1
        }
        remove_v2_ssh_config_impl
    }
    v2_profile_exists() {
        [ -d "$DEVBOX_LOCK_DIR/lifecycle" ] || {
            printf "ERROR: absent-profile v2 profile check ran without the lifecycle lock\n" >&2
            return 1
        }
        return 1
    }
    printf "%s\n" "$V2_PROFILE" | run_v2 destroy
    [ ! -d "$DEVBOX_LOCK_DIR/lifecycle" ]
    [ ! -e "$HOME/.ssh/config.d/devbox-v2" ]
    ! grep -q "# BEGIN devbox-v2" "$HOME/.ssh/config"
    grep -qx "# BEGIN devbox" "$HOME/.ssh/config"
    grep -qx "Host devbox" "$HOME/.ssh/config"
    grep -qx "  User legacy-admin" "$HOME/.ssh/config"
'
[ ! -s "$v2_colima_capture" ] || {
    printf 'ERROR: absent v2 profile acted on a same-named Colima profile\n' >&2
    exit 1
}
mkdir -p "$v2_home/.colima/devbox-v2"
printf 'devbox-v2-profile-v1\n%s\n' "$ROOT" >"$v2_home/.colima/devbox-v2/.devbox-owner"
HOME="$v2_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    configure_v2_paths
    check_v2_ownership
'
XDG_DATA_HOME="$validation_root/v2-xdg-data" XDG_CONFIG_HOME="$validation_root/v2-xdg-config" \
    HOME="$v2_home" PATH="$v2_colima_bin:$PATH" V2_COLIMA_CAPTURE="$v2_colima_capture" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    configure_v2_paths
    v2_colima status
'
[ "$(sed -n '1p' "$v2_colima_capture")" = "$v2_home/.colima" ] || {
    printf 'ERROR: v2 Colima invocation did not pin COLIMA_HOME\n' >&2
    exit 1
}
[ "$(sed -n '2p' "$v2_colima_capture")" = "$v2_home/.colima/_lima" ] || {
    printf 'ERROR: v2 Colima invocation did not pin LIMA_HOME\n' >&2
    exit 1
}
[ "$(sed -n '3p' "$v2_colima_capture")" = "$v2_home/.config/devbox/v2/docker" ] || {
    printf 'ERROR: v2 Colima invocation did not use its Docker config\n' >&2
    exit 1
}
[ "$(sed -n '3p' "$v2_colima_capture")" != "$v2_home/.docker" ] &&
    [ "$(sed -n '3p' "$v2_colima_capture")" != "$v2_home/.config/devbox/docker" ] || {
    printf 'ERROR: v2 Colima invocation used legacy or normal Docker state\n' >&2
    exit 1
}
HOME="$v2_home" V2_ARCHIVE_CAPTURE="$v2_archive_capture" V2_DISPATCH_CAPTURE="$v2_dispatch_capture" V2_GUEST_BIN="$v2_guest_bin" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    create_v2_bundle_snapshot
    [ "$V2_BUNDLE_DIGEST" = "$(v2_bundle_digest "$V2_BUNDLE_SNAPSHOT/provision")" ]
    if tar -tf "$V2_BUNDLE_ARCHIVE" | grep -Eq "(^|/)\\._[^/]*$"; then
        printf "ERROR: v2 bundle archive contains AppleDouble entries\\n" >&2
        exit 1
    fi
    v2_admin_guest() {
        printf "%s\n" "$*" >"$V2_DISPATCH_CAPTURE"
        cat >"$V2_ARCHIVE_CAPTURE"
    }
    stream_v2_bundle "$V2_BUNDLE_DIGEST" "$V2_BUNDLE_ARCHIVE"
    cmp "$V2_BUNDLE_ARCHIVE" "$V2_ARCHIVE_CAPTURE"
    grep -qx "sudo bash -c" <(cut -d " " -f1-3 "$V2_DISPATCH_CAPTURE")
    ! grep -Fq "$HOME" "$V2_DISPATCH_CAPTURE"
    v2_digest_snapshot="$(mktemp -d)"
    cp -R "$V2_BUNDLE_SNAPSHOT/provision" "$v2_digest_snapshot/provision"
    original_digest="$(v2_bundle_digest "$v2_digest_snapshot/provision")"
    printf "invalid marker\\n" >"$v2_digest_snapshot/provision/.devbox-bundle.sha256"
    [ "$original_digest" = "$(v2_bundle_digest "$v2_digest_snapshot/provision")" ]
    touch "$v2_digest_snapshot/provision/scripts/system.sh"
    [ "$original_digest" = "$(v2_bundle_digest "$v2_digest_snapshot/provision")" ]
    chmod u+w "$v2_digest_snapshot/provision/scripts/system.sh"
    printf "# digest coverage\n" >>"$v2_digest_snapshot/provision/scripts/system.sh"
    [ "$original_digest" != "$(v2_bundle_digest "$v2_digest_snapshot/provision")" ]
    rm -rf "$v2_digest_snapshot"
    rm -rf "$V2_BUNDLE_SNAPSHOT"
'
HOME="$v2_home" V2_DISPATCH_CAPTURE="$v2_dispatch_capture" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_state() { printf Running; }
    v2_guest() { printf "%s\n" "$*" >"$V2_DISPATCH_CAPTURE"; }
    run_v2 connect
    [ "$(cat "$V2_DISPATCH_CAPTURE")" = "zsh -l" ]
    run_v2 exec printf "v2 exec coverage"
    [ "$(cat "$V2_DISPATCH_CAPTURE")" = "printf v2 exec coverage" ]
'
v2_ssh_home="$validation_root/v2-ssh-home"
mkdir -p "$v2_ssh_home/.ssh/config.d"
cat >"$v2_ssh_home/.ssh/config" <<'EOF'
# global SSH preamble
StrictHostKeyChecking no
UserKnownHostsFile /dev/null
# BEGIN devbox
Host devbox
  User legacy-admin
# END devbox
Host *
  ProxyCommand ssh proxy.example
  ProxyJump proxy.example
# BEGIN devbox-v2
Host devbox-v2
  User previous-devbox
# END devbox-v2
EOF
HOME="$v2_ssh_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_colima() {
        [ "$1" = ssh-config ] || exit 1
        cat <<CONFIG
Host devbox-v2
  HostName 127.0.0.1
  Port 60022
  User generated-admin
  IdentityFile /tmp/devbox-v2-key
  ForwardAgent yes
  ControlMaster auto
  ControlPath ~/.colima/_lima/colima-devbox-v2/ssh.sock
  ControlPersist 5m
CONFIG
    }
    ssh() {
        case " $* " in
            *" -G devbox-v2 "*) command ssh "$@" ;;
            *) return 0 ;;
        esac
    }
    chmod 640 "$HOME/.ssh/config"
    config_mode="$(stat -f "%Lp" "$HOME/.ssh/config" 2>/dev/null || stat -c "%a" "$HOME/.ssh/config")"
    write_v2_ssh_config
    [ "$(stat -f "%Lp" "$HOME/.ssh/config" 2>/dev/null || stat -c "%a" "$HOME/.ssh/config")" = "$config_mode" ]
    grep -qx "# BEGIN devbox" "$HOME/.ssh/config"
    grep -A2 -x "# BEGIN devbox" "$HOME/.ssh/config" | grep -qx "  User legacy-admin"
    grep -qx "# BEGIN devbox-v2" "$HOME/.ssh/config"
    [ "$(grep -n -x "# BEGIN devbox-v2" "$HOME/.ssh/config" | cut -d: -f1)" -gt \
        "$(grep -n -x "UserKnownHostsFile /dev/null" "$HOME/.ssh/config" | cut -d: -f1)" ]
    [ "$(grep -n -x "# BEGIN devbox-v2" "$HOME/.ssh/config" | cut -d: -f1)" -lt \
        "$(grep -n -x "Host devbox" "$HOME/.ssh/config" | cut -d: -f1)" ]
    grep -qx "Host devbox-v2" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  HostName 127.0.0.1" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  Port 60022" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  User devbox" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  IdentityFile /tmp/devbox-v2-key" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  IdentitiesOnly yes" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  ForwardAgent no" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  ControlMaster no" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  ControlPath none" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  ProxyCommand none" "$HOME/.ssh/config.d/devbox-v2"
    grep -qx "  ProxyJump none" "$HOME/.ssh/config.d/devbox-v2"
    effective_config="$(command ssh -F "$HOME/.ssh/config" -G devbox-v2)"
    awk "
        \$1 == \"proxycommand\" { if (\$2 != \"none\") invalid = 1; next }
        \$1 == \"proxyjump\" { if (\$2 != \"none\") invalid = 1; next }
        \$1 == \"stricthostkeychecking\" { if (\$2 != \"false\") invalid = 1; next }
        END { exit invalid }
    " <<<"$effective_config"
    legacy_config="$(command ssh -F "$HOME/.ssh/config" -G devbox)"
    awk "
        \$1 == \"user\" { if (\$2 != \"legacy-admin\") invalid = 1; next }
        \$1 == \"proxycommand\" { if (\$0 != \"proxycommand ssh proxy.example\") invalid = 1; next }
        \$1 == \"proxyjump\" { if (\$2 != \"proxy.example\") invalid = 1; next }
        END { exit invalid }
    " <<<"$legacy_config"
    [ "$(stat -f "%Lp" "$HOME/.ssh/config.d/devbox-v2" 2>/dev/null || stat -c "%a" "$HOME/.ssh/config.d/devbox-v2")" = 600 ]
    ! grep -q "generated-admin" "$HOME/.ssh/config.d/devbox-v2"
    ! grep -q "ControlPersist" "$HOME/.ssh/config.d/devbox-v2"
    ! grep -q "colima-devbox-v2/ssh.sock" "$HOME/.ssh/config.d/devbox-v2"
    remove_v2_ssh_config
    ! grep -q "# BEGIN devbox-v2" "$HOME/.ssh/config"
    grep -qx "# BEGIN devbox" "$HOME/.ssh/config"
    [ "$(stat -f "%Lp" "$HOME/.ssh/config" 2>/dev/null || stat -c "%a" "$HOME/.ssh/config")" = "$config_mode" ]
'
v2_ssh_authorization_events="$validation_root/v2-ssh-authorization-events"
HOME="$v2_home" V2_SSH_AUTHORIZATION_EVENTS="$v2_ssh_authorization_events" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    validate_v2_guest_preflight() { return 0; }
    reconcile_v2_guest_workspace() { return 0; }
    authorize_v2_host_key() { return 1; }
    write_v2_ssh_config() { printf "configured-after-authorization-failure\n" >>"$V2_SSH_AUTHORIZATION_EVENTS"; }
    if ensure_v2_guest_ssh_access; then
        printf "ERROR: v2 SSH access continued after host-key authorization failed\n" >&2
        exit 1
    fi
    [ ! -s "$V2_SSH_AUTHORIZATION_EVENTS" ]
'
v2_ssh_conflict_home="$validation_root/v2-ssh-conflict-home"
for v2_ssh_conflict in user forwardagent controlmaster controlpath proxycommand; do
    rm -rf "$v2_ssh_conflict_home"
    mkdir -p "$v2_ssh_conflict_home/.ssh/config.d"
    case "$v2_ssh_conflict" in
        user) printf 'User conflicting-user\n' ;;
        forwardagent) printf 'ForwardAgent yes\n' ;;
        controlmaster) printf 'ControlMaster auto\n' ;;
        controlpath) printf 'ControlPath /tmp/devbox-bootstrap.sock\n' ;;
        proxycommand) printf 'ProxyCommand ssh proxy.example\n' ;;
    esac >"$v2_ssh_conflict_home/.ssh/config"
    printf 'Host existing\n  HostName localhost\n' >>"$v2_ssh_conflict_home/.ssh/config"
    printf 'previous managed configuration\n' >"$v2_ssh_conflict_home/.ssh/config.d/devbox-v2"
    cp "$v2_ssh_conflict_home/.ssh/config" "$v2_ssh_conflict_home/config.before"
    cp "$v2_ssh_conflict_home/.ssh/config.d/devbox-v2" "$v2_ssh_conflict_home/managed.before"
    if HOME="$v2_ssh_conflict_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        source "$ROOT/lib/v2.sh"
        v2_colima() {
            cat <<CONFIG
Host devbox-v2
  HostName 127.0.0.1
  Port 60022
  User generated-admin
  IdentityFile /tmp/devbox-v2-key
CONFIG
        }
        ssh() {
            case " $* " in
                *" -G devbox-v2 "*) command ssh "$@" ;;
                *) return 0 ;;
            esac
        }
        write_v2_ssh_config
    ' >/dev/null 2>&1; then
        printf 'ERROR: conflicting v2 SSH preamble %s was accepted\n' "$v2_ssh_conflict" >&2
        exit 1
    fi
    cmp "$v2_ssh_conflict_home/config.before" "$v2_ssh_conflict_home/.ssh/config"
    cmp "$v2_ssh_conflict_home/managed.before" "$v2_ssh_conflict_home/.ssh/config.d/devbox-v2"
done
v2_ssh_pipeline_failure_home="$validation_root/v2-ssh-pipeline-failure-home"
v2_ssh_pipeline_failure_capture="$validation_root/v2-ssh-pipeline-failure-capture"
mkdir -p "$v2_ssh_pipeline_failure_home/.ssh/config.d"
cat >"$v2_ssh_pipeline_failure_home/.ssh/config" <<'EOF'
# existing host SSH configuration
Host existing
  HostName localhost
EOF
printf 'previous managed configuration\n' >"$v2_ssh_pipeline_failure_home/.ssh/config.d/devbox-v2"
cp "$v2_ssh_pipeline_failure_home/.ssh/config" "$v2_ssh_pipeline_failure_home/config.before"
cp "$v2_ssh_pipeline_failure_home/.ssh/config.d/devbox-v2" "$v2_ssh_pipeline_failure_home/managed.before"
if HOME="$v2_ssh_pipeline_failure_home" V2_SSH_PIPELINE_FAILURE_CAPTURE="$v2_ssh_pipeline_failure_capture" \
    ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_colima() {
        printf "Host devbox-v2\n  IdentityFile /incomplete\n"
        return 1
    }
    ssh() { printf "validated-incomplete-configuration\n" >>"$V2_SSH_PIPELINE_FAILURE_CAPTURE"; }
    write_v2_ssh_config
' >/dev/null 2>&1; then
    printf 'ERROR: a partial failed Colima SSH configuration was accepted\n' >&2
    exit 1
fi
cmp "$v2_ssh_pipeline_failure_home/config.before" "$v2_ssh_pipeline_failure_home/.ssh/config"
cmp "$v2_ssh_pipeline_failure_home/managed.before" "$v2_ssh_pipeline_failure_home/.ssh/config.d/devbox-v2"
[ ! -s "$v2_ssh_pipeline_failure_capture" ] || {
    printf 'ERROR: an incomplete Colima SSH configuration was validated\n' >&2
    exit 1
}
! find "$v2_ssh_pipeline_failure_home/.ssh/config.d" -maxdepth 1 -name '.devbox-v2.*' -print -quit | grep -q . || {
    printf 'ERROR: a failed Colima SSH configuration left a temporary managed config\n' >&2
    exit 1
}
v2_ssh_validation_failure_home="$validation_root/v2-ssh-validation-failure-home"
mkdir -p "$v2_ssh_validation_failure_home/.ssh/config.d"
cat >"$v2_ssh_validation_failure_home/.ssh/config" <<'EOF'
# BEGIN devbox
Host devbox
  User legacy-admin
# END devbox
# BEGIN devbox-v2
Host devbox-v2
  User previous-devbox
# END devbox-v2
EOF
printf 'Host devbox-v2\n  User previous-devbox\n' >"$v2_ssh_validation_failure_home/.ssh/config.d/devbox-v2"
chmod 640 "$v2_ssh_validation_failure_home/.ssh/config"
cp "$v2_ssh_validation_failure_home/.ssh/config" "$v2_ssh_validation_failure_home/config.before"
cp "$v2_ssh_validation_failure_home/.ssh/config.d/devbox-v2" "$v2_ssh_validation_failure_home/managed.before"
v2_ssh_validation_failure_config_mode="$(stat -f '%Lp' "$v2_ssh_validation_failure_home/.ssh/config" 2>/dev/null || stat -c '%a' "$v2_ssh_validation_failure_home/.ssh/config")"
if HOME="$v2_ssh_validation_failure_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_colima() {
        cat <<CONFIG
Host devbox-v2
  HostName 127.0.0.1
  IdentityFile /tmp/devbox-v2-key
CONFIG
    }
    ssh() {
        case " $* " in
            *" -G devbox-v2 "*) return 0 ;;
            *) return 1 ;;
        esac
    }
    write_v2_ssh_config
' >/dev/null 2>&1; then
    printf 'ERROR: an unreachable staged v2 SSH configuration was accepted\n' >&2
    exit 1
fi
cmp "$v2_ssh_validation_failure_home/config.before" "$v2_ssh_validation_failure_home/.ssh/config"
cmp "$v2_ssh_validation_failure_home/managed.before" "$v2_ssh_validation_failure_home/.ssh/config.d/devbox-v2"
[ "$(stat -f '%Lp' "$v2_ssh_validation_failure_home/.ssh/config" 2>/dev/null || stat -c '%a' "$v2_ssh_validation_failure_home/.ssh/config")" = "$v2_ssh_validation_failure_config_mode" ] || {
    printf 'ERROR: failed v2 SSH validation changed the existing config mode\n' >&2
    exit 1
}
v2_ssh_interrupted_update_home="$validation_root/v2-ssh-interrupted-update-home"
mkdir -p "$v2_ssh_interrupted_update_home/.ssh/config.d"
cat >"$v2_ssh_interrupted_update_home/.ssh/config" <<'EOF'
# existing host SSH configuration
Host existing
  HostName localhost
EOF
printf 'Host devbox-v2\n  User previous-devbox\n' >"$v2_ssh_interrupted_update_home/.ssh/config.d/devbox-v2"
cp "$v2_ssh_interrupted_update_home/.ssh/config" "$v2_ssh_interrupted_update_home/config.before"
cp "$v2_ssh_interrupted_update_home/.ssh/config.d/devbox-v2" "$v2_ssh_interrupted_update_home/managed.before"
if HOME="$v2_ssh_interrupted_update_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_colima() {
        printf "Host devbox-v2\n  HostName 127.0.0.1\n  Port 60022\n  IdentityFile /tmp/devbox-v2-key\n"
    }
    ssh() {
        case " $* " in
            *" -G devbox-v2 "*) command ssh "$@" ;;
            *) return 0 ;;
        esac
    }
    mv() {
        command mv "$@"
        [ "$2" = "$HOME/.ssh/config.d/devbox-v2" ] && kill -TERM "$$"
    }
    write_v2_ssh_config
' >/dev/null 2>&1; then
    printf 'ERROR: interrupted v2 SSH update was accepted\n' >&2
    exit 1
fi
[ -f "$v2_ssh_interrupted_update_home/.ssh/config.d/.devbox-v2-transaction" ] || {
    printf 'ERROR: interrupted v2 SSH update did not leave a recovery journal\n' >&2
    exit 1
}
HOME="$v2_ssh_interrupted_update_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_colima() {
        printf "Host devbox-v2\n  HostName 127.0.0.1\n  Port 60022\n  IdentityFile /tmp/devbox-v2-key\n"
    }
    ssh() {
        case " $* " in
            *" -G devbox-v2 "*) command ssh "$@" ;;
            *) return 0 ;;
        esac
    }
    eval "$(declare -f recover_v2_ssh_config_transaction | sed "1s/recover_v2_ssh_config_transaction/recover_v2_ssh_config_transaction_impl/")"
    recover_v2_ssh_config_transaction() {
        recover_v2_ssh_config_transaction_impl "$@"
        cmp "$HOME/config.before" "$HOME/.ssh/config"
        cmp "$HOME/managed.before" "$HOME/.ssh/config.d/devbox-v2"
    }
    write_v2_ssh_config
    [ ! -e "$HOME/.ssh/config.d/.devbox-v2-transaction" ]
' || {
    printf 'ERROR: interrupted v2 SSH update was not recovered before retrying\n' >&2
    exit 1
}
v2_ssh_interrupted_cleanup_home="$validation_root/v2-ssh-interrupted-cleanup-home"
mkdir -p "$v2_ssh_interrupted_cleanup_home/.ssh/config.d"
cat >"$v2_ssh_interrupted_cleanup_home/.ssh/config" <<'EOF'
# BEGIN devbox
Host devbox
  User legacy-admin
# END devbox
# BEGIN devbox-v2
Host devbox-v2
  User devbox
# END devbox-v2
EOF
printf 'Host devbox-v2\n  User devbox\n' >"$v2_ssh_interrupted_cleanup_home/.ssh/config.d/devbox-v2"
chmod 640 "$v2_ssh_interrupted_cleanup_home/.ssh/config"
v2_ssh_interrupted_cleanup_config_mode="$(stat -f '%Lp' "$v2_ssh_interrupted_cleanup_home/.ssh/config" 2>/dev/null || stat -c '%a' "$v2_ssh_interrupted_cleanup_home/.ssh/config")"
if HOME="$v2_ssh_interrupted_cleanup_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    mv() {
        command mv "$@"
        [ "$2" = "$HOME/.ssh/config" ] && kill -TERM "$$"
        return 0
    }
    remove_v2_ssh_config
' >/dev/null 2>&1; then
    printf 'ERROR: interrupted v2 SSH cleanup was accepted\n' >&2
    exit 1
fi
[ -f "$v2_ssh_interrupted_cleanup_home/.ssh/config.d/.devbox-v2-transaction" ] || {
    printf 'ERROR: interrupted v2 SSH cleanup did not leave a recovery journal\n' >&2
    exit 1
}
[ -e "$v2_ssh_interrupted_cleanup_home/.ssh/config.d/devbox-v2" ] || {
    printf 'ERROR: interrupted v2 SSH cleanup removed its managed configuration before the direct alias\n' >&2
    exit 1
}
! grep -qx '# BEGIN devbox-v2' "$v2_ssh_interrupted_cleanup_home/.ssh/config" || {
    printf 'ERROR: interrupted v2 SSH cleanup left its direct alias active\n' >&2
    exit 1
}
! grep -qx 'Host devbox-v2' "$v2_ssh_interrupted_cleanup_home/.ssh/config" || {
    printf 'ERROR: interrupted v2 SSH cleanup left its direct host block active\n' >&2
    exit 1
}
HOME="$v2_ssh_interrupted_cleanup_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    remove_v2_ssh_config
    [ ! -e "$HOME/.ssh/config.d/.devbox-v2-transaction" ]
    [ ! -e "$HOME/.ssh/config.d/devbox-v2" ]
    ! grep -q "# BEGIN devbox-v2" "$HOME/.ssh/config"
    grep -qx "# BEGIN devbox" "$HOME/.ssh/config"
    grep -qx "  User legacy-admin" "$HOME/.ssh/config"
' || {
    printf 'ERROR: interrupted v2 SSH cleanup was not recovered\n' >&2
    exit 1
}
[ "$(stat -f '%Lp' "$v2_ssh_interrupted_cleanup_home/.ssh/config" 2>/dev/null || stat -c '%a' "$v2_ssh_interrupted_cleanup_home/.ssh/config")" = "$v2_ssh_interrupted_cleanup_config_mode" ] || {
    printf 'ERROR: v2 SSH cleanup changed the existing config mode\n' >&2
    exit 1
}
v2_ssh_remove_failure_home="$validation_root/v2-ssh-remove-failure-home"
mkdir -p "$v2_ssh_remove_failure_home/.ssh/config.d"
cat >"$v2_ssh_remove_failure_home/.ssh/config" <<'EOF'
# BEGIN devbox
Host devbox
# END devbox
# BEGIN devbox-v2
Host devbox-v2
EOF
printf 'previous managed configuration\n' >"$v2_ssh_remove_failure_home/.ssh/config.d/devbox-v2"
cp "$v2_ssh_remove_failure_home/.ssh/config" "$v2_ssh_remove_failure_home/config.before"
cp "$v2_ssh_remove_failure_home/.ssh/config.d/devbox-v2" "$v2_ssh_remove_failure_home/managed.before"
if HOME="$v2_ssh_remove_failure_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    remove_v2_ssh_config
' >/dev/null 2>&1; then
    printf 'ERROR: malformed v2 SSH markers were accepted during cleanup\n' >&2
    exit 1
fi
cmp "$v2_ssh_remove_failure_home/config.before" "$v2_ssh_remove_failure_home/.ssh/config"
cmp "$v2_ssh_remove_failure_home/managed.before" "$v2_ssh_remove_failure_home/.ssh/config.d/devbox-v2"
v2_ssh_marker_failure_capture="$validation_root/v2-ssh-marker-failure-capture"
if HOME="$v2_ssh_remove_failure_home" V2_SSH_MARKER_FAILURE_CAPTURE="$v2_ssh_marker_failure_capture" \
    ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_colima() {
        cat <<CONFIG
Host devbox-v2
  HostName 127.0.0.1
  IdentityFile /tmp/devbox-v2-key
CONFIG
    }
    ssh() { printf "validated-malformed-configuration\n" >>"$V2_SSH_MARKER_FAILURE_CAPTURE"; }
    write_v2_ssh_config
' >/dev/null 2>&1; then
    printf 'ERROR: malformed v2 SSH markers were accepted during update\n' >&2
    exit 1
fi
cmp "$v2_ssh_remove_failure_home/config.before" "$v2_ssh_remove_failure_home/.ssh/config"
cmp "$v2_ssh_remove_failure_home/managed.before" "$v2_ssh_remove_failure_home/.ssh/config.d/devbox-v2"
[ ! -s "$v2_ssh_marker_failure_capture" ] || {
    printf 'ERROR: malformed v2 SSH markers reached SSH validation\n' >&2
    exit 1
}
v2_colima_ssh_config="$validation_root/colima-ssh-config"
v2_colima_identity_file="$validation_root/colima-identity-file"
v2_ssh_keygen_capture="$validation_root/v2-ssh-keygen"
ssh-keygen -q -t ed25519 -N '' -f "$v2_colima_identity_file"
cat >"$v2_colima_ssh_config" <<EOF
Host devbox-v2
  HostName 127.0.0.1
  Port 60022
  User generated-admin
  IdentityFile "$v2_colima_identity_file"
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
HOME="$v2_home" V2_COLIMA_SSH_CONFIG="$v2_colima_ssh_config" \
    V2_EXPECTED_IDENTITY_FILE="$v2_colima_identity_file" V2_SSH_KEYGEN_CAPTURE="$v2_ssh_keygen_capture" \
    ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_colima() {
        [ "$1" = ssh-config ] && [ "$2" = "$V2_PROFILE" ] || exit 1
        cat "$V2_COLIMA_SSH_CONFIG"
    }
    ssh-keygen() {
        printf "%s\n" "$*" >>"$V2_SSH_KEYGEN_CAPTURE"
        command ssh-keygen "$@"
    }
    quoted_public_key="$(v2_host_public_key)"
    expected_public_key="$(command ssh-keygen -y -f "$V2_EXPECTED_IDENTITY_FILE")"
    [ "$quoted_public_key" = "$expected_public_key" ]
    [ "$(v2_host_ssh_user)" = generated-admin ]
    sed "s|\"$V2_EXPECTED_IDENTITY_FILE\"|$V2_EXPECTED_IDENTITY_FILE|" \
        "$V2_COLIMA_SSH_CONFIG" >"$V2_COLIMA_SSH_CONFIG.unquoted"
    V2_COLIMA_SSH_CONFIG="$V2_COLIMA_SSH_CONFIG.unquoted"
    [ "$(v2_host_public_key)" = "$expected_public_key" ]
    [ "$(cat "$V2_SSH_KEYGEN_CAPTURE")" = "-y -f $V2_EXPECTED_IDENTITY_FILE
-y -f $V2_EXPECTED_IDENTITY_FILE" ]
'
v2_transport_capture="$validation_root/v2-transport"
HOME="$v2_home" V2_TRANSPORT_CAPTURE="$v2_transport_capture" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    ssh() { printf "%s\n" "$*" >"$V2_TRANSPORT_CAPTURE"; }
    v2_guest id -un
    [ "$(cat "$V2_TRANSPORT_CAPTURE")" = "-o BatchMode=yes -o ConnectTimeout=10 devbox-v2 -- id -un" ]
'
v2_guest_dispatch_home="$validation_root/v2-guest-dispatch-home"
mkdir -p "$v2_guest_dispatch_home"
HOME="$v2_home" V2_GUEST_DISPATCH_HOME="$v2_guest_dispatch_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    V2_GUEST_HOME="$V2_GUEST_DISPATCH_HOME"
    v2_admin_guest() {
        [ "$1" = sudo ] && [ "$2" = -u ] && [ "$4" = -- ] || exit 1
        shift 4
        "$@"
    }
    v2_as_guest env \
        DEVBOX_GUEST_CONFIG_ROOT="$V2_GUEST_HOME/.config/devbox-v2" \
        DEVBOX_PROVISION_ROOT="$V2_GUEST_HOME/provisioning" \
        DEVBOX_NO_MOUNTS=true \
        bash -c '\''
            [ "$HOME" = "$PWD" ]
            [ -n "$HOME" ] && [ "$HOME" != / ]
            [ "$DEVBOX_GUEST_CONFIG_ROOT" = "$HOME/.config/devbox-v2" ]
            [ "$DEVBOX_PROVISION_ROOT" = "$HOME/provisioning" ]
            [ "$DEVBOX_NO_MOUNTS" = true ]
            directory="$DEVBOX_GUEST_CONFIG_ROOT"
            [ -n "$directory" ] && [ "$directory" != / ]
            mkdir -p "$directory"
            mkdir -p "$DEVBOX_PROVISION_ROOT"
            temporary="$(mktemp "$directory/.config.XXXXXX")"
            printf guest-env >"$temporary"
            mv "$temporary" "$directory/config"
            printf "%s\n" "$HOME" >"$DEVBOX_PROVISION_ROOT/home"
        '\''
    [ "$(cat "$V2_GUEST_HOME/.config/devbox-v2/config")" = guest-env ]
    [ "$(cat "$V2_GUEST_HOME/provisioning/home")" = "$V2_GUEST_HOME" ]
'
v2_stage_capture="$validation_root/v2-stage-dispatch"
v2_admin_home=/home/generated-admin
v2_devbox_home=/home/devbox
HOME="$v2_home" V2_STAGE_CAPTURE="$v2_stage_capture" V2_ADMIN_HOME="$v2_admin_home" \
    V2_DEVBOX_HOME="$v2_devbox_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() { printf "%s\n" "$@" >"$V2_STAGE_CAPTURE"; }
    stage_v2_guest_provisioning_input 0123456789abcdef
    grep -Fq "source_root=\"\$root/bundles/\$digest\"" "$V2_STAGE_CAPTURE"
    grep -Fq "parent=\"\$root/provisioning\"" "$V2_STAGE_CAPTURE"
    ! grep -Fq "$HOME" "$V2_STAGE_CAPTURE"
    ! grep -Fq "$V2_ADMIN_HOME" "$V2_STAGE_CAPTURE"
    ! grep -Fq "$V2_DEVBOX_HOME" "$V2_STAGE_CAPTURE"
    grep -qx 0123456789abcdef "$V2_STAGE_CAPTURE"
'
sshd_fixture="$validation_root/sshd_config"
sshd_host_key="$validation_root/ssh_host_ed25519_key"
ssh-keygen -q -t ed25519 -N '' -f "$sshd_host_key"
ROOT="$ROOT" sshd_fixture="$sshd_fixture" sshd_host_key="$sshd_host_key" /bin/bash -c '
    source "$ROOT/lib/v2.sh"
    {
        printf "HostKey %s\\n" "$sshd_host_key"
        v2_sshd_authorized_keys_config
        printf "Port 22022\\n"
    } >"$sshd_fixture"
    sshd -t -f "$sshd_fixture"
    for user in devbox generated-admin; do
        sshd -T -f "$sshd_fixture" -C "user=$user,host=localhost,addr=127.0.0.1" |
            grep -qx "authorizedkeysfile /etc/ssh/authorized_keys/%u"
    done
'
shared_lock_home="$validation_root/shared-lock-home"
HOME="$shared_lock_home" PROFILE=devbox ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    configure_paths
    legacy_lock="$DEVBOX_LOCK_DIR"
    acquire_lock lifecycle
    source "$ROOT/lib/v2.sh"
    configure_v2_paths
    [ "$DEVBOX_LOCK_DIR" = "$legacy_lock" ]
    [ -d "$DEVBOX_LOCK_DIR/lifecycle" ]
    if (acquire_lock lifecycle) >/dev/null 2>&1; then
        printf "ERROR: v2 acquired a legacy lifecycle lock\n" >&2
        exit 1
    fi
    release_lock
'
grep -q 'DEVBOX_PROVISION_ROOT="/var/lib/devbox-v2/bundles/$1"' lib/v2.sh
grep -q 'v2_admin_guest sudo -u "$V2_GUEST_USER" -- env' lib/v2.sh
grep -q 'HOME="$V2_GUEST_HOME"' lib/v2.sh
grep -q 'PWD="$V2_GUEST_HOME"' lib/v2.sh
grep -q 'cd -- "$home"' lib/v2.sh
grep -q 'v2_as_guest env' lib/v2.sh
grep -q 'DEVBOX_GUEST_CONFIG_ROOT="$V2_GUEST_CONFIG_ROOT"' lib/v2.sh
grep -q 'DEVBOX_PROVISION_ROOT="$V2_GUEST_PROVISIONING_ROOT/$digest"' lib/v2.sh
grep -q 'DEVBOX_NO_MOUNTS=true' lib/v2.sh
grep -q 'run_v2_root_apps "$digest"' lib/v2.sh
grep -q 'source "$DEVBOX_PROVISION_ROOT/scripts/lib/apps.sh"' lib/v2.sh
grep -q 'install_databricks' lib/v2.sh
grep -q 'sudo env DEVBOX_PROVISION_ROOT="$DEVBOX_PROVISION_ROOT" bash -s' lib/v2.sh
v2_root_apps_line="$(grep -n 'run_v2_root_apps "$digest"' lib/v2.sh | cut -d: -f1)"
v2_user_tools_line="$(grep -n 'bash "$DEVBOX_PROVISION_ROOT/scripts/tools.sh"' lib/v2.sh | cut -d: -f1)"
[ "$v2_root_apps_line" -lt "$v2_user_tools_line" ] || {
    printf 'ERROR: v2 root app provisioning must run before devbox tools\n' >&2
    exit 1
}
grep -A 1 -F 'if command -v databricks' provision/scripts/lib/apps.sh | grep -qx '        return' || {
    printf 'ERROR: Databricks version check must exit before sudo when v2 root provisioning installed it\n' >&2
    exit 1
}
grep -q 'V2_GUEST_WORKSPACE="$V2_GUEST_HOME/workspace"' lib/v2.sh
grep -q 'root=/var/lib/devbox-v2' lib/v2.sh
grep -Fq '{ [ ! -e /var/lib/devbox-v2 ] && [ ! -L /var/lib/devbox-v2 ]; }' lib/v2.sh
grep -Fq 'install -d -o root -g root -m 755 /var/lib/devbox-v2' lib/v2.sh
grep -Fq '{ [ ! -e "$root" ] && [ ! -L "$root" ]; }' lib/v2.sh
grep -q 'install -d -o root -g root -m 700 "$root"' lib/v2.sh
v2_root_parent_create_line="$(grep -n -F '        install -d -o root -g root -m 755 /var/lib/devbox-v2' lib/v2.sh | cut -d: -f1)"
v2_bundle_create_line="$(grep -n -F '        install -d -o root -g root -m 700 "$root"' lib/v2.sh | cut -d: -f1)"
v2_bundle_validate_line="$(grep -n -F '        [ -d "$root" ] && [ ! -L "$root" ] || {' lib/v2.sh | head -n 1 | cut -d: -f1)"
v2_bundle_extract_line="$(grep -n -F '        temporary="$(mktemp -d "$root/.bundle.XXXXXX")"' lib/v2.sh | cut -d: -f1)"
[ "$v2_root_parent_create_line" -lt "$v2_bundle_create_line" ] &&
    [ "$v2_bundle_create_line" -lt "$v2_bundle_validate_line" ] &&
    [ "$v2_bundle_validate_line" -lt "$v2_bundle_extract_line" ] || {
    printf 'ERROR: v2 bundle root creation must precede validation and extraction\n' >&2
    exit 1
}
grep -q 'find "$temporary/provision" -type d -exec chmod 700' lib/v2.sh
grep -q 'find "$temporary/provision" -type f -exec chmod 600' lib/v2.sh
grep -q 'find "$temporary/provision" -type l' lib/v2.sh
grep -q 'find "$source_root" -type l' lib/v2.sh
grep -q '\[ ! -L "$parent" \]' lib/v2.sh
grep -q '\[ ! -L "$keys_dir" \]' lib/v2.sh
grep -q 'keys_dir=/etc/ssh/authorized_keys' lib/v2.sh
grep -qx "V2_SSH_AUTHORIZED_KEYS_FILE='/etc/ssh/authorized_keys/%u'" lib/v2.sh
grep -q 'sshd_settings="$(v2_sshd_authorized_keys_config)"' lib/v2.sh
! grep -q 'Match User' lib/v2.sh
! grep -q 'home=/home/devbox' lib/v2.sh
grep -q 'configure_v2_guest_identity' provision/scripts/system.sh
grep -q 'useradd --create-home --home-dir "$guest_home" --shell "$zsh_path" --user-group "$guest_user"' provision/scripts/system.sh
grep -q '\[ "$guest_uid" -gt 0 \]' provision/scripts/system.sh
grep -q '\[ "$guest_gid" -gt 0 \]' provision/scripts/system.sh
grep -q '\[ "$group_name" = "$guest_user" \]' provision/scripts/system.sh
grep -q '\[ "$group_gid" = "$guest_gid" \]' provision/scripts/system.sh
grep -q 'existing v2 guest user has an unsafe identity or group' provision/scripts/system.sh
grep -q 'new v2 guest user has an unsafe identity or group' provision/scripts/system.sh
grep -q 'id -nG "$guest_user"' provision/scripts/system.sh
v2_identity_validator="$validation_root/v2-guest-identity-validator.sh"
sed -n '/^v2_guest_identity_is_safe() {/,/^}/p' provision/scripts/system.sh >"$v2_identity_validator"
bash -c '
    source "$1"
    ! v2_guest_identity_is_safe devbox 0 0 devbox 0 "" devbox 1 1
    ! v2_guest_identity_is_safe devbox 1000 999 docker 999 "" docker 1 1
    ! v2_guest_identity_is_safe devbox 1000 999 devbox 999 "" "devbox sudo" 1 1
    ! v2_guest_identity_is_safe devbox 1000 999 devbox 999 "" "devbox docker" 1 1
    ! v2_guest_identity_is_safe devbox 1000 999 devbox 999 "" "devbox lxd" 1 1
    ! v2_guest_identity_is_safe devbox 1000 999 devbox 999 "" "devbox libvirt" 1 1
    ! v2_guest_identity_is_safe devbox 1000 999 devbox 999 "" "devbox shadow" 1 1
    ! v2_guest_identity_is_safe devbox 1000 999 devbox 999 "" devbox 2 1
    ! v2_guest_identity_is_safe devbox 1000 999 devbox 999 "" devbox 1 2
    v2_guest_identity_is_safe devbox 1000 999 devbox 999 "" devbox 1 1
' _ "$v2_identity_validator" || {
    printf 'ERROR: v2 guest identity validation accepted unsafe new or existing account groups\n' >&2
    exit 1
}
v2_current_digest_access_capture="$validation_root/v2-current-digest-access"
grep -Fq 'sudo -n -l -U "$user"' lib/v2.sh
grep -Fq 'is not allowed to run sudo on' lib/v2.sh
grep -Fq 'sudo -u "$user" -- sudo -n true' lib/v2.sh
grep -Fq 'sudo -u "$user" -- test -w /var/run/docker.sock' lib/v2.sh
! grep -Fq 'NOPASSWD' lib/v2.sh || {
    printf 'ERROR: v2 guest privilege parser must not rely on NOPASSWD parsing\n' >&2
    exit 1
}
grep -Fq 'chmod 644 "$temporary"' lib/v2.sh || {
    printf 'ERROR: v2 authorized_keys must be readable by the target user (sshd reads it unprivileged)\n' >&2
    exit 1
}
v2_guest_privileges_remote_shell="$validation_root/v2-guest-privileges-remote-shell"
HOME="$v2_home" V2_GUEST_PRIVILEGES_REMOTE_SHELL="$v2_guest_privileges_remote_shell" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() {
        [ "$1" = sudo ] && [ "$2" = bash ] && [ "$3" = -c ] || exit 1
        printf "%s" "$4" >"$V2_GUEST_PRIVILEGES_REMOTE_SHELL"
    }
    validate_v2_guest_privileges
'
bash -n "$v2_guest_privileges_remote_shell" || {
    printf 'ERROR: v2 guest privilege parser is not valid remote Bash\n' >&2
    exit 1
}
HOME="$v2_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() {
        [ "$1" = sudo ] && [ "$2" = bash ] && [ "$3" = -c ] || exit 1
        bash -c "$4" "$5" "$6"
    }
    sudo() {
        [ "$1" = -n ] && [ "$2" = -l ] && [ "$3" = -U ] && [ "$4" = devbox ] || return 1
        printf "User devbox is not allowed to run sudo on guest.\n"
        return 1
    }
    export -f sudo
    validate_v2_guest_privileges
' || {
    printf 'ERROR: v2 guest privilege parser failed in the nested remote Bash execution\n' >&2
    exit 1
}
V2_GUEST_PRIVILEGES_REMOTE_SHELL="$v2_guest_privileges_remote_shell" /bin/bash -c '
    sudo() {
        [ "$1" = -n ] && [ "$2" = -l ] && [ "$3" = -U ] && [ "$4" = devbox ] || return 1
        printf "Matching Defaults entries for devbox on guest:\n    !authenticate, env_reset\nUser devbox may run the following commands:\n    (root) /usr/bin/id\n"
    }
    export -f sudo
    bash -c "$(cat "$V2_GUEST_PRIVILEGES_REMOTE_SHELL")" _ devbox
' >/dev/null 2>&1 && {
    printf 'ERROR: v2 guest privilege parser accepted !authenticate Defaults\n' >&2
    exit 1
}
v2_remote_payloads_dir="$validation_root/v2-remote-payloads"
mkdir -p "$v2_remote_payloads_dir"
HOME="$v2_home" V2_REMOTE_PAYLOADS_DIR="$v2_remote_payloads_dir" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/v2.sh"
    v2_host_ssh_user() { printf "admin\n"; }
    v2_host_public_key() {
        printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test\n"
    }
    capture_payloads() {
        local i j target
        for ((i = 1; i <= $#; i++)); do
            if [ "${!i}" = "-c" ]; then
                j=$((i + 1))
                target="$(mktemp "$V2_REMOTE_PAYLOADS_DIR/payload.XXXXXX")"
                printf "%s" "${!j}" >"$target"
            fi
        done
        return 0
    }
    v2_admin_guest() { capture_payloads "$@"; }
    v2_as_guest() { capture_payloads "$@"; }
    authorize_v2_host_key || true
    validate_v2_guest_identity || true
    validate_v2_guest_privileges || true
    remove_v2_managed_guest_ssh_authorization || true
' || {
    printf 'ERROR: v2 remote payload capture failed\n' >&2
    exit 1
}
v2_remote_payload_count=0
for v2_remote_payload in "$v2_remote_payloads_dir"/payload.*; do
    [ -f "$v2_remote_payload" ] || continue
    v2_remote_payload_count=$((v2_remote_payload_count + 1))
    bash -n "$v2_remote_payload" || {
        printf 'ERROR: a v2 guest remote payload is not valid Bash: %s\n' "$v2_remote_payload" >&2
        exit 1
    }
done
[ "$v2_remote_payload_count" -ge 4 ] || {
    printf 'ERROR: expected to capture at least 4 v2 remote payloads, captured %s\n' "$v2_remote_payload_count" >&2
    exit 1
}
v2_guest_privileges_docker_write_capture="$validation_root/v2-guest-privileges-docker-write"
HOME="$v2_home" V2_GUEST_PRIVILEGES_DOCKER_WRITE_CAPTURE="$v2_guest_privileges_docker_write_capture" \
    ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() { "$@"; }
    sudo() {
        case "$1" in
            bash)
                shift
                command bash "$@"
                ;;
            -n)
                [ "$2" = -l ] && [ "$3" = -U ] && [ "$4" = devbox ] || return 1
                case "$V2_GUEST_PRIVILEGE_FIXTURE" in
                    nopasswd)
                        printf "User devbox may run the following commands:\\n    (root) NOPASSWD: ALL\\n"
                        ;;
                    noauthenticate)
                        printf "Matching Defaults entries for devbox on guest:\\n    !authenticate, env_reset\\nUser devbox may run the following commands:\\n    (root) /usr/bin/id\\n"
                        ;;
                    overridden)
                        printf "Matching Defaults entries for devbox on guest:\\n    !authenticate, authenticate\\nUser devbox may run the following commands:\\n    (root) /usr/bin/id\\n"
                        ;;
                    command-specific)
                        printf "Matching Defaults entries for devbox on guest:\\n    env_reset\\nRunas and Command-specific defaults for devbox on guest:\\n    Defaults!/usr/bin/id !authenticate\\nUser devbox may run the following commands:\\n    (root) /usr/bin/id\\n"
                        ;;
                    command-specific-overridden)
                        printf "Matching Defaults entries for devbox on guest:\\n    env_reset\\nRunas and Command-specific defaults for devbox on guest:\\n    Defaults!/usr/bin/id !authenticate\\n    Defaults!/usr/bin/id authenticate\\nUser devbox may run the following commands:\\n    (root) /usr/bin/id\\n"
                        ;;
                    command-text)
                        printf "Matching Defaults entries for devbox on guest:\\n    env_reset\\nUser devbox may run the following commands:\\n    (root) /usr/bin/printf !authenticate\\n"
                        ;;
                    docker-write)
                        printf "User devbox is not allowed to run sudo on colima-devbox-v2.\\n"
                        ;;
                    passworded-sudo)
                        printf "Matching Defaults entries for devbox on guest:\\n    authenticate, env_reset\\nUser devbox may run the following commands:\\n    (root) /usr/bin/id\\n"
                        ;;
                    no-privileges)
                        printf "User devbox is not allowed to run sudo on guest.\\n" >&2
                        return 1
                        ;;
                    canonical-no-privileges)
                        printf "User devbox is not allowed to run sudo on colima-devbox-v2.\\n"
                        ;;
                    canonical-no-privileges-extra-output)
                        printf "User devbox is not allowed to run sudo on colima-devbox-v2.\\nunrecognized trailing content\\n"
                        ;;
                    parser-failure)
                        printf "unrecognized sudo listing\\n"
                        ;;
                    invalid-trailing-content)
                        printf "Matching Defaults entries for devbox on guest:\\n    authenticate, env_reset\\nUser devbox may run the following commands:\\n    (root) /usr/bin/id\\nunrecognized trailing content\\n"
                        ;;
                    probe-success)
                        printf "User devbox is not allowed to run sudo on colima-devbox-v2.\\n"
                        ;;
                    *) return 1 ;;
                esac
                ;;
            -u)
                [ "$2" = devbox ] && [ "$3" = -- ] || return 1
                if [ "$4" = sudo ] && [ "$5" = -n ] && [ "$6" = true ]; then
                    [ "$V2_GUEST_PRIVILEGE_FIXTURE" = probe-success ]
                elif [ "$4" = test ] && [ "$5" = -w ] && [ "$6" = /var/run/docker.sock ]; then
                    [ "$V2_GUEST_PRIVILEGE_FIXTURE" = docker-write ]
                else
                    return 1
                fi
                ;;
            *) return 1 ;;
        esac
    }
    [() {
        if [[ "$1" = -S && "$2" = /var/run/docker.sock && "$3" = "]" ]]; then
            return 0
        fi
        builtin test "${@:1:$#-1}"
    }
    export -f sudo [
    V2_GUEST_PRIVILEGE_FIXTURE=nopasswd
    export V2_GUEST_PRIVILEGE_FIXTURE
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=noauthenticate
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=docker-write
    if validate_v2_guest_privileges >"$V2_GUEST_PRIVILEGES_DOCKER_WRITE_CAPTURE" 2>&1; then
        exit 1
    fi
    grep -Fxq "ERROR: v2 guest user can write the Docker socket" "$V2_GUEST_PRIVILEGES_DOCKER_WRITE_CAPTURE" || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=overridden
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=command-specific
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=command-specific-overridden
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=command-text
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=passworded-sudo
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=no-privileges
    validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=canonical-no-privileges
    validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=canonical-no-privileges-extra-output
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=parser-failure
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=invalid-trailing-content
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=probe-success
    ! validate_v2_guest_privileges || exit 1
    V2_GUEST_PRIVILEGE_FIXTURE=uninspectable
    ! validate_v2_guest_privileges || exit 1
' || {
    printf 'ERROR: v2 guest privilege preflight accepted unsafe sudo privileges or Docker socket access\n' >&2
    exit 1
}
v2_sudo_probe_revocation_capture="$validation_root/v2-sudo-probe-revocation"
HOME="$v2_home" V2_SUDO_PROBE_REVOCATION_CAPTURE="$v2_sudo_probe_revocation_capture" \
    ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() { "$@"; }
    validate_v2_guest_identity() { return 0; }
    remove_v2_managed_guest_ssh_authorization() {
        printf "guest-revoked\n" >>"$V2_SUDO_PROBE_REVOCATION_CAPTURE"
    }
    remove_v2_ssh_config() {
        printf "alias-removed\n" >>"$V2_SUDO_PROBE_REVOCATION_CAPTURE"
    }
    authorize_v2_host_key() {
        printf "authorized-after-revocation\n" >>"$V2_SUDO_PROBE_REVOCATION_CAPTURE"
        return 1
    }
    write_v2_ssh_config() {
        printf "configured-after-revocation\n" >>"$V2_SUDO_PROBE_REVOCATION_CAPTURE"
    }
    sudo() {
        case "$1" in
            bash)
                shift
                command bash "$@"
                ;;
            -n)
                [ "$2" = -l ] && [ "$3" = -U ] && [ "$4" = devbox ] || return 1
                printf "User devbox is not allowed to run sudo on colima-devbox-v2.\n"
                ;;
            -u)
                [ "$2" = devbox ] && [ "$3" = -- ] && [ "$4" = sudo ] && [ "$5" = -n ] && [ "$6" = true ]
                ;;
            *) return 1 ;;
        esac
    }
    export -f sudo
    if (ensure_v2_guest_ssh_access); then
        exit 1
    fi
    [ "$(cat "$V2_SUDO_PROBE_REVOCATION_CAPTURE")" = "guest-revoked
alias-removed" ]
' || {
    printf 'ERROR: successful v2 guest sudo probe did not revoke managed direct SSH access\n' >&2
    exit 1
}
v2_first_provision_access_capture="$validation_root/v2-first-provision-access"
for v2_unsafe_privilege in nopasswd docker-write; do
    if HOME="$v2_home" V2_FIRST_PROVISION_ACCESS_CAPTURE="$v2_first_provision_access_capture" \
        V2_UNSAFE_PRIVILEGE="$v2_unsafe_privilege" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/v2.sh"
        stream_v2_bundle() { :; }
        v2_admin_guest() { return 0; }
        validate_v2_guest_identity() { return 0; }
        validate_v2_guest_privileges() { return 1; }
        remove_v2_managed_guest_ssh_authorization() {
            printf "guest-revoked:%s\n" "$V2_UNSAFE_PRIVILEGE" >>"$V2_FIRST_PROVISION_ACCESS_CAPTURE"
        }
        remove_v2_ssh_config() {
            printf "alias-removed:%s\n" "$V2_UNSAFE_PRIVILEGE" >>"$V2_FIRST_PROVISION_ACCESS_CAPTURE"
        }
        run_v2_root_apps() { printf "root-apps-ran:%s\n" "$V2_UNSAFE_PRIVILEGE" >>"$V2_FIRST_PROVISION_ACCESS_CAPTURE"; }
        stage_v2_guest_provisioning_input() { printf "staged:%s\n" "$V2_UNSAFE_PRIVILEGE" >>"$V2_FIRST_PROVISION_ACCESS_CAPTURE"; }
        sync_v2_guest_config() { printf "synced:%s\n" "$V2_UNSAFE_PRIVILEGE" >>"$V2_FIRST_PROVISION_ACCESS_CAPTURE"; }
        ensure_v2_guest_ssh_access() { printf "authorized:%s\n" "$V2_UNSAFE_PRIVILEGE" >>"$V2_FIRST_PROVISION_ACCESS_CAPTURE"; }
        run_v2_guest_provisioning deadbeef /dev/null
    ' >/dev/null 2>&1; then
        printf 'ERROR: first v2 provisioning accepted unsafe guest privileges\n' >&2
        exit 1
    fi
done
[ "$(grep -c '^guest-revoked:' "$v2_first_provision_access_capture")" -eq 2 ] &&
    [ "$(grep -c '^alias-removed:' "$v2_first_provision_access_capture")" -eq 2 ] &&
    ! grep -Eq '^(root-apps-ran|staged|synced|authorized):' "$v2_first_provision_access_capture" || {
    printf 'ERROR: first v2 provisioning did not revoke direct SSH access before further provisioning\n' >&2
    exit 1
}
HOME="$v2_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/v2.sh"
    v2_admin_guest() { printf "%s\n" "$V2_GUEST_IDENTITY"; }
    V2_GUEST_IDENTITY="0:0:devbox:0::devbox:1:1"
    ! validate_v2_guest_identity
    V2_GUEST_IDENTITY="1000:999:docker:999::docker:1:1"
    ! validate_v2_guest_identity
    V2_GUEST_IDENTITY="1000:999:devbox:999::devbox sudo:1:1"
    ! validate_v2_guest_identity
    V2_GUEST_IDENTITY="1000:999:devbox:999::devbox docker:1:1"
    ! validate_v2_guest_identity
    V2_GUEST_IDENTITY="1000:999:devbox:999::devbox lxd:1:1"
    ! validate_v2_guest_identity
    V2_GUEST_IDENTITY="1000:999:devbox:999::devbox libvirt:1:1"
    ! validate_v2_guest_identity
    V2_GUEST_IDENTITY="1000:999:devbox:999::devbox shadow:1:1"
    ! validate_v2_guest_identity
    V2_GUEST_IDENTITY="1000:999:devbox:999::devbox:2:1"
    ! validate_v2_guest_identity
    V2_GUEST_IDENTITY="1000:999:devbox:999::devbox:1:2"
    ! validate_v2_guest_identity
    V2_GUEST_IDENTITY="1000:999:devbox:999::devbox:1:1"
    validate_v2_guest_identity
' || {
    printf 'ERROR: current-digest v2 guest identity validation accepted an unsafe account\n' >&2
    exit 1
}
v2_workspace_home="$validation_root/v2-workspace-home"
mkdir -p "$v2_workspace_home"
HOME="$v2_home" V2_WORKSPACE_HOME="$v2_workspace_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/v2.sh"
    V2_GUEST_HOME="$V2_WORKSPACE_HOME"
    v2_admin_guest() {
        [ "$1" = sudo ] && [ "$2" = -u ] && [ "$4" = -- ] || exit 1
        shift 4
        "$@"
    }
    reconcile_v2_guest_workspace
    [ -d "$V2_GUEST_HOME/workspace" ] && [ ! -L "$V2_GUEST_HOME/workspace" ]
    [ "$(stat -f "%Lp" "$V2_GUEST_HOME/workspace" 2>/dev/null || stat -c "%a" "$V2_GUEST_HOME/workspace")" = 700 ]
    rm -rf "$V2_GUEST_HOME/workspace"
    mkdir "$V2_GUEST_HOME/workspace"
    chmod 755 "$V2_GUEST_HOME/workspace"
    reconcile_v2_guest_workspace
    [ "$(stat -f "%Lp" "$V2_GUEST_HOME/workspace" 2>/dev/null || stat -c "%a" "$V2_GUEST_HOME/workspace")" = 700 ]
    rm -rf "$V2_GUEST_HOME/workspace"
    ln -s /tmp "$V2_GUEST_HOME/workspace"
    ! reconcile_v2_guest_workspace
    rm "$V2_GUEST_HOME/workspace"
    : >"$V2_GUEST_HOME/workspace"
    ! reconcile_v2_guest_workspace
' || {
    printf 'ERROR: v2 workspace reconciliation did not safely create, repair, or reject workspace paths\n' >&2
    exit 1
}
HOME="$v2_home" V2_CURRENT_DIGEST_ACCESS_CAPTURE="$v2_current_digest_access_capture" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    configure_v2_paths() { :; }
    check_host_platform() { :; }
    check_v2_dependencies() { :; }
    acquire_lock() { :; }
    release_lock() { :; }
    start_v2_vm() { :; }
    create_v2_bundle_snapshot() { V2_BUNDLE_DIGEST=current; V2_BUNDLE_SNAPSHOT="$(mktemp -d)"; }
    v2_guest_provision_digest() { printf current; }
    v2_guest_bundle_is_valid() { return 0; }
    validate_v2_guest_identity() { return 0; }
    validate_v2_guest_privileges() { return 1; }
    sync_v2_guest_config() { printf "synced\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    remove_v2_managed_guest_ssh_authorization() { printf "guest-revoked\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    remove_v2_ssh_config() { printf "alias-removed\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    reconcile_v2_guest_workspace() { printf "workspace-reconciled\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    authorize_v2_host_key() { printf "authorized\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    write_v2_ssh_config() { printf "configured\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    if (run_v2 start) >/dev/null 2>&1; then
        printf "ERROR: current-digest start accepted unsafe v2 guest privileges\n" >&2
        exit 1
    fi
    [ "$(cat "$V2_CURRENT_DIGEST_ACCESS_CAPTURE")" = "guest-revoked
alias-removed" ] || {
        printf "ERROR: current-digest start did not withhold direct v2 SSH access\n" >&2
        exit 1
    }
'
HOME="$v2_home" V2_CURRENT_DIGEST_ACCESS_CAPTURE="$v2_current_digest_access_capture" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    configure_v2_paths() { :; }
    check_host_platform() { :; }
    check_v2_dependencies() { :; }
    acquire_lock() { :; }
    release_lock() { :; }
    start_v2_vm() { :; }
    create_v2_bundle_snapshot() { V2_BUNDLE_DIGEST=current; V2_BUNDLE_SNAPSHOT="$(mktemp -d)"; }
    v2_guest_provision_digest() { printf current; }
    v2_guest_bundle_is_valid() { return 0; }
    validate_v2_guest_identity() { return 0; }
    validate_v2_guest_privileges() { return 0; }
    sync_v2_guest_config() { printf "synced\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    remove_v2_managed_guest_ssh_authorization() { printf "guest-revoked\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    remove_v2_ssh_config() { printf "alias-removed\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    reconcile_v2_guest_workspace() { printf "workspace-reconciled\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    authorize_v2_host_key() { printf "authorized\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    write_v2_ssh_config() { printf "configured\n" >>"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"; }
    : >"$V2_CURRENT_DIGEST_ACCESS_CAPTURE"
    run_v2 start
    [ "$(cat "$V2_CURRENT_DIGEST_ACCESS_CAPTURE")" = "synced
workspace-reconciled
authorized
configured" ] || {
        printf "ERROR: current-digest start did not reconcile its workspace before refreshing direct v2 SSH access\n" >&2
        exit 1
    }
'
v2_provision_failure_home="$validation_root/v2-provision-failure-home"
v2_provision_failure_events="$validation_root/v2-provision-failure-events"
v2_provision_failure_status=0
if HOME="$v2_provision_failure_home" XDG_DATA_HOME="$v2_provision_failure_home/data" \
    V2_PROVISION_FAILURE_EVENTS="$v2_provision_failure_events" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    check_host_platform() { :; }
    check_v2_dependencies() { :; }
    start_v2_vm() { :; }
    create_v2_bundle_snapshot() {
        V2_BUNDLE_DIGEST=failure
        V2_BUNDLE_SNAPSHOT="$(mktemp -d)"
        V2_BUNDLE_ARCHIVE=/dev/null
    }
    v2_guest_provision_digest() { :; }
    stream_v2_bundle() { :; }
    validate_v2_guest_preflight() { :; }
    v2_admin_guest() {
        case "$*" in
            *provision.sha256*) printf "digest-marked-after-failure\n" >>"$V2_PROVISION_FAILURE_EVENTS" ;;
        esac
    }
    run_v2_root_apps() {
        printf "root-app-failed\n" >>"$V2_PROVISION_FAILURE_EVENTS"
        return 1
    }
    stage_v2_guest_provisioning_input() {
        printf "staged-after-failure\n" >>"$V2_PROVISION_FAILURE_EVENTS"
    }
    sync_v2_guest_config() {
        printf "env-synced-after-failure\n" >>"$V2_PROVISION_FAILURE_EVENTS"
    }
    ensure_v2_guest_ssh_access() {
        printf "ssh-authorized-after-failure\n" >>"$V2_PROVISION_FAILURE_EVENTS"
    }
    v2_as_guest() {
        printf "tool-verified-after-failure\n" >>"$V2_PROVISION_FAILURE_EVENTS"
    }
    run_v2 start
' >/dev/null 2>&1; then
    printf 'ERROR: v2 provisioning accepted a failed root app stage\n' >&2
    exit 1
else
    v2_provision_failure_status=$?
fi
[ "$v2_provision_failure_status" -ne 0 ]
[ "$(cat "$v2_provision_failure_events")" = "root-app-failed" ] || {
    printf 'ERROR: v2 provisioning continued after a failed root app stage\n' >&2
    exit 1
}
[ ! -d "$v2_provision_failure_home/data/devbox/locks/lifecycle" ] || {
    printf 'ERROR: v2 provisioning failure did not release the lifecycle lock\n' >&2
    exit 1
}
grep -q 'sudo -u "$guest_user" -- env HOME="$guest_home" PWD="$guest_home" bash -c' provision/scripts/system.sh
grep -q 'cd -- "$guest_home"' provision/scripts/system.sh
grep -q 'workspace must be a real directory' provision/scripts/system.sh
grep -q 'remove_v2_managed_guest_ssh_authorization' lib/v2.sh
grep -q 'authorized=/etc/ssh/authorized_keys/devbox' lib/v2.sh
grep -q 'sshd_config=/etc/ssh/sshd_config.d/00-devbox-v2.conf' lib/v2.sh
grep -q 'v2 active user' provision/scripts/verify.sh
grep -q 'v2 root bundle state is inaccessible' provision/scripts/verify.sh
grep -q 'v2 staged provisioning input is root-owned, readable, and read-only' provision/scripts/verify.sh
grep -q 'v2 guest cannot access Docker socket' provision/scripts/verify.sh
grep -q 'v2 guest config permissions' provision/scripts/verify.sh
grep -q 'v2 guest secrets permissions' provision/scripts/verify.sh
grep -q 'head -c 24 /dev/urandom' lib/v2.sh
grep -q 'source "$DEVBOX_GUEST_CONFIG_ROOT/config"' provision/scripts/tools.sh
grep -q 'source "$DEVBOX_GUEST_CONFIG_ROOT/secrets"' provision/scripts/tools.sh
HOME="$v2_home" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/guest.sh"
    source "$ROOT/lib/v2.sh"
    POSTGRES_PASSWORD="must-not-leak"
    rendered="$(render_v2_guest_config)"
    case "$rendered" in
        *POSTGRES_PASSWORD*) exit 1 ;;
    esac
    case "$rendered" in
        *"export GIT_NAME="*) ;;
        *) exit 1 ;;
    esac
' || {
    printf 'ERROR: v2 guest config must exclude host-supplied secrets\n' >&2
    exit 1
}
grep -q 'Host devbox' lib/colima.sh
grep -q 'Host devbox-v2' lib/v2.sh
if "$ROOT/devbox" v2 invalid >/dev/null 2>&1; then
    printf 'ERROR: invalid v2 command was accepted\n' >&2
    exit 1
fi
if "$ROOT/devbox" v2 exec >/dev/null 2>&1; then
    printf 'ERROR: v2 exec without a command was accepted\n' >&2
    exit 1
fi

poc_home="$validation_root/isolation-poc-home"
poc_colima_bin="$validation_root/isolation-poc-bin"
poc_colima_capture="$validation_root/isolation-poc-colima-env"
mkdir -p "$poc_colima_bin"
cat >"$poc_colima_bin/colima" <<'EOF'
#!/bin/bash
if [ "$1" = version ]; then
    printf 'colima version %s\n' "${POC_COLIMA_VERSION:-0.10.3}"
else
    printf '%s\n%s\n' "$LIMA_HOME" "$DOCKER_CONFIG" >"$ISOLATION_POC_COLIMA_CAPTURE"
fi
EOF
chmod 700 "$poc_colima_bin/colima"
HOME="$poc_home" PROFILE=devbox COLIMA_HOME="$poc_home/.colima" LIMA_HOME="$poc_home/.colima/_lima" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/isolation-poc.sh"
    DEVBOX_DIR="$ROOT"
    ifconfig() { return 0; }
    scutil() { :; }
    configure_paths
    configure_isolation_poc_paths
    DEVBOX_ISOLATION_POC_INTERFACE="en0"
    DEVBOX_ISOLATION_POC_DNS="1.1.1.1,1.0.0.1"
    DEVBOX_ISOLATION_POC_DENY_TARGETS="10.0.0.10:443,10.0.0.11:8443"
    validate_isolation_poc_interface
    validate_isolation_poc_dns
    validate_isolation_poc_deny_targets
    if ! check_isolation_poc_ownership; then
        printf "ERROR: a missing isolation POC profile was not accepted\n" >&2
        exit 1
    fi
    if ! render_isolation_poc_config; then
        printf "ERROR: isolation POC configuration rendering failed\n" >&2
        exit 1
    fi
    if ! verify_isolation_poc_config; then
        printf "ERROR: isolation POC runtime configuration verification failed\n" >&2
        exit 1
    fi
'
if HOME="$validation_root/isolation-poc-untrusted-lima-home" PROFILE=devbox \
    COLIMA_HOME="$validation_root/isolation-poc-untrusted-lima-home/.colima" \
    LIMA_HOME="$validation_root/isolation-poc-untrusted-lima-home/custom-lima" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/isolation-poc.sh"
    DEVBOX_DIR="$ROOT"
    configure_paths
    configure_isolation_poc_paths
' >/dev/null 2>&1; then
    printf 'ERROR: isolation POC accepted a redirected LIMA_HOME\n' >&2
    exit 1
fi
[ ! -e "$validation_root/isolation-poc-untrusted-lima-home/.colima/devbox-isolation-poc" ] || {
    printf 'ERROR: redirected LIMA_HOME test created an isolation POC profile\n' >&2
    exit 1
}
HOME="$poc_home" PROFILE=devbox COLIMA_HOME="$poc_home/.colima" LIMA_HOME="$poc_home/.colima/_lima" \
    PATH="$poc_colima_bin:$PATH" ISOLATION_POC_COLIMA_CAPTURE="$poc_colima_capture" ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        source "$ROOT/lib/isolation-poc.sh"
        configure_paths
        configure_isolation_poc_paths
        normal_docker_config="$DOCKER_CONFIG"
        prepare_isolation_poc_docker_config
        isolation_poc_colima start "$ISOLATION_POC_PROFILE"
        [ "$ISOLATION_POC_DOCKER_CONFIG" != "$normal_docker_config" ]
    '
[ "$(sed -n '1p' "$poc_colima_capture")" = "$poc_home/.colima/_lima" ] || {
    printf 'ERROR: isolation POC Colima invocation did not pin LIMA_HOME\n' >&2
    exit 1
}
[ "$(sed -n '2p' "$poc_colima_capture")" = "$poc_home/.config/devbox/isolation-poc/docker" ] || {
    printf 'ERROR: isolation POC Colima invocation did not use its Docker config\n' >&2
    exit 1
}
[ "$(sed -n '2p' "$poc_colima_capture")" != "$poc_home/.config/devbox/docker" ] || {
    printf 'ERROR: isolation POC Colima invocation used the normal devbox Docker config\n' >&2
    exit 1
}
if HOME="$poc_home" PROFILE=devbox COLIMA_HOME="$poc_home/.colima" LIMA_HOME="$poc_home/.colima/_lima" \
    PATH="$poc_colima_bin:$PATH" POC_COLIMA_VERSION="0.10.4" ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        source "$ROOT/lib/isolation-poc.sh"
        configure_paths
        configure_isolation_poc_paths
        prepare_isolation_poc_docker_config
        check_isolation_poc_dependencies
    ' >/dev/null 2>&1; then
    printf 'ERROR: isolation POC accepted an unvalidated Colima topology version\n' >&2
    exit 1
fi
if HOME="$poc_home" COLIMA_HOME="$poc_home/.colima" LIMA_HOME="$poc_home/.colima/_lima" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/isolation-poc.sh"
    DEVBOX_DIR="$ROOT"
    DEVBOX_ISOLATION_POC_DENY_TARGETS="not-an-ip:443"
    validate_isolation_poc_deny_targets
' >/dev/null 2>&1; then
    printf 'ERROR: invalid isolation POC deny target was accepted\n' >&2
    exit 1
fi

awk '
    !/^[[:space:]]*(#|$)/ && $0 !~ /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/ { exit 1 }
' provision/config/install-plugins.txt
grep -q '^OPENCODE_VERSION="2\.' provision/versions.env
grep -q '^OPENCODE_SHA256="[0-9a-f]\{64\}"' provision/versions.env
if grep -R -E -- 'install-skills\.txt|server-filesystem' \
    provision/config/opencode provision/scripts/lib/addons.sh; then
    printf 'ERROR: legacy OpenCode v1 or filesystem MCP configuration found\n' >&2
    exit 1
fi
grep -q 'npm uninstall --global --silent opencode-ai' provision/scripts/lib/apps.sh
if grep -q '^PYENV_VERSION=' provision/versions.env; then
    printf 'ERROR: PYENV_VERSION is reserved by pyenv as a runtime selector\n' >&2
    exit 1
fi

printf 'POSTGRES_USER="dev"\nPOSTGRES_PASSWORD="test"\nPOSTGRES_DB="dev"\nPOSTGRES_PORT="15432"\n' >"$service_env"
docker compose --project-name devbox --env-file "$service_env" \
    -f provision/config/containers/postgres/docker-compose.yml config --quiet

if grep -R -E -- \
    '^[[:space:]]*eval[[:space:]]|curl[^|]*\|[[:space:]]*(ba)?sh|SSH_AUTH_SOCK=/run/host-services|chmod 0777|rm -rf "\$HOME/(projects|data)|/etc/environment|readlink -f' \
    devbox lib provision/scripts provision/config/zsh; then
    printf 'ERROR: prohibited provisioning pattern found\n' >&2
    exit 1
fi
