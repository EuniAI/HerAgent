#!/bin/bash
# Environment setup script for containerized projects
# Detects common stacks (Python, Node.js, Ruby, Go, Java, Rust, PHP) and installs required runtimes and dependencies.
# Designed to run as root inside Docker containers without sudo.

set -Eeuo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
PROJECT_DIR="$(pwd)"
APP_USER="${APP_USER:-appuser}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-0}"             # Will be set based on project type if 0
PKG_MGR=""
NONINTERACTIVE="${NONINTERACTIVE:-1}"  # Always non-interactive for containers
LOG_FILE="${LOG_FILE:-/var/log/app_env_setup.log}"

# Trap and error handling
err() {
  local exit_code=$?
  echo -e "${RED}[ERROR] Command failed at line $1 with exit code $exit_code${NC}" | tee -a "$LOG_FILE" >&2
  exit "$exit_code"
}
trap 'err $LINENO' ERR

log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"
}

warn() {
  echo -e "${YELLOW}[WARNING] $*${NC}" | tee -a "$LOG_FILE" >&2
}

info() {
  echo -e "${BLUE}[INFO] $*${NC}" | tee -a "$LOG_FILE"
}

# Ensure running as root (Docker default)
ensure_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}[ERROR] This script must be run as root inside the container.${NC}" >&2
    exit 1
  fi
}

# Detect package manager (supports apt, apk, dnf/yum)
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    export DEBIAN_FRONTEND=noninteractive
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    echo -e "${RED}[ERROR] No supported package manager found (apt, apk, dnf, yum).${NC}" >&2
    exit 1
  fi
  log "Detected package manager: $PKG_MGR"
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      apt-get update -y -qq
      ;;
    apk)
      apk update || true
      ;;
    dnf)
      dnf -y -q makecache || dnf -y -q check-update || true
      ;;
    yum)
      yum -y -q makecache || yum -y -q check-update || true
      ;;
  esac
}

pkg_install() {
  # Accept packages as arguments
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf)
      dnf install -y -q "$@"
      ;;
    yum)
      yum install -y -q "$@"
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      rm -rf /var/cache/apk/*
      ;;
    dnf|yum)
      # Keep cache to avoid repeated downloads; containers often ephemeral anyway
      :
      ;;
  esac
}

# Base system tools and build dependencies
install_base_tools() {
  log "Installing base system tools and build dependencies..."
  pkg_update

  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git bash tzdata locales \
                  build-essential pkg-config gcc g++ make \
                  openssl libssl-dev libffi-dev zlib1g-dev xz-utils unzip tar
      ;;
    apk)
      pkg_install ca-certificates curl wget git bash tzdata \
                  build-base pkgconf \
                  openssl openssl-dev libffi-dev zlib-dev xz unzip tar
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git bash tzdata \
                  gcc gcc-c++ make which openssl openssl-devel libffi-devel zlib-devel xz unzip tar
      # Development tools group may not exist in minimal images; skip groupinstall to keep general
      ;;
  esac
  update-ca-certificates || true
  pkg_clean
  log "Base system tools installed."
}

# Create non-root application user for security
create_app_user() {
  log "Ensuring application user '$APP_USER' exists..."
  if id -u "$APP_USER" >/dev/null 2>&1; then
    info "User '$APP_USER' already exists."
  else
    # Create group if not exists
    if ! getent group "$APP_GID" >/dev/null 2>&1; then
      groupadd -g "$APP_GID" "$APP_USER" || groupadd "$APP_USER"
    fi

    # Create user
    if ! getent passwd "$APP_UID" >/dev/null 2>&1; then
      useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER"
    else
      # UID is in use; create with next available UID
      useradd -m -g "$APP_GID" -s /bin/bash "$APP_USER"
    fi
    log "Created user '$APP_USER' (uid=$(id -u "$APP_USER"), gid=$(id -g "$APP_USER"))."
  fi
  chown -R "$APP_USER":"$APP_USER" "$PROJECT_DIR" || true
}

# Project structure
setup_directories() {
  log "Setting up project directory structure..."
  mkdir -p "$PROJECT_DIR"/{logs,tmp,run,data,.cache}
  chown -R "$APP_USER":"$APP_USER" "$PROJECT_DIR"/{logs,tmp,run,data,.cache} || true
  chmod 755 "$PROJECT_DIR"
  chmod 700 "$PROJECT_DIR"/tmp || true
  log "Project directories created: logs, tmp, run, data, .cache"
}

# Detect project type based on common files
PROJECT_TYPE=""
detect_project_type() {
  if [ -f "$PROJECT_DIR/requirements.txt" ] || [ -f "$PROJECT_DIR/pyproject.toml" ]; then
    PROJECT_TYPE="python"
    [ "$APP_PORT" = "0" ] && APP_PORT="5000"
  elif [ -f "$PROJECT_DIR/package.json" ]; then
    PROJECT_TYPE="node"
    [ "$APP_PORT" = "0" ] && APP_PORT="3000"
  elif [ -f "$PROJECT_DIR/Gemfile" ]; then
    PROJECT_TYPE="ruby"
    [ "$APP_PORT" = "0" ] && APP_PORT="3000"
  elif [ -f "$PROJECT_DIR/go.mod" ]; then
    PROJECT_TYPE="go"
    [ "$APP_PORT" = "0" ] && APP_PORT="8080"
  elif [ -f "$PROJECT_DIR/pom.xml" ] || [ -f "$PROJECT_DIR/build.gradle" ] || [ -f "$PROJECT_DIR/gradlew" ]; then
    PROJECT_TYPE="java"
    [ "$APP_PORT" = "0" ] && APP_PORT="8080"
  elif [ -f "$PROJECT_DIR/Cargo.toml" ]; then
    PROJECT_TYPE="rust"
    [ "$APP_PORT" = "0" ] && APP_PORT="8080"
  elif [ -f "$PROJECT_DIR/composer.json" ]; then
    PROJECT_TYPE="php"
    [ "$APP_PORT" = "0" ] && APP_PORT="8000"
  else
    PROJECT_TYPE="unknown"
    [ "$APP_PORT" = "0" ] && APP_PORT="8080"
  fi
  log "Detected project type: $PROJECT_TYPE (port: $APP_PORT)"
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel
      # venv usually included in python3 standard library
      ;;
  esac

  # Create venv idempotently
  if [ ! -d "$PROJECT_DIR/.venv" ]; then
    python3 -m venv "$PROJECT_DIR/.venv"
    log "Created Python virtual environment at .venv"
  else
    info "Python virtual environment already exists at .venv"
  fi

  # Activate venv in subshell for pip operations
  set +u
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/.venv/bin/activate"
  set -u

  # Upgrade pip/setuptools/wheel
  python -m pip install --no-cache-dir --upgrade pip setuptools wheel
  python -m pip install --no-cache-dir --pre "pydantic>=2,<3"

  if [ -f "$PROJECT_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    PIP_CONSTRAINT="${PIP_CONSTRAINT:-}"
    if [ -n "$PIP_CONSTRAINT" ] && [ -f "$PIP_CONSTRAINT" ]; then
      pip install --no-cache-dir -r requirements.txt -c "$PIP_CONSTRAINT"
    else
      pip install --no-cache-dir -r requirements.txt
    fi
  elif [ -f "$PROJECT_DIR/pyproject.toml" ]; then
    log "Installing Python project from pyproject.toml (with extras)..."
    if ! python -m pip install --no-cache-dir -U -e '.[docs,testing]'; then
      warn "Extras install failed; falling back to standard editable install."
      python -m pip install --no-cache-dir -e "$PROJECT_DIR"
    fi
  else
    warn "No Python dependency file found (requirements.txt or pyproject.toml)."
  fi

  # Ensure cryptographic/backends available for tests and runtime
  python -m pip install --no-cache-dir -U "python-multipart" "python-jose[cryptography]" "passlib[bcrypt]" "pyjwt" "twilio" "phonenumbers" "flaml[automl]"
  python -m pip install --no-cache-dir -U gunicorn uvicorn watchgod
  python -c "import sysconfig,os,pathlib; sp=(sysconfig.get_paths().get('purelib') or sysconfig.get_paths().get('platlib')); p=pathlib.Path(sp)/'local_repo_paths.pth'; root=os.getcwd(); candidates=[root, os.path.join(root,'examples'), os.path.join(root,'apps')]; path_lines=''.join(path+'\n' for path in candidates if os.path.isdir(path)); path_lines and open(p,'w').write(path_lines); print(f'Wrote to {p}:\n'+path_lines if path_lines else f'No candidate paths created .pth at {p} but found none to add')"

  deactivate || true
  pkg_clean
  log "Python environment setup complete."
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
  esac

  # Install dependencies
  if [ -f "$PROJECT_DIR/package-lock.json" ]; then
    log "Installing Node.js dependencies (npm ci)..."
    npm ci --prefix "$PROJECT_DIR"
  else
    log "Installing Node.js dependencies (npm install)..."
    npm install --prefix "$PROJECT_DIR"
  fi

  # Install Yarn if yarn.lock exists but yarn missing
  if [ -f "$PROJECT_DIR/yarn.lock" ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      log "Installing Yarn globally via npm..."
      npm install -g yarn
    fi
    log "Installing dependencies using yarn..."
    (cd "$PROJECT_DIR" && yarn install --frozen-lockfile || yarn install)
  fi

  pkg_clean
  log "Node.js environment setup complete."
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full ruby-dev
      ;;
    apk)
      pkg_install ruby ruby-dev
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel
      ;;
  esac

  # Install bundler gem idempotently
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  if [ -f "$PROJECT_DIR/Gemfile" ]; then
    log "Installing Ruby gems with Bundler..."
    (cd "$PROJECT_DIR" && bundle config set --local path "vendor/bundle" && bundle install --jobs "$(nproc)" --retry 3)
  else
    warn "No Gemfile found for Ruby project."
  fi

  pkg_clean
  log "Ruby environment setup complete."
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum)
      pkg_install golang
      ;;
  esac

  # Configure GOPATH and cache
  local home_dir="/home/$APP_USER"
  mkdir -p "$home_dir/go" "$PROJECT_DIR/.cache/go"
  chown -R "$APP_USER":"$APP_USER" "$home_dir/go" "$PROJECT_DIR/.cache/go" || true

  if [ -f "$PROJECT_DIR/go.mod" ]; then
    log "Downloading Go module dependencies..."
    (cd "$PROJECT_DIR" && GOCACHE="$PROJECT_DIR/.cache/go" GOPATH="$home_dir/go" go mod download)
  else
    warn "No go.mod found for Go project."
  fi

  pkg_clean
  log "Go environment setup complete."
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install openjdk-17-jdk
      ;;
    apk)
      pkg_install openjdk17
      ;;
    dnf|yum)
      pkg_install java-17-openjdk java-17-openjdk-devel || pkg_install java-11-openjdk java-11-openjdk-devel
      ;;
  esac

  if [ -f "$PROJECT_DIR/pom.xml" ]; then
    log "Maven project detected."
    case "$PKG_MGR" in
      apt) pkg_install maven ;;
      apk) pkg_install maven ;;
      dnf|yum) pkg_install maven ;;
    esac
    log "Resolving Maven dependencies..."
    (cd "$PROJECT_DIR" && mvn -B -DskipTests dependency:resolve || true)
  fi

  if [ -f "$PROJECT_DIR/build.gradle" ] || [ -f "$PROJECT_DIR/gradlew" ]; then
    log "Gradle project detected."
    if [ -x "$PROJECT_DIR/gradlew" ]; then
      (cd "$PROJECT_DIR" && ./gradlew --no-daemon tasks || true)
    else
      case "$PKG_MGR" in
        apt) pkg_install gradle ;;
        apk) pkg_install gradle ;;
        dnf|yum) pkg_install gradle ;;
      esac
      (cd "$PROJECT_DIR" && gradle --no-daemon tasks || true)
    fi
  fi

  pkg_clean
  log "Java environment setup complete."
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install rustc cargo
      ;;
    apk)
      pkg_install rust cargo
      ;;
    dnf|yum)
      pkg_install rust cargo
      ;;
  esac

  if [ -f "$PROJECT_DIR/Cargo.toml" ]; then
    log "Fetching Rust crate dependencies..."
    (cd "$PROJECT_DIR" && cargo fetch)
  else
    warn "No Cargo.toml found for Rust project."
  fi

  pkg_clean
  log "Rust environment setup complete."
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip composer
      ;;
    apk)
      pkg_install php php-cli php-mbstring php-xml php-curl php-zip composer
      ;;
    dnf|yum)
      pkg_install php-cli php-mbstring php-xml php-json php-zip composer || pkg_install php-cli composer
      ;;
  esac

  if [ -f "$PROJECT_DIR/composer.json" ]; then
    log "Installing PHP dependencies with Composer..."
    (cd "$PROJECT_DIR" && composer install --no-interaction --prefer-dist)
  else
    warn "No composer.json found for PHP project."
  fi

  pkg_clean
  log "PHP environment setup complete."
}

# Configure environment variables and .env file
configure_env() {
  log "Configuring environment variables..."
  # Common environment variables
  export APP_ENV="$APP_ENV"
  export APP_PORT="$APP_PORT"
  export PROJECT_DIR="$PROJECT_DIR"
  export PATH="$PROJECT_DIR/.bin:$PATH"

  # Language-specific env hints
  case "$PROJECT_TYPE" in
    python)
      export PYTHONUNBUFFERED=1
      export PIP_DISABLE_PIP_VERSION_CHECK=1
      export VIRTUAL_ENV="$PROJECT_DIR/.venv"
      ;;
    node)
      export NODE_ENV="$APP_ENV"
      ;;
    ruby)
      export RACK_ENV="$APP_ENV"
      export RAILS_ENV="$APP_ENV"
      ;;
    go)
      export GOPATH="/home/$APP_USER/go"
      export GOCACHE="$PROJECT_DIR/.cache/go"
      ;;
    java)
      export JAVA_TOOL_OPTIONS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
      ;;
    rust)
      export CARGO_HOME="/home/$APP_USER/.cargo"
      ;;
    php)
      export APP_ENV="$APP_ENV"
      ;;
  esac

  # Write .env (idempotent: update or create)
  local env_file="$PROJECT_DIR/.env"
  touch "$env_file"
  # Remove existing keys we manage, then append fresh values
  sed -i '/^APP_ENV=/d' "$env_file" || true
  sed -i '/^APP_PORT=/d' "$env_file" || true
  sed -i '/^PROJECT_DIR=/d' "$env_file" || true
  sed -i '/^PYTHONUNBUFFERED=/d' "$env_file" || true
  sed -i '/^NODE_ENV=/d' "$env_file" || true
  sed -i '/^RACK_ENV=/d' "$env_file" || true
  sed -i '/^RAILS_ENV=/d' "$env_file" || true
  sed -i '/^GOPATH=/d' "$env_file" || true
  sed -i '/^GOCACHE=/d' "$env_file" || true
  sed -i '/^JAVA_TOOL_OPTIONS=/d' "$env_file" || true
  sed -i '/^CARGO_HOME=/d' "$env_file" || true
  {
    echo "APP_ENV=$APP_ENV"
    echo "APP_PORT=$APP_PORT"
    echo "PROJECT_DIR=$PROJECT_DIR"
    case "$PROJECT_TYPE" in
      python)
        echo "PYTHONUNBUFFERED=1"
        ;;
      node)
        echo "NODE_ENV=$APP_ENV"
        ;;
      ruby)
        echo "RACK_ENV=$APP_ENV"
        echo "RAILS_ENV=$APP_ENV"
        ;;
      go)
        echo "GOPATH=/home/$APP_USER/go"
        echo "GOCACHE=$PROJECT_DIR/.cache/go"
        ;;
      java)
        echo "JAVA_TOOL_OPTIONS=-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
        ;;
      rust)
        echo "CARGO_HOME=/home/$APP_USER/.cargo"
        ;;
      php)
        echo "APP_ENV=$APP_ENV"
        ;;
    esac
  } >> "$env_file"

  chown "$APP_USER":"$APP_USER" "$env_file" || true
  chmod 640 "$env_file" || true
  log "Environment variables configured and written to .env."
}

# Patch pytest marker quoting in scripts/test.sh
patch_test_wrapper() {
  local test_script_path="$PROJECT_DIR/scripts/test.sh"
  if [ -f "$test_script_path" ]; then
    cp -f "$test_script_path" "${test_script_path}.bak" || true
    sed -i -E 's/(-m[[:space:]]+)\$([A-Za-z_][A-Za-z0-9_]*)/\1"\$\2"/g' "$test_script_path" || true
    chmod +x "$test_script_path" || true
  fi
}

# Auto-activate venv in bashrc for root and app user
setup_auto_activate() {
  local venv_dir="$PROJECT_DIR/.venv"
  local project_path="$PROJECT_DIR"
  local bashrc_files=("/root/.bashrc" "/home/$APP_USER/.bashrc")
  for bashrc_file in "${bashrc_files[@]}"; do
    local activate_line=". \"$venv_dir/bin/activate\""
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      mkdir -p "$(dirname "$bashrc_file")" 2>/dev/null || true
      touch "$bashrc_file" 2>/dev/null || true
      {
        echo ""
        echo "# Auto-activate project venv"
        echo "if [ -d \"$venv_dir\" ] && [ -f \"$venv_dir/bin/activate\" ]; then $activate_line; fi"
        echo "export PYTHONPATH=$project_path:\${PYTHONPATH}"
      } >> "$bashrc_file"
      if [[ "$bashrc_file" == "/home/$APP_USER/.bashrc" ]]; then
        chown "$APP_USER":"$APP_USER" "$bashrc_file" 2>/dev/null || true
      fi
    fi
  done
}

# Free port 8000 and clean conflicting containers/processes
free_port_8000() {
  # Stop potentially conflicting container if Docker is available
  if command -v docker >/dev/null 2>&1; then
    docker rm -f deploy_fastagency >/dev/null 2>&1 || true
    docker ps -aq -f name=^deploy_fastagency$ | xargs -r docker stop || true
  fi

  # Ensure lsof/psmisc are available for port checks
  if ! command -v lsof >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apt)
        pkg_update
        pkg_install lsof psmisc || true
        ;;
      apk)
        pkg_install lsof psmisc || true
        ;;
      dnf|yum)
        pkg_install lsof psmisc || true
        ;;
    esac
  fi

  # Kill any process bound to TCP ports 8000, 8008, 8888
  for p in 8000 8008 8888; do
    (fuser -k -n tcp "$p" 2>/dev/null || true)
    (lsof -ti tcp:"$p" 2>/dev/null | xargs -r kill -9 || true)
  done
}

# Main
main() {
  ensure_root

  # Prepare log file
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE" || true

  log "Starting environment setup for project at: $PROJECT_DIR"
  detect_pkg_mgr
  install_base_tools
  free_port_8000
  create_app_user
  setup_directories
  detect_project_type

  case "$PROJECT_TYPE" in
    python) setup_python ;;
    node)   setup_node ;;
    ruby)   setup_ruby ;;
    go)     setup_go ;;
    java)   setup_java ;;
    rust)   setup_rust ;;
    php)    setup_php ;;
    *)
      warn "Unknown project type. Installed base tools only. Provide project context or ensure dependency files exist."
      ;;
  esac

  configure_env
  setup_auto_activate
  patch_test_wrapper

  # Final ownership to app user
  chown -R "$APP_USER":"$APP_USER" "$PROJECT_DIR" || true

  log "Environment setup completed successfully."
  info "Summary:"
  info "  Project directory: $PROJECT_DIR"
  info "  Project type: $PROJECT_TYPE"
  info "  App user: $APP_USER (uid=$(id -u "$APP_USER"), gid=$(id -g "$APP_USER"))"
  info "  Port: $APP_PORT"
  info "  Environment: $APP_ENV"
  info "  .env written at: $PROJECT_DIR/.env"

  info "To run as non-root inside the container, you can use: su -s /bin/bash -c '<start command>' $APP_USER"
  case "$PROJECT_TYPE" in
    python)
      info "Example start command: source .venv/bin/activate && python app.py (or flask run --host=0.0.0.0 --port=$APP_PORT)"
      ;;
    node)
      info "Example start command: npm start --prefix '$PROJECT_DIR'"
      ;;
    ruby)
      info "Example start command: bundle exec rails server -b 0.0.0.0 -p $APP_PORT"
      ;;
    go)
      info "Example start command: go run ./..."
      ;;
    java)
      info "Example start command (Maven): mvn -B spring-boot:run -Dspring-boot.run.arguments=--server.port=$APP_PORT"
      ;;
    rust)
      info "Example start command: cargo run"
      ;;
    php)
      info "Example start command: php -S 0.0.0.0:$APP_PORT -t public"
      ;;
    *)
      info "Please provide a start command appropriate for your project."
      ;;
  esac
}

main "$@"