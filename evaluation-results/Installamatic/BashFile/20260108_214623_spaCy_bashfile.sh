#!/usr/bin/env bash
# Container-friendly project environment setup script
# Installs runtimes, system deps, project deps, and configures environment
# Safe to run multiple times (idempotent)

# POSIX-compatible prologue to ensure Bash and essential tools when invoked under /bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
  # Install and remap /bin/sh -> bash when root (distro-aware)
  /bin/sh -ceu 'if [ "$(id -u)" -eq 0 ]; then if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y --no-install-recommends bash dash debconf-utils ca-certificates; echo "dash dash/sh boolean false" | debconf-set-selections; dpkg-reconfigure -f noninteractive dash || true; if command -v update-alternatives >/dev/null 2>&1; then update-alternatives --install /bin/sh sh /bin/bash 110 || true; update-alternatives --set sh /bin/bash || true; fi; ln -sf /bin/bash /bin/sh || true; update-ca-certificates || true; elif command -v dnf >/dev/null 2>&1; then dnf -y makecache; dnf install -y bash ca-certificates; { command -v alternatives >/dev/null 2>&1 && alternatives --set sh /bin/bash || true; }; ln -sf /bin/bash /bin/sh || true; update-ca-trust || true; elif command -v yum >/dev/null 2>&1; then yum -y makecache; yum install -y bash ca-certificates; { command -v alternatives >/dev/null 2>&1 && alternatives --set sh /bin/bash || true; }; ln -sf /bin/bash /bin/sh || true; update-ca-trust || true; elif command -v apk >/dev/null 2>&1; then apk update; apk add --no-cache bash ca-certificates; ln -sf /bin/bash /bin/sh || true; update-ca-certificates || true; else echo "No supported package manager found to install bash" >&2; fi; fi' || true

  # Provide robust /usr/local/bin/sh wrapper and prefer it via alternatives when root
  /bin/sh -ceu 'if [ "$(id -u)" -eq 0 ]; then printf "#!/bin/bash\nexec /bin/bash \"$@\"\n" >/usr/local/bin/sh; chmod 0755 /usr/local/bin/sh; if command -v update-alternatives >/dev/null 2>&1; then update-alternatives --install /bin/sh sh /usr/local/bin/sh 120 || true; update-alternatives --set /bin/sh /usr/local/bin/sh || update-alternatives --set sh /usr/local/bin/sh || true; else ln -sf /usr/local/bin/sh /bin/sh || true; fi; fi' || true

  # Non-root (and root fallback): user-space static bash and sh shim with PATH precedence
  /bin/sh -ceu 'mkdir -p "$HOME/.local/bin"; BASH_URL="https://github.com/robxu9/bash-static/releases/download/5.2.15/bash-linux-x86_64"; if ! command -v bash >/dev/null 2>&1; then if command -v curl >/dev/null 2>&1; then curl -fsSL "$BASH_URL" -o "$HOME/.local/bin/bash"; elif command -v wget >/dev/null 2>&1; then wget -qO "$HOME/.local/bin/bash" "$BASH_URL"; fi; chmod 0755 "$HOME/.local/bin/bash" || true; fi; printf "#!/usr/bin/env bash\nexec bash \"$@\"\n" >"$HOME/.local/bin/sh"; chmod 0755 "$HOME/.local/bin/sh"; for rc in "$HOME/.profile" "$HOME/.bashrc"; do [ -f "$rc" ] || touch "$rc"; grep -qF "export PATH=$HOME/.local/bin:$PATH" "$rc" 2>/dev/null || printf "\nexport PATH=$HOME/.local/bin:$PATH\n" >> "$rc"; done' || true

  # Diagnostics
  /bin/sh -ceu 'printf "After repair, /bin/sh -> %s\n" "$(readlink -f /bin/sh 2>/dev/null || echo unknown)"; if command -v bash >/dev/null 2>&1; then echo "Bash: $(bash --version | head -n1)"; fi; if command -v sh >/dev/null 2>&1; then sh -c "echo Using sh at: \$(command -v sh)"; fi' || true

  # Re-exec this script under bash now that mapping is in place
  exec /bin/bash "$0" "$@"
fi

if [ -n "${BASH_VERSION:-}" ]; then
  set -Eeuo pipefail
else
  set -eu
fi

#---------------------------
# Globals and configuration
#---------------------------
PROJECT_ROOT="$(pwd)"
CACHE_DIR="$PROJECT_ROOT/.cache/setup"
LOG_FILE="$CACHE_DIR/setup.log"
ENV_FILE="$PROJECT_ROOT/.env"
# Ensure user-level installs (e.g., uv) are discoverable
export PATH="${HOME}/.local/bin:${PATH}"

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

show_setup_log() {
  if [ -f "$LOG_FILE" ]; then
    printf "%s\n" "===== $LOG_FILE =====" >&3
    tail -n +1 -v "$LOG_FILE" >&3 || true
  else
    printf "%s\n" "No setup log found." >&3
  fi
}

cleanup() {
  # Best-effort package manager cache cleanup
  if command -v apt-get >/dev/null 2>&1; then
    rm -rf /var/lib/apt/lists/* || true
  fi
}
on_error() {
  exit_code=$?
  # Restore stdout/stderr to console so orchestrators can capture failure output
  exec 1>&3 2>&3
  echo "[ERROR] Setup failed (exit code $exit_code). See log: $LOG_FILE"
  if [ -f "$LOG_FILE" ]; then
    echo "===== $LOG_FILE ====="
    tail -n +1 -v "$LOG_FILE" || true
  else
    echo "No setup log found."
  fi
  cleanup || true
  exit "$exit_code"
}
if [ -n "${BASH_VERSION:-}" ]; then trap on_error ERR; fi
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
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" > "$CACHE_DIR/.dotenv.filtered" || true
. "$CACHE_DIR/.dotenv.filtered"
rm -f "$CACHE_DIR/.dotenv.filtered"
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
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends "$@"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  else
    warn "No supported package manager found to install: $*"
    return 1
  fi
  return 0
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
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

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh -s -- -y
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://astral.sh/uv/install.sh | sh -s -- -y
  elif command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' | sh -s -- -y
import urllib.request,sys
sys.stdout.write(urllib.request.urlopen("https://astral.sh/uv/install.sh").read().decode())
PY
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget -qO- https://astral.sh/uv/install.sh | sh -s -- -y
  else
    warn "No downloader available (curl/wget/python3/busybox) to install uv."
    return 1
  fi
  # Ensure uv is discoverable in this session
  export PATH="${HOME}/.local/bin:${PATH}"
}
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
      warn "Python 3 not found; attempting user-space install with uv."
      if ensure_uv && uv python install 3.11; then
        log "Installed Python via uv. Will create venv using uv if needed."
        return 0
      else
        warn "Failed to install Python via uv; continuing without Python."
        return 0
      fi
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
        warn "Cannot install Python via system packages (unsupported package manager). Attempting user-space install with uv."
        if ensure_uv && uv python install 3.11; then
          log "Installed Python via uv. Will create venv using uv if needed."
          return 0
        else
          error "Failed to install Python via uv."
          exit 1
        fi
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
  pybin="$(find_python3 || true)"
  if [ -z "$pybin" ]; then
    warn "Python interpreter not found; skipping virtual environment creation."
    return 0
  fi
  if [ ! -d "$PY_VENV_DIR" ]; then
    log "Creating Python virtual environment at $PY_VENV_DIR"
    if command -v uv >/dev/null 2>&1; then
      uv venv "$PY_VENV_DIR" || "$pybin" -m venv "$PY_VENV_DIR"
    else
      "$pybin" -m venv "$PY_VENV_DIR"
    fi
  else
    log "Using existing virtual environment at $PY_VENV_DIR"
  fi
  if [ -f "$PY_VENV_DIR/bin/activate" ]; then
    # shellcheck disable=SC1090
    . "$PY_VENV_DIR/bin/activate"
    python -m pip install -U pip setuptools wheel
  else
    warn "Virtual environment activation script not found at $PY_VENV_DIR/bin/activate; skipping activation."
  fi

  # Update bashrc to auto-activate venv
  setup_auto_activate
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

  # Ensure we have an active Python environment
  if [ -f "$PY_VENV_DIR/bin/activate" ]; then
    # shellcheck disable=SC1090
    . "$PY_VENV_DIR/bin/activate"
  else
    detail "No venv to activate at $PY_VENV_DIR; skipping Python deps install."
    return 0
  fi

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
    # Install Node.js via nvm in user-space
    log "package.json found; attempting user-space Node.js install with nvm."
    export NVM_DIR="$HOME/.nvm"
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
      else
        warn "Neither curl nor wget available to install nvm."
        return 0
      fi
    fi
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh" || true
    if command -v nvm >/dev/null 2>&1; then
      nvm install --lts --no-progress || true
      if command -v node >/dev/null 2>&1; then
        log "Installed Node.js via nvm: $(node -v)"
      fi
    else
      warn "nvm installation failed; skipping Node.js runtime setup."
    fi
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
# Shell auto-activation for venv
#---------------------------
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local venv_activate="$PY_VENV_DIR/bin/activate"
  if [ -f "$venv_activate" ]; then
    mkdir -p "$(dirname "$bashrc_file")" 2>/dev/null || true
    touch "$bashrc_file"
    if ! grep -qF "$venv_activate" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "if [ -f \"$venv_activate\" ]; then . \"$venv_activate\"; fi" >> "$bashrc_file"
    fi
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
  [ -f .cache/setup/setup.log ] && { echo "===== .cache/setup/setup.log ====="; tail -n +1 -v .cache/setup/setup.log; } || true
  mkdir -p .cache/setup logs data tmp && chmod 755 . logs data tmp || true
  mkdir -p "$HOME/.local/bin" && for rc in "$HOME/.bashrc" "$HOME/.profile"; do [ -f "$rc" ] || touch "$rc"; grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$rc" 2>/dev/null || printf '\n# Ensure user-local bin in PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"; done && export PATH="$HOME/.local/bin:$PATH"
  exec 1>>"$LOG_FILE" 2>&1

  load_dotenv
  install_base_system_deps

  # Preflight: remap /bin/sh to bash (distro-aware) and provision user-space bash; verify
  sh -c 'set -eu; if [ "$(id -u)" -eq 0 ]; then if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y --no-install-recommends bash debconf-utils ca-certificates; echo "dash dash/sh boolean false" | debconf-set-selections; dpkg-reconfigure -f noninteractive dash || true; if command -v update-alternatives >/dev/null 2>&1; then update-alternatives --install /bin/sh sh /bin/bash 110 || true; update-alternatives --set sh /bin/bash || true; fi; ln -sf /bin/bash /bin/sh || true; update-ca-certificates || true; elif command -v dnf >/dev/null 2>&1; then dnf -y makecache; dnf install -y bash ca-certificates; { command -v alternatives >/dev/null 2>&1 && alternatives --set sh /bin/bash || true; }; ln -sf /bin/bash /bin/sh || true; update-ca-trust || true; elif command -v yum >/dev/null 2>&1; then yum -y makecache; yum install -y bash ca-certificates; { command -v alternatives >/dev/null 2>&1 && alternatives --set sh /bin/bash || true; }; ln -sf /bin/bash /bin/sh || true; update-ca-trust || true; elif command -v apk >/dev/null 2>&1; then apk update; apk add --no-cache bash ca-certificates; ln -sf /bin/bash /bin/sh || true; update-ca-certificates || true; else echo "No supported package manager found"; fi; else echo "Non-root: cannot remap /bin/sh to bash"; fi; printf "Now /bin/sh -> %s\n" "$(readlink -f /bin/sh 2>/dev/null || echo unknown)"; command -v bash >/dev/null 2>&1 && bash -lc "echo Bash: $(bash --version | head -n1)" || true'
  sh -c 'set -eu; mkdir -p "$HOME/.local/bin"; if [ ! -x "$HOME/.local/bin/bash" ]; then if command -v curl >/dev/null 2>&1; then curl -fsSL https://github.com/robxu9/bash-static/releases/download/5.2.15/bash-linux-x86_64 -o "$HOME/.local/bin/bash"; elif command -v wget >/dev/null 2>&1; then wget -qO "$HOME/.local/bin/bash" https://github.com/robxu9/bash-static/releases/download/5.2.15/bash-linux-x86_64; fi; chmod 0755 "$HOME/.local/bin/bash" || true; fi; printf "#!/usr/bin/env bash\nexec bash \"$@\"\n" > "$HOME/.local/bin/sh"; chmod 0755 "$HOME/.local/bin/sh"; for rc in "$HOME/.profile" "$HOME/.bashrc"; do [ -f "$rc" ] || touch "$rc"; grep -qF "export PATH=\"$HOME/.local/bin:$PATH\"" "$rc" 2>/dev/null || printf "\nexport PATH=\"$HOME/.local/bin:$PATH\"\n" >> "$rc"; done; export PATH="$HOME/.local/bin:$PATH"; "$HOME/.local/bin/bash" -lc "echo User bash ready: $(bash --version | head -n1)" || true'
  sh -c 'set -eu; if [ "$(id -u)" -eq 0 ]; then printf "#!/bin/bash\nexec /bin/bash \"$@\"\n" > /usr/local/bin/sh; chmod 0755 /usr/local/bin/sh; if command -v update-alternatives >/dev/null 2>&1; then update-alternatives --install /bin/sh sh /usr/local/bin/sh 120 || true; update-alternatives --set sh /usr/local/bin/sh || true; else ln -sf /usr/local/bin/sh /bin/sh || true; fi; fi; printf "Verified /bin/sh -> %s\n" "$(readlink -f /bin/sh 2>/dev/null || echo unknown)"'
  export PATH="$HOME/.local/bin:$PATH"; command -v uv >/dev/null 2>&1 || { if command -v curl >/dev/null 2>&1; then curl -LsSf https://astral.sh/uv/install.sh | sh -s -- -y; elif command -v wget >/dev/null 2>&1; then wget -qO- https://astral.sh/uv/install.sh | sh -s -- -y; elif command -v python3 >/dev/null 2>&1; then python3 - <<'PY' | sh -s -- -y
import urllib.request,sys
sys.stdout.write(urllib.request.urlopen("https://astral.sh/uv/install.sh").read().decode())
PY
elif command -v busybox >/dev/null 2>&1; then busybox wget -qO- https://astral.sh/uv/install.sh | sh -s -- -y; fi; }; export PATH="$HOME/.local/bin:$PATH"; VENV_DIR="${PY_VENV_DIR:-$PWD/.venv}"; if command -v uv >/dev/null 2>&1; then uv python install 3.11 || true; uv venv "$VENV_DIR" || true; elif command -v python3 >/dev/null 2>&1; then python3 -m venv "$VENV_DIR" || true; fi; [ -x "$VENV_DIR/bin/python" ] && "$VENV_DIR/bin/python" -m pip install -U pip setuptools wheel || true
if [ -x "${PY_VENV_DIR:-$PWD/.venv}/bin/python" ]; then PYBIN="${PY_VENV_DIR:-$PWD/.venv}/bin/python"; if [ -f requirements.txt ]; then if command -v uv >/dev/null 2>&1; then uv pip install -p "$PYBIN" -r requirements.txt; else "$PYBIN" -m pip install -r requirements.txt; fi; fi; if [ -f requirements-dev.txt ]; then if command -v uv >/dev/null 2>&1; then uv pip install -p "$PYBIN" -r requirements-dev.txt || true; else "$PYBIN" -m pip install -r requirements-dev.txt || true; fi; fi; if [ ! -f requirements.txt ] && [ -f pyproject.toml ]; then if command -v uv >/dev/null 2>&1; then uv pip install -p "$PYBIN" --no-build-isolation --editable .; else "$PYBIN" -m pip install --no-build-isolation --editable .; fi; elif [ ! -f requirements.txt ] && [ -f setup.py ]; then if command -v uv >/dev/null 2>&1; then uv pip install -p "$PYBIN" -e .; else "$PYBIN" -m pip install -e .; fi; fi; fi
  if [ "${SKIP_SPACY_MODEL:-0}" != "1" ] && [ -f "${PY_VENV_DIR:-$PWD/.venv}/bin/python" ]; then SPACY_MODEL="${SPACY_MODEL:-en_core_web_sm}"; if "${PY_VENV_DIR:-$PWD/.venv}/bin/python" -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('spacy') else 1)" 2>/dev/null; then if ! "${PY_VENV_DIR:-$PWD/.venv}/bin/python" -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('${SPACY_MODEL}') else 1)" 2>/dev/null; then "${PY_VENV_DIR:-$PWD/.venv}/bin/python" -m spacy download "${SPACY_MODEL}" || true; fi; fi; fi
  if [ -f package.json ] && ! command -v npm >/dev/null 2>&1; then export NVM_DIR="$HOME/.nvm"; mkdir -p "$NVM_DIR"; if [ ! -s "$NVM_DIR/nvm.sh" ]; then if command -v curl >/dev/null 2>&1; then curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash; elif command -v wget >/dev/null 2>&1; then wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash; elif command -v python3 >/dev/null 2>&1; then python3 - <<'PY' | bash
import urllib.request,sys
sys.stdout.write(urllib.request.urlopen("https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh").read().decode())
PY
elif command -v busybox >/dev/null 2>&1; then busybox wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash; else echo "Unable to install nvm (no downloader)"; fi; fi; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; command -v nvm >/dev/null 2>&1 && nvm install --lts --no-progress || true; fi
  if [ -f package.json ]; then if command -v npm >/dev/null 2>&1; then if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi; else export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] || { if command -v curl >/dev/null 2>&1; then curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash; elif command -v wget >/dev/null 2>&1; then wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash; fi; }; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm install --lts --no-progress && npm --version >/dev/null 2>&1 && { if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi; }; fi; fi
  VENV_ACT="${PY_VENV_DIR:-$PWD/.venv}/bin/activate"; if [ -f "$VENV_ACT" ]; then BRC="$HOME/.bashrc"; mkdir -p "$(dirname "$BRC")" 2>/dev/null || true; touch "$BRC"; grep -qF "$VENV_ACT" "$BRC" 2>/dev/null || printf '\n# Auto-activate Python virtual environment\nif [ -f "%s" ]; then . "%s"; fi\n' "$VENV_ACT" "$VENV_ACT" >> "$BRC"; fi

  # Detect project stack
  OLD_IFS=$IFS; IFS=:
  set -- $(detect_project_types)
  IFS=$OLD_IFS
  HAS_PY="${1:-0}"
  HAS_NODE="${2:-0}"

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
  setup_auto_activate

  exec 1>&3 2>&3
  [ -f .cache/setup/setup.log ] && { echo "===== .cache/setup/setup.log ====="; tail -n +1 -v .cache/setup/setup.log; } || true
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