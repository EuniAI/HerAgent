#!/usr/bin/env bash
# Environment setup script for containerized projects
# Detects project type and installs appropriate runtimes, system dependencies,
# configures environment variables, and sets up directories and permissions.
# Designed to run inside Docker containers without sudo and be idempotent.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# Logging
LOG_DIR_DEFAULT="/var/log/env-setup"
SCRIPT_NAME="$(basename "$0")"
START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/${SCRIPT_NAME%.sh}.log}"

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARNING] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
debug()  { echo -e "${BLUE}[DEBUG] $*${NC}"; }

err_trap() {
  local exit_code=$?
  local line_no=$1
  error "Script failed at line $line_no with exit code $exit_code"
  error "Check logs at $LOG_FILE"
  exit "$exit_code"
}
trap 'err_trap $LINENO' ERR

# Globals
PROJECT_DIR="${PROJECT_DIR:-}"
PM=""
OS_ID=""
OS_LIKE=""
ARCH="$(uname -m)"
STAMP_DIR="/var/lib/env-setup"
STATE_DIR="/app/.env-setup"
ENV_FILE="/app/.env.container"
DEFAULT_USER_UID="${APP_UID:-}"
DEFAULT_USER_GID="${APP_GID:-}"
TZ_DEFAULT="${TZ:-UTC}"

mkdir -p "$STAMP_DIR" || true
mkdir -p "$LOG_DIR" || true
touch "$LOG_FILE" || true

# Ensure log rotation if > 5MB
rotate_logs() {
  local size
  size=$(wc -c <"$LOG_FILE" || echo 0)
  if [ "$size" -gt $((5 * 1024 * 1024)) ]; then
    mv "$LOG_FILE" "${LOG_FILE}.1" || true
    : > "$LOG_FILE"
    log "Rotated log file: ${LOG_FILE}.1"
  fi
}
rotate_logs

# Redirect all output to both stdout and log
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

log "Starting environment setup at $START_TIME"

# Helpers
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Script is not running as root. Package installation may fail inside containers."
    warn "If using a non-root container image, ensure required packages are present."
  fi
}

in_container() {
  if [ -f /.dockerenv ]; then return 0; fi
  if grep -qE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then return 0; fi
  return 1
}

ensure_dir() {
  local dir="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
  chmod "$mode" "$dir" || true
  chown "$owner":"$group" "$dir" || true
}

detect_os_pm() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PM="zypper"
  else
    PM="unknown"
  fi
  log "Detected OS: ${OS_ID:-unknown}, package manager: $PM"
}

pkg_update() {
  case "$PM" in
    apt)
      if [ ! -f "$STAMP_DIR/apt_updated" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        touch "$STAMP_DIR/apt_updated"
      fi
      ;;
    apk)
      # apk uses --no-cache flag typically; update not required
      true
      ;;
    dnf)
      if [ ! -f "$STAMP_DIR/dnf_updated" ]; then
        dnf -y makecache
        touch "$STAMP_DIR/dnf_updated"
      fi
      ;;
    yum)
      if [ ! -f "$STAMP_DIR/yum_updated" ]; then
        yum -y makecache
        touch "$STAMP_DIR/yum_updated"
      fi
      ;;
    zypper)
      if [ ! -f "$STAMP_DIR/zypper_refreshed" ]; then
        zypper --non-interactive refresh
        touch "$STAMP_DIR/zypper_refreshed"
      fi
      ;;
    *)
      warn "Unknown package manager. Skipping update."
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local pkgs=("$@")
  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
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
      zypper --non-interactive install --no-recommends "${pkgs[@]}"
      ;;
    *)
      error "Cannot install packages: unknown package manager."
      ;;
  esac
}

install_common_packages() {
  log "Installing common system packages..."
  case "$PM" in
    apt)
      pkg_update
      pkg_install ca-certificates curl wget git unzip xz-utils tar bash coreutils findutils grep sed procps tzdata build-essential pkg-config
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl wget git unzip xz tar bash coreutils findutils grep sed procps tzdata build-base pkgconfig
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_update
      pkg_install ca-certificates curl wget git unzip xz tar bash coreutils findutils grep sed procps tzdata make gcc gcc-c++ pkgconfig
      ;;
    zypper)
      pkg_update
      pkg_install ca-certificates curl wget git unzip xz tar bash coreutils findutils grep sed procps tzdata make gcc gcc-c++ pkg-config
      ;;
    *)
      warn "Skipping common package installation due to unknown package manager."
      ;;
  esac
  log "Common system packages installed."
}

# Arch mapping for Node/Go binaries
node_arch() {
  case "$ARCH" in
    x86_64) echo "x64" ;;
    aarch64) echo "arm64" ;;
    armv7l) echo "armv7l" ;;
    i686|i386) echo "x86" ;;
    *) echo "$ARCH" ;;
  esac
}

go_arch() {
  case "$ARCH" in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l) echo "armv6l" ;; # Go provides armv6l/armv7l sometimes; fallback to armv6l
    i686|i386) echo "386" ;;
    *) echo "$ARCH" ;;
  esac
}

# Language runtimes install
ensure_python() {
  log "Ensuring Python runtime and build dependencies..."
  case "$PM" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev zlib1g-dev libjpeg-dev libxml2-dev libxslt1-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev build-base libffi-dev openssl-dev zlib-dev jpeg-dev libxml2-dev libxslt-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel make gcc gcc-c++ libffi-devel openssl-devel zlib-devel libjpeg-turbo-devel libxml2-devel libxslt-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel make gcc gcc-c++ libffi-devel libopenssl-devel zlib-devel libjpeg8-devel libxml2-devel libxslt-devel
      ;;
    *)
      warn "Package manager unknown; Python installation may be unavailable."
      ;;
  esac
  log "Python ready."
}

ensure_node() {
  log "Ensuring Node.js runtime..."
  if command -v node >/dev/null 2>&1; then
    local ver major
    ver="$(node -v || echo v0.0.0)"
    major="$(echo "$ver" | sed -E 's/^v([0-9]+).*/\1/')"
    if [ "${major:-0}" -ge 16 ]; then
      log "Node.js $ver already present."
      return 0
    fi
  fi
  # Try package manager installation first
  case "$PM" in
    apt)
      pkg_install nodejs npm || true
      ;;
    apk)
      pkg_install nodejs npm || true
      ;;
    dnf|yum)
      pkg_install nodejs npm || true
      ;;
    zypper)
      pkg_install nodejs14 npm14 || pkg_install nodejs npm || true
      ;;
  esac
  if command -v node >/dev/null 2>&1; then
    log "Installed Node.js via package manager."
    return 0
  fi
  # Fallback to binary tarball install (LTS)
  local NODE_VERSION="${NODE_VERSION:-20.11.1}"
  local NARCH
  NARCH="$(node_arch)"
  local url="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NARCH}.tar.xz"
  local dest="/usr/local/node-v${NODE_VERSION}-linux-${NARCH}"
  local link="/usr/local/node"
  log "Installing Node.js v${NODE_VERSION} from tarball: $url"
  curl -fsSL "$url" -o /tmp/node.tar.xz
  mkdir -p "$dest"
  tar -xJf /tmp/node.tar.xz -C /tmp
  mv "/tmp/node-v${NODE_VERSION}-linux-${NARCH}" "$dest"
  ln -sfn "$dest" "$link"
  ln -sfn "$link/bin/node" /usr/local/bin/node
  ln -sfn "$link/bin/npm" /usr/local/bin/npm
  ln -sfn "$link/bin/npx" /usr/local/bin/npx
  rm -f /tmp/node.tar.xz
  log "Node.js installed at $dest"
}

ensure_ruby() {
  log "Ensuring Ruby runtime..."
  case "$PM" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel make gcc gcc-c++
      ;;
    zypper)
      pkg_install ruby ruby-devel make gcc gcc-c++
      ;;
    *)
      warn "Unknown package manager; Ruby installation may be unavailable."
      ;;
  esac
  if ! command -v bundler >/dev/null 2>&1; then
    gem install --no-document bundler || warn "Failed to install bundler"
  fi
  log "Ruby ready."
}

ensure_go() {
  log "Ensuring Go runtime..."
  if command -v go >/dev/null 2>&1; then
    log "Go $(go version) already present."
    return 0
  fi
  local GOVERSION="${GO_VERSION:-1.22.5}"
  local GARCH
  GARCH="$(go_arch)"
  local url="https://go.dev/dl/go${GOVERSION}.linux-${GARCH}.tar.gz"
  log "Installing Go ${GOVERSION} from tarball: $url"
  curl -fsSL "$url" -o /tmp/go.tgz
  rm -rf /usr/local/go || true
  tar -xzf /tmp/go.tgz -C /usr/local
  rm -f /tmp/go.tgz
  if ! grep -q "/usr/local/go/bin" /etc/profile 2>/dev/null; then
    echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile
  fi
  export PATH="/usr/local/go/bin:$PATH"
  log "Go installed at /usr/local/go"
}

ensure_java() {
  log "Ensuring OpenJDK and build tools..."
  case "$PM" in
    apt)
      pkg_install openjdk-17-jdk maven gradle || pkg_install openjdk-17-jdk maven || true
      ;;
    apk)
      pkg_install openjdk17 openjdk17-jdk maven gradle || pkg_install openjdk17 openjdk17-jdk || true
      ;;
    dnf|yum)
      pkg_install java-17-openjdk java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk java-17-openjdk-devel || true
      ;;
    zypper)
      pkg_install java-17-openjdk java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk java-17-openjdk-devel || true
      ;;
    *)
      warn "Unknown package manager; Java installation may be unavailable."
      ;;
  esac
  export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  if [ -n "${JAVA_HOME:-}" ]; then
    log "JAVA_HOME set to $JAVA_HOME"
  fi
}

ensure_php() {
  log "Ensuring PHP CLI and Composer..."
  case "$PM" in
    apt)
      pkg_install php-cli php-zip php-mbstring php-curl php-xml git unzip
      ;;
    apk)
      pkg_install php php-cli php-zip php-mbstring php-curl php-xml git unzip
      ;;
    dnf|yum)
      pkg_install php-cli php-zip php-mbstring php-curl php-xml git unzip
      ;;
    zypper)
      pkg_install php-cli php7-zip php7-mbstring php7-curl php7-xml git unzip || pkg_install php-cli php-zip php-mbstring php-curl php-xml git unzip
      ;;
    *)
      warn "Unknown package manager; PHP installation may be unavailable."
      ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Composer install failed"
    rm -f /tmp/composer-setup.php
  fi
  log "PHP ready."
}

ensure_rust() {
  log "Ensuring Rust toolchain..."
  if command -v cargo >/dev/null 2>&1; then
    log "Rust $(rustc --version 2>/dev/null || echo 'installed') already present."
    return 0
  fi
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
  sh /tmp/rustup.sh -y --no-modify-path
  rm -f /tmp/rustup.sh
  export PATH="$HOME/.cargo/bin:$PATH"
  if ! grep -q "$HOME/.cargo/bin" /etc/profile 2>/dev/null; then
    echo "export PATH=\$HOME/.cargo/bin:\$PATH" >> /etc/profile
  fi
  log "Rust installed."
}

# Project detectors
is_python_project() {
  [ -f "$PROJECT_DIR/requirements.txt" ] || [ -f "$PROJECT_DIR/pyproject.toml" ] || [ -f "$PROJECT_DIR/Pipfile" ]
}
is_node_project() {
  [ -f "$PROJECT_DIR/package.json" ]
}
is_ruby_project() {
  [ -f "$PROJECT_DIR/Gemfile" ]
}
is_go_project() {
  [ -f "$PROJECT_DIR/go.mod" ] || [ -f "$PROJECT_DIR/go.sum" ]
}
is_java_project() {
  [ -f "$PROJECT_DIR/pom.xml" ] || [ -f "$PROJECT_DIR/build.gradle" ] || [ -f "$PROJECT_DIR/build.gradle.kts" ]
}
is_php_project() {
  [ -f "$PROJECT_DIR/composer.json" ]
}
is_rust_project() {
  [ -f "$PROJECT_DIR/Cargo.toml" ]
}

# Environment and directories
setup_project_dir() {
  # Decide project directory
  if [ -z "${PROJECT_DIR:-}" ]; then
    if [ -d "/app" ]; then
      PROJECT_DIR="/app"
    else
      PROJECT_DIR="$(pwd -P)"
    fi
  fi
  ensure_dir "$PROJECT_DIR" 0755 root root
  ensure_dir "$STATE_DIR" 0755 root root
  ensure_dir "$PROJECT_DIR/logs" 0755 root root
  ensure_dir "$PROJECT_DIR/tmp" 0777 root root
  log "Project directory set to $PROJECT_DIR"
}

configure_timezone() {
  if [ -n "${TZ_DEFAULT:-}" ]; then
    case "$PM" in
      apt)
        ln -snf "/usr/share/zoneinfo/$TZ_DEFAULT" /etc/localtime || true
        echo "$TZ_DEFAULT" > /etc/timezone || true
        ;;
      apk|dnf|yum|zypper)
        ln -snf "/usr/share/zoneinfo/$TZ_DEFAULT" /etc/localtime || true
        ;;
    esac
    log "Timezone configured: $TZ_DEFAULT"
  fi
}

load_env_file() {
  local env_path="$PROJECT_DIR/.env"
  if [ -f "$env_path" ]; then
    # Only export regular key=value lines
    # shellcheck disable=SC2046
    export $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_path" | xargs -d '\n')
    log "Loaded environment from $env_path"
  fi
}

write_env_defaults() {
  {
    echo "APP_ENV=${APP_ENV:-production}"
    echo "PORT=${PORT:-8080}"
    echo "TZ=${TZ_DEFAULT}"
    echo "LANG=${LANG:-C.UTF-8}"
    echo "LC_ALL=${LC_ALL:-C.UTF-8}"
    echo "PIP_NO_CACHE_DIR=1"
    echo "PYTHONUNBUFFERED=1"
    echo "NODE_ENV=${NODE_ENV:-production}"
    echo "RAILS_ENV=${RAILS_ENV:-production}"
  } > "$ENV_FILE"
  chmod 0644 "$ENV_FILE" || true
  log "Default container environment written to $ENV_FILE"
}

set_permissions() {
  # If APP_UID/GID envs provided, adjust ownership
  if [ -n "${DEFAULT_USER_UID:-}" ] && [ -n "${DEFAULT_USER_GID:-}" ]; then
    log "Adjusting ownership of project directory to UID:GID ${DEFAULT_USER_UID}:${DEFAULT_USER_GID}"
    chown -R "${DEFAULT_USER_UID}:${DEFAULT_USER_GID}" "$PROJECT_DIR" || warn "Failed to chown project directory"
  fi
}

# Per-language setup steps
setup_python() {
  ensure_python
  local venv_dir="$PROJECT_DIR/.venv"
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
    log "Created Python virtual environment at $venv_dir"
  else
    log "Python virtual environment already exists at $venv_dir"
  fi
  # Activate venv
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel
  if [ -f "$PROJECT_DIR/requirements.txt" ]; then
    python3 -m pip install -r "$PROJECT_DIR/requirements.txt"
  elif [ -f "$PROJECT_DIR/pyproject.toml" ]; then
    # Prefer pip via pyproject (PEP 517); if poetry detected, use it
    if [ -f "$PROJECT_DIR/poetry.lock" ] || grep -qi '\[tool.poetry\]' "$PROJECT_DIR/pyproject.toml"; then
      python3 -m pip install "poetry>=1.6"
      poetry install --no-root --no-interaction --no-ansi
    else
      python3 -m pip install .
    fi
  elif [ -f "$PROJECT_DIR/Pipfile" ]; then
    python3 -m pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
  fi
  deactivate || true
  log "Python dependencies installed."
}

setup_node() {
  ensure_node
  if [ -f "$PROJECT_DIR/package.json" ]; then
    pushd "$PROJECT_DIR" >/dev/null
    if [ -f "package-lock.json" ] || [ -f "npm-shrinkwrap.json" ]; then
      npm ci --omit=dev || npm ci || npm install
    else
      npm install --omit=dev || npm install
    fi
    popd >/dev/null
    log "Node.js dependencies installed."
  fi
}

setup_ruby() {
  ensure_ruby
  if [ -f "$PROJECT_DIR/Gemfile" ]; then
    pushd "$PROJECT_DIR" >/dev/null
    if [ -f "Gemfile.lock" ]; then
      bundle config set deployment 'true'
      bundle config set without 'development test'
    fi
    bundle install --jobs "$(nproc)" || bundle install
    popd >/dev/null
    log "Ruby gems installed."
  fi
}

setup_go() {
  ensure_go
  if [ -f "$PROJECT_DIR/go.mod" ]; then
    pushd "$PROJECT_DIR" >/dev/null
    go mod download
    # Optional build if main exists
    if grep -qr 'package main' "$PROJECT_DIR"; then
      mkdir -p "$PROJECT_DIR/bin"
      go build -o "$PROJECT_DIR/bin/app" ./...
      log "Go project built: $PROJECT_DIR/bin/app"
    fi
    popd >/dev/null
    log "Go modules downloaded."
  fi
}

setup_java() {
  ensure_java
  if [ -f "$PROJECT_DIR/pom.xml" ]; then
    pushd "$PROJECT_DIR" >/dev/null
    mvn -q -DskipTests package || warn "Maven build failed"
    popd >/dev/null
    log "Maven dependencies resolved."
  elif [ -f "$PROJECT_DIR/build.gradle" ] || [ -f "$PROJECT_DIR/build.gradle.kts" ]; then
    pushd "$PROJECT_DIR" >/dev/null
    gradle build -x test || warn "Gradle build failed"
    popd >/dev/null
    log "Gradle dependencies resolved."
  fi
}

setup_php() {
  ensure_php
  if [ -f "$PROJECT_DIR/composer.json" ]; then
    pushd "$PROJECT_DIR" >/dev/null
    if [ -f "composer.lock" ]; then
      composer install --no-dev --prefer-dist --no-interaction
    else
      composer install --prefer-dist --no-interaction
    fi
    popd >/dev/null
    log "PHP dependencies installed via Composer."
  fi
}

setup_rust() {
  ensure_rust
  if [ -f "$PROJECT_DIR/Cargo.toml" ]; then
    pushd "$PROJECT_DIR" >/dev/null
    cargo fetch
    # Optional build for binaries
    if grep -qr '\[bin\]' "$PROJECT_DIR/Cargo.toml"; then
      cargo build --release || warn "Rust build failed"
    fi
    popd >/dev/null
    log "Rust dependencies fetched."
  fi
}

record_versions() {
  local vf="$STATE_DIR/versions.txt"
  {
    echo "Setup time: $(date +'%Y-%m-%d %H:%M:%S')"
    command -v python3 >/dev/null && echo "Python: $(python3 --version)"
    command -v pip >/dev/null && echo "pip: $(pip --version)"
    command -v node >/dev/null && echo "Node: $(node -v)"
    command -v npm >/dev/null && echo "npm: $(npm -v)"
    command -v ruby >/dev/null && echo "Ruby: $(ruby --version)"
    command -v bundle >/dev/null && echo "Bundler: $(bundle --version)"
    command -v go >/dev/null && echo "Go: $(go version)"
    command -v javac >/dev/null && echo "Java: $(javac -version 2>&1)"
    command -v mvn >/dev/null && echo "Maven: $(mvn -v | head -n1)"
    command -v gradle >/dev/null && echo "Gradle: $(gradle -v | head -n1)"
    command -v php >/dev/null && echo "PHP: $(php -v | head -n1)"
    command -v composer >/dev/null && echo "Composer: $(composer -V)"
    command -v rustc >/dev/null && echo "Rust: $(rustc --version)"
    command -v cargo >/dev/null && echo "Cargo: $(cargo --version)"
  } > "$vf"
  chmod 0644 "$vf" || true
  log "Recorded tool versions at $vf"
}

print_usage_hints() {
  log "Environment setup completed successfully."
  log "Detected project types:"
  is_python_project && echo " - Python"
  is_node_project && echo " - Node.js"
  is_ruby_project && echo " - Ruby"
  is_go_project && echo " - Go"
  is_java_project && echo " - Java"
  is_php_project && echo " - PHP"
  is_rust_project && echo " - Rust"

  echo "Common run hints (adjust to your project):"
  if is_python_project; then
    echo " - Python: source .venv/bin/activate && python3 app.py (or use your framework's run command)"
  fi
  if is_node_project; then
    echo " - Node.js: npm start (ensure PORT is set if needed)"
  fi
  if is_ruby_project; then
    echo " - Ruby: bundle exec rails server -e production (Rails) or rackup -E production"
  fi
  if is_go_project; then
    echo " - Go: ./bin/app (if built) or go run ./cmd/<main>"
  fi
  if is_java_project; then
    echo " - Java: java -jar target/*.jar (Maven) or use Gradle run task"
  fi
  if is_php_project; then
    echo " - PHP: php -S 0.0.0.0:\$PORT -t public (for simple apps)"
  fi
  if is_rust_project; then
    echo " - Rust: cargo run --release"
  fi
  echo " - Environment file: $ENV_FILE (override variables as needed)"
}

main() {
  require_root
  in_container && log "Running inside a container" || warn "Not detected as container; proceeding anyway."
  detect_os_pm
  install_common_packages
  setup_project_dir
  configure_timezone
  load_env_file
  write_env_defaults

  # Set LANG/LC_ALL to avoid locale issues
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"

  # Execute setup per detected project type
  if is_python_project; then setup_python; fi
  if is_node_project; then setup_node; fi
  if is_ruby_project; then setup_ruby; fi
  if is_go_project; then setup_go; fi
  if is_java_project; then setup_java; fi
  if is_php_project; then setup_php; fi
  if is_rust_project; then setup_rust; fi

  set_permissions
  record_versions
  print_usage_hints
}

main "$@"