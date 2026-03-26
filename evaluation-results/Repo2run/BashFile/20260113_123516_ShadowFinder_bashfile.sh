#!/usr/bin/env bash
#
# Universal project environment setup script for Docker containers
# - Detects common stacks (Python, Node.js, Ruby, PHP, Java, Go, Rust, .NET)
# - Installs required system/runtime dependencies
# - Sets up project directories, permissions, and environment variables
# - Idempotent and safe to run multiple times
#
# Usage:
#   Place this script at the root of your project (or run from within the project directory)
#   Run: bash setup_env.sh
#
# Configurable environment variables (optional):
#   PROJECT_ROOT=/app
#   APP_USER=app
#   APP_UID=1000
#   APP_GID=1000
#   APP_ENV=production
#   APP_PORT=8080
#   SKIP_CHOWN=1
#   PYTHON_VERSION_MIN=3.8
#
# Notes:
# - Script assumes it runs as root inside a container (no sudo).
# - Supports Debian/Ubuntu (apt), Alpine (apk), RHEL/CentOS/Fedora (yum/dnf).
# - Only installs stack-specific packages if corresponding project files are detected.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ----------------------------
# Logging and error handling
# ----------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
BLUE="$(printf '\033[0;34m')"
NC="$(printf '\033[0m')"

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN $(date +'%H:%M:%S')] $*${NC}"; }
info()   { echo -e "${BLUE}[$(date +'%H:%M:%S')] $*${NC}"; }
error()  { echo -e "${RED}[ERROR $(date +'%H:%M:%S')] $*${NC}" >&2; }

trap 'error "An error occurred on line $LINENO. Exiting."; exit 1' ERR

# ----------------------------
# Defaults and environment
# ----------------------------
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
if [ ! -d "$PROJECT_ROOT" ]; then
  # If running in a fresh container, default to /app
  PROJECT_ROOT="/app"
fi

APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-}"
PYTHON_VERSION_MIN="${PYTHON_VERSION_MIN:-3.8}"
SKIP_CHOWN="${SKIP_CHOWN:-0}"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

# ----------------------------
# Utility functions
# ----------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_file() { [ -f "${PROJECT_ROOT}/$1" ]; }
has_any_file() { for f in "$@"; do [ -f "${PROJECT_ROOT}/$f" ] && return 0; done; return 1; }
contains() { grep -qE "$2" "$1" 2>/dev/null; }

semver_ge() {
  # Compare semantic versions: returns 0 if $1 >= $2
  # usage: semver_ge "3.10" "3.8"
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# ----------------------------
# OS / Package manager detection
# ----------------------------
OS_FAMILY="unknown"
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
PKG_QUERY=""
BUILD_ESSENTIAL_PKGS=""
PYTHON_PKGS=""
NODE_PKGS=""
RUBY_PKGS=""
PHP_PKGS=""
JAVA_PKGS=""
MAVEN_PKG=""
GRADLE_PKG=""
GO_PKG=""
RUST_PKGS=""

detect_os() {
  if [ -f /etc/alpine-release ]; then
    OS_FAMILY="alpine"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
    PKG_QUERY="apk info -e"
    BUILD_ESSENTIAL_PKGS="build-base bash ca-certificates curl git openssl pkgconf coreutils"
    PYTHON_PKGS="python3 py3-pip python3-dev py3-virtualenv"
    NODE_PKGS="nodejs npm"
    RUBY_PKGS="ruby ruby-bundler build-base"
    PHP_PKGS="php81-cli php81-phar php81-openssl php81-xml php81-mbstring php81-json php81-tokenizer php81-zip unzip"
    JAVA_PKGS="openjdk17-jdk"
    MAVEN_PKG="maven"
    GRADLE_PKG="gradle"
    GO_PKG="go"
    RUST_PKGS="bash curl"
  elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ] || [ -f /etc/apt/sources.list ]; then
    OS_FAMILY="debian"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
    PKG_QUERY="dpkg -s"
    BUILD_ESSENTIAL_PKGS="bash ca-certificates curl wget git unzip xz-utils build-essential pkg-config"
    PYTHON_PKGS="python3 python3-pip python3-venv python3-dev"
    NODE_PKGS="nodejs npm"
    RUBY_PKGS="ruby-full bundler make gcc g++"
    PHP_PKGS="php-cli php-xml php-mbstring php-zip unzip"
    JAVA_PKGS="openjdk-17-jdk"
    MAVEN_PKG="maven"
    GRADLE_PKG="gradle"
    GO_PKG="golang"
    RUST_PKGS="curl"
  elif has_cmd dnf || has_cmd yum; then
    OS_FAMILY="rhel"
    if has_cmd dnf; then
      PKG_UPDATE="dnf -y update || true"
      PKG_INSTALL="dnf -y install"
      PKG_CLEAN="dnf clean all"
    else
      PKG_UPDATE="yum -y update || true"
      PKG_INSTALL="yum -y install"
      PKG_CLEAN="yum clean all"
    fi
    PKG_QUERY="rpm -q"
    BUILD_ESSENTIAL_PKGS="bash ca-certificates curl wget git unzip xz gcc gcc-c++ make autoconf automake libtool pkgconfig"
    PYTHON_PKGS="python3 python3-pip python3-devel"
    NODE_PKGS="nodejs npm"
    RUBY_PKGS="ruby ruby-devel rubygems make gcc gcc-c++"
    PHP_PKGS="php-cli php-xml php-mbstring zip unzip"
    JAVA_PKGS="java-17-openjdk-devel"
    MAVEN_PKG="maven"
    GRADLE_PKG="gradle"
    GO_PKG="golang"
    RUST_PKGS="curl"
  else
    warn "Unsupported or unrecognized base image. Attempting generic setup with minimal assumptions."
    OS_FAMILY="unknown"
  fi
}

pkg_update() {
  [ -n "$PKG_UPDATE" ] || return 0
  eval "$PKG_UPDATE" >/dev/null
}

pkg_install() {
  # Install packages only if not already present (best-effort)
  if [ $# -eq 0 ]; then return 0; fi
  local to_install=()
  case "$OS_FAMILY" in
    debian)
      for p in "$@"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then to_install+=("$p"); fi
      done
      ;;
    alpine)
      for p in "$@"; do
        if ! apk info -e "$p" >/dev/null 2>&1; then to_install+=("$p"); fi
      done
      ;;
    rhel)
      for p in "$@"; do
        if ! rpm -q "$p" >/dev/null 2>&1; then to_install+=("$p"); fi
      done
      ;;
    *)
      warn "Package manager not detected; skipping install for: $*"
      return 0
      ;;
  esac
  if [ "${#to_install[@]}" -gt 0 ]; then
    log "Installing packages: ${to_install[*]}"
    eval "$PKG_INSTALL ${to_install[*]}"
  else
    info "All requested packages already installed."
  fi
}

pkg_clean() {
  [ -n "$PKG_CLEAN" ] || return 0
  eval "$PKG_CLEAN" >/dev/null || true
}

# ----------------------------
# User and directory setup
# ----------------------------
ensure_user() {
  # Patched to handle pre-existing UID/GID safely
  if id -u "$APP_USER" >/dev/null 2>&1; then
    info "User '$APP_USER' already exists."
    return 0
  fi
  if getent passwd "$APP_UID" >/dev/null; then
    existing_user="$(getent passwd "$APP_UID" | cut -d: -f1)"
    warn "UID $APP_UID is already in use by '$existing_user'. Using that user instead."
    export APP_USER="$existing_user"
    return 0
  fi
  if getent group "$APP_GID" >/dev/null; then
    existing_group="$(getent group "$APP_GID" | cut -d: -f1)"
    warn "GID $APP_GID already exists (group: $existing_group). Using it."
    group_name="$existing_group"
  else
    group_name="$APP_USER"
    groupadd -g "$APP_GID" "$group_name" || true
  fi
  useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" 2>/dev/null || useradd -m -u "$APP_UID" -s /bin/sh "$APP_USER"
  log "Created user '$APP_USER' (uid:$APP_UID gid:$APP_GID)"
}

ensure_project_dir() {
  mkdir -p "$PROJECT_ROOT"
  # Make standard subdirs
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,cache}
  if [ "${SKIP_CHOWN}" != "1" ]; then
    chown -R "$APP_USER":"$APP_GID" "$PROJECT_ROOT" || chown -R "$APP_USER":"$APP_USER" "$PROJECT_ROOT" || true
  else
    warn "Skipping chown of $PROJECT_ROOT due to SKIP_CHOWN=1"
  fi
}

# ----------------------------
# Environment file and PATH
# ----------------------------
setup_env_file() {
  local env_file="$PROJECT_ROOT/.env"
  local default_port="${APP_PORT}"

  # Guess a reasonable default port if not provided
  if [ -z "$default_port" ]; then
    if has_any_file "package.json"; then
      default_port="3000"
    elif has_any_file "manage.py" "app.py" "wsgi.py" "requirements.txt" "pyproject.toml"; then
      default_port="8000"
    elif has_any_file "Gemfile"; then
      default_port="3000"
    elif has_any_file "composer.json"; then
      default_port="8000"
    elif has_any_file "pom.xml" "build.gradle" "build.gradle.kts"; then
      default_port="8080"
    elif has_any_file "go.mod"; then
      default_port="8080"
    elif has_any_file "Cargo.toml"; then
      default_port="8080"
    elif ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then
      default_port="8080"
    else
      default_port="8080"
    fi
  fi

  if [ ! -f "$env_file" ]; then
    cat > "$env_file" <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${default_port}
PROJECT_ROOT=${PROJECT_ROOT}
PATH=\$PATH:${PROJECT_ROOT}/.venv/bin:\$HOME/.local/bin:\$HOME/.cargo/bin:/usr/local/bin:/usr/share/dotnet
EOF
    log "Created environment file at $env_file"
  else
    info ".env file already exists at $env_file"
  fi
}

ensure_shell_profiles() {
  # Ensure PATH entries persist for the app user
  local profile_dir="/home/${APP_USER}"
  [ -d "$profile_dir" ] || profile_dir="/root"
  for f in ".bashrc" ".profile"; do
    local pf="${profile_dir}/${f}"
    touch "$pf"
    if ! grep -q "PROJECT_ROOT" "$pf" 2>/dev/null; then
      {
        echo "export PROJECT_ROOT=${PROJECT_ROOT}"
        echo 'export PATH="$PATH:${PROJECT_ROOT}/.venv/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/share/dotnet"'
      } >> "$pf"
    fi
  done
}

ensure_auto_activate_venv() {
  local profile_dir="/home/${APP_USER}"
  [ -d "$profile_dir" ] || profile_dir="/root"
  for f in ".bashrc" ".profile"; do
    local pf="${profile_dir}/${f}"
    touch "$pf"
    if ! grep -q "auto-activate project venv" "$pf" 2>/dev/null; then
      echo '[ -f "${PROJECT_ROOT}/.venv/bin/activate" ] && . "${PROJECT_ROOT}/.venv/bin/activate"  # auto-activate project venv' >> "$pf"
    fi
  done
}

setup_auto_activate() {
  local profile_dir="/home/${APP_USER}"
  [ -d "$profile_dir" ] || profile_dir="/root"
  local bashrc_file="${profile_dir}/.bashrc"
  local activate_line='[ -f "${PROJECT_ROOT}/.venv/bin/activate" ] && . "${PROJECT_ROOT}/.venv/bin/activate"  # auto-activate project venv'
  if ! grep -qF ".venv/bin/activate" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

ensure_make_installed() {
  set -e
  if command -v make >/dev/null 2>&1; then
    :
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y make
  elif command -v yum >/dev/null 2>&1; then
    yum install -y make
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache make
  else
    echo "No supported package manager found to install make" >&2
    exit 1
  fi
}

ensure_makefile() {
  local makefile_path="${PROJECT_ROOT}/Makefile"
  if [ ! -f "$makefile_path" ]; then
    printf "%s\n" ".PHONY: all build" "all: build" "build:" "	@echo Build succeeded (no-op)" > "$makefile_path"
  else
    echo "Makefile already exists"
  fi
}

# ----------------------------
# Stack detectors
# ----------------------------
is_python_project() { has_any_file "requirements.txt" "pyproject.toml" "Pipfile" "setup.py" "manage.py" "app.py"; }
is_node_project()   { has_any_file "package.json"; }
is_ruby_project()   { has_any_file "Gemfile"; }
is_php_project()    { has_any_file "composer.json"; }
is_java_maven()     { has_any_file "pom.xml"; }
is_java_gradle()    { has_any_file "build.gradle" "build.gradle.kts" "gradlew"; }
is_go_project()     { has_any_file "go.mod"; }
is_rust_project()   { has_any_file "Cargo.toml"; }
is_dotnet_project() { ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1 || ls "$PROJECT_ROOT"/*/*.csproj >/dev/null 2>&1; }

# ----------------------------
# Stack setups
# ----------------------------
setup_build_essentials() {
  if [ "$OS_FAMILY" != "unknown" ]; then
    pkg_update
    pkg_install $BUILD_ESSENTIAL_PKGS
    pkg_clean
  else
    warn "Skipping build essentials install due to unknown OS."
  fi
}

setup_python() {
  [ "$(is_python_project && echo 1 || echo 0)" -eq 1 ] || return 0

  log "Setting up Python environment..."
  if [ "$OS_FAMILY" != "unknown" ]; then
    pkg_update
    pkg_install $PYTHON_PKGS
    pkg_clean
  fi

  if ! has_cmd python3; then
    error "python3 not found and could not be installed."
    return 1
  fi

  local pyver
  pyver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
  if ! semver_ge "$pyver" "$PYTHON_VERSION_MIN"; then
    warn "Python $pyver found, but >= $PYTHON_VERSION_MIN is recommended."
  fi

  # Create virtual environment
  local venv_dir="${PROJECT_ROOT}/.venv"
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
    log "Created virtual environment at $venv_dir"
  else
    info "Virtual environment already exists at $venv_dir"
  fi

  # Activate venv for current script context
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"

  python -m pip install --upgrade pip wheel setuptools

  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "${PROJECT_ROOT}/requirements.txt"
  elif has_file "pyproject.toml"; then
    if contains "${PROJECT_ROOT}/pyproject.toml" "^\s*\[tool\.poetry\]"; then
      log "Detected Poetry project. Installing Poetry and dependencies..."
      pip install "poetry>=1.5"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi --only main || poetry install --no-interaction --no-ansi
    else
      log "Installing Python project via PEP 517 (pyproject.toml)"
      pip install "${PROJECT_ROOT}" || warn "pip install of project failed; ensure pyproject is configured."
    fi
  elif has_file "Pipfile"; then
    warn "Detected Pipfile. Installing pipenv and attempting install into venv."
    pip install "pipenv>=2023.0"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  elif has_file "setup.py"; then
    log "Installing package in editable mode (setup.py)"
    pip install -e "${PROJECT_ROOT}" || pip install "${PROJECT_ROOT}"
  else
    info "No explicit Python dependency file found."
  fi

  # Common Python env vars
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1
}

setup_node() {
  [ "$(is_node_project && echo 1 || echo 0)" -eq 1 ] || return 0

  log "Setting up Node.js environment..."
  if [ "$OS_FAMILY" != "unknown" ]; then
    pkg_update
    pkg_install $NODE_PKGS
    pkg_clean
  fi

  if ! has_cmd node; then
    error "Node.js not found and could not be installed."
    return 1
  fi

  # Enable corepack for yarn/pnpm if available
  if has_cmd corepack; then
    corepack enable || true
  fi

  pushd "$PROJECT_ROOT" >/dev/null

  export NODE_ENV="${NODE_ENV:-production}"
  if has_file "yarn.lock"; then
    if has_cmd yarn; then
      log "Installing Node dependencies with Yarn (yarn.lock detected)"
      yarn install --frozen-lockfile || yarn install
    else
      if has_cmd corepack; then
        log "Using Corepack to run Yarn"
        corepack yarn install --frozen-lockfile || corepack yarn install
      else
        warn "Yarn not available and Corepack missing; falling back to npm"
        npm install
      fi
    fi
  elif has_file "package-lock.json" || has_file "npm-shrinkwrap.json"; then
    log "Installing Node dependencies with npm ci"
    npm ci || npm install
  else
    log "Installing Node dependencies with npm"
    npm install
  fi

  # Build step (optional)
  if jq -e '.scripts.build' package.json >/dev/null 2>&1; then
    log "Running npm/yarn build script..."
    if has_cmd yarn && has_file "yarn.lock"; then
      yarn build || true
    else
      npm run build || true
    fi
  fi

  popd >/dev/null
}

setup_ruby() {
  [ "$(is_ruby_project && echo 1 || echo 0)" -eq 1 ] || return 0

  log "Setting up Ruby environment..."
  if [ "$OS_FAMILY" != "unknown" ]; then
    pkg_update
    pkg_install $RUBY_PKGS
    pkg_clean
  fi

  if ! has_cmd ruby; then
    error "Ruby not found and could not be installed."
    return 1
  fi

  if ! has_cmd bundler; then
    gem install bundler -N || true
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  bundle config set --local path 'vendor/bundle'
  if [ "$APP_ENV" = "production" ]; then
    bundle install --without development test
  else
    bundle install
  fi
  popd >/dev/null
}

setup_php() {
  [ "$(is_php_project && echo 1 || echo 0)" -eq 1 ] || return 0

  log "Setting up PHP environment..."
  if [ "$OS_FAMILY" != "unknown" ]; then
    pkg_update
    pkg_install $PHP_PKGS
    pkg_clean
  fi

  if ! has_cmd php; then
    error "PHP not found and could not be installed."
    return 1
  fi

  if ! has_cmd composer; then
    log "Installing Composer..."
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ "$APP_ENV" = "production" ]; then
    composer install --no-dev --prefer-dist --no-interaction --no-progress
  else
    composer install --prefer-dist --no-interaction --no-progress
  fi
  popd >/dev/null
}

setup_java_maven() {
  [ "$(is_java_maven && echo 1 || echo 0)" -eq 1 ] || return 0

  log "Setting up Java (Maven) environment..."
  if [ "$OS_FAMILY" != "unknown" ]; then
    pkg_update
    pkg_install $JAVA_PKGS $MAVEN_PKG
    pkg_clean
  fi

  if ! has_cmd mvn; then
    error "Maven not found and could not be installed."
    return 1
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  mvn -B -q -DskipTests dependency:go-offline || warn "Maven go-offline failed; ensure pom.xml is valid."
  popd >/dev/null
}

setup_java_gradle() {
  [ "$(is_java_gradle && echo 1 || echo 0)" -eq 1 ] || return 0

  log "Setting up Java (Gradle) environment..."
  if [ "$OS_FAMILY" != "unknown" ]; then
    pkg_update
    pkg_install $JAVA_PKGS $GRADLE_PKG
    pkg_clean
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon help || true
  elif has_cmd gradle; then
    gradle --no-daemon help || true
  else
    warn "Gradle not found and wrapper missing."
  fi
  popd >/dev/null
}

setup_go() {
  [ "$(is_go_project && echo 1 || echo 0)" -eq 1 ] || return 0

  log "Setting up Go environment..."
  if [ "$OS_FAMILY" != "unknown" ] ; then
    pkg_update
    pkg_install $GO_PKG
    pkg_clean
  fi

  if ! has_cmd go; then
    error "Go not found and could not be installed."
    return 1
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  go mod download || warn "go mod download failed."
  popd >/dev/null
}

setup_rust() {
  [ "$(is_rust_project && echo 1 || echo 0)" -eq 1 ] || return 0

  log "Setting up Rust environment..."
  if [ "$OS_FAMILY" != "unknown" ]; then
    pkg_update
    pkg_install $RUST_PKGS
    pkg_clean
  fi

  if ! has_cmd cargo; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal
    rm -f /tmp/rustup.sh
    export PATH="$PATH:$HOME/.cargo/bin"
    ln -sf "$HOME/.cargo/bin/rustc" /usr/local/bin/rustc || true
    ln -sf "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo || true
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  cargo fetch || warn "cargo fetch failed."
  popd >/dev/null
}

setup_dotnet() {
  [ "$(is_dotnet_project && echo 1 || echo 0)" -eq 1 ] || return 0

  log "Setting up .NET environment..."
  if ! has_cmd dotnet; then
    log "Installing .NET SDK using official dotnet-install script..."
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --version latest --install-dir /usr/share/dotnet
    rm -f /tmp/dotnet-install.sh
    ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet || true
  fi

  if ! has_cmd dotnet; then
    error ".NET SDK installation failed."
    return 1
  fi

  # Restore dependencies
  shopt -s nullglob
  for csproj in "$PROJECT_ROOT"/*.csproj "$PROJECT_ROOT"/*/*.csproj; do
    [ -f "$csproj" ] || continue
    dotnet restore "$csproj" || warn "dotnet restore failed for $csproj"
  done
  shopt -u nullglob
}

# ----------------------------
# Main
# ----------------------------
main() {
  log "Starting environment setup in $PROJECT_ROOT"
  detect_os
  ensure_user
  ensure_project_dir
  setup_env_file
  ensure_shell_profiles
  ensure_auto_activate_venv
  setup_auto_activate
  setup_build_essentials
  ensure_make_installed
  ensure_makefile

  # Stack-specific setup
  setup_python
  setup_node
  setup_ruby
  setup_php
  setup_java_maven
  setup_java_gradle
  setup_go
  setup_rust
  setup_dotnet

  # Finalize permissions
  if [ "${SKIP_CHOWN}" != "1" ]; then
    chown -R "$APP_USER":"$APP_GID" "$PROJECT_ROOT" || chown -R "$APP_USER":"$APP_USER" "$PROJECT_ROOT" || true
  fi

  # Summarize
  log "Environment setup completed."
  echo "Summary:"
  echo " - OS family: $OS_FAMILY"
  echo " - Project root: $PROJECT_ROOT"
  echo " - App user: $APP_USER (uid:$APP_UID gid:$APP_GID)"
  echo " - App env: $APP_ENV"
  if [ -f "$PROJECT_ROOT/.env" ]; then
    echo " - Env file: $PROJECT_ROOT/.env"
    if grep -q "^APP_PORT=" "$PROJECT_ROOT/.env"; then
      APP_PORT_VAL="$(grep '^APP_PORT=' "$PROJECT_ROOT/.env" | head -n1 | cut -d'=' -f2)"
      echo " - Suggested port: $APP_PORT_VAL"
    fi
  fi

  echo
  echo "Next steps:"
  echo " - Ensure your Dockerfile sets WORKDIR to $PROJECT_ROOT and copies your project files."
  echo " - Source the virtualenv for Python projects: source ${PROJECT_ROOT}/.venv/bin/activate"
  echo " - Set environment variables as needed (see $PROJECT_ROOT/.env)."
}

main "$@"