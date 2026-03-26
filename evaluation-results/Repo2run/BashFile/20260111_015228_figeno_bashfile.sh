#!/bin/bash
# Universal container-friendly project environment setup script
# Designed to detect common project types and install/configure runtimes and dependencies.
# Safe to run multiple times (idempotent) and tailored for Docker containers (root user, no sudo).

set -Eeuo pipefail

# ------------------------------
# Colors and logging
# ------------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
  echo -e "${YELLOW}[WARNING] $*${NC}"
}
error() {
  echo -e "${RED}[ERROR] $*${NC}" >&2
}

trap 'error "Setup failed at line $LINENO"' ERR

# ------------------------------
# Defaults and env
# ------------------------------
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
# Project root detection: prefer current directory if it has files, else /app
DEFAULT_ROOT="/app"
CURRENT_DIR="$(pwd)"
if [ "$(ls -A "$CURRENT_DIR" 2>/dev/null | wc -l || echo 0)" -gt 0 ]; then
  APP_ROOT="${APP_ROOT:-$CURRENT_DIR}"
else
  APP_ROOT="${APP_ROOT:-$DEFAULT_ROOT}"
fi
PORT="${PORT:-8080}"
SETUP_MARKER="$APP_ROOT/.setup_complete"
ENV_FILE="$APP_ROOT/.env.container"

# ------------------------------
# Helpers
# ------------------------------
require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    warn "Not running as root. Some system-level installations may fail. Run inside a Docker container as root."
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  else
    echo "none"
  fi
}

pm_update_once() {
  local pm="$1"
  case "$pm" in
    apt)
      if [ ! -f /var/lib/apt/lists/lock ] || [ ! -f /var/lib/apt/lists/status ]; then :; fi
      if [ ! -f /var/.apt_updated ]; then
        log "Updating package lists (apt-get)..."
        apt-get update -y || apt-get update
        touch /var/.apt_updated
      else
        log "apt package lists already updated. Skipping."
      fi
      ;;
    apk)
      log "Updating package index (apk)..."
      apk update || true
      ;;
    dnf)
      log "Refreshing package metadata (dnf)..."
      dnf -y makecache || true
      ;;
    yum)
      log "Refreshing package metadata (yum)..."
      yum -y makecache || true
      ;;
    zypper)
      log "Refreshing repositories (zypper)..."
      zypper --non-interactive refresh || true
      ;;
    *)
      warn "No known package manager detected. Skipping system package index update."
      ;;
  esac
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  local pm="$1"
  shift || true
  local packages=("$@")
  if [ "${#packages[@]}" -eq 0 ]; then
    return 0
  fi
  case "$pm" in
    apt)
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${packages[@]}"
      ;;
    *)
      error "Package manager not supported for install: $pm"
      return 1
      ;;
  esac
}

ensure_cmd() {
  # Ensure a command exists; if not, try to install via package manager mapping.
  local cmd="$1"
  local pm="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  case "$cmd" in
    bash)
      case "$pm" in
        apt) pm_install "$pm" bash ;;
        apk) pm_install "$pm" bash ;;
        dnf|yum) pm_install "$pm" bash ;;
        zypper) pm_install "$pm" bash ;;
      esac
      ;;
    git)
      case "$pm" in
        apt) pm_install "$pm" git ;;
        apk) pm_install "$pm" git ;;
        dnf|yum) pm_install "$pm" git ;;
        zypper) pm_install "$pm" git ;;
      esac
      ;;
    curl)
      case "$pm" in
        apt) pm_install "$pm" curl ca-certificates ;;
        apk) pm_install "$pm" curl ca-certificates ;;
        dnf|yum) pm_install "$pm" curl ca-certificates ;;
        zypper) pm_install "$pm" curl ca-certificates ;;
      esac
      ;;
    wget)
      case "$pm" in
        apt) pm_install "$pm" wget ca-certificates ;;
        apk) pm_install "$pm" wget ca-certificates ;;
        dnf|yum) pm_install "$pm" wget ca-certificates ;;
        zypper) pm_install "$pm" wget ca-certificates ;;
      esac
      ;;
    unzip)
      case "$pm" in
        apt) pm_install "$pm" unzip ;;
        apk) pm_install "$pm" unzip ;;
        dnf|yum) pm_install "$pm" unzip ;;
        zypper) pm_install "$pm" unzip ;;
      esac
      ;;
    tar)
      case "$pm" in
        apt) pm_install "$pm" tar ;;
        apk) pm_install "$pm" tar ;;
        dnf|yum) pm_install "$pm" tar ;;
        zypper) pm_install "$pm" tar ;;
      esac
      ;;
    python3)
      case "$pm" in
        apt) pm_install "$pm" python3 python3-venv python3-pip python3-dev ;;
        apk) pm_install "$pm" python3 py3-pip python3-dev ;;
        dnf|yum) pm_install "$pm" python3 python3-pip python3-devel ;;
        zypper) pm_install "$pm" python3 python3-pip python3-devel ;;
      esac
      ;;
    pip3|pip)
      case "$pm" in
        apt) pm_install "$pm" python3-pip ;;
        apk) pm_install "$pm" py3-pip ;;
        dnf|yum) pm_install "$pm" python3-pip ;;
        zypper) pm_install "$pm" python3-pip ;;
      esac
      ;;
    node|nodejs)
      case "$pm" in
        apt) pm_install "$pm" nodejs npm ;;
        apk) pm_install "$pm" nodejs npm ;;
        dnf|yum) pm_install "$pm" nodejs npm || warn "nodejs/npm may require EPEL. Consider using NodeSource or nvm." ;;
        zypper) pm_install "$pm" nodejs npm ;;
      esac
      ;;
    ruby)
      case "$pm" in
        apt) pm_install "$pm" ruby-full ruby-dev bundler ;;
        apk) pm_install "$pm" ruby ruby-dev build-base && gem install bundler --no-document || true ;;
        dnf|yum) pm_install "$pm" ruby ruby-devel rubygems && gem install bundler --no-document || true ;;
        zypper) pm_install "$pm" ruby ruby-devel rubygems && gem install bundler --no-document || true ;;
      esac
      ;;
    go)
      case "$pm" in
        apt) pm_install "$pm" golang-go ;;
        apk) pm_install "$pm" go ;;
        dnf|yum) pm_install "$pm" golang ;;
        zypper) pm_install "$pm" go ;;
      esac
      ;;
    javac)
      case "$pm" in
        apt) pm_install "$pm" default-jdk ;;
        apk) pm_install "$pm" openjdk11-jdk ;;
        dnf|yum) pm_install "$pm" java-11-openjdk-devel ;;
        zypper) pm_install "$pm" java-11-openjdk-devel ;;
      esac
      ;;
    mvn)
      case "$pm" in
        apt) pm_install "$pm" maven ;;
        apk) pm_install "$pm" maven ;;
        dnf|yum) pm_install "$pm" maven ;;
        zypper) pm_install "$pm" maven ;;
      esac
      ;;
    gradle)
      case "$pm" in
        apt) pm_install "$pm" gradle ;;
        apk) pm_install "$pm" gradle ;;
        dnf|yum) pm_install "$pm" gradle ;;
        zypper) pm_install "$pm" gradle ;;
      esac
      ;;
    php)
      case "$pm" in
        apt) pm_install "$pm" php-cli php-curl php-zip php-xml ;;
        apk) pm_install "$pm" php-cli php-curl php-zip php-xml ;;
        dnf|yum) pm_install "$pm" php-cli php-curl php-zip php-xml ;;
        zypper) pm_install "$pm" php-cli php-curl php-zip php-xml ;;
      esac
      ;;
    composer)
      case "$pm" in
        apt) pm_install "$pm" composer ;;
        apk) pm_install "$pm" composer ;;
        dnf|yum) pm_install "$pm" composer ;;
        zypper) pm_install "$pm" composer ;;
      esac
      ;;
    rustc|cargo)
      case "$pm" in
        apt) pm_install "$pm" rustc cargo ;;
        apk) pm_install "$pm" rust cargo ;;
        dnf|yum) pm_install "$pm" rust cargo ;;
        zypper) pm_install "$pm" rust cargo ;;
      esac
      ;;
    *)
      warn "No installation mapping for command: $cmd"
      ;;
  esac
}

ensure_build_tools() {
  local pm="$1"
  case "$pm" in
    apt)
      pm_install "$pm" build-essential pkg-config ca-certificates openssl libssl-dev libffi-dev zlib1g-dev
      ;;
    apk)
      pm_install "$pm" build-base pkgconfig ca-certificates openssl-dev libffi-dev zlib-dev
      ;;
    dnf|yum)
      pm_install "$pm" make gcc pkgconfig ca-certificates openssl-devel libffi-devel zlib-devel
      ;;
    zypper)
      pm_install "$pm" gcc make pkg-config ca-certificates libopenssl-devel libffi-devel zlib-devel
      ;;
    *)
      warn "Cannot ensure build tools: unknown package manager"
      ;;
  esac
}

create_user_and_dirs() {
  # Create non-root app user and set ownership for APP_ROOT.
  # Safe and idempotent.
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    log "Creating application user '$APP_USER' (uid:$APP_UID gid:$APP_GID)..."
    if ! getent group "$APP_GID" >/dev/null 2>&1; then
      if command -v groupadd >/dev/null 2>&1; then
        groupadd -g "$APP_GID" "$APP_USER"
      elif command -v addgroup >/dev/null 2>&1; then
        addgroup -g "$APP_GID" "$APP_USER"
      fi
    fi
    if command -v useradd >/dev/null 2>&1; then
      useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" || true
    elif command -v adduser >/dev/null 2>&1; then
      adduser -D -u "$APP_UID" -G "$APP_USER" -s /bin/bash "$APP_USER" || true
    fi
  fi

  mkdir -p "$APP_ROOT"
  chown -R "$APP_UID":"$APP_GID" "$APP_ROOT" || true

  # Shared directories
  mkdir -p "$APP_ROOT/log" "$APP_ROOT/tmp" "$APP_ROOT/.cache"
  chmod 775 "$APP_ROOT/log" "$APP_ROOT/tmp" || true
}

write_env_file() {
  cat > "$ENV_FILE" <<EOF
# Container environment configuration
APP_ROOT="$APP_ROOT"
APP_ENV="$APP_ENV"
PORT="$PORT"
PATH="\$PATH:$APP_ROOT/bin"
# Python virtualenv, if created:
VIRTUAL_ENV="$APP_ROOT/.venv"
# Node.js
NODE_ENV="${NODE_ENV:-production}"
# Go (if used)
GOPATH="$APP_ROOT/.gopath"
GOBIN="$APP_ROOT/.gopath/bin"
# Rust (if used)
CARGO_HOME="$APP_ROOT/.cargo"
RUSTUP_HOME="$APP_ROOT/.rustup"
EOF
  chmod 0644 "$ENV_FILE"
}

ensure_profile_path() {
  # Make PATH persistent in interactive shells inside container
  local profile_d="/etc/profile.d"
  mkdir -p "$profile_d"
  cat > "$profile_d/project-path.sh" <<'EOF'
# Auto-added by setup script: project tool paths
export PATH="${PATH}:${HOME}/.local/bin"
EOF
}

# ------------------------------
# Project type detectors
# ------------------------------
has_python() {
  [ -f "$APP_ROOT/requirements.txt" ] || [ -f "$APP_ROOT/pyproject.toml" ] || ls "$APP_ROOT"/*.py >/dev/null 2>&1
}
has_node() {
  [ -f "$APP_ROOT/package.json" ]
}
has_ruby() {
  [ -f "$APP_ROOT/Gemfile" ]
}
has_go() {
  [ -f "$APP_ROOT/go.mod" ] || [ -f "$APP_ROOT/go.sum" ] || ls "$APP_ROOT"/*.go >/dev/null 2>&1
}
has_java() {
  [ -f "$APP_ROOT/pom.xml" ] || [ -f "$APP_ROOT/build.gradle" ] || [ -f "$APP_ROOT/gradlew" ]
}
has_php() {
  [ -f "$APP_ROOT/composer.json" ]
}
has_rust() {
  [ -f "$APP_ROOT/Cargo.toml" ]
}
has_dotnet() {
  ls "$APP_ROOT"/*.sln >/dev/null 2>&1 || ls "$APP_ROOT"/*.csproj >/dev/null 2>&1
}

# ------------------------------
# Language setup routines
# ------------------------------
setup_python() {
  local pm="$1"
  log "Setting up Python environment..."
  ensure_cmd python3 "$pm"
  ensure_cmd pip3 "$pm"
  ensure_build_tools "$pm"

  # Create venv if needed
  if [ ! -d "$APP_ROOT/.venv" ]; then
    log "Creating virtual environment at $APP_ROOT/.venv"
    python3 -m venv "$APP_ROOT/.venv"
  else
    log "Python virtual environment already exists. Skipping creation."
  fi

  # Activate venv for installation
  # shellcheck source=/dev/null
  source "$APP_ROOT/.venv/bin/activate"
  log "Upgrading pip and setuptools..."
  pip install --upgrade pip setuptools wheel

  if [ -f "$APP_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install -r "$APP_ROOT/requirements.txt"
  elif [ -f "$APP_ROOT/pyproject.toml" ]; then
    # Try Poetry first if it's a Poetry project
    if grep -qE '^\s*\[tool\.poetry\]' "$APP_ROOT/pyproject.toml"; then
      log "Detected Poetry project. Installing Poetry and dependencies..."
      pip install "poetry>=1.5" || true
      if command -v poetry >/dev/null 2>&1; then
        POETRY_VIRTUALENVS_CREATE="${POETRY_VIRTUALENVS_CREATE:-false}" poetry install --no-interaction --no-ansi
      else
        warn "Poetry not available; falling back to PEP 517 build/deps"
        pip install .
      fi
    else
      log "Installing PEP 517/518 dependencies from pyproject.toml..."
      pip install .
    fi
  else
    warn "No requirements.txt or pyproject.toml found; skipping Python dependency installation."
  fi

  # Environment defaults
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=0
  echo "export PYTHONUNBUFFERED=1" >> "$ENV_FILE"
  echo "export PIP_NO_CACHE_DIR=0" >> "$ENV_FILE"
}

setup_node() {
  local pm="$1"
  log "Setting up Node.js environment..."
  ensure_cmd node "$pm" || ensure_cmd nodejs "$pm"
  ensure_cmd npm "$pm"
  ensure_build_tools "$pm"

  # Use npm ci if lockfile present
  if [ -f "$APP_ROOT/package-lock.json" ]; then
    log "Installing Node dependencies via npm ci..."
    npm ci --prefix "$APP_ROOT"
  else
    log "Installing Node dependencies via npm install..."
    npm install --no-audit --no-fund --prefix "$APP_ROOT"
  fi

  # Ensure local bin path is included
  echo "export PATH=\"\$PATH:$APP_ROOT/node_modules/.bin\"" >> "$ENV_FILE"
  export NODE_ENV="${NODE_ENV:-production}"
}

setup_ruby() {
  local pm="$1"
  log "Setting up Ruby environment..."
  ensure_cmd ruby "$pm"
  ensure_build_tools "$pm"

  if ! command -v bundle >/dev/null 2>&1; then
    if command -v gem >/dev/null 2>&1; then
      log "Installing bundler gem..."
      gem install bundler --no-document || true
    fi
  fi

  if [ -f "$APP_ROOT/Gemfile" ]; then
    log "Installing Ruby gems with bundler..."
    (cd "$APP_ROOT" && bundle config set no-cache 'true' && bundle install --path vendor/bundle)
    echo "export BUNDLE_PATH=\"$APP_ROOT/vendor/bundle\"" >> "$ENV_FILE"
  else
    warn "No Gemfile found; skipping Ruby dependency installation."
  fi
}

setup_go() {
  local pm="$1"
  log "Setting up Go environment..."
  ensure_cmd go "$pm"
  mkdir -p "$APP_ROOT/.gopath"
  export GOPATH="$APP_ROOT/.gopath"
  export GOBIN="$GOPATH/bin"
  echo "export GOPATH=\"$APP_ROOT/.gopath\"" >> "$ENV_FILE"
  echo "export GOBIN=\"$APP_ROOT/.gopath/bin\"" >> "$ENV_FILE"
  echo "export PATH=\"\$PATH:$APP_ROOT/.gopath/bin\"" >> "$ENV_FILE"

  if [ -f "$APP_ROOT/go.mod" ]; then
    log "Downloading Go modules..."
    (cd "$APP_ROOT" && go mod download)
  else
    warn "No go.mod found; skipping module download."
  fi
}

setup_java() {
  local pm="$1"
  log "Setting up Java environment..."
  ensure_cmd javac "$pm"
  # Try to install build tools based on project type
  if [ -f "$APP_ROOT/pom.xml" ]; then
    ensure_cmd mvn "$pm"
    log "Resolving Maven dependencies..."
    (cd "$APP_ROOT" && mvn -B -ntp dependency:resolve || true)
  fi
  if [ -f "$APP_ROOT/build.gradle" ] || [ -f "$APP_ROOT/gradlew" ]; then
    ensure_cmd gradle "$pm"
    log "Preparing Gradle (no-daemon)..."
    (cd "$APP_ROOT" && gradle --no-daemon tasks || true)
  fi
}

setup_php() {
  local pm="$1"
  log "Setting up PHP environment..."
  ensure_cmd php "$pm"
  ensure_cmd composer "$pm"
  if [ -f "$APP_ROOT/composer.json" ]; then
    log "Installing Composer dependencies..."
    (cd "$APP_ROOT" && composer install --no-dev --no-interaction --prefer-dist)
  else
    warn "No composer.json found; skipping Composer install."
  fi
}

setup_rust_lang() {
  local pm="$1"
  log "Setting up Rust environment..."
  # Prefer system rustc/cargo for simplicity
  ensure_cmd rustc "$pm"
  ensure_cmd cargo "$pm"
  mkdir -p "$APP_ROOT/.cargo" "$APP_ROOT/.rustup"
  echo "export CARGO_HOME=\"$APP_ROOT/.cargo\"" >> "$ENV_FILE"
  echo "export RUSTUP_HOME=\"$APP_ROOT/.rustup\"" >> "$ENV_FILE"
  echo "export PATH=\"\$PATH:$APP_ROOT/.cargo/bin\"" >> "$ENV_FILE"

  if [ -f "$APP_ROOT/Cargo.toml" ]; then
    log "Fetching Rust crates..."
    (cd "$APP_ROOT" && cargo fetch || true)
  else
    warn "No Cargo.toml found; skipping cargo fetch."
  fi
}

setup_dotnet() {
  log "Setting up .NET SDK..."
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK already installed."
  else
    ensure_cmd curl "$PKG_MANAGER"
    local DOTNET_VERSION="${DOTNET_VERSION:-}"; # optional, e.g., 8.0.100
    local install_script="/tmp/dotnet-install.sh"
    curl -sSL https://dot.net/v1/dotnet-install.sh -o "$install_script"
    chmod +x "$install_script"
    if [ -n "$DOTNET_VERSION" ]; then
      bash "$install_script" --version "$DOTNET_VERSION" --install-dir /usr/local/dotnet
    else
      bash "$install_script" --channel LTS --install-dir /usr/local/dotnet
    fi
    ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
  fi

  echo "export PATH=\"\$PATH:/usr/local/dotnet\"" >> "$ENV_FILE"

  # Restore dependencies if project files exist
  if has_dotnet; then
    log "Restoring .NET dependencies..."
    (cd "$APP_ROOT" && find . -name "*.sln" -o -name "*.csproj" | while read -r proj; do
      dotnet restore "$proj" || true
    done)
  fi
}

# ------------------------------
# Main
# ------------------------------
main() {
  require_root

  # Detect and update package manager
  PKG_MANAGER="$(detect_pkg_manager)"
  if [ "$PKG_MANAGER" = "none" ]; then
    warn "No supported package manager detected. The script will attempt limited setup."
  else
    pm_update_once "$PKG_MANAGER"
  fi

  # Base utilities
  log "Installing base utilities..."
  ensure_cmd bash "$PKG_MANAGER"
  ensure_cmd git "$PKG_MANAGER"
  ensure_cmd curl "$PKG_MANAGER"
  ensure_cmd wget "$PKG_MANAGER"
  ensure_cmd unzip "$PKG_MANAGER"
  ensure_cmd tar "$PKG_MANAGER"
  ensure_profile_path

  # Directories and user
  create_user_and_dirs

  # Write env file (will be appended by language-specific setups)
  write_env_file

  # Detect project types
  PY=false; NODE=false; RUBY=false; GO=false; JAVA=false; PHP=false; RUST=false; DOTNET=false
  has_python && PY=true
  has_node && NODE=true
  has_ruby && RUBY=true
  has_go && GO=true
  has_java && JAVA=true
  has_php && PHP=true
  has_rust && RUST=true
  has_dotnet && DOTNET=true

  if [ "$PY" = false ] && [ "$NODE" = false ] && [ "$RUBY" = false ] && [ "$GO" = false ] && [ "$JAVA" = false ] && [ "$PHP" = false ] && [ "$RUST" = false ] && [ "$DOTNET" = false ]; then
    warn "No supported project files detected in $APP_ROOT. Proceeding with base setup only."
  fi

  # Language-specific setup
  if [ "$PY" = true ]; then setup_python "$PKG_MANAGER"; fi
  if [ "$NODE" = true ]; then setup_node "$PKG_MANAGER"; fi
  if [ "$RUBY" = true ]; then setup_ruby "$PKG_MANAGER"; fi
  if [ "$GO" = true ]; then setup_go "$PKG_MANAGER"; fi
  if [ "$JAVA" = true ]; then setup_java "$PKG_MANAGER"; fi
  if [ "$PHP" = true ]; then setup_php "$PKG_MANAGER"; fi
  if [ "$RUST" = true ]; then setup_rust_lang "$PKG_MANAGER"; fi
  if [ "$DOTNET" = true ]; then setup_dotnet; fi

  # Export env for current session
  # shellcheck disable=SC1090
  if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE" || true
  fi

  # Mark setup complete
  touch "$SETUP_MARKER"

  # Summary
  log "Environment setup completed successfully."
  echo "Project root: $APP_ROOT"
  echo "Environment: $APP_ENV"
  echo "Default port: $PORT"
  echo "User: $APP_USER (uid:$APP_UID gid:$APP_GID)"
  echo "Environment file: $ENV_FILE"
  echo "To load environment variables in a new shell: source \"$ENV_FILE\""
  echo "This script is safe to run multiple times; it will skip already completed steps."
}

main "$@"