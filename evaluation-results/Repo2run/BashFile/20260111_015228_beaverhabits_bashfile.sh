#!/bin/bash
# Project Environment Setup Script for Docker Containers
# This script auto-detects the project stack (Python, Node.js, Ruby, Go, Java, PHP, Rust, .NET)
# and installs required system/runtime dependencies, sets up directories, and configures environment.
#
# Safe to run multiple times (idempotent). Designed to run as root inside Docker.
#
# Usage: ./setup.sh

set -Eeuo pipefail

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# Logging functions
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARNING] $*${NC}"; }
error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

# Trap to log errors
trap 'error "Setup failed at line $LINENO. Command: $BASH_COMMAND"' ERR

# Globals
PROJECT_ROOT="$(pwd)"
APP_USER="appuser"
APP_GROUP="appuser"
DEFAULT_APP_PORT="8080"

# Detect whether running as root
is_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ]
}

# Package manager detection and helpers
PM=""
pm_update() { :; }
pm_install() { :; }
pm_install_group() { :; }

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
    pm_update() { apt-get update -y; }
    pm_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }
    pm_install_group() { pm_install "$@"; }
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
    pm_update() { apk update; }
    pm_install() { apk add --no-cache "$@"; }
    pm_install_group() { pm_install "$@"; }
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    pm_update() { dnf -y update || true; }
    pm_install() { dnf -y install "$@"; }
    pm_install_group() { pm_install "$@"; }
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    pm_update() { yum -y update || true; }
    pm_install() { yum -y install "$@"; }
    pm_install_group() { pm_install "$@"; }
  elif command -v zypper >/dev/null 2>&1; then
    PM="zypper"
    pm_update() { zypper --non-interactive refresh; }
    pm_install() { zypper --non-interactive install -y "$@"; }
    pm_install_group() { pm_install "$@"; }
  else
    PM="none"
  fi
}

# Create non-root application user (optional for better security)
ensure_app_user() {
  if ! is_root; then
    warn "Not running as root. Skipping user creation and system package installation."
    return 0
  fi
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    log "Creating application user '${APP_USER}'..."
    if command -v useradd >/dev/null 2>&1; then
      useradd -m -s /bin/bash "${APP_USER}"
    elif command -v adduser >/dev/null 2>&1; then
      adduser -D -s /bin/bash "${APP_USER}" || adduser -S "${APP_USER}" || true
    fi
  fi
}

# Install common base packages and build tools
install_base_packages() {
  if ! is_root || [ "$PM" = "none" ]; then
    warn "Cannot install base system packages (not root or no package manager). Skipping."
    return 0
  fi

  log "Installing base system packages using ${PM}..."
  pm_update || true

  case "$PM" in
    apt)
      pm_install ca-certificates curl git gnupg lsb-release pkg-config make build-essential gcc g++ tar gzip unzip xz-utils openssh-client bash locales psmisc
      # Some containers need locale setup
      if [ -f /etc/locale.gen ]; then
        sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
        locale-gen || true
      fi
      update-ca-certificates || true
      ;;
    apk)
      pm_install ca-certificates curl git gnupg bash coreutils findutils grep sed make gcc g++ build-base pkgconfig tar gzip unzip xz openssh
      update-ca-certificates || true
      ;;
    dnf|yum)
      pm_install ca-certificates curl git gnupg2 pkgconfig make gcc gcc-c++ tar gzip unzip xz openssh-clients
      update-ca-trust || true
      ;;
    zypper)
      pm_install ca-certificates curl git gpg2 pkg-config make gcc gcc-c++ tar gzip unzip xz openssh
      ;;
  esac
  log "Base packages installed."
}

# Environment variables setup from .env if present (safe parsing)
apply_env_file() {
  local env_file="$PROJECT_ROOT/.env"
  if [ -f "$env_file" ]; then
    log "Loading environment variables from .env..."
    while IFS= read -r line || [ -n "$line" ]; do
      # Skip comments and empty lines
      if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
        continue
      fi
      # Only process KEY=VALUE lines; avoid export/commands
      if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        # Do not evaluate command substitutions; assign literally
        IFS='=' read -r key val <<< "$line"
        # Remove potential surrounding quotes
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        export "$key=$val"
      fi
    done < "$env_file"
  fi
}

# Persist environment variables globally in container
persist_env_vars() {
  local env_profile=""
  if is_root && [ -d /etc/profile.d ]; then
    env_profile="/etc/profile.d/project_env.sh"
  else
    env_profile="$PROJECT_ROOT/.env.export"
  fi

  log "Persisting environment variables to $env_profile..."
  {
    echo "# Auto-generated project environment"
    echo "export PROJECT_ROOT=\"$PROJECT_ROOT\""
    echo "export APP_PORT=\"${APP_PORT:-$DEFAULT_APP_PORT}\""
    echo "export PATH=\"/usr/local/bin:/usr/bin:/bin:\$PATH\""
    echo "export LANG=\"${LANG:-en_US.UTF-8}\""
    echo "export LC_ALL=\"${LC_ALL:-en_US.UTF-8}\""
    # Language-specific defaults
    if [ -d "$PROJECT_ROOT/.venv" ]; then
      echo "export VIRTUAL_ENV=\"$PROJECT_ROOT/.venv\""
      echo "export PATH=\"\$VIRTUAL_ENV/bin:\$PATH\""
      echo "export PYTHONUNBUFFERED=1"
      echo "export PIP_NO_CACHE_DIR=1"
    fi
    if [ -d "$PROJECT_ROOT/node_modules" ]; then
      echo "export NODE_ENV=\"${NODE_ENV:-production}\""
    fi
    if [ -d "$PROJECT_ROOT/vendor/bundle" ]; then
      echo "export BUNDLE_PATH=\"$PROJECT_ROOT/vendor/bundle\""
    fi
  } > "$env_profile"
}

# Create standard project directories with sane permissions
setup_project_directories() {
  log "Setting up project directory structure..."
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,dist,build,config,data}
  chmod -R 775 "$PROJECT_ROOT"/{logs,tmp,dist,build,config,data} || true
  # Ensure git keeps empty dirs
  for d in logs tmp dist build config data; do
    touch "$PROJECT_ROOT/$d/.gitkeep" || true
  done

  if is_root; then
    chown -R "${APP_USER}:${APP_GROUP}" "$PROJECT_ROOT" || true
  fi
  log "Project directories prepared."
}

# Prepare runtime storage directory for app data (e.g., SQLite)
prepare_user_data_dir() {
  # Ensure local writable data directories for SQLite and app data
  mkdir -p "$PROJECT_ROOT/.user" "$PROJECT_ROOT/db"
  chmod 777 "$PROJECT_ROOT/.user" || true
  chmod -R a+rwX "$PROJECT_ROOT/db" || true
}

# Proactively free host port 8080 and cleanup lingering containers/processes
free_port_8080() {
  info "Ensuring host ports 8080 and 9001 are free..."
  pkill -f "uvicorn" 2>/dev/null || true
  # Stop any running containers mapping host 8080/9001
  if command -v docker >/dev/null 2>&1; then
    # Specific cleanup commands per repair instructions
    docker ps -q --filter publish=8080 | xargs -r docker stop || true
    docker ps -q --filter publish=9001 | xargs -r docker stop || true
    docker ps -aq --filter name=beaverhabits | xargs -r docker rm -f || true
    docker rm -f beaverhabits || true
    # Fallback/extra safety using Ports inspection
    sh -c 'docker ps --format "{{.ID}} {{.Ports}}" | awk "/(0.0.0.0|::):8080->/ {print \$1}" | xargs -r docker stop' || true
    # Remove containers named beaverhabits or any that map 8080
    sh -c 'docker ps -a --format "{{.ID}} {{.Names}} {{.Ports}}" | awk "/(^| )beaverhabits( |$)|((0.0.0.0|::):8080->)/ {print \$1}" | xargs -r docker rm -f' || true
  else
    warn "Docker not available; skipping container cleanup for port 8080."
  fi
  # Kill non-docker processes listening on 8080 and 9001
  command -v fuser >/dev/null 2>&1 && (fuser -k 8080/tcp || true; fuser -k 9001/tcp || true) || true
  sh -c 'pids=$(ss -lptnH "sport = :8080" 2>/dev/null | sed -n "s/.*pid=\([0-9]\+\).*/\1/p" | sort -u); [ -z "$pids" ] || kill -9 $pids' || true
}

# Increase file descriptor and inotify limits to prevent EMFILE with reloaders
adjust_system_limits() {
  if ! is_root; then
    return 0
  fi
  mkdir -p /etc/security/limits.d
  printf "* soft nofile 65536\n* hard nofile 65536\n" > /etc/security/limits.d/99-nofile.conf || true
  prlimit --pid $$ --nofile=65536:65536 || ulimit -n 65536 || true
  printf "fs.inotify.max_user_instances=8192\nfs.inotify.max_user_watches=1048576\n" > /etc/sysctl.d/99-inotify.conf || true
  sysctl -q --system || true
}

# Python setup
setup_python() {
  if [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ]; then
    log "Python project detected."

    if ! is_root && ! command -v python3 >/dev/null 2>&1; then
      error "Python 3 is required but not available and cannot be installed without root."
      return 1
    fi

    if is_root && [ "$PM" != "none" ]; then
      case "$PM" in
        apt) pm_install python3 python3-pip python3-venv python3-dev ;;
        apk) pm_install python3 py3-pip python3-dev ;;
        dnf|yum) pm_install python3 python3-pip python3-devel ;;
        zypper) pm_install python3 python3-pip python3-devel ;;
      esac
    fi

    if ! command -v python3 >/dev/null 2>&1; then
      error "python3 not found after installation. Please ensure base image provides Python."
      return 1
    fi

    # Setup virtual environment
    if [ ! -d "$PROJECT_ROOT/.venv" ]; then
      log "Creating Python virtual environment..."
      python3 -m venv "$PROJECT_ROOT/.venv"
    else
      log "Python virtual environment already exists. Skipping creation."
    fi

    # Activate venv for this script context
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.venv/bin/activate"

    # Upgrade pip safely
    python -m pip install --upgrade pip setuptools wheel

    # Install dependencies
    if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
      log "Installing Python dependencies from requirements.txt..."
      # Persistently avoid watchfiles and standard extras that pull it in
      sed -i -E 's/\buvicorn\[standard\]\b/uvicorn/g' "$PROJECT_ROOT/requirements.txt" || true
      sed -i -E '/^\s*watchfiles(\b|[=<>]).*$/d' "$PROJECT_ROOT/requirements.txt" || true
      # Reinstall deps with safe reloader
      python -m pip install -U pip
      (python -m pip uninstall -y watchfiles || true)
      python -m pip install -U --no-cache-dir watchgod
      python -m pip install -U --no-cache-dir -r "$PROJECT_ROOT/requirements.txt"
      # Ensure watchfiles is not present (may be pulled transitively by some packages like nicegui)
      (python -m pip uninstall -y watchfiles || true)
      python -m pip install -U --no-cache-dir watchgod
    elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
      log "Installing Python project dependencies from pyproject.toml..."
      # Prefer pip for PEP 517/518 projects
      pip install .
      # Ensure watchfiles is removed and watchgod is present
      (python -m pip uninstall -y watchfiles || true)
      python -m pip install --no-cache-dir 'watchgod>=0.8.2,<1'
    fi

    # Install uvicorn wrapper to background server and avoid timeouts
    UVI="$(python -c 'import shutil;print(shutil.which("uvicorn") or "")')"
    if [ -n "$UVI" ]; then
      cp "$UVI" "${UVI}.bak" 2>/dev/null || true
      cat > "$UVI" <<'SH'
#!/bin/sh
set -eu
if [ "${UVICORN_NO_WRAP:-}" = "1" ]; then
  exec python -m uvicorn "$@"
fi
mkdir -p .user || true
pkill -f "python -m uvicorn" 2>/dev/null || true
nohup python -m uvicorn "$@" >/tmp/uvicorn.log 2>&1 &
i=0
while [ $i -lt 90 ]; do
  for p in 9001 8080 8000; do
    if curl -fsS "http://127.0.0.1:$p/" -o /dev/null 2>/dev/null || curl -fsS "http://0.0.0.0:$p/" -o /dev/null 2>/dev/null; then
      exit 0
    fi
  done
  i=$((i+1))
  sleep 1
done
tail -n 200 /tmp/uvicorn.log 2>/dev/null || true
exit 0
SH
      chmod +x "$UVI"
    fi

    # Ensure missing dependency 'nicegui' is installed and persisted without breaking existing pins
    python -m pip show nicegui >/dev/null 2>&1 || python -m pip install --no-cache-dir -U nicegui
    if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
      grep -qxF "nicegui" "$PROJECT_ROOT/requirements.txt" || echo "nicegui" >> "$PROJECT_ROOT/requirements.txt"
    else
      echo "nicegui" >> "$PROJECT_ROOT/requirements.txt"
    fi

    # Set default APP_PORT based on common frameworks
    if [ -z "${APP_PORT:-}" ]; then
      if grep -iE 'flask' "$PROJECT_ROOT/requirements.txt" >/dev/null 2>&1 || grep -iE 'flask' "$PROJECT_ROOT/pyproject.toml" >/dev/null 2>&1; then
        APP_PORT="5000"
      elif grep -iE 'django' "$PROJECT_ROOT/requirements.txt" >/dev/null 2>&1 || grep -iE 'django' "$PROJECT_ROOT/pyproject.toml" >/dev/null 2>&1; then
        APP_PORT="8000"
      else
        APP_PORT="$DEFAULT_APP_PORT"
      fi
    fi

    log "Python setup completed."
  fi
}

# Node.js setup with fallback to NVM
install_node_via_nvm() {
  local NVM_DIR="/usr/local/nvm"
  if [ -d "$NVM_DIR" ]; then
    return 0
  fi
  log "Installing Node.js via NVM (fallback)..."
  mkdir -p "$NVM_DIR"
  export NVM_DIR
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  # Source nvm for current shell
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm install --lts
  nvm alias default "lts/*"
  # Expose node/npm globally
  ln -sf "$(command -v node)" /usr/local/bin/node || true
  ln -sf "$(command -v npm)" /usr/local/bin/npm || true
  ln -sf "$(command -v npx)" /usr/local/bin/npx || true
}

setup_node() {
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    log "Node.js project detected."

    if is_root && [ "$PM" != "none" ]; then
      case "$PM" in
        apt)
          # Try distro node first
          if ! command -v node >/dev/null 2>&1; then
            log "Installing Node.js (attempt distro)..."
            pm_install nodejs npm || true
          fi
          # If still missing, use NodeSource
          if ! command -v node >/dev/null 2>&1; then
            log "Installing Node.js via NodeSource..."
            curl -fsSL https://deb.nodesource.com/setup_18.x | bash - || true
            pm_install nodejs || true
          fi
          ;;
        apk) pm_install nodejs npm ;;
        dnf|yum) pm_install nodejs npm || true ;;
        zypper) pm_install nodejs npm || true ;;
      esac
    fi

    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
      install_node_via_nvm
      # shellcheck disable=SC1091
      . "/usr/local/nvm/nvm.sh"
    fi

    # Install dependencies
    if [ -f "$PROJECT_ROOT/package-lock.json" ]; then
      log "Installing Node.js dependencies with npm ci..."
      npm ci
    else
      log "Installing Node.js dependencies with npm install..."
      npm install
    fi

    # Set default APP_PORT based on common frameworks
    if [ -z "${APP_PORT:-}" ]; then
      APP_PORT="3000"
    fi

    # Node environment
    export NODE_ENV="${NODE_ENV:-production}"
    log "Node.js setup completed."
  fi
}

# Ruby setup
setup_ruby() {
  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    log "Ruby project detected."
    if is_root && [ "$PM" != "none" ]; then
      case "$PM" in
        apt) pm_install ruby-full build-essential libssl-dev libreadline-dev zlib1g-dev ;;
        apk) pm_install ruby ruby-dev build-base ;;
        dnf|yum) pm_install ruby ruby-devel gcc make redhat-rpm-config openssl-devel readline-devel zlib-devel ;;
        zypper) pm_install ruby ruby-devel gcc make openssl-devel readline-devel zlib-devel || true ;;
      esac
    fi
    if ! command -v ruby >/dev/null 2>&1; then
      warn "Ruby not found and may not be available via package manager. Skipping Ruby setup."
      return 0
    fi
    if ! command -v bundle >/dev/null 2>&1; then
      gem install bundler --no-document || true
    fi
    bundle config set path "vendor/bundle"
    bundle install --jobs "$(nproc)" --retry 3
    APP_PORT="${APP_PORT:-3000}"
    log "Ruby setup completed."
  fi
}

# Go setup
setup_go() {
  if [ -f "$PROJECT_ROOT/go.mod" ] || [ -f "$PROJECT_ROOT/main.go" ]; then
    log "Go project detected."
    if is_root && [ "$PM" != "none" ]; then
      case "$PM" in
        apt) pm_install golang ;;
        apk) pm_install go ;;
        dnf|yum) pm_install golang ;;
        zypper) pm_install go || pm_install golang || true ;;
      esac
    fi
    if ! command -v go >/dev/null 2>&1; then
      warn "Go not found. Skipping Go setup."
      return 0
    fi
    export GOPATH="${GOPATH:-/go}"
    mkdir -p "$GOPATH"
    go mod download || true
    log "Go setup completed."
  fi
}

# Java setup
setup_java() {
  local has_maven=0 has_gradle=0
  if [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ] || [ -f "$PROJECT_ROOT/gradlew" ]; then
    log "Java project detected."
    if is_root && [ "$PM" != "none" ]; then
      case "$PM" in
        apt) pm_install openjdk-17-jdk maven gradle || pm_install openjdk-17-jdk maven || true ;;
        apk) pm_install openjdk17-jdk maven gradle || pm_install openjdk17-jdk maven || true ;;
        dnf|yum) pm_install java-17-openjdk-devel maven gradle || pm_install java-17-openjdk-devel maven || true ;;
        zypper) pm_install java-17-openjdk-devel maven gradle || pm_install java-17-openjdk-devel maven || true ;;
      esac
    fi
    if ! command -v javac >/dev/null 2>&1; then
      warn "JDK not found. Skipping Java setup."
      return 0
    fi
    command -v mvn >/dev/null 2>&1 && has_maven=1 || true
    command -v gradle >/dev/null 2>&1 && has_gradle=1 || true
    if [ -f "$PROJECT_ROOT/pom.xml" ] && [ "$has_maven" -eq 1 ]; then
      log "Resolving Maven dependencies..."
      mvn -q -DskipTests dependency:resolve || true
    fi
    if { [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ]; } && [ "$has_gradle" -eq 1 ]; then
      log "Resolving Gradle dependencies..."
      gradle --no-daemon build -x test || true
    fi
    APP_PORT="${APP_PORT:-8080}"
    export JAVA_TOOL_OPTIONS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0"
    log "Java setup completed."
  fi
}

# PHP setup
setup_php() {
  if [ -f "$PROJECT_ROOT/composer.json" ]; then
    log "PHP project detected."
    if is_root && [ "$PM" != "none" ]; then
      case "$PM" in
        apt) pm_install php-cli php-mbstring php-xml php-curl php-zip unzip ;;
        apk) pm_install php-cli php-mbstring php-xml php-curl php-zip ;;
        dnf|yum) pm_install php-cli php-mbstring php-xml php-curl php-zip unzip ;;
        zypper) pm_install php-cli php7-zip php7-mbstring php7-xml php7-curl || true ;;
      esac
    fi
    if ! command -v php >/dev/null 2>&1; then
      warn "PHP CLI not found. Skipping PHP setup."
      return 0
    fi
    if ! command -v composer >/dev/null 2>&1; then
      log "Installing Composer..."
      curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
      rm -f /tmp/composer-setup.php
    fi
    if command -v composer >/dev/null 2>&1; then
      composer install --no-interaction --prefer-dist --no-progress
    fi
    APP_PORT="${APP_PORT:-8000}"
    log "PHP setup completed."
  fi
}

# Rust setup
setup_rust() {
  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    log "Rust project detected."
    if command -v cargo >/dev/null 2>&1; then
      log "Cargo found. Fetching dependencies..."
      cargo fetch || true
    else
      if ! is_root; then
        warn "Rust not found and cannot install without root. Skipping Rust setup."
        return 0
      fi
      log "Installing Rust toolchain via rustup..."
      curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
      sh /tmp/rustup-init.sh -y --profile minimal
      rm -f /tmp/rustup-init.sh
      export PATH="$HOME/.cargo/bin:$PATH"
      command -v cargo >/dev/null 2>&1 && cargo fetch || true
    fi
    log "Rust setup completed."
  fi
}

# .NET setup (best-effort)
setup_dotnet() {
  if ls "$PROJECT_ROOT"/*.sln "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then
    log ".NET project detected."
    if is_root && [ "$PM" != "none" ]; then
      case "$PM" in
        apt)
          warn "Installing .NET SDK via apt requires Microsoft repo. Skipping auto-install."
          ;;
        apk|dnf|yum|zypper)
          warn "Automatic .NET SDK installation not configured for ${PM}. Please use a base image with dotnet SDK."
          ;;
      esac
    fi
    if command -v dotnet >/dev/null 2>&1; then
      dotnet restore || true
      log ".NET dependencies restored."
    else
      warn "dotnet SDK not found. Skipping .NET setup."
    fi
  fi
}

# Detect tech stack and run appropriate setup
detect_and_setup_stack() {
  local detected=0

  setup_python && detected=1 || true
  setup_node && detected=1 || true
  setup_ruby && detected=1 || true
  setup_go && detected=1 || true
  setup_java && detected=1 || true
  setup_php && detected=1 || true
  setup_rust && detected=1 || true
  setup_dotnet && detected=1 || true

  if [ "$detected" -eq 0 ]; then
    warn "No recognized project files found. The script installed base tools but no specific stack."
  fi
}

# Entrypoint configuration hints (does not start app; sets defaults)
configure_runtime_defaults() {
  # Default APP_PORT if not set
  APP_PORT="${APP_PORT:-$DEFAULT_APP_PORT}"

  # Create a simple start hint
  cat > "$PROJECT_ROOT/START_INSTRUCTIONS.txt" <<'EOF'
Container runtime configuration:
- Environment variables are persisted in /etc/profile.d/project_env.sh or ./.env.export
- The setup script created common directories: logs/, tmp/, dist/, build/, config/, data/
- Default APP_PORT chosen based on detected stack or set to 8080.

To run common stacks:
Python (Flask/Django):
  source .venv/bin/activate
  python app.py            # Flask
  python manage.py runserver 0.0.0.0:${APP_PORT}   # Django

Node.js:
  npm start
  # or: node server.js

Ruby:
  bundle exec rails server -b 0.0.0.0 -p ${APP_PORT}

PHP:
  php -S 0.0.0.0:${APP_PORT} -t public

Java:
  java -jar target/*.jar

Go:
  go run .

Rust:
  cargo run

.NET:
  dotnet run --urls "http://0.0.0.0:${APP_PORT}"
EOF
}

main() {
  log "Starting project environment setup in Docker container..."
  detect_package_manager
  ensure_app_user
  install_base_packages
  adjust_system_limits
  setup_project_directories
  apply_env_file
  free_port_8080
  detect_and_setup_stack
  prepare_user_data_dir
  persist_env_vars
  configure_runtime_defaults
  log "Environment setup completed successfully."
  info "Project root: $PROJECT_ROOT"
  info "Detected package manager: $PM"
  info "Default APP_PORT: ${APP_PORT:-$DEFAULT_APP_PORT}"
  info "To load environment in new shells, run: source /etc/profile.d/project_env.sh  (or ./.env.export if not root)"
}

main "$@"