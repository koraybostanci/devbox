#!/bin/bash
# Install a devbox release into the user's home; needs no clone and no sudo.
#   curl -fsSL https://github.com/koraybostanci/devbox/releases/latest/download/install.sh | bash
#   bash install.sh [--version X.Y.Z]
# Runs under macOS /bin/bash 3.2. The release's own launcher does the install
# (`devbox self-install`), so layout rules live in one place, lib/release.sh.

set -Eeuo pipefail

repo="${DEVBOX_RELEASE_REPO:-koraybostanci/devbox}"
base_override="${DEVBOX_RELEASE_BASE_URL:-}"
version=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || die "--version needs a value"
            version="${2#v}"
            shift 2
            ;;
        *) die "Usage: install.sh [--version X.Y.Z]" ;;
    esac
done

for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

valid_version() {
    case "$1" in
        '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
    esac
    [ "$(printf '%s' "$1" | tr -cd '.' | wc -c | tr -d ' ')" = 2 ]
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d ' ' -f1
    else
        sha256sum "$1" | cut -d ' ' -f1
    fi
}

if [ -z "$version" ]; then
    if [ -n "$base_override" ]; then
        version="$(curl -fsSL "$base_override/LATEST")" || die "cannot read $base_override/LATEST"
    else
        version="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "https://github.com/$repo/releases/latest")" || die "cannot determine the latest release"
        version="${version##*/}"
        version="${version#v}"
    fi
fi
valid_version "$version" || die "invalid version: $version"

if [ -n "$base_override" ]; then
    base="$base_override"
else
    base="https://github.com/$repo/releases/download/v$version"
fi

tmp="$(mktemp -d)"
trap 'command rm -rf "$tmp"' EXIT
archive="$tmp/devbox-$version.tar.gz"
printf 'Downloading devbox %s\n' "$version"
curl -fsSL -o "$archive" "$base/devbox-$version.tar.gz" || die "cannot download $base/devbox-$version.tar.gz"
curl -fsSL -o "$archive.sha256" "$base/devbox-$version.tar.gz.sha256" ||
    die "cannot download $base/devbox-$version.tar.gz.sha256"

expected="$(cut -d ' ' -f1 <"$archive.sha256")"
[ -n "$expected" ] && [ "$expected" = "$(sha256_of "$archive")" ] ||
    die "checksum mismatch for devbox-$version.tar.gz"

while IFS= read -r member; do
    case "$member" in
        /* | ../* | */../* | */.. | ..) die "unsafe path in release archive: $member" ;;
    esac
done < <(tar -tzf "$archive")
if tar -tvzf "$archive" | grep -q '^[lh]'; then
    die "release archive contains links"
fi

mkdir "$tmp/x"
tar -xzf "$archive" -C "$tmp/x"
[ -f "$tmp/x/devbox-$version/devbox" ] || die "release archive has no devbox-$version/devbox"
"$tmp/x/devbox-$version/devbox" self-install
printf 'Next: run `devbox init`.\n'
