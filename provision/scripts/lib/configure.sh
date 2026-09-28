#!/bin/bash

configure_git() {
    stage "Git identity and HTTPS defaults"
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    git config --global init.defaultBranch main
    gh config set git_protocol https --host github.com
}

# Sync provisioned files without owning the whole user directory. A manifest
# lets later runs remove only files that an earlier provision run managed.
sync_managed_opencode_tree() {
    local source="$1" target="$2" manifest="$3" path

    mkdir -p "$target"
    if [ -f "$manifest" ]; then
        while IFS= read -r path || [ -n "$path" ]; do
            [ -n "$path" ] && [ ! -e "$source/$path" ] || continue
            rm -f -- "$target/$path"
            path="$(dirname "$path")"
            while [ "$path" != . ] && rmdir "$target/$path" 2>/dev/null; do
                path="$(dirname "$path")"
            done
        done <"$manifest"
    fi
    cp -R "$source/." "$target/"
    (cd "$source" && find . -type f | LC_ALL=C sort | sed 's#^\./##') >"$manifest"
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

# Keep the user's .zshenv (or its dotfiles target) and place devbox defaults in
# a managed block before it, so user and project settings can override them.
sync_managed_zshenv() {
    local source_file="$1" target="$2" link mode=644 temporary depth
    local begin='# >>> devbox managed zshenv >>>' end='# <<< devbox managed zshenv <<<'

    for depth in 1 2 3 4 5 6 7 8; do
        [ -L "$target" ] || break
        link="$(readlink "$target")"
        case "$link" in
            /*) target="$link" ;;
            *) target="$(dirname "$target")/$link" ;;
        esac
    done
    if [ -f "$target" ]; then
        if [ "$(uname -s)" = Darwin ]; then
            mode="$(stat -f '%Lp' "$target")"
        else
            mode="$(stat -c '%a' "$target")"
        fi
    fi

    temporary="$(mktemp "$(dirname "$target")/.zshenv.devbox.XXXXXX")"
    {
        printf '%s\n' "$begin"
        cat "$source_file"
        printf '%s\n' "$end"
        [ ! -f "$target" ] || awk -v begin="$begin" -v end="$end" '
            $0 == begin { if (inside || found) exit 1; inside = found = 1; next }
            $0 == end { if (!inside) exit 1; inside = 0; next }
            !inside { print }
            END { if (inside) exit 1 }
        ' "$target"
    } >"$temporary" || {
        rm -f "$temporary"
        printf 'ERROR: malformed devbox-managed block in %s\n' "$target" >&2
        return 1
    }
    chmod "$mode" "$temporary"
    if cmp -s "$temporary" "$target"; then
        rm -f "$temporary"
    else
        mv -f "$temporary" "$target"
    fi
}

configure_shell() {
    sync_managed_zshenv "$DEVBOX_PROVISION_ROOT/config/zsh/zshenv" "$HOME/.zshenv"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/zsh/zshrc" "$HOME/.zshrc" 644
    zsh -n "$HOME/.zshenv"
    zsh -n "$HOME/.zshrc"
}

configure_guest() {
    configure_git
    configure_opencode
    configure_claude
    configure_shell
}
