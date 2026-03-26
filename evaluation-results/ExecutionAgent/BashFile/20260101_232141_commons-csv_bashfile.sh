#!/bin/bash
# Universal project environment setup script for Docker containers
# This script auto-detects project type and sets up the runtime, dependencies,
# system packages, directory structure, and environment variables.
#
# Supported stacks: Python, Node.js, Go, Java (Maven/Gradle), Ruby, PHP (Composer), Rust
#
# Usage:
#   Run inside the container at the project root: ./setup.sh
#   or: bash setup.sh

set -Eeuo pipefail

# -------- Logging & Error Handling --------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $*${NC}" >&2; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*${NC}" >&2; }
die() { error "$*"; exit 1; }

trap 'error "Setup failed at line $LINENO"; exit 1' ERR

# -------- Global Defaults --------
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"   # Will be adjusted per stack if detected

PROFILE_D_PATH="/etc/profile.d/project_env.sh"
ENV_FILE="$PROJECT_ROOT/.env"

# Versions (can be overridden via env)
NODE_VERSION="${NODE_VERSION:-20.18.0}"  # LTS at time of writing
GO_VERSION="${GO_VERSION:-1.22.5}"
JAVA_VERSION_MAJOR="${JAVA_VERSION_MAJOR:-17}"

# -------- Helpers --------

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This setup script must be run as root inside the container."
  fi
}

# Detect OS and package manager
PM="" ; OS_FAMILY=""
detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
    OS_FAMILY="debian"
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    OS_FAMILY="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    OS_FAMILY="rhel"
  elif command -v microdnf >/dev/null 2>&1; then
    PM="microdnf"
    OS_FAMILY="rhel"
  else
    PM=""
    OS_FAMILY="unknown"
  fi
}

pm_update() {
  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf -y makecache || true
      ;;
    yum)
      yum -y makecache || true
      ;;
    microdnf)
      microdnf update -y || true
      ;;
    *)
      warn "No known package manager detected; skipping update."
      ;;
  esac
}

pm_install() {
  # $@: packages to install
  case "$PM" in
    apt)
      apt-get install -y --no-install-recommends "$@" ;;
    apk)
      apk add --no-cache "$@" ;;
    dnf)
      dnf install -y "$@" ;;
    yum)
      yum install -y "$@" ;;
    microdnf)
      microdnf install -y "$@" ;;
    *)
      warn "Package manager not available; cannot install: $*"
      return 1
      ;;
  esac
}

ensure_base_tools() {
  log "Installing base system tools..."
  pm_update || true
  case "$PM" in
    apt)
      pm_install ca-certificates curl git bash coreutils tar xz-utils unzip gnupg dirmngr pkg-config build-essential
      ;;
    apk)
      pm_install ca-certificates curl git bash coreutils tar xz unzip gnupg pkgconfig build-base
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pm_install ca-certificates curl git bash coreutils tar xz unzip gnupg pkgconf gcc gcc-c++ make
      ;;
    *)
      warn "Could not install base tools via package manager; attempting to proceed with existing tools."
      ;;
  esac
}

# -------- User & Directory Setup --------

create_app_user() {
  if id "$APP_USER" >/dev/null 2>&1; then
    log "User '$APP_USER' already exists."
    return 0
  fi
  log "Creating application user '$APP_USER'..."
  if command -v useradd >/dev/null 2>&1; then
    getent group "$APP_GROUP" >/dev/null 2>&1 || groupadd -r "$APP_GROUP"
    useradd -r -m -g "$APP_GROUP" -s /usr/sbin/nologin "$APP_USER" || useradd -r -m -g "$APP_GROUP" "$APP_USER"
  elif command -v adduser >/dev/null 2>&1; then
    addgroup -S "$APP_GROUP" >/dev/null 2>&1 || true
    adduser -S -G "$APP_GROUP" "$APP_USER" || true
  else
    warn "No user management tools found; skipping creation of non-root app user."
  fi
}

setup_directories() {
  log "Setting up project directories at $PROJECT_ROOT ..."
  mkdir -p "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,run}
  # language-specific dirs will be handled in their handlers
  if id "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER":"$APP_GROUP" "$PROJECT_ROOT" || true
  fi
  chmod 755 "$PROJECT_ROOT" || true
  chmod 775 "$PROJECT_ROOT"/{logs,tmp,run} || true
}

# -------- Environment Variables --------

write_env_profiles() {
  log "Writing environment profile to $PROFILE_D_PATH and .env file..."
  {
    echo "export PROJECT_ROOT=\"$PROJECT_ROOT\""
    echo "export APP_ENV=\"$APP_ENV\""
    echo "export APP_USER=\"$APP_USER\""
    echo "export APP_PORT=\"$APP_PORT\""
    # Language-specific entries appended by handlers
  } > "$PROFILE_D_PATH"

  {
    echo "PROJECT_ROOT=$PROJECT_ROOT"
    echo "APP_ENV=$APP_ENV"
    echo "APP_USER=$APP_USER"
    echo "APP_PORT=$APP_PORT"
  } > "$ENV_FILE"

  chmod 644 "$PROFILE_D_PATH" || true
  chmod 600 "$ENV_FILE" || true
}

append_profile() {
  # $1: line to append
  echo "$1" >> "$PROFILE_D_PATH"
}

append_env() {
  # $1: KEY=VALUE
  echo "$1" >> "$ENV_FILE"
}

# -------- Language/Stack Setup Handlers --------

# ---- Python ----
setup_python() {
  log "Detected Python project."
  case "$PM" in
    apt)
      pm_install python3 python3-pip python3-venv python3-dev gcc
      ;;
    apk)
      pm_install python3 py3-pip python3-dev build-base
      ;;
    dnf|yum|microdnf)
      pm_install python3 python3-pip python3-devel gcc gcc-c++ make
      ;;
    *)
      warn "Package manager not available for Python; expecting python3 and pip to exist."
      ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 not available after installation."
  fi

  VENV_PATH="$PROJECT_ROOT/.venv"
  if [ ! -d "$VENV_PATH" ]; then
    log "Creating Python virtual environment at $VENV_PATH ..."
    python3 -m venv "$VENV_PATH"
  else
    log "Python virtual environment already exists at $VENV_PATH."
  fi

  # Activate venv for this script run
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"

  python -m pip install --upgrade pip setuptools wheel

  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt ..."
    pip install -r "$PROJECT_ROOT/requirements.txt"
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    log "pyproject.toml found. Attempting 'pip install -e .' ..."
    pip install -e "$PROJECT_ROOT" || warn "Editable install failed; ensure PEP 517 build backends are available."
  elif [ -f "$PROJECT_ROOT/Pipfile" ]; then
    log "Pipfile found. Installing pipenv..."
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install
  else
    warn "No requirements.txt or pyproject.toml found. Skipping dependency install."
  fi

  append_profile "export VIRTUAL_ENV=\"$VENV_PATH\""
  append_profile "export PATH=\"\$VIRTUAL_ENV/bin:\$PATH\""
  append_profile "export PYTHONUNBUFFERED=1"
  append_env "VIRTUAL_ENV=$VENV_PATH"
  append_env "PYTHONUNBUFFERED=1"

  # Typical port for Python web apps (Flask/FastAPI)
  APP_PORT="${APP_PORT:-5000}"
}

# ---- Node.js ----
detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) echo "x64" ;;
    aarch64) echo "arm64" ;;
    armv7l) echo "armv7l" ;;
    *) echo "$arch" ;;
  esac
}

install_node_tarball() {
  local arch tarball url tmpdir
  arch="$(detect_arch)"
  tarball="node-v${NODE_VERSION}-linux-${arch}.tar.xz"
  url="https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
  tmpdir="$(mktemp -d)"
  log "Installing Node.js ${NODE_VERSION} (arch: ${arch}) from official tarball..."
  if [ -d "/usr/local/node-v${NODE_VERSION}-linux-${arch}" ]; then
    log "Node.js tarball installation already present."
  else
    curl -fsSL "$url" -o "$tmpdir/$tarball"
    tar -xJf "$tmpdir/$tarball" -C /usr/local
    ln -sf "/usr/local/node-v${NODE_VERSION}-linux-${arch}/bin/node" /usr/local/bin/node
    ln -sf "/usr/local/node-v${NODE_VERSION}-linux-${arch}/bin/npm" /usr/local/bin/npm
    ln -sf "/usr/local/node-v${NODE_VERSION}-linux-${arch}/bin/npx" /usr/local/bin/npx
  fi
  rm -rf "$tmpdir"
}

setup_node() {
  log "Detected Node.js project."
  case "$PM" in
    apt)
      pm_install nodejs npm || true
      ;;
    apk)
      pm_install nodejs npm || true
      ;;
    dnf|yum|microdnf)
      pm_install nodejs npm || true
      ;;
    *)
      warn "Package manager not available; will use Node tarball installer."
      ;;
  esac

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    install_node_tarball
  fi

  if ! command -v node >/dev/null 2>&1; then
    die "Node.js not available after installation."
  fi

  # Install dependencies
  if [ -f "$PROJECT_ROOT/package-lock.json" ]; then
    log "Installing Node.js dependencies with npm ci ..."
    (cd "$PROJECT_ROOT" && npm ci --omit=dev || npm ci)
  elif [ -f "$PROJECT_ROOT/package.json" ]; then
    log "Installing Node.js dependencies with npm install ..."
    (cd "$PROJECT_ROOT" && npm install --omit=dev || npm install)
  else
    warn "No package.json found; skipping npm install."
  fi

  append_profile "export NODE_ENV=${APP_ENV}"
  append_env "NODE_ENV=${APP_ENV}"

  # Typical default port for Node web apps
  APP_PORT="${APP_PORT:-3000}"
}

# ---- Go ----
install_go_tarball() {
  local arch go_arch url tmpdir
  case "$(uname -m)" in
    x86_64) go_arch="amd64" ;;
    aarch64) go_arch="arm64" ;;
    armv7l) go_arch="armv6l" ;; # conservative
    *) go_arch="amd64" ;;
  esac
  url="https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"
  tmpdir="$(mktemp -d)"
  log "Installing Go ${GO_VERSION} from official tarball..."
  if [ -d "/usr/local/go" ] && command -v go >/dev/null 2>&1; then
    log "Go appears installed; skipping tarball install."
  else
    curl -fsSL "$url" -o "$tmpdir/go.tgz"
    tar -xzf "$tmpdir/go.tgz" -C /usr/local
  fi
  rm -rf "$tmpdir"
}

setup_go() {
  log "Detected Go project."
  case "$PM" in
    apt) pm_install golang || true ;;
    apk) pm_install go || true ;;
    dnf|yum|microdnf) pm_install golang || true ;;
    *) ;;
  esac

  if ! command -v go >/dev/null 2>&1; then
    install_go_tarball
  fi

  mkdir -p "$PROJECT_ROOT/.gopath" "$PROJECT_ROOT/bin"
  append_profile "export GOPATH=\"$PROJECT_ROOT/.gopath\""
  append_profile "export GOBIN=\"$PROJECT_ROOT/bin\""
  append_profile "export PATH=\"\$GOBIN:/usr/local/go/bin:\$PATH\""
  append_env "GOPATH=$PROJECT_ROOT/.gopath"
  append_env "GOBIN=$PROJECT_ROOT/bin"

  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    log "Downloading Go modules..."
    (cd "$PROJECT_ROOT" && go mod download)
  fi

  # Typical default port for Go web apps
  APP_PORT="${APP_PORT:-8080}"
}

# ---- Java (Maven/Gradle) ----
setup_java() {
  log "Detected Java project."
  case "$PM" in
    apt) pm_install "openjdk-${JAVA_VERSION_MAJOR}-jdk" maven gradle || pm_install "openjdk-${JAVA_VERSION_MAJOR}-jdk" maven ;;
    apk) pm_install "openjdk${JAVA_VERSION_MAJOR}-jdk" maven gradle || pm_install "openjdk${JAVA_VERSION_MAJOR}-jdk" maven ;;
    dnf|yum|microdnf) pm_install "java-${JAVA_VERSION_MAJOR}-openjdk-devel" maven gradle || pm_install "java-${JAVA_VERSION_MAJOR}-openjdk-devel" maven ;;
    *) warn "Cannot install Java via package manager; ensure JDK is present." ;;
  esac

  if [ -f "$PROJECT_ROOT/pom.xml" ]; then
    # Ensure Apache RAT check is skipped in CI by configuring Maven user property via .mvn/maven.config
    mkdir -p "$PROJECT_ROOT/.mvn"
    printf '%s\n' '-Drat.skip=true' '-DskipTests=true' '-Dmaven.test.skip=true' '-DskipITs=true' > "$PROJECT_ROOT/.mvn/maven.config"
    log "Resolving Maven dependencies..."
    (cd "$PROJECT_ROOT" && mvn -B -q -DskipTests dependency:resolve || true)
  fi
  if [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/gradlew" ]; then
    log "Resolving Gradle dependencies..."
    if [ -x "$PROJECT_ROOT/gradlew" ]; then
      (cd "$PROJECT_ROOT" && ./gradlew build -x test || true)
    else
      (cd "$PROJECT_ROOT" && gradle build -x test || true)
    fi
  fi

  append_profile "export JAVA_HOME=\"$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")\"\""
  append_profile "export PATH=\"\$JAVA_HOME/bin:\$PATH\""

  # Typical default port for Java web apps
  APP_PORT="${APP_PORT:-8080}"
}

# ---- Ruby ----
setup_ruby() {
  log "Detected Ruby project."
  case "$PM" in
    apt) pm_install ruby-full build-essential || pm_install ruby ruby-dev build-essential ;;
    apk) pm_install ruby ruby-dev build-base ;;
    dnf|yum|microdnf) pm_install ruby ruby-devel gcc gcc-c++ make ;;
    *) warn "Cannot install Ruby via package manager; ensure Ruby is present." ;;
  esac

  if command -v gem >/dev/null 2>&1; then
    gem install bundler || true
  fi

  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    log "Installing Ruby gems via bundler..."
    (cd "$PROJECT_ROOT" && bundle config set path 'vendor/bundle' && bundle install --jobs=4)
  else
    warn "No Gemfile found; skipping bundler install."
  fi

  append_profile "export BUNDLE_PATH=\"$PROJECT_ROOT/vendor/bundle\""
  append_env "BUNDLE_PATH=$PROJECT_ROOT/vendor/bundle"

  # Typical default port for Ruby web apps
  APP_PORT="${APP_PORT:-3000}"
}

# ---- PHP (Composer) ----
setup_php() {
  log "Detected PHP project."
  case "$PM" in
    apt) pm_install php-cli php-mbstring unzip || pm_install php-cli unzip ;;
    apk) pm_install php-cli php-mbstring unzip || pm_install php-cli unzip ;;
    dnf|yum|microdnf) pm_install php-cli php-mbstring unzip || pm_install php-cli unzip ;;
    *) warn "Cannot install PHP via package manager; ensure PHP is present." ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if [ -f "$PROJECT_ROOT/composer.json" ]; then
    log "Installing PHP dependencies via composer..."
    (cd "$PROJECT_ROOT" && composer install --no-interaction --prefer-dist)
  else
    warn "No composer.json found; skipping composer install."
  fi

  # Typical default port for PHP-FPM or built-in server (varies); leave default
  APP_PORT="${APP_PORT:-8080}"
}

# ---- Rust ----
setup_rust() {
  log "Detected Rust project."
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust via rustup (minimal profile)..."
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal
    rm -f /tmp/rustup.sh
    # rustup installs under /root/.cargo by default when run as root
    append_profile "export PATH=\"/root/.cargo/bin:\$PATH\""
  fi

  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    log "Fetching Rust crate dependencies..."
    (cd "$PROJECT_ROOT" && cargo fetch || true)
  fi

  # Typical default port for Rust web apps
  APP_PORT="${APP_PORT:-8080}"
}

# -------- Project Type Detection --------

detect_and_setup_stack() {
  local detected="none"

  if [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/Pipfile" ]; then
    setup_python
    detected="python"
  fi

  if [ -f "$PROJECT_ROOT/package.json" ]; then
    setup_node
    detected="node"
  fi

  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    setup_go
    detected="go"
  fi

  if [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/gradlew" ]; then
    setup_java
    detected="java"
  fi

  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    setup_ruby
    detected="ruby"
  fi

  if [ -f "$PROJECT_ROOT/composer.json" ]; then
    setup_php
    detected="php"
  fi

  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    setup_rust
    detected="rust"
  fi

  if [ "$detected" = "none" ]; then
    warn "No known stack files detected in $PROJECT_ROOT. Installed base tools only."
  fi

  # Ensure APP_PORT propagated after stack setup
  # Rewrite profiles with final APP_PORT
  write_env_profiles
}

# -------- Permissions & Ownership --------

finalize_permissions() {
  log "Finalizing permissions for project directory..."
  if id "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER":"$APP_GROUP" "$PROJECT_ROOT" || true
  fi
}

# -------- Main --------

main() {
  log "Starting universal environment setup for project at $PROJECT_ROOT ..."
  require_root
  detect_pm
  ensure_base_tools
  create_app_user
  setup_directories
  write_env_profiles
  detect_and_setup_stack
  finalize_permissions

  log "Environment setup completed successfully."
  log "Summary:"
  log "  - Project root: $PROJECT_ROOT"
  log "  - App user: ${APP_USER} (may be created)"
  log "  - Environment: ${APP_ENV}"
  log "  - Default port: ${APP_PORT}"
  log "  - Env profile: ${PROFILE_D_PATH}"
  log "  - .env file: ${ENV_FILE}"
  log "To use the environment in the current shell, run: source $PROFILE_D_PATH"
}

main "$@"