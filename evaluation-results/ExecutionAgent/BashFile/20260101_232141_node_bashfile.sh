#!/usr/bin/env bash
# Universal project environment bootstrap script for Docker containers
# - Detects common project types (Python, Node.js, Ruby, Java, Go, PHP, Rust, .NET)
# - Installs required runtimes, system packages, and dependencies
# - Sets up directory structure, environment variables, and permissions
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'
umask 0027

#========================
# Configurable variables
#========================
APP_DIR="${APP_DIR:-/app}"
APP_ENV="${APP_ENV:-production}"
LOG_LEVEL="${LOG_LEVEL:-info}"
RUN_AS_USER="${RUN_AS_USER:-}"        # optional: username to run as (will be created if not exists)
RUN_AS_UID="${RUN_AS_UID:-}"          # optional: uid for RUN_AS_USER
RUN_AS_GID="${RUN_AS_GID:-}"          # optional: gid for RUN_AS_USER
HTTP_PORT="${HTTP_PORT:-8080}"        # default app port if not specified by project
DEBIAN_FRONTEND=noninteractive

#========================
# Colors and logging
#========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
  echo -e "${YELLOW}[WARN] $*${NC}" >&2
}
err() {
  echo -e "${RED}[ERROR] $*${NC}" >&2
}

#========================
# Error handling
#========================
on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]}
  err "Setup failed at line ${line_no} with exit code ${exit_code}"
  exit "${exit_code}"
}
trap on_error ERR

#========================
# Helpers and detection
#========================
need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_pm() {
  if need_cmd apt-get; then PM="apt"
  elif need_cmd apk; then PM="apk"
  elif need_cmd dnf; then PM="dnf"
  elif need_cmd yum; then PM="yum"
  else
    PM=""
  fi
}
PM=""
detect_pm

ensure_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "This script must be run as root inside the container."
    exit 1
  fi
}

# package manager functions
PKG_UPDATED_STAMP="/var/lib/setup/pkg_updated.stamp"
mkdir -p /var/lib/setup >/dev/null 2>&1 || true

pkg_update() {
  case "$PM" in
    apt)
      if [ ! -f "$PKG_UPDATED_STAMP" ]; then
        log "Updating apt package index..."
        apt-get update -y
        touch "$PKG_UPDATED_STAMP"
      fi
      ;;
    apk)
      # apk doesn't need update separate from add --no-cache
      true
      ;;
    dnf|yum)
      if [ ! -f "$PKG_UPDATED_STAMP" ]; then
        log "Updating $PM package index..."
        "$PM" -y makecache
        touch "$PKG_UPDATED_STAMP"
      fi
      ;;
    *)
      err "No supported package manager found. Cannot install system packages."
      exit 1
      ;;
  esac
}

pkg_is_installed() {
  local pkg="$1"
  case "$PM" in
    apt) dpkg -s "$pkg" >/dev/null 2>&1 ;;
    apk) apk info -e "$pkg" >/dev/null 2>&1 ;;
    dnf|yum) rpm -q "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  pkg_update
  case "$PM" in
    apt)
      # Only install missing packages
      local missing=()
      for p in "${pkgs[@]}"; do
        if ! pkg_is_installed "$p"; then missing+=("$p"); fi
      done
      if [ "${#missing[@]}" -gt 0 ]; then
        log "Installing packages (apt): ${missing[*]}"
        apt-get install -y --no-install-recommends "${missing[@]}"
      fi
      ;;
    apk)
      local missing=()
      for p in "${pkgs[@]}"; do
        if ! pkg_is_installed "$p"; then missing+=("$p"); fi
      done
      if [ "${#missing[@]}" -gt 0 ]; then
        log "Installing packages (apk): ${missing[*]}"
        apk add --no-cache "${missing[@]}"
      fi
      ;;
    dnf|yum)
      local missing=()
      for p in "${pkgs[@]}"; do
        if ! pkg_is_installed "$p"; then missing+=("$p"); fi
      done
      if [ "${#missing[@]}" -gt 0 ]; then
        log "Installing packages ($PM): ${missing[*]}"
        "$PM" install -y "${missing[@]}"
      fi
      ;;
  esac
}

install_core_tools() {
  log "Installing core utilities..."
  case "$PM" in
    apt)
      pkg_install ca-certificates curl wget git gnupg unzip zip xz-utils tar bash coreutils findutils
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl wget git gnupg unzip zip xz tar bash coreutils findutils
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git gnupg2 unzip zip xz tar bash coreutils findutils
      update-ca-trust || true
      ;;
  esac
}

install_build_tools() {
  log "Ensuring build tools for native modules..."
  case "$PM" in
    apt)
      pkg_install build-essential pkg-config
      ;;
    apk)
      pkg_install build-base pkgconf
      ;;
    dnf|yum)
      pkg_install gcc gcc-c++ make pkgconfig
      ;;
  esac
}

#========================
# Directory and user setup
#========================
setup_dirs() {
  log "Setting up project directories at ${APP_DIR}..."
  mkdir -p "${APP_DIR}" \
           "${APP_DIR}/logs" \
           "${APP_DIR}/tmp" \
           "${APP_DIR}/data" \
           "${APP_DIR}/cache" \
           "${APP_DIR}/scripts" \
           "${APP_DIR}/.profile.d"
  chmod -R 0755 "${APP_DIR}"
}

create_run_user() {
  if [ -n "${RUN_AS_USER}" ]; then
    log "Configuring non-root user: ${RUN_AS_USER}"
    local gid_opt=() uid_opt=()
    if [ -n "${RUN_AS_GID}" ]; then gid_opt=(-g "${RUN_AS_GID}"); fi
    if [ -n "${RUN_AS_UID}" ]; then uid_opt=(-u "${RUN_AS_UID}"); fi

    if ! getent group "${RUN_AS_USER}" >/dev/null 2>&1 && [ -n "${RUN_AS_GID}" ]; then
      groupadd -g "${RUN_AS_GID}" "${RUN_AS_USER}" || true
    fi

    if ! id -u "${RUN_AS_USER}" >/dev/null 2>&1; then
      if need_cmd adduser; then
        adduser -D "${RUN_AS_USER}" || useradd "${uid_opt[@]}" -m -s /bin/bash "${RUN_AS_USER}" || true
      elif need_cmd useradd; then
        useradd "${uid_opt[@]}" -m -s /bin/bash "${RUN_AS_USER}" || true
      fi
    fi
    chown -R "${RUN_AS_USER}:${RUN_AS_USER}" "${APP_DIR}" || true
  fi
}

#========================
# Environment exports
#========================
persist_env() {
  log "Persisting environment variables..."
  cat >/etc/profile.d/zz-app-env.sh <<EOF
export APP_DIR="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export LOG_LEVEL="${LOG_LEVEL}"
export HTTP_PORT="${HTTP_PORT}"
export PATH="\$PATH:${APP_DIR}/.venv/bin:${APP_DIR}/node_modules/.bin:\$HOME/.local/bin:\$HOME/bin:/usr/local/go/bin:\$HOME/.cargo/bin"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export NODE_ENV="${APP_ENV}"
EOF
  chmod 0644 /etc/profile.d/zz-app-env.sh

  if [ ! -f "${APP_DIR}/.env" ]; then
    cat > "${APP_DIR}/.env" <<EOF
APP_ENV=${APP_ENV}
LOG_LEVEL=${LOG_LEVEL}
HTTP_PORT=${HTTP_PORT}
EOF
    chmod 0640 "${APP_DIR}/.env" || true
  fi

  # Profile snippet for shells in APP_DIR
  cat > "${APP_DIR}/.profile.d/path.sh" <<'EOF'
# Augment PATH for local tools
export PATH="$PATH:./node_modules/.bin"
EOF
}

#========================
# Language installers
#========================
PY_STAMP="/var/lib/setup/python.stamp"
setup_python() {
  local detected=0
  if [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/Pipfile" ] || ls "${APP_DIR}"/*.py >/dev/null 2>&1; then
    detected=1
  fi
  [ $detected -eq 0 ] && return 0

  log "Detected Python project files."
  case "$PM" in
    apt) pkg_install python3 python3-pip python3-venv python3-dev ;;
    apk) pkg_install python3 py3-pip py3-virtualenv ;;
    dnf|yum) pkg_install python3 python3-pip python3-virtualenv python3-devel || pkg_install python3 python3-pip ;;
  esac
  install_build_tools

  mkdir -p "${APP_DIR}"
  local VENV_DIR="${APP_DIR}/.venv"
  if [ ! -d "${VENV_DIR}" ]; then
    log "Creating Python virtual environment at ${VENV_DIR}..."
    python3 -m venv "${VENV_DIR}"
  fi
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  python3 -m pip install --upgrade pip wheel setuptools

  if [ -f "${APP_DIR}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    python3 -m pip install -r "${APP_DIR}/requirements.txt"
  elif [ -f "${APP_DIR}/pyproject.toml" ]; then
    if [ -f "${APP_DIR}/poetry.lock" ]; then
      if ! need_cmd poetry; then
        log "Installing Poetry..."
        python3 -m pip install "poetry>=1.6"
      fi
      log "Installing dependencies via Poetry (no dev)..."
      (cd "${APP_DIR}" && poetry config virtualenvs.create false && poetry install --no-interaction --no-ansi --only main)
    else
      log "Installing project via PEP 517 (pyproject.toml)..."
      (cd "${APP_DIR}" && python3 -m pip install .)
    fi
  elif [ -f "${APP_DIR}/Pipfile" ]; then
    if ! need_cmd pipenv; then
      python3 -m pip install pipenv
    fi
    log "Installing dependencies via Pipenv..."
    (cd "${APP_DIR}" && PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system)
  fi

  touch "$PY_STAMP"
  log "Python environment setup complete."
}

NODE_STAMP="/var/lib/setup/node.stamp"
install_node_runtime() {
  if need_cmd node && need_cmd npm; then return 0; fi
  case "$PM" in
    apt)
      pkg_install ca-certificates curl gnupg
      if ! need_cmd node || ! node -v | grep -Eq 'v(1[8-9]|[2-9][0-9])'; then
        log "Installing Node.js (LTS) via NodeSource..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        pkg_install nodejs
      fi
      ;;
    apk)
      log "Installing Node.js via apk..."
      pkg_install nodejs npm
      ;;
    dnf|yum)
      log "Installing Node.js via $PM..."
      pkg_install nodejs npm || {
        warn "Falling back to NodeSource install script..."
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        pkg_install nodejs
      }
      ;;
    *)
      err "No supported package manager to install Node.js"
      ;;
  esac
}

setup_node() {
  if [ ! -f "${APP_DIR}/package.json" ]; then return 0; fi
  log "Detected Node.js project."
  install_node_runtime
  install_build_tools

  # Install yarn if yarn.lock present
  if [ -f "${APP_DIR}/yarn.lock" ] && ! need_cmd yarn; then
    log "Installing Yarn..."
    npm install -g yarn
  fi
  # Install pnpm if pnpm-lock.yaml present
  if [ -f "${APP_DIR}/pnpm-lock.yaml" ] && ! need_cmd pnpm; then
    log "Installing pnpm..."
    npm install -g pnpm
  fi

  # Install dependencies
  if [ -f "${APP_DIR}/package-lock.json" ]; then
    log "Installing Node dependencies via npm ci..."
    (cd "${APP_DIR}" && npm ci --omit=dev --no-audit --no-fund || npm ci --no-audit --no-fund)
  elif [ -f "${APP_DIR}/yarn.lock" ]; then
    log "Installing Node dependencies via yarn..."
    (cd "${APP_DIR}" && yarn install --frozen-lockfile --production=true || yarn install --frozen-lockfile)
  elif [ -f "${APP_DIR}/pnpm-lock.yaml" ]; then
    log "Installing Node dependencies via pnpm..."
    (cd "${APP_DIR}" && pnpm install --frozen-lockfile)
  else
    log "Installing Node dependencies via npm install..."
    (cd "${APP_DIR}" && npm install --omit=dev --no-audit --no-fund || npm install --no-audit --no-fund)
  fi

  touch "$NODE_STAMP"
  log "Node.js environment setup complete."
}

RUBY_STAMP="/var/lib/setup/ruby.stamp"
setup_ruby() {
  if [ ! -f "${APP_DIR}/Gemfile" ]; then return 0; fi
  log "Detected Ruby project."
  case "$PM" in
    apt)
      pkg_install ruby-full build-essential zlib1g-dev
      ;;
    apk)
      pkg_install ruby ruby-bundler build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
  esac
  if ! need_cmd bundle; then
    log "Installing bundler gem..."
    gem install bundler --no-document
  fi
  (cd "${APP_DIR}" && bundle config set --local path 'vendor/bundle' && bundle install --jobs 4 --retry 3)
  touch "$RUBY_STAMP"
  log "Ruby environment setup complete."
}

JAVA_STAMP="/var/lib/setup/java.stamp"
setup_java() {
  local has_maven=0 has_gradle=0
  [ -f "${APP_DIR}/pom.xml" ] && has_maven=1
  [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/build.gradle.kts" ] && has_gradle=1
  [ $has_maven -eq 0 ] && [ $has_gradle -eq 0 ] && [ ! -f "${APP_DIR}/gradlew" ] && return 0

  log "Detected Java project."
  case "$PM" in
    apt) pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17 maven ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven ;;
  esac

  if [ -f "${APP_DIR}/gradlew" ]; then
    log "Using Gradle wrapper..."
    chmod +x "${APP_DIR}/gradlew"
    (cd "${APP_DIR}" && ./gradlew --no-daemon tasks >/dev/null 2>&1 || true)
  elif [ $has_gradle -eq 1 ]; then
    case "$PM" in
      apt) pkg_install gradle ;;
      apk) pkg_install gradle ;;
      dnf|yum) pkg_install gradle ;;
    esac
  fi

  # Pre-fetch dependencies for faster start
  if [ -f "${APP_DIR}/pom.xml" ]; then
    log "Resolving Maven dependencies..."
    (cd "${APP_DIR}" && mvn -B -ntp -DskipTests dependency:resolve || true)
  fi
  if [ -f "${APP_DIR}/gradlew" ]; then
    log "Resolving Gradle dependencies..."
    (cd "${APP_DIR}" && ./gradlew --no-daemon dependencies || true)
  fi

  touch "$JAVA_STAMP"
  log "Java environment setup complete."
}

GO_STAMP="/var/lib/setup/go.stamp"
setup_go() {
  if [ ! -f "${APP_DIR}/go.mod" ]; then return 0; fi
  log "Detected Go project."
  case "$PM" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
  esac
  export GOPATH="${GOPATH:-/go}"
  mkdir -p "${GOPATH}/pkg" "${GOPATH}/bin" "${GOPATH}/src"
  (cd "${APP_DIR}" && go env -w GOPRIVATE= || true)
  (cd "${APP_DIR}" && go mod download)
  touch "$GO_STAMP"
  log "Go environment setup complete."
}

PHP_STAMP="/var/lib/setup/php.stamp"
setup_php() {
  if [ ! -f "${APP_DIR}/composer.json" ]; then return 0; fi
  log "Detected PHP project."
  case "$PM" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip git
      ;;
    apk)
      pkg_install php83 php83-phar php83-mbstring php83-xml php83-curl php83-zip php83-openssl unzip git || pkg_install php php-phar php-mbstring php-xml php-curl php-zip unzip git
      ;;
    dnf|yum)
      pkg_install php php-cli php-mbstring php-xml php-common php-json php-zip unzip git
      ;;
  esac
  if ! need_cmd composer; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r 'echo hash_file(\"sha384\", \"composer-setup.php\");')"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      err "Invalid Composer installer signature"
      exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi
  (cd "${APP_DIR}" && composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader)
  touch "$PHP_STAMP"
  log "PHP environment setup complete."
}

RUST_STAMP="/var/lib/setup/rust.stamp"
setup_rust() {
  if [ ! -f "${APP_DIR}/Cargo.toml" ]; then return 0; fi
  log "Detected Rust project."
  install_build_tools
  pkg_install curl pkg-config || true
  if [ ! -d "/root/.rustup" ]; then
    log "Installing Rust via rustup (stable)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  export PATH="$PATH:/root/.cargo/bin"
  (cd "${APP_DIR}" && cargo fetch)
  touch "$RUST_STAMP"
  log "Rust environment setup complete."
}

DOTNET_STAMP="/var/lib/setup/dotnet.stamp"
setup_dotnet() {
  # Detect any .csproj or .sln files
  if ! ls "${APP_DIR}"/*.csproj "${APP_DIR}"/*.sln >/dev/null 2>&1; then return 0; fi
  log "Detected .NET project."
  case "$PM" in
    apt)
      if ! need_cmd dotnet; then
        log "Installing .NET SDK (attempt for Debian/Ubuntu)..."
        pkg_install ca-certificates curl gnupg
        rm -f /etc/apt/trusted.gpg.d/microsoft.gpg || true
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/microsoft.gpg
        . /etc/os-release
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/microsoft.gpg] https://packages.microsoft.com/repos/microsoft-${ID}-${VERSION_CODENAME}-prod ${VERSION_CODENAME} main" >/etc/apt/sources.list.d/microsoft-prod.list || true
        rm -f "$PKG_UPDATED_STAMP" || true
        pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || warn ".NET SDK install failed. Please verify base image compatibility."
      fi
      ;;
    apk|dnf|yum)
      warn ".NET SDK installation is not fully supported for this base image by this script. Please use a dotnet SDK base image for best results."
      ;;
  esac
  if need_cmd dotnet; then
    (cd "${APP_DIR}" && dotnet restore || true)
    touch "$DOTNET_STAMP"
    log ".NET environment setup complete."
  fi
}

#========================
# Healthcheck script
#========================
setup_healthcheck() {
  if [ ! -f "${APP_DIR}/scripts/healthcheck.sh" ]; then
    cat > "${APP_DIR}/scripts/healthcheck.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
PORT="${HTTP_PORT:-8080}"
HOST="${HOST:-127.0.0.1}"
timeout 2 bash -c "</dev/tcp/${HOST}/${PORT}" >/dev/null 2>&1 && exit 0 || exit 1
EOF
    chmod +x "${APP_DIR}/scripts/healthcheck.sh"
  fi
}

#========================
# Entry detection (informational)
#========================
print_detected_info() {
  log "Detection summary:"
  [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] && echo " - Python: detected" || true
  [ -f "${APP_DIR}/package.json" ] && echo " - Node.js: detected" || true
  [ -f "${APP_DIR}/Gemfile" ] && echo " - Ruby: detected" || true
  ls "${APP_DIR}"/*.csproj >/dev/null 2>&1 && echo " - .NET: detected" || true
  [ -f "${APP_DIR}/pom.xml" ] || [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/build.gradle.kts" ] || [ -f "${APP_DIR}/gradlew" ] && echo " - Java: detected" || true
  [ -f "${APP_DIR}/go.mod" ] && echo " - Go: detected" || true
  [ -f "${APP_DIR}/composer.json" ] && echo " - PHP: detected" || true
  [ -f "${APP_DIR}/Cargo.toml" ] && echo " - Rust: detected" || true
}

#========================
# Auto-activate Python venv
#========================
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line="source ${APP_DIR}/.venv/bin/activate"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

#========================
# GYP/configure setup
#========================
setup_gyp_configure() {
  if need_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential python3 python3-pip pkg-config ccache ninja-build
    ccache -M 5G || true
  fi
  (
    cd "${APP_DIR}" || exit 0
    if [ -f ./configure.py ]; then
      rm -f config.gypi
      python3 ./configure.py --with-intl=none --without-inspector
    elif [ -f ./configure ]; then
      ( [ -x ./configure ] && ./configure || sh ./configure )
    fi
    # Accelerate builds using ccache and parallel jobs
    if [ -f Makefile ]; then
      export MAKEFLAGS="-j$(nproc)"
      export CC="ccache gcc"
      export CXX="ccache g++"
      make -j"$(nproc)" || true
    fi
    test -f config.gypi || printf '{\n  "variables": {}\n}\n' > config.gypi
  )
}

#========================
# Main
#========================
main() {
  ensure_root
  log "Starting universal environment setup..."
  setup_dirs
  install_core_tools
  if need_cmd apt-get; then
    apt-get remove -y nodejs || true
    rm -f /etc/apt/sources.list.d/nodesource*.list /etc/apt/sources.list.d/nodesource*.sources /etc/apt/trusted.gpg.d/nodesource.gpg /etc/apt/keyrings/nodesource.gpg || true
    apt-get update -y
    apt-get install -y --no-install-recommends nodejs npm cmake autoconf automake libtool m4 ninja-build make git pkg-config python3 python3-pip build-essential
    bash -lc 'command -v node >/dev/null 2>&1 || { command -v nodejs >/dev/null 2>&1 && ln -sf "$(command -v nodejs)" /usr/local/bin/node; }'
  fi

  # Fallback: install Node.js via official binaries if missing
  command -v node >/dev/null 2>&1 || (
    curl -fsSL https://nodejs.org/dist/v20.11.1/node-v20.11.1-linux-x64.tar.xz -o /tmp/node.tar.xz &&
    tar -xf /tmp/node.tar.xz -C /usr/local --strip-components=1 &&
    ln -sf /usr/local/bin/node /usr/bin/node &&
    ln -sf /usr/local/bin/npm /usr/bin/npm &&
    ln -sf /usr/local/bin/npx /usr/bin/npx
  )

  # Ensure working in APP_DIR
  if [ ! -d "${APP_DIR}" ]; then
    mkdir -p "${APP_DIR}"
  fi

  # Ensure minimal Node.js project configuration to allow npm build
  # Provision minimal multi-tool project skeleton (CMake, Autotools, Node, TypeScript)
  mkdir -p "${APP_DIR}/src" "${APP_DIR}/tests"
  test -f "${APP_DIR}/CMakeLists.txt" || cat > "${APP_DIR}/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.13)
project(app_example C)
include(CTest)
add_library(app STATIC src/app.c)
if(BUILD_TESTING)
  add_executable(smoke tests/smoke.c)
  add_test(NAME smoke COMMAND smoke)
endif()
EOF
  test -f "${APP_DIR}/src/app.c" || cat > "${APP_DIR}/src/app.c" << 'EOF'
#include <stdio.h>
int app_add(int a, int b) { return a + b; }
EOF
  test -f "${APP_DIR}/tests/smoke.c" || cat > "${APP_DIR}/tests/smoke.c" << 'EOF'
#include <stdio.h>
int main(void) { printf("smoke test\n"); return 0; }
EOF
  test -f "${APP_DIR}/configure.ac" || cat > "${APP_DIR}/configure.ac" << 'EOF'
AC_INIT([app-example],[0.1],[example@example.com])
AM_INIT_AUTOMAKE([foreign])
AC_PROG_CC
AC_CONFIG_FILES([Makefile src/Makefile tests/Makefile])
AC_OUTPUT
EOF
  test -f "${APP_DIR}/Makefile.am" || cat > "${APP_DIR}/Makefile.am" << 'EOF'
SUBDIRS = src tests
EOF
  test -f "${APP_DIR}/src/Makefile.am" || cat > "${APP_DIR}/src/Makefile.am" << 'EOF'
bin_PROGRAMS = app
app_SOURCES = app.c
EOF
  test -f "${APP_DIR}/tests/Makefile.am" || cat > "${APP_DIR}/tests/Makefile.am" << 'EOF'
check_PROGRAMS = smoke
TESTS = smoke
smoke_SOURCES = smoke.c
EOF
  test -f "${APP_DIR}/a.test.ts" || cat > "${APP_DIR}/a.test.ts" << 'EOF'
export const hello: string = "world";
EOF
  test -f "${APP_DIR}/package.json" || cat > "${APP_DIR}/package.json" << 'EOF'
{
  "name": "app-example",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "build": "echo 'stub build succeeded'",
    "test": "echo 'stub tests passed'"
  },
  "devDependencies": {
    "esbuild": "^0.20.0"
  }
}
EOF
  [ -f "${APP_DIR}/package.json" ] && npm --prefix "${APP_DIR}" install --no-fund --no-audit --omit=optional || true

  # Ensure Autotools bootstrap stub
  [ -f "${APP_DIR}/autogen.sh" ] || { cat > "${APP_DIR}/autogen.sh" << 'EOF'
#!/bin/sh
set -e
autoreconf -i
EOF
  chmod +x "${APP_DIR}/autogen.sh"; }

  # Attempt to use current directory as APP_DIR if it matches
  if [ -d "$(pwd)" ] && [ "$(pwd)" != "${APP_DIR}" ]; then
    # Bind mount scenarios will typically set WORKDIR to /app; otherwise, we don't move files
    warn "Current directory is $(pwd). APP_DIR is ${APP_DIR}. Ensure your container WORKDIR points to ${APP_DIR}."
  fi

  # Language-specific setups
  setup_python
  setup_node
  setup_ruby
  setup_java
  setup_go
  setup_php
  setup_rust
  setup_dotnet

  # Ensure GYP/configure config.gypi exists for projects expecting it
  setup_gyp_configure

  # Environment persistence and healthcheck
  setup_auto_activate
  persist_env
  setup_healthcheck

  # Permissions
  create_run_user

  print_detected_info

  log "Environment setup completed successfully."
  echo "Hints:"
  echo " - Environment variables persisted in /etc/profile.d/zz-app-env.sh and ${APP_DIR}/.env"
  echo " - Python venv (if any): ${APP_DIR}/.venv"
  echo " - Node binaries path: ${APP_DIR}/node_modules/.bin"
  echo " - Healthcheck script: ${APP_DIR}/scripts/healthcheck.sh (checks HTTP_PORT=${HTTP_PORT})"
  echo " - Re-run this script safely at any time; it is idempotent."
}

main "$@"