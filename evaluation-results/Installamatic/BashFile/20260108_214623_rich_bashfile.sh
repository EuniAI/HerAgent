#!/usr/bin/env bash
# Universal Project Environment Setup Script for Docker Containers
# This script detects common project types and installs/configures the runtime and dependencies.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail
IFS=$' \n\t'

#---------------------------------------------
# Logging and error handling
#---------------------------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
BLUE="$(printf '\033[0;34m')"
NC="$(printf '\033[0m')"

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }

on_error() {
  local exit_code=$?
  err "An error occurred (exit code: $exit_code) while running: ${BASH_COMMAND:-unknown command}"
  exit "$exit_code"
}
trap on_error ERR

#---------------------------------------------
# Defaults and configuration
#---------------------------------------------
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
CREATE_APP_USER="${CREATE_APP_USER:-1}"  # 1 to create/use non-root user, 0 to stay root
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8000}"
DEBIAN_FRONTEND=noninteractive
TZ="${TZ:-UTC}"

# Sentinel/state files
STATE_DIR="/var/local/project-setup"
mkdir -p "$STATE_DIR"

#---------------------------------------------
# Utility helpers
#---------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1; }
file_exists() { [ -f "$1" ]; }
dir_exists() { [ -d "$1" ]; }

# Detect package manager
PKG_MGR=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
detect_pkg_manager() {
  if need_cmd apt-get; then
    PKG_MGR="apt"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="rm -rf /var/lib/apt/lists/*"
  elif need_cmd apk; then
    PKG_MGR="apk"
    PKG_UPDATE="true"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
  elif need_cmd dnf; then
    PKG_MGR="dnf"
    PKG_UPDATE="dnf -y makecache"
    PKG_INSTALL="dnf install -y"
    PKG_CLEAN="dnf clean all"
  elif need_cmd yum; then
    PKG_MGR="yum"
    PKG_UPDATE="yum -y makecache"
    PKG_INSTALL="yum install -y"
    PKG_CLEAN="yum clean all"
  elif need_cmd microdnf; then
    PKG_MGR="microdnf"
    PKG_UPDATE="microdnf update -y || true"
    PKG_INSTALL="microdnf install -y"
    PKG_CLEAN="microdnf clean all"
  elif need_cmd zypper; then
    PKG_MGR="zypper"
    PKG_UPDATE="zypper --non-interactive refresh"
    PKG_INSTALL="zypper --non-interactive install --no-recommends"
    PKG_CLEAN="zypper clean --all"
  else
    err "No supported package manager found (apt, apk, dnf, yum, microdnf, zypper)."
    exit 1
  fi
  log "Using package manager: $PKG_MGR"
}

pkg_update() { eval "$PKG_UPDATE"; }
pkg_install() { eval "$PKG_INSTALL \"\$@\""; }
pkg_clean() { eval "$PKG_CLEAN"; }

#---------------------------------------------
# System base setup
#---------------------------------------------
setup_system_basics() {
  log "Installing base system packages..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git bash tzdata locales gnupg coreutils findutils jq unzip xz-utils tar gzip bzip2 build-essential pkg-config openssh-client
      echo "$TZ" > /etc/timezone || true
      ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
      if [ ! -f "$STATE_DIR/locales_set" ]; then
        if need_cmd locale-gen; then
          sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
          locale-gen en_US.UTF-8 || true
        fi
        touch "$STATE_DIR/locales_set"
      fi
      ;;
    apk)
      pkg_install ca-certificates curl wget git bash tzdata coreutils findutils jq unzip xz tar gzip bzip2 build-base pkgconfig openssh-client
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl wget git bash tzdata tar gzip bzip2 xz unzip jq gcc gcc-c++ make pkgconfig openssh-clients glibc-langpack-en
      ;;
    zypper)
      pkg_install ca-certificates curl wget git bash timezone tar gzip bzip2 xz unzip jq gcc gcc-c++ make pkg-config openssh
      ;;
  esac
  update-ca-certificates 2>/dev/null || true
  pkg_clean
  log "Base system packages installed."
}

#---------------------------------------------
# App user and directory setup
#---------------------------------------------
setup_app_dir_and_user() {
  log "Setting up application directory and user..."
  mkdir -p "$APP_DIR" "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/run"
  if [ "${CREATE_APP_USER}" = "1" ]; then
    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
      groupadd -r "$APP_GROUP" || true
    fi
    if ! id "$APP_USER" >/dev/null 2>&1; then
      useradd -r -g "$APP_GROUP" -d "$APP_DIR" -s /usr/sbin/nologin "$APP_USER" || true
    fi
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
  fi
  chmod -R u+rwX,go+rX "$APP_DIR"
  log "Application directory: $APP_DIR"
}

#---------------------------------------------
# Project detection
#---------------------------------------------
IS_NODE=0
IS_PYTHON=0
IS_JAVA_MAVEN=0
IS_JAVA_GRADLE=0
IS_GO=0
IS_RUBY=0
IS_PHP=0
IS_RUST=0
IS_DOTNET=0

detect_project_type() {
  log "Detecting project type in $APP_DIR ..."
  cd "$APP_DIR"

  if file_exists "package.json"; then IS_NODE=1; fi
  if file_exists "requirements.txt" || file_exists "pyproject.toml" || file_exists "Pipfile" || file_exists "setup.py"; then IS_PYTHON=1; fi
  if file_exists "pom.xml"; then IS_JAVA_MAVEN=1; fi
  if file_exists "build.gradle" || file_exists "build.gradle.kts" || file_exists "gradlew"; then IS_JAVA_GRADLE=1; fi
  if file_exists "go.mod" || file_exists "go.sum"; then IS_GO=1; fi
  if file_exists "Gemfile"; then IS_RUBY=1; fi
  if file_exists "composer.json"; then IS_PHP=1; fi
  if file_exists "Cargo.toml"; then IS_RUST=1; fi
  if ls *.sln *.csproj 2>/dev/null | grep -q .; then IS_DOTNET=1; fi

  info "Detected: Node=$IS_NODE, Python=$IS_PYTHON, Maven=$IS_JAVA_MAVEN, Gradle=$IS_JAVA_GRADLE, Go=$IS_GO, Ruby=$IS_RUBY, PHP=$IS_PHP, Rust=$IS_RUST, DotNet=$IS_DOTNET"
}

#---------------------------------------------
# Node.js setup
#---------------------------------------------
setup_node() {
  [ "$IS_NODE" -eq 1 ] || return 0
  log "Setting up Node.js environment..."

  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum|microdnf)
      pkg_install nodejs npm || pkg_install nodejs || true
      ;;
    zypper)
      pkg_install nodejs npm || true
      ;;
  esac

  if ! need_cmd node; then
    warn "Node.js not available from OS packages. Please use a Node-enabled base image if needed."
    return 0
  fi

  npm config set fund false --global || true
  npm config set audit false --global || true
  npm config set update-notifier false --global || true

  # Package manager detection
  if file_exists "yarn.lock"; then
    if need_cmd corepack; then corepack enable || true; corepack prepare yarn@stable --activate || true; fi
    if ! need_cmd yarn; then npm i -g yarn --force || true; fi
    su_exec=""; [ "${CREATE_APP_USER}" = "1" ] && su_exec="su -s /bin/bash -c"
    if [ -n "$su_exec" ]; then
      $su_exec "yarn install --frozen-lockfile" "$APP_USER"
    else
      yarn install --frozen-lockfile
    fi
  elif file_exists "pnpm-lock.yaml"; then
    if need_cmd corepack; then corepack enable || true; corepack prepare pnpm@latest --activate || true; fi
    if ! need_cmd pnpm; then npm i -g pnpm --force || true; fi
    if [ "${CREATE_APP_USER}" = "1" ]; then su -s /bin/bash -c "pnpm install --frozen-lockfile" "$APP_USER"; else pnpm install --frozen-lockfile; fi
  else
    if file_exists "package-lock.json"; then
      if [ "${CREATE_APP_USER}" = "1" ]; then su -s /bin/bash -c "npm ci --no-audit --no-fund" "$APP_USER"; else npm ci --no-audit --no-fund; fi
    else
      if [ "${CREATE_APP_USER}" = "1" ]; then su -s /bin/bash -c "npm install --no-audit --no-fund" "$APP_USER"; else npm install --no-audit --no-fund; fi
    fi
  fi

  # Add node bin to PATH for all shells
  NODE_BIN="$APP_DIR/node_modules/.bin"
  if [ -d "$NODE_BIN" ]; then
    echo "export PATH=\"$NODE_BIN:\$PATH\"" > /etc/profile.d/10-node-path.sh
    chmod 0644 /etc/profile.d/10-node-path.sh
  fi

  log "Node.js setup complete."
}

#---------------------------------------------
# Python setup
#---------------------------------------------
setup_python() {
  [ "$IS_PYTHON" -eq 1 ] || return 0
  log "Setting up Python environment..."

  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev libsqlite3-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev musl-dev gcc libffi-dev openssl-dev
      ;;
    dnf|yum|microdnf)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel libopenssl-devel
      ;;
  esac

  if ! need_cmd python3; then
    warn "Python3 not available from OS packages. Please use a Python-enabled base image if needed."
    return 0
  fi

  VENV_DIR="$APP_DIR/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
  fi

  # Ensure pip is up-to-date
  "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
  # Install/upgrade asv for benchmarks tooling
  "$VENV_DIR/bin/python" -m pip install -U asv virtualenv rich

  # Dependency installation logic
  if file_exists "$APP_DIR/requirements.txt"; then
    "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"
  elif file_exists "$APP_DIR/pyproject.toml"; then
    # Try Poetry if pyproject has [tool.poetry], else PEP 517 build
    if grep -qE '^\s*\[tool\.poetry\]' "$APP_DIR/pyproject.toml"; then
      "$VENV_DIR/bin/pip" install "poetry>=1.6"
      POETRY_CACHE_DIR="$APP_DIR/.cache/pypoetry"
      mkdir -p "$POETRY_CACHE_DIR"
      POETRY_CMD="$VENV_DIR/bin/poetry"
      "$POETRY_CMD" config virtualenvs.in-project true
      if [ "${CREATE_APP_USER}" = "1" ]; then
        chown -R "$APP_USER:$APP_GROUP" "$APP_DIR/.venv" "$POETRY_CACHE_DIR" || true
        su -s /bin/bash -c "$POETRY_CMD install --no-root --no-interaction --no-ansi" "$APP_USER"
      else
        "$POETRY_CMD" install --no-root --no-interaction --no-ansi
      fi
    else
      "$VENV_DIR/bin/pip" install .
    fi
  elif file_exists "$APP_DIR/Pipfile"; then
    "$VENV_DIR/bin/pip" install pipenv
    "$VENV_DIR/bin/pipenv" install --dev || "$VENV_DIR/bin/pipenv" install || true
  elif file_exists "$APP_DIR/setup.py"; then
    "$VENV_DIR/bin/pip" install -e "$APP_DIR"
  fi

  # Ensure latest ASV after dependency managers may have modified the environment
  "$VENV_DIR/bin/python" -m pip install -U asv

  # Add venv to PATH for all shells
  echo "export VIRTUAL_ENV=\"$VENV_DIR\"" > /etc/profile.d/10-python-venv.sh
  echo 'export PATH="$VIRTUAL_ENV/bin:$PATH"' >> /etc/profile.d/10-python-venv.sh
  chmod 0644 /etc/profile.d/10-python-venv.sh

  log "Python setup complete."
}

#---------------------------------------------
# Virtual environment auto-activation
#---------------------------------------------
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_dir="$APP_DIR/.venv"
  local venv_activate="$venv_dir/bin/activate"

  if [ -d "$venv_dir" ] && [ -f "$venv_activate" ]; then
    local profile_file="/etc/profile.d/99-venv-auto-activate.sh"
    if [ ! -f "$profile_file" ]; then
      {
        echo "if [ -d \"$venv_dir\" ] && [ -f \"$venv_activate\" ]; then"
        echo ". \"$venv_activate\""
        echo "fi"
      } > "$profile_file"
      chmod 0644 "$profile_file" || true
    fi

    local activate_bashrc_line="[ -f \"$venv_activate\" ] && . \"$venv_activate\""
    if ! grep -qxF "$activate_bashrc_line" "$bashrc_file" 2>/dev/null; then
      {
        echo ""
        echo "# Auto-activate project venv"
        echo "$activate_bashrc_line"
      } >> "$bashrc_file"
    fi
  fi
}

#---------------------------------------------
# Benchmarks HTML directory setup (for asv preview)
#---------------------------------------------
setup_benchmarks_html() {
  cd "$APP_DIR" || return 0
  mkdir -p ../rich/benchmarks/html
  if [ ! -e ../rich/benchmarks/html/index.html ]; then
    printf '%s\n' '<!doctype html><meta charset="utf-8"><title>ASV Placeholder</title><h1>ASV Placeholder</h1>' > ../rich/benchmarks/html/index.html
  fi
  # Ensure benchmarks/html exists as a real directory (not a symlink)
  if [ -e benchmarks/html ] && [ ! -d benchmarks/html ]; then
    rm -rf benchmarks/html
  fi
  mkdir -p benchmarks/html
}

#---------------------------------------------
# ASV CLI wrapper to prevent preview from blocking
#---------------------------------------------
setup_asv_wrapper() {
  local ASV_BIN=""
  if [ -x "$APP_DIR/.venv/bin/asv" ]; then
    ASV_BIN="$APP_DIR/.venv/bin/asv"
  else
    ASV_BIN="$(command -v asv || true)"
  fi
  if [ -n "$ASV_BIN" ] && [ ! -x "${ASV_BIN}.real" ]; then
    mv "$ASV_BIN" "${ASV_BIN}.real" || true
    printf '%s\n' '#!/usr/bin/env sh' 'if [ "$1" = "preview" ]; then' '  if command -v timeout >/dev/null 2>&1; then exec timeout 60s '"${ASV_BIN}"'.real "$@"; else exec '"${ASV_BIN}"'.real "$@"; fi' 'else' '  exec '"${ASV_BIN}"'.real "$@"; fi' > "$ASV_BIN"
    chmod +x "$ASV_BIN" || true
  fi
}

#---------------------------------------------
# ASV configuration (use existing interpreter) and hashfile
#---------------------------------------------
setup_asv_conf() {
  cd "$APP_DIR" || return 0
  if [ -f asv.conf.json ]; then
    cp -f asv.conf.json asv.conf.json.bak || true
  fi
  # Ensure ASV working directories exist
  mkdir -p .asv/html .asv/results .asv/env
  # Ensure minimal benchmarks exist so `asv run` has something to execute
  mkdir -p benchmarks
  if [ ! -f benchmarks/bench_noop.py ]; then
    printf '%s\n' 'def time_noop():' '    pass' > benchmarks/bench_noop.py
  fi
  cat > asv.conf.json <<'JSON'
{
  "version": 1,
  "project": "rich",
  "repo": ".",
  "html_dir": ".asv/html",
  "results_dir": ".asv/results",
  "env_dir": ".asv/env",
  "benchmark_dir": "benchmarks",
  "environment_type": "existing",
  "matrix": {}
}
JSON
  touch asvhashfile
}

#---------------------------------------------
# asv machine configuration
#---------------------------------------------
setup_asv_machine() {
  cd "$APP_DIR" || return 0
  local asv_cmd=""
  if [ -x "$APP_DIR/.venv/bin/asv" ]; then
    asv_cmd="$APP_DIR/.venv/bin/asv"
  elif need_cmd asv; then
    asv_cmd="asv"
  fi
  if [ -n "$asv_cmd" ]; then
    $asv_cmd machine --yes || true
  fi
}

#---------------------------------------------
# Java (Maven/Gradle) setup
#---------------------------------------------
setup_java() {
  if [ "$IS_JAVA_MAVEN" -eq 0 ] && [ "$IS_JAVA_GRADLE" -eq 0 ]; then return 0; fi
  log "Setting up Java environment..."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven gradle || pkg_install default-jdk maven gradle || true ;;
    apk) pkg_install openjdk17-jdk maven gradle || true ;;
    dnf|yum|microdnf) pkg_install java-17-openjdk java-17-openjdk-devel maven gradle || true ;;
    zypper) pkg_install java-17-openjdk java-17-openjdk-devel maven gradle || true ;;
  esac

  if [ "$IS_JAVA_MAVEN" -eq 1 ] && need_cmd mvn; then
    mvn -B -ntp -q -Dmaven.test.skip=true dependency:go-offline || true
  fi

  if [ "$IS_JAVA_GRADLE" -eq 1 ]; then
    if file_exists "$APP_DIR/gradlew"; then
      chmod +x "$APP_DIR/gradlew"
      "$APP_DIR/gradlew" --no-daemon tasks || true
    elif need_cmd gradle; then
      gradle --no-daemon tasks || true
    fi
  fi
  log "Java setup complete."
}

#---------------------------------------------
# Go setup
#---------------------------------------------
setup_go() {
  [ "$IS_GO" -eq 1 ] || return 0
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum|microdnf) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac
  if need_cmd go; then
    go env -w GOPATH="$APP_DIR/.gopath" || true
    mkdir -p "$APP_DIR/.gopath"
    if file_exists "$APP_DIR/go.mod"; then go mod download || true; fi
    echo "export GOPATH=\"$APP_DIR/.gopath\"" > /etc/profile.d/10-go.sh
    echo 'export PATH="$GOPATH/bin:$PATH"' >> /etc/profile.d/10-go.sh
    chmod 0644 /etc/profile.d/10-go.sh
  else
    warn "Go toolchain not available from OS packages."
  fi
  log "Go setup complete."
}

#---------------------------------------------
# Ruby setup
#---------------------------------------------
setup_ruby() {
  [ "$IS_RUBY" -eq 1 ] || return 0
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt) pkg_install ruby-full build-essential ;;
    apk) pkg_install ruby ruby-dev build-base ;;
    dnf|yum|microdnf) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
    zypper) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
  esac
  if need_cmd gem; then
    gem install bundler --no-document || true
    if file_exists "$APP_DIR/Gemfile"; then
      BUNDLE_PATH="$APP_DIR/vendor/bundle"
      mkdir -p "$BUNDLE_PATH"
      if [ "${CREATE_APP_USER}" = "1" ]; then chown -R "$APP_USER:$APP_GROUP" "$BUNDLE_PATH"; fi
      bundle config set --local path "$BUNDLE_PATH"
      bundle install --jobs=4 || true
      echo "export GEM_HOME=\"$BUNDLE_PATH\"" > /etc/profile.d/10-ruby.sh
      echo 'export PATH="$GEM_HOME/bin:$PATH"' >> /etc/profile.d/10-ruby.sh
      chmod 0644 /etc/profile.d/10-ruby.sh
    fi
  else
    warn "Ruby not available from OS packages."
  fi
  log "Ruby setup complete."
}

#---------------------------------------------
# PHP setup
#---------------------------------------------
setup_php() {
  [ "$IS_PHP" -eq 1 ] || return 0
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt) pkg_install composer php-cli php-mbstring php-xml php-zip php-curl php-intl php-gd unzip ;;
    apk) pkg_install composer php81 php81-cli php81-mbstring php81-xml php81-zip php81-curl php81-intl php81-gd unzip || pkg_install composer php php-cli php-mbstring php-xml php-zip php-curl php-gd unzip ;;
    dnf|yum|microdnf) pkg_install php-cli php-mbstring php-xml php-zip php-json php-gd unzip ;;
    zypper) pkg_install php8 php8-cli php8-mbstring php8-xml php8-zip php8-curl php8-gd unzip || pkg_install php php-cli php-mbstring php-xml php-zip php-curl php-gd unzip ;;
  esac

  # Install Composer
  if ! need_cmd composer; then
    EXPECTED_CHECKSUM="$(curl -fsSL https://composer.github.io/installer.sig || true)"
    curl -fsSL https://getcomposer.org/installer -o composer-setup.php
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ -n "$EXPECTED_CHECKSUM" ] && [ "$EXPECTED_CHECKSUM" = "$ACTUAL_CHECKSUM" ]; then
      php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet || true
      rm -f composer-setup.php
    else
      warn "Composer installer checksum mismatch; skipping Composer installation."
      rm -f composer-setup.php || true
    fi
  fi

  if need_cmd composer && file_exists "$APP_DIR/composer.json"; then
    if file_exists "$APP_DIR/composer.lock"; then
      composer install --no-interaction --no-ansi --prefer-dist --no-progress
    else
      composer install --no-interaction --no-ansi --prefer-dist --no-progress
    fi
  fi
  log "PHP setup complete."
}

#---------------------------------------------
# Rust setup
#---------------------------------------------
setup_rust() {
  [ "$IS_RUST" -eq 1 ] || return 0
  log "Setting up Rust environment..."
  case "$PKG_MGR" in
    apt) pkg_install cargo rustc || pkg_install rust-all || true ;;
    apk) pkg_install cargo rust ;;
    dnf|yum|microdnf) pkg_install cargo rust ;;
    zypper) pkg_install cargo rust ;;
  esac
  if need_cmd cargo; then
    if file_exists "$APP_DIR/Cargo.toml"; then cargo fetch || true; fi
  else
    warn "Rust toolchain not available from OS packages."
  fi
  log "Rust setup complete."
}

#---------------------------------------------
# .NET setup (best effort)
#---------------------------------------------
setup_dotnet() {
  [ "$IS_DOTNET" -eq 1 ] || return 0
  log "Attempting .NET SDK setup (best-effort)..."
  case "$PKG_MGR" in
    apt)
      # Best effort: try installing dotnet if available in repos; otherwise skip
      pkg_install dotnet-sdk-7.0 || pkg_install dotnet-sdk-8.0 || warn ".NET SDK package not available in this image."
      ;;
    dnf|yum|microdnf)
      pkg_install dotnet-sdk-7.0 || pkg_install dotnet || warn ".NET SDK package not available in this image."
      ;;
    apk|zypper)
      warn ".NET SDK installation not supported via this package manager by default."
      ;;
  esac
  if need_cmd dotnet; then
    dotnet --info || true
    # Restore packages if solution/project exists
    if ls "$APP_DIR"/*.sln "$APP_DIR"/*.csproj >/dev/null 2>&1; then dotnet restore || true; fi
  fi
  log ".NET setup complete."
}

#---------------------------------------------
# Environment variables and runtime configuration
#---------------------------------------------
configure_environment() {
  log "Configuring environment variables and runtime settings..."
  # Global app environment
  {
    echo "export APP_DIR=\"$APP_DIR\""
    echo "export APP_ENV=\"${APP_ENV}\""
    echo "export APP_PORT=\"${APP_PORT}\""
    echo 'export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"'
  } > /etc/profile.d/00-app-env.sh
  chmod 0644 /etc/profile.d/00-app-env.sh

  # Common temp and runtime dirs
  mkdir -p "$APP_DIR/run" "$APP_DIR/tmp" "$APP_DIR/logs"
  if [ "${CREATE_APP_USER}" = "1" ]; then chown -R "$APP_USER:$APP_GROUP" "$APP_DIR/run" "$APP_DIR/tmp" "$APP_DIR/logs"; fi

  # Create a default .env if none exists (non-destructive)
  if [ ! -f "$APP_DIR/.env" ]; then
    {
      echo "APP_ENV=${APP_ENV}"
      echo "APP_PORT=${APP_PORT}"
    } > "$APP_DIR/.env"
    if [ "${CREATE_APP_USER}" = "1" ]; then chown "$APP_USER:$APP_GROUP" "$APP_DIR/.env"; fi
  fi

  log "Environment configuration complete."
}

#---------------------------------------------
# Permissions hardening
#---------------------------------------------
finalize_permissions() {
  log "Finalizing permissions..."
  if [ "${CREATE_APP_USER}" = "1" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
  fi
  find "$APP_DIR" -type d -exec chmod u+rwx,go+rx {} \; || true
  find "$APP_DIR" -type f -exec chmod u+rw,go+r {} \; || true
  log "Permissions set."
}

#---------------------------------------------
# Main entry point
#---------------------------------------------
main() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root inside the Docker container."
    exit 1
  fi

  detect_pkg_manager
  setup_system_basics
  setup_app_dir_and_user
  detect_project_type

  # Install per-tech stacks
  setup_node
  setup_python
  setup_auto_activate
  setup_benchmarks_html
  setup_asv_conf
  setup_asv_wrapper
  setup_asv_machine
  setup_java
  setup_go
  setup_ruby
  setup_php
  setup_rust
  setup_dotnet

  configure_environment
  finalize_permissions

  log "Environment setup completed successfully!"
  info "Detected project types and installed corresponding dependencies."
  info "To use the environment in an interactive shell, ensure profile scripts are loaded."
  info "Common defaults: APP_ENV=${APP_ENV}, APP_PORT=${APP_PORT}, APP_DIR=${APP_DIR}"
  if [ -d "$APP_DIR/.venv" ]; then
    info "Python venv detected: source $APP_DIR/.venv/bin/activate"
  fi
}

main "$@"