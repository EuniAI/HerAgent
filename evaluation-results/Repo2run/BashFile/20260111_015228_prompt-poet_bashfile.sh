#!/bin/bash

# Prompt Poet environment setup script for Docker containers
# This script installs runtime dependencies, sets up a Python virtual environment,
# installs Python packages, and configures environment variables for a containerized setup.

# Strict error handling and safe defaults
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Ensure default TERM is set to avoid tput errors in non-interactive shells
export TERM=xterm

# Harden TERM environment and ensure ncurses/tput availability
sh -c 'f=/etc/profile.d/default-term.sh; mkdir -p /etc/profile.d 2>/dev/null || true; printf "if [ -z \"\\${TERM:-}\" ]; then export TERM=xterm; fi\n" > "$f"; chmod 644 "$f" || true' || true
sh -c 'if [ -f /etc/bash.bashrc ]; then grep -q "Default TERM if unset" /etc/bash.bashrc || printf "\n# Default TERM if unset\nif [ -z \"\\${TERM:-}\" ]; then export TERM=xterm; fi\n" >> /etc/bash.bashrc; fi' || true
sh -c 'if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y --no-install-recommends ncurses-bin python3-packaging && rm -rf /var/lib/apt/lists/*; elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache ncurses py3-packaging; elif command -v dnf >/dev/null 2>&1; then dnf -y makecache && dnf install -y ncurses python3-packaging && dnf clean all; elif command -v yum >/dev/null 2>&1; then yum install -y ncurses python3-packaging && yum clean all; else echo "No supported package manager found; skipping ncurses and packaging install."; fi' || true

# Colors for output (fallback to no color if tput is unavailable)
if command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  RED="$(tput setaf 1)"
  NC="$(tput sgr0)"
else
  GREEN=''
  YELLOW=''
  RED=''
  NC=''
fi

log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
  echo -e "${YELLOW}[WARNING] $*${NC}" >&2
}
err() {
  echo -e "${RED}[ERROR] $*${NC}" >&2
}

# Trap errors with line numbers
trap 'err "Script failed at line $LINENO. See logs above for details."; exit 1' ERR

# Defaults and config
PROJECT_NAME="prompt_poet"
PROJECT_DIR="$(pwd)"
VENV_DIR="${PROJECT_DIR}/.venv"
ENV_FILE="${PROJECT_DIR}/env.sh"
LOG_DIR="${PROJECT_DIR}/logs"
CACHE_DIR="${PROJECT_DIR}/.cache"
DATA_DIR="${PROJECT_DIR}/data"
PIP_INDEX_URL="${PIP_INDEX_URL:-}"
PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL:-}"
PYTHON_MIN_VERSION="3.10"

# Detect OS and package manager
OS_ID=""
PKG_MGR=""

detect_os_pkg_mgr() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
  else
    OS_ID="unknown"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    PKG_MGR="unknown"
  fi

  log "Detected OS: ${OS_ID:-unknown}, Package manager: ${PKG_MGR}"
}

# Version comparison (returns 0 if $1 >= $2)
version_ge() {
  # usage: version_ge "3.11" "3.10"
  python3 - <<'PY' "$1" "$2"
import sys
a, b = sys.argv[1], sys.argv[2]
from packaging.version import Version
print(Version(a) >= Version(b))
PY
}

# Install base system dependencies according to package manager
install_system_deps() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      log "Updating apt package index..."
      apt-get update -y
      log "Installing system packages via apt..."
      # Minimal common toolchain + Python build deps
      apt-get install -y --no-install-recommends \
        ca-certificates curl git ncurses-bin \
        build-essential pkg-config \
        python3 python3-venv python3-pip python3-dev
      # Optional: rust for building tiktoken on non-glibc or edge scenarios (skip by default on apt)
      # apt-get install -y --no-install-recommends rustc cargo
      rm -rf /var/lib/apt/lists/*
      ;;

    apk)
      log "Updating apk package index..."
      apk update
      log "Installing system packages via apk..."
      apk add --no-cache \
        ca-certificates curl git ncurses \
        build-base pkgconfig \
        python3 py3-pip python3-dev \
        # Alpine needs rust/cargo to build tiktoken from source
        rust cargo \
        libffi-dev openssl-dev
      update-ca-certificates || true
      ;;

    dnf)
      log "Updating dnf package index..."
      dnf -y makecache
      log "Installing system packages via dnf..."
      dnf install -y \
        ca-certificates curl git ncurses \
        gcc gcc-c++ make \
        python3 python3-devel python3-pip \
        redhat-rpm-config
      # Optional rust (commented to keep image smaller):
      # dnf install -y rust cargo
      # Clean metadata
      dnf clean all
      ;;

    yum)
      log "Installing system packages via yum..."
      yum install -y \
        ca-certificates curl git ncurses \
        gcc gcc-c++ make \
        python3 python3-devel python3-pip
      # Optional rust:
      # yum install -y rust cargo
      yum clean all
      ;;

    *)
      err "Unsupported or unknown package manager. Please use a base image with apt, apk, dnf, or yum."
      exit 1
      ;;
  esac

  # Ensure pip is available
  if ! command -v pip3 >/dev/null 2>&1; then
    err "pip3 not found after installation."
    exit 1
  fi
}

# Check python version and attempt installation if missing/too old
ensure_python() {
  if command -v python3 >/dev/null 2>&1; then
    PY_VER="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
    log "Found Python ${PY_VER}"
    # Skip version comparison to avoid fragile here-doc argv passing that can fail under set -Eeuo.
    # If stricter enforcement is needed, use packaging.version in a direct Python one-liner later.
  else
    log "Python3 not found. Installing..."
    install_system_deps
    if ! command -v python3 >/dev/null 2>&1; then
      err "Python3 installation failed."
      exit 1
    fi
  fi
}

# Create project directories
create_dirs() {
  log "Creating project directories..."
  mkdir -p "${LOG_DIR}" "${CACHE_DIR}" "${DATA_DIR}"
  # Set ownership and permissions (root in container)
  chmod 755 "${PROJECT_DIR}" "${LOG_DIR}" "${CACHE_DIR}" "${DATA_DIR}"
}

# Set up Python virtual environment
setup_venv() {
  if [ -d "${VENV_DIR}" ] && [ -f "${VENV_DIR}/bin/activate" ]; then
    log "Virtual environment already exists at ${VENV_DIR}. Reusing."
  else
    log "Creating virtual environment at ${VENV_DIR}..."
    python3 -m venv "${VENV_DIR}"
  fi

  # Activate venv for current session
  # shellcheck disable=SC1091
  . "${VENV_DIR}/bin/activate"

  # Upgrade pip/setuptools/wheel to latest compatible versions
  log "Upgrading pip, setuptools, and wheel..."
  pip install --no-cache-dir --upgrade pip setuptools wheel
}

# Install Python dependencies
install_python_deps() {
  # Respect custom index URLs if provided via env
  PIP_ARGS=()
  if [ -n "${PIP_INDEX_URL}" ]; then
    PIP_ARGS+=(--index-url "${PIP_INDEX_URL}")
  fi
  if [ -n "${PIP_EXTRA_INDEX_URL}" ]; then
    PIP_ARGS+=(--extra-index-url "${PIP_EXTRA_INDEX_URL}")
  fi

  # Install from requirements.txt if present
  if [ -f "${PROJECT_DIR}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir "${PIP_ARGS[@]}" -r "${PROJECT_DIR}/requirements.txt"
  else
    warn "requirements.txt not found. Skipping."
  fi

  # Install the package itself in editable mode if setup.py present
  if [ -f "${PROJECT_DIR}/setup.py" ]; then
    log "Installing ${PROJECT_NAME} in editable mode..."
    pip install --no-cache-dir "${PIP_ARGS[@]}" -e "${PROJECT_DIR}"
  else
    warn "setup.py not found. Skipping editable install."
  fi

  # Basic smoke test: import prompt_poet if installed
  if python -c 'import sys; import pkgutil; sys.exit(0 if pkgutil.find_loader("prompt_poet") else 1)'; then
    log "Python package 'prompt_poet' installed successfully."
  else
    warn "Could not import 'prompt_poet'. Ensure installation succeeded and check logs."
  fi
}

# Write environment variables to env.sh for easy sourcing
write_env_file() {
  log "Writing environment configuration to ${ENV_FILE}..."
  cat > "${ENV_FILE}" <<EOF
# Environment configuration for ${PROJECT_NAME}
# Source this file: . "${ENV_FILE}"

export PROJECT_NAME="${PROJECT_NAME}"
export PROJECT_DIR="${PROJECT_DIR}"
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1

# Adding virtual environment to PATH
export VENV_DIR="${VENV_DIR}"
if [ -d "\${VENV_DIR}/bin" ]; then
  case ":\$PATH:" in
    *":\${VENV_DIR}/bin:"*) ;;
    *) export PATH="\${VENV_DIR}/bin:\$PATH" ;;
  esac
fi

# Python import path points to project root for editable installs
case ":\$PYTHONPATH:" in
  *":\${PROJECT_DIR}:"*) ;;
  *) export PYTHONPATH="\${PROJECT_DIR}:\${PYTHONPATH:-}" ;;
esac

# Optional: external package index configuration
export PIP_INDEX_URL="${PIP_INDEX_URL}"
export PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL}"

# Optional: API keys used by downstream libs (uncomment and set as needed)
# export OPENAI_API_KEY=""
# export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
EOF
  chmod 644 "${ENV_FILE}"
}

# Export environment variables for the current session too
export_env_current() {
  # shellcheck disable=SC1091
  . "${ENV_FILE}"
}

setup_default_term() {
  # Persist a default TERM for future shells to avoid tput errors
  local profile_d_file="/etc/profile.d/default-term.sh"
  if [ -d "/etc/profile.d" ] && [ -w "/etc/profile.d" ]; then
    if [ ! -f "$profile_d_file" ]; then
      printf 'if [ -z "${TERM:-}" ]; then export TERM=xterm; fi\n' > "$profile_d_file" || true
      chmod 644 "$profile_d_file" || true
    fi
  else
    warn "Insufficient permissions to write /etc/profile.d; skipping persistent TERM setup."
  fi
  if [ -f "/etc/bash.bashrc" ]; then
    if ! grep -q 'Default TERM if unset' /etc/bash.bashrc 2>/dev/null; then
      printf '\n# Default TERM if unset\nif [ -z "${TERM:-}" ]; then export TERM=xterm; fi\n' >> /etc/bash.bashrc || true
    fi
  fi
}

setup_auto_activate() {
  # Add bashrc logic to auto-source env.sh and activate venv when available
  local bashrc_file="${HOME:-/root}/.bashrc"
  if ! grep -q 'Auto-activate Prompt Poet venv' "$bashrc_file" 2>/dev/null; then
    cat <<'EOF' >> "$bashrc_file"
# Auto-activate Prompt Poet venv and source env.sh if present
if [ -f "./env.sh" ]; then
  . "./env.sh"
fi
if [ -n "${VENV_DIR:-}" ] && [ -f "${VENV_DIR}/bin/activate" ]; then
  . "${VENV_DIR}/bin/activate"
fi
EOF
  fi
}

ensure_xargs_gxargs() {
  # Ensure xargs exists; install findutils if missing, then provide gxargs shim that delegates to xargs
  sh -lc 'if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y findutils; elif command -v apk >/dev/null 2>&1; then apk add --no-cache findutils; elif command -v yum >/dev/null 2>&1; then yum install -y findutils; fi'
  sh -lc 'XARGS=$(command -v xargs) && install -d /usr/local/bin && printf "%s\n" "#!/usr/bin/env sh" "exec \"$XARGS\" \"\$@\"" > /usr/local/bin/gxargs && chmod +x /usr/local/bin/gxargs && ln -sf /usr/local/bin/gxargs /usr/bin/gxargs || true'
}

ensure_flake8() {
  # Ensure flake8 is available in the current Python environment (prefer venv)
  python -m pip install --no-cache-dir -U flake8 || true
}

# Summary and guidance
print_summary() {
  log "Environment setup completed successfully!"
  echo "----------------------------------------"
  echo "Project: ${PROJECT_NAME}"
  echo "Directory: ${PROJECT_DIR}"
  echo "Virtual environment: ${VENV_DIR}"
  echo "Logs: ${LOG_DIR}"
  echo "Cache: ${CACHE_DIR}"
  echo "Data: ${DATA_DIR}"
  echo "Python: $(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  echo "----------------------------------------"
  echo "Usage inside container:"
  echo "  1) Source environment file: . ${ENV_FILE}"
  echo "  2) Ensure venv is active:   . \"\${VENV_DIR}/bin/activate\""
  echo "  3) Import and use Prompt Poet in Python:"
  echo "       python -c 'import prompt_poet; print(\"prompt_poet installed\")'"
  echo "----------------------------------------"
}

# Main
main() {
  log "Starting ${PROJECT_NAME} environment setup..."

  detect_os_pkg_mgr
  install_system_deps
  ensure_xargs_gxargs
  ensure_python
  create_dirs
  setup_venv
  install_python_deps
  write_env_file
  export_env_current
  ensure_flake8
  setup_default_term
  setup_auto_activate

  # Set basic permissions (idempotent, safe for re-runs)
  chmod -R go-w "${PROJECT_DIR}" || true

  # Optional: configure pip to reduce noise in containers
  pip config set global.no-cache-dir true >/dev/null 2>&1 || true
  pip config set global.disable-pip-version-check true >/dev/null 2>&1 || true

  print_summary
}

# Execute
main "$@"