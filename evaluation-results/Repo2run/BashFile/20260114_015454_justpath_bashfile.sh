#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type(s) and installs required runtimes and system packages
# - Configures dependencies, environment variables, and directory structure
# - Idempotent and safe to run multiple times
# - Designed for root execution inside minimal container images (no sudo)

set -Eeuo pipefail
IFS=$'\n\t'

# ------------- Configuration (override via env) ----------------
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
ENVIRONMENT="${ENVIRONMENT:-production}"
SETUP_STAMP="${SETUP_STAMP:-/var/local/.project_setup_stamp}"
LOG_LEVEL="${LOG_LEVEL:-info}" # info|warn|error

# ------------- Logging utilities ------------------------------
is_tty() { [ -t 1 ] && [ -t 2 ]; }
if is_tty; then
  C_GREEN=$'\e[0;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[0;31m'; C_BLUE=$'\e[0;34m'; C_RESET=$'\e[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_RESET=""
fi

timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo -e "${C_GREEN}[$(timestamp)] [INFO]${C_RESET} $*" >&1; }
warn() { echo -e "${C_YELLOW}[$(timestamp)] [WARN]${C_RESET} $*" >&2; }
err() { echo -e "${C_RED}[$(timestamp)] [ERROR]${C_RESET} $*" >&2; }
debug() { if [ "${LOG_LEVEL}" = "debug" ]; then echo -e "${C_BLUE}[$(timestamp)] [DEBUG]${C_RESET} $*" >&1; fi; }

trap 'err "Failed at line $LINENO: exit code $?"; exit 1' ERR

# ------------- Package manager detection ----------------------
PKG_MGR=""
OS_FAMILY="" # debian|alpine|rhel
UPDATE_DONE_FLAG="/var/local/.pkg_update_done"

detect_pkg_mgr() {
  if [ -f /etc/alpine-release ]; then
    PKG_MGR="apk"; OS_FAMILY="alpine"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"; OS_FAMILY="debian"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"; OS_FAMILY="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"; OS_FAMILY="rhel"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"; OS_FAMILY="rhel"
  else
    err "No supported package manager found (apk/apt/dnf/yum/microdnf)."
    exit 1
  fi
  debug "Detected package manager: ${PKG_MGR} (OS family: ${OS_FAMILY})"
}

pm_update() {
  if [ -f "${UPDATE_DONE_FLAG}" ]; then
    debug "Package index already updated."
    return 0
  fi
  case "${PKG_MGR}" in
    apk)
      apk update || true
      ;;
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    dnf)
      dnf -y makecache || true
      ;;
    yum)
      yum -y makecache || true
      ;;
    microdnf)
      microdnf -y update || true
      ;;
  esac
  mkdir -p "$(dirname "${UPDATE_DONE_FLAG}")"
  touch "${UPDATE_DONE_FLAG}"
}

pm_install() {
  # Accepts generic package names and maps them to OS-specific where needed
  case "${PKG_MGR}" in
    apk)
      apk add --no-cache "$@" ;;
    apt-get)
      apt-get install -y --no-install-recommends "$@" ;;
    dnf)
      dnf install -y "$@" ;;
    yum)
      yum install -y "$@" ;;
    microdnf)
      microdnf install -y "$@" ;;
  esac
}

pm_clean() {
  case "${PKG_MGR}" in
    apk)
      rm -rf /var/cache/apk/* || true ;;
    apt-get)
      apt-get clean; rm -rf /var/lib/apt/lists/* ;;
    dnf|yum|microdnf)
      rm -rf /var/cache/dnf || true; rm -rf /var/cache/yum || true ;;
  esac
}

# ------------- System prerequisites ---------------------------
install_base_packages() {
  log "Installing base system packages and build tools..."
  pm_update

  case "${OS_FAMILY}" in
    debian)
      pm_install ca-certificates curl git bash tar xz-utils unzip zip \
        build-essential gcc g++ make pkg-config \
        openssl libssl-dev libffi-dev
      ;;
    alpine)
      pm_install ca-certificates curl git bash tar xz unzip zip \
        build-base gcc g++ make pkgconf \
        openssl openssl-dev libffi-dev
      ;;
    rhel)
      pm_install ca-certificates curl git bash tar xz unzip zip \
        gcc gcc-c++ make pkgconfig \
        openssl openssl-devel libffi-devel || true
      ;;
  esac
  pm_clean
}

# ------------- User and directory setup -----------------------
ensure_user_and_dirs() {
  log "Setting up application directory and user..."
  mkdir -p "${APP_DIR}" "${APP_DIR}/logs" "${APP_DIR}/tmp" "${APP_DIR}/bin"

  # Create group if missing
  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    if command -v addgroup >/dev/null 2>&1; then
      addgroup -g "${APP_GID}" -S "${APP_GROUP}" || addgroup -g "${APP_GID}" "${APP_GROUP}" || true
    elif command -v groupadd >/dev/null 2>&1; then
      groupadd -g "${APP_GID}" -f "${APP_GROUP}" || true
    fi
  fi

  # Create user if missing
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    if command -v adduser >/dev/null 2>&1; then
      adduser -S -D -H -G "${APP_GROUP}" -u "${APP_UID}" "${APP_USER}" || adduser -D -H -G "${APP_GROUP}" -u "${APP_UID}" "${APP_USER}" || true
    elif command -v useradd >/dev/null 2>&1; then
      useradd -M -s /bin/bash -g "${APP_GROUP}" -u "${APP_UID}" "${APP_USER}" || true
    fi
  fi

  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true
  chmod -R u+rwX,g+rwX "${APP_DIR}" || true
}

# ------------- Project type detection -------------------------
detect_project_types() {
  cd "${APP_DIR}"
  PYTHON_PROJECT="false"
  NODE_PROJECT="false"
  RUBY_PROJECT="false"
  JAVA_PROJECT="false"
  GO_PROJECT="false"
  RUST_PROJECT="false"
  PHP_PROJECT="false"
  DOTNET_PROJECT="false"

  [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ] && PYTHON_PROJECT="true"
  [ -f "package.json" ] && NODE_PROJECT="true"
  [ -f "Gemfile" ] && RUBY_PROJECT="true"
  ls *.csproj >/dev/null 2>&1 && DOTNET_PROJECT="true"
  ls *.sln >/dev/null 2>&1 && DOTNET_PROJECT="true"
  [ -f "pom.xml" ] || ls build.gradle* >/dev/null 2>&1 && JAVA_PROJECT="true"
  [ -f "go.mod" ] && GO_PROJECT="true"
  [ -f "Cargo.toml" ] && RUST_PROJECT="true"
  [ -f "composer.json" ] && PHP_PROJECT="true"

  debug "Detected types -> python:${PYTHON_PROJECT} node:${NODE_PROJECT} ruby:${RUBY_PROJECT} java:${JAVA_PROJECT} go:${GO_PROJECT} rust:${RUST_PROJECT} php:${PHP_PROJECT} dotnet:${DOTNET_PROJECT}"
}

# ------------- Language runtime installers --------------------
install_python_runtime() {
  log "Installing Python runtime and tools..."
  case "${OS_FAMILY}" in
    debian)
      pm_update
      pm_install python3 python3-dev python3-venv python3-pip
      ;;
    alpine)
      pm_update
      pm_install python3 python3-dev py3-pip
      ;;
    rhel)
      pm_update
      pm_install python3 python3-devel python3-pip
      ;;
  esac
  pm_clean
}

install_node_runtime() {
  log "Installing Node.js runtime..."
  if command -v node >/dev/null 2>&1; then
    debug "Node.js already installed: $(node -v)"
    return 0
  fi
  case "${OS_FAMILY}" in
    alpine)
      pm_update
      pm_install nodejs npm
      ;;
    debian)
      pm_update
      curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
      pm_install nodejs
      ;;
    rhel)
      pm_update
      curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
      pm_install nodejs
      ;;
  esac
  pm_clean
}

install_ruby_runtime() {
  log "Installing Ruby and Bundler..."
  case "${OS_FAMILY}" in
    debian)
      pm_update
      pm_install ruby-full
      gem install --no-document bundler || true
      ;;
    alpine)
      pm_update
      pm_install ruby ruby-dev
      gem install --no-document bundler || true
      ;;
    rhel)
      pm_update
      pm_install ruby ruby-devel
      gem install --no-document bundler || true
      ;;
  esac
  pm_clean
}

install_java_runtime() {
  log "Installing Java (OpenJDK) and build tools..."
  case "${OS_FAMILY}" in
    debian)
      pm_update
      pm_install openjdk-17-jdk maven
      pm_install gradle || true
      ;;
    alpine)
      pm_update
      pm_install openjdk17-jdk maven
      pm_install gradle || true
      ;;
    rhel)
      pm_update
      pm_install java-17-openjdk-devel maven
      pm_install gradle || true
      ;;
  esac
  pm_clean
}

install_go_runtime() {
  log "Installing Go..."
  case "${OS_FAMILY}" in
    debian)
      pm_update; pm_install golang ;;
    alpine)
      pm_update; pm_install go ;;
    rhel)
      pm_update; pm_install golang ;;
  esac
  pm_clean
}

install_rust_runtime() {
  log "Installing Rust via rustup (this may take a while)..."
  if command -v cargo >/dev/null 2>&1; then
    debug "Rust already installed: $(rustc --version 2>/dev/null || echo 'unknown')"
    return 0
  fi
  export RUSTUP_HOME="/opt/rustup"
  export CARGO_HOME="/opt/cargo"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
  ln -sf /opt/cargo/bin/* /usr/local/bin/ || true
}

install_php_runtime() {
  log "Installing PHP CLI and Composer..."
  case "${OS_FAMILY}" in
    debian)
      pm_update
      pm_install php-cli php-zip php-mbstring php-xml curl unzip
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
      fi
      ;;
    alpine)
      pm_update
      pm_install php php-cli php-phar php-zip php-mbstring php-xml curl unzip composer || {
        # Fallback if some PHP subpackages differ
        pm_install php81 php81-cli php81-phar php81-zip php81-mbstring php81-xml curl unzip composer || true
      }
      ;;
    rhel)
      pm_update
      pm_install php-cli php-zip php-mbstring php-xml curl unzip
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
      fi
      ;;
  esac
  pm_clean
}

install_dotnet_runtime() {
  log "Installing .NET SDK (attempt)..."
  # Note: .NET installation varies by distro; try official script
  if command -v dotnet >/dev/null 2>&1; then
    debug ".NET SDK already installed: $(dotnet --version)"
    return 0
  fi
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --channel STS --install-dir /usr/share/dotnet
  ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet || true
  rm -f /tmp/dotnet-install.sh
}

# ------------- Dependency installers per type -----------------
setup_python_project() {
  log "Configuring Python project environment..."
  cd "${APP_DIR}"
  # Determine python executable name
  PY=python3
  if ! command -v "${PY}" >/dev/null 2>&1; then
    err "python3 not found after installation."
    exit 1
  fi

  # Virtual environment
  VENV_DIR="${APP_DIR}/.venv"
  if [ ! -d "${VENV_DIR}" ]; then
    "${PY}" -m venv "${VENV_DIR}"
  fi
  # shellcheck source=/dev/null
  source "${VENV_DIR}/bin/activate"

  python -m pip install --upgrade pip setuptools wheel
  if [ -f "requirements.txt" ]; then
    PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1 pip install -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    # Try installing project in editable mode if build-system present
    PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1 pip install .
  elif [ -f "Pipfile" ]; then
    pip install pipenv && PIPENV_YES=1 pipenv install --system --deploy
  fi

  deactivate || true
  chown -R "${APP_USER}:${APP_GROUP}" "${VENV_DIR}" || true
}

setup_node_project() {
  log "Configuring Node.js project..."
  cd "${APP_DIR}"
  if ! command -v node >/dev/null 2>&1; then
    err "node not found after installation."
    exit 1
  fi
  # Enable corepack to manage yarn/pnpm if needed
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  if [ -f "yarn.lock" ]; then
    if ! command -v yarn >/dev/null 2>&1; then corepack prepare yarn@stable --activate || true; fi
    YARN_ENABLE_IMMUTABLE_INSTALLS=1 yarn install --frozen-lockfile || yarn install
  elif [ -f "pnpm-lock.yaml" ]; then
    if ! command -v pnpm >/dev/null 2>&1; then corepack prepare pnpm@latest --activate || npm i -g pnpm || true; fi
    pnpm install --frozen-lockfile || pnpm install
  else
    if [ -f "package-lock.json" ]; then
      npm ci || npm install
    else
      npm install || true
    fi
  fi
}

setup_ruby_project() {
  log "Configuring Ruby project..."
  cd "${APP_DIR}"
  if ! command -v bundle >/dev/null 2>&1; then
    gem install --no-document bundler || true
  fi
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs="$(nproc || echo 2)" --retry=3
}

setup_java_project() {
  log "Preparing Java project dependencies..."
  cd "${APP_DIR}"
  if [ -f "pom.xml" ]; then
    mvn -B -q -DskipTests dependency:go-offline || true
  fi
  if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew --no-daemon --quiet build -x test || ./gradlew --no-daemon --quiet dependencies || true
  else
    if command -v gradle >/dev/null 2>&1; then
      gradle --no-daemon --quiet build -x test || gradle --no-daemon --quiet dependencies || true
    fi
  fi
}

setup_go_project() {
  log "Preparing Go project..."
  cd "${APP_DIR}"
  export GOPATH="${GOPATH:-/go}"
  export GOCACHE="${GOCACHE:-/go/cache}"
  mkdir -p "${GOPATH}" "${GOCACHE}"
  go env -w GOPATH="${GOPATH}" GOCACHE="${GOCACHE}" >/dev/null 2>&1 || true
  go mod download || true
}

setup_rust_project() {
  log "Preparing Rust project..."
  cd "${APP_DIR}"
  export CARGO_HOME="${CARGO_HOME:-/opt/cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rustup}"
  cargo fetch || true
}

setup_php_project() {
  log "Configuring PHP project..."
  cd "${APP_DIR}"
  if command -v composer >/dev/null 2>&1; then
    composer install --no-interaction --prefer-dist --no-progress || true
  else
    warn "Composer not found after installation attempt."
  fi
}

setup_dotnet_project() {
  log "Preparing .NET project..."
  cd "${APP_DIR}"
  if command -v dotnet >/dev/null 2>&1; then
    # Restore (no build) for caching
    find . -maxdepth 2 -name "*.sln" -o -name "*.csproj" | while read -r proj; do
      dotnet restore "$proj" || true
    done
  else
    warn ".NET SDK unavailable; skipping restore."
  fi
}

# ------------- Environment variables and PATH -----------------
configure_environment() {
  log "Configuring environment variables..."
  ENV_FILE="/etc/profile.d/project_env.sh"
  VENV_DIR="${APP_DIR}/.venv"

  # Determine default port heuristically
  DEFAULT_PORT="8080"
  if [ "${NODE_PROJECT}" = "true" ]; then DEFAULT_PORT="3000"; fi
  if [ "${PYTHON_PROJECT}" = "true" ]; then DEFAULT_PORT="8000"; fi
  # Flask common
  if [ -f "${APP_DIR}/app.py" ] || [ -d "${APP_DIR}/flask_app" ]; then DEFAULT_PORT="5000"; fi
  if [ "${PHP_PROJECT}" = "true" ]; then DEFAULT_PORT="8000"; fi

  cat > "${ENV_FILE}" <<EOF
# Generated by setup script - do not edit manually
export APP_DIR="${APP_DIR}"
export APP_ENV="${ENVIRONMENT}"
export PORT="\${PORT:-${DEFAULT_PORT}}"

# Language-specific optimizations
export PYTHONDONTWRITEBYTECODE=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export NODE_ENV="${ENVIRONMENT}"

# Add project bin paths
if [ -d "${APP_DIR}/bin" ]; then
  export PATH="${APP_DIR}/bin:\$PATH"
fi
if [ -d "${APP_DIR}/node_modules/.bin" ]; then
  export PATH="${APP_DIR}/node_modules/.bin:\$PATH"
fi
if [ -d "${VENV_DIR}/bin" ]; then
  export PATH="${VENV_DIR}/bin:\$PATH"
fi
EOF

  chmod 0644 "${ENV_FILE}"
}

# ------------- Convenience activation script ------------------
create_activate_script() {
  ACTIVATE="${APP_DIR}/bin/activate_project"
  VENV_DIR="${APP_DIR}/.venv"
  cat > "${ACTIVATE}" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ -f /etc/profile.d/project_env.sh ]; then
  # shellcheck source=/dev/null
  source /etc/profile.d/project_env.sh
fi
if [ -d "${APP_DIR:-/app}/.venv" ]; then
  # shellcheck source=/dev/null
  source "${APP_DIR:-/app}/.venv/bin/activate"
fi
echo "Environment activated. APP_DIR=${APP_DIR:-/app} PORT=${PORT:-8080}"
EOS
  chmod +x "${ACTIVATE}"
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}/bin" || true
}

# ------------- Build entrypoint (Makefile) ---------------------
ensure_build_entrypoint() {
  cd "${APP_DIR}"
  # Ensure make is available across distros
  if ! command -v make >/dev/null 2>&1; then
    (apt-get update && apt-get install -y make) || (yum -y install make) || (dnf -y install make) || (apk add --no-cache make) || (zypper -n install make) || {
      echo "Failed to install make via known package managers" >&2
      exit 1
    }
  fi
  # Ensure a deterministic build target exists
  if [ ! -f Makefile ]; then
    printf ".PHONY: build\nbuild:\n\t@echo \"No-op build: nothing to build\"\n" > Makefile
  elif ! grep -qE "^[[:space:]]*build:" Makefile; then
    printf "\n.PHONY: build\nbuild:\n\t@echo \"No-op build: nothing to build\"\n" >> Makefile
  fi
}

# ------------- Main flow --------------------------------------
main() {
  log "Starting universal project environment setup..."

  detect_pkg_mgr
  install_base_packages
  ensure_user_and_dirs
  detect_project_types
  ensure_build_entrypoint

  # Install runtimes as needed
  [ "${PYTHON_PROJECT}" = "true" ] && install_python_runtime
  [ "${NODE_PROJECT}" = "true" ] && install_node_runtime
  [ "${RUBY_PROJECT}" = "true" ] && install_ruby_runtime
  [ "${JAVA_PROJECT}" = "true" ] && install_java_runtime
  [ "${GO_PROJECT}" = "true" ] && install_go_runtime
  [ "${RUST_PROJECT}" = "true" ] && install_rust_runtime
  [ "${PHP_PROJECT}" = "true" ] && install_php_runtime
  [ "${DOTNET_PROJECT}" = "true" ] && install_dotnet_runtime

  # Install dependencies per project type
  [ "${PYTHON_PROJECT}" = "true" ] && setup_python_project
  [ "${NODE_PROJECT}" = "true" ] && setup_node_project
  [ "${RUBY_PROJECT}" = "true" ] && setup_ruby_project
  [ "${JAVA_PROJECT}" = "true" ] && setup_java_project
  [ "${GO_PROJECT}" = "true" ] && setup_go_project
  [ "${RUST_PROJECT}" = "true" ] && setup_rust_project
  [ "${PHP_PROJECT}" = "true" ] && setup_php_project
  [ "${DOTNET_PROJECT}" = "true" ] && setup_dotnet_project

  configure_environment
  create_activate_script

  # Set ownership at the end (idempotent)
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true

  # Drop a stamp file for idempotency
  mkdir -p "$(dirname "${SETUP_STAMP}")"
  date > "${SETUP_STAMP}"

  log "Environment setup completed successfully."
  log "Tip: source /etc/profile.d/project_env.sh or run ${APP_DIR}/bin/activate_project"
}

# Ensure APP_DIR exists before proceeding
mkdir -p "${APP_DIR}"
main "$@" || { err "Setup failed."; exit 1; }