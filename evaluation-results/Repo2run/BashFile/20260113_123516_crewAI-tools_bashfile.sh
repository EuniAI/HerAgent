#!/usr/bin/env bash
# Environment setup script for containerized projects
# This script detects the project type and installs appropriate runtimes,
# system dependencies, and project dependencies. It is idempotent and safe
# to run multiple times in a Docker container.

set -Eeuo pipefail

# Safer IFS
IFS=$'\n\t'

# Colors (fallback to no color if not a tty)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  NC='\033[0m'
else
  GREEN=''
  YELLOW=''
  RED=''
  NC=''
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

# Error trap for better diagnostics
on_error() {
  err "An error occurred on line ${BASH_LINENO[0]} while executing: ${BASH_COMMAND}"
  exit 1
}
trap on_error ERR

# Defaults and global vars
APP_DIR="${APP_DIR:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
CREATE_APP_USER="${CREATE_APP_USER:-1}"
DEBIAN_FRONTEND=noninteractive
UMASK_VAL="${UMASK_VAL:-0022}"

# Detect package manager and OS family
PM=""
OS_FAMILY=""
detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
    OS_FAMILY="debian"
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    OS_FAMILY="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    OS_FAMILY="rhel"
  elif command -v zypper >/dev/null 2>&1; then
    PM="zypper"
    OS_FAMILY="suse"
  else
    PM=""
  fi
}

pkg_update() {
  case "$PM" in
    apt)
      apt-get update -y
      ;;
    apk)
      # apk uses no update command separate; update via add --update or do a fetch
      true
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache
      ;;
    zypper)
      zypper refresh
      ;;
    *)
      warn "No supported package manager detected."
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  case "$PM" in
    apt)
      apt-get install -y --no-install-recommends "$@" ;;
    apk)
      apk add --no-cache "$@" ;;
    dnf)
      dnf install -y "$@" ;;
    yum)
      yum install -y "$@" ;;
    zypper)
      zypper --non-interactive install -y "$@" ;;
    *)
      warn "Cannot install packages: no supported package manager."
      return 1 ;;
  esac
}

ensure_base_packages() {
  log "Installing base system packages..."
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root; skipping system package installation."
    return 0
  fi

  detect_pm
  if [ -z "$PM" ]; then
    warn "No supported package manager detected; cannot install system dependencies."
    return 0
  fi

  pkg_update

  case "$PM" in
    apt)
      pkg_install ca-certificates curl git gnupg tzdata xz-utils unzip \
        build-essential pkg-config make openssl libssl-dev libffi-dev
      ;;
    apk)
      pkg_install ca-certificates curl git tzdata xz unzip \
        build-base bash pkgconfig openssl-dev libffi-dev
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gnupg2 tzdata xz unzip \
        make gcc gcc-c++ openssl-devel libffi-devel which
      ;;
    zypper)
      pkg_install ca-certificates curl git gpg2 timezone xz unzip \
        gcc gcc-c++ make pkgconfig libopenssl-devel libffi-devel which
      ;;
  esac

  update-ca-certificates >/dev/null 2>&1 || true
}

# Create application user/group for better security
ensure_app_user() {
  if [ "$CREATE_APP_USER" != "1" ]; then
    log "Skipping creation of dedicated app user (CREATE_APP_USER=$CREATE_APP_USER)."
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    warn "Cannot create user/group without root privileges."
    return 0
  fi

  if getent group "$APP_GROUP" >/dev/null 2>&1; then
    :
  else
    if command -v addgroup >/dev/null 2>&1; then
      addgroup -S "$APP_GROUP" || true
    elif command -v groupadd >/dev/null 2>&1; then
      groupadd -r "$APP_GROUP" || true
    fi
  fi

  if id -u "$APP_USER" >/dev/null 2>&1; then
    :
  else
    if command -v adduser >/dev/null 2>&1; then
      adduser -S -G "$APP_GROUP" -H -D "$APP_USER" || true
    elif command -v useradd >/dev/null 2>&1; then
      useradd -r -g "$APP_GROUP" -d "$APP_DIR" -s /usr/sbin/nologin "$APP_USER" || true
    fi
  fi
}

# Project structure
setup_directories() {
  log "Setting up project directories at $APP_DIR..."
  mkdir -p "$APP_DIR"
  mkdir -p "$APP_DIR"/{logs,tmp,run,storage}
  # Node/Python common caches (do not fail if not used)
  mkdir -p "$APP_DIR"/.cache
  mkdir -p "$APP_DIR"/.npm
  mkdir -p "$APP_DIR"/.yarn
  mkdir -p "$APP_DIR"/.pip
  umask "$UMASK_VAL" || true

  if [ "$(id -u)" -eq 0 ]; then
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" 2>/dev/null || true
  fi
}

# Env configuration persisted for shells
persist_env() {
  log "Configuring environment variables..."
  mkdir -p /etc/profile.d 2>/dev/null || true

  {
    echo "# Auto-generated app environment"
    echo "export APP_DIR=\"$APP_DIR\""
    echo "export APP_ENV=\"${APP_ENV}\""
    echo "export PATH=\"${APP_DIR}/bin:\$PATH\""
    echo "export PIP_NO_CACHE_DIR=\"1\""
    echo "export PYTHONDONTWRITEBYTECODE=\"1\""
    echo "export PYTHONUNBUFFERED=\"1\""
  } > /etc/profile.d/app_env.sh 2>/dev/null || true

  # .env file in project directory if not present
  if [ ! -f "$APP_DIR/.env" ]; then
    {
      echo "APP_ENV=${APP_ENV}"
      echo "PORT=${PORT:-}"
    } > "$APP_DIR/.env"
  fi
}

# Project detection
PROJECT_TYPE=""
detect_project_type() {
  # Determine by sentinel files
  if [ -f "$APP_DIR/package.json" ]; then
    PROJECT_TYPE="node"
  elif [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ] || compgen -G "$APP_DIR/*.py" >/dev/null 2>&1; then
    PROJECT_TYPE="python"
  elif [ -f "$APP_DIR/Gemfile" ]; then
    PROJECT_TYPE="ruby"
  elif [ -f "$APP_DIR/composer.json" ]; then
    PROJECT_TYPE="php"
  elif [ -f "$APP_DIR/go.mod" ]; then
    PROJECT_TYPE="go"
  elif [ -f "$APP_DIR/Cargo.toml" ]; then
    PROJECT_TYPE="rust"
  elif [ -f "$APP_DIR/mvnw" ] || [ -f "$APP_DIR/pom.xml" ] || [ -f "$APP_DIR/gradlew" ]; then
    PROJECT_TYPE="java"
  elif compgen -G "$APP_DIR/*.csproj" >/dev/null 2>&1; then
    PROJECT_TYPE=".net"
  else
    PROJECT_TYPE="unknown"
  fi
  log "Detected project type: ${PROJECT_TYPE}"
}

# Language-specific installers
install_node() {
  log "Installing Node.js runtime and dependencies..."
  if command -v node >/dev/null 2>&1; then
    log "Node.js already installed: $(node -v)"
  else
    detect_pm
    case "$PM" in
      apt)
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        pkg_install nodejs
        ;;
      apk)
        pkg_install nodejs npm
        ;;
      dnf|yum)
        # Try to install nodejs LTS from modules/repos; fallback to default
        if command -v dnf >/dev/null 2>&1; then
          dnf module -y enable nodejs:18 || true
        fi
        pkg_install nodejs npm || pkg_install nodejs
        ;;
      zypper)
        pkg_install nodejs npm || pkg_install nodejs16 npm16 || true
        ;;
      *)
        warn "No supported package manager; Node.js install skipped."
        ;;
    esac
  fi

  # Package manager configs
  export NODE_ENV="${NODE_ENV:-$([ "$APP_ENV" = "production" ] && echo production || echo development)}"
  if [ -f "$APP_DIR/pnpm-lock.yaml" ]; then
    if ! command -v pnpm >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then
        corepack enable || true
        corepack prepare pnpm@latest --activate || true
      else
        npm install -g pnpm
      fi
    fi
    cd "$APP_DIR"
    pnpm install --frozen-lockfile
  elif [ -f "$APP_DIR/yarn.lock" ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then
        corepack enable || true
        corepack prepare yarn@stable --activate || true
      else
        npm install -g yarn
      fi
    end_if=true
    cd "$APP_DIR"
    if [ "$APP_ENV" = "production" ]; then
      yarn install --frozen-lockfile --production=true
    else
      yarn install --frozen-lockfile
    fi
  else
    cd "$APP_DIR"
    if [ -f package-lock.json ]; then
      npm ci $([ "$APP_ENV" = "production" ] && echo "--omit=dev" || true)
    else
      npm install $([ "$APP_ENV" = "production" ] && echo "--omit=dev" || true)
    fi
  fi
}

install_python() {
  log "Installing Python runtime and dependencies..."
  detect_pm
  case "$PM" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev gcc build-essential libffi-dev libssl-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev build-base libffi-dev openssl-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ openssl-devel libffi-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ libopenssl-devel libffi-devel
      ;;
    *)
      warn "No supported package manager; Python install skipped."
      ;;
  esac

  # Use .venv inside project
  cd "$APP_DIR"
  PY_BIN="python3"
  if [ ! -d ".venv" ]; then
    "$PY_BIN" -m venv .venv
  fi
  # shellcheck disable=SC1091
  source .venv/bin/activate
  pip install --no-cache-dir --upgrade pip setuptools wheel
  if [ -f "requirements.txt" ]; then
    pip install --no-cache-dir -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    # Try PEP 517 build or direct install
    pip install --no-cache-dir .
  fi
}

install_ruby() {
  log "Installing Ruby and bundler..."
  detect_pm
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
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
  esac

  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler -N
  end_if=true
  cd "$APP_DIR"
  bundle config set --local path 'vendor/bundle'
  if [ -f "$APP_DIR/Gemfile.lock" ]; then
    bundle install --jobs=4 --retry=3
  else
    bundle install --jobs=4 --retry=3
  fi
}

install_php() {
  log "Installing PHP and Composer..."
  detect_pm
  case "$PM" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip php-intl unzip
      ;;
    apk)
      pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip php81-openssl php81-json php81-dom unzip || \
      pkg_install php php-cli php-mbstring php-xml php-curl php-zip php-openssl php-json php-dom unzip
      ;;
    dnf|yum)
      pkg_install php-cli php-mbstring php-xml php-json php-zip unzip
      ;;
    zypper)
      pkg_install php8 php8-cli php8-mbstring php8-xml php8-zip unzip || pkg_install php php-cli php-mbstring php-xml php-zip unzip
      ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f /tmp/composer-setup.php
      err "Invalid Composer installer signature."
      exit 1
    fi
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f /tmp/composer-setup.php
  fi
  cd "$APP_DIR"
  if [ -f composer.json ]; then
    if [ "$APP_ENV" = "production" ]; then
      composer install --no-dev --prefer-dist --no-interaction --no-progress
    else
      composer install --prefer-dist --no-interaction --no-progress
    fi
  fi
}

install_go() {
  log "Installing Go and fetching modules..."
  detect_pm
  case "$PM" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
    *)
      warn "No supported package manager for Go"; return 0 ;;
  esac
  cd "$APP_DIR"
  if [ -f go.mod ]; then
    go env -w GOMODCACHE="$APP_DIR/.cache/go" || true
    go mod download
  fi
  if [ -f main.go ]; then
    mkdir -p "$APP_DIR/bin"
    go build -o "$APP_DIR/bin/app"
  fi
}

install_rust() {
  log "Installing Rust via rustup..."
  if command -v cargo >/dev/null 2>&1; then
    log "Rust already installed: $(rustc --version)"
  else
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    # shellcheck disable=SC1090
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  cd "$APP_DIR"
  if [ -f Cargo.toml ]; then
    cargo fetch
    cargo build --release
  fi
}

install_java() {
  log "Installing Java (OpenJDK) and build tools..."
  detect_pm
  case "$PM" in
    apt)
      pkg_install openjdk-17-jdk maven
      ;;
    apk)
      pkg_install openjdk17 maven || pkg_install openjdk11 maven
      ;;
    dnf|yum)
      pkg_install java-17-openjdk java-17-openjdk-devel maven
      ;;
    zypper)
      pkg_install java-17-openjdk java-17-openjdk-devel maven
      ;;
  esac

  cd "$APP_DIR"
  if [ -x "./mvnw" ]; then
    ./mvnw -B -q -DskipTests dependency:resolve || true
  elif [ -f "pom.xml" ]; then
    mvn -B -q -DskipTests dependency:resolve || true
  fi

  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon --quiet build -x test || ./gradlew --no-daemon --quiet assemble -x test || true
  fi
}

install_dotnet() {
  # Optional: Minimal support; many bases lack Microsoft repos
  warn ".NET detected but automated installation is not fully supported generically."
  warn "Please use a .NET base image or extend this script to add Microsoft package repo."
}

# Port detection defaults
detect_port() {
  PORT="${PORT:-}"
  if [ -n "$PORT" ]; then
    echo "$PORT"
    return 0
  fi

  case "$PROJECT_TYPE" in
    node)
      # Common defaults: 3000/8080
      PORT="3000"
      ;;
    python)
      # Flask/Django common ports
      if ls "$APP_DIR" | grep -qi "django"; then
        PORT="8000"
      else
        PORT="5000"
      fi
      ;;
    php)
      PORT="8000"
      ;;
    go|rust|java)
      PORT="8080"
      ;;
    ruby)
      PORT="3000"
      ;;
    *)
      PORT="8080"
      ;;
  esac
  export PORT
}

# Entrypoint hints file
write_runtime_hints() {
  local hint="${APP_DIR}/.runtime_setup_info"
  {
    echo "Project type: $PROJECT_TYPE"
    echo "APP_ENV: $APP_ENV"
    echo "PORT: ${PORT:-unset}"
    echo "APP_DIR: $APP_DIR"
    echo "Timestamp: $(date -Is)"
  } > "$hint"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$APP_USER:$APP_GROUP" "$hint" 2>/dev/null || true
  fi
}

# Main flow
main() {
  log "Starting environment setup..."
  log "App directory: $APP_DIR"

  ensure_base_packages
  ensure_app_user
  setup_directories

  # If running outside APP_DIR, but files exist in CWD, move them if APP_DIR empty
  if [ "$PWD" != "$APP_DIR" ] && [ -z "$(ls -A "$APP_DIR")" ]; then
    warn "APP_DIR is empty; if you intend to copy project files here, mount or copy them into $APP_DIR."
  fi

  persist_env

  detect_project_type
  detect_port

  case "$PROJECT_TYPE" in
    node)
      install_node
      ;;
    python)
      install_python
      ;;
    ruby)
      install_ruby
      ;;
    php)
      install_php
      ;;
    go)
      install_go
      ;;
    rust)
      install_rust
      ;;
    java)
      install_java
      ;;
    .net)
      install_dotnet
      ;;
    *)
      warn "Could not detect project type. Skipping language-specific dependency installation."
      ;;
  esac

  # Set permissions at end to ensure newly created files owned properly
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" 2>/dev/null || true
  fi

  write_runtime_hints

  log "Environment setup completed successfully."
  log "Summary: Type=${PROJECT_TYPE}, APP_ENV=${APP_ENV}, PORT=${PORT}, DIR=${APP_DIR}"
  log "Note: This script is idempotent. Re-run safely to ensure environment consistency."
}

main "$@"