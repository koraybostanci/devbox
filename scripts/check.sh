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
