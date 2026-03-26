#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type(s) and installs appropriate runtimes and dependencies
# - Installs required system packages
# - Sets up directory structure, permissions, and environment variables
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output (fallback to plain if no TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

trap 'error "An unexpected error occurred on line $LINENO"; exit 1' ERR

# Configuration
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-root}"     # In Docker often root; can be changed if needed
ENV_FILE="${ENV_FILE:-.env}"
APT_UPDATED_FLAG="/var/lib/apt/lists/.setup_script_apt_updated"
NVM_DIR="/usr/local/nvm"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# Detect package manager
PKG_MGR=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""
PKG_CLEAN_CMD=""

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    export DEBIAN_FRONTEND=noninteractive
    PKG_UPDATE_CMD="apt-get update -y"
    PKG_INSTALL_CMD="apt-get install -y --no-install-recommends"
    PKG_CLEAN_CMD="apt-get clean && rm -rf /var/lib/apt/lists/*"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PKG_UPDATE_CMD="apk update"
    PKG_INSTALL_CMD="apk add --no-cache"
    PKG_CLEAN_CMD="true"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
    PKG_UPDATE_CMD="microdnf -y update"
    PKG_INSTALL_CMD="microdnf -y install"
    PKG_CLEAN_CMD="microdnf clean all"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_UPDATE_CMD="dnf -y makecache"
    PKG_INSTALL_CMD="dnf -y install"
    PKG_CLEAN_CMD="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_UPDATE_CMD="yum -y makecache"
    PKG_INSTALL_CMD="yum -y install"
    PKG_CLEAN_CMD="yum clean all"
  else
    die "No supported package manager found (apt, apk, microdnf, dnf, yum)."
  fi
  log "Using package manager: $PKG_MGR"
}

pkg_update_once() {
  case "$PKG_MGR" in
    apt)
      if [ ! -f "$APT_UPDATED_FLAG" ]; then
        log "Updating apt package index..."
        eval "$PKG_UPDATE_CMD"
        touch "$APT_UPDATED_FLAG"
      else
        log "Apt package index already up-to-date (cached)."
      fi
      ;;
    apk|microdnf|dnf|yum)
      log "Refreshing package manager metadata..."
      eval "$PKG_UPDATE_CMD"
      ;;
  esac
}

pkg_install() {
  if [ $# -eq 0 ]; then return 0; fi
  pkg_update_once
  log "Installing system packages: $*"
  case "$PKG_MGR" in
    apt) apt-get install -y --no-install-recommends "$@" ;;
    apk) apk add --no-cache "$@" ;;
    microdnf|dnf|yum) $PKG_MGR -y install "$@" ;;
  esac
}

pkg_clean() {
  log "Cleaning package manager caches..."
  eval "$PKG_CLEAN_CMD" || true
}

ensure_core_tools() {
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git bash build-essential pkg-config xz-utils unzip
      ;;
    apk)
      pkg_install ca-certificates curl git bash build-base pkgconf xz unzip
      ;;
    microdnf|dnf|yum)
      pkg_install ca-certificates curl git bash make automake gcc gcc-c++ kernel-headers pkgconf xz unzip
      ;;
  esac
  update-ca-certificates 2>/dev/null || true
}

setup_directories() {
  log "Setting up application directory at $APP_DIR"
  mkdir -p "$APP_DIR"
  chmod 755 "$APP_DIR"
  chown -R "$APP_USER":"$APP_USER" "$APP_DIR" 2>/dev/null || true
}

# Environment file helpers
ensure_env_file() {
  cd "$APP_DIR"
  if [ ! -f "$ENV_FILE" ]; then
    log "Creating default environment file: $ENV_FILE"
    cat > "$ENV_FILE" <<'EOF'
# Environment configuration
NODE_ENV=production
PYTHONUNBUFFERED=1
PIP_DISABLE_PIP_VERSION_CHECK=1
PIP_NO_CACHE_DIR=1
BUNDLE_WITHOUT=development:test
APP_ENV=production
APP_DEBUG=false
PORT=0
EOF
    chmod 640 "$ENV_FILE" || true
  else
    log "Environment file exists: $ENV_FILE"
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
  set +a
}

# Language/runtime installers and setup

setup_auto_activate() {
  # Ensure future interactive shells auto-activate the Python virtual environment
  local bashrc_file="/root/.bashrc"
  local venv_path="${VENV_DIR:-$APP_DIR/.venv}/bin/activate"
  local activate_line=". \"$venv_path\""
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

install_python_stack() {
  cd "$APP_DIR"
  if [ ! -f requirements.txt ] && [ ! -f pyproject.toml ] && [ ! -f Pipfile ]; then
    return 0
  fi
  log "Detected Python project"
  case "$PKG_MGR" in
    apt) pkg_install python3 python3-pip python3-venv python3-dev gcc libffi-dev; ;;
    apk) pkg_install python3 py3-pip python3-dev musl-dev gcc libffi-dev; ;;
    microdnf|dnf|yum) pkg_install python3 python3-pip python3-devel gcc libffi-devel; ;;
  esac

  PYTHON_BIN="$(command -v python3 || true)"
  [ -n "$PYTHON_BIN" ] || die "python3 not found after installation."

  VENV_DIR="${VENV_DIR:-$APP_DIR/.venv}"
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating Python virtual environment at $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  else
    log "Python virtual environment already exists at $VENV_DIR"
  fi
  # shellcheck disable=SC1090
  . "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [ -f requirements.txt ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r requirements.txt
  elif [ -f pyproject.toml ]; then
    if grep -qi "\[tool.poetry\]" pyproject.toml 2>/dev/null; then
      log "Poetry project detected"
      pip install "poetry>=1.6"
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi
    else
      log "PEP 517/518 project detected; installing via pip"
      pip install .
    fi
  elif [ -f Pipfile ]; then
    log "Pipenv project detected"
    pip install "pipenv>=2023.0"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
  fi

  # Export typical Python env
  echo "PYTHONUNBUFFERED=1" >> "$ENV_FILE" 2>/dev/null || true
  deactivate || true
  setup_auto_activate
}

install_node_stack() {
  cd "$APP_DIR"
  if [ ! -f package.json ]; then
    return 0
  fi
  log "Detected Node.js project"

  # Preferred: use nvm for versioning if .nvmrc or engines specified
  REQUIRED_NODE=""
  if [ -f .nvmrc ]; then
    REQUIRED_NODE="$(tr -d ' \t\r\n' < .nvmrc || true)"
  else
    # Try to read engines.node from package.json
    REQUIRED_NODE="$(grep -oE '"node"[[:space:]]*:[[:space:]]*"[^\"]+"' package.json 2>/dev/null | cut -d'"' -f4 || true)"
  fi

  install_nvm_if_needed

  if [ -n "$REQUIRED_NODE" ]; then
    log "Installing Node.js version specified ($REQUIRED_NODE) via nvm"
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    nvm install "$REQUIRED_NODE"
    nvm use "$REQUIRED_NODE"
  else
    if ! command -v node >/dev/null 2>&1; then
      log "No Node.js found; installing LTS via nvm"
      # shellcheck disable=SC1090
      . "$NVM_DIR/nvm.sh"
      nvm install --lts
      nvm use --lts
    else
      log "Node.js already installed: $(node -v)"
    fi
  fi

  export NODE_OPTIONS="${NODE_OPTIONS:-}"
  export npm_config_loglevel="${npm_config_loglevel:-info}"
  export npm_config_fund="false"
  export npm_config_audit="false"

  if [ -f package-lock.json ]; then
    log "Installing Node.js dependencies (npm ci)"
    npm ci --no-optional || npm ci
  elif [ -f yarn.lock ]; then
    ensure_yarn
    log "Installing Node.js dependencies (yarn install --frozen-lockfile)"
    yarn install --frozen-lockfile || yarn install
  else
    log "Installing Node.js dependencies (npm install)"
    npm install
  fi

  # Append to ENV file
  {
    echo "NODE_ENV=${NODE_ENV:-production}"
    echo "PORT=${PORT:-3000}"
  } >> "$ENV_FILE" 2>/dev/null || true
}

install_nvm_if_needed() {
  if [ -d "$NVM_DIR" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
    log "nvm already installed at $NVM_DIR"
    return 0
  fi
  log "Installing nvm to $NVM_DIR"
  mkdir -p "$NVM_DIR"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | NVM_DIR="$NVM_DIR" bash
  # Ensure system-wide availability for subsequent shells
  if [ -d /etc/profile.d ]; then
    cat > /etc/profile.d/nvm.sh <<EOF
export NVM_DIR="$NVM_DIR"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
EOF
    chmod 644 /etc/profile.d/nvm.sh
  fi
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
}

ensure_yarn() {
  if command -v yarn >/dev/null 2>&1; then
    return
  fi
  log "Installing Yarn"
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
    corepack prepare yarn@stable --activate || true
  else
    npm install -g yarn
  fi
}

install_ruby_stack() {
  cd "$APP_DIR"
  if [ ! -f Gemfile ]; then
    return 0
  fi
  log "Detected Ruby project"
  case "$PKG_MGR" in
    apt) pkg_install ruby-full ruby-bundler build-essential libffi-dev; ;;
    apk) pkg_install ruby ruby-bundler build-base libffi-dev; ;;
    microdnf|dnf|yum) pkg_install ruby ruby-devel @development-tools libffi-devel; ;;
  esac

  if ! command -v bundle >/dev/null 2>&1 && command -v gem >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  export BUNDLE_PATH="${BUNDLE_PATH:-vendor/bundle}"
  export BUNDLE_WITHOUT="${BUNDLE_WITHOUT:-development:test}"
  bundle config set path "$BUNDLE_PATH"
  bundle install --jobs "$(nproc)" --retry 3
  echo "PORT=${PORT:-3000}" >> "$ENV_FILE" 2>/dev/null || true
}

install_go_stack() {
  cd "$APP_DIR"
  if [ ! -f go.mod ]; then
    return 0
  fi
  log "Detected Go project"
  case "$PKG_MGR" in
    apt) pkg_install golang; ;;
    apk) pkg_install go; ;;
    microdnf|dnf|yum) pkg_install golang; ;;
  esac
  export GOPATH="${GOPATH:-$APP_DIR/.gopath}"
  export GOCACHE="${GOCACHE:-$APP_DIR/.gocache}"
  mkdir -p "$GOPATH" "$GOCACHE"
  go env -w GOPATH="$GOPATH" GOCACHE="$GOCACHE" >/dev/null 2>&1 || true
  log "Downloading Go modules"
  go mod download
  echo "PORT=${PORT:-8080}" >> "$ENV_FILE" 2>/dev/null || true
}

install_java_stack() {
  cd "$APP_DIR"
  if [ ! -f pom.xml ] && [ ! -f build.gradle ] && [ ! -f settings.gradle ] && [ ! -f gradlew ]; then
    return 0
  fi
  log "Detected Java project"
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk; ;;
    apk) pkg_install openjdk17-jdk; ;;
    microdnf|dnf|yum) pkg_install java-17-openjdk-devel; ;;
  esac

  if [ -f pom.xml ]; then
    case "$PKG_MGR" in
      apt) pkg_install maven; ;;
      apk) pkg_install maven; ;;
      microdnf|dnf|yum) pkg_install maven; ;;
    esac
    log "Preparing Maven dependencies offline"
    mvn -B -ntp -q dependency:go-offline || warn "Maven offline prep failed"
  fi

  if [ -f gradlew ]; then
    log "Using Gradle Wrapper"
    chmod +x gradlew
    ./gradlew --no-daemon --quiet tasks >/dev/null 2>&1 || true
  elif [ -f build.gradle ] || [ -f settings.gradle ]; then
    case "$PKG_MGR" in
      apt) pkg_install gradle; ;;
      apk) pkg_install gradle; ;;
      microdnf|dnf|yum) pkg_install gradle; ;;
    esac
    gradle --version >/dev/null 2>&1 || warn "Gradle not available"
  fi
  echo "PORT=${PORT:-8080}" >> "$ENV_FILE" 2>/dev/null || true
}

install_php_stack() {
  cd "$APP_DIR"
  if [ ! -f composer.json ]; then
    return 0
  fi
  log "Detected PHP project"
  case "$PKG_MGR" in
    apt) pkg_install php-cli php-mbstring php-xml php-zip unzip; ;;
    apk) pkg_install php81 php81-cli php81-mbstring php81-xml php81-zip unzip || pkg_install php php-cli php-mbstring php-xml php-zip unzip; ;;
    microdnf|dnf|yum) pkg_install php-cli php-mbstring php-xml php-zip unzip; ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    curl -fsSL https://getcomposer.org/installer -o composer-setup.php
    ACTUAL_SIGNATURE="$(php -r 'echo hash_file("SHA384", "composer-setup.php");')"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      die "Invalid composer installer signature"
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi

  if [ -f composer.lock ]; then
    composer install --no-interaction --prefer-dist
  else
    composer install --no-interaction
  fi
  echo "PORT=${PORT:-8080}" >> "$ENV_FILE" 2>/dev/null || true
}

install_rust_stack() {
  cd "$APP_DIR"
  if [ ! -f Cargo.toml ]; then
    return 0
  fi
  log "Detected Rust project"
  if ! command -v cargo >/dev/null 2>&1; then
    pkg_install curl ca-certificates
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal
    rm -f /tmp/rustup.sh
    export CARGO_HOME="${CARGO_HOME:-/root/.cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-/root/.rustup}"
    export PATH="$CARGO_HOME/bin:$PATH"
    if [ -d /etc/profile.d ]; then
      cat > /etc/profile.d/rust.sh <<'EOF'
export CARGO_HOME="${CARGO_HOME:-/root/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-/root/.rustup}"
export PATH="$CARGO_HOME/bin:$PATH"
EOF
      chmod 644 /etc/profile.d/rust.sh
    fi
  else
    log "Rust already installed: $(rustc --version 2>/dev/null || echo 'unknown')"
  fi
  cargo fetch || warn "Cargo fetch failed"
}

install_dotnet_stack() {
  cd "$APP_DIR"
  if ! ls *.sln 1>/dev/null 2>&1 && ! ls *.csproj 1>/dev/null 2>&1 && [ ! -f global.json ]; then
    return 0
  fi
  log "Detected .NET project"
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK already installed: $(dotnet --version)"
    dotnet restore || true
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      log "Installing .NET SDK (attempting 8.0) for Debian/Ubuntu"
      pkg_update_once
      pkg_install wget gpg
      wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/microsoft.gpg
      DIST_ID="$(. /etc/os-release && echo "${ID}")"
      DIST_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"
      echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/repos/microsoft-${DIST_ID}-${DIST_CODENAME}-prod ${DIST_CODENAME} main" > /etc/apt/sources.list.d/microsoft-prod.list || true
      rm -f "$APT_UPDATED_FLAG" || true
      pkg_install apt-transport-https
      pkg_install dotnet-sdk-8.0 || warn "Failed to install dotnet-sdk-8.0"
      ;;
    microdnf|dnf|yum)
      pkg_install dotnet-sdk-8.0 || warn "Failed to install dotnet-sdk-8.0"
      ;;
    apk)
      warn ".NET install on Alpine is non-trivial; please use a dotnet Alpine image. Skipping automatic install."
      ;;
  esac
  if command -v dotnet >/dev/null 2>&1; then
    dotnet --info || true
    dotnet restore || true
  else
    warn ".NET SDK not available after installation attempt."
  fi
}

# Port inference
infer_port() {
  cd "$APP_DIR"
  local port="${PORT:-0}"

  if [ "$port" != "0" ] && [ -n "$port" ]; then
    echo "$port"
    return 0
  fi

  if [ -f package.json ]; then
    port=3000
  fi
  if [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f Pipfile ]; then
    # Attempt to infer Flask/Django heuristically
    if ls | grep -Ei 'manage\.py' >/dev/null 2>&1; then
      port=8000
    else
      port="${port:-5000}"
    fi
  fi
  if [ -f pom.xml ] || [ -f build.gradle ] || [ -f gradlew ]; then
    port="${port:-8080}"
  fi
  if [ -f go.mod ]; then
    port="${port:-8080}"
  fi
  if [ -f Gemfile ]; then
    port="${port:-3000}"
  fi
  if [ -f composer.json ]; then
    port="${port:-8080}"
  fi

  echo "${port:-0}"
}

# Main
main() {
  log "Starting environment setup"
  detect_pkg_mgr
  setup_directories
  ensure_core_tools
  ensure_env_file

  # Install stacks based on detection
  install_python_stack
  install_node_stack
  install_ruby_stack
  install_go_stack
  install_java_stack
  install_php_stack
  install_rust_stack
  install_dotnet_stack

  # Set final PORT in env file if not set
  FINAL_PORT="$(infer_port)"
  if [ "$FINAL_PORT" != "0" ]; then
    if ! grep -qE '^PORT=' "$ENV_FILE"; then
      echo "PORT=$FINAL_PORT" >> "$ENV_FILE"
    else
      # Update existing PORT entry to inferred if it was 0
      sed -i "s/^PORT=.*/PORT=$FINAL_PORT/" "$ENV_FILE" || true
    fi
    log "Using application port: $FINAL_PORT"
  else
    warn "Could not infer application port; set PORT in $ENV_FILE if needed."
  fi

  # Final ownership adjustment
  chown -R "$APP_USER":"$APP_USER" "$APP_DIR" 2>/dev/null || true

  pkg_clean

  log "Environment setup completed successfully."
  log "Directory: $APP_DIR"
  log "Env file: $APP_DIR/$ENV_FILE"
  log "Note: This script is idempotent; you can re-run it safely."
}

# Switch to APP_DIR if exists inside container context
if [ -d "$APP_DIR" ]; then
  cd "$APP_DIR"
fi

main "$@"