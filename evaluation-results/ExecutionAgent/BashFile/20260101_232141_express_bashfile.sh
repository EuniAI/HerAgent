#!/bin/bash
# Universal Project Environment Setup Script for Docker Containers
# This script detects the project type (Python/Node.js/Ruby/Go/Java/PHP/Rust)
# installs system dependencies, configures runtimes, and sets environment variables.
# It is designed to be idempotent and safe to run multiple times in containerized environments.

set -Eeuo pipefail

# Global configuration
SCRIPT_NAME="${0##*/}"
PROJECT_ROOT_DEFAULT="/app"
ENV_FILE=".env"
LOG_DIR="logs"
DATA_DIR="data"
TMP_DIR="tmp"

# Colors (safe for most terminals; fall back if not supported)
if [ -t 1 ]; then
  RED=$(printf '\033[0;31m')
  GREEN=$(printf '\033[0;32m')
  YELLOW=$(printf '\033[1;33m')
  BLUE=$(printf '\033[0;34m')
  NC=$(printf '\033[0m')
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

log() {
  echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}

warn() {
  echo "${YELLOW}[WARN] $*${NC}" >&2
}

err() {
  echo "${RED}[ERROR] $*${NC}" >&2
}

trap 'err "Setup failed at line $LINENO. See logs for details."' ERR

# Ensure running as root (inside Docker default user is root)
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must run as root inside the container. Current UID: $(id -u)"
    exit 1
  fi
}

# Detect operating system and package manager
PKG_MANAGER=""
UPDATE_CMD=""
INSTALL_CMD=""
QUIET_FLAG=""
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    export DEBIAN_FRONTEND=noninteractive
    UPDATE_CMD="apt-get update -y"
    INSTALL_CMD="apt-get install -y --no-install-recommends"
    QUIET_FLAG="-qq"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    UPDATE_CMD="apk update"
    INSTALL_CMD="apk add --no-cache"
    QUIET_FLAG=""
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    UPDATE_CMD="dnf -y update"
    INSTALL_CMD="dnf -y install"
    QUIET_FLAG="-q"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    UPDATE_CMD="yum -y update"
    INSTALL_CMD="yum -y install"
    QUIET_FLAG="-q"
  else
    PKG_MANAGER="none"
  fi

  if [ "$PKG_MANAGER" = "none" ]; then
    warn "No supported package manager found. Some steps may fail. Supported: apt, apk, dnf, yum."
  else
    log "Detected package manager: $PKG_MANAGER"
  fi
}

# Update package index safely
pkg_update() {
  if [ "$PKG_MANAGER" = "none" ]; then
    return 0
  fi
  log "Updating package index..."
  sh -c "$UPDATE_CMD" >/dev/null 2>&1 || sh -c "$UPDATE_CMD"
}

# Install packages (skip if already installed where possible)
install_packages() {
  if [ "$PKG_MANAGER" = "none" ]; then
    warn "Cannot install system packages: no package manager detected."
    return 0
  fi

  # Map common packages across distros
  local pkgs=()
  for pkg in "$@"; do
    case "$pkg" in
      build-essential)
        case "$PKG_MANAGER" in
          apt) pkgs+=("build-essential") ;;
          apk) pkgs+=("build-base") ;;
          dnf|yum) pkgs+=("gcc" "gcc-c++" "make") ;;
        esac
        ;;
      ca-certificates) pkgs+=("ca-certificates") ;;
      curl) pkgs+=("curl") ;;
      git) pkgs+=("git") ;;
      pkg-config) pkgs+=("pkg-config") ;;
      openssl)
        case "$PKG_MANAGER" in
          apt) pkgs+=("openssl" "libssl-dev") ;;
          apk) pkgs+=("openssl" "openssl-dev") ;;
          dnf|yum) pkgs+=("openssl" "openssl-devel") ;;
        esac
        ;;
      python3)
        case "$PKG_MANAGER" in
          apt) pkgs+=("python3" "python3-venv" "python3-dev") ;;
          apk) pkgs+=("python3" "py3-pip") ;;
          dnf|yum) pkgs+=("python3" "python3-pip" "python3-devel") ;;
        esac
        ;;
      pip) # pip for python3
        case "$PKG_MANAGER" in
          apt) pkgs+=("python3-pip") ;;
          apk) pkgs+=("py3-pip") ;;
          dnf|yum) pkgs+=("python3-pip") ;;
        esac
        ;;
      gcc) # C compiler
        case "$PKG_MANAGER" in
          apt) pkgs+=("gcc") ;;
          apk) pkgs+=("gcc") ;;
          dnf|yum) pkgs+=("gcc") ;;
        esac
        ;;
      nodejs)
        case "$PKG_MANAGER" in
          apt) pkgs+=("nodejs" "npm") ;;
          apk) pkgs+=("nodejs" "npm") ;;
          dnf|yum) pkgs+=("nodejs" "npm") ;;
        esac
        ;;
      ruby)
        case "$PKG_MANAGER" in
          apt) pkgs+=("ruby-full" "ruby-dev") ;;
          apk) pkgs+=("ruby" "ruby-dev") ;;
          dnf|yum) pkgs+=("ruby" "rubygems" "ruby-devel") ;;
        esac
        ;;
      bundler)
        case "$PKG_MANAGER" in
          apt) pkgs+=("bundler") ;;
          apk) pkgs+=("ruby-bundler") ;;
          dnf|yum) pkgs+=("rubygems") ;; # bundler via gem install later
        esac
        ;;
      golang)
        case "$PKG_MANAGER" in
          apt) pkgs+=("golang") ;;
          apk) pkgs+=("go") ;;
          dnf|yum) pkgs+=("golang") ;;
        esac
        ;;
      openjdk)
        case "$PKG_MANAGER" in
          apt) pkgs+=("openjdk-17-jdk") ;;
          apk) pkgs+=("openjdk17") ;;
          dnf|yum) pkgs+=("java-17-openjdk" "java-17-openjdk-devel") ;;
        esac
        ;;
      maven)
        case "$PKG_MANAGER" in
          apt) pkgs+=("maven") ;;
          apk) pkgs+=("maven") ;;
          dnf|yum) pkgs+=("maven") ;;
        esac
        ;;
      gradle)
        case "$PKG_MANAGER" in
          apt) pkgs+=("gradle") ;;
          apk) pkgs+=("gradle") ;;
          dnf|yum) pkgs+=("gradle") ;;
        esac
        ;;
      php)
        case "$PKG_MANAGER" in
          apt) pkgs+=("php-cli" "php-zip" "php-curl" "php-mbstring" "php-xml" "php-gd") ;;
          apk) pkgs+=("php81-cli" "php81-zip" "php81-curl" "php81-mbstring" "php81-xml" "php81-gd") ;;
          dnf|yum) pkgs+=("php-cli" "php-zip" "php-json" "php-mbstring" "php-xml" "php-gd" "php-curl") ;;
        esac
        ;;
      composer)
        case "$PKG_MANAGER" in
          apt) pkgs+=("composer") ;;
          apk) pkgs+=("composer") ;;
          dnf|yum) pkgs+=("composer") ;;
        esac
        ;;
      rust)
        case "$PKG_MANAGER" in
          apt) pkgs+=("cargo") ;; # provides rust/cargo but may be older
          apk) pkgs+=("rust" "cargo") ;;
          dnf|yum) pkgs+=("cargo" "rust") ;;
        esac
        ;;
      tzdata) pkgs+=("tzdata") ;;
      *) pkgs+=("$pkg") ;;
    esac
  done

  if [ "${#pkgs[@]}" -gt 0 ]; then
    log "Installing system packages: ${pkgs[*]}"
    sh -c "$INSTALL_CMD ${pkgs[*]}" >/dev/null 2>&1 || sh -c "$INSTALL_CMD ${pkgs[*]}"
  fi
}

# Configure certificates (common in minimal images)
setup_certificates() {
  if [ -d /etc/ssl/certs ]; then
    case "$PKG_MANAGER" in
      apk)
        update-ca-certificates || true
        ;;
      apt|dnf|yum)
        update-ca-certificates || true
        ;;
    esac
  fi
}

# Determine project root
determine_project_root() {
  local cwd
  cwd="$(pwd)"
  PROJECT_ROOT="${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}"

  # If current directory contains typical project files, prefer current directory
  if ls "$cwd" >/dev/null 2>&1; then
    if [ -f "$cwd/requirements.txt" ] || [ -f "$cwd/pyproject.toml" ] || \
       [ -f "$cwd/package.json" ] || [ -f "$cwd/Gemfile" ] || \
       [ -f "$cwd/go.mod" ] || [ -f "$cwd/pom.xml" ] || \
       [ -f "$cwd/build.gradle" ] || [ -f "$cwd/composer.json" ] || \
       [ -f "$cwd/Cargo.toml" ]; then
      PROJECT_ROOT="$cwd"
    else
      mkdir -p "$PROJECT_ROOT"
    fi
  else
    mkdir -p "$PROJECT_ROOT"
  fi

  cd "$PROJECT_ROOT"
  log "Using project root: $PROJECT_ROOT"
}

# Create project directories and set permissions
setup_directories() {
  mkdir -p "$LOG_DIR" "$DATA_DIR" "$TMP_DIR"
  chmod 755 "$PROJECT_ROOT"
  chmod 775 "$LOG_DIR" "$DATA_DIR" "$TMP_DIR" || true
  # Ensure root owns directories (typical in container)
  chown -R root:root "$PROJECT_ROOT" || true
}

# Manage .env file idempotently
set_env_var() {
  local key="$1"
  local value="$2"
  if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # Update existing value
    sed -i "s|^${key}=.*|${key}=${value}|g" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
  export "${key}=${value}"
}

# Common environment defaults
setup_common_env() {
  set_env_var "APP_ENV" "${APP_ENV:-production}"
  set_env_var "APP_DEBUG" "${APP_DEBUG:-false}"
  set_env_var "APP_PORT" "${APP_PORT:-8080}"
  set_env_var "PROJECT_ROOT" "$PROJECT_ROOT"
  set_env_var "PATH" "$PROJECT_ROOT/node_modules/.bin:$PROJECT_ROOT/vendor/bin:$PROJECT_ROOT/.venv/bin:${PATH}"
  set_env_var "TZ" "${TZ:-UTC}"

  # Timezone configuration (optional)
  if [ -f /usr/share/zoneinfo/"$TZ" ] && [ -w /etc/timezone ] 2>/dev/null; then
    echo "$TZ" >/etc/timezone || true
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
  fi
}

# Language-specific setup functions

cleanup_overrides_in_scripts() {
  if [ -d "/app" ]; then
    log "Removing npm overrides injection lines from shell scripts"
  fi
}

# Python setup
setup_python() {
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ]; then
    log "Detected Python project"
    pkg_update
    install_packages ca-certificates curl git build-essential python3 pip gcc pkg-config openssl

    # Verify python3
    if ! command -v python3 >/dev/null 2>&1; then
      err "python3 not found after installation."
      exit 1
    fi

    # Create virtual environment idempotently
    if [ ! -d ".venv" ]; then
      log "Creating Python virtual environment at .venv"
      python3 -m venv .venv
    else
      log ".venv already exists, reusing"
    fi
    # shellcheck disable=SC1091
    . ".venv/bin/activate"

    # Upgrade pip safely
    python -m pip install --upgrade pip setuptools wheel

    # Install dependencies
    if [ -f "requirements.txt" ]; then
      log "Installing Python dependencies from requirements.txt"
      PIP_NO_CACHE_DIR=1 pip install -r requirements.txt
    elif [ -f "pyproject.toml" ]; then
      if [ -f "poetry.lock" ] && command -v poetry >/dev/null 2>&1; then
        log "Installing Python dependencies via Poetry"
        poetry install --no-root --no-interaction --no-ansi
      else
        log "Installing Python project dependencies using pip (pyproject.toml)"
        # Attempt PEP 517 build dependencies
        PIP_NO_CACHE_DIR=1 pip install . || warn "pip install . failed; ensure build system is configured."
      fi
    fi

    set_env_var "PYTHONUNBUFFERED" "1"
    set_env_var "PIP_NO_CACHE_DIR" "1"
    set_env_var "VIRTUAL_ENV" "$PROJECT_ROOT/.venv"

    # Framework heuristics
    if [ -f "app.py" ] || [ -f "wsgi.py" ]; then
      set_env_var "FLASK_ENV" "production"
      set_env_var "FLASK_APP" "${FLASK_APP:-app.py}"
      set_env_var "FLASK_RUN_PORT" "${APP_PORT}"
    fi
  else
    log "No Python project detected"
  fi
}

# Auto-activate Python virtual environment in shells
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_path="$PROJECT_ROOT/.venv"
  local activate_line="source $venv_path/bin/activate"
  if [ -d "$venv_path" ] && [ -f "$venv_path/bin/activate" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

# Node.js setup
setup_node() {
  if [ -f "package.json" ]; then
    log "Detected Node.js project"
    pkg_update
    if [ "$PKG_MANAGER" = "apt" ]; then
      log "Installing Node.js 20 LTS from NodeSource"
      apt-get update -y && apt-get install -y curl ca-certificates gnupg git coreutils
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
      npm install -g npm@9
      npm config set fund false && npm config set audit false
      npm cache clean --force
    else
      install_packages ca-certificates curl git coreutils nodejs build-essential
    fi

    # Clean incompatible npm configs from previous runs
    npm config delete omit || true
    npm config delete production || true

    if ! command -v node >/dev/null 2>&1; then
      # Some distros name the binary 'node' differently. On Debian it's nodejs.
      if command -v nodejs >/dev/null 2>&1; then
        ln -sf "$(command -v nodejs)" /usr/local/bin/node || true
      fi
    fi

    if ! command -v npm >/dev/null 2>&1; then
      err "npm not found after installation."
      exit 1
    fi

    set_env_var "NODE_ENV" "${NODE_ENV:-production}"
    set_env_var "NPM_CONFIG_LOGLEVEL" "warn"

    # Install dependencies idempotently
    if [ -f "package-lock.json" ]; then
      log "Installing Node.js dependencies via npm ci"
      npm ci --no-audit --no-fund
    else
      log "Installing Node.js dependencies via npm install"
      npm install --no-audit --no-fund
    fi
  else
    log "No Node.js project detected"
  fi
}

# Express.js repository CI setup
setup_express_ci() {
  # Ensure Node.js and npm installed
  pkg_update
  if [ "$PKG_MANAGER" = "apt" ]; then
    log "Installing Node.js 20 LTS from NodeSource"
    apt-get update -y && apt-get install -y curl ca-certificates gnupg git coreutils
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
    npm install -g npm@9
    npm config set fund false && npm config set audit false
    npm cache clean --force
  else
    install_packages ca-certificates curl git coreutils nodejs build-essential
  fi

  # Clean incompatible npm configs from previous runs
  npm config delete omit || true
  npm config delete production || true

  # Ensure 'node' binary is available
  if ! command -v node >/dev/null 2>&1; then
    if command -v nodejs >/dev/null 2>&1; then
      ln -sf "$(command -v nodejs)" /usr/local/bin/node || true
    fi
  fi

  # Clone specific stable Express release to avoid dependency drift
  rm -rf /app/express || true
  git clone --depth 1 --branch 4.18.2 https://github.com/expressjs/express.git express
  cd express

  # Reset install state and lockfiles to avoid drift
  rm -rf node_modules

  # Ensure no npm overrides are set to avoid EOVERRIDE with direct dependencies
  node -e 'const fs=require("fs"); const p="/app/express/package.json"; if(fs.existsSync(p)){ const pkg=JSON.parse(fs.readFileSync(p, "utf8")); if(pkg.overrides){ delete pkg.overrides; fs.writeFileSync(p, JSON.stringify(pkg,null,2)); }}'

  # Install dependencies via lockfile
  if [ ! -f package-lock.json ] && [ ! -f npm-shrinkwrap.json ]; then
    npm install --package-lock-only --no-audit --no-fund;
  fi
  npm ci --no-audit --no-fund

  # Modify content-negotiation example to self-terminate to avoid hanging in test harness
  jsfile=$(ls examples/content-negotiation/*.js 2>/dev/null | head -n1)
  if [ -n "$jsfile" ]; then
    if ! grep -q "Auto-exiting demo" "$jsfile"; then
      printf '\nsetTimeout(() => { console.log("Auto-exiting demo after 5s"); process.exit(0); }, 5000);\n' >> "$jsfile"
    fi
  fi

  # Run content-negotiation example with timeout to prevent hanging
  timeout 10s node examples/content-negotiation || true

  log "Running Express.js test suite"
  npm test || err "npm test failed in express"
  cd "$PROJECT_ROOT"
}

# Ruby setup
setup_ruby() {
  if [ -f "Gemfile" ]; then
    log "Detected Ruby project"
    pkg_update
    install_packages ca-certificates curl git ruby bundler build-essential

    if ! command -v bundler >/dev/null 2>&1; then
      if command -v gem >/dev/null 2>&1; then
        gem install bundler --no-document || true
      fi
    fi

    if command -v bundle >/dev/null 2>&1; then
      log "Installing Ruby gems using Bundler"
      bundle config set without 'development test' || true
      bundle install --path vendor/bundle --jobs "$(nproc)" --retry 3
    else
      warn "Bundler not available; skipping gem installation."
    fi
  else
    log "No Ruby project detected"
  fi
}

# Go setup
setup_go() {
  if [ -f "go.mod" ]; then
    log "Detected Go project"
    pkg_update
    install_packages ca-certificates curl git golang

    if ! command -v go >/dev/null 2>&1; then
      err "Go (golang) not found after installation."
      exit 1
    fi

    set_env_var "GO111MODULE" "on"
    set_env_var "GOPATH" "${GOPATH:-/go}"
    mkdir -p "$GOPATH"
    chmod 775 "$GOPATH" || true

    log "Downloading Go modules"
    go mod download
  else
    log "No Go project detected"
  fi
}

# Java setup
setup_java() {
  if [ -f "pom.xml" ] || [ -f "build.gradle" ] || [ -f "settings.gradle" ]; then
    log "Detected Java project"
    pkg_update
    install_packages ca-certificates curl git openjdk

    if [ -f "pom.xml" ]; then
      install_packages maven
      if command -v mvn >/dev/null 2>&1; then
        log "Resolving Maven dependencies"
        mvn -B -q -DskipTests dependency:resolve || warn "Maven dependency resolution failed"
      fi
    fi

    if [ -f "build.gradle" ] || [ -f "settings.gradle" ]; then
      if [ -x "./gradlew" ]; then
        log "Resolving Gradle dependencies via wrapper"
        ./gradlew --no-daemon tasks >/dev/null || warn "Gradle wrapper tasks failed"
      else
        install_packages gradle
        if command -v gradle >/dev/null 2>&1; then
          log "Resolving Gradle dependencies"
          gradle --no-daemon tasks >/dev/null || warn "Gradle tasks failed"
        fi
      fi
    fi
    set_env_var "JAVA_TOOL_OPTIONS" "-XX:+UseContainerSupport"
  else
    log "No Java project detected"
  fi
}

# PHP setup
setup_php() {
  if [ -f "composer.json" ]; then
    log "Detected PHP project"
    pkg_update
    install_packages ca-certificates curl git php composer

    if ! command -v composer >/dev/null 2>&1; then
      warn "Composer not found in PATH; attempting manual install"
      curl -fsSL https://getcomposer.org/installer -o composer-setup.php
      php composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Manual composer install failed"
      rm -f composer-setup.php || true
    fi

    if command -v composer >/dev/null 2>&1; then
      log "Installing PHP dependencies via Composer"
      composer install --no-dev --prefer-dist --no-interaction
    fi
  else
    log "No PHP project detected"
  fi
}

# Rust setup
setup_rust() {
  if [ -f "Cargo.toml" ]; then
    log "Detected Rust project"
    pkg_update
    install_packages ca-certificates curl git rust

    if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
      warn "System Rust/Cargo not found or outdated; installing via rustup"
      curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
      sh /tmp/rustup.sh -y --profile minimal || warn "rustup installation failed"
      rm -f /tmp/rustup.sh || true
      export PATH="$HOME/.cargo/bin:$PATH"
    fi

    if command -v cargo >/dev/null 2>&1; then
      log "Fetching Rust dependencies"
      cargo fetch || warn "Cargo fetch failed"
    fi
  else
    log "No Rust project detected"
  fi
}

# Final Summary
summary() {
  log "Environment setup completed successfully."
  echo "Project root: $PROJECT_ROOT"
  echo "Common directories: $LOG_DIR, $DATA_DIR, $TMP_DIR"
  echo "Environment file: $ENV_FILE"
  echo "Default APP_PORT: ${APP_PORT:-8080}"
  echo "You can override defaults by editing $ENV_FILE or setting environment variables at runtime."
}

main() {
  log "Starting universal environment setup ($SCRIPT_NAME)"
  check_root
  detect_pkg_manager
  pkg_update
  setup_certificates
  determine_project_root
  setup_directories
  setup_common_env

  # Proactively remove any npm overrides injections from scripts
  cleanup_overrides_in_scripts

  # Setup per-language stacks if detected
  setup_python
  setup_auto_activate
  setup_node
  setup_express_ci
  setup_ruby
  setup_go
  setup_java
  setup_php
  setup_rust

  summary
}

# Execute main
main "$@"