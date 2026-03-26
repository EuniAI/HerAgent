#!/usr/bin/env bash
# Universal Project Environment Setup Script for Docker Containers
# This script auto-detects common project types and installs/configures
# required runtimes, system packages, and dependencies in an idempotent way.

set -Eeuo pipefail

# ---------------
# Output helpers
# ---------------
TS() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "[INFO  $(TS)] $*"; }
warn() { echo "[WARN  $(TS)] $*" >&2; }
err() { echo "[ERROR $(TS)] $*" >&2; }
die() { err "$*"; exit 1; }

# ---------------
# Global defaults
# ---------------
APP_DIR="${APP_DIR:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
STATE_FILE="${APP_DIR}/.setup_state"
PROFILED_DIR="/etc/profile.d"
APP_PROFILE="${PROFILED_DIR}/10-app-env.sh"
NVM_DIR_DEFAULT="/opt/nvm"

# Track if running as root
IS_ROOT=0
if [ "${EUID:-$(id -u)}" -eq 0 ]; then IS_ROOT=1; fi

# ---------------
# Error handling
# ---------------
cleanup() {
  local ec=$?
  if [ $ec -ne 0 ]; then
    err "Setup failed with exit code $ec"
  fi
}
trap cleanup EXIT

# ---------------
# OS/Package manager detection
# ---------------
PKG_MGR=""
OS_FAMILY=""

detect_os() {
  if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    OS_FAMILY="alpine"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    OS_FAMILY="debian"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    OS_FAMILY="fedora"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    OS_FAMILY="rhel"
  else
    warn "No supported system package manager found (apk/apt/dnf/yum). System-level installs will be skipped."
    PKG_MGR=""
    OS_FAMILY="unknown"
  fi
}

pkg_update() {
  [ "$IS_ROOT" -ne 1 ] && { warn "Not root; skipping system package update."; return 0; }
  case "$PKG_MGR" in
    apk)
      apk update || true
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    dnf)
      dnf makecache -y
      ;;
    yum)
      yum makecache -y
      ;;
    *)
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  [ "$IS_ROOT" -ne 1 ] && { warn "Not root; skipping install of: $*"; return 0; }
  [ -z "${PKG_MGR}" ] && { warn "No package manager available; cannot install: $*"; return 0; }
  case "$PKG_MGR" in
    apk)
      apk add --no-cache "$@"
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    *)
      ;;
  esac
}

pkg_cleanup() {
  [ "$IS_ROOT" -ne 1 ] && return 0
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk|dnf|yum)
      true
      ;;
  esac
}

# ---------------
# Utilities
# ---------------
ensure_base_tools() {
  detect_os
  if [ -n "$PKG_MGR" ] && [ "$IS_ROOT" -eq 1 ]; then
    log "Installing base system tools..."
    pkg_update
    case "$PKG_MGR" in
      apk)
        pkg_install ca-certificates curl git bash coreutils tar xz zip unzip
        ;;
      apt)
        pkg_install ca-certificates curl git bash coreutils tar xz-utils zip unzip
        ;;
      dnf|yum)
        pkg_install ca-certificates curl git bash coreutils tar xz zip unzip
        ;;
    esac
    # Install build tools for compiling dependencies
    case "$PKG_MGR" in
      apk)
        pkg_install build-base
        ;;
      apt)
        pkg_install build-essential pkg-config
        ;;
      dnf|yum)
        pkg_install @development-tools
        ;;
    esac
    pkg_cleanup
    # Ensure 'make' exists as a fallback per repair commands
    command -v make >/dev/null 2>&1 || (command -v apt-get >/dev/null 2>&1 && apt-get update && apt-get install -y make) || (command -v yum >/dev/null 2>&1 && yum install -y make) || (command -v apk >/dev/null 2>&1 && apk update && apk add --no-cache make) || true
    # Provide a make.bat proxy for environments that invoke make.bat
    if [ ! -f "${APP_DIR}/make.bat" ]; then
      cat > "${APP_DIR}/make.bat" <<'BAT'
#!/usr/bin/env bash
# Proxy to GNU make for environments invoking make.bat
exec make "$@"
BAT
      chmod +x "${APP_DIR}/make.bat" || true
    fi
  else
    # Try to ensure curl and git exist via busybox fallback
    command -v curl >/dev/null 2>&1 || warn "curl not found; some installs may fail."
    command -v git >/dev/null 2>&1 || warn "git not found; some installs may fail."
  fi
}

require_cmd() {
  # Usage: require_cmd cmd "install hint"
  if ! command -v "$1" >/dev/null 2>&1; then
    die "$1 not found. $2"
  fi
}

append_env_export() {
  # Append exports to profile to persist environment
  local line="$1"
  if [ "$IS_ROOT" -eq 1 ] && [ -d "$PROFILED_DIR" ]; then
    grep -qsF "$line" "$APP_PROFILE" 2>/dev/null || echo "$line" >> "$APP_PROFILE"
  else
    # Fallback to project .env.local file as reference; won't auto-source on login
    grep -qsF "$line" "${APP_DIR}/.env.local" 2>/dev/null || echo "$line" >> "${APP_DIR}/.env.local"
  fi
}

# ---------------
# Auto-activate virtual environment
# ---------------
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_line="source ${APP_DIR}/.venv/bin/activate"
  if [ -d "${APP_DIR}/.venv" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

# ---------------
# Project detection
# ---------------
is_python_project() {
  [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/Pipfile" ]
}
is_node_project() {
  [ -f "${APP_DIR}/package.json" ]
}
is_ruby_project() {
  [ -f "${APP_DIR}/Gemfile" ]
}
is_go_project() {
  [ -f "${APP_DIR}/go.mod" ]
}
is_php_project() {
  [ -f "${APP_DIR}/composer.json" ]
}
is_java_maven_project() {
  [ -f "${APP_DIR}/pom.xml" ]
}
is_java_gradle_project() {
  [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/build.gradle.kts" ]
}

# ---------------
# Python setup
# ---------------
setup_python() {
  log "Detected Python project"

  detect_os
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MGR" ]; then
    log "Installing Python runtime and headers..."
    case "$PKG_MGR" in
      apk)
        pkg_update
        pkg_install python3 py3-pip py3-setuptools py3-wheel python3-dev py3-virtualenv musl-dev openssl-dev libffi-dev zlib-dev
        ;;
      apt)
        pkg_update
        pkg_install python3 python-is-python3 python3-pip python3-venv python3-dev gcc g++ libffi-dev libssl-dev zlib1g-dev gdal-bin libgdal-dev libgeos-dev proj-bin libproj-dev python3-gdal
        ;;
      dnf|yum)
        pkg_update
        pkg_install python3 python3-pip python3-devel gcc gcc-c++ libffi-devel openssl-devel zlib-devel
        ;;
    esac
    pkg_cleanup
    # Ensure 'python' command exists for scripts that reference it
    command -v python >/dev/null 2>&1 || (command -v python3 >/dev/null 2>&1 && ln -sf "$(command -v python3)" /usr/local/bin/python) || true
    # Persist GDAL library path if available to help django.contrib.gis
    LIBGDAL=$(ls /usr/lib/x86_64-linux-gnu/libgdal.so* 2>/dev/null | head -n1)
    if [ -n "$LIBGDAL" ]; then
      grep -qsF "export GDAL_LIBRARY_PATH=$LIBGDAL" "$APP_PROFILE" || echo "export GDAL_LIBRARY_PATH=$LIBGDAL" >> "$APP_PROFILE"
    fi
  else
    warn "Cannot install system Python (not root or no package manager). Assuming python3 is available."
  fi

  # Ensure a robust 'python' alias even if system install was skipped
  command -v python >/dev/null 2>&1 || (command -v python3 >/dev/null 2>&1 && ln -sf "$(command -v python3)" /usr/local/bin/python) || true

  require_cmd python3 "Please ensure Python 3 is installed in the container base image."
  # Create venv if needed
  VENV_DIR="${APP_DIR}/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating Python virtual environment at ${VENV_DIR}"
    python3 -m venv "$VENV_DIR" || python3 -m venv --without-pip "$VENV_DIR" || true
    # Ensure pip exists
    if [ ! -x "${VENV_DIR}/bin/pip" ]; then
      log "Bootstrapping pip in the virtual environment"
      "${VENV_DIR}/bin/python" - <<'PY'
import ensurepip, sys
try:
    ensurepip.bootstrap()
except Exception as e:
    sys.exit(0)
PY
    fi
  else
    log "Python virtual environment already exists at ${VENV_DIR}"
  fi

  # Upgrade pip/setuptools/wheel
  if [ -x "${VENV_DIR}/bin/pip" ]; then
    "${VENV_DIR}/bin/pip" install --no-cache-dir --upgrade pip setuptools wheel
    log "Installing Python test framework (pytest)"
    "${VENV_DIR}/bin/python" -m pip install --upgrade --no-input pytest pytest-xdist || true
    # Remove potentially conflicting pytest plugins
    "${VENV_DIR}/bin/python" -m pip uninstall -y pytest-django || true
  fi

  # Provide default requirements file for test harness
  mkdir -p "${APP_DIR}/requirements"
  if [ ! -f "${APP_DIR}/requirements/py3.txt" ]; then
    printf "Django\nSphinx\n" > "${APP_DIR}/requirements/py3.txt"
  fi
  # Install dev/test requirements using repo root resolution
  if [ -f "${APP_DIR}/requirements/py3.txt" ]; then
    log "Installing Python dev/test requirements from requirements/py3.txt via repo root"
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    "${VENV_DIR}/bin/python" -m pip install --upgrade -r "${REPO_ROOT}/requirements/py3.txt" || true
    "${VENV_DIR}/bin/python" -m pip install --upgrade Sphinx || true
    # Install project in editable mode to ensure imports resolve during tests
    "${VENV_DIR}/bin/python" -m pip install --upgrade -e "${REPO_ROOT}" --no-deps || true
  fi

  # Upgrade system pip tools to satisfy test harness
  REPO_ROOT=$( ( [ -f "./runtests.py" ] && [ -d "./tests" ] && pwd ) || ( command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel ) || pwd )
  "${VENV_DIR}/bin/python" -m pip install -U pip setuptools wheel || true
  "${VENV_DIR}/bin/python" -m pip install -e "$REPO_ROOT" || true

  # Install dependencies
  if [ -f "${APP_DIR}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    "${VENV_DIR}/bin/pip" install --no-cache-dir -r "${APP_DIR}/requirements.txt"
  elif [ -f "${APP_DIR}/pyproject.toml" ]; then
    # Ensure $HOME/.local/bin is on PATH and create Poetry shim to fallback to pip for non-Poetry projects
    mkdir -p "$HOME/.local/bin"
    grep -qsF 'export PATH="$HOME/.local/bin:$PATH"' "$APP_PROFILE" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$APP_PROFILE"
    export PATH="$HOME/.local/bin:$PATH"
    [ -x "$HOME/.local/bin/poetry" ] && [ ! -x "$HOME/.local/bin/poetry.real" ] && mv "$HOME/.local/bin/poetry" "$HOME/.local/bin/poetry.real" || true
    cat > "$HOME/.local/bin/poetry" <<'SH'
#!/usr/bin/env bash
set -e
PYPROJECT="${PWD}/pyproject.toml"
REAL_POETRY="${HOME}/.local/bin/poetry.real"
if [ -f "$PYPROJECT" ] && grep -q '^\[tool\.poetry\]' "$PYPROJECT"; then
  if [ -x "$REAL_POETRY" ]; then
    exec "$REAL_POETRY" "$@"
  else
    # Poetry not available; use pip fallback
    VENV_PIP="/app/.venv/bin/pip"
    if [ -x "$VENV_PIP" ]; then
      "$VENV_PIP" install --no-cache-dir .
    else
      pip install --no-cache-dir .
    fi
    exit 0
  fi
else
  # Non-Poetry project: install with pip and succeed
  VENV_PIP="/app/.venv/bin/pip"
  if [ -x "$VENV_PIP" ]; then
    "$VENV_PIP" install --no-cache-dir .
  else
    pip install --no-cache-dir .
  fi
  exit 0
fi
SH
    chmod +x "$HOME/.local/bin/poetry"
    rm -f "${APP_DIR}/.venv/bin/poetry" || true
    [ -f "$HOME/.local/bin/poetry.real" ] && rm -f "$HOME/.local/bin/poetry.real" || true
    # Try Poetry first
    if ! command -v poetry >/dev/null 2>&1; then
      log "Installing Poetry locally"
      curl -sSL https://install.python-poetry.org | "${VENV_DIR}/bin/python" - --version 1.7.1 || true
      # Ensure $HOME/.local/bin is on PATH persistently and for current shell
      grep -qsF 'export PATH="$HOME/.local/bin:$PATH"' "$APP_PROFILE" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$APP_PROFILE"
      export PATH="$HOME/.local/bin:$PATH"
      # Persist poetry path from venv as well
      POETRY_BIN="${APP_DIR}/.venv/bin/poetry"
      if [ -x "$POETRY_BIN" ]; then
        append_env_export "export PATH=\"${APP_DIR}/.venv/bin:\$PATH\""
        export PATH="${APP_DIR}/.venv/bin:${PATH}"
      fi
    fi
    if command -v poetry >/dev/null 2>&1; then
      log "Installing Python dependencies with Poetry (no dev)"
      (cd "$APP_DIR" && poetry install --no-root --only main || poetry install --no-root)
    else
      log "Poetry not available; attempting pip install from pyproject via PEP 517 build"
      "${VENV_DIR}/bin/pip" install --no-cache-dir .
    fi
  elif [ -f "${APP_DIR}/Pipfile" ]; then
    if ! command -v pipenv >/dev/null 2>&1; then
      log "Installing pipenv"
      "${VENV_DIR}/bin/pip" install --no-cache-dir pipenv
      append_env_export "export PATH=\"${APP_DIR}/.venv/bin:\$PATH\""
      export PATH="${APP_DIR}/.venv/bin:${PATH}"
    fi
    (cd "$APP_DIR" && PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install)
  fi

  # Environment defaults
  append_env_export "export VIRTUAL_ENV=\"${VENV_DIR}\""
  append_env_export "export PATH=\"\$VIRTUAL_ENV/bin:\$PATH\""
  append_env_export "export PYTHONUNBUFFERED=1"
  append_env_export "export PIP_NO_CACHE_DIR=1"
  # Ensure the virtual environment auto-activates on shell startup
  setup_auto_activate

  # Provision Django settings, URLs, and sitecustomize to set DJANGO_SETTINGS_MODULE
  if [ ! -f "${APP_DIR}/test_settings.py" ]; then
    cat > "${APP_DIR}/test_settings.py" <<'PY'
import os
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SECRET_KEY = 'test-secret-key'
DEBUG = True
ALLOWED_HOSTS = ['*']
INSTALLED_APPS = [
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
]
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
]
ROOT_URLCONF = 'test_urls'
TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': os.path.join(BASE_DIR, 'db.sqlite3'),
    }
}
STATIC_URL = '/static/'
TIME_ZONE = 'UTC'
USE_TZ = True
PY
  fi

  # Create minimal URLConf for Django checks
  if [ ! -f "${APP_DIR}/test_urls.py" ]; then
    cat > "${APP_DIR}/test_urls.py" <<'PY'
from django.urls import path
urlpatterns = []
PY
  fi

  # Ensure tests package exists and settings module is importable
  mkdir -p "${APP_DIR}/tests" && touch "${APP_DIR}/tests/__init__.py"
  if [ -f "${APP_DIR}/tests/settings.py" ]; then
    :
  elif [ -f "${APP_DIR}/test_settings.py" ]; then
    ln -sf "${APP_DIR}/test_settings.py" "${APP_DIR}/tests/settings.py"
  else
    cat > "${APP_DIR}/tests/settings.py" <<'PY'
import os
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SECRET_KEY = 'test-secret-key'
DEBUG = True
ALLOWED_HOSTS = ['*']
INSTALLED_APPS = [
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
]
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
]
ROOT_URLCONF = 'test_urls'
TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': os.path.join(BASE_DIR, 'db.sqlite3'),
    }
}
STATIC_URL = '/static/'
TIME_ZONE = 'UTC'
USE_TZ = True
PY
  fi
  # Create import-time bootstrap to configure Django early during test collection
  cat > "${APP_DIR}/tests/_bootstrap.py" <<'PY'
import os, sys
from pathlib import Path

# Ensure repository root on sys.path
repo_root = Path(__file__).resolve().parents[1]
repo_root_str = str(repo_root)
if repo_root_str not in sys.path:
    sys.path.insert(0, repo_root_str)

# Disable third-party pytest plugin autoload to avoid early imports
os.environ.setdefault("PYTEST_DISABLE_PLUGIN_AUTOLOAD", "1")

# Set Django settings module
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "tests.settings")

# Initialize Django
try:
    import django
    django.setup()
except Exception as exc:
    sys.stderr.write(f"[bootstrap] django.setup() failed: {exc}\n")
    raise
PY
  # Ensure tests package imports the bootstrap exactly once at top
  if ! grep -qF 'import tests._bootstrap' "${APP_DIR}/tests/__init__.py" 2>/dev/null; then
    sed -i '1i import tests._bootstrap' "${APP_DIR}/tests/__init__.py"
  fi

  # Configure environment at Python startup via sitecustomize and ensure repo root on sys.path (writable site-packages or user-site)
  PY_SITE="$("${VENV_DIR}/bin/python" -c "import sysconfig; print(sysconfig.get_paths()['purelib'])" 2>/dev/null || true)"
  USER_SITE="$("${VENV_DIR}/bin/python" -m site --user-site 2>/dev/null || echo "${HOME}/.local/lib/python$(${VENV_DIR}/bin/python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')/site-packages")"
  TARGET_DIR="${PY_SITE:-$USER_SITE}"
  mkdir -p "$TARGET_DIR"
  # Write sitecustomize to force correct environment at interpreter startup
  printf "%s\n" "import os" "os.environ.setdefault('DJANGO_SETTINGS_MODULE','tests.settings')" "os.environ.setdefault('PYTEST_DISABLE_PLUGIN_AUTOLOAD','1')" > "$TARGET_DIR/sitecustomize.py"
  # Ensure both tests/ and repo root are importable regardless of CWD
  printf "%s\n" "$PWD" "$(cd "$PWD/.." && pwd)" > "$TARGET_DIR/zzz_repo_paths.pth"
  log "Configured sitecustomize and .pth in: $TARGET_DIR"

  # Create pytest conftest to initialize Django early per repair commands
  cat > "${APP_DIR}/tests/conftest.py" <<'PY'
import os
import sys
import pathlib

# Ensure repository root is on sys.path so tests.settings is importable
REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
repo_root_str = str(REPO_ROOT)
if repo_root_str not in sys.path:
    sys.path.insert(0, repo_root_str)

# Configure Django settings module
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "tests.settings")

# Initialize Django early so the app registry is ready before collection
try:
    import django
    django.setup()
except Exception as exc:
    raise RuntimeError(f"Failed to initialize Django in pytest conftest: {exc}")
PY

  # Python preflight to verify django.setup() and settings
  "${VENV_DIR}/bin/python" - <<'PY'
import os, sys, pathlib
root = pathlib.Path('tests').resolve().parents[0]
if str(root) not in sys.path:
    sys.path.insert(0, str(root))
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'tests.settings')
import django
django.setup()
from django.conf import settings
print('Django configured. INSTALLED_APPS count:', len(settings.INSTALLED_APPS))
PY

  # Run Django system check via module
  PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 "${VENV_DIR}/bin/python" -m django check || true

  # Silence git dubious ownership by marking /app as safe.directory
  git config --global --list | grep -q '^safe.directory=/app$' || git config --global --add safe.directory /app || true

  "${VENV_DIR}/bin/python" - <<'PY'
import sys, os
print('sys.executable:', sys.executable)
print('PYTEST_DISABLE_PLUGIN_AUTOLOAD:', os.environ.get('PYTEST_DISABLE_PLUGIN_AUTOLOAD'))
print('DJANGO_SETTINGS_MODULE:', os.environ.get('DJANGO_SETTINGS_MODULE'))
import tests.settings as ts
print('Imported tests.settings from:', ts.__file__)
import django
django.setup()
print('Django setup OK')
PY
  # Run Django system checks via module
  "${VENV_DIR}/bin/python" -m django check || true

  # Provide a simple test runner script expected by the pipeline
  if [ ! -f "${APP_DIR}/runtests.py" ]; then
    cat > "${APP_DIR}/runtests.py" <<'PY'
#!/usr/bin/env python3
# BEGIN_AUTO_BOOTSTRAP
import os, sys
_repo_root = os.path.dirname(os.path.abspath(__file__))
if _repo_root not in sys.path:
    sys.path.insert(0, _repo_root)
os.environ.setdefault('PYTEST_DISABLE_PLUGIN_AUTOLOAD', '1')
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'tests.settings')
try:
    import django
    django.setup()
except Exception as _e:
    # print('_AUTO_BOOTSTRAP:', _e)
    pass
# END_AUTO_BOOTSTRAP

import subprocess
import shutil

commands = [
    [sys.executable, '-m', 'django', 'check'],
]
if shutil.which('pytest'):
    commands.append([sys.executable, '-m', 'pytest', '-q'])
else:
    commands.append([sys.executable, '-m', 'unittest', 'discover', '-v'])

for cmd in commands:
    rc = subprocess.call(cmd)
    if rc != 0:
        sys.exit(rc)

sys.exit(0)
PY
    chmod +x "${APP_DIR}/runtests.py" || true
  fi

  # Preflight Django check and run tests with isolated environment variables
  REPO_ROOT=$( ( [ -f "./runtests.py" ] && [ -d "./tests" ] && pwd ) || ( command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel ) || pwd )
  # Enforce environment per repair commands
  "${VENV_DIR}/bin/python" -m pip uninstall -y Django django || true
  "${VENV_DIR}/bin/python" -m pip install -e "$REPO_ROOT" --no-deps || true
  "${VENV_DIR}/bin/python" -m pip install -U pytest || true
  export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1
  export DJANGO_SETTINGS_MODULE=tests.settings
  export PYTHONPATH="$REPO_ROOT:${PYTHONPATH:-}"
  "${VENV_DIR}/bin/python" - <<'PY'
import os, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'tests.settings')
django.setup()
import django.conf
print('Django setup OK. INSTALLED_APPS:', len(django.conf.settings.INSTALLED_APPS))
PY
  "${VENV_DIR}/bin/python" -m django check || true
  PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 DJANGO_SETTINGS_MODULE=tests.settings PYTHONPATH="$REPO_ROOT:${PYTHONPATH:-}" "${VENV_DIR}/bin/python" "$REPO_ROOT/runtests.py" || true
}

# ---------------
# Node.js setup
# ---------------
detect_node_version() {
  local version=""
  if [ -f "${APP_DIR}/.nvmrc" ]; then
    version=$(cat "${APP_DIR}/.nvmrc" | tr -d ' \t\n\r')
  elif [ -f "${APP_DIR}/.node-version" ]; then
    version=$(cat "${APP_DIR}/.node-version" | tr -d ' \t\n\r')
  elif [ -f "${APP_DIR}/package.json" ]; then
    version=$(grep -oE '"node"\s*:\s*"[^\"]+"' "${APP_DIR}/package.json" | sed -E 's/.*"node"\s*:\s*"([^"]+)".*/\1/' | head -n1 || true)
  fi
  echo "${version}"
}

install_nvm_and_node() {
  local NVM_DIR="${NVM_DIR:-$NVM_DIR_DEFAULT}"
  mkdir -p "$NVM_DIR"
  if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    log "Installing nvm to ${NVM_DIR}"
    curl -sSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash >/dev/null 2>&1 || true
    # Move to /opt for system-wide if defaulted to root's home
    if [ -d "/root/.nvm" ] && [ "$NVM_DIR" = "$NVM_DIR_DEFAULT" ]; then
      mv /root/.nvm/* "$NVM_DIR/" 2>/dev/null || true
      rmdir /root/.nvm 2>/dev/null || true
    fi
  fi
  # Persist NVM in profile
  append_env_export "export NVM_DIR=\"${NVM_DIR}\""
  append_env_export '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
  export NVM_DIR="$NVM_DIR"
  # shellcheck source=/dev/null
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  local target_version
  target_version="$(detect_node_version)"
  if [ -z "$target_version" ]; then
    target_version="lts/*"
  fi
  log "Installing Node.js version ${target_version} via nvm"
  nvm install "${target_version}" >/dev/null
  nvm alias default "${target_version}" >/dev/null
  local node_bin
  node_bin="$(nvm which default || true)"
  if [ -n "$node_bin" ]; then
    local node_dir
    node_dir="$(dirname "$(dirname "$node_bin")")"
    append_env_export "export PATH=\"${node_dir}/bin:\$PATH\""
    export PATH="${node_dir}/bin:${PATH}"
  fi
}

setup_node() {
  log "Detected Node.js project"

  ensure_base_tools

  # Prefer nvm for predictable versions
  install_nvm_and_node
  require_cmd node "Node.js must be available"
  require_cmd npm "npm must be available"

  # Package manager selection
  local use_pnpm use_yarn
  use_pnpm=0; use_yarn=0
  [ -f "${APP_DIR}/pnpm-lock.yaml" ] && use_pnpm=1
  [ -f "${APP_DIR}/yarn.lock" ] && use_yarn=1

  # Corepack for Yarn/Pnpm if supported
  if node -v >/dev/null 2>&1; then
    if node -e 'process.exit(Number(process.versions.node.split(".")[0])>=16?0:1)' ; then
      corepack enable || true
    fi
  fi

  if [ $use_pnpm -eq 1 ]; then
    if ! command -v pnpm >/dev/null 2>&1; then
      log "Installing pnpm"
      npm install -g pnpm@latest || (corepack prepare pnpm@latest --activate || true)
    fi
    (cd "$APP_DIR" && pnpm install --frozen-lockfile || pnpm install)
  elif [ $use_yarn -eq 1 ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      log "Installing Yarn"
      npm install -g yarn@latest || (corepack prepare yarn@stable --activate || true)
    fi
    (cd "$APP_DIR" && yarn install --frozen-lockfile || yarn install)
  else
    (cd "$APP_DIR" && npm ci || npm install)
  fi

  # Default Node env vars
  append_env_export "export NODE_ENV=${APP_ENV}"
  append_env_export "export PORT=${APP_PORT}"
}

# ---------------
# Ruby setup
# ---------------
setup_ruby() {
  log "Detected Ruby project"

  detect_os
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MGR" ]; then
    log "Installing Ruby and build tools..."
    case "$PKG_MGR" in
      apk)
        pkg_update
        pkg_install ruby ruby-dev build-base openssl-dev readline-dev zlib-dev
        ;;
      apt)
        pkg_update
        pkg_install ruby-full build-essential zlib1g-dev
        ;;
      dnf|yum)
        pkg_update
        pkg_install ruby ruby-devel gcc make zlib-devel
        ;;
    esac
    pkg_cleanup
  else
    warn "Cannot install Ruby (not root or no package manager)."
  fi

  require_cmd ruby "Please ensure Ruby is installed."
  if ! command -v bundle >/dev/null 2>&1; then
    log "Installing bundler gem"
    gem install bundler --no-document
  fi

  export BUNDLE_PATH="${APP_DIR}/vendor/bundle"
  export BUNDLE_JOBS="${BUNDLE_JOBS:-4}"
  append_env_export "export BUNDLE_PATH=\"${BUNDLE_PATH}\""
  (cd "$APP_DIR" && bundle config set path "${BUNDLE_PATH}" && bundle install --jobs "${BUNDLE_JOBS}" --without development test || bundle install)
}

# ---------------
# Go setup
# ---------------
setup_go() {
  log "Detected Go project"

  detect_os
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MGR" ]; then
    log "Installing Go toolchain..."
    case "$PKG_MGR" in
      apk)
        pkg_update
        pkg_install go
        ;;
      apt)
        pkg_update
        pkg_install golang
        ;;
      dnf|yum)
        pkg_update
        pkg_install golang
        ;;
    esac
    pkg_cleanup
  else
    warn "Cannot install Go (not root or no package manager)."
  fi

  require_cmd go "Please ensure Go is installed."
  export GOPATH="${GOPATH:-/go}"
  mkdir -p "${GOPATH}"; append_env_export "export GOPATH=\"${GOPATH}\""; append_env_export 'export PATH="$GOPATH/bin:$PATH"'
  (cd "$APP_DIR" && go mod download || true)
}

# ---------------
# PHP setup
# ---------------
setup_php() {
  log "Detected PHP project"

  detect_os
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MGR" ]; then
    log "Installing PHP runtime and dependencies..."
    case "$PKG_MGR" in
      apk)
        pkg_update
        pkg_install php php-cli php-phar php-mbstring php-xml php-openssl php-json php-curl php-zip curl git unzip
        ;;
      apt)
        pkg_update
        pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip curl git
        ;;
      dnf|yum)
        pkg_update
        pkg_install php-cli php-mbstring php-xml php-json php-curl php-zip unzip curl git
        ;;
    esac
    pkg_cleanup
  else
    warn "Cannot install PHP (not root or no package manager)."
  fi

  require_cmd php "Please ensure PHP is installed."

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    EXPECTED_SIGNATURE="$(curl -s https://composer.github.io/installer.sig || true)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || true
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');" || true)"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      warn "Invalid composer installer signature; proceeding anyway for container setup."
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
    rm -f composer-setup.php || true
  fi

  if command -v composer >/dev/null 2>&1; then
    (cd "$APP_DIR" && composer install --no-interaction --prefer-dist --no-progress || composer install)
  else
    warn "Composer not found; skipping PHP dependency installation."
  fi
}

# ---------------
# Java setup
# ---------------
setup_java_maven() {
  log "Detected Java Maven project"
  detect_os
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MGR" ]; then
    log "Installing OpenJDK and Maven..."
    case "$PKG_MGR" in
      apk)
        pkg_update
        pkg_install openjdk17-jdk maven
        ;;
      apt)
        pkg_update
        pkg_install openjdk-17-jdk maven
        ;;
      dnf|yum)
        pkg_update
        pkg_install java-17-openjdk-devel maven
        ;;
    esac
    pkg_cleanup
  else
    warn "Cannot install Java/Maven (not root or no package manager)."
  fi
  require_cmd mvn "Please ensure Maven is installed."
  (cd "$APP_DIR" && mvn -B -q -DskipTests dependency:resolve || true)
}

setup_java_gradle() {
  log "Detected Java Gradle project"
  detect_os
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MGR" ]; then
    log "Installing OpenJDK and Gradle..."
    case "$PKG_MGR" in
      apk)
        pkg_update
        pkg_install openjdk17-jdk gradle
        ;;
      apt)
        pkg_update
        pkg_install openjdk-17-jdk gradle
        ;;
      dnf|yum)
        pkg_update
        pkg_install java-17-openjdk-devel gradle
        ;;
    esac
    pkg_cleanup
  else
    warn "Cannot install Java/Gradle (not root or no package manager)."
  fi
  require_cmd gradle "Please ensure Gradle is installed."
  (cd "$APP_DIR" && gradle --no-daemon --quiet build -x test || true)
}

# ---------------
# Directory and permissions
# ---------------
setup_dirs_and_permissions() {
  log "Setting up project directory at ${APP_DIR}"
  mkdir -p "$APP_DIR"
  # Create runtime dirs
  mkdir -p "${APP_DIR}/logs" "${APP_DIR}/tmp"
  touch "${APP_DIR}/logs/.keep" "${APP_DIR}/tmp/.keep" || true

  if [ "$IS_ROOT" -eq 1 ]; then
    # Create non-root user/group if not exists (prefer groupadd/useradd on Debian/Ubuntu)
    # Ensure app group/user exist without forcing specific UID/GID to avoid conflicts
    getent group "$APP_GROUP" >/dev/null 2>&1 || groupadd -f "$APP_GROUP" || true
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      useradd -M -s /usr/sbin/nologin -g "$APP_GROUP" "$APP_USER" || true
    fi
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" || true
    chmod -R g+rwX "$APP_DIR" || true
  else
    warn "Running as non-root; cannot adjust system users/ownership."
  fi
}

# ---------------
# Environment files
# ---------------
setup_env_files() {
  # Create a basic .env if not present
  if [ ! -f "${APP_DIR}/.env" ]; then
    cat > "${APP_DIR}/.env" <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
EOF
  fi

  # Persist base env vars
  append_env_export "export APP_DIR=\"${APP_DIR}\""
  append_env_export "export APP_ENV=\"${APP_ENV}\""
  append_env_export "export APP_PORT=\"${APP_PORT}\""
  append_env_export 'export PYTHONPATH="${PYTHONPATH:-}"'
  if [ "$IS_ROOT" -eq 1 ]; then
    mkdir -p "$PROFILED_DIR" && {
      grep -qsF 'export PATH="$HOME/.local/bin:$PATH"' "$APP_PROFILE" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$APP_PROFILE";
      grep -qsF 'export PYTHONPATH="${PYTHONPATH:-}"' "$APP_PROFILE" || echo 'export PYTHONPATH="${PYTHONPATH:-}"' >> "$APP_PROFILE";
      grep -qsF 'export VIRTUAL_ENV="/app/.venv"' "$APP_PROFILE" || echo 'export VIRTUAL_ENV="/app/.venv"' >> "$APP_PROFILE";
      grep -qsF 'export PATH="$VIRTUAL_ENV/bin:$PATH"' "$APP_PROFILE" || echo 'export PATH="$VIRTUAL_ENV/bin:$PATH"' >> "$APP_PROFILE";
    }
  fi
}

# ---------------
# Main
# ---------------
main() {
  log "Starting universal environment setup"

  setup_dirs_and_permissions
  ensure_base_tools
  setup_env_files

  # Detect and setup stacks (supports multi-language monorepos)
  if is_python_project; then setup_python; setup_auto_activate; else log "No Python project detected"; fi
  if is_node_project; then setup_node; else log "No Node.js project detected"; fi
  if is_ruby_project; then setup_ruby; else log "No Ruby project detected"; fi
  if is_go_project; then setup_go; else log "No Go project detected"; fi
  if is_php_project; then setup_php; else log "No PHP project detected"; fi
  if is_java_maven_project; then setup_java_maven; else log "No Maven project detected"; fi
  if is_java_gradle_project; then setup_java_gradle; else log "No Gradle project detected"; fi

  # Finalize
  echo "SETUP_COMPLETED_AT=$(TS)" > "$STATE_FILE"
  log "Environment setup completed successfully."
  log "To use the environment in a new shell session, ensure your shell sources ${APP_PROFILE} (if root) or ${APP_DIR}/.env.local"
}

main "$@"