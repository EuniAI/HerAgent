#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Installs runtime and dependencies based on detected project type
# Supports: Python, Node.js, Ruby, PHP, Java, Go, Rust (basic)
# Safe to run multiple times (idempotent)

set -Eeuo pipefail
IFS=$'\n\t'

# Colors (non-intrusive if not a TTY)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BLUE=''; NC=''
fi

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
info()   { echo -e "${BLUE}$*${NC}"; }

trap 'rc=$?; error "Failed at line $LINENO with exit code $rc"; exit $rc' ERR

# Globals / Defaults
APP_DIR="${APP_DIR:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-}"
APP_PORT="${APP_PORT:-}"
FORCE_PKG_INDEX_REFRESH="${FORCE_PKG_INDEX_REFRESH:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"
CREATE_APP_USER="${CREATE_APP_USER:-0}"

# Retry helper
retry() {
  local attempts="${1:-3}"; shift || true
  local delay="${1:-3}"; shift || true
  local i=1
  while true; do
    "$@" && break || {
      if [ "$i" -lt "$attempts" ]; then
        warn "Command failed (attempt $i/$attempts). Retrying in ${delay}s: $*"
        sleep "$delay"
        i=$((i+1))
      else
        error "Command failed after $attempts attempts: $*"
        return 1
      fi
    }
  done
}

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

# Detect package manager
PKG_MGR=""
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt";
  elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk";
  elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf";
  elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum";
  elif command -v microdnf >/dev/null 2>&1; then PKG_MGR="microdnf";
  else PKG_MGR=""; fi
}

# Update package index (idempotent-ish)
pkg_update() {
  [ "$(is_root && echo 1 || echo 0)" = "1" ] || { warn "Not root; skipping system package index update"; return 0; }
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      if [ "$FORCE_PKG_INDEX_REFRESH" = "1" ] || [ ! -f /var/lib/apt/periodic/update-success-stamp ]; then
        retry 3 5 apt-get update -y
      fi
      ;;
    apk)
      # apk update is fast and idempotent
      retry 3 3 apk update
      ;;
    dnf|yum|microdnf)
      # no-op; dnf/yum auto refresh metadata
      ;;
    *)
      warn "Unknown package manager; cannot update package index"
      ;;
  esac
}

# Install packages by manager
pkg_install() {
  [ "$(is_root && echo 1 || echo 0)" = "1" ] || { warn "Not root; cannot install system packages: $*"; return 0; }
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      retry 3 5 apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      retry 3 3 apk add --no-cache "$@"
      ;;
    dnf)
      retry 3 5 dnf install -y "$@"
      ;;
    yum)
      retry 3 5 yum install -y "$@"
      ;;
    microdnf)
      retry 3 5 microdnf install -y "$@"
      ;;
    *)
      warn "Unknown package manager; cannot install system packages: $*"
      ;;
  esac
}

# Base OS deps
install_base_os_deps() {
  log "Installing base OS packages (if possible)..."
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git gnupg dirmngr unzip xz-utils tar bash coreutils findutils grep sed gawk build-essential pkg-config openssl libssl-dev libffi-dev
      ;;
    apk)
      pkg_install ca-certificates curl wget git unzip xz tar bash coreutils findutils grep sed gawk build-base openssl-dev libffi-dev
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl wget git unzip xz tar bash coreutils findutils grep sed gawk gcc gcc-c++ make pkgconf openssl-devel libffi-devel shadow-utils
      ;;
    *)
      warn "Skipping base OS packages; unsupported package manager"
      ;;
  esac
  # Ensure CA store
  if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates || true; fi
}

# Ensure app directory and permissions
setup_directories() {
  local dir="$APP_DIR"
  if [ ! -d "$dir" ]; then
    log "Creating application directory: $dir"
    mkdir -p "$dir"
  fi
  mkdir -p "$dir"/{logs,tmp,data,cache}
  chmod 755 "$dir" || true
}

# Create app user if requested and root
ensure_app_user() {
  if ! is_root; then
    APP_USER="${APP_USER:-$(id -un)}"
    APP_GROUP="${APP_GROUP:-$(id -gn)}"
    return 0
  fi

  if [ -n "${APP_USER}" ]; then
    : # caller provided user
  elif [ "$CREATE_APP_USER" = "1" ]; then
    APP_USER="app"
  else
    APP_USER="root"
  fi

  if [ "$APP_USER" != "root" ]; then
    # Create group if necessary
    if ! getent group "${APP_GROUP:-$APP_USER}" >/dev/null 2>&1; then
      case "$PKG_MGR" in
        apk) addgroup -S "${APP_GROUP:-$APP_USER}" || true ;;
        *)   groupadd -r "${APP_GROUP:-$APP_USER}"  || true ;;
      esac
    fi
    # Create user if necessary
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      case "$PKG_MGR" in
        apk) adduser -S -G "${APP_GROUP:-$APP_USER}" -s /bin/bash "$APP_USER" || true ;;
        *)   useradd -r -m -g "${APP_GROUP:-$APP_USER}" -s /bin/bash "$APP_USER" || true ;;
      esac
    fi
  fi

  chown -R "${APP_USER}:${APP_GROUP:-$APP_USER}" "$APP_DIR" || true
}

# Detect project type by files
detect_project_type() {
  local dir="$1"
  local type="unknown"

  [ -f "$dir/package.json" ] && type="node"
  if [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/Pipfile" ] || [ -f "$dir/setup.py" ]; then
    # If both Node and Python exist, mark as "fullstack"
    if [ "$type" = "node" ]; then type="fullstack"; else type="python"; fi
  fi
  [ -f "$dir/Gemfile" ] && type="${type:-ruby}"
  [ -f "$dir/composer.json" ] && type="${type:-php}"
  { [ -f "$dir/pom.xml" ] || [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ]; } && type="${type:-java}"
  [ -f "$dir/go.mod" ] && type="${type:-go}"
  [ -f "$dir/Cargo.toml" ] && type="${type:-rust}"
  echo "$type"
}

# Setup Python runtime and dependencies
setup_python() {
  log "Configuring Python environment..."
  case "$PKG_MGR" in
    apt)   pkg_install python3 python3-pip python3-venv python3-dev python-is-python3 ;;
    apk)   pkg_install python3 py3-pip python3-dev ;;
    dnf|yum|microdnf) pkg_install python3 python3-pip python3-devel ;;
    *) warn "Cannot install Python via package manager; expecting it to be preinstalled";;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; skipping Python setup"
    return 0
  fi

  # Ensure pip is available
  if ! command -v pip3 >/dev/null 2>&1; then
    python3 -m ensurepip --upgrade || true
  fi

  local venv_dir="$APP_DIR/.venv"
  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  fi
  # Activate venv for this session
  # shellcheck source=/dev/null
  source "$venv_dir/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [ -f "$APP_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    retry 3 5 pip install -r "$APP_DIR/requirements.txt"
  elif [ -f "$APP_DIR/pyproject.toml" ]; then
    log "Detected pyproject.toml; attempting pip install ."
    retry 3 5 pip install .
  elif [ -f "$APP_DIR/Pipfile" ]; then
    log "Detected Pipfile; installing pipenv and dependencies"
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 retry 3 5 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 retry 3 5 pipenv install
  else
    warn "No Python dependency file found"
  fi

  # Environment defaults
  set_env_var "PYTHONUNBUFFERED" "1"
  set_env_var "PIP_DISABLE_PIP_VERSION_CHECK" "1"
  set_env_path_prepend "$venv_dir/bin"
}

# Setup Node.js runtime and dependencies
setup_node() {
  log "Configuring Node.js environment..."

  local have_node=0
  if command -v node >/dev/null 2>&1; then have_node=1; fi

  if [ "$have_node" -eq 0 ]; then
    case "$PKG_MGR" in
      apt)
        # Try distro packages first
        if retry 1 0 apt-get install -y --no-install-recommends nodejs npm; then
          have_node=1
        fi
        ;;
      apk)
        if retry 1 0 apk add --no-cache nodejs npm; then
          have_node=1
        fi
        ;;
      dnf|yum|microdnf)
        if retry 1 0 "$PKG_MGR" install -y nodejs npm; then
          have_node=1
        fi
        ;;
    esac
  fi

  # Fallback to NVM (system-wide in /opt/nvm if root, else $HOME/.nvm)
  local NVM_DIR
  if [ "$have_node" -eq 0 ]; then
    if is_root; then
      NVM_DIR="/opt/nvm"
      mkdir -p "$NVM_DIR"
      if [ ! -f "$NVM_DIR/nvm.sh" ]; then
        log "Installing NVM to $NVM_DIR"
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | NVM_DIR="$NVM_DIR" bash
      fi
    else
      NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
      if [ ! -f "$NVM_DIR/nvm.sh" ]; then
        log "Installing NVM to $NVM_DIR"
        mkdir -p "$NVM_DIR"
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | NVM_DIR="$NVM_DIR" bash
      fi
    fi
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
    # Determine Node version
    local node_version="lts/*"
    if [ -f "$APP_DIR/.nvmrc" ]; then node_version="$(tr -d ' \t\n\r' < "$APP_DIR/.nvmrc")"; fi
    log "Installing Node.js version: $node_version via NVM"
    retry 3 5 nvm install "$node_version"
    nvm alias default "$node_version"
    have_node=1
    # Ensure NVM available in future shells
    append_env_script "export NVM_DIR=\"$NVM_DIR\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"  # This loads nvm
[ -s \"\$NVM_DIR/bash_completion\" ] && . \"\$NVM_DIR/bash_completion\""
  fi

  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not available; skipping Node setup"
    return 0
  fi

  # Install dependencies
  if [ -f "$APP_DIR/package-lock.json" ]; then
    log "Installing Node dependencies with npm ci"
    (cd "$APP_DIR" && retry 3 5 npm ci --omit=dev)
  elif [ -f "$APP_DIR/yarn.lock" ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      log "Installing Yarn"
      if [ "$PKG_MGR" = "apk" ]; then pkg_install yarn || npm install -g yarn
      else npm install -g yarn; fi
    fi
    log "Installing Node dependencies with yarn install --frozen-lockfile"
    (cd "$APP_DIR" && retry 3 5 yarn install --frozen-lockfile --production)
  elif [ -f "$APP_DIR/pnpm-lock.yaml" ]; then
    if ! command -v pnpm >/dev/null 2>&1; then
      log "Installing pnpm"
      npm install -g pnpm
    fi
    log "Installing Node dependencies with pnpm i --prod"
    (cd "$APP_DIR" && retry 3 5 pnpm install --frozen-lockfile --prod)
  elif [ -f "$APP_DIR/package.json" ]; then
    log "Installing Node dependencies with npm install --omit=dev"
    (cd "$APP_DIR" && retry 3 5 npm install --omit=dev)
  else
    warn "No package.json found; skipping Node dependency installation"
  fi

  set_env_var "NODE_ENV" "${NODE_ENV:-production}"
}

# Setup Ruby (basic)
setup_ruby() {
  log "Configuring Ruby environment..."
  case "$PKG_MGR" in
    apt) pkg_install ruby-full build-essential ;;
    apk) pkg_install ruby ruby-dev build-base ;;
    dnf|yum|microdnf) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
    *) warn "Cannot install Ruby via package manager";;
  esac
  if command -v gem >/dev/null 2>&1 && [ -f "$APP_DIR/Gemfile" ]; then
    gem install bundler --no-document || true
    (cd "$APP_DIR" && bundle install --without development test || bundle install)
  fi
}

# Setup PHP (basic)
setup_php() {
  log "Configuring PHP environment..."
  case "$PKG_MGR" in
    apt) pkg_install php-cli php-zip php-curl php-mbstring unzip ;;
    apk) pkg_install php81 php81-cli php81-phar php81-mbstring php81-curl php81-openssl unzip || pkg_install php php-cli php-phar php-mbstring php-curl php-openssl unzip ;;
    dnf|yum|microdnf) pkg_install php-cli php-zip php-mbstring php-json unzip ;;
    *) warn "Cannot install PHP via package manager";;
  esac
  if [ -f "$APP_DIR/composer.json" ]; then
    if ! command -v composer >/dev/null 2>&1; then
      log "Installing Composer"
      EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
      php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
      ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
      if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
        rm -f composer-setup.php
        error "Invalid composer installer signature"; return 1
      fi
      php composer-setup.php --install-dir=/usr/local/bin --filename=composer
      rm -f composer-setup.php
    fi
    (cd "$APP_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --prefer-dist --no-interaction)
  fi
}

# Setup Java (basic)
setup_java() {
  log "Configuring Java environment..."
  case "$PKG_MGR" in
    apt) pkg_install default-jdk maven gradle ;;
    apk) pkg_install openjdk17 maven gradle || pkg_install openjdk11 maven gradle ;;
    dnf|yum|microdnf) pkg_install java-17-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven gradle ;;
    *) warn "Cannot install Java via package manager";;
  esac
  if [ -f "$APP_DIR/pom.xml" ]; then (cd "$APP_DIR" && mvn -B -ntp -DskipTests dependency:resolve || true); fi
  if [ -f "$APP_DIR/build.gradle" ] || [ -f "$APP_DIR/build.gradle.kts" ]; then (cd "$APP_DIR" && gradle --no-daemon --quiet build -x test || true); fi
}

# Setup Go (basic)
setup_go() {
  log "Configuring Go environment..."
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum|microdnf) pkg_install golang ;;
    *) warn "Cannot install Go via package manager";;
  esac
  if command -v go >/dev/null 2>&1 && [ -f "$APP_DIR/go.mod" ]; then
    (cd "$APP_DIR" && go mod download)
  fi
}

# Setup Rust (basic via rustup)
setup_rust() {
  log "Configuring Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    local CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    append_env_script "export CARGO_HOME=\"$CARGO_HOME\"
[ -f \"\$CARGO_HOME/env\" ] && . \"\$CARGO_HOME/env\""
    # shellcheck source=/dev/null
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  fi
  if command -v cargo >/dev/null 2>&1 && [ -f "$APP_DIR/Cargo.toml" ]; then
    (cd "$APP_DIR" && cargo fetch)
  fi
}

# Environment management
ENV_FILE=""
ENV_SCRIPT=""
init_env_files() {
  ENV_FILE="$APP_DIR/.env"
  ENV_SCRIPT="$APP_DIR/environment.sh"
  touch "$ENV_FILE" "$ENV_SCRIPT"
  chmod 0644 "$ENV_FILE" "$ENV_SCRIPT" || true
}

# Append export lines to .env if key not present
set_env_var() {
  local key="$1"; local val="$2"
  if ! grep -qE "^\s*${key}=" "$ENV_FILE"; then
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
  export "$key"="$val"
}

# Prepend path to path-like exports into environment.sh (idempotent)
set_env_path_prepend() {
  local p="$1"
  if ! grep -qF "PATH=\"$p:\$PATH\"" "$ENV_SCRIPT"; then
    echo "export PATH=\"$p:\$PATH\"" >> "$ENV_SCRIPT"
  fi
  export PATH="$p:$PATH"
}

# Append arbitrary lines to environment.sh if not already present
append_env_script() {
  local block="$1"
  if ! grep -qF "$block" "$ENV_SCRIPT"; then
    printf '%s\n' "$block" >> "$ENV_SCRIPT"
  fi
}

# Create minimal Python build files if no recognized build files are present
ensure_minimal_python_build_files() {
  local dir="$APP_DIR"
  if [ ! -f "$dir/pom.xml" ] && [ ! -f "$dir/build.gradle" ] && [ ! -f "$dir/build.gradle.kts" ] && \
     [ ! -f "$dir/package.json" ] && [ ! -f "$dir/Cargo.toml" ] && [ ! -f "$dir/go.mod" ] && \
     [ ! -f "$dir/pyproject.toml" ] && [ ! -f "$dir/setup.py" ]; then
    cat > "$dir/pyproject.toml" << "EOF"
[build-system]
requires = ["setuptools>=64", "wheel"]
build-backend = "setuptools.build_meta"
EOF
    cat > "$dir/setup.py" << "EOF"
from setuptools import setup

setup(
    name="dummyproj",
    version="0.0.1",
    description="Placeholder package to satisfy build detection.",
    packages=[],
)
EOF
  fi
}

# Setup automatic activation of Python virtual environment in bashrc
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local venv_dir="$APP_DIR/.venv"
  local activate_line="source \"$venv_dir/bin/activate\""
  if [ -d "$venv_dir" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

# Detect application port based on common frameworks
detect_port() {
  local port=""
  # Python Flask/Django defaults
  if [ -f "$APP_DIR/app.py" ] || grep -qi "flask" "$APP_DIR/requirements.txt" 2>/dev/null; then port="5000"; fi
  if [ -f "$APP_DIR/manage.py" ] || grep -qi "django" "$APP_DIR/requirements.txt" 2>/dev/null; then port="${port:-8000}"; fi
  # Node.js Express/Nest defaults
  if [ -f "$APP_DIR/package.json" ]; then
    if grep -qi "express" "$APP_DIR/package.json"; then port="${port:-3000}"; fi
    if grep -qi "next" "$APP_DIR/package.json"; then port="${port:-3000}"; fi
    if grep -qi "nuxt" "$APP_DIR/package.json"; then port="${port:-3000}"; fi
    if grep -qi "nestjs" "$APP_DIR/package.json"; then port="${port:-3000}"; fi
  fi
  # Rails default
  if [ -f "$APP_DIR/Gemfile" ] && grep -qi "rails" "$APP_DIR/Gemfile"; then port="${port:-3000}"; fi
  # PHP built-in server default
  if [ -f "$APP_DIR/composer.json" ]; then port="${port:-8000}"; fi
  echo "${APP_PORT:-${port:-3000}}"
}

# Summary of detected stack
print_summary() {
  info "----- Environment Summary -----"
  info "App dir:       $APP_DIR"
  info "Project type:  $PROJECT_TYPE"
  info "User:          ${APP_USER:-$(id -un)}"
  info "Env file:      $ENV_FILE"
  info "Env script:    $ENV_SCRIPT"
  info "App env:       ${APP_ENV}"
  info "App port:      ${APP_PORT}"
  info "-------------------------------"
  info "To load environment in a shell: source \"$ENV_SCRIPT\" 2>/dev/null || true; export \$(grep -E '^[A-Z0-9_]+=' \"$ENV_FILE\" | cut -d= -f1); set -a; . \"$ENV_FILE\"; set +a"
}

main() {
  log "Starting universal project environment setup..."

  # Resolve APP_DIR: prefer current directory if it looks like a project
  CUR="$(pwd)"
  if [ -f "$CUR/package.json" ] || [ -f "$CUR/requirements.txt" ] || [ -f "$CUR/pyproject.toml" ] || [ -f "$CUR/Gemfile" ] || [ -f "$CUR/composer.json" ] || [ -f "$CUR/go.mod" ] || [ -f "$CUR/Cargo.toml" ] || [ -f "$CUR/pom.xml" ] || [ -f "$CUR/build.gradle" ] || [ -f "$CUR/build.gradle.kts" ]; then
    APP_DIR="$CUR"
  else
    mkdir -p "$APP_DIR"
  fi

  detect_pkg_mgr
  pkg_update
  install_base_os_deps

  setup_directories
  ensure_app_user

  init_env_files
  set_env_var "APP_ENV" "$APP_ENV"
  set_env_var "APP_HOME" "$APP_DIR"

  # Ensure minimal Python build files exist when no build system is detected
  ensure_minimal_python_build_files

  PROJECT_TYPE="$(detect_project_type "$APP_DIR")"
  log "Detected project type: $PROJECT_TYPE"

  # Setup per-type
  case "$PROJECT_TYPE" in
    fullstack)
      setup_python
      setup_node
      ;;
    python)
      setup_python
      ;;
    node)
      setup_node
      ;;
    ruby)
      setup_ruby
      ;;
    php)
      setup_php
      ;;
    java)
      setup_java
      ;;
    go)
      setup_go
      ;;
    rust)
      setup_rust
      ;;
    *)
      warn "Could not determine project type; installing minimal tools only."
      ;;
  esac

  # Ensure automatic activation of Python virtual environment in future shells
  setup_auto_activate

  # Compute and save port
  APP_PORT="$(detect_port)"
  set_env_var "APP_PORT" "$APP_PORT"

  # Set common environment
  set_env_var "LANG" "${LANG:-C.UTF-8}"
  set_env_var "LC_ALL" "${LC_ALL:-C.UTF-8}"
  set_env_var "TZ" "${TZ:-UTC}"

  # Ensure ownership
  if is_root; then
    chown -R "${APP_USER:-root}:${APP_GROUP:-${APP_USER:-root}}" "$APP_DIR" || true
  fi

  print_summary
  log "Environment setup completed successfully."
}

main "$@"