#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common project types (Python, Node.js, Go, Rust, Java) and installs required runtimes and dependencies.
# Idempotent, safe to re-run, and designed for root execution inside minimal containers.

set -Eeuo pipefail
IFS=$'\n\t'

#---------------------------
# Configuration and Defaults
#---------------------------
APP_HOME="${APP_HOME:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
CREATE_APP_USER="${CREATE_APP_USER:-1}"
APP_ENV="${APP_ENV:-production}"
DEFAULT_PORT="${PORT:-8080}"
ENV_FILE="${ENV_FILE:-.env}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"

#---------------------------
# Colors and Logging
#---------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info()   { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

on_err() {
  local exit_code=$?
  error "Setup failed with exit code ${exit_code} on line ${BASH_LINENO[0]} with command: ${BASH_COMMAND}"
  exit "${exit_code}"
}
trap on_err ERR

# Retry helper for flaky network operations
retry() {
  local -r max_attempts="${2:-5}"
  local -r delay="${3:-2}"
  local attempt=1
  until bash -lc "$1"; do
    if (( attempt >= max_attempts )); then
      return 1
    fi
    warn "Attempt $attempt failed. Retrying in ${delay}s..."
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
  done
  return 0
}

#---------------------------
# Package Manager Detection
#---------------------------
PKG_MANAGER=""
pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
  else
    die "No supported package manager detected (apt/apk/dnf/yum/microdnf)."
  fi
}

pm_update() {
  case "$PKG_MANAGER" in
    apt)
      retry "apt-get update" 5 3 || die "apt-get update failed"
      ;;
    apk)
      retry "apk update" 5 3 || die "apk update failed"
      ;;
    dnf)
      retry "dnf -y makecache" 5 3 || die "dnf makecache failed"
      ;;
    yum)
      retry "yum -y makecache" 5 3 || die "yum makecache failed"
      ;;
    microdnf)
      retry "microdnf -y makecache" 5 3 || die "microdnf makecache failed"
      ;;
  esac
}

pm_install() {
  local pkgs=("$@")
  case "$PKG_MANAGER" in
    apt)
      retry "apt-get install -y --no-install-recommends ${pkgs[*]}" 3 5 || die "apt-get install failed"
      ;;
    apk)
      retry "apk add --no-cache ${pkgs[*]}" 3 5 || die "apk add failed"
      ;;
    dnf)
      retry "dnf install -y ${pkgs[*]}" 3 5 || die "dnf install failed"
      ;;
    yum)
      retry "yum install -y ${pkgs[*]}" 3 5 || die "yum install failed"
      ;;
    microdnf)
      retry "microdnf install -y ${pkgs[*]}" 3 5 || die "microdnf install failed"
      ;;
  esac
}

pm_group_install_build_essentials() {
  case "$PKG_MANAGER" in
    apt) pm_install build-essential pkg-config ;;
    apk) pm_install build-base pkgconf ;;
    dnf|yum|microdnf) pm_install @development-tools pkgconfig ;;
  esac
}

# Check if a package is installed (apt-only optimization; others will just attempt install)
pm_is_installed() {
  case "$PKG_MANAGER" in
    apt)
      dpkg -s "$1" >/dev/null 2>&1
      ;;
    apk)
      apk info -e "$1" >/dev/null 2>&1
      ;;
    dnf|yum|microdnf)
      rpm -q "$1" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

#---------------------------
# System Base Setup
#---------------------------
setup_base_system() {
  log "Preparing base system packages using $PKG_MANAGER..."
  pm_update
  case "$PKG_MANAGER" in
    apt)
      pm_install ca-certificates curl wget git unzip xz-utils tar gzip openssl gnupg locales tzdata
      ;;
    apk)
      pm_install ca-certificates curl wget git unzip xz tar gzip openssl gnupg tzdata
      ;;
    dnf|yum|microdnf)
      pm_install ca-certificates curl wget git unzip xz tar gzip openssl gnupg2 tzdata
      ;;
  esac

  # Ensure certificates and locale (best effort)
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi

  # Set timezone if TZ provided
  if [[ -n "${TZ:-}" ]]; then
    info "Setting timezone to ${TZ}"
    case "$PKG_MANAGER" in
      apt|dnf|yum|microdnf)
        ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
        echo "${TZ}" >/etc/timezone || true
        ;;
      apk)
        ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
        echo "${TZ}" >/etc/timezone || true
        ;;
    esac
  fi

  # Build tools (useful for native deps)
  pm_group_install_build_essentials
}

#---------------------------
# Directory and Permissions
#---------------------------
setup_directories() {
  log "Setting up project directory at ${APP_HOME} ..."
  mkdir -p "${APP_HOME}"
  cd "${APP_HOME}"

  if [[ "${CREATE_APP_USER}" == "1" ]]; then
    if ! id -u "${APP_USER}" >/dev/null 2>&1; then
      info "Creating system user ${APP_USER}"
      if command -v adduser >/dev/null 2>&1; then
        # Alpine adduser
        addgroup -S "${APP_GROUP}" 2>/dev/null || true
        adduser -S -G "${APP_GROUP}" -h "${APP_HOME}" "${APP_USER}" 2>/dev/null || true
      elif command -v useradd >/dev/null 2>&1; then
        groupadd -f "${APP_GROUP}" || true
        useradd -m -d "${APP_HOME}" -g "${APP_GROUP}" "${APP_USER}" || true
      else
        warn "No useradd/adduser available; continuing as root."
      fi
    fi
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_HOME}" || true
  fi

  umask 022
}

#---------------------------
# Helpers
#---------------------------
ensure_line_in_file() {
  local line="$1"
  local file="$2"
  touch "${file}"
  grep -qxF "${line}" "${file}" || echo "${line}" >> "${file}"
}

set_env_var() {
  local key="$1"
  local value="$2"
  export "${key}"="${value}"
  ensure_line_in_file "${key}=${value}" "${ENV_FILE}"
}

# Persist virtual environment auto-activation for better UX
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local venv_activate_path="${APP_HOME}/.venv/bin/activate"
  local guard_line="[ -f \"${venv_activate_path}\" ] && . \"${venv_activate_path}\""
  if ! grep -qF "$guard_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$guard_line" >> "$bashrc_file"
  fi
}

# Detect lockfile presence
has_file() { [[ -f "$1" ]]; }
has_any() {
  for f in "$@"; do
    [[ -f "$f" ]] && return 0
  done
  return 1
}

#---------------------------
# Language-specific Setup
#---------------------------

# Python
setup_python() {
  log "Detected Python project."
  case "$PKG_MANAGER" in
    apt)
      pm_install python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev libjpeg-dev zlib1g-dev
      ;;
    apk)
      pm_install python3 py3-pip python3-dev libffi-dev openssl-dev jpeg-dev zlib-dev
      ;;
    dnf|yum|microdnf)
      pm_install python3 python3-pip python3-devel libffi-devel openssl-devel libjpeg-turbo-devel zlib-devel
      ;;
  esac

  local pybin="python3"
  local pipbin="pip3"
  command -v "${pybin}" >/dev/null 2>&1 || die "python3 not found after installation"
  command -v "${pipbin}" >/dev/null 2>&1 || die "pip3 not found after installation"

  # Create virtual environment if not present
  if [[ ! -d ".venv" ]]; then
    info "Creating virtual environment at .venv"
    "${pybin}" -m venv .venv
  else
    info "Virtual environment already exists. Skipping creation."
  fi

  # Activate venv for current shell
  # shellcheck disable=SC1091
  source ".venv/bin/activate"

  # Upgrade pip/setuptools/wheel
  pip install --upgrade pip setuptools wheel

  # Install deps
  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    if has_any "requirements.lock" "pip-tools.txt"; then
      pip install -r requirements.txt --require-hashes || pip install -r requirements.txt
    else
      pip install -r requirements.txt
    fi
  elif has_file "pyproject.toml"; then
    if grep -q "tool.poetry" pyproject.toml 2>/dev/null; then
      info "Poetry project detected"
      pip install "poetry>=1.5,<2"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi --only main || poetry install --no-interaction --no-ansi
    else
      # PEP 621 project with PDM or hatch? Try pip first.
      info "PEP 621 pyproject detected; attempting pip install of project"
      pip install -e . || pip install .
    fi
  elif has_file "Pipfile"; then
    info "Pipenv detected"
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install
  else
    warn "No recognized Python dependency file found. Skipping dependency installation."
  fi

  # Default ports and env
  local py_port="${DEFAULT_PORT}"
  if has_file "manage.py"; then
    py_port="8000"
  elif has_file "app.py" || grep -qi "flask" requirements.txt 2>/dev/null; then
    py_port="5000"
  fi

  set_env_var "APP_ENV" "${APP_ENV}"
  set_env_var "PYTHONDONTWRITEBYTECODE" "1"
  set_env_var "PYTHONUNBUFFERED" "1"
  set_env_var "PORT" "${py_port}"
  ensure_line_in_file 'PATH=".venv/bin:$PATH"' "${ENV_FILE}"

  info "Python setup complete."
}

# Node.js
install_node() {
  if command -v node >/dev/null 2>&1; then
    info "Node.js already installed: $(node -v)"
    return 0
  fi
  log "Installing Node.js runtime..."
  case "$PKG_MANAGER" in
    apt)
      # Try distro first
      if retry "apt-get install -y --no-install-recommends nodejs npm" 2 3; then
        info "Installed Node.js from distro: $(node -v || true)"
      else
        # Fallback to NodeSource Node 18.x
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        pm_install nodejs
      fi
      ;;
    apk)
      pm_install nodejs npm
      ;;
    dnf|yum|microdnf)
      # Attempt distro
      if ! pm_install nodejs npm; then
        curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
        pm_install nodejs
      fi
      ;;
  esac
}

setup_node() {
  log "Detected Node.js/JavaScript project."
  install_node
  command -v node >/dev/null 2>&1 || die "node installation failed"
  command -v npm >/dev/null 2>&1 || warn "npm not found; proceeding if using yarn/pnpm"

  # Enable Corepack to manage Yarn/Pnpm if available
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Choose package manager
  local pm="npm"
  if has_file "pnpm-lock.yaml"; then
    pm="pnpm"
    corepack prepare pnpm@latest --activate || npm install -g pnpm || true
  elif has_file "yarn.lock"; then
    pm="yarn"
    corepack prepare yarn@stable --activate || npm install -g yarn || true
  elif has_file "package-lock.json"; then
    pm="npm"
  fi

  log "Installing Node dependencies using ${pm}..."
  case "$pm" in
    pnpm)
      if has_file "pnpm-lock.yaml"; then
        pnpm install --frozen-lockfile || pnpm install
      else
        pnpm install
      fi
      ;;
    yarn)
      if has_file "yarn.lock"; then
        yarn install --frozen-lockfile || yarn install
      else
        yarn install
      fi
      ;;
    npm)
      if has_file "package-lock.json"; then
        npm ci || npm install
      else
        npm install
      fi
      ;;
  esac

  # Default port
  local node_port="${DEFAULT_PORT}"
  if grep -qi "next" package.json 2>/dev/null; then node_port="3000"; fi
  if grep -qi "nuxt" package.json 2>/dev/null; then node_port="3000"; fi
  if grep -qi "react-scripts" package.json 2>/dev/null; then node_port="3000"; fi
  if grep -qi "vite" package.json 2>/dev/null; then node_port="5173"; fi

  set_env_var "APP_ENV" "${APP_ENV}"
  set_env_var "NODE_ENV" "production"
  set_env_var "PORT" "${node_port}"
  ensure_line_in_file 'PATH="node_modules/.bin:$PATH"' "${ENV_FILE}"

  info "Node.js setup complete."
}

# Go
setup_go() {
  log "Detected Go project."
  case "$PKG_MANAGER" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    dnf|yum|microdnf) pm_install golang ;;
  esac
  command -v go >/dev/null 2>&1 || die "golang installation failed"

  # Use module mode and download dependencies
  set_env_var "GO111MODULE" "on"
  if has_file "go.mod"; then
    log "Downloading Go modules..."
    go mod download
  fi
  set_env_var "PORT" "${DEFAULT_PORT}"

  info "Go setup complete."
}

# Rust
setup_rust() {
  log "Detected Rust project."
  # Install rustup if cargo is not present
  if ! command -v cargo >/dev/null 2>&1; then
    pm_install curl ca-certificates
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi
  command -v cargo >/dev/null 2>&1 || die "cargo installation failed"

  log "Fetching Rust dependencies..."
  cargo fetch || true

  set_env_var "PORT" "${DEFAULT_PORT}"
  info "Rust setup complete."
}

# Java (Maven/Gradle)
setup_java() {
  log "Detected Java project."
  case "$PKG_MANAGER" in
    apt) pm_install openjdk-17-jdk maven gradle || pm_install openjdk-11-jdk maven ;;
    apk) pm_install openjdk17 maven gradle || pm_install openjdk11 maven ;;
    dnf|yum|microdnf) pm_install java-17-openjdk-devel maven gradle || pm_install java-11-openjdk-devel maven ;;
  esac
  command -v javac >/dev/null 2>&1 || die "Java (JDK) installation failed"

  if has_file "pom.xml"; then
    log "Resolving Maven dependencies..."
    mvn -q -e -DskipTests dependency:go-offline || true
  fi
  if has_file "build.gradle" || has_file "settings.gradle" || has_file "build.gradle.kts"; then
    log "Resolving Gradle dependencies..."
    gradle --no-daemon build -x test || gradle --no-daemon tasks || true
  fi

  set_env_var "JAVA_HOME" "$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  set_env_var "PORT" "${DEFAULT_PORT}"
  info "Java setup complete."
}

# Ruby (best-effort)
setup_ruby() {
  log "Detected Ruby project."
  case "$PKG_MANAGER" in
    apt) pm_install ruby-full ruby-bundler ;;
    apk) pm_install ruby ruby-dev ruby-bundler ;;
    dnf|yum|microdnf) pm_install ruby rubygems ruby-devel make gcc ;;
  esac
  if command -v bundle >/dev/null 2>&1; then
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4 || bundle install
  else
    warn "Bundler not found; skipping Ruby dependency installation."
  fi
  set_env_var "PORT" "${DEFAULT_PORT}"
  info "Ruby setup complete."
}

# PHP (best-effort CLI setup)
setup_php() {
  log "Detected PHP project."
  case "$PKG_MANAGER" in
    apt) pm_install php-cli php-zip php-xml php-mbstring curl unzip ;;
    apk) pm_install php81-cli php81-zip php81-xml php81-mbstring curl unzip || pm_install php-cli php-zip php-xml php-mbstring ;;
    dnf|yum|microdnf) pm_install php-cli php-zip php-xml php-mbstring curl unzip ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    info "Installing Composer..."
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi
  if has_file "composer.json"; then
    composer install --no-interaction --prefer-dist || composer install
  fi
  set_env_var "PORT" "${DEFAULT_PORT}"
  info "PHP setup complete."
}

# .NET (informational only to avoid repo setup complexity)
setup_dotnet_notice() {
  warn "Detected .NET project. Automated SDK installation is not included to keep the script repository-agnostic."
  warn "Please base your image on mcr.microsoft.com/dotnet/sdk:8.0 (or appropriate) to provide the runtime."
  set_env_var "PORT" "${DEFAULT_PORT}"
}

#---------------------------
# Project Type Detection
#---------------------------
PROJECT_TYPE=""
detect_project_type() {
  if has_file "package.json"; then
    PROJECT_TYPE="node"
  elif has_any "requirements.txt" "pyproject.toml" "Pipfile" "setup.py" "manage.py"; then
    PROJECT_TYPE="python"
  elif has_file "go.mod"; then
    PROJECT_TYPE="go"
  elif has_file "Cargo.toml"; then
    PROJECT_TYPE="rust"
  elif has_any "pom.xml" "build.gradle" "build.gradle.kts"; then
    PROJECT_TYPE="java"
  elif has_file "Gemfile"; then
    PROJECT_TYPE="ruby"
  elif has_file "composer.json"; then
    PROJECT_TYPE="php"
  elif compgen -G "*.csproj" >/dev/null 2>&1 || compgen -G "*.fsproj" >/dev/null 2>&1; then
    PROJECT_TYPE="dotnet"
  else
    PROJECT_TYPE="unknown"
  fi
  info "Project type detected: ${PROJECT_TYPE}"
}

#---------------------------
# Environment File Defaults
#---------------------------
setup_env_defaults() {
  touch "${ENV_FILE}"
  set_env_var "APP_ENV" "${APP_ENV}"
  # Default port may be overridden by language-specific setup
  if ! grep -q '^PORT=' "${ENV_FILE}"; then
    set_env_var "PORT" "${DEFAULT_PORT}"
  fi
  # Common helpful vars
  set_env_var "PIP_DISABLE_PIP_VERSION_CHECK" "1"
  set_env_var "PIP_NO_CACHE_DIR" "0"
  set_env_var "NPM_CONFIG_LOGLEVEL" "warn"
}

#---------------------------
# Main
#---------------------------
main() {
  log "Starting universal environment setup in ${APP_HOME}"
  pm_detect
  setup_base_system
  setup_directories
  setup_env_defaults
  detect_project_type

  case "$PROJECT_TYPE" in
    python) setup_python ;;
    node)   setup_node ;;
    go)     setup_go ;;
    rust)   setup_rust ;;
    java)   setup_java ;;
    ruby)   setup_ruby ;;
    php)    setup_php ;;
    dotnet) setup_dotnet_notice ;;
    *)
      warn "Could not detect project type. Installed base tools only. You may need to customize this script."
      ;;
  esac

  setup_auto_activate

  # Ensure correct ownership
  if [[ "${CREATE_APP_USER}" == "1" ]] && id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_HOME}" || true
  fi

  log "Environment setup completed successfully."
  echo
  echo "Summary:"
  echo "- Project directory: ${APP_HOME}"
  echo "- Detected type: ${PROJECT_TYPE}"
  echo "- Environment file: ${ENV_FILE}"
  echo "- Default PORT: $(grep -E '^PORT=' "${ENV_FILE}" | tail -n1 | cut -d= -f2)"
  echo
  echo "Usage:"
  echo "- Load environment variables: set -a; [ -f ${ENV_FILE} ] && . ${ENV_FILE}; set +a"
  case "$PROJECT_TYPE" in
    python) echo "- Activate virtualenv: . .venv/bin/activate" ;;
    node)   echo "- Node bin path added via node_modules/.bin (ensure to source ${ENV_FILE} or export PATH)" ;;
  esac
}

# Run
main "$@"