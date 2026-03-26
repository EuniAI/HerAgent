#!/usr/bin/env bash
# Project Environment Setup Script
# This script detects common project types and sets up the environment for running inside Docker containers.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail

# Safer IFS
IFS=$'\n\t'

# Colors for output (disable if not a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
info() { echo -e "${BLUE}[*] $*${NC}"; }

# Trap errors
on_err() {
  local exit_code=$?
  local cmd="${BASH_COMMAND:-unknown}"
  err "An error occurred (exit code $exit_code) while executing: $cmd"
  exit $exit_code
}
trap on_err ERR

# Global defaults
: "${PROJECT_ROOT:="$(pwd)"}"
: "${APP_USER:=appuser}"
: "${APP_GROUP:=appuser}"
: "${APP_UID:=10001}"
: "${APP_GID:=10001}"
: "${APP_ENV:=production}"
: "${NO_CREATE_USER:=false}"   # set to true to skip creating a non-root user
: "${ENABLE_COLOR:=true}"

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
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  else
    PKG_MGR=""
  fi
}

# Package install wrapper
pkg_update_once() {
  case "$PKG_MGR" in
    apt)
      # Prevent interactive prompts
      export DEBIAN_FRONTEND=noninteractive
      if [ ! -f /var/lib/apt/lists/lock ] || true; then
        log "Updating apt package lists..."
        apt-get update -y
      fi
      ;;
    apk)
      log "Updating apk package lists..."
      apk update || true
      ;;
    dnf)
      log "Updating dnf package lists..."
      dnf makecache -y || true
      ;;
    yum)
      log "Updating yum package lists..."
      yum makecache -y || true
      ;;
    zypper)
      log "Refreshing zypper repositories..."
      zypper refresh -y || true
      ;;
    *)
      warn "No supported package manager detected. Some system packages may not be installed."
      ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      zypper install -y --no-recommends "${pkgs[@]}"
      ;;
    *)
      warn "Cannot install packages (${pkgs[*]}): unsupported package manager."
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|yum)
      rm -rf /var/cache/dnf || true
      ;;
    zypper)
      rm -rf /var/cache/zypp || true
      ;;
  esac
}

ensure_core_tools() {
  detect_pkg_mgr
  if [ -z "$PKG_MGR" ]; then
    warn "No package manager detected. Skipping system dependencies installation."
    return
  fi

  pkg_update_once

  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git gnupg unzip xz-utils jq build-essential pkg-config make gcc g++ file
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git gnupg unzip xz jq build-base pkgconfig file
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gnupg2 unzip xz jq make gcc gcc-c++ file
      ;;
    zypper)
      pkg_install ca-certificates curl git gpg2 unzip xz jq make gcc gcc-c++ file
      ;;
  esac
}

# Directory and permission setup
setup_project_dir() {
  log "Setting up project directory at: $PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT"
  cd "$PROJECT_ROOT"

  if [ "${NO_CREATE_USER,,}" != "true" ]; then
    # Create group if not exists
    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
      info "Creating group $APP_GROUP (GID=$APP_GID)"
      if command -v addgroup >/dev/null 2>&1; then
        addgroup -g "$APP_GID" -S "$APP_GROUP" || addgroup -g "$APP_GID" "$APP_GROUP" || true
      else
        groupadd -g "$APP_GID" "$APP_GROUP" || true
      fi
    fi
    # Create user if not exists
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      info "Creating user $APP_USER (UID=$APP_UID)"
      if command -v adduser >/dev/null 2>&1 && command -v addgroup >/dev/null 2>&1; then
        adduser -S -D -H -h "$PROJECT_ROOT" -G "$APP_GROUP" -u "$APP_UID" "$APP_USER" || true
      else
        useradd -M -N -r -s /usr/sbin/nologin -d "$PROJECT_ROOT" -g "$APP_GROUP" -u "$APP_UID" "$APP_USER" || true
      fi
    fi
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT" || true
    chmod -R u+rwX,go-rwx "$PROJECT_ROOT" || true
  else
    warn "Skipping user creation as NO_CREATE_USER=$NO_CREATE_USER"
  fi
}

# Helpers
has_file() {
  for f in "$@"; do
    if [ -f "$f" ]; then return 0; fi
  done
  return 1
}
has_dir() {
  for d in "$@"; do
    if [ -d "$d" ]; then return 0; fi
  done
  return 1
}

# Python setup
setup_python() {
  log "Detected Python project. Installing Python runtime and dependencies..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev build-essential pkg-config libpq-dev libjpeg-dev zlib1g-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev libffi-dev openssl-dev build-base pkgconfig postgresql-dev jpeg-dev zlib-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel libffi-devel openssl-devel gcc gcc-c++ make pkgconfig libpq-devel libjpeg-turbo-devel zlib-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel libffi-devel libopenssl-devel gcc gcc-c++ make pkg-config libpq-devel libjpeg8-devel zlib-devel
      ;;
    *)
      warn "Cannot ensure Python system dependencies. Proceeding if Python is available..."
      ;;
  esac

  # Ensure python3 is available
  if ! command -v python3 >/dev/null 2>&1; then
    err "Python3 not found and could not be installed."
    exit 1
  fi

  # Prefer in-project venv
  VENV_DIR="$PROJECT_ROOT/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating Python virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  else
    info "Virtual environment already exists at $VENV_DIR"
  fi

  # Activate venv in subshell for installations
  set +u
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  set -u

  python -m pip install --upgrade pip setuptools wheel

  if has_file "pyproject.toml"; then
    # Detect Poetry
    if grep -qiE '^\s*\[tool\.poetry\]' pyproject.toml; then
      log "Installing Poetry and project dependencies..."
      python -m pip install --upgrade poetry
      poetry config virtualenvs.in-project true
      if [ ! -d "$PROJECT_ROOT/.venv" ]; then
        mkdir -p "$PROJECT_ROOT/.venv"
      fi
      poetry install --no-interaction --no-ansi
    else
      # PEP 517/518 project without poetry - try pip install
      log "Installing Python dependencies from pyproject.toml using pip (PEP 517/518)"
      python -m pip install .
    fi
  elif has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    python -m pip install -r requirements.txt
  elif has_file "Pipfile" "Pipfile.lock"; then
    log "Pipenv project detected. Installing pipenv and dependencies..."
    python -m pip install --upgrade pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
  else
    warn "No Python dependency file detected. Skipping dependency installation."
  fi

  # Default Python env vars
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=off
  export PATH="$VENV_DIR/bin:$PATH"

  # Deactivate to avoid leaking environment to rest of script
  deactivate || true

  # Permissions
  if [ "${NO_CREATE_USER,,}" != "true" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$VENV_DIR" || true
  fi

  # Write runtime hint
  mkdir -p "$PROJECT_ROOT/.env"
  {
    echo "PYTHONUNBUFFERED=1"
    echo "APP_ENV=${APP_ENV}"
  } > "$PROJECT_ROOT/.env/.python.env" 2>/dev/null || true

  log "Python environment setup complete."
}

# Node.js setup
install_nvm_and_node() {
  local node_version="$1"
  if [ ! -d "/opt/nvm" ]; then
    log "Installing NVM to /opt/nvm"
    mkdir -p /opt/nvm
    export NVM_DIR="/opt/nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  else
    export NVM_DIR="/opt/nvm"
  fi
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
  if [ -n "$node_version" ]; then
    nvm install "$node_version"
    nvm alias default "$node_version"
  else
    nvm install --lts
    nvm alias default 'lts/*'
  fi
  # Persist PATH for subsequent shells
  if [ -d "$NVM_DIR" ]; then
    mkdir -p /etc/profile.d
    echo "export NVM_DIR=$NVM_DIR; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; nvm use default >/dev/null 2>&1 || true" > /etc/profile.d/nvm.sh || true
  fi
}

setup_node() {
  log "Detected Node.js project. Installing Node.js and dependencies..."
  ensure_core_tools

  local desired_node=""
  if has_file ".nvmrc"; then
    desired_node="$(cat .nvmrc | tr -d '[:space:]' || true)"
  elif has_file "package.json"; then
    if command -v jq >/dev/null 2>&1; then
      desired_node="$(jq -r '.engines.node // empty' package.json || true)"
      # Normalize semver like ">=14" or "^18" to an installable version; fallback to LTS if ambiguous
      if echo "$desired_node" | grep -qE "[><=^~]"; then
        desired_node=""
      fi
    fi
  fi

  install_nvm_and_node "$desired_node"
  # shellcheck disable=SC1090
  . /etc/profile.d/nvm.sh || true
  # Use default node
  if command -v nvm >/dev/null 2>&1; then nvm use default >/dev/null 2>&1 || true; fi

  # Enable corepack for yarn/pnpm
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Install dependencies
  if has_file "pnpm-lock.yaml"; then
    log "pnpm project detected. Installing dependencies..."
    if ! command -v pnpm >/dev/null 2>&1; then corepack prepare pnpm@latest --activate || npm i -g pnpm; fi
    pnpm install --frozen-lockfile || pnpm install
  elif has_file "yarn.lock"; then
    log "Yarn project detected. Installing dependencies..."
    if ! command -v yarn >/dev/null 2>&1; then corepack prepare yarn@stable --activate || npm i -g yarn; fi
    yarn install --frozen-lockfile || yarn install
  elif has_file "package-lock.json"; then
    log "NPM project detected. Installing dependencies with npm ci..."
    npm ci || npm install
  elif has_file "package.json"; then
    log "Installing dependencies with npm..."
    npm install
  else
    warn "No package.json found; skipping Node dependency installation."
  fi

  # Create .env hint
  mkdir -p "$PROJECT_ROOT/.env"
  {
    echo "NODE_ENV=${APP_ENV}"
    echo "PORT=${PORT:-3000}"
  } > "$PROJECT_ROOT/.env/.node.env" 2>/dev/null || true

  # Permissions
  if [ "${NO_CREATE_USER,,}" != "true" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT/node_modules" 2>/dev/null || true
    chown -R "$APP_USER:$APP_GROUP" "/opt/nvm" 2>/dev/null || true
  fi

  log "Node.js environment setup complete."
}

# Ruby setup
setup_ruby() {
  log "Detected Ruby project. Installing Ruby and bundler..."
  case "$PKG_MGR" in
    apt) pkg_install ruby-full build-essential ruby-dev libffi-dev libssl-dev zlib1g-dev; ;;
    apk) pkg_install ruby ruby-dev build-base libffi-dev openssl-dev zlib-dev; ;;
    dnf|yum) pkg_install ruby ruby-devel gcc gcc-c++ make libffi-devel openssl-devel zlib-devel; ;;
    zypper) pkg_install ruby ruby-devel gcc gcc-c++ make libffi-devel libopenssl-devel zlib-devel; ;;
    *) warn "Cannot ensure Ruby dependencies. Proceeding if Ruby is available...";;
  esac
  if ! command -v ruby >/dev/null 2>&1; then
    err "Ruby not available."
    exit 1
  fi
  gem install bundler --no-document || true
  # Install gems to vendor/bundle within project to avoid global gems
  BUNDLE_PATH="$PROJECT_ROOT/vendor/bundle"
  bundle config set --local path "$BUNDLE_PATH" || true
  if has_file "Gemfile.lock"; then
    bundle install --without development test || bundle install
  elif has_file "Gemfile"; then
    bundle install
  else
    warn "No Gemfile found; skipping bundle install."
  fi
  if [ "${NO_CREATE_USER,,}" != "true" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$BUNDLE_PATH" 2>/dev/null || true
  fi
  log "Ruby environment setup complete."
}

# PHP setup
setup_php() {
  log "Detected PHP project. Installing PHP and Composer..."
  case "$PKG_MGR" in
    apt) pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip git; ;;
    apk) pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip unzip; ;;
    dnf|yum) pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip git; ;;
    zypper) pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip git; ;;
    *) warn "Cannot ensure PHP dependencies. Proceeding if PHP is available...";;
  esac
  if ! command -v php >/dev/null 2>&1; then
    err "PHP not available."
    exit 1
  fi
  # Install Composer if not present
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi
  if has_file "composer.lock"; then
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress
  elif has_file "composer.json"; then
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction
  else
    warn "No composer.json found; skipping composer install."
  fi
  mkdir -p "$PROJECT_ROOT/.env"
  {
    echo "APP_ENV=${APP_ENV}"
    echo "APP_DEBUG=0"
  } > "$PROJECT_ROOT/.env/.php.env" 2>/dev/null || true
  if [ "${NO_CREATE_USER,,}" != "true" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT/vendor" 2>/dev/null || true
  fi
  log "PHP environment setup complete."
}

# Java setup
setup_java() {
  log "Detected Java project. Installing JDK and resolving dependencies..."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven gradle || pkg_install openjdk-17-jdk; ;;
    apk) pkg_install openjdk17 maven gradle || pkg_install openjdk17; ;;
    dnf|yum) pkg_install java-17-openjdk java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk; ;;
    zypper) pkg_install java-17-openjdk java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk; ;;
  esac
  export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
  export PATH="$JAVA_HOME/bin:$PATH"

  if has_file "mvnw"; then
    chmod +x mvnw
    ./mvnw -q -DskipTests dependency:resolve || true
  elif has_file "pom.xml"; then
    mvn -q -DskipTests dependency:resolve || true
  fi

  if has_file "gradlew"; then
    chmod +x gradlew
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
  elif has_file "build.gradle" "build.gradle.kts"; then
    gradle --no-daemon tasks >/dev/null 2>&1 || true
  fi

  mkdir -p "$PROJECT_ROOT/.env"
  {
    echo "JAVA_HOME=${JAVA_HOME:-}"
    echo "APP_ENV=${APP_ENV}"
    echo "PORT=${PORT:-8080}"
  } > "$PROJECT_ROOT/.env/.java.env" 2>/dev/null || true

  if [ "${NO_CREATE_USER,,}" != "true" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT/.gradle" "$PROJECT_ROOT/.m2" 2>/dev/null || true
  fi

  log "Java environment setup complete."
}

# Go setup
setup_go() {
  log "Detected Go project. Installing Go and downloading modules..."
  case "$PKG_MGR" in
    apt) pkg_install golang git; ;;
    apk) pkg_install go git; ;;
    dnf|yum) pkg_install golang git; ;;
    zypper) pkg_install go git; ;;
  esac
  if ! command -v go >/dev/null 2>&1; then
    err "Go not available."
    exit 1
  fi
  go env -w GOPATH="${GOPATH:-/go}" || true
  go mod download || true
  mkdir -p "$PROJECT_ROOT/.env"
  {
    echo "GOFLAGS="
    echo "PORT=${PORT:-8080}"
  } > "$PROJECT_ROOT/.env/.go.env" 2>/dev/null || true
  if [ "${NO_CREATE_USER,,}" != "true" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$GOPATH" 2>/dev/null || true
  fi
  log "Go environment setup complete."
}

# Rust setup
setup_rust() {
  log "Detected Rust project. Installing Rust toolchain..."
  case "$PKG_MGR" in
    apt) pkg_install cargo rustc; ;;
    apk) pkg_install cargo rust; ;;
    dnf|yum) pkg_install cargo rust; ;;
    zypper) pkg_install cargo rust; ;;
  esac
  if ! command -v cargo >/dev/null 2>&1; then
    # Fallback rustup (requires curl)
    curl https://sh.rustup.rs -sSf | sh -s -- -y
    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
  fi
  cargo fetch || true
  mkdir -p "$PROJECT_ROOT/.env"
  {
    echo "RUST_LOG=info"
  } > "$PROJECT_ROOT/.env/.rust.env" 2>/dev/null || true
  if [ "${NO_CREATE_USER,,}" != "true" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$HOME/.cargo" "$HOME/.rustup" 2>/dev/null || true
  fi
  log "Rust environment setup complete."
}

# .NET setup
setup_dotnet() {
  log "Detected .NET project. Installing .NET SDK..."
  case "$PKG_MGR" in
    apt)
      # Try installing dotnet 8 via Microsoft package feed
      if ! command -v dotnet >/dev/null 2>&1; then
        curl -fsSL https://packages.microsoft.com/config/debian/$(. /etc/os-release; echo "$VERSION_CODENAME")/packages-microsoft-prod.deb -o packages-microsoft-prod.deb || true
        dpkg -i packages-microsoft-prod.deb || true
        rm -f packages-microsoft-prod.deb || true
        apt-get update -y || true
        apt-get install -y dotnet-sdk-8.0 || apt-get install -y dotnet-sdk-7.0 || true
      fi
      ;;
    dnf|yum)
      if ! command -v dotnet >/dev/null 2>&1; then
        rpm -Uvh https://packages.microsoft.com/config/rhel/7/packages-microsoft-prod.rpm || true
        dnf install -y dotnet-sdk-8.0 || yum install -y dotnet-sdk-8.0 || true
      fi
      ;;
    apk|zypper)
      warn ".NET installation not supported on this distro by this script. Please use a .NET base image."
      ;;
  esac

  if ! command -v dotnet >/dev/null 2>&1; then
    warn "dotnet CLI not available; skipping restore."
    return
  fi

  # Restore dependencies
  if ls *.sln >/dev/null 2>&1; then
    dotnet restore || true
  else
    # Restore for each csproj
    for csproj in $(find "$PROJECT_ROOT" -maxdepth 2 -name "*.csproj" -type f 2>/dev/null); do
      dotnet restore "$csproj" || true
    done
  fi

  mkdir -p "$PROJECT_ROOT/.env"
  {
    echo "ASPNETCORE_URLS=http://0.0.0.0:${PORT:-8080}"
    echo "DOTNET_ENVIRONMENT=${APP_ENV}"
  } > "$PROJECT_ROOT/.env/.dotnet.env" 2>/dev/null || true

  log ".NET environment setup complete."
}

# Detect project types
detect_and_setup() {
  local detected=0

  if has_file "requirements.txt" "pyproject.toml" "setup.py" "Pipfile"; then
    setup_python
    detected=$((detected+1))
  fi

  if has_file "package.json"; then
    setup_node
    detected=$((detected+1))
  fi

  if has_file "Gemfile"; then
    setup_ruby
    detected=$((detected+1))
  fi

  if has_file "composer.json"; then
    setup_php
    detected=$((detected+1))
  fi

  if has_file "pom.xml" "build.gradle" "build.gradle.kts" "mvnw" "gradlew"; then
    setup_java
    detected=$((detected+1))
  fi

  if has_file "go.mod"; then
    setup_go
    Hudson=$((detected+1))
    detected=$Hudson
  fi

  if has_file "Cargo.toml"; then
    setup_rust
    detected=$((detected+1))
  fi

  if ls *.csproj >/dev/null 2>&1 || ls *.sln >/dev/null 2>&1; then
    setup_dotnet
    detected=$((detected+1))
  fi

  if [ "$detected" -eq 0 ]; then
    warn "No recognizable project files detected. Installed core tools only."
  fi
}

# General environment setup
setup_env_files() {
  mkdir -p "$PROJECT_ROOT/.env"

  # Generic env file
  ENV_FILE="$PROJECT_ROOT/.env/.project.env"
  {
    echo "APP_ENV=${APP_ENV}"
    echo "TZ=${TZ:-UTC}"
    echo "LANG=${LANG:-C.UTF-8}"
    echo "LC_ALL=${LC_ALL:-C.UTF-8}"
  } > "$ENV_FILE" 2>/dev/null || true

  # Profile script to load env files in interactive shells
  mkdir -p /etc/profile.d
  cat > /etc/profile.d/project_env.sh <<'EOF' || true
# Load project environment files if present
if [ -d "$PWD/.env" ]; then
  for f in "$PWD"/.env/*.env; do
    [ -f "$f" ] && export $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f" | sed 's/#.*//') >/dev/null 2>&1 || true
  done
fi
EOF
}

# Auto-activate Python virtual environment for interactive shells
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local venv_path="${VENV_DIR:-$PROJECT_ROOT/.venv}"
  local activate_line="source \"$venv_path/bin/activate\""
  if [ -f "$venv_path/bin/activate" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

# Main
main() {
  log "Starting environment setup in Docker-friendly mode..."
  ensure_core_tools
  setup_project_dir
  detect_and_setup
  # Create filesystem shim for mermaid package.json to satisfy tools resolving from repo root with incorrect cwd
  if [ -f "/app/packages/mermaid/package.json" ]; then
    mkdir -p /mermaid
    ln -sfn /app/packages/mermaid/package.json /mermaid/package.json
  fi
  setup_env_files
  # Ensure future shells auto-activate Python venv
  setup_auto_activate
  pkg_clean

  log "Environment setup completed successfully."
  info "Hints:
  - If using Python: source .venv/bin/activate && run your app (default PORT 5000 if Flask, 8000 for Django).
  - If using Node.js: npm start or yarn start (default PORT 3000).
  - If using PHP: composer run or php -S 0.0.0.0:8000 -t public.
  - If using Java: ./mvnw spring-boot:run or ./gradlew bootRun (default PORT 8080).
  - If using Go: go run ./... (default PORT 8080).
  - If using Rust: cargo run (default PORT 8080).
  - If using .NET: dotnet run (default PORT 8080).

Re-run this script safely at any time for idempotent setup.
"
}

main "$@"