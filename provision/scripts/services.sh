#!/bin/bash
# Start, stop, or show the staged devbox services. Runs as root.

set -Eeuo pipefail
trap 'printf "ERROR: devbox services command failed at line %s\n" "$LINENO" >&2' ERR

# Relative sources resolve at runtime from this script's own directory (the
# staged provisioning bundle), never from a pre-set DEVBOX_PROVISION_ROOT.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/docker.sh"

devbox_services_main() {
    local action="${1:-}" services=/var/lib/devbox/services
    local -a compose=(compose --project-name devbox --env-file "$services/env" -f "$services/compose.yaml")

    [ -f "$services/compose.yaml" ] && [ -f "$services/env" ] || {
        printf 'devbox services are not provisioned; run devbox provision\n' >&2
        return 1
    }
    # These root-managed containers must never follow devbox's inherited
    # rootless host/context settings: devbox_docker drops the inherited
    # Docker environment and pins the explicit rootful socket endpoint.
    case "$action" in
        start) devbox_docker unix:///var/run/docker.sock "${compose[@]}" up -d --wait ;;
        stop) devbox_docker unix:///var/run/docker.sock "${compose[@]}" down ;;
        status) devbox_docker unix:///var/run/docker.sock "${compose[@]}" ps ;;
        *)
            printf 'Usage: services.sh <start|stop|status>\n' >&2
            return 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    devbox_services_main "$@"
fi
