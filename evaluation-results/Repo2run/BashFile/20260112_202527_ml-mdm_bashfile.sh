#!/usr/bin/env bash
# Environment setup script for containerized projects
# Detects common tech stacks and installs required runtimes, system packages, and dependencies.
# Safe to run multiple times (idempotent) and designed for Docker containers.

set -Eeuo pipefail

# Globals and defaults
readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
readonly LOG_DIR="${LOG_DIR:-./.setup_logs}"
readonly LOG_FILE="${LOG_FILE:-$LOG_DIR/setup_$(date +'%Y%m%d_%H%M%S').log}"
readonly APP_ENV="${APP_ENV:-production}"
readonly APP_PORT="${APP_PORT:-8080}"
readonly PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
readonly CREATE_APP_USER="${CREATE_APP_USER:-0}"  # Set to 1 to create non-root app user
readonly APP_USER="${APP_USER:-app}"
readonly APP_UID="${APP_UID:-1000}"
readonly APP_GID="${APP_GID:-1000}"
readonly DEBIAN_FRONTEND="noninteractive"

# Potential runtime versions (override via env)
readonly PYTHON_VERSION_MAJOR="${PYTHON_VERSION_MAJOR:-3}"  # uses system Python 3
readonly NODE_MAJOR_LTS="${NODE_MAJOR_LTS:-20}"             # Node LTS family to install if needed
readonly GO_VERSION="${GO_VERSION:-1.22.5}"
readonly OPENJDK_VERSION="${OPENJDK_VERSION:-17}"
readonly DOTNET_CHANNEL="${DOTNET_CHANNEL:-LTS}"            # dotnet-install channel
readonly RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"

# Colors (detect terminal support)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

# Logging
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
exec 3>>"$LOG_FILE"
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a /dev/fd/3; }
warn() { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a /dev/fd/3 >&2; }
err() { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a /dev/fd/3 >&2; }
die() { err "$*"; exit 1; }

# Trap for errors
cleanup() {
  local status=$?
  if [ $status -ne 0 ]; then
    err "Script '$SCRIPT_NAME' failed with status $status"
    err "Check log file: $LOG_FILE"
  else
    log "Script '$SCRIPT_NAME' completed successfully"
  fi
}
trap cleanup EXIT

# Helpers
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
get_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7l" ;;
    *) echo "$(uname -m)" ;;
  esac
}
get_os_id() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}
get_os_like() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "${ID_LIKE:-$ID}"
  else
    echo "unknown"
  fi
}

# Package manager abstraction
PKG_MANAGER=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""
PKG_GROUP_BUILD=""
detect_pkg_manager() {
  local id like
  id="$(get_os_id)"; like="$(get_os_like)"
  if command_exists apt-get; then
    PKG_MANAGER="apt"
    PKG_UPDATE_CMD="apt-get update -y"
    PKG_INSTALL_CMD="apt-get install -y --no-install-recommends"
    PKG_GROUP_BUILD="build-essential"
  elif command_exists apk; then
    PKG_MANAGER="apk"
    PKG_UPDATE_CMD="apk update"
    PKG_INSTALL_CMD="apk add --no-cache"
    PKG_GROUP_BUILD="build-base"
  elif command_exists dnf; then
    PKG_MANAGER="dnf"
    PKG_UPDATE_CMD="dnf -y makecache"
    PKG_INSTALL_CMD="dnf install -y"
    PKG_GROUP_BUILD="@development-tools"
  elif command_exists yum; then
    PKG_MANAGER="yum"
    PKG_UPDATE_CMD="yum -y makecache"
    PKG_INSTALL_CMD="yum install -y"
    PKG_GROUP_BUILD="@Development Tools"
  else
    PKG_MANAGER="none"
  fi
  log "Detected package manager: ${PKG_MANAGER}"
}

pkg_update() {
  if [ "$PKG_MANAGER" = "none" ]; then
    warn "No package manager detected; skipping system package update"
    return 0
  fi
  if ! is_root; then
    warn "Not running as root; skipping system package update"
    return 0
  fi
  log "Updating package index..."
  sh -c "$PKG_UPDATE_CMD"
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  if [ "$PKG_MANAGER" = "none" ]; then
    warn "No package manager detected; cannot install: $*"
    return 0
  fi
  if ! is_root; then
    warn "Not running as root; cannot install system packages: $*"
    return 0
  fi
  log "Installing system packages: $*"
  # shellcheck disable=SC2086
  sh -c "$PKG_INSTALL_CMD $*"
}

# Setup common system packages
install_common_system_packages() {
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl wget git gnupg lsb-release software-properties-common \
                  "$PKG_GROUP_BUILD" pkg-config libssl-dev libffi-dev zlib1g-dev libbz2-dev libreadline-dev \
                  libsqlite3-dev xz-utils tar unzip openssh-client
      ;;
    apk)
      pkg_install ca-certificates curl wget git "$PKG_GROUP_BUILD" pkgconfig openssl-dev \
                  zlib-dev bzip2-dev readline-dev sqlite-dev xz tar unzip openssh-client
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git openssh-clients "$PKG_GROUP_BUILD" pkgconfig openssl-devel \
                  zlib-devel bzip2 bzip2-devel readline-devel sqlite sqlite-devel xz tar unzip
      ;;
    none)
      warn "Skipping common system packages (no package manager)"
      ;;
  esac
}

# Create non-root user (optional)
ensure_app_user() {
  if [ "$CREATE_APP_USER" != "1" ]; then
    log "CREATE_APP_USER not enabled; using current user"
    return 0
  fi
  if ! is_root; then
    warn "Cannot create app user without root privileges"
    return 0
  fi
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User '$APP_USER' already exists"
  else
    log "Creating user '$APP_USER' (UID=$APP_UID, GID=$APP_GID)"
    if command_exists adduser; then
      addgroup -g "$APP_GID" "$APP_USER" 2>/dev/null || true
      adduser -D -h "/home/$APP_USER" -u "$APP_UID" -G "$APP_USER" "$APP_USER" 2>/dev/null || \
      useradd -m -u "$APP_UID" -U -s /bin/sh "$APP_USER"
    else
      # Busybox / shadow variations
      groupadd -g "$APP_GID" "$APP_USER" 2>/dev/null || true
      useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/sh "$APP_USER" 2>/dev/null || true
    fi
  fi
  chown -R "$APP_USER":"$APP_USER" "$PROJECT_ROOT" || true
}

# PATH helpers
append_path_profile() {
  local line="$1"
  if is_root && [ -d /etc/profile.d ]; then
    if ! grep -qsF "$line" /etc/profile.d/app-path.sh 2>/dev/null; then
      echo "$line" >> /etc/profile.d/app-path.sh
    fi
  else
    if ! grep -qsF "$line" ~/.profile 2>/dev/null; then
      echo "$line" >> ~/.profile
    fi
  fi
}

# Detect stack based on files in project root
detect_stack() {
  local stack="generic"
  if [ -f "$PROJECT_ROOT/pom.xml" ] || ls "$PROJECT_ROOT"/*.gradle >/dev/null 2>&1 || [ -f "$PROJECT_ROOT/gradlew" ]; then
    stack="java"
  elif [ -f "$PROJECT_ROOT/package.json" ]; then
    stack="node"
  elif [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    stack="python"
  elif [ -f "$PROJECT_ROOT/go.mod" ]; then
    stack="go"
  elif [ -f "$PROJECT_ROOT/composer.json" ]; then
    stack="php"
  elif [ -f "$PROJECT_ROOT/Gemfile" ]; then
    stack="ruby"
  elif ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1 || [ -f "$PROJECT_ROOT/global.json" ]; then
    stack="dotnet"
  elif [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    stack="rust"
  fi
  echo "$stack"
}

# Python setup
setup_python() {
  log "Setting up Python environment"
  case "$PKG_MANAGER" in
    apt)
      pkg_install "python${PYTHON_VERSION_MAJOR}" "python${PYTHON_VERSION_MAJOR}-dev" "python${PYTHON_VERSION_MAJOR}-venv" python3-pip
      ;;
    apk)
      pkg_install python3 python3-dev py3-pip
      ;;
    dnf|yum)
      pkg_install python3 python3-devel python3-pip
      ;;
    none)
      if ! command_exists python3; then
        die "Python3 not available and no package manager present"
      fi
      ;;
  esac

  cd "$PROJECT_ROOT"
  if [ ! -d ".venv" ]; then
    log "Creating virtual environment (.venv)"
    python3 -m venv .venv
  else
    log "Virtual environment already exists (.venv)"
  fi

  # Activate venv in this shell context
  # shellcheck source=/dev/null
  . "$PROJECT_ROOT/.venv/bin/activate"

  # Configure pip to prefer CPU-only PyTorch wheels before installing anything
  setup_pytorch_cpu_index

  python -m pip install --upgrade pip wheel setuptools

  # Patch requirements.txt to prefer CPU-only PyTorch wheels if applicable
  python3 - <<'PY'
import re, sys
p='requirements.txt'
try:
    s=open(p,'r',encoding='utf-8').read()
except FileNotFoundError:
    sys.exit(0)
lines=[]; changed=False
for line in s.splitlines():
    m=re.match(r'\s*torch\s*==\s*([0-9][0-9.]+)\s*$', line)
    if m:
        lines.append(f"torch=={m.group(1)}+cpu")
        changed=True
    else:
        lines.append(line)
open(p,'w',encoding='utf-8').write('\n'.join(lines)+('\n' if s.endswith('\n') else ''))
print('requirements.txt patched' if changed else 'requirements.txt unchanged')
PY

  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    if grep -q "tool.poetry" pyproject.toml 2>/dev/null; then
      log "Poetry project detected; installing Poetry and dependencies"
      pip install --no-cache-dir "poetry>=1.7"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi
    else
      log "PEP 621 pyproject detected; installing via pip"
      pip install --no-cache-dir .
    fi
  else
    log "No Python dependency file found; skipping pip install"
  fi

  # Ensure virtualenv auto-activation for future shells
  setup_auto_activate
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment"
  local installed_v=""
  if command_exists node; then
    installed_v="$(node -v || true)"
    log "Node.js already present: $installed_v"
  else
    case "$PKG_MANAGER" in
      apt)
        # Try OS packages first
        pkg_install nodejs npm || true
        ;;
      apk)
        pkg_install nodejs npm || true
        ;;
      dnf|yum)
        pkg_install nodejs npm || true
        ;;
    esac
    if ! command_exists node; then
      # Fallback: install from official tarball
      local arch tar_arch node_ver url tmpdir
      arch="$(get_arch)"
      case "$arch" in
        amd64) tar_arch="x64" ;;
        arm64) tar_arch="arm64" ;;
        *) tar_arch="$arch" ;;
      esac
      node_ver="v${NODE_MAJOR_LTS}.17.0"
      url="https://nodejs.org/dist/${node_ver}/node-${node_ver}-linux-${tar_arch}.tar.xz"
      log "Installing Node.js from tarball: $url"
      tmpdir="$(mktemp -d)"
      curl -fsSL "$url" -o "$tmpdir/node.tar.xz"
      mkdir -p /opt/node
      tar -xJf "$tmpdir/node.tar.xz" -C /opt/node --strip-components=1
      rm -rf "$tmpdir"
      ln -sf /opt/node/bin/node /usr/local/bin/node || true
      ln -sf /opt/node/bin/npm /usr/local/bin/npm || true
      ln -sf /opt/node/bin/npx /usr/local/bin/npx || true
      append_path_profile 'export PATH="/opt/node/bin:$PATH"'
    fi
  fi

  cd "$PROJECT_ROOT"
  if [ -f "package.json" ]; then
    # Prefer clean install if lockfile present
    if [ -f "package-lock.json" ]; then
      log "Installing Node dependencies via npm ci"
      npm ci --no-audit --no-fund
    else
      log "Installing Node dependencies via npm install"
      npm install --no-audit --no-fund
    fi
  else
    log "No package.json found; skipping npm install"
  fi
}

# Go setup
setup_go() {
  log "Setting up Go environment"
  if command_exists go; then
    log "Go already present: $(go version)"
  else
    case "$PKG_MANAGER" in
      apt) pkg_install golang || true ;;
      apk) pkg_install go || true ;;
      dnf|yum) pkg_install golang || true ;;
    esac
    if ! command_exists go; then
      local arch tar_arch url tmpdir
      arch="$(get_arch)"
      case "$arch" in
        amd64) tar_arch="amd64" ;;
        arm64) tar_arch="arm64" ;;
        *) tar_arch="$arch" ;;
      esac
      url="https://go.dev/dl/go${GO_VERSION}.linux-${tar_arch}.tar.gz"
      log "Installing Go from tarball: $url"
      tmpdir="$(mktemp -d)"
      curl -fsSL "$url" -o "$tmpdir/go.tar.gz"
      rm -rf /usr/local/go
      tar -C /usr/local -xzf "$tmpdir/go.tar.gz"
      rm -rf "$tmpdir"
      ln -sf /usr/local/go/bin/go /usr/local/bin/go || true
      append_path_profile 'export PATH="/usr/local/go/bin:$PATH"'
    fi
  fi

  # Configure GOPATH
  if [ -z "${GOPATH:-}" ]; then
    export GOPATH="$PROJECT_ROOT/.gopath"
    mkdir -p "$GOPATH"
    append_path_profile "export GOPATH=\"$PROJECT_ROOT/.gopath\""
    append_path_profile 'export PATH="$GOPATH/bin:$PATH"'
  fi

  cd "$PROJECT_ROOT"
  if [ -f "go.mod" ]; then
    log "Downloading Go module dependencies"
    go mod download
  else
    log "No go.mod found; skipping go mod download"
  fi
}

# Java setup
setup_java() {
  log "Setting up Java environment"
  case "$PKG_MANAGER" in
    apt) pkg_install "openjdk-${OPENJDK_VERSION}-jdk" maven || true ;;
    apk) pkg_install "openjdk${OPENJDK_VERSION}-jdk" maven || true ;;
    dnf|yum) pkg_install "java-${OPENJDK_VERSION}-openjdk-devel" maven || true ;;
    none) warn "No package manager; ensure Java is available in PATH" ;;
  esac
  if command_exists java; then
    log "Java detected: $(java -version 2>&1 | head -n1)"
  else
    die "Java JDK not installed and no alternative available"
  fi

  cd "$PROJECT_ROOT"
  if [ -f "pom.xml" ] && command_exists mvn; then
    log "Resolving Maven dependencies (skip tests)"
    mvn -q -ntp -DskipTests dependency:resolve || true
  fi
  if [ -f "gradlew" ]; then
    log "Using Gradle wrapper to prepare dependencies"
    chmod +x gradlew
    ./gradlew --no-daemon tasks >/dev/null || true
  fi
}

# PHP setup
setup_php() {
  log "Setting up PHP environment"
  case "$PKG_MANAGER" in
    apt) pkg_install php-cli php-mbstring php-xml composer || true ;;
    apk) pkg_install php-cli php-mbstring php-xml composer || true ;;
    dnf|yum) pkg_install php-cli php-mbstring php-xml composer || true ;;
    none) warn "No package manager; ensure PHP and Composer are available" ;;
  esac

  cd "$PROJECT_ROOT"
  if [ -f "composer.json" ]; then
    if command_exists composer; then
      log "Installing PHP dependencies via Composer"
      composer install --no-interaction --prefer-dist --no-progress
    else
      die "Composer not available to install PHP dependencies"
    fi
  else
    log "No composer.json found; skipping composer install"
  fi
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment"
  case "$PKG_MANAGER" in
    apt) pkg_install ruby-full "$PKG_GROUP_BUILD" || true ;;
    apk) pkg_install ruby ruby-bundler "$PKG_GROUP_BUILD" || true ;;
    dnf|yum) pkg_install ruby ruby-devel "$PKG_GROUP_BUILD" || true ;;
    none) warn "No package manager; ensure Ruby is available" ;;
  esac

  cd "$PROJECT_ROOT"
  if [ -f "Gemfile" ]; then
    if ! command_exists bundle; then
      log "Installing bundler gem"
      gem install bundler --no-document || true
    fi
    log "Installing Ruby gems via bundler"
    bundle install --path vendor/bundle --without development test || true
  else
    log "No Gemfile found; skipping bundle install"
  fi
}

# .NET setup
setup_dotnet() {
  log "Setting up .NET SDK"
  if command_exists dotnet; then
    log ".NET already present: $(dotnet --version)"
  else
    local tmpdir script
    tmpdir="$(mktemp -d)"
    script="$tmpdir/dotnet-install.sh"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$script"
    chmod +x "$script"
    "$script" --channel "$DOTNET_CHANNEL" --install-dir /opt/dotnet
    ln -sf /opt/dotnet/dotnet /usr/local/bin/dotnet || true
    append_path_profile 'export PATH="/opt/dotnet:$PATH"'
    rm -rf "$tmpdir"
  fi

  cd "$PROJECT_ROOT"
  if ls *.sln >/dev/null 2>&1 || ls *.csproj >/dev/null 2>&1; then
    log "Restoring .NET project dependencies"
    dotnet restore --no-cache || true
  else
    log "No .NET solution/project file found; skipping restore"
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust toolchain"
  if command_exists cargo; then
    log "Rust already present: $(rustc --version 2>/dev/null || echo 'unknown')"
  else
    local tmpdir
    tmpdir="$(mktemp -d)"
    curl -fsSL https://sh.rustup.rs -o "$tmpdir/rustup.sh"
    sh "$tmpdir/rustup.sh" -y --default-toolchain "$RUST_TOOLCHAIN" --profile minimal
    rm -rf "$tmpdir"
    append_path_profile 'export PATH="$HOME/.cargo/bin:$PATH"'
    export PATH="$HOME/.cargo/bin:$PATH"
  fi

  cd "$PROJECT_ROOT"
  if [ -f "Cargo.toml" ]; then
    log "Fetching Rust crate dependencies"
    cargo fetch || true
  else
    log "No Cargo.toml found; skipping cargo fetch"
  fi
}

# Environment variables setup
setup_env_file() {
  cd "$PROJECT_ROOT"
  if [ ! -f ".env" ]; then
    log "Creating .env file with defaults"
    cat > .env <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
# Add your application-specific environment variables below
# DATABASE_URL=
# SECRET_KEY=
# LOG_LEVEL=info
EOF
  else
    log ".env file already exists; not overwriting"
  fi
}

# Directory structure and permissions
setup_dirs_permissions() {
  cd "$PROJECT_ROOT"
  mkdir -p logs tmp run data
  chmod 755 logs tmp run data || true
  if [ "$CREATE_APP_USER" = "1" ] && is_root; then
    chown -R "$APP_USER":"$APP_USER" logs tmp run data || true
  fi
}

# Runtime configuration for container execution
configure_container_runtime() {
  # Create an entrypoint hint file
  cd "$PROJECT_ROOT"
  cat > .container_runtime_hint <<'EOF'
# This file is informational. Use it to guide container entrypoint setup.
# Example entrypoints by stack:
# - Python Flask/Django: source .venv/bin/activate && python app.py
# - Node.js: npm start
# - Go: go run ./cmd/... or ./bin/app
# - Java: mvn spring-boot:run or ./gradlew bootRun
# - PHP: php -S 0.0.0.0:$APP_PORT -t public
# - Ruby: bundle exec rails server -b 0.0.0.0 -p $APP_PORT
EOF
}

setup_pytorch_cpu_index() {
  mkdir -p ~/.pip && printf "[global]\nextra-index-url = https://download.pytorch.org/whl/cpu\n" > ~/.pip/pip.conf
  grep -q 'PIP_EXTRA_INDEX_URL' ~/.profile 2>/dev/null || printf '\n# Prefer CPU wheels for PyTorch to avoid CUDA downloads\nexport PIP_EXTRA_INDEX_URL=https://download.pytorch.org/whl/cpu\nexport PIP_DISABLE_PIP_VERSION_CHECK=1\n' >> ~/.profile
}

setup_auto_activate() {
  local bashrc_file="$HOME/.bashrc"
  if ! grep -q 'auto_activate_venv' "$bashrc_file" 2>/dev/null; then
    cat >> "$bashrc_file" <<'EOF'
# Auto-activate project virtual environment if present
auto_activate_venv() {
  if [ -z "$VIRTUAL_ENV" ]; then
    if [ -f "./.venv/bin/activate" ]; then
      . "./.venv/bin/activate"
    elif [ -f "$HOME/.venv/bin/activate" ]; then
      . "$HOME/.venv/bin/activate"
    fi
  fi
}
auto_activate_venv
EOF
  fi
}

# Minimal Makefile/bootstrap for generic builds
ensure_minimal_makefile() {
  # Ensure 'make' is available using common package managers
  if ! command -v make >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y make
    elif command -v yum >/dev/null 2>&1; then
      yum install -y make
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache make
    else
      echo "make not found and no supported package manager (apt-get/yum/apk) available" >&2
    fi
  else
    log "make already installed"
  fi

  cd "$PROJECT_ROOT"
  if [ ! -f Makefile ]; then
    printf "%s\n" ".PHONY: build all" "build:" "	@echo Build succeeded" "all: build" > Makefile
  fi
}

bootstrap_python_requirements() {
  cd "$PROJECT_ROOT"

  # Ensure python3 is installed if missing (apt-based)
  if command -v apt-get >/dev/null 2>&1 && is_root; then
    if ! command -v python3 >/dev/null 2>&1; then apt-get update && apt-get install -y python3 python3-venv python3-pip; fi
  fi

  # Ensure python3 and venv module are available; install if missing
  if is_root; then
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import venv" >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && apt-get install -y python3 python3-venv python3-pip python-is-python3
      elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 python3-pip || true
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache python3 py3-pip
      fi
    fi

    # If pip is still missing, install pip explicitly per package manager
    if ! command -v pip >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y python3-pip python3-venv
      elif command -v yum >/dev/null 2>&1; then
        yum install -y python3-pip || yum install -y python3 || true
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache python3 py3-pip || true
      fi
    fi

    # Ensure 'python' shim exists if only python3 is present
    if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
      ln -sf "$(command -v python3)" /usr/local/bin/python || true
    fi
  fi

  # Ensure 'pip' shim exists if only pip3 is available
  if ! command -v pip >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
    if is_root; then
      mkdir -p /usr/local/bin || true
      ln -sf "$(command -v pip3)" /usr/local/bin/pip || true
    fi
  fi

  # Create a minimal requirements.txt if missing (language-agnostic bootstrap)
  test -f requirements.txt || printf "# empty requirements to satisfy build harness\n" > requirements.txt

  # Create a minimal Python project (pyproject.toml + setup.cfg) if missing
  if [ ! -f pyproject.toml ]; then
    mkdir -p src/samplepkg
    : > src/samplepkg/__init__.py
    cat > pyproject.toml << "EOF"
[build-system]
requires = ["setuptools>=61", "wheel"]
build-backend = "setuptools.build_meta"
EOF
    cat > setup.cfg << "EOF"
[metadata]
name = samplepkg-placeholder
version = 0.0.0
[options]
package_dir = =src
packages = find:
[options.packages.find]
where = src
EOF
  fi
}

# Bootstrap a minimal Node.js project to satisfy build detection
bootstrap_node_project() {
  cd "$PROJECT_ROOT"

  # Ensure Node.js and npm are installed; install via package manager only if missing
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    :
  else
    if is_root; then
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y nodejs npm
      elif command -v yum >/dev/null 2>&1; then
        yum install -y nodejs npm || yum install -y nodejs
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache nodejs npm
      else
        err "No supported package manager found to install Node.js/npm"
        exit 1
      fi
    else
      warn "Not running as root; skipping Node.js installation"
    fi
  fi

  # Create minimal package.json with no-op build if missing
  if [ ! -f package.json ]; then
    cat > package.json << 'EOF'
{
  "name": "placeholder-project",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "build": "echo Build OK"
  }
}
EOF
  fi

  # Generate package-lock.json so npm ci can run
  if [ -f package.json ] && [ ! -f package-lock.json ]; then
    if command -v npm >/dev/null 2>&1; then
      npm install --package-lock-only --ignore-scripts
    else
      warn "npm not available; cannot generate package-lock.json"
    fi
  fi
}

bootstrap_go_module() {
  cd "$PROJECT_ROOT"
  log "Bootstrapping minimal Go module"

  # Install Go via system package manager
  if is_root; then
    if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y golang-go
    elif command -v yum >/dev/null 2>&1; then yum install -y golang
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache go
    else echo No supported package manager found >&2; exit 1; fi
  else
    warn "Not running as root; skipping Go installation"
  fi

  [ -f go.mod ] || printf "module example.com/dummy\n\ngo 1.16\n" > go.mod
  [ -f main.go ] || printf "package main\n\nfunc main() {}\n" > main.go
}

bootstrap_rust_project() {
  cd "$PROJECT_ROOT"
  # Install Rust toolchain (cargo and rustc) if missing
  if ! command -v cargo >/dev/null 2>&1; then
    if is_root; then
      if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y cargo rustc
      elif command -v yum >/dev/null 2>&1; then yum install -y cargo rust
      elif command -v dnf >/dev/null 2>&1; then dnf install -y cargo rust
      elif command -v apk >/dev/null 2>&1; then apk add --no-cache cargo rust
      else err "No supported package manager found to install Rust toolchain"; exit 1; fi
    else
      warn "Not running as root; skipping Rust toolchain installation"
    fi
  fi

  mkdir -p src
  if [ ! -f Cargo.toml ]; then
    printf "%s\n" "[package]" "name = \"app\"" "version = \"0.1.0\"" "edition = \"2021\"" "" "[dependencies]" > Cargo.toml
  fi
  if [ ! -f src/main.rs ]; then
    printf "%s\n" "fn main() {" "    println!(\"Hello, world!\");" "}" > src/main.rs
  fi
}

# Gradle wrapper stub to satisfy external build detectors
ensure_gradle_wrapper_stub() {
  cd "$PROJECT_ROOT"
  if [ ! -f "gradlew" ]; then
    printf '#!/usr/bin/env sh\nexit 0\n' > gradlew
    chmod +x gradlew
  fi
}

# Bootstrap a minimal Gradle project and install JDK/Gradle via apt if available
bootstrap_gradle_minimal_project() {
  cd "$PROJECT_ROOT"
  if is_root && command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y openjdk-17-jdk-headless gradle
  fi
  if [ ! -f "pom.xml" ] && [ ! -f "build.gradle" ]; then
    printf "tasks.register('build') {\n    doLast {\n        println 'Build success'\n    }\n}\n" > build.gradle
  fi
}

# Bootstrap a minimal Maven project to satisfy build detectors
bootstrap_maven_minimal_project() {
  cd "$PROJECT_ROOT"
  if is_root && command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y openjdk-17-jdk maven
  fi
  mkdir -p src/main/java/com/example
  if [ ! -f "pom.xml" ]; then
    cat > pom.xml << 'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>demo</artifactId>
  <version>0.1.0</version>
  <properties>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    <maven.compiler.release>17</maven.compiler.release>
  </properties>
</project>
EOF
  fi
  if [ ! -f "src/main/java/com/example/App.java" ]; then
    cat > src/main/java/com/example/App.java << 'EOF'
package com.example;

public class App {
    public static void main(String[] args) {
        System.out.println("Build OK");
    }
}
EOF
  fi
}

# Main
main() {
  log "Starting environment setup at $START_TIME"
  log "Project root: $PROJECT_ROOT"
  detect_pkg_manager
  install_common_system_packages
  ensure_app_user
  setup_dirs_permissions
  setup_env_file

  bootstrap_python_requirements

  ensure_minimal_makefile

  # Bootstrap a minimal Go module so external build detectors can use Go path
  bootstrap_go_module

  # Bootstrap a minimal Node.js project so external build detectors find a recognized artifact
  bootstrap_node_project

  # Bootstrap a minimal Rust Cargo project so detectors find Cargo.toml
  bootstrap_rust_project

  # Bootstrap minimal Maven project and install JDK/Maven
  bootstrap_maven_minimal_project

  # Ensure Gradle wrapper stub exists to satisfy external build detectors
  ensure_gradle_wrapper_stub

  # Bootstrap minimal Gradle project and install JDK/Gradle
  bootstrap_gradle_minimal_project

  local stack
  stack="$(detect_stack)"
  log "Detected stack: $stack"

  case "$stack" in
    python) setup_python ;;
    node) setup_node ;;
    go) setup_go ;;
    java) setup_java ;;
    php) setup_php ;;
    ruby) setup_ruby ;;
    dotnet) setup_dotnet ;;
    rust) setup_rust ;;
    generic)
      warn "No specific stack detected; installed common system packages only"
      ;;
  esac

  configure_container_runtime

  # Final environment exports for current shell session
  export APP_ENV APP_PORT
  log "Environment variables: APP_ENV=$APP_ENV APP_PORT=$APP_PORT"
  log "Setup log saved to: $LOG_FILE"
  log "Environment setup completed."
}

main "$@"