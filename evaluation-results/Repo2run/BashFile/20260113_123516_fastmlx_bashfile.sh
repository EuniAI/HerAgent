#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Supports auto-detection and setup for: Python, Node.js, Ruby, Go, Java (Maven/Gradle), PHP (Composer), .NET, Rust
# Idempotent, safe to rerun, container-friendly (no sudo required, works as root or non-root with limited features)

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output (fallback to plain text if not TTY)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

# Logging functions
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo -e "${GREEN}[$(timestamp)] $*${NC}"; }
info() { echo -e "${BLUE}[$(timestamp)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(timestamp)] [WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[$(timestamp)] [ERROR] $*${NC}" >&2; }

# Trap errors to provide context
trap 'err "Failed at line $LINENO. Command: $BASH_COMMAND"' ERR

# Utility
has_cmd() { command -v "$1" >/dev/null 2>&1; }
file_exists() { [ -f "$1" ]; }
dir_exists() { [ -d "$1" ]; }

# Globals
ROOT_UID=0
IS_ROOT=0
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
DEFAULT_PORT="${PORT:-8080}"
APP_ENV="${APP_ENV:-production}"
LOG_LEVEL="${LOG_LEVEL:-info}"
RUNTIME_DETECTED=""
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
OS_FAMILY=""

# Determine user privileges
detect_privileges() {
  if [ "$(id -u)" -eq "$ROOT_UID" ]; then
    IS_ROOT=1
    log "Running as root inside container."
  else
    IS_ROOT=0
    warn "Running as non-root. System package installation will be skipped."
  fi
}

# Detect package manager and set functions
detect_pkg_manager() {
  if has_cmd apt-get; then
    PKG_MANAGER="apt"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
    OS_FAMILY="debian"
  elif has_cmd apk; then
    PKG_MANAGER="apk"
    PKG_UPDATE="apk update || true"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
    OS_FAMILY="alpine"
  elif has_cmd dnf; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf -y makecache"
    PKG_INSTALL="dnf install -y"
    PKG_CLEAN="dnf clean all"
    OS_FAMILY="redhat"
  elif has_cmd yum; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum -y makecache || true"
    PKG_INSTALL="yum install -y"
    PKG_CLEAN="yum clean all"
    OS_FAMILY="redhat"
  elif has_cmd zypper; then
    PKG_MANAGER="zypper"
    PKG_UPDATE="zypper refresh"
    PKG_INSTALL="zypper install -y --no-recommends"
    PKG_CLEAN="zypper clean -a || true"
    OS_FAMILY="suse"
  else
    PKG_MANAGER=""
    OS_FAMILY="unknown"
    warn "No supported system package manager detected."
  fi
}

# Install a package safely (best-effort, non-fatal on failure)
install_pkg() {
  local pkg="$1"
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MANAGER" ]; then
    info "Installing system package: $pkg"
    # shellcheck disable=SC2086
    if ! sh -c "$PKG_INSTALL $pkg"; then
      warn "Failed to install package: $pkg (continuing)"
    fi
  else
    warn "Cannot install system package '$pkg' without root or package manager."
  fi
}

# Install a group of packages (best-effort)
install_pkgs() {
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MANAGER" ]; then
    # shellcheck disable=SC2086
    if ! sh -c "$PKG_INSTALL $*"; then
      warn "Some packages failed to install: $* (continuing)"
    fi
  else
    warn "Cannot install packages without root or package manager: $*"
  fi
}

# Update package index
update_packages() {
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MANAGER" ]; then
    info "Updating package index ($PKG_MANAGER)..."
    sh -c "$PKG_UPDATE" || warn "Package index update failed or skipped."
  fi
}

# Clean package caches
clean_packages() {
  if [ "$IS_ROOT" -eq 1 ] && [ -n "$PKG_MANAGER" ]; then
    info "Cleaning package caches..."
    sh -c "$PKG_CLEAN" || true
  fi
}

# Setup base tools (curl, git, build tools, CA certificates)
install_base_tools() {
  update_packages
  case "$OS_FAMILY" in
    debian)
      install_pkgs ca-certificates curl git pkg-config build-essential
      ;;
    alpine)
      install_pkgs ca-certificates curl git pkgconfig build-base
      ;;
    redhat)
      install_pkgs ca-certificates curl git pkgconfig gcc gcc-c++ make
      ;;
    suse)
      install_pkgs ca-certificates curl git pkg-config gcc gcc-c++ make
      ;;
    *)
      warn "Unknown OS family; skipping base tool installation."
      ;;
  esac
  clean_packages
}

# Project directory structure and permissions
setup_project_structure() {
  log "Setting up project directory structure at: $PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,data}
  touch "$PROJECT_ROOT"/logs/.keep "$PROJECT_ROOT"/tmp/.keep
  # Ensure sane permissions
  chmod -R u+rwX,go+rX "$PROJECT_ROOT"
  log "Created directories: logs, tmp, data"
}

# Environment file setup
setup_env_file() {
  local env_file="$PROJECT_ROOT/.env"
  if [ ! -f "$env_file" ]; then
    cat > "$env_file" <<EOF
APP_ENV=$APP_ENV
PORT=$DEFAULT_PORT
LOG_LEVEL=$LOG_LEVEL
# Add custom environment variables below. This file is sourced at runtime.
EOF
    log "Created default .env file at $env_file"
  else
    log ".env file already exists at $env_file (skipping creation)"
  fi
}

# Load .env into current environment
load_env() {
  local env_file="$PROJECT_ROOT/.env"
  if [ -f "$env_file" ]; then
    # shellcheck disable=SC2046
    set -a
    # Read only non-comment lines
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    log "Loaded environment variables from .env"
  fi
}

# Python setup
setup_python() {
  RUNTIME_DETECTED="python"
  log "Detected Python project."
  # Install Python if not present
  if ! has_cmd python3; then
    case "$OS_FAMILY" in
      debian) install_pkgs python3 python3-pip python3-venv python3-dev ;;
      alpine) install_pkgs python3 py3-pip python3-dev ;;
      redhat) install_pkgs python3 python3-pip python3-virtualenv python3-devel || install_pkgs python3 python3-pip ;;
      suse)   install_pkgs python3 python3-pip python3-virtualenv python3-devel || install_pkgs python3 python3-pip ;;
      *) warn "Python not installed and package manager unknown. Please use a Python base image."; return ;;
    esac
  fi
  if ! has_cmd pip3; then
    warn "pip3 not found; attempting ensurepip."
    python3 -m ensurepip --upgrade || warn "ensurepip failed."
  fi

  # Create and activate virtual environment (.venv)
  local venv_dir="$PROJECT_ROOT/.venv"
  if [ ! -d "$venv_dir" ] || [ ! -f "$venv_dir/bin/activate" ]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Python virtual environment already exists at $venv_dir"
  fi
  # Activate venv
  # shellcheck disable=SC1090
  . "$venv_dir/bin/activate"

  # Upgrade pip/setuptools/wheel
  pip install --no-cache-dir --upgrade pip setuptools wheel

  # Dependency installation logic
  if file_exists "$PROJECT_ROOT/requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt"
  elif file_exists "$PROJECT_ROOT/pyproject.toml"; then
    if grep -qE '^\s*\[tool.poetry\]' "$PROJECT_ROOT/pyproject.toml"; then
      log "Poetry detected in pyproject.toml"
      if ! has_cmd poetry; then
        pip install --no-cache-dir "poetry>=1.5"
      fi
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi --only main
    else
      log "Installing Python project via PEP 517/518 (pyproject.toml)"
      pip install --no-cache-dir .
    fi
  elif file_exists "$PROJECT_ROOT/setup.py"; then
    log "Installing Python project via setup.py"
    pip install --no-cache-dir -e "$PROJECT_ROOT"
  else
    warn "No Python dependency file found (requirements.txt/pyproject.toml/setup.py). Skipping dependency installation."
  fi

  # Write activation helper
  cat > "$PROJECT_ROOT/.activate_venv.sh" <<'EOF'
#!/usr/bin/env bash
if [ -f ".venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  . ".venv/bin/activate"
  echo "Virtual environment activated."
else
  echo "No virtual environment found at .venv."
fi
EOF
  chmod +x "$PROJECT_ROOT/.activate_venv.sh"

  # Environment variables common for Python web apps
  if [ -f "$PROJECT_ROOT/app.py" ] || grep -qi "flask" "$PROJECT_ROOT/requirements.txt" 2>/dev/null; then
    export FLASK_ENV="${FLASK_ENV:-production}"
    export FLASK_APP="${FLASK_APP:-app.py}"
    export FLASK_RUN_PORT="${FLASK_RUN_PORT:-$DEFAULT_PORT}"
    log "Configured Flask environment variables."
  fi
  if [ -f "$PROJECT_ROOT/manage.py" ] || grep -qi "django" "$PROJECT_ROOT/requirements.txt" 2>/dev/null; then
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-project.settings}"
    export DJANGO_ALLOWED_HOSTS="${DJANGO_ALLOWED_HOSTS:-*}"
    log "Configured Django environment variables."
  fi

  deactivate || true
}

# Node.js setup
setup_node() {
  RUNTIME_DETECTED="node"
  log "Detected Node.js project."
  # Install Node.js if not present
  if ! has_cmd node || ! has_cmd npm; then
    case "$OS_FAMILY" in
      debian) install_pkgs nodejs npm ;;
      alpine) install_pkgs nodejs npm ;;
      redhat) install_pkgs nodejs npm || warn "Node.js packages not available by default on this image." ;;
      suse)   install_pkgs nodejs14 npm14 || install_pkgs nodejs npm ;;
      *) warn "Node.js not installed and package manager unknown. Please use a Node base image."; return ;;
    esac
  fi

  # Choose package manager: pnpm > yarn > npm
  local pm="npm"
  if file_exists "$PROJECT_ROOT/pnpm-lock.yaml"; then
    pm="pnpm"
    if ! has_cmd pnpm; then
      warn "pnpm not found; installing via npm."
      npm install -g pnpm@latest || warn "Failed to install pnpm globally."
    fi
  elif file_exists "$PROJECT_ROOT/yarn.lock"; then
    pm="yarn"
    if ! has_cmd yarn; then
      warn "yarn not found; installing via npm."
      npm install -g yarn@latest || warn "Failed to install yarn globally."
    fi
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  export NODE_ENV="${NODE_ENV:-production}"

  if [ "$pm" = "pnpm" ]; then
    log "Installing Node.js dependencies with pnpm"
    pnpm install --frozen-lockfile || pnpm install
  elif [ "$pm" = "yarn" ]; then
    log "Installing Node.js dependencies with yarn"
    yarn install --frozen-lockfile || yarn install
  else
    if file_exists "$PROJECT_ROOT/package-lock.json"; then
      log "Installing Node.js dependencies with npm ci"
      npm ci || npm install
    else
      log "Installing Node.js dependencies with npm install"
      npm install
    fi
  fi
  popd >/dev/null
}

# Ruby setup
setup_ruby() {
  RUNTIME_DETECTED="ruby"
  log "Detected Ruby project."
  if ! has_cmd ruby; then
    case "$OS_FAMILY" in
      debian) install_pkgs ruby-full build-essential ;;
      alpine) install_pkgs ruby ruby-bundler build-base ;;
      redhat) install_pkgs ruby ruby-devel gcc make ;;
      suse)   install_pkgs ruby ruby-devel gcc make ;;
      *) warn "Ruby not installed and package manager unknown. Please use a Ruby base image."; return ;;
    esac
  fi
  if ! has_cmd bundler; then
    gem install bundler --no-document || warn "Failed to install bundler. Continuing."
  fi
  pushd "$PROJECT_ROOT" >/dev/null
  bundle config set --local path 'vendor/bundle'
  bundle config set --local deployment 'true'
  bundle install --jobs "$(nproc 2>/dev/null || echo 2)" || warn "Bundle install failed."
  popd >/dev/null
}

# Go setup
setup_go() {
  RUNTIME_DETECTED="go"
  log "Detected Go project."
  if ! has_cmd go; then
    case "$OS_FAMILY" in
      debian) install_pkgs golang ;;
      alpine) install_pkgs go ;;
      redhat) install_pkgs golang ;;
      suse)   install_pkgs go ;;
      *) warn "Go not installed and package manager unknown. Please use a Go base image."; return ;;
    esac
  fi
  pushd "$PROJECT_ROOT" >/dev/null
  if file_exists "$PROJECT_ROOT/go.mod"; then
    log "Downloading Go modules"
    go mod download || warn "go mod download failed."
  fi
  popd >/dev/null
}

# Java setup (Maven/Gradle)
setup_java() {
  RUNTIME_DETECTED="java"
  log "Detected Java project."
  # Install JDK
  if ! has_cmd java; then
    case "$OS_FAMILY" in
      debian) install_pkgs openjdk-17-jdk || install_pkgs openjdk-11-jdk ;;
      alpine) install_pkgs openjdk17-jdk || install_pkgs openjdk11 ;;
      redhat) install_pkgs java-17-openjdk-devel || install_pkgs java-11-openjdk-devel ;;
      suse)   install_pkgs java-17-openjdk-devel || install_pkgs java-11-openjdk-devel ;;
      *) warn "Java not installed and package manager unknown. Please use a JDK base image."; return ;;
    esac
  fi
  pushd "$PROJECT_ROOT" >/dev/null
  if file_exists "$PROJECT_ROOT/mvnw" || file_exists "$PROJECT_ROOT/pom.xml"; then
    if file_exists "$PROJECT_ROOT/mvnw"; then
      log "Using Maven Wrapper to fetch dependencies"
      chmod +x mvnw
      ./mvnw -q -B -DskipTests dependency:go-offline || warn "Maven wrapper dependency resolution failed."
    else
      if ! has_cmd mvn; then
        install_pkg maven
      fi
      mvn -q -B -DskipTests dependency:go-offline || warn "Maven dependency resolution failed."
    fi
  fi
  if file_exists "$PROJECT_ROOT/gradlew" || file_exists "$PROJECT_ROOT/build.gradle"; then
    if file_exists "$PROJECT_ROOT/gradlew"; then
      log "Using Gradle Wrapper to fetch dependencies"
      chmod +x gradlew
      ./gradlew --no-daemon tasks || warn "Gradle wrapper bootstrap failed."
    else
      if ! has_cmd gradle; then
        install_pkg gradle
      fi
      gradle --no-daemon tasks || warn "Gradle bootstrap failed."
    fi
  fi
  popd >/dev/null
}

# PHP setup (Composer)
setup_php() {
  RUNTIME_DETECTED="php"
  log "Detected PHP project."
  if ! has_cmd php; then
    case "$OS_FAMILY" in
      debian) install_pkgs php-cli php-mbstring php-xml php-zip php-curl ;;
      alpine) install_pkgs php81 php81-cli php81-ctype php81-curl php81-mbstring php81-openssl php81-json php81-xml php81-zip || install_pkgs php php-cli php-zip php-xml ;;
      redhat) install_pkgs php php-cli php-zip php-xml php-mbstring ;;
      suse)   install_pkgs php php-cli php-zip php-xml php-mbstring ;;
      *) warn "PHP not installed and package manager unknown. Please use a PHP base image."; return ;;
    esac
  fi
  if ! has_cmd composer; then
    info "Installing Composer locally"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Composer installation failed."
    rm -f /tmp/composer-setup.php || true
  fi
  pushd "$PROJECT_ROOT" >/dev/null
  if file_exists "$PROJECT_ROOT/composer.json"; then
    log "Installing PHP dependencies via Composer"
    composer install --no-interaction --prefer-dist --no-progress --no-dev || composer install --no-interaction --prefer-dist --no-progress
  else
    warn "composer.json not found. Skipping Composer install."
  fi
  popd >/dev/null
}

# .NET setup
setup_dotnet() {
  RUNTIME_DETECTED="dotnet"
  log "Detected .NET project."
  if ! has_cmd dotnet; then
    warn "dotnet SDK not found. Installing dotnet SDK in a generic container is non-trivial."
    warn "Please use an official dotnet SDK base image or pre-install dotnet."
    return
  fi
  # Restore packages
  local csproj
  csproj=$(find "$PROJECT_ROOT" -maxdepth 2 -name "*.csproj" | head -n 1 || true)
  if [ -n "$csproj" ]; then
    log "Restoring .NET packages for $csproj"
    dotnet restore "$csproj" --verbosity minimal || warn "dotnet restore failed."
  else
    warn "No .csproj found. Skipping dotnet restore."
  fi
}

# Rust setup
setup_rust() {
  RUNTIME_DETECTED="rust"
  log "Detected Rust project."
  if ! has_cmd cargo; then
    info "Installing Rust via rustup (non-interactive)"
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal || warn "rustup installation failed."
    rm -f /tmp/rustup.sh || true
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  pushd "$PROJECT_ROOT" >/dev/null
  if file_exists "$PROJECT_ROOT/Cargo.toml"; then
    log "Fetching Rust dependencies (cargo fetch)"
    cargo fetch || warn "cargo fetch failed."
  fi
  popd >/dev/null
}

# Detect project type and run corresponding setup
detect_and_setup_runtime() {
  local detected=0

  # Python
  if file_exists "$PROJECT_ROOT/requirements.txt" || file_exists "$PROJECT_ROOT/pyproject.toml" || file_exists "$PROJECT_ROOT/setup.py"; then
    setup_python
    detected=1
  fi

  # Node.js
  if file_exists "$PROJECT_ROOT/package.json"; then
    setup_node
    detected=1
  fi

  # Ruby
  if file_exists "$PROJECT_ROOT/Gemfile"; then
    setup_ruby
    detected=1
  fi

  # Go
  if file_exists "$PROJECT_ROOT/go.mod"; then
    setup_go
    detected=1
  fi

  # Java Maven/Gradle
  if file_exists "$PROJECT_ROOT/pom.xml" || file_exists "$PROJECT_ROOT/mvnw" || file_exists "$PROJECT_ROOT/build.gradle" || file_exists "$PROJECT_ROOT/gradlew"; then
    setup_java
    detected=1
  fi

  # PHP
  if file_exists "$PROJECT_ROOT/composer.json"; then
    setup_php
    detected=1
  fi

  # .NET
  if [ -n "$(find "$PROJECT_ROOT" -maxdepth 2 -name "*.csproj" -print -quit || true)" ] || file_exists "$PROJECT_ROOT/global.json"; then
    setup_dotnet
    detected=1
  fi

  # Rust
  if file_exists "$PROJECT_ROOT/Cargo.toml"; then
    setup_rust
    detected=1
  fi

  if [ "$detected" -eq 0 ]; then
    warn "No supported project configuration files detected in $PROJECT_ROOT."
    warn "Supported markers: requirements.txt, pyproject.toml, package.json, Gemfile, go.mod, pom.xml, build.gradle, composer.json, *.csproj, Cargo.toml"
  fi
}

# Configure runtime defaults
configure_runtime_environment() {
  # Common environment variables
  export APP_ENV
  export PORT="${PORT:-$DEFAULT_PORT}"
  export LOG_LEVEL

  # PATH adjustments
  if [ -d "$PROJECT_ROOT/.venv/bin" ]; then
    export PATH="$PROJECT_ROOT/.venv/bin:$PATH"
    info "Prepended Python venv to PATH."
  fi
  if [ -d "$HOME/.cargo/bin" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  fi

  # Ensure logs and tmp directories are writable
  chmod -R u+rwX "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" 2>/dev/null || true

  log "Runtime environment configured. APP_ENV=$APP_ENV, PORT=$PORT, LOG_LEVEL=$LOG_LEVEL"
}

# Main
main() {
  log "Starting project environment setup in Docker container..."
  detect_privileges
  detect_pkg_manager
  setup_project_structure
  setup_env_file
  load_env

  install_base_tools

  detect_and_setup_runtime

  configure_runtime_environment

  log "Environment setup completed successfully."
  info "Project root: $PROJECT_ROOT"
  info "Detected runtime: ${RUNTIME_DETECTED:-none}"
  info "You can now run your application according to its framework (e.g., Python: source .venv/bin/activate && python app.py; Node: npm start; Java: ./mvnw spring-boot:run; etc.)."
}

main "$@"