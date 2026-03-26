#!/usr/bin/env bash
# Environment setup script for generic projects inside Docker containers
# This script detects common project types (Python, Node.js, Go, Java, Ruby, PHP, .NET)
# and installs appropriate runtimes, dependencies, and configures environment.

set -Eeuo pipefail

# Safe IFS
IFS=$'\n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Logging functions
log() {
  echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}
warn() {
  echo "${YELLOW}[WARN] $1${NC}" >&2
}
err() {
  echo "${RED}[ERROR] $1${NC}" >&2
}
debug() {
  echo "${BLUE}[DEBUG] $1${NC}"
}

# Trap unexpected errors
trap 'err "An unexpected error occurred on line $LINENO. Aborting."; exit 1' ERR

# Globals
readonly PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
readonly SETUP_STATE_DIR="/var/lib/project-setup"
readonly SETUP_STATE_FILE="${SETUP_STATE_DIR}/setup.state"
readonly APP_USER="${APP_USER:-appuser}"
readonly APP_GROUP="${APP_GROUP:-appgroup}"
readonly APP_UID="${APP_UID:-10001}"
readonly APP_GID="${APP_GID:-10001}"
readonly DEBIAN_FRONTEND=noninteractive
readonly UMASK_VALUE="${UMASK_VALUE:-027}"

# Ensure state dir exists
mkdir -p "$SETUP_STATE_DIR"

# Idempotent flags (saved in state file)
touch "$SETUP_STATE_FILE"

mark_state() {
  local key="$1"
  if ! grep -q "^${key}$" "$SETUP_STATE_FILE" 2>/dev/null; then
    echo "$key" >> "$SETUP_STATE_FILE"
  fi
}

has_state() {
  local key="$1"
  grep -q "^${key}$" "$SETUP_STATE_FILE" 2>/dev/null
}

# Detect package manager
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v microdnf >/dev/null 2>&1; then
    echo "microdnf"
  else
    echo "none"
  fi
}

readonly PKG_MGR="$(detect_pkg_manager)"

pkg_update() {
  case "$PKG_MGR" in
    apt)
      if ! has_state "apt-updated"; then
        log "Updating apt package index..."
        apt-get update -y
        mark_state "apt-updated"
      fi
      ;;
    apk)
      if ! has_state "apk-updated"; then
        log "Updating apk package index..."
        apk update
        mark_state "apk-updated"
      fi
      ;;
    dnf)
      if ! has_state "dnf-metadata-updated"; then
        log "Updating dnf metadata..."
        dnf -y makecache
        mark_state "dnf-metadata-updated"
      fi
      ;;
    yum)
      if ! has_state "yum-metadata-updated"; then
        log "Updating yum metadata..."
        yum -y makecache
        mark_state "yum-metadata-updated"
      fi
      ;;
    microdnf)
      if ! has_state "microdnf-metadata-updated"; then
        log "Updating microdnf metadata..."
        microdnf -y update
        mark_state "microdnf-metadata-updated"
      fi
      ;;
    *)
      warn "No supported package manager detected. Skipping system package updates."
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local packages=("$@")
  case "$PKG_MGR" in
    apt)
      pkg_update
      log "Installing packages via apt: ${packages[*]}"
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    apk)
      pkg_update
      log "Installing packages via apk: ${packages[*]}"
      apk add --no-cache "${packages[@]}"
      ;;
    dnf)
      pkg_update
      log "Installing packages via dnf: ${packages[*]}"
      dnf install -y "${packages[@]}"
      ;;
    yum)
      pkg_update
      log "Installing packages via yum: ${packages[*]}"
      yum install -y "${packages[@]}"
      ;;
    microdnf)
      pkg_update
      log "Installing packages via microdnf: ${packages[*]}"
      microdnf install -y "${packages[@]}"
      ;;
    *)
      err "Unsupported or missing package manager. Cannot install: ${packages[*]}"
      return 1
      ;;
  esac
}

# System base dependencies
install_base_system_deps() {
  if has_state "base-deps-installed"; then
    log "Base system dependencies already installed."
    return
  fi

  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git gnupg openssl jq xz-utils build-essential pkg-config make locales tzdata
      # Ensure locales
      if command -v locale-gen >/dev/null 2>&1; then
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen || true
        locale-gen || true
      fi
      ;;
    apk)
      pkg_install ca-certificates curl wget git openssl jq xz build-base bash tzdata
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl wget git gnupg2 openssl jq xz make gcc gcc-c++ tar gzip
      ;;
    *)
      warn "Skipping base system dependencies install (unknown package manager)."
      ;;
  esac

  mark_state "base-deps-installed"
  log "Base system dependencies installed."
}

# User and permissions setup
create_app_user() {
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User '$APP_USER' already exists."
    return
  fi

  log "Creating application user/group '$APP_USER' ($APP_UID) / '$APP_GROUP' ($APP_GID)..."
  # Try useradd/groupadd or adduser/addgroup depending on base image
  if command -v groupadd >/dev/null 2>&1; then
    groupadd -g "$APP_GID" "$APP_GROUP" || true
  elif command -v addgroup >/dev/null 2>&1; then
    addgroup -g "$APP_GID" "$APP_GROUP" || true
  else
    warn "No groupadd/addgroup available; attempting to proceed without explicit group creation."
  fi

  if command -v useradd >/dev/null 2>&1; then
    useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/sh "$APP_USER" || true
  elif command -v adduser >/dev/null 2>&1; then
    adduser -D -u "$APP_UID" -G "$APP_GROUP" "$APP_USER" || true
  else
    warn "No useradd/adduser available; cannot create non-root user."
    return
  fi

  log "Application user '$APP_USER' created."
}

# Directory structure
setup_directories() {
  umask "$UMASK_VALUE"
  mkdir -p "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/.cache"
  mkdir -p /var/log/app /var/run/app
  chmod 755 "$PROJECT_ROOT"
  chmod 775 "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" /var/log/app /var/run/app

  if id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER":"$APP_GROUP" "$PROJECT_ROOT" /var/log/app /var/run/app || true
  fi

  log "Project directories set up at '$PROJECT_ROOT'."
}

# Project type detection
detect_project_type() {
  local type="unknown"

  if [[ -f "$PROJECT_ROOT/requirements.txt" || -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/setup.py" ]]; then
    type="python"
  elif [[ -f "$PROJECT_ROOT/package.json" ]]; then
    type="node"
  elif [[ -f "$PROJECT_ROOT/go.mod" || -f "$PROJECT_ROOT/main.go" ]]; then
    type="go"
  elif [[ -f "$PROJECT_ROOT/pom.xml" || -f "$PROJECT_ROOT/build.gradle" || -f "$PROJECT_ROOT/build.gradle.kts" ]]; then
    type="java"
  elif [[ -f "$PROJECT_ROOT/Gemfile" ]]; then
    type="ruby"
  elif [[ -f "$PROJECT_ROOT/composer.json" ]]; then
    type="php"
  elif compgen -G "$PROJECT_ROOT/*.csproj" >/dev/null || [[ -f "$PROJECT_ROOT/global.json" ]]; then
    type="dotnet"
  fi

  echo "$type"
}

# Python setup
setup_python() {
  log "Setting up Python environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev build-essential
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev build-base
      ;;
    dnf|yum|microdnf)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++
      ;;
    *)
      warn "Cannot install Python system packages without a supported package manager."
      ;;
  esac

  # Create virtual environment
  local venv_dir="$PROJECT_ROOT/.venv"
  if [[ ! -d "$venv_dir" ]]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Virtual environment already exists at $venv_dir"
  fi

  # Activate venv and install dependencies
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel --no-cache-dir

  if [[ -f "$PROJECT_ROOT/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "$PROJECT_ROOT/requirements.txt" --no-cache-dir
  elif [[ -f "$PROJECT_ROOT/pyproject.toml" ]]; then
    # Attempt PEP 517/518 build via pip if possible
    log "Detected pyproject.toml; attempting to install with pip"
    pip install . --no-cache-dir || warn "pip install . failed; ensure build-system is compatible with pip."
  fi

  # Set common environment variables
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1
  export PATH="$venv_dir/bin:${PATH}"

  # Framework detection
  if [[ -f "$PROJECT_ROOT/manage.py" ]]; then
    export APP_PORT="${APP_PORT:-8000}"
    log "Django project detected. Default APP_PORT=$APP_PORT"
    # Create .env defaults for Django
    create_env_if_missing "DJANGO_SETTINGS_MODULE=project.settings" "APP_ENV=production" "APP_PORT=${APP_PORT}"
  elif [[ -f "$PROJECT_ROOT/app.py" || -f "$PROJECT_ROOT/wsgi.py" ]]; then
    export APP_PORT="${APP_PORT:-5000}"
    log "Flask/Werkzeug app detected. Default APP_PORT=$APP_PORT"
    create_env_if_missing "FLASK_ENV=production" "FLASK_APP=app.py" "FLASK_RUN_PORT=${APP_PORT}" "APP_ENV=production" "APP_PORT=${APP_PORT}"
  else
    export APP_PORT="${APP_PORT:-8000}"
    create_env_if_missing "APP_ENV=production" "APP_PORT=${APP_PORT}"
  fi

  deactivate || true
  log "Python environment setup completed."
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."

  if command -v node >/dev/null 2>&1; then
    log "Node.js already installed: $(node --version)"
  else
    case "$PKG_MGR" in
      apt)
        # Install via NodeSource for recent LTS
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        pkg_install nodejs
        ;;
      apk)
        # Alpine repositories typically have nodejs/npm
        pkg_install nodejs npm
        ;;
      dnf|yum|microdnf)
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        pkg_install nodejs
        ;;
      *)
        err "No supported package manager found for Node.js installation."
        return 1
        ;;
    esac
    log "Installed Node.js: $(node --version)"
  fi

  # Enable corepack (for Yarn/Pnpm)
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Install dependencies
  if [[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]]; then
    log "Detected pnpm-lock.yaml; using pnpm"
    corepack prepare pnpm@latest --activate || true
    (cd "$PROJECT_ROOT" && pnpm install --frozen-lockfile || pnpm install)
  elif [[ -f "$PROJECT_ROOT/yarn.lock" ]]; then
    log "Detected yarn.lock; using Yarn"
    corepack prepare yarn@stable --activate || true
    (cd "$PROJECT_ROOT" && yarn install --frozen-lockfile || yarn install)
  elif [[ -f "$PROJECT_ROOT/package-lock.json" ]]; then
    log "Detected package-lock.json; using npm ci"
    (cd "$PROJECT_ROOT" && npm ci --no-audit --progress=false)
  elif [[ -f "$PROJECT_ROOT/package.json" ]]; then
    log "Installing npm dependencies"
    (cd "$PROJECT_ROOT" && npm install --no-audit --progress=false)
  fi

  export NODE_ENV="${NODE_ENV:-production}"
  export APP_PORT="${APP_PORT:-3000}"
  create_env_if_missing "NODE_ENV=${NODE_ENV}" "APP_ENV=production" "PORT=${APP_PORT}" "APP_PORT=${APP_PORT}"

  log "Node.js environment setup completed."
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum|microdnf)
      pkg_install golang
      ;;
    *)
      err "No supported package manager found for Go installation."
      return 1
      ;;
  esac

  export GOPATH="${GOPATH:-/go}"
  export GOCACHE="${GOCACHE:-$PROJECT_ROOT/.cache/go}"
  export PATH="${GOPATH}/bin:${PATH}"
  mkdir -p "$GOPATH" "$GOCACHE"

  if [[ -f "$PROJECT_ROOT/go.mod" ]]; then
    log "Downloading Go module dependencies"
    (cd "$PROJECT_ROOT" && go mod download)
  fi

  export APP_PORT="${APP_PORT:-8080}"
  create_env_if_missing "APP_ENV=production" "APP_PORT=${APP_PORT}"

  log "Go environment setup completed."
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install openjdk-17-jdk maven gradle
      ;;
    apk)
      pkg_install openjdk17 maven gradle
      ;;
    dnf|yum|microdnf)
      pkg_install java-17-openjdk-devel maven gradle
      ;;
    *)
      err "No supported package manager found for Java installation."
      return 1
      ;;
  esac

  export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  export PATH="${JAVA_HOME}/bin:${PATH}"

  if [[ -f "$PROJECT_ROOT/pom.xml" ]]; then
    log "Maven project detected. Resolving dependencies..."
    (cd "$PROJECT_ROOT" && mvn -B -q dependency:go-offline || warn "Maven dependency resolution failed.")
  elif compgen -G "$PROJECT_ROOT/build.gradle*" >/dev/null; then
    log "Gradle project detected. Resolving dependencies..."
    (cd "$PROJECT_ROOT" && gradle --no-daemon --warning-mode=all build -x test || warn "Gradle build/dependency resolution failed.")
  fi

  export APP_PORT="${APP_PORT:-8080}"
  create_env_if_missing "APP_ENV=production" "APP_PORT=${APP_PORT}"

  log "Java environment setup completed."
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential libffi-dev
      ;;
    apk)
      pkg_install ruby ruby-bundler build-base
      ;;
    dnf|yum|microdnf)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      err "No supported package manager found for Ruby installation."
      return 1
      ;;
  esac

  if [[ -f "$PROJECT_ROOT/Gemfile" ]]; then
    log "Installing Ruby gems via Bundler"
    if ! command -v bundle >/dev/null 2>&1; then
      gem install bundler --no-document || warn "Failed to install bundler."
    fi
    (cd "$PROJECT_ROOT" && bundle config set --local path 'vendor/bundle' && bundle install)
  fi

  export APP_PORT="${APP_PORT:-3000}"
  create_env_if_missing "APP_ENV=production" "APP_PORT=${APP_PORT}"

  log "Ruby environment setup completed."
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-xml php-mbstring php-curl unzip
      ;;
    apk)
      pkg_install php php-cli php-xml php-mbstring php-curl unzip
      ;;
    dnf|yum|microdnf)
      pkg_install php-cli php-xml php-mbstring php-json unzip
      ;;
    *)
      err "No supported package manager found for PHP installation."
      return 1
      ;;
  esac

  # Composer installation
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
      && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
      && rm -f composer-setup.php || warn "Composer installation failed."
  fi

  if [[ -f "$PROJECT_ROOT/composer.json" ]]; then
    log "Installing PHP dependencies via Composer"
    (cd "$PROJECT_ROOT" && composer install --no-interaction --no-progress --prefer-dist)
  fi

  export APP_PORT="${APP_PORT:-8080}"
  create_env_if_missing "APP_ENV=production" "APP_PORT=${APP_PORT}"

  log "PHP environment setup completed."
}

# .NET setup (optional, recommend official dotnet images)
setup_dotnet() {
  log "Setting up .NET environment..."
  warn "Installing .NET SDK inside generic container is not recommended. Prefer official mcr.microsoft.com/dotnet images."
  warn "Skipping automatic .NET installation. If needed, set up dotnet via base image or add repository manually."
  export APP_PORT="${APP_PORT:-8080}"
  create_env_if_missing "APP_ENV=production" "APP_PORT=${APP_PORT}"
}

# Create .env file with defaults if missing
create_env_if_missing() {
  local env_file="$PROJECT_ROOT/.env"
  if [[ ! -f "$env_file" ]]; then
    log "Creating default .env at $env_file"
    {
      echo "# Generated by setup script on $(date -Iseconds)"
      for kv in "$@"; do
        echo "$kv"
      done
      # Common defaults
      echo "LANG=${LANG:-C.UTF-8}"
      echo "TZ=${TZ:-UTC}"
    } > "$env_file"
    chmod 640 "$env_file"
    if id -u "$APP_USER" >/dev/null 2>&1; then
      chown "$APP_USER":"$APP_GROUP" "$env_file" || true
    fi
  else
    log ".env already exists; not overwriting."
  fi
}

# Export common environment variables for current session
export_common_env() {
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export TZ="${TZ:-UTC}"
  export APP_ENV="${APP_ENV:-production}"
}

# Main setup function
main() {
  log "Starting project environment setup in Docker container..."
  export_common_env
  install_base_system_deps
  create_app_user
  setup_directories

  local type
  type="$(detect_project_type)"
  log "Detected project type: $type"

  case "$type" in
    python)
      setup_python
      ;;
    node)
      setup_node
      ;;
    go)
      setup_go
      ;;
    java)
      setup_java
      ;;
    ruby)
      setup_ruby
      ;;
    php)
      setup_php
      ;;
    dotnet)
      setup_dotnet
      ;;
    *)
      warn "Unable to detect project type automatically. Installed base system packages only."
      create_env_if_missing "APP_ENV=production" "APP_PORT=${APP_PORT:-8080}"
      ;;
  esac

  # Adjust permissions for runtime directories
  if id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER":"$APP_GROUP" "$PROJECT_ROOT" /var/log/app /var/run/app || true
  fi

  log "Environment setup completed successfully."
  log "Notes:"
  echo "- Project root: $PROJECT_ROOT"
  echo "- Non-root user: ${APP_USER} (if created)"
  echo "- Environment file: $PROJECT_ROOT/.env"
  echo "- To run inside container, ensure your entrypoint/cmd sources environment or uses .env (depending on your framework)."
  echo "- Common ports by type: Python(Flask 5000/Django 8000), Node 3000, Go/Java/PHP 8080. Adjust APP_PORT in .env as needed."
}

# Execute main
main "$@"