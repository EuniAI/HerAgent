#!/usr/bin/env bash
# Environment setup script for containerized projects
# This script attempts to detect the project type and install necessary runtimes, system packages,
# and project dependencies in a Docker-friendly manner (no sudo, assumes root).
#
# It is designed to be idempotent and safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# Logging helpers
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "${GREEN}[$(timestamp)] $*${NC}"; }
warn() { echo "${YELLOW}[$(timestamp)] [WARN] $*${NC}" >&2; }
err() { echo "${RED}[$(timestamp)] [ERROR] $*${NC}" >&2; }
info() { echo "${BLUE}[$(timestamp)] $*${NC}"; }

# Trap errors
trap 'err "An error occurred on line $LINENO"; exit 1' ERR

# Global defaults (can be overridden by existing environment variables or .env)
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-root}"
APP_GROUP="${APP_GROUP:-root}"
APP_ENV="${APP_ENV:-production}"
PORT="${PORT:-8080}"
TZ="${TZ:-UTC}"
LANG="${LANG:-C.UTF-8}"

# Retry helper for flaky network operations
retry_cmd() {
  local retries="${1:-5}"; shift || true
  local delay="${1:-3}"; shift || true
  local cmd=("$@")
  local count=0
  until "${cmd[@]}"; do
    exit_code=$?
    count=$((count + 1))
    if (( count >= retries )); then
      err "Command failed after ${retries} attempts: ${cmd[*]} (exit code ${exit_code})"
      return "${exit_code}"
    fi
    warn "Command failed (exit ${exit_code}), retry ${count}/${retries} in ${delay}s: ${cmd[*]}"
    sleep "${delay}"
  done
}

# Detect OS and package manager
PKG_MGR=""
OS_FAMILY=""
determine_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    OS_FAMILY="debian"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    OS_FAMILY="alpine"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
    OS_FAMILY="redhat"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    OS_FAMILY="redhat"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    OS_FAMILY="redhat"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    OS_FAMILY="suse"
  else
    PKG_MGR=""
    OS_FAMILY="unknown"
  fi
}

# Update package indices
pkg_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      retry_cmd 5 3 apt-get update -y
      ;;
    apk)
      # apk update is implicit when adding if cache isn't present; still call for idempotence
      retry_cmd 5 3 apk update
      ;;
    microdnf)
      retry_cmd 5 3 microdnf update -y || true
      ;;
    dnf)
      retry_cmd 5 3 dnf makecache -y || true
      ;;
    yum)
      retry_cmd 5 3 yum makecache -y || true
      ;;
    zypper)
      retry_cmd 5 3 zypper --non-interactive refresh
      ;;
    *)
      warn "Unknown package manager. Skipping package index update."
      ;;
  esac
}

# Install packages via detected package manager (handles multiple packages)
pkg_install() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      retry_cmd 3 3 apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      retry_cmd 3 3 apk add --no-cache "$@"
      ;;
    microdnf)
      retry_cmd 3 3 microdnf install -y "$@"
      ;;
    dnf)
      retry_cmd 3 3 dnf install -y "$@"
      ;;
    yum)
      retry_cmd 3 3 yum install -y "$@"
      ;;
    zypper)
      retry_cmd 3 3 zypper --non-interactive install -y "$@"
      ;;
    *)
      err "No supported package manager found. Cannot install: $*"
      return 1
      ;;
  esac
}

# Ensure basic utilities
install_base_utils() {
  log "Installing base utilities and build tools..."
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg pkg-config tzdata locales build-essential make gcc g++ libssl-dev
      # generate locale if locales installed
      if command -v locale-gen >/dev/null 2>&1; then
        echo "$LANG UTF-8" > /etc/locale.gen || true
        locale-gen || true
      fi
      ;;
    apk)
      pkg_update
      pkg_install ca-certificates curl wget git bash tzdata build-base make gcc g++ openssl-dev
      ;;
    microdnf|dnf|yum)
      pkg_update
      pkg_install ca-certificates curl wget git tzdata make gcc gcc-c++ openssl-devel
      ;;
    zypper)
      pkg_update
      pkg_install ca-certificates curl wget git timezone make gcc gcc-c++ libopenssl-devel
      ;;
    *)
      warn "Skipping base utilities installation due to unknown package manager."
      ;;
  esac
  update-ca-certificates >/dev/null 2>&1 || true
}

# Project type detection
PROJECT_TYPE="unknown"
detect_project_type() {
  if [[ -f "$APP_DIR/requirements.txt" || -f "$APP_DIR/pyproject.toml" || -f "$APP_DIR/setup.py" ]]; then
    PROJECT_TYPE="python"
  elif [[ -f "$APP_DIR/package.json" ]]; then
    PROJECT_TYPE="node"
  elif [[ -f "$APP_DIR/Gemfile" ]]; then
    PROJECT_TYPE="ruby"
  elif [[ -f "$APP_DIR/go.mod" ]]; then
    PROJECT_TYPE="go"
  elif [[ -f "$APP_DIR/Cargo.toml" ]]; then
    PROJECT_TYPE="rust"
  elif [[ -f "$APP_DIR/pom.xml" || -f "$APP_DIR/build.gradle" || -f "$APP_DIR/build.gradle.kts" ]]; then
    PROJECT_TYPE="java"
  elif [[ -f "$APP_DIR/composer.json" ]]; then
    PROJECT_TYPE="php"
  elif [[ -n "$(find "$APP_DIR" -maxdepth 2 -name '*.csproj' -print -quit 2>/dev/null)" ]]; then
    PROJECT_TYPE="dotnet"
  else
    PROJECT_TYPE="unknown"
  fi
}

# Setup directories and permissions
setup_directories() {
  log "Preparing application directory structure at $APP_DIR..."
  mkdir -p "$APP_DIR"
  mkdir -p "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/.cache"
  chmod 755 "$APP_DIR" || true
  chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR" || true
}

# Environment file management
setup_env_file() {
  local env_file="$APP_DIR/.env"
  if [[ ! -f "$env_file" ]]; then
    log "Creating default .env at $env_file"
    cat > "$env_file" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
TZ=${TZ}
LANG=${LANG}
# Add additional environment variables as needed for your project.
EOF
  else
    log ".env already exists. Not overwriting."
  fi
}

# Load environment variables from .env
load_env() {
  if [[ -f "$APP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$APP_DIR/.env"
    set +a
    log "Loaded environment variables from .env"
  else
    warn "No .env file found. Using default environment variables."
  fi
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev build-essential
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev build-base
      ;;
    microdnf|dnf|yum)
      pkg_install python3 python3-pip python3-devel make gcc gcc-c++
      ;;
    zypper)
      pkg_install python3 python3-pip python3-virtualenv python3-devel make gcc gcc-c++
      ;;
    *)
      warn "Unknown package manager. Attempting to use existing Python."
      ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    err "Python3 is not available. Please use a Python base image or install Python."
    return 1
  fi
  if ! command -v pip3 >/dev/null 2>&1; then
    err "pip3 is not available. Cannot install Python dependencies."
    return 1
  fi

  # Create virtual environment
  if [[ ! -d "$APP_DIR/.venv" ]]; then
    log "Creating Python virtual environment at $APP_DIR/.venv"
    python3 -m venv "$APP_DIR/.venv" || {
      warn "python -m venv failed. Attempting virtualenv fallback."
      python3 -m pip install --no-cache-dir --upgrade virtualenv
      python3 -m virtualenv "$APP_DIR/.venv"
    }
  else
    log "Virtual environment already exists at $APP_DIR/.venv"
  fi

  # Activate venv for installation
  # shellcheck disable=SC1091
  source "$APP_DIR/.venv/bin/activate"
  python -m pip install --no-cache-dir --upgrade pip setuptools wheel

  if [[ -f "$APP_DIR/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    python -m pip install --no-cache-dir -r "$APP_DIR/requirements.txt"
  elif [[ -f "$APP_DIR/pyproject.toml" ]]; then
    # Basic PEP 517 install if it's a library, else best-effort with pip
    log "Detected pyproject.toml. Attempting to install project dependencies."
    python -m pip install --no-cache-dir .
  elif [[ -f "$APP_DIR/setup.py" ]]; then
    log "Installing Python package in editable mode"
    python -m pip install --no-cache-dir -e "$APP_DIR"
  else
    warn "No Python dependency file found. Skipping dependency installation."
  fi

  # Common environment defaults for Python web apps
  if [[ -f "$APP_DIR/app.py" || -n "$(find "$APP_DIR" -maxdepth 1 -name 'wsgi.py' -print -quit 2>/dev/null)" ]]; then
    export FLASK_ENV="${FLASK_ENV:-$APP_ENV}"
    export FLASK_RUN_PORT="${FLASK_RUN_PORT:-$PORT}"
    export FLASK_APP="${FLASK_APP:-app.py}"
    log "Configured Python web environment: FLASK_ENV=$FLASK_ENV FLASK_RUN_PORT=$FLASK_RUN_PORT FLASK_APP=$FLASK_APP"
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    microdnf|dnf|yum)
      # Many RHEL-based minimal images don't have recent Node.js; attempt install and warn
      pkg_install nodejs npm || warn "Installing nodejs via $PKG_MGR failed or version may be outdated."
      ;;
    zypper)
      pkg_install nodejs14 npm14 || pkg_install nodejs npm || true
      ;;
    *)
      warn "Unknown package manager. Attempting to use existing Node.js."
      ;;
  esac

  if ! command -v node >/dev/null 2>&1; then
    err "Node.js is not available. Please use a Node base image or ensure Node is installed."
    return 1
  fi

  # Use corepack to ensure yarn/pnpm if available
  if node -v >/dev/null 2>&1 && command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  if [[ -f "$APP_DIR/package-lock.json" ]]; then
    log "Installing Node dependencies with npm ci"
    (cd "$APP_DIR" && npm ci)
  elif [[ -f "$APP_DIR/package.json" ]]; then
    log "Installing Node dependencies with npm install"
    (cd "$APP_DIR" && npm install)
  else
    warn "No package.json found for Node project. Skipping dependency installation."
  fi

  # Common build script
  if [[ -f "$APP_DIR/package.json" ]] && jq -e '.scripts.build' "$APP_DIR/package.json" >/dev/null 2>&1; then
    log "Running build script"
    (cd "$APP_DIR" && npm run build)
  fi
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    microdnf|dnf|yum)
      pkg_install ruby ruby-devel make gcc gcc-c++
      ;;
    zypper)
      pkg_install ruby ruby-devel make gcc gcc-c++
      ;;
    *)
      warn "Unknown package manager for Ruby."
      ;;
  esac

  if ! command -v gem >/dev/null 2>&1; then
    err "Ruby gem is not available."
    return 1
  fi
  gem install --no-document bundler || true

  if [[ -f "$APP_DIR/Gemfile" ]]; then
    log "Installing Ruby dependencies with bundler"
    (cd "$APP_DIR" && bundle config set without 'development test' || true && bundle install)
  else
    warn "No Gemfile found. Skipping bundle install."
  fi
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
    microdnf|dnf|yum)
      pkg_install golang
      ;;
    zypper)
      pkg_install go
      ;;
    *)
      warn "Unknown package manager for Go."
      ;;
  esac

  if ! command -v go >/dev/null 2>&1; then
    err "Go is not available."
    return 1
  fi

  if [[ -f "$APP_DIR/go.mod" ]]; then
    log "Downloading Go modules"
    (cd "$APP_DIR" && go mod download)
    if [[ -n "$(find "$APP_DIR" -maxdepth 1 -name 'main.go' -print -quit 2>/dev/null)" ]]; then
      mkdir -p "$APP_DIR/bin"
      log "Building Go application"
      (cd "$APP_DIR" && go build -o "$APP_DIR/bin/app" ./)
    fi
  else
    warn "No go.mod found. Skipping Go setup."
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing rustup and toolchain (stable)"
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    chmod +x /tmp/rustup.sh
    /tmp/rustup.sh -y --default-toolchain stable
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    err "Cargo is not available after rustup installation."
    return 1
  fi

  if [[ -f "$APP_DIR/Cargo.toml" ]]; then
    log "Building Rust project in release mode"
    (cd "$APP_DIR" && cargo build --release)
  else
    warn "No Cargo.toml found. Skipping Rust setup."
  fi
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install openjdk-17-jdk maven || pkg_install openjdk-11-jdk maven
      ;;
    apk)
      pkg_install openjdk17 maven || pkg_install openjdk11 maven
      ;;
    microdnf|dnf|yum)
      pkg_install java-17-openjdk-devel maven || pkg_install java-11-openjdk-devel maven
      ;;
    zypper)
      pkg_install java-17-openjdk-devel maven || pkg_install java-11-openjdk-devel maven
      ;;
    *)
      warn "Unknown package manager for Java."
      ;;
  esac

  if ! command -v javac >/dev/null 2>&1; then
    err "Java JDK is not available."
    return 1
  fi

  if [[ -f "$APP_DIR/pom.xml" ]]; then
    log "Building Maven project (skip tests)"
    (cd "$APP_DIR" && mvn -B -DskipTests package)
  elif [[ -f "$APP_DIR/build.gradle" || -f "$APP_DIR/build.gradle.kts" ]]; then
    if command -v gradle >/dev/null 2>&1; then
      log "Building Gradle project (assemble)"
      (cd "$APP_DIR" && gradle assemble)
    else
      warn "Gradle not found; consider using Gradle wrapper."
      if [[ -x "$APP_DIR/gradlew" ]]; then
        (cd "$APP_DIR" && ./gradlew assemble)
      fi
    fi
  else
    warn "No Maven or Gradle build file found."
  fi
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip
      ;;
    apk)
      pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip unzip || pkg_install php php-cli php-mbstring php-xml php-curl php-zip unzip
      ;;
    microdnf|dnf|yum)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip
      ;;
    zypper)
      pkg_install php8 php8-cli php8-mbstring php8-xml php8-curl php8-zip unzip || pkg_install php php-cli php-mbstring php-xml php-curl php-zip unzip
      ;;
    *)
      warn "Unknown package manager for PHP."
      ;;
  esac

  # Composer
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Composer installation failed."
  fi

  if [[ -f "$APP_DIR/composer.json" ]]; then
    log "Installing PHP dependencies with composer"
    (cd "$APP_DIR" && composer install --no-interaction --no-progress --prefer-dist)
  else
    warn "No composer.json found. Skipping composer install."
  fi
}

# .NET setup (best effort)
setup_dotnet() {
  log "Setting up .NET environment..."
  if ! command -v dotnet >/dev/null 2>&1; then
    warn "dotnet SDK not found. Installing SDK requires vendor repositories and may not be supported on this base image."
    warn "Please use an official dotnet SDK base image (e.g., mcr.microsoft.com/dotnet/sdk:8.0)."
    return 0
  fi

  local csproj
  csproj="$(find "$APP_DIR" -maxdepth 2 -name '*.csproj' -print -quit || true)"
  if [[ -n "$csproj" ]]; then
    log "Restoring .NET project dependencies"
    (cd "$(dirname "$csproj")" && dotnet restore)
    log "Building .NET project"
    (cd "$(dirname "$csproj")" && dotnet build -c Release --no-restore)
  else
    warn "No .csproj found. Skipping .NET restore/build."
  fi
}

# Generic post-setup notes or hooks
post_setup() {
  # Set timezone
  if [[ -f /usr/share/zoneinfo/"$TZ" ]]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
    echo "$TZ" > /etc/timezone || true
    log "Timezone set to $TZ"
  fi

  # Ensure permissions are consistent
  chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR" || true

  # Create a default start script (non-overwriting)
  local start_script="$APP_DIR/start.sh"
  if [[ ! -f "$start_script" ]]; then
    log "Creating default start script at $start_script"
    cat > "$start_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Load env vars
if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

# Detect and run application
if [[ -d ".venv" && -f "app.py" ]]; then
  exec ./.venv/bin/python app.py
elif command -v node >/dev/null 2>&1 && [[ -f "package.json" ]]; then
  # Prefer "start" script
  if jq -e '.scripts.start' package.json >/dev/null 2>&1; then
    exec npm run start
  else
    exec node server.js
  fi
elif [[ -f "bin/app" ]]; then
  exec ./bin/app
else
  echo "No default start command found. Please customize start.sh."
  exit 1
fi
EOF
    chmod +x "$start_script"
  fi

  log "Post-setup tasks completed."
}

# Main workflow
main() {
  log "Starting environment setup..."
  determine_pkg_mgr
  if [[ -z "$PKG_MGR" ]]; then
    warn "No supported package manager detected. Proceeding with limited setup."
  else
    log "Detected package manager: $PKG_MGR (OS family: $OS_FAMILY)"
  fi

  setup_directories
  install_base_utils
  setup_env_file
  load_env

  detect_project_type
  log "Detected project type: $PROJECT_TYPE"

  case "$PROJECT_TYPE" in
    python) setup_python ;;
    node) setup_node ;;
    ruby) setup_ruby ;;
    go) setup_go ;;
    rust) setup_rust ;;
    java) setup_java ;;
    php) setup_php ;;
    dotnet) setup_dotnet ;;
    *)
      warn "Could not detect project type. Installed base utilities and prepared environment, but no language-specific setup performed."
      ;;
  esac

  post_setup
  log "Environment setup completed successfully."
  info "To run the application inside the container: cd $APP_DIR && ./start.sh"
}

# Execute main
main "$@"