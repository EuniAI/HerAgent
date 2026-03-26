#!/usr/bin/env bash
# Container-friendly project environment setup script
# Installs runtimes, system deps, project deps, and configures environment
# Safe to run multiple times (idempotent)

set -Eeuo pipefail

#---------------------------
# Globals and configuration
#---------------------------
PROJECT_ROOT="$(pwd)"
CACHE_DIR="$PROJECT_ROOT/.cache/setup"
LOG_FILE="$CACHE_DIR/setup.log"
ENV_FILE="$PROJECT_ROOT/.env"

# Default environment configuration (can be overridden via existing .env or env vars)
: "${APP_ENV:=production}"
: "${PYTHON_VERSION_MIN:=3.8}"
: "${PY_VENV_DIR:=$PROJECT_ROOT/.venv}"
: "${PIP_NO_CACHE_DIR:=1}"
: "${PIP_DISABLE_PIP_VERSION_CHECK:=1}"
: "${FORCE_PY_DEPS:=0}"
: "${FORCE_NODE_DEPS:=0}"
: "${SPACY_MODEL:=en_core_web_sm}"
: "${SKIP_SPACY_MODEL:=0}"

# Colors for output
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
BLUE="$(printf '\033[0;34m')"
NC="$(printf '\033[0m')"

#---------------------------
# Logging and traps
#---------------------------
umask 022
mkdir -p "$CACHE_DIR" "$PROJECT_ROOT/logs" "$PROJECT_ROOT/data" "$PROJECT_ROOT/tmp"

exec 3>&1 1>>"$LOG_FILE" 2>&1

log()    { printf "%b[%s] %s%b\n" "$GREEN" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$NC" >&3; }
warn()   { printf "%b[WARN %s] %s%b\n" "$YELLOW" "$(date +'%H:%M:%S')" "$*" "$NC" >&3; }
error()  { printf "%b[ERROR %s] %s%b\n" "$RED" "$(date +'%H:%M:%S')" "$*" "$NC" >&3; }
detail() { printf "%b - %s%b\n" "$BLUE" "$*" "$NC" >&3; }

cleanup() {
  # Best-effort package manager cache cleanup
  if command -v apt-get >/dev/null 2>&1; then
    rm -rf /var/lib/apt/lists/* || true
  fi
}
on_error() {
  local exit_code=$?
  error "Setup failed (exit code $exit_code). See log: $LOG_FILE"
  cleanup || true
  exit "$exit_code"
}
trap on_error ERR
trap cleanup EXIT

#---------------------------
# Helpers
#---------------------------
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

# Read .env if present to load overrides
load_dotenv() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC2046
    set -a
    # Filter only KEY=VALUE lines, ignore comments
    # shellcheck disable=SC1090
    . <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" || true)
    set +a
  fi
}

# Package manager detection and wrapper
PKG_MANAGER=""
pkg_update() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
  elif command -v apk >/dev/null 2>&1; then
    apk update
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y makecache
  elif command -v yum >/dev/null 2>&1; then
    yum -y makecache
  fi
}
pkg_install() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends "${pkgs[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  else
    warn "No supported package manager found to install: ${pkgs[*]}"
    return 1
  fi
  return 0
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/devnull 2>&1; then
    PKG_MANAGER="apk"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER="unknown"
  fi
}

#---------------------------
# System dependencies
#---------------------------
install_base_system_deps() {
  log "Installing base system packages..."
  detect_pkg_manager
  if [ "$PKG_MANAGER" = "unknown" ]; then
    warn "Unknown package manager. Skipping system package installation."
    return 0
  fi
  if ! is_root; then
    warn "Not running as root. Skipping system package installation."
    return 0
  fi

  pkg_update

  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl wget git bash tar xz-utils unzip \
                  build-essential pkg-config openssl libffi-dev \
                  tzdata
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl wget git bash tar xz unzip \
                  build-base pkgconfig openssl-dev libffi-dev \
                  tzdata
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git bash tar xz unzip \
                  which make gcc gcc-c++ pkgconfig \
                  openssl-devel libffi-devel \
                  tzdata
      update-ca-trust || true
      ;;
  esac
  log "Base system packages installed."
}

#---------------------------
# Python setup
#---------------------------
version_ge() {
  # Compare semantic versions (two or three components)
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}
find_python3() {
  if command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return 0
  elif command -v python >/dev/null 2>&1; then
    # Ensure python points to 3.x
    if python - <<'PY' >/dev/null 2>&1
import sys
sys.exit(0 if sys.version_info.major >= 3 else 1)
PY
    then
      echo "python"
      return 0
    fi
  fi
  return 1
}
ensure_python_runtime() {
  log "Ensuring Python runtime >= $PYTHON_VERSION_MIN..."
  local pybin=""
  if pybin="$(find_python3)"; then
    :
  else
    if ! is_root; then
      error "Python 3 not found and cannot install system packages as non-root."
      exit 1
    fi
    case "$PKG_MANAGER" in
      apt)
        pkg_install python3 python3-venv python3-pip python3-dev
        ;;
      apk)
        pkg_install python3 py3-pip python3-dev
        ;;
      dnf|yum)
        pkg_install python3 python3-pip python3-devel
        ;;
      *)
        error "Cannot install Python: unsupported package manager."
        exit 1
        ;;
    esac
    pybin="$(find_python3 || true)"
    if [ -z "$pybin" ]; then
      error "Failed to install Python 3."
      exit 1
    fi
  fi

  # Check version
  local pyver
  pyver="$("$pybin" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  if ! version_ge "$pyver" "$PYTHON_VERSION_MIN"; then
    warn "Detected Python $pyver < $PYTHON_VERSION_MIN. Some features may not work."
  fi

  # Ensure pip and venv are available
  "$pybin" -m ensurepip --upgrade >/dev/null 2>&1 || true
  "$pybin" -m pip install -U pip setuptools wheel >/dev/null 2>&1 || true

  log "Python runtime available: $pyver"
}
create_or_activate_venv() {
  local pybin
  pybin="$(find_python3)"
  if [ ! -d "$PY_VENV_DIR" ]; then
    log "Creating Python virtual environment at $PY_VENV_DIR"
    "$pybin" -m venv "$PY_VENV_DIR"
  else
    log "Using existing virtual environment at $PY_VENV_DIR"
  fi
  # shellcheck disable=SC1090
  . "$PY_VENV_DIR/bin/activate"
  python -m pip install -U pip setuptools wheel
}

install_python_build_tools() {
  log "Installing Python build dependencies for native extensions (if needed)..."
  if ! is_root; then
    warn "Non-root user: cannot install system build dependencies."
    return 0
  fi
  case "$PKG_MANAGER" in
    apt)
      pkg_install build-essential python3-dev libffi-dev libssl-dev
      ;;
    apk)
      pkg_install build-base python3-dev libffi-dev openssl-dev
      ;;
    dnf|yum)
      pkg_install gcc gcc-c++ make python3-devel libffi-devel openssl-devel
      ;;
  esac
}

py_dep_hash() {
  local hfiles=""
  for f in requirements.txt requirements-dev.txt pyproject.toml setup.cfg setup.py; do
    [ -f "$f" ] && hfiles="$hfiles $f"
  done
  if [ -z "$hfiles" ]; then
    echo "none"
    return 0
  fi
  sha256sum $hfiles 2>/dev/null | sha256sum | awk '{print $1}'
}

install_python_deps() {
  local prev_hash_file="$CACHE_DIR/py-deps.sha256"
  local current_hash
  current_hash="$(py_dep_hash)"

  if [ "$FORCE_PY_DEPS" = "1" ]; then
    log "FORCE_PY_DEPS=1 set; will reinstall Python dependencies."
  fi

  if [ "$current_hash" = "none" ]; then
    log "No Python dependency files found; attempting editable install if pyproject/setup present."
  fi

  if [ "$FORCE_PY_DEPS" = "1" ] || [ ! -f "$prev_hash_file" ] || [ "$(cat "$prev_hash_file")" != "$current_hash" ]; then
    log "Installing Python dependencies..."
    export PIP_NO_CACHE_DIR PIP_DISABLE_PIP_VERSION_CHECK
    python -m pip install -U pip setuptools wheel

    if [ -f "requirements.txt" ]; then
      detail "Installing from requirements.txt"
      python -m pip install -r requirements.txt
    fi
    if [ -f "requirements-dev.txt" ]; then
      detail "Installing from requirements-dev.txt (optional)"
      python -m pip install -r requirements-dev.txt || warn "Failed to install requirements-dev.txt; continuing."
    fi

    # If no requirements, try installing the project itself (PEP 517)
    if [ ! -f "requirements.txt" ] && [ -f "pyproject.toml" ]; then
      detail "Installing current project (pyproject.toml detected)"
      python -m pip install --no-build-isolation --editable .
    elif [ ! -f "requirements.txt" ] && [ -f "setup.py" ]; then
      detail "Installing current project (setup.py detected)"
      python -m pip install -e .
    fi

    printf "%s" "$current_hash" > "$prev_hash_file"
    log "Python dependencies installation complete."
  else
    log "Python dependencies are up-to-date. Skipping installation."
  fi
}

maybe_setup_spacy_model() {
  if [ "$SKIP_SPACY_MODEL" = "1" ]; then
    log "SKIP_SPACY_MODEL=1 set; skipping spaCy model installation."
    return 0
  fi
  if python - <<'PY' 2>/dev/null
import importlib.util
exit(0 if importlib.util.find_spec("spacy") is not None else 1)
PY
  then
    log "spaCy detected; ensuring language model is available: $SPACY_MODEL"
    # Install model only if not already available
    if python - <<PY 2>/dev/null; then
import importlib.util
import sys
m = importlib.util.find_spec("${SPACY_MODEL}")
sys.exit(0 if m is not None else 1)
PY
    then
      detail "spaCy model ${SPACY_MODEL} already installed."
    else
      python -m spacy download "$SPACY_MODEL" || warn "Failed to download spaCy model ${SPACY_MODEL}."
    fi
  else
    detail "spaCy not installed; skipping model setup."
  fi
}

#---------------------------
# Node.js setup (if needed)
#---------------------------
ensure_node_runtime() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "Node.js runtime detected: $(node -v), npm: $(npm -v)"
    return 0
  fi
  if [ ! -f "package.json" ]; then
    detail "No package.json found; Node.js not required."
    return 0
  fi
  if ! is_root; then
    warn "package.json found but not root; cannot install Node.js system-wide."
    return 0
  fi
  log "Installing Node.js runtime (distribution packages)..."
  case "$PKG_MANAGER" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
    *)
      warn "Unsupported package manager for Node.js installation."
      ;;
  esac
  if command -v node >/dev/null 2>&1; then
    log "Installed Node.js: $(node -v), npm: $(npm -v)"
  else
    warn "Node.js installation unsuccessful or not available."
  fi
}

install_node_deps() {
  [ -f "package.json" ] || return 0
  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not found; skipping Node dependency installation."
    return 0
  fi
  local prev_hash_file="$CACHE_DIR/node-deps.sha256"
  local current_hash
  if [ -f package-lock.json ]; then
    current_hash="$(sha256sum package.json package-lock.json | sha256sum | awk '{print $1}')"
  else
    current_hash="$(sha256sum package.json | awk '{print $1}')"
  fi

  if [ "$FORCE_NODE_DEPS" = "1" ] || [ ! -f "$prev_hash_file" ] || [ "$(cat "$prev_hash_file")" != "$current_hash" ]; then
    log "Installing Node dependencies..."
    if [ -f package-lock.json ]; then
      npm ci --no-audit --no-fund
    else
      npm install --no-audit --no-fund
    fi
    printf "%s" "$current_hash" > "$prev_hash_file"
    log "Node dependencies installation complete."
  else
    log "Node dependencies are up-to-date. Skipping installation."
  fi
}

#---------------------------
# Project structure & env
#---------------------------
setup_directories_permissions() {
  log "Setting up project directories and permissions..."
  mkdir -p "$PROJECT_ROOT/logs" "$PROJECT_ROOT/data" "$PROJECT_ROOT/tmp" "$CACHE_DIR"
  chmod 755 "$PROJECT_ROOT" "$PROJECT_ROOT/logs" "$PROJECT_ROOT/data" "$PROJECT_ROOT/tmp" || true
  # Virtualenv directory permissions
  [ -d "$PY_VENV_DIR" ] && chmod -R go-w "$PY_VENV_DIR" || true
  log "Directories set."
}

write_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    log "Creating default .env file."
    cat > "$ENV_FILE" <<EOF
# Generated by setup script
APP_ENV=${APP_ENV}
PYTHONUNBUFFERED=1
PIP_NO_CACHE_DIR=${PIP_NO_CACHE_DIR}
PIP_DISABLE_PIP_VERSION_CHECK=${PIP_DISABLE_PIP_VERSION_CHECK}
# SPAcy model to ensure installed if spaCy is present
SPACY_MODEL=${SPACY_MODEL}
EOF
    chmod 640 "$ENV_FILE" || true
  else
    detail ".env exists; not overwriting."
  fi
}

#---------------------------
# Project detection
#---------------------------
detect_project_types() {
  local has_python=0
  local has_node=0
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -d "src" ]; then
    has_python=1
  fi
  if [ -f "package.json" ]; then
    has_node=1
  fi
  echo "$has_python:$has_node"
}

#---------------------------
# Main
#---------------------------
main() {
  # Show banner on stdout
  exec 1>&3 2>&3
  echo "==============================================="
  echo " Project Environment Setup (Container-friendly) "
  echo " Log file: $LOG_FILE"
  echo "==============================================="
  exec 1>>"$LOG_FILE" 2>&1

  load_dotenv
  install_base_system_deps

  # Detect project stack
  IFS=":" read -r HAS_PY HAS_NODE < <(detect_project_types)

  if [ "$HAS_PY" = "1" ]; then
    ensure_python_runtime
    install_python_build_tools
    create_or_activate_venv
    install_python_deps
    maybe_setup_spacy_model
  else
    log "No Python project files detected."
  fi

  if [ "$HAS_NODE" = "1" ]; then
    ensure_node_runtime
    install_node_deps
  fi

  setup_directories_permissions
  write_env_file

  exec 1>&3 2>&3
  echo
  echo "Setup completed successfully."
  echo "- Project root: $PROJECT_ROOT"
  if [ "$HAS_PY" = "1" ]; then
    echo "- Python venv: $PY_VENV_DIR"
    echo "  To activate: source \"$PY_VENV_DIR/bin/activate\""
  fi
  if [ "$HAS_NODE" = "1" ]; then
    echo "- Node.js detected. Use npm/yarn as needed."
  fi
  echo
}

main "$@"