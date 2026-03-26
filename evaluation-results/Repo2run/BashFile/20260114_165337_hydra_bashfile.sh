#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types (Python, Node.js, Go, Rust, Java, PHP, Ruby)
# - Installs system packages and language runtimes as needed
# - Configures dependencies, environment variables, and directory structure
# - Designed to run as root inside minimal Docker base images
# - Safe to re-run (idempotent), with logging and error handling

set -Eeuo pipefail
IFS=$'\n\t'

# Colors (may be ignored by some terminals)
RED="$(printf '\033[0;31m')" || true
GREEN="$(printf '\033[0;32m')" || true
YELLOW="$(printf '\033[1;33m')" || true
NC="$(printf '\033[0m')" || true

# Global defaults
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
STATE_DIR="${PROJECT_ROOT}/.setup_state"
LOG_FILE="${PROJECT_ROOT}/setup.log"
APP_USER="${APP_USER:-app}"
USE_NON_ROOT="${USE_NON_ROOT:-false}"

# Trap for errors and exit
on_error() {
  local exit_code=$?
  echo -e "${RED}[ERROR] Setup failed with exit code ${exit_code}${NC}" | tee -a "$LOG_FILE" >&2
  echo -e "${YELLOW}Check the log at: ${LOG_FILE}${NC}" >&2
  exit $exit_code
}
on_exit() {
  echo -e "${GREEN}Setup script finished at $(date -u +'%Y-%m-%dT%H:%M:%SZ')${NC}" | tee -a "$LOG_FILE"
}
trap on_error ERR
trap on_exit EXIT

# Logging helpers
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" | tee -a "$LOG_FILE" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" | tee -a "$LOG_FILE" >&2; }

# Idempotent state marker
mark_done() {
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/$1"
}
is_done() {
  [[ -f "$STATE_DIR/$1" ]]
}

# Utilities
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}
ensure_dir() {
  mkdir -p "$@"
}

# Detect package manager
PKG_MGR=""
PKG_INSTALL=""
PKG_UPDATE=""
PKG_GROUP_BUILD=""
detect_pkg_manager() {
  if need_cmd apt-get; then
    PKG_MGR="apt"
    PKG_UPDATE="DEBIAN_FRONTEND=noninteractive apt-get update -y"
    PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
    PKG_GROUP_BUILD=""
  elif need_cmd apk; then
    PKG_MGR="apk"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_GROUP_BUILD=""
  elif need_cmd dnf; then
    PKG_MGR="dnf"
    PKG_UPDATE="dnf -y makecache"
    PKG_INSTALL="dnf install -y"
    PKG_GROUP_BUILD="dnf groupinstall -y 'Development Tools'"
  elif need_cmd yum; then
    PKG_MGR="yum"
    PKG_UPDATE="yum makecache -y"
    PKG_INSTALL="yum install -y"
    PKG_GROUP_BUILD="yum groupinstall -y 'Development Tools'"
  elif need_cmd zypper; then
    PKG_MGR="zypper"
    PKG_UPDATE="zypper refresh"
    PKG_INSTALL="zypper install -y --no-recommends"
    PKG_GROUP_BUILD=""
  else
    err "No supported package manager found (apt, apk, dnf, yum, zypper)."
    exit 1
  fi
  log "Detected package manager: ${PKG_MGR}"
}

# Update package index idempotently for apt
update_pkg_index() {
  if [[ "$PKG_MGR" == "apt" ]]; then
    # Update only if lists are empty or older than 1 day
    if [[ ! -d /var/lib/apt/lists ]] || [[ -z "$(ls -A /var/lib/apt/lists 2>/dev/null || true)" ]] || find /var/lib/apt/lists -type f -mtime +1 | grep -q .; then
      eval "$PKG_UPDATE"
    fi
  else
    eval "$PKG_UPDATE"
  fi
}

# Install base tools common across stacks
install_base_tools() {
  if is_done "base_tools"; then
    log "Base tools already installed."
    return
  fi

  log "Installing base system tools..."
  update_pkg_index

  case "$PKG_MGR" in
    apt)
      eval "$PKG_INSTALL ca-certificates curl wget git bash coreutils grep sed gawk tar gzip unzip xz-utils openssl pkg-config make gcc g++ file"
      ;;
    apk)
      eval "$PKG_INSTALL ca-certificates curl wget git bash coreutils grep sed awk tar gzip unzip xz openssl pkgconf make gcc g++ musl-dev file"
      ;;
    dnf|yum)
      eval "$PKG_INSTALL ca-certificates curl wget git bash coreutils grep sed gawk tar gzip unzip xz openssl pkgconf-pkg-config make gcc gcc-c++ file"
      [[ -n "$PKG_GROUP_BUILD" ]] && eval "$PKG_GROUP_BUILD" || true
      ;;
    zypper)
      eval "$PKG_INSTALL ca-certificates curl wget git bash coreutils grep sed gawk tar gzip unzip xz openssl pkg-config make gcc gcc-c++ file"
      ;;
  esac

  update_ca_certificates || true
  mark_done "base_tools"
}

update_ca_certificates() {
  if need_cmd update-ca-certificates; then
    update-ca-certificates
  elif need_cmd update-ca-trust; then
    update-ca-trust
  fi
}

# Project type detectors
is_python_project() { [[ -f "${PROJECT_ROOT}/requirements.txt" || -f "${PROJECT_ROOT}/pyproject.toml" || -f "${PROJECT_ROOT}/Pipfile" ]]; }
is_node_project()   { [[ -f "${PROJECT_ROOT}/package.json" ]]; }
is_go_project()     { [[ -f "${PROJECT_ROOT}/go.mod" ]]; }
is_rust_project()   { [[ -f "${PROJECT_ROOT}/Cargo.toml" ]]; }
is_java_project()   { [[ -f "${PROJECT_ROOT}/pom.xml" || -f "${PROJECT_ROOT}/build.gradle" || -f "${PROJECT_ROOT}/gradlew" ]]; }
is_php_project()    { [[ -f "${PROJECT_ROOT}/composer.json" ]]; }
is_ruby_project()   { [[ -f "${PROJECT_ROOT}/Gemfile" ]]; }

# Runtime installers
install_python_runtime() {
  if is_done "python_runtime"; then
    log "Python runtime already set."
    return
  fi
  log "Installing Python runtime and build deps..."
  case "$PKG_MGR" in
    apt)
      # Prefer Python 3.11 from deadsnakes to avoid building ML wheels on 3.12
      eval "$PKG_UPDATE"
      eval "$PKG_INSTALL software-properties-common"
      add-apt-repository -y ppa:deadsnakes/ppa || true
      eval "$PKG_UPDATE"
      eval "$PKG_INSTALL python3.11 python3.11-venv python3.11-dev libffi-dev libssl-dev zlib1g-dev libjpeg-dev build-essential"
      # Ensure pip available outside venv (optional)
      eval "$PKG_INSTALL python3-pip" || true
      ;;
    apk)
      eval "$PKG_INSTALL python3 py3-pip py3-virtualenv python3-dev libffi-dev openssl-dev zlib-dev jpeg-dev build-base"
      ;;
    dnf|yum)
      eval "$PKG_INSTALL python3 python3-pip python3-devel libffi-devel openssl-devel zlib-devel gcc gcc-c++ make"
      ;;
    zypper)
      eval "$PKG_INSTALL python3 python3-pip python3-devel libffi-devel libopenssl-devel zlib-devel gcc gcc-c++ make"
      ;;
  esac
  mark_done "python_runtime"
}

setup_python_env() {
  if ! is_python_project; then return; fi
  install_python_runtime

  PY_VENV_DIR="${PROJECT_ROOT}/.venv"
  # Ensure uv is installed and on PATH (package-manager-agnostic)
  if ! command -v uv >/dev/null 2>&1; then
    curl -fsSL https://astral.sh/uv/install.sh | env UV_NO_PROMPT=1 sh -s --
  fi
  export PATH="${HOME}/.local/bin:${PATH}"

  # Recreate venv on Python 3.11 if missing or using a different Python
  if [[ -d "$PY_VENV_DIR" ]]; then
    if ! "${PY_VENV_DIR}/bin/python" -c 'import sys; print(sys.version_info[:2]==(3,11))' 2>/dev/null | grep -q "True"; then
      rm -rf "$PY_VENV_DIR"
    fi
  fi
  if [[ ! -d "$PY_VENV_DIR" ]]; then
    log "Creating Python virtual environment at ${PY_VENV_DIR} with Python 3.11 via uv..."
    uv python install 3.11
    uv venv --python 3.11 "$PY_VENV_DIR"
  else
    log "Python virtual environment already exists at ${PY_VENV_DIR}."
  fi

  # shellcheck disable=SC1090
  source "${PY_VENV_DIR}/bin/activate"
  pip install --upgrade pip setuptools wheel

  if [[ -f "${PROJECT_ROOT}/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt..."
    PIP_PREFER_BINARY=1 pip install --no-input --prefer-binary -r "${PROJECT_ROOT}/requirements.txt" || true
  elif [[ -f "${PROJECT_ROOT}/pyproject.toml" ]]; then
    if grep -qi '\[tool.poetry\]' "${PROJECT_ROOT}/pyproject.toml" 2>/dev/null; then
      log "Detected Poetry project. Installing Poetry and dependencies..."
      pip install "poetry>=1.5"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-root || true
    else
      log "pyproject.toml detected without Poetry. Attempting pip install via PEP 517 with prefer-binary..."
      PIP_PREFER_BINARY=1 pip install --no-input --prefer-binary . || true
    fi
  elif [[ -f "${PROJECT_ROOT}/Pipfile" ]]; then
    log "Detected Pipenv project. Installing Pipenv and dependencies..."
    pip install "pipenv>=2023.0.0"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install
  fi
}

install_node_runtime() {
  if is_done "node_runtime"; then
    log "Node.js runtime already set."
    return
  fi
  log "Installing Node.js runtime..."
  case "$PKG_MGR" in
    apt)
      eval "$PKG_INSTALL nodejs npm"
      ;;
    apk)
      eval "$PKG_INSTALL nodejs npm"
      ;;
    dnf|yum)
      eval "$PKG_INSTALL nodejs npm"
      ;;
    zypper)
      eval "$PKG_INSTALL nodejs npm"
      ;;
  esac
  # Enable corepack if available to use yarn/pnpm if requested
  if need_cmd corepack; then
    corepack enable || true
  fi
  mark_done "node_runtime"
}

setup_node_env() {
  if ! is_node_project; then return; fi
  install_node_runtime

  pushd "$PROJECT_ROOT" >/dev/null
  # Choose installer based on lockfile
  if [[ -f "pnpm-lock.yaml" ]]; then
    if ! need_cmd pnpm; then
      log "Installing pnpm via corepack..."
      if need_cmd corepack; then corepack prepare pnpm@latest --activate || true; fi
    fi
    log "Installing Node.js dependencies via pnpm..."
    pnpm install --frozen-lockfile || pnpm install
  elif [[ -f "yarn.lock" ]]; then
    if ! need_cmd yarn; then
      log "Installing Yarn via corepack..."
      if need_cmd corepack; then corepack prepare yarn@stable --activate || true; fi
    fi
    log "Installing Node.js dependencies via yarn..."
    yarn install --frozen-lockfile || yarn install
  elif [[ -f "package-lock.json" ]]; then
    log "Installing Node.js dependencies via npm ci..."
    npm ci || npm install
  else
    log "Installing Node.js dependencies via npm..."
    npm install
  fi
  popd >/dev/null
}

install_go_runtime() {
  if is_done "go_runtime"; then
    log "Go runtime already set."
    return
  fi
  log "Installing Go runtime..."
  case "$PKG_MGR" in
    apt) eval "$PKG_INSTALL golang" ;;
    apk) eval "$PKG_INSTALL go" ;;
    dnf|yum) eval "$PKG_INSTALL golang" ;;
    zypper) eval "$PKG_INSTALL go" ;;
  esac
  mark_done "go_runtime"
}

setup_go_env() {
  if ! is_go_project; then return; fi
  install_go_runtime

  export GOPATH="${PROJECT_ROOT}/.gopath"
  export GOCACHE="${PROJECT_ROOT}/.gocache"
  ensure_dir "$GOPATH" "$GOCACHE"
  log "Configured GOPATH=${GOPATH}"
  pushd "$PROJECT_ROOT" >/dev/null
  if need_cmd go; then
    log "Downloading Go modules..."
    go mod download
  fi
  popd >/dev/null
}

install_rust_runtime() {
  if is_done "rust_runtime"; then
    log "Rust runtime already set."
    return
  fi
  log "Installing Rust toolchain..."
  # Prefer distro packages for simplicity in containers
  case "$PKG_MGR" in
    apt) eval "$PKG_INSTALL cargo rustc" || true ;;
    apk) eval "$PKG_INSTALL cargo rust" || true ;;
    dnf|yum) eval "$PKG_INSTALL cargo rust" || true ;;
    zypper) eval "$PKG_INSTALL cargo rust" || true ;;
  esac

  if ! need_cmd cargo; then
    log "Falling back to rustup installation..."
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
    chmod +x /tmp/rustup-init.sh
    export RUSTUP_HOME="${PROJECT_ROOT}/.rustup"
    export CARGO_HOME="${PROJECT_ROOT}/.cargo"
    /tmp/rustup-init.sh -y --no-modify-path --default-toolchain stable
    rm -f /tmp/rustup-init.sh
    export PATH="${CARGO_HOME}/bin:${PATH}"
  fi

  mark_done "rust_runtime"
}

setup_rust_env() {
  if ! is_rust_project; then return; fi
  install_rust_runtime

  export RUSTUP_HOME="${PROJECT_ROOT}/.rustup"
  export CARGO_HOME="${PROJECT_ROOT}/.cargo"
  export PATH="${CARGO_HOME}/bin:${PATH}"
  ensure_dir "$RUSTUP_HOME" "$CARGO_HOME"
  pushd "$PROJECT_ROOT" >/dev/null
  if need_cmd cargo; then
    log "Fetching Rust crates..."
    cargo fetch || true
  fi
  popd >/dev/null
}

install_java_runtime() {
  if is_done "java_runtime"; then
    log "Java runtime already set."
    return
  fi
  log "Installing Java (OpenJDK) and build tools..."
  case "$PKG_MGR" in
    apt) eval "$PKG_INSTALL openjdk-17-jdk maven" ;;
    apk) eval "$PKG_INSTALL openjdk17 maven" ;;
    dnf|yum) eval "$PKG_INSTALL java-17-openjdk java-17-openjdk-devel maven" ;;
    zypper) eval "$PKG_INSTALL java-17-openjdk java-17-openjdk-devel maven" ;;
  esac
  mark_done "java_runtime"
}

setup_java_env() {
  if ! is_java_project; then return; fi
  install_java_runtime
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f "mvnw" ]]; then
    chmod +x mvnw
    log "Using Maven Wrapper to resolve dependencies..."
    ./mvnw -B -q -DskipTests dependency:resolve || true
  elif [[ -f "pom.xml" ]]; then
    log "Resolving Maven dependencies..."
    mvn -B -q -DskipTests dependency:resolve || true
  fi
  if [[ -f "gradlew" ]]; then
    chmod +x gradlew
    log "Using Gradle Wrapper to prepare dependencies..."
    ./gradlew --no-daemon --quiet tasks >/dev/null 2>&1 || true
  fi
  popd >/dev/null
}

install_php_runtime() {
  if is_done "php_runtime"; then
    log "PHP runtime already set."
    return
  fi
  log "Installing PHP and Composer..."
  case "$PKG_MGR" in
    apt) eval "$PKG_INSTALL php-cli php-xml php-curl php-mbstring php-zip unzip composer" ;;
    apk) eval "$PKG_INSTALL php php-cli php-xml php-curl php-mbstring php-zip unzip composer" ;;
    dnf|yum) eval "$PKG_INSTALL php-cli php-xml php-common php-json php-mbstring php-zip unzip composer" ;;
    zypper) eval "$PKG_INSTALL php7 php7-pear php7-xml php7-curl php7-mbstring php7-zip unzip composer" || eval "$PKG_INSTALL php php-pear php-xml php-curl php-mbstring php-zip unzip composer" ;;
  esac
  mark_done "php_runtime"
}

setup_php_env() {
  if ! is_php_project; then return; fi
  install_php_runtime
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f "composer.json" ]]; then
    if need_cmd composer; then
      log "Installing PHP dependencies via Composer..."
      composer install --no-interaction --prefer-dist || composer install --no-interaction
    fi
  fi
  popd >/dev/null
}

install_ruby_runtime() {
  if is_done "ruby_runtime"; then
    log "Ruby runtime already set."
    return
  fi
  log "Installing Ruby and Bundler..."
  case "$PKG_MGR" in
    apt) eval "$PKG_INSTALL ruby-full ruby-dev build-essential zlib1g-dev" ;;
    apk) eval "$PKG_INSTALL ruby ruby-dev build-base zlib-dev" ;;
    dnf|yum) eval "$PKG_INSTALL ruby ruby-devel gcc gcc-c++ make zlib-devel" ;;
    zypper) eval "$PKG_INSTALL ruby ruby-devel gcc gcc-c++ make zlib-devel" ;;
  esac
  if ! need_cmd bundler; then
    gem install bundler --no-document || true
  fi
  mark_done "ruby_runtime"
}

setup_ruby_env() {
  if ! is_ruby_project; then return; fi
  install_ruby_runtime
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f "Gemfile" ]]; then
    log "Installing Ruby gems via Bundler..."
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2) || bundle install
  fi
  popd >/dev/null
}

# Directory structure and permissions
setup_directories() {
  log "Setting up project directory structure under ${PROJECT_ROOT}..."
  ensure_dir "${PROJECT_ROOT}/logs" "${PROJECT_ROOT}/tmp" "${PROJECT_ROOT}/run" "${PROJECT_ROOT}/data" "$STATE_DIR"

  # Language-specific workspace dirs
  [[ -d "${PROJECT_ROOT}/.venv" ]] || true
  [[ -d "${PROJECT_ROOT}/node_modules" ]] || true
  [[ -d "${PROJECT_ROOT}/vendor" ]] || true

  # Ensure reasonable permissions
  chmod -R u+rwX,go+rX "${PROJECT_ROOT}/logs" "${PROJECT_ROOT}/tmp" "${PROJECT_ROOT}/run" "${PROJECT_ROOT}/data" || true
}

# Create non-root user (optional)
setup_user() {
  if [[ "${USE_NON_ROOT}" != "true" ]]; then
    log "Non-root user creation skipped (USE_NON_ROOT=false)."
    return
  fi
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User ${APP_USER} already exists."
  else
    log "Creating non-root user ${APP_USER}..."
    if need_cmd useradd; then
      useradd -m -s /bin/bash "$APP_USER"
    elif need_cmd adduser; then
      adduser -D -s /bin/bash "$APP_USER" || adduser -D "$APP_USER" || adduser "$APP_USER"
    else
      warn "No useradd/adduser available; skipping user creation."
      return
    fi
  fi
  chown -R "${APP_USER}":"${APP_USER}" "$PROJECT_ROOT" || true
}

# Environment variables management
setup_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    log "Environment file exists at ${ENV_FILE}."
    return
  fi
  log "Creating default environment file at ${ENV_FILE}..."
  cat > "$ENV_FILE" <<'EOF'
# Application environment
APP_ENV=production
# Default port (adjust as needed)
PORT=8000
# Bind address inside container
HOST=0.0.0.0

# Database placeholders
DB_HOST=localhost
DB_PORT=5432
DB_USER=user
DB_PASSWORD=pass
DB_NAME=appdb

# Python specific
PYTHONPATH=
# Node specific
NODE_ENV=production
# Java specific
JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75.0
EOF
  chmod 600 "$ENV_FILE" || true
}

# Export env for current session (non-persistent)
export_runtime_env() {
  # Source .env for current shell
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi

  # Language-specific PATH adjustments
  if [[ -d "${PROJECT_ROOT}/.venv/bin" ]]; then
    export PATH="${PROJECT_ROOT}/.venv/bin:${PATH}"
  fi
  if [[ -d "${PROJECT_ROOT}/.cargo/bin" ]]; then
    export PATH="${PROJECT_ROOT}/.cargo/bin:${PATH}"
  fi
}

# Auto-activate Python venv on shell start
ensure_venv_auto_activate() {
  local venv_dir="${PROJECT_ROOT}/.venv"
  local bashrc_file="/root/.bashrc"
  local activate_line="source ${venv_dir}/bin/activate"
  if [[ -d "$venv_dir" ]]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
    if [[ -d /etc/profile.d ]]; then
      printf "%s\n" "[ -d \"${venv_dir}\" ] && . \"${venv_dir}/bin/activate\"" > /etc/profile.d/venv-auto-activate.sh
      chmod 0644 /etc/profile.d/venv-auto-activate.sh || true
    fi
  fi
}

ensure_run_build_script() {
  local script_path="${PROJECT_ROOT}/run_build.sh"
  # Always (re)generate run_build.sh to avoid quoting issues in upstream runners
  cat > "$script_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f gradlew ]; then
  chmod +x gradlew || true
  ./gradlew build -x test
elif [ -f mvnw ] || [ -f pom.xml ]; then
  if command -v mvn >/dev/null 2>&1; then
    mvn -q -DskipTests package
  else
    echo Maven not found. Installing Maven via apt-get...
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y || true
      apt-get install -y maven
      mvn -q -DskipTests package
    else
      echo apt-get not available; please install Maven manually. >&2
      exit 1
    fi
  fi
elif [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile || pnpm install
    pnpm build || pnpm run build
  elif command -v npm >/dev/null 2>&1; then
    npm ci || npm install
    npm run build || npm run build --if-present
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile || yarn install
    yarn build || yarn run build
  else
    echo No Node package manager found >&2
    exit 1
  fi
elif [ -f Cargo.toml ]; then
  if command -v cargo >/dev/null 2>&1; then
    cargo build --locked || cargo build
  else
    echo Cargo not found >&2
    exit 1
  fi
elif [ -f Makefile ]; then
  make build || make
else
  echo No recognized build system \(Gradle, Maven, Node, Cargo, Make\) found >&2
  exit 1
fi
EOF
  chmod +x "$script_path"
}

# Summary and hints
print_summary() {
  echo
  log "Setup summary:"
  [[ -f "${PROJECT_ROOT}/requirements.txt" || -f "${PROJECT_ROOT}/pyproject.toml" || -f "${PROJECT_ROOT}/Pipfile" ]] && echo " - Python environment: ${PROJECT_ROOT}/.venv"
  [[ -f "${PROJECT_ROOT}/package.json" ]] && echo " - Node.js dependencies installed"
  [[ -f "${PROJECT_ROOT}/go.mod" ]] && echo " - Go GOPATH: ${PROJECT_ROOT}/.gopath"
  [[ -f "${PROJECT_ROOT}/Cargo.toml" ]] && echo " - Rust CARGO_HOME: ${PROJECT_ROOT}/.cargo"
  [[ -f "${PROJECT_ROOT}/pom.xml" || -f "${PROJECT_ROOT}/build.gradle" || -f "${PROJECT_ROOT}/gradlew" ]] && echo " - Java runtime installed"
  [[ -f "${PROJECT_ROOT}/composer.json" ]] && echo " - PHP Composer dependencies installed"
  [[ -f "${PROJECT_ROOT}/Gemfile" ]] && echo " - Ruby Bundler dependencies installed"
  echo " - Environment file: ${ENV_FILE}"
  echo " - Logs directory: ${PROJECT_ROOT}/logs"
  echo
  echo "Next steps:"
  if is_python_project; then
    echo " - Activate Python venv: source ${PROJECT_ROOT}/.venv/bin/activate"
  fi
  if is_node_project; then
    echo " - Run Node app (example): npm start"
  fi
  if is_go_project; then
    echo " - Build Go app: go build ./..."
  fi
  if is_rust_project; then
    echo " - Build Rust app: cargo build --release"
  fi
  if is_java_project; then
    echo " - Build Java app (example): mvn -B -DskipTests package"
  fi
  if is_php_project; then
    echo " - Run PHP app (example): php -S 0.0.0.0:${PORT:-8000} -t public"
  fi
  if is_ruby_project; then
    echo " - Run Ruby app (example): bundle exec rake or rails server -b 0.0.0.0 -p ${PORT:-3000}"
  fi
  echo
}

# Main
main() {
  umask 0022
  ensure_dir "$PROJECT_ROOT"
  touch "$LOG_FILE" || true

  log "Starting environment setup for project at ${PROJECT_ROOT}"

  detect_pkg_manager
  install_base_tools
  setup_directories
  setup_user
  setup_env_file
  ensure_venv_auto_activate
  ensure_run_build_script
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f run_build.sh ]; then ./run_build.sh || true; fi
  popd >/dev/null

  # Language-specific setup based on detection
  if is_python_project; then
    log "Detected Python project."
    setup_python_env
  fi

  if is_node_project; then
    log "Detected Node.js project."
    setup_node_env
  fi

  if is_go_project; then
    log "Detected Go project."
    setup_go_env
  fi

  if is_rust_project; then
    log "Detected Rust project."
    setup_rust_env
  fi

  if is_java_project; then
    log "Detected Java project."
    setup_java_env
  fi

  if is_php_project; then
    log "Detected PHP project."
    setup_php_env
  fi

  if is_ruby_project; then
    log "Detected Ruby project."
    setup_ruby_env
  fi

  if ! is_python_project && ! is_node_project && ! is_go_project && ! is_rust_project && ! is_java_project && ! is_php_project && ! is_ruby_project; then
    warn "No known project type detected. You may need to customize this script for your stack."
  fi

  export_runtime_env
  print_summary
  log "Environment setup completed successfully."
}

main "$@"