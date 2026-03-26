#!/usr/bin/env bash
# Project Environment Setup Script for Docker Containers
# This script attempts to auto-detect the project type and install required runtimes,
# system packages, and dependencies. It is designed to be idempotent and safe to re-run.

set -Eeuo pipefail
IFS=$'\n\t'

# Globals and defaults
APP_DIR="${APP_DIR:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"
LOG_LEVEL="${LOG_LEVEL:-info}" # info|debug
OS_ID=""
PKG_MGR=""
UPDATED_FLAG="/var/tmp/setup_env_updated.flag"
ENV_FILE="$APP_DIR/.env.container"
CACHE_DIR="${CACHE_DIR:-/var/cache/project-setup}"
RUNTIME_USER="${RUNTIME_USER:-}" # Optional non-root user name, if container runs as that user
export LC_ALL=C
export LANG=C

# Colors (non-bold to avoid issues in minimal terminals)
NC="$(printf '\033[0m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[0;33m')"
RED="$(printf '\033[0;31m')"

log() {
  local level="${2:-info}"
  if [[ "$LOG_LEVEL" == "debug" || "$level" != "debug" ]]; then
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
  fi
}

warn() {
  echo -e "${YELLOW}[WARNING] $1${NC}" >&2
}

err() {
  echo -e "${RED}[ERROR] $1${NC}" >&2
}

die() {
  err "$1"
  exit "${2:-1}"
}

on_error() {
  local exit_code=$?
  err "Script failed at line ${BASH_LINENO[0]} in function ${FUNCNAME[1]:-main} with exit code $exit_code"
  exit "$exit_code"
}

on_exit() {
  log "Environment setup script finished." "debug"
}

trap on_error ERR
trap on_exit EXIT

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Detect OS / Package Manager
detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  else
    OS_ID="unknown"
  fi

  if cmd_exists apt-get; then
    PKG_MGR="apt"
  elif cmd_exists apk; then
    PKG_MGR="apk"
  elif cmd_exists dnf; then
    PKG_MGR="dnf"
  elif cmd_exists yum; then
    PKG_MGR="yum"
  elif cmd_exists microdnf; then
    PKG_MGR="microdnf"
  else
    PKG_MGR="none"
  fi

  log "Detected OS: ${OS_ID}, Package Manager: ${PKG_MGR}" "debug"
}

pkg_update() {
  if [[ -f "$UPDATED_FLAG" ]]; then
    log "Package index already updated, skipping." "debug"
    return
  fi
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      touch "$UPDATED_FLAG"
      ;;
    apk)
      apk update || true
      touch "$UPDATED_FLAG"
      ;;
    dnf)
      dnf makecache -y || true
      touch "$UPDATED_FLAG"
      ;;
    yum)
      yum makecache -y || true
      touch "$UPDATED_FLAG"
      ;;
    microdnf)
      microdnf update -y || true
      touch "$UPDATED_FLAG"
      ;;
    *)
      warn "No supported package manager detected; system package installation may be skipped."
      ;;
  esac
}

pkg_install() {
  # Install packages passed as arguments, best effort across PMs
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -eq 0 ]] && return 0

  case "$PKG_MGR" in
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
    microdnf)
      microdnf install -y "${pkgs[@]}"
      ;;
    *)
      warn "Cannot install packages (${pkgs[*]}): unsupported package manager."
      ;;
  esac
}

install_base_tools() {
  log "Installing base system tools and build dependencies..."
  mkdir -p "$CACHE_DIR" || true

  pkg_update

  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git tar xz-utils gzip unzip expect util-linux
      pkg_install build-essential pkg-config
      pkg_install libssl-dev libffi-dev zlib1g-dev
      ;;
    apk)
      pkg_install ca-certificates curl git tar xz gzip unzip
      pkg_install build-base pkgconf
      pkg_install openssl-dev libffi-dev zlib-dev
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl git tar xz gzip unzip
      pkg_install gcc gcc-c++ make pkgconfig
      pkg_install openssl-devel libffi-devel zlib-devel
      ;;
    *)
      warn "Skipping base tools installation due to unsupported package manager."
      ;;
  esac

  log "Base system tools installation completed."
}

# Directory setup & permissions
setup_project_dir() {
  log "Setting up project directory at $APP_DIR ..."
  mkdir -p "$APP_DIR"
  # If running as a non-root user inside container, set ownership accordingly
  if [[ -n "$RUNTIME_USER" ]] && id "$RUNTIME_USER" >/dev/null 2>&1; then
    chown -R "$RUNTIME_USER":"$RUNTIME_USER" "$APP_DIR"
  else
    chown -R "$(id -u)":"$(id -g)" "$APP_DIR"
  fi
  chmod 755 "$APP_DIR"
  mkdir -p "$APP_DIR/log" "$APP_DIR/tmp" "$APP_DIR/.cache"
  log "Project directory structure prepared."
}

# Environment file setup
write_env_file() {
  log "Configuring environment file at $ENV_FILE ..."
  {
    echo "export APP_DIR=\"$APP_DIR\""
    echo "export APP_ENV=\"$APP_ENV\""
    echo "export APP_PORT=\"$APP_PORT\""
    echo "export PATH=\"$APP_DIR/bin:\$PATH\""
    echo "export HTTP_PROXY=\"${HTTP_PROXY:-}\""
    echo "export HTTPS_PROXY=\"${HTTPS_PROXY:-}\""
    echo "export NO_PROXY=\"${NO_PROXY:-}\""
  } > "$ENV_FILE"
  chmod 644 "$ENV_FILE"
  log "Environment file prepared."
}

# Project type detection
has_file() {
  [[ -f "$APP_DIR/$1" ]]
}

detect_python() {
  if has_file "requirements.txt" || has_file "pyproject.toml" || has_file "Pipfile"; then
    echo "1"; return 0
  fi
  echo "0"
}

detect_node() {
  if has_file "package.json"; then
    echo "1"; return 0
  fi
  echo "0"
}

detect_ruby() {
  if has_file "Gemfile"; then
    echo "1"; return 0
  fi
  echo "0"
}

detect_go() {
  if has_file "go.mod"; then
    echo "1"; return 0
  fi
  echo "0"
}

detect_rust() {
  if has_file "Cargo.toml"; then
    echo "1"; return 0
  fi
  echo "0"
}

detect_php() {
  if has_file "composer.json"; then
    echo "1"; return 0
  fi
  echo "0"
}

detect_java() {
  if has_file "pom.xml" || has_file "build.gradle" || has_file "build.gradle.kts"; then
    echo "1"; return 0
  fi
  echo "0"
}

detect_dotnet() {
  # Look for any .csproj or .sln
  if compgen -G "$APP_DIR/*.csproj" >/dev/null || compgen -G "$APP_DIR/*.sln" >/dev/null; then
    echo "1"; return 0
  fi
  echo "0"
}

# Python setup
setup_python() {
  log "Detected Python project. Setting up Python environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      pkg_install python3 py3-pip
      ;;
    dnf|yum|microdnf)
      pkg_install python3 python3-pip python3-devel
      ;;
    *)
      warn "Could not ensure Python installation via package manager."
      ;;
  esac

  if ! cmd_exists python3; then
    die "Python3 not available in this container. Please use a Python base image or install Python manually."
  fi

  # Create virtual environment idempotently
  if [[ ! -d "$APP_DIR/.venv" ]]; then
    log "Creating virtual environment at $APP_DIR/.venv ..."
    python3 -m venv "$APP_DIR/.venv" || {
      warn "Python venv creation failed. Falling back to system pip installation."
    }
  else
    log "Virtual environment already exists. Skipping creation."
  fi

  PIP_BIN="pip3"
  if [[ -x "$APP_DIR/.venv/bin/pip" ]]; then
    PIP_BIN="$APP_DIR/.venv/bin/pip"
    # Append venv exports to env file
    {
      echo "export VIRTUAL_ENV=\"$APP_DIR/.venv\""
      echo "export PATH=\"$APP_DIR/.venv/bin:\$PATH\""
      echo "export PYTHONPATH=\"$APP_DIR:\$PYTHONPATH\""
    } >> "$ENV_FILE"
  fi

  "$PIP_BIN" --version || true
  "$PIP_BIN" install --upgrade pip setuptools wheel || true

  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt ..."
    "$PIP_BIN" install -r "$APP_DIR/requirements.txt"
  elif has_file "Pipfile"; then
    # Optional: pipenv if available
    if ! cmd_exists pipenv; then
      "$PIP_BIN" install pipenv || true
    fi
    if cmd_exists pipenv; then
      (cd "$APP_DIR" && pipenv install --deploy || pipenv install)
    else
      warn "Pipfile found but pipenv not installed; skipping."
    fi
  elif has_file "pyproject.toml"; then
    log "pyproject.toml found. Attempting to install project with pip ..."
    (cd "$APP_DIR" && "$PIP_BIN" install .) || warn "Failed to install from pyproject; dependencies may be managed by Poetry."
    # Try Poetry if pyproject indicates it
    if grep -qi '\[tool.poetry\]' "$APP_DIR/pyproject.toml"; then
      if ! cmd_exists poetry; then
        "$PIP_BIN" install poetry || true
      fi
      if cmd_exists poetry; then
        (cd "$APP_DIR" && poetry install --no-root || poetry install)
        # Add Poetry venv to env file if created
        POETRY_VENV_DIR="$(poetry env info --path 2>/dev/null || true)"
        if [[ -n "$POETRY_VENV_DIR" && -d "$POETRY_VENV_DIR" ]]; then
          {
            echo "export VIRTUAL_ENV=\"$POETRY_VENV_DIR\""
            echo "export PATH=\"$POETRY_VENV_DIR/bin:\$PATH\""
          } >> "$ENV_FILE"
        fi
      fi
    fi
  else
    warn "No Python dependency file found. Skipping dependency installation."
  fi

  # ComfyUI workspace bootstrap under a pseudo-terminal to handle first-run prompts and set a deterministic workspace
  if [[ "${COMFY_BOOTSTRAP:-1}" == "1" ]]; then
    # Ensure required tools exist and allocate TTY for comfy-cli first run
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update && apt-get install -y --no-install-recommends util-linux git curl && rm -rf /var/lib/apt/lists/* || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y util-linux git curl || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache util-linux git curl || true
    fi

    # Upgrade pip, setuptools, wheel, and ensure comfy-cli >= 1.5.4
    python3 -m pip install --upgrade pip setuptools wheel || true
    python3 -m pip install --upgrade --no-cache-dir "comfy-cli>=1.5.4" || true

    local comfy_workspace="/root/comfy"
    mkdir -p "$comfy_workspace"

    # Run comfy commands via 'script' to allocate a PTY and avoid non-interactive aborts
    script -qfc "comfy install --workspace $comfy_workspace" /dev/null || true
    script -qfc "comfy install --workspace $comfy_workspace --skip-manager" /dev/null || true
    script -qfc "comfy node install ComfyUI-Impact-Pack --workspace $comfy_workspace" /dev/null || true
    script -qfc "comfy node update all --workspace $comfy_workspace" /dev/null || true

    # Prime recent workspace and validate without failing the whole setup
    comfy --workspace "$comfy_workspace" env >/dev/null 2>&1 || true
    comfy --workspace="$comfy_workspace" which >/dev/null 2>&1 || true
  fi
  # Default Python app port hint, can be overridden
  if [[ "$APP_PORT" == "8080" ]]; then
    APP_PORT="8000"
    sed -i "s|^export APP_PORT=.*$|export APP_PORT=\"$APP_PORT\"|" "$ENV_FILE" || true
  fi

  log "Python environment setup completed."
}

# Node.js setup
setup_node() {
  log "Detected Node.js project. Setting up Node environment..."

  if ! cmd_exists node || ! cmd_exists npm; then
    case "$PKG_MGR" in
      apt)
        pkg_install nodejs npm
        ;;
      apk)
        pkg_install nodejs npm
        ;;
      dnf|yum|microdnf)
        pkg_install nodejs npm
        ;;
      *)
        warn "Cannot install Node.js via package manager."
        ;;
    esac
  fi

  if ! cmd_exists node; then
    warn "Node.js not available. Consider using a Node base image."
  else
    log "Node.js $(node --version) detected."
  fi

  # Corepack for Yarn/Pnpm (Node >=16)
  if cmd_exists node && node -e 'process.exit(Number(process.versions.node.split(".")[0])<16)' >/dev/null 2>&1; then
    if cmd_exists corepack; then
      corepack enable || true
    fi
  fi

  # Install dependencies using appropriate package manager
  if has_file "yarn.lock"; then
    log "yarn.lock detected."
    if cmd_exists yarn; then
      (cd "$APP_DIR" && yarn install --frozen-lockfile || yarn install)
    else
      if cmd_exists corepack; then
        (cd "$APP_DIR" && corepack prepare yarn@stable --activate && yarn install --frozen-lockfile || yarn install)
      else
        (cd "$APP_DIR" && npm install)
      fi
    fi
  elif has_file "pnpm-lock.yaml"; then
    log "pnpm-lock.yaml detected."
    if cmd_exists pnpm; then
      (cd "$APP_DIR" && pnpm install --frozen-lockfile || pnpm install)
    else
      if cmd_exists corepack; then
        (cd "$APP_DIR" && corepack prepare pnpm@latest --activate && pnpm install --frozen-lockfile || pnpm install)
      else
        (cd "$APP_DIR" && npm install)
      fi
    fi
  elif has_file "package-lock.json"; then
    log "package-lock.json detected. Running npm ci ..."
    (cd "$APP_DIR" && npm ci || npm install)
  elif has_file "package.json"; then
    log "Installing Node dependencies via npm ..."
    (cd "$APP_DIR" && npm install)
  fi

  # Default Node port hint
  if [[ "$APP_PORT" == "8080" ]]; then
    APP_PORT="3000"
    sed -i "s|^export APP_PORT=.*$|export APP_PORT=\"$APP_PORT\"|" "$ENV_FILE" || true
  fi

  log "Node.js environment setup completed."
}

# Ruby setup
setup_ruby() {
  log "Detected Ruby project. Setting up Ruby environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum|microdnf)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      warn "Cannot install Ruby via package manager."
      ;;
  esac

  if ! cmd_exists ruby; then
    warn "Ruby not available. Consider using a Ruby base image."
    return
  fi

  if ! cmd_exists bundle; then
    gem install bundler || true
  fi

  if has_file "Gemfile"; then
    (cd "$APP_DIR" && bundle config set path 'vendor/bundle' && bundle install)
  fi

  if [[ "$APP_PORT" == "8080" ]]; then
    APP_PORT="3000"
    sed -i "s|^export APP_PORT=.*$|export APP_PORT=\"$APP_PORT\"|" "$ENV_FILE" || true
  fi

  log "Ruby environment setup completed."
}

# Go setup
setup_go() {
  log "Detected Go project. Setting up Go environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum|microdnf)
      pkg_install golang
      ;;
    *)
      warn "Cannot install Go via package manager."
      ;;
  esac

  if ! cmd_exists go; then
    warn "Go not available. Consider using a Go base image."
    return
  fi

  {
    echo "export GOPATH=\"/go\""
    echo "export GOCACHE=\"/go/cache\""
    echo "export PATH=\"/go/bin:\$PATH\""
  } >> "$ENV_FILE"
  mkdir -p /go/cache || true

  (cd "$APP_DIR" && go mod download) || warn "go mod download failed or go.mod missing."

  if [[ "$APP_PORT" == "8080" ]]; then
    APP_PORT="8080"
    sed -i "s|^export APP_PORT=.*$|export APP_PORT=\"$APP_PORT\"|" "$ENV_FILE" || true
  fi

  log "Go environment setup completed."
}

# Rust setup
setup_rust() {
  log "Detected Rust project. Setting up Rust environment..."

  if ! cmd_exists cargo; then
    curl -fsSL https://sh.rustup.rs -o "$CACHE_DIR/rustup-init.sh"
    chmod +x "$CACHE_DIR/rustup-init.sh"
    "$CACHE_DIR/rustup-init.sh" -y --no-modify-path || warn "Rustup installation failed."
  fi

  if [[ -d "$HOME/.cargo" ]]; then
    {
      echo "export CARGO_HOME=\"$HOME/.cargo\""
      echo "export RUSTUP_HOME=\"$HOME/.rustup\""
      echo "export PATH=\"$HOME/.cargo/bin:\$PATH\""
    } >> "$ENV_FILE"
  fi

  if cmd_exists cargo; then
    (cd "$APP_DIR" && cargo fetch) || warn "cargo fetch failed."
  else
    warn "Cargo not available. Consider using a Rust base image."
  fi

  if [[ "$APP_PORT" == "8080" ]]; then
    APP_PORT="8080"
    sed -i "s|^export APP_PORT=.*$|export APP_PORT=\"$APP_PORT\"|" "$ENV_FILE" || true
  fi

  log "Rust environment setup completed."
}

# PHP setup
setup_php() {
  log "Detected PHP project. Setting up PHP environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-mbstring php-xml curl
      ;;
    apk)
      pkg_install php-cli php-mbstring php-xml curl
      ;;
    dnf|yum|microdnf)
      pkg_install php-cli php-mbstring php-xml curl
      ;;
    *)
      warn "Cannot install PHP via package manager."
      ;;
  esac

  if ! cmd_exists php; then
    warn "PHP not available. Consider using a PHP base image."
    return
  fi

  # Install Composer if not present
  if ! cmd_exists composer; then
    curl -fsSL https://getcomposer.org/installer -o "$CACHE_DIR/composer-setup.php"
    php "$CACHE_DIR/composer-setup.php" --install-dir=/usr/local/bin --filename=composer || warn "Composer installation failed."
  fi

  if has_file "composer.json"; then
    (cd "$APP_DIR" && composer install --no-interaction --no-progress) || warn "composer install failed."
  fi

  if [[ "$APP_PORT" == "8080" ]]; then
    APP_PORT="8000"
    sed -i "s|^export APP_PORT=.*$|export APP_PORT=\"$APP_PORT\"|" "$ENV_FILE" || true
  fi

  log "PHP environment setup completed."
}

# Java setup
setup_java() {
  log "Detected Java project. Setting up Java environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install default-jdk maven gradle || pkg_install default-jdk maven
      ;;
    apk)
      pkg_install openjdk17-jdk maven gradle || pkg_install openjdk17-jdk maven
      ;;
    dnf|yum|microdnf)
      pkg_install java-11-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven
      ;;
    *)
      warn "Cannot install Java via package manager."
      ;;
  esac

  if ! cmd_exists java; then
    warn "Java not available. Consider using a JDK base image."
    return
  fi

  if has_file "pom.xml"; then
    if [[ -x "$APP_DIR/mvnw" ]]; then
      (cd "$APP_DIR" && ./mvnw -B -q -DskipTests dependency:go-offline) || true
    elif cmd_exists mvn; then
      (cd "$APP_DIR" && mvn -B -q -DskipTests dependency:go-offline) || true
    fi
  fi

  if has_file "build.gradle" || has_file "build.gradle.kts"; then
    if [[ -x "$APP_DIR/gradlew" ]]; then
      (cd "$APP_DIR" && ./gradlew --quiet --no-daemon build -x test || ./gradlew --quiet --no-daemon tasks) || true
    elif cmd_exists gradle; then
      (cd "$APP_DIR" && gradle --no-daemon build -x test) || true
    fi
  fi

  if [[ "$APP_PORT" == "8080" ]]; then
    APP_PORT="8080"
    sed -i "s|^export APP_PORT=.*$|export APP_PORT=\"$APP_PORT\"|" "$ENV_FILE" || true
  fi

  log "Java environment setup completed."
}

# .NET setup (limited)
setup_dotnet() {
  log "Detected .NET project. Attempting minimal setup..."
  if ! cmd_exists dotnet; then
    warn ".NET SDK not found. Installing .NET SDK inside generic images is complex. Use official .NET SDK runtime image (e.g., mcr.microsoft.com/dotnet/sdk) for builds."
    return
  fi
  (cd "$APP_DIR" && dotnet restore) || warn "dotnet restore failed."
  if [[ "$APP_PORT" == "8080" ]]; then
    APP_PORT="8080"
    sed -i "s|^export APP_PORT=.*$|export APP_PORT=\"$APP_PORT\"|" "$ENV_FILE" || true
  fi
  log ".NET environment setup completed."
}

# Decide primary runtime based on detection order
setup_runtime() {
  local did_any=0

  if [[ "$(detect_python)" == "1" ]]; then
    setup_python
    did_any=1
  fi

  if [[ "$(detect_node)" == "1" ]]; then
    setup_node
    did_any=1
  fi

  if [[ "$(detect_ruby)" == "1" ]]; then
    setup_ruby
    did_any=1
  fi

  if [[ "$(detect_go)" == "1" ]]; then
    setup_go
    did_any=1
  fi

  if [[ "$(detect_rust)" == "1" ]]; then
    setup_rust
    did_any=1
  fi

  if [[ "$(detect_php)" == "1" ]]; then
    setup_php
    did_any=1
  fi

  if [[ "$(detect_java)" == "1" ]]; then
    setup_java
    did_any=1
  fi

  if [[ "$(detect_dotnet)" == "1" ]]; then
    setup_dotnet
    did_any=1
  fi

  if [[ "$did_any" -eq 0 ]]; then
    warn "No recognized project configuration files found in $APP_DIR. Skipping runtime-specific setup."
  fi
}

# Permissions tightening (avoid world-writable files)
tighten_permissions() {
  log "Tightening permissions in $APP_DIR ..."
  find "$APP_DIR" -type d -exec chmod 755 {} \; || true
  find "$APP_DIR" -type f -name "*.sh" -exec chmod 755 {} \; || true
  find "$APP_DIR" -type f ! -name "*.sh" -exec chmod 644 {} \; || true
  log "Permissions tightened."
}

# Guidance
print_usage() {
  cat <<EOF
Environment setup completed.

- To load environment variables in your shell:
  source "$ENV_FILE"

- Default variables:
  APP_DIR=$APP_DIR
  APP_ENV=$APP_ENV
  APP_PORT=$APP_PORT

This script is idempotent; re-running will update dependencies when necessary.
EOF
}

main() {
  log "Starting project environment setup for Docker container..."

  detect_os
  install_base_tools
  setup_project_dir
  write_env_file
  setup_runtime
  tighten_permissions
  print_usage

  log "All done!"
}

# Change to APP_DIR if it exists, but allow running from current dir
if [[ -d "$APP_DIR" ]]; then
  cd "$APP_DIR" || die "Failed to change directory to $APP_DIR"
else
  mkdir -p "$APP_DIR"
  cd "$APP_DIR" || die "Failed to change directory to $APP_DIR"
fi

main "$@"