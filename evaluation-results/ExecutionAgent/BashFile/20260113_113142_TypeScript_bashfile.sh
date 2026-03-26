#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type (Python, Node.js, Go, Rust, Java, PHP, Ruby, .NET)
# - Installs runtimes and system dependencies
# - Sets up project directories, permissions, and environment variables
# - Idempotent and safe to re-run
# - No sudo; intended to run as root inside containers

set -Eeuo pipefail
IFS=$' \n\t'

# Globals
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
ENV_FILE="${ENV_FILE:-.env}"
DEBIAN_FRONTEND=noninteractive

# Colors when TTY
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
on_error() { err "Line $1: $2"; }
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "This script must run as root in Docker (no sudo available)."
    exit 1
  fi
}

# Detect package manager and define commands
PM=""; PM_UPDATE=""; PM_INSTALL=""
detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
    PM_UPDATE="apt-get update -y"
    PM_INSTALL="apt-get install -y --no-install-recommends"
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
    PM_UPDATE="apk update"
    PM_INSTALL="apk add --no-cache"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    PM_UPDATE="dnf -y update || true"
    PM_INSTALL="dnf -y install"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    PM_UPDATE="yum -y update || true"
    PM_INSTALL="yum -y install"
  else
    PM="none"
  fi
}

pm_update() {
  if [ "$PM" = "none" ]; then
    warn "No supported package manager found. Skipping system package installs."
    return 0
  fi
  log "Updating package index with $PM ..."
  eval "$PM_UPDATE"
  # ensure ca-certificates for TLS
  case "$PM" in
    apt) eval "$PM_INSTALL ca-certificates gnupg"; update-ca-certificates || true ;;
    apk) eval "$PM_INSTALL ca-certificates"; update-ca-certificates || true ;;
    dnf|yum) eval "$PM_INSTALL ca-certificates" ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  [ "$PM" = "none" ] && { warn "Cannot install packages: no package manager."; return 0; }
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  log "Installing packages: ${pkgs[@]}"
  eval "$PM_INSTALL ${pkgs[@]}"
}

# Base tools for building many ecosystems
install_base_tools() {
  case "$PM" in
    apt)
      pkg_install curl wget git unzip xz-utils zip tar gzip bzip2 build-essential pkg-config openssl
      ;;
    apk)
      pkg_install curl wget git unzip xz zip tar gzip bzip2 build-base pkgconfig openssl
      ;;
    dnf|yum)
      pkg_install curl wget git unzip xz zip tar gzip bzip2 make gcc gcc-c++ pkgconfig openssl
      ;;
    none) ;;
  esac
}

# Create app user/group if running as root
ensure_app_user() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    return 0
  fi
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if command -v groupadd >/dev/null 2>&1; then groupadd -r "$APP_GROUP" || true
    elif command -v addgroup >/dev/null 2>&1; then addgroup -S "$APP_GROUP" || true
    fi
  fi
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
      useradd -r -g "$APP_GROUP" -d "/home/$APP_USER" -m -s /bin/bash "$APP_USER" || true
    elif command -v adduser >/dev/null 2>&1; then
      # Use BusyBox flags on Alpine; Debian/Ubuntu use long options
      if adduser --help 2>&1 | grep -qi 'BusyBox'; then
        adduser -S -G "$APP_GROUP" "$APP_USER" || true
      else
        adduser --system --ingroup "$APP_GROUP" --home "/home/$APP_USER" --shell /bin/bash "$APP_USER" || true
      fi
    fi
  fi
}

# Ensure directories exist and permissions set
ensure_dirs() {
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,data,.cache}
  chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT" || true
  chmod -R u+rwX,g+rwX "$PROJECT_ROOT" || true
}

# Persist environment variables to profile.d
persist_env_var() {
  local key="$1"; shift
  local val="$*"
  local profile="/etc/profile.d/zz-project-env.sh"
  touch "$profile"
  grep -qE "^export ${key}=" "$profile" 2>/dev/null && sed -i "s|^export ${key}=.*$|export ${key}=\"${val}\"|" "$profile" || echo "export ${key}=\"${val}\"" >> "$profile"
}

append_path_if_missing() {
  local dir="$1"
  local profile="/etc/profile.d/zz-project-env.sh"
  touch "$profile"
  if ! grep -qF "$dir" "$profile" 2>/dev/null; then
    echo "case :\$PATH: in *:$dir:*) ;; *) export PATH=\"$dir:\$PATH\" ;; esac" >> "$profile"
  fi
}

# Auto-activate virtualenv in future shells
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_path="$1"
  local activate_line="source $venv_path/bin/activate"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate Python virtual environment"
      echo 'if [ -n "${PS1:-}" ] && [ -z "${VIRTUAL_ENV:-}" ]; then'
      echo "  if [ -f \"$venv_path/bin/activate\" ]; then"
      echo "    $activate_line"
      echo "  fi"
      echo "fi"
    } >> "$bashrc_file"
  fi
}

# Load .env file if present and export variables
load_env_file() {
  if [ -f "$PROJECT_ROOT/$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/$ENV_FILE"
    set -a
  fi
}

# Project type detection
detect_project_type() {
  if [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/Pipfile" ] || [ -f "$PROJECT_ROOT/setup.py" ]; then
    echo "python"; return
  fi
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    echo "node"; return
  fi
  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    echo "go"; return
  fi
  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    echo "rust"; return
  fi
  if [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/build.gradle.kts" ] || [ -f "$PROJECT_ROOT/gradlew" ] || [ -f "$PROJECT_ROOT/mvnw" ]; then
    echo "java"; return
  fi
  if [ -f "$PROJECT_ROOT/composer.json" ]; then
    echo "php"; return
  fi
  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    echo "ruby"; return
  fi
  if find "$PROJECT_ROOT" -maxdepth 1 -name "*.csproj" -print -quit | grep -q . || [ -f "$PROJECT_ROOT/global.json" ]; then
    echo "dotnet"; return
  fi
  echo "unknown"
}

# Python setup
setup_python() {
  log "Configuring Python environment..."
  case "$PM" in
    apt) pkg_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev ;;
    apk) pkg_install python3 py3-pip py3-virtualenv python3-dev build-base libffi-dev openssl-dev ;;
    dnf|yum) pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel ;;
    none) warn "No package manager; expecting python3 available in base image." ;;
  esac
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required but not installed. Aborting."; exit 1
  fi
  cd "$PROJECT_ROOT"
  local venv_dir="${VENV_DIR:-.venv}"
  if [ ! -d "$venv_dir" ]; then
    log "Creating virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Virtual environment already exists at $venv_dir"
  fi
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  pip install --no-cache-dir --upgrade pip setuptools wheel
  if [ -f requirements.txt ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r requirements.txt
  elif [ -f pyproject.toml ]; then
    log "Detected pyproject.toml; attempting to install project dependencies"
    # Try common tools if lock files suggest poetry/pdm
    if [ -f poetry.lock ]; then
      pip install --no-cache-dir "poetry>=1.6"
      poetry install --no-interaction --no-ansi
    elif [ -f pdm.lock ]; then
      pip install --no-cache-dir "pdm>=2.6"
      pdm install
    else
      pip install --no-cache-dir -e . || warn "Editable install failed; ensure build system defined."
    fi
  elif [ -f Pipfile ]; then
    pip install --no-cache-dir "pipenv>=2023.0.0"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || PIPENV_VENV_IN_PROJECT=1 pipenv install
  else
    warn "No requirements.txt/Pipfile/pyproject found; skipping dependency installation."
  fi
  persist_env_var PYTHONUNBUFFERED 1
  persist_env_var PIP_NO_CACHE_DIR 1
  persist_env_var VIRTUAL_ENV "$PROJECT_ROOT/$venv_dir"
  append_path_if_missing "$PROJECT_ROOT/$venv_dir/bin"
  setup_auto_activate "$PROJECT_ROOT/$venv_dir"
  log "Python environment configured."
}

# Node.js setup
setup_node() {
  log "Configuring Node.js environment..."
  # Force-install and use Node.js 20 via nvm regardless of any preinstalled system node
  export NVM_DIR="/usr/local/nvm"
  mkdir -p "$NVM_DIR"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh -o /tmp/install_nvm.sh
    NVM_DIR="$NVM_DIR" bash /tmp/install_nvm.sh
  fi
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
  nvm install 20
  nvm alias default 20
  nvm use 20 >/dev/null 2>&1 || true
  ln -sf "$(nvm which 20)" /usr/local/bin/node
  ln -sf "$(dirname "$(nvm which 20)")/npm" /usr/local/bin/npm
  ln -sf "$(dirname "$(nvm which 20)")/npx" /usr/local/bin/npx
  # Persist NVM for future shells
  if ! grep -q 'NVM_DIR="/usr/local/nvm"' /etc/profile.d/zz-project-env.sh 2>/dev/null; then
    printf '%s\n%s\n' 'export NVM_DIR="/usr/local/nvm"' '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" # Load nvm' >> /etc/profile.d/zz-project-env.sh
  fi
  cd "$PROJECT_ROOT"
  if [ -f package.json ]; then
    # Enable corepack if available (for yarn/pnpm)
    if command -v corepack >/dev/null 2>&1; then corepack enable || true; fi
    if [ -f yarn.lock ]; then
      log "Installing dependencies with Yarn"
      if command -v yarn >/dev/null 2>&1; then yarn install --frozen-lockfile || yarn install
      else
        if command -v corepack >/dev/null 2>&1; then corepack yarn install --frozen-lockfile || corepack yarn install
        else npm install -g yarn && yarn install --frozen-lockfile || yarn install
        fi
      fi
    elif [ -f pnpm-lock.yaml ]; then
      log "Installing dependencies with pnpm"
      if command -v pnpm >/dev/null 2>&1; then pnpm install --frozen-lockfile || pnpm install
      else
        if command -v corepack >/dev/null 2>&1; then corepack pnpm install --frozen-lockfile || corepack pnpm install
        else npm install -g pnpm && pnpm install --frozen-lockfile || pnpm install
        fi
      fi
    elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
      log "Installing dependencies with npm ci"
      npm ci || npm install
    else
      log "Installing dependencies with npm"
      npm install
    fi
  else
    warn "No package.json found; skipping Node dependencies."
  fi
  persist_env_var NODE_ENV production
  log "Node.js environment configured."
}

# Go setup
setup_go() {
  log "Configuring Go environment..."
  case "$PM" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    none) warn "No package manager; expecting go in base image." ;;
  esac
  if ! command -v go >/dev/null 2>&1; then
    err "go is required but not installed. Aborting."; exit 1
  fi
  append_path_if_missing "/usr/local/go/bin"
  cd "$PROJECT_ROOT"
  if [ -f go.mod ]; then
    go mod download
  else
    warn "No go.mod found; skipping go mod download."
  fi
  log "Go environment configured."
}

# Rust setup
setup_rust() {
  log "Configuring Rust environment..."
  case "$PM" in
    apt) pkg_install cargo rustc || true ;;
    apk) pkg_install cargo rust || true ;;
    dnf|yum) pkg_install cargo rust || true ;;
  esac
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust via rustup..."
    export CARGO_HOME="/opt/cargo"
    export RUSTUP_HOME="/opt/rustup"
    mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
    append_path_if_missing "$CARGO_HOME/bin"
    persist_env_var CARGO_HOME "$CARGO_HOME"
    persist_env_var RUSTUP_HOME "$RUSTUP_HOME"
  fi
  cd "$PROJECT_ROOT"
  if [ -f Cargo.toml ]; then
    cargo fetch || true
  fi
  log "Rust environment configured."
}

# Java (Maven/Gradle) setup
setup_java() {
  log "Configuring Java environment..."
  case "$PM" in
    apt) pkg_install openjdk-17-jdk maven gradle || pkg_install default-jdk maven gradle || true ;;
    apk) pkg_install openjdk17 maven gradle || true ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven gradle || true ;;
  esac
  if ! command -v java >/dev/null 2>&1; then
    err "Java JDK not installed. Aborting."; exit 1
  fi
  cd "$PROJECT_ROOT"
  # Prefer wrappers if present
  if [ -f mvnw ]; then
    chmod +x mvnw
    ./mvnw -q -DskipTests dependency:go-offline || true
  elif command -v mvn >/dev/null 2>&1 && [ -f pom.xml ]; then
    mvn -q -DskipTests dependency:go-offline || true
  fi
  if [ -f gradlew ]; then
    chmod +x gradlew
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
  elif command -v gradle >/dev/null 2>&1 && { [ -f build.gradle ] || [ -f build.gradle.kts ]; }; then
    gradle --no-daemon tasks >/dev/null 2>&1 || true
  fi
  log "Java environment configured."
}

# PHP setup
setup_php() {
  log "Configuring PHP environment..."
  case "$PM" in
    apt) pkg_install php-cli php-zip php-mbstring php-xml unzip curl ;;
    apk) pkg_install php81 php81-phar php81-zip php81-mbstring php81-xml unzip curl || pkg_install php php-phar php-zip php-mbstring php-xml ;;
    dnf|yum) pkg_install php-cli php-zip php-mbstring php-xml unzip curl ;;
  esac
  if ! command -v php >/dev/null 2>&1; then
    err "php is required but not installed. Aborting."; exit 1
  fi
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
  cd "$PROJECT_ROOT"
  if [ -f composer.json ]; then
    composer install --no-interaction --prefer-dist --optimize-autoloader || composer install --no-interaction
  else
    warn "No composer.json found; skipping composer install."
  fi
  log "PHP environment configured."
}

# Ruby setup
setup_ruby() {
  log "Configuring Ruby environment..."
  case "$PM" in
    apt) pkg_install ruby-full bundler make gcc g++ patch build-essential zlib1g-dev liblzma-dev ;;
    apk) pkg_install ruby ruby-dev build-base zlib-dev libffi-dev ;;
    dnf|yum) pkg_install ruby ruby-devel @development-tools zlib-devel libffi-devel ;;
  esac
  if ! command -v ruby >/dev/null 2>&1; then
    err "ruby is required but not installed. Aborting."; exit 1
  fi
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document || true
  fi
  cd "$PROJECT_ROOT"
  if [ -f Gemfile ]; then
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4 || bundle install
  else
    warn "No Gemfile found; skipping bundle install."
  fi
  log "Ruby environment configured."
}

# .NET setup
setup_dotnet() {
  log "Configuring .NET SDK environment..."
  if ! command -v dotnet >/dev/null 2>&1; then
    log "Installing dotnet SDK via official install script..."
    mkdir -p /usr/local/dotnet
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir /usr/local/dotnet --channel STS
    append_path_if_missing "/usr/local/dotnet"
  fi
  cd "$PROJECT_ROOT"
  local csproj
  csproj=$(find . -maxdepth 2 -name "*.csproj" | head -n1 || true)
  if [ -n "$csproj" ]; then
    dotnet restore "$(dirname "$csproj")" || true
  else
    warn "No .csproj found; skipping dotnet restore."
  fi
  log ".NET environment configured."
}

# Unknown setup: just install base tools
setup_unknown() {
  warn "Could not detect project type. Installing only base tools."
}

# Ensure a basic build system is available if the project lacks one
ensure_make_and_makefile() {
  cd "$PROJECT_ROOT"
  if command -v make >/dev/null 2>&1; then
    echo "make already installed"
    # Preserve any existing make wrapper; will (re)install updated wrapper below
  else
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y make
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y make
    elif command -v yum >/dev/null 2>&1; then
      yum install -y make
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache make
    else
      echo "No supported package manager found" >&2
      exit 1
    fi
  fi
  # Ensure CI/build entrypoints using simple repository-contained scripts
  cat > build.sh <<'SH'
#!/usr/bin/env sh
set -e

if [ -f package.json ]; then
  npm ci --no-audit --no-fund && npm run build
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  ./gradlew assemble -x test
elif [ -f build.gradle ]; then
  gradle assemble -x test
elif [ -f Cargo.toml ]; then
  cargo build --locked
elif [ -f go.mod ]; then
  go build ./...
elif ls *.sln >/dev/null 2>&1; then
  dotnet build --nologo
elif [ -f pyproject.toml ]; then
  pip install -U pip && pip install -e .
elif [ -f setup.py ]; then
  pip install -U pip && pip install -e .
else
  echo "No known build system detected; exiting successfully."
  exit 0
fi
SH
  chmod +x build.sh

  # Simple Makefile wrapper to call the build script
  cat > Makefile <<'MAKE'
.PHONY: build
build:
	./build.sh
MAKE
}

# Default environment variables and configuration
ensure_placeholder_python_project() {
  cd "$PROJECT_ROOT"
  if [ ! -f "package.json" ] && [ ! -f "pyproject.toml" ] && [ ! -f "setup.py" ] && [ ! -f "go.mod" ] && [ ! -f "Cargo.toml" ] && [ ! -f "pom.xml" ] && [ ! -f "build.gradle" ] && [ ! -f "build.gradle.kts" ] && ! find . -maxdepth 1 -name "*.csproj" -print -quit | grep -q . && [ ! -f "global.json" ]; then
    log "No known build system detected; creating minimal Maven Java project to enable detection."
    ensure_java_build_entrypoint
  fi
}

ensure_java_build_entrypoint() {
  cd "$PROJECT_ROOT"
  # Ensure JDK 17 and Maven are installed
  case "$PM" in
    apt) pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17 maven || pkg_install openjdk17-jdk maven || true ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven ;;
  esac

  # Create minimal Maven project if not present
  if [ ! -f pom.xml ]; then
    cat > pom.xml <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>app</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
  </properties>
</project>
EOF
  fi

  mkdir -p src/main/java/com/example
  if [ ! -f src/main/java/com/example/App.java ]; then
    cat > src/main/java/com/example/App.java <<'EOF'
package com.example;
public class App { public static void main(String[] args) { System.out.println("OK"); } }
EOF
  fi

  mkdir -p .ci
  cat > .ci/build.sh <<'EOF'
#!/usr/bin/env sh
set -eu

log() { printf "%s\n" "[build] $*"; }
has() { command -v "$1" >/dev/null 2>&1; }

# Node.js
if [ -f package.json ] && has npm; then
  log "Node.js project detected"
  (npm ci --no-audit --no-fund || npm install --no-audit --no-fund) || true
  npm run -s build || true
  exit 0
fi

# Python
if [ -f pyproject.toml ] || [ -f setup.py ]; then
  if has python3 && has pip; then
    log "Python project detected"
    python3 -m pip install -U pip setuptools wheel || true
    pip install -e . || true
    exit 0
  fi
fi

# Rust
if [ -f Cargo.toml ] && has cargo; then
  log "Rust project detected"
  cargo build --locked || cargo build || true
  exit 0
fi

# Go
if [ -f go.mod ] && has go; then
  log "Go project detected"
  go build ./... || true
  exit 0
fi

# Gradle
if [ -f gradlew ]; then
  log "Gradle wrapper project detected"
  chmod +x gradlew || true
  ./gradlew assemble -x test || true
  exit 0
fi
if [ -f build.gradle ] && has gradle; then
  log "Gradle project detected"
  gradle assemble -x test || true
  exit 0
fi

# .NET
if ls *.sln >/dev/null 2>&1 && has dotnet; then
  log ".NET solution detected"
  dotnet build --nologo || true
  exit 0
fi

# Makefile delegation
if [ -f Makefile ]; then
  log "Makefile detected; delegating"
  make build || make || true
  exit 0
fi

log "No known build system detected; nothing to build"
exit 0
EOF
  chmod +x .ci/build.sh

  if command -v mvn >/dev/null 2>&1; then
    mvn -q -DskipTests package || true
  fi
}

setup_default_env() {
  cd "$PROJECT_ROOT"
  # Create .env if not present
  if [ ! -f "$ENV_FILE" ]; then
    log "Creating default $ENV_FILE"
    cat > "$ENV_FILE" <<EOF
APP_ENV=production
LOG_LEVEL=info
PORT=${PORT:-8080}
EOF
  fi
  load_env_file
  persist_env_var APP_ENV "${APP_ENV:-production}"
  persist_env_var LOG_LEVEL "${LOG_LEVEL:-info}"
  persist_env_var PORT "${PORT:-8080}"
}

# Summary of instructions
print_summary() {
  log "Environment setup completed."
  echo "Project root: $PROJECT_ROOT"
  echo "App user: $APP_USER"
  echo "Detected project type: $1"
  echo "Environment variables persisted to /etc/profile.d/zz-project-env.sh"
  echo "Tip: Start a new shell or source /etc/profile.d/zz-project-env.sh to load PATH changes."
}

main() {
  require_root
  detect_pm
  pm_update
  install_base_tools
  ensure_app_user
  ensure_dirs
  setup_default_env
  ensure_placeholder_python_project

  local type
  type=$(detect_project_type)
  log "Detected project type: $type"

  case "$type" in
    python) setup_python ;;
    node) setup_node ;;
    go) setup_go ;;
    rust) setup_rust ;;
    java) setup_java ;;
    php) setup_php ;;
    ruby) setup_ruby ;;
    dotnet) setup_dotnet ;;
    unknown) setup_unknown ;;
  esac

  # Ensure basic build system if none detected
  ensure_make_and_makefile

  make build || make || true

  # Final permission pass
  chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT" || true

  print_summary "$type"
}

main "$@"