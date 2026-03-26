#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Installs runtimes, system packages, and project dependencies based on detected stack.
# Safe to run multiple times (idempotent) and avoids sudo (assumes container context).

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------
# Logging and error handling
# -----------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

trap 'err "Setup failed on line $LINENO. See logs above."' ERR

# -----------------------------
# Helpers
# -----------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

as_root() {
  # Run command expecting root privileges. In containers, usually running as root already.
  if [ "$(id -u)" -ne 0 ]; then
    die "This setup script must be run as root inside the container. Current UID=$(id -u)."
  fi
  "$@"
}

# -----------------------------
# Detect package manager / OS
# -----------------------------
PKG_MGR=""
UPDATED=0
install_base_build_tools_done=0

detect_pkg_mgr() {
  if command_exists apt-get; then
    PKG_MGR="apt"
  elif command_exists apk; then
    PKG_MGR="apk"
  elif command_exists dnf; then
    PKG_MGR="dnf"
  elif command_exists yum; then
    PKG_MGR="yum"
  elif command_exists zypper; then
    PKG_MGR="zypper"
  else
    die "Unsupported base image: no known package manager (apt, apk, dnf, yum, zypper) found."
  fi
}

pkg_update() {
  if [ "$UPDATED" -eq 1 ]; then return 0; fi
  case "$PKG_MGR" in
    apt) as_root apt-get update -y ;;
    apk) : ;; # apk uses --no-cache and doesn't require update
    dnf) as_root dnf makecache -y ;;
    yum) as_root yum makecache -y || true ;;
    zypper) as_root zypper refresh -y ;;
  esac
  UPDATED=1
}

pkg_install() {
  case "$PKG_MGR" in
    apt) DEBIAN_FRONTEND=noninteractive as_root apt-get install -y --no-install-recommends "$@" ;;
    apk) as_root apk add --no-cache "$@" ;;
    dnf) as_root dnf install -y "$@" ;;
    yum) as_root yum install -y "$@" ;;
    zypper) as_root zypper install -y "$@" ;;
  esac
}

pkg_clean() {
  case "$PKG_MGR" in
    apt)
      as_root apt-get clean
      as_root rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* || true
      ;;
    apk) : ;; # --no-cache already avoids cache
    dnf|yum)
      as_root "$PKG_MGR" clean all -y || true
      as_root rm -rf /var/cache/"$PKG_MGR"/* || true
      ;;
    zypper)
      as_root zypper clean -a || true
      ;;
  esac
}

install_base_tools() {
  if [ "$install_base_build_tools_done" -eq 1 ]; then return 0; fi
  log "Installing base system tools and build essentials..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git gnupg unzip xz-utils tar \
                  build-essential pkg-config openssl
      ;;
    apk)
      pkg_install ca-certificates curl git gnupg unzip xz tar \
                  build-base pkgconf openssl-dev bash
      ;;
    dnf|yum)
      # Some images split ca-certificates/openssl differently
      pkg_install ca-certificates curl git gnupg2 unzip xz tar \
                  gcc gcc-c++ make pkgconf-pkg-config openssl openssl-devel
      ;;
    zypper)
      pkg_install ca-certificates curl git gpg2 unzip xz tar \
                  gcc gcc-c++ make pkg-config libopenssl-devel
      ;;
  esac
  install_base_build_tools_done=1
}

# -----------------------------
# Directories and permissions
# -----------------------------
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
APP_USER="${APP_USER:-appuser}"
RUN_AS_UID="${RUN_AS_UID:-}"
RUN_AS_GID="${RUN_AS_GID:-}"

prepare_directories() {
  log "Preparing project directory structure in: $PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"/{.cache,.local/bin,logs,tmp}
  # Common dependency dirs will be created by tools themselves; create placeholders for permissions
  mkdir -p "$PROJECT_DIR"/{node_modules,vendor}
  # Ensure write permissions for the current user
  if [ -n "$RUN_AS_UID" ] && [ -n "$RUN_AS_GID" ] && [ "$(id -u)" -eq 0 ]; then
    if ! getent group "$RUN_AS_GID" >/dev/null 2>&1; then
      addgroup_cmd="groupadd"
      command_exists addgroup && addgroup_cmd="addgroup"
      if [ "$addgroup_cmd" = "addgroup" ]; then
        as_root addgroup -g "$RUN_AS_GID" "$APP_USER" || true
      else
        as_root groupadd -g "$RUN_AS_GID" "$APP_USER" || true
      fi
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      adduser_cmd="useradd"
      command_exists adduser && adduser_cmd="adduser"
      if [ "$adduser_cmd" = "adduser" ]; then
        as_root adduser -D -u "$RUN_AS_UID" -G "$RUN_AS_GID" "$APP_USER" || true
      else
        as_root useradd -m -u "$RUN_AS_UID" -g "$RUN_AS_GID" -s /bin/bash "$APP_USER" || true
      fi
    fi
    as_root chown -R "$RUN_AS_UID":"$RUN_AS_GID" "$PROJECT_DIR"
  fi
}

# -----------------------------
# Environment variables defaults
# -----------------------------
export APP_ENV="${APP_ENV:-production}"
export NODE_ENV="${NODE_ENV:-$APP_ENV}"

# Python settings to be friendly in containers
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export DEBIAN_FRONTEND=noninteractive

# Extend PATH for local installs
export PATH="$PROJECT_DIR/.local/bin:$PROJECT_DIR/.venv/bin:$PATH"

# -----------------------------
# Language setup functions
# -----------------------------

setup_python() {
  if [ ! -f "$PROJECT_DIR/requirements.txt" ] \
     && [ ! -f "$PROJECT_DIR/pyproject.toml" ] \
     && [ ! -f "$PROJECT_DIR/setup.py" ] \
     && [ ! -f "$PROJECT_DIR/Pipfile" ] \
     && [ ! -f "$PROJECT_DIR/environment.yml" ]; then
    return 0
  fi
  log "Detected Python project. Installing Python runtime and dependencies..."
  pkg_update
  case "$PKG_MGR" in
    apt) pkg_install python3 python3-venv python3-pip python3-dev ;;
    apk) pkg_install python3 py3-pip python3-dev ;;
    dnf|yum) pkg_install python3 python3-pip python3-devel ;;
    zypper) pkg_install python3 python3-pip python3-devel ;;
  esac

  # Create venv if not exists
  if [ ! -f "$PROJECT_DIR/.venv/bin/activate" ]; then
    log "Creating Python virtual environment at .venv"
    python3 -m venv "$PROJECT_DIR/.venv"
  else
    log "Python virtual environment already exists at .venv"
  fi

  # Activate venv for this shell (safe, idempotent)
  # shellcheck disable=SC1090
  . "$PROJECT_DIR/.venv/bin/activate"

  pip install --upgrade pip wheel setuptools

  if [ -f "$PROJECT_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "$PROJECT_DIR/requirements.txt"
  elif [ -f "$PROJECT_DIR/pyproject.toml" ]; then
    if grep -qE '^\s*\[tool\.poetry\]' "$PROJECT_DIR/pyproject.toml" 2>/dev/null; then
      log "Poetry project detected. Installing poetry and dependencies."
      python3 -m pip install --user poetry
      export PATH="$PROJECT_DIR/.local/bin:$PATH"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi
    else
      log "PEP 517/518 project detected. Installing via pip (build backend)."
      pip install .
    fi
  elif [ -f "$PROJECT_DIR/Pipfile" ]; then
    log "Pipfile detected. Installing pipenv and dependencies."
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  elif [ -f "$PROJECT_DIR/environment.yml" ]; then
    warn "environment.yml detected (Conda). Conda not installed by this script. Please use a conda-based image."
  fi

  # Common framework env defaults
  if [ -f "$PROJECT_DIR/manage.py" ]; then
    export PORT="${PORT:-8000}"
  elif [ -f "$PROJECT_DIR/app.py" ] || [ -f "$PROJECT_DIR/wsgi.py" ] || [ -f "$PROJECT_DIR/asgi.py" ]; then
    export PORT="${PORT:-5000}"
  else
    export PORT="${PORT:-8000}"
  fi
}

setup_node() {
  if [ ! -f "$PROJECT_DIR/package.json" ]; then
    return 0
  fi
  log "Detected Node.js project. Installing Node.js runtime and dependencies..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      # Try distro NodeJS first
      if ! command_exists node; then
        pkg_install nodejs npm || true
      fi
      # If node still not available or too old, try Nodesource LTS
      if ! command_exists node || ! node -v >/dev/null 2>&1; then
        log "Installing Node.js LTS from NodeSource repository..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        pkg_install nodejs
      fi
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm || true
      if ! command_exists node; then
        warn "Node.js not available via package manager. Consider using a Node base image."
      fi
      ;;
    zypper)
      pkg_install nodejs npm || true
      ;;
  esac

  # Enable corepack if available to manage Yarn/PNPM
  if command_exists corepack; then
    corepack enable || true
  fi

  # Use yarn if yarn.lock present
  if [ -f "$PROJECT_DIR/yarn.lock" ]; then
    if ! command_exists yarn; then
      if command_exists corepack; then
        corepack prepare yarn@stable --activate || true
      fi
      if ! command_exists yarn; then
        npm install -g yarn
      fi
    fi
    log "Installing Node dependencies with yarn"
    yarn install --frozen-lockfile || yarn install
  elif [ -f "$PROJECT_DIR/pnpm-lock.yaml" ]; then
    if ! command_exists pnpm; then
      if command_exists corepack; then
        corepack prepare pnpm@latest --activate || true
      fi
      if ! command_exists pnpm; then
        npm install -g pnpm
      fi
    fi
    log "Installing Node dependencies with pnpm"
    pnpm install --frozen-lockfile || pnpm install
  else
    # Default to npm
    if [ -f "$PROJECT_DIR/package-lock.json" ]; then
      log "Installing Node dependencies with npm ci"
      npm ci || npm install
    else
      log "Installing Node dependencies with npm install"
      npm install
    fi
  fi

  # Default Node port
  export PORT="${PORT:-3000}"
}

setup_ruby() {
  if [ ! -f "$PROJECT_DIR/Gemfile" ]; then
    return 0
  fi
  log "Detected Ruby project. Installing Ruby and bundler..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full
      ;;
    apk)
      pkg_install ruby ruby-dev
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel
      ;;
    zypper)
      pkg_install ruby ruby-devel
      ;;
  esac

  # Ensure build tools for native gems
  install_base_tools

  # Use local gem path within project to avoid system gem writes
  export GEM_HOME="$PROJECT_DIR/.gem"
  export GEM_PATH="$GEM_HOME"
  export PATH="$GEM_HOME/bin:$PATH"

  gem install --no-document bundler || gem install bundler -N
  log "Installing Ruby gems via bundler"
  bundle config set --local path "$PROJECT_DIR/vendor/bundle"
  bundle install --jobs 4 --retry 3

  export PORT="${PORT:-3000}"
}

setup_go() {
  if [ ! -f "$PROJECT_DIR/go.mod" ]; then
    return 0
  fi
  log "Detected Go project. Installing Go toolchain..."
  pkg_update
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac
  log "Downloading Go module dependencies"
  (cd "$PROJECT_DIR" && go mod download)
  export GOPATH="${GOPATH:-$PROJECT_DIR/.gopath}"
  export GOCACHE="${GOCACHE:-$PROJECT_DIR/.cache/go-build}"
  export PATH="$GOPATH/bin:$PATH"
  export PORT="${PORT:-8080}"
}

setup_rust() {
  if [ ! -f "$PROJECT_DIR/Cargo.toml" ]; then
    return 0
  fi
  log "Detected Rust project. Installing cargo toolchain..."
  pkg_update
  case "$PKG_MGR" in
    apt) pkg_install cargo ;;
    apk) pkg_install cargo ;;
    dnf|yum) pkg_install cargo ;;
    zypper) pkg_install cargo ;;
  esac
  log "Fetching Rust crate dependencies"
  (cd "$PROJECT_DIR" && cargo fetch)
  export CARGO_HOME="${CARGO_HOME:-$PROJECT_DIR/.cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-$PROJECT_DIR/.rustup}"
  export PORT="${PORT:-8080}"
}

setup_java() {
  if [ ! -f "$PROJECT_DIR/pom.xml" ] && [ ! -f "$PROJECT_DIR/build.gradle" ] && [ ! -f "$PROJECT_DIR/settings.gradle" ] && [ ! -f "$PROJECT_DIR/gradlew" ]; then
    return 0
  fi
  log "Detected Java project. Installing JDK and build tools..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install default-jdk maven
      # gradle often via wrapper; install only if no wrapper
      [ -f "$PROJECT_DIR/gradlew" ] || pkg_install gradle || true
      ;;
    apk)
      pkg_install openjdk17-jdk maven
      [ -f "$PROJECT_DIR/gradlew" ] || pkg_install gradle || true
      ;;
    dnf|yum)
      pkg_install java-17-openjdk-devel maven
      [ -f "$PROJECT_DIR/gradlew" ] || pkg_install gradle || true
      ;;
    zypper)
      pkg_install java-17-openjdk-devel maven
      [ -f "$PROJECT_DIR/gradlew" ] || pkg_install gradle || true
      ;;
  esac

  if [ -f "$PROJECT_DIR/pom.xml" ]; then
    log "Pre-fetching Maven dependencies (offline cache)"
    (cd "$PROJECT_DIR" && mvn -B -ntp -DskipTests dependency:go-offline)
  fi
  if [ -f "$PROJECT_DIR/gradlew" ]; then
    log "Using Gradle wrapper to pre-download dependencies"
    (cd "$PROJECT_DIR" && chmod +x gradlew && ./gradlew --no-daemon dependencies || true)
  fi
  export PORT="${PORT:-8080}"
}

setup_php() {
  if [ ! -f "$PROJECT_DIR/composer.json" ]; then
    return 0
  fi
  log "Detected PHP project. Installing PHP and Composer..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-zip php-curl php-mbstring php-xml unzip
      # Composer is available via apt on many distros, otherwise install via installer
      if ! command_exists composer; then
        log "Installing Composer from official installer..."
        EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
        curl -fsSL https://getcomposer.org/installer -o composer-setup.php
        ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
        if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
          rm -f composer-setup.php
          die "Invalid composer installer signature"
        fi
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
      fi
      ;;
    apk)
      pkg_install php81 php81-cli php81-phar php81-openssl php81-tokenizer php81-dom php81-xmlwriter php81-simplexml php81-mbstring php81-curl php81-zip composer
      ;;
    dnf|yum)
      pkg_install php-cli php-json php-mbstring php-xml php-zip composer || true
      if ! command_exists composer; then
        warn "Composer not available via package manager; installing via installer."
        curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
      fi
      ;;
    zypper)
      pkg_install php8 php8-cli php8-mbstring php8-xml php8-zip composer || true
      ;;
  esac

  log "Installing PHP dependencies via Composer"
  cd "$PROJECT_DIR"
  if [ "${APP_ENV:-production}" = "production" ]; then
    composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader
  else
    composer install --prefer-dist --no-interaction
  fi
  export PORT="${PORT:-8080}"
}

setup_dotnet() {
  # We avoid automatic installation of dotnet SDK due to complexity; recommend base image.
  if ls "$PROJECT_DIR"/*.csproj >/dev/null 2>&1 || ls "$PROJECT_DIR"/*.sln >/dev/null 2>&1; then
    warn ".NET project detected. Installing .NET SDK is not handled by this script due to distro-specific repos."
    warn "Use a base image like mcr.microsoft.com/dotnet/sdk:8.0 and run: dotnet restore"
  fi
}

# -----------------------------
# Environment .env handling
# -----------------------------
setup_env_file() {
  ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
  if [ ! -f "$ENV_FILE" ]; then
    log "Creating environment file at $ENV_FILE"
    {
      echo "APP_ENV=${APP_ENV}"
      echo "NODE_ENV=${NODE_ENV}"
      echo "PORT=${PORT:-8080}"
      # Language-specific placeholders
      if [ -f "$PROJECT_DIR/manage.py" ]; then
        echo "DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE:-project.settings}"
        echo "PYTHONPATH=${PYTHONPATH:-$PROJECT_DIR}"
      fi
      if [ -f "$PROJECT_DIR/app.py" ]; then
        echo "FLASK_APP=${FLASK_APP:-app.py}"
        echo "FLASK_ENV=${FLASK_ENV:-${APP_ENV}}"
        echo "FLASK_RUN_PORT=${FLASK_RUN_PORT:-${PORT:-5000}}"
      fi
    } > "$ENV_FILE"
  else
    log "Environment file $ENV_FILE already exists; leaving as-is."
  fi
}

# -----------------------------
# Port heuristic (fallback)
# -----------------------------
set_default_port_if_missing() {
  if [ -n "${PORT:-}" ]; then return 0; fi
  if [ -f "$PROJECT_DIR/package.json" ]; then
    export PORT="${PORT:-3000}"
  elif [ -f "$PROJECT_DIR/manage.py" ]; then
    export PORT="${PORT:-8000}"
  elif [ -f "$PROJECT_DIR/app.py" ] || [ -f "$PROJECT_DIR/wsgi.py" ] || [ -f "$PROJECT_DIR/asgi.py" ]; then
    export PORT="${PORT:-5000}"
  elif [ -f "$PROJECT_DIR/go.mod" ] || [ -f "$PROJECT_DIR/Cargo.toml" ] || [ -f "$PROJECT_DIR/pom.xml" ] || [ -f "$PROJECT_DIR/build.gradle" ]; then
    export PORT="${PORT:-8080}"
  else
    export PORT="${PORT:-8080}"
  fi
}

# -----------------------------
# Summary
# -----------------------------
ensure_venv_auto_activation() {
  local bashrc_file="${HOME}/.bashrc"
  # Append a snippet that auto-activates a local .venv when starting an interactive shell
  if [ -d "$PROJECT_DIR/.venv" ] && [ -f "$PROJECT_DIR/.venv/bin/activate" ]; then
    if ! grep -qF ".venv/bin/activate" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate local Python venv when entering shell" >> "$bashrc_file"
      echo "if [ -f \"\$PWD/.venv/bin/activate\" ]; then . \"\$PWD/.venv/bin/activate\"; fi" >> "$bashrc_file"
    fi
  fi
}

print_summary() {
  log "Environment setup completed."
  echo "Summary:"
  echo "- Base tools installed via: $PKG_MGR"
  echo "- Project directory: $PROJECT_DIR"
  echo "- Environment: APP_ENV=${APP_ENV}, NODE_ENV=${NODE_ENV}"
  echo "- Default PORT=${PORT}"
  echo "- .env file: ${ENV_FILE:-$PROJECT_DIR/.env}"
  echo
  echo "Next steps (typical commands):"
  if [ -d "$PROJECT_DIR/.venv" ]; then
    echo "Python: source .venv/bin/activate && (e.g., python app.py or gunicorn wsgi:app)"
  fi
  if [ -f "$PROJECT_DIR/package.json" ]; then
    echo "Node: npm run start (or yarn start / pnpm start)"
  fi
  if [ -f "$PROJECT_DIR/Gemfile" ]; then
    echo "Ruby: bundle exec rails s -p ${PORT} -b 0.0.0.0 (or rackup)"
  fi
  if [ -f "$PROJECT_DIR/go.mod" ]; then
    echo "Go: go run . (or go build)"
  fi
  if [ -f "$PROJECT_DIR/Cargo.toml" ]; then
    echo "Rust: cargo run --release"
  fi
  if [ -f "$PROJECT_DIR/pom.xml" ] || [ -f "$PROJECT_DIR/build.gradle" ] || [ -f "$PROJECT_DIR/gradlew" ]; then
    echo "Java: mvn spring-boot:run or ./gradlew bootRun (if applicable)"
  fi
  if [ -f "$PROJECT_DIR/composer.json" ]; then
    echo "PHP: php -S 0.0.0.0:${PORT} -t public (adjust as needed)"
  fi
  if ls "$PROJECT_DIR"/*.csproj >/dev/null 2>&1 || ls "$PROJECT_DIR"/*.sln >/dev/null 2>&1; then
    echo ".NET: dotnet restore && dotnet run (use a dotnet SDK base image)"
  fi
}

# -----------------------------
# Main
# -----------------------------
main() {
  detect_pkg_mgr
  install_base_tools
  prepare_directories

  # Stack detection and setup
  setup_python
  setup_node
  setup_ruby
  setup_go
  setup_rust
  setup_java
  setup_php
  setup_dotnet

  set_default_port_if_missing
  setup_env_file
  ensure_venv_auto_activation

  # Clean caches to keep image lean
  pkg_clean

  print_summary
}

main "$@"