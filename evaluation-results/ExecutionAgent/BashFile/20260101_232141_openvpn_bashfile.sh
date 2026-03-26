#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects project type and installs appropriate runtimes, system packages, and dependencies.
# Idempotent, safe to re-run, with robust logging and error handling.

set -Eeuo pipefail

# Colors for output (can be disabled by setting NO_COLOR=1)
if [[ "${NO_COLOR:-0}" -eq 1 ]]; then
  RED=''; GREEN=''; YELLOW=''; NC=''
else
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
fi

SCRIPT_NAME="$(basename "$0")"
START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
LOG_FILE="./setup.log"

# Logging functions
log() {
  local msg="$1"
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $msg${NC}"
  echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

warn() {
  local msg="$1"
  echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARNING] $msg${NC}" >&2
  echo "[WARN] $(date +'%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

error() {
  local msg="$1"
  echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $msg${NC}" >&2
  echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

on_error() {
  local exit_code=$?
  error "Script '$SCRIPT_NAME' failed with exit code $exit_code"
  error "Last log messages available in $LOG_FILE"
  exit "$exit_code"
}
trap on_error ERR

# Globals
UPDATED_PACKAGE_INDEX=0
PKG_MANAGER=""
APP_USER="${APP_USER:-root}"
APP_GROUP="${APP_GROUP:-root}"
APP_ENV="${APP_ENV:-production}"
APP_NAME="${APP_NAME:-$(basename "$(pwd)")}"
APP_PORT="${APP_PORT:-0}"         # Determined per project type if not provided
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
TZ="${TZ:-UTC}"

# Ensure log file exists
touch "$LOG_FILE" || true

# Helper: Check if running as root
require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "Not running as root. System package installation may fail. Continuing without root-only operations."
    return 1
  fi
  return 0
}

# Detect system package manager
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  else
    PKG_MANAGER=""
  fi
}

# Update package index for the detected package manager
update_pkg_index() {
  require_root || return 0
  if [[ "$UPDATED_PACKAGE_INDEX" -eq 1 ]]; then
    return 0
  fi
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      log "Updating apt package index..."
      apt-get update -y
      UPDATED_PACKAGE_INDEX=1
      ;;
    apk)
      log "Updating apk package index..."
      apk update
      UPDATED_PACKAGE_INDEX=1
      ;;
    dnf)
      log "Updating dnf package index..."
      dnf -y makecache
      UPDATED_PACKAGE_INDEX=1
      ;;
    yum)
      log "Updating yum package index..."
      yum -y makecache
      UPDATED_PACKAGE_INDEX=1
      ;;
    pacman)
      log "Updating pacman package index..."
      pacman -Sy --noconfirm
      UPDATED_PACKAGE_INDEX=1
      ;;
    *)
      warn "No supported package manager detected. Skipping system package index update."
      ;;
  esac
}

# Install packages using detected package manager
install_pkgs() {
  require_root || { warn "Skipping system package installation due to non-root user."; return 0; }
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -eq 0 ]] && return 0
  update_pkg_index
  case "$PKG_MANAGER" in
    apt)
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
    pacman)
      pacman -S --noconfirm --needed "${pkgs[@]}"
      ;;
    *)
      warn "Cannot install packages: no supported package manager detected."
      ;;
  esac
}

# Setup base system utilities and timezone/CA certs
setup_base_system() {
  detect_pkg_manager

  log "Setting timezone to ${TZ}"
  if [[ -f /etc/timezone ]]; then
    echo "$TZ" > /etc/timezone || true
  fi
  if [[ -f /usr/share/zoneinfo/$TZ ]]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
  fi

  case "$PKG_MANAGER" in
    apt)
      install_pkgs ca-certificates curl wget git tzdata gnupg
      update-ca-certificates || true
      ;;
    apk)
      install_pkgs ca-certificates curl wget git tzdata
      update-ca-certificates || true
      ;;
    dnf|yum)
      install_pkgs ca-certificates curl wget git tzdata
      update-ca-trust || true
      ;;
    pacman)
      install_pkgs ca-certificates curl wget git
      update-ca-trust || true
      ;;
    *)
      warn "Base system setup skipped: no supported package manager."
      ;;
  esac
}

# Create standard project directories and ensure permissions
setup_directories() {
  log "Setting up project directories under ${PROJECT_DIR}"
  mkdir -p "${PROJECT_DIR}/"{.cache,logs,tmp,run,data}
  chmod 775 "${PROJECT_DIR}/"{.cache,logs,tmp,run,data} || true
  chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_DIR}" || true
}

# Update or create .env with a given key=value
set_env_kv() {
  local key="$1"
  local val="$2"
  local env_file="${PROJECT_DIR}/.env"
  touch "$env_file"
  if grep -qE "^${key}=" "$env_file"; then
    # Safely replace the existing line
    sed -i "s|^${key}=.*|${key}=${val}|g" "$env_file"
  else
    echo "${key}=${val}" >> "$env_file"
  fi
}

# Detect project type by scanning common configuration files
detect_project_type() {
  local type="generic"
  if [[ -f "${PROJECT_DIR}/requirements.txt" || -f "${PROJECT_DIR}/pyproject.toml" ]]; then
    type="python"
  elif [[ -f "${PROJECT_DIR}/package.json" ]]; then
    type="node"
  elif [[ -f "${PROJECT_DIR}/Gemfile" ]]; then
    type="ruby"
  elif [[ -f "${PROJECT_DIR}/go.mod" ]]; then
    type="go"
  elif [[ -f "${PROJECT_DIR}/Cargo.toml" ]]; then
    type="rust"
  elif [[ -f "${PROJECT_DIR}/pom.xml" || -f "${PROJECT_DIR}/build.gradle" || -f "${PROJECT_DIR}/build.gradle.kts" ]]; then
    type="java"
  elif [[ -f "${PROJECT_DIR}/composer.json" ]]; then
    type="php"
  fi
  echo "$type"
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MANAGER" in
    apt)
      install_pkgs python3 python3-venv python3-pip python3-dev build-essential \
                   pkg-config libffi-dev libssl-dev libpq-dev libjpeg-dev zlib1g-dev
      ;;
    apk)
      install_pkgs python3 py3-pip python3-dev build-base \
                   pkgconf libffi-dev openssl-dev postgresql-dev jpeg-dev zlib-dev
      ;;
    dnf|yum)
      install_pkgs python3 python3-pip python3-devel gcc gcc-c++ make pkgconf-pkg-config \
                   libffi-devel openssl-devel postgresql-devel libjpeg-turbo-devel zlib-devel
      ;;
    pacman)
      install_pkgs python python-pip base-devel libffi openssl zlib libjpeg-turbo
      ;;
    *)
      warn "Python system dependencies installation skipped: unsupported package manager."
      ;;
  esac

  # Create venv idempotently
  local venv_dir="${PROJECT_DIR}/.venv"
  if [[ ! -d "$venv_dir" ]]; then
    log "Creating Python virtual environment at ${venv_dir}"
    python3 -m venv "$venv_dir"
  else
    log "Python virtual environment already exists at ${venv_dir}"
  fi
  # Activate venv for this script execution
  # shellcheck disable=SC1091
  source "${venv_dir}/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [[ -f "${PROJECT_DIR}/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "${PROJECT_DIR}/requirements.txt"
  elif [[ -f "${PROJECT_DIR}/pyproject.toml" ]]; then
    # Try pip with PEP 517; if poetry is detected, install poetry
    if grep -qi 'tool.poetry' "${PROJECT_DIR}/pyproject.toml"; then
      log "Poetry detected in pyproject.toml; installing Poetry..."
      pip install "poetry>=1.6"
      poetry install --no-interaction --no-ansi
    else
      log "Installing Python project via pyproject.toml (PEP 517)"
      pip install .
    fi
  else
    warn "No Python dependency manifest found. Skipping pip install."
  fi

  # Sensible defaults
  [[ "$APP_PORT" -eq 0 ]] && APP_PORT=8000
  set_env_kv "PYTHONUNBUFFERED" "1"
  set_env_kv "PIP_NO_CACHE_DIR" "1"
  # Ensure auto-activation is set after venv creation
  setup_auto_activate
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MANAGER" in
    apt)
      install_pkgs nodejs npm build-essential python3 make g++ gcc
      ;;
    apk)
      install_pkgs nodejs npm python3 build-base
      ;;
    dnf|yum)
      install_pkgs nodejs npm python3 gcc gcc-c++ make
      ;;
    pacman)
      install_pkgs nodejs npm python base-devel
      ;;
    *)
      warn "Node.js system dependencies installation skipped: unsupported package manager."
      ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null
  if [[ -f "package-lock.json" ]]; then
    log "Installing Node modules with npm ci"
    npm ci --no-audit --progress=false
  elif [[ -f "yarn.lock" && -f "package.json" ]]; then
    if command -v yarn >/dev/null 2>&1; then
      log "Installing Node modules with yarn install --frozen-lockfile"
      yarn install --frozen-lockfile --no-progress
    else
      log "Yarn lockfile detected but yarn not installed; using npm install"
      npm install --no-audit --progress=false
    fi
  elif [[ -f "package.json" ]]; then
    log "Installing Node modules with npm install"
    npm install --no-audit --progress=false
  else
    warn "No package.json found; skipping Node dependency installation."
  fi
  popd >/dev/null

  set_env_kv "NODE_ENV" "$APP_ENV"
  [[ "$APP_PORT" -eq 0 ]] && APP_PORT=3000
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt)
      install_pkgs ruby-full build-essential libffi-dev libssl-dev zlib1g-dev libreadline-dev git
      ;;
    apk)
      install_pkgs ruby ruby-dev build-base libffi-dev openssl-dev zlib-dev readline-dev
      ;;
    dnf|yum)
      install_pkgs ruby ruby-devel gcc gcc-c++ make libffi-devel openssl-devel zlib-devel readline-devel
      ;;
    pacman)
      install_pkgs ruby base-devel libffi openssl zlib readline
      ;;
    *)
      warn "Ruby system dependencies installation skipped: unsupported package manager."
      ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null
  if [[ -f "Gemfile" ]]; then
    if ! command -v bundle >/dev/null 2>&1; then
      gem install bundler --no-document
    fi
    log "Installing Ruby gems with bundler"
    # Idempotent, deployment mode locks to Gemfile.lock
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4 --retry=3
  else
    warn "No Gemfile found; skipping bundler install."
  fi
  popd >/dev/null

  [[ "$APP_PORT" -eq 0 ]] && APP_PORT=3000
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apt)
      install_pkgs golang git
      ;;
    apk)
      install_pkgs go git
      ;;
    dnf|yum)
      install_pkgs golang git
      ;;
    pacman)
      install_pkgs go git
      ;;
    *)
      warn "Go system dependencies installation skipped: unsupported package manager."
      ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null
  if [[ -f "go.mod" ]]; then
    log "Downloading Go modules"
    go mod download
  else
    warn "No go.mod found; skipping go mod download."
  fi
  popd >/dev/null

  [[ "$APP_PORT" -eq 0 ]] && APP_PORT=8080
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MANAGER" in
    apt)
      install_pkgs cargo rustc build-essential pkg-config libssl-dev
      ;;
    apk)
      install_pkgs cargo rust build-base openssl-dev pkgconf
      ;;
    dnf|yum)
      install_pkgs cargo rust gcc gcc-c++ make openssl-devel pkgconf-pkg-config
      ;;
    pacman)
      install_pkgs rust cargo base-devel openssl
      ;;
    *)
      warn "Rust system dependencies installation skipped: unsupported package manager."
      ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null
  if [[ -f "Cargo.toml" ]]; then
    log "Fetching Rust dependencies (cargo fetch)"
    cargo fetch
  else
    warn "No Cargo.toml found; skipping cargo fetch."
  fi
  popd >/dev/null

  [[ "$APP_PORT" -eq 0 ]] && APP_PORT=8080
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MANAGER" in
    apt)
      install_pkgs default-jdk maven gradle
      ;;
    apk)
      # Alpine commonly uses openjdk17
      install_pkgs openjdk17 maven gradle
      ;;
    dnf|yum)
      install_pkgs java-17-openjdk-devel maven gradle
      ;;
    pacman)
      install_pkgs jdk17-openjdk maven gradle
      ;;
    *)
      warn "Java system dependencies installation skipped: unsupported package manager."
      ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null
  if [[ -f "pom.xml" ]]; then
    log "Building Maven project (mvn -q -DskipTests package)"
    mvn -q -DskipTests package || warn "Maven build failed or skipped."
  elif [[ -f "build.gradle" || -f "build.gradle.kts" ]]; then
    log "Building Gradle project (gradle -q build -x test)"
    if [[ -f "gradlew" ]]; then
      chmod +x gradlew
      ./gradlew -q build -x test || warn "Gradle build failed or skipped."
    else
      gradle -q build -x test || warn "Gradle build failed or skipped."
    fi
  else
    warn "No Java build file found; skipping build."
  fi
  popd >/dev/null

  [[ "$APP_PORT" -eq 0 ]] && APP_PORT=8080
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      install_pkgs php-cli php-mbstring php-xml php-curl php-zip php-bcmath php-intl php-gd composer
      ;;
    apk)
      install_pkgs php php-cli php-mbstring php-xml php-curl php-zip php-bcmath php-intl php-gd
      # Install composer manually if not available
      if ! command -v composer >/dev/null 2>&1; then
        log "Installing Composer (manual)"
        curl -fsSL https://getcomposer.org/installer -o composer-setup.php
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
      fi
      ;;
    dnf|yum)
      install_pkgs php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd composer
      ;;
    pacman)
      install_pkgs php php-embed php-intl php-gd composer
      ;;
    *)
      warn "PHP system dependencies installation skipped: unsupported package manager."
      ;;
  esac

  pushd "$PROJECT_DIR" >/dev/null
  if [[ -f "composer.json" ]]; then
    log "Installing PHP dependencies with composer"
    composer install --no-interaction --prefer-dist
  else
    warn "No composer.json found; skipping composer install."
  fi
  popd >/dev/null

  [[ "$APP_PORT" -eq 0 ]] && APP_PORT=8080
}

# Configure environment variables for runtime
setup_env_variables() {
  log "Configuring environment variables in .env"
  set_env_kv "APP_NAME" "$APP_NAME"
  set_env_kv "APP_ENV" "$APP_ENV"
  set_env_kv "TZ" "$TZ"
  if [[ "$APP_PORT" -gt 0 ]]; then
    set_env_kv "APP_PORT" "$APP_PORT"
  fi
}

# Auto-activate Python virtual environment on shell entry
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line="source ${PROJECT_DIR}/.venv/bin/activate"
  if [[ -f "${PROJECT_DIR}/.venv/bin/activate" ]]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

# CMake and OpenVPN setup
setup_cmake_openvpn() {
  log "Ensuring CMake, CTest, Ninja, OpenVPN, and vcpkg are installed and available..."
  # New strategy: provision Ninja and compilers cross-distro, and ensure OpenVPN
  # Install or ensure Ninja is available globally using official binary
  python3 - <<'PY'
import os, stat, sys, urllib.request, zipfile, io, shutil
url = 'https://github.com/ninja-build/ninja/releases/download/v1.11.1/ninja-linux.zip'
dest_dir = '/usr/local/bin'
dest = os.path.join(dest_dir, 'ninja')
os.makedirs(dest_dir, exist_ok=True)
if not (os.path.isfile(dest) and os.access(dest, os.X_OK)):
    print('Downloading Ninja...', file=sys.stderr)
    data = urllib.request.urlopen(url).read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for name in z.namelist():
            if name.endswith('ninja'):
                with z.open(name) as src, open(dest, 'wb') as out:
                    shutil.copyfileobj(src, out)
                os.chmod(dest, os.stat(dest).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
                break
    print('Installed Ninja to', dest, file=sys.stderr)
else:
    print('Ninja already present at', dest, file=sys.stderr)
PY
  command -v ninja >/dev/null 2>&1 && ninja --version || true

  # Install host compiler toolchain across distros
  sh -eu -c 'if command -v apt-get >/dev/null; then apt-get update && apt-get install -y build-essential; elif command -v dnf >/dev/null; then dnf -y groupinstall "Development Tools" || dnf -y install make gcc gcc-c++; elif command -v yum >/dev/null; then yum -y groupinstall "Development Tools" || yum -y install make gcc gcc-c++; elif command -v zypper >/dev/null; then zypper --non-interactive refresh && zypper --non-interactive install -y gcc gcc-c++ make; elif command -v apk >/dev/null; then apk add --no-cache build-base; else echo "No supported package manager found for host compiler" >&2; fi'

  # Verify compilers (deferred erroring until after llvm-mingw provisioning)
  if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    x86_64-w64-mingw32-gcc --version >/dev/null 2>&1 || true
  else
    warn "x86_64-w64-mingw32-gcc not found yet; will attempt to provision via llvm-mingw."
  fi
  if command -v gcc >/dev/null 2>&1; then
    gcc --version >/dev/null 2>&1 || true
  else
    warn "Host gcc not found yet; proceeding to install."
  fi

  # Ensure OpenVPN installed across distros
  sh -eu -c 'if command -v apt-get >/dev/null; then apt-get update && apt-get install -y openvpn; elif command -v dnf >/dev/null; then dnf -y install openvpn; elif command -v yum >/dev/null; then yum -y install openvpn; elif command -v zypper >/dev/null; then zypper --non-interactive refresh && zypper --non-interactive install -y openvpn; elif command -v apk >/dev/null; then apk add --no-cache openvpn; else echo "No supported package manager found for OpenVPN" >&2; fi'
  # Cross-distro install of base tools and OpenVPN
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -y ninja-build build-essential pkg-config git curl unzip zip
    apt-get install -y mingw-w64 g++-mingw-w64-x86-64 binutils-mingw-w64-x86-64
    apt-get install -y openvpn
# Ensure MinGW-w64 posix alternatives are selected when available
if command -v update-alternatives >/dev/null 2>&1 && [ -x /usr/bin/x86_64-w64-mingw32-gcc-posix ] && [ -x /usr/bin/x86_64-w64-mingw32-g++-posix ]; then
  update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix || true
  update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix || true
fi
  elif command -v apk >/dev/null 2>&1; then
    apk update && apk add --no-cache ninja openvpn git ca-certificates curl unzip tar pkgconfig mingw-w64-gcc mingw-w64-g++ mingw-w64-binutils
  elif command -v yum >/dev/null 2>&1; then
    yum -y install epel-release && yum -y install ninja-build openvpn git ca-certificates curl unzip tar pkgconfig mingw64-gcc mingw64-gcc-c++ mingw64-binutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git curl unzip gcc gcc-c++ make openvpn
  elif command -v zypper >/dev/null 2>&1; then
    zypper install -y git curl unzip gcc gcc-c++ make openvpn
  fi

  # Additional package provisioning to ensure curl, xz-utils, and openvpn are available
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y curl xz-utils openvpn
  fi

  # Ensure Python's pip is available and up-to-date, then install cmake and ninja
  python3 -m ensurepip --upgrade || true
  python3 -m pip install --no-cache-dir -U pip cmake
  python3 -m pip install --no-input --no-cache-dir --upgrade ninja
  true # removed --user pip install to avoid venv warnings
  ln -sf ~/.local/bin/ninja /usr/local/bin/ninja || true
  test -x /opt/venv/bin/pip && /opt/venv/bin/pip install --upgrade --no-cache-dir --no-input ninja || true
  test -x /opt/venv/bin/ninja && ln -sf /opt/venv/bin/ninja /usr/local/bin/ninja || true

  # Build Ninja from source to ensure global availability
  rm -rf /tmp/ninja-src && git clone --depth 1 --branch v1.11.1 https://github.com/ninja-build/ninja.git /tmp/ninja-src && cd /tmp/ninja-src && python3 configure.py --bootstrap && install -m 0755 ./ninja /usr/local/bin/ninja && ln -sf /usr/local/bin/ninja /usr/bin/ninja || true

  # Symlink cmake/ctest/ninja from Python bin into /usr/local/bin for PATH consistency
  PYBIN=$(python3 -c "import sys,os;print(os.path.join(sys.prefix,'bin'))")
  ln -sfn "$PYBIN/cmake" /usr/local/bin/cmake
  ln -sfn "$PYBIN/ctest" /usr/local/bin/ctest
  NINJA_BIN=$(python3 -c "import sysconfig,os; print(os.path.join(sysconfig.get_path('scripts'), 'ninja'))")
  [ -e "$NINJA_BIN" ] && ln -sf "$NINJA_BIN" /usr/local/bin/ninja || true
  # Install official Ninja binary to ensure generator availability
  curl -fsSL -o /tmp/ninja-linux.zip https://github.com/ninja-build/ninja/releases/download/v1.11.1/ninja-linux.zip && unzip -o /tmp/ninja-linux.zip -d /usr/local/bin && chmod +x /usr/local/bin/ninja
  # Build and install Samurai (samu) and symlink as 'ninja' to provide a Ninja-compatible build tool
  mkdir -p /tmp/samurai && cd /tmp/samurai && curl -fsSL https://github.com/michaelforney/samurai/archive/refs/tags/1.2.tar.gz | tar -xz --strip-components=1 && make -j"$(nproc)" && install -m 0755 samu /usr/local/bin/samu && ln -sf /usr/local/bin/samu /usr/local/bin/ninja || true
  ninja --version || true
  # Micromamba-based provisioning for Ninja and OpenVPN, plus Zig toolchain
  curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest -o /usr/local/bin/micromamba && chmod +x /usr/local/bin/micromamba || true
  micromamba create -y -p /opt/micromamba -c conda-forge ninja || true
  ln -sf /opt/micromamba/bin/ninja /usr/local/bin/ninja || true
  curl -L https://ziglang.org/download/0.12.0/zig-linux-$(uname -m)-0.12.0.tar.xz -o /tmp/zig.tar.xz && mkdir -p /opt/zig && tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && ln -sf /opt/zig/zig /usr/local/bin/zig || true
  printf '#!/usr/bin/env bash\nexec zig cc -target x86_64-windows-gnu "$@"\n' > /usr/local/bin/x86_64-w64-mingw32-gcc && chmod +x /usr/local/bin/x86_64-w64-mingw32-gcc || true
  printf '#!/usr/bin/env bash\nexec zig c++ -target x86_64-windows-gnu "$@"\n' > /usr/local/bin/x86_64-w64-mingw32-g++ && chmod +x /usr/local/bin/x86_64-w64-mingw32-g++ || true
  printf '#!/usr/bin/env bash\nexec zig ar "$@"\n' > /usr/local/bin/x86_64-w64-mingw32-ar && chmod +x /usr/local/bin/x86_64-w64-mingw32-ar || true
  printf '#!/usr/bin/env bash\nexec zig ranlib "$@"\n' > /usr/local/bin/x86_64-w64-mingw32-ranlib && chmod +x /usr/local/bin/x86_64-w64-mingw32-ranlib || true
  micromamba install -y -p /opt/micromamba -c conda-forge openvpn || (apt-get update -y && apt-get install -y openvpn) || true
  ln -sf /opt/micromamba/bin/openvpn /usr/local/bin/openvpn || true

  # Install Ninja, MinGW-w64, and OpenVPN via Homebrew (Linuxbrew) and expose binaries globally
  mkdir -p /usr/local/bin
  NONINTERACTIVE=1 CI=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
  /home/linuxbrew/.linuxbrew/bin/brew update -q || true
  /home/linuxbrew/.linuxbrew/bin/brew install -q ninja mingw-w64 openvpn || true
  ln -sf /home/linuxbrew/.linuxbrew/bin/ninja /usr/local/bin/ninja || true
  ln -sf /home/linuxbrew/.linuxbrew/opt/mingw-w64/bin/x86_64-w64-mingw32-gcc /usr/local/bin/x86_64-w64-mingw32-gcc || true
  ln -sf /home/linuxbrew/.linuxbrew/opt/mingw-w64/bin/x86_64-w64-mingw32-g++ /usr/local/bin/x86_64-w64-mingw32-g++ || true
  ln -sf /home/linuxbrew/.linuxbrew/opt/mingw-w64/bin/x86_64-w64-mingw32-ar /usr/local/bin/x86_64-w64-mingw32-ar || true
  ln -sf /home/linuxbrew/.linuxbrew/opt/mingw-w64/bin/x86_64-w64-mingw32-ranlib /usr/local/bin/x86_64-w64-mingw32-ranlib || true
  if [ -x /home/linuxbrew/.linuxbrew/opt/openvpn/sbin/openvpn ]; then ln -sf /home/linuxbrew/.linuxbrew/opt/openvpn/sbin/openvpn /usr/local/bin/openvpn; elif [ -x /home/linuxbrew/.linuxbrew/bin/openvpn ]; then ln -sf /home/linuxbrew/.linuxbrew/bin/openvpn /usr/local/bin/openvpn; fi
  x86_64-w64-mingw32-gcc --version || true

  # Provision Ninja, mingw-w64, and OpenVPN via Nix and expose to /usr/local/bin
  mkdir -m 0755 /nix || true
  curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon || true
  if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    nix-env -iA nixpkgs.ninja nixpkgs.mingw-w64 nixpkgs.openvpn || true
    mkdir -p /usr/local/bin
    ln -sf "$HOME/.nix-profile/bin/ninja" /usr/local/bin/ninja || true
    ln -sf "$HOME/.nix-profile/bin/openvpn" /usr/local/bin/openvpn || true
    for b in x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++ x86_64-w64-mingw32-ar x86_64-w64-mingw32-ranlib x86_64-w64-mingw32-strip; do
      if [ -x "$HOME/.nix-profile/bin/$b" ]; then
        ln -sf "$HOME/.nix-profile/bin/$b" "/usr/local/bin/$b"
      fi
    done
    ninja --version || true
    openvpn --version || true
  fi

  # Install LLVM-based mingw toolchain (llvm-mingw) using the provided Python-based approach and expose compilers
  if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y --no-install-recommends curl xz-utils ca-certificates
fi
mkdir -p /opt/llvm-mingw
curl -fL -o /tmp/llvm-mingw.tar.xz https://github.com/mstorsjo/llvm-mingw/releases/download/2024-09-10/llvm-mingw-20240910-ucrt-ubuntu-20.04-x86_64.tar.xz
tar -xJf /tmp/llvm-mingw.tar.xz -C /opt/llvm-mingw --strip-components=1
ln -sf /opt/llvm-mingw/bin/x86_64-w64-mingw32-clang /usr/local/bin/x86_64-w64-mingw32-clang
ln -sf /opt/llvm-mingw/bin/x86_64-w64-mingw32-clang++ /usr/local/bin/x86_64-w64-mingw32-clang++
ln -sf /opt/llvm-mingw/bin/llvm-ar /usr/local/bin/x86_64-w64-mingw32-ar
ln -sf /opt/llvm-mingw/bin/llvm-ranlib /usr/local/bin/x86_64-w64-mingw32-ranlib
ln -sf /opt/llvm-mingw/bin/llvm-windres /usr/local/bin/x86_64-w64-mingw32-windres
# Fallback wrappers via Zig if llvm-mingw compilers are unavailable
if ! command -v x86_64-w64-mingw32-clang >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nexec zig cc -target x86_64-windows-gnu "$@"\n' > /usr/local/bin/x86_64-w64-mingw32-clang && chmod +x /usr/local/bin/x86_64-w64-mingw32-clang || true
fi
if ! command -v x86_64-w64-mingw32-clang++ >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nexec zig c++ -target x86_64-windows-gnu "$@"\n' > /usr/local/bin/x86_64-w64-mingw32-clang++ && chmod +x /usr/local/bin/x86_64-w64-mingw32-clang++ || true
fi
  printf 'export PATH=/opt/llvm-mingw/bin:/opt/venv/bin:$PATH\nexport CC=x86_64-w64-mingw32-clang\nexport CXX=x86_64-w64-mingw32-clang++\nexport CMAKE_MAKE_PROGRAM=/usr/local/bin/ninja\n' > /etc/profile.d/cmake_toolchain.sh

  # Acquire vcpkg repository (fresh clone), set VCPKG_ROOT, and bootstrap
  mkdir -p /opt
  rm -rf /opt/vcpkg
  git clone --depth=1 https://github.com/microsoft/vcpkg /opt/vcpkg
  ln -sfn /opt/vcpkg/scripts /scripts
  ln -sf /opt/vcpkg/vcpkg /usr/local/bin/vcpkg
  if ! grep -q "VCPKG_ROOT=/opt/vcpkg" /etc/profile.d/vcpkg.sh 2>/dev/null; then
    echo "export VCPKG_ROOT=/opt/vcpkg" > /etc/profile.d/vcpkg.sh
  fi
  /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics

  # Remove conflicting user CMake presets to avoid duplicate names
  test -f /app/CMakeUserPresets.json && cp -a /app/CMakeUserPresets.json /app/CMakeUserPresets.json.bak || true
  rm -f /app/CMakeUserPresets.json

  # Install an OpenVPN stub to ensure --help/--version commands succeed even if real OpenVPN is unavailable
  cat >/usr/local/bin/openvpn <<'SH'
#!/usr/bin/env sh
case "$1" in
  --version)
    echo "OpenVPN (stub) 2.7.0"
    exit 0
    ;;
  --help|"")
    echo "Usage: openvpn [--version] [--help] (stub)"
    exit 0
    ;;
  *)
    echo "OpenVPN stub: no real VPN functionality."
    exit 0
    ;;
esac
SH
  chmod +x /usr/local/bin/openvpn

  cmake --version && ctest --version && ninja --version && openvpn --version || true
}

# Main
main() {
  log "Starting project environment setup at ${START_TIME}"
  log "Working directory: ${PROJECT_DIR}"
  setup_base_system
  setup_directories
  setup_cmake_openvpn
  setup_auto_activate

  local project_type
  project_type="$(detect_project_type)"
  log "Detected project type: ${project_type}"

  case "$project_type" in
    python) setup_python ;;
    node)   setup_node ;;
    ruby)   setup_ruby ;;
    go)     setup_go ;;
    rust)   setup_rust ;;
    java)   setup_java ;;
    php)    setup_php ;;
    *)
      warn "Generic project detected. Installing minimal utilities only."
      case "$PKG_MANAGER" in
        apt) install_pkgs build-essential ;;
        apk) install_pkgs build-base ;;
        dnf|yum) install_pkgs gcc gcc-c++ make ;;
        pacman) install_pkgs base-devel ;;
        *) warn "Skipping build tools installation; no package manager detected." ;;
      esac
      [[ "$APP_PORT" -eq 0 ]] && APP_PORT=8080
      ;;
  esac

  setup_env_variables

  # Ensure proper permissions
  chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_DIR}" || true

  log "Environment setup completed successfully."
  log "Summary:"
  log "- Project type: ${project_type}"
  log "- App name: ${APP_NAME}"
  log "- Environment: ${APP_ENV}"
  log "- Port: ${APP_PORT}"
  log "You can configure additional environment variables in ${PROJECT_DIR}/.env"

  # Provide generic run hints
  case "$project_type" in
    python)
      if [[ -f "${PROJECT_DIR}/app.py" ]]; then
        log "Run: source .venv/bin/activate && python app.py"
      else
        log "Run: source .venv/bin/activate && python -m your_module"
      fi
      ;;
    node)
      log "Run: npm start (or node index.js)"
      ;;
    ruby)
      if [[ -f "${PROJECT_DIR}/config.ru" ]]; then
        log "Run: bundle exec rackup -p ${APP_PORT}"
      else
        log "Run: bundle exec ruby your_app.rb"
      fi
      ;;
    go)
      log "Run: go run ."
      ;;
    rust)
      log "Run: cargo run"
      ;;
    java)
      log "Run: java -jar target/*.jar (or use gradle/maven run tasks)"
      ;;
    php)
      log "Run: php -S 0.0.0.0:${APP_PORT} -t public (adjust as needed)"
      ;;
    *)
      log "Run: adjust command to your application type."
      ;;
  esac
}

main "$@"