#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust, .NET)
# Installs system packages, runtimes, and project dependencies idempotently
# Configures environment variables and directory structure

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output (disabled if NO_COLOR is set)
if [[ -n "${NO_COLOR:-}" ]]; then
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
else
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
fi

# Global variables
APP_ROOT="${APP_ROOT:-$(pwd)}"
APP_USER="${APP_USER:-root}"       # Non-root user optional, root by default in Docker
APP_GROUP="${APP_GROUP:-root}"
ENV_FILE="$APP_ROOT/.env"
BIN_DIR="$APP_ROOT/bin"
LOG_DIR="$APP_ROOT/log"
TMP_DIR="$APP_ROOT/tmp"
CACHE_DIR="$APP_ROOT/.cache"
STATE_DIR="$APP_ROOT/.state"
VENV_DIR="$APP_ROOT/.venv"
DOCKER_DETECTED="false"
PKG_MANAGER=""
OS_FAMILY=""

# Logging functions
log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()  { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    error "Setup script failed with exit code $exit_code"
  fi
}
trap cleanup EXIT

# Detect Docker environment
detect_docker() {
  if [[ -f "/.dockerenv" ]] || grep -qi docker /proc/1/cgroup 2>/dev/null; then
    DOCKER_DETECTED="true"
    log "Docker environment detected."
  fi
}

# Detect OS and package manager
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    OS_FAMILY="debian"
    export DEBIAN_FRONTEND=noninteractive
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    OS_FAMILY="fedora"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    OS_FAMILY="rhel"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    OS_FAMILY="suse"
  else
    PKG_MANAGER=""
    OS_FAMILY="unknown"
  fi

  if [[ -z "$PKG_MANAGER" ]]; then
    warn "No supported package manager found. Assuming runtime dependencies are pre-installed."
  else
    log "Using package manager: $PKG_MANAGER (OS: $OS_FAMILY)"
  fi
}

# Package installation helpers
pkg_update() {
  case "$PKG_MANAGER" in
    apt)   apt-get update -y -qq ;;
    apk)   apk update || true ;;
    dnf)   dnf -y -q makecache ;;
    yum)   yum -y -q makecache ;;
    zypper) zypper refresh ;;
    *)     ;;
  esac
}

pkg_install() {
  # install packages passed as args in an idempotent manner
  local pkgs=("$@")
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}" || true
      ;;
    dnf)
      dnf install -y -q "${pkgs[@]}"
      ;;
    yum)
      yum install -y -q "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${pkgs[@]}"
      ;;
    *)
      warn "Package manager not available; cannot install: ${pkgs[*]}"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MANAGER" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
      ;;
    dnf|yum)
      rm -rf /var/cache/dnf /var/cache/yum /tmp/* /var/tmp/*
      ;;
    zypper)
      rm -rf /var/cache/zypp /tmp/* /var/tmp/*
      ;;
    *)
      ;;
  esac
}

# System base dependencies
install_base_system_deps() {
  if [[ -z "$PKG_MANAGER" ]]; then
    warn "Skipping base system dependency installation due to missing package manager."
    return 0
  fi

  log "Installing base system dependencies..."
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git gnupg build-essential pkg-config libffi-dev libssl-dev zlib1g-dev jq
      # Ensure CA certs
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git build-base libffi-dev openssl-dev zlib-dev
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gcc gcc-c++ make pkgconfig libffi-devel openssl-devel zlib-devel
      ;;
    zypper)
      pkg_install ca-certificates curl git gcc gcc-c++ make pkg-config libffi-devel libopenssl-devel zlib-devel
      ;;
  esac
  pkg_cleanup
  git config --global --add safe.directory /app || true
  log "Base system dependencies installed."
}

# Directory setup
setup_directories() {
  log "Setting up project directories at $APP_ROOT..."
  mkdir -p "$BIN_DIR" "$LOG_DIR" "$TMP_DIR" "$CACHE_DIR" "$STATE_DIR"
  chmod 755 "$BIN_DIR" "$LOG_DIR" "$TMP_DIR" "$CACHE_DIR" "$STATE_DIR"
  chown -R "$APP_USER:$APP_GROUP" "$BIN_DIR" "$LOG_DIR" "$TMP_DIR" "$CACHE_DIR" "$STATE_DIR" || true
}

# Environment file setup
setup_env_file() {
  log "Configuring environment variables in $ENV_FILE..."
  touch "$ENV_FILE"
  # Add defaults only if not present
  grep -q '^APP_ENV=' "$ENV_FILE" 2>/dev/null || echo "APP_ENV=${APP_ENV:-production}" >>"$ENV_FILE"
  grep -q '^PORT=' "$ENV_FILE" 2>/dev/null || echo "PORT=${PORT:-8080}" >>"$ENV_FILE"
  grep -q '^LOG_LEVEL=' "$ENV_FILE" 2>/dev/null || echo "LOG_LEVEL=${LOG_LEVEL:-info}" >>"$ENV_FILE"
  grep -q '^PYTHONDONTWRITEBYTECODE=' "$ENV_FILE" 2>/dev/null || echo "PYTHONDONTWRITEBYTECODE=1" >>"$ENV_FILE"
  grep -q '^PYTHONUNBUFFERED=' "$ENV_FILE" 2>/dev/null || echo "PYTHONUNBUFFERED=1" >>"$ENV_FILE"
  grep -q '^PIP_NO_CACHE_DIR=' "$ENV_FILE" 2>/dev/null || echo "PIP_NO_CACHE_DIR=1" >>"$ENV_FILE"
  grep -q '^NODE_ENV=' "$ENV_FILE" 2>/dev/null || echo "NODE_ENV=${NODE_ENV:-production}" >>"$ENV_FILE"
  grep -q '^RUBYOPT=' "$ENV_FILE" 2>/dev/null || echo "RUBYOPT='-W:no-deprecated'" >>"$ENV_FILE"
  grep -q '^GOPATH=' "$ENV_FILE" 2>/dev/null || echo "GOPATH=${GOPATH:-$APP_ROOT/.gopath}" >>"$ENV_FILE"
  grep -q '^JAVA_TOOL_OPTIONS=' "$ENV_FILE" 2>/dev/null || echo "JAVA_TOOL_OPTIONS='-XX:+UnlockExperimentalVMOptions -XX:+UseContainerSupport'" >>"$ENV_FILE"
  grep -q '^DOTNET_CLI_TELEMETRY_OPTOUT=' "$ENV_FILE" 2>/dev/null || echo "DOTNET_CLI_TELEMETRY_OPTOUT=1" >>"$ENV_FILE"
  grep -q '^COMPOSER_NO_INTERACTION=' "$ENV_FILE" 2>/dev/null || echo "COMPOSER_NO_INTERACTION=1" >>"$ENV_FILE"
  grep -q '^CI=' "$ENV_FILE" 2>/dev/null || echo "CI=true" >>"$ENV_FILE"

  # Export for current session
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

# Detect project types
PY_PROJECT="0"
NODE_PROJECT="0"
RUBY_PROJECT="0"
GO_PROJECT="0"
JAVA_PROJECT="0"
PHP_PROJECT="0"
RUST_PROJECT="0"
DOTNET_PROJECT="0"

detect_project_types() {
  [[ -f "$APP_ROOT/requirements.txt" || -f "$APP_ROOT/pyproject.toml" || -f "$APP_ROOT/Pipfile" ]] && PY_PROJECT="1"
  [[ -f "$APP_ROOT/package.json" ]] && NODE_PROJECT="1"
  [[ -f "$APP_ROOT/Gemfile" ]] && RUBY_PROJECT="1"
  [[ -f "$APP_ROOT/go.mod" ]] && GO_PROJECT="1"
  [[ -f "$APP_ROOT/pom.xml" || -f "$APP_ROOT/build.gradle" || -f "$APP_ROOT/gradlew" || -f "$APP_ROOT/mvnw" ]] && JAVA_PROJECT="1"
  [[ -f "$APP_ROOT/composer.json" ]] && PHP_PROJECT="1"
  [[ -f "$APP_ROOT/Cargo.toml" ]] && RUST_PROJECT="1"
  # .NET detection: any *.csproj or global.json
  if compgen -G "$APP_ROOT/*.csproj" >/dev/null || [[ -f "$APP_ROOT/global.json" ]]; then
    DOTNET_PROJECT="1"
  fi

  log "Project type detection:"
  [[ "$PY_PROJECT" == "1" ]] && log " - Python project detected"
  [[ "$NODE_PROJECT" == "1" ]] && log " - Node.js project detected"
  [[ "$RUBY_PROJECT" == "1" ]] && log " - Ruby project detected"
  [[ "$GO_PROJECT" == "1" ]] && log " - Go project detected"
  [[ "$JAVA_PROJECT" == "1" ]] && log " - Java project detected"
  [[ "$PHP_PROJECT" == "1" ]] && log " - PHP project detected"
  [[ "$RUST_PROJECT" == "1" ]] && log " - Rust project detected"
  [[ "$DOTNET_PROJECT" == "1" ]] && log " - .NET project detected"

  if [[ "$PY_PROJECT$NODE_PROJECT$RUBY_PROJECT$GO_PROJECT$JAVA_PROJECT$PHP_PROJECT$RUST_PROJECT$DOTNET_PROJECT" == "00000000" ]]; then
    warn "No recognizable project manifests found. The script will install base tools only."
  fi
}

# --- Language-specific installers ---

# Python setup
setup_python() {
  if [[ "$PY_PROJECT" != "1" ]]; then return 0; fi
  log "Setting up Python environment..."
  if [[ -n "$PKG_MANAGER" ]]; then
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install python3 python3-venv python3-pip python3-dev; pkg_cleanup ;;
      apk) pkg_install python3 py3-pip python3-dev; ;;
      dnf|yum) pkg_install python3 python3-pip python3-devel; ;;
      zypper) pkg_install python3 python3-pip python3-devel; ;;
    esac
  fi

  # Create venv idempotently
  if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
    log "Created virtual environment at $VENV_DIR"
  else
    log "Virtual environment already exists at $VENV_DIR"
  fi

  # Activate venv for current shell
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  # Upgrade pip/setuptools/wheel
  pip install --no-cache-dir --upgrade pip setuptools wheel

  # Install dependencies
  if [[ -f "$APP_ROOT/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir -r "$APP_ROOT/requirements.txt"
  elif [[ -f "$APP_ROOT/pyproject.toml" ]]; then
    # Attempt to install via pip if project is PEP 517 compatible
    log "Installing Python project via pyproject.toml..."
    pip install --no-cache-dir .
  elif [[ -f "$APP_ROOT/Pipfile" ]]; then
    log "Pipfile detected. Installing pipenv and dependencies..."
    pip install --no-cache-dir pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --system --deploy || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
  else
    warn "Python project detected but no dependency file found."
  fi

  # Persist venv path
  echo "VIRTUAL_ENV=$VENV_DIR" > "$STATE_DIR/python.env"
  log "Python environment configured."
}

# Node.js setup
setup_node() {
  if [[ "$NODE_PROJECT" != "1" ]]; then return 0; fi
  log "Setting up Node.js environment..."

  # Install Node.js
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "Node.js ($(node -v)) and npm ($(npm -v)) already installed."
  else
    if [[ "$PKG_MANAGER" == "apt" ]]; then
      pkg_update
      pkg_install ca-certificates curl gnupg
      if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]]; then
        log "Adding NodeSource repository for Node.js 20 LTS..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || warn "Failed to add NodeSource repo; falling back to apt nodejs."
      fi
      pkg_install nodejs npm || pkg_install nodejs
      pkg_cleanup
    elif [[ "$PKG_MANAGER" == "apk" ]]; then
      pkg_install nodejs npm
    elif [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]]; then
      if [[ ! -f /etc/yum.repos.d/nodesource.repo ]]; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - || warn "Failed to add NodeSource repo; falling back to distro nodejs."
      fi
      pkg_install nodejs npm || pkg_install nodejs
    elif [[ "$PKG_MANAGER" == "zypper" ]]; then
      pkg_install nodejs npm || pkg_install nodejs14 || true
    else
      error "Cannot install Node.js: unknown package manager."
    fi
  fi

  # Install Google Chrome and required libraries for Karma/Chromium-based tests when using apt
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    apt-get update
    apt-get install -y curl gnupg ca-certificates apt-transport-https
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt-get update
    apt-get install -y google-chrome-stable
    apt-get install -y libnss3 libxss1 libatk-bridge2.0-0 libgtk-3-0 libdrm2 libgbm1 libasound2 fonts-liberation libu2f-udev
    printf '#!/usr/bin/env bash\nexec /usr/bin/google-chrome --no-sandbox "$@"\n' > /usr/local/bin/chromium-browser && chmod +x /usr/local/bin/chromium-browser
  fi

  # Install project dependencies
  log "Ensuring npm installs devDependencies..."
  # Install npm-run-all globally to ensure availability of the binary in CI
  npm install -g npm-run-all@latest || true
  if [[ -f "$APP_ROOT/package-lock.json" ]]; then
    log "Using npm ci to install dependencies (including dev)..."
    npm ci --include=dev --no-audit --no-fund || npm ci --include=dev --no-audit --no-fund --ignore-scripts
  elif [[ -f "$APP_ROOT/yarn.lock" ]]; then
    if command -v yarn >/dev/null 2>&1; then
      log "Using yarn to install dependencies..."
      yarn install --frozen-lockfile || yarn install
    else
      warn "yarn.lock detected but yarn is not installed; using npm install."
      npm install --ignore-scripts || npm install
    fi
  else
    log "Installing dependencies with npm..."
    npm install --ignore-scripts || npm install
  fi
  # Ensure required dev tools are present
  # Ensure npm-run-all is present (needed by npm scripts)
  [ -x node_modules/.bin/npm-run-all ] || npm install -D npm-run-all --no-audit --no-fund || warn "Failed to install npm-run-all."

  # Configure Chromium/Chrome environment variables
  export PATH="/usr/local/bin:$PATH"
  export CHROME_BIN=/usr/local/bin/chromium-browser
  grep -q '^CHROME_BIN=' "$ENV_FILE" 2>/dev/null || echo "CHROME_BIN=/usr/local/bin/chromium-browser" >>"$ENV_FILE"
  export CHROMIUM_BIN=/usr/local/bin/chromium-browser
  grep -q '^CHROMIUM_BIN=' "$ENV_FILE" 2>/dev/null || echo "CHROMIUM_BIN=/usr/local/bin/chromium-browser" >>"$ENV_FILE"
  log "Configured Chromium wrapper and environment variables."

  log "Node.js environment configured."
}

# Ruby setup
setup_ruby() {
  if [[ "$RUBY_PROJECT" != "1" ]]; then return 0; fi
  log "Setting up Ruby environment..."
  if command -v ruby >/dev/null 2>&1 && command -v gem >/dev/null 2>&1; then
    log "Ruby ($(ruby -v)) already installed."
  else
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install ruby-full build-essential libffi-dev; pkg_cleanup ;;
      apk) pkg_install ruby ruby-dev build-base libffi-dev ;;
      dnf|yum) pkg_install ruby ruby-devel gcc gcc-c++ make libffi-devel ;;
      zypper) pkg_install ruby ruby-devel gcc gcc-c++ make libffi-devel ;;
      *) error "Cannot install Ruby: unknown package manager."; return 1 ;;
    esac
  fi

  if ! command -v bundler >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  log "Installing Ruby gems with bundler..."
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs "$(nproc)" --retry 3

  log "Ruby environment configured."
}

# Go setup
setup_go() {
  if [[ "$GO_PROJECT" != "1" ]]; then return 0; fi
  log "Setting up Go environment..."
  if command -v go >/dev/null 2>&1; then
    log "Go ($(go version)) already installed."
  else
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install golang; pkg_cleanup ;;
      apk) pkg_install go ;;
      dnf|yum) pkg_install golang ;;
      zypper) pkg_install go ;;
      *) error "Cannot install Go: unknown package manager."; return 1 ;;
    esac
  fi

  mkdir -p "${GOPATH:-$APP_ROOT/.gopath}"
  export GOPATH="${GOPATH:-$APP_ROOT/.gopath}"
  export GOCACHE="$CACHE_DIR/go"
  export GOFLAGS="-mod=mod"
  log "Downloading Go modules..."
  go mod download || warn "go mod download failed."
  log "Go environment configured."
}

# Java setup
setup_java() {
  if [[ "$JAVA_PROJECT" != "1" ]]; then return 0; fi
  log "Setting up Java environment..."
  if command -v java >/dev/null 2>&1; then
    log "Java runtime ($(java -version 2>&1 | head -n1)) already installed."
  else
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install openjdk-17-jdk; pkg_cleanup ;;
      apk) pkg_install openjdk17-jdk ;;
      dnf|yum) pkg_install java-17-openjdk-devel ;;
      zypper) pkg_install java-17-openjdk-devel ;;
      *) error "Cannot install Java: unknown package manager."; return 1 ;;
    esac
  fi

  # Maven or Gradle dependencies
  if [[ -f "$APP_ROOT/mvnw" || -f "$APP_ROOT/pom.xml" ]]; then
    if [[ -f "$APP_ROOT/mvnw" ]]; then
      log "Resolving Maven dependencies using wrapper..."
      chmod +x "$APP_ROOT/mvnw"
      "$APP_ROOT/mvnw" -q -B -DskipTests dependency:resolve || warn "Maven dependency resolve failed."
    else
      case "$PKG_MANAGER" in
        apt) pkg_install maven ;;
        apk) pkg_install maven ;;
        dnf|yum) pkg_install maven ;;
        zypper) pkg_install maven ;;
        *) warn "Cannot install Maven; skipping." ;;
      esac
      mvn -q -B -DskipTests dependency:resolve || warn "Maven dependency resolve failed."
    fi
  elif [[ -f "$APP_ROOT/gradlew" || -f "$APP_ROOT/build.gradle" ]]; then
    if [[ -f "$APP_ROOT/gradlew" ]]; then
      log "Resolving Gradle dependencies using wrapper..."
      chmod +x "$APP_ROOT/gradlew"
      "$APP_ROOT/gradlew" --no-daemon -q build -x test || warn "Gradle build failed."
    else
      case "$PKG_MANAGER" in
        apt) pkg_install gradle ;;
        apk) pkg_install gradle ;;
        dnf|yum) pkg_install gradle ;;
        zypper) pkg_install gradle ;;
        *) warn "Cannot install Gradle; skipping." ;;
      esac
      gradle --no-daemon -q build -x test || warn "Gradle build failed."
    fi
  fi

  log "Java environment configured."
}

# PHP setup
setup_php() {
  if [[ "$PHP_PROJECT" != "1" ]]; then return 0; fi
  log "Setting up PHP environment..."
  if command -v php >/dev/null 2>&1; then
    log "PHP ($(php -v | head -n1)) already installed."
  else
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install php-cli php-zip php-xml php-mbstring php-curl; pkg_cleanup ;;
      apk) pkg_install php php-cli php-zip php-xml php-mbstring php-curl ;;
      dnf|yum) pkg_install php-cli php-zip php-xml php-mbstring php-curl ;;
      zypper) pkg_install php7 php7-zip php7-xml php7-mbstring php7-curl || pkg_install php php-zip php-xml php-mbstring php-curl ;;
      *) error "Cannot install PHP: unknown package manager."; return 1 ;;
    esac
  fi

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  log "Installing PHP dependencies with Composer..."
  composer install --no-interaction --prefer-dist --no-progress || warn "Composer install failed."

  log "PHP environment configured."
}

# Rust setup
setup_rust() {
  if [[ "$RUST_PROJECT" != "1" ]]; then return 0; fi
  log "Setting up Rust environment..."
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    log "Rust ($(rustc --version)) and Cargo ($(cargo --version)) already installed."
  else
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install cargo rustc; pkg_cleanup ;;
      apk) pkg_install cargo rust ;;
      dnf|yum) pkg_install cargo rust ;;
      zypper) pkg_install cargo rust ;;
      *)
        warn "Installing Rust via rustup..."
        curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
        sh /tmp/rustup.sh -y --default-toolchain stable
        # shellcheck disable=SC1090
        source "$HOME/.cargo/env"
        ;;
    esac
  fi

  log "Fetching Rust dependencies..."
  cargo fetch || warn "Cargo fetch failed."
  log "Rust environment configured."
}

# .NET setup
setup_dotnet() {
  if [[ "$DOTNET_PROJECT" != "1" ]]; then return 0; fi
  log "Setting up .NET environment..."
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK ($(dotnet --version)) already installed."
  else
    warn ".NET SDK not found. Installing .NET SDK in containers requires adding Microsoft package repositories, which this script avoids for minimal footprint."
    warn "Please use a base image with .NET preinstalled (e.g., mcr.microsoft.com/dotnet/sdk) or install manually before running this script."
    return 0
  fi

  log "Restoring .NET dependencies..."
  # Restore for all solutions/projects found
  if compgen -G "$APP_ROOT/*.sln" >/dev/null; then
    for sln in "$APP_ROOT"/*.sln; do
      dotnet restore "$sln" || warn "dotnet restore failed for $sln"
    done
  fi
  if compgen -G "$APP_ROOT/*.csproj" >/dev/null; then
    for csproj in "$APP_ROOT"/*.csproj; do
      dotnet restore "$csproj" || warn "dotnet restore failed for $csproj"
    done
  fi

  log ".NET environment configured."
}

# PATH configuration
configure_path() {
  log "Configuring PATH and runtime settings..."
  # Prepend venv bin for Python projects
  if [[ -d "$VENV_DIR/bin" ]]; then
    case ":$PATH:" in
      *":$VENV_DIR/bin:"*) ;;
      *) export PATH="$VENV_DIR/bin:$PATH" ;;
    esac
  fi
  # Yarn global bin if available
  if command -v yarn >/dev/null 2>&1; then
    YARN_BIN="$(yarn global bin 2>/dev/null || true)"
    if [[ -n "$YARN_BIN" ]]; then
      case ":$PATH:" in
        *":$YARN_BIN:"*) ;;
        *) export PATH="$YARN_BIN:$PATH" ;;
      esac
    fi
  fi

  # Persist to a profile script for future shells (idempotent)
  local profile_script="$APP_ROOT/.profile.d/env.sh"
  mkdir -p "$APP_ROOT/.profile.d"
  {
    echo "#!/usr/bin/env bash"
    echo "set -a"
    echo "source \"$ENV_FILE\" 2>/dev/null || true"
    if [[ -d "$VENV_DIR/bin" ]]; then
      echo "export PATH=\"$VENV_DIR/bin:\$PATH\""
    fi
    echo "set +a"
  } >"$profile_script"
  chmod 644 "$profile_script"
}

# Auto-activate venv and environment on shell login
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local env_line="if [ -f \"$APP_ROOT/.profile.d/env.sh\" ]; then . \"$APP_ROOT/.profile.d/env.sh\"; fi"
  local venv_line="if [ -d \"$APP_ROOT/.venv\" ] && [ -f \"$APP_ROOT/.venv/bin/activate\" ]; then . \"$APP_ROOT/.venv/bin/activate\"; fi"
  for L in "$env_line" "$venv_line"; do
    grep -qxF "$L" "$bashrc_file" 2>/dev/null || echo "$L" >> "$bashrc_file"
  done
}

# Permissions setup
setup_permissions() {
  log "Setting file ownership and permissions..."
  chown -R "$APP_USER:$APP_GROUP" "$APP_ROOT" || true
  find "$APP_ROOT" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$APP_ROOT" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true
}

# Entry points hints/setup
setup_entry_points() {
  # Create convenience wrappers for running common apps, if applicable
  log "Setting up convenience launchers in $BIN_DIR..."
  # Python Flask/Django detection
  if [[ "$PY_PROJECT" == "1" ]]; then
    if grep -qi "flask" "$APP_ROOT/requirements.txt" 2>/dev/null || grep -qi "flask" "$APP_ROOT/pyproject.toml" 2>/dev/null; then
      cat >"$BIN_DIR/run-flask" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$APP_ROOT"
source "$APP_ROOT/.venv/bin/activate"
export FLASK_APP="\${FLASK_APP:-app.py}"
export FLASK_ENV="\${FLASK_ENV:-production}"
export FLASK_RUN_PORT="\${FLASK_RUN_PORT:-\${PORT:-8080}}"
exec flask run --host=0.0.0.0 --port "\$FLASK_RUN_PORT"
EOF
      chmod 755 "$BIN_DIR/run-flask"
    fi
    if grep -qi "django" "$APP_ROOT/requirements.txt" 2>/dev/null || grep -qi "django" "$APP_ROOT/pyproject.toml" 2>/dev/null; then
      cat >"$BIN_DIR/run-django" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$APP_ROOT"
source "$APP_ROOT/.venv/bin/activate"
export DJANGO_SETTINGS_MODULE="\${DJANGO_SETTINGS_MODULE:-settings}"
export PORT="\${PORT:-8080}"
exec python manage.py migrate && python manage.py runserver 0.0.0.0:"\$PORT"
EOF
      chmod 755 "$BIN_DIR/run-django"
    fi
  fi
  # Node.js common start
  if [[ "$NODE_PROJECT" == "1" ]]; then
    cat >"$BIN_DIR/run-node" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$APP_ROOT"
export PORT="\${PORT:-8080}"
if [ -f package.json ]; then
  if jq -e '.scripts.start' package.json >/dev/null 2>&1; then
    exec npm start -- --port "\$PORT"
  else
    # fallback to node index.js
    if [ -f server.js ]; then exec node server.js; fi
    if [ -f app.js ]; then exec node app.js; fi
    if [ -f index.js ]; then exec node index.js; fi
    echo "No start script or entry file found." >&2; exit 1
  fi
else
  echo "package.json not found." >&2; exit 1
fi
EOF
    chmod 755 "$BIN_DIR/run-node"
  fi
}

# Main
main() {
  log "Starting universal environment setup..."
  detect_docker
  detect_pkg_manager
  install_base_system_deps
  setup_directories
  setup_env_file
  detect_project_types

  # Language-specific setups
  setup_python
  setup_node
  setup_ruby
  setup_go
  setup_java
  setup_php
  setup_rust
  setup_dotnet

  configure_path
  setup_permissions
  setup_entry_points

  # Mark /app as safe git directory and setup auto-activation
  git config --global --add safe.directory "$APP_ROOT" || true
  setup_auto_activate

  log "Environment setup completed successfully."
  log "Notes:"
  log " - Environment variables stored in $ENV_FILE"
  log " - Convenience scripts (if applicable) available in $BIN_DIR"
  log " - To ensure environment variables are loaded in interactive shells: source $APP_ROOT/.profile.d/env.sh"
}

# Execute
main "$@"