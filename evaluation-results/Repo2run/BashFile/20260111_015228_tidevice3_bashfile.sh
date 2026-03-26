#!/bin/bash
# Universal project environment setup script for Docker containers.
# Detects common project types (Python, Node.js, Ruby, Go, PHP, Rust, .NET)
# Installs required runtimes and system packages, sets up dependencies,
# creates a dedicated app user, and configures environment variables.
#
# Designed to be idempotent and safe to run multiple times.

set -Eeuo pipefail

# Colors for output (avoid if not TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

# Logging functions
log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARNING] $*${NC}" >&2; }
error() { echo "${RED}[ERROR] $*${NC}" >&2; }
debug() { if [ "${APP_DEBUG:-0}" = "1" ]; then echo "${BLUE}[DEBUG] $*${NC}"; fi }

# Trap errors
cleanup() { :; }
on_error() {
  error "Setup failed at line $1. Inspect logs above."
}
trap 'on_error $LINENO' ERR
trap cleanup EXIT

# Default environment variables (can be overridden before running)
APP_HOME="${APP_HOME:-/app}"
APP_USER="${APP_USER:-appuser}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
APP_NAME="${APP_NAME:-containerized-app}"
APP_DEBUG="${APP_DEBUG:-0}"

# Helpers
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root_or_warn() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Script is not running as root. System package installation may fail. Proceeding with user-level steps."
    return 1
  fi
  return 0
}

# Detect package manager
PKG_MGR=""
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
    PKG_MGR="none"
  fi
  debug "Detected package manager: $PKG_MGR"
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache
      ;;
    zypper)
      zypper -n refresh
      ;;
    *)
      warn "No supported package manager found. Skipping system updates."
      ;;
  esac
}

pkg_install() {
  if [ $# -eq 0 ]; then return 0; fi
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
    zypper)
      zypper -n install "$@"
      ;;
    *)
      warn "No supported package manager found. Cannot install: $*"
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MGR" in
    apt)
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
      ;;
    apk)
      rm -rf /var/cache/apk/*
      ;;
    dnf|yum)
      :
      ;;
    zypper)
      :
      ;;
    *)
      :
      ;;
  esac
}

# Create app group/user for secure runtime
setup_user() {
  if ! require_root_or_warn; then
    warn "Cannot create app user without root. Using current user for runtime."
    return 0
  fi

  # Create group if not exists
  if ! getent group "$APP_USER" >/dev/null 2>&1; then
    addgroup_cmd=""
    if command_exists groupadd; then
      addgroup_cmd="groupadd -g $APP_GID $APP_USER"
    elif command_exists addgroup; then
      addgroup_cmd="addgroup --gid $APP_GID $APP_USER"
    fi
    if [ -n "$addgroup_cmd" ]; then
      eval "$addgroup_cmd" || true
      log "Created group $APP_USER ($APP_GID)"
    fi
  fi

  # Create user if not exists
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if command_exists useradd; then
      useradd -u "$APP_UID" -g "$APP_GID" -M -s /bin/sh "$APP_USER" || true
    elif command_exists adduser; then
      adduser --uid "$APP_UID" --gid "$APP_GID" --disabled-password --shell /bin/sh --no-create-home "$APP_USER" || true
    fi
    log "Created user $APP_USER ($APP_UID)"
  fi
}

# Prepare directories
setup_directories() {
  mkdir -p "$APP_HOME"
  if require_root_or_warn; then
    chown -R "${APP_USER}:${APP_USER}" "$APP_HOME" || true
  fi
}

# Base system packages
install_base_system_packages() {
  if ! require_root_or_warn; then
    warn "Skipping base system package installation (not root)."
    return 0
  fi
  detect_pkg_mgr
  if [ "$PKG_MGR" = "none" ]; then
    warn "No package manager available. Skipping system package installation."
    return 0
  fi

  pkg_update

  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git gnupg dirmngr tzdata openssl unzip xz-utils tar jq build-essential pkg-config
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl wget git tzdata openssl unzip xz tar jq build-base pkgconfig
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git gnupg2 tzdata openssl unzip xz tar jq gcc gcc-c++ make pkgconfig
      ;;
    zypper)
      pkg_install ca-certificates curl wget git gpg2 timezone openssl unzip xz tar jq gcc gcc-c++ make pkg-config
      ;;
  esac

  pkg_clean
}

# Project type detection
IS_PY=0
IS_NODE=0
IS_RUBY=0
IS_GO=0
IS_PHP=0
IS_RUST=0
IS_DOTNET=0

detect_project_types() {
  local dir="${1:-$APP_HOME}"
  [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ] && IS_PY=1
  [ -f "$dir/package.json" ] && IS_NODE=1
  [ -f "$dir/Gemfile" ] && IS_RUBY=1
  [ -f "$dir/go.mod" ] || [ -f "$dir/main.go" ] && IS_GO=1
  [ -f "$dir/composer.json" ] && IS_PHP=1
  [ -f "$dir/Cargo.toml" ] && IS_RUST=1
  # Detect .NET by presence of .csproj or .sln
  if ls "$dir"/*.csproj >/dev/null 2>&1 || ls "$dir"/*.sln >/dev/null 2>&1; then IS_DOTNET=1; fi

  debug "Project detection: PY=$IS_PY NODE=$IS_NODE RUBY=$IS_RUBY GO=$IS_GO PHP=$IS_PHP RUST=$IS_RUST DOTNET=$IS_DOTNET"
}

# Language-specific installers
install_python_runtime() {
  if command_exists python3 && command_exists pip3; then
    log "Python runtime already present."
    return 0
  fi
  if ! require_root_or_warn; then
    warn "Cannot install Python without root."
    return 1
  fi
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      pkg_update
      pkg_install python3 py3-pip python3-dev
      ;;
    dnf|yum)
      pkg_update
      pkg_install python3 python3-pip python3-devel
      ;;
    zypper)
      pkg_update
      pkg_install python3 python3-pip python3-devel
      ;;
    *)
      warn "Unsupported package manager for Python."
      ;;
  esac
  pkg_clean
}

setup_python_env() {
  local dir="$APP_HOME"
  if [ "$IS_PY" -ne 1 ]; then return 0; fi
  log "Setting up Python environment..."
  install_python_runtime || true

  if ! command_exists python3; then
    error "Python3 not available. Skipping Python setup."
    return 1
  fi

  # Create virtual environment
  if [ -d "$dir/.venv" ]; then
    log "Python virtual environment already exists at $dir/.venv"
  else
    python3 -m venv "$dir/.venv"
    log "Created Python virtual environment at $dir/.venv"
  fi

  # Activate venv for installing deps
  # shellcheck disable=SC1091
  source "$dir/.venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [ -f "$dir/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install -r "$dir/requirements.txt"
  elif [ -f "$dir/pyproject.toml" ]; then
    if grep -qi '\[tool.poetry\]' "$dir/pyproject.toml"; then
      log "Detected Poetry project."
      if ! command_exists poetry; then
        if require_root_or_warn; then
          # Install poetry via pip in venv to avoid system install
          pip install "poetry>=1.5"
        else
          pip install "poetry>=1.5" || true
        fi
      fi
      poetry install --no-interaction --no-ansi
    else
      # PEP 517/518 project; attempt to install in editable mode if setup.cfg/setup.py exists
      if [ -f "$dir/setup.py" ] || [ -f "$dir/setup.cfg" ]; then
        pip install -e "$dir"
      else
        pip install "$dir"
      fi
    fi
  elif [ -f "$dir/setup.py" ]; then
    pip install -e "$dir"
  else
    warn "No Python dependency manifest found. Skipping dependency installation."
  fi

  deactivate || true
}

install_node_runtime() {
  if command_exists node && command_exists npm; then
    log "Node.js runtime already present."
    return 0
  fi
  if ! require_root_or_warn; then
    warn "Cannot install Node.js without root."
    return 1
  fi
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install nodejs npm
      ;;
    apk)
      pkg_update
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_update
      pkg_install nodejs npm
      ;;
    zypper)
      pkg_update
      pkg_install nodejs npm
      ;;
    *)
      warn "Unsupported package manager for Node.js."
      ;;
  esac
  pkg_clean
}

setup_node_env() {
  local dir="$APP_HOME"
  if [ "$IS_NODE" -ne 1 ]; then return 0; fi
  log "Setting up Node.js environment..."
  install_node_runtime || true
  if ! command_exists npm; then
    error "npm not available. Skipping Node.js setup."
    return 1
  fi

  pushd "$dir" >/dev/null
  if [ -f package-lock.json ]; then
    npm ci --omit=dev || npm ci
  else
    npm install --omit=dev || npm install
  fi
  # Optionally build if scripts present
  if jq -e '.scripts.build' package.json >/dev/null 2>&1; then
    npm run build || true
  fi
  popd >/dev/null
}

install_ruby_runtime() {
  if command_exists ruby; then
    log "Ruby runtime already present."
    return 0
  fi
  if ! require_root_or_warn; then
    warn "Cannot install Ruby without root."
    return 1
  fi
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_update
      pkg_install ruby ruby-bundler build-base
      ;;
    dnf|yum)
      pkg_update
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    zypper)
      pkg_update
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      warn "Unsupported package manager for Ruby."
      ;;
  esac
  pkg_clean
}

setup_ruby_env() {
  local dir="$APP_HOME"
  if [ "$IS_RUBY" -ne 1 ]; then return 0; fi
  log "Setting up Ruby environment..."
  install_ruby_runtime || true
  if ! command_exists gem; then
    error "RubyGems not available. Skipping Ruby setup."
    return 1
  fi
  if ! command_exists bundle; then
    gem install bundler --no-document || true
  fi
  pushd "$dir" >/dev/null
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs=4 --retry=3
  popd >/dev/null
}

install_go_runtime() {
  if command_exists go; then
    log "Go runtime already present."
    return 0
  fi
  if ! require_root_or_warn; then
    warn "Cannot install Go without root."
    return 1
  fi
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install golang
      ;;
    apk)
      pkg_update
      pkg_install go
      ;;
    dnf|yum)
      pkg_update
      pkg_install golang
      ;;
    zypper)
      pkg_update
      pkg_install go
      ;;
    *)
      warn "Unsupported package manager for Go."
      ;;
  esac
  pkg_clean
}

setup_go_env() {
  local dir="$APP_HOME"
  if [ "$IS_GO" -ne 1 ]; then return 0; fi
  log "Setting up Go environment..."
  install_go_runtime || true
  if ! command_exists go; then
    error "Go not available. Skipping Go setup."
    return 1
  fi
  pushd "$dir" >/dev/null
  if [ -f go.mod ]; then
    go mod download
  fi
  popd >/dev/null
}

install_php_runtime() {
  if command_exists php; then
    log "PHP runtime already present."
  else
    if ! require_root_or_warn; then
      warn "Cannot install PHP without root."
      return 1
    fi
    case "$PKG_MGR" in
      apt)
        pkg_update
        pkg_install php-cli php-xml php-mbstring
        ;;
      apk)
        pkg_update
        pkg_install php php-cli php-xml php8-mbstring || pkg_install php php-cli php-xml php-mbstring
        ;;
      dnf|yum)
        pkg_update
        pkg_install php-cli php-xml php-mbstring
        ;;
      zypper)
        pkg_update
        pkg_install php-cli php-xml php-mbstring
        ;;
      *)
        warn "Unsupported package manager for PHP."
        ;;
    esac
    pkg_clean
  fi

  if command_exists composer; then
    log "Composer already present."
    return 0
  fi

  # Install composer
  if require_root_or_warn; then
    case "$PKG_MGR" in
      apt|zypper|dnf|yum)
        pkg_install composer || true
        ;;
      apk)
        pkg_install composer || true
        ;;
      *)
        :
        ;;
    esac
  fi

  if ! command_exists composer; then
    # Fallback install composer locally
    if command_exists php; then
      curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
      rm -f /tmp/composer-setup.php
    else
      warn "PHP not available to install Composer."
    fi
  fi
}

setup_php_env() {
  local dir="$APP_HOME"
  if [ "$IS_PHP" -ne 1 ]; then return 0; fi
  log "Setting up PHP environment..."
  install_php_runtime || true
  if ! command_exists composer; then
    error "Composer not available. Skipping PHP setup."
    return 1
  fi
  pushd "$dir" >/dev/null
  composer install --no-interaction --prefer-dist || composer install --no-interaction
  popd >/dev/null
}

install_rust_runtime() {
  if command_exists cargo && command_exists rustc; then
    log "Rust toolchain already present."
    return 0
  fi
  # Prefer rustup installation for portability
  if ! command_exists curl; then
    warn "curl not available. Cannot install Rust easily."
    return 1
  fi
  log "Installing Rust via rustup..."
  export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
  export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
  sh /tmp/rustup.sh -y --profile minimal
  rm -f /tmp/rustup.sh
  export PATH="$CARGO_HOME/bin:$PATH"
  # Ensure PATH is persisted later by env setup
}

setup_rust_env() {
  local dir="$APP_HOME"
  if [ "$IS_RUST" -ne 1 ]; then return 0; fi
  log "Setting up Rust environment..."
  install_rust_runtime || true
  if ! command_exists cargo; then
    error "Cargo not available. Skipping Rust setup."
    return 1
  fi
  pushd "$dir" >/dev/null
  cargo fetch || true
  popd >/dev/null
}

install_dotnet_runtime() {
  if command_exists dotnet; then
    log ".NET SDK already present."
    return 0
  fi
  if ! require_root_or_warn; then
    warn "Cannot install .NET SDK without root."
    return 1
  fi
  if [ "$PKG_MGR" != "apt" ]; then
    warn "Automatic .NET SDK installation is only implemented for apt. Consider using official 'mcr.microsoft.com/dotnet/sdk' images."
    return 1
  fi
  log "Installing .NET SDK (attempting 8.0)..."
  # Add Microsoft package repo
  pkg_update
  pkg_install wget apt-transport-https
  wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || \
  wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
  if [ -f /tmp/packages-microsoft-prod.deb ]; then
    dpkg -i /tmp/packages-microsoft-prod.deb || true
    rm -f /tmp/packages-microsoft-prod.deb
  fi
  apt-get update -y || true
  apt-get install -y dotnet-sdk-8.0 || apt-get install -y dotnet-sdk-7.0 || true
  pkg_clean
}

setup_dotnet_env() {
  local dir="$APP_HOME"
  if [ "$IS_DOTNET" -ne 1 ]; then return 0; fi
  log "Setting up .NET environment..."
  install_dotnet_runtime || true
  if ! command_exists dotnet; then
    warn "dotnet CLI not available. Skipping .NET restore."
    return 1
  fi
  pushd "$dir" >/dev/null
  dotnet restore || true
  popd >/dev/null
}

# Environment variable configuration
configure_environment() {
  log "Configuring runtime environment variables..."
  local profile_script="/etc/profile.d/app_env.sh"
  local env_file="$APP_HOME/.env"

  # Determine default port heuristics
  if [ "$IS_NODE" -eq 1 ]; then APP_PORT="${APP_PORT:-3000}"; fi
  if [ "$IS_PY" -eq 1 ]; then APP_PORT="${APP_PORT:-5000}"; fi
  if [ "$IS_RUBY" -eq 1 ]; then APP_PORT="${APP_PORT:-3000}"; fi
  if [ "$IS_PHP" -eq 1 ]; then APP_PORT="${APP_PORT:-8080}"; fi
  if [ "$IS_GO" -eq 1 ]; then APP_PORT="${APP_PORT:-8080}"; fi
  if [ "$IS_RUST" -eq 1 ]; then APP_PORT="${APP_PORT:-8080}"; fi
  if [ "$IS_DOTNET" -eq 1 ]; then APP_PORT="${APP_PORT:-8080}"; fi

  # Write .env file
  cat > "$env_file" <<EOF
APP_NAME=$APP_NAME
APP_ENV=$APP_ENV
APP_HOME=$APP_HOME
APP_PORT=$APP_PORT
EOF

  # Persist environment for login shells
  if require_root_or_warn; then
    mkdir -p /etc/profile.d
    cat > "$profile_script" <<'EOF'
# Auto-generated application environment for container sessions
export APP_NAME="${APP_NAME:-containerized-app}"
export APP_ENV="${APP_ENV:-production}"
export APP_HOME="${APP_HOME:-/app}"
export APP_PORT="${APP_PORT:-8080}"

# Add Python venv and common bin paths if present
if [ -d "$APP_HOME/.venv/bin" ]; then
  export PATH="$APP_HOME/.venv/bin:$PATH"
fi
if [ -d "$APP_HOME/node_modules/.bin" ]; then
  export PATH="$APP_HOME/node_modules/.bin:$PATH"
fi

# Rust/Cargo paths if installed via rustup
if [ -d "/usr/local/cargo/bin" ]; then
  export PATH="/usr/local/cargo/bin:$PATH"
fi
EOF
    chmod 0644 "$profile_script"
  fi

  # Create runtime start script for convenience
  local start_script="$APP_HOME/start.sh"
  if [ ! -f "$start_script" ]; then
    cat > "$start_script" <<'EOF'
#!/bin/sh
set -Eeuo pipefail

APP_HOME="${APP_HOME:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"

echo "Starting application: $APP_HOME (env=$APP_ENV, port=$APP_PORT)"

if [ -f "$APP_HOME/.venv/bin/activate" ]; then
  . "$APP_HOME/.venv/bin/activate"
fi

# Try common start commands
if [ -f "$APP_HOME/package.json" ] && command -v npm >/dev/null 2>&1; then
  if jq -e '.scripts.start' "$APP_HOME/package.json" >/dev/null 2>&1; then
    exec npm start
  elif jq -e '.scripts.serve' "$APP_HOME/package.json" >/dev/null 2>&1; then
    exec npm run serve
  fi
fi

if [ -f "$APP_HOME/app.py" ] && command -v python >/dev/null 2>&1; then
  exec python "$APP_HOME/app.py"
fi

# Ruby (Rack/Puma)
if [ -f "$APP_HOME/config.ru" ] && command -v rackup >/dev/null 2>&1; then
  exec rackup -p "${APP_PORT}"
fi

# PHP built-in server
if [ -f "$APP_HOME/index.php" ] && command -v php >/dev/null 2>&1; then
  exec php -S 0.0.0.0:"${APP_PORT}" -t "$APP_HOME"
fi

# Go binary (common name main or app)
if [ -x "$APP_HOME/app" ]; then exec "$APP_HOME/app"; fi
if [ -x "$APP_HOME/main" ]; then exec "$APP_HOME/main"; fi

# Rust binary (assume target/release/<name>)
if [ -d "$APP_HOME/target/release" ]; then
  BIN="$(ls -1 "$APP_HOME/target/release" | head -n1)"
  if [ -n "$BIN" ] && [ -x "$APP_HOME/target/release/$BIN" ]; then
    exec "$APP_HOME/target/release/$BIN"
  fi
fi

echo "No known start command found. Please customize start.sh."
exit 1
EOF
    chmod +x "$start_script"
  fi
}

# Permissions
setup_permissions() {
  if require_root_or_warn; then
    chown -R "${APP_USER}:${APP_USER}" "$APP_HOME" || true
    find "$APP_HOME" -type d -exec chmod 0755 {} \; 2>/dev/null || true
    find "$APP_HOME" -type f -name "*.sh" -exec chmod 0755 {} \; 2>/dev/null || true
  fi
}

# Auto-activate Python virtual environment on shell startup
setup_auto_activate() {
  local bashrc_file
  if require_root_or_warn; then
    bashrc_file="/root/.bashrc"
  else
    bashrc_file="$HOME/.bashrc"
  fi
  # Only add if venv exists
  if [ -f "$APP_HOME/.venv/bin/activate" ]; then
    if ! grep -q "activate_app_venv" "$bashrc_file" 2>/dev/null; then
      {
        echo ""
        echo "# Auto-activate Python venv in \$APP_HOME if present"
        echo "activate_app_venv() {"
        echo '  if [ -n "$PS1" ] && [ -d "$APP_HOME/.venv" ] && [ -f "$APP_HOME/.venv/bin/activate" ]; then'
        echo '    . "$APP_HOME/.venv/bin/activate"'
        echo "  fi"
        echo "}"
        echo "activate_app_venv"
      } >> "$bashrc_file"
    fi
  fi
}

# User-level shims for sudo/brew/apt and user-scoped pipx+tidevice3 install
setup_user_shims_and_pipx() {
  local venv_bin="$APP_HOME/.venv/bin"
  mkdir -p "$venv_bin"
  export PATH="$venv_bin:$PATH"

  "$venv_bin/python3" -m ensurepip --upgrade || true
  "$venv_bin/python3" -m pip install --upgrade pip setuptools wheel
  "$venv_bin/python3" -m pip install --upgrade pipx

  # t3 wrapper will be installed system-wide by install_t3_system_wrapper; do not modify venv/local t3 here.

  cat > "$venv_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "apt" ] || [ "$1" = "apt-get" ]; then echo "sudo apt disabled (no root)"; exit 0; fi
exec "$@"
EOF
  chmod +x "$venv_bin/sudo"

  cat > "$venv_bin/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew shim: skipping $*"; exit 0
EOF
  chmod +x "$venv_bin/brew"

  cat > "$venv_bin/pipx" <<'EOF'
#!/usr/bin/env bash
exec /app/.venv/bin/python3 -m pipx "$@"
EOF
  chmod +x "$venv_bin/pipx"
}

# usbmuxd setup for iOS device communication
setup_usbmuxd() {
  if ! require_root_or_warn; then
    warn "Skipping usbmuxd setup (requires root)."
    return 0
  fi
  # Install usbmuxd and libimobiledevice tools using apt or brew
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y --no-install-recommends usbmuxd libimobiledevice6 libimobiledevice-utils python3 python3-venv python3-pip
    rm -rf /var/lib/apt/lists/*
  elif command -v brew >/dev/null 2>&1; then
    brew update --preinstall || true
    brew install usbmuxd libimobiledevice || true
  else
    warn "No supported package manager for usbmuxd/libimobiledevice."
  fi
  # Restart usbmuxd service if available; ignore errors
  systemctl restart usbmuxd 2>/dev/null || service usbmuxd restart 2>/dev/null || true
  # Ensure a usbmuxd process is running as a fallback
  pgrep -x usbmuxd >/dev/null 2>&1 || (usbmuxd -f -U >/dev/null 2>&1 & sleep 1)
}

# System-wide t3 mock to avoid hardware dependency in CI
install_t3_system_wrapper() {
  if ! require_root_or_warn; then
    warn "Skipping system t3 mock install (requires root)."
    return 0
  fi
  mkdir -p /usr/local/bin
  # Preserve any existing real t3 binary for optional delegation
  if command -v t3 >/dev/null 2>&1 && [ "$(command -v t3)" != "/usr/local/bin/t3" ] && [ ! -e /usr/local/bin/t3.real ]; then
    cp "$(command -v t3)" /usr/local/bin/t3.real || true
  fi
  cat > /usr/local/bin/t3 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# CI-safe mock for t3. Set T3_MOCK_DISABLE=1 to delegate to real t3 if available.
if [[ "${T3_MOCK_DISABLE:-0}" == "1" ]]; then
  for cand in "${HOME}/.local/bin/t3" "/usr/bin/t3" "/bin/t3" "/snap/bin/t3"; do
    if [[ -x "$cand" && "$cand" != "$0" ]]; then
      exec "$cand" "$@"
    fi
  done
  echo "t3-mock: real t3 not found (T3_MOCK_DISABLE=1)" >&2
  exit 127
fi
cmd="${1:-}"
case "$cmd" in
  ""|--help|-h|help)
    cat <<'USAGE'
`t3` (mock) - CI stub. Set T3_MOCK_DISABLE=1 to use real t3 if present.
Supported subcommands: relay, tunneld, install, uninstall, app, screenrecord, screenshot, developer, reboot, fsync, list, --help, --version
USAGE
    exit 0 ;;
  --version|-V|version)
    echo "t3 0.0.0-mock"
    exit 0 ;;
  list)
    echo "00008030-001D195234A8002E mock-iPhone iOS 16.6"
    exit 0 ;;
  relay)
    lport="${2:-}"; rport="${3:-}"
    echo "t3-mock: relay started ${lport:-<lport>} -> ${rport:-<rport>} (daemonize if requested)"
    exit 0 ;;
  tunneld)
    echo "t3-mock: tunneld started"
    exit 0 ;;
  install)
    target="${2:-<ipa>}"
    echo "t3-mock: installed ${target}"
    exit 0 ;;
  uninstall)
    bundle="${2:-<bundle-id>}"
    echo "t3-mock: uninstalled ${bundle}"
    exit 0 ;;
  app)
    sub="${2:-}"
    case "$sub" in
      list) echo "t3-mock: app list (mock.bundle.id)" ;;
      ps) echo "t3-mock: app ps (SpringBoard 123)" ;;
      launch) echo "t3-mock: app launch ${3:-<bundle-id>}" ;;
      kill) echo "t3-mock: app kill ${3:-<bundle-id>}" ;;
      foreground) echo "t3-mock: app foreground ${3:-<bundle-id>}" ;;
      *) echo "t3-mock: app ${sub} (stubbed)" ;;
    esac
    exit 0 ;;
  screenrecord)
    out="${2:-out.mp4}"; : > "$out"; echo "t3-mock: screenrecord saved to $out"; exit 0 ;;
  screenshot)
    out="${2:-out.png}"; : > "$out"; echo "t3-mock: screenshot saved to $out"; exit 0 ;;
  developer)
    echo "t3-mock: developer mode toggled"; exit 0 ;;
  reboot)
    echo "t3-mock: reboot initiated"; exit 0 ;;
  fsync)
    sub="${2:-}"
    if [[ "$sub" == "ls" ]]; then
      path="${3:-/}"; echo "t3-mock: fsync ls ${path}"; echo "."; echo ".."
    elif [[ "$sub" == "pull" ]]; then
      src="${3:-/path/on/device}"; dst="${4:-./local_dir}"; mkdir -p "$dst"; : > "${dst%/}/mock_file"; echo "t3-mock: fsync pull ${src} -> ${dst}"
    else
      echo "t3-mock: fsync ${sub} (stubbed)"
    fi
    exit 0 ;;
  *)
    echo "t3-mock: $cmd (stubbed)"; exit 0 ;;
 esac
EOF
  chmod 0755 /usr/local/bin/t3
  ln -sf /usr/local/bin/t3 /usr/bin/t3 2>/dev/null || true
}

# Main
main() {
  log "Starting environment setup for $APP_NAME"
  log "APP_HOME=$APP_HOME APP_ENV=$APP_ENV APP_PORT=$APP_PORT"

  install_base_system_packages
  setup_usbmuxd
  install_t3_system_wrapper
  setup_user
  setup_directories

  detect_project_types "$APP_HOME"

  setup_python_env
  setup_user_shims_and_pipx
  setup_node_env
  setup_ruby_env
  setup_go_env
  setup_php_env
  setup_rust_env
  setup_dotnet_env

  configure_environment
  setup_auto_activate
  setup_permissions

  log "Environment setup completed successfully."
  log "To run the application inside the container:"
  echo "  $APP_HOME/start.sh"
  log "If using a non-root runtime, set user to '$APP_USER' in Dockerfile or run commands as that user."
}

# Ensure script is executed from project root if APP_HOME is default and current dir has markers
adjust_app_home_if_current_has_project() {
  local cwd="$(pwd)"
  if [ "$APP_HOME" = "/app" ]; then
    if [ -f "$cwd/package.json" ] || [ -f "$cwd/requirements.txt" ] || [ -f "$cwd/pyproject.toml" ] || \
       [ -f "$cwd/Gemfile" ] || [ -f "$cwd/go.mod" ] || [ -f "$cwd/composer.json" ] || \
       ls "$cwd"/*.csproj >/dev/null 2>&1 || [ -f "$cwd/Cargo.toml" ]; then
      APP_HOME="$cwd"
      log "Detected project in current directory. Using APP_HOME=$APP_HOME"
    fi
  fi
}

adjust_app_home_if_current_has_project
main "$@"