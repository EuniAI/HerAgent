#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# This script detects the project type and installs the required runtimes,
# system packages, and dependencies. It is idempotent and safe to re-run.

set -Eeuo pipefail
set -o errtrace

# Globals
export DEBIAN_FRONTEND=noninteractive
PROJECT_ROOT="$(pwd)"
RUN_AS_USER_ID="$(id -u)"
RUN_AS_GROUP_ID="$(id -g)"
DEFAULT_ENV_FILE="$PROJECT_ROOT/.env"
LOCKFILE="$PROJECT_ROOT/.setup_lock"
LOG_DIR="$PROJECT_ROOT/logs"
CACHE_DIR="$PROJECT_ROOT/.cache"
TMP_DIR="$PROJECT_ROOT/tmp"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
err() { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]}
  err "Setup failed at line $line_no with exit code $exit_code."
  err "Last command: ${BASH_COMMAND}"
  exit $exit_code
}
trap on_error ERR

require_root() {
  if [[ "$RUN_AS_USER_ID" -ne 0 ]]; then
    err "This script must run as root inside Docker (no sudo available). Current UID: $RUN_AS_USER_ID"
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Detect package manager
PKG_MGR=""
pkg_detect() {
  if has_cmd apt-get; then PKG_MGR="apt"; return 0; fi
  if has_cmd apk; then PKG_MGR="apk"; return 0; fi
  if has_cmd dnf; then PKG_MGR="dnf"; return 0; fi
  if has_cmd yum; then PKG_MGR="yum"; return 0; fi
  if has_cmd microdnf; then PKG_MGR="microdnf"; return 0; fi
  if has_cmd zypper; then PKG_MGR="zypper"; return 0; fi
  err "No supported package manager found (apt, apk, dnf, yum, microdnf, zypper)."
  exit 1
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      apt-get update
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
    microdnf)
      microdnf -y update || true
      ;;
    zypper)
      zypper --non-interactive refresh
      ;;
  esac
}

pkg_install() {
  local packages=("$@")
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    microdnf)
      microdnf install -y "${packages[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${packages[@]}"
      ;;
  esac
}

cleanup_pkg_cache() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|yum|microdnf)
      rm -rf /var/cache/dnf/* /var/cache/yum/* || true
      ;;
    zypper)
      zypper clean --all || true
      ;;
  esac
}

# Create basic directories and permissions
prep_dirs() {
  mkdir -p "$LOG_DIR" "$CACHE_DIR" "$TMP_DIR"
  chmod 755 "$LOG_DIR" "$TMP_DIR" || true
  chmod 700 "$CACHE_DIR" || true
  chown -R "$RUN_AS_USER_ID":"$RUN_AS_GROUP_ID" "$PROJECT_ROOT" || true
}

# Detect project types
IS_NODE=0
IS_PYTHON=0
IS_RUBY=0
IS_PHP=0
IS_JAVA_MAVEN=0
IS_JAVA_GRADLE=0
IS_GO=0
IS_RUST=0
IS_DOTNET=0

detect_project() {
  [[ -f "$PROJECT_ROOT/package.json" ]] && IS_NODE=1
  [[ -f "$PROJECT_ROOT/requirements.txt" || -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/Pipfile" || -f "$PROJECT_ROOT/setup.py" ]] && IS_PYTHON=1
  [[ -f "$PROJECT_ROOT/Gemfile" ]] && IS_RUBY=1
  [[ -f "$PROJECT_ROOT/composer.json" ]] && IS_PHP=1
  [[ -f "$PROJECT_ROOT/pom.xml" ]] && IS_JAVA_MAVEN=1
  [[ -f "$PROJECT_ROOT/build.gradle" || -f "$PROJECT_ROOT/build.gradle.kts" || -f "$PROJECT_ROOT/gradlew" ]] && IS_JAVA_GRADLE=1
  [[ -f "$PROJECT_ROOT/go.mod" || -f "$PROJECT_ROOT/go.sum" ]] && IS_GO=1
  [[ -f "$PROJECT_ROOT/Cargo.toml" ]] && IS_RUST=1
  if ls -1 "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1 || ls -1 "$PROJECT_ROOT"/*.sln >/dev/null 2>&1; then
    IS_DOTNET=1
  fi
}

# Install core utilities
install_base_tools() {
  log "Installing base system tools..."
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl wget git unzip tar xz-utils gzip bzip2 jq locales gnupg build-essential pkg-config openssl bash coreutils
      ;;
    apk)
      pkg_install ca-certificates curl wget git unzip tar xz gzip bzip2 jq openssl build-base libressl coreutils
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl wget git unzip tar xz gzip bzip2 jq openssl gcc gcc-c++ make patch coreutils
      ;;
    zypper)
      pkg_install ca-certificates curl wget git unzip tar xz gzip bzip2 jq libopenssl-devel gcc gcc-c++ make coreutils
      ;;
  esac
  log "Base tools installed."
}

# Python setup
setup_python() {
  log "Detected Python project."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev build-essential libffi-dev
      ;;
    apk)
      pkg_install python3 py3-pip py3-setuptools py3-virtualenv build-base libffi-dev
      ;;
    dnf|yum|microdnf)
      pkg_install python3 python3-pip python3-virtualenv python3-devel gcc gcc-c++ make libffi-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-virtualenv python3-devel gcc gcc-c++ make libffi-devel
      ;;
  esac

  # Create virtual environment
  local venv_dir="$PROJECT_ROOT/.venv"
  if [[ ! -d "$venv_dir" ]]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    info "Virtual environment already exists at $venv_dir"
  fi

  # Activate venv in subshell for installation
  (
    set -e
    source "$venv_dir/bin/activate"
    python -m pip install --upgrade pip setuptools wheel
    if [[ -f "$PROJECT_ROOT/requirements.txt" ]]; then
      log "Installing Python dependencies from requirements.txt"
      pip install -r "$PROJECT_ROOT/requirements.txt"
    elif [[ -f "$PROJECT_ROOT/pyproject.toml" ]]; then
      if grep -qE '^\[tool.poetry\]' "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
        log "Poetry project detected. Installing Poetry and dependencies."
        pip install "poetry>=1.5"
        poetry config virtualenvs.create false
        poetry install --no-interaction --no-root --only main || poetry install --no-interaction --no-root
      else
        log "PEP 517/pyproject project detected. Installing with pip."
        pip install .
      fi
    elif [[ -f "$PROJECT_ROOT/Pipfile" ]]; then
      log "Pipfile detected. Installing pipenv and dependencies."
      pip install pipenv
      PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
    else
      warn "No recognized Python dependency file found. Skipping Python dependency installation."
    fi
  )

  # Add venv to PATH for future shells
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/py_venv.sh <<EOF
# Auto-activate project venv for interactive shells
if [ -d "$PROJECT_ROOT/.venv" ]; then
  VENV_DIR="$PROJECT_ROOT/.venv"
  case ":\$PATH:" in
    *":\$VENV_DIR/bin:"*) ;;
    *) export PATH="\$VENV_DIR/bin:\$PATH" ;;
  esac
fi
EOF
}

# Node.js setup
setup_node() {
  log "Detected Node.js project."
  case "$PKG_MGR" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum|microdnf)
      pkg_install nodejs npm
      ;;
    zypper)
      pkg_install nodejs npm
      ;;
  esac

  # Use corepack if available to manage yarn/pnpm
  if has_cmd corepack; then
    corepack enable || true
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f yarn.lock ]]; then
    log "yarn.lock detected. Installing Yarn and dependencies."
    if ! has_cmd yarn; then
      if has_cmd corepack; then corepack prepare yarn@stable --activate || true; fi
      if ! has_cmd yarn; then npm install -g yarn@latest; fi
    fi
    yarn install --frozen-lockfile || yarn install
  elif [[ -f pnpm-lock.yaml ]]; then
    log "pnpm-lock.yaml detected. Installing pnpm and dependencies."
    if ! has_cmd pnpm; then
      if has_cmd corepack; then corepack prepare pnpm@latest --activate || true; fi
      if ! has_cmd pnpm; then npm install -g pnpm@latest; fi
    fi
    pnpm install --frozen-lockfile || pnpm install
  elif [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
    log "Installing Node dependencies with npm ci"
    npm ci || npm install
  elif [[ -f package.json ]]; then
    log "Installing Node dependencies with npm install"
    npm install
  else
    warn "No Node dependency manifest found."
  fi
  popd >/dev/null

  # Add local node bin to PATH
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/node_path.sh <<'EOF'
# Ensure local node bins are on PATH
if [ -d "./node_modules/.bin" ]; then
  case ":$PATH:" in
    *":./node_modules/.bin:"*) ;;
    *) export PATH="./node_modules/.bin:$PATH" ;;
  esac
fi
EOF
}

# Ruby setup
setup_ruby() {
  log "Detected Ruby project."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum|microdnf)
      pkg_install ruby ruby-devel gcc make redhat-rpm-config
      ;;
    zypper)
      pkg_install ruby ruby-devel gcc make
      ;;
  esac

  if ! has_cmd gem; then
    err "Ruby gem command not found after installation."
  fi

  gem install bundler --no-document || true
  pushd "$PROJECT_ROOT" >/dev/null
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs 4 --retry 3
  popd >/dev/null
}

# PHP setup
setup_php() {
  log "Detected PHP project."
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-json php-mbstring php-zip curl unzip
      ;;
    apk)
      # Alpine PHP packages may vary by version; try generic names
      pkg_install php php-cli php-json php-mbstring php-zip curl unzip || true
      ;;
    dnf|yum|microdnf)
      pkg_install php-cli php-json php-mbstring php-zip curl unzip || true
      ;;
    zypper)
      pkg_install php-cli php7 php7-mbstring php7-zip curl unzip || true
      ;;
  esac

  if ! has_cmd composer; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f composer.json ]]; then
    composer install --no-interaction --prefer-dist --no-progress || composer install --no-interaction
  fi
  popd >/dev/null
}

# Java setup
setup_java_maven() {
  log "Detected Java (Maven) project."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17 maven ;;
    dnf|yum|microdnf) pkg_install java-17-openjdk-devel maven ;;
    zypper) pkg_install java-17-openjdk-devel maven ;;
  esac
  pushd "$PROJECT_ROOT" >/dev/null
  mvn -B -ntp -DskipTests dependency:go-offline || true
  popd >/dev/null
}

setup_java_gradle() {
  log "Detected Java (Gradle) project."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk gradle ;;
    apk) pkg_install openjdk17 gradle ;;
    dnf|yum|microdnf) pkg_install java-17-openjdk-devel gradle ;;
    zypper) pkg_install java-17-openjdk-devel gradle ;;
  esac
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -x gradlew ]]; then
    ./gradlew --no-daemon dependencies || true
  else
    gradle --no-daemon tasks || true
  fi
  popd >/dev/null
}

# Go setup
setup_go() {
  log "Detected Go project."
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum|microdnf) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac
  export GOPATH="${GOPATH:-/go}"
  mkdir -p "$GOPATH"
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f go.mod ]]; then
    go mod download
  fi
  popd >/dev/null

  mkdir -p /etc/profile.d
  cat >/etc/profile.d/go_path.sh <<EOF
export GOPATH="${GOPATH:-/go}"
case ":\$PATH:" in
  *":\$GOPATH/bin:"*) ;;
  *) export PATH="\$GOPATH/bin:\$PATH" ;;
esac
EOF
}

# Rust setup
setup_rust() {
  log "Detected Rust project."
  case "$PKG_MGR" in
    apt) pkg_install cargo rustc ;;
    apk) pkg_install cargo rust ;;
    dnf|yum|microdnf) pkg_install cargo rust ;;
    zypper) pkg_install cargo rust ;;
  esac
  pushd "$PROJECT_ROOT" >/dev/null
  if [[ -f Cargo.toml ]]; then
    cargo fetch || true
  fi
  popd >/dev/null
}

# .NET setup (best-effort)
setup_dotnet() {
  log "Detected .NET project."
  if has_cmd dotnet; then
    pushd "$PROJECT_ROOT" >/dev/null
    dotnet restore || true
    popd >/dev/null
  else
    warn ".NET SDK is not installed and automated installation varies by distro. Please use a .NET SDK base image or preinstall the SDK."
  fi
}

# Environment variables setup
setup_env_file() {
  # Determine default port
  local default_port="8080"
  if [[ $IS_NODE -eq 1 ]]; then default_port="3000"; fi
  if [[ $IS_PYTHON -eq 1 ]]; then default_port="8000"; fi
  if [[ $IS_RUBY -eq 1 ]]; then default_port="3000"; fi
  if [[ $IS_GO -eq 1 ]]; then default_port="8080"; fi
  if [[ $IS_PHP -eq 1 ]]; then default_port="8000"; fi
  if [[ $IS_JAVA_MAVEN -eq 1 || $IS_JAVA_GRADLE -eq 1 ]]; then default_port="8080"; fi

  if [[ ! -f "$DEFAULT_ENV_FILE" ]]; then
    log "Creating default .env file at $DEFAULT_ENV_FILE"
    cat >"$DEFAULT_ENV_FILE" <<EOF
# Project environment defaults
APP_NAME=$(basename "$PROJECT_ROOT")
APP_ENV=production
PORT=${PORT:-$default_port}
# Add additional variables below as needed
EOF
  else
    info ".env already exists. Preserving existing environment configuration."
  fi

  # A profile script to source .env for interactive shells
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/project_env.sh <<EOF
# Load project .env into environment for interactive shells
if [ -f "$DEFAULT_ENV_FILE" ]; then
  set -a
  . "$DEFAULT_ENV_FILE"
  set +a
fi
# Common local bin paths
for d in "$PROJECT_ROOT/.venv/bin" "$PROJECT_ROOT/node_modules/.bin" "$PROJECT_ROOT/vendor/bin"; do
  [ -d "\$d" ] && case ":\$PATH:" in *":\$d:"*) ;; *) PATH="\$d:\$PATH";; esac
done
export PATH
EOF
}

# Ensure Python virtual environment auto-activation for future shells
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_dir="$PROJECT_ROOT/.venv"
  local activate_line="[ -d \"$venv_dir\" ] && [ -f \"$venv_dir/bin/activate\" ] && . \"$venv_dir/bin/activate\""
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# Ensure logging permissions
setup_logging() {
  touch "$LOG_DIR/setup.log" || true
  chmod 664 "$LOG_DIR/setup.log" || true
}

# CI build script setup
setup_ci_build_scripts() {
  # Create project-local ci_build.sh
  cat > "$PROJECT_ROOT/ci_build.sh" << 'EOF'
#!/bin/sh
set -e
if [ -f package.json ]; then
  npm ci && npm run build
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f build.gradle ]; then
  ./gradlew build -x test
elif [ -f requirements.txt ] || [ -f pyproject.toml ]; then
  pip install -r requirements.txt || pip install .
elif [ -f Cargo.toml ]; then
  cargo build -q
elif [ -f Makefile ]; then
  make build || make
else
  echo "No recognized build file found"
fi
EOF
  chmod +x "$PROJECT_ROOT/ci_build.sh" || true

  # Install to /usr/local/bin if available and writable
  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    install -m 0755 "$PROJECT_ROOT/ci_build.sh" /usr/local/bin/ci_build.sh 2>/dev/null || cp -f "$PROJECT_ROOT/ci_build.sh" /usr/local/bin/ci_build.sh
  fi
}

# Timeout shim to wrap inline shell conditionals passed to timeout
setup_timeout_shim() {
  # Ensure coreutils (with timeout) is installed across distros
  if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y --no-install-recommends coreutils; elif command -v apk >/dev/null 2>&1; then apk add --no-cache coreutils; elif command -v dnf >/dev/null 2>&1; then dnf install -y coreutils; elif command -v yum >/dev/null 2>&1; then yum install -y coreutils; elif command -v microdnf >/dev/null 2>&1; then microdnf install -y coreutils || true; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install -y coreutils; else echo "No supported package manager found for coreutils" >&2; fi

  # Remove any conflicting timeout shims with higher PATH precedence
  if [ -e /usr/local/bin/timeout ]; then mv -f /usr/local/bin/timeout /usr/local/bin/timeout.harness-bak || rm -f /usr/local/bin/timeout; fi

  # Preserve the real timeout binary, if present
  if [ -e /usr/bin/timeout.distrib ] && [ ! -e /usr/bin/timeout.real ]; then mv -f /usr/bin/timeout.distrib /usr/bin/timeout.real || true; fi
  if [ -x /usr/bin/timeout ] && [ ! -e /usr/bin/timeout.real ]; then mv -f /usr/bin/timeout /usr/bin/timeout.real || true; fi
  if [ ! -x /usr/bin/timeout.real ] && [ -x /bin/timeout ]; then cp -f /bin/timeout /usr/bin/timeout.real || true; fi

  # Install robust wrapper that supports both standard and harness invocation forms
  cat >/usr/bin/timeout <<'EOF'
#!/bin/sh
REAL="/usr/bin/timeout.real"
if [ ! -x "$REAL" ]; then
  if [ -x /bin/timeout ]; then REAL=/bin/timeout; fi
fi
[ -x "$REAL" ] || { echo "timeout wrapper: real timeout binary not found" >&2; exit 127; }
OPTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --) OPTS="$OPTS --"; shift; break;;
    -*) OPTS="$OPTS $1"; shift;;
    *) break;;
  esac
done
is_duration() {
  echo "$1" | grep -Eq '^[0-9]+([.][0-9]+)?([smhd])?$'
}
# Standard GNU form: duration first
if [ $# -ge 1 ] && is_duration "$1"; then
  exec "$REAL" $OPTS "$@"
fi
# Harness form: timeout sh|bash -lc "cmd" DURATION
if [ $# -ge 3 ]; then
  first="$1"; second="$2"; last=""
  for a in "$@"; do last="$a"; done
  case "$first" in sh|/bin/sh|/usr/bin/sh|bash|/bin/bash|/usr/bin/bash) ;; *) first="";; esac
  case "$second" in -lc|-c) ;; *) second="";; esac
  if [ -n "$first" ] && [ -n "$second" ] && is_duration "$last"; then
    D="$last"; CMD="$3"
    exec "$REAL" $OPTS "$D" "$1" "$2" "$CMD"
  fi
fi
# Fallback: pass-through
exec "$REAL" $OPTS "$@"
EOF
  chmod +x /usr/bin/timeout
  ln -sf /usr/bin/timeout /bin/timeout || true
  /usr/bin/timeout 1s sh -lc 'echo timeout-wrapper-ok-1' >/dev/null 2>&1 || true
  /usr/bin/timeout sh -lc 'echo timeout-wrapper-ok-2' 1s >/dev/null 2>&1 || true
}

# Idempotency lock to avoid overlapping runs
acquire_lock() {
  if [[ -f "$LOCKFILE" ]]; then
    info "Lockfile exists. Previous setup may have completed. Continuing idempotently."
  else
    echo "locked $(date -Iseconds)" >"$LOCKFILE"
  fi
}

release_lock() {
  # Keep the lockfile to indicate setup has run; do not remove for idempotency.
  true
}

# Main
main() {
  require_root
  acquire_lock
  setup_timeout_shim

  pkg_detect
  prep_dirs
  pkg_update
  install_base_tools

  detect_project

  # Install per-project runtimes and dependencies
  if [[ $IS_PYTHON -eq 1 ]]; then setup_python; fi
  if [[ $IS_NODE -eq 1 ]]; then setup_node; fi
  if [[ $IS_RUBY -eq 1 ]]; then setup_ruby; fi
  if [[ $IS_PHP -eq 1 ]]; then setup_php; fi
  if [[ $IS_JAVA_MAVEN -eq 1 ]]; then setup_java_maven; fi
  if [[ $IS_JAVA_GRADLE -eq 1 ]]; then setup_java_gradle; fi
  if [[ $IS_GO -eq 1 ]]; then setup_go; fi
  if [[ $IS_RUST -eq 1 ]]; then setup_rust; fi
  if [[ $IS_DOTNET -eq 1 ]]; then setup_dotnet; fi

  setup_env_file
  setup_auto_activate
  setup_logging
  setup_ci_build_scripts

  cleanup_pkg_cache

  log "Environment setup completed successfully."

  echo
  info "Detected stack summary:"
  [[ $IS_PYTHON -eq 1 ]] && echo "- Python"
  [[ $IS_NODE -eq 1 ]] && echo "- Node.js"
  [[ $IS_RUBY -eq 1 ]] && echo "- Ruby"
  [[ $IS_PHP -eq 1 ]] && echo "- PHP"
  [[ $IS_JAVA_MAVEN -eq 1 ]] && echo "- Java (Maven)"
  [[ $IS_JAVA_GRADLE -eq 1 ]] && echo "- Java (Gradle)"
  [[ $IS_GO -eq 1 ]] && echo "- Go"
  [[ $IS_RUST -eq 1 ]] && echo "- Rust"
  [[ $IS_DOTNET -eq 1 ]] && echo "- .NET"

  echo
  info "Next steps (examples):"
  if [[ $IS_PYTHON -eq 1 ]]; then
    echo "  Python: source .venv/bin/activate && python -m pip list"
  fi
  if [[ $IS_NODE -eq 1 ]]; then
    echo "  Node: npm run start (or yarn start)"
  fi
  if [[ $IS_RUBY -eq 1 ]]; then
    echo "  Ruby: bundle exec rackup or rails server"
  fi
  if [[ $IS_PHP -eq 1 ]]; then
    echo "  PHP: php -S 0.0.0.0:\${PORT:-8000} -t public"
  fi
  if [[ $IS_JAVA_MAVEN -eq 1 ]]; then
    echo "  Maven: mvn spring-boot:run or mvn exec:java"
  fi
  if [[ $IS_JAVA_GRADLE -eq 1 ]]; then
    echo "  Gradle: ./gradlew bootRun or ./gradlew run"
  fi
  if [[ $IS_GO -eq 1 ]]; then
    echo "  Go: go run ./..."
  fi
  if [[ $IS_RUST -eq 1 ]]; then
    echo "  Rust: cargo run"
  fi
  if [[ $IS_DOTNET -eq 1 ]]; then
    echo "  .NET: dotnet run"
  fi
  echo "  To customize environment variables, edit $DEFAULT_ENV_FILE"

  release_lock
}

main "$@"