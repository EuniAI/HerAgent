#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust) and installs dependencies.
# Safe to run multiple times (idempotent) and designed to run as root inside Docker.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Logging functions
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

error_exit() {
  err "Exit status $1 at line $2"
  exit "$1"
}
trap 'error_exit $? $LINENO' ERR

# Default configuration (can be overridden by env vars)
APP_ROOT="${APP_ROOT:-/app}"
APP_USER="${APP_USER:-root}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-}"
CREATE_USER="${CREATE_USER:-auto}" # auto|always|never
PYTHON_VENV_PATH="${PYTHON_VENV_PATH:-$APP_ROOT/.venv}"
NPM_INSTALL_CMD="${NPM_INSTALL_CMD:-auto}" # auto|ci|install
RUST_INSTALL_METHOD="${RUST_INSTALL_METHOD:-pkg}" # pkg|rustup

# Ensure working directory exists and is correct
prepare_app_root() {
  if [ ! -d "$APP_ROOT" ]; then
    log "Creating application root directory at $APP_ROOT"
    mkdir -p "$APP_ROOT"
  fi
  cd "$APP_ROOT"
}

# OS and package manager detection
PKG_MANAGER=""
OS_ID=""
OS_ID_LIKE=""
read_os_release() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_ID_LIKE="${ID_LIKE:-}"
  fi
  if [[ -z "${OS_ID}" ]]; then
    OS_ID="unknown"
  fi
}

detect_pkg_manager() {
  read_os_release
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  else
    PKG_MANAGER="unknown"
  fi
}

# Run package manager update once per container
pm_update_once() {
  case "$PKG_MANAGER" in
    apt)
      local mark="/var/lib/setup/apt-updated"
      mkdir -p /var/lib/setup
      if [ ! -f "$mark" ]; then
        log "Updating apt package index..."
        apt-get update -y
        touch "$mark"
      else
        log "apt package index already updated (idempotent)"
      fi
      ;;
    apk)
      log "Updating apk package index..."
      apk update
      ;;
    dnf)
      log "Refreshing dnf metadata..."
      dnf makecache -y || true
      ;;
    yum)
      log "Refreshing yum metadata..."
      yum makecache -y || true
      ;;
    zypper)
      log "Refreshing zypper metadata..."
      zypper --non-interactive refresh || true
      ;;
    *)
      warn "Unknown package manager; cannot update indexes automatically."
      ;;
  esac
}

# Repair apt/dpkg state if previous operations were interrupted
repair_apt_state() {
  if [ "$PKG_MANAGER" = "apt" ]; then
    log "Repairing dpkg/apt state if interrupted..."
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock && dpkg --configure -a || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -f
    apt-get update -y || true
  fi
}

# Install packages using the detected package manager
install_packages() {
  # Accepts a space-separated list of packages
  if [ $# -eq 0 ]; then return 0; fi
  case "$PKG_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    apk)
      apk add --no-cache "$@" ;;
    dnf)
      dnf install -y "$@" ;;
    yum)
      yum install -y "$@" ;;
    zypper)
      zypper --non-interactive install -y "$@" ;;
    *)
      err "Package manager not supported. Cannot install: $*"
      return 1 ;;
  esac
}

# Create non-root user if requested
ensure_user() {
  if [ "$APP_USER" = "root" ]; then
    log "Running as root user."
    return 0
  fi

  # Decide if we should create the user
  local should_create="false"
  case "$CREATE_USER" in
    auto)
      if id -u "$APP_USER" >/dev/null 2>&1; then
        should_create="false"
      else
        should_create="true"
      fi
      ;;
    always)
      if ! id -u "$APP_USER" >/dev/null 2>&1; then
        should_create="true"
      fi
      ;;
    never)
      should_create="false"
      ;;
    *)
      should_create="false"
      ;;
  esac

  if [ "$should_create" = "true" ]; then
    log "Creating user '$APP_USER' for application ownership."
    case "$PKG_MANAGER" in
      apk)
        adduser -D -h "$APP_ROOT" "$APP_USER" || true
        ;;
      apt|dnf|yum|zypper|unknown)
        if command -v useradd >/dev/null 2>&1; then
          useradd -m -d "$APP_ROOT" -s /bin/bash "$APP_USER" || true
        elif command -v adduser >/dev/null 2>&1; then
          adduser --disabled-password --gecos "" "$APP_USER" || true
        else
          warn "No useradd/adduser available; cannot create user '$APP_USER'."
        fi
        ;;
    esac
  else
    log "User '$APP_USER' exists or creation not requested."
  fi
}

# Set directory structure and permissions
setup_directories() {
  log "Setting up directory structure under $APP_ROOT"
  mkdir -p "$APP_ROOT"/{logs,tmp,data,config}
  # Do not overwrite existing .env; will create if missing later
  touch "$APP_ROOT/.setup_done" || true

  # Set ownership and permissions (idempotent)
  if id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER":"$APP_USER" "$APP_ROOT"
  fi
  chmod -R u+rwX,go-rwx "$APP_ROOT"
  chmod 1777 "$APP_ROOT/tmp" || true
}

# Detect project type(s)
PROJECT_TYPES=()
detect_project_types() {
  PROJECT_TYPES=()
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ]; then
    PROJECT_TYPES+=("python")
  fi
  if [ -f "package.json" ]; then
    PROJECT_TYPES+=("node")
  fi
  if [ -f "Gemfile" ]; then
    PROJECT_TYPES+=("ruby")
  fi
  if [ -f "go.mod" ] || ls *.go >/dev/null 2>&1; then
    PROJECT_TYPES+=("go")
  fi
  if [ -f "pom.xml" ] || [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -f "mvnw" ] || [ -f "gradlew" ]; then
    PROJECT_TYPES+=("java")
  fi
  if [ -f "composer.json" ]; then
    PROJECT_TYPES+=("php")
  fi
  if [ -f "Cargo.toml" ]; then
    PROJECT_TYPES+=("rust")
  fi

  if [ ${#PROJECT_TYPES[@]} -eq 0 ]; then
    warn "No specific project type detected. Installing only base tools."
  else
    log "Detected project types: ${PROJECT_TYPES[*]}"
  fi
}

# Install base system packages/tools for building
install_base_tools() {
  log "Installing base system packages and build tools..."
  case "$PKG_MANAGER" in
    apt)
      pm_update_once
      install_packages ca-certificates curl wget gnupg git lsb-release pkg-config \
        build-essential autoconf automake libtool
      ;;
    apk)
      install_packages ca-certificates curl wget git bash pkgconfig \
        build-base autoconf automake libtool
      ;;
    dnf)
      pm_update_once
      install_packages ca-certificates curl wget gnupg2 git pkgconfig \
        gcc gcc-c++ make autoconf automake libtool
      ;;
    yum)
      pm_update_once
      install_packages ca-certificates curl wget gnupg2 git pkgconfig \
        gcc gcc-c++ make autoconf automake libtool
      ;;
    zypper)
      pm_update_once
      install_packages ca-certificates curl wget git pkg-config \
        gcc gcc-c++ make autoconf automake libtool
      ;;
    *)
      warn "Unknown package manager; skipping base tool installation."
      ;;
  esac
}

# Language-specific installers
install_python() {
  log "Setting up Python environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages python3 python3-venv python3-pip python3-dev \
        libffi-dev libssl-dev zlib1g-dev libjpeg-dev libpq-dev
      ;;
    apk)
      install_packages python3 py3-pip python3-dev libffi-dev openssl-dev \
        zlib-dev jpeg-dev postgresql-dev
      ;;
    dnf|yum)
      install_packages python3 python3-pip python3-devel \
        libffi-devel openssl-devel zlib-devel libjpeg-turbo-devel postgresql-devel || true
      ;;
    zypper)
      install_packages python3 python3-pip python3-devel libffi-devel libopenssl-devel zlib-devel \
        libjpeg8-devel libpq-devel || true
      ;;
    *)
      warn "Package manager unknown; Python install may fail."
      ;;
  esac

  # Create/refresh virtual environment idempotently
  if [ ! -d "$PYTHON_VENV_PATH" ]; then
    log "Creating Python virtual environment at $PYTHON_VENV_PATH"
    python3 -m venv "$PYTHON_VENV_PATH"
  else
    log "Python virtual environment already exists at $PYTHON_VENV_PATH"
  fi

  # Upgrade pip and install dependencies if files exist
  if [ -x "$PYTHON_VENV_PATH/bin/pip" ]; then
    "$PYTHON_VENV_PATH/bin/pip" install --upgrade pip wheel setuptools
    if [ -f "requirements.txt" ]; then
      log "Installing Python dependencies from requirements.txt"
      "$PYTHON_VENV_PATH/bin/pip" install -r requirements.txt
    elif [ -f "pyproject.toml" ]; then
      if [ -f "poetry.lock" ] || grep -q '\[tool.poetry\]' pyproject.toml; then
        log "Installing Poetry and project dependencies"
        "$PYTHON_VENV_PATH/bin/pip" install poetry
        "$PYTHON_VENV_PATH/bin/poetry" install --no-interaction --no-ansi
      else
        log "Installing project via pip based on pyproject.toml"
        "$PYTHON_VENV_PATH/bin/pip" install .
      fi
    elif [ -f "Pipfile" ]; then
      log "Installing pipenv and project dependencies"
      "$PYTHON_VENV_PATH/bin/pip" install pipenv
      "$PYTHON_VENV_PATH/bin/pipenv" install --deploy || "$PYTHON_VENV_PATH/bin/pipenv" install
    else
      log "No Python dependency file found; skipping dependency installation."
    fi
  else
    err "pip not found in virtual environment at $PYTHON_VENV_PATH"
  fi
}

install_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MANAGER" in
    apt)
      apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg
      local node_major=""
      if command -v node >/dev/null 2>&1; then
        node_major=$(node -v | sed 's/^v//' | cut -d. -f1)
      fi
      if [ -z "$node_major" ] || [ "$node_major" -lt 22 ]; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs
      fi
      ;;
    apk)
      install_packages nodejs npm
      ;;
    dnf|yum)
      install_packages nodejs npm
      ;;
    zypper)
      install_packages nodejs14 npm14 || install_packages nodejs npm || true
      ;;
    *)
      warn "Unknown package manager; Node.js install may fail."
      ;;
  esac

  # Ensure modern package managers are available via Corepack
  corepack enable && corepack prepare pnpm@latest --activate || true

  if [ -f "package.json" ]; then
    log "Installing Node.js dependencies using: pnpm (workspace-aware)"
    # Clean existing node_modules to avoid inclusion conflicts
    bash -lc "find \"$APP_ROOT\" -type d -name node_modules -prune -exec rm -rf {} +"
    # Use pnpm via Corepack; unset NODE_ENV during install to include dev deps consistently
    bash -lc "cd \"$APP_ROOT\" && NODE_ENV= pnpm install --recursive --prefer-frozen-lockfile || NODE_ENV= pnpm install --recursive"
  else
    log "package.json not found; skipping Node.js dependency installation."
  fi
}

install_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages ruby-full bundler build-essential
      ;;
    apk)
      install_packages ruby ruby-bundler build-base
      ;;
    dnf|yum)
      install_packages ruby rubygems ruby-devel gcc gcc-c++ make
      gem install bundler || true
      ;;
    zypper)
      install_packages ruby ruby-devel rubygems gcc gcc-c++ make
      gem install bundler || true
      ;;
    *)
      warn "Unknown package manager; Ruby install may fail."
      ;;
  esac

  if [ -f "Gemfile" ]; then
    log "Installing Ruby gems via Bundler"
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs=4
  else
    log "Gemfile not found; skipping bundler installation."
  fi
}

install_go() {
  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apt) install_packages golang ;;
    apk) install_packages go ;;
    dnf|yum) install_packages golang ;;
    zypper) install_packages go || install_packages golang || true ;;
    *) warn "Unknown package manager; Go install may fail." ;;
  esac

  export GOPATH="${GOPATH:-$APP_ROOT/.go}"
  export GOBIN="${GOBIN:-$GOPATH/bin}"
  mkdir -p "$GOPATH" "$GOBIN"
  if [ -f "go.mod" ]; then
    log "Downloading Go module dependencies"
    go mod download
  fi
}

install_java() {
  log "Setting up Java environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages openjdk-17-jdk maven gradle || install_packages openjdk-11-jdk maven gradle || true
      ;;
    apk)
      install_packages openjdk17 maven gradle || install_packages openjdk11 maven gradle || true
      ;;
    dnf|yum)
      install_packages java-17-openjdk-devel maven gradle || install_packages java-11-openjdk-devel maven gradle || true
      ;;
    zypper)
      install_packages java-17-openjdk-devel maven gradle || install_packages java-11-openjdk-devel maven gradle || true
      ;;
    *)
      warn "Unknown package manager; Java install may fail."
      ;;
  esac

  if [ -f "mvnw" ]; then
    chmod +x mvnw
    log "Resolving Maven dependencies via wrapper"
    ./mvnw -B -q dependency:resolve || true
  elif [ -f "pom.xml" ]; then
    log "Resolving Maven dependencies"
    mvn -B -q dependency:resolve || true
  fi

  if [ -f "gradlew" ]; then
    chmod +x gradlew
    log "Preparing Gradle wrapper and dependency cache"
    ./gradlew --no-daemon tasks >/dev/null || true
  elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
    log "Gradle project detected; dependencies will be resolved during build."
  fi
}

install_php() {
  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages php-cli composer
      ;;
    apk)
      install_packages php-cli composer
      ;;
    dnf|yum)
      install_packages php-cli composer
      ;;
    zypper)
      install_packages php8-cli composer || install_packages php-cli composer || true
      ;;
    *)
      warn "Unknown package manager; PHP install may fail."
      ;;
  esac

  if [ -f "composer.json" ]; then
    if [ -f "composer.lock" ]; then
      log "Installing PHP dependencies via Composer (locked)"
      if [ "$APP_ENV" = "production" ]; then
        composer install --no-dev --prefer-dist --no-interaction
      else
        composer install --prefer-dist --no-interaction
      fi
    else
      log "Installing PHP dependencies via Composer"
      composer install --prefer-dist --no-interaction
    fi
  fi
}

install_rust() {
  log "Setting up Rust environment..."
  if [ "$RUST_INSTALL_METHOD" = "rustup" ]; then
    install_packages curl ca-certificates
    if ! command -v rustup >/dev/null 2>&1; then
      log "Installing rustup (Rust toolchain manager)"
      curl https://sh.rustup.rs -sSf | sh -s -- -y
      export PATH="$PATH:$HOME/.cargo/bin"
    fi
  else
    case "$PKG_MANAGER" in
      apt) install_packages rustc cargo ;;
      apk) install_packages rust cargo ;;
      dnf|yum) install_packages rust cargo ;;
      zypper) install_packages rust rust-cargo || install_packages rust cargo || true ;;
      *) warn "Unknown package manager; Rust install may fail." ;;
    esac
  fi

  if [ -f "Cargo.toml" ]; then
    log "Fetching Rust crate dependencies"
    cargo fetch || true
  fi
}

# Configure environment variables and write .env
configure_env() {
  log "Configuring environment variables"
  # Determine default port if not provided
  if [[ -z "${APP_PORT}" ]]; then
    if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^node$'; then
      APP_PORT="3000"
    elif printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^python$'; then
      # Attempt to detect Django vs Flask
      if ls manage.py >/dev/null 2>&1 || grep -qi 'django' requirements.txt 2>/dev/null; then
        APP_PORT="8000"
      else
        APP_PORT="5000"
      fi
    elif printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^java$'; then
      APP_PORT="8080"
    elif printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^php$'; then
      APP_PORT="8000"
    elif printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^go$'; then
      APP_PORT="8080"
    elif printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^rust$'; then
      APP_PORT="8080"
    else
      APP_PORT="8080"
    fi
  fi

  # Export commonly used vars for this session
  export APP_ROOT APP_USER APP_ENV APP_PORT
  export PYTHON_VENV_PATH

  # Persist to .env (append or create, idempotent line updates)
  local env_file="$APP_ROOT/.env"
  touch "$env_file"
  # Helper to set/update a key=value in env file
  set_env_kv() {
    local key="$1"; shift
    local val="$1"; shift
    if grep -qE "^${key}=" "$env_file"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$env_file"
    else
      echo "${key}=${val}" >> "$env_file"
    fi
  }

  set_env_kv "APP_ENV" "$APP_ENV"
  set_env_kv "APP_PORT" "$APP_PORT"
  set_env_kv "APP_ROOT" "$APP_ROOT"
  set_env_kv "APP_USER" "$APP_USER"

  if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^python$'; then
    set_env_kv "PYTHON_VENV_PATH" "$PYTHON_VENV_PATH"
  fi
  if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^node$'; then
    set_env_kv "NODE_ENV" "${NODE_ENV:-$APP_ENV}"
  fi
}

# Summary and usage hints
print_summary() {
  log "Environment setup completed successfully."
  echo -e "${BLUE}Project root: ${APP_ROOT}${NC}"
  echo -e "${BLUE}Project types detected: ${PROJECT_TYPES[*]:-none}${NC}"
  echo -e "${BLUE}App user: ${APP_USER}${NC}"
  echo -e "${BLUE}App environment: ${APP_ENV}${NC}"
  echo -e "${BLUE}App port: ${APP_PORT}${NC}"
  echo -e "${BLUE}.env file written to: ${APP_ROOT}/.env${NC}"

  echo "Common next steps:"
  if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^python$'; then
    echo " - Activate venv: source \"$PYTHON_VENV_PATH/bin/activate\""
    echo " - Run (Flask): python -m flask run --host=0.0.0.0 --port=${APP_PORT}"
    echo " - Run (Django): python manage.py runserver 0.0.0.0:${APP_PORT}"
  fi
  if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^node$'; then
    echo " - Start app (npm): npm start"
  fi
  if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^ruby$'; then
    echo " - Start app (Rails): bundle exec rails s -b 0.0.0.0 -p ${APP_PORT}"
  fi
  if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^php$'; then
    echo " - Start built-in server: php -S 0.0.0.0:${APP_PORT} -t public"
  fi
  if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^go$'; then
    echo " - Build: go build ./..."
    echo " - Run: ./your-binary (ensure it listens on ${APP_PORT})"
  fi
  if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^java$'; then
    echo " - Build (Maven): mvn -B package"
    echo " - Build (Gradle): ./gradlew build"
  fi
  if printf '%s\n' "${PROJECT_TYPES[@]}" | grep -q '^rust$'; then
    echo " - Build: cargo build --release"
  fi
}

setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_path="${PYTHON_VENV_PATH}"
  local activate_line=". \"${venv_path}/bin/activate\""
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# auto-activate venv in ${venv_path} if present" >> "$bashrc_file"
    echo "if [ -d \"${venv_path}\" ] && [ -f \"${venv_path}/bin/activate\" ]; then" >> "$bashrc_file"
    echo "  . \"${venv_path}/bin/activate\"" >> "$bashrc_file"
    echo "fi" >> "$bashrc_file"
  fi
}

main() {
  umask 027
  log "Starting universal project environment setup for Docker..."

  prepare_app_root
  detect_pkg_manager
  if [ "$PKG_MANAGER" = "unknown" ]; then
    warn "Could not detect package manager. Proceeding with limited setup."
  fi

  repair_apt_state
  install_base_tools
  ensure_user
  setup_directories
  detect_project_types

  # Install language runtimes and dependencies based on project type(s)
  for t in "${PROJECT_TYPES[@]}"; do
    case "$t" in
      python) install_python ;;
      node) install_node ;;
      ruby) install_ruby ;;
      go) install_go ;;
      java) install_java ;;
      php) install_php ;;
      rust) install_rust ;;
      *) warn "Unknown project type: $t" ;;
    esac
  done

  configure_env
  setup_auto_activate
  print_summary
}

# Execute
main "$@"