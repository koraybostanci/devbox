#!/bin/bash

install_claude_plugins() {
    local plugin
    while IFS= read -r plugin || [ -n "$plugin" ]; do
        [[ "$plugin" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$plugin" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]] || {
            printf 'WARNING: invalid Claude plugin entry: %s\n' "$plugin" >&2
            ADDON_FAILURES=$((ADDON_FAILURES + 1))
            continue
        }
        claude plugin install "$plugin" --scope user >/dev/null 2>&1 || {
            printf 'WARNING: Claude plugin install failed: %s\n' "$plugin" >&2
            ADDON_FAILURES=$((ADDON_FAILURES + 1))
        }
    done </provision/config/install-plugins.txt
}

install_skills() {
    local entry command_hash has_yes sentinel_file token
    local -a command_parts
    while IFS= read -r entry <&3 || [ -n "$entry" ]; do
        [[ "$entry" =~ ^[[:space:]]*(#|$) ]] && continue
        read -r -a command_parts <<<"$entry"
        if [ "${#command_parts[@]}" -lt 3 ] || [ "${command_parts[0]}" != npx ] ||
            [[ "${command_parts[1]}" = -* ]]; then
            printf 'WARNING: invalid skill entry: %s\n' "$entry" >&2
            ADDON_FAILURES=$((ADDON_FAILURES + 1))
            continue
        fi
        has_yes=false
        for token in "${command_parts[@]:1}"; do
            if [ "$token" = -y ] || [ "$token" = --yes ]; then
                has_yes=true
            fi
            if [[ ! "$token" =~ ^[A-Za-z0-9@.,_=/:-]+$ ]]; then
                printf 'WARNING: invalid skill entry: %s\n' "$entry" >&2
                ADDON_FAILURES=$((ADDON_FAILURES + 1))
                continue 2
            fi
        done
        if [ "$has_yes" != true ]; then
            printf 'WARNING: skill entry is not unattended: %s\n' "$entry" >&2
            ADDON_FAILURES=$((ADDON_FAILURES + 1))
            continue
        fi
        command_hash="$(printf '%s' "$entry" | sha256sum | awk '{print $1}')"
        sentinel_file="$HOME/.claude/skills/.installed-$command_hash"
        [ -f "$sentinel_file" ] && continue
        if npx --yes "${command_parts[@]:1}"; then
            touch "$sentinel_file"
        else
            printf 'WARNING: skill install failed: %s\n' "$entry" >&2
            ADDON_FAILURES=$((ADDON_FAILURES + 1))
        fi
    done 3</provision/config/install-skills.txt
}

install_addons() {
    stage "Optional add-ons"
    ADDON_FAILURES=0
    install_claude_plugins
    install_skills
    if ((ADDON_FAILURES > 0)); then
        printf 'WARNING: %s optional add-on(s) failed\n' "$ADDON_FAILURES" >&2
    fi
}
