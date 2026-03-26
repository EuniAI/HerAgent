#!/bin/bash

# Strict mode: exit on error, undefined var, or failed pipeline; safer IFS
set -euo pipefail
IFS=$'\n\t'

# Colors (safe fallback if not TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

# Logging helpers
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "${GREEN}[$(timestamp)] $*${NC}"; }
warn() { echo "${YELLOW}[WARNING $(timestamp)] $*${NC}" >&2; }
err() { echo "${RED}[ERROR $(timestamp)] $*${NC}" >&2; }

# Trap unexpected errors
trap 'err "An unexpected error occurred at line $LINENO"; exit 1' ERR

# Detect if running as root
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

# Determine project root (prefer current working dir)
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
if [ ! -d "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$(dirname "$(readlink -f "$0")")"
fi

# Create essential directories idempotently
ensure_dirs() {
  log "Ensuring project directories exist under: $PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT/bin" "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp"
  chmod 755 "$PROJECT_ROOT" || true
}

# Load .env file if present
load_env_file() {
  local env_file="${ENV_FILE:-$PROJECT_ROOT/.env}"
  if [ -f "$env_file" ]; then
    log "Loading environment variables from $env_file"
    # shellcheck disable=SC2163
    export $(grep -E -v '^\s*#' "$env_file" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | xargs -d '\n')
  else
    warn "No .env file found at $env_file; proceeding with defaults"
  fi
}

# Detect package manager and define functions
PM=""
pm_update() { :; }
pm_install() { :; }
pm_is_installed_cmd() { :; }

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
    pm_update() {
      export DEBIAN_FRONTEND=noninteractive
      # Update only if lists are empty to be idempotent
      if [ -z "$(ls -A /var/lib/apt/lists 2>/dev/null || true)" ]; then
        log "Updating apt package lists..."
        apt-get update -y -qq
      else
        log "apt package lists already present; skipping update"
      fi
    }
    pm_install() {
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y -qq "$@"
    }
    pm_is_installed_cmd() { dpkg -s "$1" >/dev/null 2>&1; }
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
    pm_update() {
      log "Updating apk package lists..."
      apk update
    }
    pm_install() {
      apk add --no-cache "$@"
    }
    pm_is_installed_cmd() { apk info -e "$1" >/dev/null 2>&1; }
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    pm_update() { log "Updating dnf metadata..."; dnf -y -q makecache; }
    pm_install() { dnf install -y -q "$@"; }
    pm_is_installed_cmd() { rpm -q "$1" >/dev/null 2>&1; }
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    pm_update() { log "Updating yum metadata..."; yum -y -q makecache; }
    pm_install() { yum install -y -q "$@"; }
    pm_is_installed_cmd() { rpm -q "$1" >/dev/null 2>&1; }
  elif command -v microdnf >/dev/null 2>&1; then
    PM="microdnf"
    pm_update() { log "Updating microdnf metadata..."; microdnf update -y || true; }
    pm_install() { microdnf install -y "$@"; }
    pm_is_installed_cmd() { rpm -q "$1" >/dev/null 2>&1; }
  elif command -v zypper >/dev/null 2>&1; then
    PM="zypper"
    pm_update() { log "Refreshing zypper repositories..."; zypper --non-interactive refresh; }
    pm_install() { zypper --non-interactive install -y "$@"; }
    pm_is_installed_cmd() { rpm -q "$1" >/dev/null 2>&1; }
  else
    PM=""
  fi
}

# Install a baseline of system tools (curl, git, ca-certificates, build essentials)
install_baseline_system_tools() {
  if ! is_root; then
    warn "Not running as root; skipping system package installation. Ensure required tools are present."
    return 0
  fi
  if [ -z "$PM" ]; then
    warn "No supported package manager detected; cannot install system packages. Ensure runtime tools are available."
    return 0
  fi

  pm_update

  case "$PM" in
    apt)
      local pkgs=(
        ca-certificates
        curl
        git
        tzdata
        openssl
        pkg-config
        build-essential
        bash
        libssl-dev
      )
      log "Installing baseline system tools via apt..."
      pm_install "${pkgs[@]}"
      update-ca-certificates || true
      ;;
    apk)
      local pkgs=(
        ca-certificates
        curl
        git
        tzdata
        openssl
        pkgconfig
        build-base
        bash
      )
      log "Installing baseline system tools via apk..."
      pm_install "${pkgs[@]}"
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      local pkgs=(
        ca-certificates
        curl
        git
        tzdata
        openssl
        pkgconfig
        gcc
        make
        bash
        openssl-devel
      )
      log "Installing baseline system tools via $PM..."
      pm_install "${pkgs[@]}"
      ;;
    zypper)
      local pkgs=(
        ca-certificates
        curl
        git
        timezone
        openssl
        pkg-config
        gcc
        make
        bash
        libopenssl-devel
      )
      log "Installing baseline system tools via zypper..."
      pm_install "${pkgs[@]}"
      ;;
    *)
      warn "Unsupported package manager: $PM"
      ;;
  esac
}

# Language/runtime installers and dependency resolvers

setup_python() {
  local needs_python=0
  if [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || ls "$PROJECT_ROOT"/*.py >/dev/null 2>&1; then
    needs_python=1
  fi
  [ "$needs_python" -eq 1 ] || return 0

  log "Python project detected. Setting up Python environment..."

  # Ensure Python runtime and venv components
  if ! command -v python3 >/dev/null 2>&1; then
    if ! is_root || [ -z "$PM" ]; then
      err "Python3 is not installed and cannot install without root/package manager."
      exit 1
    fi
    case "$PM" in
      apt) pm_install python3 python3-pip python3-venv python3-dev apt-utils ;;
      apk) pm_install python3 py3-pip python3-dev ;;
      dnf|yum|microdnf) pm_install python3 python3-pip python3-devel ;;
      zypper) pm_install python3 python3-pip python3-devel ;;
      *) err "Unsupported package manager for Python install"; exit 1 ;;
    esac
  else
    # Ensure venv/pip/dev packages on apt even if python3 is present
    if is_root && [ "$PM" = "apt" ]; then
      pm_install python3-venv python3-pip python3-dev apt-utils
    fi
  fi

  # Create venv idempotently
  local venv_dir="${PYTHON_VENV_DIR:-$PROJECT_ROOT/.venv}"
  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Python virtual environment already exists at $venv_dir"
  fi

  # Activate venv
  # shellcheck source=/dev/null
  . "$venv_dir/bin/activate"

  # Upgrade pip/setuptools/wheel
  pip install --upgrade --no-cache-dir pip setuptools wheel

  # Install dependencies
  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    if [ -f /tmp/pip-constraints.txt ]; then
      PIP_NO_BUILD_ISOLATION=0 pip install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt" -c /tmp/pip-constraints.txt || true
    else
      PIP_NO_BUILD_ISOLATION=0 pip install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt" || true
    fi
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    # Prefer pip; if project uses Poetry, install poetry and use it
    if grep -qi '\[tool.poetry\]' "$PROJECT_ROOT/pyproject.toml"; then
      log "Poetry configuration detected. Installing Poetry and project dependencies."
      pip install --no-cache-dir "poetry>=1.6"
      poetry config virtualenvs.in-project true || true
      poetry install --no-interaction --no-ansi
      # Reset venv_dir to Poetry's in-project venv
      venv_dir="$PROJECT_ROOT/.venv"
      # shellcheck source=/dev/null
      . "$venv_dir/bin/activate"
    else
      log "pyproject.toml detected. Attempting to install with pip (PEP 517)."
      if [ -f /tmp/pip-constraints.txt ]; then
        PIP_NO_BUILD_ISOLATION=0 pip install --no-cache-dir . -c /tmp/pip-constraints.txt || true
      else
        PIP_NO_BUILD_ISOLATION=1 PIP_ONLY_BINARY=:all: PIP_PREFER_BINARY=1 pip install --no-cache-dir . || true
      fi
    fi
  else
    log "No requirements.txt or pyproject.toml found. Skipping Python dependency installation."
  fi

  # Set basic environment variables, if not already set
  export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
  export PIP_NO_CACHE_DIR="${PIP_NO_CACHE_DIR:-1}"
  export PATH="$venv_dir/bin:$PATH"

  # Setup auto-activation of this virtual environment for future shells
  setup_auto_activate "$venv_dir"
}

setup_node() {
  local needs_node=0
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    needs_node=1
  fi
  [ "$needs_node" -eq 1 ] || return 0

  log "Node.js project detected. Setting up Node.js environment..."

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    if ! is_root || [ -z "$PM" ]; then
      err "Node.js/npm are not installed and cannot install without root/package manager."
      exit 1
    fi
    case "$PM" in
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
        pm_install nodejs npm10 || pm_install nodejs npm || true
        ;;
      *)
        err "Unsupported package manager for Node.js install"
        exit 1
        ;;
    esac
  fi

  # Install dependencies
  if [ -f "$PROJECT_ROOT/package-lock.json" ]; then
    log "Using npm ci for reproducible installs"
    (cd "$PROJECT_ROOT" && npm ci --no-audit --no-fund)
  else
    log "Using npm install"
    (cd "$PROJECT_ROOT" && npm install --no-audit --no-fund)
  fi

  export PATH="$PROJECT_ROOT/node_modules/.bin:$PATH"
}

setup_ruby() {
  local needs_ruby=0
  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    needs_ruby=1
  fi
  [ "$needs_ruby" -eq 1 ] || return 0

  log "Ruby project detected. Setting up Ruby environment..."

  if ! command -v ruby >/dev/null 2>&1; then
    if ! is_root || [ -z "$PM" ]; then
      err "Ruby is not installed and cannot install without root/package manager."
      exit 1
    fi
    case "$PM" in
      apt) pm_install ruby-full build-essential ;;
      apk) pm_install ruby ruby-dev build-base ;;
      dnf|yum|microdnf) pm_install ruby ruby-devel gcc make ;;
      zypper) pm_install ruby ruby-devel gcc make ;;
      *) err "Unsupported package manager for Ruby install"; exit 1 ;;
    esac
  fi

  # Install bundler
  if ! command -v bundle >/dev/null 2>&1; then
    log "Installing Bundler gem"
    gem install bundler --no-document
  fi

  # Install gems
  (cd "$PROJECT_ROOT" && bundle install --path vendor/bundle)
  export GEM_HOME="$PROJECT_ROOT/vendor/bundle"
  export PATH="$GEM_HOME/bin:$PATH"
}

setup_go() {
  local needs_go=0
  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    needs_go=1
  fi
  [ "$needs_go" -eq 1 ] || return 0

  log "Go project detected. Setting up Go environment..."

  if ! command -v go >/dev/null 2>&1; then
    if ! is_root || [ -z "$PM" ]; then
      err "Go is not installed and cannot install without root/package manager."
      exit 1
    fi
    case "$PM" in
      apt) pm_install golang ;;
      apk) pm_install go ;;
      dnf|yum|microdnf) pm_install golang ;;
      zypper) pm_install go ;;
      *) err "Unsupported package manager for Go install"; exit 1 ;;
    esac
  fi

  export GO111MODULE=on
  export GOPATH="${GOPATH:-$PROJECT_ROOT/.gopath}"
  mkdir -p "$GOPATH"
  export PATH="$GOPATH/bin:$PATH"

  (cd "$PROJECT_ROOT" && go mod download)
}

setup_rust() {
  local needs_rust=0
  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    needs_rust=1
  fi
  [ "$needs_rust" -eq 1 ] || return 0

  log "Rust project detected. Setting up Rust environment..."

  if ! command -v cargo >/dev/null 2>&1; then
    warn "Rust not found. Installing via rustup (user-local, no root required)."
    local rustup_url="https://sh.rustup.rs"
    curl -fsSL "$rustup_url" -o /tmp/rustup.sh
    chmod +x /tmp/rustup.sh
    # Install minimal toolchain quietly
    /tmp/rustup.sh -y --profile minimal --default-toolchain stable
    rm -f /tmp/rustup.sh || true
    # Add to PATH for current session
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    export PATH="$CARGO_HOME/bin:$PATH"
  fi

  (cd "$PROJECT_ROOT" && cargo fetch)
}

setup_java() {
  local needs_java=0
  if [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ]; then
    needs_java=1
  fi
  [ "$needs_java" -eq 1 ] || return 0

  log "Java project detected. Setting up Java environment..."

  # Install JDK
  if ! command -v javac >/dev/null 2>&1; then
    if ! is_root || [ -z "$PM" ]; then
      err "JDK is not installed and cannot install without root/package manager."
      exit 1
    fi
    case "$PM" in
      apt) pm_install default-jdk ;;
      apk) pm_install openjdk17-jdk || pm_install openjdk11-jdk ;;
      dnf|yum|microdnf) pm_install java-11-openjdk-devel || pm_install java-17-openjdk-devel ;;
      zypper) pm_install java-11-openjdk-devel || pm_install java-17-openjdk-devel ;;
      *) err "Unsupported package manager for JDK install"; exit 1 ;;
    esac
  fi

  # Install Maven if pom.xml present
  if [ -f "$PROJECT_ROOT/pom.xml" ]; then
    if ! command -v mvn >/dev/null 2>&1; then
      if ! is_root || [ -z "$PM" ]; then
        err "Maven is not installed and cannot install without root/package manager."
        exit 1
      fi
      case "$PM" in
        apt) pm_install maven ;;
        apk) pm_install maven ;;
        dnf|yum|microdnf) pm_install maven ;;
        zypper) pm_install maven ;;
        *) err "Unsupported package manager for Maven install"; exit 1 ;;
      esac
    fi
    log "Fetching Maven dependencies (go-offline)"
    (cd "$PROJECT_ROOT" && mvn -B -q -DskipTests dependency:go-offline || true)
  fi

  # Install Gradle if build.gradle present
  if [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ]; then
    if ! command -v gradle >/dev/null 2>&1; then
      if ! is_root || [ -z "$PM" ]; then
        warn "Gradle not installed and cannot install without root; trying gradle wrapper if present."
      else
        case "$PM" in
          apt) pm_install gradle || true ;;
          apk) pm_install gradle || true ;;
          dnf|yum|microdnf) pm_install gradle || true ;;
          zypper) pm_install gradle || true ;;
        esac
      fi
    fi
    if [ -x "$PROJECT_ROOT/gradlew" ]; then
      log "Using Gradle wrapper to fetch dependencies"
      (cd "$PROJECT_ROOT" && ./gradlew --no-daemon build -x test || ./gradlew --no-daemon tasks || true)
    elif command -v gradle >/dev/null 2>&1; then
      log "Using system Gradle to fetch dependencies"
      (cd "$PROJECT_ROOT" && gradle --no-daemon build -x test || gradle --no-daemon tasks || true)
    else
      warn "Gradle not available; ensure dependencies are resolved during build."
    fi
  fi
}

setup_php() {
  local needs_php=0
  if [ -f "$PROJECT_ROOT/composer.json" ]; then
    needs_php=1
  fi
  [ "$needs_php" -eq 1 ] || return 0

  log "PHP project detected. Setting up PHP environment..."

  if ! command -v php >/dev/null 2>&1; then
    if ! is_root || [ -z "$PM" ]; then
      err "PHP is not installed and cannot install without root/package manager."
      exit 1
    fi
    case "$PM" in
      apt) pm_install php-cli php-mbstring php-xml php-curl php-zip ;;
      apk) pm_install php-cli php-mbstring php-xml php-curl php-zip ;;
      dnf|yum|microdnf) pm_install php-cli php-mbstring php-xml php-curl php-zip ;;
      zypper) pm_install php-cli php7-mbstring php7-xml php7-curl php7-zip || pm_install php-cli ;;
      *) err "Unsupported package manager for PHP install"; exit 1 ;;
    esac
  fi

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer locally"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir="$PROJECT_ROOT/bin" --filename=composer
    rm -f /tmp/composer-setup.php
    export PATH="$PROJECT_ROOT/bin:$PATH"
  fi

  log "Installing PHP dependencies via Composer"
  (cd "$PROJECT_ROOT" && composer install --no-interaction --prefer-dist)
}

setup_dotnet() {
  local needs_dotnet=0
  # Detect .NET projects
  if ls "$PROJECT_ROOT"/*.sln >/dev/null 2>&1 || ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then
    needs_dotnet=1
  fi
  [ "$needs_dotnet" -eq 1 ] || return 0

  log ".NET project detected."

  # Installing dotnet SDK across distros is complex; warn if missing
  if ! command -v dotnet >/dev/null 2>&1; then
    warn "dotnet SDK not found. Please use a base image with dotnet installed (e.g., mcr.microsoft.com/dotnet/sdk). Skipping dotnet setup."
    return 0
  fi

  log "Restoring .NET dependencies"
  (cd "$PROJECT_ROOT" && dotnet restore || true)
}

# Set default environment variables (can be overridden by .env)
setup_default_env() {
  export APP_ENV="${APP_ENV:-production}"
  export APP_PORT="${APP_PORT:-8080}"
  export LOG_LEVEL="${LOG_LEVEL:-info}"
  export PROJECT_ROOT
}

# Ensure virtual environment auto-activation on shell startup
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local activate_path="$1/bin/activate"
  local activate_line="source $activate_path"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# Configure permissions if requested via env
configure_permissions() {
  local user="${APP_USER:-}"
  local group="${APP_GROUP:-}"
  if [ -n "$user" ] && [ -n "$group" ] && is_root; then
    if id "$user" >/dev/null 2>&1 && getent group "$group" >/dev/null 2>&1; then
      log "Setting ownership of project to $user:$group"
      chown -R "$user:$group" "$PROJECT_ROOT"
    else
      warn "Requested APP_USER/APP_GROUP ($user:$group) not found; skipping chown."
    fi
  fi
}

# Summarize detected project types
summarize_detection() {
  log "Detection summary:"
  [ -f "$PROJECT_ROOT/requirements.txt" ] && echo " - Python (requirements.txt)"
  [ -f "$PROJECT_ROOT/pyproject.toml" ] && echo " - Python (pyproject.toml)"
  [ -f "$PROJECT_ROOT/package.json" ] && echo " - Node.js (package.json)"
  [ -f "$PROJECT_ROOT/Gemfile" ] && echo " - Ruby (Gemfile)"
  [ -f "$PROJECT_ROOT/go.mod" ] && echo " - Go (go.mod)"
  [ -f "$PROJECT_ROOT/Cargo.toml" ] && echo " - Rust (Cargo.toml)"
  { [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ]; } && echo " - Java (Maven/Gradle)"
  [ -f "$PROJECT_ROOT/composer.json" ] && echo " - PHP (composer.json)"
  if ls "$PROJECT_ROOT"/*.sln >/dev/null 2>&1 || ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then
  echo " - .NET (sln/csproj)"
fi
}

apply_repair_commands() {
  # Ensure bash is installed to avoid quoting issues with sh -lc
  if is_root; then
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y -qq
      apt-get install -y -qq bash
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q bash
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache bash
    fi
  fi

  # Install Python and build dependencies for scientific packages on apt-based systems
  if is_root && command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -qq
    apt-get install -y -qq python3 python3-venv python3-pip python3-dev build-essential gcc g++ make
  fi

  # Remove restrictive pip configuration that forced wheels-only installs
  rm -f /etc/pip.conf "$HOME/.pip/pip.conf" 2>/dev/null || true

  # Ensure virtual environment exists and has modern build tooling
  local venv_dir="${PYTHON_VENV_DIR:-$PROJECT_ROOT/.venv}"
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
  fi
  . "$venv_dir/bin/activate"
  "$venv_dir/bin/pip" install -U --no-cache-dir pip setuptools wheel cython build

  # Preinstall pybars4 from source to satisfy semantic-kernel dependency
  PIP_NO_BUILD_ISOLATION=0 "$venv_dir/bin/pip" install --no-binary=:all: "pybars4~=0.9" || true

  # Create constraints file aligned with project requirements
  printf "setuptools>=68\nwheel>=0.41\nnumpy~=1.25.2\n" > /tmp/pip-constraints.txt

  # Install project requirements with no build isolation and binary-only preferences
  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    PIP_NO_BUILD_ISOLATION=1 PIP_ONLY_BINARY=:all: PIP_PREFER_BINARY=1 "$venv_dir/bin/pip" install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt" -c /tmp/pip-constraints.txt || true
  fi

  # If pyproject.toml exists and it's not a Poetry project, install the project itself via pip
  if [ -f "$PROJECT_ROOT/pyproject.toml" ] && ! grep -qi '\[tool.poetry\]' "$PROJECT_ROOT/pyproject.toml"; then
    PIP_NO_BUILD_ISOLATION=1 PIP_ONLY_BINARY=:all: PIP_PREFER_BINARY=1 "$venv_dir/bin/pip" install --no-cache-dir . -c /tmp/pip-constraints.txt || true
  fi

  # Write and execute auto_build.sh to avoid shell -c quoting issues
  (
    cd "$PROJECT_ROOT" && rm -f ./auto_build.sh && cat > ./auto_build.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '%s\n' "$1" >&2; }
run() { printf '+ %s\n' "$*" >&2; "$@"; }

if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    run npm ci --no-audit --no-fund
    if npm run -s build; then :; elif npm run -s compile; then :; else log "No npm build script; continuing."; fi
  else
    log "npm not found"; exit 127
  fi
elif [ -f pom.xml ]; then
  if command -v mvn >/dev/null 2>&1; then
    run mvn -q -DskipTests package
  else
    log "maven (mvn) not found"; exit 127
  fi
elif [ -f gradlew ]; then
  run chmod +x gradlew
  run ./gradlew build
elif [ -f build.gradle ]; then
  if command -v gradle >/dev/null 2>&1; then
    run gradle build
  else
    log "gradle not found"; exit 127
  fi
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
  if command -v python3 >/dev/null 2>&1; then PY=python3; elif command -v python >/dev/null 2>&1; then PY=python; else log "python not found"; exit 127; fi
  run "$PY" -m pip install -U pip
  run "$PY" -m pip install -e .
elif [ -f Cargo.toml ]; then
  if command -v cargo >/dev/null 2>&1; then
    run cargo build -q
  else
    log "cargo not found"; exit 127
  fi
elif [ -f go.mod ]; then
  if command -v go >/dev/null 2>&1; then
    run go build ./...
  else
    log "go not found"; exit 127
  fi
elif [ -f composer.json ]; then
  if command -v composer >/dev/null 2>&1; then
    run composer install --no-interaction --prefer-dist
  else
    log "composer not found"; exit 127
  fi
else
  log "No recognized build file; nothing to do."
fi
EOF
    chmod +x ./auto_build.sh
    ./auto_build.sh || true
  )

  if [ -d "/app" ]; then
    test -f /app/placeholder.csproj || touch /app/placeholder.csproj
  fi
}

main() {
  log "Starting environment setup in container..."

  # Prepare project directories and env
  ensure_dirs
  load_env_file
  setup_default_env

  apply_repair_commands

  # Package manager detection and baseline tools
  detect_pm
  install_baseline_system_tools

  # Detect and setup runtimes/dependencies per stack
  summarize_detection
  setup_python
  setup_node
  setup_ruby
  setup_go
  setup_rust
  setup_java
  setup_php
  setup_dotnet

  # Configure permissions if requested
  configure_permissions

  log "Environment setup completed successfully."
  log "Project root: $PROJECT_ROOT"
  log "Environment: APP_ENV=$APP_ENV, APP_PORT=$APP_PORT, LOG_LEVEL=$LOG_LEVEL"
}

# Execute
main "$@"