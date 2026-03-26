#!/usr/bin/env bash
#
# Universal project environment setup script for Docker containers
# - Auto-detects common project types (Node.js, Python, Go, Java, PHP, Ruby, Rust, .NET)
# - Installs required runtimes and system dependencies
# - Configures environment variables and paths
# - Idempotent and safe to re-run
# - Designed for root execution inside containers (no sudo required)
#

set -Eeuo pipefail
IFS=$' \t\n'
umask 022

#------------------------------
# Logging and error handling
#------------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}"; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

trap 'rc=$?; error "Command failed at line $LINENO with exit code $rc"; exit $rc' ERR

#------------------------------
# Configuration
#------------------------------
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
APP_ROOT="$PROJECT_ROOT"
APP_ENV_DEFAULT="${APP_ENV:-production}"

# Default ports by stack (used only if not provided)
DEFAULT_PORT_GLOBAL=8080
DEFAULT_PORT_NODE=3000
DEFAULT_PORT_PYTHON=8000   # Django/uvicorn default; Flask commonly 5000
DEFAULT_PORT_RUBY=3000
DEFAULT_PORT_PHP=8000
DEFAULT_PORT_GO=8080
DEFAULT_PORT_JAVA=8080
DEFAULT_PORT_RUST=8000
DEFAULT_PORT_DOTNET=8080

#------------------------------
# OS / Package manager detection
#------------------------------
OS_ID=""
OS_like=""
PKG_MANAGER=""
APT_UPDATED_STAMP="/var/lib/.project_setup_apt_updated"

detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_like="${ID_LIKE:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  else
    PKG_MANAGER=""
  fi
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      if [[ ! -f "$APT_UPDATED_STAMP" ]]; then
        log "Updating apt package index..."
        apt-get update -y
        touch "$APT_UPDATED_STAMP" || true
      else
        log "apt package index already updated (stamp present)."
      fi
      ;;
    apk)
      log "Updating apk package index..."
      apk update || true
      ;;
    dnf)
      log "Updating dnf metadata..."
      dnf makecache -y || true
      ;;
    yum)
      log "Updating yum metadata..."
      yum makecache -y || true
      ;;
    zypper)
      log "Refreshing zypper repositories..."
      zypper --non-interactive refresh || true
      ;;
    *)
      warn "No supported package manager detected. Skipping system package updates."
      ;;
  esac
}

pkg_install() {
  # Install packages, ignoring those not found on the platform
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0

  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends "${pkgs[@]}" 2>/tmp/apt.err || {
        warn "Some apt packages failed to install, attempting to continue. See /tmp/apt.err"
      }
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}" 2>/tmp/apk.err || {
        warn "Some apk packages failed to install, attempting to continue. See /tmp/apk.err"
      }
      ;;
    dnf)
      dnf install -y "${pkgs[@]}" 2>/tmp/dnf.err || {
        warn "Some dnf packages failed to install, attempting to continue. See /tmp/dnf.err"
      }
      ;;
    yum)
      yum install -y "${pkgs[@]}" 2>/tmp/yum.err || {
        warn "Some yum packages failed to install, attempting to continue. See /tmp/yum.err"
      }
      ;;
    zypper)
      zypper --non-interactive install -y "${pkgs[@]}" 2>/tmp/zypper.err || {
        warn "Some zypper packages failed to install, attempting to continue. See /tmp/zypper.err"
      }
      ;;
    *)
      warn "No supported package manager detected. Cannot install: ${pkgs[*]}"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MANAGER" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      # apk caches in /var/cache/apk
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|yum)
      rm -rf /var/cache/dnf/* /var/cache/yum/* || true
      ;;
    zypper)
      zypper clean -a || true
      ;;
  esac
}

#------------------------------
# Utility helpers
#------------------------------
ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This script must run as root inside the container."
  fi
}

ensure_dir() {
  local d="$1"
  mkdir -p "$d"
  chmod 755 "$d"
}

append_profile_env() {
  local line="$1"
  local profile="/etc/profile.d/project-env.sh"
  grep -qxF "$line" "$profile" 2>/dev/null || echo "$line" >> "$profile"
}

path_prepend_once() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  local profile="/etc/profile.d/project-env.sh"
  if ! grep -q "PATH=.*$dir" "$profile" 2>/dev/null; then
    echo "export PATH=\"$dir:\$PATH\"" >> "$profile"
  fi
}

file_exists() { [[ -f "$1" ]]; }
any_file_exists() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] && return 0
  done
  return 1
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

#------------------------------
# Project type detection
#------------------------------
detect_project_types() {
  IS_NODE=0; IS_PY=0; IS_RUBY=0; IS_GO=0; IS_JAVA=0; IS_PHP=0; IS_RUST=0; IS_DOTNET=0

  [[ -f "$APP_ROOT/package.json" ]] && IS_NODE=1
  any_file_exists "$APP_ROOT/requirements.txt" "$APP_ROOT/pyproject.toml" "$APP_ROOT/Pipfile" && IS_PY=1
  [[ -f "$APP_ROOT/Gemfile" ]] && IS_RUBY=1
  [[ -f "$APP_ROOT/go.mod" ]] && IS_GO=1
  any_file_exists "$APP_ROOT/pom.xml" "$APP_ROOT/build.gradle" "$APP_ROOT/build.gradle.kts" "$APP_ROOT/gradlew" && IS_JAVA=1
  [[ -f "$APP_ROOT/composer.json" ]] && IS_PHP=1
  [[ -f "$APP_ROOT/Cargo.toml" ]] && IS_RUST=1
  ls "$APP_ROOT"/*.sln "$APP_ROOT"/*.csproj >/dev/null 2>&1 && IS_DOTNET=1

  log "Detected project types: Node=$IS_NODE Python=$IS_PY Ruby=$IS_RUBY Go=$IS_GO Java=$IS_JAVA PHP=$IS_PHP Rust=$IS_RUST .NET=$IS_DOTNET"
}

#------------------------------
# Base system setup
#------------------------------
install_base_system_tools() {
  log "Installing base system tools and compilers..."
  pkg_update

  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git unzip tar xz-utils gzip bzip2 gnupg
      pkg_install build-essential pkg-config
      # Common dev headers often needed by Python/Ruby gems
      pkg_install libssl-dev libffi-dev libxml2-dev libxslt1-dev zlib1g-dev libpq-dev
      ;;
    apk)
      pkg_install ca-certificates curl git unzip tar xz gzip bzip2 gnupg
      pkg_install build-base pkgconfig
      pkg_install openssl-dev libffi-dev libxml2-dev libxslt-dev zlib-dev libpq-dev
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git unzip tar xz gzip bzip2 gnupg2 which
      pkg_install gcc gcc-c++ make pkgconfig
      pkg_install openssl-devel libffi-devel libxml2-devel libxslt-devel zlib-devel libpq-devel
      ;;
    zypper)
      pkg_install ca-certificates curl git unzip tar xz gzip bzip2 gpg2 which
      pkg_install gcc gcc-c++ make pkg-config
      pkg_install libopenssl-devel libffi-devel libxml2-devel libxslt-devel zlib-devel libpq-devel
      ;;
    *)
      warn "Skipping base package installation due to unknown package manager. Ensure curl, git, compilers exist."
      ;;
  esac

  # Ensure CA certificates are up to date (for HTTPS downloads)
  update-ca-certificates >/dev/null 2>&1 || true
}

#------------------------------
# Language/runtime setup
#------------------------------
setup_node() {
  [[ $IS_NODE -eq 1 ]] || return 0
  log "Setting up Node.js environment..."

  if ! command_exists node || ! command_exists npm; then
    case "$PKG_MANAGER" in
      apt) pkg_install nodejs npm ;;
      apk) pkg_install nodejs npm ;;
      dnf|yum) pkg_install nodejs npm ;;
      zypper) pkg_install nodejs npm10 npm14 npm16 >/dev/null 2>&1 || pkg_install nodejs npm ;;
      *) warn "No package manager available to install Node.js. Please ensure Node.js and npm are present."; ;;
    esac
  fi

  if command_exists corepack; then
    corepack enable || true
  fi

  pushd "$APP_ROOT" >/dev/null

  local pm="npm"
  if [[ -f yarn.lock ]]; then
    if command_exists yarn; then pm="yarn"
    elif command_exists corepack; then corepack prepare yarn@stable --activate || true; pm="yarn"
    else npm install -g yarn >/dev/null 2>&1 || true; command_exists yarn && pm="yarn"
    fi
  elif [[ -f pnpm-lock.yaml ]]; then
    if command_exists pnpm; then pm="pnpm"
    elif command_exists corepack; then corepack prepare pnpm@latest --activate || true; command_exists pnpm && pm="pnpm"
    else npm install -g pnpm >/dev/null 2>&1 || true; command_exists pnpm && pm="pnpm"
    fi
  elif [[ -f package-lock.json ]] && command_exists npm; then
    pm="npm"
  fi

  export NODE_ENV="${NODE_ENV:-$APP_ENV_DEFAULT}"

  case "$pm" in
    yarn)
      if [[ -f yarn.lock ]]; then
        yarn install --frozen-lockfile --non-interactive || yarn install --non-interactive
      else
        yarn install --non-interactive
      fi
      ;;
    pnpm)
      pnpm install --frozen-lockfile || pnpm install
      ;;
    npm|*)
      if [[ -f package-lock.json ]]; then
        npm ci || npm install
      else
        npm install
      fi
      ;;
  esac

  # Make local node binaries available
  path_prepend_once "$APP_ROOT/node_modules/.bin"

  popd >/dev/null
}

setup_python() {
  [[ $IS_PY -eq 1 ]] || return 0
  log "Setting up Python environment..."

  case "$PKG_MANAGER" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel
      ;;
    *)
      warn "Cannot install Python via system packages; assuming python3 and pip are available."
      ;;
  esac

  command_exists python3 || die "python3 is required for Python projects."
  command_exists pip3 || die "pip3 is required for Python projects."

  # Allow pip to modify externally-managed system Python environments (PEP 668)
  python3 -m pip config set global.break-system-packages true || true

  pushd "$APP_ROOT" >/dev/null

  local VENV_DIR="$APP_ROOT/.venv"
  if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"

  pip install --upgrade pip setuptools wheel

  if [[ -f requirements.txt ]]; then
    pip install -r requirements.txt
  elif [[ -f pyproject.toml ]]; then
    # Try PEP 517 build first; if poetry is used, install via poetry
    if grep -qi '\[tool.poetry\]' pyproject.toml 2>/dev/null || [[ -f poetry.lock ]]; then
      pip install "poetry>=1.5,<2" || true
      if command_exists poetry; then
        poetry config virtualenvs.create false
        poetry install --no-interaction --no-ansi --without dev || poetry install --no-interaction --no-ansi
      else
        pip install .
      fi
    else
      pip install .
    fi
  elif [[ -f Pipfile ]]; then
    pip install pipenv || true
    if command_exists pipenv; then
      PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
    fi
  fi

  # Expose venv bin on PATH for future shells
  path_prepend_once "$VENV_DIR/bin"

  # Common env defaults
  export PYTHONUNBUFFERED=1
  append_profile_env "export PYTHONUNBUFFERED=1"

  deactivate || true
  popd >/dev/null
}

setup_ruby() {
  [[ $IS_RUBY -eq 1 ]] || return 0
  log "Setting up Ruby environment..."

  case "$PKG_MANAGER" in
    apt) pkg_install ruby-full ruby-dev make gcc ;;
    apk) pkg_install ruby ruby-dev ruby-bundler build-base ;;
    dnf|yum) pkg_install ruby ruby-devel make gcc ;;
    zypper) pkg_install ruby ruby-devel make gcc ;;
    *) warn "Cannot install Ruby via system packages; proceeding assuming Ruby is present." ;;
  esac

  command_exists ruby || die "Ruby is required for Ruby projects."

  pushd "$APP_ROOT" >/dev/null

  if ! command_exists bundle; then
    gem install --no-document bundler || true
  fi

  if [[ -f Gemfile ]]; then
    bundle config set --local path 'vendor/bundle'
    bundle config set --local without 'development test' || true
    bundle install --jobs "$(nproc)" || bundle install
    path_prepend_once "$APP_ROOT/vendor/bundle/bin"
  fi

  popd >/dev/null
}

setup_go() {
  [[ $IS_GO -eq 1 ]] || return 0
  log "Setting up Go environment..."

  case "$PKG_MANAGER" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go go1.21 >/dev/null 2>&1 || pkg_install go ;;
    *) warn "Cannot install Go via system packages; proceeding assuming Go is present." ;;
  esac

  command_exists go || die "Go is required for Go projects."

  pushd "$APP_ROOT" >/dev/null
  if [[ -f go.mod ]]; then
    go env -w GOMODCACHE="${GOMODCACHE:-/go/pkg/mod}" || true
    go mod download
  fi
  # Add GOPATH/bin if exists
  if [[ -d /root/go/bin ]]; then path_prepend_once "/root/go/bin"; fi
  popd >/dev/null
}

setup_java() {
  [[ $IS_JAVA -eq 1 ]] || return 0
  log "Setting up Java environment..."

  case "$PKG_MANAGER" in
    apt) pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17-jdk maven ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven ;;
    zypper) pkg_install java-17-openjdk-devel maven ;;
    *) warn "Cannot install Java via system packages; proceeding assuming JDK is present." ;;
  esac

  if ! command_exists javac; then
    warn "JDK not found; attempting JRE... Some builds may fail."
    case "$PKG_MANAGER" in
      apt) pkg_install openjdk-17-jre ;;
      apk) pkg_install openjdk17-jre ;;
      dnf|yum) pkg_install java-17-openjdk ;;
      zypper) pkg_install java-17-openjdk ;;
    esac
  fi

  pushd "$APP_ROOT" >/dev/null

  if [[ -f mvnw ]]; then
    chmod +x mvnw
    ./mvnw -B -DskipTests dependency:resolve dependency:resolve-plugins || true
  elif [[ -f pom.xml ]]; then
    command_exists mvn && mvn -B -DskipTests dependency:resolve dependency:resolve-plugins || true
  fi

  if [[ -f gradlew ]]; then
    chmod +x gradlew
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
  elif any_file_exists build.gradle build.gradle.kts; then
    if ! command_exists gradle; then
      case "$PKG_MANAGER" in
        apt|dnf|yum|zypper) pkg_install gradle || true ;;
        apk) warn "Gradle package may not be available on Alpine repositories." ;;
      esac
    fi
    command_exists gradle && gradle --no-daemon tasks >/dev/null 2>&1 || true
  fi

  popd >/dev/null
}

setup_php() {
  [[ $IS_PHP -eq 1 ]] || return 0
  log "Setting up PHP environment..."

  case "$PKG_MANAGER" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip php-intl php-bcmath php-gd
      pkg_install composer || true
      ;;
    apk)
      pkg_install php php-cli php-phar php-mbstring php-xml php-curl php-zip php-intl php-gd
      ;;
    dnf|yum)
      pkg_install php-cli php-mbstring php-xml php-json php-zip php-intl php-gd php-curl
      ;;
    zypper)
      pkg_install php8 php8-mbstring php8-xml php8-zip php8-intl php8-gd php8-curl
      ;;
    *)
      warn "Cannot install PHP via system packages; proceeding assuming PHP is present."
      ;;
  esac

  command_exists php || die "PHP is required for PHP projects."

  if ! command_exists composer; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Composer install failed"
    rm -f /tmp/composer-setup.php
  fi

  pushd "$APP_ROOT" >/dev/null
  if [[ -f composer.json ]]; then
    composer install --no-interaction --prefer-dist --optimize-autoloader || composer install --no-interaction
    path_prepend_once "$APP_ROOT/vendor/bin"
  fi
  popd >/dev/null
}

setup_rust() {
  [[ $IS_RUST -eq 1 ]] || return 0
  log "Setting up Rust environment..."

  if ! command_exists cargo; then
    pkg_update
    pkg_install curl ca-certificates
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
    chmod +x /tmp/rustup-init.sh
    /tmp/rustup-init.sh -y --no-modify-path --default-toolchain stable --profile minimal
    rm -f /tmp/rustup-init.sh
    append_profile_env 'export PATH="/root/.cargo/bin:$PATH"'
    export PATH="/root/.cargo/bin:$PATH"
  fi

  command_exists cargo || die "Rust toolchain installation failed."

  pushd "$APP_ROOT" >/dev/null
  if [[ -f Cargo.toml ]]; then
    cargo fetch || true
  fi
  popd >/dev/null
}

setup_dotnet() {
  [[ $IS_DOTNET -eq 1 ]] || return 0
  log "Setting up .NET SDK runtime..."

  DOTNET_ROOT="/usr/local/dotnet"
  if ! command_exists dotnet; then
    pkg_update
    pkg_install curl ca-certificates
    ensure_dir "$DOTNET_ROOT"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir "$DOTNET_ROOT" --channel LTS || /tmp/dotnet-install.sh --install-dir "$DOTNET_ROOT" --channel STS || true
    rm -f /tmp/dotnet-install.sh
    append_profile_env "export DOTNET_ROOT=\"$DOTNET_ROOT\""
    append_profile_env 'export PATH="$DOTNET_ROOT:$PATH"'
    export DOTNET_ROOT="$DOTNET_ROOT"
    export PATH="$DOTNET_ROOT:$PATH"
  fi

  command_exists dotnet || die ".NET SDK installation failed."

  pushd "$APP_ROOT" >/dev/null
  # Restore for solutions or projects found
  if ls *.sln >/dev/null 2>&1; then
    for sln in *.sln; do dotnet restore "$sln" || true; done
  elif ls *.csproj >/dev/null 2>&1; then
    for csproj in *.csproj; do dotnet restore "$csproj" || true; done
  else
    dotnet restore || true
  fi
  popd >/dev/null
}

#------------------------------
# Compatibility shims
#------------------------------
ensure_scapy_py_wrapper() {
  # Provide scapy.py shim without shadowing the scapy package.
  local bad="/usr/local/bin/scapy.py"
  local target="/usr/bin/scapy.py"

  # Remove problematic wrapper if present
  if [[ -e "$bad" ]]; then
    rm -f "$bad" || true
  fi

  # Install correct wrapper that invokes python3 -m scapy
  if command_exists python3; then
    printf '%s\n' '#!/usr/bin/env sh' 'exec python3 -m scapy "$@"' > "$target"
    chmod +x "$target" || true
  fi
}

#------------------------------
# Environment configuration
#------------------------------
configure_environment() {
  log "Configuring environment variables and paths..."
  local profile="/etc/profile.d/project-env.sh"

  ensure_dir "$APP_ROOT"
  touch "$profile"
  chmod 644 "$profile"

  # Locale and app basics
  append_profile_env 'export LANG=C.UTF-8'
  append_profile_env 'export LC_ALL=C.UTF-8'
  append_profile_env "export APP_ROOT=\"$APP_ROOT\""
  append_profile_env "export APP_ENV=\"${APP_ENV_DEFAULT}\""
  append_profile_env 'export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"'

  # Language-specific path hints (added earlier where applicable)
  # Keep existing PATH lines idempotently

  # Determine a sensible default port
  local port="${PORT:-}"
  if [[ -z "$port" ]]; then
    if [[ $IS_NODE -eq 1 ]]; then
      port=$DEFAULT_PORT_NODE
    elif [[ $IS_PY -eq 1 ]]; then
      # If Flask hint exists, prefer 5000
      if grep -Ril "Flask" "$APP_ROOT" >/dev/null 2>&1; then
        port=5000
      else
        port=$DEFAULT_PORT_PYTHON
      fi
    elif [[ $IS_RUBY -eq 1 ]]; then
      port=$DEFAULT_PORT_RUBY
    elif [[ $IS_PHP -eq 1 ]]; then
      port=$DEFAULT_PORT_PHP
    elif [[ $IS_GO -eq 1 ]]; then
      port=$DEFAULT_PORT_GO
    elif [[ $IS_JAVA -eq 1 ]]; then
      port=$DEFAULT_PORT_JAVA
    elif [[ $IS_RUST -eq 1 ]]; then
      port=$DEFAULT_PORT_RUST
    elif [[ $IS_DOTNET -eq 1 ]]; then
      port=$DEFAULT_PORT_DOTNET
    else
      port=$DEFAULT_PORT_GLOBAL
    fi
  fi

  append_profile_env "export PORT=\"$port\""

  # Create a .env template if none exists
  if [[ ! -f "$APP_ROOT/.env" ]]; then
    cat > "$APP_ROOT/.env" <<EOF
# Auto-generated environment file
APP_ENV=${APP_ENV_DEFAULT}
PORT=${port}
# Add additional environment variables below:
EOF
    chmod 640 "$APP_ROOT/.env" || true
  fi
}

#------------------------------
# Permissions
#------------------------------
set_permissions() {
  log "Setting directory permissions..."
  ensure_dir "$APP_ROOT"
  chown -R root:root "$APP_ROOT" || true
  find "$APP_ROOT" -type d -exec chmod 755 {} \; || true
  # Common writable dirs if present
  for d in log logs tmp storage .cache; do
    if [[ -d "$APP_ROOT/$d" ]]; then
      chmod -R 777 "$APP_ROOT/$d" || true
    fi
  done
}

#------------------------------
# Main
#------------------------------
main() {
  ensure_root
  detect_os
  log "Using package manager: ${PKG_MANAGER:-none}"

  install_base_system_tools

  detect_project_types

  setup_node
  setup_python
  setup_ruby
  setup_go
  setup_java
  setup_php
  setup_rust
  setup_dotnet

  ensure_scapy_py_wrapper

  configure_environment
  set_permissions

  pkg_cleanup

  log "Environment setup completed successfully."
  echo
  echo "Usage notes:"
  echo "- Project root: $APP_ROOT"
  echo "- Environment profile: /etc/profile.d/project-env.sh (auto-sourced for login shells)"
  echo "- .env file created (if missing) at: $APP_ROOT/.env"
  echo "- To load environment in current shell: source /etc/profile.d/project-env.sh"
  echo
  echo "Detected stacks:"
  echo "  Node.js: $IS_NODE, Python: $IS_PY, Ruby: $IS_RUBY, Go: $IS_GO, Java: $IS_JAVA, PHP: $IS_PHP, Rust: $IS_RUST, .NET: $IS_DOTNET"
  echo
  echo "This script is idempotent and safe to re-run."
}

main "$@"