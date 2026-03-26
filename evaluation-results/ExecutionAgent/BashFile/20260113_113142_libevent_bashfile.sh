#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type (Python/Node/Go/Rust/Java/Ruby/PHP/.NET)
# - Installs system packages and runtime dependencies
# - Sets up directories, permissions, and environment variables
# - Idempotent and safe to re-run
# - Designed to run as root inside Docker (no sudo). Will degrade gracefully if not root.

set -Eeuo pipefail

umask 022

#========================
# Configurable defaults
#========================
: "${PROJECT_ROOT:=/app}"
: "${APP_USER:=app}"
: "${APP_GROUP:=app}"
: "${APP_UID:=10001}"
: "${APP_GID:=10001}"
: "${CREATE_APP_USER:=1}"            # set 0 to skip creating a non-root user
: "${APP_ENV:=production}"
: "${CI:=0}"                         # set 1 in CI to reduce interactivity
: "${RUNTIME:=auto}"                 # force runtime e.g., python|node|go|rust|java-maven|java-gradle|ruby|php|dotnet|auto

# Colors
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

#========================
# Logging and error handling
#========================
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

_last_cmd=""
trap 'rc=$?; [ $rc -eq 0 ] || err "Command failed (exit $rc): ${_last_cmd:-unknown} at line $LINENO"' ERR
trap 'true' INT

run() { _last_cmd="$*"; eval "$@"; _last_cmd=""; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [ "$(id -u)" -eq 0 ]; }

#========================
# OS / Package manager detection
#========================
PM=""
UPDATE_CMD=""
INSTALL_CMD=""
CLEAN_CMD=""
NONINTERACTIVE_ENV=""

detect_pm() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release || true
  fi

  if need_cmd apt-get; then
    PM="apt"
    UPDATE_CMD="apt-get update -y"
    INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
    CLEAN_CMD="apt-get clean && rm -rf /var/lib/apt/lists/*"
    NONINTERACTIVE_ENV="DEBIAN_FRONTEND=noninteractive"
  elif need_cmd apk; then
    PM="apk"
    UPDATE_CMD="apk update"
    INSTALL_CMD="apk add --no-cache"
    CLEAN_CMD="true"
  elif need_cmd dnf; then
    PM="dnf"
    UPDATE_CMD="dnf -y makecache"
    INSTALL_CMD="dnf install -y"
    CLEAN_CMD="dnf clean all"
  elif need_cmd yum; then
    PM="yum"
    UPDATE_CMD="yum -y makecache"
    INSTALL_CMD="yum install -y"
    CLEAN_CMD="yum clean all"
  else
    PM="unknown"
  fi
}

ensure_update() {
  [ "$PM" = "unknown" ] && { warn "No supported package manager found. Skipping system package installation."; return 0; }
  log "Updating package index with $PM..."
  run "$UPDATE_CMD"
}

ensure_packages() {
  [ "$PM" = "unknown" ] && { warn "Package manager unknown; cannot install: $*"; return 0; }
  local pkgs=("$@")
  [ ${#pkgs[@]} -eq 0 ] && return 0
  log "Installing packages via $PM: ${pkgs[*]}"
  # shellcheck disable=SC2086
  run "$INSTALL_CMD ${pkgs[*]}"
}

pm_clean() {
  [ "$PM" = "unknown" ] && return 0
  run "$CLEAN_CMD"
}

#========================
# Project type detection
#========================
PROJECT_TYPE="unknown"

detect_project_type() {
  [ "$RUNTIME" != "auto" ] && { PROJECT_TYPE="$RUNTIME"; log "Runtime forced by RUNTIME=$RUNTIME"; return; }

  cd "$PROJECT_ROOT" 2>/dev/null || true
  if [ -f package.json ]; then
    PROJECT_TYPE="node"
  elif [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f setup.py ] || [ -f setup.cfg ]; then
    PROJECT_TYPE="python"
  elif [ -f go.mod ]; then
    PROJECT_TYPE="go"
  elif [ -f Cargo.toml ]; then
    PROJECT_TYPE="rust"
  elif [ -f pom.xml ]; then
    PROJECT_TYPE="java-maven"
  elif ls *.gradle *.gradle.kts >/dev/null 2>&1; then
    PROJECT_TYPE="java-gradle"
  elif [ -f Gemfile ]; then
    PROJECT_TYPE="ruby"
  elif [ -f composer.json ]; then
    PROJECT_TYPE="php"
  elif ls *.sln *.csproj >/dev/null 2>&1; then
    PROJECT_TYPE="dotnet"
  else
    PROJECT_TYPE="unknown"
  fi
  log "Detected project type: $PROJECT_TYPE"
}

#========================
# User and directory setup
#========================
create_app_user() {
  [ "$CREATE_APP_USER" = "1" ] || { log "Skipping app user creation (CREATE_APP_USER=0)"; return; }
  is_root || { warn "Not running as root, cannot create user/group"; return; }

  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    run "groupadd -g $APP_GID -r $APP_GROUP"
  fi
  if ! id "$APP_USER" >/dev/null 2>&1; then
    run "useradd -r -u $APP_UID -g $APP_GROUP -d $PROJECT_ROOT -M -s /usr/sbin/nologin $APP_USER"
  fi
}

prepare_directories() {
  log "Preparing project directories at $PROJECT_ROOT"
  run "mkdir -p '$PROJECT_ROOT'"
  run "mkdir -p '$PROJECT_ROOT/logs' '$PROJECT_ROOT/tmp' '$PROJECT_ROOT/data' '$PROJECT_ROOT/cache'"
  if is_root && id "$APP_USER" >/dev/null 2>&1; then
    run "chown -R ${APP_USER}:${APP_GROUP} '$PROJECT_ROOT'"
  fi
}

#========================
# Runtime installers
#========================
install_base_tools() {
  ensure_update
  case "$PM" in
    apt) ensure_packages ca-certificates curl git jq unzip tar xz-utils bash build-essential pkg-config openssl libssl-dev; update-ca-certificates || true ;;
    apk) ensure_packages ca-certificates curl git jq unzip tar xz bash build-base pkgconfig openssl openssl-dev; update-ca-certificates || true ;;
    dnf|yum) ensure_packages ca-certificates curl git jq unzip tar xz bash gcc gcc-c++ make pkgconfig openssl-devel ;;
    *) warn "Skipping base tools install; unsupported PM." ;;
  esac
}

install_python_runtime() {
  case "$PM" in
    apt) ensure_packages python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev ;;
    apk) ensure_packages python3 py3-pip python3-dev build-base libffi-dev openssl-dev ;;
    dnf|yum) ensure_packages python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel ;;
    *) warn "Cannot install Python on unknown PM";;
  esac
  if ! need_cmd python3; then err "Python3 not found after installation"; fi
}

install_node_runtime() {
  case "$PM" in
    apt) ensure_packages nodejs npm ;;
    apk) ensure_packages nodejs npm ;;
    dnf|yum) ensure_packages nodejs npm ;;
    *) warn "Cannot install Node.js on unknown PM";;
  esac
  if ! need_cmd node; then warn "node not found; consider using a node base image."; fi
  if need_cmd corepack; then run "corepack enable" || true; fi
}

install_go_runtime() {
  case "$PM" in
    apt) ensure_packages golang ;;
    apk) ensure_packages go ;;
    dnf|yum) ensure_packages golang ;;
    *) warn "Cannot install Go on unknown PM";;
  esac
  if ! need_cmd go; then err "Go not found after installation"; fi
}

install_rust_runtime() {
  case "$PM" in
    apt) ensure_packages rustc cargo pkg-config libssl-dev build-essential ;;
    apk) ensure_packages rust cargo pkgconfig openssl-dev build-base ;;
    dnf|yum) ensure_packages rust cargo pkgconfig openssl-devel gcc gcc-c++ make ;;
    *) warn "Cannot install Rust on unknown PM";;
  esac
  if ! need_cmd cargo; then err "Rust toolchain not found after installation"; fi
}

install_java_maven_runtime() {
  case "$PM" in
    apt) ensure_packages openjdk-17-jdk maven ;;
    apk) ensure_packages openjdk17 maven ;;
    dnf|yum) ensure_packages java-17-openjdk-devel maven ;;
    *) warn "Cannot install Java/Maven on unknown PM";;
  esac
  if ! need_cmd mvn; then err "Maven not found after installation"; fi
}

install_java_gradle_runtime() {
  case "$PM" in
    apt) ensure_packages openjdk-17-jdk gradle || ensure_packages openjdk-17-jdk ;;
    apk) ensure_packages openjdk17 gradle || ensure_packages openjdk17 ;;
    dnf|yum) ensure_packages java-17-openjdk-devel gradle || ensure_packages java-17-openjdk-devel ;;
    *) warn "Cannot install Java/Gradle on unknown PM";;
  esac
  if ! need_cmd gradle; then warn "Gradle not installed; will try Gradle Wrapper if present."; fi
}

install_ruby_runtime() {
  case "$PM" in
    apt) ensure_packages ruby-full build-essential ;;
    apk) ensure_packages ruby ruby-dev build-base ;;
    dnf|yum) ensure_packages ruby ruby-devel gcc gcc-c++ make ;;
    *) warn "Cannot install Ruby on unknown PM";;
  esac
  if ! need_cmd gem; then err "Ruby gem not found after installation"; fi
  run "gem install --no-document bundler" || true
}

install_php_runtime() {
  case "$PM" in
    apt) ensure_packages php-cli php-mbstring php-xml php-curl php-zip unzip composer || ensure_packages php-cli unzip ;;
    apk) ensure_packages php81 php81-cli php81-phar php81-mbstring php81-xml php81-curl php81-zip unzip || ensure_packages php php-cli php-phar ;;
    dnf|yum) ensure_packages php-cli php-mbstring php-xml php-common php-json unzip composer || ensure_packages php-cli unzip ;;
    *) warn "Cannot install PHP on unknown PM";;
  esac
  if ! need_cmd composer; then
    warn "Composer not found in package manager; installing locally..."
    run "curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php"
    run "php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer" || warn "Composer install failed"
    rm -f /tmp/composer-setup.php || true
  fi
}

install_dotnet_runtime() {
  # Attempt to install .NET SDK using Microsoft dotnet-install script (works without root; installs under /usr/share/dotnet when root)
  local install_dir
  if is_root; then install_dir="/usr/share/dotnet"; else install_dir="$PROJECT_ROOT/.dotnet"; fi
  mkdir -p "$install_dir"
  if need_cmd dotnet; then
    log ".NET already installed: $(dotnet --version 2>/dev/null || echo unknown)"
    return 0
  fi
  warn "Installing .NET SDK via dotnet-install script (internet required)."
  run "curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh"
  run "bash /tmp/dotnet-install.sh --install-dir \"$install_dir\" --version latest"
  rm -f /tmp/dotnet-install.sh || true
  if is_root; then
    ln -sf "$install_dir/dotnet" /usr/local/bin/dotnet || true
  else
    export PATH="$install_dir:$PATH"
  fi
  if ! need_cmd dotnet; then warn ".NET not available in PATH; set PATH to include $install_dir"; fi
}

#========================
# Dependency installation per project type
#========================
setup_python_project() {
  cd "$PROJECT_ROOT"
  local venv_dir="${PROJECT_ROOT}/.venv"
  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at $venv_dir"
    run "python3 -m venv '$venv_dir'"
  else
    log "Python virtual environment already exists"
  fi
  # shellcheck source=/dev/null
  run "source '$venv_dir/bin/activate'"
  run "pip install --upgrade pip setuptools wheel"
  if [ -f requirements.txt ]; then
    log "Installing Python dependencies from requirements.txt"
    run "pip install -r requirements.txt"
  elif [ -f pyproject.toml ]; then
    log "Installing Python project from pyproject.toml"
    run "pip install ."
  elif [ -f setup.py ] || [ -f setup.cfg ]; then
    log "Installing Python project (setup.*)"
    run "pip install -e ."
  else
    warn "No Python dependency file found"
  fi
}

setup_node_project() {
  cd "$PROJECT_ROOT"
  if [ -f package.json ]; then
    if [ -f package-lock.json ]; then
      log "Installing Node dependencies with npm ci"
      run "npm ci --no-audit --no-fund"
    else
      log "Installing Node dependencies with npm install"
      run "npm install --no-audit --no-fund"
    fi
    if [ "$APP_ENV" = "production" ]; then
      run "npm prune --production" || true
    fi
  else
    warn "package.json not found"
  fi
}

setup_go_project() {
  cd "$PROJECT_ROOT"
  if [ -f go.mod ]; then
    log "Downloading Go modules"
    run "go mod download"
    if ls *.go >/dev/null 2>&1; then
      log "Building Go binary"
      run "go build -o bin/app ./..."
    fi
  else
    warn "go.mod not found"
  fi
}

setup_rust_project() {
  cd "$PROJECT_ROOT"
  if [ -f Cargo.toml ]; then
    log "Fetching Rust crates"
    run "cargo fetch"
    if [ "$APP_ENV" = "production" ]; then
      log "Building Rust project (release)"
      run "cargo build --release"
    else
      log "Building Rust project (debug)"
      run "cargo build"
    fi
  else
    warn "Cargo.toml not found"
  fi
}

setup_java_maven_project() {
  cd "$PROJECT_ROOT"
  if [ -f pom.xml ]; then
    log "Resolving Maven dependencies"
    run "mvn -B -ntp dependency:resolve"
    if [ "$CI" = "1" ]; then
      run "mvn -B -ntp -DskipTests package"
    fi
  else
    warn "pom.xml not found"
  fi
}

setup_java_gradle_project() {
  cd "$PROJECT_ROOT"
  if [ -x ./gradlew ]; then
    log "Using Gradle Wrapper to resolve dependencies"
    run "./gradlew --no-daemon build -x test"
  elif need_cmd gradle; then
    log "Using system Gradle to resolve dependencies"
    run "gradle --no-daemon build -x test"
  else
    warn "Gradle not available and no gradlew found"
  fi
}

setup_ruby_project() {
  cd "$PROJECT_ROOT"
  if [ -f Gemfile ]; then
    run "bundle config set --local path 'vendor/bundle'"
    if [ "$APP_ENV" = "production" ]; then
      run "bundle install --without development test --jobs 4 --retry 3"
    else
      run "bundle install --jobs 4 --retry 3"
    fi
  else
    warn "Gemfile not found"
  fi
}

setup_php_project() {
  cd "$PROJECT_ROOT"
  if [ -f composer.json ]; then
    if ! need_cmd composer; then err "Composer not installed"; fi
    if [ "$APP_ENV" = "production" ]; then
      run "composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader"
    else
      run "composer install --no-interaction --prefer-dist"
    fi
  else
    warn "composer.json not found"
  fi
}

setup_dotnet_project() {
  cd "$PROJECT_ROOT"
  if ls *.sln *.csproj >/dev/null 2>&1; then
    if ! need_cmd dotnet; then err ".NET SDK not installed"; fi
    log "Restoring .NET dependencies"
    run "dotnet restore"
    if [ "$CI" = "1" ]; then
      run "dotnet build --configuration Release --no-restore"
    fi
  else
    warn "No .sln or .csproj found"
  fi
}

#========================
# Environment configuration
#========================
write_env_file() {
  cd "$PROJECT_ROOT"
  local env_file="$PROJECT_ROOT/.env"
  if [ ! -f "$env_file" ]; then
    log "Creating default .env file"
    cat > "$env_file" <<EOF
# Generated by setup script
APP_ENV=${APP_ENV}
PORT=${PORT:-8080}
HOST=0.0.0.0
# Add project-specific variables below
EOF
    if is_root && id "$APP_USER" >/dev/null 2>&1; then
      chown "${APP_USER}:${APP_GROUP}" "$env_file" || true
      chmod 0640 "$env_file" || true
    fi
  else
    log ".env already exists; not overwriting"
  fi
}

export_runtime_env() {
  # Export common defaults for container runtime
  export APP_ENV
  export PROJECT_ROOT
  export PATH="$PROJECT_ROOT/bin:$PATH"

  case "$PROJECT_TYPE" in
    python)
      export VIRTUAL_ENV="$PROJECT_ROOT/.venv"
      export PATH="$VIRTUAL_ENV/bin:$PATH"
      ;;
    node)
      export NODE_ENV="${NODE_ENV:-${APP_ENV}}"
      ;;
    go)
      export GOPATH="${GOPATH:-$PROJECT_ROOT/.gopath}"
      export GOCACHE="${GOCACHE:-$PROJECT_ROOT/.gocache}"
      mkdir -p "$GOPATH" "$GOCACHE"
      ;;
    rust)
      export CARGO_HOME="${CARGO_HOME:-$PROJECT_ROOT/.cargo}"
      export RUSTUP_HOME="${RUSTUP_HOME:-$PROJECT_ROOT/.rustup}"
      mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"
      ;;
    java-* )
      export MAVEN_OPTS="${MAVEN_OPTS:--Xmx512m}"
      ;;
    ruby)
      export BUNDLE_PATH="$PROJECT_ROOT/vendor/bundle"
      ;;
    php)
      true
      ;;
    dotnet)
      true
      ;;
    *)
      true
      ;;
  esac
}

#========================
# Makefile helper
#========================
ensure_auto_test_and_make_targets() {
  cd "$PROJECT_ROOT" 2>/dev/null || return 0
  mkdir -p scripts
  cat > scripts/auto-test.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Python pytest
if command -v pytest >/dev/null 2>&1; then
  if [ -d tests ] || ls test_*.py *_test.py >/dev/null 2>&1; then
    pytest -q || pytest
    exit 0
  fi
fi
# Node.js npm test
if [ -f package.json ] && command -v npm >/dev/null 2>&1 && grep -q '"test"[[:space:]]*:' package.json; then
  npm test --silent
  exit 0
fi
# Go
if [ -f go.mod ] && command -v go >/dev/null 2>&1; then
  go test ./...
  exit 0
fi
# Rust
if [ -f Cargo.toml ] && command -v cargo >/dev/null 2>&1; then
  cargo test --quiet
  exit 0
fi
# Java Maven
if [ -f pom.xml ] && command -v mvn >/dev/null 2>&1; then
  mvn -q -DskipTests=false test
  exit 0
fi
# Gradle
if [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  if [ -x ./gradlew ]; then ./gradlew test; elif command -v gradle >/dev/null 2>&1; then gradle test; fi
  exit 0
fi
echo "No test runner detected; nothing to do."
exit 0
EOF
  chmod +x scripts/auto-test.sh || true
  cat > scripts/ensure-make-targets.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ ! -f Makefile ]; then
  printf ".PHONY: test run\n\ntest:\n\t./scripts/auto-test.sh\n\nrun: test\n" > Makefile
  exit 0
fi
# Ensure PHONY markers exist (append once)
grep -Eq '^[[:space:]]*\.PHONY:.*test' Makefile || printf "\n.PHONY: test\n" >> Makefile
grep -Eq '^[[:space:]]*\.PHONY:.*run' Makefile || printf ".PHONY: run\n" >> Makefile
# Ensure test target exists with a recipe if missing
grep -Eq '^[[:space:]]*test[:]' Makefile || printf "\ntest:\n\t./scripts/auto-test.sh\n" >> Makefile
# Ensure run target exists; default to test
grep -Eq '^[[:space:]]*run[:]' Makefile || printf "\nrun: test\n" >> Makefile
EOF
  chmod +x scripts/ensure-make-targets.sh || true
  ./scripts/ensure-make-targets.sh || true
}

ensure_makefile_build_target() {
  cd "$PROJECT_ROOT" 2>/dev/null || return 0
  if [ ! -f Makefile ]; then
    printf ".PHONY: build\n\nbuild:\n\t@echo \"No explicit build steps defined. Skipping build.\"\n" > Makefile
    return 0
  fi
  grep -Eq '^[[:space:]]*\.PHONY:.*build' Makefile || printf "\n.PHONY: build\n" >> Makefile
  grep -Eq '^[[:space:]]*build[:]' Makefile || printf "\nbuild:\n\t@echo \"No explicit build steps defined. Skipping build.\"\n" >> Makefile
}

#========================
# Main
#========================
main() {
  log "Starting environment setup"
  log "Settings: PROJECT_ROOT=$PROJECT_ROOT APP_ENV=$APP_ENV APP_USER=$APP_USER PM=$(detect_pm >/dev/null 2>&1; echo $PM)"

  detect_pm
  is_root || warn "Not running as root; system package installation may fail or be skipped."

  create_app_user
  prepare_directories
  install_base_tools

  detect_project_type

  case "$PROJECT_TYPE" in
    python)
      install_python_runtime
      setup_python_project
      ;;
    node)
      install_node_runtime
      setup_node_project
      ;;
    go)
      install_go_runtime
      setup_go_project
      ;;
    rust)
      install_rust_runtime
      setup_rust_project
      ;;
    java-maven)
      install_java_maven_runtime
      setup_java_maven_project
      ;;
    java-gradle)
      install_java_gradle_runtime
      setup_java_gradle_project
      ;;
    ruby)
      install_ruby_runtime
      setup_ruby_project
      ;;
    php)
      install_php_runtime
      setup_php_project
      ;;
    dotnet)
      install_dotnet_runtime
      setup_dotnet_project
      ;;
    *)
      warn "Could not detect project type automatically. Base tools installed; please set RUNTIME=... and re-run if needed."
      ;;
  esac

  write_env_file
  export_runtime_env

  # Ensure Makefile has test/run targets and a build target; add auto-test helper
  ensure_auto_test_and_make_targets
  ensure_makefile_build_target

  pm_clean

  # Final ownership adjustments
  if is_root && id "$APP_USER" >/dev/null 2>&1; then
    run "chown -R ${APP_USER}:${APP_GROUP} '$PROJECT_ROOT'"
  fi

  log "Environment setup completed successfully."
  case "$PROJECT_TYPE" in
    python)
      echo "Activate venv: source '$PROJECT_ROOT/.venv/bin/activate' && python -m pip list"
      ;;
    node)
      echo "Run app: cd '$PROJECT_ROOT' && npm start (if defined)"
      ;;
    go)
      echo "Run binary: '$PROJECT_ROOT/bin/app' (if built)"
      ;;
    rust)
      echo "Run binary: target/release/<app> or target/debug/<app>"
      ;;
    java-maven)
      echo "Run: mvn spring-boot:run or java -jar target/*.jar"
      ;;
    java-gradle)
      echo "Run: ./gradlew bootRun or java -jar build/libs/*.jar"
      ;;
    ruby)
      echo "Run: bundle exec <command>"
      ;;
    php)
      echo "Run: php -S 0.0.0.0:\${PORT:-8080} -t public"
      ;;
    dotnet)
      echo "Run: dotnet run"
      ;;
    *)
      echo "Set RUNTIME=python|node|go|rust|java-maven|java-gradle|ruby|php|dotnet and re-run for specific setup."
      ;;
  esac
}

# Ensure PROJECT_ROOT exists even if mounted volume
mkdir -p "$PROJECT_ROOT"

main "$@"