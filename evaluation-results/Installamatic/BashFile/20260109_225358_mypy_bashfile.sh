#!/usr/bin/env bash
# Environment setup script for containerized projects (polyglot support)
# This script detects common project types and installs required runtimes,
# system dependencies, and project dependencies in an idempotent way.
# Designed to run as root inside Docker containers without sudo.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------- Logging and Error Handling ----------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err()    { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()    { err "$*"; exit 1; }

_cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Setup failed with exit code $exit_code"
  fi
  exit $exit_code
}
trap _cleanup EXIT

# ---------------------- Globals and Defaults ----------------------
# Root of the project (directory containing this script or current dir)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="${APP_DIR:-$SCRIPT_DIR}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
PROFILE_SNIPPET="${PROFILE_SNIPPET:-$APP_DIR/.container_env.sh}"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

# Will track if apt-get update has run
_APT_UPDATED=0

# ---------------------- Utility Functions ----------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
  if has_cmd apt-get; then echo "apt"; return
  elif has_cmd apk; then echo "apk"; return
  elif has_cmd dnf; then echo "dnf"; return
  elif has_cmd yum; then echo "yum"; return
  elif has_cmd zypper; then echo "zypper"; return
  else echo "none"; return
  fi
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local pm; pm="$(detect_pkg_manager)"
  local pkgs=("$@")
  case "$pm" in
    apt)
      if [[ $_APT_UPDATED -eq 0 ]]; then
        log "Updating apt package index..."
        apt-get update -y
        _APT_UPDATED=1
      fi
      log "Installing packages via apt: ${pkgs[*]}"
      apt-get install -y --no-install-recommends "${pkgs[@]}" || die "apt install failed"
      ;;
    apk)
      log "Installing packages via apk: ${pkgs[*]}"
      apk add --no-cache "${pkgs[@]}" || die "apk add failed"
      ;;
    dnf)
      log "Installing packages via dnf: ${pkgs[*]}"
      dnf -y install "${pkgs[@]}" || die "dnf install failed"
      ;;
    yum)
      log "Installing packages via yum: ${pkgs[*]}"
      yum -y install "${pkgs[@]}" || die "yum install failed"
      ;;
    zypper)
      log "Installing packages via zypper: ${pkgs[*]}"
      zypper --non-interactive install -y "${pkgs[@]}" || die "zypper install failed"
      ;;
    *)
      warn "No supported package manager found. Skipping system package installation."
      return 1
      ;;
  esac
  return 0
}

pkg_cleanup() {
  local pm; pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      # no-op due to --no-cache
      true
      ;;
    dnf|yum)
      dnf -y clean all 2>/dev/null || yum -y clean all 2>/dev/null || true
      rm -rf /var/cache/dnf /var/cache/yum || true
      ;;
    zypper)
      zypper clean -a || true
      ;;
  esac
}

ensure_base_tools() {
  local pm; pm="$(detect_pkg_manager)"
  log "Ensuring base system tools are installed..."
  case "$pm" in
    apt)
      pkg_install ca-certificates curl git gnupg unzip xz-utils zip tar build-essential pkg-config
      ;;
    apk)
      pkg_install ca-certificates curl git gnupg unzip xz tar build-base pkgconfig
      ;;
    dnf)
      pkg_install ca-certificates curl git gnupg2 unzip xz tar gcc gcc-c++ make pkgconfig
      ;;
    yum)
      pkg_install ca-certificates curl git gnupg2 unzip xz tar gcc gcc-c++ make pkgconfig
      ;;
    zypper)
      pkg_install ca-certificates curl git gpg2 unzip xz tar gcc gcc-c++ make pkg-config
      ;;
    *)
      warn "Cannot ensure base tools without a package manager."
      ;;
  esac
  update-ca-certificates 2>/dev/null || update-ca-trust 2>/dev/null || true
}

# Ensure a Git repository and commit exist for projects that compute version from Git
ensure_git_repo_for_build() {
  local dir="${1:-$APP_DIR}"
  # Ensure git is available
  if ! has_cmd git; then
    pkg_install git || true
  fi
  # Mark directory as safe to avoid 'dubious ownership' errors
  git config --global --add safe.directory "$dir" >/dev/null 2>&1 || true
  # Initialize repo and create an initial commit if missing
  if [[ ! -d "$dir/.git" ]]; then
    (cd "$dir" && git init && git config user.email "ci@example.com" && git config user.name "CI" && git add -A && git commit -m "Initial commit for build metadata") >/dev/null 2>&1 || true
  else
    if ! git -C "$dir" rev-parse HEAD >/dev/null 2>&1; then
      (cd "$dir" && git config user.email "ci@example.com" && git config user.name "CI" && git add -A && git commit -m "Initial commit for build metadata") >/dev/null 2>&1 || true
    fi
  fi
}

ensure_app_user() {
  # Create application group and user if running as root. If not root, skip.
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "Not running as root; skipping user creation and permission adjustments."
    return 0
  fi

  # Create group if not exists
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if has_cmd addgroup; then
      addgroup -g "$APP_GID" "$APP_GROUP" || addgroup "$APP_GROUP" || true
    elif has_cmd groupadd; then
      groupadd -g "$APP_GID" -o -r "$APP_GROUP" || groupadd -o -r "$APP_GROUP" || true
    fi
  fi

  # Create user if not exists
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if has_cmd adduser; then
      adduser -D -G "$APP_GROUP" -u "$APP_UID" "$APP_USER" || adduser -D "$APP_USER" || true
    elif has_cmd useradd; then
      useradd -r -u "$APP_UID" -g "$APP_GROUP" -d "$APP_DIR" -s /bin/bash "$APP_USER" || useradd -r -g "$APP_GROUP" "$APP_USER" || true
    fi
  fi
}

setup_directories() {
  log "Setting up project directories and permissions..."
  mkdir -p "$APP_DIR" \
           "$APP_DIR/logs" \
           "$APP_DIR/tmp" \
           "$APP_DIR/cache" \
           "$APP_DIR/data"
  # Create node_modules/.cache to avoid root-owned caches when RUN steps differ
  mkdir -p "$APP_DIR/node_modules/.cache" 2>/dev/null || true

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR" || true
    chmod -R ug+rw "$APP_DIR" || true
    find "$APP_DIR" -type d -exec chmod 775 {} \; || true
    find "$APP_DIR" -type f -exec chmod 664 {} \; || true
  fi
}

# ---------------------- Project Detection ----------------------
detect_project_components() {
  local components=()

  # Python
  [[ -f "$APP_DIR/requirements.txt" || -f "$APP_DIR/requirements.prod.txt" || -f "$APP_DIR/pyproject.toml" || -f "$APP_DIR/Pipfile" ]] && components+=("python")

  # Node.js
  [[ -f "$APP_DIR/package.json" ]] && components+=("node")

  # Ruby
  [[ -f "$APP_DIR/Gemfile" ]] && components+=("ruby")

  # Go
  [[ -f "$APP_DIR/go.mod" ]] && components+=("go")

  # PHP
  [[ -f "$APP_DIR/composer.json" ]] && components+=("php")

  # Java
  [[ -f "$APP_DIR/pom.xml" || -f "$APP_DIR/build.gradle" || -f "$APP_DIR/build.gradle.kts" || -f "$APP_DIR/gradlew" ]] && components+=("java")

  # Rust
  [[ -f "$APP_DIR/Cargo.toml" ]] && components+=("rust")

  echo "${components[*]}"
}

# ---------------------- Setup Per Stack ----------------------
setup_python() {
  log "Configuring Python environment..."
  local pm; pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev zlib1g-dev libpq-dev sqlite3
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev libffi-dev openssl-dev zlib-dev postgresql-dev sqlite-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel libffi-devel openssl-devel zlib-devel postgresql-devel sqlite
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel libffi-devel libopenssl-devel zlib-devel postgresql-devel sqlite3
      ;;
    *)
      warn "Package manager not found; assuming Python runtime exists."
      ;;
  esac

  # Ensure python3 and pip are present
  has_cmd python3 || die "Python3 not available"
  if ! has_cmd pip3; then
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
    python3 /tmp/get-pip.py
  fi

  # Create venv
  local venv_dir="$APP_DIR/.venv"
  if [[ ! -d "$venv_dir" ]]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Python virtual environment already exists at $venv_dir"
  fi

  # Activate venv for this shell
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"

  python -m pip install --upgrade pip setuptools wheel

  if [[ -f "$APP_DIR/requirements.prod.txt" ]]; then
    log "Installing Python dependencies from requirements.prod.txt"
    pip install -r "$APP_DIR/requirements.prod.txt"
  elif [[ -f "$APP_DIR/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "$APP_DIR/requirements.txt"
  elif [[ -f "$APP_DIR/pyproject.toml" ]]; then
    log "Installing Python project from pyproject.toml"
    ensure_git_repo_for_build "$APP_DIR"
    pip install "$APP_DIR"
  elif [[ -f "$APP_DIR/Pipfile" ]]; then
    log "Detected Pipfile. Installing pipenv and dependencies."
    pip install pipenv
    cd "$APP_DIR"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
  else
    warn "No Python dependency file found."
  fi

  # Env vars
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1

  # Make PATH available for subsequent shells
  {
    echo 'export PYTHONUNBUFFERED=1'
    echo 'export PYTHONDONTWRITEBYTECODE=1'
    echo "export PATH=\"$APP_DIR/.venv/bin:\$PATH\""
  } >> "$PROFILE_SNIPPET"

  # Ensure venv auto-activation via profile snippet for login shells
  if ! grep -qF "$venv_dir/bin/activate" "$PROFILE_SNIPPET" 2>/dev/null; then
    echo "[ -d \"$venv_dir\" ] && . \"$venv_dir/bin/activate\"" >> "$PROFILE_SNIPPET"
  fi
}

setup_node() {
  log "Configuring Node.js environment..."
  local pm; pm="$(detect_pkg_manager)"
  if ! has_cmd node || ! has_cmd npm; then
    case "$pm" in
      apt) pkg_install nodejs npm ;;
      apk) pkg_install nodejs npm ;;
      dnf|yum) pkg_install nodejs npm || warn "Could not install Node.js via $pm, will try nvm." ;;
      zypper) pkg_install nodejs npm ;;
    esac
  fi

  if ! has_cmd node || ! has_cmd npm; then
    # Fallback to nvm
    log "Installing Node.js via nvm..."
    export NVM_DIR="/usr/local/nvm"
    if [[ ! -d "$NVM_DIR" ]]; then
      mkdir -p "$NVM_DIR"
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    # shellcheck disable=SC1090
    source "$NVM_DIR/nvm.sh"
    nvm install --lts
    nvm alias default 'lts/*'
    # Make nvm available for login shells
    {
      echo 'export NVM_DIR="/usr/local/nvm"'
      echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
      echo 'nvm use default >/dev/null 2>&1 || true'
    } >> "$PROFILE_SNIPPET"
  fi

  # Install package managers as needed
  local use_yarn=0 use_pnpm=0
  if [[ -f "$APP_DIR/yarn.lock" ]]; then use_yarn=1; fi
  if [[ -f "$APP_DIR/pnpm-lock.yaml" || -f "$APP_DIR/pnpm-lock.yml" ]]; then use_pnpm=1; fi

  if [[ $use_yarn -eq 1 ]] && ! has_cmd yarn; then
    log "Installing yarn..."
    if has_cmd corepack; then
      corepack enable || true
      corepack prepare yarn@stable --activate || npm install -g yarn
    else
      npm install -g yarn
    fi
  fi

  if [[ $use_pnpm -eq 1 ]] && ! has_cmd pnpm; then
    log "Installing pnpm..."
    if has_cmd corepack; then
      corepack enable || true
      corepack prepare pnpm@latest --activate || npm install -g pnpm
    else
      npm install -g pnpm
    fi
  fi

  cd "$APP_DIR"
  if [[ -f package.json ]]; then
    export NODE_ENV="${NODE_ENV:-production}"
    if [[ $use_pnpm -eq 1 ]]; then
      log "Installing Node dependencies with pnpm..."
      pnpm install --frozen-lockfile || pnpm install
    elif [[ $use_yarn -eq 1 ]]; then
      log "Installing Node dependencies with yarn..."
      yarn install --frozen-lockfile || yarn install
    else
      if [[ -f package-lock.json ]]; then
        log "Installing Node dependencies with npm ci..."
        npm ci || npm install
      else
        log "Installing Node dependencies with npm install..."
        npm install
      fi
    fi
    # Persist env
    {
      echo 'export NODE_ENV=${NODE_ENV:-production}'
      echo "export PATH=\"$APP_DIR/node_modules/.bin:\$PATH\""
    } >> "$PROFILE_SNIPPET"
  else
    warn "package.json not found; skipping Node dependency installation."
  fi
}

setup_ruby() {
  log "Configuring Ruby environment..."
  local pm; pm="$(detect_pkg_manager)"
  case "$pm" in
    apt) pkg_install ruby-full build-essential libffi-dev libssl-dev zlib1g-dev ;;
    apk) pkg_install ruby ruby-dev build-base libffi-dev openssl-dev zlib-dev ;;
    dnf|yum) pkg_install ruby ruby-devel gcc gcc-c++ make libffi-devel openssl-devel zlib-devel ;;
    zypper) pkg_install ruby ruby-devel gcc gcc-c++ make libffi-devel libopenssl-devel zlib-devel ;;
    *) warn "No package manager found for Ruby installation." ;;
  esac

  if ! has_cmd gem; then die "gem not found after installation"; fi
  gem install bundler --no-document || true

  if [[ -f "$APP_DIR/Gemfile" ]]; then
    cd "$APP_DIR"
    export BUNDLE_WITHOUT="${BUNDLE_WITHOUT:-development:test}"
    bundle config set path "$APP_DIR/vendor/bundle"
    bundle install --jobs "$(nproc)" --retry 3
    {
      echo "export BUNDLE_WITHOUT=\${BUNDLE_WITHOUT:-development:test}"
      echo "export PATH=\"$APP_DIR/vendor/bundle/ruby/*/bin:\$PATH\""
    } >> "$PROFILE_SNIPPET"
  else
    warn "Gemfile not found; skipping bundle install."
  fi
}

setup_go() {
  log "Configuring Go environment..."
  local pm; pm="$(detect_pkg_manager)"
  case "$pm" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
    *) warn "No package manager found for Go installation." ;;
  esac

  if ! has_cmd go; then die "go not found after installation"; fi

  export GOPATH="${GOPATH:-$APP_DIR/.gopath}"
  export GOBIN="${GOBIN:-$GOPATH/bin}"
  mkdir -p "$GOBIN"
  if [[ -f "$APP_DIR/go.mod" ]]; then
    cd "$APP_DIR"
    go env -w GOPATH="$GOPATH" || true
    go env -w GOMODCACHE="$GOPATH/pkg/mod" || true
    go mod download
  fi
  {
    echo "export GOPATH=\"${GOPATH}\""
    echo "export GOBIN=\"${GOBIN}\""
    echo 'export PATH="$GOBIN:$PATH"'
  } >> "$PROFILE_SNIPPET"
}

setup_php() {
  log "Configuring PHP environment..."
  local pm; pm="$(detect_pkg_manager)"
  case "$pm" in
    apt) pkg_install php-cli php-mbstring php-xml php-zip unzip curl ca-certificates composer ;;
    apk) pkg_install php php-cli php-mbstring php-xml php-zip unzip curl ca-certificates composer ;;
    dnf|yum) pkg_install php-cli php-mbstring php-xml php-zip unzip curl ca-certificates composer || true ;;
    zypper) pkg_install php7 php7-mbstring php7-xml php7-zip unzip curl ca-certificates composer || true ;;
    *) warn "No package manager found for PHP installation." ;;
  esac

  if [[ -f "$APP_DIR/composer.json" ]]; then
    cd "$APP_DIR"
    if ! has_cmd composer; then
      log "Installing Composer (local)..."
      EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
      php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
      ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
      if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
        rm composer-setup.php
        die "Invalid Composer installer signature"
      fi
      php composer-setup.php --install-dir=/usr/local/bin --filename=composer
      rm composer-setup.php
    fi
    composer install --no-interaction --prefer-dist --no-progress --no-suggest --optimize-autoloader || composer install --no-interaction
    echo 'export COMPOSER_ALLOW_SUPERUSER=1' >> "$PROFILE_SNIPPET"
  else
    warn "composer.json not found; skipping composer install."
  fi
}

setup_java() {
  log "Configuring Java environment..."
  local pm; pm="$(detect_pkg_manager)"
  case "$pm" in
    apt) pkg_install openjdk-17-jdk maven gradle || pkg_install default-jdk maven ;;
    apk) pkg_install openjdk17 maven gradle || pkg_install openjdk21 ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven ;;
    zypper) pkg_install java-17-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven ;;
    *) warn "No package manager found for Java installation." ;;
  esac

  if [[ -f "$APP_DIR/pom.xml" ]]; then
    cd "$APP_DIR"
    if [[ -x "./mvnw" ]]; then
      ./mvnw -B -q -DskipTests dependency:resolve || true
    else
      mvn -B -q -DskipTests dependency:resolve || true
    fi
  fi

  if [[ -f "$APP_DIR/gradlew" ]]; then
    cd "$APP_DIR"
    chmod +x ./gradlew || true
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
  elif [[ -f "$APP_DIR/build.gradle" || -f "$APP_DIR/build.gradle.kts" ]]; then
    gradle --no-daemon tasks >/dev/null 2>&1 || true
  fi
}

setup_rust() {
  log "Configuring Rust environment..."
  local pm; pm="$(detect_pkg_manager)"
  case "$pm" in
    apt) pkg_install cargo rustc ;;
    apk) pkg_install cargo rust ;;
    dnf|yum) pkg_install cargo rust ;;
    zypper) pkg_install cargo rust ;;
    *) warn "No package manager found for Rust installation." ;;
  esac

  if [[ -f "$APP_DIR/Cargo.toml" ]]; then
    cd "$APP_DIR"
    cargo fetch || true
  fi
}

# ---------------------- Environment Configuration ----------------------
write_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    log "Creating default .env file at $ENV_FILE"
    cat > "$ENV_FILE" <<'EOF'
# Generic environment defaults
APP_ENV=production
LOG_LEVEL=info
PORT=8080

# Python
PYTHONUNBUFFERED=1
PYTHONDONTWRITEBYTECODE=1

# Node
NODE_ENV=production

# Database placeholders
DB_HOST=localhost
DB_PORT=5432
DB_NAME=app
DB_USER=app
DB_PASSWORD=change_me
EOF
  else
    log ".env file already exists at $ENV_FILE"
  fi
}

persist_profile_snippet() {
  # Ensure PATH and key ENV are available when container starts an interactive shell
  if [[ ! -f "$PROFILE_SNIPPET" ]]; then
    touch "$PROFILE_SNIPPET"
  fi
  chmod 0644 "$PROFILE_SNIPPET"

  # Link the snippet to common shell init files if present and writable
  for rc in /etc/profile /etc/bash.bashrc; do
    if [[ -w "$rc" ]] && ! grep -qF "$PROFILE_SNIPPET" "$rc"; then
      echo "[ -f \"$PROFILE_SNIPPET\" ] && . \"$PROFILE_SNIPPET\"" >> "$rc" || true
    fi
  done
}

setup_auto_activate() {
  # Ensure the Python virtual environment auto-activates for interactive shells
  local bashrc_file="/root/.bashrc"
  local activate_line="[ -d \"$APP_DIR/.venv\" ] && . \"$APP_DIR/.venv/bin/activate\""
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# ---------------------- Main ----------------------
main() {
  log "Starting environment setup for project at: $APP_DIR"

  ensure_base_tools
  ensure_app_user
  setup_directories

  # Detect project components
  IFS=' ' read -r -a components <<<"$(detect_project_components)"
  if [[ ${#components[@]} -eq 0 ]]; then
    warn "No known project configuration files detected in $APP_DIR."
    warn "The script will still prepare base tools and environment files."
  else
    log "Detected project components: ${components[*]}"
  fi

  # Prepare per-component environments
  for comp in "${components[@]}"; do
    case "$comp" in
      python) setup_python ;;
      node)   setup_node ;;
      ruby)   setup_ruby ;;
      go)     setup_go ;;
      php)    setup_php ;;
      java)   setup_java ;;
      rust)   setup_rust ;;
      *) warn "Unknown component: $comp" ;;
    esac
  done

  write_env_file
  persist_profile_snippet
  setup_auto_activate

  pkg_cleanup

  # Fix permissions at the end (idempotent)
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR" || true
  fi

  log "Environment setup completed successfully."
  log "To load environment in shell: source \"$PROFILE_SNIPPET\" (usually auto-sourced)."
}

main "$@"