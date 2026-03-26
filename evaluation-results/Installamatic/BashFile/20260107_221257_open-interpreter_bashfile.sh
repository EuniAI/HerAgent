#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type(s) and installs required runtimes and dependencies
# - Installs necessary system packages and build tools
# - Sets up project directory structure and permissions
# - Configures environment variables and runtime settings
# - Idempotent and safe to run multiple times
# - Designed to run as root inside a Docker container

set -Eeuo pipefail

# Strict IFS and safer pathname expansion
IFS=$'\n\t'
umask 027

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# Logging
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
err()  { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }

# Trap for errors
on_error() {
  err "Failed at line $1 with exit code $2"
}
trap 'on_error "$LINENO" "$?"' ERR

# Defaults (overridable via env)
APP_HOME="${APP_HOME:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
APP_SHELL="${APP_SHELL:-/bin/bash}"
PORT="${PORT:-}"
DEBIAN_FRONTEND=noninteractive

# Cache directory for idempotence markers
SETUP_CACHE_DIR="${APP_HOME}/.setup-cache"
mkdir -p "${SETUP_CACHE_DIR}"

# Ensure running as root
require_root() {
  if [ "${EUID}" -ne 0 ]; then
    err "This script must be run as root inside the container."
    exit 1
  fi
}

# Detect package manager
PKG_MGR=""
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    err "No supported package manager found (apt, apk, dnf, yum)."
    exit 1
  fi
  log "Detected package manager: ${PKG_MGR}"
}

# Update package lists (idempotent)
pm_update() {
  case "$PKG_MGR" in
    apt)
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache
      ;;
  esac
}

# Install packages
pm_install() {
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
  esac
}

# Install basic tools and build chain
install_base_tools() {
  log "Installing base system tools and build chain..."
  pm_update
  case "$PKG_MGR" in
    apt)
      pm_install ca-certificates curl git gnupg pkg-config build-essential zip unzip xz-utils software-properties-common
      ;;
    apk)
      pm_install ca-certificates curl git build-base pkgconfig bash coreutils findutils zip unzip
      update-ca-certificates || true
      ;;
    dnf)
      pm_install ca-certificates curl git gnupg2 pkgconfig gcc gcc-c++ make which tar gzip zip unzip
      ;;
    yum)
      pm_install ca-certificates curl git gnupg2 pkgconfig gcc gcc-c++ make which tar gzip zip unzip
      ;;
  esac
  log "Base tools installed."
}

# Ensure bash is present (script uses bash)
ensure_bash() {
  if ! command -v bash >/dev/null 2>&1; then
    log "Bash not found. Installing bash..."
    case "$PKG_MGR" in
      apt) pm_install bash ;;
      apk) pm_install bash ;;
      dnf) pm_install bash ;;
      yum) pm_install bash ;;
    esac
  fi
}

# Create app group/user idempotently
ensure_app_user() {
  log "Ensuring application user/group exist..."
  # Create group if not exists
  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apk) addgroup -g "${APP_GID}" -S "${APP_GROUP}" ;;
      *)   groupadd -g "${APP_GID}" -r "${APP_GROUP}" ;;
    esac
  fi
  # Create user if not exists
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apk) adduser -S -D -H -s "${APP_SHELL}" -G "${APP_GROUP}" -u "${APP_UID}" "${APP_USER}" ;;
      *)   useradd -r -m -d "${APP_HOME}" -s "${APP_SHELL}" -g "${APP_GROUP}" -u "${APP_UID}" "${APP_USER}" ;;
    esac
  fi
}

# Create directory structure and permissions
setup_directories() {
  log "Setting up project directories under ${APP_HOME}..."
  mkdir -p "${APP_HOME}"/{logs,tmp,data,bin}
  mkdir -p "${SETUP_CACHE_DIR}"
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_HOME}"
  chmod 0750 "${APP_HOME}"
  chmod -R 0750 "${APP_HOME}/logs" "${APP_HOME}/tmp" "${APP_HOME}/data" || true
}

# Compute combined checksum for idempotence
files_checksum() {
  local out=""
  for f in "$@"; do
    if [ -f "$f" ]; then
      out+=$(sha256sum "$f" | awk '{print $1}')
      out+=$'\n'
    fi
  done
  printf "%s" "$(echo -n "${out}" | sha256sum | awk '{print $1}')"
}

# Project detection
IS_PY=0; IS_NODE=0; IS_JAVA_MAVEN=0; IS_JAVA_GRADLE=0; IS_RUBY=0; IS_PHP=0; IS_GO=0; IS_RUST=0; IS_DOTNET=0
detect_project_types() {
  log "Detecting project types..."
  [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f Pipfile ] && IS_PY=1
  [ -f package.json ] && IS_NODE=1
  [ -f pom.xml ] && IS_JAVA_MAVEN=1
  { [ -f build.gradle ] || [ -f build.gradle.kts ]; } && IS_JAVA_GRADLE=1
  [ -f Gemfile ] && IS_RUBY=1
  [ -f composer.json ] && IS_PHP=1
  [ -f go.mod ] && IS_GO=1
  [ -f Cargo.toml ] && IS_RUST=1
  ls *.sln *.csproj >/dev/null 2>&1 && IS_DOTNET=1 || true

  info "Detected: $( [ $IS_PY -eq 1 ] && echo -n 'Python ' )$( [ $IS_NODE -eq 1 ] && echo -n 'Node.js ' )$( [ $IS_JAVA_MAVEN -eq 1 ] && echo -n 'Java-Maven ' )$( [ $IS_JAVA_GRADLE -eq 1 ] && echo -n 'Java-Gradle ' )$( [ $IS_RUBY -eq 1 ] && echo -n 'Ruby ' )$( [ $IS_PHP -eq 1 ] && echo -n 'PHP ' )$( [ $IS_GO -eq 1 ] && echo -n 'Go ' )$( [ $IS_RUST -eq 1 ] && echo -n 'Rust ' )$( [ $IS_DOTNET -eq 1 ] && echo -n '.NET ' )"
}

# Install Python and set up venv
install_python() {
  log "Installing Python runtime and dev tools..."
  case "$PKG_MGR" in
    apt)
      pm_install python3 python3-pip python3-venv python3-dev build-essential
      ;;
    apk)
      pm_install python3 py3-pip py3-setuptools py3-virtualenv build-base
      ;;
    dnf|yum)
      pm_install python3 python3-pip python3-devel gcc gcc-c++ make
      ;;
  esac
  log "Python installed."
}

setup_python_env() {
  [ $IS_PY -eq 1 ] || return 0
  install_python

  local VENV_DIR="${APP_HOME}/.venv"
  if [ ! -d "${VENV_DIR}" ]; then
    log "Creating Python virtual environment at ${VENV_DIR}..."
    python3 -m venv "${VENV_DIR}"
    chown -R "${APP_USER}:${APP_GROUP}" "${VENV_DIR}"
  else
    log "Reusing existing Python virtual environment."
  fi

  # Upgrade pip and install dependencies if changed
  local checksum_file="${SETUP_CACHE_DIR}/requirements.sha256"
  local req_checksum
  req_checksum=$(files_checksum requirements.txt pyproject.toml Pipfile)
  local need_install=1
  if [ -f "${checksum_file}" ]; then
    if [ "$(cat "${checksum_file}")" = "${req_checksum}" ]; then
      need_install=0
      log "Python dependencies unchanged; skipping reinstall."
    fi
  fi

  if [ $need_install -eq 1 ]; then
    log "Installing Python dependencies..."
    # Use a login shell for environment isolation
    su -s "${APP_SHELL}" - "${APP_USER}" -c "source '${VENV_DIR}/bin/activate' && python -m pip install --upgrade pip wheel setuptools"
    if [ -f requirements.txt ]; then
      su -s "${APP_SHELL}" - "${APP_USER}" -c "source '${VENV_DIR}/bin/activate' && pip install -r requirements.txt"
    elif [ -f pyproject.toml ]; then
      # Basic PEP 517 build support
      su -s "${APP_SHELL}" - "${APP_USER}" -c "source '${VENV_DIR}/bin/activate' && pip install -U build"
      su -s "${APP_SHELL}" - "${APP_USER}" -c "source '${VENV_DIR}/bin/activate' && python -m build || true"
      warn "pyproject.toml detected. If using Poetry/PDM, consider adding a lockfile and dedicated installer."
    elif [ -f Pipfile ]; then
      su -s "${APP_SHELL}" - "${APP_USER}" -c "source '${VENV_DIR}/bin/activate' && pip install pipenv && pipenv install --system --deploy || pipenv install --system"
    fi
    echo -n "${req_checksum}" > "${checksum_file}"
    chown "${APP_USER}:${APP_GROUP}" "${checksum_file}"
  fi

  # Default port for Python web frameworks
  if [ -z "${PORT}" ]; then PORT=5000; fi
}

# Install Node.js and dependencies
install_node() {
  log "Installing Node.js runtime..."
  case "$PKG_MGR" in
    apt)
      # Using distro nodejs/npm for stability
      pm_install nodejs npm
      ;;
    apk)
      pm_install nodejs npm
      ;;
    dnf)
      # Try module for newer versions if available
      dnf module -y enable nodejs:20 >/dev/null 2>&1 || true
      pm_install nodejs npm
      ;;
    yum)
      pm_install nodejs npm || true
      ;;
  esac
  log "Node.js installed: $(node -v 2>/dev/null || echo 'unknown')"
}

setup_node_env() {
  [ $IS_NODE -eq 1 ] || return 0
  install_node

  # Idempotent installation based on lockfiles
  local checksum_file="${SETUP_CACHE_DIR}/node_deps.sha256"
  local node_checksum
  if [ -f package-lock.json ]; then
    node_checksum=$(files_checksum package-lock.json)
  else
    node_checksum=$(files_checksum package.json)
  fi

  local need_install=1
  if [ -f "${checksum_file}" ] && [ "$(cat "${checksum_file}")" = "${node_checksum}" ]; then
    need_install=0
    log "Node dependencies unchanged; skipping reinstall."
  fi

  if [ $need_install -eq 1 ]; then
    log "Installing Node.js dependencies..."
    if [ -f package-lock.json ]; then
      su -s "${APP_SHELL}" - "${APP_USER}" -c "cd '${APP_HOME}' && npm ci --no-audit --no-fund $( [ "${APP_ENV}" = "production" ] && echo '--omit=dev' )"
    else
      su -s "${APP_SHELL}" - "${APP_USER}" -c "cd '${APP_HOME}' && npm install --no-audit --no-fund $( [ "${APP_ENV}" = "production" ] && echo '--omit=dev' )"
    fi
    echo -n "${node_checksum}" > "${checksum_file}"
    chown "${APP_USER}:${APP_GROUP}" "${checksum_file}"
  fi

  # Default port for Node apps
  if [ -z "${PORT}" ]; then PORT=3000; fi
}

# Install Java and build tools
install_java() {
  log "Installing OpenJDK..."
  case "$PKG_MGR" in
    apt) pm_install openjdk-17-jdk ;;
    apk) pm_install openjdk17-jdk ;;
    dnf) pm_install java-17-openjdk-devel ;;
    yum) pm_install java-17-openjdk-devel ;;
  esac
  log "Java installed: $(java -version 2>&1 | head -n1 || true)"
}

setup_java_env() {
  if [ $IS_JAVA_MAVEN -eq 1 ]; then
    install_java
    case "$PKG_MGR" in
      apt) pm_install maven ;;
      apk) pm_install maven ;;
      dnf) pm_install maven ;;
      yum) pm_install maven ;;
    esac
    # Idempotent: based on pom + locklike inputs
    local checksum_file="${SETUP_CACHE_DIR}/maven.sha256"
    local mvn_checksum
    mvn_checksum=$(files_checksum pom.xml)
    if [ ! -f "${checksum_file}" ] || [ "$(cat "${checksum_file}")" != "${mvn_checksum}" ]; then
      log "Downloading Maven dependencies..."
      su -s "${APP_SHELL}" - "${APP_USER}" -c "cd '${APP_HOME}' && mvn -B -q -DskipTests dependency:go-offline || true"
      echo -n "${mvn_checksum}" > "${checksum_file}"
      chown "${APP_USER}:${APP_GROUP}" "${checksum_file}"
    else
      log "Maven dependencies unchanged; skipping offline resolution."
    fi
    [ -z "${PORT}" ] && PORT=8080
  fi
  if [ $IS_JAVA_GRADLE -eq 1 ]; then
    install_java
    case "$PKG_MGR" in
      apt) pm_install gradle ;;
      apk) pm_install gradle ;;
      dnf) pm_install gradle ;;
      yum) pm_install gradle ;;
    esac
    [ -z "${PORT}" ] && PORT=8080
  fi
}

# Install Ruby and bundle
install_ruby() {
  log "Installing Ruby..."
  case "$PKG_MGR" in
    apt) pm_install ruby-full build-essential zlib1g-dev ;;
    apk) pm_install ruby ruby-dev build-base ;;
    dnf) pm_install ruby ruby-devel @development-tools ;;
    yum) pm_install ruby ruby-devel @'Development Tools' || true ;;
  esac
}

setup_ruby_env() {
  [ $IS_RUBY -eq 1 ] || return 0
  install_ruby
  if [ -f Gemfile ]; then
    # Install bundler and gems idempotently based on Gemfile.lock
    local checksum_file="${SETUP_CACHE_DIR}/bundle.sha256"
    local gem_checksum
    if [ -f Gemfile.lock ]; then
      gem_checksum=$(files_checksum Gemfile.lock)
    else
      gem_checksum=$(files_checksum Gemfile)
    fi
    if [ ! -f "${checksum_file}" ] || [ "$(cat "${checksum_file}")" != "${gem_checksum}" ]; then
      log "Installing Ruby gems..."
      su -s "${APP_SHELL}" - "${APP_USER}" -c "cd '${APP_HOME}' && gem install bundler --no-document && bundle config set path 'vendor/bundle' && bundle install --jobs=4"
      echo -n "${gem_checksum}" > "${checksum_file}"
      chown "${APP_USER}:${APP_GROUP}" "${checksum_file}"
    else
      log "Ruby gems unchanged; skipping reinstall."
    fi
  fi
  [ -z "${PORT}" ] && PORT=3000
}

# Install PHP and Composer
install_php() {
  log "Installing PHP and Composer..."
  case "$PKG_MGR" in
    apt)
      pm_install php-cli php-mbstring php-xml php-curl php-zip unzip
      # Install composer
      if ! command -v composer >/dev/null 2>&1; then
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
      fi
      ;;
    apk)
      pm_install php81 php81-phar php81-openssl php81-mbstring php81-tokenizer php81-xml php81-curl php81-zip php81-json php81-dom composer
      ln -sf /usr/bin/php81 /usr/bin/php || true
      ;;
    dnf|yum)
      pm_install php-cli php-json php-mbstring php-xml php-curl php-zip unzip
      if ! command -v composer >/dev/null 2>&1; then
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
      fi
      ;;
  esac
}

setup_php_env() {
  [ $IS_PHP -eq 1 ] || return 0
  install_php
  if [ -f composer.json ]; then
    local checksum_file="${SETUP_CACHE_DIR}/composer.sha256"
    local comp_checksum
    if [ -f composer.lock ]; then
      comp_checksum=$(files_checksum composer.lock)
    else
      comp_checksum=$(files_checksum composer.json)
    fi
    if [ ! -f "${checksum_file}" ] || [ "$(cat "${checksum_file}")" != "${comp_checksum}" ]; then
      log "Installing Composer dependencies..."
      su -s "${APP_SHELL}" - "${APP_USER}" -c "cd '${APP_HOME}' && composer install --no-interaction --no-progress $( [ "${APP_ENV}" = "production" ] && echo '--no-dev' )"
      echo -n "${comp_checksum}" > "${checksum_file}"
      chown "${APP_USER}:${APP_GROUP}" "${checksum_file}"
    else
      log "Composer dependencies unchanged; skipping reinstall."
    fi
  fi
  [ -z "${PORT}" ] && PORT=8000
}

# Install Go
install_go() {
  log "Installing Go..."
  case "$PKG_MGR" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    dnf|yum) pm_install golang ;;
  esac
}

setup_go_env() {
  [ $IS_GO -eq 1 ] || return 0
  install_go
  # Idempotent module download
  local checksum_file="${SETUP_CACHE_DIR}/go.sum.sha256"
  local gomod_checksum
  gomod_checksum=$(files_checksum go.mod go.sum)
  if [ ! -f "${checksum_file}" ] || [ "$(cat "${checksum_file}")" != "${gomod_checksum}" ]; then
    log "Downloading Go modules..."
    su -s "${APP_SHELL}" - "${APP_USER}" -c "cd '${APP_HOME}' && go mod download"
    echo -n "${gomod_checksum}" > "${checksum_file}"
    chown "${APP_USER}:${APP_GROUP}" "${checksum_file}"
  else
    log "Go modules unchanged; skipping download."
  fi
  [ -z "${PORT}" ] && PORT=8080
}

# Install Rust
install_rust() {
  log "Installing Rust toolchain..."
  case "$PKG_MGR" in
    apk)
      pm_install rust cargo
      ;;
    apt|dnf|yum)
      # Install via rustup for latest stable
      if [ ! -f /usr/local/bin/rustup ] && [ ! -f /root/.cargo/bin/rustup ]; then
        curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
        sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain stable >/dev/null 2>&1 || true
        ln -sf /root/.cargo/bin/rustup /usr/local/bin/rustup || true
        ln -sf /root/.cargo/bin/rustc /usr/local/bin/rustc || true
        ln -sf /root/.cargo/bin/cargo /usr/local/bin/cargo || true
      fi
      ;;
  esac
}

setup_rust_env() {
  [ $IS_RUST -eq 1 ] || return 0
  install_rust
  # Cargo dependencies idempotence
  local checksum_file="${SETUP_CACHE_DIR}/cargo.sha256"
  local cargo_checksum
  cargo_checksum=$(files_checksum Cargo.toml Cargo.lock)
  if [ ! -f "${checksum_file}" ] || [ "$(cat "${checksum_file}")" != "${cargo_checksum}" ]; then
    log "Fetching Rust crates..."
    su -s "${APP_SHELL}" - "${APP_USER}" -c "cd '${APP_HOME}' && cargo fetch || true"
    echo -n "${cargo_checksum}" > "${checksum_file}"
    chown "${APP_USER}:${APP_GROUP}" "${checksum_file}"
  else
    log "Rust crates unchanged; skipping fetch."
  fi
  [ -z "${PORT}" ] && PORT=8080
}

# .NET SDK (best-effort)
setup_dotnet_env() {
  [ $IS_DOTNET -eq 1 ] || return 0
  log "Detected .NET project. Attempting to install .NET SDK (best-effort)..."
  case "$PKG_MGR" in
    apt)
      pm_install wget apt-transport-https
      wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
      dpkg -i /tmp/packages-microsoft-prod.deb || true
      pm_update || true
      pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || true
      ;;
    dnf|yum)
      rpm -Uvh https://packages.microsoft.com/config/centos/8/packages-microsoft-prod.rpm || true
      pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || true
      ;;
    apk)
      warn ".NET installation on Alpine is not officially supported in this script. Please use a dotnet base image."
      ;;
  esac
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK installed: $(dotnet --version)"
    su -s "${APP_SHELL}" - "${APP_USER}" -c "cd '${APP_HOME}' && dotnet restore || true"
  else
    warn ".NET SDK could not be installed automatically. Consider using a Microsoft .NET base image."
  fi
  [ -z "${PORT}" ] && PORT=8080
}

# Configure environment variables and PATH for app user
configure_environment() {
  log "Configuring environment variables..."
  local env_file="${APP_HOME}/.env.docker"
  {
    echo "export APP_HOME='${APP_HOME}'"
    echo "export APP_ENV='${APP_ENV}'"
    echo "export PORT='${PORT:-8080}'"
    echo "export PATH=\"${APP_HOME}/bin:\$PATH\""
    if [ -d "${APP_HOME}/.venv/bin" ]; then
      echo "export VIRTUAL_ENV='${APP_HOME}/.venv'"
      echo "export PATH=\"${APP_HOME}/.venv/bin:\$PATH\""
    fi
    if [ -d "${APP_HOME}/node_modules/.bin" ]; then
      echo "export PATH=\"${APP_HOME}/node_modules/.bin:\$PATH\""
    fi
    # Go and Cargo default bin paths
    echo "export GOPATH=\${GOPATH:-${APP_HOME}/.go}"
    echo "export PATH=\"\${GOPATH}/bin:\$PATH\""
    echo "export CARGO_HOME=\${CARGO_HOME:-${APP_HOME}/.cargo}"
    echo "export PATH=\"\${CARGO_HOME}/bin:\$PATH\""
  } > "${env_file}"
  chown "${APP_USER}:${APP_GROUP}" "${env_file}"
  chmod 0640 "${env_file}"

  # Profile script for shell sessions
  local profile_script="/etc/profile.d/app_env.sh"
  {
    echo "# Autogenerated by setup script"
    echo "[ -f '${env_file}' ] && . '${env_file}'"
    echo "cd '${APP_HOME}' 2>/dev/null || true"
  } > "${profile_script}"
  chmod 0644 "${profile_script}"

  log "Environment configuration written to ${env_file} and ${profile_script}"
}

# Final helpful info
print_summary() {
  info "Setup complete."
  echo "Summary:"
  echo "- APP_HOME: ${APP_HOME}"
  echo "- APP_USER: ${APP_USER} (${APP_UID})"
  echo "- APP_ENV:  ${APP_ENV}"
  echo "- PORT:     ${PORT:-8080}"
  echo "- Detected types: $( [ $IS_PY -eq 1 ] && echo -n 'Python ' )$( [ $IS_NODE -eq 1 ] && echo -n 'Node.js ' )$( [ $IS_JAVA_MAVEN -eq 1 ] && echo -n 'Java-Maven ' )$( [ $IS_JAVA_GRADLE -eq 1 ] && echo -n 'Java-Gradle ' )$( [ $IS_RUBY -eq 1 ] && echo -n 'Ruby ' )$( [ $IS_PHP -eq 1 ] && echo -n 'PHP ' )$( [ $IS_GO -eq 1 ] && echo -n 'Go ' )$( [ $IS_RUST -eq 1 ] && echo -n 'Rust ' )$( [ $IS_DOTNET -eq 1 ] && echo -n '.NET ' )"
  echo
  echo "To use the environment inside the container:"
  echo "- Start a shell as ${APP_USER} and source env: su - ${APP_USER} -c 'source ${APP_HOME}/.env.docker && \$SHELL'"
  echo "- Or rely on /etc/profile.d/app_env.sh which auto-loads on interactive shells."
  echo
}

main() {
  require_root
  detect_pkg_mgr
  install_base_tools
  ensure_bash
  # Ensure working directory exists; do not overwrite existing project files
  mkdir -p "${APP_HOME}"
  ensure_app_user
  setup_directories

  # Move into APP_HOME if script run elsewhere (common in Docker)
  cd "${APP_HOME}" || true

  detect_project_types

  # Install per-stack system libraries often required for builds
  case "$PKG_MGR" in
    apt)
      # Common native deps for Python/Ruby/Node packages
      pm_install libssl-dev libffi-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libxml2-dev libxslt1-dev
      ;;
    apk)
      pm_install openssl-dev libffi-dev zlib-dev bzip2-dev readline-dev sqlite-dev libxml2-dev libxslt-dev
      ;;
    dnf|yum)
      pm_install openssl-devel libffi-devel zlib-devel bzip2-devel readline-devel sqlite-devel libxml2-devel libxslt-devel
      ;;
  esac || true

  # Per-language setup
  setup_python_env
  setup_node_env
  setup_java_env
  setup_ruby_env
  setup_php_env
  setup_go_env
  setup_rust_env
  setup_dotnet_env

  # Sensible default port if still unset
  if [ -z "${PORT}" ]; then PORT=8080; fi

  configure_environment
  print_summary
  log "Environment setup completed successfully."
}

main "$@"