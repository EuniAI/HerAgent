#!/usr/bin/env bash
# Universal project environment setup script for containerized (Docker) environments.
# Detects common stacks (Python, Node.js, Ruby, Java, Go, Rust, PHP) and installs/configures accordingly.
# Idempotent, safe to re-run, no sudo required (assumes running as root inside container).

set -Eeuo pipefail

# Globals
readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +%s)"
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SETUP_DIR="${PROJECT_ROOT}/.setup"
readonly LOG_FILE="${SETUP_DIR}/setup.log"
readonly ENV_FILE="${PROJECT_ROOT}/.env"
readonly DEFAULT_APP_USER="app"
readonly DEFAULT_APP_UID="${APP_UID:-1000}"
readonly DEFAULT_APP_GID="${APP_GID:-1000}"

# Colors (safe if stdout is not a terminal)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE" >&2; }
err()  { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE" >&2; }

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    err "Setup failed (exit code: $exit_code). See log: $LOG_FILE"
  else
    local duration=$(( $(date +%s) - START_TIME ))
    log "Setup completed in ${duration}s"
  fi
}
trap cleanup EXIT

ensure_dirs() {
  mkdir -p "$SETUP_DIR" "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/data" || true
  touch "$LOG_FILE" || true
}

# Package manager detection
PKG_MANAGER=""
PKG_INSTALL=""
PKG_UPDATE=""
PKG_CLEAN=""
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_UPDATE="apt-get update"
    PKG_CLEAN="rm -rf /var/lib/apt/lists/*"
    export DEBIAN_FRONTEND=noninteractive
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_INSTALL="apk add --no-cache"
    PKG_UPDATE="apk update"
    PKG_CLEAN="true"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_INSTALL="dnf install -y"
    PKG_UPDATE="dnf makecache"
    PKG_CLEAN="dnf clean all"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
    PKG_INSTALL="microdnf install -y"
    PKG_UPDATE="microdnf update -y || true"
    PKG_CLEAN="microdnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_INSTALL="yum install -y"
    PKG_UPDATE="yum makecache"
    PKG_CLEAN="yum clean all"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    PKG_INSTALL="zypper --non-interactive install --no-recommends"
    PKG_UPDATE="zypper --non-interactive refresh"
    PKG_CLEAN="zypper --non-interactive clean --all"
  else
    err "No supported package manager found (apt, apk, dnf, microdnf, yum, zypper)."
    exit 1
  fi
  info "Using package manager: $PKG_MANAGER"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must run as root inside the container (no sudo available)."
    exit 1
  fi
}

install_base_tools() {
  local marker="${SETUP_DIR}/base_tools.done"
  if [ -f "$marker" ]; then
    info "Base tools already installed. Skipping."
    return 0
  fi
  log "Installing base system tools..."
  case "$PKG_MANAGER" in
    apt)
      $PKG_UPDATE
      $PKG_INSTALL ca-certificates curl git bash tzdata xz-utils unzip zip gnupg procps
      # On Debian/Ubuntu, ensure locales if needed (optional)
      $PKG_INSTALL locales || true
      $PKG_CLEAN
      ;;
    apk)
      $PKG_UPDATE || true
      $PKG_INSTALL ca-certificates curl git bash tzdata xz unzip zip tar
      # Alpine compatibility shim
      $PKG_INSTALL libc6-compat || true
      ;;
    dnf|microdnf|yum)
      $PKG_UPDATE || true
      $PKG_INSTALL ca-certificates curl git bash tzdata xz unzip zip gnupg2 procps-ng
      $PKG_CLEAN || true
      ;;
    zypper)
      $PKG_UPDATE || true
      $PKG_INSTALL ca-certificates curl git bash timezone xz unzip zip gpg2 procps
      $PKG_CLEAN || true
      ;;
  esac
  touch "$marker"
}

create_app_user() {
  local marker="${SETUP_DIR}/app_user.done"
  if [ -f "$marker" ]; then
    info "App user already configured."
    return 0
  fi
  # Create non-root user for runtime if possible
  if command -v adduser >/dev/null 2>&1 || command -v useradd >/dev/null 2>&1; then
    if ! id -u "$DEFAULT_APP_USER" >/dev/null 2>&1; then
      case "$PKG_MANAGER" in
        apk)
          addgroup -g "$DEFAULT_APP_GID" "$DEFAULT_APP_USER" 2>/dev/null || true
          adduser -D -h "$PROJECT_ROOT" -G "$DEFAULT_APP_USER" -u "$DEFAULT_APP_UID" "$DEFAULT_APP_USER" 2>/dev/null || true
          ;;
        apt|dnf|microdnf|yum|zypper)
          groupadd -g "$DEFAULT_APP_GID" "$DEFAULT_APP_USER" 2>/dev/null || true
          useradd -m -u "$DEFAULT_APP_UID" -g "$DEFAULT_APP_GID" -d "$PROJECT_ROOT" -s /bin/bash "$DEFAULT_APP_USER" 2>/dev/null || true
          ;;
      esac
    fi
    chown -R "$DEFAULT_APP_UID:$DEFAULT_APP_GID" "$PROJECT_ROOT" || true
    touch "$marker"
    info "Created/ensured non-root user '$DEFAULT_APP_USER' (uid:$DEFAULT_APP_UID gid:$DEFAULT_APP_GID)."
  else
    warn "User management tools not available; continuing as root."
  fi
}

ensure_env_file() {
  if [ -f "$ENV_FILE" ]; then
    # Patch JAVA_TOOL_OPTIONS if present and unquoted to avoid word-splitting during export
    if grep -q '^JAVA_TOOL_OPTIONS=' "$ENV_FILE"; then
      if ! grep -q '^JAVA_TOOL_OPTIONS="' "$ENV_FILE" && ! grep -q "^JAVA_TOOL_OPTIONS='" "$ENV_FILE"; then
        sed -i "s|^JAVA_TOOL_OPTIONS=.*$|JAVA_TOOL_OPTIONS='-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0'|" "$ENV_FILE" || true
      fi
    fi
    info ".env found; not modifying."
    return 0
  fi
  log "Creating default .env file..."
  cat > "$ENV_FILE" <<EOF
# Generated by ${SCRIPT_NAME} on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
APP_ENV=development
APP_PORT=8080
TZ=UTC

# Python
PYTHONUNBUFFERED=1
PIP_NO_CACHE_DIR=1
PIP_DISABLE_PIP_VERSION_CHECK=1

# Node
NODE_ENV=development
NPM_CONFIG_FUND=false
NPM_CONFIG_AUDIT=false

# Java
JAVA_TOOL_OPTIONS='-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0'

# Go
GOPATH=\$HOME/go

# Rust
CARGO_TERM_COLOR=always
EOF
}

export_env() {
  # Load .env safely (ignore comments/empty lines)
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC2046
    eval $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | sed 's/^/export /')
    set +a
  fi
  [ -n "${TZ:-}" ] && ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime 2>/dev/null || true
}

# Auto-activate Python virtual environment for future shells
ensure_venv_auto_activate() {
  local bashrc_file="$HOME/.bashrc"
  if [ -d "${PROJECT_ROOT}/.venv" ]; then
    if ! grep -qF "source ${PROJECT_ROOT}/.venv/bin/activate" "$bashrc_file" 2>/dev/null && \
       ! grep -qF ". ${PROJECT_ROOT}/.venv/bin/activate" "$bashrc_file" 2>/dev/null; then
      {
        echo ""
        echo "# Auto-activate Python virtual environment"
        echo "if [ -d \"${PROJECT_ROOT}/.venv\" ]; then . \"${PROJECT_ROOT}/.venv/bin/activate\"; fi"
      } >> "$bashrc_file"
    fi
  fi
}

# Sherlock CLI setup (dedicated venv in /opt, symlink to PATH)
setup_sherlock_cli() {
  local marker="${SETUP_DIR}/sherlock_cli.done"
  if [ -f "$marker" ]; then
    info "Sherlock CLI already installed. Skipping."
    return 0
  fi
  log "Installing Sherlock CLI into dedicated virtual environment..."
  if [ "$PKG_MANAGER" = "apt" ]; then
    apt-get update
    apt-get install -y python3-venv python3-pip
  fi
  if [ ! -d "/opt/sherlock-venv" ]; then
    python3 -m venv /opt/sherlock-venv
  fi
  /opt/sherlock-venv/bin/python -m pip install --upgrade pip setuptools wheel
  /opt/sherlock-venv/bin/pip install --no-cache-dir --upgrade sherlock-project
  ln -sf /opt/sherlock-venv/bin/sherlock /usr/local/bin/sherlock
  touch "$marker"
}

# Language-specific setup functions
setup_python() {
  if [ -f "${SETUP_DIR}/python.done" ]; then
    info "Python environment already set up."
    return 0
  fi
  if [ ! -f "$PROJECT_ROOT/requirements.txt" ] && [ ! -f "$PROJECT_ROOT/pyproject.toml" ] && [ ! -f "$PROJECT_ROOT/Pipfile" ]; then
    info "No Python project files detected."
    return 0
  fi
  log "Setting up Python environment..."

  case "$PKG_MANAGER" in
    apt)
      $PKG_UPDATE
      $PKG_INSTALL python3 python3-pip python3-venv python3-dev build-essential libffi-dev libssl-dev pkg-config
      $PKG_CLEAN
      ;;
    apk)
      $PKG_INSTALL python3 py3-pip python3-dev build-base libffi-dev openssl-dev pkgconf
      ;;
    dnf|microdnf|yum)
      $PKG_INSTALL python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel pkgconf-pkg-config
      ;;
    zypper)
      $PKG_INSTALL python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel libopenssl-devel pkg-config
      ;;
  esac

  # Create venv
  local venv_dir="${PROJECT_ROOT}/.venv"
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
  fi
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel
  python3 -m pip install --no-cache-dir -U sherlock-project

  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install -r "$PROJECT_ROOT/requirements.txt"
  fi

  if [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    # Try Poetry if configured; fall back to pip-compatible build if available
    if grep -q "\[tool\.poetry\]" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      log "Detected Poetry project; installing with Poetry..."
      pip install "poetry>=1.4"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi
    else
      log "PEP 621 project; attempting editable install (if applicable)..."
      pip install -e "$PROJECT_ROOT" || true
    fi
  fi

  if [ -f "$PROJECT_ROOT/Pipfile" ]; then
    log "Detected Pipenv project; installing with Pipenv..."
    pip install "pipenv>=2023.0"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  fi

  # Persist PATH update for shell sessions
  local profile="${PROJECT_ROOT}/.bashrc"
  if ! grep -q '.venv/bin' "$profile" 2>/dev/null; then
    echo 'export PATH="'"$PROJECT_ROOT"'/.venv/bin:$PATH"' >> "$profile"
  fi

  touch "${SETUP_DIR}/python.done"
  info "Python environment setup complete."
}

setup_node() {
  if [ -f "${SETUP_DIR}/node.done" ]; then
    info "Node.js environment already set up."
    return 0
  fi
  if [ ! -f "$PROJECT_ROOT/package.json" ]; then
    info "No Node.js project files detected."
    return 0
  fi

  log "Setting up Node.js environment..."
  case "$PKG_MANAGER" in
    apt)
      $PKG_UPDATE
      # Use distro packages to avoid remote scripts. May be older but stable.
      $PKG_INSTALL nodejs npm
      # If node is too old and corepack is missing, optionally install from Nodesource when NODE_MAJOR set
      if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        warn "node/npm not found via apt; attempting NodeSource (20.x)..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && $PKG_INSTALL nodejs || warn "NodeSource install failed; continuing."
      fi
      $PKG_CLEAN || true
      ;;
    apk)
      $PKG_INSTALL nodejs npm
      ;;
    dnf|microdnf|yum)
      $PKG_INSTALL nodejs npm || {
        warn "Repo nodejs not available; trying NodeSource (20.x)"
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - && $PKG_INSTALL nodejs || warn "NodeSource install failed; continuing."
      }
      ;;
    zypper)
      $PKG_INSTALL nodejs npm || true
      ;;
  esac

  # Enable corepack if available (yarn/pnpm)
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f yarn.lock ]; then
    log "Detected yarn.lock; installing with Yarn..."
    if ! command -v yarn >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then
        corepack prepare yarn@stable --activate || true
      else
        npm install -g yarn
      fi
    fi
    yarn install --frozen-lockfile || yarn install
  elif [ -f pnpm-lock.yaml ]; then
    log "Detected pnpm-lock.yaml; installing with pnpm..."
    if ! command -v pnpm >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then
        corepack prepare pnpm@latest --activate || true
      else
        npm install -g pnpm
      fi
    fi
    pnpm install --frozen-lockfile || pnpm install
  elif [ -f package-lock.json ]; then
    log "Detected package-lock.json; installing with npm ci..."
    npm ci || npm install
  else
    log "No lock file found; running npm install..."
    npm install
  fi
  popd >/dev/null

  touch "${SETUP_DIR}/node.done"
  info "Node.js environment setup complete."
}

setup_ruby() {
  if [ -f "${SETUP_DIR}/ruby.done" ]; then
    info "Ruby environment already set up."
    return 0
  fi
  if [ ! -f "$PROJECT_ROOT/Gemfile" ]; then
    info "No Ruby project files detected."
    return 0
  fi

  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt)
      $PKG_UPDATE
      $PKG_INSTALL ruby-full build-essential libffi-dev libssl-dev
      $PKG_CLEAN
      ;;
    apk)
      $PKG_INSTALL ruby ruby-dev build-base libffi-dev openssl-dev
      ;;
    dnf|microdnf|yum)
      $PKG_INSTALL ruby ruby-devel gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    zypper)
      $PKG_INSTALL ruby ruby-devel gcc gcc-c++ make libffi-devel libopenssl-devel
      ;;
  esac

  gem install bundler --no-document || true
  pushd "$PROJECT_ROOT" >/dev/null
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs 4 || bundle install
  popd >/dev/null

  touch "${SETUP_DIR}/ruby.done"
  info "Ruby environment setup complete."
}

setup_java() {
  if [ -f "${SETUP_DIR}/java.done" ]; then
    info "Java environment already set up."
    return 0
  fi
  if [ ! -f "$PROJECT_ROOT/pom.xml" ] && [ ! -f "$PROJECT_ROOT/build.gradle" ] && [ ! -f "$PROJECT_ROOT/gradlew" ] && [ ! -f "$PROJECT_ROOT/mvnw" ]; then
    info "No Java project files detected."
    return 0
  fi

  log "Setting up Java environment..."
  case "$PKG_MANAGER" in
    apt)
      $PKG_UPDATE
      $PKG_INSTALL openjdk-17-jdk
      $PKG_CLEAN
      ;;
    apk)
      $PKG_INSTALL openjdk17-jdk
      ;;
    dnf|microdnf|yum)
      $PKG_INSTALL java-17-openjdk java-17-openjdk-devel
      ;;
    zypper)
      $PKG_INSTALL java-17-openjdk java-17-openjdk-devel
      ;;
  esac

  # Ensure build tools if wrapper not present
  if [ -f "$PROJECT_ROOT/mvnw" ]; then chmod +x "$PROJECT_ROOT/mvnw"; fi
  if [ -f "$PROJECT_ROOT/gradlew" ]; then chmod +x "$PROJECT_ROOT/gradlew"; fi

  touch "${SETUP_DIR}/java.done"
  info "Java environment setup complete."
}

setup_go() {
  if [ -f "${SETUP_DIR}/go.done" ]; then
    info "Go environment already set up."
    return 0
  fi
  if [ ! -f "$PROJECT_ROOT/go.mod" ]; then
    info "No Go project files detected."
    return 0
  fi

  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apt)
      $PKG_UPDATE
      $PKG_INSTALL golang
      $PKG_CLEAN
      ;;
    apk)
      $PKG_INSTALL go
      ;;
    dnf|microdnf|yum)
      $PKG_INSTALL golang
      ;;
    zypper)
      $PKG_INSTALL go
      ;;
  esac

  pushd "$PROJECT_ROOT" >/dev/null
  if command -v go >/dev/null 2>&1; then
    go mod download || true
  fi
  popd >/dev/null

  touch "${SETUP_DIR}/go.done"
  info "Go environment setup complete."
}

setup_rust() {
  if [ -f "${SETUP_DIR}/rust.done" ]; then
    info "Rust environment already set up."
    return 0
  fi
  if [ ! -f "$PROJECT_ROOT/Cargo.toml" ]; then
    info "No Rust project files detected."
    return 0
  fi

  log "Setting up Rust toolchain (rustup)..."
  if [ ! -x "/root/.cargo/bin/rustc" ] && [ ! -x "$HOME/.cargo/bin/rustc" ]; then
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  # shellcheck disable=SC1090
  if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
  if [ -f "/root/.cargo/env" ]; then . "/root/.cargo/env"; fi

  pushd "$PROJECT_ROOT" >/dev/null
  if command -v cargo >/dev/null 2>&1; then
    cargo fetch || true
  fi
  popd >/dev/null

  # Persist PATH update
  local profile="${PROJECT_ROOT}/.bashrc"
  if ! grep -q '.cargo/bin' "$profile" 2>/dev/null; then
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$profile"
  fi

  touch "${SETUP_DIR}/rust.done"
  info "Rust environment setup complete."
}

setup_php() {
  if [ -f "${SETUP_DIR}/php.done" ]; then
    info "PHP environment already set up."
    return 0
  fi
  if [ ! -f "$PROJECT_ROOT/composer.json" ]; then
    info "No PHP project files detected."
    return 0
  fi

  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      $PKG_UPDATE
      $PKG_INSTALL php-cli php-zip php-mbstring php-curl php-xml unzip
      $PKG_CLEAN
      ;;
    apk)
      $PKG_INSTALL php81 php81-cli php81-phar php81-json php81-mbstring php81-session php81-curl php81-zip php81-xml unzip || \
      $PKG_INSTALL php php-cli php-phar php-json php-mbstring php-session php-curl php-zip php-xml unzip
      ;;
    dnf|microdnf|yum)
      $PKG_INSTALL php-cli php-zip php-mbstring php-json php-curl php-xml unzip
      ;;
    zypper)
      $PKG_INSTALL php8 php8-cli php8-zip php8-mbstring php8-curl php8-xml unzip || \
      $PKG_INSTALL php php-cli php-zip php-mbstring php-curl php-xml unzip
      ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f composer.lock ]; then
    composer install --no-interaction --prefer-dist --no-progress
  else
    composer install --no-interaction --prefer-dist --no-progress || true
  fi
  popd >/dev/null

  touch "${SETUP_DIR}/php.done"
  info "PHP environment setup complete."
}

set_permissions() {
  local marker="${SETUP_DIR}/permissions.done"
  if [ -f "$marker" ]; then
    info "Permissions already set."
    return 0
  fi
  if id -u "$DEFAULT_APP_USER" >/dev/null 2>&1; then
    chown -R "$DEFAULT_APP_UID:$DEFAULT_APP_GID" "$PROJECT_ROOT" || true
  fi
  chmod -R u+rwX,go-rwx "$PROJECT_ROOT" || true
  touch "$marker"
}

print_summary() {
  echo
  log "Summary:"
  [ -f "${SETUP_DIR}/python.done" ] && echo " - Python: ready (.venv at ${PROJECT_ROOT}/.venv)"
  [ -f "${SETUP_DIR}/node.done" ] && echo " - Node.js: ready (dependencies installed)"
  [ -f "${SETUP_DIR}/ruby.done" ] && echo " - Ruby: ready (bundler/vendor/bundle)"
  [ -f "${SETUP_DIR}/java.done" ] && echo " - Java: ready (JDK installed)"
  [ -f "${SETUP_DIR}/go.done" ] && echo " - Go: ready (modules downloaded)"
  [ -f "${SETUP_DIR}/rust.done" ] && echo " - Rust: ready (rustup installed)"
  [ -f "${SETUP_DIR}/php.done" ] && echo " - PHP: ready (composer dependencies installed)"
  echo " - .env at ${ENV_FILE}"
  echo " - Logs: ${LOG_FILE}"
  echo
  info "To use non-root user inside container: `su - ${DEFAULT_APP_USER}` or set USER in Dockerfile/runtime."
}

main() {
  umask 022
  ensure_dirs
  log "Starting environment setup in $PROJECT_ROOT"
  require_root
  detect_pkg_manager
  install_base_tools
  create_app_user
  ensure_env_file
  export_env

  # Detect and setup stacks (can coexist)
  setup_sherlock_cli
  setup_python
  ensure_venv_auto_activate
  setup_node
  setup_ruby
  setup_java
  setup_go
  setup_rust
  setup_php

  set_permissions
  print_summary
}

main "$@"