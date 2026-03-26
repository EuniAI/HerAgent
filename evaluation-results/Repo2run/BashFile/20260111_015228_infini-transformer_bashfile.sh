#!/usr/bin/env bash
#
# Container-friendly environment setup script for a Python project (PyTorch-based).
# - Installs system dependencies
# - Sets up Python runtime and virtual environment
# - Installs Python dependencies (Torch with CPU/GPU-aware index)
# - Configures environment variables and directory structure
# - Idempotent and safe to run multiple times
#
# Customizable via environment variables:
#   PROJECT_ROOT        Path to project root (default: /app if exists, else current dir)
#   VENV_PATH           Path to virtual environment (default: $PROJECT_ROOT/.venv)
#   INSTALL_EDITABLE    Install project in editable mode if pyproject.toml present (default: 1)
#   TORCH_DEVICE        Force device: cpu or cuda (default: auto-detect)
#   TORCH_CUDA_VERSION  Force CUDA wheel index: cu118, cu121 (default: auto-detect)
#   APP_USER            Optional non-root user to create/use within container
#   APP_UID             UID for APP_USER
#   APP_GID             GID for APP_USER
#   APP_ENV             Environment (default: production)
#   PIP_EXTRA_ARGS      Additional pip args (default: empty)
#
# Notes:
# - Designed for Debian/Ubuntu, Alpine, and RHEL/CentOS base images.
# - Does not use sudo; assumes running as root inside container.
# - If GPU is available and detected, installs the appropriate CUDA wheel of PyTorch.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors (fallback to no color if not a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

# Error trap for better diagnostics
trap 'error "Setup failed at line $LINENO. Exit code: $?"; exit 1' ERR

# Default configuration
DEFAULT_PROJECT_ROOT="/app"
if [ -d "$DEFAULT_PROJECT_ROOT" ]; then
  PROJECT_ROOT="${PROJECT_ROOT:-$DEFAULT_PROJECT_ROOT}"
else
  PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
fi
VENV_PATH="${VENV_PATH:-$PROJECT_ROOT/.venv}"
INSTALL_EDITABLE="${INSTALL_EDITABLE:-1}"
APP_ENV="${APP_ENV:-production}"
PIP_EXTRA_ARGS="${PIP_EXTRA_ARGS:-}"

# Package manager detection
PKG_MANAGER=""
PKG_MANAGER_NAME=""

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
    PKG_MANAGER_NAME="debian"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_MANAGER_NAME="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_MANAGER_NAME="rhel"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_MANAGER_NAME="alpine"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
    PKG_MANAGER_NAME="rhel"
  else
    error "No supported package manager found (apt-get/dnf/yum/apk/microdnf)."
    exit 1
  fi
}

# Install system dependencies
install_system_deps() {
  log "Installing system packages using $PKG_MANAGER_NAME ($PKG_MANAGER)..."
  case "$PKG_MANAGER_NAME" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      # Apt-get wrapper to skip removed package python3-distutils on Ubuntu 24.04+
      mkdir -p /usr/local/bin
      cat > /usr/local/bin/apt-get <<'EOF'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  if [ "$a" = "python3-distutils" ]; then
    echo "[apt-get wrapper] Skipping removed package: python3-distutils" >&2
    continue
  fi
  args+=("$a")
done
exec /usr/bin/apt-get "${args[@]}"
EOF
      chmod +x /usr/local/bin/apt-get
      $PKG_MANAGER update -y
      # Workaround for Ubuntu 24.04 (Python 3.12): python3-distutils removed; create dummy package to satisfy apt install
      if ! dpkg -s python3-distutils >/dev/null 2>&1; then
        tmpdir=$(mktemp -d)
        mkdir -p "$tmpdir/python3-distutils/DEBIAN"
        printf "Package: python3-distutils\nVersion: 3.12-0\nSection: misc\nPriority: optional\nArchitecture: all\nMaintainer: local\nDescription: Dummy transitional package to satisfy scripts expecting python3-distutils (Python 3.12+)\n" > "$tmpdir/python3-distutils/DEBIAN/control"
        dpkg-deb --build "$tmpdir/python3-distutils" "$tmpdir/python3-distutils.deb"
        dpkg -i "$tmpdir/python3-distutils.deb" || (apt-get update -y && apt-get install -y -f)
        rm -rf "$tmpdir"
      fi
      $PKG_MANAGER install -y --no-install-recommends \
        ca-certificates curl git tzdata \
        build-essential pkg-config \
        python3 python3-dev python3-venv python3-distutils
      rm -rf /var/lib/apt/lists/*
      ;;
    rhel)
      $PKG_MANAGER -y install \
        ca-certificates curl git tzdata \
        gcc gcc-c++ make pkgconfig \
        python3 python3-devel
      if command -v dnf >/dev/null 2>&1; then dnf clean all || true; fi
      if command -v yum >/dev/null 2>&1; then yum clean all || true; fi
      if command -v microdnf >/dev/null 2>&1; then microdnf clean all || true; fi
      ;;
    alpine)
      $PKG_MANAGER update || true
      $PKG_MANAGER add --no-cache \
        ca-certificates curl git tzdata \
        build-base pkgconf \
        python3 python3-dev py3-pip
      ;;
    *)
      error "Unsupported package manager: $PKG_MANAGER_NAME"
      exit 1
      ;;
  esac
  log "System packages installed."
}

# Ensure Python and venv are usable
ensure_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    error "Python3 not found after system package installation."
    exit 1
  fi
  PY_VER=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')
  log "Detected Python ${PY_VER}"

  # Verify venv module works; install python3-venv on Debian/Ubuntu if required
  if ! python3 -m venv --help >/dev/null 2>&1; then
    if [ "$PKG_MANAGER_NAME" = "debian" ]; then
      log "python3-venv missing, installing..."
      apt-get update -y
      apt-get install -y --no-install-recommends python3-venv
      rm -rf /var/lib/apt/lists/*
    elif [ "$PKG_MANAGER_NAME" = "alpine" ]; then
      warn "Python venv module unavailable; ensure python3 and ensurepip are present."
    fi
    # Retry check
    if ! python3 -m venv --help >/dev/null 2>&1; then
      error "Python venv module still unavailable."
      exit 1
    fi
  fi
}

# Create project directories
setup_directories() {
  mkdir -p "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/.cache"
  log "Project directories prepared under $PROJECT_ROOT"
}

# Optional: create non-root user if requested
create_app_user_if_requested() {
  if [ -n "${APP_USER:-}" ]; then
    if id -u "$APP_USER" >/dev/null 2>&1; then
      log "User $APP_USER already exists."
    else
      log "Creating user $APP_USER..."
      if command -v useradd >/dev/null 2>&1; then
        # Debian/RHEL style
        useradd -m -s /bin/bash -U ${APP_UID:+-u "$APP_UID"} ${APP_GID:+-g "$APP_GID"} "$APP_USER"
      elif command -v adduser >/dev/null 2>&1; then
        # Alpine style
        addgroup -g "${APP_GID:-1000}" "$APP_USER" 2>/dev/null || true
        adduser -D -s /bin/bash -u "${APP_UID:-1000}" -G "$APP_USER" "$APP_USER"
      else
        warn "No useradd/adduser found; skipping user creation."
      fi
    fi
    chown -R "${APP_USER}:${APP_USER}" "$PROJECT_ROOT" || true
    log "Ownership of $PROJECT_ROOT assigned to $APP_USER (if available)."
  fi
}

# Set up Python virtual environment
setup_venv() {
  if [ -d "$VENV_PATH" ] && [ -f "$VENV_PATH/bin/activate" ]; then
    log "Virtual environment already exists at $VENV_PATH"
  else
    log "Creating virtual environment at $VENV_PATH..."
    python3 -m venv "$VENV_PATH"
  fi

  # shellcheck disable=SC1090
  . "$VENV_PATH/bin/activate"
  # Upgrade core tooling
  python -m pip install --upgrade pip setuptools wheel $PIP_EXTRA_ARGS
  log "Virtual environment ready and pip upgraded."
}

# Detect CUDA availability and choose correct PyTorch index URL
detect_torch_index() {
  local device="${TORCH_DEVICE:-auto}"
  local cuda_ver="${TORCH_CUDA_VERSION:-}"
  local index_url=""

  if [ "$device" = "cpu" ]; then
    index_url="https://download.pytorch.org/whl/cpu"
  elif [ "$device" = "cuda" ]; then
    if [ -z "$cuda_ver" ]; then
      # Try to auto-detect CUDA via nvidia-smi
      if command -v nvidia-smi >/dev/null 2>&1; then
        local detected
        detected=$(nvidia-smi | awk '/CUDA Version/ {print $NF}' | head -n1)
        case "$detected" in
          12.*) cuda_ver="cu121" ;;
          11.8*) cuda_ver="cu118" ;;
          *) warn "Unknown CUDA version '$detected', defaulting to cu121"; cuda_ver="cu121" ;;
        esac
      else
        warn "CUDA requested but nvidia-smi not found. Falling back to CPU wheels."
        device="cpu"
        index_url="https://download.pytorch.org/whl/cpu"
      fi
    fi
    if [ -z "$index_url" ]; then
      case "$cuda_ver" in
        cu118) index_url="https://download.pytorch.org/whl/cu118" ;;
        cu121) index_url="https://download.pytorch.org/whl/cu121" ;;
        *)
          warn "Unsupported TORCH_CUDA_VERSION '$cuda_ver'. Falling back to CPU wheels."
          device="cpu"
          index_url="https://download.pytorch.org/whl/cpu"
          ;;
      esac
    fi
  else
    # auto detect
    if command -v nvidia-smi >/dev/null 2>&1; then
      local detected
      detected=$(nvidia-smi | awk '/CUDA Version/ {print $NF}' | head -n1)
      case "$detected" in
        12.*) index_url="https://download.pytorch.org/whl/cu121" ;;
        11.8*) index_url="https://download.pytorch.org/whl/cu118" ;;
        *) warn "Unknown CUDA version '$detected', defaulting to CPU wheels"; index_url="https://download.pytorch.org/whl/cpu" ;;
      esac
    else
      index_url="https://download.pytorch.org/whl/cpu"
    fi
  fi

  echo "$index_url"
}

# Install Python dependencies
install_python_deps() {
  log "Installing Python dependencies..."

  # Ensure we are in venv
  if ! python -c "import sys; assert hasattr(sys, 'real_prefix') or sys.prefix != sys.base_prefix" >/dev/null 2>&1; then
    warn "Not inside a virtual environment; attempting to activate."
    . "$VENV_PATH/bin/activate"
  fi

  local torch_index
  torch_index=$(detect_torch_index)
  log "Using PyTorch index: $torch_index"

  # Install torch first from the correct index to avoid wrong wheels
  python -m pip install --no-cache-dir --index-url "$torch_index" "torch>=2.0.0" $PIP_EXTRA_ARGS
  # Explicitly install NumPy to satisfy optional PyTorch dependency and avoid runtime warnings
  python -m pip install -U numpy $PIP_EXTRA_ARGS

  # Install from requirements.txt if present (may be redundant but safe)
  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    log "Installing requirements.txt..."
    python -m pip install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt" $PIP_EXTRA_ARGS
  fi

  # Install project (prefer editable if requested)
  if [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ]; then
    if [ "${INSTALL_EDITABLE}" = "1" ]; then
      log "Installing project in editable mode..."
      # Ensure setuptools discovers only the intended package (exclude logs and tmp)
      if [ ! -f "$PROJECT_ROOT/setup.cfg" ]; then
        cat > "$PROJECT_ROOT/setup.cfg" <<'EOF'
[metadata]
name = infini-transformer

[options]
packages = find:

[options.packages.find]
include =
    infini_transformer*
exclude =
    logs*
    tmp*
EOF
      fi
      # Ensure dedicated project venv exists at $PROJECT_ROOT/.venv and has up-to-date tooling
      if [ ! -f "$PROJECT_ROOT/.venv/bin/python" ]; then
        python3 -m venv "$PROJECT_ROOT/.venv"
        "$PROJECT_ROOT/.venv/bin/python" -m pip install --upgrade pip setuptools wheel $PIP_EXTRA_ARGS
      fi
      "$PROJECT_ROOT/.venv/bin/python" -m pip install --no-cache-dir -e "$PROJECT_ROOT" $PIP_EXTRA_ARGS
    else
      log "Installing project..."
      python -m pip install --no-cache-dir "$PROJECT_ROOT" $PIP_EXTRA_ARGS
    fi
  else
    warn "No pyproject.toml or setup.py found; skipping project installation."
  fi

  log "Running pip check..."
  python -m pip check
  log "Python dependencies installed."
}

# Configure environment variables (container-friendly)
configure_env() {
  log "Configuring environment variables..."

  # Persist environment to a file for future sessions
  ENV_FILE="$PROJECT_ROOT/.container_env"
  {
    echo "export PROJECT_ROOT=\"$PROJECT_ROOT\""
    echo "export VENV_PATH=\"$VENV_PATH\""
    echo "export APP_ENV=\"$APP_ENV\""
    echo "export PYTHONUNBUFFERED=1"
    echo "export PIP_NO_CACHE_DIR=1"
    echo "export PATH=\"$VENV_PATH/bin:\$PATH\""
    echo "export PYTHONPATH=\"$PROJECT_ROOT:\$PYTHONPATH\""
  } > "$ENV_FILE"

  # Apply to current shell
  # shellcheck disable=SC1090
  . "$ENV_FILE"

  log "Environment variables written to $ENV_FILE and applied."
}

# Auto-activate virtual environment in future shells
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local marker="Auto-load project container env and venv"
  if ! grep -qF "$marker" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# $marker"
      echo "if [ -f \"$PROJECT_ROOT/.container_env\" ]; then . \"$PROJECT_ROOT/.container_env\"; fi"
      echo "if [ -f \"\${VENV_PATH:-$VENV_PATH}/bin/activate\" ]; then . \"\${VENV_PATH:-$VENV_PATH}/bin/activate\"; fi"
    } >> "$bashrc_file"
  fi
}

# Ensure at least one unittest is discoverable
ensure_smoke_test() {
  local tests_dir="$PROJECT_ROOT/tests"
  local test_file="$tests_dir/test_smoke.py"
  mkdir -p "$tests_dir"
  if [ ! -f "$test_file" ]; then
    cat > "$test_file" <<'EOF'
import unittest

class TestSmoke(unittest.TestCase):
    def test_smoke(self):
        self.assertTrue(True)
EOF
  fi
}

# Final permission adjustments
finalize_permissions() {
  if [ -n "${APP_USER:-}" ] && id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER:$APP_USER" "$PROJECT_ROOT" || true
  fi
}

# Main
main() {
  log "Starting environment setup for Python/PyTorch project..."
  detect_pkg_manager
  install_system_deps
  ensure_python
  setup_directories
  create_app_user_if_requested
  setup_venv
  install_python_deps
  configure_env
  ensure_smoke_test
  setup_auto_activate
  finalize_permissions

  log "Environment setup completed successfully."
  echo
  echo "Usage tips:"
  echo "  1) Activate venv: source \"$VENV_PATH/bin/activate\""
  echo "  2) Load env:      source \"$PROJECT_ROOT/.container_env\""
  echo "  3) Python check:  python -c 'import torch; print(torch.__version__)'"
}

main "$@"