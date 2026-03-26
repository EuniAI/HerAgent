#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Installs runtimes, system packages, dependencies, and configures environment
# Safe to run multiple times (idempotent), with robust logging and error handling

set -Eeuo pipefail
IFS=$'\n\t'
umask 027
export DEBIAN_FRONTEND=noninteractive

# -----------------------------
# Logging and error handling
# -----------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info()   { echo "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARNING] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

cleanup() { :; }
trap 'rc=$?; [ $rc -ne 0 ] && error "Script failed (exit ${rc}) at line $LINENO"; cleanup; exit $rc' EXIT

# -----------------------------
# Configuration defaults
# -----------------------------
APP_HOME="${APP_HOME:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
PORT="${PORT:-8000}"
APP_USER_NAME="${APP_USER_NAME:-app}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
SKIP_CHOWN="${SKIP_CHOWN:-0}"

# Flags for detection
HAS_PYTHON=0
HAS_NODE=0
HAS_JAVA=0
HAS_GO=0
HAS_RUST=0
HAS_PHP=0
HAS_DOTNET=0

# Package manager global
PKG_MGR=""
PM_UPDATE=""
PM_INSTALL=""
PM_HAS=""

# -----------------------------
# Helper functions
# -----------------------------

require_root_or_warn() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Running as non-root; system package installation may be skipped if not permitted."
    return 1
  fi
  return 0
}

detect_distro() {
  local id=""
  local like=""
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    id="${ID:-}"
    like="${ID_LIKE:-}"
  fi

  if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PM_UPDATE="apk update"
    PM_INSTALL="apk add --no-cache"
    PM_HAS="apk info -e"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PM_UPDATE="apt-get update -y -qq"
    PM_INSTALL="apt-get install -y --no-install-recommends"
    PM_HAS="dpkg -s"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
    PM_UPDATE="microdnf -y update"
    PM_INSTALL="microdnf -y install"
    PM_HAS="rpm -q"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PM_UPDATE="dnf -y makecache"
    PM_INSTALL="dnf -y install"
    PM_HAS="rpm -q"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PM_UPDATE="yum -y makecache"
    PM_INSTALL="yum -y install"
    PM_HAS="rpm -q"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    PM_UPDATE="zypper --non-interactive refresh"
    PM_INSTALL="zypper --non-interactive install -y"
    PM_HAS="rpm -q"
  else
    PKG_MGR="none"
  fi

  if [ "$PKG_MGR" = "none" ]; then
    warn "No supported package manager detected. System dependencies may not be installed."
  else
    log "Detected package manager: $PKG_MGR"
  fi
}

pm_update() {
  require_root_or_warn || return 0
  [ "$PKG_MGR" = "none" ] && return 0
  eval "$PM_UPDATE" || warn "Package manager update encountered issues"
}

pm_install() {
  require_root_or_warn || return 0
  [ "$PKG_MGR" = "none" ] && return 0
  local pkgs=("$@")
  if [ "${#pkgs[@]}" -eq 0 ]; then return 0; fi
  log "Installing system packages: ${pkgs[*]}"
  (
    IFS=' '
    # shellcheck disable=SC2086
    $PM_INSTALL "${pkgs[@]}"
  )
}

ensure_base_packages() {
  pm_update
  case "$PKG_MGR" in
    apk)
      pm_install bash ca-certificates curl wget git openssl tar xz gzip unzip shadow su-exec libc6-compat coreutils findutils grep sed gawk jq procps
      ;;
    apt)
      pm_install ca-certificates curl wget git openssl tar xz-utils gzip unzip build-essential pkg-config jq procps gnupg dirmngr
      ;;
    microdnf|dnf|yum)
      pm_install ca-certificates curl wget git openssl tar xz gzip unzip make automake gcc g++ kernel-headers pkgconf jq procps-ng
      ;;
    zypper)
      pm_install ca-certificates curl wget git openssl tar xz gzip unzip make gcc-c++ pkgconf jq procps
      ;;
    *)
      warn "Skipping base package installation; unsupported package manager."
      ;;
  esac
  # Update CA certificates if available
  if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates || true; fi
}

# -----------------------------
# Virtual environment auto-activation
# -----------------------------
setup_auto_activate() {
  local bashrc_file="$HOME/.bashrc"
  local venv_dir="${VENV_DIR:-$APP_HOME/.venv}"
  local activate_line="source $venv_dir/bin/activate"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# -----------------------------
# Build toolchain setup (CMake, Ninja, compilers)
# -----------------------------
setup_cmake_toolchain() {
  log "Installing CMake/Ninja and core build dependencies"
  set +e
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y cmake ninja-build make gcc g++ ccache python3 python3-pip git
  elif command -v yum >/dev/null 2>&1; then
    yum -y install epel-release && yum -y install cmake ninja-build make gcc gcc-c++ ccache python3 python3-pip git
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install cmake ninja-build make gcc gcc-c++ ccache python3 python3-pip git
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache cmake ninja make gcc g++ ccache python3 py3-pip git
  else
    echo No supported package manager found
    set -e
    exit 1
  fi

  if command -v yum >/dev/null 2>&1; then
    yum -y install centos-release-scl scl-utils && yum -y install gcc-toolset-11
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install scl-utils || true
    dnf -y install gcc-toolset-11 || dnf -y module install gcc-toolset-11 || true
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip install --no-cache-dir --upgrade pip
    python3 -m pip install --no-cache-dir cmake ninja codespell pytest
  fi

  set -e
  cmake --version || true
}

# -----------------------------
# Project detection
# -----------------------------
detect_project_type() {
  # Python
  if [ -f "$APP_HOME/requirements.txt" ] || [ -f "$APP_HOME/pyproject.toml" ] || [ -f "$APP_HOME/Pipfile" ]; then
    HAS_PYTHON=1
  fi
  # Node
  if [ -f "$APP_HOME/package.json" ]; then
    HAS_NODE=1
  fi
  # Java
  if [ -f "$APP_HOME/pom.xml" ] || [ -f "$APP_HOME/build.gradle" ] || [ -f "$APP_HOME/build.gradle.kts" ] || [ -f "$APP_HOME/gradlew" ]; then
    HAS_JAVA=1
  fi
  # Go
  if [ -f "$APP_HOME/go.mod" ]; then
    HAS_GO=1
  fi
  # Rust
  if [ -f "$APP_HOME/Cargo.toml" ]; then
    HAS_RUST=1
  fi
  # PHP
  if [ -f "$APP_HOME/composer.json" ]; then
    HAS_PHP=1
  fi
  # .NET
  if ls "$APP_HOME"/*.sln >/dev/null 2>&1 || ls "$APP_HOME"/*.csproj >/dev/null 2>&1 || [ -f "$APP_HOME/global.json" ]; then
    HAS_DOTNET=1
  fi

  info "Detected stacks -> Python:$HAS_PYTHON Node:$HAS_NODE Java:$HAS_JAVA Go:$HAS_GO Rust:$HAS_RUST PHP:$HAS_PHP .NET:$HAS_DOTNET"
}

# -----------------------------
# Runtime setup functions
# -----------------------------
setup_python() {
  [ "$HAS_PYTHON" -eq 1 ] || return 0
  log "Setting up Python environment"
  case "$PKG_MGR" in
    apk) pm_install python3 py3-pip python3-dev musl-dev gcc ;;
    apt) pm_install python3 python3-pip python3-venv python3-dev build-essential ;;
    microdnf|dnf|yum) pm_install python3 python3-pip python3-devel gcc gcc-c++ make ;;
    zypper) pm_install python3 python3-pip python3-virtualenv python3-devel gcc gcc-c++ make ;;
    *) warn "Package manager not detected; assuming Python preinstalled";;
  esac

  if ! command -v python3 >/dev/null 2>&1; then die "Python3 not found after installation"; fi

  cd "$APP_HOME"
  VENV_DIR="${VENV_DIR:-$APP_HOME/.venv}"
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  else
    log "Virtual environment already exists at $VENV_DIR"
  fi

  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    PIP_DISABLE_PIP_VERSION_CHECK=1 pip install -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    if grep -q "\[tool.poetry\]" pyproject.toml 2>/dev/null; then
      log "Poetry project detected; installing Poetry and dependencies"
      pip install "poetry>=1.5"
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi
    else
      log "PEP 517 build detected; installing via pip"
      PIP_DISABLE_PIP_VERSION_CHECK=1 pip install .
    fi
  elif [ -f "Pipfile" ]; then
    log "Pipenv project detected; installing pipenv"
    pip install "pipenv>=2022.1.8"
    pipenv --python "$(command -v python)" install --deploy || pipenv install
  else
    info "No Python dependency file found"
  fi

  deactivate || true
}

setup_node() {
  [ "$HAS_NODE" -eq 1 ] || return 0
  log "Setting up Node.js environment"
  case "$PKG_MGR" in
    apk) pm_install nodejs npm ;;
    apt) pm_install nodejs npm ;;
    microdnf|dnf|yum) pm_install nodejs npm || warn "Node.js packages may be named differently or not present" ;;
    zypper) pm_install nodejs npm ;;
    *) warn "Package manager not detected; assuming Node.js preinstalled" ;;
  esac

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    warn "node/npm not available via system packages. Attempting to install Node via NodeSource (Debian/Ubuntu) or fallback to failure."
    if [ "$PKG_MGR" = "apt" ] && require_root_or_warn; then
      curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - || warn "NodeSource setup failed"
      pm_install nodejs
    fi
  fi

  if ! command -v node >/dev/null 2>&1; then die "Node.js not found after installation attempts"; fi

  cd "$APP_HOME"
  if [ -f "yarn.lock" ]; then
    info "yarn.lock found"
    if ! command -v yarn >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then
        corepack enable || true
        corepack prepare yarn@stable --activate || true
      fi
    fi
    if command -v yarn >/dev/null 2>&1; then
      yarn install --frozen-lockfile || yarn install
    else
      warn "Yarn not available; using npm as fallback"
      if [ -f "package-lock.json" ]; then npm ci || npm install; else npm install; fi
    fi
  else
    if [ -f "package-lock.json" ]; then
      npm ci || npm install
    else
      npm install
    fi
  fi
}

setup_java() {
  [ "$HAS_JAVA" -eq 1 ] || return 0
  log "Setting up Java environment"
  case "$PKG_MGR" in
    apk) pm_install openjdk17-jdk maven gradle ;;
    apt) pm_install openjdk-17-jdk maven gradle ;;
    microdnf|dnf|yum) pm_install java-17-openjdk java-17-openjdk-devel maven gradle ;;
    zypper) pm_install java-17-openjdk java-17-openjdk-devel maven gradle ;;
    *) warn "Package manager not detected; assuming Java tools preinstalled" ;;
  esac

  if ! command -v java >/dev/null 2>&1; then die "Java not found after installation"; fi

  cd "$APP_HOME"
  if [ -f "pom.xml" ]; then
    if [ -x "./mvnw" ]; then
      ./mvnw -q -DskipTests dependency:resolve || true
    else
      if command -v mvn >/dev/null 2>&1; then mvn -q -DskipTests dependency:resolve || true; else warn "Maven not available"; fi
    fi
  fi
  if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -x "./gradlew" ]; then
    if [ -x "./gradlew" ]; then
      ./gradlew --quiet tasks || true
    else
      if command -v gradle >/dev/null 2>&1; then gradle --quiet tasks || true; else warn "Gradle not available"; fi
    fi
  fi
}

setup_go() {
  [ "$HAS_GO" -eq 1 ] || return 0
  log "Setting up Go environment"
  case "$PKG_MGR" in
    apk) pm_install go ;;
    apt) pm_install golang ;;
    microdnf|dnf|yum) pm_install golang ;;
    zypper) pm_install go ;;
    *) warn "Package manager not detected; assuming Go preinstalled" ;;
  esac

  if ! command -v go >/dev/null 2>&1; then die "Go not found after installation"; fi

  cd "$APP_HOME"
  go mod download || warn "go mod download failed"
}

setup_rust() {
  [ "$HAS_RUST" -eq 1 ] || return 0
  log "Setting up Rust environment"
  local rust_ok=0
  if command -v cargo >/dev/null 2>&1; then rust_ok=1; fi

  if [ $rust_ok -eq 0 ]; then
    case "$PKG_MGR" in
      apk) pm_install cargo rust ;;
      apt) pm_install cargo rustc ;;
      microdnf|dnf|yum) pm_install cargo rust ;;
      zypper) pm_install cargo rust ;;
      *) warn "Package manager not detected; will install via rustup script" ;;
    esac
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    warn "Installing Rust using rustup (will install to /usr/local if root, else to \$HOME/.cargo)"
    if curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; then
      chmod +x /tmp/rustup-init.sh
      # Non-interactive install, default toolchain stable
      /tmp/rustup-init.sh -y --profile minimal
      export PATH="$HOME/.cargo/bin:$PATH"
    else
      die "Failed to download rustup installer"
    fi
  fi

  if ! command -v cargo >/dev/null 2>&1; then die "Rust cargo not found after installation"; fi
  cd "$APP_HOME"
  cargo fetch || warn "cargo fetch failed"
}

setup_php() {
  [ "$HAS_PHP" -eq 1 ] || return 0
  log "Setting up PHP environment"
  case "$PKG_MGR" in
    apk) pm_install php81 php81-cli php81-phar php81-json php81-mbstring php81-openssl php81-xml php81-curl composer || pm_install php php-cli php-phar php-json php-mbstring php-openssl php-xml php-curl composer ;;
    apt) pm_install php-cli php-xml php-curl php-mbstring composer ;;
    microdnf|dnf|yum) pm_install php-cli php-xml php-json php-mbstring php-openssl php-curl composer || warn "Composer may be missing; install manually if needed" ;;
    zypper) pm_install php-cli php-xml php-curl php-mbstring composer ;;
    *) warn "Package manager not detected; assuming PHP preinstalled" ;;
  esac

  if ! command -v php >/dev/null 2>&1; then die "PHP not found after installation"; fi

  cd "$APP_HOME"
  if ! command -v composer >/dev/null 2>&1; then
    warn "Composer not found; attempting to install locally"
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)" || die "Failed to fetch composer signature"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      die "Invalid composer installer signature"
    fi
    php composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer || php composer-setup.php --quiet
    rm -f composer-setup.php
  fi

  if [ -f "composer.json" ]; then
    if [ -f "composer.lock" ]; then
      composer install --no-interaction --no-progress || warn "composer install failed"
    else
      composer update --no-interaction --no-progress || warn "composer update failed"
    fi
  fi
}

setup_dotnet() {
  [ "$HAS_DOTNET" -eq 1 ] || return 0
  log "Setting up .NET SDK/runtime"
  if ! command -v dotnet >/dev/null 2>&1; then
    warn ".NET not detected; installing .NET SDK LTS via official installer"
    INSTALL_DIR="/opt/dotnet"
    if [ "$(id -u)" -ne 0 ]; then
      INSTALL_DIR="${HOME}/.dotnet"
    fi
    mkdir -p "$INSTALL_DIR"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir "$INSTALL_DIR" --version LTS || /tmp/dotnet-install.sh --install-dir "$INSTALL_DIR" --channel LTS
    export DOTNET_ROOT="$INSTALL_DIR"
    export PATH="$DOTNET_ROOT:$PATH"
    if [ "$(id -u)" -eq 0 ]; then
      ln -sf "$DOTNET_ROOT/dotnet" /usr/local/bin/dotnet || true
    fi
  fi

  if ! command -v dotnet >/dev/null 2>&1; then die ".NET dotnet command not found after installation"; fi

  cd "$APP_HOME"
  if ls *.sln >/dev/null 2>&1; then
    dotnet restore || warn "dotnet restore failed"
  elif ls *.csproj >/dev/null 2>&1; then
    dotnet restore || warn "dotnet restore failed"
  fi
}

# -----------------------------
# Permissions and directories
# -----------------------------
setup_directories() {
  cd "$APP_HOME"
  log "Ensuring project directories"
  mkdir -p "$APP_HOME"/{logs,tmp,data,run}
  touch "$APP_HOME/logs/.keep" "$APP_HOME/tmp/.keep" "$APP_HOME/data/.keep" "$APP_HOME/run/.keep" || true
}

setup_user_permissions() {
  # Create non-root app user if running as root
  if [ "$(id -u)" -eq 0 ]; then
    if ! getent group "$APP_GID" >/dev/null 2>&1; then
      groupadd -g "$APP_GID" "$APP_USER_NAME" 2>/dev/null || true
    fi
    if ! id -u "$APP_USER_NAME" >/dev/null 2>&1; then
      useradd -m -u "$APP_UID" -g "$APP_GID" -s /sbin/nologin "$APP_USER_NAME" 2>/dev/null || true
    fi
    if [ "$SKIP_CHOWN" = "0" ]; then
      log "Setting ownership of $APP_HOME to $APP_USER_NAME:$APP_USER_NAME"
      chown -R "$APP_USER_NAME:$APP_USER_NAME" "$APP_HOME" || warn "Failed to chown project (possibly bind-mounted). Continuing."
    else
      info "SKIP_CHOWN=1; skipping chown of project directory"
    fi
  else
    info "Not running as root; skipping user create and chown"
  fi
}

# -----------------------------
# Environment variables
# -----------------------------
setup_env_file() {
  cd "$APP_HOME"
  local env_file="$APP_HOME/.env"
  if [ ! -f "$env_file" ]; then
    log "Creating default .env file"
    cat > "$env_file" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
PYTHONUNBUFFERED=1
PIP_DISABLE_PIP_VERSION_CHECK=1
NODE_ENV=production
LOG_LEVEL=info
EOF
  else
    info ".env already exists; not overwriting"
  fi
}

export_runtime_env() {
  export APP_HOME APP_ENV PORT
  export PYTHONUNBUFFERED=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export NODE_ENV=production
}

# -----------------------------
# Entrypoint helper generation
# -----------------------------
generate_run_helpers() {
  cd "$APP_HOME"
  local run_file="$APP_HOME/run-app.sh"
  if [ ! -f "$run_file" ]; then
    log "Generating run-app.sh helper"
    cat > "$run_file" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_HOME="${APP_HOME:-$(pwd)}"
cd "$APP_HOME"

if [ -f ".env" ]; then
  set -o allexport
  # shellcheck disable=SC1091
  source .env
  set +o allexport
fi

if [ -d ".venv" ]; then
  # shellcheck disable=SC1091
  source ".venv/bin/activate" || true
fi

start_python() {
  if [ -f "manage.py" ]; then
    # Django
    exec python manage.py runserver 0.0.0.0:${PORT:-8000}
  elif [ -f "app.py" ] || [ -f "wsgi.py" ]; then
    if command -v gunicorn >/dev/null 2>&1; then
      MODULE="$( [ -f wsgi.py ] && echo wsgi || echo app )"
      exec gunicorn "${MODULE}:app" --bind 0.0.0.0:${PORT:-8000} --workers "${WEB_CONCURRENCY:-2}"
    else
      TARGET="$( [ -f app.py ] && echo app.py || echo wsgi.py )"
      exec python "$TARGET"
    fi
  fi
}

start_node() {
  if [ -f "package.json" ]; then
    if jq -e '.scripts.start' package.json >/dev/null 2>&1; then
      exec npm run start
    elif jq -e '.scripts.serve' package.json >/dev/null 2>&1; then
      exec npm run serve
    elif [ -f "server.js" ]; then
      exec node server.js
    else
      echo "No start script found in package.json" >&2
      exit 1
    fi
  fi
}

start_java() {
  if [ -f "pom.xml" ]; then
    if [ -x "./mvnw" ]; then
      exec ./mvnw spring-boot:run -Dspring-boot.run.profiles=${APP_ENV:-production} -Dserver.port=${PORT:-8080}
    else
      exec mvn spring-boot:run -Dspring-boot.run.profiles=${APP_ENV:-production} -Dserver.port=${PORT:-8080}
    fi
  elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -x "./gradlew" ]; then
    if [ -x "./gradlew" ]; then
      exec ./gradlew bootRun -Pargs="--server.port=${PORT:-8080}"
    else
      exec gradle bootRun -Pargs="--server.port=${PORT:-8080}"
    fi
  fi
}

start_go() {
  if [ -f "main.go" ]; then
    exec go run .
  fi
}

start_php() {
  if [ -f "public/index.php" ]; then
    exec php -S 0.0.0.0:${PORT:-8000} -t public
  elif [ -f "index.php" ]; then
    exec php -S 0.0.0.0:${PORT:-8000}
  fi
}

start_dotnet() {
  if ls *.sln >/dev/null 2>&1; then
    exec dotnet run --no-launch-profile --urls "http://0.0.0.0:${PORT:-8080}"
  elif ls *.csproj >/dev/null 2>&1; then
    exec dotnet run --no-launch-profile --urls "http://0.0.0.0:${PORT:-8080}"
  fi
}

if [ -f "package.json" ]; then
  start_node
elif [ -f "pyproject.toml" ] || [ -f "requirements.txt" ] || [ -f "Pipfile" ]; then
  start_python
elif [ -f "pom.xml" ] || [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -x "./gradlew" ]; then
  start_java
elif [ -f "go.mod" ]; then
  start_go
elif [ -f "composer.json" ]; then
  start_php
elif ls *.sln >/dev/null 2>&1 || ls *.csproj >/dev/null 2>&1; then
  start_dotnet
else
  echo "Unknown project type; please customize run-app.sh" >&2
  exit 1
fi
EOS
    chmod +x "$run_file"
  else
    info "run-app.sh already exists; not overwriting"
  fi
}

# -----------------------------
# Main
# -----------------------------
main() {
  log "Starting universal environment setup"
  log "APP_HOME=$APP_HOME APP_ENV=$APP_ENV PORT=$PORT"

  detect_distro
  ensure_base_packages
  setup_cmake_toolchain
  setup_directories
  setup_user_permissions
  setup_env_file
  export_runtime_env
  detect_project_type

  # Language-specific setups
  setup_python
  setup_auto_activate
  setup_node
  setup_java
  setup_go
  setup_rust
  setup_php
  setup_dotnet

  generate_run_helpers

  log "Environment setup completed successfully"
  info "To run the application: ./run-app.sh"
  info "If you need to run as non-root user inside container: su -s /bin/sh -c './run-app.sh' ${APP_USER_NAME}"
}

main "$@"