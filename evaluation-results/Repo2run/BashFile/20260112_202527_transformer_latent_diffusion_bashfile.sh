#!/usr/bin/env bash

# Strict error handling
set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output (basic ANSI)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging functions
log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
  echo -e "${YELLOW}[WARN] $*${NC}"
}
err() {
  echo -e "${RED}[ERROR] $*${NC}" >&2
}

# Trap for unexpected errors
cleanup() {
  err "Setup failed at line $1. Refer to logs above."
}
trap 'cleanup $LINENO' ERR

# Default environment configuration
APP_ENV="${APP_ENV:-production}"
PROJECT_DIR="${PROJECT_DIR:-}"
PORT="${PORT:-8080}"
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-}"

# Detect package manager
PKG_MGR=""
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    PKG_MGR=""
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf makecache -y
      ;;
    yum)
      yum makecache -y
      ;;
    *)
      warn "No supported package manager detected; assuming base image has required tools."
      ;;
  esac
}

pkg_install() {
  # Install packages passed as arguments, mapping per manager
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    *)
      warn "Skipping installation of: $* (no supported package manager)"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MGR" in
    apt)
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      # Nothing special
      ;;
    dnf|yum)
      # Nothing special
      ;;
  esac
}

ensure_base_tools() {
  log "Ensuring base system tools are installed..."
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git pkg-config build-essential wget tar zip unzip bash
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git pkgconf build-base wget tar zip unzip bash
      update-ca-certificates || true
      ;;
    dnf)
      pkg_install ca-certificates curl git pkgconf-pkg-config gcc gcc-c++ make wget tar zip unzip bash
      ;;
    yum)
      pkg_install ca-certificates curl git pkgconfig gcc gcc-c++ make wget tar zip unzip bash
      ;;
    *)
      warn "Cannot install base tools; package manager not found."
      ;;
  esac
  log "Base system tools ready."
}

# Project directory setup
detect_project_dir() {
  # If PROJECT_DIR provided, use it; else detect common root patterns
  if [[ -n "${PROJECT_DIR}" ]]; then
    :
  else
    # Prefer current working directory if it contains project files
    local cwd
    cwd="$(pwd)"
    if compgen -G "${cwd}/requirements.txt" >/dev/null || \
       compgen -G "${cwd}/pyproject.toml" >/dev/null || \
       compgen -G "${cwd}/Pipfile" >/dev/null || \
       compgen -G "${cwd}/package.json" >/dev/null || \
       compgen -G "${cwd}/go.mod" >/dev/null || \
       compgen -G "${cwd}/pom.xml" >/dev/null || \
       compgen -G "${cwd}/Gemfile" >/dev/null || \
       compgen -G "${cwd}/Cargo.toml" >/dev/null; then
      PROJECT_DIR="${cwd}"
    else
      PROJECT_DIR="/app"
    fi
  fi
}

setup_directories() {
  log "Setting up project directories at ${PROJECT_DIR}..."
  mkdir -p "${PROJECT_DIR}"
  mkdir -p "${PROJECT_DIR}/logs" "${PROJECT_DIR}/tmp"
  # Set permissions
  chmod 755 "${PROJECT_DIR}"
  chmod 775 "${PROJECT_DIR}/logs" "${PROJECT_DIR}/tmp"

  # Ownership management (if APP_USER/APP_GROUP provided and exist)
  if [[ -n "${APP_USER}" ]]; then
    if getent passwd "${APP_USER}" >/dev/null 2>&1; then
      chown -R "${APP_USER}:${APP_GROUP:-${APP_USER}}" "${PROJECT_DIR}" || true
    else
      warn "APP_USER '${APP_USER}' not found. Skipping chown."
    fi
  fi
  log "Directories created and permissions set."
}

# Environment file setup
setup_env_file() {
  local env_file="${PROJECT_DIR}/.env"
  if [[ ! -f "${env_file}" ]]; then
    log "Creating default .env file..."
    cat >"${env_file}" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
EOF
    chmod 640 "${env_file}"
  else
    log ".env file already exists; leaving as-is."
  fi
}

# Python environment setup
setup_python() {
  local is_python="false"
  if [[ -f "${PROJECT_DIR}/requirements.txt" ]] || [[ -f "${PROJECT_DIR}/pyproject.toml" ]] || [[ -f "${PROJECT_DIR}/Pipfile" ]]; then
    is_python="true"
  fi
  if [[ "${is_python}" != "true" ]]; then
    return 0
  fi
  log "Detected Python project. Preparing Python environment..."

  # Install Python runtime if missing
  if ! command -v python3 >/dev/null 2>&1; then
    log "Python3 not found. Installing..."
    case "$PKG_MGR" in
      apt) pkg_install python3 python3-venv python3-pip ;;
      apk) pkg_install python3 py3-pip ;;
      dnf|yum) pkg_install python3 python3-pip ;;
      *) err "Cannot install Python3: unsupported package manager." ;;
    esac
  else
    log "Python3 found: $(python3 --version)"
  fi

  # Create venv
  local venv_dir="${PROJECT_DIR}/.venv"
  if [[ ! -d "${venv_dir}" ]]; then
    log "Creating Python virtual environment at ${venv_dir}..."
    if python3 -m venv "${venv_dir}"; then
      :
    else
      warn "python3 -m venv failed; trying virtualenv via pip..."
      if command -v pip3 >/dev/null 2>&1; then
        pip3 install --no-cache-dir virtualenv
        python3 -m virtualenv "${venv_dir}"
      else
        err "pip3 not available to install virtualenv."
      fi
    fi
  else
    log "Virtual environment already exists at ${venv_dir}."
  fi

  # Activate venv for subsequent pip actions
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"

  # Upgrade pip inside venv and install dependencies
  if command -v pip >/dev/null 2>&1; then
    log "Upgrading pip..."
    pip install --no-cache-dir --upgrade pip setuptools wheel
    if [[ -f "${PROJECT_DIR}/requirements.txt" ]]; then
      log "Installing Python dependencies from requirements.txt..."
      pip install --no-cache-dir -r "${PROJECT_DIR}/requirements.txt"
    elif [[ -f "${PROJECT_DIR}/pyproject.toml" ]]; then
      # Try pip for PEP 517; if poetry detected, use it
      if [[ -f "${PROJECT_DIR}/poetry.lock" ]] || grep -q 'tool.poetry' "${PROJECT_DIR}/pyproject.toml" || [[ -f "${PROJECT_DIR}/poetry.toml" ]]; then
        log "Poetry-based project detected. Installing Poetry and dependencies..."
        pip install --no-cache-dir poetry
        poetry config virtualenvs.create false
        poetry install --no-interaction --no-ansi
      else
        log "PEP 517/518 project detected. Attempting pip install of pyproject..."
        pip install --no-cache-dir .
      fi
    elif [[ -f "${PROJECT_DIR}/Pipfile" ]]; then
      log "Pipenv project detected. Installing pipenv and dependencies..."
      pip install --no-cache-dir pipenv
      PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
    fi
  else
    err "pip not available inside virtual environment."
  fi

  # Set Python-specific environment variables
  export VIRTUAL_ENV="${venv_dir}"
  export PATH="${venv_dir}/bin:${PATH}"
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1
  export PYTHONPATH="${PROJECT_DIR}:${PYTHONPATH:-}"

  log "Python environment setup completed."
}

# Node.js environment setup
setup_node() {
  if [[ ! -f "${PROJECT_DIR}/package.json" ]]; then
    return 0
  fi
  log "Detected Node.js project. Preparing Node.js environment..."

  if ! command -v node >/dev/null 2>&1; then
    log "Node.js not found. Installing..."
    case "$PKG_MGR" in
      apt) pkg_install nodejs npm ;;
      apk) pkg_install nodejs npm ;;
      dnf|yum) pkg_install nodejs npm || warn "Node.js install may require extra repos; continuing." ;;
      *) err "Cannot install Node.js: unsupported package manager." ;;
    esac
  else
    log "Node.js found: $(node -v)"
  fi

  if ! command -v npm >/dev/null 2>&1; then
    err "npm not available after Node.js installation."
  fi

  pushd "${PROJECT_DIR}" >/dev/null
  # npm install strategy (idempotent)
  if [[ -f "package-lock.json" ]]; then
    log "Installing Node dependencies via npm ci..."
    if [[ "${APP_ENV}" == "production" ]]; then
      npm ci --omit=dev || npm ci --only=production
    else
      npm ci
    fi
  else
    log "Installing Node dependencies via npm install..."
    if [[ "${APP_ENV}" == "production" ]]; then
      npm install --omit=dev || npm install --only=production
    else
      npm install
    fi
  fi
  popd >/dev/null

  export NODE_ENV="${APP_ENV}"
  export NPM_CONFIG_LOGLEVEL="${NPM_CONFIG_LOGLEVEL:-warn}"
  log "Node.js environment setup completed."
}

# Go environment setup
setup_go() {
  if [[ ! -f "${PROJECT_DIR}/go.mod" ]]; then
    return 0
  fi
  log "Detected Go project. Preparing Go environment..."

  if ! command -v go >/dev/null 2>&1; then
    log "Go not found. Installing..."
    case "$PKG_MGR" in
      apt) pkg_install golang ;;
      apk) pkg_install go ;;
      dnf|yum) pkg_install golang ;;
      *) err "Cannot install Go: unsupported package manager." ;;
    esac
  else
    log "Go found: $(go version)"
  fi

  export GOPATH="${GOPATH:-/go}"
  mkdir -p "${GOPATH}"
  export PATH="${GOPATH}/bin:${PATH}"

  pushd "${PROJECT_DIR}" >/dev/null
  log "Downloading Go modules..."
  go mod download
  popd >/dev/null

  log "Go environment setup completed."
}

# Ensure Java and Maven/Gradle toolchain via system package manager
ensure_java_maven_toolchain() {
  log "Installing Java JDK, Maven, and Gradle via SDKMAN..."

  # Install SDKMAN to a system-wide location if not present
  export SDKMAN_DIR="/usr/local/sdkman"
  if [[ ! -s "${SDKMAN_DIR}/bin/sdkman-init.sh" ]]; then
    curl -fsSL https://get.sdkman.io | bash
  fi

  # Initialize SDKMAN and install toolchains non-interactively
  if [[ -s "${SDKMAN_DIR}/bin/sdkman-init.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SDKMAN_DIR}/bin/sdkman-init.sh"
    yes | sdk install java 17.0.10-tem
    sdk default java 17.0.10-tem
    yes | sdk install maven
    yes | sdk install gradle

    # Create symlinks so tools are available on PATH for non-interactive shells
    ln -sf "${SDKMAN_DIR}/candidates/java/current/bin/java" /usr/local/bin/java
    ln -sf "${SDKMAN_DIR}/candidates/java/current/bin/javac" /usr/local/bin/javac
    ln -sf "${SDKMAN_DIR}/candidates/maven/current/bin/mvn" /usr/local/bin/mvn
    ln -sf "${SDKMAN_DIR}/candidates/gradle/current/bin/gradle" /usr/local/bin/gradle

    # Export JAVA_HOME for tools that require it explicitly
    export JAVA_HOME="${SDKMAN_DIR}/candidates/java/current"
    export PATH="${SDKMAN_DIR}/candidates/java/current/bin:${PATH}"
  else
    warn "SDKMAN initialization failed; Java/Maven/Gradle may be unavailable."
  fi

  # Normalize Gradle/Maven wrapper scripts (fix CRLF and permissions) at repo root
  sh -c 'if [ -f gradlew ]; then sed -i "s/\r$//" gradlew && chmod +x gradlew; fi; if [ -f mvnw ]; then sed -i "s/\r$//" mvnw && chmod +x mvnw; fi' || true

  # Verify toolchain availability
  java -version && javac -version && mvn -v && gradle -v || true

  # Concise marker summary at repo root
  printf "Detected project markers at repo root:\n"
  for f in pom.xml gradlew build.gradle package.json pyproject.toml go.mod Cargo.toml CMakeLists.txt Makefile; do
    [ -f "$f" ] && echo " - $f"
  done
  [ -d tests ] && echo " - tests/ directory" || true
}

# Java (Maven) environment setup
setup_java_maven() {
  if [[ ! -f "${PROJECT_DIR}/pom.xml" ]]; then
    return 0
  fi
  log "Detected Java Maven project. Preparing Java environment..."

  if ! command -v java >/dev/null 2>&1; then
    log "Java runtime not found. Installing OpenJDK..."
    case "$PKG_MGR" in
      apt) pkg_install openjdk-17-jre-headless ;;
      apk) pkg_install openjdk17-jre ;;
      dnf|yum) pkg_install java-17-openjdk-headless || pkg_install java-11-openjdk-headless ;;
      *) err "Cannot install Java: unsupported package manager." ;;
    esac
  else
    log "Java found: $(java -version 2>&1 | head -n1)"
  fi

  if ! command -v mvn >/dev/null 2>&1; then
    log "Maven not found. Installing Maven..."
    case "$PKG_MGR" in
      apt) pkg_install maven ;;
      apk) pkg_install maven ;;
      dnf|yum) pkg_install maven ;;
      *) err "Cannot install Maven: unsupported package manager." ;;
    esac
  fi

  pushd "${PROJECT_DIR}" >/dev/null
  log "Resolving Maven dependencies..."
  mvn -B -ntp dependency:resolve || warn "Maven dependency resolution encountered issues."
  popd >/dev/null

  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:- -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0}"
  log "Java Maven environment setup completed."
}

# Ruby environment setup
setup_ruby() {
  if [[ ! -f "${PROJECT_DIR}/Gemfile" ]]; then
    return 0
  fi
  log "Detected Ruby project. Preparing Ruby environment..."

  if ! command -v ruby >/dev/null 2>&1; then
    log "Ruby not found. Installing..."
    case "$PKG_MGR" in
      apt) pkg_install ruby-full ;;
      apk) pkg_install ruby ;;
      dnf|yum) pkg_install ruby ;;
      *) err "Cannot install Ruby: unsupported package manager." ;;
    esac
  else
    log "Ruby found: $(ruby --version)"
  fi

  if ! command -v bundle >/dev/null 2>&1; then
    log "Bundler not found. Installing bundler gem..."
    if command -v gem >/dev/null 2>&1; then
      gem install bundler
    else
      case "$PKG_MGR" in
        apt) pkg_install ruby-bundler || true ;;
        apk) pkg_install ruby-bundler || true ;;
      esac
    fi
  fi

  pushd "${PROJECT_DIR}" >/dev/null
  log "Installing Ruby gems via Bundler..."
  bundle config set path 'vendor/bundle'
  if [[ "${APP_ENV}" == "production" ]]; then
    bundle install --deployment --without development test
  else
    bundle install
  fi
  popd >/dev/null

  log "Ruby environment setup completed."
}

# Rust environment setup
setup_rust() {
  if [[ ! -f "${PROJECT_DIR}/Cargo.toml" ]]; then
    return 0
  fi
  log "Detected Rust project. Preparing Rust environment..."

  if ! command -v cargo >/dev/null 2>&1; then
    log "Rust toolchain not found. Installing rustc and cargo..."
    case "$PKG_MGR" in
      apt) pkg_install rustc cargo ;;
      apk) pkg_install rust cargo ;;
      dnf|yum) pkg_install rust cargo ;;
      *) err "Cannot install Rust: unsupported package manager." ;;
    esac
  else
    log "Rust found: $(rustc --version)"
  fi

  pushd "${PROJECT_DIR}" >/dev/null
  log "Fetching Rust crates..."
  cargo fetch || warn "Cargo fetch encountered issues."
  popd >/dev/null

  log "Rust environment setup completed."
}

# PHP environment setup (basic CLI + Composer if available)
setup_php() {
  if [[ ! -f "${PROJECT_DIR}/composer.json" ]]; then
    return 0
  fi
  log "Detected PHP project. Preparing PHP environment..."

  if ! command -v php >/dev/null 2>&1; then
    log "PHP not found. Installing..."
    case "$PKG_MGR" in
      apt) pkg_install php-cli unzip curl ;;
      apk) pkg_install php php-cli curl ;;
      dnf|yum) pkg_install php-cli curl unzip ;;
      *) err "Cannot install PHP: unsupported package manager." ;;
    esac
  else
    log "PHP found: $(php -v | head -n1)"
  fi

  if ! command -v composer >/dev/null 2>&1; then
    log "Composer not found. Installing Composer..."
    # Install composer locally into /usr/local/bin
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  pushd "${PROJECT_DIR}" >/dev/null
  log "Installing PHP dependencies via Composer..."
  if [[ "${APP_ENV}" == "production" ]]; then
    composer install --no-dev --no-interaction --prefer-dist
  else
    composer install --no-interaction --prefer-dist
  fi
  popd >/dev/null

  log "PHP environment setup completed."
}

# Export common runtime environment variables
export_common_env() {
  export APP_ENV
  export PORT
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  # Log directory env
  export APP_LOG_DIR="${PROJECT_DIR}/logs"
}

# Summary
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local venv_path="${PROJECT_DIR}/.venv"
  local activate_line="source ${venv_path}/bin/activate"
  if [[ -d "${venv_path}" ]]; then
    if ! grep -qF "${activate_line}" "${bashrc_file}" 2>/dev/null; then
      echo "" >> "${bashrc_file}"
      echo "# Auto-activate Python virtual environment" >> "${bashrc_file}"
      echo "${activate_line}" >> "${bashrc_file}"
    fi
  fi
}

diagnose_project_markers() {
  printf "Repo root listing and markers:\n"
  ls -la || true
  printf "\nDetected project markers (maxdepth 2):\n"
  find . -maxdepth 2 -type f \
    \( -name pom.xml -o -name gradlew -o -name build.gradle -o -name package.json -o -name pyproject.toml -o -name go.mod -o -name Cargo.toml -o -name CMakeLists.txt -o -name Makefile -o -name "*.sln" -o -name "*.csproj" \) \
    -print 2>/dev/null || true

  # Additional concise summary at repo root and first 10 .sln/.csproj entries
  echo "Project markers at repo root:"
  for f in pom.xml gradlew build.gradle package.json pyproject.toml go.mod Cargo.toml CMakeLists.txt Makefile; do
    [ -f "$f" ] && echo " - $f"
  done
  find . -maxdepth 2 \( -name "*.sln" -o -name "*.csproj" \) | sed -n '1,10p' || true
  printf "Repo root markers: "
  for f in pom.xml gradlew build.gradle package.json pyproject.toml go.mod Cargo.toml CMakeLists.txt Makefile pytest.ini tox.ini; do [ -e "$f" ] && printf "%s " "$f"; done
  echo
  echo "Discovered build files within depth 3:"
  find . -maxdepth 3 -type f \( -name pom.xml -o -name build.gradle -o -name package.json -o -name Cargo.toml -o -name go.mod \) | sed -e "s|^\./||"
}

print_summary() {
  log "Environment setup completed successfully."
  echo "Summary:"
  echo "  Project directory: ${PROJECT_DIR}"
  echo "  App environment:   ${APP_ENV}"
  echo "  Port:              ${PORT}"
  echo "  Logs directory:    ${APP_LOG_DIR}"
  echo "Next steps (examples, adapt to your project):"
  if [[ -f "${PROJECT_DIR}/package.json" ]]; then
    echo "  - To run Node app: cd '${PROJECT_DIR}' && npm start"
  fi
  if [[ -f "${PROJECT_DIR}/requirements.txt" ]] || [[ -f "${PROJECT_DIR}/pyproject.toml" ]] || [[ -f "${PROJECT_DIR}/Pipfile" ]]; then
    echo "  - To run Python app: source '${PROJECT_DIR}/.venv/bin/activate' && python your_entrypoint.py"
  fi
  if [[ -f "${PROJECT_DIR}/go.mod" ]]; then
    echo "  - To build Go app: cd '${PROJECT_DIR}' && go build ./..."
  fi
  if [[ -f "${PROJECT_DIR}/pom.xml" ]]; then
    echo "  - To build Java app: cd '${PROJECT_DIR}' && mvn package"
  fi
  if [[ -f "${PROJECT_DIR}/Gemfile" ]]; then
    echo "  - To run Ruby app: cd '${PROJECT_DIR}' && bundle exec ruby your_app.rb"
  fi
  if [[ -f "${PROJECT_DIR}/composer.json" ]]; then
    echo "  - To run PHP app: cd '${PROJECT_DIR}' && php your_script.php"
  fi
}

main() {
  log "Starting project environment setup..."
  detect_pkg_mgr
  if [[ -n "${PKG_MGR}" ]]; then
    log "Detected package manager: ${PKG_MGR}"
    pkg_update
    ensure_base_tools
  else
    warn "No supported package manager detected. Skipping system package installation."
  fi
  ensure_java_maven_toolchain

  detect_project_dir
  setup_directories
  setup_env_file

  # Language-specific setup
  setup_python
  setup_node
  setup_go
  setup_java_maven
  setup_ruby
  setup_rust
  setup_php

  export_common_env
  pkg_cleanup || true
  setup_auto_activate
  diagnose_project_markers || true
  print_summary
}

main "$@"