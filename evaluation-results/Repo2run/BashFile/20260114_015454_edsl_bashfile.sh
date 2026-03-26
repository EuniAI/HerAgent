#!/usr/bin/env bash
# Environment setup script for containerized projects
# This script auto-detects common tech stacks (Python, Node.js, Java, Go, Ruby, PHP, Rust)
# and installs the required runtimes, system packages, and dependencies.
# It is idempotent and safe to run multiple times inside Docker containers.

set -Eeuo pipefail

#--- Configurable defaults (can be overridden by env vars before running) ---
APP_HOME="${APP_HOME:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
ENVIRONMENT="${ENVIRONMENT:-production}"
PORT="${PORT:-3000}" # generic default if app uses PORT
PYTHON_VERSION_MIN="${PYTHON_VERSION_MIN:-3.8}" # minimum acceptable Python version
JAVA_VERSION="${JAVA_VERSION:-17}"              # default Java version for JDK
NODE_ENV="${NODE_ENV:-production}"
#----------------------------------------------------------------------------

# Globals set later
PKG_MANAGER=""
PM_UPDATE=""
PM_INSTALL=""
PM_GROUP="@development-tools"
SUDO="" # in containers we assume root; no sudo used

# Colors may not render in all environments; keep it simple
log()    { printf '[%(%Y-%m-%d %H:%M:%S)T] [INFO] %s\n' -1 "$*"; }
warn()   { printf '[%(%Y-%m-%d %H:%M:%S)T] [WARN] %s\n' -1 "$*" >&2; }
error()  { printf '[%(%Y-%m-%d %H:%M:%S)T] [ERROR] %s\n' -1 "$*" >&2; }

cleanup() { :; }
trap cleanup EXIT
on_error() {
  local code=$?
  error "Setup failed at line $BASH_LINENO with exit code $code"
  exit $code
}
trap on_error ERR

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "This script must run as root inside the container."
    exit 1
  fi
}

# Detect a package manager and define helper commands
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    PM_UPDATE="apt-get update -y"
    PM_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PM_UPDATE="apk update"
    PM_INSTALL="apk add --no-cache"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PM_UPDATE="dnf makecache -y"
    PM_INSTALL="dnf install -y"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PM_UPDATE="yum makecache -y"
    PM_INSTALL="yum install -y"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    PM_UPDATE="zypper refresh"
    PM_INSTALL="zypper install -y --no-recommends"
  else
    error "No supported package manager found (apt, apk, dnf, yum, zypper)."
    exit 1
  fi
  log "Using package manager: $PKG_MANAGER"
}

pm_update() {
  log "Updating package database..."
  eval "$PM_UPDATE"
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  if [ "$#" -eq 0 ]; then return 0; fi
  log "Installing packages: $*"
  # shellcheck disable=SC2086
  eval "$PM_INSTALL $*"
}

# Install base/utility packages and build tools
install_base_system_packages() {
  log "Installing base system packages and build tools..."
  case "$PKG_MANAGER" in
    apt)
      pm_update
      pm_install ca-certificates curl git unzip zip tar xz-utils gnupg locales
      pm_install build-essential pkg-config
      # Ensure locales (C.UTF-8) available
      if [ -f /etc/locale.gen ]; then
        sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
        locale-gen || true
      fi
      ;;
    apk)
      pm_update
      pm_install ca-certificates curl git unzip zip tar xz gnupg
      pm_install build-base pkgconfig
      update-ca-certificates || true
      ;;
    dnf|yum)
      pm_update
      pm_install ca-certificates curl git unzip zip tar xz gnupg2 which
      pm_install gcc gcc-c++ make pkgconfig
      ;;
    zypper)
      pm_update
      pm_install ca-certificates curl git unzip zip tar xz gzip gpg2 which
      pm_install gcc gcc-c++ make pkg-config
      ;;
  esac
}

# Create application user and directories, ensure permissions
setup_user_and_dirs() {
  log "Setting up application user and directories..."
  # Create group if missing
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if command -v groupadd >/dev/null 2>&1; then
      groupadd -f "$APP_GROUP"
    elif command -v addgroup >/dev/null 2>&1; then
      addgroup -S "$APP_GROUP" 2>/dev/null || addgroup "$APP_GROUP"
    fi
  fi

  # Create user if missing
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
      useradd -m -d "$APP_HOME" -g "$APP_GROUP" -s /bin/sh "$APP_USER"
    elif command -v adduser >/dev/null 2>&1; then
      adduser -S -G "$APP_GROUP" -h "$APP_HOME" "$APP_USER" 2>/dev/null || \
      adduser -D -G "$APP_GROUP" -h "$APP_HOME" "$APP_USER" 2>/dev/null || \
      adduser --ingroup "$APP_GROUP" --home "$APP_HOME" --shell /bin/sh --disabled-password --gecos "" "$APP_USER"
    fi
  fi

  mkdir -p "$APP_HOME"/{logs,tmp,.cache,.config,.local/bin}
  mkdir -p "$APP_HOME/.profile.d"
  chown -R "$APP_USER:$APP_GROUP" "$APP_HOME"
  chmod -R u+rwX,go-rwx "$APP_HOME"
}

# Save environment variables to a file to be sourced by shells and processes
setup_environment_files() {
  log "Configuring environment files..."
  local env_file="$APP_HOME/.env"
  local profile_snippet="$APP_HOME/.profile.d/10-app-env.sh"

  # .env (create if not exists, do not overwrite user customizations)
  if [ ! -f "$env_file" ]; then
    cat > "$env_file" <<EOF
# Application environment variables
ENVIRONMENT=${ENVIRONMENT}
NODE_ENV=${NODE_ENV}
PORT=${PORT}
APP_HOME=${APP_HOME}
PYTHONUNBUFFERED=1
PIP_DISABLE_PIP_VERSION_CHECK=1
PIP_NO_CACHE_DIR=1
# Add your custom variables below
# DATABASE_URL=
# SECRET_KEY=
EOF
    chown "$APP_USER:$APP_GROUP" "$env_file"
    chmod 0640 "$env_file"
  fi

  # Profile snippet to set PATHs and load .env for interactive shells
  cat > "$profile_snippet" <<'EOF'
# Auto-generated by setup script
set -a
if [ -f "$HOME/.env" ]; then
  . "$HOME/.env"
fi
set +a
# Python venv path
if [ -d "$HOME/.venv/bin" ]; then
  export VIRTUAL_ENV="$HOME/.venv"
  PATH="$HOME/.venv/bin:$PATH"
fi
# Local user bin and Node modules bin
PATH="$HOME/.local/bin:$PATH"
if [ -d "$HOME/node_modules/.bin" ]; then
  PATH="$HOME/node_modules/.bin:$PATH"
fi
export PATH
EOF
  chown "$APP_USER:$APP_GROUP" "$profile_snippet"
  chmod 0644 "$profile_snippet"
}

ensure_venv_auto_activation() {
  local bashrc="$APP_HOME/.bashrc"
  touch "$bashrc"
  chown "$APP_USER:$APP_GROUP" "$bashrc"
  chmod 0640 "$bashrc" || true
  if ! grep -q '10-app-env.sh' "$bashrc"; then
    cat >> "$bashrc" <<'EOF'
# Auto-load app environment and virtualenv
if [ -f "$HOME/.profile.d/10-app-env.sh" ]; then
  . "$HOME/.profile.d/10-app-env.sh"
fi
if [ -d "$HOME/.venv" ] && [ -f "$HOME/.venv/bin/activate" ]; then
  . "$HOME/.venv/bin/activate"
fi
EOF
  fi
}

file_exists() { [ -f "$1" ]; }
any_file_exists() {
  for f in "$@"; do
    [ -f "$f" ] && return 0
  done
  return 1
}

version_ge() {
  # Compare two versions: returns 0 if $1 >= $2
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

#-------------------- Language-specific installers --------------------------

install_python_stack() {
  if ! any_file_exists "$APP_HOME/requirements.txt" "$APP_HOME/pyproject.toml" "$APP_HOME/setup.py"; then
    return 0
  fi
  log "Detected Python project files"

  case "$PKG_MANAGER" in
    apt)
      pm_install python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      pm_install python3 py3-pip py3-virtualenv python3-dev musl-dev libffi-dev openssl-dev zlib-dev bzip2-dev xz-dev readline-dev sqlite-dev
      ;;
    dnf|yum)
      pm_install python3 python3-pip python3-devel
      ;;
    zypper)
      pm_install python3 python3-pip python3-devel
      ;;
  esac

  # Check version
  if command -v python3 >/dev/null 2>&1; then
    local pyv
    pyv="$(python3 -c 'import sys;print(".".join(map(str,sys.version_info[:2])))')"
    if ! version_ge "$pyv" "$PYTHON_VERSION_MIN"; then
      warn "Python $pyv < $PYTHON_VERSION_MIN. Consider upgrading base image."
    fi
  fi

  # Create venv idempotently
  if [ ! -d "$APP_HOME/.venv" ]; then
    log "Creating Python virtual environment at $APP_HOME/.venv"
    python3 -m venv "$APP_HOME/.venv"
    chown -R "$APP_USER:$APP_GROUP" "$APP_HOME/.venv"
  else
    log "Python virtual environment already exists"
  fi

  # Install dependencies
  log "Installing Python dependencies..."
  # shellcheck disable=SC1090
  source "$APP_HOME/.venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if file_exists "$APP_HOME/requirements.txt"; then
    pip install -r "$APP_HOME/requirements.txt"
  elif file_exists "$APP_HOME/pyproject.toml"; then
    # Try pip install . to resolve PEP 517 projects; fallback to installing dependencies via uv/poetry if present
    if grep -qi "\[project\]" "$APP_HOME/pyproject.toml" 2>/dev/null || grep -qi "\[tool.poetry\]" "$APP_HOME/pyproject.toml" 2>/dev/null; then
      pip install .
    fi
  elif file_exists "$APP_HOME/setup.py"; then
    pip install -e "$APP_HOME"
  fi

  deactivate || true
  log "Python setup complete"
}

install_node_stack() {
  if ! file_exists "$APP_HOME/package.json"; then
    return 0
  fi
  log "Detected Node.js project files"

  # Install Node.js + npm
  case "$PKG_MANAGER" in
    apt)
      pm_install nodejs npm
      ;;
    apk)
      pm_install nodejs npm
      ;;
    dnf|yum)
      # Try module first (skip failure)
      (dnf module enable -y nodejs:18 || true) 2>/dev/null || true
      pm_install nodejs npm || true
      ;;
    zypper)
      pm_install nodejs npm || true
      ;;
  esac

  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not available from base repos; attempting NodeSource (Debian/Ubuntu only)"
    if [ "$PKG_MANAGER" = "apt" ]; then
      curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
      pm_install nodejs
    fi
  fi

  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js installation failed; skipping Node dependency installation."
    return 0
  fi

  # Enable corepack if available (Yarn/PNPM)
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Install dependencies (prefer lockfile-based installs)
  su -s /bin/sh -c '
    set -Eeuo pipefail
    cd "$APP_HOME"
    if [ -f package-lock.json ]; then
      npm ci --omit=dev
    elif [ -f pnpm-lock.yaml ]; then
      if command -v pnpm >/dev/null 2>&1; then pnpm i --frozen-lockfile --prod; else npm install --omit=dev; fi
    elif [ -f yarn.lock ]; then
      if command -v yarn >/dev/null 2>&1; then yarn install --frozen-lockfile --production; else npm install --omit=dev; fi
    else
      npm install --omit=dev
    fi
  ' "$APP_USER"
  log "Node.js setup complete"
}

install_java_stack() {
  if ! any_file_exists "$APP_HOME/pom.xml" "$APP_HOME/build.gradle" "$APP_HOME/build.gradle.kts"; then
    return 0
  fi
  log "Detected Java project files"

  case "$PKG_MANAGER" in
    apt)
      pm_install "openjdk-${JAVA_VERSION}-jdk" maven gradle || pm_install "openjdk-${JAVA_VERSION}-jdk" maven || true
      ;;
    apk)
      pm_install "openjdk${JAVA_VERSION}-jdk" maven gradle || pm_install openjdk${JAVA_VERSION}-jre maven || true
      ;;
    dnf|yum)
      pm_install "java-${JAVA_VERSION}-openjdk-devel" maven gradle || pm_install "java-${JAVA_VERSION}-openjdk-devel" maven || true
      ;;
    zypper)
      pm_install "java-${JAVA_VERSION}-openjdk-devel" maven gradle || pm_install "java-${JAVA_VERSION}-openjdk-devel" maven || true
      ;;
  esac
  if command -v javac >/dev/null 2>&1; then
    log "Java installed: $(javac -version 2>&1)"
  else
    warn "Java installation may have failed; continuing."
    return 0
  fi

  # Attempt to cache dependencies
  if file_exists "$APP_HOME/pom.xml" && command -v mvn >/dev/null 2>&1; then
    su -s /bin/sh -c '
      set -Eeuo pipefail
      cd "$APP_HOME"
      mvn -q -DskipTests dependency:go-offline || true
    ' "$APP_USER"
  fi
  if any_file_exists "$APP_HOME/build.gradle" "$APP_HOME/build.gradle.kts" && command -v gradle >/dev/null 2>&1; then
    su -s /bin/sh -c '
      set -Eeuo pipefail
      cd "$APP_HOME"
      gradle --no-daemon -q dependencies || true
    ' "$APP_USER"
  fi
  log "Java setup complete"
}

install_go_stack() {
  if ! file_exists "$APP_HOME/go.mod"; then
    return 0
  fi
  log "Detected Go project files"
  case "$PKG_MANAGER" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    dnf|yum) pm_install golang ;;
    zypper) pm_install go ;;
  esac
  if command -v go >/dev/null 2>&1; then
    su -s /bin/sh -c '
      set -Eeuo pipefail
      cd "$APP_HOME"
      go env -w GOMODCACHE="$HOME/.cache/go-build" || true
      go mod download
    ' "$APP_USER"
  else
    warn "Go installation failed; skipping go mod download"
  fi
  log "Go setup complete"
}

install_ruby_stack() {
  if ! file_exists "$APP_HOME/Gemfile"; then
    return 0
  fi
  log "Detected Ruby project files"
  case "$PKG_MANAGER" in
    apt)
      pm_install ruby-full build-essential
      ;;
    apk)
      pm_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pm_install ruby ruby-devel make gcc gcc-c++ rubygems
      ;;
    zypper)
      pm_install ruby ruby-devel make gcc gcc-c++ rubygems
      ;;
  esac

  # Ensure bundler
  if ! command -v bundle >/dev/null 2>&1; then
    if command -v gem >/dev/null 2>&1; then
      gem install bundler --no-document
    else
      warn "Ruby installed but gem not found; skipping bundler install."
      return 0
    fi
  fi

  su -s /bin/sh -c '
    set -Eeuo pipefail
    cd "$APP_HOME"
    bundle config set --local deployment "true"
    bundle config set --local path "vendor/bundle"
    bundle install --jobs 4 --retry 3
  ' "$APP_USER"
  log "Ruby setup complete"
}

install_php_stack() {
  if ! file_exists "$APP_HOME/composer.json"; then
    return 0
  fi
  log "Detected PHP project files"
  case "$PKG_MANAGER" in
    apt)
      pm_install php-cli php-zip php-mbstring php-xml php-curl php-json unzip
      pm_install composer || true
      ;;
    apk)
      pm_install php php-cli php-phar php-zip php-mbstring php-xml php-openssl php-curl unzip
      pm_install composer || true
      ;;
    dnf|yum)
      pm_install php-cli php-zip php-mbstring php-xml php-curl unzip || true
      ;;
    zypper)
      pm_install php-cli php-zip php-mbstring php-xml php-curl unzip || true
      ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer from getcomposer.org"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
    rm -f composer-setup.php
  fi

  if command -v composer >/dev/null 2>&1; then
    su -s /bin/sh -c '
      set -Eeuo pipefail
      cd "$APP_HOME"
      composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader
    ' "$APP_USER"
  else
    warn "Composer could not be installed; skipping PHP dependency install."
  fi
  log "PHP setup complete"
}

install_rust_stack() {
  if ! file_exists "$APP_HOME/Cargo.toml"; then
    return 0
  fi
  log "Detected Rust project files"
  case "$PKG_MANAGER" in
    apt) pm_install rustc cargo ;;
    apk) pm_install rust cargo ;; # package names can vary
    dnf|yum) pm_install rust cargo ;;
    zypper) pm_install rust cargo ;;
  esac

  if command -v cargo >/dev/null 2>&1; then
    su -s /bin/sh -c '
      set -Eeuo pipefail
      cd "$APP_HOME"
      cargo fetch
    ' "$APP_USER"
  else
    warn "Rust toolchain installation failed; skipping cargo fetch"
  fi
  log "Rust setup complete"
}

#-------------------------- Project detection -------------------------------

detect_project_stacks() {
  # Returns a list of stacks found
  local stacks=()
  any_file_exists "$APP_HOME/requirements.txt" "$APP_HOME/pyproject.toml" "$APP_HOME/setup.py" && stacks+=("python")
  file_exists "$APP_HOME/package.json" && stacks+=("node")
  any_file_exists "$APP_HOME/pom.xml" "$APP_HOME/build.gradle" "$APP_HOME/build.gradle.kts" && stacks+=("java")
  file_exists "$APP_HOME/go.mod" && stacks+=("go")
  file_exists "$APP_HOME/Gemfile" && stacks+=("ruby")
  file_exists "$APP_HOME/composer.json" && stacks+=("php")
  file_exists "$APP_HOME/Cargo.toml" && stacks+=("rust")

  if [ "${#stacks[@]}" -eq 0 ]; then
    warn "No recognized project files found in $APP_HOME."
  else
    log "Detected stacks: ${stacks[*]}"
  fi
}

#----------------------------- Main flow ------------------------------------

ensure_bash_available() {
  if ! command -v bash >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y bash
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache bash
    elif command -v yum >/dev/null 2>&1; then
      yum install -y bash
    fi
  fi
}

setup_ci_build_assets() {
  cat > "./ci_build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile || pnpm install
    pnpm -s build || pnpm run build
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile || yarn install
    yarn build || yarn run build
  else
    npm ci || npm install
    npm run build
  fi
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew assemble
elif [ -f build.gradle ]; then
  gradle assemble
elif [ -f Cargo.toml ]; then
  cargo build --release
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip build
  python -m build
elif [ -f setup.py ]; then
  python -m pip install -e .
elif [ -f Makefile ]; then
  make build || make
else
  echo "No known build file found" >&2
  exit 2
fi
EOF
  chmod +x "./ci_build.sh"
  if [ ! -f Makefile ]; then
    cat > Makefile <<'EOF'
.PHONY: build
build:
	./ci_build.sh
EOF
  fi
}

setup_run_build_script() {
  rm -f run_build.sh
  cat <<\EOF > run_build.sh
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then pnpm install && pnpm -s build; elif command -v yarn >/dev/null 2>&1; then yarn install --frozen-lockfile && yarn build; elif command -v npm >/dev/null 2>&1; then npm ci && npm run build; else echo "Node.js package manager not found" >&2; exit 2; fi
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew && ./gradlew assemble
elif [ -f build.gradle ]; then
  gradle assemble
elif [ -f Cargo.toml ]; then
  cargo build --release
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip build && python -m build
elif [ -f setup.py ]; then
  python -m pip install -e .
elif [ -f Makefile ]; then
  make build || make
else
  echo "No known build file found"
  exit 2
fi
EOF
  chmod +x run_build.sh && ./run_build.sh
}

setup_and_run_build_or_package() {
  cat > build_or_package.sh <<EOF
#!/usr/bin/env bash
set -e
if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install || true
    pnpm -s build || pnpm run build || true
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile || yarn install
    yarn build || yarn run build || true
  elif command -v npm >/dev/null 2>&1; then
    npm ci || npm install
    npm run build || true
  else
    echo Node.js package manager not found
    exit 2
  fi
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew assemble
elif [ -f build.gradle ]; then
  gradle assemble
elif [ -f Cargo.toml ]; then
  cargo build --release
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip build
  python -m build
elif [ -f setup.py ]; then
  python -m pip install -e .
elif [ -f Makefile ]; then
  make build || make
else
  echo No known build file found
  exit 2
fi
EOF
  chmod +x build_or_package.sh
  bash ./build_or_package.sh
}

# New CI build integration per repair commands
setup_ci_build_sh_and_run() {
  mkdir -p .ci
  . /usr/share/bash-completion/bash_completion >/dev/null 2>&1 || true; true
  cat > .ci/build.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install && pnpm -s build
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile && yarn build
  else
    npm ci && npm run build
  fi
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew && ./gradlew assemble
elif [ -f build.gradle ]; then
  gradle assemble
elif [ -f Cargo.toml ]; then
  cargo build --release
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip build && python -m build
elif [ -f setup.py ]; then
  python -m pip install -e .
elif [ -f Makefile ]; then
  make build || make
else
  echo "No known build file found"
  exit 2
fi
EOF
  chmod +x .ci/build.sh
  bash .ci/build.sh
}

setup_build_runner_and_run() {
  cat > build_runner.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile || pnpm install
    pnpm -s build || pnpm run build || true
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile || yarn install
    yarn build || true
  elif command -v npm >/dev/null 2>&1; then
    npm ci || npm install
    npm run build || true
  else
    echo "Node.js package manager not found" >&2
    exit 2
  fi
elif [ -f pom.xml ]; then
  if command -v mvn >/dev/null 2>&1; then
    mvn -q -DskipTests package
  else
    echo "Maven not found" >&2
    exit 2
  fi
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew assemble
elif [ -f build.gradle ]; then
  if command -v gradle >/dev/null 2>&1; then
    gradle assemble
  else
    echo "Gradle not found" >&2
    exit 2
  fi
elif [ -f Cargo.toml ]; then
  if command -v cargo >/dev/null 2>&1; then
    cargo build --release
  else
    echo "Cargo not found" >&2
    exit 2
  fi
elif [ -f pyproject.toml ]; then
  if command -v python >/dev/null 2>&1; then
    python -m pip install -U pip build
    python -m build
  else
    echo "Python not found" >&2
    exit 2
  fi
elif [ -f setup.py ]; then
  if command -v python >/dev/null 2>&1; then
    python -m pip install -e .
  else
    echo "Python not found" >&2
    exit 2
  fi
elif [ -f Makefile ]; then
  make build || make
else
  echo "No known build file found"
  exit 2
fi
EOF
  chmod +x build_runner.sh
  ./build_runner.sh
}

setup_ci_build_heredoc_and_run() {
  cat > /tmp/auto_build.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile || pnpm install
    pnpm -s build || pnpm run build || true
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile || yarn install
    yarn build || yarn run build || true
  elif command -v npm >/dev/null 2>&1; then
    npm ci --no-audit --no-fund || npm install --no-audit --no-fund
    npm run -s build || npm run build || true
  else
    echo "Node.js package manager not found"
    exit 2
  fi
elif [ -f pom.xml ]; then
  if command -v mvn >/dev/null 2>&1; then
    mvn -q -DskipTests package
  else
    echo "Maven not found"
    exit 2
  fi
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew assemble
elif [ -f build.gradle ]; then
  if command -v gradle >/dev/null 2>&1; then
    gradle assemble
  else
    echo "Gradle not found"
    exit 2
  fi
elif [ -f Cargo.toml ]; then
  if command -v cargo >/dev/null 2>&1; then
    cargo build --release
  else
    echo "Cargo not found"
    exit 2
  fi
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip build
  python -m build
elif [ -f setup.py ]; then
  python -m pip install -e .
elif [ -f Makefile ]; then
  make build || make
else
  echo "No known build file found"
  exit 2
fi
EOF
  chmod +x /tmp/auto_build.sh
  bash /tmp/auto_build.sh
}

setup_build_detect_and_run() {
  printf "%s\n" "#!/usr/bin/env bash" "set -euo pipefail" "if [ -f package.json ]; then" "  if command -v pnpm >/dev/null 2>&1; then" "    pnpm install --frozen-lockfile || pnpm install" "    pnpm -s build || pnpm run build || true" "  elif command -v yarn >/dev/null 2>&1; then" "    yarn install --frozen-lockfile || yarn install" "    yarn build || yarn run build || true" "  elif command -v npm >/dev/null 2>&1; then" "    npm ci || npm install" "    npm run build || true" "  else" "    echo Node.js package manager not found >&2" "    exit 2" "  fi" "elif [ -f pom.xml ]; then" "  mvn -q -DskipTests package" "elif [ -f gradlew ]; then" "  chmod +x gradlew" "  ./gradlew assemble" "elif [ -f build.gradle ]; then" "  gradle assemble" "elif [ -f Cargo.toml ]; then" "  cargo build --release" "elif [ -f pyproject.toml ]; then" "  python -m pip install -U pip build" "  python -m build" "elif [ -f setup.py ]; then" "  python -m pip install -e ." "elif [ -f Makefile ]; then" "  make build || make" "else" "  echo No known build file found" "  exit 2" "fi" > build_detect.sh && chmod +x build_detect.sh && bash ./build_detect.sh
}

setup_ci_build_detect_sh_and_run() {
  mkdir -p .ci
  cat > .ci/build_detect.sh << "EOF"
#!/usr/bin/env sh
set -e
if [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile || pnpm install
    pnpm -s build || pnpm build
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile || yarn install
    yarn build
  elif command -v npm >/dev/null 2>&1; then
    npm ci || npm install
    npm run build
  else
    echo "Node.js package manager not found"
    exit 127
  fi
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x ./gradlew
  ./gradlew assemble
elif [ -f build.gradle ]; then
  gradle assemble
elif [ -f Cargo.toml ]; then
  cargo build --release
elif [ -f pyproject.toml ]; then
  python -m pip install -U pip build
  python -m build
elif [ -f setup.py ]; then
  python -m pip install -e .
elif [ -f Makefile ]; then
  make build || make
else
  echo "No known build file found"
  exit 2
fi
EOF
  chmod +x .ci/build_detect.sh
  .ci/build_detect.sh
}

main() {
  umask 0027
  require_root
  detect_pkg_manager
  ensure_bash_available
  install_base_system_packages
  setup_user_and_dirs
  setup_environment_files
  ensure_venv_auto_activation # auto-added-venv-activation

  # Ensure APP_HOME exists and owned by the app user
  if [ ! -d "$APP_HOME" ]; then
    mkdir -p "$APP_HOME"
    chown -R "$APP_USER:$APP_GROUP" "$APP_HOME"
  fi

  # Run installers for detected stacks (can coexist)
  install_python_stack
  install_node_stack
  install_java_stack
  install_go_stack
  install_ruby_stack
  install_php_stack
  install_rust_stack

  # Create CI build assets (script and Makefile target)
  setup_ci_build_assets
  setup_run_build_script
  setup_and_run_build_or_package
  setup_ci_build_sh_and_run
  setup_build_runner_and_run
  setup_ci_build_heredoc_and_run
  setup_ci_build_detect_sh_and_run

  # Permissions: do not change ownership of entire tree blindly if using bind mounts
  find "$APP_HOME" -maxdepth 1 -type d -exec chown "$APP_USER:$APP_GROUP" {} \; || true
  chown "$APP_USER:$APP_GROUP" "$APP_HOME"/.env 2>/dev/null || true

  # Final info
  log "Environment setup completed successfully."
  cat <<EOF
Notes:
- Application home: $APP_HOME
- App user: $APP_USER
- Environment file: $APP_HOME/.env
- To use the configured environment in an interactive shell:
    su - $APP_USER
    # .env and .profile.d are auto-loaded for interactive shells
- To run typical apps (examples, adjust for your project):
    Python:    su - $APP_USER -c 'source ~/.profile.d/10-app-env.sh && source ~/.venv/bin/activate && python app.py'
    Node.js:   su - $APP_USER -c 'node server.js'
    Java:      su - $APP_USER -c 'java -jar target/*.jar'
    Go:        su - $APP_USER -c './your-binary'
    Ruby:      su - $APP_USER -c 'bundle exec your_command'
    PHP:       su - $APP_USER -c 'php -S 0.0.0.0:$PORT -t public'
    Rust:      su - $APP_USER -c 'cargo run --release'
EOF
}

# Ensure APP_HOME exists before changing directory
mkdir -p "$APP_HOME"
cd "$APP_HOME" 2>/dev/null || true

main "$@"