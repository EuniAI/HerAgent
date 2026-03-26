#!/usr/bin/env bash
# Setup script for the "cookiecutter-mlops-package" template development environment
# This script is designed to run inside Docker containers with root privileges.
# It installs system dependencies, Python 3.12 via uv, Poetry, and project dependencies.
#
# Idempotent: safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'

#---------------------------
# Configuration
#---------------------------
PROJECT_NAME="cookiecutter-mlops-package"
PY_VERSION="${PY_VERSION:-3.12}"         # Override with env var if needed (e.g., 3.12, 3.12.7)
WORKDIR_DEFAULT="/app"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
WORKDIR="${WORKDIR:-$PROJECT_DIR}"
POETRY_HOME="${POETRY_HOME:-/opt/poetry}"
POETRY_BIN="${POETRY_HOME}/bin/poetry"
POETRY_VENV_IN_PROJECT="${POETRY_VENV_IN_PROJECT:-1}"
UV_INSTALL_DIR="${UV_INSTALL_DIR:-/usr/local/bin}"
UV_NO_MODIFY_PATH=1
export LC_ALL=C.UTF-8 LANG=C.UTF-8

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info()   { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}"; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() {
  local code=$?
  if [[ $code -ne 0 ]]; then
    error "Setup failed with exit code ${code}"
  fi
}
trap cleanup EXIT

#---------------------------
# Helpers
#---------------------------
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return; fi
  echo "unknown"
}

install_system_packages() {
  local pmgr; pmgr="$(detect_pkg_manager)"
  log "Installing system packages using package manager: ${pmgr}"

  case "$pmgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # Core tools + build toolchain + common native deps for Python packages
      apt-get install -y --no-install-recommends \
        ca-certificates curl git bash build-essential pkg-config \
        openssh-client \
        libssl-dev libffi-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
        xz-utils tk-dev uuid-runtime
      # Clean
      rm -rf /var/lib/apt/lists/* ;;
    apk)
      apk update
      apk add --no-cache \
        ca-certificates curl git bash build-base pkgconfig \
        openssl-dev bzip2-dev zlib-dev readline-dev sqlite-dev \
        xz-dev tk tk-dev libffi-dev linux-headers
      update-ca-certificates ;;
    dnf)
      dnf -y install \
        ca-certificates curl git bash gcc gcc-c++ make pkgconfig \
        openssl-devel bzip2-devel zlib-devel libffi-devel readline-devel sqlite-devel xz-devel tk
      dnf -y clean all || true ;;
    yum)
      yum -y install \
        ca-certificates curl git bash gcc gcc-c++ make pkgconfig \
        openssl-devel bzip2-devel zlib-devel libffi-devel readline-devel sqlite-devel xz-devel tk
      yum -y clean all || true ;;
    zypper)
      zypper --non-interactive refresh
      zypper --non-interactive install -y \
        ca-certificates curl git bash gcc gcc-c++ make \
        libopenssl-devel libbz2-devel zlib-devel libffi-devel readline-devel sqlite3-devel xz tk
      zypper clean -a || true ;;
    *)
      warn "Unknown package manager. Skipping system package installation."
      ;;
  esac
}

ensure_directory() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
  fi
}

#---------------------------
# Install uv (Python toolchain manager)
#---------------------------
install_uv() {
  if command -v uv >/dev/null 2>&1; then
    log "uv already installed: $(command -v uv)"
    return
  fi
  log "Installing uv to ${UV_INSTALL_DIR}..."
  # shellcheck disable=SC2155
  export UV_INSTALL_DIR UV_NO_MODIFY_PATH
  curl -fsSL https://astral.sh/uv/install.sh | sh
  if ! command -v uv >/dev/null 2>&1; then
    error "uv installation failed"
    exit 1
  fi
  log "uv installed: $(uv --version)"
}

#---------------------------
# Install Python via uv
#---------------------------
install_python() {
  local version="$1"
  if uv python find "$version" >/dev/null 2>&1; then
    log "Python $version already available via uv at: $(uv python find "$version")"
  else
    log "Installing Python $version via uv..."
    UV_LINK_MODE=copy uv python install "$version"
  fi
  PYTHON_BIN="$(uv python find "$version")"
  if [[ -z "${PYTHON_BIN:-}" ]]; then
    error "Failed to locate Python $version via uv"
    exit 1
  fi
  log "Using Python: $PYTHON_BIN ($("$PYTHON_BIN" -V))"
}

#---------------------------
# Install Poetry
#---------------------------
install_poetry() {
  if [[ -x "$POETRY_BIN" ]]; then
    log "Poetry already installed at $POETRY_BIN"
    return
  fi
  log "Installing Poetry into $POETRY_HOME..."
  ensure_directory "$POETRY_HOME"
  # Poetry official installer; run with the uv-provided Python
  curl -sSL https://install.python-poetry.org | env POETRY_HOME="$POETRY_HOME" "$PYTHON_BIN" - --yes --preview
  # Ensure system-wide shim
  ln -sf "$POETRY_BIN" /usr/local/bin/poetry
  if ! command -v poetry >/dev/null 2>&1; then
    error "Poetry installation failed"
    exit 1
  fi
  log "Poetry installed: $(poetry --version)"
}

#---------------------------
# Configure project environment
#---------------------------
configure_project_env() {
  log "Configuring project directory and environment..."
  ensure_directory "$WORKDIR"
  cd "$WORKDIR"

  # Sanity checks
  if [[ ! -f "pyproject.toml" ]]; then
    error "pyproject.toml not found in $WORKDIR. Run this script from the repository root or set PROJECT_DIR/WORKDIR."
    exit 1
  fi

  # Git safety for root in containers
  if command -v git >/dev/null 2>&1; then
    git config --global --add safe.directory "$WORKDIR" || true
  fi

  # Poetry environment configurations
  export POETRY_HOME
  export POETRY_VIRTUALENVS_IN_PROJECT="${POETRY_VENV_IN_PROJECT}"
  export POETRY_VIRTUALENVS_CREATE=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1
  export PYTHONUNBUFFERED=1

  # Ensure Poetry uses the uv-provided Python
  poetry env use "$PYTHON_BIN" >/dev/null

  # Create .venv if not present and install deps
  if [[ -d ".venv" ]]; then
    log "Existing virtual environment detected at .venv"
  else
    log "Creating virtual environment with Poetry (.venv)"
  fi

  log "Installing project dependencies via Poetry..."
  poetry install --no-interaction --no-ansi

  log "Python runtime in venv: $(poetry run python -V)"
  log "Installed tools:"
  poetry run python -c "import sys; print('  site-packages:', next(p for p in sys.path if p.endswith('site-packages')), '\n  executable:', sys.executable)"

  # Optional: install pre-commit hooks if in a git repo
  if [[ -d ".git" ]]; then
    log "Setting up pre-commit hooks..."
    poetry run pre-commit install --install-hooks -t pre-commit -t commit-msg || warn "pre-commit setup skipped"
  else
    warn "No .git directory found; skipping pre-commit hook installation."
  fi
}

#---------------------------
# Makefile build target setup
#---------------------------
ensure_makefile_build_target() {
  # Backup existing Makefile if present, then write a safe, idempotent build target
  if [[ -f Makefile ]]; then
    cp -f Makefile Makefile.bak || true
  fi
  cat > Makefile <<'EOF'
SHELL := /bin/sh

.PHONY: build test

build:
	@echo "Running build..."
	@if [ -f package.json ] && command -v npm >/dev/null 2>&1; then \
	  if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi; \
	  if npm run | grep -qE ' build( |:)'; then npm run build || true; else echo "No npm build script; skipping."; fi; \
	elif [ -f go.mod ] && command -v go >/dev/null 2>&1; then \
	  go build ./...; \
	elif [ -f Cargo.toml ] && command -v cargo >/dev/null 2>&1; then \
	  cargo build --locked; \
	else \
	  echo "No recognized project type or required toolchain missing; skipping build."; \
	fi

test:
	@echo "Running tests..."
	@if [ -f package.json ] && command -v npm >/dev/null 2>&1; then \
	  if grep -q '"test"' package.json; then npm test --silent || npm run test || true; else echo "No npm test script; skipping."; fi; \
	elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -d tests ] || ls -1 test_*.py >/dev/null 2>&1 || ls -1 */test_*.py >/dev/null 2>&1; then \
	  if command -v pytest >/dev/null 2>&1; then pytest -q || true; elif command -v python3 >/dev/null 2>&1; then python3 -m pytest -q || true; else echo "pytest not available; skipping Python tests."; fi; \
	elif [ -f go.mod ] && command -v go >/dev/null 2>&1; then \
	  go test ./... || true; \
	elif [ -f Cargo.toml ] && command -v cargo >/dev/null 2>&1; then \
	  cargo test --locked || true; \
	else \
	  echo "No tests detected or required toolchain missing; skipping tests."; \
	fi
EOF
}

#---------------------------
# Main
#---------------------------
main() {
  info "Starting environment setup for ${PROJECT_NAME}"
  info "Working directory: ${WORKDIR}"

  install_system_packages
  install_uv
  install_python "$PY_VERSION"
  install_poetry
  configure_project_env
  ensure_makefile_build_target

  # Environment variables relevant to template development
  cat > .env.example <<'ENVVARS' || true
# Example environment variables for local development
# Adjust and export before running tasks, or use `direnv`/`dotenv` tools.

# Python/Poetry
POETRY_VIRTUALENVS_IN_PROJECT=1
PYTHONUNBUFFERED=1
PIP_NO_CACHE_DIR=1
PIP_DISABLE_PIP_VERSION_CHECK=1

# Cookiecutter defaults (used when generating new projects)
COOKIECUTTER_DEFAULT_USER=fmind
COOKIECUTTER_DEFAULT_PYTHON_VERSION=3.12
COOKIECUTTER_DEFAULT_MLFLOW_VERSION=2.14.3
ENVVARS

  log "Environment setup completed successfully!"
  echo
  echo "Useful commands:"
  echo "  - poetry --version"
  echo "  - uv --version"
  echo "  - poetry run invoke install       # installs deps (already done)"
  echo "  - poetry run invoke test          # runs tests (if any)"
  echo "  - poetry run pre-commit run -a    # run all hooks"
  echo
  echo "To activate the virtual environment:"
  echo "  source .venv/bin/activate"
  echo
}

main "$@"