#!/bin/bash
# Start, stop, or show the staged devbox services. Runs as root.

set -Eeuo pipefail
trap 'printf "ERROR: devbox services command failed at line %s\n" "$LINENO" >&2' ERR

action="${1:-}"
services=/var/lib/devbox/services
[ -f "$services/compose.yaml" ] && [ -f "$services/env" ] || {
    printf 'devbox services are not provisioned; run devbox provision\n' >&2
    exit 1
}
compose=(docker compose --project-name devbox --env-file "$services/env" -f "$services/compose.yaml")
case "$action" in
    start) "${compose[@]}" up -d --wait ;;
    stop) "${compose[@]}" down ;;
    status) "${compose[@]}" ps ;;
    *)
        printf 'Usage: services.sh <start|stop|status>\n' >&2
        exit 1
        ;;
esac
