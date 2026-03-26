#!/usr/bin/env bash
# Environment setup script for containerized projects
# This script detects the project type and installs required runtimes, system packages,
# and dependencies. It is idempotent and safe to run multiple times.
#
# Supported stacks (auto-detected):
# - Node.js (package.json)
# - Python (requirements.txt or pyproject.toml)
# - Go (go.mod)
# - Java (Maven/Gradle: pom.xml/build.gradle*)
# - PHP (composer.json)
# - Ruby (Gemfile)
#
# Notes:
# - Designed to run as root in Docker containers (no sudo used).
# - Tries to support major Linux distributions (Debian/Ubuntu, Alpine, RHEL-based).
# - Creates a non-root "appuser" (uid/gid configurable via APP_UID/APP_GID).
# - Sets common environment variables in /etc/profile.d/project-env.sh

set -Eeuo pipefail
IFS=$'\n\t'

# -------------------------
# Logging and error handling
# -------------------------
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }
on_error() {
  err "An error occurred at line $1. Aborting."
}
trap 'on_error $LINENO' ERR

# -------------------------
# Preconditions
# -------------------------
if [ "$(id -u)" -ne 0 ]; then
  err "This script must be run as root inside the container."
  exit 1
fi

# -------------------------
# Globals and defaults
# -------------------------
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
PROFILE_D="/etc/profile.d"
ENV_FILE="${PROFILE_D}/project-env.sh"
STATE_DIR="/var/lib/project-setup"
mkdir -p "$STATE_DIR"

# Default ports per stack
DEFAULT_NODE_PORT="${DEFAULT_NODE_PORT:-3000}"
DEFAULT_PY_PORT="${DEFAULT_PY_PORT:-5000}"
DEFAULT_WEB_PORT="${DEFAULT_WEB_PORT:-8080}"

# -------------------------
# Helpers
# -------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_file() { [ -f "$1" ]; }
ensure_dir() {
  local d="$1" owner="${2:-root}" group="${3:-root}" mode="${4:-0755}"
  mkdir -p "$d"
  chmod "$mode" "$d"
  chown -R "$owner":"$group" "$d"
}
append_env_once() {
  # idempotently append line to env file if not present
  local line="$1"
  grep -Fqx "$line" "$ENV_FILE" 2>/dev/null || echo "$line" >> "$ENV_FILE"
}

# -------------------------
# Detect OS / Package manager
# -------------------------
PKG_MGR=""
OS_ID=""
OS_LIKE=""
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release || true
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
fi

if has_cmd apt-get; then
  PKG_MGR="apt"
elif has_cmd apk; then
  PKG_MGR="apk"
elif has_cmd dnf; then
  PKG_MGR="dnf"
elif has_cmd yum; then
  PKG_MGR="yum"
elif has_cmd microdnf; then
  PKG_MGR="microdnf"
elif has_cmd zypper; then
  PKG_MGR="zypper"
else
  err "No supported package manager found (apt/apk/dnf/yum/microdnf/zypper)."
  exit 1
fi

pkg_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      # Update at most every 6 hours to keep idempotent but reasonably fresh
      local stamp="$STATE_DIR/apt-update.stamp"
      if [ ! -f "$stamp" ] || [ $(( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) )) -gt 21600 ]; then
        log "Running apt-get update..."
        apt-get update -y
        date +%s > "$stamp"
      else
        log "Skipping apt-get update (recently updated)."
      fi
      ;;
    apk)
      log "Ensuring Alpine package index is up to date..."
      apk update || true
      ;;
    dnf)
      log "Running dnf makecache..."
      dnf -y makecache
      ;;
    yum)
      log "Running yum makecache..."
      yum -y makecache
      ;;
    microdnf)
      log "Running microdnf makecache..."
      microdnf -y makecache
      ;;
    zypper)
      log "Refreshing zypper repositories..."
      zypper --non-interactive refresh
      ;;
  esac
}

pkg_install() {
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
    microdnf)
      microdnf install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
      ;;
    dnf|yum|microdnf)
      rm -rf /var/cache/dnf/* /var/cache/yum/* /tmp/* /var/tmp/*
      ;;
    zypper)
      rm -rf /var/cache/zypp/* /tmp/* /var/tmp/*
      ;;
  esac
}

# -------------------------
# Base system tools
# -------------------------
install_base_tools() {
  log "Installing base system tools..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git bash openssl unzip tar xz-utils gzip bzip2 \
                  findutils coreutils procps netcat-traditional jq
      # build-essential is often needed for native builds
      pkg_install build-essential
      ;;
    apk)
      pkg_install ca-certificates curl git bash openssl unzip tar xz gzip bzip2 \
                  findutils coreutils procps-ng netcat-openbsd jq
      pkg_install build-base
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl git bash openssl unzip tar xz gzip bzip2 \
                  findutils coreutils procps-ng nmap-ncat jq
      pkg_install gcc gcc-c++ make
      ;;
    zypper)
      pkg_install ca-certificates curl git bash openssl unzip tar xz gzip bzip2 \
                  findutils coreutils procps netcat-openbsd jq
      pkg_install gcc gcc-c++ make
      ;;
  esac
  update-ca-certificates || true
  pkg_clean
  log "Base tools installed."
}

# -------------------------
# User and directories
# -------------------------
setup_users_dirs() {
  log "Setting up application directories and user..."
  # Create group if not exists
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    groupadd -g "$APP_GID" "$APP_GROUP" || true
  fi
  # Create user if not exists
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd -m -u "$APP_UID" -g "$APP_GROUP" -s /bin/bash "$APP_USER" || \
    adduser -D -u "$APP_UID" -G "$APP_GROUP" -s /bin/bash "$APP_USER" || true
  fi

  ensure_dir "$APP_DIR" "$APP_USER" "$APP_GROUP" 0755
  ensure_dir "$APP_DIR/logs" "$APP_USER" "$APP_GROUP" 0755
  ensure_dir "$APP_DIR/tmp" "$APP_USER" "$APP_GROUP" 0775
  ensure_dir "$APP_DIR/data" "$APP_USER" "$APP_GROUP" 0775

  # Ensure env file exists
  touch "$ENV_FILE"
  chmod 0644 "$ENV_FILE"

  # Common env defaults
  append_env_once "export APP_DIR=\"$APP_DIR\""
  append_env_once "export PATH=\"/usr/local/bin:/usr/bin:/bin:\$PATH\""
  append_env_once "export NODE_ENV=\${NODE_ENV:-production}"
  append_env_once "export PYTHONUNBUFFERED=1"
  append_env_once "export PIP_DISABLE_PIP_VERSION_CHECK=1"
  append_env_once "export PIP_NO_CACHE_DIR=0"
  append_env_once "export LANG=C.UTF-8"
  append_env_once "export LC_ALL=C.UTF-8"
  append_env_once "export TZ=\${TZ:-UTC}"
  append_env_once "export PATH=\"$APP_DIR/node_modules/.bin:\$PATH\""

  log "User and directories configured."
}

# -------------------------
# Language/Stack installers
# -------------------------
install_python_stack() {
  log "Detected Python project. Installing Python runtime and dependencies..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev libffi-dev libssl-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev musl-dev libffi-dev openssl-dev
      ;;
    dnf|yum|microdnf)
      pkg_install python3 python3-pip python3-devel openssl-devel libffi-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel libffi-devel libopenssl-devel
      ;;
  case_esac=true
  pkg_clean

  # Create a global venv at /opt/venv (idempotent)
  if [ ! -d /opt/venv ]; then
    log "Creating Python virtual environment at /opt/venv..."
    python3 -m venv /opt/venv
  else
    log "Python virtual environment already exists at /opt/venv."
  fi

  # Ensure venv available in environment and for login shells
  append_env_once "export VIRTUAL_ENV=/opt/venv"
  append_env_once "export PATH=\"/opt/venv/bin:\$PATH\""

  # Install Python dependencies
  if has_file "$APP_DIR/requirements.txt"; then
    log "Installing dependencies from requirements.txt..."
    /opt/venv/bin/pip install --upgrade pip wheel setuptools
    /opt/venv/bin/pip install -r "$APP_DIR/requirements.txt"
  elif has_file "$APP_DIR/pyproject.toml"; then
    # Try to use pip with PEP 517 or Poetry if lockfile exists
    if grep -qiE 'tool.poetry' "$APP_DIR/pyproject.toml" && has_file "$APP_DIR/poetry.lock"; then
      log "Detected Poetry project. Installing Poetry and dependencies..."
      /opt/venv/bin/pip install --upgrade pip wheel setuptools poetry
      POETRY_HOME="/opt/poetry"
      mkdir -p "$POETRY_HOME"
      append_env_once "export POETRY_HOME=\"$POETRY_HOME\""
      /opt/venv/bin/poetry config virtualenvs.create false
      (cd "$APP_DIR" && /opt/venv/bin/poetry install --no-root --no-interaction --no-ansi)
    else
      log "Installing build backend dependencies via pip..."
      /opt/venv/bin/pip install --upgrade pip wheel build setuptools
      (cd "$APP_DIR" && /opt/venv/bin/pip install . || true)
      # If above fails due to missing backend, fallback to requirements-dev if present
      if has_file "$APP_DIR/requirements-dev.txt"; then
        /opt/venv/bin/pip install -r "$APP_DIR/requirements-dev.txt" || true
      fi
    fi
  else
    warn "No requirements.txt or pyproject.toml found. Skipping Python package installation."
  fi

  # Framework-specific defaults
  if has_file "$APP_DIR/app.py" || has_file "$APP_DIR/wsgi.py" || grep -Rqi "flask" "$APP_DIR" 2>/dev/null; then
    append_env_once "export FLASK_ENV=\${FLASK_ENV:-production}"
    append_env_once "export FLASK_APP=\${FLASK_APP:-app.py}"
    append_env_once "export PORT=\${PORT:-$DEFAULT_PY_PORT}"
  elif grep -Rqi "django" "$APP_DIR" 2>/dev/null; then
    append_env_once "export DJANGO_SETTINGS_MODULE=\${DJANGO_SETTINGS_MODULE:-project.settings}"
    append_env_once "export PORT=\${PORT:-$DEFAULT_PY_PORT}"
  else
    append_env_once "export PORT=\${PORT:-$DEFAULT_PY_PORT}"
  fi

  log "Python setup completed."
}

install_node_stack() {
  log "Detected Node.js project. Installing Node.js and dependencies..."
  pkg_update
  local installed=false
  # Install Node.js + npm
  case "$PKG_MGR" in
    apt)
      if ! has_cmd node; then
        pkg_install nodejs npm || true
      fi
      ;;
    apk)
      if ! has_cmd node; then
        pkg_install nodejs npm
      fi
      ;;
    dnf|yum|microdnf)
      if ! has_cmd node; then
        # Try installing module stream if available
        if has_cmd dnf; then
          dnf module -y enable nodejs:20 || true
          pkg_install nodejs npm || true
        else
          pkg_install nodejs npm || true
        fi
      fi
      ;;
    zypper)
      if ! has_cmd node; then
        pkg_install nodejs npm || true
      fi
      ;;
  esac

  # If node still not available or too old, install via nvm (binary tarballs)
  local need_nvm=false
  if has_cmd node; then
    NODE_CURR=$(node -v | sed 's/^v//')
    NODE_MAJOR=${NODE_CURR%%.*}
    if [ -n "${NODE_MAJOR}" ] && [ "$NODE_MAJOR" -lt 16 ]; then
      need_nvm=true
    fi
  else
    need_nvm=true
  fi

  if $need_nvm; then
    log "Installing Node.js via nvm (system-wide)..."
    local NVM_DIR="/usr/local/nvm"
    if [ ! -d "$NVM_DIR" ]; then
      mkdir -p "$NVM_DIR"
      git clone --depth=1 https://github.com/nvm-sh/nvm.git "$NVM_DIR"
    else
      (cd "$NVM_DIR" && git fetch --depth=1 origin && git reset --hard origin/HEAD) || true
    fi
    # Create profile script
    cat > /etc/profile.d/nvm.sh <<'EOF'
export NVM_DIR="/usr/local/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
EOF
    # Load nvm in current shell
    # shellcheck disable=SC1091
    . /etc/profile.d/nvm.sh
    local NODE_VERSION="${NODE_VERSION:-20}"
    nvm install --lts || nvm install "$NODE_VERSION"
    nvm alias default "lts/*" || nvm alias default "$NODE_VERSION"
    nvm use default
    append_env_once '. /etc/profile.d/nvm.sh'
    installed=true
  else
    installed=true
  fi

  if ! $installed; then
    err "Failed to install Node.js."
    exit 1
  fi

  # Prefer corepack for yarn/pnpm
  if has_cmd corepack; then
    corepack enable || true
  fi

  # Install dependencies
  if has_file "$APP_DIR/yarn.lock"; then
    log "Detected yarn.lock. Installing dependencies with Yarn..."
    if ! has_cmd yarn; then
      if has_cmd corepack; then
        corepack prepare yarn@stable --activate || true
      else
        npm install -g yarn
      fi
    end_if=true
    fi
    (cd "$APP_DIR" && yarn install --frozen-lockfile || yarn install)
  elif has_file "$APP_DIR/pnpm-lock.yaml"; then
    log "Detected pnpm-lock.yaml. Installing dependencies with pnpm..."
    if ! has_cmd pnpm; then
      if has_cmd corepack; then
        corepack prepare pnpm@latest --activate || true
      else
        npm install -g pnpm
      fi
    fi
    (cd "$APP_DIR" && pnpm install --frozen-lockfile || pnpm install)
  elif has_file "$APP_DIR/package-lock.json"; then
    log "Detected package-lock.json. Installing dependencies with npm ci..."
    (cd "$APP_DIR" && npm ci || npm install)
  elif has_file "$APP_DIR/package.json"; then
    log "Installing dependencies with npm..."
    (cd "$APP_DIR" && npm install)
  else
    warn "No package.json found in $APP_DIR while Node.js selected. Skipping dependency install."
  fi

  append_env_once "export PORT=\${PORT:-$DEFAULT_NODE_PORT}"
  append_env_once "export NODE_ENV=\${NODE_ENV:-production}"
  append_env_once "export PATH=\"$APP_DIR/node_modules/.bin:\$PATH\""

  log "Node.js setup completed."
}

install_go_stack() {
  log "Detected Go project. Installing Go toolchain..."
  pkg_update
  case "$PKG_MGR" in
    apt) pkg_install golang ;; 
    apk) pkg_install go ;;
    dnf|yum|microdnf) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac
  pkg_clean
  (cd "$APP_DIR" && if has_file go.mod; then go mod download; fi) || true
  append_env_once "export GOPATH=\${GOPATH:-/go}"
  append_env_once "export PATH=\"\$GOPATH/bin:\$PATH\""
  append_env_once "export PORT=\${PORT:-$DEFAULT_WEB_PORT}"
  log "Go setup completed."
}

install_java_stack() {
  log "Detected Java project. Installing OpenJDK and build tools..."
  pkg_update
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven gradle || pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17 maven gradle || pkg_install openjdk17 maven ;;
    dnf|yum|microdnf) pkg_install java-17-openjdk java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk maven ;;
    zypper) pkg_install java-17-openjdk java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk maven ;;
  esac
  pkg_clean
  (cd "$APP_DIR" && if has_file pom.xml; then mvn -B -ntp -q -DskipTests dependency:resolve || true; fi) || true
  (cd "$APP_DIR" && if ls "$APP_DIR"/gradlew >/dev/null 2>&1; then chmod +x gradlew && ./gradlew --no-daemon build -x test || true; elif ls "$APP_DIR"/build.gradle* >/dev/null 2>&1; then gradle --no-daemon build -x test || true; fi) || true
  append_env_once "export JAVA_HOME=\$(dirname \$(dirname \$(readlink -f \$(command -v javac))))"
  append_env_once "export PATH=\"\$JAVA_HOME/bin:\$PATH\""
  append_env_once "export PORT=\${PORT:-$DEFAULT_WEB_PORT}"
  log "Java setup completed."
}

install_php_stack() {
  log "Detected PHP project. Installing PHP and Composer..."
  pkg_update
  case "$PKG_MGR" in
    apt) pkg_install php-cli php-fpm php-mbstring php-xml php-curl php-zip php-intl php-bcmath php-gd unzip ;;
    apk) pkg_install php81 php81-fpm php81-mbstring php81-xml php81-curl php81-zip php81-intl php81-bcmath php81-gd ;;
    dnf|yum|microdnf) pkg_install php-cli php-fpm php-mbstring php-xml php-json php-curl php-zip php-intl php-gd ;;
    zypper) pkg_install php8 php8-fpm php8-mbstring php8-xml php8-curl php8-zip php8-intl php8-gd ;;
  esac
  # Install Composer
  if ! has_cmd composer; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
      && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
      && rm -f composer-setup.php
  fi
  pkg_clean
  if has_file "$APP_DIR/composer.json"; then
    (cd "$APP_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress)
  fi
  append_env_once "export PORT=\${PORT:-$DEFAULT_WEB_PORT}"
  log "PHP setup completed."
}

install_ruby_stack() {
  log "Detected Ruby project. Installing Ruby and Bundler..."
  pkg_update
  case "$PKG_MGR" in
    apt) pkg_install ruby-full ruby-dev build-essential ;;
    apk) pkg_install ruby ruby-dev ruby-bundler ;;
    dnf|yum|microdnf) pkg_install ruby ruby-devel rubygems gcc make ;;
    zypper) pkg_install ruby ruby-devel ruby2.5-rubygem-bundler || pkg_install ruby ruby-devel ;;
  esac
  pkg_clean
  if ! has_cmd bundler; then
    gem install bundler --no-document || true
  fi
  if has_file "$APP_DIR/Gemfile"; then
    (cd "$APP_DIR" && bundle config set without 'development test' && bundle install --jobs 4 --retry 3)
  fi
  append_env_once "export PORT=\${PORT:-$DEFAULT_WEB_PORT}"
  log "Ruby setup completed."
}

# -------------------------
# Detection logic
# -------------------------
detect_and_install_stack() {
  local detected="none"

  if has_file "$APP_DIR/package.json"; then
    install_node_stack
    detected="node"
  fi

  if has_file "$APP_DIR/requirements.txt" || has_file "$APP_DIR/pyproject.toml"; then
    install_python_stack
    if [ "$detected" = "none" ]; then detected="python"; else detected="${detected}+python"; fi
  fi

  if has_file "$APP_DIR/go.mod"; then
    install_go_stack
    if [ "$detected" = "none" ]; then detected="go"; else detected="${detected}+go"; fi
  fi

  if has_file "$APP_DIR/pom.xml" || ls "$APP_DIR"/build.gradle* >/dev/null 2>&1; then
    install_java_stack
    if [ "$detected" = "none" ]; then detected="java"; else detected="${detected}+java"; fi
  fi

  if has_file "$APP_DIR/composer.json"; then
    install_php_stack
    if [ "$detected" = "none" ]; then detected="php"; else detected="${detected}+php"; fi
  fi

  if has_file "$APP_DIR/Gemfile"; then
    install_ruby_stack
    if [ "$detected" = "none" ]; then detected="ruby"; else detected="${detected}+ruby"; fi
  fi

  if [ "$detected" = "none" ]; then
    warn "No recognized project files found in $APP_DIR."
    append_env_once "export PORT=\${PORT:-$DEFAULT_WEB_PORT}"
  else
    log "Stacks configured: $detected"
  fi
}

# -------------------------
# Permissions
# -------------------------
finalize_permissions() {
  log "Finalizing permissions..."
  chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR"
  # Ensure profile env file readable by all users
  chmod 0644 "$ENV_FILE"
  log "Permissions set. Primary app directory owner: $APP_USER"
}

# -------------------------
# Summary and instructions
# -------------------------
print_summary() {
  log "Environment setup completed successfully!"
  echo "Summary:"
  echo "- App directory: $APP_DIR"
  echo "- App user/group: $APP_USER/$APP_GROUP (uid: $APP_UID, gid: $APP_GID)"
  echo "- Environment file: $ENV_FILE (auto-loaded for login shells)"
  echo "- Common runtime env: NODE_ENV=production, PYTHONUNBUFFERED=1, PATH includes venv and node_modules/.bin"
  echo
  echo "Usage tips:"
  echo "- To load environment in an interactive shell: source $ENV_FILE"
  echo "- To run as non-root inside container: su - $APP_USER"
  echo "- Default PORT is set based on stack (Node: $DEFAULT_NODE_PORT, Python: $DEFAULT_PY_PORT, others: $DEFAULT_WEB_PORT)"
}

# -------------------------
# Main
# -------------------------
main() {
  log "Starting project environment setup..."
  install_base_tools
  setup_users_dirs
  detect_and_install_stack
  finalize_permissions
  print_summary
}

main "$@"