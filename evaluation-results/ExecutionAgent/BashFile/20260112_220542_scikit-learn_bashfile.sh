#!/usr/bin/env bash
# Environment setup script for containerized projects
# Detects project type(s) and installs required runtimes, system packages, and dependencies.
# Designed to be idempotent and safe to run multiple times in Docker containers.

set -Eeuo pipefail
IFS=$'\n\t'

# Configurable defaults (can be overridden via env)
: "${PROJECT_ROOT:=/app}"
: "${APP_USER:=app}"
: "${APP_GROUP:=app}"
: "${CREATE_APP_USER:=true}"       # set to false to skip creating a non-root user
: "${NONINTERACTIVE:=true}"        # set to false to allow interactive package managers
: "${PY_VENV_DIR:=.venv}"
: "${NODE_ENV:=production}"
: "${FORCE_REINSTALL:=false}"      # true to force reinstall deps (e.g., npm ci, pip --force-reinstall)
: "${SETUP_LOG_LEVEL:=info}"       # debug|info|warn|error

# Colorized logging (if terminal)
if [ -t 1 ]; then
  RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; NC="\033[0m"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

timestamp() { date +'%Y-%m-%d %H:%M:%S'; }

log() {
  local level="${1}"; shift || true
  local msg="${*:-}"
  local allowed="info"
  case "${SETUP_LOG_LEVEL}" in
    debug) allowed="debug info warn error" ;;
    info) allowed="info warn error" ;;
    warn) allowed="warn error" ;;
    error) allowed="error" ;;
    *) allowed="info warn error" ;;
  esac
  case "${level}" in
    debug) [[ " ${allowed} " == *" debug "* ]] || return 0 ;;
    info) [[ " ${allowed} " == *" info "* ]] || return 0 ;;
    warn) [[ " ${allowed} " == *" warn "* ]] || return 0 ;;
    error) [[ " ${allowed} " == *" error "* ]] || return 0 ;;
  esac
  local color="${NC}"
  case "${level}" in
    debug) color="${BLUE}" ;;
    info) color="${GREEN}" ;;
    warn) color="${YELLOW}" ;;
    error) color="${RED}" ;;
  esac
  echo -e "${color}[$(timestamp)] [${level^^}]${NC} ${msg}"
}

err_report() {
  local exit_code=$?
  log error "Setup failed at line ${BASH_LINENO[0]} with exit code ${exit_code}"
  exit "${exit_code}"
}
trap err_report ERR

umask 022

# Create a marker directory for idempotency stamps
STAMP_DIR="/var/local/setup-stamps"
mkdir -p "${STAMP_DIR}"

# Detect package manager
PKG_MGR=""
OS_FAMILY=""
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    OS_FAMILY="debian"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    OS_FAMILY="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    OS_FAMILY="rhel"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    OS_FAMILY="suse"
  else
    PKG_MGR=""
    OS_FAMILY="unknown"
  fi
}
detect_pkg_mgr

if [ "${NONINTERACTIVE}" = "true" ]; then
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
fi

pkg_update() {
  [ -n "${PKG_MGR}" ] || { log warn "No supported package manager detected"; return 0; }
  local stamp="${STAMP_DIR}/pkg_updated.${PKG_MGR}"
  if [ -f "${stamp}" ]; then
    log debug "Package index already updated for ${PKG_MGR}"
    return 0
  fi
  log info "Updating package index using ${PKG_MGR}..."
  case "${PKG_MGR}" in
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
    zypper)
      zypper -n refresh
      ;;
  esac
  touch "${stamp}"
}

pkg_install() {
  [ -n "${PKG_MGR}" ] || { log warn "Cannot install packages: no package manager"; return 0; }
  local pkgs=("$@")
  [ "${#pkgs[@]}" -gt 0 ] || return 0
  log info "Installing system packages: ${pkgs[*]}"
  case "${PKG_MGR}" in
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
    zypper)
      zypper -n install -y "${pkgs[@]}"
      ;;
  esac
}

pkg_clean() {
  [ -n "${PKG_MGR}" ] || return 0
  log debug "Cleaning package caches..."
  case "${PKG_MGR}" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      # apk cache is already minimized with --no-cache
      ;;
    dnf)
      dnf clean all -y || true
      rm -rf /var/cache/dnf || true
      ;;
    yum)
      yum clean all -y || true
      rm -rf /var/cache/yum || true
      ;;
    zypper)
      zypper clean --all || true
      ;;
  esac
}

retry() {
  local attempts="${1:-3}"
  shift || true
  local delay=2
  local i=1
  until "$@"; do
    local ec=$?
    if [ $i -ge $attempts ]; then
      log error "Command failed after ${attempts} attempts: $*"
      return $ec
    fi
    log warn "Command failed (attempt ${i}/${attempts}), retrying in ${delay}s: $*"
    sleep $delay
    i=$((i+1))
    delay=$((delay*2))
  done
}

# Project detection
cd_detect_root() {
  # If PROJECT_ROOT exists, ensure it; otherwise, default to CWD as project root if it looks like a project
  if [ -d "${PROJECT_ROOT}" ]; then
    cd "${PROJECT_ROOT}"
  else
    mkdir -p "${PROJECT_ROOT}"
    cd "${PROJECT_ROOT}"
  fi
}
cd_detect_root

# Copy current workspace into PROJECT_ROOT if it's empty and we're not already there
if [ -z "$(ls -A "${PROJECT_ROOT}" 2>/dev/null || true)" ]; then
  if [ -n "${PWD}" ] && [ "${PWD}" != "${PROJECT_ROOT}" ] && [ -d "${PWD}" ]; then
    log debug "Project directory ${PROJECT_ROOT} is empty."
  fi
fi

# Determine stack by presence of files
shopt -s nullglob
IS_NODE=false
IS_PYTHON=false
IS_JAVA_MAVEN=false
IS_JAVA_GRADLE=false
IS_GO=false
IS_RUST=false
IS_PHP=false
IS_RUBY=false
IS_DOTNET=false
IS_ELIXIR=false

[ -f package.json ] && IS_NODE=true
{ [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f Pipfile ] || [ -f setup.py ] || [ -f manage.py ]; } && IS_PYTHON=true
[ -f pom.xml ] && IS_JAVA_MAVEN=true
{ [ -f build.gradle ] || [ -f build.gradle.kts ]; } && IS_JAVA_GRADLE=true
[ -f go.mod ] && IS_GO=true
[ -f Cargo.toml ] && IS_RUST=true
[ -f composer.json ] && IS_PHP=true
[ -f Gemfile ] && IS_RUBY=true
ls ./*.csproj ./*.sln >/dev/null 2>&1 && IS_DOTNET=true
[ -f mix.exs ] && IS_ELIXIR=true
shopt -u nullglob

log info "Detected stacks: node=${IS_NODE} python=${IS_PYTHON} maven=${IS_JAVA_MAVEN} gradle=${IS_JAVA_GRADLE} go=${IS_GO} rust=${IS_RUST} php=${IS_PHP} ruby=${IS_RUBY} dotnet=${IS_DOTNET} elixir=${IS_ELIXIR}"

# Create app user/group if root
ensure_app_user() {
  if [ "${CREATE_APP_USER}" != "true" ]; then
    log info "Skipping app user creation (CREATE_APP_USER=${CREATE_APP_USER})"
    return 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    log warn "Not running as root; cannot create or chown to ${APP_USER}"
    return 0
  fi
  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    groupadd -g 1000 "${APP_GROUP}" || groupadd "${APP_GROUP}"
  fi
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/sh -g "${APP_GROUP}" -u 1000 "${APP_USER}" || useradd -m -s /bin/sh -g "${APP_GROUP}" "${APP_USER}"
  fi
  mkdir -p "${PROJECT_ROOT}"
  chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}" || true
}

# Core utilities (git/curl/tar/zip/build tools/etc.)
install_core_utils() {
  pkg_update
  case "${PKG_MGR}" in
    apt)
      pkg_install ca-certificates curl wget git gnupg dirmngr zip unzip tar xz-utils \
                  openssl tzdata bash \
                  build-essential pkg-config
      ;;
    apk)
      pkg_install ca-certificates curl wget git gnupg zip unzip tar xz \
                  openssl tzdata bash \
                  build-base pkgconf
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git gnupg2 zip unzip tar xz \
                  openssl tzdata bash \
                  make gcc gcc-c++ pkgconfig
      ;;
    zypper)
      pkg_install ca-certificates curl wget git gpg2 zip unzip tar xz \
                  openssl timezone bash \
                  make gcc gcc-c++ pkg-config
      ;;
    *)
      log warn "Unknown package manager. Skipping core utils installation."
      ;;
  esac
}

# Language/runtime installers
install_python_runtime() {
  log info "Installing Python runtime via Miniforge (Conda) at /opt ..."
  # Ensure required tools are present
  pkg_update
  case "${PKG_MGR}" in
    apt)
      pkg_install curl bzip2 ca-certificates
      ;;
    apk)
      # Package names differ on Alpine; try common combos
      pkg_install curl bzip2 ca-certificates || pkg_install curl bzip2-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install curl bzip2 ca-certificates
      ;;
    zypper)
      pkg_install curl bzip2 ca-certificates
      ;;
    *)
      :
      ;;
  esac

  # Install Miniforge if missing
  if [ ! -x /opt/miniforge/bin/conda ]; then
    local arch
    arch="$(uname -m)"
    local mf_url
    if [ "${arch}" = "x86_64" ]; then
      mf_url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
    else
      mf_url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${arch}.sh"
    fi
    retry 3 curl -fsSL -o /tmp/miniforge.sh "$mf_url"
    bash /tmp/miniforge.sh -b -p /opt/miniforge
    rm -f /tmp/miniforge.sh
  fi

  # Create a dedicated Python environment at /opt/pyenv using Conda
  if [ ! -x /opt/pyenv/bin/python ]; then
    /opt/miniforge/bin/conda create -y -p /opt/pyenv python=3.11
  fi

  /opt/pyenv/bin/python -m pip install -U pip setuptools wheel

  # Expose interpreter on PATH as `python` (and provide `python3` shim for compatibility)
  mkdir -p /usr/local/bin || true
  ln -sf /opt/pyenv/bin/python /usr/local/bin/python
  ln -sf /opt/pyenv/bin/python /usr/local/bin/python3 || true

  # Preinstall scikit-learn into the dedicated interpreter to satisfy build requirements
  /opt/pyenv/bin/python -m pip install -U scikit-learn || true
  /opt/pyenv/bin/python -m pip install -U pytest
}

install_node_runtime() {
  log info "Installing Node.js runtime..."
  case "${PKG_MGR}" in
    apt)
      # Try system nodejs first
      pkg_install nodejs npm || true
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
    zypper)
      pkg_install nodejs npm || pkg_install nodejs20 npm20 || true
      ;;
    *)
      log warn "Cannot install Node.js on unknown OS."
      ;;
  esac
  if ! command -v node >/dev/null 2>&1; then
    log warn "node not found; attempting NodeSource (Debian/Ubuntu only)"
    if [ "${PKG_MGR}" = "apt" ]; then
      retry 3 bash -c "curl -fsSL https://deb.nodesource.com/setup_18.x | bash -"
      pkg_install nodejs
    fi
  fi
  node -v || log warn "node not found after installation"
  npm -v || log warn "npm not found after installation"
}

install_java_runtime() {
  log info "Installing OpenJDK (17) and build tools..."
  case "${PKG_MGR}" in
    apt)
      pkg_install openjdk-17-jdk maven gradle
      ;;
    apk)
      pkg_install openjdk17-jdk maven gradle
      ;;
    dnf|yum)
      pkg_install java-17-openjdk-devel maven gradle
      ;;
    zypper)
      pkg_install java-17-openjdk-devel maven gradle
      ;;
    *)
      log warn "Cannot install Java on unknown OS."
      ;;
  esac
  java -version || log warn "java not found after installation"
}

install_go_runtime() {
  log info "Installing Go toolchain..."
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
    zypper)
      pkg_install go
      ;;
    *)
      log warn "Cannot install Go on unknown OS."
      ;;
  esac
  go version || log warn "go not found after installation"
}

install_rust_toolchain() {
  log info "Installing Rust toolchain..."
  case "${PKG_MGR}" in
    apt)
      if pkg_install cargo rustc; then
        :
      else
        :
      fi
      ;;
    apk)
      pkg_install cargo rust
      ;;
    dnf|yum)
      pkg_install rust cargo
      ;;
    zypper)
      pkg_install rust cargo
      ;;
  esac
  if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
    log warn "Cargo/rustc not available via package manager; installing via rustup (user toolchain)"
    retry 3 curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --default-toolchain stable
    export PATH="${HOME}/.cargo/bin:${PATH}"
  fi
  cargo --version || log warn "cargo not found after installation"
}

install_php_runtime() {
  log info "Installing PHP and Composer..."
  case "${PKG_MGR}" in
    apt)
      pkg_install php-cli php-xml php-curl php-mbstring php-zip zip unzip composer
      ;;
    apk)
      # Alpine packages are versioned; try php8x, fall back to meta
      if ! pkg_install php81 php81-cli php81-xml php81-curl php81-mbstring php81-zip composer; then
        pkg_install php php-cli php-xml php-curl php-mbstring php-zip composer || true
      fi
      ;;
    dnf|yum)
      pkg_install php-cli php-xml php-json php-mbstring php-curl php-zip composer
      ;;
    zypper)
      pkg_install php8 php8-cli php8-xml php8-mbstring php8-curl php8-zip composer || pkg_install php php-cli php-xml php-mbstring php-curl php-zip composer
      ;;
    *)
      log warn "Cannot install PHP on unknown OS."
      ;;
  esac
  php -v || log warn "php not found after installation"
  composer --version || log warn "composer not found after installation"
}

install_ruby_runtime() {
  log info "Installing Ruby and Bundler..."
  case "${PKG_MGR}" in
    apt)
      pkg_install ruby-full bundler
      ;;
    apk)
      pkg_install ruby ruby-dev build-base && gem install --no-document bundler
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel rubygems && gem install --no-document bundler
      ;;
    zypper)
      pkg_install ruby-devel rubygems && gem install --no-document bundler
      ;;
    *)
      log warn "Cannot install Ruby on unknown OS."
      ;;
  esac
  ruby -v || log warn "ruby not found after installation"
  bundler -v || log warn "bundler not found after installation"
}

install_dotnet_sdk() {
  log info "Installing .NET SDK (requires network access to Microsoft repos; best done in Dockerfile)..."
  case "${PKG_MGR}" in
    apt)
      retry 3 bash -c 'wget https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb'
      dpkg -i /tmp/packages-microsoft-prod.deb || true
      pkg_update
      pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || true
      ;;
    dnf|yum)
      retry 3 rpm -Uvh https://packages.microsoft.com/config/centos/7/packages-microsoft-prod.rpm || true
      pkg_update
      pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || true
      ;;
    *)
      log warn ".NET SDK installation not supported on this OS in this script."
      ;;
  esac
  dotnet --info || log warn "dotnet not found after installation"
}

install_elixir_runtime() {
  log info "Installing Elixir and Erlang (may be limited by distro repos)..."
  case "${PKG_MGR}" in
    apt)
      pkg_install erlang elixir
      ;;
    apk)
      pkg_install erlang elixir
      ;;
    dnf|yum)
      pkg_install erlang elixir
      ;;
    zypper)
      pkg_install erlang elixir
      ;;
    *)
      log warn "Cannot install Elixir/Erlang on unknown OS."
      ;;
  esac
  elixir -v || log warn "elixir not found after installation"
}

# Load environment from .env if present (simple parser: KEY=VALUE lines)
load_env_file() {
  local env_file="${PROJECT_ROOT}/.env"
  if [ -f "${env_file}" ]; then
    log info "Loading environment variables from .env"
    set -a
    # shellcheck disable=SC2046
    eval $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${env_file}" | sed 's/^/export /')
    set +a
  fi
}

# Set defaults for common env vars if not set
apply_env_defaults() {
  export NODE_ENV="${NODE_ENV}"
  export PYTHONDONTWRITEBYTECODE=1
  export PYTHONUNBUFFERED=1

  if [ "${IS_NODE}" = "true" ]; then
    : "${PORT:=3000}"
  elif [ "${IS_PYTHON}" = "true" ]; then
    : "${PORT:=8000}"
  elif [ "${IS_JAVA_MAVEN}" = "true" ] || [ "${IS_JAVA_GRADLE}" = "true" ]; then
    : "${PORT:=8080}"
  else
    : "${PORT:=8080}"
  fi
  export PORT
  log info "Using PORT=${PORT}"
}

# Dependency installers per stack
install_python_deps() {
  command -v python3 >/dev/null 2>&1 || install_python_runtime
  command -v python3 >/dev/null 2>&1 || { log error "Python 3 is required but not installed"; return 1; }
  # Create venv if not exists
  if [ ! -d "${PROJECT_ROOT}/${PY_VENV_DIR}" ] || [ "${FORCE_REINSTALL}" = "true" ]; then
    log info "Creating Python virtual environment at ${PY_VENV_DIR}"
    python3 -m venv "${PROJECT_ROOT}/${PY_VENV_DIR}"
  else
    log info "Python virtual environment already exists at ${PY_VENV_DIR}"
  fi
  # shellcheck disable=SC1090
  source "${PROJECT_ROOT}/${PY_VENV_DIR}/bin/activate"
  # Prevent local sklearn source tree from shadowing installed wheel (idempotent rename)
  if [ -d "/app/sklearn" ]; then
    mv -n "/app/sklearn" "/app/_sklearn_local_src" || true
  elif [ -d "./sklearn" ]; then
    mv -n "./sklearn" "./_sklearn_local_src" || true
  fi
  # Upgrade packaging tools and ensure pytest is available (per repair commands)
  python -m pip install -U pip setuptools wheel
  python -m pip install -U pytest
  # Optionally ensure scikit-learn is present for projects that need it
  python -m pip install -U scikit-learn || true
  if [ -f requirements.txt ]; then
    if [ "${FORCE_REINSTALL}" = "true" ]; then
      pip install --no-cache-dir --requirement requirements.txt --force-reinstall
    else
      pip install --no-cache-dir --requirement requirements.txt
    fi
  elif [ -f pyproject.toml ]; then
    # Try PEP 517 build backends; prefer pip-tools/uv if available
    if grep -qi "poetry" pyproject.toml; then
      pip install --no-cache-dir poetry
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi --no-root || poetry install --no-interaction --no-ansi
    else
      pip install --no-cache-dir "build>=1.0.0" "hatchling" "uv>=0.2" || true
      # Attempt to install dependencies via pip/uv
      if command -v uv >/dev/null 2>&1; then
        uv pip install -r <(uv pip compile pyproject.toml) || true
      else
        pip install --no-cache-dir -e . || pip install --no-cache-dir .
      fi
    fi
  elif [ -f Pipfile ]; then
    pip install --no-cache-dir pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
  else
    log warn "No Python dependency file found (requirements.txt/pyproject.toml/Pipfile)"
  fi
  # Create a sitecustomize.py to prevent local source trees (e.g., ./sklearn) from shadowing installed wheels
  # This is safe to ship in the repo and only adjusts sys.path when a local 'sklearn' dir is present.
  cat > "${PROJECT_ROOT}/sitecustomize.py" <<'PY'
import os, sys
# If a local 'sklearn' directory exists in the CWD, move the CWD entry
# from the front of sys.path to the end so it does not shadow installed packages.
cwd = os.getcwd()
if os.path.isdir(os.path.join(cwd, "sklearn")):
    if sys.path and sys.path[0] in ("", cwd):
        sys.path.append(sys.path.pop(0))
PY

  # Verify scikit-learn imports successfully from the installed distribution
  python -c "import sklearn, sklearn.__check_build; import sys; print('scikit-learn import OK:', sklearn.__version__)" || log warn "scikit-learn import test failed"

  deactivate || true
}

install_node_deps() {
  command -v node >/dev/null 2>&1 || install_node_runtime
  command -v node >/dev/null 2>&1 || { log error "Node.js is required but not installed"; return 1; }
  export NODE_ENV
  if [ -f yarn.lock ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      npm --version >/dev/null 2>&1 || install_node_runtime
      npm install -g yarn
    fi
    if [ "${FORCE_REINSTALL}" = "true" ]; then
      yarn install --frozen-lockfile --check-files
    else
      yarn install --frozen-lockfile || yarn install
    fi
  elif [ -f pnpm-lock.yaml ]; then
    if ! command -v pnpm >/dev/null 2>&1; then
      npm install -g pnpm
    fi
    if [ "${FORCE_REINSTALL}" = "true" ]; then
      pnpm install --frozen-lockfile
    else
      pnpm install --frozen-lockfile || pnpm install
    fi
  elif [ -f package-lock.json ]; then
    if [ "${FORCE_REINSTALL}" = "true" ]; then
      npm ci --no-audit --no-fund
    else
      npm ci --no-audit --no-fund || npm install --no-audit --no-fund
    fi
  elif [ -f package.json ]; then
    npm install --no-audit --no-fund
  else
    log warn "No package.json found for Node project"
  fi
}

install_maven_deps() {
  command -v java >/dev/null 2>&1 || install_java_runtime
  command -v mvn >/dev/null 2>&1 || install_java_runtime
  mvn -v || log warn "Maven not available"
  if command -v mvn >/dev/null 2>&1; then
    log info "Pre-fetching Maven dependencies (no build)"
    mvn -B -q dependency:go-offline || log warn "Maven dependency pre-fetch failed"
  fi
}

install_gradle_deps() {
  command -v java >/dev/null 2>&1 || install_java_runtime
  command -v gradle >/dev/null 2>&1 || install_java_runtime
  gradle -v || log warn "Gradle not available"
  if command -v gradle >/dev/null 2>&1; then
    log info "Pre-fetching Gradle dependencies"
    gradle --no-daemon --console=plain build -x test || log warn "Gradle pre-fetch failed"
  fi
}

install_go_deps() {
  command -v go >/dev/null 2>&1 || install_go_runtime
  command -v go >/dev/null 2>&1 || { log error "Go is required but not installed"; return 1; }
  log info "Downloading Go modules"
  go env -w GOPATH="${PROJECT_ROOT}/.gopath" || true
  go mod download || log warn "go mod download failed"
}

install_rust_deps() {
  command -v cargo >/dev/null 2>&1 || install_rust_toolchain
  command -v cargo >/dev/null 2>&1 || { log error "Rust is required but not installed"; return 1; }
  log info "Fetching Rust dependencies"
  cargo fetch || log warn "cargo fetch failed"
}

install_php_deps() {
  command -v php >/dev/null 2>&1 || install_php_runtime
  command -v composer >/dev/null 2>&1 || install_php_runtime
  if [ -f composer.json ]; then
    if [ -f composer.lock ]; then
      composer install --no-interaction --no-progress --prefer-dist
    else
      composer install --no-interaction --no-progress
    fi
  else
    log warn "composer.json not found"
  fi
}

install_ruby_deps() {
  command -v ruby >/dev/null 2>&1 || install_ruby_runtime
  if [ -f Gemfile ]; then
    bundle config set without 'development test' || true
    bundle install --jobs "$(nproc || echo 2)" --retry 3
  else
    log warn "Gemfile not found"
  fi
}

install_dotnet_deps() {
  command -v dotnet >/dev/null 2>&1 || install_dotnet_sdk
  if ls ./*.sln ./*.csproj >/dev/null 2>&1; then
    log info "Restoring .NET dependencies"
    dotnet restore || log warn "dotnet restore failed"
  else
    log warn "No .NET solution/project files found"
  fi
}

install_elixir_deps() {
  command -v mix >/dev/null 2>&1 || install_elixir_runtime
  if [ -f mix.exs ]; then
    mix local.hex --force
    mix local.rebar --force
    mix deps.get || log warn "mix deps.get failed"
  fi
}

# Permissions and directory structure
setup_directories() {
  mkdir -p "${PROJECT_ROOT}/logs" "${PROJECT_ROOT}/data" "${PROJECT_ROOT}/tmp"
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}" || true
  fi
}

# Create a default .env if missing
ensure_env_file() {
  local env_file="${PROJECT_ROOT}/.env"
  if [ ! -f "${env_file}" ]; then
    log info "Creating default .env file"
    cat > "${env_file}" <<EOF
# Environment variables for the application
NODE_ENV=${NODE_ENV}
PORT=${PORT}
# Add custom variables below, e.g.:
# DATABASE_URL=postgres://user:pass@host:5432/db
EOF
    if [ "$(id -u)" -eq 0 ]; then
      chown "${APP_USER}:${APP_GROUP}" "${env_file}" || true
      chmod 640 "${env_file}" || true
    fi
  fi
}

# Export common PATH adjustments
configure_runtime_env() {
  # Prefer venv bin for Python if exists
  if [ -d "${PROJECT_ROOT}/${PY_VENV_DIR}/bin" ]; then
    export PATH="${PROJECT_ROOT}/${PY_VENV_DIR}/bin:${PATH}"
  fi
  # cargo bin if exists
  if [ -d "${HOME}/.cargo/bin" ]; then
    export PATH="${HOME}/.cargo/bin:${PATH}"
  fi
  # npm global bin for root vs user
  if command -v npm >/dev/null 2>&1; then
    local npm_bin
    npm_bin="$(npm bin -g 2>/dev/null || true)"
    if [ -n "${npm_bin}" ]; then
      export PATH="${npm_bin}:${PATH}"
    fi
  fi
}

# Configure auto-activation of project Python virtual environment for interactive shells
setup_auto_activate() {
  local venv_dir="${PROJECT_ROOT}/${PY_VENV_DIR}"
  local bashrc_file="/root/.bashrc"
  local activate_line="source ${venv_dir}/bin/activate"

  # Create /etc/profile.d script (root only) for all users' interactive shells
  if [ "$(id -u)" -eq 0 ]; then
    local profile_script="/etc/profile.d/auto-venv.sh"
    if [ ! -f "$profile_script" ] || ! grep -qF "$activate_line" "$profile_script" 2>/dev/null; then
      cat > "$profile_script" <<EOF
# Auto-activate project Python venv if present
if [ -n "\$PS1" ] && [ -d "${venv_dir}/bin" ]; then
  source "${venv_dir}/bin/activate"
fi
EOF
      chmod 644 "$profile_script" || true
    fi
  fi

  # Root user's bashrc
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate Python virtual environment"
      echo "$activate_line"
    } >> "$bashrc_file" || true
  fi

  # App user's bashrc (if user exists)
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    local app_home
    app_home="$(getent passwd "${APP_USER}" | cut -d: -f6)"
    if [ -n "$app_home" ] && [ -d "$app_home" ]; then
      local app_bashrc="$app_home/.bashrc"
      if ! grep -qF "$activate_line" "$app_bashrc" 2>/dev/null; then
        {
          echo ""
          echo "# Auto-activate Python virtual environment"
          echo "$activate_line"
        } >> "$app_bashrc" || true
        chown "${APP_USER}:${APP_GROUP}" "$app_bashrc" || true
      fi
    fi
  fi
}

# Summary of detected run instructions
print_next_steps() {
  log info "Environment setup completed."
  if [ "${IS_PYTHON}" = "true" ]; then
    log info "Python: activate venv -> source ${PY_VENV_DIR}/bin/activate"
  fi
  if [ "${IS_NODE}" = "true" ] && [ -f package.json ]; then
    if jq -r '.scripts.start // empty' package.json >/dev/null 2>&1; then
      log info "Node: run -> npm run start (PORT=${PORT})"
    else
      log info "Node: run -> node <entry-file.js> (PORT=${PORT})"
    fi
  fi
  if [ "${IS_JAVA_MAVEN}" = "true" ]; then
    log info "Java/Maven: build -> mvn -B package -DskipTests"
  fi
  if [ "${IS_JAVA_GRADLE}" = "true" ]; then
    log info "Java/Gradle: build -> gradle build -x test"
  fi
  if [ "${IS_GO}" = "true" ]; then
    log info "Go: build -> go build ./..."
  fi
  if [ "${IS_RUST}" = "true" ]; then
    log info "Rust: build -> cargo build --release"
  fi
  if [ "${IS_PHP}" = "true" ]; then
    log info "PHP: run -> php -S 0.0.0.0:${PORT} -t public"
  fi
  if [ "${IS_RUBY}" = "true" ]; then
    log info "Ruby: run -> bundle exec <command>"
  fi
  if [ "${IS_DOTNET}" = "true" ]; then
    log info ".NET: run -> dotnet run --urls http://0.0.0.0:${PORT}"
  fi
  if [ "${IS_ELIXIR}" = "true" ]; then
    log info "Elixir: run -> mix phx.server (if Phoenix) on PORT=${PORT}"
  fi
}

main() {
  log info "Starting environment setup in ${PROJECT_ROOT}"

  install_core_utils
  ensure_app_user
  setup_directories

  load_env_file
  apply_env_defaults

  # Install language runtimes and dependencies as detected
  if [ "${IS_PYTHON}" = "true" ]; then
    install_python_runtime
    install_python_deps
    setup_auto_activate
  fi

  if [ "${IS_NODE}" = "true" ]; then
    install_node_runtime
    install_node_deps
  fi

  if [ "${IS_JAVA_MAVEN}" = "true" ]; then
    install_java_runtime
    install_maven_deps
  fi

  if [ "${IS_JAVA_GRADLE}" = "true" ]; then
    install_java_runtime
    install_gradle_deps
  fi

  if [ "${IS_GO}" = "true" ]; then
    install_go_runtime
    install_go_deps
  fi

  if [ "${IS_RUST}" = "true" ]; then
    install_rust_toolchain
    install_rust_deps
  fi

  if [ "${IS_PHP}" = "true" ]; then
    install_php_runtime
    install_php_deps
  fi

  if [ "${IS_RUBY}" = "true" ]; then
    install_ruby_runtime
    install_ruby_deps
  fi

  if [ "${IS_DOTNET}" = "true" ]; then
    install_dotnet_sdk
    install_dotnet_deps
  fi

  if [ "${IS_ELIXIR}" = "true" ]; then
    install_elixir_runtime
    install_elixir_deps
  fi

  configure_runtime_env
  ensure_env_file
  pkg_clean

  print_next_steps
}

main "$@"