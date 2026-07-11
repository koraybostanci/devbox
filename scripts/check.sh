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

jq empty \
    provision/config/claude/settings.json \
    provision/config/mcp.json \
    provision/config/opencode/opencode.json

sed \
    -e 's/{{CPU}}/4/g' \
    -e 's/{{MEMORY}}/4/g' \
    -e 's/{{DISK}}/60/g' \
    -e 's|{{PROVISION_PATH}}|"/tmp/devbox/provision"|g' \
    -e 's|{{PROJECTS_PATH}}|"/tmp/devbox/projects"|g' \
    -e 's|{{DATA_PATH}}|"/tmp/devbox/data"|g' \
    colima.yaml >"$rendered_colima"
yq eval '.' "$rendered_colima" >/dev/null

awk '
    !/^[[:space:]]*(#|$)/ {
        if (NF < 3 || $1 != "npx" || $2 ~ /^-/) exit 1
        unattended = 0
        for (field = 2; field <= NF; field++) {
            if ($field == "-y" || $field == "--yes") unattended = 1
            if ($field !~ /^[A-Za-z0-9@.,_=\/:\-]+$/) exit 1
        }
        if (!unattended) exit 1
    }
' provision/config/install-skills.txt
awk '
    !/^[[:space:]]*(#|$)/ && $0 !~ /^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$/ { exit 1 }
' provision/config/install-plugins.txt
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
