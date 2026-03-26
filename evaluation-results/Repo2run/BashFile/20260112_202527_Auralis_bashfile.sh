#!/bin/sh
# POSIX bootstrap: provision minimal /bin/sh via busybox if missing, install bash/coreutils, then re-exec under bash
if [ ! -x /bin/sh ]; then
  set -eux; mkdir -p /bin /usr/bin /usr/local/bin; ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) BB_URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-x86_64" ;; aarch64|arm64) BB_URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-aarch64" ;; armv7l|armhf) BB_URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-armv7l" ;; *) BB_URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-x86_64" ;; esac; if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y --no-install-recommends ca-certificates curl wget && (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true); elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache ca-certificates curl wget && (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true); elif command -v dnf >/dev/null 2>&1; then dnf makecache -y && dnf install -y ca-certificates curl wget; elif command -v yum >/dev/null 2>&1; then yum makecache -y && yum install -y ca-certificates curl wget; elif command -v microdnf >/dev/null 2>&1; then microdnf -y install ca-certificates curl wget; fi; fi; if [ ! -x /usr/local/bin/busybox ]; then (curl -fsSL "$BB_URL" -o /usr/local/bin/busybox || curl -kfsSL "$BB_URL" -o /usr/local/bin/busybox || wget -qO /usr/local/bin/busybox "$BB_URL" || wget --no-check-certificate -qO /usr/local/bin/busybox "$BB_URL"); fi; chmod +x /usr/local/bin/busybox; [ -x /bin/sh ] || ln -sf /usr/local/bin/busybox /bin/sh; [ -x /bin/bash ] || ln -sf /usr/local/bin/busybox /bin/bash; [ -x /usr/bin/env ] || ln -sf /usr/local/bin/busybox /usr/bin/env; [ -x /bin/timeout ] || ln -sf /usr/local/bin/busybox /bin/timeout; /usr/local/bin/busybox --help >/dev/null 2>&1 || true
fi
if [ -z "${BASH_VERSION:-}" ]; then
  set -euxo pipefail; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y --no-install-recommends bash coreutils ca-certificates curl git wget tar xz-utils && (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true); elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache bash coreutils ca-certificates curl git wget tar xz && (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true); elif command -v dnf >/dev/null 2>&1; then dnf makecache -y && dnf install -y bash coreutils ca-certificates curl git wget tar xz; elif command -v yum >/dev/null 2>&1; then yum makecache -y && yum install -y bash coreutils ca-certificates curl git wget tar xz; elif command -v microdnf >/dev/null 2>&1; then microdnf -y install bash coreutils ca-certificates curl git wget tar xz; else echo "No supported package manager found; keeping BusyBox as shell" >&2; fi; if command -v bash >/dev/null 2>&1; then ln -sf "$(command -v bash)" /bin/bash; fi; if ! command -v timeout >/dev/null 2>&1 && [ -x /usr/local/bin/busybox ]; then ln -sf /usr/local/bin/busybox /bin/timeout; fi; [ -x /usr/bin/env ] || { if command -v env >/dev/null 2>&1; then ln -sf "$(command -v env)" /usr/bin/env; else ln -sf /usr/local/bin/busybox /usr/bin/env; fi; }
  if ! command -v timeout >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y --no-install-recommends coreutils; elif command -v apk >/dev/null 2>&1; then apk add --no-cache coreutils; elif command -v dnf >/dev/null 2>&1; then dnf install -y coreutils; elif command -v yum >/dev/null 2>&1; then yum install -y coreutils; elif command -v microdnf >/dev/null 2>&1; then microdnf -y install coreutils; elif [ -x /usr/local/bin/busybox ]; then ln -sf /usr/local/bin/busybox /bin/timeout; fi
  fi
  command -v timeout || true
  exec /bin/bash "$0" "$@"
  exit 1
fi
# Container-friendly, idempotent environment setup script
# Detects common project types (Python, Node.js, Go, Java, PHP, Ruby, Rust, .NET)
# Installs system packages and runtimes, configures environment, and installs dependencies.

set -Eeuo pipefail

#===============================
# Logging and error handling
#===============================
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log() {
  echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}

warn() {
  echo "${YELLOW}[WARNING] $*${NC}" >&2
}

err() {
  echo "${RED}[ERROR] $*${NC}" >&2
}

cleanup() {
  if [[ "${BASH_SUBSHELL:-0}" -eq 0 ]]; then
    :
  fi
}
trap cleanup EXIT
trap 'err "Setup failed at line $LINENO"; exit 1' ERR

#===============================
# Globals and defaults
#===============================
APP_HOME="${APP_HOME:-/app}"
WORK_DIR="${1:-$APP_HOME}"   # Allow path override via first arg
RUN_AS_USER="${RUN_AS_USER:-}"
CREATE_USER="${CREATE_USER:-false}"  # Set true to create a non-root user
APP_ENV="${APP_ENV:-production}"
PORT="${PORT:-}"
DEBIAN_FRONTEND=noninteractive

#===============================
# Utility functions
#===============================
has_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "This script must run as root inside the container."
    exit 1
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
  else
    OS_ID="unknown"
    OS_VERSION_ID="unknown"
  fi

  PKG_MGR=""
  UPDATE_CMD=""
  INSTALL_CMD=""
  EXTRA_REPOS_SETUP=""

  case "$OS_ID" in
    debian|ubuntu)
      PKG_MGR="apt"
      UPDATE_CMD="apt-get update -y"
      INSTALL_CMD="apt-get install -y --no-install-recommends"
      ;;
    alpine)
      PKG_MGR="apk"
      UPDATE_CMD="apk update"
      INSTALL_CMD="apk add --no-cache"
      ;;
    centos|rhel|rocky|almalinux)
      # Prefer dnf if available
      if has_cmd dnf; then
        PKG_MGR="dnf"
        UPDATE_CMD="dnf makecache -y"
        INSTALL_CMD="dnf install -y"
      else
        PKG_MGR="yum"
        UPDATE_CMD="yum makecache -y"
        INSTALL_CMD="yum install -y"
      fi
      ;;
    fedora)
      PKG_MGR="dnf"
      UPDATE_CMD="dnf makecache -y"
      INSTALL_CMD="dnf install -y"
      ;;
    amzn|amazon)
      if has_cmd dnf; then
        PKG_MGR="dnf"
        UPDATE_CMD="dnf makecache -y"
        INSTALL_CMD="dnf install -y"
      else
        PKG_MGR="yum"
        UPDATE_CMD="yum makecache -y"
        INSTALL_CMD="yum install -y"
      fi
      ;;
    *)
      warn "Unknown OS. Attempting apt as default."
      PKG_MGR="apt"
      UPDATE_CMD="apt-get update -y"
      INSTALL_CMD="apt-get install -y --no-install-recommends"
      ;;
  esac

  log "Detected OS: $OS_ID $OS_VERSION_ID, package manager: $PKG_MGR"
}

pm_update() {
  log "Updating package index..."
  eval "$UPDATE_CMD"
}

pm_install() {
  # Installs packages, tolerating not-found errors per package by retrying alternates when possible
  local pkgs=("$@")
  if [[ "${#pkgs[@]}" -eq 0 ]]; then return 0; fi
  log "Installing system packages: ${pkgs[*]}"
  set +e
  eval "$INSTALL_CMD ${pkgs[*]}"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    err "Package installation encountered errors."
    exit 1
  fi
}

ensure_packages() {
  # Cross-distro package mapping
  case "$PKG_MGR" in
    apt)
      pm_update
      pm_install ca-certificates curl git openssh-client gnupg tar xz-utils build-essential pkg-config libssl-dev zlib1g-dev libffi-dev
      # Python
      pm_install python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      pm_update
      pm_install ca-certificates curl git openssh-client tar xz build-base pkgconfig openssl-dev zlib-dev libffi-dev
      pm_install python3 py3-pip python3-dev
      # Ensure pip bootstrapped for venv environments in Alpine
      python3 -m ensurepip || true
      ;;
    yum|dnf)
      pm_update
      pm_install ca-certificates curl git openssh-clients tar xz gcc gcc-c++ make pkgconfig openssl-devel zlib-devel libffi-devel
      # Enable EPEL if available (helps with python3)
      if [[ "$PKG_MGR" != "apk" ]] && has_cmd yum; then yum install -y epel-release || true; fi
      pm_install python3 python3-pip python3-devel
      ;;
    *)
      err "Unsupported package manager: $PKG_MGR"
      exit 1
      ;;
  esac
}

setup_directories() {
  mkdir -p "$WORK_DIR"
  mkdir -p "$WORK_DIR/logs" "$WORK_DIR/tmp"
  chmod 755 "$WORK_DIR"
  chown -R root:root "$WORK_DIR"
  log "Project directories prepared at $WORK_DIR"
}

maybe_create_user() {
  if [[ "$CREATE_USER" == "true" ]]; then
    local user="${RUN_AS_USER:-appuser}"
    if ! id "$user" >/dev/null 2>&1; then
      log "Creating non-root user: $user"
      case "$PKG_MGR" in
        apk)
          adduser -D -h "$WORK_DIR" "$user"
          ;;
        apt|yum|dnf)
          useradd -m -d "$WORK_DIR" -s /bin/bash "$user"
          ;;
      esac
    fi
    chown -R "$user":"$user" "$WORK_DIR"
  fi
}

load_env_file() {
  # Load .env if present (safe parsing: skip comments and malformed lines)
  local env_file="$WORK_DIR/.env"
  if [[ -f "$env_file" ]]; then
    log "Loading environment variables from $env_file"
    while IFS='=' read -r key value; do
      [[ -z "$key" ]] && continue
      [[ "$key" =~ ^# ]] && continue
      if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
        value="${value:1:-1}"
      fi
      export "$key=$value"
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" || true)
  fi
}

detect_project_type() {
  PROJECT_TYPE="unknown"
  if [[ -f "$WORK_DIR/package.json" ]]; then
    PROJECT_TYPE="node"
  elif [[ -f "$WORK_DIR/pyproject.toml" || -f "$WORK_DIR/requirements.txt" || -f "$WORK_DIR/setup.py" ]]; then
    PROJECT_TYPE="python"
  elif [[ -f "$WORK_DIR/go.mod" || -n "$(ls "$WORK_DIR"/*.go 2>/dev/null || true)" ]]; then
    PROJECT_TYPE="go"
  elif [[ -f "$WORK_DIR/pom.xml" || -f "$WORK_DIR/build.gradle" || -f "$WORK_DIR/build.gradle.kts" ]]; then
    PROJECT_TYPE="java"
  elif [[ -f "$WORK_DIR/composer.json" ]]; then
    PROJECT_TYPE="php"
  elif [[ -f "$WORK_DIR/Gemfile" ]]; then
    PROJECT_TYPE="ruby"
  elif [[ -f "$WORK_DIR/Cargo.toml" ]]; then
    PROJECT_TYPE="rust"
  elif [[ -n "$(ls "$WORK_DIR"/*.csproj 2>/dev/null || true)" || -f "$WORK_DIR/global.json" ]]; then
    PROJECT_TYPE=".net"
  fi
  log "Detected project type: $PROJECT_TYPE"
}

set_default_port() {
  if [[ -n "${PORT:-}" ]]; then
    APP_PORT="$PORT"
    export PORT="$APP_PORT"
    return
  fi

  case "$PROJECT_TYPE" in
    python)
      # Heuristic based on common frameworks
      if [[ -f "$WORK_DIR/requirements.txt" ]] && grep -qi 'flask' "$WORK_DIR/requirements.txt"; then
        APP_PORT="5000"
      elif [[ -f "$WORK_DIR/pyproject.toml" ]] && grep -qi 'flask' "$WORK_DIR/pyproject.toml"; then
        APP_PORT="5000"
      elif [[ -f "$WORK_DIR/requirements.txt" ]] && grep -qi 'django' "$WORK_DIR/requirements.txt"; then
        APP_PORT="8000"
      else
        APP_PORT="8000"
      fi
      ;;
    node)
      APP_PORT="3000"
      ;;
    go|java|rust|.net)
      APP_PORT="8080"
      ;;
    php)
      APP_PORT="8000"
      ;;
    ruby)
      APP_PORT="3000"
      ;;
    *)
      APP_PORT="3000"
      ;;
  esac
  export PORT="$APP_PORT"
}

ensure_node() {
  if has_cmd node && has_cmd npm; then
    log "Node.js already present: $(node -v)"
    return
  fi
  log "Installing Node.js (LTS)..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) NODE_ARCH="x64" ;;
    aarch64|arm64) NODE_ARCH="arm64" ;;
    armv7l|armhf) NODE_ARCH="armv7l" ;;
    *) NODE_ARCH="x64"; warn "Unknown arch $ARCH, defaulting to x64." ;;
  esac
  NODE_VERSION="${NODE_VERSION:-20.11.1}" # LTS as default, can override
  NODE_BASE_URL="https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$NODE_ARCH.tar.xz"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  curl -fsSL "$NODE_BASE_URL" -o "$TMP_DIR/node.tar.xz"
  mkdir -p /usr/local/node
  tar -xJf "$TMP_DIR/node.tar.xz" -C /usr/local/node --strip-components=1
  ln -sf /usr/local/node/bin/node /usr/local/bin/node || true
  ln -sf /usr/local/node/bin/npm /usr/local/bin/npm || true
  ln -sf /usr/local/node/bin/npx /usr/local/bin/npx || true
  log "Installed Node.js $(node -v)"
}

ensure_go() {
  if has_cmd go; then
    log "Go already present: $(go version)"
    return
  fi
  log "Installing Go..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    armv6l) GO_ARCH="armv6l" ;;
    armv7l|armhf) GO_ARCH="armv6l" ;;
    *) GO_ARCH="amd64"; warn "Unknown arch $ARCH, defaulting to amd64." ;;
  esac
  GO_VERSION="${GO_VERSION:-1.22.5}"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  curl -fsSL "https://golang.org/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o "$TMP_DIR/go.tgz"
  tar -xzf "$TMP_DIR/go.tgz" -C /usr/local
  ln -sf /usr/local/go/bin/go /usr/local/bin/go || true
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt || true
  log "Installed $(go version)"
}

ensure_java() {
  if has_cmd java && has_cmd javac; then
    log "Java already present: $(java -version 2>&1 | head -n1)"
  else
    log "Installing OpenJDK..."
    case "$PKG_MGR" in
      apt) pm_install openjdk-17-jdk ;;
      apk) pm_install openjdk17 ;;
      yum|dnf) pm_install java-17-openjdk java-17-openjdk-devel ;;
    esac
    log "Installed Java: $(java -version 2>&1 | head -n1)"
  fi
  # Maven/Gradle
  if [[ -f "$WORK_DIR/pom.xml" ]]; then
    if ! has_cmd mvn; then
      log "Installing Maven..."
      case "$PKG_MGR" in
        apt) pm_install maven ;;
        apk) pm_install maven ;;
        yum|dnf) pm_install maven ;;
      esac
    fi
  elif [[ -f "$WORK_DIR/build.gradle" || -f "$WORK_DIR/build.gradle.kts" ]]; then
    if ! has_cmd gradle; then
      log "Installing Gradle..."
      case "$PKG_MGR" in
        apt) pm_install gradle ;;
        apk) pm_install gradle ;;
        yum|dnf) pm_install gradle ;;
      esac
    fi
  fi
}

ensure_php() {
  if has_cmd php; then
    log "PHP present: $(php -v | head -n1)"
  else
    log "Installing PHP..."
    case "$PKG_MGR" in
      apt) pm_install php php-cli php-mbstring php-zip php-xml php-curl ;;
      apk) pm_install php81 php81-cli php81-mbstring php81-zip php81-xml php81-curl || pm_install php php-cli php-mbstring php-zip php-xml php-curl ;;
      yum|dnf) pm_install php php-cli php-mbstring php-zip php-xml php-curl ;;
    esac
  fi
  if ! has_cmd composer; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
}

ensure_ruby() {
  if has_cmd ruby; then
    log "Ruby present: $(ruby -v)"
  else
    log "Installing Ruby..."
    case "$PKG_MGR" in
      apt) pm_install ruby-full build-essential ;;
      apk) pm_install ruby ruby-dev build-base ;;
      yum|dnf) pm_install ruby ruby-devel gcc make ;;
    esac
  fi
  if ! has_cmd bundle; then
    gem install bundler --no-document || true
  fi
}

ensure_rust() {
  if has_cmd cargo && has_cmd rustc; then
    log "Rust present: $(rustc --version)"
    return
  fi
  log "Installing Rust (rustup)..."
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
  sh /tmp/rustup.sh -y --default-toolchain stable
  rm -f /tmp/rustup.sh
  export PATH="$HOME/.cargo/bin:/root/.cargo/bin:$PATH"
  ln -sf "$HOME/.cargo/bin/rustc" /usr/local/bin/rustc || true
  ln -sf "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo || true
  log "Installed Rust: $(rustc --version)"
}

ensure_dotnet() {
  if has_cmd dotnet; then
    log ".NET SDK present: $(dotnet --version)"
    return
  fi
  warn "Installing .NET SDK requires Microsoft repos; attempting minimal setup."
  case "$PKG_MGR" in
    apt)
      pm_install wget apt-transport-https
      wget -q https://packages.microsoft.com/config/"$OS_ID"/"$OS_VERSION_ID"/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
      if [[ -f /tmp/packages-microsoft-prod.deb ]]; then
        dpkg -i /tmp/packages-microsoft-prod.deb || true
        rm -f /tmp/packages-microsoft-prod.deb
        pm_update
        pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || true
      fi
      ;;
    yum|dnf)
      rpm -Uvh https://packages.microsoft.com/config/"$OS_ID"/"$OS_VERSION_ID"/packages-microsoft-prod.rpm || true
      pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || true
      ;;
    apk)
      warn ".NET installation on Alpine via this script is not guaranteed. Skipping."
      ;;
    *)
      warn "Unsupported for .NET install. Skipping."
      ;;
  esac
}

python_setup() {
  log "Setting up Python environment..."
  PY_BIN="${PY_BIN:-python3}"

  if ! has_cmd "$PY_BIN"; then
    err "Python3 not available after installation."
    exit 1
  fi

  # Create or reuse venv
  VENV_PATH="${PYTHON_VENV_PATH:-$WORK_DIR/.venv}"
  if [[ ! -d "$VENV_PATH" ]]; then
    "$PY_BIN" -m venv "$VENV_PATH"
  fi
  # shellcheck source=/dev/null
  . "$VENV_PATH/bin/activate"

  python -m pip install --upgrade pip setuptools wheel

  if [[ -f "$WORK_DIR/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "$WORK_DIR/requirements.txt"
  elif [[ -f "$WORK_DIR/pyproject.toml" ]]; then
    # Try PEP 517 build
    log "Installing Python project via pyproject.toml (using pip)"
    pip install .
    # If using poetry/pdm, try auto install if lockfiles present
    if [[ -f "$WORK_DIR/poetry.lock" ]]; then
      pip install poetry && (cd "$WORK_DIR" && poetry install --no-root)
    fi
    if [[ -f "$WORK_DIR/pdm.lock" ]]; then
      pip install pdm && (cd "$WORK_DIR" && pdm install --no-self)
    fi
  else
    warn "No Python dependency files found."
  fi

  # Common runtime env vars
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1
  export VIRTUAL_ENV="$VENV_PATH"
  export PATH="$VENV_PATH/bin:$PATH"
}

node_setup() {
  log "Setting up Node.js environment..."
  ensure_node
  export PATH="/usr/local/node/bin:$PATH"

  if [[ -f "$WORK_DIR/package-lock.json" ]]; then
    (cd "$WORK_DIR" && npm ci)
  elif [[ -f "$WORK_DIR/yarn.lock" ]]; then
    npm -g install yarn
    (cd "$WORK_DIR" && yarn install --frozen-lockfile || yarn install)
  elif [[ -f "$WORK_DIR/pnpm-lock.yaml" ]]; then
    npm -g install pnpm
    (cd "$WORK_DIR" && pnpm install --frozen-lockfile || pnpm install)
  elif [[ -f "$WORK_DIR/package.json" ]]; then
    (cd "$WORK_DIR" && npm install)
  else
    warn "No Node.js dependency files found."
  fi

  export NODE_ENV="${NODE_ENV:-production}"
}

go_setup() {
  log "Setting up Go environment..."
  ensure_go
  export GOROOT="/usr/local/go"
  export GOPATH="${GOPATH:-/go}"
  mkdir -p "$GOPATH"
  export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
  if [[ -f "$WORK_DIR/go.mod" ]]; then
    (cd "$WORK_DIR" && go mod download)
  fi
}

java_setup() {
  log "Setting up Java environment..."
  ensure_java
  if [[ -f "$WORK_DIR/pom.xml" ]]; then
    (cd "$WORK_DIR" && mvn -B -q -DskipTests dependency:resolve || true)
  elif [[ -f "$WORK_DIR/build.gradle" || -f "$WORK_DIR/build.gradle.kts" ]]; then
    (cd "$WORK_DIR" && gradle --no-daemon build -x test || true)
  fi
}

php_setup() {
  log "Setting up PHP environment..."
  ensure_php
  if [[ -f "$WORK_DIR/composer.json" ]]; then
    (cd "$WORK_DIR" && composer install --no-dev --no-interaction || composer install --no-interaction)
  fi
}

ruby_setup() {
  log "Setting up Ruby environment..."
  ensure_ruby
  if [[ -f "$WORK_DIR/Gemfile" ]]; then
    (cd "$WORK_DIR" && bundle config set without 'development test' && bundle install)
  fi
}

rust_setup() {
  log "Setting up Rust environment..."
  ensure_rust
  if [[ -f "$WORK_DIR/Cargo.toml" ]]; then
    (cd "$WORK_DIR" && cargo fetch)
  fi
}

dotnet_setup() {
  log "Setting up .NET environment..."
  ensure_dotnet
  local csproj
  csproj="$(ls "$WORK_DIR"/*.csproj 2>/dev/null | head -n1 || true)"
  if [[ -n "$csproj" ]] && has_cmd dotnet; then
    (cd "$WORK_DIR" && dotnet restore)
  fi
}

configure_runtime_env() {
  export APP_HOME="$WORK_DIR"
  export APP_ENV="$APP_ENV"
  set_default_port
  export PATH="/usr/local/bin:$PATH"

  # Additional common env
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"

  log "Environment configured: APP_HOME=$APP_HOME, APP_ENV=$APP_ENV, PORT=$PORT"
}

ownership_permissions() {
  # If non-root user requested, ensure directories are accessible
  if [[ "$CREATE_USER" == "true" ]]; then
    local user="${RUN_AS_USER:-appuser}"
    chown -R "$user":"$user" "$WORK_DIR"
  else
    chown -R root:root "$WORK_DIR"
  fi
}

post_setup_instructions() {
  log "Environment setup completed successfully."
  log "Detected project type: $PROJECT_TYPE"
  case "$PROJECT_TYPE" in
    python)
      log "To run (example): source \"$WORK_DIR/.venv/bin/activate\" && python \"$WORK_DIR/app.py\""
      ;;
    node)
      log "To run (example): cd \"$WORK_DIR\" && npm start"
      ;;
    go)
      log "To run (example): cd \"$WORK_DIR\" && go run ."
      ;;
    java)
      log "To run (example): use mvn spring-boot:run or gradle bootRun depending on the project."
      ;;
    php)
      log "To run (example): php -S 0.0.0.0:$PORT -t \"$WORK_DIR\""
      ;;
    ruby)
      log "To run (example): cd \"$WORK_DIR\" && bundle exec rails server -b 0.0.0.0 -p \"$PORT\""
      ;;
    rust)
      log "To run (example): cd \"$WORK_DIR\" && cargo run"
      ;;
    .net)
      log "To run (example): cd \"$WORK_DIR\" && dotnet run --urls http://0.0.0.0:$PORT"
      ;;
    *)
      log "Generic run hint: ensure your entrypoint uses PORT=$PORT and binds to 0.0.0.0."
      ;;
  esac
}

setup_timeout_wrapper() {
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/timeout <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Locate the real timeout binary
REAL_TIMEOUT=""
if command -v -p timeout >/dev/null 2>&1; then
  REAL_TIMEOUT="$(command -v -p timeout)"
fi
if [[ -z "${REAL_TIMEOUT}" || "${REAL_TIMEOUT}" == "$0" ]]; then
  for p in /usr/bin/timeout /bin/timeout; do
    if [[ -x "$p" && "$p" != "$0" ]]; then REAL_TIMEOUT="$p"; break; fi
  done
fi
if [[ -z "${REAL_TIMEOUT}" ]]; then
  echo "Real timeout binary not found" >&2
  exit 127
fi

# Parse options up to duration
args=("$@")
opts=()
i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  if [[ "$a" == "--" ]]; then
    opts+=("$a")
    ((i++))
    break
  fi
  if [[ "$a" == -* ]]; then
    opts+=("$a")
    ((i++))
    if [[ "$a" == "-k" && $i -lt ${#args[@]} ]]; then
      opts+=("${args[$i]}")
      ((i++))
    fi
    continue
  fi
  break
done

if (( i >= ${#args[@]} )); then
  exec "$REAL_TIMEOUT" "$@"
fi

duration="${args[$i]}"; ((i++))
if (( i >= ${#args[@]} )); then
  exec "$REAL_TIMEOUT" "$@"
fi

cmd="${args[$i]}"

is_compound=0
case "$cmd" in
  if|'['|'{'|'(') is_compound=1 ;;
esac

if (( is_compound == 1 )); then
  cmd_str=
  for (( j=i; j<${#args[@]}; j++ )); do
    token_escaped=$(printf '%q' "${args[$j]}")
    if [[ -z "$cmd_str" ]]; then
      cmd_str="$token_escaped"
    else
      cmd_str="$cmd_str $token_escaped"
    fi
  done
  exec "$REAL_TIMEOUT" "${opts[@]}" "$duration" bash -lc "$cmd_str"
else
  exec "$REAL_TIMEOUT" "$@"
fi
EOF
  chmod +x /usr/local/bin/timeout
}

setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  if ! grep -q "auto-activate app venv" "$bashrc_file" 2>/dev/null; then
    cat >> "$bashrc_file" <<'EOF'
# auto-activate app venv
if [ -d /app/.venv ] && [ -x /app/.venv/bin/activate ]; then
  . /app/.venv/bin/activate
fi
# auto-activate app venv
EOF
  fi
}

ensure_base_runtime() {
  set -eux; mkdir -p /bin /usr/bin /usr/local/bin; ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) BB_URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-x86_64" ;; aarch64|arm64) BB_URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-aarch64" ;; armv7l|armhf) BB_URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-armv7l" ;; *) BB_URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-x86_64" ;; esac; if [ ! -x /usr/local/bin/busybox ]; then if command -v curl >/dev/null 2>&1; then curl -fsSL "$BB_URL" -o /usr/local/bin/busybox || curl -kfsSL "$BB_URL" -o /usr/local/bin/busybox; elif command -v wget >/dev/null 2>&1; then wget -qO /usr/local/bin/busybox "$BB_URL" || wget --no-check-certificate -qO /usr/local/bin/busybox "$BB_URL"; elif command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y --no-install-recommends ca-certificates curl wget && (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true); curl -fsSL "$BB_URL" -o /usr/local/bin/busybox || wget -qO /usr/local/bin/busybox "$BB_URL"; elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache ca-certificates curl wget && (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true); curl -fsSL "$BB_URL" -o /usr/local/bin/busybox || wget -qO /usr/local/bin/busybox "$BB_URL"; elif command -v dnf >/dev/null 2>&1; then dnf makecache -y && dnf install -y ca-certificates curl wget; curl -fsSL "$BB_URL" -o /usr/local/bin/busybox || wget -qO /usr/local/bin/busybox "$BB_URL"; elif command -v yum >/dev/null 2>&1; then yum makecache -y && yum install -y ca-certificates curl wget; curl -fsSL "$BB_URL" -o /usr/local/bin/busybox || wget -qO /usr/local/bin/busybox "$BB_URL"; elif command -v microdnf >/dev/null 2>&1; then microdnf -y install ca-certificates curl wget; curl -fsSL "$BB_URL" -o /usr/local/bin/busybox || wget -qO /usr/local/bin/busybox "$BB_URL"; else echo "No downloader available to fetch busybox" >&2; exit 1; fi; fi; chmod +x /usr/local/bin/busybox; [ -x /bin/sh ] || ln -sf /usr/local/bin/busybox /bin/sh; [ -x /usr/bin/env ] || ln -sf /usr/local/bin/busybox /usr/bin/env; [ -x /bin/bash ] || ln -sf /usr/local/bin/busybox /bin/bash; [ -x /bin/timeout ] || ln -sf /usr/local/bin/busybox /bin/timeout; /usr/local/bin/busybox --help >/dev/null 2>&1 || true
  set -eux; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y --no-install-recommends bash coreutils ca-certificates curl git wget tar xz-utils && (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true); elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache bash coreutils ca-certificates curl git wget tar xz && (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true); elif command -v dnf >/dev/null 2>&1; then dnf makecache -y && dnf install -y bash coreutils ca-certificates curl git wget tar xz; elif command -v yum >/dev/null 2>&1; then yum makecache -y && yum install -y bash coreutils ca-certificates curl git wget tar xz; elif command -v microdnf >/dev/null 2>&1; then microdnf -y install bash coreutils ca-certificates curl git wget tar xz; else echo "No supported package manager found; keeping BusyBox sh/env only" >&2; fi; if command -v bash >/dev/null 2>&1; then ln -sf "$(command -v bash)" /bin/bash; fi; if command -v env >/dev/null 2>&1; then ln -sf "$(command -v env)" /usr/bin/env || true; fi; if ! command -v timeout >/dev/null 2>&1 && [ -x /usr/local/bin/busybox ]; then ln -sf /usr/local/bin/busybox /bin/timeout; fi; /bin/sh -c 'echo SH READY' || true; /bin/bash -lc 'echo BASH READY' || true
}

main() {
  ensure_root
  ensure_base_runtime
  detect_os
  setup_directories
  ensure_packages
  maybe_create_user
  load_env_file
  detect_project_type
  configure_runtime_env
  setup_timeout_wrapper

  case "$PROJECT_TYPE" in
    python) python_setup ;;
    node) node_setup ;;
    go) go_setup ;;
    java) java_setup ;;
    php) php_setup ;;
    ruby) ruby_setup ;;
    rust) rust_setup ;;
    .net) dotnet_setup ;;
    *)
      warn "No recognized project type. Installed base tools only."
      ;;
  esac

  setup_auto_activate
  ownership_permissions
  post_setup_instructions
}

main "$@"