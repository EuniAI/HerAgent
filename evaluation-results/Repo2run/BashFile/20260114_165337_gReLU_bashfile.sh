#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types and installs required runtimes, system deps, and project deps
# - Idempotent, safe to rerun
# - Designed to run as root inside containers

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

#-----------------------------
# Logging and error handling
#-----------------------------
LOG_TS() { date +'%Y-%m-%d %H:%M:%S'; }
log()    { echo "[$(LOG_TS)] [INFO] $*"; }
warn()   { echo "[$(LOG_TS)] [WARN] $*" >&2; }
err()    { echo "[$(LOG_TS)] [ERROR] $*" >&2; }
die()    { err "$*"; exit 1; }

trap 'err "An error occurred on line $LINENO. Exiting."; exit 1' ERR

#-----------------------------
# Preconditions
#-----------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  die "This script must run as root inside the container."
fi

APP_ROOT="${APP_ROOT:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
ENV_FILE="${ENV_FILE:-.env}"
VENV_DIR="${VENV_DIR:-.venv}"

#-----------------------------
# Helpers
#-----------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_dir() {
  local d="$1"
  mkdir -p "$d"
}

# Create system user/group if not exists, ignore if already present
ensure_app_user() {
  if getent group "$APP_GROUP" >/dev/null 2>&1; then
    :
  else
    if command_exists addgroup; then
      addgroup -g "$APP_GID" "$APP_GROUP" >/dev/null 2>&1 || true
    elif command_exists groupadd; then
      groupadd -g "$APP_GID" -r "$APP_GROUP" >/dev/null 2>&1 || true
    fi
  fi

  if getent passwd "$APP_USER" >/dev/null 2>&1; then
    :
  else
    if command_exists adduser; then
      # Alpine busybox
      adduser -D -H -u "$APP_UID" -G "$APP_GROUP" "$APP_USER" >/dev/null 2>&1 || true
    elif command_exists useradd; then
      useradd -r -m -u "$APP_UID" -g "$APP_GID" -s /usr/sbin/nologin "$APP_USER" >/dev/null 2>&1 || true
    fi
  fi
}

# Change ownership safely if user/group exist
safe_chown() {
  local path="$1"
  if getent passwd "$APP_USER" >/dev/null 2>&1 && getent group "$APP_GROUP" >/dev/null 2>&1; then
    chown -R "$APP_USER:$APP_GROUP" "$path" || true
  fi
}

#-----------------------------
# OS package manager detection
#-----------------------------
PKG_MGR=""
pkg_detect() {
  if command_exists apt-get; then
    PKG_MGR="apt"
  elif command_exists apk; then
    PKG_MGR="apk"
  elif command_exists microdnf; then
    PKG_MGR="microdnf"
  elif command_exists dnf; then
    PKG_MGR="dnf"
  elif command_exists yum; then
    PKG_MGR="yum"
  elif command_exists zypper; then
    PKG_MGR="zypper"
  else
    die "No supported package manager found (apt/apk/dnf/yum/zypper)."
  fi
  log "Detected package manager: $PKG_MGR"
}

pkg_update_once() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      # apk updates indexes automatically during add with --no-cache
      ;;
    microdnf|dnf|yum)
      :
      ;;
    zypper)
      zypper --non-interactive refresh || true
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local pkgs=("$@")
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    microdnf)
      microdnf install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install --no-recommends "${pkgs[@]}"
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    microdnf)
      microdnf clean all || true
      rm -rf /var/cache/yum || true
      ;;
    dnf)
      dnf clean all || true
      rm -rf /var/cache/dnf || true
      ;;
    yum)
      yum clean all || true
      rm -rf /var/cache/yum || true
      ;;
    zypper)
      zypper clean -a || true
      ;;
  esac
}

#-----------------------------
# Install base/common tools
#-----------------------------
install_base_tools() {
  log "Installing base tools and build essentials..."
  pkg_update_once
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl gnupg git openssh-client wget xz-utils \
                  build-essential pkg-config zip unzip tar
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git openssh-client wget xz \
                  build-base pkgconfig zip unzip tar
      update-ca-certificates || true
      ;;
    microdnf|dnf|yum)
      pkg_install ca-certificates curl git openssh-clients wget xz \
                  gcc gcc-c++ make pkgconfig zip unzip tar
      ;;
    zypper)
      pkg_install ca-certificates curl git openssh wget xz \
                  gcc gcc-c++ make pkg-config zip unzip tar
      ;;
  esac
  log "Base tools installed."
}

#-----------------------------
# Project detection
#-----------------------------
is_python_project=false
is_node_project=false
is_ruby_project=false
is_php_project=false
is_go_project=false
is_rust_project=false
is_java_maven_project=false
is_java_gradle_project=false
is_dotnet_project=false

detect_projects() {
  cd "$APP_ROOT"

  # Python
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ] || ls *.py >/dev/null 2>&1; then
    is_python_project=true
  fi

  # Node.js
  if [ -f "package.json" ]; then
    is_node_project=true
  fi

  # Ruby
  if [ -f "Gemfile" ]; then
    is_ruby_project=true
  fi

  # PHP
  if [ -f "composer.json" ]; then
    is_php_project=true
  fi

  # Go
  if [ -f "go.mod" ]; then
    is_go_project=true
  fi

  # Rust
  if [ -f "Cargo.toml" ]; then
    is_rust_project=true
  fi

  # Java
  if [ -f "pom.xml" ]; then
    is_java_maven_project=true
  fi
  if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -f "gradlew" ]; then
    is_java_gradle_project=true
  fi

  # .NET
  if ls *.sln *.csproj *.fsproj >/dev/null 2>&1; then
    is_dotnet_project=true
  fi

  log "Project detection:
  - Python: $is_python_project
  - Node.js: $is_node_project
  - Ruby: $is_ruby_project
  - PHP: $is_php_project
  - Go: $is_go_project
  - Rust: $is_rust_project
  - Java (Maven): $is_java_maven_project
  - Java (Gradle): $is_java_gradle_project
  - .NET: $is_dotnet_project"
}

#-----------------------------
# Language-specific installers
#-----------------------------
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev \
                  gcc g++ make libffi-dev libssl-dev
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev \
                  build-base libffi-dev openssl-dev
      ;;
    microdnf|dnf|yum)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make \
                  libffi-devel openssl-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-virtualenv python3-devel \
                  gcc gcc-c++ make libffi-devel libopenssl-devel
      ;;
  esac

  # Create venv idempotently
  cd "$APP_ROOT"
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"

  # Upgrade pip/setuptools/wheel
  pip install --no-input --upgrade pip setuptools wheel

  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    PIP_NO_CACHE_DIR=1 pip install --no-input -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    log "Installing Python project from pyproject.toml..."
    # Try editable install; fallback to standard install
    if ! PIP_NO_CACHE_DIR=1 pip install --no-input -e .; then
      PIP_NO_CACHE_DIR=1 pip install --no-input .
    fi
  elif [ -f "Pipfile" ]; then
    log "Pipfile detected. Installing pipenv and syncing..."
    pip install --no-input pipenv
    # Install into current venv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
  else
    log "No explicit dependency file found. Skipping Python deps."
  fi

  # Environment defaults for Python apps
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1

  deactivate || true
  log "Python setup complete."
}

# Auto-activate venv in interactive shells if present
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_path="$APP_ROOT/$VENV_DIR"
  local activate_line="source $venv_path/bin/activate"
  if [ -f "$venv_path/bin/activate" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      # Use distro packages for simplicity
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    microdnf|dnf|yum)
      pkg_install nodejs npm
      ;;
    zypper)
      pkg_install nodejs npm
      ;;
  esac

  cd "$APP_ROOT"
  export NODE_ENV="${NODE_ENV:-production}"

  if [ -f "package-lock.json" ]; then
    log "Installing Node dependencies via npm ci..."
    npm ci --omit=dev || npm ci
  elif [ -f "yarn.lock" ]; then
    log "yarn.lock detected. Installing yarn and dependencies..."
    if ! command_exists yarn; then
      npm install -g yarn
    fi
    yarn install --frozen-lockfile --production || yarn install --frozen-lockfile
  else
    log "Installing Node dependencies via npm install..."
    npm install --omit=dev || npm install
  fi

  log "Node.js setup complete."
}

setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential zlib1g-dev
      ;;
    apk)
      pkg_install ruby ruby-dev build-base zlib-dev
      ;;
    microdnf|dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make zlib-devel
      ;;
    zypper)
      pkg_install ruby ruby-devel gcc gcc-c++ make zlib-devel
      ;;
  esac

  cd "$APP_ROOT"
  if ! command_exists bundle; then
    gem install --no-document bundler
  fi
  bundle config set --local path 'vendor/bundle'
  bundle config set --local without 'development test' || true
  bundle install --jobs=4
  log "Ruby setup complete."
}

setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-zip php-mbstring php-xml php-curl unzip git
      if ! command_exists composer; then
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
      fi
      ;;
    apk)
      pkg_install php81 php81-cli php81-phar php81-curl php81-mbstring php81-xml php81-zip unzip git
      if ! command_exists composer; then
        wget -O /usr/local/bin/composer https://getcomposer.org/download/latest-stable/composer.phar
        chmod +x /usr/local/bin/composer
      fi
      ;;
    microdnf|dnf|yum)
      pkg_install php-cli php-json php-zip php-mbstring php-xml php-curl unzip git
      if ! command_exists composer; then
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
      fi
      ;;
    zypper)
      pkg_install php8 php8-cli php8-zip php8-mbstring php8-xml php8-curl unzip git
      if ! command_exists composer; then
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
      fi
      ;;
  esac

  cd "$APP_ROOT"
  if [ -f "composer.json" ]; then
    composer install --no-interaction --no-progress --prefer-dist --no-dev || composer install --no-interaction --prefer-dist
  fi
  log "PHP setup complete."
}

setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    microdnf|dnf|yum)
      pkg_install golang
      ;;
    zypper)
      pkg_install go
      ;;
  esac
  cd "$APP_ROOT"
  ensure_dir "$APP_ROOT/bin"
  if [ -f "go.mod" ]; then
    go mod download
    # Try to build if main package
    if grep -q "module" go.mod 2>/dev/null; then
      if [ -f "main.go" ] || grep -R --include="*.go" -E "^package main" . >/dev/null 2>&1; then
        go build -v -o "$APP_ROOT/bin/app" ./...
      fi
    fi
  fi
  log "Go setup complete."
}

setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install cargo rustc
      ;;
    apk)
      pkg_install cargo rust
      ;;
    microdnf|dnf|yum)
      pkg_install rust cargo
      ;;
    zypper)
      pkg_install rust cargo
      ;;
  esac
  cd "$APP_ROOT"
  if [ -f "Cargo.toml" ]; then
    cargo fetch
    cargo build --release || cargo build
  fi
  log "Rust setup complete."
}

setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install default-jdk maven
      ;;
    apk)
      pkg_install openjdk17-jdk maven
      ;;
    microdnf|dnf|yum)
      pkg_install java-17-openjdk-devel maven
      ;;
    zypper)
      pkg_install java-17-openjdk-devel maven
      ;;
  esac
  cd "$APP_ROOT"
  mvn -B -DskipTests package || mvn -B package
  log "Java (Maven) setup complete."
}

setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install default-jdk
      ;;
    apk)
      pkg_install openjdk17-jdk
      ;;
    microdnf|dnf|yum)
      pkg_install java-17-openjdk-devel
      ;;
    zypper)
      pkg_install java-17-openjdk-devel
      ;;
  esac
  cd "$APP_ROOT"
  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon build -x test || ./gradlew --no-daemon build
  else
    # Use distro gradle if available
    if command_exists gradle; then
      gradle --no-daemon build -x test || gradle --no-daemon build
    else
      warn "Gradle wrapper not found and gradle not installed. Skipping build."
    fi
  fi
  log "Java (Gradle) setup complete."
}

setup_dotnet() {
  log "Setting up .NET environment..."
  if ! command_exists dotnet; then
    warn ".NET SDK not found in the container. Please use a dotnet SDK base image or preinstall the SDK."
    return 0
  fi
  cd "$APP_ROOT"
  dotnet restore || true
  log ".NET setup complete."
}

#-----------------------------
# Environment configuration
#-----------------------------
guess_port() {
  # Heuristics: returns a default port based on detected project types and files
  local port="8080"
  if $is_python_project; then
    if [ -f "manage.py" ]; then port="8000"; fi
    if grep -R -E "Flask|flask" -n . >/dev/null 2>&1; then port="5000"; fi
  fi
  if $is_node_project; then
    port="3000"
  fi
  if $is_ruby_project; then
    port="3000"
  fi
  if $is_php_project; then
    port="8000"
  fi
  if $is_go_project || $is_rust_project || $is_java_maven_project || $is_java_gradle_project || $is_dotnet_project; then
    port="8080"
  fi
  echo "$port"
}

write_env_file() {
  cd "$APP_ROOT"
  local default_port
  default_port="$(guess_port)"

  if [ ! -f "$ENV_FILE" ]; then
    log "Creating default $ENV_FILE..."
    cat > "$ENV_FILE" <<EOF
# Generated by setup script
APP_ENV=production
PORT=${PORT:-$default_port}
# Python
PYTHONUNBUFFERED=1
PYTHONDONTWRITEBYTECODE=1
# Node.js
NODE_ENV=production
# Common
LOG_LEVEL=info
EOF
  else
    log "$ENV_FILE already exists. Not overwriting."
  fi
}

# Create the .ci/build.sh, Makefile, and run-build symlink as per repair commands
create_build_files() {
  cd "$APP_ROOT"

  cat > run-build.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1 && [ -f pnpm-lock.yaml ]; then
    pnpm install --frozen-lockfile && pnpm build
  elif command -v yarn >/dev/null 2>&1 && [ -f yarn.lock ]; then
    yarn install --frozen-lockfile && yarn build
  else
    if command -v npm >/dev/null 2>&1; then
      npm ci --no-audit --no-fund && npm run build
    else
      echo "npm not found in PATH" >&2; exit 2
    fi
  fi
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew && ./gradlew build -x test
elif [ -f build.gradle ]; then
  gradle build -x test
elif [ -f Cargo.toml ]; then
  cargo build --release
elif ls *.sln >/dev/null 2>&1; then
  dotnet restore && dotnet build -c Release
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip && python -m pip install -e .
elif [ -f setup.py ]; then
  python -m pip install -U pip && python -m pip install -e .
elif [ -f Makefile ]; then
  make build || make
else
  echo "No recognized build config found" >&2
  exit 1
fi
EOF
  chmod +x run-build.sh

  cat > Makefile <<'EOF'
.PHONY: build
build:
	./run-build.sh
EOF

  # Validate script syntax
  bash -n ./run-build.sh || true
}

#-----------------------------
# Directory structure
#-----------------------------
setup_directories() {
  cd "$APP_ROOT"
  ensure_dir "$APP_ROOT/logs"
  ensure_dir "$APP_ROOT/tmp"
  ensure_dir "$APP_ROOT/data"
  ensure_dir "$APP_ROOT/bin"
  ensure_dir "$APP_ROOT/.cache"
  ensure_app_user
  safe_chown "$APP_ROOT"
}

#-----------------------------
# Main
#-----------------------------
main() {
  log "Starting environment setup in $APP_ROOT"
  pkg_detect
  install_base_tools
  detect_projects
  setup_directories

  # Install language environments as detected
  if $is_python_project; then setup_python; fi
  if $is_node_project; then setup_node; fi
  if $is_ruby_project; then setup_ruby; fi
  if $is_php_project; then setup_php; fi
  if $is_go_project; then setup_go; fi
  if $is_rust_project; then setup_rust; fi
  if $is_java_maven_project; then setup_java_maven; fi
  if $is_java_gradle_project; then setup_java_gradle; fi
  if $is_dotnet_project; then setup_dotnet; fi

  write_env_file

  setup_auto_activate

  create_build_files

  bash ./run-build.sh || true

  pkg_clean
  log "Environment setup completed successfully."

  cat <<'EONOTE'
Notes:
- The environment was configured based on detected project files.
- For Python, a virtual environment was created in .venv. Activate with: source .venv/bin/activate
- Default environment variables were written to .env (not overwritten if already present).
- If running as non-root, consider using the created "app" user inside the container.
EONOTE
}

main "$@"