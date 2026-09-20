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
printf 'DEVBOX_ENV_SOURCE=v2\n' >"$zsh_profile_home/.config/devbox-v2/env"
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
    [ "$DEVBOX_LOCK_DIR" = "$HOME/.local/share/devbox/v2/locks" ]
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
    printf "%s\n" "$V2_PROFILE" | run_v2 destroy
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
HOME="$v2_home" V2_ARCHIVE_CAPTURE="$v2_archive_capture" V2_GUEST_BIN="$v2_guest_bin" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/v2.sh"
    create_v2_bundle_snapshot
    [ "$V2_BUNDLE_DIGEST" = "$(v2_bundle_digest "$V2_BUNDLE_SNAPSHOT/provision")" ]
    if tar -tf "$V2_BUNDLE_ARCHIVE" | grep -Eq "(^|/)\\._[^/]*$"; then
        printf "ERROR: v2 bundle archive contains AppleDouble entries\\n" >&2
        exit 1
    fi
    v2_guest() { cat >"$V2_ARCHIVE_CAPTURE"; }
    stream_v2_bundle "$V2_BUNDLE_DIGEST" "$V2_BUNDLE_ARCHIVE"
    cmp "$V2_BUNDLE_ARCHIVE" "$V2_ARCHIVE_CAPTURE"
    v2_guest() { PATH="$V2_GUEST_BIN:$PATH" "$@"; }
    stream_v2_bundle "$V2_BUNDLE_DIGEST" "$V2_BUNDLE_ARCHIVE"
    target="$HOME/.local/share/devbox-v2/bundles/$V2_BUNDLE_DIGEST"
    [ "$(cat "$target/.devbox-bundle.sha256")" = "$V2_BUNDLE_DIGEST" ]
    v2_guest_bundle_is_valid "$V2_BUNDLE_DIGEST"
    target_inode="$(stat -f "%i" "$target")"
    stream_v2_bundle "$V2_BUNDLE_DIGEST" "$V2_BUNDLE_ARCHIVE"
    [ "$(stat -f "%i" "$target")" = "$target_inode" ]
    chmod u+w "$target/scripts/system.sh"
    printf "# corruption coverage\\n" >>"$target/scripts/system.sh"
    if v2_guest_bundle_is_valid "$V2_BUNDLE_DIGEST"; then
        printf "ERROR: corrupt cached v2 bundle was accepted\\n" >&2
        exit 1
    fi
    stream_v2_bundle "$V2_BUNDLE_DIGEST" "$V2_BUNDLE_ARCHIVE"
    [ "$(stat -f "%i" "$target")" != "$target_inode" ]
    v2_guest_bundle_is_valid "$V2_BUNDLE_DIGEST"
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
grep -q 'DEVBOX_PROVISION_ROOT="$HOME/.local/share/devbox-v2/bundles/$1"' lib/v2.sh
grep -q 'DEVBOX_GUEST_CONFIG_ROOT="$HOME/.config/devbox-v2"' lib/v2.sh
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
