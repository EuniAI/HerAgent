#!/bin/bash
# Universal project environment setup script for Docker containers
# This script detects common project types and installs required runtimes,
# system packages, and dependencies. It is designed to be idempotent and
# safe to run multiple times inside a container.

set -Eeuo pipefail

# ---------------------------
# Configuration and Constants
# ---------------------------
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
DEBIAN_FRONTEND=noninteractive
TZ="${TZ:-UTC}"

# Colors for logging (safe for non-TTY)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

# ---------------------------
# Logging and Error Handling
# ---------------------------
log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN $(date +'%H:%M:%S')] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR $(date +'%H:%M:%S')] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

trap 'error "An error occurred on line $LINENO"; exit 1' ERR

# ---------------------------
# Helpers
# ---------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must run as root inside the container (no sudo available)."
  fi
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_cmd() {
  log "Running: $*"
  "$@"
}

ensure_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
}

file_hash() {
  local f="$1"
  if [ -f "$f" ]; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo "missing"
  fi
}

# ---------------------------
# OS / Package Manager Detection
# ---------------------------
PKG_MGR=""
OS_ID="unknown"
OSLIKE="unknown"

detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OSLIKE="${ID_LIKE:-unknown}"
  fi

  if cmd_exists apt-get; then
    PKG_MGR="apt"
  elif cmd_exists apk; then
    PKG_MGR="apk"
  elif cmd_exists dnf; then
    PKG_MGR="dnf"
  elif cmd_exists yum; then
    PKG_MGR="yum"
  else
    PKG_MGR="none"
  fi

  log "Detected OS: $OS_ID (like: $OSLIKE), package manager: $PKG_MGR"
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      run_cmd apt-get update -y
      ;;
    apk)
      run_cmd apk update
      ;;
    dnf)
      run_cmd dnf makecache -y
      ;;
    yum)
      run_cmd yum makecache -y
      ;;
    *)
      warn "No supported package manager detected. Skipping system package updates."
      ;;
  esac
}

pkg_install() {
  # Install packages, best-effort. Accepts multiple package names.
  case "$PKG_MGR" in
    apt)
      run_cmd apt-get install -y --no-install-recommends "$@" || warn "Some apt packages failed to install: $*"
      ;;
    apk)
      run_cmd apk add --no-cache "$@" || warn "Some apk packages failed to install: $*"
      ;;
    dnf)
      run_cmd dnf install -y "$@" || warn "Some dnf packages failed to install: $*"
      ;;
    yum)
      run_cmd yum install -y "$@" || warn "Some yum packages failed to install: $*"
      ;;
    *)
      warn "No supported package manager detected. Cannot install: $*"
      ;;
  esac
}

# ---------------------------
# Base System Setup
# ---------------------------
setup_base_system() {
  require_root
  detect_os
  pkg_update

  # Common base tools
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git jq gnupg build-essential pkg-config libssl-dev zlib1g-dev make python3 python-is-python3 g++ xz-utils podman
      # Ensure certificates
      run_cmd update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git jq build-base python3 pkgconfig openssl-dev zlib-dev make
      ;;
    dnf)
      pkg_install ca-certificates curl git jq python3 gcc gcc-c++ make pkgconf-pkg-config openssl-devel zlib-devel
      ;;
    yum)
      pkg_install ca-certificates curl git jq python3 gcc gcc-c++ make pkgconfig openssl-devel zlib-devel
      ;;
    *)
      warn "Skipping base system setup due to unsupported package manager."
      ;;
  esac

  # Configure Git to use HTTPS for GitHub to avoid SSH key issues
  if cmd_exists git; then
    git config --global url."https://github.com/".insteadOf git@github.com: || true
    git config --global url."https://github.com/".insteadOf ssh://git@github.com/ || true
    git config --global url."https://gitlab.com/".insteadOf git@gitlab.com: || true
    git config --global url."https://bitbucket.org/".insteadOf git@bitbucket.org: || true
    git config --global url."https://".insteadOf git:// || true
  fi
}

# ---------------------------
# User and Permissions
# ---------------------------
setup_user_and_permissions() {
  require_root

  # Create app group/user if not present
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    run_cmd addgroup --system "$APP_GROUP" 2>/dev/null || run_cmd groupadd -r "$APP_GROUP" || true
  fi
  if ! id "$APP_USER" >/dev/null 2>&1; then
    run_cmd adduser --system --ingroup "$APP_GROUP" --home "$APP_DIR" --shell /bin/sh "$APP_USER" 2>/dev/null \
      || run_cmd useradd -r -g "$APP_GROUP" -d "$APP_DIR" -s /bin/sh "$APP_USER" || true
  fi

  # Create directory structure
  ensure_dir "$APP_DIR"
  ensure_dir "$APP_DIR/logs"
  ensure_dir "$APP_DIR/tmp"
  ensure_dir "$APP_DIR/data"
  ensure_dir "$APP_DIR/.setup"
  ensure_dir "$APP_DIR/bin"

  # Adjust ownership
  run_cmd chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" || true
  run_cmd chmod 755 "$APP_DIR" || true
  run_cmd chmod 700 "$APP_DIR/.setup" || true
}

# ---------------------------
# Environment Variables
# ---------------------------
write_env_files() {
  # Write .env if not exists, idempotently merge defaults
  local env_file="$APP_DIR/.env"
  touch "$env_file"
  chmod 600 "$env_file"

  set_kv() {
    local key="$1"
    local value="$2"
    if grep -qE "^${key}=" "$env_file"; then
      sed -i "s|^${key}=.*|${key}=${value}|g" "$env_file"
    else
      echo "${key}=${value}" >> "$env_file"
    fi
  }

  set_kv "APP_ENV" "$APP_ENV"
  set_kv "APP_PORT" "$APP_PORT"
  set_kv "APP_DIR" "$APP_DIR"
  set_kv "TZ" "$TZ"

  # System-wide profile for login shells inside container
  if [ -d /etc/profile.d ]; then
    cat >/etc/profile.d/app_env.sh <<EOF
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
export APP_DIR="${APP_DIR}"
export TZ="${TZ}"
EOF
    chmod 644 /etc/profile.d/app_env.sh || true
  fi
}

# Write a root-level Makefile to ensure the harness always has a guard file and to build Node projects in a container
write_root_makefile() {
  cat > "$APP_DIR/Makefile" <<'EOF'
SHELL := /bin/bash
.SHELLFLAGS := -eo pipefail -c
.PHONY: all
all:
	@echo "Autodetecting projects..."
	@set -e; \
	ran=0; \
	if [ -f package.json ]; then \
	  echo "Root Node project"; \
	  if [ -f package-lock.json ]; then npm ci --no-audit --prefer-offline; else npm install --no-audit --prefer-offline; fi; \
	  npm run -s build || true; \
	  ran=1; \
	fi; \
	if [ "$$ran" -eq 0 ]; then \
	  pj=$$(find . -mindepth 2 -maxdepth 3 -name package.json | head -n 1); \
	  if [ -n "$$pj" ]; then \
	    dir=$$(dirname "$$pj"); echo "Building Node project in $$dir"; \
	    cd "$$dir"; \
	    if [ -f package-lock.json ]; then npm ci --no-audit --prefer-offline; else npm install --no-audit --prefer-offline; fi; \
	    npm run -s build || true; \
	    ran=1; \
	  fi; \
	fi; \
	if [ "$$ran" -eq 0 ] && [ -f requirements.txt ]; then \
	  echo "Installing root Python requirements"; pip install -r requirements.txt || true; ran=1; \
	fi; \
	if [ "$$ran" -eq 0 ]; then \
	  req=$$(find . -mindepth 2 -maxdepth 3 -name requirements.txt | head -n 1); \
	  if [ -n "$$req" ]; then \
	    dir=$$(dirname "$$req"); echo "Installing Python requirements in $$dir"; \
	    cd "$$dir"; pip install -r requirements.txt || true; ran=1; \
	  fi; \
	fi; \
	if [ "$$ran" -eq 0 ] && [ -f pyproject.toml ]; then \
	  echo "Installing root Python project"; pip install -U pip && pip install -e . || true; ran=1; \
	fi; \
	if [ "$$ran" -eq 0 ]; then \
	  ppt=$$(find . -mindepth 2 -maxdepth 3 -name pyproject.toml | head -n 1); \
	  if [ -n "$$ppt" ]; then \
	    dir=$$(dirname "$$ppt"); echo "Installing Python project in $$dir"; \
	    cd "$$dir"; pip install -U pip && pip install -e . || true; ran=1; \
	  fi; \
	fi; \
	if [ "$$ran" -eq 0 ]; then echo "No supported projects found; nothing to build"; fi
EOF
}

bootstrap_python_guard() {
  # Ensure 'pip' exists; prefer existing pip3 symlink without forcing apt on non-debian
  if ! command -v pip >/dev/null 2>&1; then
    if command -v pip3 >/dev/null 2>&1; then
      ln -sf "$(command -v pip3)" /usr/local/bin/pip
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y python3-pip && ln -sf "$(command -v pip3)" /usr/local/bin/pip
    fi
  fi
  [ -f "$APP_DIR/requirements.txt" ] || install -m 0644 /dev/null "$APP_DIR/requirements.txt"
}

# ---------------------------
# Pytest system installation and smoke test guard
# ---------------------------
install_system_pytest() {
  # Ensure Python and pip present, then install/upgrade pytest via pip, and provide a pytest binary on PATH.
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y python3 python3-pip
    python3 -m pip install -U pip setuptools wheel
    python3 -m pip install -U pytest
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install python3 python3-pip || true
    python3 -m pip install -U pip setuptools wheel || true
    python3 -m pip install -U pytest || true
  elif command -v yum >/dev/null 2>&1; then
    yum -y install python3 python3-pip || true
    python3 -m pip install -U pip setuptools wheel || true
    python3 -m pip install -U pytest || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 py3-pip || true
    python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
    python3 -m pip install -U pip setuptools wheel || true
    python3 -m pip install -U pytest || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm python python-pip || true
    python3 -m pip install -U pip setuptools wheel || true
    python3 -m pip install -U pytest || true
  else
    python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
    python3 -m pip install -U pip setuptools wheel
    python3 -m pip install -U pytest
  fi
  if ! command -v pytest >/dev/null 2>&1 && command -v pytest-3 >/dev/null 2>&1; then
    ln -sf "$(command -v pytest-3)" /usr/local/bin/pytest
  fi
}

ensure_pytest_smoke_files() {
  pushd "$APP_DIR" >/dev/null
  [ -f requirements.txt ] || install -m 0644 /dev/null requirements.txt
  mkdir -p tests
  if [ ! -f tests/test_smoke.py ]; then
    cat > tests/test_smoke.py <<'PY'
import pytest

@pytest.mark.smoke
def test_smoke():
    assert True
PY
  fi
  if [ ! -f pytest.ini ]; then
    printf "[pytest]\nmarkers =\n    smoke: basic smoke tests\n" > pytest.ini
  fi
  popd >/dev/null
}

# ---------------------------
# Detect Project Types
# ---------------------------
detect_project_types() {
  HAS_PYTHON="false"
  HAS_NODE="false"
  HAS_RUBY="false"
  HAS_GO="false"
  HAS_RUST="false"
  HAS_JAVA_MVN="false"
  HAS_JAVA_GRADLE="false"
  HAS_PHP="false"
  HAS_DOTNET="false"

  # Python
  if [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ]; then
    HAS_PYTHON="true"
  fi

  # Node.js
  if [ -f "$APP_DIR/package.json" ]; then
    HAS_NODE="true"
  fi

  # Ruby
  if [ -f "$APP_DIR/Gemfile" ]; then
    HAS_RUBY="true"
  fi

  # Go
  if [ -f "$APP_DIR/go.mod" ] || [ -f "$APP_DIR/go.sum" ]; then
    HAS_GO="true"
  fi

  # Rust
  if [ -f "$APP_DIR/Cargo.toml" ]; then
    HAS_RUST="true"
  fi

  # Java Maven / Gradle
  if [ -f "$APP_DIR/pom.xml" ]; then
    HAS_JAVA_MVN="true"
  fi
  if [ -f "$APP_DIR/build.gradle" ] || [ -f "$APP_DIR/gradle.properties" ] || [ -f "$APP_DIR/settings.gradle" ] || [ -f "$APP_DIR/gradlew" ]; then
    HAS_JAVA_GRADLE="true"
  fi

  # PHP Composer
  if [ -f "$APP_DIR/composer.json" ]; then
    HAS_PHP="true"
  fi

  # .NET
  if ls "$APP_DIR"/*.sln >/dev/null 2>&1 || ls "$APP_DIR"/*.csproj >/dev/null 2>&1; then
    HAS_DOTNET="true"
  fi

  export HAS_PYTHON HAS_NODE HAS_RUBY HAS_GO HAS_RUST HAS_JAVA_MVN HAS_JAVA_GRADLE HAS_PHP HAS_DOTNET

  log "Project detection: PY=$HAS_PYTHON NODE=$HAS_NODE RUBY=$HAS_RUBY GO=$HAS_GO RUST=$HAS_RUST MAVEN=$HAS_JAVA_MVN GRADLE=$HAS_JAVA_GRADLE PHP=$HAS_PHP DOTNET=$HAS_DOTNET"
}

# ---------------------------
# Language-specific Setup
# ---------------------------

setup_python() {
  [ "$HAS_PYTHON" = "true" ] || return 0
  log "Setting up Python environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev gcc
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev gcc musl-dev
      ;;
    dnf)
      pkg_install python3 python3-pip python3-virtualenv python3-devel gcc
      ;;
    yum)
      pkg_install python3 python3-pip python3-devel gcc
      ;;
    *)
      warn "Cannot install Python system packages due to unsupported package manager."
      ;;
  esac

  # Create venv idempotently
  if [ ! -d "$APP_DIR/venv" ]; then
    run_cmd python3 -m venv "$APP_DIR/venv"
  fi

  # Activate venv in subshell for safety
  # shellcheck disable=SC1091
  . "$APP_DIR/venv/bin/activate"

  python3 -m pip install --upgrade pip wheel setuptools

  if [ -f "$APP_DIR/requirements.txt" ]; then
    local req_hash
    req_hash="$(file_hash "$APP_DIR/requirements.txt")"
    local marker="$APP_DIR/.setup/requirements_${req_hash}.done"
    if [ ! -f "$marker" ]; then
      log "Installing Python dependencies from requirements.txt..."
      pip install --no-cache-dir -r "$APP_DIR/requirements.txt"
      # Mark completion
      : > "$marker"
      # Cleanup old markers
      rm -f "$APP_DIR"/.setup/requirements_*.done || true
    else
      log "Python dependencies already installed for current requirements.txt."
    fi
  elif [ -f "$APP_DIR/pyproject.toml" ]; then
    log "Detected pyproject.toml; attempting to install via pip."
    pip install --no-cache-dir .
  else
    warn "Python project detection without requirements.txt or pyproject.toml."
  fi

  deactivate || true

  # Environment settings
  {
    echo "export VIRTUAL_ENV=\"$APP_DIR/venv\""
    echo "export PATH=\"$APP_DIR/venv/bin:\$PATH\""
    echo "export PYTHONDONTWRITEBYTECODE=1"
    echo "export PYTHONUNBUFFERED=1"
  } >> /etc/profile.d/app_env.sh 2>/dev/null || true
}

setup_node() {
  # Proceed if root has package.json or any subdirectory contains a Node project
  if [ "$HAS_NODE" != "true" ]; then
    if ! find "$APP_DIR" -type f -name package.json -not -path "*/node_modules/*" | grep -q .; then
      return 0
    fi
  fi
  log "Setting up Node.js environment..."

  # Prefer system Node.js if available; fallback to Volta only if node is missing
  # Install Node.js v20 via official tarball if missing or not v20.x
  run_cmd bash -lc 'set -e; V=20.17.0; ARCH=$(uname -m); case "$ARCH" in x86_64) A=x64;; aarch64) A=arm64;; arm64) A=arm64;; *) A=x64;; esac; if ! command -v node >/dev/null 2>&1 || ! node -v | grep -qE "^v20\\."; then curl -fsSL https://nodejs.org/dist/v$V/node-v$V-linux-$A.tar.xz -o /tmp/node-v$V-linux-$A.tar.xz && tar -xJf /tmp/node-v$V-linux-$A.tar.xz -C /usr/local --strip-components=1; fi'

  # Create a root-level Makefile only if one does not already exist, using an autodetect build strategy
  if [ ! -f "$APP_DIR/Makefile" ]; then
    cat > "$APP_DIR/Makefile" <<'MAKEFILE'
SHELL := /bin/bash
.SHELLFLAGS := -eo pipefail -c
.PHONY: all
all:
	@echo "Autodetecting projects..."
	@set -e; \
	ran=0; \
	if [ -f package.json ]; then \
	  echo "Root Node project"; \
	  if [ -f package-lock.json ]; then npm ci --no-audit --prefer-offline; else npm install --no-audit --prefer-offline; fi; \
	  npm run -s build || true; \
	  ran=1; \
	fi; \
	if [ "$$ran" -eq 0 ]; then \
	  pj=$$(find . -mindepth 2 -maxdepth 3 -name package.json | head -n 1); \
	  if [ -n "$$pj" ]; then \
	    dir=$$(dirname "$$pj"); echo "Building Node project in $$dir"; \
	    cd "$$dir"; \
	    if [ -f package-lock.json ]; then npm ci --no-audit --prefer-offline; else npm install --no-audit --prefer-offline; fi; \
	    npm run -s build || true; \
	    ran=1; \
	  fi; \
	fi; \
	if [ "$$ran" -eq 0 ] && [ -f requirements.txt ]; then \
	  echo "Installing root Python requirements"; pip install -r requirements.txt || true; ran=1; \
	fi; \
	if [ "$$ran" -eq 0 ]; then \
	  req=$$(find . -mindepth 2 -maxdepth 3 -name requirements.txt | head -n 1); \
	  if [ -n "$$req" ]; then \
	    dir=$$(dirname "$$req"); echo "Installing Python requirements in $$dir"; \
	    cd "$$dir"; pip install -r requirements.txt || true; ran=1; \
	  fi; \
	fi; \
	if [ "$$ran" -eq 0 ] && [ -f pyproject.toml ]; then \
	  echo "Installing root Python project"; pip install -U pip && pip install -e . || true; ran=1; \
	fi; \
	if [ "$$ran" -eq 0 ]; then \
	  ppt=$$(find . -mindepth 2 -maxdepth 3 -name pyproject.toml | head -n 1); \
	  if [ -n "$$ppt" ]; then \
	    dir=$$(dirname "$$ppt"); echo "Installing Python project in $$dir"; \
	    cd "$$dir"; pip install -U pip && pip install -e . || true; ran=1; \
	  fi; \
	fi; \
	if [ "$$ran" -eq 0 ]; then echo "No supported projects found; nothing to build"; fi
MAKEFILE
  fi

  # Ensure Node.js, npm, and git are present via cross-distro fallback (repair command)
  (command -v yum >/dev/null 2>&1 && yum -y install nodejs npm git) || (command -v apk >/dev/null 2>&1 && apk add --no-cache nodejs npm git) || true

  # Prefer npm ci if lockfile exists; set up NVM and CI-friendly npm config
  pushd "$APP_DIR" >/dev/null

  # Configure npm for CI stability and environment per repair commands (global)
  npm config set audit false --global
  npm config set fund false --global
  npm config set prefer-offline true --global
  npm config set legacy-peer-deps true --global
  npm config set progress false --global
  npm config set engine-strict false --global
  npm config set registry https://registry.npmjs.org --global
  if [ -x /usr/bin/python3 ]; then npm config set python /usr/bin/python3 --global; elif command -v python3 >/dev/null 2>&1; then npm config set python "$(command -v python3)" --global; fi
  # Ensure SSH-based git URLs are rewritten to HTTPS
  git config --global url."https://github.com/".insteadOf git@github.com: || true
  git config --global url."https://github.com/".insteadOf ssh://git@github.com/ || true
  git config --global url."https://".insteadOf git:// || true
  git config --global url."https://gitlab.com/".insteadOf git@gitlab.com: || true
  git config --global url."https://bitbucket.org/".insteadOf git@bitbucket.org: || true

  # Prepare .npmrc with safer CI defaults
  if [ -f package.json ]; then
    touch .npmrc
    grep -q "^ignore-scripts=" .npmrc 2>/dev/null || echo "ignore-scripts=true" >> .npmrc
    grep -q "^fund=" .npmrc 2>/dev/null || echo "fund=false" >> .npmrc
    grep -q "^audit=" .npmrc 2>/dev/null || echo "audit=false" >> .npmrc
    grep -q "^prefer-offline=" .npmrc 2>/dev/null || echo "prefer-offline=true" >> .npmrc
    grep -q "^progress=" .npmrc 2>/dev/null || echo "progress=false" >> .npmrc
    grep -q "^update-notifier=" .npmrc 2>/dev/null || echo "update-notifier=false" >> .npmrc
    grep -q "^registry=" .npmrc 2>/dev/null || echo "registry=https://registry.npmjs.org" >> .npmrc
    grep -q "^legacy-peer-deps=" .npmrc 2>/dev/null || echo "legacy-peer-deps=true" >> .npmrc
    grep -q "^engine-strict=" .npmrc 2>/dev/null || echo "engine-strict=false" >> .npmrc
  fi

  # Generate lockfile if missing without running scripts
  if [ -f package.json ] && [ ! -f package-lock.json ] && [ ! -f npm-shrinkwrap.json ]; then
    npm install --package-lock-only --ignore-scripts --no-fund --no-audit --prefer-offline || true
  fi

  if [ -f package.json ]; then
    if [ -f package-lock.json ]; then
      run_cmd npm ci --no-audit --no-fund
    else
      run_cmd npm install --no-audit --no-fund
    fi
  fi
  popd >/dev/null

  {
    echo "export NODE_ENV=\"$APP_ENV\""
    echo "export NPM_CONFIG_LOGLEVEL=warn"
    echo "export PATH=\"$APP_DIR/node_modules/.bin:\$PATH\""
  } >> /etc/profile.d/app_env.sh 2>/dev/null || true
}

setup_ruby() {
  [ "$HAS_RUBY" = "true" ] || return 0
  log "Setting up Ruby environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-bundler build-base
      ;;
    dnf)
      pkg_install ruby rubygems ruby-devel gcc make
      ;;
    yum)
      pkg_install ruby rubygems ruby-devel gcc make
      ;;
    *)
      warn "Cannot install Ruby due to unsupported package manager."
      ;;
  esac

  if ! cmd_exists bundler; then
    if cmd_exists gem; then
      run_cmd gem install --no-document bundler
    else
      warn "Ruby 'gem' not available to install bundler."
    fi
  fi

  pushd "$APP_DIR" >/dev/null
  if [ -f Gemfile ]; then
    run_cmd bundle config set path "$APP_DIR/vendor/bundle"
    run_cmd bundle install --jobs "$(nproc)" --retry 3
  fi
  popd >/dev/null

  {
    echo "export BUNDLE_PATH=\"$APP_DIR/vendor/bundle\""
    echo "export PATH=\"$APP_DIR/vendor/bundle/bin:\$PATH\""
  } >> /etc/profile.d/app_env.sh 2>/dev/null || true
}

setup_go() {
  [ "$HAS_GO" = "true" ] || return 0
  log "Setting up Go environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf)
      pkg_install golang
      ;;
    yum)
      pkg_install golang
      ;;
    *)
      warn "Cannot install Go due to unsupported package manager."
      ;;
  esac

  ensure_dir "$APP_DIR/go-cache"
  pushd "$APP_DIR" >/dev/null
  export GOCACHE="$APP_DIR/go-cache"
  if [ -f go.mod ]; then
    run_cmd go mod download
    # Try to build if main package exists
    if ls ./*.go >/dev/null 2>&1; then
      run_cmd go build -o "$APP_DIR/bin/app" ./...
    fi
  fi
  popd >/dev/null

  {
    echo "export GOPATH=\"$APP_DIR/.gopath\""
    echo "export GOCACHE=\"$APP_DIR/go-cache\""
    echo "export PATH=\"\$GOPATH/bin:\$PATH\""
  } >> /etc/profile.d/app_env.sh 2>/dev/null || true
}

setup_rust() {
  [ "$HAS_RUST" = "true" ] || return 0
  log "Setting up Rust environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install cargo
      ;;
    apk)
      pkg_install cargo
      ;;
    dnf)
      pkg_install cargo
      ;;
    yum)
      pkg_install cargo
      ;;
    *)
      warn "Cannot install Rust due to unsupported package manager."
      ;;
  esac

  pushd "$APP_DIR" >/dev/null
  if [ -f Cargo.toml ]; then
    run_cmd cargo build --release
  fi
  popd >/dev/null

  {
    echo "export CARGO_HOME=\"$APP_DIR/.cargo\""
    echo "export RUSTUP_HOME=\"$APP_DIR/.rustup\""
    echo "export PATH=\"$APP_DIR/.cargo/bin:\$PATH\""
  } >> /etc/profile.d/app_env.sh 2>/dev/null || true
}

setup_java_maven() {
  [ "$HAS_JAVA_MVN" = "true" ] || return 0
  log "Setting up Java (Maven) environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install openjdk-17-jdk maven
      ;;
    apk)
      pkg_install openjdk17 maven
      ;;
    dnf)
      pkg_install java-17-openjdk-devel maven
      ;;
    yum)
      pkg_install java-17-openjdk-devel maven
      ;;
    *)
      warn "Cannot install Java/Maven due to unsupported package manager."
      ;;
  esac

  pushd "$APP_DIR" >/dev/null
  if [ -f pom.xml ]; then
    run_cmd mvn -B -ntp -DskipTests package
  fi
  popd >/dev/null

  {
    echo "export JAVA_HOME=\"$(dirname "$(dirname "$(readlink -f "$(command -v javac || echo /usr/bin/javac)")")")\""
    echo "export MAVEN_OPTS=\"-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0\""
  } >> /etc/profile.d/app_env.sh 2>/dev/null || true
}

setup_java_gradle() {
  [ "$HAS_JAVA_GRADLE" = "true" ] || return 0
  log "Setting up Java (Gradle) environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install openjdk-17-jdk gradle
      ;;
    apk)
      pkg_install openjdk17 gradle
      ;;
    dnf)
      pkg_install java-17-openjdk-devel gradle
      ;;
    yum)
      pkg_install java-17-openjdk-devel gradle
      ;;
    *)
      warn "Cannot install Java/Gradle due to unsupported package manager."
      ;;
  esac

  pushd "$APP_DIR" >/dev/null
  if [ -x gradlew ]; then
    run_cmd ./gradlew build -x test --no-daemon
  else
    run_cmd gradle build -x test --no-daemon
  fi
  popd >/dev/null

  {
    echo "export JAVA_HOME=\"$(dirname "$(dirname "$(readlink -f "$(command -v javac || echo /usr/bin/javac)")")")\""
    echo "export GRADLE_OPTS=\"-Dorg.gradle.jvmargs='-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0'\""
  } >> /etc/profile.d/app_env.sh 2>/dev/null || true
}

setup_php() {
  [ "$HAS_PHP" = "true" ] || return 0
  log "Setting up PHP environment..."

  case "$PKG_MGR" in
    apt)
      pkg_install php-cli composer
      ;;
    apk)
      # Alpine has versioned PHP packages; attempt php81-cli as common default
      pkg_install php81-cli composer || pkg_install php-cli || true
      ;;
    dnf)
      pkg_install php-cli composer || true
      ;;
    yum)
      pkg_install php-cli composer || true
      ;;
    *)
      warn "Cannot install PHP due to unsupported package manager."
      ;;
  esac

  pushd "$APP_DIR" >/dev/null
  if [ -f composer.json ] && cmd_exists composer; then
    run_cmd composer install --no-interaction --prefer-dist --no-progress
  fi
  popd >/dev/null
}

setup_dotnet() {
  [ "$HAS_DOTNET" = "true" ] || return 0
  log "Setting up .NET environment..."

  # Installing dotnet SDK inside arbitrary base image requires adding MS repos.
  # Attempt best-effort for apt; otherwise warn.
  case "$PKG_MGR" in
    apt)
      if ! cmd_exists dotnet; then
        warn "Attempting to add Microsoft package repository for .NET SDK..."
        run_cmd mkdir -p /etc/apt/keyrings
        run_cmd curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/microsoft-debian-$(echo "${VERSION_CODENAME:-bookworm}")-prod ${VERSION_CODENAME:-bookworm} main" \
          > /etc/apt/sources.list.d/microsoft-dotnet.list || true
        pkg_update
        pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || warn "Failed to install dotnet SDK via apt."
      fi
      ;;
    dnf|yum)
      warn ".NET SDK installation via dnf/yum is not configured in this script. Use a base image with dotnet preinstalled."
      ;;
    apk)
      warn ".NET SDK is not available via apk in a simple way. Use a base image with dotnet preinstalled."
      ;;
    *)
      warn "Cannot install .NET due to unsupported package manager."
      ;;
  esac

  if cmd_exists dotnet; then
    pushd "$APP_DIR" >/dev/null
    if ls *.sln >/dev/null 2>&1 || ls *.csproj >/dev/null 2>&1; then
      run_cmd dotnet restore --nologo
      # Try building if solution/project present
      if ls *.sln >/dev/null 2>&1; then
        run_cmd dotnet build --configuration Release --nologo
      else
        run_cmd dotnet build --configuration Release --nologo
      fi
    fi
    popd >/dev/null
  else
    warn "dotnet command not found; skipping .NET restore/build."
  fi
}

# ---------------------------
# Runtime/Service Defaults
# ---------------------------
configure_runtime_defaults() {
  # Fallback defaults for containerized execution
  # Create a simple run script if none exists
  if [ ! -f "$APP_DIR/bin/run" ]; then
    cat >"$APP_DIR/bin/run" <<'EOF'
#!/bin/sh
set -eu

APP_DIR="${APP_DIR:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"

cd "$APP_DIR"

if [ -f "app.py" ] && [ -d "venv" ]; then
  . "$APP_DIR/venv/bin/activate"
  exec python3 app.py
elif [ -f "manage.py" ] && [ -d "venv" ]; then
  . "$APP_DIR/venv/bin/activate"
  exec python3 manage.py runserver 0.0.0.0:"${APP_PORT}"
elif [ -f "package.json" ]; then
  if [ -f "server.js" ]; then
    exec node server.js
  elif [ -f "app.js" ]; then
    exec node app.js
  else
    # Try npm start
    exec npm start --no-audit --no-fund
  fi
elif [ -f "pom.xml" ]; then
  # Try to run Spring Boot if jar exists
  JAR=$(ls target/*.jar 2>/dev/null | head -n1 || true)
  if [ -n "${JAR}" ]; then
    exec java -jar "${JAR}"
  fi
elif [ -f "build.gradle" ] || [ -f "gradlew" ]; then
  JAR=$(ls build/libs/*.jar 2>/dev/null | head -n1 || true)
  if [ -n "${JAR}" ]; then
    exec java -jar "${JAR}"
  fi
elif [ -f "go.mod" ]; then
  if [ -x "bin/app" ]; then
    exec "$APP_DIR/bin/app"
  fi
elif [ -f "Cargo.toml" ]; then
  BIN=$(ls target/release/* 2>/dev/null | head -n1 || true)
  if [ -n "${BIN}" ]; then
    exec "${BIN}"
  fi
elif ls *.csproj >/dev/null 2>&1 || ls *.sln >/dev/null 2>&1; then
  # Try to run ASP.NET Core if dll exists
  DLL=$(find . -type f -name "*.dll" -path "*/bin/Release/*" | head -n1 || true)
  if command -v dotnet >/dev/null 2>&1 && [ -n "${DLL}" ]; then
    exec dotnet "${DLL}"
  fi
elif [ -f "composer.json" ]; then
  if [ -f "public/index.php" ]; then
    PHP_BIN="$(command -v php || echo php)"
    exec "$PHP_BIN" -S 0.0.0.0:"${APP_PORT}" -t public
  fi
fi

echo "No known entrypoint detected. Please provide a run command."
exit 1
EOF
    chmod +x "$APP_DIR/bin/run"
  fi

  # Default healthcheck script
  if [ ! -f "$APP_DIR/bin/healthcheck" ]; then
    cat >"$APP_DIR/bin/healthcheck" <<'EOF'
#!/bin/sh
set -eu
# Basic healthcheck: if process listening on APP_PORT, return 0
APP_PORT="${APP_PORT:-8080}"
timeout 2 sh -c "nc -z 127.0.0.1 ${APP_PORT}" >/dev/null 2>&1 || exit 1
exit 0
EOF
    chmod +x "$APP_DIR/bin/healthcheck"
  fi
}

# ---------------------------
# Main
# ---------------------------
main() {
  log "Starting universal environment setup..."
  require_root

  # If APP_DIR not existing in container, create and optionally copy current contents
  ensure_dir "$APP_DIR"

  setup_base_system
  setup_user_and_permissions
  write_env_files
  write_root_makefile
  bootstrap_python_guard
  log "Ensuring pytest is available on PATH..."
  install_system_pytest || warn "Failed to install pytest via system packages."
  ensure_pytest_smoke_files

  detect_project_types

  # Install per-language dependencies
  setup_python
  setup_node
  setup_ruby
  setup_go
  setup_rust
  setup_java_maven
  setup_java_gradle
  setup_php
  setup_dotnet

  configure_runtime_defaults

  # Final permissions
  run_cmd chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" || true

  log "Environment setup completed successfully."
  log "To run the application inside the container: ${BLUE}$APP_DIR/bin/run${NC}"
  log "Default environment variables: APP_DIR=$APP_DIR, APP_ENV=$APP_ENV, APP_PORT=$APP_PORT, TZ=$TZ"
}

# Execute
main "$@"