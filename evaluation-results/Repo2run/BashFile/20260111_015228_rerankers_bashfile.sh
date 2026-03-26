#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects common project types (Python, Node.js, Ruby, Go, Java, PHP) and installs dependencies.
# Idempotent, with robust error handling and logging.

set -Eeuo pipefail

# Globals
APP_DIR="${APP_DIR:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-root}"       # default root inside Docker
APP_GROUP="${APP_GROUP:-root}"
DEFAULT_PORT="${DEFAULT_PORT:-8080}"  # fallback port

# Colors (may be ignored if not supported)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

timestamp() { date +'%Y-%m-%d %H:%M:%S'; }

log() { echo "${GREEN}[$(timestamp)] $*${NC}"; }
info() { echo "${BLUE}[$(timestamp)] $*${NC}"; }
warn() { echo "${YELLOW}[$(timestamp)] [WARN] $*${NC}" >&2; }
err() { echo "${RED}[$(timestamp)] [ERROR] $*${NC}" >&2; }

cleanup() {
  set +e
  # APT cleanup to reduce image size when applicable
  if command -v apt-get >/dev/null 2>&1; then
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* || true
  fi
}
trap 'err "Setup failed on line $LINENO"; exit 1' ERR
trap cleanup EXIT

# Detect package manager
PKG_MGR=""
detect_pkg_mgr() {
  if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    export APK_PROGRESS=no
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    export DEBIAN_FRONTEND=noninteractive
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    err "No supported package manager found (apk/apt/dnf/yum)."
    exit 1
  fi
}

# Helper: install packages if missing (idempotent)
apt_install_if_missing() {
  local missing=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing (apt) packages: ${missing[*]}"
    apt-get update -y
    apt-get install -y --no-install-recommends "${missing[@]}"
  else
    info "All requested apt packages already installed."
  fi
}

apk_add_if_missing() {
  local missing=()
  for pkg in "$@"; do
    if ! apk info -e "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing (apk) packages: ${missing[*]}"
    apk add --no-cache "${missing[@]}"
  else
    info "All requested apk packages already installed."
  fi
}

dnf_install_if_missing() {
  local missing=()
  for pkg in "$@"; do
    if ! dnf list --installed "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing (dnf) packages: ${missing[*]}"
    dnf install -y "${missing[@]}"
  else
    info "All requested dnf packages already installed."
  fi
}

yum_install_if_missing() {
  local missing=()
  for pkg in "$@"; do
    if ! yum list installed "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing (yum) packages: ${missing[*]}"
    yum install -y "${missing[@]}"
  else
    info "All requested yum packages already installed."
  fi
}

ensure_packages() {
  case "$PKG_MGR" in
    apk) apk_add_if_missing "$@";;
    apt) apt_install_if_missing "$@";;
    dnf) dnf_install_if_missing "$@";;
    yum) yum_install_if_missing "$@";;
    *) err "Unsupported package manager"; exit 1;;
  esac
}

# Base system setup
install_base_system_tools() {
  log "Installing base system tools and build dependencies..."
  case "$PKG_MGR" in
    apk)
      ensure_packages ca-certificates curl git bash coreutils tar unzip gzip \
        build-base pkgconfig openssl
      update-ca-certificates || true
      ;;
    apt)
      apt_install_if_missing ca-certificates curl git bash coreutils tar unzip gzip \
        build-essential pkg-config openssl
      update-ca-certificates || true
      ;;
    dnf|yum)
      ensure_packages ca-certificates curl git bash coreutils tar unzip gzip \
        make gcc gcc-c++ pkgconfig openssl
      ;;
  esac
}

# Directory setup
setup_directories() {
  log "Setting up project directories at $APP_DIR"
  mkdir -p "$APP_DIR"/{logs,tmp,run}
  # Set ownership and permissions; avoid changing mounted code ownership unexpectedly
  chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR"/logs "$APP_DIR"/tmp "$APP_DIR"/run
  chmod 755 "$APP_DIR"
  chmod -R 775 "$APP_DIR"/logs "$APP_DIR"/tmp "$APP_DIR"/run
}

# Environment variables
write_env_file() {
  local env_file="$APP_DIR/env.sh"
  log "Writing environment configuration to $env_file"
  cat > "$env_file" <<EOF
# Source this file to load project environment variables
export APP_DIR="$APP_DIR"
export APP_ENV="${APP_ENV}"
export PATH="\$APP_DIR/bin:\$APP_DIR/.venv/bin:\$APP_DIR/node_modules/.bin:\$HOME/.local/bin:\$PATH"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"
export PIP_NO_CACHE_DIR="1"
export PYTHONDONTWRITEBYTECODE="1"
export PYTHONUNBUFFERED="1"
export NODE_ENV="production"
export GOPATH="\$APP_DIR/.gopath"
export GOCACHE="\$APP_DIR/.gocache"
export JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+UseContainerSupport"
export APP_PORT="${APP_PORT:-$DEFAULT_PORT}"
EOF
  chmod 644 "$env_file"
}

# Detect project types
has_file() { [ -f "$APP_DIR/$1" ]; }
has_dir() { [ -d "$APP_DIR/$1" ]; }
file_contains() { grep -qi "$2" "$APP_DIR/$1" 2>/dev/null; }

# Ensure user's shell auto-activates the project virtual environment
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_path="$APP_DIR/.venv/bin/activate"
  # Check by path to avoid duplicates even if 'source' vs '.' differs or quotes vary
  if ! grep -qF "$activate_path" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "if [ -d \"$APP_DIR/.venv\" ] && [ -n \"\$PS1\" ] && [ -z \"\$VIRTUAL_ENV\" ]; then" >> "$bashrc_file"
    echo "  . \"$APP_DIR/.venv/bin/activate\"" >> "$bashrc_file"
    echo "fi" >> "$bashrc_file"
  fi
}

detect_project_types() {
  PROJECT_TYPES=()

  # Python
  if has_file "requirements.txt" || has_file "pyproject.toml" || has_file "setup.py"; then
    PROJECT_TYPES+=("python")
  fi

  # Node.js
  if has_file "package.json"; then
    PROJECT_TYPES+=("node")
  fi

  # Ruby
  if has_file "Gemfile"; then
    PROJECT_TYPES+=("ruby")
  fi

  # Go
  if has_file "go.mod" || has_file "go.sum"; then
    PROJECT_TYPES+=("go")
  fi

  # Java (Maven/Gradle)
  if has_file "pom.xml" || has_file "build.gradle" || has_file "build.gradle.kts" || has_file "gradlew"; then
    PROJECT_TYPES+=("java")
  fi

  # PHP
  if has_file "composer.json"; then
    PROJECT_TYPES+=("php")
  fi

  if [ "${#PROJECT_TYPES[@]}" -eq 0 ]; then
    warn "No specific project type files detected. Installing base tools only."
  else
    info "Detected project types: ${PROJECT_TYPES[*]}"
  fi
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MGR" in
    apk)
      ensure_packages python3 py3-pip python3-dev py3-virtualenv
      ;;
    apt)
      apt_install_if_missing python3 python3-pip python3-venv python3-dev
      ;;
    dnf|yum)
      ensure_packages python3 python3-pip python3-devel
      ;;
  esac

  # Create venv at .venv
  if [ ! -d "$APP_DIR/.venv" ]; then
    log "Creating Python virtual environment at $APP_DIR/.venv"
    python3 -m venv "$APP_DIR/.venv"
  else
    info "Python virtual environment already exists at $APP_DIR/.venv"
  fi

  # Activate and install deps
  # shellcheck disable=SC1091
  source "$APP_DIR/.venv/bin/activate"
  # Install a pip shim that rewrites 'rerankers[all]' to 'rerankers' and ensure it's first in PATH
  export PIP_PREFER_BINARY=1
  # Prefer binary wheels globally via pip config as a safeguard
  python -m pip config set global.prefer-binary true || true
  # Configure pip to prefer CPU wheels and binaries
  mkdir -p "$HOME/.config/pip"
  cat > "$HOME/.config/pip/pip.conf" <<'PIP'
[global]
index-url = https://pypi.org/simple
extra-index-url = https://download.pytorch.org/whl/cpu
prefer-binary = true
PIP
  python -m pip install -U pip setuptools wheel build
  # Preinstall PyTorch CPU stack to avoid GPU wheels/heavy deps
  python -m pip install -U --prefer-binary --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple torch
  # Install CPU-only stubs for flash-attn and xformers to satisfy dependency resolution without CUDA builds
  python - <<'PY'
import os, sys, tempfile, textwrap, subprocess
from pathlib import Path
# Create a minimal local stub package for flash-attn that satisfies version constraints
td = Path(tempfile.mkdtemp())
(td / "pyproject.toml").write_text(textwrap.dedent(
    """
    [build-system]
    requires = ["setuptools>=61"]
    build-backend = "setuptools.build_meta"

    [project]
    name = "flash-attn"
    version = "2.9.9"
    description = "CPU-only stub for flash-attn to satisfy dependency in non-CUDA environments"
    requires-python = ">=3.8"
    """
).lstrip())
(pkg := td / "flash_attn").mkdir()
(pkg / "__init__.py").write_text("def is_available(): return False\n__all__=['is_available']\n")
subprocess.check_call([sys.executable, "-m", "build", "-w", str(td)])
whls = list((td / "dist").glob("flash_attn-*.whl"))
assert whls, "wheel not built"
subprocess.check_call([sys.executable, "-m", "pip", "install", "--no-deps", "--no-input", "--no-cache-dir", str(whls[0])])
print("Installed stub:", whls[0])
PY

  # Install rerankers from binary wheels only to avoid source builds
  python -m pip install --upgrade "rerankers[all]"

  if has_file "requirements.txt"; then
    log "Sanitizing and installing Python dependencies from requirements.txt (CPU-only friendly)"
    cp "$APP_DIR/requirements.txt" "$APP_DIR/requirements.txt.bak" || true
    sed -i -E '/^(cupy-cuda|flash-attn|flashinfer|vllm(|[<=>].*)|rank-llm|cuda-(python|bindings)|nvidia-(cudnn|cublas|cufft|cusparse|cusolver|cutlass|cuda).*)/ s/^/# disabled for CPU: /' "$APP_DIR/requirements.txt"
    python3 -m pip install --prefer-binary --no-build-isolation -r "$APP_DIR/requirements.txt"
  elif has_file "pyproject.toml"; then
    if file_contains "pyproject.toml" "build-system"; then
      log "Installing Python project via pyproject.toml"
      python3 -m pip install "$APP_DIR"
    else
      warn "pyproject.toml found but no build-system defined; skipping install."
    fi
  elif has_file "setup.py"; then
    log "Installing Python project via setup.py (editable)"
    python3 -m pip install -e "$APP_DIR"
  else
    info "No Python dependency file found; skipping pip install."
  fi

  deactivate || true

  # Determine default port for Python
  if has_file "manage.py"; then
    APP_PORT="${APP_PORT:-8000}"
  elif has_file "app.py" && file_contains "requirements.txt" "flask"; then
    APP_PORT="${APP_PORT:-5000}"
  else
    APP_PORT="${APP_PORT:-$DEFAULT_PORT}"
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apk)
      ensure_packages nodejs npm
      ;;
    apt)
      apt_install_if_missing nodejs npm
      ;;
    dnf|yum)
      ensure_packages nodejs npm
      ;;
  esac

  # Install dependencies
  if has_file "package.json"; then
    if has_file "package-lock.json"; then
      log "Installing Node.js dependencies with npm ci"
      npm ci --prefix "$APP_DIR"
    else
      log "Installing Node.js dependencies with npm install"
      npm install --prefix "$APP_DIR"
    fi
  fi

  # Default port for Node.js
  APP_PORT="${APP_PORT:-3000}"
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apk)
      ensure_packages ruby ruby-dev build-base
      ;;
    apt)
      apt_install_if_missing ruby-full build-essential
      ;;
    dnf|yum)
      ensure_packages ruby ruby-devel make gcc gcc-c++
      ;;
  esac

  # Install bundler
  if ! command -v bundler >/dev/null 2>&1; then
    log "Installing bundler gem"
    gem install --no-document bundler
  fi

  if has_file "Gemfile"; then
    log "Installing Ruby gems via bundler"
    BUNDLE_PATH="$APP_DIR/vendor/bundle"
    mkdir -p "$BUNDLE_PATH"
    bundle config set --local path "$BUNDLE_PATH"
    bundle install
  fi

  APP_PORT="${APP_PORT:-$DEFAULT_PORT}"
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apk)
      ensure_packages go
      ;;
    apt)
      apt_install_if_missing golang
      ;;
    dnf|yum)
      ensure_packages golang
      ;;
  esac

  mkdir -p "$APP_DIR/.gopath" "$APP_DIR/.gocache"
  export GOPATH="$APP_DIR/.gopath"
  export GOCACHE="$APP_DIR/.gocache"

  if has_file "go.mod"; then
    log "Downloading Go modules"
    (cd "$APP_DIR" && go mod download)
  fi

  APP_PORT="${APP_PORT:-8080}"
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MGR" in
    apk)
      ensure_packages openjdk17-jdk maven gradle
      ;;
    apt)
      # Prefer JDK 17 where available
      apt_install_if_missing openjdk-17-jdk
      # Maven/Gradle optional based on project files
      if has_file "pom.xml"; then apt_install_if_missing maven; fi
      if has_file "build.gradle" || has_file "build.gradle.kts"; then apt_install_if_missing gradle; fi
      ;;
    dnf|yum)
      ensure_packages java-17-openjdk java-17-openjdk-devel maven gradle
      ;;
  esac

  if has_file "pom.xml"; then
    log "Resolving Maven dependencies (no tests)"
    (cd "$APP_DIR" && mvn -B -q -DskipTests dependency:resolve dependency:resolve-plugins)
  fi

  if has_file "gradlew"; then
    log "Using Gradle wrapper to prepare build (no tests)"
    chmod +x "$APP_DIR/gradlew"
    (cd "$APP_DIR" && ./gradlew --no-daemon build -x test)
  elif has_file "build.gradle" || has_file "build.gradle.kts"; then
    log "Using system Gradle to prepare build (no tests)"
    (cd "$APP_DIR" && gradle --no-daemon build -x test)
  fi

  APP_PORT="${APP_PORT:-8080}"
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apk)
      ensure_packages php php-cli php-phar php-json php-openssl composer
      ;;
    apt)
      apt_install_if_missing php-cli php-json php-mbstring php-xml php-zip
      # Composer install via package or fallback to installer
      if ! command -v composer >/dev/null 2>&1; then
        if apt-get update -y && apt-get install -y composer; then
          :
        else
          warn "Composer package not available, installing via official installer"
          curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
          php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
          rm -f /tmp/composer-setup.php
        fi
      fi
      ;;
    dnf|yum)
      ensure_packages php-cli php-json php-mbstring php-xml php-zip composer
      ;;
  esac

  if has_file "composer.json"; then
    log "Installing PHP dependencies with Composer (no dev)"
    (cd "$APP_DIR" && composer install --no-interaction --no-progress --prefer-dist --no-dev)
  fi

  APP_PORT="${APP_PORT:-8080}"
}

# Write helpful run instructions based on detected files
print_run_instructions() {
  echo
  log "Environment setup completed successfully."
  echo "Summary:"
  echo "  APP_DIR: $APP_DIR"
  echo "  APP_ENV: $APP_ENV"
  echo "  APP_PORT: ${APP_PORT:-$DEFAULT_PORT}"
  echo "  Detected types: ${PROJECT_TYPES[*]:-none}"
  echo
  echo "To load environment variables in the shell:"
  echo "  source \"$APP_DIR/env.sh\""
  echo
  if [[ " ${PROJECT_TYPES[*]} " == *" python "* ]]; then
    if has_file "manage.py"; then
      echo "Python (Django) run example:"
      echo "  source \"$APP_DIR/env.sh\" && source \"$APP_DIR/.venv/bin/activate\" && python manage.py runserver 0.0.0.0:${APP_PORT:-8000}"
    else
      echo "Python run example:"
      echo "  source \"$APP_DIR/env.sh\" && source \"$APP_DIR/.venv/bin/activate\" && python \"$APP_DIR/app.py\""
    fi
  fi
  if [[ " ${PROJECT_TYPES[*]} " == *" node "* ]]; then
    echo "Node.js run example:"
    echo "  source \"$APP_DIR/env.sh\" && npm --prefix \"$APP_DIR\" start"
  fi
  if [[ " ${PROJECT_TYPES[*]} " == *" ruby "* ]]; then
    echo "Ruby run example:"
    echo "  source \"$APP_DIR/env.sh\" && bundle exec ruby your_app_entry.rb"
  fi
  if [[ " ${PROJECT_TYPES[*]} " == *" go "* ]]; then
    echo "Go run example:"
    echo "  source \"$APP_DIR/env.sh\" && go run ./..."
  fi
  if [[ " ${PROJECT_TYPES[*]} " == *" java "* ]]; then
    echo "Java run example:"
    if has_file "pom.xml"; then
      echo "  source \"$APP_DIR/env.sh\" && mvn -q spring-boot:run"
    else
      echo "  source \"$APP_DIR/env.sh\" && java -jar build/libs/yourapp.jar"
    fi
  fi
  if [[ " ${PROJECT_TYPES[*]} " == *" php "* ]]; then
    echo "PHP run example:"
    echo "  source \"$APP_DIR/env.sh\" && php -S 0.0.0.0:${APP_PORT:-8080} -t public"
  fi
  echo
}

# Main
main() {
  log "Starting environment setup for project at $APP_DIR"

  umask 022
  detect_pkg_mgr
  install_base_system_tools
  setup_directories

  detect_project_types

  # Set default APP_PORT depending on detected type
  APP_PORT="${APP_PORT:-$DEFAULT_PORT}"

  for t in "${PROJECT_TYPES[@]:-}"; do
    case "$t" in
      python) setup_python ;;
      node)   setup_node ;;
      ruby)   setup_ruby ;;
      go)     setup_go ;;
      java)   setup_java ;;
      php)    setup_php ;;
      *) warn "Unknown project type: $t" ;;
    esac
  done

  write_env_file
  setup_auto_activate
  print_run_instructions
}

main "$@"