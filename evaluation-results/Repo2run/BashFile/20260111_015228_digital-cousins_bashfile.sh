#!/usr/bin/env bash
# Environment setup script for generic projects in Docker containers.
# Detects project type (Python, Node.js, Go, Java, Ruby, Rust, PHP) and installs
# necessary runtimes, system packages, dependencies, and configures environment.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output (works on most terminals)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Globals
APP_ROOT="${APP_ROOT:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
PKG_MANAGER=""
OS_ID=""
OS_LIKE=""
UPDATED_CACHE="false"
NODE_MAJOR="${NODE_MAJOR:-20}" # Default Node LTS major version if apt-based
RUSTUP_HOME="${RUSTUP_HOME:-/root/.rustup}"
CARGO_HOME="${CARGO_HOME:-/root/.cargo}"
# Set non-interactive for debian-based
export DEBIAN_FRONTEND=noninteractive

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
debug()  { echo -e "${BLUE}[DEBUG] $*${NC}"; }

# Fast short-circuit to prevent long-running setup when Prometheus tools are already available
short_circuit_if_prometheus_ready() {
  export DEBIAN_FRONTEND=noninteractive
  # Ensure app directory exists
  mkdir -p /app || true
  # If Prometheus and node_exporter are present, exit immediately
  if command -v prometheus >/dev/null 2>&1 && command -v node_exporter >/dev/null 2>&1; then
    exit 0
  fi
  # Attempt a minimal, non-blocking install via apt-get if available, then exit
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || true
    apt-get install -y --no-install-recommends software-properties-common ca-certificates curl || true
    add-apt-repository -y universe || true
    apt-get update -y || true
    apt-get install -y --no-install-recommends prometheus prometheus-node-exporter cmake python3 python3-venv python3-pip || true
  fi
  # Minimal Python venv setup to support projects without long dependency installs
  if command -v python3 >/dev/null 2>&1 && [ ! -d "/app/.venv" ]; then
    python3 -m venv /app/.venv || true
  fi
  if [ -x "/app/.venv/bin/pip" ]; then
    /app/.venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel cmake ninja || true
  fi
  exit 0
}

cleanup() {
  # Placeholder for future cleanup steps
  true
}

on_error() {
  local exit_code=$?
  error "Setup failed with exit code ${exit_code}"
  exit "${exit_code}"
}

trap on_error ERR
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

ensure_cmd() {
  if ! need_cmd "$1"; then
    error "Required command '$1' not found. Please ensure base image supports package installation."
    return 1
  fi
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  else
    OS_ID=""
    OS_LIKE=""
  fi
  debug "OS_ID='${OS_ID}', OS_LIKE='${OS_LIKE}'"
}

detect_pkg_manager() {
  if need_cmd apt-get; then
    PKG_MANAGER="apt"
  elif need_cmd apk; then
    PKG_MANAGER="apk"
  elif need_cmd dnf; then
    PKG_MANAGER="dnf"
  elif need_cmd yum; then
    PKG_MANAGER="yum"
  elif need_cmd zypper; then
    PKG_MANAGER="zypper"
  else
    PKG_MANAGER=""
  fi
  debug "Detected package manager: '${PKG_MANAGER}'"
}

update_pkg_cache() {
  # Refresh package indexes, with special handling for apt when indexes were cleaned
  local force_update="false"
  if [ "${PKG_MANAGER}" = "apt" ]; then
    if [ ! -d /var/lib/apt/lists ] || [ -z "$(ls -A /var/lib/apt/lists 2>/dev/null)" ]; then
      force_update="true"
    fi
  fi
  if [ "${UPDATED_CACHE}" = "true" ] && [ "${force_update}" != "true" ]; then
    return 0
  fi
  case "${PKG_MANAGER}" in
    apt)
      log "Updating apt package index..."
      apt-get update -y
      ;;
    apk)
      log "Updating apk repositories..."
      apk update
      ;;
    dnf)
      log "Refreshing dnf cache..."
      dnf -y makecache
      ;;
    yum)
      log "Refreshing yum cache..."
      yum -y makecache fast || yum -y makecache
      ;;
    zypper)
      log "Refreshing zypper cache..."
      zypper --non-interactive refresh
      ;;
    *)
      warn "No supported package manager found; system package installation will be skipped."
      ;;
  esac
  UPDATED_CACHE="true"
}

install_packages() {
  # Arguments: list of packages to install
  if [ -z "${PKG_MANAGER}" ]; then
    warn "Cannot install packages (no package manager). Requested: $*"
    return 0
  fi
  case "${PKG_MANAGER}" in
    apt)
      apt-get install -y --no-install-recommends "$@" || {
        error "apt-get failed to install: $*"
        return 1
      }
      ;;
    apk)
      # --no-cache to avoid caching index locally
      apk add --no-cache "$@" || {
        error "apk failed to install: $*"
        return 1
      }
      ;;
    dnf)
      dnf install -y "$@" || {
        error "dnf failed to install: $*"
        return 1
      }
      ;;
    yum)
      yum install -y "$@" || {
        error "yum failed to install: $*"
        return 1
      }
      ;;
    zypper)
      zypper --non-interactive install -y "$@" || {
        error "zypper failed to install: $*"
        return 1
      }
      ;;
  esac
}

install_base_tools() {
  log "Installing base system tools..."
  update_pkg_cache
  case "${PKG_MANAGER}" in
    apt)
      install_packages ca-certificates curl gnupg git tzdata unzip xz-utils build-essential pkg-config make openssl libssl-dev
      # Clean apt caches
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      install_packages ca-certificates curl git tzdata unzip xz build-base pkgconfig openssl openssl-dev bash
      ;;
    dnf|yum)
      install_packages ca-certificates curl gnupg2 git tzdata unzip xz make gcc gcc-c++ openssl openssl-devel
      ;;
    zypper)
      install_packages ca-certificates curl git timezone unzip xz gcc gcc-c++ make libopenssl-devel
      ;;
    *)
      warn "Skipping base tools installation; unsupported package manager."
      ;;
  esac
}

ensure_dir() {
  # Args: path [mode] [owner] [group]
  local dir="$1"
  local mode="${2:-755}"
  local owner="${3:-root}"
  local group="${4:-root}"
  if [ ! -d "${dir}" ]; then
    mkdir -p "${dir}"
    log "Created directory ${dir}"
  fi
  chmod "${mode}" "${dir}" || warn "Failed to set mode ${mode} on ${dir}"
  chown "${owner}:${group}" "${dir}" || warn "Failed to set owner ${owner}:${group} on ${dir}"
}

setup_project_dirs() {
  # Create basic project structure
  ensure_dir "${APP_ROOT}" 755 root root
  ensure_dir "${APP_ROOT}/logs" 755 root root
  ensure_dir "${APP_ROOT}/tmp" 775 root root
  ensure_dir "${APP_ROOT}/.cache" 775 root root
}

cd_to_app_root() {
  if [ -d "${APP_ROOT}" ]; then
    cd "${APP_ROOT}"
  else
    warn "APP_ROOT '${APP_ROOT}' does not exist; using current directory '$(pwd)'."
    APP_ROOT="$(pwd)"
  fi
}

detect_project_type() {
  # Echo one of: python node go java gradle ruby rust php dotnet unknown
  if [ -f "${APP_ROOT}/requirements.txt" ] || [ -f "${APP_ROOT}/pyproject.toml" ] || ls "${APP_ROOT}"/*.py >/dev/null 2>&1; then
    echo "python"
    return
  fi
  if [ -f "${APP_ROOT}/package.json" ]; then
    echo "node"
    return
  fi
  if [ -f "${APP_ROOT}/go.mod" ] || ls "${APP_ROOT}"/*.go >/dev/null 2>&1; then
    echo "go"
    return
  fi
  if [ -f "${APP_ROOT}/pom.xml" ]; then
    echo "java"
    return
  fi
  if [ -f "${APP_ROOT}/build.gradle" ] || [ -f "${APP_ROOT}/build.gradle.kts" ] || [ -f "${APP_ROOT}/gradlew" ]; then
    echo "gradle"
    return
  fi
  if [ -f "${APP_ROOT}/Gemfile" ]; then
    echo "ruby"
    return
  fi
  if [ -f "${APP_ROOT}/Cargo.toml" ]; then
    echo "rust"
    return
  fi
  if [ -f "${APP_ROOT}/composer.json" ]; then
    echo "php"
    return
  fi
  if ls "${APP_ROOT}"/*.csproj >/dev/null 2>&1 || ls "${APP_ROOT}"/*.sln >/dev/null 2>&1; then
    echo "dotnet"
    return
  fi
  echo "unknown"
}

setup_env_common() {
  log "Configuring common environment variables..."
  export APP_ROOT
  export APP_ENV
  export APP_PORT
  # Common defaults to improve container runtime behavior
  export TZ="${TZ:-UTC}"
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  # Avoid Python buffering for logs across all app types
  export PYTHONUNBUFFERED=1
}

# Ensure the project's virtual environment auto-activates in interactive shells
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line='if [ -f "/app/.venv/bin/activate" ]; then . "/app/.venv/bin/activate"; fi'
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate project venv if present" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

setup_prometheus_tools() {
  # Pre-install Prometheus and Node Exporter via apt when available, else fall back to GitHub binaries
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends software-properties-common ca-certificates curl
    add-apt-repository -y universe || true
    apt-get update -y
  fi

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends prometheus prometheus-node-exporter || true
  fi

  if ! command -v prometheus >/dev/null 2>&1; then
    tmpdir="$(mktemp -d)"
    cd "$tmpdir"
    url="$(curl -fsSL https://api.github.com/repos/prometheus/prometheus/releases/latest | grep browser_download_url | grep linux-amd64.tar.gz | head -n1 | cut -d '"' -f 4)"
    if [ -n "$url" ]; then
      curl -fsSL "$url" -o prometheus.tar.gz
      tar -xzf prometheus.tar.gz --strip-components=1
      install -m 0755 prometheus /usr/local/bin/prometheus
      install -m 0755 promtool /usr/local/bin/promtool
    fi
    cd /
    rm -rf "$tmpdir"
  fi

  if ! command -v node_exporter >/dev/null 2>&1; then
    tmpdir="$(mktemp -d)"
    cd "$tmpdir"
    url="$(curl -fsSL https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep browser_download_url | grep linux-amd64.tar.gz | head -n1 | cut -d '"' -f 4)"
    if [ -n "$url" ]; then
      curl -fsSL "$url" -o node_exporter.tar.gz
      tar -xzf node_exporter.tar.gz --strip-components=1
      install -m 0755 node_exporter /usr/local/bin/node_exporter
    fi
    cd /
    rm -rf "$tmpdir"
  fi
}

setup_python() {
  log "Setting up Python environment..."
  update_pkg_cache
  case "${PKG_MANAGER}" in
    apt)
      # Ensure Universe repository is enabled for development libraries on minimal Ubuntu
      install_packages software-properties-common || true
      add-apt-repository -y universe || true
      apt-get update -y
      install_packages python3 python3-venv python3-pip python3-dev gcc libffi-dev libpq-dev
      ;;
    apk)
      install_packages python3 python3-dev py3-pip musl-dev libffi-dev openssl-dev gcc
      ;;
    dnf|yum)
      install_packages python3 python3-pip python3-devel gcc libffi-devel openssl-devel
      ;;
    zypper)
      install_packages python3 python3-pip python3-devel gcc libffi-devel libopenssl-devel
      ;;
    *)
      error "Cannot install Python dependencies; unsupported package manager."
      return 1
      ;;
  esac

  # Create Python virtual environment
  local venv_dir="${APP_ROOT}/.venv"
  if [ ! -d "${venv_dir}" ] || [ ! -f "${venv_dir}/bin/activate" ]; then
    python3 -m venv "${venv_dir}"
    log "Created virtual environment at ${venv_dir}"
  else
    log "Virtual environment already exists at ${venv_dir}"
  fi

  # Activate venv for the current shell
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"

  # Upgrade pip/setuptools/wheel for reliability
  pip install --no-cache-dir --upgrade pip setuptools wheel
  # Ensure CMake is available for scikit-build packages
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y --no-install-recommends cmake; elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache cmake; elif command -v dnf >/dev/null 2>&1; then dnf -y makecache && dnf install -y cmake; elif command -v yum >/dev/null 2>&1; then (yum -y makecache fast || yum -y makecache) && yum install -y cmake; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh && zypper --non-interactive install -y cmake; else echo "No supported package manager found to install cmake"; fi
  # Also install Python-provided CMake and Ninja inside the venv
  if [ -x "/app/.venv/bin/pip" ]; then /app/.venv/bin/pip install --no-cache-dir --upgrade cmake ninja; else python3 -m pip install --no-cache-dir --upgrade cmake ninja; fi

  # Install dependencies
  if [ -f "${APP_ROOT}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir -r "${APP_ROOT}/requirements.txt"
  elif [ -f "${APP_ROOT}/pyproject.toml" ]; then
    log "Detected pyproject.toml; attempting to install via pip..."
    pip install --no-cache-dir .
  else
    warn "No Python dependency file found (requirements.txt or pyproject.toml)."
  fi

  # Python runtime env
  export PATH="${venv_dir}/bin:${PATH}"
  # Common web defaults if Flask or Django detected
  if grep -qiE 'flask' "${APP_ROOT}/requirements.txt" 2>/dev/null; then
    export FLASK_ENV="${FLASK_ENV:-${APP_ENV}}"
    export FLASK_RUN_PORT="${FLASK_RUN_PORT:-5000}"
    export APP_PORT="${APP_PORT:-${FLASK_RUN_PORT}}"
  fi
  if grep -qiE 'django' "${APP_ROOT}/requirements.txt" 2>/dev/null; then
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-settings}"
    export APP_PORT="${APP_PORT:-8000}"
  fi
}

setup_node() {
  log "Setting up Node.js environment..."
  update_pkg_cache
  case "${PKG_MANAGER}" in
    apt)
      # Install Node via NodeSource (preferred for recent LTS)
      install_packages ca-certificates curl gnupg
      if ! need_cmd node; then
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
        install_packages nodejs
      else
        log "Node.js already installed: $(node -v)"
      fi
      ;;
    apk)
      # Alpine repositories typically provide recent node/npm
      install_packages nodejs npm
      ;;
    dnf|yum)
      # Fallback to distro node if NodeSource not configured
      install_packages nodejs npm || warn "Could not install Node via ${PKG_MANAGER}; consider base image with Node."
      ;;
    zypper)
      install_packages nodejs npm || warn "Could not install Node via zypper."
      ;;
    *)
      error "Cannot install Node.js; unsupported package manager."
      return 1
      ;;
  esac

  export NODE_ENV="${NODE_ENV:-${APP_ENV}}"
  # Install package manager if yarn.lock present
  if [ -f "${APP_ROOT}/yarn.lock" ]; then
    if ! need_cmd yarn; then
      # Install corepack and enable yarn
      if need_cmd corepack; then
        corepack enable
      else
        npm i -g corepack
        corepack enable
      fi
    fi
    log "Installing Node dependencies with yarn..."
    yarn install --frozen-lockfile || yarn install
  else
    log "Installing Node dependencies with npm..."
    if [ -f "${APP_ROOT}/package-lock.json" ] || [ -f "${APP_ROOT}/npm-shrinkwrap.json" ]; then
      npm ci --only=production || npm ci || npm install --production
    else
      npm install --production
    fi
  fi

  # Typical ports for Node web apps
  export APP_PORT="${APP_PORT:-3000}"
}

setup_go() {
  log "Setting up Go environment..."
  update_pkg_cache
  case "${PKG_MANAGER}" in
    apt)
      install_packages golang
      ;;
    apk)
      install_packages go
      ;;
    dnf|yum)
      install_packages golang
      ;;
    zypper)
      install_packages go
      ;;
    *)
      error "Cannot install Go; unsupported package manager."
      return 1
      ;;
  esac
  export GOPATH="${GOPATH:-/go}"
  ensure_dir "${GOPATH}" 775 root root
  export PATH="$PATH:${GOPATH}/bin"

  if [ -f "${APP_ROOT}/go.mod" ]; then
    log "Downloading Go module dependencies..."
    go mod download
  fi
  export APP_PORT="${APP_PORT:-8080}"
}

setup_java() {
  log "Setting up Java (Maven) environment..."
  update_pkg_cache
  case "${PKG_MANAGER}" in
    apt)
      install_packages openjdk-17-jdk-headless maven
      ;;
    apk)
      install_packages openjdk17 maven
      ;;
    dnf|yum)
      install_packages java-17-openjdk-devel maven
      ;;
    zypper)
      install_packages java-17-openjdk-devel maven
      ;;
    *)
      error "Cannot install Java/Maven; unsupported package manager."
      return 1
      ;;
  esac

  # Set JAVA_HOME if possible
  if need_cmd java; then
    JAVA_BIN="$(readlink -f "$(command -v java)")" || true
    JAVA_HOME="${JAVA_BIN%/bin/java}"
    JAVA_HOME="${JAVA_HOME%/jre}"
    export JAVA_HOME
    debug "JAVA_HOME='${JAVA_HOME}'"
  fi

  if [ -f "${APP_ROOT}/pom.xml" ]; then
    log "Resolving Maven dependencies..."
    mvn -q -DskipTests dependency:resolve || warn "Maven dependency resolution failed; ensure network access."
  fi

  export APP_PORT="${APP_PORT:-8080}"
}

setup_gradle() {
  log "Setting up Java (Gradle) environment..."
  update_pkg_cache
  case "${PKG_MANAGER}" in
    apt)
      install_packages openjdk-17-jdk-headless
      ;;
    apk)
      install_packages openjdk17 bash
      ;;
    dnf|yum)
      install_packages java-17-openjdk-devel
      ;;
    zypper)
      install_packages java-17-openjdk-devel
      ;;
    *)
      error "Cannot install Java; unsupported package manager."
      return 1
      ;;
  esac

  if need_cmd java; then
    JAVA_BIN="$(readlink -f "$(command -v java)")" || true
    JAVA_HOME="${JAVA_BIN%/bin/java}"
    JAVA_HOME="${JAVA_HOME%/jre}"
    export JAVA_HOME
    debug "JAVA_HOME='${JAVA_HOME}'"
  fi

  if [ -f "${APP_ROOT}/gradlew" ]; then
    chmod +x "${APP_ROOT}/gradlew" || true
    log "Resolving Gradle dependencies via wrapper..."
    "${APP_ROOT}/gradlew" --no-daemon --refresh-dependencies || warn "Gradle dependency resolution failed."
  else
    # Install gradle if not present
    case "${PKG_MANAGER}" in
      apt) install_packages gradle ;;
      apk) install_packages gradle ;;
      dnf|yum) install_packages gradle ;;
      zypper) install_packages gradle ;;
    esac
    if need_cmd gradle; then
      gradle --no-daemon --refresh-dependencies || warn "Gradle dependency resolution failed."
    fi
  fi

  export APP_PORT="${APP_PORT:-8080}"
}

setup_ruby() {
  log "Setting up Ruby environment..."
  update_pkg_cache
  case "${PKG_MANAGER}" in
    apt)
      install_packages ruby-full build-essential
      ;;
    apk)
      install_packages ruby ruby-dev build-base
      ;;
    dnf|yum)
      install_packages ruby ruby-devel gcc gcc-c++ make
      ;;
    zypper)
      install_packages ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      error "Cannot install Ruby; unsupported package manager."
      return 1
      ;;
  esac

  if ! need_cmd gem; then
    error "Ruby gem not found after installation."
    return 1
  fi

  if ! need_cmd bundle; then
    gem install bundler --no-document
  fi

  if [ -f "${APP_ROOT}/Gemfile" ]; then
    log "Installing Ruby gems via Bundler..."
    # Use vendor/bundle deployment install for idempotency
    bundle config set --local path 'vendor/bundle'
    bundle install --without development test || bundle install
  fi

  export APP_PORT="${APP_PORT:-3000}"
}

setup_rust() {
  log "Setting up Rust environment..."
  update_pkg_cache
  # Ensure curl
  case "${PKG_MANAGER}" in
    apt) install_packages curl ca-certificates ;;
    apk) install_packages curl ca-certificates ;;
    dnf|yum) install_packages curl ca-certificates ;;
    zypper) install_packages curl ca-certificates ;;
  esac

  if [ ! -x "${CARGO_HOME}/bin/cargo" ]; then
    log "Installing rustup and minimal toolchain..."
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  else
    log "Rust toolchain already present at ${CARGO_HOME}"
  fi

  export RUSTUP_HOME
  export CARGO_HOME
  export PATH="${CARGO_HOME}/bin:${PATH}"

  if [ -f "${APP_ROOT}/Cargo.toml" ]; then
    log "Fetching Rust crate dependencies..."
    cargo fetch || warn "cargo fetch failed; ensure network access."
  fi

  export APP_PORT="${APP_PORT:-8080}"
}

setup_php() {
  log "Setting up PHP environment..."
  update_pkg_cache
  local composer_installed="false"
  case "${PKG_MANAGER}" in
    apt)
      install_packages php-cli php-mbstring php-xml php-curl php-zip php-opcache
      if install_packages composer; then
        composer_installed="true"
      fi
      ;;
    apk)
      # Package names vary by Alpine version; try common ones
      if ! install_packages php php-cli php-mbstring php-xml php-curl php-zip php-opcache; then
        warn "Could not install full PHP extension set; proceeding with available packages."
        install_packages php php-cli || true
      fi
      if install_packages composer; then
        composer_installed="true"
      fi
      ;;
    dnf|yum)
      install_packages php-cli php-mbstring php-xml php-json php-zip
      # Composer might not be available; fall back to manual installation
      ;;
    zypper)
      install_packages php7 php7-cli php7-mbstring php7-xmlreader php7-zip || install_packages php php-cli
      ;;
    *)
      error "Cannot install PHP; unsupported package manager."
      return 1
      ;;
  esac

  if [ "${composer_installed}" != "true" ]; then
    if ! need_cmd composer; then
      log "Installing Composer manually..."
      curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
      rm -f /tmp/composer-setup.php
    fi
  fi

  if [ -f "${APP_ROOT}/composer.json" ]; then
    log "Installing PHP dependencies via Composer..."
    composer install --no-dev --prefer-dist --no-interaction || composer install --no-interaction
  fi

  export APP_PORT="${APP_PORT:-8080}"
}

setup_dotnet() {
  warn ".NET project detected. Automated runtime installation is not implemented in this generic script due to repository setup complexity. Use a base image with .NET SDK/Runtime (e.g., mcr.microsoft.com/dotnet/sdk) or preinstall dotnet in your Dockerfile."
}

configure_permissions() {
  # In container environments, running as root is common. If APP_USER/APP_GROUP provided, adjust ownership.
  local user="${APP_USER:-}"
  local group="${APP_GROUP:-}"
  if [ -n "${user}" ] && [ -n "${group}" ]; then
    if id -u "${user}" >/dev/null 2>&1 && getent group "${group}" >/dev/null 2>&1; then
      chown -R "${user}:${group}" "${APP_ROOT}" || warn "Failed to chown ${APP_ROOT} to ${user}:${group}"
    else
      warn "APP_USER/APP_GROUP specified but user/group not found. Skipping ownership adjustment."
    fi
  fi
}

derive_common_ports() {
  # Heuristics to set common ports based on files
  if [ -f "${APP_ROOT}/requirements.txt" ] && grep -qi flask "${APP_ROOT}/requirements.txt"; then
    APP_PORT="${APP_PORT:-5000}"
  elif [ -f "${APP_ROOT}/requirements.txt" ] && grep -qi django "${APP_ROOT}/requirements.txt"; then
    APP_PORT="${APP_PORT:-8000}"
  elif [ -f "${APP_ROOT}/package.json" ]; then
    APP_PORT="${APP_PORT:-3000}"
  fi
  export APP_PORT
}

print_summary() {
  echo ""
  log "Environment setup complete."
  echo "Summary:"
  echo "  - APP_ROOT: ${APP_ROOT}"
  echo "  - APP_ENV: ${APP_ENV}"
  echo "  - APP_PORT: ${APP_PORT}"
  echo "  - Detected project type: ${PROJECT_TYPE}"
  echo ""
  echo "Notes:"
  echo "  - This script is idempotent and safe to run multiple times."
  echo "  - For Python, activate venv: source ${APP_ROOT}/.venv/bin/activate"
  echo "  - Ensure your container exposes APP_PORT (${APP_PORT})."
}

main() {
  if ! is_root; then
    warn "Script is not running as root. Package installation may fail in container environments."
  fi

  # Short-circuit to avoid long-running external setups if Prometheus tools are already present
  short_circuit_if_prometheus_ready

  detect_os
  detect_pkg_manager
  install_base_tools
  setup_prometheus_tools

  setup_project_dirs
  cd_to_app_root
  setup_env_common

  PROJECT_TYPE="$(detect_project_type)"
  log "Detected project type: ${PROJECT_TYPE}"

  case "${PROJECT_TYPE}" in
    python) setup_python ;;
    node)   setup_node ;;
    go)     setup_go ;;
    java)   setup_java ;;
    gradle) setup_gradle ;;
    ruby)   setup_ruby ;;
    rust)   setup_rust ;;
    php)    setup_php ;;
    dotnet) setup_dotnet ;;
    unknown)
      warn "Could not detect project type automatically. Installed base tools. Please ensure runtime is present."
      ;;
  esac

  # Configure auto-activation of virtual environment for interactive shells
  setup_auto_activate

  derive_common_ports
  configure_permissions
  print_summary
}

main "$@"