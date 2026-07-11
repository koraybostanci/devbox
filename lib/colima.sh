#!/bin/bash

colima_cmd() {
    check_colima_profile_ownership
    command colima "$@"
}

colima_state() {
    colima_cmd list --json 2>/dev/null |
        jq -r --arg profile "$PROFILE" 'select(.name == $profile) | .status' |
        head -n 1
}

require_running_vm() {
    local state
    state="$(colima_state)"
    [ "$state" = "Running" ] || die "VM is not running; run 'devbox start' first"
}

wait_for_ssh() {
    local attempts=60
    local attempt

    log "Waiting for VM SSH readiness..."
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if colima_cmd ssh -p "$PROFILE" -- true >/dev/null 2>&1; then
            return
        fi
        sleep 2
    done
    die "VM SSH did not become ready within $((attempts * 2)) seconds"
}

wait_for_mounts() {
    local attempts=15
    local attempt

    log "Waiting for persistent mounts..."
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if guest_exec test -d /mnt/devbox/projects -a -d /mnt/devbox/data >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    return 1
}

sync_host_ssh_config() {
    local managed_config="$1"
    local ssh_dir="$HOME/.ssh"
    local config="$ssh_dir/config"
    local begin_marker='# BEGIN devbox'
    local end_marker='# END devbox'
    local config_dir temporary backup begin_count end_count

    mkdir -p "$ssh_dir/config.d"
    chmod 700 "$ssh_dir" "$ssh_dir/config.d"
    if [ -L "$config" ]; then
        config="$(resolve_path "$config")"
    fi
    config_dir="$(dirname "$config")"
    [ -e "$config" ] || : >"$config"
    chmod 600 "$config"

    begin_count="$(grep -Fxc "$begin_marker" "$config" || true)"
    end_count="$(grep -Fxc "$end_marker" "$config" || true)"
    if [ "$begin_count" -ne "$end_count" ] || [ "$begin_count" -gt 1 ]; then
        die "$config contains malformed devbox markers"
    fi

    temporary="$(mktemp "$config_dir/.config.XXXXXX")"
    if [ "$begin_count" -eq 1 ]; then
        awk -v managed="$managed_config" '
            $0 == "# BEGIN devbox" {
                print
                while ((getline line < managed) > 0) print line
                close(managed)
                skipping = 1
                next
            }
            skipping {
                if ($0 == "# END devbox") {
                    print
                    skipping = 0
                }
                next
            }
            NF == 2 && $1 == "Include" && $2 == "~/.ssh/config.d/devbox" { next }
            { print }
            END { if (skipping) exit 1 }
        ' "$config" >"$temporary"
    else
        backup="$config.devbox-backup.$(date +%Y%m%d%H%M%S).$$"
        cp -p "$config" "$backup"
        {
            printf '%s\n' "$begin_marker"
            cat "$managed_config"
            printf '%s\n\n' "$end_marker"
            awk '!(NF == 2 && $1 == "Include" && $2 == "~/.ssh/config.d/devbox")' "$config"
        } >"$temporary"
        log "Added managed devbox SSH entry; backup: $backup"
    fi
    chmod 600 "$temporary"
    if cmp -s "$config" "$temporary"; then
        command rm "$temporary"
        return
    fi
    mv "$temporary" "$config"
}

write_ssh_config() {
    local target="$HOME/.ssh/config.d/devbox"
    local temporary

    mkdir -p "$HOME/.ssh/config.d"
    temporary="$(mktemp "$HOME/.ssh/config.d/.devbox.XXXXXX")"
    colima_cmd ssh-config "$PROFILE" | awk '
        /^Host[[:space:]]/ {
            print "Host devbox"
            print "  ForwardAgent no"
            next
        }
        /^[[:space:]]*ForwardAgent[[:space:]]/ { next }
        { print }
    ' >"$temporary"
    grep -q '^Host devbox$' "$temporary" || die "Colima returned an invalid SSH configuration"
    grep -q '^[[:space:]]*IdentityFile[[:space:]]' "$temporary" || die "Colima SSH configuration has no identity file"
    chmod 600 "$temporary"
    mv "$temporary" "$target"
    sync_host_ssh_config "$target"

    ssh -G devbox >/dev/null 2>&1 || die "generated SSH configuration is invalid"
    ssh -o BatchMode=yes -o ConnectTimeout=10 devbox true >/dev/null 2>&1 ||
        die "generated SSH host 'devbox' is not reachable"
}

remove_ssh_config() {
    local config="$HOME/.ssh/config"
    local config_dir temporary

    command rm -f "$HOME/.ssh/config.d/devbox"
    [ -e "$config" ] || return
    if [ -L "$config" ]; then
        config="$(resolve_path "$config")"
    fi
    config_dir="$(dirname "$config")"
    temporary="$(mktemp "$config_dir/.config.XXXXXX")"
    awk '
        $0 == "# BEGIN devbox" { skipping = 1; next }
        skipping && $0 == "# END devbox" { skipping = 0; next }
        skipping { next }
        NF == 2 && $1 == "Include" && $2 == "~/.ssh/config.d/devbox" { next }
        { print }
        END { if (skipping) exit 1 }
    ' "$config" >"$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$config"
}

start_vm_only() {
    local state

    render_colima_config
    state="$(colima_state)"
    case "$state" in
        Running) ;;
        '' | Stopped)
            colima_cmd start "$PROFILE" \
                --activate=false \
                --ssh-config=false \
                --ssh-agent=false \
                --save-config=false
            ;;
        *) die "VM is in state '$state'; wait for it to settle and retry" ;;
    esac

    wait_for_ssh
    if ! wait_for_mounts; then
        guest_exec true >/dev/null 2>&1 || die "VM SSH became unavailable while waiting for persistent mounts"
        die "persistent mounts are unavailable; if this profile predates /mnt/devbox, run 'devbox rebuild'"
    fi
    write_ssh_config
}

stop_vm() {
    local force="${1:-false}"
    local state

    state="$(colima_state)"
    case "$state" in
        '' | Stopped) log "VM is already stopped." ;;
        Running)
            if [ "$force" = "true" ]; then
                colima_cmd stop --force "$PROFILE"
            else
                colima_cmd stop "$PROFILE"
            fi
            ;;
        *) die "VM is in state '$state'; wait for it to settle and retry" ;;
    esac
}

show_status() {
    local record
    record="$(colima_cmd list --json 2>/dev/null | jq -c --arg profile "$PROFILE" 'select(.name == $profile)' | head -n 1)"
    if [ -z "$record" ]; then
        log "devbox: Not created"
        return
    fi
    jq -r '"devbox: \(.status) | \(.arch) | \(.cpus) CPU | \(.memory / 1073741824) GiB memory | \(.disk / 1073741824) GiB disk"' <<<"$record"
}

show_ide_connection() {
        local effective_config host port user identity_file

        require_running_vm
        SSH_AUTH_SOCK=none ssh -o BatchMode=yes -o ConnectTimeout=10 devbox true >/dev/null 2>&1 ||
                die "managed SSH host 'devbox' is not reachable; run 'devbox start'"

        effective_config="$(ssh -G devbox 2>/dev/null)"
        host="$(awk '$1 == "hostname" { print $2; exit }' <<<"$effective_config")"
        port="$(awk '$1 == "port" { print $2; exit }' <<<"$effective_config")"
        user="$(awk '$1 == "user" { print $2; exit }' <<<"$effective_config")"
        identity_file="$(awk '$1 == "identityfile" { $1 = ""; sub(/^ /, ""); print; exit }' <<<"$effective_config")"

        cat <<EOF
IDE SSH connection verified.

VS Code Remote - SSH:
    Select host: devbox

JetBrains Gateway:
    In the SSH configuration dialog, enable "Parse config file ~/.ssh/config".
    Select or enter host "devbox" and do not override its port or authentication.

JetBrains manual fallback:
    Host: $host
    Port: $port
    Username: $user
    Authentication: Key pair (OpenSSH)
    Private key: $identity_file

The port is assigned by Colima and can change after rebuild. Prefer the managed
"devbox" OpenSSH entry over saving the manual fallback.
EOF
}
