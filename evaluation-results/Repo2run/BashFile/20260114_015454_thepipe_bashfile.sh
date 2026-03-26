#!/usr/bin/env bash
# Universal Project Environment Setup Script for Docker Containers
# This script attempts to detect the project type and install/configure the necessary runtime,
# system packages, and dependencies in a container-safe, idempotent manner.

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------
# Logging and error handling
# -----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

on_error() {
  local exit_code=$?
  local line_no=$1
  err "Setup failed at line $line_no with exit code $exit_code"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# -----------------------------
# Defaults and environment
# -----------------------------
APP_NAME="${APP_NAME:-app}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-}"
APP_PORT="${APP_PORT:-}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
UMASK_VALUE="${UMASK_VALUE:-022}"

# Ensure absolute path
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

# -----------------------------
# Helpers
# -----------------------------
has_file() { [ -f "$PROJECT_ROOT/$1" ]; }
has_dir() { [ -d "$PROJECT_ROOT/$1" ]; }

ensure_dir() {
  local dir="$1"
  [ -d "$dir" ] || mkdir -p "$dir"
}

# Load .env if present (safe parsing of KEY=VALUE lines)
load_dotenv() {
  local env_file="$PROJECT_ROOT/.env"
  if [ -f "$env_file" ]; then
    log "Loading environment variables from .env"
    # shellcheck disable=SC2163
    while IFS='=' read -r key value; do
      # skip comments and empty lines
      if [[ -z "$key" || "$key" =~ ^\s*# ]]; then
        continue
      fi
      # Remove export if present
      key="${key#export }"
      # Trim spaces
      key="$(echo -n "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      value="$(echo -n "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      # Strip quotes
      value="${value%\"}"
      value="${value#\"}"
      value="${value%\'}"
      value="${value#\'}"
      if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        export "$key=$value"
      fi
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=.*$' "$env_file" || true)
  fi
}

# -----------------------------
# Package manager detection
# -----------------------------
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
PM_NONINTERACTIVE=0

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
    PM_NONINTERACTIVE=1
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf -y makecache"
    PKG_INSTALL="dnf install -y"
    PKG_CLEAN="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum makecache -y"
    PKG_INSTALL="yum install -y"
    PKG_CLEAN="yum clean all"
  else
    err "No supported package manager found (apt, apk, dnf, yum)."
    exit 1
  fi
  log "Using package manager: $PKG_MANAGER"
}

pm_update() {
  log "Updating package index..."
  eval "$PKG_UPDATE" >/dev/null
}

pm_install() {
  local packages=("$@")
  if [ "${#packages[@]}" -eq 0 ]; then
    return 0
  fi
  log "Installing packages: ${packages[*]}"
  if [ "$PKG_MANAGER" = "apt" ] && [ "$PM_NONINTERACTIVE" -eq 1 ]; then
    export DEBIAN_FRONTEND=noninteractive
  fi
  # shellcheck disable=SC2086
  eval "$PKG_INSTALL ${packages[@]}"
}

pm_clean() {
  log "Cleaning package caches..."
  eval "$PKG_CLEAN" >/dev/null || true
}

# -----------------------------
# Base system setup
# -----------------------------
install_base_utils() {
  case "$PKG_MANAGER" in
    apt)
      pm_install ca-certificates curl git bash openssl unzip xz-utils tar gnupg build-essential pkg-config
      update-ca-certificates || true
      ;;
    apk)
      pm_install ca-certificates curl git bash openssl unzip xz tar build-base pkgconfig
      update-ca-certificates || true
      ;;
    dnf|yum)
      pm_install ca-certificates curl git bash openssl unzip xz tar gcc gcc-c++ make pkgconfig
      update-ca-trust || true
      ;;
  esac
}

# -----------------------------
# Language/runtime installers
# -----------------------------
install_python_runtime() {
  case "$PKG_MANAGER" in
    apt)
      pm_install python3 python3-venv python3-dev gcc libffi-dev libssl-dev
      ;;
    apk)
      pm_install python3 py3-pip python3-dev musl-dev libffi-dev openssl-dev
      ;;
    dnf|yum)
      pm_install python3 python3-pip python3-devel gcc libffi-devel openssl-devel
      ;;
  esac
}

setup_python_venv_and_deps() {
  local venv_dir="$PROJECT_ROOT/.venv"
  log "Setting up Python virtual environment at $venv_dir"
  if [ ! -f "$venv_dir/bin/activate" ]; then
    python3 -m venv "$venv_dir"
  fi
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1
  python -m pip install --upgrade pip wheel setuptools build
  # Create a placeholder requirements.txt if missing to satisfy setup.py/packaging
  if { has_file "setup.py" || has_file "pyproject.toml"; } && ! has_file "requirements.txt"; then
    printf "# Auto-generated placeholder to satisfy setup.py; add dependencies here\n" > "$PROJECT_ROOT/requirements.txt"
  fi
  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "$PROJECT_ROOT/requirements.txt"
  elif has_file "pyproject.toml"; then
    # Try PEP 517 build backend install
    log "Detected pyproject.toml, attempting 'pip install .'"
    pip install "$PROJECT_ROOT" || warn "pip install . failed; ensure build backend is configured."
  else
    warn "No requirements.txt or pyproject.toml found; skipping Python dependency installation."
  fi
}

install_node_runtime() {
  case "$PKG_MANAGER" in
    apt)
      # Use distro node (may be older); for most builds sufficient
      pm_install nodejs npm python3 g++ make
      ;;
    apk)
      pm_install nodejs npm python3 g++ make
      ;;
    dnf|yum)
      pm_install nodejs npm python3 gcc-c++ make
      ;;
  esac
}

setup_node_deps() {
  if has_file "package.json"; then
    log "Installing Node.js dependencies"
    pushd "$PROJECT_ROOT" >/dev/null
    # Enable corepack for yarn/pnpm if node supports it; ignore errors if not
    if command -v corepack >/dev/null 2>&1; then
      corepack enable || true
    fi
    if has_file "pnpm-lock.yaml"; then
      if command -v corepack >/dev/null 2>&1; then corepack prepare pnpm@latest --activate || true; fi
      if ! command -v pnpm >/dev/null 2>&1; then
        npm install -g pnpm || warn "Failed to install pnpm globally; falling back to npm"
      fi
      if command -v pnpm >/dev/null 2>&1; then
        pnpm install --frozen-lockfile || pnpm install
      else
        npm ci || npm install
      fi
    elif has_file "yarn.lock"; then
      if command -v corepack >/dev/null 2>&1; then corepack prepare yarn@stable --activate || true; fi
      if ! command -v yarn >/dev/null 2>&1; then
        npm install -g yarn || warn "Failed to install yarn globally; falling back to npm"
      fi
      if command -v yarn >/dev/null 2>&1; then
        yarn install --frozen-lockfile || yarn install
      else
        npm ci || npm install
      fi
    else
      npm ci || npm install
    fi
    popd >/dev/null
  else
    warn "package.json not found; skipping Node.js dependency installation."
  fi
}

install_java_runtime_tools() {
  case "$PKG_MANAGER" in
    apt)
      pm_install openjdk-17-jdk maven gradle
      ;;
    apk)
      # Some Alpine tags use different names; try to install commonly available packages
      pm_install openjdk17 maven gradle || pm_install openjdk11 maven gradle
      ;;
    dnf|yum)
      pm_install java-17-openjdk-devel maven gradle
      ;;
  esac
  export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)" 2>/dev/null || echo /usr/lib/jvm/java-17-openjdk)" )")}"
  export PATH="$JAVA_HOME/bin:$PATH"
}

setup_java_deps() {
  pushd "$PROJECT_ROOT" >/dev/null
  if has_file "pom.xml"; then
    if [ -x "./mvnw" ]; then
      ./mvnw -q -B -DskipTests dependency:resolve dependency:resolve-plugins || warn "Maven wrapper dependency resolution failed"
    else
      mvn -q -B -DskipTests dependency:go-offline || warn "Maven dependency resolution failed"
    fi
  fi
  if has_file "build.gradle" || has_file "build.gradle.kts"; then
    if [ -x "./gradlew" ]; then
      ./gradlew -q tasks || true
      ./gradlew -q build -x test || warn "Gradle wrapper build failed"
    else
      gradle -q build -x test || warn "Gradle build failed"
    fi
  fi
  popd >/dev/null
}

install_ruby_runtime() {
  case "$PKG_MANAGER" in
    apt)
      pm_install ruby-full build-essential ruby-dev
      ;;
    apk)
      pm_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pm_install ruby ruby-devel gcc make
      ;;
  esac
  gem install --no-document bundler || true
}

setup_ruby_deps() {
  if has_file "Gemfile"; then
    pushd "$PROJECT_ROOT" >/dev/null
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs 4 --retry 3
    popd >/dev/null
  else
    warn "Gemfile not found; skipping Ruby dependency installation."
  fi
}

install_go_runtime() {
  case "$PKG_MANAGER" in
    apt) pm_install golang ;; 
    apk) pm_install go ;;
    dnf|yum) pm_install golang ;;
  esac
}

setup_go_deps() {
  if has_file "go.mod"; then
    pushd "$PROJECT_ROOT" >/dev/null
    go env -w GOPATH="${GOPATH:-/go}" || true
    go mod download
    popd >/dev/null
  else
    warn "go.mod not found; skipping Go dependency installation."
  fi
}

install_rust_runtime() {
  case "$PKG_MANAGER" in
    apt) pm_install cargo rustc ;;
    apk) pm_install cargo rust ;;
    dnf|yum) pm_install cargo rust ;;
  esac
}

setup_rust_deps() {
  if has_file "Cargo.toml"; then
    pushd "$PROJECT_ROOT" >/dev/null
    cargo fetch || warn "Cargo fetch failed"
    popd >/dev/null
  else
    warn "Cargo.toml not found; skipping Rust dependency installation."
  fi
}

install_php_runtime() {
  case "$PKG_MANAGER" in
    apt)
      pm_install php-cli php-mbstring php-xml php-curl php-zip unzip
      # Composer
      if ! command -v composer >/dev/null 2>&1; then
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
      fi
      ;;
    apk)
      # Try php8.1 first, then php8, then default php
      pm_install php81-cli php81-mbstring php81-xml php81-curl php81-zip unzip || \
      pm_install php8-cli php8-mbstring php8-xml php8-curl php8-zip unzip || \
      pm_install php-cli php-mbstring php-xml php-curl php-zip unzip
      if ! command -v composer >/dev/null 2>&1; then
        pm_install composer || {
          curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
          php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
          rm -f /tmp/composer-setup.php
        }
      fi
      ;;
    dnf|yum)
      pm_install php-cli php-mbstring php-xml php-json php-zip unzip
      if ! command -v composer >/dev/null 2>&1; then
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
      fi
      ;;
  esac
}

setup_php_deps() {
  if has_file "composer.json"; then
    pushd "$PROJECT_ROOT" >/dev/null
    local composer_opts="--no-interaction --prefer-dist"
    if [ "${APP_ENV:-production}" = "production" ]; then
      composer install $composer_opts --no-dev || warn "Composer install failed"
    else
      composer install $composer_opts || warn "Composer install failed"
    fi
    popd >/dev/null
  else
    warn "composer.json not found; skipping PHP dependency installation."
  fi
}

# -----------------------------
# Project structure and permissions
# -----------------------------
setup_directories_and_permissions() {
  log "Setting up project directory structure at $PROJECT_ROOT"
  ensure_dir "$PROJECT_ROOT"
  ensure_dir "$PROJECT_ROOT/logs"
  ensure_dir "$PROJECT_ROOT/tmp"
  ensure_dir "$PROJECT_ROOT/.cache"
  ensure_dir "$PROJECT_ROOT/.config"
  # Typical runtime specific
  if has_file "package.json"; then ensure_dir "$PROJECT_ROOT/node_modules"; fi
  if has_file "requirements.txt" || has_file "pyproject.toml"; then ensure_dir "$PROJECT_ROOT/.venv"; fi
  if has_file "Gemfile"; then ensure_dir "$PROJECT_ROOT/vendor/bundle"; fi

  # Ownership
  if [ -n "$APP_USER" ]; then
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      log "Creating user $APP_USER"
      if [ -n "$APP_GROUP" ]; then
        if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
          groupadd -r "$APP_GROUP" || true
        fi
        useradd -r -g "$APP_GROUP" -d "$PROJECT_ROOT" -s /bin/bash "$APP_USER" || true
      else
        useradd -r -d "$PROJECT_ROOT" -s /bin/bash "$APP_USER" || true
      fi
    fi
    chown -R "$APP_USER:${APP_GROUP:-$APP_USER}" "$PROJECT_ROOT" || true
  fi

  umask "$UMASK_VALUE"
}

# -----------------------------
# Environment configuration
# -----------------------------
write_env_exports() {
  local env_file="$PROJECT_ROOT/.container_env"
  log "Writing container environment configuration to $env_file"
  {
    echo "export APP_NAME=${APP_NAME}"
    echo "export APP_ENV=${APP_ENV}"
    [ -n "${APP_PORT}" ] && echo "export APP_PORT=${APP_PORT}"
    echo "export PROJECT_ROOT=${PROJECT_ROOT}"
    echo "export PATH=${PROJECT_ROOT}/.venv/bin:\$PATH"
    echo "export PIP_DISABLE_PIP_VERSION_CHECK=1"
    echo "export PIP_NO_CACHE_DIR=1"
    echo "export NODE_ENV=${NODE_ENV:-production}"
    echo "export UV_THREADPOOL_SIZE=${UV_THREADPOOL_SIZE:-4}"
  } > "$env_file"

  # Shell profile hook
  local profile_hook="$PROJECT_ROOT/.profile"
  if ! grep -q ".container_env" "$profile_hook" 2>/dev/null; then
    echo '[ -f "$HOME/.container_env" ] && . "$HOME/.container_env"' >> "$profile_hook" || true
  fi

  # Symlink .container_env to HOME if PROJECT_ROOT != HOME
  if [ "$PROJECT_ROOT" != "$HOME" ]; then
    ln -sf "$env_file" "$HOME/.container_env" 2>/dev/null || true
    ln -sf "$PROJECT_ROOT/.profile" "$HOME/.profile" 2>/dev/null || true
  fi
}

setup_auto_activate() {
  local bashrc_file="$HOME/.bashrc"
  local container_env_line='[ -f "$HOME/.container_env" ] && . "$HOME/.container_env"'
  local venv_activate_line='[ -f "$PROJECT_ROOT/.venv/bin/activate" ] && . "$PROJECT_ROOT/.venv/bin/activate"'
  touch "$bashrc_file"
  if ! grep -qF "$container_env_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-source container environment"
      echo "$container_env_line"
    } >> "$bashrc_file"
  fi
  if ! grep -qF "$venv_activate_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate Python virtual environment"
      echo "$venv_activate_line"
    } >> "$bashrc_file"
  fi
}

# -----------------------------
# Generic build entrypoints and tools
# -----------------------------
setup_generic_build_entrypoints() {
  # Ensure 'make' is available for build orchestration
  if ! command -v make >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y make; elif command -v yum >/dev/null 2>&1; then yum install -y make; elif command -v apk >/dev/null 2>&1; then apk add --no-cache make; fi
  fi

  # Create a generic build script if not present
  if [ ! -f "$PROJECT_ROOT/scripts/build.sh" ]; then
    mkdir -p "$PROJECT_ROOT/scripts"
    cat > "$PROJECT_ROOT/scripts/build.sh" <<'EOF'
#!/usr/bin/env sh
set -e
# Node.js projects
if [ -f package.json ] && command -v npm >/dev/null 2>&1; then
  npm ci --no-audit --no-fund || npm install --no-audit --no-fund
  if npm run -s build >/dev/null 2>&1; then npm run build; else echo "No npm build script found"; fi
  exit 0
fi
# Python projects
if { [ -f pyproject.toml ] || [ -f setup.py ]; } && command -v python >/dev/null 2>&1; then
  python -m pip install --upgrade pip setuptools wheel build
  python -m build || echo "Python build tool ran but may not be configured"
  exit 0
fi
# Go projects
if [ -f go.mod ] && command -v go >/dev/null 2>&1; then
  go build ./...
  exit 0
fi
# Rust projects
if [ -f Cargo.toml ] && command -v cargo >/dev/null 2>&1; then
  cargo build --release
  exit 0
fi
# Fallback
echo "No recognized build configuration found."
exit 0
EOF
    chmod +x "$PROJECT_ROOT/scripts/build.sh"
  fi

  # Create a Makefile that delegates to the generic build script (only if missing)
  if [ ! -f "$PROJECT_ROOT/Makefile" ]; then
    cat > "$PROJECT_ROOT/Makefile" <<'EOF'
.PHONY: build test
build:
	@./scripts/build.sh

test:
	@./scripts/build.sh
EOF
  fi

  # Append a stub run target if Makefile exists but lacks one
  if [ -f "$PROJECT_ROOT/Makefile" ] && ! grep -qE '^[[:space:]]*run:' "$PROJECT_ROOT/Makefile"; then
    printf "\nrun:\n\t@echo 'Run target not defined for this project yet.'\n" >> "$PROJECT_ROOT/Makefile"
  fi
}

# -----------------------------
# Detection and setup orchestration
# -----------------------------
detect_and_setup() {
  local found_any=0

  if has_file "requirements.txt" || has_file "pyproject.toml" || has_file "setup.py"; then
    found_any=1
    log "Detected Python project artifacts"
    install_python_runtime
    setup_python_venv_and_deps
  fi

  if has_file "package.json"; then
    found_any=1
    log "Detected Node.js project artifacts"
    install_node_runtime
    setup_node_deps
  fi

  if has_file "pom.xml" || has_file "build.gradle" || has_file "build.gradle.kts" || [ -x "$PROJECT_ROOT/gradlew" ] || [ -x "$PROJECT_ROOT/mvnw" ]; then
    found_any=1
    log "Detected Java/Maven/Gradle project artifacts"
    install_java_runtime_tools
    setup_java_deps
  fi

  if has_file "Gemfile"; then
    found_any=1
    log "Detected Ruby/Bundler project artifacts"
    install_ruby_runtime
    setup_ruby_deps
  fi

  if has_file "go.mod"; then
    found_any=1
    log "Detected Go project artifacts"
    install_go_runtime
    setup_go_deps
  fi

  if has_file "Cargo.toml"; then
    found_any=1
    log "Detected Rust/Cargo project artifacts"
    install_rust_runtime
    setup_rust_deps
  fi

  if has_file "composer.json"; then
    found_any=1
    log "Detected PHP/Composer project artifacts"
    install_php_runtime
    setup_php_deps
  fi

  # .NET detection (informational)
  if ls "$PROJECT_ROOT"/*.csproj "$PROJECT_ROOT"/*.sln >/dev/null 2>&1; then
    warn ".NET project detected (*.csproj/*.sln). Automatic .NET SDK install is not implemented in this script."
    warn "Use a .NET base image (e.g., mcr.microsoft.com/dotnet/sdk:8.0) or preinstall the SDK in your Dockerfile."
  fi

  if [ "$found_any" -eq 0 ]; then
    warn "No known project files detected. The script installed base tools only."
  fi
}

# -----------------------------
# Main
# -----------------------------
main() {
  log "Starting environment setup for project at $PROJECT_ROOT"
  detect_pm
  pm_update
  install_base_utils

  setup_directories_and_permissions
  load_dotenv
  write_env_exports

  setup_auto_activate

  detect_and_setup

  setup_generic_build_entrypoints
  pm_clean

  log "Environment setup completed successfully."
  log "To load environment in current shell: source \"$PROJECT_ROOT/.container_env\""
}

main "$@"