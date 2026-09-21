#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

validation_root="$(mktemp -d)"
trap 'command rm -rf "$validation_root"' EXIT

# Make the Homebrew Docker Compose plugin discoverable (macOS CI layout).
if command -v brew >/dev/null 2>&1; then
    compose_plugin_dir="$(brew --prefix)/lib/docker/cli-plugins"
    if [ -d "$compose_plugin_dir" ]; then
        export DOCKER_CONFIG="$validation_root/docker"
        mkdir -p "$DOCKER_CONFIG"
        printf '{"cliPluginsExtraDirs":["%s"]}\n' "$compose_plugin_dir" \
            >"$DOCKER_CONFIG/config.json"
    fi
fi

# --- shell syntax -----------------------------------------------------------
shell_files=()
while IFS= read -r shell_file; do
    shell_files+=("$shell_file")
done < <(find . \( -type f -name '*.sh' -o -path './devbox' \) | sort)
bash -n "${shell_files[@]}"

# --- the legacy mounted profile is gone ------------------------------------
for legacy_path in \
    lib/colima.sh lib/containers.sh lib/doctor.sh lib/guest.sh \
    lib/isolation-poc.sh provision/config/containers; do
    [ ! -e "$legacy_path" ] || fail "legacy path still present: $legacy_path"
done
if grep -q 'migrate' lib/devbox.sh; then
    fail "obsolete legacy migration command still present"
fi

# --- .env.example -----------------------------------------------------------
grep -q '^export GIT_NAME=' .env.example
grep -q '^export GIT_EMAIL=' .env.example
if grep -q 'POSTGRES_PASSWORD' .env.example; then
    fail ".env.example must not carry POSTGRES_PASSWORD (it is generated in the guest)"
fi

# --- launcher ---------------------------------------------------------------
[ -x devbox ]
"$ROOT/devbox" help | grep -q 'Usage: devbox <command>'
if "$ROOT/devbox" bogus >/dev/null 2>&1; then
    fail "unknown command was accepted"
fi

# `devbox version` reports the trimmed VERSION file and needs no host checks.
launcher_version="$("$ROOT/devbox" version)" || fail "devbox version failed"
[ "$launcher_version" = "$(cat "$ROOT/VERSION")" ] ||
    fail "devbox version printed '$launcher_version' instead of the VERSION contents"

# --- release workflows ------------------------------------------------------
grep -q 'workflow_call:' .github/workflows/check.yml ||
    fail "check.yml must be reusable via workflow_call"
# The VERSION trigger must be an item of on.push.paths. Scoping the search to
# that block keeps a "- VERSION" entry under any other key from satisfying it.
push_paths="$(
    awk '
        function indent_of(line) {
            match(line, /^ */)
            return RLENGTH
        }
        {
            line = $0
            stripped = line
            sub(/^[[:space:]]+/, "", stripped)
            ind = indent_of(line)
            if (in_paths) {
                if (line ~ /^[[:space:]]*$/) next
                if (ind > paths_indent) {
                    print stripped
                    next
                }
                in_paths = 0
            }
            if (in_push) {
                if (line ~ /^[[:space:]]*$/) next
                if (ind <= push_indent) {
                    in_push = 0
                } else if (stripped ~ /^paths:[[:space:]]*$/) {
                    in_paths = 1
                    paths_indent = ind
                    next
                }
            }
            if (in_on) {
                if (line ~ /^[[:space:]]*$/) next
                if (ind <= on_indent) {
                    in_on = 0
                } else if (stripped ~ /^push:[[:space:]]*$/) {
                    in_push = 1
                    push_indent = ind
                    next
                }
            }
            if (stripped ~ /^on:[[:space:]]*$/) {
                in_on = 1
                on_indent = ind
            }
        }
    ' .github/workflows/release.yml
)"
printf '%s\n' "$push_paths" | grep -qx -- '- VERSION' ||
    fail "release.yml must trigger on the VERSION path under on.push.paths"
if grep -n '\${{ steps\.' .github/workflows/release.yml; then
    fail "release.yml must not reference step outputs"
fi
# Workflow context expressions belong in env: blocks, never in run: scripts.
# Both inline run: values and block-scalar run: bodies are scanned.
run_context_usage="$(
    awk '
        function indent_of(line) {
            match(line, /^ */)
            return RLENGTH
        }
        {
            line = $0
            stripped = line
            sub(/^[[:space:]]+/, "", stripped)
            if (in_run && line ~ /^[[:space:]]*$/) next
            if (in_run && indent_of(line) <= run_indent) in_run = 0
            if (in_run) {
                if (index(line, "${{") > 0) printf "%s:%d: %s\n", FILENAME, FNR, line
                next
            }
            if (stripped ~ /^run:([[:space:]]|$)/) {
                run_indent = indent_of(line)
                in_run = 1
                if (index(line, "${{") > 0) printf "%s:%d: %s\n", FILENAME, FNR, line
            }
        }
    ' .github/workflows/release.yml
)"
[ -z "$run_context_usage" ] ||
    fail "release.yml interpolates workflow context inside run scripts: $run_context_usage"

# --- guest companion --------------------------------------------------------
[ -f provision/config/guest/devbox ]
bash -n provision/config/guest/devbox
grep -q 'config/guest/devbox' provision/scripts/system.sh
grep -q 'devbox_guest_interactive' lib/devbox.sh
companion_home="$validation_root/guest-home"
mkdir -p "$companion_home/.config/devbox"
printf 'export POSTGRES_USER=dev\nexport POSTGRES_DB=dev\nexport POSTGRES_PORT=15432\n' \
    >"$companion_home/.config/devbox/config"
printf 'export POSTGRES_PASSWORD=test\nexport VALKEY_PASSWORD=test\n' \
    >"$companion_home/.config/devbox/secrets"
companion_status="$(HOME="$companion_home" PATH=/nonexistent "$(command -v bash)" \
    provision/config/guest/devbox auth status)" || fail "companion 'auth status' failed"
printf '%s\n' "$companion_status" | grep -q '^github: not configured$' ||
    fail "companion did not report github as unconfigured"
printf '%s\n' "$companion_status" | grep -q '^databricks: not configured$' ||
    fail "companion did not report databricks as unconfigured"

# `gh auth status` exits 0 for an invalid token, so a stubbed failure must not
# be reported as authenticated.
stub_bin="$validation_root/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/gh" <<'EOF'
#!/bin/bash
[ "$1" = auth ] && [ "$2" = status ] && printf 'X Failed to log in to github.com\n'
exit 0
EOF
chmod +x "$stub_bin/gh"
invalid_gh_status="$(HOME="$companion_home" PATH="$stub_bin:/usr/bin:/bin" \
    "$(command -v bash)" provision/config/guest/devbox auth status)" ||
    fail "companion 'auth status' failed with a stubbed gh"
printf '%s\n' "$invalid_gh_status" | grep -q '^github: not configured$' ||
    fail "companion reported an invalid GitHub token as authenticated"

# ~/.claude.json is onboarding metadata that exists before login; only the
# credentials file means signed in.
claude_home="$validation_root/claude-home"
mkdir -p "$claude_home"
printf '{}\n' >"$claude_home/.claude.json"
claude_status="$(HOME="$claude_home" PATH=/nonexistent "$(command -v bash)" \
    provision/config/guest/devbox auth status)" || fail "companion 'auth status' failed"
printf '%s\n' "$claude_status" | grep -q '^claude: not configured$' ||
    fail "companion reported Claude as configured from onboarding metadata"
mkdir -p "$claude_home/.claude"
printf '{}\n' >"$claude_home/.claude/.credentials.json"
claude_status="$(HOME="$claude_home" PATH=/nonexistent "$(command -v bash)" \
    provision/config/guest/devbox auth status)" || fail "companion 'auth status' failed"
printf '%s\n' "$claude_status" | grep -q '^claude: configured$' ||
    fail "companion did not report Claude credentials as configured"

companion_db="$(HOME="$companion_home" bash provision/config/guest/devbox db info)" ||
    fail "companion 'db info' failed"
printf '%s\n' "$companion_db" | grep -q 'postgres port: 15432' ||
    fail "companion did not report PostgreSQL settings"

# --- devbox must not need host jq or yq ----------------------------------------
if grep -nE '(^|[^[:alnum:]_])(jq|yq)([^[:alnum:]_]|$)' lib/devbox.sh lib/config.sh; then
    fail "devbox must not require host jq or yq"
fi

# --- prohibited provisioning patterns --------------------------------------
if grep -R -E -- \
    '^[[:space:]]*eval[[:space:]]|curl[^|]*\|[[:space:]]*(ba)?sh|SSH_AUTH_SOCK=/run/host-services|chmod 0777|rm -rf "\$HOME/(projects|data)|/etc/environment|readlink -f' \
    devbox lib provision/scripts provision/config/zsh; then
    fail "prohibited provisioning pattern found"
fi

# --- devbox remote payloads must be valid Bash ---------------------------------
devbox_home="$validation_root/home"
mkdir -p "$devbox_home"
payloads_dir="$validation_root/payloads"
mkdir -p "$payloads_dir"
HOME="$devbox_home" DEVBOX_REMOTE_PAYLOADS_DIR="$payloads_dir" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    devbox_host_ssh_user() { printf "admin\n"; }
    devbox_host_public_key() {
        printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test\n"
    }
    devbox_sshd_authorized_keys_config() { printf "AuthorizedKeysFile /etc/ssh/authorized_keys/%%u\n"; }
    capture_payloads() {
        local i j target
        for ((i = 1; i <= $#; i++)); do
            if [ "${!i}" = "-c" ]; then
                j=$((i + 1))
                target="$(mktemp "$DEVBOX_REMOTE_PAYLOADS_DIR/payload.XXXXXX")"
                printf "%s" "${!j}" >"$target"
            fi
        done
        return 0
    }
    devbox_admin_guest() { capture_payloads "$@"; }
    devbox_as_guest() { capture_payloads "$@"; }
    authorize_devbox_host_key || true
    validate_devbox_guest_identity || true
    validate_devbox_guest_privileges || true
    remove_devbox_managed_guest_ssh_authorization || true
' || fail "devbox remote payload capture failed"
payload_count=0
for payload in "$payloads_dir"/payload.*; do
    [ -f "$payload" ] || continue
    payload_count=$((payload_count + 1))
    bash -n "$payload" || fail "a devbox remote payload is not valid Bash: $payload"
done
[ "$payload_count" -ge 3 ] || fail "expected at least 3 devbox remote payloads, captured $payload_count"

# --- devbox privilege parser behavior ------------------------------------------
devbox_privileges_remote="$validation_root/privileges.sh"
HOME="$devbox_home" DEVBOX_REMOTE="$devbox_privileges_remote" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    devbox_admin_guest() {
        [ "$1" = sudo ] && [ "$2" = bash ] && [ "$3" = -c ] || exit 1
        printf "%s" "$4" >"$DEVBOX_REMOTE"
    }
    validate_devbox_guest_privileges
' || fail "devbox privilege parser capture failed"
bash -n "$devbox_privileges_remote" || fail "devbox privilege parser is not valid Bash"

HOME="$devbox_home" DEVBOX_REMOTE="$devbox_privileges_remote" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    devbox_admin_guest() { "$@"; }
    sudo() {
        case "$1" in
            bash) shift; command bash "$@" ;;
            -n)
                [ "$2" = -l ] && [ "$3" = -U ] && [ "$4" = devbox ] || return 1
                printf "User devbox is not allowed to run sudo on guest.\n"
                return 1
                ;;
            -u)
                [ "$2" = devbox ] && [ "$3" = -- ] || return 1
                return 1
                ;;
            *) return 1 ;;
        esac
    }
    export -f sudo
    validate_devbox_guest_privileges
' || fail "devbox privilege parser rejected the no-sudo guest output"
HOME="$devbox_home" DEVBOX_REMOTE="$devbox_privileges_remote" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    devbox_admin_guest() { "$@"; }
    sudo() {
        case "$1" in
            bash) shift; command bash "$@" ;;
            -n)
                [ "$2" = -l ] && [ "$3" = -U ] && [ "$4" = devbox ] || return 1
                printf "User devbox may run the following commands on guest:\n    (root) NOPASSWD: ALL\n"
                ;;
            -u) return 1 ;;
            *) return 1 ;;
        esac
    }
    export -f sudo
    ! validate_devbox_guest_privileges
' || fail "devbox privilege parser accepted sudo privileges"

# --- devbox identity validator --------------------------------------------------
devbox_identity_script="$validation_root/identity.sh"
HOME="$devbox_home" DEVBOX_IDENTITY="$devbox_identity_script" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    devbox_admin_guest() {
        [ "$1" = bash ] && [ "$2" = -c ] || exit 1
        printf "%s" "$3" >"$DEVBOX_IDENTITY"
    }
    validate_devbox_guest_identity
' || true
bash -n "$devbox_identity_script" || fail "devbox identity validator is not valid Bash"

# --- managed services -------------------------------------------------------
if docker compose version >/dev/null 2>&1; then
    POSTGRES_PASSWORD=test POSTGRES_USER=test POSTGRES_DB=test POSTGRES_PORT=15432 \
        VALKEY_PASSWORD=test VALKEY_PORT=16379 \
        docker compose -f provision/config/services/compose.yaml config -q ||
        fail "devbox service definition is invalid"
    grep -q '"127.0.0.1:' provision/config/services/compose.yaml ||
        fail "devbox services must publish to loopback only"
else
    printf 'WARN: docker compose is unavailable; skipping service-definition validation\n' >&2
fi

# --- release tooling --------------------------------------------------------
# Route release sandboxes through a symlinked directory so logical paths
# (HOME, XDG_DATA_HOME, DEVBOX_DIR) and physical paths differ exactly as they
# do on macOS CI, where the sandbox HOME lives below /var/folders and is
# reached through the /var -> /private/var symlink. Release path identity
# checks must canonicalize before comparing.
release_real_root="$validation_root/release-real"
release_root="$validation_root/release-link"
mkdir -p "$release_real_root"
ln -s "$release_real_root" "$release_root"

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

file_mode_of() {
    if [ "$(uname -s)" = Darwin ]; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

# Resolve a path physically the way devbox_data_root does: walk up to the
# nearest existing ancestor, resolve it with cd -P, and re-append the remaining
# components. Assertions that compare readlink output or marker contents use
# this so they expect the same physical paths the implementation stores.
physical_path() {
    local path="$1" suffix="" base parent target directory

    case "$path" in
        /*) ;;
        *) path="$PWD/$path" ;;
    esac
    while [ "${path%/}" != "$path" ] && [ -n "${path#/}" ]; do
        path="${path%/}"
    done

    while [ ! -e "$path" ] && [ ! -L "$path" ]; do
        base="${path##*/}"
        parent="${path%/*}"
        [ -n "$parent" ] || parent="/"
        [ "$base" != "$path" ] || break
        suffix="/$base$suffix"
        path="${parent%/}"
        [ -n "$path" ] || path="/"
    done

    if [ -L "$path" ]; then
        target="$(readlink "$path")"
        case "$target" in
            /*) ;;
            *) target="$(dirname "$path")/$target" ;;
        esac
        path="$(physical_path "$target")"
    else
        directory="$(dirname "$path")"
        if [ "$directory" != "$path" ]; then
            directory="$(cd -P "$directory" && pwd)"
            if [ "$directory" = "/" ]; then
                path="/$(basename "$path")"
            else
                path="$directory/$(basename "$path")"
            fi
        fi
    fi

    if [ "$path" = "/" ]; then
        printf '/%s\n' "${suffix#/}"
    else
        printf '%s%s\n' "$path" "$suffix"
    fi
}

# devbox_data_root must not create anything and must resolve the data root
# itself when it is a symlink.
data_root_real="$release_root/data-root-real"
data_root_link="$release_root/data-root-link"
mkdir -p "$data_root_real/devbox"
ln -s "$data_root_real" "$data_root_link"
data_root_output="$(
    HOME="$release_root/data-root-home" XDG_DATA_HOME="$data_root_link" ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        devbox_data_root
    '
)" || fail "devbox_data_root failed for an existing symlinked data root"
[ "$data_root_output" = "$(physical_path "$data_root_real/devbox")" ] ||
    fail "devbox_data_root did not resolve the symlinked data root: $data_root_output"
command rm -rf "$data_root_real/devbox"
ln -s "$data_root_real/elsewhere" "$data_root_real/devbox"
data_root_output="$(
    HOME="$release_root/data-root-home" XDG_DATA_HOME="$data_root_link" ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        devbox_data_root
    '
)" || fail "devbox_data_root failed for a data root that is itself a symlink"
[ "$data_root_output" = "$(physical_path "$data_root_real/elsewhere")" ] ||
    fail "devbox_data_root did not resolve a data-root symlink: $data_root_output"
command rm -f "$data_root_real/devbox"
data_root_output="$(
    HOME="$release_root/data-root-home" XDG_DATA_HOME="$data_root_link/nested" ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        devbox_data_root
    '
)" || fail "devbox_data_root failed for a missing data root"
[ "$data_root_output" = "$(physical_path "$data_root_real/nested/devbox")" ] ||
    fail "devbox_data_root did not canonicalize a missing data root: $data_root_output"
[ ! -e "$data_root_real/nested" ] ||
    fail "devbox_data_root created a missing data root"

release_version="$(cat "$ROOT/VERSION")"
release_archive="$ROOT/dist/devbox-$release_version/devbox-$release_version.tar.gz"

# A fresh build drops any signature left by a previous build.
mkdir -p "$ROOT/dist/devbox-$release_version"
printf 'stale\n' >"$ROOT/dist/devbox-$release_version/SHA256SUMS.sig"
"$ROOT/scripts/release.sh" build >/dev/null || fail "release build failed"
[ ! -e "$ROOT/dist/devbox-$release_version/SHA256SUMS.sig" ] ||
    fail "fresh release build kept a stale signature"
if "$ROOT/scripts/release.sh" build 9.9.9 >/dev/null 2>&1; then
    fail "release build accepted a version that does not match VERSION"
fi

tar -tzf "$release_archive" >"$release_root/archive.list"
for release_entry in .env.example VERSION scripts/release.sh; do
    grep -qx "devbox-$release_version/$release_entry" "$release_root/archive.list" ||
        fail "release archive is missing $release_entry"
done
if grep -q 'release-signing-key' "$release_root/archive.list"; then
    fail "release archive must not ship the release public key"
fi
[ "$(tar -xzOf "$release_archive" "devbox-$release_version/VERSION")" = "$release_version" ] ||
    fail "embedded VERSION does not match $release_version"

# Unsigned releases fail closed; the local-testing override succeeds.
if "$ROOT/scripts/release.sh" verify "$release_archive" >/dev/null 2>&1; then
    fail "unsigned release verification was accepted"
fi
DEVBOX_ALLOW_UNSIGNED=1 "$ROOT/scripts/release.sh" verify "$release_archive" >/dev/null ||
    fail "release verification with DEVBOX_ALLOW_UNSIGNED=1 failed"

release_key="$release_root/signing-key.pem"
openssl ecparam -name prime256v1 -genkey -noout -out "$release_key" ||
    fail "could not generate test key"
openssl ec -in "$release_key" -pubout -out "$release_root/signing-key.pub.pem" 2>/dev/null
if DEVBOX_RELEASE_PUBKEY="$release_root/signing-key.pub.pem" \
    "$ROOT/scripts/release.sh" verify "$release_archive" >/dev/null 2>&1; then
    fail "unsigned release verification was accepted with a public key present"
fi
"$ROOT/scripts/release.sh" sign "$release_archive" --key "$release_key" >/dev/null ||
    fail "release signing failed"
DEVBOX_RELEASE_PUBKEY="$release_root/signing-key.pub.pem" \
    "$ROOT/scripts/release.sh" verify "$release_archive" >/dev/null ||
    fail "signed release verification failed"

# The documented flat-download invocation installs with relative arguments:
# the shipped scripts/release.sh resolves the archive and DEVBOX_RELEASE_PUBKEY
# against the invocation directory, not against the extracted tree.
relative_root="$release_root/relative"
relative_home="$relative_root/home"
relative_data="$relative_home/.local/share/devbox"
relative_path="$relative_root/path:/usr/bin:/bin"
mkdir -p "$relative_root" "$relative_home"
tar -xzf "$release_archive" -C "$relative_root"
cp "$release_archive" "$relative_root/devbox-$release_version.tar.gz"
cp "$ROOT/dist/devbox-$release_version/SHA256SUMS" "$relative_root/SHA256SUMS"
cp "$ROOT/dist/devbox-$release_version/SHA256SUMS.sig" "$relative_root/SHA256SUMS.sig"
cp "$release_root/signing-key.pub.pem" "$relative_root/release-signing-key.pub.pem"
(
    cd "$relative_root"
    DEVBOX_RELEASE_PUBKEY=release-signing-key.pub.pem \
        HOME="$relative_home" XDG_DATA_HOME="$relative_home/.local/share" \
        PATH="$relative_path" \
        "./devbox-$release_version/scripts/release.sh" \
        install "devbox-$release_version.tar.gz"
) >/dev/null || fail "relative-path release installation failed"
[ -x "$relative_data/releases/$release_version/devbox" ] ||
    fail "relative-path installation did not install the release"
[ "$(readlink "$relative_data/current")" = "$(physical_path "$relative_data/releases/$release_version")" ] ||
    fail "relative-path installation did not activate the release"

printf 'tampered\n' >"$ROOT/dist/devbox-$release_version/SHA256SUMS.sig"
if DEVBOX_RELEASE_PUBKEY="$release_root/signing-key.pub.pem" \
    "$ROOT/scripts/release.sh" verify "$release_archive" >/dev/null 2>&1; then
    fail "tampered release signature was accepted"
fi
command rm -f "$ROOT/dist/devbox-$release_version/SHA256SUMS.sig"

# A tampered archive with recomputed checksums and a valid signature must still
# fail on its MANIFEST.
tamper_root="$release_root/manifest-tamper"
mkdir -p "$tamper_root"
tar -xzf "$release_archive" -C "$tamper_root"
printf 'tampered\n' >>"$tamper_root/devbox-$release_version/README.md"
(
    cd "$tamper_root"
    tar -czf "$tamper_root/tampered.tar.gz" "devbox-$release_version"
)
tampered_archive="$tamper_root/devbox-$release_version.tar.gz"
mv "$tamper_root/tampered.tar.gz" "$tampered_archive"
printf '%s  %s\n' "$(sha256_of "$tampered_archive")" "$(basename "$tampered_archive")" \
    >"$tamper_root/SHA256SUMS"
"$ROOT/scripts/release.sh" sign "$tampered_archive" --key "$release_key" >/dev/null ||
    fail "could not sign the tampered archive"
if DEVBOX_RELEASE_PUBKEY="$release_root/signing-key.pub.pem" \
    "$ROOT/scripts/release.sh" verify "$tampered_archive" \
    >/dev/null 2>"$release_root/manifest-tamper.err"; then
    fail "release with a tampered MANIFEST was accepted"
fi
grep -q 'manifest checksum mismatch' "$release_root/manifest-tamper.err" ||
    fail "tampered MANIFEST rejection did not report a checksum mismatch"

# An archive with two top-level directories is rejected.
two_top_root="$release_root/two-tops"
mkdir -p "$two_top_root/devbox-$release_version" "$two_top_root/devbox-other"
printf 'file\n' >"$two_top_root/devbox-$release_version/README.md"
printf 'file\n' >"$two_top_root/devbox-other/file"
(
    cd "$two_top_root"
    tar -czf "$two_top_root/two-tops.tar.gz" "devbox-$release_version" devbox-other
)
two_top_archive="$two_top_root/devbox-$release_version.tar.gz"
mv "$two_top_root/two-tops.tar.gz" "$two_top_archive"
printf '%s  %s\n' "$(sha256_of "$two_top_archive")" "$(basename "$two_top_archive")" \
    >"$two_top_root/SHA256SUMS"
if DEVBOX_ALLOW_UNSIGNED=1 \
    "$ROOT/scripts/release.sh" verify "$two_top_archive" \
    >/dev/null 2>"$release_root/two-tops.err"; then
    fail "archive with two top-level directories was accepted"
fi
grep -q 'multiple top-level directories' "$release_root/two-tops.err" ||
    fail "two-top rejection did not report the multiple top-level directories"

# An archive containing a symlink entry is rejected.
symlink_root="$release_root/symlink"
mkdir -p "$symlink_root/devbox-$release_version"
printf 'real\n' >"$symlink_root/devbox-$release_version/real"
ln -s real "$symlink_root/devbox-$release_version/link"
(
    cd "$symlink_root"
    tar -czf "$symlink_root/symlink.tar.gz" "devbox-$release_version"
)
symlink_archive="$symlink_root/devbox-$release_version.tar.gz"
mv "$symlink_root/symlink.tar.gz" "$symlink_archive"
printf '%s  %s\n' "$(sha256_of "$symlink_archive")" "$(basename "$symlink_archive")" \
    >"$symlink_root/SHA256SUMS"
if DEVBOX_ALLOW_UNSIGNED=1 \
    "$ROOT/scripts/release.sh" verify "$symlink_archive" \
    >/dev/null 2>"$release_root/symlink.err"; then
    fail "archive containing a symlink entry was accepted"
fi
grep -q 'unsupported entry type' "$release_root/symlink.err" ||
    fail "symlink rejection did not report an unsupported entry type"

# Legacy archives (v0.0.1-rc1) carry a MANIFEST but no VERSION and no
# .env.example; a valid tree without VERSION still verifies and installs.
synthetic_root="$release_root/synthetic"
legacy_version="0.0.1-rc1"
legacy_top="devbox-$legacy_version"
legacy_tree="$synthetic_root/$legacy_top"
mkdir -p "$legacy_tree"
printf 'legacy payload\n' >"$legacy_tree/README.md"
printf '#!/bin/bash\necho legacy\n' >"$legacy_tree/devbox"
chmod +x "$legacy_tree/devbox"
(
    cd "$legacy_tree"
    find . -type f ! -name MANIFEST -print | LC_ALL=C sort |
        while IFS= read -r entry; do
            printf '%s\t%s\n' "$(sha256_of "$entry")" "${entry#./}"
        done
) >"$legacy_tree/MANIFEST"
(
    cd "$synthetic_root"
    tar -czf "$synthetic_root/$legacy_top.tar.gz" "$legacy_top"
)
legacy_archive="$synthetic_root/$legacy_top.tar.gz"
printf '%s  %s\n' "$(sha256_of "$legacy_archive")" "$legacy_top.tar.gz" \
    >"$synthetic_root/SHA256SUMS"
DEVBOX_ALLOW_UNSIGNED=1 "$ROOT/scripts/release.sh" verify "$legacy_archive" >/dev/null ||
    fail "a valid release tree without VERSION was rejected"
synthetic_home="$synthetic_root/home"
synthetic_data="$synthetic_home/.local/share/devbox"
synthetic_path="$synthetic_root/path:/usr/bin:/bin"
mkdir -p "$synthetic_home"
DEVBOX_ALLOW_UNSIGNED=1 HOME="$synthetic_home" XDG_DATA_HOME="$synthetic_home/.local/share" \
    PATH="$synthetic_path" "$ROOT/scripts/release.sh" install "$legacy_archive" >/dev/null ||
    fail "a valid release tree without VERSION could not be installed"
[ -f "$synthetic_data/releases/$legacy_version/devbox" ] ||
    fail "legacy release without VERSION was not installed"

# A VERSION that disagrees with the release directory is rejected.
mismatch_top="devbox-0.0.2"
mismatch_tree="$synthetic_root/$mismatch_top"
mkdir -p "$mismatch_tree"
printf '0.0.1\n' >"$mismatch_tree/VERSION"
printf 'payload\n' >"$mismatch_tree/README.md"
(
    cd "$mismatch_tree"
    find . -type f ! -name MANIFEST -print | LC_ALL=C sort |
        while IFS= read -r entry; do
            printf '%s\t%s\n' "$(sha256_of "$entry")" "${entry#./}"
        done
) >"$mismatch_tree/MANIFEST"
(
    cd "$synthetic_root"
    tar -czf "$synthetic_root/$mismatch_top.tar.gz" "$mismatch_top"
)
mismatch_archive="$synthetic_root/$mismatch_top.tar.gz"
printf '%s  %s\n' "$(sha256_of "$mismatch_archive")" "$mismatch_top.tar.gz" \
    >"$synthetic_root/SHA256SUMS"
if DEVBOX_ALLOW_UNSIGNED=1 "$ROOT/scripts/release.sh" verify "$mismatch_archive" \
    >/dev/null 2>"$synthetic_root/mismatch.err"; then
    fail "a release whose VERSION disagrees with its directory was accepted"
fi
grep -q 'does not match version' "$synthetic_root/mismatch.err" ||
    fail "mismatched VERSION rejection did not explain the failure"

# Install into a sandboxed HOME and PATH so the CLI symlink can never touch the
# developer's real installation.
install_home="$release_root/install/home"
install_data="$install_home/.local/share/devbox"
install_path="$release_root/install/path:/usr/bin:/bin"
mkdir -p "$install_home"
DEVBOX_ALLOW_UNSIGNED=1 HOME="$install_home" XDG_DATA_HOME="$install_home/.local/share" \
    PATH="$install_path" "$ROOT/scripts/release.sh" install "$release_archive" >/dev/null ||
    fail "release installation failed"
[ -x "$install_data/releases/$release_version/devbox" ] ||
    fail "release launcher was not installed"
[ -f "$install_data/releases/$release_version/.env.example" ] ||
    fail "installed release is missing .env.example"
install_data_physical="$(physical_path "$install_data")"
install_release_physical="$(physical_path "$install_data/releases/$release_version")"
[ "$(readlink "$install_data/current")" = "$install_release_physical" ] ||
    fail "release was not activated"
[ "$(readlink "$install_home/.local/bin/devbox")" = "$install_data_physical/current/devbox" ] ||
    fail "PATH symlink does not target the active release"

# Repeating the same install is idempotent.
DEVBOX_ALLOW_UNSIGNED=1 HOME="$install_home" XDG_DATA_HOME="$install_home/.local/share" \
    PATH="$install_path" "$ROOT/scripts/release.sh" install "$release_archive" >/dev/null ||
    fail "repeat release installation failed"
[ "$(readlink "$install_data/current")" = "$install_release_physical" ] ||
    fail "repeat installation changed the active release"
[ ! -e "$install_data/releases/$release_version/current" ] ||
    fail "activation symlink leaked into the release tree"

# An installed release that no longer matches its MANIFEST is replaced.
printf 'corrupt\n' >>"$install_data/releases/$release_version/README.md"
DEVBOX_ALLOW_UNSIGNED=1 HOME="$install_home" XDG_DATA_HOME="$install_home/.local/share" \
    PATH="$install_path" "$ROOT/scripts/release.sh" install "$release_archive" >/dev/null ||
    fail "corrupted release installation was not replaced"
if grep -q '^corrupt$' "$install_data/releases/$release_version/README.md"; then
    fail "corrupted release contents survived replacement"
fi
[ "$(readlink "$install_data/current")" = "$install_release_physical" ] ||
    fail "replacement installation changed the active release"

# Replacing an invalid target must preserve a legacy in-tree .env: the copy
# happens before the tree is moved aside and removed.
replace_root="$release_root/replace"
replace_home="$replace_root/home"
replace_data="$replace_home/.local/share/devbox"
replace_path="$replace_root/path:/usr/bin:/bin"
legacy_env="$release_root/replace-legacy.env"
mkdir -p "$replace_home"
printf 'export GIT_NAME="Legacy Replace"\nexport GIT_EMAIL="legacy@example.com"\n' \
    >"$legacy_env"
chmod 600 "$legacy_env"
DEVBOX_ALLOW_UNSIGNED=1 HOME="$replace_home" XDG_DATA_HOME="$replace_home/.local/share" \
    PATH="$replace_path" "$ROOT/scripts/release.sh" install "$release_archive" >/dev/null ||
    fail "seed release installation for the replacement test failed"
cp "$legacy_env" "$replace_data/releases/$release_version/.env"
chmod 600 "$replace_data/releases/$release_version/.env"
printf 'corrupt\n' >>"$replace_data/releases/$release_version/README.md"
DEVBOX_ALLOW_UNSIGNED=1 HOME="$replace_home" XDG_DATA_HOME="$replace_home/.local/share" \
    PATH="$replace_path" "$ROOT/scripts/release.sh" install "$release_archive" >/dev/null ||
    fail "replacement install with a legacy in-tree .env failed"
cmp -s "$replace_home/.config/devbox/env" "$legacy_env" ||
    fail "replacing an invalid release destroyed or changed its legacy .env"
[ "$(file_mode_of "$replace_home/.config/devbox/env")" = 600 ] ||
    fail "preserved legacy .env is not mode 0600"
[ ! -e "$replace_data/releases/$release_version/.env" ] ||
    fail "replacement kept the legacy in-tree .env"

# --force replaces an existing release directory even when it is intact.
DEVBOX_ALLOW_UNSIGNED=1 HOME="$replace_home" XDG_DATA_HOME="$replace_home/.local/share" \
    PATH="$replace_path" "$ROOT/scripts/release.sh" install "$release_archive" --force \
    >/dev/null || fail "--force release installation failed"
[ "$(readlink "$replace_data/current")" = "$(physical_path "$replace_data/releases/$release_version")" ] ||
    fail "--force installation changed the active release"

release_list="$(HOME="$install_home" XDG_DATA_HOME="$install_home/.local/share" \
    PATH="$install_path" "$ROOT/scripts/release.sh" list)" || fail "release list failed"
printf '%s\n' "$release_list" | grep -qx "$release_version (active)" ||
    fail "release list did not mark the active release"
HOME="$install_home" XDG_DATA_HOME="$install_home/.local/share" PATH="$install_path" \
    "$ROOT/scripts/release.sh" use "$release_version" >/dev/null || fail "release use failed"
if HOME="$install_home" XDG_DATA_HOME="$install_home/.local/share" PATH="$install_path" \
    "$ROOT/scripts/release.sh" use 9.9.9 >/dev/null 2>&1; then
    fail "release use accepted a release that is not installed"
fi

# `prune` keeps the active release, keeps the N most recently modified
# non-active releases, and removes staging directories older than 24 hours.
prune_root="$release_root/prune"
prune_home="$prune_root/home"
prune_data="$prune_home/.local/share/devbox"
prune_path="$prune_root/path:/usr/bin:/bin"
mkdir -p "$prune_home"
DEVBOX_ALLOW_UNSIGNED=1 HOME="$prune_home" XDG_DATA_HOME="$prune_home/.local/share" \
    PATH="$prune_path" "$ROOT/scripts/release.sh" install "$release_archive" >/dev/null ||
    fail "release installation for the prune test failed"
prune_releases="$prune_data/releases"
prune_active="$prune_releases/$release_version"
prune_decoy_one="$prune_releases/9.9.8"
cp -R "$prune_active" "$prune_decoy_one" || fail "could not stage the first prune decoy"
prune_output="$(HOME="$prune_home" XDG_DATA_HOME="$prune_home/.local/share" PATH="$prune_path" \
    "$ROOT/scripts/release.sh" prune --keep 0)" || fail "release prune --keep 0 failed"
[ ! -e "$prune_decoy_one" ] || fail "prune --keep 0 kept a non-active release"
[ -d "$prune_active" ] || fail "prune --keep 0 removed the active release"
[ "$(readlink "$prune_data/current")" = "$(physical_path "$prune_active")" ] ||
    fail "prune --keep 0 changed the active release"
printf '%s\n' "$prune_output" | grep -q 'Removed release' ||
    fail "prune did not report the release it removed"

prune_decoy_two="$prune_releases/9.9.7"
cp -R "$prune_active" "$prune_decoy_two" || fail "could not stage the second prune decoy"
prune_stale="$prune_releases/.install.stale"
mkdir -p "$prune_stale"
touch -t 202001010000 "$prune_stale" || fail "could not age the stale staging directory"
prune_output="$(HOME="$prune_home" XDG_DATA_HOME="$prune_home/.local/share" PATH="$prune_path" \
    "$ROOT/scripts/release.sh" prune --keep 1)" || fail "release prune --keep 1 failed"
[ -d "$prune_decoy_two" ] || fail "prune --keep 1 removed the most recent non-active release"
[ ! -e "$prune_stale" ] || fail "prune kept a stale staging directory"
[ -d "$prune_active" ] || fail "prune --keep 1 removed the active release"
printf '%s\n' "$prune_output" | grep -q 'Removed stale staging directory' ||
    fail "prune did not report the stale staging directory it removed"

# A version-named symlink under releases/ is not a release directory: prune
# skips it instead of deleting the entries of its target.
prune_link="$prune_releases/9.9.6"
prune_link_target="$prune_root/link-target"
mkdir -p "$prune_link_target"
printf 'payload\n' >"$prune_link_target/file"
ln -s "$prune_link_target" "$prune_link"
HOME="$prune_home" XDG_DATA_HOME="$prune_home/.local/share" PATH="$prune_path" \
    "$ROOT/scripts/release.sh" prune --keep 0 >/dev/null ||
    fail "release prune with a version-named symlink failed"
[ -L "$prune_link" ] || fail "prune removed a version-named symlink"
[ -f "$prune_link_target/file" ] ||
    fail "prune followed a version-named symlink into its target"
command rm -f "$prune_link"

# A releases directory that is itself a symlink is refused before pruning.
link_p_host="$release_root/prune-symlink"
link_p_home="$link_p_host/home"
link_p_path="$link_p_host/path:/usr/bin:/bin"
mkdir -p "$link_p_home/.local/share/devbox" "$link_p_host/real-releases"
ln -s "$link_p_host/real-releases" "$link_p_home/.local/share/devbox/releases"
if HOME="$link_p_home" XDG_DATA_HOME="$link_p_home/.local/share" PATH="$link_p_path" \
    "$ROOT/scripts/release.sh" prune >/dev/null 2>"$link_p_host/prune.err"; then
    fail "prune accepted a symlinked releases directory"
fi
grep -q 'invalid release directory' "$link_p_host/prune.err" ||
    fail "symlinked releases directory rejection did not explain the failure"

# `devbox uninstall` from a release install removes the CLI symlink and the
# activation symlink while leaving the release tree in place. The ownership and
# activation identity checks run through the symlinked HOME.
uninstall_home="$release_root/uninstall/home"
uninstall_data="$uninstall_home/.local/share/devbox"
uninstall_path="$uninstall_home/.local/bin:/usr/bin:/bin"
mkdir -p "$uninstall_home"
DEVBOX_ALLOW_UNSIGNED=1 HOME="$uninstall_home" XDG_DATA_HOME="$uninstall_home/.local/share" \
    PATH="$uninstall_path" "$ROOT/scripts/release.sh" install "$release_archive" >/dev/null ||
    fail "release installation for the uninstall test failed"
[ -L "$uninstall_home/.local/bin/devbox" ] ||
    fail "uninstall test did not install the CLI symlink"
HOME="$uninstall_home" XDG_DATA_HOME="$uninstall_home/.local/share" PATH="$uninstall_path" \
    "$uninstall_data/current/devbox" uninstall >/dev/null ||
    fail "devbox uninstall failed for a release install"
[ ! -e "$uninstall_home/.local/bin/devbox" ] && [ ! -L "$uninstall_home/.local/bin/devbox" ] ||
    fail "devbox uninstall kept the CLI symlink"
[ ! -e "$uninstall_data/current" ] && [ ! -L "$uninstall_data/current" ] ||
    fail "devbox uninstall kept the activation symlink"
[ -x "$uninstall_data/releases/$release_version/devbox" ] ||
    fail "devbox uninstall removed the installed release tree"

# Upgrading from a release whose .env lived in the versioned tree keeps the
# host configuration at the stable path.
upgrade_home="$release_root/upgrade/home"
upgrade_data="$upgrade_home/.local/share/devbox"
upgrade_path="$release_root/upgrade/path:/usr/bin:/bin"
mkdir -p "$upgrade_data/releases/0.0.1-rc1" "$upgrade_home"
printf 'export GIT_NAME="Upgrade Test"\nexport GIT_EMAIL="upgrade@example.com"\n' \
    >"$upgrade_data/releases/0.0.1-rc1/.env"
chmod 600 "$upgrade_data/releases/0.0.1-rc1/.env"
ln -s "$upgrade_data/releases/0.0.1-rc1" "$upgrade_data/current"
DEVBOX_ALLOW_UNSIGNED=1 HOME="$upgrade_home" XDG_DATA_HOME="$upgrade_home/.local/share" \
    PATH="$upgrade_path" "$ROOT/scripts/release.sh" install "$release_archive" >/dev/null ||
    fail "upgrade release installation failed"
[ -f "$upgrade_home/.config/devbox/env" ] ||
    fail "upgrade did not preserve the host configuration"
cmp -s "$upgrade_home/.config/devbox/env" "$upgrade_data/releases/0.0.1-rc1/.env" ||
    fail "upgrade copied the wrong host configuration"
[ "$(file_mode_of "$upgrade_home/.config/devbox/env")" = 600 ] ||
    fail "preserved host configuration is not mode 0600"
upgrade_list="$(HOME="$upgrade_home" XDG_DATA_HOME="$upgrade_home/.local/share" \
    PATH="$upgrade_path" "$ROOT/scripts/release.sh" list)" || fail "upgrade release list failed"
printf '%s\n' "$upgrade_list" | grep -qx '0.0.1-rc1' ||
    fail "release list dropped the previous release"
printf '%s\n' "$upgrade_list" | grep -qx "$release_version (active)" ||
    fail "release list did not mark the upgraded release active"

# devbox_env_file resolves release trees outside the versioned directory. The
# launcher reports DEVBOX_DIR physically (cd -P) while HOME can stay logical, so
# both spellings of the release directory must select the stable host
# configuration.
env_unit_home="$release_root/env-unit/home"
env_unit_release="$env_unit_home/.local/share/devbox/releases/$release_version"
mkdir -p "$env_unit_release"
env_output="$(
    HOME="$env_unit_home" XDG_DATA_HOME="$env_unit_home/.local/share" \
        DEVBOX_DIR="$ROOT" ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        devbox_env_file
    '
)" || fail "devbox_env_file failed for a checkout"
[ "$env_output" = "$(physical_path "$ROOT")/.env" ] ||
    fail "devbox_env_file did not return the checkout .env"
env_output="$(
    HOME="$env_unit_home" XDG_DATA_HOME="$env_unit_home/.local/share" \
        DEVBOX_DIR="$env_unit_release" ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        devbox_env_file
    '
)" || fail "devbox_env_file failed for a release tree"
[ "$env_output" = "$env_unit_home/.config/devbox/env" ] ||
    fail "devbox_env_file did not return the stable release configuration"
env_output="$(
    HOME="$env_unit_home" XDG_DATA_HOME="$env_unit_home/.local/share" \
        DEVBOX_DIR="$(physical_path "$env_unit_release")" ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        devbox_env_file
    '
)" || fail "devbox_env_file failed for a physically resolved release tree"
[ "$env_output" = "$env_unit_home/.config/devbox/env" ] ||
    fail "devbox_env_file did not return the stable release configuration for a physical DEVBOX_DIR"
env_output="$(
    HOME="$env_unit_home" DEVBOX_ENV_FILE="$release_root/override.env" \
        XDG_DATA_HOME="$env_unit_home/.local/share" DEVBOX_DIR="$ROOT" ROOT="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        devbox_env_file
    '
)" || fail "devbox_env_file failed with DEVBOX_ENV_FILE"
[ "$env_output" = "$release_root/override.env" ] ||
    fail "DEVBOX_ENV_FILE did not override the configuration path"

# Ownership marker v2: accept the install root (data root for releases).
owner_home="$release_root/owner/home"
owner_data="$owner_home/.local/share/devbox"
owner_release="$owner_data/releases/$release_version"
owner_sibling="$owner_data/releases/0.0.1-rc1"
owner_marker="$owner_home/.colima/devbox/.devbox-owner"
mkdir -p "$owner_home/.colima/devbox" "$owner_release" "$owner_sibling"
owner_data_physical="$(physical_path "$owner_data")"
owner_release_physical="$(physical_path "$owner_release")"
# The marker holds the logical data root and the launcher reports the release
# directory physically; the comparison must canonicalize both.
printf 'devbox-profile-v2\n%s\n' "$owner_data" >"$owner_marker"
HOME="$owner_home" XDG_DATA_HOME="$owner_home/.local/share" COLIMA_HOME= LIMA_HOME= \
    DEVBOX_DIR="$owner_release_physical" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    configure_devbox_paths
    check_devbox_ownership
' || fail "ownership marker v2 was rejected for a release tree"

# A legacy checkout marker is rewritten to v2 lazily.
printf 'devbox-profile-v1\n%s\n' "$ROOT" >"$owner_marker"
HOME="$owner_home" XDG_DATA_HOME="$owner_home/.local/share" COLIMA_HOME= LIMA_HOME= \
    DEVBOX_DIR="$ROOT" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    configure_devbox_paths
    check_devbox_ownership
' || fail "legacy checkout ownership marker was rejected"
[ "$(sed -n '1p' "$owner_marker")" = "devbox-profile-v2" ] ||
    fail "legacy checkout marker was not rewritten"
[ "$(sed -n '2p' "$owner_marker")" = "$(physical_path "$ROOT")" ] ||
    fail "rewritten legacy marker recorded the wrong install root"

# A new release under the same data root is accepted after a legacy marker that
# recorded a sibling release.
printf 'devbox-profile-v1\n%s\n' "$owner_sibling" >"$owner_marker"
HOME="$owner_home" XDG_DATA_HOME="$owner_home/.local/share" COLIMA_HOME= LIMA_HOME= \
    DEVBOX_DIR="$owner_release_physical" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    configure_devbox_paths
    check_devbox_ownership
' || fail "upgrade from a sibling release was rejected"
[ "$(sed -n '1p' "$owner_marker")" = "devbox-profile-v2" ] ||
    fail "sibling release marker was not rewritten"
[ "$(sed -n '2p' "$owner_marker")" = "$owner_data_physical" ] ||
    fail "sibling release marker recorded the wrong install root"

# An unrelated marker is rejected with adoption guidance.
printf 'devbox-profile-v1\n%s\n' "$release_root/elsewhere" >"$owner_marker"
if HOME="$owner_home" XDG_DATA_HOME="$owner_home/.local/share" COLIMA_HOME= LIMA_HOME= \
    DEVBOX_DIR="$owner_release_physical" ROOT="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    configure_devbox_paths
    check_devbox_ownership
' 2>"$release_root/unrelated.err"; then
    fail "unrelated ownership marker was accepted"
fi
grep -q 'devbox install --adopt' "$release_root/unrelated.err" ||
    fail "unrelated ownership rejection did not mention devbox install --adopt"

# `devbox stop` must use the ownership-free Colima runner so the documented
# `devbox stop; devbox install --adopt` recovery works for a profile whose
# marker still names another install root.
stop_root="$release_root/stop"
stop_home="$stop_root/home"
stop_bin="$stop_root/bin"
mkdir -p "$stop_home/.colima/devbox" "$stop_bin"
printf 'devbox-profile-v2\n%s\n' "$release_root/elsewhere" \
    >"$stop_home/.colima/devbox/.devbox-owner"
cat >"$stop_bin/colima" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$COLIMA_STUB_LOG"
if [ "$1" = list ]; then
    printf 'devbox Running\n'
fi
exit 0
EOF
chmod +x "$stop_bin/colima"
COLIMA_STUB_LOG="$stop_root/stop.log" \
    HOME="$stop_home" XDG_DATA_HOME="$stop_home/.local/share" COLIMA_HOME= LIMA_HOME= \
    PATH="$stop_bin:/usr/bin:/bin" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    configure_devbox_paths
    stop_devbox_vm false
' || fail "devbox stop failed for a profile owned by another install root"
grep -qx 'stop devbox' "$stop_root/stop.log" ||
    fail "devbox stop did not use the ownership-free Colima runner"

# Status reports the state of an existing profile without the ownership gate.
stop_status="$(
    COLIMA_STUB_LOG="$stop_root/status.log" \
        HOME="$stop_home" XDG_DATA_HOME="$stop_home/.local/share" COLIMA_HOME= LIMA_HOME= \
        PATH="$stop_bin:/usr/bin:/bin" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        source "$ROOT/lib/devbox.sh"
        configure_devbox_paths
        show_devbox_status
    '
)" || fail "devbox status failed for a profile owned by another install root"
[ "$stop_status" = "devbox: Running" ] ||
    fail "devbox status did not report the foreign profile state"

# A failing state query explains itself instead of exiting 1 silently.
cat >"$stop_bin/colima" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$stop_bin/colima"
if COLIMA_STUB_LOG="$stop_root/failure.log" \
    HOME="$stop_home" XDG_DATA_HOME="$stop_home/.local/share" COLIMA_HOME= LIMA_HOME= \
    PATH="$stop_bin:/usr/bin:/bin" ROOT="$ROOT" DEVBOX_DIR="$ROOT" /bin/bash -c '
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/devbox.sh"
    configure_devbox_paths
    stop_devbox_vm false
' 2>"$stop_root/failure.err"; then
    fail "devbox stop reported success when the state query failed"
fi
grep -q 'could not determine the devbox VM state' "$stop_root/failure.err" ||
    fail "a failed state query did not surface a message"

# devbox init against the installed artifact (macOS only).
if [ "$(uname -s)" = "Darwin" ]; then
    init_launcher="$install_data/current/devbox"
    init_env="$install_home/.config/devbox/env"
    init_status=0
    HOME="$install_home" XDG_DATA_HOME="$install_home/.local/share" PATH="/usr/bin:/bin" \
        "$init_launcher" init >"$release_root/init.log" 2>&1 || init_status=$?
    [ "$init_status" -eq 1 ] ||
        fail "devbox init did not require configuration edits before succeeding"
    [ -f "$init_env" ] || fail "devbox init did not create the release host configuration"
    [ "$(file_mode_of "$init_env")" = 600 ] ||
        fail "devbox init created the host configuration with the wrong mode"
    grep -q '^export GIT_NAME=' "$init_env" ||
        fail "devbox init did not seed the host configuration from .env.example"
    printf 'export GIT_NAME="Devbox Test"\nexport GIT_EMAIL="devbox@example.com"\n' >"$init_env"
    chmod 600 "$init_env"
    HOME="$install_home" XDG_DATA_HOME="$install_home/.local/share" PATH="/usr/bin:/bin" \
        "$init_launcher" init >/dev/null ||
        fail "devbox init did not complete after configuration"
else
    printf 'WARN: devbox init smoke test requires macOS; skipping\n' >&2
fi

printf 'All checks passed.\n'
