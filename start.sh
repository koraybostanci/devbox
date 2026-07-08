#!/bin/bash
# Usage: source .env && ./start.sh
set -e

DEVBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVED_YAML="/tmp/koray-dev-lima.yaml"

sed "s|{{DEVBOX_DIR}}|$DEVBOX_DIR|g" "$DEVBOX_DIR/lima.yaml" > "$RESOLVED_YAML"

exec limactl start --name devbox "$RESOLVED_YAML"
