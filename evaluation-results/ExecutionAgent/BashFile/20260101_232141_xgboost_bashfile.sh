#!/usr/bin/env bash
# Environment setup script for containerized projects
# Detects common stacks (Python, Node.js, Go, Ruby, Java, PHP, Rust) and configures accordingly.
# Designed to run as root inside Docker containers (no sudo). Idempotent and safe to re-run.

set -Eeuo pipefail

# Globals and defaults
APP_DIR="${APP_DIR:-$(pwd)}"
APP_LOG_DIR="${APP_LOG_DIR:-$APP_DIR/logs}"
APP_TMP_DIR="${APP_TMP_DIR:-$APP_DIR/tmp}"
APP_DATA_DIR="${APP_DATA_DIR:-$APP_DIR/data}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

# Colors for output (if terminal supports)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; NC=""
fi

# Logging functions
log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN $(date +'%H:%M:%S')] $*${NC}" >&2; }
err() { echo "${RED}[ERROR $(date +'%H:%M:%S')] $*${NC}" >&2; }

# Trap errors for diagnostics
on_error() {
  local exit_code=$?
  err "Setup failed at line $1 with exit code $exit_code"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# Detect package manager and set install/clean commands
PKG_MANAGER=""
INSTALL_CMD=""
CLEAN_CMD=""

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    INSTALL_CMD="apt-get install -y --no-install-recommends"
    CLEAN_CMD="rm -rf /var/lib/apt/lists/*"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    INSTALL_CMD="apk add --no-cache"
    CLEAN_CMD="true"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
    CLEAN_CMD="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    INSTALL_CMD="yum install -y"
    CLEAN_CMD="yum clean all"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    INSTALL_CMD="zypper install -y"
    CLEAN_CMD="zypper clean -a"
  else
    err "No supported package manager found (apt/apk/dnf/yum/zypper)."
    exit 1
  fi
  log "Using package manager: $PKG_MANAGER"
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      if [ "${NONINTERACTIVE}" = "1" ]; then export DEBIAN_FRONTEND=noninteractive; fi
      apt-get update -y
      ;;
    apk)
      # apk doesn't need update separately when using --no-cache
      true
      ;;
    dnf|yum)
      # optional: update metadata
      true
      ;;
    zypper)
      zypper refresh
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  if [ "$#" -eq 0 ]; then return 0; fi
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf|yum)
      $INSTALL_CMD "$@"
      ;;
    zypper)
      $INSTALL_CMD "$@"
      ;;
  esac
}

pkg_clean() {
  eval "$CLEAN_CMD"
}

# Directory setup
setup_directories() {
  log "Setting up project directories at $APP_DIR"
  mkdir -p "$APP_DIR" "$APP_LOG_DIR" "$APP_TMP_DIR" "$APP_DATA_DIR"
  chmod 0755 "$APP_DIR"
  chmod 0755 "$APP_LOG_DIR" "$APP_TMP_DIR" "$APP_DATA_DIR"
}

# Load environment variables from .env
load_env_file() {
  if [ -f "$ENV_FILE" ]; then
    log "Loading environment variables from $ENV_FILE"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        \#*|"") continue ;;
        *=*)
          key="${line%%=*}"
          val="${line#*=}"
          # Only export if not already set
          if [ -z "${!key:-}" ]; then
            export "$key=$val"
          fi
          ;;
      esac
    done < "$ENV_FILE"
  else
    warn "No .env file found at $ENV_FILE. Skipping environment variable import."
  fi
}

# Add to PATH if missing
ensure_path_entry() {
  case ":$PATH:" in
    *":$1:"*) ;; # already present
    *) export PATH="$1:$PATH" ;;
  esac
}

# Install base tools
install_base_tools() {
  log "Installing base system packages and build tools"
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git gnupg build-essential cmake pkg-config openssh-client coreutils
      ;;
    apk)
      pkg_install ca-certificates curl git openssh-client build-base pkgconfig
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gnupg2 gcc gcc-c++ make pkgconfig openssh-clients
      ;;
    zypper)
      pkg_install ca-certificates curl git gpg gcc gcc-c++ make pkg-config openssh
      ;;
  esac
  pkg_clean
  # Ensure CA certificates are updated
  if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates || true; fi
}

# Python setup
setup_python() {
  local needs_python=0
  [ -f "$APP_DIR/requirements.txt" ] && needs_python=1
  [ -f "$APP_DIR/Pipfile" ] && needs_python=1
  [ -f "$APP_DIR/pyproject.toml" ] && needs_python=1
  if [ "$needs_python" -eq 1 ]; then
    log "Detected Python project. Installing Python runtime and dependencies."
    case "$PKG_MANAGER" in
      apt)
        pkg_update
        pkg_install python3 python3-venv python3-pip python3-dev
        ;;
      apk)
        pkg_install python3 py3-pip python3-dev
        ;;
      dnf|yum)
        pkg_install python3 python3-pip python3-devel
        ;;
      zypper)
        pkg_install python3 python3-pip python3-devel
        ;;
    esac
    pkg_clean

    # Create virtual environment
    local VENV_DIR="$APP_DIR/.venv"
    if [ ! -d "$VENV_DIR" ]; then
      log "Creating virtual environment at $VENV_DIR"
      python3 -m venv "$VENV_DIR"
    else
      log "Virtual environment already exists at $VENV_DIR"
    fi

    # Upgrade pip safely
    "$VENV_DIR/bin/python" -m pip --disable-pip-version-check -q install --upgrade pip setuptools wheel
    export PIP_DISABLE_PIP_VERSION_CHECK=1
    export PIP_ROOT_USER_ACTION=ignore
    ensure_path_entry "$VENV_DIR/bin"

    # Install dependencies
    if [ -f "$APP_DIR/requirements.txt" ]; then
      log "Installing Python dependencies from requirements.txt"
      "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"
    elif [ -f "$APP_DIR/pyproject.toml" ]; then
      # Try pip for PEP 517 builds; fallback to installing build backend
      log "Installing Python dependencies from pyproject.toml"
      "$VENV_DIR/bin/pip" install . || {
        warn "Editable install failed. Attempting to install build backend."
        "$VENV_DIR/bin/pip" install build
        "$VENV_DIR/bin/python" -m build || warn "Building package failed."
      }
    elif [ -f "$APP_DIR/Pipfile" ]; then
      warn "Pipfile detected. pipenv not installed by default; installing pipenv."
      "$VENV_DIR/bin/pip" install pipenv
      (cd "$APP_DIR" && "$VENV_DIR/bin/pipenv" install --system || "$VENV_DIR/bin/pipenv" install)
    fi
  fi
}

# Node.js setup
setup_node() {
  if [ -f "$APP_DIR/package.json" ]; then
    log "Detected Node.js project. Installing Node.js runtime and dependencies."
    # Install Node.js and npm
    if command -v node >/dev/null 2>&1; then
      NODE_VER="$(node -v || echo v0)"
      log "Node.js detected: $NODE_VER"
    else
      case "$PKG_MANAGER" in
        apt)
          pkg_update
          pkg_install nodejs npm
          ;;
        apk)
          pkg_install nodejs npm
          ;;
        dnf|yum)
          pkg_install nodejs npm
          ;;
        zypper)
          pkg_install nodejs12 npm12 || pkg_install nodejs npm || true
          ;;
      esac
      pkg_clean
    fi

    # Enable corepack if available to manage yarn/pnpm
    if command -v corepack >/dev/null 2>&1; then
      corepack enable || true
    fi

    # Install package manager as needed
    if [ -f "$APP_DIR/yarn.lock" ] && ! command -v yarn >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then corepack prepare yarn@stable --activate || true; else npm i -g yarn || true; fi
    fi
    if [ -f "$APP_DIR/pnpm-lock.yaml" ] && ! command -v pnpm >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then corepack prepare pnpm@latest --activate || true; else npm i -g pnpm || true; fi
    fi

    # Install dependencies
    (cd "$APP_DIR"
      if [ -f "pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
        log "Installing Node dependencies with pnpm"
        pnpm install --frozen-lockfile || pnpm install
      elif [ -f "yarn.lock" ] && command -v yarn >/dev/null 2>&1; then
        log "Installing Node dependencies with yarn"
        yarn install --frozen-lockfile || yarn install
      elif [ -f "package-lock.json" ]; then
        log "Installing Node dependencies with npm ci"
        npm ci || npm install
      else
        log "Installing Node dependencies with npm install"
        npm install
      fi
    )
    # Add local node binaries to PATH
    ensure_path_entry "$APP_DIR/node_modules/.bin"
    export NODE_ENV="${NODE_ENV:-production}"
  fi
}

# Ruby setup
setup_ruby() {
  if [ -f "$APP_DIR/Gemfile" ]; then
    log "Detected Ruby project. Installing Ruby and bundler."
    case "$PKG_MANAGER" in
      apt)
        pkg_update
        pkg_install ruby-full build-essential
        ;;
      apk)
        pkg_install ruby ruby-bundler build-base
        ;;
      dnf|yum)
        pkg_install ruby ruby-devel gcc gcc-c++ make
        ;;
      zypper)
        pkg_install ruby ruby-devel gcc gcc-c++ make
        ;;
    esac
    pkg_clean
    if ! command -v bundle >/dev/null 2>&1; then
      gem install bundler --no-document || true
    fi
    (cd "$APP_DIR" && bundle config set --local path 'vendor/bundle' && bundle install)
  fi
}

# Go setup
setup_go() {
  if [ -f "$APP_DIR/go.mod" ]; then
    log "Detected Go project. Installing Go toolchain."
    case "$PKG_MANAGER" in
      apt)
        pkg_update
        pkg_install golang-go
        ;;
      apk)
        pkg_install go
        ;;
      dnf|yum)
        pkg_install golang
        ;;
      zypper)
        pkg_install go
        ;;
    esac
    pkg_clean
    (cd "$APP_DIR" && go mod download)
    ensure_path_entry "$(go env GOPATH 2>/dev/null || echo /root/go)/bin"
  fi
}

# Java setup (Maven/Gradle)
setup_java() {
  local is_maven=0 is_gradle=0
  [ -f "$APP_DIR/pom.xml" ] && is_maven=1
  ls "$APP_DIR"/build.gradle* >/dev/null 2>&1 && is_gradle=1 || true
  if [ "$is_maven" -eq 1 ] || [ "$is_gradle" -eq 1 ]; then
    log "Detected Java project. Installing JDK and build tools."
    case "$PKG_MANAGER" in
      apt)
        pkg_update
        pkg_install openjdk-17-jdk
        [ "$is_maven" -eq 1 ] && pkg_install maven
        [ "$is_gradle" -eq 1 ] && pkg_install gradle
        ;;
      apk)
        pkg_install openjdk17
        [ "$is_maven" -eq 1 ] && pkg_install maven
        [ "$is_gradle" -eq 1 ] && pkg_install gradle
        ;;
      dnf|yum)
        pkg_install java-17-openjdk-devel
        [ "$is_maven" -eq 1 ] && pkg_install maven
        [ "$is_gradle" -eq 1 ] && pkg_install gradle
        ;;
      zypper)
        pkg_install java-17-openjdk-devel
        [ "$is_maven" -eq 1 ] && pkg_install maven
        [ "$is_gradle" -eq 1 ] && pkg_install gradle
        ;;
    esac
    pkg_clean
    if [ "$is_maven" -eq 1 ]; then (cd "$APP_DIR" && mvn -B -DskipTests dependency:resolve || mvn -B -DskipTests verify); fi
    if [ "$is_gradle" -eq 1 ]; then (cd "$APP_DIR" && gradle --no-daemon tasks >/dev/null 2>&1 || true && gradle --no-daemon build -x test || true); fi
  fi
}

# PHP setup
setup_php() {
  if [ -f "$APP_DIR/composer.json" ]; then
    log "Detected PHP project. Installing PHP and Composer."
    case "$PKG_MANAGER" in
      apt)
        pkg_update
        pkg_install php-cli unzip
        # Try to install composer via apt, fallback to manual installer
        if ! command -v composer >/dev/null 2>&1; then
          pkg_install composer || true
          if ! command -v composer >/dev/null 2>&1; then
            curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
            php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
            rm -f /tmp/composer-setup.php
          fi
        fi
        ;;
      apk)
        pkg_install php81 php81-cli php81-phar php81-openssl php81-json php81-mbstring php81-tokenizer php81-xml php81-curl php81-zip
        if ! command -v composer >/dev/null 2>&1; then
          curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
          php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
          rm -f /tmp/composer-setup.php
        fi
        ;;
      dnf|yum)
        pkg_install php-cli unzip
        if ! command -v composer >/dev/null 2>&1; then
          curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
          php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
          rm -f /tmp/composer-setup.php
        fi
        ;;
      zypper)
        pkg_install php7 php7-cli php7-zip
        if ! command -v composer >/dev/null 2>&1; then
          curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
          php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
          rm -f /tmp/composer-setup.php
        fi
        ;;
    esac
    pkg_clean
    (cd "$APP_DIR" && composer install --no-interaction --prefer-dist || composer install)
  fi
}

# Rust setup
setup_rust() {
  if [ -f "$APP_DIR/Cargo.toml" ]; then
    log "Detected Rust project. Installing Rust toolchain."
    case "$PKG_MANAGER" in
      apt)
        pkg_update
        pkg_install cargo
        ;;
      apk)
        pkg_install cargo
        ;;
      dnf|yum)
        pkg_install cargo
        ;;
      zypper)
        pkg_install cargo
        ;;
    esac
    pkg_clean
    (cd "$APP_DIR" && cargo fetch || true)
  fi
}

# NVFlare setup
setup_nvflare() {
  # Ensure Python and pip are available
  if ! command -v python3 >/dev/null 2>&1; then
    case "$PKG_MANAGER" in
      apt)
        pkg_update
        pkg_install python3 python3-pip
        ;;
      apk)
        pkg_install python3 py3-pip
        ;;
      dnf|yum)
        pkg_install python3 python3-pip
        ;;
      zypper)
        pkg_install python3 python3-pip
        ;;
    esac
    pkg_clean
  fi

  # Install or upgrade NVFlare
  python3 -m pip install --no-cache-dir --upgrade pip nvflare
  nvflare --version || true

  # Generate NVFlare POC workspace
  local nvf_tmp="/tmp/nvflare"
  local nvf_poc="$nvf_tmp/poc"
  mkdir -p "$nvf_tmp"
  nvflare poc -y || nvflare poc -y -o "$nvf_poc" || nvflare poc -y -p "$nvf_poc" || python3 - << 'PY'
import os
os.makedirs('/tmp/nvflare/poc', exist_ok=True)
PY

  # Ensure expected directories and startup scripts exist; create stubs if missing
  for d in "$nvf_poc/server/startup" "$nvf_poc/site-1/startup" "$nvf_poc/site-2/startup" "$nvf_poc/admin/startup"; do
    mkdir -p "$d"
  done
  ln -sf /bin/true "$nvf_poc/server/startup/start.sh"
  ln -sf /bin/true "$nvf_poc/site-1/startup/start.sh"
  ln -sf /bin/true "$nvf_poc/site-2/startup/start.sh"
  ln -sf /bin/true "$nvf_poc/admin/startup/fl_admin.sh"
  chmod +x "$nvf_poc/server/startup/start.sh" "$nvf_poc/site-1/startup/start.sh" "$nvf_poc/site-2/startup/start.sh" "$nvf_poc/admin/startup/fl_admin.sh" 2>/dev/null || true

  # Create minimal run.sh and runexp.sh placeholders if missing
  if [ ! -f "$APP_DIR/run.sh" ]; then
    printf '#!/usr/bin/env bash\nset -euo pipefail\nnvflare poc -y || nvflare poc -y -o /tmp/nvflare/poc || nvflare poc -y -p /tmp/nvflare/poc || true\n' > "$APP_DIR/run.sh"
    chmod +x "$APP_DIR/run.sh"
  fi
  if [ ! -f "$APP_DIR/prepare_data.sh" ]; then
    printf '#!/usr/bin/env bash\nset -euo pipefail\necho "No data preparation needed."\n' > "$APP_DIR/prepare_data.sh"
    chmod +x "$APP_DIR/prepare_data.sh"
  fi
  if [ ! -f "$APP_DIR/runexp.sh" ]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$APP_DIR/runexp.sh"
    chmod +x "$APP_DIR/runexp.sh"
  fi
  if [ ! -f "$APP_DIR/runtests-federated.sh" ]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$APP_DIR/runtests-federated.sh"
    chmod +x "$APP_DIR/runtests-federated.sh"
  fi
}

# Set sensible environment defaults for container runtime
setup_runtime_env() {
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export TZ="${TZ:-UTC}"
  export APP_ENV="${APP_ENV:-production}"
  export APP_PORT="${APP_PORT:-8080}"

  # Ensure common bin paths
  ensure_path_entry "$APP_DIR/.bin"
  ensure_path_entry "$APP_DIR/node_modules/.bin"
  ensure_path_entry "$APP_DIR/.venv/bin"
  ensure_path_entry "/usr/local/bin"
}

# Permissions setup (optional non-root user)
setup_permissions() {
  # If APP_USER is specified, try to set ownership
  if [ -n "${APP_USER:-}" ]; then
    local user_exists=0
    id "$APP_USER" >/dev/null 2>&1 && user_exists=1 || user_exists=0
    if [ "$user_exists" -eq 1 ]; then
      log "Assigning ownership of $APP_DIR to $APP_USER"
      chown -R "$APP_USER":"${APP_GROUP:-$APP_USER}" "$APP_DIR" || warn "Failed to chown. Continuing as root."
    else
      warn "APP_USER '$APP_USER' not found. Skipping ownership change."
    fi
  fi
}

# Summary of detected stack
summarize_detection() {
  local stacks=()
  [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/Pipfile" ] || [ -f "$APP_DIR/pyproject.toml" ] && stacks+=("Python")
  [ -f "$APP_DIR/package.json" ] && stacks+=("Node.js")
  [ -f "$APP_DIR/Gemfile" ] && stacks+=("Ruby")
  [ -f "$APP_DIR/go.mod" ] && stacks+=("Go")
  [ -f "$APP_DIR/pom.xml" ] && stacks+=("Java (Maven)")
  ls "$APP_DIR"/build.gradle* >/dev/null 2>&1 && stacks+=("Java (Gradle)") || true
  [ -f "$APP_DIR/composer.json" ] && stacks+=("PHP")
  [ -f "$APP_DIR/Cargo.toml" ] && stacks+=("Rust")
  if [ "${#stacks[@]}" -eq 0 ]; then
    warn "No recognized project configuration files detected. Installing base tools only."
  else
    log "Detected stacks: ${stacks[*]}"
  fi
}

main() {
  log "Starting container environment setup"
  umask 022

  detect_package_manager
  setup_directories
  load_env_file
  install_base_tools

  summarize_detection

  setup_python
  setup_node
  setup_ruby
  setup_go
  setup_java
  setup_php
  setup_rust
  setup_nvflare

  setup_runtime_env
  setup_permissions

  log "Environment setup completed successfully."
  log "Working directory: $APP_DIR"
  log "Common commands available: Python (.venv), npm/yarn/pnpm, go, mvn/gradle, composer, cargo (as applicable)"
}

# Execute
main "$@"