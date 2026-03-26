#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type (Python/Node/Ruby/PHP/Go/Java/Rust/.NET)
# - Installs runtimes and system dependencies
# - Configures environment and directories
# - Idempotent and safe to re-run

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Logging
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
err() { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }

trap 'err "Failed at line $LINENO. Exiting."; exit 1' ERR

# Defaults and configuration
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
TZ="${TZ:-Etc/UTC}"

# Detect if running as root
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

# Detect package manager and define commands
PKG_MGR=""
PKG_UPDATED_FLAG="/var/cache/.pkg_updated"

pkg_detect() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt";
  elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk";
  elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf";
  elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum";
  elif command -v zypper >/dev/null 2>&1; then PKG_MGR="zypper";
  elif command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman";
  else PKG_MGR="unknown"; fi
}

pkg_update() {
  [ "$PKG_MGR" = "unknown" ] && { warn "Unknown package manager; skipping system update"; return 0; }
  [ ! -w / ] && { warn "No root permissions; skipping system update"; return 0; }
  if [ -f "$PKG_UPDATED_FLAG" ]; then
    info "Packages already updated in this container session."
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      touch "$PKG_UPDATED_FLAG"
      ;;
    apk)
      apk update
      touch "$PKG_UPDATED_FLAG"
      ;;
    dnf)
      dnf makecache -y
      touch "$PKG_UPDATED_FLAG"
      ;;
    yum)
      yum makecache -y
      touch "$PKG_UPDATED_FLAG"
      ;;
    zypper)
      zypper refresh -y || zypper refresh
      touch "$PKG_UPDATED_FLAG"
      ;;
    pacman)
      pacman -Sy --noconfirm
      touch "$PKG_UPDATED_FLAG"
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  [ "$PKG_MGR" = "unknown" ] && { warn "Unknown package manager; cannot install: $*"; return 0; }
  [ ! -w / ] && { warn "No root permissions; cannot install system packages: $*"; return 0; }
  [ "$#" -eq 0 ] && return 0
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
    zypper)
      zypper install -y "$@"
      ;;
    pacman)
      pacman -S --noconfirm --needed "$@"
      ;;
  esac
}

pkg_clean() {
  [ "$PKG_MGR" = "unknown" ] && return 0
  [ ! -w / ] && return 0
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf)
      dnf clean all -y || true
      ;;
    yum)
      yum clean all -y || true
      ;;
    zypper)
      zypper clean -a || true
      ;;
    pacman)
      pacman -Scc --noconfirm || true
      ;;
  esac
}

# User and directory setup
ensure_user_and_dirs() {
  log "Setting up application user and directories..."

  # Create group and user if running as root
  if is_root; then
    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
      groupadd "$APP_GROUP"
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      useradd -m -s /bin/bash -g "$APP_GROUP" "$APP_USER"
    fi
  else
    warn "Not running as root; skipping user creation. Continuing as $(id -un)."
    APP_USER="$(id -un)"
    APP_GROUP="$(id -gn)"
  fi

  # Create application directories
  mkdir -p "$APP_DIR" "$APP_DIR/logs" "$APP_DIR/data" "$APP_DIR/tmp"
  chmod 755 "$APP_DIR" || true
  chmod 775 "$APP_DIR/logs" "$APP_DIR/data" "$APP_DIR/tmp" || true

  # Assign ownership
  if is_root; then
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" || true
  fi

  # Set safe umask
  umask 022

  log "Application base directory: $APP_DIR"
}

# Base tools often needed across stacks
install_base_tools() {
  log "Installing base system tools..."
  pkg_detect
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git unzip xz-utils tzdata gnupg openssh-client build-essential pkg-config
      # Locale setup (optional)
      if ! locale -a 2>/dev/null | grep -qi 'en_US.utf8'; then
        pkg_install locales
        sed -i 's/# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
        locale-gen || true
      fi
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl wget git unzip tzdata openssh-client build-base pkgconfig
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl wget git unzip tzdata gnupg2 openssh-clients gcc gcc-c++ make pkgconfig
      update-ca-trust || true
      ;;
    zypper)
      pkg_install ca-certificates curl wget git unzip timezone openssh gcc gcc-c++ make pkg-config
      update-ca-certificates || true
      ;;
    pacman)
      pkg_install ca-certificates curl wget git unzip tzdata openssh base-devel pkgconf
      update-ca-trust || true
      ;;
    *)
      warn "Skipping base tools installation; unsupported package manager."
      ;;
  esac
  # Set timezone non-interactively
  if is_root; then
    case "$PKG_MGR" in
      apt|dnf|yum|zypper|pacman)
        ln -fs "/usr/share/zoneinfo/$TZ" /etc/localtime || true
        dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
        ;;
      apk)
        echo "$TZ" > /etc/timezone || true
        ;;
    esac
  fi
}

# Environment file helpers
ensure_env_line() {
  # ensure_env_line FILE KEY VALUE
  local file="$1" key="$2" value="$3"
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|g" "$file"
  else
    echo "${key}=${value}" >>"$file"
  fi
}

write_env_files() {
  log "Configuring environment variables..."
  local env_file="${APP_DIR}/.env"
  ensure_env_line "$env_file" APP_ENV "$APP_ENV"
  ensure_env_line "$env_file" APP_PORT "$APP_PORT"
  ensure_env_line "$env_file" APP_DIR "$APP_DIR"
  ensure_env_line "$env_file" TZ "$TZ"

  # profile for login shells
  if is_root; then
    local profile="/etc/profile.d/project_env.sh"
    cat > "$profile" <<EOF
# Auto-generated project environment
export APP_DIR="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
export TZ="${TZ}"
# Add common toolchain paths if present
[ -d "\$APP_DIR/.venv/bin" ] && export PATH="\$APP_DIR/.venv/bin:\$PATH"
[ -d "\$HOME/.dotnet" ] && export DOTNET_ROOT="\$HOME/.dotnet" && export PATH="\$HOME/.dotnet:\$PATH"
[ -d "\$HOME/.cargo/bin" ] && export PATH="\$HOME/.cargo/bin:\$PATH"
[ -d "\$HOME/go/bin" ] && export GOPATH="\$HOME/go" && export PATH="\$HOME/go/bin:\$PATH"
EOF
    chmod 644 "$profile"
  fi

  log "Environment configuration written to $env_file"
}

ensure_venv_auto_activate() {
  local bashrc
  if is_root; then bashrc="/home/${APP_USER}/.bashrc"; [ ! -d "/home/${APP_USER}" ] && bashrc="/root/.bashrc"; else bashrc="$HOME/.bashrc"; fi
  if [ -f "${APP_DIR}/.venv/bin/activate" ] && ! grep -Fq "source \"${APP_DIR}/.venv/bin/activate\"" "$bashrc" 2>/dev/null; then
    printf '\n# Auto-activate project venv\n[ -f "%s/.venv/bin/activate" ] && source "%s/.venv/bin/activate"\n' "${APP_DIR}" "${APP_DIR}" >> "$bashrc"
  fi
}

# Project type detection
PROJECT_TYPES=()

detect_project_types() {
  PROJECT_TYPES=()
  # Python
  if [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/Pipfile" ] || [ -f "${APP_DIR}/setup.py" ]; then
    PROJECT_TYPES+=("python")
  fi
  # Node.js
  if [ -f "${APP_DIR}/package.json" ]; then
    PROJECT_TYPES+=("node")
  fi
  # Ruby
  if [ -f "${APP_DIR}/Gemfile" ]; then
    PROJECT_TYPES+=("ruby")
  fi
  # PHP
  if [ -f "${APP_DIR}/composer.json" ]; then
    PROJECT_TYPES+=("php")
  fi
  # Go
  if [ -f "${APP_DIR}/go.mod" ]; then
    PROJECT_TYPES+=("go")
  fi
  # Java/Maven/Gradle
  if [ -f "${APP_DIR}/pom.xml" ]; then
    PROJECT_TYPES+=("java-maven")
  fi
  if [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/build.gradle.kts" ] || [ -f "${APP_DIR}/gradlew" ]; then
    PROJECT_TYPES+=("java-gradle")
  fi
  # Rust
  if [ -f "${APP_DIR}/Cargo.toml" ]; then
    PROJECT_TYPES+=("rust")
  fi
  # .NET
  if compgen -G "${APP_DIR}/*.csproj" >/dev/null 2>&1 || [ -f "${APP_DIR}/global.json" ]; then
    PROJECT_TYPES+=("dotnet")
  fi
  # Default
  if [ "${#PROJECT_TYPES[@]}" -eq 0 ]; then
    warn "No explicit project type detected; installing base tools only."
  else
    info "Detected project types: ${PROJECT_TYPES[*]}"
  fi
}

# Language-specific installers

install_python_stack() {
  log "Setting up Python environment..."
  pkg_detect; pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev build-essential libssl-dev libffi-dev libpq-dev libsqlite3-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev build-base libffi-dev openssl-dev postgresql-dev sqlite-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make openssl-devel libffi-devel sqlite-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libopenssl-devel libffi-devel sqlite3-devel
      ;;
    pacman)
      pkg_install python python-pip base-devel openssl libffi sqlite
      ;;
    *)
      warn "Unsupported package manager for Python; attempting to proceed if python3 exists."
      ;;
  esac

  # Create venv
  if [ ! -d "${APP_DIR}/.venv" ]; then
    python3 -m venv "${APP_DIR}/.venv"
    log "Python virtual environment created at ${APP_DIR}/.venv"
  else
    info "Python virtual environment already exists."
  fi

  # Activate and install deps
  set +u
  # shellcheck source=/dev/null
  source "${APP_DIR}/.venv/bin/activate"
  set -u
  python -m pip install -U pip wheel setuptools

  if [ -f "${APP_DIR}/requirements.txt" ]; then
    pip install -r "${APP_DIR}/requirements.txt"
  elif [ -f "${APP_DIR}/pyproject.toml" ]; then
    # Prefer PEP 517 install if project is PDM/Poetry; fallback to pip
    if grep -qi '\[tool.poetry\]' "${APP_DIR}/pyproject.toml"; then
      pip install poetry && poetry config virtualenvs.create false && poetry install --no-interaction --no-ansi --no-root || true
    else
      pip install . || true
    fi
  elif [ -f "${APP_DIR}/Pipfile" ]; then
    pip install pipenv && pipenv install --dev --system --deploy || pipenv install --system || true
  fi

  deactivate || true
  log "Python dependencies installed."
}

install_node_stack() {
  log "Setting up Node.js environment..."
  pkg_detect; pkg_update
  local need_yarn=false need_pnpm=false
  [ -f "${APP_DIR}/yarn.lock" ] && need_yarn=true
  [ -f "${APP_DIR}/pnpm-lock.yaml" ] && need_pnpm=true

  case "$PKG_MGR" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
    zypper)
      pkg_install nodejs npm
      ;;
    pacman)
      pkg_install nodejs npm
      ;;
    *)
      warn "Unsupported package manager for Node.js; skipping system install if node not present."
      ;;
  esac
  if ! command -v node >/dev/null 2>&1; then
    err "Node.js is not installed and could not be installed via package manager."
    return 1
  fi

  # Install package manager helpers if needed
  if $need_yarn; then
    if ! command -v yarn >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then
        corepack enable && corepack prepare yarn@stable --activate || npm i -g yarn@stable
      else
        npm i -g yarn@stable
      fi
    fi
  fi
  if $need_pnpm; then
    if ! command -v pnpm >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then
        corepack enable && corepack prepare pnpm@latest --activate || npm i -g pnpm@latest
      else
        npm i -g pnpm@latest
      fi
    fi
  fi

  # Install project dependencies
  pushd "$APP_DIR" >/dev/null
  if $need_pnpm; then
    pnpm install --frozen-lockfile || pnpm install
  elif $need_yarn; then
    yarn install --frozen-lockfile || yarn install
  else
    if [ -f package-lock.json ]; then
      npm ci --no-audit --no-fund
    else
      npm install --no-audit --no-fund
    fi
  fi
  popd >/dev/null

  log "Node.js dependencies installed."
}

install_ruby_stack() {
  log "Setting up Ruby environment..."
  pkg_detect; pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    zypper)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    pacman)
      pkg_install ruby base-devel
      ;;
    *)
      warn "Unsupported package manager for Ruby."
      ;;
  esac
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document
  fi
  pushd "$APP_DIR" >/dev/null
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs="$(nproc)" --retry=3
  popd >/dev/null
  log "Ruby dependencies installed."
}

install_php_stack() {
  log "Setting up PHP environment..."
  pkg_detect; pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip git
      ;;
    apk)
      pkg_install php83 php83-cli php83-mbstring php83-xml php83-curl php83-zip unzip git || pkg_install php php-cli php-mbstring php-xml php-curl php-zip unzip git
      ;;
    dnf|yum)
      pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip git
      ;;
    zypper)
      pkg_install php8 php8-mbstring php8-xml php8-curl php8-zip unzip git || pkg_install php php-mbstring php-xml php-curl php-zip unzip git
      ;;
    pacman)
      pkg_install php php-embed unzip git
      ;;
    *)
      warn "Unsupported package manager for PHP."
      ;;
  esac
  # Composer
  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet || true
    rm -f composer-setup.php
  fi
  pushd "$APP_DIR" >/dev/null
  if [ -f composer.lock ]; then
    composer install --no-interaction --prefer-dist --no-ansi
  else
    composer install --no-interaction --no-ansi || true
  fi
  popd >/dev/null
  log "PHP dependencies installed."
}

install_go_stack() {
  log "Setting up Go environment..."
  pkg_detect; pkg_update
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
    pacman) pkg_install go ;;
    *) warn "Unsupported package manager for Go." ;;
  esac
  # GOPATH
  local home_dir
  if is_root; then home_dir="/home/${APP_USER}"; [ ! -d "$home_dir" ] && home_dir="/root"; else home_dir="$HOME"; fi
  local gopath="${GOPATH:-$home_dir/go}"
  mkdir -p "$gopath/bin"
  [ -d "$gopath" ] && chown -R "$APP_USER:$APP_GROUP" "$gopath" 2>/dev/null || true

  pushd "$APP_DIR" >/dev/null
  if command -v go >/dev/null 2>&1; then
    go env -w GOPATH="$gopath" || true
    go mod download
  else
    warn "Go binary not found."
  fi
  popd >/dev/null

  log "Go dependencies prepared."
}

install_java_maven_stack() {
  log "Setting up Java (Maven) environment..."
  pkg_detect; pkg_update
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17 maven ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven ;;
    zypper) pkg_install java-17-openjdk-devel maven ;;
    pacman) pkg_install jdk17-openjre maven ;;
    *) warn "Unsupported package manager for Java." ;;
  esac
  pushd "$APP_DIR" >/dev/null
  if command -v mvn >/dev/null 2>&1; then
    mvn -B -DskipTests dependency:go-offline || true
  fi
  popd >/dev/null
  log "Maven dependencies cached."
}

install_java_gradle_stack() {
  log "Setting up Java (Gradle) environment..."
  pkg_detect; pkg_update
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk gradle || pkg_install openjdk-17-jdk ;;
    apk) pkg_install openjdk17 gradle || pkg_install openjdk17 ;;
    dnf|yum) pkg_install java-17-openjdk-devel gradle || pkg_install java-17-openjdk-devel ;;
    zypper) pkg_install java-17-openjdk-devel gradle || pkg_install java-17-openjdk-devel ;;
    pacman) pkg_install jdk17-openjre gradle || pkg_install jdk17-openjre ;;
    *) warn "Unsupported package manager for Java." ;;
  esac
  pushd "$APP_DIR" >/dev/null
  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon tasks >/dev/null || true
  elif command -v gradle >/dev/null 2>&1; then
    gradle --no-daemon tasks >/dev/null || true
  fi
  popd >/dev/null
  log "Gradle environment prepared."
}

install_rust_stack() {
  log "Setting up Rust environment..."
  pkg_detect; pkg_update
  case "$PKG_MGR" in
    apt) pkg_install rustc cargo ;;
    apk) pkg_install rust cargo ;;
    dnf|yum) pkg_install rust cargo ;;
    zypper) pkg_install rust cargo ;;
    pacman) pkg_install rust ;;
    *) warn "Unsupported package manager for Rust." ;;
  esac
  pushd "$APP_DIR" >/dev/null
  if command -v cargo >/dev/null 2>&1; then
    cargo fetch || true
  fi
  popd >/dev/null
  log "Rust dependencies fetched."
}

install_dotnet_stack() {
  log "Setting up .NET SDK environment..."
  # Install into user space using dotnet-install.sh (no root required)
  local home_dir
  if is_root; then home_dir="/home/${APP_USER}"; [ ! -d "$home_dir" ] && home_dir="/root"; else home_dir="$HOME"; fi
  local dotnet_root="${home_dir}/.dotnet"
  mkdir -p "$dotnet_root"
  chown -R "$APP_USER:$APP_GROUP" "$dotnet_root" 2>/dev/null || true

  local dotnet_install="/tmp/dotnet-install.sh"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$dotnet_install"
  chmod +x "$dotnet_install"
  # If global.json exists, installer will pick appropriate version; otherwise LTS
  su_exec_prefix=()
  if is_root && [ "$APP_USER" != "root" ]; then
    su_exec_prefix=(su -s /bin/bash - "$APP_USER" -c)
  fi
  if [ "${#su_exec_prefix[@]}" -gt 0 ]; then
    "${su_exec_prefix[@]}" "bash -lc '$dotnet_install --install-dir \"$dotnet_root\" --quality lts'"
  else
    "$dotnet_install" --install-dir "$dotnet_root" --quality lts
  fi

  export DOTNET_ROOT="$dotnet_root"
  export PATH="$DOTNET_ROOT:$PATH"

  # Restore
  pushd "$APP_DIR" >/dev/null
  if compgen -G "*.csproj" >/dev/null 2>&1; then
    "$DOTNET_ROOT/dotnet" restore || true
  fi
  popd >/dev/null

  log ".NET SDK installed at $DOTNET_ROOT."
}

run_ci_build_detect() {
  info "Generating build detection helper script..."
  local script=".ci_build.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci --no-audit --progress=false
    npm run -s build || npm run -s build:prod || true
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile --non-interactive
    yarn -s build || true
  elif command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile
    pnpm -s build || true
  else
    echo "Node.js package manager not found"
    exit 1
  fi
elif [ -f pom.xml ]; then
  mvn -q -e -DskipTests package
elif [ -f gradlew ] || [ -f build.gradle ]; then
  if [ -x ./gradlew ]; then ./gradlew build -x test; else gradle build -x test; fi
elif [ -f Cargo.toml ]; then
  cargo build --locked --quiet
elif [ -f go.mod ]; then
  go build ./...
elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ]; then
  python -m pip install -U pip
  if [ -f requirements.txt ]; then
    pip install -r requirements.txt || true
  fi
  if [ -f setup.py ] || [ -f pyproject.toml ]; then
    pip install -e . || true
  fi
  python - <<PY
print("Build/Install complete")
PY
elif [ -f Makefile ]; then
  make -s build || make -s
else
  echo "No recognized build system"
  exit 1
fi
EOF
  chmod +x "$script"
  info "Executing build detection script..."
  bash ./.ci_build.sh
}

# Final touches: permissions and cleaning
finalize_setup() {
  if is_root; then
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" || true
  fi
  pkg_clean
  log "Setup finalized."
}

# Main
main() {
  log "Starting environment setup..."
  ensure_user_and_dirs
  install_base_tools
  write_env_files
  ensure_venv_auto_activate

  # Switch to APP_DIR for detection and installs that rely on CWD
  cd "$APP_DIR"

  detect_project_types

  for t in "${PROJECT_TYPES[@]:-}"; do
    case "$t" in
      python) install_python_stack ;;
      node) install_node_stack ;;
      ruby) install_ruby_stack ;;
      php) install_php_stack ;;
      go) install_go_stack ;;
      java-maven) install_java_maven_stack ;;
      java-gradle) install_java_gradle_stack ;;
      rust) install_rust_stack ;;
      dotnet) install_dotnet_stack ;;
    esac
  done

  run_ci_build_detect
  finalize_setup

  info "Environment variables:"
  echo "  APP_DIR=$APP_DIR"
  echo "  APP_ENV=$APP_ENV"
  echo "  APP_PORT=$APP_PORT"
  echo "  TZ=$TZ"

  log "Environment setup completed successfully."

  # Guidance for running within container
  echo
  echo "Next steps (examples):"
  echo "- To activate Python venv: source \"$APP_DIR/.venv/bin/activate\""
  echo "- Node app: cd \"$APP_DIR\" && npm start (or yarn start)"
  echo "- Python app: cd \"$APP_DIR\" && python app.py (or framework-specific command)"
  echo "- .NET app: cd \"$APP_DIR\" && ~/.dotnet/dotnet run"
  echo
}

main "$@"