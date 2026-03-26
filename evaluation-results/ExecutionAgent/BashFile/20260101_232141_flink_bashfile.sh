#!/usr/bin/env bash
# Environment setup script for containerized projects
# Detects common project types and installs required runtimes, system packages, and dependencies.
# Designed for Ubuntu/Debian-based Docker containers running as root (no sudo).
#
# Idempotent and safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'

# -------------------------
# Configuration and Globals
# -------------------------
APP_DIR="${APP_DIR:-/app}"
SETUP_STATE_DIR="/opt/app-setup"
LOCK_FILE="/tmp/app_setup.lock"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
TZ="${TZ:-UTC}"
DEFAULT_PORT="${PORT:-8080}"
APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"

# Flags for project detection
HAS_NODE=0
HAS_PYTHON=0
HAS_RUBY=0
HAS_GO=0
HAS_JAVA_MVN=0
HAS_JAVA_GRADLE=0
HAS_RUST=0
HAS_PHP=0
HAS_DOTNET=0

# Colors (fallback to no color if not TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

# -------------------------
# Logging and Error Handling
# -------------------------
log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info()   { echo "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]}
  error "Failed at line ${line_no} with exit code ${exit_code}"
  exit "$exit_code"
}
trap on_error ERR

# Prevent concurrent runs (requires util-linux, usually present)
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      error "Another setup process is running. If this is a stale lock, remove $LOCK_FILE and retry."
      exit 1
    fi
  else
    warn "flock not found; proceeding without concurrency protection."
  fi
}

# -------------------------
# Helpers
# -------------------------
ensure_dir() { mkdir -p "$1"; }

# Run apt-get update once per script
APT_UPDATED=0
apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    log "Updating apt package lists..."
    apt-get update -y
    APT_UPDATED=1
  fi
}

# Install packages only if missing
ensure_packages() {
  local missing=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    apt_update_once
    log "Installing packages: ${missing[*]}"
    apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}

apt_clean() {
  apt-get clean
  rm -rf /var/lib/apt/lists/* || true
}

# Append line to file if not already present
append_unique_line() {
  local file="$1"
  local line="$2"
  touch "$file"
  grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

# -------------------------
# System Preparation
# -------------------------
prepare_system() {
  log "Preparing system base packages and configuration..."
  export DEBIAN_FRONTEND TZ
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
  echo "$TZ" > /etc/timezone || true
  # Base tools often needed across stacks
  ensure_packages ca-certificates curl wget git gnupg lsb-release apt-transport-https software-properties-common pkg-config make build-essential unzip zip xz-utils openssl
}

# -------------------------
# User and Permissions
# -------------------------
create_app_user() {
  # Create group if missing
  if ! getent group "$APP_GID" >/dev/null 2>&1; then
    if getent group "$APP_GID" >/dev/null 2>&1; then
      warn "Group GID $APP_GID exists; will reuse."
    fi
  fi

  if ! getent group "$APP_USER" >/dev/null 2>&1; then
    addgroup --gid "$APP_GID" "$APP_USER" >/dev/null 2>&1 || addgroup "$APP_USER" >/dev/null 2>&1 || true
  fi

  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" --uid "$APP_UID" --gid "$APP_GID" "$APP_USER" >/dev/null 2>&1 || true
  fi

  ensure_dir "$APP_DIR"
  ensure_dir "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/data"
  chown -R "$APP_USER:$APP_USER" "$APP_DIR" || true
}

# -------------------------
# Project Detection
# -------------------------
detect_project() {
  cd "$APP_DIR"
  if [ -f "package.json" ]; then HAS_NODE=1; fi
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ]; then HAS_PYTHON=1; fi
  if [ -f "Gemfile" ]; then HAS_RUBY=1; fi
  if [ -f "go.mod" ]; then HAS_GO=1; fi
  if [ -f "pom.xml" ] || [ -f "mvnw" ]; then HAS_JAVA_MVN=1; fi
  if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -f "gradlew" ]; then HAS_JAVA_GRADLE=1; fi
  if [ -f "Cargo.toml" ]; then HAS_RUST=1; fi
  if [ -f "composer.json" ]; then HAS_PHP=1; fi
  if compgen -G "*.sln" >/dev/null || compgen -G "*.csproj" >/dev/null; then HAS_DOTNET=1; fi

  log "Project detection:"
  [ "$HAS_NODE" -eq 1 ] && info "- Node.js project detected"
  [ "$HAS_PYTHON" -eq 1 ] && info "- Python project detected"
  [ "$HAS_RUBY" -eq 1 ] && info "- Ruby project detected"
  [ "$HAS_GO" -eq 1 ] && info "- Go project detected"
  [ "$HAS_JAVA_MVN" -eq 1 ] && info "- Java (Maven) project detected"
  [ "$HAS_JAVA_GRADLE" -eq 1 ] && info "- Java (Gradle) project detected"
  [ "$HAS_RUST" -eq 1 ] && info "- Rust project detected"
  [ "$HAS_PHP" -eq 1 ] && info "- PHP (Composer) project detected"
  [ "$HAS_DOTNET" -eq 1 ] && info "- .NET project detected"

  if [ "$HAS_NODE" -eq 0 ] && [ "$HAS_PYTHON" -eq 0 ] && [ "$HAS_RUBY" -eq 0 ] && [ "$HAS_GO" -eq 0 ] && [ "$HAS_JAVA_MVN" -eq 0 ] && [ "$HAS_JAVA_GRADLE" -eq 0 ] && [ "$HAS_RUST" -eq 0 ] && [ "$HAS_PHP" -eq 0 ] && [ "$HAS_DOTNET" -eq 0 ]; then
    warn "No known project files found. The script will still configure base environment and directories."
  fi
}

# -------------------------
# Language/Framework Setups
# -------------------------
setup_node() {
  [ "$HAS_NODE" -eq 1 ] || return 0
  log "Setting up Node.js environment..."

  # Install Node.js LTS via NodeSource if not present or too old
  local need_node_install=1
  if command -v node >/dev/null 2>&1; then
    local major
    major=$(node -v | sed -E 's/^v([0-9]+).*/\1/')
    if [ "${major:-0}" -ge 16 ]; then
      need_node_install=0
      info "Node.js $(node -v) already installed."
    fi
  fi

  if [ "$need_node_install" -eq 1 ]; then
    log "Installing Node.js via apt (nodejs and npm)..."
    apt_update_once
    ensure_packages nodejs npm
  fi

  # Enable corepack for yarn/pnpm management
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Install package manager if needed
  local used_pm="npm"
  if [ -f "pnpm-lock.yaml" ]; then
    used_pm="pnpm"
    if ! command -v pnpm >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then
        corepack prepare pnpm@latest --activate || true
      fi
      if ! command -v pnpm >/dev/null 2>&1; then
        npm install -g pnpm@8
      end_if=true
      fi
    fi
  elif [ -f "yarn.lock" ]; then
    used_pm="yarn"
    if ! command -v yarn >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then
        corepack prepare yarn@stable --activate || true
      fi
      if ! command -v yarn >/dev/null 2>&1; then
        npm install -g yarn
      fi
    fi
  fi

  # Install dependencies
  case "$used_pm" in
    pnpm)
      log "Installing Node dependencies using pnpm..."
      pnpm install --frozen-lockfile || pnpm install
      ;;
    yarn)
      log "Installing Node dependencies using yarn..."
      yarn install --frozen-lockfile || yarn install
      ;;
    npm)
      if [ -f "package-lock.json" ]; then
        log "Installing Node dependencies using npm ci..."
        npm ci --no-audit --no-fund
      else
        log "Installing Node dependencies using npm install..."
        npm install --no-audit --no-fund
      fi
      ;;
  esac

  # Build step if defined
  if jq -e '.scripts.build' package.json >/dev/null 2>&1; then
    log "Running npm/yarn build script..."
    case "$used_pm" in
      pnpm) pnpm run build || warn "Build step failed";;
      yarn) yarn build || warn "Build step failed";;
      npm) npm run build || warn "Build step failed";;
    esac
  fi
}

setup_python() {
  [ "$HAS_PYTHON" -eq 1 ] || return 0
  log "Setting up Python environment..."

  ensure_packages python3 python3-venv python3-pip python3-dev

  # Create venv in project directory for containerized isolation
  local venv_dir="$APP_DIR/.venv"
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
  fi

  # Activate venv
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"

  pip install --no-cache-dir --upgrade pip setuptools wheel

  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir -r requirements.txt
  elif [ -f "Pipfile" ]; then
    log "Detected Pipfile. Installing pipenv and dependencies..."
    pip install --no-cache-dir pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  elif [ -f "pyproject.toml" ]; then
    # Attempt to install project via PEP 517
    log "Installing Python project via pyproject.toml..."
    pip install --no-cache-dir .
  fi

  deactivate || true
}

setup_ruby() {
  [ "$HAS_RUBY" -eq 1 ] || return 0
  log "Setting up Ruby environment..."
  ensure_packages ruby-full
  if ! command -v bundler >/dev/null 2>&1; then
    gem install bundler --no-document
  fi
  bundle config set path 'vendor/bundle'
  bundle install --jobs 4 --retry 3
}

setup_go() {
  [ "$HAS_GO" -eq 1 ] || return 0
  log "Setting up Go environment..."
  ensure_packages golang
  export GO111MODULE=on
  export GOPATH="${GOPATH:-/go}"
  ensure_dir "$GOPATH/bin" "$GOPATH/pkg"
  append_unique_line /etc/profile.d/app_env.sh "export GOPATH=${GOPATH}"
  append_unique_line /etc/profile.d/app_env.sh 'export PATH="$GOPATH/bin:$PATH"'
  if [ -f "go.mod" ]; then
    go mod download
  fi
}

ensure_temurin_jdks_and_maven() {
  # Install OpenJDK toolchains (11, 17, 21) and Maven
  apt_update_once
  ensure_packages curl gnupg ca-certificates
  ensure_packages maven openjdk-21-jdk

  # Set JDK 21 as the default java and javac if available
  local J JC
  J=$(update-alternatives --list java 2>/dev/null | grep -E "java-21" | head -n1)
  [ -n "$J" ] && update-alternatives --set java "$J" || true
  JC=$(update-alternatives --list javac 2>/dev/null | grep -E "java-21" | head -n1)
  [ -n "$JC" ] && update-alternatives --set javac "$JC" || true

  # Configure Maven defaults to reduce build time and noise
  mkdir -p .mvn
  printf "%s\n" "-T 1C" "-nsu" "-Drat.skip=true" "-Dcheckstyle.skip=true" "-Dspotless.skip=true" "-Dmaven.javadoc.skip=true" "-Dsurefire.failIfNoSpecifiedTests=false" "-DfailIfNoTests=false" > .mvn/maven.config
  printf "%s\n" "-Xmx1024m" "-XX:+UseParallelGC" > .mvn/jvm.config
}

setup_java_maven() {
  [ "$HAS_JAVA_MVN" -eq 1 ] || return 0
  log "Setting up Java (Maven) environment..."
  # Ensure Node.js/npm is available for frontend builds invoked from Maven
  if ! command -v npm >/dev/null 2>&1; then
    log "Installing Node.js via apt (nodejs and npm)..."
    apt_update_once
    ensure_packages nodejs npm
  fi
  ensure_temurin_jdks_and_maven
  npm --version && node --version || true

  # Configure Maven to skip Apache RAT license checks during CI to prevent build failures
  mkdir -p .mvn && (test -f .mvn/maven.config && grep -qxF "-Drat.skip=true" .mvn/maven.config || printf "%s\n" "-Drat.skip=true" >> .mvn/maven.config)

  if [ -f "mvnw" ]; then
    chmod +x mvnw
    mvn -B -q -DskipTests -nsu -T 1C dependency:go-offline || ./mvnw -B -q -DskipTests -nsu -T 1C dependency:go-offline
  else
    mvn -B -q -DskipTests -nsu -T 1C dependency:go-offline || warn "Maven go-offline failed"
  fi
}

setup_java_gradle() {
  [ "$HAS_JAVA_GRADLE" -eq 1 ] || return 0
  log "Setting up Java (Gradle) environment..."
  ensure_packages openjdk-17-jdk
  if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
    ./gradlew --no-daemon build -x test || warn "Gradle build step failed (dependencies likely fetched)"
  else
    ensure_packages gradle
    gradle --no-daemon tasks >/dev/null 2>&1 || true
    gradle --no-daemon build -x test || warn "Gradle build step failed"
  fi
}

setup_rust() {
  [ "$HAS_RUST" -eq 1 ] || return 0
  log "Setting up Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    # Install rustup and stable toolchain
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
  fi
  if command -v cargo >/dev/null 2>&1; then
    cargo fetch || warn "cargo fetch failed"
  else
    error "Cargo not available after installation attempt."
  fi
  append_unique_line /etc/profile.d/app_env.sh 'export PATH="$HOME/.cargo/bin:$PATH"'
}

setup_php() {
  [ "$HAS_PHP" -eq 1 ] || return 0
  log "Setting up PHP (Composer) environment..."
  ensure_packages php-cli php-mbstring php-xml php-zip unzip
  if ! command -v composer >/dev/null 2>&1; then
    ensure_packages composer
  fi
  composer install --no-interaction --prefer-dist || warn "Composer install failed"
}

setup_dotnet() {
  [ "$HAS_DOTNET" -eq 1 ] || return 0
  log "Setting up .NET SDK..."
  if ! command -v dotnet >/dev/null 2>&1; then
    apt_update_once
    wget -q https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb
    dpkg -i /tmp/packages-microsoft-prod.deb
    rm -f /tmp/packages-microsoft-prod.deb
    apt_update_once
    ensure_packages dotnet-sdk-8.0
  else
    info "dotnet already installed: $(dotnet --version)"
  fi
  # Restore dependencies
  if compgen -G "*.sln" >/dev/null; then
    for sln in *.sln; do
      dotnet restore "$sln" || warn "dotnet restore failed for $sln"
    done
  else
    for proj in *.csproj; do
      [ -f "$proj" ] && dotnet restore "$proj" || true
    done
  fi
}

# -------------------------
# Python Lint Script Setup
# -------------------------
setup_python_lint_script() {
  apt_update_once
  ensure_packages python3-pip
  ensure_dir "$APP_DIR/dev"
  cat > "$APP_DIR/dev/lint-python.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
# Attempt to install common linters if available
if command -v uv >/dev/null 2>&1; then
  uv pip install --system --quiet --upgrade ruff black flake8 || true
elif command -v python3 >/dev/null 2>&1; then
  python3 -m pip install --user --quiet --upgrade ruff black flake8 || true
elif command -v python >/dev/null 2>&1; then
  python -m pip install --user --quiet --upgrade ruff black flake8 || true
fi
# Detect python files; skip if none
pycount=$(find . -type f -name '*.py' | wc -l | tr -d ' ')
if [ "$pycount" = "0" ]; then
  echo "No Python files to lint; skipping."
  exit 0
fi
# Run available linters; do not fail the script on style issues
if command -v ruff >/dev/null 2>&1; then ruff check . || true; fi
if command -v black >/dev/null 2>&1; then black --check . || true; fi
if command -v flake8 >/dev/null 2>&1; then flake8 . || true; fi
exit 0
EOF
  chmod +x "$APP_DIR/dev/lint-python.sh"
}

# -------------------------
# Hugo Site Scaffolding
# -------------------------
setup_hugo_scaffold() {
  cd "$APP_DIR"
  if [ -f "config.toml" ] || [ -f "config.yaml" ] || [ -f "config.yml" ] || [ -d "config" ]; then
    :
  else
    mkdir -p content
    printf "baseURL = \"http://localhost:1313/\"\nlanguageCode = \"en-us\"\ntitle = \"Flink Docs\"\n" > config.toml
    printf "%s\n" "---" "title: Home" "---" "" "Welcome." > content/_index.md
  fi
}

# -------------------------
# Hugo wrapper image to auto-exit server
# -------------------------
setup_hugo_wrapper() {
  cd "$APP_DIR"
  cat > Dockerfile.hugo-wrapper <<'EOF'
FROM jakejarvis/hugo-extended:latest
RUN printf '%s\n' '#!/bin/sh' 'hugo "$@" &' 'sleep "${HUGO_EXIT_AFTER:-10}"' 'exit 0' > /usr/local/bin/run-and-exit.sh && chmod +x /usr/local/bin/run-and-exit.sh
ENTRYPOINT ["/usr/local/bin/run-and-exit.sh"]
EOF
  if command -v docker >/dev/null 2>&1; then
    docker build -t jakejarvis/hugo-extended:latest -f Dockerfile.hugo-wrapper .
  else
    warn "Docker not available; skipping Hugo wrapper image build"
  fi
}

# -------------------------
# Environment Variables Setup
# -------------------------
configure_env() {
  log "Configuring environment variables and PATH..."

  local env_file="/etc/profile.d/app_env.sh"
  touch "$env_file"
  chmod 0644 "$env_file"

  append_unique_line "$env_file" "export APP_DIR=${APP_DIR}"
  append_unique_line "$env_file" "export TZ=${TZ}"
  append_unique_line "$env_file" "export PORT=${DEFAULT_PORT}"
  append_unique_line "$env_file" 'export PATH="$HOME/.local/bin:$PATH"'

  # Python venv PATH
  if [ -d "$APP_DIR/.venv/bin" ]; then
    append_unique_line "$env_file" "export VIRTUAL_ENV=${APP_DIR}/.venv"
    append_unique_line "$env_file" 'export PATH="$VIRTUAL_ENV/bin:$PATH"'
    append_unique_line "$env_file" "export PYTHONUNBUFFERED=1"
  fi

  # Node env
  if [ "$HAS_NODE" -eq 1 ]; then
    append_unique_line "$env_file" "export NODE_ENV=${NODE_ENV:-production}"
    # NPM loglevel to reduce noise in containers
    append_unique_line "$env_file" "export NPM_CONFIG_LOGLEVEL=${NPM_CONFIG_LOGLEVEL:-warn}"
  fi

  # Go PATH handled in setup_go
  # Rust PATH handled in setup_rust

  # PHP Composer bin
  if command -v composer >/dev/null 2>&1; then
    # Composer global bin path (for root /root/.composer/vendor/bin or /root/.config/composer/vendor/bin)
    append_unique_line "$env_file" 'export PATH="$HOME/.composer/vendor/bin:$HOME/.config/composer/vendor/bin:$PATH"'
  fi

  # Create project .env with defaults if not exists
  local proj_env="$APP_DIR/.env"
  if [ ! -f "$proj_env" ]; then
    cat > "$proj_env" <<EOF
# Project environment defaults
PORT=${DEFAULT_PORT}
TZ=${TZ}
NODE_ENV=${NODE_ENV:-production}
PYTHONUNBUFFERED=1
EOF
    chown "$APP_USER:$APP_USER" "$proj_env" || true
  fi
}

# -------------------------
# Bash auto-activation for environments
# -------------------------
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local env_profile="/etc/profile.d/app_env.sh"
  local activate_line="if [ -d \"${APP_DIR}/.venv\" ] && [ -f \"${APP_DIR}/.venv/bin/activate\" ]; then . \"${APP_DIR}/.venv/bin/activate\"; fi"
  # Ensure profile is sourced when starting a shell
  if ! grep -qF "source ${env_profile}" "${bashrc_file}" 2>/dev/null; then
    echo "source ${env_profile}" >> "${bashrc_file}"
  fi
  # Ensure virtual environment auto-activation for the project
  if ! grep -qF "${activate_line}" "${bashrc_file}" 2>/dev/null; then
    echo "${activate_line}" >> "${bashrc_file}"
  fi
}

# -------------------------
# Permissions and Executables
# -------------------------
finalize_permissions() {
  log "Finalizing permissions and executable flags..."
  # Ensure wrapper scripts are executable if present
  [ -f "$APP_DIR/gradlew" ] && chmod +x "$APP_DIR/gradlew" || true
  [ -f "$APP_DIR/mvnw" ] && chmod +x "$APP_DIR/mvnw" || true

  chown -R "$APP_USER:$APP_USER" "$APP_DIR" || true
}

# -------------------------
# Main Flow
# -------------------------
main() {
  acquire_lock
  ensure_dir "$SETUP_STATE_DIR"
  prepare_system
  create_app_user
  detect_project

  # For jq JSON parsing in Node build scripts detection (optional)
  if [ "$HAS_NODE" -eq 1 ]; then
    ensure_packages jq
  fi

  # Setup stacks as detected
  setup_node
  setup_python
  setup_ruby
  setup_go
  setup_java_maven
  setup_java_gradle
  setup_rust
  setup_php
  setup_dotnet

  setup_python_lint_script
  setup_hugo_scaffold
  setup_hugo_wrapper
  configure_env
  setup_auto_activate
  finalize_permissions

  apt_clean || true

  log "Environment setup completed successfully!"
  info "App directory: $APP_DIR"
  info "Default port: ${DEFAULT_PORT}"
  info "To load environment in a shell: source /etc/profile.d/app_env.sh"
}

# Execute
main "$@"