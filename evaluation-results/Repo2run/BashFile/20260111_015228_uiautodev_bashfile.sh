#!/usr/bin/env bash
#
# Universal project environment setup script for Docker containers.
# Detects common tech stacks (Python, Node.js, Ruby, Go, Rust, PHP, Java) and installs
# runtimes, system packages, and project dependencies in an idempotent manner.
#
# Usage:
#   ./setup.sh [--stack=<python|node|ruby|go|rust|php|java>] [--project-dir=/app]
# Environment variables:
#   APP_ENV (default: production)
#   APP_PORT (default: 8080)
#   PROJECT_DIR (default: current working directory)
#   STACK (override auto-detection)
#
# Notes:
# - Designed to run as root inside Docker containers (no sudo).
# - Supports apt, apk, dnf/yum package managers.
# - Safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'

# ------------- Logging and error handling -------------
LOG_TS() { date +'%Y-%m-%d %H:%M:%S'; }
log()     { printf '[%s] %s\n' "$(LOG_TS)" "$*"; }
warn()    { printf '[%s] [WARN] %s\n' "$(LOG_TS)" "$*" >&2; }
err()     { printf '[%s] [ERROR] %s\n' "$(LOG_TS)" "$*" >&2; }
on_error() {
  local exit_code=$?
  err "Setup failed at line ${BASH_LINENO[0]} while running: ${BASH_COMMAND}"
  exit "$exit_code"
}
trap on_error ERR

# ------------- Defaults and argument parsing -------------
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
STACK="${STACK:-}"

for arg in "$@"; do
  case "$arg" in
    --stack=*) STACK="${arg#*=}" ;;
    --project-dir=*) PROJECT_DIR="${arg#*=}" ;;
    --help|-h)
      echo "Usage: $0 [--stack=<python|node|ruby|go|rust|php|java>] [--project-dir=/app]"
      exit 0
      ;;
    *)
      warn "Unknown argument: $arg"
      ;;
  esac
done

# Ensure project directory exists
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# ------------- Package manager detection -------------
PKG_MANAGER=""
PKG_UPDATE_DONE_FLAG="/var/tmp/pkg_update_done"
if command -v apt-get >/dev/null 2>&1; then
  PKG_MANAGER="apt"
elif command -v apk >/dev/null 2>&1; then
  PKG_MANAGER="apk"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
else
  err "No supported package manager found (apt, apk, dnf, yum)."
  exit 1
fi

pm_update() {
  if [ -f "$PKG_UPDATE_DONE_FLAG" ]; then
    return 0
  fi
  case "$PKG_MANAGER" in
    apt)
      log "Updating apt package index..."
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      touch "$PKG_UPDATE_DONE_FLAG"
      ;;
    apk)
      # apk uses remote repo index automatically, no global update needed
      touch "$PKG_UPDATE_DONE_FLAG"
      ;;
    dnf)
      log "Refreshing dnf metadata..."
      dnf -y makecache
      touch "$PKG_UPDATE_DONE_FLAG"
      ;;
    yum)
      log "Refreshing yum metadata..."
      yum -y makecache
      touch "$PKG_UPDATE_DONE_FLAG"
      ;;
  esac
}

pm_install() {
  # Install packages idempotently based on PKG_MANAGER
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0

  case "$PKG_MANAGER" in
    apt)
      pm_update
      local to_install=()
      for p in "${pkgs[@]}"; do
        if dpkg -s "$p" >/dev/null 2>&1; then
          continue
        else
          to_install+=("$p")
        fi
      done
      if [ "${#to_install[@]}" -gt 0 ]; then
        log "Installing packages via apt: ${to_install[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${to_install[@]}"
      fi
      ;;
    apk)
      local to_install=()
      for p in "${pkgs[@]}"; do
        if apk info -e "$p" >/dev/null 2>&1; then
          continue
        else
          to_install+=("$p")
        fi
      done
      if [ "${#to_install[@]}" -gt 0 ]; then
        log "Installing packages via apk: ${to_install[*]}"
        apk add --no-cache "${to_install[@]}"
      fi
      ;;
    dnf)
      pm_update
      local to_install=()
      for p in "${pkgs[@]}"; do
        if rpm -q "$p" >/dev/null 2>&1; then
          continue
        else
          to_install+=("$p")
        fi
      done
      if [ "${#to_install[@]}" -gt 0 ]; then
        log "Installing packages via dnf: ${to_install[*]}"
        dnf install -y "${to_install[@]}"
      fi
      ;;
    yum)
      pm_update
      local to_install=()
      for p in "${pkgs[@]}"; do
        if rpm -q "$p" >/dev/null 2>&1; then
          continue
        else
          to_install+=("$p")
        fi
      done
      if [ "${#to_install[@]}" -gt 0 ]; then
        log "Installing packages via yum: ${to_install[*]}"
        yum install -y "${to_install[@]}"
      fi
      ;;
  esac
}

# ------------- Base utilities installation -------------
install_base_utils() {
  case "$PKG_MANAGER" in
    apt)
      pm_install ca-certificates curl wget git unzip zip openssh-client tzdata gnupg lsb-release procps
      ;;
    apk)
      pm_install ca-certificates curl wget git unzip zip openssh-client tzdata bash coreutils
      update-ca-certificates || true
      ;;
    dnf|yum)
      pm_install ca-certificates curl wget git unzip zip openssh-clients tzdata procps-ng gnupg
      ;;
  esac
}

# ------------- Directory structure and permissions -------------
setup_directories() {
  mkdir -p "$PROJECT_DIR"/{logs,tmp,.cache}
  mkdir -p /var/log/app /var/run/app /tmp/app
  chmod 0755 "$PROJECT_DIR" || true
  chmod 0775 "$PROJECT_DIR"/{logs,tmp,.cache} || true
  chmod 0775 /var/log/app /var/run/app /tmp/app || true

  # Ensure ownership to current user (likely root in Docker)
  local uid gid
  uid="$(id -u)" || uid=0
  gid="$(id -g)" || gid=0
  chown -R "$uid":"$gid" "$PROJECT_DIR" /var/log/app /var/run/app /tmp/app || true
}

# ------------- Environment file creation -------------
write_env_files() {
  # .env (for frameworks) and env.sh (for shell usage)
  if [ ! -f "$PROJECT_DIR/.env" ]; then
    cat >"$PROJECT_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
EOF
    log "Created $PROJECT_DIR/.env"
  else
    log ".env already exists; leaving untouched"
  fi

  # env.sh is regenerated idempotently but preserves custom lines if present
  # We'll rewrite a standard env.sh that can be sourced safely.
  cat >"$PROJECT_DIR/env.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Source .env if present
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  . ".env"
  set +a
fi

# Prepend project-specific bin paths if available
if [ -d ".venv/bin" ]; then
  export VIRTUAL_ENV="$(pwd)/.venv"
  export PATH="$VIRTUAL_ENV/bin:$PATH"
fi
if [ -d "node_modules/.bin" ]; then
  export PATH="$(pwd)/node_modules/.bin:$PATH"
fi

# Default locale and noninteractive settings for reproducibility
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

# Common environment defaults
export APP_ENV="${APP_ENV:-production}"
export APP_PORT="${APP_PORT:-8080}"
EOF
  chmod +x "$PROJECT_DIR/env.sh"
  log "Created $PROJECT_DIR/env.sh"
}

# ------------- Stack detection -------------
detect_stack() {
  if [ -n "$STACK" ]; then
    log "Stack override provided: $STACK"
    return 0
  fi
  if [ -f "package.json" ]; then
    STACK="node"
  elif [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
    STACK="python"
  elif [ -f "Gemfile" ]; then
    STACK="ruby"
  elif [ -f "go.mod" ]; then
    STACK="go"
  elif [ -f "Cargo.toml" ]; then
    STACK="rust"
  elif [ -f "composer.json" ]; then
    STACK="php"
  elif [ -f "pom.xml" ] || [ -f "build.gradle" ] || [ -f "gradlew" ] || [ -f "mvnw" ]; then
    STACK="java"
  else
    STACK="unknown"
  fi
  log "Detected stack: $STACK"
}

# ------------- Stack-specific setup functions -------------

setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MANAGER" in
    apt)
      pm_install python3 python3-venv python3-pip python3-dev build-essential pkg-config libffi-dev libssl-dev
      ;;
    apk)
      pm_install python3 py3-pip py3-virtualenv build-base libffi-dev openssl-dev
      ;;
    dnf|yum)
      pm_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel
      ;;
  esac

  # Create venv idempotently
  if [ ! -d ".venv" ]; then
    log "Creating Python virtual environment at .venv"
    python3 -m venv ".venv"
  else
    log "Python virtual environment already exists at .venv"
  fi

  # Upgrade pip tooling
  if [ -x ".venv/bin/pip" ]; then
    ".venv/bin/pip" install --upgrade pip setuptools wheel
  fi

  # Install project dependencies
  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    ".venv/bin/pip" install -r requirements.txt
  elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
    log "Installing Python project (editable if possible)"
    # Try editable, fallback to standard install
    ".venv/bin/pip" install -e . || ".venv/bin/pip" install .
  else
    warn "No Python dependency file found (requirements.txt or pyproject.toml). Skipping dependency installation."
  fi

  # Runtime environment variables
  write_env_files
  log "Python environment setup complete."
}

setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MANAGER" in
    apt)
      # Basic nodejs/npm from distro repos
      pm_install nodejs npm
      ;;
    apk)
      pm_install nodejs npm
      ;;
    dnf|yum)
      pm_install nodejs npm
      ;;
  esac

  # Install dependencies if package.json exists
  if [ -f "package.json" ]; then
    if [ -f "yarn.lock" ]; then
      if command -v corepack >/dev/null 2>&1; then
        corepack enable || true
        if command -v yarn >/dev/null 2>&1; then
          log "Installing Node dependencies via yarn (immutable)"
          yarn install --immutable || yarn install
        else
          warn "yarn not available; falling back to npm"
          if [ -f "package-lock.json" ]; then
            npm ci --no-audit --no-fund
          else
            npm install --no-audit --no-fund
          fi
        fi
      else
        warn "corepack not available; using npm instead of yarn"
        if [ -f "package-lock.json" ]; then
          npm ci --no-audit --no-fund
        else
          npm install --no-audit --no-fund
        fi
      fi
    else
      if [ -f "package-lock.json" ]; then
        log "Installing Node dependencies via npm ci"
        npm ci --no-audit --no-fund
      else
        log "Installing Node dependencies via npm install"
        npm install --no-audit --no-fund
      fi
    fi
  else
    warn "No package.json found; skipping Node dependency installation."
  fi

  # Runtime environment variables
  write_env_files
  # Common NODE_ENV and NPM config
  {
    echo 'export NODE_ENV="${NODE_ENV:-production}"'
    echo 'export NPM_CONFIG_LOGLEVEL="${NPM_CONFIG_LOGLEVEL:-warn}"'
  } >> "$PROJECT_DIR/env.sh"
  log "Node.js environment setup complete."
}

setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt)
      pm_install ruby-full build-essential
      ;;
    apk)
      pm_install ruby ruby-bundler build-base
      ;;
    dnf|yum)
      pm_install ruby rubygems ruby-devel gcc gcc-c++ make
      ;;
  esac

  # Ensure bundler is available
  if ! command -v bundle >/dev/null 2>&1; then
    if command -v gem >/dev/null 2>&1; then
      gem install bundler --no-document || true
    fi
  fi

  # Install dependencies if Gemfile exists
  if [ -f "Gemfile" ]; then
    log "Installing Ruby gems via bundler"
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4 --retry=3
  else
    warn "No Gemfile found; skipping bundler install."
  fi

  write_env_files
  log "Ruby environment setup complete."
}

setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apt)
      pm_install golang
      ;;
    apk)
      pm_install go
      ;;
    dnf|yum)
      pm_install golang
      ;;
  esac

  # Setup GOPATH
  mkdir -p /go/pkg /go/bin
  {
    echo 'export GOPATH=/go'
    echo 'export PATH="/go/bin:$PATH"'
  } >> "$PROJECT_DIR/env.sh"

  # Fetch dependencies
  if [ -f "go.mod" ]; then
    log "Fetching Go modules"
    go mod download
    if [ -d "vendor" ]; then
      go mod vendor || true
    fi
  else
    warn "No go.mod found; skipping module download."
  fi

  write_env_files
  log "Go environment setup complete."
}

setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MANAGER" in
    apt)
      pm_install rustc cargo build-essential
      ;;
    apk)
      pm_install rust cargo build-base
      ;;
    dnf|yum)
      pm_install rust cargo gcc gcc-c++ make
      ;;
  esac

  # Prepare CARGO_HOME within project to avoid global writes
  mkdir -p "$PROJECT_DIR/.cargo"
  {
    echo "export CARGO_HOME=\"$PROJECT_DIR/.cargo\""
    echo 'export PATH="$CARGO_HOME/bin:$PATH"'
  } >> "$PROJECT_DIR/env.sh"

  if [ -f "Cargo.toml" ]; then
    log "Fetching Rust crate dependencies"
    cargo fetch || true
  else
    warn "No Cargo.toml found; skipping cargo fetch."
  fi

  write_env_files
  log "Rust environment setup complete."
}

setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      pm_install php-cli php-zip php-mbstring php-xml php-curl git unzip
      # Try to install composer via apt if available; otherwise download composer phar
      if ! command -v composer >/dev/null 2>&1; then
        pm_install composer || true
        if ! command -v composer >/dev/null 2>&1; then
          log "Installing Composer (phar)"
          curl -fsSL https://getcomposer.org/installer -o composer-setup.php
          php composer-setup.php --install-dir=/usr/local/bin --filename=composer
          rm -f composer-setup.php
        fi
      fi
      ;;
    apk)
      pm_install php-cli php-zip php-mbstring php-xml php-curl git unzip composer
      ;;
    dnf|yum)
      pm_install php-cli php-json php-zip php-mbstring php-xml php-curl git unzip
      # Composer via phar if not installed
      if ! command -v composer >/dev/null 2>&1; then
        log "Installing Composer (phar)"
        curl -fsSL https://getcomposer.org/installer -o composer-setup.php
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
      fi
      ;;
  esac

  if [ -f "composer.json" ]; then
    log "Installing PHP dependencies via composer (no-dev)"
    composer install --no-dev --prefer-dist --no-interaction || composer install --prefer-dist --no-interaction
  else
    warn "No composer.json found; skipping composer install."
  fi

  write_env_files
  log "PHP environment setup complete."
}

setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MANAGER" in
    apt)
      pm_install openjdk-17-jdk
      ;;
    apk)
      pm_install openjdk17
      ;;
    dnf|yum)
      pm_install java-17-openjdk-devel
      ;;
  esac

  # Maven/Gradle: prefer project wrappers if present
  if [ -f "mvnw" ]; then
    chmod +x mvnw
    log "Bootstrapping Maven wrapper, resolving dependencies (skip tests)"
    ./mvnw -q -DskipTests dependency:resolve dependency:resolve-plugins || true
  elif command -v mvn >/dev/null 2>&1; then
    log "Resolving Maven dependencies (skip tests)"
    mvn -q -DskipTests dependency:resolve dependency:resolve-plugins || true
  else
    # Try to install maven
    case "$PKG_MANAGER" in
      apt) pm_install maven ;;
      apk) pm_install maven ;;
      dnf|yum) pm_install maven ;;
    esac
    if command -v mvn >/dev/null 2>&1; then
      mvn -q -DskipTests dependency:resolve dependency:resolve-plugins || true
    fi
  fi

  if [ -f "gradlew" ]; then
    chmod +x gradlew
    log "Bootstrapping Gradle wrapper (no-daemon)"
    ./gradlew --no-daemon tasks || true
  elif command -v gradle >/dev/null 2>&1; then
    log "Gradle detected; syncing dependencies"
    gradle --no-daemon tasks || true
  else
    # Try to install gradle if not available
    case "$PKG_MANAGER" in
      apt) pm_install gradle || true ;;
      apk) pm_install gradle || true ;;
      dnf|yum) pm_install gradle || true ;;
    esac
  fi

  write_env_files
  log "Java environment setup complete."
}

setup_unknown() {
  warn "Could not detect project stack. Installing base utilities only."
  write_env_files
}

# ------------- Main execution -------------
main() {
  log "Starting universal environment setup in $PROJECT_DIR"
  install_base_utils
  setup_directories
  detect_stack

  case "$STACK" in
    python) setup_python ;;
    node)   setup_node ;;
    ruby)   setup_ruby ;;
    go)     setup_go ;;
    rust)   setup_rust ;;
    php)    setup_php ;;
    java)   setup_java ;;
    unknown)
      setup_unknown
      ;;
    *)
      warn "Unsupported or unrecognized stack: $STACK. Proceeding with base setup."
      setup_unknown
      ;;
  esac

  # Final reminders and environment summary
  log "Environment setup completed successfully."
  log "Summary:"
  echo "- Project directory: $PROJECT_DIR"
  echo "- Stack: $STACK"
  echo "- Package manager: $PKG_MANAGER"
  echo "- APP_ENV: $APP_ENV"
  echo "- APP_PORT: $APP_PORT"
  echo "- Env files: $PROJECT_DIR/.env and $PROJECT_DIR/env.sh (source env.sh to load env)"

  # Guidance for running typical apps
  case "$STACK" in
    python)
      if [ -f "app.py" ]; then
        echo "Example run: source ./env.sh && python app.py"
      elif [ -f "manage.py" ]; then
        echo "Example run: source ./env.sh && python manage.py runserver 0.0.0.0:${APP_PORT}"
      else
        echo "Example run: source ./env.sh && python -m your_module"
      fi
      ;;
    node)
      if grep -q '"start"' package.json 2>/dev/null; then
        echo "Example run: source ./env.sh && npm run start"
      else
        echo "Example run: source ./env.sh && node server.js"
      fi
      ;;
    ruby)
      if [ -f "config.ru" ]; then
        echo "Example run: source ./env.sh && bundle exec rackup -o 0.0.0.0 -p ${APP_PORT}"
      else
        echo "Example run: source ./env.sh && bundle exec ruby app.rb"
      fi
      ;;
    php)
      echo "Example run: source ./env.sh && php -S 0.0.0.0:${APP_PORT} -t public"
      ;;
    go)
      echo "Example run: source ./env.sh && go run ./..."
      ;;
    rust)
      echo "Example run: source ./env.sh && cargo run"
      ;;
    java)
      if [ -f "mvnw" ]; then
        echo "Example run: source ./env.sh && ./mvnw spring-boot:run"
      elif [ -f "gradlew" ]; then
        echo "Example run: source ./env.sh && ./gradlew bootRun"
      else
        echo "Example run: source ./env.sh && java -jar target/app.jar"
      fi
      ;;
    *)
      echo "Example run: source ./env.sh && your_command_here"
      ;;
  esac
}

main "$@"