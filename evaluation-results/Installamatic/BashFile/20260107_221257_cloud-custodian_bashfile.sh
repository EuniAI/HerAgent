#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type(s) and installs required runtimes and system packages
# - Installs dependencies (Node/Python/Ruby/Go/Rust/Java/PHP/.NET)
# - Configures environment variables and PATH
# - Idempotent and safe to re-run
# - Designed to run as root inside Docker (no sudo required)

set -Eeuo pipefail

# -----------------------------
# Configuration (overridable)
# -----------------------------
PROJECT_DIR="${PROJECT_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
DEFAULT_PORT="${PORT:-8080}"
NODE_DEFAULT_MAJOR="${NODE_DEFAULT_MAJOR:-20}"        # Fallback Node.js LTS major version
DOTNET_CHANNEL="${DOTNET_CHANNEL:-LTS}"               # .NET install channel if no global.json
JAVA_VERSION="${JAVA_VERSION:-17}"                    # OpenJDK version if needed
GO_VERSION_PKG="${GO_VERSION_PKG:-}"                  # Leave empty to use distro default
RUST_PROFILE="${RUST_PROFILE:-minimal}"               # rustup profile
PYTHON_VENV_DIR="${PYTHON_VENV_DIR:-$PROJECT_DIR/.venv}"
ENV_PROFILE_FILE="/etc/profile.d/project_env.sh"

# -----------------------------
# Colors and logging
# -----------------------------
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'
  RED=$'\033[0;31m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BLUE=""; NC=""
fi

log()    { echo "${GREEN}[$(date +'%F %T')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR] $*${NC}" >&2; }
info()   { echo "${BLUE}$*${NC}"; }

# Trap errors with line/command info
err_trap() {
  local exit_code=$?
  local line_no=$1
  error "Script failed at line ${line_no} with exit code ${exit_code}"
  exit "${exit_code}"
}
trap 'err_trap $LINENO' ERR

# -----------------------------
# Utility helpers
# -----------------------------
DEBIAN_FRONTEND=noninteractive
PKG_MGR=""
PKG_UPDATED="false"
NEEDS_BUILD_TOOLS="false"

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  else
    error "No supported package manager found (apt/apk/dnf/yum/microdnf/zypper)."
    exit 1
  fi
}

pm_update() {
  if [ "$PKG_UPDATED" = "true" ]; then return 0; fi
  case "$PKG_MGR" in
    apt)
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    microdnf)
      microdnf -y update || true
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache
      ;;
    zypper)
      zypper refresh
      ;;
  esac
  PKG_UPDATED="true"
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  local pkgs=("$@")
  if [ ${#pkgs[@]} -eq 0 ]; then return 0; fi
  pm_update
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    microdnf)
      microdnf install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${pkgs[@]}"
      ;;
  esac
}

pm_install_build_tools() {
  case "$PKG_MGR" in
    apt)
      pm_install build-essential pkg-config
      ;;
    apk)
      pm_install build-base pkgconfig
      ;;
    microdnf|dnf|yum)
      # Try groupinstall, fallback individual packages
      if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        (dnf groupinstall -y "Development Tools" || yum groupinstall -y "Development Tools") || true
      fi
      pm_install gcc gcc-c++ make pkgconfig
      ;;
    zypper)
      pm_install -t pattern devel_C_C++ || true
      pm_install gcc gcc-c++ make pkg-config
      ;;
  esac
}

ensure_base_packages() {
  log "Installing base system packages and CA certificates..."
  case "$PKG_MGR" in
    apt)
      pm_install ca-certificates curl git unzip xz-utils tar gzip bash coreutils sed awk grep jq findutils
      ;;
    apk)
      pm_install ca-certificates curl git unzip xz tar gzip bash coreutils sed gawk grep jq findutils
      update-ca-certificates || true
      ;;
    microdnf|dnf|yum)
      pm_install ca-certificates curl git unzip xz tar gzip bash coreutils sed gawk grep jq findutils shadow-utils
      update-ca-trust || true
      ;;
    zypper)
      pm_install ca-certificates curl git unzip xz tar gzip bash coreutils sed gawk grep jq findutils shadow
      ;;
  esac
}

ensure_user_and_dirs() {
  log "Ensuring project directory and application user..."
  mkdir -p "$PROJECT_DIR"

  # Create group if needed
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if command -v addgroup >/dev/null 2>&1; then
      addgroup -g "$APP_GID" -S "$APP_GROUP" || addgroup -g "$APP_GID" "$APP_GROUP" || true
    elif command -v groupadd >/dev/null 2>&1; then
      groupadd -g "$APP_GID" -f "$APP_GROUP" || true
    fi
  fi

  # Create user if needed
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if command -v adduser >/dev/null 2>&1; then
      adduser -S -D -H -G "$APP_GROUP" -u "$APP_UID" "$APP_USER" || adduser -D -H -G "$APP_GROUP" -u "$APP_UID" "$APP_USER" || true
    elif command -v useradd >/dev/null 2>&1; then
      useradd -M -N -g "$APP_GROUP" -u "$APP_UID" -s /usr/sbin/nologin "$APP_USER" || true
    else
      warn "No useradd/adduser available; continuing as root."
    fi
  fi

  chown -R "${APP_USER}:${APP_GROUP}" "$PROJECT_DIR" || true
}

run_as_app() {
  # Runs a command as APP_USER if possible; otherwise runs as current user
  local cmd="$*"
  if id -u "$APP_USER" >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    su -s /bin/sh -c "cd \"$PROJECT_DIR\" && $cmd" "$APP_USER"
  else
    (cd "$PROJECT_DIR" && eval "$cmd")
  fi
}

# -----------------------------
# Stack detection
# -----------------------------
has_file() { [ -f "$PROJECT_DIR/$1" ]; }
has_any_file() { for f in "$@"; do [ -f "$PROJECT_DIR/$f" ] && return 0; done; return 1; }

detect_stack() {
  STACK_NODE="false"
  STACK_PYTHON="false"
  STACK_RUBY="false"
  STACK_GO="false"
  STACK_RUST="false"
  STACK_JAVA="false"
  STACK_PHP="false"
  STACK_DOTNET="false"

  if has_file "package.json"; then STACK_NODE="true"; fi
  if has_any_file "pyproject.toml" "requirements.txt" "Pipfile" "setup.py" "requirements.in"; then STACK_PYTHON="true"; fi
  if has_file "Gemfile"; then STACK_RUBY="true"; fi
  if has_file "go.mod"; then STACK_GO="true"; fi
  if has_file "Cargo.toml"; then STACK_RUST="true"; fi
  if has_any_file "pom.xml" "build.gradle" "build.gradle.kts" "gradle.properties" "mvnw" "gradlew"; then STACK_JAVA="true"; fi
  if has_file "composer.json"; then STACK_PHP="true"; fi
  if ls "$PROJECT_DIR"/*.csproj >/dev/null 2>&1 || has_file "global.json" || ls "$PROJECT_DIR"/*.sln >/dev/null 2>&1; then STACK_DOTNET="true"; fi

  # Flag if we likely need build tools for native dependencies
  if [ "$STACK_PYTHON" = "true" ] || [ "$STACK_RUST" = "true" ] || [ "$STACK_NODE" = "true" ]; then
    NEEDS_BUILD_TOOLS="true"
  fi
}

# -----------------------------
# Node.js setup
# -----------------------------
install_node_runtime() {
  log "Installing Node.js runtime..."
  case "$PKG_MGR" in
    apt)
      # Install via NodeSource for modern LTS
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_DEFAULT_MAJOR}.x" -o /tmp/nodesource_setup.sh
      bash /tmp/nodesource_setup.sh
      pm_install nodejs
      ;;
    apk)
      pm_install nodejs npm
      ;;
    microdnf|dnf|yum)
      pm_install nodejs npm || {
        warn "Distro Node.js not available; installing via NodeSource RPM..."
        curl -fsSL https://rpm.nodesource.com/setup_${NODE_DEFAULT_MAJOR}.x -o /tmp/nodesource_setup.sh
        bash /tmp/nodesource_setup.sh
        pm_install nodejs
      }
      ;;
    zypper)
      pm_install nodejs npm || pm_install nodejs20 npm20 || true
      ;;
  esac
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi
}

install_node_dependencies() {
  log "Installing Node.js dependencies..."
  local pkgmgr=""
  if has_file "pnpm-lock.yaml"; then
    pkgmgr="pnpm"
    if command -v corepack >/dev/null 2>&1; then corepack enable pnpm || true; fi
    run_as_app "pnpm install --frozen-lockfile || pnpm install"
  elif has_file "yarn.lock"; then
    pkgmgr="yarn"
    if command -v corepack >/dev/null 2>&1; then corepack enable yarn || true; fi
    run_as_app "yarn install --frozen-lockfile || yarn install"
  elif has_file "package-lock.json" || has_file "npm-shrinkwrap.json"; then
    pkgmgr="npm"
    run_as_app "npm ci || npm install"
  else
    pkgmgr="npm"
    run_as_app "npm install"
  fi
  log "Node.js dependencies installed using $pkgmgr"
}

# -----------------------------
# Python setup
# -----------------------------
install_python_runtime() {
  log "Installing Python runtime and tools..."
  case "$PKG_MGR" in
    apt)
      pm_install python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      pm_install python3 py3-pip py3-virtualenv python3-dev musl-dev
      ;;
    microdnf|dnf|yum)
      pm_install python3 python3-pip python3-devel
      ;;
    zypper)
      pm_install python3 python3-pip python3-virtualenv python3-devel
      ;;
  esac
  if [ "$NEEDS_BUILD_TOOLS" = "true" ]; then
    pm_install_build_tools
  fi
}

setup_python_venv_and_deps() {
  log "Setting up Python virtual environment and installing dependencies..."
  mkdir -p "$PYTHON_VENV_DIR"
  if [ ! -f "$PYTHON_VENV_DIR/bin/activate" ]; then
    run_as_app "python3 -m venv \"$PYTHON_VENV_DIR\""
  fi
  # shellcheck disable=SC2016
  run_as_app "source \"$PYTHON_VENV_DIR/bin/activate\" && python -m pip install --upgrade pip setuptools wheel"
  if has_file "requirements.txt"; then
    # shellcheck disable=SC2016
    run_as_app "source \"$PYTHON_VENV_DIR/bin/activate\" && pip install -r requirements.txt"
  elif has_file "pyproject.toml"; then
    if grep -q "^\[tool\.poetry\]" "$PROJECT_DIR/pyproject.toml" 2>/dev/null || has_file "poetry.lock"; then
      # shellcheck disable=SC2016
      run_as_app "source \"$PYTHON_VENV_DIR/bin/activate\" && pip install poetry && poetry config virtualenvs.create false && poetry install --no-interaction --no-ansi"
    else
      # PEP 517/518 build-system – attempt pip install in editable if setup defined
      # shellcheck disable=SC2016
      run_as_app "source \"$PYTHON_VENV_DIR/bin/activate\" && pip install . || true"
    fi
  elif has_file "Pipfile"; then
    # Install pipenv lightweight
    # shellcheck disable=SC2016
    run_as_app "source \"$PYTHON_VENV_DIR/bin/activate\" && pip install pipenv && pipenv install --dev --system --deploy || pipenv install --system"
  fi
}

# -----------------------------
# Ruby setup
# -----------------------------
install_ruby_and_bundle() {
  log "Installing Ruby and Bundler..."
  case "$PKG_MGR" in
    apt)
      pm_install ruby-full build-essential
      ;;
    apk)
      pm_install ruby ruby-dev build-base
      ;;
    microdnf|dnf|yum)
      pm_install ruby ruby-devel @development-tools || pm_install ruby ruby-devel gcc gcc-c++ make
      ;;
    zypper)
      pm_install ruby ruby-devel make gcc gcc-c++
      ;;
  esac
  run_as_app "gem install --no-document bundler || true"
  if has_file "Gemfile"; then
    run_as_app "bundle config set --local path 'vendor/bundle' && bundle install --jobs=4"
  fi
}

# -----------------------------
# Go setup
# -----------------------------
install_go_and_deps() {
  log "Installing Go..."
  case "$PKG_MGR" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    microdnf|dnf|yum) pm_install golang ;;
    zypper) pm_install go ;;
  esac
  if has_file "go.mod"; then
    run_as_app "go mod download"
  fi
}

# -----------------------------
# Rust setup
# -----------------------------
install_rust_and_deps() {
  log "Installing Rust toolchain via rustup..."
  if ! command -v curl >/dev/null 2>&1; then pm_install curl; fi
  run_as_app "curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile $RUST_PROFILE"
  # Add cargo to PATH for subsequent non-login shells
  mkdir -p /etc/profile.d
  if ! grep -q 'CARGO_HOME' "$ENV_PROFILE_FILE" 2>/dev/null; then
    cat >> "$ENV_PROFILE_FILE" <<'EOF'
# Rust/Cargo
export CARGO_HOME="${CARGO_HOME:-/home/app/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-/home/app/.rustup}"
if [ -d "$CARGO_HOME/bin" ]; then
  export PATH="$CARGO_HOME/bin:$PATH"
fi
EOF
  fi
  if has_file "Cargo.toml"; then
    run_as_app "$HOME/.cargo/bin/cargo fetch || cargo fetch || true"
  fi
}

# -----------------------------
# Java setup
# -----------------------------
install_java_and_tools() {
  log "Installing OpenJDK and build tools..."
  case "$PKG_MGR" in
    apt)
      pm_install "openjdk-${JAVA_VERSION}-jdk" maven
      ;;
    apk)
      # Alpine uses specific package names
      pm_install "openjdk${JAVA_VERSION}-jdk" maven || pm_install openjdk17 maven || true
      ;;
    microdnf|dnf|yum)
      pm_install "java-${JAVA_VERSION}-openjdk-devel" maven
      ;;
    zypper)
      pm_install "java-${JAVA_VERSION}-openjdk-devel" maven
      ;;
  esac
  # Use wrapper if present
  if has_file "mvnw"; then
    run_as_app "chmod +x mvnw && ./mvnw -q -B -DskipTests dependency:resolve || true"
  elif has_any_file "pom.xml"; then
    run_as_app "mvn -q -B -DskipTests dependency:resolve || true"
  fi
  if has_file "gradlew"; then
    run_as_app "chmod +x gradlew && ./gradlew --no-daemon tasks >/dev/null 2>&1 || true"
  fi
}

# -----------------------------
# PHP setup
# -----------------------------
install_php_and_composer() {
  log "Installing PHP and Composer..."
  case "$PKG_MGR" in
    apt)
      pm_install php-cli php-xml php-mbstring php-curl php-zip unzip curl
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
      fi
      ;;
    apk)
      pm_install php php-cli php-phar php-json php-iconv php-mbstring php-openssl php-xml php-curl php-zip curl
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
      fi
      ;;
    microdnf|dnf|yum)
      pm_install php-cli php-xml php-mbstring php-json php-curl php-zip curl
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
      fi
      ;;
    zypper)
      pm_install php7 php7-cli php7-xml php7-mbstring php7-curl php7-zip curl || pm_install php php-cli php-xml php-mbstring php-curl php-zip curl
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
      fi
      ;;
  esac
  if has_file "composer.json"; then
    run_as_app "composer install --no-interaction --prefer-dist --no-progress || true"
  fi
}

# -----------------------------
# .NET setup
# -----------------------------
install_dotnet_and_restore() {
  log "Installing .NET SDK..."
  mkdir -p /usr/share/dotnet
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  chmod +x /tmp/dotnet-install.sh

  local channel="$DOTNET_CHANNEL"
  if has_file "global.json" && command -v jq >/dev/null 2>&1; then
    local version
    version=$(jq -r '.sdk.version // empty' "$PROJECT_DIR/global.json" || true)
    if [ -n "$version" ] && [ "$version" != "null" ]; then
      run_as_app "/tmp/dotnet-install.sh --install-dir /usr/share/dotnet --version $version"
    else
      run_as_app "/tmp/dotnet-install.sh --install-dir /usr/share/dotnet --channel $channel"
    fi
  else
    run_as_app "/tmp/dotnet-install.sh --install-dir /usr/share/dotnet --channel $channel"
  fi

  # Ensure PATH contains dotnet
  if ! grep -q '/usr/share/dotnet' "$ENV_PROFILE_FILE" 2>/dev/null; then
    echo 'export PATH="/usr/share/dotnet:$PATH"' >> "$ENV_PROFILE_FILE"
  fi

  # Restore packages if project found
  if ls "$PROJECT_DIR"/*.sln >/dev/null 2>&1; then
    run_as_app "DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 /usr/share/dotnet/dotnet restore || true"
  elif ls "$PROJECT_DIR"/*.csproj >/dev/null 2>&1; then
    run_as_app "DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 /usr/share/dotnet/dotnet restore || true"
  fi
}

# -----------------------------
# PATH and environment configuration
# -----------------------------
write_env_profile() {
  log "Writing environment profile to $ENV_PROFILE_FILE"
  mkdir -p "$(dirname "$ENV_PROFILE_FILE")"

  cat > "$ENV_PROFILE_FILE" <<EOF
# Auto-generated by setup script
export APP_USER="${APP_USER}"
export APP_GROUP="${APP_GROUP}"
export APP_HOME="/home/${APP_USER}"
export PROJECT_DIR="${PROJECT_DIR}"
export PORT="${DEFAULT_PORT}"

# Prefer local project bins
if [ -d "\$PROJECT_DIR/node_modules/.bin" ]; then
  export PATH="\$PROJECT_DIR/node_modules/.bin:\$PATH"
fi

# Python virtualenv
if [ -d "${PYTHON_VENV_DIR}/bin" ]; then
  export VIRTUAL_ENV="${PYTHON_VENV_DIR}"
  export PATH="${PYTHON_VENV_DIR}/bin:\$PATH"
fi

# Go
if command -v go >/dev/null 2>&1; then
  export GOPATH="\${GOPATH:-\$PROJECT_DIR/.gopath}"
  mkdir -p "\$GOPATH"
  export PATH="\$GOPATH/bin:\$PATH"
fi

# Dotnet (may be added above too)
if [ -d "/usr/share/dotnet" ]; then
  export PATH="/usr/share/dotnet:\$PATH"
fi

umask 0022
EOF

  chmod 0644 "$ENV_PROFILE_FILE"
}

# -----------------------------
# Main
# -----------------------------
main() {
  log "Starting environment setup..."
  detect_pkg_mgr
  ensure_base_packages

  if [ "$NEEDS_BUILD_TOOLS" = "true" ]; then
    pm_install_build_tools
  fi

  ensure_user_and_dirs

  # Re-detect after creating dir and reading files
  detect_stack

  # Install per stack
  if [ "$STACK_NODE" = "true" ]; then
    install_node_runtime
    install_node_dependencies
  fi

  if [ "$STACK_PYTHON" = "true" ]; then
    install_python_runtime
    setup_python_venv_and_deps
  fi

  if [ "$STACK_RUBY" = "true" ]; then
    install_ruby_and_bundle
  fi

  if [ "$STACK_GO" = "true" ]; then
    install_go_and_deps
  fi

  if [ "$STACK_RUST" = "true" ]; then
    install_rust_and_deps
  fi

  if [ "$STACK_JAVA" = "true" ]; then
    install_java_and_tools
  fi

  if [ "$STACK_PHP" = "true" ]; then
    install_php_and_composer
  fi

  if [ "$STACK_DOTNET" = "true" ]; then
    install_dotnet_and_restore
  fi

  write_env_profile

  # Create a default .env if not exists
  if [ ! -f "$PROJECT_DIR/.env" ]; then
    cat > "$PROJECT_DIR/.env" <<EOF
# Default environment variables
PORT=${DEFAULT_PORT}
ENV=production
EOF
    chown "${APP_USER}:${APP_GROUP}" "$PROJECT_DIR/.env" || true
  fi

  # Permissions
  chown -R "${APP_USER}:${APP_GROUP}" "$PROJECT_DIR" || true

  log "Environment setup completed."
  info "Detected stacks:
  - Node.js:  $STACK_NODE
  - Python:   $STACK_PYTHON
  - Ruby:     $STACK_RUBY
  - Go:       $STACK_GO
  - Rust:     $STACK_RUST
  - Java:     $STACK_JAVA
  - PHP:      $STACK_PHP
  - .NET:     $STACK_DOTNET
"
  info "Usage inside container (new shell):
  - Source environment automatically via /etc/profile.d/project_env.sh
  - Project dir: $PROJECT_DIR
  - Default PORT: $DEFAULT_PORT

Examples:
  - Node:   cd \"$PROJECT_DIR\" && npm start (or yarn/pnpm)
  - Python: cd \"$PROJECT_DIR\" && . \"$PYTHON_VENV_DIR/bin/activate\" && python -m pip list
  - Ruby:   cd \"$PROJECT_DIR\" && bundle exec rake -T
  - Go:     cd \"$PROJECT_DIR\" && go build ./...
  - Rust:   cd \"$PROJECT_DIR\" && cargo build
  - Java:   cd \"$PROJECT_DIR\" && ./mvnw test || mvn test
  - PHP:    cd \"$PROJECT_DIR\" && php -v
  - .NET:   cd \"$PROJECT_DIR\" && dotnet --info
"
}

# Ensure PROJECT_DIR exists before detection in case it's not the current working dir
mkdir -p "$PROJECT_DIR"

# If the project files are actually in current directory and PROJECT_DIR is empty, use current directory
if [ "$PROJECT_DIR" = "/app" ] && [ -d "$PWD" ] && [ -n "$(ls -A "$PWD" 2>/dev/null)" ] && [ "$PWD" != "$PROJECT_DIR" ]; then
  warn "PROJECT_DIR is /app but current directory is $PWD with files. Consider setting PROJECT_DIR=$PWD if desired."
fi

main "$@"