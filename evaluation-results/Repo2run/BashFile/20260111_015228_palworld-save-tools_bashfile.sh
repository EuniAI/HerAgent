#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust) and installs dependencies.
# Idempotent, safe to run multiple times, and avoids sudo (assumes root in Docker where needed).

set -Eeuo pipefail
IFS=$'\n\t'

# ======== Logging and error handling ========
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() {
  local exit_code=$?
  if (( exit_code != 0 )); then
    err "Setup failed (exit code: $exit_code) at line ${BASH_LINENO[0]} in function ${FUNCNAME[1]:-main}"
  fi
}
trap cleanup EXIT

# ======== Defaults and environment ========
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-}"
TZ="${TZ:-UTC}"

# Prepare runtime env
export DEBIAN_FRONTEND=noninteractive
export PIP_NO_CACHE_DIR=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

# ======== Helpers ========
is_root() { [ "$(id -u)" -eq 0 ]; }

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  else
    PKG_MGR="unknown"
  fi
}

pkg_update_once() {
  # Use a stamp file to avoid repeated update
  local stamp="/var/lib/.setup_pkg_updated"
  if ! is_root; then
    warn "Not running as root; cannot update system packages."
    return 0
  fi
  if [[ -f "$stamp" ]]; then
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      log "Updating apt package index..."
      apt-get update -y
      touch "$stamp"
      ;;
    apk)
      log "Updating apk package index..."
      apk update
      touch "$stamp"
      ;;
    dnf)
      log "Updating dnf package index..."
      dnf -y makecache
      touch "$stamp"
      ;;
    yum)
      log "Updating yum package index..."
      yum -y makecache
      touch "$stamp"
      ;;
    zypper)
      log "Refreshing zypper repositories..."
      zypper --non-interactive refresh
      touch "$stamp"
      ;;
    *)
      warn "Unknown package manager; skipping update."
      ;;
  esac
}

pkg_install() {
  # Install packages passed as arguments in a cross-distro way
  if ! is_root; then
    warn "Not running as root; cannot install system packages: $*"
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install --no-recommends "$@"
      ;;
    *)
      warn "Unknown package manager; cannot install: $*"
      ;;
  esac
}

ensure_common_build_tools() {
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git gnupg locales tzdata \
                  build-essential pkg-config libssl-dev
      ;;
    apk)
      pkg_install ca-certificates curl wget git tzdata \
                  build-base pkgconf openssl-dev
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git gnupg2 tzdata \
                  make automake gcc gcc-c++ kernel-devel openssl-devel
      ;;
    zypper)
      pkg_install ca-certificates curl wget git timezone \
                  gcc gcc-c++ make pkg-config libopenssl-devel
      ;;
  esac
  # Configure timezone non-interactively
  if is_root; then
    if [ -f /usr/share/zoneinfo/"$TZ" ]; then
      ln -sf /usr/share/zoneinfo/"$TZ" /etc/localtime || true
      echo "$TZ" > /etc/timezone || true
    fi
  fi
}

create_app_user_and_dirs() {
  log "Ensuring application directory structure at $APP_DIR ..."
  mkdir -p "$APP_DIR"/{logs,tmp,.cache}
  # create user/group if root
  if is_root; then
    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
      log "Creating group $APP_GROUP ..."
      if command -v addgroup >/dev/null 2>&1; then
        addgroup -S "$APP_GROUP" || true
      else
        groupadd -r "$APP_GROUP" || true
      fi
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      log "Creating user $APP_USER ..."
      if command -v adduser >/dev/null 2>&1; then
        adduser -S -G "$APP_GROUP" -h "$APP_DIR" "$APP_USER" || true
      else
        useradd -r -g "$APP_GROUP" -d "$APP_DIR" -s /usr/sbin/nologin "$APP_USER" || true
      fi
    fi
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" || true
  else
    warn "Not root; skipping user creation and chown."
  fi
}

write_env_file() {
  local env_file="$APP_DIR/.env"
  if [[ ! -f "$env_file" ]]; then
    log "Creating default environment file at $env_file"
    cat > "$env_file" <<EOF
# Application environment
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
TZ=${TZ}

# Common environment flags
PYTHONDONTWRITEBYTECODE=1
PYTHONUNBUFFERED=1
PIP_NO_CACHE_DIR=1
NODE_ENV=production
EOF
    if is_root; then chown "$APP_USER:$APP_GROUP" "$env_file" || true; fi
  else
    log ".env already exists; leaving as-is."
  fi
}

detect_project_type() {
  PROJECT_TYPE="unknown"
  if [[ -f "$APP_DIR/requirements.txt" || -f "$APP_DIR/pyproject.toml" || -f "$APP_DIR/Pipfile" ]]; then
    PROJECT_TYPE="python"
  elif [[ -f "$APP_DIR/package.json" ]]; then
    PROJECT_TYPE="node"
  elif [[ -f "$APP_DIR/Gemfile" ]]; then
    PROJECT_TYPE="ruby"
  elif [[ -f "$APP_DIR/go.mod" ]]; then
    PROJECT_TYPE="go"
  elif [[ -f "$APP_DIR/pom.xml" ]]; then
    PROJECT_TYPE="java-maven"
  elif [[ -f "$APP_DIR/build.gradle" || -f "$APP_DIR/gradlew" ]]; then
    PROJECT_TYPE="java-gradle"
  elif [[ -f "$APP_DIR/composer.json" ]]; then
    PROJECT_TYPE="php"
  elif [[ -f "$APP_DIR/Cargo.toml" ]]; then
    PROJECT_TYPE="rust"
  else
    PROJECT_TYPE="unknown"
  fi
}

set_default_port_by_type() {
  # Set APP_PORT if not provided
  if [[ -n "${APP_PORT}" ]]; then
    return
  fi
  case "$PROJECT_TYPE" in
    python)
      # Try to infer Flask (5000) vs Django (8000)
      if [[ -f "$APP_DIR/manage.py" ]]; then
        APP_PORT="8000"
      elif [[ -f "$APP_DIR/app.py" || -f "$APP_DIR/wsgi.py" ]]; then
        APP_PORT="5000"
      else
        APP_PORT="8000"
      fi
      ;;
    node)
      APP_PORT="3000"
      ;;
    ruby)
      # Rails default dev port; production often via puma
      APP_PORT="3000"
      ;;
    go)
      APP_PORT="8080"
      ;;
    java-maven|java-gradle)
      APP_PORT="8080"
      ;;
    php)
      APP_PORT="8080"
      ;;
    rust)
      APP_PORT="8080"
      ;;
    *)
      APP_PORT="8080"
      ;;
  esac
}

setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev \
                  build-essential libffi-dev libssl-dev zlib1g-dev \
                  libpq-dev
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev \
                  build-base libffi-dev openssl-dev zlib-dev postgresql-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel \
                  gcc gcc-c++ make libffi-devel openssl-devel zlib-devel \
                  postgresql-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-virtualenv python3-devel \
                  gcc gcc-c++ make libffi-devel libopenssl-devel libz1 \
                  postgresql-devel
      ;;
  esac

  # Create virtual environment idempotently
  if [[ ! -d "$APP_DIR/.venv" ]]; then
    log "Creating Python virtual environment at $APP_DIR/.venv"
    python3 -m venv "$APP_DIR/.venv"
  else
    log "Virtual environment already exists."
  fi

  # Upgrade pip and install dependencies
  # shellcheck disable=SC1090
  source "$APP_DIR/.venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  if [[ -f "$APP_DIR/requirements.txt" ]]; then
    log "Installing dependencies from requirements.txt ..."
    pip install -r "$APP_DIR/requirements.txt"
  elif [[ -f "$APP_DIR/pyproject.toml" ]]; then
    if grep -qi "\[tool.poetry\]" "$APP_DIR/pyproject.toml"; then
      log "Poetry project detected. Installing poetry and project deps..."
      pip install "poetry>=1.5"
      cd "$APP_DIR"
      poetry install --no-root --no-interaction
    else
      log "PEP 517/518 project detected. Installing via pip..."
      pip install -e "$APP_DIR" || pip install "$APP_DIR"
    fi
  elif [[ -f "$APP_DIR/Pipfile" ]]; then
    log "Pipenv project detected. Installing pipenv and dependencies..."
    pip install pipenv
    cd "$APP_DIR"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install
  else
    log "No Python dependency file found; skipping dependency installation."
  fi

  deactivate || true

  # Environment additions
  {
    echo "export PATH=\"$APP_DIR/.venv/bin:\$PATH\""
    echo "export PYTHONUNBUFFERED=1"
    echo "export PIP_NO_CACHE_DIR=1"
  } > "$APP_DIR/.python_env.sh"
  if is_root; then chown "$APP_USER:$APP_GROUP" "$APP_DIR/.python_env.sh" || true; fi
}

setup_node() {
  log "Setting up Node.js environment..."
  # Install Node.js LTS using available manager
  if command -v node >/dev/null 2>&1; then
    log "Node.js $(node -v) already installed."
  else
    case "$PKG_MGR" in
      apt)
        pkg_update_once
        # Use NodeSource for a recent LTS
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        pkg_install nodejs
        ;;
      dnf|yum)
        curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
        pkg_install nodejs
        ;;
      apk)
        pkg_install nodejs npm
        ;;
      zypper)
        pkg_install nodejs npm
        ;;
      *)
        warn "Unsupported package manager for Node.js; attempting to install via tarball..."
        ARCH="$(uname -m)"
        case "$ARCH" in
          x86_64|amd64) NODE_ARCH="x64" ;;
          aarch64|arm64) NODE_ARCH="arm64" ;;
          *) NODE_ARCH="x64" ;;
        esac
        NODE_VER="18.20.4"
        curl -fsSL "https://nodejs.org/dist/v$NODE_VER/node-v$NODE_VER-linux-$NODE_ARCH.tar.xz" -o /tmp/node.tar.xz
        mkdir -p /opt/node
        tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1
        ln -sf /opt/node/bin/node /usr/local/bin/node || true
        ln -sf /opt/node/bin/npm /usr/local/bin/npm || true
        ln -sf /opt/node/bin/npx /usr/local/bin/npx || true
        ;;
    esac
  fi

  # Enable corepack and yarn if yarn.lock exists
  if [[ -f "$APP_DIR/yarn.lock" ]]; then
    if command -v corepack >/dev/null 2>&1; then
      corepack enable || true
    fi
    if ! command -v yarn >/dev/null 2>&1; then
      warn "Yarn not found; corepack will provide it if available."
    fi
  fi

  # Install dependencies idempotently
  cd "$APP_DIR"
  if [[ -f "package-lock.json" ]]; then
    log "Installing Node dependencies via npm ci ..."
    npm ci --no-audit --no-fund
  elif [[ -f "yarn.lock" ]]; then
    log "Installing Node dependencies via yarn ..."
    if command -v yarn >/dev/null 2>&1; then
      yarn install --frozen-lockfile
    else
      npx yarn install --frozen-lockfile
    fi
  elif [[ -f "pnpm-lock.yaml" ]]; then
    log "Installing Node dependencies via pnpm ..."
    if ! command -v pnpm >/devnull 2>&1; then
      npm -g install pnpm || npx pnpm --version >/dev/null 2>&1 || true
    fi
    pnpm install --frozen-lockfile
  else
    log "Installing Node dependencies via npm install ..."
    npm install --no-audit --no-fund
  fi

  # Build if applicable
  if jq -e '.scripts.build' package.json >/dev/null 2>&1; then
    log "Running npm run build ..."
    npm run build
  fi
}

setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel make gcc gcc-c++ redhat-rpm-config
      ;;
    zypper)
      pkg_install ruby ruby-devel make gcc gcc-c++
      ;;
  esac
  # Install bundler
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document
  fi
  cd "$APP_DIR"
  export BUNDLE_PATH="$APP_DIR/vendor/bundle"
  bundle config set --local path "$BUNDLE_PATH"
  bundle install --jobs "$(nproc)" --retry 3
}

setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac
  mkdir -p "$APP_DIR/.gopath"
  export GOPATH="$APP_DIR/.gopath"
  export GOCACHE="$APP_DIR/.cache/go"
  cd "$APP_DIR"
  go mod download
}

setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17 maven ;;
    dnf|yum) pkg_install java-17-openjdk maven ;;
    zypper) pkg_install java-17-openjdk maven ;;
  esac
  cd "$APP_DIR"
  mvn -q -DskipTests dependency:go-offline
}

setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk ;;
    apk) pkg_install openjdk17 ;;
    dnf|yum) pkg_install java-17-openjdk ;;
    zypper) pkg_install java-17-openjdk ;;
  esac
  cd "$APP_DIR"
  if [[ -x "./gradlew" ]]; then
    ./gradlew --no-daemon build -x test || ./gradlew --no-daemon dependencies
  else
    warn "gradlew not found; installing gradle system-wide."
    pkg_install gradle || true
    gradle build -x test || true
  fi
}

setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt) pkg_install php-cli php-curl php-xml php-mbstring php-zip composer ;;
    apk) pkg_install php8 php8-cli php8-curl php8-xml php8-mbstring php8-zip composer ;;
    dnf|yum) pkg_install php-cli php-curl php-xml php-mbstring php-zip composer ;;
    zypper) pkg_install php8 php8-cli php8-curl php8-xml php8-mbstring php8-zip composer ;;
  esac
  cd "$APP_DIR"
  if [[ -f "composer.json" ]]; then
    if [[ -f "composer.lock" ]]; then
      composer install --no-interaction --prefer-dist --no-dev --optimize-autoloader
    else
      composer install --no-interaction --prefer-dist
    fi
  fi
}

setup_rust() {
  log "Setting up Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --quiet
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
    ln -sf "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo || true
    ln -sf "$HOME/.cargo/bin/rustc" /usr/local/bin/rustc || true
  else
    log "Rust toolchain already installed."
  fi
  cd "$APP_DIR"
  cargo fetch
}

print_summary() {
  log "Setup complete."
  echo -e "${BLUE}Detected project type: ${PROJECT_TYPE}${NC}"
  echo -e "${BLUE}App directory: ${APP_DIR}${NC}"
  echo -e "${BLUE}App environment: ${APP_ENV}${NC}"
  if [[ -n "$APP_PORT" ]]; then
    echo -e "${BLUE}Default application port: ${APP_PORT}${NC}"
  fi
  echo -e "${BLUE}To run your application inside the container, consider commands like:${NC}"
  case "$PROJECT_TYPE" in
    python)
      echo "  source $APP_DIR/.venv/bin/activate && python $APP_DIR/app.py"
      echo "  or: source $APP_DIR/.venv/bin/activate && gunicorn -b 0.0.0.0:${APP_PORT:-8000} module:wsgi_app"
      ;;
    node)
      echo "  cd $APP_DIR && npm start"
      ;;
    ruby)
      echo "  cd $APP_DIR && bundle exec puma -b tcp://0.0.0.0:${APP_PORT:-3000}"
      ;;
    go)
      echo "  cd $APP_DIR && go run ./..."
      ;;
    java-maven)
      echo "  cd $APP_DIR && mvn spring-boot:run"
      ;;
    java-gradle)
      echo "  cd $APP_DIR && ./gradlew bootRun"
      ;;
    php)
      echo "  php -S 0.0.0.0:${APP_PORT:-8080} -t $APP_DIR/public"
      ;;
    rust)
      echo "  cd $APP_DIR && cargo run"
      ;;
    *)
      echo "  Navigate to $APP_DIR and run your project's start command."
      ;;
  esac
}

# ======== Main ========
main() {
  log "Starting universal environment setup..."

  detect_pkg_manager
  log "Detected package manager: $PKG_MGR"

  # Ensure common build tools, certificates, git, etc.
  pkg_update_once
  ensure_common_build_tools

  # Prepare directories and user/group
  create_app_user_and_dirs

  # Placeholders for runtime configuration
  detect_project_type
  set_default_port_by_type
  write_env_file

  # Install tech-specific runtimes and dependencies
  case "$PROJECT_TYPE" in
    python) setup_python ;;
    node) setup_node ;;
    ruby) setup_ruby ;;
    go) setup_go ;;
    java-maven) setup_java_maven ;;
    java-gradle) setup_java_gradle ;;
    php) setup_php ;;
    rust) setup_rust ;;
    *)
      warn "Unable to detect project type in $APP_DIR. Ensure the project files are present."
      ;;
  esac

  # Permissions and ownership
  if is_root; then
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" || true
  fi

  print_summary
}

# Change to APP_DIR if it exists; otherwise create it
if [[ ! -d "$APP_DIR" ]]; then
  log "APP_DIR $APP_DIR does not exist; creating..."
  mkdir -p "$APP_DIR"
fi

cd "$APP_DIR"
main "$@"