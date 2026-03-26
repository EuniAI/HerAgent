#!/usr/bin/env bash
# Ultralytics/YOLO environment setup script for Docker containers
# This script installs system packages, Python runtime, creates a virtual environment,
# installs project dependencies from pyproject.toml, and configures environment variables.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail

umask 022

# --------------- Configurable settings (can be overridden via environment variables) ---------------
APP_DIR="${APP_DIR:-/app}"
VENV_PATH="${VENV_PATH:-/opt/venv}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PIP_BIN="${PIP_BIN:-pip3}"
REQUIRE_PYTHON_MIN="${REQUIRE_PYTHON_MIN:-3.8}"

# Installation mode for the Python package in current directory:
#   false (default): pip install .
#   true:  pip install -e .  (editable/dev mode)
INSTALL_EDITABLE="${INSTALL_EDITABLE:-false}"

# Optional: install development dependencies defined in pyproject as [dev]
INSTALL_DEV_DEPS="${INSTALL_DEV_DEPS:-false}"

# Optional: pre-install torch/torchvision with a specific CUDA variant or versions (defaults to CPU wheels)
# Examples:
#   TORCH_CUDA=cu121 TORCH_VERSION=2.4.0 TORCHVISION_VERSION=0.19.0
TORCH_CUDA="${TORCH_CUDA:-cpu}"           # one of: cpu, cu118, cu121, rocm6.0, etc.
TORCH_VERSION="${TORCH_VERSION:-}"        # leave empty to let pip resolve
TORCHVISION_VERSION="${TORCHVISION_VERSION:-}" # leave empty to let pip resolve
PREINSTALL_TORCH="${PREINSTALL_TORCH:-true}"  # if true, pre-install torch/torchvision before project install

# Networking configuration passthrough (optional)
PIP_INDEX_URL="${PIP_INDEX_URL:-}"
PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL:-}"

# Ownership configuration (optional) - if provided, change ownership on APP_DIR and VENV_PATH
APP_UID="${APP_UID:-}"
APP_GID="${APP_GID:-}"

# --------------- Colors & Logging ---------------
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }
debug() { echo "${BLUE}[DEBUG] $*${NC}"; }

trap 'err "Setup failed at line $LINENO"; exit 1' ERR

# --------------- Utility functions ---------------
compare_versions() {
  # returns 0 if $1 >= $2, else 1
  # usage: compare_versions "3.10" "3.8"
  awk -v a="$1" -v b="$2" '
    function ver(v, A,i,n){n=split(v,A,".");for(i=1;i<=n;i++){printf "%d%03d", A[i], 0}}
    BEGIN{ if (ver(a) >= ver(b)) exit 0; else exit 1 }'
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Command '$1' not found"; return 1; }
}

# --------------- Package manager detection ---------------
PKG_MANAGER=""
update_pkgs() { :; }
install_pkgs() { :; }
clean_pkg_cache() { :; }

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    update_pkgs() {
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
    }
    install_pkgs() {
      export DEBIAN_FRONTEND=noninteractive
      # shellcheck disable=SC2068
      apt-get install -y --no-install-recommends $@
    }
    clean_pkg_cache() {
      apt-get clean
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
    }
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    update_pkgs() { dnf -y makecache; }
    install_pkgs() { dnf install -y "$@"; }
    clean_pkg_cache() { dnf clean all; rm -rf /var/cache/dnf; }
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    update_pkgs() { yum -y makecache; }
    install_pkgs() { yum install -y "$@"; }
    clean_pkg_cache() { yum clean all; rm -rf /var/cache/yum; }
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    update_pkgs() { apk update; }
    install_pkgs() { apk add --no-cache "$@"; }
    clean_pkg_cache() { :; }
  else
    err "Unsupported base image: no apt-get/dnf/yum/apk detected."
    exit 1
  fi
  log "Detected package manager: $PKG_MANAGER"
}

# --------------- System packages installation ---------------
install_system_dependencies() {
  log "Installing required system packages..."

  case "$PKG_MANAGER" in
    apt)
      update_pkgs
      install_pkgs \
        ca-certificates curl git \
        python3 python3-venv python3-pip python3-dev \
        build-essential pkg-config \
        ffmpeg \
        libgl1 libglib2.0-0 libsm6 libxrender1 libxext6
      ;;
    dnf|yum)
      update_pkgs
      # FFmpeg may require EPEL on RHEL/CentOS; ignore failure if unavailable
      install_pkgs ca-certificates curl git \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconf-pkg-config || true
      install_pkgs \
        ffmpeg || warn "FFmpeg not available in default repos; skipping."
      # OpenCV/Qt runtime libs
      install_pkgs \
        glib2 libXext libSM libXrender mesa-libGL || true
      ;;
    apk)
      update_pkgs
      install_pkgs ca-certificates curl git \
        python3 py3-pip py3-virtualenv python3-dev \
        build-base pkgconfig \
        ffmpeg \
        libstdc++ \
        mesa-gl \
        libxrender \
        libxext \
        glib
      warn "Alpine Linux detected. Note: PyTorch wheels are not provided for musl libc. Installation may fail."
      ;;
  esac

  # Ensure Python symlinks exist as python3/pip3
  if ! command -v python3 >/dev/null 2>&1 && command -v python >/dev/null 2>&1; then
    ln -sf "$(command -v python)" /usr/bin/python3 || true
  fi
  if ! command -v pip3 >/dev/null 2>&1 && command -v pip >/dev/null 2>&1; then
    ln -sf "$(command -v pip)" /usr/bin/pip3 || true
  fi

  clean_pkg_cache
  log "System packages installed."
}

# --------------- Python runtime checks ---------------
ensure_python() {
  require_cmd "$PYTHON_BIN" || PYTHON_BIN="python3"
  require_cmd "$PYTHON_BIN"
  local v
  v="$("$PYTHON_BIN" -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
  if ! compare_versions "$v" "$REQUIRE_PYTHON_MIN"; then
    err "Python $REQUIRE_PYTHON_MIN+ is required, found $v"
    exit 1
  fi
  log "Python $v detected."
}

# --------------- Virtual environment setup ---------------
setup_venv() {
  if [ ! -d "$VENV_PATH" ] || [ ! -x "$VENV_PATH/bin/python" ]; then
    log "Creating virtual environment at $VENV_PATH"
    "$PYTHON_BIN" -m venv "$VENV_PATH"
  else
    log "Virtual environment already exists at $VENV_PATH"
  fi

  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"
  python -V
  pip -V

  # Upgrade core tooling
  PIP_DEFAULT_TIMEOUT="${PIP_DEFAULT_TIMEOUT:-100}"
  export PIP_DEFAULT_TIMEOUT
  pip install --no-input --upgrade pip setuptools wheel packaging
}

# Configure pip to prefer CPU-only PyTorch wheels globally
configure_pip_cpu_index() {
  mkdir -p /etc
  printf "[global]\nindex-url = https://download.pytorch.org/whl/cpu\nextra-index-url = https://pypi.org/simple\n" > /etc/pip.conf
}

# Ensure the virtual environment auto-activates for interactive shells
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line="source $VENV_PATH/bin/activate"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# --------------- Torch pre-install (optional) ---------------
preinstall_torch_if_requested() {
  if [ "${PREINSTALL_TORCH}" != "true" ]; then
    return 0
  fi

  log "Pre-installing torch/torchvision (TORCH_CUDA=${TORCH_CUDA:-cpu})"

  local pkgs=()
  if [ -n "$TORCH_VERSION" ]; then
    if [ "${TORCH_CUDA}" = "cpu" ]; then
      pkgs+=("torch==${TORCH_VERSION}")
    else
      pkgs+=("torch==${TORCH_VERSION}")
    fi
  else
    pkgs+=("torch==2.9.1")
  fi

  if [ -n "$TORCHVISION_VERSION" ]; then
    pkgs+=("torchvision==${TORCHVISION_VERSION}")
  else
    pkgs+=("torchvision")
  fi

  # Configure index URLs if CUDA variant requested
  local extra_args=()
  if [ "$TORCH_CUDA" != "cpu" ]; then
    # Prefer PyTorch CUDA wheels from official index
    extra_args+=(--index-url "https://download.pytorch.org/whl/${TORCH_CUDA}")
    if [ -n "$PIP_EXTRA_INDEX_URL" ]; then
      extra_args+=(--extra-index-url "$PIP_EXTRA_INDEX_URL")
    else
      # fallback to PyPI as extra index so non-PyTorch deps still resolve
      extra_args+=(--extra-index-url "https://pypi.org/simple")
    fi
  else
    # Force CPU-only PyTorch wheels from official index and keep PyPI for other deps
    extra_args+=(--index-url "https://download.pytorch.org/whl/cpu")
    extra_args+=(--extra-index-url "https://pypi.org/simple")
  fi

  # Avoid building from source for heavy packages
  export PIP_ONLY_BINARY="torch,torchvision,:all:"
  pip install --no-cache-dir "${extra_args[@]}" "${pkgs[@]}" || {
    warn "torch/torchvision pre-install failed. Will rely on project dependency resolution."
    return 0
  }
  log "torch/torchvision pre-installation completed."
}

# --------------- Project installation ---------------
install_project() {
  # Ensure we're at the project root or APP_DIR has the project
  local PROJECT_ROOT
  if [ -f "./pyproject.toml" ] || [ -f "./setup.py" ]; then
    PROJECT_ROOT="$(pwd)"
  elif [ -d "$APP_DIR" ] && [ -f "$APP_DIR/pyproject.toml" ]; then
    PROJECT_ROOT="$APP_DIR"
  else
    warn "pyproject.toml not found in current directory or $APP_DIR. Skipping project installation."
    return 0
  fi

  log "Installing project from $PROJECT_ROOT"
  cd "$PROJECT_ROOT"

  # Respect user-provided index URLs
  local pip_args=(--no-cache-dir)
  if [ -n "$PIP_INDEX_URL" ]; then
    pip_args+=(--index-url "$PIP_INDEX_URL")
  fi
  if [ -n "$PIP_EXTRA_INDEX_URL" ]; then
    pip_args+=(--extra-index-url "$PIP_EXTRA_INDEX_URL")
  fi

  # Prevent building source distributions for heavy deps if wheels exist
  export PIP_PREFER_BINARY=1
  export PIP_DEFAULT_TIMEOUT="${PIP_DEFAULT_TIMEOUT:-100}"

  # For headless environments, set a non-interactive matplotlib backend
  export MPLBACKEND="${MPLBACKEND:-Agg}"

  # Install base project
  if [ "$INSTALL_EDITABLE" = "true" ]; then
    if [ "$INSTALL_DEV_DEPS" = "true" ]; then
      pip install "${pip_args[@]}" -e ".[dev]" || pip install "${pip_args[@]}" -e .
    else
      pip install "${pip_args[@]}" -e .
    fi
  else
    if [ "$INSTALL_DEV_DEPS" = "true" ]; then
      pip install "${pip_args[@]}" ".[dev]" || pip install "${pip_args[@]}" .
    else
      pip install "${pip_args[@]}" .
    fi
  fi

  log "Project installation complete."
}

# --------------- Environment variables & profile ---------------
configure_environment() {
  log "Configuring runtime environment variables and shell profile..."

  mkdir -p /etc/profile.d || true
  cat >/etc/profile.d/ultralytics_env.sh <<EOF
# Auto-generated by setup script
# Ensure virtual environment is on PATH for all users/shells
if [ -d "$VENV_PATH/bin" ]; then
  case ":\$PATH:" in
    *:"$VENV_PATH/bin":*) ;;
    *) export PATH="$VENV_PATH/bin:\$PATH" ;;
  esac
fi

# Safer Python I/O in containers
export PYTHONUNBUFFERED="\${PYTHONUNBUFFERED:-1}"
export PYTHONDONTWRITEBYTECODE="\${PYTHONDONTWRITEBYTECODE:-1}"

# Pip behavior in containers
export PIP_NO_CACHE_DIR="\${PIP_NO_CACHE_DIR:-1}"
export PIP_DEFAULT_TIMEOUT="\${PIP_DEFAULT_TIMEOUT:-100}"

# Matplotlib headless backend
export MPLBACKEND="\${MPLBACKEND:-Agg}"

# Optional: uncomment to reduce OpenMP thread contention in containers
# export OMP_NUM_THREADS="\${OMP_NUM_THREADS:-1}"

# Ultralytics CLI becomes available via PATH after venv activation
EOF

  chmod 0644 /etc/profile.d/ultralytics_env.sh

  # Convenience wrapper to activate venv for interactive shells
  cat >/usr/local/bin/activate-venv <<'EOF'
#!/usr/bin/env bash
set -e
VENV_PATH="${VENV_PATH:-/opt/venv}"
# shellcheck disable=SC1090
if [ -f "$VENV_PATH/bin/activate" ]; then
  . "$VENV_PATH/bin/activate"
  echo "Activated virtual environment at $VENV_PATH"
else
  echo "Virtual environment not found at $VENV_PATH" >&2
  exit 1
fi
EOF
  chmod 0755 /usr/local/bin/activate-venv

  log "Environment configuration complete."
}

# --------------- Directories and permissions ---------------
setup_directories_and_permissions() {
  log "Setting up project directory structure and permissions..."

  mkdir -p "$APP_DIR"
  # Create common runtime directories used by Ultralytics (optional)
  mkdir -p "$APP_DIR/runs" "$APP_DIR/data" "$APP_DIR/models" || true

  # Ensure venv exists dir perms are correct
  mkdir -p "$VENV_PATH"

  if [ -n "$APP_UID" ] && [ -n "$APP_GID" ]; then
    if getent group "$APP_GID" >/dev/null 2>&1; then
      :
    else
      # Create group if not exists (OK to fail if not supported)
      groupadd -g "$APP_GID" appgroup 2>/dev/null || true
    fi
    if getent passwd "$APP_UID" >/dev/null 2>&1; then
      :
    else
      useradd -m -u "$APP_UID" -g "${APP_GID}" appuser 2>/dev/null || true
    fi
    chown -R "$APP_UID":"$APP_GID" "$APP_DIR" "$VENV_PATH" 2>/dev/null || true
  fi

  log "Directories and permissions configured."
}

# --------------- Main ---------------
main() {
  log "Starting Ultralytics/YOLO environment setup..."

  detect_pkg_manager
  install_system_dependencies
  ensure_python
  setup_venv
  configure_pip_cpu_index
  preinstall_torch_if_requested
  install_project
  configure_environment
  setup_directories_and_permissions
  setup_auto_activate

  log "Environment setup completed successfully."
  echo
  echo "Usage hints:"
  echo "  - Start a new shell to pick up /etc/profile.d env, or run: . /etc/profile.d/ultralytics_env.sh"
  echo "  - Activate venv interactively: source $VENV_PATH/bin/activate  (or run: activate-venv)"
  echo "  - Ultralytics CLI (yolo) should now be available: yolo --help"
}

main "$@"