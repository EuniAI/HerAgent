#!/usr/bin/env bash
# Container-friendly, idempotent environment setup script
# This script detects common project types (Python, Node.js, Go, Rust, Ruby, PHP, Java)
# and installs appropriate runtimes and dependencies using the available package manager.
# It sets up directories, environment variables, and configures the runtime.

set -Eeuo pipefail
IFS=$' \n\t'

# ----------------------------
# Logging and error handling
# ----------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

ts() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "${GREEN}[$(ts)] $*${NC}"; }
info() { echo "${BLUE}[$(ts)] $*${NC}"; }
warn() { echo "${YELLOW}[$(ts)] $*${NC}" >&2; }
error() { echo "${RED}[$(ts)] ERROR: $*${NC}" >&2; }

cleanup() { :; }
on_error() {
  error "Setup failed at line $1 (command: $2)"
  exit 1
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ----------------------------
# Defaults and config
# ----------------------------
APP_DIR="${APP_DIR:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"

# Optional non-root execution inside the container:
RUN_USER="${RUN_USER:-}"
RUN_UID="${RUN_UID:-1000}"
RUN_GID="${RUN_GID:-1000}"

# Language-specific versions (optional; used where applicable)
PYTHON_VERSION_MIN="${PYTHON_VERSION_MIN:-3.8}"
NODE_VERSION="${NODE_VERSION:-20.18.0}"  # LTS
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"

# Non-interactive installs in containers
export DEBIAN_FRONTEND=noninteractive

# ----------------------------
# Package manager detection
# ----------------------------
PKG_MGR=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
is_alpine=0

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN=": # apk uses --no-cache; nothing to clean"
    is_alpine=1
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_UPDATE="dnf -y update || true"
    PKG_INSTALL="dnf -y install"
    PKG_CLEAN="dnf clean all || true"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_UPDATE="yum -y update || true"
    PKG_INSTALL="yum -y install"
    PKG_CLEAN="yum clean all || true"
  else
    error "No supported package manager found (apt/apk/dnf/yum)."
    exit 1
  fi
  info "Using package manager: $PKG_MGR"
}

install_pkgs() {
  # usage: install_pkgs pkg1 pkg2 ...
  $PKG_UPDATE
  $PKG_INSTALL "$@"
  eval "$PKG_CLEAN"
}

# ----------------------------
# Common system dependencies
# ----------------------------
install_common_deps() {
  log "Installing common system packages..."
  case "$PKG_MGR" in
    apt)
      install_pkgs ca-certificates curl git tzdata pkg-config build-essential \
        openssl libssl-dev libffi-dev zlib1g-dev gzip xz-utils unzip
      update-ca-certificates || true
      ;;
    apk)
      install_pkgs ca-certificates curl git tzdata pkgconfig build-base \
        openssl openssl-dev libffi-dev zlib-dev xz unzip
      update-ca-certificates || true
      ;;
    dnf|yum)
      install_pkgs ca-certificates curl git tzdata pkgconfig \
        openssl openssl-devel libffi libffi-devel zlib zlib-devel gzip xz unzip tar make gcc
      update-ca-trust || true
      ;;
  esac
  log "Common system packages installed."
}

# ----------------------------
# Project directory setup
# ----------------------------
setup_directories() {
  log "Setting up project directories at $APP_DIR..."
  mkdir -p "$APP_DIR"
  mkdir -p "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/.cache"
  mkdir -p "$APP_DIR/bin"
  chown -R root:root "$APP_DIR" || true
  chmod -R 755 "$APP_DIR" || true
}

# ----------------------------
# Optional user creation
# ----------------------------
setup_user() {
  if [[ -n "$RUN_USER" ]]; then
    info "Configuring non-root user: $RUN_USER ($RUN_UID:$RUN_GID)"
    if ! getent group "$RUN_GID" >/dev/null 2>&1; then
      groupadd -g "$RUN_GID" "$RUN_USER" || true
    fi
    if ! id -u "$RUN_USER" >/dev/null 2>&1; then
      useradd -m -u "$RUN_UID" -g "$RUN_GID" -s /bin/bash "$RUN_USER" || true
    fi
    chown -R "$RUN_UID":"$RUN_GID" "$APP_DIR" || true
  else
    info "RUN_USER not set; proceeding as root."
  fi
}

# ----------------------------
# Environment variables setup
# ----------------------------
write_env_files() {
  log "Writing environment configuration..."
  {
    echo "APP_DIR=$APP_DIR"
    echo "APP_ENV=$APP_ENV"
    echo "APP_PORT=$APP_PORT"
    echo "PYTHONUNBUFFERED=1"
    echo "PIP_NO_CACHE_DIR=off"
    echo "PIP_DISABLE_PIP_VERSION_CHECK=1"
    echo "NODE_ENV=${NODE_ENV:-production}"
    echo "NPM_CONFIG_FUND=false"
    echo "NPM_CONFIG_AUDIT=false"
    echo "NPM_CONFIG_UPDATE_NOTIFIER=false"
    echo "UV_THREADPOOL_SIZE=16"
    echo "PATH=$APP_DIR/bin:\$PATH"
  } > "$APP_DIR/.env"

  mkdir -p /etc/profile.d
  {
    echo "export APP_DIR=$APP_DIR"
    echo "export APP_ENV=$APP_ENV"
    echo "export APP_PORT=$APP_PORT"
    echo "export PYTHONUNBUFFERED=1"
    echo "export NODE_ENV=${NODE_ENV:-production}"
    echo "export PATH=$APP_DIR/bin:\$PATH"
  } > /etc/profile.d/app_env.sh
}

# Ensure the Python virtual environment is auto-activated for interactive shells
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_dir="$APP_DIR/.venv"
  local marker="# Auto-activate Python venv"
  if ! grep -qF "$marker" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "$marker" >> "$bashrc_file"
    echo "if [ -d \"$venv_dir\" ]; then . \"$venv_dir/bin/activate\"; fi" >> "$bashrc_file"
  fi
}

# Clean bash wrapper to avoid sourcing broken startup files
setup_clean_bash_wrapper() {
  # Neutralize any existing BASH_ENV file to prevent Bash startup parse errors
  /usr/bin/env -i BASH_ENV="${BASH_ENV:-}" PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -lc 'f="$BASH_ENV"; if [ -n "$f" ]; then d=$(dirname "$f"); mkdir -p "$d"; if [ -f "$f" ] && [ ! -f "$f.bak" ]; then cp -a "$f" "$f.bak"; fi; printf "%s\n" "# stubbed to prevent Bash startup parse errors" "true" > "$f"; fi'

  # Remove any BASH_ENV/ENV definitions from /etc/environment
  /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -lc '[ -w /etc/environment ] && { cp -a /etc/environment /etc/environment.bak 2>/dev/null || true; sed -i -E "/^(BASH_ENV|ENV)=/d" /etc/environment || true; } || true'

  # Wrap /bin/bash to ignore BASH_ENV/ENV even if re-injected
  sh -lc 'set -e; if ! grep -q "exec /bin/bash.real" /bin/bash 2>/dev/null; then if [ ! -f /bin/bash.real ]; then cp -a /bin/bash /bin/bash.real; fi; printf "%s\n" "#!/bin/sh" "unset BASH_ENV ENV" "exec /bin/bash.real \"$@\"" > /bin/.bash.wrapper.new; chmod 0755 /bin/.bash.wrapper.new; mv -f /bin/.bash.wrapper.new /bin/bash; fi'
  sh -lc 'printf "%s\n" "# Ensure BASH_ENV/ENV are not set in interactive shells" "unset BASH_ENV ENV" > /etc/profile.d/99-clean-bash-env.sh'
}

# ----------------------------
# Tech stack detectors
# ----------------------------
is_python_project() {
  [[ -f "$APP_DIR/requirements.txt" || -f "$APP_DIR/pyproject.toml" || -f "$APP_DIR/Pipfile" ]]
}
is_node_project() {
  [[ -f "$APP_DIR/package.json" ]]
}
is_go_project() {
  [[ -f "$APP_DIR/go.mod" ]]
}
is_rust_project() {
  [[ -f "$APP_DIR/Cargo.toml" ]]
}
is_ruby_project() {
  [[ -f "$APP_DIR/Gemfile" ]]
}
is_php_project() {
  [[ -f "$APP_DIR/composer.json" ]]
}
is_java_maven_project() {
  [[ -f "$APP_DIR/pom.xml" ]]
}
is_java_gradle_project() {
  [[ -f "$APP_DIR/build.gradle" || -f "$APP_DIR/build.gradle.kts" ]]
}

# ----------------------------
# Python setup
# ----------------------------
setup_python() {
  log "Detected Python project. Installing Python runtime and dependencies..."
  case "$PKG_MGR" in
    apt)
      install_pkgs python3 python3-pip python3-venv python3-dev gcc libffi-dev
      ;;
    apk)
      install_pkgs python3 py3-pip python3-dev gcc musl-dev libffi-dev openssl-dev
      ;;
    dnf|yum)
      install_pkgs python3 python3-pip python3-devel gcc libffi-devel openssl-devel
      ;;
  esac

  # Ensure pip is up-to-date
  python3 -m pip install --upgrade pip setuptools wheel >/dev/null

  # Create venv if not exists
  VENV_DIR="$APP_DIR/.venv"
  if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    if [[ $is_alpine -eq 1 ]]; then
      # Alpine sometimes needs ensurepip
      "$VENV_DIR/bin/python" -m ensurepip || true
    fi
  else
    info "Virtual environment already exists at $VENV_DIR"
  fi

  # Activate venv and install dependencies
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null

  if [[ -f "$APP_DIR/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"
  elif [[ -f "$APP_DIR/Pipfile" ]]; then
    log "Pipfile detected; installing pipenv and dependencies"
    "$VENV_DIR/bin/pip" install pipenv
    cd "$APP_DIR"
    "$VENV_DIR/bin/pipenv" install --deploy || "$VENV_DIR/bin/pipenv" install
  elif [[ -f "$APP_DIR/pyproject.toml" ]]; then
    if grep -qi '\[tool.poetry\]' "$APP_DIR/pyproject.toml"; then
      log "Poetry project detected; installing poetry and dependencies"
      "$VENV_DIR/bin/pip" install poetry
      cd "$APP_DIR"
      "$VENV_DIR/bin/poetry" install --no-interaction --no-ansi
    else
      log "PyProject detected; attempting editable install"
      cd "$APP_DIR"
      "$VENV_DIR/bin/pip" install -e .
    fi
  else
    info "No dependency manifest found; skipping Python dependency installation."
  fi

  # Persist Python environment variables
  {
    echo "VIRTUAL_ENV=$VENV_DIR"
    echo "PATH=$VENV_DIR/bin:\$PATH"
    echo "PYTHONPATH=$APP_DIR:\$PYTHONPATH"
  } >> "$APP_DIR/.env"
  log "Python setup complete."
}

# ----------------------------
# Node.js setup
# ----------------------------
setup_node() {
  log "Detected Node.js project. Installing Node.js runtime and dependencies..."
  # Prefer nvm for consistent versions across distros
  NVM_DIR="/usr/local/nvm"
  if [[ ! -d "$NVM_DIR" ]]; then
    mkdir -p "$NVM_DIR"
    export NVM_DIR
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  # shellcheck disable=SC1090
  source "$NVM_DIR/nvm.sh"

  if command -v node >/dev/null 2>&1; then
    CURRENT_NODE=$(node -v | sed 's/^v//')
    if [[ "$CURRENT_NODE" != "$NODE_VERSION" ]]; then
      log "Installing Node.js v$NODE_VERSION via nvm"
      nvm install "$NODE_VERSION"
      nvm alias default "$NODE_VERSION"
      nvm use default
    else
      info "Node.js v$NODE_VERSION already installed."
    fi
  else
    log "Installing Node.js v$NODE_VERSION via nvm"
    nvm install "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    nvm use default
  fi

  # Ensure corepack for yarn/pnpm
  if node -v >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Configure npm to be safe under root
  npm config set fund false
  npm config set audit false
  npm config set update-notifier false
  npm config set unsafe-perm true

  cd "$APP_DIR"
  if [[ -f package-lock.json ]]; then
    log "Installing Node.js dependencies via npm ci"
    npm ci --no-audit --no-fund
  elif [[ -f pnpm-lock.yaml ]]; then
    log "pnpm lockfile detected; installing via pnpm"
    corepack prepare pnpm@latest --activate || npm i -g pnpm
    pnpm install --frozen-lockfile || pnpm install
  elif [[ -f yarn.lock ]]; then
    log "yarn lockfile detected; installing via yarn"
    corepack prepare yarn@stable --activate || npm i -g yarn
    yarn install --frozen-lockfile || yarn install
  else
    log "Installing Node.js dependencies via npm install"
    npm install --no-audit --no-fund
  fi

  {
    echo "NVM_DIR=$NVM_DIR"
    echo "PATH=$NVM_DIR/versions/node/v$NODE_VERSION/bin:\$PATH"
    echo "NODE_ENV=${NODE_ENV:-production}"
  } >> "$APP_DIR/.env"

  log "Node.js setup complete."
}

# ----------------------------
# Go setup
# ----------------------------
setup_go() {
  log "Detected Go project. Installing Go runtime and dependencies..."
  case "$PKG_MGR" in
    apt) install_pkgs golang ;;
    apk) install_pkgs go ;;
    dnf|yum) install_pkgs golang ;;
  esac
  export GOPATH="${GOPATH:-$APP_DIR/.gopath}"
  export GOCACHE="${GOCACHE:-$APP_DIR/.cache/go-build}"
  mkdir -p "$GOPATH" "$GOCACHE"
  {
    echo "GOPATH=$GOPATH"
    echo "GOCACHE=$GOCACHE"
    echo "PATH=\$GOPATH/bin:\$PATH"
  } >> "$APP_DIR/.env"
  cd "$APP_DIR"
  if [[ -f go.mod ]]; then
    log "Downloading Go modules..."
    go mod download
  fi
  log "Go setup complete."
}

# ----------------------------
# Rust setup
# ----------------------------
setup_rust() {
  log "Detected Rust project. Installing Rust toolchain and dependencies..."
  if ! command -v rustup >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y
  fi
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
  rustup toolchain install "$RUST_TOOLCHAIN"
  rustup default "$RUST_TOOLCHAIN"
  {
    echo "CARGO_HOME=$HOME/.cargo"
    echo "RUSTUP_HOME=$HOME/.rustup"
    echo "PATH=$HOME/.cargo/bin:\$PATH"
  } >> "$APP_DIR/.env"
  cd "$APP_DIR"
  if [[ -f Cargo.toml ]]; then
    log "Fetching Rust dependencies (cargo fetch)..."
    cargo fetch
  fi
  log "Rust setup complete."
}

# ----------------------------
# Ruby setup
# ----------------------------
setup_ruby() {
  log "Detected Ruby project. Installing Ruby and dependencies..."
  case "$PKG_MGR" in
    apt) install_pkgs ruby-full build-essential ;;
    apk) install_pkgs ruby ruby-dev build-base ;;
    dnf|yum) install_pkgs ruby ruby-devel make gcc ;;
  esac
  cd "$APP_DIR"
  if [[ -f Gemfile ]]; then
    if ! command -v bundle >/dev/null 2>&1; then
      gem install bundler --no-document
    fi
    log "Installing Ruby gems via bundler..."
    bundle config set path 'vendor/bundle'
    bundle install --jobs "$(nproc)" --retry 3
  fi
  log "Ruby setup complete."
}

# ----------------------------
# PHP setup
# ----------------------------
setup_php() {
  log "Detected PHP project. Installing PHP and dependencies..."
  case "$PKG_MGR" in
    apt) install_pkgs php-cli php-xml php-json php-mbstring php-curl php-zip unzip ;;
    apk) install_pkgs php81 php81-cli php81-xml php81-json php81-mbstring php81-curl php81-zip unzip || install_pkgs php php-cli php-xml php-json php-mbstring php-curl php-zip unzip ;;
    dnf|yum) install_pkgs php-cli php-xml php-json php-mbstring php-curl php-zip unzip ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
  cd "$APP_DIR"
  if [[ -f composer.json ]]; then
    log "Installing PHP dependencies via composer..."
    composer install --no-interaction --prefer-dist --no-progress
  fi
  log "PHP setup complete."
}

# ----------------------------
# Java setup
# ----------------------------
setup_java() {
  if is_java_maven_project; then
    log "Detected Maven project. Installing JDK and Maven..."
    case "$PKG_MGR" in
      apt) install_pkgs openjdk-17-jdk maven ;;
      apk) install_pkgs openjdk17 maven ;;
      dnf|yum) install_pkgs java-17-openjdk maven ;;
    esac
    cd "$APP_DIR"
    log "Pre-fetching Maven dependencies (optional)..."
    mvn -q -e -DskipTests dependency:go-offline || true
  elif is_java_gradle_project; then
    log "Detected Gradle project. Installing JDK and Gradle..."
    case "$PKG_MGR" in
      apt) install_pkgs openjdk-17-jdk gradle ;;
      apk) install_pkgs openjdk17 gradle ;;
      dnf|yum) install_pkgs java-17-openjdk gradle ;;
    esac
    cd "$APP_DIR"
    log "Pre-fetching Gradle dependencies (optional)..."
    gradle --no-daemon build -x test || true
  fi
  log "Java setup complete."
}

# ----------------------------
# Main logic: detection and setup
# ----------------------------
main() {
  log "Starting environment setup..."

  detect_pkg_mgr
  install_common_deps
  setup_clean_bash_wrapper
  setup_directories
  setup_user
  write_env_files
  setup_auto_activate

  # Detect project directory contents
  cd "$APP_DIR"

  local did_any=0

  if is_python_project; then
    setup_python
    did_any=1
  fi

  if is_node_project; then
    setup_node
    did_any=1
  fi

  if is_go_project; then
    setup_go
    did_any=1
  fi

  if is_rust_project; then
    setup_rust
    did_any=1
  fi

  if is_ruby_project; then
    setup_ruby
    did_any=1
  fi

  if is_php_project; then
    setup_php
    did_any=1
  fi

  if is_java_maven_project || is_java_gradle_project; then
    setup_java
    did_any=1
  fi

  if [[ "$did_any" -eq 0 ]]; then
    warn "No known project manifest found in $APP_DIR."
    warn "This script supports Python (requirements.txt/pyproject.toml), Node.js (package.json), Go (go.mod), Rust (Cargo.toml), Ruby (Gemfile), PHP (composer.json), Java (pom.xml/build.gradle)."
    warn "You can still use the installed common tools or set APP_DIR to the correct location."
  fi

  # Final permissions
  if [[ -n "$RUN_USER" ]]; then
    chown -R "$RUN_UID":"$RUN_GID" "$APP_DIR" || true
  fi

  log "Environment setup completed successfully."
  info "Environment variables written to: $APP_DIR/.env and /etc/profile.d/app_env.sh"
}

main "$@"