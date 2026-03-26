#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types (Node.js, Python, Ruby, PHP, Java, Go, Rust)
# - Installs runtimes and system dependencies via the container's package manager
# - Sets up project directories, permissions, and environment variables
# - Idempotent and safe to re-run
# - Designed for root execution in containers (no sudo)
#
# Usage: ./setup.sh

set -Eeuo pipefail

# -----------------------------
# Config and logging
# -----------------------------
SCRIPT_NAME="$(basename "$0")"
START_TS="$(date +%s)"
PROJ_DIR="${PROJECT_DIR:-$(pwd)}"
ENV_FILE="${ENV_FILE:-"$PROJ_DIR/.env"}"
DEFAULT_APP_USER="${APP_USER:-app}"
DEFAULT_APP_UID="${APP_UID:-1000}"
DEFAULT_APP_GID="${APP_GID:-1000}"

# Colors if TTY
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log()    { echo -e "${GREEN}[$(date +'%F %T')] ${SCRIPT_NAME}: $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date +'%F %T')] ${SCRIPT_NAME} [WARN]: $*${NC}" >&2; }
error()  { echo -e "${RED}[$(date +'%F %T')] ${SCRIPT_NAME} [ERROR]: $*${NC}" >&2; }
section(){ echo -e "${BLUE}--- $* ---${NC}"; }

on_error() {
  local exit_code=$?
  error "An error occurred (exit code $exit_code) while executing: ${BASH_COMMAND:-unknown}"
  exit "$exit_code"
}
trap on_error ERR

# Ensure we run from the project directory
cd "$PROJ_DIR" || { error "Cannot cd to $PROJ_DIR"; exit 1; }

# -----------------------------
# Helpers
# -----------------------------
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

pm=""  # package manager type: apt|apk|dnf|yum|microdnf|zypper|none

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then pm="apt"
  elif command -v apk >/dev/null 2>&1; then pm="apk"
  elif command -v dnf >/dev/null 2>&1; then pm="dnf"
  elif command -v yum >/dev/null 2>&1; then pm="yum"
  elif command -v microdnf >/dev/null 2>&1; then pm="microdnf"
  elif command -v zypper >/dev/null 2>&1; then pm="zypper"
  else pm="none"
  fi
}

pkg_update() {
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update || true
      ;;
    dnf)
      dnf -y makecache || true
      ;;
    yum)
      yum -y makecache || true
      ;;
    microdnf)
      microdnf -y update || true
      ;;
    zypper)
      zypper --non-interactive refresh || true
      ;;
    *)
      warn "No supported package manager found; skipping system package index update."
      ;;
  esac
}

pkg_install() {
  # Arguments: list of packages to install (names must be correct for the chosen PM)
  [ "$#" -gt 0 ] || return 0
  case "$pm" in
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
    microdnf)
      microdnf install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
    *)
      warn "No supported package manager found; cannot install: $*"
      return 1
      ;;
  esac
}

pkg_cleanup() {
  case "$pm" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|yum|microdnf)
      rm -rf /var/cache/dnf /var/cache/yum || true
      ;;
    zypper)
      zypper --non-interactive clean --all || true
      ;;
  esac
}

ensure_base_system() {
  section "Installing base system packages"
  if ! is_root; then
    warn "Not running as root; skipping system package installation."
    return 0
  fi
  detect_pm
  if [ "$pm" = "none" ]; then
    warn "No package manager detected; base system packages cannot be installed."
    return 0
  fi
  pkg_update
  case "$pm" in
    apt)
      pkg_install ca-certificates curl git bash tzdata xz-utils unzip tar sed grep findutils coreutils
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git bash tzdata xz unzip tar sed grep findutils coreutils
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl git bash tzdata xz unzip tar sed grep findutils coreutils
      update-ca-trust || true
      ;;
    zypper)
      pkg_install ca-certificates curl git bash timezone xz unzip tar sed grep findutils coreutils
      ;;
  esac
}

ensure_build_tools() {
  section "Installing build tools for native extensions"
  if ! is_root; then
    warn "Not root; cannot install build tools system-wide."
    return 0
  fi
  case "$pm" in
    apt)
      pkg_install build-essential pkg-config
      ;;
    apk)
      pkg_install build-base pkgconfig
      ;;
    dnf|yum|microdnf)
      pkg_install gcc gcc-c++ make pkgconfig
      ;;
    zypper)
      pkg_install gcc gcc-c++ make pkg-config
      ;;
  esac
}

ensure_make_and_makefile() {
  section "Ensuring make and generic Makefile"
  if is_root; then
    detect_pm
    case "$pm" in
      apt|apk|dnf|yum|microdnf|zypper)
        pkg_install make || true
        ;;
      *)
        warn "No supported package manager found; cannot ensure 'make'."
        ;;
    esac
  else
    warn "Not root; cannot install make."
  fi

  if [ ! -f "$PROJ_DIR/Makefile" ]; then
    printf "build:\n\t@echo \"No-op build: generic Makefile used because no project manifest was found\"\n" > "$PROJ_DIR/Makefile"
  fi
}

ensure_user() {
  section "Ensuring application user and permissions"
  if is_root; then
    # Create group if not exists
    if ! getent group "$DEFAULT_APP_GID" >/dev/null 2>&1 && ! getent group "$DEFAULT_APP_USER" >/dev/null 2>&1; then
      case "$pm" in
        apk)
          addgroup -g "$DEFAULT_APP_GID" -S "$DEFAULT_APP_USER" || true
          ;;
        *)
          groupadd -g "$DEFAULT_APP_GID" -f "$DEFAULT_APP_USER" || true
          ;;
      esac
    fi

    # Create user if not exists
    if ! id -u "$DEFAULT_APP_USER" >/dev/null 2>&1; then
      case "$pm" in
        apk)
          adduser -D -S -u "$DEFAULT_APP_UID" -G "$DEFAULT_APP_USER" "$DEFAULT_APP_USER" || true
          ;;
        *)
          useradd -m -u "$DEFAULT_APP_UID" -g "$DEFAULT_APP_GID" -s /bin/bash "$DEFAULT_APP_USER" || true
          ;;
      esac
    fi

    # Create directories and adjust ownership
    mkdir -p "$PROJ_DIR"/{logs,tmp,data,run}
    chown -R "$DEFAULT_APP_UID":"$DEFAULT_APP_GID" "$PROJ_DIR"/logs "$PROJ_DIR"/tmp "$PROJ_DIR"/data "$PROJ_DIR"/run || true
  else
    mkdir -p "$PROJ_DIR"/{logs,tmp,data,run}
  fi
}

ensure_env_file() {
  section "Configuring environment variables"
  touch "$ENV_FILE"
  chmod 0644 "$ENV_FILE" || true

  set_env_kv "APP_ENV" "${APP_ENV:-production}"
  set_env_kv "APP_PORT" "${APP_PORT:-8080}"
  set_env_kv "LOG_LEVEL" "${LOG_LEVEL:-info}"
  set_env_kv "PROJECT_DIR" "$PROJ_DIR"
  set_env_kv "APP_USER" "$DEFAULT_APP_USER"

  # Export into current shell too
  export APP_ENV APP_PORT LOG_LEVEL PROJECT_DIR APP_USER
}

set_env_kv() {
  # set_env_kv KEY VALUE -> ensure KEY=VALUE exists in ENV_FILE (update or append)
  local k="${1:?key}"; local v="${2:-}"
  if grep -qE "^${k}=" "$ENV_FILE" 2>/dev/null; then
    # shellcheck disable=SC2001
    sed -i "s|^${k}=.*$|${k}=${v}|" "$ENV_FILE" || true
  else
    echo "${k}=${v}" >> "$ENV_FILE"
  fi
}

# -----------------------------
# Virtual environment auto-activation
# -----------------------------
setup_auto_activate() {
  local bashrc_files=("/root/.bashrc")
  # If a default app user home exists, include their bashrc as well
  if [ -n "$DEFAULT_APP_USER" ] && [ -d "/home/$DEFAULT_APP_USER" ]; then
    bashrc_files+=("/home/$DEFAULT_APP_USER/.bashrc")
  fi

  # Activation line uses the same venv path used elsewhere in this script
  local activate_line='PROJ_DIR="${PROJECT_DIR:-/app}"; [ -f "$PROJ_DIR/.venv/bin/activate" ] && . "$PROJ_DIR/.venv/bin/activate"'

  for bashrc_file in "${bashrc_files[@]}"; do
    mkdir -p "$(dirname "$bashrc_file")" 2>/dev/null || true
    if touch "$bashrc_file" 2>/dev/null; then
      if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
        {
          echo ""
          echo "# Auto-activate Python virtual environment"
          echo "$activate_line"
        } >> "$bashrc_file"
      fi
    else
      warn "Skipping auto-activation setup: cannot write to $bashrc_file"
    fi
  done
}

# -----------------------------
# Project type detection
# -----------------------------
has_file() { [ -f "$PROJ_DIR/$1" ]; }
has_any() { for f in "$@"; do [ -e "$PROJ_DIR/$f" ] && return 0; done; return 1; }

detect_project_types() {
  local types=()

  if has_file "package.json"; then types+=("node"); fi
  if has_any "requirements.txt" "pyproject.toml" "setup.py" "Pipfile"; then types+=("python"); fi
  if has_file "Gemfile"; then types+=("ruby"); fi
  if has_file "composer.json"; then types+=("php"); fi
  if has_any "pom.xml" "build.gradle" "build.gradle.kts" "gradlew"; then types+=("java"); fi
  if has_file "go.mod"; then types+=("go"); fi
  if has_file "Cargo.toml"; then types+=("rust"); fi
  shopt -s nullglob
  local csproj=( "$PROJ_DIR"/*.csproj ); local sln=( "$PROJ_DIR"/*.sln )
  if [ "${#csproj[@]}" -gt 0 ] || [ "${#sln[@]}" -gt 0 ]; then types+=(".net"); fi
  shopt -u nullglob

  printf "%s\n" "${types[@]}"
}

# -----------------------------
# Language/runtime installers
# -----------------------------
install_node_runtime() {
  section "Installing Node.js runtime"
  if ! is_root; then
    warn "Not root; attempting to use existing Node.js if available."
  else
    detect_pm
    case "$pm" in
      apt)
        pkg_update
        pkg_install nodejs npm
        ;;
      apk)
        pkg_update
        pkg_install nodejs npm
        ;;
      dnf|yum|microdnf)
        pkg_update
        pkg_install nodejs npm
        ;;
      zypper)
        pkg_update
        pkg_install nodejs npm
        ;;
      *)
        warn "No package manager; cannot install Node.js."
        ;;
    esac
  fi

  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not found. Some Node-based setups may fail."
  else
    log "Node version: $(node -v)"
  fi

  # Tools for building native modules
  ensure_build_tools
  case "$pm" in
    apt)  pkg_install python3 python3-dev || true ;;
    apk)  pkg_install python3 python3-dev || true ;;
    dnf|yum|microdnf) pkg_install python3 python3-devel || true ;;
    zypper) pkg_install python3 python3-devel || true ;;
  esac

  # Corepack for managing yarn/pnpm if available
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  elif command -v npm >/dev/null 2>&1; then
    npm install -g corepack --no-audit --no-fund || true
    command -v corepack >/dev/null 2>&1 && corepack enable || true
  fi

  # Environment
  export NODE_ENV="${NODE_ENV:-production}"
  set_env_kv "NODE_ENV" "$NODE_ENV"
}

install_node_deps() {
  [ -f "$PROJ_DIR/package.json" ] || return 0
  section "Installing Node.js dependencies"
  export npm_config_loglevel=warn
  export npm_config_fund=false
  export npm_config_audit=false

  if [ -f "$PROJ_DIR/pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
    (cd "$PROJ_DIR" && pnpm install --frozen-lockfile)
  elif [ -f "$PROJ_DIR/yarn.lock" ] && command -v yarn >/dev/null 2>&1; then
    (cd "$PROJ_DIR" && yarn install --frozen-lockfile --non-interactive)
  elif [ -f "$PROJ_DIR/package-lock.json" ] || [ -f "$PROJ_DIR/npm-shrinkwrap.json" ]; then
    (cd "$PROJ_DIR" && npm ci --no-audit --no-fund)
  elif command -v npm >/dev/null 2>&1; then
    (cd "$PROJ_DIR" && npm install --no-audit --no-fund)
  else
    warn "No Node package manager found to install dependencies."
  fi
}

install_python_runtime() {
  section "Installing Python runtime"
  if is_root; then
    detect_pm
    case "$pm" in
      apt)
        pkg_update
        pkg_install python3 python3-venv python3-pip python3-dev
        ;;
      apk)
        pkg_update
        pkg_install python3 py3-pip python3-dev
        ;;
      dnf|yum|microdnf)
        pkg_update
        pkg_install python3 python3-pip python3-devel
        ;;
      zypper)
        pkg_update
        pkg_install python3 python3-pip python3-devel
        ;;
      *)
        warn "No package manager; cannot install Python."
        ;;
    esac
  else
    warn "Not root; attempting to use existing Python."
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "Python3 not found. Python-based setups may fail."
    return 0
  fi

  # Virtual environment setup (idempotent)
  if [ ! -d "$PROJ_DIR/.venv" ]; then
    (cd "$PROJ_DIR" && python3 -m venv .venv)
  fi
  # shellcheck disable=SC1091
  source "$PROJ_DIR/.venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  export PYTHONDONTWRITEBYTECODE=1
  export PYTHONUNBUFFERED=1
  set_env_kv "PYTHONDONTWRITEBYTECODE" "1"
  set_env_kv "PYTHONUNBUFFERED" "1"
  set_env_kv "VIRTUAL_ENV" "$PROJ_DIR/.venv"
}

install_python_deps() {
  if [ -d "$PROJ_DIR/.venv" ]; then
    # shellcheck disable=SC1091
    source "$PROJ_DIR/.venv/bin/activate"
  fi

  if [ -f "$PROJ_DIR/requirements.txt" ]; then
    section "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r "$PROJ_DIR/requirements.txt"
  elif [ -f "$PROJ_DIR/pyproject.toml" ]; then
    section "Installing Python project from pyproject.toml"
    pip install --no-cache-dir "$PROJ_DIR" || {
      warn "PEP 517 install failed; attempting editable install"
      pip install --no-cache-dir -e "$PROJ_DIR" || true
    }
  elif [ -f "$PROJ_DIR/Pipfile" ] && command -v pipenv >/dev/null 2>&1; then
    section "Installing with Pipenv"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  else
    log "No Python dependency manifest found."
  fi
}

install_ruby_runtime() {
  [ -f "$PROJ_DIR/Gemfile" ] || return 0
  section "Installing Ruby runtime"
  if is_root; then
    detect_pm
    case "$pm" in
      apt)
        pkg_update
        pkg_install ruby-full
        ensure_build_tools
        ;;
      apk)
        pkg_update
        pkg_install ruby ruby-dev
        ensure_build_tools
        ;;
      dnf|yum|microdnf)
        pkg_update
        pkg_install ruby ruby-devel
        ensure_build_tools
        ;;
      zypper)
        pkg_update
        pkg_install ruby ruby-devel
        ensure_build_tools
        ;;
      *)
        warn "No package manager; cannot install Ruby."
        ;;
    esac
  else
    warn "Not root; attempting to use existing Ruby."
  fi

  if command -v gem >/dev/null 2>&1; then
    gem install bundler --no-document || true
  else
    warn "RubyGems not available; skipping bundler installation."
  fi
}

install_ruby_deps() {
  [ -f "$PROJ_DIR/Gemfile" ] || return 0
  section "Installing Ruby gems via Bundler"
  if command -v bundle >/dev/null 2>&1; then
    (cd "$PROJ_DIR" && bundle config set --local path 'vendor/bundle'
      if [ "${APP_ENV:-production}" = "production" ]; then
        bundle install --jobs="$(nproc || echo 2)" --retry=3 --without development test
      else
        bundle install --jobs="$(nproc || echo 2)" --retry=3
      fi
    )
  else
    warn "Bundler not found; skipping Ruby dependency installation."
  fi
}

install_php_runtime() {
  [ -f "$PROJ_DIR/composer.json" ] || return 0
  section "Installing PHP runtime"
  if is_root; then
    detect_pm
    case "$pm" in
      apt)
        pkg_update
        pkg_install php-cli php-zip php-xml php-mbstring php-curl php-json unzip
        ;;
      apk)
        pkg_update
        pkg_install php php-phar php-openssl php-json php-mbstring php-xml php-curl php-zip unzip
        ;;
      dnf|yum|microdnf)
        pkg_update
        pkg_install php-cli php-zip php-xml php-mbstring php-json unzip
        ;;
      zypper)
        pkg_update
        pkg_install php7 php7-zip php7-xml php7-mbstring php7-json unzip || pkg_install php php-zip php-xml php-mbstring php-json unzip || true
        ;;
      *)
        warn "No package manager; cannot install PHP."
        ;;
    esac
  else
    warn "Not root; attempting to use existing PHP."
  fi

  if ! command -v composer >/dev/null 2>&1; then
    section "Installing Composer"
    if command -v php >/dev/null 2>&1; then
      curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Composer installation failed"
      rm -f /tmp/composer-setup.php
    else
      warn "PHP not available; cannot install Composer."
    fi
  fi
}

install_php_deps() {
  [ -f "$PROJ_DIR/composer.json" ] || return 0
  section "Installing PHP dependencies via Composer"
  if command -v composer >/dev/null 2>&1; then
    (cd "$PROJ_DIR" && composer install --no-dev --prefer-dist --no-progress --no-interaction || composer install --prefer-dist --no-progress --no-interaction)
  else
    warn "Composer not found; skipping PHP dependency installation."
  fi
}

install_java_runtime() {
  if ! has_any "pom.xml" "build.gradle" "build.gradle.kts" "gradlew"; then return 0; fi
  section "Installing Java runtime and build tools"
  if is_root; then
    detect_pm
    case "$pm" in
      apt)
        pkg_update
        pkg_install openjdk-17-jdk maven gradle || pkg_install openjdk-11-jdk maven gradle || true
        ;;
      apk)
        pkg_update
        pkg_install openjdk17-jdk maven gradle || pkg_install openjdk11-jdk maven gradle || true
        ;;
      dnf|yum|microdnf)
        pkg_update
        pkg_install java-17-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven gradle || true
        ;;
      zypper)
        pkg_update
        pkg_install java-17-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven gradle || true
        ;;
      *)
        warn "No package manager; cannot install Java."
        ;;
    esac
  else
    warn "Not root; attempting to use existing Java."
  fi
  if command -v java >/dev/null 2>&1; then
    log "Java version: $(java -version 2>&1 | head -n1)"
  else
    warn "Java not found."
  fi
}

install_java_deps() {
  if [ -f "$PROJ_DIR/pom.xml" ] && command -v mvn >/dev/null 2>&1; then
    section "Resolving Maven dependencies (offline cache)"
    (cd "$PROJ_DIR" && mvn -B -DskipTests dependency:go-offline || true)
  fi
  if [ -x "$PROJ_DIR/gradlew" ]; then
    section "Running Gradle wrapper to warm cache"
    (cd "$PROJ_DIR" && chmod +x ./gradlew && ./gradlew --no-daemon tasks >/dev/null || true)
  elif [ -f "$PROJ_DIR/build.gradle" ] || [ -f "$PROJ_DIR/build.gradle.kts" ]; then
    if command -v gradle >/dev/null 2>&1; then
      section "Running Gradle to warm cache"
      (cd "$PROJ_DIR" && gradle --no-daemon tasks >/dev/null || true)
    fi
  fi
}

install_go_runtime() {
  [ -f "$PROJ_DIR/go.mod" ] || return 0
  section "Installing Go runtime"
  if is_root; then
    detect_pm
    case "$pm" in
      apt) pkg_update; pkg_install golang ;;
      apk) pkg_update; pkg_install go ;;
      dnf|yum|microdnf) pkg_update; pkg_install golang ;;
      zypper) pkg_update; pkg_install go ;;
      *) warn "No package manager; cannot install Go." ;;
    esac
  else
    warn "Not root; attempting to use existing Go."
  fi
  if command -v go >/dev/null 2>&1; then
    log "Go version: $(go version)"
  else
    warn "Go not found."
  fi
}

install_go_deps() {
  [ -f "$PROJ_DIR/go.mod" ] || return 0
  if command -v go >/dev/null 2>&1; then
    section "Downloading Go modules"
    (cd "$PROJ_DIR" && go mod download || true)
  fi
}

install_rust_runtime() {
  [ -f "$PROJ_DIR/Cargo.toml" ] || return 0
  section "Installing Rust toolchain (via rustup)"
  if command -v cargo >/dev/null 2>&1; then
    log "Rust already installed: $(cargo --version)"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not available; cannot install Rustup."
    return 0
  fi
  export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
  export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
  chmod +x /tmp/rustup-init.sh
  /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal
  rm -f /tmp/rustup-init.sh
  export PATH="$CARGO_HOME/bin:$PATH"
  set_env_kv "CARGO_HOME" "$CARGO_HOME"
  set_env_kv "RUSTUP_HOME" "$RUSTUP_HOME"
  set_env_kv "PATH" "\$CARGO_HOME/bin:\$PATH"
}

install_rust_deps() {
  [ -f "$PROJ_DIR/Cargo.toml" ] || return 0
  if command -v cargo >/dev/null 2>&1; then
    section "Fetching Rust crates"
    (cd "$PROJ_DIR" && cargo fetch || true)
  fi
}

dotnet_notice() {
  # We only advise; installing dotnet SDK cross-distro is complex in arbitrary base images
  shopt -s nullglob
  local csproj=( "$PROJ_DIR"/*.csproj ); local sln=( "$PROJ_DIR"/*.sln )
  if [ "${#csproj[@]}" -gt 0 ] || [ "${#sln[@]}" -gt 0 ]; then
    section ".NET project detected"
    warn ".NET SDK installation is not handled by this generic script. Consider using an official .NET SDK base image:"
    warn "  FROM mcr.microsoft.com/dotnet/sdk:8.0"
    warn "Then run: dotnet restore"
  fi
  shopt -u nullglob
}

# -----------------------------
# Main flow
# -----------------------------
main() {
  section "Starting environment setup in $PROJ_DIR"
  if ! is_root; then
    warn "Running as non-root user $(id -u):$(id -g). System package installation may be skipped."
  fi

  ensure_base_system
  ensure_user
  ensure_env_file

  # Configure auto-activation of the Python virtual environment for interactive shells
  setup_auto_activate

  # Ensure 'make' is available and provide a generic Makefile if none exists
  ensure_make_and_makefile

  # Detect project types
  mapfile -t project_types < <(detect_project_types)
  if [ "${#project_types[@]}" -eq 0 ]; then
    warn "No recognized project type found. The script will only prepare directories and base environment."
  else
    log "Detected project types: ${project_types[*]}"
  fi

  # Install runtimes and dependencies per type
  for t in "${project_types[@]}"; do
    case "$t" in
      node)
        install_node_runtime
        install_node_deps
        ;;
      python)
        install_python_runtime
        install_python_deps
        ;;
      ruby)
        install_ruby_runtime
        install_ruby_deps
        ;;
      php)
        install_php_runtime
        install_php_deps
        ;;
      java)
        install_java_runtime
        install_java_deps
        ;;
      go)
        install_go_runtime
        install_go_deps
        ;;
      rust)
        install_rust_runtime
        install_rust_deps
        ;;
      .net)
        dotnet_notice
        ;;
    esac
  done

  # Final cleanup to keep container slim
  if is_root; then
    pkg_cleanup || true
  fi

  section "Setup complete"
  log "Environment file: $ENV_FILE"
  log "Project directories ensured: logs/, tmp/, data/, run/"
  log "Elapsed: $(( $(date +%s) - START_TS ))s"

  # Helpful hints
  if [ -f "$PROJ_DIR/package.json" ]; then
    log "Node.js: consider using: npm start (or yarn start) - default port: ${APP_PORT:-8080}"
  fi
  if [ -f "$PROJ_DIR/requirements.txt" ] || [ -f "$PROJ_DIR/pyproject.toml" ]; then
    log "Python: activate venv with: source .venv/bin/activate"
  fi
}

main "$@"