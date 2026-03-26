#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects common project types and installs appropriate runtimes and dependencies.
# Safe to run multiple times (idempotent), with robust logging and error handling.

set -Eeuo pipefail

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Global defaults
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}
export LC_ALL=${LC_ALL:-C.UTF-8}
export LANG=${LANG:-C.UTF-8}

# Logging functions
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }

log() {
  echo "${GREEN}[$(timestamp)] $*${NC}"
}

warn() {
  echo "${YELLOW}[$(timestamp)] [WARN] $*${NC}" >&2
}

err() {
  echo "${RED}[$(timestamp)] [ERROR] $*${NC}" >&2
}

die() {
  err "$*"
  exit 1
}

# Error trap for debugging
trap 'err "An error occurred at line $LINENO while executing: ${BASH_COMMAND}"' ERR

# Determine script and project root
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"

# Determine user/group (Docker often runs as root)
RUN_UID="$(id -u)"
RUN_GID="$(id -g)"
RUN_USER="$(id -un || echo root)"
RUN_GROUP="$(id -gn || echo root)"

# Package manager detection
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_EXISTS_CMD=""

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_EXISTS_CMD="dpkg -s"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_EXISTS_CMD="apk info -e"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf makecache -y"
    PKG_INSTALL="dnf install -y"
    PKG_EXISTS_CMD="rpm -q"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum makecache -y"
    PKG_INSTALL="yum install -y"
    PKG_EXISTS_CMD="rpm -q"
  else
    die "No supported package manager found. Supported: apt, apk, dnf, yum."
  fi
  log "Detected package manager: $PKG_MANAGER"
}

pkg_update_once() {
  # Use a lock file to avoid repeated updates in idempotent runs
  local lock="/var/cache/.pkg_update_done"
  if [[ -f "$lock" ]]; then
    log "Package index already updated."
    return 0
  fi
  log "Updating package index..."
  eval "$PKG_UPDATE"
  mkdir -p "$(dirname "$lock")"
  touch "$lock"
}

pkg_installed() {
  # Check if a package is installed (best-effort)
  local pkg="$1"
  case "$PKG_MANAGER" in
    apt)
      dpkg -s "$pkg" >/dev/null 2>&1
      ;;
    apk)
      apk info -e "$pkg" >/dev/null 2>&1
      ;;
    dnf|yum)
      rpm -q "$pkg" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

pkg_install() {
  if [[ $# -eq 0 ]]; then return 0; fi
  local to_install=()
  for pkg in "$@"; do
    if pkg_installed "$pkg"; then
      log "Package '$pkg' already installed."
    else
      to_install+=("$pkg")
    fi
  done
  if [[ ${#to_install[@]} -gt 0 ]]; then
    log "Installing system packages: ${to_install[*]}"
    eval "$PKG_INSTALL ${to_install[*]}"
  else
    log "All requested system packages are already installed."
  fi
}

# Provide a harmless Homebrew stub if brew is not installed
ensure_brew_stub() {
  if ! command -v brew >/dev/null 2>&1; then
    mkdir -p /usr/local/bin
    printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/brew
    chmod +x /usr/local/bin/brew
  fi
}

# Common system dependencies
install_common_system_deps() {
  log "Installing common system dependencies..."

  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git gnupg unzip zip xz-utils
      pkg_install build-essential pkg-config libssl-dev libffi-dev zlib1g-dev
      ;;
    apk)
      pkg_install ca-certificates curl git unzip zip xz
      pkg_install build-base pkgconfig openssl-dev libffi-dev zlib-dev
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git unzip zip xz
      pkg_install gcc gcc-c++ make pkgconfig openssl-devel libffi-devel zlib-devel
      ;;
  esac

  # Ensure CA certificates up to date
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi
}

# Environment directories
setup_directories() {
  log "Setting up project directories at $PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,.cache}
  chmod 755 "$PROJECT_ROOT"
  chmod -R 775 "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/.cache"
  chown -R "$RUN_UID":"$RUN_GID" "$PROJECT_ROOT" || true
}

# .env setup
setup_env_file() {
  local env_file="$PROJECT_ROOT/.env"
  if [[ ! -f "$env_file" ]]; then
    log "Creating default .env file"
    cat > "$env_file" <<EOF
APP_NAME=${APP_NAME:-app}
APP_ENV=${APP_ENV:-production}
APP_DEBUG=${APP_DEBUG:-false}
APP_PORT=${APP_PORT:-8080}
# Add more env vars as needed by your project
EOF
    chown "$RUN_UID":"$RUN_GID" "$env_file" || true
    chmod 640 "$env_file" || true
  else
    log ".env file already exists"
  fi
}

# Persist environment configuration for shells
persist_profile_env() {
  local profile="/etc/profile.d/project_env.sh"
  log "Persisting environment and PATH configuration to $profile"
  cat > "$profile" <<'EOF'
# Project environment profile
export LC_ALL=${LC_ALL:-C.UTF-8}
export LANG=${LANG:-C.UTF-8}
export APP_ENV=${APP_ENV:-production}
export APP_PORT=${APP_PORT:-8080}

# NVM/Node
export NVM_DIR=${NVM_DIR:-/usr/local/nvm}
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
fi

# Go
export GOROOT=${GOROOT:-/usr/local/go}
export GOPATH=${GOPATH:-/workspace/go}
export PATH="$PATH:$GOROOT/bin:$GOPATH/bin"

# Rust
export CARGO_HOME=${CARGO_HOME:-/usr/local/cargo}
export RUSTUP_HOME=${RUSTUP_HOME:-/usr/local/rustup}
export PATH="$PATH:$CARGO_HOME/bin"

# .NET
export DOTNET_ROOT=${DOTNET_ROOT:-/usr/local/dotnet}
export PATH="$PATH:$DOTNET_ROOT"
EOF
  chmod 644 "$profile"
}

# Python setup
setup_python() {
  local has_python="false"
  if [[ -f "$PROJECT_ROOT/requirements.txt" || -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/Pipfile" ]]; then
    has_python="true"
  fi
  [[ "$has_python" == "false" ]] && return 0

  log "Detected Python project files."
  case "$PKG_MANAGER" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev
      # On Alpine, venv is part of python3
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel
      ;;
  esac

  # Ensure pip is up to date
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel || true
  fi

  # Virtual environment
  VENV_DIR="$PROJECT_ROOT/.venv"
  if [[ -d "$VENV_DIR" ]]; then
    log "Python virtual environment already exists at $VENV_DIR"
  else
    log "Creating Python virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  # Activate venv for installation
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  # Poetry or Pipenv detection
  if [[ -f "$PROJECT_ROOT/pyproject.toml" ]] && grep -qi '\[tool.poetry\]' "$PROJECT_ROOT/pyproject.toml"; then
    log "Detected Poetry configuration. Installing Poetry..."
    python3 -m pip install --no-cache-dir "poetry>=1.6"
    log "Installing Python dependencies with Poetry"
    (cd "$PROJECT_ROOT" && poetry install --no-root --no-interaction)
  elif [[ -f "$PROJECT_ROOT/Pipfile" ]]; then
    log "Detected Pipenv configuration. Installing Pipenv..."
    python3 -m pip install --no-cache-dir "pipenv>=2023.0.0"
    log "Installing Python dependencies with Pipenv"
    (cd "$PROJECT_ROOT" && pipenv install --deploy)
  elif [[ -f "$PROJECT_ROOT/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    python3 -m pip install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt"
  else
    warn "No recognized Python dependency file found. Skipping dependency installation."
  fi

  deactivate || true

  # Environment variables defaults for Python web apps
  export FLASK_ENV=${FLASK_ENV:-production}
  export PYTHONUNBUFFERED=1

  # Permissions
  chown -R "$RUN_UID":"$RUN_GID" "$VENV_DIR" || true
}

# Auto-activate project Python virtual environment for interactive shells
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_dir="$PROJECT_ROOT/.venv"
  local profile="/etc/profile.d/zz_project_venv.sh"
  # Create profile.d script to auto-activate when interactive and no existing venv
  {
    echo "# Auto-activate project venv if present"
    echo "if [ -z \"\$CI\" ] && [ -t 1 ] && [ -d \"$venv_dir\" ] && [ -z \"\$VIRTUAL_ENV\" ]; then"
    echo "  . \"$venv_dir/bin/activate\""
    echo "fi"
  } > "$profile"
  chmod 644 "$profile" || true
  # Append to .bashrc if not present
  local activate_line=". \"$venv_dir/bin/activate\""
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate Python virtual environment"
      echo "if [ -f \"$venv_dir/bin/activate\" ]; then $activate_line; fi"
    } >> "$bashrc_file"
  fi
}

# Goose CLI setup using dedicated venv (bypass pipx)
setup_goose_cli() {
  log "Setting up goose CLI in dedicated virtual environment"

  # Ensure Python tooling via apt when available
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y python3-venv python3-pip pipx
  fi

  # Provide a harmless Homebrew stub if brew is not installed
  [ -x "$(command -v brew)" ] || { printf '#!/bin/sh\nexit 0\n' >/usr/local/bin/brew && chmod +x /usr/local/bin/brew; }

  # Create venv for goose and install required packages in /opt/goose2
  [ -d /opt/goose2 ] || python3 -m venv /opt/goose2
  /opt/goose2/bin/pip install --upgrade pip setuptools wheel
  /opt/goose2/bin/pip install --upgrade goose-ai "langfuse>=2,<3"

  # Expose goose on PATH
  ln -sf /opt/goose2/bin/goose /usr/local/bin/goose
}

# Node.js setup via NVM (distro-independent)
setup_node() {
  if [[ ! -f "$PROJECT_ROOT/package.json" ]]; then
    return 0
  fi
  log "Detected Node.js project (package.json). Setting up Node via NVM..."

  export NVM_DIR="${NVM_DIR:-/usr/local/nvm}"
  if [[ ! -d "$NVM_DIR" ]]; then
    log "Installing NVM to $NVM_DIR"
    mkdir -p "$NVM_DIR"
    # Install NVM
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    # Move to /usr/local/nvm if installed to root's home
    if [[ -d "/root/.nvm" && "$NVM_DIR" != "/root/.nvm" ]]; then
      mv /root/.nvm/* "$NVM_DIR"/ || true
      rm -rf /root/.nvm || true
    fi
  else
    log "NVM already present at $NVM_DIR"
  fi

  # Load NVM
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"

  # Install latest LTS Node and use it
  if ! command -v node >/dev/null 2>&1; then
    log "Installing latest LTS Node.js"
    nvm install --lts
    nvm alias default 'lts/*'
  else
    log "Node.js already installed: $(node -v)"
  fi
  nvm use default >/dev/null

  # Enable Corepack for Yarn/PNPM if available (Node >= 16.10)
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Install dependencies
  if [[ -f "$PROJECT_ROOT/yarn.lock" ]]; then
    log "Installing Node dependencies with Yarn (frozen lockfile)"
    (cd "$PROJECT_ROOT" && if command -v yarn >/dev/null 2>&1; then yarn install --frozen-lockfile; else npx yarn install --frozen-lockfile; fi)
  elif [[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]]; then
    log "Installing Node dependencies with PNPM (frozen lockfile)"
    (cd "$PROJECT_ROOT" && if command -v pnpm >/dev/null 2>&1; then pnpm install --frozen-lockfile; else npx pnpm install --frozen-lockfile; fi)
  elif [[ -f "$PROJECT_ROOT/package-lock.json" ]]; then
    log "Installing Node dependencies with npm ci"
    (cd "$PROJECT_ROOT" && npm ci --no-audit --no-fund)
  else
    log "Installing Node dependencies with npm install"
    (cd "$PROJECT_ROOT" && npm install --no-audit --no-fund)
  fi

  # Environment variables
  export NODE_ENV=${NODE_ENV:-production}

  # Permissions
  chown -R "$RUN_UID":"$RUN_GID" "$PROJECT_ROOT/node_modules" || true
}

# Ruby setup
setup_ruby() {
  if [[ ! -f "$PROJECT_ROOT/Gemfile" ]]; then
    return 0
  fi
  log "Detected Ruby project (Gemfile). Installing Ruby and Bundler..."

  case "$PKG_MANAGER" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
  esac

  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  log "Installing Ruby gems with Bundler"
  (cd "$PROJECT_ROOT" && bundle config set path 'vendor/bundle' && bundle install --jobs 4 --retry 3)

  chown -R "$RUN_UID":"$RUN_GID" "$PROJECT_ROOT/vendor" || true
}

# Go setup
setup_go() {
  if [[ ! -f "$PROJECT_ROOT/go.mod" ]]; then
    return 0
  fi
  log "Detected Go project (go.mod). Installing Go..."

  case "$PKG_MANAGER" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum)
      pkg_install golang
      ;;
  esac

  if ! command -v go >/dev/null 2>&1; then
    die "Go installation failed; 'go' not found in PATH."
  fi

  export GOPATH="${GOPATH:-/workspace/go}"
  mkdir -p "$GOPATH"
  log "Downloading Go module dependencies"
  (cd "$PROJECT_ROOT" && go mod download)

  chown -R "$RUN_UID":"$RUN_GID" "$GOPATH" || true
}

# Java (Maven/Gradle) setup
setup_java() {
  local is_maven="false"
  local is_gradle="false"
  [[ -f "$PROJECT_ROOT/pom.xml" || -f "$PROJECT_ROOT/mvnw" ]] && is_maven="true"
  [[ -f "$PROJECT_ROOT/build.gradle" || -f "$PROJECT_ROOT/gradlew" ]] && is_gradle="true"
  if [[ "$is_maven" == "false" && "$is_gradle" == "false" ]]; then
    return 0
  fi

  log "Detected Java project. Installing JDK 17 and build tools..."

  case "$PKG_MANAGER" in
    apt)
      pkg_install openjdk-17-jdk
      ;;
    apk)
      pkg_install openjdk17
      ;;
    dnf|yum)
      pkg_install java-17-openjdk java-17-openjdk-devel
      ;;
  esac

  export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  export PATH="$PATH:$JAVA_HOME/bin"

  if [[ "$is_maven" == "true" ]]; then
    case "$PKG_MANAGER" in
      apt) pkg_install maven ;;
      apk) pkg_install maven ;;
      dnf|yum) pkg_install maven ;;
    esac
    log "Pre-fetching Maven dependencies (go-offline)"
    (cd "$PROJECT_ROOT" && if [[ -x "./mvnw" ]]; then ./mvnw -q -DskipTests dependency:go-offline; else mvn -q -DskipTests dependency:go-offline; fi)
  fi

  if [[ "$is_gradle" == "true" ]]; then
    log "Preparing Gradle dependencies"
    (cd "$PROJECT_ROOT" && if [[ -x "./gradlew" ]]; then ./gradlew --no-daemon build -x test || ./gradlew --no-daemon assemble; else
      # Install gradle if wrapper not present
      case "$PKG_MANAGER" in
        apt) pkg_install gradle ;;
        apk) pkg_install gradle ;;
        dnf|yum) pkg_install gradle ;;
      esac
      gradle --no-daemon build -x test || gradle --no-daemon assemble
    fi)
  fi
}

# PHP setup
setup_php() {
  if [[ ! -f "$PROJECT_ROOT/composer.json" ]]; then
    return 0
  fi
  log "Detected PHP project (composer.json). Installing PHP CLI and Composer..."

  case "$PKG_MANAGER" in
    apt)
      pkg_install php-cli php-zip php-mbstring unzip
      ;;
    apk)
      pkg_install php81 php81-cli php81-mbstring php81-zip
      ;;
    dnf|yum)
      pkg_install php-cli php-zip php-mbstring unzip
      ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  log "Installing PHP dependencies with Composer"
  (cd "$PROJECT_ROOT" && composer install --no-interaction --prefer-dist --no-progress)
  chown -R "$RUN_UID":"$RUN_GID" "$PROJECT_ROOT/vendor" || true
}

# Rust setup
setup_rust() {
  if [[ ! -f "$PROJECT_ROOT/Cargo.toml" ]]; then
    return 0
  fi
  log "Detected Rust project (Cargo.toml). Installing Rust via rustup..."

  export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"

  if ! command -v rustup >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
    sh /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal
    rm -f /tmp/rustup-init.sh
  else
    log "rustup already installed"
  fi

  # Ensure PATH includes cargo
  export PATH="$PATH:$CARGO_HOME/bin"
  rustup default stable || true
  log "Fetching Rust crate dependencies"
  (cd "$PROJECT_ROOT" && cargo fetch)
  chown -R "$RUN_UID":"$RUN_GID" "$CARGO_HOME" "$RUSTUP_HOME" || true
}

# .NET setup
setup_dotnet() {
  local has_dotnet="false"
  if compgen -G "$PROJECT_ROOT/*.sln" >/dev/null || compgen -G "$PROJECT_ROOT/*.csproj" >/dev/null; then
    has_dotnet="true"
  fi
  [[ "$has_dotnet" == "false" ]] && return 0

  log "Detected .NET project (.sln/.csproj). Installing .NET SDK via official installer..."
  export DOTNET_ROOT="${DOTNET_ROOT:-/usr/local/dotnet}"
  mkdir -p "$DOTNET_ROOT"

  if ! command -v dotnet >/dev/null 2>&1; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --install-dir "$DOTNET_ROOT" --channel LTS
    rm -f /tmp/dotnet-install.sh
  else
    log ".NET SDK already installed: $(dotnet --version)"
  fi

  export PATH="$PATH:$DOTNET_ROOT"
  log "Restoring .NET project dependencies"
  (cd "$PROJECT_ROOT" && dotnet restore)
}

# Permissions and umask
setup_permissions() {
  log "Setting file permissions for $PROJECT_ROOT"
  chown -R "$RUN_UID":"$RUN_GID" "$PROJECT_ROOT" || true
  chmod -R g+rwX "$PROJECT_ROOT" || true
  umask 002
}

# Summary output
summary() {
  echo ""
  echo "${BLUE}========== Setup Summary ==========${NC}"
  echo "Project root: $PROJECT_ROOT"
  echo "User: $RUN_USER (uid=$RUN_UID) Group: $RUN_GROUP (gid=$RUN_GID)"
  echo "Package manager: $PKG_MANAGER"
  echo "Installed runtimes (if detected):"
  command -v python3 >/dev/null 2>&1 && echo " - Python: $(python3 --version 2>/dev/null)"
  [[ -f "$PROJECT_ROOT/.venv/bin/python" ]] && echo "   Virtualenv: $PROJECT_ROOT/.venv"
  command -v node >/dev/null 2>&1 && echo " - Node.js: $(node -v 2>/dev/null)"
  command -v ruby >/dev/null 2>&1 && echo " - Ruby: $(ruby --version 2>/dev/null)"
  command -v go >/dev/null 2>&1 && echo " - Go: $(go version 2>/dev/null)"
  command -v javac >/dev/null 2>&1 && echo " - Java: $(javac -version 2>&1)"
  command -v php >/dev/null 2>&1 && echo " - PHP: $(php -v | head -n1)"
  command -v rustc >/dev/null 2>&1 && echo " - Rust: $(rustc --version 2>/dev/null)"
  command -v dotnet >/dev/null 2>&1 && echo " - .NET: $(dotnet --version 2>/dev/null)"
  echo "Environment persisted in: /etc/profile.d/project_env.sh"
  echo "Default .env: $PROJECT_ROOT/.env"
  echo "${BLUE}====================================${NC}"
}

main() {
  log "Starting universal environment setup for project at: $PROJECT_ROOT"

  # Pre-flight: ensure running as root when needed
  if [[ "$RUN_UID" -ne 0 ]]; then
    warn "Script is not running as root. System package installation may fail inside Docker without sudo."
  fi

  ensure_brew_stub
  detect_pkg_manager
  pkg_update_once
  install_common_system_deps

  setup_directories
  setup_env_file
  persist_profile_env

  # Language/runtime setups
  setup_python
  setup_auto_activate
  setup_goose_cli
  setup_node
  setup_ruby
  setup_go
  setup_java
  setup_php
  setup_rust
  setup_dotnet

  setup_permissions
  summary

  log "Environment setup completed successfully."
}

main "$@"