#!/usr/bin/env bash
# Universal project environment setup script for containerized execution
# Detects project type and installs runtime/dependencies using the container's package manager.
# Safe to run multiple times (idempotent) and designed for root execution inside Docker.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Global variables
PROJECT_ROOT="$(pwd)"
APP_NAME="${APP_NAME:-$(basename "$PROJECT_ROOT")}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-}"
PKG_MGR=""
CREATED_USER=""
NONINTERACTIVE="${NONINTERACTIVE:-1}"

# Logging functions
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "${GREEN}[$(timestamp)] $*${NC}"; }
info() { echo "${BLUE}[$(timestamp)] $*${NC}"; }
warn() { echo "${YELLOW}[WARNING] $*${NC}" >&2; }
error() { echo "${RED}[ERROR] $*${NC}" >&2; }

# Trap errors
trap 'error "An error occurred at line $LINENO. Exiting."; exit 1' ERR

# Check running as root
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "This setup script must run as root inside the container. Current UID: $(id -u)"
    exit 1
  fi
}

# Detect package manager
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  else
    error "Unsupported base image: no recognized package manager found."
    exit 1
  fi
  log "Using package manager: $PKG_MGR"
}

# Update package indexes (idempotent)
pm_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update || true
      ;;
    yum)
      yum makecache -y || true
      ;;
    dnf)
      dnf makecache -y || true
      ;;
    microdnf)
      microdnf update -y || true
      ;;
    zypper)
      zypper refresh -y || true
      ;;
  esac
}

# Install base system tools and build dependencies
install_base_packages() {
  log "Installing base system packages and build tools..."
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends \
        build-essential pkg-config git curl wget ca-certificates gnupg \
        unzip zip tar bash coreutils findutils sed grep jq locales
      ;;
    apk)
      apk add --no-cache \
        build-base pkgconfig git curl wget ca-certificates openssl gnupg \
        unzip zip tar bash coreutils findutils sed grep jq
      ;;
    yum)
      yum install -y \
        gcc gcc-c++ make pkgconfig git curl wget ca-certificates openssl gnupg2 \
        unzip zip tar bash coreutils findutils sed grep jq
      ;;
    dnf|microdnf)
      $PKG_MGR install -y \
        gcc gcc-c++ make pkgconfig git curl wget ca-certificates openssl gnupg2 \
        unzip zip tar bash coreutils findutils sed grep jq
      ;;
    zypper)
      zypper install -y \
        gcc gcc-c++ make pkg-config git curl wget ca-certificates openssl gpg2 \
        unzip zip tar bash coreutils findutils sed grep jq
      ;;
  esac
  log "Base system packages installed."
}

# Load environment variables from .env if present
load_env_file() {
  if [ -f "$PROJECT_ROOT/.env" ]; then
    log "Loading environment variables from .env"
    # Export variables from .env safely (ignore comments/empty lines)
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|\#*) continue ;;
        *)
          if echo "$line" | grep -q '='; then
            varname="$(echo "$line" | cut -d= -f1)"
            varvalue="$(echo "$line" | cut -d= -f2-)"
            export "$varname=$varvalue"
          fi
          ;;
      esac
    done < "$PROJECT_ROOT/.env"
  fi
}

# Ensure directories exist and permissions set
setup_directories() {
  log "Setting up project directories and permissions..."
  mkdir -p "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/data" "$PROJECT_ROOT/dist"
  chmod 755 "$PROJECT_ROOT" || true
  chmod -R 775 "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/data" || true
  log "Directories prepared: logs, tmp, data, dist"
}

# Optional: create non-root app user (disabled by default)
create_app_user() {
  if [ "${CREATE_APP_USER:-0}" = "1" ]; then
    local user="${APP_USER:-app}"
    local uid="${APP_UID:-10001}"
    local gid="${APP_GID:-10001}"
    if ! getent group "$gid" >/dev/null 2>&1 && ! getent group "$user" >/dev/null 2>&1; then
      groupadd -g "$gid" "$user" || true
    fi
    if ! id -u "$user" >/dev/null 2>&1; then
      useradd -m -u "$uid" -g "$gid" -s /usr/sbin/nologin "$user" || true
      CREATED_USER="$user"
      chown -R "$user:$user" "$PROJECT_ROOT" || true
      log "Created app user: $user (uid:$uid gid:$gid)"
    else
      CREATED_USER="$user"
      log "App user $user already exists"
    fi
  fi
}

# Detect project type based on common files
PROJECT_TYPE=""
detect_project_type() {
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    PROJECT_TYPE="node"
  elif [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/Pipfile" ]; then
    PROJECT_TYPE="python"
  elif [ -f "$PROJECT_ROOT/Gemfile" ]; then
    PROJECT_TYPE="ruby"
  elif [ -f "$PROJECT_ROOT/go.mod" ]; then
    PROJECT_TYPE="go"
  elif [ -f "$PROJECT_ROOT/pom.xml" ]; then
    PROJECT_TYPE="java-maven"
  elif [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/gradlew" ]; then
    PROJECT_TYPE="java-gradle"
  elif [ -f "$PROJECT_ROOT/composer.json" ]; then
    PROJECT_TYPE="php"
  elif ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1 || [ -f "$PROJECT_ROOT/global.json" ]; then
    PROJECT_TYPE="dotnet"
  else
    PROJECT_TYPE="unknown"
  fi
  log "Detected project type: $PROJECT_TYPE"
}

# Language-specific setup functions
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends python3 python3-pip python3-venv python3-dev libffi-dev libssl-dev
      ;;
    apk)
      apk add --no-cache python3 py3-pip py3-virtualenv python3-dev libffi-dev openssl-dev
      ;;
    yum)
      yum install -y python3 python3-pip python3-devel libffi-devel openssl-devel
      ;;
    dnf|microdnf)
      $PKG_MGR install -y python3 python3-pip python3-devel libffi-devel openssl-devel
      ;;
    zypper)
      zypper install -y python3 python3-pip python3-devel libffi-devel libopenssl-devel
      ;;
  esac
  python3 -m pip install --upgrade pip setuptools wheel --no-cache-dir
  # Use .venv for idempotency
  if [ ! -d "$PROJECT_ROOT/.venv" ]; then
    python3 -m venv "$PROJECT_ROOT/.venv"
    log "Created virtual environment at .venv"
  else
    log "Virtual environment already exists at .venv"
  fi
  # Activate venv for this script run
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.venv/bin/activate"
  export VIRTUAL_ENV="$PROJECT_ROOT/.venv"
  export PATH="$PROJECT_ROOT/.venv/bin:$PATH"
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1

  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install -r "$PROJECT_ROOT/requirements.txt" --no-cache-dir
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    if command -v pip >/dev/null 2>&1; then
      log "Installing Python project via pyproject.toml (PEP 517/518)..."
      pip install . --no-cache-dir || warn "pip install . failed; ensure build backend is available."
    fi
  elif [ -f "$PROJECT_ROOT/Pipfile" ]; then
    if ! command -v pipenv >/dev/null 2>&1; then
      pip install pipenv --no-cache-dir
    fi
    pipenv install --deploy --system
  else
    warn "No Python dependency file found (requirements.txt/pyproject.toml/Pipfile). Skipping dependency installation."
  fi

  # Default environment variables for Python apps
  export APP_ENV="${APP_ENV:-production}"
  if [ -z "${APP_PORT:-}" ]; then
    APP_PORT=8000
    export APP_PORT
  fi
  log "Python environment ready. VIRTUAL_ENV set. APP_ENV=${APP_ENV} APP_PORT=${APP_PORT}"
}

setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends nodejs npm
      ;;
    apk)
      apk add --no-cache nodejs npm
      ;;
    yum)
      yum install -y nodejs npm
      ;;
    dnf|microdnf)
      $PKG_MGR install -y nodejs npm
      ;;
    zypper)
      zypper install -y nodejs npm
      ;;
  esac

  # Install dependencies using npm or yarn based on lock file
  if [ -f "$PROJECT_ROOT/yarn.lock" ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      npm install -g yarn
    fi
    log "Installing Node dependencies with yarn..."
    pushd "$PROJECT_ROOT" >/dev/null
    yarn install --frozen-lockfile
    popd >/dev/null
  else
    log "Installing Node dependencies with npm..."
    pushd "$PROJECT_ROOT" >/dev/null
    if [ -f package-lock.json ]; then
      npm ci --no-audit --loglevel=warn
    else
      npm install --no-audit --loglevel=warn
    fi
    popd >/dev/null
  fi

  export NODE_ENV="${NODE_ENV:-production}"
  if [ -z "${APP_PORT:-}" ]; then
    APP_PORT=3000
    export APP_PORT
  fi
  log "Node.js environment ready. NODE_ENV=${NODE_ENV} APP_PORT=${APP_PORT}"
}

setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends ruby-full build-essential
      ;;
    apk)
      apk add --no-cache ruby ruby-bundler build-base
      ;;
    yum)
      yum install -y ruby ruby-devel gcc gcc-c++ make
      ;;
    dnf|microdnf)
      $PKG_MGR install -y ruby ruby-devel gcc gcc-c++ make
      ;;
    zypper)
      zypper install -y ruby ruby-devel gcc gcc-c++ make
      ;;
  esac

  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document || true
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  bundle config set path 'vendor/bundle' || true
  bundle config set deployment 'true' || true
  bundle install --without development test || bundle install || true
  popd >/dev/null

  if [ -z "${APP_PORT:-}" ]; then
    APP_PORT=9292
    export APP_PORT
  fi
  log "Ruby environment ready. APP_PORT=${APP_PORT}"
}

setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends golang
      ;;
    apk)
      apk add --no-cache go
      ;;
    yum)
      yum install -y golang
      ;;
    dnf|microdnf)
      $PKG_MGR install -y golang
      ;;
    zypper)
      zypper install -y go
      ;;
  esac
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f go.mod ]; then
    go mod download
  fi
  popd >/dev/null
  if [ -z "${APP_PORT:-}" ]; then
    APP_PORT=8080
    export APP_PORT
  fi
  log "Go environment ready. APP_PORT=${APP_PORT}"
}

setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends openjdk-17-jdk-headless maven
      ;;
    apk)
      apk add --no-cache openjdk17 maven
      ;;
    yum)
      yum install -y java-17-openjdk-devel maven
      ;;
    dnf|microdnf)
      $PKG_MGR install -y java-17-openjdk-devel maven
      ;;
    zypper)
      zypper install -y java-17-openjdk-devel maven
      ;;
  esac
  pushd "$PROJECT_ROOT" >/dev/null
  mvn -B -q dependency:resolve || warn "Maven dependency resolution failed"
  popd >/dev/null
  if [ -z "${APP_PORT:-}" ]; then
    APP_PORT=8080
    export APP_PORT
  fi
  log "Java (Maven) environment ready. APP_PORT=${APP_PORT}"
}

setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends openjdk-17-jdk-headless gradle
      ;;
    apk)
      apk add --no-cache openjdk17 gradle
      ;;
    yum)
      yum install -y java-17-openjdk-devel gradle
      ;;
    dnf|microdnf)
      $PKG_MGR install -y java-17-openjdk-devel gradle
      ;;
    zypper)
      zypper install -y java-17-openjdk-devel gradle
      ;;
  esac
  pushd "$PROJECT_ROOT" >/dev/null
  gradle --no-daemon build -x test || warn "Gradle build failed or not configured"
  popd >/dev/null
  if [ -z "${APP_PORT:-}" ]; then
    APP_PORT=8080
    export APP_PORT
  fi
  log "Java (Gradle) environment ready. APP_PORT=${APP_PORT}"
}

setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends php-cli php-mbstring php-xml php-zip unzip git curl
      # Composer
      if ! command -v composer >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends composer || true
      fi
      ;;
    apk)
      apk add --no-cache php php-cli php-mbstring php-xml php-openssl php-phar php-zip unzip git curl
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o composer-setup.php
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
        rm -f composer-setup.php || true
      fi
      ;;
    yum)
      yum install -y php-cli php-json php-mbstring php-xml php-zip unzip git curl || true
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o composer-setup.php
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
        rm -f composer-setup.php || true
      fi
      ;;
    dnf|microdnf)
      $PKG_MGR install -y php-cli php-json php-mbstring php-xml php-zip unzip git curl || true
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o composer-setup.php
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
        rm -f composer-setup.php || true
      fi
      ;;
    zypper)
      zypper install -y php-cli php7 php7-mbstring php7-xmlreader php7-zip unzip git curl || true
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o composer-setup.php
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
        rm -f composer-setup.php || true
      fi
      ;;
  esac

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f composer.json ]; then
    COMPOSER_NO_INTERACTION=1
    export COMPOSER_NO_INTERACTION
    composer install --no-dev --prefer-dist --no-progress || warn "Composer install failed"
  else
    warn "composer.json not found; skipping composer install"
  fi
  popd >/dev/null

  if [ -z "${APP_PORT:-}" ]; then
    APP_PORT=8080
    export APP_PORT
  fi
  log "PHP environment ready. APP_PORT=${APP_PORT}"
}

setup_dotnet() {
  log "Setting up .NET environment..."
  case "$PKG_MGR" in
    apt)
      # Attempt to install dotnet SDK 6 via apt if available
      apt-get install -y --no-install-recommends dotnet-sdk-6.0 || warn "dotnet-sdk-6.0 not available in this base image repositories"
      ;;
    apk)
      warn ".NET SDK installation is not supported via apk in this generic script; consider using a dotnet base image."
      ;;
    yum|dnf|microdnf|zypper)
      warn ".NET SDK installation is not standardized across this package manager; consider using a dotnet base image."
      ;;
  esac
  if [ -z "${APP_PORT:-}" ]; then
    APP_PORT=8080
    export APP_PORT
  fi
  log ".NET environment attempted. APP_PORT=${APP_PORT}"
}

# Set generic environment variables and config files
configure_runtime_env() {
  log "Configuring generic runtime environment..."
  export APP_NAME
  export APP_ENV
  export TZ="${TZ:-UTC}"
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"

  # Configure locales on Debian-based images for UTF-8 if available
  if [ "$PKG_MGR" = "apt" ]; then
    if command -v locale-gen >/dev/null 2>&1; then
      sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
      locale-gen || true
    fi
  fi

  # Create default .env if none exists
  if [ ! -f "$PROJECT_ROOT/.env" ]; then
    cat > "$PROJECT_ROOT/.env" <<EOF
APP_NAME=$APP_NAME
APP_ENV=$APP_ENV
APP_PORT=${APP_PORT:-8080}
TZ=$TZ
EOF
    log "Created default .env file."
  else
    log ".env file already exists; not overwriting."
  fi

  # Ensure DATABASE_URL is defined (default to local SQLite for tests)
  touch "$PROJECT_ROOT/.env"
  if ! grep -q "^DATABASE_URL=" "$PROJECT_ROOT/.env" 2>/dev/null; then
    printf "DATABASE_URL=sqlite:///./test.db\n" >> "$PROJECT_ROOT/.env"
  fi

  # Create a Python sitecustomize.py to set a default DATABASE_URL at interpreter startup
  if [ ! -f "$PROJECT_ROOT/sitecustomize.py" ]; then
    cat > "$PROJECT_ROOT/sitecustomize.py" <<'PYEOF'
import os
if not os.environ.get("DATABASE_URL"):
    os.environ["DATABASE_URL"] = "sqlite:///./test.db"
PYEOF
  fi

  # Placeholders for runtime-specific configs
  touch "$PROJECT_ROOT/.runtime_ready" || true
  log "Runtime configuration complete."
}

# Main orchestrator
main() {
  log "Starting universal environment setup for project: $APP_NAME"
  require_root
  detect_pkg_manager
  pm_update
  install_base_packages
  load_env_file
  setup_directories
  create_app_user
  detect_project_type

  case "$PROJECT_TYPE" in
    python) setup_python ;;
    node) setup_node ;;
    ruby) setup_ruby ;;
    go) setup_go ;;
    java-maven) setup_java_maven ;;
    java-gradle) setup_java_gradle ;;
    php) setup_php ;;
    dotnet) setup_dotnet ;;
    *)
      warn "Unknown project type. Installed base tools only. You may need to customize this script."
      if [ -z "${APP_PORT:-}" ]; then
        APP_PORT=8080
        export APP_PORT
      fi
      ;;
  esac

  configure_runtime_env

  log "Environment setup completed successfully!"
  info "Summary:"
  info "- Project type: $PROJECT_TYPE"
  info "- App name: $APP_NAME"
  info "- Environment: $APP_ENV"
  info "- Port: ${APP_PORT}"
  info "- Project root: $PROJECT_ROOT"
  if [ -n "$CREATED_USER" ]; then
    info "- Non-root app user created: $CREATED_USER"
  fi

  info "Notes:"
  info "- This script is idempotent and safe to re-run."
  info "- Customize environment via .env or by exporting variables before running."
  info "- For Python, virtualenv is at .venv and activated for this setup run."
  info "- For Node, dependencies installed via npm or yarn based on lockfile."
  info "- For Java, dependencies resolved via Maven/Gradle."
  info "- For PHP, dependencies installed via Composer if composer.json is present."
}

main "$@"