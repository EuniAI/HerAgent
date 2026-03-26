#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects tech stack and installs runtimes and system dependencies
# - Configures environment, users, permissions, and dependency installation
# - Idempotent, safe to rerun
# - Supports Debian/Ubuntu (apt), Alpine (apk), and RHEL/CentOS/Fedora (dnf/yum/microdnf)

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ------------------------------
# Logging and error handling
# ------------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Setup failed with exit code ${exit_code}"
  fi
}
trap cleanup EXIT

# ------------------------------
# Defaults and globals
# ------------------------------
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}
export TZ=${TZ:-UTC}

PROJECT_ROOT="${PROJECT_ROOT:-}"
if [[ -z "${PROJECT_ROOT}" ]]; then
  # If current directory looks like a project, use it; else default to /app
  if ls -A 1 >/dev/null 2>&1; then
    PROJECT_ROOT="$PWD"
  else
    PROJECT_ROOT="/app"
  fi
fi

APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
CREATE_USER="${CREATE_USER:-1}"  # set to 0 to skip creating a non-root user

SETUP_MARKER="${PROJECT_ROOT}/.setup_complete"
ENV_PROFILE_FILE="/etc/profile.d/10-app-env.sh"
VENV_DIR="${VENV_DIR:-/opt/venv}"

# Stack detection flags
IS_NODE=0
IS_PYTHON=0
IS_RUBY=0
IS_GO=0
IS_JAVA=0
IS_RUST=0
IS_PHP=0
IS_DOTNET=0

PKG_MGR=""
UPDATED=0

# ------------------------------
# Utility functions
# ------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
  if have_cmd apt-get; then PKG_MGR="apt";
  elif have_cmd apk; then PKG_MGR="apk";
  elif have_cmd microdnf; then PKG_MGR="microdnf";
  elif have_cmd dnf; then PKG_MGR="dnf";
  elif have_cmd yum; then PKG_MGR="yum";
  else
    err "No supported package manager found (apt, apk, dnf, yum, microdnf)."
    exit 1
  fi
  log "Detected package manager: ${PKG_MGR}"
}

pm_update() {
  case "$PKG_MGR" in
    apt)
      if [[ $UPDATED -eq 0 ]]; then
        log "Updating apt package lists..."
        apt-get update -y
        UPDATED=1
      fi
      ;;
    apk)
      # apk doesn't need a separate update with --no-cache
      ;;
    dnf|yum|microdnf)
      # dnf/yum handle metadata automatically
      ;;
  esac
}

pm_install() {
  local pkgs=("$@")
  case "$PKG_MGR" in
    apt)
      pm_update
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    microdnf)
      microdnf install -y "${pkgs[@]}"
      ;;
  esac
}

pm_clean() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
      ;;
    dnf|yum|microdnf)
      # Clean caches if available
      if have_cmd dnf; then dnf clean all || true; fi
      if have_cmd yum; then yum clean all || true; fi
      rm -rf /var/cache/dnf /var/cache/yum /tmp/* /var/tmp/* || true
      ;;
  esac
}

# ------------------------------
# System base setup
# ------------------------------
setup_os_basics() {
  detect_pkg_manager

  log "Installing base system packages..."
  case "$PKG_MGR" in
    apt)
      pm_install ca-certificates curl git openssl tzdata bash coreutils findutils sed grep gawk \
                 tar xz-utils unzip zip gzip bzip2 gnupg apt-transport-https \
                 build-essential pkg-config
      update-ca-certificates || true
      ;;
    apk)
      pm_install ca-certificates curl git openssl tzdata bash coreutils findutils sed grep gawk \
                 tar xz unzip zip gzip bzip2 gnupg \
                 build-base pkgconfig
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pm_install ca-certificates curl git openssl tzdata bash coreutils findutils sed grep gawk \
                 tar xz unzip zip gzip bzip2 gnupg2 which \
                 make automake gcc gcc-c++ kernel-headers pkgconf-pkg-config
      update-ca-trust || true
      ;;
  esac

  # Tools for user management
  case "$PKG_MGR" in
    apt) pm_install passwd ;;
    apk) pm_install shadow || pm_install shadow-uidmap || true ;;
    dnf|yum|microdnf) pm_install shadow-utils || true ;;
  esac

  # Set timezone
  if [[ -f /usr/share/zoneinfo/$TZ ]]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone || true
  fi

  # UTF-8 locale environment
  if [[ -z "${LANG:-}" ]]; then
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
  fi
}

# ------------------------------
# User and directory setup
# ------------------------------
ensure_directories() {
  log "Ensuring project directories..."
  mkdir -p "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/.cache"
  # Common dependency/cache dirs
  mkdir -p "$PROJECT_ROOT/node_modules" || true
  mkdir -p "$PROJECT_ROOT/vendor" || true
  mkdir -p "$PROJECT_ROOT/.venv" || true
}

ensure_user() {
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "Not running as root. User management and some system changes may fail."
    return 0
  fi
  if [[ "$CREATE_USER" != "1" ]]; then
    log "Skipping creation of non-root user (CREATE_USER=$CREATE_USER)."
    return 0
  fi

  # Create group if missing
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apk) addgroup -g "$APP_GID" "$APP_GROUP" ;;
      *) groupadd -g "$APP_GID" "$APP_GROUP" ;;
    esac
  fi

  # Create user if missing
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apk) adduser -D -H -s /bin/bash -G "$APP_GROUP" -u "$APP_UID" "$APP_USER" ;;
      *) useradd -m -s /bin/bash -g "$APP_GROUP" -u "$APP_UID" "$APP_USER" ;;
    esac
  fi

  # Ensure home exists
  local home_dir
  home_dir="$(getent passwd "$APP_USER" | cut -d: -f6)"
  mkdir -p "$home_dir" "$home_dir/.cache" "$home_dir/.local/bin"

  # Ownership of project
  chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT" "$home_dir" 2>/dev/null || true
}

# ------------------------------
# Stack detection
# ------------------------------
detect_stack() {
  log "Detecting project stack in ${PROJECT_ROOT} ..."
  shopt -s nullglob
  pushd "$PROJECT_ROOT" >/dev/null

  # Node.js
  if [[ -f package.json ]]; then IS_NODE=1; fi

  # Python
  if [[ -f requirements.txt || -f requirements-dev.txt || -f Pipfile || -f pyproject.toml || -f setup.py ]]; then
    IS_PYTHON=1
  fi

  # Ruby
  if [[ -f Gemfile ]]; then IS_RUBY=1; fi

  # Go
  if [[ -f go.mod ]]; then IS_GO=1; fi

  # Java
  if compgen -G "pom.xml" >/dev/null; then IS_JAVA=1; fi
  if compgen -G "build.gradle* gradle.properties settings.gradle*" >/dev/null; then IS_JAVA=1; fi

  # Rust
  if [[ -f Cargo.toml ]]; then IS_RUST=1; fi

  # PHP
  if [[ -f composer.json ]]; then IS_PHP=1; fi

  # .NET (best-effort)
  if compgen -G "*.sln *.csproj global.json" >/dev/null; then IS_DOTNET=1; fi

  popd >/dev/null

  log "Detected stacks: Node=$IS_NODE Python=$IS_PYTHON Ruby=$IS_RUBY Go=$IS_GO Java=$IS_JAVA Rust=$IS_RUST PHP=$IS_PHP DotNet=$IS_DOTNET"
}

# ------------------------------
# Language/runtime installers
# ------------------------------
install_node() {
  log "Installing Node.js runtime and tools..."
  case "$PKG_MGR" in
    apt)
      pm_install nodejs npm
      ;;
    apk)
      pm_install nodejs npm
      ;;
    dnf|yum|microdnf)
      # Some distros provide modular streams; try nodejs
      pm_install nodejs npm || warn "Could not install nodejs via ${PKG_MGR}. Consider using a Node-specific base image."
      ;;
  esac

  if have_cmd corepack; then
    corepack enable || true
  fi
}

install_python() {
  log "Installing Python runtime and tools..."
  case "$PKG_MGR" in
    apt)
      pm_install software-properties-common ca-certificates gnupg curl
      add-apt-repository -y ppa:deadsnakes/ppa
      apt-get update -y
      pm_install python3.11 python3.11-venv python3.11-dev
      pm_install build-essential pkg-config
      ;;
    apk)
      pm_install python3 py3-pip py3-setuptools py3-virtualenv python3-dev musl-dev gcc
      ;;
    dnf|yum|microdnf)
      pm_install python3 python3-pip python3-devel
      pm_install make automake gcc gcc-c++ kernel-headers
      ;;
  esac

  # Create shared venv (prefer Python 3.11 if available)
  if [[ -x "$VENV_DIR/bin/python3" ]]; then
    current_py="$("$VENV_DIR/bin/python3" -c 'import sys; print(".".join(map(str, sys.version_info[:2])))' 2>/dev/null || echo)"
    if [[ "$current_py" != "3.11" && $(command -v python3.11 2>/dev/null) ]]; then
      rm -rf "$VENV_DIR"
    fi
  fi
  if [[ ! -d "$VENV_DIR" || ! -x "$VENV_DIR/bin/python3" ]]; then
    if command -v python3.11 >/dev/null 2>&1; then
      python3.11 -m venv "$VENV_DIR"
    else
      python3 -m venv "$VENV_DIR"
    fi
  fi
  # Upgrade pip/setuptools/wheel
  "$VENV_DIR/bin/python3" -m pip install --upgrade pip setuptools wheel
}

install_ruby() {
  log "Installing Ruby runtime and bundler..."
  case "$PKG_MGR" in
    apt)
      pm_install ruby-full ruby-dev build-essential
      ;;
    apk)
      pm_install ruby ruby-dev build-base
      ;;
    dnf|yum|microdnf)
      pm_install ruby ruby-devel make automake gcc gcc-c++ redhat-rpm-config
      ;;
  esac
  gem install --no-document bundler || true
}

install_go() {
  log "Installing Go runtime..."
  case "$PKG_MGR" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    dnf|yum|microdnf) pm_install golang ;;
  esac
}

install_java() {
  log "Installing Java (OpenJDK) and build tools..."
  case "$PKG_MGR" in
    apt)
      pm_install openjdk-17-jdk maven
      pm_install gradle || true
      ;;
    apk)
      pm_install openjdk17 maven
      pm_install gradle || true
      ;;
    dnf|yum|microdnf)
      pm_install java-17-openjdk java-17-openjdk-devel maven
      pm_install gradle || true
      ;;
  esac
}

# Proactive installation to avoid mvn not found errors in CI even if no Java project is detected
ensure_maven_jdk() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y maven default-jdk
  elif command -v yum >/dev/null 2>&1; then
    yum install -y maven java-11-openjdk-devel
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y maven java-11-openjdk-devel
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache maven openjdk11
  else
    echo "No supported package manager found" >&2
    exit 1
  fi
  mvn -version || true
}

create_mvn_wrapper() {
  local wrapper="/usr/local/bin/mvn"
  if [ ! -w "$(dirname "$wrapper")" ]; then
    warn "Insufficient permissions to write $wrapper; skipping wrapper creation."
    return 0
  fi
  cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# If current dir has a pom or caller already specified -f/--file, use real Maven directly
if [[ -f "pom.xml" ]] || [[ " $* " == *" -f "* ]] || [[ " $* " == *" --file "* ]]; then
  exec /usr/bin/mvn "$@"
fi
# Search for a pom.xml in common roots
search_roots=(/app /workspace /workdir /home /src /project /repo)
for root in "${search_roots[@]}"; do
  if [[ -d "$root" ]]; then
    candidate=$(find "$root" -maxdepth 6 -type f -name pom.xml \
      -not -path "*/target/*" -not -path "*/.*/*" 2>/dev/null | head -n1 || true)
    if [[ -n "${candidate:-}" ]]; then
      exec /usr/bin/mvn -f "$candidate" "$@"
    fi
  fi
done
# Fallback: shallow search on the current filesystem
candidate=$(find / -xdev -maxdepth 4 -type f -name pom.xml -not -path "*/target/*" 2>/dev/null | head -n1 || true)
if [[ -n "${candidate:-}" ]]; then
  exec /usr/bin/mvn -f "$candidate" "$@"
fi
echo "Error: No pom.xml found in current directory or searched roots. Please run from a Maven project directory." >&2
exit 1
EOF
  chmod +x "$wrapper" || true
}

ensure_app_pom() {
  mkdir -p /app
  local POM
  POM=$(find / -xdev -type f -name pom.xml -not -path "/proc/*" -not -path "/sys/*" -not -path "/dev/*" -not -path "/run/*" -print -quit 2>/dev/null || true)
  if [ -n "${POM:-}" ]; then
    ln -sf "$POM" /app/pom.xml
    echo "Linked /app/pom.xml -> $POM"
  else
    cat >/app/pom.xml <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>placeholder</groupId>
  <artifactId>placeholder</artifactId>
  <version>0.0.1</version>
  <packaging>pom</packaging>
</project>
EOF
    echo "Created placeholder /app/pom.xml"
  fi
}

install_rust() {
  log "Installing Rust toolchain (system packages)..."
  case "$PKG_MGR" in
    apt) pm_install rustc cargo ;;
    apk) pm_install rust cargo ;;
    dnf|yum|microdnf) pm_install rust cargo ;;
  esac
}

install_php() {
  log "Installing PHP and Composer..."
  case "$PKG_MGR" in
    apt)
      pm_install php-cli php-mbstring php-xml php-curl php-zip php-gd php-json php-bcmath php-intl php-sqlite3
      pm_install composer || {
        # Fallback to installer
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
          && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
          && rm -f composer-setup.php
      }
      ;;
    apk)
      pm_install php81 php81-cli php81-phar php81-openssl php81-curl php81-mbstring php81-xml php81-tokenizer php81-simplexml php81-fileinfo php81-zip php81-intl
      pm_install composer || true
      ln -sf /usr/bin/php81 /usr/bin/php || true
      ;;
    dnf|yum|microdnf)
      pm_install php-cli php-json php-mbstring php-xml php-zip php-gd php-intl php-sqlite3 || true
      pm_install composer || true
      ;;
  esac
}

install_dotnet() {
  # Best-effort: dotnet installation varies by distro; recommend using .NET base images
  warn ".NET installation is not fully automated in this script. Consider using a dotnet SDK base image."
}

# ------------------------------
# Dependency installation per stack
# ------------------------------
install_deps_node() {
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f package.json ]]; then
    log "Installing Node.js dependencies..."
    if [[ -f yarn.lock ]]; then
      if have_cmd yarn; then
        yarn install --frozen-lockfile
      else
        if have_cmd corepack; then corepack enable && corepack prepare yarn@stable --activate; fi
        if have_cmd yarn; then yarn install --frozen-lockfile; else npm install -g yarn && yarn install --frozen-lockfile; fi
      fi
    elif [[ -f pnpm-lock.yaml ]]; then
      if have_cmd pnpm; then
        pnpm install --frozen-lockfile
      else
        if have_cmd corepack; then corepack enable && corepack prepare pnpm@latest --activate; fi
        if have_cmd pnpm; then pnpm install --frozen-lockfile; else npm install -g pnpm && pnpm install --frozen-lockfile; fi
      fi
    elif [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
      npm ci
    else
      npm install
    fi
  fi
  popd >/dev/null
}

install_deps_python() {
  pushd "$PROJECT_ROOT" >/dev/null
  log "Installing Python dependencies..."
  export PIP_CACHE_DIR="${PROJECT_ROOT}/.cache/pip"
  mkdir -p "$PIP_CACHE_DIR"

  if [[ -f requirements.txt || -f requirements-dev.txt || -f requirements/prod.txt || -f requirements/base.txt ]]; then
    # Install most specific if available
    if [[ -f requirements.txt ]]; then
      "$VENV_DIR/bin/python3" -m pip install -r requirements.txt
    fi
    if [[ -f requirements/base.txt ]]; then
      "$VENV_DIR/bin/python3" -m pip install -r requirements/base.txt
    fi
    if [[ -f requirements/prod.txt ]]; then
      "$VENV_DIR/bin/python3" -m pip install -r requirements/prod.txt
    fi
    if [[ -f requirements-dev.txt ]]; then
      "$VENV_DIR/bin/python3" -m pip install -r requirements-dev.txt
    fi
  elif [[ -f setup.py ]]; then
    "$VENV_DIR/bin/python3" -m pip install -e .
  elif [[ -f pyproject.toml ]]; then
    # Try to install the project in editable mode
    "$VENV_DIR/bin/python3" -m pip install -e "$PROJECT_ROOT"
  else
    warn "No Python dependency files found."
  fi
  popd >/dev/null
}

install_deps_ruby() {
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f Gemfile ]]; then
    log "Installing Ruby gems via Bundler..."
    export BUNDLE_PATH="${PROJECT_ROOT}/vendor/bundle"
    export BUNDLE_WITHOUT="${BUNDLE_WITHOUT:-development:test}"
    bundle config set path "$BUNDLE_PATH"
    bundle install --jobs="$(nproc)" --retry=3
  fi
  popd >/dev/null
}

install_deps_go() {
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f go.mod ]]; then
    log "Downloading Go modules..."
    go env -w GOPATH="${PROJECT_ROOT}/.gopath" || true
    mkdir -p "${PROJECT_ROOT}/.gopath/bin"
    go mod download
  fi
  popd >/dev/null
}

install_deps_java() {
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f pom.xml ]]; then
    log "Resolving Maven dependencies (offline preparation)..."
    if [[ -x "./mvnw" ]]; then
      ./mvnw -B -q -DskipTests dependency:go-offline || true
    else
      mvn -B -q -DskipTests dependency:go-offline || true
    fi
  fi
  if compgen -G "build.gradle* settings.gradle*" >/dev/null; then
    log "Resolving Gradle dependencies..."
    if [[ -x "./gradlew" ]]; then
      ./gradlew --no-daemon --quiet tasks >/dev/null 2>&1 || true
    elif have_cmd gradle; then
      gradle --no-daemon --quiet tasks >/dev/null 2>&1 || true
    fi
  fi
  popd >/dev/null
}

install_deps_rust() {
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f Cargo.toml ]]; then
    log "Fetching Rust crate dependencies..."
    cargo fetch || true
  fi
  popd >/dev/null
}

install_deps_php() {
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f composer.json ]]; then
    log "Installing PHP dependencies via Composer..."
    if have_cmd composer; then
      COMPOSER_CACHE_DIR="${PROJECT_ROOT}/.cache/composer" composer install --no-interaction --prefer-dist --no-progress
    else
      err "Composer not available."
    fi
  fi
  popd >/dev/null
}

# ------------------------------
# Environment configuration
# ------------------------------
write_env_profile() {
  log "Writing environment profile to ${ENV_PROFILE_FILE} ..."
  local home_dir
  if getent passwd "$APP_USER" >/dev/null 2>&1; then
    home_dir="$(getent passwd "$APP_USER" | cut -d: -f6)"
  else
    home_dir="/root"
  fi

  cat > "$ENV_PROFILE_FILE" <<EOF
# Auto-generated environment profile for the application
export TZ="${TZ}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export APP_ENV="\${APP_ENV:-production}"
export PROJECT_ROOT="${PROJECT_ROOT}"

# Python virtual environment
if [ -x "${VENV_DIR}/bin/activate" ]; then
  export VIRTUAL_ENV="${VENV_DIR}"
  export PATH="${VENV_DIR}/bin:\$PATH"
fi

# Node local binaries
if [ -d "${PROJECT_ROOT}/node_modules/.bin" ]; then
  export PATH="${PROJECT_ROOT}/node_modules/.bin:\$PATH"
fi

# Ruby bundler bin (varies by platform/version)
if [ -d "${PROJECT_ROOT}/vendor/bundle" ]; then
  for d in \$(find "${PROJECT_ROOT}/vendor/bundle" -maxdepth 3 -type d -name bin 2>/dev/null); do
    export PATH="\$d:\$PATH"
  done
fi

# Go bin
if [ -d "${PROJECT_ROOT}/.gopath/bin" ]; then
  export GOBIN="${PROJECT_ROOT}/.gopath/bin"
  export PATH="\$GOBIN:\$PATH"
fi

# User local bin
export PATH="${home_dir}/.local/bin:\$PATH"

# Common app ports (override as needed)
export PORT="\${PORT:-3000}"

# Python pip cache
export PIP_CACHE_DIR="${PROJECT_ROOT}/.cache/pip"
EOF

  chmod 0644 "$ENV_PROFILE_FILE"
}

set_permissions() {
  if [[ "$(id -u)" -eq 0 && "$CREATE_USER" == "1" ]]; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT" 2>/dev/null || true
  fi
  chmod -R u=rwX,go=rX "$PROJECT_ROOT" 2>/dev/null || true
  chmod -R 0775 "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/logs" 2>/dev/null || true
}

# ------------------------------
# Main logic
# ------------------------------
main() {
  log "Starting project environment setup..."
  setup_os_basics
  ensure_directories
  ensure_user
  detect_stack

  # Proactively ensure Maven/JDK available for CI pipelines
  ensure_maven_jdk
  create_mvn_wrapper
  ensure_app_pom

  # Install runtimes as detected
  [[ $IS_NODE -eq 1 ]] && install_node
  [[ $IS_PYTHON -eq 1 ]] && install_python
  [[ $IS_RUBY -eq 1 ]] && install_ruby
  [[ $IS_GO -eq 1 ]] && install_go
  [[ $IS_JAVA -eq 1 ]] && install_java
  [[ $IS_RUST -eq 1 ]] && install_rust
  [[ $IS_PHP -eq 1 ]] && install_php
  [[ $IS_DOTNET -eq 1 ]] && install_dotnet

  # Install dependencies for each stack
  [[ $IS_NODE -eq 1 ]] && install_deps_node
  [[ $IS_PYTHON -eq 1 ]] && install_deps_python
  [[ $IS_RUBY -eq 1 ]] && install_deps_ruby
  [[ $IS_GO -eq 1 ]] && install_deps_go
  [[ $IS_JAVA -eq 1 ]] && install_deps_java
  [[ $IS_RUST -eq 1 ]] && install_deps_rust
  [[ $IS_PHP -eq 1 ]] && install_deps_php

  write_env_profile
  set_permissions
  pm_clean

  # Mark setup complete
  {
    echo "timestamp=$(date -Is)"
    echo "user=${APP_USER}"
    echo "project_root=${PROJECT_ROOT}"
    echo "stacks=node:${IS_NODE},python:${IS_PYTHON},ruby:${IS_RUBY},go:${IS_GO},java:${IS_JAVA},rust:${IS_RUST},php:${IS_PHP},dotnet:${IS_DOTNET}"
  } > "$SETUP_MARKER" || true

  log "Environment setup completed successfully."
  cat <<'EONOTE'
Notes:
- Environment profile installed at /etc/profile.d/10-app-env.sh
  Use: source /etc/profile.d/10-app-env.sh
- If a non-root user was created, consider running processes as that user:
  su - appuser -c "cd ${PROJECT_ROOT} && bash -lc 'your_start_command'"
- Default PORT=3000 (override with environment variable).
EONOTE
}

main "$@"