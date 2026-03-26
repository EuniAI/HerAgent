#!/usr/bin/env bash
# Environment setup script for the project (Python/PennyLane)
# Designed to run inside Docker containers (as root or non-root).
# Idempotent: safe to run multiple times.

set -Eeuo pipefail

# Globals and defaults
APP_DIR="${APP_DIR:-/app}"
VENV_DIR="${VENV_DIR:-$APP_DIR/.venv}"
PY_MIN_MAJOR=3
PY_MIN_MINOR=10
DEBIAN_FRONTEND=noninteractive
PIP_NO_CACHE_DIR="${PIP_NO_CACHE_DIR:-1}"
PIP_DISABLE_PIP_VERSION_CHECK="${PIP_DISABLE_PIP_VERSION_CHECK:-1}"
PIP_ROOT_USER_ACTION=ignore
UMASK_VAL="${UMASK_VAL:-0022}"
ENV_FILE="$APP_DIR/.env"
MARKER_DIR="/var/local/setup_markers"
SYS_MARKER="$MARKER_DIR/system_deps.done"
PY_MARKER="$MARKER_DIR/py_env.done"

# Colors (only if TTY)
if [ -t 1 ]; then
  GREEN="$(printf '\033[0;32m')"
  YELLOW="$(printf '\033[1;33m')"
  RED="$(printf '\033[0;31m')"
  NC="$(printf '\033[0m')"
else
  GREEN=""; YELLOW=""; RED=""; NC=""
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

cleanup() { :; }
trap cleanup EXIT
trap 'err "Failed at line $LINENO"; exit 1' ERR

# Utility: ensure directory exists with right perms
ensure_dir() {
  local d="$1"
  [ -d "$d" ] || mkdir -p "$d"
}

# Detect package manager and set commands + package names
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_UPDATE="apt-get update"
    PKG_CLEAN="rm -rf /var/lib/apt/lists/*"
    SYSTEM_PACKAGES=(
      build-essential python3 python3-dev python3-venv python3-pip
      git curl ca-certificates pkg-config cmake gfortran
      libopenblas-dev liblapack-dev libsuitesparse-dev libffi-dev libssl-dev
    )
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_INSTALL="dnf install -y"
    PKG_UPDATE="dnf makecache"
    PKG_CLEAN="dnf clean all && rm -rf /var/cache/dnf"
    SYSTEM_PACKAGES=(
      gcc gcc-c++ make python3 python3-devel python3-pip
      git curl ca-certificates pkgconf-pkg-config cmake gcc-gfortran
      openblas-devel lapack-devel suitesparse-devel libffi-devel openssl-devel
    )
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_INSTALL="yum install -y"
    PKG_UPDATE="yum makecache"
    PKG_CLEAN="yum clean all && rm -rf /var/cache/yum"
    SYSTEM_PACKAGES=(
      gcc gcc-c++ make python3 python3-devel python3-pip
      git curl ca-certificates pkgconf-pkg-config cmake gcc-gfortran
      openblas-devel lapack-devel suitesparse-devel libffi-devel openssl-devel
    )
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PKG_INSTALL="apk add --no-cache"
    PKG_UPDATE=":"
    PKG_CLEAN=":"
    SYSTEM_PACKAGES=(
      build-base python3 python3-dev py3-pip
      git curl ca-certificates pkgconf cmake gfortran
      openblas-dev lapack-dev suitesparse-dev libffi-dev openssl-dev
    )
    warn "Alpine/musl detected. Some scientific Python wheels may not be available; builds may be slow."
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
    PKG_INSTALL="pacman --noconfirm -S"
    PKG_UPDATE="pacman -Sy --noconfirm"
    PKG_CLEAN="pacman -Scc --noconfirm || true"
    SYSTEM_PACKAGES=(
      base-devel python python-pip
      git curl ca-certificates pkgconf cmake gcc-fortran
      openblas lapack suitesparse libffi openssl
    )
  else
    PKG_MGR="none"
  fi
}

install_system_deps() {
  detect_pkg_manager
  if [ "$PKG_MGR" = "none" ]; then
    warn "No supported package manager found; skipping system deps installation."
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root; cannot install system packages. Skipping system deps."
    return 0
  fi

  ensure_dir "$MARKER_DIR"
  if [ -f "$SYS_MARKER" ]; then
    log "System dependencies already installed. Skipping."
    return 0
  fi

  log "Installing system dependencies using $PKG_MGR..."
  $PKG_UPDATE || true

  # A few base fixes for Debian/Ubuntu noninteractive
  if [ "$PKG_MGR" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
  fi

  # Install packages
  # shellcheck disable=SC2086
  $PKG_INSTALL "${SYSTEM_PACKAGES[@]}"

  # Python venv provision for distros missing python3-venv
  if ! python3 -m venv --help >/dev/null 2>&1; then
    warn "python3-venv is unavailable. Will use virtualenv via pip."
  fi

  # Ensure certificates updated
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi

  # Clean caches to keep image lean
  bash -c "$PKG_CLEAN" || true

  touch "$SYS_MARKER"
  log "System dependencies installation completed."
}

check_python_version() {
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is not installed. Please use a base image with Python 3.${PY_MIN_MINOR}+ or ensure system deps step runs as root."
  fi
  local pyver
  pyver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  local major minor
  major="$(python3 -c 'import sys; print(sys.version_info[0])')"
  minor="$(python3 -c 'import sys; print(sys.version_info[1])')"
  if [ "$major" -lt "$PY_MIN_MAJOR" ] || { [ "$major" -eq "$PY_MIN_MAJOR" ] && [ "$minor" -lt "$PY_MIN_MINOR" ]; }; then
    die "Python $pyver detected. Requires Python >= ${PY_MIN_MAJOR}.${PY_MIN_MINOR}."
  fi
  log "Python $pyver detected (meets requirement >= ${PY_MIN_MAJOR}.${PY_MIN_MINOR})."
}

create_project_structure() {
  umask "$UMASK_VAL"
  ensure_dir "$APP_DIR"
  ensure_dir "$APP_DIR/logs"
  ensure_dir "$APP_DIR/data"
  ensure_dir "$APP_DIR/tmp"
  touch "$APP_DIR/.gitignore" >/dev/null 2>&1 || true
  # Permissions: allow readable dirs for non-root containers
  chmod 755 "$APP_DIR" || true
  chmod 755 "$APP_DIR/logs" "$APP_DIR/data" "$APP_DIR/tmp" || true

  # Set ownership to current user if root and requested
  if [ "$(id -u)" -eq 0 ] && [ -n "${APP_UID:-}" ] && [ -n "${APP_GID:-}" ]; then
    if getent group "$APP_GID" >/dev/null 2>&1 || getent group "${APP_GROUP:-app}" >/dev/null 2>&1; then
      :
    else
      groupadd -g "$APP_GID" "${APP_GROUP:-app}" || true
    fi
    if id -u "$APP_UID" >/dev/null 2>&1; then
      :
    else
      useradd -M -N -u "$APP_UID" -g "${APP_GID}" -s /usr/sbin/nologin "${APP_USER:-appuser}" || true
    fi
    chown -R "${APP_UID}:${APP_GID}" "$APP_DIR" || true
  fi
}

setup_virtualenv() {
  ensure_dir "$APP_DIR"
  if [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/activate" ]; then
    log "Reusing existing virtual environment at $VENV_DIR"
  else
    log "Creating Python virtual environment at $VENV_DIR"
    if python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
      :
    else
      warn "python3 -m venv failed; attempting to use virtualenv from pip"
      python3 -m pip install --no-cache-dir -U pip setuptools wheel virtualenv
      python3 -m virtualenv "$VENV_DIR"
    fi
  fi
  # shellcheck source=/dev/null
  . "$VENV_DIR/bin/activate"
  python -m pip install --no-cache-dir -U pip setuptools wheel
}

install_python_deps() {
  ensure_dir "$MARKER_DIR"
  if [ -f "$PY_MARKER" ]; then
    log "Python dependencies already installed. Skipping."
    # Still ensure environment is activated
    # shellcheck source=/dev/null
    . "$VENV_DIR/bin/activate"
    return 0
  fi

  # shellcheck source=/dev/null
  . "$VENV_DIR/bin/activate"

  # Prefer local requirements.txt if present
  if [ -f "$APP_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r "$APP_DIR/requirements.txt"
  fi

  # If a local package exists (setup.py/pyproject), install it editable
  if [ -f "$APP_DIR/setup.py" ] || [ -f "$APP_DIR/pyproject.toml" ]; then
    log "Installing local package in editable mode"
    pip install --no-cache-dir -e "$APP_DIR"
  fi

  # Validate import
  python - <<'PY'
import sys
try:
    import pennylane as qml
    print("PennyLane installed:", qml.__version__)
except Exception as e:
    print("PennyLane import failed:", e, file=sys.stderr)
    sys.exit(1)
PY

  touch "$PY_MARKER"
  log "Python dependencies installed successfully."
}

write_env_file() {
  # Create/update .env with safe defaults
  cat > "$ENV_FILE" <<EOF
# Auto-generated environment for container runtime
PYTHONUNBUFFERED=${PYTHONUNBUFFERED:-1}
PIP_NO_CACHE_DIR=${PIP_NO_CACHE_DIR}
PIP_DISABLE_PIP_VERSION_CHECK=${PIP_DISABLE_PIP_VERSION_CHECK}
MPLBACKEND=${MPLBACKEND:-Agg}
# Uncomment to change log level if needed
# PENNYLANE_LOG_LEVEL=INFO
# Extra pip index if required by your environment (leave empty if unused)
# PIP_EXTRA_INDEX_URL=
# PIP_INDEX_URL=
EOF
  chmod 644 "$ENV_FILE" || true
}

write_activation_helper() {
  # Helper to activate venv and load .env
  local helper="$APP_DIR/activate_venv.sh"
  cat > "$helper" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="${APP_DIR:-/app}"
VENV_DIR="${VENV_DIR:-$APP_DIR/.venv}"
if [ ! -f "$VENV_DIR/bin/activate" ]; then
  echo "Virtualenv not found at $VENV_DIR" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$VENV_DIR/bin/activate"
if [ -f "$APP_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$APP_DIR/.env"
  set +a
fi
python -c "import sys; print('Python', sys.version)"
python -c "import pennylane as qml; print('PennyLane', qml.__version__)"
echo "Environment activated."
EOF
  chmod +x "$helper" || true
}

export_runtime_env() {
  # Export .env variables into current shell for subsequent steps in this script
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
  fi
}

summary() {
  log "Setup complete."
  echo "Summary:"
  echo "- App directory: $APP_DIR"
  echo "- Virtualenv:    $VENV_DIR"
  echo "- Env file:      $ENV_FILE"
  echo "- Logs dir:      $APP_DIR/logs"
  echo "- Data dir:      $APP_DIR/data"
  echo "- Temp dir:      $APP_DIR/tmp"
  echo
  echo "Usage inside container:"
  echo "  source $APP_DIR/activate_venv.sh"
  echo "  python -c 'import pennylane as qml; print(qml.__version__)'"
  echo "  pl-device-test --help"
}

main() {
  log "Starting project environment setup..."
  create_project_structure
  install_system_deps
  check_python_version
  setup_virtualenv
  write_env_file
  export_runtime_env
  install_python_deps
  write_activation_helper
  summary
}

# Honor custom APP_DIR if script executed from repo root
# If /app exists and we are not inside a git repo, assume /app is mount point
if [ -f "./setup.py" ] || [ -f "./pyproject.toml" ] || [ -f "./requirements.txt" ]; then
  # Prefer current working directory as APP_DIR if looks like project root
  APP_DIR="${APP_DIR:-$(pwd)}"
fi

main "$@"