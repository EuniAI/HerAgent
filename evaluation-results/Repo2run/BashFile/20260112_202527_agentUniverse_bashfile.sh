#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust, .NET)
# Installs runtime and dependencies, sets up directories and environment variables.
#
# Usage:
#   Place this script in your project root (or run from project root) and execute:
#   bash setup_env.sh
#
# Notes:
# - Designed to run as root inside Docker (no sudo required).
# - Idempotent: safe to run multiple times.
# - Supports Debian/Ubuntu (apt), Alpine (apk), and RHEL/CentOS/Fedora (yum/dnf).
# - Respects environment variables: APP_ROOT, APP_USER, APP_ENV, CREATE_APP_USER, APP_PORT.

set -Eeuo pipefail
IFS=$'\n\t'

# Globals
SCRIPT_NAME="$(basename "$0")"
START_TIME="$(date +%s)"

# Basic logging
log()   { echo "[INFO]  $(date +'%Y-%m-%d %H:%M:%S') - $*"; }
warn()  { echo "[WARN]  $(date +'%Y-%m-%d %H:%M:%S') - $*" >&2; }
error() { echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $*" >&2; }
die()   { error "$*"; exit 1; }

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    error "Setup failed with exit code $exit_code"
  else
    local end_time
    end_time="$(date +%s)"
    log "Setup completed in $((end_time - START_TIME))s"
  fi
}
trap cleanup EXIT

# Utility functions
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Detect package manager and OS family
PKG_MGR=""
OS_FAMILY=""
detect_pkg_mgr() {
  if command_exists apt-get; then
    PKG_MGR="apt"
    OS_FAMILY="debian"
  elif command_exists apk; then
    PKG_MGR="apk"
    OS_FAMILY="alpine"
  elif command_exists dnf; then
    PKG_MGR="dnf"
    OS_FAMILY="rhel"
  elif command_exists yum; then
    PKG_MGR="yum"
    OS_FAMILY="rhel"
  else
    die "Unsupported base OS: no known package manager found (apt/apk/dnf/yum)."
  fi
}

# Perform package index update once per run
PKG_UPDATED="no"
pkg_update() {
  if [ "$PKG_UPDATED" = "yes" ]; then
    return 0
  fi
  case "$PKG_MGR" in
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
  esac
  PKG_UPDATED="yes"
}

# Install packages idempotently
install_packages() {
  # Arguments: list of packages
  [ $# -ge 1 ] || return 0
  pkg_update
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf)
      dnf -y install "$@"
      dnf -y clean all
      ;;
    yum)
      yum -y install "$@"
      yum -y clean all
      ;;
  esac
}

# Ensure Maven and JDK are installed and verify mvn
ensure_maven_jdk() {
  case "$PKG_MGR" in
    apt)
      if ! command_exists mvn; then
        log "Installing Maven and default JDK (apt)"
        install_packages maven default-jdk
      fi
      # Install mvn PATH wrapper to auto-detect pom.xml when not in project root
      if command_exists mvn; then
        mvn -v || true
        mkdir -p /usr/local/bin
        cat > /usr/local/bin/mvn <<'EOF'
#!/usr/bin/env sh
set -eu
# Prefer system Maven binary
if [ -x /usr/bin/mvn ]; then
  REAL_MVN="/usr/bin/mvn"
else
  REAL_MVN=$(command -v mvn 2>/dev/null || true)
fi
if [ -z "${REAL_MVN:-}" ]; then
  echo "Maven (mvn) not found on PATH." >&2
  exit 127
fi
# If pom.xml exists here, run normally
if [ -f "pom.xml" ]; then
  exec "$REAL_MVN" "$@"
fi
# Otherwise, search for a single pom.xml (skip target and hidden dirs)
POMS=$(find . -type f -name pom.xml -not -path "*/target/*" -not -path "*/.*/*")
COUNT=$(printf "%s\n" "$POMS" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$COUNT" -eq 1 ]; then
  ONE=$(printf "%s\n" "$POMS" | sed 's|^\./||')
  DIR=$(dirname "$ONE")
  cd "$DIR"
  exec "$REAL_MVN" "$@"
fi
echo "No pom.xml in $(pwd), and found $COUNT candidate(s). Cannot auto-select." >&2
if [ "$COUNT" -gt 1 ]; then
  printf '%s\n' "$POMS" >&2
fi
exit 1
EOF
        chmod +x /usr/local/bin/mvn || true
      fi
      ;;
    yum|dnf)
      if ! command_exists mvn; then
        log "Installing Maven and JDK ($PKG_MGR)"
        install_packages maven java-11-openjdk-devel
      fi
      ;;
    apk)
      if ! command_exists mvn; then
        log "Installing Maven and JDK (apk)"
        install_packages maven openjdk11
      fi
      ;;
  esac
}

# Ensure minimal Maven project if none exists at APP_ROOT
ensure_minimal_maven_project() {
  local pom_file="${APP_ROOT:-$(pwd)}/pom.xml"
  if [ ! -f "$pom_file" ]; then
    log "No pom.xml found at $pom_file; creating a minimal Maven project"
    cat > "$pom_file" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>app</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.release>11</maven.compiler.release>
  </properties>
</project>
EOF
  fi
}

# Ensure executable JAR by adding a minimal Main class and manifest if needed
ensure_maven_executable_jar() {
  pushd "$APP_ROOT" >/dev/null

  # Create minimal Java application and proper Maven configuration
  mkdir -p src/main/java/com/example
  cat > pom.xml <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>app</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
  <name>app</name>
  <properties>
    <maven.compiler.source>11</maven.compiler.source>
    <maven.compiler.target>11</maven.compiler.target>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-jar-plugin</artifactId>
        <version>3.2.2</version>
        <configuration>
          <archive>
            <manifest>
              <mainClass>com.example.App</mainClass>
            </manifest>
          </archive>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
EOF

  cat > src/main/java/com/example/App.java <<'EOF'
package com.example;

public class App {
    public static void main(String[] args) {
        System.out.println("Hello, World!");
    }
}
EOF

  mvn -q -DskipTests package || true
  popd >/dev/null
}

# Create non-root user optionally
maybe_create_user() {
  local user="${APP_USER:-app}"
  local create="${CREATE_APP_USER:-no}"
  if [ "$create" != "yes" ]; then
    log "Skipping creation of non-root user (CREATE_APP_USER != yes). Running as current user."
    return 0
  fi
  if id -u "$user" >/dev/null 2>&1; then
    log "User '$user' already exists."
    return 0
  fi

  case "$OS_FAMILY" in
    debian|rhel)
      install_packages passwd
      useradd -m -s /bin/bash "$user" || adduser -D "$user" || true
      ;;
    alpine)
      # Busybox adduser
      adduser -D "$user" || true
      ;;
    *)
      warn "Unknown OS family; cannot create user '$user'."
      return 0
      ;;
  esac
  log "Created user '$user'."
}

# Load environment variables from .env file if present
load_dotenv() {
  local dotfile="$APP_ROOT/.env"
  if [ -f "$dotfile" ]; then
    log "Loading environment variables from $dotfile"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        \#*|"") continue ;;
        *)
          if echo "$line" | grep -q '='; then
            # only export simple KEY=VALUE lines
            export "$line"
          fi
          ;;
      esac
    done < "$dotfile"
  fi
}

# Ensure directory structure
ensure_directories() {
  mkdir -p "$APP_ROOT"
  mkdir -p "$APP_ROOT"/{bin,logs,tmp,config}
  # Create typical cache dirs
  mkdir -p "$APP_ROOT"/.cache
  # Ownership
  if [ "${CREATE_APP_USER:-no}" = "yes" ] && id -u "${APP_USER:-app}" >/dev/null 2>&1; then
    chown -R "${APP_USER:-app}:${APP_USER:-app}" "$APP_ROOT"
  fi
  log "Ensured directory structure under $APP_ROOT"
}

# Project detection helpers
is_python_project() { [ -f "$APP_ROOT/requirements.txt" ] || [ -f "$APP_ROOT/pyproject.toml" ] || [ -f "$APP_ROOT/Pipfile" ]; }
is_node_project()   { [ -f "$APP_ROOT/package.json" ]; }
is_ruby_project()   { [ -f "$APP_ROOT/Gemfile" ]; }
is_go_project()     { [ -f "$APP_ROOT/go.mod" ] || [ -f "$APP_ROOT/go.sum" ]; }
is_java_maven()     { [ -f "$APP_ROOT/pom.xml" ]; }
is_java_gradle()    { [ -f "$APP_ROOT/build.gradle" ] || [ -f "$APP_ROOT/gradlew" ]; }
is_php_project()    { [ -f "$APP_ROOT/composer.json" ]; }
is_rust_project()   { [ -f "$APP_ROOT/Cargo.toml" ]; }
is_dotnet_project() { ls "$APP_ROOT"/*.csproj >/dev/null 2>&1 || ls "$APP_ROOT"/*.fsproj >/dev/null 2>&1 || [ -f "$APP_ROOT/global.json" ]; }

# Python setup
setup_python() {
  log "Detected Python project"
  case "$OS_FAMILY" in
    debian|rhel)
      install_packages python3 python3-venv python3-pip ca-certificates git curl build-essential pkg-config libffi-dev libssl-dev zlib1g-dev
      # Optional DB client headers commonly needed
      install_packages libpq-dev || true
      ;;
    alpine)
      install_packages python3 py3-pip ca-certificates git curl build-base libffi-dev openssl-dev zlib-dev
      # Optional DB dev packages
      install_packages postgresql-dev || true
      ;;
  esac

  # Virtual environment
  local venv_dir="$APP_ROOT/.venv"
  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Python virtual environment already exists at $venv_dir"
  fi
  # Activate
  # shellcheck disable=SC1090
  . "$venv_dir/bin/activate"

  # Upgrade pip tooling
  pip install --upgrade pip setuptools wheel

  # Install dependencies
  if [ -f "$APP_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "$APP_ROOT/requirements.txt"
  elif [ -f "$APP_ROOT/pyproject.toml" ]; then
    if grep -qi '\[tool.poetry\]' "$APP_ROOT/pyproject.toml"; then
      log "Poetry project detected; installing Poetry"
      pip install "poetry>=1.5"
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi
    else
      log "PEP 517/518 project detected; attempting pip install ."
      pip install .
    fi
  elif [ -f "$APP_ROOT/Pipfile" ]; then
    log "Pipenv project detected; installing pipenv"
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
  fi

  # Default environment variables
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=off
  export PATH="$APP_ROOT/.venv/bin:$PATH"

  log "Python environment configured"
}

# Node.js setup
setup_node() {
  log "Detected Node.js project"
  case "$OS_FAMILY" in
    debian|rhel)
      install_packages ca-certificates curl git build-essential python3 make g++ nodejs npm
      ;;
    alpine)
      install_packages ca-certificates curl git build-base python3 make g++ nodejs npm
      ;;
  esac

  # Use npm ci if lockfile exists; fall back to install
  pushd "$APP_ROOT" >/dev/null
  if [ -f package-lock.json ]; then
    log "Installing Node dependencies with npm ci"
    npm ci --no-progress
  else
    log "Installing Node dependencies with npm install"
    npm install --no-progress
  fi
  # Install Yarn if yarn.lock exists and package.json specifies yarn
  if [ -f yarn.lock ] && ! command_exists yarn; then
    log "yarn.lock detected; installing Yarn"
    npm install -g yarn
    yarn install --frozen-lockfile || true
  fi
  popd >/dev/null

  # Default environment variables
  export NODE_ENV="${APP_ENV:-production}"
  export PATH="$APP_ROOT/node_modules/.bin:$PATH"
  log "Node.js environment configured"
}

# Ruby setup
setup_ruby() {
  log "Detected Ruby project"
  case "$OS_FAMILY" in
    debian|rhel)
      install_packages ca-certificates git curl build-essential ruby-full
      ;;
    alpine)
      install_packages ca-certificates git curl build-base ruby ruby-dev
      ;;
  esac

  if ! command_exists bundle; then
    gem install bundler --no-document
  fi

  pushd "$APP_ROOT" >/dev/null
  bundle config set path 'vendor/bundle'
  bundle install --jobs "$(nproc)" --retry 3
  popd >/dev/null

  export BUNDLE_PATH="$APP_ROOT/vendor/bundle"
  log "Ruby environment configured"
}

# Go setup
setup_go() {
  log "Detected Go project"
  case "$OS_FAMILY" in
    debian|rhel)
      install_packages ca-certificates git curl golang
      ;;
    alpine)
      install_packages ca-certificates git curl go
      ;;
  esac

  export GOPATH="${GOPATH:-$APP_ROOT/.gopath}"
  mkdir -p "$GOPATH"
  export PATH="$GOPATH/bin:$PATH"

  pushd "$APP_ROOT" >/dev/null
  if [ -f go.mod ]; then
    log "Downloading Go modules"
    go mod download
  fi
  popd >/dev/null

  log "Go environment configured"
}

# Java setup (Maven/Gradle)
setup_java() {
  log "Detected Java project"
  case "$OS_FAMILY" in
    debian)
      install_packages ca-certificates git curl default-jdk
      ;;
    rhel)
      install_packages ca-certificates git curl java-11-openjdk-devel
      ;;
    alpine)
      install_packages ca-certificates git curl openjdk17-jdk
      ;;
  esac

  if is_java_maven; then
    case "$OS_FAMILY" in
      debian|rhel) install_packages maven ;;
      alpine) install_packages maven ;;
    esac
    pushd "$APP_ROOT" >/dev/null
    log "Resolving Maven dependencies"
    mvn -q -DskipTests dependency:resolve || true
    popd >/dev/null
    # Ensure we can run `java -jar` by creating a minimal Main and manifest if needed
    ensure_maven_executable_jar
  fi

  if is_java_gradle; then
    if [ -x "$APP_ROOT/gradlew" ]; then
      pushd "$APP_ROOT" >/dev/null
      log "Resolving Gradle dependencies via wrapper"
      ./gradlew --no-daemon build -x test || ./gradlew --no-daemon dependencies || true
      popd >/dev/null
    else
      case "$OS_FAMILY" in
        debian|rhel) install_packages gradle ;;
        alpine) install_packages gradle ;;
      esac
      pushd "$APP_ROOT" >/dev/null
      log "Resolving Gradle dependencies"
      gradle --no-daemon build -x test || gradle --no-daemon dependencies || true
      popd >/dev/null
    fi
  fi

  export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac || command -v java)")")")" || true
  export PATH="$JAVA_HOME/bin:$PATH"
  log "Java environment configured (JAVA_HOME=${JAVA_HOME:-unknown})"
}

# PHP setup
setup_php() {
  log "Detected PHP project"
  case "$OS_FAMILY" in
    debian|rhel)
      install_packages ca-certificates git curl php-cli php-xml php-mbstring php-curl php-zip php-intl
      ;;
    alpine)
      install_packages ca-certificates git curl php81 php81-xml php81-mbstring php81-curl php81-zip php81-intl php81-openssl
      ;;
  esac

  # Composer installation (prefer system package, else download)
  if ! command_exists composer; then
    if [ "$PKG_MGR" = "apt" ] || [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
      install_packages composer || true
    fi
  fi
  if ! command_exists composer; then
    log "Installing Composer (local)"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  pushd "$APP_ROOT" >/dev/null
  local composer_args="--no-interaction --prefer-dist"
  if [ "${APP_ENV:-production}" = "production" ]; then
    composer_args="$composer_args --no-dev --optimize-autoloader"
  fi
  log "Installing PHP dependencies with Composer ($composer_args)"
  composer install $composer_args
  popd >/dev/null

  log "PHP environment configured"
}

# Rust setup
setup_rust() {
  log "Detected Rust project"
  case "$OS_FAMILY" in
    debian|rhel)
      install_packages ca-certificates git curl build-essential cargo rustc
      ;;
    alpine)
      install_packages ca-certificates git curl build-base cargo rust
      ;;
  esac

  pushd "$APP_ROOT" >/dev/null
  cargo fetch
  popd >/dev/null

  log "Rust environment configured"
}

# .NET setup
setup_dotnet() {
  log "Detected .NET project"
  # Installing .NET SDK cross-distro is complex; try distro packages, else warn.
  case "$OS_FAMILY" in
    debian|rhel)
      warn ".NET SDK installation is not handled automatically. Ensure base image provides dotnet SDK."
      ;;
    alpine)
      warn ".NET SDK on Alpine requires specific packages. Ensure base image provides dotnet."
      ;;
  esac
  if command_exists dotnet; then
    pushd "$APP_ROOT" >/dev/null
    log "Restoring .NET dependencies"
    dotnet restore || true
    popd >/dev/null
    log ".NET environment configured"
  else
    warn "dotnet command not found; skipping .NET restore."
  fi
}

# Configure generic runtime environment variables
configure_env() {
  export APP_ENV="${APP_ENV:-production}"
  export APP_PORT="${APP_PORT:-3000}"
  export APP_ROOT="${APP_ROOT:-$(pwd)}"
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export TZ="${TZ:-UTC}"
  log "Environment variables: APP_ENV=$APP_ENV, APP_PORT=$APP_PORT, APP_ROOT=$APP_ROOT, TZ=$TZ"
}

# Auto-activate Python virtual environment on shell login
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local activate_line="source ${APP_ROOT:-/app}/.venv/bin/activate"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# Main detection and setup
main() {
  detect_pkg_mgr
  ensure_maven_jdk

  # Set APP_ROOT default to current directory if not set
  export APP_ROOT="${APP_ROOT:-$(pwd)}"
  configure_env
  load_dotenv
  ensure_directories
  maybe_create_user
  # Ensure a minimal Maven project exists for mvn commands when none provided
  ensure_minimal_maven_project
  # Ensure shell auto-activates project venv if present
  setup_auto_activate

  local handled="no"

  if is_python_project; then
    setup_python
    handled="yes"
  fi

  if is_node_project; then
    setup_node
    handled="yes"
  fi

  if is_ruby_project; then
    setup_ruby
    handled="yes"
  fi

  if is_go_project; then
    setup_go
    handled="yes"
  fi

  if is_java_maven || is_java_gradle; then
    setup_java
    handled="yes"
  fi

  if is_php_project; then
    setup_php
    handled="yes"
  fi

  if is_rust_project; then
    setup_rust
    handled="yes"
  fi

  if is_dotnet_project; then
    setup_dotnet
    handled="yes"
  fi

  if [ "$handled" = "no" ]; then
    warn "No known project type detected in $APP_ROOT. Create one of: requirements.txt, package.json, Gemfile, go.mod, pom.xml, build.gradle, composer.json, Cargo.toml, *.csproj"
  fi

  # Final permissions
  if [ "${CREATE_APP_USER:-no}" = "yes" ] && id -u "${APP_USER:-app}" >/dev/null 2>&1; then
    chown -R "${APP_USER:-app}:${APP_USER:-app}" "$APP_ROOT"
    log "Adjusted ownership of $APP_ROOT to ${APP_USER:-app}"
  fi

  # Summary and usage hints
  log "Setup summary:"
  if is_python_project; then
    log "- Python: Activate venv with 'source $APP_ROOT/.venv/bin/activate'"
  fi
  if is_node_project; then
    log "- Node.js: Start scripts via 'npm run <script>'"
  fi
  if is_ruby_project; then
    log "- Ruby: Use 'bundle exec <command>'"
  fi
  if is_go_project; then
    log "- Go: Build with 'go build ./...' or run with 'go run .'"
  fi
  if is_java_maven || is_java_gradle; then
    log "- Java: Use 'mvn package' or './gradlew build' as applicable"
  fi
  if is_php_project; then
    log "- PHP: Use 'composer run <script>' or appropriate framework commands"
  fi
  if is_rust_project; then
    log "- Rust: Build with 'cargo build --release'"
  fi
  if is_dotnet_project; then
    log "- .NET: Build with 'dotnet build' and run with 'dotnet run'"
  fi

  log "Default APP_PORT is $APP_PORT (override with environment variable)."
}

main "$@"