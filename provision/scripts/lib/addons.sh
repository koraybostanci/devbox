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
    done <"$DEVBOX_PROVISION_ROOT/config/install-plugins.txt"
}

install_addons() {
    stage "Optional add-ons"
    ADDON_FAILURES=0
    install_claude_plugins
    if ((ADDON_FAILURES > 0)); then
        printf 'WARNING: %s optional add-on(s) failed\n' "$ADDON_FAILURES" >&2
    fi
}
