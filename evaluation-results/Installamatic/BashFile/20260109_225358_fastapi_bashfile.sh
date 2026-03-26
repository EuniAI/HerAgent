#!/usr/bin/env bash
# Universal project environment setup script for containerized (Docker) environments.
# - Installs system packages and language runtimes
# - Installs project dependencies based on detected project type
# - Configures environment variables and PATH
# - Creates non-root user and sets correct permissions
# - Idempotent and safe to re-run

set -Eeuo pipefail

# Globals and defaults
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"

# Versions/channels (overridable via environment)
JAVA_VERSION="${JAVA_VERSION:-17}"
DOTNET_CHANNEL="${DOTNET_CHANNEL:-LTS}"
GO_VERSION="${GO_VERSION:-}" # if empty, use distro package
NODE_MAJOR="${NODE_MAJOR:-20}" # NodeSource channel or Alpine package; defaults to Node 20 LTS
PYTHON_VERSION_PKG="${PYTHON_VERSION_PKG:-3}" # distro major version package selector (apt: python3, apk: python3)

# Runtime flags (auto-detected)
HAS_NODE=0
HAS_PYTHON=0
HAS_RUBY=0
HAS_JAVA=0
HAS_GRADLE=0
HAS_MAVEN=0
HAS_GO=0
HAS_DOTNET=0
HAS_PHP=0
HAS_RUST=0

# Colors for output (no-op if not a TTY)
if [ -t 1 ]; then
  GREEN=$(printf '\033[0;32m')
  RED=$(printf '\033[0;31m')
  YELLOW=$(printf '\033[1;33m')
  BLUE=$(printf '\033[0;34m')
  NC=$(printf '\033[0m')
else
  GREEN=""; RED=""; YELLOW=""; BLUE=""; NC=""
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
trap 'err "Setup failed at line $LINENO. See logs above."' ERR

# Detect OS and package manager
OS_FAMILY=""
PKG_MGR=""
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "${ID_LIKE:-$ID}" in
      *debian*) OS_FAMILY="debian";;
      *alpine*) OS_FAMILY="alpine";;
      *rhel*|*fedora*|*centos*) OS_FAMILY="rhel";;
      *) OS_FAMILY="${ID:-unknown}";;
    esac
  else
    OS_FAMILY="unknown"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    PKG_MGR="unknown"
  fi
  log "Detected OS family: $OS_FAMILY, package manager: $PKG_MGR"
}

# Package manager helpers
pm_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y ;;
    apk)
      apk update || true ;;
    dnf)
      dnf makecache -y || true ;;
    yum)
      yum makecache -y || true ;;
    *)
      warn "Unknown package manager; skipping update." ;;
  esac
}

pm_install() {
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@" ;;
    apk)
      apk add --no-cache "$@" ;;
    dnf)
      dnf install -y "$@" ;;
    yum)
      yum install -y "$@" ;;
    *)
      err "Unsupported package manager for installing: $*"; return 1 ;;
  esac
}

pm_cleanup() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* ;;
    apk)
      rm -rf /var/cache/apk/* || true ;;
    dnf|yum)
      rm -rf /var/cache/dnf || true
      rm -rf /var/cache/yum || true ;;
    *)
      ;;
  esac
}

# Install baseline tools commonly required
install_common_packages() {
  log "Installing common system packages..."
  pm_update
  case "$PKG_MGR" in
    apt)
      pm_install ca-certificates curl wget gnupg git openssl unzip zip tar xz-utils \
                 procps net-tools iproute2 locales \
                 build-essential pkg-config libssl-dev \
                 python3 python3-venv python3-pip
      ;;
    apk)
      pm_install ca-certificates curl wget git openssl unzip zip tar xz \
                 bash shadow su-exec \
                 build-base pkgconfig openssl-dev \
                 python3 py3-pip
      ;;
    dnf|yum)
      pm_install ca-certificates curl wget gnupg2 git openssl unzip zip tar xz \
                 which procps-ng iproute \
                 gcc gcc-c++ make pkgconf-pkg-config openssl-devel \
                 python3 python3-pip python3-virtualenv
      ;;
    *)
      warn "Skipping common system package installation (unknown package manager)."
      ;;
  esac
  update-ca-certificates || true
  pm_cleanup
  log "Common packages installed."
}

# Ensure app user, group, directories
ensure_user_and_dirs() {
  log "Setting up application directories and user..."
  mkdir -p "$APP_DIR" "$APP_DIR/tmp" "$APP_DIR/logs" "$APP_DIR/.cache"
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if command -v addgroup >/dev/null 2>&1; then
      addgroup -g "$APP_GID" "$APP_GROUP"
    else
      groupadd -g "$APP_GID" "$APP_GROUP"
    fi
  fi
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if command -v adduser >/dev/null 2>&1; then
      adduser -D -G "$APP_GROUP" -u "$APP_UID" "$APP_USER" || true
      # Busybox adduser may not support all flags; fallback to useradd
      id -u "$APP_USER" >/dev/null 2>&1 || useradd -m -u "$APP_UID" -g "$APP_GROUP" -s /bin/bash "$APP_USER"
    else
      useradd -m -u "$APP_UID" -g "$APP_GROUP" -s /bin/bash "$APP_USER"
    fi
  fi
  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
  chmod -R u+rwX,go-rwx "$APP_DIR" || true
  log "User and directories set: $APP_USER ($APP_UID:$APP_GID), APP_DIR=$APP_DIR"
}

# Detect project type by files present
detect_project_type() {
  cd "$APP_DIR"
  # Node.js
  if [ -f package.json ]; then HAS_NODE=1; fi
  # Python
  if [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f Pipfile ] || [ -f setup.py ] || [ -f setup.cfg ]; then HAS_PYTHON=1; fi
  # Ruby
  if [ -f Gemfile ]; then HAS_RUBY=1; fi
  # Java
  if [ -f pom.xml ] || [ -f mvnw ]; then HAS_JAVA=1; HAS_MAVEN=1; fi
  if [ -f build.gradle ] || [ -f build.gradle.kts ] || [ -f gradlew ]; then HAS_JAVA=1; HAS_GRADLE=1; fi
  # Go
  if [ -f go.mod ] || [ -f go.sum ]; then HAS_GO=1; fi
  # .NET
  if compgen -G "*.sln" >/dev/null || compgen -G "*.csproj" >/dev/null || [ -f global.json ]; then HAS_DOTNET=1; fi
  # PHP
  if [ -f composer.json ]; then HAS_PHP=1; fi
  # Rust
  if [ -f Cargo.toml ]; then HAS_RUST=1; fi

  log "Detected project stack: Node=$HAS_NODE Python=$HAS_PYTHON Ruby=$HAS_RUBY Java=$HAS_JAVA Maven=$HAS_MAVEN Gradle=$HAS_GRADLE Go=$HAS_GO .NET=$HAS_DOTNET PHP=$HAS_PHP Rust=$HAS_RUST"
}

# Install Node.js and JS package managers
install_node() {
  if command -v node >/dev/null 2>&1; then
    log "Node.js already installed: $(node -v)"
  else
    log "Installing Node.js..."
    case "$PKG_MGR" in
      apt)
        pm_update
        pm_install ca-certificates curl gnupg
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
        pm_install nodejs
        pm_cleanup
        ;;
      dnf|yum)
        pm_update
        pm_install ca-certificates curl gnupg2
        curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
        pm_install nodejs
        ;;
      apk)
        pm_update
        # Use latest available Node package on Alpine
        pm_install nodejs npm
        ;;
      *)
        err "Cannot install Node.js: unsupported package manager."
        return 1
        ;;
    esac
  fi

  # Enable corepack to manage yarn/pnpm if available (Node >=16)
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Install project dependencies
  if [ "$HAS_NODE" -eq 1 ]; then
    log "Installing Node.js dependencies..."
    if [ -f yarn.lock ]; then
      if command -v yarn >/dev/null 2>&1; then :
      else
        if command -v corepack >/dev/null 2>&1; then corepack prepare yarn@stable --activate || true; else pm_install yarn || true; fi
      fi
      if [ "${NODE_ENV:-$APP_ENV}" = "production" ] && [ -f package.json ] && grep -q '"private"' package.json 2>/dev/null; then
        yarn install --frozen-lockfile --production=true
      else
        yarn install --frozen-lockfile || yarn install
      fi
    elif [ -f pnpm-lock.yaml ]; then
      if command -v pnpm >/dev/null 2>&1; then :
      else
        if command -v corepack >/dev/null 2>&1; then corepack prepare pnpm@latest --activate || true; fi
      fi
      pnpm install --frozen-lockfile || pnpm install
    elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
      npm ci || npm install
    else
      npm install || true
    fi
    log "Node.js dependencies installed."
  fi
}

# Install Python and dependencies
install_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    log "Installing Python 3..."
    case "$PKG_MGR" in
      apt) pm_update; pm_install "python${PYTHON_VERSION_PKG}" "python${PYTHON_VERSION_PKG}-venv" "python${PYTHON_VERSION_PKG}-pip"; pm_cleanup ;;
      apk) pm_update; pm_install python3 py3-pip ;;
      dnf|yum) pm_update; pm_install python3 python3-pip ;;
      *) warn "Cannot install Python: unknown package manager." ;;
    esac
  fi

  if [ "$HAS_PYTHON" -eq 1 ]; then
    log "Setting up Python virtual environment..."
    PY_BIN="${PY_BIN:-$(command -v python3)}"
    VENV_PATH="$APP_DIR/.venv"
    if [ ! -d "$VENV_PATH" ]; then
      "$PY_BIN" -m venv "$VENV_PATH"
    fi
    # shellcheck disable=SC1090
    . "$VENV_PATH/bin/activate"
    pip install --no-cache-dir --upgrade pip setuptools wheel

    if [ -f pyproject.toml ] && grep -q "\[tool.poetry\]" pyproject.toml 2>/dev/null; then
      pip install --no-cache-dir poetry
      if [ "$APP_ENV" = "production" ]; then
        poetry install --no-dev --no-interaction --no-ansi
      else
        poetry install --no-interaction --no-ansi
      fi
    elif [ -f Pipfile ]; then
      pip install --no-cache-dir pipenv
      if [ "$APP_ENV" = "production" ]; then
        PIPENV_VENV_IN_PROJECT=1 pipenv sync --system --deploy || PIPENV_VENV_IN_PROJECT=1 pipenv install --system --deploy
      else
        PIPENV_VENV_IN_PROJECT=1 pipenv install --system
      fi
    elif [ -f requirements.txt ]; then
      if [ "$APP_ENV" = "production" ] && [ -f requirements-prod.txt ]; then
        pip install --no-cache-dir -r requirements-prod.txt
      else
        pip install --no-cache-dir -r requirements.txt
      fi
    elif [ -f setup.py ] || [ -f setup.cfg ]; then
      pip install --no-cache-dir -e .
    fi
    log "Python dependencies installed."
  fi
}

# Install Ruby and bundle
install_ruby() {
  if [ "$HAS_RUBY" -eq 0 ]; then return 0; fi
  if ! command -v ruby >/dev/null 2>&1; then
    log "Installing Ruby..."
    case "$PKG_MGR" in
      apt) pm_update; pm_install ruby-full build-essential libssl-dev zlib1g-dev libreadline-dev; pm_cleanup ;;
      apk) pm_update; pm_install ruby ruby-dev build-base openssl-dev zlib-dev readline-dev; ;;
      dnf|yum) pm_update; pm_install ruby ruby-devel gcc gcc-c++ make openssl-devel zlib-devel readline-devel; ;;
      *) err "Unsupported package manager for Ruby installation."; return 1 ;;
    esac
  fi
  gem install bundler --no-document || true
  if [ -f Gemfile ]; then
    log "Installing Ruby gems via bundler..."
    if [ "$APP_ENV" = "production" ]; then
      bundle config set without 'development test'
    fi
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4 --retry=3
    log "Ruby gems installed."
  fi
}

# Install Java (OpenJDK) and build tools
install_java() {
  if [ "$HAS_JAVA" -eq 0 ]; then return 0; fi
  if ! command -v javac >/dev/null 2>&1; then
    log "Installing OpenJDK $JAVA_VERSION..."
    case "$PKG_MGR" in
      apt) pm_update; pm_install "openjdk-${JAVA_VERSION}-jdk" ca-certificates; pm_cleanup ;;
      apk) pm_update; pm_install "openjdk${JAVA_VERSION}" "openjdk${JAVA_VERSION}-jre" ca-certificates || pm_install openjdk17 openjdk17-jre ca-certificates ;;
      dnf|yum) pm_update; pm_install "java-${JAVA_VERSION}-openjdk" "java-${JAVA_VERSION}-openjdk-devel" ca-certificates || pm_install java-17-openjdk java-17-openjdk-devel ca-certificates ;;
      *) err "Unsupported package manager for Java installation."; return 1 ;;
    esac
  fi
  if [ "$HAS_MAVEN" -eq 1 ]; then
    if [ -x "./mvnw" ]; then
      log "Using Maven Wrapper to pre-fetch dependencies..."
      ./mvnw -B -DskipTests dependency:go-offline || true
    else
      log "Installing Maven via package manager..."
      case "$PKG_MGR" in
        apt) pm_update; pm_install maven; pm_cleanup ;;
        apk) pm_update; pm_install maven ;;
        dnf|yum) pm_update; pm_install maven ;;
      esac
      mvn -B -DskipTests dependency:go-offline || true
    fi
  fi
  if [ "$HAS_GRADLE" -eq 1 ]; then
    if [ -x "./gradlew" ]; then
      log "Using Gradle Wrapper to pre-fetch dependencies..."
      ./gradlew --no-daemon build -x test || ./gradlew --no-daemon tasks || true
    else
      log "Installing Gradle via package manager..."
      case "$PKG_MGR" in
        apt) pm_update; pm_install gradle; pm_cleanup ;;
        apk) pm_update; pm_install gradle ;;
        dnf|yum) pm_update; pm_install gradle ;;
      esac
      gradle --no-daemon build -x test || true
    fi
  fi
}

# Install Go and modules
install_go() {
  if [ "$HAS_GO" -eq 0 ]; then return 0; fi
  if ! command -v go >/dev/null 2>&1; then
    log "Installing Go..."
    case "$PKG_MGR" in
      apt) pm_update; pm_install golang; pm_cleanup ;;
      apk) pm_update; pm_install go ;;
      dnf|yum) pm_update; pm_install golang ;;
      *)
        if [ -n "$GO_VERSION" ]; then
          ARCH=$(uname -m)
          case "$ARCH" in
            x86_64) GOARCH=amd64 ;;
            aarch64|arm64) GOARCH=arm64 ;;
            armv7l) GOARCH=armv6l ;;
            *) err "Unsupported architecture for Go: $ARCH"; return 1 ;;
          esac
          TMP_TGZ="/tmp/go${GO_VERSION}.linux-${GOARCH}.tar.gz"
          curl -fsSL -o "$TMP_TGZ" "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz"
          tar -C /usr/local -xzf "$TMP_TGZ"
          ln -sf /usr/local/go/bin/go /usr/local/bin/go
          rm -f "$TMP_TGZ"
        else
          err "No package manager and GO_VERSION not set; cannot install Go."
          return 1
        fi
        ;;
    esac
  fi
  if [ -f go.mod ]; then
    log "Fetching Go modules..."
    go env -w GOMODCACHE="$APP_DIR/.cache/go" || true
    go mod download
  fi
}

# Install .NET SDK and restore
install_dotnet() {
  if [ "$HAS_DOTNET" -eq 0 ]; then return 0; fi
  if [ ! -x /usr/local/bin/dotnet-install.sh ]; then
    log "Downloading dotnet-install.sh..."
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /usr/local/bin/dotnet-install.sh
    chmod +x /usr/local/bin/dotnet-install.sh
  fi
  if [ ! -d /usr/local/dotnet ]; then
    log "Installing .NET SDK (channel: $DOTNET_CHANNEL)..."
    /usr/local/bin/dotnet-install.sh --install-dir /usr/local/dotnet --channel "$DOTNET_CHANNEL" --quality ga
  fi
  if ! command -v dotnet >/dev/null 2>&1; then
    ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
  fi
  log ".NET version: $(/usr/local/dotnet/dotnet --version || dotnet --version || echo 'unknown')"
  if compgen -G "*.sln" >/dev/null || compgen -G "*.csproj" >/dev/null; then
    log "Restoring .NET dependencies..."
    find . -maxdepth 2 -name "*.sln" -print -exec /usr/local/dotnet/dotnet restore {} \; || \
    find . -maxdepth 2 -name "*.csproj" -print -exec /usr/local/dotnet/dotnet restore {} \; || true
  fi
}

# Install PHP and composer
install_php() {
  if [ "$HAS_PHP" -eq 0 ]; then return 0; fi
  if ! command -v php >/dev/null 2>&1; then
    log "Installing PHP CLI..."
    case "$PKG_MGR" in
      apt) pm_update; pm_install php-cli php-curl php-xml php-mbstring php-zip php-json php-openssl; pm_cleanup ;;
      apk) pm_update; pm_install php php-cli php-phar php-json php-openssl php-mbstring php-xml php-curl php-zip ;;
      dnf|yum) pm_update; pm_install php php-cli php-xml php-mbstring php-json php-openssl php-zip php-curl ;;
      *) err "Unsupported package manager for PHP installation."; return 1 ;;
    esac
  fi
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    EXPECTED_CHECKSUM="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
      err "Invalid composer installer checksum"; rm -f composer-setup.php; exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi
  if [ -f composer.json ]; then
    log "Installing PHP dependencies via Composer..."
    if [ "$APP_ENV" = "production" ]; then
      composer install --no-dev --prefer-dist --no-progress --no-interaction
    else
      composer install --prefer-dist --no-progress --no-interaction
    fi
  fi
}

# Install Rust via rustup and fetch dependencies
install_rust() {
  if [ "$HAS_RUST" -eq 0 ]; then return 0; fi
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust (stable, minimal profile)..."
    export RUSTUP_HOME=/usr/local/rustup
    export CARGO_HOME=/usr/local/cargo
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path
    ln -sf /usr/local/cargo/bin/* /usr/local/bin/ || true
  fi
  if [ -f Cargo.toml ]; then
    log "Fetching Rust crates..."
    cargo fetch || true
  fi
}

# Configure environment variables and PATH persistently
configure_environment() {
  log "Configuring environment variables..."
  ENV_FILE="/etc/profile.d/project_env.sh"
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<EOF
# Generated by setup script
export APP_DIR="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
export DOTNET_ROOT="/usr/local/dotnet"
export RUSTUP_HOME="/usr/local/rustup"
export CARGO_HOME="/usr/local/cargo"
export PATH="/usr/local/dotnet:/usr/local/cargo/bin:\$PATH"
EOF
  chmod 644 "$ENV_FILE"
  # Create project .env if not present
  if [ ! -f "$APP_DIR/.env" ]; then
    cat > "$APP_DIR/.env" <<EOF
# Application environment variables
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
# Add your custom variables below
EOF
    chown "$APP_USER:$APP_GROUP" "$APP_DIR/.env"
    chmod 640 "$APP_DIR/.env"
  fi
  log "Environment configuration written to $ENV_FILE and $APP_DIR/.env"
}

# Apply reasonable defaults for common stacks
configure_stack_defaults() {
  if [ "$HAS_NODE" -eq 1 ]; then
    export NODE_ENV="${NODE_ENV:-$APP_ENV}"
    : "${APP_PORT:=3000}"
  fi
  if [ "$HAS_PYTHON" -eq 1 ]; then
    : "${APP_PORT:=8000}"
  fi
  if [ "$HAS_RUBY" -eq 1 ]; then
    : "${APP_PORT:=3000}"
  fi
  if [ "$HAS_JAVA" -eq 1 ] || [ "$HAS_GO" -eq 1 ] || [ "$HAS_DOTNET" -eq 1 ]; then
    : "${APP_PORT:=8080}"
  fi
  if [ "$HAS_PHP" -eq 1 ]; then
    : "${APP_PORT:=9000}"
  fi
}

# Main
main() {
  log "Starting environment setup for project in $APP_DIR"

  # Ensure APP_DIR exists even if called before copying project files
  mkdir -p "$APP_DIR"

  detect_os
  install_common_packages
  ensure_user_and_dirs

  # Ensure we're operating in APP_DIR
  cd "$APP_DIR"

  detect_project_type
  configure_stack_defaults

  # Install runtimes and dependencies by stack
  if [ "$HAS_NODE" -eq 1 ]; then install_node; fi
  if [ "$HAS_PYTHON" -eq 1 ]; then install_python; fi
  if [ "$HAS_RUBY" -eq 1 ]; then install_ruby; fi
  if [ "$HAS_JAVA" -eq 1 ]; then install_java; fi
  if [ "$HAS_GO" -eq 1 ]; then install_go; fi
  if [ "$HAS_DOTNET" -eq 1 ]; then install_dotnet; fi
  if [ "$HAS_PHP" -eq 1 ]; then install_php; fi
  if [ "$HAS_RUST" -eq 1 ]; then install_rust; fi

  configure_environment

  # Final permissions
  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"

  log "Environment setup completed successfully."

  echo
  echo "Summary:"
  echo "- APP_DIR: $APP_DIR"
  echo "- APP_USER: $APP_USER ($APP_UID:$APP_GID)"
  echo "- Detected stacks: Node=$HAS_NODE Python=$HAS_PYTHON Ruby=$HAS_RUBY Java=$HAS_JAVA Go=$HAS_GO .NET=$HAS_DOTNET PHP=$HAS_PHP Rust=$HAS_RUST"
  echo "- Default APP_PORT: ${APP_PORT}"
  echo
  echo "Notes:"
  echo "- Persistent environment variables are saved in /etc/profile.d/project_env.sh"
  echo "- A .env file was created at $APP_DIR/.env (edit as needed)."
  echo "- If using a shell, source /etc/profile to load PATH updates, or start a new shell."
  echo "- To run as non-root in Docker, add: USER ${APP_UID}:${APP_GID} in your Dockerfile after running this script."
}

main "$@"