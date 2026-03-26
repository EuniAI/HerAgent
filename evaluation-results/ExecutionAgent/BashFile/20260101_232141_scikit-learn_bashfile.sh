#!/bin/bash
# Container-friendly, idempotent environment setup script
# This script attempts to detect the project's technology stack and install
# required runtimes, system packages, and dependencies. Designed to run as root
# inside Docker containers with Debian/Ubuntu, Alpine, or RHEL-based images.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARNING] $*${NC}" >&2; }
error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

trap 'error "Setup failed at line $LINENO. Command: $BASH_COMMAND"' ERR

# Globals
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_ENV="${APP_ENV:-production}"
DEFAULT_PORT="${PORT:-}" # if PORT is pre-set, respect it; otherwise determine later
PM=""        # package manager
OS_FAMILY="" # debian|alpine|rhel|unknown

# Utility: run a command safely with logging
run() {
  log "RUN: $*"
  "$@"
}

# Detect package manager and OS family
detect_os() {
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
  elif command -v microdnf >/dev/null 2>&1; then
    PM="microdnf"
    OS_FAMILY="rhel"
  else
    OS_FAMILY="unknown"
    warn "Unsupported base image: no known package manager found. Some operations may fail."
  fi
  log "Detected OS family: ${OS_FAMILY} (PM: ${PM})"
}

# Update package index idempotently
pkg_update() {
  case "$PM" in
    apt)
      if [ ! -f /tmp/.apt_updated ]; then
        export DEBIAN_FRONTEND=noninteractive
        run apt-get update -y
        touch /tmp/.apt_updated
      fi
      ;;
    apk)
      # apk update is fast; run once per container
      if [ ! -f /tmp/.apk_updated ]; then
        run apk update
        touch /tmp/.apk_updated
      fi
      ;;
    dnf)
      # dnf has no explicit update for metadata; it auto-refreshes
      :
      ;;
    yum)
      :
      ;;
    microdnf)
      :
      ;;
    *)
      warn "Skip package index update: unknown PM"
      ;;
  esac
}

# Install packages using PM, ignoring already installed
pkg_install() {
  if [ $# -eq 0 ]; then return 0; fi
  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      run apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      run apk add --no-cache "$@"
      ;;
    dnf)
      run dnf install -y "$@"
      ;;
    yum)
      run yum install -y "$@"
      ;;
    microdnf)
      run microdnf install -y "$@"
      ;;
    *)
      error "Cannot install packages: unknown PM"
      return 1
      ;;
  esac
}

# Ensure a command exists; if not, install given package names
ensure_cmd() {
  local cmd="$1"; shift || true
  if command -v "$cmd" >/dev/null 2>&1; then
    log "Command '$cmd' is already available"
  else
    log "Command '$cmd' not found; installing packages: $*"
    pkg_update
    pkg_install "$@"
  fi
}

# Create app user/group (non-root) for better security
setup_user() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root; skipping user and permission setup."
    return 0
  fi
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    run groupadd -r "$APP_GROUP" || true
  fi
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    run useradd -r -g "$APP_GROUP" -d "$APP_DIR" -s /sbin/nologin "$APP_USER" || true
  fi
}

# Setup directory structure
setup_directories() {
  run mkdir -p "$APP_DIR"
  run mkdir -p "$APP_DIR"/{bin,logs,tmp,data}
  if [ "$(id -u)" -eq 0 ]; then
    run chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR"
  fi
}

# Determine the working project directory:
# If /app is empty and current directory contains project files, use current directory.
finalize_app_dir() {
  if [ -d "$APP_DIR" ] && [ -z "$(ls -A "$APP_DIR" 2>/dev/null || true)" ]; then
    # /app exists but empty
    if [ -f "./package.json" ] || [ -f "./requirements.txt" ] || [ -f "./pyproject.toml" ] || \
       [ -f "./Gemfile" ] || [ -f "./pom.xml" ] || [ -f "./build.gradle" ] || [ -f "./go.mod" ] || \
       [ -f "./Cargo.toml" ] || ls ./*.csproj >/dev/null 2>&1 || [ -f "./composer.json" ]; then
      warn "APP_DIR is empty; using current directory as project directory"
      APP_DIR="$(pwd)"
    fi
  fi
  log "Project directory: $APP_DIR"
}

# Basic tools and CA certificates
install_base_tools() {
  case "$OS_FAMILY" in
    debian)
      pkg_update
      pkg_install ca-certificates curl git tzdata
      # For building source-based dependencies
      pkg_install build-essential
      # Native build tools required for scikit-learn editable builds
      pkg_install ninja-build cmake gfortran libopenblas-dev liblapack-dev libgomp1 python-is-python3 pkg-config python3 python3-pip python3-venv
      # Clean up apt caches to reduce image size
      run apt-get clean || true
      run rm -rf /var/lib/apt/lists/* || true
      ;;
    alpine)
      pkg_update
      pkg_install ca-certificates curl git tzdata
      pkg_install build-base
      ;;
    rhel)
      pkg_update
      pkg_install ca-certificates curl git tzdata
      pkg_install gcc make
      ;;
    *)
      warn "Unknown OS family; attempting to proceed with existing tools."
      ;;
  esac
  # Ensure CA certs are updated
  if command -v update-ca-certificates >/dev/null 2>&1; then
    run update-ca-certificates || true
  fi
}

# Project type detection
PROJECT_TYPES=() # could include: python, node, ruby, java-maven, java-gradle, go, rust, php, dotnet

detect_project_types() {
  PROJECT_TYPES=()
  if [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ] || [ -f "$APP_DIR/Pipfile" ]; then
    PROJECT_TYPES+=("python")
  fi
  if [ -f "$APP_DIR/package.json" ]; then
    PROJECT_TYPES+=("node")
  fi
  if [ -f "$APP_DIR/Gemfile" ]; then
    PROJECT_TYPES+=("ruby")
  fi
  if [ -f "$APP_DIR/pom.xml" ]; then
    PROJECT_TYPES+=("java-maven")
  fi
  if [ -f "$APP_DIR/build.gradle" ] || [ -f "$APP_DIR/build.gradle.kts" ] || [ -f "$APP_DIR/gradlew" ]; then
    PROJECT_TYPES+=("java-gradle")
  fi
  if [ -f "$APP_DIR/go.mod" ]; then
    PROJECT_TYPES+=("go")
  fi
  if [ -f "$APP_DIR/Cargo.toml" ]; then
    PROJECT_TYPES+=("rust")
  fi
  if [ -f "$APP_DIR/composer.json" ]; then
    PROJECT_TYPES+=("php")
  fi
  if compgen -G "$APP_DIR/*.csproj" >/dev/null; then
    PROJECT_TYPES+=("dotnet")
  fi

  if [ ${#PROJECT_TYPES[@]} -eq 0 ]; then
    warn "No specific project type detected. The script will install base tools only."
  else
    log "Detected project types: ${PROJECT_TYPES[*]}"
  fi
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$OS_FAMILY" in
    debian)
      ensure_cmd python3 python3
      pkg_update
      pkg_install python3-venv python3-pip python3-dev
      ;;
    alpine)
      ensure_cmd python3 python3
      pkg_update
      pkg_install py3-pip py3-virtualenv python3-dev
      pkg_install musl-dev # headers for building wheels
      ;;
    rhel)
      ensure_cmd python3 python3
      pkg_update
      pkg_install python3-pip python3-devel
      ;;
    *)
      warn "Unknown OS family; attempting to use existing python3/pip."
      ;;
  esac

  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1

  # Create venv idempotently
  if [ ! -d "$APP_DIR/.venv" ]; then
    run python3 -m venv "$APP_DIR/.venv"
  else
    log "Python virtual environment already exists at $APP_DIR/.venv"
  fi

  # Activate venv for installation within the script
  # shellcheck disable=SC1091
  . "$APP_DIR/.venv/bin/activate"

  # Upgrade pip/setuptools/wheel to reduce build issues
  run python -m pip install -U pip setuptools wheel setuptools_scm
  # Ensure Python build dependencies required for scikit-learn editable builds
  run python -m pip install -U numpy scipy joblib threadpoolctl scikit-build scikit-build-core ninja cmake Cython pybind11 pytest ruff meson meson-python

  if [ -f "$APP_DIR/requirements.txt" ]; then
    run pip install -r "$APP_DIR/requirements.txt"
  elif [ -f "$APP_DIR/pyproject.toml" ]; then
    # Install build backend or use pip to install project
    if grep -qiE '^\s*\[project\]' "$APP_DIR/pyproject.toml" 2>/dev/null; then
      run pip install "$APP_DIR"
    else
      # PEP 517 build requirements may be specified; try pip install -e
      run pip install -e "$APP_DIR"
    fi
  elif [ -f "$APP_DIR/Pipfile" ]; then
    # Install pipenv to handle Pipfile
    run pip install pipenv
    (cd "$APP_DIR" && run pipenv install --system --deploy)
  else
    log "No Python dependency file found; skipping Python package installation."
  fi

  # Ensure scikit-learn is available in editable mode; clone if missing
  if [ -d "$APP_DIR/scikit-learn" ]; then
    (cd "$APP_DIR" && run python -m pip install -U meson-python meson)
    (cd "$APP_DIR" && run python -m pip install -e ./scikit-learn[tests] --no-build-isolation -v)
  else
    (cd "$APP_DIR" && run git clone https://github.com/scikit-learn/scikit-learn.git)
    (cd "$APP_DIR" && run python -m pip install -U meson-python meson)
    (cd "$APP_DIR" && run python -m pip install -e ./scikit-learn[tests] --no-build-isolation -v)
  fi

  deactivate || true
}

# Python wrapper for resilient -c handling
setup_python_wrapper() {
  # Install a python shim at /usr/local/bin/python that robustly handles -c
  log "Configuring python -c wrapper at /usr/local/bin/python"
  run mkdir -p /usr/local/bin
  cat <<'EOF' >/usr/local/bin/python
#!/usr/bin/env bash
set -e
REALPY="$(command -v python3 || true)"
if [ -z "$REALPY" ]; then
  REALPY="$(command -v python || true)"
fi
if [ -z "$REALPY" ]; then
  echo "No python interpreter found" >&2
  exit 127
fi
if [ "${1:-}" = "-c" ]; then
  shift
  CODE="$*"
  exec "$REALPY" -c "$CODE"
else
  exec "$REALPY" "$@"
fi
EOF
  run chmod +x /usr/local/bin/python
  # Ensure /usr/bin/python points to the wrapper if not present
  if [ ! -x /usr/bin/python ]; then
    run ln -sf /usr/local/bin/python /usr/bin/python
  fi
  # Ensure pytest is available in the system interpreter
  run python -m pip install -U pip setuptools wheel pytest numpy scipy cython
}

# Python shim inside /opt/venv for robust -c handling and package setup
setup_opt_venv_python_shim() {
  if [ -x "/opt/venv/bin/python" ]; then
    log "Setting up /opt/venv python -c wrapper and ensuring build deps..."
    if [ ! -x "/opt/venv/bin/python.real" ]; then
      run mv /opt/venv/bin/python /opt/venv/bin/python.real
    fi
    cat > /opt/venv/bin/python <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
PYREAL="/opt/venv/bin/python.real"
if [ ! -x "$PYREAL" ]; then
  PYREAL="$(command -v python3 || true)"
  if [ -z "${PYREAL:-}" ]; then
    echo "python3 not found" >&2
    exit 127
  fi
fi
if [ "${1-}" = "-c" ]; then
  shift
  code="$*"
  exec "$PYREAL" -c "$code"
else
  exec "$PYREAL" "$@"
fi
EOF
    run chmod +x /opt/venv/bin/python
    # Upgrade pip/setuptools/wheel and native build helpers inside /opt/venv
    run /opt/venv/bin/python -m pip install -U pip setuptools wheel setuptools_scm scikit-build-core ninja cmake cython pybind11
    run /opt/venv/bin/python -m pip install -U meson-python meson numpy scipy cython pybind11 pytest
    # If scikit-learn repo exists, install editable without build isolation for native builds
    if [ -d "$APP_DIR/scikit-learn" ]; then
      (cd "$APP_DIR" && run /opt/venv/bin/python -m pip install -e ./scikit-learn[tests] --no-build-isolation -v)
    fi
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "$OS_FAMILY" in
    debian)
      # Attempt to install recent Node via apt if available
      pkg_update
      pkg_install nodejs npm || {
        warn "apt nodejs/npm install failed; attempting NodeSource LTS install"
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        pkg_install nodejs
      }
      ;;
    alpine)
      pkg_update
      pkg_install nodejs npm
      ;;
    rhel)
      pkg_update
      # Try installing nodejs/npm directly; may require EPEL in some images
      pkg_install nodejs npm || warn "nodejs/npm not available via PM; please use a Node base image."
      ;;
    *)
      warn "Unknown OS family; attempting to use existing node/npm."
      ;;
  esac

  # Enable corepack for Yarn and PNPM if supported
  if command -v corepack >/dev/null 2>&1; then
    run corepack enable || true
  fi

  # Install dependencies idempotently
  if [ -f "$APP_DIR/pnpm-lock.yaml" ]; then
    if command -v pnpm >/dev/null 2>&1; then
      (cd "$APP_DIR" && run pnpm install --frozen-lockfile)
    else
      # Try corepack
      if command -v corepack >/dev/null 2>&1; then
        (cd "$APP_DIR" && run corepack prepare pnpm@latest --activate && run pnpm install --frozen-lockfile)
      else
        warn "pnpm lockfile detected but pnpm/corepack not available; falling back to npm install."
        (cd "$APP_DIR" && run npm ci || run npm install)
      fi
    fi
  elif [ -f "$APP_DIR/yarn.lock" ]; then
    if command -v yarn >/dev/null 2>&1; then
      (cd "$APP_DIR" && run yarn install --frozen-lockfile)
    else
      if command -v corepack >/dev/null 2>&1; then
        (cd "$APP_DIR" && run corepack prepare yarn@stable --activate && run yarn install --frozen-lockfile)
      else
        warn "yarn.lock detected but yarn/corepack not available; falling back to npm install."
        (cd "$APP_DIR" && run npm ci || run npm install)
      fi
    fi
  elif [ -f "$APP_DIR/package-lock.json" ]; then
    (cd "$APP_DIR" && run npm ci)
  elif [ -f "$APP_DIR/package.json" ]; then
    (cd "$APP_DIR" && run npm install)
  else
    log "No Node.js project files found; skipping dependency installation."
  fi
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$OS_FAMILY" in
    debian)
      pkg_update
      pkg_install ruby-full build-essential
      ;;
    alpine)
      pkg_update
      pkg_install ruby ruby-dev build-base
      ;;
    rhel)
      pkg_update
      pkg_install ruby ruby-devel gcc make
      ;;
    *)
      warn "Unknown OS family; attempting to use existing Ruby."
      ;;
  esac

  ensure_cmd gem ruby
  run gem install --no-document bundler || true

  if [ -f "$APP_DIR/Gemfile" ]; then
    (cd "$APP_DIR" && run bundle config set --local path 'vendor/bundle' && run bundle install)
  fi
}

# Java (Maven) setup
setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "$OS_FAMILY" in
    debian)
      pkg_update
      pkg_install openjdk-17-jdk maven
      ;;
    alpine)
      pkg_update
      pkg_install openjdk17 maven
      ;;
    rhel)
      pkg_update
      pkg_install java-17-openjdk java-17-openjdk-devel maven
      ;;
    *)
      warn "Unknown OS family; attempting to use existing Java/Maven."
      ;;
  esac

  if [ -f "$APP_DIR/pom.xml" ]; then
    (cd "$APP_DIR" && run mvn -B -q dependency:resolve || true)
  fi
}

# Java (Gradle) setup
setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  case "$OS_FAMILY" in
    debian)
      pkg_update
      pkg_install openjdk-17-jdk
      # Use gradle wrapper if present instead of system gradle
      ;;
    alpine)
      pkg_update
      pkg_install openjdk17
      ;;
    rhel)
      pkg_update
      pkg_install java-17-openjdk java-17-openjdk-devel
      ;;
    *)
      warn "Unknown OS family; attempting to use existing Java."
      ;;
  esac

  if [ -x "$APP_DIR/gradlew" ]; then
    (cd "$APP_DIR" && run ./gradlew --version && run ./gradlew --no-daemon build -x test || true)
  elif [ -f "$APP_DIR/build.gradle" ] || [ -f "$APP_DIR/build.gradle.kts" ]; then
    # Try installing gradle if wrapper not present
    case "$OS_FAMILY" in
      debian) pkg_install gradle || true ;;
      alpine) pkg_install gradle || true ;;
      rhel) pkg_install gradle || true ;;
    esac
    if command -v gradle >/dev/null 2>&1; then
      (cd "$APP_DIR" && run gradle --no-daemon build -x test || true)
    else
      warn "Gradle not available and no wrapper found; skipping Gradle build."
    fi
  fi
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$OS_FAMILY" in
    debian)
      pkg_update
      pkg_install golang
      ;;
    alpine)
      pkg_update
      pkg_install go
      ;;
    rhel)
      pkg_update
      pkg_install golang
      ;;
    *)
      warn "Unknown OS family; attempting to use existing Go."
      ;;
  esac

  if [ -f "$APP_DIR/go.mod" ]; then
    (cd "$APP_DIR" && run go mod download)
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    ensure_cmd curl curl
    # Install rustup toolchain in a container-safe way
    export RUSTUP_HOME="/usr/local/rustup"
    export CARGO_HOME="/usr/local/cargo"
    if [ ! -d "$RUSTUP_HOME" ]; then
      run curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
      run sh /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal
      rm -f /tmp/rustup-init.sh
    fi
    export PATH="$CARGO_HOME/bin:$PATH"
    # Persist PATH for future shells
    if [ -d /etc/profile.d ]; then
      echo 'export PATH="/usr/local/cargo/bin:$PATH"' >/etc/profile.d/zz_rust_path.sh
    fi
  fi

  if [ -f "$APP_DIR/Cargo.toml" ]; then
    (cd "$APP_DIR" && run cargo fetch)
  fi
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$OS_FAMILY" in
    debian)
      pkg_update
      pkg_install php-cli php-common php-json php-mbstring php-xml php-curl
      ;;
    alpine)
      pkg_update
      pkg_install php81 php81-cli php81-common php81-json php81-mbstring php81-xml php81-curl || \
      pkg_install php php-cli php-common php-json php-mbstring php-xml php-curl
      ;;
    rhel)
      pkg_update
      pkg_install php-cli php-json php-mbstring php-xml php-curl || warn "PHP packages may require additional repos."
      ;;
    *)
      warn "Unknown OS family; attempting to use existing PHP."
      ;;
  esac

  # Install composer
  if ! command -v composer >/dev/null 2>&1; then
    ensure_cmd curl curl
    run curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if [ -f "$APP_DIR/composer.json" ]; then
    (cd "$APP_DIR" && run composer install --no-interaction --no-progress --prefer-dist)
  fi
}

# .NET setup (best effort)
setup_dotnet() {
  log "Setting up .NET environment (best effort)..."
  warn "Automated .NET SDK install is not guaranteed on all base images. Prefer using a Microsoft .NET base image."
  # Attempt installation only on Debian/Ubuntu
  if [ "$OS_FAMILY" = "debian" ]; then
    pkg_update
    ensure_cmd wget wget
    run wget -q https://packages.microsoft.com/config/debian/$(. /etc/os-release && echo "$VERSION_ID")/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
    if [ -f /tmp/packages-microsoft-prod.deb ]; then
      run dpkg -i /tmp/packages-microsoft-prod.deb || true
      rm -f /tmp/packages-microsoft-prod.deb
      pkg_update
      pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || warn "Failed to install dotnet SDK via apt."
    else
      warn "Could not fetch Microsoft packages config; skipping .NET install."
    fi
  fi

  # Restore dependencies if possible
  if compgen -G "$APP_DIR/*.csproj" >/dev/null; then
    if command -v dotnet >/dev/null 2>&1; then
      (cd "$APP_DIR" && run dotnet restore)
    else
      warn "dotnet CLI not available; cannot restore .NET dependencies."
    fi
  fi
}

# Determine default port based on simple heuristics
determine_port() {
  local port="${DEFAULT_PORT}"
  if [ -n "$port" ]; then
    echo "$port"
    return 0
  fi
  # Heuristics based on common frameworks
  if [ -f "$APP_DIR/manage.py" ]; then
    port=8000
  elif [ -f "$APP_DIR/app.py" ] || grep -qi "flask" "$APP_DIR/requirements.txt" 2>/dev/null; then
    port=5000
  elif [ -f "$APP_DIR/server.js" ] || [ -f "$APP_DIR/app.js" ] || [ -f "$APP_DIR/package.json" ]; then
    port=3000
  elif [ -f "$APP_DIR/Gemfile" ]; then
    port=3000
  elif [ -f "$APP_DIR/pom.xml" ] || [ -f "$APP_DIR/build.gradle" ] || [ -f "$APP_DIR/build.gradle.kts" ]; then
    port=8080
  elif [ -f "$APP_DIR/go.mod" ]; then
    port=8080
  elif [ -f "$APP_DIR/Cargo.toml" ]; then
    port=8080
  elif [ -f "$APP_DIR/composer.json" ]; then
    port=8000
  else
    port=8080
  fi
  echo "$port"
}

# Write environment variables to files for future shells
persist_env() {
  local port
  port="$(determine_port)"
  # /etc/profile.d for system-wide shells
  if [ -d /etc/profile.d ]; then
    cat >/etc/profile.d/zz_project_env.sh <<EOF
# Project environment exports
export APP_DIR="$APP_DIR"
export APP_ENV="${APP_ENV}"
export PORT="${port}"
# Common tool paths
export PATH="/usr/local/bin:$PATH"
EOF
  fi
  # .env in project dir
  if [ ! -f "$APP_DIR/.env" ]; then
    cat >"$APP_DIR/.env" <<EOF
APP_DIR=$APP_DIR
APP_ENV=$APP_ENV
PORT=$port
EOF
    if [ "$(id -u)" -eq 0 ]; then
      chown "$APP_USER":"$APP_GROUP" "$APP_DIR/.env" || true
    fi
  else
    log ".env already exists; not overwriting."
  fi
}

# Auto-activate Python virtual environment for interactive shells
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_line="source $APP_DIR/.venv/bin/activate"
  # Ensure .bashrc exists
  if [ ! -f "$bashrc_file" ]; then
    touch "$bashrc_file"
  fi
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# Adjust permissions for writeable dirs
finalize_permissions() {
  if [ "$(id -u)" -eq 0 ]; then
    run chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR"
    # Restrict permissions on sensitive directories
    chmod 0755 "$APP_DIR" || true
    chmod 0755 "$APP_DIR"/{bin,logs,tmp,data} || true
  fi
}

# Main execution
main() {
  log "Starting project environment setup..."

  detect_os
  setup_user
  setup_directories
  finalize_app_dir
  install_base_tools
  setup_opt_venv_python_shim
  setup_python_wrapper
  setup_auto_activate
  detect_project_types

  # Install runtimes and dependencies per detected type
  for t in "${PROJECT_TYPES[@]}"; do
    case "$t" in
      python)       setup_python ;;
      node)         setup_node ;;
      ruby)         setup_ruby ;;
      java-maven)   setup_java_maven ;;
      java-gradle)  setup_java_gradle ;;
      go)           setup_go ;;
      rust)         setup_rust ;;
      php)          setup_php ;;
      dotnet)       setup_dotnet ;;
      *)            warn "Unknown detected type: $t" ;;
    esac
  done

  persist_env
  finalize_permissions

  log "Environment setup completed successfully."
  log "Summary:"
  log "- Project dir: $APP_DIR"
  log "- App env: $APP_ENV"
  log "- Default PORT: $(determine_port)"
  if [ "$(id -u)" -eq 0 ]; then
    log "- Created/ensured user: $APP_USER"
    log "You may switch to the non-root user in Dockerfile: USER $APP_USER"
  fi
  log "To use environment variables in shell: source /etc/profile.d/zz_project_env.sh (if applicable)"
  log "To inspect .env: cat $APP_DIR/.env"
}

main "$@"