#!/usr/bin/env bash
# Environment setup script for containerized projects (polyglot support)
# This script detects common project types (Python, Node.js, Ruby, PHP, Go, Rust, Java)
# and installs required runtimes and dependencies using the available package manager.
# It is designed to run inside Docker containers as root without sudo.
#
# Usage:
#   ./setup.sh               # run from project root or set PROJECT_ROOT
#   PROJECT_ROOT=/app ./setup.sh
#
# Idempotent: safe to run multiple times.

set -Eeuo pipefail

# Globals and defaults
UMASK_DEFAULT="022"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-}"
PROFILE_FILE="/etc/profile.d/project_env.sh"
LOG_FILE="${LOG_FILE:-/var/log/project_setup.log}"
RETRIES="${RETRIES:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-3}"
PATH_BACKUP="$PATH"
export DEBIAN_FRONTEND=noninteractive

# Colors for output (may be ignored by some terminals)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m' # No Color

# Logging
log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"
}
warn() {
  echo -e "${YELLOW}[WARN] $*${NC}" | tee -a "$LOG_FILE" >&2
}
err() {
  echo -e "${RED}[ERROR] $*${NC}" | tee -a "$LOG_FILE" >&2
}
trap 'err "Setup failed at line $LINENO. See $LOG_FILE for details."' ERR

# Retry helper for transient network failures
with_retries() {
  local tries=0
  local exit_code=0
  until "$@"; do
    exit_code=$?
    tries=$((tries + 1))
    if [ "$tries" -ge "$RETRIES" ]; then
      err "Command failed after $RETRIES attempts: $* (exit code $exit_code)"
      return "$exit_code"
    fi
    warn "Command failed (exit $exit_code). Retrying $tries/$RETRIES in ${RETRY_DELAY_SECONDS}s: $*"
    sleep "$RETRY_DELAY_SECONDS"
  done
  return 0
}

# System/package manager detection
OS_ID=""
OS_VERSION_ID=""
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""

detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
  fi
}

detect_pkg_manager() {
  case "$OS_ID" in
    alpine)
      PKG_MANAGER="apk"
      PKG_UPDATE="apk update"
      PKG_INSTALL="apk add --no-cache"
      PKG_CLEAN="true"
      ;;
    debian|ubuntu)
      PKG_MANAGER="apt"
      PKG_UPDATE="apt-get update -y"
      PKG_INSTALL="apt-get install -y --no-install-recommends"
      PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
      ;;
    centos|rhel)
      if command -v microdnf >/dev/null 2>&1; then
        PKG_MANAGER="microdnf"
        PKG_UPDATE="microdnf update -y || true"
        PKG_INSTALL="microdnf install -y"
        PKG_CLEAN="microdnf clean all || true"
      else
        PKG_MANAGER="yum"
        PKG_UPDATE="yum makecache -y || true"
        PKG_INSTALL="yum install -y"
        PKG_CLEAN="yum clean all || true"
      fi
      ;;
    fedora)
      PKG_MANAGER="dnf"
      PKG_UPDATE="dnf makecache -y || true"
      PKG_INSTALL="dnf install -y"
      PKG_CLEAN="dnf clean all || true"
      ;;
    *)
      # Fallback detection
      if command -v apk >/dev/null 2>&1; then
        OS_ID="alpine"; detect_pkg_manager
      elif command -v apt-get >/dev/null 2>&1; then
        OS_ID="debian"; detect_pkg_manager
      elif command -v dnf >/dev/null 2>&1; then
        OS_ID="fedora"; detect_pkg_manager
      elif command -v yum >/dev/null 2>&1; then
        OS_ID="centos"; detect_pkg_manager
      else
        err "Unsupported or unknown base image. No known package manager found."
        exit 1
      fi
      ;;
  esac
}

# Base system packages
install_base_system() {
  log "Installing base system packages using $PKG_MANAGER..."
  case "$PKG_MANAGER" in
    apk)
      with_retries $PKG_UPDATE
      with_retries $PKG_INSTALL \
        bash ca-certificates curl git openssh shadow \
        build-base pkgconfig jq openssl-dev zlib-dev \
        tar xz gzip unzip bzip2 findutils coreutils
      $PKG_CLEAN
      update-ca-certificates || true
      ;;
    apt)
      with_retries $PKG_UPDATE
      with_retries $PKG_INSTALL \
        bash ca-certificates curl git gnupg \
        build-essential pkg-config jq openssl zlib1g-dev \
        tar xz-utils gzip unzip bzip2 findutils coreutils \
        libffi-dev libssl-dev
      $PKG_CLEAN
      update-ca-certificates || true
      ;;
    yum|dnf|microdnf)
      with_retries $PKG_UPDATE
      with_retries $PKG_INSTALL \
        bash ca-certificates curl git \
        gcc gcc-c++ make pkgconfig jq openssl openssl-devel zlib zlib-devel \
        tar xz gzip unzip bzip2 findutils coreutils shadow-utils
      $PKG_CLEAN
      update-ca-trust || true
      ;;
  esac
  log "Base system packages installed."
}

# User and directory setup
ensure_app_user() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root. System package installation may fail. Proceeding with user-level setup."
    return 0
  fi

  if id "$APP_USER" >/dev/null 2>&1; then
    log "User $APP_USER already exists."
  else
    log "Creating application user and group: $APP_USER"
    if [ "$OS_ID" = "alpine" ]; then
      addgroup -S "$APP_GROUP" || true
      adduser -S -D -H -G "$APP_GROUP" -s /sbin/nologin "$APP_USER" || true
    else
      groupadd -r "$APP_GROUP" 2>/dev/null || true
      useradd -r -m -d "/home/$APP_USER" -g "$APP_GROUP" -s /usr/sbin/nologin "$APP_USER" 2>/dev/null || true
    fi
  fi
}

setup_project_dirs() {
  umask "$UMASK_DEFAULT"
  mkdir -p "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,data}
  touch "$LOG_FILE" || true

  if [ "$(id -u)" -eq 0 ] && id "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT" || true
    chown -R "$APP_USER:$APP_GROUP" "$(dirname "$LOG_FILE")" || true
  fi

  log "Project root set to: $PROJECT_ROOT"
}

# Detection of project types
has_file() { [ -f "$PROJECT_ROOT/$1" ]; }
has_any() {
  for f in "$@"; do
    if has_file "$f"; then return 0; fi
  done
  return 1
}

detect_project_types() {
  PROJECT_TYPES=()

  # Python
  if has_any "requirements.txt" "pyproject.toml" "Pipfile" "setup.py"; then
    PROJECT_TYPES+=("python")
  fi
  # Node.js
  if has_file "package.json"; then
    PROJECT_TYPES+=("node")
  fi
  # Ruby
  if has_file "Gemfile"; then
    PROJECT_TYPES+=("ruby")
  fi
  # PHP
  if has_file "composer.json"; then
    PROJECT_TYPES+=("php")
  fi
  # Go
  if has_file "go.mod"; then
    PROJECT_TYPES+=("go")
  fi
  # Rust
  if has_file "Cargo.toml"; then
    PROJECT_TYPES+=("rust")
  fi
  # Java (Maven)
  if has_file "pom.xml"; then
    PROJECT_TYPES+=("java_maven")
  fi
  # Java (Gradle)
  if has_any "build.gradle" "build.gradle.kts" "gradlew"; then
    PROJECT_TYPES+=("java_gradle")
  fi
  # .NET
  if ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then
    PROJECT_TYPES+=("dotnet")
  fi

  if [ "${#PROJECT_TYPES[@]}" -eq 0 ]; then
    warn "No recognized project files found in $PROJECT_ROOT. Proceeding with base setup."
  else
    log "Detected project types: ${PROJECT_TYPES[*]}"
  fi
}

# Language-specific setup functions

setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MANAGER" in
    apk)
      with_retries $PKG_INSTALL python3 py3-pip python3-dev
      ;;
    apt)
      with_retries $PKG_INSTALL python3 python3-pip python3-venv python3-dev
      ;;
    yum|dnf|microdnf)
      with_retries $PKG_INSTALL python3 python3-pip python3-devel
      ;;
  esac

  PIP_BIN="pip3"
  PY_BIN="python3"
  if ! command -v python3 >/dev/null 2>&1; then
    err "Python3 could not be installed."
    return 1
  fi
  if ! command -v pip3 >/dev/null 2>&1; then
    err "pip3 could not be installed."
    return 1
  fi

  # Allow pip to install into system site-packages on PEP 668 managed systems
  python3 -m pip config --global set global.break-system-packages true || true

  VENV_DIR="$PROJECT_ROOT/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtual environment at $VENV_DIR"
    "$PY_BIN" -m venv "$VENV_DIR"
  else
    log "Virtual environment already exists at $VENV_DIR"
  fi

  # Activate venv for local installs
  # shellcheck disable=SC1091
  . "$VENV_DIR/bin/activate"
  "$PIP_BIN" install --no-cache-dir --upgrade pip setuptools wheel

  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    with_retries "$PIP_BIN" install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt"
  elif has_file "pyproject.toml"; then
    log "Installing Python project from pyproject.toml"
    with_retries "$PIP_BIN" install --no-cache-dir "$PROJECT_ROOT"
  elif has_file "Pipfile"; then
    log "Pipfile detected. Installing pipenv and dependencies."
    with_retries "$PIP_BIN" install --no-cache-dir pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --system --deploy || PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
  elif has_file "setup.py"; then
    log "Installing Python package in editable mode (setup.py)"
    with_retries "$PIP_BIN" install --no-cache-dir -e "$PROJECT_ROOT"
  fi

  # Determine default port heuristically
  if [ -z "$APP_PORT" ]; then
    if has_file "app.py"; then
      APP_PORT="5000"
    else
      APP_PORT="8000"
    fi
  fi

  # Persist environment
  add_env "PYTHONUNBUFFERED" "1"
  add_env "PIP_NO_CACHE_DIR" "1"
  add_env "VIRTUAL_ENV" "$VENV_DIR"
  add_path "$VENV_DIR/bin"

  log "Python environment configured."
}

setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MANAGER" in
    apk)
      with_retries $PKG_INSTALL nodejs npm
      ;;
    apt)
      with_retries $PKG_INSTALL nodejs npm
      ;;
    yum|dnf|microdnf)
      # Node availability varies; attempt install
      if [ "$PKG_MANAGER" = "microdnf" ]; then
        with_retries $PKG_INSTALL nodejs npm || warn "Node.js packages not available in microdnf base repos."
      else
        with_retries $PKG_INSTALL nodejs npm || warn "Node.js packages may require EPEL or alternate repos."
      fi
      ;;
  esac

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    warn "Node.js/npm not found via package manager. Attempting to install via n (node version manager)."
    curl -fsSL https://raw.githubusercontent.com/tj/n/master/bin/n -o /usr/local/bin/n
    chmod +x /usr/local/bin/n
    with_retries n lts || err "Failed to install Node.js via n. Please ensure network access or use a Node base image."
  fi

  if has_file "package.json"; then
    pushd "$PROJECT_ROOT" >/dev/null
    if has_file "package-lock.json"; then
      log "Installing Node.js dependencies via npm ci"
      with_retries npm ci --omit=dev
    else
      log "Installing Node.js dependencies via npm install"
      with_retries npm install --omit=dev
    fi
    popd >/dev/null
  fi

  # Default port
  if [ -z "$APP_PORT" ]; then
    APP_PORT="3000"
  fi

  add_env "NODE_ENV" "$APP_ENV"
  add_env "NPM_CONFIG_LOGLEVEL" "warn"
  log "Node.js environment configured."
}

setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apk)
      with_retries $PKG_INSTALL ruby ruby-bundler ruby-dev
      ;;
    apt)
      with_retries $PKG_INSTALL ruby-full
      ;;
    yum|dnf|microdnf)
      with_retries $PKG_INSTALL ruby ruby-devel
      ;;
  esac

  if ! command -v gem >/dev/null 2>&1; then
    err "Ruby gem tool not available."
    return 1
  fi

  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document || true
  fi

  if has_file "Gemfile"; then
    pushd "$PROJECT_ROOT" >/dev/null
    export BUNDLE_PATH="$PROJECT_ROOT/vendor/bundle"
    bundle config set without 'development test' || true
    if has_file "Gemfile.lock"; then
      with_retries bundle install --jobs "$(nproc)" --deployment
    else
      with_retries bundle install --jobs "$(nproc)"
    fi
    popd >/dev/null
  fi

  if [ -z "$APP_PORT" ]; then
    APP_PORT="3000"
  fi

  add_env "BUNDLE_PATH" "$PROJECT_ROOT/vendor/bundle"
  log "Ruby environment configured."
}

setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apk)
      with_retries $PKG_INSTALL php-cli php-json php-openssl php-xml php-mbstring php-phar php-tokenizer composer
      ;;
    apt)
      with_retries $PKG_INSTALL php-cli php-json php-xml php-mbstring php-curl composer
      ;;
    yum|dnf|microdnf)
      with_retries $PKG_INSTALL php-cli php-json php-xml php-mbstring curl || true
      if ! command -v composer >/dev/null 2>&1; then
        with_retries curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
      fi
      ;;
  esac

  if has_file "composer.json"; then
    pushd "$PROJECT_ROOT" >/dev/null
    with_retries composer install --no-dev --no-interaction --prefer-dist
    popd >/dev/null
  fi

  if [ -z "$APP_PORT" ]; then
    APP_PORT="8000"
  fi

  add_env "COMPOSER_NO_INTERACTION" "1"
  add_env "COMPOSER_CACHE_DIR" "$PROJECT_ROOT/.composer"
  log "PHP environment configured."
}

setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apk)
      with_retries $PKG_INSTALL go
      ;;
    apt)
      with_retries $PKG_INSTALL golang
      ;;
    yum|dnf|microdnf)
      with_retries $PKG_INSTALL golang
      ;;
  esac

  if ! command -v go >/dev/null 2>&1; then
    err "Go toolchain not found."
    return 1
  fi

  GOPATH_DIR="$PROJECT_ROOT/.gopath"
  mkdir -p "$GOPATH_DIR"
  add_env "GOPATH" "$GOPATH_DIR"
  add_path "$GOPATH_DIR/bin"

  if has_file "go.mod"; then
    pushd "$PROJECT_ROOT" >/dev/null
    with_retries go mod download
    popd >/dev/null
  fi

  if [ -z "$APP_PORT" ]; then
    APP_PORT="8080"
  fi

  log "Go environment configured."
}

setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MANAGER" in
    apk)
      with_retries $PKG_INSTALL rust cargo
      ;;
    apt)
      with_retries $PKG_INSTALL cargo rustc
      ;;
    yum|dnf|microdnf)
      with_retries $PKG_INSTALL cargo rust
      ;;
  esac

  if ! command -v cargo >/dev/null 2>&1; then
    warn "Cargo not found via package manager. Attempting rustup (network required)."
    with_retries curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env" || true
  fi

  if has_file "Cargo.toml"; then
    pushd "$PROJECT_ROOT" >/dev/null
    with_retries cargo fetch
    popd >/dev/null
  fi

  if [ -z "$APP_PORT" ]; then
    APP_PORT="8080"
  fi

  add_path "$HOME/.cargo/bin"
  log "Rust environment configured."
}

setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "$PKG_MANAGER" in
    apk)
      with_retries $PKG_INSTALL openjdk17-jdk maven
      ;;
    apt)
      with_retries $PKG_INSTALL openjdk-17-jdk maven
      ;;
    yum|dnf|microdnf)
      with_retries $PKG_INSTALL java-17-openjdk java-17-openjdk-devel maven
      ;;
  esac

  if ! command -v mvn >/dev/null 2>&1; then
    err "Maven not found."
    return 1
  fi

  if has_file "pom.xml"; then
    pushd "$PROJECT_ROOT" >/dev/null
    with_retries mvn -B -ntp -DskipTests dependency:go-offline
    popd >/dev/null
  fi

  if [ -z "$APP_PORT" ]; then
    APP_PORT="8080"
  fi

  add_env "JAVA_TOOL_OPTIONS" "-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"
  log "Java (Maven) environment configured."
}

setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  local gradle_cmd=""
  if has_file "gradlew"; then
    gradle_cmd="$PROJECT_ROOT/gradlew"
    chmod +x "$gradle_cmd" || true
  else
    case "$PKG_MANAGER" in
      apk)
        with_retries $PKG_INSTALL openjdk17-jdk gradle
        ;;
      apt)
        with_retries $PKG_INSTALL openjdk-17-jdk gradle
        ;;
      yum|dnf|microdnf)
        with_retries $PKG_INSTALL java-17-openjdk java-17-openjdk-devel gradle
        ;;
    esac
    gradle_cmd="gradle"
  fi

  if ! command -v "$gradle_cmd" >/dev/null 2>&1 && ! [ -x "$gradle_cmd" ]; then
    err "Gradle not available."
    return 1
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  with_retries "$gradle_cmd" --no-daemon -v >/dev/null || true
  # Prepare dependencies offline (best-effort)
  with_retries "$gradle_cmd" --no-daemon build -x test || true
  popd >/dev/null

  if [ -z "$APP_PORT" ]; then
    APP_PORT="8080"
  fi

  add_env "JAVA_TOOL_OPTIONS" "-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"
  log "Java (Gradle) environment configured."
}

setup_dotnet() {
  log "Setting up .NET environment..."
  # Installing dotnet SDK/Runtime via package manager is distro-specific and heavy.
  # We attempt a best-effort install, but using a dotnet base image is recommended.
  case "$PKG_MANAGER" in
    apt)
      warn "Installing .NET via apt requires Microsoft package feed; skipping automatic install."
      ;;
    apk|yum|dnf|microdnf)
      warn ".NET installation not supported via this package manager in this script. Use a dotnet base image."
      ;;
  esac

  if ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then
    if command -v dotnet >/dev/null 2>&1; then
      pushd "$PROJECT_ROOT" >/dev/null
      with_retries dotnet restore
      popd >/dev/null
      [ -z "$APP_PORT" ] && APP_PORT="8080"
      log ".NET restore completed."
    else
      warn "dotnet CLI not found. Skipping .NET restore."
    fi
  fi
}

# Environment persistence helpers
add_env() {
  local key="$1"; shift
  local val="$1"; shift || true
  ensure_profile_file
  if ! grep -qE "^export ${key}=" "$PROFILE_FILE" 2>/dev/null; then
    echo "export ${key}=\"${val}\"" >> "$PROFILE_FILE"
  else
    # Update in place
    sed -i "s|^export ${key}=.*$|export ${key}=\"${val}\"|" "$PROFILE_FILE"
  fi
  export "${key}"="${val}"
}

add_path() {
  local dir="$1"
  if [ -d "$dir" ]; then
    ensure_profile_file
    if ! grep -qF "$dir" "$PROFILE_FILE" 2>/dev/null; then
      echo "export PATH=\"$dir:\$PATH\"" >> "$PROFILE_FILE"
    fi
    export PATH="$dir:$PATH"
  fi
}

ensure_profile_file() {
  if [ ! -f "$PROFILE_FILE" ]; then
    mkdir -p "$(dirname "$PROFILE_FILE")"
    cat > "$PROFILE_FILE" <<EOF
# Auto-generated environment for project
# Loaded by shell at startup
EOF
    if [ "$(id -u)" -eq 0 ]; then
      chown "$APP_USER:$APP_GROUP" "$PROFILE_FILE" 2>/dev/null || true
      chmod 0644 "$PROFILE_FILE" || true
    fi
  fi
}

finalize_env() {
  add_env "PROJECT_ROOT" "$PROJECT_ROOT"
  add_env "APP_ENV" "$APP_ENV"
  if [ -n "$APP_PORT" ]; then
    add_env "APP_PORT" "$APP_PORT"
  fi
  # Make sure PATH is sane
  add_path "/usr/local/bin"
  add_path "/usr/bin"
}

print_summary() {
  log "Environment setup completed successfully."
  echo "Summary:"
  echo "  - Project root: $PROJECT_ROOT"
  echo "  - Detected types: ${PROJECT_TYPES[*]:-none}"
  echo "  - App environment: $APP_ENV"
  echo "  - App port: ${APP_PORT:-not set}"
  echo "  - Profile file: $PROFILE_FILE"
  echo "  - Log file: $LOG_FILE"
  echo ""
  echo "Usage hints (depending on stack):"
  echo "  - Python: source \"$PROJECT_ROOT/.venv/bin/activate\" && python app.py"
  echo "  - Node.js: npm start (or node server.js)"
  echo "  - Ruby (Rails): bundle exec rails server -b 0.0.0.0 -p ${APP_PORT:-3000}"
  echo "  - PHP: php -S 0.0.0.0:${APP_PORT:-8000} -t public"
  echo "  - Go: go run ./... (or built binary in ./bin)"
  echo "  - Rust: cargo run --release"
  echo "  - Java (Maven): mvn spring-boot:run (if Spring Boot)"
  echo "  - Java (Gradle): ./gradlew bootRun (if Spring Boot)"
}

main() {
  log "Starting containerized project environment setup..."
  detect_os
  detect_pkg_manager
  ensure_app_user
  setup_project_dirs
  install_base_system

  detect_project_types

  # Install per detected type (support polyglot repos)
  for t in "${PROJECT_TYPES[@]:-}"; do
    case "$t" in
      python) setup_python ;;
      node) setup_node ;;
      ruby) setup_ruby ;;
      php) setup_php ;;
      go) setup_go ;;
      rust) setup_rust ;;
      java_maven) setup_java_maven ;;
      java_gradle) setup_java_gradle ;;
      dotnet) setup_dotnet ;;
      *) warn "Unknown project type: $t" ;;
    esac
  done

  finalize_env
  print_summary
}

# Ensure script runs as intended
main "$@" || {
  err "Setup encountered errors."
  exit 1
}