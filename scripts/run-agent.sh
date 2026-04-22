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

# Safe mode: mount the project read-only so nothing inside the container can
# modify host files. Dependency installs still work (they write to named volumes,
# not the project dir). Use for exploratory runs where you want pure observation.
SANDBOX_SAFE=${SANDBOX_SAFE:-0}
if [[ "$SANDBOX_SAFE" == "1" ]]; then
  PROJECT_MOUNT_MODE="ro"
  echo "[sandbox] SAFE MODE — project mounted read-only, writes blocked"
else
  PROJECT_MOUNT_MODE="rw"
fi

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
      --volume "$PROJECT:/app:${PROJECT_MOUNT_MODE}" $extra_volumes \
      --workdir /app --runtime-flag=ignore-cgroups \
      $IMAGE sh -c "$cmd"
  else
    sudo podman run --rm \
      --runtime runsc --user 1000:1000 --cap-drop ALL \
      --security-opt no-new-privileges --network none \
      --memory="$SANDBOX_MEMORY" --cpus="$SANDBOX_CPUS" \
      --volume "$PROJECT:/app:${PROJECT_MOUNT_MODE}" $extra_volumes \
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
# Parting-gift protection: snapshot sensitive project files before the run.
# After the run we diff the snapshot to detect modifications made from inside
# the container. SANDBOX_APPROVE_WRITES=1 adds an interactive approval gate.
# ---------------------------------------------------------------------------
SENSITIVE_PATTERNS=( "Makefile" "GNUmakefile" "package.json" "requirements.txt"
  "go.mod" "go.sum" "Pipfile" "pyproject.toml" "*.sh"
  "Dockerfile" "Dockerfile.*" "docker-compose.yml" "docker-compose.*.yml" )

is_sensitive_file() {
  local base
  base="$(basename "$1")"
  local pat
  for pat in "${SENSITIVE_PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$base" in $pat) return 0 ;; esac
  done
  # Anything under .github/
  [[ "$1" == ".github/"* ]] && return 0
  return 1
}

if [[ "$SANDBOX_SAFE" != "1" ]]; then
  SNAPSHOT_DIR=$(mktemp -d /tmp/sandbox-snapshot-XXXXXX)

  find_sensitive() {
    find "$PROJECT" -maxdepth 4 \( \
      -name "Makefile" -o -name "GNUmakefile" -o \
      -name "package.json" -o -name "requirements.txt" -o \
      -name "go.mod" -o -name "go.sum" -o -name "Pipfile" -o -name "pyproject.toml" -o \
      -name "*.sh" -o \
      -name "Dockerfile" -o -name "Dockerfile.*" -o \
      -name "docker-compose.yml" -o -name "docker-compose.*.yml" \
    \) ! -path "*/node_modules/*" ! -path "*/.git/*" -print 2>/dev/null
  }

  while IFS= read -r f; do
    rel="${f#$PROJECT/}"
    mkdir -p "$SNAPSHOT_DIR/$(dirname "$rel")"
    cp "$f" "$SNAPSHOT_DIR/$rel" 2>/dev/null
  done < <(find_sensitive)
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
    --volume "$PROJECT:/app:${PROJECT_MOUNT_MODE}" \
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
    --volume "$PROJECT:/app:${PROJECT_MOUNT_MODE}" \
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
if [[ "$SANDBOX_SAFE" == "1" ]]; then
  printf "  Mode           safe (read-only mount)\n"
fi
printf "  Files read     %4d\n" "$FILES_READ"
if [[ "$SANDBOX_SAFE" != "1" ]]; then
  printf "  Files written  %4d\n" "$FILES_WRITTEN"
fi
if [[ "$SENSITIVE" -gt 0 ]]; then
  printf "  Sensitive      %4d  ⚠ review dashboard\n" "$SENSITIVE"
fi
printf "  Processes      %4d\n" "$PROCESSES"
printf "  Network        %4d  outbound attempts\n" "$NETWORK"
echo "──────────────────────────────────────────"

# ---------------------------------------------------------------------------
# Parting-gift protection: show written project paths + flag sensitive changes.
# Skipped in safe mode — the read-only mount makes writes impossible.
# ---------------------------------------------------------------------------
if [[ "$SANDBOX_SAFE" != "1" ]]; then

  # Extract all paths written inside /app/ during this run from gVisor strace
  WRITTEN_PATHS=$(echo "$SESSION_LINES" \
    | grep -E 'openat.*(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC)' \
    | sed -n 's/.*openat[^"]*"\([^"]*\)".*/\1/p' \
    | grep '^/app/' \
    | sed 's|^/app/||' \
    | sort -u)

  # Detect which sensitive files were modified or newly created
  MODIFIED_SENSITIVE=()
  CREATED_SENSITIVE=()
  if [[ -n "$WRITTEN_PATHS" ]]; then
    while IFS= read -r rel; do
      is_sensitive_file "$rel" || continue
      if [[ -f "$SNAPSHOT_DIR/$rel" ]]; then
        diff -q "$SNAPSHOT_DIR/$rel" "$PROJECT/$rel" &>/dev/null || MODIFIED_SENSITIVE+=("$rel")
      else
        CREATED_SENSITIVE+=("$rel")
      fi
    done <<< "$WRITTEN_PATHS"
  fi

  # Build a lookup set of sensitive paths for display annotation
  declare -A SENSITIVE_LOOKUP
  for rel in "${MODIFIED_SENSITIVE[@]}" "${CREATED_SENSITIVE[@]}"; do
    SENSITIVE_LOOKUP["$rel"]=1
  done

  if [[ -n "$WRITTEN_PATHS" ]]; then
    echo ""
    echo "  Files written to your project:"
    while IFS= read -r rel; do
      if [[ "${SENSITIVE_LOOKUP[$rel]:-0}" == "1" ]]; then
        printf "    %-42s ⚠ sensitive project file\n" "$rel"
      else
        printf "    %s\n" "$rel"
      fi
    done <<< "$WRITTEN_PATHS"
    echo "──────────────────────────────────────────"
  fi

  # Approval gate — only active when SANDBOX_APPROVE_WRITES=1
  if [[ "${SANDBOX_APPROVE_WRITES:-0}" == "1" ]] \
     && [[ ${#MODIFIED_SENSITIVE[@]} -gt 0 || ${#CREATED_SENSITIVE[@]} -gt 0 ]]; then
    echo ""
    echo "  ⚠  Sensitive project files were modified inside the sandbox."
    echo "     Keep these changes? [y/N]"
    read -r _response </dev/tty
    if [[ ! "$_response" =~ ^[Yy]$ ]]; then
      for rel in "${MODIFIED_SENSITIVE[@]}"; do
        cp "$SNAPSHOT_DIR/$rel" "$PROJECT/$rel"
        echo "  Restored: $rel"
      done
      for rel in "${CREATED_SENSITIVE[@]}"; do
        rm -f "$PROJECT/$rel"
        echo "  Removed:  $rel"
      done
      echo "  Changes reverted."
    else
      echo "  Changes kept."
    fi
  fi

  rm -rf "$SNAPSHOT_DIR"

fi
