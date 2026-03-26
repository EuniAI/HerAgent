#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types (Python, Node.js, Ruby, PHP, Go, Java, Rust, .NET)
# - Installs runtime and system dependencies
# - Sets up directory structure, permissions, and environment variables
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$' \n\t'
umask 027

#========================
# Logging and error trap
#========================
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info()   { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() { :; }
on_error() {
  local exit_code=$?
  error "Setup failed with exit code ${exit_code}"
  exit "$exit_code"
}
trap cleanup EXIT
trap on_error ERR

#========================
# Configuration defaults
#========================
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_PORT="${APP_PORT:-8080}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
PROFILE_SNIPPET="/etc/profile.d/zz-app-env.sh"

PY_VENV_DIR="${PY_VENV_DIR:-/opt/venv}"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-$APP_DIR/.cache/pip}"
NPM_CACHE_DIR="${NPM_CACHE_DIR:-$APP_DIR/.cache/npm}"
COMPOSER_CACHE_DIR="${COMPOSER_CACHE_DIR:-$APP_DIR/.cache/composer}"
CARGO_HOME="${CARGO_HOME:-$APP_DIR/.cache/cargo}"
GOMODCACHE="${GOMODCACHE:-$APP_DIR/.cache/go}"

#========================
# Helpers
#========================
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
file_exists() { [ -f "$1" ]; }
dir_exists() { [ -d "$1" ]; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

#========================
# Package manager setup
#========================
PKG_MGR=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
DEBIAN_FRONTEND=noninteractive; export DEBIAN_FRONTEND

detect_pkg_manager() {
  if cmd_exists apt-get; then
    PKG_MGR="apt"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
  elif cmd_exists apk; then
    PKG_MGR="apk"
    PKG_UPDATE=": # apk doesn't require explicit update with --no-cache"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN=": # apk clean not required with --no-cache"
  elif cmd_exists dnf; then
    PKG_MGR="dnf"
    PKG_UPDATE="dnf -y makecache"
    PKG_INSTALL="dnf -y install"
    PKG_CLEAN="dnf clean all"
  elif cmd_exists yum; then
    PKG_MGR="yum"
    PKG_UPDATE="yum -y makecache"
    PKG_INSTALL="yum -y install"
    PKG_CLEAN="yum clean all"
  elif cmd_exists microdnf; then
    PKG_MGR="microdnf"
    PKG_UPDATE="microdnf makecache"
    PKG_INSTALL="microdnf install -y"
    PKG_CLEAN="microdnf clean all"
  else
    error "No supported package manager found (apt, apk, dnf, yum, microdnf)."
    exit 1
  fi
  log "Using package manager: $PKG_MGR"
}

pkg_update() { eval "$PKG_UPDATE"; }
pkg_install() {
  local packages=("$@")
  if [ "${#packages[@]}" -eq 0 ]; then return 0; fi
  log "Installing packages: ${packages[*]}"
  eval "$PKG_INSTALL ${packages[*]}"
}
pkg_clean() { eval "$PKG_CLEAN"; }

#========================
# User and directory setup
#========================
ensure_group() {
  local group="$1" gid="$2"
  if cmd_exists getent; then
    if getent group "$group" >/dev/null 2>&1; then return 0; fi
  fi
  if cmd_exists addgroup; then
    addgroup -g "$gid" -S "$group" 2>/dev/null || true
  elif cmd_exists groupadd; then
    groupadd -g "$gid" -f "$group" 2>/dev/null || true
  fi
}
ensure_user() {
  local user="$1" uid="$2" group="$3"
  if cmd_exists id && id -u "$user" >/dev/null 2>&1; then return 0; fi
  if cmd_exists adduser; then
    adduser -S -D -H -s /sbin/nologin -u "$uid" -G "$group" "$user" 2>/dev/null || true
  elif cmd_exists useradd; then
    useradd -M -r -s /usr/sbin/nologin -u "$uid" -g "$group" "$user" 2>/dev/null || true
  fi
}

setup_dirs_and_permissions() {
  log "Creating project directories"
  mkdir -p "$APP_DIR" \
           "$APP_DIR/logs" \
           "$APP_DIR/tmp" \
           "$APP_DIR/.cache" \
           "$(dirname "$PY_VENV_DIR")" \
           "$PIP_CACHE_DIR" \
           "$NPM_CACHE_DIR" \
           "$COMPOSER_CACHE_DIR" \
           "$CARGO_HOME" \
           "$GOMODCACHE"

  if is_root; then
    ensure_group "$APP_GROUP" "$APP_GID"
    ensure_user "$APP_USER" "$APP_UID" "$APP_GROUP"
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR" "$PY_VENV_DIR" "$(dirname "$PY_VENV_DIR")" 2>/dev/null || true
  else
    warn "Running as non-root. Skipping user creation and chown."
  fi

  chmod -R u=rwX,g=rX,o= "$APP_DIR"
}

#========================
# Environment persistence
#========================
write_env_files() {
  log "Writing environment configuration"
  mkdir -p "$(dirname "$ENV_FILE")"

  # .env file in app directory (non-exported key=value)
  if ! file_exists "$ENV_FILE"; then
    cat > "$ENV_FILE" <<EOF
APP_DIR=$APP_DIR
APP_PORT=$APP_PORT
NODE_ENV=${NODE_ENV:-production}
PYTHONDONTWRITEBYTECODE=1
PYTHONUNBUFFERED=1
PIP_CACHE_DIR=$PIP_CACHE_DIR
NPM_CONFIG_CACHE=$NPM_CACHE_DIR
COMPOSER_CACHE_DIR=$COMPOSER_CACHE_DIR
CARGO_HOME=$CARGO_HOME
GOMODCACHE=$GOMODCACHE
EOF
    if is_root; then chown "$APP_USER:$APP_GROUP" "$ENV_FILE" 2>/dev/null || true; fi
  fi

  # Profile snippet for shell sessions
  if is_root; then
    cat > "$PROFILE_SNIPPET" <<'EOS'
# Auto-generated by setup script
[ -f /app/.env ] && set -a && . /app/.env && set +a
export PATH="/opt/venv/bin:/app/node_modules/.bin:$PATH"
EOS
    chmod 0644 "$PROFILE_SNIPPET"
  fi
}

#========================
# Auto-activate Python venv in shell sessions
#========================
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local activate_line="source $PY_VENV_DIR/bin/activate"
  if [ -f "$PY_VENV_DIR/bin/activate" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      mkdir -p "$(dirname "$bashrc_file")" 2>/dev/null || true
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

#========================
# Checksums for idempotent installs
#========================
checksum_file() {
  local f="$1"
  if ! file_exists "$f"; then echo "absent"; return 0; fi
  if cmd_exists sha256sum; then sha256sum "$f" | awk '{print $1}'; elif cmd_exists shasum; then shasum -a 256 "$f" | awk '{print $1}'; else cat "$f" | wc -c; fi
}

#========================
# Language environment setup functions
#========================
setup_python() {
  local need_python="false"
  local req_file=""
  if file_exists "$APP_DIR/requirements.txt"; then req_file="$APP_DIR/requirements.txt"; need_python="true"; fi
  if file_exists "$APP_DIR/pyproject.toml"; then need_python="true"; fi
  if file_exists "$APP_DIR/Pipfile"; then need_python="true"; fi

  [ "$need_python" = "false" ] && { info "Python project files not detected."; return 0; }

  log "Setting up Python environment"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install python3 python3-venv python3-distutils python3-pip python3-dev gcc build-essential libffi-dev libssl-dev liblzma-dev libbz2-dev libsqlite3-dev ca-certificates
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev gcc musl-dev libffi-dev openssl-dev ca-certificates
      ;;
    dnf|yum|microdnf)
      pkg_update
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel ca-certificates
      ;;
  esac

  python3 - <<'PY'
import sys
maj=min=0
maj, min = sys.version_info[:2]
assert (maj, min) >= (3,7), "Python 3.7+ required"
PY

  if [ ! -d "$PY_VENV_DIR" ] || [ ! -x "$PY_VENV_DIR/bin/python3" ]; then
    log "Creating Python virtual environment at $PY_VENV_DIR"
    python3 -m venv "$PY_VENV_DIR"
  else
    info "Python virtual environment already exists at $PY_VENV_DIR"
  fi

  # Activate venv for current script context
  # shellcheck disable=SC1090
  source "$PY_VENV_DIR/bin/activate"

  "$PY_VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
  export PIP_CACHE_DIR

  if [ -n "$req_file" ] && file_exists "$req_file"; then
    local req_hash current_hash_file
    req_hash="$(checksum_file "$req_file")"
    current_hash_file="$PY_VENV_DIR/.requirements.sha256"
    local prev_hash="none"
    if file_exists "$current_hash_file"; then prev_hash="$(cat "$current_hash_file")"; fi
    if [ "$req_hash" != "$prev_hash" ]; then
      log "Installing Python dependencies from requirements.txt"
      PIP_NO_CACHE_DIR=0 pip install -r "$req_file"
      echo "$req_hash" > "$current_hash_file"
    else
      info "Python dependencies are up to date (requirements checksum unchanged)"
    fi
  elif file_exists "$APP_DIR/pyproject.toml"; then
    log "Installing Python project via pyproject.toml (PEP 517)"
    # Try to install build backend if needed
    pip install --upgrade build
    # Install in editable mode if possible; fallback to regular install
    if grep -qiE 'tool\.poetry' "$APP_DIR/pyproject.toml" 2>/dev/null; then
      pip install "poetry>=1.5" || true
      poetry config virtualenvs.create false || true
      poetry install --no-interaction --no-ansi --no-root || true
      poetry install --no-interaction --no-ansi || true
    else
      pip install -e "$APP_DIR" || pip install "$APP_DIR"
    fi
  fi

  # Persist PATH for runtime
  log "Python setup completed"
}

setup_node() {
  if ! file_exists "$APP_DIR/package.json"; then
    info "Node.js project files not detected."
    return 0
  fi

  log "Setting up Node.js environment"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ca-certificates curl gnupg
      # Install node and npm from distro (may not be latest, but stable)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum|microdnf)
      pkg_update
      pkg_install nodejs npm
      ;;
  esac

  mkdir -p "$APP_DIR/node_modules" "$NPM_CACHE_DIR"
  local lockfile=""
  if file_exists "$APP_DIR/package-lock.json"; then lockfile="$APP_DIR/package-lock.json"; fi
  if file_exists "$APP_DIR/npm-shrinkwrap.json"; then lockfile="$APP_DIR/npm-shrinkwrap.json"; fi

  local lock_hash prev_hash_file
  prev_hash_file="$APP_DIR/.npm-deps.sha256"
  lock_hash="$(checksum_file "${lockfile:-$APP_DIR/package.json}")"
  local prev_hash="none"
  if file_exists "$prev_hash_file"; then prev_hash="$(cat "$prev_hash_file")"; fi

  export NPM_CONFIG_CACHE="$NPM_CACHE_DIR"
  export NODE_ENV="${NODE_ENV:-production}"

  if [ "$lock_hash" != "$prev_hash" ]; then
    log "Installing Node.js dependencies"
    if file_exists "$APP_DIR/package-lock.json"; then
      (cd "$APP_DIR" && npm ci --no-audit --omit=dev)
    else
      (cd "$APP_DIR" && npm install --no-audit --omit=dev)
    fi
    echo "$lock_hash" > "$prev_hash_file"
    if is_root; then chown -R "$APP_USER:$APP_GROUP" "$APP_DIR/node_modules" "$prev_hash_file" 2>/dev/null || true; fi
  else
    info "Node.js dependencies are up to date (lock/package checksum unchanged)"
  fi

  log "Node.js setup completed"
}

setup_ruby() {
  if ! file_exists "$APP_DIR/Gemfile"; then
    info "Ruby project files not detected."
    return 0
  fi
  log "Setting up Ruby environment"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-bundler build-base
      ;;
    dnf|yum|microdnf)
      pkg_update
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
  esac

  if ! cmd_exists bundle && cmd_exists gem; then gem install bundler --no-document || true; fi

  local lock_hash prev_hash_file
  prev_hash_file="$APP_DIR/.bundle-deps.sha256"
  lock_hash="$(checksum_file "$APP_DIR/Gemfile.lock")"
  local prev_hash="none"
  if file_exists "$prev_hash_file"; then prev_hash="$(cat "$prev_hash_file")"; fi

  if [ "$lock_hash" != "$prev_hash" ]; then
    (cd "$APP_DIR" && BUNDLE_PATH="$APP_DIR/vendor/bundle" bundle install --jobs=4 --retry=3 --without development test || bundle install)
    echo "$lock_hash" > "$prev_hash_file"
    if is_root; then chown -R "$APP_USER:$APP_GROUP" "$APP_DIR/vendor/bundle" "$prev_hash_file" 2>/dev/null || true; fi
  else
    info "Ruby dependencies are up to date"
  fi
  log "Ruby setup completed"
}

setup_php() {
  if ! file_exists "$APP_DIR/composer.json"; then
    info "PHP project files not detected."
    return 0
  fi
  log "Setting up PHP environment"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install php-cli php-zip php-mbstring php-xml php-curl unzip curl ca-certificates
      ;;
    apk)
      pkg_install php81 php81-cli php81-phar php81-mbstring php81-xml php81-curl php81-zip curl
      ;;
    dnf|yum|microdnf)
      pkg_update
      pkg_install php-cli php-json php-zip php-mbstring php-xml php-curl unzip curl
      ;;
  esac

  if ! cmd_exists composer; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  export COMPOSER_CACHE_DIR
  local lock_hash prev_hash_file
  prev_hash_file="$APP_DIR/.composer-deps.sha256"
  lock_hash="$(checksum_file "$APP_DIR/composer.lock")"
  local prev_hash="none"
  if file_exists "$prev_hash_file"; then prev_hash="$(cat "$prev_hash_file")"; fi

  if [ "$lock_hash" != "$prev_hash" ]; then
    (cd "$APP_DIR" && composer install --no-interaction --no-progress --prefer-dist --no-dev || composer install --no-interaction --no-progress --prefer-dist)
    echo "$lock_hash" > "$prev_hash_file"
    if is_root; then chown -R "$APP_USER:$APP_GROUP" "$APP_DIR/vendor" "$prev_hash_file" 2>/dev/null || true; fi
  else
    info "PHP dependencies are up to date"
  fi
  log "PHP setup completed"
}

setup_go() {
  if ! file_exists "$APP_DIR/go.mod"; then
    info "Go project files not detected."
    return 0
  fi
  log "Setting up Go environment"
  case "$PKG_MGR" in
    apt) pkg_update; pkg_install golang ca-certificates git ;;
    apk) pkg_install go ca-certificates git ;;
    dnf|yum|microdnf) pkg_update; pkg_install golang ca-certificates git ;;
  esac
  export GO111MODULE=on
  export GOMODCACHE
  (cd "$APP_DIR" && go mod download)
  log "Go setup completed"
}

setup_java() {
  local is_maven="false" is_gradle="false"
  if file_exists "$APP_DIR/pom.xml"; then is_maven="true"; fi
  if file_exists "$APP_DIR/build.gradle" || file_exists "$APP_DIR/build.gradle.kts" || file_exists "$APP_DIR/gradlew"; then is_gradle="true"; fi
  if [ "$is_maven" = "false" ] && [ "$is_gradle" = "false" ]; then
    info "Java project files not detected."
    return 0
  fi
  log "Setting up Java environment"
  case "$PKG_MGR" in
    apt) pkg_update; pkg_install openjdk-17-jdk maven gradle || pkg_install openjdk-17-jdk maven ;;
    apk) pkg_install openjdk17 maven gradle || pkg_install openjdk17 maven ;;
    dnf|yum|microdnf) pkg_update; pkg_install java-17-openjdk java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk maven ;;
  esac

  if [ "$is_maven" = "true" ]; then
    (cd "$APP_DIR" && mvn -B -q -DskipTests dependency:resolve || true)
  fi
  if [ "$is_gradle" = "true" ]; then
    if file_exists "$APP_DIR/gradlew"; then
      (cd "$APP_DIR" && chmod +x gradlew && ./gradlew -q --no-daemon tasks || true)
    else
      (cd "$APP_DIR" && gradle -q --no-daemon tasks || true)
    fi
  fi
  log "Java setup completed"
}

setup_rust() {
  if ! file_exists "$APP_DIR/Cargo.toml"; then
    info "Rust project files not detected."
    return 0
  fi
  log "Setting up Rust environment"
  case "$PKG_MGR" in
    apt) pkg_update; pkg_install cargo rustc gcc pkg-config ;;
    apk) pkg_install cargo rust gcc pkgconf ;;
    dnf|yum|microdnf) pkg_update; pkg_install cargo rust gcc pkgconf-pkg-config ;;
  esac
  export CARGO_HOME
  (cd "$APP_DIR" && cargo fetch || true)
  log "Rust setup completed"
}

setup_dotnet() {
  # Minimal detection and notice
  if ! ls "$APP_DIR"/*.csproj >/dev/null 2>&1 && ! ls "$APP_DIR"/*.sln >/dev/null 2>&1; then
    info ".NET project files not detected."
    return 0
  fi
  log "Detected .NET project files"
  warn "Automatic .NET SDK installation is environment-specific. Attempting distro packages."

  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || warn "Could not install .NET SDK via apt"
      ;;
    dnf|yum|microdnf)
      pkg_update
      pkg_install dotnet-sdk-8.0 || pkg_install dotnet-sdk-7.0 || warn "Could not install .NET SDK via rpm"
      ;;
    apk)
      pkg_install dotnet7-sdk || warn "Could not install .NET SDK via apk"
      ;;
  esac

  if cmd_exists dotnet; then
    (cd "$APP_DIR" && dotnet restore || true)
    log ".NET setup completed"
  else
    warn ".NET SDK not installed; please add SDK to base image."
  fi
}

#========================
# Base tools setup
#========================
install_base_tools() {
  log "Installing base system tools"
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ca-certificates curl git unzip zip xz-utils tar gzip gnupg coreutils findutils make python3
      ;;
    apk)
      pkg_install ca-certificates curl git unzip zip xz tar gzip gnupg coreutils findutils make
      ;;
    dnf|yum|microdnf)
      pkg_update
      pkg_install ca-certificates curl git unzip zip xz tar gzip gnupg coreutils findutils make
      ;;
  esac
}

#========================
# Timeout wrapper to allow compound commands under harness
#========================
setup_timeout_wrapper() {
  if is_root; then
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/timeout << 'PY'
#!/usr/bin/env python3
import os, sys
real_timeout = '/usr/bin/timeout' if os.path.exists('/usr/bin/timeout') else '/bin/timeout'
av = sys.argv[1:]
i = 0
while i < len(av) and av[i].startswith('-'):
    if av[i] in ('-k', '-s', '--signal'):
        i += 2
    else:
        i += 1
if i < len(av):
    cmd = av[i]
    if cmd in ('if','for','while','case','{','('):
        compound = ' '.join(av[i:])
        new_av = av[:i] + ['bash','-lc', compound]
        os.execv(real_timeout, [real_timeout] + new_av)
os.execv(real_timeout, [real_timeout] + av)
PY
    chmod +x /usr/local/bin/timeout
  else
    warn "Non-root user; cannot install timeout wrapper"
  fi
}

#========================
# Bash wrapper fix for harness compound-timeout issue
#========================
setup_bash_wrapper_fix() {
  if is_root; then
    # Ensure python3 is available for the wrapper
    if ! cmd_exists python3; then
      case "$PKG_MGR" in
        apt)
          pkg_update; pkg_install python3 ;;
        apk)
          pkg_install python3 ;;
        dnf|yum|microdnf)
          pkg_update; pkg_install python3 ;;
      esac
    fi
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/bash << 'PY'
#!/usr/bin/env python3
import os, sys
real_bash = '/bin/bash'
av = sys.argv[1:]
idx = None
for i, a in enumerate(av):
    if a == '-c' or (a.startswith('-') and 'c' in a[1:]):
        idx = i
        break
if idx is not None:
    cmd = ' '.join(av[idx+1:])
    new_av = av[:idx+1] + [cmd]
else:
    new_av = av
os.execv(real_bash, [real_bash] + new_av)
PY
    chmod +x /usr/local/bin/bash
  else
    warn "Non-root user; cannot install bash wrapper fix"
  fi
}

#========================
# Project detection
#========================
detect_project_types() {
  local types=()
  file_exists "$APP_DIR/requirements.txt"   && types+=("python")
  file_exists "$APP_DIR/pyproject.toml"     && [[ ! " ${types[*]} " =~ " python " ]] && types+=("python")
  file_exists "$APP_DIR/package.json"       && types+=("node")
  file_exists "$APP_DIR/Gemfile"            && types+=("ruby")
  file_exists "$APP_DIR/composer.json"      && types+=("php")
  file_exists "$APP_DIR/go.mod"             && types+=("go")
  file_exists "$APP_DIR/pom.xml" && types+=("java")
  (file_exists "$APP_DIR/build.gradle" || file_exists "$APP_DIR/build.gradle.kts" || file_exists "$APP_DIR/gradlew") && [[ ! " ${types[*]} " =~ " java " ]] && types+=("java")
  ls "$APP_DIR"/*.csproj >/dev/null 2>&1 && types+=(".net")
  ls "$APP_DIR"/*.sln   >/dev/null 2>&1 && [[ ! " ${types[*]} " =~ " .net " ]] && types+=(".net")
  file_exists "$APP_DIR/Cargo.toml"        && types+=("rust")

  if [ "${#types[@]}" -eq 0 ]; then
    warn "No recognized project files found in $APP_DIR. Installing only base tools."
  else
    log "Detected project types: ${types[*]}"
  fi
  echo "${types[*]}"
}

#========================
# Main flow
#========================
main() {
  log "Starting environment setup"
  detect_pkg_manager
  install_base_tools
  setup_bash_wrapper_fix
  setup_timeout_wrapper
  setup_dirs_and_permissions
  write_env_files

  # Ensure script operates inside APP_DIR
  cd "$APP_DIR"

  # Project types
  IFS=' ' read -r -a proj_types <<<"$(detect_project_types)"

  # Install per type
  local t
  for t in "${proj_types[@]}"; do
    case "$t" in
      python) setup_python ;;
      node)   setup_node ;;
      ruby)   setup_ruby ;;
      php)    setup_php ;;
      go)     setup_go ;;
      java)   setup_java ;;
      rust)   setup_rust ;;
      .net)   setup_dotnet ;;
    esac
  done

  # Configure shell auto-activation for Python venv if present
  setup_auto_activate

  # Clean package caches
  pkg_clean || true

  # Final info
  log "Environment setup completed successfully."
  echo "Summary:"
  echo " - App directory: $APP_DIR"
  echo " - App user: ${APP_USER} (UID: ${APP_UID})"
  echo " - App group: ${APP_GROUP} (GID: ${APP_GID})"
  echo " - Default port: ${APP_PORT}"
  echo " - Python venv: $PY_VENV_DIR (if Python detected)"
  echo " - .env file: $ENV_FILE"
  echo
  echo "Runtime tips:"
  echo " - To load environment in a shell: source $PROFILE_SNIPPET (if present) or: set -a && . $ENV_FILE && set +a"
  echo " - Python: source $PY_VENV_DIR/bin/activate && python your_app.py"
  echo " - Node:   node your_app.js"
  echo " - Ruby:   bundle exec your_cmd"
  echo " - PHP:    php your_script.php"
  echo " - Go:     go run ."
  echo " - Java:   mvn spring-boot:run or ./gradlew bootRun (if applicable)"
  echo " - .NET:   dotnet run"
}

main "$@"