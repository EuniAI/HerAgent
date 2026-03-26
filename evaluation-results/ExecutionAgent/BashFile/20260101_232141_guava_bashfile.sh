#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type (Python/Node/Ruby/Go/Rust/Java/PHP)
# - Installs runtimes and system dependencies
# - Sets up directory structure and permissions
# - Configures environment for containerized execution
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# --- Output formatting ---
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }

on_error() {
  local exit_code=$?
  err "Setup failed at line ${BASH_LINENO[0]} (exit code $exit_code)."
  exit "$exit_code"
}
trap on_error ERR

# --- Configurable defaults (override via environment variables) ---
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
CREATE_USER="${CREATE_USER:-true}"        # true|false
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"    # expects script to run at project root
ENV_FILE="${ENV_FILE:-.env}"              # will create if not exists
ENV_MODE="${ENV_MODE:-development}"       # development|production
DEFAULT_PORT="${DEFAULT_PORT:-8080}"      # fallback when undetectable
PYTHON_VENV_DIR="${PYTHON_VENV_DIR:-.venv}"

# --- Globals ---
PKG_MGR=""
UPDATE_DONE="false"
OS_ID=""
OS_VERSION_ID=""

# --- Helper functions ---
need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_platform() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
  fi

  if need_cmd apt-get; then
    PKG_MGR="apt"
  elif need_cmd apk; then
    PKG_MGR="apk"
  elif need_cmd dnf; then
    PKG_MGR="dnf"
  elif need_cmd yum; then
    PKG_MGR="yum"
  elif need_cmd zypper; then
    PKG_MGR="zypper"
  else
    PKG_MGR="unknown"
  fi

  log "Detected platform: ID=${OS_ID:-unknown}, VERSION=${OS_VERSION_ID:-unknown}, PKG_MGR=$PKG_MGR"
}

pkg_update() {
  if [ "$UPDATE_DONE" = "true" ]; then
    return 0
  fi

  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      UPDATE_DONE="true"
      ;;
    apk)
      apk update
      UPDATE_DONE="true"
      ;;
    dnf)
      dnf -y makecache
      UPDATE_DONE="true"
      ;;
    yum)
      yum -y makecache
      UPDATE_DONE="true"
      ;;
    zypper)
      zypper --gpg-auto-import-keys refresh
      UPDATE_DONE="true"
      ;;
    *)
      warn "Unknown package manager; cannot run update."
      ;;
  esac
}

install_pkgs() {
  # Arguments are package names appropriate for the detected package manager
  [ "$#" -gt 0 ] || return 0
  case "$PKG_MGR" in
    apt)
      pkg_update
      # shellcheck disable=SC2068
      apt-get install -y --no-install-recommends $@
      ;;
    apk)
      pkg_update
      # shellcheck disable=SC2068
      apk add --no-cache $@
      ;;
    dnf)
      pkg_update
      # shellcheck disable=SC2068
      dnf install -y $@
      ;;
    yum)
      pkg_update
      # shellcheck disable=SC2068
      yum install -y $@
      ;;
    zypper)
      pkg_update
      # shellcheck disable=SC2068
      zypper install -y $@
      ;;
    *)
      warn "Unknown package manager; unable to install: $*"
      return 1
      ;;
  esac
}

ensure_base_tools() {
  log "Ensuring base tools are installed..."
  case "$PKG_MGR" in
    apt)
      install_pkgs ca-certificates curl git unzip tar xz-utils bash coreutils findutils procps gnupg
      ;;
    apk)
      install_pkgs ca-certificates curl git unzip tar xz bash coreutils findutils procps-ng gnupg
      ;;
    dnf|yum)
      install_pkgs ca-certificates curl git unzip tar xz bash coreutils findutils procps-ng gnupg
      ;;
    zypper)
      install_pkgs ca-certificates curl git unzip tar xz bash coreutils findutils procps gnupg
      ;;
    *)
      warn "Base tools installation skipped due to unknown package manager."
      ;;
  esac
  update-ca-certificates >/dev/null 2>&1 || true
}

# --- Directory and permissions setup ---
setup_directories() {
  log "Setting up project directory structure at: $PROJECT_ROOT"

  mkdir -p "$PROJECT_ROOT"/{logs,tmp,data,cache}
  # Ensure ownership and permissions: create app user if requested and running as root
  if [ "${CREATE_USER}" = "true" ] && [ "$(id -u)" -eq 0 ]; then
    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
      groupadd -r "$APP_GROUP" || true
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      useradd -m -r -g "$APP_GROUP" -s /bin/bash "$APP_USER" || true
    fi
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT"
  else
    warn "Skipping app user creation or chown (CREATE_USER=$CREATE_USER, EUID=$(id -u))"
  fi
}

# --- Env file management ---
ensure_env_file() {
  local env_path="$PROJECT_ROOT/$ENV_FILE"
  if [ ! -f "$env_path" ]; then
    log "Creating environment file: $env_path"
    {
      echo "APP_ENV=${ENV_MODE}"
      echo "APP_PORT=${DEFAULT_PORT}"
      echo "LOG_LEVEL=info"
      echo "TZ=UTC"
      echo "PYTHONDONTWRITEBYTECODE=1"
      echo "PIP_NO_CACHE_DIR=1"
      echo "NODE_ENV=${ENV_MODE}"
    } > "$env_path"
  else
    log "Environment file exists: $env_path"
  fi
}

# --- Project type detection ---
detect_project_type() {
  # Sets global variables indicating the detected project types.
  IS_PYTHON="false"
  IS_NODE="false"
  IS_RUBY="false"
  IS_GO="false"
  IS_RUST="false"
  IS_JAVA_MAVEN="false"
  IS_JAVA_GRADLE="false"
  IS_PHP="false"
  IS_DOTNET="false"

  if [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/Pipfile" ]; then
    IS_PYTHON="true"
  fi
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    IS_NODE="true"
  fi
  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    IS_RUBY="true"
  fi
  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    IS_GO="true"
  fi
  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    IS_RUST="true"
  fi
  if [ -f "$PROJECT_ROOT/pom.xml" ]; then
    IS_JAVA_MAVEN="true"
  fi
  if [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ] || [ -f "$PROJECT_ROOT/gradlew" ]; then
    IS_JAVA_GRADLE="true"
  fi
  if [ -f "$PROJECT_ROOT/composer.json" ]; then
    IS_PHP="true"
  fi
  if compgen -G "$PROJECT_ROOT/*.sln" >/dev/null || compgen -G "$PROJECT_ROOT/*.csproj" >/dev/null; then
    IS_DOTNET="true"
  fi

  log "Detected project types => Python:$IS_PYTHON, Node:$IS_NODE, Ruby:$IS_RUBY, Go:$IS_GO, Rust:$IS_RUST, Java(Maven):$IS_JAVA_MAVEN, Java(Gradle):$IS_JAVA_GRADLE, PHP:$IS_PHP, .NET:$IS_DOTNET"
}

# --- Python setup ---
install_python_runtime() {
  log "Installing Python runtime and build deps..."
  case "$PKG_MGR" in
    apt)
      install_pkgs python3 python3-pip python3-venv python3-dev build-essential \
                   libffi-dev libssl-dev libpq-dev zlib1g-dev libxml2-dev libxslt1-dev
      ;;
    apk)
      install_pkgs python3 py3-pip python3-dev build-base libffi-dev openssl-dev \
                   postgresql-dev zlib-dev libxml2-dev libxslt-dev
      ;;
    dnf|yum)
      install_pkgs python3 python3-pip python3-devel gcc gcc-c++ make \
                   libffi-devel openssl-devel libpq-devel zlib-devel libxml2-devel libxslt-devel
      ;;
    zypper)
      install_pkgs python3 python3-pip python3-virtualenv python3-devel gcc gcc-c++ make \
                   libffi-devel libopenssl-devel libpq-devel zlib-devel libxml2-devel libxslt-devel
      ;;
    *)
      err "Unsupported package manager for Python installation."
      return 1
      ;;
  esac
}

setup_python_env() {
  log "Configuring Python environment..."
  if [ ! -d "$PROJECT_ROOT/$PYTHON_VENV_DIR" ]; then
    python3 -m venv "$PROJECT_ROOT/$PYTHON_VENV_DIR"
  fi
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/$PYTHON_VENV_DIR/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    log "Installing Python packages from requirements.txt"
    pip install -r "$PROJECT_ROOT/requirements.txt"
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    # Prefer PEP 517 build if present
    log "Installing Python project from pyproject.toml"
    pip install .
  elif [ -f "$PROJECT_ROOT/Pipfile" ]; then
    log "Installing pipenv and resolving dependencies..."
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  else
    warn "No Python dependency file found."
  fi

  deactivate || true
}

# --- Node.js setup ---
install_node_runtime() {
  log "Installing Node.js runtime..."
  case "$PKG_MGR" in
    apt)
      pkg_update
      # NodeSource LTS setup (idempotent)
      curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
      install_pkgs nodejs
      ;;
    apk)
      install_pkgs nodejs npm
      ;;
    dnf|yum)
      pkg_update
      curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
      install_pkgs nodejs
      ;;
    zypper)
      # zypper's node version may be older; attempt install
      install_pkgs nodejs npm || warn "Failed installing Node.js with zypper; please verify repository availability."
      ;;
    *)
      err "Unsupported package manager for Node installation."
      return 1
      ;;
  esac
}

setup_node_env() {
  log "Configuring Node.js environment..."
  pushd "$PROJECT_ROOT" >/dev/null
  # Prefer deterministic install using lockfiles
  if [ -f "yarn.lock" ]; then
    if ! need_cmd yarn; then
      log "Installing Yarn (via corepack if available)..."
      if need_cmd corepack; then
        corepack enable
      fi
      npm -g install yarn
    fi
    yarn install --frozen-lockfile || yarn install
  elif [ -f "pnpm-lock.yaml" ]; then
    log "Enabling corepack and installing pnpm..."
    if need_cmd corepack; then
      corepack enable
      corepack prepare pnpm@latest --activate || true
    else
      npm -g install pnpm
    fi
    pnpm install --frozen-lockfile || pnpm install
  elif [ -f "package-lock.json" ]; then
    npm ci || npm install
  else
    if [ -f "package.json" ]; then
      npm install
    fi
  fi
  popd >/dev/null
}

# --- Ruby setup ---
install_ruby_runtime() {
  log "Installing Ruby runtime..."
  case "$PKG_MGR" in
    apt)
      install_pkgs ruby-full build-essential
      ;;
    apk)
      install_pkgs ruby ruby-dev build-base
      ;;
    dnf|yum)
      install_pkgs ruby ruby-devel gcc gcc-c++ make
      ;;
    zypper)
      install_pkgs ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      err "Unsupported package manager for Ruby."
      return 1
      ;;
  esac
}

setup_ruby_env() {
  log "Configuring Ruby environment..."
  if ! need_cmd bundler; then
    gem install bundler -N
  fi
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "Gemfile" ]; then
    if [ "$ENV_MODE" = "production" ]; then
      bundle config set without 'development test'
    fi
    bundle install --jobs=4 --retry=3
  fi
  popd >/dev/null
}

# --- Go setup ---
install_go_runtime() {
  log "Installing Go runtime..."
  case "$PKG_MGR" in
    apt)
      install_pkgs golang
      ;;
    apk)
      install_pkgs go
      ;;
    dnf|yum)
      install_pkgs golang
      ;;
    zypper)
      install_pkgs go
      ;;
    *)
      err "Unsupported package manager for Go."
      return 1
      ;;
  esac
}

setup_go_env() {
  log "Configuring Go environment..."
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "go.mod" ]; then
    go env -w GO111MODULE=on || true
    go mod download
  fi
  popd >/dev/null
}

# --- Rust setup ---
install_rust_runtime() {
  log "Installing Rust toolchain..."
  case "$PKG_MGR" in
    apt)
      install_pkgs cargo rustc
      ;;
    apk)
      install_pkgs cargo rust
      ;;
    dnf|yum)
      install_pkgs cargo rust
      ;;
    zypper)
      install_pkgs cargo rust
      ;;
    *)
      err "Unsupported package manager for Rust."
      return 1
      ;;
  esac
}

setup_rust_env() {
  log "Configuring Rust environment..."
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "Cargo.toml" ]; then
    cargo fetch
  fi
  popd >/dev/null
}

# --- Java setup ---
install_java_runtime() {
  log "Installing Java runtime (OpenJDK 17)..."
  case "$PKG_MGR" in
    apt)
      install_pkgs openjdk-17-jdk ca-certificates-java
      ;;
    apk)
      install_pkgs openjdk17
      ;;
    dnf|yum)
      install_pkgs java-17-openjdk java-17-openjdk-devel
      ;;
    zypper)
      install_pkgs java-17-openjdk java-17-openjdk-devel
      ;;
    *)
      err "Unsupported package manager for Java."
      return 1
      ;;
  esac
}

setup_java_maven() {
  log "Configuring Maven environment..."
  case "$PKG_MGR" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y openjdk-17-jdk ca-certificates-java ca-certificates maven ;;
    apk) install_pkgs maven ;;
    dnf|yum) install_pkgs maven ;;
    zypper) install_pkgs maven ;;
    *) warn "Unable to install Maven automatically." ;;
  esac
  # Ensure JDK 17 is available and configure Maven toolchains to use it
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y openjdk-17-jdk ca-certificates-java
  elif command -v yum >/dev/null 2>&1; then
    yum install -y java-17-openjdk java-17-openjdk-devel
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache openjdk17
  else
    echo "No supported package manager found to install OpenJDK 17" && exit 1
  fi
  mkdir -p ~/.m2
  JDK_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  [ -n "$JDK_HOME" ] && [ -d "$JDK_HOME" ] || JDK_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
  export JAVA_HOME="$JDK_HOME"
  export PATH="$JAVA_HOME/bin:$PATH"
  # Persist system-wide for future shells
  if [ -d /etc/profile.d ] && [ "$(id -u)" -eq 0 ]; then
    printf 'export JAVA_HOME=%s\nexport PATH=$JAVA_HOME/bin:$PATH\n' "$JDK_HOME" > /etc/profile.d/java_home.sh
    chmod 644 /etc/profile.d/java_home.sh
  fi
  # Set system alternatives to JDK 17 if available
  update-alternatives --install /usr/bin/java java /usr/lib/jvm/java-17-openjdk-amd64/bin/java 171 || true
  [ -x /usr/lib/jvm/java-17-openjdk-amd64/bin/java ] && update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java || true
  [ -x /usr/lib/jvm/java-17-openjdk-amd64/bin/javac ] && update-alternatives --set javac /usr/lib/jvm/java-17-openjdk-amd64/bin/javac || true
  # Defensive fallback for Maven wrapper expecting $JAVA_HOME/bin/java relative to project root
  mkdir -p /app/bin && ln -sf /usr/lib/jvm/java-17-openjdk-amd64/bin/java /app/bin/java || true
  mkdir -p ~/.m2
  # Legacy variable retained for compatibility
  JAVAHOME="$JDK_HOME"
  cat > ~/.m2/toolchains.xml <<'EOF'
<toolchains>
  <toolchain>
    <type>jdk</type>
    <provides>
      <version>17</version>
      <vendor>openjdk</vendor>
    </provides>
    <configuration>
      <jdkHome>/usr/lib/jvm/java-17-openjdk-amd64</jdkHome>
    </configuration>
  </toolchain>
</toolchains>
EOF
# Configure Maven to prioritize snapshot repositories and always update snapshots
cat > ~/.m2/settings.xml <<'EOF'
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <profiles>
    <profile>
      <id>extra-snapshots</id>
      <repositories>
        <repository>
          <id>sonatype-snapshots</id>
          <url>https://oss.sonatype.org/content/repositories/snapshots/</url>
          <releases><enabled>false</enabled></releases>
          <snapshots><enabled>true</enabled><updatePolicy>always</updatePolicy></snapshots>
        </repository>
        <repository>
          <id>apache-snapshots</id>
          <url>https://repository.apache.org/snapshots</url>
          <releases><enabled>false</enabled></releases>
          <snapshots><enabled>true</enabled><updatePolicy>always</updatePolicy></snapshots>
        </repository>
      </repositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>extra-snapshots</activeProfile>
  </activeProfiles>
</settings>
EOF
# Purge cached failing snapshot artifacts to force re-resolution
rm -rf ~/.m2/repository/com/google/guava/guava-testlib ~/.m2/repository/com/google/guava/guava-tests || true
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "pom.xml" ]; then
    # Ensure Maven wrapper is executable
    chmod +x ./mvnw ./gradlew || true
    # Prefer Maven wrapper; fallback to system mvn
    if [ -x "./mvnw" ]; then
      chmod +x ./mvnw || true
      chmod +x ./gradlew || true
      ./mvnw -B -q -DskipTests dependency:go-offline || warn "Maven offline dependency resolution failed."
      [ -x ./mvnw ] || chmod +x ./mvnw
      ./mvnw -B -U -Dmaven.javadoc.skip=true -DskipTests=true --projects '!guava-testlib,!guava-tests,!guava-bom,!guava-gwt' install
    else
      chmod +x ./mvnw || true
      chmod +x ./gradlew || true
      mvn -B -U -Dmaven.javadoc.skip=true -DskipTests=true --projects '!guava-testlib,!guava-tests,!guava-bom,!guava-gwt' install
    fi
  fi
  popd >/dev/null
}

setup_java_gradle() {
  log "Configuring Gradle environment..."
  # Prefer wrapper if available; otherwise install gradle
  if [ ! -x "$PROJECT_ROOT/gradlew" ]; then
    case "$PKG_MGR" in
      apt) install_pkgs gradle ;;
      apk) install_pkgs gradle ;;
      dnf|yum) install_pkgs gradle ;;
      zypper) install_pkgs gradle ;;
      *) warn "Unable to install Gradle automatically." ;;
    esac
  fi
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
  else
    gradle --no-daemon tasks >/dev/null 2>&1 || true
  fi
  popd >/dev/null
}

# --- PHP setup ---
install_php_runtime() {
  log "Installing PHP runtime..."
  case "$PKG_MGR" in
    apt)
      install_pkgs php-cli php-mbstring php-xml php-curl php-zip unzip
      ;;
    apk)
      install_pkgs php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip
      ;;
    dnf|yum)
      install_pkgs php-cli php-mbstring php-xml php-curl php-zip unzip
      ;;
    zypper)
      install_pkgs php7 php7-cli php7-mbstring php7-xml php7-curl php7-zip unzip || \
      install_pkgs php8 php8-cli php8-mbstring php8-xml php8-curl php8-zip unzip
      ;;
    *)
      err "Unsupported package manager for PHP."
      return 1
      ;;
  esac

  if ! need_cmd composer; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      err "Invalid Composer installer signature"
      exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi
}

setup_php_env() {
  log "Configuring PHP environment with Composer..."
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "composer.json" ]; then
    if [ "$ENV_MODE" = "production" ]; then
      composer install --no-interaction --no-dev --prefer-dist
    else
      composer install --no-interaction --prefer-dist
    fi
  fi
  popd >/dev/null
}

# --- .NET setup (best-effort) ---
install_dotnet_runtime() {
  log "Attempting to install .NET SDK (best-effort)..."
  case "$PKG_MGR" in
    apt)
      pkg_update
      install_pkgs wget apt-transport-https
      wget -q https://packages.microsoft.com/config/"${OS_ID:-ubuntu}"/"${OS_VERSION_ID:-20.04}"/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || {
        warn "Failed to fetch Microsoft package repo descriptor; skipping .NET installation."
        return 0
      }
      dpkg -i /tmp/packages-microsoft-prod.deb || true
      rm -f /tmp/packages-microsoft-prod.deb
      pkg_update
      install_pkgs dotnet-sdk-8.0 || warn "Failed installing dotnet-sdk-8.0"
      ;;
    dnf|yum)
      warn ".NET SDK installation not fully automated for this distro in this script."
      ;;
    apk|zypper|*)
      warn ".NET SDK installation not supported by this script for this package manager."
      ;;
  esac
}

setup_dotnet_env() {
  log "Configuring .NET environment..."
  pushd "$PROJECT_ROOT" >/dev/null
  if compgen -G "*.sln" >/dev/null || compgen -G "*.csproj" >/dev/null; then
    if need_cmd dotnet; then
      dotnet restore || warn "dotnet restore failed"
    else
      warn "dotnet command not available; restore skipped."
    fi
  fi
  popd >/dev/null
}

# --- Port detection (best-effort) ---
detect_port() {
  local port="$DEFAULT_PORT"
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    # Try to detect common defaults for Node
    port="${PORT:-3000}"
  elif [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    # Common defaults for Python web
    port="${PORT:-8000}"
  elif [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ]; then
    port="${PORT:-8080}"
  elif [ -f "$PROJECT_ROOT/composer.json" ]; then
    port="${PORT:-8080}"
  fi
  echo "$port"
}

# --- Main ---

# Ensure the project's Python virtual environment auto-activates for interactive shells
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local venv_path="$PROJECT_ROOT/$PYTHON_VENV_DIR"
  local activate_line="source \"$venv_path/bin/activate\""
  if [ -d "$venv_path" ] && [ -f "$venv_path/bin/activate" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

# --- Main ---
main() {
  log "Starting project environment setup for Docker..."
  detect_platform
  ensure_base_tools
  setup_directories
  ensure_env_file
  detect_project_type

  # Add environment fixups for Maven/Gradle wrappers and ROOT_POM
  export ROOT_POM="${ROOT_POM:-pom.xml}"
  install -d /etc/profile.d && printf 'export ROOT_POM=${ROOT_POM:-pom.xml}\n' > /etc/profile.d/root_pom.sh && chmod 644 /etc/profile.d/root_pom.sh
  pushd "$PROJECT_ROOT" >/dev/null
  [ -f ./mvnw ] && chmod +x ./mvnw || true
  [ -f ./gradlew ] && chmod +x ./gradlew || true
  [ -f ./util/gradle_integration_tests.sh ] && chmod +x ./util/gradle_integration_tests.sh || true
  popd >/dev/null

  # Per-language installation and setup
  if [ "$IS_PYTHON" = "true" ]; then
    install_python_runtime
    setup_python_env
    setup_auto_activate
  fi

  if [ "$IS_NODE" = "true" ]; then
    install_node_runtime
    setup_node_env
  fi

  if [ "$IS_RUBY" = "true" ]; then
    install_ruby_runtime
    setup_ruby_env
  fi

  if [ "$IS_GO" = "true" ]; then
    install_go_runtime
    setup_go_env
  fi

  if [ "$IS_RUST" = "true" ]; then
    install_rust_runtime
    setup_rust_env
  fi

  if [ "$IS_JAVA_MAVEN" = "true" ] || [ "$IS_JAVA_GRADLE" = "true" ]; then
    install_java_runtime
    [ "$IS_JAVA_MAVEN" = "true" ] && setup_java_maven
    [ "$IS_JAVA_GRADLE" = "true" ] && setup_java_gradle
  fi

  if [ "$IS_PHP" = "true" ]; then
    install_php_runtime
    setup_php_env
  fi

  if [ "$IS_DOTNET" = "true" ]; then
    install_dotnet_runtime
    setup_dotnet_env
  fi

  # Write a profile snippet for environment variables inside container sessions
  if [ -d /etc/profile.d ] && [ "$(id -u)" -eq 0 ]; then
    cat >/etc/profile.d/app_env.sh <<EOF
# Auto-generated by setup script
[ -f "$PROJECT_ROOT/$ENV_FILE" ] && export \$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$PROJECT_ROOT/$ENV_FILE" | sed 's/=.*//') && set -a && . "$PROJECT_ROOT/$ENV_FILE" && set +a || true
EOF
    chmod 0644 /etc/profile.d/app_env.sh
  fi

  # Provide a simple run hint script
  RUN_HINT="$PROJECT_ROOT/run_hint.txt"
  PORT_DETECTED=$(detect_port)
  {
    echo "Environment setup completed successfully."
    echo "Project root: $PROJECT_ROOT"
    echo "App user: $APP_USER"
    echo "Mode: $ENV_MODE"
    echo "Suggested container port: $PORT_DETECTED"
    echo
    if [ "$IS_PYTHON" = "true" ]; then
      echo "Python:"
      echo "  source $PYTHON_VENV_DIR/bin/activate"
      echo "  Common run (Flask): FLASK_APP=app.py FLASK_RUN_PORT=$PORT_DETECTED flask run --host=0.0.0.0"
      echo "  Common run (Django): python manage.py runserver 0.0.0.0:$PORT_DETECTED"
      echo
    fi
    if [ "$IS_NODE" = "true" ]; then
      echo "Node.js:"
      echo "  npm start (ensure it binds to 0.0.0.0:$PORT_DETECTED inside container)"
      echo
    fi
    if [ "$IS_RUBY" = "true" ]; then
      echo "Ruby:"
      echo "  bundle exec rails server -b 0.0.0.0 -p $PORT_DETECTED  (for Rails)"
      echo
    fi
    if [ "$IS_GO" = "true" ]; then
      echo "Go:"
      echo "  go run ./...  (ensure server binds to 0.0.0.0:$PORT_DETECTED)"
      echo
    fi
    if [ "$IS_RUST" = "true" ]; then
      echo "Rust:"
      echo "  cargo run  (ensure server binds to 0.0.0.0:$PORT_DETECTED)"
      echo
    fi
    if [ "$IS_JAVA_MAVEN" = "true" ] || [ "$IS_JAVA_GRADLE" = "true" ]; then
      echo "Java:"
      echo "  mvn spring-boot:run or ./gradlew bootRun  (ensure server binds to 0.0.0.0:$PORT_DETECTED)"
      echo
    fi
    if [ "$IS_PHP" = "true" ]; then
      echo "PHP:"
      echo "  php -S 0.0.0.0:$PORT_DETECTED -t public  (adjust docroot as needed)"
      echo
    fi
    if [ "$IS_DOTNET" = "true" ]; then
      echo ".NET:"
      echo "  dotnet run --urls http://0.0.0.0:$PORT_DETECTED"
      echo
    fi
  } > "$RUN_HINT"

  log "Setup complete. See $RUN_HINT for run instructions."
}

main "$@"