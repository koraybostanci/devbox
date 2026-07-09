#!/bin/bash
# Usage: source .env && ./start.sh
set -e

# Preflight: ensure required env vars are set
REQUIRED_VARS=(GIT_NAME GIT_EMAIL ANTHROPIC_API_KEY)
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
    [ -z "${!var:-}" ] && MISSING+=("$var")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: Missing required environment variables: ${MISSING[*]}"
    echo "Run: source .env && ./start.sh"
    exit 1
fi

DEVBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVED_YAML="/tmp/devbox-lima.yaml"

sed "s|{{DEVBOX_DIR}}|$DEVBOX_DIR|g" "$DEVBOX_DIR/lima.yaml" > "$RESOLVED_YAML"

exec limactl start --name devbox "$RESOLVED_YAML"
