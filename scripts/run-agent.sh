#!/bin/bash
# run-agent.sh — run any command in the sandbox with full observability

PROJECT=${PROJECT:-$(pwd)}
IMAGE=${IMAGE:-node:20-alpine}
OS="$(uname -s)"
TIMEOUT=60
RUNSC_LOG="/var/log/runsc/current.log"

# Resource quotas — override via env vars for heavy workloads
SANDBOX_MEMORY=${SANDBOX_MEMORY:-2g}
SANDBOX_CPUS=${SANDBOX_CPUS:-2.0}

# ---------------------------------------------------------------------------
# Warm standby: ensure the sandbox runtime is ready before running a command
# ---------------------------------------------------------------------------

wait_for_ready() {
  local check_cmd="$1"
  local label="$2"
  local elapsed=0

  printf "[sandbox] %s" "$label"
  while ! eval "$check_cmd" &>/dev/null; do
    if [[ $elapsed -ge $TIMEOUT ]]; then
      echo ""
      echo "[sandbox] ERROR: timed out after ${TIMEOUT}s waiting for ${label%...}"
      echo ""
      echo "Troubleshooting:"
      if [[ "$OS" == "Darwin" ]]; then
        echo "  • Check Lima VM status:   limactl list"
        echo "  • View Lima logs:         limactl show-ssh --format=args podman"
        echo "  • Restart the VM:         limactl stop podman && limactl start podman"
        echo "  • Full reset:             limactl delete podman && ./scripts/bootstrap.sh"
      else
        echo "  • Check socket status:    systemctl status podman.socket"
        echo "  • View recent logs:       journalctl -u podman.socket -n 30"
        echo "  • Restart the socket:     sudo systemctl restart podman.socket"
      fi
      exit 1
    fi
    printf " %ds..." "$elapsed"
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo " ready (${elapsed}s)"
}

if [[ "$OS" == "Darwin" ]]; then
  VM_STATUS="$(limactl list --format '{{.Status}}' 2>/dev/null | grep -c 'Running')"
  if [[ "$VM_STATUS" -eq 0 ]]; then
    VM_EXISTS="$(limactl list --format '{{.Name}}' 2>/dev/null | grep -c '^podman$')"
    if [[ "$VM_EXISTS" -eq 0 ]]; then
      echo "[sandbox] ERROR: Lima VM 'podman' not found."
      echo "  Run: ./scripts/bootstrap.sh"
      exit 1
    fi
    echo "[sandbox] VM is stopped — starting..."
    limactl start podman &>/dev/null &
    wait_for_ready "limactl shell podman -- echo ok 2>/dev/null" "VM starting..."
  fi

else
  if ! systemctl is-active --quiet podman.socket 2>/dev/null; then
    echo "[sandbox] Podman socket inactive — starting..."
    sudo systemctl start podman.socket
    wait_for_ready "systemctl is-active --quiet podman.socket" "Podman socket starting..."
  fi
fi

# ---------------------------------------------------------------------------
# Dependency auto-install: hash-based detection for Node, Python, and Go.
# Each language installs into a named Podman volume that persists across runs.
# ---------------------------------------------------------------------------
PROJECT_SLUG="$(basename "$PROJECT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')"

hash_file() { md5 -q "$1" 2>/dev/null || md5sum "$1" | awk '{print $1}'; }

podman_run_install() {
  local extra_volumes="$1"; shift
  local cmd="$*"
  if [[ "$OS" == "Darwin" ]]; then
    limactl shell podman -- sudo podman run --rm \
      --runtime runsc --user 1000:1000 --cap-drop ALL \
      --security-opt no-new-privileges --network none \
      --memory="$SANDBOX_MEMORY" --cpus="$SANDBOX_CPUS" \
      --volume "$PROJECT:/app:rw" $extra_volumes \
      --workdir /app --runtime-flag=ignore-cgroups \
      $IMAGE sh -c "$cmd"
  else
    sudo podman run --rm \
      --runtime runsc --user 1000:1000 --cap-drop ALL \
      --security-opt no-new-privileges --network none \
      --memory="$SANDBOX_MEMORY" --cpus="$SANDBOX_CPUS" \
      --volume "$PROJECT:/app:rw" $extra_volumes \
      --workdir /app --runtime-flag=ignore-cgroups \
      $IMAGE sh -c "$cmd"
  fi
}

# ── Node.js ──────────────────────────────────────────────────────────────────
NM_VOLUME_FLAG=""
if [[ -f "$PROJECT/package.json" ]]; then
  NM_VOLUME="sandbox-nm-${PROJECT_SLUG}"
  CURRENT_HASH="$(hash_file "$PROJECT/package.json")"
  STORED_HASH="$(cat "$PROJECT/.sandbox-pkg-hash" 2>/dev/null || echo '')"
  if [[ "$CURRENT_HASH" != "$STORED_HASH" ]]; then
    echo "[sandbox] package.json changed — running npm install..."
    podman_run_install "--volume ${NM_VOLUME}:/app/node_modules:rw" \
      "npm install --prefer-offline"
    echo "$CURRENT_HASH" > "$PROJECT/.sandbox-pkg-hash"
    echo "[sandbox] node dependencies ready."
  fi
  NM_VOLUME_FLAG="--volume ${NM_VOLUME}:/app/node_modules:rw"
fi

# ── Python ────────────────────────────────────────────────────────────────────
PY_VOLUME_FLAG=""
PY_ENV_FLAG=""
if [[ -f "$PROJECT/requirements.txt" ]]; then
  PY_VOLUME="sandbox-py-${PROJECT_SLUG}"
  CURRENT_HASH="$(hash_file "$PROJECT/requirements.txt")"
  STORED_HASH="$(cat "$PROJECT/.sandbox-py-hash" 2>/dev/null || echo '')"
  if [[ "$CURRENT_HASH" != "$STORED_HASH" ]]; then
    echo "[sandbox] requirements.txt changed — running pip install..."
    podman_run_install "--volume ${PY_VOLUME}:/app/.vendor/python:rw" \
      "pip install --quiet -r requirements.txt --target /app/.vendor/python"
    echo "$CURRENT_HASH" > "$PROJECT/.sandbox-py-hash"
    echo "[sandbox] python dependencies ready."
  fi
  PY_VOLUME_FLAG="--volume ${PY_VOLUME}:/app/.vendor/python:rw"
  PY_ENV_FLAG="--env PYTHONPATH=/app/.vendor/python"
fi

# ── Go ────────────────────────────────────────────────────────────────────────
GO_VOLUME_FLAG=""
if [[ -f "$PROJECT/go.mod" ]]; then
  GO_VOLUME="sandbox-go-${PROJECT_SLUG}"
  CURRENT_HASH="$(hash_file "$PROJECT/go.mod")"
  STORED_HASH="$(cat "$PROJECT/.sandbox-go-hash" 2>/dev/null || echo '')"
  if [[ "$CURRENT_HASH" != "$STORED_HASH" ]]; then
    echo "[sandbox] go.mod changed — running go mod download..."
    podman_run_install "--volume ${GO_VOLUME}:/go/pkg/mod:rw" \
      "go mod download"
    echo "$CURRENT_HASH" > "$PROJECT/.sandbox-go-hash"
    echo "[sandbox] go dependencies ready."
  fi
  GO_VOLUME_FLAG="--volume ${GO_VOLUME}:/go/pkg/mod:rw"
fi

# ---------------------------------------------------------------------------
# Network mode:
#   default              → --network none (fully isolated)
#   SANDBOX_PORT=3000    → publish port 3000, inbound only
#   SANDBOX_NETWORK=bridge → full outbound access, all connections logged
# ---------------------------------------------------------------------------
if [[ -n "${SANDBOX_NETWORK:-}" && "${SANDBOX_NETWORK}" == "bridge" ]]; then
  NETWORK_FLAGS=""
  echo "[sandbox] WARNING: network=bridge — outbound connections enabled and logged"
elif [[ -n "${SANDBOX_PORT:-}" ]]; then
  NETWORK_FLAGS="-p ${SANDBOX_PORT}:${SANDBOX_PORT}"
else
  NETWORK_FLAGS="--network none"
fi

# ---------------------------------------------------------------------------
# Capture log position before run for post-run summary
# ---------------------------------------------------------------------------
if [[ "$OS" == "Darwin" ]]; then
  LOG_START=$(limactl shell podman -- sudo wc -l "$RUNSC_LOG" 2>/dev/null | awk '{print $1}' || echo 0)
else
  LOG_START=$(sudo wc -l "$RUNSC_LOG" 2>/dev/null | awk '{print $1}' || echo 0)
fi

# ---------------------------------------------------------------------------
# Run the sandbox container
# ---------------------------------------------------------------------------
if [[ "$OS" == "Darwin" ]]; then
  limactl shell podman -- sudo podman run --rm \
    --runtime runsc \
    --user 1000:1000 \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --memory="$SANDBOX_MEMORY" \
    --cpus="$SANDBOX_CPUS" \
    $NETWORK_FLAGS \
    --volume "$PROJECT:/app:rw" \
    $NM_VOLUME_FLAG \
    $PY_VOLUME_FLAG $PY_ENV_FLAG \
    $GO_VOLUME_FLAG \
    --workdir /app \
    --name dev-sandbox \
    --runtime-flag=ignore-cgroups \
    --runtime-flag=debug \
    --runtime-flag=strace \
    --runtime-flag="debug-log=$RUNSC_LOG" \
    $IMAGE \
    "$@"
else
  sudo podman run --rm \
    --runtime runsc \
    --user 1000:1000 \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --memory="$SANDBOX_MEMORY" \
    --cpus="$SANDBOX_CPUS" \
    $NETWORK_FLAGS \
    --volume "$PROJECT:/app:rw" \
    $NM_VOLUME_FLAG \
    $PY_VOLUME_FLAG $PY_ENV_FLAG \
    $GO_VOLUME_FLAG \
    --workdir /app \
    --name dev-sandbox \
    --runtime-flag=ignore-cgroups \
    --runtime-flag=debug \
    --runtime-flag=strace \
    --runtime-flag="debug-log=$RUNSC_LOG" \
    $IMAGE \
    "$@"
fi

# ---------------------------------------------------------------------------
# Post-run summary: read new log lines and count event types
# ---------------------------------------------------------------------------
sleep 1  # allow gVisor to flush final log lines

if [[ "$OS" == "Darwin" ]]; then
  SESSION_LINES=$(limactl shell podman -- sudo tail -n +"$((LOG_START + 1))" "$RUNSC_LOG" 2>/dev/null)
else
  SESSION_LINES=$(sudo tail -n +"$((LOG_START + 1))" "$RUNSC_LOG" 2>/dev/null)
fi

FILES_READ=$(echo "$SESSION_LINES"     | grep -c 'openat' 2>/dev/null || echo 0)
FILES_WRITTEN=$(echo "$SESSION_LINES"  | grep -cE 'openat.*(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC)' 2>/dev/null || echo 0)
SENSITIVE=$(echo "$SESSION_LINES"      | grep -cE 'openat.*(\.ssh|\.aws|/etc/passwd|/etc/shadow|id_rsa|environ|\.env)' 2>/dev/null || echo 0)
PROCESSES=$(echo "$SESSION_LINES"      | grep -c 'execve' 2>/dev/null || echo 0)
NETWORK=$(echo "$SESSION_LINES"        | grep -c 'connect.*SOCK_STREAM' 2>/dev/null || echo 0)

echo ""
echo "─── Sandbox summary ─────────────────────"
printf "  Files read     %4d\n" "$FILES_READ"
printf "  Files written  %4d\n" "$FILES_WRITTEN"
if [[ "$SENSITIVE" -gt 0 ]]; then
  printf "  Sensitive      %4d  ⚠ review dashboard\n" "$SENSITIVE"
fi
printf "  Processes      %4d\n" "$PROCESSES"
printf "  Network        %4d  outbound attempts\n" "$NETWORK"
echo "──────────────────────────────────────────"
