#!/usr/bin/env bash
# Project Environment Setup Script for Docker Containers
# This script detects common project types (Node.js, Python, Go, PHP, Ruby) and installs
# runtimes, system packages, dependencies, and environment configuration in an idempotent way.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------
# Configuration (override via environment variables before running)
# ---------------------------
APP_DIR="${APP_DIR:-/app}"
ENVIRONMENT="${ENVIRONMENT:-production}"
PORT="${PORT:-8080}"
VENV_DIR="${VENV_DIR:-$APP_DIR/.venv}"
LOG_DIR="${LOG_DIR:-$APP_DIR/logs}"
DATA_DIR="${DATA_DIR:-$APP_DIR/data}"
TMP_DIR="${TMP_DIR:-$APP_DIR/tmp}"
CACHE_DIR="${CACHE_DIR:-$APP_DIR/.cache}"
SETUP_MARKER="${SETUP_MARKER:-$APP_DIR/.setup_done}"
DEBIAN_FRONTEND=noninteractive

# Optional UID/GID for ownership adjustments (typical for bind mounts)
USER_ID="${USER_ID:-}"
GROUP_ID="${GROUP_ID:-}"

# ---------------------------
# Logging / Utilities
# ---------------------------
NO_COLOR="${NO_COLOR:-}"
if [ -t 1 ] && [ -z "${NO_COLOR}" ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() { true; }
on_error() { err "Setup failed at line $1"; }
trap 'on_error $LINENO' ERR
trap cleanup EXIT

umask 022

# ---------------------------
# Detection Helpers
# ---------------------------
file_exists() { [ -f "$1" ]; }
dir_exists() { [ -d "$1" ]; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

is_debian_like() { cmd_exists apt-get; }
is_alpine() { cmd_exists apk; }
is_redhat_like() { cmd_exists dnf || cmd_exists yum; }
is_suse_like() { cmd_exists zypper; }

is_node_project() { file_exists "$APP_DIR/package.json"; }
is_python_project() { file_exists "$APP_DIR/requirements.txt" || file_exists "$APP_DIR/pyproject.toml" || file_exists "$APP_DIR/Pipfile" || file_exists "$APP_DIR/setup.py"; }
is_go_project() { file_exists "$APP_DIR/go.mod"; }
is_php_project() { file_exists "$APP_DIR/composer.json"; }
is_ruby_project() { file_exists "$APP_DIR/Gemfile"; }

has_yarn_lock() { file_exists "$APP_DIR/yarn.lock"; }
has_pnpm_lock() { file_exists "$APP_DIR/pnpm-lock.yaml" || file_exists "$APP_DIR/pnpm-lock.yml"; }
has_npm_lock() { file_exists "$APP_DIR/package-lock.json"; }
has_poetry() { grep -q "\[tool\.poetry\]" "$APP_DIR/pyproject.toml" 2>/dev/null || false; }

# ---------------------------
# Package Manager Wrapper
# ---------------------------
REFRESHED_PACKAGES="false"

pm_update() {
  if [ "$REFRESHED_PACKAGES" = "true" ]; then
    return 0
  fi
  if is_debian_like; then
    log "Updating apt package lists..."
    apt-get update -y
  elif is_alpine; then
    log "Refreshing apk indexes..."
    apk update
  elif is_redhat_like; then
    if cmd_exists dnf; then
      log "Refreshing dnf metadata..."
      dnf makecache -y || true
    else
      log "Refreshing yum metadata..."
      yum makecache -y || true
    fi
  elif is_suse_like; then
    log "Refreshing zypper repositories..."
    zypper refresh -f || true
  else
    warn "No supported package manager detected."
  fi
  REFRESHED_PACKAGES="true"
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  [ $# -gt 0 ] || return 0
  pm_update
  if is_debian_like; then
    apt-get install -y --no-install-recommends "$@"
  elif is_alpine; then
    apk add --no-cache "$@"
  elif is_redhat_like; then
    if cmd_exists dnf; then
      dnf install -y "$@"
    else
      yum install -y "$@"
    fi
  elif is_suse_like; then
    zypper --non-interactive install -y "$@"
  else
    err "Cannot install packages: unsupported distribution."
    return 1
  fi
}

# ---------------------------
# System Dependencies
# ---------------------------
install_base_tools() {
  log "Installing base system packages..."
  if is_debian_like; then
    pm_install ca-certificates curl git openssl wget gnupg xz-utils \
               build-essential pkg-config tzdata locales
    # optional but useful
    pm_install nano less unzip
    update-ca-certificates || true
  elif is_alpine; then
    pm_install ca-certificates curl git openssl wget xz \
               build-base pkgconfig tzdata bash shadow \
               nano less unzip
    update-ca-certificates || true
  elif is_redhat_like; then
    pm_install ca-certificates curl git openssl wget xz \
               gcc gcc-c++ make pkgconfig tzdata glibc-langpack-en
  elif is_suse_like; then
    pm_install ca-certificates curl git openssl wget xz \
               gcc gcc-c++ make pkg-config timezone
  else
    warn "Unknown base image: skipping base tools installation."
  fi
}

# ---------------------------
# Language Runtimes Installers
# ---------------------------
install_python_runtime() {
  if cmd_exists python3 && cmd_exists pip3; then
    log "Python3 and pip3 already present."
    return 0
  fi
  log "Installing Python runtime..."
  if is_debian_like; then
    pm_install python3 python3-pip python3-venv python3-dev
  elif is_alpine; then
    pm_install python3 py3-pip python3-dev
    # venv is bundled in python3 in alpine 3.12+
    pm_install musl-dev || true
  elif is_redhat_like; then
    pm_install python3 python3-pip python3-virtualenv python3-devel
  elif is_suse_like; then
    pm_install python3 python3-pip python3-devel
  else
    err "Cannot install Python: unsupported distribution."
    return 1
  fi
}

install_node_runtime() {
  if cmd_exists node && cmd_exists npm; then
    log "Node.js and npm already present."
    return 0
  fi
  log "Installing Node.js runtime..."
  if is_debian_like; then
    pm_install nodejs npm
  elif is_alpine; then
    pm_install nodejs npm
  elif is_redhat_like; then
    pm_install nodejs npm || {
      warn "Native nodejs/npm packages unavailable; attempting alternatives not implemented."
    }
  elif is_suse_like; then
    pm_install nodejs npm
  else
    err "Cannot install Node.js: unsupported distribution."
    return 1
  fi
}

install_go_runtime() {
  if cmd_exists go; then
    log "Go runtime already present."
    return 0
  fi
  log "Installing Go runtime..."
  if is_debian_like; then
    pm_install golang
  elif is_alpine; then
    pm_install go
  elif is_redhat_like; then
    pm_install golang
  elif is_suse_like; then
    pm_install go
  else
    err "Cannot install Go: unsupported distribution."
    return 1
  fi
}

install_php_runtime() {
  if cmd_exists php; then
    log "PHP already present."
  else
    log "Installing PHP CLI..."
    if is_debian_like; then
      pm_install php-cli php-zip php-curl php-mbstring php-xml unzip
    elif is_alpine; then
      pm_install php81 php81-cli php81-phar php81-mbstring php81-xml php81-curl php81-zip unzip || pm_install php php-cli php-phar php-mbstring php-xml php-curl php-zip unzip
    elif is_redhat_like; then
      pm_install php-cli php-zip php-mbstring php-xml php-curl unzip || pm_install php
    elif is_suse_like; then
      pm_install php-cli php7-zip php7-mbstring php7-xml php7-curl unzip || pm_install php
    else
      err "Cannot install PHP: unsupported distribution."
      return 1
    fi
  fi

  if cmd_exists composer; then
    log "Composer already present."
    return 0
  fi
  log "Installing Composer..."
  tmp_inst="$(mktemp -d)"
  (
    cd "$tmp_inst"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    EXPECTED_SIG="$(curl -fsSL https://composer.github.io/installer.sig)"
    ACTUAL_SIG="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_SIG" != "$ACTUAL_SIG" ]; then
      rm -f composer-setup.php
      err "Invalid Composer installer signature."
      exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  )
  rm -rf "$tmp_inst"
  log "Composer installed."
}

install_ruby_runtime() {
  if cmd_exists ruby && cmd_exists gem; then
    log "Ruby already present."
  else
    log "Installing Ruby..."
    if is_debian_like; then
      pm_install ruby-full build-essential
    elif is_alpine; then
      pm_install ruby ruby-dev build-base
    elif is_redhat_like; then
      pm_install ruby ruby-devel gcc make
    elif is_suse_like; then
      pm_install ruby ruby-devel gcc make
    else
      err "Cannot install Ruby: unsupported distribution."
      return 1
    fi
  fi
  if ! cmd_exists bundle; then
    log "Installing Bundler gem..."
    gem install bundler --no-document
  fi
}

# ---------------------------
# Project Directory Setup
# ---------------------------
setup_directories() {
  log "Setting up project directories at $APP_DIR..."
  mkdir -p "$APP_DIR" "$LOG_DIR" "$DATA_DIR" "$TMP_DIR" "$CACHE_DIR"
  chmod 755 "$APP_DIR" "$LOG_DIR" "$DATA_DIR" "$TMP_DIR" "$CACHE_DIR"

  # Adjust ownership if USER_ID/GROUP_ID provided
  if [ -n "${USER_ID}" ] && [ -n "${GROUP_ID}" ]; then
    log "Adjusting ownership to UID:GID ${USER_ID}:${GROUP_ID}..."
    chown -R "${USER_ID}:${GROUP_ID}" "$APP_DIR" || warn "Failed to chown $APP_DIR"
  fi
}

# ---------------------------
# Environment Variables and Configuration
# ---------------------------
write_env_file() {
  local env_file="$APP_DIR/.env"
  if [ ! -f "$env_file" ]; then
    log "Creating default .env file..."
    cat > "$env_file" <<EOF
ENVIRONMENT=${ENVIRONMENT}
PORT=${PORT}
APP_DIR=${APP_DIR}
LOG_DIR=${LOG_DIR}
DATA_DIR=${DATA_DIR}
TMP_DIR=${TMP_DIR}
EOF
    chmod 640 "$env_file" || true
  else
    log ".env already exists, not overwriting."
  fi

  local profile_file="$APP_DIR/env.sh"
  if [ ! -f "$profile_file" ]; then
    log "Creating environment profile at $profile_file..."
    cat > "$profile_file" <<'EOF'
# Source this file to load project environment variables and PATH adjustments
set -a
[ -f "$(dirname "$0")/.env" ] && . "$(dirname "$0")/.env"
set +a

# Python venv activation if present
if [ -d "$(dirname "$0")/.venv" ]; then
  export VIRTUAL_ENV="$(dirname "$0")/.venv"
  export PATH="$VIRTUAL_ENV/bin:$PATH"
fi

# Node.js local binaries
if [ -d "$(dirname "$0")/node_modules/.bin" ]; then
  export PATH="$(dirname "$0")/node_modules/.bin:$PATH"
fi
EOF
    chmod 640 "$profile_file" || true
  fi
}

# Auto-activate environment and virtualenv on shell start
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local env_activate_line="[ -f \"$APP_DIR/env.sh\" ] && . \"$APP_DIR/env.sh\""
  if [ -f "$APP_DIR/env.sh" ] && ! grep -qF "$env_activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate project environment on shell start" >> "$bashrc_file"
    echo "$env_activate_line" >> "$bashrc_file"
  fi

  # Auto-activate Python virtual environment if present
  local venv_activate_line="source \"$VENV_DIR/bin/activate\""
  if [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/activate" ] && ! grep -qF "$venv_activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$venv_activate_line" >> "$bashrc_file"
  fi
}

# ---------------------------
# CI Build Script Writer
# ---------------------------
write_ci_build_script() {
  local ci_script="$APP_DIR/ci-build.sh"
  cat > "$ci_script" <<\EOF
#!/usr/bin/env bash
set -euo pipefail

if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1 && [ -f pnpm-lock.yaml ]; then
    pnpm install --frozen-lockfile
    pnpm build
  elif command -v yarn >/dev/null 2>&1 && [ -f yarn.lock ]; then
    yarn install --frozen-lockfile
    yarn build
  else
    npm ci
    npm run -s build
  fi
elif [ -f pom.xml ]; then
  mvn -q -B -DskipTests package
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  ./gradlew -q assemble
elif [ -f Cargo.toml ]; then
  cargo build --locked --quiet
elif [ -f pyproject.toml ]; then
  if grep -F -q "[tool.poetry]" pyproject.toml 2>/dev/null; then
    poetry install --no-interaction --no-root
    poetry build
  else
    pip install -U pip
    pip install -e .
  fi
elif [ -f requirements.txt ]; then
  pip install -U pip
  pip install -r requirements.txt
elif [ -f go.mod ]; then
  go mod download
  go build ./...
elif ls *.sln >/dev/null 2>&1; then
  dotnet restore
  dotnet build -c Release
else
  echo "No recognized build manifest" >&2
  exit 1
fi
EOF
  chmod +x "$ci_script"
}

# ---------------------------
# Dependency Installation Per Project Type
# ---------------------------
setup_python_project() {
  log "Configuring Python project..."
  install_python_runtime

  if [ ! -d "$VENV_DIR" ]; then
    log "Creating Python virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
  else
    log "Python virtual environment already exists."
  fi

  # Activate venv in subshell for installation
  (
    set +u
    . "$VENV_DIR/bin/activate"
    python -m pip install --upgrade pip setuptools wheel
    if file_exists "$APP_DIR/requirements.txt"; then
      log "Installing Python dependencies from requirements.txt..."
      pip install -r "$APP_DIR/requirements.txt"
    elif file_exists "$APP_DIR/pyproject.toml"; then
      if has_poetry; then
        log "Detected Poetry configuration. Installing Poetry and dependencies..."
        pip install "poetry>=1.6.0"
        cd "$APP_DIR"
        poetry config virtualenvs.in-project true
        poetry install --no-interaction --no-ansi --no-root || poetry install --no-interaction --no-ansi
      else
        log "Installing project via pyproject.toml..."
        cd "$APP_DIR"
        pip install .
      fi
    elif file_exists "$APP_DIR/Pipfile"; then
      log "Detected Pipfile; installing pipenv and syncing..."
      pip install pipenv
      cd "$APP_DIR"
      PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
    elif file_exists "$APP_DIR/setup.py"; then
      log "Installing Python project via setup.py..."
      cd "$APP_DIR"
      pip install .
    else
      warn "No Python dependency file found."
    fi
  )
}

setup_node_project() {
  log "Configuring Node.js project..."
  install_node_runtime

  # Enable corepack if available (Node >=16) to support yarn/pnpm
  if cmd_exists corepack; then
    corepack enable || true
  fi

  # Install yarn/pnpm globally if needed
  if has_yarn_lock && ! cmd_exists yarn; then
    log "Installing yarn globally via npm..."
    npm install -g yarn
  fi

  if has_pnpm_lock && ! cmd_exists pnpm; then
    log "Installing pnpm globally via npm..."
    npm install -g pnpm
  fi

  # Install dependencies using the appropriate package manager
  (
    cd "$APP_DIR"
    if has_yarn_lock && cmd_exists yarn; then
      log "Installing Node.js dependencies using yarn..."
      yarn install --frozen-lockfile || yarn install
    elif has_pnpm_lock && cmd_exists pnpm; then
      log "Installing Node.js dependencies using pnpm..."
      pnpm install --frozen-lockfile || pnpm install
    elif has_npm_lock; then
      log "Installing Node.js dependencies using npm ci..."
      npm ci || npm install
    else
      log "Installing Node.js dependencies using npm..."
      npm install
    fi
  )
}

setup_go_project() {
  log "Configuring Go project..."
  install_go_runtime
  mkdir -p /go/pkg /go/bin /go/src
  if ! grep -q 'GOPATH' "$APP_DIR/env.sh" 2>/dev/null; then
    echo 'export GOPATH=/go' >> "$APP_DIR/env.sh"
    echo 'export PATH="$GOPATH/bin:$PATH"' >> "$APP_DIR/env.sh"
  fi
  (
    cd "$APP_DIR"
    if file_exists "$APP_DIR/go.mod"; then
      log "Downloading Go modules..."
      go mod download
    fi
  )
}

setup_php_project() {
  log "Configuring PHP project..."
  install_php_runtime
  (
    cd "$APP_DIR"
    if file_exists "$APP_DIR/composer.json"; then
      log "Installing PHP dependencies via Composer..."
      composer install --no-interaction --no-progress --prefer-dist
    else
      warn "composer.json not found."
    fi
  )
}

setup_ruby_project() {
  log "Configuring Ruby project..."
  install_ruby_runtime
  (
    cd "$APP_DIR"
    if file_exists "$APP_DIR/Gemfile"; then
      log "Installing Ruby gems via Bundler..."
      bundle config set --local path 'vendor/bundle'
      bundle install --jobs=4 --retry=3
    else
      warn "Gemfile not found."
    fi
  )
}

# ---------------------------
# Main
# ---------------------------
main() {
  log "Starting environment setup for project at $APP_DIR"

  setup_directories
  install_base_tools
  write_env_file
  setup_auto_activate
  write_ci_build_script
  mkdir -p "$APP_DIR" && touch "$APP_DIR/requirements.txt"

  # Detect project types and install dependencies
  local any_detected="false"

  if is_python_project; then
    any_detected="true"
    setup_python_project
  fi

  if is_node_project; then
    any_detected="true"
    setup_node_project
  fi

  if is_go_project; then
    any_detected="true"
    setup_go_project
  fi

  if is_php_project; then
    any_detected="true"
    setup_php_project
  fi

  if is_ruby_project; then
    any_detected="true"
    setup_ruby_project
  fi

  if [ "$any_detected" = "false" ]; then
    warn "No recognized project files found in $APP_DIR."
    warn "Supported types: Node.js (package.json), Python (requirements.txt/pyproject.toml), Go (go.mod), PHP (composer.json), Ruby (Gemfile)."
  fi

  if [ -x "$APP_DIR/ci-build.sh" ]; then
    log "Running CI build script..."
    (
      cd "$APP_DIR"
      bash ci-build.sh
    )
  fi

  # Finalize: permissions and marker
  if [ -n "${USER_ID}" ] && [ -n "${GROUP_ID}" ]; then
    chown -R "${USER_ID}:${GROUP_ID}" "$APP_DIR" || warn "Failed to adjust ownership post-setup."
  fi

  echo "ENVIRONMENT=$ENVIRONMENT" > "$APP_DIR/.runtime_env"
  echo "PORT=$PORT" >> "$APP_DIR/.runtime_env"

  if [ ! -f "$SETUP_MARKER" ]; then
    touch "$SETUP_MARKER"
  fi

  log "Environment setup completed successfully."
  log "To load environment in a shell: source \"$APP_DIR/env.sh\""
}

# Ensure APP_DIR exists; if the repository is mounted elsewhere, allow override via APP_DIR
mkdir -p "$APP_DIR"

main "$@"