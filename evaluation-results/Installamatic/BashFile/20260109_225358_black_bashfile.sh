#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Auto-detects common project types and installs runtimes and dependencies
# - Installs necessary system packages and build tools
# - Sets up directories, permissions, and environment variables
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'
umask 0022

#-----------------------------#
# Logging and error handling  #
#-----------------------------#
COLOR_OK="$(printf '\033[0;32m')"
COLOR_WARN="$(printf '\033[1;33m')"
COLOR_ERR="$(printf '\033[0;31m')"
COLOR_NONE="$(printf '\033[0m')"

log()    { echo -e "${COLOR_OK}[$(date +'%Y-%m-%d %H:%M:%S')] $*${COLOR_NONE}"; }
warn()   { echo -e "${COLOR_WARN}[WARN] $*${COLOR_NONE}" >&2; }
err()    { echo -e "${COLOR_ERR}[ERROR] $*${COLOR_NONE}" >&2; }
die()    { err "$*"; exit 1; }

cleanup() { :; }
on_error() { err "An error occurred on line ${BASH_LINENO[0]} (command: ${BASH_COMMAND})"; }
trap cleanup EXIT
trap on_error ERR

#-----------------------------#
# Global defaults             #
#-----------------------------#
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
DEFAULT_PORT="${PORT:-8080}"
STATE_DIR="/var/cache/project-setup"
mkdir -p "$STATE_DIR"

#-----------------------------#
# Package manager detection   #
#-----------------------------#
PKG_MANAGER=""
PKG_UPDATE_STAMP="$STATE_DIR/pkg_updated"
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  else
    die "No supported package manager found (apt, apk, dnf, yum, zypper)."
  fi
}

pkg_update() {
  if [[ -f "$PKG_UPDATE_STAMP" ]]; then
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
    zypper)
      zypper --non-interactive refresh
      ;;
  esac
  touch "$PKG_UPDATE_STAMP"
}

pkg_install() {
  local pkgs=("$@")
  case "$PKG_MANAGER" in
    apt)
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
    zypper)
      zypper --non-interactive install -y "${pkgs[@]}"
      ;;
  esac
}

pkg_group_build_tools() {
  case "$PKG_MANAGER" in
    apt)
      pkg_install build-essential
      ;;
    apk)
      pkg_install build-base
      ;;
    dnf)
      dnf groupinstall -y "Development Tools" || pkg_install gcc gcc-c++ make
      ;;
    yum)
      yum groupinstall -y "Development Tools" || pkg_install gcc gcc-c++ make
      ;;
    zypper)
      pkg_install -t pattern devel_C_C++ || pkg_install gcc gcc-c++ make
      ;;
  esac
}

#-----------------------------#
# System base dependencies    #
#-----------------------------#
install_base_system_tools() {
  log "Installing base system tools and build dependencies..."
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git gnupg pkg-config unzip xz-utils tar openssh-client
      ;;
    apk)
      pkg_install ca-certificates curl git gnupg pkgconf unzip xz tar openssh-client
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gnupg2 pkgconfig unzip xz tar openssh-clients
      ;;
    zypper)
      pkg_install ca-certificates curl git gpg2 pkg-config unzip xz tar openssh
      ;;
  esac
  pkg_group_build_tools
  update-ca-certificates || true
  log "Base system tools installed."
}

#-----------------------------#
# User and permissions        #
#-----------------------------#
ensure_app_user() {
  log "Ensuring application user and group exist..."
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if command -v addgroup >/dev/null 2>&1; then
      addgroup -g "$APP_GID" -S "$APP_GROUP" || addgroup -g "$APP_GID" "$APP_GROUP" || true
    elif command -v groupadd >/dev/null 2>&1; then
      groupadd -g "$APP_GID" -f "$APP_GROUP"
    fi
  fi
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if command -v adduser >/dev/null 2>&1; then
      adduser -S -D -H -u "$APP_UID" -G "$APP_GROUP" "$APP_USER" || adduser -D -H -u "$APP_UID" -G "$APP_GROUP" "$APP_USER" || true
    elif command -v useradd >/dev/null 2>&1; then
      useradd -M -N -u "$APP_UID" -g "$APP_GROUP" -s /usr/sbin/nologin "$APP_USER" || true
    fi
  fi
  log "User setup complete."
}

#-----------------------------#
# Project directories         #
#-----------------------------#
setup_directories() {
  log "Setting up project directories at $PROJECT_ROOT ..."
  mkdir -p "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,run,data}
  chown -R "$APP_UID":"$APP_GID" "$PROJECT_ROOT" || true
  chmod -R u=rwX,g=rX,o=rX "$PROJECT_ROOT" || true
  log "Directories prepared."
}

#-----------------------------#
# Environment configuration   #
#-----------------------------#
install_profile_env() {
  log "Configuring environment variables..."
  local profile_d="/etc/profile.d"
  mkdir -p "$profile_d"
  cat > "$profile_d/project_env.sh" <<'EOF'
# Project-wide environment defaults
export APP_ENV=${APP_ENV:-production}
export LANG=${LANG:-C.UTF-8}
export LC_ALL=${LC_ALL:-C.UTF-8}
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_NO_CACHE_DIR=1
export NODE_ENV=${NODE_ENV:-production}
export NOKOGIRI_USE_SYSTEM_LIBRARIES=1
# Add common bin paths if exist
[ -d "/app/.venv/bin" ] && export PATH="/app/.venv/bin:$PATH"
[ -d "/root/.dotnet" ] && export DOTNET_ROOT="${DOTNET_ROOT:-/root/.dotnet}" && export PATH="$DOTNET_ROOT:$DOTNET_ROOT/tools:$PATH"
[ -d "/usr/local/bin" ] && export PATH="/usr/local/bin:$PATH"
EOF
  chmod 0644 "$profile_d/project_env.sh"
  log "Environment profile configured."
}

#-----------------------------#
# Helpers for detection       #
#-----------------------------#
has_file() { [[ -f "$PROJECT_ROOT/$1" ]]; }
has_any() {
  local f
  for f in "$@"; do
    [[ -f "$PROJECT_ROOT/$f" ]] && return 0
  done
  return 1
}
grep_file() { local file="$1" pattern="$2"; [[ -f "$PROJECT_ROOT/$file" ]] && grep -qiE "$pattern" "$PROJECT_ROOT/$file"; }

#-----------------------------#
# Node.js setup               #
#-----------------------------#
install_node_runtime() {
  log "Installing Node.js runtime..."
  case "$PKG_MANAGER" in
    apt)
      # Use distro packages for stability; can be replaced with NodeSource if needed
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm || pkg_install nodejs
      ;;
    zypper)
      pkg_install nodejs npm || pkg_install nodejs16 nodejs-common npm16 || true
      ;;
  esac
  node --version >/dev/null 2>&1 || warn "Node.js may not have been installed successfully."
  npm --version >/dev/null 2>&1 || warn "npm may not have been installed successfully."
  log "Node.js installation complete."
}

install_node_dependencies() {
  log "Installing Node.js dependencies..."
  pushd "$PROJECT_ROOT" >/dev/null
  local use_ci=""
  if has_file "package-lock.json"; then
    use_ci="yes"
  fi
  if has_file "yarn.lock"; then
    # Install yarn via npm to avoid external repos
    npm install -g yarn >/dev/null 2>&1 || true
    if command -v yarn >/dev/null 2>&1; then
      yarn install --frozen-lockfile || yarn install
    else
      warn "yarn not available; falling back to npm."
      [[ -n "$use_ci" ]] && npm ci || npm install
    fi
  elif has_file "pnpm-lock.yaml"; then
    npm install -g pnpm >/dev/null 2>&1 || true
    if command -v pnpm >/dev/null 2>&1; then
      pnpm install --frozen-lockfile || pnpm install
    else
      warn "pnpm not available; falling back to npm."
      [[ -n "$use_ci" ]] && npm ci || npm install
    fi
  else
    [[ -n "$use_ci" ]] && npm ci || npm install
  fi
  popd >/dev/null
  log "Node.js dependencies installed."
}

configure_node_env() {
  log "Configuring Node.js environment..."
  local port="${PORT:-3000}"
  {
    echo "export NODE_ENV=\${NODE_ENV:-production}"
    echo "export PORT=\${PORT:-$port}"
  } >> /etc/profile.d/project_env.sh
  log "Node.js environment configured (PORT=$port)."
}

#-----------------------------#
# Python setup                #
#-----------------------------#
install_python_runtime() {
  log "Installing Python runtime..."
  case "$PKG_MANAGER" in
    apt)
      pkg_install python3 python3-venv python3-dev python3-pip libffi-dev libssl-dev
      ;;
    apk)
      pkg_install python3 python3-dev py3-pip libffi-dev openssl-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-devel python3-pip libffi-devel openssl-devel
      ;;
    zypper)
      pkg_install python3 python3-devel python3-pip libffi-devel libopenssl-devel
      ;;
  esac
  python3 --version || die "Python3 installation failed."
  log "Python installed."
}

setup_python_venv_and_deps() {
  log "Setting up Python virtual environment and dependencies..."
  pushd "$PROJECT_ROOT" >/dev/null
  local venv_dir="$PROJECT_ROOT/.venv"
  if [[ ! -d "$venv_dir" ]]; then
    python3 -m venv "$venv_dir"
  fi
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  pip install --upgrade pip wheel setuptools
  if has_file "requirements.txt"; then
    pip install -r requirements.txt
  elif has_file "pyproject.toml"; then
    # Try to install project via PEP 517
    pip install .
  elif has_file "Pipfile"; then
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv sync --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
  else
    warn "No Python dependency file found; skipping dependency install."
  fi
  # Ensure a stub requirements.txt exists for external build steps
  [ -f "requirements.txt" ] || touch requirements.txt
  deactivate || true
  popd >/dev/null
  log "Python environment ready."
}

configure_python_env() {
  log "Configuring Python environment..."
  local port="${PYTHON_PORT:-}"
  # Heuristic: set common ports based on frameworks
  if grep_file "requirements.txt" "flask"; then
    port="${port:-5000}"
    {
      echo "export FLASK_ENV=\${FLASK_ENV:-production}"
      echo "export FLASK_RUN_HOST=\${FLASK_RUN_HOST:-0.0.0.0}"
      echo "export FLASK_RUN_PORT=\${FLASK_RUN_PORT:-$port}"
    } >> /etc/profile.d/project_env.sh
  elif grep_file "requirements.txt" "django"; then
    port="${port:-8000}"
    echo "export DJANGO_SETTINGS_MODULE=\${DJANGO_SETTINGS_MODULE:-}" >> /etc/profile.d/project_env.sh
  elif grep_file "requirements.txt" "fastapi|uvicorn"; then
    port="${port:-8000}"
    echo "export UVICORN_HOST=\${UVICORN_HOST:-0.0.0.0}" >> /etc/profile.d/project_env.sh
    echo "export UVICORN_PORT=\${UVICORN_PORT:-$port}" >> /etc/profile.d/project_env.sh
  fi
  [[ -z "$port" ]] && port="${PORT:-5000}"
  echo "export PORT=\${PORT:-$port}" >> /etc/profile.d/project_env.sh
  log "Python environment configured (PORT=$port)."
}

#-----------------------------#
# Ruby setup                  #
#-----------------------------#
install_ruby_and_bundler() {
  log "Installing Ruby and Bundler..."
  case "$PKG_MANAGER" in
    apt)
      pkg_install ruby-full
      ;;
    apk)
      pkg_install ruby ruby-dev
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel
      ;;
    zypper)
      pkg_install ruby ruby-devel
      ;;
  esac
  gem install --no-document bundler || true
  log "Ruby installed."
}

install_bundle_deps() {
  log "Installing Ruby bundle dependencies..."
  pushd "$PROJECT_ROOT" >/dev/null
  if has_file "Gemfile"; then
    bundle config set path 'vendor/bundle'
    bundle install --jobs "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" --retry 3
  else
    warn "Gemfile not found; skipping bundle install."
  fi
  popd >/dev/null
  log "Ruby dependencies installed."
}

configure_ruby_env() {
  log "Configuring Ruby environment..."
  echo "export RACK_ENV=\${RACK_ENV:-production}" >> /etc/profile.d/project_env.sh
  echo "export RAILS_ENV=\${RAILS_ENV:-production}" >> /etc/profile.d/project_env.sh
  echo "export PORT=\${PORT:-3000}" >> /etc/profile.d/project_env.sh
  log "Ruby environment configured (PORT=3000)."
}

#-----------------------------#
# Go setup                    #
#-----------------------------#
install_go_runtime() {
  log "Installing Go runtime..."
  case "$PKG_MANAGER" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac
  go version || warn "Go installation verification failed."
  log "Go installed."
}

prepare_go_deps() {
  log "Preparing Go dependencies..."
  pushd "$PROJECT_ROOT" >/dev/null
  if has_file "go.mod"; then
    go mod download
  else
    warn "go.mod not found; skipping go mod download."
  fi
  popd >/dev/null
  echo "export GOPATH=\${GOPATH:-/go}" >> /etc/profile.d/project_env.sh
  echo 'export PATH="$GOPATH/bin:$PATH"' >> /etc/profile.d/project_env.sh
  echo "export PORT=\${PORT:-8080}" >> /etc/profile.d/project_env.sh
  log "Go dependencies prepared."
}

#-----------------------------#
# Java (Maven/Gradle) setup   #
#-----------------------------#
install_java_tooling() {
  log "Installing Java runtime and build tools..."
  case "$PKG_MANAGER" in
    apt) pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17 maven ;;
    dnf|yum) pkg_install java-17-openjdk java-17-openjdk-devel maven ;;
    zypper) pkg_install java-17-openjdk java-17-openjdk-devel maven ;;
  esac
  java -version || warn "Java installation verification failed."
  mvn -v || warn "Maven installation verification failed."
  log "Java tools installed."
}

prepare_java_deps() {
  log "Preparing Java dependencies..."
  pushd "$PROJECT_ROOT" >/dev/null
  if has_file "pom.xml"; then
    mvn -B -DskipTests dependency:go-offline || true
  elif has_any "gradlew" "build.gradle" "settings.gradle"; then
    if has_file "gradlew"; then
      chmod +x gradlew
      ./gradlew --no-daemon build -x test || ./gradlew --no-daemon tasks || true
    else
      case "$PKG_MANAGER" in
        apt) pkg_install gradle || true ;;
        apk) pkg_install gradle || true ;;
        dnf|yum) pkg_install gradle || true ;;
        zypper) pkg_install gradle || true ;;
      esac
      command -v gradle >/dev/null 2>&1 && gradle build -x test || true
    fi
  else
    warn "No Maven or Gradle build files found."
  fi
  popd >/dev/null
  echo "export PORT=\${PORT:-8080}" >> /etc/profile.d/project_env.sh
  log "Java dependencies prepared."
}

#-----------------------------#
# PHP setup                   #
#-----------------------------#
install_php_and_composer() {
  log "Installing PHP and Composer..."
  case "$PKG_MANAGER" in
    apt)
      pkg_install php-cli php-zip php-mbstring php-xml unzip curl
      ;;
    apk)
      pkg_install php81 php81-cli php81-phar php81-zip php81-mbstring php81-xml unzip curl || pkg_install php php-cli php-phar php-zip php-mbstring php-xml unzip curl
      ;;
    dnf|yum)
      pkg_install php-cli php-zip php-mbstring php-xml unzip curl
      ;;
    zypper)
      pkg_install php7 php7-cli php7-zip php7-mbstring php7-xml unzip curl || pkg_install php8 php8-cli php8-zip php8-mbstring php8-xml unzip curl
      ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
      && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
      && rm composer-setup.php || warn "Composer installation failed."
  fi
  composer --version >/dev/null 2>&1 || warn "Composer not available."
  log "PHP and Composer installation complete."
}

prepare_php_deps() {
  log "Preparing PHP dependencies with Composer..."
  pushd "$PROJECT_ROOT" >/dev/null
  if has_file "composer.json"; then
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress --no-dev || true
  else
    warn "composer.json not found; skipping."
  fi
  popd >/dev/null
  echo "export PORT=\${PORT:-9000}" >> /etc/profile.d/project_env.sh
  log "PHP dependencies prepared."
}

#-----------------------------#
# .NET setup                  #
#-----------------------------#
install_dotnet() {
  log "Installing .NET SDK (LTS via dotnet-install script)..."
  local install_dir="/root/.dotnet"
  mkdir -p "$install_dir"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --install-dir "$install_dir" --channel LTS || warn ".NET installation encountered issues."
  rm -f /tmp/dotnet-install.sh
  "$install_dir/dotnet" --info || warn ".NET SDK verification failed."
  echo "export DOTNET_ROOT=$install_dir" >> /etc/profile.d/project_env.sh
  echo 'export PATH="$DOTNET_ROOT:$DOTNET_ROOT/tools:$PATH"' >> /etc/profile.d/project_env.sh
  log ".NET installed."
}

restore_dotnet_deps() {
  log "Restoring .NET dependencies..."
  pushd "$PROJECT_ROOT" >/dev/null
  local dotnet_bin="/root/.dotnet/dotnet"
  if compgen -G "*.sln" >/dev/null || compgen -G "*.csproj" >/dev/null; then
    "$dotnet_bin" restore || warn "dotnet restore failed."
  else
    warn "No .NET solution or project files found."
  fi
  popd >/dev/null
  echo "export ASPNETCORE_URLS=\${ASPNETCORE_URLS:-http://0.0.0.0:${PORT:-8080}}" >> /etc/profile.d/project_env.sh
  log ".NET dependencies restored."
}

#-----------------------------#
# Rust setup                  #
#-----------------------------#
install_rust() {
  log "Installing Rust toolchain via distro packages..."
  case "$PKG_MANAGER" in
    apt) pkg_install rustc cargo ;;
    apk) pkg_install rust cargo ;;
    dnf|yum) pkg_install rust cargo ;;
    zypper) pkg_install rust cargo ;;
  esac
  rustc --version || warn "rustc not found."
  cargo --version || warn "cargo not found."
  log "Rust installed."
}

prepare_rust_deps() {
  log "Preparing Rust dependencies..."
  pushd "$PROJECT_ROOT" >/dev/null
  if has_file "Cargo.toml"; then
    cargo fetch || true
  else
    warn "Cargo.toml not found; skipping cargo fetch."
  fi
  popd >/dev/null
  echo "export PORT=\${PORT:-8080}" >> /etc/profile.d/project_env.sh
  log "Rust dependencies prepared."
}

#-----------------------------#
# Project detection           #
#-----------------------------#
detect_and_setup_project() {
  local handled="no"

  if has_file "package.json"; then
    handled="yes"
    log "Detected Node.js project."
    install_node_runtime
    install_node_dependencies
    configure_node_env
  fi

  if has_any "requirements.txt" "pyproject.toml" "Pipfile"; then
    handled="yes"
    log "Detected Python project."
    install_python_runtime
    setup_python_venv_and_deps
    configure_python_env
  fi

  if has_file "Gemfile"; then
    handled="yes"
    log "Detected Ruby project."
    install_ruby_and_bundler
    install_bundle_deps
    configure_ruby_env
  fi

  if has_file "go.mod"; then
    handled="yes"
    log "Detected Go project."
    install_go_runtime
    prepare_go_deps
  fi

  if has_any "pom.xml" "build.gradle" "gradlew"; then
    handled="yes"
    log "Detected Java project."
    install_java_tooling
    prepare_java_deps
  fi

  if has_file "composer.json"; then
    handled="yes"
    log "Detected PHP project."
    install_php_and_composer
    prepare_php_deps
  fi

  # .NET: look for .sln or .csproj
  if compgen -G "$PROJECT_ROOT/*.sln" >/dev/null || compgen -G "$PROJECT_ROOT/*.csproj" >/dev/null; then
    handled="yes"
    log "Detected .NET project."
    install_dotnet
    restore_dotnet_deps
  fi

  if has_file "Cargo.toml"; then
    handled="yes"
    log "Detected Rust project."
    install_rust
    prepare_rust_deps
  fi

  if [[ "$handled" == "no" ]]; then
    warn "Could not detect project type. Installed base tools only."
    echo "export PORT=\${PORT:-$DEFAULT_PORT}" >> /etc/profile.d/project_env.sh
  fi
}

#-----------------------------#
# Final notes and idempotency #
#-----------------------------#
print_summary() {
  log "Setup complete."
  log "Summary:"
  echo "- Project root: $PROJECT_ROOT"
  echo "- App user: $APP_USER ($APP_UID:$APP_GID)"
  echo "- Environment profile: /etc/profile.d/project_env.sh"
  echo "- Common directories: logs/, tmp/, run/, data/"
  echo "- Re-run safe: Yes (idempotent installs where possible)"
  echo
  echo "To use the configured environment in this container:"
  echo "  source /etc/profile.d/project_env.sh"
  echo
}

#-----------------------------#
# Main                        #
#-----------------------------#
main() {
  log "Starting environment setup..."
  detect_pkg_manager
  install_base_system_tools
  ensure_app_user
  setup_directories
  install_profile_env
  detect_and_setup_project
  chown -R "$APP_UID":"$APP_GID" "$PROJECT_ROOT" || true
  print_summary
}

main "$@"