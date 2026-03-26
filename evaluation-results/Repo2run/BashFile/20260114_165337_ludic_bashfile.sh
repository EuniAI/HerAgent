#!/usr/bin/env bash
# Environment setup script for the "ludic" Python project
# Designed for Docker containers (root by default; no sudo assumed)

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
info() { echo -e "${BLUE}$*${NC}"; }

trap 'err "Script failed at line $LINENO"; exit 1' ERR

# Defaults and configuration
PROJECT_NAME_DEFAULT="ludic"
: "${PROJECT_NAME:=${PROJECT_NAME_DEFAULT}}"

# Determine project root: prefer directory containing pyproject.toml
detect_project_root() {
  local start_dir script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  start_dir="$PWD"
  if [[ -f "$start_dir/pyproject.toml" ]]; then
    echo "$start_dir"
    return 0
  elif [[ -f "$script_dir/pyproject.toml" ]]; then
    echo "$script_dir"
    return 0
  else
    # Traverse upwards until root to find pyproject.toml
    local d="$start_dir"
    while [[ "$d" != "/" ]]; do
      if [[ -f "$d/pyproject.toml" ]]; then
        echo "$d"
        return 0
      fi
      d="$(dirname "$d")"
    done
    # Fallback to start_dir if not found
    echo "$start_dir"
  fi
}

PROJECT_ROOT="$(detect_project_root)"
VENV_PATH="${VENV_PATH:-$PROJECT_ROOT/.venv}"

# Environment variables for Python tooling
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_NO_CACHE_DIR=${PIP_NO_CACHE_DIR:-1}
export UV_LINK_MODE=${UV_LINK_MODE:-copy} # safer for containerized volumes
export UV_PYTHON_PURE=${UV_PYTHON_PURE:-0}

# Respect custom index if provided
if [[ -n "${PIP_INDEX_URL:-}" ]]; then
  export UV_PIP_INDEX_URL="${UV_PIP_INDEX_URL:-$PIP_INDEX_URL}"
fi

# Optional user creation (set CREATE_APP_USER=1 to enable)
APP_USER="${APP_USER:-appuser}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
CREATE_APP_USER="${CREATE_APP_USER:-0}"

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_directory() {
  local d="$1"
  [[ -d "$d" ]] || mkdir -p "$d"
}

install_system_packages() {
  if ! is_root; then
    warn "Not running as root; skipping system package installation."
    return 0
  fi

  log "Installing system packages required for building and VCS..."
  export DEBIAN_FRONTEND=noninteractive

  if have_cmd apt-get; then
    apt-get update -y
    apt-get install -y --no-install-recommends \
      ca-certificates curl git \
      build-essential pkg-config \
      libffi-dev
    rm -rf /var/lib/apt/lists/*
  elif have_cmd apk; then
    apk update
    apk add --no-cache \
      ca-certificates curl git \
      build-base pkgconf \
      libffi-dev
    update-ca-certificates || true
  elif have_cmd dnf; then
    dnf -y install \
      ca-certificates curl git \
      gcc gcc-c++ make pkgconf-pkg-config \
      libffi-devel
    dnf clean all
  elif have_cmd yum; then
    yum -y install \
      ca-certificates curl git \
      gcc gcc-c++ make pkgconfig \
      libffi-devel
    yum clean all
  elif have_cmd zypper; then
    zypper --non-interactive refresh
    zypper --non-interactive install -y \
      ca-certificates curl git \
      gcc gcc-c++ make pkgconf-pkg-config \
      libffi-devel
    zypper clean -a
  else
    warn "No supported package manager found. Proceeding without system-level dependencies."
  fi
  log "System package installation completed."
}

install_uv() {
  if have_cmd uv; then
    log "uv already installed: $(command -v uv)"
    return 0
  fi

  log "Installing uv (Python package manager/runtime) ..."
  # Use official installer; installs to ~/.local/bin/uv
  # shellcheck disable=SC2155
  local install_sh
  install_sh="$(mktemp)"
  curl -fsSL https://astral.sh/uv/install.sh -o "$install_sh"
  chmod +x "$install_sh"
  # The installer respects DESTDIR/UV_UNPACK_DIR; default is ~/.local/bin
  sh "$install_sh" >/dev/null
  rm -f "$install_sh"

  # Ensure ~/.local/bin on PATH for current shell and persist
  local local_bin
  local_bin="${HOME}/.local/bin"
  if [[ ":$PATH:" != *":$local_bin:"* ]]; then
    export PATH="${local_bin}:${PATH}"
  fi

  if ! have_cmd uv; then
    err "uv installation failed or not in PATH."
    exit 1
  fi
  log "uv installed: $(command -v uv)"
}

ensure_python_runtime() {
  # We need Python >= 3.12 (prefer 3.12)
  local required="3.12"
  local have_python=""

  if have_cmd python3; then
    local v
    v="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))' || true)"
    if [[ -n "$v" ]]; then
      have_python="$v"
    fi
  fi

  if [[ -n "$have_python" ]]; then
    # If system python is sufficient, we can still use uv to manage venv.
    if python3 -c 'import sys; assert sys.version_info >= (3,12)' 2>/dev/null; then
      log "System Python $have_python satisfies requirement (>=3.12)."
      return 0
    else
      warn "System Python $have_python is < 3.12. A newer runtime will be installed via uv."
    fi
  fi

  install_uv

  # Install Python runtime via uv
  if uv python list | grep -q "$required" >/dev/null 2>&1; then
    log "uv-managed Python $required already present."
  else
    log "Installing Python $required via uv..."
    uv python install "$required"
  fi
}

create_venv() {
  ensure_directory "$PROJECT_ROOT"
  cd "$PROJECT_ROOT"

  if [[ -d "$VENV_PATH" ]]; then
    log "Virtual environment already exists at $VENV_PATH"
    return 0
  fi

  # Prefer uv venv to ensure correct Python version (3.12)
  install_uv
  log "Creating virtual environment at $VENV_PATH using Python 3.12..."
  uv venv --python 3.12 "$VENV_PATH"
  log "Virtual environment created."
}

install_project_dependencies() {
  cd "$PROJECT_ROOT"

  # Activate venv
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"

  install_uv

  # Upgrade base tooling inside venv
  log "Upgrading core Python packaging tools..."
  uv pip install --upgrade pip setuptools wheel

  # Install project in editable mode with all optional extras defined in pyproject
  if [[ -f "$PROJECT_ROOT/pyproject.toml" ]]; then
    log "Installing project and extras: [full,dev,django,test] ..."
    # Editable install with extras; safe to re-run
    uv pip install -e ".[full,dev,django,test]"
  else
    warn "pyproject.toml not found in $PROJECT_ROOT. Skipping project installation."
  fi

  # Optional dev tools convenience
  # Ensure common CLI tools are available in venv (idempotent)
  uv pip install ruff pytest || true

  log "Python dependencies installed."
}

write_env_profile() {
  # Persist environment settings for interactive shells
  local profile_snippet
  profile_snippet="# Auto-generated by setup script for $PROJECT_NAME
export PYTHONDONTWRITEBYTECODE=${PYTHONDONTWRITEBYTECODE}
export PYTHONUNBUFFERED=${PYTHONUNBUFFERED}
export PIP_NO_CACHE_DIR=${PIP_NO_CACHE_DIR}
export UV_LINK_MODE=${UV_LINK_MODE}
export PROJECT_NAME=${PROJECT_NAME}
export PROJECT_ROOT=${PROJECT_ROOT}
export VENV_PATH=${VENV_PATH}
# Add .venv and ~/.local/bin to PATH
if [ -d \"${HOME}/.local/bin\" ] && [[ \":\$PATH:\" != *\":${HOME}/.local/bin:\"* ]]; then
  export PATH=\"${HOME}/.local/bin:\$PATH\"
fi
if [ -d \"${VENV_PATH}/bin\" ] && [[ \":\$PATH:\" != *\":${VENV_PATH}/bin:\"* ]]; then
  export PATH=\"${VENV_PATH}/bin:\$PATH\"
fi
"

  if is_root && [[ -d /etc/profile.d ]]; then
    echo "$profile_snippet" > /etc/profile.d/"${PROJECT_NAME}".sh
    chmod 0644 /etc/profile.d/"${PROJECT_NAME}".sh
    log "Persisted environment to /etc/profile.d/${PROJECT_NAME}.sh"
  else
    # Fallback to user profile
    local shell_rc
    shell_rc="${HOME}/.profile"
    echo "$profile_snippet" > "${PROJECT_ROOT}/.envrc"
    # Append a source line idempotently
    if ! grep -qs 'source .*\.envrc' "$shell_rc" 2>/dev/null; then
      echo "source '${PROJECT_ROOT}/.envrc' 2>/dev/null || true" >> "$shell_rc"
    fi
    log "Persisted environment to ${PROJECT_ROOT}/.envrc and referenced in ${shell_rc}"
  fi
}

setup_permissions() {
  if [[ "$CREATE_APP_USER" != "1" ]]; then
    log "Skipping non-root user creation (set CREATE_APP_USER=1 to enable)."
    return 0
  fi
  if ! is_root; then
    warn "Cannot create user without root privileges."
    return 0
  fi

  # Create group if missing
  if ! getent group "$APP_GID" >/dev/null 2>&1; then
    addgroup_cmd=""
    if have_cmd addgroup; then
      addgroup_cmd="addgroup -g $APP_GID $APP_USER"
    elif have_cmd groupadd; then
      addgroup_cmd="groupadd -g $APP_GID $APP_USER"
    fi
    if [[ -n "$addgroup_cmd" ]]; then
      eval "$addgroup_cmd"
    fi
  fi

  # Create user if missing
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if have_cmd adduser; then
      adduser -D -H -u "$APP_UID" -G "$APP_USER" "$APP_USER" 2>/dev/null || \
      adduser --uid "$APP_UID" --gid "$APP_GID" --disabled-password --gecos "" "$APP_USER"
    elif have_cmd useradd; then
      useradd -u "$APP_UID" -g "$APP_GID" -m -s /bin/sh "$APP_USER"
    else
      warn "No adduser/useradd available; skipping user creation."
    fi
  fi

  chown -R "$APP_UID":"$APP_GID" "$PROJECT_ROOT" || true
  log "Set ownership of project directory to ${APP_USER}:${APP_GID}."
}

print_summary() {
  info ""
  info "Setup complete for project: ${PROJECT_NAME}"
  info "Project root: ${PROJECT_ROOT}"
  info "Virtual env:  ${VENV_PATH}"
  info ""
  info "Next steps:"
  info "1) Activate environment: source \"${VENV_PATH}/bin/activate\""
  info "2) Run tests:           pytest"
  info "3) Lint:                ruff check ${PROJECT_NAME}"
  info ""
  info "This script is idempotent and safe to re-run."
}

main() {
  log "Starting environment setup for project '${PROJECT_NAME}' ..."
  log "Detected project root: ${PROJECT_ROOT}"

  install_system_packages
  ensure_python_runtime
  create_venv
  install_project_dependencies
  write_env_profile
  setup_permissions
  print_summary

  log "Environment setup completed successfully."
}

main "$@"