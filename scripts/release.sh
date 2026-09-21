#!/usr/bin/env bash
# Thin wrapper for `devbox release` (kept for existing workflows and CI).

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVBOX_DIR="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/release.sh"

run_devbox_release "$@"
