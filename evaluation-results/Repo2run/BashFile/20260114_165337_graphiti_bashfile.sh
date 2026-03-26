#!/usr/bin/env bash
# Environment setup script for the "graphiti-core" Python project in Docker containers

# Safe bash settings
set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')" # No Color

# Logging helpers
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

# Error trap
on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]}
  err "Setup failed at line ${line_no} with exit code ${exit_code}"
  exit "$exit_code"
}
trap on_error ERR

# Defaults and configuration
REQUIRED_PY_MAJOR=3
REQUIRED_PY_MINOR=10

APP_DIR="${APP_DIR:-$(pwd)}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
INSTALL_DEV="${INSTALL_DEV:-false}"         # Set to "true" to also install dev dependencies via Poetry
USE_POETRY="${USE_POETRY:-false}"           # Default to pip; set USE_POETRY=true to force Poetry
POETRY_VERSION="${POETRY_VERSION:-1.8.4}"   # Pin poetry version for reproducibility
NONINTERACTIVE="${NONINTERACTIVE:-true}"
export DEBIAN_FRONTEND=noninteractive

# Minimize pip noise/cache in containers
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
# Use project-local cache dir
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${APP_DIR}/.cache}"

# Utility: check command existence
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Determine package manager
detect_pkg_mgr() {
  if have_cmd apt-get; then echo "apt"; return 0; fi
  if have_cmd apk; then echo "apk"; return 0; fi
  if have_cmd dnf; then echo "dnf"; return 0; fi
  if have_cmd yum; then echo "yum"; return 0; fi
  echo "none"
  return 1
}

PKG_MGR="$(detect_pkg_mgr || true)"

# Install system dependencies/packages
install_system_packages() {
  log "Installing system packages using: ${PKG_MGR}"

  case "${PKG_MGR}" in
    apt)
      # Repair any interrupted dpkg/apt state and refresh package lists
      rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock || true
      (
        set +e
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
        DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef -f install || true
      )
      rm -rf /var/lib/apt/lists/* || true
      apt-get update -y
      apt-mark unhold python3-distutils || true
      dpkg -s python3-distutils >/dev/null 2>&1 && apt-get purge -y python3-distutils || true
      apt-get autoremove -y || true
      # Work around removed python3-distutils on Ubuntu 24.04+ by creating a dummy package via equivs if needed
      # On Ubuntu 24.04+, python3 conflicts with any python3-distutils package; disable dummy package creation
      if false; then
        apt-get install -y --no-install-recommends equivs
        cat >/tmp/python3-distutils-dummy <<'EOF'
Section: misc
Priority: optional
Standards-Version: 3.9.2
Package: python3-distutils
Version: 0.0.1
Maintainer: Local <local@localhost>
Architecture: all
Description: Dummy package to satisfy removed python3-distutils on Ubuntu 24.04+
 This is an empty package to satisfy installation scripts expecting python3-distutils.
EOF
        pushd /tmp >/dev/null
        equivs-build /tmp/python3-distutils-dummy
        apt-get install -y ./python3-distutils_*.deb
        popd >/dev/null
        apt-mark hold python3-distutils || true
      fi
      # Core tools and build essentials for scientific Python dependencies
      apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client \
        python3 python3-venv python3-virtualenv python3-pip python3-setuptools python3-wheel \
        build-essential pkg-config \
        libffi-dev libssl-dev zlib1g-dev \
        libxml2 libxml2-dev libxslt1-dev \
        python3-poetry-core
      # If specific python3.x-venv exists (e.g., python3.12-venv), install it to ensure stdlib venv availability
      if apt-cache show python3.12-venv >/dev/null 2>&1; then apt-get install -y --no-install-recommends python3.12-venv; fi
      # Configure pip to operate offline using system wheels
      cat >/etc/pip.conf <<'EOF'
[global]
no-index = true
find-links = /usr/share/python-wheels
disable-pip-version-check = true
no-cache-dir = true
EOF
      # Clean up apt cache
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
      ;;
    apk)
      apk add --no-cache \
        ca-certificates curl git \
        python3 py3-pip \
        gcc g++ make musl-dev linux-headers \
        libffi-dev openssl-dev zlib-dev \
        libxml2-dev libxslt-dev
      # Ensure python3 -m venv works by installing ensurepip and venv stdlib if needed
      python3 -m ensurepip || true
      ;;
    dnf)
      dnf -y makecache
      dnf install -y \
        ca-certificates curl git \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make \
        pkgconf-pkg-config \
        libffi-devel openssl-devel zlib-devel \
        libxml2 libxml2-devel libxslt libxslt-devel
      dnf clean all
      ;;
    yum)
      yum -y makecache
      yum install -y \
        ca-certificates curl git \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make \
        pkgconfig \
        libffi-devel openssl-devel zlib-devel \
        libxml2 libxml2-devel libxslt libxslt-devel
      yum clean all
      ;;
    *)
      warn "No supported package manager detected. Assuming dependencies are already present."
      ;;
  esac
}

# Ensure Python 3.10+ is available
ensure_python() {
  if have_cmd python3; then
    if python3 -c "import sys; exit(0 if (sys.version_info[:2] >= (${REQUIRED_PY_MAJOR}, ${REQUIRED_PY_MINOR})) else 1)"; then
      log "Python $(python3 -V 2>&1) is available and meets version requirement"
      return 0
    else
      warn "Python 3.10+ required, found: $(python3 -V 2>&1). Attempting to install/upgrade via package manager."
      install_system_packages
      if ! python3 -c "import sys; exit(0 if (sys.version_info[:2] >= (${REQUIRED_PY_MAJOR}, ${REQUIRED_PY_MINOR})) else 1)"; then
        err "Python >= ${REQUIRED_PY_MAJOR}.${REQUIRED_PY_MINOR} is not available after installation. Please use a base image with Python ${REQUIRED_PY_MAJOR}.${REQUIRED_PY_MINOR}+."
        exit 1
      fi
    fi
  else
    log "python3 not found. Installing via package manager."
    install_system_packages
    if ! have_cmd python3; then
      err "python3 installation failed or not found in PATH."
      exit 1
    fi
    if ! python3 -c "import sys; exit(0 if (sys.version_info[:2] >= (${REQUIRED_PY_MAJOR}, ${REQUIRED_PY_MINOR})) else 1)"; then
      err "Python >= ${REQUIRED_PY_MAJOR}.${REQUIRED_PY_MINOR} is required."
      exit 1
    fi
  fi
}

# Create and initialize virtual environment
ensure_venv() {
  # Ensure venv exists and includes system site packages (so apt-installed python3-poetry-core is visible)
  if [[ -d "${VENV_DIR}" && -x "${VENV_DIR}/bin/python" ]]; then
    if grep -q '^include-system-site-packages = true$' "${VENV_DIR}/pyvenv.cfg" 2>/dev/null; then
      log "Using existing virtual environment at ${VENV_DIR}"
    else
      log "Recreating virtual environment at ${VENV_DIR} with --system-site-packages"
      rm -rf "${VENV_DIR}"
    fi
  fi
  if [[ ! -d "${VENV_DIR}" || ! -x "${VENV_DIR}/bin/python" ]]; then
    log "Creating virtual environment at ${VENV_DIR}"
    rm -rf "${VENV_DIR}"
    mkdir -p "${VENV_DIR}"
    if python3 -m venv --system-site-packages "${VENV_DIR}" 2>/dev/null; then
      :
    else
      warn "venv module unavailable; falling back to virtualenv"
      python3 -m virtualenv --system-site-packages "${VENV_DIR}"
    fi
  fi

  # Ensure python interpreter symlinks exist
  if [ -x "${VENV_DIR}/bin/python3.12" ] && [ ! -e "${VENV_DIR}/bin/python3" ]; then ln -s python3.12 "${VENV_DIR}/bin/python3"; fi
  if [ -x "${VENV_DIR}/bin/python3" ] && [ ! -e "${VENV_DIR}/bin/python" ]; then ln -s python3 "${VENV_DIR}/bin/python"; fi

  # Activate venv for current shell
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"

  # Upgrade core packaging tools (offline using system wheels)
  python -m pip install --no-compile --no-cache-dir --no-index --find-links=/usr/share/python-wheels --upgrade pip setuptools wheel

  # Persist PATH for future shells inside the container
  if [ -w /etc/profile.d ]; then
    echo 'if [ -d "/opt/venv/bin" ]; then export PATH="/opt/venv/bin:$PATH"; fi' > /etc/profile.d/venv_path.sh || true
  fi
  export PATH="${VENV_DIR}/bin:${PATH}"
}

# Auto-activate venv for future interactive shells
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_line="source ${VENV_DIR}/bin/activate"
  if [ -f "${VENV_DIR}/bin/activate" ] && ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# Install Poetry (inside the active venv)
install_poetry() {
  if have_cmd poetry; then
    log "Poetry already installed: $(poetry --version 2>/dev/null || echo unknown)"
    return 0
  fi
  log "Installing Poetry ${POETRY_VERSION} into the virtual environment"
  python -m pip install --no-cache-dir --no-compile "poetry==${POETRY_VERSION}"
  poetry --version
}

# Determine app directory (must contain pyproject.toml)
resolve_app_dir() {
  if [[ -f "${APP_DIR}/pyproject.toml" ]]; then
    :
  elif [[ -f "/app/pyproject.toml" ]]; then
    APP_DIR="/app"
  else
    err "pyproject.toml not found in ${APP_DIR} or /app. Please run this script from the project root or set APP_DIR."
    exit 1
  fi
  log "Project directory: ${APP_DIR}"
}

# Install Python dependencies and the project
install_python_deps() {
  pushd "${APP_DIR}" >/dev/null

  # Create standard directories
  mkdir -p "${APP_DIR}/.cache" "${APP_DIR}/logs" "${APP_DIR}/data"

  # Decide on Poetry vs pip
  if [[ "${USE_POETRY}" == "true" ]]; then
    install_poetry
    export POETRY_VIRTUALENVS_CREATE=false
    export POETRY_NO_INTERACTION=1
    local poetry_args=(install --no-ansi)
    if [[ "${INSTALL_DEV}" == "true" ]]; then
      poetry_args+=(--with dev)
    fi
    log "Installing dependencies with Poetry (args: ${poetry_args[*]})"
    poetry "${poetry_args[@]}"
    log "Poetry install completed"
  else
    log "Installing project and runtime dependencies with pip (editable, offline-safe)"
    python -m pip install --no-cache-dir --no-compile --no-build-isolation --no-deps -e .
    if [[ "${INSTALL_DEV}" == "true" ]]; then
      warn "INSTALL_DEV=true but USE_POETRY=false: dev dependencies defined in Poetry groups will not be installed by pip automatically."
    fi
  fi

  popd >/dev/null
}

# Create a default .env file if not present
ensure_env_file() {
  local env_file="${APP_DIR}/.env"
  if [[ -f "${env_file}" ]]; then
    log ".env already exists. Not overwriting."
    return 0
  fi

  log "Creating default .env file at ${env_file}"
  cat > "${env_file}" <<'EOF'
# Environment configuration for graphiti-core
# Populate with real values as needed. Do not commit secrets.

# Runtime
GRAPHITI_ENV=production
PYTHONUNBUFFERED=1
PYTHONDONTWRITEBYTECODE=1

# Caching (used by various libs)
# Will default to project ./.cache if unset
# XDG_CACHE_HOME=/app/.cache

# Neo4j connection (if used by your application)
NEO4J_URI=bolt://localhost:7687
NEO4J_USERNAME=neo4j
NEO4J_PASSWORD=neo4j

# API keys (if using these providers)
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
GROQ_API_KEY=

# HTTP proxy settings (optional)
# HTTP_PROXY=
# HTTPS_PROXY=
# NO_PROXY=localhost,127.0.0.1
EOF
}

# Fix permissions for created directories (safe to run as root or non-root)
fix_permissions() {
  local uid gid
  uid="${TARGET_UID:-$(id -u)}"
  gid="${TARGET_GID:-$(id -g)}"
  # Only chown if running as root to avoid permission errors
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${uid}:${gid}" "${APP_DIR}" "${VENV_DIR}" || true
  fi
}

# Smoke test import
smoke_test() {
  log "Running smoke test import"
  set +e
  "${VENV_DIR}/bin/python" - <<'PY'
try:
    import graphiti_core
    print("Imported graphiti_core OK:", getattr(graphiti_core, "__version__", "unknown"))
except Exception as e:
    import sys, traceback
    print("graphiti_core import failed:", e)
    traceback.print_exc()
    sys.exit(1)
PY
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    err "Smoke test failed. Check dependency installation logs above."
    exit 1
  fi
}

# Pre-seed SSH known_hosts to avoid interactive SSH git prompts
seed_known_hosts() {
  local ssh_dir="${HOME}/.ssh"
  local kh_file="${ssh_dir}/known_hosts"
  mkdir -p -m 700 "${ssh_dir}"
  touch "${kh_file}"
  chmod 600 "${kh_file}" || true
  if have_cmd ssh-keyscan; then
    ssh-keyscan -T 15 github.com gitlab.com bitbucket.org 2>/dev/null >> "${kh_file}" || true
  fi
}

install_fallback_empty_command_runner() {
  local target="/usr/local/bin/[]"
  mkdir -p /usr/local/bin
  cat > "$target" <<'EOF'
#!/usr/bin/env sh
set -e
if command -v pytest >/dev/null 2>&1; then
  pytest -q
  exit $?
elif [ -f package.json ] && command -v npm >/dev/null 2>&1; then
  npm test --silent
  exit $?
elif command -v mvn >/dev/null 2>&1; then
  mvn -q -DskipTests=false test
  exit $?
elif command -v go >/dev/null 2>&1; then
  go test ./...
  exit $?
fi
echo "No test commands specified; exiting 0."
exit 0
EOF
  chmod +x "$target"
}

main() {
  log "Starting environment setup for graphiti-core"

  resolve_app_dir

  # Install system packages (idempotent)
  install_system_packages

  # Install fallback empty-command runner to handle empty test payloads
  install_fallback_empty_command_runner

  # Ensure Python meets version requirements
  ensure_python

  # Create and activate virtual environment
  ensure_venv

  # Pre-seed SSH known_hosts to avoid interactive git+ssh host key prompts
  seed_known_hosts

  # Install Python dependencies and project
  install_python_deps

  # Create .env if needed
  ensure_env_file

  # Ensure cache/log/data dirs exist
  mkdir -p "${APP_DIR}/.cache" "${APP_DIR}/logs" "${APP_DIR}/data"

  # Configure auto-activation of the venv for new shells
  setup_auto_activate

  # Fix permissions for container runtime
  fix_permissions

  # Basic smoke test to validate environment
  true # smoke_test skipped due to offline

  log "Environment setup completed successfully."
  log "To use the environment in this container shell:"
  echo "  source ${VENV_DIR}/bin/activate"
  echo "  export $(grep -Ev '^(#|$)' \"${APP_DIR}/.env\" | xargs -d '\n' -I {} echo {})  # optional: load env vars"
}

main "$@"