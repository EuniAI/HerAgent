#!/usr/bin/env bash
# Environment setup script for the "moffee" Python project.
# Designed to run inside Docker containers as root without sudo.
# This script installs system packages, Python runtime, sets up a virtual environment,
# installs project dependencies, and configures environment variables and directories.
#
# Project details (from pyproject.toml):
# - Python: ^3.10
# - CLI entry point: moffee (moffee.cli:cli)
# - Type: CLI tool with optional live web server (livereload)
#
# Usage:
#   bash setup_env.sh
#
# Optional environment variables:
#   INSTALLER=poetry|pip          # Default: pip
#   FORCE_REINSTALL=1             # Forces reinstall of Python package into venv
#   DEV_MODE=1                    # Keep build tools installed (otherwise minimized)
#   MOFFEE_HOST=0.0.0.0           # Default host for live server
#   MOFFEE_PORT=5500              # Default port for live server
#   APP_USER=app                  # Create/use this user (optional)
#   APP_UID=1000                  # UID for app user (optional)
#   APP_GID=1000                  # GID for app user (optional)
#   DEBUG=1                       # Enable verbose tracing

set -Eeuo pipefail

# Enable debug tracing if requested
if [[ "${DEBUG:-}" == "1" ]]; then
  set -x
fi

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}"; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

# Trap errors
trap 'error "An error occurred on line $LINENO. Exiting."; exit 1' ERR

# Globals and defaults
PROJECT_NAME="moffee"
PYTHON_MIN_VERSION="3.10"
INSTALLER="${INSTALLER:-pip}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
DEV_MODE="${DEV_MODE:-0}"
MOFFEE_HOST="${MOFFEE_HOST:-0.0.0.0}"
MOFFEE_PORT="${MOFFEE_PORT:-5500}"
APP_USER="${APP_USER:-}"
APP_UID="${APP_UID:-}"
APP_GID="${APP_GID:-}"
DEBIAN_FRONTEND="noninteractive"

# Resolve project root from script location
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
ENV_DIR="$PROJECT_ROOT/env.d"
LOG_DIR="$PROJECT_ROOT/logs"
CACHE_DIR="$PROJECT_ROOT/.cache"
TMP_DIR="$PROJECT_ROOT/tmp"
OUTPUT_DIR="$PROJECT_ROOT/output_html"

# Utility: check running as root (apt/dnf/yum/apk requires root)
require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root inside the Docker container. Current UID: $(id -u)"
  fi
}

# Detect package manager
PKG_MGR=""
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    die "Unsupported base image. No known package manager found (apt/apk/dnf/yum)."
  fi
  log "Detected package manager: $PKG_MGR"
}

# Package manager operations
pm_update() {
  case "$PKG_MGR" in
    apt)
      log "Updating apt package index..."
      apt-get update -y
      ;;
    apk)
      log "Updating apk package index..."
      apk update
      ;;
    dnf)
      log "Updating dnf metadata..."
      dnf -y makecache
      ;;
    yum)
      log "Updating yum metadata..."
      yum -y makecache
      ;;
  esac
}

pm_install() {
  case "$PKG_MGR" in
    apt)
      # shellcheck disable=SC2068
      apt-get install -y --no-install-recommends $@
      ;;
    apk)
      # shellcheck disable=SC2068
      apk add --no-cache $@
      ;;
    dnf)
      # shellcheck disable=SC2068
      dnf install -y $@
      ;;
    yum)
      # shellcheck disable=SC2068
      yum install -y $@
      ;;
  esac
}

pm_clean() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
      ;;
    apk)
      rm -rf /var/cache/apk/*
      ;;
    dnf)
      dnf clean all || true
      rm -rf /var/cache/dnf/*
      ;;
    yum)
      yum clean all || true
      rm -rf /var/cache/yum/*
      ;;
  esac
}

# Install system dependencies required for Python and building wheels if needed
install_system_dependencies() {
  pm_update

  case "$PKG_MGR" in
    apt)
      pm_install ca-certificates curl git python3 python3-venv python3-pip
      # Build tools (some environments may need to compile wheels); keep minimal unless DEV_MODE
      pm_install build-essential libffi-dev libssl-dev
      ;;
    apk)
      pm_install ca-certificates curl git python3 py3-pip py3-virtualenv
      pm_install build-base libffi-dev openssl-dev
      ;;
    dnf)
      pm_install ca-certificates curl git python3 python3-pip
      # venv is part of python3 std lib in most distros; include build essentials
      pm_install gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    yum)
      pm_install ca-certificates curl git python3 python3-pip
      pm_install gcc gcc-c++ make libffi-devel openssl-devel
      ;;
  esac

  # Update CA certificates if available
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi

  if [[ "$DEV_MODE" != "1" ]]; then
    pm_clean
  fi

  log "System dependencies installed."
}

# Compare Python versions (returns 0 if version >= minimum)
check_python_version() {
  local pycmd=${1:-python3}
  if ! command -v "$pycmd" >/dev/null 2>&1; then
    return 1
  fi
  local ver
  ver="$("$pycmd" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo "0.0")"
  # Simple numeric comparison for major.minor
  local major="${ver%%.*}"
  local minor="${ver##*.}"
  local min_major="${PYTHON_MIN_VERSION%%.*}"
  local min_minor="${PYTHON_MIN_VERSION##*.}"
  if [[ "$major" -gt "$min_major" ]] || { [[ "$major" -eq "$min_major" ]] && [[ "$minor" -ge "$min_minor" ]]; }; then
    return 0
  fi
  return 1
}

ensure_python_runtime() {
  if check_python_version python3; then
    log "Python3 runtime meets requirement (>= $PYTHON_MIN_VERSION)."
  else
    die "Python3 runtime is missing or below $PYTHON_MIN_VERSION. Please use a base image with Python >= $PYTHON_MIN_VERSION."
  fi

  # Ensure pip is present
  if ! command -v pip3 >/dev/null 2>&1; then
    warn "pip3 not found; attempting to install via package manager."
    case "$PKG_MGR" in
      apt) pm_install python3-pip ;;
      apk) pm_install py3-pip ;;
      dnf) pm_install python3-pip ;;
      yum) pm_install python3-pip ;;
    esac
  fi

  log "Python runtime and pip are available."
}

# Create directories and set permissions
setup_directories() {
  log "Setting up project directories at $PROJECT_ROOT"
  mkdir -p "$ENV_DIR" "$LOG_DIR" "$CACHE_DIR" "$TMP_DIR" "$OUTPUT_DIR"

  # Optional: create non-root user and assign ownership
  if [[ -n "$APP_USER" ]]; then
    log "Ensuring application user: $APP_USER"
    # Create group if needed
    if [[ -n "$APP_GID" ]]; then
      if ! getent group "$APP_GID" >/dev/null 2>&1; then
        # Try to create a group with given GID
        if command -v addgroup >/dev/null 2>&1; then
          addgroup -g "$APP_GID" "$APP_USER" || true
        elif command -v groupadd >/dev/null 2>&1; then
          groupadd -g "$APP_GID" "$APP_USER" || true
        fi
      fi
    fi
    # Create user if needed
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      if command -v adduser >/dev/null 2>&1; then
        if [[ -n "$APP_UID" && -n "$APP_GID" ]]; then
          adduser -D -u "$APP_UID" -G "$APP_USER" "$APP_USER" 2>/dev/null || adduser -D "$APP_USER" || true
        else
          adduser -D "$APP_USER" || true
        fi
      elif command -v useradd >/dev/null 2>&1; then
        if [[ -n "$APP_UID" && -n "$APP_GID" ]]; then
          useradd -m -u "$APP_UID" -g "${APP_GID:-$(getent group "$APP_USER" | cut -d: -f3 || echo 1000)}" "$APP_USER" || true
        else
          useradd -m "$APP_USER" || true
        fi
      fi
    fi
    chown -R "${APP_USER}:${APP_USER}" "$PROJECT_ROOT" || true
  fi

  log "Directories created: $ENV_DIR, $LOG_DIR, $CACHE_DIR, $TMP_DIR, $OUTPUT_DIR"
}

# Set up Python virtual environment
setup_venv() {
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    log "Virtual environment already exists at $VENV_DIR"
  else
    log "Creating Python virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  # Activate for local installation within script context
  # shellcheck source=/dev/null
  source "$VENV_DIR/bin/activate"

  # Upgrade pip, setuptools, wheel for reliable builds
  log "Upgrading pip, setuptools, wheel in venv..."
  python -m pip install --upgrade --no-cache-dir pip setuptools wheel

  # Configure pip to no cache for containers
  pip config set global.no-cache-dir true >/dev/null 2>&1 || true

  log "Virtual environment is ready."
}

# Install project dependencies and the package itself
install_project_dependencies() {
  log "Installing project dependencies using ${INSTALLER}"

  if [[ ! -f "$PROJECT_ROOT/pyproject.toml" ]]; then
    die "pyproject.toml not found in $PROJECT_ROOT. This project uses Poetry/PEP 517; ensure files are present."
  fi

  case "$INSTALLER" in
    pip)
      # Install the project into the venv
      local pip_args=("--no-cache-dir")
      if [[ "$FORCE_REINSTALL" == "1" ]]; then
        pip_args+=("--upgrade" "--force-reinstall")
      fi

      # If moffee already installed, skip reinstall unless forcing
      if [[ "$FORCE_REINSTALL" != "1" ]]; then
        if "$VENV_DIR/bin/python" -m pip show "$PROJECT_NAME" >/dev/null 2>&1; then
          log "Package '$PROJECT_NAME' already installed in venv. Skipping reinstall."
        else
          log "Installing package '$PROJECT_NAME' into venv..."
          "$VENV_DIR/bin/python" -m pip install "${pip_args[@]}" "$PROJECT_ROOT"
        fi
      else
        log "Force re-installing package '$PROJECT_NAME' into venv..."
        "$VENV_DIR/bin/python" -m pip install "${pip_args[@]}" "$PROJECT_ROOT"
      fi
      ;;
    poetry)
      # Install Poetry into the venv to avoid global install
      log "Installing Poetry into venv..."
      "$VENV_DIR/bin/python" -m pip install --no-cache-dir "poetry==1.8.4"

      # Configure Poetry to use in-project venv and our venv python
      "$VENV_DIR/bin/poetry" config virtualenvs.in-project true --local || true
      "$VENV_DIR/bin/poetry" env use "$VENV_DIR/bin/python"

      # Install dependencies and project
      log "Running 'poetry install'..."
      "$VENV_DIR/bin/poetry" install --no-interaction --no-ansi
      ;;
    *)
      die "Unknown INSTALLER: $INSTALLER. Use 'pip' or 'poetry'."
      ;;
  esac

  # Verify CLI entrypoint availability
  if [[ -x "$VENV_DIR/bin/moffee" ]]; then
    log "CLI 'moffee' installed at $VENV_DIR/bin/moffee"
    "$VENV_DIR/bin/moffee" --help >/dev/null 2>&1 || warn "Installed CLI but unable to run help; check installation."
  else
    warn "CLI 'moffee' not found in venv bin. Dependencies may be installed but entrypoint missing."
  fi
}

# Configure environment variables and convenience files
configure_environment() {
  log "Configuring environment variables..."

  mkdir -p "$ENV_DIR"

  cat > "$ENV_DIR/project.env" <<EOF
# Environment variables for ${PROJECT_NAME}
export PROJECT_NAME="${PROJECT_NAME}"
export PROJECT_ROOT="${PROJECT_ROOT}"
export VENV_DIR="${VENV_DIR}"
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1
export PIP_NO_CACHE_DIR=1
export MOFFEE_HOST="${MOFFEE_HOST}"
export MOFFEE_PORT="${MOFFEE_PORT}"
# Prefer venv on PATH
export PATH="\$VENV_DIR/bin:\$PATH"
EOF

  chmod 0644 "$ENV_DIR/project.env"

  # Convenience wrapper to run moffee inside venv
  mkdir -p "$PROJECT_ROOT/bin"
  cat > "$PROJECT_ROOT/bin/run-moffee" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
if [[ -f "$PROJECT_ROOT/env.d/project.env" ]]; then
  source "$PROJECT_ROOT/env.d/project.env"
fi
if [[ ! -x "$VENV_DIR/bin/moffee" ]]; then
  echo "moffee CLI not found in venv ($VENV_DIR). Run setup_env.sh first." >&2
  exit 1
fi
exec "$VENV_DIR/bin/moffee" "$@"
EOF
  chmod +x "$PROJECT_ROOT/bin/run-moffee"

  log "Environment configuration written to $ENV_DIR/project.env"
  log "Use 'source $ENV_DIR/project.env' to load env vars in a shell."
}

# Create sample input file for CLI and ensure output directory exists
prepare_sample_files() {
  local sample_md="${PROJECT_ROOT}/example.md"
  if [[ ! -f "$sample_md" ]]; then
    printf '# Example Slides\n\n---\n\n## Slide 1\n\n- Item A\n- Item B\n' > "$sample_md"
  fi
  mkdir -p "$OUTPUT_DIR"
}

# Summary
print_summary() {
  cat <<EOF
Setup completed successfully.

Project: $PROJECT_NAME
Root:    $PROJECT_ROOT
Venv:    $VENV_DIR

Useful paths:
- Logs:         $LOG_DIR
- Cache:        $CACHE_DIR
- Temp:         $TMP_DIR
- Output HTML:  $OUTPUT_DIR

Environment file:
- $ENV_DIR/project.env (source this to export PATH and variables)

Run the CLI:
- $PROJECT_ROOT/bin/run-moffee --help
- Example (live server): $PROJECT_ROOT/bin/run-moffee live example.md --host "$MOFFEE_HOST" --port "$MOFFEE_PORT"

Notes:
- Re-run this script safely; it is idempotent.
- Set INSTALLER=poetry to use Poetry for dependency management.
- Set FORCE_REINSTALL=1 to force reinstall the package into the venv.
EOF
}

main() {
  log "Starting environment setup for project '$PROJECT_NAME' at $PROJECT_ROOT"
  require_root
  detect_pkg_manager
  install_system_dependencies
  ensure_python_runtime
  setup_directories
  setup_venv
  install_project_dependencies
  configure_environment
  prepare_sample_files
  print_summary
}

main "$@"