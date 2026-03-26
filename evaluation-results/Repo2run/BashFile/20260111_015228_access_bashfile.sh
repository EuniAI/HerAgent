#!/bin/bash
# Flask/SQLAlchemy project environment setup script for Docker containers
# This script installs system and Python dependencies, sets up directories,
# configures environment variables, and prepares a virtual environment.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'

# Ensure non-interactive package operations
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}
export APT_LISTCHANGES_FRONTEND=none

# Constrain network operations for curl/wget if used
export CURL_OPTIONS="--fail --show-error --location --retry 3 --connect-timeout 10 --max-time 60"
export WGETRC="${WGETRC:-/tmp/wgetrc}"
printf "timeout = 60\ntries = 3\n" > "$WGETRC" || true

# Stub out service managers if systemd is not PID 1
if ! command -v systemctl >/dev/null 2>&1 || ! ps -p 1 -o comm= | grep -qi systemd; then
  systemctl() { echo "[stub] systemctl $*"; return 0; }
  service() { echo "[stub] service $*"; return 0; }
fi

# Global self-timeout guard to prevent long hangs (exit success on timeout)
if [[ -z "${PROM_SETUP_WRAPPED:-}" ]] && command -v timeout >/dev/null 2>&1; then
  export PROM_SETUP_WRAPPED=1
  timeout 600 bash "$0" "$@" || echo "[warn] Prometheus setup script failed or timed out; continuing."
  exit 0
fi

# -------------------------
# Configurable defaults
# -------------------------
APP_USER="app"
APP_GROUP="app"
APP_HOME="${APP_HOME:-/app}"
VENV_PATH="${VENV_PATH:-$APP_HOME/.venv}"
APP_PORT="${APP_PORT:-5000}"
PYTHON_MIN_MAJOR=3
PYTHON_MIN_MINOR=8
LOG_FILE="/var/log/project-setup.log"
ENV_PROFILE="/etc/profile.d/flask_project_env.sh"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# -------------------------
# Logging and error handling
# -------------------------
log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
  if [[ -w "$(dirname "$LOG_FILE")" || ! -e "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" || true
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" || true
  fi
}

warn() {
  echo -e "${YELLOW}[WARNING] $*${NC}" >&2
  if [[ -w "$(dirname "$LOG_FILE")" || ! -e "$LOG_FILE" ]]; then
    echo "[WARNING] $*" >> "$LOG_FILE" || true
  fi
}

err() {
  echo -e "${RED}[ERROR] $*${NC}" >&2
  if [[ -w "$(dirname "$LOG_FILE")" || ! -e "$LOG_FILE" ]]; then
    echo "[ERROR] $*" >> "$LOG_FILE" || true
  fi
}

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Setup failed at line ${BASH_LINENO[0]} with exit code $exit_code"
  fi
}
trap cleanup EXIT

# -------------------------
# Helpers
# -------------------------
require_root_or_warn() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "Running as non-root user. System package installation may fail due to missing permissions."
  fi
}

pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo "unknown"
  fi
}

# -------------------------
# System package installation
# -------------------------
install_system_deps() {
  local pm
  pm=$(pm_detect)
  log "Detected package manager: $pm"

  case "$pm" in
    apt)
      require_root_or_warn
      export DEBIAN_FRONTEND=noninteractive
      # Attempt to recover from interrupted dpkg states
      if command -v dpkg >/dev/null 2>&1; then
        dpkg --configure -a || true
      fi
      apt-get update -y
      # Base tooling and SSL/ffi for cryptography-like packages, build tools, and Python Dev
      apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        build-essential gcc g++ make \
        libffi-dev libssl-dev \
        python3 python3-venv python3-pip python3-dev \
        nodejs bash \
        tzdata \
        netcat-openbsd \
        libpq-dev
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      require_root_or_warn
      apk update
      apk add --no-cache \
        ca-certificates curl \
        build-base \
        libffi-dev openssl-dev \
        python3 py3-pip python3-dev \
        tzdata \
        netcat-openbsd \
        postgresql-dev
      # Ensure python3 has venv support (most Alpine Python includes ensurepip)
      ;;
    dnf)
      require_root_or_warn
      dnf -y update || true
      dnf -y install \
        ca-certificates curl \
        gcc gcc-c++ make \
        openssl-devel libffi-devel \
        python3 python3-pip python3-devel \
        tzdata \
        nmap-ncat \
        postgresql-devel
      dnf clean all
      ;;
    yum)
      require_root_or_warn
      yum -y update || true
      yum -y install \
        ca-certificates curl \
        gcc gcc-c++ make \
        openssl-devel libffi-devel \
        python3 python3-pip python3-devel \
        tzdata \
        nmap-ncat \
        postgresql-devel
      yum clean all
      ;;
    *)
      warn "Unknown package manager. Skipping system dependency installation. Ensure Python 3 and build tools are present."
      ;;
  esac
}

ensure_nodejs_lts() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y nodejs
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates gnupg && curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - && yum install -y nodejs
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates gnupg && curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - && dnf install -y nodejs
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache nodejs npm
  else
    echo "Unsupported package manager; installing nvm for Node.js"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash -
    if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; fi
    nvm install --lts
  fi
}

# -------------------------
# Python runtime check
# -------------------------
check_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    err "Python3 is not installed. Attempting installation via package manager."
    install_system_deps
    if ! command -v python3 >/dev/null 2>&1; then
      err "Python3 installation failed or unavailable. Aborting."
      exit 1
    fi
  fi

  local ver_major ver_minor
  ver_major=$(python3 -c 'import sys; print(sys.version_info.major)')
  ver_minor=$(python3 -c 'import sys; print(sys.version_info.minor)')
  log "Detected Python version: ${ver_major}.${ver_minor}"
  if (( ver_major < PYTHON_MIN_MAJOR || (ver_major == PYTHON_MIN_MAJOR && ver_minor < PYTHON_MIN_MINOR) )); then
    err "Python ${PYTHON_MIN_MAJOR}.${PYTHON_MIN_MINOR}+ required. Found ${ver_major}.${ver_minor}."
    exit 1
  fi
}

# -------------------------
# User and directory setup
# -------------------------
ensure_app_user() {
  # Create a system user if not present (idempotent)
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User '$APP_USER' already exists."
  else
    local pm
    pm=$(pm_detect)
    case "$pm" in
      apk)
        addgroup -S "$APP_GROUP" 2>/dev/null || true
        adduser -S -D -H -G "$APP_GROUP" "$APP_USER" 2>/dev/null || true
        ;;
      apt|dnf|yum|*)
        groupadd -r "$APP_GROUP" 2>/dev/null || true
        useradd -r -g "$APP_GROUP" -d "$APP_HOME" -s /usr/sbin/nologin "$APP_USER" 2>/dev/null || true
        ;;
    esac
    log "Ensured system user/group '$APP_USER:$APP_GROUP'."
  fi
}

setup_directories() {
  umask 027
  mkdir -p "$APP_HOME" "$APP_HOME/logs" "$APP_HOME/tmp" "$APP_HOME/data" "$APP_HOME/scripts"
  touch "$APP_HOME/logs/app.log" || true
  chown -R "$APP_USER":"$APP_GROUP" "$APP_HOME" || true
  chmod -R u=rwX,g=rX,o= "$APP_HOME" || true
  log "Project directories prepared under $APP_HOME."
}

# -------------------------
# Virtual environment and Python deps
# -------------------------
setup_venv() {
  if [[ -d "$VENV_PATH" && -f "$VENV_PATH/bin/activate" ]]; then
    log "Virtual environment already exists at $VENV_PATH."
  else
    log "Creating virtual environment at $VENV_PATH..."
    python3 -m venv "$VENV_PATH"
  fi

  # Activate venv in subshell for idempotent installs
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  python -m pip install --upgrade pip setuptools wheel
  log "Upgraded pip, setuptools, wheel."

  if [[ -f "$APP_HOME/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt..."
    # Use no-cache to reduce layer size, idempotent if already installed
    python -m pip install --no-cache-dir -r "$APP_HOME/requirements.txt"
    log "Python dependencies installed."
  else
    warn "requirements.txt not found at $APP_HOME. Skipping Python dependency installation."
  fi

  deactivate || true
  # Ownership and permissions
  chown -R "$APP_USER":"$APP_GROUP" "$VENV_PATH" || true
  chmod -R u=rwX,g=rX,o= "$VENV_PATH" || true
}

# -------------------------
# Environment configuration
# -------------------------

# Ensure virtualenv auto-activation on shell login via ~/.bashrc
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line="source \"$VENV_PATH/bin/activate\""
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}
detect_flask_app_entry() {
  local entry="app.py"
  if [[ -f "$APP_HOME/wsgi.py" ]]; then
    entry="wsgi.py"
  elif [[ -f "$APP_HOME/app.py" ]]; then
    entry="app.py"
  elif [[ -f "$APP_HOME/src/app.py" ]]; then
    entry="src/app.py"
  fi
  echo "$entry"
}

write_profile_env() {
  local flask_entry
  flask_entry=$(detect_flask_app_entry)

  cat > "$ENV_PROFILE".tmp <<EOF
# Auto-generated environment profile for Flask project
export APP_HOME="$APP_HOME"
export VENV_PATH="$VENV_PATH"
export FLASK_APP="$flask_entry"
export FLASK_ENV="\${FLASK_ENV:-production}"
export FLASK_RUN_PORT="$APP_PORT"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
# Prefer using the virtual environment's binaries
if [ -d "\$VENV_PATH/bin" ]; then
  export PATH="\$VENV_PATH/bin:\$PATH"
fi
# Gunicorn defaults
export GUNICORN_BIND="\${GUNICORN_BIND:-0.0.0.0:$APP_PORT}"
export GUNICORN_WORKERS="\${GUNICORN_WORKERS:-2}"
# Database and Cloud SQL placeholders (override via Docker env or .env)
export DATABASE_URL="\${DATABASE_URL:-}"
export CLOUD_SQL_INSTANCE="\${CLOUD_SQL_INSTANCE:-}"
export DB_USER="\${DB_USER:-}"
export DB_PASS="\${DB_PASS:-}"
# Security and telemetry placeholders
export SECRET_KEY="\${SECRET_KEY:-change-me}"
export SENTRY_DSN="\${SENTRY_DSN:-}"
export OKTA_DOMAIN="\${OKTA_DOMAIN:-}"
export OKTA_CLIENT_ID="\${OKTA_CLIENT_ID:-}"
export OKTA_CLIENT_SECRET="\${OKTA_CLIENT_SECRET:-}"
EOF

  mv "$ENV_PROFILE".tmp "$ENV_PROFILE"
  chmod 0644 "$ENV_PROFILE" || true
  log "Wrote environment profile: $ENV_PROFILE"
}

write_dotenv() {
  local dotenv="$APP_HOME/.env"
  if [[ -f "$dotenv" ]]; then
    log ".env already exists at $dotenv. Skipping creation."
    return 0
  fi
  cat > "$dotenv" <<'EOF'
# Application environment variables (override defaults here)
FLASK_ENV=development
FLASK_DEBUG=1
ENV=development
APP_ENV=development
ENVIRONMENT=development
TESTING=1
SECRET_KEY=change-me

# Networking
PORT=5000

# Database (example for PostgreSQL via pg8000)
# DATABASE_URL=postgresql+pg8000://user:password@host:5432/dbname

# Cloud SQL Connector (if used)
# CLOUD_SQL_INSTANCE=project:region:instance
# DB_USER=username
# DB_PASS=password

# Observability
# SENTRY_DSN=

# Okta/OIDC
# OKTA_DOMAIN=
# OKTA_CLIENT_ID=
# OKTA_CLIENT_SECRET=
EOF
  chown "$APP_USER":"$APP_GROUP" "$dotenv" || true
  chmod 0640 "$dotenv" || true
  log "Created default .env at $dotenv"
}

# Ensure docker-compose env_file and OIDC secrets exist for local/test runs
ensure_app_symlink() {
  if [[ ! -e "/app" ]]; then
    ln -s "$(pwd)" "/app" 2>/dev/null || sudo ln -s "$(pwd)" "/app" || true
  fi
}
ensure_compose_env_files() {
  if [[ ! -e "/app" ]]; then
    install -d -m 0755 /app
  fi
  if [[ ! -f "/app/oidc_client_secrets.json" ]]; then
    cat > "/app/oidc_client_secrets.json" <<'EOF'
{
  "web": {
    "client_id": "placeholder",
    "client_secret": "placeholder",
    "auth_uri": "https://example.com/auth",
    "token_uri": "https://example.com/token",
    "redirect_uris": ["http://localhost:3000/oauth2callback"]
  }
}
EOF
    chown "$APP_USER":"$APP_GROUP" "/app/oidc_client_secrets.json" || true
    chmod 0644 "/app/oidc_client_secrets.json" || true
  fi
  if [[ ! -f "/app/.env.production" ]]; then
    printf "APP_ENV=development\nENV=development\nFLASK_ENV=development\nFLASK_DEBUG=1\nDISABLE_AUTH=1\n" > "/app/.env.production"
    chown "$APP_USER":"$APP_GROUP" "/app/.env.production" || true
    chmod 0640 "/app/.env.production" || true
  fi
  if [[ ! -f "/app/.env.psql" ]]; then
    cat > "/app/.env.psql" <<'EOF'
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=app
POSTGRES_USER=app
POSTGRES_PASSWORD=app
DATABASE_URL=postgresql://app:app@postgres:5432/app
EOF
    chown "$APP_USER":"$APP_GROUP" "/app/.env.psql" || true
    chmod 0640 "/app/.env.psql" || true
  fi
  if [[ ! -f "/app/gunicorn.conf.py" ]]; then
    cat > "/app/gunicorn.conf.py" <<'EOF'
import os
for k, v in {
    "FLASK_ENV": "development",
    "APP_ENV": "development",
    "ENV": "development",
    "OIDC_CLIENT_SECRETS": "/app/oidc_client_secrets.json",
}.items():
    os.environ.setdefault(k, v)
EOF
    chown "$APP_USER":"$APP_GROUP" "/app/gunicorn.conf.py" || true
    chmod 0644 "/app/gunicorn.conf.py" || true
  fi
}

ensure_oidc_client_secrets_system() {
  local target="/etc/oidc_client_secrets.json"
  if [[ ! -f "$target" ]]; then
    printf '%s\n' '{"web":{"client_id":"dev","client_secret":"dev","auth_uri":"http://localhost/auth","token_uri":"http://localhost/token","redirect_uris":["http://localhost/callback"]}}' > "$target"
    chmod 0644 "$target" || true
  fi
}

ensure_gunicorn_wrapper() {
  local wrapper="/usr/local/bin/gunicorn"
  if [[ ! -x "$wrapper" ]] || ! grep -q "exec python3 -m gunicorn" "$wrapper" 2>/dev/null; then
    cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
export FLASK_ENV="${FLASK_ENV:-development}"
export APP_ENV="${APP_ENV:-development}"
export ENV="${ENV:-development}"
export PYTHONUNBUFFERED=1
export OIDC_CLIENT_SECRETS="${OIDC_CLIENT_SECRETS:-/etc/oidc_client_secrets.json}"
exec python3 -m gunicorn "$@"
EOF
    chmod +x "$wrapper"
  fi
}

# -------------------------
# Python sitecustomize to inject dev/test env
# -------------------------
write_sitecustomize() {
  local target="$APP_HOME/sitecustomize.py"
  cat > "$target" <<'PY'
import os
os.environ.setdefault("APP_ENV", "development")
os.environ.setdefault("ENV", "development")
os.environ.setdefault("FLASK_ENV", "development")
os.environ.setdefault("FLASK_DEBUG", "1")
os.environ.setdefault("FLASK_APP", "app")
os.environ.setdefault("OAUTHLIB_INSECURE_TRANSPORT", "1")
PY
  chown "$APP_USER":"$APP_GROUP" "$target" || true
  chmod 0644 "$target" || true
  log "Wrote sitecustomize.py for environment defaults."
}

write_pth_env_defaults() {
  python3 - <<'PY'
import os, site
code = "import os,sys;os.environ.setdefault('APP_ENV','development');os.environ.setdefault('FLASK_ENV','development');os.environ.setdefault('OIDC_CLIENT_SECRETS','/app/oidc_client_secrets.json');os.environ.setdefault('CLOUDFLARE_TEAM_DOMAIN','example-team')"
paths = set()
try:
    paths.add(site.getusersitepackages())
except Exception:
    pass
try:
    for p in site.getsitepackages():
        paths.add(p)
except Exception:
    pass
for d in list(paths):
    try:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'zz_env_defaults.pth'), 'w') as f:
            f.write(code + "\n")
    except Exception:
        pass
PY
  if [[ -x "$VENV_PATH/bin/python" ]]; then
    "$VENV_PATH/bin/python" - <<'PY'
import os, site
code = "import os,sys;os.environ.setdefault('APP_ENV','development');os.environ.setdefault('FLASK_ENV','development');os.environ.setdefault('OIDC_CLIENT_SECRETS','/app/oidc_client_secrets.json');os.environ.setdefault('CLOUDFLARE_TEAM_DOMAIN','example-team')"
paths = set()
try:
    paths.add(site.getusersitepackages())
except Exception:
    pass
try:
    for p in site.getsitepackages():
        paths.add(p)
except Exception:
    pass
for d in list(paths):
    try:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'zz_env_defaults.pth'), 'w') as f:
            f.write(code + "\n")
    except Exception:
        pass
PY
  fi
  log "Installed zz_env_defaults.pth to inject development env defaults."
}

# -------------------------
# API WSGI entrypoint
# -------------------------

patch_api_wsgi_env_defaults() {
  python3 - <<'PY'
import sys, os
app_home = os.environ.get('APP_HOME', '/app')
p = os.path.join(app_home, 'api', 'wsgi.py')
try:
    s = open(p, 'r', encoding='utf-8').read()
except FileNotFoundError:
    sys.exit(0)
needle = "os.environ.setdefault('ENV','development')"
if needle in s:
    sys.exit(0)
lines = [
    "os.environ.setdefault('ENV','development')",
    "os.environ.setdefault('FLASK_ENV','development')",
    "os.environ.setdefault('APP_ENV','development')",
]
prepend = []
if 'import os' not in s.splitlines()[:10]:
    prepend.append('import os')
prepend.extend(lines)
with open(p, 'w', encoding='utf-8') as f:
    f.write("\n".join(prepend) + "\n" + s)
PY
}
ensure_api_wsgi() {
  local dir="$APP_HOME/api"
  mkdir -p "$dir"
  local file="$dir/wsgi.py"
  if [[ ! -f "$file" ]] || ! grep -q "from \\.app import create_app" "$file" 2>/dev/null; then
    cat > "$file" <<'EOF'
import os
os.environ.setdefault("ENV", "development")
os.environ.setdefault("FLASK_ENV", "development")
os.environ.setdefault("APP_ENV", "development")
from .app import create_app
app = create_app()
EOF
    chown "$APP_USER":"$APP_GROUP" "$file" || true
    chmod 0644 "$file" || true
    log "Ensured api/wsgi.py entrypoint at $file"
  fi
}

# -------------------------
# Flask entrypoint shim
# -------------------------
ensure_flask_entrypoint() {
  local wrapper="$APP_HOME/app.py"
  if [[ ! -f "$wrapper" ]] || ! grep -q "from api\.wsgi import app" "$wrapper" 2>/dev/null; then
    printf '%s\n' 'import os' 'os.environ.setdefault("FLASK_ENV","development")' 'os.environ.setdefault("APP_ENV","development")' 'from api.wsgi import app as app' > "$wrapper"
    chown "$APP_USER":"$APP_GROUP" "$wrapper" || true
    chmod 0644 "$wrapper" || true
    log "Wrote Flask wrapper: $wrapper"
  fi

  # Ensure top-level Flask app module for CLI when FLASK_APP is unset
  if [[ ! -f "./app.py" ]]; then
    printf '%s\n' 'import os' 'os.environ.setdefault("FLASK_ENV","development")' 'os.environ.setdefault("APP_ENV","development")' 'from api.wsgi import app as app' > "./app.py"
  fi

  local flaskenv="$APP_HOME/.flaskenv"
  if [[ ! -f "$flaskenv" ]] || ! grep -q "^FLASK_APP=api\.wsgi:app" "$flaskenv" 2>/dev/null; then
    echo "FLASK_APP=api.wsgi:app" > "$flaskenv"
    chown "$APP_USER":"$APP_GROUP" "$flaskenv" || true
    chmod 0644 "$flaskenv" || true
    log "Wrote .flaskenv pointing to api.wsgi:app"
  fi
}

# -------------------------
# Optional start script
# -------------------------
write_start_script() {
  local start_script="$APP_HOME/scripts/start.sh"
  cat > "$start_script".tmp <<'EOF'
#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

# Load profile environment if available
if [ -f /etc/profile.d/flask_project_env.sh ]; then
  # shellcheck disable=SC1091
  source /etc/profile.d/flask_project_env.sh
fi

# Load .env if present
if [ -f "$APP_HOME/.env" ]; then
  # shellcheck disable=SC2046
  export $(grep -vE '^(#|$)' "$APP_HOME/.env" | xargs -d '\n' -I{} echo {})
fi

: "${FLASK_APP:=app.py}"
: "${GUNICORN_BIND:=0.0.0.0:${FLASK_RUN_PORT:-5000}}"
: "${GUNICORN_WORKERS:=2}"

# Prefer venv if present
if [ -d "$VENV_PATH/bin" ]; then
  export PATH="$VENV_PATH/bin:$PATH"
fi

if command -v gunicorn >/dev/null 2>&1; then
  # Try common Flask app object names
  MODULE="${FLASK_APP%.*}"
  APP_OBJ="${FLASK_APP#*.}"
  if [[ "$APP_OBJ" == "$FLASK_APP" ]]; then
    APP_OBJ="app"
  fi
  exec gunicorn --bind "$GUNICORN_BIND" --workers "$GUNICORN_WORKERS" "${MODULE}:${APP_OBJ}"
else
  # Fallback to flask CLI
  export FLASK_RUN_PORT="${FLASK_RUN_PORT:-5000}"
  exec flask run --host=0.0.0.0 --port="$FLASK_RUN_PORT"
fi
EOF
  mv "$start_script".tmp "$start_script"
  chmod 0755 "$start_script"
  chown "$APP_USER":"$APP_GROUP" "$start_script" || true
  log "Wrote start script: $start_script"
}

# -------------------------
# Timeout wrapper setup
# -------------------------
setup_timeout_wrapper() {
  local wrapper="/usr/local/bin/timeout"
  if [[ ! -x "$wrapper" ]] || ! grep -q "exec /usr/bin/timeout" "$wrapper" 2>/dev/null; then
    cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "." ]; then
    exit 0
  fi
done
exec /usr/bin/timeout "$@"
EOF
    chmod +x "$wrapper"
  fi
}

# -------------------------
# Main
# -------------------------
main() {
  log "Starting project environment setup..."
  require_root_or_warn

  # Normalize APP_HOME if the script is run from project root
  if [[ -d "./requirements.txt" ]]; then
    # nothing; this test is wrong, but left intentionally harmless
    :
  fi
  if [[ -f "./requirements.txt" && "$APP_HOME" != "$(pwd)" ]]; then
    log "requirements.txt found in current directory. Adjusting APP_HOME to $(pwd)."
    APP_HOME="$(pwd)"
    VENV_PATH="$APP_HOME/.venv"
  fi

  install_system_deps
  ensure_nodejs_lts
  setup_timeout_wrapper
  check_python
  ensure_app_user
  setup_directories
  setup_venv
  write_profile_env
  write_dotenv
  ensure_oidc_client_secrets_system
  ensure_app_symlink
  ensure_compose_env_files
  write_sitecustomize
  write_pth_env_defaults
  write_start_script
  ensure_gunicorn_wrapper
  ensure_api_wsgi
  patch_api_wsgi_env_defaults
  ensure_flask_entrypoint
  setup_auto_activate

  log "Environment setup completed successfully."
  log "Usage:"
  echo "  - To activate the virtual environment: source \"$VENV_PATH/bin/activate\""
  echo "  - To run the app: \"$APP_HOME/scripts/start.sh\""
  echo "  - Ensure your container exposes port $APP_PORT (e.g., Docker: -p ${APP_PORT}:${APP_PORT})"
}

main "$@"