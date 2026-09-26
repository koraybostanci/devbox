#!/bin/bash

configure_git() {
    stage "Git identity and HTTPS defaults"
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    git config --global init.defaultBranch main
    gh config set git_protocol https --host github.com
}

managed_opencode_path_is_safe() {
    case "$1" in
        '' | . | .. | /* | ../* | */../* | */.. | */./* | */.) return 1 ;;
        *//* ) return 1 ;;
    esac
    return 0
}

managed_opencode_target_path_is_safe() {
    local target="$1" path="$2" parent remainder component

    managed_opencode_path_is_safe "$path" || return 1
    parent="$target"
    remainder="$path"
    while [ "$remainder" != "${remainder#*/}" ]; do
        component="${remainder%%/*}"
        if [ -e "$parent/$component" ] || [ -L "$parent/$component" ]; then
            [ -d "$parent/$component" ] && [ ! -L "$parent/$component" ] || return 1
        fi
        parent="$parent/$component"
        remainder="${remainder#*/}"
    done
    [ ! -L "$parent/$remainder" ] && [ ! -d "$parent/$remainder" ]
}

remove_managed_opencode_file() {
    local target="$1" path="$2" parent remainder component

    managed_opencode_path_is_safe "$path" || return 1
    parent="$target"
    remainder="$path"
    while [ "$remainder" != "${remainder#*/}" ]; do
        component="${remainder%%/*}"
        [ ! -L "$parent/$component" ] || return 1
        parent="$parent/$component"
        remainder="${remainder#*/}"
    done
    [ ! -L "$parent/$remainder" ] || return 1
    rm -f -- "$parent/$remainder" || return 1

    parent="$(dirname "$target/$path")"
    while [ "$parent" != "$target" ]; do
        rmdir "$parent" 2>/dev/null || break
        parent="$(dirname "$parent")"
    done
}

# Sync provisioned files without owning the whole user directory. A manifest
# lets later runs remove only files that an earlier provision run managed.
sync_managed_opencode_tree() {
    local source="$1" target="$2" manifest="$3"
    local current_manifest manifest_temporary path

    [ -d "$source" ] && [ ! -L "$source" ] || return 1
    mkdir -p "$target"
    [ -d "$target" ] && [ ! -L "$target" ] || return 1
    if [ -e "$manifest" ] || [ -L "$manifest" ]; then
        [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
    fi

    current_manifest="$(mktemp "$target/.devbox-current.XXXXXX")" || return 1
    if ! (cd "$source" && find . -type f -print | LC_ALL=C sort | sed 's#^\./##') >"$current_manifest"; then
        rm -f -- "$current_manifest"
        return 1
    fi
    while IFS= read -r path || [ -n "$path" ]; do
        managed_opencode_target_path_is_safe "$target" "$path" || {
            rm -f -- "$current_manifest"
            return 1
        }
    done <"$current_manifest"

    if [ -f "$manifest" ]; then
        while IFS= read -r path || [ -n "$path" ]; do
            managed_opencode_path_is_safe "$path" || {
                rm -f -- "$current_manifest"
                return 1
            }
            if ! grep -Fqx -- "$path" "$current_manifest"; then
                remove_managed_opencode_file "$target" "$path" || {
                    rm -f -- "$current_manifest"
                    return 1
                }
            fi
        done <"$manifest"
    fi

    cp -R "$source/." "$target/" || {
        rm -f -- "$current_manifest"
        return 1
    }
    manifest_temporary="$(mktemp "$(dirname "$manifest")/.devbox-managed.XXXXXX")" || {
        rm -f -- "$current_manifest"
        return 1
    }
    cp "$current_manifest" "$manifest_temporary" && chmod 600 "$manifest_temporary" &&
        mv "$manifest_temporary" "$manifest" || {
        rm -f -- "$current_manifest" "$manifest_temporary"
        return 1
    }
    rm -f -- "$current_manifest"
}

configure_opencode() {
    local config_directory="$HOME/.config/opencode"

    stage "OpenCode configuration"
    mkdir -p "$config_directory/agents" "$config_directory/skills"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/opencode/opencode.jsonc" "$config_directory/opencode.jsonc"
    sync_managed_opencode_tree \
        "$DEVBOX_PROVISION_ROOT/config/opencode/agents" \
        "$config_directory/agents" "$config_directory/.devbox-managed-agents"
    sync_managed_opencode_tree \
        "$DEVBOX_PROVISION_ROOT/config/skills" \
        "$config_directory/skills" "$config_directory/.devbox-managed-skills"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/opencode/AGENTS.md" "$config_directory/AGENTS.md" 644
}

configure_claude() {
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
}

configure_shell() {
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/zsh/zshrc" "$HOME/.zshrc" 644
    zsh -n "$HOME/.zshrc"
}

configure_guest() {
    configure_git
    configure_opencode
    configure_claude
    configure_shell
}
