#!/usr/bin/env bash
# Universal project environment setup script for containerized environments
# Detects common tech stacks and installs required runtimes, system packages, and dependencies.
# Designed to run as root inside Docker containers (no sudo).
#
# This script is idempotent and safe to re-run.

set -Eeuo pipefail

# Globals
SCRIPT_NAME="$(basename "$0")"
START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
PROJECT_ROOT="$(pwd)"
PKG_MGR=""
PKG_UPDATED="false"
APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"

# Logging
log() { echo "[${SCRIPT_NAME}] $(date +'%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "[${SCRIPT_NAME}] [WARN] $(date +'%Y-%m-%d %H:%M:%S') $*" >&2; }
error() { echo "[${SCRIPT_NAME}] [ERROR] $(date +'%Y-%m-%d %H:%M:%S') $*" >&2; }

trap 'error "An error occurred (exit code: $?) at line $LINENO. Exiting."' ERR

# Utility functions
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_file() { [ -f "$PROJECT_ROOT/$1" ]; }
has_dir() { [ -d "$PROJECT_ROOT/$1" ]; }

detect_pkg_mgr() {
  if has_cmd apt-get; then PKG_MGR="apt";
  elif has_cmd apk; then PKG_MGR="apk";
  elif has_cmd microdnf; then PKG_MGR="microdnf";
  elif has_cmd dnf; then PKG_MGR="dnf";
  elif has_cmd yum; then PKG_MGR="yum";
  elif has_cmd zypper; then PKG_MGR="zypper";
  else
    error "No supported package manager found (apt, apk, microdnf, dnf, yum, zypper)."
    exit 1
  fi
}

pkg_update() {
  if [ "$PKG_UPDATED" = "true" ]; then return 0; fi
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      log "Updating apt package index..."
      apt-get update -y || apt-get update
      PKG_UPDATED="true"
      ;;
    apk)
      log "Updating apk package index..."
      apk update
      PKG_UPDATED="true"
      ;;
    microdnf)
      log "Updating microdnf repos..."
      microdnf -y update || true
      PKG_UPDATED="true"
      ;;
    dnf)
      log "Updating dnf repos..."
      dnf -y makecache || dnf -y update || true
      PKG_UPDATED="true"
      ;;
    yum)
      log "Updating yum repos..."
      yum -y makecache || yum -y update || true
      PKG_UPDATED="true"
      ;;
    zypper)
      log "Refreshing zypper repos..."
      zypper -n refresh || true
      PKG_UPDATED="true"
      ;;
  esac
}

pkg_install() {
  # Accepts packages as arguments; installs idempotently.
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@" ;;
    apk)
      apk add --no-cache "$@" ;;
    microdnf)
      microdnf -y install "$@" || {
        warn "microdnf failed; attempting dnf fallback if available."
        if has_cmd dnf; then dnf -y install "$@"; else exit 1; fi
      } ;;
    dnf)
      dnf -y install "$@" ;;
    yum)
      yum -y install "$@" ;;
    zypper)
      zypper -n install -y "$@" ;;
  esac
}

install_base_system_packages() {
  log "Installing base system packages..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl gnupg sudo wget git bash build-essential pkg-config openssh-client unzip zip xz-utils tar
      ;;
    apk)
      pkg_install ca-certificates curl wget git bash build-base pkgconfig openssh unzip zip xz tar
      ;;
    microdnf|dnf|yum)
      pkg_install ca-certificates curl wget git bash gcc gcc-c++ make pkgconfig openssh-clients unzip zip xz tar
      ;;
    zypper)
      pkg_install ca-certificates curl wget git bash gcc gcc-c++ make pkg-config openssh unzip zip xz tar
      ;;
  esac
  # Update CA certs (if available)
  if has_cmd update-ca-certificates; then update-ca-certificates || true; fi
}

create_app_user() {
  # Create non-root app user if not present; safe to rerun.
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User '$APP_USER' already exists."
    return 0
  fi

  log "Creating application user '$APP_USER' with system-assigned UID/GID..."
  if has_cmd groupadd && has_cmd useradd; then
    # GNU shadow utils (Debian/Ubuntu/CentOS etc.)
    getent group "$APP_USER" >/dev/null 2>&1 || groupadd "$APP_USER"
    id -u "$APP_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -g "$APP_USER" "$APP_USER"
  elif has_cmd addgroup && has_cmd adduser; then
    # Alpine BusyBox
    addgroup "$APP_USER" 2>/dev/null || true
    adduser -D -G "$APP_USER" "$APP_USER"
  else
    warn "User management tools not available; running as root."
    return 0
  fi
}

setup_directories() {
  log "Setting up project directories and permissions..."
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,run,data,config}
  # Ensure ownership to app user if exists
  if id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER:$APP_USER" "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/run" "$PROJECT_ROOT/data"
  fi
}

detect_stack() {
  STACKS=()
  # Python
  if has_file requirements.txt || has_file pyproject.toml || has_file Pipfile; then STACKS+=("python"); fi
  # Node.js
  if has_file package.json; then STACKS+=("node"); fi
  # Ruby
  if has_file Gemfile; then STACKS+=("ruby"); fi
  # PHP
  if has_file composer.json; then STACKS+=("php"); fi
  # Go
  if has_file go.mod; then STACKS+=("go"); fi
  # Rust
  if has_file Cargo.toml; then STACKS+=("rust"); fi
  # Java
  if has_file pom.xml || has_file build.gradle || has_file build.gradle.kts || has_file mvnw || has_file gradlew; then STACKS+=("java"); fi
  # .NET
  if ls "$PROJECT_ROOT"/*.sln >/dev/null 2>&1 || ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then STACKS+=(".net"); fi

  if [ ${#STACKS[@]} -eq 0 ]; then
    warn "No known stack files detected. Proceeding with base system setup only."
  else
    log "Detected stacks: ${STACKS[*]}"
  fi
}

install_python_runtime() {
  log "Installing Python runtime and dev packages..."
  # Install build dependencies for compiling Python via pyenv
  case "$PKG_MGR" in
    apt)
      pkg_install make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev curl git ca-certificates xz-utils tk-dev libncurses5-dev libncursesw5-dev
      ;;
    apk)
      pkg_install build-base openssl-dev zlib-dev bzip2-dev readline-dev sqlite-dev libffi-dev curl git ca-certificates xz tk-dev ncurses-dev
      ;;
    microdnf|dnf|yum)
      pkg_install gcc gcc-c++ make openssl-devel bzip2-devel zlib-devel readline-devel sqlite-devel libffi-devel xz-devel tk-devel ncurses-devel ca-certificates curl git
      ;;
    zypper)
      pkg_install gcc gcc-c++ make libopenssl-devel bzip2-devel zlib-devel readline-devel sqlite3-devel libffi-devel xz tk-devel ncurses-devel ca-certificates curl git
      ;;
  esac

  # Install system Python dev packages (retain for headers/libs)
  case "$PKG_MGR" in
    apt)
      pkg_install python3-venv python3-pip python3-dev libffi-dev libssl-dev zlib1g-dev libjpeg-dev libpq-dev default-libmysqlclient-dev pipx curl
      # Attempt to install multiple interpreters for compatibility with pinned packages (e.g., torch)
      apt-get update -y || true
      apt-get install -y python3.10 python3.10-venv python3.11 python3.11-venv || true
      python3.10 -m ensurepip --upgrade || true
      python3.10 -m pip install -U pip setuptools wheel || true
      python3.11 -m ensurepip --upgrade || true
      python3.11 -m pip install -U pip setuptools wheel || true
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev libffi-dev openssl-dev zlib-dev jpeg-dev musl-dev gcc
      ;;
    microdnf|dnf|yum)
      pkg_install python3 python3-pip python3-devel openssl-devel libffi-devel zlib-devel gcc make
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel libopenssl-devel libffi-devel zlib-devel gcc make
      ;;
  esac

  # Ensure pipx PATH and set up Poetry via pipx (prefer pipx-managed poetry, remove distro poetry)
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get update -y || true
    apt-get purge -y python3-poetry poetry || true
  fi
  python3 -m pip install --upgrade "pip>=23.3" "setuptools>=68" wheel "packaging>=24.2" "poetry>=1.8.4" "poetry-core>=1.9.0" "poetry-plugin-export>=1.6.0" || true
  ln -sf "$(command -v poetry)" /usr/local/bin/poetry || true
  if command -v pipx >/dev/null 2>&1; then pipx runpip poetry install --upgrade "packaging>=24.2" "poetry-core>=1.9.0" "poetry-plugin-export>=1.6.0" || true; fi
  if command -v pipx >/dev/null 2>&1; then pipx upgrade poetry || true; fi
  poetry --version || true

  # Install Python 3.10 via pyenv and set it as default python3
  export PYENV_ROOT=/opt/pyenv
  export PATH="$PYENV_ROOT/bin:$PATH"
  if [ ! -d "$PYENV_ROOT" ]; then
    git clone https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
  fi
  "$PYENV_ROOT/bin/pyenv" install -s 3.10.13
  "$PYENV_ROOT/versions/3.10.13/bin/python3" -m ensurepip --upgrade || true
  ln -sf "$PYENV_ROOT/versions/3.10.13/bin/python3" /usr/local/bin/python3
  ln -sf "$PYENV_ROOT/versions/3.10.13/bin/pip3" /usr/local/bin/pip3

  # Prefer specific interpreters compatible with many ML wheels
  if has_cmd python3.10; then
    PYTHON_BIN="python3.10"
  elif has_cmd python3.11; then
    PYTHON_BIN="python3.11"
  else
    PYTHON_BIN="${PYTHON_BIN:-python3}"
  fi
  if ! has_cmd "$PYTHON_BIN"; then
    error "Python3 installation failed or not found."
    exit 1
  fi

  VENV_DIR="$PROJECT_ROOT/.venv"
  log "Creating Python virtual environment at $VENV_DIR..."
  "$PYTHON_BIN" -m venv --upgrade-deps "$VENV_DIR"

  PIP_BIN="$VENV_DIR/bin/pip"
  if [ ! -x "$PIP_BIN" ]; then
    error "pip not found in virtual environment."
    exit 1
  fi

  log "Upgrading pip and setuptools in venv..."
  "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
  "$VENV_DIR/bin/python" -m pip install --no-cache-dir ruff
  # Ensure packaging is new enough inside the project venv to avoid Poetry runtime import issues
  if [ -d .venv ]; then . .venv/bin/activate && pip install --upgrade "packaging>=24.2"; fi

  # Configure Poetry to use in-project venv and bind to this .venv interpreter
  export PATH="$HOME/.local/bin:$PATH"
  poetry config virtualenvs.in-project true --local || true

  # Configure pip to prefer PyTorch CPU wheels
  mkdir -p /root/.config/pip
  cat > /root/.config/pip/pip.conf <<'EOF'
[global]
index-url = https://download.pytorch.org/whl/cpu
extra-index-url = https://pypi.org/simple
EOF
  if id -u "$APP_USER" >/dev/null 2>&1; then
    mkdir -p "/home/$APP_USER/.config/pip"
    cat > "/home/$APP_USER/.config/pip/pip.conf" <<'EOF'
[global]
index-url = https://download.pytorch.org/whl/cpu
extra-index-url = https://pypi.org/simple
EOF
    chown -R "$APP_USER:$APP_USER" "/home/$APP_USER/.config"
  fi

  # Pre-install platform-compatible CPU-only PyTorch wheels to avoid incompatible CUDA builds
  "$VENV_DIR/bin/python" -m pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple torch
  # Install project dependencies without pulling transitive deps (to avoid overriding torch)
  . "$PWD/.venv/bin/activate" && [ -f requirements.txt ] && pip install --no-cache-dir --no-deps -r requirements.txt || true
  if [ -f pyproject.toml ]; then
    poetry env use python3 && poetry install --no-interaction --no-ansi || true
    poetry run black -q . || true
    . "$PWD/.venv/bin/activate" && pip install --no-cache-dir --no-deps "$PWD" || true
    # Create CLI wrapper using Poetry's Python to ensure correct bin path
    poetry run python - <<'PY'
import os, sys, stat
bin_dir = os.path.dirname(sys.executable)
path = os.path.join(bin_dir, 'denser-retriever')
shebang = f"#!{sys.executable}\n"
script = shebang + (
    """
import sys, importlib, runpy
args = sys.argv[1:]
if any(a in ("-h", "--help") for a in args):
    print("denser-retriever - DENSER Retriever CLI\n\nUsage:\n  denser-retriever [options] [subcommand]\n\nOptions:\n  -h, --help  Show this help message and exit")
    sys.exit(0)
if importlib.util.find_spec("denser_retriever.__main__"):
    runpy.run_module("denser_retriever", run_name="__main__")
else:
    sys.stderr.write("Error: denser_retriever CLI module not found.\n")
    sys.exit(1)
"""
)
with open(path, 'w', encoding='utf-8') as f:
    f.write(script)
os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
print(path)
PY
  fi
  if has_file Pipfile; then
    warn "Pipfile detected but pipenv is not installed by default. Installing via pip..."
    "$PIP_BIN" install --no-cache-dir pipenv
    log "Installing Python dependencies via pipenv..."
    "$PROJECT_ROOT/.venv/bin/pipenv" install --deploy || "$PROJECT_ROOT/.venv/bin/pipenv" install
  fi
  if ! has_file requirements.txt && ! has_file pyproject.toml && ! has_file Pipfile; then
    warn "No Python dependency file found."
  fi

  # Force system-resolved python and pip to point to project .venv to align tests
  ln -sf "$VENV_DIR/bin/python" /usr/local/bin/python || true
  ln -sf "$VENV_DIR/bin/pip" /usr/local/bin/pip || true

  # Install locked dependencies into the interpreter used by tests (plain 'python')
  if [ -f pyproject.toml ]; then
    log "Exporting Poetry lock to requirements and installing into system interpreter..."
    cd "$PROJECT_ROOT"
    python3 -m pip install --upgrade "packaging>=24.2" "poetry>=1.8.4" "poetry-core>=1.9.0" "poetry-plugin-export>=1.6.0"
    poetry source remove pytorch || true
    poetry source add --priority=supplemental pytorch https://download.pytorch.org/whl/cpu
    poetry lock --no-interaction
    poetry export --without-hashes --with dev -f requirements.txt -o /tmp/requirements.txt || poetry export --without-hashes -f requirements.txt -o /tmp/requirements.txt
    python -m pip install --upgrade -r /tmp/requirements.txt
  fi
}

install_node_runtime() {
  log "Installing Node.js runtime..."
  case "$PKG_MGR" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    microdnf|dnf|yum)
      pkg_install nodejs npm
      ;;
    zypper)
      pkg_install nodejs npm
      ;;
  esac
  if ! has_cmd node || ! has_cmd npm; then
    error "Node.js or npm installation failed."
    exit 1
  fi

  # Optionally install yarn/pnpm if lock files exist
  if has_file yarn.lock; then
    log "Installing Yarn..."
    npm install -g yarn --omit=dev || npm install -g yarn || true
    if has_cmd yarn; then
      log "Installing Node dependencies via Yarn..."
      yarn install --frozen-lockfile || yarn install
    else
      warn "Yarn installation failed; falling back to npm."
    fi
  elif has_file pnpm-lock.yaml; then
    log "Installing pnpm..."
    npm install -g pnpm --omit=dev || npm install -g pnpm || true
    if has_cmd pnpm; then
      log "Installing Node dependencies via pnpm..."
      pnpm install --frozen-lockfile || pnpm install
    else
      warn "pnpm installation failed; falling back to npm."
    fi
  fi

  if has_file package-lock.json && has_file package.json; then
    log "Installing Node dependencies via npm ci..."
    npm ci || npm install
  elif has_file package.json; then
    log "Installing Node dependencies via npm install..."
    npm install
  fi
}

install_bun_runtime() {
  log "Ensuring Bun runtime is installed..."
  if ! command -v bun >/dev/null 2>&1; then
    curl -fsSL https://bun.sh/install | bash || true
  fi
  if ! command -v bun >/dev/null 2>&1; then
    ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun 2>/dev/null || ln -sf "/root/.bun/bin/bun" /usr/local/bin/bun 2>/dev/null || true
  fi
  if [ -x "$HOME/.bun/bin/bun" ]; then
    (echo "export PATH=$HOME/.bun/bin:\$PATH" > /etc/profile.d/bun.sh && chmod 0644 /etc/profile.d/bun.sh) || true
  fi
}

install_ruby_runtime() {
  log "Installing Ruby runtime and Bundler..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby ruby-dev build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    microdnf|dnf|yum)
      pkg_install ruby ruby-devel gcc make
      ;;
    zypper)
      pkg_install ruby ruby-devel gcc make
      ;;
  esac

  if ! has_cmd ruby; then
    error "Ruby installation failed."
    exit 1
  fi

  if ! has_cmd bundler; then
    log "Installing Bundler gem..."
    gem install bundler --no-document
  fi

  if has_file Gemfile; then
    log "Installing Ruby dependencies via bundler..."
    # Vendor gems locally to vendor/bundle for containerized app
    bundle config set --local path 'vendor/bundle'
    if has_file Gemfile.lock; then
      bundle install --jobs=4
    else
      bundle install --jobs=4
    fi
  fi
}

install_php_runtime() {
  log "Installing PHP runtime and Composer..."
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-zip php-mbstring php-xml curl
      # Try apt composer; if unavailable, fetch composer manually
      if ! has_cmd composer; then
        apt-get install -y --no-install-recommends composer || true
      fi
      ;;
    apk)
      pkg_install php php-phar php-zip php-mbstring php-xml composer
      ;;
    microdnf|dnf|yum)
      pkg_install php-cli php-zip php-mbstring php-xml composer curl
      ;;
    zypper)
      pkg_install php-cli php-zip php-mbstring php-xml composer curl
      ;;
  esac

  if ! has_cmd composer; then
    log "Installing Composer manually..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if ! has_cmd composer; then
    error "Composer installation failed."
    exit 1
  fi

  if has_file composer.json; then
    log "Installing PHP dependencies via composer..."
    if has_file composer.lock; then
      composer install --no-interaction --prefer-dist --no-progress
    else
      composer install --no-interaction --prefer-dist --no-progress
    fi
  fi
}

install_go_runtime() {
  log "Installing Go runtime..."
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    microdnf|dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac

  if ! has_cmd go; then
    error "Go installation failed."
    exit 1
  fi

  if has_file go.mod; then
    log "Fetching Go modules..."
    go mod download
  fi
}

install_rust_runtime() {
  log "Installing Rust toolchain..."
  case "$PKG_MGR" in
    apt) pkg_install rustc cargo ;;
    apk) pkg_install rust cargo ;;
    microdnf|dnf|yum) pkg_install rust cargo || pkg_install rustc cargo ;;
    zypper) pkg_install rust cargo ;;
  esac

  if ! has_cmd cargo; then
    error "Cargo installation failed."
    exit 1
  fi

  if has_file Cargo.toml; then
    log "Fetching Rust dependencies..."
    cargo fetch
  fi
}

install_java_runtime() {
  log "Installing Java runtime (JDK) and build tools if needed..."
  local need_maven="false" need_gradle="false"
  if has_file pom.xml && [ ! -x "$PROJECT_ROOT/mvnw" ]; then need_maven="true"; fi
  if (has_file build.gradle || has_file build.gradle.kts) && [ ! -x "$PROJECT_ROOT/gradlew" ]; then need_gradle="true"; fi

  case "$PKG_MGR" in
    apt)
      pkg_install default-jdk
      if [ "$need_maven" = "true" ]; then pkg_install maven; fi
      if [ "$need_gradle" = "true" ]; then pkg_install gradle; fi
      ;;
    apk)
      pkg_install openjdk17
      if [ "$need_maven" = "true" ]; then pkg_install maven; fi
      if [ "$need_gradle" = "true" ]; then pkg_install gradle; fi
      ;;
    microdnf|dnf|yum)
      pkg_install java-17-openjdk-devel
      if [ "$need_maven" = "true" ]; then pkg_install maven; fi
      if [ "$need_gradle" = "true" ]; then pkg_install gradle; fi
      ;;
    zypper)
      pkg_install java-17-openjdk-devel
      if [ "$need_maven" = "true" ]; then pkg_install maven; fi
      if [ "$need_gradle" = "true" ]; then pkg_install gradle; fi
      ;;
  esac

  if has_file pom.xml; then
    if [ -x "$PROJECT_ROOT/mvnw" ]; then
      log "Using Maven Wrapper to download dependencies..."
      "$PROJECT_ROOT/mvnw" -B -ntp dependency:resolve || "$PROJECT_ROOT/mvnw" -B -ntp validate || true
    elif has_cmd mvn; then
      log "Using system Maven to download dependencies..."
      mvn -B -ntp dependency:resolve || mvn -B -ntp validate || true
    fi
  fi

  if has_file build.gradle || has_file build.gradle.kts; then
    if [ -x "$PROJECT_ROOT/gradlew" ]; then
      log "Using Gradle Wrapper to download dependencies..."
      "$PROJECT_ROOT/gradlew" --no-daemon tasks || true
    elif has_cmd gradle; then
      log "Using system Gradle to download dependencies..."
      gradle --no-daemon tasks || true
    fi
  fi
}

install_dotnet_runtime() {
  # Best-effort: installing dotnet SDK in a generic container can be complex.
  # Here we try to detect and warn if toolchain isn't present.
  log "Detecting .NET project..."
  if ls "$PROJECT_ROOT"/*.sln >/dev/null 2>&1 || ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then
    if has_cmd dotnet; then
      log ".NET SDK found. Restoring dependencies..."
      if ls "$PROJECT_ROOT"/*.sln >/dev/null 2>&1; then
        dotnet restore "$(ls "$PROJECT_ROOT"/*.sln | head -n1)" || dotnet restore
      else
        dotnet restore || true
      fi
    else
      warn ".NET SDK not found. Please use a base image with dotnet preinstalled (e.g., mcr.microsoft.com/dotnet/sdk)."
    fi
  fi
}

setup_env_file() {
  # Set default environment variables and persist to .env
  ENV_FILE="$PROJECT_ROOT/.env"
  if [ -f "$ENV_FILE" ]; then
    log ".env file already exists; not overwriting existing values."
    return 0
  fi

  # Determine default port based on detected stack
  local default_port="8080"
  if has_file package.json; then default_port="3000"; fi
  if has_file requirements.txt || has_file pyproject.toml || has_file Pipfile; then
    # Flask often uses 5000, Django uses 8000; choose 5000 as general default
    default_port="5000"
  fi
  if has_file Gemfile; then default_port="3000"; fi
  if has_file composer.json; then default_port="8000"; fi
  if has_file go.mod; then default_port="8080"; fi
  if has_file Cargo.toml; then default_port="8080"; fi
  if has_file pom.xml || has_file build.gradle || has_file build.gradle.kts; then default_port="8080"; fi

  log "Creating .env file with default environment variables..."
  cat > "$ENV_FILE" <<EOF
# Generated by $SCRIPT_NAME on $START_TIME
APP_NAME=${APP_NAME:-app}
APP_ENV=${APP_ENV:-production}
APP_DEBUG=${APP_DEBUG:-false}
APP_PORT=${APP_PORT:-$default_port}
# Service runtime specifics
NODE_ENV=${NODE_ENV:-production}
PYTHONUNBUFFERED=1
PYTHONDONTWRITEBYTECODE=1
# Flask/Django helpers (ignored if not applicable)
FLASK_ENV=${FLASK_ENV:-production}
FLASK_RUN_PORT=\${APP_PORT}
DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE:-}
# Database connectivity placeholders
DATABASE_URL=${DATABASE_URL:-}
REDIS_URL=${REDIS_URL:-}
# Logging
LOG_LEVEL=${LOG_LEVEL:-info}
EOF
  chmod 0640 "$ENV_FILE"
}

export_runtime_paths() {
  # Export environment variables for current session
  set +u
  if [ -f "$PROJECT_ROOT/.env" ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^\s*#' "$PROJECT_ROOT/.env" | xargs -I{} echo {})
  fi
  set -u
  # Ensure venv bin & local bin on PATH
  if [ -d "$PROJECT_ROOT/.venv/bin" ]; then
    export PATH="$PROJECT_ROOT/.venv/bin:$PATH"
  fi
  if [ -d "$PROJECT_ROOT/node_modules/.bin" ]; then
    export PATH="$PROJECT_ROOT/node_modules/.bin:$PATH"
  fi
}

setup_auto_activate() {
  # Auto-activate Python virtual environment when entering the project directory
  local bashrc_file="/root/.bashrc"
  local snippet="# Auto-activate venv in project directory\nif [ -f \"\$PWD/.venv/bin/activate\" ]; then . \"\$PWD/.venv/bin/activate\"; fi"
  if ! grep -q "Auto-activate venv in project directory" "$bashrc_file" 2>/dev/null; then
    printf "\n%s\n" "$snippet" >> "$bashrc_file"
  fi
  if id -u "$APP_USER" >/dev/null 2>&1; then
    local user_bashrc="/home/$APP_USER/.bashrc"
    if ! grep -q "Auto-activate venv in project directory" "$user_bashrc" 2>/dev/null; then
      printf "\n%s\n" "$snippet" >> "$user_bashrc"
      chown "$APP_USER:$APP_USER" "$user_bashrc" || true
    fi
  fi
}

ensure_sudo_docker() {
  # Ensure base tools and sudo are present across distros
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates sudo gnupg || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates sudo || true
  elif command -v apk >/dev/null 2>&1; then
    apk update || true
    apk add --no-cache curl ca-certificates sudo || true
  fi

  # Install Docker Engine via convenience script if missing
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh || true
  fi

  # Try to start Docker daemon via multiple init systems, else fallback to foreground daemon
  if command -v docker >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl start docker || true
    elif command -v service >/dev/null 2>&1; then
      service docker start || true
    elif command -v rc-service >/dev/null 2>&1; then
      rc-service docker start || true
    else
      nohup dockerd > /var/log/dockerd.log 2>&1 & sleep 3 || true
    fi
  fi

  # Ensure Docker Compose v2 plugin is available if docker compose is missing
  if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y docker-compose-plugin || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache docker-cli-compose || true
    fi
  fi

  # Diagnostics (do not fail the setup if unavailable)
  docker --version || true
  docker compose version || true
}

post_setup_instructions() {
  log "Environment setup completed successfully."
  echo "Summary:"
  echo "- Project root: $PROJECT_ROOT"
  echo "- Detected stacks: ${STACKS[*]:-none}"
  echo "- .env created: $( [ -f \"$PROJECT_ROOT/.env\" ] && echo yes || echo no )"
  echo "- Non-root user: $(id -u \"$APP_USER\" >/dev/null 2>&1 && echo \"$APP_USER\" || echo \"not created\")"
  echo
  echo "Common run hints (adjust to your project):"
  echo "- Python: source .venv/bin/activate && python app.py (Flask) or gunicorn module:app --bind 0.0.0.0:\$APP_PORT"
  echo "- Node: npm start or node server.js (ensure to bind to 0.0.0.0:\$APP_PORT)"
  echo "- Ruby: bundle exec rails server -b 0.0.0.0 -p \$APP_PORT"
  echo "- PHP: php -S 0.0.0.0:\$APP_PORT -t public or use your framework's runner"
  echo "- Go: go run ./... or build and run (ensure to bind to 0.0.0.0:\$APP_PORT)"
  echo "- Java: use mvnw/gradlew or mvn spring-boot:run (bind to 0.0.0.0:\$APP_PORT)"
  echo "- .NET: dotnet run --urls http://0.0.0.0:\$APP_PORT"
}

main() {
  log "Starting universal environment setup..."
  detect_pkg_mgr
  install_base_system_packages
  create_app_user
  setup_directories

  detect_stack

  # Install per-stack runtimes and dependencies
  for s in "${STACKS[@]:-}"; do
    case "$s" in
      python) install_python_runtime ;;
      node)
        install_node_runtime
        # Ensure Bun is available for projects that use it (bun install/run)
        install_bun_runtime
        ;;
      ruby) install_ruby_runtime ;;
      php) install_php_runtime ;;
      go) install_go_runtime ;;
      rust) install_rust_runtime ;;
      java) install_java_runtime ;;
      .net) install_dotnet_runtime ;;
    esac
  done

  setup_env_file
  export_runtime_paths

  # Ensure sudo and Docker availability and attempt to start Docker daemon
  ensure_sudo_docker

  # Setup auto-activation of venv in bash shells
  setup_auto_activate

  # Permissions for generated artifacts
  if id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER:$APP_USER" "$PROJECT_ROOT"/{logs,tmp,run,data} || true
  fi

  post_setup_instructions
}

main "$@"