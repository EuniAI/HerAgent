#!/bin/sh
# Early bootstrap to restore a working /bin/bash and re-exec this script under bash.
# This allows the script to run even if /bin/bash is broken or missing.
if [ -z "${BASH_VERSION:-}" ]; then
  /bin/sh -lc 'set -eux; if [ -x /bin/bash.real ]; then install -m 0755 /bin/bash.real /bin/bash || cp -f /bin/bash.real /bin/bash || true; fi; set +e; /bin/bash --version >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ] && command -v busybox >/dev/null 2>&1; then ln -sf "$(command -v busybox)" /bin/bash || true; fi'
  /bin/sh -lc 'set -eux; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y || true; (apt-get install -y --reinstall --no-install-recommends bash || apt-get install -y --no-install-recommends bash) || true; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || cp -f "$real" /bin/bash || true; cp -a "$real" /bin/bash.real || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then apt-get install -y --reinstall libc6 || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then apt-get install -y --no-install-recommends bash-static || true; if [ -x /bin/bash-static ]; then install -m 0755 /bin/bash-static /bin/bash; fi; fi; elif command -v apk >/dev/null 2>&1; then apk add --no-cache --upgrade bash || apk add --no-cache bash; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then apk add --no-cache musl || true; fi; elif command -v dnf >/dev/null 2>&1; then dnf -y install bash || dnf -y reinstall bash; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then dnf -y install glibc || dnf -y reinstall glibc || true; fi; elif command -v yum >/dev/null 2>&1; then yum -y install bash || yum -y reinstall bash; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then yum -y install glibc || yum -y reinstall glibc || true; fi; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install -y bash || zypper --non-interactive in -y bash; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then zypper --non-interactive install -y glibc || true; fi; else echo "No supported package manager found" >&2; fi'
  /bin/sh -lc 'set -eux; /bin/bash --version || true; /bin/bash -lc "echo Bash_OK"'
  exec /bin/bash "$0" "$@"
fi
# Universal project environment setup script for Docker containers
# Detects common project types and installs required runtimes, system packages,
# dependencies, and environment configuration in an idempotent way.

set -Eeuo pipefail
IFS=$'\n\t'
[ "${DEBUG:-0}" = "1" ] && set -x

# -------------------------
# Logging and error handling
# -------------------------
TS() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[INFO  $(TS)] $*"; }
warn() { echo "[WARN  $(TS)] $*" >&2; }
err() { echo "[ERROR $(TS)] $*" >&2; }
die() { err "$*"; exit 1; }

cleanup() { :; }
on_error() {
  local exit_code=$?
  err "Setup failed (exit code $exit_code) at line ${BASH_LINENO[0]} in ${BASH_SOURCE[1]:-main}"
  exit "$exit_code"
}
trap cleanup EXIT
trap on_error ERR

# -------------------------
# Defaults and configuration
# -------------------------
APP_DIR="${APP_DIR:-/app}"
PROFILE_D_DIR="${PROFILE_D_DIR:-/etc/profile.d}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

# Ports defaults
DEFAULT_PORT_NODE=3000
DEFAULT_PORT_PY=5000
DEFAULT_PORT_PHP=8000
DEFAULT_PORT_RUBY=9292
DEFAULT_PORT_GO=8080
DEFAULT_PORT_JAVA=8080
DEFAULT_PORT_DOTNET=8080
DEFAULT_PORT_RUST=8080

# Ensure we are in the project directory if running inside it
if [ -d ".git" ] || [ -f "package.json" ] || [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "go.mod" ] || [ -f "pom.xml" ] || [ -f "build.gradle" ] || [ -f "Gemfile" ] || [ -f "composer.json" ] || [ -f "Cargo.toml" ] || ls ./*.csproj >/dev/null 2>&1; then
  # The current working directory appears to be the project directory
  HOST_PROJECT_DIR="$(pwd)"
else
  HOST_PROJECT_DIR=""
fi

# -------------------------
# Utility helpers
# -------------------------
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
require_root() { is_root || die "This script must run as root in a container (no sudo available)."; }

file_contains() { grep -qE "$2" "$1" 2>/dev/null; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Package manager detection
PKG_MGR=""
detect_pkg_mgr() {
  if has_cmd apt-get; then PKG_MGR="apt";
  elif has_cmd apk; then PKG_MGR="apk";
  elif has_cmd dnf; then PKG_MGR="dnf";
  elif has_cmd yum; then PKG_MGR="yum";
  elif has_cmd zypper; then PKG_MGR="zypper";
  else PKG_MGR="unknown";
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      mkdir -p /var/lib/setup-state
      if [ ! -f /var/lib/setup-state/apt-updated ]; then
        log "Updating apt package index..."
        apt-get update -y
        touch /var/lib/setup-state/apt-updated
      fi
      ;;
    apk)
      log "Updating apk package index..."
      apk update
      ;;
    dnf)
      log "Updating dnf package index..."
      dnf -y makecache
      ;;
    yum)
      log "Updating yum package index..."
      yum -y makecache
      ;;
    zypper)
      log "Refreshing zypper repositories..."
      zypper --non-interactive refresh
      ;;
    *)
      warn "Unknown package manager. Skipping system package updates."
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  [ "$#" -gt 0 ] || return 0
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
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
    *)
      warn "Unknown package manager. Cannot install: $*"
      ;;
  esac
}

ensure_dirs() {
  mkdir -p "$APP_DIR" "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/data"
  chmod 775 "$APP_DIR" "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/data" || true
}

write_profile_line() {
  local line="$1"
  local target="${PROFILE_D_DIR}/project_env.sh"
  mkdir -p "$PROFILE_D_DIR"
  touch "$target"
  if ! grep -Fq "$line" "$target" 2>/dev/null; then
    echo "$line" >> "$target"
  fi
}

# Auto-activate Python virtual environment when entering the container
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_activate="$APP_DIR/.venv/bin/activate"
  if [ -f "$venv_activate" ]; then
    local activate_line="source $venv_activate"
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

# -------------------------
# Safe bash wrapper to avoid non-interactive startup pollution
# -------------------------
ensure_safe_bash_wrapper() {
  # Repair strategy: restore a working /bin/bash and ensure /bin/bash.real exists.
  # Do NOT overwrite /bin/bash with a shim. Use /bin/sh to avoid relying on bash during repair.
  /bin/sh -lc 'set -eux; if [ -x /bin/bash.real ]; then install -m 0755 /bin/bash.real /bin/bash || cp -f /bin/bash.real /bin/bash || true; fi; set +e; /bin/bash --version >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ] && command -v busybox >/dev/null 2>&1; then ln -sf "$(command -v busybox)" /bin/bash || true; fi'
  /bin/sh -lc 'set -eux; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y || true; (apt-get install -y --reinstall --no-install-recommends bash || apt-get install -y --no-install-recommends bash) || true; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || cp -f "$real" /bin/bash || true; cp -a "$real" /bin/bash.real || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then apt-get install -y --reinstall libc6 || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then apt-get install -y --no-install-recommends bash-static || true; if [ -x /bin/bash-static ]; then install -m 0755 /bin/bash-static /bin/bash; fi; fi; elif command -v apk >/dev/null 2>&1; then apk add --no-cache --upgrade bash || apk add --no-cache bash; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then apk add --no-cache musl || true; fi; elif command -v dnf >/dev/null 2>&1; then dnf -y install bash || dnf -y reinstall bash; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then dnf -y install glibc || dnf -y reinstall glibc || true; fi; elif command -v yum >/dev/null 2>&1; then yum -y install bash || yum -y reinstall bash; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then yum -y install glibc || yum -y reinstall glibc || true; fi; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install -y bash || zypper --non-interactive in -y bash; real="$(command -v bash || true)"; if [ -n "$real" ] && [ -x "$real" ]; then install -m 0755 "$real" /bin/bash || true; fi; set +e; /bin/bash -lc true >/dev/null 2>&1; ok=$?; set -e; if [ "$ok" -ne 0 ]; then zypper --non-interactive install -y glibc || true; fi; else echo "No supported package manager found" >&2; fi'
  /bin/sh -lc 'set -eux; /bin/bash --version || true; /bin/bash -lc "echo Bash_OK"'
}

# -------------------------
# System base packages
# -------------------------
install_base_packages() {
  detect_pkg_mgr
  if [ "$PKG_MGR" = "unknown" ]; then
    warn "Cannot detect package manager. Skipping base package installation."
    return
  fi

  pkg_update

  case "$PKG_MGR" in
    apt)
      # Avoid tzdata interactive
      export DEBIAN_FRONTEND=noninteractive
      pkg_install ca-certificates curl wget git unzip tar xz-utils gnupg lsb-release pkg-config
      # Build tools
      pkg_install build-essential make gcc g++ openssl libssl-dev
      # Optional utils
      pkg_install locales netbase
      ;;
    apk)
      pkg_install ca-certificates curl wget git unzip tar xz build-base bash coreutils openssl-dev
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git unzip tar xz gcc gcc-c++ make openssl-devel which
      ;;
    zypper)
      pkg_install ca-certificates curl wget git unzip tar xz gcc gcc-c++ make libopenssl-devel which
      ;;
  esac

  update-ca-certificates >/dev/null 2>&1 || true
}

# -------------------------
# Language/runtime installers
# -------------------------

# Python
setup_python() {
  if ! [ -f "$APP_DIR/requirements.txt" ] && ! [ -f "$APP_DIR/pyproject.toml" ] && ! [ -f "$APP_DIR/setup.py" ] && ! [ -f "$APP_DIR/Pipfile" ]; then
    return
  fi

  log "Configuring Python environment..."
  case "$PKG_MGR" in
    apt) pkg_install python3 python3-venv python3-pip python3-dev ;;
    apk) pkg_install python3 py3-pip python3-dev ;;
    dnf|yum) pkg_install python3 python3-pip python3-devel ;;
    zypper) pkg_install python3 python3-pip python3-devel ;;
  esac

  # Create venv inside project
  PY_VENV="${APP_DIR}/.venv"
  if [ ! -f "$PY_VENV/bin/activate" ]; then
    log "Creating Python virtual environment at $PY_VENV"
    python3 -m venv "$PY_VENV"
  else
    log "Reusing existing Python virtual environment at $PY_VENV"
  fi

  # Upgrade pip/setuptools/wheel and install deps
  "$PY_VENV/bin/pip" install --no-cache-dir --upgrade pip setuptools wheel >/dev/null
  if [ -f "$APP_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    "$PY_VENV/bin/pip" install --no-cache-dir -r "$APP_DIR/requirements.txt"
  elif [ -f "$APP_DIR/pyproject.toml" ]; then
    if file_contains "$APP_DIR/pyproject.toml" "build-system"; then
      log "Installing Python project with PEP 517/518 (pyproject.toml)"
      "$PY_VENV/bin/pip" install --no-cache-dir "$APP_DIR"
    fi
  elif [ -f "$APP_DIR/Pipfile" ]; then
    # Pipenv not guaranteed; fall back to pip installing requirements if present
    warn "Pipfile detected. Consider generating requirements.txt for deterministic installs."
  fi

  # Persist environment
  write_profile_line "export VIRTUAL_ENV='$PY_VENV'"
  write_profile_line "export PATH=\"\$VIRTUAL_ENV/bin:\$PATH\""
  [ -f "$ENV_FILE" ] || {
    echo "PYTHONUNBUFFERED=1" > "$ENV_FILE"
    echo "PORT=${PORT:-$DEFAULT_PORT_PY}" >> "$ENV_FILE"
  }
}

# Node.js (nvm + npm/yarn/pnpm)
setup_node() {
  if ! [ -f "$APP_DIR/package.json" ]; then
    return
  fi

  log "Configuring Node.js environment..."
  # Install dependencies for native modules
  case "$PKG_MGR" in
    apt) pkg_install python3 make g++ ;;
    apk) pkg_install python3 make g++ ;;
    dnf|yum) pkg_install python3 make gcc-c++ ;;
    zypper) pkg_install python3 make gcc-c++ ;;
  esac

  # Install NVM
  NVM_DIR="/usr/local/nvm"
  if [ ! -d "$NVM_DIR" ]; then
    log "Installing NVM to $NVM_DIR"
    mkdir -p "$NVM_DIR"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | NVM_DIR="$NVM_DIR" bash
  else
    log "NVM already installed at $NVM_DIR"
  fi

  # Load NVM for this shell
  export NVM_DIR="$NVM_DIR"
  # shellcheck disable=SC1090
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

  NODE_VERSION="lts/*"
  if [ -f "$APP_DIR/.nvmrc" ]; then
    NODE_VERSION="$(cat "$APP_DIR/.nvmrc" | tr -d '[:space:]')"
  else
    # Try to read engines.node from package.json
    if has_cmd jq; then
      if jq -e '.engines.node' "$APP_DIR/package.json" >/dev/null 2>&1; then
        NODE_VERSION="$(jq -r '.engines.node' "$APP_DIR/package.json")"
      fi
    fi
  fi

  if ! nvm ls "$NODE_VERSION" >/dev/null 2>&1; then
    log "Installing Node.js version: $NODE_VERSION"
    nvm install "$NODE_VERSION"
  fi
  nvm use "$NODE_VERSION" >/dev/null
  CURRENT_NODE="$(nvm current)"
  log "Using Node.js: $CURRENT_NODE"

  # Ensure Node is in global PATH for future shells
  # Resolve installed version path
  NODE_PREFIX="$(nvm which current | xargs dirname | xargs dirname || true)"
  [ -n "$NODE_PREFIX" ] && write_profile_line "export PATH=\"$NODE_PREFIX/bin:\$PATH\""

  # Package manager detection via lockfiles
  pushd "$APP_DIR" >/dev/null
  export NODE_ENV="${NODE_ENV:-production}"

  if [ -f "pnpm-lock.yaml" ]; then
    log "pnpm lockfile detected. Enabling corepack and installing dependencies."
    corepack enable >/dev/null 2>&1 || npm i -g corepack >/dev/null 2>&1 || true
    corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
    pnpm install --frozen-lockfile
  elif [ -f "yarn.lock" ]; then
    log "yarn lockfile detected. Enabling corepack and installing dependencies."
    corepack enable >/dev/null 2>&1 || npm i -g corepack >/dev/null 2>&1 || true
    corepack prepare yarn@stable --activate >/dev/null 2>&1 || true
    yarn install --frozen-lockfile || yarn install
  else
    if [ -f "package-lock.json" ]; then
      log "Installing Node dependencies with npm ci"
      npm ci
    else
      log "Installing Node dependencies with npm install"
      npm install
    fi
  fi

  popd >/dev/null

  [ -f "$ENV_FILE" ] || {
    echo "NODE_ENV=${NODE_ENV:-production}" > "$ENV_FILE"
    echo "PORT=${PORT:-$DEFAULT_PORT_NODE}" >> "$ENV_FILE"
  }
}

# Ruby
setup_ruby() {
  if ! [ -f "$APP_DIR/Gemfile" ]; then
    return
  fi

  log "Configuring Ruby environment..."
  case "$PKG_MGR" in
    apt) pkg_install ruby-full build-essential ;;
    apk) pkg_install ruby ruby-dev build-base ;;
    dnf|yum) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
    zypper) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
  esac

  if ! has_cmd bundler; then
    gem install bundler --no-document
  fi

  pushd "$APP_DIR" >/dev/null
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs "$(nproc)" --retry 3
  popd >/dev/null

  [ -f "$ENV_FILE" ] || {
    echo "RACK_ENV=${RACK_ENV:-production}" > "$ENV_FILE"
    echo "PORT=${PORT:-$DEFAULT_PORT_RUBY}" >> "$ENV_FILE"
  }
}

# Go
setup_go() {
  if ! [ -f "$APP_DIR/go.mod" ]; then
    return
  fi

  log "Configuring Go environment..."
  case "$PKG_MGR" in
    apt) pkg_install golang-go ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac

  if ! has_cmd go; then
    warn "Go installation via system package manager failed. Skipping Go setup."
    return
  fi

  GOPATH_DEFAULT="/go"
  mkdir -p "$GOPATH_DEFAULT"
  write_profile_line "export GOPATH='$GOPATH_DEFAULT'"
  write_profile_line "export PATH=\"\$GOPATH/bin:\$PATH\""

  pushd "$APP_DIR" >/dev/null
  go mod download
  popd >/dev/null

  [ -f "$ENV_FILE" ] || {
    echo "PORT=${PORT:-$DEFAULT_PORT_GO}" > "$ENV_FILE"
  }
}

# Java (Maven/Gradle)
setup_java() {
  local has_mvn="0" has_gradle="0"
  [ -f "$APP_DIR/pom.xml" ] && has_mvn="1"
  { [ -f "$APP_DIR/build.gradle" ] || [ -f "$APP_DIR/build.gradle.kts" ]; } && has_gradle="1"

  if [ "$has_mvn" = "0" ] && [ "$has_gradle" = "0" ]; then
    return
  fi

  log "Configuring Java environment..."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven gradle ;;
    apk) pkg_install openjdk17-jdk maven gradle ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven gradle ;;
    zypper) pkg_install java-17-openjdk-devel maven gradle ;;
  esac

  if has_cmd javac; then
    JAVA_HOME_CAND="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
    write_profile_line "export JAVA_HOME='$JAVA_HOME_CAND'"
    write_profile_line "export PATH=\"\$JAVA_HOME/bin:\$PATH\""
  fi

  if [ "$has_mvn" = "1" ] && has_cmd mvn; then
    pushd "$APP_DIR" >/dev/null
    mvn -q -e -DskipTests dependency:go-offline || mvn -q -DskipTests package || true
    popd >/dev/null
  fi
  if [ "$has_gradle" = "1" ] && has_cmd gradle; then
    pushd "$APP_DIR" >/dev/null
    gradle --no-daemon build -x test || gradle --no-daemon tasks || true
    popd >/dev/null
  fi

  [ -f "$ENV_FILE" ] || {
    echo "PORT=${PORT:-$DEFAULT_PORT_JAVA}" > "$ENV_FILE"
  }
}

# .NET
setup_dotnet() {
  shopt -s nullglob
  local csproj_files=("$APP_DIR"/*.csproj)
  shopt -u nullglob
  [ "${#csproj_files[@]}" -eq 0 ] && [ ! -f "$APP_DIR/global.json" ] && return

  log "Configuring .NET SDK..."
  DOTNET_ROOT="/usr/local/dotnet"
  DOTNET_INSTALL_SCRIPT="/tmp/dotnet-install.sh"
  mkdir -p "$DOTNET_ROOT"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$DOTNET_INSTALL_SCRIPT"
  chmod +x "$DOTNET_INSTALL_SCRIPT"

  # Determine channel/version
  local channel="LTS"
  if [ -f "$APP_DIR/global.json" ] && has_cmd jq; then
    ver="$(jq -r '.sdk.version // empty' "$APP_DIR/global.json" || true)"
    if [ -n "$ver" ]; then
      "$DOTNET_INSTALL_SCRIPT" --version "$ver" --install-dir "$DOTNET_ROOT"
    else
      "$DOTNET_INSTALL_SCRIPT" --channel "$channel" --install-dir "$DOTNET_ROOT"
    fi
  else
    "$DOTNET_INSTALL_SCRIPT" --channel "$channel" --install-dir "$DOTNET_ROOT"
  fi

  write_profile_line "export DOTNET_ROOT='$DOTNET_ROOT'"
  write_profile_line "export PATH=\"\$DOTNET_ROOT:\$DOTNET_ROOT/tools:\$PATH\""

  if [ "${#csproj_files[@]}" -gt 0 ]; then
    pushd "$APP_DIR" >/dev/null
    "$DOTNET_ROOT/dotnet" restore || true
    popd >/dev/null
  fi

  [ -f "$ENV_FILE" ] || {
    echo "PORT=${PORT:-$DEFAULT_PORT_DOTNET}" > "$ENV_FILE"
  }
}

# PHP
setup_php() {
  if ! [ -f "$APP_DIR/composer.json" ]; then
    return
  fi

  log "Configuring PHP environment..."
  case "$PKG_MGR" in
    apt) pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip git ;;
    apk) pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip unzip git ;;
    dnf|yum) pkg_install php-cli php-mbstring php-xml php-common unzip git ;;
    zypper) pkg_install php8 php8-mbstring php8-xml php8-curl php8-zip unzip git ;;
  esac

  # Install Composer
  if ! has_cmd composer; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      die "Invalid Composer installer signature"
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer >/dev/null
    rm -f composer-setup.php
  fi

  pushd "$APP_DIR" >/dev/null
  if [ -f "composer.lock" ]; then
    composer install --no-interaction --prefer-dist --no-progress
  else
    composer update --no-interaction --prefer-dist --no-progress || true
  fi
  popd >/dev/null

  [ -f "$ENV_FILE" ] || {
    echo "PORT=${PORT:-$DEFAULT_PORT_PHP}" > "$ENV_FILE"
  }
}

# Rust
setup_rust() {
  if ! [ -f "$APP_DIR/Cargo.toml" ]; then
    return
  fi

  log "Configuring Rust toolchain..."
  if ! has_cmd cargo; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
    chmod +x /tmp/rustup-init.sh
    /tmp/rustup-init.sh -y --default-toolchain stable --no-modify-path
    rm -f /tmp/rustup-init.sh
  fi

  # rustup installs to /root/.cargo in root container; expose via PATH
  write_profile_line "export CARGO_HOME=\"/root/.cargo\""
  write_profile_line "export RUSTUP_HOME=\"/root/.rustup\""
  write_profile_line "export PATH=\"/root/.cargo/bin:\$PATH\""

  if has_cmd cargo; then
    pushd "$APP_DIR" >/dev/null
    cargo fetch || true
    popd >/dev/null
  fi

  [ -f "$ENV_FILE" ] || {
    echo "PORT=${PORT:-$DEFAULT_PORT_RUST}" > "$ENV_FILE"
  }
}

# -------------------------
# Project detection and orchestration
# -------------------------
detect_project_types() {
  TYPES=()
  [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ] || [ -f "$APP_DIR/setup.py" ] || [ -f "$APP_DIR/Pipfile" ] && TYPES+=("python")
  [ -f "$APP_DIR/package.json" ] && TYPES+=("node")
  [ -f "$APP_DIR/Gemfile" ] && TYPES+=("ruby")
  [ -f "$APP_DIR/go.mod" ] && TYPES+=("go")
  [ -f "$APP_DIR/pom.xml" ] || [ -f "$APP_DIR/build.gradle" ] || [ -f "$APP_DIR/build.gradle.kts" ] && TYPES+=("java")
  shopt -s nullglob; local csproj=("$APP_DIR"/*.csproj); shopt -u nullglob
  [ -f "$APP_DIR/global.json" ] || [ "${#csproj[@]}" -gt 0 ] && TYPES+=("dotnet")
  [ -f "$APP_DIR/composer.json" ] && TYPES+=("php")
  [ -f "$APP_DIR/Cargo.toml" ] && TYPES+=("rust")
  echo "${TYPES[*]-}"
}

copy_into_app_dir_if_needed() {
  # If running inside project dir, set APP_DIR to current dir to avoid copy.
  if [ -n "$HOST_PROJECT_DIR" ]; then
    APP_DIR="$HOST_PROJECT_DIR"
    return
  fi
  # Otherwise, ensure APP_DIR exists. We cannot copy source code here because the
  # script runs inside container; project should be mounted or copied by Dockerfile.
  mkdir -p "$APP_DIR"
}

# -------------------------
# Environment file handling
# -------------------------
ensure_env_file() {
  [ -f "$ENV_FILE" ] || {
    {
      echo "APP_DIR=$APP_DIR"
      echo "ENV=production"
      echo "PORT=${PORT:-8080}"
    } > "$ENV_FILE"
  }
}

persist_common_profile() {
  write_profile_line "export APP_DIR='$APP_DIR'"
  write_profile_line "export PATH=\"/usr/local/bin:/usr/bin:/bin:\$PATH\""
  write_profile_line "[ -f \"\$APP_DIR/.env\" ] && export \$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' \"\$APP_DIR/.env\" | xargs) >/dev/null 2>&1 || true"
}

# -------------------------
# Main
# -------------------------
main() {
  require_root

  log "Starting environment setup..."
  copy_into_app_dir_if_needed
  ensure_dirs
  ensure_safe_bash_wrapper
  install_base_packages
  ensure_env_file

  persist_common_profile

  PROJECT_TYPES="$(detect_project_types)"
  if [ -z "$PROJECT_TYPES" ]; then
    warn "No known project type detected in $APP_DIR."
    warn "This script supports: Python, Node.js, Ruby, Go, Java (Maven/Gradle), .NET, PHP, Rust."
    warn "Ensure your project files are present inside the container at $APP_DIR."
  else
    log "Detected project types: $PROJECT_TYPES"
  fi

  # Run setups conditionally
  setup_python
  setup_auto_activate
  setup_node
  setup_ruby
  setup_go
  setup_java
  setup_dotnet
  setup_php
  setup_rust

  # Set sensible permissions for writable dirs (logs/tmp/data)
  chmod -R g+rwX "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/data" || true

  log "Environment setup completed."
  echo "Summary:"
  echo "- Project directory: $APP_DIR"
  echo "- Environment file: $ENV_FILE"
  echo "- Profile config: ${PROFILE_D_DIR}/project_env.sh"
  echo "- Re-run safe: yes"

  echo
  echo "To use the environment in an interactive shell:"
  echo "  source ${PROFILE_D_DIR}/project_env.sh 2>/dev/null || true"
  echo "  [ -f \"$ENV_FILE\" ] && export \$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' \"$ENV_FILE\" | xargs)"

  echo
  echo "Note: This script prepares dependencies. Start commands vary by stack:"
  echo "- Python: source \"$APP_DIR/.venv/bin/activate\" && python your_app.py (default port $DEFAULT_PORT_PY)"
  echo "- Node: cd \"$APP_DIR\" && npm start (default port $DEFAULT_PORT_NODE)"
  echo "- Ruby: cd \"$APP_DIR\" && bundle exec rackup -p $DEFAULT_PORT_RUBY"
  echo "- Go: cd \"$APP_DIR\" && go run ./... (default port $DEFAULT_PORT_GO)"
  echo "- Java (Maven): cd \"$APP_DIR\" && mvn spring-boot:run (default port $DEFAULT_PORT_JAVA)"
  echo "- .NET: cd \"$APP_DIR\" && dotnet run (default port $DEFAULT_PORT_DOTNET)"
  echo "- PHP: cd \"$APP_DIR\" && php -S 0.0.0.0:$DEFAULT_PORT_PHP -t public"
  echo "- Rust: cd \"$APP_DIR\" && cargo run (default port $DEFAULT_PORT_RUST)"
}

main "$@"