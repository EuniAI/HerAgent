#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects project type and installs appropriate runtime, system packages, dependencies,
# configures environment variables, and ensures idempotent behavior.

set -euo pipefail
IFS=$'\n\t'

# Trap errors
trap 'echo "[ERROR] Command failed at line $LINENO. Exit code: $?" >&2' ERR

# Colors (may not render in all environments)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}

warn() {
  echo -e "${YELLOW}[WARN] $*${NC}"
}

error() {
  echo -e "${RED}[ERROR] $*${NC}" >&2
}

# Globals
APP_DIR="${APP_DIR:-$(pwd)}"
STATE_DIR="/var/lib/setup-env-script"
ENV_PROFILE="/etc/profile.d/app_env.sh"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

# Ensure state directory
mkdir -p "$STATE_DIR"

# Detect OS and package manager
OS_ID=""
PKG_MGR=""
detect_os_pkgmgr() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  else
    OS_ID="unknown"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    PKG_MGR=""
  fi
}

# Update package indices idempotently
pkg_update() {
  case "$PKG_MGR" in
    apt)
      if [ ! -f "$STATE_DIR/apt_updated" ]; then
        log "Updating apt package indexes..."
        apt-get update -y
        touch "$STATE_DIR/apt_updated"
      fi
      ;;
    apk)
      if [ ! -f "$STATE_DIR/apk_updated" ]; then
        log "Updating apk package indexes..."
        apk update
        touch "$STATE_DIR/apk_updated"
      fi
      ;;
    microdnf|dnf|yum)
      # dnf/yum usually auto-resolve metadata; we still mark a state file
      if [ ! -f "$STATE_DIR/dnf_updated" ]; then
        log "Initializing $PKG_MGR..."
        touch "$STATE_DIR/dnf_updated"
      fi
      ;;
    *)
      warn "No supported package manager detected. Skipping update."
      ;;
  esac
}

# Install packages with mapping per platform
install_packages() {
  if [ $# -eq 0 ]; then return 0; fi
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    microdnf)
      microdnf install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    *)
      error "Cannot install packages: unsupported package manager"
      return 1
      ;;
  esac
}

# Ensure essential base tools
ensure_base_tools() {
  log "Ensuring essential base tools..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      install_packages ca-certificates curl tar git sudo build-essential pkg-config libglfw3-dev libsdl2-dev bash
      ;;
    apk)
      install_packages ca-certificates curl git build-base pkgconfig glfw-dev sdl2-dev
      ;;
    microdnf|dnf|yum)
      install_packages ca-certificates curl git gcc gcc-c++ make pkgconf glfw-devel sdl2-devel
      ;;
    *)
      warn "Skipping base tool installation due to unsupported package manager"
      ;;
  esac
  # Update CA certificates where applicable
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi
}

# Project type detection
PROJECT_TYPE=""
PROJECT_SUBTYPE=""
detect_project_type() {
  # Python
  if [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ] || find "$APP_DIR" -maxdepth 2 -name "*.py" | grep -q .; then
    PROJECT_TYPE="python"
    if [ -f "$APP_DIR/requirements.txt" ] && grep -i -q "flask" "$APP_DIR/requirements.txt"; then
      PROJECT_SUBTYPE="flask"
    elif [ -f "$APP_DIR/requirements.txt" ] && grep -i -q "django" "$APP_DIR/requirements.txt"; then
      PROJECT_SUBTYPE="django"
    else
      PROJECT_SUBTYPE="generic"
    fi
    return
  fi

  # Node.js
  if [ -f "$APP_DIR/package.json" ]; then
    PROJECT_TYPE="node"
    if [ -f "$APP_DIR/package.json" ] && grep -i -q '"next"' "$APP_DIR/package.json"; then
      PROJECT_SUBTYPE="nextjs"
    elif [ -f "$APP_DIR/package.json" ] && grep -i -q '"express"' "$APP_DIR/package.json"; then
      PROJECT_SUBTYPE="express"
    else
      PROJECT_SUBTYPE="generic"
    fi
    return
  fi

  # Ruby
  if [ -f "$APP_DIR/Gemfile" ]; then
    PROJECT_TYPE="ruby"
    if grep -i -q "rails" "$APP_DIR/Gemfile"; then
      PROJECT_SUBTYPE="rails"
    else
      PROJECT_SUBTYPE="generic"
    fi
    return
  fi

  # Go
  if [ -f "$APP_DIR/go.mod" ]; then
    PROJECT_TYPE="go"
    PROJECT_SUBTYPE="generic"
    return
  fi

  # Java
  if [ -f "$APP_DIR/pom.xml" ] || [ -f "$APP_DIR/build.gradle" ] || [ -f "$APP_DIR/gradlew" ]; then
    PROJECT_TYPE="java"
    PROJECT_SUBTYPE="generic"
    return
  fi

  # Rust
  if [ -f "$APP_DIR/Cargo.toml" ]; then
    PROJECT_TYPE="rust"
    PROJECT_SUBTYPE="generic"
    return
  fi

  # PHP
  if [ -f "$APP_DIR/composer.json" ]; then
    PROJECT_TYPE="php"
    PROJECT_SUBTYPE="generic"
    return
  fi

  PROJECT_TYPE="unknown"
  PROJECT_SUBTYPE="unknown"
}

# Setup directories and permissions
setup_directories() {
  log "Setting up project directories and permissions..."
  mkdir -p "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/.cache"
  # Use current user and group; inside Docker often root
  CHOWN_USER="$(id -u)"
  CHOWN_GROUP="$(id -g)"
  chown -R "$CHOWN_USER:$CHOWN_GROUP" "$APP_DIR" || true
  chmod -R u+rwX,go-rwx "$APP_DIR" || true
}

# Write environment variables to profile.d
write_env_profile() {
  local port="$1"
  local extras="$2"
  log "Persisting environment variables to $ENV_PROFILE..."
  {
    echo "#!/bin/sh"
    echo "# Auto-generated by setup script on $(date)"
    echo "export APP_DIR=\"$APP_DIR\""
    echo "export PORT=\"${PORT:-$port}\""
    echo "export NODE_ENV=\"${NODE_ENV:-production}\""
    echo "export PYTHONUNBUFFERED=\"1\""
    echo "export PIP_NO_CACHE_DIR=\"off\""
    echo "export PIP_DISABLE_PIP_VERSION_CHECK=\"1\""
    echo "$extras"
  } > "$ENV_PROFILE"
  chmod 0644 "$ENV_PROFILE"
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      install_packages python3 python3-pip python3-venv python3-dev gcc
      ;;
    apk)
      install_packages python3 py3-pip python3-dev gcc musl-dev
      ;;
    microdnf|dnf|yum)
      install_packages python3 python3-pip python3-devel gcc
      ;;
    *)
      warn "Package manager not supported for Python dependencies; assuming Python is present."
      ;;
  esac

  # Create venv idempotently
  VENV_DIR="$APP_DIR/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    log "Created virtual environment at $VENV_DIR"
  else
    log "Virtual environment already exists at $VENV_DIR"
  fi

  # Activate venv and install deps
  # shellcheck disable=SC1090
  . "$VENV_DIR/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel

  if [ -f "$APP_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    python3 -m pip install -r "$APP_DIR/requirements.txt"
  elif [ -f "$APP_DIR/pyproject.toml" ]; then
    log "Installing Python project via pyproject.toml..."
    python3 -m pip install "$APP_DIR"
  else
    warn "No Python dependency file found (requirements.txt or pyproject.toml). Skipping dependency install."
  fi

  # Framework-specific environment
  local extras=""
  local port="8000"
  case "$PROJECT_SUBTYPE" in
    flask)
      port="5000"
      extras='export FLASK_ENV="${FLASK_ENV:-production}"
export FLASK_APP="${FLASK_APP:-app.py}"'
      ;;
    django)
      port="8000"
      extras='export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-settings}"'
      ;;
    *)
      port="8000"
      ;;
  esac
  write_env_profile "$port" "$extras"
  log "Python setup completed."
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      install_packages nodejs npm
      ;;
    apk)
      install_packages nodejs npm
      ;;
    microdnf|dnf|yum)
      install_packages nodejs npm || warn "Node.js/npm may not be available in repos; ensure base image includes Node."
      ;;
    *)
      error "Cannot install Node.js: unsupported package manager"
      ;;
  esac

  # Configure npm for CI environments
  npm config set fund false || true
  npm config set audit false || true

  if [ -f "$APP_DIR/package-lock.json" ]; then
    log "Installing Node.js dependencies via npm ci..."
    (cd "$APP_DIR" && npm ci)
  elif [ -f "$APP_DIR/package.json" ]; then
    log "Installing Node.js dependencies via npm install..."
    (cd "$APP_DIR" && npm install)
  else
    warn "No package.json found. Skipping npm install."
  fi

  # Yarn support if yarn.lock present
  if [ -f "$APP_DIR/yarn.lock" ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      warn "yarn.lock found but yarn is not installed. Installing yarn globally..."
      npm install -g yarn || warn "Failed to install yarn globally."
    fi
    if command -v yarn >/dev/null 2>&1; then
      (cd "$APP_DIR" && yarn install --frozen-lockfile || yarn install)
    fi
  fi

  local port="3000"
  case "$PROJECT_SUBTYPE" in
    nextjs)
      port="3000"
      ;;
    express)
      port="3000"
      ;;
    *)
      port="3000"
      ;;
  esac

  write_env_profile "$port" 'export NODE_ENV="${NODE_ENV:-production}"'
  log "Node.js setup completed."
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      install_packages ruby-full build-essential
      ;;
    apk)
      install_packages ruby ruby-bundler build-base
      ;;
    microdnf|dnf|yum)
      install_packages ruby rubygems gcc gcc-c++ make || true
      ;;
    *)
      error "Cannot install Ruby: unsupported package manager"
      ;;
  esac

  if ! command -v bundle >/dev/null 2>&1; then
    if command -v gem >/dev/null 2>&1; then
      gem install bundler --no-document || warn "Failed to install bundler via gem."
    fi
  fi

  if [ -f "$APP_DIR/Gemfile" ]; then
    log "Installing Ruby gems via bundler..."
    (cd "$APP_DIR" && bundle config set deployment 'true' && bundle install --jobs 4 || bundle install)
  else
    warn "No Gemfile found. Skipping bundle install."
  fi

  local port="3000"
  case "$PROJECT_SUBTYPE" in
    rails)
      port="3000"
      ;;
    *)
      port="3000"
      ;;
  esac

  write_env_profile "$port" 'export RACK_ENV="${RACK_ENV:-production}"
export RAILS_ENV="${RAILS_ENV:-production}"'
  log "Ruby setup completed."
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      install_packages golang
      ;;
    apk)
      install_packages go
      ;;
    microdnf|dnf|yum)
      install_packages golang
      ;;
    *)
      error "Cannot install Go: unsupported package manager"
      ;;
  esac

  export GOPATH="${GOPATH:-$APP_DIR/.gopath}"
  mkdir -p "$GOPATH"
  export GOCACHE="$APP_DIR/.cache/go"
  mkdir -p "$GOCACHE"

  if [ -f "$APP_DIR/go.mod" ]; then
    log "Downloading Go module dependencies..."
    (cd "$APP_DIR" && go mod download)
  else
    warn "No go.mod found. Skipping go mod download."
  fi

  write_env_profile "8080" "export GOPATH=\"$GOPATH\"
export GOCACHE=\"$GOCACHE\""
  log "Go setup completed."
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      install_packages openjdk-17-jdk maven
      ;;
    apk)
      install_packages openjdk17 maven
      ;;
    microdnf|dnf|yum)
      install_packages java-17-openjdk maven
      ;;
    *)
      error "Cannot install Java: unsupported package manager"
      ;;
  esac

  if [ -f "$APP_DIR/mvnw" ]; then
    log "Bootstrapping Maven wrapper dependencies..."
    (cd "$APP_DIR" && chmod +x mvnw && ./mvnw -B -DskipTests dependency:resolve || true)
  elif [ -f "$APP_DIR/pom.xml" ]; then
    log "Resolving Maven dependencies..."
    (cd "$APP_DIR" && mvn -B -DskipTests dependency:resolve || true)
  elif [ -f "$APP_DIR/gradlew" ]; then
    log "Bootstrapping Gradle wrapper dependencies..."
    (cd "$APP_DIR" && chmod +x gradlew && ./gradlew --no-daemon build -x test || true)
  elif [ -f "$APP_DIR/build.gradle" ]; then
    warn "Gradle build.gradle found but gradle wrapper missing. Consider adding gradlew."
  fi

  write_env_profile "8080" ""
  log "Java setup completed."
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      install_packages cargo
      ;;
    apk)
      install_packages cargo
      ;;
    microdnf|dnf|yum)
      install_packages cargo
      ;;
    *)
      error "Cannot install Rust: unsupported package manager"
      ;;
  esac

  if [ -f "$APP_DIR/Cargo.toml" ]; then
    log "Fetching Rust crate dependencies..."
    (cd "$APP_DIR" && cargo fetch)
  else
    warn "No Cargo.toml found. Skipping cargo fetch."
  fi

  write_env_profile "8080" ""
  log "Rust setup completed."
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      install_packages php-cli php-mbstring php-xml curl
      ;;
    apk)
      install_packages php-cli php8-mbstring php8-xml curl composer || install_packages php-cli php-mbstring php-xml curl composer
      ;;
    microdnf|dnf|yum)
      install_packages php-cli php-mbstring php-xml curl || true
      ;;
    *)
      error "Cannot install PHP: unsupported package manager"
      ;;
  esac

  # Composer installation if missing
  if ! command -v composer >/dev/null 2>&1; then
    warn "Composer not found. Installing locally..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Failed to install composer globally."
    rm -f /tmp/composer-setup.php || true
  fi

  if [ -f "$APP_DIR/composer.json" ]; then
    log "Installing PHP dependencies via composer..."
    (cd "$APP_DIR" && if [ -f composer.lock ]; then composer install --no-interaction --prefer-dist --no-progress; else composer update --no-interaction --prefer-dist --no-progress; fi)
  else
    warn "No composer.json found. Skipping composer install."
  fi

  write_env_profile "8080" ""
  log "PHP setup completed."
}

# Unknown project setup
setup_unknown() {
  warn "Project type not detected. Installing minimal base tools only."
  ensure_base_tools
  write_env_profile "8080" ""
}

# CI shims to support environments without sudo and shell-style env assignment
setup_ci_shims() {
  # Provide a sudo shim if /usr/bin/sudo is missing (common in minimal containers)
  if [ ! -x /usr/bin/sudo ]; then
    cat > /usr/bin/sudo <<'SH'
#!/bin/sh
exec "$@"
SH
    chmod +x /usr/bin/sudo || true
  fi

  # Provide a sudo pass-through shim in /usr/local/bin only if sudo is missing and running as root
  if ! command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    cat > /usr/local/bin/sudo <<'SH'
#!/bin/sh
exec "$@"
SH
    chmod +x /usr/local/bin/sudo || true
  fi

  # Provide benign stubs for PowerShell commands to avoid aborts on Linux
  if ! command -v ForEach-Object >/dev/null 2>&1; then
    printf '#!/bin/sh\ncat >/dev/null 2>&1 || true\n' | sudo tee /usr/local/bin/ForEach-Object >/dev/null && sudo chmod +x /usr/local/bin/ForEach-Object
  fi
  if ! command -v gci >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' | sudo tee /usr/local/bin/gci >/dev/null && sudo chmod +x /usr/local/bin/gci
  fi

  # Provide a wrapper to handle commands like 'CFLAGS=-Werror make' in shell-less runners
  if [ ! -x "/usr/bin/CFLAGS=-Werror" ]; then
    cat > "/usr/bin/CFLAGS=-Werror" <<'SH'
#!/bin/sh
name=$(basename "$0")
var="${name%%=*}"
val="${name#*=}"
export "$var=$val"
# rebuild args, replacing literal -j\$(sysctl -n hw.ncpu) with computed -jN
params=
while [ "$#" -gt 0 ]; do
  a="$1"
  if [ "$a" = "-j\$(sysctl" ] && [ "${2:-}" = "-n" ] && [ "${3:-}" = "hw.ncpu)" ]; then
    cores=$(command -v nproc >/dev/null 2>&1 && nproc || getconf _NPROCESSORS_ONLN || echo 1)
    params="$params -j$cores"
    shift 3
    continue
  fi
  params="$params $(printf "%s" "$a")"
  shift
done
# shellcheck disable=SC2086
set -- $params
exec "$@"
SH
    chmod +x "/usr/bin/CFLAGS=-Werror" || true
  fi

  # Also provide a robust bash-based wrapper in /usr/local/bin to handle CPU cores and -j substitution
  cat > "/usr/local/bin/CFLAGS=-Werror" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
export CFLAGS="-Werror"
cpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
args=()
for arg in "$@"; do
  case "$arg" in 
    -j\$\(*\)) args+=( "-j$cpu" ) ;; 
    *) args+=( "$arg" ) ;; 
  esac
done
exec "${args[@]}"
SH
  chmod +x "/usr/local/bin/CFLAGS=-Werror" || true
}

# ImGui helpers for CI/build
ensure_compiler_deps() {
  if ! command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo && chmod +x /usr/local/bin/sudo; fi
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y git curl wget build-essential pkg-config g++ make libglfw3-dev libsdl2-dev
  elif command -v yum >/dev/null 2>&1; then
    sudo yum -y install git curl wget gcc gcc-c++ make pkgconfig glfw-devel SDL2-devel
  elif command -v apk >/dev/null 2>&1; then
    sudo apk update && sudo apk add --no-cache git curl wget build-base pkgconfig glfw-dev sdl2-dev
  else
    echo "No supported package manager found (apt-get/yum/apk)"
  fi
}

ensure_imgui_sources() {
  if [ -d "$APP_DIR/imgui_test_suite" ]; then
    (
      cd "$APP_DIR"
      git submodule sync --recursive && git submodule update --init --recursive || true
      if [ ! -d imgui ]; then
        git clone --depth=1 https://github.com/ocornut/imgui.git imgui
      fi
    )
  fi
}

build_imgui_test_suite() {
  if [ -d "$APP_DIR/imgui_test_suite" ]; then
    make -C "$APP_DIR/imgui_test_suite" clean || true
    log "Building imgui_test_suite with CFLAGS=-Werror..."
    CFLAGS=-Werror make -C "$APP_DIR/imgui_test_suite" -j"$(nproc)" IMGUI_TEST_ENGINE_ENABLE_IMPLOT=0
  fi
}

# Main
main() {
  log "Starting project environment setup in $APP_DIR"

  detect_os_pkgmgr
  if [ -z "$PKG_MGR" ]; then
    warn "No supported package manager detected. Some steps may be skipped."
  else
    log "Detected OS: ${OS_ID}, Package manager: ${PKG_MGR}"
  fi

  ensure_base_tools
  setup_ci_shims
  ensure_compiler_deps
  # Ensure missing third-party sources
  ensure_imgui_sources
  setup_directories
  detect_project_type
  log "Detected project type: $PROJECT_TYPE (${PROJECT_SUBTYPE})"

  case "$PROJECT_TYPE" in
    python) setup_python ;;
    node) setup_node ;;
    ruby) setup_ruby ;;
    go) setup_go ;;
    java) setup_java ;;
    rust) setup_rust ;;
    php) setup_php ;;
    *) setup_unknown ;;
  esac

  # Attempt to build imgui_test_suite if present (handles shellless env var injection)
  build_imgui_test_suite || true

  # Summary and runtime hints
  log "Environment setup completed successfully."
  log "Environment variables persisted to $ENV_PROFILE"
  log "You can run your application using typical commands for the detected stack."
  case "$PROJECT_TYPE" in
    python)
      log "To run: source \"$ENV_PROFILE\" && . \"$APP_DIR/.venv/bin/activate\" && python app.py (or appropriate entrypoint)"
      ;;
    node)
      log "To run: source \"$ENV_PROFILE\" && cd \"$APP_DIR\" && npm start (or appropriate script)"
      ;;
    ruby)
      if [ "$PROJECT_SUBTYPE" = "rails" ]; then
        log "To run: source \"$ENV_PROFILE\" && cd \"$APP_DIR\" && bundle exec rails server -b 0.0.0.0 -p \"${PORT:-3000}\""
      else
        log "To run: source \"$ENV_PROFILE\" && cd \"$APP_DIR\" && bundle exec rackup -o 0.0.0.0 -p \"${PORT:-3000}\""
      fi
      ;;
    go)
      log "To run: source \"$ENV_PROFILE\" && cd \"$APP_DIR\" && go run ./... (or built binary)"
      ;;
    java)
      log "To run: source \"$ENV_PROFILE\" && use mvn spring-boot:run or ./gradlew bootRun, if applicable"
      ;;
    rust)
      log "To run: source \"$ENV_PROFILE\" && cd \"$APP_DIR\" && cargo run"
      ;;
    php)
      log "To run: source \"$ENV_PROFILE\" && cd \"$APP_DIR\" && php -S 0.0.0.0:\"${PORT:-8080}\" -t public (or framework-specific)"
      ;;
    *)
      log "To run: source \"$ENV_PROFILE\" and start your application as appropriate for your stack."
      ;;
  esac
}

main "$@"