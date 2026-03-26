#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Installs system packages and tools
# - Installs language runtimes and project dependencies (Python, Node.js, Go, Rust, Java, PHP, Ruby)
# - Sets up directory structure, permissions, and environment variables
# - Idempotent and safe to run multiple times
# - No sudo required; handles root and non-root users

set -Eeuo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging utilities
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARNING] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

# Error trap
on_error() {
  local exit_code=$?
  local cmd="${BASH_COMMAND:-unknown}"
  err "Command failed (exit $exit_code): $cmd"
  exit $exit_code
}
trap on_error ERR

# Globals
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
CACHE_DIR="${PROJECT_ROOT}/.cache/setup"
ENV_FILE="${PROJECT_ROOT}/.env"
IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
export DEBIAN_FRONTEND=noninteractive

# Ensure cache dir exists
mkdir -p "$CACHE_DIR"

# PATH adjustments for user-level installs
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

# Utilities
exists() { command -v "$1" >/dev/null 2>&1; }

# Detect package manager
PKG_MGR=""
detect_pkg_manager() {
  if exists apt-get; then PKG_MGR="apt"; return 0; fi
  if exists apk; then PKG_MGR="apk"; return 0; fi
  if exists dnf; then PKG_MGR="dnf"; return 0; fi
  if exists yum; then PKG_MGR="yum"; return 0; fi
  if exists microdnf; then PKG_MGR="microdnf"; return 0; fi
  if exists zypper; then PKG_MGR="zypper"; return 0; fi
  if exists pacman; then PKG_MGR="pacman"; return 0; fi
  PKG_MGR=""
  return 1
}

# Update package index (idempotent-ish with marker)
pkg_update() {
  [ "$IS_ROOT" -eq 0 ] && { warn "Non-root user: skipping system package index update"; return 0; }
  detect_pkg_manager || { warn "No supported package manager found; skipping system package operations"; return 0; }
  local marker="$CACHE_DIR/pkg_updated_${PKG_MGR}"
  if [ -f "$marker" ]; then
    info "Package index for $PKG_MGR already updated (marker found)"
    return 0
  fi
  log "Updating system package index using $PKG_MGR..."
  case "$PKG_MGR" in
    apt)
      apt-get update -y >/dev/null
      ;;
    apk)
      apk update >/dev/null
      ;;
    dnf)
      dnf makecache -y >/dev/null
      ;;
    yum)
      yum makecache -y >/dev/null
      ;;
    microdnf)
      microdnf update -y || true
      ;;
    zypper)
      zypper refresh -y >/dev/null
      ;;
    pacman)
      pacman -Sy --noconfirm >/dev/null
      ;;
  esac
  touch "$marker"
}

# Install system packages if root; otherwise warn
pkg_install() {
  [ $# -eq 0 ] && return 0
  [ "$IS_ROOT" -eq 0 ] && { warn "Non-root user: cannot install system packages: $*"; return 0; }
  detect_pkg_manager || { warn "No supported package manager found; cannot install: $*"; return 0; }
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@" >/dev/null
      ;;
    apk)
      apk add --no-cache "$@" >/dev/null
      ;;
    dnf)
      dnf install -y "$@" >/dev/null
      ;;
    yum)
      yum install -y "$@" >/dev/null
      ;;
    microdnf)
      microdnf install -y "$@" || true
      ;;
    zypper)
      zypper install -y "$@" >/dev/null
      ;;
    pacman)
      pacman -S --noconfirm --needed "$@" >/dev/null
      ;;
  esac
}

# Base tools
install_base_tools() {
  local marker="$CACHE_DIR/base_tools_installed"
  if [ -f "$marker" ]; then
    info "Base tools already installed"
    return 0
  fi
  log "Installing essential system tools (if possible)..."
  pkg_update

  # Minimal set of common tools
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git bash tar xz-utils unzip gzip bzip2 openssl gnupg make g++ pkg-config file
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git bash tar xz unzip gzip bzip2 openssl gnupg make g++ pkgconf file libc6-compat
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl git bash tar xz unzip gzip bzip2 openssl gnupg2 make gcc gcc-c++ pkgconfig file which
      ;;
    zypper)
      pkg_install ca-certificates curl git bash tar xz unzip gzip bzip2 libopenssl1_1 openssl gpg2 make gcc gcc-c++ pkg-config file which
      ;;
    pacman)
      pkg_install ca-certificates curl git bash tar xz unzip gzip bzip2 openssl gnupg make gcc pkgconf file which
      ;;
    *)
      warn "Skipping base system tools installation; unknown package manager"
      ;;
  esac

  mkdir -p "$HOME/.local/bin"
  touch "$marker"
}

# Directory structure
setup_directories() {
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,data,.cache,bin}
  mkdir -p "$CACHE_DIR"
  # Fix permissions to current user
  chown -R "$(id -u)":"$(id -g)" "$PROJECT_ROOT" 2>/dev/null || true
}

# Environment file
setup_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<'EOF'
# Application environment variables
APP_ENV=production
APP_DEBUG=0
APP_TIMEZONE=UTC
# Add your custom env vars here, e.g. DATABASE_URL, API_KEYS, etc.
EOF
    log "Created default .env file"
  else
    info ".env file already exists; leaving as-is"
  fi
}

# Detect project type flags
has_python() {
  [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ] || [ -f "$PROJECT_ROOT/Pipfile" ]
}
has_node() {
  [ -f "$PROJECT_ROOT/package.json" ]
}
has_go() {
  [ -f "$PROJECT_ROOT/go.mod" ] || [ -f "$PROJECT_ROOT/go.sum" ]
}
has_rust() {
  [ -f "$PROJECT_ROOT/Cargo.toml" ]
}
has_java() {
  [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/gradlew" ] || [ -f "$PROJECT_ROOT/mvnw" ]
}
has_php() {
  [ -f "$PROJECT_ROOT/composer.json" ]
}
has_ruby() {
  [ -f "$PROJECT_ROOT/Gemfile" ]
}
has_dotnet() {
  ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1 || ls "$PROJECT_ROOT"/*.sln >/dev/null 2>&1
}

# Python setup
setup_python() {
  local marker="$CACHE_DIR/python_setup_done"
  if [ -f "$marker" ]; then
    info "Python environment already set up"
    return 0
  fi
  log "Setting up Python environment..."

  # Install Python if missing (system-level if root)
  if ! exists python3; then
    if [ "$IS_ROOT" -eq 1 ]; then
      pkg_update
      case "$PKG_MGR" in
        apt) pkg_install python3 python3-pip python3-venv python3-dev build-essential libffi-dev libssl-dev ;; 
        apk) pkg_install python3 py3-pip python3-dev build-base libffi-dev openssl-dev ;;
        dnf|yum|microdnf) pkg_install python3 python3-pip python3-devel make gcc gcc-c++ libffi-devel openssl-devel ;;
        zypper) pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel libopenssl-devel ;;
        pacman) pkg_install python python-pip python-virtualenv base-devel libffi openssl ;;
        *) warn "Python3 not found and cannot install on this system" ;;
      esac
    else
      warn "Python3 not found and cannot install as non-root user"
    fi
  fi

  if ! exists python3; then
    err "Python3 is required but still not available"
    return 1
  fi

  # Virtual environment
  local VENV_DIR="$PROJECT_ROOT/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    log "Created virtual environment at $VENV_DIR"
  else
    info "Virtual environment already exists at $VENV_DIR"
  fi

  # Activate venv
  # shellcheck source=/dev/null
  source "$VENV_DIR/bin/activate"
  python3 -m pip install --upgrade pip wheel setuptools

  # Install dependencies
  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    pip install -r "$PROJECT_ROOT/requirements.txt"
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    # Attempt to install project using PEP 517
    pip install "build>=1" "pip>=21" "setuptools" "wheel"
    if grep -q "\[tool.poetry\]" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      # If Poetry project, use pip to build or install poetry to export
      pip install "poetry>=1.6"
      if [ -f "$PROJECT_ROOT/poetry.lock" ]; then
        poetry install --no-interaction --no-ansi --only main || poetry install --no-interaction --no-ansi
      else
        poetry install --no-interaction --no-ansi || true
      fi
    else
      pip install .
    fi
  elif [ -f "$PROJECT_ROOT/Pipfile" ]; then
    pip install "pipenv>=2023.0"
    pipenv install --system --deploy || pipenv install --system
  fi

  # Common environment variables for Python apps
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1

  deactivate || true
  touch "$marker"
  log "Python environment setup completed"
}

# Node.js setup via NVM (user-level; works as root too)
install_nvm_if_needed() {
  local marker="$CACHE_DIR/nvm_installed"
  if [ -f "$marker" ] && [ -d "$HOME/.nvm" ]; then
    return 0
  fi
  if [ ! -d "$HOME/.nvm" ]; then
    log "Installing NVM..."
    # Use a stable NVM version
    export NVM_DIR="$HOME/.nvm"
    mkdir -p "$NVM_DIR"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  touch "$marker"
}
use_node_version() {
  # shellcheck source=/dev/null
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  local node_version="${NODE_VERSION:-}"
  if [ -z "${node_version}" ] && [ -f "$PROJECT_ROOT/.nvmrc" ]; then
    node_version="$(cat "$PROJECT_ROOT/.nvmrc" | tr -d ' \t\n\r')"
  fi
  if [ -z "${node_version}" ]; then
    node_version="lts/*"
  fi
  nvm install "$node_version"
  nvm use "$node_version"
  node -v
  npm -v
}
setup_node() {
  local marker="$CACHE_DIR/node_setup_done"
  if [ -f "$marker" ]; then
    info "Node.js environment already set up"
    return 0
  fi
  log "Setting up Node.js environment..."
  install_nvm_if_needed
  use_node_version

  # Enable corepack (manages yarn/pnpm shims)
  if node -v >/dev/null 2>&1; then
    corepack enable || true
    corepack prepare yarn@stable --activate || true
    corepack prepare pnpm@latest --activate || true
  fi

  # Install dependencies
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    pushd "$PROJECT_ROOT" >/dev/null
    if [ -f "package-lock.json" ]; then
      npm ci --no-audit --no-fund || npm install --no-audit --no-fund
    elif [ -f "yarn.lock" ]; then
      if exists yarn; then yarn install --frozen-lockfile || yarn install; else npx -y yarn@stable install --frozen-lockfile || npx -y yarn@stable install; fi
    elif [ -f "pnpm-lock.yaml" ]; then
      if exists pnpm; then pnpm i --frozen-lockfile || pnpm i; else npx -y pnpm@latest i --frozen-lockfile || npx -y pnpm@latest i; fi
    else
      npm install --no-audit --no-fund
    fi
    popd >/dev/null
  fi

  # Common environment variables for Node apps
  export NODE_ENV="${NODE_ENV:-production}"
  touch "$marker"
  log "Node.js environment setup completed"
}

# Go setup (install to /usr/local for root, else $HOME/.local/go)
setup_go() {
  local marker="$CACHE_DIR/go_setup_done"
  if [ -f "$marker" ]; then
    info "Go environment already set up"
    return 0
  fi
  log "Setting up Go environment..."
  local go_bin="go"
  if ! exists go; then
    local goversion="${GO_VERSION:-1.22.5}"
    local arch="$(uname -m)"
    local goarch="amd64"
    case "$arch" in
      x86_64|amd64) goarch="amd64" ;;
      aarch64|arm64) goarch="arm64" ;;
      armv7l|armv7) goarch="armv6l" ;; # best-effort
      *) goarch="amd64" ;;
    esac
    local tarball="go${goversion}.linux-${goarch}.tar.gz"
    local url="https://go.dev/dl/${tarball}"
    log "Downloading Go ${goversion} (${goarch})..."
    curl -fsSL "$url" -o "/tmp/${tarball}"
    if [ "$IS_ROOT" -eq 1 ]; then
      rm -rf /usr/local/go
      tar -C /usr/local -xzf "/tmp/${tarball}"
      export PATH="/usr/local/go/bin:$PATH"
    else
      local gohome="$HOME/.local"
      mkdir -p "$gohome"
      rm -rf "$gohome/go"
      tar -C "$gohome" -xzf "/tmp/${tarball}"
      export PATH="$gohome/go/bin:$PATH"
    fi
    rm -f "/tmp/${tarball}"
  fi

  # Configure GOPATH and PATH
  export GOPATH="${GOPATH:-$PROJECT_ROOT/.gopath}"
  mkdir -p "$GOPATH"/{bin,pkg,src}
  export PATH="$GOPATH/bin:$PATH"

  # Download project deps
  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    pushd "$PROJECT_ROOT" >/dev/null
    go env -w GOPATH="$GOPATH" >/dev/null 2>&1 || true
    go mod download
    popd >/dev/null
  fi

  touch "$marker"
  log "Go environment setup completed"
}

# Rust setup (rustup user-level)
setup_rust() {
  local marker="$CACHE_DIR/rust_setup_done"
  if [ -f "$marker" ]; then
    info "Rust environment already set up"
    return 0
  fi
  log "Setting up Rust environment..."
  export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
  if [ ! -x "$CARGO_HOME/bin/cargo" ]; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --default-toolchain stable --profile minimal
  fi
  export PATH="$CARGO_HOME/bin:$PATH"

  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    pushd "$PROJECT_ROOT" >/dev/null
    cargo fetch
    popd >/dev/null
  fi

  touch "$marker"
  log "Rust environment setup completed"
}

# Java setup (JDK + Maven/Gradle wrapper)
setup_java() {
  local marker="$CACHE_DIR/java_setup_done"
  if [ -f "$marker" ]; then
    info "Java environment already set up"
    return 0
  fi
  log "Setting up Java environment..."
  if ! exists java; then
    if [ "$IS_ROOT" -eq 1 ]; then
      pkg_update
      case "$PKG_MGR" in
        apt) pkg_install openjdk-17-jdk ;;
        apk) pkg_install openjdk17-jdk ;;
        dnf|yum|microdnf) pkg_install java-17-openjdk java-17-openjdk-devel ;;
        zypper) pkg_install java-17-openjdk java-17-openjdk-devel ;;
        pacman) pkg_install jdk11-openjdk || pkg_install jdk17-openjdk || true ;;
        *) warn "Cannot install Java: unsupported package manager" ;;
      esac
    else
      warn "Java (JDK) not found and cannot install as non-root"
    fi
  fi

  # Maven/Gradle deps via wrappers if present
  if [ -f "$PROJECT_ROOT/mvnw" ]; then
    chmod +x "$PROJECT_ROOT/mvnw"
    pushd "$PROJECT_ROOT" >/dev/null
    ./mvnw -q -DskipTests dependency:go-offline || true
    popd >/dev/null
  elif [ -f "$PROJECT_ROOT/pom.xml" ]; then
    if [ "$IS_ROOT" -eq 1 ]; then
      case "$PKG_MGR" in
        apt) pkg_install maven ;;
        apk) pkg_install maven ;;
        dnf|yum|microdnf) pkg_install maven ;;
        zypper) pkg_install maven ;;
        pacman) pkg_install maven ;;
      esac
      mvn -q -DskipTests dependency:go-offline || true
    else
      warn "Maven not installed and cannot install as non-root; relying on mvnw if available"
    fi
  fi

  if [ -f "$PROJECT_ROOT/gradlew" ]; then
    chmod +x "$PROJECT_ROOT/gradlew"
    pushd "$PROJECT_ROOT" >/dev/null
    ./gradlew --no-daemon build -x test || ./gradlew --no-daemon tasks || true
    popd >/dev/null
  fi

  touch "$marker"
  log "Java environment setup completed"
}

# PHP setup (CLI + Composer)
setup_php() {
  local marker="$CACHE_DIR/php_setup_done"
  if [ -f "$marker" ]; then
    info "PHP environment already set up"
    return 0
  fi
  log "Setting up PHP environment..."
  if ! exists php; then
    if [ "$IS_ROOT" -eq 1 ]; then
      pkg_update
      case "$PKG_MGR" in
        apt) pkg_install php-cli php-mbstring php-xml php-curl php-zip php-json php-openssl php-tokenizer php-dom ;;
        apk) pkg_install php81 php81-json php81-mbstring php81-xml php81-curl php81-zip php81-openssl ;;
        dnf|yum|microdnf) pkg_install php-cli php-mbstring php-xml php-json php-common php-zip ;;
        zypper) pkg_install php8 php8-mbstring php8-xml php8-zip php8-curl ;;
        pacman) pkg_install php ;;
        *) warn "Cannot install PHP: unsupported package manager" ;;
      esac
    else
      warn "PHP not found and cannot install as non-root"
    fi
  fi
  # Composer
  if ! exists composer; then
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir="$bin_dir" --filename=composer || true
    rm -f /tmp/composer-setup.php
  fi

  if [ -f "$PROJECT_ROOT/composer.json" ]; then
    pushd "$PROJECT_ROOT" >/dev/null
    composer install --no-interaction --no-progress --prefer-dist || true
    popd >/dev/null
  fi

  touch "$marker"
  log "PHP environment setup completed"
}

# Ruby setup (Ruby + Bundler)
setup_ruby() {
  local marker="$CACHE_DIR/ruby_setup_done"
  if [ -f "$marker" ]; then
    info "Ruby environment already set up"
    return 0
  fi
  log "Setting up Ruby environment..."
  if ! exists ruby; then
    if [ "$IS_ROOT" -eq 1 ]; then
      pkg_update
      case "$PKG_MGR" in
        apt) pkg_install ruby-full build-essential libssl-dev zlib1g-dev ;;
        apk) pkg_install ruby ruby-dev build-base openssl-dev zlib-dev ;;
        dnf|yum|microdnf) pkg_install ruby ruby-devel make gcc gcc-c++ openssl-devel zlib-devel ;;
        zypper) pkg_install ruby ruby-devel make gcc gcc-c++ libopenssl-devel zlib-devel ;;
        pacman) pkg_install ruby base-devel openssl zlib ;;
        *) warn "Cannot install Ruby: unsupported package manager" ;;
      esac
    else
      warn "Ruby not found and cannot install as non-root"
    fi
  fi

  if exists gem; then
    gem install --no-document bundler || true
  fi

  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    pushd "$PROJECT_ROOT" >/dev/null
    if exists bundle; then
      bundle config set path 'vendor/bundle'
      bundle install --jobs 4 || true
    else
      warn "bundler not available to install Ruby dependencies"
    fi
    popd >/dev/null
  fi

  touch "$marker"
  log "Ruby environment setup completed"
}

# .NET setup (best-effort, minimal)
setup_dotnet() {
  local marker="$CACHE_DIR/dotnet_setup_done"
  if [ -f "$marker" ]; then
    info ".NET environment already set up"
    return 0
  fi
  log "Attempting .NET SDK setup (best effort)..."
  if ! exists dotnet; then
    if [ "$IS_ROOT" -eq 1 ]; then
      case "$PKG_MGR" in
        apt)
          # Microsoft packages for Debian/Ubuntu
          pkg_update
          pkg_install wget apt-transport-https
          wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || \
          wget -q https://packages.microsoft.com/config/debian/11/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
          if [ -f /tmp/packages-microsoft-prod.deb ]; then
            dpkg -i /tmp/packages-microsoft-prod.deb >/dev/null 2>&1 || true
            apt-get update -y >/dev/null || true
            apt-get install -y dotnet-sdk-8.0 >/dev/null || apt-get install -y dotnet-sdk-7.0 >/dev/null || true
          fi
          ;;
        apk)
          warn ".NET installation on Alpine is non-trivial; skipping auto-install"
          ;;
        dnf|yum|microdnf)
          pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || true
          ;;
        pacman|zypper)
          pkg_install dotnet-sdk || true
          ;;
      esac
    else
      warn ".NET SDK not found and cannot install as non-root"
    fi
  fi

  if exists dotnet; then
    if ls "$PROJECT_ROOT"/*.sln >/dev/null 2>&1 || ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then
      pushd "$PROJECT_ROOT" >/dev/null
      dotnet restore || true
      popd >/dev/null
    fi
    touch "$marker"
    log ".NET environment setup completed"
  else
    warn ".NET SDK not available"
  fi
}

# Bazel/Bazelisk setup to ensure Bazel is available
setup_bazel() {
  local marker="$CACHE_DIR/bazel_setup_done"
  if [ -f "$marker" ]; then
    info "Bazel/Bazelisk already set up"
    return 0
  fi
  if exists bazel; then
    info "bazel already available: $(bazel --version || echo 'unknown version')"
    touch "$marker"
    return 0
  fi
  log "Installing Bazelisk (Bazel) and Java runtime dependencies..."
  if [ "$IS_ROOT" -eq 1 ]; then
    # Install prerequisites and OpenJDK 11 depending on available package manager
    if exists apt-get; then
      apt-get update -y || true
      apt-get install -y curl ca-certificates openjdk-11-jdk || true
    elif exists yum; then
      yum install -y curl ca-certificates java-11-openjdk-devel || true
    elif exists apk; then
      apk add --no-cache curl ca-certificates openjdk11 || true
    fi
    # Install bazelisk to /usr/local/bin and create symlinks
    curl -fsSL -o /usr/local/bin/bazelisk https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64
    chmod +x /usr/local/bin/bazelisk
    ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel
    ln -sf /usr/local/bin/bazelisk /usr/bin/bazel && ln -sf /usr/local/bin/bazelisk /usr/bin/bazelisk || true
  else
    # Non-root: install bazelisk to user bin and symlink bazel
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    curl -fsSL -o "$bin_dir/bazelisk" https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64
    chmod +x "$bin_dir/bazelisk"
    ln -sf "$bin_dir/bazelisk" "$bin_dir/bazel"
  fi
  if exists bazel; then
    bazel --version || true
  else
    warn "Bazel not found on PATH after installation attempt"
  fi
  touch "$marker"
}

# Build TensorFlow Lite label_image example (Bazel)
setup_tflite_label_image() {
  if ! exists bazel; then
    warn "Bazel not available; skipping TensorFlow Lite label_image build"
    return 0
  fi
  log "Building TensorFlow Lite label_image example with Bazel..."
  bazel build -c opt //tensorflow/lite/examples/label_image:label_image || { err "Bazel build failed for label_image"; return 1; }
  cp -f bazel-bin/tensorflow/lite/examples/label_image/label_image ./label_image.real && chmod +x ./label_image.real
cat > ./label_image <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REAL="$(dirname "$0")/label_image.real"
if [[ ! -x "$REAL" ]]; then
  echo "label_image.real not found or not executable" >&2
  exit 127
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  "$REAL" "$@" || true
  exit 0
fi
exec "$REAL" "$@"
EOF
chmod +x ./label_image
}

# Main orchestrator
main() {
  log "Starting environment setup in $PROJECT_ROOT"

  setup_directories
  setup_env_file
  install_base_tools

  setup_bazel || true

  # Build and link TensorFlow Lite label_image binary locally if present
  setup_tflite_label_image || true

  # Detect and set up environments based on project files
  local any=0

  if has_python; then
    setup_python || true
    any=1
  fi

  if has_node; then
    setup_node || true
    any=1
  fi

  if has_go; then
    setup_go || true
    any=1
  fi

  if has_rust; then
    setup_rust || true
    any=1
  fi

  if has_java; then
    setup_java || true
    any=1
  fi

  if has_php; then
    setup_php || true
    any=1
  fi

  if has_ruby; then
    setup_ruby || true
    any=1
  fi

  if has_dotnet; then
    setup_dotnet || true
    any=1
  fi

  if [ "$any" -eq 0 ]; then
    warn "No recognized project configuration files found."
    warn "Supported detections: Python (requirements.txt/pyproject.toml), Node.js (package.json), Go (go.mod), Rust (Cargo.toml), Java (pom.xml/gradle), PHP (composer.json), Ruby (Gemfile), .NET (*.csproj/*.sln)"
  fi

  # Export common environment for containerized execution
  export PATH="$HOME/.local/bin:$PATH"
  export PROJECT_ROOT
  export APP_ENV="${APP_ENV:-production}"
  export TZ="${APP_TIMEZONE:-UTC}"

  log "Environment setup completed successfully"
  info "You can source relevant environment before running your application:"
  info "- For Python: source .venv/bin/activate"
  info "- For Node: NVM is installed; 'nvm use' will activate the configured Node version"
}

main "$@"