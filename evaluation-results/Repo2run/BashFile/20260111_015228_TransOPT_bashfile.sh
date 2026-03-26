#!/usr/bin/env bash
# Universal project environment setup script for containerized (Docker) environments.
# Detects common project types (Python, Node.js, Go, Java, PHP, Ruby, Rust) and installs
# required runtimes, system dependencies, sets up directories, and configures environment.
#
# Usage: ./setup.sh
# This script is idempotent and safe to run multiple times.

set -Eeuo pipefail

# --------------- Configuration Defaults ---------------

DEFAULT_APP_NAME="${APP_NAME:-app}"
DEFAULT_APP_ENV="${APP_ENV:-production}"
DEFAULT_PORT="${PORT:-8080}"
DEFAULT_LOCALE="${LANG:-C.UTF-8}"

# Working directory (project root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"

# Persistent marker directory for idempotency
STATE_DIR="/var/lib/project-setup"
mkdir -p "$STATE_DIR" || true

# Colors for output (safe for non-TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

# --------------- Logging & Error Handling ---------------

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }

cleanup() { :; }
trap cleanup EXIT

on_error() {
  err "Setup failed at line $1. See logs above for details."
}
trap 'on_error $LINENO' ERR

# --------------- Privilege Checks ---------------

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "This script must run as root inside the container (no sudo). Current UID: $(id -u)"
    exit 1
  fi
}
require_root

# --------------- Package Manager Detection ---------------

PKG_MGR=""
PKG_UPDATE_MARK="$STATE_DIR/pkg_updated"
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    err "Unsupported base image: no apt, apk, dnf, or yum found."
    exit 1
  fi
}

pkg_update() {
  if [ ! -f "$PKG_UPDATE_MARK" ]; then
    case "$PKG_MGR" in
      apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        touch "$PKG_UPDATE_MARK"
        ;;
      apk)
        apk update
        touch "$PKG_UPDATE_MARK"
        ;;
      dnf)
        dnf -y makecache
        touch "$PKG_UPDATE_MARK"
        ;;
      yum)
        yum -y makecache
        touch "$PKG_UPDATE_MARK"
        ;;
    esac
  fi
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
  esac
}

# --------------- System Dependencies ---------------

install_common_build_tools() {
  log "Installing common build tools and utilities..."
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git build-essential pkg-config \
                 openssh-client gnupg lsb-release
      ;;
    apk)
      pkg_install ca-certificates curl git build-base pkgconfig \
                 openssh-client bash coreutils
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gcc gcc-c++ make pkgconfig \
                 openssh-clients
      ;;
  esac
  # Language runtime build libs (used by many modules)
  case "$PKG_MGR" in
    apt)
      pkg_install libssl-dev libffi-dev zlib1g-dev libjpeg-dev libpng-dev \
                  libpq-dev libsqlite3-dev libreadline-dev
      ;;
    apk)
      pkg_install openssl-dev libffi-dev zlib-dev jpeg-dev libpng-dev \
                  postgresql-dev sqlite-dev readline-dev
      ;;
    dnf|yum)
      pkg_install openssl-devel libffi-devel zlib-devel libjpeg-turbo-devel libpng-devel \
                  postgresql-devel sqlite-devel readline-devel
      ;;
  esac
}

# --------------- Directory Structure ---------------

setup_directories() {
  log "Setting up project directories in $WORKDIR"
  mkdir -p "$WORKDIR"/{logs,tmp,dist,bin,.cache}
  chmod 775 "$WORKDIR"/{logs,tmp,.cache} || true
  chmod 755 "$WORKDIR"/{dist,bin} || true

  # If running as root, keep ownership root; if non-root (rare), ensure access
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    chown -R root:root "$WORKDIR" || true
  fi
}

# --------------- Environment Variables ---------------

write_env_file() {
  local env_file="$WORKDIR/.env"
  log "Writing environment configuration to $env_file"
  cat > "$env_file" <<EOF
APP_NAME=${DEFAULT_APP_NAME}
APP_ENV=${DEFAULT_APP_ENV}
PORT=${DEFAULT_PORT}
LANG=${DEFAULT_LOCALE}
LC_ALL=${DEFAULT_LOCALE}
# Python
PIP_DISABLE_PIP_VERSION_CHECK=1
PIP_NO_CACHE_DIR=1
PYTHONDONTWRITEBYTECODE=1
# Node.js
NPM_CONFIG_FUND=false
NPM_CONFIG_AUDIT=false
# Java
JAVA_TOOL_OPTIONS=-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0
# Go
GOMODCACHE=${WORKDIR}/.cache/go
GOPATH=${WORKDIR}/.cache/gopath
# Rust
CARGO_HOME=${WORKDIR}/.cache/cargo
RUSTUP_HOME=${WORKDIR}/.cache/rustup
EOF
  chmod 640 "$env_file" || true
}

# --------------- Runtime Setup: Python ---------------

setup_python() {
  if [ -f "$WORKDIR/requirements.txt" ] || [ -f "$WORKDIR/pyproject.toml" ] || [ -f "$WORKDIR/Pipfile" ]; then
    log "Detected Python project files"
    case "$PKG_MGR" in
      apt)
        pkg_install python3 python3-venv python3-pip python3-dev
        ;;
      apk)
        pkg_install python3 py3-pip python3-dev musl-dev
        ;;
      dnf|yum)
        pkg_install python3 python3-pip python3-devel
        ;;
    esac

    # Create virtual environment
    if [ ! -d "$WORKDIR/.venv" ]; then
      log "Creating Python virtual environment at $WORKDIR/.venv"
      python3 -m venv "$WORKDIR/.venv"
    else
      log "Python virtual environment already exists"
    fi

    # Activate venv for installation
    # shellcheck disable=SC1090
    source "$WORKDIR/.venv/bin/activate"

    python -m pip install --upgrade pip wheel setuptools

    if [ -f "$WORKDIR/requirements.txt" ]; then
      log "Installing Python dependencies from requirements.txt"
      pip install --no-compile --no-cache-dir -r "$WORKDIR/requirements.txt"
    elif [ -f "$WORKDIR/pyproject.toml" ]; then
      if [ -f "$WORKDIR/poetry.lock" ] || grep -qi '\[tool.poetry\]' "$WORKDIR/pyproject.toml" 2>/dev/null; then
        log "Poetry project detected; installing Poetry"
        pip install --no-cache-dir "poetry>=1.6"
        POETRY_HOME="$WORKDIR/.cache/poetry"
        mkdir -p "$POETRY_HOME"
        export POETRY_HOME
        "$WORKDIR/.venv/bin/poetry" config virtualenvs.create false
        "$WORKDIR/.venv/bin/poetry" install --no-interaction --no-ansi --no-root
      else
        log "Installing Python project via pip (pyproject.toml)"
        pip install --no-cache-dir -e "$WORKDIR"
      fi
    elif [ -f "$WORKDIR/Pipfile" ]; then
      log "Pipenv project detected; installing Pipenv"
      pip install --no-cache-dir pipenv
      PIPENV_VENV_IN_PROJECT=1 PIPENV_IGNORE_VIRTUALENVS=1 pipenv install --deploy
    fi

    deactivate || true
  else
    log "No Python dependency files found; skipping Python setup"
  fi
}

# --------------- Runtime Setup: Node.js ---------------

setup_node() {
  if [ -f "$WORKDIR/package.json" ]; then
    log "Detected Node.js project"
    # Install Node.js via nvm for consistent LTS versions
    NVM_DIR="/usr/local/nvm"
    NODE_MARK="$STATE_DIR/node_installed"
    if ! command -v node >/dev/null 2>&1; then
      log "Installing Node.js via NVM"
      mkdir -p "$NVM_DIR"
      if [ ! -d "$NVM_DIR/.git" ] && [ ! -f "$NVM_DIR/nvm.sh" ]; then
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
      fi
      # shellcheck disable=SC1090
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      nvm install --lts
      nvm alias default 'lts/*'
      # Persist NVM in profile.d for future shells
      cat > /etc/profile.d/nvm.sh <<'EOF'
export NVM_DIR="/usr/local/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
EOF
      touch "$NODE_MARK"
    else
      log "Node.js already installed: $(node -v)"
      # Ensure NVM is sourced if present
      if [ -d "$NVM_DIR" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1090
        . "$NVM_DIR/nvm.sh"
      fi
    fi

    # Enable Corepack for Yarn/Pnpm if available
    if command -v corepack >/dev/null 2>&1; then
      corepack enable || true
      corepack prepare yarn@stable --activate || true
      corepack prepare pnpm@latest --activate || true
    fi

    mkdir -p "$WORKDIR/.cache/npm"
    export NPM_CONFIG_CACHE="$WORKDIR/.cache/npm"
    export npm_config_cache="$WORKDIR/.cache/npm"

    if [ -f "$WORKDIR/yarn.lock" ] && command -v yarn >/dev/null 2>&1; then
      log "Installing Node.js dependencies with Yarn"
      yarn install --frozen-lockfile --non-interactive
    elif [ -f "$WORKDIR/pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
      log "Installing Node.js dependencies with pnpm"
      pnpm install --frozen-lockfile
    elif [ -f "$WORKDIR/package-lock.json" ]; then
      log "Installing Node.js dependencies with npm ci"
      npm ci --no-audit --no-fund
    else
      log "Installing Node.js dependencies with npm install"
      npm install --no-audit --no-fund
    fi
  else
    log "No package.json found; skipping Node.js setup"
  fi
}

# --------------- Runtime Setup: Java ---------------

setup_java() {
  if [ -f "$WORKDIR/pom.xml" ] || [ -f "$WORKDIR/build.gradle" ] || [ -f "$WORKDIR/build.gradle.kts" ]; then
    log "Detected Java project"
    case "$PKG_MGR" in
      apt)
        pkg_install openjdk-17-jdk
        ;;
      apk)
        pkg_install openjdk17
        ;;
      dnf|yum)
        pkg_install java-17-openjdk
        ;;
    esac

    if [ -f "$WORKDIR/pom.xml" ]; then
      log "Installing Maven and resolving dependencies"
      case "$PKG_MGR" in
        apt) pkg_install maven ;;
        apk) pkg_install maven ;;
        dnf|yum) pkg_install maven ;;
      esac
      (cd "$WORKDIR" && mvn -B -DskipTests dependency:go-offline || true)
    fi

    if [ -f "$WORKDIR/build.gradle" ] || [ -f "$WORKDIR/build.gradle.kts" ]; then
      log "Installing Gradle and resolving dependencies"
      case "$PKG_MGR" in
        apt) pkg_install gradle ;;
        apk) pkg_install gradle ;;
        dnf|yum) pkg_install gradle ;;
      esac
      (cd "$WORKDIR" && gradle --no-daemon build -x test || true)
    fi
  else
    log "No Java build files found; skipping Java setup"
  fi
}

# --------------- Runtime Setup: Go ---------------

setup_go() {
  if [ -f "$WORKDIR/go.mod" ]; then
    log "Detected Go project"
    case "$PKG_MGR" in
      apt)
        if ! pkg_install golang; then
          pkg_install golang-go
        fi
        ;;
      apk)
        pkg_install go
        ;;
      dnf|yum)
        pkg_install golang
        ;;
    esac
    export GOPATH="$WORKDIR/.cache/gopath"
    export GOMODCACHE="$WORKDIR/.cache/go"
    mkdir -p "$GOPATH" "$GOMODCACHE"
    (cd "$WORKDIR" && go mod download)
  else
    log "No go.mod found; skipping Go setup"
  fi
}

# --------------- Runtime Setup: PHP ---------------

setup_php() {
  if [ -f "$WORKDIR/composer.json" ]; then
    log "Detected PHP project"
    case "$PKG_MGR" in
      apt)
        pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip
        ;;
      apk)
        pkg_install php php-cli php-mbstring php-xml php-curl php-zip unzip
        ;;
      dnf|yum)
        pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip
        ;;
    esac

    if command -v composer >/dev/null 2>&1; then
      log "Composer already installed"
    else
      log "Installing Composer"
      EXPECTED_CHECKSUM="$(curl -fsSL https://composer.github.io/installer.sig)"
      php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
      ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
      if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        rm -f composer-setup.php
        err "Invalid Composer installer checksum"
        exit 1
      fi
      php composer-setup.php --install-dir=/usr/local/bin --filename=composer
      rm -f composer-setup.php
    fi
    (cd "$WORKDIR" && composer install --no-interaction --prefer-dist --no-dev)
  else
    log "No composer.json found; skipping PHP setup"
  fi
}

# --------------- Runtime Setup: Ruby ---------------

setup_ruby() {
  if [ -f "$WORKDIR/Gemfile" ]; then
    log "Detected Ruby project"
    case "$PKG_MGR" in
      apt)
        pkg_install ruby-full ruby-dev
        ;;
      apk)
        pkg_install ruby ruby-dev build-base
        ;;
      dnf|yum)
        pkg_install ruby ruby-devel
        ;;
    esac
    if ! command -v bundle >/dev/null 2>&1; then
      gem install bundler --no-document
    fi
    (cd "$WORKDIR" && bundle install --path vendor/bundle --without development test)
  else
    log "No Gemfile found; skipping Ruby setup"
  fi
}

# --------------- Runtime Setup: Rust ---------------

setup_rust() {
  if [ -f "$WORKDIR/Cargo.toml" ]; then
    log "Detected Rust project"
    if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
      log "Rust toolchain already present: $(rustc --version)"
    else
      log "Installing Rust via rustup"
      mkdir -p "$WORKDIR/.cache/rustup" "$WORKDIR/.cache/cargo"
      export RUSTUP_HOME="$WORKDIR/.cache/rustup"
      export CARGO_HOME="$WORKDIR/.cache/cargo"
      curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
      sh /tmp/rustup.sh -y --profile minimal --default-toolchain stable
      rm -f /tmp/rustup.sh
      # Persist cargo env
      cat > /etc/profile.d/rust.sh <<'EOF'
export RUSTUP_HOME="/app/.cache/rustup"
export CARGO_HOME="/app/.cache/cargo"
[ -f "$CARGO_HOME/env" ] && . "$CARGO_HOME/env"
EOF
      # shellcheck disable=SC1091
      [ -f "$WORKDIR/.cache/cargo/env" ] && . "$WORKDIR/.cache/cargo/env"
    fi
    (cd "$WORKDIR" && cargo fetch || true)
  else
    log "No Cargo.toml found; skipping Rust setup"
  fi
}

# --------------- Locale and SSL CA Setup ---------------

setup_locale_and_ca() {
  log "Configuring locale and SSL certificates"
  case "$PKG_MGR" in
    apt)
      pkg_install locales
      sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
      locale-gen || true
      update-ca-certificates || true
      ;;
    apk)
      update-ca-certificates || true
      ;;
    dnf|yum)
      update-ca-trust || true
      ;;
  esac
}

# --------------- Main ---------------

main() {
  log "Starting environment setup for project at $WORKDIR"

  detect_pkg_mgr
  pkg_update
  install_common_build_tools
  setup_directories
  setup_locale_and_ca

  # Write env file
  write_env_file

  # Language-specific setups (conditionally)
  setup_python
  setup_node
  setup_java
  setup_go
  setup_php
  setup_ruby
  setup_rust

  # Final summary
  log "Environment setup completed successfully."
  echo
  echo "Project root: $WORKDIR"
  echo "Default environment:"
  echo "  APP_NAME=${DEFAULT_APP_NAME}"
  echo "  APP_ENV=${DEFAULT_APP_ENV}"
  echo "  PORT=${DEFAULT_PORT}"
  echo
  echo "Notes:"
  echo "- To use Python virtualenv: source \"$WORKDIR/.venv/bin/activate\""
  echo "- Node.js installed via NVM; it will be available in new shells via /etc/profile.d/nvm.sh"
  echo "- Environment variables written to $WORKDIR/.env (source it in your process if needed)"
  echo "- This script is safe to re-run; it will skip already installed components."
}

main "$@"