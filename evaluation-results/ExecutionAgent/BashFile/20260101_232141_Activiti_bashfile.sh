#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects common project types and installs appropriate runtimes, system packages, dependencies,
# sets up directory structure, environment variables, and permissions.
#
# Supported stacks (auto-detected by files in /app):
# - Python (requirements.txt or pyproject.toml)
# - Node.js (package.json)
# - Ruby (Gemfile)
# - Go (go.mod)
# - Java (pom.xml, build.gradle, gradlew)
# - PHP (composer.json)
# - Rust (Cargo.toml)
# - .NET (csproj/sln) [requires base image with dotnet or additional repo setup]
#
# This script is idempotent and safe to run multiple times.

set -Eeuo pipefail

# ---- Configuration defaults ----
APP_ROOT="${APP_ROOT:-/app}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-}"   # We'll auto-detect default per stack if not set

DEBIAN_FRONTEND=noninteractive
UMASK_VALUE="${UMASK_VALUE:-022}"

# ---- Logging utilities ----
TS() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(TS)] $*"; }
warn() { echo "[WARN $(TS)] $*" >&2; }
err() { echo "[ERROR $(TS)] $*" >&2; }
die() { err "$*"; exit 1; }

trap 'err "Setup failed at line $LINENO running: $BASH_COMMAND"; exit 1' ERR

# ---- OS / Package manager detection ----
PKG_MGR=""
OS_ID=""
OS_VERSION_ID=""

detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    PKG_MGR=""
  fi

  if [[ -z "$PKG_MGR" ]]; then
    warn "No supported package manager detected. System package installation will be skipped."
  else
    log "Detected OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-}, package manager: $PKG_MGR"
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      apt-get update -y || apt-get update
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
    *)
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0

  case "$PKG_MGR" in
    apt)
      # Install only missing packages
      local to_install=()
      for p in "${pkgs[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || to_install+=("$p")
      done
      if [[ ${#to_install[@]} -gt 0 ]]; then
        log "Installing packages: ${to_install[*]}"
        apt-get install -y --no-install-recommends "${to_install[@]}"
      else
        log "All requested packages already installed."
      fi
      ;;
    apk)
      # apk automatically skips installed packages
      log "Installing packages: ${pkgs[*]}"
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      log "Installing packages: ${pkgs[*]}"
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      log "Installing packages: ${pkgs[*]}"
      yum install -y "${pkgs[@]}"
      ;;
    *)
      warn "Package manager not available; cannot install: ${pkgs[*]}"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      ;;
    dnf)
      dnf clean all || true
      ;;
    yum)
      yum clean all || true
      ;;
    *)
      ;;
  esac
}

# ---- Base system setup ----
setup_base_system() {
  detect_os
  if [[ -n "$PKG_MGR" ]]; then
    pkg_update

    case "$PKG_MGR" in
      apt)
        pkg_install ca-certificates curl wget git gnupg build-essential pkg-config
        ;;
      apk)
        pkg_install ca-certificates curl wget git gnupg build-base bash
        update-ca-certificates || true
        ;;
      dnf|yum)
        pkg_install ca-certificates curl wget git gnupg gcc gcc-c++ make pkgconfig
        ;;
    esac

    pkg_cleanup
  else
    warn "Skipping base system package installation (no package manager found)."
  fi

  # Set umask
  umask "$UMASK_VALUE"

  # Ensure /app exists
  mkdir -p "$APP_ROOT"/{logs,tmp,run,data}
  # Create dedicated user/group if not existing
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if command -v groupadd >/dev/null 2>&1; then
      groupadd -g "$APP_GID" -r "$APP_GROUP" || groupadd -r "$APP_GROUP" || true
    elif command -v addgroup >/dev/null 2>&1; then
      if [[ "$PKG_MGR" == "apk" ]]; then
        addgroup -g "$APP_GID" "$APP_GROUP" || addgroup "$APP_GROUP"
      else
        addgroup --gid "$APP_GID" "$APP_GROUP" || addgroup "$APP_GROUP"
      fi
    fi
  fi

  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
      useradd -r -u "$APP_UID" -g "$APP_GROUP" -m -s /bin/bash "$APP_USER" || useradd -r -m -s /bin/bash "$APP_USER" || true
    elif command -v adduser >/dev/null 2>&1; then
      # BusyBox/Alpine adduser fallback
      adduser -D -G "$APP_GROUP" -u "$APP_UID" "$APP_USER" || adduser -D "$APP_USER"
    fi
  fi

  chown -R "$APP_USER:$APP_GROUP" "$APP_ROOT" || true
}

# ---- Environment persistence ----
write_env_profile() {
  local profile_file="/etc/profile.d/app_env.sh"
  {
    echo "# Managed by setup script - application environment"
    echo "export APP_ROOT=\"$APP_ROOT\""
    echo "export APP_ENV=\"${APP_ENV}\""
    [[ -n "$APP_PORT" ]] && echo "export APP_PORT=\"${APP_PORT}\""
    echo "export PATH=\"/usr/local/bin:\$PATH\""
    echo "umask ${UMASK_VALUE}"
    # If Python venv created, add activation
    if [[ -d "$APP_ROOT/.venv" ]]; then
      echo "export VIRTUAL_ENV=\"$APP_ROOT/.venv\""
      echo "export PATH=\"\$VIRTUAL_ENV/bin:\$PATH\""
    fi
    # Node-specific env
    if [[ -f "$APP_ROOT/package.json" ]]; then
      echo "export NODE_ENV=\"production\""
    fi
  } > "$profile_file"
}

write_project_env_file() {
  local env_file="$APP_ROOT/.env"
  if [[ ! -f "$env_file" ]]; then
    {
      echo "# Managed by setup script"
      echo "APP_ENV=${APP_ENV}"
      [[ -n "$APP_PORT" ]] && echo "APP_PORT=${APP_PORT}"
    } > "$env_file"
    chown "$APP_USER:$APP_GROUP" "$env_file" || true
  fi
}

# ---- Virtual environment auto-activation ----
setup_auto_activate() {
  # Add auto-activation to root's bashrc to ensure venv is active on shell start
  local bashrc_file="/root/.bashrc"
  local venv_activate_line=". \"$APP_ROOT/.venv/bin/activate\""
  if [[ -d "$APP_ROOT/.venv" ]]; then
    if ! grep -qF "$venv_activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$venv_activate_line" >> "$bashrc_file"
    fi
  fi
}

write_venv_auto_profile() {
  # Create /etc/profile.d script to auto-source the venv in login shells if present
  local profile_file="/etc/profile.d/venv_auto.sh"
  local venv_path="$APP_ROOT/.venv"
  {
    echo '# Auto-activate project venv if present'
    echo "if [ -d \"$venv_path\" ] && [ -z \"${VIRTUAL_ENV:-}\" ]; then"
    echo "  . \"$venv_path/bin/activate\""
    echo "fi"
  } > "$profile_file"
  chmod 644 "$profile_file" || true
  grep -q '^VIRTUAL_ENV=' /etc/environment 2>/dev/null || echo 'VIRTUAL_ENV=' >> /etc/environment
}

# ---- Stack-specific setup functions ----

# Python
install_python_runtime() {
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev libffi-dev openssl-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel libffi-devel openssl-devel
      ;;
    *)
      if ! command -v python3 >/dev/null 2>&1; then
        die "Python3 not found and package manager unavailable to install it."
      fi
      ;;
  esac
  pkg_cleanup
}

setup_python() {
  log "Detected Python project."

  install_python_runtime

  # Create Python virtual environment if not exists
  if [[ ! -d "$APP_ROOT/.venv" ]]; then
    log "Creating virtual environment at $APP_ROOT/.venv"
    python3 -m venv "$APP_ROOT/.venv"
  else
    log "Virtual environment already exists at $APP_ROOT/.venv"
  fi

  # Activate venv in subshell for pip operations
  # shellcheck disable=SC1091
  source "$APP_ROOT/.venv/bin/activate"

  python3 -m pip install --upgrade pip setuptools wheel

  if [[ -f "$APP_ROOT/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r "$APP_ROOT/requirements.txt"
  elif [[ -f "$APP_ROOT/pyproject.toml" ]]; then
    log "Installing Python dependencies from pyproject.toml"
    pip install --no-cache-dir .
  elif [[ -f "$APP_ROOT/Pipfile" ]]; then
    log "Pipfile detected; installing pipenv and syncing environment"
    pip install --no-cache-dir pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
  else
    warn "No Python dependency file found (requirements.txt, pyproject.toml, Pipfile). Skipping Python dependency installation."
  fi

  deactivate || true

  # Default port for common Python web apps
  if [[ -z "${APP_PORT}" ]]; then
    APP_PORT="5000"
  fi
}

# Node.js
install_node_runtime() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "Node.js already installed: $(node -v)"
    return
  fi
  case "$PKG_MGR" in
    apt)
      pkg_update
      # Install Node.js LTS via NodeSource
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash - || warn "NodeSource setup failed; falling back to distro nodejs"
      else
        warn "curl not available; falling back to distro nodejs"
      fi
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://rpm.nodesource.com/setup_18.x | bash - || warn "NodeSource setup failed; falling back to distro nodejs"
      fi
      pkg_install nodejs npm
      ;;
    *)
      die "Node.js not found and package manager unavailable to install it."
      ;;
  esac
  pkg_cleanup
}

setup_node() {
  log "Detected Node.js project."

  install_node_runtime

  # Install dependencies
  if [[ -f "$APP_ROOT/package-lock.json" ]]; then
    log "Installing Node.js dependencies with npm ci"
    npm ci --prefix "$APP_ROOT"
  elif [[ -f "$APP_ROOT/yarn.lock" ]]; then
    if ! command -v yarn >/dev/null 2>&1; then
      log "Installing yarn globally"
      npm install -g yarn
    fi
    log "Installing Node.js dependencies with yarn"
    (cd "$APP_ROOT" && yarn install --frozen-lockfile)
  else
    log "Installing Node.js dependencies with npm install"
    npm install --prefix "$APP_ROOT"
  fi

  # Default port for Node apps
  if [[ -z "${APP_PORT}" ]]; then
    APP_PORT="3000"
  fi
}

# Ruby
setup_ruby() {
  log "Detected Ruby project."
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-bundler build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      if ! command -v ruby >/dev/null 2>&1; then
        die "Ruby not found and package manager unavailable to install it."
      fi
      ;;
  esac
  pkg_cleanup

  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler
  fi

  if [[ -f "$APP_ROOT/Gemfile" ]]; then
    log "Installing Ruby gems via bundler"
    (cd "$APP_ROOT" && bundle config set path 'vendor/bundle' && bundle install --without development test)
  else
    warn "Gemfile not found. Skipping bundle install."
  fi

  if [[ -z "${APP_PORT}" ]]; then
    APP_PORT="3000"
  fi
}

# Go
setup_go() {
  log "Detected Go project."
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum)
      pkg_install golang
      ;;
    *)
      if ! command -v go >/dev/null 2>&1; then
        die "Go not found and package manager unavailable to install it."
      fi
      ;;
  esac
  pkg_cleanup

  export GOPATH="${GOPATH:-/go}"
  mkdir -p "$GOPATH"
  if [[ -f "$APP_ROOT/go.mod" ]]; then
    log "Fetching Go modules"
    (cd "$APP_ROOT" && GO111MODULE=on go mod download)
  else
    warn "go.mod not found. Skipping module download."
  fi

  if [[ -z "${APP_PORT}" ]]; then
    APP_PORT="8080"
  fi
}

# Java
setup_java() {
  log "Detected Java project."
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install openjdk-11-jdk maven
      ;;
    apk)
      pkg_install openjdk17-jdk || pkg_install openjdk11-jdk
      ;;
    dnf|yum)
      pkg_install java-11-openjdk-devel || pkg_install java-17-openjdk-devel
      ;;
    *)
      if ! command -v javac >/dev/null 2>&1; then
        die "Java JDK not found and package manager unavailable to install it."
      fi
      ;;
  esac
  pkg_cleanup

  if [[ -f "$APP_ROOT/pom.xml" ]]; then
    log "Maven project detected; installing Maven"
    case "$PKG_MGR" in
      apt) pkg_update; pkg_install maven ;;
      apk) pkg_install maven ;;
      dnf|yum) pkg_install maven ;;
      *) [[ -x /usr/bin/mvn ]] || warn "Maven not found; ensure Maven is available." ;;
    esac
    pkg_cleanup
    log "Resolving Maven dependencies"
    java -version && mvn -v || warn "Java/Maven not properly installed or not found in PATH"
    mkdir -p /root/.m2
    cat > /root/.m2/settings.xml <<'EOF'
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <profiles>
    <profile>
      <id>enable-activiti-snapshots</id>
      <repositories>
        <repository>
          <id>central</id>
          <url>https://repo.maven.apache.org/maven2</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>false</enabled></snapshots>
        </repository>
        <repository>
          <id>activiti-snapshots</id>
          <url>https://artifacts.alfresco.com/nexus/content/repositories/activiti-snapshots</url>
          <releases><enabled>false</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>enable-activiti-snapshots</activeProfile>
  </activeProfiles>
</settings>
EOF
    log "Resolving Maven dependencies and installing SNAPSHOT modules"
    (cd "$APP_ROOT" && mvn -B -ntp -DskipTests -DskipITs=true -U -pl :activiti-api-runtime-shared -am install || mvn -B -ntp -DskipTests -DskipITs=true -U install || warn "Maven build failed; ensure internet access and valid pom.xml")
    log "Running Maven verify with deterministic environment settings"
    (cd "$APP_ROOT" && JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac)))) TZ=Etc/UTC LANG=C.UTF-8 LC_ALL=C.UTF-8 MAVEN_OPTS="-Xmx1024m -Dfile.encoding=UTF-8 -Duser.timezone=UTC" mvn -B -V -e -DskipTests=false -DfailIfNoTests=false clean verify || warn "Maven verify failed; see output for details")
  elif [[ -f "$APP_ROOT/gradlew" ]]; then
    log "Gradle wrapper detected; ensuring executable"
    chmod +x "$APP_ROOT/gradlew" || true
    log "Preparing Gradle dependencies via wrapper"
    (cd "$APP_ROOT" && ./gradlew --no-daemon tasks >/dev/null || warn "Gradle wrapper setup tasks failed")
  elif [[ -f "$APP_ROOT/build.gradle" ]]; then
    log "Gradle build.gradle detected; installing Gradle"
    case "$PKG_MGR" in
      apt) pkg_update; pkg_install gradle ;;
      apk) pkg_install gradle ;;
      dnf|yum) pkg_install gradle ;;
    esac
    pkg_cleanup
  else
    warn "No Maven or Gradle build files found."
  fi

  if [[ -z "${APP_PORT}" ]]; then
    APP_PORT="8080"
  fi
}

# PHP
setup_php() {
  log "Detected PHP project."
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install php-cli unzip
      # Prefer distro composer if available
      if ! command -v composer >/dev/null 2>&1; then
        pkg_install composer || true
      fi
      ;;
    apk)
      pkg_install php81-cli php81-phar php81-openssl php81-zip || pkg_install php8-cli php8-phar php8-openssl php8-zip
      ;;
    dnf|yum)
      pkg_install php-cli unzip
      ;;
    *)
      if ! command -v php >/dev/null 2>&1; then
        die "PHP CLI not found and package manager unavailable to install it."
      fi
      ;;
  esac
  pkg_cleanup

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
      && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
      && rm composer-setup.php || warn "Composer standalone install failed; ensure PHP openssl is available."
  fi

  if [[ -f "$APP_ROOT/composer.json" ]]; then
    log "Installing PHP dependencies via Composer (no-dev)"
    (cd "$APP_ROOT" && composer install --no-dev --no-interaction --prefer-dist)
  else
    warn "composer.json not found. Skipping composer install."
  fi

  if [[ -z "${APP_PORT}" ]]; then
    APP_PORT="8000"
  fi
}

# Rust
setup_rust() {
  log "Detected Rust project."
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install cargo
      ;;
    apk)
      pkg_install cargo
      ;;
    dnf|yum)
      pkg_install cargo
      ;;
    *)
      if ! command -v cargo >/dev/null 2>&1; then
        die "Rust (cargo) not found and package manager unavailable to install it."
      fi
      ;;
  esac
  pkg_cleanup

  if [[ -f "$APP_ROOT/Cargo.toml" ]]; then
    log "Fetching Rust crates"
    (cd "$APP_ROOT" && cargo fetch)
  else
    warn "Cargo.toml not found. Skipping cargo fetch."
  fi

  if [[ -z "${APP_PORT}" ]]; then
    APP_PORT="8080"
  fi
}

# .NET
setup_dotnet() {
  log "Detected .NET project."
  if ! command -v dotnet >/dev/null 2>&1; then
    warn ".NET SDK not found. Installing .NET varies by distribution.
- Recommended: use a base image like mcr.microsoft.com/dotnet/sdk:8.0
- Alternatively: add Microsoft package repo per https://learn.microsoft.com/dotnet/core/install/linux"
    return
  fi

  # Restore if solution or project exists
  shopt -s nullglob
  local sln_files=("$APP_ROOT"/*.sln)
  local csproj_files=("$APP_ROOT"/*.csproj)
  shopt -u nullglob

  if [[ ${#sln_files[@]} -gt 0 ]]; then
    log "Restoring .NET solution packages"
    (cd "$APP_ROOT" && dotnet restore "${sln_files[0]}" || warn "dotnet restore failed")
  elif [[ ${#csproj_files[@]} -gt 0 ]]; then
    log "Restoring .NET project packages"
    (cd "$APP_ROOT" && dotnet restore "${csproj_files[0]}" || warn "dotnet restore failed")
  else
    warn "No .NET solution or project file found. Skipping dotnet restore."
  fi

  if [[ -z "${APP_PORT}" ]]; then
    APP_PORT="8080"
  fi
}

# ---- Project type detection ----
detect_and_setup_project() {
  local detected=0

  if [[ -f "$APP_ROOT/requirements.txt" || -f "$APP_ROOT/pyproject.toml" || -f "$APP_ROOT/Pipfile" ]]; then
    setup_python
    detected=1
  fi

  if [[ -f "$APP_ROOT/package.json" ]]; then
    setup_node
    detected=1
  fi

  if [[ -f "$APP_ROOT/Gemfile" ]]; then
    setup_ruby
    detected=1
  fi

  if [[ -f "$APP_ROOT/go.mod" ]]; then
    setup_go
    detected=1
  fi

  if [[ -f "$APP_ROOT/pom.xml" || -f "$APP_ROOT/build.gradle" || -f "$APP_ROOT/gradlew" ]]; then
    setup_java
    detected=1
  fi

  if [[ -f "$APP_ROOT/composer.json" ]]; then
    setup_php
    detected=1
  fi

  if [[ -f "$APP_ROOT/Cargo.toml" ]]; then
    setup_rust
    detected=1
  fi

  shopt -s nullglob
  local sln_files=("$APP_ROOT"/*.sln)
  local csproj_files=("$APP_ROOT"/*.csproj)
  shopt -u nullglob
  if [[ ${#sln_files[@]} -gt 0 || ${#csproj_files[@]} -gt 0 ]]; then
    setup_dotnet
    detected=1
  fi

  if [[ "$detected" -eq 0 ]]; then
    warn "No supported project type detected in $APP_ROOT. Please ensure project files are present."
  fi
}

# ---- Permissions and final configuration ----
finalize_permissions() {
  chown -R "$APP_USER:$APP_GROUP" "$APP_ROOT" || true
  find "$APP_ROOT/logs" -type d -exec chmod 775 {} + || true
  find "$APP_ROOT/tmp" -type d -exec chmod 775 {} + || true
}

# ---- Main ----
main() {
  log "Starting environment setup for project at $APP_ROOT"

  # Ensure script runs as root inside container (no sudo)
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This setup script must be run as root inside the container."
  fi

  setup_base_system

  # Ensure working directory
  cd "$APP_ROOT"

  detect_and_setup_project

  # Set default port if not configured by stack
  if [[ -z "${APP_PORT}" ]]; then
    APP_PORT="8080"
  fi

  write_env_profile
  write_project_env_file
  write_venv_auto_profile
  setup_auto_activate
  finalize_permissions

  log "Environment setup completed successfully."
  log "Summary:"
  log "- APP_ROOT: $APP_ROOT"
  log "- APP_ENV: $APP_ENV"
  log "- APP_PORT: $APP_PORT"
  log "- Managed user: $APP_USER ($APP_UID)"
  log "You can source /etc/profile.d/app_env.sh in your container shell to load environment."
}

main "$@"