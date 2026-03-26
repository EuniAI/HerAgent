#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common project types and installs appropriate runtimes, system packages, and dependencies.
# Safe to run multiple times (idempotent).

set -Eeuo pipefail
IFS=$'\n\t'

# Global configuration
APP_DIR="${APP_DIR:-$(pwd)}"
APP_USER="${APP_USER:-}"           # Optional: set to a username to chown files (e.g., "app")
APP_GROUP="${APP_GROUP:-${APP_USER:-}}"
CREATE_APP_USER="${CREATE_APP_USER:-false}"  # Set to true to create APP_USER if it doesn't exist
NONINTERACTIVE="${NONINTERACTIVE:-true}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
TZ="${TZ:-UTC}"

# Default versions (can be overridden by env vars)
DEFAULT_NODE_VERSION="${DEFAULT_NODE_VERSION:-20.11.1}"   # LTS
DEFAULT_GO_VERSION="${DEFAULT_GO_VERSION:-1.22.5}"
DEFAULT_DOTNET_CHANNEL="${DEFAULT_DOTNET_CHANNEL:-8.0}"
DEFAULT_JAVA_VERSION="${DEFAULT_JAVA_VERSION:-17}"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log()      { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()     { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error()    { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()      { error "$*"; exit 1; }

cleanup()  { :; }
on_error() {
  local exit_code=$?
  error "Setup failed with exit code ${exit_code}"
  exit "${exit_code}"
}
trap cleanup EXIT
trap on_error ERR

# Detect package manager
PKG_MGR=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""
PKG_CLEAN_CMD=""
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PKG_UPDATE_CMD="apt-get update -y"
    PKG_INSTALL_CMD="apt-get install -y --no-install-recommends"
    PKG_CLEAN_CMD="rm -rf /var/lib/apt/lists/*"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PKG_UPDATE_CMD="apk update"
    PKG_INSTALL_CMD="apk add --no-cache"
    PKG_CLEAN_CMD=":"  # no-op; --no-cache avoids cache
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
    PKG_UPDATE_CMD="microdnf -y update"
    PKG_INSTALL_CMD="microdnf -y install"
    PKG_CLEAN_CMD="microdnf clean all"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_UPDATE_CMD="dnf -y makecache"
    PKG_INSTALL_CMD="dnf -y install"
    PKG_CLEAN_CMD="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_UPDATE_CMD="yum -y makecache"
    PKG_INSTALL_CMD="yum -y install"
    PKG_CLEAN_CMD="yum clean all"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    PKG_UPDATE_CMD="zypper refresh"
    PKG_INSTALL_CMD="zypper --non-interactive install --no-recommends --force-resolution"
    PKG_CLEAN_CMD="zypper clean --all"
  else
    PKG_MGR=""
  fi
}

pkg_update()  { [ -n "${PKG_UPDATE_CMD}" ] && eval "${PKG_UPDATE_CMD}" || true; }
pkg_clean()   { [ -n "${PKG_CLEAN_CMD}" ] && eval "${PKG_CLEAN_CMD}" || true; }
pkg_install() {
  # shellcheck disable=SC2068
  if [ -n "${PKG_INSTALL_CMD}" ]; then
    eval "${PKG_INSTALL_CMD} $@"
  else
    die "No supported package manager found to install packages: $*"
  fi
}

ensure_timezone_noninteractive() {
  if [ "${PKG_MGR}" = "apt" ] && [ "${NONINTERACTIVE}" = "true" ]; then
    export DEBIAN_FRONTEND=noninteractive
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
    echo "${TZ}" >/etc/timezone || true
  fi
}

# Create user/group if requested
ensure_app_user() {
  if [ -n "${APP_USER}" ] && [ "${CREATE_APP_USER}" = "true" ]; then
    if ! id -u "${APP_USER}" >/dev/null 2>&1; then
      log "Creating user ${APP_USER}"
      if command -v adduser >/dev/null 2>&1; then
        if [ "${PKG_MGR}" = "apk" ]; then
          addgroup -S "${APP_GROUP}" 2>/dev/null || true
          adduser -S -G "${APP_GROUP}" -h "${APP_DIR}" "${APP_USER}"
        else
          addgroup "${APP_GROUP}" 2>/dev/null || true
          adduser --disabled-password --gecos "" --home "${APP_DIR}" --ingroup "${APP_GROUP}" "${APP_USER}"
        fi
      elif command -v useradd >/dev/null 2>&1; then
        getent group "${APP_GROUP}" >/dev/null 2>&1 || groupadd -r "${APP_GROUP}"
        useradd -m -d "${APP_DIR}" -s /bin/bash -g "${APP_GROUP}" "${APP_USER}"
      else
        warn "No useradd/adduser available; skipping user creation."
      fi
    fi
  fi
}

# Ensure base system tools
install_base_system_tools() {
  log "Installing base system packages and build tools..."
  detect_pkg_manager
  if [ -z "${PKG_MGR}" ]; then
    die "No supported package manager detected. This script requires apt, apk, dnf, microdnf, yum, or zypper."
  fi

  ensure_timezone_noninteractive
  pkg_update

  case "${PKG_MGR}" in
    apt)
      pkg_install ca-certificates curl git bash tar xz-utils unzip gzip make build-essential pkg-config gnupg openssl \
                  python3 python3-venv python3-pip python3-dev tzdata
      ;;
    apk)
      pkg_install ca-certificates curl git bash tar xz unzip gzip make build-base pkgconfig gnupg openssl openssl-dev \
                  python3 py3-venv py3-pip python3-dev tzdata
      ;;
    microdnf|dnf|yum)
      local gnupg_pkg="gnupg2"; [ "${PKG_MGR}" = "yum" ] && gnupg_pkg="gnupg2"
      pkg_install ca-certificates curl git bash tar xz unzip gzip make gcc gcc-c++ pkgconfig "${gnupg_pkg}" openssl openssl-devel \
                  python3 python3-pip python3-devel tzdata
      ;;
    zypper)
      pkg_install ca-certificates curl git bash tar xz unzip gzip make gcc gcc-c++ pkg-config gpg2 libopenssl-devel \
                  python3 python3-pip python3-devel timezone
      ;;
  esac

  update-ca-certificates >/dev/null 2>&1 || true
  pkg_clean
}

# Utility: write environment exports to profile.d and current shell
ensure_profile_env() {
  local profile_file="/etc/profile.d/zz-project-env.sh"
  if [ -w "/etc/profile.d" ]; then
    touch "${profile_file}"
    chmod 0644 "${profile_file}"
  fi
  for kv in "$@"; do
    local key="${kv%%=*}"
    local val="${kv#*=}"
    export "${key}=${val}"
    if [ -d "/etc/profile.d" ]; then
      if ! grep -q "^export ${key}=" "${profile_file}" 2>/dev/null; then
        echo "export ${key}=${val}" >> "${profile_file}"
      else
        # update existing
        sed -i "s|^export ${key}=.*$|export ${key}=${val}|g" "${profile_file}"
      fi
    fi
  done
}

# Directory structure
setup_directories() {
  log "Setting up application directory structure at ${APP_DIR} ..."
  mkdir -p "${APP_DIR}"
  mkdir -p "${APP_DIR}/"{logs,run,tmp,data}
  if [ -n "${APP_USER}" ] && id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true
  fi
}

# Project detection
HAS_NODE="false"
HAS_PYTHON="false"
HAS_JAVA="false"
HAS_GO="false"
HAS_RUST="false"
HAS_PHP="false"
HAS_RUBY="false"
HAS_DOTNET="false"

detect_project_types() {
  cd "${APP_DIR}"

  [ -f "package.json" ] && HAS_NODE="true"
  { [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ] || ls *.py >/dev/null 2>&1; } && HAS_PYTHON="true"
  { [ -f "pom.xml" ] || [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -f "gradlew" ] || [ -f "mvnw" ]; } && HAS_JAVA="true"
  [ -f "go.mod" ] && HAS_GO="true"
  [ -f "Cargo.toml" ] && HAS_RUST="true"
  [ -f "composer.json" ] && HAS_PHP="true"
  [ -f "Gemfile" ] && HAS_RUBY="true"
  { ls *.sln *.csproj >/dev/null 2>&1; } && HAS_DOTNET="true"

  log "Detected project types: node=${HAS_NODE}, python=${HAS_PYTHON}, java=${HAS_JAVA}, go=${HAS_GO}, rust=${HAS_RUST}, php=${HAS_PHP}, ruby=${HAS_RUBY}, dotnet=${HAS_DOTNET}"
}

# Node.js installation
node_arch() {
  local arch="$(uname -m)"
  case "${arch}" in
    x86_64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7l" ;;
    *) echo "x64" ;;
  esac
}

parse_node_version() {
  local ver=""
  if [ -f ".nvmrc" ]; then
    ver="$(tr -d ' \t\r\n' < .nvmrc || true)"
  fi
  if [ -z "${ver}" ] && [ -f "package.json" ]; then
    # naive engines.node parser (doesn't handle complex ranges)
    ver="$(grep -o '"node"[[:space:]]*:[[:space:]]*"[^"]\+"' package.json | head -n1 | sed 's/.*"node"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/' | tr -d ' \t' || true)"
    # If version like ">=18" or "^18", fallback to default
    if echo "${ver}" | grep -Eq '[<>=^*]'; then ver=""; fi
    # If has "x" like "20.x", trim to "20"
    if echo "${ver}" | grep -Eq '^[0-9]+\.[xX]$'; then
      ver="$(echo "${ver}" | cut -d. -f1)"
    fi
  fi
  if [ -z "${ver}" ]; then
    ver="${DEFAULT_NODE_VERSION}"
  fi
  echo "${ver}"
}

install_node() {
  if [ "${HAS_NODE}" != "true" ]; then return; fi
  local want_version
  want_version="$(parse_node_version)"
  local arch="$(node_arch)"
  if command -v node >/dev/null 2>&1; then
    local have_ver
    have_ver="$(node -v | sed 's/^v//')"
    if [ "${have_ver}" = "${want_version}" ]; then
      log "Node.js v${have_ver} already installed."
    else
      warn "Node.js version ${have_ver} found; installing requested ${want_version}."
    fi
  fi

  if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/^v//')" != "${want_version}" ]; then
    local url="https://nodejs.org/dist/v${want_version}/node-v${want_version}-linux-${arch}.tar.xz"
    local dest="/opt/node-v${want_version}"
    if [ ! -d "${dest}" ]; then
      log "Downloading Node.js v${want_version} (${arch}) ..."
      curl -fsSL "${url}" -o /tmp/node.tar.xz
      mkdir -p "${dest}"
      tar -xJf /tmp/node.tar.xz -C /opt
      mv "/opt/node-v${want_version}-linux-${arch}" "${dest}"
      rm -f /tmp/node.tar.xz
    fi
    ln -sfn "${dest}" /opt/node
    mkdir -p /usr/local/bin
    ln -sf /opt/node/bin/node /usr/local/bin/node
    ln -sf /opt/node/bin/npm /usr/local/bin/npm
    ln -sf /opt/node/bin/npx /usr/local/bin/npx
    # Corepack for yarn/pnpm
    ln -sf /opt/node/bin/corepack /usr/local/bin/corepack 2>/dev/null || true
    ensure_profile_env PATH="${PATH}:/opt/node/bin" NODE_ENV="${NODE_ENV:-production}"
    log "Node.js v${want_version} installed."
  fi

  # Install JS package manager and dependencies
  if [ -f "yarn.lock" ]; then
    log "Using Yarn (via Corepack) to install dependencies..."
    corepack enable || true
    corepack prepare yarn@stable --activate || true
    if [ -f "package.json" ]; then
      yarn install --frozen-lockfile || yarn install
    fi
  elif [ -f "pnpm-lock.yaml" ]; then
    log "Using pnpm (via Corepack) to install dependencies..."
    corepack enable || true
    corepack prepare pnpm@latest --activate || true
    if [ -f "package.json" ]; then
      pnpm install --frozen-lockfile || pnpm install
    fi
  elif [ -f "package.json" ]; then
    log "Using npm to install dependencies..."
    if [ -f "package-lock.json" ] || [ -f "npm-shrinkwrap.json" ]; then
      npm ci || npm install
    else
      npm install
    fi
  fi
}

# Python installation and dependencies
install_python_env() {
  if [ "${HAS_PYTHON}" != "true" ]; then return; fi
  log "Configuring Python environment..."
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found, attempting to install via package manager."
    install_base_system_tools
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 could not be installed."
  fi

  local venv_dir="${APP_DIR}/.venv"
  if [ ! -d "${venv_dir}" ]; then
    python3 -m venv "${venv_dir}"
  fi
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"
  pip install --no-cache-dir --upgrade pip setuptools wheel

  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    if grep -q "tool.poetry" pyproject.toml 2>/dev/null; then
      log "Poetry project detected. Installing Poetry and dependencies..."
      pip install --no-cache-dir poetry
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi
    else
      log "PEP 517/518 pyproject detected. Installing project with pip..."
      pip install --no-cache-dir -e .
    fi
  elif [ -f "Pipfile" ]; then
    log "Pipenv project detected. Installing pipenv and dependencies..."
    pip install --no-cache-dir pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  fi

  ensure_profile_env PYTHONDONTWRITEBYTECODE="1" PYTHONUNBUFFERED="1" PIP_NO_CACHE_DIR="1"
}

# Java installation (JDK/Maven/Gradle)
install_java_env() {
  if [ "${HAS_JAVA}" != "true" ]; then return; fi
  log "Configuring Java environment..."
  detect_pkg_manager
  case "${PKG_MGR}" in
    apt)
      pkg_update
      pkg_install "openjdk-${DEFAULT_JAVA_VERSION}-jdk" maven
      ;;
    apk)
      pkg_update
      # Alpine package names vary by branch; try openjdk17-jdk else fallback
      apk add --no-cache "openjdk${DEFAULT_JAVA_VERSION}-jdk" maven || apk add --no-cache openjdk17-jdk maven || true
      ;;
    microdnf|dnf|yum)
      pkg_update
      pkg_install "java-${DEFAULT_JAVA_VERSION}-openjdk" "java-${DEFAULT_JAVA_VERSION}-openjdk-devel" maven || true
      ;;
    zypper)
      pkg_update
      pkg_install "java-${DEFAULT_JAVA_VERSION}-openjdk" "java-${DEFAULT_JAVA_VERSION}-openjdk-devel" maven || true
      ;;
  esac
  pkg_clean || true

  # Gradle wrapper/Maven wrapper support
  if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
    ./gradlew --no-daemon -x test build || ./gradlew --no-daemon dependencies || true
  elif [ -f "mvnw" ]; then
    chmod +x mvnw
    ./mvnw -B -DskipTests dependency:go-offline || true
  elif [ -f "pom.xml" ]; then
    mvn -B -DskipTests dependency:go-offline || true
  fi

  # Set JAVA_HOME if possible
  if command -v javac >/dev/null 2>&1; then
    local javapath
    javapath="$(readlink -f "$(command -v javac)")" || true
    local java_home="${javapath%/bin/javac}"
    ensure_profile_env JAVA_HOME="${java_home}"
  fi
}

# Go installation
install_go_env() {
  if [ "${HAS_GO}" != "true" ]; then return; fi
  log "Configuring Go environment..."
  if ! command -v go >/dev/null 2>&1; then
    local arch="$(uname -m)"
    local go_arch="amd64"
    case "${arch}" in
      x86_64) go_arch="amd64" ;;
      aarch64|arm64) go_arch="arm64" ;;
      armv7l) go_arch="armv6l" ;; # closest available; may vary
    esac
    local url="https://go.dev/dl/go${DEFAULT_GO_VERSION}.linux-${go_arch}.tar.gz"
    curl -fsSL "${url}" -o /tmp/go.tgz
    rm -rf /usr/local/go
    tar -xzf /tmp/go.tgz -C /usr/local
    rm -f /tmp/go.tgz
    ensure_profile_env PATH="${PATH}:/usr/local/go/bin" GOPATH="/go" GOCACHE="/go/.cache" CGO_ENABLED="1"
    mkdir -p /go/bin /go/pkg /go/src /go/.cache
  fi
  # Download dependencies
  if [ -f "go.mod" ]; then
    export GOPATH="${GOPATH:-/go}"
    export GOCACHE="${GOCACHE:-/go/.cache}"
    go env -w GOPATH="${GOPATH}" || true
    go env -w GOCACHE="${GOCACHE}" || true
    go mod download
  fi
}

# Rust installation
install_rust_env() {
  if [ "${HAS_RUST}" != "true" ]; then return; fi
  log "Configuring Rust environment..."
  local rustup_home="/opt/rust/rustup"
  local cargo_home="/opt/rust/cargo"
  mkdir -p "${rustup_home}" "${cargo_home}"
  ensure_profile_env RUSTUP_HOME="${rustup_home}" CARGO_HOME="${cargo_home}" PATH="${PATH}:${cargo_home}/bin"
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    chmod +x /tmp/rustup.sh
    RUSTUP_HOME="${rustup_home}" CARGO_HOME="${cargo_home}" /tmp/rustup.sh -y --no-modify-path --profile minimal
    rm -f /tmp/rustup.sh
  fi
  if [ -f "Cargo.toml" ]; then
    "${cargo_home}/bin/cargo" fetch || true
  fi
}

# PHP + Composer
install_php_env() {
  if [ "${HAS_PHP}" != "true" ]; then return; fi
  log "Configuring PHP environment..."
  detect_pkg_manager
  case "${PKG_MGR}" in
    apt)
      pkg_update
      pkg_install php-cli php-zip php-mbstring php-xml php-curl php-openssl php-json php-phar php-tokenizer unzip
      ;;
    apk)
      pkg_update
      # Alpine packages vary by version; try php82 first, else fallback to php
      apk add --no-cache php82 php82-cli php82-openssl php82-zip php82-mbstring php82-xml php82-curl php82-json php82-phar unzip || \
      apk add --no-cache php php-cli php-openssl php-zip php-mbstring php-xml php-curl php-json php-phar unzip
      ;;
    microdnf|dnf|yum)
      pkg_update
      pkg_install php-cli php-json php-mbstring php-xml php-common php-openssl php-zip php-curl unzip || true
      ;;
    zypper)
      pkg_update
      pkg_install php8 php8-cli php8-json php8-mbstring php8-xml php8-openssl php8-zip php8-curl unzip || true
      ;;
  esac
  pkg_clean || true

  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer >/dev/null
    rm -f /tmp/composer-setup.php
  fi
  export COMPOSER_ALLOW_SUPERUSER=1
  if [ -f "composer.lock" ]; then
    composer install --no-interaction --prefer-dist --no-progress --optimize-autoloader
  else
    composer install --no-interaction --prefer-dist --no-progress || true
  fi
}

# Ruby + Bundler
install_ruby_env() {
  if [ "${HAS_RUBY}" != "true" ]; then return; fi
  log "Configuring Ruby environment..."
  detect_pkg_manager
  case "${PKG_MGR}" in
    apt)
      pkg_update
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_update
      pkg_install ruby ruby-dev build-base
      ;;
    microdnf|dnf|yum)
      pkg_update
      pkg_install ruby ruby-devel make gcc gcc-c++
      ;;
    zypper)
      pkg_update
      pkg_install ruby ruby-devel make gcc gcc-c++
      ;;
  esac
  pkg_clean || true

  if ! command -v gem >/dev/null 2>&1; then
    die "Ruby gem tool not found after installation."
  fi
  gem install bundler --no-document || true
  if [ -f "Gemfile" ]; then
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs 4 --retry 3
  fi
}

# .NET SDK via dotnet-install.sh
install_dotnet_env() {
  if [ "${HAS_DOTNET}" != "true" ]; then return; fi
  log "Configuring .NET SDK..."
  local dotnet_root="/opt/dotnet"
  mkdir -p "${dotnet_root}"
  if [ ! -x "${dotnet_root}/dotnet" ]; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir "${dotnet_root}" --channel "${DEFAULT_DOTNET_CHANNEL}" --quality ga
    rm -f /tmp/dotnet-install.sh
  fi
  ensure_profile_env DOTNET_ROOT="${dotnet_root}" PATH="${PATH}:${dotnet_root}"
  export DOTNET_CLI_TELEMETRY_OPTOUT=1
  export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

  # Restore dependencies if csproj/sln present
  if ls *.sln *.csproj >/dev/null 2>&1; then
    "${dotnet_root}/dotnet" restore || true
  fi
}

# Environment file
ensure_env_file() {
  local env_file="${APP_DIR}/.env"
  if [ ! -f "${env_file}" ]; then
    log "Creating default .env file..."
    {
      echo "APP_ENV=production"
      echo "TZ=${TZ}"
      echo "PORT=3000"
      echo "PYTHONUNBUFFERED=1"
      echo "PYTHONDONTWRITEBYTECODE=1"
      echo "PIP_NO_CACHE_DIR=1"
      echo "NODE_ENV=production"
      echo "COMPOSER_ALLOW_SUPERUSER=1"
      echo "DOTNET_CLI_TELEMETRY_OPTOUT=1"
      echo "DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1"
    } > "${env_file}"
  fi
}

# Permissions
fix_permissions() {
  if [ -n "${APP_USER}" ] && id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true
  fi
}

# Summary and usage hints
print_summary() {
  log "Environment setup completed successfully."
  echo "Summary:"
  echo " - App directory: ${APP_DIR}"
  echo " - Detected: node=${HAS_NODE}, python=${HAS_PYTHON}, java=${HAS_JAVA}, go=${HAS_GO}, rust=${HAS_RUST}, php=${HAS_PHP}, ruby=${HAS_RUBY}, dotnet=${HAS_DOTNET}"
  echo " - .env created if missing at ${APP_DIR}/.env"
  echo " - PATH and env persisted to /etc/profile.d/zz-project-env.sh (if writable)."
  echo
  echo "Common run hints (adjust for your project):"
  if [ "${HAS_NODE}" = "true" ]; then
    echo " - Node.js: npm run start (or yarn start), PORT defaults to 3000"
  fi
  if [ "${HAS_PYTHON}" = "true" ]; then
    echo " - Python: source .venv/bin/activate && python app.py (or your WSGI/ASGI server), PORT commonly 5000/8000"
  fi
  if [ "${HAS_JAVA}" = "true" ]; then
    echo " - Java: mvn spring-boot:run or ./gradlew bootRun (if applicable)"
  fi
  if [ "${HAS_GO}" = "true" ]; then
    echo " - Go: go run ./... or go build ./..."
  fi
  if [ "${HAS_RUST}" = "true" ]; then
    echo " - Rust: cargo run --release"
  fi
  if [ "${HAS_PHP}" = "true" ]; then
    echo " - PHP: php -S 0.0.0.0:8000 -t public (for simple server)"
  fi
  if [ "${HAS_RUBY}" = "true" ]; then
    echo " - Ruby: bundle exec rails server -b 0.0.0.0"
  fi
  if [ "${HAS_DOTNET}" = "true" ]; then
    echo " - .NET: dotnet run --project YourProject.csproj"
  fi
}

rocketmq_setup_and_test() {
  # Run RocketMQ-specific integration to prepare environment and execute tests
  if [ "${HAS_JAVA}" != "true" ]; then return; fi
  if [ ! -f "pom.xml" ]; then return; fi
  if ! grep -qF "rocketmq" "pom.xml" 2>/dev/null; then
    # Not a RocketMQ project, skip
    return
  fi

  # Ensure JDK 11 and procps (for pkill) are available on Debian/Ubuntu
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y openjdk-11-jdk procps || true
    # Prefer JDK 11 during Maven runs
    if [ -d "/usr/lib/jvm/java-11-openjdk-amd64" ]; then
      export JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
      export PATH="${JAVA_HOME}/bin:${PATH}"
    fi
  fi

  log "Building project with tests skipped (mvn package -DskipTests)..."
  mvn -B -DskipTests package || die "Maven package failed."

  # Start NameServer and Broker for tests
  log "Starting RocketMQ NameServer and Broker for tests..."
  pkill -f 'org.apache.rocketmq.namesrv.NamesrvStartup' >/dev/null 2>&1 || true
  pkill -f 'org.apache.rocketmq.broker.BrokerStartup' >/dev/null 2>&1 || true
  BIN_DIR="$(dirname "$(find . -type f -name mqnamesrv -path "*/target/*/bin/*" -print -quit)")"
  if [ -n "${BIN_DIR}" ] && [ -x "${BIN_DIR}/mqnamesrv" ]; then
    export ROCKETMQ_HOME="$(dirname "${BIN_DIR}")"
    nohup sh "${BIN_DIR}/mqnamesrv" >/tmp/mqnamesrv.out 2>&1 &
    sleep 3
    nohup sh "${BIN_DIR}/mqbroker" -n localhost:9876 >/tmp/mqbroker.out 2>&1 &
  else
    warn "Could not locate mqnamesrv script under target/*/bin/*; RocketMQ services may not start."
  fi

  # Run Maven tests with IPv4 preference and a small rerun count for flakiness
  log "Running Maven tests with IPv4 preference..."
  MAVEN_OPTS="-Djava.net.preferIPv4Stack=true" mvn -B -Dsurefire.rerunFailingTestsCount=1 test || true

  # Print surefire report excerpts for debugging
  log "Printing surefire reports (first 1000 lines across files)..."
  find . -type f -path "*/target/surefire-reports/*" \( -name "*.txt" -o -name "*.xml" \) -exec sed -n '1,200p' {} + | sed -n '1,1000p' || true
}

main() {
  log "Starting environment setup in Docker-friendly mode..."
  install_base_system_tools
  ensure_app_user
  setup_directories
  detect_project_types

  # Set generic env
  ensure_profile_env LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}" TZ="${TZ}" APP_DIR="${APP_DIR}"

  # Install runtimes and deps based on detection
  install_node
  install_python_env
  install_java_env
  install_go_env
  install_rust_env
  install_php_env
  install_ruby_env
  install_dotnet_env

  # RocketMQ-specific setup and test run (if applicable)
  rocketmq_setup_and_test

  ensure_env_file
  fix_permissions
  print_summary
}

main "$@"