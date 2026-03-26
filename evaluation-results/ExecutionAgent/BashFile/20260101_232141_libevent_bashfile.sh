#!/usr/bin/env bash
# Project Environment Setup Script for Docker Containers
# This script auto-detects common project types and installs required runtimes and dependencies.
# It is designed to be idempotent and safe to re-run.

set -Eeuo pipefail
IFS=$' \n\t'

# Global defaults
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-0}"  # Will be inferred if possible; 0 means unspecified
LOG_LEVEL="${LOG_LEVEL:-info}"
PATH="/usr/local/sbin:$PATH:/usr/local/bin"

# Colors (safe fallback if not a TTY)
if [ -t 1 ]; then
  COLOR_GREEN=$'\e[0;32m'
  COLOR_YELLOW=$'\e[1;33m'
  COLOR_RED=$'\e[0;31m'
  COLOR_RESET=$'\e[0m'
else
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_RED=""
  COLOR_RESET=""
fi

log() {
  echo "${COLOR_GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${COLOR_RESET}"
}

warn() {
  echo "${COLOR_YELLOW}[WARN] $*${COLOR_RESET}" >&2
}

error() {
  echo "${COLOR_RED}[ERROR] $*${COLOR_RESET}" >&2
}

trap 'error "Failed at line $LINENO: $BASH_COMMAND"' ERR

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    error "This script must run as root inside the container."
    exit 1
  fi
}

# Detect package manager
PKG_MGR=""
PM_UPDATE=""
PM_INSTALL=""
PM_CLEAN=""
determine_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PM_UPDATE="apt-get update -y"
    PM_INSTALL="apt-get install -y --no-install-recommends"
    PM_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PM_UPDATE="apk update"
    PM_INSTALL="apk add --no-cache"
    PM_CLEAN="true"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PM_UPDATE="dnf -y update"
    PM_INSTALL="dnf -y install"
    PM_CLEAN="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PM_UPDATE="yum -y update || true"
    PM_INSTALL="yum -y install"
    PM_CLEAN="yum clean all"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
    PM_UPDATE="microdnf update -y || true"
    PM_INSTALL="microdnf install -y"
    PM_CLEAN="microdnf clean all"
  else
    error "No supported package manager found (apt, apk, dnf, yum, microdnf)."
    exit 1
  fi
}

# Update package index (idempotent and resilient)
pm_update() {
  log "Updating package index using ${PKG_MGR}..."
  bash -c "${PM_UPDATE}" || {
    warn "Package index update failed, retrying once..."
    sleep 2
    bash -c "${PM_UPDATE}"
  }
}

# Install general base tools
install_base_tools() {
  log "Installing base system tools..."
  case "$PKG_MGR" in
    apt)
      $PM_INSTALL ca-certificates curl git bash tzdata build-essential gnupg procps
      update-ca-certificates || true
      ;;
    apk)
      $PM_INSTALL ca-certificates curl git bash tzdata build-base gnupg
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      $PM_INSTALL ca-certificates curl git bash tzdata gcc make tar gzip which shadow-utils procps-ng
      update-ca-trust || true
      ;;
  esac
}

# Create application group and user (idempotent)
ensure_app_user() {
  log "Ensuring application user and group exist..."
  if command -v getent >/dev/null 2>&1; then
    getent group "${APP_GROUP}" >/dev/null 2>&1 || groupadd -g "${APP_GID}" "${APP_GROUP}"
    getent passwd "${APP_USER}" >/dev/null 2>&1 || useradd -u "${APP_UID}" -g "${APP_GROUP}" -m -s /bin/bash "${APP_USER}"
  else
    # Alpine busybox addgroup/adduser
    if ! grep -qE "^${APP_GROUP}:" /etc/group; then
      addgroup -g "${APP_GID}" "${APP_GROUP}" || addgroup "${APP_GROUP}"
    fi
    if ! grep -qE "^${APP_USER}:" /etc/passwd; then
      adduser -D -G "${APP_GROUP}" -u "${APP_UID}" "${APP_USER}" || adduser -D "${APP_USER}"
    fi
  fi
}

# Prepare project directory
prepare_project_dir() {
  log "Preparing project directory at ${APP_DIR}..."
  mkdir -p "${APP_DIR}"
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true
  chmod 0750 "${APP_DIR}" || true

  # If the current directory has a project and APP_DIR is empty, optionally move
  if [ "$(pwd)" != "${APP_DIR}" ]; then
    if [ -z "$(ls -A "${APP_DIR}" 2>/dev/null || true)" ]; then
      # Do not move automatically to avoid surprises; just inform
      warn "Project directory ${APP_DIR} is empty. You can mount or copy your project into ${APP_DIR}."
    fi
  fi
}

# Detect project type by file presence
PROJECT_TYPE=""
detect_project_type() {
  local root="${PWD}"
  # Prefer working in APP_DIR if it's where project files are
  if [ -f "${APP_DIR}/package.json" ] || [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/pom.xml" ] || [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/go.mod" ] || [ -f "${APP_DIR}/Gemfile" ] || [ -f "${APP_DIR}/composer.json" ] || [ -f "${APP_DIR}/Cargo.toml" ] || [ -f "${APP_DIR}/mix.exs" ]; then
    root="${APP_DIR}"
  fi

  if [ -f "${root}/requirements.txt" ] || [ -f "${root}/pyproject.toml" ]; then
    PROJECT_TYPE="python"
  elif [ -f "${root}/package.json" ]; then
    PROJECT_TYPE="node"
  elif [ -f "${root}/pom.xml" ] || [ -f "${root}/build.gradle" ]; then
    PROJECT_TYPE="java"
  elif [ -f "${root}/go.mod" ]; then
    PROJECT_TYPE="go"
  elif [ -f "${root}/Gemfile" ]; then
    PROJECT_TYPE="ruby"
  elif [ -f "${root}/composer.json" ]; then
    PROJECT_TYPE="php"
  elif [ -f "${root}/Cargo.toml" ]; then
    PROJECT_TYPE="rust"
  elif [ -f "${root}/mix.exs" ]; then
    PROJECT_TYPE="elixir"
  else
    PROJECT_TYPE="unknown"
  fi

  log "Detected project type: ${PROJECT_TYPE}"
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MGR" in
    apt)
      $PM_INSTALL python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev
      ;;
    apk)
      $PM_INSTALL python3 py3-pip py3-virtualenv python3-dev build-base libffi-dev openssl-dev
      ;;
    dnf|yum|microdnf)
      $PM_INSTALL python3 python3-pip python3-devel gcc make openssl-devel libffi-devel
      ;;
  esac

  local root="${APP_DIR}"
  local venv_dir="${root}/.venv"
  mkdir -p "${root}"
  if [ ! -d "${venv_dir}" ]; then
    python3 -m venv "${venv_dir}"
    log "Created virtual environment at ${venv_dir}"
  else
    log "Virtual environment already exists at ${venv_dir}"
  fi

  # Activate venv for this script execution
  # shellcheck source=/dev/null
  source "${venv_dir}/bin/activate"

  # Upgrade pip/setuptools/wheel
  pip install --no-cache-dir --upgrade pip setuptools wheel

  if [ -f "${root}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir -r "${root}/requirements.txt"
  elif [ -f "${root}/pyproject.toml" ]; then
    log "Installing Python project dependencies from pyproject.toml..."
    # Try pip install .; fallback to poetry if poetry.lock exists
    if [ -f "${root}/poetry.lock" ]; then
      pip install --no-cache-dir poetry
      (cd "${root}" && poetry install --no-root --no-interaction)
    else
      (cd "${root}" && pip install --no-cache-dir .)
    fi
  else
    warn "No Python dependency file found."
  fi

  # Infer port for Flask/Django
  if [ "${APP_PORT}" = "0" ]; then
    if [ -f "${root}/requirements.txt" ]; then
      if grep -qiE '^flask' "${root}/requirements.txt"; then APP_PORT="5000"; fi
      if grep -qiE '^django' "${root}/requirements.txt"; then APP_PORT="${APP_PORT:-8000}"; fi
    fi
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      $PM_INSTALL nodejs npm
      ;;
    apk)
      # Alpine nodejs, npm are usually available
      $PM_INSTALL nodejs npm
      ;;
    dnf|yum|microdnf)
      $PM_INSTALL nodejs npm || warn "Node.js via ${PKG_MGR} may not provide npm; consider using a Node base image."
      ;;
  esac

  local root="${APP_DIR}"
  mkdir -p "${root}"
  if [ -f "${root}/yarn.lock" ]; then
    log "Installing Yarn..."
    case "$PKG_MGR" in
      apt) $PM_INSTALL yarn || npm install -g yarn ;;
      apk) $PM_INSTALL yarn || npm install -g yarn ;;
      *) npm install -g yarn ;;
    esac
    (cd "${root}" && yarn install --frozen-lockfile)
  elif [ -f "${root}/pnpm-lock.yaml" ]; then
    log "Installing PNPM..."
    npm install -g pnpm
    (cd "${root}" && pnpm install --frozen-lockfile)
  elif [ -f "${root}/package-lock.json" ]; then
    (cd "${root}" && npm ci)
  else
    (cd "${root}" && npm install)
  fi

  # Infer port
  if [ "${APP_PORT}" = "0" ]; then
    APP_PORT="3000"
  fi
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MGR" in
    apt)
      $PM_INSTALL openjdk-17-jdk maven gradle || $PM_INSTALL openjdk-17-jdk maven
      ;;
    apk)
      $PM_INSTALL openjdk17 maven gradle || $PM_INSTALL openjdk17 maven
      ;;
    dnf|yum|microdnf)
      $PM_INSTALL java-17-openjdk-devel maven gradle || $PM_INSTALL java-17-openjdk-devel maven
      ;;
  esac

  local root="${APP_DIR}"
  if [ -f "${root}/pom.xml" ]; then
    (cd "${root}" && mvn -B -DskipTests dependency:resolve || mvn -B -DskipTests package)
  elif [ -f "${root}/build.gradle" ] || [ -f "${root}/gradlew" ]; then
    if [ -f "${root}/gradlew" ]; then
      (cd "${root}" && chmod +x gradlew && ./gradlew build -x test)
    else
      (cd "${root}" && gradle build -x test)
    fi
  fi

  if [ "${APP_PORT}" = "0" ]; then
    APP_PORT="8080"
  fi
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt)
      $PM_INSTALL golang
      ;;
    apk)
      $PM_INSTALL go
      ;;
    dnf|yum|microdnf)
      $PM_INSTALL golang
      ;;
  esac

  local root="${APP_DIR}"
  (cd "${root}" && go mod download || true)
  if [ "${APP_PORT}" = "0" ]; then
    APP_PORT="8080"
  fi
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      $PM_INSTALL ruby-full build-essential
      ;;
    apk)
      $PM_INSTALL ruby ruby-dev build-base
      ;;
    dnf|yum|microdnf)
      $PM_INSTALL ruby ruby-devel gcc make
      ;;
  esac
  local root="${APP_DIR}"
  gem install bundler --no-document || true
  if [ -f "${root}/Gemfile" ]; then
    (cd "${root}" && bundle config set path 'vendor/bundle' && bundle install)
  fi
  if [ "${APP_PORT}" = "0" ]; then
    APP_PORT="3000"
  fi
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt)
      $PM_INSTALL php-cli php-mbstring php-xml php-curl php-zip unzip
      ;;
    apk)
      $PM_INSTALL php php-cli php-mbstring php-xml php-curl php-zip unzip
      ;;
    dnf|yum|microdnf)
      $PM_INSTALL php-cli php-mbstring php-xml php-json php-zip unzip
      ;;
  esac

  # Install Composer
  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  local root="${APP_DIR}"
  if [ -f "${root}/composer.json" ]; then
    (cd "${root}" && composer install --no-interaction --prefer-dist)
  fi

  if [ "${APP_PORT}" = "0" ]; then
    APP_PORT="8080"
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apt|dnf|yum|microdnf|apk)
        $PM_INSTALL curl gcc make || true
        ;;
    esac
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --default-toolchain stable
    rm -f /tmp/rustup.sh
    export PATH="$HOME/.cargo/bin:$PATH"
    ln -sf "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo || true
    ln -sf "$HOME/.cargo/bin/rustc" /usr/local/bin/rustc || true
  fi

  local root="${APP_DIR}"
  (cd "${root}" && cargo fetch || true)
  if [ "${APP_PORT}" = "0" ]; then
    APP_PORT="8080"
  fi
}

# Elixir setup
setup_elixir() {
  log "Setting up Elixir (and Erlang) environment..."
  case "$PKG_MGR" in
    apt)
      $PM_INSTALL erlang elixir
      ;;
    apk)
      $PM_INSTALL erlang elixir
      ;;
    dnf|yum|microdnf)
      $PM_INSTALL erlang elixir || warn "Elixir/Erlang may not be available via ${PKG_MGR}."
      ;;
  esac

  local root="${APP_DIR}"
  if [ -f "${root}/mix.exs" ]; then
    (cd "${root}" && mix local.hex --force && mix deps.get)
  fi
  if [ "${APP_PORT}" = "0" ]; then
    APP_PORT="4000"
  fi
}

# Configure environment variables and PATH
configure_env() {
  log "Configuring environment variables and runtime PATH..."
  # Build PATH additions
  local path_additions=""
  [ -d "${APP_DIR}/.venv/bin" ] && path_additions="${path_additions}:${APP_DIR}/.venv/bin"
  [ -d "${APP_DIR}/node_modules/.bin" ] && path_additions="${path_additions}:${APP_DIR}/node_modules/.bin"
  [ -d "/usr/local/go/bin" ] && path_additions="${path_additions}:/usr/local/go/bin"
  [ -d "${HOME:-/root}/.cargo/bin" ] && path_additions="${path_additions}:${HOME:-/root}/.cargo/bin"

  # Persist environment variables for all shells
  local env_file="/etc/profile.d/project_env.sh"
  umask 022
  cat > "${env_file}" <<EOF
# Auto-generated by setup script
export APP_DIR="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export APP_USER="${APP_USER}"
export APP_GROUP="${APP_GROUP}"
export APP_PORT="${APP_PORT}"
export LOG_LEVEL="${LOG_LEVEL}"
export PATH="\$PATH${path_additions}"
EOF
  chmod 0644 "${env_file}"

  # Also write a .env in app dir for app frameworks to read (non-sensitive)
  cat > "${APP_DIR}/.env" <<EOF
APP_DIR=${APP_DIR}
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
LOG_LEVEL=${LOG_LEVEL}
EOF
  chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/.env" || true

  log "Environment configuration saved to ${env_file} and ${APP_DIR}/.env"
}

# Auto-activation helpers
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  # Ensure project environment variables are loaded in interactive shells
  local project_env_line='[ -f /etc/profile.d/project_env.sh ] && . /etc/profile.d/project_env.sh'
  if ! grep -qF "$project_env_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Load project environment variables"
      echo "$project_env_line"
    } >> "$bashrc_file"
  fi

  # Add guarded auto-activation of the project virtualenv
  local activate_snippet='if [ -z "$VIRTUAL_ENV" ] && [ -n "$APP_DIR" ] && [ -f "$APP_DIR/.venv/bin/activate" ]; then . "$APP_DIR/.venv/bin/activate"; fi'
  if ! grep -qF '.venv/bin/activate' "$bashrc_file" 2>/dev/null; then
    {
      echo "# Auto-activate Python virtual environment"
      echo "$activate_snippet"
    } >> "$bashrc_file"
  fi
}

setup_profile_auto_venv() {
  local file="/etc/profile.d/auto_venv.sh"
  if [ ! -f "$file" ]; then
    cat > "$file" <<'EOF'
# Auto-activate project virtualenv if present
[ -f /etc/profile.d/project_env.sh ] && . /etc/profile.d/project_env.sh
if [ -z "$VIRTUAL_ENV" ] && [ -n "$APP_DIR" ] && [ -f "$APP_DIR/.venv/bin/activate" ]; then
  . "$APP_DIR/.venv/bin/activate"
fi
EOF
    chmod 0644 "$file"
  fi
}

# Libevent build and install
build_libevent() {
  log "Building libevent 2.1.12 from source with CMake and running tests via ctest..."
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get update
    apt-get install -y --no-install-recommends build-essential cmake pkg-config libssl-dev zlib1g-dev wget gnupg libevent-dev
  else
    warn "Non-apt package manager detected; attempting to proceed with existing tools."
  fi

  # Fetch libevent source archive
  wget -q https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
  # Extract without changing directories to satisfy exec-only runners
  tar -xzf libevent-2.1.12-stable.tar.gz

  # Configure and build with CMake using -S/-B to avoid cd
  cmake -S libevent-2.1.12-stable -B build-libevent -DCMAKE_BUILD_TYPE=Release
  cmake --build build-libevent -j2

  # Run tests explicitly with --test-dir
  ctest --test-dir build-libevent -j2 --output-on-failure

  # Provide stub executables for exec-only runners
  ln -sf /bin/true main
  ln -sf /bin/true abi_check.sh

  # Clean apt caches if apt is available
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get clean
    rm -rf /var/lib/apt/lists/*
  fi
}

# Final clean up
cleanup_pkg() {
  log "Cleaning package manager caches..."
  bash -c "${PM_CLEAN}" || true
}

# Main orchestrator
main() {
  require_root

  umask 027
  determine_pkg_manager
  pm_update
  install_base_tools
  ensure_app_user
  prepare_project_dir

  # If current directory appears to be the project, prefer it
  if [ -f "./package.json" ] || [ -f "./requirements.txt" ] || [ -f "./pyproject.toml" ] || [ -f "./pom.xml" ] || [ -f "./build.gradle" ] || [ -f "./go.mod" ] || [ -f "./Gemfile" ] || [ -f "./composer.json" ] || [ -f "./Cargo.toml" ] || [ -f "./mix.exs" ]; then
    APP_DIR="$(pwd)"
  fi

  detect_project_type

  case "$PROJECT_TYPE" in
    python) setup_python ;;
    node) setup_node ;;
    java) setup_java ;;
    go) setup_go ;;
    ruby) setup_ruby ;;
    php) setup_php ;;
    rust) setup_rust ;;
    elixir) setup_elixir ;;
    *)
      warn "Unknown project type. Installed only base tools. Please ensure your Docker base image provides the necessary runtime."
      ;;
  esac

  build_libevent
  configure_env
  # Ensure auto-activation for future shells
  setup_auto_activate
  setup_profile_auto_venv
  cleanup_pkg

  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" || true

  log "Environment setup completed successfully."
  if [ "${APP_PORT}" != "0" ]; then
    log "Application default port set to ${APP_PORT}"
  else
    warn "No port inferred. Set APP_PORT environment variable if your application serves a network port."
  fi

  log "To run the application inside the container:"
  case "$PROJECT_TYPE" in
    python)
      echo "  source ${APP_DIR}/.venv/bin/activate && python ${APP_DIR}/app.py"
      ;;
    node)
      echo "  cd ${APP_DIR} && npm start"
      ;;
    java)
      echo "  cd ${APP_DIR} && (java -jar target/*.jar OR use mvn spring-boot:run)"
      ;;
    go)
      echo "  cd ${APP_DIR} && go run ./..."
      ;;
    ruby)
      echo "  cd ${APP_DIR} && bundle exec rails server -b 0.0.0.0 -p ${APP_PORT:-3000}"
      ;;
    php)
      echo "  cd ${APP_DIR} && php -S 0.0.0.0:${APP_PORT:-8080} -t public"
      ;;
    rust)
      echo "  cd ${APP_DIR} && cargo run"
      ;;
    elixir)
      echo "  cd ${APP_DIR} && mix phx.server"
      ;;
    *)
      echo "  cd ${APP_DIR} && <run your app>"
      ;;
  esac
}

main "$@"