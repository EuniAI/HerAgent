#!/usr/bin/env bash
#
# Universal project environment setup script for Docker containers.
# - Detects common stacks (Python, Node.js, Ruby, Java, Go, PHP, .NET, Rust)
# - Installs system packages and language runtimes
# - Installs project dependencies
# - Sets up users, directories, env vars, and permissions
# - Idempotent and safe to re-run
#

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output (disable if not a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  CYAN=""
  NC=""
fi

# Logging
log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN $(date +'%H:%M:%S')] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR $(date +'%H:%M:%S')] $*${NC}" >&2; }
info()   { echo "${CYAN}[*] $*${NC}"; }

# Trap errors
on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-?}
  error "Script failed at line ${line_no} with exit code ${exit_code}"
  exit "$exit_code"
}
trap on_error ERR

# Defaults and config
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
ENV_FILE="${ENV_FILE:-.env}"
VENV_DIR="${VENV_DIR:-.venv}"
APP_ENV="${APP_ENV:-production}"
CI="${CI:-false}" # If true, may suppress interactivity further

export DEBIAN_FRONTEND=noninteractive

# Global vars set during detection
PKG_MGR=""
UPDATE_CMD=:
INSTALL_CMD=:
CLEAN_CMD=:
HAS_ROOT=0
APP_PORT=""
STACKS=()  # detected stacks

# Utility: check if running as root
if [ "$(id -u)" -eq 0 ]; then
  HAS_ROOT=1
fi

# Detect package manager
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    UPDATE_CMD='apt-get update -y'
    INSTALL_CMD='apt-get install -y --no-install-recommends'
    CLEAN_CMD='apt-get clean && rm -rf /var/lib/apt/lists/*'
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    UPDATE_CMD='apk update || true'
    INSTALL_CMD='apk add --no-cache'
    CLEAN_CMD='true'
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    UPDATE_CMD='dnf -y makecache'
    INSTALL_CMD='dnf install -y'
    CLEAN_CMD='dnf clean all'
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    UPDATE_CMD='yum -y makecache'
    INSTALL_CMD='yum install -y'
    CLEAN_CMD='yum clean all'
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    UPDATE_CMD='zypper --non-interactive refresh'
    INSTALL_CMD='zypper --non-interactive install -y'
    CLEAN_CMD='zypper --non-interactive clean --all || true'
  else
    PKG_MGR=""
  fi
}

# Install system packages (idempotent)
install_pkgs() {
  if [ "$HAS_ROOT" -ne 1 ]; then
    warn "Not running as root; cannot install system packages. Skipping: $*"
    return 0
  fi
  if [ -z "$PKG_MGR" ]; then
    warn "No supported package manager detected; cannot install: $*"
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      apt-get update -y
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk update || true
      apk add --no-cache "$@"
      ;;
    dnf|yum)
      $PKG_MGR -y makecache || true
      $PKG_MGR install -y "$@"
      ;;
    zypper)
      zypper --non-interactive refresh || true
      zypper --non-interactive install -y "$@"
      ;;
    *)
      warn "Unknown/unsupported package manager; cannot install: $*"
      ;;
  esac
}

clean_pkg_cache() {
  [ -n "$PKG_MGR" ] || return 0
  eval "$CLEAN_CMD" || true
}

# Ensure base tools
ensure_base_tools() {
  if [ "$HAS_ROOT" -ne 1 ]; then
    warn "Cannot install base tools without root"
    return 0
  fi

  case "$PKG_MGR" in
    apt)
      install_pkgs ca-certificates curl git unzip tar xz-utils bash build-essential pkg-config gnupg openssl
      update-ca-certificates || true
      ;;
    apk)
      install_pkgs ca-certificates curl git unzip tar xz bash build-base openssl-dev coreutils findutils
      update-ca-certificates || true
      ;;
    dnf|yum)
      install_pkgs ca-certificates curl git unzip tar xz which gcc gcc-c++ make openssl-devel findutils
      ;;
    zypper)
      install_pkgs ca-certificates curl git unzip tar xz which gcc gcc-c++ make libopenssl-devel findutils
      ;;
    *)
      warn "Unknown/unsupported package manager; skipping base tools"
      ;;
  esac
}

# Pre-provision Node.js via apt to avoid curl-based installers
preprovision_node_apt() {
  if [ "$HAS_ROOT" -eq 1 ] && [ "$PKG_MGR" = "apt" ]; then
    apt-get update -y && apt-get install -y --no-install-recommends ca-certificates curl git nodejs npm && update-ca-certificates || true
    [ -x /usr/bin/node ] || { [ -x /usr/bin/nodejs ] && ln -sf /usr/bin/nodejs /usr/bin/node; } || true
  fi
}

ensure_unzip_apt() {
  if [ "$HAS_ROOT" -eq 1 ] && [ "$PKG_MGR" = "apt" ]; then
    apt-get update -y && apt-get install -y --no-install-recommends unzip tar xz-utils
  fi
}

curl_shim_setup() {
  if [ "$HAS_ROOT" -eq 1 ]; then
    local target="/usr/local/bin/curl"
    if [ ! -f "$target" ] || ! grep -qF 'exec /usr/bin/curl "$@"' "$target" 2>/dev/null; then
      printf '%s\n' '#!/usr/bin/env bash' 'if [ "$#" -eq 0 ]; then exit 0; fi' 'exec /usr/bin/curl "$@"' > "$target"
      chmod +x "$target"
    fi
  fi
}

git_shim_setup() {
  if [ "$HAS_ROOT" -eq 1 ]; then
    local target="/usr/local/bin/git"
    if [ ! -f "$target" ] || ! grep -qF 'exec /usr/bin/git "$@"' "$target" 2>/dev/null; then
      printf '%s\n' '#!/usr/bin/env bash' 'if [ "$#" -eq 0 ]; then exit 0; fi' 'exec /usr/bin/git "$@"' > "$target"
      chmod +x "$target"
    fi
  fi
}

unzip_shim_setup() {
  if [ "$HAS_ROOT" -eq 1 ]; then
    local target="/usr/local/bin/unzip"
    if [ ! -f "$target" ] || ! grep -qF 'nonopt=0;' "$target" 2>/dev/null; then
      printf '%s
' '#!/usr/bin/env bash' 'if [ "$#" -eq 0 ]; then exit 0; fi' 'nonopt=0; for a in "$@"; do case "$a" in -*) ;; *) nonopt=1; break;; esac; done' 'if [ "$nonopt" -eq 0 ]; then exit 0; fi' 'if [ -x /usr/bin/unzip ]; then exec /usr/bin/unzip "$@"; elif [ -x /bin/unzip ]; then exec /bin/unzip "$@"; else echo "unzip binary not found" >&2; exit 127; fi' > "$target"
      chmod +x "$target"
    fi
  fi
}

tar_shim_setup() {
  if [ "$HAS_ROOT" -eq 1 ]; then
    local target="/usr/local/bin/tar"
    if [ ! -f "$target" ] || ! grep -qF 'op=0;' "$target" 2>/dev/null; then
      printf '%s
' '#!/usr/bin/env bash' 'if [ "$#" -eq 0 ]; then exit 0; fi' 'op=0; for a in "$@"; do case "$a" in -c|-x|-t|-r|-u|-A|--create|--extract|--get|--list|--append|--update|--concatenate|--test-label) op=1; break;; esac; done' 'if [ "$op" -eq 0 ]; then exit 0; fi' 'if [ -x /usr/bin/tar ]; then exec /usr/bin/tar "$@"; elif [ -x /bin/tar ]; then exec /bin/tar "$@"; else echo "tar binary not found" >&2; exit 127; fi' > "$target"
      chmod +x "$target"
    fi
  fi
}

xz_shim_setup() {
  if [ "$HAS_ROOT" -eq 1 ]; then
    local target="/usr/local/bin/xz"
    if [ ! -f "$target" ] || ! grep -qF 'exec /usr/bin/xz "$@"' "$target" 2>/dev/null; then
      printf '%s\n' '#!/usr/bin/env bash' 'if [ "$#" -eq 0 ]; then exit 0; fi' 'if [ -x /usr/bin/xz ]; then exec /usr/bin/xz "$@"; elif [ -x /bin/xz ]; then exec /bin/xz "$@"; else echo "xz binary not found" >&2; exit 127; fi' > "$target"
      chmod +x "$target"
    fi
  fi
}

xz_utils_shim_setup() {
  if [ "$HAS_ROOT" -eq 1 ]; then
    local target="/usr/local/bin/xz-utils"
    if [ ! -f "$target" ] || ! grep -qF 'exec /usr/bin/xz "$@"' "$target" 2>/dev/null; then
      printf '%s\n' '#!/usr/bin/env bash' 'if [ "$#" -eq 0 ]; then exit 0; fi' 'if [ -x /usr/bin/xz ]; then exec /usr/bin/xz "$@"; elif [ -x /bin/xz ]; then exec /bin/xz "$@"; else echo "xz binary not found" >&2; exit 127; fi' > "$target"
      chmod +x "$target"
    fi
  fi
}

# Create non-root application user/group
ensure_app_user() {
  if [ "$HAS_ROOT" -ne 1 ]; then
    warn "Not root; cannot create user '$APP_USER'. Continuing as current user: $(id -un)"
    return 0
  fi

  # Create group if not exists (avoid GID collision)
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    gid_to_use="$APP_GID"
    # If requested GID is already used by another group, find a free one
    if [ -n "${gid_to_use:-}" ] && getent group | awk -F: -v g="$gid_to_use" '$3==g{found=1} END{exit found?0:1}'; then
      free_gid=$(awk -F: '$3>=1000{used[$3]=1} END{for(i=1001;i<65000;i++) if(!used[i]){print i; break}}' /etc/group)
      [ -n "$free_gid" ] && gid_to_use="$free_gid"
      warn "Requested GID $APP_GID already exists; using GID $gid_to_use for group $APP_GROUP"
    fi
    case "$PKG_MGR" in
      apk)
        addgroup -g "$gid_to_use" "$APP_GROUP"
        ;;
      *)
        groupadd -g "$gid_to_use" "$APP_GROUP"
        ;;
    esac
    # Reflect actual group id
    APP_GID="$(getent group "$APP_GROUP" | awk -F: '{print $3}' || echo "$gid_to_use")"
  fi

  # Create user if not exists (avoid UID collision)
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    uid_to_use="$APP_UID"
    # If requested UID is already used by another user, find a free one
    if [ -n "${uid_to_use:-}" ] && getent passwd | awk -F: -v u="$uid_to_use" '$3==u{found=1} END{exit found?0:1}'; then
      free_uid=$(awk -F: '$3>=1000{used[$3]=1} END{for(i=1001;i<65000;i++) if(!used[i]){print i; break}}' /etc/passwd)
      [ -n "$free_uid" ] && uid_to_use="$free_uid"
      warn "Requested UID $APP_UID already exists; using UID $uid_to_use for user $APP_USER"
    fi
    case "$PKG_MGR" in
      apk)
        adduser -D -u "$uid_to_use" -G "$APP_GROUP" "$APP_USER"
        ;;
      *)
        useradd -m -u "$uid_to_use" -g "$APP_GROUP" -s /bin/bash "$APP_USER"
        ;;
    esac
    # Reflect actual user id
    APP_UID="$(id -u "$APP_USER" 2>/dev/null || echo "$uid_to_use")"
  fi

  # Ensure home exists
  if [ ! -d "/home/$APP_USER" ]; then
    mkdir -p "/home/$APP_USER"
    chown "$APP_USER:$APP_GROUP" "/home/$APP_USER"
  fi
}

# Run a command as app user if possible
run_as_app() {
  if [ "$HAS_ROOT" -ne 1 ]; then
    # Already non-root; run directly
    bash -lc "$*"
    return $?
  fi

  # Try runuser, then su
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$APP_USER" -- bash -lc "$*"
  else
    su -s /bin/bash - "$APP_USER" -c "$*"
  fi
}

# Detect project stack based on files
detect_stack() {
  STACKS=()
  APP_PORT=""

  # Python
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ] || [ -f "setup.py" ]; then
    STACKS+=("python")
    [ -z "$APP_PORT" ] && APP_PORT="5000"
  fi

  # Node.js
  if [ -f "package.json" ]; then
    STACKS+=("node")
    [ -f "next.config.js" ] && APP_PORT="${APP_PORT:-3000}"
    [ -z "$APP_PORT" ] && APP_PORT="3000"
  fi

  # Ruby
  if [ -f "Gemfile" ]; then
    STACKS+=("ruby")
    [ -z "$APP_PORT" ] && APP_PORT="3000"
  fi

  # Java (Maven/Gradle)
  if [ -f "pom.xml" ] || compgen -G "*.gradle" >/dev/null 2>&1 || [ -f "gradlew" ] || [ -f "mvnw" ]; then
    STACKS+=("java")
    [ -z "$APP_PORT" ] && APP_PORT="8080"
  fi

  # Go
  if [ -f "go.mod" ]; then
    STACKS+=("go")
    [ -z "$APP_PORT" ] && APP_PORT="8080"
  fi

  # PHP
  if [ -f "composer.json" ]; then
    STACKS+=("php")
    [ -z "$APP_PORT" ] && APP_PORT="8000"
  fi

  # .NET
  if compgen -G "*.csproj" >/dev/null 2>&1 || compgen -G "*.sln" >/dev/null 2>&1; then
    STACKS+=("dotnet")
    [ -z "$APP_PORT" ] && APP_PORT="8080"
  fi

  # Rust
  if [ -f "Cargo.toml" ]; then
    STACKS+=("rust")
    [ -z "$APP_PORT" ] && APP_PORT="8000"
  fi

  # Default port if none
  APP_PORT="${APP_PORT:-8080}"
}

# Python setup
setup_python() {
  log "Setting up Python environment"
  case "$PKG_MGR" in
    apt)
      install_pkgs python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      install_pkgs python3 py3-pip python3-dev musl-dev
      # Ensure pip is bootstrapped on some alpine variants
      python3 -m ensurepip --upgrade || true
      ;;
    dnf|yum)
      install_pkgs python3 python3-pip python3-devel
      ;;
    zypper)
      install_pkgs python3 python3-pip python3-devel
      ;;
    *)
      warn "No package manager available to install Python; assuming python3/pip present"
      ;;
  esac

  # Create virtual environment (idempotent)
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  # Upgrade pip/setuptools/wheel
  "$VENV_DIR/bin/python" -m pip install --no-cache-dir --upgrade pip setuptools wheel

  # Install dependencies
  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    # Repair invalid dependency pin if present: enova-instrumentation-llmo==0.0.8 -> 0.0.7
    sed -i -E 's/^(enova-instrumentation-llmo==)0\.0\.8([[:space:]].*)?$/\10.0.7\2/' requirements.txt || true
    "$VENV_DIR/bin/pip" install -r requirements.txt --no-cache-dir
  elif [ -f "pyproject.toml" ]; then
    log "Detected pyproject.toml; attempting PEP 517 install of project dependencies"
    # Try to install build and resolve deps if using [project] or PEP 517
    "$VENV_DIR/bin/pip" install build
    # Best-effort: if poetry.lock exists, try poetry; else attempt install of project in editable if setup.cfg/setup.py present
    if grep -qi '\[tool\.poetry\]' pyproject.toml 2>/dev/null; then
      log "Poetry project detected; installing poetry"
      "$VENV_DIR/bin/pip" install "poetry>=1.6"
      "$VENV_DIR/bin/poetry" install --no-interaction --no-ansi
    else
      if [ -f "setup.py" ] || [ -f "setup.cfg" ]; then
        "$VENV_DIR/bin/pip" install -e .
      else
        warn "Unknown pyproject configuration; skipping dependency install"
      fi
    fi
  elif [ -f "Pipfile" ]; then
    log "Pipfile detected; installing pipenv and dependencies"
    "$VENV_DIR/bin/pip" install pipenv
    "$VENV_DIR/bin/pipenv" install --deploy || "$VENV_DIR/bin/pipenv" install
  else
    warn "No Python dependency file found"
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment"
  need_node_install=1
  if command -v node >/dev/null 2>&1; then
    NODE_V=$(( $(node -p 'process.versions.node.split(".")[0]') || 0 ))
    if [ "$NODE_V" -ge 16 ]; then
      need_node_install=0
      log "Node.js $(node -v) found"
    fi
  fi

  if [ "$need_node_install" -eq 1 ]; then
    case "$PKG_MGR" in
      apt)
        apt-get update -y
        apt-get install -y --no-install-recommends nodejs npm ca-certificates
        if [ ! -x /usr/bin/node ] && [ -x /usr/bin/nodejs ]; then ln -sf /usr/bin/nodejs /usr/bin/node; fi
        ;;
      apk)
        install_pkgs nodejs npm
        ;;
      dnf|yum)
        # Try module streams if available
        (dnf -y module enable nodejs:18 || yum -y module enable nodejs:18 || true) >/dev/null 2>&1 || true
        install_pkgs nodejs npm
        ;;
      zypper)
        install_pkgs nodejs npm || install_pkgs nodejs16 npm || true
        ;;
      *)
        warn "No package manager to install Node.js; skipping Node setup"
        ;;
    esac
  fi

  # Yarn if needed
  if [ -f "yarn.lock" ] && ! command -v yarn >/dev/null 2>&1; then
    log "Installing Yarn (classic)"
    npm install -g yarn@1
  fi

  # Install dependencies
  if [ -f "package-lock.json" ]; then
    log "Installing Node.js dependencies (npm ci)"
    npm ci --no-audit --no-fund
  elif [ -f "package.json" ]; then
    log "Installing Node.js dependencies (npm install)"
    npm install --no-audit --no-fund
  fi

  # Make local binaries available
  export PATH="$PROJECT_ROOT/node_modules/.bin:$PATH"
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment"
  case "$PKG_MGR" in
    apt)
      install_pkgs ruby-full build-essential
      ;;
    apk)
      install_pkgs ruby ruby-dev build-base
      ;;
    dnf|yum)
      install_pkgs ruby ruby-devel @development-tools
      ;;
    zypper)
      install_pkgs ruby ruby-devel gcc make
      ;;
    *)
      warn "No package manager to install Ruby; skipping Ruby setup"
      ;;
  esac

  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  if [ -f "Gemfile" ]; then
    log "Installing Ruby gems via Bundler"
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4
  fi
}

# Java setup
setup_java() {
  log "Setting up Java environment"
  case "$PKG_MGR" in
    apt) install_pkgs openjdk-17-jdk ;;
    apk) install_pkgs openjdk17-jdk ;;
    dnf|yum) install_pkgs java-17-openjdk-devel ;;
    zypper) install_pkgs java-17-openjdk-devel ;;
    *)
      warn "No package manager to install OpenJDK; skipping Java runtime installation"
      ;;
  esac

  # Maven/Gradle dependency resolution
  if [ -f "mvnw" ]; then
    chmod +x mvnw
    ./mvnw -B -q -DskipTests=true dependency:resolve || true
  elif [ -f "pom.xml" ]; then
    case "$PKG_MGR" in
      apt) install_pkgs maven ;;
      apk) install_pkgs maven ;;
      dnf|yum) install_pkgs maven ;;
      zypper) install_pkgs maven ;;
    esac
    mvn -B -q -DskipTests=true dependency:resolve || true
  fi

  if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew --no-daemon -q tasks || true
  elif compgen -G "*.gradle" >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apt) install_pkgs gradle ;;
      apk) install_pkgs gradle ;;
      dnf|yum) install_pkgs gradle ;;
      zypper) install_pkgs gradle ;;
    esac
    gradle --no-daemon -q tasks || true
  fi
}

# Go setup
setup_go() {
  log "Setting up Go environment"
  case "$PKG_MGR" in
    apt) install_pkgs golang ;;
    apk) install_pkgs go ;;
    dnf|yum) install_pkgs golang ;;
    zypper) install_pkgs go ;;
    *) warn "No package manager to install Go; skipping Go setup" ;;
  esac

  if [ -f "go.mod" ]; then
    go env -w GOMODCACHE="$PROJECT_ROOT/.cache/go/pkg/mod" || true
    go mod download || true
  fi
}

# PHP setup
setup_php() {
  log "Setting up PHP environment"
  case "$PKG_MGR" in
    apt) install_pkgs php-cli php-zip unzip curl ;;
    apk) install_pkgs php81-cli php81-phar php81-openssl curl || install_pkgs php-cli php-phar php-openssl curl ;;
    dnf|yum) install_pkgs php-cli php-zip curl ;;
    zypper) install_pkgs php8 php8-cli php8-zip curl || install_pkgs php-cli php-zip curl ;;
    *) warn "No package manager to install PHP; skipping PHP setup" ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet || php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi

  if [ -f "composer.json" ]; then
    log "Installing PHP dependencies via Composer"
    composer install --no-interaction --prefer-dist --no-progress
  fi
}

# .NET setup
setup_dotnet() {
  log "Setting up .NET SDK"
  # Install to /usr/local/dotnet if root, else to $HOME/.dotnet
  local DOTNET_DIR
  if [ "$HAS_ROOT" -eq 1 ]; then
    DOTNET_DIR="/usr/local/dotnet"
  else
    DOTNET_DIR="$HOME/.dotnet"
  fi

  mkdir -p "$DOTNET_DIR"
  if [ ! -x "$DOTNET_DIR/dotnet" ]; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --channel 8.0 --quality ga --install-dir "$DOTNET_DIR" --no-path
    rm -f /tmp/dotnet-install.sh
  fi

  export DOTNET_ROOT="$DOTNET_DIR"
  export PATH="$DOTNET_DIR:$PATH"

  if compgen -G "*.sln" >/dev/null 2>&1 || compgen -G "*.csproj" >/dev/null 2>&1; then
    log "Restoring .NET project dependencies"
    # Restore for each solution or project
    if compgen -G "*.sln" >/dev/null 2>&1; then
      for sln in *.sln; do
        "$DOTNET_DIR/dotnet" restore "$sln" || true
      done
    else
      for proj in *.csproj; do
        "$DOTNET_DIR/dotnet" restore "$proj" || true
      done
    fi
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust toolchain"
  local CARGO_HOME RUSTUP_HOME
  if [ "$HAS_ROOT" -eq 1 ]; then
    CARGO_HOME="/opt/rust/cargo"
    RUSTUP_HOME="/opt/rust/rustup"
    mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"
  else
    CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
  fi
  export CARGO_HOME RUSTUP_HOME

  if [ ! -x "${CARGO_HOME}/bin/cargo" ]; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --default-toolchain stable --no-modify-path
    rm -f /tmp/rustup.sh
  fi
  export PATH="${CARGO_HOME}/bin:$PATH"

  if [ -f "Cargo.toml" ]; then
    log "Fetching Rust crate dependencies"
    cargo fetch || true
  fi
}

# Create project structure and permissions
setup_directories() {
  log "Setting up project directories"
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,data,run}
  if [ "$HAS_ROOT" -eq 1 ]; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT"
  fi
}

# Configure environment variables
setup_env_vars() {
  log "Configuring environment variables"
  # Port heuristics already determined
  local DEFAULT_PORT="${APP_PORT:-8080}"

  # Create .env if not exists; update keys idempotently
  touch "$PROJECT_ROOT/$ENV_FILE"
  # Helper to upsert key=value in .env
  upsert_env() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "$PROJECT_ROOT/$ENV_FILE"; then
      sed -i "s|^${key}=.*|${key}=${val}|g" "$PROJECT_ROOT/$ENV_FILE"
    else
      printf "%s=%s\n" "$key" "$val" >> "$PROJECT_ROOT/$ENV_FILE"
    fi
  }

  upsert_env "APP_ENV" "$APP_ENV"
  upsert_env "PORT" "$DEFAULT_PORT"
  upsert_env "PYTHONUNBUFFERED" "1"
  upsert_env "PIP_NO_CACHE_DIR" "1"
  upsert_env "PIP_DISABLE_PIP_VERSION_CHECK" "1"
  upsert_env "NODE_ENV" "production"
  upsert_env "PROJECT_ROOT" "$PROJECT_ROOT"

  # Profile script for PATH (system-wide if root)
  local PROFILE_SNIPPET='
# Auto-generated by setup script
export PROJECT_ROOT="'"$PROJECT_ROOT"'"
[ -d "$PROJECT_ROOT/.venv/bin" ] && export PATH="$PROJECT_ROOT/.venv/bin:$PATH"
[ -d "$PROJECT_ROOT/node_modules/.bin" ] && export PATH="$PROJECT_ROOT/node_modules/.bin:$PATH"
[ -d "/usr/local/dotnet" ] && export DOTNET_ROOT="/usr/local/dotnet" && export PATH="/usr/local/dotnet:$PATH"
[ -d "$HOME/.dotnet" ] && export DOTNET_ROOT="$HOME/.dotnet" && export PATH="$HOME/.dotnet:$PATH"
[ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH"
'
  if [ "$HAS_ROOT" -eq 1 ]; then
    echo "$PROFILE_SNIPPET" > /etc/profile.d/project_env.sh
    chmod 0644 /etc/profile.d/project_env.sh
  else
    # Write a local profile snippet
    echo "$PROFILE_SNIPPET" > "$PROJECT_ROOT/.project_env.sh"
    chmod 0644 "$PROJECT_ROOT/.project_env.sh"
  fi
}

# Add/augment a generic Makefile build target if missing
setup_generic_make_build() {
  # Auto-generate or augment Makefile with a generic 'build' target if missing
  cat > Makefile.build <<'EOF'
# Auto-generated generic build target
# Uses GNU make .RECIPEPREFIX to avoid tab requirements
.RECIPEPREFIX := >
.PHONY: build
build:
> set -e; \
> if [ -f package.json ]; then \
>   if command -v npm >/dev/null 2>&1; then \
>     npm ci --no-audit --prefer-offline --no-fund || npm install --no-audit --no-fund; \
>     npm run build; \
>   else \
>     echo "npm not found. Please install Node.js/npm." >&2; exit 1; \
>   fi; \
> elif [ -f pyproject.toml ]; then \
>   if command -v python3 >/dev/null 2>&1; then \
>     python3 -m pip install --upgrade pip build; \
>     python3 -m build; \
>   else \
>     echo "python3 not found." >&2; exit 1; \
>   fi; \
> elif [ -f setup.py ]; then \
>   if command -v python3 >/dev/null 2>&1; then \
>     python3 -m pip install --upgrade pip setuptools wheel; \
>     python3 setup.py sdist bdist_wheel; \
>   else \
>     echo "python3 not found." >&2; exit 1; \
>   fi; \
> elif [ -f go.mod ]; then \
>   if command -v go >/dev/null 2>&1; then \
>     go build ./...; \
>   else \
>     echo "go not found." >&2; exit 1; \
>   fi; \
> elif [ -f Cargo.toml ]; then \
>   if command -v cargo >/dev/null 2>&1; then \
>     cargo build --release; \
>   else \
>     echo "cargo not found." >&2; exit 1; \
>   fi; \
> elif [ -f pom.xml ]; then \
>   if command -v mvn >/dev/null 2>&1; then \
>     mvn -B -DskipTests package; \
>   else \
>     echo "maven (mvn) not found." >&2; exit 1; \
>   fi; \
> elif [ -f build.gradle ] || [ -f build.gradle.kts ] || [ -x ./gradlew ]; then \
>   if [ -x ./gradlew ]; then \
>     ./gradlew build; \
>   elif command -v gradle >/dev/null 2>&1; then \
>     gradle build; \
>   else \
>     echo "Gradle not found." >&2; exit 1; \
>   fi; \
> else \
>   echo "No recognizable build configuration found; please add a build script or Makefile target." >&2; \
>   exit 1; \
> fi
EOF

  if [ -f Makefile ]; then
    if ! grep -Eq "^[[:space:]]*build[[:space:]]*:" Makefile; then
      printf "\n# Added generic build target\n" >> Makefile
      cat Makefile.build >> Makefile
    fi
    rm -f Makefile.build
  else
    mv Makefile.build Makefile
  fi
}

setup_generic_make_test() {
  if [ -f Makefile ]; then
    if ! grep -qE "^[[:space:]]*test:" Makefile; then
      if grep -qE '^[[:space:]]*\.RECIPEPREFIX[[:space:]]*:=' Makefile; then
        cat <<'EOF' >> Makefile
.PHONY: test
test:
> @echo "Running tests..."
> if [ -d tests ] || ls -1 *test*.py >/dev/null 2>&1; then \
>   (python3 -m pytest -q || python -m pytest -q); \
> else \
>   echo "No tests found. Skipping."; \
> fi
EOF
      else
        cat <<'EOF' >> Makefile
.PHONY: test
test:
	@echo "Running tests..."
	@if [ -d tests ] || ls -1 *test*.py >/dev/null 2>&1; then \
	  (python3 -m pytest -q || python -m pytest -q); \
	else \
	  echo "No tests found. Skipping."; \
	fi
EOF
      fi
    fi
  else
    cat <<'EOF' > Makefile
.PHONY: test
test:
	@echo "Running tests..."
	@if [ -d tests ] || ls -1 *test*.py >/dev/null 2>&1; then \
	  (python3 -m pytest -q || python -m pytest -q); \
	else \
	  echo "No tests found. Skipping."; \
	fi
EOF
  fi
}

install_pytest_and_dev_reqs() {
  # Upgrade base packaging tools
  (python3 -m pip install --no-cache-dir -U pip setuptools wheel || \
   python -m pip install --no-cache-dir -U pip setuptools wheel) || true

  # Ensure framework compatibility and test dependencies on system Python
  (python3 -m pip install --no-cache-dir --upgrade --force-reinstall "fastapi==0.95.2" "starlette==0.27.0" "pydantic==1.10.13" "httpx==0.27.0" "anyio<4" "python-multipart>=0.0.5" || \
   python -m pip install --no-cache-dir --upgrade --force-reinstall "fastapi==0.95.2" "starlette==0.27.0" "pydantic==1.10.13" "httpx==0.27.0" "anyio<4" "python-multipart>=0.0.5") || true
  (python3 -m pip check || python -m pip check) || true

  if [ -x "$VENV_DIR/bin/python" ]; then
    "$VENV_DIR/bin/python" -m pip install --no-cache-dir -U pip setuptools wheel || true
    "$VENV_DIR/bin/python" -m pip install --no-cache-dir --upgrade --force-reinstall "fastapi==0.95.2" "starlette==0.27.0" "pydantic==1.10.13" "httpx==0.27.0" "anyio<4" "python-multipart>=0.0.5" || true
    "$VENV_DIR/bin/python" -m pip install --no-cache-dir --upgrade --force-reinstall "fastapi==0.95.2" "starlette==0.27.0" "pydantic==1.10.13" "httpx==0.27.0" "anyio<4" "python-multipart>=0.0.5" pytest || true
    "$VENV_DIR/bin/python" -m pip check || true
    if [ -f "requirements-dev.txt" ]; then
      "$VENV_DIR/bin/pip" install --no-cache-dir -r requirements-dev.txt || true
    fi
  else
    if [ -f "requirements-dev.txt" ]; then
      (python3 -m pip install --no-cache-dir -r requirements-dev.txt || python -m pip install --no-cache-dir -r requirements-dev.txt) || true
    fi
  fi

  # Configure pytest to use asyncio mode and marker
  tee pytest.ini >/dev/null << 'EOF'
[pytest]
markers =
    asyncio: mark a test as asyncio
asyncio_mode = auto
EOF
}

# Main
main() {
  log "Starting universal environment setup"
  log "Project root: $PROJECT_ROOT"

  detect_pkg_manager
  ensure_unzip_apt
  curl_shim_setup
  git_shim_setup
  unzip_shim_setup
  tar_shim_setup
  xz_shim_setup
  xz_utils_shim_setup
  preprovision_node_apt
  if [ -z "$PKG_MGR" ] && [ "$HAS_ROOT" -eq 1 ]; then
    warn "No supported package manager detected (apt/apk/dnf/yum/zypper). System package installation will be skipped."
  fi

  ensure_base_tools
  ensure_app_user
  setup_directories

  detect_stack
  if [ "${#STACKS[@]}" -eq 0 ]; then
    warn "No known project stack detected. Proceeding with base setup only."
  else
    info "Detected stack(s): ${STACKS[*]}"
  fi

  # Language setups (in a deterministic order)
  for s in "${STACKS[@]}"; do
    case "$s" in
      python) setup_python ;;
      node)   setup_node ;;
      ruby)   setup_ruby ;;
      java)   setup_java ;;
      go)     setup_go ;;
      php)    setup_php ;;
      dotnet) setup_dotnet ;;
      rust)   setup_rust ;;
    esac
  done

  # Post-repair: ensure Python deps are installed with no cache; do not fail script if this step errors
  if [ -f "requirements.txt" ] && [ -x "$VENV_DIR/bin/pip" ]; then
    "$VENV_DIR/bin/pip" install -r requirements.txt --no-cache-dir || true
  fi

  install_pytest_and_dev_reqs
  setup_env_vars
  setup_generic_make_build
  setup_generic_make_test
  clean_pkg_cache

  # Final ownership fix
  if [ "$HAS_ROOT" -eq 1 ]; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT"
  fi

  log "Environment setup completed successfully."
  echo
  echo "Summary:"
  echo " - Detected stacks: ${STACKS[*]:-none}"
  echo " - App user: ${HAS_ROOT:+$APP_USER (uid:$APP_UID)}${HAS_ROOT:+" , group:$APP_GROUP (gid:$APP_GID)"}${HAS_ROOT:+" (created if needed)"}${HAS_ROOT:+"."}"
  echo " - Env file: $PROJECT_ROOT/$ENV_FILE (PORT=$APP_PORT, APP_ENV=$APP_ENV)"
  echo " - Useful PATH additions and env exported via: ${HAS_ROOT:+/etc/profile.d/project_env.sh}${HAS_ROOT:+" or "}$PROJECT_ROOT/.project_env.sh"
  echo
  echo "Next steps:"
  echo " - Source the environment in your shell: source $PROJECT_ROOT/$ENV_FILE 2>/dev/null || true; [ -f $PROJECT_ROOT/.project_env.sh ] && source $PROJECT_ROOT/.project_env.sh || true"
  echo " - Start your app using the appropriate command for your stack."
  echo
}

main "$@"