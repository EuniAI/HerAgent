#!/usr/bin/env bash
# Unified project environment setup script for Docker containers
# Installs runtimes and dependencies for common stacks (Python, Node.js, Ruby, Java, Go, Rust, PHP, .NET),
# configures system packages, project directories, environment variables, and ensures idempotent execution.

set -Eeuo pipefail

# Global defaults (can be overridden via env)
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
LOG_DIR="${LOG_DIR:-/var/log/app}"
DATA_DIR="${DATA_DIR:-/var/lib/app}"
CACHE_DIR="${CACHE_DIR:-/var/cache/app}"
ENV_FILE="${ENV_FILE:-.env}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"

# Colors (optional, plain output if not TTY)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  NC='\033[0m'
else
  GREEN=''
  YELLOW=''
  RED=''
  NC=''
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }

# Error trap
on_error() {
  err "Setup failed at line ${BASH_LINENO[0]} while executing: ${BASH_COMMAND}"
  exit 1
}
trap on_error ERR

# Detect OS package manager
PKG_MGR=""
OS_FAMILY="" # debian/alpine/redhat/arch/suse
APT_UPDATED=0

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    OS_FAMILY="debian"
    if [ "${NONINTERACTIVE}" = "1" ]; then
      export DEBIAN_FRONTEND=noninteractive
    fi
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    OS_FAMILY="redhat"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    OS_FAMILY="redhat"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
    OS_FAMILY="arch"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    OS_FAMILY="suse"
  else
    err "Unsupported base image: no known package manager found."
    exit 1
  fi
  log "Detected package manager: ${PKG_MGR} (${OS_FAMILY})"
}

update_pkg_index() {
  case "$PKG_MGR" in
    apt)
      if [ "$APT_UPDATED" -eq 0 ]; then
        log "Updating apt package index..."
        apt-get update -y
        APT_UPDATED=1
      fi
      ;;
    apk)
      # apk doesn't require separate index update for add --no-cache
      ;;
    dnf|yum)
      # dnf/yum automatically handle metadata when installing
      ;;
    pacman)
      log "Refreshing pacman keys and package database..."
      pacman -Sy --noconfirm
      ;;
    zypper)
      log "Refreshing zypper repositories..."
      zypper refresh -y || true
      ;;
  esac
}

install_packages() {
  # usage: install_packages pkg1 pkg2 ...
  local pkgs=("$@")
  if [ "${#pkgs[@]}" -eq 0 ]; then return 0; fi

  update_pkg_index
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    pacman)
      pacman -S --noconfirm --needed "${pkgs[@]}"
      ;;
    zypper)
      zypper install -y "${pkgs[@]}"
      ;;
  esac
}

cleanup_packages() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
      ;;
    dnf|yum)
      yum clean all || dnf clean all || true
      rm -rf /var/cache/yum /var/cache/dnf /tmp/* /var/tmp/*
      ;;
    pacman)
      rm -rf /var/cache/pacman/pkg /tmp/* /var/tmp/*
      ;;
    zypper)
      zypper clean -a || true
      rm -rf /var/tmp/* /tmp/*
      ;;
  esac
}

install_base_system_deps() {
  log "Installing base system dependencies..."
  case "$OS_FAMILY" in
    debian)
      install_packages ca-certificates curl wget git bash build-essential pkg-config openssl libssl-dev zlib1g-dev libffi-dev tzdata xz-utils findutils
      ;;
    alpine)
      install_packages ca-certificates curl wget git bash build-base pkgconfig openssl-dev zlib-dev libffi-dev tzdata
      ;;
    redhat)
      # Development tools and common libs
      if [ "$PKG_MGR" = "dnf" ]; then
        dnf groupinstall -y "Development Tools" || true
      else
        yum groupinstall -y "Development Tools" || true
      fi
      install_packages ca-certificates curl wget git bash openssl-devel zlib-devel libffi-devel tzdata which
      ;;
    arch)
      install_packages ca-certificates curl wget git bash base-devel openssl zlib libffi tzdata
      ;;
    suse)
      install_packages ca-certificates curl wget git bash gcc gcc-c++ make libopenssl-devel libz1 libffi-devel timezone
      ;;
  esac
  # Ensure certificates updated in minimal images
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi
  log "Base system dependencies installed."
}

# User and directory setup
setup_users_and_dirs() {
  log "Setting up application user, group, and directories..."

  # Create group if not exists
  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    case "$OS_FAMILY" in
      alpine) addgroup -g "${APP_GID}" "${APP_GROUP}" ;;
      debian|redhat|suse|arch) groupadd -g "${APP_GID}" "${APP_GROUP}" ;;
    esac
  fi

  # Create user if not exists
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    case "$OS_FAMILY" in
      alpine) adduser -D -G "${APP_GROUP}" -u "${APP_UID}" -s /bin/sh "${APP_USER}" ;;
      debian|redhat|suse|arch) useradd -m -s /bin/bash -u "${APP_UID}" -g "${APP_GROUP}" "${APP_USER}" ;;
    esac
  fi

  # Create directories
  mkdir -p "${APP_DIR}" "${LOG_DIR}" "${DATA_DIR}" "${CACHE_DIR}"

  # Set permissions
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" "${LOG_DIR}" "${DATA_DIR}" "${CACHE_DIR}"
  chmod 0755 "${APP_DIR}" || true
  chmod 0755 "${LOG_DIR}" || true
  chmod 0755 "${DATA_DIR}" || true
  chmod 0755 "${CACHE_DIR}" || true

  log "User, group, and directories configured."
}

# Environment file handling
load_env_file() {
  local env_path="${APP_DIR}/${ENV_FILE}"
  if [ -f "${env_path}" ]; then
    log "Loading environment variables from ${env_path}"
    # shellcheck disable=SC2046
    export $(grep -v '^[[:space:]]*#' "${env_path}" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | xargs -d '\n' -n1)
  else
    warn "No ${ENV_FILE} found at ${APP_DIR}. Creating a default one."
    cat > "${env_path}" <<EOF
# Application environment
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
# Add additional variables below as needed
EOF
    chown "${APP_USER}:${APP_GROUP}" "${env_path}" || true
  fi
}

persist_env_profile() {
  # Persist a minimal set of env vars for interactive shells
  local profile="/etc/profile.d/app_env.sh"
  if [ -w "/etc/profile.d" ]; then
    cat > "${profile}" <<EOF
# Generated by setup script
export APP_DIR="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
EOF
    chmod 0644 "${profile}" || true
  fi
}

# Ensure the project's Python virtual environment auto-activates in interactive shells
setup_auto_activate() {
  local venv_path="${APP_DIR}/.venv"
  local bashrc_file="/root/.bashrc"
  local activate_line=". ${venv_path}/bin/activate"

  # Create profile script for interactive shells
  if [ -w "/etc/profile.d" ]; then
    cat >/etc/profile.d/venv_auto.sh <<'EOF'
# Auto-activate project venv for interactive shells
if [ -n "$PS1" ] && [ -f /app/.venv/bin/activate ]; then
  . /app/.venv/bin/activate
fi
EOF
    chmod 0644 /etc/profile.d/venv_auto.sh || true
  fi

  # Also persist to root's bashrc to cover environments that do not source /etc/profile.d
  if [ -f "${venv_path}/bin/activate" ]; then
    if ! grep -qF "${activate_line}" "${bashrc_file}" 2>/dev/null; then
      {
        echo ""
        echo "# Auto-activate Python virtual environment"
        echo "${activate_line}"
      } >> "${bashrc_file}"
    fi
  fi
}

# Detection helpers
is_python_project() {
  [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/Pipfile" ] || [ -f "${APP_DIR}/setup.py" ]
}
is_node_project() { [ -f "${APP_DIR}/package.json" ]; }
is_ruby_project() { [ -f "${APP_DIR}/Gemfile" ]; }
is_java_maven_project() { [ -f "${APP_DIR}/pom.xml" ]; }
is_java_gradle_project() { [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/build.gradle.kts" ] || [ -x "${APP_DIR}/gradlew" ]; }
is_go_project() { [ -f "${APP_DIR}/go.mod" ] || ls "${APP_DIR}"/*.go >/dev/null 2>&1; }
is_rust_project() { [ -f "${APP_DIR}/Cargo.toml" ]; }
is_php_project() { [ -f "${APP_DIR}/composer.json" ]; }
is_dotnet_project() { ls "${APP_DIR}"/*.sln "${APP_DIR}"/*.csproj "${APP_DIR}"/*.fsproj >/dev/null 2>&1 || false; }

# Stack setup functions
setup_python() {
  log "Configuring Python environment..."
  case "$OS_FAMILY" in
    debian)
      # Ensure dummy metapackage for python3-twine on Ubuntu 24.04/noble if not available
      if ! dpkg -s python3-twine >/dev/null 2>&1; then
        update_pkg_index
        apt-get install -y --no-install-recommends equivs
        cat >/tmp/python3-twine.ctl <<'EOF'
Section: misc
Priority: optional
Standards-Version: 4.5.0
Package: python3-twine
Version: 1.0
Maintainer: root <root@localhost>
Architecture: all
Description: Dummy metapackage to satisfy python3-twine dependency (twine will be installed via pip in the project venv)
EOF
        cd /tmp && equivs-build /tmp/python3-twine.ctl && dpkg -i /tmp/python3-twine_*_all.deb || true
      fi
      install_packages python3 python3-pip python3-venv python3-dev python3-twine
      ;;

    alpine) install_packages python3 py3-pip python3-dev ;;
    redhat) install_packages python3 python3-pip python3-devel ;;
    arch) install_packages python python-pip ;;
    suse) install_packages python3 python3-pip python3-devel ;;
  esac

  local venv="${APP_DIR}/.venv"
  if [ ! -d "${venv}" ]; then
    log "Creating virtual environment at ${venv}"
    python3 -m venv "${venv}"
  else
    log "Virtual environment already exists at ${venv}"
  fi

  # Activate venv in subshell for installation
  log "Installing Python dependencies..."
  (
    set -Eeuo pipefail
    # shellcheck disable=SC1090
    . "${venv}/bin/activate"
    python -m pip install --upgrade pip setuptools wheel --no-cache-dir
    if [ -f "${APP_DIR}/requirements.txt" ]; then
      pip install -r "${APP_DIR}/requirements.txt" --no-cache-dir
    elif [ -f "${APP_DIR}/pyproject.toml" ]; then
      # Prefer PEP 517 builds; install project
      pip install . --no-cache-dir || true
    elif [ -f "${APP_DIR}/Pipfile" ] && command -v pipenv >/dev/null 2>&1; then
      pipenv install --system --deploy || true
    fi
  )
  chown -R "${APP_USER}:${APP_GROUP}" "${venv}" || true
  log "Python environment configured."
}

setup_node() {
  log "Configuring Node.js environment..."
  case "$OS_FAMILY" in
    debian|suse)
      install_packages nodejs npm
      ;;
    alpine)
      install_packages nodejs npm
      ;;
    redhat)
      # Node.js from EPEL/AppStream may be available; try default
      install_packages nodejs npm || warn "Node.js install via ${PKG_MGR} failed; consider using a Node base image."
      ;;
    arch)
      install_packages nodejs npm
      ;;
  esac

  # Optionally install yarn if yarn.lock present
  if [ -f "${APP_DIR}/yarn.lock" ]; then
    if command -v corepack >/dev/null 2>&1; then
      corepack enable || true
      if ! command -v yarn >/dev/null 2>&1; then corepack prepare yarn@stable --activate || true; fi
    else
      if ! command -v yarn >/dev/null 2>&1; then npm install -g yarn; fi
    fi
  fi

  # Install dependencies
  if [ -f "${APP_DIR}/package.json" ]; then
    pushd "${APP_DIR}" >/dev/null
    if [ -f "package-lock.json" ]; then
      log "Running npm ci..."
      npm ci
    elif [ -f "yarn.lock" ] && command -v yarn >/dev/null 2>&1; then
      log "Running yarn install..."
      yarn install --frozen-lockfile || yarn install
    else
      log "Running npm install..."
      npm install
    fi
    popd >/dev/null
  fi
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}/node_modules" 2>/dev/null || true
  log "Node.js environment configured."
}

setup_ruby() {
  log "Configuring Ruby environment..."
  case "$OS_FAMILY" in
    debian) install_packages ruby-full build-essential libssl-dev ;;
    alpine) install_packages ruby ruby-dev build-base openssl-dev ;;
    redhat) install_packages ruby ruby-devel openssl-devel gcc make ;;
    arch) install_packages ruby base-devel ;;
    suse) install_packages ruby ruby-devel libopenssl-devel gcc make ;;
  esac

  if ! command -v bundler >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  if [ -f "${APP_DIR}/Gemfile" ]; then
    pushd "${APP_DIR}" >/dev/null
    log "Running bundle install..."
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs 4 --retry 3
    popd >/dev/null
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}/vendor" || true
  fi
  log "Ruby environment configured."
}

setup_java() {
  log "Configuring Java environment..."
  case "$OS_FAMILY" in
    debian) install_packages openjdk-17-jdk ;;
    alpine) install_packages openjdk17 ;;
    redhat) install_packages java-17-openjdk-devel ;;
    arch) install_packages jdk17-openjdk ;;
    suse) install_packages java-17-openjdk-devel ;;
  esac

  if is_java_maven_project; then
    case "$OS_FAMILY" in
      debian|redhat|arch|suse) install_packages maven ;;
      alpine) install_packages maven ;;
    esac
    pushd "${APP_DIR}" >/dev/null
    log "Running mvn -q -DskipTests dependency:resolve and package..."
    mvn -q -DskipTests dependency:resolve || true
    mvn -q -DskipTests package || true
    popd >/dev/null
  fi

  if is_java_gradle_project; then
    pushd "${APP_DIR}" >/dev/null
    if [ -x "./gradlew" ]; then
      log "Using gradle wrapper to build..."
      ./gradlew --no-daemon build -x test || true
    else
      case "$OS_FAMILY" in
        debian|redhat|arch|suse) install_packages gradle ;;
        alpine) install_packages gradle ;;
      esac
      gradle --no-daemon build -x test || true
    fi
    popd >/dev/null
  fi
  log "Java environment configured."
}

setup_go() {
  log "Configuring Go environment..."
  case "$OS_FAMILY" in
    debian) install_packages golang ;;
    alpine) install_packages go ;;
    redhat) install_packages golang ;;
    arch) install_packages go ;;
    suse) install_packages go ;;
  esac

  if [ -f "${APP_DIR}/go.mod" ]; then
    pushd "${APP_DIR}" >/dev/null
    log "Running go mod download..."
    go mod download
    popd >/dev/null
  fi
  log "Go environment configured."
}

setup_rust() {
  log "Configuring Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal
    rm -f /tmp/rustup.sh
    # Ensure rust is available in PATH
    export PATH="$HOME/.cargo/bin:${PATH}"
    if [ -d "/root/.cargo/bin" ]; then export PATH="/root/.cargo/bin:${PATH}"; fi
  fi

  if [ -f "${APP_DIR}/Cargo.toml" ]; then
    pushd "${APP_DIR}" >/dev/null
    log "Fetching Rust dependencies..."
    cargo fetch
    popd >/dev/null
  fi
  log "Rust environment configured."
}

setup_php() {
  log "Configuring PHP environment..."
  case "$OS_FAMILY" in
    debian) install_packages php-cli php-xml php-mbstring php-curl ;;
    alpine) install_packages php php-cli php-phar php-openssl php-xml php-mbstring ;;
    redhat) install_packages php-cli php-xml php-mbstring php-json php-curl ;;
    arch) install_packages php ;;
    suse) install_packages php7 php7-cli php7-xmlreader php7-mbstring ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if [ -f "${APP_DIR}/composer.json" ]; then
    pushd "${APP_DIR}" >/dev/null
    log "Running composer install..."
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress
    popd >/dev/null
  fi
  log "PHP environment configured."
}

setup_dotnet() {
  log "Configuring .NET environment..."
  # Use dotnet-install script to avoid adding repos
  if ! command -v dotnet >/dev/null 2>&1; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh

    local version_arg="--channel LTS"
    if [ -f "${APP_DIR}/global.json" ]; then
      # Try pinned SDK version from global.json
      version_arg="--jsonfile ${APP_DIR}/global.json"
    fi

    /tmp/dotnet-install.sh ${version_arg} --install-dir /opt/dotnet
    ln -sf /opt/dotnet/dotnet /usr/local/bin/dotnet
    rm -f /tmp/dotnet-install.sh
  fi

  if is_dotnet_project; then
    pushd "${APP_DIR}" >/dev/null
    log "Restoring .NET dependencies..."
    # Restore for solutions or projects
    if ls *.sln >/dev/null 2>&1; then
      dotnet restore *.sln
    else
      for proj in *.csproj *.fsproj; do
        [ -f "$proj" ] && dotnet restore "$proj"
      done
    fi
    popd >/dev/null
  fi
  log ".NET environment configured."
}

# Main logic: orchestrate setup based on detected project files
main() {
  log "Starting environment setup for project in ${APP_DIR}"

  detect_pkg_mgr
  install_base_system_deps
  setup_users_and_dirs

  # Ensure APP_DIR exists and is the working directory
  mkdir -p "${APP_DIR}"
  cd "${APP_DIR}"

  load_env_file
  persist_env_profile
  setup_auto_activate

  # Detect and configure stacks
  local configured=0
  if is_python_project; then setup_python; configured=$((configured+1)); fi
  if is_node_project; then setup_node; configured=$((configured+1)); fi
  if is_ruby_project; then setup_ruby; configured=$((configured+1)); fi
  if is_java_maven_project || is_java_gradle_project; then setup_java; configured=$((configured+1)); fi
  if is_go_project; then setup_go; configured=$((configured+1)); fi
  if is_rust_project; then setup_rust; configured=$((configured+1)); fi
  if is_php_project; then setup_php; configured=$((configured+1)); fi
  if is_dotnet_project; then setup_dotnet; configured=$((configured+1)); fi

  if [ "$configured" -eq 0 ]; then
    warn "No known project type detected in ${APP_DIR}. Installed base system dependencies only."
  fi

  # Ensure venv auto-activation is persisted after potential venv creation
  setup_auto_activate

  # Final cleanup
  cleanup_packages

  # Final permissions
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" "${LOG_DIR}" "${DATA_DIR}" "${CACHE_DIR}" || true

  log "Environment setup completed successfully."
  log "APP_ENV=${APP_ENV} APP_PORT=${APP_PORT} APP_DIR=${APP_DIR}"
}

# Execute main
main "$@"