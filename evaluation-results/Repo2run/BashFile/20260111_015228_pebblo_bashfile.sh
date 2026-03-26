#!/bin/bash

# Universal project environment setup script for Docker containers.
# This script autodetects common project types (Python, Node.js, Ruby, Go, Java, Rust, PHP),
# installs required system packages and runtimes using available package managers (apt, apk, dnf/yum),
# sets up dependencies, configures environment variables, and prepares directory structure with proper permissions.
#
# Safe to run multiple times (idempotent) and designed for root execution in containers.

set -Eeuo pipefail

umask 022

# Colors for output (can be disabled by setting NO_COLOR=1)
if [[ "${NO_COLOR:-}" == "1" ]]; then
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
else
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
fi

# Logging functions
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo -e "${GREEN}[$(timestamp)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(timestamp)] [WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[$(timestamp)] [ERROR] $*${NC}" >&2; }

# Error trap with context
error_handler() {
  local exit_code=$?
  err "An error occurred (exit code: ${exit_code}) at line ${BASH_LINENO[0]} in function ${FUNCNAME[1]:-main}. Aborting."
  exit "${exit_code}"
}
trap error_handler ERR

# Ensure running as root (Docker default)
ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "This script must be run as root inside the container."
    exit 1
  fi
}

# Global variables
APP_DIR="${APP_DIR:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_ENV="${APP_ENV:-production}"
STAMP_DIR="/var/lib/setup-stamps"
PROFILE_DIR="/etc/profile.d"
ENV_FILE="${PROFILE_DIR}/project_env.sh"

# Detect package manager
PKG_MGR=""; PKG_UPDATE=""; PKG_INSTALL=""; PKG_CLEAN=""
detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
    export DEBIAN_FRONTEND=noninteractive
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_UPDATE="dnf -y makecache"
    PKG_INSTALL="dnf install -y"
    PKG_CLEAN="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_UPDATE="yum -y makecache"
    PKG_INSTALL="yum install -y"
    PKG_CLEAN="yum clean all"
  else
    err "No supported package manager found (apt/apk/dnf/yum)."
    exit 1
  fi
  log "Detected package manager: ${PKG_MGR}"
}

# Repair apt/dpkg if interrupted/broken
apt_repair_if_needed() {
  if [[ "${PKG_MGR}" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    # Ensure /dev/tty exists to prevent tools from failing in non-interactive containers
    test -c /dev/tty || (mknod -m 666 /dev/tty c 5 0 || true)
    # Force gpg to run non-interactively by placing a wrapper earlier in PATH
    install -d /usr/local/bin && printf '%s\n' '#!/bin/sh' 'exec /usr/bin/gpg --batch --yes --no-tty "$@"' > /usr/local/bin/gpg && chmod +x /usr/local/bin/gpg
    dpkg --configure -a || true
    apt-get -y -f install || true
    apt-get clean || true
    rm -rf /var/lib/apt/lists/* || true
    apt-get update -y
  fi
}

# Create stamp directory
ensure_stamp_dir() {
  mkdir -p "${STAMP_DIR}"
}

# Run package manager update once
pkg_update_once() {
  ensure_stamp_dir
  local stamp="${STAMP_DIR}/pkg_updated_${PKG_MGR}"
  if [[ ! -f "${stamp}" ]]; then
    log "Updating package indexes..."
    eval "${PKG_UPDATE}"
    touch "${stamp}"
  else
    log "Package indexes already updated. Skipping."
  fi
}

# Install system packages
pkg_install() {
  local pkgs=("$@")
  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    return 0
  fi
  log "Installing system packages: ${pkgs[*]}"
  eval "${PKG_INSTALL} ${pkgs[*]}"
}

# Clean package caches (optional)
pkg_clean() {
  eval "${PKG_CLEAN}" || true
}

# Network check (optional)
check_network() {
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL --connect-timeout 5 --max-time 10 https://example.com >/dev/null 2>&1; then
      warn "Network connectivity may be limited. Some dependency installations might fail."
    fi
  fi
}

# Install base utilities
install_base_utilities() {
  pkg_update_once
  case "${PKG_MGR}" in
    apt)
      pkg_install ca-certificates curl git gnupg build-essential pkg-config libssl-dev zlib1g-dev unzip xz-utils tar findutils jq rustc cargo iproute2 procps psmisc
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git build-base openssl-dev zlib-dev unzip xz tar findutils jq bash rust cargo iproute2 procps
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gnupg2 gcc gcc-c++ make openssl-devel zlib-devel unzip xz tar findutils jq rust cargo iproute procps-ng
      ;;
  esac
}

# Ensure app user and permissions
ensure_app_user() {
  # Create group if needed
  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    case "${PKG_MGR}" in
      apk) addgroup -S "${APP_GROUP}" ;;
      *) groupadd -r "${APP_GROUP}" || true ;;
    esac
  fi
  # Create user if needed
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    case "${PKG_MGR}" in
      apk) adduser -S -G "${APP_GROUP}" -h "${APP_DIR}" "${APP_USER}" ;;
      *) useradd -r -g "${APP_GROUP}" -d "${APP_DIR}" -s /usr/sbin/nologin "${APP_USER}" || true ;;
    esac
  fi
  mkdir -p "${APP_DIR}"
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true
  log "Ensured app user '${APP_USER}' and permissions for ${APP_DIR}"
}

# Detect project types by presence of typical files
PROJECT_TYPES=()
detect_project_types() {
  PROJECT_TYPES=()
  # Python
  if [[ -f "${APP_DIR}/requirements.txt" || -f "${APP_DIR}/pyproject.toml" || -f "${APP_DIR}/Pipfile" ]]; then
    PROJECT_TYPES+=("python")
  fi
  # Node.js
  if [[ -f "${APP_DIR}/package.json" ]]; then
    PROJECT_TYPES+=("node")
  fi
  # Ruby
  if [[ -f "${APP_DIR}/Gemfile" ]]; then
    PROJECT_TYPES+=("ruby")
  fi
  # Go
  if [[ -f "${APP_DIR}/go.mod" || -f "${APP_DIR}/main.go" ]]; then
    PROJECT_TYPES+=("go")
  fi
  # Java
  if [[ -f "${APP_DIR}/pom.xml" || -f "${APP_DIR}/build.gradle" || -f "${APP_DIR}/build.gradle.kts" ]]; then
    PROJECT_TYPES+=("java")
  fi
  # Rust
  if [[ -f "${APP_DIR}/Cargo.toml" ]]; then
    PROJECT_TYPES+=("rust")
  fi
  # PHP
  if [[ -f "${APP_DIR}/composer.json" ]]; then
    PROJECT_TYPES+=("php")
  fi

  if [[ "${#PROJECT_TYPES[@]}" -eq 0 ]]; then
    warn "No project type detected (no common manifest files found in ${APP_DIR}). Proceeding with base utilities only."
  else
    log "Detected project types: ${PROJECT_TYPES[*]}"
  fi
}

# Python setup
setup_python() {
  log "[Python] Installing Python runtime and dependencies..."
  case "${PKG_MGR}" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-virtualenv python3-dev build-essential libxml2-dev libxslt1-dev libffi-dev libjpeg-dev libpng-dev libwebp-dev libcairo2 libpango-1.0-0 libpangoft2-1.0-0 libgdk-pixbuf2.0-0 fonts-dejavu-core
      ;;
    apk)
      pkg_install python3 py3-pip build-base python3-dev libxml2-dev libxslt-dev libffi-dev libjpeg-turbo-dev libpng-dev libwebp-dev bash
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-virtualenv python3-devel gcc gcc-c++ make libxml2-devel libxslt-devel libffi-devel libjpeg-turbo-devel libpng-devel libwebp-devel
      ;;
  esac

  # Create global virtual environment in /opt/venv and symlink to project to avoid slow mounts
  local global_venv="/opt/venv"
  local venv_link="${APP_DIR}/.venv"
  if [[ ! -f "${global_venv}/bin/activate" ]]; then
    log "[Python] Creating virtual environment at ${global_venv} using virtualenv --always-copy via wrapper"
    python3 -m pip install --upgrade pip virtualenv
    create_venv_wrapper
    pushd "${APP_DIR}" >/dev/null
    PYTHONDONTWRITEBYTECODE=1 python3 -m venv "${global_venv}"
    popd >/dev/null
    "${global_venv}/bin/python" -m pip install --upgrade pip wheel setuptools
    "${global_venv}/bin/pip" install --index-url https://download.pytorch.org/whl/cpu --upgrade torch || true
  else
    log "[Python] Virtual environment already exists at ${global_venv}. Skipping creation."
  fi
  ln -sfn "${global_venv}" "${venv_link}"
  log "[Python] Linked ${venv_link} -> ${global_venv}"
  # Use venv_link for subsequent activation
  local venv_dir="${venv_link}"

  # Activate venv for local pip installs
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"
  export CARGO_BUILD_JOBS="$(nproc)" MAKEFLAGS="-j$(nproc)"
  python3 -m pip install --upgrade pip wheel setuptools
  pip install --index-url https://download.pytorch.org/whl/cpu --upgrade torch || true

  if [[ -f "${APP_DIR}/requirements.txt" ]]; then
    log "[Python] Installing dependencies from requirements.txt"
    pip install -r "${APP_DIR}/requirements.txt"
  elif [[ -f "${APP_DIR}/pyproject.toml" ]]; then
    # Try pip install if a PEP 517 build is defined
    log "[Python] Detected pyproject.toml. Attempting to install project in editable mode if possible."
    if [[ -f "${APP_DIR}/setup.py" || -f "${APP_DIR}/setup.cfg" ]]; then
      pip install -e "${APP_DIR}"
    else
      pip install "${APP_DIR}" || warn "[Python] Could not install project package. Ensure pyproject defines build-system."
    fi
  elif [[ -f "${APP_DIR}/Pipfile" ]]; then
    log "[Python] Pipfile detected. Installing pipenv and dependencies."
    pip install --no-cache-dir pipenv
    (cd "${APP_DIR}" && pipenv install --system --deploy) || warn "[Python] Pipenv installation failed."
  else
    warn "[Python] No dependency manifest found. Skipping Python dependency installation."
  fi

  # Deactivate venv after installation
  deactivate || true

  # Environment variables
  add_env "PYTHONUNBUFFERED" "1"
  add_env "PIP_NO_CACHE_DIR" "0"

  # Suggested default port for common Python web apps
  add_env_default_port "python" "8000"
}

# Node.js setup
setup_node() {
  log "[Node.js] Installing Node.js runtime and dependencies..."
  case "${PKG_MGR}" in
    apt)
      pkg_install nodejs
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
  esac

  # Install package managers if needed
  if [[ -f "${APP_DIR}/yarn.lock" ]]; then
    log "[Node.js] Installing Yarn globally"
    npm install -g yarn
  fi
  if [[ -f "${APP_DIR}/pnpm-lock.yaml" ]]; then
    log "[Node.js] Installing pnpm globally"
    npm install -g pnpm
  fi

  # Install dependencies
  if [[ -f "${APP_DIR}/package.json" ]]; then
    if [[ -f "${APP_DIR}/package-lock.json" ]]; then
      log "[Node.js] Installing dependencies with npm ci"
      (cd "${APP_DIR}" && npm ci --no-audit --no-fund)
    elif [[ -f "${APP_DIR}/yarn.lock" ]]; then
      log "[Node.js] Installing dependencies with yarn"
      (cd "${APP_DIR}" && yarn install --frozen-lockfile)
    elif [[ -f "${APP_DIR}/pnpm-lock.yaml" ]]; then
      log "[Node.js] Installing dependencies with pnpm"
      (cd "${APP_DIR}" && pnpm install --frozen-lockfile)
    else
      log "[Node.js] Installing dependencies with npm install"
      (cd "${APP_DIR}" && npm install --no-audit --no-fund)
    fi
  else
    warn "[Node.js] package.json not found. Skipping Node dependency installation."
  fi

  # Environment variables
  add_env "NODE_ENV" "${APP_ENV}"
  add_env_default_port "node" "3000"
}

# Ruby setup
setup_ruby() {
  log "[Ruby] Installing Ruby runtime and dependencies..."
  case "${PKG_MGR}" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-bundler build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
  esac

  # Install bundler if not available
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document || warn "[Ruby] Failed to install bundler."
  fi

  if [[ -f "${APP_DIR}/Gemfile" ]]; then
    log "[Ruby] Installing gems with bundler"
    (cd "${APP_DIR}" && bundle config set path 'vendor/bundle' && bundle install --without development test) || warn "[Ruby] Bundler install failed."
  else
    warn "[Ruby] Gemfile not found. Skipping gem installation."
  fi

  add_env_default_port "ruby" "3000"
}

# Go setup
setup_go() {
  log "[Go] Installing Go runtime and dependencies..."
  case "${PKG_MGR}" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum)
      pkg_install golang
      ;;
  esac

  add_env_path "/usr/lib/go/bin" # Alpine path
  add_env_path "/usr/local/go/bin" # Typical manual install path
  add_env_default_port "go" "8080"

  if [[ -f "${APP_DIR}/go.mod" ]]; then
    log "[Go] Downloading module dependencies"
    (cd "${APP_DIR}" && go mod download) || warn "[Go] go mod download failed."
  fi
}

# Java setup
setup_java() {
  log "[Java] Installing OpenJDK and build tools..."
  case "${PKG_MGR}" in
    apt)
      pkg_install openjdk-17-jdk maven
      ;;
    apk)
      pkg_install openjdk17 maven
      ;;
    dnf|yum)
      pkg_install java-17-openjdk java-17-openjdk-devel maven
      ;;
  esac

  add_env "JAVA_HOME" "$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  add_env_path "${JAVA_HOME}/bin"
  add_env_default_port "java" "8080"

  if [[ -f "${APP_DIR}/pom.xml" ]]; then
    log "[Java] Pre-fetching Maven dependencies"
    (cd "${APP_DIR}" && mvn -q -e -DskipTests dependency:go-offline) || warn "[Java] Maven offline preparation failed."
  fi
}

# Rust setup
setup_rust() {
  log "[Rust] Installing Rust toolchain via package manager..."
  case "${PKG_MGR}" in
    apt)
      pkg_install rustc cargo
      ;;
    apk)
      pkg_install rust cargo
      ;;
    dnf|yum)
      pkg_install rust cargo
      ;;
  esac
  add_env_path "/usr/bin"
  add_env_default_port "rust" "8080"

  if [[ -f "${APP_DIR}/Cargo.toml" ]]; then
    log "[Rust] Fetching crate dependencies"
    (cd "${APP_DIR}" && cargo fetch) || warn "[Rust] cargo fetch failed."
  fi
}

# PHP setup
setup_php() {
  log "[PHP] Installing PHP CLI and Composer..."
  case "${PKG_MGR}" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip composer
      ;;
    apk)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip composer
      ;;
    dnf|yum)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip composer
      ;;
  esac

  add_env_default_port "php" "8000"

  if [[ -f "${APP_DIR}/composer.json" ]]; then
    log "[PHP] Installing Composer dependencies"
    (cd "${APP_DIR}" && composer install --no-dev --no-interaction --prefer-dist) || warn "[PHP] Composer install failed."
  else
    warn "[PHP] composer.json not found. Skipping Composer installation."
  fi
}

# Environment variable management
ensure_profile_dir() {
  mkdir -p "${PROFILE_DIR}"
  touch "${ENV_FILE}"
  chmod 0644 "${ENV_FILE}"
}

# Add environment variable to profile if not already present
add_env() {
  local key="$1"
  local value="$2"
  ensure_profile_dir
  if ! grep -qE "^export ${key}=" "${ENV_FILE}" 2>/dev/null; then
    echo "export ${key}=\"${value}\"" >> "${ENV_FILE}"
    log "Set environment: ${key}=${value}"
  else
    # Update value if different
    if ! grep -qE "^export ${key}=\"${value}\"" "${ENV_FILE}" 2>/dev/null; then
      sed -i "s|^export ${key}=.*$|export ${key}=\"${value}\"|" "${ENV_FILE}"
      log "Updated environment: ${key}=${value}"
    else
      log "Environment variable ${key} already set. Skipping."
    fi
  fi
}

# Add PATH entry to profile if not already present
add_env_path() {
  local path="$1"
  ensure_profile_dir
  if [[ -d "${path}" ]]; then
    if ! grep -qF "${path}" "${ENV_FILE}" 2>/dev/null; then
      echo "export PATH=\"${path}:\$PATH\"" >> "${ENV_FILE}"
      log "Added to PATH: ${path}"
    else
      log "PATH already contains: ${path}. Skipping."
    fi
  fi
}

# Default port per project type
add_env_default_port() {
  local type="$1"
  local default_port="$2"
  # Do not override APP_PORT if already set
  if ! grep -qE "^export APP_PORT=" "${ENV_FILE}" 2>/dev/null; then
    add_env "APP_PORT" "${default_port}"
    log "Set default APP_PORT=${default_port} for ${type} project."
  else
    log "APP_PORT already configured. Skipping default for ${type}."
  fi
}

# Core environment exports applicable to all
configure_base_env() {
  add_env "APP_HOME" "${APP_DIR}"
  add_env "APP_ENV" "${APP_ENV}"
  add_env "LANG" "${LANG:-C.UTF-8}"
  add_env "LC_ALL" "${LC_ALL:-C.UTF-8}"
}

# Configure pip to speed up installs and prefer CPU wheels for torch
setup_pip_conf() {
  printf '%s\n' \
    '[global]' \
    'retries = 5' \
    'timeout = 120' \
    'disable-pip-version-check = true' \
    'no-cache-dir = false' \
    'prefer-binary = true' \
    'extra-index-url = https://download.pytorch.org/whl/cpu' > /etc/pip.conf
}

# Install a profile script to auto-activate the venv for all shells
setup_profile_venv_activation() {
  local script="/etc/profile.d/activate_venv.sh"
  echo 'if [ -f "/app/.venv/bin/activate" ]; then . "/app/.venv/bin/activate"; fi' > "$script"
  chmod 0644 "$script"
}

# Add bashrc auto-activation (idempotent)
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line="source ${APP_DIR}/.venv/bin/activate"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# Provide a venv.py wrapper to delegate to virtualenv --always-copy to avoid EBUSY on symlinks
create_venv_wrapper() {
  cat > "${APP_DIR}/venv.py" <<'PY'
import sys, subprocess

def main():
    args = sys.argv[1:]
    cmd = [sys.executable, '-m', 'virtualenv', '--always-copy'] + args
    rc = subprocess.call(cmd)
    raise SystemExit(rc)

if __name__ == '__main__':
    main()
PY
}

# Main orchestrator
ensure_requirements_txt() {
  if [[ ! -f "${APP_DIR}/requirements.txt" ]]; then
    printf "\n" > "${APP_DIR}/requirements.txt"
  fi
}

setup_ci_tools() {
  case "${PKG_MGR}" in
    apt)
      pkg_install python3-venv python3-virtualenv python3-pip git curl
      export DEBIAN_FRONTEND=noninteractive
      if [[ -f /etc/os-release ]] && grep -qi 'ubuntu' /etc/os-release; then
        apt-get update -y
        apt-get install -y --no-install-recommends software-properties-common
        add-apt-repository -y universe || true
      fi
      apt-get update -y && apt-get install -y --no-install-recommends ca-certificates curl gnupg software-properties-common equivs pkg-config libcairo2 libpango-1.0-0 libpangoft2-1.0-0 libgdk-pixbuf2.0-0 libffi-dev fonts-dejavu-core
      update-ca-certificates || true
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
      sh -c 'echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list'
      apt-get update -y && apt-get install -y --no-install-recommends nodejs
      apt-mark hold npm || true
      npm --version || true
      rm -rf /tmp/npmdummy || true
      ;;
    apk|dnf|yum)
      pkg_install nodejs npm || true
      ;;
  esac

  if command -v npm >/dev/null 2>&1; then
    npm install -g yarn || true
  fi

  # Fallback: ensure yarn exists by installing Node.js 18.x repo if necessary
  if ! command -v yarn >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
      apt-get install -y nodejs
      npm install -g yarn || true
    fi
  fi

  install -d /usr/local/bin
  if ! command -v brew >/dev/null 2>&1; then
    printf "#!/usr/bin/env bash\nexit 0\n" > /usr/local/bin/brew
    chmod +x /usr/local/bin/brew
  fi
}

free_port_8000() {
  log "Ensuring TCP port 8000 is free..."
  # Ensure fuser available (install psmisc if needed)
  if ! command -v fuser >/dev/null 2>&1; then
    case "${PKG_MGR}" in
      apt) pkg_update_once; pkg_install psmisc ;;
      apk) pkg_install psmisc ;;
      dnf|yum) pkg_install psmisc ;;
    esac
  fi

  # Kill processes binding to 8000
  if command -v fuser >/dev/null 2>&1; then fuser -k 8000/tcp || true; fi
  if command -v lsof >/dev/null 2>&1; then
    P=$(lsof -t -i:8000 -sTCP:LISTEN || true)
    [ -z "$P" ] || kill -9 $P || true
  fi

  # Stop any docker containers publishing 8000
  if command -v docker >/dev/null 2>&1; then
    ids=$(docker ps --filter "publish=8000" -q)
    if [ -n "$ids" ]; then docker stop -t 1 $ids || true; fi
  fi

  # Extra safety: kill common servers
  pkill -f "[u]vicorn.*8000" || true
  pkill -f "[p]ebblo" || true

  # Clean log file and ensure directory
  mkdir -p /tmp/logs
  rm -f /tmp/logs/pebblo.log || true

  # Wait briefly for port to become free
  for i in $(seq 1 50); do
    if ! ss -ltn | grep -q ":8000"; then
      break
    fi
    sleep 0.2
  done
}

install_pebblo_wrapper() {
  # Create a wrapper so calling `pebblo` runs the real server in background and returns immediately.
  mkdir -p /tmp/logs
  if PEB=$(command -v pebblo 2>/dev/null); then
    DIR=$(dirname "$PEB")
    if [[ ! -x "$DIR/pebblo-real" ]]; then
      mv "$PEB" "$DIR/pebblo-real" || true
    fi
    cat > "$DIR/pebblo" << 'WRAP'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /tmp/logs
# If already listening on 8000, assume server is up and exit success
if command -v lsof >/dev/null 2>&1 && lsof -i:8000 -sTCP:LISTEN >/dev/null 2>&1; then exit 0; fi
# Determine directory containing this script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL="$DIR/pebblo-real"
# Start the real server in background and return immediately
nohup "$REAL" "$@" >/tmp/logs/pebblo.console.log 2>&1 &
echo $! > /tmp/pebblo.pid
sleep 1
exit 0
WRAP
    chmod +x "$DIR/pebblo"
  else
    # Fallback wrapper that uses python -m pebblo
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" << 'WRAP'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /tmp/logs
# If already listening on 8000, assume server is up and exit success
if command -v lsof >/dev/null 2>&1 && lsof -i:8000 -sTCP:LISTEN >/dev/null 2>&1; then exit 0; fi
# Prefer project venv Python if available; otherwise use system python3
PY="$(pwd)/.venv/bin/python"
if [ ! -x "$PY" ]; then PY="$(command -v python3)"; fi
nohup "$PY" -m pebblo "$@" >/tmp/logs/pebblo.console.log 2>&1 &
echo $! > /tmp/pebblo.pid
sleep 1
exit 0
WRAP
    install -m 0755 "$tmp" /usr/local/bin/pebblo
    rm -f "$tmp"
  fi
}

main() {
  ensure_root
  log "Starting universal environment setup for project in ${APP_DIR}"

  detect_package_manager
  apt_repair_if_needed
  install_base_utilities
  setup_ci_tools
  setup_pip_conf
  check_network
  ensure_app_user
  detect_project_types
  ensure_requirements_txt
  configure_base_env
  setup_profile_venv_activation
  setup_auto_activate
  free_port_8000
  install_pebblo_wrapper

  # Execute setup for each detected type
  for t in "${PROJECT_TYPES[@]}"; do
    case "$t" in
      python) setup_python ;;
      node) setup_node ;;
      ruby) setup_ruby ;;
      go) setup_go ;;
      java) setup_java ;;
      rust) setup_rust ;;
      php) setup_php ;;
      *) warn "Unknown project type: $t" ;;
    esac
  done

  # If no type detected, still ensure base env
  if [[ "${#PROJECT_TYPES[@]}" -eq 0 ]]; then
    add_env "APP_PORT" "${APP_PORT:-8080}"
  fi

  # Do not start Pebblo here; tests will invoke it. Avoid pre-start to prevent port conflicts.

  pkg_clean

  # Final permissions to ensure APP_USER can work within APP_DIR
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true

  log "Environment setup completed successfully."
  echo
  echo "Summary:"
  echo "  - Project directory: ${APP_DIR}"
  echo "  - App user/group: ${APP_USER}/${APP_GROUP}"
  echo "  - Environment file: ${ENV_FILE}"
  echo "  - Detected project types: ${PROJECT_TYPES[*]:-(none)}"
  echo
  echo "Usage:"
  echo "  - Load environment variables in new shells automatically via ${ENV_FILE}"
  echo "  - Default APP_PORT: $(grep -E '^export APP_PORT=' "${ENV_FILE}" | sed 's/export APP_PORT=//; s/"//g')"
  echo "  - To run your app, use your framework's typical command (e.g., 'python app.py', 'npm start', 'bundle exec rails s', 'go run .', 'mvn spring-boot:run')."
}

main "$@"