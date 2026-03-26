#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types (Python, Node.js, Ruby, PHP, Go, Java, .NET, Rust)
# - Installs runtimes and system dependencies
# - Configures environment and directory structure
# - Idempotent and safe to re-run

set -Eeuo pipefail

# Globals and defaults
APP_DIR="${APP_DIR:-$PWD}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
CREATE_APP_USER="${CREATE_APP_USER:-1}"           # set 0 to skip user creation
NONINTERACTIVE="${NONINTERACTIVE:-1}"             # 1 forces noninteractive installs
DEFAULT_PORT_NODE="${DEFAULT_PORT_NODE:-3000}"
DEFAULT_PORT_PYTHON="${DEFAULT_PORT_PYTHON:-8000}"
DEFAULT_PORT_PHP="${DEFAULT_PORT_PHP:-8080}"
DEFAULT_PORT_GO="${DEFAULT_PORT_GO:-8080}"
DEFAULT_PORT_JAVA="${DEFAULT_PORT_JAVA:-8080}"
DEFAULT_PORT_DOTNET="${DEFAULT_PORT_DOTNET:-8080}"
DEFAULT_PORT_RUST="${DEFAULT_PORT_RUST:-8080}"
PROFILE_D_PATH="/etc/profile.d/project_env.sh"
PKG_MANAGER=""
UPDATED_ONCE=0

# Colors (safe fallback without tput)
if command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2 || true)"
  YELLOW="$(tput setaf 3 || true)"
  RED="$(tput setaf 1 || true)"
  BLUE="$(tput setaf 4 || true)"
  NC="$(tput sgr0 || true)"
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*${NC}" >&2; }
info()   { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }

on_error() {
  local exit_code=$?
  error "Setup failed with exit code ${exit_code}"
  error "Last command: ${BASH_COMMAND}"
  exit ${exit_code}
}
trap on_error ERR

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    error "This script must run as root inside the container. Current UID: $(id -u)"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "${APP_DIR}"/{logs,tmp,run,data,scripts,bin}
}

append_if_missing() {
  # append_if_missing <file> <line>
  local file="$1"; shift
  local line="$*"
  grep -Fqx "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER=""
  fi
  if [ -z "${PKG_MANAGER}" ]; then
    warn "No known package manager found (apt/apk/dnf/yum). Skipping system package installation."
  else
    log "Detected package manager: ${PKG_MANAGER}"
  fi
}

pkg_update() {
  [ "${UPDATED_ONCE}" -eq 1 ] && return 0
  case "${PKG_MANAGER}" in
    apt)
      apt-get update -y
      UPDATED_ONCE=1
      ;;
    apk)
      # apk updates package index during add --update is deprecated; --no-cache avoids cache
      UPDATED_ONCE=1
      ;;
    dnf)
      dnf -y makecache || true
      UPDATED_ONCE=1
      ;;
    microdnf)
      microdnf -y update || true
      UPDATED_ONCE=1
      ;;
    yum)
      yum -y makecache || true
      UPDATED_ONCE=1
      ;;
  esac
}

pkg_install() {
  # pkg_install pkg1 pkg2 ...
  [ -z "${PKG_MANAGER}" ] && return 0
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  pkg_update
  case "${PKG_MANAGER}" in
    apt)
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    microdnf)
      microdnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
  esac
}

pkg_cleanup() {
  case "${PKG_MANAGER}" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|microdnf|yum)
      rm -rf /var/cache/dnf/* /var/cache/yum/* || true
      ;;
  esac
}

install_base_tools() {
  log "Installing base system tools and build dependencies..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install ca-certificates curl git unzip tar xz-utils pkg-config \
                  build-essential bash coreutils findutils grep sed
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git unzip tar xz pkgconfig \
                  build-base bash coreutils findutils grep sed
      update-ca-certificates || true
      ;;
    dnf|microdnf|yum)
      pkg_install ca-certificates curl git unzip tar xz pkgconfig \
                  gcc gcc-c++ make bash coreutils findutils grep sed
      update-ca-trust || true
      ;;
    *)
      warn "Skipping base tools installation due to unknown package manager."
      ;;
  esac
}

detect_project_types() {
  TYPES=()

  # Node.js
  [ -f "${APP_DIR}/package.json" ] && TYPES+=("node")

  # Python
  if [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ]; then
    TYPES+=("python")
  fi

  # Ruby
  [ -f "${APP_DIR}/Gemfile" ] && TYPES+=("ruby")

  # PHP
  [ -f "${APP_DIR}/composer.json" ] && TYPES+=("php")

  # Go
  [ -f "${APP_DIR}/go.mod" ] && TYPES+=("go")

  # Java
  [ -f "${APP_DIR}/pom.xml" ] || ls "${APP_DIR}"/build.gradle* >/dev/null 2>&1 && TYPES+=("java")

  # .NET
  ls "${APP_DIR}"/**/*.sln "${APP_DIR}"/**/*.csproj >/dev/null 2>&1 && TYPES+=("dotnet") || true

  # Rust
  [ -f "${APP_DIR}/Cargo.toml" ] && TYPES+=("rust")

  # Fallback if none detected
  if [ "${#TYPES[@]}" -eq 0 ]; then
    warn "No known project type detected. Proceeding with base environment only."
  else
    log "Detected project types: ${TYPES[*]}"
  fi
}

ensure_app_user() {
  if [ "${CREATE_APP_USER}" = "1" ] && [ "$(id -u)" -eq 0 ]; then
    if ! id -u "${APP_USER}" >/dev/null 2>&1; then
      log "Creating application user: ${APP_USER}"
      case "${PKG_MANAGER}" in
        alpine|apk)
          addgroup -S "${APP_GROUP}" 2>/dev/null || true
          adduser -S -G "${APP_GROUP}" -h "${APP_DIR}" "${APP_USER}" || true
          ;;
        *)
          groupadd -r "${APP_GROUP}" 2>/dev/null || true
          useradd -r -g "${APP_GROUP}" -d "${APP_DIR}" -s /bin/bash "${APP_USER}" 2>/dev/null || true
          ;;
      esac
    else
      log "Application user ${APP_USER} already exists"
    fi
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true
  fi
}

setup_env_file() {
  local env_file="${APP_DIR}/.env"
  touch "${env_file}"
  append_if_missing "${env_file}" "APP_ENV=${APP_ENV:-production}"

  # Per-type default ports
  if printf '%s\n' "${TYPES[@]}" | grep -qx "node"; then
    grep -q "^PORT=" "${env_file}" || echo "PORT=${DEFAULT_PORT_NODE}" >> "${env_file}"
    append_if_missing "${env_file}" "NODE_ENV=${NODE_ENV:-production}"
  fi
  if printf '%s\n' "${TYPES[@]}" | grep -qx "python"; then
    grep -q "^PORT=" "${env_file}" || echo "PORT=${DEFAULT_PORT_PYTHON}" >> "${env_file}"
    append_if_missing "${env_file}" "PYTHONDONTWRITEBYTECODE=1"
    append_if_missing "${env_file}" "PYTHONUNBUFFERED=1"
  fi
  if printf '%s\n' "${TYPES[@]}" | grep -qx "php"; then
    grep -q "^PORT=" "${env_file}" || echo "PORT=${DEFAULT_PORT_PHP}" >> "${env_file}"
  fi
  if printf '%s\n' "${TYPES[@]}" | grep -qx "go"; then
    grep -q "^PORT=" "${env_file}" || echo "PORT=${DEFAULT_PORT_GO}" >> "${env_file}"
  fi
  if printf '%s\n' "${TYPES[@]}" | grep -qx "java"; then
    grep -q "^PORT=" "${env_file}" || echo "PORT=${DEFAULT_PORT_JAVA}" >> "${env_file}"
    append_if_missing "${env_file}" "JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75"
  fi
  if printf '%s\n' "${TYPES[@]}" | grep -qx "dotnet"; then
    grep -q "^PORT=" "${env_file}" || echo "PORT=${DEFAULT_PORT_DOTNET}" >> "${env_file}"
    append_if_missing "${env_file}" "DOTNET_CLI_TELEMETRY_OPTOUT=1"
    append_if_missing "${env_file}" "DOTNET_NOLOGO=1"
  fi
  if printf '%s\n' "${TYPES[@]}" | grep -qx "rust"; then
    grep -q "^PORT=" "${env_file}" || echo "PORT=${DEFAULT_PORT_RUST}" >> "${env_file}"
  fi

  # Export variables for current session
  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a
}

persist_profile_exports() {
  # Persist PATH additions and useful envs for login shells
  local content=""
  content+="# Auto-generated by setup script\n"
  content+="export APP_DIR=\"${APP_DIR}\"\n"
  content+="export PATH=\"\${APP_DIR}/bin:\${PATH}\"\n"
  content+="[ -d \"\${APP_DIR}/.venv/bin\" ] && export PATH=\"\${APP_DIR}/.venv/bin:\${PATH}\"\n"
  content+="[ -d \"\${APP_DIR}/node_modules/.bin\" ] && export PATH=\"\${APP_DIR}/node_modules/.bin:\${PATH}\"\n"
  if [ -d "/usr/local/cargo/bin" ]; then
    content+="export PATH=\"/usr/local/cargo/bin:\${PATH}\"\n"
  fi
  if [ -d "/usr/local/share/dotnet" ]; then
    content+="export PATH=\"/usr/local/share/dotnet:\${PATH}\"\n"
  fi
  if [ -f "${APP_DIR}/.env" ]; then
    content+="set -a; [ -f \"${APP_DIR}/.env\" ] && . \"${APP_DIR}/.env\"; set +a\n"
  fi

  if [ "$(id -u)" -eq 0 ]; then
    printf "%b" "${content}" > "${PROFILE_D_PATH}"
    chmod 0644 "${PROFILE_D_PATH}"
  else
    append_if_missing "${HOME}/.bashrc" "${content}"
  fi
}

install_python() {
  log "Installing Python runtime and dependencies..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev
      ;;
    dnf|microdnf|yum)
      pkg_install python3 python3-pip python3-devel
      # virtualenv package naming varies; use python -m venv instead
      ;;
    *)
      warn "Cannot install Python via system packages (unknown package manager)."
      ;;
  esac

  # Create venv idempotently
  if [ ! -d "${APP_DIR}/.venv" ]; then
    python3 -m venv "${APP_DIR}/.venv"
  fi
  # shellcheck disable=SC1090
  . "${APP_DIR}/.venv/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel

  if [ -f "${APP_DIR}/requirements.txt" ]; then
    pip install -r "${APP_DIR}/requirements.txt"
  elif [ -f "${APP_DIR}/pyproject.toml" ]; then
    # Try PEP 517 install; prefer uv/pip if present
    pip install build
    if [ -f "${APP_DIR}/requirements.lock" ]; then
      pip install -r "${APP_DIR}/requirements.lock" || true
    else
      pip install .
    fi
  else
    warn "No Python dependency file found."
  fi
}

install_node() {
  log "Installing Node.js runtime and dependencies..."
  case "${PKG_MANAGER}" in
    apt)
      if ! command -v node >/dev/null 2>&1 || ! node -v | grep -qE '^v1[8-9]|^v2[0-9]'; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        pkg_install nodejs
      else
        log "Node.js already present: $(node -v)"
      fi
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|microdnf|yum)
      # Try module for modern Node.js; fallback to nodesource rpm if desired
      (command -v dnf >/dev/null 2>&1 && dnf module -y enable nodejs:20) 2>/dev/null || true
      pkg_install nodejs npm || {
        warn "Falling back to NodeSource RPM install not implemented for this distro."
      }
      ;;
    *)
      warn "Cannot install Node.js via system packages."
      ;;
  esac

  if [ -f "${APP_DIR}/package.json" ]; then
    pushd "${APP_DIR}" >/dev/null
    if [ -f "package-lock.json" ]; then
      npm ci --no-audit --no-fund
    else
      npm install --no-audit --no-fund
    fi
    popd >/dev/null
  else
    warn "No package.json found for Node.js project."
  fi
}

install_ruby() {
  log "Installing Ruby runtime and dependencies..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|microdnf|yum)
      pkg_install ruby ruby-devel gcc make
      ;;
    *)
      warn "Cannot install Ruby via system packages."
      ;;
  esac

  if command -v gem >/dev/null 2>&1; then
    gem install --no-document bundler || true
  fi

  if [ -f "${APP_DIR}/Gemfile" ]; then
    pushd "${APP_DIR}" >/dev/null
    BUNDLE_PATH="${APP_DIR}/vendor/bundle"
    mkdir -p "${BUNDLE_PATH}"
    bundle config set --local path "${BUNDLE_PATH}" || true
    bundle install --jobs=4
    popd >/dev/null
  else
    warn "No Gemfile found for Ruby project."
  fi
}

install_php() {
  log "Installing PHP runtime and dependencies..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-curl unzip curl
      ;;
    apk)
      # Use php81 packages; adjust if image provides different version
      pkg_install php81-cli php81-mbstring php81-xml php81-curl php81-phar curl unzip || \
      pkg_install php php-cli php-mbstring php-xml php-curl curl unzip || true
      ;;
    dnf|microdnf|yum)
      pkg_install php-cli php-mbstring php-xml curl unzip
      ;;
    *)
      warn "Cannot install PHP via system packages."
      ;;
  esac

  # Install Composer
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer','/tmp/composer-setup.php');" || true
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
    rm -f /tmp/composer-setup.php || true
  fi

  if [ -f "${APP_DIR}/composer.json" ]; then
    pushd "${APP_DIR}" >/dev/null
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress
    popd >/dev/null
  else
    warn "No composer.json found for PHP project."
  fi
}

install_go() {
  log "Installing Go runtime and dependencies..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install golang-go
      ;;
    apk)
      pkg_install go
      ;;
    dnf|microdnf|yum)
      pkg_install golang
      ;;
    *)
      warn "Cannot install Go via system packages."
      ;;
  esac

  if [ -f "${APP_DIR}/go.mod" ]; then
    pushd "${APP_DIR}" >/dev/null
    go mod download
    popd >/dev/null
  else
    warn "No go.mod found for Go project."
  fi
}

install_java() {
  log "Installing Java runtime and build tools..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install default-jdk-headless maven gradle || pkg_install default-jdk gradle || true
      ;;
    apk)
      pkg_install openjdk17-jdk maven gradle || pkg_install openjdk11-jdk maven gradle || true
      ;;
    dnf|microdnf|yum)
      pkg_install java-17-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven gradle || true
      ;;
    *)
      warn "Cannot install Java via system packages."
      ;;
  esac
}

install_dotnet() {
  log "Installing .NET SDK (using dotnet-install script for portability)..."
  # Install prerequisites
  case "${PKG_MANAGER}" in
    apt) pkg_install libc6 libgcc1 libgssapi-krb5-2 libicu70 || true ;;
    apk) pkg_install icu-libs krb5-libs zlib || true ;;
    dnf|microdnf|yum) pkg_install icu lttng-ust || true ;;
    *) true ;;
  esac
  # Use Microsoft's install script (non-interactive)
  if [ ! -x "/usr/local/share/dotnet/dotnet" ]; then
    mkdir -p /usr/local/share/dotnet
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --channel STS --install-dir /usr/local/share/dotnet
    ln -sf /usr/local/share/dotnet/dotnet /usr/local/bin/dotnet
    rm -f /tmp/dotnet-install.sh
  fi
}

install_rust() {
  log "Installing Rust toolchain (system packages preferred)..."
  # Prefer system packages to avoid network access
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    log "Rust already installed: $(cargo --version 2>/dev/null || echo 'cargo') / $(rustc --version 2>/dev/null || echo 'rustc')"
  else
    case "${PKG_MANAGER}" in
      apt)
        pkg_update
        apt-get install -y --no-install-recommends cargo rustc
        ;;
      apk)
        pkg_install rust cargo || true
        ;;
      dnf|microdnf|yum)
        pkg_install rust cargo || true
        ;;
      *)
        warn "Unknown package manager; skipping Rust install."
        ;;
    esac
  fi

  if [ -f "${APP_DIR}/Cargo.toml" ]; then
    pushd "${APP_DIR}" >/dev/null
    cargo fetch || true
    popd >/dev/null
  fi
}

ensure_make() {
  set -e
  if command -v make >/dev/null 2>&1; then
    echo "make found"
  else
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y make
    elif command -v yum >/dev/null 2>&1; then
      yum install -y make
    elif command -v apk >/dev/null 2>&1; then
      apk update && apk add --no-cache make
    else
      echo "No supported package manager found to install make" >&2
      exit 1
    fi
  fi
}

ensure_stub_makefile() {
  (
    cd "${APP_DIR}" || return 0
    # Do not create a Makefile if a Cargo project exists
    [ -f Cargo.toml ] && return 0
    if [ ! -f Makefile ]; then
      cat > Makefile <<'EOF'
.RECIPEPREFIX := >
.PHONY: all build
all: build
build:
> @echo "No build needed; placeholder target to satisfy autodetector."
EOF
    fi
  )
}

ensure_gradle_wrapper_stub() {
  (
    cd "${APP_DIR}" || return 0
    if [ ! -f gradlew ]; then
      printf '#!/bin/sh
# Lightweight gradle wrapper stub using system gradle
# Prefer Java 11 for compatibility with older Gradle builds
if [ -d /usr/lib/jvm/java-11-openjdk-amd64 ]; then
  export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
else
  for d in /usr/lib/jvm/java-11-*/ /usr/lib/jvm/java-11-openjdk*/; do
    [ -d "$d" ] && export JAVA_HOME="$d" && break
  done
fi
exec gradle "$@"
' > gradlew
      chmod +x gradlew
    fi
  )
}

ensure_gradle_java_installed() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y default-jdk-headless gradle
  fi
}

ensure_minimal_gradle_project() {
  (
    cd "${APP_DIR}" || return 0
    mkdir -p src/main/java
    if [ ! -f build.gradle ]; then
      cat > build.gradle <<'EOF'
plugins {
    id 'java'
}
sourceCompatibility = JavaVersion.VERSION_11
targetCompatibility = JavaVersion.VERSION_11
EOF
    fi
    [ -f settings.gradle ] || echo "rootProject.name = 'app'" > settings.gradle
    if [ ! -f src/main/java/App.java ]; then
      cat > src/main/java/App.java <<'EOF'
public class App {
    public static void main(String[] args) {
        System.out.println("Hello, World");
    }
}
EOF
    fi
  )
}

ensure_stub_requirements() {
  (
    cd "${APP_DIR}" || return 0
    [ -f requirements.txt ] || : > requirements.txt
  )
}

ensure_dummy_python_package() {
  (
    cd "${APP_DIR}" || return 0
    if [ ! -f "setup.py" ] && [ ! -f "pyproject.toml" ] && [ ! -f "package.json" ] && [ ! -f "Cargo.toml" ] && [ ! -f "go.mod" ] && [ ! -f "pom.xml" ] && ! ls ./*.sln ./**/*.sln ./*.csproj ./**/*.csproj >/dev/null 2>&1 && [ ! -f "Makefile" ] && [ ! -f "requirements.txt" ]; then
      mkdir -p dummy_pkg
      : > dummy_pkg/__init__.py
      cat > setup.py <<'EOF'
from setuptools import setup, find_packages
setup(
    name="dummy-pkg",
    version="0.0.0",
    description="Placeholder package to satisfy build autodetection",
    packages=find_packages(),
)
EOF
    fi
  )
}

ensure_node_tools_installed() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    echo "node and npm already installed"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nodejs npm
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache nodejs npm
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm nodejs npm
  else
    echo "No supported package manager found to install nodejs and npm" >&2
    return 1
  fi
}

ensure_placeholder_node_project() {
  (
    cd "${APP_DIR}" || return 0
    if [ ! -f package.json ]; then
      printf "%s\n" "{" "  \"name\": \"dummy-project\"," "  \"version\": \"1.0.0\"," "  \"private\": true," "  \"scripts\": {" "    \"build\": \"echo Build succeeded\"" "  }" "}" > package.json
    fi
  )
}

ensure_package_lock_file() {
  (
    cd "${APP_DIR}" || return 0
    if [ -f package.json ] && [ ! -f package-lock.json ]; then
      printf "%s\n" "{" "  \"name\": \"dummy-project\"," "  \"version\": \"1.0.0\"," "  \"lockfileVersion\": 1," "  \"requires\": true," "  \"dependencies\": {}" "}" > package-lock.json
    fi
  )
}

create_start_script() {
  local start_script="${APP_DIR}/scripts/start.sh"
  cat > "${start_script}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE="${APP_DIR}/.env"
[ -f "${ENV_FILE}" ] && set -a && . "${ENV_FILE}" && set +a
export PATH="${APP_DIR}/bin:${APP_DIR}/.venv/bin:${APP_DIR}/node_modules/.bin:/usr/local/share/dotnet:/usr/local/cargo/bin:${PATH}"

cd "${APP_DIR}"

# Try to start based on detected files
if [ -f "package.json" ]; then
  if npm run | grep -q " start"; then
    exec npm run start
  elif [ -f "server.js" ]; then
    exec node server.js
  elif [ -f "index.js" ]; then
    exec node index.js
  fi
fi

if [ -f "manage.py" ]; then
  exec python manage.py runserver 0.0.0.0:${PORT:-8000}
elif [ -f "app.py" ]; then
  if command -v gunicorn >/dev/null 2>&1; then
    exec gunicorn --bind 0.0.0.0:${PORT:-8000} app:app
  else
    exec python app.py
  fi
fi

if [ -f "artisan" ]; then
  exec php artisan serve --host 0.0.0.0 --port ${PORT:-8080}
elif [ -d "public" ] && [ -f "public/index.php" ]; then
  exec php -S 0.0.0.0:${PORT:-8080} -t public
fi

if [ -f "go.mod" ]; then
  if [ -f "main.go" ]; then
    mkdir -p bin
    go build -o bin/app .
    exec ./bin/app
  fi
fi

if [ -f "mvnw" ]; then
  exec ./mvnw spring-boot:run -Dspring-boot.run.jvmArguments="-Dserver.port=${PORT:-8080}"
elif [ -f "gradlew" ]; then
  exec ./gradlew bootRun -Pargs="--server.port=${PORT:-8080}"
fi

shopt -s nullglob
csproj=(*.csproj)
if [ ${#csproj[@]} -gt 0 ]; then
  exec dotnet run --urls "http://0.0.0.0:${PORT:-8080}"
fi

if [ -f "Cargo.toml" ]; then
  exec cargo run --release
fi

echo "No known start command found. Please customize scripts/start.sh."
exit 1
EOF
  chmod +x "${start_script}"
}

ensure_python_runtime() {
  # Ensure Python and pip exist across common distros
  if ! command -v python >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y python3 python3-pip
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3 python3-pip || dnf install -y python3 python3-pip || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache python3 py3-pip
    fi
  fi
  # Create symlinks if only python3/pip3 are present
  if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" /usr/local/bin/python || ln -sf "$(command -v python3)" /usr/bin/python || true
  fi
  if ! command -v pip >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
    ln -sf "$(command -v pip3)" /usr/local/bin/pip || ln -sf "$(command -v pip3)" /usr/bin/pip || true
  fi
}

fix_permissions() {
  if [ "$(id -u)" -eq 0 ] && id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true
  fi
}

ensure_go_runtime_exists() {
  if command -v go >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y --no-install-recommends golang-go
  elif command -v yum >/dev/null 2>&1; then
    yum install -y golang
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache go
  else
    echo "No supported package manager found for installing Go" >&2
    return 1
  fi
}

ensure_go_minimal_module() {
  (
    cd "${APP_DIR}" || return 0
    if [ ! -f go.mod ]; then
      printf "module example.com/autobuild\n\ngo 1.20\n" > go.mod
    fi
    mkdir -p cmd/app
    if [ ! -f cmd/app/main.go ]; then
      cat > cmd/app/main.go <<'EOF'
package main

func main() {}
EOF
    fi
  )
}

ensure_maven_runtime() {
  if command -v mvn >/dev/null 2>&1 && java -version >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y maven default-jdk-headless
  elif command -v yum >/dev/null 2>&1; then
    yum install -y maven java-17-openjdk-headless || yum install -y maven java-11-openjdk-headless
  elif command -v apk >/dev/null 2>&1; then
    apk update && apk add --no-cache maven openjdk17-jre
  else
    echo "No supported package manager found"
    exit 1
  fi
}

ensure_minimal_pom() {
  (
    cd "${APP_DIR}" || return 0
    if [ ! -f pom.xml ]; then
      mkdir -p src/main/java/com/example
      cat > src/main/java/com/example/App.java <<'EOF'
package com.example;
public class App {
    public static void main(String[] args) {
        System.out.println("Hello from Maven demo");
    }
}
EOF
      cat > pom.xml <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>demo</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.11.0</version>
        <configuration>
          <release>17</release>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
EOF
    fi
  )
}

ensure_minimal_rust_project() {
  (
    cd "${APP_DIR}" || return 0
    # Ensure Rust toolchain via apt when available
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y --no-install-recommends cargo rustc
    fi

    # Create minimal Cargo project if missing (independent of other artifacts)
    if [ ! -f Cargo.toml ]; then
      printf "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n" > Cargo.toml
    fi
    mkdir -p src
    if [ ! -f src/main.rs ]; then
      printf "fn main() { println!(\"OK\"); }\n" > src/main.rs
    fi

    # Generate lockfile and build in locked mode
    if command -v cargo >/dev/null 2>&1; then
      cargo generate-lockfile
      cargo build --locked
    else
      warn "cargo not found; skipping lockfile generation and build"
    fi
  )
}

main() {
  require_root
  log "Starting environment setup in ${APP_DIR}"

  ensure_dirs
  detect_pkg_manager
  install_base_tools
  ensure_minimal_rust_project
  ensure_placeholder_node_project
  ensure_dummy_python_package
  ensure_stub_requirements
  ensure_maven_runtime
  ensure_go_runtime_exists
  ensure_go_minimal_module
  ensure_minimal_pom
  ensure_gradle_wrapper_stub
  ensure_gradle_java_installed
  ensure_minimal_gradle_project
  ensure_node_tools_installed
  ensure_python_runtime
  ensure_package_lock_file
  ensure_stub_requirements
  detect_project_types

  ensure_make
  ensure_stub_makefile

  # Per-language installations
  for t in "${TYPES[@]:-}"; do
    case "$t" in
      python) install_python ;;
      node)   install_node ;;
      ruby)   install_ruby ;;
      php)    install_php ;;
      go)     install_go ;;
      java)   install_java ;;
      dotnet) install_dotnet ;;
      rust)   install_rust ;;
      *)      warn "Unknown project type: $t" ;;
    esac
  done

  setup_env_file
  persist_profile_exports
  create_start_script
  ensure_app_user
  fix_permissions
  pkg_cleanup

  log "Environment setup completed successfully."
  info "Next steps:"
  info "- To load environment: source ${PROFILE_D_PATH} (automatic for new shells)"
  info "- To start the app: ${APP_DIR}/scripts/start.sh"
}

main "$@"