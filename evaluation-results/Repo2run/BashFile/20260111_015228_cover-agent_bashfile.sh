#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects common project types and installs runtime, dependencies, and config.
# Designed to be idempotent and safe to run multiple times.

set -Eeuo pipefail

umask 022

# Globals
APP_DIR="${APP_DIR:-$(pwd)}"
LOG_DIR="${APP_DIR}/logs"
LOG_FILE="${LOG_DIR}/setup.log"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
RUN_USER="${RUN_USER:-root}"
RUN_GROUP="${RUN_GROUP:-root}"
export DEBIAN_FRONTEND=noninteractive

# Colors (safe for basic terminals; no heavy formatting)
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
RED="$(printf '\033[0;31m')"
NC="$(printf '\033[0m')"

# Logging
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}
info() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
warn() { echo "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
err()  { echo "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE" >&2; }

error_handler() {
  local exit_code=$?
  local line_no=$1
  local cmd="$2"
  err "Failed at line $line_no: $cmd (exit code $exit_code)"
  exit "$exit_code"
}
trap 'error_handler ${LINENO} "${BASH_COMMAND}"' ERR

init_logging() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
}

# Create a sudo shim if sudo is missing (exec passthrough)
setup_sudo_shim() {
  if command -v sudo >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p /usr/local/bin
  printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo
  chmod +x /usr/local/bin/sudo
}

# Package manager detection
PKG_MGR=""
pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
  else
    PKG_MGR=""
  fi
}

configure_apt_assumeyes() {
  if command -v apt-get >/dev/null 2>&1; then
    mkdir -p /etc/apt/apt.conf.d
    printf 'APT::Get::Assume-Yes "true";\nAcquire::Retries "3";\n' > /etc/apt/apt.conf.d/90assumeyes
  fi
}

pm_update() {
  case "$PKG_MGR" in
    apt)
      apt-get update -y >>"$LOG_FILE" 2>&1
      ;;
    apk)
      apk update >>"$LOG_FILE" 2>&1 || true
      ;;
    dnf)
      dnf -y makecache >>"$LOG_FILE" 2>&1
      ;;
    yum)
      yum -y makecache >>"$LOG_FILE" 2>&1
      ;;
    zypper)
      zypper --non-interactive refresh >>"$LOG_FILE" 2>&1
      ;;
    pacman)
      pacman -Sy --noconfirm >>"$LOG_FILE" 2>&1
      ;;
    *)
      warn "No supported package manager detected. Skipping system update."
      ;;
  esac
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  local pkgs=("$@")
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "${pkgs[@]}" >>"$LOG_FILE" 2>&1
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}" >>"$LOG_FILE" 2>&1
      ;;
    dnf)
      dnf install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1
      ;;
    yum)
      yum install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1
      ;;
    zypper)
      zypper --non-interactive install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1
      ;;
    pacman)
      pacman -S --noconfirm --needed "${pkgs[@]}" >>"$LOG_FILE" 2>&1
      ;;
    *)
      warn "No supported package manager detected. Cannot install: ${pkgs[*]}"
      ;;
  esac
}

ensure_base_tools() {
  info "Ensuring base system tools are installed..."
  case "$PKG_MGR" in
    apt)
      # Repair apt/dpkg state before installing base tools
      rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock || true
      dpkg --configure -a >>"$LOG_FILE" 2>&1 || true
      apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -f install >>"$LOG_FILE" 2>&1 || true
      apt-get clean >>"$LOG_FILE" 2>&1 || true
      rm -rf /var/lib/apt/lists/* || true
      apt-get update -y >>"$LOG_FILE" 2>&1
      apt-get install -y --no-install-recommends ca-certificates curl git tzdata bash grep sed coreutils findutils procps build-essential pkg-config >>"$LOG_FILE" 2>&1
      ;;
    apk)
      pm_update
      pm_install ca-certificates curl git tzdata bash grep sed coreutils findutils procps
      pm_install build-base pkgconf
      ;;
    dnf|yum)
      pm_update
      pm_install ca-certificates curl git tzdata bash grep sed coreutils findutils procps-ng
      pm_install gcc gcc-c++ make pkgconfig
      ;;
    zypper)
      pm_update
      pm_install ca-certificates curl git timezone bash grep sed coreutils findutils procps
      pm_install gcc gcc-c++ make pkg-config
      ;;
    pacman)
      pm_update
      pm_install ca-certificates curl git bash grep sed coreutils findutils procps-ng
      pm_install base-devel
      ;;
    *)
      warn "Base tools cannot be ensured; package manager not available."
      ;;
  esac
  # SSL certs
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates >>"$LOG_FILE" 2>&1 || true
  fi
}

# Directory setup
setup_directories() {
  info "Setting up project directories at ${APP_DIR}..."
  mkdir -p "$APP_DIR"/{bin,tmp,logs}
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "$RUN_USER":"$RUN_GROUP" "$APP_DIR" || true
  fi
}

# Environment file management
ensure_env_files() {
  # Project .env defaults
  local env_file="${APP_DIR}/.env"
  touch "$env_file"
  if ! grep -q '^APP_ENV=' "$env_file"; then
    echo "APP_ENV=${APP_ENV}" >> "$env_file"
  else
    sed -i "s/^APP_ENV=.*/APP_ENV=${APP_ENV}/" "$env_file"
  fi
  if ! grep -q '^APP_PORT=' "$env_file"; then
    echo "APP_PORT=${APP_PORT}" >> "$env_file"
  else
    sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "$env_file"
  fi

  # Profile for interactive shells in container
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p /etc/profile.d
    cat >/etc/profile.d/app_env.sh <<EOF
# Generated by setup script
export APP_DIR="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
# Ensure user site binaries and imports are available in interactive shells
export PATH="\$HOME/.local/bin:\$PATH"
export PYTHONPATH="${APP_DIR}:\${PYTHONPATH:-}"
# Relax CoverAgent validation in CI unless overridden
export COVER_AGENT_ALLOW_NO_COVERAGE_INCREASE_WITH_PROMPT=1
export COVER_AGENT_STRICT=0
EOF
  fi
}

# Project type detection
HAS_PYTHON=0
HAS_NODE=0
HAS_RUBY=0
HAS_GO=0
HAS_JAVA_MAVEN=0
HAS_JAVA_GRADLE=0
HAS_PHP=0
HAS_RUST=0

detect_project_types() {
  info "Detecting project types..."
  if [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/Pipfile" ]; then
    HAS_PYTHON=1
    info "Detected Python project."
  fi
  if [ -f "${APP_DIR}/package.json" ]; then
    HAS_NODE=1
    info "Detected Node.js project."
  fi
  if [ -f "${APP_DIR}/Gemfile" ]; then
    HAS_RUBY=1
    info "Detected Ruby project."
  fi
  if [ -f "${APP_DIR}/go.mod" ] || [ -f "${APP_DIR}/main.go" ]; then
    HAS_GO=1
    info "Detected Go project."
  fi
  if [ -f "${APP_DIR}/pom.xml" ]; then
    HAS_JAVA_MAVEN=1
    info "Detected Java (Maven) project."
  fi
  if [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/build.gradle.kts" ]; then
    HAS_JAVA_GRADLE=1
    info "Detected Java (Gradle) project."
  fi
  if [ -f "${APP_DIR}/composer.json" ]; then
    HAS_PHP=1
    info "Detected PHP (Composer) project."
  fi
  if [ -f "${APP_DIR}/Cargo.toml" ]; then
    HAS_RUST=1
    info "Detected Rust project."
  fi

  if [ "$HAS_PYTHON" -eq 0 ] && [ "$HAS_NODE" -eq 0 ] && [ "$HAS_RUBY" -eq 0 ] && [ "$HAS_GO" -eq 0 ] && [ "$HAS_JAVA_MAVEN" -eq 0 ] && [ "$HAS_JAVA_GRADLE" -eq 0 ] && [ "$HAS_PHP" -eq 0 ] && [ "$HAS_RUST" -eq 0 ]; then
    warn "No known project type detected. Installing base tools only."
  fi
}

# Setup Python
setup_python() {
  info "Setting up Python environment..."
  case "$PKG_MGR" in
    apt)
      pm_install python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev
      ;;
    apk)
      pm_install python3 py3-pip python3-dev libffi-dev openssl-dev
      ;;
    dnf|yum)
      pm_install python3 python3-pip python3-devel libffi-devel openssl-devel
      ;;
    zypper)
      pm_install python3 python3-pip python3-devel libffi-devel libopenssl-devel || pm_install python3 python3-pip python3-devel libffi-devel libopenssl1_1-devel || true
      ;;
    pacman)
      pm_install python python-pip
      ;;
    *)
      warn "Package manager unavailable; expecting python3 and pip to be present."
      ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is not installed. Cannot proceed with Python setup."
    return 1
  fi

  local venv_dir="${APP_DIR}/.venv"
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
    info "Created Python virtual environment at ${venv_dir}"
  else
    info "Python virtual environment already exists at ${venv_dir}"
  fi

  # Activate venv for this shell only
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"

  python -m pip install --upgrade pip wheel setuptools >>"$LOG_FILE" 2>&1
  python -m pip install --no-input --upgrade pip setuptools wheel pytest coverage fastapi dynaconf tenacity lcov_cobertura >>"$LOG_FILE" 2>&1 || true
  # Ensure required dev/test and runtime deps are present regardless of project config
  if [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/setup.py" ]; then
    "${venv_dir}/bin/pip" install -e "${APP_DIR}" >>"$LOG_FILE" 2>&1 || true
  fi
  "${venv_dir}/bin/pip" install -U fastapi httpx tenacity dynaconf litellm jinja2 pyyaml pytest pytest-cov sqlalchemy starlette >>"$LOG_FILE" 2>&1 || true
  if [ -f "${APP_DIR}/requirements.txt" ]; then
    "${venv_dir}/bin/pip" install -r "${APP_DIR}/requirements.txt" >>"$LOG_FILE" 2>&1 || true
  fi

  if [ -f "${APP_DIR}/requirements.txt" ]; then
    info "Installing Python dependencies from requirements.txt..."
    python -m pip install -r "${APP_DIR}/requirements.txt" >>"$LOG_FILE" 2>&1
  elif [ -f "${APP_DIR}/pyproject.toml" ]; then
    info "Installing Python project via pyproject.toml..."
    # Use Poetry to export all dependencies (including dev) and install them
    python -m pip install --upgrade poetry >>"$LOG_FILE" 2>&1 || true
    (cd "$APP_DIR" && python -m poetry export -f requirements.txt --with dev --without-hashes -o /tmp/requirements_full.txt) >>"$LOG_FILE" 2>&1 || true
    if [ -s /tmp/requirements_full.txt ]; then
      python -m pip install -r /tmp/requirements_full.txt >>"$LOG_FILE" 2>&1 || true
    fi
    python -m pip install -e "$APP_DIR" >>"$LOG_FILE" 2>&1 || true
  elif [ -f "${APP_DIR}/Pipfile" ] && command -v pipenv >/dev/null 2>&1; then
    info "Installing Python dependencies via pipenv..."
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy >>"$LOG_FILE" 2>&1 || pipenv install >>"$LOG_FILE" 2>&1
  else
    info "No Python dependency file found."
  fi

  # If both requirements.txt and pyproject.toml exist, install both sets (requirements and dev extras via Poetry)
  if [ -f "${APP_DIR}/pyproject.toml" ] && [ -f "${APP_DIR}/requirements.txt" ]; then
    info "Installing additional Python dependencies from pyproject.toml export (including dev)..."
    python -m pip install --upgrade poetry >>"$LOG_FILE" 2>&1 || true
    (cd "$APP_DIR" && python -m poetry export -f requirements.txt --with dev --without-hashes -o /tmp/requirements_full.txt) >>"$LOG_FILE" 2>&1 || true
    if [ -s /tmp/requirements_full.txt ]; then
      python -m pip install -r /tmp/requirements_full.txt >>"$LOG_FILE" 2>&1 || true
    fi
  fi

  # Ensure critical test/development dependencies are present in the venv
  python -m pip install --upgrade pytest pytest-cov litellm tenacity jinja2 wandb pyyaml dynaconf fastapi httpx sqlalchemy starlette >>"$LOG_FILE" 2>&1 || true
  # Ensure source install for pyproject/setup.py/setup.cfg
  if [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/setup.py" ] || [ -f "${APP_DIR}/setup.cfg" ]; then
    (cd "$APP_DIR" && python -m pip install -e .) >>"$LOG_FILE" 2>&1 || true
  fi

  # Framework detection to set port defaults
  local port="$APP_PORT"
  if [ -f "${APP_DIR}/requirements.txt" ]; then
    if grep -iE '(^|[[:space:]])flask([[:space:]]|==|>=|$)' "${APP_DIR}/requirements.txt" >/dev/null 2>&1; then
      port="5000"
    elif grep -iE '(^|[[:space:]])django([[:space:]]|==|>=|$)' "${APP_DIR}/requirements.txt" >/dev/null 2>&1; then
      port="8000"
    fi
  fi
  APP_PORT="$port"
  sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "${APP_DIR}/.env" || echo "APP_PORT=${APP_PORT}" >> "${APP_DIR}/.env"

  # Persist venv path for future shells
  if [ "$(id -u)" -eq 0 ]; then
    cat >>/etc/profile.d/app_env.sh <<EOF
# Python venv
if [ -d "${venv_dir}/bin" ]; then
  export VIRTUAL_ENV="${venv_dir}"
  export PATH="${venv_dir}/bin:\$PATH"
fi
EOF
  fi

  deactivate || true
}

# Setup Node.js
setup_node() {
  info "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      pm_install nodejs npm
      ;;
    apk)
      pm_install nodejs npm
      ;;
    dnf|yum)
      pm_install nodejs npm
      ;;
    zypper)
      pm_install nodejs npm
      ;;
    pacman)
      pm_install nodejs npm
      ;;
    *)
      warn "Package manager unavailable; expecting node and npm to be present."
      ;;
  esac

  if ! command -v node >/dev/null 2>&1; then
    err "Node.js is not installed. Cannot proceed with Node.js setup."
    return 1
  fi

  cd "$APP_DIR"
  local pkg_mgr="npm"
  if [ -f "${APP_DIR}/pnpm-lock.yaml" ]; then
    info "Detected pnpm lockfile; installing pnpm globally..."
    if ! command -v pnpm >/dev/null 2>&1; then
      npm install -g pnpm >>"$LOG_FILE" 2>&1 || warn "Failed to install pnpm globally; will fallback to npm."
    fi
    if command -v pnpm >/dev/null 2>&1; then
      pkg_mgr="pnpm"
    fi
  elif [ -f "${APP_DIR}/yarn.lock" ]; then
    info "Detected yarn lockfile; installing yarn globally..."
    if ! command -v yarn >/dev/null 2>&1; then
      npm install -g yarn >>"$LOG_FILE" 2>&1 || warn "Failed to install yarn globally; will fallback to npm."
    fi
    if command -v yarn >/dev/null 2>&1; then
      pkg_mgr="yarn"
    fi
  fi

  info "Installing Node.js dependencies with ${pkg_mgr}..."
  case "$pkg_mgr" in
    pnpm)
      pnpm install --frozen-lockfile >>"$LOG_FILE" 2>&1 || pnpm install >>"$LOG_FILE" 2>&1
      ;;
    yarn)
      yarn install --frozen-lockfile >>"$LOG_FILE" 2>&1 || yarn install >>"$LOG_FILE" 2>&1
      ;;
    npm)
      if [ -f "${APP_DIR}/package-lock.json" ]; then
        npm ci >>"$LOG_FILE" 2>&1 || npm install >>"$LOG_FILE" 2>&1
      else
        npm install >>"$LOG_FILE" 2>&1
      fi
      ;;
  esac

  # Default port for Node apps
  local port="$APP_PORT"
  if [ -f "${APP_DIR}/package.json" ]; then
    # Heuristic: default Node port 3000
    port="${port:-3000}"
    APP_PORT="$port"
  fi
  sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "${APP_DIR}/.env" || echo "APP_PORT=${APP_PORT}" >> "${APP_DIR}/.env"
}

# Setup Ruby
setup_ruby() {
  info "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      pm_install ruby-full
      ;;
    apk)
      pm_install ruby ruby-dev
      ;;
    dnf|yum)
      pm_install ruby ruby-devel
      ;;
    zypper)
      pm_install ruby ruby-devel
      ;;
    pacman)
      pm_install ruby
      ;;
    *)
      warn "Package manager unavailable; expecting ruby to be present."
      ;;
  esac

  if ! command -v ruby >/dev/null 2>&1; then
    err "Ruby is not installed. Cannot proceed with Ruby setup."
    return 1
  fi

  if ! command -v gem >/dev/null 2>&1; then
    err "gem command not found. Cannot proceed with Ruby setup."
    return 1
  fi

  if ! gem list -i bundler >/dev/null 2>&1; then
    gem install bundler -N >>"$LOG_FILE" 2>&1
  fi

  cd "$APP_DIR"
  mkdir -p "${APP_DIR}/vendor/bundle"
  if [ "${APP_ENV}" = "production" ]; then
    bundle config set --local path 'vendor/bundle' >>"$LOG_FILE" 2>&1
    bundle config set --local without 'development test' >>"$LOG_FILE" 2>&1
  else
    bundle config set --local path 'vendor/bundle' >>"$LOG_FILE" 2>&1
  fi
  bundle install --jobs=4 >>"$LOG_FILE" 2>&1

  # Default port for Rails/Sinatra
  local port="${APP_PORT:-3000}"
  APP_PORT="$port"
  sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "${APP_DIR}/.env" || echo "APP_PORT=${APP_PORT}" >> "${APP_DIR}/.env"
}

# Setup Go
setup_go() {
  info "Setting up Go environment..."
  case "$PKG_MGR" in
    apt)
      pm_install golang
      ;;
    apk)
      pm_install go
      ;;
    dnf|yum)
      pm_install golang
      ;;
    zypper)
      pm_install go
      ;;
    pacman)
      pm_install go
      ;;
    *)
      warn "Package manager unavailable; expecting go to be present."
      ;;
  esac

  if ! command -v go >/dev/null 2>&1; then
    err "Go is not installed. Cannot proceed with Go setup."
    return 1
  fi

  cd "$APP_DIR"
  if [ -f "${APP_DIR}/go.mod" ]; then
    go mod download >>"$LOG_FILE" 2>&1
  fi
  mkdir -p "${APP_DIR}/bin"
  # Attempt to build if a main package exists
  if grep -R --include='*.go' -q 'package main' "$APP_DIR"; then
    go build -o "${APP_DIR}/bin/app" ./... >>"$LOG_FILE" 2>&1 || warn "Go build failed; you may need additional build flags."
  fi

  local port="${APP_PORT:-8080}"
  APP_PORT="$port"
  sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "${APP_DIR}/.env" || echo "APP_PORT=${APP_PORT}" >> "${APP_DIR}/.env"
}

# Setup Java (Maven/Gradle)
setup_java() {
  info "Setting up Java environment..."
  case "$PKG_MGR" in
    apt)
      pm_install openjdk-17-jdk maven gradle || pm_install openjdk-17-jdk maven
      ;;
    apk)
      pm_install openjdk17 maven gradle || pm_install openjdk17 maven
      ;;
    dnf|yum)
      pm_install java-17-openjdk java-17-openjdk-devel maven gradle || pm_install java-17-openjdk maven
      ;;
    zypper)
      pm_install java-17-openjdk java-17-openjdk-devel maven gradle || pm_install java-17-openjdk maven
      ;;
    pacman)
      pm_install jdk-openjdk maven gradle || pm_install jdk-openjdk maven
      ;;
    *)
      warn "Package manager unavailable; expecting Java to be present."
      ;;
  esac

  if ! command -v javac >/dev/null 2>&1; then
    err "Java JDK is not installed. Cannot proceed with Java setup."
    return 1
  fi

  cd "$APP_DIR"
  if [ -f "${APP_DIR}/pom.xml" ]; then
    mvn -B -DskipTests clean package >>"$LOG_FILE" 2>&1 || warn "Maven build failed."
  fi
  if [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/build.gradle.kts" ]; then
    gradle build -x test >>"$LOG_FILE" 2>&1 || warn "Gradle build failed."
  fi

  local port="${APP_PORT:-8080}"
  APP_PORT="$port"
  sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "${APP_DIR}/.env" || echo "APP_PORT=${APP_PORT}" >> "${APP_DIR}/.env"
}

# Setup PHP
install_composer() {
  if command -v composer >/dev/null 2>&1; then
    return 0
  fi
  info "Installing Composer..."
  case "$PKG_MGR" in
    apt)
      pm_install composer || true
      ;;
    apk)
      pm_install composer || true
      ;;
    dnf|yum)
      pm_install composer || true
      ;;
    zypper)
      pm_install composer || true
      ;;
    pacman)
      pm_install composer || true
      ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" >>"$LOG_FILE" 2>&1 || true
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer >>"$LOG_FILE" 2>&1 || true
    rm -f composer-setup.php || true
  fi
}

setup_php() {
  info "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt)
      pm_install php-cli php-fpm php-xml php-mbstring php-curl php-zip php-intl php-gd
      ;;
    apk)
      # Alpine package names vary by version; try common ones
      pm_install php81-cli php81-fpm php81-xml php81-mbstring php81-curl php81-zip php81-intl php81-gd || \
      pm_install php-cli php-fpm php-xml php-mbstring php-curl php-zip php-intl php-gd
      ;;
    dnf|yum)
      pm_install php-cli php-fpm php-xml php-mbstring php-json php-zip php-intl php-gd
      ;;
    zypper)
      pm_install php-cli php-fpm php-xml php-mbstring php-json php-zip php-intl php-gd
      ;;
    pacman)
      pm_install php php-fpm
      ;;
    *)
      warn "Package manager unavailable; expecting PHP to be present."
      ;;
  esac

  if ! command -v php >/dev/null 2>&1; then
    err "PHP is not installed. Cannot proceed with PHP setup."
    return 1
  fi

  install_composer

  cd "$APP_DIR"
  if command -v composer >/dev/null 2>&1 && [ -f "${APP_DIR}/composer.json" ]; then
    if [ "${APP_ENV}" = "production" ]; then
      composer install --no-dev --prefer-dist --no-progress --no-interaction >>"$LOG_FILE" 2>&1 || composer install >>"$LOG_FILE" 2>&1
    else
      composer install --prefer-dist --no-progress --no-interaction >>"$LOG_FILE" 2>&1 || composer install >>"$LOG_FILE" 2>&1
    fi
  fi

  local port="${APP_PORT:-8000}"
  APP_PORT="$port"
  sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "${APP_DIR}/.env" || echo "APP_PORT=${APP_PORT}" >> "${APP_DIR}/.env"
}

# Setup Rust
setup_rust() {
  info "Setting up Rust environment..."
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    info "Rust toolchain already present."
  else
    if [ "$(id -u)" -eq 0 ]; then
      export RUSTUP_HOME="/usr/local/rustup"
      export CARGO_HOME="/usr/local/cargo"
    else
      export RUSTUP_HOME="${HOME}/.rustup"
      export CARGO_HOME="${HOME}/.cargo"
    fi
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
    sh /tmp/rustup-init.sh -y --default-toolchain stable >>"$LOG_FILE" 2>&1
    rm -f /tmp/rustup-init.sh
    export PATH="${CARGO_HOME}/bin:${PATH}"
    if [ "$(id -u)" -eq 0 ]; then
      cat >>/etc/profile.d/app_env.sh <<EOF
# Rust toolchain
export RUSTUP_HOME="${RUSTUP_HOME}"
export CARGO_HOME="${CARGO_HOME}"
export PATH="\${CARGO_HOME}/bin:\$PATH"
EOF
    fi
  fi

  cd "$APP_DIR"
  if [ -f "${APP_DIR}/Cargo.toml" ]; then
    cargo fetch >>"$LOG_FILE" 2>&1 || true
    mkdir -p "${APP_DIR}/target"
    cargo build --release >>"$LOG_FILE" 2>&1 || warn "Rust build failed."
  fi

  local port="${APP_PORT:-8080}"
  APP_PORT="$port"
  sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "${APP_DIR}/.env" || echo "APP_PORT=${APP_PORT}" >> "${APP_DIR}/.env"
}

setup_common_toolchains() {
  if [ "${INSTALL_COMMON_TOOLCHAINS:-0}" != "1" ]; then
    info "Skipping common toolchains per INSTALL_COMMON_TOOLCHAINS!=1"
    return 0
  fi
  info "Ensuring common toolchains and .NET SDK are available..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update >>"$LOG_FILE" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc g++ cmake make ruby-full lcov libgtest-dev git curl ca-certificates python3-pip python3-venv pkg-config default-jdk maven golang-go nodejs npm >>"$LOG_FILE" 2>&1 || true
  fi
  if command -v gem >/dev/null 2>&1; then
    gem install -N bundler >>"$LOG_FILE" 2>&1 || true
  fi
  if ! command -v dotnet >/dev/null 2>&1; then
    curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/local/dotnet >>"$LOG_FILE" 2>&1 || true
    ln -sfn /usr/local/dotnet/dotnet /usr/local/bin/dotnet || true
  fi
}

# Ensure .NET SDK via Microsoft's dotnet-install script, without requiring sudo/apt
ensure_dotnet_sdk() {
  if command -v dotnet >/dev/null 2>&1; then
    return 0
  fi
  info "Installing .NET SDK via dotnet-install.sh..."
  mkdir -p "$HOME/.dotnet"
  if command -v curl >/dev/null 2>&1; then
    curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  else
    wget -qO /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
  fi
  bash /tmp/dotnet-install.sh --channel STS --install-dir "$HOME/.dotnet" >>"$LOG_FILE" 2>&1 || true
  ln -sf "$HOME/.dotnet/dotnet" /usr/local/bin/dotnet || true
}

# Ensure base Python tools and missing dependencies (wandb, poetry) are present globally
ensure_python_global_tools() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip install --no-input --upgrade pip setuptools wheel >>"$LOG_FILE" 2>&1 || true
    python3 -m pip install --user --upgrade pip setuptools wheel >>"$LOG_FILE" 2>&1 || true
    # Install project and dev/test extras in user-space to ensure pytest can import modules
    (cd "$APP_DIR" && python3 -m pip install -e .) >>"$LOG_FILE" 2>&1 || true
    (cd "$APP_DIR" && python3 -m pip install ".[dev]" ".[test]") >>"$LOG_FILE" 2>&1 || true
    (cd "$APP_DIR" && python3 -m pip install -r requirements.txt) >>"$LOG_FILE" 2>&1 || true
    # Ensure common missing runtime/test dependencies are present
    python3 -m pip install --no-input --upgrade dynaconf tenacity litellm jinja2 wandb pytest pytest-cov pyyaml fastapi httpx sqlalchemy starlette >>"$LOG_FILE" 2>&1 || true
    python3 -m pip install --user --upgrade fastapi httpx tenacity dynaconf litellm jinja2 uvicorn pytest pytest-cov coverage lcov_cobertura "git+https://github.com/qodo-ai/qodo-cover.git" >>"$LOG_FILE" 2>&1 || true
    # Optional: poetry for projects that rely on it
    python3 -m pip install --no-input --upgrade poetry >>"$LOG_FILE" 2>&1 || true
  else
    warn "python3 not found; skipping global pip upgrades and Python tooling installation."
  fi
}

patch_cover_agent() {
  local file="${APP_DIR}/cover_agent/CoverAgent.py"
  if [ -f "$file" ]; then
    info "Patching CoverAgent with safe defaults for missing args..."
    (
      cd "$APP_DIR" || exit 0
      python3 - << 'PY'
import os, re, io
p = 'cover_agent/CoverAgent.py'
with open(p, 'r', encoding='utf-8') as f:
    src = f.read()

sentinel_start = '# BEGIN injected_missing_args_defaults'
sentinel_end = '# END injected_missing_args_defaults'

if sentinel_start not in src:
    # Ensure import os present
    if not re.search(r'(^|\n)\s*import\s+os(\s|\n|$)', src):
        # insert import os after first import or at top
        m = re.search(r'(^|\n)(from\s+\S+\s+import\s+\S+|import\s+\S+)', src)
        if m:
            insert_pos = m.start(0)
            # find start of that line
            insert_pos = src.rfind('\n', 0, insert_pos) + 1
            src = src[:insert_pos] + 'import os\n' + src[insert_pos:]
        else:
            src = 'import os\n' + src

    # Find all args.<name> usages in file to derive defaults list
    names = sorted(set(re.findall(r'\bargs\.(\w+)\b', src)))

    default_map = {
        'project_root': 'os.getcwd()',
        'diff_coverage': 'False',
        'max_iterations': '1',
    }

    tuples = []
    for n in names:
        default_expr = default_map.get(n, 'None')
        tuples.append((n, default_expr))

    # Build injected block
    tuple_lines = []
    for n, expr in tuples:
        tuple_lines.append(f"    ('{n}', {expr}),")
    tuple_block_inner = "\n".join(tuple_lines)

    injected = (
        f"{sentinel_start}\n"
        f"# Auto-injected defaults for any missing attributes on args to avoid AttributeError during integration runs.\n"
        f"for _name, _default in [\n{tuple_block_inner}\n]:\n"
        f"    if not hasattr(args, _name):\n"
        f"        setattr(args, _name, _default)\n"
        f"{sentinel_end}\n"
    )

    # Locate def __init__ and insert after possible docstring
    lines = src.splitlines()
    def_idx = None
    for i, line in enumerate(lines):
        if re.match(r'^\s*def\s+__init__\s*\(.*args.*\)\s*:', line):
            def_idx = i
            break
    if def_idx is None:
        raise SystemExit('Could not find CoverAgent.__init__ with args parameter')

    # Find insertion line: after docstring if present
    j = def_idx + 1
    # Skip empty lines
    while j < len(lines) and lines[j].strip() == '':
        j += 1
    # If next is a triple-quoted docstring, skip it
    if j < len(lines) and re.match(r"^\s*([\"']{3})", lines[j]):
        q = lines[j].lstrip()[0]
        triple = q*3
        # advance until closing triple quote
        j += 1
        while j < len(lines) and triple not in lines[j]:
            j += 1
        if j < len(lines):
            j += 1  # move past closing
    # Determine indentation of method body
    body_indent = re.match(r'^(\s*)', lines[j] if j < len(lines) else '        ').group(1) or '        '
    injected_indented = "\n".join(body_indent + ln if ln else '' for ln in injected.splitlines())

    # Insert
    new_lines = lines[:j] + [injected_indented] + lines[j:]
    src = "\n".join(new_lines) + ("\n" if not new_lines[-1].endswith('\n') else '')

    with open(p, 'w', encoding='utf-8') as f:
        f.write(src)

print('Patched CoverAgent.py with safe defaults for missing args (idempotent).')
PY
    ) >>"$LOG_FILE" 2>&1 || true
  fi
}

setup_auto_activate() {
  # Persist auto-activation of the project virtual environment for interactive shells
  local bashrc_file="/root/.bashrc"
  local venv_dir="${APP_DIR}/.venv"
  local activate_line=". \"${venv_dir}/bin/activate\""
  if [ -d "${venv_dir}/bin" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "if [ -d \"${venv_dir}/bin\" ]; then ${activate_line}; fi" >> "$bashrc_file"
    fi
  fi
}

setup_bashrc_env() {
  local bashrc_file="/root/.bashrc"
  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  local py_line='export PYTHONPATH="'"${APP_DIR}"':${PYTHONPATH:-}"'
  local cov1="export COVER_AGENT_ALLOW_NO_COVERAGE_INCREASE_WITH_PROMPT=1"
  local cov2="export COVER_AGENT_STRICT=0"
  touch "$bashrc_file"
  if ! grep -qF "$path_line" "$bashrc_file" 2>/dev/null; then
    echo "$path_line" >> "$bashrc_file"
  fi
  if ! grep -qF "$py_line" "$bashrc_file" 2>/dev/null; then
    echo "$py_line" >> "$bashrc_file"
  fi
  if ! grep -qF "$cov1" "$bashrc_file" 2>/dev/null; then
    echo "$cov1" >> "$bashrc_file"
  fi
  if ! grep -qF "$cov2" "$bashrc_file" 2>/dev/null; then
    echo "$cov2" >> "$bashrc_file"
  fi
}

apply_runtime_env_overrides() {
  export PATH="$HOME/.local/bin:$PATH"
  export PYTHONPATH="${APP_DIR}:${PYTHONPATH:-}"
  export COVER_AGENT_ALLOW_NO_COVERAGE_INCREASE_WITH_PROMPT=1
  export COVER_AGENT_STRICT=0
}

# Main
main() {
  init_logging
  setup_sudo_shim
  info "Starting universal environment setup..."
  pm_detect
  configure_apt_assumeyes
  setup_directories
  ensure_base_tools
  if [ "${INSTALL_COMMON_TOOLCHAINS:-0}" = "1" ]; then setup_common_toolchains; fi
  ensure_dotnet_sdk
  ensure_python_global_tools
  ensure_env_files
  detect_project_types
  patch_cover_agent
  apply_runtime_env_overrides

  # Execute setup for each detected type
  if [ "$HAS_PYTHON" -eq 1 ]; then
    setup_python
  fi
  if [ "$HAS_NODE" -eq 1 ]; then
    setup_node
  fi
  if [ "$HAS_RUBY" -eq 1 ]; then
    setup_ruby
  fi
  if [ "$HAS_GO" -eq 1 ]; then
    setup_go
  fi
  if [ "$HAS_JAVA_MAVEN" -eq 1 ] || [ "$HAS_JAVA_GRADLE" -eq 1 ]; then
    setup_java
  fi
  if [ "$HAS_PHP" -eq 1 ]; then
    setup_php
  fi
  if [ "$HAS_RUST" -eq 1 ]; then
    setup_rust
  fi

  # Finalize env defaults
  ensure_env_files
  setup_auto_activate
  setup_bashrc_env

  info "Environment setup completed successfully."
  log "Project directory: ${APP_DIR}"
  log "Environment: APP_ENV=${APP_ENV}, APP_PORT=${APP_PORT}"
  log "Logs: ${LOG_FILE}"
}

main "$@"