#!/bin/bash
# Sourced by check.sh after ROOT, validation_root, and fail are set.
# Exercises release.sh, install.sh, update, and uninstall against file:// URLs
# in an isolated HOME; no network and no VM.
# shellcheck disable=SC2154

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'ERROR: scripts/check-release.sh must be sourced by scripts/check.sh\n' >&2
    exit 1
fi

rel_root="$validation_root/release"
rel_home="$rel_root/home"
mkdir -p "$rel_home/.local/bin" "$rel_root/src/scripts"

# Build releases from a fixture copy so VERSION can differ from the checkout.
build_release() {
    local version="$1" src="$rel_root/src"
    command rm -rf "$src"
    mkdir -p "$src/scripts"
    cp -pR "$ROOT/devbox" "$ROOT/lib" "$ROOT/provision" "$ROOT/colima.yaml" "$ROOT/install.sh" "$src/"
    cp -p "$ROOT/scripts/release.sh" "$src/scripts/"
    printf '%s\n' "$version" >"$src/VERSION"
    bash "$src/scripts/release.sh" --build-only >/dev/null || fail "release.sh --build-only failed for $version"
    command rm -rf "$rel_root/dist-$version"
    mv "$src/dist" "$rel_root/dist-$version"
}
build_release 0.0.8
build_release 0.0.9
# One flat directory holds every version, as a mirror would.
mkdir -p "$rel_root/mirror"
cp "$rel_root"/dist-0.0.8/devbox-* "$rel_root"/dist-0.0.9/devbox-* "$rel_root/mirror/"
printf '0.0.9\n' >"$rel_root/mirror/LATEST"

rel_env() {
    HOME="$rel_home" PATH="$rel_home/.local/bin:/usr/bin:/bin" \
        DEVBOX_RELEASE_BASE_URL="file://$rel_root/mirror" \
        env -u DEVBOX_ENV_FILE -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u DEVBOX_HOME "$@"
}

# Contents and reproducibility.
rel_listing="$(tar -tzf "$rel_root/dist-0.0.8/devbox-0.0.8.tar.gz")"
grep -qx 'devbox-0.0.8/RELEASE' <<<"$rel_listing" || fail "release tarball lacks the RELEASE marker"
if grep -E '^devbox-[0-9.]+/(docs|scripts|\.git|README|AGENTS)' <<<"$rel_listing"; then
    fail "release tarball contains non-runtime files"
fi
first_sum="$(cut -d ' ' -f1 <"$rel_root/dist-0.0.8/devbox-0.0.8.tar.gz.sha256")"
build_release 0.0.8
[ "$first_sum" = "$(cut -d ' ' -f1 <"$rel_root/dist-0.0.8/devbox-0.0.8.tar.gz.sha256")" ] ||
    fail "release build is not reproducible"

# A clone-based command and .env get migrated, never deleted.
mkdir -p "$rel_root/clone"
printf 'export GIT_NAME="Old"\n' >"$rel_root/clone/.env"
chmod 600 "$rel_root/clone/.env"
ln -s "$rel_root/clone/devbox" "$rel_home/.local/bin/devbox"

# Install the older release.
rel_env bash "$ROOT/install.sh" --version 0.0.8 >/dev/null 2>&1 || fail "install.sh failed"
rel_data="$rel_home/.local/share/devbox"
[ "$(readlink "$rel_data/current")" = versions/0.0.8 ] || fail "install did not set current"
[ "$(readlink "$rel_home/.local/bin/devbox")" = "$rel_data/current/devbox" ] ||
    fail "install did not link the command through current"
[ "$(rel_env devbox version)" = 0.0.8 ] || fail "installed devbox reports the wrong version"
rel_config="$rel_home/.config/devbox/env"
[ "$(file_mode "$rel_config")" = 600 ] || fail "migrated configuration has the wrong mode"
grep -q 'GIT_NAME="Old"' "$rel_config" || fail "clone .env was not migrated"
[ -f "$rel_root/clone/.env" ] || fail "migration removed the clone .env"
[ "$(rel_env /bin/bash -c 'DEVBOX_DIR="$1"; source "$1/lib/config.sh"; devbox_env_file' _ "$rel_data/current")" = "$rel_config" ] ||
    fail "release env file is not the XDG path"

# Update flips current, keeps the old version and the configuration.
printf 'export GIT_NAME="Edited"\n' >"$rel_config"
rel_env devbox update >/dev/null 2>&1 || fail "devbox update failed"
[ "$(readlink "$rel_data/current")" = versions/0.0.9 ] || fail "update did not flip current"
[ -d "$rel_data/versions/0.0.8" ] || fail "update dropped the previous version"
grep -q Edited "$rel_config" || fail "update touched the configuration"
rel_repeat="$(rel_env devbox update 2>&1)"
[[ "$rel_repeat" == *'already installed'* ]] || fail "repeat update was not a no-op"
rel_env devbox update --version 0.0.8 >/dev/null 2>&1 || fail "rollback via update --version failed"
[ "$(readlink "$rel_data/current")" = versions/0.0.8 ] || fail "rollback did not flip current"

# Pruning keeps the newest two versions plus current.
for fake in 0.0.1 0.0.2; do mkdir -p "$rel_data/versions/$fake"; done
rel_env devbox update --version 0.0.9 >/dev/null 2>&1 || fail "update to 0.0.9 failed"
[ ! -e "$rel_data/versions/0.0.1" ] && [ ! -e "$rel_data/versions/0.0.2" ] || fail "old versions were not pruned"

# A corrupted download installs nothing.
mkdir -p "$rel_root/bad/mirror" "$rel_root/bad/home"
cp "$rel_root"/mirror/devbox-0.0.9.tar.gz* "$rel_root/bad/mirror/"
printf 'corrupt' >>"$rel_root/bad/mirror/devbox-0.0.9.tar.gz"
if HOME="$rel_root/bad/home" DEVBOX_RELEASE_BASE_URL="file://$rel_root/bad/mirror" \
    bash "$ROOT/install.sh" --version 0.0.9 >/dev/null 2>"$rel_root/bad/err"; then
    fail "install.sh accepted a corrupted tarball"
fi
grep -q 'checksum mismatch' "$rel_root/bad/err" || fail "corruption was not reported as a checksum mismatch"
[ ! -e "$rel_root/bad/home/.local/share/devbox" ] || fail "corrupted install left files behind"

# Unsafe archives are rejected even with a matching checksum.
mkdir -p "$rel_root/evil/pkg/devbox-0.0.9" "$rel_root/evil/mirror" "$rel_root/evil/home"
ln -s /etc/passwd "$rel_root/evil/pkg/devbox-0.0.9/link"
tar -czf "$rel_root/evil/mirror/devbox-0.0.9.tar.gz" -C "$rel_root/evil/pkg" devbox-0.0.9
(cd "$rel_root/evil/mirror" && sha256sum devbox-0.0.9.tar.gz >devbox-0.0.9.tar.gz.sha256)
if HOME="$rel_root/evil/home" DEVBOX_RELEASE_BASE_URL="file://$rel_root/evil/mirror" \
    bash "$ROOT/install.sh" --version 0.0.9 >/dev/null 2>"$rel_root/evil/err"; then
    fail "install.sh accepted an archive containing a symlink"
fi
grep -q 'contains links' "$rel_root/evil/err" || fail "symlink archive was not reported"

# Uninstall removes the install, keeps the configuration.
rel_env devbox uninstall >/dev/null 2>&1 || fail "release uninstall failed"
[ ! -e "$rel_data" ] && [ ! -L "$rel_home/.local/bin/devbox" ] || fail "release uninstall left files"
[ -f "$rel_config" ] || fail "release uninstall removed the configuration"

# A clone refuses update.
clone_update="$(rel_env "$ROOT/devbox" update 2>&1 || true)"
[[ "$clone_update" == *'use git pull'* ]] || fail "update in a clone did not point at git pull"
