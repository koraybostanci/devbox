#!/bin/bash
container_files() {
    local service="$1"
    local file

    if [ "$service" != "all" ]; then
        [[ "$service" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "invalid service name: $service"
        file="$DEVBOX_DIR/provision/config/containers/$service/docker-compose.yml"
        [ -f "$file" ] || die "unknown container service: $service"
        printf '%s\n' "/provision/config/containers/$service/docker-compose.yml"
        return
    fi

    for file in "$DEVBOX_DIR"/provision/config/containers/*/docker-compose.yml; do
        [ -f "$file" ] || continue
        printf '%s\n' "/provision/config/containers/$(basename "$(dirname "$file")")/docker-compose.yml"
    done
}

run_containers() {
    local service subcommand guest_home file
    local -a compose=(docker compose --project-name devbox)

    require_running_vm
    case "$#" in
        1)
            service=all
            subcommand="$1"
            ;;
        2)
            service="$1"
            subcommand="$2"
            ;;
        *) die "Usage: devbox containers [service] <up|down|ps|logs>" ;;
    esac
    case "$subcommand" in
        up | down | ps | logs) ;;
        *) die "Usage: devbox containers [service] <up|down|ps|logs>" ;;
    esac

    guest_home="$(guest_exec bash -c 'printf %s "$HOME"')"
    compose+=(--env-file "$guest_home/.config/devbox/service.env")
    while IFS= read -r file; do
        compose+=(-f "$file")
    done < <(container_files "$service")
    [ ${#compose[@]} -gt 5 ] || die "no container services are configured"

    case "$subcommand" in
        up) guest_exec "${compose[@]}" up -d --wait ;;
        down) guest_exec "${compose[@]}" down ;;
        ps) guest_exec "${compose[@]}" ps -a ;;
        logs) guest_exec "${compose[@]}" logs -f ;;
    esac
}
