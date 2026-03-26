#!/usr/bin/env bash
# Universal Project Environment Setup Script for Docker Containers
# This script detects the project's tech stack and installs required runtimes,
# system packages, and dependencies. It is idempotent and safe to re-run.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
info() { echo -e "${BLUE}$*${NC}"; }

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Setup failed with exit code $exit_code on line ${BASH_LINENO[0]}."
  fi
  # No special cleanup for now
}
trap cleanup EXIT

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "This script must run as root in a Docker container (no sudo available)."
    exit 1
  fi
}

# Globals
APP_HOME="${APP_HOME:-$PWD}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
APP_PORT="${APP_PORT:-8080}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"
SKIP_SYSTEM_PACKAGES="${SKIP_SYSTEM_PACKAGES:-0}"

PKG_MGR=""
OS_FAMILY=""

detect_pkg_mgr() {
  if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    OS_FAMILY="alpine"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    OS_FAMILY="debian"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    OS_FAMILY="redhat"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    OS_FAMILY="redhat"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    OS_FAMILY="suse"
  else
    err "No supported package manager found (apk/apt/dnf/yum/zypper)."
    exit 1
  fi
  log "Detected package manager: $PKG_MGR (OS family: $OS_FAMILY)"
}

pm_update() {
  case "$PKG_MGR" in
    apk)
      apk update
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache fast || yum -y makecache
      ;;
    zypper)
      zypper --non-interactive refresh
      ;;
  esac
}

pm_install() {
  case "$PKG_MGR" in
    apk)
      apk add --no-cache "$@"
      ;;
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
  esac
}

pm_cleanup() {
  case "$PKG_MGR" in
    apk)
      # nothing needed
      ;;
    apt)
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb || true
      ;;
    dnf|yum)
      dnf clean all >/dev/null 2>&1 || yum clean all >/dev/null 2>&1 || true
      rm -rf /var/cache/dnf /var/cache/yum || true
      ;;
    zypper)
      zypper clean --all || true
      ;;
  esac
}

install_base_tools() {
  if [[ "$SKIP_SYSTEM_PACKAGES" == "1" ]]; then
    warn "Skipping system package installation due to SKIP_SYSTEM_PACKAGES=1"
    return 0
  fi
  log "Installing base system tools..."
  pm_update
  case "$PKG_MGR" in
    apk)
      pm_install bash ca-certificates curl wget git coreutils findutils grep sed awk musl-utils tar xz unzip gzip bzip2 openssl build-base shadow su-exec
      update-ca-certificates || true
      ;;
    apt)
      pm_install bash ca-certificates curl wget git coreutils findutils grep sed gawk tar xz-utils unzip gzip bzip2 openssl build-essential pkg-config apt-transport-https gnupg dirmngr passwd adduser uidmap
      update-ca-certificates || true
      ;;
    dnf|yum)
      pm_install bash ca-certificates curl wget git coreutils findutils grep sed gawk tar xz unzip gzip bzip2 openssl make automake gcc gcc-c++ kernel-devel shadow-utils
      update-ca-trust || true
      ;;
    zypper)
      pm_install bash ca-certificates curl wget git coreutils findutils grep sed gawk tar xz unzip gzip bzip2 libopenssl-devel make gcc gcc-c++ shadow
      ;;
  esac
  pm_cleanup
  log "Base system tools installed."
}

ensure_user_group() {
  log "Ensuring application user and group exist..."
  if id -g "$APP_GROUP" >/dev/null 2>&1; then
    :
  else
    case "$OS_FAMILY" in
      alpine)
        addgroup -g "$APP_GID" "$APP_GROUP"
        ;;
      debian|redhat|suse)
        groupadd -g "$APP_GID" "$APP_GROUP"
        ;;
    esac
  fi

  if id -u "$APP_USER" >/dev/null 2>&1; then
    :
  else
    case "$OS_FAMILY" in
      alpine)
        adduser -D -H -s /sbin/nologin -G "$APP_GROUP" -u "$APP_UID" "$APP_USER"
        ;;
      debian|redhat|suse)
        useradd -m -s /usr/sbin/nologin -g "$APP_GROUP" -u "$APP_UID" "$APP_USER"
        ;;
    esac
  fi
  log "User $APP_USER and group $APP_GROUP are ready."
}

setup_project_dir() {
  log "Setting up project directory at: $APP_HOME"
  mkdir -p "$APP_HOME"
  chown -R "$APP_USER":"$APP_GROUP" "$APP_HOME"
  chmod -R u=rwX,g=rX,o= "$APP_HOME" || true
}

write_env_profile() {
  log "Configuring environment variables..."
  local profile="/etc/profile.d/app_env.sh"
  cat > "$profile" <<EOF
# Auto-generated by setup script
export APP_HOME="${APP_HOME}"
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
# Extend PATH for common toolchains
export PATH="\$APP_HOME/.venv/bin:\$APP_HOME/venv/bin:\$APP_HOME/node_modules/.bin:/usr/local/dotnet:\$PATH"
# Rust and Go (if installed)
[ -d "/root/.cargo/bin" ] && export PATH="/root/.cargo/bin:\$PATH"
[ -d "/usr/local/go/bin" ] && export PATH="/usr/local/go/bin:\$PATH"
# DOTNET
[ -d "/usr/local/dotnet" ] && export DOTNET_ROOT="/usr/local/dotnet"
EOF
  chmod 0644 "$profile"
  # .env file for app-level variables (do not overwrite if exists)
  local dotenv="${APP_HOME}/.env"
  if [[ ! -f "$dotenv" ]]; then
    cat > "$dotenv" <<EOF
# Application environment file
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
EOF
    chown "$APP_USER":"$APP_GROUP" "$dotenv"
    chmod 0640 "$dotenv"
  fi
  log "Environment configuration written."
}

write_venv_auto_activate() {
  local bashrc="/root/.bashrc"
  local venv_path=""
  if [ -d "$APP_HOME/.venv" ]; then venv_path="$APP_HOME/.venv"; elif [ -d "$APP_HOME/venv" ]; then venv_path="$APP_HOME/venv"; fi
  if [ -n "$venv_path" ]; then
    mkdir -p "$(dirname "$bashrc")"
    if ! grep -q "source \"$venv_path/bin/activate\"" "$bashrc" 2>/dev/null; then
      {
        echo "";
        echo "# Auto-activate project virtualenv";
        echo "[ -f \"$venv_path/bin/activate\" ] && source \"$venv_path/bin/activate\"";
      } >> "$bashrc"
    fi
  fi
}

# Alias required by repair instructions; wrap existing implementation
setup_auto_activate() {
  write_venv_auto_activate
}

# Install a python wrapper to robustly handle improperly split `python -c` invocations
setup_python_wrapper() {
  local wrapper="/usr/local/bin/python"
  if [[ ! -f "$wrapper" || ! -x "$wrapper" ]]; then
    cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Wrapper to robustly handle improperly split `python -c` invocations
if [[ "${1-}" == "-c" && -n "${2-}" ]]; then
  code="$2"
  shift 2
  # If any additional tokens exist, join them back into the code string
  if [[ $# -gt 0 ]]; then
    code="$code $*"
    set --
  fi
  exec "$(command -v python3)" -c "$code"
else
  exec "$(command -v python3)" "$@"
fi
EOF
    chmod +x "$wrapper"
  fi
}

# ==================== Stack Detection ====================

has_file() { [[ -f "$APP_HOME/$1" ]]; }
has_any() {
  local f
  for f in "$@"; do
    has_file "$f" && return 0
  done
  return 1
}

# ==================== Installers for Stacks ====================

install_python_stack() {
  log "Detected Python project. Installing Python and dependencies..."
  case "$PKG_MGR" in
    apk)
      pm_update
      pm_install python3 py3-pip python3-dev build-base libffi-dev openssl-dev
      ;;
    apt)
      pm_update
      pm_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev
      ;;
    dnf|yum)
      pm_update
      pm_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    zypper)
      pm_update
      pm_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel libopenssl-devel
      ;;
  esac
  pm_cleanup

  local venv_dir=""
  if [[ -d "$APP_HOME/.venv" ]]; then
    venv_dir="$APP_HOME/.venv"
  elif [[ -d "$APP_HOME/venv" ]]; then
    venv_dir="$APP_HOME/venv"
  else
    venv_dir="$APP_HOME/.venv"
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
    chown -R "$APP_USER":"$APP_GROUP" "$venv_dir"
  fi
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"

  python3 -m pip install --upgrade pip wheel setuptools

  if has_file "requirements.txt"; then
    log "Installing Python packages from requirements.txt"
    pip install --no-cache-dir -r "$APP_HOME/requirements.txt"
  elif has_file "pyproject.toml"; then
    if has_file "poetry.lock" || grep -qiE '^\s*\[tool\.poetry\]' "$APP_HOME/pyproject.toml"; then
      log "PyProject with Poetry detected. Installing Poetry and dependencies..."
      pip install --no-cache-dir "poetry>=1.6"
      su -s /bin/sh -c "cd \"$APP_HOME\" && poetry config virtualenvs.create false && poetry install --no-root --no-interaction --no-ansi" "$APP_USER"
    else
      log "Installing project via pip from pyproject.toml"
      pip install --no-cache-dir "$APP_HOME"
    fi
  elif has_file "setup.py" || has_file "setup.cfg"; then
    log "Installing project in editable mode"
    pip install --no-cache-dir -e "$APP_HOME"
  else
    warn "No Python dependency file found. Skipping package installation."
  fi

  deactivate || true
  log "Python environment setup complete."
}

install_node_stack() {
  log "Detected Node.js project. Installing Node.js and dependencies..."
  case "$PKG_MGR" in
    apk)
      pm_update
      pm_install nodejs npm
      ;;
    apt)
      pm_update
      pm_install nodejs npm
      ;;
    dnf|yum)
      pm_update
      pm_install nodejs npm
      ;;
    zypper)
      pm_update
      pm_install nodejs npm
      ;;
  esac
  pm_cleanup

  pushd "$APP_HOME" >/dev/null
  if has_file "package-lock.json"; then
    log "Running npm ci"
    npm ci --no-audit --no-fund
  elif has_file "yarn.lock"; then
    log "yarn.lock detected. Installing yarn and installing dependencies..."
    case "$PKG_MGR" in
      apk) pm_install yarn ;;
      apt) pm_install yarnpkg || pm_install yarn || true ;;
      dnf|yum) pm_install yarnpkg || true ;;
      zypper) pm_install yarn || true ;;
    esac
    if command -v yarn >/dev/null 2>&1; then
      yarn install --frozen-lockfile --non-interactive
    elif command -v yarnpkg >/dev/null 2>&1; then
      yarnpkg install --frozen-lockfile --non-interactive
    else
      warn "Yarn not available via package manager; falling back to npm install"
      npm install --no-audit --no-fund
    fi
  else
    log "Running npm install"
    npm install --no-audit --no-fund
  fi
  popd >/dev/null
  log "Node.js environment setup complete."
}

install_ruby_stack() {
  log "Detected Ruby project. Installing Ruby and Bundler..."
  case "$PKG_MGR" in
    apk)
      pm_update
      pm_install ruby ruby-dev build-base
      ;;
    apt)
      pm_update
      pm_install ruby-full build-essential
      ;;
    dnf|yum)
      pm_update
      pm_install ruby ruby-devel make gcc gcc-c++
      ;;
    zypper)
      pm_update
      pm_install ruby ruby-devel make gcc gcc-c++
      ;;
  esac
  pm_cleanup

  gem install --no-document bundler
  pushd "$APP_HOME" >/dev/null
  if has_file "Gemfile"; then
    log "Running bundle install (vendor/bundle)"
    su -s /bin/sh -c "cd \"$APP_HOME\" && bundle config set path 'vendor/bundle' && bundle install --jobs $(nproc)" "$APP_USER"
  else
    warn "No Gemfile found."
  fi
  popd >/dev/null
  log "Ruby environment setup complete."
}

install_java_stack() {
  log "Detected Java project. Installing OpenJDK and build tools..."
  case "$PKG_MGR" in
    apk)
      pm_update
      pm_install openjdk17-jdk maven gradle
      ;;
    apt)
      pm_update
      pm_install openjdk-17-jdk maven gradle
      ;;
    dnf|yum)
      pm_update
      pm_install java-17-openjdk java-17-openjdk-devel maven gradle
      ;;
    zypper)
      pm_update
      pm_install java-17-openjdk java-17-openjdk-devel maven gradle
      ;;
  esac
  pm_cleanup

  pushd "$APP_HOME" >/dev/null
  if has_file "mvnw"; then
    chmod +x mvnw
    ./mvnw -B -DskipTests dependency:go-offline || true
  elif has_file "pom.xml"; then
    mvn -B -DskipTests dependency:go-offline || true
  fi
  if has_file "gradlew"; then
    chmod +x gradlew
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
  elif has_any "build.gradle" "build.gradle.kts"; then
    gradle --no-daemon tasks >/dev/null 2>&1 || true
  fi
  popd >/dev/null
  log "Java environment setup complete."
}

install_go_stack() {
  log "Detected Go project. Installing Go toolchain..."
  case "$PKG_MGR" in
    apk)
      pm_update
      pm_install go
      ;;
    apt)
      pm_update
      pm_install golang
      ;;
    dnf|yum)
      pm_update
      pm_install golang
      ;;
    zypper)
      pm_update
      pm_install go
      ;;
  esac
  pm_cleanup

  pushd "$APP_HOME" >/dev/null
  if has_file "go.mod"; then
    log "Downloading Go modules..."
    GOPATH="${GOPATH:-/go}" go mod download
  fi
  popd >/dev/null
  log "Go environment setup complete."
}

install_php_stack() {
  log "Detected PHP project. Installing PHP and Composer..."
  case "$PKG_MGR" in
    apk)
      pm_update
      pm_install php81 php81-cli php81-phar php81-openssl php81-mbstring php81-tokenizer php81-xml php81-zip php81-curl php81-json php81-dom
      ln -sf /usr/bin/php81 /usr/bin/php || true
      ;;
    apt)
      pm_update
      pm_install php-cli php-xml php-curl php-zip php-mbstring php-json
      ;;
    dnf|yum)
      pm_update
      pm_install php-cli php-xml php-json php-mbstring php-zip php-curl
      ;;
    zypper)
      pm_update
      pm_install php8 php8-cli php8-xml php8-curl php8-zip php8-mbstring
      ln -sf /usr/bin/php8 /usr/bin/php || true
      ;;
  esac
  pm_cleanup

  # Install Composer (local to /usr/local/bin)
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi

  pushd "$APP_HOME" >/dev/null
  if has_file "composer.json"; then
    log "Installing Composer dependencies (no-dev in production)..."
    if has_file "composer.lock"; then
      COMPOSER_NO_INTERACTION=1 composer install --no-ansi --no-progress --prefer-dist $( [[ "$APP_ENV" == "production" ]] && printf %s "--no-dev" )
    else
      COMPOSER_NO_INTERACTION=1 composer update --no-ansi --no-progress --prefer-dist $( [[ "$APP_ENV" == "production" ]] && printf %s "--no-dev" )
    fi
  else
    warn "No composer.json found."
  fi
  popd >/dev/null
  log "PHP environment setup complete."
}

install_rust_stack() {
  log "Detected Rust project. Installing Rust toolchain via rustup..."
  if ! command -v rustc >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal
    rm -f /tmp/rustup.sh
    # Add cargo to PATH for current shell
    export PATH="/root/.cargo/bin:${PATH}"
  fi
  pushd "$APP_HOME" >/dev/null
  if has_file "Cargo.toml"; then
    /root/.cargo/bin/cargo fetch || true
  fi
  popd >/dev/null
  log "Rust environment setup complete."
}

install_dotnet_stack() {
  log "Detected .NET project. Installing .NET SDK (LTS) via official installer..."
  local DOTNET_DIR="/usr/local/dotnet"
  mkdir -p "$DOTNET_DIR"
  if [[ ! -x "$DOTNET_DIR/dotnet" ]]; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir "$DOTNET_DIR" --channel LTS --quality ga --verbose
    rm -f /tmp/dotnet-install.sh
  fi
  export DOTNET_ROOT="$DOTNET_DIR"
  export PATH="$DOTNET_DIR:$PATH"
  pushd "$APP_HOME" >/dev/null
  # Restore if project files present
  if compgen -G "*.sln" >/dev/null || compgen -G "*.csproj" >/dev/null || compgen -G "*.fsproj" >/dev/null; then
    "$DOTNET_DIR/dotnet" restore || true
  fi
  popd >/dev/null
  log ".NET environment setup complete."
}

# ==================== Stack Dispatcher ====================

detect_and_install_stacks() {
  local detected=0

  # Python
  if has_any "requirements.txt" "pyproject.toml" "Pipfile" "setup.py" "setup.cfg"; then
    install_python_stack
    detected=1
  fi

  # Node.js
  if has_file "package.json"; then
    install_node_stack
    detected=1
  fi

  # Ruby
  if has_file "Gemfile"; then
    install_ruby_stack
    detected=1
  fi

  # Java (Maven/Gradle)
  if has_any "pom.xml" "mvnw" "build.gradle" "build.gradle.kts" "gradlew"; then
    install_java_stack
    detected=1
  fi

  # Go
  if has_file "go.mod"; then
    install_go_stack
    detected=1
  fi

  # PHP
  if has_file "composer.json"; then
    install_php_stack
    detected=1
  fi

  # Rust
  if has_file "Cargo.toml"; then
    install_rust_stack
    detected=1
  fi

  # .NET
  if compgen -G "$APP_HOME/*.sln" >/dev/null || compgen -G "$APP_HOME/*.csproj" >/dev/null || compgen -G "$APP_HOME/*.fsproj" >/dev/null; then
    install_dotnet_stack
    detected=1
  fi

  if [[ "$detected" -eq 0 ]]; then
    warn "No supported project stack detected. Place this script in the project root with standard config files."
  fi
}

# ==================== Main ====================

main() {
  info "==============================================="
  info " Universal Environment Setup for Docker"
  info " Project root: $APP_HOME"
  info "==============================================="

  require_root
  detect_pkg_mgr
  install_base_tools
  ensure_user_group
  setup_project_dir
  write_env_profile
  setup_python_wrapper

  detect_and_install_stacks
  setup_auto_activate

  # Final ownership to ensure app user can read/write
  chown -R "$APP_USER":"$APP_GROUP" "$APP_HOME" || true

  log "Setup completed successfully."
  echo
  info "Notes:"
  info "- Environment variables are written to /etc/profile.d/app_env.sh and ${APP_HOME}/.env"
  info "- Default APP_ENV=${APP_ENV}, APP_PORT=${APP_PORT}, APP_HOME=${APP_HOME}"
  info "- Re-run this script safely; it is idempotent."
  echo
  info "To use the environment in an interactive shell, run:"
  info "  source /etc/profile.d/app_env.sh"
  echo
}

write_venv_auto_activate; main "$@"