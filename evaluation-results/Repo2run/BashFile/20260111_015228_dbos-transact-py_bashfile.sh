#!/usr/bin/env bash
# Environment setup script for Python project using pyproject.toml (PDM backend)
# Designed to run inside Docker containers with root or non-root users.
# Idempotent, safe to run multiple times.

set -euo pipefail

# Globals
SCRIPT_NAME="$(basename "$0")"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
VENV_DIR="${VENV_DIR:-$PROJECT_DIR/.venv}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
DATA_DIR="${DATA_DIR:-$PROJECT_DIR/data}"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/env.sh}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/setup.log}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PIP_BIN="pip"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=9

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# Logging functions
log() {
  echo "[${SCRIPT_NAME}] $(date +'%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

warn() {
  echo "${YELLOW}[WARNING]$(date +'%Y-%m-%d %H:%M:%S') $*${NC}" | tee -a "$LOG_FILE" >&2
}

error() {
  echo "${RED}[ERROR]$(date +'%Y-%m-%d %H:%M:%S') $*${NC}" | tee -a "$LOG_FILE" >&2
}

trap 'error "An unexpected error occurred. See $LOG_FILE for details."; exit 1' ERR

# Ensure basic directories exist
prepare_directories() {
  mkdir -p "$LOG_DIR" "$DATA_DIR"
  touch "$LOG_FILE"
  # Set permissions: rwx for owner, rx for group/others on dirs; log file owner writeable
  chmod 755 "$PROJECT_DIR" || true
  chmod 755 "$LOG_DIR" "$DATA_DIR" || true
  chmod 644 "$LOG_FILE" || true
}

# Detect package manager
detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo "none"
  fi
}

# Auto-activation and package manager helpers
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  [ -f "$bashrc_file" ] || touch "$bashrc_file"
  if ! grep -q 'DBOS_AUTO_VENV' "$bashrc_file" 2>/dev/null; then
    printf '%s\n' \
'# DBOS_AUTO_VENV: auto-activate project virtualenv if present' \
'if [ -z "$VIRTUAL_ENV" ] && [ -d "$PWD/.venv" ]; then' \
'  . "$PWD/.venv/bin/activate"' \
'fi' >> "$bashrc_file"
  fi
  # Ensure PEP 517 builds with pdm-backend succeed even without SCM by setting a default version
  if ! grep -q 'PDM_BUILD_SCM_VERSION' "$bashrc_file" 2>/dev/null; then
    printf 'export PDM_BUILD_SCM_VERSION=${PDM_BUILD_SCM_VERSION:-0.0.0}\n' >> "$bashrc_file"
  fi
}

setup_cache_isolation() {
  mkdir -p /tmp/xdg-cache
  chmod 700 /tmp/xdg-cache || true
  export XDG_CACHE_HOME="/tmp/xdg-cache"
  export PIP_NO_CACHE_DIR=1
  export HISHEL_DISABLED=1
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/pdm" "${XDG_CACHE_HOME:-$HOME/.cache}/hishel" || true
  printf 'export XDG_CACHE_HOME=/tmp/xdg-cache\nexport PIP_NO_CACHE_DIR=1\nexport HISHEL_DISABLED=1\n' > /etc/profile.d/02-cache.sh
  chmod 644 /etc/profile.d/02-cache.sh || true
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > /etc/profile.d/01-local-path.sh
  chmod 644 /etc/profile.d/01-local-path.sh || true
  rm -rf "$HOME/.cache/hishel" "$HOME/.cache/pdm" "$HOME/.cache/pip" "$HOME/.local/state/pdm" "$HOME/.local/state/pdm/cache" "$HOME/.local/state/pdm/httpcache" "$HOME/.local/share/pdm/http-cache" || true
  find "$HOME/.cache" -type f \( -name "*.sqlite" -o -name "*.sqlite-shm" -o -name "*.sqlite-wal" -o -name "cache.db" -o -name "cache.db-shm" -o -name "cache.db-wal" \) -path "*/hishel/*" -delete 2>/dev/null || true
}

# Repair PDM HTTP cache lock/corruption issues and upgrade hishel in PDM's own venv if present
repair_pdm_http_cache() {
  if [ -x /root/.local/share/pdm/venv/bin/python ]; then
    /root/.local/share/pdm/venv/bin/python -m pip install --no-cache-dir -U hishel
  fi
  rm -rf /root/.cache/pdm /root/.cache/hishel /root/.local/state/pdm/http-cache || true
  rm -rf ~/.cache/pdm ~/.cache/hishel || true
  find /root/.cache -type f -name "*.sqlite*" -path "*/pdm/*" -delete 2>/dev/null || true
}

setup_apt_wrapper() {
  if command -v apt-get >/dev/null 2>&1; then
    mkdir -p /usr/local/bin
    cat >/usr/local/bin/apt-get <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REAL_APT_GET="/usr/bin/apt-get"
if [ "$#" -gt 0 ] && [ "$1" = "install" ]; then
  args=()
  for arg in "$@"; do
    if [ "$arg" = "python3-distutils" ]; then
      continue
    fi
    args+=("$arg")
  done
  exec "$REAL_APT_GET" "${args[@]}"
else
  exec "$REAL_APT_GET" "$@"
fi
EOF
    chmod +x /usr/local/bin/apt-get
    /usr/local/bin/apt-get update -y
  fi
}

# Install system packages required for Python builds and networking
install_system_packages() {
  local pm
  pm="$(detect_package_manager)"

  log "Detected package manager: $pm"

  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # Core tools + build dependencies for common Python packages
      apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git tzdata \
        python3 python3-venv python3-pip python3-dev python3-distutils \
        build-essential gcc g++ make \
        libffi-dev libssl-dev \
        libpq-dev \
        pkg-config
      update-ca-certificates || true
      ;;
    apk)
      apk update
      apk add --no-cache \
        ca-certificates curl git tzdata \
        python3 py3-pip \
        build-base \
        libffi-dev openssl-dev \
        postgresql-dev \
        pkgconfig
      update-ca-certificates || true
      # Ensure pip is available for python3
      if ! command -v pip3 >/dev/null 2>&1; then
        "$PYTHON_BIN" -m ensurepip || true
      fi
      ;;
    dnf)
      dnf -y install \
        ca-certificates curl git tzdata \
        python3 python3-devel \
        gcc gcc-c++ make \
        libffi-devel openssl-devel \
        postgresql-devel \
        pkgconfig
      update-ca-trust || true
      ;;
    yum)
      yum -y install \
        ca-certificates curl git tzdata \
        python3 python3-devel \
        gcc gcc-c++ make \
        libffi-devel openssl-devel \
        postgresql-devel \
        pkgconfig
      update-ca-trust || true
      ;;
    *)
      warn "No supported package manager detected. Assuming base image already has required tools."
      ;;
  esac
}

# Persist PDM SCM version across sessions
persist_pdm_scm_version() {
  printf 'export PDM_BUILD_SCM_VERSION=0.0.0\n' > /etc/profile.d/pdm_scm.sh
  chmod +x /etc/profile.d/pdm_scm.sh || true
  sh -c 'if grep -q "^PDM_BUILD_SCM_VERSION=" /etc/environment; then sed -i "s/^PDM_BUILD_SCM_VERSION=.*/PDM_BUILD_SCM_VERSION=0.0.0/" /etc/environment; else echo "PDM_BUILD_SCM_VERSION=0.0.0" >> /etc/environment; fi'
}

# Install Node.js (NodeSource) and DBOS Cloud CLI
install_node_and_dbos_cli() {
  if command -v npm >/dev/null 2>&1; then
    :
  else
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y ca-certificates curl gnupg
      mkdir -p /usr/share/keyrings
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
      printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main\n' > /etc/apt/sources.list.d/nodesource.list
      apt-get update -y
      apt-get install -y nodejs
    else
      warn "Unsupported package manager for Node.js installation; skipping."
    fi
  fi
  if command -v npm >/dev/null 2>&1; then
    npm i -g @dbos-inc/dbos-cloud || warn "Failed to install @dbos-inc/dbos-cloud via npm"
  fi
}

# Ensure PDM is installed and on PATH for non-interactive shells
ensure_pdm_on_path() {
  if ! command -v pip3 >/dev/null 2>&1; then
    apt-get update && apt-get install -y python3-pip python3-venv
  fi
  python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel
  python3 -m pip install --no-cache-dir -U pdm
  mkdir -p /usr/local/bin
  if [ -x /usr/local/bin/pdm ] && [ ! -x /usr/local/bin/pdm.real ]; then
    mv /usr/local/bin/pdm /usr/local/bin/pdm.real
  fi
  cat > /usr/local/bin/pdm <<'EOF'
#!/usr/bin/env bash
export PDM_BUILD_SCM_VERSION=${PDM_BUILD_SCM_VERSION:-0.0.0}
export XDG_CACHE_HOME=${XDG_CACHE_HOME:-/tmp/xdg-cache}
exec python3 -m pdm "$@"
EOF
  chmod +x /usr/local/bin/pdm
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > /etc/profile.d/user-local-bin.sh
}

# Verify Python version
check_python() {
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    error "Python 3 is not installed. Please use a Python base image (e.g., python:3.11-slim) or rerun after installing Python."
    exit 1
  fi

  local ver_major ver_minor
  ver_major="$("$PYTHON_BIN" -c 'import sys; print(sys.version_info[0])')"
  ver_minor="$("$PYTHON_BIN" -c 'import sys; print(sys.version_info[1])')"

  if [ "$ver_major" -lt "$MIN_PYTHON_MAJOR" ] || { [ "$ver_major" -eq "$MIN_PYTHON_MAJOR" ] && [ "$ver_minor" -lt "$MIN_PYTHON_MINOR" ]; }; then
    error "Python ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}+ is required. Detected ${ver_major}.${ver_minor}."
    exit 1
  fi

  log "Python version ${ver_major}.${ver_minor} detected"
}

# Create or reuse virtual environment
setup_venv() {
  if [ -d "$VENV_DIR" ]; then
    log "Virtual environment already exists at $VENV_DIR"
  else
    log "Creating virtual environment at $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi

  # Activate venv in this shell
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  PIP_BIN="pip"
  # Upgrade pip, wheel, setuptools to latest
  "$PIP_BIN" install --no-cache-dir --upgrade pip setuptools wheel
}

# Install Python dependencies from pyproject.toml or requirements.txt
install_python_deps() {
  local pyproject requirements
  pyproject="$PROJECT_DIR/pyproject.toml"
  requirements="$PROJECT_DIR/requirements.txt"

  if [ -f "$pyproject" ]; then
    log "pyproject.toml found. Installing project using PEP 517 (pdm-backend will be pulled automatically)."
    # Ensure pdm-backend can resolve version when SCM is not detected
    export PDM_BUILD_SCM_VERSION="${PDM_BUILD_SCM_VERSION:-0.0.0}"
    "$PIP_BIN" install --no-cache-dir .
  elif [ -f "$requirements" ]; then
    log "requirements.txt found. Installing dependencies."
    "$PIP_BIN" install --no-cache-dir -r "$requirements"
  else
    warn "No pyproject.toml or requirements.txt found. Skipping Python dependency installation."
  fi

  # Verify CLI entrypoint if defined
  if "$PIP_BIN" show dbos >/dev/null 2>&1; then
    log "Package 'dbos' installed."
  fi
}

# Install missing OpenTelemetry packages into global /opt/venv if present to support dbos CLI
install_opentelemetry_for_dbos() {
  if [ -x /opt/venv/bin/pip ]; then
    /opt/venv/bin/pip install --no-cache-dir -U jsonpickle jsonschema opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp opentelemetry-distro
  else
    python3 -m pip install --no-cache-dir -U jsonpickle jsonschema opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp opentelemetry-distro
  fi
}

# Ensure Alembic is available both where the dbos CLI runs and for pdm-run environments
install_alembic_dependencies() {
  # Prefer installing into /opt/venv if it exists (where dbos CLI typically resides)
  if [ -x /opt/venv/bin/pip ]; then
    /opt/venv/bin/pip install --no-cache-dir -U alembic || warn "Failed to install Alembic into /opt/venv"
  fi
  # Also install into the environment backing `python3`
  python3 -m pip install --no-cache-dir -U alembic || warn "Failed to install Alembic via system python3"
  # Also install into the interpreter that `pdm run` resolves, to support pdm-based test runs
  if command -v pdm >/dev/null 2>&1; then
    pdm run python -m pip install --no-cache-dir -U alembic || warn "Failed to install Alembic via pdm run"
  fi
}

# Install and configure local PostgreSQL for tests/environment
install_and_configure_postgres() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if ! dpkg -s postgresql >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y postgresql postgresql-contrib
    fi
    su - postgres -c "psql -tAc \"ALTER USER postgres WITH PASSWORD 'postgres';\"" || true
    sh -lc 'PG_VER=$(ls /etc/postgresql | head -n1); HBA=/etc/postgresql/$PG_VER/main/pg_hba.conf; if [ -f "$HBA" ]; then sed -ri "s/^(local[[:space:]]+all[[:space:]]+postgres[[:space:]]+)peer/\1md5/" "$HBA"; sed -ri "s/^(local[[:space:]]+all[[:space:]]+all[[:space:]]+)peer/\1md5/" "$HBA"; grep -q "host all all 127.0.0.1/32 md5" "$HBA" || echo "host all all 127.0.0.1/32 md5" >> "$HBA"; grep -q "host all all ::1/128 md5" "$HBA" || echo "host all all ::1/128 md5" >> "$HBA"; fi; (systemctl restart postgresql || service postgresql restart || pg_ctlcluster "$PG_VER" main restart || true)'
  else
    warn "PostgreSQL setup currently only supported with apt-based images; skipping."
  fi
}

# Create a sitecustomize.py to set default PostgreSQL environment variables
create_sitecustomize() {
  cat > "$PROJECT_DIR/sitecustomize.py" <<'PY'
import os
os.environ.setdefault('PGHOST', os.environ.get('PGHOST', '127.0.0.1'))
os.environ.setdefault('PGPORT', os.environ.get('PGPORT', '5432'))
os.environ.setdefault('PGUSER', os.environ.get('PGUSER', 'postgres'))
os.environ.setdefault('PGDATABASE', os.environ.get('PGDATABASE', 'postgres'))
os.environ.setdefault('PGPASSWORD', os.environ.get('PGPASSWORD', 'postgres'))
PY
}

# Configure environment variables and write to env.sh for reuse
configure_env() {
  log "Configuring environment variables..."

  # Defaults that can be overridden by the user
  export APP_ENV="${APP_ENV:-production}"
  export DBOS_LOG_LEVEL="${DBOS_LOG_LEVEL:-INFO}"

  # Networking defaults for web servers (FastAPI/Uvicorn)
  export HOST="${HOST:-0.0.0.0}"
  export PORT="${PORT:-8000}"

  # Database URL placeholder (psycopg)
  export DATABASE_URL="${DATABASE_URL:-postgresql+psycopg://user:password@localhost:5432/dbname}"

  # OpenTelemetry defaults
  export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-dbos}"
  export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}"
  export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
  export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-none}"

  # Ensure venv is on PATH for subsequent shells
  export VIRTUAL_ENV="$VENV_DIR"
  export PATH="$VENV_DIR/bin:$PATH"
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1
  export PYTHONPATH="$PROJECT_DIR:$PYTHONPATH"

  # Write env to file for re-use
  cat > "$ENV_FILE" <<'EOF'
# Source this file to load environment variables
export APP_ENV="${APP_ENV:-production}"
export DBOS_LOG_LEVEL="${DBOS_LOG_LEVEL:-INFO}"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8000}"
export DATABASE_URL="${DATABASE_URL:-postgresql+psycopg://user:password@localhost:5432/dbname}"
export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-dbos}"
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}"
export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-none}"
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1
# Use project venv if present
if [ -d "${VIRTUAL_ENV:-./.venv}" ]; then
  export VIRTUAL_ENV="${VIRTUAL_ENV:-./.venv}"
  export PATH="$VIRTUAL_ENV/bin:$PATH"
fi
# Ensure current project is importable
if [ -d "$(pwd)" ]; then
  export PYTHONPATH="$(pwd):$PYTHONPATH"
fi
EOF

  chmod 644 "$ENV_FILE"
  log "Environment variables configured. Written to $ENV_FILE"
}

# Set permissions for project directories
set_permissions() {
  # If running as root in Docker (common), set permissive but safe permissions
  if [ "$(id -u)" -eq 0 ]; then
    chmod -R u+rwX,go+rX "$PROJECT_DIR" || true
  else
    warn "Running as non-root. Ensuring current user has access to project directories."
    chmod -R u+rwX "$PROJECT_DIR" || true
  fi
}

# Show usage info for running the CLI or web server
show_usage() {
  log "Setup complete."
  echo "Useful commands:"
  echo "- To load environment in a shell: . \"$ENV_FILE\""
  echo "- To activate virtualenv: . \"$VENV_DIR/bin/activate\""
  echo "- To run the CLI (if installed): dbos --help"
  echo "- To run a FastAPI app (if applicable): uvicorn <module>:<app_variable> --host \"\$HOST\" --port \"\$PORT\""
  echo "  Replace <module>:<app_variable> with your application entrypoint (e.g., mypkg.api:app)."
}

main() {
  prepare_directories
  setup_apt_wrapper
  install_system_packages
  install_and_configure_postgres
  persist_pdm_scm_version
  install_node_and_dbos_cli
  install_opentelemetry_for_dbos
  setup_cache_isolation
  repair_pdm_http_cache
  check_python
  ensure_pdm_on_path
  install_alembic_dependencies
  setup_venv
  install_python_deps
  configure_env
  create_sitecustomize
  set_permissions
  setup_auto_activate
  show_usage
}

main "$@"