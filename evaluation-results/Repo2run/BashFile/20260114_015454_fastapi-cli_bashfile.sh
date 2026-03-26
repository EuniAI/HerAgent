#!/usr/bin/env bash
# FastAPI CLI project environment setup script for Docker containers
# - Installs system packages and Python runtime
# - Creates and configures an isolated Python virtual environment
# - Installs project and optional test/dev dependencies
# - Sets environment variables and permissions
# - Idempotent and safe to run multiple times

set -Eeuo pipefail

# Safer IFS
IFS=$'\n\t'
umask 022

#-----------------------------
# Logging and error handling
#-----------------------------
LOG_TS() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "[INFO $(LOG_TS)] $*"; }
warn() { echo "[WARN $(LOG_TS)] $*" >&2; }
err() { echo "[ERROR $(LOG_TS)] $*" >&2; }
abort() { err "$*"; exit 1; }
on_error() {
  local exit_code=$?
  err "Setup failed (exit code ${exit_code}). See logs above."
  exit "$exit_code"
}
trap on_error ERR

#-----------------------------
# Configuration (overridable via env)
#-----------------------------
: "${APP_HOME:="$(pwd)"}"
: "${VENV_PATH:="/opt/venv"}"
: "${INSTALL_TEST_DEPS:="false"}"           # set to "true" to install requirements-tests.txt
: "${PIP_INDEX_URL:=""}"                    # optional custom index
: "${PIP_EXTRA_INDEX_URL:=""}"              # optional extra index
: "${APP_UID:="${UID:-0}"}"                 # target owner UID for files/dirs
: "${APP_GID:="${GID:-0}"}"                 # target owner GID for files/dirs

# Environment defaults for Python/apps inside the container
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1

#-----------------------------
# Helpers
#-----------------------------
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pm=""

detect_package_manager() {
  if have_cmd apt-get; then pm="apt"
  elif have_cmd apk; then pm="apk"
  elif have_cmd dnf; then pm="dnf"
  elif have_cmd microdnf; then pm="microdnf"
  elif have_cmd yum; then pm="yum"
  else pm=""; fi
}

python_version_ok() {
  if ! have_cmd python3; then return 1; fi
  python3 - <<'PY' || exit 1
import sys
major, minor = sys.version_info[:2]
# Project requires Python >= 3.8
raise SystemExit(0 if (major > 3 or (major == 3 and minor >= 8)) else 1)
PY
}

ensure_symlinks() {
  # Ensure `python` and `pip` resolve to python3/pip3 inside venv or system if needed
  if have_cmd python3 && ! have_cmd python; then
    ln -sf "$(command -v python3)" /usr/local/bin/python || true
  fi
  if have_cmd pip3 && ! have_cmd pip; then
    ln -sf "$(command -v pip3)" /usr/local/bin/pip || true
  fi
}

#-----------------------------
# System package installation
#-----------------------------
install_system_packages() {
  detect_package_manager

  if [[ -z "$pm" ]]; then
    warn "No supported package manager detected; skipping system package installation."
    return 0
  fi

  if ! is_root; then
    warn "Not running as root; cannot install system packages. Skipping."
    return 0
  fi

  log "Installing system packages using ${pm}..."

  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # Core tools and build essentials for common Python deps (uvicorn[standard] et al)
      apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        python3 python3-venv python3-dev python3-pip \
        build-essential pkg-config libffi-dev libssl-dev
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      apk update
      apk add --no-cache \
        ca-certificates curl git \
        python3 py3-pip python3-dev \
        build-base pkgconfig libffi-dev openssl-dev
      update-ca-certificates || true
      ;;
    dnf)
      dnf -y install \
        ca-certificates curl git \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconfig libffi-devel openssl-devel
      dnf clean all
      ;;
    microdnf)
      microdnf -y install \
        ca-certificates curl git \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconfig libffi-devel openssl-devel
      microdnf clean all
      ;;
    yum)
      yum -y install \
        ca-certificates curl git \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconfig libffi-devel openssl-devel
      yum clean all
      ;;
    *)
      warn "Package manager ${pm} not explicitly supported; skipping system packages."
      ;;
  esac

  ensure_symlinks
}

#-----------------------------
# Python and venv setup
#-----------------------------
ensure_python() {
  if python_version_ok; then
    log "Python $(python3 -V 2>/dev/null | awk '{print $2}') detected and meets version requirements (>=3.8)"
    return 0
  fi

  log "Python 3.8+ not found or too old. Attempting to install via system package manager."
  install_system_packages

  if ! python_version_ok; then
    abort "Python 3.8+ is required but not available after installation."
  fi
}

create_or_update_venv() {
  mkdir -p "$(dirname "$VENV_PATH")"
  if [[ -d "$VENV_PATH" && -x "$VENV_PATH/bin/python" ]]; then
    log "Using existing virtual environment at $VENV_PATH"
  else
    log "Creating virtual environment at $VENV_PATH"
    python3 -m venv "$VENV_PATH"
  fi

  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"

  # Upgrade pip/setuptools/wheel to modern versions for PEP 517/660 support
  python -m pip install --upgrade pip setuptools wheel
  log "Virtual environment ready at $VENV_PATH"
}

#-----------------------------
# Dependency installation
#-----------------------------
pip_common_args=()
add_pip_index_args() {
  if [[ -n "${PIP_INDEX_URL}" ]]; then
    pip_common_args+=( "--index-url" "${PIP_INDEX_URL}" )
  fi
  if [[ -n "${PIP_EXTRA_INDEX_URL}" ]]; then
    pip_common_args+=( "--extra-index-url" "${PIP_EXTRA_INDEX_URL}" )
  fi
}

install_dependencies() {
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"

  add_pip_index_args

  if [[ -f "${APP_HOME}/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    python -m pip install "${pip_common_args[@]}" -r "${APP_HOME}/requirements.txt"
  elif [[ -f "${APP_HOME}/pyproject.toml" ]]; then
    log "requirements.txt not found. Installing project in editable mode from pyproject.toml"
    python -m pip install "${pip_common_args[@]}" -e "${APP_HOME}"
  else
    warn "No requirements.txt or pyproject.toml found. Skipping project dependency installation."
  fi

  if [[ "${INSTALL_TEST_DEPS}" == "true" && -f "${APP_HOME}/requirements-tests.txt" ]]; then
    log "Installing test/development dependencies from requirements-tests.txt"
    python -m pip install "${pip_common_args[@]}" -r "${APP_HOME}/requirements-tests.txt"
  fi
}

#-----------------------------
# Environment configuration
#-----------------------------
write_profiled_env() {
  # Make virtualenv binaries available by default for interactive shells
  local profiled="/etc/profile.d/fastapi_cli_env.sh"
  if is_root; then
    cat > "${profiled}.tmp" <<EOF
# Auto-generated by setup script: environment for FastAPI CLI project
export VIRTUAL_ENV="${VENV_PATH}"
export PATH="\${VIRTUAL_ENV}/bin:\${PATH}"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
# Respect custom index settings if provided at build/run time
${PIP_INDEX_URL:+export PIP_INDEX_URL="${PIP_INDEX_URL}"}
${PIP_EXTRA_INDEX_URL:+export PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL}"}
EOF
    mv -f "${profiled}.tmp" "${profiled}"
    chmod 0644 "${profiled}"
    log "Wrote environment profile to ${profiled}"
  else
    warn "Not root; cannot write /etc/profile.d. Skipping system-wide environment export."
  fi
}

#-----------------------------
# Permissions
#-----------------------------
set_permissions() {
  # Ensure project directory exists
  mkdir -p "${APP_HOME}"

  # Adjust ownership if requested and running as root
  if is_root; then
    if [[ -n "${APP_UID}" && -n "${APP_GID}" ]]; then
      # chown only if user/group are numeric to avoid resolution issues
      if [[ "${APP_UID}" =~ ^[0-9]+$ && "${APP_GID}" =~ ^[0-9]+$ ]]; then
        chown -R "${APP_UID}:${APP_GID}" "${APP_HOME}" "${VENV_PATH}" 2>/dev/null || true
      fi
    fi
  else
    warn "Not root; skipping ownership adjustments."
  fi

  # Set safe permissions
  chmod -R go-w "${APP_HOME}" || true
}

#-----------------------------
# Verification
#-----------------------------
verify_setup() {
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"

  python -c "import sys; print('Python', sys.version)" || abort "Python not working in venv"
  if python -c "import fastapi_cli, sys; print('fastapi-cli version:', getattr(fastapi_cli, '__version__', 'unknown'))" 2>/dev/null; then
    log "fastapi-cli package import verified."
  else
    warn "fastapi-cli import not verified (this may be normal if the project isn't installed yet)."
  fi

  if have_cmd fastapi; then
    fastapi --version || true
  else
    warn "'fastapi' CLI entry point not found in PATH. If this is unexpected, ensure the package is installed."
  fi
}

#-----------------------------
# Main
#-----------------------------
main() {
  log "Starting environment setup for FastAPI CLI project"
  log "APP_HOME=${APP_HOME}"
  log "VENV_PATH=${VENV_PATH}"
  log "INSTALL_TEST_DEPS=${INSTALL_TEST_DEPS}"

  install_system_packages
  ensure_python
  create_or_update_venv
  install_dependencies
  write_profiled_env
  set_permissions
  verify_setup

  log "Environment setup completed successfully."
  cat <<'USAGE'

Quick usage:
- Activate the virtual environment (if not auto-activated in your shell):
    source /opt/venv/bin/activate

- Verify the CLI:
    fastapi --help

- If you installed test deps:
    pytest -q

Environment variables you can override:
- APP_HOME: project root (default: current directory)
- VENV_PATH: virtualenv path (default: /opt/venv)
- INSTALL_TEST_DEPS: set to "true" to install requirements-tests.txt
- APP_UID / APP_GID: set file ownership (useful when running as a non-root user later)
- PIP_INDEX_URL / PIP_EXTRA_INDEX_URL: custom package indexes

USAGE
}

main "$@"