#!/usr/bin/env bash
#
# Universal project environment bootstrapper for Docker containers
# - Detects project type and installs appropriate runtimes and dependencies
# - Installs required system packages and tools
# - Sets up directories, permissions, virtualenvs, and configs
# - Safe to run multiple times (idempotent)
# - Works as root or non-root user; no sudo required
#
# Usage: bash setup.sh
# Optional env vars:
#   PROJECT_ROOT=/app
#   APP_USER=app
#   APP_GROUP=app
#   APP_UID=1000
#   APP_GID=1000
#   APP_ENV=production
#   PORT=... (if not set, a default is chosen based on stack)
#   NODE_VERSION=18|20|lts/* (optional)
#   PYTHON_VERSION=3 (major) or explicit path (optional)
#   RUST_TOOLCHAIN=stable|nightly (optional)
#   JAVA_VERSION=17 (optional)

set -Eeuo pipefail
IFS=$'\n\t'

# Colors (fallback if not TTY)
if [ -t 1 ]; then
  RED=$'\e[0;31m'; GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'; BLUE=$'\e[0;34m'; NC=$'\e[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR] $*${NC}" >&2; }
status() { echo "${BLUE}==> $*${NC}"; }

cleanup() { :; }
trap 'error "An error occurred on line $LINENO"; exit 1' ERR
trap cleanup EXIT

# Defaults
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
APP_NAME_DEFAULT="$(basename "${PROJECT_ROOT}")"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

# Detect package manager
PKG_MANAGER=""
update_repos_once="false"
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    error "Unsupported base image: apt/apk/dnf/yum not found."
    exit 1
  fi
  log "Detected package manager: ${PKG_MANAGER}"
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      if [ "${update_repos_once}" = "false" ]; then
        status "Updating apt repositories..."
        apt-get update -y
        update_repos_once="true"
      fi
      ;;
    apk)
      # apk updates indexes per add; no separate update needed with --no-cache
      :
      ;;
    dnf|yum)
      :
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      # shellcheck disable=SC2086
      apt-get install -y --no-install-recommends ${pkgs[*]}
      ;;
    apk)
      # shellcheck disable=SC2086
      apk add --no-cache ${pkgs[*]}
      ;;
    dnf)
      # shellcheck disable=SC2086
      dnf install -y ${pkgs[*]}
      ;;
    yum)
      # shellcheck disable=SC2086
      yum install -y ${pkgs[*]}
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MANAGER" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      # No cache when using --no-cache
      :
      ;;
    dnf|yum)
      :
      ;;
  esac
}

# Create non-root user if running as root
ensure_app_user() {
  if [ "$(id -u)" -eq 0 ]; then
    if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
      groupadd -r "${APP_GROUP}" || true
    fi
    if ! id -u "${APP_USER}" >/dev/null 2>&1; then
      useradd -m -r -s /bin/bash -g "${APP_GROUP}" "${APP_USER}" || true
    fi
  else
    APP_USER="$(id -un)"
    APP_GROUP="$(id -gn)"
  fi
  log "Using user: ${APP_USER} (group: ${APP_GROUP})"
}

# Create directory structure
setup_directories() {
  mkdir -p "${PROJECT_ROOT}"/{logs,tmp,data,run}
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}"
    chmod -R u=rwX,g=rwX,o=rX "${PROJECT_ROOT}" || true
    chmod 0775 "${PROJECT_ROOT}"/{logs,tmp,data,run} || true
  fi
}

# Detect project type(s)
HAS_NODE="false"; HAS_PYTHON="false"; HAS_RUBY="false"; HAS_GO="false"; HAS_JAVA="false"; HAS_PHP="false"; HAS_RUST="false"; HAS_DOTNET="false"

detect_project_types() {
  cd "${PROJECT_ROOT}"
  [ -f package.json ] && HAS_NODE="true"
  { [ -f requirements.txt ] || [ -f pyproject.toml ] || compgen -G "*.py" >/dev/null; } && HAS_PYTHON="true"
  [ -f Gemfile ] && HAS_RUBY="true"
  [ -f go.mod ] && HAS_GO="true"
  { [ -f pom.xml ] || compgen -G "build.gradle*" >/dev/null; } && HAS_JAVA="true"
  [ -f composer.json ] && HAS_PHP="true"
  [ -f Cargo.toml ] && HAS_RUST="true"
  compgen -G "*.csproj" >/dev/null && HAS_DOTNET="true"

  log "Detected stacks: node=${HAS_NODE}, python=${HAS_PYTHON}, ruby=${HAS_RUBY}, go=${HAS_GO}, java=${HAS_JAVA}, php=${HAS_PHP}, rust=${HAS_RUST}, dotnet=${HAS_DOTNET}"
}

# Base build tools
install_base_build_tools() {
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git gnupg wget xz-utils unzip zip tar
      pkg_install build-essential pkg-config
      # common headers often needed for pip/ruby gems, etc.
      pkg_install libssl-dev zlib1g-dev libbz2-1.0 libbz2-dev libreadline-dev libffi-dev libsqlite3-dev
      ;;
    apk)
      pkg_install ca-certificates curl git gnupg wget xz unzip zip tar
      pkg_install build-base pkgconfig
      pkg_install openssl-dev zlib-dev bzip2-dev readline-dev libffi-dev sqlite-dev
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gnupg2 wget xz unzip zip tar
      pkg_install gcc gcc-c++ make automake autoconf libtool pkgconfig
      pkg_install openssl-devel zlib-devel bzip2 bzip2-libs bzip2-devel readline-devel libffi-devel sqlite sqlite-devel
      ;;
  esac
}

# Node.js setup
setup_node() {
  [ "${HAS_NODE}" = "true" ] || return 0
  status "Configuring Node.js environment..."
  cd "${PROJECT_ROOT}"

  local have_node="false"
  if command -v node >/dev/null 2>&1; then
    have_node="true"
  fi

  # Install Node.js using package manager when possible, fallback to nvm
  if [ "${have_node}" = "false" ]; then
    case "$PKG_MANAGER" in
      apt)
        # Try distro node first
        pkg_install nodejs npm || true
        ;;
      apk)
        pkg_install nodejs npm || true
        ;;
      dnf|yum)
        pkg_install nodejs npm || true
        ;;
    esac
    if ! command -v node >/dev/null 2>&1; then
      # Fallback to nvm (user-level install)
      log "Installing Node.js via nvm..."
      local NVM_DIR=""
      if [ "$(id -u)" -eq 0 ]; then
        NVM_DIR="/usr/local/nvm"
        mkdir -p "${NVM_DIR}"
        export NVM_DIR
      else
        export NVM_DIR="${HOME}/.nvm"
      fi
      if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
      fi
      # shellcheck disable=SC1090
      [ -s "${NVM_DIR}/nvm.sh" ] && . "${NVM_DIR}/nvm.sh"
      local NODE_VER="${NODE_VERSION:-lts/*}"
      nvm install "${NODE_VER}"
      nvm alias default "${NODE_VER}"
      nvm use default
      log "Installed Node $(node -v)"
    else
      log "Installed Node via package manager: $(node -v)"
    fi
  else
    log "Node already present: $(node -v)"
  fi

  # Detect package manager: npm, yarn, pnpm
  local pkgtool="npm"
  if [ -f yarn.lock ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      case "$PKG_MANAGER" in
        apt|dnf|yum) npm install -g yarn >/dev/null 2>&1 || true ;;
        apk) npm install -g yarn >/dev/null 2>&1 || true ;;
      esac
    fi
    pkgtool="yarn"
  elif [ -f pnpm-lock.yaml ]; then
    if ! command -v pnpm >/dev/null 2>&1; then
      npm install -g pnpm >/dev/null 2>&1 || true
    fi
    pkgtool="pnpm"
  fi

  # Install deps
  if [ "${pkgtool}" = "npm" ]; then
    if [ -f package-lock.json ]; then
      npm ci --omit=dev --no-audit --no-fund || npm ci --no-audit --no-fund || true
    else
      npm install --omit=dev --no-audit --no-fund || npm install --no-audit --no-fund || true
    fi
  elif [ "${pkgtool}" = "yarn" ]; then
    yarn install --frozen-lockfile --production=true || yarn install --production=true || true
  else
    pnpm install --frozen-lockfile --prod || pnpm install || true
  fi

  export NODE_ENV="${NODE_ENV:-${APP_ENV}}"
  log "Node setup complete. NODE_ENV=${NODE_ENV}"
}

# Python setup
setup_python() {
  [ "${HAS_PYTHON}" = "true" ] || return 0
  status "Configuring Python environment..."
  cd "${PROJECT_ROOT}"

  case "$PKG_MANAGER" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel
      ;;
  esac

  # Virtual environment in .venv
  if [ ! -d ".venv" ]; then
    python3 -m venv .venv
  fi
  # shellcheck disable=SC1091
  . ".venv/bin/activate"

  # Upgrade pip/setuptools/wheel
  pip install --no-cache-dir --upgrade pip setuptools wheel

  if [ -f requirements.txt ]; then
    pip install --no-cache-dir -r requirements.txt
  elif [ -f pyproject.toml ]; then
    # Prefer pip if PEP 517 build, or use poetry if lockfile present
    if [ -f poetry.lock ]; then
      pip install --no-cache-dir poetry
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi --without dev || poetry install --no-interaction --no-ansi
    else
      pip install --no-cache-dir .
    fi
  fi

  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1
  log "Python setup complete. Virtualenv: ${PROJECT_ROOT}/.venv"
}

# Ruby setup
setup_ruby() {
  [ "${HAS_RUBY}" = "true" ] || return 0
  status "Configuring Ruby environment..."
  cd "${PROJECT_ROOT}"
  case "$PKG_MANAGER" in
    apt)
      pkg_install ruby-full ruby-dev build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc make
      ;;
  esac

  gem install --no-document bundler || true
  if [ -f Gemfile ]; then
    bundle config set --local path 'vendor/bundle'
    bundle install --without development test || bundle install
  fi
  log "Ruby setup complete."
}

# Go setup
setup_go() {
  [ "${HAS_GO}" = "true" ] || return 0
  status "Configuring Go environment..."
  cd "${PROJECT_ROOT}"
  if ! command -v go >/dev/null 2>&1; then
    case "$PKG_MANAGER" in
      apt) pkg_install golang ;;
      apk) pkg_install go ;;
      dnf|yum) pkg_install golang ;;
    esac
  fi
  if ! command -v go >/dev/null 2>&1; then
    warn "Go not available via package manager; skipping Go install."
    return 0
  fi
  export GOPATH="${PROJECT_ROOT}/.gopath"
  export GOBIN="${PROJECT_ROOT}/.gopath/bin"
  mkdir -p "${GOPATH}" "${GOBIN}"
  go mod download || true
  log "Go setup complete. GOPATH=${GOPATH}"
}

# Java setup
setup_java() {
  if [ "${HAS_JAVA}" != "true" ] && [ ! -f "${PROJECT_ROOT}/gradlew" ]; then
  return 0
fi
  status "Configuring Java environment..."
  local jver="${JAVA_VERSION:-17}"
  case "$PKG_MANAGER" in
    apt)
      pkg_install "openjdk-${jver}-jdk-headless" openjdk-11-jdk maven
      ;;
    apk)
      # Alpine package names differ
      if [ "$jver" -ge 17 ]; then
        pkg_install openjdk17 maven
      else
        pkg_install openjdk11 maven
      fi
      ;;
    dnf|yum)
      pkg_install "java-${jver}-openjdk" maven
      ;;
  esac
  # Ensure curl is available (some minimal images may lack it)
  if ! command -v curl >/dev/null 2>&1; then
    case "$PKG_MANAGER" in
      apt)
        pkg_update
        pkg_install curl ca-certificates
        ;;
      apk)
        pkg_install curl ca-certificates
        ;;
      dnf|yum)
        pkg_install curl ca-certificates
        ;;
    esac
  fi
  # Provision Temurin JDK 11 for Maven toolchains (vendor='temurin')
  local temurin_dir="${HOME}/.jdks/temurin-11"
  mkdir -p "${temurin_dir}" "${HOME}/.m2"
  if [ ! -x "${temurin_dir}/bin/java" ]; then
    curl -fsSL -o /tmp/temurin11.tar.gz https://api.adoptium.net/v3/binary/latest/11/ga/linux/x64/jdk/hotspot/normal/eclipse
    tar -xzf /tmp/temurin11.tar.gz -C "${temurin_dir}" --strip-components=1
  fi
  cat > "${HOME}/.m2/toolchains.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<toolchains>
  <toolchain>
    <type>jdk</type>
    <provides>
      <version>11</version>
      <vendor>temurin</vendor>
    </provides>
    <configuration>
      <jdkHome>${temurin_dir}</jdkHome>
    </configuration>
  </toolchain>
</toolchains>
EOF
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    app_home="$(getent passwd "${APP_USER}" | cut -d: -f6)"
    if [ -n "$app_home" ] && [ -d "$app_home" ]; then
      mkdir -p "$app_home/.m2" "$app_home/.jdks/temurin-11"
      if [ ! -x "$app_home/.jdks/temurin-11/bin/java" ]; then
        # Reuse downloaded tarball if present; otherwise fetch again
        if [ ! -f /tmp/temurin11.tar.gz ]; then
          curl -fsSL -o /tmp/temurin11.tar.gz https://api.adoptium.net/v3/binary/latest/11/ga/linux/x64/jdk/hotspot/normal/eclipse
        fi
        tar -xzf /tmp/temurin11.tar.gz -C "$app_home/.jdks/temurin-11" --strip-components=1
      fi
      cat > "$app_home/.m2/toolchains.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<toolchains>
  <toolchain>
    <type>jdk</type>
    <provides>
      <version>11</version>
      <vendor>temurin</vendor>
    </provides>
    <configuration>
      <jdkHome>$app_home/.jdks/temurin-11</jdkHome>
    </configuration>
  </toolchain>
</toolchains>
EOF
      chown -R "${APP_USER}:${APP_GROUP}" "$app_home/.m2" "$app_home/.jdks" || true
    fi
  fi
  cd "${PROJECT_ROOT}"
  if [ ! -f "./gradlew" ]; then
      status "Gradle wrapper not found. Generating via Gradle (8.8)..."
      if ! command -v gradle >/dev/null 2>&1; then
        case "$PKG_MANAGER" in
          apt) pkg_install gradle ;;
          apk) pkg_install gradle || true ;;
          dnf|yum) pkg_install gradle || true ;;
        esac
      fi
      gradle wrapper --gradle-version 8.8 --no-daemon || gradle wrapper --gradle-version 8.8 || true
      chmod +x ./gradlew || true
      ./gradlew --version --no-daemon || true
    fi
  # Ensure minimal Gradle build files exist at repository root
  if [ ! -f "settings.gradle" ] && [ ! -f "settings.gradle.kts" ]; then
    printf 'rootProject.name = "%s"\n' "${APP_NAME_DEFAULT:-app}" > settings.gradle
  fi
  if [ ! -f "build.gradle" ] && [ ! -f "build.gradle.kts" ]; then
    printf "%s\n" "plugins {" "    id 'java'" "}" "" "repositories {" "    mavenCentral()" "}" > build.gradle
  fi
  # Ensure gradlew is executable
  if [ -f "./gradlew" ]; then
    chmod +x ./gradlew || true
  fi
  log "Java setup complete."
}

# PHP setup
setup_php() {
  [ "${HAS_PHP}" = "true" ] || return 0
  status "Configuring PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_install php-cli php-json php-mbstring php-xml php-curl php-zip php-dom php-openssl composer
      ;;
    apk)
      pkg_install php81 php81-cli php81-json php81-mbstring php81-xml php81-curl php81-zip php81-openssl composer || \
      pkg_install php php-cli php-json php-mbstring php-xml php-curl php-zip php-openssl composer
      ;;
    dnf|yum)
      pkg_install php-cli php-json php-mbstring php-xml php-common php-zip composer
      ;;
  esac
  cd "${PROJECT_ROOT}"
  if [ -f composer.json ]; then
    composer install --no-dev --prefer-dist --no-interaction || composer install --prefer-dist --no-interaction
  fi
  log "PHP setup complete."
}

# Rust setup
setup_rust() {
  [ "${HAS_RUST}" = "true" ] || return 0
  status "Configuring Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain "${RUST_TOOLCHAIN:-stable}"
    # shellcheck disable=SC1090
    . "${HOME}/.cargo/env" || true
  fi
  if command -v cargo >/dev/null 2>&1; then
    cd "${PROJECT_ROOT}"
    cargo fetch || true
    log "Rust setup complete."
  else
    warn "Rust installation failed or cargo not in PATH."
  fi
}

# .NET setup (best-effort)
setup_dotnet() {
  [ "${HAS_DOTNET}" = "true" ] || return 0
  status "Configuring .NET environment..."
  # Installing dotnet SDK properly requires Microsoft package feeds; best effort:
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK already installed: $(dotnet --version)"
  else
    warn ".NET SDK not found. Use a dotnet base image or preinstall the SDK in your Dockerfile."
  fi
}

# Environment variables and .env
setup_env_file() {
  cd "${PROJECT_ROOT}"
  local envfile=".env"
  if [ ! -f "${envfile}" ]; then
    status "Creating default .env"
    {
      echo "APP_NAME=${APP_NAME_DEFAULT}"
      echo "APP_ENV=${APP_ENV}"
      # Determine default port
      local default_port="8080"
      if [ "${HAS_NODE}" = "true" ]; then default_port="3000"; fi
      if [ "${HAS_PYTHON}" = "true" ]; then
        # prefer Flask/uvicorn default
        if [ -f app.py ] || grep -qi flask **/*.py 2>/dev/null; then default_port="5000"; else default_port="8000"; fi
      fi
      if [ "${HAS_RUBY}" = "true" ]; then default_port="3000"; fi
      if [ "${HAS_GO}" = "true" ]; then default_port="8080"; fi
      if [ "${HAS_PHP}" = "true" ]; then default_port="8000"; fi
      echo "PORT=${PORT:-$default_port}"
      echo "LOG_LEVEL=info"
    } > "${envfile}"
  fi
  set -a
  # shellcheck disable=SC1090
  . "${envfile}" || true
  set +a
  log "Loaded environment from ${envfile}"
}

# Virtualenv auto-activation
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  if [ "$(id -u)" -ne 0 ]; then
    bashrc_file="${HOME}/.bashrc"
  fi
  local marker="# Auto-activate Python virtual environment"
  if ! grep -qF "$marker" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "$marker"
      echo 'PROJ_ROOT="${PROJECT_ROOT:-$PWD}"'
      echo 'if [ -f "$PROJ_ROOT/.venv/bin/activate" ]; then'
      echo '  . "$PROJ_ROOT/.venv/bin/activate"'
      echo 'fi'
    } >> "$bashrc_file"
  fi

  if [ "$(id -u)" -eq 0 ]; then
    local prof="/etc/profile.d/auto_venv.sh"
    if [ ! -f "$prof" ]; then
      printf '%s\n' '# Auto-activate project virtualenv if present' 'PROJ_ROOT="${PROJECT_ROOT:-$PWD}"' 'if [ -f "$PROJ_ROOT/.venv/bin/activate" ]; then' '  . "$PROJ_ROOT/.venv/bin/activate"' 'fi' > "$prof"
      chmod +x "$prof" || true
    fi
  fi
}

# Permissions
fix_permissions() {
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}"
    find "${PROJECT_ROOT}" -type d -exec chmod 0755 {} \; || true
    find "${PROJECT_ROOT}"/{logs,tmp,data,run} -type d -exec chmod 0775 {} \; || true
  else
    warn "Not running as root; skipping chown. Ensure mounted volume permissions are correct."
  fi
}

# Summary
print_summary() {
  echo
  status "Setup summary"
  echo "Project root: ${PROJECT_ROOT}"
  echo "User: ${APP_USER}:${APP_GROUP}"
  echo "Stacks: node=${HAS_NODE}, python=${HAS_PYTHON}, ruby=${HAS_RUBY}, go=${HAS_GO}, java=${HAS_JAVA}, php=${HAS_PHP}, rust=${HAS_RUST}, dotnet=${HAS_DOTNET}"
  echo "Environment: APP_ENV=${APP_ENV}, PORT=${PORT:-${PORT:-${PORT_DEFAULT:-}}}"
  echo
  log "Environment setup completed successfully."
}

main() {
  log "Starting universal environment setup..."
  detect_pkg_manager
  ensure_app_user
  setup_directories
  install_base_build_tools

  detect_project_types
  setup_env_file

  # Language setups
  setup_node
  setup_python
  setup_auto_activate
  setup_ruby
  setup_go
  setup_java
  setup_php
  setup_rust
  setup_dotnet

  fix_permissions
  pkg_clean
  print_summary

  echo
  status "Next steps (examples):"
  if [ "${HAS_NODE}" = "true" ]; then
    echo "- Node: npm start (or yarn start) [PORT=${PORT:-3000}]"
  fi
  if [ "${HAS_PYTHON}" = "true" ]; then
    echo "- Python: . .venv/bin/activate && python app.py (or your WSGI/ASGI server) [PORT=${PORT:-8000}]"
  fi
  if [ "${HAS_RUBY}" = "true" ]; then
    echo "- Ruby: bundle exec rails s -e ${APP_ENV} -p ${PORT:-3000}"
  fi
  if [ "${HAS_GO}" = "true" ]; then
    echo "- Go: go run ./... or go build"
  fi
  if [ "${HAS_PHP}" = "true" ]; then
    echo "- PHP: php -S 0.0.0.0:${PORT:-8000} -t public"
  fi
  if [ "${HAS_JAVA}" = "true" ]; then
    echo "- Java: mvn spring-boot:run or gradle bootRun"
  fi
  if [ "${HAS_RUST}" = "true" ] ; then
    echo "- Rust: cargo run"
  fi
  if [ "${HAS_DOTNET}" = "true" ]; then
    echo "- .NET: dotnet build && dotnet run"
  fi
}

main "$@"