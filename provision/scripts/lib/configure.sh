#!/bin/bash

# The publish helper lives in common.sh; sources resolve from this file's own
# directory so standalone unit runs see the same shared implementation.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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
    # An absent source directory means the managed tree is retired: the manifest
    # cleanup above already removed its files, so there is nothing to copy.
    [ -d "$source" ] || return 0
    cp -R "$source/." "$target/"
    (cd "$source" && find . -type f | LC_ALL=C sort | sed 's#^\./##') >"$manifest"
}

configure_opencode() {
    local config_directory="$HOME/.config/opencode"
    local managed_tree managed_trees=(
        "$DEVBOX_PROVISION_ROOT/config/opencode/agents:$config_directory/agents:$config_directory/.devbox-managed-agents"
        "$DEVBOX_PROVISION_ROOT/config/opencode/commands:$config_directory/commands:$config_directory/.devbox-managed-commands"
        "$DEVBOX_PROVISION_ROOT/config/skills:$config_directory/skills:$config_directory/.devbox-managed-skills"
    )

    stage "OpenCode configuration"
    mkdir -p "$config_directory/skills" "$config_directory/commands"
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/opencode/opencode.jsonc" "$config_directory/opencode.jsonc"
    # One loop over the (source, target, manifest) triples; each sync keeps
    # the manifest machinery, so user-owned files in the managed directories
    # always survive.
    for managed_tree in "${managed_trees[@]}"; do
        IFS=':' read -r tree_source tree_target tree_manifest <<<"$managed_tree"
        sync_managed_opencode_tree "$tree_source" "$tree_target" "$tree_manifest"
    done
    atomic_copy "$DEVBOX_PROVISION_ROOT/config/opencode/AGENTS.md" "$config_directory/AGENTS.md" 644
}

# Emit the merged Claude Code settings: the settings file Claude Code itself
# manages is the base, with the provisioned policy (attribution today) deep
# merged over it. An absent target publishes the policy file unchanged.
devbox_build_claude_settings() {
    local source_file="$1" target="$2"

    [ -f "$target" ] || { cat -- "$source_file"; return 0; }
    jq -s '.[0] * .[1]' -- "$target" "$source_file"
}

configure_claude() {
    local source_file="$DEVBOX_PROVISION_ROOT/config/claude/settings.json" target="$HOME/.claude/settings.json"

    atomic_copy "$DEVBOX_PROVISION_ROOT/config/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
    # Managed through a manifest so user-owned agents in ~/.claude/agents survive.
    sync_managed_opencode_tree "$DEVBOX_PROVISION_ROOT/config/claude/agents" \
        "$HOME/.claude/agents" "$HOME/.claude/.devbox-managed-agents"
    # A merge, not a clobber: Claude Code owns keys such as enabledPlugins and
    # the theme in this file, so the provisioned policy is deep merged over
    # whatever is already there.
    mkdir -p "$(dirname "$target")"
    devbox_publish_atomic "$target" 644 --skip-if-same -- \
        devbox_build_claude_settings "$source_file" "$target"
}

# Keep the user's .zshenv (or its dotfiles target) and place devbox defaults in
# a managed block before it, so user and project settings can override them.
sync_managed_zshenv() {
    local source_file="$1" target="$2" link mode=644 depth
    local begin='# >>> devbox managed zshenv >>>' end='# <<< devbox managed zshenv <<<'

    # depth only counts symlink hops; the 8-hop cap is the loop's literal list.
    # shellcheck disable=SC2034
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
    # The managed block is validated on the existing target first, so a
    # malformed block is refused before anything is written; the publishing
    # awk in devbox_build_managed_zshenv cannot fail after that. The helper
    # keeps its temporary in the target's own directory, chmods the captured
    # mode before the mv, and skips the mv when the assembled content already
    # matches.
    if [ -f "$target" ] && ! awk -v begin="$begin" -v end="$end" '
        $0 == begin { if (inside || found) exit 1; inside = found = 1 }
        $0 == end { if (!inside) exit 1; inside = 0 }
        END { if (inside) exit 1 }
        ' "$target" >/dev/null; then
        printf 'ERROR: malformed devbox-managed block in %s\n' "$target" >&2
        return 1
    fi
    devbox_publish_atomic "$target" "$mode" --skip-if-same -- \
        devbox_build_managed_zshenv "$source_file" "$target" "$begin" "$end"
}

# Emit the managed zshenv: devbox defaults inside a begin/end block, then the
# existing target's own lines, which the caller already validated.
devbox_build_managed_zshenv() {
    local source_file="$1" target="$2" begin="$3" end="$4"

    printf '%s\n' "$begin"
    cat -- "$source_file"
    printf '%s\n' "$end"
    [ ! -f "$target" ] || awk -v begin="$begin" -v end="$end" '
        $0 == begin { if (inside || found) exit 1; inside = found = 1; next }
        $0 == end { if (!inside) exit 1; inside = 0; next }
        !inside { print }
        END { if (inside) exit 1 }
    ' "$target"
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
