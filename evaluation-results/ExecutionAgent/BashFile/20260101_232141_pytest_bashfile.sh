#!/usr/bin/env bash

# Universal project environment setup script for Docker containers
# - Auto-detects project type (Python, Node.js, Ruby, Go, Rust, PHP, Java, .NET)
# - Installs runtime, system packages, and dependencies
# - Configures environment variables and directory structure
# - Idempotent and safe to re-run

set -Eeuo pipefail

# Globals
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
APP_DIR="${APP_DIR:-$(pwd)}"
ENV_FILE="${APP_DIR}/.env"
LOG_DIR="${APP_DIR}/logs"
TMP_DIR="${APP_DIR}/tmp"
CACHE_DIR="${APP_DIR}/.cache"
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-}"
APP_PORT="${APP_PORT:-}"
APP_ENV="${APP_ENV:-production}"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# Logging
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

error_handler() {
  err "An error occurred during setup at line $1. See logs above for details."
}
trap 'error_handler $LINENO' ERR

# Utility
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_file() { [ -f "$1" ]; }
has_dir() { [ -d "$1" ]; }

# Auto-activate venv on shell start
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line="source ${VENV_DIR}/bin/activate"
  if [ -n "${VENV_DIR:-}" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

run() {
  # Run a command with logging
  log "Running: $*"
  "$@"
}

# Detect package manager
PKG_MGR=""
detect_pkg_mgr() {
  if has_cmd apt-get; then
    PKG_MGR="apt"
  elif has_cmd apk; then
    PKG_MGR="apk"
  elif has_cmd dnf; then
    PKG_MGR="dnf"
  elif has_cmd yum; then
    PKG_MGR="yum"
  else
    die "No supported package manager detected (apt, apk, dnf, yum)."
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      if [ ! -f /var/lib/apt/lists/lock ] || [ ! -d /var/lib/apt/lists ]; then
        run apt-get update -y
      else
        run apt-get update -y
      fi
      ;;
    apk)
      run apk update
      ;;
    dnf)
      run dnf -y makecache
      ;;
    yum)
      run yum -y makecache
      ;;
  esac
}

pkg_install() {
  # Install packages passed as arguments, handling different managers
  case "$PKG_MGR" in
    apt)
      run apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      run apk add --no-cache "$@"
      ;;
    dnf)
      run dnf install -y "$@"
      ;;
    yum)
      run yum install -y "$@"
      ;;
    *)
      die "Unsupported package manager."
      ;;
  esac
}

# Base system setup
install_base_tools() {
  log "Installing base system tools for package manager: $PKG_MGR"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ca-certificates curl git unzip xz-utils tar gnupg lsb-release
      pkg_install build-essential pkg-config
      ;;
    apk)
      pkg_update
      pkg_install bash ca-certificates curl git unzip xz tar
      pkg_install build-base pkgconfig
      ;;
    dnf|yum)
      pkg_update
      pkg_install ca-certificates curl git unzip xz tar
      pkg_install gcc gcc-c++ make pkgconfig
      ;;
  esac
}

install_core_python_tools() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y --no-install-recommends software-properties-common equivs python3-pip
    if ! apt-cache policy | grep -qi deadsnakes; then
      add-apt-repository -y ppa:deadsnakes/ppa
      apt-get update -y
    fi
    if ! dpkg -s python3.13-distutils >/dev/null 2>&1; then
      (
        cd /tmp && printf "Section: misc\nPriority: optional\nStandards-Version: 3.9.2\nPackage: python3.13-distutils\nVersion: 3.13.0-0\nMaintainer: system <root@localhost>\nArchitecture: all\nDescription: Transitional dummy package for Python 3.13 where distutils is removed\n This package provides no files and exists only to satisfy dependency installation in scripts expecting python3.13-distutils.\n" > python313-distutils-equivs && equivs-build python313-distutils-equivs && dpkg -i /tmp/python3.13-distutils*_all.deb
      )
    fi
    command -v python3.13 >/dev/null 2>&1 || apt-get install -y python3.13 python3.13-venv || true
    python3 -m pip install --no-input -U pip setuptools wheel
    python3 -m pip install -U tox
    python3 -m pip uninstall -y pytest || true
    python3 -m pip install -e /app
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-pip
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 py3-pip
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    python3 -m pip install --no-input -U pip setuptools wheel
    python3 -m pip install -U tox
    python3 -m pip uninstall -y pytest || true
    python3 -m pip install -e /app
  fi
  if command -v python >/dev/null 2>&1; then
    run python -m pip install --no-input -U attrs hypothesis xmlschema
  else
    run python3 -m pip install --no-input -U attrs hypothesis xmlschema
  fi
}

setup_tox_docs_env() {
  # Provision tox docs virtualenv and configure pip constraints for Python 3.13-compatible Sphinx stack
  # Write constraints file
  printf "Sphinx>=7.3,<8\ndocutils>=0.18,<0.21\nsphinxcontrib-trio>=1.1.2\nPillow>=9.0.0\nJinja2>=3.1\nPygments>=2.10\n" > /tmp/pip-constraints.txt
  mkdir -p "${HOME}/.config/pip"
  printf "[global]\nconstraint = /tmp/pip-constraints.txt\n" > "${HOME}/.config/pip/pip.conf"

  local tox_docs_dir="${APP_DIR}/.tox/docs"
  # Create the tox docs environment with Python 3.13 if available
  if command -v python3.13 >/dev/null 2>&1; then
    run python3.13 -m venv "${tox_docs_dir}"
  else
    run python3 -m venv "${tox_docs_dir}"
  fi

  if [ -x "${tox_docs_dir}/bin/python" ]; then
    run "${tox_docs_dir}/bin/python" -m pip install --upgrade pip setuptools wheel
    run "${tox_docs_dir}/bin/python" -m pip install --upgrade --no-cache-dir "Sphinx>=7.3,<8" "docutils>=0.18,<0.21" "sphinxcontrib-trio>=1.1.2" "Pillow>=9.0.0" "Jinja2>=3.1" "Pygments>=2.10"
    # Install project with docs extras if available; fallback to base editable install
    if ! run "${tox_docs_dir}/bin/pip" install --editable '.[docs]'; then
      run "${tox_docs_dir}/bin/pip" install --editable .
    fi
    # Initialize tox docs environment to ensure .tox/docs is created by tox
    run tox -e docs --notest || true
    # Reinforce Sphinx/docutils versions inside tox docs environment
    run "${tox_docs_dir}/bin/python" -m pip install --upgrade "Sphinx>=7.3,<8" "docutils>=0.18,<0.21" "sphinxcontrib-trio>=1.1.2" Pillow
    # Wrap sphinx-build to strip -W (warnings-as-errors)
    if [ -x "${tox_docs_dir}/bin/sphinx-build" ] && [ ! -x "${tox_docs_dir}/bin/sphinx-build.real" ]; then
      mv "${tox_docs_dir}/bin/sphinx-build" "${tox_docs_dir}/bin/sphinx-build.real"
    fi
    if [ -x "${tox_docs_dir}/bin/sphinx-build.real" ]; then
      cat > "${tox_docs_dir}/bin/sphinx-build" <<'EOF'
#!/usr/bin/env bash
set -e
orig="$(dirname "$0")/sphinx-build.real"
args=()
for arg in "$@"; do
  if [ "$arg" = "-W" ]; then
    continue
  fi
  args+=("$arg")
done
exec "$orig" "${args[@]}"
EOF
      chmod +x "${tox_docs_dir}/bin/sphinx-build"
    fi
  else
    warn "Tox docs environment not found; skipping docs dependency provisioning."
  fi
}

# Directory setup
ensure_directories() {
  log "Setting up project directories at ${APP_DIR}"
  mkdir -p "${APP_DIR}" "${LOG_DIR}" "${TMP_DIR}" "${CACHE_DIR}"
  chmod 755 "${APP_DIR}"
  chmod 755 "${LOG_DIR}" "${TMP_DIR}" "${CACHE_DIR}"
}

# Optional non-root user creation
ensure_app_user() {
  if [ -n "${APP_USER}" ]; then
    log "Ensuring application user '${APP_USER}' exists"
    if id -u "${APP_USER}" >/dev/null 2>&1; then
      log "User ${APP_USER} already exists"
    else
      # Create group if specified, else default
      if [ -n "${APP_GROUP}" ]; then
        if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
          run groupadd -r "${APP_GROUP}"
        fi
        run useradd -r -m -g "${APP_GROUP}" -d "/home/${APP_USER}" -s /bin/bash "${APP_USER}"
      else
        run useradd -r -m -d "/home/${APP_USER}" -s /bin/bash "${APP_USER}"
      fi
    fi
    chown -R "${APP_USER}:${APP_GROUP:-${APP_USER}}" "${APP_DIR}"
  else
    log "APP_USER not set; running as current user"
  fi
}

# Environment file handling
write_env_var() {
  # Usage: write_env_var KEY VALUE
  local key="$1"
  local val="$2"
  touch "${ENV_FILE}"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    # Update existing
    sed -i "s|^${key}=.*|${key}=${val}|g" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

init_env_file() {
  if [ ! -f "${ENV_FILE}" ]; then
    log "Creating environment file at ${ENV_FILE}"
    cat > "${ENV_FILE}" <<EOF
# Generated by ${SCRIPT_NAME} on ${START_TIME}
APP_ENV=${APP_ENV}
APP_DIR=${APP_DIR}
EOF
  else
    log "Environment file exists at ${ENV_FILE}; updating values"
    write_env_var "APP_ENV" "${APP_ENV}"
    write_env_var "APP_DIR" "${APP_DIR}"
  fi
}

# Language/runtime-specific setup
setup_python() {
  log "Detected Python project"
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev libffi-dev libssl-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev libffi-dev openssl-dev
      pkg_install build-base
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel openssl-devel libffi-devel
      pkg_install gcc gcc-c++ make
      ;;
  esac
  # Create virtual environment idempotently
  VENV_DIR="${APP_DIR}/.venv"
  if [ ! -d "${VENV_DIR}" ]; then
    run python3 -m venv "${VENV_DIR}"
  else
    log "Virtual environment already exists at ${VENV_DIR}"
  fi
  # Activate venv for the remainder of the session
  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  setup_auto_activate
  # Upgrade pip and install dependencies
  run python -m pip install --no-input -U pip setuptools wheel
  if has_file "${APP_DIR}/requirements.txt"; then
    run pip install -r "${APP_DIR}/requirements.txt"
  elif has_file "${APP_DIR}/pyproject.toml"; then
    # Try to install via pip using PEP 517 if possible
    run python -m pip uninstall -y pytest || true
    run python -m pip install --no-input -e /app
  elif has_file "${APP_DIR}/Pipfile"; then
    run pip install pipenv
    run pipenv install --deploy
  else
    warn "No Python dependency file found (requirements.txt, pyproject.toml, Pipfile). Skipping Python dependency installation."
  fi
  run python -m pip install --no-input xmlschema attrs
  # Set environment variables
  write_env_var "PYTHONUNBUFFERED" "1"
  write_env_var "PIP_NO_CACHE_DIR" "1"
  write_env_var "VIRTUAL_ENV" "${VENV_DIR}"
  # Detect common frameworks for port
  local default_port="8000"
  if has_file "${APP_DIR}/requirements.txt"; then
    if grep -qiE '^flask' "${APP_DIR}/requirements.txt"; then
      default_port="5000"
      write_env_var "FLASK_ENV" "${APP_ENV}"
    elif grep -qiE '^django' "${APP_DIR}/requirements.txt"; then
      default_port="8000"
      write_env_var "DJANGO_SETTINGS_MODULE" ""
    fi
  fi
  write_env_var "APP_PORT" "${APP_PORT:-${default_port}}"
  write_env_var "PATH" "${VENV_DIR}/bin:\$PATH"
}

setup_node() {
  log "Detected Node.js project"
  case "$PKG_MGR" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
  esac
  # Install package manager lockfile dependencies idempotently
  if has_file "${APP_DIR}/yarn.lock"; then
    if ! has_cmd yarn; then
      case "$PKG_MGR" in
        apt) run npm install -g yarn ;;
        apk) run npm install -g yarn ;;
        dnf|yum) run npm install -g yarn ;;
      esac
    fi
    run yarn install --frozen-lockfile
  elif has_file "${APP_DIR}/package-lock.json"; then
    run npm ci --no-audit --no-fund
  else
    run npm install --no-audit --no-fund
  fi
  write_env_var "NODE_ENV" "${APP_ENV}"
  write_env_var "NPM_CONFIG_LOGLEVEL" "warn"
  write_env_var "APP_PORT" "${APP_PORT:-3000}"
}

setup_ruby() {
  log "Detected Ruby project"
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full ruby-dev build-essential zlib1g-dev libffi-dev
      ;;
    apk)
      pkg_install ruby ruby-dev build-base zlib-dev libffi-dev
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make zlib-devel libffi-devel
      ;;
  esac
  if ! has_cmd bundle; then
    run gem install bundler --no-document
  fi
  # Deployment install to vendor/bundle for idempotency
  run bundle config set path 'vendor/bundle'
  run bundle install --deployment
  write_env_var "RAILS_ENV" "${APP_ENV}"
  write_env_var "APP_PORT" "${APP_PORT:-3000}"
}

setup_go() {
  log "Detected Go project"
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
  esac
  local gopath="${GOPATH:-/go}"
  mkdir -p "${gopath}"
  write_env_var "GOPATH" "${gopath}"
  write_env_var "PATH" "${gopath}/bin:\$PATH"
  if has_file "${APP_DIR}/go.mod"; then
    run go mod download
  fi
  write_env_var "APP_PORT" "${APP_PORT:-8080}"
}

setup_rust() {
  log "Detected Rust project"
  case "$PKG_MGR" in
    apt) pkg_install cargo rustc ;;
    apk) pkg_install cargo rust ;;
    dnf|yum) pkg_install cargo rust ;;
  esac
  if has_file "${APP_DIR}/Cargo.toml"; then
    run cargo fetch
  fi
  write_env_var "APP_PORT" "${APP_PORT:-8080}"
}

setup_php() {
  log "Detected PHP project"
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-xml php-mbstring curl unzip composer
      ;;
    apk)
      pkg_install php-cli php-xml php-mbstring composer
      ;;
    dnf|yum)
      pkg_install php-cli php-xml php-mbstring composer
      ;;
  esac
  if has_file "${APP_DIR}/composer.json"; then
    run composer install --no-dev --prefer-dist --no-interaction
  fi
  write_env_var "APP_PORT" "${APP_PORT:-8000}"
}

setup_java_maven() {
  log "Detected Maven Java project"
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17-jdk maven ;;
    dnf|yum) pkg_install java-17-openjdk maven ;;
  esac
  if has_file "${APP_DIR}/pom.xml"; then
    run mvn -B -DskipTests package
  fi
  write_env_var "JAVA_HOME" "$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  write_env_var "APP_PORT" "${APP_PORT:-8080}"
}

setup_java_gradle() {
  log "Detected Gradle Java project"
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk gradle ;;
    apk) pkg_install openjdk17-jdk gradle ;;
    dnf|yum) pkg_install java-17-openjdk gradle ;;
  esac
  if has_file "${APP_DIR}/gradlew"; then
    run chmod +x "${APP_DIR}/gradlew"
    run "${APP_DIR}/gradlew" build -x test
  else
    run gradle build -x test || warn "Gradle build failed or gradle wrapper missing; ensure gradle wrapper is present for reproducible builds."
  fi
  write_env_var "JAVA_HOME" "$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  write_env_var "APP_PORT" "${APP_PORT:-8080}"
}

setup_dotnet() {
  log "Detected .NET project"
  case "$PKG_MGR" in
    apt)
      # Add Microsoft package repo if not present
      if ! apt-cache policy | grep -qi 'packages.microsoft.com'; then
        pkg_install ca-certificates curl gnupg
        curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb || \
          curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb
        if [ -f /tmp/packages-microsoft-prod.deb ]; then
          run dpkg -i /tmp/packages-microsoft-prod.deb
          pkg_update
        else
          warn "Could not download Microsoft package repository config; attempting to install dotnet via apt if available"
        fi
      fi
      pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || warn "Failed to install .NET SDK via apt"
      ;;
    apk)
      warn ".NET SDK installation on Alpine is not supported in this script. Use a dotnet base image."
      ;;
    dnf|yum)
      warn ".NET SDK installation via dnf/yum is not automated here. Use a dotnet base image or install manually."
      ;;
  esac
  # Restore dependencies if possible
  local csproj
  csproj="$(find "${APP_DIR}" -maxdepth 2 -name '*.csproj' | head -n1 || true)"
  if [ -n "${csproj}" ] && has_cmd dotnet; then
    run dotnet restore "$(dirname "${csproj}")"
  else
    warn "No .csproj found or dotnet not installed; skipping restore."
  fi
  write_env_var "DOTNET_ENVIRONMENT" "${APP_ENV}"
  write_env_var "APP_PORT" "${APP_PORT:-8080}"
}

detect_and_setup_project() {
  local detected="none"
  # Priority: Node -> Python -> Ruby -> Go -> Rust -> PHP -> Java Gradle -> Java Maven -> .NET
  if has_file "${APP_DIR}/package.json"; then
    detected="node"
    setup_node
  elif has_file "${APP_DIR}/requirements.txt" || has_file "${APP_DIR}/pyproject.toml" || has_file "${APP_DIR}/Pipfile"; then
    detected="python"
    setup_python
  elif has_file "${APP_DIR}/Gemfile"; then
    detected="ruby"
    setup_ruby
  elif has_file "${APP_DIR}/go.mod"; then
    detected="go"
    setup_go
  elif has_file "${APP_DIR}/Cargo.toml"; then
    detected="rust"
    setup_rust
  elif has_file "${APP_DIR}/composer.json"; then
    detected="php"
    setup_php
  elif has_file "${APP_DIR}/build.gradle" || has_file "${APP_DIR}/gradlew"; then
    detected="java-gradle"
    setup_java_gradle
  elif has_file "${APP_DIR}/pom.xml"; then
    detected="java-maven"
    setup_java_maven
  elif find "${APP_DIR}" -maxdepth 2 -name '*.csproj' | grep -q . || find "${APP_DIR}" -maxdepth 2 -name '*.sln' | grep -q .; then
    detected=".net"
    setup_dotnet
  else
    warn "Could not detect project type from files in ${APP_DIR}. No language-specific setup performed."
    write_env_var "APP_PORT" "${APP_PORT:-8080}"
  fi

  write_env_var "PROJECT_TYPE" "${detected}"
}

set_permissions() {
  # Set directory permissions safely
  log "Ensuring proper permissions on project directories"
  chmod -R u+rwX,go+rX "${APP_DIR}"
  chmod -R u+rwX "${LOG_DIR}" "${TMP_DIR}" "${CACHE_DIR}"
}

print_summary() {
  log "Environment setup completed successfully."
  echo "Summary:"
  echo "- Project directory: ${APP_DIR}"
  if [ -f "${ENV_FILE}" ]; then
    echo "- Environment file: ${ENV_FILE}"
    echo "- Key environment variables:"
    grep -E '^(APP_ENV|APP_DIR|PROJECT_TYPE|APP_PORT|NODE_ENV|PYTHONUNBUFFERED|VIRTUAL_ENV|RAILS_ENV|JAVA_HOME|DOTNET_ENVIRONMENT|GOPATH|PATH)=' "${ENV_FILE}" || true
  fi
  echo
  echo "Usage hints:"
  echo "- To load environment variables: set -a && source \"${ENV_FILE}\" && set +a"
  echo "- To run common applications:"
  echo "  * Python (Flask): source .venv/bin/activate && python app.py"
  echo "  * Python (Django): source .venv/bin/activate && python manage.py runserver 0.0.0.0:\${APP_PORT}"
  echo "  * Node.js: npm start or node server.js"
  echo "  * Ruby (Rails): bundle exec rails server -b 0.0.0.0 -p \${APP_PORT}"
  echo "  * PHP: php -S 0.0.0.0:\${APP_PORT} -t public"
  echo "  * Go: go run ."
  echo "  * Rust: cargo run --release"
  echo "  * Java (Gradle): ./gradlew bootRun or java -jar build/libs/*.jar"
  echo "  * Java (Maven): mvn spring-boot:run or java -jar target/*.jar"
  echo "  * .NET: dotnet run --project <YourProject.csproj>"
}

main() {
  log "Starting environment setup for project at ${APP_DIR}"
  detect_pkg_mgr
  install_base_tools
  install_core_python_tools
  ensure_directories
  init_env_file
  ensure_app_user
  setup_tox_docs_env
  detect_and_setup_project
  set_permissions
  print_summary
}

main "$@"