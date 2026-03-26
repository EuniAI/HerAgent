#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects common project types (Python, Node.js, Ruby, Go, Rust, Java, PHP, .NET)
# Installs runtimes and dependencies, configures environment, and prepares app directories.
#
# Usage: ./setup.sh
# Optional environment variables:
#   APP_ROOT=/app             Path to project root (defaults to current directory)
#   APP_USER=appuser          Non-root user to create/use (only if running as root)
#   APP_ENV=production        Application environment
#   PYTHON_VERSION=3          Preferred Python major version (e.g., 3, 3.11)
#   NODE_VERSION=16           Fallback Node.js major or "lts/*" if no .nvmrc/.node-version
#   GO_VERSION=1.22.5         Go toolchain version if not available via package manager
#   RUST_TOOLCHAIN=stable     Rust toolchain channel (stable/beta/nightly or x.y)
#   DOTNET_SDK_VERSION=       Dotnet SDK version (falls back to global.json or latest LTS)
#   JAVA_VERSION=11           Preferred Java version (8, 11, 17)
#   PHP_VERSION=8.2           Preferred PHP major.minor
#
# This script is idempotent and safe to run multiple times.

set -Euo pipefail
IFS=$'\n\t'
umask 027

# Colors (disable if not a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR] $*${NC}" >&2; }
info()   { echo "${BLUE}$*${NC}"; }

on_error() {
  local exit_code=$?
  error "Setup failed at line ${BASH_LINENO[0]} in ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  return 0
}
trap - ERR

# Defaults
APP_ROOT="${APP_ROOT:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
PYTHON_VERSION="${PYTHON_VERSION:-3}"
NODE_VERSION="${NODE_VERSION:-lts/*}"
GO_VERSION="${GO_VERSION:-1.22.5}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
JAVA_VERSION="${JAVA_VERSION:-11}"
PHP_VERSION="${PHP_VERSION:-8.2}"
APP_USER="${APP_USER:-}"

# Global variables
PKG_MANAGER=""
UPDATE_DONE_FILE="/var/lib/.pkg_update_done"
PROFILE_D_DIR="/etc/profile.d"

require_root_for_system_changes() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Running as non-root. System-wide package installation and user creation will be skipped if required."
    return 1
  fi
  return 0
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"; return 0; fi
  if command -v apk >/dev/null 2>&1; then PKG_MANAGER="apk"; return 0; fi
  if command -v dnf >/dev/null 2>&1; then PKG_MANAGER="dnf"; return 0; fi
  if command -v yum >/dev/null 2>&1; then PKG_MANAGER="yum"; return 0; fi
  if command -v microdnf >/dev/null 2>&1; then PKG_MANAGER="microdnf"; return 0; fi
  if command -v zypper >/dev/null 2>&1; then PKG_MANAGER="zypper"; return 0; fi
  warn "No supported package manager detected. Proceeding with language-specific installers only."
  PKG_MANAGER=""
  return 1
}

pkg_update() {
  require_root_for_system_changes || return 0
  if [ -n "$PKG_MANAGER" ] && [ ! -f "$UPDATE_DONE_FILE" ]; then
    log "Updating package repositories (${PKG_MANAGER})..."
    case "$PKG_MANAGER" in
      apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        ;;
      apk)
        apk update || true
        ;;
      dnf)
        dnf -y makecache
        ;;
      yum)
        yum -y makecache
        ;;
      microdnf)
        microdnf -y makecache || true
        ;;
      zypper)
        zypper -n refresh
        ;;
    esac
    touch "$UPDATE_DONE_FILE" || true
  fi
}

install_packages() {
  # accepts packages as arguments; handles each pkg manager
  require_root_for_system_changes || { warn "Skipping system package installation (not root)"; return 0; }
  [ -z "${1:-}" ] && return 0
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y --no-install-recommends "$@" && rm -rf /var/lib/apt/lists/* ;;
    apk)
      apk add --no-cache "$@" ;;
    dnf)
      dnf -y install "$@" && dnf clean all ;;
    yum)
      yum -y install "$@" && yum clean all ;;
    microdnf)
      microdnf -y install "$@" || true ;;
    zypper)
      zypper -n install --no-recommends "$@" ;;
    *)
      warn "Package manager not available to install: $*"
      ;;
  esac
}

install_base_tools() {
  log "Installing base system tools and build dependencies..."
  case "$PKG_MANAGER" in
    apt)
      install_packages ca-certificates curl wget git openssh-client gnupg dirmngr tar gzip unzip xz-utils \
        build-essential pkg-config make gcc g++ python3-minimal grep sed
      update-ca-certificates || true
      ;;
    apk)
      install_packages ca-certificates curl wget git openssh-client gnupg tar gzip unzip xz build-base \
        bash coreutils findutils libc6-compat
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      install_packages ca-certificates curl wget git openssh-clients gnupg2 tar gzip unzip xz \
        gcc gcc-c++ make pkgconfig which python3
      update-ca-trust || true
      ;;
    zypper)
      install_packages ca-certificates curl wget git openssh gnupg tar gzip unzip xz \
        gcc gcc-c++ make pkg-config which python3
      ;;
    *)
      warn "Skipping base system tools installation (no package manager found)."
      ;;
  esac
}

create_app_user_and_permissions() {
  require_root_for_system_changes || return 0
  mkdir -p "$APP_ROOT"
  if [ -n "$APP_USER" ]; then
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      log "Creating application user: $APP_USER"
      case "$PKG_MANAGER" in
        apk)
          addgroup -S "$APP_USER" || true
          adduser -S -G "$APP_USER" "$APP_USER" || true
          ;;
        *)
          useradd -m -U -s /bin/bash "$APP_USER" || true
          ;;
      esac
    else
      log "User $APP_USER already exists"
    fi
    chown -R "$APP_USER":"$APP_USER" "$APP_ROOT" || true
  fi
  # Common project dirs
  mkdir -p "$APP_ROOT"/{logs,tmp,cache}
  chmod -R 775 "$APP_ROOT"/{logs,tmp,cache} || true
}

persist_env_var() {
  # persist environment variables for all shells (if root)
  local key="$1" val="$2"
  if require_root_for_system_changes; then
    mkdir -p "$PROFILE_D_DIR" || true
    chmod 755 "$PROFILE_D_DIR" || true
    local f="$PROFILE_D_DIR/99-app-env.sh"
    [ -f "$f" ] || install -m 0644 /dev/null "$f" || { touch "$f" && chmod 0644 "$f"; } || true
    if [ -w "$f" ]; then
      if ! grep -q "^export $key=" "$f" 2>/dev/null; then
        echo "export $key=\"$val\"" >> "$f" || true
      else
        # replace existing
        sed -i "s|^export $key=.*$|export $key=\"$val\"|g" "$f" || true
      fi
    else
      warn "Cannot write to $f; skipping persistence for $key"
    fi
  fi
  export "$key"="$val" || true
}

load_env_file() {
  local env_file="$APP_ROOT/.env"
  if [ -f "$env_file" ]; then
    log "Loading environment variables from .env"
    # shellcheck disable=SC2162
    while IFS= read -r line || [ -n "$line" ]; do
      # ignore comments and empty lines
      if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then continue; fi
      if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        key="${line%%=*}"
        val="${line#*=}"
        persist_env_var "$key" "$val" || true
      fi
    done < "$env_file"
  fi
}

detect_project_types() {
  PROJECT_TYPES=()
  [ -f "$APP_ROOT/requirements.txt" ] || [ -f "$APP_ROOT/pyproject.toml" ] || [ -f "$APP_ROOT/Pipfile" ] && PROJECT_TYPES+=("python")
  [ -f "$APP_ROOT/package.json" ] && PROJECT_TYPES+=("node")
  [ -f "$APP_ROOT/Gemfile" ] && PROJECT_TYPES+=("ruby")
  [ -f "$APP_ROOT/go.mod" ] && PROJECT_TYPES+=("go")
  [ -f "$APP_ROOT/Cargo.toml" ] && PROJECT_TYPES+=("rust")
  [ -f "$APP_ROOT/pom.xml" ] || ls "$APP_ROOT"/*.gradle >/dev/null 2>&1 && PROJECT_TYPES+=("java")
  [ -f "$APP_ROOT/composer.json" ] && PROJECT_TYPES+=("php")
  ls "$APP_ROOT"/*.sln >/dev/null 2>&1 || ls "$APP_ROOT"/*.csproj >/dev/null 2>&1 && PROJECT_TYPES+=("dotnet")
}

install_python_stack() {
  log "Configuring Python environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-venv" "python3-venv" python3-pip python3-dev \
        libffi-dev libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev
      ;;
    apk)
      install_packages python3 py3-pip python3-dev musl-dev libffi-dev openssl-dev zlib-dev bzip2-dev readline-dev sqlite-dev
      ;;
    dnf|yum|microdnf)
      install_packages python3 python3-pip python3-devel libffi-devel openssl-devel zlib-devel bzip2 bzip2-devel readline-devel sqlite-devel
      ;;
    zypper)
      install_packages python3 python3-pip python3-devel libffi-devel libopenssl-devel zlib-devel libbz2-devel readline-devel sqlite3-devel
      ;;
    *)
      warn "Python system packages not installed (no package manager). Proceeding with existing python if available."
      ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    error "python3 not found. Install a base image with Python or use a distro with package manager."
    return
  fi

  PYTHON_BIN="python3"
  VENV_DIR="$APP_ROOT/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtual environment at $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  else
    log "Python virtual environment already exists at $VENV_DIR"
  fi

  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip setuptools wheel

  if [ -f "$APP_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    PIP_NO_CACHE_DIR=1 pip install -r "$APP_ROOT/requirements.txt"
  elif [ -f "$APP_ROOT/pyproject.toml" ]; then
    if grep -qi "\[tool.poetry\]" "$APP_ROOT/pyproject.toml"; then
      log "Detected Poetry project"
      pip install "poetry>=1.6"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi --no-root
    else
      log "Installing pyproject.toml dependencies via pip if a requirements backend is available"
      pip install .
    fi
  elif [ -f "$APP_ROOT/Pipfile" ]; then
    log "Detected Pipenv project"
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
  else
    log "No Python dependency file found; skipping package install."
  fi

  persist_env_var "PYTHONDONTWRITEBYTECODE" "1" || true
  persist_env_var "PYTHONUNBUFFERED" "1" || true
  persist_env_var "PATH" "$VENV_DIR/bin:\$PATH" || true
}

install_nvm_and_node() {
  # NVM installation in a container-friendly way
  if [ -z "${NVM_DIR:-}" ]; then
    export NVM_DIR="${NVM_DIR:-/usr/local/nvm}"
  fi
  if [ ! -d "$NVM_DIR" ]; then
    log "Installing NVM to $NVM_DIR"
    mkdir -p "$NVM_DIR"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash -s -- --no-use
  fi
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
  persist_env_var "NVM_DIR" "$NVM_DIR" || true
  persist_env_var "PATH" "$NVM_DIR/versions/node/$(ls -1 "$NVM_DIR/versions/node" 2>/dev/null | tail -n1)/bin:\$PATH" || true

  local desired="$NODE_VERSION"
  if [ -f "$APP_ROOT/.nvmrc" ]; then
    desired="$(cat "$APP_ROOT/.nvmrc")"
  elif [ -f "$APP_ROOT/.node-version" ]; then
    desired="$(cat "$APP_ROOT/.node-version")"
  else
    # Try package.json engines.node
    if [ -f "$APP_ROOT/package.json" ]; then
      local eng
      eng=$(awk '/"engines"[[:space:]]*:/,/\}/{print}' "$APP_ROOT/package.json" | awk -F: '/"node"[[:space:]]*:/ {gsub(/[",]/,"",$2); print $2}' | head -n1 || true)
      [ -n "$eng" ] && desired="$eng"
    fi
  fi

  log "Installing Node.js version: $desired (via nvm)"
  # Some engine specs like ">=16" aren't valid to nvm; fallback to lts if install fails
  if ! nvm install "$desired"; then
    warn "Could not install Node.js $desired; falling back to LTS"
    nvm install --lts
  fi
  nvm use --silent "$desired" || nvm use --silent --lts
  local node_bin
  node_bin="$(command -v node || true)"
  if [ -z "$node_bin" ]; then error "Node installation failed"; return 1; fi

  # Persist PATH for non-login shells
  if require_root_for_system_changes; then
    echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1' > "$PROFILE_D_DIR/99-nvm.sh"
    chmod +x "$PROFILE_D_DIR/99-nvm.sh" || true
  fi
}

install_node_stack() {
  log "Configuring Node.js environment..."
  # Ensure base tools for build and node-gyp
  case "$PKG_MANAGER" in
    apt) install_packages python3 make g++ ;;
    apk) install_packages python3 make g++ ;;
    dnf|yum|microdnf) install_packages python3 make gcc-c++ ;;
    zypper) install_packages python3 make gcc-c++ ;;
  esac

  if ! command -v node >/dev/null 2>&1; then
    install_nvm_and_node
  fi

  # Detect package manager
  local pm="npm"
  if [ -f "$APP_ROOT/pnpm-lock.yaml" ]; then pm="pnpm"
  elif [ -f "$APP_ROOT/yarn.lock" ]; then pm="yarn"
  elif [ -f "$APP_ROOT/package-lock.json" ]; then pm="npm"
  fi

  pushd "$APP_ROOT" >/dev/null
  if [ ! -f package.json ]; then
    warn "package.json not found; skipping Node dependency installation."
    popd >/dev/null
    return
  fi

  export NODE_ENV="${NODE_ENV:-production}"
  persist_env_var "NODE_ENV" "$NODE_ENV"
  persist_env_var "NPM_CONFIG_LOGLEVEL" "warn"

  case "$pm" in
    pnpm)
      if ! command -v pnpm >/dev/null 2>&1; then npm i -g pnpm@8 >/dev/null 2>&1 || npx -y pnpm@8 -v >/dev/null; fi
      if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile; else pnpm install; fi
      ;;
    yarn)
      if ! command -v yarn >/dev/null 2>&1; then npm i -g yarn >/dev/null 2>&1 || npx -y yarn -v >/dev/null; fi
      if [ -f yarn.lock ]; then yarn install --frozen-lockfile; else yarn install; fi
      ;;
    npm|*)
      if [ -f package-lock.json ]; then npm ci; else npm install --no-audit --no-fund; fi
      ;;
  esac

  popd >/dev/null
}

install_ruby_stack() {
  log "Configuring Ruby environment..."
  case "$PKG_MANAGER" in
    apt) install_packages ruby-full ruby-dev build-essential ;;
    apk) install_packages ruby ruby-dev build-base ;;
    dnf|yum|microdnf) install_packages ruby ruby-devel gcc gcc-c++ make ;;
    zypper) install_packages ruby ruby-devel gcc gcc-c++ make ;;
    *) warn "No package manager; Ruby install skipped."; return ;;
  esac

  if ! command -v gem >/dev/null 2>&1; then error "Ruby not available after installation"; return; fi
  gem install --no-document bundler || true

  pushd "$APP_ROOT" >/dev/null
  if [ -f Gemfile ]; then
    BUNDLE_PATH="$APP_ROOT/vendor/bundle" bundle config set path "$APP_ROOT/vendor/bundle"
    bundle install --jobs=4 --retry=3
  else
    warn "Gemfile not found; skipping bundle install."
  fi
  popd >/dev/null
}

install_go_stack() {
  log "Configuring Go environment..."
  if ! command -v go >/dev/null 2>&1; then
    case "$PKG_MANAGER" in
      apt|dnf|yum|microdnf|zypper)
        install_packages golang || true
        ;;
      apk)
        install_packages go || true
        ;;
    esac
  fi

  if ! command -v go >/dev/null 2>&1; then
    warn "Go not available via package manager; installing from tarball $GO_VERSION"
    local arch
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      armv7l) arch="armv6l" ;;
      *) warn "Unsupported arch $arch for Go; attempting amd64"; arch="amd64" ;;
    esac
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" -o /tmp/go.tgz
    require_root_for_system_changes && rm -rf /usr/local/go
    require_root_for_system_changes && tar -C /usr/local -xzf /tmp/go.tgz || {
      mkdir -p "$HOME/.local"; tar -C "$HOME/.local" -xzf /tmp/go.tgz; mv "$HOME/.local/go" "$HOME/.local/go-${GO_VERSION}" || true; ln -snf "$HOME/.local/go-${GO_VERSION}" "$HOME/.local/go"
      persist_env_var "PATH" "\$HOME/.local/go/bin:\$PATH"
    }
    rm -f /tmp/go.tgz
    persist_env_var "PATH" "/usr/local/go/bin:\$PATH"
  fi

  pushd "$APP_ROOT" >/dev/null
  if [ -f go.mod ]; then
    go env -w GOMODCACHE="$APP_ROOT/.gocache" || true
    go mod download
  else
    warn "go.mod not found; skipping go mod download."
  fi
  popd >/dev/null
}

install_rust_stack() {
  log "Configuring Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
    chmod +x /tmp/rustup-init.sh
    /tmp/rustup-init.sh -y --no-modify-path --default-toolchain "$RUST_TOOLCHAIN"
    rm -f /tmp/rustup-init.sh
    persist_env_var "PATH" "\$HOME/.cargo/bin:\$PATH"
  fi

  pushd "$APP_ROOT" >/dev/null
  if [ -f Cargo.toml ]; then
    "$HOME/.cargo/bin/cargo" fetch || cargo fetch
  else
    warn "Cargo.toml not found; skipping cargo fetch."
  fi
  popd >/dev/null
}

install_java_stack() {
  log "Configuring Java environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages "openjdk-${JAVA_VERSION}-jdk" maven gradle || install_packages "default-jdk" maven gradle
      ;;
    apk)
      install_packages "openjdk${JAVA_VERSION//./}-jdk" maven gradle || install_packages openjdk11-jdk maven gradle
      ;;
    dnf|yum|microdnf)
      install_packages "java-${JAVA_VERSION}-openjdk-devel" maven gradle || install_packages "java-11-openjdk-devel" maven gradle
      ;;
    zypper)
      install_packages "java-${JAVA_VERSION}-openjdk-devel" maven gradle || install_packages "java-11-openjdk-devel" maven gradle
      ;;
    *)
      warn "No package manager; Java install skipped."
      ;;
  esac

  pushd "$APP_ROOT" >/dev/null
  if [ -f pom.xml ]; then
    mvn -B -q -DskipTests dependency:go-offline || warn "Maven offline prepare failed"
  fi
  if ls ./*.gradle >/dev/null 2>&1 || [ -d gradle ]; then
    gradle -q --no-daemon tasks >/dev/null 2>&1 || true
  fi
  popd >/dev/null
}

install_php_stack() {
  log "Configuring PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages "php${PHP_VERSION}" "php${PHP_VERSION}-cli" php-cli php-json php-mbstring php-xml php-curl php-zip php-openssl php-intl || install_packages php-cli php-json php-mbstring php-xml php-curl php-zip
      ;;
    apk)
      install_packages "php82" "php82-cli" php82-openssl php82-json php82-mbstring php82-xml php82-curl php82-zip || install_packages php php-cli php-openssl php-json php-mbstring php-xml php-curl php-zip
      ;;
    dnf|yum|microdnf)
      install_packages php php-cli php-json php-mbstring php-xml php-curl php-zip
      ;;
    zypper)
      install_packages php8 php8-cli php8-json php8-mbstring php8-xml php8-curl php8-zip || install_packages php php-cli php-json php-mbstring php-xml php-curl php-zip
      ;;
    *)
      warn "No package manager; PHP install skipped."
      ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
    rm -f /tmp/composer-setup.php
  fi

  pushd "$APP_ROOT" >/dev/null
  if [ -f composer.json ]; then
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress --no-suggest
  else
    warn "composer.json not found; skipping composer install."
  fi
  popd >/dev/null
}

install_dotnet_stack() {
  log "Configuring .NET environment..."
  if ! command -v dotnet >/dev/null 2>&1; then
    log "Installing dotnet SDK via Microsoft dotnet-install script..."
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    local version_arg=""
    if [ -n "${DOTNET_SDK_VERSION:-}" ]; then
      version_arg="--version $DOTNET_SDK_VERSION"
    elif [ -f "$APP_ROOT/global.json" ]; then
      version_arg="--jsonfile $APP_ROOT/global.json"
    else
      version_arg="--channel LTS"
    fi
    /tmp/dotnet-install.sh $version_arg --install-dir /usr/local/dotnet
    rm -f /tmp/dotnet-install.sh
    persist_env_var "PATH" "/usr/local/dotnet:\$PATH"
  fi

  pushd "$APP_ROOT" >/dev/null
  if ls ./*.sln >/dev/null 2>&1 || ls ./*.csproj >/dev/null 2>&1; then
    dotnet restore || warn "dotnet restore failed"
  else
    warn "No .sln or .csproj found; skipping dotnet restore."
  fi
  popd >/dev/null
}

configure_env_defaults() {
  log "Configuring default environment variables..."
  persist_env_var "APP_ROOT" "$APP_ROOT" || true
  persist_env_var "APP_ENV" "$APP_ENV" || true
  # Prevent core dumps and keep processes in foreground
  persist_env_var "MALLOC_ARENA_MAX" "2" || true
}

prepare_runtime_specific_config() {
  # Additional runtime-specific setup (ports, run hints) can be placed here
  :
}

ensure_makefile() {
  # Ensure make is available; install minimally if missing
  if ! command -v make >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -y && sudo apt-get install -y make || warn "Failed to install make via apt-get"
      else
        if require_root_for_system_changes; then
          apt-get update -y && apt-get install -y make || warn "Failed to install make via apt-get"
        else
          warn "Skipping make install (not root and no sudo)"
        fi
      fi
    elif command -v dnf >/dev/null 2>&1; then
      if command -v sudo >/dev/null 2>&1; then
        sudo dnf install -y make || warn "Failed to install make via dnf"
      else
        if require_root_for_system_changes; then
          dnf install -y make || warn "Failed to install make via dnf"
        else
          warn "Skipping make install (not root and no sudo)"
        fi
      fi
    elif command -v yum >/dev/null 2>&1; then
      if command -v sudo >/dev/null 2>&1; then
        sudo yum install -y make || warn "Failed to install make via yum"
      else
        if require_root_for_system_changes; then
          yum install -y make || warn "Failed to install make via yum"
        else
          warn "Skipping make install (not root and no sudo)"
        fi
      fi
    elif command -v apk >/dev/null 2>&1; then
      if command -v sudo >/dev/null 2>&1; then
        sudo apk add --no-cache make || warn "Failed to install make via apk"
      else
        if require_root_for_system_changes; then
          apk add --no-cache make || warn "Failed to install make via apk"
        else
          warn "Skipping make install (not root and no sudo)"
        fi
      fi
    elif command -v zypper >/dev/null 2>&1; then
      if command -v sudo >/dev/null 2>&1; then
        sudo zypper install -y make || warn "Failed to install make via zypper"
      else
        if require_root_for_system_changes; then
          zypper install -y make || warn "Failed to install make via zypper"
        else
          warn "Skipping make install (not root and no sudo)"
        fi
      fi
    else
      warn "No supported package manager found to install make"
    fi
  fi

  if [ ! -f "$APP_ROOT/Makefile" ]; then
    log "No Makefile found; creating a minimal one."
    printf '%b\n' 'all: build' '' 'build:' '\t./build.sh' > "$APP_ROOT/Makefile"
  elif ! grep -q "^build:" "$APP_ROOT/Makefile"; then
    printf "\nbuild:\n\t./build.sh\n" >> "$APP_ROOT/Makefile"
  fi
}

setup_ci_build_script() {
  mkdir -p "$APP_ROOT/.ci"
  cat > "$APP_ROOT/.ci/build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1 && [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile && pnpm -s build
  elif command -v yarn >/dev/null 2>&1 && [ -f yarn.lock ]; then yarn install --frozen-lockfile && yarn -s build
  else npm ci && npm run -s build
  fi
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f build.gradle ] || [ -f settings.gradle ] || [ -x ./gradlew ]; then
  if [ -x ./gradlew ]; then ./gradlew build -x test
  else gradle build -x test
  fi
elif [ -f Cargo.toml ]; then
  cargo build
elif [ -f go.mod ]; then
  go build ./...
elif ls *.sln >/dev/null 2>&1 || ls *.csproj >/dev/null 2>&1; then
  dotnet restore && dotnet build -clp:ErrorsOnly
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip && pip install -e .
elif [ -f setup.py ]; then
  python -m pip install -U pip && pip install -e .
elif [ -f Makefile ]; then
  make build || make
else
  echo No recognized build configuration found
  exit 1
fi
EOF
  chmod +x "$APP_ROOT/.ci/build.sh" || true
  cat > "$APP_ROOT/build.sh" <<'EOF'
#!/usr/bin/env bash
exec bash .ci/build.sh
EOF
  chmod +x "$APP_ROOT/build.sh" || true
  echo "Repository build entrypoints created. Use: bash .ci/build.sh  (preferred) or: make build"
}

setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_line=". \"$APP_ROOT/.venv/bin/activate\""
  if [ -f "$APP_ROOT/.venv/bin/activate" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

setup_profiled_venv_activation() {
  require_root_for_system_changes || return 0
  mkdir -p "$PROFILE_D_DIR" || true
  chmod 755 "$PROFILE_D_DIR" || true
  printf '# Auto-activate project Python venv if present\nif [ -f "/app/.venv/bin/activate" ]; then\n  . "/app/.venv/bin/activate"\nfi\n' > "$PROFILE_D_DIR/99-python-venv.sh" || true
  chmod 644 "$PROFILE_D_DIR/99-python-venv.sh" || true
}

prepare_env_persistence_prereqs() {
  require_root_for_system_changes || return 0
  # Ensure essential tools and prepare /etc/profile.d and target env file
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y --no-install-recommends coreutils grep sed && rm -rf /var/lib/apt/lists/* || true
  fi
  mkdir -p /etc/profile.d && chmod 755 /etc/profile.d || true
  sh -c 'test -f /etc/profile.d/99-app-env.sh || install -m 0644 /dev/null /etc/profile.d/99-app-env.sh || { touch /etc/profile.d/99-app-env.sh && chmod 0644 /etc/profile.d/99-app-env.sh; }' || true
  chown root:root /etc/profile.d/99-app-env.sh && chmod 0644 /etc/profile.d/99-app-env.sh || true
}

main() {
  log "Starting universal project environment setup"
  log "Project root: $APP_ROOT"

  detect_pkg_manager
  install_base_tools
  prepare_env_persistence_prereqs
  create_app_user_and_permissions
  configure_env_defaults || true
  load_env_file

  setup_profiled_venv_activation
  setup_auto_activate
  setup_ci_build_script

  detect_project_types

  if [ "${#PROJECT_TYPES[@]}" -eq 0 ]; then
    warn "Could not detect project type. Scanning for common markers..."
    # Continue attempting common stacks based on presence of files
  else
    info "Detected project types: ${PROJECT_TYPES[*]}"
  fi

  # Install stacks based on detection
  if [ -f "$APP_ROOT/requirements.txt" ] || [ -f "$APP_ROOT/pyproject.toml" ] || [ -f "$APP_ROOT/Pipfile" ]; then
    install_python_stack
  fi

  if [ -f "$APP_ROOT/package.json" ]; then
    install_node_stack
  fi

  if [ -f "$APP_ROOT/Gemfile" ]; then
    install_ruby_stack
  fi

  if [ -f "$APP_ROOT/go.mod" ]; then
    install_go_stack
  fi

  if [ -f "$APP_ROOT/Cargo.toml" ]; then
    install_rust_stack
  fi

  if [ -f "$APP_ROOT/pom.xml" ] || ls "$APP_ROOT"/*.gradle >/dev/null 2>&1; then
    install_java_stack
  fi

  if [ -f "$APP_ROOT/composer.json" ]; then
    install_php_stack
  fi

  if ls "$APP_ROOT"/*.sln >/dev/null 2>&1 || ls "$APP_ROOT"/*.csproj >/dev/null 2>&1; then
    install_dotnet_stack
  fi

  prepare_runtime_specific_config

  ensure_makefile

  # Final ownership if APP_USER set and running as root
  if [ -n "$APP_USER" ] && [ "$(id -u)" -eq 0 ]; then
    chown -R "$APP_USER":"$APP_USER" "$APP_ROOT" || true
  fi

  log "Environment setup completed successfully."
  echo
  echo "Hints:"
  if [ -f "$APP_ROOT/.venv/bin/activate" ]; then
    echo " - Activate Python venv: source \"$APP_ROOT/.venv/bin/activate\""
  fi
  if [ -d "${NVM_DIR:-/usr/local/nvm}" ]; then
    echo " - Load Node environment in shell: . \"${NVM_DIR:-/usr/local/nvm}/nvm.sh\""
  fi
  echo " - Environment variables persisted in: $PROFILE_D_DIR (if root)"
  echo " - Project directories prepared in: $APP_ROOT"
}

# Safe override of persist_env_var to avoid fatal exits
persist_env_var() {
  local key="$1" val="$2"
  # Export to current shell with expansion (so PATH updates like "$VENV_DIR/bin:$PATH" work)
  eval "export $key=\"$val\"" || true
  if [ -w "/etc/profile.d" ]; then
    { printf 'export %s="%s"\n' "$key" "$val" >> /etc/profile.d/99-app-env.sh; } || true
  else
    { touch "$HOME/.bashrc" && printf 'export %s="%s"\n' "$key" "$val" >> "$HOME/.bashrc"; } || true
  fi
  return 0
}

main "$@"