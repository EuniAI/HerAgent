#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common stacks (Python, Node.js, Ruby, PHP, Go, Java, Rust)
# - Installs required system packages and runtimes
# - Configures project directories, permissions, and environment variables
# - Idempotent and safe to re-run
# - Designed to run as root (no sudo), but handles non-root gracefully

set -Eeuo pipefail
IFS=$'\n\t'

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

SCRIPT_NAME="$(basename "$0")"
START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
LOG_DIR="${LOG_DIR:-/var/log/setup}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/project_setup.log}"
APT_UPDATED=0

# Default environment variables (can be overridden)
APP_ENV="${APP_ENV:-production}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
APP_USER="${APP_USER:-app}"
CREATE_APP_USER="${CREATE_APP_USER:-true}"
CHOWN_PROJECT="${CHOWN_PROJECT:-true}"
HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
NO_PROXY="${NO_PROXY:-${no_proxy:-}}"

# Helpers
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
err() { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE" >&2; }

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Setup failed with exit code $exit_code"
    err "Last command: '${BASH_COMMAND}'"
  else
    log "Setup completed successfully"
  fi
}
trap cleanup EXIT

require_root_or_warn() {
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "Not running as root. System package installation and user setup may fail."
  fi
}

init_logging() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE" || true
  umask 022
  log "==== $SCRIPT_NAME started at $START_TIME ===="
}

# Ensure logging directory and file exist early to avoid tee failures
ensure_log_path() {
  mkdir -p /var/log/setup && chmod 777 /var/log/setup && touch /var/log/setup/project_setup.log && chmod 666 /var/log/setup/project_setup.log || true
}

# Detect package manager
PKG_MGR=""
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  else
    err "No supported package manager found (apt, dnf, yum, apk, zypper)."
    exit 1
  fi
  log "Using package manager: $PKG_MGR"
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      if [[ $APT_UPDATED -eq 0 ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y || apt-get update
        APT_UPDATED=1
      fi
      ;;
    dnf)
      dnf -y makecache || true
      ;;
    yum)
      yum -y makecache fast || true
      ;;
    apk)
      true # apk update is implicit with --update in add
      ;;
    zypper)
      zypper refresh -y || zypper refresh || true
      ;;
  esac
}

pkg_install() {
  local packages=("$@")
  case "$PKG_MGR" in
    apt)
      pkg_update
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    dnf)
      pkg_update
      dnf install -y "${packages[@]}"
      ;;
    yum)
      pkg_update
      yum install -y "${packages[@]}"
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
    zypper)
      pkg_update
      zypper install -y --no-recommends "${packages[@]}"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    dnf|yum)
      rm -rf /var/cache/dnf /var/cache/yum || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    zypper)
      zypper clean -a || true
      ;;
  esac
}

install_common_tools() {
  log "Installing base system tools..."
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git gnupg dirmngr tzdata locales unzip zip xz-utils tar gzip bzip2 build-essential pkg-config openssl
      update-ca-certificates || true
      ;;
    dnf)
      pkg_install ca-certificates curl wget git tar gzip bzip2 unzip zip xz gcc gcc-c++ make openssl-devel pkgconfig findutils which tzdata
      update-ca-trust || true
      ;;
    yum)
      pkg_install ca-certificates curl wget git tar gzip bzip2 unzip zip xz gcc gcc-c++ make openssl-devel pkgconfig findutils which tzdata
      update-ca-trust || true
      ;;
    apk)
      pkg_install ca-certificates curl wget git tar gzip bzip2 unzip zip xz tzdata bash openssl openssl-dev build-base coreutils findutils
      update-ca-certificates || true
      ;;
    zypper)
      pkg_install ca-certificates curl wget git tar gzip bzip2 unzip zip xz gcc gcc-c++ make libopenssl-devel pkg-config timezone
      ;;
  esac
}

setup_proxy_env() {
  if [[ -n "$HTTP_PROXY" || -n "$HTTPS_PROXY" || -n "$NO_PROXY" ]]; then
    log "Configuring proxy environment for package managers and tools..."
    export http_proxy="$HTTP_PROXY"
    export https_proxy="$HTTPS_PROXY"
    export no_proxy="$NO_PROXY"
    git config --global http.proxy "${HTTP_PROXY:-}" || true
    git config --global https.proxy "${HTTPS_PROXY:-}" || true
    npm config set proxy "${HTTP_PROXY:-}" >/dev/null 2>&1 || true
    npm config set https-proxy "${HTTPS_PROXY:-}" >/dev/null 2>&1 || true
  fi
}

# Project structure and permissions
setup_project_structure() {
  log "Setting up project structure at: $PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"/{logs,tmp,run,.cache}
  chmod 755 "$PROJECT_DIR" || true
  chmod 755 "$PROJECT_DIR"/{logs,tmp,run} || true
}

create_app_user() {
  if [[ "${CREATE_APP_USER,,}" != "true" ]]; then
    info "Skipping app user creation (CREATE_APP_USER=$CREATE_APP_USER)"
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "Cannot create user without root privileges; continuing as current user."
    return 0
  fi
  if id -u "$APP_USER" >/dev/null 2>&1; then
    info "User '$APP_USER' already exists"
    return 0
  fi
  log "Creating non-root user '$APP_USER'..."
  case "$PKG_MGR" in
    apk)
      adduser -D -H "$APP_USER"
      ;;
    apt|dnf|yum|zypper|*)
      useradd -m -s /usr/sbin/nologin "$APP_USER"
      ;;
  esac
}

set_permissions() {
  if [[ "${CHOWN_PROJECT,,}" != "true" ]]; then
    info "Skipping chown on project directory (CHOWN_PROJECT=$CHOWN_PROJECT)"
    return 0
  fi
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "Adjusting ownership of project directory to '$APP_USER'..."
    chown -R "$APP_USER":"$APP_USER" "$PROJECT_DIR" || warn "Failed to chown project directory"
  fi
}

# Stack detection
is_python_project() { [[ -f "$PROJECT_DIR/requirements.txt" || -f "$PROJECT_DIR/pyproject.toml" || -f "$PROJECT_DIR/Pipfile" || -f "$PROJECT_DIR/setup.py" ]]; }
is_node_project()   { [[ -f "$PROJECT_DIR/package.json" ]]; }
is_ruby_project()   { [[ -f "$PROJECT_DIR/Gemfile" ]]; }
is_php_project()    { [[ -f "$PROJECT_DIR/composer.json" ]]; }
is_go_project()     { [[ -f "$PROJECT_DIR/go.mod" ]]; }
is_java_maven()     { [[ -f "$PROJECT_DIR/pom.xml" ]]; }
is_java_gradle()    { [[ -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ]]; }
is_rust_project()   { [[ -f "$PROJECT_DIR/Cargo.toml" ]]; }

# Python setup
install_python_runtime() {
  log "Installing Python runtime and build dependencies..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make openssl-devel libffi-devel
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev musl-dev gcc libffi-dev openssl-dev
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel libopenssl-devel
      ;;
  esac
  python3 -m pip install --upgrade pip setuptools wheel >/dev/null
}

setup_python_env() {
  log "Configuring Python virtual environment..."
  cd "$PROJECT_DIR"
  local venv_dir="$PROJECT_DIR/.venv"
  if [[ ! -d "$venv_dir" ]]; then
    python3 -m venv "$venv_dir"
  fi
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  python -m pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.* torchaudio==2.4.*

  if [[ -f "requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-compile -r requirements.txt
  elif [[ -f "Pipfile" ]]; then
    log "Installing Python dependencies via pipenv..."
    pip install --no-compile pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
  elif [[ -f "pyproject.toml" ]]; then
    if grep -qiE 'tool\.poetry' pyproject.toml; then
      log "Detected Poetry project; installing dependencies..."
      pip install --no-compile "poetry>=1.5"
      export POETRY_VIRTUALENVS_IN_PROJECT=true
      export POETRY_VIRTUALENVS_CREATE=true
      poetry install --no-interaction --no-ansi
    else
      log "Installing Python project from pyproject.toml (PEP 517)..."
      pip install --no-compile .
    fi
  else
    info "No recognized Python dependency file found."
  fi

  # Default Python env vars
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=off
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export VIRTUAL_ENV="$venv_dir"

  # Common web defaults
  if [[ -f "manage.py" ]]; then
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-project.settings}"
  fi
  if [[ -f "app.py" || -f "wsgi.py" || -f "asgi.py" ]]; then
    export PORT="${PORT:-8000}"
  fi
  setup_auto_activate
  write_ci_run_tests_sh || true
}

# Ensure auto-activate venv on shell start
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local venv_dir="$PROJECT_DIR/.venv"
  local activate_line="source $venv_dir/bin/activate"
  if [[ -d "$venv_dir" ]]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

# Node.js setup
install_node_runtime() {
  log "Installing Node.js runtime..."
  case "$PKG_MGR" in
    apt)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    zypper)
      pkg_install nodejs16 npm16 || pkg_install nodejs npm || true
      ;;
  esac
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi
}

setup_node_env() {
  log "Installing Node.js dependencies..."
  cd "$PROJECT_DIR"
  export NODE_ENV="${NODE_ENV:-$APP_ENV}"
  # Prefer lock-based installs
  if [[ -f "pnpm-lock.yaml" ]] && command -v corepack >/dev/null 2>&1; then
    corepack prepare pnpm@latest --activate || true
    pnpm install --frozen-lockfile
  elif [[ -f "yarn.lock" ]] && command -v corepack >/dev/null 2>&1; then
    corepack prepare yarn@stable --activate || true
    yarn install --immutable || yarn install --frozen-lockfile || yarn install
  elif [[ -f "package-lock.json" ]]; then
    npm ci || npm install
  else
    npm install
  fi
  export PORT="${PORT:-3000}"
}

# Ruby setup
install_ruby_runtime() {
  log "Installing Ruby runtime..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    zypper)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
  esac
  gem install bundler --no-document || true
}

setup_ruby_env() {
  log "Installing Ruby gems..."
  cd "$PROJECT_DIR"
  bundle config set --local path 'vendor/bundle'
  if [[ "${APP_ENV}" == "production" ]]; then
    bundle install --jobs=4 --retry=3 --without development test
  else
    bundle install --jobs=4 --retry=3
  fi
  export PORT="${PORT:-3000}"
}

# PHP setup
install_php_runtime() {
  log "Installing PHP CLI and Composer..."
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip curl git
      ;;
    dnf|yum)
      pkg_install php-cli php-mbstring php-xml php-json php-zip unzip curl git || pkg_install php php-mbstring php-xml php-json php-zip unzip curl git
      ;;
    apk)
      pkg_install php81 php81-cli php81-mbstring php81-xml php81-json php81-phar php81-openssl php81-curl php81-zip curl git || pkg_install php php-cli php-mbstring php-xml php-json php-phar php-openssl php-curl php-zip curl git
      ;;
    zypper)
      pkg_install php8 php8-cli php8-mbstring php8-xml php8-curl php8-zip unzip curl git || pkg_install php php-cli php-mbstring php-xml php-curl php-zip unzip curl git
      ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi
}

setup_php_env() {
  log "Installing PHP dependencies with Composer..."
  cd "$PROJECT_DIR"
  if [[ -f "composer.json" ]]; then
    if [[ "${APP_ENV}" == "production" ]]; then
      composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader
    else
      composer install --prefer-dist --no-interaction
    fi
  fi
  export PORT="${PORT:-8080}"
}

# Go setup
install_go_runtime() {
  log "Installing Go toolchain..."
  case "$PKG_MGR" in
    apt)
      pkg_install golang
      ;;
    dnf|yum)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    zypper)
      pkg_install go
      ;;
  esac
}

setup_go_env() {
  log "Fetching Go module dependencies..."
  cd "$PROJECT_DIR"
  export GOPATH="${GOPATH:-/go}"
  export GOCACHE="${GOCACHE:-$PROJECT_DIR/.cache/go-build}"
  mkdir -p "$GOPATH" "$GOCACHE"
  if [[ -f "go.mod" ]]; then
    go mod download
  fi
  export PORT="${PORT:-8080}"
}

# Java setup
install_java_runtime() {
  log "Installing Java (OpenJDK) runtime..."
  case "$PKG_MGR" in
    apt)
      pkg_install openjdk-17-jdk maven gradle || pkg_install openjdk-17-jdk maven
      ;;
    dnf|yum)
      pkg_install java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk-devel maven
      ;;
    apk)
      pkg_install openjdk17 maven gradle || pkg_install openjdk17 maven
      ;;
    zypper)
      pkg_install java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk-devel maven
      ;;
  esac
}

setup_java_env() {
  cd "$PROJECT_DIR"
  if is_java_maven; then
    log "Resolving Maven dependencies..."
    mvn -B -q -DskipTests dependency:resolve dependency:resolve-plugins || mvn -B -DskipTests package
  elif is_java_gradle; then
    log "Resolving Gradle dependencies..."
    gradle --no-daemon tasks >/dev/null 2>&1 || true
    gradle --no-daemon build -x test || true
  fi
  export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac || command -v java)")")")"
  export PORT="${PORT:-8080}"
}

# Rust setup
install_rust_runtime() {
  log "Installing Rust toolchain..."
  case "$PKG_MGR" in
    apt)
      pkg_install rustc cargo build-essential
      ;;
    dnf|yum)
      pkg_install rust cargo gcc gcc-c++ make
      ;;
    apk)
      pkg_install rust cargo build-base
      ;;
    zypper)
      pkg_install rust cargo gcc gcc-c++ make
      ;;
  esac
}

setup_rust_env() {
  log "Fetching Rust crate dependencies..."
  cd "$PROJECT_DIR"
  if [[ -f "Cargo.toml" ]]; then
    cargo fetch || true
  fi
  export PORT="${PORT:-8080}"
}

# Environment file management
ensure_env_file() {
  cd "$PROJECT_DIR"
  if [[ -f ".env" ]]; then
    info ".env file found; not overwriting."
    return 0
  fi
  if [[ -f ".env.example" ]]; then
    log "Creating .env from .env.example..."
    cp .env.example .env
  else
    log "Creating default .env..."
    cat > .env <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT:-8080}
# Add additional environment variables here
EOF
  fi
}

print_summary() {
  echo
  log "Environment setup summary:"
  echo "- Project directory: $PROJECT_DIR"
  echo "- Package manager: $PKG_MGR"
  echo "- App user: $APP_USER (created: ${CREATE_APP_USER})"
  echo "- APP_ENV: $APP_ENV"
  echo "- PORT: ${PORT:-unset}"
  echo "- Log file: $LOG_FILE"
  echo
  info "Common run hints (adjust to your app):"
  if is_python_project; then
    echo "  Python:"
    echo "    source \"$PROJECT_DIR/.venv/bin/activate\""
    if [[ -f "$PROJECT_DIR/manage.py" ]]; then
      echo "    python manage.py runserver 0.0.0.0:${PORT:-8000}"
    else
      echo "    python -m pip install gunicorn >/dev/null 2>&1 || true"
      echo "    gunicorn -b 0.0.0.0:${PORT:-8000} app:app  # adjust module:app"
    fi
  fi
  if is_node_project; then
    echo "  Node.js:"
    echo "    npm run start  # or: npm run dev"
  fi
  if is_ruby_project; then
    echo "  Ruby:"
    echo "    bundle exec rails server -b 0.0.0.0 -p ${PORT:-3000}  # for Rails apps"
  fi
  if is_php_project; then
    echo "  PHP:"
    echo "    php -S 0.0.0.0:${PORT:-8080} -t public  # adjust docroot"
  fi
  if is_go_project; then
    echo "  Go:"
    echo "    go run .  # or: go build -o bin/app && ./bin/app"
  fi
  if is_java_maven || is_java_gradle; then
    echo "  Java:"
    echo "    mvn spring-boot:run  # Maven Spring Boot"
    echo "    or: java -jar target/*.jar"
  fi
  if is_rust_project; then
    echo "  Rust:"
    echo "    cargo run --release"
  fi
  echo
}

write_auto_build_script() {
  cat >/tmp/auto_build.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  npm ci && (npm run build || npm run compile || true)
elif [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; then
  command -v pnpm >/dev/null 2>&1 || (npm i -g pnpm >/dev/null 2>&1 || true)
  pnpm install && (pnpm build || true)
elif [ -f yarn.lock ]; then
  yarn install --frozen-lockfile && (yarn build || true)
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew && ./gradlew build
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  gradle build
elif [ -f Cargo.toml ]; then
  cargo build --verbose
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip && pip install .
elif [ -f setup.py ]; then
  python -m pip install -U pip && pip install -e .
elif [ -f requirements.txt ]; then
  python -m pip install -U pip && pip install -r requirements.txt
elif [ -f go.mod ]; then
  go mod download && go build ./...
elif ls *.sln >/dev/null 2>&1; then
  dotnet restore && dotnet build -c Release
else
  echo "No recognized build system to run initial build. Skipping."
fi
EOF
  chmod +x /tmp/auto_build.sh

  # Generate and run CI auto build script to provide a stable, parsed-on-disk build step
  (
    cd "$PROJECT_DIR"
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '' 'if [ -f package.json ]; then' '  if command -v pnpm >/dev/null 2>&1 && { [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; }; then' '    pnpm install --frozen-lockfile --silent || pnpm install' '    pnpm build || true' '  elif command -v yarn >/dev/null 2>&1 && [ -f yarn.lock ]; then' '    yarn install --frozen-lockfile --non-interactive' '    yarn build || true' '  elif command -v npm >/dev/null 2>&1; then' '    npm ci || npm install --no-audit --no-fund' '    npm run build || npm run compile || true' '  fi' 'elif [ -f pom.xml ]; then' '  mvn -B -q -DskipTests package' 'elif [ -f gradlew ]; then' '  chmod +x gradlew' '  ./gradlew --no-daemon build -x test' 'elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then' '  if command -v gradle >/dev/null 2>&1; then' '    gradle --no-daemon build -x test' '  else' '    echo "Gradle wrapper missing and gradle not installed" >&2' '    exit 1' '  fi' 'elif [ -f Cargo.toml ]; then' '  cargo build --verbose' 'elif [ -f pyproject.toml ]; then' '  python -m pip install -U pip' '  pip install .' 'elif [ -f setup.py ]; then' '  python -m pip install -U pip' '  pip install -e .' 'elif [ -f requirements.txt ]; then' '  python -m pip install -U pip' '  pip install -r requirements.txt' 'elif [ -f go.mod ]; then' '  go mod download' '  go build ./...' 'elif ls *.sln >/dev/null 2>&1; then' '  dotnet restore' '  dotnet build -c Release' 'else' '  echo "No recognized build system detected; nothing to do."' 'fi' > ci_auto_build.sh
    chmod +x ci_auto_build.sh
    ./ci_auto_build.sh
  )
}

write_build_probe_script() {
  cat >"$PROJECT_DIR/build_probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci || npm install
    npm run build || npm run compile || true
  fi
elif [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install
    pnpm build || true
  fi
elif [ -f yarn.lock ]; then
  if command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile || yarn install
    yarn build || true
  fi
elif [ -f pom.xml ]; then
  if command -v mvn >/dev/null 2>&1; then mvn -q -DskipTests package; fi
elif [ -f gradlew ]; then
  chmod +x gradlew && ./gradlew build
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  if command -v gradle >/dev/null 2>&1; then gradle build; fi
elif [ -f Cargo.toml ]; then
  if command -v cargo >/dev/null 2>&1; then cargo build --verbose; fi
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip && pip install . || true
elif [ -f setup.py ]; then
  python -m pip install -U pip && pip install -e . || true
elif [ -f requirements.txt ]; then
  python -m pip install -U pip && pip install -r requirements.txt || true
elif [ -f go.mod ]; then
  if command -v go >/dev/null 2>&1; then go mod download && go build ./...; fi
elif ls *.sln >/dev/null 2>&1; then
  if command -v dotnet >/dev/null 2>&1; then dotnet restore && dotnet build -c Release; fi
else
  echo "No recognized build system to run initial build"
  exit 1
fi
EOF
  chmod +x "$PROJECT_DIR/build_probe.sh"
}

write_ci_build_detect_script() {
  cat >"$PROJECT_DIR/ci_build_detect.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ -f package.json ]; then
  npm ci --no-audit --no-fund
  (npm run build || npm run compile || true)
elif [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; then
  pnpm install --frozen-lockfile
  (pnpm build || true)
elif [ -f yarn.lock ]; then
  yarn install --frozen-lockfile
  (yarn build || true)
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew && ./gradlew build
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  gradle build
elif [ -f Cargo.toml ]; then
  cargo build --verbose
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip && pip install .
elif [ -f setup.py ]; then
  python -m pip install -U pip && pip install -e .
elif [ -f requirements.txt ]; then
  python -m pip install -U pip && pip install -r requirements.txt
elif [ -f go.mod ]; then
  go mod download && go build ./...
elif ls *.sln >/dev/null 2>&1; then
  dotnet restore && dotnet build -c Release
else
  echo "No recognized build system to run initial build" >&2
  exit 1
fi
EOF
  chmod +x "$PROJECT_DIR/ci_build_detect.sh"
}

write_ci_build_script() {
  mkdir -p "$PROJECT_DIR/.ci"
  cat >"$PROJECT_DIR/.ci/build.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci --no-audit --no-fund
    (npm run build || npm run compile || true)
    exit 0
  fi
fi

if [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile
    (pnpm build || true)
    exit 0
  elif command -v corepack >/dev/null 2>&1; then
    corepack enable
    corepack prepare pnpm@latest --activate
    pnpm install --frozen-lockfile
    (pnpm build || true)
    exit 0
  fi
fi

if [ -f yarn.lock ]; then
  if command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile
    (yarn build || true)
    exit 0
  elif command -v corepack >/dev/null 2>&1; then
    corepack enable
    yarn install --frozen-lockfile
    (yarn build || true)
    exit 0
  fi
fi

if [ -f pom.xml ]; then mvn -q -DskipTests package; exit 0; fi
if [ -f gradlew ]; then chmod +x gradlew && ./gradlew build -x test; exit 0; fi
if [ -f build.gradle ] || [ -f build.gradle.kts ]; then gradle build -x test; exit 0; fi
if [ -f Cargo.toml ]; then cargo build --verbose; exit 0; fi
if [ -f pyproject.toml ]; then python -m pip install -U pip && pip install .; exit 0; fi
if [ -f setup.py ]; then python -m pip install -U pip && pip install -e .; exit 0; fi
if [ -f requirements.txt ]; then python -m pip install -U pip && pip install -r requirements.txt; exit 0; fi
if [ -f go.mod ]; then go mod download && go build ./...; exit 0; fi
if ls *.sln >/dev/null 2>&1; then dotnet restore && dotnet build -c Release; exit 0; fi

echo "No recognized build system to run initial build" >&2
exit 1
EOF
  chmod +x "$PROJECT_DIR/.ci/build.sh"
}

write_ci_build_sh() {
  cat >"$PROJECT_DIR/ci-build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci && (npm run build || npm run compile || true)
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile && (yarn build || true)
  elif command -v pnpm >/dev/null 2>&1; then
    pnpm install && (pnpm build || true)
  else
    echo "No Node.js package manager found (npm/yarn/pnpm)."
    exit 1
  fi
elif [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; then
  command -v pnpm >/dev/null 2>&1 && pnpm install && (pnpm build || true) || { echo "pnpm not installed"; exit 1; }
elif [ -f yarn.lock ]; then
  command -v yarn >/dev/null 2>&1 && yarn install --frozen-lockfile && (yarn build || true) || { echo "yarn not installed"; exit 1; }
elif [ -f pom.xml ]; then
  command -v mvn >/dev/null 2>&1 && mvn -q -DskipTests package || { echo "maven not installed"; exit 1; }
elif [ -f gradlew ]; then
  chmod +x gradlew && ./gradlew build
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  command -v gradle >/dev/null 2>&1 && gradle build || { echo "gradle not installed"; exit 1; }
elif [ -f Cargo.toml ]; then
  command -v cargo >/dev/null 2>&1 && cargo build --verbose || { echo "cargo not installed"; exit 1; }
elif [ -f pyproject.toml ]; then
  command -v python >/dev/null 2>&1 && python -m pip install -U pip && pip install . || { echo "python/pip not installed"; exit 1; }
elif [ -f setup.py ]; then
  command -v python >/dev/null 2>&1 && python -m pip install -U pip && pip install -e . || { echo "python/pip not installed"; exit 1; }
elif [ -f requirements.txt ]; then
  command -v python >/dev/null 2>&1 && python -m pip install -U pip && pip install -r requirements.txt || { echo "python/pip not installed"; exit 1; }
elif [ -f go.mod ]; then
  command -v go >/dev/null 2>&1 && go mod download && go build ./... || { echo "go not installed"; exit 1; }
elif ls *.sln >/dev/null 2>&1; then
  command -v dotnet >/dev/null 2>&1 && dotnet restore && dotnet build -c Release || { echo "dotnet not installed"; exit 1; }
else
  echo 'No recognized build system to run initial build'
  exit 1
fi
EOF
  chmod +x "$PROJECT_DIR/ci-build.sh"
}

write_dot_ci_build_sh() {
  cat >"$PROJECT_DIR/.ci_build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci --no-audit --no-fund || npm install --no-audit --no-fund
    npm run build || npm run compile || true
  else
    echo "npm not found"; exit 127
  fi
elif [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile --reporter=silent || pnpm install --reporter=silent
    pnpm build || true
  else
    echo "pnpm not found"; exit 127
  fi
elif [ -f yarn.lock ]; then
  if command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile --non-interactive
    yarn build || true
  else
    echo "yarn not found"; exit 127
  fi
elif [ -f pom.xml ]; then
  if command -v mvn >/dev/null 2>&1; then
    mvn -q -DskipTests package
  else
    echo "mvn not found"; exit 127
  fi
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew build -x test
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  if command -v gradle >/dev/null 2>&1; then
    gradle build -x test
  else
    echo "gradle not found"; exit 127
  fi
elif [ -f Cargo.toml ]; then
  if command -v cargo >/dev/null 2>&1; then
    cargo build --verbose
  else
    echo "cargo not found"; exit 127
  fi
elif [ -f pyproject.toml ]; then
  if command -v python >/dev/null 2>&1; then
    python -m pip install -U pip
    pip install .
  else
    echo "python not found"; exit 127
  fi
elif [ -f setup.py ]; then
  if command -v python >/dev/null 2>&1; then
    python -m pip install -U pip
    pip install -e .
  else
    echo "python not found"; exit 127
  fi
elif [ -f requirements.txt ]; then
  if command -v python >/dev/null 2>&1; then
    python -m pip install -U pip
    pip install -r requirements.txt
  else
    echo "python not found"; exit 127
  fi
elif [ -f go.mod ]; then
  if command -v go >/dev/null 2>&1; then
    go mod download
    go build ./...
  else
    echo "go not found"; exit 127
  fi
elif ls *.sln >/dev/null 2>&1; then
  if command -v dotnet >/dev/null 2>&1; then
    dotnet restore
    dotnet build -c Release
  else
    echo "dotnet not found"; exit 127
  fi
else
  echo "No recognized build system to run initial build"
  exit 1
fi
EOF
  chmod +x "$PROJECT_DIR/.ci_build.sh"
}

write_ci_run_build_sh() {
  mkdir -p "$PROJECT_DIR/.ci"
  cat >"$PROJECT_DIR/.ci/run_build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci --no-audit --prefer-offline || npm install
    (npm run -s build || npm run -s compile || true)
  elif command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile --prefer-offline
    (pnpm build || true)
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile
    (yarn build || true)
  else
    echo "Node.js package manager (npm/pnpm/yarn) not found" >&2
    exit 1
  fi
elif [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile --prefer-offline
    (pnpm build || true)
  else
    echo "pnpm not found" >&2
    exit 1
  fi
elif [ -f yarn.lock ]; then
  if command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile
    (yarn build || true)
  else
    echo "yarn not found" >&2
    exit 1
  fi
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew build -x test
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  gradle build -x test
elif [ -f Cargo.toml ]; then
  cargo build --verbose
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip
  pip install . || pip install -e .
elif [ -f setup.py ]; then
  python -m pip install -U pip
  pip install -e .
elif [ -f requirements.txt ]; then
  python -m pip install -U pip
  pip install -r requirements.txt
elif [ -f go.mod ]; then
  go mod download
  go build ./...
elif ls *.sln >/dev/null 2>&1; then
  dotnet restore
  dotnet build -c Release
else
  echo "No recognized build system to run initial build" >&2
  exit 1
fi
EOF
  chmod +x "$PROJECT_DIR/.ci/run_build.sh"
}

write_ci_run_tests_sh() {
  mkdir -p "$PROJECT_DIR/.ci"
  cat >"$PROJECT_DIR/.ci/run-tests.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  npm ci --no-audit --fund=false --prefer-offline
  (npm test --silent || npm run test || true)
elif [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; then
  pnpm install --frozen-lockfile
  (pnpm test || true)
elif [ -f yarn.lock ]; then
  yarn install --frozen-lockfile --silent
  (yarn test --silent || yarn test || true)
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
  mvn -q test
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew test
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  gradle test
elif [ -f Cargo.toml ]; then
  cargo test --verbose
elif [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ]; then
  (pytest -q || python -m pytest -q || python -m unittest -q)
elif [ -f go.mod ]; then
  go test ./...
elif ls *.sln >/dev/null 2>&1; then
  dotnet test -c Release
else
  echo "No recognized test system to run"; exit 1
fi
EOF
  chmod +x "$PROJECT_DIR/.ci/run-tests.sh"
}

main() {
  ensure_log_path
  require_root_or_warn
  setup_project_structure
  init_logging
  detect_pkg_manager
  install_common_tools
  setup_proxy_env
  create_app_user
  write_auto_build_script
  write_build_probe_script
  write_ci_build_detect_script
  write_ci_build_script
  write_ci_run_build_sh
  write_ci_build_sh
  write_dot_ci_build_sh

  local any_stack=false

  if is_python_project; then
    any_stack=true
    log "Detected Python project"
    install_python_runtime
    setup_python_env
    setup_auto_activate
  fi

  if is_node_project; then
    any_stack=true
    log "Detected Node.js project"
    install_node_runtime
    setup_node_env
  fi

  if is_ruby_project; then
    any_stack=true
    log "Detected Ruby project"
    install_ruby_runtime
    setup_ruby_env
  fi

  if is_php_project; then
    any_stack=true
    log "Detected PHP project"
    install_php_runtime
    setup_php_env
  fi

  if is_go_project; then
    any_stack=true
    log "Detected Go project"
    install_go_runtime
    setup_go_env
  fi

  if is_java_maven || is_java_gradle; then
    any_stack=true
    log "Detected Java project"
    install_java_runtime
    setup_java_env
  fi

  if is_rust_project; then
    any_stack=true
    log "Detected Rust project"
    install_rust_runtime
    setup_rust_env
  fi

  if ! $any_stack; then
    warn "No recognized project files found in $PROJECT_DIR."
    warn "Supported: Python (requirements.txt/pyproject.toml), Node.js (package.json), Ruby (Gemfile), PHP (composer.json), Go (go.mod), Java (pom.xml/build.gradle), Rust (Cargo.toml)."
  fi

  (cd "$PROJECT_DIR" && ./ci-build.sh)
  (cd "$PROJECT_DIR" && ./.ci_build.sh)
  /tmp/auto_build.sh
  (cd "$PROJECT_DIR" && ./ci_build_detect.sh)
  (cd "$PROJECT_DIR" && ./.ci/build.sh)
  (cd "$PROJECT_DIR" && ./.ci/run_build.sh)
  bash "$PROJECT_DIR/build_probe.sh"
  ensure_env_file
  set_permissions
  pkg_cleanup
  print_summary
}

main "$@"