#!/bin/bash
# bootstrap.sh — install all prerequisites before running `make setup`

set -uo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

failures=()

log()    { echo -e "${BOLD}==> $1${RESET}"; }
ok()     { echo -e "${GREEN}    [ok]${RESET} $1"; }
skip()   { echo -e "${YELLOW}  [skip]${RESET} $1 (already installed)"; }
fail()   { echo -e "${RED}  [fail]${RESET} $1"; failures+=("$1"); }

# ---------------------------------------------------------------------------
# 1. Prompt for projects directory
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}secureLocalDev — Bootstrap${RESET}"
echo "-----------------------------------------------"
echo "This script installs all prerequisites and runs"
echo "make setup automatically."
echo ""
read -rp "Enter your projects directory (e.g. ~/Projects): " PROJECTS_DIR
PROJECTS_DIR="${PROJECTS_DIR/#\~/$HOME}"

if [[ -z "$PROJECTS_DIR" ]]; then
  PROJECTS_DIR="$HOME/Projects"
  echo "  No input — using default: $PROJECTS_DIR"
fi

echo ""
log "Projects directory set to: $PROJECTS_DIR"

# ---------------------------------------------------------------------------
# 2. Detect OS
# ---------------------------------------------------------------------------
OS="$(uname -s)"
log "Detected OS: $OS"

# ---------------------------------------------------------------------------
# 3. macOS prerequisites
# ---------------------------------------------------------------------------
if [[ "$OS" == "Darwin" ]]; then

  log "Checking Xcode Command Line Tools..."
  if xcode-select -p &>/dev/null; then
    skip "Xcode CLI tools"
  else
    echo "    Installing Xcode CLI tools (a dialog may appear)..."
    if xcode-select --install 2>&1; then
      ok "Xcode CLI tools installed"
    else
      fail "Xcode CLI tools — install manually with: xcode-select --install"
    fi
  fi

  log "Checking Homebrew..."
  if command -v brew &>/dev/null; then
    skip "Homebrew"
  else
    echo "    Installing Homebrew..."
    if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
      # Add brew to PATH for the rest of this script on Apple Silicon
      if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      fi
      ok "Homebrew installed"
    else
      fail "Homebrew — install manually: https://brew.sh"
    fi
  fi

  log "Installing packages via Homebrew..."
  BREW_PACKAGES=(lima qemu ansible mise tmux)
  for pkg in "${BREW_PACKAGES[@]}"; do
    if brew list "$pkg" &>/dev/null; then
      skip "$pkg"
    else
      if brew install "$pkg"; then
        ok "$pkg"
      else
        fail "brew install $pkg"
      fi
    fi
  done

# ---------------------------------------------------------------------------
# 4. Linux prerequisites
# ---------------------------------------------------------------------------
elif [[ "$OS" == "Linux" ]]; then

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO="${ID:-unknown}"
  else
    DISTRO="unknown"
  fi
  log "Linux distro: $DISTRO"

  case "$DISTRO" in
    ubuntu|debian|linuxmint|pop)
      log "Installing packages via apt-get..."
      if sudo apt-get update -qq && sudo apt-get install -y ansible curl git tmux; then
        ok "apt packages"
      else
        fail "apt-get install (ansible curl git tmux)"
      fi
      ;;
    rhel|fedora|centos|rocky|almalinux)
      log "Installing packages via dnf..."
      if sudo dnf install -y ansible curl git tmux; then
        ok "dnf packages"
      else
        fail "dnf install (ansible curl git tmux)"
      fi
      ;;
    *)
      fail "Unsupported distro '$DISTRO' — install ansible, curl, git, tmux manually"
      ;;
  esac

  log "Checking mise..."
  if command -v mise &>/dev/null; then
    skip "mise"
  else
    if curl https://mise.run | sh; then
      # Activate mise for the rest of this script
      export PATH="$HOME/.local/bin:$PATH"
      ok "mise installed"
    else
      fail "mise — install manually: curl https://mise.run | sh"
    fi
  fi

else
  fail "Unsupported OS: $OS"
fi

# ---------------------------------------------------------------------------
# 5. Run mise install (both OS)
# ---------------------------------------------------------------------------
log "Running mise install..."
if command -v mise &>/dev/null; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if (cd "$REPO_DIR" && mise install); then
    ok "mise install"
  else
    fail "mise install — check .mise.toml or .tool-versions in repo root"
  fi
else
  fail "mise not found — skipping mise install"
fi

# ---------------------------------------------------------------------------
# 6. Wire sandbox() into ~/.zshrc (macOS only, guarded against duplicates)
# ---------------------------------------------------------------------------
if [[ "$OS" == "Darwin" ]]; then
  log "Wiring sandbox() shell function into ~/.zshrc..."

  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  SANDBOX_SNIPPET="
# secureLocalDev — sandbox command
sandbox() {
  PROJECT=\$(pwd) \\
  IMAGE=\${SANDBOX_IMAGE:-node:20-alpine} \\
  \"$REPO_DIR/scripts/run-agent.sh\" \"\$@\"
}"

  if grep -q "secureLocalDev — sandbox command" ~/.zshrc 2>/dev/null; then
    skip "sandbox() already in ~/.zshrc"
  else
    if echo "$SANDBOX_SNIPPET" >> ~/.zshrc; then
      ok "sandbox() added to ~/.zshrc"
      echo "    Run: source ~/.zshrc  (or open a new terminal)"
    else
      fail "Could not write to ~/.zshrc"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 7. Run Ansible setup with projects dir passed as extra variable
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ${#failures[@]} -eq 0 ]]; then
  log "Running ansible setup (sandbox_projects_dir=$PROJECTS_DIR)..."
  if (cd "$REPO_DIR" && ansible-playbook ansible/sandbox.yml \
        -e "sandbox_projects_dir=$PROJECTS_DIR"); then
    ok "ansible-playbook"
  else
    fail "ansible-playbook ansible/sandbox.yml"
  fi
fi

# ---------------------------------------------------------------------------
# 8. Final report
# ---------------------------------------------------------------------------
echo ""
echo "-----------------------------------------------"
if [[ ${#failures[@]} -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}Bootstrap complete — no failures.${RESET}"
  echo ""
  echo "Next steps:"
  if [[ "$OS" == "Darwin" ]]; then
    echo "  1. source ~/.zshrc"
    echo "  2. sandbox npm test"
  else
    echo "  1. source ~/.bashrc"
    echo "  2. sandbox npm test"
  fi
else
  echo -e "${YELLOW}${BOLD}Bootstrap finished with ${#failures[@]} failure(s):${RESET}"
  for f in "${failures[@]}"; do
    echo -e "  ${RED}•${RESET} $f"
  done
  echo ""
  echo "Resolve the above, then re-run: ./scripts/bootstrap.sh"
fi
echo ""
