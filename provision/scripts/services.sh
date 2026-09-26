#!/bin/bash
# Start, stop, or show the staged devbox services. Runs as root.

set -Eeuo pipefail
trap 'printf "ERROR: devbox services command failed at line %s\n" "$LINENO" >&2' ERR

devbox_services_docker() {
    # These root-managed containers must never follow devbox's inherited
    # rootless host/context settings.
    env -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
        DOCKER_HOST=unix:///var/run/docker.sock docker "$@"
}

devbox_services_main() {
    local action="${1:-}" services=/var/lib/devbox/services
    local -a compose=(compose --project-name devbox --env-file "$services/env" -f "$services/compose.yaml")

    [ -f "$services/compose.yaml" ] && [ -f "$services/env" ] || {
        printf 'devbox services are not provisioned; run devbox provision\n' >&2
        return 1
    }
    case "$action" in
        start) devbox_services_docker "${compose[@]}" up -d --wait ;;
        stop) devbox_services_docker "${compose[@]}" down ;;
        status) devbox_services_docker "${compose[@]}" ps ;;
        *)
            printf 'Usage: services.sh <start|stop|status>\n' >&2
            return 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    devbox_services_main "$@"
fi
