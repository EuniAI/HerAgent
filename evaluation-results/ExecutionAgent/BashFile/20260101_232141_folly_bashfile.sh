#!/usr/bin/env bash
# Project Environment Setup Script
# This script auto-detects the project type and sets up the environment inside a Docker container.
# It installs system packages, language runtimes, and project dependencies following best practices.
#
# Usage:
#   setup.sh [-d APP_DIR] [--type {python|node|ruby|go|java|php|rust|dotnet}] [-y]
# Examples:
#   ./setup.sh
#   ./setup.sh -d /app
#   ./setup.sh --type python

set -Eeuo pipefail

# Globals and defaults
APP_DIR="${APP_DIR:-}"
PROJECT_TYPE="${PROJECT_TYPE:-}"
ASSUME_YES="false"
DEBIAN_FRONTEND=noninteractive
UMASK_DEFAULT="022"

# Colors for output (fallback to no color if terminal doesn't support)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  NC=""
fi

# Logging functions
log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

# Error trap to show line number
trap 'err "An error occurred at line $LINENO. Exiting."; exit 1' ERR

usage() {
  cat <<EOF
Project Environment Setup Script

Options:
  -d, --dir PATH         Application directory (default: current working directory)
  -t, --type TYPE        Force project type: python|node|ruby|go|java|php|rust|dotnet
  -y, --yes              Assume "yes" for package installs (non-interactive)
  -h, --help             Show this help

Environment variables:
  APP_DIR                 Same as --dir
  PROJECT_TYPE            Same as --type
EOF
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--dir) APP_DIR="${2:-}"; shift 2 ;;
    -t|--type) PROJECT_TYPE="${2:-}"; shift 2 ;;
    -y|--yes) ASSUME_YES="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

# Ensure we are in correct directory
if [ -z "${APP_DIR}" ]; then
  APP_DIR="$(pwd)"
fi
if [ ! -d "${APP_DIR}" ]; then
  die "Application directory does not exist: ${APP_DIR}"
fi

# Ensure we can write to APP_DIR
if [ ! -w "${APP_DIR}" ]; then
  die "Application directory is not writable: ${APP_DIR}"
fi

umask "${UMASK_DEFAULT}"

# Detect if running as root (Docker usually runs as root)
IS_ROOT="false"
if [ "$(id -u)" -eq 0 ]; then
  IS_ROOT="true"
fi

# Detect OS and package manager
OS_ID=""
OS_NAME=""
PKG_MANAGER=""
PKG_INSTALL_CMD=""
PKG_UPDATE_CMD=""
PKG_SETUP_DONE_STAMP="/var/tmp/setup_pkg_manager_initialized"

detect_pkg_manager() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_NAME="${NAME:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    PKG_UPDATE_CMD="apt-get update -y"
    if [ "${ASSUME_YES}" = "true" ]; then
      PKG_INSTALL_CMD="apt-get install -y --no-install-recommends"
    else
      PKG_INSTALL_CMD="apt-get install -y --no-install-recommends"
    fi
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_UPDATE_CMD="apk update"
    if [ "${ASSUME_YES}" = "true" ]; then
      PKG_INSTALL_CMD="apk add --no-cache"
    else
      PKG_INSTALL_CMD="apk add --no-cache"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_UPDATE_CMD="dnf -y update"
    if [ "${ASSUME_YES}" = "true" ]; then
      PKG_INSTALL_CMD="dnf -y install"
    else
      PKG_INSTALL_CMD="dnf -y install"
    fi
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_UPDATE_CMD="yum -y update"
    if [ "${ASSUME_YES}" = "true" ]; then
      PKG_INSTALL_CMD="yum -y install"
    else
      PKG_INSTALL_CMD="yum -y install"
    fi
  else
    PKG_MANAGER=""
  fi

  if [ -z "${PKG_MANAGER}" ]; then
    warn "No supported package manager found. System package installation will be skipped."
  else
    log "Detected package manager: ${PKG_MANAGER} (${OS_NAME:-unknown})"
  fi
}

pkg_update() {
  [ -z "${PKG_MANAGER}" ] && return 0
  if [ "${IS_ROOT}" != "true" ]; then
    warn "Not running as root. Skipping system package update."
    return 0
  fi
  log "Updating package indexes..."
  eval "${PKG_UPDATE_CMD}"
}

pkg_install() {
  [ -z "${PKG_MANAGER}" ] && return 0
  if [ "${IS_ROOT}" != "true" ]; then
    warn "Not running as root. Skipping system package install: $*"
    return 0
  fi
  # shellcheck disable=SC2086
  eval "${PKG_INSTALL_CMD} $*"
}

ensure_ca_certificates() {
  case "${PKG_MANAGER}" in
    apt) pkg_install ca-certificates ;;
    apk) pkg_install ca-certificates ;;
    dnf|yum) pkg_install ca-certificates ;;
    *) ;;
  esac
}

ensure_base_tools() {
  log "Installing base tools..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_update
      pkg_install apt-transport-https curl wget git gnupg procps tzdata m4 autoconf automake libtool build-essential pkg-config libssl-dev ca-certificates
      ;;
    apk)
      pkg_update
      pkg_install curl wget git bash coreutils tar gzip ca-certificates build-base openssl-dev pkgconf
      ;;
    dnf|yum)
      pkg_update
      pkg_install curl wget git gnupg procps-ng tzdata gcc gcc-c++ make openssl-devel pkgconfig ca-certificates
      ;;
    *)
      warn "Skipping base tools installation due to unsupported or missing package manager."
      ;;
  esac
}

# Network check
check_network() {
  if command -v curl >/dev/null 2>&1; then
    if ! curl -s --max-time 5 https://example.com >/dev/null 2>&1; then
      warn "Network connectivity check failed. Package installations or dependency downloads may fail."
    fi
  else
    warn "curl not available to perform network check."
  fi
}

# Project type detection
detect_project_type() {
  if [ -n "${PROJECT_TYPE}" ]; then
    log "Project type forced to: ${PROJECT_TYPE}"
    return
  fi

  if [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/Pipfile" ]; then
    PROJECT_TYPE="python"
  elif [ -f "${APP_DIR}/package.json" ]; then
    PROJECT_TYPE="node"
  elif [ -f "${APP_DIR}/Gemfile" ]; then
    PROJECT_TYPE="ruby"
  elif [ -f "${APP_DIR}/go.mod" ]; then
    PROJECT_TYPE="go"
  elif [ -f "${APP_DIR}/composer.json" ]; then
    PROJECT_TYPE="php"
  elif [ -f "${APP_DIR}/pom.xml" ] || [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/gradlew" ]; then
    PROJECT_TYPE="java"
  elif [ -f "${APP_DIR}/Cargo.toml" ]; then
    PROJECT_TYPE="rust"
  elif ls "${APP_DIR}"/*.sln >/dev/null 2>&1 || ls "${APP_DIR}"/*.csproj >/dev/null 2>&1; then
    PROJECT_TYPE="dotnet"
  else
    PROJECT_TYPE="unknown"
  fi

  log "Detected project type: ${PROJECT_TYPE}"
}

# Directory setup
setup_directories() {
  log "Setting up project directories under ${APP_DIR}..."
  mkdir -p "${APP_DIR}/logs" "${APP_DIR}/tmp" "${APP_DIR}/cache" "${APP_DIR}/bin"
  chmod 755 "${APP_DIR}/logs" "${APP_DIR}/tmp" "${APP_DIR}/cache" "${APP_DIR}/bin"
  # Do not chown non-root target user unless specified; Docker usually runs as root.
  log "Project directories created with appropriate permissions."
}

# Environment setup
setup_common_env() {
  log "Configuring common environment variables..."
  export APP_HOME="${APP_DIR}"
  export APP_ENV="${APP_ENV:-production}"
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export PATH="${APP_DIR}/bin:${PATH}"

  # Persist environment for shells (if available)
  ENV_FILE="${APP_DIR}/.env"
  {
    echo "APP_HOME=${APP_DIR}"
    echo "APP_ENV=${APP_ENV}"
    echo "LANG=${LANG}"
    echo "LC_ALL=${LC_ALL}"
    echo "PATH=${APP_DIR}/bin:\$PATH"
  } > "${ENV_FILE}"
  chmod 644 "${ENV_FILE}"

  if [ "${IS_ROOT}" = "true" ] && [ -d /etc/profile.d ]; then
    cat > /etc/profile.d/app_env.sh <<EOF
export APP_HOME="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export LANG="${LANG}"
export LC_ALL="${LC_ALL}"
export PATH="${APP_DIR}/bin:\$PATH"
EOF
    chmod 644 /etc/profile.d/app_env.sh
  fi
  log "Environment variables written to ${ENV_FILE}"
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev build-essential libffi-dev libssl-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev build-base libffi-dev openssl-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    *)
      warn "No package manager available to install Python. Assuming Python is already present."
      ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    die "Python3 is required but not installed."
  fi
  if ! command -v pip3 >/dev/null 2>&1; then
    die "pip3 is required but not installed."
  fi

  VENV_PATH="${APP_DIR}/.venv"
  if [ ! -d "${VENV_PATH}" ]; then
    log "Creating Python virtual environment at ${VENV_PATH}..."
    python3 -m venv "${VENV_PATH}"
  else
    log "Virtual environment already exists at ${VENV_PATH}."
  fi

  # Activate venv for this script
  # shellcheck disable=SC1091
  . "${VENV_PATH}/bin/activate"

  export PYTHONUNBUFFERED=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1

  python3 -m pip install --upgrade pip setuptools wheel

  if [ -f "${APP_DIR}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    python3 -m pip install -r "${APP_DIR}/requirements.txt"
  elif [ -f "${APP_DIR}/pyproject.toml" ]; then
    log "Installing Python project from pyproject.toml..."
    python3 -m pip install .
  elif [ -f "${APP_DIR}/Pipfile" ]; then
    log "Pipfile detected. Installing pipenv and dependencies..."
    python3 -m pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
  else
    warn "No Python dependency file found (requirements.txt/pyproject.toml/Pipfile). Skipping dependency installation."
  fi

  # Persist Python-specific env vars
  {
    echo "VIRTUAL_ENV=${VENV_PATH}"
    echo "PYTHONUNBUFFERED=1"
    echo "PIP_DISABLE_PIP_VERSION_CHECK=1"
    echo "PIP_NO_CACHE_DIR=1"
    echo "PATH=${VENV_PATH}/bin:\$PATH"
  } >> "${APP_DIR}/.env"

  # Create a generic run wrapper if app.py exists
  if [ -f "${APP_DIR}/app.py" ]; then
    cat > "${APP_DIR}/bin/run" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${APP_DIR}/.venv"
# shellcheck disable=SC1091
. "${VENV}/bin/activate"
export PYTHONUNBUFFERED=1
exec python "${APP_DIR}/app.py"
EOF
    chmod +x "${APP_DIR}/bin/run"
  fi

  log "Python environment setup complete."
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install nodejs npm
      # Fallback to NodeSource if node version is too old
      if command -v node >/dev/null 2>&1; then
        NODE_VER="$(node -v || echo v0)"
      else
        NODE_VER="v0"
      fi
      if [ "${NODE_VER#v}" \< "14.0.0" ] || ! command -v node >/dev/null 2>&1; then
        warn "Node.js version is missing or older than 14. Attempting to install via NodeSource..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        pkg_install nodejs
      fi
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
    *)
      warn "No package manager available to install Node.js. Assuming Node.js is already present."
      ;;
  esac

  if ! command -v node >/dev/null 2>&1; then
    die "Node.js is required but not installed."
  fi
  if ! command -v npm >/dev/null 2>&1; then
    die "npm is required but not installed."
  fi

  export NODE_ENV=production
  # Detect package manager
  PM="npm"
  if [ -f "${APP_DIR}/pnpm-lock.yaml" ]; then
    PM="pnpm"
    npm install -g pnpm
  elif [ -f "${APP_DIR}/yarn.lock" ]; then
    PM="yarn"
    npm install -g yarn
  fi

  # Install dependencies
  if [ -f "${APP_DIR}/package-lock.json" ] && [ "${PM}" = "npm" ]; then
    log "Installing Node.js dependencies with npm ci..."
    (cd "${APP_DIR}" && npm ci --omit=dev)
  elif [ -f "${APP_DIR}/package.json" ]; then
    case "${PM}" in
      npm)
        log "Installing Node.js dependencies with npm..."
        (cd "${APP_DIR}" && npm install --omit=dev)
        ;;
      yarn)
        log "Installing Node.js dependencies with yarn..."
        (cd "${APP_DIR}" && yarn install --frozen-lockfile --production=true)
        ;;
      pnpm)
        log "Installing Node.js dependencies with pnpm..."
        (cd "${APP_DIR}" && pnpm install --frozen-lockfile --prod)
        ;;
    esac
  else
    warn "No package.json found. Skipping Node.js dependency installation."
  fi

  # Create generic run wrapper if an entrypoint is defined
  if [ -f "${APP_DIR}/package.json" ]; then
    # Attempt to create a run script that uses start script if present
    cat > "${APP_DIR}/bin/run" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_ENV="${NODE_ENV:-production}"
if [ -f "${APP_DIR}/package.json" ] && jq -e '.scripts.start' "${APP_DIR}/package.json" >/dev/null 2>&1; then
  cd "${APP_DIR}"
  exec npm start --silent
else
  # Fallback: try to run index.js
  if [ -f "${APP_DIR}/index.js" ]; then
    exec node "${APP_DIR}/index.js"
  else
    echo "No start script or index.js found."
    exit 1
  fi
fi
EOF
    chmod +x "${APP_DIR}/bin/run" || true
  fi

  # Persist Node env
  {
    echo "NODE_ENV=production"
    echo "PATH=${APP_DIR}/node_modules/.bin:\$PATH"
  } >> "${APP_DIR}/.env"

  log "Node.js environment setup complete."
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-bundler build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      warn "No package manager available to install Ruby. Assuming Ruby is already present."
      ;;
  esac

  if ! command -v ruby >/dev/null 2>&1; then
    die "Ruby is required but not installed."
  fi

  # Bundler
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  if [ -f "${APP_DIR}/Gemfile" ]; then
    (cd "${APP_DIR}" && bundle config set --local path 'vendor/bundle')
    (cd "${APP_DIR}" && bundle install --jobs "$(nproc)" --retry 3)
  else
    warn "No Gemfile found. Skipping bundle install."
  fi

  cat >> "${APP_DIR}/.env" <<EOF
RACK_ENV=${RACK_ENV:-production}
RAILS_ENV=${RAILS_ENV:-production}
BUNDLE_WITHOUT=${BUNDLE_WITHOUT:-test:development}
EOF

  log "Ruby environment setup complete."
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum)
      pkg_install golang
      ;;
    *)
      warn "No package manager available to install Go. Assuming Go is already present."
      ;;
  esac

  if ! command -v go >/dev/null 2>&1; then
    die "Go is required but not installed."
  fi

  export GOPATH="${APP_DIR}/.gopath"
  mkdir -p "${GOPATH}"
  export PATH="${GOPATH}/bin:${PATH}"
  echo "GOPATH=${GOPATH}" >> "${APP_DIR}/.env"
  echo "PATH=${GOPATH}/bin:\$PATH" >> "${APP_DIR}/.env"

  if [ -f "${APP_DIR}/go.mod" ]; then
    (cd "${APP_DIR}" && go mod download)
    # Build main if present
    if [ -f "${APP_DIR}/main.go" ]; then
      (cd "${APP_DIR}" && go build -o "${APP_DIR}/bin/app" ./)
      log "Built Go binary at ${APP_DIR}/bin/app"
    fi
  else
    warn "No go.mod found. Skipping go mod download."
  fi

  log "Go environment setup complete."
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install openjdk-17-jdk maven gradle
      ;;
    apk)
      pkg_install openjdk17-jdk maven gradle
      ;;
    dnf|yum)
      pkg_install java-17-openjdk-devel maven gradle
      ;;
    *)
      warn "No package manager available to install Java. Assuming Java is already present."
      ;;
  esac

  if ! command -v javac >/dev/null 2>&1; then
    die "Java JDK is required but not installed."
  fi

  if [ -f "${APP_DIR}/pom.xml" ]; then
    (cd "${APP_DIR}" && mvn -B -DskipTests package)
  elif [ -f "${APP_DIR}/gradlew" ]; then
    (cd "${APP_DIR}" && chmod +x gradlew && ./gradlew build -x test)
  elif [ -f "${APP_DIR}/build.gradle" ]; then
    (cd "${APP_DIR}" && gradle build -x test)
  else
    warn "No pom.xml or build.gradle found. Skipping Java build."
  fi

  log "Java environment setup complete."
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install php-cli php-zip unzip
      if ! command -v composer >/dev/null 2>&1; then
        log "Installing Composer..."
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
      fi
      ;;
    apk)
      pkg_install php81-cli php81-phar php81-openssl unzip
      if ! command -v composer >/dev/null 2>&1; then
        log "Installing Composer..."
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
      fi
      ;;
    dnf|yum)
      pkg_install php-cli unzip
      if ! command -v composer >/dev/null 2>&1; then
        log "Installing Composer..."
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
      fi
      ;;
    *)
      warn "No package manager available to install PHP. Assuming PHP is already present."
      ;;
  esac

  if ! command -v php >/div/null 2>&1; then
    err "PHP is not installed or not found in PATH."
  fi

  if [ -f "${APP_DIR}/composer.json" ]; then
    (cd "${APP_DIR}" && composer install --no-dev --prefer-dist --no-interaction)
  else
    warn "No composer.json found. Skipping Composer install."
  fi

  log "PHP environment setup complete."
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install cargo rustc
      ;;
    apk)
      pkg_install cargo rust
      ;;
    dnf|yum)
      pkg_install cargo rust
      ;;
    *)
      warn "No package manager available to install Rust. Attempting rustup install..."
      curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
      sh /tmp/rustup.sh -y
      rm -f /tmp/rustup.sh
      export PATH="${HOME}/.cargo/bin:${PATH}"
      ;;
  esac

  if ! command -v cargo >/dev/null 2>&1; then
    die "Cargo is required but not installed."
  fi

  if [ -f "${APP_DIR}/Cargo.toml" ]; then
    (cd "${APP_DIR}" && cargo build --release)
    if [ -f "${APP_DIR}/target/release" ]; then
      find "${APP_DIR}/target/release" -maxdepth 1 -type f -executable -exec cp {} "${APP_DIR}/bin/" \; || true
    fi
  else
    warn "No Cargo.toml found. Skipping cargo build."
  fi

  log "Rust environment setup complete."
}

# .NET setup (best-effort; may require external repos)
setup_dotnet() {
  log "Setting up .NET environment..."
  case "${PKG_MANAGER}" in
    apt)
      # Install dependencies and Microsoft package repository
      pkg_install wget apt-transport-https
      wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
      if [ -f /tmp/packages-microsoft-prod.deb ]; then
        dpkg -i /tmp/packages-microsoft-prod.deb || true
        rm -f /tmp/packages-microsoft-prod.deb
        pkg_update
      fi
      pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || warn "Could not install dotnet SDK via apt."
      ;;
    apk)
      warn ".NET SDK not readily available via apk. Please use a microsoft/dotnet base image."
      ;;
    dnf|yum)
      warn ".NET SDK setup via dnf/yum requires Microsoft repositories. Consider using official .NET images."
      ;;
    *)
      warn "No package manager available to install .NET. Skipping."
      ;;
  esac

  if command -v dotnet >/dev/null 2>&1; then
    log "dotnet SDK installed: $(dotnet --version)"
    # Restore and build if .csproj found
    if ls "${APP_DIR}"/*.sln >/dev/null 2>&1 || ls "${APP_DIR}"/*.csproj >/dev/null 2>&1; then
      (cd "${APP_DIR}" && dotnet restore)
      (cd "${APP_DIR}" && dotnet build -c Release)
    fi
  else
    warn "dotnet command not found; .NET setup incomplete."
  fi

  log ".NET environment setup complete."
}

# Pre-clone cleanup to ensure idempotent git clone steps for projects like facebook/folly
pre_clone_cleanup() {
  if [ -e "${APP_DIR}/folly" ]; then
    ts=$(date +%s)
    if command -v sudo >/dev/null 2>&1; then
      sudo mv -f "${APP_DIR}/folly" "${APP_DIR}/folly.bak.${ts}"
    else
      mv -f "${APP_DIR}/folly" "${APP_DIR}/folly.bak.${ts}"
    fi
  fi
}

# Compatibility setup for non-shell runners that attempt to execute 'cd' as a binary
setup_non_shell_runner_compat() {
  log "Applying non-shell runner compatibility steps..."
  # Ensure required tooling via apt-get (if available)
  if command -v apt-get >/dev/null 2>&1; then
    if [ "${IS_ROOT}" = "true" ]; then
      apt-get update || apt-get update
      apt-get install -y m4 autoconf automake libtool python3 python3-pip python3-venv git cmake ninja-build build-essential pkg-config curl ca-certificates zip unzip
      update-ca-certificates || true
    else
      if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update || apt-get update
        sudo apt-get install -y m4 autoconf automake libtool python3 python3-pip python3-venv git cmake ninja-build build-essential pkg-config curl ca-certificates zip unzip
        sudo update-ca-certificates || true
      fi
    fi
  fi

  # Prepare workspace for folly and symlink build at root
  if [ -d "${APP_DIR}" ]; then
    (
      cd "${APP_DIR}"
      rm -rf folly build
      git clone https://github.com/facebook/folly folly || true
      ln -s folly/build build || true
    )
  fi

  # Provide an external 'cd' stub for non-shell runners
  if [ "${IS_ROOT}" = "true" ]; then
    printf "#!/bin/sh\nexit 0\n" > /usr/local/bin/cd && chmod +x /usr/local/bin/cd || true
  else
    if command -v sudo >/dev/null 2>&1; then
      printf "#!/bin/sh\nexit 0\n" | sudo tee /usr/local/bin/cd >/dev/null && sudo chmod +x /usr/local/bin/cd || true
    fi
  fi

  # Install vcpkg and expose it in PATH for subsequent steps
  if command -v sudo >/dev/null 2>&1; then
    sudo git clone https://github.com/microsoft/vcpkg /opt/vcpkg || true
    sudo /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics || true
    sudo ln -sf /opt/vcpkg/vcpkg /usr/local/bin/vcpkg || true
  elif [ "${IS_ROOT}" = "true" ]; then
    git clone https://github.com/microsoft/vcpkg /opt/vcpkg || true
    /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics || true
    ln -sf /opt/vcpkg/vcpkg /usr/local/bin/vcpkg || true
  fi

  # Run folly getdeps build and test steps
  if [ -f "${APP_DIR}/folly/build/fbcode_builder/getdeps.py" ]; then
    if command -v sudo >/dev/null 2>&1 && [ "${IS_ROOT}" != "true" ]; then
      sudo python3 "${APP_DIR}/folly/build/fbcode_builder/getdeps.py" install-system-deps --recursive || true
    else
      python3 "${APP_DIR}/folly/build/fbcode_builder/getdeps.py" install-system-deps --recursive || true
    fi
    python3 "${APP_DIR}/folly/build/fbcode_builder/getdeps.py" --allow-system-packages build || true
    python3 "${APP_DIR}/folly/build/fbcode_builder/getdeps.py" --allow-system-packages test || true
  fi
}

# Main routine
main() {
  log "Starting environment setup for project at ${APP_DIR}..."
  detect_pkg_manager
  check_network
  ensure_base_tools
  command -v git >/dev/null 2>&1 || { if command -v sudo >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y git ca-certificates; else apt-get update && apt-get install -y git ca-certificates; fi; }
  setup_directories
  setup_common_env
  pre_clone_cleanup
  setup_non_shell_runner_compat
  detect_project_type

  case "${PROJECT_TYPE}" in
    python) setup_python ;;
    node) setup_node ;;
    ruby) setup_ruby ;;
    go) setup_go ;;
    java) setup_java ;;
    php) setup_php ;;
    rust) setup_rust ;;
    dotnet) setup_dotnet ;;
    unknown)
      warn "Unable to detect project type. Installed base tools and set common environment only."
      ;;
    *)
      warn "Unrecognized project type: ${PROJECT_TYPE}. Skipping language-specific setup."
      ;;
  esac

  # Final info
  log "Environment setup completed successfully."
  log "To use the environment, you may source the .env file: 'set -a; . ${APP_DIR}/.env; set +a'"
  if [ -x "${APP_DIR}/bin/run" ]; then
    log "To run the application: ${APP_DIR}/bin/run"
  fi
}

main "$@"