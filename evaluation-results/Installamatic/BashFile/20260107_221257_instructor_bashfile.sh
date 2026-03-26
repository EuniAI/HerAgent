#!/usr/bin/env bash
# Environment setup script for the Instructor (Python) project.
# Designed to run inside Docker containers and be idempotent.

set -Eeuo pipefail
IFS=$'\n\t'

#---------------------------#
# Logging & error handling  #
#---------------------------#
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

on_error() {
  local exit_code=$?
  err "Setup failed with exit code ${exit_code}"
  exit "${exit_code}"
}
trap on_error ERR

#---------------------------#
# Configurable defaults     #
#---------------------------#
APP_HOME="${APP_HOME:-/app}"                       # Project root inside container
VENV_PATH="${VENV_PATH:-${APP_HOME}/.venv}"       # In-project venv
PYTHON_BIN="${PYTHON_BIN:-python3}"               # Python executable
PIP_BIN="${PIP_BIN:-pip}"                         # pip within venv (resolved after activate)
INSTALL_DEV_DEPS="${INSTALL_DEV_DEPS:-false}"     # Optionally install dev tools
INSTRUCTOR_EXTRAS="${INSTRUCTOR_EXTRAS:-}"        # e.g. "anthropic,groq,cohere"
PRE_COMMIT_INSTALL="${PRE_COMMIT_INSTALL:-false}" # Install git hooks if config exists
NO_SYSTEM_CHANGES="${NO_SYSTEM_CHANGES:-false}"   # Set true if container is non-root
DEBIAN_FRONTEND=noninteractive                     # Quiet apt in non-interactive env

# Pip behavior in containers
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export PYTHONUNBUFFERED=1
export UV_NO_CACHE=1 || true

#---------------------------#
# Helpers                   #
#---------------------------#
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
  if has_cmd apt-get; then echo "apt"; return 0; fi
  if has_cmd apk; then echo "apk"; return 0; fi
  if has_cmd dnf; then echo "dnf"; return 0; fi
  if has_cmd yum; then echo "yum"; return 0; fi
  echo "none"
}

install_system_packages() {
  local pmgr
  pmgr="$(detect_pkg_manager)"

  if ! is_root || [ "${NO_SYSTEM_CHANGES}" = "true" ]; then
    warn "Skipping system package installation (not root or NO_SYSTEM_CHANGES=true)."
    return 0
  fi

  case "${pmgr}" in
    apt)
      log "Installing system packages with apt..."
      apt-get update -y
      # Core build/deps for Python and common libs used in this project
      apt-get install -y --no-install-recommends \
        ca-certificates curl git tzdata \
        python3 python3-venv python3-pip python3-dev \
        build-essential pkg-config libffi-dev libssl-dev
      # Clean up
      rm -rf /var/lib/apt/lists/*;;
    apk)
      log "Installing system packages with apk..."
      apk update
      apk add --no-cache \
        ca-certificates curl git tzdata \
        python3 py3-pip python3-dev \
        build-base pkgconfig libffi-dev openssl-dev
      # Ensure python3 -m venv is available
      if ! python3 -m venv --help >/dev/null 2>&1; then
        # Older alpine sometimes needs py3-virtualenv
        apk add --no-cache py3-virtualenv || true
      fi;;
    dnf)
      log "Installing system packages with dnf..."
      dnf install -y \
        ca-certificates curl git tzdata \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconf-pkg-config libffi-devel openssl-devel
      dnf clean all -y || true;;
    yum)
      log "Installing system packages with yum..."
      yum install -y \
        ca-certificates curl git tzdata \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconfig libffi-devel openssl-devel
      yum clean all -y || true;;
    *)
      warn "No supported package manager detected. Skipping system package installation."
      ;;
  esac
}

ensure_python() {
  if has_cmd "${PYTHON_BIN}"; then
    log "Found Python: $(${PYTHON_BIN} -V 2>&1)"
  else
    err "Python (${PYTHON_BIN}) is not installed or not in PATH."
    err "Use a base image with Python 3.9+ or allow system installation."
    exit 1
  fi
}

create_directories() {
  log "Preparing project directories at ${APP_HOME}..."
  mkdir -p "${APP_HOME}" \
           "${APP_HOME}/logs" \
           "${APP_HOME}/tmp" \
           "${APP_HOME}/.cache/pip"
  chmod 755 "${APP_HOME}" "${APP_HOME}/logs" "${APP_HOME}/tmp" || true
}

setup_venv() {
  if [ ! -d "${VENV_PATH}" ]; then
    log "Creating virtual environment at ${VENV_PATH}..."
    "${PYTHON_BIN}" -m venv "${VENV_PATH}"
  else
    log "Virtual environment already exists at ${VENV_PATH}."
  fi

  # shellcheck disable=SC1090
  source "${VENV_PATH}/bin/activate"
  # Upgrade core tooling in venv
  python -m pip install --upgrade pip setuptools wheel
}

install_python_dependencies() {
  # Install via requirements.txt if present
  if [ -f "${APP_HOME}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install -r "${APP_HOME}/requirements.txt"
  fi

  # If pyproject.toml exists, install the package itself (editable for dev)
  if [ -f "${APP_HOME}/pyproject.toml" ]; then
    local target="."
    if [ -n "${INSTRUCTOR_EXTRAS}" ]; then
      log "Installing package with extras: ${INSTRUCTOR_EXTRAS}"
      target=".[${INSTRUCTOR_EXTRAS}]"
    fi
    log "Installing project package (editable): ${target}"
    pip install -e "${APP_HOME}/${target}"
  fi

  # Optional dev deps (idempotent)
  if [ "${INSTALL_DEV_DEPS}" = "true" ]; then
    log "Installing optional development dependencies (ruff, pre-commit, pyright)..."
    pip install --upgrade ruff pre-commit pyright
  fi
}

configure_env_files() {
  # Write a container env file to auto-activate venv and set vars when bash starts
  local profile_snippet_path="/etc/profile.d/10-project-env.sh"
  local can_write_profile="false"
  if is_root && [ -d "/etc/profile.d" ] && [ -w "/etc/profile.d" ]; then
    can_write_profile="true"
  fi

  if [ "${can_write_profile}" = "true" ]; then
    log "Writing shell profile configuration to ${profile_snippet_path}"
    cat > "${profile_snippet_path}" <<EOF
# Auto-generated by setup script
export APP_HOME="${APP_HOME}"
export VENV_PATH="${VENV_PATH}"
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
if [ -d "\${VENV_PATH}" ] && [ -x "\${VENV_PATH}/bin/activate" ]; then
  . "\${VENV_PATH}/bin/activate"
fi
EOF
    chmod 644 "${profile_snippet_path}" || true
  else
    warn "Cannot write to /etc/profile.d (non-root or read-only). Skipping shell profile configuration."
  fi

  # Create .env.example with provider keys placeholders
  local env_example="${APP_HOME}/.env.example"
  if [ ! -f "${env_example}" ]; then
    log "Creating ${env_example}"
    cat > "${env_example}" <<'EOF'
# Copy to .env and fill in as needed.
# API Keys (optional, used by examples and integrations)
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
CO_API_KEY=
GROQ_API_KEY=
GOOGLE_API_KEY=
# General environment
PYTHONUNBUFFERED=1
EOF
  fi

  # If .env exists, export variables in current shell
  if [ -f "${APP_HOME}/.env" ]; then
    log "Loading environment variables from .env"
    # shellcheck disable=SC2046
    export $(grep -v '^[[:space:]]*#' "${APP_HOME}/.env" | xargs -I{} echo {})
  fi
}

setup_git_hooks() {
  if [ "${PRE_COMMIT_INSTALL}" = "true" ] && [ -f "${APP_HOME}/.pre-commit-config.yaml" ]; then
    if ! has_cmd git; then
      warn "git not available; cannot install pre-commit hooks."
      return 0
    fi
    if ! has_cmd pre-commit; then
      warn "pre-commit not installed in venv; installing..."
      pip install pre-commit
    fi
    log "Installing pre-commit git hooks..."
    (cd "${APP_HOME}" && pre-commit install --install-hooks -f || true)
  fi
}

print_summary() {
  log "------------------------------------------------------------"
  log "Setup complete!"
  log "Project home: ${APP_HOME}"
  log "Virtual env:  ${VENV_PATH}"
  log "Python:       $(python -V 2>&1 || echo 'unknown')"
  log "Pip:          $(pip --version 2>/dev/null || echo 'unknown')"
  if [ -n "${INSTRUCTOR_EXTRAS}" ]; then
    log "Installed extras: ${INSTRUCTOR_EXTRAS}"
  fi
  log "To use the environment in an interactive shell:"
  log "  source \"${VENV_PATH}/bin/activate\""
  if [ -f "${APP_HOME}/.env.example" ]; then
    log "Review environment variables in ${APP_HOME}/.env.example"
  fi
  log "------------------------------------------------------------"
}

#---------------------------#
# Main                      #
#---------------------------#
main() {
  log "Starting project environment setup..."

  create_directories

  install_system_packages

  ensure_python

  # Ensure ensurepip works across distros
  if ! has_cmd pip && has_cmd "${PYTHON_BIN}"; then
    log "Bootstrapping pip with ensurepip..."
    "${PYTHON_BIN}" -m ensurepip --upgrade || true
  fi

  setup_venv

  # Make sure we're in project root for editable install
  cd "${APP_HOME}"

  install_python_dependencies

  configure_env_files

  setup_git_hooks

  # Permissions: make sure directories are readable/executable by all (safe defaults)
  chmod -R a+rX "${APP_HOME}" || true

  print_summary
}

main "$@"