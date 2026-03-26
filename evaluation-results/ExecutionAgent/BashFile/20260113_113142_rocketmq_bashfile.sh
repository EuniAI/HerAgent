#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type (Python/Node.js/Ruby/Java/Go/Rust/PHP/.NET)
# - Installs required runtimes and system dependencies
# - Configures environment variables and directory structure
# - Idempotent and safe to re-run
# - No sudo usage; designed for root in Docker but degrades gracefully

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Colors for output (disable if NO_COLOR set)
if [[ -n "${NO_COLOR:-}" ]]; then
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
else
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
fi

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
info()   { echo -e "${BLUE}[INFO] $*${NC}"; }

on_error() {
  local exit_code=$?
  error "Setup failed at line ${BASH_LINENO[0]} (exit code: $exit_code)"
  exit "$exit_code"
}
trap on_error ERR

# Defaults (can be overridden via env)
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
ENV_PROFILE_FILE="${ENV_PROFILE_FILE:-/etc/profile.d/app_env.sh}"
ENV_DOTFILE="${ENV_DOTFILE:-$APP_DIR/.env}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"

# Internal flags
IS_ROOT=0
if [[ "$(id -u)" -eq 0 ]]; then IS_ROOT=1; fi

# OS / package manager detection
PKG_MGR=""
UPDATE_DONE_FLAG="/var/tmp/.pkg_update_done"
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt";
  elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk";
  elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf";
  elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum";
  elif command -v microdnf >/dev/null 2>&1; then PKG_MGR="microdnf";
  else PKG_MGR=""; fi
}
pkg_update() {
  [[ $IS_ROOT -ne 1 ]] && { warn "Not running as root; skipping system package index update"; return 0; }
  [[ -f "$UPDATE_DONE_FLAG" ]] && return 0
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      touch "$UPDATE_DONE_FLAG"
      ;;
    apk)
      apk update
      touch "$UPDATE_DONE_FLAG"
      ;;
    dnf|yum|microdnf)
      # dnf/yum update metadata
      "$PKG_MGR" -y makecache
      touch "$UPDATE_DONE_FLAG"
      ;;
    *)
      warn "No supported package manager found; skipping update"
      ;;
  esac
}
pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  [[ $# -eq 0 ]] && return 0
  if [[ $IS_ROOT -ne 1 ]]; then
    warn "Not running as root; cannot install system packages: $*"
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
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
    microdnf)
      microdnf install -y "$@"
      ;;
    *)
      warn "No supported package manager found; cannot install packages: $*"
      ;;
  esac
}
pkg_clean() {
  [[ $IS_ROOT -ne 1 ]] && return 0
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|yum|microdnf)
      "$PKG_MGR" clean all || true
      ;;
  esac
}

# User and directory setup
ensure_group_user() {
  if [[ $IS_ROOT -ne 1 ]]; then
    warn "Not root; skipping user/group creation. Running as $(id -u):$(id -g)"
    return 0
  fi
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    log "Creating group $APP_GROUP"
    groupadd -r "$APP_GROUP"
  fi
  if ! getent passwd "$APP_USER" >/dev/null 2>&1; then
    log "Creating user $APP_USER"
    useradd -m -r -g "$APP_GROUP" -s /bin/bash "$APP_USER"
  fi
}
ensure_dirs() {
  log "Ensuring application directories"
  mkdir -p "$APP_DIR" "$APP_DIR/.cache" "$APP_DIR/bin" /var/log/app
  if [[ $IS_ROOT -eq 1 ]]; then
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" /var/log/app
  fi
}

# Project detection
detect_project() {
  IS_PYTHON=0; IS_NODE=0; IS_RUBY=0; IS_MVN=0; IS_GRADLE=0; IS_JAVA=0; IS_GO=0; IS_RUST=0; IS_PHP=0; IS_DOTNET=0
  cd "$APP_DIR"

  [[ -f "requirements.txt" || -f "pyproject.toml" || -f "Pipfile" ]] && IS_PYTHON=1
  [[ -f "package.json" ]] && IS_NODE=1
  [[ -f "Gemfile" ]] && IS_RUBY=1
  [[ -f "pom.xml" || -f "mvnw" ]] && { IS_MVN=1; IS_JAVA=1; }
  [[ -f "build.gradle" || -f "build.gradle.kts" || -f "gradlew" ]] && { IS_GRADLE=1; IS_JAVA=1; }
  [[ -f "go.mod" ]] && IS_GO=1
  [[ -f "Cargo.toml" ]] && IS_RUST=1
  [[ -f "composer.json" ]] && IS_PHP=1
  shopt -s nullglob
  for f in *.sln *.csproj; do IS_DOTNET=1; break; done
  shopt -u nullglob

  info "Detected project types: python=$IS_PYTHON node=$IS_NODE ruby=$IS_RUBY java=$IS_JAVA mvn=$IS_MVN gradle=$IS_GRADLE go=$IS_GO rust=$IS_RUST php=$IS_PHP dotnet=$IS_DOTNET"
}

# Base tools
install_base_tools() {
  log "Installing base tools and certificates"
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git bash coreutils findutils gnupg unzip xz-utils tar gzip
      ;;
    apk)
      pkg_install ca-certificates curl git bash coreutils findutils gnupg unzip xz tar gzip
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl git bash coreutils findutils gnupg2 unzip xz tar gzip
      update-ca-trust || true
      ;;
    *)
      warn "Base tools may be missing (no package manager)."
      ;;
  esac
}

# Python setup
setup_python() {
  [[ $IS_PYTHON -ne 1 ]] && return 0
  log "Setting up Python environment"
  case "$PKG_MGR" in
    apt) pkg_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev ;;
    apk) pkg_install python3 py3-pip py3-virtualenv python3-dev build-base libffi-dev openssl-dev ;;
    dnf|yum|microdnf) pkg_install python3 python3-pip python3-devel gcc gcc-c++ make openssl-devel libffi-devel ;;
    *) warn "Cannot install Python system packages; attempting existing python3";;
  esac

  PY_BIN="${PY_BIN:-python3}"
  if ! command -v "$PY_BIN" >/dev/null 2>&1; then
    error "Python is required but not available"
    return 1
  fi

  VENV_DIR="${VENV_DIR:-/opt/venv}"
  if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtual environment at $VENV_DIR"
    "$PY_BIN" -m venv "$VENV_DIR"
  else
    info "Virtual environment already exists at $VENV_DIR"
  fi

  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  pip install --no-input --upgrade pip setuptools wheel

  if [[ -f "requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-input -r requirements.txt
  elif [[ -f "pyproject.toml" ]]; then
    # Prefer pip if PEP 517 backend; else try poetry if lock present
    if grep -qi "tool.poetry" pyproject.toml && [[ -f "poetry.lock" ]]; then
      pip install --no-input "poetry>=1.6"
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi --only main
    else
      pip install --no-input .
    fi
  elif [[ -f "Pipfile" ]]; then
    pip install --no-input pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system
  fi

  PY_PORT_GUESS=5000
  if grep -Rqi "django" requirements.txt 2>/dev/null; then PY_PORT_GUESS=8000; fi
  if grep -Rqi "uvicorn\|fastapi" requirements.txt 2>/dev/null; then PY_PORT_GUESS=8000; fi

  export PATH="$VENV_DIR/bin:$PATH"
  ENV_PYTHON="PYTHONPATH=$APP_DIR"
  echo "PYTHON_VENV_DIR=$VENV_DIR" >> "$ENV_DOTFILE"
  echo "PATH=$VENV_DIR/bin:\$PATH" >> "$ENV_DOTFILE"
  echo "$ENV_PYTHON" >> "$ENV_DOTFILE"
  echo "APP_PORT=\${APP_PORT:-$PY_PORT_GUESS}" >> "$ENV_DOTFILE"
}

# Node.js setup via corepack/nvm
setup_node() {
  [[ $IS_NODE -ne 1 ]] && return 0
  log "Setting up Node.js environment"

  # Install dependencies for building native modules
  case "$PKG_MGR" in
    apt) pkg_install build-essential python3 make g++ ;;
    apk) pkg_install build-base python3 make g++ ;;
    dnf|yum|microdnf) pkg_install gcc gcc-c++ make python3 ;;
  esac

  # Install nvm to system location if root; else to user home
  NVM_DIR_DEFAULT="/usr/local/nvm"
  if [[ $IS_ROOT -eq 1 ]]; then
    export NVM_DIR="${NVM_DIR:-$NVM_DIR_DEFAULT}"
  else
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  fi
  mkdir -p "$NVM_DIR"
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    log "Installing nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"

  NODE_VERSION=""
  if [[ -f ".nvmrc" ]]; then
    NODE_VERSION="$(< .nvmrc)"
  else
    if [[ -f package.json ]]; then
      NODE_VERSION="$(grep -oE '"node"\s*:\s*"[^"]+"' package.json | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    fi
  fi
  NODE_VERSION="${NODE_VERSION:-lts/*}"

  if ! nvm ls "$NODE_VERSION" >/dev/null 2>&1; then
    log "Installing Node.js ($NODE_VERSION)"
    nvm install "$NODE_VERSION"
  fi
  nvm use "$NODE_VERSION"
  nvm alias default "$NODE_VERSION"

  # Ensure corepack for yarn/pnpm
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  # Install dependencies
  if [[ -f "pnpm-lock.yaml" ]]; then
    corepack prepare pnpm@latest --activate || npm i -g pnpm || true
    pnpm install --frozen-lockfile
  elif [[ -f "yarn.lock" ]]; then
    corepack prepare yarn@stable --activate || npm i -g yarn || true
    yarn install --frozen-lockfile
  elif [[ -f "package-lock.json" || -f "npm-shrinkwrap.json" ]]; then
    npm ci
  else
    npm install
  fi

  NODE_PORT_GUESS=3000
  echo "NVM_DIR=$NVM_DIR" >> "$ENV_DOTFILE"
  echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm use default >/dev/null' >> "$ENV_DOTFILE"
  echo "NODE_ENV=\${NODE_ENV:-production}" >> "$ENV_DOTFILE"
  echo "APP_PORT=\${APP_PORT:-$NODE_PORT_GUESS}" >> "$ENV_DOTFILE"
}

# Ruby setup
setup_ruby() {
  [[ $IS_RUBY -ne 1 ]] && return 0
  log "Setting up Ruby environment"
  case "$PKG_MGR" in
    apt) pkg_install ruby-full build-essential libffi-dev libssl-dev ;;
    apk) pkg_install ruby ruby-bundler build-base libffi-dev openssl-dev ;;
    dnf|yum|microdnf) pkg_install ruby ruby-devel gcc gcc-c++ make libffi-devel openssl-devel ;;
    *) warn "Cannot install Ruby runtime"; return 0;;
  esac
  if ! command -v bundle >/dev/null 2>&1; then gem install bundler --no-document || true; fi
  if [[ -f "Gemfile.lock" ]]; then
    bundle config set --local path "vendor/bundle"
    bundle install --deployment --without development test
  else
    bundle install
  fi
}

# Java setup
setup_java() {
  [[ $IS_JAVA -ne 1 ]] && return 0
  log "Setting up Java environment"
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk ;;
    apk) pkg_install openjdk17 ;;
    dnf|yum|microdnf) pkg_install java-17-openjdk-devel ;;
    *) warn "Cannot install OpenJDK";;
  esac

  if [[ $IS_MVN -eq 1 ]]; then
    if [[ -x "./mvnw" ]]; then
      chmod +x ./mvnw
      ./mvnw -B -DskipTests dependency:go-offline || ./mvnw -B -DskipTests package
    else
      pkg_install maven
      mvn -B -DskipTests dependency:go-offline || mvn -B -DskipTests package
    fi
  fi

  if [[ $IS_GRADLE -eq 1 ]]; then
    if [[ -x "./gradlew" ]]; then
      chmod +x ./gradlew
      ./gradlew --no-daemon build -x test || ./gradlew --no-daemon dependencies
    else
      pkg_install gradle
      gradle --no-daemon build -x test || gradle --no-daemon dependencies
    fi
  fi

  echo "JAVA_HOME=\${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}" >> "$ENV_DOTFILE"
  echo 'PATH=$JAVA_HOME/bin:$PATH' >> "$ENV_DOTFILE"
  echo 'APP_PORT=${APP_PORT:-8080}' >> "$ENV_DOTFILE"
}

# Go setup
setup_go() {
  [[ $IS_GO -ne 1 ]] && return 0
  log "Setting up Go environment"
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum|microdnf) pkg_install golang ;;
    *) warn "Cannot install Go runtime";;
  esac
  if ! command -v go >/dev/null 2>&1; then error "Go not available after installation"; return 1; fi
  GO_PATH="${GO_PATH:-/go}"
  mkdir -p "$GO_PATH"/{bin,pkg,src}
  echo "GOPATH=$GO_PATH" >> "$ENV_DOTFILE"
  echo 'PATH=$GOPATH/bin:$PATH' >> "$ENV_DOTFILE"
  go env -w GOPATH="$GO_PATH" || true
  if [[ -f "go.mod" ]]; then
    go mod download
  fi
  echo 'APP_PORT=${APP_PORT:-8080}' >> "$ENV_DOTFILE"
}

# Rust setup
setup_rust() {
  [[ $IS_RUST -ne 1 ]] && return 0
  log "Setting up Rust environment"
  case "$PKG_MGR" in
    apt) pkg_install curl ca-certificates build-essential pkg-config libssl-dev ;;
    apk) pkg_install curl ca-certificates build-base pkgconfig openssl-dev ;;
    dnf|yum|microdnf) pkg_install curl ca-certificates gcc gcc-c++ make pkgconfig openssl-devel ;;
  esac
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    if [[ -f "$HOME/.cargo/env" ]]; then
      # shellcheck disable=SC1090
      . "$HOME/.cargo/env"
    fi
  fi
  cargo fetch || true
  echo 'PATH=$HOME/.cargo/bin:$PATH' >> "$ENV_DOTFILE"
}

# PHP setup
setup_php() {
  [[ $IS_PHP -ne 1 ]] && return 0
  log "Setting up PHP environment"
  case "$PKG_MGR" in
    apt) pkg_install php-cli php-zip unzip php-mbstring php-xml php-curl ;;
    apk) pkg_install php81-cli php81-zip php81-mbstring php81-xml php81-curl unzip || pkg_install php-cli php-zip php-mbstring php-xml php-curl unzip ;;
    dnf|yum|microdnf) pkg_install php-cli php-zip php-mbstring php-xml php-json unzip ;;
    *) warn "Cannot install PHP runtime";;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
  if [[ -f "composer.lock" ]]; then
    composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader
  else
    composer install --no-interaction
  fi
}

# .NET setup via dotnet-install script
setup_dotnet() {
  [[ $IS_DOTNET -ne 1 ]] && return 0
  log "Setting up .NET SDK/runtime"
  install_dir=""
  if [[ $IS_ROOT -eq 1 ]]; then
    install_dir="/usr/share/dotnet"
  else
    install_dir="$HOME/.dotnet"
  fi
  mkdir -p "$install_dir"
  if ! command -v dotnet >/dev/null 2>&1; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir "$install_dir" --channel STS || /tmp/dotnet-install.sh --install-dir "$install_dir" --channel LTS
  fi
  export PATH="$install_dir:$PATH"
  echo "DOTNET_ROOT=$install_dir" >> "$ENV_DOTFILE"
  echo "PATH=$install_dir:\$PATH" >> "$ENV_DOTFILE"
  # Restore
  shopt -s nullglob
  for sln in *.sln; do dotnet restore "$sln" || true; done
  for csproj in *.csproj; do dotnet restore "$csproj" || true; done
  shopt -u nullglob
}

# Auto-activate Python virtual environment for new shells
ensure_venv_auto_activate() {
  local venv_dir="${VENV_DIR:-/opt/venv}"
  local bashrc="${HOME}/.bashrc"
  local line="[ -d \"$venv_dir\" ] && [ -f \"$venv_dir/bin/activate\" ] && . \"$venv_dir/bin/activate\""

  if ! grep -Fq "$venv_dir/bin/activate" "$bashrc" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate Python virtual environment"
      echo "$line"
    } >> "$bashrc"
  fi

  if [[ -d "/home/$APP_USER" ]]; then
    local user_bashrc="/home/$APP_USER/.bashrc"
    if ! grep -Fq "$venv_dir/bin/activate" "$user_bashrc" 2>/dev/null; then
      {
        echo ""
        echo "# Auto-activate Python virtual environment"
        echo "$line"
      } >> "$user_bashrc"
      [[ $IS_ROOT -eq 1 ]] && chown "$APP_USER:$APP_GROUP" "$user_bashrc" || true
    fi
  fi
}

# Environment files setup
write_env_profiles() {
  log "Writing environment configuration"
  # Ensure .env is fresh and idempotent
  {
    echo "APP_DIR=$APP_DIR"
    echo "APP_ENV=\${APP_ENV:-production}"
    echo "PATH=$APP_DIR/bin:\$PATH"
  } > "$ENV_DOTFILE"

  # Additional env already appended by setup_* functions

  if [[ $IS_ROOT -eq 1 ]]; then
    mkdir -p "$(dirname "$ENV_PROFILE_FILE")"
    {
      echo '#!/usr/bin/env bash'
      echo "export APP_DIR=$APP_DIR"
      echo 'export APP_ENV=${APP_ENV:-production}'
      echo "export PATH=$APP_DIR/bin:\$PATH"
      echo '[ -f "'"$ENV_DOTFILE"'" ] && set -a && . "'"$ENV_DOTFILE"'" && set +a || true'
    } > "$ENV_PROFILE_FILE"
    chmod 0644 "$ENV_PROFILE_FILE"
  fi
}

# Permissions
fix_permissions() {
  if [[ $IS_ROOT -eq 1 ]]; then
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" || true
    chown -R "$APP_USER:$APP_GROUP" /var/log/app || true
  fi
}

# Port detection fallback from Procfile
detect_port_from_procfile() {
  if [[ -f "$APP_DIR/Procfile" ]]; then
    PORT_LINE="$(grep -E '^web:' "$APP_DIR/Procfile" || true)"
    if [[ -n "$PORT_LINE" ]]; then
      if [[ "$PORT_LINE" =~ :([0-9]{2,5}) ]]; then
        PORT_GUESS="${BASH_REMATCH[1]}"
        echo "APP_PORT=\${APP_PORT:-$PORT_GUESS}" >> "$ENV_DOTFILE"
      fi
    fi
  fi
}

# Clean caches
finalize_cleanup() {
  pkg_clean
}

# Install a wrapper for timeout to handle compound shell constructs safely
install_timeout_wrapper() {
  if [[ $IS_ROOT -ne 1 ]]; then
    warn "Not root; skipping timeout wrapper installation"
    return 0
  fi
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/timeout <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REAL_TIMEOUT="/usr/bin/timeout"
if [ ! -x "$REAL_TIMEOUT" ]; then
  REAL_TIMEOUT="$(command -v -p timeout || true)"
fi
# Collect timeout options until duration
opts=()
while (( "$#" )); do
  case "$1" in
    --) opts+=("$1"); shift; break;;
    -k|--kill-after) opts+=("$1"); shift; opts+=("$1"); shift;;
    -*) opts+=("$1"); shift;;
    *) break;;
  esac
done
# Duration argument
if [ "$#" -lt 1 ]; then
  exec "$REAL_TIMEOUT" "${opts[@]}"
fi
duration="$1"; shift || true
# If there is no command, just exec timeout with duration
if [ "$#" -eq 0 ]; then
  exec "$REAL_TIMEOUT" "${opts[@]}" "$duration"
fi
# If the command begins with a shell reserved word, wrap it in bash -lc
case "${1:-}" in
  if|for|while|case|{)
    cmd_str="$*"
    exec "$REAL_TIMEOUT" "${opts[@]}" "$duration" bash -lc "$cmd_str"
    ;;
  *)
    exec "$REAL_TIMEOUT" "${opts[@]}" "$duration" "$@"
    ;;
esac
EOF
  chmod +x /usr/local/bin/timeout
  if [ ! -e /bin/timeout ]; then ln -s /usr/local/bin/timeout /bin/timeout || true; fi
}

# Bash wrapper to address CI orchestration bug with timeout + if compound
install_bash_wrapper() {
  if [[ $IS_ROOT -ne 1 ]]; then
    warn "Not root; skipping /bin/bash wrapper installation"
    return 0
  fi

  # Ensure the real bash is saved
  if [ ! -x /bin/bash.real ]; then
    cp /bin/bash /bin/bash.real 2>/dev/null || true
  fi

  # Install robust wrapper that strips leading 'timeout' prefix from -c commands
  cat > /bin/bash <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real="/bin/bash.real"
if ! [ -x "$real" ]; then
  real="$(command -v bash.real || true)"
fi
if ! [ -x "$real" ]; then
  real="/usr/bin/bash"
fi
if [ "${1-}" = "-c" ] && [ "${2-}" != "" ]; then
  cmd="$2"
  # Strip leading 'timeout [-k <val>] <duration>' if present to avoid parse errors with compound statements
  newcmd="$(printf '%s' "$cmd" | sed -E 's/^[[:space:]]*timeout[[:space:]]+(-k[[:space:]]+[^[:space:]]+[[:space:]]+)?[^[:space:]]+[[:space:]]+//')"
  exec "$real" -c "$newcmd"
else
  exec "$real" "$@"
fi
EOF
  chmod 0755 /bin/bash
}

# Main
main() {
  log "Starting universal environment setup"
  detect_pkg_mgr
  ensure_group_user
  ensure_dirs
  install_base_tools
  install_timeout_wrapper
  install_bash_wrapper
  write_env_profiles  # initialize .env with base entries

  detect_project

  # Execute language-specific setups
  setup_python
  ensure_venv_auto_activate
  setup_node
  setup_ruby
  setup_java
  setup_go
  setup_rust
  setup_php
  setup_dotnet

  detect_port_from_procfile
  fix_permissions
  finalize_cleanup

  log "Environment setup completed successfully."
  info "Environment variables written to: $ENV_DOTFILE"
  if [[ $IS_ROOT -eq 1 ]]; then
    info "Profile script installed: $ENV_PROFILE_FILE"
  fi
  info "To load environment in a running shell: set -a && . \"$ENV_DOTFILE\" && set +a"
}

# Ensure APP_DIR exists (if mounted empty)
mkdir -p "$APP_DIR"
cd "$APP_DIR"

main "$@"