#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type(s) and installs appropriate runtimes and dependencies
# - Installs system packages and build tools
# - Configures environment, creates directories, and sets permissions
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'

# --------------- Logging and error handling ---------------
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "[INFO $(timestamp)] $*"; }
warn() { echo "[WARN $(timestamp)] $*" >&2; }
err() { echo "[ERROR $(timestamp)] $*" >&2; }
on_err() { err "Setup failed at line ${BASH_LINENO[0]} running: ${BASH_COMMAND}"; exit 1; }
trap on_err ERR

# Colors disabled in plain output environments (kept simple per requirement)

# --------------- Globals and defaults ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
SETUP_STATE_DIR="$PROJECT_DIR/.setup"
mkdir -p "$SETUP_STATE_DIR"

# Default environment
export DEBIAN_FRONTEND=noninteractive
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export TZ="${TZ:-UTC}"

# Default ports per common stacks (can be overridden via .env or env vars)
DEFAULT_NODE_PORT="${DEFAULT_NODE_PORT:-3000}"
DEFAULT_PY_PORT="${DEFAULT_PY_PORT:-5000}"
DEFAULT_JAVA_PORT="${DEFAULT_JAVA_PORT:-8080}"
DEFAULT_PHP_PORT="${DEFAULT_PHP_PORT:-8080}"
DEFAULT_GO_PORT="${DEFAULT_GO_PORT:-8080}"
DEFAULT_RUST_PORT="${DEFAULT_RUST_PORT:-8080}"

# Optional ownership mapping (useful when container runs as root but files belong to a host user)
PUID="${PUID:-}"
PGID="${PGID:-}"

# --------------- Utility functions ---------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }
file_exists() { [ -f "$1" ]; }
dir_exists() { [ -d "$1" ]; }

# Detect Linux distro package manager
PKG_MANAGER=""
APT_UPDATED_FLAG="$SETUP_STATE_DIR/.apt_updated"
detect_pkg_manager() {
  if has_cmd apt-get; then PKG_MANAGER="apt"; return 0; fi
  if has_cmd apk; then PKG_MANAGER="apk"; return 0; fi
  if has_cmd dnf; then PKG_MANAGER="dnf"; return 0; fi
  if has_cmd yum; then PKG_MANAGER="yum"; return 0; fi
  if has_cmd zypper; then PKG_MANAGER="zypper"; return 0; fi
  return 1
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      if [ ! -f "$APT_UPDATED_FLAG" ]; then
        log "Updating apt package list..."
        apt-get update -y
        touch "$APT_UPDATED_FLAG"
      fi
      ;;
    apk) apk update || true ;;
    dnf) dnf makecache -y || true ;;
    yum) yum makecache -y || true ;;
    zypper) zypper refresh -y || true ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  if [ ${#pkgs[@]} -eq 0 ]; then return 0; fi
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      pkg_update
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      pkg_update
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      pkg_update
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      pkg_update
      zypper install -y --no-recommends "${pkgs[@]}"
      ;;
    *)
      err "No supported package manager found."
      exit 1
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MANAGER" in
    apt)
      rm -rf /var/lib/apt/lists/* 2>/dev/null || true
      ;;
    apk) true ;;
    dnf|yum)
      true
      ;;
    zypper) true ;;
  esac
}

install_build_tools() {
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl wget git openssh-client gnupg tzdata locales \
        build-essential pkg-config cmake unzip xz-utils zip jq
      ;;
    apk)
      pkg_install ca-certificates curl wget git openssh gnupg tzdata \
        build-base pkgconfig cmake unzip xz zip jq
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git openssh gnupg2 tzdata \
        gcc gcc-c++ make pkgconfig cmake unzip xz zip jq
      ;;
    zypper)
      pkg_install ca-certificates curl wget git openssh gnupg2 timezone \
        gcc gcc-c++ make pkgconfig cmake unzip xz zip jq
      ;;
  esac
}

# --------------- Project detection ---------------
is_node() { file_exists "$PROJECT_DIR/package.json"; }
is_python() { file_exists "$PROJECT_DIR/requirements.txt" || file_exists "$PROJECT_DIR/pyproject.toml" || file_exists "$PROJECT_DIR/Pipfile"; }
is_ruby() { file_exists "$PROJECT_DIR/Gemfile"; }
is_go() { file_exists "$PROJECT_DIR/go.mod"; }
is_rust() { file_exists "$PROJECT_DIR/Cargo.toml"; }
is_java_maven() { file_exists "$PROJECT_DIR/pom.xml"; }
is_java_gradle() { file_exists "$PROJECT_DIR/build.gradle" || file_exists "$PROJECT_DIR/build.gradle.kts" || file_exists "$PROJECT_DIR/gradlew"; }
is_php() { file_exists "$PROJECT_DIR/composer.json"; }
is_dotnet() { compgen -G "$PROJECT_DIR/*.sln" >/dev/null || compgen -G "$PROJECT_DIR/*.csproj" >/dev/null || false; }

# --------------- Environment and directory setup ---------------
setup_directories() {
  log "Setting up project directories..."
  mkdir -p "$PROJECT_DIR"/{logs,tmp,dist,build,.cache}
  touch "$PROJECT_DIR/.gitignore" 2>/dev/null || true
  # Ensure log files exist with sane permissions
  touch "$PROJECT_DIR/logs/app.log" 2>/dev/null || true
}

setup_permissions() {
  if [ -n "$PUID" ] && [ -n "$PGID" ] && [ "$(id -u)" -eq 0 ]; then
    log "Adjusting ownership of project directory to $PUID:$PGID ..."
    chown -R "$PUID:$PGID" "$PROJECT_DIR" || warn "Failed to chown project directory"
  else
    warn "Skipping ownership adjustment (PUID/PGID not set or not running as root)."
  fi
}

setup_env_file() {
  local env_file="$PROJECT_DIR/.env"
  if [ ! -f "$env_file" ]; then
    log "Creating default .env file..."
    cat > "$env_file" <<EOF
# Generated by setup script
APP_ENV=production
TZ=${TZ}
LANG=${LANG}
LC_ALL=${LC_ALL}
PYTHONUNBUFFERED=1
PIP_NO_CACHE_DIR=1
PIP_DISABLE_PIP_VERSION_CHECK=1
# Ports (override as needed)
NODE_PORT=${DEFAULT_NODE_PORT}
PY_PORT=${DEFAULT_PY_PORT}
JAVA_PORT=${DEFAULT_JAVA_PORT}
PHP_PORT=${DEFAULT_PHP_PORT}
GO_PORT=${DEFAULT_GO_PORT}
RUST_PORT=${DEFAULT_RUST_PORT}
EOF
  else
    log ".env file already exists; leaving unchanged."
  fi
}

# --------------- Python setup ---------------
setup_python() {
  log "Detected Python project."
  case "$PKG_MANAGER" in
    apt) pkg_install python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev ;;
    apk) pkg_install python3 py3-pip python3-dev musl-dev libffi-dev openssl-dev ;;
    dnf|yum) pkg_install python3 python3-pip python3-devel openssl-devel libffi-devel ;;
    zypper) pkg_install python3 python3-pip python3-devel libopenssl-devel libffi-devel ;;
  esac

  if ! has_cmd python3; then
    err "python3 not found after installation."
    exit 1
  fi

  # Use venv at PROJECT_DIR/.venv
  local venv_dir="$PROJECT_DIR/.venv"
  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at .venv ..."
    python3 -m venv "$venv_dir"
  else
    log "Virtual environment already present."
  fi

  # Activate venv in a subshell for isolation
  (
    set -Eeuo pipefail
    # shellcheck disable=SC1090
    source "$venv_dir/bin/activate"
    python -m pip install --upgrade pip setuptools wheel

    if file_exists "$PROJECT_DIR/requirements.txt"; then
      log "Installing Python dependencies from requirements.txt ..."
      pip install -r "$PROJECT_DIR/requirements.txt"
    fi

    if file_exists "$PROJECT_DIR/pyproject.toml"; then
      # Try to detect Poetry; fallback to pip installing project
      if grep -q '^\[tool\.poetry\]' "$PROJECT_DIR/pyproject.toml" 2>/dev/null; then
        log "Poetry project detected. Installing Poetry and dependencies..."
        pip install --no-input "poetry>=1.6,<2"
        (cd "$PROJECT_DIR" && poetry config virtualenvs.create false && poetry install --no-interaction --no-ansi)
      else
        log "PEP 517/518 project detected. Installing in editable mode if possible..."
        (cd "$PROJECT_DIR" && pip install -e . || pip install .)
      fi
    fi

    if file_exists "$PROJECT_DIR/Pipfile"; then
      log "Pipenv project detected. Installing pipenv and dependencies..."
      pip install --no-input "pipenv>=2023.0"
      (cd "$PROJECT_DIR" && pipenv install --dev --deploy || pipenv install --dev)
    fi
  )
}

# --------------- Node.js setup ---------------
install_nvm_if_needed() {
  export NVM_DIR="${NVM_DIR:-/root/.nvm}"
  if [ ! -d "$NVM_DIR" ]; then
    log "Installing NVM..."
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  # shellcheck disable=SC1090
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
}

desired_node_version() {
  local ver=""
  if file_exists "$PROJECT_DIR/.nvmrc"; then
    ver="$(tr -d ' \t\r\n' < "$PROJECT_DIR/.nvmrc" || true)"
  elif file_exists "$PROJECT_DIR/package.json"; then
    # Try to parse engines.node using jq if available
    if has_cmd jq; then
      ver="$(jq -r '.engines.node // empty' "$PROJECT_DIR/package.json" || true)"
    fi
  fi
  if [ -z "$ver" ]; then
    ver="lts/*"
  fi
  echo "$ver"
}

setup_node() {
  log "Detected Node.js project."
  install_nvm_if_needed
  # shellcheck disable=SC1090
  . "${NVM_DIR:-/root/.nvm}/nvm.sh"
  local node_ver
  node_ver="$(desired_node_version)"
  log "Installing/using Node.js version: $node_ver"
  nvm install "$node_ver"
  nvm use "$node_ver"
  node -v; npm -v

  # Enable corepack for yarn/pnpm if available
  if has_cmd corepack; then
    corepack enable || true
  fi

  # Select package manager and install
  if file_exists "$PROJECT_DIR/pnpm-lock.yaml"; then
    log "pnpm detected; installing dependencies..."
    corepack prepare pnpm@latest --activate || true
    (cd "$PROJECT_DIR" && pnpm install --frozen-lockfile || pnpm install)
  elif file_exists "$PROJECT_DIR/yarn.lock"; then
    log "Yarn detected; installing dependencies..."
    corepack prepare yarn@stable --activate || true
    (cd "$PROJECT_DIR" && yarn install --frozen-lockfile || yarn install)
  else
    log "npm detected; installing dependencies..."
    (cd "$PROJECT_DIR" && (npm ci || npm install))
  fi

  # Build step if defined
  if grep -q '"build"' "$PROJECT_DIR/package.json" 2>/dev/null; then
    log "Running build script..."
    (cd "$PROJECT_DIR" && npm run build || true)
  fi
}

# --------------- Ruby setup ---------------
setup_ruby() {
  log "Detected Ruby project."
  case "$PKG_MANAGER" in
    apt) pkg_install ruby-full build-essential ruby-bundler ;;
    apk) pkg_install ruby ruby-dev build-base ruby-bundler ;;
    dnf|yum) pkg_install ruby ruby-devel make gcc gcc-c++ rubygems ;;
    zypper) pkg_install ruby ruby-devel make gcc gcc-c++ rubygems ;;
  esac
  if ! has_cmd bundler; then gem install bundler --no-document || true; fi
  (cd "$PROJECT_DIR" && bundle config set path 'vendor/bundle' && bundle install)
}

# --------------- Go setup ---------------
setup_go() {
  log "Detected Go project."
  case "$PKG_MANAGER" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac
  if ! has_cmd go; then err "Go not found after installation"; exit 1; fi
  (cd "$PROJECT_DIR" && go mod download)
  # Optional build to warm cache
  (cd "$PROJECT_DIR" && go build ./... || true)
}

# --------------- Rust setup ---------------
setup_rust() {
  log "Detected Rust project."
  if ! has_cmd cargo || ! has_cmd rustc; then
    log "Installing Rust toolchain via rustup (non-interactive)..."
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
  else
    # shellcheck disable=SC1090
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    rustup update stable || true
  fi
  cargo --version || true
  (cd "$PROJECT_DIR" && cargo fetch)
  # Optional build to warm cache
  (cd "$PROJECT_DIR" && cargo build --locked || cargo build || true)
}

# --------------- Java setup ---------------
setup_java() {
  if is_java_gradle || is_java_maven; then
    log "Detected Java project."
    # Default to JDK 17
    case "$PKG_MANAGER" in
      apt) pkg_install openjdk-17-jdk ;;
      apk) pkg_install openjdk17-jdk ;;
      dnf|yum) pkg_install java-17-openjdk java-17-openjdk-devel ;;
      zypper) pkg_install java-17-openjdk java-17-openjdk-devel ;;
    esac
    export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
    export PATH="$JAVA_HOME/bin:$PATH"

    if is_java_gradle; then
      if file_exists "$PROJECT_DIR/gradlew"; then
        chmod +x "$PROJECT_DIR/gradlew" || true
        (cd "$PROJECT_DIR" && ./gradlew --no-daemon tasks >/dev/null 2>&1 || true)
        (cd "$PROJECT_DIR" && ./gradlew --no-daemon --stacktrace --no-build-cache build -x test || true)
      else
        case "$PKG_MANAGER" in
          apt) pkg_install gradle ;;
          apk) pkg_install gradle ;;
          dnf|yum) pkg_install gradle ;;
          zypper) pkg_install gradle ;;
        esac
        (cd "$PROJECT_DIR" && gradle --no-daemon build -x test || true)
      fi
    fi

    if is_java_maven; then
      case "$PKG_MANAGER" in
        apt) pkg_install maven ;;
        apk) pkg_install maven ;;
        dnf|yum) pkg_install maven ;;
        zypper) pkg_install maven ;;
      esac
      (cd "$PROJECT_DIR" && mvn -B -ntp -q dependency:go-offline || true)
    fi
  fi
}

# --------------- PHP setup ---------------
setup_php() {
  log "Detected PHP project."
  case "$PKG_MANAGER" in
    apt) pkg_install php-cli php-mbstring php-xml php-curl unzip ;;
    apk) pkg_install php81-cli php81-mbstring php81-xml php81-curl unzip ;;
    dnf|yum) pkg_install php-cli php-mbstring php-xml php-curl unzip ;;
    zypper) pkg_install php-cli php-mbstring php-xml php-curl unzip ;;
  esac
  if ! has_cmd composer; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      err "Invalid composer installer signature"
      exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi
  (cd "$PROJECT_DIR" && composer install --no-interaction --prefer-dist || true)
}

# --------------- .NET setup ---------------
setup_dotnet() {
  log "Detected .NET project."
  if has_cmd dotnet; then
    log ".NET SDK already installed: $(dotnet --version)"
  else
    case "$PKG_MANAGER" in
      apt)
        log "Installing .NET SDK (8.0) via Microsoft package repository..."
        pkg_install apt-transport-https
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
        chmod 644 /etc/apt/keyrings/microsoft.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/$(. /etc/os-release && echo $VERSION_CODENAME)/prod $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/microsoft-prod.list || true
        # Refresh and install
        rm -f "$APT_UPDATED_FLAG" || true
        pkg_update
        apt-get install -y dotnet-sdk-8.0 || {
          warn "Falling back to dotnet-install script..."
          curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
          bash /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/share/dotnet
          ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
        }
        ;;
      apk|dnf|yum|zypper)
        warn "Automatic .NET SDK install not supported on this base image; attempting dotnet-install script..."
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
        bash /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/share/dotnet
        ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
        ;;
      *)
        warn "Could not install .NET SDK automatically."
        ;;
    esac
  fi
  if has_cmd dotnet; then
    (cd "$PROJECT_DIR" && dotnet restore || true)
  else
    warn "dotnet command not available after attempted installation."
  fi
}

# --------------- Bashrc auto-activation helpers ---------------
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_line='. "${PROJECT_DIR:-$PWD}/.venv/bin/activate"'
  local marker="# Auto-activate project Python venv"
  if ! grep -qF "$marker" "$bashrc_file" 2>/dev/null && ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    mkdir -p "$(dirname "$bashrc_file")" 2>/dev/null || true
    touch "$bashrc_file"
    {
      echo ""
      echo "$marker"
      echo 'if [ -d "${PROJECT_DIR:-$PWD}/.venv" ] && [ -f "${PROJECT_DIR:-$PWD}/.venv/bin/activate" ]; then'
      echo '  . "${PROJECT_DIR:-$PWD}/.venv/bin/activate"'
      echo "fi"
    } >> "$bashrc_file"
  fi
}

setup_bashrc_nvm() {
  local bashrc_file="${HOME}/.bashrc"
  local marker="# Load NVM automatically"
  if ! grep -q 'NVM_DIR' "$bashrc_file" 2>/dev/null; then
    touch "$bashrc_file"
    {
      echo ""
      echo "$marker"
      echo 'export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"'
      echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
      echo 'if [ -f "${PROJECT_DIR:-$PWD}/package.json" ]; then'
      echo '  nvm use >/dev/null 2>&1 || true'
      echo 'fi'
    } >> "$bashrc_file"
  fi
}

# --------------- iCloud Drive config prep ---------------
setup_icloud_config() {
  # Prepare host-mapped config and data directories to prevent container startup failure
  (
    cd "$PROJECT_DIR" || exit 0
    # Create required directories
    mkdir -p config/session_data icloud

    # Seed minimal valid config.yaml if missing
    if [ ! -f ./config/config.yaml ]; then
      cat > config/config.yaml <<'EOF'
app:
  logger:
    level: INFO
    filename: /config/app.log
EOF
    fi

    # Ensure container permissions
    chown -R 911:911 config icloud 2>/dev/null || true
    chmod -R 0777 config icloud
  )

  # Remove any stale container and pre-pull image
  if has_cmd docker; then
    docker rm -f icloud >/dev/null 2>&1 || true
    docker pull -q mandarons/icloud-drive || true
  fi
}

# --------------- Main orchestration ---------------
main() {
  log "Starting environment setup in $PROJECT_DIR"
  detect_pkg_manager || { err "Unsupported Linux distribution (no known package manager found)."; exit 1; }

  install_build_tools
  setup_directories
  setup_env_file

  setup_icloud_config

  # Ensure convenient shell auto-activation for Python venv and NVM
  setup_auto_activate
  setup_bashrc_nvm

  # Process each supported stack if detected
  local detected=false

  if is_python; then
    setup_python
    detected=true
  fi

  if is_node; then
    setup_node
    detected=true
  fi

  if is_ruby; then
    setup_ruby
    detected=true
  fi

  if is_go; then
    setup_go
    detected=true
  fi

  if is_rust; then
    setup_rust
    detected=true
  fi

  if is_java_gradle || is_java_maven; then
    setup_java
    detected=true
  fi

  if is_php; then
    setup_php
    detected=true
  fi

  if is_dotnet; then
    setup_dotnet
    detected=true
  fi

  if [ "$detected" = false ]; then
    warn "No recognized project files found. The script installed base tools only."
    warn "Add one of: package.json, requirements.txt/pyproject.toml, go.mod, Cargo.toml, pom.xml/build.gradle, composer.json, or a .NET sln/csproj file."
  fi

  setup_permissions
  pkg_cleanup

  log "Environment setup completed successfully."

  # Helpful summary
  echo ""
  echo "Summary:"
  if is_python; then
    echo "- Python: venv at .venv (activate with: source .venv/bin/activate)"
  fi
  if is_node; then
    echo "- Node.js: installed via NVM (activate in shell with: source \$NVM_DIR/nvm.sh && nvm use)"
  fi
  if is_java_gradle || is_java_maven; then
    echo "- Java: OpenJDK configured (JAVA_HOME=$JAVA_HOME)"
  fi
  if is_go; then
    echo "- Go: go modules downloaded"
  fi
  if is_rust; then
    echo "- Rust: toolchain installed via rustup"
  fi
  if is_php; then
    echo "- PHP: composer dependencies installed"
  fi
  if is_dotnet; then
    echo "- .NET: SDK installed or attempted"
  fi
  echo ""
  echo "Environment variables defaults written to .env (override as needed)."
}

main "$@"