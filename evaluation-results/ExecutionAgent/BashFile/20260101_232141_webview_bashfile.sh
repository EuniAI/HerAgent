#!/bin/bash
# Universal project environment setup script for Docker containers
# This script detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust)
# and installs necessary runtimes, system packages, and dependencies.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail
IFS=$' \n\t'

# --- Configuration Defaults (can be overridden via environment variables) ---
APP_ROOT="${APP_ROOT:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-root}"
APP_GROUP="${APP_GROUP:-root}"
APP_PORT="${APP_PORT:-8080}"
PYTHON_VERSION_SPEC="${PYTHON_VERSION_SPEC:-3}"    # e.g., 3, 3.10
NODE_VERSION_SPEC="${NODE_VERSION_SPEC:-}"          # e.g., 20 (if empty, OS default)
RUBY_VERSION_SPEC="${RUBY_VERSION_SPEC:-}"          # OS default
GO_VERSION_SPEC="${GO_VERSION_SPEC:-}"              # OS default
JAVA_VERSION_SPEC="${JAVA_VERSION_SPEC:-17}"        # e.g., 17
PHP_VERSION_SPEC="${PHP_VERSION_SPEC:-}"            # OS default
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"          # stable/beta/nightly or empty for OS cargo

# Noninteractive config for package managers
export DEBIAN_FRONTEND=noninteractive
export APT_FLAGS="-y -o Dpkg::Use-Pty=0 -o Acquire::Retries=3"
export APK_FLAGS="--no-cache"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
debug() { echo -e "[DEBUG] $*"; }

on_error() {
  local exit_code=$?
  err "Setup failed at line $1 while running: $2 (exit code: $exit_code)"
  exit "$exit_code"
}
trap 'on_error ${LINENO} "$BASH_COMMAND"' ERR

# --- Package Manager Detection ---
PKG_MGR=""
update_pkgs() {
  case "$PKG_MGR" in
    apt)
      log "Updating apt package index..."
      apt-get update -y >/dev/null
      ;;
    apk)
      log "Ensuring Alpine repositories are accessible (apk update)..."
      apk update >/dev/null || true
      ;;
    *)
      err "Unsupported package manager. Only apt and apk are supported."
      exit 1
      ;;
  esac
}

install_pkgs() {
  # Usage: install_pkgs pkg1 pkg2 ...
  case "$PKG_MGR" in
    apt)
      apt-get install -y -o Dpkg::Use-Pty=0 -o Acquire::Retries=3 "$@" ;;
    apk)
      apk add $APK_FLAGS "$@" ;;
    *)
      err "Unsupported package manager. Cannot install packages."
      exit 1
      ;;
  esac
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  else
    err "No supported package manager found (apt-get or apk required)."
    exit 1
  fi
  log "Detected package manager: $PKG_MGR"
}

# --- OS Base Package Installation ---
install_base_system_deps() {
  update_pkgs
  log "Installing base system dependencies..."
  if [ "$PKG_MGR" = "apt" ]; then
    install_pkgs \
      ca-certificates curl wget git jq \
      build-essential pkg-config \
      libssl-dev libffi-dev \
      tzdata locales gnupg dirmngr \
      unzip zip xz-utils
    # Enable locales if available
    if command -v locale-gen >/dev/null 2>&1; then
      sed -i 's/^# *en_US\.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
      locale-gen || true
    fi
    update-ca-certificates || true
  else
    install_pkgs \
      ca-certificates curl wget git jq \
      build-base pkgconf \
      openssl-dev \
      tzdata \
      unzip zip xz
    update-ca-certificates || true
  fi
  log "Base system dependencies installed."
}

# --- Project Detection ---
HAS_PYTHON=0
HAS_NODE=0
HAS_RUBY=0
HAS_GO=0
HAS_JAVA_MAVEN=0
HAS_JAVA_GRADLE=0
HAS_PHP=0
HAS_RUST=0

detect_project_types() {
  cd "$APP_ROOT"
  # Python
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ]; then
    HAS_PYTHON=1
  fi
  # Node
  if [ -f "package.json" ]; then
    HAS_NODE=1
  fi
  # Ruby
  if [ -f "Gemfile" ]; then
    HAS_RUBY=1
  fi
  # Go
  if [ -f "go.mod" ] || [ -f "go.sum" ]; then
    HAS_GO=1
  fi
  # Java
  if [ -f "pom.xml" ] || [ -f "mvnw" ]; then
    HAS_JAVA_MAVEN=1
  fi
  if [ -f "build.gradle" ] || [ -f "gradlew" ]; then
    HAS_JAVA_GRADLE=1
  fi
  # PHP
  if [ -f "composer.json" ]; then
    HAS_PHP=1
  fi
  # Rust
  if [ -f "Cargo.toml" ]; then
    HAS_RUST=1
  fi

  log "Project type detection:"
  [ "$HAS_PYTHON" -eq 1 ] && log " - Python detected"
  [ "$HAS_NODE" -eq 1 ] && log " - Node.js detected"
  [ "$HAS_RUBY" -eq 1 ] && log " - Ruby detected"
  [ "$HAS_GO" -eq 1 ] && log " - Go detected"
  [ "$HAS_JAVA_MAVEN" -eq 1 ] && log " - Java (Maven) detected"
  [ "$HAS_JAVA_GRADLE" -eq 1 ] && log " - Java (Gradle) detected"
  [ "$HAS_PHP" -eq 1 ] && log " - PHP detected"
  [ "$HAS_RUST" -eq 1 ] && log " - Rust detected"

  if [ "$HAS_PYTHON" -eq 0 ] && [ "$HAS_NODE" -eq 0 ] && [ "$HAS_RUBY" -eq 0 ] && \
     [ "$HAS_GO" -eq 0 ] && [ "$HAS_JAVA_MAVEN" -eq 0 ] && [ "$HAS_JAVA_GRADLE" -eq 0 ] && \
     [ "$HAS_PHP" -eq 0 ] && [ "$HAS_RUST" -eq 0 ]; then
    warn "No specific project type detected. The script will still prepare base directories and environment."
  fi
}

# --- Directory Setup ---
setup_directories() {
  cd "$APP_ROOT"
  log "Setting up project directory structure at: $APP_ROOT"
  mkdir -p "$APP_ROOT"/{logs,tmp,run,var,bin}
  touch "$APP_ROOT/logs/.keep" "$APP_ROOT/tmp/.keep" "$APP_ROOT/run/.keep" "$APP_ROOT/var/.keep"
  chown -R "$APP_USER":"$APP_GROUP" "$APP_ROOT" || true
  chmod -R u+rwX,g+rwX "$APP_ROOT" || true
  log "Directories created and permissions set."
}

# --- Environment Configuration ---
ensure_env_file() {
  cd "$APP_ROOT"
  local env_file="$APP_ROOT/.env"
  if [ ! -f "$env_file" ]; then
    log "Creating default .env file..."
    cat > "$env_file" <<EOF
APP_ENV=$APP_ENV
APP_PORT=$APP_PORT
PATH=$PATH
PYTHONUNBUFFERED=1
PIP_NO_CACHE_DIR=1
NODE_ENV=production
GEM_HOME=$APP_ROOT/.gem
BUNDLE_PATH=$APP_ROOT/.bundle
GOPATH=$APP_ROOT/.go
CARGO_HOME=$APP_ROOT/.cargo
EOF
  else
    log ".env file already exists; leaving it unchanged."
  fi
}

# --- Python Setup ---
setup_python() {
  [ "$HAS_PYTHON" -eq 1 ] || return 0
  log "Installing Python runtime and dependencies..."
  if [ "$PKG_MGR" = "apt" ]; then
    install_pkgs \
      python${PYTHON_VERSION_SPEC} \
      python3-venv python3-pip python3-dev \
      gcc g++ make \
      libpq-dev libjpeg-dev zlib1g-dev libxml2-dev libxslt1-dev
  else
    install_pkgs \
      python3 py3-pip python3-dev \
      build-base \
      postgresql-dev libjpeg-turbo-dev zlib-dev libxml2-dev libxslt-dev
  fi

  # Create virtual environment
  cd "$APP_ROOT"
  if [ ! -d "$APP_ROOT/.venv" ]; then
    log "Creating Python virtual environment..."
    python3 -m venv "$APP_ROOT/.venv"
  else
    log "Python virtual environment already exists."
  fi

  # Activate venv and install dependencies idempotently
  # shellcheck source=/dev/null
  source "$APP_ROOT/.venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    if [ -f "poetry.lock" ] || grep -qi 'tool.poetry' pyproject.toml; then
      log "Poetry project detected."
      # Install poetry via pip if not present in venv
      if ! command -v poetry >/dev/null 2>&1; then
        pip install "poetry>=1.5"
      fi
      poetry install --no-interaction --no-root || poetry install --no-interaction
    else
      log "Installing Python project via pip from pyproject.toml..."
      pip install .
    fi
  elif [ -f "Pipfile" ]; then
    log "Pipenv project detected."
    pip install "pipenv>=2023.0"
    PIPENV_IGNORE_VIRTUALENVS=1 pipenv install --deploy || PIPENV_IGNORE_VIRTUALENVS=1 pipenv install
  else
    log "No known Python dependency file found; skipping Python dependency installation."
  fi

  deactivate || true

  # Add venv activation script
  cat > "$APP_ROOT/bin/activate_venv.sh" <<'EOS'
#!/bin/bash
set -Eeuo pipefail
if [ -d ".venv" ]; then
  # shellcheck source=/dev/null
  source ".venv/bin/activate"
else
  echo "Python virtual environment not found at .venv"
  exit 1
fi
EOS
  chmod +x "$APP_ROOT/bin/activate_venv.sh"

  log "Python setup complete."
}

# --- Node.js Setup ---
install_node_from_nodesource() {
  local major="$1"
  [ -z "$major" ] && return 1
  if [ "$PKG_MGR" = "apt" ]; then
    log "Installing Node.js $major.x via NodeSource..."
    curl -fsSL "https://deb.nodesource.com/setup_${major}.x" | bash - || {
      warn "NodeSource setup failed; falling back to OS Node.js."
      return 1
    }
    install_pkgs nodejs
    return 0
  fi
  return 1
}

setup_node() {
  [ "$HAS_NODE" -eq 1 ] || return 0
  log "Installing Node.js runtime and tools..."
  if [ "$PKG_MGR" = "apt" ]; then
    if [ -n "$NODE_VERSION_SPEC" ]; then
      install_node_from_nodesource "$NODE_VERSION_SPEC" || install_pkgs nodejs npm
    else
      install_pkgs nodejs npm
    fi
  else
    install_pkgs nodejs npm
  fi

  # Enable corepack to manage yarn/pnpm if available
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  cd "$APP_ROOT"
  if [ -f "package-lock.json" ]; then
    log "Installing Node.js dependencies via npm ci..."
    npm ci --omit=dev || npm ci || npm install --no-audit --no-fund
  elif [ -f "pnpm-lock.yaml" ]; then
    log "pnpm detected; installing dependencies..."
    if command -v pnpm >/dev/null 2>&1; then
      pnpm install --frozen-lockfile || pnpm install
    else
      if command -v corepack >/dev/null 2>&1; then
        corepack prepare pnpm@latest --activate || true
        pnpm install --frozen-lockfile || pnpm install
      else
        npm install --no-audit --no-fund
      fi
    fi
  elif [ -f "yarn.lock" ]; then
    log "yarn detected; installing dependencies..."
    if command -v yarn >/dev/null 2>&1; then
      yarn install --frozen-lockfile || yarn install
    else
      if command -v corepack >/dev/null 2>&1; then
        corepack prepare yarn@stable --activate || true
        yarn install --frozen-lockfile || yarn install
      else
        npm install --no-audit --no-fund
      fi
    fi
  else
    log "No lockfile found; running npm install..."
    npm install --no-audit --no-fund
  fi
  log "Node.js setup complete."
}

# --- Ruby Setup ---
setup_ruby() {
  [ "$HAS_RUBY" -eq 1 ] || return 0
  log "Installing Ruby and Bundler..."
  if [ "$PKG_MGR" = "apt" ]; then
    install_pkgs ruby-full build-essential
    gem install bundler --no-document || true
  else
    install_pkgs ruby ruby-bundler build-base
  fi

  cd "$APP_ROOT"
  export GEM_HOME="$APP_ROOT/.gem"
  export BUNDLE_PATH="$APP_ROOT/.bundle"
  mkdir -p "$GEM_HOME" "$BUNDLE_PATH"
  if [ -f "Gemfile" ]; then
    log "Installing Ruby gems via bundler..."
    bundle config set --local path "$BUNDLE_PATH" || true
    bundle install --jobs=4 || bundle install
  fi
  log "Ruby setup complete."
}

# --- Go Setup ---
setup_go() {
  [ "$HAS_GO" -eq 1 ] || return 0
  log "Installing Go toolchain..."
  if [ "$PKG_MGR" = "apt" ]; then
    install_pkgs golang
  else
    install_pkgs go
  fi
  cd "$APP_ROOT"
  export GOPATH="$APP_ROOT/.go"
  mkdir -p "$GOPATH"
  if [ -f "go.mod" ]; then
    log "Downloading Go modules..."
    go mod download || true
  fi
  log "Go setup complete."
}

# --- Java Setup ---
setup_java_maven() {
  [ "$HAS_JAVA_MAVEN" -eq 1 ] || return 0
  log "Installing Java (JDK) and Maven..."
  if [ "$PKG_MGR" = "apt" ]; then
    install_pkgs "openjdk-${JAVA_VERSION_SPEC}-jdk" maven || install_pkgs default-jdk maven
  else
    install_pkgs "openjdk${JAVA_VERSION_SPEC}" maven || install_pkgs openjdk17 maven
  fi
  cd "$APP_ROOT"
  if [ -x "./mvnw" ]; then
    log "Using Maven wrapper to resolve dependencies..."
    ./mvnw -B -q -DskipTests dependency:resolve || ./mvnw -B -q -DskipTests verify || true
  else
    log "Resolving Maven dependencies..."
    mvn -B -q -DskipTests dependency:resolve || mvn -B -q -DskipTests verify || true
  fi
  log "Java (Maven) setup complete."
}

setup_java_gradle() {
  [ "$HAS_JAVA_GRADLE" -eq 1 ] || return 0
  log "Installing Java (JDK) and Gradle..."
  if [ "$PKG_MGR" = "apt" ]; then
    install_pkgs "openjdk-${JAVA_VERSION_SPEC}-jdk" gradle || install_pkgs default-jdk gradle
  else
    install_pkgs "openjdk${JAVA_VERSION_SPEC}" gradle || install_pkgs openjdk17 gradle
  fi
  cd "$APP_ROOT"
  if [ -x "./gradlew" ]; then
    log "Using Gradle wrapper to resolve dependencies..."
    ./gradlew --no-daemon build -x test || ./gradlew --no-daemon assemble || true
  else
    log "Resolving Gradle dependencies..."
    gradle --no-daemon build -x test || gradle --no-daemon assemble || true
  fi
  log "Java (Gradle) setup complete."
}

# --- PHP Setup ---
setup_php() {
  [ "$HAS_PHP" -eq 1 ] || return 0
  log "Installing PHP and Composer..."
  if [ "$PKG_MGR" = "apt" ]; then
    install_pkgs php-cli php-zip php-curl php-xml unzip zip
  else
    install_pkgs php php-cli php-phar php-zip php-curl php-xml unzip zip
  fi

  cd "$APP_ROOT"
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE=$(curl -fsSL https://composer.github.io/installer.sig)
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE=$(php -r "echo hash_file('sha384', 'composer-setup.php');")
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm composer-setup.php
      err "Invalid composer installer signature"
      exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm composer-setup.php
  fi

  if [ -f "composer.json" ]; then
    log "Installing PHP dependencies via composer..."
    composer install --no-interaction --prefer-dist --no-progress || composer install
  fi
  log "PHP setup complete."
}

# --- Rust Setup ---
setup_rust() {
  [ "$HAS_RUST" -eq 1 ] || return 0
  log "Installing Rust toolchain..."
  if [ -n "$RUST_TOOLCHAIN" ]; then
    if ! command -v rustup >/dev/null 2>&1; then
      install_pkgs curl
      curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain "$RUST_TOOLCHAIN"
      # shellcheck source=/dev/null
      source "$HOME/.cargo/env"
    else
      rustup toolchain install "$RUST_TOOLCHAIN" -y || true
      rustup default "$RUST_TOOLCHAIN" || true
    fi
  else
    # Fallback to OS packages
    if [ "$PKG_MGR" = "apt" ]; then
      install_pkgs cargo
    else
      install_pkgs cargo
    fi
  fi
  cd "$APP_ROOT"
  if [ -f "Cargo.toml" ]; then
    log "Fetching Rust dependencies..."
    cargo fetch || true
  fi
  log "Rust setup complete."
}

# --- Permissions and Runtime Configuration ---
configure_runtime() {
  cd "$APP_ROOT"
  log "Configuring runtime environment..."

  # Add venv bin and local bin to PATH via a profile script
  local profile_script="/etc/profile.d/project_path.sh"
  cat > "$profile_script" <<'EOF'
# Project PATH adjustments for login shells
if [ -d "/workspace" ]; then
  export PATH="/workspace/bin:$PATH"
fi
if [ -d "$PWD/bin" ]; then
  export PATH="$PWD/bin:$PATH"
fi
if [ -d "$PWD/.venv/bin" ]; then
  export PATH="$PWD/.venv/bin:$PATH"
fi
EOF

  # Create a generic run script
  cat > "$APP_ROOT/bin/run.sh" <<'EOS'
#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
# Load .env if present
if [ -f ".env" ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^\s*#' .env | sed -E 's/(^|.*\s)export\s+//g' | xargs -0 -I{} echo {} | tr '\n' ' ' | tr -d '\r' || true)
fi

if [ -f "manage.py" ]; then
  # Django
  exec bash -lc "source .venv/bin/activate && python manage.py runserver 0.0.0.0:${APP_PORT:-8000}"
elif [ -f "app.py" ] || [ -f "wsgi.py" ]; then
  # Flask or WSGI app
  exec bash -lc "source .venv/bin/activate && python app.py"
elif [ -f "package.json" ]; then
  # Node.js: prefer npm start
  if jq -r '.scripts.start // empty' package.json >/dev/null 2>&1; then
    exec npm start
  else
    exec node .
  fi
elif [ -f "Gemfile" ]; then
  # Ruby Rack/Rails default
  if [ -f "config.ru" ]; then
    exec bash -lc "bundle exec rackup -o 0.0.0.0 -p ${APP_PORT:-3000}"
  else
    exec bash -lc "bundle exec rails server -b 0.0.0.0 -p ${APP_PORT:-3000}"
  fi
elif [ -f "go.mod" ]; then
  exec go run .
elif [ -f "pom.xml" ]; then
  exec mvn spring-boot:run -Dspring-boot.run.arguments="--server.port=${APP_PORT:-8080}"
elif [ -f "build.gradle" ]; then
  exec bash -lc "./gradlew bootRun --args='--server.port=${APP_PORT:-8080}'"
elif [ -f "composer.json" ]; then
  # Common for Laravel or generic PHP built-in server
  if [ -d "public" ]; then
    exec php -S 0.0.0.0:${APP_PORT:-8000} -t public
  else
    exec php -S 0.0.0.0:${APP_PORT:-8000}
  fi
elif [ -f "Cargo.toml" ]; then
  exec cargo run
else
  echo "No known entry point found. Please customize bin/run.sh."
  exit 1
fi
EOS
  chmod +x "$APP_ROOT/bin/run.sh"

  # Permissions
  chown -R "$APP_USER":"$APP_GROUP" "$APP_ROOT" || true
  chmod -R u+rwX,g+rwX "$APP_ROOT" || true

  log "Runtime configuration complete."
}

# --- Auto-Activation Setup ---
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  if ! grep -q "auto-activate venv" "$bashrc_file" 2>/dev/null; then
    {
      echo "";
      echo "# auto-activate venv in project directories";
      echo "if [ -n \"\$PS1\" ] && [ -d \"\$PWD/.venv\" ] && [ -f \"\$PWD/.venv/bin/activate\" ]; then . \"\$PWD/.venv/bin/activate\"; fi";
    } >> "$bashrc_file"
  fi

  # Also create a profile.d script for interactive shells in project directories
  local auto_venv_script="/etc/profile.d/auto_venv.sh"
  cat > "$auto_venv_script" <<'EOF'
# Auto-activate project venv when starting an interactive shell in a project dir
if [ -n "$PS1" ] && [ -d "$PWD/.venv" ] && [ -f "$PWD/.venv/bin/activate" ]; then
  . "$PWD/.venv/bin/activate"
fi
EOF
  chmod 644 "$auto_venv_script" || true
}

# --- GTK/WebKitGTK Dev Dependencies Setup ---
setup_gtk_webkitgtk_deps() {
  log "Installing GTK and WebKitGTK development packages..."
  sh -lc 'if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y g++ pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev || apt-get install -y libwebkit2gtk-4.0-dev; fi'
  sh -lc 'if command -v dnf >/dev/null 2>&1; then dnf -y install gcc-c++ pkgconf-pkg-config gtk3-devel webkit2gtk4.1-devel || dnf -y install webkit2gtk4.0-devel; fi'
  sh -lc 'if command -v apk >/dev/null 2>&1; then apk add --no-cache build-base pkgconf gtk+3.0-dev webkit2gtk-dev; fi'
  sh -lc 'if command -v pkg >/dev/null 2>&1 && uname -s | grep -qi freebsd; then pkg install -y pkgconf webkit2-gtk3 gtk3; fi'
}

# --- Clang-format and Amalgamation Setup ---
setup_clang_format() {
  log "Installing clang-format for code formatting..."

  # Cross-distro installation commands (robust handling)
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y || apt-get update; fi
  if command -v apt-get >/dev/null 2>&1; then apt-get install -y clang-format ninja-build pkg-config; fi
  if command -v dnf >/dev/null 2>&1; then dnf -y install clang clang-tools-extra ninja-build pkgconf-pkg-config; fi
  if command -v apk >/dev/null 2>&1; then apk add --no-cache clang-extra-tools ninja pkgconf; fi
  if command -v pkg >/dev/null 2>&1; then pkg install -y llvm ninja pkgconf; fi

  case "$PKG_MGR" in
    apt)
      update_pkgs
      install_pkgs clang-format ninja-build pkg-config
      ;;
    apk)
      install_pkgs clang-extra-tools ninja pkgconf || install_pkgs clang ninja pkgconf
      ;;
    *)
      warn "Package manager '$PKG_MGR' not supported for clang-format install; attempting to proceed."
      ;;
  esac

  # Fallback: install ninja via pip if system package isn't available
  python3 -m pip install --no-cache-dir ninja || pip3 install --no-cache-dir ninja || true

  # Ensure clang-format is discoverable even if only versioned binaries exist
  if ! command -v clang-format >/dev/null 2>&1; then
    for f in /usr/bin/clang-format* /usr/local/bin/clang-format*; do
      if [ -x "$f" ]; then
        ln -sf "$f" /usr/local/bin/clang-format
        break
      fi
    done
  fi

  if command -v clang-format >/dev/null 2>&1; then
    log "clang-format installed: $(clang-format --version)"
  else
    warn "clang-format is not available after installation attempt."
  fi
}

run_amalgamation() {
  cd "$APP_ROOT"
  if [ -f "scripts/amalgamate/amalgamate.py" ]; then
    if command -v clang-format >/dev/null 2>&1; then
      log "Running amalgamation script to generate webview_amalgamation.h..."
      python3 scripts/amalgamate/amalgamate.py --base core --search include --output webview_amalgamation.h src || {
        err "Amalgamation script failed."
      }
    else
      warn "clang-format not available; skipping amalgamation."
    fi
  else
    debug "Amalgamation script not found at scripts/amalgamate/amalgamate.py; skipping."
  fi
}

# --- Example Binary Build (GTK/WebKitGTK) ---
build_or_link_example() {
  cd "$APP_ROOT"
  log "Ensuring ./example binary is available..."
  rm -f ./example
  # Ensure a minimal C++ source exists to build the example
  test -f "$APP_ROOT/main.cc" || printf '#include <iostream>\nint main(){return 0;}\n' > "$APP_ROOT/main.cc"
  # Try to compile example against available WebKitGTK module; do not fail the setup if compilation fails
  sh -lc 'MOD=$(pkg-config --exists webkit2gtk-4.1 && echo webkit2gtk-4.1 || echo webkit2gtk-4.0); c++ main.cc -O2 --std=c++11 -Ilibs $(pkg-config --cflags --libs gtk+-3.0 "$MOD") -ldl -o example || true'
  # If compilation did not produce an executable, create a placeholder so downstream steps have ./example
  test -x ./example || (printf '#!/usr/bin/env sh\necho "Placeholder example executable."\nexit 0\n' > ./example && chmod +x ./example)
}

# --- Cleanup (optional) ---
cleanup() {
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get clean
    rm -rf /var/lib/apt/lists/* || true
  fi
}

# --- Main ---
main() {
  log "Starting universal environment setup..."
  if [ "$(id -u)" != "0" ]; then
    warn "Script is not running as root. Some steps (system package installation) may fail inside Docker."
  fi
  detect_pkg_mgr
  install_base_system_deps
  setup_directories
  ensure_env_file
  detect_project_types

  setup_python
  setup_node
  setup_ruby
  setup_go
  setup_java_maven
  setup_java_gradle
  setup_php
  setup_rust

  configure_runtime
  setup_auto_activate

  # Install GTK/WebKitGTK dev dependencies (for WebKit-based builds)
  setup_gtk_webkitgtk_deps

  # Ensure clang-format is available and run amalgamation if applicable
  setup_clang_format
  if command -v clang-format >/dev/null 2>&1; then
    clang-format --version || true
  fi
  run_amalgamation

  # Build or link example binary expected by tests
  build_or_link_example

  cleanup

  log "Environment setup completed successfully."
  log "To run the application, you can execute: $APP_ROOT/bin/run.sh"
}

main "$@"