#!/usr/bin/env bash
# Environment Setup Script for Containerized Projects
# This script detects common project types (Python, Node.js, Ruby, PHP, Go, Java, Rust)
# and installs required runtimes, system packages, and dependencies.
# It is idempotent and safe to run multiple times inside Docker containers.
#
# Usage:
#   ./setup.sh
# Optional environment variables:
#   APP_DIR=/app              # Project directory (defaults to current directory)
#   APP_USER=app              # Non-root user to own app files (created if possible)
#   APP_GROUP=app             # Group for APP_USER
#   RUN_AS_ROOT=0             # Set to 1 to skip user creation and ownership changes
#   TZ=UTC                    # Timezone
#   LOCALE=en_US.UTF-8        # Locale (apt-based only)

set -Eeuo pipefail

# Global settings
readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +%s)"
APP_DIR="${APP_DIR:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
RUN_AS_ROOT="${RUN_AS_ROOT:-0}"
TZ="${TZ:-UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# Colors (basic; avoid special formatting issues in non-TTY)
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

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $*${NC}"; }
error()  { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

cleanup() {
  local code=$?
  if [ $code -ne 0 ]; then
    error "Script '${SCRIPT_NAME}' failed with exit code ${code} at line ${BASH_LINENO[0]}."
  fi
}
trap cleanup EXIT

# Utilities
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_file() { [ -f "$APP_DIR/$1" ]; }
has_dir() { [ -d "$APP_DIR/$1" ]; }
append_line_once() {
  # $1 file, $2 line
  local f="$1" line="$2"
  mkdir -p "$(dirname "$f")"
  touch "$f"
  grep -qxF "$line" "$f" || echo "$line" >> "$f"
}
# Package manager detection
PKG_MGR=""
PKG_UPDATED_MARKER="/var/tmp/.pkg_index_updated"

detect_pkg_mgr() {
  if has_cmd apt-get; then PKG_MGR="apt"; return 0; fi
  if has_cmd apk; then PKG_MGR="apk"; return 0; fi
  if has_cmd dnf; then PKG_MGR="dnf"; return 0; fi
  if has_cmd yum; then PKG_MGR="yum"; return 0; fi
  PKG_MGR=""
  return 1
}

update_pkg_index() {
  if [ -f "$PKG_UPDATED_MARKER" ]; then
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      # apk updates index automatically during add; no need
      true
      ;;
    dnf)
      dnf makecache -y || true
      ;;
    yum)
      yum makecache -y || true
      ;;
    *)
      warn "No package manager detected. Skipping index update."
      return 0
      ;;
  esac
  touch "$PKG_UPDATED_MARKER" || true
}

install_packages() {
  # Installs packages only if not already installed when possible.
  # Accepts list of packages in distro-specific names.
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@" || die "Failed to install apt packages: $*"
      ;;
    apk)
      apk add --no-cache "$@" || die "Failed to install apk packages: $*"
      ;;
    dnf)
      dnf install -y "$@" || die "Failed to install dnf packages: $*"
      ;;
    yum)
      yum install -y "$@" || die "Failed to install yum packages: $*"
      ;;
    *)
      warn "No supported package manager found; cannot install packages: $*"
      return 1
      ;;
  esac
}

install_common_base() {
  log "Installing base system packages..."
  update_pkg_index
  case "$PKG_MGR" in
    apt)
      install_packages ca-certificates curl git unzip tar xz-utils pkg-config \
        build-essential make gcc g++ libc6-dev \
        openssl libssl-dev libffi-dev zlib1g-dev \
        tzdata locales
      ;;
    apk)
      install_packages ca-certificates curl git unzip tar xz \
        pkgconfig build-base \
        openssl openssl-dev libffi libffi-dev zlib tzdata
      ;;
    dnf|yum)
      install_packages ca-certificates curl git unzip tar xz \
        pkgconfig gcc gcc-c++ make glibc-devel \
        openssl openssl-devel libffi libffi-devel zlib zlib-devel tzdata
      ;;
    *)
      warn "Skipped base packages installation due to missing package manager."
      ;;
  esac
  # Ensure CA certificates up-to-date
  if has_cmd update-ca-certificates; then update-ca-certificates || true; fi
  # Timezone setup
  if [ -n "${TZ:-}" ]; then
    if [ -d /usr/share/zoneinfo ] && [ -e "/usr/share/zoneinfo/$TZ" ]; then
      ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
      echo "$TZ" > /etc/timezone || true
      log "Timezone set to $TZ"
    else
      warn "Timezone $TZ not found on system."
    fi
  fi
  # Locale setup for apt-based images
  if [ "$PKG_MGR" = "apt" ]; then
    if has_cmd locale-gen; then
      sed -i "s/^# *$LOCALE/$LOCALE/" /etc/locale.gen 2>/dev/null || echo "$LOCALE UTF-8" >> /etc/locale.gen
      locale-gen || true
      update-locale LANG="$LOCALE" || true
    fi
  fi
}

ensure_directories() {
  log "Ensuring project directory structure at '$APP_DIR'..."
  mkdir -p "$APP_DIR"
  mkdir -p "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/.cache"
  # Create standard environment file if missing
  if ! has_file ".env"; then
    echo "PORT=${PORT:-8080}" > "$APP_DIR/.env"
    echo "ENV=${ENV:-production}" >> "$APP_DIR/.env"
    echo "APP_DIR=${APP_DIR}" >> "$APP_DIR/.env"
    log "Created default .env file."
  fi
}

create_app_user() {
  if [ "$RUN_AS_ROOT" = "1" ]; then
    warn "RUN_AS_ROOT=1 set; skipping user creation and ownership changes."
    return 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root; cannot create app user. Continuing as current user."
    return 0
  fi
  # Create group if possible
  if has_cmd getent && getent group "$APP_GROUP" >/dev/null 2>&1; then
    true
  else
    if has_cmd addgroup; then
      addgroup -S "$APP_GROUP" || true
    elif has_cmd groupadd; then
      groupadd -r "$APP_GROUP" || true
    else
      warn "No group creation tool available."
    fi
  fi
  # Create user if possible
  if has_cmd id && id -u "$APP_USER" >/dev/null 2>&1; then
    true
  else
    if has_cmd adduser; then
      # Alpine/busybox
      adduser -S -D -H -G "$APP_GROUP" "$APP_USER" || true
    elif has_cmd useradd; then
      useradd -r -M -s /sbin/nologin -g "$APP_GROUP" "$APP_USER" || true
    else
      warn "No user creation tool available."
    fi
  fi
  chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR" || true
}

# ---------- Language/runtime installation ----------

# Python
PYTHON_DETECTED=0
PY_VENV_PATH="$APP_DIR/.venv"
ensure_python_runtime() {
  log "Checking for Python project files..."
  if has_file "requirements.txt" || has_file "pyproject.toml" || has_file "setup.py"; then
    PYTHON_DETECTED=1
    log "Python project detected."
    update_pkg_index
    case "$PKG_MGR" in
      apt)
        install_packages python3 python3-pip python3-venv python3-dev
        ;;
      apk)
        install_packages python3 py3-pip python3-dev
        # venv is included in python3 on Alpine
        ;;
      dnf|yum)
        install_packages python3 python3-pip python3-devel
        ;;
      *)
        warn "Package manager not available; assuming Python is pre-installed."
        ;;
    esac
    if ! has_cmd python3; then die "python3 not found after installation."; fi
    if ! has_cmd pip3 && ! has_cmd pip; then die "pip not found after installation."; fi

    # Create/activate venv idempotently
    if [ ! -d "$PY_VENV_PATH" ]; then
      log "Creating Python virtual environment at $PY_VENV_PATH..."
      python3 -m venv "$PY_VENV_PATH" || die "Failed to create Python venv."
    else
      log "Python virtual environment already exists."
    fi
    # shellcheck disable=SC1090
    source "$PY_VENV_PATH/bin/activate"
    python -m pip install --upgrade pip setuptools wheel || die "Failed to upgrade pip/setuptools/wheel."

    if has_file "requirements.txt"; then
      log "Installing Python dependencies from requirements.txt..."
      # Backup and ensure FastAPI is compatible with Pydantic v2
      cp "$APP_DIR/requirements.txt" "$APP_DIR/requirements.txt.bak" || true
      sed -i -E 's/^[[:space:]]*fastapi(\[[^]]+\])?.*$/fastapi\1>=0.100.0/' "$APP_DIR/requirements.txt" || true
      pip install -r "$APP_DIR/requirements.txt" || die "pip install requirements failed."
    elif has_file "pyproject.toml"; then
      log "Installing Python project via pyproject.toml..."
      if has_cmd pip; then
        pip install . || warn "pip install . failed; ensure pyproject.toml uses PEP 517 build backend."
      fi
    fi
    # Common Python env vars
    append_line_once "$APP_DIR/.env" "PYTHONUNBUFFERED=1"
    append_line_once "$APP_DIR/.env" "PIP_DISABLE_PIP_VERSION_CHECK=1"
  else
    log "No Python project detected."
  fi
}

# Node.js
NODE_DETECTED=0
ensure_node_runtime() {
  log "Checking for Node.js project files..."
  if has_file "package.json"; then
    NODE_DETECTED=1
    log "Node.js project detected."
    update_pkg_index
    case "$PKG_MGR" in
      apt)
        # Try distro packages first
        install_packages nodejs npm
        ;;
      apk)
        install_packages nodejs npm
        ;;
      dnf|yum)
        install_packages nodejs npm
        ;;
      *)
        warn "Package manager not available; ensure Node.js is present."
        ;;
    esac
    if ! has_cmd node || ! has_cmd npm; then
      warn "node/npm not found after installation."
    fi

    # Install dependencies
    if has_file "package-lock.json"; then
      log "Installing Node dependencies via npm ci..."
      npm ci --no-audit --no-fund || die "npm ci failed."
    else
      log "Installing Node dependencies via npm install..."
      npm install --no-audit --no-fund || die "npm install failed."
    fi
    # Add Yarn support if yarn.lock exists
    if has_file "yarn.lock"; then
      log "Detected yarn.lock; installing yarn..."
      case "$PKG_MGR" in
        apt) install_packages yarn || npm i -g yarn || true ;;
        apk) npm i -g yarn || true ;;
        dnf|yum) npm i -g yarn || true ;;
        *) npm i -g yarn || true ;;
      esac
      if has_cmd yarn; then
        yarn install --frozen-lockfile || warn "yarn install failed."
      fi
    fi

    # Add node_modules/.bin to PATH
    append_line_once "/etc/profile.d/app_path.sh" "export PATH=\"$APP_DIR/node_modules/.bin:\$PATH\""
  else
    log "No Node.js project detected."
  fi
}

# Ruby
RUBY_DETECTED=0
ensure_ruby_runtime() {
  log "Checking for Ruby project files..."
  if has_file "Gemfile"; then
    RUBY_DETECTED=1
    log "Ruby project detected."
    update_pkg_index
    case "$PKG_MGR" in
      apt)
        install_packages ruby ruby-dev bundler
        ;;
      apk)
        install_packages ruby ruby-dev ruby-bundler build-base
        ;;
      dnf|yum)
        install_packages ruby ruby-devel rubygems
        ;;
      *)
        warn "Package manager not available; ensure Ruby is present."
        ;;
    esac
    if ! has_cmd bundler; then gem install bundler || true; fi
    if has_cmd bundle; then
      log "Installing Ruby gems..."
      bundle config set path "$APP_DIR/vendor/bundle" || true
      bundle install || warn "bundle install failed."
    fi
    append_line_once "/etc/profile.d/app_path.sh" "export PATH=\"$APP_DIR/vendor/bundle/ruby/*/bin:\$PATH\""
  else
    log "No Ruby project detected."
  fi
}

# PHP
PHP_DETECTED=0
ensure_php_runtime() {
  log "Checking for PHP project files..."
  if has_file "composer.json"; then
    PHP_DETECTED=1
    log "PHP project detected."
    update_pkg_index
    case "$PKG_MGR" in
      apt)
        install_packages php-cli php-xml php-mbstring php-curl php-zip unzip
        ;;
      apk)
        install_packages php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip || install_packages php php-cli php-mbstring php-xml php-curl php-zip
        ;;
      dnf|yum)
        install_packages php-cli php-xml php-mbstring php-curl php-zip
        ;;
      *)
        warn "Package manager not available; ensure PHP is present."
        ;;
    esac
    # Composer
    if ! has_cmd composer; then
      log "Installing Composer..."
      curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Composer installation failed."
      rm -f /tmp/composer-setup.php || true
    fi
    if has_cmd composer; then
      log "Installing PHP dependencies via composer..."
      composer install --no-interaction --prefer-dist || warn "composer install failed."
    fi
  else
    log "No PHP project detected."
  fi
}

# Go
GO_DETECTED=0
ensure_go_runtime() {
  log "Checking for Go project files..."
  if has_file "go.mod" || has_file "go.sum"; then
    GO_DETECTED=1
    log "Go project detected."
    update_pkg_index
    case "$PKG_MGR" in
      apt) install_packages golang ;;
      apk) install_packages go ;;
      dnf|yum) install_packages golang ;;
      *) warn "Package manager not available; ensure Go is present." ;;
    esac
    if has_cmd go; then
      log "Downloading Go modules..."
      go mod download || warn "go mod download failed."
    fi
  else
    log "No Go project detected."
  fi
}

# Java/Maven/Gradle
JAVA_DETECTED=0
ensure_java_runtime() {
  log "Checking for Java project files..."
  if has_file "pom.xml" || has_file "build.gradle" || has_file "build.gradle.kts" || has_file "gradlew"; then
    JAVA_DETECTED=1
    log "Java project detected."
    update_pkg_index
    case "$PKG_MGR" in
      apt) install_packages openjdk-17-jdk || install_packages openjdk-11-jdk ;;
      apk) install_packages openjdk17 || install_packages openjdk11 ;;
      dnf|yum) install_packages java-17-openjdk-devel || install_packages java-11-openjdk-devel ;;
      *) warn "Package manager not available; ensure Java is present." ;;
    esac
    # Maven/Gradle
    if has_file "pom.xml"; then
      case "$PKG_MGR" in
        apt) install_packages maven ;;
        apk) install_packages maven ;;
        dnf|yum) install_packages maven ;;
        *) warn "Cannot install Maven without package manager." ;;
      esac
      if has_cmd mvn; then
        log "Resolving Maven dependencies..."
        mvn -q -DskipTests dependency:resolve || warn "mvn dependency resolve failed."
      fi
    fi
    if has_file "build.gradle" || has_file "build.gradle.kts"; then
      if has_file "gradlew"; then
        chmod +x "$APP_DIR/gradlew" || true
        log "Resolving Gradle dependencies via wrapper..."
        "$APP_DIR/gradlew" build -x test || warn "gradle build failed."
      else
        case "$PKG_MGR" in
          apt) install_packages gradle ;;
          apk) install_packages gradle ;;
          dnf|yum) install_packages gradle ;;
          *) warn "Cannot install Gradle without package manager." ;;
        esac
        if has_cmd gradle; then
          gradle build -x test || warn "gradle build failed."
        fi
      fi
    fi
  else
    log "No Java project detected."
  fi
}

# Rust
RUST_DETECTED=0
ensure_rust_runtime() {
  log "Checking for Rust project files..."
  if has_file "Cargo.toml"; then
    RUST_DETECTED=1
    log "Rust project detected."
    if ! has_cmd cargo; then
      update_pkg_index
      case "$PKG_MGR" in
        apt) install_packages cargo || true ;;
        apk) install_packages cargo || true ;;
        dnf|yum) install_packages cargo || true ;;
        *) warn "Package manager not available; attempting rustup installation." ;;
      esac
      if ! has_cmd cargo; then
        log "Installing Rust via rustup (stable)..."
        curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
        sh /tmp/rustup.sh -y --default-toolchain stable || warn "rustup install failed."
        rm -f /tmp/rustup.sh || true
        export PATH="$HOME/.cargo/bin:$PATH"
        append_line_once "/etc/profile.d/app_path.sh" "export PATH=\"\$HOME/.cargo/bin:\$PATH\""
      fi
    fi
    if has_cmd cargo; then
      log "Fetching Rust dependencies..."
      cargo fetch || warn "cargo fetch failed."
    fi
  else
    log "No Rust project detected."
  fi
}

# ---------- Environment configuration ----------

detect_app_type_and_port() {
  local port_default=8080
  local app_type="generic"

  # Python heuristics
  if [ "$PYTHON_DETECTED" -eq 1 ]; then
    if has_file "requirements.txt"; then
      if grep -qiE 'flask' "$APP_DIR/requirements.txt"; then
        app_type="python-flask"
        port_default=5000
        append_line_once "$APP_DIR/.env" "FLASK_APP=${FLASK_APP:-app.py}"
        append_line_once "$APP_DIR/.env" "FLASK_ENV=${FLASK_ENV:-production}"
      elif grep -qiE 'django' "$APP_DIR/requirements.txt"; then
        app_type="python-django"
        port_default=8000
        append_line_once "$APP_DIR/.env" "DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE:-project.settings}"
      else
        app_type="python"
        port_default=8000
      fi
    elif has_file "pyproject.toml"; then
      app_type="python"
      port_default=8000
    fi
  fi

  # Node heuristics
  if [ "$NODE_DETECTED" -eq 1 ]; then
    app_type="node"
    port_default=3000
    # Try to detect framework from package.json
    if has_file "package.json"; then
      if grep -qi '"express"' "$APP_DIR/package.json"; then app_type="node-express"; fi
      if grep -qi '"next"' "$APP_DIR/package.json"; then app_type="node-next"; fi
      if grep -qi '"nestjs"' "$APP_DIR/package.json"; then app_type="node-nest"; fi
    fi
  fi

  if [ "$RUBY_DETECTED" -eq 1 ]; then
    app_type="ruby"
    port_default=3000
  fi
  if [ "$PHP_DETECTED" -eq 1 ]; then
    app_type="php"
    port_default=8000
  fi
  if [ "$GO_DETECTED" -eq 1 ]; then
    app_type="go"
    port_default=8080
  fi
  if [ "$JAVA_DETECTED" -eq 1 ]; then
    app_type="java"
    port_default=8080
  fi
  if [ "$RUST_DETECTED" -eq 1 ]; then
    app_type="rust"
    port_default=8080
  fi

  # Set PORT in .env if not set
  if ! grep -q '^PORT=' "$APP_DIR/.env"; then
    append_line_once "$APP_DIR/.env" "PORT=${PORT:-$port_default}"
  fi

  log "Detected app type: $app_type. Default PORT set to ${PORT:-$port_default}."
}

configure_paths_env() {
  # Persist PATH additions and generic env vars
  append_line_once "/etc/profile.d/app_path.sh" "export PATH=\"$APP_DIR/.venv/bin:\$PATH\""
  append_line_once "$APP_DIR/.env" "APP_DIR=$APP_DIR"
  append_line_once "$APP_DIR/.env" "ENV=${ENV:-production}"
}

# Configure auto-activation of Python virtual environment for interactive shells
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local venv_path="$PY_VENV_PATH"
  local activate_line="source $venv_path/bin/activate"
  mkdir -p "$(dirname "$bashrc_file")"
  touch "$bashrc_file"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
  local profile_script="/etc/profile.d/auto_venv.sh"
  echo "if [ -d \"$venv_path\" ]; then . \"$venv_path/bin/activate\"; fi" > "$profile_script"
  chmod +x "$profile_script"
}

set_permissions() {
  if [ "$RUN_AS_ROOT" = "1" ]; then
    return 0
  fi
  if [ "$(id -u)" -eq 0 ] && id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" || true
  fi
  chmod -R u+rwX,go-rwx "$APP_DIR" || true
}

print_summary() {
  local duration=$(( $(date +%s) - START_TIME ))
  log "Environment setup completed in ${duration}s."
  echo "Project directory: $APP_DIR"
  echo "Detected runtimes:"
  [ "$PYTHON_DETECTED" -eq 1 ] && echo " - Python (venv: $PY_VENV_PATH)"
  [ "$NODE_DETECTED" -eq 1 ] && echo " - Node.js"
  [ "$RUBY_DETECTED" -eq 1 ] && echo " - Ruby"
  [ "$PHP_DETECTED" -eq 1 ] && echo " - PHP"
  [ "$GO_DETECTED" -eq 1 ] && echo " - Go"
  [ "$JAVA_DETECTED" -eq 1 ] && echo " - Java"
  [ "$RUST_DETECTED" -eq 1 ] && echo " - Rust"
  echo "Environment variables saved in: $APP_DIR/.env"
  echo "PATH additions persisted in: /etc/profile.d/app_path.sh"
  echo "To use environment variables in current shell: export \$(grep -v '^#' \"$APP_DIR/.env\" | xargs)"
  echo "If Python was detected: source \"$PY_VENV_PATH/bin/activate\""
  echo "Typical start commands (depending on project type):"
  echo " - Python Flask: source \"$PY_VENV_PATH/bin/activate\" && flask run --host=0.0.0.0 --port=\"\${PORT:-5000}\""
  echo " - Python Django: source \"$PY_VENV_PATH/bin/activate\" && python manage.py runserver 0.0.0.0:\"\${PORT:-8000}\""
  echo " - Node.js: npm start (ensure it binds 0.0.0.0 and uses PORT)"
  echo " - Ruby (Rails): bundle exec rails server -b 0.0.0.0 -p \"\${PORT:-3000}\""
  echo " - PHP (Laravel): php artisan serve --host=0.0.0.0 --port=\"\${PORT:-8000}\""
  echo " - Go: go run ./... (ensure it reads PORT)"
  echo " - Java (Spring): ./mvnw spring-boot:run (ensure server.port=\${PORT})"
  echo " - Rust (Rocket/Axum): cargo run (ensure it reads PORT)"
}

main() {
  log "Starting environment setup for project at '$APP_DIR'..."

  cd "$APP_DIR" || die "Cannot change directory to $APP_DIR."

  detect_pkg_mgr || warn "No supported package manager detected. Some installations may fail."
  install_common_base
  ensure_directories
  create_app_user

  ensure_python_runtime
  ensure_node_runtime
  ensure_ruby_runtime
  ensure_php_runtime
  ensure_go_runtime
  ensure_java_runtime
  ensure_rust_runtime

  detect_app_type_and_port
  configure_paths_env
  [ "$PYTHON_DETECTED" -eq 1 ] && setup_auto_activate
  set_permissions

  print_summary
}

main "$@"