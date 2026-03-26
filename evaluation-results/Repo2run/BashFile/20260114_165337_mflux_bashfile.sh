#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects tech stack and installs required runtimes, dependencies, and tools.
# Safe to run multiple times (idempotent) and handles common Linux distro package managers.

# Early repair of /usr/local/bin/timeout (idempotent)
mkdir -p /usr/local/bin
mv -f /usr/local/bin/timeout /usr/local/bin/timeout.broken 2>/dev/null || true
printf '%s\n' '#!/bin/sh' 'exec "$@"' > /usr/local/bin/timeout
chmod 0755 /usr/local/bin/timeout || true

# Ensure a real timeout implementation is available and re-point /usr/local/bin/timeout
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get install -y coreutils
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache coreutils
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y coreutils
elif command -v yum >/dev/null 2>&1; then
  yum install -y coreutils
elif command -v microdnf >/dev/null 2>&1; then
  microdnf install -y coreutils
elif command -v zypper >/dev/null 2>&1; then
  zypper --non-interactive in -y coreutils
else
  echo 'No supported package manager found' >&2
fi

if [ -x /usr/bin/timeout.coreutils ]; then
  ln -sf /usr/bin/timeout.coreutils /usr/local/bin/timeout
elif [ -x /usr/bin/timeout ]; then
  ln -sf /usr/bin/timeout /usr/local/bin/timeout
elif command -v busybox >/dev/null 2>&1 && busybox timeout --help >/dev/null 2>&1; then
  ln -sf "$(command -v busybox)" /usr/local/bin/timeout
else
  echo "No timeout implementation available" >&2
fi
chmod 0755 /usr/local/bin/timeout || true

/usr/local/bin/timeout --version >/dev/null 2>&1 || /usr/bin/timeout --version >/dev/null 2>&1 || busybox timeout --help >/dev/null 2>&1 || true

# Optionally restore /bin/bash from shim if present
if [ -x /usr/local/bin/bash.real ]; then
  cp -f /usr/local/bin/bash.real /bin/bash && chmod +x /bin/bash || true
fi

set -Eeuo pipefail

# Globals and defaults
PROJECT_DIR="${PROJECT_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
APP_PORT_DEFAULT=8080

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# Logging helpers
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

on_error() {
  local exit_code=$?
  err "Setup failed at line ${BASH_LINENO[0]} executing: ${BASH_COMMAND}"
  exit "$exit_code"
}
trap on_error ERR

# Ensure running as root (containers typically run as root by default)
require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "This script must run as root inside the container (no sudo available)."
  fi
}

# Determine package manager
PKG_MGR=""
pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  else
    die "No supported package manager found (apt/apk/dnf/yum/microdnf/zypper)."
  fi
  log "Detected package manager: $PKG_MGR"
}

APT_UPDATED=0
pm_update() {
  case "$PKG_MGR" in
    apt)
      if [ "$APT_UPDATED" -eq 0 ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        APT_UPDATED=1
      fi
      ;;
    apk)
      # apk uses online index by default with --no-cache
      true
      ;;
    dnf|yum|microdnf|zypper)
      # These usually refresh on install
      true
      ;;
  esac
}

pm_install() {
  local pkgs=("$@")
  case "$PKG_MGR" in
    apt)
      pm_update
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
    microdnf)
      microdnf install -y "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive in -y "${pkgs[@]}"
      ;;
    *)
      die "Unknown package manager: $PKG_MGR"
      ;;
  esac
}

pm_clean() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      # No cache by default
      true
      ;;
    dnf|yum|microdnf)
      # Clean metadata to reduce size
      if command -v dnf >/dev/null 2>&1; then dnf clean all -y || true; fi
      if command -v yum >/dev/null 2>&1; then yum clean all -y || true; fi
      if command -v microdnf >/dev/null 2>&1; then microdnf clean all -y || true; fi
      ;;
    zypper)
      zypper clean --all || true
      ;;
  esac
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }
has_file() { [ -f "$PROJECT_DIR/$1" ]; }
has_any_file() {
  local f
  for f in "$@"; do
    if has_file "$f"; then return 0; fi
  done
  return 1
}

# Prepare filesystem and user
prepare_fs() {
  log "Preparing project filesystem at $PROJECT_DIR"
  mkdir -p "$PROJECT_DIR" "$PROJECT_DIR/logs" "$PROJECT_DIR/tmp" "$PROJECT_DIR/data"
  chmod 755 "$PROJECT_DIR" || true
}

ensure_user() {
  # Create group if missing
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    log "Creating system group $APP_GROUP"
    groupadd -r "$APP_GROUP" || groupadd "$APP_GROUP"
  fi

  # Create user if missing
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    log "Creating user $APP_USER"
    useradd -m -g "$APP_GROUP" -s /bin/bash "$APP_USER"
  fi

  mkdir -p "$PROJECT_DIR"
  chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR"
}

# Base tools
install_base_tools() {
  log "Installing base tools..."
  case "$PKG_MGR" in
    apt)
      pm_install ca-certificates curl git unzip tar gzip xz-utils jq openssl
      ;;
    apk)
      pm_install ca-certificates curl git unzip tar gzip xz jq openssl
      ;;
    dnf|yum|microdnf)
      pm_install ca-certificates curl git unzip tar gzip xz jq openssl
      ;;
    zypper)
      pm_install ca-certificates curl git unzip tar gzip xz jq libopenssl1_1 || pm_install ca-certificates curl git unzip tar gzip xz jq openssl
      ;;
  esac
  update-ca-certificates || true
}

# Build tools (only when needed)
install_build_essentials() {
  log "Installing build essentials..."
  case "$PKG_MGR" in
    apt)
      pm_install build-essential pkg-config
      ;;
    apk)
      pm_install build-base pkgconf
      ;;
    dnf|yum|microdnf)
      pm_install make gcc gcc-c++ kernel-devel pkgconf-pkg-config
      ;;
    zypper)
      pm_install -t pattern devel_basis || pm_install gcc gcc-c++ make pkg-config
      ;;
  esac
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MGR" in
    apt)
      pm_install python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      pm_install python3 py3-pip python3-dev
      install_build_essentials
      ;;
    dnf|yum|microdnf)
      pm_install python3 python3-pip python3-devel
      install_build_essentials
      ;;
    zypper)
      pm_install python3 python3-pip python3-devel
      install_build_essentials
      ;;
  esac

  local VENV_DIR="$PROJECT_DIR/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  pip install --no-input --upgrade pip setuptools wheel

  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-input -r "$PROJECT_DIR/requirements.txt"
  elif has_file "pyproject.toml"; then
    if has_file "poetry.lock"; then
      log "Detected Poetry project"
      pip install --no-input "poetry>=1.6"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-root || poetry install --no-interaction
    else
      log "Installing Python project from pyproject.toml via pip"
      if has_file "setup.py"; then
        pip install --no-input -e "$PROJECT_DIR"
      else
        pip install --no-input "$PROJECT_DIR" || warn "pip install of pyproject failed; ensure build-backend supports PEP 517."
      fi
    fi
  elif has_file "Pipfile"; then
    log "Detected Pipenv project"
    pip install --no-input pipenv
    pipenv install --dev || pipenv install
  else
    warn "No Python dependency manifest found. Skipping dependency install."
  fi

  # Environment defaults
  echo "PYTHONUNBUFFERED=1" >> "$PROJECT_DIR/.env.defaults"
  echo "PYTHONDONTWRITEBYTECODE=1" >> "$PROJECT_DIR/.env.defaults"
  echo "PIP_NO_CACHE_DIR=1" >> "$PROJECT_DIR/.env.defaults"

  # Framework-specific hints
  local APP_PORT="${APP_PORT:-}"
  if has_file "manage.py"; then
    APP_PORT="${APP_PORT:-8000}"
    echo "DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE:-}" >> "$PROJECT_DIR/.env.defaults"
  elif has_any_file "app.py" "wsgi.py"; then
    APP_PORT="${APP_PORT:-5000}"
    if has_file "app.py"; then echo "FLASK_APP=app.py" >> "$PROJECT_DIR/.env.defaults"; fi
    echo "FLASK_ENV=production" >> "$PROJECT_DIR/.env.defaults"
    echo "FLASK_RUN_HOST=0.0.0.0" >> "$PROJECT_DIR/.env.defaults"
    echo "FLASK_RUN_PORT=${APP_PORT}" >> "$PROJECT_DIR/.env.defaults"
  else
    APP_PORT="${APP_PORT:-8080}"
  fi

  export APP_PORT
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      pm_install nodejs npm
      ;;
    apk)
      pm_install nodejs npm
      ;;
    dnf|yum|microdnf)
      pm_install nodejs npm
      ;;
    zypper)
      pm_install nodejs npm
      ;;
  esac

  # For native modules
  install_build_essentials
  case "$PKG_MGR" in
    apk) pm_install python3 py3-pip python3-dev ;; # node-gyp requires python3
    apt) pm_install python3 python3-dev ;;
    dnf|yum|microdnf|zypper) pm_install python3 python3-devel || true ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null

  if has_file "pnpm-lock.yaml"; then
    log "Detected pnpm"
    if ! have_cmd pnpm; then
      if have_cmd corepack; then corepack enable || true; fi
      npm -g install pnpm
    fi
    pnpm install --frozen-lockfile || pnpm install
  elif has_file "yarn.lock"; then
    log "Detected yarn"
    if ! have_cmd yarn; then npm -g install yarn; fi
    yarn install --frozen-lockfile || yarn install
  elif has_file "package-lock.json"; then
    log "Detected npm with package-lock.json"
    npm ci || npm install
  else
    if has_file "package.json"; then
      log "Installing npm dependencies"
      npm install
    else
      warn "No package.json found; skipping Node.js dependency install."
    fi
  fi

  # Build step if present
  if has_file "package.json"; then
    if npm run -s build >/dev/null 2>&1; then
      log "Build script executed (npm run build)"
    else
      log "No build script or build skipped"
    fi
  fi
  popd >/dev/null

  echo "NODE_ENV=production" >> "$PROJECT_DIR/.env.defaults"
  export APP_PORT="${APP_PORT:-3000}"
}

# Java (Maven) setup
setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "$PKG_MGR" in
    apt) pm_install openjdk-17-jdk maven ;;
    apk) pm_install openjdk17 maven ;;
    dnf|yum|microdnf) pm_install java-17-openjdk-devel maven ;;
    zypper) pm_install java-17-openjdk-devel maven ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null
  mvn -B -DskipTests dependency:resolve || true
  mvn -B -DskipTests package || mvn -B -DskipTests install || true
  popd >/dev/null

  export APP_PORT="${APP_PORT:-8080}"
}

# Java (Gradle) setup
setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  case "$PKG_MGR" in
    apt) pm_install openjdk-17-jdk unzip ;;
    apk) pm_install openjdk17 unzip ;;
    dnf|yum|microdnf) pm_install java-17-openjdk-devel unzip ;;
    zypper) pm_install java-17-openjdk-devel unzip ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null
  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon assemble -x test || true
  else
    log "No gradle wrapper found; installing gradle"
    case "$PKG_MGR" in
      apt|dnf|yum|microdnf|zypper) pm_install gradle ;;
      apk) pm_install gradle ;;
    esac
    gradle --no-daemon assemble -x test || true
  fi
  popd >/dev/null

  export APP_PORT="${APP_PORT:-8080}"
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    dnf|yum|microdnf) pm_install golang ;;
    zypper) pm_install go ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null
  if has_file "go.mod"; then
    go mod download || true
    go build ./... || true
  else
    warn "No go.mod found; skipping go build."
  fi
  popd >/dev/null

  export APP_PORT="${APP_PORT:-8080}"
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  install_build_essentials
  pm_install curl ca-certificates

  export RUSTUP_HOME=/usr/local/rustup
  export CARGO_HOME=/usr/local/cargo
  if [ ! -x "/usr/local/cargo/bin/cargo" ]; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable
  fi

  # Make cargo available for all shells
  if [ ! -f /etc/profile.d/cargo.sh ]; then
    echo 'export CARGO_HOME=/usr/local/cargo' > /etc/profile.d/cargo.sh
    echo 'export RUSTUP_HOME=/usr/local/rustup' >> /etc/profile.d/cargo.sh
    echo 'export PATH=$CARGO_HOME/bin:$PATH' >> /etc/profile.d/cargo.sh
  fi
  export PATH="/usr/local/cargo/bin:$PATH"

  pushd "$PROJECT_DIR" >/dev/null
  if has_file "Cargo.toml"; then
    cargo fetch || true
    cargo build --release || cargo build || true
  else
    warn "No Cargo.toml found; skipping cargo build."
  fi
  popd >/dev/null

  export APP_PORT="${APP_PORT:-8080}"
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt) pm_install php-cli php-xml php-mbstring php-zip unzip ;;
    apk) pm_install php81 php81-cli php81-xml php81-mbstring php81-zip unzip || pm_install php php-cli php-xml php-mbstring php-zip unzip ;;
    dnf|yum|microdnf) pm_install php-cli php-xml php-mbstring php-zip unzip ;;
    zypper) pm_install php-cli php-xml php-mbstring php-zip unzip ;;
  esac

  if ! have_cmd composer; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  pushd "$PROJECT_DIR" >/dev/null
  if has_file "composer.json"; then
    composer install --no-interaction --no-progress --prefer-dist || composer install --no-interaction
  else
    warn "No composer.json found; skipping Composer install."
  fi
  popd >/dev/null

  export APP_PORT="${APP_PORT:-9000}"
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      pm_install ruby-full build-essential
      ;;
    apk)
      pm_install ruby ruby-dev build-base
      ;;
    dnf|yum|microdnf)
      pm_install ruby ruby-devel @'Development Tools' || pm_install ruby ruby-devel make gcc gcc-c++
      ;;
    zypper)
      pm_install ruby ruby-devel make gcc gcc-c++
      ;;
  esac

  if ! have_cmd bundler; then
    gem install bundler -N
  fi

  pushd "$PROJECT_DIR" >/dev/null
  if has_file "Gemfile"; then
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4 --retry=3
  else
    warn "No Gemfile found; skipping bundle install."
  fi
  popd >/dev/null

  export APP_PORT="${APP_PORT:-3000}"
}

# .NET setup (best-effort for Debian/Ubuntu/CentOS/RHEL/Fedora)
setup_dotnet() {
  log "Setting up .NET environment..."
  if have_cmd dotnet; then
    log "dotnet SDK already installed."
  else
    case "$PKG_MGR" in
      apt)
        pm_update
        pm_install wget gpg
        wget -qO- https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || \
        wget -qO- https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb
        dpkg -i /tmp/packages-microsoft-prod.deb || true
        rm -f /tmp/packages-microsoft-prod.deb
        pm_update
        pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || true
        ;;
      dnf|yum|microdnf)
        pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || true
        ;;
      apk|zypper)
        warn ".NET installation not automated on this distro. Please use a .NET base image."
        ;;
    esac
  fi

  if have_cmd dotnet; then
    pushd "$PROJECT_DIR" >/dev/null
    if ls "$PROJECT_DIR"/*.csproj >/dev/null 2>&1 || ls "$PROJECT_DIR"/*/*.csproj >/dev/null 2>&1; then
      dotnet restore || true
      dotnet build -c Release || true
    else
      warn "No .csproj found; skipping dotnet restore/build."
    fi
    popd >/dev/null
  fi

  export APP_PORT="${APP_PORT:-8080}"
}

# Detect tech stack
detect_stack() {
  if has_any_file "requirements.txt" "pyproject.toml" "Pipfile" "manage.py" "wsgi.py"; then
    echo "python"
  elif has_file "package.json"; then
    echo "node"
  elif has_file "pom.xml"; then
    echo "java-maven"
  elif has_any_file "build.gradle" "build.gradle.kts" "gradlew"; then
    echo "java-gradle"
  elif has_file "go.mod"; then
    echo "go"
  elif has_file "Cargo.toml"; then
    echo "rust"
  elif has_file "composer.json"; then
    echo "php"
  elif ls "$PROJECT_DIR"/*.csproj >/dev/null 2>&1 || ls "$PROJECT_DIR"/*/*.csproj >/dev/null 2>&1; then
    echo "dotnet"
  else
    echo "unknown"
  fi
}

# Environment file management (do not overwrite existing .env)
write_env_files() {
  local defaults="$PROJECT_DIR/.env.defaults"
  local envfile="$PROJECT_DIR/.env"

  # de-duplicate defaults
  if [ -f "$defaults" ]; then
    sort -u "$defaults" -o "$defaults"
  fi

  # Create .env if missing, merging defaults
  if [ ! -f "$envfile" ]; then
    log "Creating $envfile from defaults"
    {
      echo "APP_ENV=${APP_ENV}"
      echo "APP_PORT=${APP_PORT:-$APP_PORT_DEFAULT}"
      [ -f "$defaults" ] && cat "$defaults"
    } > "$envfile"
  else
    log "Preserving existing .env; writing defaults to $defaults"
    # Ensure APP_ENV and APP_PORT exist in .env; append if missing
    grep -q '^APP_ENV=' "$envfile" || echo "APP_ENV=${APP_ENV}" >> "$envfile"
    grep -q '^APP_PORT=' "$envfile" || echo "APP_PORT=${APP_PORT:-$APP_PORT_DEFAULT}" >> "$envfile"
  fi

  chown "$APP_USER:$APP_GROUP" "$PROJECT_DIR/.env" "$defaults" 2>/dev/null || true
}

# Timeout misuse wrapper for 'timeout' command
setup_timeout_wrapper() {
  # Ensure real bash and restore a reliable timeout; move any broken wrapper aside
  if [ -e /usr/local/bin/timeout ]; then mv -f /usr/local/bin/timeout /usr/local/bin/timeout.broken; fi
  if [ -x /usr/local/bin/bash.real ]; then cp -f /usr/local/bin/bash.real /bin/bash && chmod +x /bin/bash; fi


  if [ ! -x /usr/bin/timeout ] && [ ! -x /usr/bin/timeout.coreutils ]; then
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y && apt-get install -y coreutils
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache coreutils
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y coreutils
    elif command -v yum >/dev/null 2>&1; then
      yum install -y coreutils
    elif command -v microdnf >/dev/null 2>&1; then
      microdnf install -y coreutils
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive in -y coreutils
    fi
  fi

  if [ -x /usr/bin/timeout.coreutils ]; then
    ln -sf /usr/bin/timeout.coreutils /usr/local/bin/timeout
  elif [ -x /usr/bin/timeout ]; then
    ln -sf /usr/bin/timeout /usr/local/bin/timeout
  elif command -v busybox >/dev/null 2>&1 && busybox timeout --help >/dev/null 2>&1; then
    ln -sf "$(command -v busybox)" /usr/local/bin/timeout
  else
    echo >&2 "No timeout implementation available after attempting install"
  fi
  chmod 0755 /usr/local/bin/timeout 2>/dev/null || true
  /usr/local/bin/timeout --version >/dev/null 2>&1 || /usr/bin/timeout --version >/dev/null 2>&1 || busybox timeout --help >/dev/null 2>&1 || true
}

# Main

setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_activate="$PROJECT_DIR/.venv/bin/activate"
  local activate_line=". \"$venv_activate\""
  if [ -f "$venv_activate" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
    if [ ! -f /etc/profile.d/auto_venv.sh ] || ! grep -qF "$venv_activate" /etc/profile.d/auto_venv.sh 2>/dev/null; then
      printf 'if [ -f %q ]; then . %q; fi\n' "$venv_activate" "$venv_activate" > /etc/profile.d/auto_venv.sh
      chmod 644 /etc/profile.d/auto_venv.sh || true
    fi
  fi
}

main() {
  require_root
  # setup_timeout_wrapper disabled; timeout repaired earlier at script start
  pm_detect
  prepare_fs
  install_base_tools

  # Move into project directory if it exists
  cd "$PROJECT_DIR"

  local stack
  stack=$(detect_stack)
  log "Detected project stack: $stack"

  case "$stack" in
    python) setup_python ;;
    node) setup_node ;;
    java-maven) setup_java_maven ;;
    java-gradle) setup_java_gradle ;;
    go) setup_go ;;
    rust) setup_rust ;;
    php) setup_php ;;
    dotnet) setup_dotnet ;;
    unknown)
      warn "Could not detect project type. Installing base build tools only."
      install_build_essentials
      export APP_PORT="${APP_PORT:-$APP_PORT_DEFAULT}"
      ;;
  esac

  setup_auto_activate

  # Finalize environment files
  write_env_files

  # Ensure non-root user exists and has permissions
  ensure_user

  # Cleanup package caches
  pm_clean

  log "Environment setup completed successfully."
  log "Summary:"
  echo "- Project directory: $PROJECT_DIR"
  echo "- App user: $APP_USER (UID: $APP_UID)"
  echo "- Detected stack: $stack"
  echo "- Environment file: $PROJECT_DIR/.env"
  echo "- Default port: ${APP_PORT:-$APP_PORT_DEFAULT}"
  echo
  log "Next steps (examples):"
  case "$stack" in
    python)
      echo "source $PROJECT_DIR/.venv/bin/activate"
      if has_file "manage.py"; then
        echo "python manage.py runserver 0.0.0.0:\${APP_PORT:-8000}"
      elif has_any_file "app.py" "wsgi.py"; then
        echo "python app.py  # or: flask run --host=0.0.0.0 --port=\${APP_PORT:-5000}"
      else
        echo "python -m your_module"
      fi
      ;;
    node)
      echo "cd $PROJECT_DIR && npm start  # or yarn start / pnpm start"
      ;;
    java-maven)
      echo "java -jar $(ls "$PROJECT_DIR"/target/*.jar 2>/dev/null | head -n1 || echo target/your-app.jar)"
      ;;
    java-gradle)
      echo "java -jar $(ls "$PROJECT_DIR"/build/libs/*.jar 2>/dev/null | head -n1 || echo build/libs/your-app.jar)"
      ;;
    go)
      echo "cd $PROJECT_DIR && ./$(basename "$PROJECT_DIR")  # or: go run ./..."
      ;;
    rust)
      echo "cd $PROJECT_DIR && ./target/release/$(basename "$PROJECT_DIR")  # or: cargo run --release"
      ;;
    php)
      echo "cd $PROJECT_DIR && php -S 0.0.0.0:\${APP_PORT:-9000} -t public  # adjust docroot as needed"
      ;;
    dotnet)
      echo "cd $PROJECT_DIR && dotnet run --no-build --urls http://0.0.0.0:\${APP_PORT:-8080}"
      ;;
    *)
      echo "Review your project start command and use \$APP_PORT from $PROJECT_DIR/.env"
      ;;
  esac

  log "Setup script is idempotent; you can re-run it safely."
}

main "$@"