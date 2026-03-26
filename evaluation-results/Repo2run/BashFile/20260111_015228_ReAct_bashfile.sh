#!/bin/bash

# Universal project environment setup script for Docker containers
# - Autodetects common project types (Python, Node.js, Ruby, Go, PHP, Java, Rust)
# - Installs runtime and system dependencies
# - Sets up directory structure, permissions, and environment variables
# - Idempotent and safe to run multiple times
# - Designed for root execution inside Docker (no sudo), with fallback for non-root

set -euo pipefail
IFS=$'\n\t'

# Ensure script runs under Bash even if invoked via sh
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  else
    echo "Warning: bash not found; continuing under ${SHELL:-/bin/sh} may cause failures." >&2
  fi
fi

# Colors for output (ANSI)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Global defaults
WORKDIR="${WORKDIR:-$(pwd)}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
SETUP_MARKER_DIR="${WORKDIR}/.setup"
LOG_DIR="${WORKDIR}/logs"
TMP_DIR="${WORKDIR}/tmp"
DEFAULT_SHELL="${SHELL:-/bin/sh}"

# Logging helpers
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "${GREEN}[$(timestamp)] $*${NC}"; }
warn() { echo "${YELLOW}[WARNING] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }

# Trap unexpected errors
cleanup_on_error() {
  err "Setup failed at line ${BASH_LINENO[0]} (command: ${BASH_COMMAND}). Check logs and ensure network connectivity and package manager availability."
}
trap cleanup_on_error ERR

# Ensure setup marker dir exists
mkdir -p "${SETUP_MARKER_DIR}"

# Detect package manager
PM=""
PM_INSTALL_CMD=""
PM_UPDATE_CMD=""
PM_GROUP_ADD=""
PM_USER_ADD=""
PM_CLEAN_CMD=""

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
    PM_UPDATE_CMD="apt-get update -y"
    PM_INSTALL_CMD="apt-get install -y --no-install-recommends"
    PM_CLEAN_CMD="apt-get clean && rm -rf /var/lib/apt/lists/*"
    PM_GROUP_ADD="groupadd -f"
    PM_USER_ADD="useradd -m -s /bin/bash -g ${APP_GROUP} -u 1000"
    export DEBIAN_FRONTEND=noninteractive
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
    PM_UPDATE_CMD="apk update"
    PM_INSTALL_CMD="apk add --no-cache"
    PM_CLEAN_CMD="true"
    PM_GROUP_ADD="addgroup -S"
    PM_USER_ADD="adduser -S -D -H -G ${APP_GROUP} -u 1000 -s /bin/sh"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    PM_UPDATE_CMD="dnf -y makecache"
    PM_INSTALL_CMD="dnf install -y"
    PM_CLEAN_CMD="dnf clean all"
    PM_GROUP_ADD="groupadd -f"
    PM_USER_ADD="useradd -m -s /bin/bash -g ${APP_GROUP} -u 1000"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    PM_UPDATE_CMD="yum -y makecache"
    PM_INSTALL_CMD="yum install -y"
    PM_CLEAN_CMD="yum clean all"
    PM_GROUP_ADD="groupadd -f"
    PM_USER_ADD="useradd -m -s /bin/bash -g ${APP_GROUP} -u 1000"
  elif command -v microdnf >/dev/null 2>&1; then
    PM="microdnf"
    PM_UPDATE_CMD="microdnf -y update"
    PM_INSTALL_CMD="microdnf -y install"
    PM_CLEAN_CMD="microdnf clean all"
    PM_GROUP_ADD="groupadd -f"
    PM_USER_ADD="useradd -m -s /bin/bash -g ${APP_GROUP} -u 1000"
  else
    PM="none"
  fi
}

# Install packages idempotently
install_packages() {
  if [ "${PM}" = "none" ]; then
    warn "No supported package manager found. Skipping system package installation."
    return 0
  fi

  local pkgs=("$@")
  # Build a space-joined list to avoid newlines causing separate commands with eval
  local IFS_SAVE="$IFS"
  IFS=' '
  local pkg_str="${pkgs[*]}"
  IFS="$IFS_SAVE"

  log "Updating package index (${PM})..."
  eval "${PM_UPDATE_CMD}" || warn "Package index update failed, continuing..."

  log "Installing packages: ${pkg_str}"
  eval "${PM_INSTALL_CMD} ${pkg_str}" || {
    err "Failed to install system packages: ${pkg_str}"
    exit 1
  }

  eval "${PM_CLEAN_CMD}" || true
}

# Setup core system dependencies
setup_system_deps() {
  local marker="${SETUP_MARKER_DIR}/system_deps.done"
  if [ -f "${marker}" ]; then
    # Verify critical dev libraries for PyAV/FFmpeg are present; install if missing
    detect_package_manager
    if command -v pkg-config >/dev/null 2>&1; then
      if ! pkg-config --exists libavformat libavcodec libavdevice libavutil libavfilter libswscale libswresample; then
        if [ "${PM}" = "apt" ]; then
          log "FFmpeg development libraries missing. Installing required packages..."
          install_packages ffmpeg libavformat-dev libavcodec-dev libavdevice-dev libavutil-dev libavfilter-dev libswscale-dev libswresample-dev libgl1 libglib2.0-0 build-essential pkg-config
        else
          warn "FFmpeg dev libraries appear missing but automatic installation for PM=${PM} is not configured."
        fi
      fi
    else
      # If pkg-config is missing, attempt to install it and dev libraries on apt
      if [ "${PM}" = "apt" ]; then
        log "pkg-config not found. Installing pkg-config and FFmpeg dev libraries..."
        install_packages pkg-config ffmpeg libavformat-dev libavcodec-dev libavdevice-dev libavutil-dev libavfilter-dev libswscale-dev libswresample-dev libgl1 libglib2.0-0 build-essential
      fi
    fi
    log "System dependencies already installed. Skipping."
    return 0
  fi

  detect_package_manager
  log "Detected package manager: ${PM}"

  case "${PM}" in
    apt)
      install_packages bash ca-certificates curl wget git gnupg openssh-client \
        build-essential pkg-config libssl-dev zlib1g-dev libffi-dev \
        libsqlite3-dev jq ffmpeg libavformat-dev libavcodec-dev libavdevice-dev \
        libavutil-dev libavfilter-dev libswscale-dev libswresample-dev libgl1 libglib2.0-0
      update-ca-certificates || true
      ;;
    apk)
      install_packages ca-certificates curl wget git openssh \
        build-base pkgconfig openssl-dev zlib-dev libffi-dev sqlite-dev
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      install_packages ca-certificates curl wget git gnupg2 openssh-clients \
        gcc gcc-c++ make pkgconfig openssl-devel zlib-devel libffi-devel sqlite-devel
      ;;
    *)
      warn "Skipping system dependency installation due to unknown package manager."
      ;;
  esac

  touch "${marker}"
}

# Create non-root application user (optional but recommended)
ensure_app_user() {
  local marker="${SETUP_MARKER_DIR}/app_user.done"
  if [ -f "${marker}" ]; then
    log "Application user already set up."
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root. Cannot create system user. Continuing with current user."
    touch "${marker}"
    return 0
  fi

  detect_package_manager

  # Create group
  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    if [ "${PM}" = "apk" ]; then
      ${PM_GROUP_ADD} "${APP_GROUP}" || warn "Failed to create group ${APP_GROUP}"
    else
      ${PM_GROUP_ADD} "${APP_GROUP}" || warn "Failed to create group ${APP_GROUP}"
    fi
  fi

  # Create user
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    if [ "${PM}" = "apk" ]; then
      ${PM_USER_ADD} "${APP_USER}" || warn "Failed to create user ${APP_USER}"
    else
      ${PM_USER_ADD} "${APP_USER}" || warn "Failed to create user ${APP_USER}"
    fi
  fi

  touch "${marker}"
}

# Setup directories and permissions
setup_dirs() {
  local marker="${SETUP_MARKER_DIR}/dirs.done"
  if [ -f "${marker}" ]; then
    log "Directories already set up."
    return 0
  fi

  log "Setting up project directories at ${WORKDIR}"
  mkdir -p "${WORKDIR}"
  mkdir -p "${LOG_DIR}" "${TMP_DIR}"

  # Language-specific dirs if project detected later will be created as needed

  # Set permissions
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${WORKDIR}" || warn "Failed to chown ${WORKDIR}"
  fi
  chmod -R u+rwX,g+rX,o-rwx "${WORKDIR}"

  touch "${marker}"
}

# Environment variables setup
setup_env_vars() {
  local marker="${SETUP_MARKER_DIR}/env.done"
  if [ -f "${marker}" ]; then
    log "Environment variables already configured."
    return 0
  fi

  log "Configuring environment variables..."
  cat > "${WORKDIR}/env.sh" <<EOF
# Generated by setup script on $(timestamp)
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
export WORKDIR="${WORKDIR}"
export PATH="\$WORKDIR/.venv/bin:\$PATH"
# Add additional variables below or use .env to override
EOF

  # Load .env if present at runtime; we just ensure the file exists
  if [ ! -f "${WORKDIR}/.env" ]; then
    cat > "${WORKDIR}/.env" <<EOF
# Environment overrides
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
# Add project-specific variables here (DATABASE_URL, API_KEYS, etc.)
EOF
  fi

  touch "${marker}"
}

# Detect project type(s)
PROJECT_TYPES=()
detect_project_types() {
  PROJECT_TYPES=()
  # Python
  if [ -f "${WORKDIR}/requirements.txt" ] || [ -f "${WORKDIR}/pyproject.toml" ] || [ -f "${WORKDIR}/Pipfile" ]; then
    PROJECT_TYPES+=("python")
  fi
  # Node.js
  if [ -f "${WORKDIR}/package.json" ]; then
    PROJECT_TYPES+=("node")
  fi
  # Ruby
  if [ -f "${WORKDIR}/Gemfile" ]; then
    PROJECT_TYPES+=("ruby")
  fi
  # Go
  if [ -f "${WORKDIR}/go.mod" ]; then
    PROJECT_TYPES+=("go")
  fi
  # PHP
  if [ -f "${WORKDIR}/composer.json" ]; then
    PROJECT_TYPES+=("php")
  fi
  # Java (Maven/Gradle)
  if ls "${WORKDIR}"/*.pom.xml >/dev/null 2>&1 || [ -f "${WORKDIR}/pom.xml" ]; then
    PROJECT_TYPES+=("java-maven")
  fi
  if [ -f "${WORKDIR}/build.gradle" ] || [ -f "${WORKDIR}/gradlew" ]; then
    PROJECT_TYPES+=("java-gradle")
  fi
  # Rust
  if [ -f "${WORKDIR}/Cargo.toml" ]; then
    PROJECT_TYPES+=("rust")
  fi
}

# Setup Python runtime and dependencies
setup_python() {
  local marker="${SETUP_MARKER_DIR}/python.done"
  if [ -f "${marker}" ]; then
    log "Python environment already set up."
    # Ensure critical Python deps are installed even on subsequent runs (repair path)
    if [ -f "${WORKDIR}/requirements.txt" ]; then
      # shellcheck disable=SC1091
      source "${WORKDIR}/.venv/bin/activate" || true
      # Ensure system FFmpeg dev libraries and build tools are present (apt-based systems)
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y --no-install-recommends ffmpeg libavcodec-dev libavutil-dev libavformat-dev libavfilter-dev libavdevice-dev libswresample-dev libswscale-dev build-essential pkg-config python3-dev libgl1 libglib2.0-0 || true
        rm -rf /var/lib/apt/lists/* || true
      fi
      python -m pip install -U pip setuptools wheel
      mkdir -p "$HOME/.config/pip" && printf "[global]\nprefer-binary = true\nonly-binary = av,decord\n" > "$HOME/.config/pip/pip.conf"
      python -m pip uninstall -y av || true
      PIP_ONLY_BINARY=:all: PIP_PREFER_BINARY=1 python -m pip install "av>=12,<13"
      python -m pip install -U decord
      python -m pip install --no-cache-dir webcolors decord av moviepy imageio imageio-ffmpeg
      PIP_PREFER_BINARY=1 python -m pip install -r "${WORKDIR}/requirements.txt" || true
      test -f "${WORKDIR}/requirements/demo.txt" && pip install -r "${WORKDIR}/requirements/demo.txt" || true
      test -f "${WORKDIR}/requirements/optional.txt" && pip install -r "${WORKDIR}/requirements/optional.txt" || true
      # Repair: ensure compatible mmcv version
      pip uninstall -y mmcv mmcv-full || true
      pip install -U "mmcv-full==1.6.0" -f https://download.openmmlab.com/mmcv/dist/cu111/torch1.9.0/index.html
      deactivate || true
    fi
    return 0
  fi

  log "Setting up Python environment..."
  detect_package_manager
  case "${PM}" in
    apt)
      install_packages python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      install_packages python3 py3-pip python3-dev
      # venv module typically included; ensure virtualenv if needed
      ;;
    dnf|yum|microdnf)
      install_packages python3 python3-pip python3-devel
      ;;
    *)
      warn "Package manager not available for Python installation. Assuming python3 present."
      ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 not found. Please ensure Python is available."
    exit 1
  fi

  mkdir -p "${WORKDIR}/.venv"
  if [ ! -d "${WORKDIR}/.venv/bin" ]; then
    python3 -m venv "${WORKDIR}/.venv"
  fi

  # Activate venv for the current process to install deps
  # shellcheck disable=SC1091
  source "${WORKDIR}/.venv/bin/activate"
  python -m pip install -U pip setuptools wheel
  mkdir -p "$HOME/.config/pip" && printf "[global]\nprefer-binary = true\nonly-binary = av,decord\n" > "$HOME/.config/pip/pip.conf"
  python -m pip uninstall -y av || true
  PIP_ONLY_BINARY=:all: PIP_PREFER_BINARY=1 python -m pip install "av>=12,<13"
  python -m pip install -U decord
  python -m pip install --no-cache-dir webcolors decord av moviepy imageio imageio-ffmpeg

  if [ -f "${WORKDIR}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    # Ensure system FFmpeg dev libraries and build tools (apt-based systems)
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg libavcodec-dev libavutil-dev libavformat-dev libavfilter-dev libavdevice-dev \
        libswresample-dev libswscale-dev build-essential pkg-config python3-dev libgl1 libglib2.0-0 || true
      rm -rf /var/lib/apt/lists/* || true
    fi
    # Upgrade packaging tools
    pip install -U pip setuptools wheel
    # Optionally ensure OpenCV is available in headless environments
    pip install -U opencv-python-headless || true
    # Prefer binary wheels for PyAV and decord to avoid brittle source builds
    python -m pip uninstall -y av || true
    PIP_ONLY_BINARY=:all: PIP_PREFER_BINARY=1 python -m pip install "av>=12,<13"
    python -m pip install -U decord
    # Install project requirements preferring binary wheels
    PIP_PREFER_BINARY=1 python -m pip install -r "${WORKDIR}/requirements.txt"
    test -f "${WORKDIR}/requirements/demo.txt" && pip install -r "${WORKDIR}/requirements/demo.txt" || true
    test -f "${WORKDIR}/requirements/optional.txt" && pip install -r "${WORKDIR}/requirements/optional.txt" || true
    # Repair: enforce compatible mmcv version after requirements installation
    pip uninstall -y mmcv mmcv-full || true
    pip install -U "mmcv-full==1.6.0" -f https://download.openmmlab.com/mmcv/dist/cu111/torch1.9.0/index.html
  elif [ -f "${WORKDIR}/pyproject.toml" ]; then
    # Try Poetry if it's a Poetry project; otherwise fallback to pip PEP517
    if grep -q '\[tool\.poetry\]' "${WORKDIR}/pyproject.toml"; then
      log "Poetry project detected. Installing Poetry and dependencies..."
      python3 -m pip install "poetry>=1.5"
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi
    else
      log "PEP 517 project detected. Installing via pip..."
      python3 -m pip install .
    fi
  elif [ -f "${WORKDIR}/Pipfile" ]; then
    log "Pipenv project detected. Installing pipenv and dependencies..."
    python3 -m pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || pipenv install
  else
    log "No Python dependency manifest found. Skipping dependency installation."
  fi

  # Common ports for Python web apps; override via env if needed
  if [ -f "${WORKDIR}/app.py" ] || [ -f "${WORKDIR}/wsgi.py" ] || [ -d "${WORKDIR}/django_project" ]; then
    APP_PORT="${APP_PORT:-8000}"
  fi

  deactivate || true
  touch "${marker}"
}

# Setup Node.js runtime and dependencies
setup_node() {
  local marker="${SETUP_MARKER_DIR}/node.done"
  if [ -f "${marker}" ]; then
    log "Node.js environment already set up."
    return 0
  fi

  log "Setting up Node.js environment..."
  detect_package_manager
  case "${PM}" in
    apt)
      # Use distro nodejs/npm to avoid external repos in generic containers
      install_packages nodejs npm
      ;;
    apk)
      install_packages nodejs npm
      ;;
    dnf|yum|microdnf)
      install_packages nodejs npm
      ;;
    *)
      warn "No package manager available to install Node.js. Skipping Node runtime installation."
      ;;
  esac

  if [ -f "${WORKDIR}/package.json" ]; then
    # Use npm ci when lockfile exists to ensure reproducibility
    if [ -f "${WORKDIR}/package-lock.json" ]; then
      log "Installing Node dependencies with npm ci..."
      npm ci --prefer-offline --no-audit --no-fund
    else
      log "Installing Node dependencies with npm install..."
      npm install --prefer-offline --no-audit --no-fund
    fi

    # Determine common ports for web apps
    if jq -r '.scripts.start // ""' < "${WORKDIR}/package.json" >/dev/null 2>&1; then
      APP_PORT="${APP_PORT:-3000}"
    fi
  else
    warn "package.json not found. Skipping Node dependency installation."
  fi

  touch "${marker}"
}

# Setup Ruby runtime and dependencies
setup_ruby() {
  local marker="${SETUP_MARKER_DIR}/ruby.done"
  if [ -f "${marker}" ]; then
    log "Ruby environment already set up."
    return 0
  fi

  if [ ! -f "${WORKDIR}/Gemfile" ]; then
    return 0
  fi

  log "Setting up Ruby environment..."
  detect_package_manager
  case "${PM}" in
    apt)
      install_packages ruby-full build-essential
      ;;
    apk)
      install_packages ruby ruby-bundler build-base
      ;;
    dnf|yum|microdnf)
      install_packages ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      warn "No package manager available to install Ruby. Skipping Ruby setup."
      ;;
  esac

  if command -v bundle >/dev/null 2>&1; then
    log "Installing Ruby gems with Bundler..."
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4 --retry=3
  else
    warn "Bundler not found. Attempting gem install bundler..."
    if command -v gem >/dev/null 2>&1; then
      gem install bundler
      bundle config set path 'vendor/bundle'
      bundle install --jobs=4 --retry=3
    else
      warn "RubyGems not available. Skipping Ruby dependency installation."
    fi
  fi

  touch "${marker}"
}

# Setup Go runtime and dependencies
setup_go() {
  local marker="${SETUP_MARKER_DIR}/go.done"
  if [ -f "${marker}" ]; then
    log "Go environment already set up."
    return 0
  fi

  if [ ! -f "${WORKDIR}/go.mod" ]; then
    return 0
  fi

  log "Setting up Go environment..."
  detect_package_manager
  case "${PM}" in
    apt)
      install_packages golang
      ;;
    apk)
      install_packages go
      ;;
    dnf|yum|microdnf)
      install_packages golang
      ;;
    *)
      warn "No package manager available to install Go. Skipping Go setup."
      ;;
  esac

  if command -v go >/dev/null 2>&1; then
    log "Pre-fetching Go modules..."
    go mod download
    mkdir -p "${WORKDIR}/bin"
    # Optional build step for CLI tools; comment out if not desired
    # go build -o "${WORKDIR}/bin/app" ./...
  else
    warn "Go not installed. Skipping go mod download."
  fi

  touch "${marker}"
}

# Setup PHP runtime and dependencies
setup_php() {
  local marker="${SETUP_MARKER_DIR}/php.done"
  if [ -f "${marker}" ]; then
    log "PHP environment already set up."
    return 0
  fi

  if [ ! -f "${WORKDIR}/composer.json" ]; then
    return 0
  fi

  log "Setting up PHP environment..."
  detect_package_manager
  case "${PM}" in
    apt)
      install_packages php-cli php-zip unzip
      ;;
    apk)
      install_packages php-cli php php-openssl php-json php-phar php-zip
      ;;
    dnf|yum|microdnf)
      install_packages php-cli unzip zip
      ;;
    *)
      warn "No package manager available to install PHP. Skipping PHP setup."
      ;;
  esac

  # Install Composer if missing
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || {
      warn "Composer installation failed. Attempting local install..."
      php /tmp/composer-setup.php --install-dir="${WORKDIR}" --filename=composer
      export PATH="${WORKDIR}:${PATH}"
    }
    rm -f /tmp/composer-setup.php || true
  fi

  if command -v composer >/dev/null 2>&1; then
    log "Installing PHP dependencies with Composer..."
    composer install --no-interaction --prefer-dist --no-progress --no-suggest
  else
    warn "Composer not available. Skipping PHP dependency installation."
  fi

  touch "${marker}"
}

# Setup Java runtime and dependencies (Maven and/or Gradle)
setup_java() {
  local marker="${SETUP_MARKER_DIR}/java.done"
  if [ -f "${marker}" ]; then
    log "Java environment already set up."
    return 0
  fi

  local has_maven=0
  local has_gradle=0
  if [ -f "${WORKDIR}/pom.xml" ]; then has_maven=1; fi
  if [ -f "${WORKDIR}/build.gradle" ] || [ -f "${WORKDIR}/gradlew" ]; then has_gradle=1; fi
  if [ "${has_maven}" -eq 0 ] && [ "${has_gradle}" -eq 0 ]; then
    return 0
  fi

  log "Setting up Java environment..."
  detect_package_manager
  case "${PM}" in
    apt)
      install_packages openjdk-17-jdk maven gradle || install_packages openjdk-11-jdk maven
      ;;
    apk)
      install_packages openjdk17 maven gradle || install_packages openjdk11 maven
      ;;
    dnf|yum|microdnf)
      install_packages java-17-openjdk-devel maven gradle || install_packages java-11-openjdk-devel maven
      ;;
    *)
      warn "No package manager available to install Java. Skipping Java setup."
      ;;
  esac

  if [ "${has_maven}" -eq 1 ] && command -v mvn >/dev/null 2>&1; then
    log "Pre-fetching Maven dependencies (go-offline)..."
    mvn -B -ntp dependency:go-offline || warn "Maven go-offline failed."
  fi
  if [ "${has_gradle}" -eq 1 ] && command -v gradle >/dev/null 2>&1; then
    log "Pre-fetching Gradle dependencies..."
    gradle --no-daemon build -x test || warn "Gradle build for dependency resolution failed."
  fi

  touch "${marker}"
}

# Setup Rust runtime and dependencies
setup_rust() {
  local marker="${SETUP_MARKER_DIR}/rust.done"
  if [ -f "${marker}" ]; then
    log "Rust environment already set up."
    return 0
  fi

  if [ ! -f "${WORKDIR}/Cargo.toml" ]; then
    return 0
  fi

  log "Setting up Rust environment..."
  detect_package_manager
  case "${PM}" in
    apt)
      install_packages cargo
      ;;
    apk)
      install_packages rust cargo
      ;;
    dnf|yum|microdnf)
      install_packages cargo rust
      ;;
    *)
      warn "No package manager available to install Rust. Skipping Rust setup."
      ;;
  esac

  if command -v cargo >/dev/null 2>&1; then
    log "Fetching Rust dependencies..."
    cargo fetch || warn "Cargo fetch failed."
    # Optional build:
    # cargo build --release
  else
    warn "Cargo not installed. Skipping Rust dependency setup."
  fi

  touch "${marker}"
}

# Finalize permissions
finalize_permissions() {
  local marker="${SETUP_MARKER_DIR}/perm.done"
  if [ -f "${marker}" ]; then
    log "Permissions already finalized."
    return 0
  fi

  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${WORKDIR}" || warn "Failed to chown ${WORKDIR}"
  fi
  chmod -R u+rwX,g+rX,o-rwx "${WORKDIR}"

  touch "${marker}"
}

# Configure shell auto-activation of the Python virtual environment
setup_auto_activate() {
  # Use the venv path referenced in this script
  local venv_activate="${WORKDIR}/.venv/bin/activate"
  local bashrc_file="${HOME}/.bashrc"
  local activate_line="source ${venv_activate}"

  # Only add if venv exists
  if [ -f "${venv_activate}" ]; then
    if ! grep -qF "${activate_line}" "${bashrc_file}" 2>/dev/null; then
      echo "" >> "${bashrc_file}"
      echo "# Auto-activate Python virtual environment" >> "${bashrc_file}"
      echo "${activate_line}" >> "${bashrc_file}"
    fi

    # Also add for APP_USER if different and exists
    if id -u "${APP_USER}" >/dev/null 2>&1; then
      local user_home
      user_home=$(getent passwd "${APP_USER}" | cut -d: -f6)
      if [ -n "${user_home}" ] && [ -d "${user_home}" ]; then
        local user_bashrc="${user_home}/.bashrc"
        if ! grep -qF "${activate_line}" "${user_bashrc}" 2>/dev/null; then
          echo "" >> "${user_bashrc}"
          echo "# Auto-activate Python virtual environment" >> "${user_bashrc}"
          echo "${activate_line}" >> "${user_bashrc}"
          chown "${APP_USER}:${APP_GROUP}" "${user_bashrc}" || true
        fi
      fi
    fi
  fi
}

# Display summary and usage
show_summary() {
  log "Environment setup completed successfully."
  echo "Summary:"
  echo "- Workdir: ${WORKDIR}"
  echo "- Detected project types: ${PROJECT_TYPES[*]:-none}"
  echo "- Logs directory: ${LOG_DIR}"
  echo "- Temp directory: ${TMP_DIR}"
  echo "- App user: $(id -un 2>/dev/null || echo "$(whoami)")"
  echo "- To load environment variables: source ${WORKDIR}/env.sh && export \$(grep -v '^#' ${WORKDIR}/.env | xargs)"
  echo "- Default app port: ${APP_PORT}"
}

# Main
main() {
  log "Starting universal project environment setup..."
  setup_system_deps
  ensure_app_user
  setup_dirs
  setup_env_vars
  detect_project_types

  # Execute relevant setup routines based on detection
  for t in "${PROJECT_TYPES[@]:-}"; do
    case "$t" in
      python) setup_python ;;
      node) setup_node ;;
      ruby) setup_ruby ;;
      go) setup_go ;;
      php) setup_php ;;
      java-maven|java-gradle) setup_java ;;
      rust) setup_rust ;;
      *)
        warn "Unknown project type detected: $t"
        ;;
    esac
  done

  finalize_permissions
  setup_auto_activate
  show_summary

  log "Setup script finished."
}

# Execute
main "$@"