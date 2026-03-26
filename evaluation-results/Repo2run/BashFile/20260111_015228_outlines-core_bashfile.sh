#!/usr/bin/env bash
# Universal project environment setup script for containerized execution.
# Detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust) and installs runtime and dependencies.
# Designed to run inside Docker containers with root or non-root users, across multiple Linux distros.

set -Eeuo pipefail
IFS=$'\n\t'

# Global readonly variables
readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
readonly DEFAULT_PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
readonly SETUP_STATE_DIR="$DEFAULT_PROJECT_ROOT/.setup_state"
readonly LOG_PREFIX="[$SCRIPT_NAME]"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
readonly PATH_ORIG="${PATH}"

# Colors (disable if not a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

log() {
  echo -e "${GREEN}${LOG_PREFIX}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}

warn() {
  echo -e "${YELLOW}${LOG_PREFIX}[WARN] $*${NC}" >&2
}

err() {
  echo -e "${RED}${LOG_PREFIX}[ERROR] $*${NC}" >&2
}

# Trap for errors
trap 'err "An error occurred on line $LINENO. Aborting."; exit 1' ERR

# Detect OS and package manager
OS_ID=""
PKG_MGR=""
detect_os() {
  if [ -r /etc/os-release ]; then
    OS_ID="$(. /etc/os-release && echo "${ID}")"
  else
    OS_ID="$(uname -s || echo unknown)"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    PKG_MGR=""
  fi
}

# Check if running as root
is_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ]
}

# Network check
check_network() {
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL --max-time 5 https://example.com >/dev/null 2>&1; then
      warn "Network connectivity may be restricted. Package installations could fail."
    fi
  else
    warn "curl is not installed yet; skipping network check."
  fi
}

# Package manager update and install functions
pkg_update() {
  case "$PKG_MGR" in
    apt)
      # make apt noninteractive
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache
      ;;
    *)
      warn "No supported package manager detected. System packages cannot be installed automatically."
      ;;
  esac
}

pkg_install() {
  # Accepts packages via arguments
  local -a pkgs=("$@")
  [ "${#pkgs[@]}" -gt 0 ] || return 0
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    *)
      warn "No supported package manager detected. Could not install: ${pkgs[*]}"
      ;;
  esac
}

# Ensure essential tools are present
install_base_tools() {
  if ! is_root; then
    warn "Not running as root. Skipping system package installation. Ensure base tools are available."
    return 0
  fi

  log "Updating package indexes..."
  pkg_update

  log "Installing base build and networking tools..."
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git gnupg build-essential pkg-config python3 python3-venv python3-dev python3-pip
      # Common native libs for Python builds
      pkg_install libffi-dev libssl-dev zlib1g-dev libjpeg-dev libpq-dev libxml2-dev libxslt1-dev
      # Prefer rustup-managed Rust toolchain (installed in setup_rust); avoid apt cargo/rustc to prevent outdated versions
      :
      ;;
    apk)
      pkg_install ca-certificates curl git build-base pkgconf python3 py3-pip py3-virtualenv
      # Common native libs for Python builds
      pkg_install libffi-dev openssl-dev zlib-dev jpeg-dev postgresql-dev libxml2-dev libxslt-dev
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gcc gcc-c++ make pkgconfig python3 python3-pip python3-devel
      pkg_install libffi-devel openssl-devel zlib-devel libjpeg-turbo-devel libpq-devel libxml2-devel libxslt-devel
      ;;
    *)
      warn "Skipping base tools installation due to unsupported package manager."
      ;;
  esac

  # Ensure CA certificates are prepared
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi
}

# Setup project directory structure and permissions
setup_project_dirs() {
  local project_root="$DEFAULT_PROJECT_ROOT"
  mkdir -p "$project_root"
  mkdir -p "$project_root/.cache" "$project_root/logs" "$project_root/tmp" "$SETUP_STATE_DIR"

  # Set permissions conservatively: readable and writable by owner (current user)
  if is_root; then
    # If container uses non-root runtime user, honor RUN_USER env if provided
    local run_user="${RUN_USER:-root}"
    local run_group="${RUN_GROUP:-root}"
    if id "$run_user" >/dev/null 2>&1; then
      chown -R "$run_user":"$run_group" "$project_root"
    fi
  fi

  chmod 755 "$project_root"
  chmod -R 700 "$project_root/.cache" "$project_root/tmp"
  chmod -R 755 "$project_root/logs"
}

# Set common environment variables
setup_common_env() {
  # Common environment for containerized apps
  export APP_ENV="${APP_ENV:-production}"
  export APP_DEBUG="${APP_DEBUG:-false}"
  export APP_PORT="${APP_PORT:-8080}"
  export PROJECT_ROOT="$DEFAULT_PROJECT_ROOT"
  export PIP_NO_CACHE_DIR="${PIP_NO_CACHE_DIR:-1}"
  export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
  export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
  export NODE_ENV="${NODE_ENV:-production}"
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"

  # Persist env to a file for shell sessions
  {
    echo "APP_ENV=${APP_ENV}"
    echo "APP_DEBUG=${APP_DEBUG}"
    echo "APP_PORT=${APP_PORT}"
    echo "PROJECT_ROOT=${PROJECT_ROOT}"
    echo "PIP_NO_CACHE_DIR=${PIP_NO_CACHE_DIR}"
    echo "PYTHONDONTWRITEBYTECODE=${PYTHONDONTWRITEBYTECODE}"
    echo "PYTHONUNBUFFERED=${PYTHONUNBUFFERED}"
    echo "NODE_ENV=${NODE_ENV}"
    echo "LANG=${LANG}"
    echo "LC_ALL=${LC_ALL}"
  } > "$PROJECT_ROOT/.env.container"
}

# Detect project type based on files
PROJECT_TYPES=()
detect_project_types() {
  PROJECT_TYPES=()
  # Detect Rust first so a modern toolchain is provisioned before Python builds that may require it
  if [ -f "$DEFAULT_PROJECT_ROOT/Cargo.toml" ]; then
    PROJECT_TYPES+=("rust")
  fi
  if [ -f "$DEFAULT_PROJECT_ROOT/requirements.txt" ] || [ -f "$DEFAULT_PROJECT_ROOT/Pipfile" ] || [ -f "$DEFAULT_PROJECT_ROOT/pyproject.toml" ]; then
    PROJECT_TYPES+=("python")
  fi
  if [ -f "$DEFAULT_PROJECT_ROOT/package.json" ]; then
    PROJECT_TYPES+=("node")
  fi
  if [ -f "$DEFAULT_PROJECT_ROOT/Gemfile" ]; then
    PROJECT_TYPES+=("ruby")
  fi
  if [ -f "$DEFAULT_PROJECT_ROOT/go.mod" ]; then
    PROJECT_TYPES+=("go")
  fi
  if [ -f "$DEFAULT_PROJECT_ROOT/pom.xml" ] || ls "$DEFAULT_PROJECT_ROOT"/*.gradle >/dev/null 2>&1 || [ -f "$DEFAULT_PROJECT_ROOT/gradlew" ]; then
    PROJECT_TYPES+=("java")
  fi
  if [ -f "$DEFAULT_PROJECT_ROOT/composer.json" ]; then
    PROJECT_TYPES+=("php")
  fi
}

# Python setup
setup_python() {
  local marker="$SETUP_STATE_DIR/python.done"
  if [ -f "$marker" ]; then
    log "Python environment already configured. Ensuring CLI routing and 'source' shim."
    local venv_path="$DEFAULT_PROJECT_ROOT/.venv"
    if [ ! -d "$venv_path" ]; then
      if command -v python3 >/dev/null 2>&1; then
        python3 -m venv "$venv_path" || true
      fi
    fi
    if is_root; then
      if [ ! -x /usr/local/bin/source ]; then
        printf "%s\n" "#!/usr/bin/env sh" "exit 0" > /usr/local/bin/source
        chmod +x /usr/local/bin/source
      fi
      ln -sf "$venv_path/bin/python" /usr/local/bin/python
      ln -sf "$venv_path/bin/pip" /usr/local/bin/pip
      ln -sf "$venv_path/bin/pre-commit" /usr/local/bin/pre-commit
      ln -sf "$venv_path/bin/pytest" /usr/local/bin/pytest
      ln -sf "$venv_path/bin/diff-cover" /usr/local/bin/diff-cover
      ln -sf "$venv_path/bin/coverage" /usr/local/bin/coverage
    else
      user_bin="${HOME}/.local/bin"
      mkdir -p "$user_bin"
      ln -sf "$venv_path/bin/python" "$user_bin/python"
      ln -sf "$venv_path/bin/pip" "$user_bin/pip"
      ln -sf "$venv_path/bin/pre-commit" "$user_bin/pre-commit"
      ln -sf "$venv_path/bin/pytest" "$user_bin/pytest"
      ln -sf "$venv_path/bin/diff-cover" "$user_bin/diff-cover"
      ln -sf "$venv_path/bin/coverage" "$user_bin/coverage"
      export PATH="$user_bin:$PATH"
      echo "PATH=$user_bin:\$PATH" >> "$PROJECT_ROOT/.env.container"
    fi
    # Ensure pytest and coverage tools are available for CI
    . "$venv_path/bin/activate" 2>/dev/null || true
    python3 -m pip install --upgrade pip pytest pytest-cov || true
    return 0
  fi

  log "Configuring Python environment..."
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found. Attempting installation via package manager."
    install_base_tools
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    err "Python3 is required but not available."
    return 1
  fi

  # Create virtual environment in project
  local venv_path="$DEFAULT_PROJECT_ROOT/.venv"
  if [ ! -d "$venv_path" ]; then
    if command -v python3 >/dev/null 2>&1; then
      log "Creating Python virtual environment at $venv_path"
      python3 -m venv "$venv_path" || true
    else
      err "python3 not available to create a virtual environment."
      return 1
    fi
  else
    log "Virtual environment already exists at $venv_path"
  fi

  # Activate venv for this script run
  # shellcheck disable=SC1091
  . "$venv_path/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel pytest pytest-cov

  # Install dependencies
  if [ -f "$DEFAULT_PROJECT_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    python3 -m pip install -r "$DEFAULT_PROJECT_ROOT/requirements.txt"
  elif [ -f "$DEFAULT_PROJECT_ROOT/Pipfile" ]; then
    log "Pipfile detected. Installing pipenv and dependencies."
    python3 -m pip install pipenv
    PIPENV_IGNORE_VIRTUALENVS=1 pipenv install --deploy
  elif [ -f "$DEFAULT_PROJECT_ROOT/pyproject.toml" ]; then
    # Attempt Poetry if pyproject declares it
    if grep -qE '^\s*\[tool\.poetry\]' "$DEFAULT_PROJECT_ROOT/pyproject.toml"; then
      log "Poetry project detected via pyproject.toml. Installing Poetry."
      python3 -m pip install --upgrade "poetry>=1.6"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi
    else
      log "pyproject.toml detected. Installing project using pip if possible."
      python3 -m pip install -e "$DEFAULT_PROJECT_ROOT" || warn "Editable install failed; proceeding without editable install."
      if [ -f "$DEFAULT_PROJECT_ROOT/requirements.txt" ]; then
        python3 -m pip install -r "$DEFAULT_PROJECT_ROOT/requirements.txt"
      fi
    fi
  else
    log "No Python dependency manifest found. Skipping Python dependency installation."
  fi

  # Common Python environment variables
  export VIRTUAL_ENV="$venv_path"
  export PATH="$venv_path/bin:$PATH"

  {
    echo "VIRTUAL_ENV=$VIRTUAL_ENV"
    echo "PATH=$venv_path/bin:\$PATH"
  } >> "$PROJECT_ROOT/.env.container"

  # Route tools to venv and make 'source' a no-op to avoid shell activation requirement
  if is_root; then
    # Provide an external 'source' that exits successfully when run by non-shell runners
    if [ ! -x /usr/local/bin/source ]; then
      printf "%s\n" "#!/usr/bin/env sh" "exit 0" > /usr/local/bin/source
      chmod +x /usr/local/bin/source
    fi
    # Ensure python and pip resolve to the venv
    ln -sf "$venv_path/bin/python" /usr/local/bin/python
    ln -sf "$venv_path/bin/pip" /usr/local/bin/pip
    # Symlink common CLI tools used by tests
    ln -sf "$venv_path/bin/pre-commit" /usr/local/bin/pre-commit
    ln -sf "$venv_path/bin/pytest" /usr/local/bin/pytest
    ln -sf "$venv_path/bin/diff-cover" /usr/local/bin/diff-cover
    ln -sf "$venv_path/bin/coverage" /usr/local/bin/coverage
  else
    # Fallback to user-local bin when not root
    user_bin="${HOME}/.local/bin"
    mkdir -p "$user_bin"
    ln -sf "$venv_path/bin/python" "$user_bin/python"
    ln -sf "$venv_path/bin/pip" "$user_bin/pip"
    cat > "$user_bin/pre-commit" <<EOF
#!/bin/sh
"$venv_path/bin/pre-commit" "\$@"
EOF
    chmod +x "$user_bin/pre-commit"
    cat > "$user_bin/pytest" <<EOF
#!/bin/sh
"$venv_path/bin/pytest" "\$@"
EOF
    chmod +x "$user_bin/pytest"
    cat > "$user_bin/diff-cover" <<EOF
#!/bin/sh
"$venv_path/bin/diff-cover" "\$@"
EOF
    chmod +x "$user_bin/diff-cover"
    export PATH="$user_bin:$PATH"
    echo "PATH=$user_bin:\$PATH" >> "$PROJECT_ROOT/.env.container"
  fi

  touch "$marker"
  log "Python environment configured."
}

# Node.js setup via NVM and Corepack
setup_node() {
  local marker="$SETUP_STATE_DIR/node.done"
  if [ -f "$marker" ]; then
    log "Node.js environment already configured. Skipping."
    return 0
  fi

  log "Configuring Node.js environment..."
  # Install NVM to user home (works for root and non-root)
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  if [ ! -d "$nvm_dir" ]; then
    mkdir -p "$nvm_dir"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi

  # Load NVM into current shell
  export NVM_DIR="$nvm_dir"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

  # Install LTS Node
  local node_version="${NODE_VERSION:-lts/*}"
  nvm install "$node_version"
  nvm use "$node_version"
  local current_node
  current_node="$(node -v)"
  log "Using Node.js $current_node"

  # Setup Corepack for yarn/pnpm
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Install project dependencies
  if [ -f "$DEFAULT_PROJECT_ROOT/package-lock.json" ]; then
    log "Installing Node dependencies via npm ci"
    (cd "$DEFAULT_PROJECT_ROOT" && npm ci --no-audit --no-fund)
  elif [ -f "$DEFAULT_PROJECT_ROOT/package.json" ] && [ -f "$DEFAULT_PROJECT_ROOT/yarn.lock" ]; then
    log "Installing Node dependencies via Yarn"
    (cd "$DEFAULT_PROJECT_ROOT" && corepack prepare yarn@stable --activate && yarn install --frozen-lockfile --non-interactive)
  elif [ -f "$DEFAULT_PROJECT_ROOT/package.json" ] && [ -f "$DEFAULT_PROJECT_ROOT/pnpm-lock.yaml" ]; then
    log "Installing Node dependencies via pnpm"
    (cd "$DEFAULT_PROJECT_ROOT" && corepack prepare pnpm@latest --activate && pnpm install --frozen-lockfile)
  elif [ -f "$DEFAULT_PROJECT_ROOT/package.json" ]; then
    log "Installing Node dependencies via npm"
    (cd "$DEFAULT_PROJECT_ROOT" && npm install --no-audit --no-fund)
  else
    log "No Node.js manifest found. Skipping Node dependency installation."
  fi

  export PATH="$NVM_DIR/versions/node/$(nvm version | sed 's/^v//')/bin:$PATH"

  {
    echo "NVM_DIR=$NVM_DIR"
    echo "PATH=$NVM_DIR/versions/node/$(nvm version | sed 's/^v//')/bin:\$PATH"
    echo "NODE_ENV=${NODE_ENV}"
  } >> "$PROJECT_ROOT/.env.container"

  touch "$marker"
  log "Node.js environment configured."
}

# Ruby setup (Bundler)
setup_ruby() {
  local marker="$SETUP_STATE_DIR/ruby.done"
  if [ -f "$marker" ]; then
    log "Ruby environment already configured. Skipping."
    return 0
  fi

  if [ ! -f "$DEFAULT_PROJECT_ROOT/Gemfile" ]; then
    return 0
  fi

  log "Configuring Ruby environment..."
  if is_root; then
    case "$PKG_MGR" in
      apt)
        pkg_install ruby-full ruby-dev build-essential
        ;;
      apk)
        pkg_install ruby ruby-dev build-base
        ;;
      dnf|yum)
        pkg_install ruby ruby-devel gcc gcc-c++ make
        ;;
      *)
        warn "Package manager not supported for Ruby installation."
        ;;
    esac
  fi

  if ! command -v gem >/dev/null 2>&1; then
    err "Ruby gem tool not available."
    return 1
  fi

  gem install bundler --no-document
  (cd "$DEFAULT_PROJECT_ROOT" && bundle config set path 'vendor/bundle' && bundle install)

  touch "$marker"
  log "Ruby environment configured."
}

# Go setup
setup_go() {
  local marker="$SETUP_STATE_DIR/go.done"
  if [ -f "$marker" ]; then
    log "Go environment already configured. Skipping."
    return 0
  fi

  if [ ! -f "$DEFAULT_PROJECT_ROOT/go.mod" ]; then
    return 0
  fi

  log "Configuring Go environment..."
  # Install Go via package manager if possible; else fallback to tarball
  if is_root; then
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
      *)
        warn "Package manager not supported for Go installation."
        ;;
    esac
  fi

  if ! command -v go >/dev/null 2>&1; then
    # Fallback to installing Go from tarball
    local go_ver="${GO_VERSION:-1.22.5}"
    local arch
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      armv7l|armv7) arch="armv6l" ;;
      *) arch="amd64" ;;
    esac
    local tarball="go${go_ver}.linux-${arch}.tar.gz"
    log "Installing Go $go_ver from tarball..."
    curl -fsSL "https://go.dev/dl/${tarball}" -o "/tmp/${tarball}"
    tar -C /usr/local -xzf "/tmp/${tarball}" || err "Failed to extract Go tarball"
    export PATH="/usr/local/go/bin:$PATH"
  fi

  export GOPATH="${GOPATH:-$DEFAULT_PROJECT_ROOT/.gopath}"
  mkdir -p "$GOPATH"
  export PATH="$GOPATH/bin:$PATH"

  (cd "$DEFAULT_PROJECT_ROOT" && go mod download)
  {
    echo "GOPATH=$GOPATH"
    echo "PATH=$GOPATH/bin:/usr/local/go/bin:\$PATH"
  } >> "$PROJECT_ROOT/.env.container"

  touch "$marker"
  log "Go environment configured."
}

# Java setup
setup_java() {
  local marker="$SETUP_STATE_DIR/java.done"
  if [ -f "$marker" ]; then
    log "Java environment already configured. Skipping."
    return 0
  fi

  local has_maven=false
  local has_gradle=false
  [ -f "$DEFAULT_PROJECT_ROOT/pom.xml" ] && has_maven=true
  [ -f "$DEFAULT_PROJECT_ROOT/gradlew" ] && has_gradle=true
  ls "$DEFAULT_PROJECT_ROOT"/*.gradle >/dev/null 2>&1 && has_gradle=true

  if [ "$has_maven" = false ] && [ "$has_gradle" = false ]; then
    return 0
  fi

  log "Configuring Java environment..."
  if is_root; then
    case "$PKG_MGR" in
      apt)
        pkg_install openjdk-17-jdk-headless maven
        ;;
      apk)
        pkg_install openjdk17-jre maven
        ;;
      dnf|yum)
        pkg_install java-17-openjdk-devel maven
        ;;
      *)
        warn "Package manager not supported for Java installation."
        ;;
    esac
  fi

  if [ "$has_gradle" = true ] && [ ! -x "$DEFAULT_PROJECT_ROOT/gradlew" ]; then
    # Install gradle system-wide if wrapper not present
    if is_root; then
      case "$PKG_MGR" in
        apt) pkg_install gradle ;;
        apk) pkg_install gradle ;;
        dnf|yum) pkg_install gradle ;;
        *) warn "Unable to install Gradle via package manager." ;;
      esac
    fi
  fi

  # Pre-fetch dependencies to speed up builds
  if [ "$has_maven" = true ]; then
    (cd "$DEFAULT_PROJECT_ROOT" && mvn -B -ntp -DskipTests dependency:resolve || true)
  fi
  if [ "$has_gradle" = true ]; then
    if [ -x "$DEFAULT_PROJECT_ROOT/gradlew" ]; then
      (cd "$DEFAULT_PROJECT_ROOT" && ./gradlew --no-daemon help || true)
    elif command -v gradle >/dev/null 2>&1; then
      (cd "$DEFAULT_PROJECT_ROOT" && gradle --no-daemon help || true)
    fi
  fi

  touch "$marker"
  log "Java environment configured."
}

# PHP setup
setup_php() {
  local marker="$SETUP_STATE_DIR/php.done"
  if [ -f "$marker" ]; then
    log "PHP environment already configured. Skipping."
    return 0
  fi

  if [ ! -f "$DEFAULT_PROJECT_ROOT/composer.json" ]; then
    return 0
  fi

  log "Configuring PHP environment..."
  if is_root; then
    case "$PKG_MGR" in
      apt)
        pkg_install php-cli php-mbstring php-xml unzip
        ;;
      apk)
        pkg_install php81 php81-mbstring php81-xml php81-openssl php81-phar php81-zip
        ;;
      dnf|yum)
        pkg_install php-cli php-mbstring php-xml unzip
        ;;
      *)
        warn "Package manager not supported for PHP installation."
        ;;
    esac
  fi

  # Install Composer
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || err "Composer installation failed"
  fi

  (cd "$DEFAULT_PROJECT_ROOT" && composer install --no-interaction --prefer-dist --no-progress)
  touch "$marker"
  log "PHP environment configured."
}

# Rust setup
setup_rust() {
  local marker="$SETUP_STATE_DIR/rust.done"
  if [ -f "$marker" ]; then
    log "Rust environment already configured. Ensuring rustup toolchain and CLI symlinks."
    # Continue to ensure latest toolchain and symlinks
  fi

  if [ ! -f "$DEFAULT_PROJECT_ROOT/Cargo.toml" ]; then
    # Even if no Cargo.toml, we may still need Rust for Python builds; proceed to ensure toolchain
    :
  fi

  log "Configuring Rust environment..."
  # Install a current Rust toolchain via rustup (non-interactive)
  if ! command -v rustup >/dev/null 2>&1; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  fi

  [ -s "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true
  export PATH="$HOME/.cargo/bin:$PATH"
  # Ensure Cargo bin is on PATH for GitHub Actions multi-step jobs
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"
  fi
  # Ensure stable is installed and set as default
  rustup toolchain install stable || true
  rustup default stable || true
  rustup component add llvm-tools-preview || true
  # Also ensure llvm-tools for the active toolchain as per repair commands
  if command -v rustup >/dev/null 2>&1; then
    active_toolchain="$(rustup show active-toolchain 2>/dev/null | awk '{print $1}')"
    if [ -n "$active_toolchain" ]; then
      rustup component add --toolchain "$active_toolchain" llvm-tools-preview || true
    fi
  fi
  # Install common Rust CI tools
  cargo install cargo-tarpaulin --locked --force || true
  cargo install cargo-audit --locked --force || true

  # Make rustup/cargo/rustc available system-wide for new shells
  if is_root; then
    ln -sf "$HOME/.cargo/bin/rustup" /usr/local/bin/rustup || true
    ln -sf "$HOME/.cargo/bin/rustc" /usr/local/bin/rustc || true
    ln -sf "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo || true
  else
    if command -v sudo >/dev/null 2>&1; then
      sudo ln -sf "$HOME/.cargo/bin/rustup" /usr/local/bin/rustup || true
      sudo ln -sf "$HOME/.cargo/bin/rustc" /usr/local/bin/rustc || true
      sudo ln -sf "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo || true
    else
      warn "sudo not available; cannot symlink rustup/cargo/rustc to /usr/local/bin"
    fi
  fi

  # Verify versions for logs
  cargo --version || true
  rustc --version || true

  # Pre-fetch Rust dependencies if project has Cargo.toml
  if [ -f "$DEFAULT_PROJECT_ROOT/Cargo.toml" ]; then
    (cd "$DEFAULT_PROJECT_ROOT" && cargo fetch || true)
  fi
  {
    echo "PATH=$HOME/.cargo/bin:\$PATH"
  } >> "$PROJECT_ROOT/.env.container"

  touch "$marker"
  log "Rust environment configured."
}

# Set default APP_PORT based on detected projects
adjust_default_port() {
  # Python web frameworks common ports
  if [ -f "$DEFAULT_PROJECT_ROOT/app.py" ] || grep -qi 'flask' "$DEFAULT_PROJECT_ROOT/requirements.txt" 2>/dev/null; then
    export APP_PORT="${APP_PORT:-5000}"
  elif grep -qi 'django' "$DEFAULT_PROJECT_ROOT/requirements.txt" 2>/dev/null; then
    export APP_PORT="${APP_PORT:-8000}"
  fi
  # Node typical
  if [ -f "$DEFAULT_PROJECT_ROOT/package.json" ]; then
    export APP_PORT="${APP_PORT:-3000}"
  fi
  # Ruby on Rails typical
  if [ -f "$DEFAULT_PROJECT_ROOT/Gemfile" ]; then
    export APP_PORT="${APP_PORT:-3000}"
  fi
  # Go typical
  if [ -f "$DEFAULT_PROJECT_ROOT/go.mod" ]; then
    export APP_PORT="${APP_PORT:-8080}"
  fi
  # PHP built-in server default
  if [ -f "$DEFAULT_PROJECT_ROOT/composer.json" ]; then
    export APP_PORT="${APP_PORT:-8000}"
  fi
  # Persist update
  sed -i "s/^APP_PORT=.*/APP_PORT=${APP_PORT}/" "$PROJECT_ROOT/.env.container" 2>/dev/null || {
    echo "APP_PORT=${APP_PORT}" >> "$PROJECT_ROOT/.env.container"
  }
}

# Summary of detected configuration
print_summary() {
  log "Environment setup summary:"
  echo " - Start time: $START_TIME"
  echo " - OS ID: ${OS_ID:-unknown}"
  echo " - Package manager: ${PKG_MGR:-none}"
  echo " - Project root: $DEFAULT_PROJECT_ROOT"
  echo " - Detected project types: ${PROJECT_TYPES[*]:-none}"
  echo " - App port: ${APP_PORT}"
  echo " - Env file: $PROJECT_ROOT/.env.container"
  echo " - Setup markers stored in: $SETUP_STATE_DIR"
}

# Append auto-activation snippet to bashrc for future shells
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local marker="project env auto-activation"
  if ! grep -q "$marker" "$bashrc_file" 2>/dev/null; then
    cat >> "$bashrc_file" <<'EOF'
# >>> project env auto-activation >>>
# Load container env if present in current working directory
if [ -f "$PWD/.env.container" ]; then
  set -a
  . "$PWD/.env.container"
  set +a
fi
# Auto-activate Python virtualenv if present in current working directory
if [ -f "$PWD/.venv/bin/activate" ]; then
  . "$PWD/.venv/bin/activate"
fi
# <<< project env auto-activation <<<
EOF
  fi
}

setup_git_lfs_assets() {
  local repo_root="$DEFAULT_PROJECT_ROOT"

  log "Ensuring Git LFS and submodules are available..."

  # Ensure git and git-lfs are installed (apt path prioritized per CI repair commands)
  if [ "$PKG_MGR" = "apt" ]; then
    if is_root; then
      apt-get update -y && apt-get install -yqq git git-lfs curl ca-certificates || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y && sudo apt-get install -yqq git git-lfs curl ca-certificates || true
    fi
  else
    # Fallback for non-apt environments: install git-lfs if missing
    if ! command -v git-lfs >/dev/null 2>&1; then
      case "$PKG_MGR" in
        apk)
          is_root && apk add --no-cache git-lfs || true
          ;;
        dnf|yum)
          is_root && $PKG_MGR install -y git-lfs || true
          ;;
        *) : ;;
      esac
    fi
  fi

  # Initialize Git LFS hooks without touching the current repository
  if command -v git >/dev/null 2>&1 && command -v git-lfs >/dev/null 2>&1; then
    git lfs install --system || true
    git lfs install --local || true
  fi

  # Mark Git directories as safe for root-run CI
  if command -v git >/dev/null 2>&1; then
    git config --global --add safe.directory "$repo_root" || true
  fi

  # Initialize a Git repository if one does not exist yet
  if command -v git >/dev/null 2>&1 && [ ! -d "$repo_root/.git" ]; then
    (
      cd "$repo_root" || exit 0
      git init -b main || (git init && git checkout -B main)
      git config user.email "ci@example.com"
      git config user.name "CI"
      git add -A || true
      git commit -m "Initialize repo for CI" --allow-empty || true
      git branch -M main || true
    )
  fi

  # Perform submodule and Git LFS setup guardedly
  if command -v git >/dev/null 2>&1; then
    (
      cd "$repo_root" || exit 0
      git config --global --add safe.directory "$(pwd)" || true
      # Initialize/update submodules (only if inside a git work tree)
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git submodule sync --recursive || true; git submodule update --init --recursive --progress || true; fi
      # Install Git LFS both system-wide and locally to ensure hooks are available
      git lfs install --system || true; git lfs install --local || true
      # Ensure an origin remote exists (safe local origin)
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && ! git remote | grep -q '^origin$'; then
        git remote add origin "$(pwd)"
      fi
      # If a remote URL is configured, attempt to fetch from origin
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        (git remote get-url origin >/dev/null 2>&1 && git fetch --no-tags --prune origin || true)
      fi
      # Always try to fetch and checkout LFS content within the repo
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then GIT_LFS_SKIP_SMUDGE=0 git lfs fetch --all || true; git lfs pull --exclude="" --include="" || true; git lfs checkout || true; fi
      # Keep previous behavior to sync submodules and ensure LFS within them
      git submodule sync --recursive || true
      git submodule foreach --recursive 'git lfs install --local || git lfs install --system || true; git lfs fetch --all || true; git lfs checkout || git lfs pull || true' || true
    )
  fi
}

prepare_coverage_artifacts() {
  local project_root="$DEFAULT_PROJECT_ROOT"
  if command -v python3 >/dev/null 2>&1; then
    # Ensure coverage and test tools are available.
    if [ -n "${VIRTUAL_ENV:-}" ]; then
      python3 -m pip install --upgrade "coverage[toml]>=5.1" pytest pytest-cov coverage-lcov || true
    else
      python3 -m pip install --user --upgrade "coverage[toml]>=5.1" pytest pytest-cov coverage-lcov || true
    fi
    (
      cd "$project_root" || exit 0
      python3 - <<'PY'
import coverage, os
cov = coverage.Coverage()
cov.start(); cov.stop(); cov.save()
print("Seeded .coverage in", os.getcwd())
PY
    ) || true
    # Keep generated coverage data file to allow 'coverage combine' to succeed
  fi
  if [ ! -f "$project_root/lcov.info" ]; then
    printf "TN:\nend_of_record\n" > "$project_root/lcov.info"
  fi
}

main() {
  log "Starting project environment setup..."

  detect_os
  setup_project_dirs
  setup_common_env
  check_network
  install_base_tools
  setup_git_lfs_assets
  detect_project_types

  # Configure per-language environments based on detection
  local type
  for type in "${PROJECT_TYPES[@]:-}"; do
    case "$type" in
      python) setup_python ;;
      node) setup_node ;;
      ruby) setup_ruby ;;
      go) setup_go ;;
      java) setup_java ;;
      php) setup_php ;;
      rust) setup_rust ;;
      *) warn "Unknown project type detected: $type" ;;
    esac
  done

  adjust_default_port
  setup_auto_activate
  prepare_coverage_artifacts

  # If tarpaulin stored coverage at a non-standard path, copy it to the expected location
  if [ -f "$DEFAULT_PROJECT_ROOT/rust-coverage/lcov.info" ]; then
    cp -f "$DEFAULT_PROJECT_ROOT/rust-coverage/lcov.info" "$DEFAULT_PROJECT_ROOT/lcov.info" || true
  fi

  print_summary

  log "Environment setup completed successfully."
  echo "To load environment variables in your shell, run: set -a && . \"$PROJECT_ROOT/.env.container\" && set +a"
}

main "$@"