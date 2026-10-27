#!/bin/bash
# Refresh the vendored ub-mode skill from upstream unclebob/ub-mode.
#
# Usage: bash scripts/update-ub-mode.sh [<upstream-commit-sha>]
#
# Refetches upstream SKILL.md at the given commit (or at upstream master,
# resolved client-side) and replaces the vendored copy, updating the upstream
# commit/SHA/date record in UPSTREAM.md. It never commits: review
# the working-tree diff under the repository Git policy. Upstream publishes
# no digest catalog, so a fetch is pinned by commit and reviewed by diff,
# mirroring how this repository treats other tree-commit pins.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REPO="https://github.com/unclebob/ub-mode.git"
UPSTREAM_DEFAULT_REF="master"
UPSTREAM_RAW_BASE="https://raw.githubusercontent.com/unclebob/ub-mode"
TARGET_SKILL="$ROOT/provision/config/skills/ub-mode/SKILL.md"
TARGET_RECORD="$ROOT/provision/config/skills/ub-mode/UPSTREAM.md"

command -v curl >/dev/null || { echo "ERROR: curl is required" >&2; exit 1; }
command -v shasum >/dev/null || { echo "ERROR: shasum is required" >&2; exit 1; }
command -v git >/dev/null || { echo "ERROR: git is required" >&2; exit 1; }
[ -f "$TARGET_SKILL" ] || { echo "ERROR: vendored SKILL.md is missing: $TARGET_SKILL" >&2; exit 1; }
[ -f "$TARGET_RECORD" ] || { echo "ERROR: UPSTREAM.md record is missing: $TARGET_RECORD" >&2; exit 1; }

commit="${1:-}"
if [ -z "$commit" ]; then
    # ls-remote answers with the branch's current SHA; the caller pins the
    # result, so the vendor diff is reproducible long after master moves.
    commit="$(git ls-remote "$UPSTREAM_REPO" "refs/heads/$UPSTREAM_DEFAULT_REF" | awk 'NR == 1 { print $1 }')"
    [ -n "$commit" ] || { echo "ERROR: cannot resolve upstream $UPSTREAM_DEFAULT_REF" >&2; exit 1; }
fi
case "$commit" in
    [0-9a-f] | [0-9a-f][0-9a-f] | [0-9a-f][0-9a-f][0-9a-f] | [0-9a-f]*) ;;
    *) echo "ERROR: upstream pin must be a hex commit SHA, possibly abbreviated: $commit" >&2; exit 1 ;;
esac

workdir="$(mktemp -d "${TMPDIR:-/tmp}/devbox-ub-mode.XXXXXX")"
trap 'command rm -rf "$workdir"' EXIT
fetched="$workdir/SKILL.md"

curl -fsSLo "$fetched" "$UPSTREAM_RAW_BASE/$commit/SKILL.md" || {
    echo "ERROR: fetch failed for $commit/SKILL.md" >&2
    exit 1
}
# Fetch shape: a skill file starts with frontmatter and names the skill.
head -n 1 "$fetched" | grep -q '^---$' || {
    echo "ERROR: fetched SKILL.md for $commit is not frontmatter-prefixed" >&2
    exit 1
}
grep -q '^name: ub-mode$' "$fetched" || {
    echo "ERROR: fetched SKILL.md for $commit does not name ub-mode" >&2
    exit 1
}

fetched_sha="$(shasum -a 256 "$fetched" | awk '{print $1}')"
current_sha="$(shasum -a 256 "$TARGET_SKILL" | awk '{print $1}')"
recorded_date="$(LC_ALL=C date +%Y-%m-%d)"

if [ "$fetched_sha" = "$current_sha" ] && grep -qF "\`$commit\`" "$TARGET_RECORD"; then
    echo "ub-mode is already vendored from upstream $commit; nothing to do."
    exit 0
fi

# Install: replace the vendored file, then refresh the tracked record rows
# by rebuilding exactly those rows (the other prose lines stay untouched).
cat "$fetched" >"$TARGET_SKILL"
awk -v commit="$commit" -v sha="$fetched_sha" -v date="$recorded_date" '
    /^\| Upstream commit \|/  { $0 = "| Upstream commit | `" commit "` |" }
    /^\| Vendored SHA-256/    { $0 = "| Vendored SHA-256 (SKILL.md) | `" sha "` |" }
    /^\| Vendored on \|/      { $0 = "| Vendored on | " date " |" }
    { print }
' "$TARGET_RECORD" >"$TARGET_RECORD.new"
mv "$TARGET_RECORD.new" "$TARGET_RECORD"

if [ "$fetched_sha" = "$current_sha" ]; then
    echo "UPSTREAM.md record updated to $commit; content is unchanged (sha256 $fetched_sha)."
else
    echo "ub-mode vendored from upstream $commit (sha256 $fetched_sha)."
    echo "Review the diff and commit under the repository Git policy:"
    echo "  git -C \"$ROOT\" diff"
fi
