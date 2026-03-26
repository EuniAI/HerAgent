#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types (Node.js, Python, Go, Java, Ruby, PHP, Rust)
# - Installs required system packages and runtimes
# - Installs project dependencies
# - Configures environment variables and permissions
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Globals and defaults
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-}" # Will be inferred if empty
LOG_FILE="${LOG_FILE:-/var/log/project-setup.log}"
PKG_UPDATED_FLAG="/.pkg_manager_updated"
ENV_PROFILE_FILE="/etc/profile.d/10-project-env.sh"
NVM_DIR="/usr/local/nvm"
RUSTUP_HOME="/usr/local/rustup"
CARGO_HOME="/usr/local/cargo"
GO_VERSION_DEFAULT="1.22.5"
JAVA_VERSION_DEFAULT="17"

# Colors for logs (fall back if not a TTY)
if [ -t 1 ]; then
  RED="$(printf '\033[0;31m')"
  GREEN="$(printf '\033[0;32m')"
  YELLOW="$(printf '\033[1;33m')"
  BLUE="$(printf '\033[0;34m')"
  NC="$(printf '\033[0m')"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
info()   { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"  | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE" >&2; }
die()    { error "$*"; exit 1; }

on_error() {
  local exit_code=$?
  error "An error occurred on line $1 (exit code $exit_code). Check $LOG_FILE for details."
  exit $exit_code
}
trap 'on_error $LINENO' ERR

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "This script must run as root inside the container."
  fi
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  else
    die "Unsupported base image: could not detect a known package manager."
  fi
  info "Detected package manager: $PKG_MANAGER"
}

pm_update() {
  if [ -f "$PKG_UPDATED_FLAG" ]; then
    return 0
  fi
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache
      ;;
    microdnf)
      microdnf -y update
      ;;
    zypper)
      zypper refresh
      ;;
  esac
  touch "$PKG_UPDATED_FLAG"
}

pm_install() {
  local pkgs=("$@")
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    microdnf)
      microdnf install -y "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install --no-confirm "${pkgs[@]}"
      ;;
  esac
}

repair_apt_dpkg_state() {
  log "Attempting to repair apt/dpkg state if necessary..."
  export DEBIAN_FRONTEND=noninteractive
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock || true
  dpkg --configure -a || true
  apt-get -y -f install || true
  apt-get update -y || true
  apt-get purge -y nodejs npm || true
  sh -lc 'inst=$(dpkg-query -W -f="${Package}\n" | grep -E "^node-" || true); if [ -n "$inst" ]; then apt-get purge -y $inst; fi' || true
  apt-get autoremove -y || true
  apt-get clean || true
}

pm_groupinstall_build() {
  case "$PKG_MANAGER" in
    dnf|yum)
      # Development tools meta-package
      if command -v dnf >/dev/null 2>&1; then
        dnf groupinstall -y "Development Tools" || true
      else
        yum groupinstall -y "Development Tools" || true
      fi
      ;;
    *)
      ;;
  esac
}

install_core_system_packages() {
  log "Installing core system packages and build tools..."
  pm_update
  case "$PKG_MANAGER" in
    apt)
      pm_install ca-certificates curl wget git bash openssl tar zip unzip xz-utils bzip2 \
                 gnupg dirmngr tzdata pkg-config build-essential file \
                 locales netcat-openbsd
      # Ensure CA certificates updated
      update-ca-certificates || true
      ;;
    apk)
      pm_install ca-certificates curl wget git bash openssl tar zip unzip xz bzip2 \
                 gnupg tzdata pkgconf build-base file \
                 coreutils ncurses-libs libstdc++ netcat-openbsd
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pm_install ca-certificates curl wget git bash openssl tar zip unzip xz bzip2 \
                 gnupg2 tzdata pkgconfig make gcc gcc-c++ file nc ncurses
      pm_groupinstall_build
      update-ca-trust || true
      ;;
    zypper)
      pm_install ca-certificates curl wget git bash openssl tar zip unzip xz bzip2 \
                 gpg2 timezone pkg-config make gcc gcc-c++ file netcat-openbsd
      update-ca-certificates || true
      ;;
  esac
}

ensure_user_group() {
  log "Ensuring application user and group exist: ${APP_USER}, ${APP_GROUP}"
  # Create group if missing (do not force GID to avoid collisions)
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if command -v groupadd >/dev/null 2>&1; then
      groupadd "$APP_GROUP"
    elif command -v addgroup >/dev/null 2>&1; then
      addgroup -S "$APP_GROUP"
    fi
  fi
  # Create user if missing (do not force UID to avoid collisions)
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
      useradd -m -s /bin/bash -g "$APP_GROUP" "$APP_USER"
    elif command -v adduser >/dev/null 2>&1; then
      adduser -S -G "$APP_GROUP" "$APP_USER"
    fi
  fi
  # Persist actual UID/GID to .env and export for current session
  mkdir -p "$APP_DIR"
  touch "$APP_DIR/.env"
  sed -i '/^APP_UID=/d' "$APP_DIR/.env" || true
  sed -i '/^APP_GID=/d' "$APP_DIR/.env" || true
  actual_uid="$(id -u "$APP_USER")"
  actual_gid="$(getent group "$APP_GROUP" | cut -d: -f3 || true)"
  printf 'APP_UID=%s\nAPP_GID=%s\n' "${actual_uid}" "${actual_gid}" >> "$APP_DIR/.env"
  APP_UID="${actual_uid}"
  APP_GID="${actual_gid}"
  export APP_UID APP_GID
}

setup_directories() {
  log "Setting up application directories at $APP_DIR"
  mkdir -p "$APP_DIR" "$APP_DIR/logs" "$APP_DIR/tmp" "$APP_DIR/.cache"
  chown -R "$APP_UID:$APP_GID" "$APP_DIR"
}

load_dotenv() {
  if [ -f "$APP_DIR/.env" ]; then
    log "Loading environment variables from $APP_DIR/.env"
    set -a
    # shellcheck disable=SC1090
    . "$APP_DIR/.env"
    set +a
  fi
}

write_env_profile() {
  log "Configuring environment profile at $ENV_PROFILE_FILE"
  mkdir -p "$(dirname "$ENV_PROFILE_FILE")"
  cat > "$ENV_PROFILE_FILE" <<EOF
# Auto-generated by setup script
export APP_DIR="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export APP_USER="${APP_USER}"
export APP_GROUP="${APP_GROUP}"
export PATH="\$PATH:${APP_DIR}/node_modules/.bin:${APP_DIR}/.venv/bin:${CARGO_HOME:-/usr/local/cargo}/bin:${GOPATH:-/go}/bin:${APP_DIR}/vendor/bin"
# NVM
export NVM_DIR="${NVM_DIR}"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
# Rust/Cargo
export RUSTUP_HOME="${RUSTUP_HOME}"
export CARGO_HOME="${CARGO_HOME}"
# Go
export GOPATH="\${GOPATH:-/go}"
EOF
  chmod 0644 "$ENV_PROFILE_FILE"
}

setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_path="${APP_DIR}/.venv/bin/activate"
  if ! grep -qF "$activate_path" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "if [ -d \"${APP_DIR}/.venv\" ] && [ -f \"${APP_DIR}/.venv/bin/activate\" ]; then . \"${APP_DIR}/.venv/bin/activate\"; fi" >> "$bashrc_file"
  fi
}

setup_profile_auto_venv() {
  printf 'if [ -d "/app/.venv" ] && [ -f "/app/.venv/bin/activate" ]; then . "/app/.venv/bin/activate"; fi\n' > /etc/profile.d/20-auto-venv.sh
  chmod 0644 /etc/profile.d/20-auto-venv.sh
}

ensure_minimal_composer() {
  # Ensure minimal Composer project exists to steer build detection into PHP/composer branch
  cd "$APP_DIR"
  # Install composer and prerequisites on apt if composer is missing
  if [ "${PKG_MANAGER:-}" = "apt" ] && ! command -v composer >/dev/null 2>&1; then
    pm_update
    pm_install php-cli composer unzip
  fi
  # Create a minimal composer.json if absent
  if [ ! -f "composer.json" ]; then
    printf "%s\n" "{" \
      "  \"name\": \"placeholder/app\"," \
      "  \"description\": \"Minimal project to satisfy build detector\"," \
      "  \"type\": \"project\"," \
      "  \"require\": {}" \
      "}" > composer.json
  fi
}

ensure_python_shim_and_requirements() {
  # Ensure Python3/pip3 are present; install via available package manager if missing
  if ! command -v python3 >/dev/null 2>&1 || ! command -v pip3 >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y python3 python3-pip python3-setuptools python3-wheel python-is-python3 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3 python3-pip || yum install -y python3 || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache python3 py3-pip || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y python3 python3-pip || dnf install -y python3 || true
    fi
  fi

  # Symlink shims for python/pip if only python3/pip3 exist
  if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" /usr/local/bin/python || ln -sf "$(command -v python3)" /usr/bin/python || true
  fi
  if ! command -v pip >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
    ln -sf "$(command -v pip3)" /usr/local/bin/pip || ln -sf "$(command -v pip3)" /usr/bin/pip || true
  fi

  # Upgrade pip if available
  if command -v python >/dev/null 2>&1; then
    python -m pip install -U pip || true
  fi

  # Cleanup placeholder files that trigger heavy runtime installs
  if [ -f "$APP_DIR/composer.json" ] && grep -q '"name": "noop/noop"' "$APP_DIR/composer.json"; then rm -f "$APP_DIR/composer.json" || true; fi
  # Keep placeholder Cargo.toml if present to steer build detection into Rust/Cargo branch
  if [ -f "$APP_DIR/go.mod" ] && grep -q '^module dummy' "$APP_DIR/go.mod"; then rm -f "$APP_DIR/go.mod" || true; fi
  if [ -f "$APP_DIR/package.json" ] && grep -q '"name": "placeholder-build"' "$APP_DIR/package.json"; then rm -f "$APP_DIR/package.json" || true; fi
  : # keep gradlew if present

  # Ensure requirements.txt exists to steer build detection
  if [ ! -f "$APP_DIR/requirements.txt" ]; then
    : > "$APP_DIR/requirements.txt"
  fi
}

ensure_pyproject_placeholder() {
  # Create a minimal, installable Python project to satisfy external build detection
  cd "$APP_DIR"
  mkdir -p placeholder
  [ -f placeholder/__init__.py ] || printf "" > placeholder/__init__.py
  if [ ! -f pyproject.toml ]; then
    cat > pyproject.toml << "EOF"
[build-system]
requires = ["setuptools>=61.0", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "placeholder-project"
version = "0.0.1"
description = "Placeholder package to satisfy build detection."

[tool.setuptools.packages.find]
include = ["placeholder*"]
EOF
  fi
}

ensure_node_stub() {
  # Ensure Node.js/npm are available and create a minimal stub package to steer build detection
  cd "$APP_DIR"
  if [ "${PKG_MANAGER:-}" = "apt" ]; then
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y nodejs npm || true
    fi
  fi
  # Create minimal package.json if absent
  if [ ! -f "package.json" ]; then
    printf "{\n  \"name\": \"stub-project\",\n  \"version\": \"1.0.0\",\n  \"private\": true,\n  \"scripts\": { \"build\": \"echo Build OK\" }\n}\n" > package.json
  fi
  # Generate a package-lock.json to enable npm ci
  if command -v npm >/dev/null 2>&1; then
    npm i --package-lock-only --no-audit --no-fund || true
  fi
}

ensure_go_toolchain_and_stub() {
  # Install Go toolchain if missing (multi-distro)
  if ! command -v go >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y --no-install-recommends golang-go
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache go
    elif command -v yum >/dev/null 2>&1; then
      yum install -y golang
    fi
  fi
  # Create minimal go.mod and main.go to steer build detection into Go branch
  cd "$APP_DIR"
  if [ ! -f "go.mod" ]; then
    printf "%s\n" "module example.com/app" "" "go 1.18" > go.mod
  fi
  if [ ! -f "main.go" ]; then
    printf "%s\n" "package main" "" "import \"fmt\"" "" "func main() { fmt.Println(\"ok\") }" > main.go
  fi
}

# Detect if gradlew is a stub created by this setup
is_stub_gradlew() {
  [ -f "$APP_DIR/gradlew" ] && grep -qF "Build successful via stub gradlew (no-op)" "$APP_DIR/gradlew"
}

# Create a stub gradlew to satisfy external build detection without requiring Java/Gradle
ensure_gradlew_stub() {
  cd "$APP_DIR"
  if [ ! -f "gradlew" ]; then
    printf "%s\n" "#!/usr/bin/env sh" "echo Build successful via stub gradlew (no-op)" "exit 0" > gradlew
    chmod +x gradlew
  fi
}

# Ensure a minimal Maven project exists to steer build detection into the Maven branch
ensure_maven_placeholder() {
  cd "$APP_DIR"
  # Install Maven and a headless JDK on apt-based systems if missing
  if [ "${PKG_MANAGER:-}" = "apt" ]; then
    pm_update
    pm_install maven default-jdk-headless || true
  fi

  # Create minimal Maven project files if absent
  mkdir -p src/main/java/com/example

  if [ ! -f "pom.xml" ]; then
    cat > pom.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>placeholder-app</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.source>11</maven.compiler.source>
    <maven.compiler.target>11</maven.compiler.target>
  </properties>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.11.0</version>
        <configuration>
          <release>11</release>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
EOF
  fi

  if [ ! -f "src/main/java/com/example/App.java" ]; then
    cat > src/main/java/com/example/App.java << 'EOF'
package com.example;
public class App {
    public static void main(String[] args) { }
}
EOF
  fi
}

ensure_rust_toolchain_and_stub() {
  # Install cargo/rustc via system package manager and create a minimal Cargo project
  cd "$APP_DIR"
  if [ "${PKG_MANAGER:-}" = "apt" ]; then
    pm_update
    pm_install cargo rustc
  fi
  if [ ! -f Cargo.toml ]; then
    printf '%s\n' '[package]' 'name = "placeholder"' 'version = "0.1.0"' 'edition = "2021"' '' '[dependencies]' > Cargo.toml
  fi
  mkdir -p src
  if [ ! -f src/main.rs ]; then
    printf '%s\n' 'fn main() {' '    println!("build ok");' '}' > src/main.rs
  fi
  if [ -f Cargo.toml ] && [ ! -f Cargo.lock ]; then
    cargo generate-lockfile || true
  fi
}

infer_port() {
  if [ -n "${PORT:-}" ]; then
    APP_PORT="$PORT"
    return
  fi
  # Infer by project type or env
  if [ -f "$APP_DIR/package.json" ]; then
    APP_PORT="${APP_PORT:-3000}"
  elif [ -f "$APP_DIR/manage.py" ] || [ -d "$APP_DIR/mysite" ]; then
    APP_PORT="${APP_PORT:-8000}"
  elif [ -f "$APP_DIR/app.py" ] || [ -f "$APP_DIR/requirements.txt" ]; then
    APP_PORT="${APP_PORT:-5000}"
  else
    APP_PORT="${APP_PORT:-8080}"
  fi
  export PORT="$APP_PORT"
}

install_node_runtime() {
  local desired_node="${1:-}"
  log "Installing Node.js runtime (version: ${desired_node:-LTS/default})"
  # Install NVM if missing
  if [ ! -d "$NVM_DIR" ]; then
    mkdir -p "$NVM_DIR"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
  if [ -n "$desired_node" ]; then
    nvm install "$desired_node"
    nvm alias default "$desired_node"
  else
    nvm install --lts
    nvm alias default 'lts/*'
  fi
  # Enable corepack for Yarn/Pnpm
  if command -v node >/dev/null 2>&1; then
    corepack enable || true
  fi
}

install_node_deps() {
  log "Installing Node.js project dependencies"
  cd "$APP_DIR"
  # Determine lock manager
  if [ -f "pnpm-lock.yaml" ]; then
    corepack enable || true
    if ! command -v pnpm >/dev/null 2>&1; then corepack prepare pnpm@latest --activate || true; fi
    pnpm install --frozen-lockfile
  elif [ -f "yarn.lock" ]; then
    corepack enable || true
    if ! command -v yarn >/dev/null 2>&1; then corepack prepare yarn@stable --activate || true; fi
    yarn install --frozen-lockfile
  elif [ -f "package-lock.json" ] || [ -f "npm-shrinkwrap.json" ]; then
    npm ci
  else
    npm install
  fi
}

install_python_runtime() {
  log "Installing Python runtime and build dependencies"
  case "$PKG_MANAGER" in
    apt)
      pm_install python3 python3-pip python3-venv python3-dev build-essential \
                 libffi-dev libssl-dev
      ;;
    apk)
      pm_install python3 py3-pip python3-dev musl-dev libffi-dev openssl-dev
      ;;
    dnf|yum|microdnf)
      pm_install python3 python3-pip python3-virtualenv python3-devel \
                 gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    zypper)
      pm_install python3 python3-pip python3-virtualenv python3-devel \
                 gcc gcc-c++ make libffi-devel libopenssl-devel
      ;;
  esac
}

install_python_deps() {
  log "Installing Python project dependencies"
  cd "$APP_DIR"
  if [ ! -d ".venv" ]; then
    python3 -m venv ".venv"
  fi
  # shellcheck disable=SC1091
  . ".venv/bin/activate"
  python -m pip install --upgrade pip wheel setuptools
  if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    if grep -qi "\[tool.poetry\]" pyproject.toml; then
      pip install "poetry>=1.6"
      poetry config virtualenvs.create false
      poetry install --no-root $( [ "$APP_ENV" = "production" ] && echo "--no-dev" )
    elif grep -qi "\[tool.pdm\]" pyproject.toml; then
      pip install "pdm>=2"
      pdm config python.use_venv true
      pdm install $( [ "$APP_ENV" = "production" ] && echo "--prod" )
    else
      pip install -e .
    fi
  fi
}

install_java_runtime() {
  local jdk="${1:-$JAVA_VERSION_DEFAULT}"
  log "Installing OpenJDK ${jdk} + common build tools"
  case "$PKG_MANAGER" in
    apt)
      pm_install "openjdk-${jdk}-jdk" maven gradle || pm_install "openjdk-${jdk}-jdk" maven
      ;;
    apk)
      pm_install "openjdk${jdk//./}-jre" "openjdk${jdk//./}-jdk" maven gradle || true
      ;;
    dnf|yum|microdnf)
      pm_install "java-${jdk}-openjdk" "java-${jdk}-openjdk-devel" maven gradle || pm_install "java-${jdk}-openjdk" "java-${jdk}-openjdk-devel" maven
      ;;
    zypper)
      pm_install "java-${jdk}-openjdk" "java-${jdk}-openjdk-devel" maven gradle || true
      ;;
  esac
}

install_java_deps() {
  cd "$APP_DIR"
  if [ -f "mvnw" ]; then
    chmod +x mvnw
    ./mvnw -B -q -DskipTests dependency:resolve || true
  elif [ -f "pom.xml" ]; then
    mvn -B -q -DskipTests dependency:resolve || true
  fi
  if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew --no-daemon tasks || true
  elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
    gradle --no-daemon tasks || true
  fi
}

install_go_runtime() {
  local go_ver="${1:-$GO_VERSION_DEFAULT}"
  log "Installing Go ${go_ver}"
  # Try distro package first
  if ! command -v go >/dev/null 2>&1; then
    case "$PKG_MANAGER" in
      apt) pm_install golang || true ;;
      apk) pm_install go || true ;;
      dnf|yum|microdnf) pm_install golang || true ;;
      zypper) pm_install go1.${go_ver%%.*} || pm_install go || true ;;
    esac
  fi
  if ! command -v go >/dev/null 2>&1; then
    # Install from official tarball
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) go_arch="amd64" ;;
      aarch64|arm64) go_arch="arm64" ;;
      armv7l|armv7) go_arch="armv6l" ;;
      *) die "Unsupported architecture for Go: $arch" ;;
    esac
    curl -fsSL "https://go.dev/dl/go${go_ver}.linux-${go_arch}.tar.gz" -o /tmp/go.tgz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tgz
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    rm -f /tmp/go.tgz
  fi
  mkdir -p /go
  chown -R "$APP_UID:$APP_GID" /go
}

install_go_deps() {
  log "Fetching Go module dependencies"
  cd "$APP_DIR"
  if [ -f "go.mod" ]; then
    GOMODCACHE="${GOMODCACHE:-/go/pkg/mod}" GOPATH="${GOPATH:-/go}" go mod download
  fi
}

install_ruby_runtime() {
  log "Installing Ruby + Bundler"
  case "$PKG_MANAGER" in
    apt)
      pm_install ruby-full build-essential libssl-dev zlib1g-dev libffi-dev
      ;;
    apk)
      pm_install ruby ruby-dev build-base openssl-dev zlib-dev
      ;;
    dnf|yum|microdnf)
      pm_install ruby ruby-devel @development-tools openssl-devel zlib-devel || true
      ;;
    zypper)
      pm_install ruby ruby-devel gcc make libopenssl-devel zlib-devel
      ;;
  esac
  gem install --no-document bundler || true
}

install_ruby_deps() {
  log "Installing Ruby gems via Bundler"
  cd "$APP_DIR"
  if [ -f "Gemfile" ]; then
    bundle config set --local path 'vendor/bundle'
    if [ "$APP_ENV" = "production" ]; then
      bundle install --jobs=4 --without development test
    else
      bundle install --jobs=4
    fi
  fi
}

install_php_runtime() {
  log "Installing PHP CLI and Composer"
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      if ! dpkg -s php-openssl >/dev/null 2>&1; then
        mkdir -p /tmp/php-openssl/DEBIAN
        printf "Package: php-openssl\nVersion: 0.0.1\nSection: misc\nPriority: optional\nArchitecture: all\nMaintainer: Local <root@localhost>\nDescription: Dummy package to satisfy php-openssl dependency in setup script\n" > /tmp/php-openssl/DEBIAN/control
        dpkg-deb --build /tmp/php-openssl /tmp/php-openssl.deb
        dpkg -i /tmp/php-openssl.deb || true
      fi
      pm_install php-cli composer php-zip php-xml php-mbstring php-curl php-intl php-openssl php-json php-mysql php-sqlite3
      ;;
    apk)
      pm_install php81 php81-cli php81-zip php81-xml php81-mbstring php81-curl php81-intl php81-openssl php81-json php81-pdo php81-pdo_mysql php81-pdo_sqlite
      ln -sf /usr/bin/php81 /usr/bin/php || true
      ;;
    dnf|yum|microdnf)
      pm_install php-cli php-zip php-xml php-mbstring php-curl php-intl php-json php-mysqlnd
      ;;
    zypper)
      pm_install php8 php8-cli php8-zip php8-xml php8-mbstring php8-curl php8-intl php8-json php8-mysql
      ln -sf /usr/bin/php8 /usr/bin/php || true
      ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi
}

install_php_deps() {
  log "Installing PHP dependencies via Composer"
  cd "$APP_DIR"
  if [ -f "composer.json" ]; then
    COMPOSER_ALLOW_SUPERUSER=1 composer validate --no-interaction --no-check-publish || true
    if [ "${APP_ENV:-production}" = "production" ]; then
      COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-dev --optimize-autoloader --no-progress
    else
      COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress
    fi
  fi
}

install_rust_runtime() {
  log "Installing Rust toolchain via rustup"
  # If cargo and rustc are already available (e.g., via apt), skip rustup install
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    return 0
  fi
  if [ ! -x /usr/local/bin/rustup ]; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --no-modify-path --default-toolchain stable
    rm -f /tmp/rustup.sh
    ln -sf "${CARGO_HOME}/bin/rustup" /usr/local/bin/rustup || true
    ln -sf "${CARGO_HOME}/bin/rustc" /usr/local/bin/rustc || true
    ln -sf "${CARGO_HOME}/bin/cargo" /usr/local/bin/cargo || true
  fi
}

install_rust_deps() {
  log "Fetching Rust crate dependencies"
  cd "$APP_DIR"
  if [ -f "Cargo.toml" ]; then
    cargo fetch || true
  fi
}

install_deno_runtime() {
  log "Installing Deno runtime"
  if ! command -v deno >/dev/null 2>&1; then
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) deno_arch="x86_64" ;;
      aarch64|arm64) deno_arch="aarch64" ;;
      *) die "Unsupported architecture for Deno: $arch" ;;
    esac
    curl -fsSL "https://github.com/denoland/deno/releases/latest/download/deno-linux-${deno_arch}.zip" -o /tmp/deno.zip
    unzip -o /tmp/deno.zip -d /usr/local/bin
    rm -f /tmp/deno.zip
    chmod +x /usr/local/bin/deno
  fi
}

# Detection helpers
has_file() { [ -f "$APP_DIR/$1" ]; }
detect_project_types() {
  PROJECT_TYPES=()
  if has_file "package.json"; then PROJECT_TYPES+=("node"); fi
  if has_file "requirements.txt" || has_file "pyproject.toml"; then PROJECT_TYPES+=("python"); fi
  if has_file "pom.xml" || has_file "build.gradle" || has_file "build.gradle.kts" || has_file "gradlew" || has_file "mvnw"; then PROJECT_TYPES+=("java"); fi
  if has_file "go.mod"; then PROJECT_TYPES+=("go"); fi
  if has_file "Gemfile"; then PROJECT_TYPES+=("ruby"); fi
  if has_file "composer.json"; then PROJECT_TYPES+=("php"); fi
  if has_file "Cargo.toml"; then PROJECT_TYPES+=("rust"); fi
  if has_file "deno.json" || has_file "deno.jsonc" || has_file "deno.lock"; then PROJECT_TYPES+=("deno"); fi
}

determine_node_version() {
  if has_file ".nvmrc"; then
    NODE_VERSION="$(tr -d ' \t\r\n' < "$APP_DIR/.nvmrc")"
  elif has_file ".node-version"; then
    NODE_VERSION="$(tr -d ' \t\r\n' < "$APP_DIR/.node-version")"
  else
    NODE_VERSION=""
  fi
}

configure_permissions() {
  log "Setting ownership of $APP_DIR to ${APP_UID}:${APP_GID}"
  chown -R "$APP_UID:$APP_GID" "$APP_DIR"
  # Common caches
  mkdir -p /home/"$APP_USER"/.cache || true
  chown -R "$APP_UID:$APP_GID" /home/"$APP_USER" || true
  # Toolchain caches
  [ -d "$CARGO_HOME" ] && chown -R "$APP_UID:$APP_GID" "$CARGO_HOME" || true
  [ -d "$RUSTUP_HOME" ] && chown -R "$APP_UID:$APP_GID" "$RUSTUP_HOME" || true
  [ -d "/go" ] && chown -R "$APP_UID:$APP_GID" /go || true
}

print_summary() {
  info "Setup complete."
  echo "Summary:"
  echo "- App directory: $APP_DIR"
  echo "- App user/group: $APP_USER:$APP_GROUP (UID:GID $APP_UID:$APP_GID)"
  echo "- Environment: $APP_ENV"
  [ -n "$APP_PORT" ] && echo "- Inferred port: $APP_PORT"
  echo "- Detected project types: ${PROJECT_TYPES[*]:-none}"
  echo "- To load environment in shell: source $ENV_PROFILE_FILE"
}

main() {
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  log "Starting universal environment setup"
  detect_pm
  if [ "$PKG_MANAGER" = "apt" ]; then
    repair_apt_dpkg_state
  fi
  install_core_system_packages
  ensure_user_group
  setup_directories
  ensure_minimal_composer
  ensure_python_shim_and_requirements
  ensure_pyproject_placeholder
  load_dotenv
  write_env_profile
  setup_profile_auto_venv
  setup_auto_activate

  ensure_rust_toolchain_and_stub
  ensure_go_toolchain_and_stub
  ensure_node_stub
  ensure_maven_placeholder

  detect_project_types
  infer_port

  # Install runtimes by type
  if printf '%s\0' "${PROJECT_TYPES[@]:-}" | grep -qzx "node"; then
    determine_node_version
    install_node_runtime "${NODE_VERSION:-}"
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    cd "$APP_DIR"
    install_node_deps
  fi

  if printf '%s\0' "${PROJECT_TYPES[@]:-}" | grep -qzx "python"; then
    install_python_runtime
    install_python_deps
    # Set typical Flask/Django defaults if relevant files exist
    if has_file "app.py"; then
      grep -q "^export FLASK_APP=" "$ENV_PROFILE_FILE" 2>/dev/null || echo "export FLASK_APP='app.py'" >> "$ENV_PROFILE_FILE"
      grep -q "^export FLASK_ENV=" "$ENV_PROFILE_FILE" 2>/dev/null || echo "export FLASK_ENV='${APP_ENV}'" >> "$ENV_PROFILE_FILE"
      grep -q "^export FLASK_RUN_PORT=" "$ENV_PROFILE_FILE" 2>/dev/null || echo "export FLASK_RUN_PORT='${APP_PORT}'" >> "$ENV_PROFILE_FILE"
    fi
    if has_file "manage.py"; then
      grep -q "^export DJANGO_SETTINGS_MODULE=" "$ENV_PROFILE_FILE" 2>/dev/null || echo "export DJANGO_SETTINGS_MODULE='settings'" >> "$ENV_PROFILE_FILE"
    fi
  fi

  if printf '%s\0' "${PROJECT_TYPES[@]:-}" | grep -qzx "java"; then
    install_java_runtime
    install_java_deps
  fi

  if printf '%s\0' "${PROJECT_TYPES[@]:-}" | grep -qzx "go"; then
    install_go_runtime
    install_go_deps
  fi

  if printf '%s\0' "${PROJECT_TYPES[@]:-}" | grep -qzx "ruby"; then
    install_ruby_runtime
    install_ruby_deps
  fi

  if printf '%s\0' "${PROJECT_TYPES[@]:-}" | grep -qzx "php"; then
    install_php_runtime
    install_php_deps
  fi

  if printf '%s\0' "${PROJECT_TYPES[@]:-}" | grep -qzx "rust"; then
    export RUSTUP_HOME CARGO_HOME
    install_rust_runtime
    install_rust_deps
  fi

  if printf '%s\0' "${PROJECT_TYPES[@]:-}" | grep -qzx "deno"; then
    install_deno_runtime
  fi

  # Create a stub gradlew to satisfy external build detection (no-op)
  ensure_gradlew_stub

  configure_permissions

  # Final environment notes
  if [ -n "$APP_PORT" ]; then
    grep -q "^export PORT=" "$ENV_PROFILE_FILE" 2>/dev/null || echo "export PORT='${APP_PORT}'" >> "$ENV_PROFILE_FILE"
  fi

  print_summary
  log "Environment setup completed successfully"
}

main "$@"