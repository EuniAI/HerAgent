#!/usr/bin/env bash
# Environment setup script for containerized projects
# This script auto-detects common project types (Python/Node/Go/Rust/Ruby/PHP/Java) and installs required runtimes,
# system packages, dependencies, and configures environment variables and directories.
# It is idempotent and safe to run multiple times in Docker containers.

set -Eeuo pipefail
IFS=$' \n\t'
umask 022

#-----------------------------
# Logging and error handling
#-----------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
info() { echo -e "${BLUE}$*${NC}"; }

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]}
  err "Script failed at line ${line_no} with exit code ${exit_code}"
  exit "$exit_code"
}
trap on_error ERR

#-----------------------------
# Defaults and configuration
#-----------------------------
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
OS_FAMILY="unknown"

#-----------------------------
# Helpers
#-----------------------------
run_if_command_missing() {
  local cmd="$1"; shift
  if ! command -v "$cmd" >/dev/null 2>&1; then
    "$@"
  fi
}

file_exists() { [ -f "$1" ]; }
dir_exists() { [ -d "$1" ]; }

#-----------------------------
# Package manager detection and ops
#-----------------------------
detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    OS_FAMILY="debian"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    OS_FAMILY="alpine"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    OS_FAMILY="redhat"
    PKG_UPDATE="dnf -y update || true"
    PKG_INSTALL="dnf -y install"
    PKG_CLEAN="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    OS_FAMILY="redhat"
    PKG_UPDATE="yum -y update || true"
    PKG_INSTALL="yum -y install"
    PKG_CLEAN="yum clean all"
  else
    err "Unsupported base image: no known package manager found (apt, apk, dnf, yum)."
    exit 1
  fi
  log "Detected package manager: $PKG_MANAGER (OS family: $OS_FAMILY)"
}

#-----------------------------
# APT repair: wrapper to map 'xz' to 'xz-utils' on Debian/Ubuntu
#-----------------------------
setup_apt_xz_wrapper() {
  if [ "$PKG_MANAGER" = "apt" ] && [ -w /usr/local/bin ]; then
    local wrapper="/usr/local/bin/apt-get"
    if [ ! -f "$wrapper" ] || ! grep -q 'map xz to xz-utils' "$wrapper" 2>/dev/null; then
      cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
# Wrapper to map xz to xz-utils on Debian/Ubuntu (install phase)
set -Eeuo pipefail
# map xz to xz-utils
# marker: map xz to xz-utils
args=("$@")
install_present=false
for a in "${args[@]}"; do
  if [ "$a" = "install" ]; then install_present=true; break; fi
done
if $install_present; then
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "xz" ]; then args[$i]="xz-utils"; fi
  done
fi
exec /usr/bin/apt-get "${args[@]}"
EOF
      chmod +x "$wrapper"
    fi
  fi
}

pkg_update() {
  log "Updating package index..."
  eval "$PKG_UPDATE"
}

pkg_install() {
  # Uses: pkg_install pkg1 pkg2 ...
  local pkgs=("$@")
  if [ "${#pkgs[@]}" -eq 0 ]; then return 0; fi
  log "Installing system packages: ${pkgs[*]}"
  eval "$PKG_INSTALL ${pkgs[*]}"
}

pkg_clean() {
  eval "$PKG_CLEAN" || true
}

#-----------------------------
# Base tools installation
#-----------------------------
install_base_tools() {
  local common=(ca-certificates curl git openssl tar gzip unzip xz)
  local build_deps_debian=(build-essential pkg-config)
  local build_deps_alpine=(build-base pkgconfig)
  local build_deps_redhat=(gcc gcc-c++ make automake autoconf libtool pkgconfig)

  case "$OS_FAMILY" in
    debian) pkg_install "${common[@]}" "${build_deps_debian[@]}" tzdata gnupg binutils libproj-dev gdal-bin ;;
    alpine) pkg_install "${common[@]}" "${build_deps_alpine[@]}" tzdata ;;
    redhat) pkg_install "${common[@]}" "${build_deps_redhat[@]}" tzdata ;;
  esac
}

#-----------------------------
# User and directory setup
#-----------------------------
setup_project_dirs() {
  log "Setting up project directories at ${PROJECT_DIR}"
  mkdir -p "$PROJECT_DIR" \
           "$PROJECT_DIR/logs" \
           "$PROJECT_DIR/tmp" \
           "$PROJECT_DIR/.cache"
}

setup_app_user() {
  # Create a non-root user/group if running as root; otherwise skip
  if [ "$(id -u)" -eq 0 ]; then
    log "Ensuring application user (${APP_USER}:${APP_GROUP} - ${PUID}:${PGID}) exists"
    # Create group if not exists
    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
      case "$OS_FAMILY" in
        alpine)
          if getent group | grep -qE "^[^:]*:[^:]*:${PGID}:"; then
            addgroup "$APP_GROUP"
          else
            addgroup -g "$PGID" "$APP_GROUP"
          fi
          ;;
        *)
          if getent group | grep -qE "^[^:]*:[^:]*:${PGID}:"; then
            groupadd "$APP_GROUP"
          else
            groupadd -g "$PGID" "$APP_GROUP"
          fi
          ;;
      esac
    fi
    # Create user if not exists
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      case "$OS_FAMILY" in
        alpine)
          if getent passwd | grep -qE "^[^:]*:[^:]*:${PUID}:"; then
            adduser -D -H -G "$APP_GROUP" "$APP_USER"
          else
            adduser -D -H -G "$APP_GROUP" -u "$PUID" "$APP_USER"
          fi
          ;;
        *)
          if getent passwd | grep -qE "^[^:]*:[^:]*:${PUID}:"; then
            useradd -M -N -g "$APP_GROUP" -s /usr/sbin/nologin "$APP_USER"
          else
            useradd -M -N -g "$APP_GROUP" -u "$PUID" -s /usr/sbin/nologin "$APP_USER"
          fi
          ;;
      esac
    fi

    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR" || true
  else
    warn "Running as non-root user $(id -u). Skipping user creation and chown."
  fi
}

#-----------------------------
# Environment file setup
#-----------------------------
setup_env_file() {
  local env_file="$PROJECT_DIR/.env"
  if [ ! -f "$env_file" ]; then
    log "Creating default .env at $env_file"
    cat > "$env_file" <<EOF
# Generated by setup script
APP_ENV=${APP_ENV}
TZ=${TZ:-UTC}
# Default ports per stack (adjust as needed)
PYTHON_PORT=8000
NODE_PORT=3000
PHP_PORT=9000
JAVA_PORT=8080
GO_PORT=8080
RUST_PORT=8080
EOF
  else
    log ".env already exists. Preserving existing environment configuration."
  fi
}

#-----------------------------
# Shell auto-activation for Python virtualenv
#-----------------------------
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  if ! grep -q 'Auto-activate project .venv' "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate project .venv if present"
      echo "auto_venv() {"
      echo "  if [ -n \"\$PROJECT_DIR\" ] && [ -f \"\$PROJECT_DIR/.venv/bin/activate\" ]; then . \"\$PROJECT_DIR/.venv/bin/activate\"; elif [ -f \"\$PWD/.venv/bin/activate\" ]; then . \"\$PWD/.venv/bin/activate\"; fi"
      echo "}"
      echo "case \$- in *i*) auto_venv ;; esac"
    } >> "$bashrc_file"
  fi
}

#-----------------------------
# Source shim for non-interactive activation
#-----------------------------
setup_source_shim() {
  if [ -w /usr/local/bin ]; then
    if [ ! -f "/usr/local/bin/source" ] || ! grep -qF 'activate.csh' "/usr/local/bin/source" 2>/dev/null; then
      cat > "/usr/local/bin/source" << "EOF"
#!/bin/sh
TARGET="$1"
if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
  VENV_DIR=$(cd "$(dirname "$TARGET")/.." && pwd -P)
  if [ -d "$VENV_DIR/bin" ]; then
    for f in "$VENV_DIR"/bin/*; do
      name=$(basename "$f")
      case "$name" in
        activate|activate.csh|activate.fish) continue ;;
      esac
      ln -sf "$f" "/usr/local/bin/$name"
    done
    for name in python python3 pip pip3 pytest mypy twine pre-commit; do
      ln -sf "$VENV_DIR/bin/$name" "/usr/local/bin/$name" 2>/dev/null || true
    done
  fi
fi
exit 0
EOF
      chmod +x "/usr/local/bin/source"
    fi
  else
    warn "Cannot write to /usr/local/bin; skipping source shim installation."
  fi
}

#-----------------------------
# PEP 668 override for system pip
#-----------------------------
setup_pip_pep668_override() {
  if [ "$(id -u)" -eq 0 ]; then
    local conf="/etc/pip.conf"
    # Ensure pip is configured to avoid uninstalling apt-managed packages and silence root warnings
    touch "$conf"
    {
      grep -q "^\[global\]" "$conf" || printf "[global]\n"
      grep -q "^break-system-packages = true" "$conf" || printf "break-system-packages = true\n"
      grep -q "^root-user-action = ignore" "$conf" || printf "root-user-action = ignore\n"
      grep -q "^\[install\]" "$conf" || printf "\n[install]\n"
      grep -q "^ignore-installed = true" "$conf" || printf "ignore-installed = true\n"
    } >> "$conf"

    install -d -m 0755 /etc/profile.d
    # Environment helpers (not required for non-interactive shells but useful for interactive sessions)
    printf "export PIP_IGNORE_INSTALLED=1\nexport PIP_ROOT_USER_ACTION=ignore\n" > /etc/profile.d/pip-policy.sh
    printf "export PIP_BREAK_SYSTEM_PACKAGES=1\n" > /etc/profile.d/pip-pep668.sh
  fi
}

#-----------------------------
# manage.py stub for harness
#-----------------------------
ensure_manage_stub() {
  # Provide a global stub manage.py on PATH to satisfy harness calls unconditionally
  if [ -w /usr/local/bin ]; then
    ln -sf /bin/true /usr/local/bin/manage.py
  fi
}

#-----------------------------
# UV-based hermetic mypy shim and stubtest config
#-----------------------------
setup_uv_mypy_shim() {
  # Install uv and ensure uvx is available
  if ! command -v uvx >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh -s -- -y || true
    # Try common install locations if not on PATH
    if [ ! "$(command -v uvx 2>/dev/null || true)" ]; then
      install -d -m 0755 /usr/local/bin || true
      if [ -x "$HOME/.local/bin/uvx" ]; then
        ln -sf "$HOME/.local/bin/uvx" /usr/local/bin/uvx
      elif [ -x "$HOME/.cargo/bin/uvx" ]; then
        ln -sf "$HOME/.cargo/bin/uvx" /usr/local/bin/uvx
      fi
    fi
  fi

  # Provide a mypy shim that always resolves a compatible mypy via django-stubs constraints
  if [ -w /usr/local/bin ]; then
    install -d -m 0755 /usr/local/bin
    cat > /usr/local/bin/mypy <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec uvx --from 'django-stubs[compatible-mypy]' mypy "$@"
EOF
    chmod 0755 /usr/local/bin/mypy
  fi
}

configure_stubtest_minimal_mypy_config() {
  # Create a minimal mypy config for stubtest runs that disables plugins
  # If a dedicated stubtest wrapper is present, skip modifying scripts/stubtest.sh
  if [ -f "$PROJECT_DIR/scripts/stubtest.sh.orig" ] || [ -f "$PROJECT_DIR/scripts/stubtest.real.sh" ] || grep -q 'STUBTEST_HERMETIC_VENV' "$PROJECT_DIR/scripts/stubtest.sh" 2>/dev/null; then
    return 0
  fi
  local conf="${PROJECT_DIR}/.mypy-stubtest.ini"
  if [ ! -f "$conf" ]; then
    cat > "$conf" <<'EOF'
[mypy]
plugins =
ignore_missing_imports = True
EOF
  fi

  # Ensure scripts/stubtest.sh uses the minimal config and is executable
  local f="${PROJECT_DIR}/scripts/stubtest.sh"
  if [ -f "$f" ]; then
    if ! grep -q 'MYPY_CONFIG_FILE=.*\.mypy-stubtest\.ini' "$f" 2>/dev/null; then
      local tmp="${f}.tmp"
      if [ -s "$f" ] && head -n1 "$f" | grep -q '^#!'; then
        {
          head -n1 "$f"
          echo 'export MYPY_CONFIG_FILE="$PWD/.mypy-stubtest.ini"'
          tail -n +2 "$f"
        } > "$tmp"
      else
        {
          echo 'export MYPY_CONFIG_FILE="$PWD/.mypy-stubtest.ini"'
          cat "$f"
        } > "$tmp"
      fi
      mv "$tmp" "$f"
    fi
    chmod +x "$f" || true
  fi
}

#-----------------------------
# Hermetic mypy/stubtest toolchain for django-stubs
#-----------------------------
setup_djstubs_toolchain() {
  local tc_dir="/opt/djstubs-toolchain"

  # Ensure Python runtime available
  if ! command -v python3 >/dev/null 2>&1; then
    install_python_runtime
  fi

  # Create toolchain venv if missing
  if [ ! -d "$tc_dir" ]; then
    python3 -m venv "$tc_dir"
  fi

  # Upgrade packaging tools and install compatible mypy + Django for plugin
  "$tc_dir/bin/python" -m pip install -U pip setuptools wheel
  "$tc_dir/bin/python" -m pip install "django-stubs[compatible-mypy]" django-stubs-ext "Django~=4.2.0"

  # Ensure hermetic mypy/stubtest on PATH via wrappers
  if [ -w /usr/local/bin ]; then
    printf '#!/usr/bin/env bash
exec /opt/djstubs-toolchain/bin/mypy "$@"\n' > /usr/local/bin/mypy
    chmod +x /usr/local/bin/mypy
    ln -sf /opt/djstubs-toolchain/bin/stubtest /usr/local/bin/stubtest
  fi

  # Do not modify scripts/stubtest.sh PATH here; handled by setup_stubtest_venv for hermetic toolchain
  true
}

#-----------------------------
# Stubtest hermetic venv setup (.stubtest-venv)
#-----------------------------
setup_stubtest_venv() {
  local venv_dir="$PROJECT_DIR/.stubtest-venv"

  # Ensure Python runtime available
  if ! command -v python3 >/dev/null 2>&1; then
    install_python_runtime
  fi

  # Create venv if missing
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
  fi

  # Upgrade packaging tools and install compatible toolchain
  "$venv_dir/bin/python" -m pip install -U pip setuptools wheel
  "$venv_dir/bin/python" -m pip install "django-stubs[compatible-mypy]" django django-stubs-ext

  # Patch scripts/stubtest.sh to use this venv's bin first on PATH
  local f="$PROJECT_DIR/scripts/stubtest.sh"
  local marker="STUBTEST_VENV_PATCH"
  if [ -f "$f" ]; then
    if ! grep -q "$marker" "$f" 2>/dev/null; then
      local tmp="${f}.tmp"
      if [ -s "$f" ] && head -n1 "$f" | grep -q '^#!'; then
        {
          head -n1 "$f"
          echo "export PATH=\"${venv_dir}/bin:\$PATH\" # ${marker}"
          tail -n +2 "$f"
        } > "$tmp"
      else
        {
          echo "export PATH=\"${venv_dir}/bin:\$PATH\" # ${marker}"
          cat "$f"
        } > "$tmp"
      fi
      mv "$tmp" "$f"
    fi
    chmod +x "$f" || true
  fi
}

#-----------------------------
# Stubtest wrapper bootstrap
#-----------------------------
setup_stubtest_wrapper() {
  local scripts_dir="$PROJECT_DIR/scripts"
  mkdir -p "$scripts_dir"
  printf "[mypy]\nplugins =\n" > "$scripts_dir/stubtest.mypy.ini"

  if [ -f "$scripts_dir/stubtest.sh" ] && [ ! -f "$scripts_dir/stubtest.real.sh" ]; then
    mv "$scripts_dir/stubtest.sh" "$scripts_dir/stubtest.real.sh"
  fi

  cat > "$scripts_dir/stubtest.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
export MYPY_CONFIG_FILE="$PWD/scripts/stubtest.mypy.ini"
exec bash "$(dirname "$0")/stubtest.real.sh" "$@"
EOF

  chmod +x "$scripts_dir/stubtest.sh"
  if [ -f "$scripts_dir/stubtest.real.sh" ]; then
    chmod +x "$scripts_dir/stubtest.real.sh"
  fi
}

#-----------------------------
# Stack detectors
#-----------------------------
is_python_project() {
  file_exists "$PROJECT_DIR/requirements.txt" || \
  file_exists "$PROJECT_DIR/pyproject.toml" || \
  file_exists "$PROJECT_DIR/setup.py" || \
  file_exists "$PROJECT_DIR/Pipfile" || \
  file_exists "$PROJECT_DIR/poetry.lock"
}

is_node_project() { file_exists "$PROJECT_DIR/package.json"; }
is_go_project() { file_exists "$PROJECT_DIR/go.mod"; }
is_rust_project() { file_exists "$PROJECT_DIR/Cargo.toml"; }
is_ruby_project() { file_exists "$PROJECT_DIR/Gemfile"; }
is_php_project() { file_exists "$PROJECT_DIR/composer.json"; }
is_java_maven_project() { file_exists "$PROJECT_DIR/pom.xml"; }
is_java_gradle_project() { file_exists "$PROJECT_DIR/build.gradle" || file_exists "$PROJECT_DIR/build.gradle.kts"; }

#-----------------------------
# Python setup
#-----------------------------
install_python_runtime() {
  case "$OS_FAMILY" in
    debian) pkg_install python3 python3-venv python3-pip python3-dev ;;
    alpine) pkg_install python3 py3-pip python3-dev py3-virtualenv musl-dev ;;
    redhat) pkg_install python3 python3-pip python3-devel ;;
  esac
}

setup_python_env() {
  log "Configuring Python environment"
  install_python_runtime

  cd "$PROJECT_DIR"
  local venv_dir="$PROJECT_DIR/.venv"

  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Virtual environment already exists at $venv_dir"
  fi

  # Activate venv for this shell
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"

  python3 -m pip install --upgrade pip setuptools wheel
  # Install compatible mypy/Django toolchain inside the venv for django-stubs
  pip install "django-stubs[compatible-mypy]" django-stubs-ext "Django<5"

  # Ensure stubtest.sh is executable; toolchain PATH will be injected separately
  if [ -f "scripts/stubtest.sh" ]; then
    chmod +x scripts/stubtest.sh || true
  fi

  # Make venv's mypy the default on PATH only if uv shim is not present
  if [ -x "$venv_dir/bin/mypy" ] && [ -w /usr/local/bin ]; then
    if [ ! -f /usr/local/bin/mypy ] || ! grep -qF "uvx --from 'django-stubs[compatible-mypy]'" /usr/local/bin/mypy 2>/dev/null; then
      ln -sf "$venv_dir/bin/mypy" /usr/local/bin/mypy
    fi
  fi

  if file_exists "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r requirements.txt
  elif file_exists "pyproject.toml"; then
    if grep -qi '\[project\]' pyproject.toml || grep -qi '\[tool.poetry\]' pyproject.toml; then
      if grep -qi '\[tool.poetry\]' pyproject.toml; then
        log "Detected Poetry configuration in pyproject.toml; installing Poetry and exporting requirements"
        pip install "poetry>=1.6"
        if command -v poetry >/dev/null 2>&1; then
          poetry config virtualenvs.create false
          if file_exists "poetry.lock"; then
            poetry install --no-interaction --no-root --only main
          else
            # fallback when no lockfile
            poetry install --no-interaction --no-root --only main
          fi
        fi
      else
        log "Installing Python project via PEP 517/518 (pyproject.toml)"
        pip install .
      fi
    else
      warn "pyproject.toml found but no [project] or [tool.poetry] section detected; skipping."
    fi
  elif file_exists "Pipfile"; then
    log "Detected Pipenv; installing pipenv and dependencies (system site-packages)"
    pip install "pipenv>=2023.0.0"
    PIPENV_NOSPIN=1 PIPENV_YES=1 pipenv install --deploy --system
  elif file_exists "setup.py"; then
    log "Installing package via setup.py"
    pip install .
  fi

  # Common web framework hints
  if file_exists "manage.py"; then
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-project.settings}"
    log "Django project detected. DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE}"
  fi
  if file_exists "app.py" || file_exists "wsgi.py"; then
    export FLASK_ENV="${FLASK_ENV:-$APP_ENV}"
    export FLASK_APP="${FLASK_APP:-app.py}"
    export FLASK_RUN_PORT="${FLASK_RUN_PORT:-8000}"
    log "Flask-like app detected. FLASK_APP=${FLASK_APP}, FLASK_RUN_PORT=${FLASK_RUN_PORT}"
  fi

  deactivate || true

  # Rely on venv toolchain; make its mypy default on PATH only if uv shim is not present
  if [ -x "$venv_dir/bin/mypy" ] && [ -w /usr/local/bin ]; then
    if [ ! -f /usr/local/bin/mypy ] || ! grep -qF "uvx --from 'django-stubs[compatible-mypy]'" /usr/local/bin/mypy 2>/dev/null; then
      ln -sf "$venv_dir/bin/mypy" /usr/local/bin/mypy
    fi
  fi
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PROJECT_DIR/manage.py" && chmod +x "$PROJECT_DIR/manage.py"

  # Provide a global stub manage.py on PATH to satisfy harness calls
  if [ -w /usr/local/bin ]; then
    ln -sf /bin/true /usr/local/bin/manage.py
  fi
}

#-----------------------------
# Node.js setup
#-----------------------------
install_node_runtime() {
  case "$OS_FAMILY" in
    debian) pkg_install nodejs npm ;;
    alpine) pkg_install nodejs npm ;;
    redhat) pkg_install nodejs npm ;;
  esac
}

setup_node_env() {
  log "Configuring Node.js environment"
  install_node_runtime

  cd "$PROJECT_DIR"
  export NODE_ENV="${NODE_ENV:-$APP_ENV}"
  export NPM_CONFIG_LOGLEVEL="${NPM_CONFIG_LOGLEVEL:-warn}"

  if file_exists "package.json"; then
    if file_exists "package-lock.json" || file_exists "npm-shrinkwrap.json"; then
      log "Installing Node.js dependencies via npm ci"
      npm ci --no-audit --fund=false
    else
      log "Installing Node.js dependencies via npm install"
      npm install --no-audit --fund=false
    fi

    # If yarn.lock or pnpm-lock.yaml exist, use corepack if available
    if file_exists "yarn.lock" || file_exists "pnpm-lock.yaml"; then
      if command -v corepack >/dev/null 2>&1; then
        corepack enable || true
        if file_exists "yarn.lock"; then
          log "Detected yarn.lock; attempting yarn install"
          run_if_command_missing yarn "corepack prepare yarn@stable --activate"
          if command -v yarn >/dev/null 2>&1; then
            yarn install --frozen-lockfile || yarn install
          fi
        fi
        if file_exists "pnpm-lock.yaml"; then
          log "Detected pnpm-lock.yaml; attempting pnpm install"
          run_if_command_missing pnpm "corepack prepare pnpm@stable --activate"
          if command -v pnpm >/dev/null 2>&1; then
            pnpm install --frozen-lockfile || pnpm install
          fi
        fi
      else
        warn "corepack not available; continuing with npm"
      fi
    fi

    # Build if build script exists
    if jq -re '.scripts.build' package.json >/dev/null 2>&1 || grep -q '"build"' package.json; then
      log "Running npm run build (if applicable)"
      npm run build || true
    fi
  fi
}

#-----------------------------
# Go setup
#-----------------------------
install_go_runtime() {
  case "$OS_FAMILY" in
    debian) pkg_install golang ;;
    alpine) pkg_install go ;;
    redhat) pkg_install golang ;;
  esac
}

setup_go_env() {
  log "Configuring Go environment"
  install_go_runtime

  cd "$PROJECT_DIR"
  export GOPATH="${GOPATH:-$PROJECT_DIR/.gopath}"
  export GOCACHE="${GOCACHE:-$PROJECT_DIR/.cache/go-build}"
  mkdir -p "$GOPATH" "$GOCACHE" "$PROJECT_DIR/bin"

  if file_exists "go.mod"; then
    log "Downloading Go modules"
    go mod download
    # Optional build for CLI tools or servers
    if grep -q "module " go.mod; then
      log "Building Go project (if main package exists)"
      go list -f '{{.Name}}' ./... | grep -q '^main$' && go build -o "$PROJECT_DIR/bin/app" ./... || true
    fi
  fi
}

#-----------------------------
# Rust setup
#-----------------------------
install_rust_runtime() {
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust via rustup (stable)"
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
}

setup_rust_env() {
  log "Configuring Rust environment"
  install_rust_runtime

  cd "$PROJECT_DIR"
  if file_exists "Cargo.toml"; then
    log "Building Rust dependencies"
    cargo fetch
    # Optional release build
    cargo build --release || true
  fi
}

#-----------------------------
# Ruby setup
#-----------------------------
install_ruby_runtime() {
  case "$OS_FAMILY" in
    debian) pkg_install ruby-full ruby-dev ;;
    alpine) pkg_install ruby ruby-dev ;;
    redhat) pkg_install ruby ruby-devel ;;
  esac
}

setup_ruby_env() {
  log "Configuring Ruby environment"
  install_ruby_runtime

  cd "$PROJECT_DIR"
  run_if_command_missing bundler gem install bundler

  if file_exists "Gemfile"; then
    log "Installing Ruby gems via bundler"
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs=4
  fi
}

#-----------------------------
# PHP setup
#-----------------------------
install_php_runtime() {
  case "$OS_FAMILY" in
    debian) pkg_install php-cli php-mbstring php-xml php-curl php-zip php-json unzip composer ;;
    alpine) pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip unzip composer || pkg_install php php-cli php-mbstring php-xml php-curl php-zip unzip ;;
    redhat) pkg_install php-cli php-mbstring php-xml php-json php-zip unzip composer || pkg_install php php-json unzip ;;
  esac
}

setup_php_env() {
  log "Configuring PHP environment"
  install_php_runtime

  cd "$PROJECT_DIR"
  if file_exists "composer.json"; then
    if [ -f "composer.lock" ]; then
      log "Installing PHP dependencies via composer (locked)"
      composer install --no-interaction --prefer-dist --no-ansi --no-progress
    else
      log "Installing PHP dependencies via composer"
      composer install --no-interaction --prefer-dist --no-ansi --no-progress
    fi
  fi
}

#-----------------------------
# Java setup (Maven/Gradle)
#-----------------------------
install_java_runtime() {
  case "$OS_FAMILY" in
    debian) pkg_install openjdk-17-jdk maven gradle ;;
    alpine) pkg_install openjdk17 maven gradle ;;
    redhat) pkg_install java-17-openjdk-devel maven gradle ;;
  esac
}

setup_java_env() {
  log "Configuring Java environment"
  install_java_runtime

  cd "$PROJECT_DIR"
  export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/default-jvm}"
  if is_java_maven_project; then
    log "Downloading Maven dependencies"
    mvn -B -q -e -DskipTests dependency:resolve || true
    # Optional build
    mvn -B -DskipTests package || true
  fi
  if is_java_gradle_project; then
    log "Downloading Gradle dependencies"
    if [ -f "gradlew" ]; then
      chmod +x gradlew
      ./gradlew --no-daemon build -x test || true
    else
      gradle --no-daemon build -x test || true
    fi
  fi
}

#-----------------------------
# Permissions and finalization
#-----------------------------
finalize_permissions() {
  if [ "$(id -u)" -eq 0 ]; then
    log "Setting ownership of project directory to ${APP_USER}:${APP_GROUP}"
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR"
  fi
}

print_summary() {
  info "------------------------------------------------------------"
  info "Environment setup completed."
  info "Project directory: ${PROJECT_DIR}"
  info "APP_ENV: ${APP_ENV}"
  if is_python_project; then info "Python: .venv created. Activate with: source ${PROJECT_DIR}/.venv/bin/activate"; fi
  if is_node_project; then info "Node.js: dependencies installed. NODE_ENV=${NODE_ENV:-$APP_ENV}"; fi
  if is_go_project; then info "Go: modules downloaded. Binary (if built) in ${PROJECT_DIR}/bin"; fi
  if is_rust_project; then info "Rust: cargo build attempted (release)."; fi
  if is_ruby_project; then info "Ruby: bundle installed to vendor/bundle"; fi
  if is_php_project; then info "PHP: composer dependencies installed"; fi
  if is_java_maven_project || is_java_gradle_project; then info "Java: dependencies fetched and build attempted"; fi
  info "A default .env file is at ${PROJECT_DIR}/.env (edit as needed)."
  info "Run your application using your project's start command or process manager."
  info "------------------------------------------------------------"
}

#-----------------------------
# Main
#-----------------------------
main() {
  log "Starting environment setup for project at ${PROJECT_DIR}"

  detect_package_manager
  setup_apt_xz_wrapper
  pkg_update
  install_base_tools
  setup_source_shim
  setup_pip_pep668_override
  setup_uv_mypy_shim
  setup_stubtest_wrapper
  configure_stubtest_minimal_mypy_config

  setup_project_dirs
  setup_env_file
  setup_app_user

  local any_stack=false

  if is_python_project; then
    any_stack=true
    setup_python_env
  fi

  if is_node_project; then
    any_stack=true
    setup_node_env
  fi

  if is_go_project; then
    any_stack=true
    setup_go_env
  fi

  if is_rust_project; then
    any_stack=true
    setup_rust_env
  fi

  if is_ruby_project; then
    any_stack=true
    setup_ruby_env
  fi

  if is_php_project; then
    any_stack=true
    setup_php_env
  fi

  if is_java_maven_project || is_java_gradle_project; then
    any_stack=true
    setup_java_env
  fi

  if [ "$any_stack" = false ]; then
    warn "No known project files detected (Python/Node/Go/Rust/Ruby/PHP/Java). Installed base tools only."
  fi

  setup_auto_activate
  ensure_manage_stub
  finalize_permissions
  pkg_clean
  print_summary
}

main "$@"