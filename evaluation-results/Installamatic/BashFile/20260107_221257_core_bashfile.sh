#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project stack(s) and installs required runtimes/dependencies
# - Installs system packages and tools across major distros (Debian/Ubuntu, Alpine, RHEL/CentOS/Fedora, SUSE)
# - Sets up project directories, permissions, and environment variables
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'

# ------------- Configuration (overridable via env) -------------
APP_DIR="${APP_DIR:-$PWD}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
CREATE_APP_USER="${CREATE_APP_USER:-true}"
DEFAULT_PORT="${PORT:-8080}"
DEBIAN_FRONTEND=noninteractive
UMASK_VAL="${UMASK_VAL:-0022}"

# ------------- Logging and error handling -------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
info() { echo -e "${BLUE}[*] $*${NC}"; }

on_error() {
  err "An error occurred on line ${BASH_LINENO[0]}. Aborting."
}
trap on_error ERR

# ------------- Helpers -------------
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
file_contains() { [ -f "$1" ] && grep -qE "$2" "$1"; }

# ------------- Detect package manager / distro -------------
PKG_MGR=""
OS_FAMILY=""
detect_pkg_manager() {
  if have_cmd apt-get; then
    PKG_MGR="apt"
    OS_FAMILY="debian"
  elif have_cmd apk; then
    PKG_MGR="apk"
    OS_FAMILY="alpine"
  elif have_cmd dnf; then
    PKG_MGR="dnf"
    OS_FAMILY="rhel"
  elif have_cmd yum; then
    PKG_MGR="yum"
    OS_FAMILY="rhel"
  elif have_cmd microdnf; then
    PKG_MGR="microdnf"
    OS_FAMILY="rhel"
  elif have_cmd zypper; then
    PKG_MGR="zypper"
    OS_FAMILY="suse"
  else
    PKG_MGR=""
    OS_FAMILY="unknown"
  fi
}

update_pkg_index() {
  case "$PKG_MGR" in
    apt)
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf -y makecache || true
      ;;
    yum)
      yum -y makecache || true
      ;;
    microdnf)
      microdnf -y update || true
      ;;
    zypper)
      zypper --non-interactive refresh || true
      ;;
    *)
      ;;
  esac
}

install_pkgs() {
  # Usage: install_pkgs pkg1 pkg2 ...
  case "$PKG_MGR" in
    apt)
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
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
    *)
      err "Unsupported package manager. Cannot install packages: $*"
      return 1
      ;;
  esac
}

install_build_essentials() {
  case "$PKG_MGR" in
    apt)
      install_pkgs build-essential gcc g++ make
      ;;
    apk)
      install_pkgs build-base
      ;;
    dnf|yum|microdnf)
      # @development-tools is a group; fallback to individual packages if group not available
      if have_cmd dnf; then dnf groupinstall -y "Development Tools" || true; fi
      if have_cmd yum; then yum groupinstall -y "Development Tools" || true; fi
      install_pkgs gcc gcc-c++ make || true
      ;;
    zypper)
      install_pkgs -t pattern devel_C_C++ || true
      install_pkgs gcc gcc-c++ make || true
      ;;
    *)
      ;;
  esac
}

install_base_tools() {
  log "Installing base tools and certificates..."
  case "$PKG_MGR" in
    apt)
      install_pkgs ca-certificates curl git unzip xz-utils tar gnupg
      update-ca-certificates || true
      ;;
    apk)
      install_pkgs ca-certificates curl git unzip xz tar gnupg
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      install_pkgs ca-certificates curl git unzip xz tar gnupg2 || install_pkgs ca-certificates curl git unzip xz tar gnupg
      update-ca-trust || true
      ;;
    zypper)
      install_pkgs ca-certificates curl git unzip xz tar gpg2 || install_pkgs ca-certificates curl git unzip xz tar gpg
      update-ca-certificates || true
      ;;
    *)
      warn "Unknown package manager; cannot ensure base tools are installed."
      ;;
  esac
}

# ------------- User/Group setup -------------
ensure_app_user() {
  if [ "${CREATE_APP_USER}" != "true" ]; then
    log "Skipping app user creation (CREATE_APP_USER=${CREATE_APP_USER})"
    return 0
  fi
  if ! is_root; then
    warn "Not running as root; cannot create user/group. Proceeding as current user."
    return 0
  fi

  case "$OS_FAMILY" in
    alpine)
      if ! getent group "$APP_GROUP" >/dev/null 2>&1; then addgroup -S "$APP_GROUP"; fi
      if ! id -u "$APP_USER" >/dev/null 2>&1; then adduser -S -G "$APP_GROUP" -s /bin/sh "$APP_USER"; fi
      ;;
    debian|rhel|suse|*)
      if ! getent group "$APP_GROUP" >/dev/null 2>&1; then groupadd -r "$APP_GROUP"; fi
      if ! id -u "$APP_USER" >/dev/null 2>&1; then useradd -m -r -g "$APP_GROUP" -s /bin/bash "$APP_USER"; fi
      ;;
  esac
}

ensure_dirs() {
  umask "$UMASK_VAL"
  mkdir -p "$APP_DIR"/{.cache,logs,tmp,data,build,dist}
  # Common dependency/cache dirs
  mkdir -p "$APP_DIR"/{.venv,node_modules,vendor/bundle}
  if is_root; then
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR"/.cache "$APP_DIR"/logs "$APP_DIR"/tmp "$APP_DIR"/data "$APP_DIR"/build "$APP_DIR"/dist "$APP_DIR"/.venv "$APP_DIR"/node_modules "$APP_DIR"/vendor || true
  fi
}

# ------------- Stack detection -------------
STACKS=()

detect_stacks() {
  log "Detecting project stacks in $APP_DIR ..."
  # Python
  if [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ] || [ -f "$APP_DIR/setup.py" ]; then
    STACKS+=("python")
  fi
  # Node.js
  if [ -f "$APP_DIR/package.json" ]; then
    STACKS+=("node")
  fi
  # Ruby
  if [ -f "$APP_DIR/Gemfile" ]; then
    STACKS+=("ruby")
  fi
  # Go
  if [ -f "$APP_DIR/go.mod" ]; then
    STACKS+=("go")
  fi
  # Rust
  if [ -f "$APP_DIR/Cargo.toml" ]; then
    STACKS+=("rust")
  fi
  # Java (Maven/Gradle)
  if [ -f "$APP_DIR/pom.xml" ]; then
    STACKS+=("java-maven")
  fi
  if ls "$APP_DIR"/build.gradle* >/dev/null 2>&1; then
    STACKS+=("java-gradle")
  fi
  # PHP (Composer)
  if [ -f "$APP_DIR/composer.json" ]; then
    STACKS+=("php")
  fi
  # .NET (best-effort notice)
  if ls "$APP_DIR"/*.csproj >/dev/null 2>&1 || [ -f "$APP_DIR/global.json" ]; then
    STACKS+=(".net")
  fi

  if [ "${#STACKS[@]}" -eq 0 ]; then
    warn "No known project stack detected. The script will install base tools only."
  else
    info "Detected stacks: ${STACKS[*]}"
  fi
}

# ------------- Stack installers -------------

setup_python() {
  log "Setting up Python environment..."
  # Install Python and build deps
  case "$PKG_MGR" in
    apt)
      install_pkgs python3 python3-venv python3-pip python3-dev pkg-config
      install_build_essentials
      install_pkgs libffi-dev libssl-dev
      ;;
    apk)
      install_pkgs python3 py3-pip py3-virtualenv python3-dev pkgconfig
      install_build_essentials
      install_pkgs libffi-dev openssl-dev musl-dev
      ;;
    dnf|yum|microdnf)
      install_pkgs python3 python3-pip python3-devel pkgconfig
      install_build_essentials
      install_pkgs libffi-devel openssl-devel
      ;;
    zypper)
      install_pkgs python3 python3-pip python3-virtualenv python3-devel pkg-config
      install_build_essentials
      install_pkgs libffi-devel libopenssl-devel || install_pkgs libffi-devel libopenssl1_1-devel || true
      ;;
    *)
      warn "Cannot ensure Python packages; unknown package manager."
      ;;
  esac

  # Create venv idempotently
  VENV_DIR="$APP_DIR/.venv"
  if [ ! -d "$VENV_DIR" ] || [ ! -f "$VENV_DIR/bin/activate" ]; then
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel

  if [ -f "$APP_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    PIP_NO_CACHE_DIR=1 pip install -r "$APP_DIR/requirements.txt"
  elif [ -f "$APP_DIR/pyproject.toml" ]; then
    log "Installing Python project from pyproject.toml (editable if possible)..."
    PIP_NO_CACHE_DIR=1 pip install -e "$APP_DIR" || PIP_NO_CACHE_DIR=1 pip install "$APP_DIR"
  elif [ -f "$APP_DIR/setup.py" ]; then
    log "Installing Python project via setup.py..."
    (cd "$APP_DIR" && PIP_NO_CACHE_DIR=1 pip install -e .)
  else
    warn "Python detected but no requirements.txt/pyproject.toml/setup.py found."
  fi

  # Environment variables
  export VIRTUAL_ENV="$VENV_DIR"
  export PATH="$VENV_DIR/bin:$PATH"
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1

  # Write .env additions
  {
    echo "PYTHONUNBUFFERED=1"
    echo "PIP_NO_CACHE_DIR=1"
    echo "VIRTUAL_ENV=$VENV_DIR"
    echo "PATH=$VENV_DIR/bin:\$PATH"
  } >> "$APP_DIR/.env.generated"

  if is_root; then chown -R "${APP_USER}:${APP_GROUP}" "$VENV_DIR" || true; fi
  log "Python environment ready."
}

setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      install_pkgs nodejs npm
      ;;
    apk)
      install_pkgs nodejs npm
      ;;
    dnf|yum|microdnf)
      install_pkgs nodejs npm || warn "Node.js packages may not be available on this distro by default."
      ;;
    zypper)
      install_pkgs nodejs npm || true
      ;;
    *)
      warn "Unknown package manager; cannot ensure Node.js installation."
      ;;
  esac

  pushd "$APP_DIR" >/dev/null
  if [ -f package-lock.json ]; then
    npm ci --no-audit --no-fund
  else
    npm install --no-audit --no-fund
  fi

  # Environment vars
  : "${NODE_ENV:=production}"
  export NODE_ENV
  {
    echo "NODE_ENV=${NODE_ENV}"
    echo "NPM_CONFIG_FUND=false"
    echo "NPM_CONFIG_AUDIT=false"
  } >> "$APP_DIR/.env.generated"

  if is_root; then chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR/node_modules" || true; fi
  popd >/dev/null
  log "Node.js environment ready."
}

setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      install_pkgs ruby-full
      install_build_essentials
      ;;
    apk)
      install_pkgs ruby ruby-dev
      install_build_essentials
      ;;
    dnf|yum|microdnf)
      install_pkgs ruby ruby-devel
      install_build_essentials
      ;;
    zypper)
      install_pkgs ruby ruby-devel
      install_build_essentials
      ;;
    *)
      warn "Unknown package manager; cannot ensure Ruby installation."
      ;;
  esac

  if ! have_cmd bundler; then
    gem install bundler --no-document
  fi

  pushd "$APP_DIR" >/dev/null
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs "$(nproc 2>/dev/null || echo 2)" --retry 3
  popd >/dev/null

  if is_root; then chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR/vendor" || true; fi
  {
    echo "BUNDLE_PATH=$APP_DIR/vendor/bundle"
  } >> "$APP_DIR/.env.generated"
  log "Ruby environment ready."
}

setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt)
      install_pkgs golang
      ;;
    apk)
      install_pkgs go
      ;;
    dnf|yum|microdnf)
      install_pkgs golang
      ;;
    zypper)
      install_pkgs go
      ;;
    *)
      warn "Unknown package manager; cannot ensure Go installation."
      ;;
  esac

  export GO111MODULE=on
  pushd "$APP_DIR" >/dev/null
  if [ -f go.mod ]; then
    go mod download
    # Attempt to build if main exists
    if [ -f main.go ] || grep -RqlE '^package main$' .; then
      mkdir -p "$APP_DIR/dist"
      go build -o "$APP_DIR/dist/app"
    fi
  fi
  popd >/dev/null

  {
    echo "GO111MODULE=on"
    echo "GOBIN=\$HOME/go/bin"
    echo "PATH=\$PATH:\$GOBIN"
  } >> "$APP_DIR/.env.generated"
  log "Go environment ready."
}

setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MGR" in
    apt)
      install_pkgs rustc cargo
      ;;
    apk)
      install_pkgs cargo
      ;;
    dnf|yum|microdnf)
      install_pkgs rust cargo || install_pkgs rustc cargo || true
      ;;
    zypper)
      install_pkgs rust cargo || true
      ;;
    *)
      warn "Unknown package manager; cannot ensure Rust installation."
      ;;
  esac

  pushd "$APP_DIR" >/dev/null
  if [ -f Cargo.toml ]; then
    cargo fetch
    # Optional build
    cargo build --release || true
  fi
  popd >/dev/null

  log "Rust environment ready."
}

setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "$PKG_MGR" in
    apt)
      install_pkgs openjdk-17-jdk maven
      ;;
    apk)
      install_pkgs openjdk17 maven
      ;;
    dnf|yum|microdnf)
      install_pkgs java-17-openjdk-devel maven
      ;;
    zypper)
      install_pkgs java-17-openjdk-devel maven
      ;;
    *)
      warn "Unknown package manager; cannot ensure Java/Maven installation."
      ;;
  esac
  export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
  pushd "$APP_DIR" >/dev/null
  mvn -B -ntp -DskipTests package || mvn -B -DskipTests package || true
  popd >/dev/null
  {
    echo "JAVA_HOME=$JAVA_HOME"
    echo "MAVEN_OPTS=-Xmx512m"
  } >> "$APP_DIR/.env.generated"
  log "Java (Maven) environment ready."
}

setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  case "$PKG_MGR" in
    apt)
      install_pkgs openjdk-17-jdk gradle || install_pkgs openjdk-17-jdk
      ;;
    apk)
      install_pkgs openjdk17 gradle || install_pkgs openjdk17
      ;;
    dnf|yum|microdnf)
      install_pkgs java-17-openjdk-devel gradle || install_pkgs java-17-openjdk-devel
      ;;
    zypper)
      install_pkgs java-17-openjdk-devel gradle || install_pkgs java-17-openjdk-devel
      ;;
    *)
      warn "Unknown package manager; cannot ensure Java/Gradle installation."
      ;;
  esac
  export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
  pushd "$APP_DIR" >/dev/null
  if [ -x "./gradlew" ]; then
    ./gradlew build -x test || true
  else
    if have_cmd gradle; then
      gradle build -x test || true
    else
      warn "Gradle not available and no gradlew wrapper found."
    fi
  fi
  popd >/dev/null
  {
    echo "JAVA_HOME=$JAVA_HOME"
    echo "GRADLE_OPTS=-Xmx512m -Dorg.gradle.daemon=false"
  } >> "$APP_DIR/.env.generated"
  log "Java (Gradle) environment ready."
}

setup_php() {
  log "Setting up PHP (Composer) environment..."
  case "$PKG_MGR" in
    apt)
      install_pkgs php-cli php-xml php-mbstring unzip curl git
      ;;
    apk)
      # Alpine packages may vary by version; use defaults
      install_pkgs php81-cli php81-xml php81-mbstring php81-openssl php81-json unzip curl git || install_pkgs php-cli php-xml php-mbstring unzip curl git
      ;;
    dnf|yum|microdnf)
      install_pkgs php-cli php-xml php-mbstring unzip curl git || install_pkgs php php-xml php-mbstring unzip curl git
      ;;
    zypper)
      install_pkgs php7 php7-xml php7-mbstring unzip curl git || install_pkgs php php-xml php-mbstring unzip curl git
      ;;
    *)
      warn "Unknown package manager; cannot ensure PHP installation."
      ;;
  esac

  if ! have_cmd composer; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE="$(curl -s https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      err "Invalid Composer installer signature."
      return 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi

  pushd "$APP_DIR" >/dev/null
  if [ -f composer.lock ]; then
    composer install --no-dev --no-interaction --prefer-dist
  else
    composer install --no-interaction --prefer-dist
  fi
  popd >/dev/null

  if is_root; then chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR/vendor" || true; fi
  log "PHP environment ready."
}

setup_dotnet_notice() {
  warn ".NET project detected. Installing .NET SDK inside an arbitrary base image is non-trivial."
  warn "Recommendation: Use an official .NET SDK base image (e.g., mcr.microsoft.com/dotnet/sdk:8.0) for builds,"
  warn "and a .NET ASP.NET runtime image for production. Skipping automatic SDK installation."
}

# ------------- Environment file handling -------------
init_env_files() {
  # Generate or append environment defaults
  : > "$APP_DIR/.env.generated"
  {
    echo "APP_ENV=production"
    echo "PORT=${DEFAULT_PORT}"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"
  } >> "$APP_DIR/.env.generated"

  if [ ! -f "$APP_DIR/.env" ]; then
    cp "$APP_DIR/.env.generated" "$APP_DIR/.env"
  fi

  if is_root; then chown "${APP_USER}:${APP_GROUP}" "$APP_DIR/.env" "$APP_DIR/.env.generated" || true; fi
}

# ------------- Main orchestration -------------
main() {
  log "Starting environment setup in Docker container..."
  detect_pkg_manager
  info "Detected OS family: ${OS_FAMILY:-unknown} | Package manager: ${PKG_MGR:-none}"

  if ! is_root; then
    warn "Running as non-root. System package installation may fail. Some steps will be skipped if permissions are insufficient."
  fi

  # Prepare system
  [ -n "$PKG_MGR" ] && update_pkg_index || warn "Skipping package index update (no package manager found)."
  [ -n "$PKG_MGR" ] && install_base_tools

  ensure_app_user
  ensure_dirs
  init_env_files

  # Detect stacks
  detect_stacks

  # Configure per stack
  for stack in "${STACKS[@]:-}"; do
    case "$stack" in
      python) setup_python ;;
      node) setup_node ;;
      ruby) setup_ruby ;;
      go) setup_go ;;
      rust) setup_rust ;;
      java-maven) setup_java_maven ;;
      java-gradle) setup_java_gradle ;;
      php) setup_php ;;
      .net) setup_dotnet_notice ;;
      *) warn "Unknown stack entry: $stack" ;;
    esac
  done

  # Final permissions on common writable dirs
  if is_root; then
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/data" "$APP_DIR/build" "$APP_DIR/dist" || true
  fi

  # Summary
  log "Environment setup completed successfully."
  info "Generated/updated: $APP_DIR/.env and $APP_DIR/.env.generated"
  info "Detected stacks: ${STACKS[*]:-none}"
  info "App directory: $APP_DIR"
  if is_root; then
    info "App user: ${APP_USER} (you may switch user in Dockerfile: USER ${APP_USER})"
  fi
}

main "$@" || exit 1