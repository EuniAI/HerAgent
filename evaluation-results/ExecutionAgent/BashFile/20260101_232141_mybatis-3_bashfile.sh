#!/usr/bin/env bash
# Universal Project Environment Setup Script for Docker containers
# This script detects common project types and installs/configures required runtimes and dependencies.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------
# Global configuration
# ----------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
UMASK_DEFAULT="0022"
export UMASK_DEFAULT
umask "$UMASK_DEFAULT"

# Colors (disabled if not a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# ----------------------------
# Logging and error handling
# ----------------------------
log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*${NC}" >&2; }
on_error() {
  error "An error occurred in ${SCRIPT_NAME} at line ${BASH_LINENO[0]} while executing: ${BASH_COMMAND}"
}
trap on_error ERR

# ----------------------------
# Privilege and environment detection
# ----------------------------
IS_ROOT=0
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  IS_ROOT=1
fi

# Installation prefixes and bin dirs
if [ "$IS_ROOT" -eq 1 ]; then
  PREFIX="/usr/local"
  USER_HOME="/root"
else
  USER_HOME="${HOME:-/tmp}"
  PREFIX="${HOME}/.local"
fi
BIN_DIR="${PREFIX}/bin"
mkdir -p "$BIN_DIR"

# Ensure cache/log/tmp dirs in project
mkdir -p "$PROJECT_ROOT"/{logs,tmp,.cache}
chmod -R u+rwX,go+rX "$PROJECT_ROOT"

# ----------------------------
# OS and Package Manager detection
# ----------------------------
OS_ID=""
OS_LIKE=""
PKG_MANAGER=""
determine_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi
}
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
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

pm_update() {
  [ "$IS_ROOT" -eq 1 ] || { warn "Cannot update package index without root privileges"; return 0; }
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      # apk updates repos on add by default
      true
      ;;
    microdnf)
      microdnf -y update || true
      ;;
    dnf)
      dnf -y makecache || true
      ;;
    yum)
      yum -y makecache || true
      ;;
    zypper)
      zypper --non-interactive refresh || true
      ;;
    *)
      warn "No known package manager detected"
      ;;
  esac
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  [ "$#" -gt 0 ] || return 0
  if [ "$IS_ROOT" -ne 1 ]; then
    warn "Skipping system package installation (not running as root). Missing packages: $*"
    return 0
  fi
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    microdnf)
      microdnf install -y "$@" || dnf install -y "$@" || yum install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
    *)
      warn "No known package manager detected; cannot install: $*"
      ;;
  esac
}

pm_clean() {
  [ "$IS_ROOT" -eq 1 ] || return 0
  case "$PKG_MANAGER" in
    apt)
      apt-get clean
      : # keep apt lists for later installs
      ;;
    apk)
      # no cleanup needed; using --no-cache
      true
      ;;
    microdnf)
      microdnf clean all || true
      ;;
    dnf)
      dnf clean all || true
      ;;
    yum)
      yum clean all || true
      ;;
    zypper)
      zypper clean -a || true
      ;;
  esac
}

# ----------------------------
# Networking utility
# ----------------------------
have_network() {
  # Quick check: try to resolve and connect to a common endpoint
  command -v curl >/dev/null 2>&1 || return 0
  curl -sSfI --connect-timeout 5 https://www.google.com >/dev/null 2>&1 || return 1
  return 0
}

# ----------------------------
# Base tools installation
# ----------------------------
install_base_tools() {
  log "Ensuring base system tools are installed"
  determine_os
  detect_pkg_manager
  pm_update
  case "$PKG_MANAGER" in
    apt)
      pm_install ca-certificates curl git gnupg tar xz-utils unzip gzip procps openssh-client make gcc g++ build-essential pkg-config bash coreutils findutils
      update-ca-certificates || true
      ;;
    apk)
      pm_install ca-certificates curl git tar xz unzip gzip coreutils findutils openssh-client bash build-base pkgconfig
      update-ca-certificates || true
      ;;
    microdnf|dnf|yum)
      pm_install ca-certificates curl git tar xz unzip gzip procps-ng openssh-clients make gcc gcc-c++ which pkgconfig shadow-utils findutils
      update-ca-trust || true
      ;;
    zypper)
      pm_install ca-certificates curl git tar xz unzip gzip which procps openssh make gcc gcc-c++ pkg-config findutils
      update-ca-certificates || true
      ;;
    *)
      warn "Unknown package manager; assuming required tools are present"
      ;;
  esac
  pm_clean
}

# ----------------------------
# Architecture detection helper
# ----------------------------
detect_arch() {
  local uname_m
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7l" ;;
    *) echo "$uname_m" ;;
  esac
}

# ----------------------------
# Environment persistence
# ----------------------------
ENV_FILE="$PROJECT_ROOT/.env.container"
persist_env_var() {
  local name="$1"; shift
  local value="$*"
  grep -qE "^export ${name}=" "$ENV_FILE" 2>/dev/null && sed -i "s|^export ${name}=.*$|export ${name}=${value}|g" "$ENV_FILE" || echo "export ${name}=${value}" >> "$ENV_FILE"
}
ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "# Auto-generated by ${SCRIPT_NAME} - container environment" > "$ENV_FILE"
    echo "export PROJECT_ROOT=\"$PROJECT_ROOT\"" >> "$ENV_FILE"
    echo "export APP_ENV=\"${APP_ENV:-production}\"" >> "$ENV_FILE"
  fi
}

# Ensure PATH contains our prefixes
ensure_paths() {
  ensure_env_file
  case ":$PATH:" in
    *":$BIN_DIR:"*) : ;;
    *) export PATH="$BIN_DIR:$PATH" ;;
  esac
  persist_env_var PATH "\"$BIN_DIR:\$PATH\""
}

# ----------------------------
# Python setup
# ----------------------------
setup_python() {
  local need_python=0
  if [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ]; then
    need_python=1
  fi
  [ "$need_python" -eq 1 ] || return 0
  log "Configuring Python environment"
  # Install python and build deps
  case "$PKG_MANAGER" in
    apt)
      pm_install python3 python3-venv python3-pip python3-dev build-essential
      ;;
    apk)
      pm_install python3 py3-pip python3-dev musl-dev gcc
      ;;
    microdnf|dnf|yum)
      pm_install python3 python3-pip python3-devel gcc make redhat-rpm-config
      ;;
    zypper)
      pm_install python3 python3-pip python3-devel gcc make
      ;;
  esac
  pm_clean

  # Create venv
  local venv_dir="$PROJECT_ROOT/.venv"
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
  fi
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  pip install --no-cache-dir --upgrade pip setuptools wheel

  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    pip install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt"
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    # Try to install project (PEP 517)
    pip install --no-cache-dir .
  elif [ -f "$PROJECT_ROOT/setup.py" ]; then
    pip install --no-cache-dir -e .
  fi

  ensure_env_file
  persist_env_var VIRTUAL_ENV "\"$venv_dir\""
  persist_env_var PATH "\"$venv_dir/bin:\$PATH\""
  persist_env_var PYTHONPATH "\"$PROJECT_ROOT:\$PYTHONPATH\""
  log "Python setup complete"
}

# ----------------------------
# Node.js setup
# ----------------------------
setup_node() {
  local need_node=0
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    need_node=1
  fi
  [ "$need_node" -eq 1 ] || return 0
  log "Configuring Node.js environment"

  # Determine Node version
  local NODE_VERSION="${NODE_VERSION:-}"
  if [ -z "$NODE_VERSION" ] && [ -f "$PROJECT_ROOT/.nvmrc" ]; then
    NODE_VERSION="$(tr -d 'v' < "$PROJECT_ROOT/.nvmrc" | tr -d ' \t\r\n')"
  fi
  if [ -z "$NODE_VERSION" ]; then
    NODE_VERSION="20.18.0"  # default LTS fallback
  fi

  local arch; arch="$(detect_arch)"
  local node_install_dir="${PREFIX}/node-v${NODE_VERSION}"
  local node_symlink="${PREFIX}/node"
  local node_bin="${node_symlink}/bin"

  install_node_binary() {
    local url="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz"
    local tmp="${PROJECT_ROOT}/tmp/node-v${NODE_VERSION}-linux-${arch}.tar.xz"
    mkdir -p "$(dirname "$tmp")"
    log "Downloading Node.js v${NODE_VERSION} (${arch})"
    curl -fsSL "$url" -o "$tmp"
    rm -rf "$node_install_dir"
    mkdir -p "$node_install_dir"
    tar -xJf "$tmp" -C "$node_install_dir" --strip-components=1
    rm -f "$tmp"
    rm -f "$node_symlink"
    ln -s "$node_install_dir" "$node_symlink"
    # Create bin symlinks into BIN_DIR for convenience
    mkdir -p "$BIN_DIR"
    ln -sf "${node_bin}/node" "$BIN_DIR/node"
    ln -sf "${node_bin}/npm" "$BIN_DIR/npm"
    ln -sf "${node_bin}/npx" "$BIN_DIR/npx"
    ln -sf "${node_bin}/corepack" "$BIN_DIR/corepack"
  }

  # Decide whether to install/upgrade
  if command -v node >/dev/null 2>&1; then
    current="$(node -v | tr -d 'v')"
    if [ "$current" != "$NODE_VERSION" ]; then
      log "Node.js version $current found; installing requested $NODE_VERSION"
      install_node_binary
    else
      log "Node.js v$NODE_VERSION already installed"
    fi
  else
    install_node_binary
  fi

  # Ensure PATH includes node bin
  export PATH="$node_bin:$PATH"
  ensure_env_file
  persist_env_var PATH "\"$node_bin:\$PATH\""

  # Enable corepack for yarn/pnpm
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Install JS dependencies depending on lockfile and tool
  pushd "$PROJECT_ROOT" >/dev/null
  local install_flags=""
  if [ "${NODE_ENV:-}" = "production" ] || grep -qi '"type": "module"' package.json >/dev/null 2>&1; then
    :
  fi
  if [ -f "pnpm-lock.yaml" ]; then
    corepack prepare pnpm@latest --activate || true
    if command -v pnpm >/dev/null 2>&1; then
      if [ "${NODE_ENV:-}" = "production" ]; then install_flags="--frozen-lockfile --prod"; else install_flags="--frozen-lockfile"; fi
      pnpm install $install_flags
    else
      warn "pnpm not available; falling back to npm"
      npm install
    fi
  elif [ -f "yarn.lock" ]; then
    corepack prepare yarn@stable --activate || true
    if command -v yarn >/dev/null 2>&1; then
      if [ "${NODE_ENV:-}" = "production" ]; then install_flags="--frozen-lockfile --production"; else install_flags="--frozen-lockfile"; fi
      yarn install $install_flags
    else
      warn "yarn not available; falling back to npm"
      npm install
    fi
  else
    if [ -f "package-lock.json" ]; then
      if [ "${NODE_ENV:-}" = "production" ]; then install_flags="--omit=dev"; fi
      npm ci $install_flags
    else
      if [ "${NODE_ENV:-}" = "production" ]; then install_flags="--omit=dev"; fi
      npm install $install_flags
    fi
  fi
  popd >/dev/null

  log "Node.js setup complete"
}

# ----------------------------
# Ruby setup
# ----------------------------
setup_ruby() {
  local need_ruby=0
  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    need_ruby=1
  fi
  [ "$need_ruby" -eq 1 ] || return 0
  log "Configuring Ruby environment"

  case "$PKG_MANAGER" in
    apt)
      pm_install ruby-full build-essential
      ;;
    apk)
      pm_install ruby ruby-dev build-base
      ;;
    microdnf|dnf|yum)
      pm_install ruby ruby-devel gcc make redhat-rpm-config
      ;;
    zypper)
      pm_install ruby ruby-devel gcc make
      ;;
  esac
  pm_clean

  if ! command -v gem >/dev/null 2>&1; then
    error "Ruby gem command not found after installation"
    return 1
  fi

  gem install --no-document bundler || true
  pushd "$PROJECT_ROOT" >/dev/null
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs "$(nproc 2>/dev/null || echo 2)"
  popd >/dev/null

  log "Ruby setup complete"
}

# ----------------------------
# Java (Maven/Gradle) setup
# ----------------------------
setup_java() {
  local need_java=0 use_maven=0 use_gradle=0
  if [ -f "$PROJECT_ROOT/pom.xml" ]; then use_maven=1; need_java=1; fi
  if [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/build.gradle.kts" ] || [ -f "$PROJECT_ROOT/gradlew" ]; then use_gradle=1; need_java=1; fi
  [ "$need_java" -eq 1 ] || return 0
  log "Configuring Java environment"

  # Ensure package indices are current before installing Java packages
  pm_update

  case "$PKG_MANAGER" in
    apt)
      pm_install default-jdk unzip
      ;;
    apk)
      pm_install openjdk17-jdk maven unzip
      ;;
    microdnf|dnf|yum)
      pm_install java-17-openjdk-devel maven unzip
      ;;
    zypper)
      pm_install java-17-openjdk-devel maven unzip
      ;;
  esac
  pm_clean

  # Ensure JDK is available; install Temurin 21 if javac missing
  if [ "$IS_ROOT" -eq 1 ]; then
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) ARCH="x64" ;;
      aarch64|arm64) ARCH="aarch64" ;;
      *) ARCH="x64" ;;
    esac
    if ! command -v javac >/dev/null 2>&1; then
      curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/$ARCH/jdk/hotspot/normal/eclipse" -o /tmp/temurin.tar.gz
      mkdir -p /usr/local/temurin-21
      tar -xzf /tmp/temurin.tar.gz -C /usr/local/temurin-21 --strip-components=1
      ln -sf /usr/local/temurin-21/bin/java /usr/local/bin/java
      ln -sf /usr/local/temurin-21/bin/javac /usr/local/bin/javac
      rm -f /tmp/temurin.tar.gz
    fi
  fi

  # Ensure Maven is available (install Apache Maven if missing)
  if [ "$use_maven" -eq 1 ] && [ "$IS_ROOT" -eq 1 ] && ! command -v mvn >/dev/null 2>&1; then
    MAVEN_VERSION="3.9.9"
    MAVEN_DIR="/usr/local/apache-maven-$MAVEN_VERSION"
    if [ ! -d "$MAVEN_DIR" ]; then
      curl -fsSL "https://archive.apache.org/dist/maven/maven-3/$MAVEN_VERSION/binaries/apache-maven-$MAVEN_VERSION-bin.tar.gz" -o /tmp/maven.tar.gz
      tar -xzf /tmp/maven.tar.gz -C /usr/local
      ln -sf "$MAVEN_DIR" /usr/local/apache-maven
      ln -sf /usr/local/apache-maven/bin/mvn /usr/local/bin/mvn
      rm -f /tmp/maven.tar.gz
    else
      ln -sf "$MAVEN_DIR" /usr/local/apache-maven
      ln -sf /usr/local/apache-maven/bin/mvn /usr/local/bin/mvn
    fi
  fi

  export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  ensure_env_file
  persist_env_var JAVA_HOME "\"$JAVA_HOME\""
  persist_env_var PATH "\"$JAVA_HOME/bin:\$PATH\""

  pushd "$PROJECT_ROOT" >/dev/null
  if [ "$use_maven" -eq 1 ]; then
    if [ -x "./mvnw" ]; then
      ./mvnw -q -DskipTests dependency:go-offline || ./mvnw -q -DskipTests package -DskipTests
    else
      mvn -q -DskipTests dependency:go-offline || mvn -q -DskipTests package -DskipTests
    fi
  fi
  if [ "$use_gradle" -eq 1 ]; then
    if [ -x "./gradlew" ]; then
      ./gradlew --no-daemon build -x test || ./gradlew --no-daemon dependencies
    else
      case "$PKG_MANAGER" in
        apt|apk|microdnf|dnf|yum|zypper) pm_install gradle ;; *) warn "Gradle not found and cannot install automatically";;
      esac
      gradle --no-daemon build -x test || gradle --no-daemon dependencies || true
    fi
  fi
  popd >/dev/null

  log "Java setup complete"
}

# ----------------------------
# Go setup
# ----------------------------
setup_go() {
  local need_go=0
  if [ -f "$PROJECT_ROOT/go.mod" ]; then need_go=1; fi
  [ "$need_go" -eq 1 ] || return 0
  log "Configuring Go environment"

  local GO_VERSION="${GO_VERSION:-}"
  if [ -z "$GO_VERSION" ] && [ -f "$PROJECT_ROOT/go.mod" ]; then
    GO_VERSION="$(grep -E '^go [0-9]+\.[0-9]+' "$PROJECT_ROOT/go.mod" | awk '{print $2}' | head -n1 || true)"
  fi
  if [ -z "$GO_VERSION" ]; then
    GO_VERSION="1.22.10"
  fi

  local arch_raw; arch_raw="$(uname -m)"
  local arch="amd64"
  case "$arch_raw" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7) arch="armv6l" ;;
    *) arch="amd64" ;;
  esac

  local go_root=""
  if [ "$IS_ROOT" -eq 1 ]; then
    go_root="/usr/local/go"
  else
    go_root="${PREFIX}/go"
  fi

  install_go() {
    local url="https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"
    local tmp="${PROJECT_ROOT}/tmp/go${GO_VERSION}.linux-${arch}.tar.gz"
    curl -fsSL "$url" -o "$tmp"
    rm -rf "$go_root"
    mkdir -p "$(dirname "$go_root")"
    tar -xzf "$tmp" -C "$(dirname "$go_root")"
    if [ "$IS_ROOT" -ne 1 ]; then
      mv "$(dirname "$go_root")/go" "$go_root"
    fi
    rm -f "$tmp"
    ln -sf "$go_root/bin/go" "$BIN_DIR/go"
  }

  if command -v go >/dev/null 2>&1; then
    current="$(go version | awk '{print $3}' | sed 's/^go//')"
    if [ "$current" != "$GO_VERSION" ]; then
      log "Go $current found; installing requested $GO_VERSION"
      install_go
    else
      log "Go $GO_VERSION already installed"
    fi
  else
    install_go
  fi

  export GOROOT="$go_root"
  export GOPATH="${GOPATH:-$PROJECT_ROOT/.gopath}"
  mkdir -p "$GOPATH"/{bin,pkg,src}
  ensure_env_file
  persist_env_var GOROOT "\"$GOROOT\""
  persist_env_var GOPATH "\"$GOPATH\""
  persist_env_var PATH "\"$GOROOT/bin:\$GOPATH/bin:\$PATH\""

  pushd "$PROJECT_ROOT" >/dev/null
  go env -w GOPATH="$GOPATH" || true
  go env -w GOMODCACHE="$GOPATH/pkg/mod" || true
  go mod download
  popd >/dev/null

  log "Go setup complete"
}

# ----------------------------
# Rust setup
# ----------------------------
setup_rust() {
  local need_rust=0
  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then need_rust=1; fi
  [ "$need_rust" -eq 1 ] || return 0
  log "Configuring Rust environment"

  local cargo_bin="${USER_HOME}/.cargo/bin"
  if [ ! -x "${cargo_bin}/cargo" ]; then
    curl -fsSL https://sh.rustup.rs -o "$PROJECT_ROOT/tmp/rustup.sh"
    sh "$PROJECT_ROOT/tmp/rustup.sh" -y --default-toolchain stable --profile minimal
  fi
  # shellcheck disable=SC1090
  [ -f "${USER_HOME}/.cargo/env" ] && . "${USER_HOME}/.cargo/env"
  mkdir -p "$BIN_DIR"
  ln -sf "${cargo_bin}/cargo" "$BIN_DIR/cargo" || true
  ln -sf "${cargo_bin}/rustc" "$BIN_DIR/rustc" || true

  ensure_env_file
  persist_env_var PATH "\"${cargo_bin}:\$PATH\""

  pushd "$PROJECT_ROOT" >/dev/null
  cargo fetch
  popd >/dev/null

  log "Rust setup complete"
}

# ----------------------------
# PHP setup
# ----------------------------
setup_php() {
  local need_php=0
  if [ -f "$PROJECT_ROOT/composer.json" ]; then need_php=1; fi
  [ "$need_php" -eq 1 ] || return 0
  log "Configuring PHP environment"

  case "$PKG_MANAGER" in
    apt)
      pm_install php-cli php-zip php-mbstring php-xml php-curl php-intl unzip git
      ;;
    apk)
      # Package names may vary by Alpine version; try common ones
      pm_install php php-cli php-zip php-mbstring php-xml php-curl php-intl php-openssl unzip git || true
      ;;
    microdnf|dnf|yum)
      pm_install php-cli php-zip php-mbstring php-xml php-curl php-intl unzip git || true
      ;;
    zypper)
      pm_install php-cli php-zip php-mbstring php-xml php-curl php-intl unzip git || true
      ;;
  esac
  pm_clean

  # Install Composer if not available
  if ! command -v composer >/dev/null 2>&1; then
    local composer_bin="$BIN_DIR/composer"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir="$BIN_DIR" --filename="composer"
    rm -f composer-setup.php
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "composer.lock" ]; then
    composer install --no-interaction --prefer-dist --optimize-autoloader
  else
    composer update --no-interaction --prefer-dist --optimize-autoloader || composer install --no-interaction
  fi
  popd >/dev/null

  log "PHP setup complete"
}

# ----------------------------
# .NET setup
# ----------------------------
setup_dotnet() {
  local need_dotnet=0
  if compgen -G "$PROJECT_ROOT/*.sln" >/dev/null || compgen -G "$PROJECT_ROOT/*.csproj" >/dev/null; then
    need_dotnet=1
  fi
  [ "$need_dotnet" -eq 1 ] || return 0
  log "Configuring .NET environment"

  local dotnet_root="${USER_HOME}/.dotnet"
  mkdir -p "$dotnet_root"
  if [ ! -x "${dotnet_root}/dotnet" ]; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$PROJECT_ROOT/tmp/dotnet-install.sh"
    bash "$PROJECT_ROOT/tmp/dotnet-install.sh" --install-dir "$dotnet_root" --channel LTS --quality ga
  fi
  ln -sf "${dotnet_root}/dotnet" "$BIN_DIR/dotnet"
  ensure_env_file
  persist_env_var DOTNET_ROOT "\"$dotnet_root\""
  persist_env_var PATH "\"$dotnet_root:\$PATH\""

  pushd "$PROJECT_ROOT" >/dev/null
  if compgen -G "*.sln" >/dev/null; then
    for sln in *.sln; do
      dotnet restore "$sln"
    done
  else
    for proj in *.csproj; do
      dotnet restore "$proj"
    done
  fi
  popd >/dev/null

  log ".NET setup complete"
}

# ----------------------------
# Project directory setup and ownership
# ----------------------------
setup_project_structure() {
  log "Ensuring project directory structure and permissions"
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,.cache}
  chmod -R u+rwX,go+rX "$PROJECT_ROOT"/logs "$PROJECT_ROOT"/tmp "$PROJECT_ROOT"/.cache || true
  # Adjust ownership to current user if running as root and not inside read-only FS
  if [ "$IS_ROOT" -eq 1 ]; then
    chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$PROJECT_ROOT" 2>/dev/null || true
  fi
}

# ----------------------------
# Configuration and environment defaults
# ----------------------------
setup_runtime_env() {
  log "Configuring runtime environment variables"
  ensure_env_file
  persist_env_var APP_ENV "\"${APP_ENV:-production}\""
  persist_env_var PROJECT_ROOT "\"$PROJECT_ROOT\""
  # Append commonly used PATH entries for installed toolchains
  # Node
  if [ -d "${PREFIX}/node/bin" ]; then persist_env_var PATH "\"${PREFIX}/node/bin:\$PATH\""; fi
  # Go
  if [ -d "/usr/local/go/bin" ] || [ -d "${PREFIX}/go/bin" ]; then
    persist_env_var PATH "\"/usr/local/go/bin:${PREFIX}/go/bin:\$PATH\""
  fi
  # Cargo
  if [ -d "${USER_HOME}/.cargo/bin" ]; then persist_env_var PATH "\"${USER_HOME}/.cargo/bin:\$PATH\""; fi
  # Dotnet
  if [ -d "${USER_HOME}/.dotnet" ]; then persist_env_var PATH "\"${USER_HOME}/.dotnet:\$PATH\""; fi

  # Export variables for current shell too
  # shellcheck disable=SC1090
  source "$ENV_FILE"
}

# ----------------------------
# Shell auto-activation setup
# ----------------------------
setup_auto_activate() {
  local bashrc_file="${USER_HOME}/.bashrc"
  ensure_env_file
  local env_line="if [ -f \"$ENV_FILE\" ]; then . \"$ENV_FILE\"; fi"
  if ! grep -qF "$env_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-load project container environment" >> "$bashrc_file"
    echo "$env_line" >> "$bashrc_file"
  fi
  # Virtualenv auto-activation
  local venv_dir="$PROJECT_ROOT/.venv"
  local activate_line="if [ -d \"$venv_dir\" ]; then . \"$venv_dir/bin/activate\"; fi"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# ----------------------------
# Main entry
# ----------------------------
main() {
  log "Starting environment setup in $PROJECT_ROOT"
  install_base_tools
  ensure_paths
  setup_project_structure

  # Detect and setup for various project types (polyglot-friendly)
  setup_python
  setup_node
  setup_ruby
  setup_java
  setup_go
  setup_rust
  setup_php
  setup_dotnet

  setup_runtime_env
  setup_auto_activate

  log "Environment setup completed successfully"
  echo "To load environment variables in a shell, run: source \"$ENV_FILE\""
}

main "$@"