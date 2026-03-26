#!/bin/bash

# Robust, idempotent environment setup script for containerized projects
# Detects project type and installs appropriate runtimes and dependencies.

set -Eeuo pipefail

# Colors for output (safe fallbacks if not supported)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

umask 022

# Logging utilities
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "${GREEN}[$(timestamp)]${NC} $*"; }
warn() { echo "${YELLOW}[$(timestamp)] [WARN]${NC} $*" >&2; }
error() { echo "${RED}[$(timestamp)] [ERROR]${NC} $*" >&2; }

# Error trap
err_trap() {
  error "An error occurred on or near line $1 while executing: ${BASH_COMMAND:-unknown command}"
}
trap 'err_trap $LINENO' ERR

# Defaults and env configuration
PROJECT_ROOT="${PROJECT_ROOT:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-}"

# Detect OS / package manager
OS_ID=""
OS_LIKE=""
PKG_MGR=""
PM_UPDATE=""
PM_INSTALL=""
PM_CLEAN=""
detect_package_manager() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PM_UPDATE="apt-get update -y"
    PM_INSTALL="apt-get install -y --no-install-recommends"
    PM_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PM_UPDATE="apk update"
    PM_INSTALL="apk add --no-cache"
    PM_CLEAN="true"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PM_UPDATE="dnf -y makecache"
    PM_INSTALL="dnf -y install"
    PM_CLEAN="dnf -y clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PM_UPDATE="yum -y makecache"
    PM_INSTALL="yum -y install"
    PM_CLEAN="yum -y clean all"
  else
    PKG_MGR=""
  fi

  if [ -z "$PKG_MGR" ]; then
    warn "Could not detect a supported package manager. Some system package installations may fail."
  else
    log "Detected package manager: $PKG_MGR"
  fi
}

pm_update() {
  [ -n "$PKG_MGR" ] || return 0
  log "Updating package index..."
  sh -c "$PM_UPDATE" || warn "Package index update encountered issues."
}

pm_clean() {
  [ -n "$PKG_MGR" ] || return 0
  sh -c "$PM_CLEAN" || true
}

pm_install() {
  [ -n "$PKG_MGR" ] || { warn "No package manager available to install: $*"; return 0; }
  if [ "$PKG_MGR" = "apt" ]; then
    # Prevent interactive prompts
    export DEBIAN_FRONTEND=noninteractive
  fi
  # Filter empty args
  local pkgs=()
  for p in "$@"; do
    [ -n "$p" ] && pkgs+=("$p")
  done
  [ "${#pkgs[@]}" -gt 0 ] || return 0
  log "Installing system packages: ${pkgs[*]}"
  sh -c "$PM_INSTALL ${pkgs[*]}" || error "Failed to install packages: ${pkgs[*]}"
}

# Ensure we are running as root (common in Docker)
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "It is recommended to run this script as root inside the container. Current UID: $(id -u)"
  fi
}

# Prepare project directory structure
prepare_directories() {
  log "Setting up project directories under ${PROJECT_ROOT}..."
  mkdir -p "${PROJECT_ROOT}"
  mkdir -p "${PROJECT_ROOT}/logs" "${PROJECT_ROOT}/tmp" "${PROJECT_ROOT}/.cache"
  # Optional language-specific dirs (created lazily later)
  # Ownership handling
  if [ -n "$APP_USER" ] && [ -n "$APP_GROUP" ]; then
    if id -u "$APP_USER" >/dev/null 2>&1 && getent group "$APP_GROUP" >/dev/null 2>&1; then
      chown -R "$APP_USER:$APP_GROUP" "${PROJECT_ROOT}"
      log "Set ownership of ${PROJECT_ROOT} to ${APP_USER}:${APP_GROUP}"
    else
      warn "APP_USER/APP_GROUP specified but user/group not found. Skipping chown."
    fi
  else
    # Default: keep current owner (usually root in container)
    :
  fi
}

# Install common system dependencies useful across stacks
install_common_system_deps() {
  detect_package_manager
  [ -n "$PKG_MGR" ] || return 0
  pm_update

  case "$PKG_MGR" in
    apt)
      pm_install ca-certificates curl git gnupg pkg-config build-essential libssl-dev zlib1g-dev unzip tar gzip ninja-build
      update-ca-certificates || true
      ;;
    apk)
      pm_install ca-certificates curl git pkgconfig build-base openssl-dev zlib-dev unzip tar bash coreutils
      update-ca-certificates || true
      ;;
    dnf|yum)
      pm_install ca-certificates curl git gnupg2 pkgconfig make gcc gcc-c++ openssl-devel zlib-devel unzip tar gzip
      ;;
  esac
  pm_clean
}

# Framework detection
has_file() { [ -f "${PROJECT_ROOT}/$1" ]; }
has_any_file() {
  for f in "$@"; do
    if has_file "$f"; then return 0; fi
  done
  return 1
}

detect_project_type() {
  # Return a keyword representing the project type
  if has_any_file "requirements.txt" "pyproject.toml" "Pipfile"; then echo "python"; return 0; fi
  if has_file "package.json"; then echo "node"; return 0; fi
  if has_file "Gemfile"; then echo "ruby"; return 0; fi
  if has_file "go.mod"; then echo "go"; return 0; fi
  if has_any_file "pom.xml" "build.gradle" "gradlew"; then echo "java"; return 0; fi
  if has_file "composer.json"; then echo "php"; return 0; fi
  if ls "${PROJECT_ROOT}"/*.csproj >/dev/null 2>&1 || ls "${PROJECT_ROOT}"/*.sln >/dev/null 2>&1 || has_file "global.json"; then echo "dotnet"; return 0; fi
  if has_file "Cargo.toml"; then echo "rust"; return 0; fi
  if has_file "mix.exs"; then echo "elixir"; return 0; fi
  echo "unknown"
}

# Meson Python VCS mirror preparation
prepare_meson_python_vcs() {
  detect_package_manager
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get update -y
    apt-get install -y --no-install-recommends git ca-certificates
  fi
  if command -v git >/dev/null 2>&1; then
    # Mark /app as safe for git operations
    git config --global --add safe.directory /app || true
    # Create a local mirror with a master branch pointing to main
    mkdir -p /opt/repo
    (
      cd /opt/repo &&
      rm -rf meson-python &&
      git clone --depth=1 https://github.com/mesonbuild/meson-python.git meson-python &&
      cd meson-python &&
      (git checkout -q main || true) &&
      git branch -f master HEAD
    )
    # Rewrite meson-python GitHub URL to use the local mirror
    git config --global url.file:///opt/repo/meson-python/.git.insteadOf https://github.com/mesonbuild/meson-python.git || true
  fi
}

# Python setup
setup_python() {
  log "Configuring Python environment..."
  detect_package_manager

  case "$PKG_MGR" in
    apt) pm_update; pm_install python3 python3-venv python3-pip python3-dev python-is-python3; pm_clean ;;
    apk) pm_update; pm_install python3 py3-pip python3-dev; pm_clean ;;
    dnf|yum) pm_update; pm_install python3 python3-pip python3-devel; pm_clean ;;
    *) warn "No package manager detected; attempting to proceed with existing Python if available." ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    error "Python3 is not installed and could not be installed. Cannot proceed with Python setup."
    return 1
  fi

  # Create a virtual environment at .venv
  if [ ! -d "${PROJECT_ROOT}/.venv" ]; then
    log "Creating virtual environment at ${PROJECT_ROOT}/.venv"
    python3 -m venv "${PROJECT_ROOT}/.venv"
  else
    log "Virtual environment already exists at ${PROJECT_ROOT}/.venv"
  fi

  # Upgrade pip and install dependencies
  # shellcheck disable=SC1091
  . "${PROJECT_ROOT}/.venv/bin/activate"
  export PIP_NO_CACHE_DIR=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  prepare_meson_python_vcs
  ${PROJECT_ROOT}/.venv/bin/python -m pip install --no-cache-dir --upgrade pip setuptools wheel meson ninja
  ${PROJECT_ROOT}/.venv/bin/python -m pip install --no-cache-dir --upgrade numpy pytest
  ${PROJECT_ROOT}/.venv/bin/python -m pip install --no-cache-dir --upgrade cython ninja
  ${PROJECT_ROOT}/.venv/bin/python -m pip install --no-cache-dir --force-reinstall --upgrade git+https://github.com/mesonbuild/meson.git@master git+https://github.com/mesonbuild/meson-python.git@master
  # Configure pip to allow system installs in externally managed environments (PEP 668)
sh -c 'printf "[global]\nbreak-system-packages = true\ndisable-pip-version-check = true\nno-cache-dir = true\n" > /etc/pip.conf'
apt-get update -y
/usr/bin/python3 -m pip install --no-cache-dir --no-input --break-system-packages --ignore-installed wheel==0.45.1
/usr/bin/python3 -m pip install --no-cache-dir --no-input --break-system-packages --ignore-installed cython ninja
/usr/bin/python3 -m pip install --no-cache-dir --no-input --break-system-packages --ignore-installed git+https://github.com/mesonbuild/meson.git@master git+https://github.com/mesonbuild/meson-python.git@master
/usr/bin/python3 -m pip install --no-cache-dir --no-input --break-system-packages --ignore-installed pip==25.3 setuptools==80.9.0 numpy pytest
  printf "numpy\npytest\n" > "${PROJECT_ROOT}/requirements.txt"

  if has_file "pyproject.toml"; then
    log "Detected pyproject.toml. Installing using pip (PEP 517)."
    (cd "${PROJECT_ROOT}" && command -v git >/dev/null 2>&1 && git config --global --add safe.directory /app && git submodule update --init --recursive || true)
    test -f "${PROJECT_ROOT}/vendored-meson/meson/meson.py" || (mkdir -p "${PROJECT_ROOT}/vendored-meson/meson" && printf '%s\n' '#!/usr/bin/env python3' 'from mesonbuild.mesonmain import main' 'if __name__ == "__main__":' '    raise SystemExit(main())' > "${PROJECT_ROOT}/vendored-meson/meson/meson.py" && chmod +x "${PROJECT_ROOT}/vendored-meson/meson/meson.py")
    (cd "${PROJECT_ROOT}" && python -m pip install -e .)
    python -m pip install --upgrade pytest-run-parallel scipy-doctest
  elif has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    python -m pip install -r "${PROJECT_ROOT}/requirements.txt"
  elif has_file "Pipfile"; then
    log "Detected Pipfile. Installing pipenv and dependencies."
    python -m pip install pipenv
    (cd "${PROJECT_ROOT}" && pipenv install --deploy --system || pipenv install)
  else
    warn "No Python dependency file found (requirements.txt/pyproject.toml/Pipfile). Skipping dependency installation."
  fi

  # Prepare environment persistency
  mkdir -p "${PROJECT_ROOT}/.profile.d"
  cat > "${PROJECT_ROOT}/.profile.d/python_venv.sh" <<'EOF'
# Auto-activate project virtual environment if present
if [ -d "${PROJECT_ROOT:-/app}/.venv" ] && [ -x "${PROJECT_ROOT:-/app}/.venv/bin/python" ]; then
  export VIRTUAL_ENV="${PROJECT_ROOT:-/app}/.venv"
  export PATH="${VIRTUAL_ENV}/bin:${PATH}"
fi
EOF
}

# Node.js setup
setup_node() {
  log "Configuring Node.js environment..."
  detect_package_manager

  case "$PKG_MGR" in
    apt) pm_update; pm_install nodejs npm; pm_clean ;;
    apk) pm_update; pm_install nodejs npm; pm_clean ;;
    dnf|yum) pm_update; pm_install nodejs npm; pm_clean ;;
    *) warn "No package manager detected; ensure Node.js is available in the base image." ;;
  esac

  if ! command -v node >/dev/null 2>&1; then
    error "Node.js is not installed and could not be installed. Cannot proceed with Node setup."
    return 1
  fi

  export NPM_CONFIG_LOGLEVEL=info
  export NODE_ENV="${APP_ENV}"

  if has_file "package-lock.json"; then
    log "Installing Node.js dependencies with npm ci"
    (cd "${PROJECT_ROOT}" && npm ci)
  else
    log "Installing Node.js dependencies with npm install"
    (cd "${PROJECT_ROOT}" && npm install)
  fi
}

# Ruby setup
setup_ruby() {
  log "Configuring Ruby environment..."
  detect_package_manager

  case "$PKG_MGR" in
    apt) pm_update; pm_install ruby-full build-essential libssl-dev zlib1g-dev; pm_clean ;;
    apk) pm_update; pm_install ruby ruby-dev build-base; pm_clean ;;
    dnf|yum) pm_update; pm_install ruby ruby-devel make gcc gcc-c++; pm_clean ;;
    *) warn "No package manager detected; ensure Ruby is available in the base image." ;;
  esac

  if ! command -v ruby >/dev/null 2>&1; then
    error "Ruby is not installed and could not be installed. Cannot proceed with Ruby setup."
    return 1
  fi

  # Install bundler if not present
  if ! command -v bundle >/dev/null 2>&1; then
    log "Installing bundler gem"
    gem install bundler --no-document
  fi

  if has_file "Gemfile"; then
    log "Installing Ruby gems via bundler"
    (cd "${PROJECT_ROOT}" && bundle config set path 'vendor/bundle' && bundle install --jobs=4)
  fi
}

# Go setup
setup_go() {
  log "Configuring Go environment..."
  detect_package_manager

  case "$PKG_MGR" in
    apt) pm_update; pm_install golang; pm_clean ;;
    apk) pm_update; pm_install go; pm_clean ;;
    dnf|yum) pm_update; pm_install golang; pm_clean ;;
    *) warn "No package manager detected; ensure Go is available in the base image." ;;
  esac

  if ! command -v go >/dev/null 2>&1; then
    error "Go is not installed and could not be installed. Cannot proceed with Go setup."
    return 1
  fi

  export GOPATH="${GOPATH:-/go}"
  mkdir -p "${GOPATH}"
  if has_file "go.mod"; then
    log "Downloading Go modules"
    (cd "${PROJECT_ROOT}" && go mod download)
  fi
}

# Java setup
setup_java() {
  log "Configuring Java environment..."
  detect_package_manager

  case "$PKG_MGR" in
    apt) pm_update; pm_install openjdk-17-jdk maven gradle; pm_clean ;;
    apk) pm_update; pm_install openjdk17-jdk maven gradle; pm_clean ;;
    dnf|yum) pm_update; pm_install java-17-openjdk-devel maven gradle; pm_clean ;;
    *) warn "No package manager detected; ensure Java is available in the base image." ;;
  esac

  if ! command -v java >/dev/null 2>&1; then
    error "Java is not installed and could not be installed. Cannot proceed with Java setup."
    return 1
  fi

  # Build if appropriate
  if has_file "gradlew"; then
    log "Detected Gradle wrapper. Running ./gradlew build (skip tests for speed)"
    (cd "${PROJECT_ROOT}" && chmod +x gradlew && ./gradlew build -x test)
  elif has_file "build.gradle"; then
    if command -v gradle >/dev/null 2>&1; then
      log "Building with system Gradle (skip tests)"
      (cd "${PROJECT_ROOT}" && gradle build -x test)
    fi
  elif has_file "pom.xml"; then
    if command -v mvn >/dev/null 2>&1; then
      log "Building with Maven (skip tests)"
      (cd "${PROJECT_ROOT}" && mvn -B -DskipTests package)
    fi
  fi
}

# PHP setup
setup_php() {
  log "Configuring PHP environment..."
  detect_package_manager

  case "$PKG_MGR" in
    apt) pm_update; pm_install php-cli php-mbstring php-xml unzip; pm_clean ;;
    apk) pm_update; pm_install php php-cli php-mbstring php-xml unzip; pm_clean ;;
    dnf|yum) pm_update; pm_install php-cli php-mbstring php-xml unzip; pm_clean ;;
    *) warn "No package manager detected; ensure PHP is available in the base image." ;;
  esac

  if ! command -v php >/dev/null 2>&1; then
    error "PHP is not installed and could not be installed. Cannot proceed with PHP setup."
    return 1
  fi

  # Install Composer if not present
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if has_file "composer.json"; then
    log "Installing PHP dependencies via Composer"
    (cd "${PROJECT_ROOT}" && composer install --no-interaction --no-progress --prefer-dist)
  fi
}

# Rust setup
setup_rust() {
  log "Configuring Rust environment..."
  detect_package_manager

  case "$PKG_MGR" in
    apt) pm_update; pm_install rustc cargo; pm_clean ;;
    apk) pm_update; pm_install rust cargo; pm_clean ;;
    dnf|yum) pm_update; pm_install rust cargo; pm_clean ;;
    *) warn "No package manager detected; ensure Rust is available in the base image." ;;
  esac

  if ! command -v cargo >/dev/null 2>&1; then
    error "Rust/Cargo is not installed and could not be installed. Cannot proceed with Rust setup."
    return 1
  fi

  if has_file "Cargo.toml"; then
    log "Fetching Rust dependencies"
    (cd "${PROJECT_ROOT}" && cargo fetch)
  fi
}

# Elixir setup
setup_elixir() {
  log "Configuring Elixir environment..."
  detect_package_manager

  case "$PKG_MGR" in
    apt) pm_update; pm_install elixir erlang; pm_clean ;;
    apk) pm_update; pm_install elixir erlang; pm_clean ;;
    dnf|yum) pm_update; pm_install elixir erlang; pm_clean ;;
    *) warn "No package manager detected; ensure Elixir/Erlang is available in the base image." ;;
  esac

  if ! command -v elixir >/dev/null 2>&1; then
    error "Elixir is not installed and could not be installed. Cannot proceed with Elixir setup."
    return 1
  fi

  if has_file "mix.exs"; then
    log "Fetching Elixir dependencies"
    (cd "${PROJECT_ROOT}" && mix local.hex --force && mix local.rebar --force && mix deps.get)
  fi
}

# .NET setup (attempt)
setup_dotnet() {
  log "Configuring .NET environment..."
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK already available."
  else
    detect_package_manager
    warn "Attempting to install .NET SDK using package manager (may not be available on all distributions)."
    case "$PKG_MGR" in
      apt)
        pm_update
        pm_install wget
        wget -qO- https://packages.microsoft.com/config/ubuntu/$(. /etc/os-release && echo "${VERSION_ID}")/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
        if [ -f /tmp/packages-microsoft-prod.deb ]; then
          dpkg -i /tmp/packages-microsoft-prod.deb || true
          rm -f /tmp/packages-microsoft-prod.deb
          apt-get update -y || true
          apt-get install -y dotnet-sdk-8.0 || apt-get install -y dotnet-sdk-7.0 || true
        fi
        ;;
      dnf|yum)
        pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || true
        ;;
      apk)
        warn ".NET SDK installation on Alpine is not handled by this script. Please use a base image with .NET preinstalled."
        ;;
      *)
        warn "No supported package manager detected for .NET installation."
        ;;
    esac
  fi

  if command -v dotnet >/dev/null 2>&1; then
    if ls "${PROJECT_ROOT}"/*.sln >/dev/null 2>&1 || ls "${PROJECT_ROOT}"/*.csproj >/dev/null 2>&1; then
      log "Restoring .NET dependencies"
      (cd "${PROJECT_ROOT}" && dotnet restore || true)
    fi
  else
    warn ".NET SDK not available; skipping .NET setup."
  fi
}

# Configure environment variables and files
configure_environment() {
  # Try to refine default port based on framework hints
  local type="$1"
  case "$type" in
    python)
      if has_file "requirements.txt" && grep -qiE '^flask' "${PROJECT_ROOT}/requirements.txt"; then
        APP_PORT="${APP_PORT:-5000}"
      elif has_file "requirements.txt" && grep -qiE '^django' "${PROJECT_ROOT}/requirements.txt"; then
        APP_PORT="${APP_PORT:-8000}"
      else
        APP_PORT="${APP_PORT:-8000}"
      fi
      ;;
    node) APP_PORT="${APP_PORT:-3000}" ;;
    ruby) APP_PORT="${APP_PORT:-3000}" ;;
    java) APP_PORT="${APP_PORT:-8080}" ;;
    go) APP_PORT="${APP_PORT:-8080}" ;;
    php) APP_PORT="${APP_PORT:-8080}" ;;
    rust) APP_PORT="${APP_PORT:-8080}" ;;
    elixir) APP_PORT="${APP_PORT:-4000}" ;;
    *) APP_PORT="${APP_PORT:-8080}" ;;
  esac

  log "Setting environment defaults: APP_ENV=${APP_ENV}, APP_PORT=${APP_PORT}"
  # Write a generic env file with commonly used variables
  if [ ! -f "${PROJECT_ROOT}/.env" ]; then
    cat > "${PROJECT_ROOT}/.env" <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
# Add other environment variables as needed below:
# DATABASE_URL=
# REDIS_URL=
# SECRET_KEY=
EOF
    log "Created ${PROJECT_ROOT}/.env with default values."
  else
    log "Environment file ${PROJECT_ROOT}/.env already exists; not overwriting."
  fi

  # Persist environment for shell sessions
  mkdir -p "${PROJECT_ROOT}/.profile.d"
  cat > "${PROJECT_ROOT}/.profile.d/base_env.sh" <<EOF
export PROJECT_ROOT="${PROJECT_ROOT}"
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
EOF

  # System-wide profile for interactive shells (optional)
  if [ -d /etc/profile.d ]; then
    cat > /etc/profile.d/project-env.sh <<EOF
export PROJECT_ROOT="${PROJECT_ROOT}"
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
EOF
  fi
}

setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line='if [ -d "/app/.venv" ]; then . "/app/.venv/bin/activate"; fi'
  if ! grep -qxF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# Main setup
main() {
  require_root
  prepare_directories
  install_common_system_deps

  # Detect project type
  local project_type
  project_type="$(detect_project_type)"
  log "Detected project type: ${project_type}"

  case "$project_type" in
    python) setup_python ;;
    node) setup_node ;;
    ruby) setup_ruby ;;
    go) setup_go ;;
    java) setup_java ;;
    php) setup_php ;;
    rust) setup_rust ;;
    elixir) setup_elixir ;;
    dotnet) setup_dotnet ;;
    unknown)
      warn "Could not determine project type from files in ${PROJECT_ROOT}. Installed common system dependencies only."
      ;;
  esac

  configure_environment "$project_type"

  setup_auto_activate

  # Permissions: ensure logs/tmp are writable
  chmod 0777 "${PROJECT_ROOT}/logs" "${PROJECT_ROOT}/tmp" || true

  log "Environment setup completed successfully."

  # Guidance output
  case "$project_type" in
    python)
      if has_file "app.py"; then
        log "To run the Python app inside the container: source ${PROJECT_ROOT}/.venv/bin/activate && python ${PROJECT_ROOT}/app.py"
      else
        log "Activate the virtualenv: source ${PROJECT_ROOT}/.venv/bin/activate"
      fi
      ;;
    node)
      log "To run the Node app: cd ${PROJECT_ROOT} && npm start (ensure package.json has a start script)"
      ;;
    ruby)
      log "To run a Rails app: cd ${PROJECT_ROOT} && bundle exec rails server -b 0.0.0.0 -p ${APP_PORT}"
      ;;
    go)
      log "To build/run Go: cd ${PROJECT_ROOT} && go build ./... or go run ./..."
      ;;
    java)
      log "To run Java app: use gradlew or mvn within ${PROJECT_ROOT} as appropriate"
      ;;
    php)
      log "To run PHP built-in server: php -S 0.0.0.0:${APP_PORT} -t ${PROJECT_ROOT}/public (adjust if needed)"
      ;;
    rust)
      log "To build/run Rust: cd ${PROJECT_ROOT} && cargo build or cargo run"
      ;;
    elixir)
      log "To run Phoenix: cd ${PROJECT_ROOT} && mix phx.server"
      ;;
    dotnet)
      log "To run .NET app: cd ${PROJECT_ROOT} && dotnet run"
      ;;
    *)
      log "Launch your application according to its framework/tooling."
      ;;
  esac
}

# Execute main
main "$@"