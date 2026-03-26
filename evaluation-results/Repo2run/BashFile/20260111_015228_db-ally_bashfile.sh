#!/usr/bin/env bash

# Safe, idempotent environment setup script for containerized projects
# Detects common tech stacks (Python, Node.js, Ruby, Java, Go, PHP, Rust) and installs required runtimes and dependencies.
# Designed to run as root inside Docker with Debian/Ubuntu, Alpine, or RHEL/Fedora/CentOS base images.

set -Eeuo pipefail

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# Logging
log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
  echo -e "${YELLOW}[WARNING] $*${NC}" >&2
}
err() {
  echo -e "${RED}[ERROR] $*${NC}" >&2
}

# Error handler
error_handler() {
  local exit_code=$1
  local line_no=$2
  err "Setup failed with exit code $exit_code at line $line_no"
  exit "$exit_code"
}
trap 'error_handler $? $LINENO' ERR

# Defaults and configuration
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_ENV="${APP_ENV:-production}"
APP_NAME="${APP_NAME:-containerized-app}"
# Ports will be set per tech stack if detected; default fallback
APP_PORT="${APP_PORT:-8080}"

# Package manager detection and helpers
PKG_MGR=""
NONINTERACTIVE_ENV=""

detect_pkg_mgr() {
  if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    err "No supported package manager found (apk, apt-get, dnf, yum)."
    exit 1
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apk)
      apk update >/dev/null
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      NONINTERACTIVE_ENV="DEBIAN_FRONTEND=noninteractive"
      apt-get update -y -qq
      ;;
    dnf)
      dnf -y -q makecache
      ;;
    yum)
      yum -y -q makecache
      ;;
  esac
}

pkg_install() {
  # Install packages passed as arguments
  case "$PKG_MGR" in
    apk)
      apk add --no-cache "$@"
      ;;
    apt)
      apt-get install -y -qq --no-install-recommends "$@"
      ;;
    dnf)
      dnf install -y -q "$@"
      ;;
    yum)
      yum install -y -q "$@"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      rm -rf /var/cache/apk/*
      ;;
    dnf)
      dnf clean all
      ;;
    yum)
      yum clean all
      ;;
  esac
}

# Create system user and group if running as root
ensure_app_user() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root; skipping user creation"
    return
  fi
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    groupadd --system "$APP_GROUP" || true
  fi
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --gid "$APP_GROUP" --shell /usr/sbin/nologin "$APP_USER" || true
  fi
}

# Setup directories and permissions
setup_directories() {
  mkdir -p "$APP_DIR"
  mkdir -p "$APP_DIR"/{bin,logs,tmp}
  # Only chown if root
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR"
  fi
  chmod -R u+rwX,g+rwX "$APP_DIR"
  umask 022
}

# Detect tech stack based on files
detect_stack() {
  local stack="unknown"
  if [ -f "$APP_DIR/pyproject.toml" ] || [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/setup.py" ] || [ -f "$APP_DIR/Pipfile" ]; then
    stack="python"
  elif [ -f "$APP_DIR/package.json" ]; then
    stack="node"
  elif [ -f "$APP_DIR/Gemfile" ]; then
    stack="ruby"
  elif [ -f "$APP_DIR/pom.xml" ] || [ -f "$APP_DIR/build.gradle" ] || [ -f "$APP_DIR/build.gradle.kts" ]; then
    stack="java"
  elif [ -f "$APP_DIR/go.mod" ]; then
    stack="go"
  elif [ -f "$APP_DIR/composer.json" ]; then
    stack="php"
  elif [ -f "$APP_DIR/Cargo.toml" ]; then
    stack="rust"
  elif ls "$APP_DIR"/*.sln "$APP_DIR"/*.csproj >/dev/null 2>&1; then
    stack="dotnet"
  fi
  echo "$stack"
}

# Install base system tools
install_base_system_tools() {
  log "Installing base system tools..."
  pkg_update
  case "$PKG_MGR" in
    apk)
      pkg_install ca-certificates curl git bash coreutils build-base openssl
      ;;
    apt)
      pkg_install ca-certificates curl git bash coreutils build-essential pkg-config openssl
      ;;
    dnf)
      pkg_install ca-certificates curl git bash coreutils gcc gcc-c++ make openssl
      ;;
    yum)
      pkg_install ca-certificates curl git bash coreutils gcc gcc-c++ make openssl
      ;;
  esac
  update-ca-certificates || true
  pkg_cleanup
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  pkg_update
  case "$PKG_MGR" in
    apk)
      pkg_install python3 py3-pip python3-dev build-base
      ;;
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev build-essential
      ;;
    dnf)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make
      ;;
    yum)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make
      ;;
  esac
  pkg_cleanup

  # Create and activate venv
  VENV_DIR="$APP_DIR/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
  fi
  # Use venv pip without activating shell
  PIP_BIN="$VENV_DIR/bin/pip"
  PY_BIN="$VENV_DIR/bin/python"
  "$PIP_BIN" --version >/dev/null 2>&1 || "$PY_BIN" -m ensurepip

  "$PIP_BIN" install --upgrade pip setuptools wheel

  if [ -f "$APP_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    "$PIP_BIN" install --no-cache-dir -r "$APP_DIR/requirements.txt"
  elif [ -f "$APP_DIR/pyproject.toml" ]; then
    log "Detected pyproject.toml; attempting to install via pip"
    "$PIP_BIN" install --no-cache-dir .
  elif [ -f "$APP_DIR/Pipfile" ]; then
    log "Detected Pipfile; installing pipenv and dependencies..."
    "$PIP_BIN" install --no-cache-dir pipenv
    "$VENV_DIR/bin/pipenv" install --deploy --system || warn "pipenv system install failed, using venv"
    "$VENV_DIR/bin/pipenv" install || true
  else
    warn "No Python dependency file found."
  fi

  # Environment defaults
  APP_PORT="${APP_PORT:-5000}"
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  pkg_update
  case "$PKG_MGR" in
    apk)
      pkg_install nodejs npm
      ;;
    apt)
      pkg_install nodejs npm
      ;;
    dnf)
      pkg_install nodejs npm
      ;;
    yum)
      pkg_install nodejs npm
      ;;
  esac
  pkg_cleanup

  # Install node dependencies
  cd "$APP_DIR"
  if [ -f package-lock.json ]; then
    log "Installing Node.js dependencies via npm ci..."
    npm ci --no-audit --no-fund
  elif [ -f yarn.lock ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      log "Installing Yarn..."
      npm install -g yarn
    fi
    log "Installing Node.js dependencies via yarn install..."
    yarn install --frozen-lockfile
  else
    log "Installing Node.js dependencies via npm install..."
    npm install --no-audit --no-fund
  fi
  npm cache clean --force || true

  APP_PORT="${APP_PORT:-3000}"
  export NODE_ENV="${NODE_ENV:-production}"
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  pkg_update
  case "$PKG_MGR" in
    apk)
      pkg_install ruby ruby-bundler ruby-dev build-base
      ;;
    apt)
      pkg_install ruby-full build-essential
      ;;
    dnf)
      pkg_install ruby rubygems ruby-devel gcc gcc-c++ make
      ;;
    yum)
      pkg_install ruby rubygems ruby-devel gcc gcc-c++ make
      ;;
  esac
  pkg_cleanup

  cd "$APP_DIR"
  if command -v bundle >/dev/null 2>&1; then
    log "Installing Ruby gems via bundler..."
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs "$(nproc)" --retry 3
  else
    warn "Bundler not found; attempting gem install bundler..."
    gem install bundler
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs "$(nproc)" --retry 3
  fi

  APP_PORT="${APP_PORT:-3000}"
  export RACK_ENV="${RACK_ENV:-production}"
  export RAILS_ENV="${RAILS_ENV:-production}"
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  pkg_update
  case "$PKG_MGR" in
    apk)
      pkg_install openjdk17-jdk maven gradle
      ;;
    apt)
      pkg_install openjdk-17-jdk maven gradle
      ;;
    dnf)
      pkg_install java-17-openjdk-devel maven gradle
      ;;
    yum)
      pkg_install java-17-openjdk-devel maven gradle
      ;;
  esac
  pkg_cleanup

  cd "$APP_DIR"
  if [ -f pom.xml ]; then
    log "Maven project detected; resolving dependencies..."
    mvn -B -ntp -q dependency:go-offline || warn "Maven offline resolution failed"
  fi
  if [ -f build.gradle ] || [ -f build.gradle.kts ]; then
    log "Gradle project detected; resolving dependencies..."
    gradle -q --no-daemon tasks >/dev/null 2>&1 || true
    gradle -q --no-daemon build -x test || warn "Gradle build failed; dependencies may still be resolved"
  fi

  APP_PORT="${APP_PORT:-8080}"
  export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}"
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  pkg_update
  case "$PKG_MGR" in
    apk)
      pkg_install go
      ;;
    apt)
      pkg_install golang
      ;;
    dnf)
      pkg_install golang
      ;;
    yum)
      pkg_install golang
      ;;
  esac
  pkg_cleanup

  export GOPATH="${GOPATH:-$APP_DIR/.gopath}"
  export GOCACHE="${GOCACHE:-$APP_DIR/.gocache}"
  mkdir -p "$GOPATH" "$GOCACHE"
  cd "$APP_DIR"
  if [ -f go.mod ]; then
    log "Resolving Go modules..."
    go mod download
  fi
  APP_PORT="${APP_PORT:-8080}"
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  pkg_update
  case "$PKG_MGR" in
    apk)
      pkg_install php php-cli php-phar php-openssl
      ;;
    apt)
      pkg_install php-cli php php-mbstring php-xml php-curl
      ;;
    dnf)
      pkg_install php-cli php php-mbstring php-xml php-json php-curl
      ;;
    yum)
      pkg_install php-cli php php-mbstring php-xml php-json php-curl
      ;;
  esac
  pkg_cleanup

  # Composer install
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || err "Failed to download composer installer"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer || err "Composer setup failed"
    rm -f composer-setup.php
  fi

  cd "$APP_DIR"
  if [ -f composer.json ]; then
    log "Installing PHP dependencies via composer..."
    composer install --no-interaction --prefer-dist --no-progress --no-suggest
  fi
  APP_PORT="${APP_PORT:-8000}"
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  pkg_update
  case "$PKG_MGR" in
    apk)
      pkg_install build-base
      ;;
    apt)
      pkg_install build-essential
      ;;
    dnf)
      pkg_install gcc gcc-c++ make
      ;;
    yum)
      pkg_install gcc gcc-c++ make
      ;;
  esac
  pkg_cleanup

  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    export PATH="$PATH:$HOME/.cargo/bin"
  fi

  cd "$APP_DIR"
  if [ -f Cargo.toml ]; then
    log "Fetching Rust dependencies..."
    cargo fetch || warn "cargo fetch failed"
  fi
  APP_PORT="${APP_PORT:-8080}"
}

# .NET setup (limited due to external repos)
setup_dotnet() {
  warn ".NET projects detected; installing dotnet SDK is not supported via generic package managers in minimal containers."
  warn "Please use a base image with dotnet SDK preinstalled (e.g., mcr.microsoft.com/dotnet/sdk)."
}

# Write environment file
write_env_file() {
  local env_file="$APP_DIR/.env"
  log "Writing environment configuration to $env_file"
  {
    echo "APP_NAME=${APP_NAME}"
    echo "APP_ENV=${APP_ENV}"
    echo "APP_PORT=${APP_PORT}"
    echo "APP_DIR=${APP_DIR}"
    # Language-specific hints
    if [ -d "$APP_DIR/.venv" ]; then
      echo "VENV_PATH=${APP_DIR}/.venv"
    fi
  } > "$env_file"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$APP_USER":"$APP_GROUP" "$env_file"
  fi
  chmod 0644 "$env_file"
}

# Main
main() {
  log "Starting environment setup for $APP_NAME"
  detect_pkg_mgr
  ensure_app_user
  setup_directories
  install_base_system_tools

  # Detect stack
  STACK=$(detect_stack)
  log "Detected stack: $STACK"

  case "$STACK" in
    python)
      setup_python
      ;;
    node)
      setup_node
      ;;
    ruby)
      setup_ruby
      ;;
    java)
      setup_java
      ;;
    go)
      setup_go
      ;;
    php)
      setup_php
      ;;
    rust)
      setup_rust
      ;;
    dotnet)
      setup_dotnet
      ;;
    unknown)
      warn "No recognized project files found in ${APP_DIR}. Installed base tools only."
      ;;
  esac

  write_env_file

  # Final permissions
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR"
  fi

  log "Environment setup completed successfully."
  log "Project directory: $APP_DIR"
  log "Environment: $APP_ENV"
  log "Default port: ${APP_PORT}"
}

# Execute
main "$@"