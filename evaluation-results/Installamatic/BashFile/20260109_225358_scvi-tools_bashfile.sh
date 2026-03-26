#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Auto-detects common project types (Node.js, Python, Ruby, PHP, Go, Rust, Java, .NET)
# - Installs system packages and language runtimes using available package manager
# - Installs project dependencies
# - Configures environment variables and directory structure
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$' \n\t'

# -----------------------------
# Global config and logging
# -----------------------------
SCRIPT_NAME="$(basename "${0}")"
START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_ENV="${APP_ENV:-production}"
DEFAULT_PORT="${PORT:-8080}"
CHOWN_FILES="${CHOWN_FILES:-true}"
CREATE_APP_USER="${CREATE_APP_USER:-true}"
ENV_FILE="${ENV_FILE:-.env}"
PROFILE_FILE="/etc/profile.d/project_env.sh"

# Logging
log()  { printf '[%s] [INFO] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Error handler
on_error() {
  local exit_code=$?
  local line_no=$1
  err "Script failed at line ${line_no} with exit code ${exit_code}"
  exit "${exit_code}"
}
trap 'on_error $LINENO' ERR

have_command() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------
# Package manager detection
# -----------------------------
PKG_MGR=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
PM_FAMILY=""

detect_pkg_mgr() {
  if have_command apt-get; then
    PKG_MGR="apt-get"; PM_FAMILY="debian"
    PKG_UPDATE='apt-get update -y'
    PKG_INSTALL='apt-get install -y --no-install-recommends'
    PKG_CLEAN='rm -rf /var/lib/apt/lists/*'
    export DEBIAN_FRONTEND=noninteractive
  elif have_command apk; then
    PKG_MGR="apk"; PM_FAMILY="alpine"
    PKG_UPDATE='true'
    PKG_INSTALL='apk add --no-cache'
    PKG_CLEAN='true'
  elif have_command dnf; then
    PKG_MGR="dnf"; PM_FAMILY="rhel"
    PKG_UPDATE='dnf -y makecache'
    PKG_INSTALL='dnf -y install'
    PKG_CLEAN='dnf -y clean all'
  elif have_command microdnf; then
    PKG_MGR="microdnf"; PM_FAMILY="rhel"
    PKG_UPDATE='microdnf update -y || true'
    PKG_INSTALL='microdnf install -y'
    PKG_CLEAN='microdnf clean all'
  elif have_command yum; then
    PKG_MGR="yum"; PM_FAMILY="rhel"
    PKG_UPDATE='yum -y makecache'
    PKG_INSTALL='yum -y install'
    PKG_CLEAN='yum -y clean all'
  else
    err "No supported package manager found (apt-get, apk, dnf, microdnf, yum)."
    exit 1
  fi
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local pkgs=("$@")
  if [ "${#pkgs[@]}" -eq 0 ]; then
    return 0
  fi
  log "Installing packages with ${PKG_MGR}: ${pkgs[*]}"
  eval "${PKG_UPDATE}"
  # shellcheck disable=SC2086
  eval "${PKG_INSTALL} ${pkgs[*]}"
  eval "${PKG_CLEAN}"
}

# -----------------------------
# System packages per distro
# -----------------------------
install_base_system_packages() {
  case "${PM_FAMILY}" in
    debian)
      pkg_install ca-certificates curl git unzip tar xz-utils gnupg pkg-config \
        locales \
        gcc g++ make build-essential
      ;;
    alpine)
      pkg_install ca-certificates curl git unzip tar xz \
        build-base bash coreutils findutils grep sed gawk \
        openssl \
        shadow
      ;;
    rhel)
      pkg_install ca-certificates curl git unzip tar xz gnupg2 \
        gcc gcc-c++ make autoconf automake libtool \
        shadow-utils
      ;;
    *)
      warn "Unknown PM_FAMILY: ${PM_FAMILY}"
      ;;
  esac
}

# -----------------------------
# User and permissions
# -----------------------------
ensure_app_user() {
  if [ "${CREATE_APP_USER}" != "true" ]; then
    log "Skipping app user creation (CREATE_APP_USER=${CREATE_APP_USER})"
    return 0
  fi

  # Some minimal images may not include user management; we tried to install shadow above
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    log "User ${APP_USER} already exists."
    return 0
  fi

  case "${PM_FAMILY}" in
    alpine)
      if ! have_command adduser; then
        pkg_install shadow
      fi
      log "Creating user ${APP_USER} on Alpine..."
      addgroup -g 1000 -S "${APP_GROUP}" 2>/dev/null || true
      adduser -S -D -h "${PROJECT_DIR}" -G "${APP_GROUP}" -u 1000 "${APP_USER}" || adduser -S -D "${APP_USER}"
      ;;
    debian|rhel)
      if ! have_command useradd; then
        pkg_install shadow-utils || true
      fi
      log "Creating user ${APP_USER}..."
      groupadd -g 1000 "${APP_GROUP}" 2>/dev/null || true
      useradd -m -d "${PROJECT_DIR}" -s /bin/bash -u 1000 -g "${APP_GROUP}" "${APP_USER}" 2>/dev/null || true
      ;;
    *)
      warn "User management not configured for ${PM_FAMILY}"
      ;;
  esac
}

set_permissions() {
  if [ "${CHOWN_FILES}" = "true" ] && id -u "${APP_USER}" >/dev/null 2>&1; then
    log "Setting ownership of ${PROJECT_DIR} to ${APP_USER}:${APP_GROUP}"
    chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_DIR}" || warn "Failed to chown ${PROJECT_DIR}"
  else
    log "Skipping chown (CHOWN_FILES=${CHOWN_FILES} or user missing)"
  fi
}

# -----------------------------
# Project structure
# -----------------------------
prepare_project_structure() {
  mkdir -p "${PROJECT_DIR}"
  mkdir -p "${PROJECT_DIR}/logs" "${PROJECT_DIR}/tmp" "${PROJECT_DIR}/.cache"
  touch "${PROJECT_DIR}/.setup.marker" 2>/dev/null || true
}

# -----------------------------
# Environment configuration
# -----------------------------
write_env_files() {
  # .env in project
  if [ ! -f "${PROJECT_DIR}/${ENV_FILE}" ]; then
    log "Creating ${ENV_FILE} with default values"
    cat > "${PROJECT_DIR}/${ENV_FILE}" <<EOF
APP_ENV=${APP_ENV}
PORT=${DEFAULT_PORT}
# Add your application specific env vars below
# DATABASE_URL=
# REDIS_URL=
EOF
  else
    log "${ENV_FILE} already exists; leaving it as-is."
  fi

  # Profile script for shells in container
  mkdir -p "$(dirname "${PROFILE_FILE}")"
  cat > "${PROFILE_FILE}" <<'EOF'
# Project environment defaults
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export APP_ENV="${APP_ENV:-production}"
export PORT="${PORT:-8080}"
# Prefer project-local tools
if [ -d "/workspace/.dotnet" ]; then
  export DOTNET_ROOT="/workspace/.dotnet"
  export PATH="$DOTNET_ROOT:$DOTNET_ROOT/tools:$PATH"
fi
if [ -d "/workspace/.venv/bin" ]; then
  export PATH="/workspace/.venv/bin:$PATH"
fi
if [ -d "/workspace/node_modules/.bin" ]; then
  export PATH="/workspace/node_modules/.bin:$PATH"
fi
EOF
  # Replace /workspace with actual PROJECT_DIR in profile
  sed -i "s|/workspace|${PROJECT_DIR}|g" "${PROFILE_FILE}"
}

# -----------------------------
# Runtime installers
# -----------------------------
install_node_runtime_and_deps() {
  if [ ! -f "${PROJECT_DIR}/package.json" ]; then
    return 0
  fi
  log "Detected Node.js project."

  case "${PM_FAMILY}" in
    debian) pkg_install nodejs npm ;;
    alpine) pkg_install nodejs npm ;;
    rhel)   pkg_install nodejs npm ;;
  esac

  # npm config for CI/container
  export npm_config_loglevel=info
  export npm_config_fund=false
  export npm_config_audit=false
  export npm_config_progress=false
  export npm_config_cache="${PROJECT_DIR}/.cache/npm"
  mkdir -p "${npm_config_cache}"

  pushd "${PROJECT_DIR}" >/dev/null
  if [ -f "package-lock.json" ]; then
    log "Installing Node dependencies with npm ci"
    npm ci --no-optional --unsafe-perm || npm ci --unsafe-perm
  else
    log "Installing Node dependencies with npm install"
    npm install --no-optional --unsafe-perm || npm install --unsafe-perm
  fi
  popd >/dev/null

  # Environment defaults
  {
    echo "NODE_ENV=${APP_ENV}"
    echo "NPM_CONFIG_CACHE=${PROJECT_DIR}/.cache/npm"
  } >> "${PROJECT_DIR}/${ENV_FILE}"
}

install_python_runtime_and_deps() {
  if [ ! -f "${PROJECT_DIR}/requirements.txt" ] && [ ! -f "${PROJECT_DIR}/pyproject.toml" ] && [ ! -f "${PROJECT_DIR}/Pipfile" ] && [ ! -f "${PROJECT_DIR}/setup.py" ]; then
    return 0
  fi
  log "Detected Python project."

  case "${PM_FAMILY}" in
    debian)
      pkg_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev
      ;;
    alpine)
      pkg_install python3 py3-virtualenv py3-pip python3-dev build-base libffi-dev
      ;;
    rhel)
      pkg_install python3 python3-pip python3-virtualenv python3-devel gcc gcc-c++ make libffi-devel
      ;;
  esac

  pushd "${PROJECT_DIR}" >/dev/null
  if [ ! -d ".venv" ]; then
    log "Creating Python virtual environment at .venv"
    python3 -m venv .venv
  else
    log "Python virtual environment already exists."
  fi

  # shellcheck disable=SC1091
  source ".venv/bin/activate"
  python -m pip install --upgrade pip wheel setuptools
  python -m pip install --upgrade "pytest>=8.2" "pluggy>=1.5" "pytest-cov>=4.1" "coverage>=7.5" "pre-commit>=3.6"
  pip uninstall -y pytest-xdist pytest-forked || true
  export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1
  export PYTEST_ADDOPTS="-p no:faulthandler"

  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    log "Installing Python project from pyproject.toml"
    python -m pip install -e ".[dev]"
    pip show scvi-tools || true
    printf 'import scvi\nprint(scvi.__version__)\n' > /tmp/check_scvi_version.py
    python /tmp/check_scvi_version.py
    PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 pytest -q
    PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 coverage run -m pytest -v --color=yes
    coverage report -m
  elif [ -f "setup.py" ]; then
    log "Installing Python project from setup.py"
    pip install .
  fi
  deactivate || true
  popd >/dev/null

  {
    echo "PYTHONUNBUFFERED=1"
    echo "PIP_NO_CACHE_DIR=1"
    echo "VIRTUAL_ENV=${PROJECT_DIR}/.venv"
    echo "PATH=${PROJECT_DIR}/.venv/bin:\$PATH"
  } >> "${PROJECT_DIR}/${ENV_FILE}"
}

install_ruby_runtime_and_deps() {
  if [ ! -f "${PROJECT_DIR}/Gemfile" ]; then
    return 0
  fi
  log "Detected Ruby project."

  case "${PM_FAMILY}" in
    debian)
      pkg_install ruby-full build-essential
      ;;
    alpine)
      pkg_install ruby ruby-bundler ruby-dev build-base
      ;;
    rhel)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
  esac

  pushd "${PROJECT_DIR}" >/dev/null
  if ! have_command bundle; then
    gem install bundler --no-document || true
  fi
  bundle config set path 'vendor/bundle'
  bundle install --jobs=4 --retry=3
  popd >/dev/null

  {
    echo "BUNDLE_DEPLOYMENT=1"
    echo "BUNDLE_PATH=${PROJECT_DIR}/vendor/bundle"
  } >> "${PROJECT_DIR}/${ENV_FILE}"
}

install_php_runtime_and_deps() {
  if [ ! -f "${PROJECT_DIR}/composer.json" ]; then
    return 0
  fi
  log "Detected PHP project."

  case "${PM_FAMILY}" in
    debian)
      pkg_install php-cli php-mbstring php-xml php-json php-curl php-zip unzip curl git
      ;;
    alpine)
      # Package names may vary by image; using common PHP 8.1 names where available
      pkg_install php81 php81-cli php81-phar php81-mbstring php81-xml php81-json php81-curl php81-zip curl unzip git || \
      pkg_install php php-cli php-phar php-mbstring php-xml php-json php-curl php-zip curl unzip git
      ;;
    rhel)
      pkg_install php php-cli php-mbstring php-xml php-json php-common php-zip curl unzip git
      ;;
  esac

  if ! have_command composer; then
    log "Installing Composer"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  pushd "${PROJECT_DIR}" >/dev/null
  composer install --no-interaction --prefer-dist --no-progress --no-ansi
  popd >/dev/null

  {
    echo "COMPOSER_ALLOW_SUPERUSER=1"
    echo "COMPOSER_HOME=${PROJECT_DIR}/.cache/composer"
  } >> "${PROJECT_DIR}/${ENV_FILE}"
}

install_go_runtime_and_deps() {
  if [ ! -f "${PROJECT_DIR}/go.mod" ] && ! ls "${PROJECT_DIR}"/*.go >/dev/null 2>&1; then
    return 0
  fi
  log "Detected Go project."

  case "${PM_FAMILY}" in
    debian) pkg_install golang ;;
    alpine) pkg_install go ;;
    rhel)   pkg_install golang ;;
  esac

  pushd "${PROJECT_DIR}" >/dev/null
  if [ -f "go.mod" ]; then
    log "Downloading Go modules"
    go mod download
  fi
  mkdir -p "${PROJECT_DIR}/bin"
  # Attempt to build if main package present
  if grep -R --include='*.go' -n 'package main' . >/dev/null 2>&1; then
    log "Attempting to build Go project"
    go build -o "${PROJECT_DIR}/bin/app" ./... || warn "Go build failed; dependencies should still be cached."
  fi
  popd >/dev/null
}

install_rust_runtime_and_deps() {
  if [ ! -f "${PROJECT_DIR}/Cargo.toml" ]; then
    return 0
  fi
  log "Detected Rust project."

  case "${PM_FAMILY}" in
    debian) pkg_install rustc cargo pkg-config ;;
    alpine) pkg_install rust cargo pkgconfig ;;
    rhel)   pkg_install rust cargo pkgconfig ;;
  esac

  pushd "${PROJECT_DIR}" >/dev/null
  cargo fetch || warn "Cargo fetch failed."
  # Try to build dependencies only
  cargo build --release -Zminimal-versions 2>/dev/null || cargo build --release || true
  popd >/dev/null
}

install_java_runtime_and_deps() {
  local has_maven=0 has_gradle=0
  [ -f "${PROJECT_DIR}/pom.xml" ] && has_maven=1
  { [ -f "${PROJECT_DIR}/build.gradle" ] || [ -f "${PROJECT_DIR}/build.gradle.kts" ]; } && has_gradle=1
  if [ "${has_maven}" -eq 0 ] && [ "${has_gradle}" -eq 0 ]; then
    return 0
  fi
  log "Detected Java project."

  case "${PM_FAMILY}" in
    debian) pkg_install openjdk-17-jdk maven gradle ;;
    alpine) pkg_install openjdk17-jdk maven gradle ;;
    rhel)   pkg_install java-17-openjdk-devel maven gradle ;;
  esac

  pushd "${PROJECT_DIR}" >/dev/null
  if [ "${has_maven}" -eq 1 ]; then
    log "Priming Maven dependencies"
    mvn -B -ntp -DskipTests dependency:go-offline || warn "Maven go-offline failed."
  fi
  if [ -x "./gradlew" ]; then
    log "Using Gradle wrapper to prepare dependencies"
    ./gradlew --no-daemon dependencies || true
  elif [ "${has_gradle}" -eq 1 ]; then
    log "Preparing Gradle dependencies"
    gradle --no-daemon dependencies || true
  fi
  popd >/dev/null
}

install_dotnet_runtime_and_deps() {
  # Detect .NET by presence of solution or project files
  local dotnet_projects
  dotnet_projects=$(ls "${PROJECT_DIR}"/*.sln "${PROJECT_DIR}"/*.csproj "${PROJECT_DIR}"/*.fsproj 2>/dev/null || true)
  if [ -z "${dotnet_projects}" ]; then
    return 0
  fi
  log "Detected .NET project."

  # Install .NET SDK using official installer to project-local .dotnet (no root repo config needed)
  local DOTNET_ROOT_DIR="${PROJECT_DIR}/.dotnet"
  mkdir -p "${DOTNET_ROOT_DIR}"
  if [ ! -x "${DOTNET_ROOT_DIR}/dotnet" ]; then
    log "Installing .NET SDK (LTS) to ${DOTNET_ROOT_DIR}"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir "${DOTNET_ROOT_DIR}" --channel LTS
    rm -f /tmp/dotnet-install.sh
  else
    log ".NET SDK already installed."
  fi

  export DOTNET_ROOT="${DOTNET_ROOT_DIR}"
  export PATH="${DOTNET_ROOT}:${DOTNET_ROOT}/tools:${PATH}"

  pushd "${PROJECT_DIR}" >/dev/null
  # Restore for each project/solution found
  if ls *.sln >/dev/null 2>&1; then
    for sln in *.sln; do
      log "Restoring .NET solution ${sln}"
      "${DOTNET_ROOT}/dotnet" restore "${sln}" || warn "dotnet restore failed for ${sln}"
    done
  else
    for proj in *.csproj *.fsproj; do
      [ -e "$proj" ] || continue
      log "Restoring .NET project ${proj}"
      "${DOTNET_ROOT}/dotnet" restore "${proj}" || warn "dotnet restore failed for ${proj}"
    done
  fi
  popd >/dev/null

  {
    echo "DOTNET_ROOT=${DOTNET_ROOT_DIR}"
    echo "PATH=${DOTNET_ROOT_DIR}:${DOTNET_ROOT_DIR}/tools:\$PATH"
  } >> "${PROJECT_DIR}/${ENV_FILE}"
}

# -----------------------------
# Runtime-specific environment hints
# -----------------------------
setup_framework_env_hints() {
  # Common defaults
  {
    echo "LOG_DIR=${PROJECT_DIR}/logs"
    echo "TMP_DIR=${PROJECT_DIR}/tmp"
    echo "APP_DIR=${PROJECT_DIR}"
  } >> "${PROJECT_DIR}/${ENV_FILE}"

  # Framework hints
  if [ -f "${PROJECT_DIR}/manage.py" ]; then
    {
      echo "DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE:-config.settings}"
      echo "PYTHONPATH=${PROJECT_DIR}:\$PYTHONPATH"
    } >> "${PROJECT_DIR}/${ENV_FILE}"
  fi
  if [ -f "${PROJECT_DIR}/app.py" ]; then
    {
      echo "FLASK_APP=app.py"
      echo "FLASK_ENV=${APP_ENV}"
      echo "FLASK_RUN_PORT=${DEFAULT_PORT:-5000}"
    } >> "${PROJECT_DIR}/${ENV_FILE}"
  fi
  if [ -f "${PROJECT_DIR}/config.ru" ]; then
    {
      echo "RACK_ENV=${APP_ENV}"
    } >> "${PROJECT_DIR}/${ENV_FILE}"
  fi
  if [ -d "${PROJECT_DIR}/public" ] && [ -f "${PROJECT_DIR}/Gemfile" ]; then
    {
      echo "RAILS_ENV=${APP_ENV}"
      echo "RAILS_LOG_TO_STDOUT=true"
    } >> "${PROJECT_DIR}/${ENV_FILE}"
  fi
  if [ -d "${PROJECT_DIR}/public" ] && [ -f "${PROJECT_DIR}/composer.json" ]; then
    {
      echo "APP_ENV=${APP_ENV}"
    } >> "${PROJECT_DIR}/${ENV_FILE}"
  fi
}

# -----------------------------
# Main execution
# -----------------------------
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line=". \"${PROJECT_DIR}/.venv/bin/activate\""
  if [ -f "${PROJECT_DIR}/.venv/bin/activate" ] && ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

main() {
  log "Starting environment setup (${SCRIPT_NAME}) at ${START_TIME}"
  log "Project directory: ${PROJECT_DIR}"
  detect_pkg_mgr
  install_base_system_packages
  prepare_project_structure
  ensure_app_user

  # Install runtimes and project dependencies based on detection
  install_node_runtime_and_deps
  install_python_runtime_and_deps
  setup_auto_activate
  install_ruby_runtime_and_deps
  install_php_runtime_and_deps
  install_go_runtime_and_deps
  install_rust_runtime_and_deps
  install_java_runtime_and_deps
  install_dotnet_runtime_and_deps

  write_env_files
  setup_framework_env_hints
  set_permissions

  log "Environment setup completed successfully."
  cat <<EOM

Notes:
- Environment variables written to: ${PROJECT_DIR}/${ENV_FILE}
- Shell profile defaults written to: ${PROFILE_FILE}
- To use configured PATH in an interactive shell, run: source ${PROFILE_FILE}
- Project structure prepared under: ${PROJECT_DIR}

Common run hints (adjust to your project):
- Node.js:           npm start
- Python (Flask):    source .venv/bin/activate && python app.py
- Python (Django):   source .venv/bin/activate && python manage.py runserver 0.0.0.0:\${PORT:-${DEFAULT_PORT}}
- Ruby (Rails):      bundle exec rails server -b 0.0.0.0 -p \${PORT:-${DEFAULT_PORT}}
- PHP (Laravel):     php artisan serve --host=0.0.0.0 --port=\${PORT:-${DEFAULT_PORT}}
- Go:                ./bin/app (if built)
- Rust:              cargo run --release
- Java (Maven):      mvn spring-boot:run
- .NET:              \${DOTNET_ROOT:-${PROJECT_DIR}/.dotnet}/dotnet run

EOM
}

main "$@"