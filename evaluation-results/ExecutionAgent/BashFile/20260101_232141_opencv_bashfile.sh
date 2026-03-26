#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust)
# - Installs system packages and runtimes (supports apt, apk, dnf, yum, microdnf, zypper)
# - Sets up dependencies (venv, npm/yarn/pnpm, bundler, maven/gradle, composer, cargo, go)
# - Configures environment variables and PATH
# - Creates non-root user (optional) and sets permissions
# - Idempotent and safe to run multiple times

set -Eeuo pipefail

# Global defaults
export DEBIAN_FRONTEND=noninteractive
umask 022
IFS=$' \n\t'

# Colors (fallback if not TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()    { printf "%s[%s] %s%s\n" "$GREEN" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$NC"; }
warn()   { printf "%s[WARN] %s%s\n" "$YELLOW" "$*" "$NC" >&2; }
error()  { printf "%s[ERROR] %s%s\n" "$RED" "$*" "$NC" >&2; }
die()    { error "$*"; exit 1; }

cleanup() { :; }
trap cleanup EXIT
trap 'die "An unexpected error occurred on line $LINENO"' ERR

# Configuration via env vars (override as needed)
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
CREATE_APP_USER="${CREATE_APP_USER:-true}"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-0}"  # will be set based on project type if 0
EXTRA_SYS_PACKAGES="${EXTRA_SYS_PACKAGES:-}"  # space-separated additional system packages to install
HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
NO_PROXY="${NO_PROXY:-${no_proxy:-}}"

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

# Detect package manager and OS info
PKG_MGR=""
OS_ID=""
OS_LIKE=""

detect_os_pm() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  else
    warn "No known package manager detected. System package installation will be skipped."
  fi
}

# Package manager wrappers
apt_updated_stamp="/var/cache/apt-updated.stamp"
apt_update_if_needed() {
  if [ ! -f "$apt_updated_stamp" ] || find "$apt_updated_stamp" -mmin +60 >/dev/null 2>&1; then
    log "Updating apt package lists..."
    apt-get update
    mkdir -p "$(dirname "$apt_updated_stamp")"
    date > "$apt_updated_stamp"
  fi
}

pkg_is_installed() {
  case "$PKG_MGR" in
    apt-get) dpkg -s "$1" >/dev/null 2>&1 ;;
    apk) apk info -e "$1" >/dev/null 2>&1 ;;
    dnf|yum|microdnf) rpm -q "$1" >/dev/null 2>&1 ;;
    zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

install_packages() {
  [ -z "${1:-}" ] && return 0
  if [ -z "$PKG_MGR" ]; then
    warn "Cannot install system packages ($*): No package manager available."
    return 0
  fi
  if ! is_root; then
    warn "Skipping system package installation (need root): $*"
    return 0
  fi
  # Filter out already-installed packages
  local to_install=()
  for pkg in "$@"; do
    if ! pkg_is_installed "$pkg"; then
      to_install+=("$pkg")
    fi
  done
  [ "${#to_install[@]}" -eq 0 ] && return 0

  log "Installing system packages: ${to_install[*]}"
  case "$PKG_MGR" in
    apt-get)
      apt_update_if_needed
      apt-get install -y --no-install-recommends "${to_install[@]}"
      ;;
    apk)
      apk add --no-cache "${to_install[@]}"
      ;;
    dnf)
      dnf -y install "${to_install[@]}"
      ;;
    yum)
      yum -y install "${to_install[@]}"
      ;;
    microdnf)
      microdnf -y install "${to_install[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${to_install[@]}"
      ;;
    *)
      warn "Unsupported package manager: $PKG_MGR"
      ;;
  esac
}

# Base tools
install_base_tools() {
  local base_ca base_tools base_build
  case "$PKG_MGR" in
    apt-get)
      base_ca="ca-certificates"
      base_tools="curl wget git gnupg unzip xz-utils"
      base_build="build-essential pkg-config"
      ;;
    apk)
      base_ca="ca-certificates"
      base_tools="curl wget git gnupg unzip xz"
      base_build="build-base pkgconf"
      ;;
    dnf|yum|microdnf)
      base_ca="ca-certificates"
      base_tools="curl wget git gnupg2 unzip xz"
      base_build="gcc gcc-c++ make automake autoconf libtool pkgconfig"
      ;;
    zypper)
      base_ca="ca-certificates"
      base_tools="curl wget git gpg2 unzip xz"
      base_build="gcc gcc-c++ make automake autoconf libtool pkgconfig"
      ;;
    *)
      return 0
      ;;
  esac
  install_packages $base_ca $base_tools $base_build
  # update-ca-certificates if available
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi
}

# Create non-root app user
ensure_app_user() {
  if ! is_root || [ "${CREATE_APP_USER,,}" != "true" ]; then
    return 0
  fi
  if ! getent group "$APP_GID" >/dev/null 2>&1; then
    if getent group "$APP_GROUP" >/dev/null 2>&1; then
      groupmod -g "$APP_GID" "$APP_GROUP" || true
    else
      groupadd -g "$APP_GID" "$APP_GROUP" || true
    fi
  fi
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" || \
    useradd -m -u "$APP_UID" -g "$APP_GID" "$APP_USER" || true
  else
    usermod -u "$APP_UID" "$APP_USER" || true
    usermod -g "$APP_GID" "$APP_USER" || true
  fi
}

# Directory setup
setup_dirs() {
  mkdir -p "$PROJECT_ROOT" "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/data"
  if is_root && id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT"
  fi
}

# Environment file setup
persist_env() {
  local envfile="$PROJECT_ROOT/.container_env"
  touch "$envfile"
  # Update or append key in envfile
  set_kv() {
    local key="$1"; shift
    local val="$1"; shift
    if grep -qE "^${key}=" "$envfile"; then
      sed -i "s|^${key}=.*|${key}=${val}|g" "$envfile"
    else
      printf "%s=%s\n" "$key" "$val" >> "$envfile"
    fi
  }
  set_kv APP_ENV "$APP_ENV"
  set_kv PROJECT_ROOT "$PROJECT_ROOT"
  [ "${APP_PORT}" != "0" ] && set_kv APP_PORT "$APP_PORT" || true

  # Profile path injection for shells
  local profile_script="/etc/profile.d/project_env.sh"
  local path_additions=("$PROJECT_ROOT/.venv/bin" "$PROJECT_ROOT/.venv/Scripts" "$PROJECT_ROOT/node_modules/.bin" "$HOME/.local/bin" "/usr/local/bin" "/usr/local/go/bin" "$HOME/go/bin" "$HOME/.cargo/bin" "/usr/local/cargo/bin")
  local path_line=""
  for p in "${path_additions[@]}"; do
    [ -d "$p" ] && path_line="${path_line:+$path_line:}$p" || true
  done
  if [ -n "$path_line" ]; then
    if is_root; then
      mkdir -p "$(dirname "$profile_script")"
      cat > "$profile_script" <<EOF
# Generated by setup script
export PATH="$path_line:\$PATH"
[ -f "$envfile" ] && export \$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$envfile" | xargs)
EOF
    else
      local user_profile="$HOME/.profile"
      if ! grep -q "project_env" "$user_profile" 2>/dev/null; then
        {
          echo "# project_env"
          echo "export PATH=\"$path_line:\$PATH\""
          echo "[ -f \"$envfile\" ] && export \$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' \"$envfile\" | xargs)"
        } >> "$user_profile"
      fi
    fi
  fi
}

# Language/runtime install helpers per PM
install_python_runtime() {
  case "$PKG_MGR" in
    apt-get) install_packages python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev ;;
    apk)     install_packages python3 py3-pip python3-dev libffi-dev openssl-dev ;;
    dnf|yum|microdnf) install_packages python3 python3-pip python3-devel libffi-devel openssl-devel ;;
    zypper)  install_packages python3 python3-pip python3-devel libffi-devel libopenssl-devel || install_packages python3 python3-pip python3-devel ;;
    *) warn "Cannot install Python runtime (no package manager)";;
  esac
}

install_node_runtime() {
  # Prefer non-apt installation of Node.js (binary includes npm/npx). If node is present, skip.
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    return 0
  fi
  warn "Skipping apt-based Node.js/npm installation to avoid timeouts; Node.js should be installed via binary earlier in main()."
}

install_ruby_runtime() {
  case "$PKG_MGR" in
    apt-get) install_packages ruby-full ruby-dev make gcc ;;
    apk)     install_packages ruby ruby-bundler ruby-dev build-base ;;
    dnf|yum|microdnf) install_packages ruby ruby-devel ruby-libs rubygems gcc make ;;
    zypper)  install_packages ruby ruby-devel rubygems gcc make ;;
    *) warn "Cannot install Ruby runtime (no package manager)";;
  esac
}

install_go_runtime() {
  case "$PKG_MGR" in
    apt-get) install_packages golang ;;
    apk)     install_packages go ;;
    dnf|yum|microdnf) install_packages golang ;;
    zypper)  install_packages go ;;
    *) warn "Cannot install Go runtime (no package manager)";;
  esac
}

install_java_runtime() {
  case "$PKG_MGR" in
    apt-get) install_packages openjdk-17-jdk ;;
    apk)     install_packages openjdk17 ;;
    dnf|yum|microdnf) install_packages java-17-openjdk-devel ;;
    zypper)  install_packages java-17-openjdk-devel ;;
    *) warn "Cannot install Java runtime (no package manager)";;
  esac
}

install_maven() {
  case "$PKG_MGR" in
    apt-get|dnf|yum|microdnf|zypper) install_packages maven ;;
    apk) install_packages maven ;;
    *) warn "Cannot install Maven";;
  esac
}

install_gradle() {
  case "$PKG_MGR" in
    apt-get|dnf|yum|microdnf|zypper) install_packages gradle ;;
    apk) install_packages gradle ;;
    *) warn "Cannot install Gradle";;
  esac
}

install_php_runtime() {
  case "$PKG_MGR" in
    apt-get) install_packages php-cli php-zip php-mbstring php-xml php-curl unzip ;;
    apk)     install_packages php php-cli php-phar php-openssl php-zip php-mbstring php-xml curl ;;
    dnf|yum|microdnf) install_packages php-cli php-zip php-mbstring php-xml php-json unzip ;;
    zypper)  install_packages php8-cli php8-zip php8-mbstring php8-xml unzip || install_packages php-cli php-zip php-mbstring php-xml unzip ;;
    *) warn "Cannot install PHP runtime (no package manager)";;
  esac
  # Install Composer if missing
  if ! command -v composer >/dev/null 2>&1; then
    if command -v php >/dev/null 2>&1; then
      log "Installing Composer..."
      local tgt="/usr/local/bin/composer"
      if is_root; then
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
          && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
          && rm -f composer-setup.php
      else
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
          && php composer-setup.php --filename=composer \
          && rm -f composer-setup.php
        mv -f composer "$HOME/.local/bin/composer" 2>/dev/null || true
      fi
      command -v composer >/dev/null 2>&1 || warn "Composer installation failed"
    else
      warn "PHP not found; cannot install Composer"
    fi
  fi
}

install_rust_runtime() {
  if command -v cargo >/dev/null 2>&1; then return 0; fi
  if ! command -v curl >/dev/null 2>&1; then install_packages curl || true; fi
  log "Installing Rust toolchain via rustup..."
  if is_root; then
    export RUSTUP_HOME=/usr/local/rustup
    export CARGO_HOME=/usr/local/cargo
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    ln -sf /usr/local/cargo/bin/cargo /usr/local/bin/cargo || true
    ln -sf /usr/local/cargo/bin/rustc /usr/local/bin/rustc || true
  else
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  fi
}

# Project detection
is_python_project() { [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ]; }
is_node_project()   { [ -f "$PROJECT_ROOT/package.json" ]; }
is_ruby_project()   { [ -f "$PROJECT_ROOT/Gemfile" ]; }
is_go_project()     { [ -f "$PROJECT_ROOT/go.mod" ] || [ -d "$PROJECT_ROOT/cmd" ] || [ -f "$PROJECT_ROOT/main.go" ]; }
is_java_maven()     { [ -f "$PROJECT_ROOT/pom.xml" ]; }
is_java_gradle()    { [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/build.gradle.kts" ] || [ -f "$PROJECT_ROOT/gradlew" ]; }
is_php_project()    { [ -f "$PROJECT_ROOT/composer.json" ]; }
is_rust_project()   { [ -f "$PROJECT_ROOT/Cargo.toml" ]; }

# Python setup
setup_python() {
  install_python_runtime
  # Determine app port if unset
  if [ "$APP_PORT" = "0" ]; then APP_PORT="5000"; fi
  # Venv path
  local venv_dir="$PROJECT_ROOT/.venv"
  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Python virtual environment already exists at $venv_dir"
  fi
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel
  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    python3 -m pip install -r "$PROJECT_ROOT/requirements.txt"
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    # Try PEP 517 install
    if grep -qi "\[tool\.poetry\]" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      python3 -m pip install "poetry>=1.5"
      poetry config virtualenvs.create false
      poetry install --no-root --no-interaction --no-ansi
    else
      python3 -m pip install build
      python3 -m pip install .
    fi
  fi
  persist_env
  # Add venv PATH for current shell
  export PATH="$venv_dir/bin:$PATH"
}

# Node.js setup
setup_node() {
  install_node_runtime
  # For native modules: ensure build tools and python present
  install_packages make gcc g++ || true
  if ! command -v python3 >/dev/null 2>&1; then install_python_runtime || true; fi

  # Determine app port if unset
  if [ "$APP_PORT" = "0" ]; then APP_PORT="3000"; fi

  pushd "$PROJECT_ROOT" >/dev/null
  # Use package manager based on lockfiles
  if [ -f "pnpm-lock.yaml" ]; then
    if command -v corepack >/dev/null 2>&1; then corepack enable || true; fi
    if ! command -v pnpm >/dev/null 2>&1; then npm -g install pnpm || true; fi
    log "Installing Node dependencies with pnpm"
    pnpm install --frozen-lockfile || pnpm install
  elif [ -f "yarn.lock" ]; then
    if command -v corepack >/dev/null 2>&1; then corepack enable || true; fi
    if ! command -v yarn >/dev/null 2>&1; then npm -g install yarn || true; fi
    log "Installing Node dependencies with yarn"
    yarn install --prefer-offline --frozen-lockfile || yarn install
  else
    log "Installing Node dependencies with npm"
    if [ -f "package-lock.json" ]; then
      npm ci --no-audit --no-fund || npm install --no-audit --no-fund
    else
      npm install --no-audit --no-fund
    fi
  fi
  popd >/dev/null
  persist_env
  export PATH="$PROJECT_ROOT/node_modules/.bin:$PATH"
}

# Ruby setup
setup_ruby() {
  install_ruby_runtime
  # Determine app port if unset
  if [ "$APP_PORT" = "0" ]; then APP_PORT="3000"; fi

  if ! command -v bundle >/dev/null 2>&1 && command -v gem >/dev/null 2>&1; then
    gem install bundler --no-document || true
  fi
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "Gemfile" ]; then
    log "Installing Ruby gems with bundler"
    bundle config set --local path 'vendor/bundle' || true
    bundle install --jobs=4
  fi
  popd >/dev/null
  persist_env
}

# Go setup
setup_go() {
  install_go_runtime
  # Determine app port if unset
  if [ "$APP_PORT" = "0" ]; then APP_PORT="8080"; fi

  export GOPATH="${GOPATH:-$HOME/go}"
  mkdir -p "$GOPATH/bin"
  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    pushd "$PROJECT_ROOT" >/dev/null
    log "Downloading Go modules"
    go mod download
    popd >/dev/null
  fi
  persist_env
  export PATH="$GOPATH/bin:$PATH"
}

# Java setup
setup_java() {
  install_java_runtime
  if is_java_maven; then
    install_maven
    pushd "$PROJECT_ROOT" >/dev/null
    log "Resolving Maven dependencies"
    mvn -B -q -DskipTests dependency:resolve dependency:resolve-plugins || true
    popd >/dev/null
  fi
  if is_java_gradle; then
    install_gradle
    pushd "$PROJECT_ROOT" >/dev/null
    if [ -x "./gradlew" ]; then
      log "Resolving Gradle dependencies with wrapper"
      ./gradlew --no-daemon --quiet tasks || true
    else
      log "Resolving Gradle dependencies"
      gradle --no-daemon --quiet tasks || true
    fi
    popd >/dev/null
  fi
  # Determine app port if unset
  if [ "$APP_PORT" = "0" ]; then APP_PORT="8080"; fi
  persist_env
}

# PHP setup
setup_php() {
  install_php_runtime
  # Determine app port if unset
  if [ "$APP_PORT" = "0" ]; then APP_PORT="8000"; fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "composer.json" ] && command -v composer >/dev/null 2>&1; then
    log "Installing PHP dependencies with Composer"
    composer install --no-interaction --prefer-dist --no-progress || true
  fi
  popd >/dev/null
  persist_env
}

# Rust setup
setup_rust() {
  install_rust_runtime
  # Determine app port if unset
  if [ "$APP_PORT" = "0" ]; then APP_PORT="8080"; fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "Cargo.toml" ]; then
    log "Fetching Rust crate dependencies"
    if command -v cargo >/dev/null 2>&1; then
      cargo fetch || true
    fi
  fi
  popd >/dev/null
  persist_env
}

# Generate a simple start script with heuristics
generate_start_script() {
  local start_script="$PROJECT_ROOT/start_server.sh"
  cat > "$start_script" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_PORT="${APP_PORT:-0}"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
export PATH="$PROJECT_ROOT/.venv/bin:$PROJECT_ROOT/node_modules/.bin:$PATH"
[ -f "$PROJECT_ROOT/.container_env" ] && export $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$PROJECT_ROOT/.container_env" | xargs)

cd "$PROJECT_ROOT"

run_cmd() {
  echo "[start] $*"
  exec "$@"
}

# Determine port default if 0
set_default_port() {
  if [ "$APP_PORT" = "0" ]; then
    if [ -f "package.json" ]; then APP_PORT="3000"
    elif [ -f "manage.py" ]; then APP_PORT="8000"
    elif ls app.py main.py wsgi.py 1>/dev/null 2>&1; then APP_PORT="5000"
    elif [ -f "Gemfile" ]; then APP_PORT="3000"
    elif [ -f "composer.json" ]; then APP_PORT="8000"
    else APP_PORT="8080"
    fi
  fi
  export APP_PORT
}

set_default_port

# Node.js
if [ -f "package.json" ]; then
  # Prefer npm/yarn/pnpm start scripts
  if command -v pnpm >/dev/null 2>&1 && grep -q '"start"' package.json; then
    run_cmd pnpm run start
  elif command -v yarn >/dev/null 2>&1 && grep -q '"start"' package.json; then
    run_cmd yarn start
  elif command -v npm >/dev/null 2>&1 && grep -q '"start"' package.json; then
    run_cmd npm run start
  elif [ -f "index.js" ]; then
    run_cmd node index.js
  fi
fi

# Python: Django
if [ -f "manage.py" ]; then
  if command -v python >/dev/null 2>&1; then
    run_cmd python manage.py runserver 0.0.0.0:"$APP_PORT"
  else
    run_cmd python3 manage.py runserver 0.0.0.0:"$APP_PORT"
  fi
fi

# Python: Flask/FastAPI heuristics
if [ -f "wsgi.py" ]; then
  if command -v gunicorn >/dev/null 2>&1; then
    run_cmd gunicorn --bind 0.0.0.0:"$APP_PORT" wsgi:app
  fi
fi
if [ -f "app.py" ]; then
  if command -v gunicorn >/dev/null 2>&1; then
    run_cmd gunicorn --bind 0.0.0.0:"$APP_PORT" app:app
  else
    run_cmd python app.py
  fi
fi
if [ -f "main.py" ]; then
  if grep -q "FastAPI" main.py 2>/dev/null && command -v uvicorn >/dev/null 2>&1; then
    run_cmd uvicorn main:app --host 0.0.0.0 --port "$APP_PORT"
  else
    run_cmd python main.py
  fi
fi

# Ruby on Rails
if [ -f "Gemfile" ]; then
  if grep -qi 'rails' Gemfile && [ -f "bin/rails" ]; then
    run_cmd bin/rails server -b 0.0.0.0 -p "$APP_PORT"
  fi
  if command -v rackup >/dev/null 2>&1 && [ -f "config.ru" ]; then
    run_cmd rackup -o 0.0.0.0 -p "$APP_PORT"
  fi
fi

# PHP: Laravel/Symfony dev servers
if [ -f "artisan" ]; then
  run_cmd php artisan serve --host=0.0.0.0 --port="$APP_PORT"
fi
if [ -f "public/index.php" ]; then
  if command -v php >/dev/null 2>&1; then
    # Start built-in server
    run_cmd php -S 0.0.0.0:"$APP_PORT" -t public
  fi
fi

# Java: Spring Boot fat jar
if ls target/*.jar 1>/dev/null 2>&1; then
  JAR="$(ls target/*.jar | head -n1)"
  run_cmd java -jar "$JAR"
fi
# Gradle bootRun
if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
  if [ -x "./gradlew" ]; then
    run_cmd ./gradlew bootRun --no-daemon
  elif command -v gradle >/dev/null 2>&1; then
    run_cmd gradle bootRun --no-daemon
  fi
fi

# Go
if [ -f "main.go" ] || [ -d "cmd" ]; then
  if [ -f "./app" ]; then
    run_cmd ./app
  else
    run_cmd go run .
  fi
fi

echo "[start] No known start command found. Override by running your own command or editing start_server.sh."
sleep infinity
EOS
  chmod +x "$start_script"
  if is_root && id -u "$APP_USER" >/dev/null 2>&1; then
    chown "$APP_USER:$APP_GROUP" "$start_script"
  fi
}

# Apply proxies if provided
configure_proxies() {
  if [ -n "$HTTP_PROXY" ] || [ -n "$HTTPS_PROXY" ]; then
    log "Configuring proxy environment"
    export http_proxy="$HTTP_PROXY"
    export https_proxy="$HTTPS_PROXY"
    export no_proxy="$NO_PROXY"
    if is_root; then
      mkdir -p /etc/profile.d
      cat > /etc/profile.d/proxy.sh <<EOF
export http_proxy="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export NO_PROXY="${NO_PROXY}"
EOF
    fi
  fi
}

# Virtual environment auto-activation
setup_auto_activate() {
  local script='if [ -f "${PROJECT_ROOT:-$PWD}/.venv/bin/activate" ]; then . "${PROJECT_ROOT:-$PWD}/.venv/bin/activate"; fi'
  if is_root && [ -w /etc/profile.d ]; then
    echo "$script" > /etc/profile.d/venv_auto.sh
  else
    local bashrc_file="$HOME/.bashrc"
    if ! grep -qxF "$script" "$bashrc_file" 2>/dev/null; then
      echo "$script" >> "$bashrc_file"
    fi
  fi
}

# Main
main() {
  log "Starting environment setup in $PROJECT_ROOT"
  detect_os_pm
  # Repair dpkg/apt state early if using apt-get
  if [ "$PKG_MGR" = "apt-get" ]; then
    export DEBIAN_FRONTEND=noninteractive
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
    dpkg --configure -a
    apt-get -o Dpkg::Options::="--force-confnew" -f install -y
    printf 'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";\n' > /etc/apt/apt.conf.d/99no-recommends
    apt-get update
  fi
  configure_proxies
  ensure_app_user
  install_base_tools
  # Ensure build tools and Python headers for building wheels (e.g., paddle2onnx dependencies)
  if [ "$PKG_MGR" = "apt-get" ]; then apt_update_if_needed; fi
  install_packages cmake build-essential python3-dev || true
  # Install Node.js and npm for Node-based tests
  apt-get update && apt-get install -y nodejs npm wget unzip
# Configure apt to avoid recommends/suggests
printf 'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";\n' > /etc/apt/apt.conf.d/99no-recommends || true
# Ensure tools for Node.js binary installation
# Repair dpkg/apt state before proceeding
export DEBIAN_FRONTEND=noninteractive; rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; dpkg --configure -a
apt-get -o Dpkg::Options::="--force-confnew" -f install -y
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates xz-utils
# Install Node.js via official binaries (includes npm/npx)
NODE_VER=v18.19.1 NODE_DIR=/usr/local/lib/nodejs
mkdir -p "$NODE_DIR"
curl -fsSL "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz" -o /tmp/node.tar.xz
tar -xJf /tmp/node.tar.xz -C "$NODE_DIR"
ln -sf "$NODE_DIR/node-${NODE_VER}-linux-x64/bin/node" /usr/local/bin/node
ln -sf "$NODE_DIR/node-${NODE_VER}-linux-x64/bin/npm" /usr/local/bin/npm
ln -sf "$NODE_DIR/node-${NODE_VER}-linux-x64/bin/npx" /usr/local/bin/npx
rm -f /tmp/node.tar.xz
node -v || true
npm -v || true
# Clean apt caches to reduce image size
apt-get clean && rm -rf /var/lib/apt/lists/*
  # Create 'node' symlink if only 'nodejs' exists
  if ! command -v node >/dev/null 2>&1 && [ -x /usr/bin/nodejs ]; then
    ln -sf /usr/bin/nodejs /usr/bin/node
  fi
  # Upgrade pip tooling, install PaddlePaddle CPU, and ensure paddle2onnx is present
  python -m pip install --upgrade pip setuptools wheel || true
  python -m pip install --no-cache-dir --upgrade paddlepaddle || true
  python -m pip install --no-cache-dir --upgrade opencv-python-headless || true
  python -m pip show paddle2onnx >/dev/null 2>&1 || python -m pip install --no-cache-dir paddle2onnx || true
  setup_dirs
  setup_auto_activate

  # Fetch OpenCV sample object_detection.py if missing and download Paddle model assets
  pushd "$PROJECT_ROOT" >/dev/null
  test -f object_detection.py || wget -q https://raw.githubusercontent.com/opencv/opencv/4.x/samples/dnn/object_detection.py -O object_detection.py
  wget -q -O humanseg_hrnet18_small_v1.zip https://x2paddle.bj.bcebos.com/inference/models/humanseg_hrnet18_small_v1.zip && unzip -o -q humanseg_hrnet18_small_v1.zip
  test -f humanseg_hrnet18_small_v1/model.pdmodel && test -f humanseg_hrnet18_small_v1/model.pdiparams
  popd >/dev/null

  # Extra system packages if provided
  if [ -n "$EXTRA_SYS_PACKAGES" ]; then
    log "Installing extra system packages: $EXTRA_SYS_PACKAGES"
    # shellcheck disable=SC2086
    install_packages $EXTRA_SYS_PACKAGES || true
  fi

  # Detect and setup project types (can be multi-language repo; process in order)
  local detected=0

  if is_python_project; then
    log "Python project detected"
    setup_python
    detected=$((detected+1))
  fi

  if is_node_project; then
    log "Node.js project detected"
    setup_node
    detected=$((detected+1))
  fi

  if is_ruby_project; then
    log "Ruby project detected"
    setup_ruby
    detected=$((detected+1))
  fi

  if is_go_project; then
    log "Go project detected"
    setup_go
    detected=$((detected+1))
  fi

  if is_java_maven || is_java_gradle; then
    log "Java project detected"
    setup_java
    detected=$((detected+1))
  fi

  if is_php_project; then
    log "PHP project detected"
    setup_php
    detected=$((detected+1))
  fi

  if is_rust_project; then
    log "Rust project detected"
    setup_rust
    detected=$((detected+1))
  fi

  if [ "$detected" -eq 0 ]; then
    warn "No recognized project type detected in $PROJECT_ROOT."
    warn "Place your project files (e.g., package.json, requirements.txt, pom.xml) in $PROJECT_ROOT and re-run."
    # Assign a sensible default port
    if [ "$APP_PORT" = "0" ]; then APP_PORT="8080"; fi
    persist_env
  fi

  # Ensure APP_PORT is persisted
  if [ "$APP_PORT" = "0" ]; then APP_PORT="8080"; fi
  persist_env

  # Generate start script
  generate_start_script

  # Set ownership
  if is_root && id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT"
  fi

  log "Environment setup completed successfully."
  log "Project root: $PROJECT_ROOT"
  log "App environment: APP_ENV=$APP_ENV, APP_PORT=$APP_PORT"
  log "To start the app, run: $PROJECT_ROOT/start_server.sh"
}

main "$@"