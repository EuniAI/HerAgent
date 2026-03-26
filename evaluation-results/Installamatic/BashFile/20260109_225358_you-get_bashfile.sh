#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types and installs required runtimes/dependencies
# - Installs necessary system packages and tools
# - Sets up project directories and environment variables
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s extglob

# Globals and defaults
APP_HOME="${APP_HOME:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-}"
PORT="${PORT:-}"
DEBIAN_FRONTEND=noninteractive
LANG="${LANG:-C.UTF-8}"
LC_ALL="${LC_ALL:-C.UTF-8}"
TZ="${TZ:-UTC}"

# Colors only if TTY
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { printf "%s[INFO %s]%s %s\n" "$BLUE" "$(timestamp)" "$NC" "$*"; }
warn() { printf "%s[WARN %s]%s %s\n" "$YELLOW" "$(timestamp)" "$NC" "$*" >&2; }
err() { printf "%s[ERROR %s]%s %s\n" "$RED" "$(timestamp)" "$NC" "$*" >&2; }
die() { err "$*"; exit 1; }

on_error() {
  local exit_code=$?
  local line=${1:-}
  local cmd=${2:-}
  err "Command failed (exit $exit_code) at line $line: ${cmd}"
  exit "$exit_code"
}
trap 'on_error ${LINENO} "${BASH_COMMAND}"' ERR

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must run as root inside the container."
  fi
}

# Detect OS / package manager
PKG_MGR=""
OS_FAMILY=""
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    OS_FAMILY="debian"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    OS_FAMILY="fedora"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    OS_FAMILY="rhel"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    OS_FAMILY="suse"
  else
    die "Unsupported base image: could not detect package manager."
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
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
    zypper)
      zypper --non-interactive refresh || true
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@" || apt-get -f install -y
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
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
      ;;
    dnf|yum)
      rm -rf /var/cache/dnf/* /var/cache/yum/* /tmp/* /var/tmp/*
      ;;
    zypper)
      rm -rf /var/cache/zypp/* /tmp/* /var/tmp/*
      ;;
  esac
}

install_base_tools() {
  log "Installing base system packages and build tools..."
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg tar gzip xz-utils bzip2 unzip zip \
                  build-essential pkg-config openssl locales tzdata
      ;;
    apk)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg tar gzip xz bzip2 unzip zip \
                  build-base pkgconfig openssl tzdata
      ;;
    dnf|yum)
      pkg_update
      # Install "Development Tools" group if available
      if command -v dnf >/dev/null 2>&1; then
        dnf groupinstall -y "Development Tools" || true
      else
        yum groupinstall -y "Development Tools" || true
      fi
      pkg_install ca-certificates curl wget git gnupg2 tar gzip xz bzip2 unzip zip \
                  openssl tzdata which
      ;;
    zypper)
      pkg_update
      pkg_install ca-certificates curl wget git gpg2 tar gzip xz bzip2 unzip zip \
                  gcc gcc-c++ make pkgconfig libopenssl-devel timezone
      ;;
  esac

  # Configure timezone
  if [ -f /usr/share/zoneinfo/$TZ ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
    echo "$TZ" > /etc/timezone || true
  fi

  update-ca-certificates 2>/dev/null || true
}

# Project detection
is_python_project() {
  [ -f "$APP_HOME/requirements.txt" ] || [ -f "$APP_HOME/pyproject.toml" ] || [ -f "$APP_HOME/Pipfile" ]
}
is_node_project() {
  [ -f "$APP_HOME/package.json" ]
}
is_ruby_project() {
  [ -f "$APP_HOME/Gemfile" ]
}
is_java_maven_project() {
  [ -f "$APP_HOME/pom.xml" ]
}
is_java_gradle_project() {
  [ -f "$APP_HOME/build.gradle" ] || [ -f "$APP_HOME/build.gradle.kts" ] || [ -f "$APP_HOME/gradlew" ]
}
is_go_project() {
  [ -f "$APP_HOME/go.mod" ]
}
is_rust_project() {
  [ -f "$APP_HOME/Cargo.toml" ]
}
is_php_project() {
  [ -f "$APP_HOME/composer.json" ]
}
is_dotnet_project() {
  ls "$APP_HOME"/*.sln "$APP_HOME"/*.csproj "$APP_HOME"/*.fsproj >/dev/null 2>&1
}

ensure_app_dirs() {
  mkdir -p "$APP_HOME" "$APP_HOME/bin" "$APP_HOME/logs" "$APP_HOME/tmp" "$APP_HOME/data"
}

maybe_create_user() {
  # Create a non-root user if requested through APP_USER/APP_GROUP
  if [ -n "${APP_USER}" ]; then
    local group="${APP_GROUP:-$APP_USER}"
    if ! getent group "$group" >/dev/null 2>&1; then
      log "Creating group: $group"
      groupadd -r "$group"
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      log "Creating user: $APP_USER"
      useradd -r -g "$group" -d "$APP_HOME" -s /usr/sbin/nologin "$APP_USER"
    fi
    chown -R "${APP_USER}:${group}" "$APP_HOME" || true
  fi
}

write_env_file() {
  local env_file="$APP_HOME/.container_env"
  log "Writing environment file: $env_file"
  {
    echo "# Auto-generated by setup script on $(timestamp)"
    echo "export APP_HOME=\"$APP_HOME\""
    echo "export APP_ENV=\"$APP_ENV\""
    echo "export LANG=\"$LANG\""
    echo "export LC_ALL=\"$LC_ALL\""
    echo "export TZ=\"$TZ\""
    [ -n "${PORT}" ] && echo "export PORT=\"$PORT\""
    # Placeholder for stack-specific variables appended later
  } > "$env_file"
  chmod 0644 "$env_file"
}

append_env_var() {
  local key="$1"
  local val="$2"
  local env_file="$APP_HOME/.container_env"
  grep -qE "^export ${key}=" "$env_file" 2>/dev/null || echo "export ${key}=\"${val}\"" >> "$env_file"
}

ensure_profile_loading() {
  # Ensure /etc/profile.d loads APP_HOME/.container_env for login shells
  local profile_d="/etc/profile.d/app_env.sh"
  if [ ! -f "$profile_d" ]; then
    log "Configuring shell profile to load container environment variables."
    {
      echo "#!/usr/bin/env sh"
      echo "[ -f \"$APP_HOME/.container_env\" ] && . \"$APP_HOME/.container_env\""
    } > "$profile_d"
    chmod 0755 "$profile_d"
  fi
}

# Python setup
install_python_stack() {
  log "Detected Python project"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install python3 python3-venv python3-pip python3-dev build-essential \
                  libssl-dev libffi-dev libpq-dev libxml2-dev libxslt1-dev zlib1g-dev
      ;;
    apk)
      pkg_update
      pkg_install python3 py3-pip python3-dev build-base libffi-dev openssl-dev musl-dev \
                  libxml2-dev libxslt-dev postgresql-dev
      ;;
    dnf|yum)
      pkg_update
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make openssl-devel libffi-devel \
                  libxml2-devel libxslt-devel postgresql-devel
      ;;
    zypper)
      pkg_update
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libopenssl-devel libffi-devel \
                  libxml2-devel libxslt-devel libpq5 postgresql-devel
      ;;
  esac

  # Python virtual environment
  local venv_dir="$APP_HOME/.venv"
  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Python virtual environment already exists at $venv_dir"
  fi

  # Activate venv for this script
  # shellcheck disable=SC1090
  . "$venv_dir/bin/activate"

  # Upgrade pip/setuptools/wheel
  pip install --no-cache-dir --upgrade pip setuptools wheel

  # Install dependencies using requirements.txt or pyproject.toml
  if [ -f "$APP_HOME/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r "$APP_HOME/requirements.txt"
  elif [ -f "$APP_HOME/pyproject.toml" ]; then
    # Try PEP 517 build or project deps
    if grep -qiE '^\s*\[project\]' "$APP_HOME/pyproject.toml" || grep -qiE '^\s*\[tool.poetry\]' "$APP_HOME/pyproject.toml"; then
      log "Installing Python project dependencies from pyproject.toml"
      pip install --no-cache-dir "build>=1.0.0" "pip-tools>=7.0.0" || true
      # Try to install project editable if setuptools; else fallback
      if grep -qiE 'setuptools|hatch|flit|poetry' "$APP_HOME/pyproject.toml"; then
        pip install --no-cache-dir -e "$APP_HOME" || pip install --no-cache-dir "$APP_HOME"
      else
        pip install --no-cache-dir "$APP_HOME"
      fi
    fi
  elif [ -f "$APP_HOME/Pipfile" ]; then
    log "Pipfile detected; installing pipenv and syncing"
    pip install --no-cache-dir pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
  else
    warn "No requirements.txt/pyproject.toml/Pipfile found; skipping Python dependency installation."
  fi

  append_env_var "PYTHONUNBUFFERED" "1"
  append_env_var "PIP_NO_CACHE_DIR" "1"
  append_env_var "VIRTUAL_ENV" "$venv_dir"
  append_env_var "PATH" "$venv_dir/bin:\$PATH"

  # Guess port for common frameworks
  if [ -z "${PORT}" ]; then
    if [ -f "$APP_HOME/manage.py" ]; then
      PORT="8000"
    elif [ -f "$APP_HOME/app.py" ] || ls "$APP_HOME"/*flask* 1>/dev/null 2>&1; then
      PORT="5000"
    fi
    [ -n "${PORT}" ] && append_env_var "PORT" "$PORT"
  fi

  deactivate || true
}

# Node.js setup
install_node_stack() {
  log "Detected Node.js project"
  # Install Node.js and npm
  if ! command -V node >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apt)
        pkg_update
        # Install Node.js 18.x via NodeSource if possible
        if [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
          curl -fsSL https://deb.nodesource.com/setup_18.x | bash - || true
        fi
        pkg_install nodejs
        ;;
      apk)
        pkg_update
        pkg_install nodejs npm
        ;;
      dnf)
        pkg_update
        dnf module -y reset nodejs || true
        dnf module -y enable nodejs:18 || true
        pkg_install nodejs npm
        ;;
      yum)
        pkg_update
        curl -fsSL https://rpm.nodesource.com/setup_18.x | bash - || true
        pkg_install nodejs
        ;;
      zypper)
        pkg_update
        pkg_install nodejs18 npm18 || pkg_install nodejs npm || true
        # Symlink to expected names
        if command -v nodejs18 >/dev/null 2>&1 && [ ! -e /usr/bin/node ]; then
          ln -sf "$(command -v nodejs18)" /usr/bin/node || true
        fi
        if command -v npm18 >/dev/null 2>&1 && [ ! -e /usr/bin/npm ]; then
          ln -sf "$(command -v npm18)" /usr/bin/npm || true
        fi
        ;;
    esac
  else
    log "Node.js already installed: $(node -v)"
  fi

  # Install package manager helpers if needed
  if [ -f "$APP_HOME/yarn.lock" ] && ! command -v yarn >/dev/null 2>&1; then
    npm install -g yarn --omit=dev || npm install -g yarn || true
  fi
  if [ -f "$APP_HOME/pnpm-lock.yaml" ] && ! command -v pnpm >/dev/null 2>&1; then
    npm install -g pnpm || true
  fi
  if [ -f "$APP_HOME/package-lock.json" ]; then
    (cd "$APP_HOME" && npm ci --no-audit --no-fund)
  elif [ -f "$APP_HOME/yarn.lock" ]; then
    (cd "$APP_HOME" && yarn install --frozen-lockfile || yarn install)
  elif [ -f "$APP_HOME/pnpm-lock.yaml" ]; then
    (cd "$APP_HOME" && pnpm install --frozen-lockfile || pnpm install)
  else
    (cd "$APP_HOME" && npm install --no-audit --no-fund)
  fi

  append_env_var "NODE_ENV" "${NODE_ENV:-production}"
  if [ -z "${PORT}" ]; then
    PORT="3000"
    append_env_var "PORT" "$PORT"
  fi
}

# Ruby setup
install_ruby_stack() {
  log "Detected Ruby project"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ruby-full build-essential zlib1g-dev libssl-dev libreadline-dev libyaml-dev \
                  libxml2-dev libxslt1-dev nodejs
      ;;
    apk)
      pkg_update
      pkg_install ruby ruby-dev build-base zlib-dev openssl-dev readline-dev yaml-dev libxml2-dev libxslt-dev nodejs
      ;;
    dnf|yum)
      pkg_update
      pkg_install ruby ruby-devel gcc gcc-c++ make zlib-devel openssl-devel readline-devel libyaml-devel libxml2-devel libxslt-devel nodejs
      ;;
    zypper)
      pkg_update
      pkg_install ruby ruby-devel gcc gcc-c++ make zlib-devel libopenssl-devel readline-devel libyaml-devel libxml2-devel libxslt-devel nodejs
      ;;
  esac
  if ! gem list -i bundler >/dev/null 2>&1; then
    gem install bundler -N
  fi
  (cd "$APP_HOME" && bundle config set path 'vendor/bundle' && bundle install --jobs=4)
  if [ -z "${PORT}" ]; then
    PORT="3000"
    append_env_var "PORT" "$PORT"
  fi
}

# Java setup
install_java_maven() {
  log "Detected Maven project"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install default-jdk maven
      ;;
    apk)
      pkg_update
      pkg_install openjdk17 maven
      export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
      append_env_var "JAVA_HOME" "$JAVA_HOME"
      ;;
    dnf|yum)
      pkg_update
      pkg_install java-17-openjdk java-17-openjdk-devel maven
      ;;
    zypper)
      pkg_update
      pkg_install java-17-openjdk java-17-openjdk-devel maven
      ;;
  esac
  (cd "$APP_HOME" && mvn -B -ntp -DskipTests dependency:go-offline || true)
}

install_java_gradle() {
  log "Detected Gradle project"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install default-jdk wget unzip
      if ! command -v gradle >/dev/null 2>&1 && [ ! -f "$APP_HOME/gradlew" ]; then
        pkg_install gradle || true
      fi
      ;;
    apk)
      pkg_update
      pkg_install openjdk17 wget unzip
      export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
      append_env_var "JAVA_HOME" "$JAVA_HOME"
      if ! command -v gradle >/dev/null 2>&1 && [ ! -f "$APP_HOME/gradlew" ]; then
        pkg_install gradle || true
      fi
      ;;
    dnf|yum)
      pkg_update
      pkg_install java-17-openjdk java-17-openjdk-devel wget unzip gradle || true
      ;;
    zypper)
      pkg_update
      pkg_install java-17-openjdk java-17-openjdk-devel wget unzip gradle || true
      ;;
  esac

  if [ -f "$APP_HOME/gradlew" ]; then
    chmod +x "$APP_HOME/gradlew"
    (cd "$APP_HOME" && ./gradlew --no-daemon tasks >/dev/null 2>&1 || true)
  else
    (cd "$APP_HOME" && gradle --no-daemon tasks >/dev/null 2>&1 || true)
  fi
}

# Go setup
install_go_stack() {
  log "Detected Go project"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install golang
      ;;
    apk)
      pkg_update
      pkg_install go
      ;;
    dnf|yum)
      pkg_update
      pkg_install golang
      ;;
    zypper)
      pkg_update
      pkg_install go
      ;;
  esac
  (cd "$APP_HOME" && go mod download || true)
  append_env_var "GOBIN" "/usr/local/bin"
}

# Rust setup
install_rust_stack() {
  log "Detected Rust project"
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust via rustup (non-interactive)"
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    append_env_var "CARGO_HOME" "/root/.cargo"
    append_env_var "RUSTUP_HOME" "/root/.rustup"
    append_env_var "PATH" "/root/.cargo/bin:\$PATH"
    # shellcheck disable=SC1090
    . /root/.cargo/env
  fi
  (cd "$APP_HOME" && cargo fetch || true)
}

# PHP setup
install_php_stack() {
  log "Detected PHP project"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install php-cli php-mbstring php-xml php-curl php-zip php-intl php-sqlite3 unzip
      ;;
    apk)
      pkg_update
      pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip php81-intl php81-sqlite3 php81-openssl unzip || \
      pkg_install php php-cli php-mbstring php-xml php-curl php-zip php-sqlite3 unzip
      ;;
    dnf|yum)
      pkg_update
      pkg_install php php-cli php-mbstring php-xml php-curl php-zip php-intl php-sqlite3 unzip
      ;;
    zypper)
      pkg_update
      pkg_install php8 php8-cli php8-mbstring php8-xml php8-curl php8-zip php8-intl php8-sqlite unzip || \
      pkg_install php php-cli php-mbstring php-xml php-curl php-zip php-intl php-sqlite unzip
      ;;
  esac

  # Composer
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    EXPECTED_SIGNATURE=$(curl -fsSL https://composer.github.io/installer.sig)
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE=$(php -r "echo hash_file('sha384', 'composer-setup.php');")
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      die "Invalid Composer installer signature"
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi

  (cd "$APP_HOME" && composer install --no-interaction --prefer-dist)
  if [ -z "${PORT}" ]; then
    PORT="9000"
    append_env_var "PORT" "$PORT"
  fi
}

# .NET setup (Debian/Ubuntu and RHEL/Fedora only; best-effort)
install_dotnet_stack() {
  log "Detected .NET project (best-effort installation)"
  if command -v dotnet >/dev/null 2>&1; then
    log "dotnet already installed: $(dotnet --version)"
  else
    case "$PKG_MGR" in
      apt)
        pkg_update
        if [ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]; then
          wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || \
          wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
          dpkg -i /tmp/packages-microsoft-prod.deb || true
          rm -f /tmp/packages-microsoft-prod.deb
          apt-get update -y || true
        fi
        pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || true
        ;;
      dnf)
        pkg_update
        rpm -Uvh https://packages.microsoft.com/config/centos/8/packages-microsoft-prod.rpm || true
        dnf install -y dotnet-sdk-8.0 || dnf install -y dotnet-sdk-7.0 || true
        ;;
      yum)
        pkg_update
        rpm -Uvh https://packages.microsoft.com/config/centos/7/packages-microsoft-prod.rpm || true
        yum install -y dotnet-sdk-8.0 || yum install -y dotnet-sdk-7.0 || true
        ;;
      *)
        warn ".NET installation not supported for this base image; please use a dotnet base image."
        ;;
    esac
  fi
  if command -v dotnet >/dev/null 2>&1; then
    # Restore dependencies for all solutions/projects
    if ls "$APP_HOME"/*.sln >/dev/null 2>&1; then
      (cd "$APP_HOME" && dotnet restore)
    else
      for proj in "$APP_HOME"/*.csproj "$APP_HOME"/*.fsproj; do
        [ -f "$proj" ] && (cd "$(dirname "$proj")" && dotnet restore)
      done
    fi
  fi
}

# Summary and guidance
print_summary() {
  log "Setup complete."
  echo "----------------------------------------"
  echo "Project home: $APP_HOME"
  echo "Environment: $APP_ENV"
  if [ -f "$APP_HOME/.container_env" ]; then
    echo "Env file: $APP_HOME/.container_env (auto-loaded for login shells)"
  fi
  [ -n "$PORT" ] && echo "Default port: $PORT"
  echo "Common run tips (depending on stack):"
  echo "- Python: source $APP_HOME/.venv/bin/activate && python -m your_app"
  echo "- Node:   npm start (or specific script in package.json)"
  echo "- Ruby:   bundle exec rails s -b 0.0.0.0 -p \$PORT"
  echo "- Java:   mvn spring-boot:run or ./gradlew bootRun"
  echo "- Go:     go run ./..."
  echo "- PHP:    php -S 0.0.0.0:\$PORT -t public (or run php-fpm)"
  echo "- .NET:   dotnet run --project path/to/*.csproj"
  echo "----------------------------------------"
}

main() {
  require_root
  detect_pkg_mgr
  ensure_app_dirs
  install_base_tools
  write_env_file
  ensure_profile_loading

  # Set permissions if requested
  maybe_create_user

  # Copy container env into root profile for current shell session
  # shellcheck disable=SC1090
  . "$APP_HOME/.container_env" || true

  # Detect and install stacks (support monorepos: run in heuristic order)
  local any_stack=0

  if is_python_project; then
    install_python_stack
    any_stack=1
  fi

  if is_node_project; then
    install_node_stack
    any_stack=1
  fi

  if is_ruby_project; then
    install_ruby_stack
    any_stack=1
  fi

  if is_java_maven_project; then
    install_java_maven
    any_stack=1
  fi

  if is_java_gradle_project; then
    install_java_gradle
    any_stack=1
  fi

  if is_go_project; then
    install_go_stack
    any_stack=1
  fi

  if is_rust_project; then
    install_rust_stack
    any_stack=1
  fi

  if is_php_project; then
    install_php_stack
    any_stack=1
  fi

  if is_dotnet_project; then
    install_dotnet_stack
    any_stack=1
  fi

  if [ "$any_stack" -eq 0 ]; then
    warn "No recognized project configuration found in $APP_HOME."
    warn "Place your project files in $APP_HOME and re-run this script."
  fi

  # Ensure app dir permissions are consistent
  if [ -n "${APP_USER}" ]; then
    chown -R "${APP_USER}:${APP_GROUP:-$APP_USER}" "$APP_HOME" || true
  fi

  pkg_cleanup
  print_summary
}

main "$@"