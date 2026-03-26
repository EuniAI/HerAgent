#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common project types and installs runtime, system dependencies,
# sets up directories, permissions, and environment configuration.
#
# Safe to run multiple times (idempotent).

set -Eeuo pipefail
IFS=$'\n\t'

#-----------------------------
# Globals and defaults
#-----------------------------
APP_DIR="${APP_DIR:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
LOG_FILE="${LOG_FILE:-${APP_DIR}/setup.log}"
CREATE_APP_USER="${CREATE_APP_USER:-true}"
# If true, avoid building/compiling heavy artifacts; only dependencies
INSTALL_BUILD_DEPS="${INSTALL_BUILD_DEPS:-true}"

#-----------------------------
# Logging utilities
#-----------------------------
TS() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(TS)] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[WARN $(TS)] $*" | tee -a "$LOG_FILE" >&2; }
err() { echo "[ERROR $(TS)] $*" | tee -a "$LOG_FILE" >&2; }

on_error() {
  local exit_code=$?
  err "Setup failed at line ${BASH_LINENO[0]} while executing: ${BASH_COMMAND}"
  err "Exit code: $exit_code. Check ${LOG_FILE} for details."
  exit $exit_code
}
trap on_error ERR

#-----------------------------
# Helpers
#-----------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_file() { [ -f "$APP_DIR/$1" ]; }
has_any_file() {
  for f in "$@"; do
    if has_file "$f"; then return 0; fi
  done
  return 1
}

# idempotently set env var in .env file
set_env_kv() {
  local key="$1"
  local value="$2"
  local env_file="${APP_DIR}/.env"
  touch "$env_file"
  if grep -qE "^${key}=" "$env_file"; then
    # Replace existing
    sed -i "s#^${key}=.*#${key}=${value}#g" "$env_file"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
}

# Safe mkdir with permissive permissions for containers
mkd() {
  mkdir -p "$1"
  chmod 775 "$1" || true
}

#-----------------------------
# Package manager detection
#-----------------------------
PKG_MGR=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
PKG_QUERY_INSTALLED=""

detect_pkg_mgr() {
  if has_cmd apt-get; then
    PKG_MGR="apt"
    export DEBIAN_FRONTEND=noninteractive
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
    PKG_QUERY_INSTALLED="dpkg -s"
  elif has_cmd apk; then
    PKG_MGR="apk"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
    PKG_QUERY_INSTALLED="apk info -e"
  elif has_cmd dnf; then
    PKG_MGR="dnf"
    PKG_UPDATE="dnf -y update || true"
    PKG_INSTALL="dnf -y install"
    PKG_CLEAN="dnf clean all"
    PKG_QUERY_INSTALLED="rpm -q"
  elif has_cmd yum; then
    PKG_MGR="yum"
    PKG_UPDATE="yum -y update || true"
    PKG_INSTALL="yum -y install"
    PKG_CLEAN="yum clean all"
    PKG_QUERY_INSTALLED="rpm -q"
  elif has_cmd zypper; then
    PKG_MGR="zypper"
    PKG_UPDATE="zypper --non-interactive refresh"
    PKG_INSTALL="zypper --non-interactive install --no-recommends"
    PKG_CLEAN="zypper clean --all"
    PKG_QUERY_INSTALLED="rpm -q"
  else
    err "Unsupported base image: no known package manager (apt, apk, dnf, yum, zypper) found."
    exit 1
  fi
  log "Detected package manager: $PKG_MGR"
}

pkg_update_once() {
  # Use a marker to avoid repeated index updates in repeated runs
  local marker="/tmp/.pkg_updated_${PKG_MGR}"
  if [ ! -f "$marker" ]; then
    log "Updating package indexes..."
    eval "$PKG_UPDATE" >> "$LOG_FILE" 2>&1
    touch "$marker"
  else
    log "Package indexes already updated in this container lifecycle."
  fi
}

pkg_install() {
  # Install packages idempotently
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  log "Installing packages: ${pkgs[*]}"
  eval "$PKG_INSTALL ${pkgs[*]}" >> "$LOG_FILE" 2>&1
}

pkg_clean() {
  log "Cleaning package manager caches..."
  eval "$PKG_CLEAN" >> "$LOG_FILE" 2>&1 || true
}

#-----------------------------
# System baseline dependencies
#-----------------------------
install_baseline_deps() {
  detect_pkg_mgr
  # Force-refresh apt indexes to avoid stale/missing package lists
  if [ "$PKG_MGR" = "apt" ]; then
    rm -f /tmp/.pkg_updated_apt
  fi
  pkg_update_once

  case "$PKG_MGR" in
    apt)
      local base_pkgs=(
        ca-certificates curl git gnupg dirmngr
        bash coreutils findutils sed grep gawk tar xz-utils unzip zip
        build-essential pkg-config make
        openssh-client
        libc6-dev
        # locale is optional; skip to keep minimal
      )
      pkg_install "${base_pkgs[@]}"
      ;;
    apk)
      local base_pkgs=(
        ca-certificates curl git
        bash coreutils findutils sed grep gawk tar xz unzip zip
        build-base pkgconfig make
        openssh-client
      )
      pkg_install "${base_pkgs[@]}"
      ;;
    dnf|yum)
      local base_pkgs=(
        ca-certificates curl git gnupg2
        bash coreutils findutils sed grep gawk tar xz unzip zip
        make gcc gcc-c++ kernel-headers glibc-headers
        which pkg-config
        openssh-clients
      )
      pkg_install "${base_pkgs[@]}"
      ;;
    zypper)
      local base_pkgs=(
        ca-certificates curl git gpg2
        bash coreutils findutils sed grep gawk tar xz unzip zip
        make gcc gcc-c++ glibc-devel
        which pkg-config
        openssh
      )
      pkg_install "${base_pkgs[@]}"
      ;;
  esac

  # Ensure certificates
  if has_cmd update-ca-certificates; then update-ca-certificates >> "$LOG_FILE" 2>&1 || true; fi
}

#-----------------------------
# Create app user/group
#-----------------------------
ensure_app_user() {
  [ "$CREATE_APP_USER" = "true" ] || { log "Skipping app user creation (CREATE_APP_USER=false)"; return 0; }
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root; cannot create user/group. Continuing as current user."
    return 0
  fi

  # Create group
  if getent group "$APP_GROUP" >/dev/null 2>&1; then
    log "Group '$APP_GROUP' already exists."
  else
    if has_cmd groupadd; then
      groupadd -g "$APP_GID" "$APP_GROUP" >> "$LOG_FILE" 2>&1 || true
    elif has_cmd addgroup; then
      addgroup -g "$APP_GID" -S "$APP_GROUP" >> "$LOG_FILE" 2>&1 || true
    fi
    log "Ensured group '$APP_GROUP' (gid=$APP_GID)."
  fi

  # Create user
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User '$APP_USER' already exists."
  else
    if has_cmd useradd; then
      useradd -m -u "$APP_UID" -g "$APP_GROUP" -s /bin/bash "$APP_USER" >> "$LOG_FILE" 2>&1 || true
    elif has_cmd adduser; then
      # Busybox adduser
      adduser -D -h "/home/$APP_USER" -s /bin/bash -G "$APP_GROUP" -u "$APP_UID" "$APP_USER" >> "$LOG_FILE" 2>&1 || true
    fi
    log "Ensured user '$APP_USER' (uid=$APP_UID)."
  fi

  # Permissions on APP_DIR
  mkd "$APP_DIR"
  chown -R "$APP_UID:$APP_GID" "$APP_DIR" || true
  chmod -R g+rwX "$APP_DIR" || true
}

#-----------------------------
# Directory structure
#-----------------------------
setup_directories() {
  mkd "$APP_DIR"
  mkd "$APP_DIR/logs"
  mkd "$APP_DIR/tmp"
  mkd "$APP_DIR/.cache"
  mkd "$APP_DIR/.local/bin"
  touch "$LOG_FILE"
  chmod 664 "$LOG_FILE" || true
}

#-----------------------------
# Language/runtime setups
#-----------------------------

# Python
setup_python() {
  log "Configuring Python environment..."
  case "$PKG_MGR" in
    apt) pkg_install python3 python3-venv python3-pip python3-dev ;;
    apk) pkg_install python3 py3-pip python3-dev musl-dev ;; # venv is included in python3
    dnf|yum) pkg_install python3 python3-pip python3-devel gcc gcc-c++ make ;;
    zypper) pkg_install python3 python3-pip python3-devel gcc gcc-c++ make ;;
  esac

  # Create venv
  local venv_dir="${APP_DIR}/.venv"
  if [ ! -d "$venv_dir" ]; then
    log "Creating Python venv at $venv_dir"
    python3 -m venv "$venv_dir" >> "$LOG_FILE" 2>&1 || {
      # Alpine may need ensurepip
      python3 -m ensurepip --upgrade >> "$LOG_FILE" 2>&1 || true
      python3 -m venv "$venv_dir" >> "$LOG_FILE" 2>&1
    }
  else
    log "Python venv already exists."
  fi
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"

  python3 -m pip install --upgrade pip setuptools wheel >> "$LOG_FILE" 2>&1

  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    python3 -m pip install -r "$APP_DIR/requirements.txt" >> "$LOG_FILE" 2>&1
  elif has_file "pyproject.toml"; then
    # Detect Poetry usage
    if grep -qiE '^\s*\[tool\.poetry\]' "$APP_DIR/pyproject.toml"; then
      log "Detected Poetry in pyproject.toml; installing dependencies"
      export POETRY_VIRTUALENVS_CREATE=false
      python3 -m pip install "poetry>=1.5" >> "$LOG_FILE" 2>&1
      poetry install --no-interaction --only main >> "$LOG_FILE" 2>&1 || poetry install --no-interaction >> "$LOG_FILE" 2>&1
    else
      # PEP 517/621 project; try build/install
      log "Detected PEP 517/621 project; installing via pip"
      python3 -m pip install . >> "$LOG_FILE" 2>&1 || true
    fi
  elif has_file "Pipfile"; then
    log "Detected Pipfile; installing via pipenv (system)"
    python3 -m pip install pipenv >> "$LOG_FILE" 2>&1
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy >> "$LOG_FILE" 2>&1 || PIPENV_VENV_IN_PROJECT=1 pipenv install >> "$LOG_FILE" 2>&1
  else
    log "No Python dependency file found; skipping dependency install."
  fi

  # Set Python environment vars
  set_env_kv "PYTHONUNBUFFERED" "1"
  set_env_kv "PIP_NO_CACHE_DIR" "1"
  set_env_kv "VIRTUAL_ENV" "$venv_dir"
  # Ensure PATH includes venv
  if ! grep -q "^PATH=.*\.venv/bin" "$APP_DIR/.env" 2>/dev/null; then
    echo 'PATH='"$venv_dir"'/bin:$PATH' >> "$APP_DIR/.env"
  fi
}

# Node.js
setup_node() {
  log "Configuring Node.js environment..."
  case "$PKG_MGR" in
    apt) pkg_install nodejs npm ;;
    apk) pkg_install nodejs npm ;;
    dnf|yum) pkg_install nodejs npm ;;
    zypper) pkg_install nodejs npm ;;
  esac

  # Enable corepack if available (to manage yarn/pnpm)
  if has_cmd corepack; then
    corepack enable >> "$LOG_FILE" 2>&1 || true
  fi

  # Choose package manager based on lockfiles
  pushd "$APP_DIR" >/dev/null
  if has_file "yarn.lock"; then
    log "Detected yarn.lock"
    if ! has_cmd yarn; then
      if has_cmd corepack; then corepack prepare yarn@stable --activate >> "$LOG_FILE" 2>&1 || true; fi
      if ! has_cmd yarn; then npm install -g yarn >> "$LOG_FILE" 2>&1 || true; fi
    fi
    yarn install --frozen-lockfile >> "$LOG_FILE" 2>&1 || yarn install >> "$LOG_FILE" 2>&1
  elif has_file "pnpm-lock.yaml"; then
    log "Detected pnpm-lock.yaml"
    if ! has_cmd pnpm; then
      if has_cmd corepack; then corepack prepare pnpm@latest --activate >> "$LOG_FILE" 2>&1 || true; fi
      if ! has_cmd pnpm; then npm install -g pnpm >> "$LOG_FILE" 2>&1 || true; fi
    fi
    pnpm install --frozen-lockfile >> "$LOG_FILE" 2>&1 || pnpm install >> "$LOG_FILE" 2>&1
  elif has_file "package-lock.json"; then
    log "Detected package-lock.json"
    npm ci >> "$LOG_FILE" 2>&1 || npm install >> "$LOG_FILE" 2>&1
  elif has_file "package.json"; then
    log "Detected package.json"
    npm install >> "$LOG_FILE" 2>&1
  else
    log "No Node.js dependency file found; skipping."
  fi
  popd >/dev/null

  set_env_kv "NODE_ENV" "${NODE_ENV:-$APP_ENV}"
  set_env_kv "NPM_CONFIG_LOGLEVEL" "warn"
}

# Java / JVM
setup_java() {
  log "Configuring Java/JVM environment..."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk-headless maven ;;
    apk) pkg_install openjdk17-jdk maven ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven ;;
    zypper) pkg_install java-17-openjdk-devel maven ;;
  esac

  pushd "$APP_DIR" >/dev/null
  if has_file "mvnw"; then
    chmod +x mvnw
    ./mvnw -v >> "$LOG_FILE" 2>&1 || true
    ./mvnw -B dependency:resolve >> "$LOG_FILE" 2>&1 || true
  elif has_file "pom.xml"; then
    mvn -B -q -e -DskipTests dependency:resolve >> "$LOG_FILE" 2>&1 || true
  fi

  if has_file "gradlew"; then
    chmod +x gradlew
    ./gradlew --version >> "$LOG_FILE" 2>&1 || true
    ./gradlew --no-daemon build -x test >> "$LOG_FILE" 2>&1 || true
  fi
  popd >/dev/null
}

# Go
setup_go() {
  log "Configuring Go environment..."
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac

  # Set GOPATH and GOCACHE inside project
  local gopath="${APP_DIR}/.go"
  mkd "$gopath"
  set_env_kv "GOPATH" "$gopath"
  set_env_kv "GOCACHE" "${APP_DIR}/.cache/go-build"
  if ! grep -q "^PATH=.*\.go/bin" "$APP_DIR/.env" 2>/dev/null; then
    echo 'PATH='"$gopath"'/bin:$PATH' >> "$APP_DIR/.env"
  fi

  if has_file "go.mod"; then
    pushd "$APP_DIR" >/dev/null
    go env -w GOPATH="$gopath" GOCACHE="${APP_DIR}/.cache/go-build" >> "$LOG_FILE" 2>&1 || true
    go mod download >> "$LOG_FILE" 2>&1 || true
    popd >/dev/null
  fi
}

# Ruby
setup_ruby() {
  log "Configuring Ruby environment..."
  case "$PKG_MGR" in
    apt) pkg_install ruby-full ruby-dev build-essential ;;
    apk) pkg_install ruby ruby-dev build-base ;;
    dnf|yum) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
    zypper) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
  esac

  if ! has_cmd gem; then
    warn "Ruby gem tool not found; skipping bundler install."
    return 0
  fi

  if has_file "Gemfile"; then
    gem install bundler --no-document >> "$LOG_FILE" 2>&1 || true
    pushd "$APP_DIR" >/dev/null
    bundle config set --local path 'vendor/bundle' >> "$LOG_FILE" 2>&1 || true
    bundle install --jobs=4 >> "$LOG_FILE" 2>&1 || true
    popd >/dev/null
  fi
}

# PHP
setup_php() {
  log "Configuring PHP environment..."
  case "$PKG_MGR" in
    apt) pkg_install php-cli php-json php-mbstring php-xml php-curl php-zip composer ;;
    apk) pkg_install php81 php81-cli php81-json php81-mbstring php81-xml php81-curl php81-zip composer || pkg_install php php-cli php-json php-mbstring php-xml php-curl php-zip ;;
    dnf|yum) pkg_install php-cli php-json php-mbstring php-xml php-curl php-zip composer || pkg_install php-cli composer ;;
    zypper) pkg_install php8 php8-cli php8-json php8-mbstring php8-xml php8-curl php8-zip composer || pkg_install php php-cli composer ;;
  esac

  if has_file "composer.json"; then
    pushd "$APP_DIR" >/dev/null
    if has_cmd composer; then
      composer install --no-interaction --prefer-dist >> "$LOG_FILE" 2>&1 || true
    else
      warn "Composer not available; skipping composer install."
    fi
    popd >/dev/null
  fi
}

# Rust
setup_rust() {
  log "Configuring Rust environment..."
  case "$PKG_MGR" in
    apt) pkg_install rustc cargo ;;
    apk) pkg_install rust cargo ;;
    dnf|yum) pkg_install rust cargo ;;
    zypper) pkg_install rust cargo ;;
  esac

  if has_file "Cargo.toml"; then
    pushd "$APP_DIR" >/dev/null
    cargo fetch >> "$LOG_FILE" 2>&1 || true
    popd >/dev/null
  fi
}

# .NET (best-effort; may not be available on minimal images)
setup_dotnet() {
  log "Checking for .NET project..."
  if ls "$APP_DIR"/*.sln "$APP_DIR"/*.csproj "$APP_DIR"/*.fsproj >/dev/null 2>&1; then
    warn ".NET SDK setup is not fully automated in this script due to repo-specific feeds."
    warn "Consider using a base image with dotnet SDK preinstalled (e.g., mcr.microsoft.com/dotnet/sdk:8.0)."
  fi
}

#-----------------------------
# Project type detection
#-----------------------------
detect_and_setup_project() {
  local did_any=false

  # Python
  if has_any_file "requirements.txt" "pyproject.toml" "Pipfile"; then
    setup_python
    did_any=true
  fi

  # Node
  if has_any_file "package.json" "yarn.lock" "pnpm-lock.yaml" "package-lock.json"; then
    setup_node
    did_any=true
  fi

  # Java
  if has_any_file "pom.xml" "build.gradle" "build.gradle.kts" "gradlew" "mvnw"; then
    setup_java
    did_any=true
  fi

  # Go
  if has_file "go.mod"; then
    setup_go
    did_any=true
  fi

  # Ruby
  if has_file "Gemfile"; then
    setup_ruby
    did_any=true
  fi

  # PHP
  if has_file "composer.json"; then
    setup_php
    did_any=true
  fi

  # Rust
  if has_file "Cargo.toml"; then
    setup_rust
    did_any=true
  fi

  setup_dotnet

  if [ "$did_any" = false ]; then
    warn "No recognized project files found. The script installed baseline tools only."
  fi
}

#-----------------------------
# Environment configuration
#-----------------------------
configure_environment() {
  log "Configuring environment variables..."
  set_env_kv "APP_ENV" "$APP_ENV"
  set_env_kv "PORT" "$APP_PORT"

  # Generic variables
  set_env_kv "PATH" '$HOME/.local/bin:'"$PATH"
  # Create .env only if not present; we already touch in set_env_kv
  if [ ! -s "$APP_DIR/.env" ]; then
    log "Created default .env at $APP_DIR/.env"
  else
    log ".env updated at $APP_DIR/.env"
  fi

  # Create .dockerignore/.gitignore additions (idempotent)
  for ignore_file in ".gitignore" ".dockerignore"; do
    local_file="${APP_DIR}/${ignore_file}"
    touch "$local_file"
    for pat in ".venv" "vendor/bundle" "node_modules" ".go" ".cache" "tmp" "logs" ".gradle" "target" "dist" "build"; do
      grep -qxF "$pat" "$local_file" 2>/dev/null || echo "$pat" >> "$local_file"
    done
  done
}

setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_path="${APP_DIR}/.venv"
  local activate_line="source ${venv_path}/bin/activate"
  if [ -d "${venv_path}/bin" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

#-----------------------------
# Permissions
#-----------------------------
fix_permissions() {
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "$APP_UID:$APP_GID" "$APP_DIR" || true
    chmod -R g+rwX "$APP_DIR" || true
  else
    warn "Not root; skipping chown. Ensure proper permissions externally."
  fi
}

#-----------------------------
# Main
#-----------------------------
main() {
  umask 002
  mkd "$APP_DIR"
  touch "$LOG_FILE" || true

  log "Starting universal environment setup for project in $APP_DIR"
  log "Environment: APP_ENV=$APP_ENV APP_PORT=$APP_PORT USER=$(id -un) BASE_PKG_MGR=auto"
  install_baseline_deps
  setup_directories
  ensure_app_user

  detect_and_setup_project
  configure_environment
  setup_auto_activate

  pkg_clean
  fix_permissions

  log "Environment setup completed successfully."
  log "Next steps:"
  log "- Review/update ${APP_DIR}/.env"
  log "- To use Python venv in shell: source ${APP_DIR}/.venv/bin/activate (if applicable)"
  log "- Run your application using your project's standard command (e.g., npm start, python app.py, gunicorn, etc.)"
}

main "$@"