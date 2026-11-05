#!/bin/bash
# Release installs: versioned copies under the install root, a `current`
# symlink, and a stable ~/.local/bin/devbox link. Clone-based use never
# touches any of this; a release install is recognized by the RELEASE marker
# that scripts/release.sh packs next to the launcher.

DEVBOX_RELEASE_REPO="${DEVBOX_RELEASE_REPO:-koraybostanci/devbox}"
DEVBOX_RELEASE_KEEP=2

release_mode() {
    [ -f "$DEVBOX_DIR/RELEASE" ]
}

release_root() {
    printf '%s\n' "${DEVBOX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/devbox}"
}

release_config_file() {
    printf '%s/devbox/env\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

release_valid_version() {
    case "$1" in
        '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
    esac
    [ "$(printf '%s' "$1" | tr -cd '.' | wc -c | tr -d ' ')" = 2 ]
}

release_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d ' ' -f1
    else
        sha256sum "$1" | cut -d ' ' -f1
    fi
}

# Print the base URL that holds devbox-<ver>.tar.gz and its .sha256.
release_base_url() {
    if [ -n "${DEVBOX_RELEASE_BASE_URL:-}" ]; then
        printf '%s\n' "$DEVBOX_RELEASE_BASE_URL"
    else
        printf 'https://github.com/%s/releases/download/v%s\n' "$DEVBOX_RELEASE_REPO" "$1"
    fi
}

# Print the newest released version. A base-URL override (tests, mirrors)
# serves it from a LATEST file; GitHub answers with a redirect to the tag page,
# which avoids API rate limits and a JSON parser.
release_latest_version() {
    local latest

    if [ -n "${DEVBOX_RELEASE_BASE_URL:-}" ]; then
        latest="$(curl -fsSL "$DEVBOX_RELEASE_BASE_URL/LATEST")" ||
            die "cannot read $DEVBOX_RELEASE_BASE_URL/LATEST"
    else
        latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "https://github.com/$DEVBOX_RELEASE_REPO/releases/latest")" ||
            die "cannot determine the latest release"
        latest="${latest##*/}"
        latest="${latest#v}"
    fi
    release_valid_version "$latest" || die "unexpected latest version: $latest"
    printf '%s\n' "$latest"
}

# Download, verify, and unpack one release into <dest>/devbox-<ver>.
release_fetch() {
    local version="$1" dest="$2" base archive expected actual member

    base="$(release_base_url "$version")"
    archive="$dest/devbox-$version.tar.gz"
    curl -fsSL -o "$archive" "$base/devbox-$version.tar.gz" ||
        die "cannot download $base/devbox-$version.tar.gz"
    curl -fsSL -o "$archive.sha256" "$base/devbox-$version.tar.gz.sha256" ||
        die "cannot download $base/devbox-$version.tar.gz.sha256"

    expected="$(cut -d ' ' -f1 <"$archive.sha256")"
    actual="$(release_sha256 "$archive")"
    [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
        die "checksum mismatch for devbox-$version.tar.gz"

    # Refuse anything that could write outside the staging directory.
    while IFS= read -r member; do
        case "$member" in
            /* | ../* | */../* | */.. | ..) die "unsafe path in release archive: $member" ;;
        esac
    done < <(tar -tzf "$archive")
    if tar -tvzf "$archive" | grep -q '^[lh]'; then
        die "release archive contains links"
    fi
    mkdir -p "$dest/x"
    tar -xzf "$archive" -C "$dest/x"
    [ -f "$dest/x/devbox-$version/devbox" ] ||
        die "release archive has no devbox-$version/devbox"
}

# Install the release this launcher belongs to: copy it into
# <root>/versions/<ver>, then make it current.
release_self_install() {
    local version root staging

    read -r version <"$DEVBOX_DIR/VERSION" || true
    release_valid_version "$version" || die "invalid release version: $version"
    root="$(release_root)"
    mkdir -p "$root/versions"
    staging="$(mktemp -d "$root/versions/.staging.XXXXXX")"
    cp -pR "$DEVBOX_DIR/." "$staging/"
    command rm -rf "$root/versions/$version"
    mv "$staging" "$root/versions/$version"
    release_activate "$version"
}

release_activate() {
    local version="$1" root link previous old_dir config

    root="$(release_root)"
    link="$HOME/.local/bin/devbox"
    mkdir -p "$HOME/.local/bin"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        die "$link exists and is not a symlink"
    fi

    previous=""
    if [ -L "$link" ]; then
        previous="$(resolve_symlink_target "$link")"
    fi

    ln -sfn "versions/$version" "$root/current"
    ln -sfn "$root/current/devbox" "$link"
    log "Installed devbox $version: $link -> $root/current/devbox"

    # Carry a clone's .env over once; the clone's copy is left alone.
    config="$(release_config_file)"
    old_dir="$(dirname "$previous")"
    if [ -n "$previous" ] && [ ! -e "$config" ] && [ -f "$old_dir/.env" ]; then
        case "$previous" in
            "$root"/*) ;;
            *)
                warn "replacing the command that pointed into $old_dir"
                mkdir -p "$(dirname "$config")"
                chmod 700 "$(dirname "$config")"
                (umask 077 && cp "$old_dir/.env" "$config")
                log "Copied $old_dir/.env to $config"
                ;;
        esac
    fi

    release_prune "$root" "$version"

    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *)
            log "Add $HOME/.local/bin to PATH before using devbox from other directories:"
            log "    export PATH=\"$HOME/.local/bin:\$PATH\""
            ;;
    esac
}

release_prune() {
    local root="$1" current="$2" kept=0 entry path

    while IFS= read -r entry; do
        if [ "$entry" = "$current" ] || [ "$kept" -lt "$DEVBOX_RELEASE_KEEP" ]; then
            kept=$((kept + 1))
        else
            command rm -rf "$root/versions/$entry"
        fi
    done < <(for path in "$root"/versions/*; do
        entry="${path##*/}"
        release_valid_version "$entry" && printf '%s\n' "$entry"
    done | sort -t. -k1,1nr -k2,2nr -k3,3nr)
}

release_update() {
    local version="" explicit=0 current tmp

    release_mode || die "devbox was installed from a clone; use git pull to update"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] || die "--version needs a value"
                version="${2#v}"
                explicit=1
                shift 2
                ;;
            *) die "Usage: devbox update [--version X.Y.Z]" ;;
        esac
    done
    [ -n "$version" ] || version="$(release_latest_version)"
    release_valid_version "$version" || die "invalid version: $version"
    read -r current <"$DEVBOX_DIR/VERSION" || true
    if [ "$version" = "$current" ]; then
        log "devbox $current is already installed."
        return
    fi
    # Only an explicit --version may move backwards (rollback).
    if [ "$explicit" = 0 ] && version_at_least "$current" "$version"; then
        log "devbox $current is newer than the latest release ($version); not downgrading. Use --version to choose."
        return
    fi

    tmp="$(mktemp -d)"
    release_fetch "$version" "$tmp" || {
        command rm -rf "$tmp"
        return 1
    }
    "$tmp/x/devbox-$version/devbox" self-install || {
        command rm -rf "$tmp"
        return 1
    }
    command rm -rf "$tmp"
}

# Remove the release install: the command link and the install root. The
# configuration and the VM are left alone.
release_uninstall() {
    local root link
    root="$(release_root)"
    link="$HOME/.local/bin/devbox"

    if [ -L "$link" ] && [ "$(readlink "$link")" = "$root/current/devbox" ]; then
        command rm "$link"
        log "Removed: $link"
    fi
    command rm -rf "$root"
    log "Removed: $root"
    log "Kept configuration ($(release_config_file)) and the VM; run 'devbox destroy' first to remove the VM."
}
