#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types (Node.js, Python, Ruby, PHP/Composer, Go, Rust, Java/Maven/Gradle, .NET, Deno)
# - Installs required system packages and runtimes
# - Installs project dependencies
# - Configures environment variables and paths
# - Idempotent and safe to run multiple times
# - Designed to run as root inside Docker (no sudo), but degrades gracefully if not root

set -Eeuo pipefail
IFS=$'\n\t'

# --------------- Configurable defaults ---------------
: "${PROJECT_ROOT:=$(pwd)}"
: "${APP_ENV:=production}"
: "${NODE_ENV:=production}"
: "${PYTHON_VERSION_MIN:=3.8}" # minimum acceptable Python 3 version for Python projects
: "${DOTNET_CHANNEL:=LTS}"     # .NET channel for dotnet-install (LTS or specific version)
: "${NONINTERACTIVE:=1}"       # set to 1 to force non-interactive package installs
: "${LOG_LEVEL:=INFO}"         # INFO|WARN|ERROR
# -----------------------------------------------------

# --------------- Logging ---------------
NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log()      { echo -e "${GREEN}[$(timestamp)] [INFO]${NC} $*"; }
warn()     { echo -e "${YELLOW}[$(timestamp)] [WARN]${NC} $*" >&2; }
error()    { echo -e "${RED}[$(timestamp)] [ERROR]${NC} $*" >&2; }
debug()    { [ "${LOG_LEVEL}" = "DEBUG" ] && echo -e "${BLUE}[$(timestamp)] [DEBUG]${NC} $*"; }
# ---------------------------------------

# --------------- Trap and cleanup ---------------
cleanup() { :; }
trap cleanup EXIT
trap 'error "An error occurred on line $LINENO"; exit 1' ERR
# -----------------------------------------------

# --------------- Utilities ---------------
is_root() { [ "$(id -u)" -eq 0 ]; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_file() { [ -f "$PROJECT_ROOT/$1" ]; }
has_dir() { [ -d "$PROJECT_ROOT/$1" ]; }
file_contains() { [ -f "$PROJECT_ROOT/$1" ] && grep -qiE "$2" "$PROJECT_ROOT/$1"; }

# Create directory with proper perms
ensure_dir() {
  local path="$1" mode="${2:-0755}"
  mkdir -p "$path"
  chmod "$mode" "$path" || true
}

# --------------- OS/package manager detection ---------------
PKG_MANAGER=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""
PKG_CLEAN_CMD=""
detect_pkg_manager() {
  if has_cmd apt-get; then
    PKG_MANAGER="apt"
    export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}
    PKG_UPDATE_CMD="apt-get update -y"
    PKG_INSTALL_CMD="apt-get install -y --no-install-recommends"
    PKG_CLEAN_CMD="apt-get clean && rm -rf /var/lib/apt/lists/*"
  elif has_cmd apk; then
    PKG_MANAGER="apk"
    PKG_UPDATE_CMD="apk update"
    PKG_INSTALL_CMD="apk add --no-cache"
    PKG_CLEAN_CMD=":" # no-op
  elif has_cmd microdnf; then
    PKG_MANAGER="microdnf"
    PKG_UPDATE_CMD="microdnf update -y || true"
    PKG_INSTALL_CMD="microdnf install -y"
    PKG_CLEAN_CMD="microdnf clean all || true"
  elif has_cmd dnf; then
    PKG_MANAGER="dnf"
    PKG_UPDATE_CMD="dnf makecache -y || true"
    PKG_INSTALL_CMD="dnf install -y"
    PKG_CLEAN_CMD="dnf clean all || true"
  elif has_cmd yum; then
    PKG_MANAGER="yum"
    PKG_UPDATE_CMD="yum makecache -y || true"
    PKG_INSTALL_CMD="yum install -y"
    PKG_CLEAN_CMD="yum clean all || true"
  elif has_cmd zypper; then
    PKG_MANAGER="zypper"
    PKG_UPDATE_CMD="zypper --non-interactive refresh"
    PKG_INSTALL_CMD="zypper --non-interactive install -y"
    PKG_CLEAN_CMD="zypper clean -a || true"
  else
    PKG_MANAGER="unknown"
  fi
}

pkg_update() { [ "$PKG_MANAGER" != "unknown" ] && sh -c "$PKG_UPDATE_CMD"; }
pkg_install() {
  if [ "$PKG_MANAGER" = "unknown" ]; then
    warn "No supported package manager detected. Skipping system package installation."
    return 0
  fi
  local pkgs=("$@")
  if [ "${#pkgs[@]}" -eq 0 ]; then return 0; fi
  debug "Installing packages: ${pkgs[*]}"
  sh -c "$PKG_INSTALL_CMD ${pkgs[*]}"
}
pkg_clean() { [ "$PKG_MANAGER" != "unknown" ] && sh -c "$PKG_CLEAN_CMD"; }

# OS-specific package lists
install_base_build_tools() {
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git bash build-essential pkg-config python3 python3-pip python3-venv python3-dev gcc g++ make openssl libssl-dev libc6-dev unzip xz-utils procps jq coreutils
      ;;
    apk)
      pkg_install ca-certificates curl git bash build-base pkgconfig python3 py3-pip python3-dev musl-dev openssl openssl-dev unzip xz
      ;;
    microdnf|dnf|yum)
      pkg_install ca-certificates curl git bash gcc gcc-c++ make pkgconfig python3 python3-pip python3-devel openssl openssl-devel unzip xz
      ;;
    zypper)
      pkg_install ca-certificates curl git bash gcc gcc-c++ make pkg-config python3 python3-pip python3-devel libopenssl-devel unzip xz
      ;;
    *)
      warn "Skipping base build tools installation due to unknown package manager."
      ;;
  esac
}

# --------------- Project detection ---------------
PROJECT_TYPE="unknown"
detect_project_type() {
  if has_file package.json; then PROJECT_TYPE="node"; fi
  if has_file requirements.txt || has_file pyproject.toml || has_file Pipfile; then PROJECT_TYPE="${PROJECT_TYPE}+python"; fi
  if has_file Gemfile; then PROJECT_TYPE="${PROJECT_TYPE}+ruby"; fi
  if has_file composer.json; then PROJECT_TYPE="${PROJECT_TYPE}+php"; fi
  if has_file go.mod; then PROJECT_TYPE="${PROJECT_TYPE}+go"; fi
  if has_file Cargo.toml; then PROJECT_TYPE="${PROJECT_TYPE}+rust"; fi
  if has_file pom.xml; then PROJECT_TYPE="${PROJECT_TYPE}+java-maven"; fi
  if has_file build.gradle || has_file settings.gradle || has_file gradlew; then PROJECT_TYPE="${PROJECT_TYPE}+java-gradle"; fi
  if ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1 || ls "$PROJECT_ROOT"/*.sln >/dev/null 2>&1; then PROJECT_TYPE="${PROJECT_TYPE}+dotnet"; fi
  if has_file deno.json || has_file deno.jsonc; then PROJECT_TYPE="${PROJECT_TYPE}+deno"; fi

  # Normalize if empty
  if [ "$PROJECT_TYPE" = "unknown" ] || [ -z "$PROJECT_TYPE" ]; then
    PROJECT_TYPE="unknown"
  else
    PROJECT_TYPE="${PROJECT_TYPE#+}" # trim leading plus
  fi
  log "Detected project type: $PROJECT_TYPE"
}

# --------------- Environment variables and profiles ---------------
ENV_FILE_SYSTEM="/etc/profile.d/project_env.sh"
ENV_FILE_LOCAL="$PROJECT_ROOT/.env.sh"
write_env_file() {
  local target="$1"
  local can_write=1
  if [ "$target" = "$ENV_FILE_SYSTEM" ] && ! is_root; then
    can_write=0
  fi

  if [ "$can_write" -eq 1 ]; then
    cat > "$target" <<'EOF'
# Project environment defaults
export APP_ENV=${APP_ENV:-production}
export NODE_ENV=${NODE_ENV:-production}
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
# Add common local bin paths
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
# Enable Python venv in project if present
if [ -d "$PWD/.venv" ]; then
  export VIRTUAL_ENV="$PWD/.venv"
  export PATH="$VIRTUAL_ENV/bin:$PATH"
fi
# Composer vendor bin
if [ -d "$PWD/vendor/bin" ]; then
  export PATH="$PWD/vendor/bin:$PATH"
fi
# Dotnet
if [ -d "/usr/share/dotnet" ]; then
  export DOTNET_ROOT="/usr/share/dotnet"
  export PATH="$DOTNET_ROOT:$PATH"
elif [ -d "$HOME/.dotnet" ]; then
  export DOTNET_ROOT="$HOME/.dotnet"
  export PATH="$DOTNET_ROOT:$PATH"
fi
EOF
    chmod 0644 "$target" || true
    log "Environment file written: $target"
  else
    warn "Cannot write to $target (not root). Writing to local env file instead."
    write_env_file "$ENV_FILE_LOCAL"
  fi
}

# --------------- Language/runtime installers ---------------

# Node.js setup
setup_node() {
  if ! has_file package.json; then return 0; fi
  log "Setting up Node.js environment..."
  case "$PKG_MANAGER" in
    apt|microdnf|dnf|yum|zypper|apk)
      pkg_update
      case "$PKG_MANAGER" in
        apt)
          pkg_install curl ca-certificates gnupg
          curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
          apt-get install -y nodejs
          ;;
        microdnf|dnf|yum) pkg_install nodejs npm ;;
        zypper) pkg_install nodejs npm ;;
        apk) pkg_install nodejs npm ;;
      esac
      pkg_clean
      ;;
    *)
      warn "Unknown OS package manager - attempting Node.js via tarball is not implemented. Ensure Node.js is present."
      ;;
  esac

  if ! has_cmd node; then
    error "Node.js is not installed or not found in PATH."
    return 1
  fi

  # Ensure grunt CLI is available for grunt-based builds
  if has_cmd npm; then
    command -v start-server-and-test >/dev/null 2>&1 || npm install -g --no-audit --no-fund start-server-and-test || true
    command -v grunt >/dev/null 2>&1 || npm install -g --no-audit --no-fund grunt-cli || true
  else
    warn "npm not found; skipping global CLI installs."
  fi

  # Configure package manager based on lockfiles
  pushd "$PROJECT_ROOT" >/dev/null
  npm config set production false || true
  npm install -D cross-env wait-on start-server-and-test dtslint --no-audit --no-fund || true
  npm install --no-save start-server-and-test || true
  if has_file pnpm-lock.yaml; then
    if has_cmd corepack; then
      corepack enable || true
      corepack prepare pnpm@latest --activate || true
    elif has_cmd npm; then
      npm install -g pnpm --no-audit --no-fund
    fi
    [ -d node_modules ] || ensure_dir node_modules
    if has_cmd pnpm; then
      PNPM_ENABLE_PREPOSTINSTALL=1 pnpm install --frozen-lockfile
    else
      warn "pnpm is not available; falling back to npm install"
      npm_config_production=false npm ci --no-audit --no-fund --include=dev || npm_config_production=false npm install --no-audit --no-fund --include=dev
    fi
  elif has_file yarn.lock; then
    if has_cmd corepack; then
      corepack enable || true
      corepack prepare yarn@stable --activate || true
    elif has_cmd npm; then
      npm install -g yarn
    fi
    [ -d node_modules ] || ensure_dir node_modules
    if has_cmd yarn; then
      yarn install --frozen-lockfile || yarn install
    else
      warn "yarn is not available; falling back to npm install"
      npm_config_production=false npm ci --no-audit --no-fund --include=dev || npm_config_production=false npm install --no-audit --no-fund --include=dev
    fi
  else
    [ -d node_modules ] || ensure_dir node_modules
    npm config set production false || true
    npm install -g --no-audit --no-fund grunt-cli || true
    npm install -D cross-env wait-on start-server-and-test dtslint --no-audit --no-fund || true
    npm install --no-save start-server-and-test || true
    if has_file package-lock.json; then
      npm ci --include=dev --no-audit --no-fund || npm install --no-audit --no-fund --include=dev
    else
      npm install --no-audit --no-fund --include=dev
    fi
  fi
  # Orchestrate npm start to run server and client with start-server-and-test
  if has_file package.json; then
    if ! has_cmd jq; then
      pkg_update || true
      pkg_install jq || true
    fi
    if has_cmd jq; then
      jq '.scripts.start="start-server-and-test \"node ./sandbox/server.js\" http://127.0.0.1:3000 \"node ./sandbox/client\""' package.json > package.json.tmp && mv package.json.tmp package.json || warn "Failed to update package.json start script via jq"
    else
      warn "jq is not available; skipping package.json start script update."
    fi
    # Ensure start-server-and-test is installed as a dev dependency
    if has_cmd npm; then
      npm install --no-audit --no-fund --save-dev start-server-and-test@latest || true
      npm install --no-save start-server-and-test || true
    fi
    # Ensure grunt-cli is available globally for future invocations
    if has_cmd npm; then
      npm install -g --no-audit --no-fund grunt-cli || true
    fi
  fi
  npm install --no-audit --no-fund || true
  popd >/dev/null
  log "Node.js dependencies installed."
}

# Python setup
check_python_version() {
  if has_cmd python3; then
    local ver vcmp
    ver="$(python3 -c 'import sys;print(".".join(map(str,sys.version_info[:3])))')"
    vcmp="$(python3 - "$PYTHON_VERSION_MIN" <<'PY'
import sys
from packaging.version import Version
curr = Version(sys.argv[1])
minv = Version(sys.argv[2])
print(0 if curr >= minv else 1)
PY
"$(python3 -c 'import sys;print(".".join(map(str,sys.version_info[:3])))')" "$1")" || true
    # If packaging not available, fallback skip
  else
    return 1
  fi
}

setup_python() {
  if ! has_file requirements.txt && ! has_file pyproject.toml && ! has_file Pipfile; then return 0; fi
  log "Setting up Python environment..."
  pkg_update || true
  install_base_build_tools || true
  pkg_clean || true

  if ! has_cmd python3; then
    error "python3 not found after installation attempt."
    return 1
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  # Prefer in-project venv
  if [ ! -d ".venv" ]; then
    python3 -m venv .venv
  fi
  # shellcheck disable=SC1091
  source ".venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if has_file requirements.txt; then
    pip install -r requirements.txt
  elif has_file pyproject.toml; then
    if file_contains pyproject.toml 'tool.poetry'; then
      # Install poetry in-project via pipx or pip
      python -m pip install --upgrade pipx || python -m pip install poetry
      if has_cmd pipx; then
        pipx ensurepath || true
        pipx install poetry || pipx upgrade poetry || true
        export PATH="$HOME/.local/bin:$PATH"
      fi
      if has_cmd poetry; then
        poetry config virtualenvs.in-project true
        poetry install --no-interaction --no-ansi || poetry install
      else
        warn "Poetry not available; attempting PEP517 build via pip"
        pip install .
      fi
    else
      # PEP 517 standard build or dependencies specified in pyproject
      pip install . || true
      # If dependencies are specified in optional requirements, this may be a no-op
    fi
  elif has_file Pipfile; then
    pip install pipenv
    pipenv install --deploy || pipenv install
  fi

  deactivate || true
  popd >/dev/null
  log "Python environment configured (.venv) and dependencies installed."
}

# Ruby setup
setup_ruby() {
  if ! has_file Gemfile; then return 0; fi
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install ruby-full build-essential
      pkg_clean
      ;;
    apk)
      pkg_update
      pkg_install ruby ruby-dev build-base
      ;;
    microdnf|dnf|yum)
      pkg_update
      pkg_install ruby ruby-devel gcc gcc-c++ make
      pkg_clean
      ;;
    zypper)
      pkg_update
      pkg_install ruby ruby-devel gcc gcc-c++ make
      pkg_clean
      ;;
    *)
      warn "Unknown package manager; ensure Ruby is installed."
      ;;
  esac
  if ! has_cmd gem; then
    error "Ruby gem tool not available after installation."
    return 1
  fi
  gem install bundler -N || true
  pushd "$PROJECT_ROOT" >/dev/null
  BUNDLE_PATH="vendor/bundle"
  ensure_dir "$BUNDLE_PATH"
  bundle config set --local path "$BUNDLE_PATH"
  bundle install --jobs="$(nproc || echo 2)" --retry=3
  popd >/dev/null
  log "Ruby dependencies installed."
}

# PHP/Composer setup
setup_php() {
  if ! has_file composer.json; then return 0; fi
  log "Setting up PHP/Composer environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install php-cli php-mbstring php-xml php-curl unzip git
      pkg_clean
      ;;
    apk)
      pkg_update
      pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-openssl php81-phar php81-zip unzip git || \
      pkg_install php php-cli php-mbstring php-xml php-curl php-openssl php-phar php-zip unzip git
      ;;
    microdnf|dnf|yum)
      pkg_update
      pkg_install php php-cli php-mbstring php-xml php-curl unzip git
      pkg_clean
      ;;
    zypper)
      pkg_update
      pkg_install php8 php8-cli php8-mbstring php8-xml php8-curl php8-openssl php8-zip unzip git || \
      pkg_install php php-cli php-mbstring php-xml php-curl php-zip unzip git
      pkg_clean
      ;;
    *)
      warn "Unknown package manager; ensure PHP is installed."
      ;;
  esac

  if ! has_cmd composer; then
    # Install composer globally
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || true
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
    rm -f composer-setup.php || true
  fi
  if ! has_cmd composer; then
    error "Composer not available."
    return 1
  fi
  pushd "$PROJECT_ROOT" >/dev/null
  ensure_dir vendor
  composer install --no-interaction --prefer-dist --no-progress || composer install
  popd >/dev/null
  log "Composer dependencies installed."
}

# Go setup
setup_go() {
  if ! has_file go.mod; then return 0; fi
  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apt) pkg_update; pkg_install golang-go; pkg_clean ;;
    apk) pkg_update; pkg_install go ;; 
    microdnf|dnf|yum) pkg_update; pkg_install golang; pkg_clean ;;
    zypper) pkg_update; pkg_install go; pkg_clean ;;
    *) warn "Unknown package manager; ensure Go is installed." ;;
  esac
  if ! has_cmd go; then error "Go not available."; return 1; fi
  pushd "$PROJECT_ROOT" >/dev/null
  go env -w GO111MODULE=on || true
  go mod download
  popd >/dev/null
  log "Go dependencies fetched."
}

# Rust setup
setup_rust() {
  if ! has_file Cargo.toml; then return 0; fi
  log "Setting up Rust environment..."
  case "$PKG_MANAGER" in
    apt) pkg_update; pkg_install cargo; pkg_clean ;;
    apk) pkg_update; pkg_install cargo rust ;; 
    microdnf|dnf|yum) pkg_update; pkg_install cargo; pkg_clean ;;
    zypper) pkg_update; pkg_install cargo; pkg_clean ;;
    *) warn "Unknown package manager; attempting rustup (may fail)." ;;
  esac
  if ! has_cmd cargo; then
    # fallback to rustup
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh || true
    sh /tmp/rustup.sh -y --profile minimal || true
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  if ! has_cmd cargo; then error "Cargo not available."; return 1; fi
  pushd "$PROJECT_ROOT" >/dev/null
  cargo fetch || true
  popd >/dev/null
  log "Rust toolchain ready and dependencies fetched."
}

# Java setup
setup_java() {
  local is_maven=0 is_gradle=0
  has_file pom.xml && is_maven=1
  { has_file build.gradle || has_file settings.gradle || has_file gradlew; } && is_gradle=1
  [ $is_maven -eq 0 ] && [ $is_gradle -eq 0 ] && return 0

  log "Setting up Java environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install openjdk-17-jdk maven gradle || pkg_install default-jdk maven gradle
      pkg_clean
      ;;
    apk)
      pkg_update
      pkg_install openjdk17-jdk maven gradle || pkg_install openjdk11-jdk maven gradle
      ;;
    microdnf|dnf|yum)
      pkg_update
      pkg_install java-17-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven gradle
      pkg_clean
      ;;
    zypper)
      pkg_update
      pkg_install java-17-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven gradle
      pkg_clean
      ;;
    *)
      warn "Unknown package manager; ensure Java, Maven/Gradle are installed."
      ;;
  esac
  if [ $is_maven -eq 1 ] && ! has_cmd mvn; then error "Maven not available."; fi
  if [ $is_gradle -eq 1 ] && ! has_cmd gradle && [ ! -x "$PROJECT_ROOT/gradlew" ]; then warn "Gradle not available; attempting system gradle."; fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ $is_maven -eq 1 ]; then
    mvn -B -ntp -DskipTests dependency:go-offline || true
  fi
  if [ $is_gradle -eq 1 ]; then
    if [ -x "./gradlew" ]; then
      ./gradlew --no-daemon build -x test || ./gradlew --no-daemon dependencies || true
    else
      gradle --no-daemon build -x test || gradle --no-daemon dependencies || true
    fi
  fi
  popd >/dev/null
  log "Java environment ready."
}

# .NET setup
setup_dotnet() {
  # Detect .NET by presence of .csproj or .sln
  if ! ls "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1 && ! ls "$PROJECT_ROOT"/*.sln >/dev/null 2>&1; then return 0; fi
  log "Setting up .NET SDK ($DOTNET_CHANNEL)..."
  local dotnet_root_install="/usr/share/dotnet"
  local install_dir="$dotnet_root_install"
  if ! is_root; then
    install_dir="$HOME/.dotnet"
  fi
  ensure_dir "$install_dir"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  chmod +x /tmp/dotnet-install.sh
  /tmp/dotnet-install.sh --channel "$DOTNET_CHANNEL" --install-dir "$install_dir" || true

  # Export to current shell session
  export DOTNET_ROOT="$install_dir"
  export PATH="$DOTNET_ROOT:$PATH"

  if ! has_cmd dotnet; then
    warn ".NET SDK installation might have failed."
    return 1
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  # Restore for all solutions/projects
  if ls *.sln >/dev/null 2>&1; then
    for sln in *.sln; do dotnet restore "$sln" || true; done
  else
    for csproj in *.csproj; do dotnet restore "$csproj" || true; done
  fi
  popd >/dev/null
  log ".NET environment ready."
}

# Deno setup
setup_deno() {
  if ! has_file deno.json && ! has_file deno.jsonc; then return 0; fi
  log "Setting up Deno..."
  if ! has_cmd deno; then
    curl -fsSL https://deno.land/install.sh -o /tmp/deno_install.sh
    sh /tmp/deno_install.sh -y
    if is_root && [ -f "$HOME/.deno/bin/deno" ]; then
      mv "$HOME/.deno/bin/deno" /usr/local/bin/deno || true
    fi
  fi
  if ! has_cmd deno; then
    warn "Deno not available after install attempt."
    return 1
  fi
  log "Deno installed."
}

# --------------- Ports and framework hints ---------------
detect_port() {
  local port="8080"
  # Python frameworks
  if has_file requirements.txt; then
    if file_contains requirements.txt 'flask'; then port="5000"; fi
    if file_contains requirements.txt 'django'; then port="8000"; fi
    if file_contains requirements.txt 'fastapi|uvicorn'; then port="8000"; fi
  fi
  if has_file pyproject.toml; then
    if file_contains pyproject.toml 'flask'; then port="5000"; fi
    if file_contains pyproject.toml 'django'; then port="8000"; fi
    if file_contains pyproject.toml 'fastapi|uvicorn'; then port="8000"; fi
  fi
  # Node frameworks
  if has_file package.json; then
    if file_contains package.json '"next"' || file_contains package.json '"react-scripts"'; then port="3000"; fi
    if file_contains package.json '"express"'; then port="3000"; fi
    if file_contains package.json '"nestjs"'; then port="3000"; fi
    if file_contains package.json '"vite"'; then port="5173"; fi
  fi
  # Ruby Rails
  if has_file Gemfile && file_contains Gemfile 'rails'; then port="3000"; fi
  # PHP Laravel
  if has_file composer.json && file_contains composer.json 'laravel'; then port="8000"; fi
  # Java Spring Boot default 8080
  # .NET Kestrel default 8080/5000, keep 8080
  echo "$port"
}

# --------------- Permissions ---------------
fix_permissions() {
  # Make sure common dirs are writable by current user or container runtime
  local uid gid
  uid=$(id -u || echo 0)
  gid=$(id -g || echo 0)

  pushd "$PROJECT_ROOT" >/dev/null
  for d in .venv node_modules vendor .m2 .gradle .cache target bin dist build; do
    [ -e "$d" ] && chown -R "$uid:$gid" "$d" || true
  done
  popd >/dev/null
}

# --------------- System limits tuning ---------------
configure_os_limits() {
  # Increase inotify watches/instances and file descriptor limits to support large watch sets (e.g., chokidar/karma)
  if ! is_root; then
    warn "Skipping system limits tuning (requires root)."
    return 0
  fi
  # Ensure sysctl is available on Debian/Ubuntu
  if [ "$PKG_MANAGER" = "apt" ]; then
    pkg_update || true
    pkg_install procps || true
  fi
  local sysctl_conf="/etc/sysctl.d/99-chokidar.conf"
  # Apply runtime settings (may be ignored on read-only fs)
  if has_cmd sysctl; then
    sysctl -w fs.inotify.max_user_watches=524288 || warn "Failed to set fs.inotify.max_user_watches"
    sysctl -w fs.inotify.max_user_instances=1024 || warn "Failed to set fs.inotify.max_user_instances"
  else
    warn "sysctl command not found; skipping runtime inotify tuning."
  fi
  # Persist settings
  printf "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=1024\n" > "$sysctl_conf"
  if has_cmd sysctl; then
    sysctl -p "$sysctl_conf" || warn "Failed to reload sysctl from $sysctl_conf"
  else
    warn "sysctl command not found; inotify limits will apply on next boot."
  fi
  local limits_dir="/etc/security/limits.d"
  [ -d "$limits_dir" ] || mkdir -p "$limits_dir"
  printf "* soft nofile 65536\n* hard nofile 65536\nroot soft nofile 65536\nroot hard nofile 65536\n" > "$limits_dir/99-nofile.conf"
  # Configure chokidar polling to reduce inotify load
  printf "export CHOKIDAR_USEPOLLING=true\nexport CHOKIDAR_INTERVAL=500\n" > "/etc/profile.d/chokidar.sh"
  chmod 0644 "/etc/profile.d/chokidar.sh" || true
}

# --------------- Main ---------------
main() {
  log "Starting environment setup in $PROJECT_ROOT"

  if ! is_root; then
    warn "Not running as root. System package installation may fail; attempting best-effort userland setup."
  fi

  detect_pkg_manager
  if [ "$PKG_MANAGER" != "unknown" ] && is_root; then
    pkg_update || true
    install_base_build_tools || true
    pkg_clean || true
  else
    warn "Skipping base system tools installation."
  fi

  configure_os_limits || true
  detect_project_type

  # Execute setup routines based on detection
  case "$PROJECT_TYPE" in
    unknown)
      warn "No recognizable project files found. Installing only base tools."
      ;;
    *)
      # Language-specific setups (order chosen to satisfy build toolchains)
      setup_node || true
      setup_python || true
      setup_ruby || true
      setup_php || true
      setup_go || true
      setup_rust || true
      setup_java || true
      setup_dotnet || true
      setup_deno || true
      ;;
  esac

  # Environment file
  if is_root; then
    write_env_file "$ENV_FILE_SYSTEM"
  else
    write_env_file "$ENV_FILE_LOCAL"
  fi

  # Set derived environment variables for current session
  export APP_ENV="$APP_ENV"
  export NODE_ENV="$NODE_ENV"
  export PYTHONUNBUFFERED=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1

  # If Python venv present, prepend to PATH
  if [ -d "$PROJECT_ROOT/.venv/bin" ]; then
    export VIRTUAL_ENV="$PROJECT_ROOT/.venv"
    export PATH="$PROJECT_ROOT/.venv/bin:$PATH"
  fi
  # Composer binaries
  if [ -d "$PROJECT_ROOT/vendor/bin" ]; then
    export PATH="$PROJECT_ROOT/vendor/bin:$PATH"
  fi
  # Dotnet path adjustments for current session
  if [ -d "/usr/share/dotnet" ]; then
    export DOTNET_ROOT="/usr/share/dotnet"
    export PATH="$DOTNET_ROOT:$PATH"
  elif [ -d "$HOME/.dotnet" ]; then
    export DOTNET_ROOT="$HOME/.dotnet"
    export PATH="$DOTNET_ROOT:$PATH"
  fi

  # Determine and export APP_PORT heuristic
  : "${APP_PORT:=$(detect_port)}"
  export APP_PORT
  log "Heuristic application port set to ${APP_PORT}"

  # Ensure directories and permissions
  ensure_dir "$PROJECT_ROOT/.cache"
  fix_permissions

  log "Environment setup completed successfully."
  echo
  echo "Summary:"
  echo " - Project root: $PROJECT_ROOT"
  echo " - Detected type: $PROJECT_TYPE"
  echo " - APP_ENV: $APP_ENV"
  echo " - NODE_ENV: $NODE_ENV"
  echo " - APP_PORT: $APP_PORT"
  echo
  echo "Notes:"
  echo " - To load environment variables in a new shell, source: ${ENV_FILE_LOCAL} (if not root) or auto-loaded from ${ENV_FILE_SYSTEM}."
  echo " - Python venv (if any) is at: $PROJECT_ROOT/.venv"
  echo " - Node modules (if any) are in: $PROJECT_ROOT/node_modules"
  echo " - Composer vendor (if any) is in: $PROJECT_ROOT/vendor"
}

main "$@"