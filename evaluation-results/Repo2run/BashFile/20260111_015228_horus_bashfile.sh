#!/bin/bash

# Strict error handling and security best practices
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Color output (safe for most terminals; if not supported, it's fine)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# Timestamped logging
log() {
  echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
  echo "${YELLOW}[WARNING] $*${NC}" >&2
}
err() {
  echo "${RED}[ERROR] $*${NC}" >&2
}

# Trap errors to show line and command
trap 'err "Command failed at line $LINENO. Exit status: $?"; exit 1' ERR

# Defaults and environment setup
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}
export TZ=${TZ:-UTC}
APP_HOME_DEFAULT="/app"
APP_USER_DEFAULT="app"
APP_GROUP_DEFAULT="app"

APP_HOME="${APP_HOME:-$APP_HOME_DEFAULT}"
APP_USER="${APP_USER:-$APP_USER_DEFAULT}"
APP_GROUP="${APP_GROUP:-$APP_GROUP_DEFAULT}"

SETUP_STATE_DIR="$APP_HOME/.setup"
ENV_FILE="$APP_HOME/.env"
PATH_EXPORT_FILE="$APP_HOME/.profile"

# Determine OS and package manager
OS_FAMILY=""
PKG_MGR=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""
PKG_CLEAN_CMD=""

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    OS_FAMILY="debian"
    PKG_MGR="apt-get"
    PKG_UPDATE_CMD="apt-get update -y"
    PKG_INSTALL_CMD="apt-get install -y --no-install-recommends"
    PKG_CLEAN_CMD="rm -rf /var/lib/apt/lists/*"
  elif command -v apk >/dev/null 2>&1; then
    OS_FAMILY="alpine"
    PKG_MGR="apk"
    PKG_UPDATE_CMD="apk update"
    PKG_INSTALL_CMD="apk add --no-cache"
    PKG_CLEAN_CMD="true"
  elif command -v dnf >/dev/null 2>&1; then
    OS_FAMILY="redhat"
    PKG_MGR="dnf"
    PKG_UPDATE_CMD="dnf -y makecache"
    PKG_INSTALL_CMD="dnf -y install"
    PKG_CLEAN_CMD="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    OS_FAMILY="redhat"
    PKG_MGR="yum"
    PKG_UPDATE_CMD="yum -y makecache"
    PKG_INSTALL_CMD="yum -y install"
    PKG_CLEAN_CMD="yum clean all"
  elif command -v zypper >/dev/null 2>&1; then
    OS_FAMILY="suse"
    PKG_MGR="zypper"
    PKG_UPDATE_CMD="zypper --non-interactive refresh"
    PKG_INSTALL_CMD="zypper --non-interactive install --no-recommends"
    PKG_CLEAN_CMD="zypper --non-interactive clean -a"
  else
    err "No supported package manager found (apt, apk, dnf, yum, zypper). Please use a standard Linux base image."
    exit 1
  fi
  log "Detected OS family: $OS_FAMILY, package manager: $PKG_MGR"
}

# Update package index (idempotent-ish via state file)
pkg_update_once() {
  mkdir -p "$SETUP_STATE_DIR"
  local state_file="$SETUP_STATE_DIR/pkg_updated_${PKG_MGR}.stamp"
  if [[ ! -f "$state_file" ]]; then
    log "Updating package index with $PKG_MGR..."
    sh -c "$PKG_UPDATE_CMD"
    touch "$state_file"
  else
    log "Package index already updated for $PKG_MGR (skipping)."
  fi
}

# Install base packages common across stacks
install_base_packages() {
  log "Installing base system packages..."
  case "$OS_FAMILY" in
    debian)
      sh -c "$PKG_INSTALL_CMD ca-certificates curl git tzdata pkg-config build-essential bash"
      # localizations optional
      if command -v locale-gen >/dev/null 2>&1; then
        $PKG_INSTALL_CMD locales || true
        sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
        locale-gen || true
      fi
      update-ca-certificates || true
      ;;
    alpine)
      sh -c "$PKG_INSTALL_CMD ca-certificates curl git tzdata bash build-base pkgconf"
      update-ca-certificates || true
      ;;
    redhat)
      sh -c "$PKG_INSTALL_CMD ca-certificates curl git tzdata bash gcc gcc-c++ make pkgconf"
      update-ca-trust || true
      ;;
    suse)
      sh -c "$PKG_INSTALL_CMD ca-certificates curl git timezone bash gcc gcc-c++ make pkg-config"
      update-ca-certificates || true
      ;;
  esac
  sh -c "$PKG_CLEAN_CMD" || true
  log "Base system packages installed."
}

# Create app user/group if running as root
ensure_app_user() {
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "Not running as root; skipping user/group creation."
    return 0
  fi

  # Create group if not exists
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    log "Creating group: $APP_GROUP"
    groupadd -r "$APP_GROUP"
  else
    log "Group '$APP_GROUP' already exists."
  fi

  # Create user if not exists
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    log "Creating user: $APP_USER"
    useradd -r -g "$APP_GROUP" -m -s /bin/bash "$APP_USER"
  else
    log "User '$APP_USER' already exists."
  fi
}

# Create project directories and set permissions
setup_dirs() {
  log "Setting up project directories at $APP_HOME..."
  mkdir -p "$APP_HOME"
  mkdir -p "$APP_HOME"/{logs,tmp,data,bin}
  mkdir -p "$SETUP_STATE_DIR"
  touch "$APP_HOME/.gitkeep" || true
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "$APP_USER":"$APP_GROUP" "$APP_HOME"
  fi
  chmod -R u+rwX,go-rwx "$APP_HOME"
  log "Directory structure prepared."
}

# Detect project types based on files
detect_project_types() {
  PROJECT_TYPES=()
  # Use current working directory if APP_HOME empty
  local dir="${APP_HOME:-$PWD}"

  [[ -f "$dir/package.json" ]] && PROJECT_TYPES+=("node")
  [[ -f "$dir/requirements.txt" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" || -f "$dir/Pipfile" ]] && PROJECT_TYPES+=("python")
  [[ -f "$dir/go.mod" ]] && PROJECT_TYPES+=("go")
  [[ -f "$dir/pom.xml" || -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]] && PROJECT_TYPES+=("java")
  [[ -f "$dir/Gemfile" ]] && PROJECT_TYPES+=("ruby")
  [[ -f "$dir/composer.json" ]] && PROJECT_TYPES+=("php")
  [[ -f "$dir/Cargo.toml" ]] && PROJECT_TYPES+=("rust")
  # .NET detection for SDK availability; installation is complex so we only configure if present
  if compgen -G "$dir/*.csproj" >/dev/null || compgen -G "$dir/*.sln" >/dev/null; then
    PROJECT_TYPES+=(".net")
  fi

  if [[ ${#PROJECT_TYPES[@]} -eq 0 ]]; then
    warn "No specific project type detected in $dir. The script will install base tooling only."
  else
    log "Detected project types: ${PROJECT_TYPES[*]}"
  fi
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$OS_FAMILY" in
    debian)
      sh -c "$PKG_INSTALL_CMD python3 python3-venv python3-pip python3-dev"
      ;;
    alpine)
      sh -c "$PKG_INSTALL_CMD python3 python3-dev py3-pip"
      ;;
    redhat)
      sh -c "$PKG_INSTALL_CMD python3 python3-pip python3-devel"
      ;;
    suse)
      sh -c "$PKG_INSTALL_CMD python3 python3-pip python3-devel"
      ;;
  esac

  local venv_dir="$APP_HOME/.venv"
  if [[ ! -d "$venv_dir" ]]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Python virtual environment already exists at $venv_dir"
  fi

  # Activate venv for installation
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel

  if [[ -f "$APP_HOME/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    python3 -m pip install -r "$APP_HOME/requirements.txt"
  elif [[ -f "$APP_HOME/pyproject.toml" ]]; then
    log "Installing Python project via pyproject.toml (PEP 517)"
    # Attempt with pip; if poetry detected, install poetry and use it
    if grep -qi "tool.poetry" "$APP_HOME/pyproject.toml"; then
      python3 -m pip install poetry
      POETRY_VENV="$APP_HOME/.poetry_venv"
      poetry config virtualenvs.in-project true || true
      poetry install --no-interaction --no-ansi
    else
      python3 -m pip install .
    fi
  elif [[ -f "$APP_HOME/Pipfile" ]]; then
    python3 -m pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  else
    log "No Python dependency manifest found; skipping dependency installation."
  fi

  # Set common Python env vars
  {
    echo "PYTHONUNBUFFERED=1"
    echo "PIP_DISABLE_PIP_VERSION_CHECK=1"
    echo "VIRTUAL_ENV=$venv_dir"
    echo "PATH=$venv_dir/bin:\$PATH"
  } >> "$ENV_FILE"

  # Framework-specific hints
  if [[ -f "$APP_HOME/app.py" ]] || grep -qi "flask" "$APP_HOME/requirements.txt" 2>/dev/null; then
    {
      echo "FLASK_APP=${FLASK_APP:-app.py}"
      echo "FLASK_ENV=${FLASK_ENV:-production}"
      echo "FLASK_RUN_PORT=${FLASK_RUN_PORT:-5000}"
      echo "APP_PORT=${APP_PORT:-5000}"
    } >> "$ENV_FILE"
  fi
  if [[ -f "$APP_HOME/manage.py" ]] || grep -qi "django" "$APP_HOME/requirements.txt" 2>/dev/null; then
    {
      echo "DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE:-}"
      echo "APP_PORT=${APP_PORT:-8000}"
    } >> "$ENV_FILE"
  fi

  deactivate || true
  log "Python setup complete."
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  local install_done=false
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "Node.js and npm already installed: node $(node -v), npm $(npm -v)"
    install_done=true
  fi

  if [[ "$install_done" == false ]]; then
    case "$OS_FAMILY" in
      debian)
        sh -c "$PKG_INSTALL_CMD nodejs npm"
        ;;
      alpine)
        sh -c "$PKG_INSTALL_CMD nodejs npm"
        ;;
      redhat)
        sh -c "$PKG_INSTALL_CMD nodejs npm"
        ;;
      suse)
        sh -c "$PKG_INSTALL_CMD nodejs npm"
        ;;
    esac
    log "Node.js installed."
  fi

  # Install project dependencies
  if [[ -f "$APP_HOME/package-lock.json" ]]; then
    log "Installing Node.js dependencies with npm ci"
    (cd "$APP_HOME" && npm ci --no-audit --no-fund)
  elif [[ -f "$APP_HOME/package.json" ]]; then
    log "Installing Node.js dependencies with npm install"
    (cd "$APP_HOME" && npm install --no-audit --no-fund)
  else
    log "No package.json found; skipping npm install."
  fi

  # Set common Node env vars
  {
    echo "NODE_ENV=${NODE_ENV:-production}"
    echo "NPM_CONFIG_LOGLEVEL=${NPM_CONFIG_LOGLEVEL:-warn}"
    echo "APP_PORT=${APP_PORT:-3000}"
  } >> "$ENV_FILE"

  log "Node.js setup complete."
}

# Go setup
setup_go() {
  log "Setting up Go (Golang) environment..."
  local go_bin="/usr/local/go/bin/go"
  if [[ ! -x "$go_bin" ]] && ! command -v go >/dev/null 2>&1; then
    # Install a recent Go via tarball if curl available
    local go_version="1.22.5"
    local arch="$(uname -m)"
    local go_arch="amd64"
    case "$arch" in
      x86_64) go_arch="amd64" ;;
      aarch64|arm64) go_arch="arm64" ;;
      armv7l) go_arch="armv6l" ;;
      *) go_arch="amd64" ;;
    esac
    log "Downloading and installing Go $go_version for $go_arch"
    curl -fsSL "https://go.dev/dl/go${go_version}.linux-${go_arch}.tar.gz" -o /tmp/go.tgz
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
  else
    log "Go already installed: $(go version 2>/dev/null || "$go_bin" version)"
  fi

  # Set GOPATH and PATH
  local gopath="$APP_HOME/.go"
  mkdir -p "$gopath"
  {
    echo "GOROOT=/usr/local/go"
    echo "GOPATH=$gopath"
    echo "PATH=/usr/local/go/bin:\$GOPATH/bin:\$PATH"
    echo "APP_PORT=${APP_PORT:-8080}"
  } >> "$ENV_FILE"

  # Download modules if go.mod exists
  if [[ -f "$APP_HOME/go.mod" ]]; then
    log "Downloading Go modules..."
    (cd "$APP_HOME" && /usr/local/go/bin/go mod download || go mod download)
  fi
  log "Go setup complete."
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "$OS_FAMILY" in
    debian)
      sh -c "$PKG_INSTALL_CMD openjdk-17-jdk maven"
      ;;
    alpine)
      sh -c "$PKG_INSTALL_CMD openjdk17 maven"
      ;;
    redhat)
      sh -c "$PKG_INSTALL_CMD java-17-openjdk-devel maven"
      ;;
    suse)
      sh -c "$PKG_INSTALL_CMD java-17-openjdk-devel maven"
      ;;
  esac
  # Gradle optional
  if [[ -f "$APP_HOME/build.gradle" || -f "$APP_HOME/build.gradle.kts" ]]; then
    case "$OS_FAMILY" in
      debian|suse) sh -c "$PKG_INSTALL_CMD gradle" || warn "Failed to install gradle; relying on gradlew if present." ;;
      alpine|redhat) sh -c "$PKG_INSTALL_CMD gradle" || warn "Failed to install gradle; relying on gradlew if present." ;;
    esac
  fi

  # Set JAVA_HOME and PATH
  local java_home=""
  case "$OS_FAMILY" in
    debian|suse) java_home="/usr/lib/jvm/java-17-openjdk-amd64" ;;
    redhat) java_home="/usr/lib/jvm/java-17-openjdk" ;;
    alpine) java_home="/usr/lib/jvm/java-17-openjdk" ;;
  esac
  [[ -d "$java_home" ]] || java_home="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  {
    echo "JAVA_HOME=$java_home"
    echo "PATH=\$JAVA_HOME/bin:\$PATH"
    echo "APP_PORT=${APP_PORT:-8080}"
  } >> "$ENV_FILE"

  log "Java setup complete."
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$OS_FAMILY" in
    debian) sh -c "$PKG_INSTALL_CMD ruby-full build-essential" ;;
    alpine) sh -c "$PKG_INSTALL_CMD ruby ruby-dev build-base" ;;
    redhat) sh -c "$PKG_INSTALL_CMD ruby ruby-devel gcc make" ;;
    suse) sh -c "$PKG_INSTALL_CMD ruby ruby-devel gcc make" ;;
  esac

  if command -v gem >/dev/null 2>&1; then
    gem install --no-document bundler || true
  fi

  if [[ -f "$APP_HOME/Gemfile" ]]; then
    log "Installing Ruby gems with bundler"
    (cd "$APP_HOME" && bundle install --without development test || bundle install)
  fi

  echo "APP_PORT=${APP_PORT:-3000}" >> "$ENV_FILE"
  log "Ruby setup complete."
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$OS_FAMILY" in
    debian) sh -c "$PKG_INSTALL_CMD php-cli php-mbstring unzip" ;;
    alpine) sh -c "$PKG_INSTALL_CMD php php-cli php-phar php-mbstring unzip" ;;
    redhat) sh -c "$PKG_INSTALL_CMD php-cli php-mbstring unzip" ;;
    suse) sh -c "$PKG_INSTALL_CMD php-cli php7-mbstring unzip" || sh -c "$PKG_INSTALL_CMD php-cli mbstring unzip" ;;
  esac

  # Install Composer
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if [[ -f "$APP_HOME/composer.json" ]]; then
    log "Installing PHP dependencies with Composer"
    (cd "$APP_HOME" && composer install --no-interaction --no-progress --no-dev || composer install --no-interaction --no-progress)
  fi

  echo "APP_PORT=${APP_PORT:-9000}" >> "$ENV_FILE"
  log "PHP setup complete."
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing rustup (Rust toolchain manager)..."
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal
    rm -f /tmp/rustup.sh
    # Source cargo env for this session
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env" || true
  else
    log "Rust already installed: $(rustc --version 2>/dev/null || true)"
  fi

  {
    echo "PATH=\$HOME/.cargo/bin:\$PATH"
    echo "APP_PORT=${APP_PORT:-8000}"
  } >> "$ENV_FILE"

  if [[ -f "$APP_HOME/Cargo.toml" ]]; then
    log "Fetching Rust dependencies (cargo fetch)"
    (cd "$APP_HOME" && cargo fetch || true)
  fi
  log "Rust setup complete."
}

# .NET setup (env-only; installation often requires external repos)
setup_dotnet_env() {
  log "Configuring .NET environment (skipping SDK installation)."
  if command -v dotnet >/dev/null 2>&1; then
    log "dotnet SDK present: $(dotnet --version)"
  else
    warn "dotnet SDK not found. Consider using a dotnet base image or install SDK via official Microsoft repositories."
  fi
  echo "APP_PORT=${APP_PORT:-8080}" >> "$ENV_FILE"
}

# Write baseline environment variables
write_baseline_env() {
  log "Writing baseline environment file at $ENV_FILE"
  touch "$ENV_FILE"
  {
    echo "APP_HOME=$APP_HOME"
    echo "APP_ENV=${APP_ENV:-production}"
    echo "TZ=$TZ"
    echo "LANG=${LANG:-en_US.UTF-8}"
    echo "LC_ALL=${LC_ALL:-en_US.UTF-8}"
  } >> "$ENV_FILE"

  # Ensure profile to load env on shell login
  {
    echo "[ -f \"$ENV_FILE\" ] && set -a && . \"$ENV_FILE\" && set +a"
  } >> "$PATH_EXPORT_FILE"

  if [[ "$(id -u)" -eq 0 ]]; then
    chown "$APP_USER":"$APP_GROUP" "$ENV_FILE" "$PATH_EXPORT_FILE" || true
    chmod 0640 "$ENV_FILE" || true
    chmod 0644 "$PATH_EXPORT_FILE" || true
  fi
  log "Baseline environment configured."
}

# Main execution
main() {
  log "Starting project environment setup for container..."
  detect_pkg_mgr
  pkg_update_once
  install_base_packages
  ensure_app_user
  setup_dirs

  # Use APP_HOME as working directory if exists, otherwise fallback to current dir
  if [[ -d "$APP_HOME" ]]; then
    cd "$APP_HOME"
  fi

  # Initialize env files
  : > "$ENV_FILE"
  : > "$PATH_EXPORT_FILE"

  write_baseline_env

  detect_project_types

  # Install per detected type(s)
  local has_type=false
  for t in "${PROJECT_TYPES[@]:-}"; do
    has_type=true
    case "$t" in
      python) setup_python ;;
      node) setup_node ;;
      go) setup_go ;;
      java) setup_java ;;
      ruby) setup_ruby ;;
      php) setup_php ;;
      rust) setup_rust ;;
      .net) setup_dotnet_env ;;
      *) warn "Unknown project type: $t" ;;
    esac
  done

  if [[ "$has_type" == false ]]; then
    warn "No project type detected. Base system and environment prepared. You may need to customize runtime installation."
  fi

  # Final permissions and summary
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "$APP_USER":"$APP_GROUP" "$APP_HOME"
  fi

  log "Environment setup completed successfully."
  echo "Environment file created at: $ENV_FILE"
  echo "To load environment in shell: source \"$PATH_EXPORT_FILE\""
  echo "Common directories:"
  echo " - Logs: $APP_HOME/logs"
  echo " - Temp: $APP_HOME/tmp"
  echo " - Data: $APP_HOME/data"
  echo "If running the container, set working directory to $APP_HOME and ensure application entrypoint uses the configured environment."
}

main "$@"