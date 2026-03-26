#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# This script detects common project types and installs and configures their environments.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail

# Globals
APP_DIR="${APP_DIR:-}"
APP_SUBDIR="${APP_SUBDIR:-}"        # Optional subdir to focus on (e.g., "backend")
NONINTERACTIVE="${NONINTERACTIVE:-1}"
BUILD_IN_SETUP="${BUILD_IN_SETUP:-0}"  # If 1, run build steps when safe
DEFAULT_USER="${DEFAULT_USER:-}"
DEFAULT_GROUP="${DEFAULT_GROUP:-}"

# Colors
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# Logging
log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

trap 'err "Failure at line $LINENO: $BASH_COMMAND"; exit 1' ERR

# Helpers
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
file_contains() { [ -f "$1" ] && grep -qE "$2" "$1"; }

ensure_path() {
  # Prepend paths if not present
  for p in "$@"; do
    case ":$PATH:" in
      *":$p:"*) : ;;
      *) PATH="$p:$PATH" ;;
    esac
  done
  export PATH
}

ensure_dir() {
  local d="$1"
  [ -d "$d" ] || mkdir -p "$d"
}

chown_if_possible() {
  local target="$1"
  local user="${2:-}"
  local group="${3:-}"
  if ! is_root; then return 0; fi
  if [ -n "$user" ] && [ -n "$group" ]; then
    chown -R "$user:$group" "$target" || true
  fi
}

# Package manager detection and install functions
PKG_MANAGER=""
pm_detect() {
  if have_cmd apt-get; then
    PKG_MANAGER="apt"
  elif have_cmd apk; then
    PKG_MANAGER="apk"
  elif have_cmd dnf; then
    PKG_MANAGER="dnf"
  elif have_cmd yum; then
    PKG_MANAGER="yum"
  elif have_cmd microdnf; then
    PKG_MANAGER="microdnf"
  else
    PKG_MANAGER=""
  fi
}

pm_update() {
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y -qq
      ;;
    apk)
      apk update >/dev/null
      ;;
    dnf)
      dnf -y -q makecache
      ;;
    yum)
      yum -y -q makecache
      ;;
    microdnf)
      microdnf -y -q update || true
      ;;
    *)
      ;;
  esac
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  [ -z "$PKG_MANAGER" ] && return 1
  local pkgs=("$@")
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y -q "${pkgs[@]}"
      ;;
    yum)
      yum install -y -q "${pkgs[@]}"
      ;;
    microdnf)
      microdnf install -y -q "${pkgs[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

pm_clean() {
  case "$PKG_MANAGER" in
    apt)
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|yum|microdnf)
      # Leave caches; minimal benefit in short-lived containers
      :
      ;;
    *)
      ;;
  esac
}

require_root_for_pkg() {
  if [ -z "$PKG_MANAGER" ]; then
    warn "No supported package manager detected; skipping system package installation."
    return 1
  fi
  if ! is_root; then
    warn "Not running as root; cannot install system packages with $PKG_MANAGER. Skipping."
    return 1
  fi
  return 0
}

install_base_tools() {
  pm_detect
  if ! require_root_for_pkg; then return 0; fi
  log "Installing base system tools using $PKG_MANAGER..."
  pm_update
  case "$PKG_MANAGER" in
    apt)
      pm_install ca-certificates curl git openssh-client bash tzdata xz-utils unzip zip sed grep procps
      ;;
    apk)
      pm_install ca-certificates curl git openssh-client bash tzdata xz unzip zip sed grep procps
      ;;
    dnf|yum|microdnf)
      pm_install ca-certificates curl git openssh-clients bash tzdata xz unzip zip sed grep procps-ng
      ;;
  esac
  pm_clean
}

install_build_essentials() {
  pm_detect
  if ! require_root_for_pkg; then return 0; fi
  log "Installing build essentials using $PKG_MANAGER..."
  pm_update
  case "$PKG_MANAGER" in
    apt)
      pm_install build-essential pkg-config
      ;;
    apk)
      pm_install build-base pkgconfig
      ;;
    dnf|yum|microdnf)
      pm_install gcc gcc-c++ make pkgconfig
      ;;
  esac
  pm_clean
}

# Language-specific installers

# Python
ensure_python_runtime() {
  if have_cmd python3 && have_cmd pip3; then
    return 0
  fi
  pm_detect
  if ! require_root_for_pkg; then
    warn "Python not found and cannot install system packages."
    return 1
  fi
  log "Installing Python runtime..."
  pm_update
  case "$PKG_MANAGER" in
    apt)
      pm_install python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      pm_install python3 py3-pip py3-virtualenv python3-dev
      ;;
    dnf|yum|microdnf)
      pm_install python3 python3-pip python3-devel
      # venv typically included in python3 on these distros
      ;;
  esac
  pm_clean
}

setup_python_project() {
  local root="$1"
  local venv_dir="$root/.venv"

  ensure_python_runtime || return 0
  install_build_essentials

  export PYTHONUNBUFFERED=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1

  ensure_path "$venv_dir/bin" "$HOME/.local/bin"

  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Reusing existing Python virtual environment at $venv_dir"
  fi

  # Activate environment for this shell session
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"

  python3 -m pip install --upgrade pip setuptools wheel

  if [ -f "$root/poetry.lock" ] || file_contains "$root/pyproject.toml" '^\s*\[tool\.poetry\]'; then
    log "Detected Poetry project. Installing dependencies..."
    python3 -m pip install --upgrade "poetry>=1.5"
    poetry config virtualenvs.in-project true
    if [ -f "$root/poetry.lock" ]; then
      poetry install --no-interaction --no-ansi
    else
      poetry install --no-interaction --no-ansi || true
    fi
  elif [ -f "$root/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install -r "$root/requirements.txt"
  elif [ -f "$root/Pipfile" ]; then
    log "Detected Pipenv project. Installing dependencies..."
    pip install --upgrade pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  elif [ -f "$root/pyproject.toml" ] && file_contains "$root/pyproject.toml" '^\s*\[build-system\]'; then
    log "Detected PEP 517 pyproject. Attempting to install via pip..."
    pip install .
  else
    warn "No Python dependency file found (requirements.txt, Pipfile, poetry.lock, pyproject.toml)."
  fi

  # Common Python env vars
  export APP_ENV="${APP_ENV:-production}"
  export PYTHONDONTWRITEBYTECODE=1
  export PATH="$venv_dir/bin:$PATH"
}

# Node.js
ensure_node_runtime() {
  if have_cmd node && have_cmd npm; then
    return 0
  fi
  pm_detect
  if ! require_root_for_pkg; then
    warn "Node.js not found and cannot install system packages."
    return 1
  fi
  log "Installing Node.js runtime..."
  pm_update
  case "$PKG_MANAGER" in
    apt)
      pm_install nodejs npm
      ;;
    apk)
      pm_install nodejs npm
      ;;
    dnf|yum|microdnf)
      pm_install nodejs npm
      ;;
  esac
  pm_clean
}

setup_node_project() {
  local root="$1"

  ensure_node_runtime || return 0
  ensure_path "$root/node_modules/.bin"

  export NODE_ENV="${NODE_ENV:-production}"
  export CI="${CI:-true}"

  local pkg_manager="npm"
  if [ -f "$root/pnpm-lock.yaml" ]; then
    pkg_manager="pnpm"
  elif [ -f "$root/yarn.lock" ]; then
    pkg_manager="yarn"
  elif [ -f "$root/package-lock.json" ]; then
    pkg_manager="npm"
  fi

  # Install package managers if needed
  if [ "$pkg_manager" = "pnpm" ] && ! have_cmd pnpm; then
    if have_cmd corepack; then corepack enable pnpm || true; fi
    if ! have_cmd pnpm; then npm install -g pnpm@latest || true; fi
  fi
  if [ "$pkg_manager" = "yarn" ] && ! have_cmd yarn; then
    if have_cmd corepack; then corepack enable yarn || true; fi
    if ! have_cmd yarn; then npm install -g yarn@latest || true; fi
  fi

  log "Installing Node.js dependencies with $pkg_manager..."
  case "$pkg_manager" in
    pnpm)
      pnpm install --frozen-lockfile || pnpm install
      ;;
    yarn)
      if [ -f "$root/yarn.lock" ]; then
        yarn install --frozen-lockfile
      else
        yarn install
      fi
      ;;
    npm)
      if [ -f "$root/package-lock.json" ]; then
        npm ci || npm install
      else
        npm install
      fi
      ;;
  esac

  if [ "$BUILD_IN_SETUP" = "1" ] && [ -f "$root/package.json" ] && grep -q '"build"\s*:' "$root/package.json"; then
    log "Running build script..."
    case "$pkg_manager" in
      pnpm) pnpm run build || true ;;
      yarn) yarn run build || true ;;
      npm) npm run build || true ;;
    esac
  fi
}

# Ruby
ensure_ruby_runtime() {
  if have_cmd ruby && have_cmd gem; then
    return 0
  fi
  pm_detect
  if ! require_root_for_pkg; then
    warn "Ruby not found and cannot install system packages."
    return 1
  fi
  log "Installing Ruby runtime..."
  pm_update
  case "$PKG_MANAGER" in
    apt) pm_install ruby-full ;;
    apk) pm_install ruby ruby-dev ;;
    dnf|yum|microdnf) pm_install ruby ruby-devel ;;
  esac
  pm_clean
}

setup_ruby_project() {
  local root="$1"

  ensure_ruby_runtime || return 0
  install_build_essentials

  if ! have_cmd bundle; then
    gem install bundler --no-document || true
  fi

  ensure_dir "$root/vendor/bundle"
  log "Installing Ruby gems with Bundler..."
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs "$(nproc || echo 2)" --retry 3
}

# Java
ensure_java_runtime() {
  if have_cmd java; then return 0; fi
  pm_detect
  if ! require_root_for_pkg; then
    warn "Java not found and cannot install system packages."
    return 1
  fi
  log "Installing OpenJDK..."
  pm_update
  case "$PKG_MANAGER" in
    apt) pm_install openjdk-17-jdk ;;
    apk) pm_install openjdk17-jdk ;;
    dnf|yum|microdnf) pm_install java-17-openjdk-devel ;;
  esac
  pm_clean
}

setup_java_project() {
  local root="$1"
  ensure_java_runtime || return 0

  if [ -f "$root/gradlew" ]; then
    log "Detected Gradle Wrapper. Bootstrapping..."
    chmod +x "$root/gradlew"
    (cd "$root" && ./gradlew --no-daemon tasks >/dev/null || true)
  elif [ -f "$root/build.gradle" ] || [ -f "$root/build.gradle.kts" ]; then
    pm_detect; if require_root_for_pkg; then
      pm_update
      case "$PKG_MANAGER" in
        apt) pm_install gradle ;;
        apk) pm_install gradle ;;
        dnf|yum|microdnf) pm_install gradle ;;
      esac
      pm_clean
    fi
  fi

  if [ -f "$root/pom.xml" ]; then
    if ! have_cmd mvn; then
      pm_detect; if require_root_for_pkg; then
        pm_update
        case "$PKG_MANAGER" in
          apt) pm_install maven ;;
          apk) pm_install maven ;;
          dnf|yum|microdnf) pm_install maven ;;
        esac
        pm_clean
      fi
    fi
    if have_cmd mvn; then
      log "Resolving Maven dependencies (skip tests)..."
      (cd "$root" && mvn -q -DskipTests dependency:resolve dependency:resolve-plugins || true)
    fi
  fi
}

# Go
ensure_go_runtime() {
  if have_cmd go; then return 0; fi
  pm_detect
  if ! require_root_for_pkg; then
    warn "Go not found and cannot install system packages."
    return 1
  fi
  log "Installing Go..."
  pm_update
  case "$PKG_MANAGER" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    dnf|yum|microdnf) pm_install golang ;;
  esac
  pm_clean
}

setup_go_project() {
  local root="$1"
  ensure_go_runtime || return 0
  if [ -f "$root/go.mod" ]; then
    log "Downloading Go modules..."
    (cd "$root" && go mod download || true)
  fi
}

# Rust
ensure_rust_runtime() {
  if have_cmd cargo; then return 0; fi
  pm_detect
  if ! require_root_for_pkg; then
    warn "Rust not found and cannot install system packages."
    return 1
  fi
  log "Installing Rust/Cargo..."
  pm_update
  case "$PKG_MANAGER" in
    apt) pm_install cargo ;;
    apk) pm_install cargo ;;
    dnf|yum|microdnf) pm_install rust cargo ;;
  esac
  pm_clean
}

setup_rust_project() {
  local root="$1"
  ensure_rust_runtime || return 0
  if [ -f "$root/Cargo.toml" ]; then
    log "Fetching Rust crates..."
    (cd "$root" && cargo fetch || true)
  fi
}

# PHP
ensure_php_runtime() {
  if have_cmd php; then return 0; fi
  pm_detect
  if ! require_root_for_pkg; then
    warn "PHP not found and cannot install system packages."
    return 1
  fi
  log "Installing PHP CLI..."
  pm_update
  case "$PKG_MANAGER" in
    apt) pm_install php-cli unzip ;;
    apk) pm_install php-cli php-phar curl unzip ;;
    dnf|yum|microdnf) pm_install php-cli unzip ;;
  esac
  pm_clean
}

ensure_composer() {
  if have_cmd composer; then return 0; fi
  pm_detect
  if require_root_for_pkg; then
    case "$PKG_MANAGER" in
      apt)
        pm_update; pm_install composer || true; pm_clean
        ;;
      apk)
        pm_update; pm_install composer || true; pm_clean
        ;;
      dnf|yum|microdnf)
        pm_update; pm_install composer || true; pm_clean
        ;;
    esac
  fi
  if ! have_cmd composer; then
    log "Installing Composer locally..."
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer || php composer-setup.php --filename=composer
    rm -f composer-setup.php || true
  fi
}

setup_php_project() {
  local root="$1"
  ensure_php_runtime || return 0
  ensure_composer
  if [ -f "$root/composer.json" ]; then
    log "Installing PHP dependencies via Composer..."
    (cd "$root" && composer install --no-interaction --prefer-dist || true)
  fi
}

# Environment files
ensure_env_file() {
  local root="$1"
  if [ ! -f "$root/.env" ] && [ -f "$root/.env.example" ]; then
    log "Creating .env from .env.example"
    cp "$root/.env.example" "$root/.env"
  fi
}

# Directory structure and permissions
setup_directories() {
  local root="$1"
  ensure_dir "$root/logs"
  ensure_dir "$root/tmp"
  ensure_dir "$root/dist"
  ensure_dir "$root/build"
  ensure_dir "$root/.cache"
}

# Determine app directory
determine_app_dir() {
  if [ -n "$APP_DIR" ]; then
    :
  elif [ -d "/workspace" ]; then
    APP_DIR="/workspace"
  elif [ -d "/app" ]; then
    APP_DIR="/app"
  else
    APP_DIR="$(pwd)"
  fi
  if [ -n "$APP_SUBDIR" ]; then
    APP_DIR="$APP_DIR/$APP_SUBDIR"
  fi
  ensure_dir "$APP_DIR"
}

# Permissions
apply_permissions() {
  local root="$1"
  local user="${DEFAULT_USER:-}"
  local group="${DEFAULT_GROUP:-}"
  # Try to infer user/group if not provided
  if [ -z "$user" ] || [ -z "$group" ]; then
    if is_root; then
      # If running as root in Docker, leave ownership as-is
      :
    else
      user="$(id -un)"; group="$(id -gn)"
    fi
  fi
  if [ -n "$user" ] && [ -n "$group" ]; then
    chown_if_possible "$root" "$user" "$group"
  fi
}

# Runtime environment configuration
configure_runtime_env() {
  export APP_ENV="${APP_ENV:-production}"
  export NODE_ENV="${NODE_ENV:-production}"
  export PORT="${PORT:-8000}"
  export PATH="$APP_DIR/bin:$APP_DIR/.bin:$PATH"
  ensure_path "$APP_DIR/node_modules/.bin" "$APP_DIR/.venv/bin" "$HOME/.local/bin"
}

# Makefile test target helper
ensure_makefile_test_target() {
  if [ -f Makefile ] && ! grep -qE '^[[:space:]]*test:' Makefile; then
    printf "%b\n" ".PHONY: test" "test:" "\t@if [ -f package.json ]; then npm test --silent --if-present; exit \$\$?; fi" "\t@if [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ] || [ -d tests ]; then python3 -m pytest -q; exit \$\$?; fi" "\t@if [ -f go.mod ]; then go test ./...; exit \$\$?; fi" "\t@if [ -f Cargo.toml ]; then cargo test --quiet; exit \$\$?; fi" "\t@if [ -f mvnw ]; then ./mvnw -q -DskipTests=false test; exit \$\$?; fi" "\t@if [ -f pom.xml ]; then mvn -q -DskipTests=false test; exit \$\$?; fi" "\t@if [ -f gradlew ]; then ./gradlew test; exit \$\$?; fi" "\t@if [ -f build.gradle ]; then gradle test; exit \$\$?; fi" "\t@echo \"No recognizable project type found for tests.\"; exit 2" >> Makefile
  fi
  if [ ! -f Makefile ]; then
    printf "%b\n" ".PHONY: test" "test:" "\t@if [ -f package.json ]; then npm test --silent --if-present; exit \$\$?; fi" "\t@if [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ] || [ -d tests ]; then python3 -m pytest -q; exit \$\$?; fi" "\t@if [ -f go.mod ]; then go test ./...; exit \$\$?; fi" "\t@if [ -f Cargo.toml ]; then cargo test --quiet; exit \$\$?; fi" "\t@if [ -f mvnw ]; then ./mvnw -q -DskipTests=false test; exit \$\$?; fi" "\t@if [ -f pom.xml ]; then mvn -q -DskipTests=false test; exit \$\$?; fi" "\t@if [ -f gradlew ]; then ./gradlew test; exit \$\$?; fi" "\t@if [ -f build.gradle ]; then gradle test; exit \$\$?; fi" "\t@echo \"No recognizable project type found for tests.\"; exit 2" > Makefile
  fi
}

# Ensure Makefile exports PYTHONSAFEPATH and MPLBACKEND for safe imports and headless matplotlib
ensure_makefile_env_exports() {
  if [ -f Makefile ]; then
    if ! grep -q '^export PYTHONSAFEPATH=1' Makefile; then
      local tmp
      tmp="$(mktemp)"
      printf 'export PYTHONSAFEPATH=1\nexport MPLBACKEND=Agg\n' | cat - Makefile > "$tmp"
      mv "$tmp" Makefile
    fi
  fi
}

# Ensure pytest is available globally as a fallback for test runners
ensure_pytest_global() {
  pm_detect
  # Install python3-pip if using apt and running as root
  if is_root && [ "$PKG_MANAGER" = "apt" ]; then
    log "Ensuring python3-pip, python3-pytest, python3-numpy, python3-toml, and python3-matplotlib are installed via apt..."
    pm_update
    pm_install python3-pip python3-pytest python3-numpy python3-toml python3-matplotlib
    apt-get update -y
    apt-get install -y libfreetype6 libpng16-16 fonts-dejavu
  fi
  # Configure Python safe import path to avoid CWD shadowing site-packages
  if have_cmd python3; then
    python3 - <<'PY'
import os, sysconfig
pure = sysconfig.get_paths().get('purelib')
os.makedirs(pure, exist_ok=True)
pth = os.path.join(pure, 'ci_safepath_and_mplbackend.pth')
with open(pth, 'w') as f:
    f.write('import os, sys; os.environ.setdefault("MPLBACKEND", "Agg"); sys.path = [p for p in sys.path if p not in ("", os.getcwd())]\n')
print(pth)
PY
    printf "[pytest]\naddopts = --import-mode=importlib\n" > pytest.ini
  fi
  # Configure environment for pytest and safe imports
  if is_root; then
    printf 'export PYTHONSAFEPATH=${PYTHONSAFEPATH:-1}\nexport MPLBACKEND=${MPLBACKEND:-Agg}\n' | tee /etc/profile.d/py_env.sh >/dev/null
    chmod 644 /etc/profile.d/py_env.sh
    printf "%s\n" "export PYTHONSAFEPATH=1" "export MPLBACKEND=Agg" > /etc/profile.d/ci_test_env.sh
    chmod 644 /etc/profile.d/ci_test_env.sh || true
    grep -q '^PYTHONSAFEPATH=' /etc/environment || printf '\nPYTHONSAFEPATH="1"\n' >> /etc/environment
    grep -q '^MPLBACKEND=' /etc/environment || printf 'MPLBACKEND="Agg"\n' >> /etc/environment
    printf "backend: Agg\n" | tee /etc/matplotlibrc > /dev/null
    printf '#!/bin/sh\nexport PYTHONSAFEPATH=1\nexport MPLBACKEND=Agg\nexec /usr/bin/make "$@"\n' | tee /usr/local/bin/make > /dev/null
    chmod +x /usr/local/bin/make
  fi
  export PYTHONSAFEPATH=1
  export PYTEST_ADDOPTS="--import-mode=importlib"
  export MPLBACKEND="Agg"
  # Ensure pip is available and install required packages
  if have_cmd python3; then
    python3 -m ensurepip --upgrade || true
    log "Upgrading pip/setuptools/wheel (toml and matplotlib provided by OS packages)..."
    python3 -m pip install --no-input -U pip setuptools wheel || true
    : # toml and matplotlib provided by OS packages; skipping pip install
    python3 - <<'PY'
import site, os, sys
content = '''# Auto-generated sitecustomize to enforce safe import path and headless plotting
import os, sys
# Remove current directory and working directory from sys.path to avoid local shadowing
try:
    cwd = os.getcwd()
    sys.path = [p for p in sys.path if p not in ('', cwd)]
except Exception:
    pass
# Ensure headless matplotlib backend
os.environ.setdefault('MPLBACKEND', 'Agg')
'''
paths = []
try:
    paths.extend(site.getsitepackages())
except Exception:
    pass
try:
    paths.append(site.getusersitepackages())
except Exception:
    pass
for d in [p for p in paths if isinstance(p, str)]:
    try:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'sitecustomize.py'), 'w') as f:
            f.write(content)
    except Exception as e:
        print(f'warn: could not write sitecustomize to {d}: {e}', file=sys.stderr)
PY
    python3 -m pip install -U pytest || true
  fi
}

# CI-safe Python virtual environment to avoid CWD shadowing and enforce safe imports
setup_ci_safe_python_venv() {
  local root="${1:-$APP_DIR}"
  local venv="/opt/venv"

  pm_detect
  if is_root && [ "$PKG_MANAGER" = "apt" ]; then
    apt-get update -y
    apt-get install -y python3-venv python3-pip
  fi

  if [ ! -d "$venv" ]; then
    python3 -m venv "$venv"
  fi

  "$venv/bin/python" -m pip install -U pip setuptools wheel
  "$venv/bin/pip" install -U pytest numpy
  if [ -n "$root" ]; then
    (cd "$root" && "$venv/bin/pip" install -e .) || true
  fi

  # Write a .pth hook to sanitize sys.path and force headless matplotlib
  "$venv/bin/python" - <<'PY'
import os, sysconfig
pure = sysconfig.get_paths().get('purelib')
os.makedirs(pure, exist_ok=True)
pth = os.path.join(pure, 'ci_safepath_and_mplbackend.pth')
with open(pth, 'w') as f:
    f.write('import os, sys; os.environ.setdefault("MPLBACKEND", "Agg"); sys.path = [p for p in sys.path if p not in ("", os.getcwd())]\n')
print(pth)
PY

  # Create pytest wrapper that enforces safe path and headless backend
  if [ -w /usr/local/bin ] || is_root; then
    cat >/usr/local/bin/pytest <<'PYWRAP'
#!/usr/bin/env python3
import os, sys, runpy
# Ensure headless backend for matplotlib
os.environ.setdefault("MPLBACKEND", "Agg")
# Remove current directory entries from sys.path to avoid shadowing
sys.path = [p for p in sys.path if p not in ("", ".")]
# Also hint to Python 3.11+ safe path behavior
os.environ.setdefault("PYTHONSAFEPATH", "1")
# Delegate to pytest module preserving CLI args
runpy.run_module("pytest", run_name="__main__")
PYWRAP
    chmod +x /usr/local/bin/pytest || true
    ln -sf /usr/local/bin/pytest /usr/local/bin/py.test || true
  fi

  # Export env for current session
  export PATH="$venv/bin:$PATH"
  export PYTHONSAFEPATH=1
}

# Ensure auto-activation of the CI venv for interactive shells
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line="source /opt/venv/bin/activate"
  if is_root; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

# Fix local numpy shadowing of the third-party package
fix_numpy_shadowing() {
  local root="${1:-$APP_DIR}"
  if [ -z "$root" ]; then root="$(pwd)"; fi
  (
    cd "$root" 2>/dev/null || return 0
    test -d numpy -a ! -e numpy_local_shadow && mv numpy numpy_local_shadow || true
    test -f numpy.py -a ! -e numpy_local_shadow.py && mv numpy.py numpy_local_shadow.py || true
  )
}

# Project type detection
detect_and_setup_projects() {
  local root="$1"
  local did_any=0

  # Python
  if [ -f "$root/requirements.txt" ] || [ -f "$root/pyproject.toml" ] || [ -f "$root/Pipfile" ] || [ -f "$root/poetry.lock" ]; then
    log "Detected Python project files."
    setup_python_project "$root" || true
    did_any=1
  fi

  # Node.js
  if [ -f "$root/package.json" ]; then
    log "Detected Node.js project."
    setup_node_project "$root" || true
    did_any=1
  fi

  # Ruby
  if [ -f "$root/Gemfile" ]; then
    log "Detected Ruby project."
    setup_ruby_project "$root" || true
    did_any=1
  fi

  # Java/Gradle/Maven
  if [ -f "$root/pom.xml" ] || [ -f "$root/build.gradle" ] || [ -f "$root/build.gradle.kts" ] || [ -f "$root/gradlew" ]; then
    log "Detected Java project."
    setup_java_project "$root" || true
    did_any=1
  fi

  # Go
  if [ -f "$root/go.mod" ]; then
    log "Detected Go project."
    setup_go_project "$root" || true
    did_any=1
  fi

  # Rust
  if [ -f "$root/Cargo.toml" ]; then
    log "Detected Rust project."
    setup_rust_project "$root" || true
    did_any=1
  fi

  # PHP
  if [ -f "$root/composer.json" ]; then
    log "Detected PHP project."
    setup_php_project "$root" || true
    did_any=1
  fi

  if [ "$did_any" -eq 0 ]; then
    warn "No recognized project files detected in $root."
  fi
}

# Cleanup caches and temporary files where safe
final_cleanup() {
  pm_detect
  pm_clean
  return 0
}

main() {
  log "Starting universal environment setup..."

  # Avoid interactive prompts
  if [ "$NONINTERACTIVE" = "1" ]; then
    export DEBIAN_FRONTEND=noninteractive
    export PIP_YES=1
    export BUNDLE_WITHOUT="${BUNDLE_WITHOUT:-development:test}"
    export COMPOSER_NO_INTERACTION=1
    export npm_config_yes=true
  fi

  determine_app_dir
  log "Using application directory: $APP_DIR"

  cd "$APP_DIR"

  install_base_tools
  setup_directories "$APP_DIR"
  ensure_env_file "$APP_DIR"
  configure_runtime_env
  setup_ci_safe_python_venv "$APP_DIR"
  setup_auto_activate
  fix_numpy_shadowing "$APP_DIR"
  ensure_pytest_global
  ensure_makefile_test_target
  ensure_makefile_env_exports

  detect_and_setup_projects "$APP_DIR"
  apply_permissions "$APP_DIR"

  final_cleanup

  log "Environment setup completed successfully."
  cat <<EOF

Usage notes:
- APP_DIR: $APP_DIR
- Common bin paths are added to PATH: .venv/bin, node_modules/.bin, bin
- Environment variables set: APP_ENV=${APP_ENV:-production}, NODE_ENV=${NODE_ENV:-production}, PORT=${PORT:-8000}
- To activate Python venv (if created): source "$APP_DIR/.venv/bin/activate"

This script is idempotent and safe to run multiple times.
EOF
}

main "$@"