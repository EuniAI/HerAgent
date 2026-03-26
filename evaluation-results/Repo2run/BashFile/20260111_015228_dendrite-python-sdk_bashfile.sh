#!/usr/bin/env bash
# Environment setup script for containerized projects.
# Detects common stacks (Python, Node.js, Ruby, Go, PHP, Java, Rust) and installs runtime and dependencies.
# Intended to run as root inside Docker containers without sudo.

set -Eeuo pipefail
IFS=$' \n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# Logging
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

# Error handler
error_handler() {
  local exit_code=$?
  err "Setup failed with exit code ${exit_code}"
  exit "${exit_code}"
}
trap error_handler ERR

# Helpers
have_cmd() { command -v "$1" >/dev/null 2>&1; }
is_root() { [ "$(id -u)" -eq 0 ]; }

# Global defaults
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"

PYTHON_VENV_DIR="${PYTHON_VENV_DIR:-${PROJECT_ROOT}/.venv}"
NODE_VERSION_DEFAULT="${NODE_VERSION_DEFAULT:-18}"
GOPATH_DIR="${GOPATH_DIR:-/go}"

# Package manager detection
PKG_MANAGER=""
PKG_INSTALL=""
PKG_UPDATE=""
PKG_CLEAN=""
PKG_GROUP_BUILD=""  # build tools/group
detect_pkg_manager() {
  if have_cmd apt-get; then
    PKG_MANAGER="apt"
    PKG_UPDATE="apt-get update"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="rm -rf /var/lib/apt/lists/*"
    PKG_GROUP_BUILD="build-essential"
    export DEBIAN_FRONTEND=noninteractive
  elif have_cmd apk; then
    PKG_MANAGER="apk"
    PKG_UPDATE="apk update || true"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
    PKG_GROUP_BUILD="build-base"
  elif have_cmd dnf; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf -y update || true"
    PKG_INSTALL="dnf -y install"
    PKG_CLEAN="dnf clean all || true"
    PKG_GROUP_BUILD="@development-tools"
  elif have_cmd yum; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum -y update || true"
    PKG_INSTALL="yum -y install"
    PKG_CLEAN="yum clean all || true"
    PKG_GROUP_BUILD="gcc gcc-c++ make"
  elif have_cmd microdnf; then
    PKG_MANAGER="microdnf"
    PKG_UPDATE="microdnf update -y || true"
    PKG_INSTALL="microdnf install -y"
    PKG_CLEAN="microdnf clean all || true"
    PKG_GROUP_BUILD="gcc gcc-c++ make"
  else
    err "No supported package manager found (apt/apk/dnf/yum)."
    exit 1
  fi
}

# System packages installation
install_common_packages() {
  log "Installing common system packages..."
  ${PKG_UPDATE}
  case "$PKG_MANAGER" in
    apt)
      ${PKG_INSTALL} ca-certificates curl git jq unzip tar "$PKG_GROUP_BUILD" \
        bash coreutils findutils grep sed gawk \
        libffi-dev libssl-dev zlib1g-dev libjpeg-dev \
        pkg-config
      update-ca-certificates || true
      ;;
    apk)
      ${PKG_INSTALL} ca-certificates curl git jq unzip tar "$PKG_GROUP_BUILD" \
        bash coreutils findutils grep sed gawk \
        libffi-dev openssl-dev zlib-dev jpeg-dev \
        pkgconfig
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      ${PKG_INSTALL} ca-certificates curl git jq unzip tar ${PKG_GROUP_BUILD} \
        bash coreutils findutils grep sed gawk \
        libffi-devel openssl-devel zlib-devel libjpeg-turbo-devel \
        pkgconfig
      update-ca-trust || true
      ;;
  esac
  ${PKG_CLEAN}
  log "Common system packages installed."
}

# Create project directories and permissions
setup_project_structure() {
  log "Setting up project directories under ${PROJECT_ROOT}..."
  mkdir -p "${PROJECT_ROOT}"
  mkdir -p "${PROJECT_ROOT}/logs" "${PROJECT_ROOT}/tmp" "${PROJECT_ROOT}/data"
  chmod 755 "${PROJECT_ROOT}"
  chmod 755 "${PROJECT_ROOT}/logs" "${PROJECT_ROOT}/tmp" "${PROJECT_ROOT}/data"
  log "Project directory structure created."
}

# .env handling
ensure_env_file() {
  local env_file="${PROJECT_ROOT}/.env"
  if [ ! -f "${env_file}" ]; then
    log "Creating default .env file at ${env_file}"
    cat > "${env_file}" <<EOF
APP_ENV=${APP_ENV}
# Common defaults; adjust as needed
APP_PORT=3000
PYTHONUNBUFFERED=1
PIP_NO_CACHE_DIR=1
NODE_ENV=production
RAILS_ENV=production
DJANGO_DEBUG=False
EOF
    chmod 640 "${env_file}"
  else
    log ".env already exists; leaving in place."
  fi
  set -a
  . "${env_file}"
  set +a
}

# Stack detection
detect_stack() {
  PYTHON_DETECT="false"
  NODE_DETECT="false"
  RUBY_DETECT="false"
  GO_DETECT="false"
  PHP_DETECT="false"
  JAVA_MAVEN_DETECT="false"
  JAVA_GRADLE_DETECT="false"
  RUST_DETECT="false"
  DOTNET_DETECT="false"

  # Python
  if [ -f "${PROJECT_ROOT}/requirements.txt" ] || [ -f "${PROJECT_ROOT}/pyproject.toml" ] || [ -f "${PROJECT_ROOT}/Pipfile" ] || [ -f "${PROJECT_ROOT}/setup.py" ]; then
    PYTHON_DETECT="true"
  fi

  # Node.js
  if [ -f "${PROJECT_ROOT}/package.json" ]; then
    NODE_DETECT="true"
  fi

  # Ruby
  if [ -f "${PROJECT_ROOT}/Gemfile" ]; then
    RUBY_DETECT="true"
  fi

  # Go
  if [ -f "${PROJECT_ROOT}/go.mod" ] || [ -f "${PROJECT_ROOT}/go.sum" ]; then
    GO_DETECT="true"
  fi

  # PHP
  if [ -f "${PROJECT_ROOT}/composer.json" ]; then
    PHP_DETECT="true"
  fi

  # Java
  if [ -f "${PROJECT_ROOT}/pom.xml" ]; then
    JAVA_MAVEN_DETECT="true"
  fi
  if [ -f "${PROJECT_ROOT}/build.gradle" ] || [ -f "${PROJECT_ROOT}/gradlew" ]; then
    JAVA_GRADLE_DETECT="true"
  fi

  # Rust
  if [ -f "${PROJECT_ROOT}/Cargo.toml" ]; then
    RUST_DETECT="true"
  fi

  # .NET
  if compgen -G "${PROJECT_ROOT}/*.csproj" >/dev/null || compgen -G "${PROJECT_ROOT}/*.sln" >/dev/null; then
    DOTNET_DETECT="true"
  fi
}

# Pip config: allow breaking system packages for Debian/Ubuntu PEP 668
configure_pip_break_system_packages() {
  if [ -f /etc/pip.conf ]; then
    grep -q "^\[global\]" /etc/pip.conf || sed -i "1i [global]" /etc/pip.conf
    grep -Eq "^\s*break-system-packages\s*=\s*true" /etc/pip.conf || sed -i "/^\[global\]/a break-system-packages = true" /etc/pip.conf
    grep -Eq "^\s*ignore-installed\s*=\s*true" /etc/pip.conf || sed -i "/^\[global\]/a ignore-installed = true" /etc/pip.conf
  else
    printf "[global]\nbreak-system-packages = true\nignore-installed = true\n" > /etc/pip.conf
  fi
  printf "export PIP_BREAK_SYSTEM_PACKAGES=1\nexport PIP_IGNORE_INSTALLED=1\n" > /etc/profile.d/pip_env.sh
  chmod 644 /etc/profile.d/pip_env.sh
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MANAGER" in
    apt)
      apt-get update
      ${PKG_INSTALL} software-properties-common
      add-apt-repository -y universe || true
      apt-get update
      ${PKG_INSTALL} python3 python3-venv python3-dev python-is-python3 pipx
      # Skipping removal of python3-wheel to avoid removing python3-pip
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      ${PKG_INSTALL} python3 py3-pip python3-dev
      ;;
    dnf|yum|microdnf)
      ${PKG_INSTALL} python3 python3-pip python3-devel
      ;;
  esac
  # Ensure pip is available independent of apt-managed packages
  if ! /usr/bin/python3 -m pip --version >/dev/null 2>&1; then
    if have_cmd apt-get; then
      apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && update-ca-certificates || true
    fi
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
    /usr/bin/python3 /tmp/get-pip.py --no-warn-script-location --disable-pip-version-check
    rm -f /tmp/get-pip.py
  fi
  configure_pip_break_system_packages
  /usr/bin/python3 -m pip install --upgrade pip setuptools wheel poetry
  # Ensure Poetry is installed at user level and configured to use the current environment
  python3 -m pip install --upgrade poetry || true
  mkdir -p /tmp/poetry-venvs /tmp/ms-playwright
(cd "${PROJECT_ROOT}" && python3 -m poetry config virtualenvs.in-project false && python3 -m poetry config virtualenvs.path /tmp/poetry-venvs || true)
  # Remove any existing Poetry-managed virtualenv to avoid conflicts; will recreate project venv next
  rm -rf "${PROJECT_ROOT}/.venv" || true
  hash -r || true

  if [ -f "${PROJECT_ROOT}/pyproject.toml" ]; then
    log "pyproject.toml detected; using Poetry-managed virtualenv under /tmp. Skipping creation of ${PYTHON_VENV_DIR}."
  else
    if [ ! -d "${PYTHON_VENV_DIR}" ]; then
      log "Creating Python virtual environment at ${PYTHON_VENV_DIR}"
      /usr/bin/python3 -m venv "${PYTHON_VENV_DIR}"
    else
      log "Virtual environment already exists at ${PYTHON_VENV_DIR}"
    fi
  fi

  # shellcheck source=/dev/null
  if [ -f "${PYTHON_VENV_DIR}/bin/activate" ]; then
    . "${PYTHON_VENV_DIR}/bin/activate"
    hash -r || true
    python3 -m pip install --upgrade pip setuptools wheel
  fi

  if [ -f "${PROJECT_ROOT}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "${PROJECT_ROOT}/requirements.txt"
  elif [ -f "${PROJECT_ROOT}/Pipfile" ]; then
    log "Pipfile detected; installing pipenv and dependencies"
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install
  elif [ -f "${PROJECT_ROOT}/pyproject.toml" ]; then
    log "Installing Python project dependencies with Poetry into exec-enabled venv"
    # Ensure pytest-asyncio is present as a dev dependency for async tests
    if ! grep -qE '^[[:space:]]*pytest-asyncio[[:space:]]*=' "${PROJECT_ROOT}/pyproject.toml"; then
      (cd "${PROJECT_ROOT}" && poetry add --group dev pytest-asyncio --no-interaction --no-ansi) || true
    fi
    (cd "${PROJECT_ROOT}" && poetry install --with dev --no-interaction --no-ansi)
  elif [ -f "${PROJECT_ROOT}/setup.py" ]; then
    log "Installing Python project via setup.py"
    pip install -e "${PROJECT_ROOT}"
  else
    warn "No Python dependency file found; skipping Python package installation."
  fi

  # Ensure Poetry is up-to-date in the active venv and configured to use the current environment
  if [ -f "${PROJECT_ROOT}/pyproject.toml" ]; then
    python -m pip install -U poetry || true
    (cd "${PROJECT_ROOT}" && poetry config virtualenvs.in-project false && poetry config virtualenvs.path /tmp/poetry-venvs || true)
  fi

  # Install Playwright browsers if Playwright package is present
  if have_cmd poetry && [ -f "${PROJECT_ROOT}/pyproject.toml" ] && (cd "${PROJECT_ROOT}" && poetry run python -c "import playwright" >/dev/null 2>&1); then
    log "Playwright detected; installing Chromium browser binaries via Poetry in exec-enabled venv..."
    (cd "${PROJECT_ROOT}" && PLAYWRIGHT_BROWSERS_PATH=/tmp/ms-playwright poetry run python -m playwright install chromium) || true
  elif python3 -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('playwright') else 1)" >/dev/null 2>&1; then
    log "Playwright detected; installing Chromium browser binaries..."
    PLAYWRIGHT_BROWSERS_PATH=/tmp/ms-playwright python3 -m playwright install chromium || true
  fi

  # Framework-specific env defaults
  if [ -f "${PROJECT_ROOT}/manage.py" ]; then
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-project.settings}"
    export APP_PORT="${APP_PORT:-8000}"
    log "Django project detected. DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE} APP_PORT=${APP_PORT}"
  elif [ -f "${PROJECT_ROOT}/app.py" ]; then
    export FLASK_APP="${FLASK_APP:-app.py}"
    export FLASK_ENV="${FLASK_ENV:-${APP_ENV}}"
    export APP_PORT="${APP_PORT:-5000}"
    log "Possible Flask app detected. FLASK_APP=${FLASK_APP} FLASK_ENV=${FLASK_ENV} APP_PORT=${APP_PORT}"
  fi

  deactivate || true
  log "Python environment setup complete."
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  # Prefer distro packages to keep script self-contained; Nodesource optional if apt nodejs not present
  if ! have_cmd node || ! have_cmd npm; then
    case "$PKG_MANAGER" in
      apt)
        ${PKG_INSTALL} nodejs npm || {
          warn "Installing Node.js via Nodesource (LTS ${NODE_VERSION_DEFAULT})"
          curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION_DEFAULT}.x" | bash -
          ${PKG_INSTALL} nodejs
        }
        ;;
      apk)
        ${PKG_INSTALL} nodejs npm
        ;;
      dnf|yum|microdnf)
        ${PKG_INSTALL} nodejs npm || warn "Node.js install may require enabling module streams or external repos"
        ;;
    esac
  else
    log "Node.js and npm already installed."
  fi

  if [ -f "${PROJECT_ROOT}/package-lock.json" ]; then
    log "Installing Node.js dependencies via npm ci"
    (cd "${PROJECT_ROOT}" && npm ci --no-audit --no-fund)
  else
    log "Installing Node.js dependencies via npm install"
    (cd "${PROJECT_ROOT}" && npm install --no-audit --no-fund)
  fi

  # Yarn support if yarn.lock present
  if [ -f "${PROJECT_ROOT}/yarn.lock" ]; then
    if ! have_cmd yarn; then
      log "Installing Yarn"
      case "$PKG_MANAGER" in
        apt) ${PKG_INSTALL} yarn || npm install -g yarn ;;
        apk) npm install -g yarn ;;
        dnf|yum|microdnf) npm install -g yarn ;;
      esac
    fi
    (cd "${PROJECT_ROOT}" && yarn install --frozen-lockfile || yarn install)
  fi

  export NODE_ENV="${NODE_ENV:-${APP_ENV}}"

  # Common Node app ports
  if grep -qi "\"start\"" "${PROJECT_ROOT}/package.json"; then
    export APP_PORT="${APP_PORT:-3000}"
  fi
  log "Node.js environment setup complete."
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt)
      ${PKG_INSTALL} ruby-full bundler
      ;;
    apk)
      ${PKG_INSTALL} ruby ruby-bundler ruby-dev
      ;;
    dnf|yum|microdnf)
      ${PKG_INSTALL} ruby ruby-devel rubygems
      gem install bundler || true
      ;;
  esac
  (cd "${PROJECT_ROOT}" && bundle config set --local path 'vendor/bundle' && bundle install --jobs=4 --retry=3)
  export RAILS_ENV="${RAILS_ENV:-${APP_ENV}}"
  export APP_PORT="${APP_PORT:-3000}"
  log "Ruby environment setup complete."
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apt) ${PKG_INSTALL} golang ;;
    apk) ${PKG_INSTALL} go ;;
    dnf|yum|microdnf) ${PKG_INSTALL} golang ;;
  esac
  mkdir -p "${GOPATH_DIR}"
  export GOPATH="${GOPATH_DIR}"
  export GOCACHE="${PROJECT_ROOT}/.gocache"
  mkdir -p "${GOCACHE}"
  (cd "${PROJECT_ROOT}" && have_cmd go && go mod download || true)
  export APP_PORT="${APP_PORT:-8080}"
  log "Go environment setup complete."
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      ${PKG_INSTALL} php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd
      ${PKG_INSTALL} composer || {
        warn "Installing Composer manually"
        curl -fsSL https://getcomposer.org/installer -o composer-setup.php
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
      }
      ;;
    apk)
      ${PKG_INSTALL} php81-cli php81-mbstring php81-xml php81-curl php81-zip php81-intl php81-gd composer || ${PKG_INSTALL} php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd composer
      ;;
    dnf|yum|microdnf)
      ${PKG_INSTALL} php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd
      curl -fsSL https://getcomposer.org/installer -o composer-setup.php
      php composer-setup.php --install-dir=/usr/local/bin --filename=composer
      rm -f composer-setup.php
      ;;
  esac
  (cd "${PROJECT_ROOT}" && composer install --no-interaction --prefer-dist || composer install)
  export APP_PORT="${APP_PORT:-8000}"
  log "PHP environment setup complete."
}

# Java setup
setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "$PKG_MANAGER" in
    apt) ${PKG_INSTALL} maven default-jdk ;;
    apk) ${PKG_INSTALL} maven openjdk11-jdk || ${PKG_INSTALL} maven openjdk8-jdk ;;
    dnf|yum|microdnf) ${PKG_INSTALL} maven java-11-openjdk-devel || ${PKG_INSTALL} maven java-1.8.0-openjdk-devel ;;
  esac
  (cd "${PROJECT_ROOT}" && mvn -B -q dependency:resolve || true)
  export APP_PORT="${APP_PORT:-8080}"
  log "Java (Maven) environment setup complete."
}

setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  case "$PKG_MANAGER" in
    apt) ${PKG_INSTALL} default-jdk ;;
    apk) ${PKG_INSTALL} openjdk11-jdk || ${PKG_INSTALL} openjdk8-jdk ;;
    dnf|yum|microdnf) ${PKG_INSTALL} java-11-openjdk-devel || ${PKG_INSTALL} java-1.8.0-openjdk-devel ;;
  esac
  if [ -x "${PROJECT_ROOT}/gradlew" ]; then
    (cd "${PROJECT_ROOT}" && ./gradlew tasks --no-daemon || true)
  else
    case "$PKG_MANAGER" in
      apt) ${PKG_INSTALL} gradle || warn "Gradle not available; ensure gradlew is present." ;;
      apk) ${PKG_INSTALL} gradle || warn "Gradle not available; ensure gradlew is present." ;;
      dnf|yum|microdnf) ${PKG_INSTALL} gradle || warn "Gradle not available; ensure gradlew is present." ;;
    esac
  fi
  export APP_PORT="${APP_PORT:-8080}"
  log "Java (Gradle) environment setup complete."
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MANAGER" in
    apt) ${PKG_INSTALL} cargo rustc ;;
    apk) ${PKG_INSTALL} cargo rust ;;
    dnf|yum|microdnf) ${PKG_INSTALL} cargo rust ;;
  esac
  (cd "${PROJECT_ROOT}" && cargo fetch || true)
  log "Rust environment setup complete."
}

# .NET setup (informational due to complexity)
setup_dotnet() {
  warn ".NET project detected. Installing .NET SDK in generic containers is non-trivial."
  warn "Prefer using official Microsoft .NET SDK base images. Skipping automatic install."
}

# Configure runtime environment
configure_runtime_env() {
  log "Configuring runtime environment variables..."
  export APP_ENV="${APP_ENV:-production}"
  export PATH="${PYTHON_VENV_DIR}/bin:${PATH}"
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  # Persist environment for later shells
  local profile_file="/etc/profile.d/project_env.sh"
  cat > "${profile_file}" <<EOF
export APP_ENV="${APP_ENV}"
export PATH="${PYTHON_VENV_DIR}/bin:\$PATH"
export LANG="${LANG}"
export LC_ALL="${LC_ALL}"
EOF
  chmod 644 "${profile_file}"
  log "Runtime environment configured."
}

# Auto-activate Python virtual environment on login
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local marker="# Auto-activate project virtualenv"
  if ! grep -qF "$marker" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "$marker" >> "$bashrc_file"
    echo "VENV_DIR=\"\${PYTHON_VENV_DIR:-/app/.venv}\"" >> "$bashrc_file"
    echo "if [ -f \"\$VENV_DIR/bin/activate\" ]; then" >> "$bashrc_file"
    echo "  . \"\$VENV_DIR/bin/activate\"" >> "$bashrc_file"
    echo "fi" >> "$bashrc_file"
  fi
}

# Permissions and ownership (keep root-friendly; do not chown unknown users)
set_permissions() {
  log "Ensuring safe permissions for project files..."
  find "${PROJECT_ROOT}" -type d -exec chmod 755 {} \; || true
  find "${PROJECT_ROOT}" -type f -not -path "${PROJECT_ROOT}/.env" -exec chmod 644 {} \; || true
  chmod 640 "${PROJECT_ROOT}/.env" || true
  log "Permissions set."
}

# Main
main() {
  if ! is_root; then
    err "Script must run as root inside the container (no sudo available)."
    exit 1
  fi

  log "Starting environment setup in ${PROJECT_ROOT}"
  detect_pkg_manager
  install_common_packages
  setup_project_structure
  ensure_env_file
  detect_stack

  # Install per detected stack
  if [ "${PYTHON_DETECT}" = "true" ]; then
    setup_python
  fi
  if [ "${NODE_DETECT}" = "true" ]; then
    setup_node
  fi
  if [ "${RUBY_DETECT}" = "true" ]; then
    setup_ruby
  fi
  if [ "${GO_DETECT}" = "true" ]; then
    setup_go
  fi
  if [ "${PHP_DETECT}" = "true" ]; then
    setup_php
  fi
  if [ "${JAVA_MAVEN_DETECT}" = "true" ]; then
    setup_java_maven
  fi
  if [ "${JAVA_GRADLE_DETECT}" = "true" ]; then
    setup_java_gradle
  fi
  if [ "${RUST_DETECT}" = "true" ]; then
    setup_rust
  fi
  if [ "${DOTNET_DETECT}" = "true" ]; then
    setup_dotnet
  fi

  configure_runtime_env
  setup_auto_activate
  set_permissions

  # Final hints
  log "Environment setup completed successfully."
  if [ "${PYTHON_DETECT}" = "true" ]; then
    log "To run Python app: source ${PYTHON_VENV_DIR}/bin/activate and run your app (e.g., python app.py)"
  fi
  if [ "${NODE_DETECT}" = "true" ]; then
    log "To run Node app: cd ${PROJECT_ROOT} && npm run start"
  fi
  if [ "${RUBY_DETECT}" = "true" ]; then
    log "To run Rails app: cd ${PROJECT_ROOT} && bundle exec rails server -b 0.0.0.0 -p \${APP_PORT:-3000}"
  fi
  if [ "${GO_DETECT}" = "true" ]; then
    log "To run Go app: cd ${PROJECT_ROOT} && go run ./..."
  fi
  if [ "${PHP_DETECT}" = "true" ]; then
    log "To run PHP app: cd ${PROJECT_ROOT} && php -S 0.0.0.0:\${APP_PORT:-8000} -t public"
  fi
  if [ "${JAVA_MAVEN_DETECT}" = "true" ] || [ "${JAVA_GRADLE_DETECT}" = "true" ]; then
    log "To run Java app: use your build tool (mvn spring-boot:run or ./gradlew bootRun)"
  fi
}

main "$@"