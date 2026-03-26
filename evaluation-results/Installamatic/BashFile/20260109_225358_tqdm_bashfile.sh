#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type and installs required runtimes and system packages
# - Sets up dependencies and environment variables
# - Safe to run multiple times (idempotent)
# - Designed to run as root inside Docker, but works best-effort as non-root

set -Eeuo pipefail

#-------------------------
# Configuration defaults
#-------------------------
PROJECT_DIR="${PROJECT_DIR:-/app}"
APP_USER="${APP_USER:-root}"
APP_GROUP="${APP_GROUP:-root}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-}"  # Will be detected if empty
UMASK_VALUE="${UMASK_VALUE:-027}"  # Restrictive default permissions
PYTHON_VENV_DIR="${PYTHON_VENV_DIR:-$PROJECT_DIR/.venv}"
GOPATH_DIR="${GOPATH_DIR:-$PROJECT_DIR/.go}"
PROFILED_DIR="/etc/profile.d"
ENV_FILE="$PROJECT_DIR/.env"

#-------------------------
# Logging and traps
#-------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info()   { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}"; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

cleanup() { :; }
trap cleanup EXIT
trap 'error "An error occurred on line $LINENO. Aborting."; exit 1' ERR

umask "$UMASK_VALUE"

#-------------------------
# Helpers
#-------------------------
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

has_file() { [ -f "$PROJECT_DIR/$1" ]; }

ensure_dir() {
  local d="$1" mode="${2:-0755}"
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
  fi
  chmod "$mode" "$d" || true
}

append_unique_line() {
  # $1=file, $2=line
  local f="$1" line="$2"
  touch "$f"
  grep -qxF "$line" "$f" || echo "$line" >> "$f"
}

#-------------------------
# Package manager detection and install
#-------------------------
PKG_MGR=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
BUILD_PKGS=()
COMMON_PKGS=()
PYTHON_PKGS=()
NODE_PKGS=()
RUBY_PKGS=()
PHP_PKGS=()
JAVA_PKGS=()
GO_PKGS=()

detect_pkg_manager() {
  if has_cmd apt-get; then
    PKG_MGR="apt"
    PKG_UPDATE="apt-get update -y -qq"
    PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
    BUILD_PKGS=(build-essential gcc g++ make pkg-config)
    COMMON_PKGS=(ca-certificates curl git openssl tar unzip xz-utils bash coreutils sed gawk findutils)
    PYTHON_PKGS=(python3 python3-pip python3-venv python3-dev)
    NODE_PKGS=(nodejs npm)
    RUBY_PKGS=(ruby-full)
    PHP_PKGS=(php-cli php-mbstring php-xml)
    JAVA_PKGS=(default-jdk maven)
    GO_PKGS=(golang)
  elif has_cmd apk; then
    PKG_MGR="apk"
    PKG_UPDATE="apk update -q"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="rm -rf /var/cache/apk/*"
    BUILD_PKGS=(build-base pkgconfig)
    COMMON_PKGS=(ca-certificates curl git openssl tar unzip xz bash coreutils sed gawk findutils)
    PYTHON_PKGS=(python3 py3-pip py3-virtualenv python3-dev)
    NODE_PKGS=(nodejs npm)
    RUBY_PKGS=(ruby ruby-dev)
    PHP_PKGS=(php81-cli php81-mbstring php81-xml) # version may vary
    JAVA_PKGS=(openjdk11-jdk maven)
    GO_PKGS=(go)
  elif has_cmd dnf; then
    PKG_MGR="dnf"
    PKG_UPDATE="dnf -y -q makecache"
    PKG_INSTALL="dnf install -y -q"
    PKG_CLEAN="dnf clean all"
    BUILD_PKGS=(gcc gcc-c++ make pkgconf-pkg-config)
    COMMON_PKGS=(ca-certificates curl git openssl tar unzip xz bash coreutils sed gawk findutils)
    PYTHON_PKGS=(python3 python3-pip python3-devel)
    NODE_PKGS=(nodejs npm)
    RUBY_PKGS=(ruby ruby-devel)
    PHP_PKGS=(php-cli php-mbstring php-xml)
    JAVA_PKGS=(java-11-openjdk maven)
    GO_PKGS=(golang)
  elif has_cmd yum; then
    PKG_MGR="yum"
    PKG_UPDATE="yum -y -q makecache"
    PKG_INSTALL="yum install -y -q"
    PKG_CLEAN="yum clean all"
    BUILD_PKGS=(gcc gcc-c++ make pkgconfig)
    COMMON_PKGS=(ca-certificates curl git openssl tar unzip xz bash coreutils sed gawk findutils)
    PYTHON_PKGS=(python3 python3-pip python3-devel)
    NODE_PKGS=(nodejs npm)
    RUBY_PKGS=(ruby ruby-devel)
    PHP_PKGS=(php-cli php-mbstring php-xml)
    JAVA_PKGS=(java-11-openjdk maven)
    GO_PKGS=(golang)
  else
    PKG_MGR="none"
  fi
}

pm_update() { [ "$PKG_MGR" != "none" ] && eval "$PKG_UPDATE" || true; }
pm_clean()  { [ "$PKG_MGR" != "none" ] && eval "$PKG_CLEAN" || true; }
pm_install() {
  # Arguments are packages to install if missing
  [ "$PKG_MGR" = "none" ] && { warn "No supported package manager detected. Skipping system package installation."; return 0; }
  local to_install=()
  for pkg in "$@"; do
    # Best-effort: attempt to install blindly (checking every pkg name across distros is complex)
    to_install+=("$pkg")
  done
  if [ "${#to_install[@]}" -gt 0 ]; then
    pm_update
    set +e
    # Try install; if a specific package name is invalid for the distro, the install may fail.
    # We handle this by attempting grouped installs and ignoring not-found where feasible.
    if ! eval "$PKG_INSTALL ${to_install[*]}"; then
      warn "Some packages failed to install: ${to_install[*]}. Continuing best-effort."
    fi
    set -e
    pm_clean
  fi
}

require_root_or_warn() {
  if ! is_root; then
    warn "Not running as root. System package installation will be skipped or may fail. Consider running container as root for full setup."
  fi
}

#-------------------------
# Environment persistence
#-------------------------
write_env_exports() {
  # Persist env for interactive shells
  local kv
  local env_script="${PROFILED_DIR}/project_env.sh"
  if is_root && [ -d "$PROFILED_DIR" ]; then
    {
      echo "#!/usr/bin/env bash"
      echo "export PROJECT_DIR=\"$PROJECT_DIR\""
      echo "export APP_ENV=\"$APP_ENV\""
      [ -n "${APP_PORT:-}" ] && echo "export APP_PORT=\"$APP_PORT\""
      echo "export PATH=\"$PROJECT_DIR/bin:\$PATH\""
      [ -d "$PYTHON_VENV_DIR/bin" ] && echo "export PATH=\"$PYTHON_VENV_DIR/bin:\$PATH\""
      [ -d "$GOPATH_DIR/bin" ] && echo "export GOPATH=\"$GOPATH_DIR\"; export PATH=\"\$GOPATH/bin:\$PATH\""
      echo "export PYTHONUNBUFFERED=1"
      echo "export PIP_NO_CACHE_DIR=1"
      echo "export NODE_ENV=\"${NODE_ENV:-${APP_ENV}}\""
    } > "$env_script"
    chmod 0644 "$env_script"
  fi

  # Also write a .env file for app use if missing or to update core entries
  touch "$ENV_FILE"
  append_unique_line "$ENV_FILE" "PROJECT_DIR=$PROJECT_DIR"
  append_unique_line "$ENV_FILE" "APP_ENV=$APP_ENV"
  [ -n "${APP_PORT:-}" ] && append_unique_line "$ENV_FILE" "APP_PORT=$APP_PORT"
}

#-------------------------
# Project detection
#-------------------------
detect_project_type() {
  local types=()
  if has_file "package.json"; then types+=("node"); fi
  if has_file "requirements.txt" || has_file "Pipfile" || has_file "pyproject.toml" || ls "$PROJECT_DIR"/*.py >/dev/null 2>&1; then types+=("python"); fi
  if has_file "Gemfile"; then types+=("ruby"); fi
  if has_file "composer.json"; then types+=("php"); fi
  if has_file "go.mod"; then types+=("go"); fi
  if has_file "pom.xml"; then types+=("java-maven"); fi
  if ls "$PROJECT_DIR"/*.gradle >/dev/null 2>&1 || [ -d "$PROJECT_DIR/gradle" ]; then types+=("java-gradle"); fi
  echo "${types[*]:-}"
}

detect_port() {
  # Heuristics: override via APP_PORT env if already set
  if [ -n "${APP_PORT:-}" ]; then
    echo "$APP_PORT"
    return
  fi
  # Simple detection by framework files
  if has_file "package.json"; then
    # Common Node defaults
    echo "3000"
    return
  fi
  if has_file "manage.py" || grep -qi "django" "$PROJECT_DIR/requirements.txt" 2>/dev/null; then
    echo "8000"; return
  fi
  if has_file "app.py" || grep -qi "flask" "$PROJECT_DIR/requirements.txt" 2>/dev/null; then
    echo "5000"; return
  fi
  if has_file "composer.json"; then
    echo "8080"; return
  fi
  # Default fallback
  echo "8080"
}

#-------------------------
# Stack setup functions
#-------------------------
setup_common() {
  info "Setting up common environment..."
  ensure_dir "$PROJECT_DIR" 0755
  ensure_dir "$PROJECT_DIR/logs" 0755
  ensure_dir "$PROJECT_DIR/tmp" 0775
  ensure_dir "$PROJECT_DIR/bin" 0755

  if is_root; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR" || true
  fi

  # Install baseline tools
  require_root_or_warn
  if is_root; then
    detect_pkg_manager
    if [ "$PKG_MGR" != "none" ]; then
      pm_install "${COMMON_PKGS[@]}"
    else
      warn "Skipping system tool installation: no supported package manager found."
    fi

    # Update CA certificates if present (important for HTTPS installs)
    if has_cmd update-ca-certificates; then update-ca-certificates || true; fi
  fi

  # Add bin dir to PATH in current shell session
  export PATH="$PROJECT_DIR/bin:$PATH"
}

setup_python() {
  info "Detected Python project. Preparing environment..."
  detect_pkg_manager
  if is_root && [ "$PKG_MGR" != "none" ]; then
    pm_install "${BUILD_PKGS[@]}" "${PYTHON_PKGS[@]}"
  fi

  # Prefer system python3; Alpine might use python3
  local py="python3"
  if ! has_cmd "$py"; then
    warn "python3 not found. Skipping Python setup."
    return
  fi

  # Create venv if not exists
  if [ ! -d "$PYTHON_VENV_DIR" ]; then
    "$py" -m venv "$PYTHON_VENV_DIR"
  fi

  # Activate venv in this shell
  # shellcheck source=/dev/null
  source "$PYTHON_VENV_DIR/bin/activate"

  # Upgrade baseline packaging tools
  pip install --no-cache-dir --upgrade pip setuptools wheel

  # Install dependencies (pyproject or requirements or Pipfile)
  if has_file "pyproject.toml"; then
    # Try pip to install the project and dependencies; if poetry is required, try to use it.
    if grep -qi '\[build-system\]' "$PROJECT_DIR/pyproject.toml" 2>/dev/null; then
      # Attempt to detect poetry usage
      if grep -qi 'tool.poetry' "$PROJECT_DIR/pyproject.toml" 2>/dev/null; then
        if ! has_cmd poetry; then
          pip install --no-cache-dir "poetry>=1.5"
        fi
        if [ "${APP_ENV}" = "production" ]; then
          poetry install --no-root --no-interaction --no-ansi --only main
        else
          poetry install --no-interaction --no-ansi
        fi
      else
        # PEP 517 build
        pip install --no-cache-dir .
      fi
    else
      pip install --no-cache-dir -r "$PROJECT_DIR/requirements.txt" 2>/dev/null || true
    fi
  elif has_file "requirements.txt"; then
    pip install --no-cache-dir -r "$PROJECT_DIR/requirements.txt"
  elif has_file "Pipfile"; then
    pip install --no-cache-dir pipenv
    if [ "${APP_ENV}" = "production" ]; then
      PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system
    else
      PIPENV_VENV_IN_PROJECT=1 pipenv install --system
    fi
  else
    info "No Python dependency file found. Skipping Python dependency installation."
  fi

  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1

  # Deactivate venv at end of function to avoid polluting other stack setups
  deactivate || true
}

setup_node() {
  info "Detected Node.js project. Preparing environment..."
  detect_pkg_manager
  if is_root && [ "$PKG_MGR" != "none" ]; then
    pm_install "${BUILD_PKGS[@]}" "${NODE_PKGS[@]}"
  fi

  if ! has_cmd node; then
    warn "Node.js not available from system packages. Attempting to proceed with npm install may fail."
  fi

  export NODE_ENV="${NODE_ENV:-$APP_ENV}"

  # Use npm/yarn/pnpm depending on lock files, favoring deterministic installs
  if has_file "package.json"; then
    pushd "$PROJECT_DIR" >/dev/null
    if has_file "package-lock.json"; then
      if has_cmd npm; then npm ci --no-audit --no-fund || npm install --no-audit --no-fund; fi
    elif has_file "yarn.lock"; then
      if has_cmd corepack; then corepack enable || true; fi
      if ! has_cmd yarn; then
        if has_cmd corepack; then corepack prepare yarn@stable --activate || true; fi
      fi
      if has_cmd yarn; then yarn install --frozen-lockfile || yarn install; fi
    elif has_file "pnpm-lock.yaml"; then
      if has_cmd corepack; then corepack enable || true; fi
      if ! has_cmd pnpm; then
        if has_cmd corepack; then corepack prepare pnpm@latest --activate || true; else npm i -g pnpm || true; fi
      fi
      if has_cmd pnpm; then pnpm install --frozen-lockfile || pnpm install; fi
    else
      if has_cmd npm; then npm install --no-audit --no-fund; fi
    fi
    popd >/dev/null
  fi
}

setup_ruby() {
  info "Detected Ruby project. Preparing environment..."
  detect_pkg_manager
  if is_root && [ "$PKG_MGR" != "none" ]; then
    pm_install "${BUILD_PKGS[@]}" "${RUBY_PKGS[@]}"
  fi

  if ! has_cmd ruby; then
    warn "Ruby not found. Skipping Ruby dependency installation."
    return
  fi

  if ! has_cmd bundle; then
    gem install bundler --no-document || true
  fi

  pushd "$PROJECT_DIR" >/dev/null
  bundle config set --local path "vendor/bundle"
  if [ "${APP_ENV}" = "production" ]; then
    bundle install --without development test --jobs=4 --retry=3
  else
    bundle install --jobs=4 --retry=3
  fi
  popd >/dev/null
}

setup_php() {
  info "Detected PHP project. Preparing environment..."
  detect_pkg_manager
  if is_root && [ "$PKG_MGR" != "none" ]; then
    pm_install "${PHP_PKGS[@]}" curl git ca-certificates
  fi

  if ! has_cmd php; then
    warn "PHP not found. Skipping PHP dependency installation."
    return
  fi

  if ! has_cmd composer; then
    info "Installing Composer locally..."
    # Install composer to /usr/local/bin if root, else to project bin
    local composer_target="/usr/local/bin/composer"
    if ! is_root; then composer_target="$PROJECT_DIR/bin/composer"; fi
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir="$(dirname "$composer_target")" --filename="$(basename "$composer_target")"
    rm -f composer-setup.php
    chmod +x "$composer_target" || true
    export PATH="$PROJECT_DIR/bin:$PATH"
  fi

  pushd "$PROJECT_DIR" >/dev/null
  if [ "${APP_ENV}" = "production" ]; then
    composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader || true
  else
    composer install --no-interaction --prefer-dist || true
  fi
  popd >/dev/null
}

setup_go() {
  info "Detected Go project. Preparing environment..."
  detect_pkg_manager
  if is_root && [ "$PKG_MGR" != "none" ]; then
    pm_install "${GO_PKGS[@]}"
  fi

  if ! has_cmd go; then
    warn "Go not found. Skipping Go setup."
    return
  fi

  ensure_dir "$GOPATH_DIR" 0755
  export GOPATH="$GOPATH_DIR"
  export PATH="$GOPATH/bin:$PATH"

  pushd "$PROJECT_DIR" >/dev/null
  go mod download || true
  popd >/dev/null
}

setup_java_maven() {
  info "Detected Java (Maven) project. Preparing environment..."
  detect_pkg_manager
  if is_root && [ "$PKG_MGR" != "none" ]; then
    pm_install "${JAVA_PKGS[@]}"
  fi

  if ! has_cmd mvn; then
    warn "Maven not found. Skipping Maven setup."
    return
  fi

  pushd "$PROJECT_DIR" >/dev/null
  mvn -B -q -DskipTests dependency:go-offline || true
  popd >/dev/null
}

setup_java_gradle() {
  info "Detected Java (Gradle) project. Preparing environment..."
  detect_pkg_manager
  if is_root && [ "$PKG_MGR" != "none" ]; then
    pm_install "${JAVA_PKGS[@]}"
  fi

  if ! has_cmd gradle; then
    warn "Gradle not found. If using gradle wrapper, it will download Gradle."
  fi

  pushd "$PROJECT_DIR" >/dev/null
  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
  else
    gradle --no-daemon tasks >/dev/null 2>&1 || true
  fi
  popd >/dev/null
}

#-------------------------
# Main
#-------------------------
main() {
  log "Starting universal environment setup..."
  log "Project directory: $PROJECT_DIR"
  ensure_dir "$PROJECT_DIR"

  # Move to project directory
  cd "$PROJECT_DIR"

  setup_common

  # Detect project types and run appropriate setup
  local types
  types="$(detect_project_type)"
  if [ -z "$types" ]; then
    warn "No specific project type detected. Installing only common tools."
  else
    info "Detected project types: $types"
  fi

  # Run setups conditionally
  case " $types " in
    *" python "*) setup_python ;;
  esac
  case " $types " in
    *" node "*) setup_node ;;
  esac
  case " $types " in
    *" ruby "*) setup_ruby ;;
  esac
  case " $types " in
    *" php "*) setup_php ;;
  esac
  case " $types " in
    *" go "*) setup_go ;;
  esac
  case " $types " in
    *" java-maven "*) setup_java_maven ;;
  esac
  case " $types " in
    *" java-gradle "*) setup_java_gradle ;;
  esac

  # Detect and set port if not provided
  APP_PORT="$(detect_port)"
  info "Using application port: $APP_PORT"

  # Persist environment exports
  write_env_exports

  # Final permissions
  if is_root; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR" || true
    find "$PROJECT_DIR/bin" -type f -maxdepth 1 -exec chmod +x {} \; 2>/dev/null || true
  fi

  log "Environment setup completed successfully."
  info "Summary:"
  info "- PROJECT_DIR: $PROJECT_DIR"
  info "- APP_ENV: $APP_ENV"
  info "- APP_PORT: $APP_PORT"
  info "- Node: $(node -v 2>/dev/null || echo 'not installed')"
  info "- Python: $(python3 -V 2>/dev/null || echo 'not installed'); venv: $PYTHON_VENV_DIR"
  info "- Ruby: $(ruby -v 2>/dev/null || echo 'not installed')"
  info "- PHP: $(php -v 2>/dev/null | head -n1 || echo 'not installed')"
  info "- Go: $(go version 2>/dev/null || echo 'not installed')"
  info "- Java: $(java -version 2>&1 | head -n1 || echo 'not installed')"

  info "To load environment automatically in new shells, the script created:"
  if is_root && [ -f "$PROFILED_DIR/project_env.sh" ]; then
    info " - $PROFILED_DIR/project_env.sh"
  else
    info " - $ENV_FILE (application .env)"
  fi
}

main "$@"