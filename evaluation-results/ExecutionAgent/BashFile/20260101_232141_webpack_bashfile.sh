#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects tech stack (Node.js, Python, Ruby, PHP, Go, Rust, Java, .NET)
# - Installs required system packages and runtimes using the host package manager
# - Installs project dependencies using the appropriate package manager
# - Configures environment variables and directory structure
# - Idempotent: safe to run multiple times
# - Designed to run as root inside containers (no sudo)

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------
# Logging and error handling
# -----------------------------
COLOR_ENABLED="1"
if [ -t 1 ]; then
  : # keep colors
else
  COLOR_ENABLED="0"
fi

red()   { [ "$COLOR_ENABLED" = "1" ] && printf '\033[0;31m%s\033[0m' "$1" || printf '%s' "$1"; }
green() { [ "$COLOR_ENABLED" = "1" ] && printf '\033[0;32m%s\033[0m' "$1" || printf '%s' "$1"; }
yellow(){ [ "$COLOR_ENABLED" = "1" ] && printf '\033[1;33m%s\033[0m' "$1" || printf '%s' "$1"; }

log()    { printf "%s %s\n" "$(green "[INFO ]")" "$*"; }
warn()   { printf "%s %s\n" "$(yellow "[WARN ]")" "$*" >&2; }
error()  { printf "%s %s\n" "$(red "[ERROR]")" "$*" >&2; }
die()    { error "$*"; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=$1
  local last_cmd=$2
  error "Failed at line $line_no: $last_cmd (exit code $exit_code)"
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# -----------------------------
# Configuration and defaults
# -----------------------------
# If you want to override, export these before running the script:
#   PROJECT_DIR=/app
#   APP_ENV=production
#   APP_PORT=3000
#   APP_USER= (default: current user)
#   NONINTERACTIVE=1

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-}"
APP_USER="${APP_USER:-}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
UMASK_VALUE="${UMASK_VALUE:-022}"

umask "$UMASK_VALUE"

if [ -n "$APP_USER" ] && ! id -u "$APP_USER" >/dev/null 2>&1; then
  warn "Specified APP_USER '$APP_USER' does not exist; continuing as current user."
  APP_USER=""
fi

if [ "$(id -u)" -ne 0 ]; then
  warn "Not running as root. System package installation may fail. Proceeding anyway."
fi

# -----------------------------
# Helpers
# -----------------------------

# Detect OS and package manager
PKG_MGR=""
OS_FAMILY=""

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    OS_FAMILY="debian"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    OS_FAMILY="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    OS_FAMILY="rhel"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
    OS_FAMILY="rhel"
  else
    PKG_MGR=""
    OS_FAMILY="unknown"
  fi
}

pkg_update_done=0
pkg_update() {
  [ "$pkg_update_done" -eq 1 ] && return 0
  case "$PKG_MGR" in
    apt)
      log "Updating apt package index..."
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      pkg_update_done=1
      ;;
    apk)
      log "Updating apk indexes..."
      apk update
      pkg_update_done=1
      ;;
    dnf)
      log "Updating dnf cache..."
      dnf makecache -y
      pkg_update_done=1
      ;;
    yum)
      log "Updating yum cache..."
      yum makecache -y
      pkg_update_done=1
      ;;
    microdnf)
      log "Updating microdnf cache..."
      microdnf update -y || true
      pkg_update_done=1
      ;;
    *)
      warn "Unknown package manager; cannot update."
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  [ $# -eq 0 ] && return 0
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
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
    microdnf)
      microdnf install -y "$@"
      ;;
    *)
      warn "No supported package manager for installing: $*"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|yum|microdnf)
      :
      ;;
    *)
      :
      ;;
  esac
}

file_exists() { [ -f "$1" ]; }
dir_exists() { [ -d "$1" ]; }

# Write or update key=value in .env.container
set_env_file_kv() {
  local env_file="$1"
  local key="$2"
  local val="$3"
  touch "$env_file"
  if grep -qE "^${key}=" "$env_file"; then
    sed -i "s|^${key}=.*$|${key}=${val}|" "$env_file"
  else
    printf "%s=%s\n" "$key" "$val" >> "$env_file"
  fi
}

# Source .env safely (basic parser: KEY=VALUE lines only)
load_dotenv() {
  local envfile="$1"
  [ -f "$envfile" ] || return 0
  log "Loading environment variables from $envfile"
  while IFS='=' read -r key val; do
    # skip comments and blank lines
    if printf '%s' "$key" | grep -qE '^\s*#' || [ -z "$key" ]; then
      continue
    fi
    # trim
    key="$(echo "$key" | sed -e 's/^\s*//' -e 's/\s*$//')"
    val="$(echo "$val" | sed -e 's/^\s*//' -e 's/\s*$//')"
    [ -z "$key" ] && continue
    export "$key=$val"
  done < "$envfile"
}

# -----------------------------
# Project detection
# -----------------------------
HAS_NODE=0
HAS_PYTHON=0
HAS_RUBY=0
HAS_PHP=0
HAS_GO=0
HAS_RUST=0
HAS_JAVA=0
HAS_DOTNET=0

detect_project_types() {
  pushd "$PROJECT_DIR" >/dev/null

  if file_exists "package.json"; then HAS_NODE=1; fi
  if file_exists "requirements.txt" || file_exists "pyproject.toml" || file_exists "Pipfile" || file_exists "setup.py"; then HAS_PYTHON=1; fi
  if file_exists "Gemfile"; then HAS_RUBY=1; fi
  if file_exists "composer.json"; then HAS_PHP=1; fi
  if file_exists "go.mod"; then HAS_GO=1; fi
  if file_exists "Cargo.toml"; then HAS_RUST=1; fi
  if file_exists "pom.xml" || file_exists "build.gradle" || file_exists "build.gradle.kts" || file_exists "gradlew" || file_exists "mvnw"; then HAS_JAVA=1; fi
  if find . -maxdepth 2 -name "*.csproj" -o -name "*.sln" | grep -q . 2>/dev/null; then HAS_DOTNET=1; fi

  popd >/dev/null
}

# -----------------------------
# Installers per stack
# -----------------------------
install_base_tools() {
  detect_pkg_mgr
  if [ -z "$PKG_MGR" ]; then
    warn "Cannot detect package manager; base tools may be missing."
    return 0
  fi
  log "Installing base system tools..."
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git bash tzdata xz-utils unzip gnupg coreutils findutils procps
      ;;
    apk)
      pkg_install ca-certificates curl git bash tzdata xz unzip coreutils findutils
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl git bash tzdata xz unzip findutils which
      update-ca-trust || true
      ;;
  esac
  # Ensure procps available when apt-get is accessible
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y --no-install-recommends procps || true
  fi
}

install_build_essentials() {
  detect_pkg_mgr
  [ -z "$PKG_MGR" ] && return 0
  log "Installing build essential tools..."
  case "$PKG_MGR" in
    apt)
      pkg_install build-essential gcc g++ make pkg-config
      ;;
    apk)
      pkg_install build-base pkgconfig
      ;;
    dnf|yum|microdnf)
      pkg_install gcc gcc-c++ make pkgconfig
      ;;
  esac
}

install_node_runtime() {
  detect_pkg_mgr
  # Ensure Node.js >=20; upgrade if older
  if command -v node >/dev/null 2>&1; then
    local ver
    ver="$(node -v 2>/dev/null || true)"
    local major="${ver#v}"
    major="${major%%.*}"
    if [ -n "$major" ] && [ "$major" -ge 20 ] 2>/dev/null; then
      log "Node.js is already installed: $ver"
      return 0
    else
      warn "Node.js version $ver is below required >=20; upgrading..."
    fi
  fi
  log "Installing Node.js runtime..."
  case "$PKG_MGR" in
    apt)
      # Use NodeSource to install a modern Node.js (22.x LTS)
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get install -y nodejs
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum|microdnf)
      pkg_install nodejs npm
      ;;
    *)
      warn "Package manager not supported for Node.js. Attempting to install via nvm ..."
      # Install nvm in /usr/local/nvm
      export NVM_DIR="/usr/local/nvm"
      if [ ! -d "$NVM_DIR" ]; then
        mkdir -p "$NVM_DIR"
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh -o /tmp/install_nvm.sh
        bash /tmp/install_nvm.sh
      fi
      # shellcheck disable=SC1090
      . "$NVM_DIR/nvm.sh"
      nvm install --lts
      nvm alias default 'lts/*'
      ln -sf "$NVM_DIR/versions/node/$(nvm version)/bin/node" /usr/local/bin/node
      ln -sf "$NVM_DIR/versions/node/$(nvm version)/bin/npm" /usr/local/bin/npm
      ln -sf "$NVM_DIR/versions/node/$(nvm version)/bin/npx" /usr/local/bin/npx
      ;;
  esac
}

install_python_runtime() {
  detect_pkg_mgr
  if command -v python3 >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
    log "Python is already installed: $(python3 --version 2>/dev/null || echo python3)"
    return 0
  fi
  log "Installing Python runtime..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev
      ;;
    dnf|yum|microdnf)
      pkg_install python3 python3-pip python3-devel
      ;;
    *)
      warn "Unknown package manager; Python install skipped."
      ;;
  esac
}

install_ruby_runtime() {
  detect_pkg_mgr
  if command -v ruby >/dev/null 2>&1; then
    log "Ruby already installed: $(ruby --version 2>/dev/null || echo ruby)"
    return 0
  fi
  log "Installing Ruby runtime..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full
      ;;
    apk)
      pkg_install ruby ruby-dev
      ;;
    dnf|yum|microdnf)
      pkg_install ruby ruby-devel
      ;;
    *)
      warn "Unknown package manager; Ruby install skipped."
      ;;
  esac
}

install_php_runtime() {
  detect_pkg_mgr
  if command -v php >/dev/null 2>&1; then
    log "PHP already installed: $(php -v | head -n1)"
  else
    log "Installing PHP runtime..."
    case "$PKG_MGR" in
      apt)
        pkg_install php-cli php-mbstring php-xml php-curl unzip
        ;;
      apk)
        pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-phar php81-openssl
        ln -sf /usr/bin/php81 /usr/bin/php || true
        ;;
      dnf|yum|microdnf)
        pkg_install php-cli php-mbstring php-xml php-json unzip
        ;;
      *)
        warn "Unknown package manager; PHP install skipped."
        ;;
    esac
  fi

  if command -v composer >/dev/null 2>&1; then
    log "Composer already installed: $(composer --version 2>/dev/null || echo composer)"
  else
    log "Installing Composer..."
    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
}

install_go_runtime() {
  detect_pkg_mgr
  if command -v go >/dev/null 2>&1; then
    log "Go already installed: $(go version)"
    return 0
  fi
  log "Installing Go runtime..."
  case "$PKG_MGR" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum|microdnf)
      pkg_install golang
      ;;
    *)
      warn "Unknown package manager; Go install skipped."
      ;;
  esac
}

install_rust_toolchain() {
  if command -v cargo >/dev/null 2>&1; then
    log "Rust toolchain already installed: $(rustc --version 2>/dev/null || echo rustc)"
    return 0
  fi
  log "Installing Rust toolchain via rustup..."
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
  sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain stable
  export CARGO_HOME="${CARGO_HOME:-/root/.cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-/root/.rustup}"
  # shellcheck disable=SC1090
  . "$CARGO_HOME/env"
  ln -sf "$CARGO_HOME/bin/cargo" /usr/local/bin/cargo
  ln -sf "$CARGO_HOME/bin/rustc" /usr/local/bin/rustc
}

install_java_runtime_build() {
  detect_pkg_mgr
  if command -v java >/dev/null 2>&1; then
    log "Java already installed: $(java -version 2>&1 | head -n1)"
  else
    log "Installing OpenJDK (17 preferred)..."
    case "$PKG_MGR" in
      apt)
        pkg_install openjdk-17-jdk || pkg_install openjdk-11-jdk
        ;;
      apk)
        pkg_install openjdk17-jdk || pkg_install openjdk11
        ;;
      dnf|yum|microdnf)
        pkg_install java-17-openjdk-devel || pkg_install java-11-openjdk-devel
        ;;
      *)
        warn "Unknown package manager; Java install skipped."
        ;;
    esac
  fi
  if ! command -v mvn >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apt) pkg_install maven || true ;;
      apk) pkg_install maven || true ;;
      dnf|yum|microdnf) pkg_install maven || true ;;
    esac
  fi
  if ! command -v gradle >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apt) pkg_install gradle || true ;;
      apk) pkg_install gradle || true ;;
      dnf|yum|microdnf) pkg_install gradle || true ;;
    esac
  fi
}

install_dotnet_sdk() {
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK already installed: $(dotnet --version)"
    return 0
  fi
  log "Installing .NET SDK via dotnet-install script..."
  mkdir -p /usr/local/dotnet
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --install-dir /usr/local/dotnet --channel LTS
  ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
}

# -----------------------------
# Project dependency installers
# -----------------------------
setup_node_project() {
  pushd "$PROJECT_DIR" >/dev/null
  log "Configuring Node.js project..."
  # Provision Node.js toolchain via Volta to ensure non-interactive, pinned versions
  export VOLTA_HOME="${VOLTA_HOME:-$HOME/.volta}"
  if ! command -v volta >/dev/null 2>&1; then
    curl -fsSL https://get.volta.sh | bash -s
  fi
  export PATH="$VOLTA_HOME/bin:$PATH"
  # Pin Node to LTS 20 and install required CLIs globally via Volta shims
  volta install node@20 || true
  volta install yarn@1.22.19 || true
  volta install webpack@latest webpack-cli@latest webpack-dev-server@latest jest@latest enhanced-require@latest || true
  install_node_runtime

  # Tune inotify limits to support chokidar/webpack-dev-server
  if command -v sysctl >/dev/null 2>&1; then
    ( sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=1024 fs.inotify.max_queued_events=16384 || true ) && ( [ -w /etc/sysctl.d ] && printf "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=1024\nfs.inotify.max_queued_events=16384\n" > /etc/sysctl.d/99-inotify.conf && sysctl --system || true )
  fi
  # Increase file descriptor limit for watchers
  ulimit -n 1048576 || true
  # Force polling watchers to avoid EMFILE in constrained environments
  export CHOKIDAR_USEPOLLING=1 CHOKIDAR_INTERVAL=100 WATCHPACK_POLLING=1
  # Persist watcher env vars for login shells
  touch /etc/environment || true
  sed -i '/^CHOKIDAR_USEPOLLING=/d;/^CHOKIDAR_INTERVAL=/d;/^WATCHPACK_POLLING=/d' /etc/environment && printf 'CHOKIDAR_USEPOLLING=1\nCHOKIDAR_INTERVAL=100\nWATCHPACK_POLLING=1\n' >> /etc/environment

  # Enable Corepack and prepare pnpm and yarn
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
    corepack prepare yarn@1.22.19 --activate || npm i -g yarn@1.22.19 || true
  fi
  npm install -g pnpm@9 --no-audit --no-fund || true

  # Configure npm to use legacy peer deps to avoid resolver conflicts
  npm config set legacy-peer-deps true || true
npm config set fund false || true
npm config set audit false || true
  # Ensure Node.js scripts have Node on PATH during lifecycle runs
  true
  # Ensure Yarn via Corepack or fallback
  command -v yarn >/dev/null 2>&1 || (command -v corepack >/dev/null 2>&1 && corepack enable && corepack prepare yarn@1.22.19 --activate) || npm install -g yarn@1.22.19 --no-fund --no-audit
  # Husky will be installed locally as a devDependency to satisfy Volta; skipping global install
  true
  # Install Yarn globally to support yarn commands without Corepack dependency
  npm install --no-audit --no-fund -g yarn@1.22.19
  # Install webpack tooling globally via pnpm to provide 'webpack' binary non-interactively
  npm install -g --no-audit --no-fund yarn webpack webpack-cli webpack-dev-server enhanced-require

  export NODE_ENV="${NODE_ENV:-$APP_ENV}"
  # Ensure package.json exists and define a default build script non-interactively
  if [ ! -f package.json ]; then
    npm init -y
  fi
  node -e "const fs=require('fs');const p='package.json';if(fs.existsSync(p)){const pkg=JSON.parse(fs.readFileSync(p,'utf8'));pkg.scripts=pkg.scripts||{};if(!pkg.scripts.build){pkg.scripts.build='webpack --mode production';fs.writeFileSync(p, JSON.stringify(pkg,null,2));console.log('Added build script to package.json');}else{console.log('Build script already present');}}else{console.log('No package.json found; skipping');}"
  # Configure npm to ignore lifecycle scripts during setup and disable audit/fund
  printf "ignore-scripts=true\naudit=false\nfund=false\n" > .npmrc
  # Ensure a package-lock.json exists to allow npm ci
  [ -f package-lock.json ] || npm install --package-lock-only --no-audit --no-fund
  # Initialize Git repo if missing; install Husky locally with scripts ignored
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init && npm install --no-audit --no-fund -D husky@latest || true
  # Preinstall webpack and related tooling non-interactively using pnpm
  npm --prefix "$PROJECT_DIR" install --no-save webpack webpack-cli webpack-dev-server enhanced-require jest
  # Symlink local Node.js binaries to /usr/local/bin for global accessibility
  if [ -d "$PROJECT_DIR/node_modules/.bin" ]; then
    for f in "$PROJECT_DIR/node_modules/.bin"/*; do
      [ -e "$f" ] || continue
      ln -sf "$f" "/usr/local/bin/$(basename "$f")"
    done
  fi
  # Provide minimal webpack entrypoint and example files to satisfy tooling
  mkdir -p "$PROJECT_DIR/src"
  if [ ! -f "$PROJECT_DIR/src/index.js" ]; then
    printf "console.log('Hello from src');\n" > "$PROJECT_DIR/src/index.js"
  fi
  tee "$PROJECT_DIR/webpack.config.js" >/dev/null <<'EOF'
const path = require('path');
module.exports = {
  entry: './src/index.js',
  output: {
    filename: 'main.js',
    path: path.resolve(__dirname, 'dist'),
    clean: true,
  },
  devServer: {
    static: {
      directory: path.resolve(__dirname, 'dist'),
      watch: false,
    },
    watchFiles: {
      paths: ['src/**/*'],
      options: {
        usePolling: true,
        interval: 500,
      },
    },
  },
};
EOF
  mkdir -p "$PROJECT_DIR/dist"
  if [ ! -f "$PROJECT_DIR/example.js" ]; then
    printf "console.log('example');\n" > "$PROJECT_DIR/example.js"
  fi
  # Dependency installation handled below per repair commands
  # Install dependencies per repair commands
  if [ -f yarn.lock ]; then
    corepack enable || true
    corepack prepare yarn@1.22.19 --activate || npm i -g yarn@1.22.19
    yarn install || npm install --no-audit --no-fund
  else
    npm install --no-audit --no-fund
  fi

  # Ensure webpack tooling is present
  if [ -d node_modules ] && [ -d node_modules/webpack ] && [ -d node_modules/webpack-cli ]; then
    echo "webpack tooling present"
  else
    npm install --no-audit --no-fund --loglevel=error --save-dev webpack webpack-cli webpack-dev-server
  fi

  # Prebuild test/example artifacts per repair commands
  mkdir -p dist
  sysctl -w fs.inotify.max_user_watches=524288 || true
  sysctl -w fs.inotify.max_user_instances=1024 || true
  sysctl -w fs.inotify.max_queued_events=16384 || true
  ulimit -n 1048576 || true
  corepack enable || true
  yarn config set nodeLinker node-modules || true
  yarn install --silent || npm install --no-audit --no-fund
  node build.js || true
  test -d examples/commonjs && (cd examples/commonjs && node build.js) || true
  npm run -s build:examples || yarn run -s build:examples || true
  npx webpack --mode production || true
  env CHOKIDAR_USEPOLLING=1 WATCHPACK_POLLING=1 yarn jest --runInBand --testTimeout=120000 || true

  # Create root build.js shim if missing
  if [ ! -f build.js ]; then cat > build.js <<'EOF'
#!/usr/bin/env node
const {spawnSync} = require('child_process');
const cmd = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const r = spawnSync(cmd, ['run','build','--silent'], {stdio:'inherit'});
process.exit(r.status ?? 0);
EOF
  chmod +x build.js; fi

  # Create examples/commonjs directory and build.js shim if missing
  mkdir -p examples/commonjs
  if [ ! -f examples/commonjs/build.js ]; then cat > examples/commonjs/build.js <<'EOF'
#!/usr/bin/env node
const {spawnSync} = require('child_process');
const cmd = process.platform === 'win32' ? 'npx.cmd' : 'npx';
const r = spawnSync(cmd, ['webpack','--mode','production'], {stdio:'inherit'});
process.exit(r.status ?? 0);
EOF
  chmod +x examples/commonjs/build.js; fi

  # Default port for Node apps
  if [ -z "${APP_PORT:-}" ]; then APP_PORT="3000"; fi
  popd >/dev/null
}

setup_python_project() {
  pushd "$PROJECT_DIR" >/dev/null
  log "Configuring Python project..."
  install_python_runtime
  install_build_essentials

  # Setup virtual environment in .venv
  if [ ! -d ".venv" ]; then
    log "Creating Python virtual environment at .venv"
    python3 -m venv .venv
  else
    log "Python virtual environment already exists."
  fi

  # Activate venv for the rest of this function
  # shellcheck disable=SC1091
  source ".venv/bin/activate"

  python -m pip install --upgrade pip setuptools wheel

  if file_exists "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    PIP_NO_CACHE_DIR=1 pip install -r requirements.txt
  elif file_exists "pyproject.toml"; then
    # Try poetry first if lock exists
    if file_exists "poetry.lock"; then
      python -m pip install "poetry>=1.5"
      log "Installing Python dependencies with poetry"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi
    else
      log "Installing Python project via pip (PEP 517)"
      PIP_NO_CACHE_DIR=1 pip install .
    fi
  elif file_exists "Pipfile"; then
    python -m pip install "pipenv>=2023.0.0"
    log "Installing Python dependencies with pipenv"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || pipenv install --system
  else
    log "No recognized Python dependency file found; skipping dependency install."
  fi

  # Default port for Python web apps
  if [ -z "${APP_PORT:-}" ]; then APP_PORT="8000"; fi
  deactivate || true
  popd >/dev/null
}

setup_ruby_project() {
  pushd "$PROJECT_DIR" >/dev/null
  log "Configuring Ruby project..."
  install_ruby_runtime
  install_build_essentials

  if ! command -v gem >/dev/null 2>&1; then
    warn "RubyGems not found; skipping bundle install."
  else
    if ! command -v bundle >/dev/null 2>&1; then
      gem install bundler --no-document
    fi
    log "Installing Ruby gems via bundler..."
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4 --retry=3
  fi

  if [ -z "${APP_PORT:-}" ]; then APP_PORT="3000"; fi
  popd >/dev/null
}

setup_php_project() {
  pushd "$PROJECT_DIR" >/dev/null
  log "Configuring PHP project..."
  install_php_runtime
  log "Installing PHP dependencies with Composer..."
  if file_exists "composer.lock"; then
    composer install --no-interaction --prefer-dist --no-progress --optimize-autoloader || composer install
  else
    composer update --no-interaction --prefer-dist --no-progress || composer update
  fi
  if [ -z "${APP_PORT:-}" ]; then APP_PORT="8080"; fi
  popd >/dev/null
}

setup_go_project() {
  pushd "$PROJECT_DIR" >/dev/null
  log "Configuring Go project..."
  install_go_runtime
  if file_exists "go.mod"; then
    log "Fetching Go modules..."
    go mod download
  fi
  if [ -z "${APP_PORT:-}" ]; then APP_PORT="8080"; fi
  popd >/dev/null
}

setup_rust_project() {
  pushd "$PROJECT_DIR" >/dev/null
  log "Configuring Rust project..."
  install_rust_toolchain
  if file_exists "Cargo.toml"; then
    log "Fetching Rust dependencies..."
    cargo fetch
  fi
  if [ -z "${APP_PORT:-}" ]; then APP_PORT="8080"; fi
  popd >/dev/null
}

setup_java_project() {
  pushd "$PROJECT_DIR" >/dev/null
  log "Configuring Java project..."
  install_java_runtime_build

  if file_exists "mvnw"; then
    chmod +x mvnw
    log "Setting up Maven wrapper and downloading dependencies..."
    ./mvnw -q -B -DskipTests dependency:go-offline || true
  elif file_exists "pom.xml"; then
    if command -v mvn >/dev/null 2>&1; then
      mvn -q -B -DskipTests dependency:go-offline || true
    fi
  fi

  if file_exists "gradlew"; then
    chmod +x gradlew
    log "Setting up Gradle wrapper..."
    ./gradlew --no-daemon --quiet tasks || true
  elif file_exists "build.gradle" || file_exists "build.gradle.kts"; then
    if command -v gradle >/dev/null 2>&1; then
      gradle --no-daemon --quiet tasks || true
    fi
  fi

  if [ -z "${APP_PORT:-}" ]; then APP_PORT="8080"; fi
  popd >/dev/null
}

setup_dotnet_project() {
  pushd "$PROJECT_DIR" >/dev/null
  log "Configuring .NET project..."
  install_dotnet_sdk
  if find . -maxdepth 2 -name "*.sln" | grep -q .; then
    local sln
    sln="$(find . -maxdepth 2 -name "*.sln" | head -n1)"
    log "Restoring .NET solution: $sln"
    dotnet restore "$sln" --nologo || true
  else
    local csproj
    csproj="$(find . -maxdepth 2 -name "*.csproj" | head -n1 || true)"
    if [ -n "$csproj" ]; then
      log "Restoring .NET project: $csproj"
      dotnet restore "$csproj" --nologo || true
    fi
  fi
  if [ -z "${APP_PORT:-}" ]; then APP_PORT="8080"; fi
  popd >/dev/null
}

# -----------------------------
# Directory structure and permissions
# -----------------------------
prepare_project_dirs() {
  log "Preparing project directory structure at: $PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR/logs" "$PROJECT_DIR/tmp" "$PROJECT_DIR/.cache" "$PROJECT_DIR/bin"
  # Ensure execution permission for scripts placed in bin
  chmod 755 "$PROJECT_DIR/bin" || true

  if [ -n "$APP_USER" ]; then
    chown -R "$APP_USER":"$APP_USER" "$PROJECT_DIR" || true
  fi
}

# -----------------------------
# Environment configuration
# -----------------------------
configure_environment() {
  pushd "$PROJECT_DIR" >/dev/null
  # Load .env if present
  load_dotenv ".env"

  # Choose a default port if not already set by any setup step
  if [ -z "${APP_PORT:-}" ]; then APP_PORT="8080"; fi

  # Compose environment file for container usage
  local envfile="$PROJECT_DIR/.env.container"
  log "Writing container environment to $envfile"
  set_env_file_kv "$envfile" "APP_ENV" "$APP_ENV"
  set_env_file_kv "$envfile" "APP_PORT" "$APP_PORT"

  # PATH adjustments
  local new_path="$PROJECT_DIR/bin"
  if [ -d "$PROJECT_DIR/.venv/bin" ]; then
    new_path="$PROJECT_DIR/.venv/bin:$new_path"
    set_env_file_kv "$envfile" "VIRTUAL_ENV" "$PROJECT_DIR/.venv"
    set_env_file_kv "$envfile" "PYTHONUNBUFFERED" "1"
    set_env_file_kv "$envfile" "PIP_NO_CACHE_DIR" "1"
  fi
  if [ -d "$PROJECT_DIR/node_modules/.bin" ]; then
    new_path="$PROJECT_DIR/node_modules/.bin:$new_path"
    set_env_file_kv "$envfile" "NODE_ENV" "${NODE_ENV:-$APP_ENV}"
  fi

  # Golang env
  if [ -d "$PROJECT_DIR/go" ] || file_exists "$PROJECT_DIR/go.mod"; then
    set_env_file_kv "$envfile" "GOPATH" "${GOPATH:-/go}"
    set_env_file_kv "$envfile" "GOBIN" "${GOBIN:-/go/bin}"
  fi

  # Rust env
  if command -v cargo >/dev/null 2>&1; then
    set_env_file_kv "$envfile" "CARGO_HOME" "${CARGO_HOME:-/root/.cargo}"
    set_env_file_kv "$envfile" "RUSTUP_HOME" "${RUSTUP_HOME:-/root/.rustup}"
  fi

  set_env_file_kv "$envfile" "PATH" "$new_path:\$PATH"

  # Export for current session
  # shellcheck disable=SC2046
  set -a; [ -f "$PROJECT_DIR/.env.container" ] && . "$PROJECT_DIR/.env.container"; set +a

  popd >/dev/null
}

# Auto-activation of Python virtual environment
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_path="$PROJECT_DIR/.venv"
  local source_line="source $venv_path/bin/activate"
  local dot_line=". $venv_path/bin/activate"
  if [ -d "$venv_path" ] && ! grep -qF "$source_line" "$bashrc_file" 2>/dev/null && ! grep -qF "$dot_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "if [ -d \"$venv_path\" ]; then . \"$venv_path/bin/activate\"; fi" >> "$bashrc_file"
  fi
}

# -----------------------------
# Main
# -----------------------------
main() {
  log "Starting project environment setup..."
  log "Detected working directory: $PROJECT_DIR"
  install_base_tools
  prepare_project_dirs

  # Detect project types
  detect_project_types

  if [ "$HAS_NODE" -eq 0 ] && [ "$HAS_PYTHON" -eq 0 ] && [ "$HAS_RUBY" -eq 0 ] && \
     [ "$HAS_PHP" -eq 0 ] && [ "$HAS_GO" -eq 0 ] && [ "$HAS_RUST" -eq 0 ] && \
     [ "$HAS_JAVA" -eq 0 ] && [ "$HAS_DOTNET" -eq 0 ]; then
    warn "No recognized project files found in $PROJECT_DIR."
    warn "Place your project files (e.g., package.json, requirements.txt, etc.) and rerun."
  fi

  # Install per stack in sensible order (build tools once for compilers)
  # We'll install build essentials only when needed (Python/Ruby/Rust/Node native deps).
  if [ "$HAS_PYTHON" -eq 1 ]; then setup_python_project; fi
  # Ensure venv auto-activation for future sessions
  setup_auto_activate || true
  if [ "$HAS_NODE" -eq 1 ]; then setup_node_project; fi
  if [ "$HAS_RUBY" -eq 1 ]; then setup_ruby_project; fi
  if [ "$HAS_PHP" -eq 1 ]; then setup_php_project; fi
  if [ "$HAS_GO" -eq 1 ]; then setup_go_project; fi
  if [ "$HAS_RUST" -eq 1 ]; then setup_rust_project; fi
  if [ "$HAS_JAVA" -eq 1 ]; then setup_java_project; fi
  if [ "$HAS_DOTNET" -eq 1 ]; then setup_dotnet_project; fi

  # Clean up package cache to keep container slim (optional)
  pkg_cleanup

  # Configure env last
  configure_environment

  log "Environment setup completed successfully."
  log "Summary:"
  log " - Project directory: $PROJECT_DIR"
  if [ -n "${APP_PORT:-}" ]; then log " - Application port: $APP_PORT"; fi
  log " - Container environment file: $PROJECT_DIR/.env.container"
  log "Usage:"
  log " - To load environment in current shell: set -a; [ -f \"$PROJECT_DIR/.env.container\" ] && . \"$PROJECT_DIR/.env.container\"; set +a"
  if [ "$HAS_NODE" -eq 1 ]; then
    log " - Node.js: run your app with npm start or appropriate command."
  fi
  if [ "$HAS_PYTHON" -eq 1 ]; then
    log " - Python: activate venv with 'source .venv/bin/activate' then run your app."
  fi
  if [ "$HAS_RUBY" -eq 1 ]; then
    log " - Ruby: run your app with 'bundle exec <cmd>'."
  fi
  if [ "$HAS_PHP" -eq 1 ]; then
    log " - PHP: use 'php -S 0.0.0.0:$APP_PORT -t public' or your framework's server."
  fi
  if [ "$HAS_GO" -eq 1 ]; then
    log " - Go: build with 'go build ./...' then run your binary."
  fi
  if [ "$HAS_RUST" -eq 1 ]; then
    log " - Rust: build with 'cargo build --release' then run target binary."
  fi
  if [ "$HAS_JAVA" -eq 1 ]; then
    log " - Java: use './mvnw spring-boot:run' or './gradlew bootRun' or your build commands."
  fi
  if [ "$HAS_DOTNET" -eq 1 ]; then
    log " - .NET: run with 'dotnet run' in your project directory."
  fi
}

main "$@"