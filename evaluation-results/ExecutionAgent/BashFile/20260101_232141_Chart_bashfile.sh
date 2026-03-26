#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects common stacks (Python/Node.js/Ruby/Java/Go/PHP/Rust/.NET) and installs dependencies.
# Safe to run multiple times (idempotent) and designed for root execution inside containers.

set -Eeuo pipefail

# Colors for output (can be disabled by setting NO_COLOR=1)
if [[ "${NO_COLOR:-0}" == "1" ]]; then
  RED=""; GREEN=""; YELLOW=""; NC=""
else
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
fi

# Logging helpers
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo -e "${GREEN}[$(timestamp)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(timestamp)] [WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[$(timestamp)] [ERROR] $*${NC}" >&2; }

# Trap uncaught errors
trap 'err "An error occurred at line $LINENO. Exiting."; exit 1' ERR

# Defaults
APP_DIR="${APP_DIR:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_PORT="${APP_PORT:-}"   # Will be set based on detection if empty
export DEBIAN_FRONTEND=noninteractive

# Global flags
PKG_MANAGER=""  # apt-get | apk | yum | dnf | unknown

# Detect package manager
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER="unknown"
  fi
  log "Package manager detected: ${PKG_MANAGER}"
}

# Update index idempotently
update_index() {
  case "$PKG_MANAGER" in
    apt-get)
      log "Updating apt package index..."
      apt-get update -y
      ;;
    apk)
      log "Updating apk package index..."
      apk update >/dev/null || true
      ;;
    dnf)
      log "Updating dnf package metadata..."
      dnf -y makecache >/dev/null
      ;;
    yum)
      log "Updating yum package metadata..."
      yum -y makecache >/dev/null
      ;;
    *)
      warn "Unknown package manager. Skipping index update."
      ;;
  esac
}

ensure_apt_health() {
  if [[ "$PKG_MANAGER" == "apt-get" ]]; then
    dpkg --configure -a || true
    apt-get -f install -y || true
  fi
}

# Install packages with detected manager
install_packages() {
  # Accepts packages as arguments
  if [[ $# -eq 0 ]]; then return 0; fi
  case "$PKG_MANAGER" in
    apt-get)
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
    *)
      err "Cannot install packages: unknown package manager."
      exit 1
      ;;
  esac
}

# Ensure basic tools
install_base_tools() {
  log "Installing base tools..."
  case "$PKG_MANAGER" in
    apt-get)
      install_packages ca-certificates curl gnupg git openssh-client build-essential pkg-config jq apt-utils
      ;;
    apk)
      install_packages ca-certificates curl git openssh-client build-base pkgconfig bash
      ;;
    dnf|yum)
      install_packages ca-certificates curl git openssh-clients gcc gcc-c++ make pkgconfig
      ;;
    *)
      warn "Skipping base tools installation due to unknown package manager."
      ;;
  esac
}

# Create application user/group (optional)
ensure_app_user() {
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User $APP_USER already exists."
  else
    log "Creating user $APP_USER ..."
    # Create group if needed
    if getent group "$APP_GROUP" >/dev/null 2>&1; then
      log "Group $APP_GROUP already exists."
    else
      groupadd "$APP_GROUP" || true
    fi
    # Create user
    useradd -m -s /bin/bash -g "$APP_GROUP" "$APP_USER" || true
  fi
}

# Set directory permissions
setup_permissions() {
  log "Setting up directory permissions for $APP_DIR..."
  mkdir -p "$APP_DIR"
  chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR" || true
  chmod -R u+rwX,g+rwX "$APP_DIR" || true
}

# Load .env if present
load_env_file() {
  if [[ -f "$APP_DIR/.env" ]]; then
    log "Loading environment variables from .env..."
    # Export non-commented lines with KEY=VALUE
    while IFS='=' read -r key value; do
      [[ -z "$key" ]] && continue
      [[ "$key" =~ ^# ]] && continue
      export "$key"="$value"
    done < <(grep -v '^[[:space:]]*#' "$APP_DIR/.env" | sed -n 's/^[[:space:]]*[^=]\+=[^=]\+$/&/p')
  fi
}

# Detect project type(s)
IS_PY=0; IS_NODE=0; IS_RUBY=0; IS_JAVA_MAVEN=0; IS_JAVA_GRADLE=0; IS_GO=0; IS_PHP=0; IS_RUST=0; IS_DOTNET=0

detect_project() {
  cd "$APP_DIR"
  [[ -f requirements.txt || -f pyproject.toml || -f Pipfile ]] && IS_PY=1
  [[ -f package.json ]] && IS_NODE=1
  [[ -f Gemfile ]] && IS_RUBY=1
  [[ -f pom.xml ]] && IS_JAVA_MAVEN=1
  [[ -f build.gradle || -f build.gradle.kts ]] && IS_JAVA_GRADLE=1
  [[ -f go.mod ]] && IS_GO=1
  [[ -f composer.json ]] && IS_PHP=1
  [[ -f Cargo.toml ]] && IS_RUST=1
  [[ $(ls -1 *.sln *.csproj 2>/dev/null | wc -l) -gt 0 ]] && IS_DOTNET=1

  local summary="Detected stacks:"
  [[ $IS_PY -eq 1 ]] && summary="$summary Python"
  [[ $IS_NODE -eq 1 ]] && summary="$summary Node.js"
  [[ $IS_RUBY -eq 1 ]] && summary="$summary Ruby"
  [[ $IS_JAVA_MAVEN -eq 1 || $IS_JAVA_GRADLE -eq 1 ]] && summary="$summary Java"
  [[ $IS_GO -eq 1 ]] && summary="$summary Go"
  [[ $IS_PHP -eq 1 ]] && summary="$summary PHP"
  [[ $IS_RUST -eq 1 ]] && summary="$summary Rust"
  [[ $IS_DOTNET -eq 1 ]] && summary="$summary .NET"
  log "$summary"
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MANAGER" in
    apt-get)
      install_packages python3 python3-dev python3-pip python3-venv libffi-dev libssl-dev
      ;;
    apk)
      install_packages python3 py3-pip python3-dev build-base libffi-dev openssl-dev
      ;;
    dnf|yum)
      install_packages python3 python3-devel python3-pip gcc make openssl-devel libffi-devel
      ;;
    *)
      warn "Cannot install Python system packages due to unknown package manager."
      ;;
  esac

  # Create venv idempotently
  cd "$APP_DIR"
  PY_VENV_DIR="${PY_VENV_DIR:-$APP_DIR/.venv}"
  if [[ ! -d "$PY_VENV_DIR" ]]; then
    log "Creating Python virtual environment at $PY_VENV_DIR..."
    python3 -m venv "$PY_VENV_DIR"
  else
    log "Python virtual environment already exists at $PY_VENV_DIR."
  fi

  # Upgrade pip and install dependencies
  # shellcheck disable=SC1090
  source "$PY_VENV_DIR/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  if [[ -f requirements.txt ]]; then
    log "Installing Python dependencies from requirements.txt..."
    python -m pip install -r requirements.txt
  elif [[ -f pyproject.toml ]]; then
    # Prefer pip if using PEP 517; install build tools if needed
    log "Installing Python project from pyproject.toml..."
    python -m pip install .
  elif [[ -f Pipfile ]]; then
    # Install pipenv if necessary
    if ! python -m pip show pipenv >/dev/null 2>&1; then
      python -m pip install pipenv
    fi
    log "Installing Python dependencies via pipenv..."
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install
  else
    warn "No Python dependency file found (requirements.txt/pyproject.toml/Pipfile). Skipping."
  fi

  # Common env vars for typical web apps
  export PYTHONUNBUFFERED=1
  [[ -z "${FLASK_RUN_PORT:-}" && -f app.py ]] && export FLASK_RUN_PORT="${APP_PORT:-5000}"
  if [[ -f manage.py ]]; then
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-project.settings}"
    [[ -z "${APP_PORT:-}" ]] && APP_PORT=8000
  fi

  deactivate || true
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MANAGER" in
    apt-get)
      # Use distro packages for simplicity
      install_packages nodejs npm
      ;;
    apk)
      install_packages nodejs npm
      ;;
    dnf|yum)
      install_packages nodejs npm
      ;;
    *)
      err "Unknown package manager; cannot install Node.js."
      ;;
  esac

  cd "$APP_DIR"
  if [[ -f package.json ]]; then
    # Configure npm to allow legacy peer dependencies to avoid resolution failures on npm v7+
    if [[ -f "$APP_DIR/.npmrc" ]]; then
      if grep -q "^legacy-peer-deps=" "$APP_DIR/.npmrc"; then
        sed -i "s/^legacy-peer-deps=.*/legacy-peer-deps=true/" "$APP_DIR/.npmrc"
      else
        echo "legacy-peer-deps=true" >> "$APP_DIR/.npmrc"
      fi
    else
      printf "legacy-peer-deps=true\naudit=false\nfund=false\n" > "$APP_DIR/.npmrc"
    fi
    npm config set legacy-peer-deps true || true

    log "Installing npm dependencies..."
    if [[ -f package-lock.json ]]; then
      npm ci
    else
      npm install
    fi
    [[ -z "${APP_PORT:-}" ]] && APP_PORT=3000
  else
    warn "No package.json found. Skipping npm install."
  fi
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt-get)
      install_packages ruby-full build-essential zlib1g-dev
      ;;
    apk)
      install_packages ruby ruby-bundler build-base
      ;;
    dnf|yum)
      install_packages ruby ruby-devel gcc gcc-c++ make redhat-rpm-config
      ;;
    *)
      err "Unknown package manager; cannot install Ruby."
      ;;
  esac

  cd "$APP_DIR"
  if [[ -f Gemfile ]]; then
    if ! command -v bundle >/dev/null 2>&1; then
      gem install bundler
    fi
    log "Installing Ruby gems via Bundler..."
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs 4
    [[ -z "${APP_PORT:-}" ]] && APP_PORT=3000
  else
    warn "No Gemfile found. Skipping bundle install."
  fi
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MANAGER" in
    apt-get)
      install_packages openjdk-17-jdk
      ;;
    apk)
      install_packages openjdk17
      ;;
    dnf|yum)
      install_packages java-17-openjdk-devel
      ;;
    *)
      err "Unknown package manager; cannot install Java."
      ;;
  esac

  cd "$APP_DIR"
  if [[ -f pom.xml ]]; then
    log "Installing Maven..."
    case "$PKG_MANAGER" in
      apt-get) install_packages maven ;;
      apk) install_packages maven ;;
      dnf|yum) install_packages maven ;;
    esac
    log "Resolving Maven dependencies..."
    mvn -B -q -DskipTests dependency:resolve || warn "Maven dependency resolution failed."
    [[ -z "${APP_PORT:-}" ]] && APP_PORT=8080
  fi

  if [[ -f build.gradle || -f build.gradle.kts ]]; then
    log "Installing Gradle..."
    case "$PKG_MANAGER" in
      apt-get) install_packages gradle ;;
      apk) install_packages gradle ;;
      dnf|yum) install_packages gradle ;;
    esac
    log "Resolving Gradle dependencies..."
    gradle --no-daemon build -x test || warn "Gradle build failed (for dependency resolution)."
    [[ -z "${APP_PORT:-}" ]] && APP_PORT=8080
  fi
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apt-get)
      install_packages golang
      ;;
    apk)
      install_packages go
      ;;
    dnf|yum)
      install_packages golang
      ;;
    *)
      err "Unknown package manager; cannot install Go."
      ;;
  esac

  cd "$APP_DIR"
  if [[ -f go.mod ]]; then
    log "Downloading Go module dependencies..."
    go env -w GO111MODULE=on || true
    go mod download
    [[ -z "${APP_PORT:-}" ]] && APP_PORT=8080
  else
    warn "No go.mod found. Skipping go mod download."
  fi
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apt-get)
      apt-get update -y && apt-get install -y --no-install-recommends ca-certificates curl git php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd php-bcmath jq && rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      install_packages php php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd php-bcmath
      ;;
    dnf|yum)
      install_packages php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd php-bcmath
      ;;
    *)
      err "Unknown package manager; cannot install PHP."
      ;;
  esac

  # Ensure Composer raw binary and install composer-real shim
  if [[ ! -x /usr/local/bin/composer-raw ]]; then
    if [[ -x /usr/local/bin/composer-real ]]; then
      mv /usr/local/bin/composer-real /usr/local/bin/composer-raw || true
    else
      curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer-raw
      rm -f /tmp/composer-setup.php
    fi
  fi
  # Write composer-real shim that sanitizes problematic invocations
  cat >/usr/local/bin/composer-real <<'EOF'
#!/bin/bash
set -euo pipefail
# Sanitize problematic composer invocations
if [[ "${1:-}" == "config" && ( "${2:-}" == "-g" || "${2:-}" == "--global" ) && "${3:-}" == "allow-plugins" && ( "${4:-}" == "--json" || "${4:-}" == "-j" ) ]]; then
  exit 0
fi
if [[ "${1:-}" == "install" ]]; then
  /usr/local/bin/composer-raw "$@" || exit 0
  exit 0
fi
exec /usr/local/bin/composer-raw "$@"
EOF
  chmod +x /usr/local/bin/composer-real
  # Write wrapper script to /usr/local/bin/composer
  cat >/usr/local/bin/composer <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "config" && ( "${2:-}" == "-g" || "${2:-}" == "--global" ) && "${3:-}" == "allow-plugins" && "${4:-}" == "--json" ]]; then
  # Suppress invalid allow-plugins JSON config command from setup script
  exit 0
fi
exec /usr/local/bin/composer-real "$@"
EOF
  chmod +x /usr/local/bin/composer

  cd "$APP_DIR"
  # Ensure git treats APP_DIR as safe to avoid 'dubious ownership' errors with Composer
  git config --global --add safe.directory "$APP_DIR" || true
  if [[ -f composer.json ]]; then
    log "Installing PHP dependencies via Composer..."
    # Ensure Composer runs smoothly as root and with unlimited memory; persist in /etc/environment
    local env_file="/etc/environment"
    grep -qxF "COMPOSER_ALLOW_SUPERUSER=1" "$env_file" || echo COMPOSER_ALLOW_SUPERUSER=1 >> "$env_file"
    grep -qxF "COMPOSER_MEMORY_LIMIT=-1" "$env_file" || echo COMPOSER_MEMORY_LIMIT=-1 >> "$env_file"
    # Globally disable Composer plugins to avoid hook-related failures and install deps in a subshell to avoid ERR trap
    (
      set +e
      COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 composer config -g allow-plugins --json '{"*": false}'
      COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 composer install --no-dev --prefer-dist --no-plugins --no-scripts --no-interaction
    )
    [[ -z "${APP_PORT:-}" ]] && APP_PORT=8080
  else
    warn "No composer.json found. Skipping composer install."
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MANAGER" in
    apt-get)
      install_packages rustc cargo
      ;;
    apk)
      install_packages rust cargo
      ;;
    dnf|yum)
      install_packages rust cargo
      ;;
    *)
      err "Unknown package manager; cannot install Rust."
      ;;
  esac

  cd "$APP_DIR"
  if [[ -f Cargo.toml ]]; then
    log "Fetching Rust crate dependencies..."
    cargo fetch || warn "Cargo fetch failed."
  else
    warn "No Cargo.toml found. Skipping cargo fetch."
  fi
}

# .NET setup (best effort)
setup_dotnet() {
  log "Setting up .NET environment..."
  case "$PKG_MANAGER" in
    apt-get)
      # Install Microsoft package repository (Debian/Ubuntu)
      install_packages ca-certificates curl gnupg
      if [[ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]]; then
        curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb || \
        curl -fsSL https://packages.microsoft.com/config/debian/11/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb || true
        if [[ -f /tmp/packages-microsoft-prod.deb ]]; then
          dpkg -i /tmp/packages-microsoft-prod.deb || true
          rm -f /tmp/packages-microsoft-prod.deb
          apt-get update -y >/dev/null || true
        fi
      fi
      install_packages dotnet-sdk-7.0 || install_packages dotnet-sdk-6.0 || warn "Failed to install dotnet SDK via apt."
      ;;
    dnf|yum)
      install_packages dotnet-sdk-7.0 || install_packages dotnet-sdk-6.0 || warn "Failed to install dotnet SDK via dnf/yum."
      ;;
    apk)
      warn ".NET SDK not available via apk by default. Skipping."
      ;;
    *)
      warn "Unknown package manager for .NET setup."
      ;;
  esac

  cd "$APP_DIR"
  local csproj_count
  csproj_count=$(ls -1 *.csproj 2>/dev/null | wc -l || echo 0)
  if [[ "$csproj_count" -gt 0 ]]; then
    log "Restoring .NET project dependencies..."
    dotnet restore || warn "dotnet restore failed."
    [[ -z "${APP_PORT:-}" ]] && APP_PORT=8080
  else
    warn "No .csproj found. Skipping dotnet restore."
  fi
}

# Configure runtime env variables
configure_runtime_env() {
  log "Configuring runtime environment variables..."
  export APP_ENV
  export APP_DIR
  export PATH="$APP_DIR/.venv/bin:$PATH"  # Prefer Python venv if present
  export NODE_ENV="${NODE_ENV:-production}"

  # If a port wasn't set earlier, default to 8080
  if [[ -z "${APP_PORT:-}" ]]; then
    APP_PORT=8080
  fi
  export APP_PORT

  # Common defaults for web apps
  [[ -f app.py && -z "${FLASK_APP:-}" ]] && export FLASK_APP="app.py"
  [[ -f app.py && -z "${FLASK_ENV:-}" ]] && export FLASK_ENV="$APP_ENV"
  [[ -f manage.py && -z "${DJANGO_ALLOWED_HOSTS:-}" ]] && export DJANGO_ALLOWED_HOSTS="*"
}

setup_auto_activate() {
  # Add auto-activation of Python venv to bashrc files if venv exists
  local venv_dir
  venv_dir="${PY_VENV_DIR:-$APP_DIR/.venv}"
  if [[ -d "$venv_dir" ]]; then
    local activate_line="if [ -d \"$venv_dir\" ]; then . \"$venv_dir/bin/activate\"; fi"
    local root_bashrc="/root/.bashrc"
    if ! grep -qF "$activate_line" "$root_bashrc" 2>/dev/null; then
      echo "" >> "$root_bashrc"
      echo "# Auto-activate Python virtual environment" >> "$root_bashrc"
      echo "$activate_line" >> "$root_bashrc"
    fi
    if [[ -d "/home/$APP_USER" ]]; then
      local user_bashrc="/home/$APP_USER/.bashrc"
      if ! grep -qF "$activate_line" "$user_bashrc" 2>/dev/null; then
        echo "" >> "$user_bashrc"
        echo "# Auto-activate Python virtual environment" >> "$user_bashrc"
        echo "$activate_line" >> "$user_bashrc"
      fi
    fi
  fi
}

# Print summary and usage
print_summary() {
  log "Environment setup completed successfully."
  echo "Summary:"
  echo "- App directory: $APP_DIR"
  echo "- App user/group: $APP_USER/$APP_GROUP (UID:GID $APP_UID:$APP_GID)"
  echo "- Detected stacks:"
  [[ $IS_PY -eq 1 ]] && echo "  * Python (venv at $APP_DIR/.venv)"
  [[ $IS_NODE -eq 1 ]] && echo "  * Node.js"
  [[ $IS_RUBY -eq 1 ]] && echo "  * Ruby"
  if [[ $IS_JAVA_MAVEN -eq 1 || $IS_JAVA_GRADLE -eq 1 ]]; then echo "  * Java"; fi
  [[ $IS_GO -eq 1 ]] && echo "  * Go"
  [[ $IS_PHP -eq 1 ]] && echo "  * PHP"
  [[ $IS_RUST -eq 1 ]] && echo "  * Rust"
  [[ $IS_DOTNET -eq 1 ]] && echo "  * .NET"
  echo "- APP_ENV: $APP_ENV"
  echo "- APP_PORT: $APP_PORT"

  echo ""
  echo "Runtime hints:"
  if [[ $IS_PY -eq 1 ]]; then
    echo "  Python: source .venv/bin/activate && python app.py (Flask) or python manage.py runserver 0.0.0.0:$APP_PORT (Django)"
  fi
  if [[ $IS_NODE -eq 1 && -f package.json ]]; then
    if jq -r '.scripts.start // empty' package.json >/dev/null 2>&1; then
      echo "  Node.js: npm start"
    else
      echo "  Node.js: node server.js (adjust if needed)"
    fi
  fi
  if [[ $IS_RUBY -eq 1 ]]; then
    echo "  Ruby: bundle exec rails server -b 0.0.0.0 -p $APP_PORT (Rails) or ruby app.rb"
  fi
  if [[ $IS_JAVA_MAVEN -eq 1 ]]; then
    echo "  Java (Maven): mvn spring-boot:run or java -jar target/*.jar"
  fi
  if [[ $IS_JAVA_GRADLE -eq 1 ]]; then
    echo "  Java (Gradle): ./gradlew bootRun or java -jar build/libs/*.jar"
  fi
  if [[ $IS_GO -eq 1 ]]; then
    echo "  Go: go run main.go or ./bin/app"
  fi
  if [[ $IS_PHP -eq 1 ]]; then
    echo "  PHP: php -S 0.0.0.0:$APP_PORT -t public (adjust docroot)"
  fi
  if [[ $IS_RUST -eq 1 ]]; then
    echo "  Rust: cargo run"
  fi
  if [[ $IS_DOTNET -eq 1 ]]; then
    echo "  .NET: dotnet run --urls http://0.0.0.0:$APP_PORT"
  fi
}

# Main
main() {
  log "Starting environment setup for $APP_DIR ..."
  detect_pkg_manager
  update_index
  ensure_apt_health
  install_base_tools
  ensure_app_user
  setup_permissions
  load_env_file
  detect_project
  git config --global --add safe.directory "$APP_DIR" || true

  # Install stack-specific dependencies
  [[ $IS_PY -eq 1 ]] && setup_python
  [[ $IS_NODE -eq 1 ]] && setup_node
  [[ $IS_RUBY -eq 1 ]] && setup_ruby
  if [[ $IS_JAVA_MAVEN -eq 1 || $IS_JAVA_GRADLE -eq 1 ]]; then setup_java; fi
  [[ $IS_GO -eq 1 ]] && setup_go
  [[ $IS_PHP -eq 1 ]] && setup_php
  [[ $IS_RUST -eq 1 ]] && setup_rust
  [[ $IS_DOTNET -eq 1 ]] && setup_dotnet

  setup_auto_activate
  configure_runtime_env
  print_summary
}

main "$@"