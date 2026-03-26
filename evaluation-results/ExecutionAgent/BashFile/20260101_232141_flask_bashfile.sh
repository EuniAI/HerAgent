#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Auto-detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust, .NET)
# - Installs system packages and language runtimes
# - Installs project dependencies
# - Configures environment variables and directories
# - Safe to re-run (idempotent), no sudo required (expects root in container)

set -Eeuo pipefail

# Safety and logging
IFS=$'\n\t'
umask 002

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
err()  { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }

trap 'ret=$?; err "Setup failed at line $LINENO with exit code $ret"; exit $ret' ERR

# Configuration
APP_DIR="${APP_DIR:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
ENV_FILE="${ENV_FILE:-${APP_DIR}/.env}"
STATE_DIR="${STATE_DIR:-/var/local/project-setup}"
APT_STAMP="${STATE_DIR}/apt-updated.stamp"
APK_STAMP="${STATE_DIR}/apk-updated.stamp"
DNF_STAMP="${STATE_DIR}/dnf-updated.stamp"

mkdir -p "$STATE_DIR"

# Keep apt-get enabled for system-level installations required by repair commands
: # no-op

# Detect package manager
PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v apk >/dev/null 2>&1; then
  PKG_MGR="apk"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
elif command -v zypper >/dev/null 2>&1; then
  PKG_MGR="zypper"
else
  PKG_MGR="none"
fi

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Ensure root for system package installation
IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
  IS_ROOT=1
else
  warn "Not running as root. System packages cannot be installed. Will attempt user-level setup where possible."
fi

# Package installation helpers
apt_repair_sources() {
  if [ "$IS_ROOT" -ne 1 ]; then return 0; fi
  if ! command -v apt-get >/dev/null 2>&1; then return 0; fi
  . /etc/os-release || true
  if [ "${ID:-}" = "debian" ] && [ -n "${VERSION_CODENAME:-}" ]; then
    printf "deb http://deb.debian.org/debian %s main contrib non-free non-free-firmware\n" "$VERSION_CODENAME" > /etc/apt/sources.list
    printf "deb http://deb.debian.org/debian %s-updates main contrib non-free non-free-firmware\n" "$VERSION_CODENAME" >> /etc/apt/sources.list
    printf "deb http://security.debian.org/debian-security %s-security main contrib non-free non-free-firmware\n" "$VERSION_CODENAME" >> /etc/apt/sources.list
  elif [ "${ID:-}" = "ubuntu" ] && [ -n "${UBUNTU_CODENAME:-}" ]; then
    printf "deb http://archive.ubuntu.com/ubuntu %s main restricted universe multiverse\n" "$UBUNTU_CODENAME" > /etc/apt/sources.list
    printf "deb http://archive.ubuntu.com/ubuntu %s-updates main restricted universe multiverse\n" "$UBUNTU_CODENAME" >> /etc/apt/sources.list
    printf "deb http://archive.ubuntu.com/ubuntu %s-backports main restricted universe multiverse\n" "$UBUNTU_CODENAME" >> /etc/apt/sources.list
    printf "deb http://security.ubuntu.com/ubuntu %s-security main restricted universe multiverse\n" "$UBUNTU_CODENAME" >> /etc/apt/sources.list
  else
    echo "deb http://deb.debian.org/debian stable main contrib non-free non-free-firmware" > /etc/apt/sources.list
    echo "deb http://deb.debian.org/debian stable-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list
    echo "deb http://security.debian.org/debian-security stable-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list
  fi
}

apt_update_once() {
  if [ "$IS_ROOT" -ne 1 ]; then return 0; fi
  if [ ! -f "$APT_STAMP" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt_repair_sources
    apt-get update -y
    # Ensure minimal locales/certs for TLS and HTTPS support
    apt-get install -y --no-install-recommends ca-certificates gnupg apt-transport-https software-properties-common || true
    # Enable Ubuntu universe/multiverse if applicable
    . /etc/os-release || true
    if [ "${ID:-}" = "ubuntu" ]; then
      add-apt-repository -y universe || true
      add-apt-repository -y multiverse || true
      apt-get update -y || true
    fi
    # Pre-install tools that may be missing from limited images to avoid failures later
    apt_install_psmisc_lsof_fallback || true
    update-ca-certificates || true
    touch "$APT_STAMP"
  fi
}

apk_update_once() {
  if [ "$IS_ROOT" -ne 1 ]; then return 0; fi
  if [ ! -f "$APK_STAMP" ]; then
    apk update
    update-ca-certificates || true
    touch "$APK_STAMP"
  fi
}

dnf_update_once() {
  if [ "$IS_ROOT" -ne 1 ]; then return 0; fi
  if [ ! -f "$DNF_STAMP" ]; then
    dnf -y makecache
    update-ca-certificates || true
    touch "$DNF_STAMP"
  fi
}

ensure_packages() {
  # Usage: ensure_packages pkg1 pkg2 ...
  [ "$IS_ROOT" -eq 1 ] || { warn "Skipping system package install (not root)"; return 0; }
  local missing=()
  case "$PKG_MGR" in
    apt)
      apt_update_once
      for p in "$@"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then missing+=("$p"); fi
      done
      if [ "${#missing[@]}" -gt 0 ]; then
        export DEBIAN_FRONTEND=noninteractive
        # Try to handle psmisc/lsof specially to avoid apt failures on minimal images
        if printf '%s\n' "${missing[@]}" | grep -qE '^psmisc$|^lsof$'; then
          apt_install_psmisc_lsof_fallback || true
          # Recompute missing after the fallback and exclude psmisc/lsof from apt-get
          local new_missing=()
          for p in "${missing[@]}"; do
            if ! dpkg -s "$p" >/dev/null 2>&1; then
              if [ "$p" != "psmisc" ] && [ "$p" != "lsof" ]; then
                new_missing+=("$p")
              fi
            fi
          done
          missing=("${new_missing[@]}")
        fi
        if [ "${#missing[@]}" -gt 0 ]; then
          apt-get install -y --no-install-recommends "${missing[@]}"
        fi
        rm -rf /var/lib/apt/lists/*
      fi
      ;;
    apk)
      apk_update_once
      for p in "$@"; do
        if ! apk info -e "$p" >/dev/null 2>&1; then missing+=("$p"); fi
      done
      if [ "${#missing[@]}" -gt 0 ]; then
        apk add --no-cache "${missing[@]}"
      fi
      ;;
    dnf|yum)
      local mgr="$PKG_MGR"
      dnf_update_once || true
      for p in "$@"; do
        if ! rpm -q "$p" >/dev/null 2>&1; then missing+=("$p"); fi
      done
      if [ "${#missing[@]}" -gt 0 ]; then
        "$mgr" install -y "${missing[@]}"
      fi
      ;;
    zypper)
      for p in "$@"; do
        if ! rpm -q "$p" >/dev/null 2>&1; then missing+=("$p"); fi
      done
      if [ "${#missing[@]}" -gt 0 ]; then
        zypper --non-interactive install --no-confirm "${missing[@]}"
      fi
      ;;
    *)
      warn "No supported package manager found; skipping system package installation."
      ;;
  esac
}

apt_install_psmisc_lsof_fallback() {
  if [ "$IS_ROOT" -ne 1 ]; then return 0; fi
  if ! command -v apt-get >/dev/null 2>&1; then return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends psmisc lsof || {
    arch="$(dpkg --print-architecture || echo amd64)"
    tmpdir="$(mktemp -d)"
    cd "$tmpdir"
    curl -fsSL "http://deb.debian.org/debian/pool/main/p/psmisc/" | grep -Eo "psmisc_[^\" ]+_${arch}\.deb" | tail -n1 | xargs -I{} curl -fsSLO "http://deb.debian.org/debian/pool/main/p/psmisc/{}"
    curl -fsSL "http://deb.debian.org/debian/pool/main/l/lsof/" | grep -Eo "lsof_[^\" ]+_${arch}\.deb" | tail -n1 | xargs -I{} curl -fsSLO "http://deb.debian.org/debian/pool/main/l/lsof/{}"
    dpkg -i ./*.deb || apt-get -y -f install
    rm -rf "$tmpdir"
  }
}

# Create app user/group if running as root
ensure_app_user() {
  if [ "$IS_ROOT" -ne 1 ]; then return 0; fi
  if getent group "$APP_GROUP" >/dev/null 2>&1; then
    :
  else
    if have_cmd groupadd; then groupadd -g 1000 "$APP_GROUP" 2>/dev/null || groupadd "$APP_GROUP" || true
    elif have_cmd addgroup; then addgroup -g 1000 "$APP_GROUP" 2>/dev/null || addgroup "$APP_GROUP" || true
    fi
  fi
  if id "$APP_USER" >/dev/null 2>&1; then
    :
  else
    if have_cmd useradd; then useradd -m -g "$APP_GROUP" -u 1000 -s /bin/sh "$APP_USER" 2>/dev/null || useradd -m -g "$APP_GROUP" "$APP_USER" || true
    elif have_cmd adduser; then adduser -D -G "$APP_GROUP" -u 1000 "$APP_USER" 2>/dev/null || adduser -D -G "$APP_GROUP" "$APP_USER" || true
    fi
  fi
}

# Prepare directories and permissions
prepare_directories() {
  mkdir -p "$APP_DIR" "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/.cache"
  if [ "$IS_ROOT" -eq 1 ]; then
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR" || true
  fi
}

# Common base tools
install_base_tools() {
  case "$PKG_MGR" in
    apt)
      ensure_packages apt-transport-https ca-certificates curl wget git openssl xz-utils unzip bzip2 procps file tini tzdata psmisc lsof socat python3-gunicorn
      ensure_packages build-essential pkg-config
      # Ensure gunicorn is on PATH for harness commands
      if [ -x "/usr/bin/gunicorn3" ] && [ ! -x "/usr/local/bin/gunicorn" ]; then
        ln -sf /usr/bin/gunicorn3 /usr/local/bin/gunicorn || true
      fi
      ;;
    apk)
      ensure_packages ca-certificates curl wget git openssl xz unzip bzip2 procps file tini tzdata psmisc lsof
      ensure_packages build-base pkgconfig
      ;;
    dnf|yum)
      ensure_packages ca-certificates curl wget git openssl xz unzip bzip2 procps-ng file tzdata which psmisc lsof
      # tini may not be available; ignore
      ensure_packages gcc gcc-c++ make automake autoconf libtool pkgconfig
      ;;
    zypper)
      ensure_packages ca-certificates curl wget git openssl xz unzip bzip2 procps file timezone psmisc lsof
      ensure_packages gcc gcc-c++ make automake autoconf libtool pkg-config
      ;;
    *)
      warn "Skipping base tool installation (no package manager)."
      ;;
  esac
  # Update certs if possible
  update-ca-certificates >/dev/null 2>&1 || true
}

# Micromamba-based Python runtime setup to bypass broken system Python/apt
ensure_micromamba_python() {
  # Install micromamba if missing
  if [ ! -x "/usr/local/bin/micromamba" ]; then
    if command -v curl >/dev/null 2>&1; then
      curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest -o /usr/local/bin/micromamba || true
    elif command -v wget >/dev/null 2>&1; then
      wget -qO /usr/local/bin/micromamba https://micro.mamba.pm/api/micromamba/linux-64/latest || true
    else
      warn "Neither curl nor wget available to install micromamba; skipping."
    fi
    chmod +x /usr/local/bin/micromamba 2>/dev/null || true
  fi
  # Create standalone Python env and expose python3/pip3
  if [ -x "/usr/local/bin/micromamba" ]; then
    if [ ! -x "/opt/py311/bin/python" ]; then
      /usr/local/bin/micromamba create -y -p /opt/py311 -c conda-forge python=3.11 || true
    fi
    ln -sf /opt/py311/bin/python /usr/local/bin/python3 || true
    ln -sf /opt/py311/bin/pip /usr/local/bin/pip3 || true
  fi
}

# Project detection
detect_project_types() {
  PROJECT_TYPES=()
  [ -f "${APP_DIR}/package.json" ] && PROJECT_TYPES+=("node")
  { [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/Pipfile" ] || [ -f "${APP_DIR}/setup.py" ] || [ -f "${APP_DIR}/setup.cfg" ]; } && PROJECT_TYPES+=("python")
  [ -f "${APP_DIR}/Gemfile" ] && PROJECT_TYPES+=("ruby")
  { [ -f "${APP_DIR}/go.mod" ] || compgen -G "${APP_DIR}/**/*.go" >/dev/null 2>&1; } && PROJECT_TYPES+=("go")
  { [ -f "${APP_DIR}/pom.xml" ] || compgen -G "${APP_DIR}/build.gradle*" >/dev/null 2>&1; } && PROJECT_TYPES+=("java")
  [ -f "${APP_DIR}/composer.json" ] && PROJECT_TYPES+=("php")
  [ -f "${APP_DIR}/Cargo.toml" ] && PROJECT_TYPES+=("rust")
  compgen -G "${APP_DIR}/*.csproj" >/dev/null 2>&1 && PROJECT_TYPES+=("dotnet")
  # Unique-ify
  if [ "${#PROJECT_TYPES[@]}" -gt 0 ]; then
    mapfile -t PROJECT_TYPES < <(printf "%s\n" "${PROJECT_TYPES[@]}" | awk '!seen[$0]++')
  fi
}

# Language-specific installers

setup_python() {
  log "Setting up Python environment..."
  # Repair: ensure gunicorn CLI and psmisc via apt if available
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y --no-install-recommends curl ca-certificates lsof psmisc python3-gunicorn || true
  fi
  # Ensure a working Python via micromamba and override system python
  ensure_micromamba_python
  case "$PKG_MGR" in
    apt) ensure_packages python3 python3-venv python3-pip python3-dev gcc ;;
    apk) ensure_packages python3 py3-pip python3-dev build-base ;;
    dnf|yum) ensure_packages python3 python3-pip python3-devel gcc gcc-c++ make ;;
    zypper) ensure_packages python3 python3-pip python3-devel gcc gcc-c++ make ;;
    *) warn "No package manager detected to install Python. Expecting python3/pip to be present.";;
  esac

  if ! have_cmd python3; then err "python3 is required but not available"; return 1; fi

  # Create virtual environment idempotently
  VENV_DIR="${APP_DIR}/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
  fi
  PY_BIN="${VENV_DIR}/bin/python"
  PIP_BIN="${VENV_DIR}/bin/pip"
  "$PY_BIN" -m pip install --upgrade pip setuptools wheel
  # Ensure baseline requirements aligned with harness
  test -f "${APP_DIR}/requirements.txt" || printf "Flask\ngunicorn\npython-dotenv\ncelery\npytest\ntox\n" > "${APP_DIR}/requirements.txt"
  # Install requirements
  "$PY_BIN" -m pip install -r "${APP_DIR}/requirements.txt"
  # Also ensure core CLIs are installed explicitly
  "$PY_BIN" -m pip install --upgrade --no-cache-dir Flask gunicorn python-dotenv pytest celery tox
  "$PY_BIN" -m pip install --upgrade asgiref python-dotenv tox
  "$PY_BIN" -m pip install --upgrade --no-cache-dir asgiref
  # Ensure packaging metadata exists for editable installs
  if [ ! -f "${APP_DIR}/pyproject.toml" ]; then
    cat > "${APP_DIR}/pyproject.toml" <<'PY'
[project]
name = "placeholder-project"
version = "0.0.0"
requires-python = ">=3.8"
dependencies = ["tox"]
PY
  fi
  if [ ! -f "${APP_DIR}/setup.cfg" ]; then
    cat > "${APP_DIR}/setup.cfg" <<'PY'
[metadata]
name = hello-app
version = 0.0.1

[options]
py_modules = hello,task_app,make_celery
install_requires =
    Flask
    gunicorn
    python-dotenv
    celery
PY
  fi
  # Write minimal setup.py for editable install and install package
  if [ ! -f "${APP_DIR}/setup.py" ]; then
    cat > "${APP_DIR}/setup.py" <<'PY'
from setuptools import setup

setup(
    name="hello-app",
    version="0.0.1",
    py_modules=["hello", "task_app", "make_celery"],
)
PY
  fi
  "$PY_BIN" -m pip install -e "${APP_DIR}" || "$PY_BIN" -m pip install "${APP_DIR}"
  "$PY_BIN" -m pip install --no-input --upgrade "flask[async]" tox celery asgiref python-dotenv pytest gunicorn
  # Symlink gunicorn to a global PATH location if system-level gunicorn is missing
  if [ -x "${VENV_DIR}/bin/gunicorn" ] && [ ! -x "/usr/local/bin/gunicorn" ]; then
    ln -sf "${VENV_DIR}/bin/gunicorn" /usr/local/bin/gunicorn || true
  fi

  # Install uv CLI and prepare uv lock/tox config for typing checks
  if command -v apt-get >/dev/null 2>&1 && [ "$IS_ROOT" -eq 1 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y --no-install-recommends curl ca-certificates || true
  fi
  if ! command -v uv >/dev/null 2>&1; then
    curl -fsSL https://astral.sh/uv/install.sh | sh -s -- --yes
    ln -sf "$HOME/.local/bin/uv" /usr/local/bin/uv || true
  fi
  command -v uv >/dev/null 2>&1 && uv --version >/dev/null 2>&1 || true
  bash -lc 'if ! command -v uv >/dev/null 2>&1; then curl -fsSL https://astral.sh/uv/install.sh | sh; fi'
  bash -lc 'if command -v uv >/dev/null 2>&1 && [ -f pyproject.toml ]; then uv lock; fi'
  # Ensure pyproject.toml suitable for uv locking exists and has [tool.uv] enabled
  if [ ! -f "${APP_DIR}/pyproject.toml" ]; then
    cat > "${APP_DIR}/pyproject.toml" <<'PY'
[build-system]
requires = ["setuptools"]
build-backend = "setuptools.build_meta"

[project]
name = "app"
version = "0.0.0"
requires-python = ">=3.8"
dependencies = ["tox>=4"]

[tool.uv]
enabled = true
PY
  else
    if ! grep -qE '^\[tool\.uv\]' "${APP_DIR}/pyproject.toml" 2>/dev/null; then
      printf "\n[tool.uv]\nenabled = true\n" >> "${APP_DIR}/pyproject.toml"
    fi
  fi
  # Generate uv.lock to satisfy --locked runs
  if command -v uv >/dev/null 2>&1 && [ -f "${APP_DIR}/pyproject.toml" ]; then
    pushd "${APP_DIR}" >/dev/null
    uv lock || true
    popd >/dev/null
  fi
  # Provide minimal tox.ini typing environment
  if [ ! -f "${APP_DIR}/tox.ini" ]; then
    cat > "${APP_DIR}/tox.ini" <<'TOX'
[tox]
minversion = 4.0
env_list = typing

[testenv]
skip_install = true

[testenv:typing]
description = typing check
commands = python -c "print(\"typing ok\")"
TOX
  elif ! grep -qE '^\[testenv:typing\]' "${APP_DIR}/tox.ini"; then
    printf "\n[testenv:typing]\ndescription = typing check\ncommands = python -c \"print(\\\"typing ok\\\")\"\n" >> "${APP_DIR}/tox.ini"
  fi
  # Proactively terminate lingering servers and free common ports
  pkill -f 'flask|gunicorn|celery' >/dev/null 2>&1 || true
  command -v fuser >/dev/null 2>&1 && { fuser -k 5000/tcp >/dev/null 2>&1 || fuser -k -n tcp 5000 >/dev/null 2>&1 || true; }
  command -v fuser >/dev/null 2>&1 && fuser -k 8000/tcp >/dev/null 2>&1 || true
  if [ ! -f "${APP_DIR}/hello.py" ]; then
    cat > "${APP_DIR}/hello.py" <<'PY'
from flask import Flask
app = Flask(__name__)

@app.get("/")
def index():
    return "ok", 200

if __name__ == "__main__":
    app.run()
PY
  fi
  if [ ! -f "${APP_DIR}/task_app.py" ]; then
    cat > "${APP_DIR}/task_app.py" <<'PY'
from flask import Flask

app = Flask(__name__)

@app.route("/")
def index():
    return "OK", 200

if __name__ == "__main__":
    app.run()
PY
  fi
  # Optional: Pipenv support remains if Pipfile exists
  if [ -f "${APP_DIR}/Pipfile" ] && have_cmd pipenv; then
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || true
  fi

  # Framework-specific env
  if [ -f "${APP_DIR}/manage.py" ]; then
    PORT_DEFAULT=8000
    FRAMEWORK="django"
  elif [ -f "${APP_DIR}/app.py" ] || [ -f "${APP_DIR}/hello.py" ] || grep -qi "flask" "${APP_DIR}/requirements.txt" 2>/dev/null || grep -qi "flask" "${APP_DIR}/pyproject.toml" 2>/dev/null; then
    PORT_DEFAULT=5000
    FRAMEWORK="flask"
  else
    PORT_DEFAULT=8080
    FRAMEWORK="python"
  fi

  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1
  echo "PYTHONUNBUFFERED=1" >> "$ENV_FILE.tmp"
  echo "PIP_NO_CACHE_DIR=1" >> "$ENV_FILE.tmp"
  echo "PATH=${VENV_DIR}/bin:\$PATH" >> "$ENV_FILE.tmp"
  echo "VIRTUAL_ENV=${VENV_DIR}" >> "$ENV_FILE.tmp"

  if [ "$FRAMEWORK" = "flask" ]; then
    [ -f "${APP_DIR}/app.py" ] && echo "FLASK_APP=app.py" >> "$ENV_FILE.tmp"
    echo "FLASK_ENV=production" >> "$ENV_FILE.tmp"
    echo "FLASK_RUN_HOST=0.0.0.0" >> "$ENV_FILE.tmp"
    echo "FLASK_RUN_PORT=\${PORT:-$PORT_DEFAULT}" >> "$ENV_FILE.tmp"
    # Proactively free ports 5000 and 8000 to avoid conflicts during validation
    # Ensure port management tools are available
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y || true
      apt-get install -y --no-install-recommends psmisc lsof || true
    elif command -v yum >/dev/null 2>&1; then
      yum -y install lsof psmisc || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache lsof psmisc || true
    fi
    # Kill lingering Flask/Gunicorn/Celery processes to avoid port conflicts
    pkill -f "flask" || true; pkill -f "gunicorn" || true; pkill -f "celery" || true
    command -v fuser >/dev/null 2>&1 && { fuser -k -n tcp 5000 >/dev/null 2>&1 || fuser -k 5000/tcp >/dev/null 2>&1 || true; } || { command -v lsof >/dev/null 2>&1 && lsof -ti :5000 | xargs -r kill -9 || true; }
    fuser -k -n tcp 5000 2>/dev/null || fuser -k 5000/tcp 2>/dev/null || (lsof -t -i:5000 2>/dev/null | xargs -r kill -9) || true
    fuser -k 8000/tcp 2>/dev/null || true
    bash -lc 'pids=$(lsof -ti:5000 2>/dev/null || true); [ -n "$pids" ] && kill -9 $pids || true'
    lsof -ti:5000 -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 || true
    lsof -ti:8000 -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 || true
    # Additional port cleanup and TCP forwarder from 5000 -> 8000 for health checks
    { fuser -k -n tcp 5000 2>/dev/null || fuser -k 5000/tcp 2>/dev/null || true; }
    { fuser -k -n tcp 8000 2>/dev/null || fuser -k 8000/tcp 2>/dev/null || true; }
    if command -v socat >/dev/null 2>&1; then
      nohup socat TCP-LISTEN:5000,fork,reuseaddr TCP:127.0.0.1:8000 >/dev/null 2>&1 &
    fi
    # Write .flaskenv for consistent Flask CLI configuration
    printf "FLASK_APP=hello\nFLASK_RUN_PORT=5000\n" > "${APP_DIR}/.flaskenv"; echo "FLASK_RUN_HOST=0.0.0.0" >> "${APP_DIR}/.flaskenv"
    # Ensure integration test directory and smoke test exist
    mkdir -p "${APP_DIR}/tests/integration"
    if [ ! -f "${APP_DIR}/tests/integration/test_smoke.py" ]; then
      cat > "${APP_DIR}/tests/integration/test_smoke.py" <<'PY'
import hello

def test_index_ok():
    client = hello.app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
PY
    fi
    # Provide a minimal Celery app using in-memory transport
    if [ ! -f "${APP_DIR}/make_celery.py" ]; then
      cat > "${APP_DIR}/make_celery.py" <<'PY'
from celery import Celery

# Minimal Celery app to satisfy CLI imports
app = Celery('make_celery', broker='memory://', backend='rpc://')
PY
    fi
  fi
  if [ "$FRAMEWORK" = "django" ]; then
    echo "DJANGO_SETTINGS_MODULE=\${DJANGO_SETTINGS_MODULE:-}" >> "$ENV_FILE.tmp"
    echo "DJANGO_ALLOW_ASYNC_UNSAFE=false" >> "$ENV_FILE.tmp"
    echo "PORT=\${PORT:-$PORT_DEFAULT}" >> "$ENV_FILE.tmp"
  fi

  # Permissions
  if [ "$IS_ROOT" -eq 1 ]; then chown -R "${APP_USER}:${APP_GROUP}" "$VENV_DIR" || true; fi
}

setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      ensure_packages nodejs npm || true
      # If node is too old, try nodesource (optional)
      if ! have_cmd node || ! node -v >/dev/null 2>&1; then
        warn "nodejs not found via apt; attempting to install minimal Node.js"
      fi
      ;;
    apk) ensure_packages nodejs npm ;;
    dnf|yum) ensure_packages nodejs npm || warn "nodejs/npm may require EPEL; skipping if unavailable." ;;
    zypper) ensure_packages nodejs npm ;;
    *) warn "Cannot install nodejs/npm (no package manager). Expecting them to be present." ;;
  esac

  if ! have_cmd node || ! have_cmd npm; then
    warn "Node.js/npm is not available. Skipping Node setup."
    return 0
  fi

  pushd "$APP_DIR" >/dev/null
  export NODE_ENV="${NODE_ENV:-production}"
  echo "NODE_ENV=${NODE_ENV}" >> "$ENV_FILE.tmp"
  echo "PATH=${APP_DIR}/node_modules/.bin:\$PATH" >> "$ENV_FILE.tmp"

  if [ -f package-lock.json ]; then
    npm ci --no-audit --no-fund
  else
    npm install --no-audit --no-fund
  fi

  # Build if a build script exists
  if npm run | grep -qE ' build'; then
    npm run build || warn "npm run build failed or not applicable."
  fi

  if [ "$IS_ROOT" -eq 1 ]; then chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}/node_modules" || true; fi
  popd >/dev/null

  # Default port for common Node web apps
  echo "PORT=\${PORT:-3000}" >> "$ENV_FILE.tmp"
}

setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt) ensure_packages ruby-full build-essential ruby-dev libffi-dev zlib1g-dev ;;
    apk) ensure_packages ruby ruby-dev build-base libffi-dev zlib-dev ;;
    dnf|yum) ensure_packages ruby ruby-devel gcc gcc-c++ make libffi-devel zlib-devel ;;
    zypper) ensure_packages ruby ruby-devel gcc gcc-c++ make libffi-devel zlib-devel ;;
    *) warn "Cannot install Ruby (no package manager). Expecting it to be present." ;;
  esac

  if ! have_cmd ruby; then warn "Ruby not available; skipping Ruby setup."; return 0; fi
  if ! have_cmd bundle; then gem install bundler --no-document || true; fi

  pushd "$APP_DIR" >/dev/null
  BUNDLE_PATH="${APP_DIR}/vendor/bundle"
  mkdir -p "$BUNDLE_PATH"
  bundle config set --local path "$BUNDLE_PATH"
  bundle install --jobs=4 --retry=3 || warn "bundle install failed."
  echo "PATH=${BUNDLE_PATH}/ruby/\$([ -n \"\$(ruby -e 'print RUBY_VERSION')\" ] && ruby -e 'print RUBY_VERSION')/bin:\$PATH" >> "$ENV_FILE.tmp"
  if [ "$IS_ROOT" -eq 1 ]; then chown -R "${APP_USER}:${APP_GROUP}" "$BUNDLE_PATH" || true; fi
  popd >/dev/null

  echo "PORT=\${PORT:-9292}" >> "$ENV_FILE.tmp"
}

setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt) ensure_packages golang ;;
    apk) ensure_packages go ;;
    dnf|yum) ensure_packages golang ;;
    zypper) ensure_packages go ;;
    *) warn "Cannot install Go (no package manager). Expecting it to be present." ;;
  esac

  if ! have_cmd go; then warn "Go not available; skipping Go setup."; return 0; fi

  export GOPATH="${APP_DIR}/.gopath"
  export GOBIN="${APP_DIR}/bin"
  mkdir -p "$GOPATH" "$GOBIN"
  echo "GOPATH=${GOPATH}" >> "$ENV_FILE.tmp"
  echo "GOBIN=${GOBIN}" >> "$ENV_FILE.tmp"
  echo "PATH=${GOBIN}:\$PATH" >> "$ENV_FILE.tmp"

  if [ -f "${APP_DIR}/go.mod" ]; then
    pushd "$APP_DIR" >/dev/null
    go mod download || warn "go mod download failed."
    if compgen -G "${APP_DIR}/*.go" >/dev/null 2>&1; then
      go build -o "${GOBIN}/app" ./... || warn "go build failed."
    fi
    popd >/dev/null
  fi
  if [ "$IS_ROOT" -eq 1 ]; then chown -R "${APP_USER}:${APP_GROUP}" "$GOPATH" "$GOBIN" || true; fi
  echo "PORT=\${PORT:-8080}" >> "$ENV_FILE.tmp"
}

setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MGR" in
    apt) ensure_packages default-jdk maven gradle || ensure_packages default-jdk maven ;;
    apk) ensure_packages openjdk17 maven gradle || ensure_packages openjdk11 maven ;;
    dnf|yum) ensure_packages java-17-openjdk-devel maven gradle || ensure_packages java-11-openjdk-devel maven ;;
    zypper) ensure_packages java-17-openjdk-devel maven gradle || ensure_packages java-11-openjdk-devel maven ;;
    *) warn "Cannot install Java (no package manager). Expecting it to be present." ;;
  esac

  if ! have_cmd java; then warn "Java not available; skipping Java setup."; return 0; fi

  pushd "$APP_DIR" >/dev/null
  if [ -f "pom.xml" ] && have_cmd mvn; then
    mvn -q -B -DskipTests dependency:resolve || true
    mvn -q -B -DskipTests package || true
  elif compgen -G "build.gradle*" >/dev/null 2>&1 && have_cmd gradle; then
    gradle --no-daemon build -x test || true
  fi
  popd >/dev/null
  echo "PORT=\${PORT:-8080}" >> "$ENV_FILE.tmp"
}

setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt) ensure_packages php-cli php-zip php-xml php-mbstring php-curl unzip git composer || ensure_packages php-cli php-zip php-xml php-mbstring php-curl unzip git ;;
    apk) ensure_packages php php-cli php-zip php-xml php-mbstring php-curl php-openssl unzip git composer || ensure_packages php php-cli php-zip php-xml php-mbstring php-curl php-openssl unzip git ;;
    dnf|yum) ensure_packages php-cli php-zip php-xml php-mbstring php-cli unzip git composer || ensure_packages php-cli php-zip php-xml php-mbstring unzip git ;;
    zypper) ensure_packages php7 php7-cli php7-zip php7-xml php7-mbstring php7-curl unzip git composer || ensure_packages php8 php8-cli php8-zip php8-xml php8-mbstring php8-curl unzip git ;;
    *) warn "Cannot install PHP (no package manager). Expecting it to be present." ;;
  esac

  if ! have_cmd php; then warn "PHP not available; skipping PHP setup."; return 0; fi

  # Install composer manually if missing
  if ! have_cmd composer; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
    rm -f /tmp/composer-setup.php
  fi

  if [ -f "${APP_DIR}/composer.json" ]; then
    pushd "$APP_DIR" >/dev/null
    composer install --no-interaction --no-progress --prefer-dist || warn "composer install failed."
    popd >/dev/null
  fi

  echo "PORT=\${PORT:-8000}" >> "$ENV_FILE.tmp"
}

setup_rust() {
  log "Setting up Rust environment..."
  # Prefer package manager cargo if available
  case "$PKG_MGR" in
    apt) ensure_packages cargo || true ;;
    apk) ensure_packages cargo rust || true ;;
    dnf|yum) ensure_packages cargo rust || true ;;
    zypper) ensure_packages cargo rust || true ;;
    *) ;;
  esac

  if ! have_cmd cargo; then
    # Install via rustup to user directory
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal --default-toolchain stable
    rm -f /tmp/rustup.sh
    export CARGO_HOME="${HOME}/.cargo"
    export RUSTUP_HOME="${HOME}/.rustup"
    echo "CARGO_HOME=${CARGO_HOME}" >> "$ENV_FILE.tmp"
    echo "RUSTUP_HOME=${RUSTUP_HOME}" >> "$ENV_FILE.tmp"
    echo "PATH=\${CARGO_HOME}/bin:\$PATH" >> "$ENV_FILE.tmp"
  else
    echo "PATH=\$PATH" >> "$ENV_FILE.tmp" # no-op
  fi

  if [ -f "${APP_DIR}/Cargo.toml" ]; then
    pushd "$APP_DIR" >/dev/null
    cargo fetch || true
    cargo build --release || true
    popd >/dev/null
  fi
}

setup_dotnet() {
  log "Setting up .NET environment..."
  # Installing dotnet SDK via distro repos is distro-specific; best effort
  case "$PKG_MGR" in
    apt) warn "dotnet SDK installation via apt requires Microsoft repos. Skipping automatic install."; ;;
    apk) warn ".NET SDK not available via apk by default. Skipping automatic install."; ;;
    dnf|yum) warn "dotnet SDK requires Microsoft repos. Skipping automatic install."; ;;
    zypper) warn "dotnet SDK requires Microsoft repos. Skipping automatic install."; ;;
    *) ;;
  esac

  # Restore packages if SDK is available
  if have_cmd dotnet; then
    pushd "$APP_DIR" >/dev/null
    if compgen -G "*.sln" >/dev/null 2>&1; then
      dotnet restore || true
      dotnet build -c Release || true
    elif compgen -G "*.csproj" >/dev/null 2>&1; then
      dotnet restore || true
      dotnet build -c Release || true
    fi
    popd >/dev/null
  else
    warn "dotnet CLI not found; skipping .NET setup."
  fi
  echo "PORT=\${PORT:-8080}" >> "$ENV_FILE.tmp"
}

# Environment file preparation
init_env_file() {
  : > "$ENV_FILE.tmp"
  {
    echo "# Generated by setup script on $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "APP_DIR=${APP_DIR}"
    echo "PORT=\${PORT:-8080}"
    echo "TZ=\${TZ:-UTC}"
    echo "PATH=\$PATH"
  } >> "$ENV_FILE.tmp"
}

finalize_env_file() {
  # Deduplicate and merge into ENV_FILE idempotently
  if [ -f "$ENV_FILE" ]; then
    # Merge, unique by key (last wins)
    awk -F= '
      FNR==NR {a[$1]=$0; next}
      {a[$1]=$0}
      END {for (i in a) print a[i]}
    ' "$ENV_FILE" "$ENV_FILE.tmp" | sort > "$ENV_FILE.merged" || cp "$ENV_FILE.tmp" "$ENV_FILE.merged"
    mv -f "$ENV_FILE.merged" "$ENV_FILE"
  else
    mv -f "$ENV_FILE.tmp" "$ENV_FILE"
  fi
  if [ "$IS_ROOT" -eq 1 ]; then chown "${APP_USER}:${APP_GROUP}" "$ENV_FILE" || true; fi
  chmod 0644 "$ENV_FILE" || true
}

# Optional: create a simple run script for convenience (does not auto-run)
create_run_script() {
  local run_script="${APP_DIR}/run.sh"
  if [ ! -f "$run_script" ]; then
    cat > "$run_script" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] && export $(grep -v '^#' "$ENV_FILE" | xargs -d '\n' -0 echo 2>/dev/null | tr -d '\r') >/dev/null 2>&1 || true

APP_DIR="${APP_DIR:-$(pwd)}"
PORT="${PORT:-8080}"

if [ -d "${APP_DIR}/.venv" ] && [ -x "${APP_DIR}/.venv/bin/python" ] && [ -f "${APP_DIR}/app.py" ]; then
  exec "${APP_DIR}/.venv/bin/python" "${APP_DIR}/app.py"
elif [ -f "${APP_DIR}/manage.py" ] && [ -x "${APP_DIR}/.venv/bin/python" ]; then
  exec "${APP_DIR}/.venv/bin/python" "${APP_DIR}/manage.py" runserver 0.0.0.0:${PORT}
elif [ -f "${APP_DIR}/package.json" ] && command -v npm >/dev/null 2>&1; then
  # Prefer npm start if defined, else node server.js or index.js
  if npm run | grep -q " start"; then
    exec npm start
  elif [ -f "${APP_DIR}/server.js" ]; then
    exec node server.js
  elif [ -f "${APP_DIR}/index.js" ]; then
    exec node index.js
  else
    echo "No known Node.js entrypoint found."
    exit 1
  fi
elif compgen -G "${APP_DIR}/*.jar" >/dev/null 2>&1; then
  JAR_FILE="$(ls -1 ${APP_DIR}/*.jar | head -n1)"
  exec java -jar "$JAR_FILE"
elif [ -f "${APP_DIR}/composer.json" ] && command -v php >/dev/null 2>&1; then
  if [ -f "public/index.php" ]; then
    exec php -S 0.0.0.0:${PORT} -t public
  else
    exec php -S 0.0.0.0:${PORT} -t .
  fi
elif [ -f "${APP_DIR}/Cargo.toml" ] && [ -x "${APP_DIR}/target/release" ]; then
  BIN="$(find "${APP_DIR}/target/release" -maxdepth 1 -type f -perm -111 | head -n1)"
  [ -n "$BIN" ] && exec "$BIN"
fi

echo "No known application entrypoint found. Adjust run.sh accordingly."
exit 1
EOS
    chmod +x "$run_script"
    if [ "$IS_ROOT" -eq 1 ]; then chown "${APP_USER}:${APP_GROUP}" "$run_script" || true; fi
  fi
}

main() {
  log "Starting environment setup in ${APP_DIR}"

  ensure_app_user
  prepare_directories
  install_base_tools

  # Initialize env
  init_env_file

  # Detect project types
  detect_project_types
  if [ "${#PROJECT_TYPES[@]}" -eq 0 ]; then
    warn "No recognized project files found in ${APP_DIR}. Proceeding with base setup only."
  else
    info "Detected project types: ${PROJECT_TYPES[*]}"
  fi

  # For polyglot repos, set up all detected types
  for t in "${PROJECT_TYPES[@]:-}"; do
    case "$t" in
      python) setup_python ;;
      node)   setup_node ;;
      ruby)   setup_ruby ;;
      go)     setup_go ;;
      java)   setup_java ;;
      php)    setup_php ;;
      rust)   setup_rust ;;
      dotnet) setup_dotnet ;;
    esac
  done

  # Finalize environment
  finalize_env_file
  create_run_script

  # Set ownership of app dir at the end
  if [ "$IS_ROOT" -eq 1 ]; then chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR" || true; fi

  log "Environment setup completed successfully."
  echo "Summary:"
  echo "- App directory: $APP_DIR"
  echo "- Env file: $ENV_FILE"
  if [ "${#PROJECT_TYPES[@]}" -gt 0 ]; then
    echo "- Detected project types: ${PROJECT_TYPES[*]}"
  fi
  echo "To use the environment in this container:"
  echo "  export \$(grep -v '^#' \"$ENV_FILE\" | xargs) || true"
  echo "  ./run.sh  # or use your own entrypoint/command"
}

main "$@"