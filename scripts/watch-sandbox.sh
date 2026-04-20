#!/bin/bash
# watch-sandbox.sh — start the security dashboard and open it in the browser

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Starting security dashboard..."
echo "  gVisor syscalls, Falco alerts, and Podman events stream to: http://localhost:9999"
echo ""

open http://localhost:9999 2>/dev/null &

cd "$REPO_DIR/dashboard" && npm install --silent && node server.js
