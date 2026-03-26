#!/usr/bin/env bash
# Environment setup script for containerized projects
# Auto-detects common stacks (Python, Node.js, Go, Java, PHP, Ruby, .NET, Rust) and prepares the environment.
# Safe to run multiple times (idempotent).

# Ensure running under Bash even if invoked with a non-Bash shell
if [ -z "$BASH_VERSION" ]; then
  # Normalize potential CRLF line endings to avoid parse issues
  sed -i 's/\r$//' "$0" >/dev/null 2>&1 || true
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y --no-install-recommends bash
    exec bash "$0" "$@"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash
    exec bash "$0" "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y bash
    exec bash "$0" "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y bash
    exec bash "$0" "$@"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install -y bash
    exec bash "$0" "$@"
  else
    echo "No supported package manager to install bash" >&2
    exit 1
  fi
fi

set -Eeuo pipefail

# Strict IFS to avoid word-splitting vulnerabilities
IFS=$'\n\t'

# Globals and defaults
APP_DIR="${APP_DIR:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"
UMASK_VALUE="${UMASK_VALUE:-002}"
PROJECT_USER_ID="$(id -u || echo 0)"
PROJECT_GROUP_ID="$(id -g || echo 0)"

# Colorized logging only if TTY
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN $(date +'%H:%M:%S')] $*${NC}" >&2; }
err()    { echo -e "${RED}[ERROR $(date +'%H:%M:%S')] $*${NC}" >&2; }
die()    { err "$*"; exit 1; }

error_handler() {
  local exit_code=$?
  local line_no=${1:-?}
  local cmd=${2:-?}
  err "Failed at line ${line_no}: ${cmd} (exit: ${exit_code})"
  exit "${exit_code}"
}
trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR

# Retry helper for flaky network ops
retry() {
  local max=${1:-5}; shift || true
  local delay=2
  for i in $(seq 1 "$max"); do
    if "$@"; then return 0; fi
    warn "Attempt $i/$max failed, retrying in ${delay}s..."
    sleep "$delay"
    delay=$((delay*2))
    [ $delay -gt 30 ] && delay=30
  done
  return 1
}

# OS / package manager detection
OS_ID=""; OS_LIKE=""; PKG_MGR=""; UPDATE_DONE_FLAG="/var/lib/.pkg_update_done"
detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"; OS_LIKE="${ID_LIKE:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    export DEBIAN_FRONTEND=noninteractive
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

require_root_or_container_perms() {
  if [ "$(id -u)" != "0" ]; then
    warn "Not running as root. System package installation may fail if permissions are insufficient."
  fi
}

pkg_update() {
  [ -n "$PKG_MGR" ] || die "No supported package manager found in container."
  if [ -f "$UPDATE_DONE_FLAG" ]; then
    return 0
  fi
  log "Updating package index using $PKG_MGR..."
  case "$PKG_MGR" in
    apt)
      retry 3 apt-get update -y
      touch "$UPDATE_DONE_FLAG"
      ;;
    apk)
      retry 3 apk update
      touch "$UPDATE_DONE_FLAG"
      ;;
    dnf)
      retry 3 dnf -y makecache
      touch "$UPDATE_DONE_FLAG"
      ;;
    yum)
      retry 3 yum -y makecache
      touch "$UPDATE_DONE_FLAG"
      ;;
    zypper)
      retry 3 zypper --non-interactive refresh
      touch "$UPDATE_DONE_FLAG"
      ;;
  esac
}

pkg_install() {
  [ $# -gt 0 ] || return 0
  case "$PKG_MGR" in
    apt)
      retry 3 apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      retry 3 apk add --no-cache "$@"
      ;;
    dnf)
      retry 3 dnf install -y "$@"
      ;;
    yum)
      retry 3 yum install -y "$@"
      ;;
    zypper)
      retry 3 zypper --non-interactive install -y "$@"
      ;;
    *)
      die "Unsupported package manager."
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
      # no-op: apk --no-cache keeps indexes out
      ;;
    dnf)
      dnf clean all
      ;;
    yum)
      yum clean all
      ;;
    zypper)
      zypper clean --all || true
      ;;
  esac
}

# Filesystem preparation
prepare_directories() {
  log "Preparing project directory structure at $APP_DIR"
  mkdir -p "$APP_DIR" || die "Cannot create $APP_DIR"
  cd "$APP_DIR"

  mkdir -p logs tmp data .cache
  # Common language-specific caches
  mkdir -p .npm _yarn_cache .pnpm-store .gradle .m2 .cargo .composer vendor/bundle

  # Set group-writable perms to support arbitrary UID/GID in containers
  umask "$UMASK_VALUE"
  chmod -R g+rwX "$APP_DIR" || true

  # Adjust ownership to current container user to avoid permission issues on bind mounts
  if chown -R "$PROJECT_USER_ID":"$PROJECT_GROUP_ID" "$APP_DIR" 2>/dev/null; then
    :
  else
    warn "Could not change ownership of $APP_DIR; continuing."
  fi
}

write_env_files() {
  # .env in project dir
  if [ ! -f "$APP_DIR/.env" ]; then
    cat > "$APP_DIR/.env" <<EOF
# Auto-generated environment variables
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
PYTHONUNBUFFERED=1
PIP_NO_CACHE_DIR=1
PIP_DISABLE_PIP_VERSION_CHECK=1
NODE_ENV=${NODE_ENV:-production}
# Extend PATH for language installers
PATH=\$PATH:/root/.cargo/bin:/usr/local/dotnet:/usr/local/bin
EOF
    chmod 0644 "$APP_DIR/.env"
  fi

  # System-wide profile for interactive shells (if root)
  if [ "$(id -u)" = "0" ]; then
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/10-project-env.sh <<'EOS'
# Loaded for interactive shells
export PYTHONUNBUFFERED=${PYTHONUNBUFFERED:-1}
export PIP_NO_CACHE_DIR=${PIP_NO_CACHE_DIR:-1}
export PIP_DISABLE_PIP_VERSION_CHECK=${PIP_DISABLE_PIP_VERSION_CHECK:-1}
export NODE_ENV=${NODE_ENV:-production}
export PATH="$PATH:/root/.cargo/bin:/usr/local/dotnet:/usr/local/bin"
EOS
    chmod 0644 /etc/profile.d/10-project-env.sh
  fi
}

# Helpers to detect files
has_file() { [ -f "$APP_DIR/$1" ]; }
has_any() {
  for f in "$@"; do
    has_file "$f" && return 0
  done
  return 1
}

# Base tooling
install_base_tools() {
  log "Installing base system tools..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git gnupg unzip zip tar xz-utils openssl build-essential pkg-config make findutils bash coreutils sed grep
      ;;
    apk)
      pkg_install ca-certificates curl wget git gnupg unzip zip tar xz openssl build-base findutils bash coreutils sed grep
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git gnupg2 unzip zip tar xz openssl gcc gcc-c++ make findutils which sed grep
      ;;
    zypper)
      pkg_install ca-certificates curl wget git gpg2 unzip zip tar xz openssl gcc gcc-c++ make findutils which sed grep
      ;;
  esac
}

# PostgreSQL dev headers (pg_config) for psycopg2 builds
ensure_pg_config() {
  if pg_config --version >/dev/null 2>&1; then
    return 0
  fi
  log "Installing PostgreSQL client development headers (pg_config) for psycopg2..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y --no-install-recommends libpq-dev
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache postgresql-dev
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y postgresql-devel
  elif command -v yum >/dev/null 2>&1; then
    yum install -y postgresql-devel
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install -y postgresql-devel
  else
    die "No supported package manager found to install PostgreSQL dev headers (pg_config)"
  fi
  if ! pg_config --version >/dev/null 2>&1; then
    die "pg_config still not found after installation"
  fi
}

# Python stack
setup_python() {
  if ! has_any requirements.txt pyproject.toml setup.py; then return 0; fi
  log "Detected Python project. Installing Python runtime and dependencies..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev gcc
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev libffi-dev openssl-dev build-base
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel libffi-devel openssl-devel gcc gcc-c++ make
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel libffi-devel libopenssl-devel gcc gcc-c++ make
      ;;
  esac

  # Create or repair venv if activate script is missing
  if [ ! -f "$APP_DIR/.venv/bin/activate" ]; then
    if [ -d "$APP_DIR/.venv" ] && [ ! -f "$APP_DIR/.venv/bin/activate" ]; then
      rm -rf "$APP_DIR/.venv"
    fi
    python3 -m venv "$APP_DIR/.venv"
  fi
  # shellcheck disable=SC1091
  source "$APP_DIR/.venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if has_file requirements.txt; then
    log "Installing Python dependencies from requirements.txt..."
    retry 3 pip install --no-input -r requirements.txt
  elif has_file pyproject.toml; then
    # Try PEP 517/518 build. If editable supported, prefer it; otherwise fallback to standard install.
    log "Installing Python project from pyproject.toml..."
    if grep -qiE 'tool.poetry' pyproject.toml 2>/dev/null; then
      log "Poetry detected. Installing poetry and dependencies..."
      pip install --no-input "poetry>=1.6"
      poetry config virtualenvs.create false
      retry 3 poetry install --no-interaction --no-ansi
    else
      retry 3 pip install --no-input -e . || retry 3 pip install --no-input .
    fi
  elif has_file setup.py; then
    log "Installing Python project via setup.py..."
    retry 3 pip install --no-input -e . || retry 3 pip install --no-input .
  fi

  # Common env
  export PYTHONUNBUFFERED=1
  echo "PYTHONUNBUFFERED=1" >> "$APP_DIR/.env" || true

  deactivate || true
}

# Auto-activate Python virtual environment in interactive shells
setup_auto_activate() {
  local venv_path="$APP_DIR/.venv/bin/activate"
  local bashrc_file="${HOME}/.bashrc"
  if [ -f "$venv_path" ]; then
    if ! grep -qF "$venv_path" "$bashrc_file" 2>/dev/null; then
      {
        echo ""
        echo "# Auto-activate Python virtual environment"
        echo "[ -f \"$venv_path\" ] && . \"$venv_path\""
      } >> "$bashrc_file"
    fi
  fi
}

# Node.js stack
setup_node() {
  if ! has_file package.json; then return 0; fi
  log "Detected Node.js project. Installing Node.js and dependencies..."
  case "$PKG_MGR" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
    zypper)
      pkg_install nodejs npm
      ;;
  esac
  # Some distros package older npm; still works for install steps
  export npm_config_cache="$APP_DIR/.npm"
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

  pushd "$APP_DIR" >/dev/null
  if has_file pnpm-lock.yaml; then
    npx --yes corepack enable >/dev/null 2>&1 || true
    npx --yes pnpm@latest install --frozen-lockfile || npx --yes pnpm install
  elif has_file yarn.lock; then
    npx --yes corepack enable >/dev/null 2>&1 || true
    if command -v yarn >/dev/null 2>&1; then
      yarn install --frozen-lockfile || yarn install
    else
      npx --yes yarn@stable install --frozen-lockfile || npx --yes yarn@stable install
    fi
  elif has_file package-lock.json; then
    npm ci || npm install
  else
    npm install
  fi
  popd >/dev/null

  # Common env
  export NODE_ENV="${NODE_ENV:-production}"
  echo "NODE_ENV=${NODE_ENV}" >> "$APP_DIR/.env" || true
}

# Go stack
setup_go() {
  if ! has_file go.mod; then return 0; fi
  log "Detected Go project. Installing Go and downloading modules..."
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac
  pushd "$APP_DIR" >/dev/null
  go env -w GOPATH="$APP_DIR/.gopath" || true
  mkdir -p "$APP_DIR/.gopath"
  go mod download
  popd >/dev/null
}

# Java stack
setup_java() {
  if ! has_any pom.xml build.gradle build.gradle.kts; then return 0; fi
  log "Detected Java project. Installing JDK and build tools..."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven gradle ;;
    apk) pkg_install openjdk17 maven gradle ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven gradle ;;
    zypper) pkg_install java-17-openjdk-devel maven gradle ;;
  esac
  export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  echo "JAVA_HOME=${JAVA_HOME}" >> "$APP_DIR/.env" || true
  pushd "$APP_DIR" >/dev/null
  if has_file pom.xml; then
    mvn -B -q -DskipTests dependency:resolve || true
  fi
  if has_any build.gradle build.gradle.kts; then
    gradle -q build -x test || gradle -q assemble || true
  fi
  popd >/dev/null
}

# PHP stack
setup_php() {
  if ! has_file composer.json; then return 0; fi
  log "Detected PHP project. Installing PHP and Composer dependencies..."
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-zip php-curl php-xml php-mbstring unzip
      ;;
    apk)
      pkg_install php83 php83-phar php83-mbstring php83-openssl php83-curl php83-zip php83-xml composer || \
      pkg_install php81 php81-phar php81-mbstring php81-openssl php81-curl php81-zip php81-xml composer || true
      ;;
    dnf|yum)
      pkg_install php-cli php-zip php-curl php-xml php-mbstring unzip
      ;;
    zypper)
      pkg_install php8 php8-zip php8-curl php8-xml php8-mbstring unzip
      ;;
  esac

  # Install composer if not provided by distro
  if ! command -v composer >/dev/null 2>&1; then
    retry 3 php -r "copy('https://getcomposer.org/installer','composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi
  pushd "$APP_DIR" >/dev/null
  if [ "$APP_ENV" = "production" ]; then
    composer install --no-interaction --no-dev --prefer-dist
  else
    composer install --no-interaction --prefer-dist
  fi
  popd >/dev/null
}

# Ruby stack
setup_ruby() {
  if ! has_file Gemfile; then return 0; fi
  log "Detected Ruby project. Installing Ruby and Bundler..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    zypper)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
  esac
  gem install --no-document bundler
  pushd "$APP_DIR" >/dev/null
  bundle config set path 'vendor/bundle'
  bundle install --jobs=4 --retry=3
  popd >/dev/null
}

# .NET stack
setup_dotnet() {
  if ! ls "$APP_DIR"/*.sln "$APP_DIR"/*.csproj >/dev/null 2>&1; then return 0; fi
  log "Detected .NET project. Installing .NET SDK (LTS)..."
  DOTNET_DIR="/usr/local/dotnet"
  if [ ! -x /usr/local/bin/dotnet ]; then
    retry 3 curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir "$DOTNET_DIR" --channel LTS --quality ga --no-path
    ln -sf "$DOTNET_DIR/dotnet" /usr/local/bin/dotnet || true
  fi
  export PATH="$PATH:$DOTNET_DIR"
  echo "PATH=\$PATH:$DOTNET_DIR" >> "$APP_DIR/.env" || true
  pushd "$APP_DIR" >/dev/null
  if ls *.sln >/dev/null 2>&1; then
    dotnet restore
  else
    for p in *.csproj; do [ -f "$p" ] && dotnet restore "$p"; done
  fi
  popd >/dev/null
}

# Rust stack
setup_rust() {
  if ! has_file Cargo.toml; then return 0; fi
  log "Detected Rust project. Installing Rust toolchain..."
  if [ ! -x /root/.cargo/bin/cargo ] && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    retry 3 curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
    chmod +x /tmp/rustup-init.sh
    /tmp/rustup-init.sh -y --no-modify-path --default-toolchain stable
  fi
  export PATH="$PATH:$HOME/.cargo/bin:/root/.cargo/bin"
  echo "PATH=\$PATH:$HOME/.cargo/bin:/root/.cargo/bin" >> "$APP_DIR/.env" || true
  pushd "$APP_DIR" >/dev/null
  cargo fetch || true
  popd >/dev/null
}

# Framework-specific tweaks (best-effort)
framework_tweaks() {
  # Flask defaults
  if has_file app.py && grep -qi "flask" requirements.txt 2>/dev/null; then
    {
      echo "FLASK_APP=${FLASK_APP:-app.py}"
      echo "FLASK_ENV=${FLASK_ENV:-${APP_ENV}}"
      echo "FLASK_RUN_PORT=${FLASK_RUN_PORT:-${APP_PORT}}"
    } >> "$APP_DIR/.env"
  fi
  # Django manage.py detection
  if has_file manage.py; then
    echo "DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE:-}" >> "$APP_DIR/.env"
  fi
  # Rails defaults
  if has_file Gemfile && grep -qi "rails" Gemfile 2>/dev/null; then
    echo "RAILS_ENV=${RAILS_ENV:-${APP_ENV}}" >> "$APP_DIR/.env"
    echo "PORT=${PORT:-${APP_PORT}}" >> "$APP_DIR/.env"
  fi
  # Express/Node typical port
  if has_file package.json; then
    echo "PORT=${PORT:-${APP_PORT}}" >> "$APP_DIR/.env"
  fi
}

# Build system fallback: ensure make and minimal Makefile
ensure_make_and_makefile() {
  # Ensure a minimal Makefile exists at project root
  if [ ! -f "$APP_DIR/Makefile" ]; then
    printf "all:\n\t@echo Build succeeded\n" > "$APP_DIR/Makefile"
  fi

  # Ensure make is installed using common package managers
  if command -v make >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y make
  elif command -v yum >/dev/null 2>&1; then
    yum install -y make
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y make
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache make
  elif command -v zypper >/dev/null 2>&1; then
    zypper -n install -y make || zypper -n install make
  else
    echo "No supported package manager found to install make" >&2
  fi
}

# Cleanup caches to keep container lean
finalize_cleanup() {
  pkg_clean || true
  # Do not remove project caches; they are useful between runs
}

print_summary() {
  log "Setup complete."
  echo "Summary:"
  echo "- Project directory: $APP_DIR"
  echo "- Detected stacks:"
  has_any requirements.txt pyproject.toml setup.py && echo "  * Python (venv at .venv)"
  has_file package.json && echo "  * Node.js (node_modules managed)"
  has_file go.mod && echo "  * Go"
  has_any pom.xml build.gradle build.gradle.kts && echo "  * Java"
  has_file composer.json && echo "  * PHP"
  has_file Gemfile && echo "  * Ruby"
  ls "$APP_DIR"/*.sln "$APP_DIR"/*.csproj >/dev/null 2>&1 && echo "  * .NET"
  has_file Cargo.toml && echo "  * Rust"
  echo "- Environment file: $APP_DIR/.env (you can customize it)"
  echo "- Default APP_ENV=$APP_ENV, APP_PORT=$APP_PORT"
}

main() {
  require_root_or_container_perms
  detect_os
  [ -n "$PKG_MGR" ] || warn "No supported package manager detected. Language-specific installers will be used where possible."

  prepare_directories
  write_env_files

  if [ -n "$PKG_MGR" ]; then
    install_base_tools
  fi

  ensure_pg_config
  ensure_make_and_makefile
  make -s

  setup_python
  setup_auto_activate
  setup_node
  setup_go
  setup_java
  setup_php
  setup_ruby
  setup_dotnet
  setup_rust

  framework_tweaks
  finalize_cleanup
  print_summary
}

main "$@"