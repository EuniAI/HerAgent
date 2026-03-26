#!/usr/bin/env bash

# Safe, idempotent environment setup script for containerized projects
# Detects common stacks (Python, Node.js, Ruby, Java, Go, PHP, Rust, .NET) and configures accordingly.
# Designed to run inside Docker containers (typically as root). Requires network access for package installs.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Globals
PROJECT_ROOT="$(pwd)"
SETUP_DIR="$PROJECT_ROOT/.setup"
LOG_FILE="$SETUP_DIR/setup.log"
STAMP_DIR="$SETUP_DIR/stamps"
DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-}"
APP_HOME="${APP_HOME:-/home/${APP_USER:-app}}"

# Logging functions
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $*${NC}" | tee -a "$LOG_FILE" >&2; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*${NC}" | tee -a "$LOG_FILE" >&2; }
die() { error "$*"; exit 1; }

err_handler() {
  local exit_code=$1
  local line_no=$2
  error "Setup failed with exit code $exit_code at line $line_no"
}
trap 'err_handler $? $LINENO' ERR

# Ensure setup directories exist
mkdir -p "$SETUP_DIR" "$STAMP_DIR"
touch "$LOG_FILE"

# Utility functions
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
checksum() { sha256sum "$1" | awk '{print $1}'; }

# Detect OS package manager
PKG_MANAGER=""
detect_pkg_manager() {
  if has_cmd apt-get; then PKG_MANAGER="apt";
  elif has_cmd apk; then PKG_MANAGER="apk";
  elif has_cmd dnf; then PKG_MANAGER="dnf";
  elif has_cmd yum; then PKG_MANAGER="yum";
  else PKG_MANAGER=""; fi
}
detect_pkg_manager

# Run package manager update (idempotent)
pkg_update() {
  [ -z "$PKG_MANAGER" ] && warn "No package manager detected; skipping system package installation." && return 0
  if ! is_root; then
    warn "Not running as root; cannot perform system package installation."
    return 0
  fi

  local stamp="/var/lib/.project_setup_pkg_update"
  case "$PKG_MANAGER" in
    apt)
      if [ ! -f "$stamp" ]; then
        export DEBIAN_FRONTEND=noninteractive
        log "Updating apt package index..."
        apt-get update -y >>"$LOG_FILE" 2>&1 || die "apt-get update failed"
        touch "$stamp"
      else
        log "apt index already updated (stamp exists)."
      fi
      ;;
    apk)
      log "Ensuring Alpine repositories are up to date..."
      # apk doesn't have a stamp naturally; but we can skip update as apk add --no-cache refreshes indexes
      ;;
    dnf)
      if [ ! -f "$stamp" ]; then
        log "Updating dnf package metadata..."
        dnf -y makecache >>"$LOG_FILE" 2>&1 || die "dnf makecache failed"
        touch "$stamp"
      else
        log "dnf cache already updated (stamp exists)."
      fi
      ;;
    yum)
      if [ ! -f "$stamp" ]; then
        log "Updating yum package metadata..."
        yum -y makecache fast >>"$LOG_FILE" 2>&1 || die "yum makecache failed"
        touch "$stamp"
      else
        log "yum cache already updated (stamp exists)."
      fi
      ;;
  esac
}

# Install system packages in a cross-distro manner
pkg_install() {
  # Pass packages as arguments; names should be distro-specific when needed
  [ -z "$PKG_MANAGER" ] && return 0
  is_root || return 0

  case "$PKG_MANAGER" in
    apt)
      apt-get install -y --no-install-recommends "$@" >>"$LOG_FILE" 2>&1 || die "apt-get install failed for: $*"
      ;;
    apk)
      apk add --no-cache "$@" >>"$LOG_FILE" 2>&1 || die "apk add failed for: $*"
      ;;
    dnf)
      dnf install -y "$@" >>"$LOG_FILE" 2>&1 || die "dnf install failed for: $*"
      ;;
    yum)
      yum install -y "$@" >>"$LOG_FILE" 2>&1 || die "yum install failed for: $*"
      ;;
  esac
}

# Base system dependencies (build tools, CA, curl, git)
install_base_deps() {
  [ -z "$PKG_MANAGER" ] && { warn "Skipping base system dependencies; no package manager."; return 0; }
  is_root || { warn "Skipping base system dependencies; not root."; return 0; }
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git build-essential pkg-config libssl-dev libffi-dev zlib1g-dev
      ;;
    apk)
      pkg_install ca-certificates curl git build-base pkgconf openssl-dev libffi-dev zlib-dev
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gcc gcc-c++ make pkgconfig openssl-devel libffi-devel zlib-devel
      ;;
  esac
  # Clean caches when possible
  case "$PKG_MANAGER" in
    apt) apt-get clean >>"$LOG_FILE" 2>&1 || true ;;
    apk) rm -rf /var/cache/apk/* || true ;;
    dnf) dnf clean all >>"$LOG_FILE" 2>&1 || true ;;
    yum) yum clean all >>"$LOG_FILE" 2>&1 || true ;;
  esac
}

# Create application user/group if requested
ensure_app_user() {
  [ -z "$APP_USER" ] && return 0
  [ -z "$APP_GROUP" ] && APP_GROUP="$APP_USER"

  if ! is_root; then
    warn "Cannot create user/group without root privileges; proceeding as current user."
    return 0
  fi

  # Create group if not exists
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if has_cmd addgroup; then
      addgroup -S "$APP_GROUP" >>"$LOG_FILE" 2>&1 || die "addgroup failed"
    else
      groupadd -r "$APP_GROUP" >>"$LOG_FILE" 2>&1 || die "groupadd failed"
    fi
  fi
  # Create user if not exists
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    if has_cmd adduser; then
      adduser -S -G "$APP_GROUP" -h "$APP_HOME" "$APP_USER" >>"$LOG_FILE" 2>&1 || adduser -D -G "$APP_GROUP" -h "$APP_HOME" "$APP_USER" >>"$LOG_FILE" 2>&1 || die "adduser failed"
    else
      useradd -r -g "$APP_GROUP" -d "$APP_HOME" -m "$APP_USER" >>"$LOG_FILE" 2>&1 || die "useradd failed"
    fi
  fi
  mkdir -p "$APP_HOME"
  chown -R "$APP_USER:$APP_GROUP" "$APP_HOME" "$PROJECT_ROOT" "$SETUP_DIR" 2>/dev/null || true
}

# Load environment variables from .env if present (safe)
load_env_file() {
  local env_file="$PROJECT_ROOT/.env"
  if [ -f "$env_file" ]; then
    log "Loading environment from .env"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        \#*|'') continue ;;
        *'='*)
          var="${line%%=*}"
          val="${line#*=}"
          # Strip surrounding quotes
          val="${val%\"}"; val="${val#\"}"
          val="${val%\'}"; val="${val#\'}"
          export "$var=$val"
          ;;
      esac
    done < "$env_file"
  fi
}

# Extend PATH with common local bins
configure_path() {
  local path_file="/etc/profile.d/project_path.sh"
  local add_paths=("$PROJECT_ROOT/.venv/bin" "$PROJECT_ROOT/venv/bin" "$PROJECT_ROOT/.local/bin" "$PROJECT_ROOT/node_modules/.bin" "/usr/local/bin")
  for p in "${add_paths[@]}"; do
    if [ -d "$p" ] && [[ ":$PATH:" != *":$p:"* ]]; then
      export PATH="$p:$PATH"
    fi
  done

  if is_root; then
    {
      echo "#!/usr/bin/env bash"
      echo "export PATH=\"$PROJECT_ROOT/.venv/bin:$PROJECT_ROOT/venv/bin:$PROJECT_ROOT/.local/bin:$PROJECT_ROOT/node_modules/.bin:\$PATH\""
    } > "$path_file"
    chmod 0644 "$path_file" || true
  else
    # Non-root: write a local script
    {
      echo "export PATH=\"$PROJECT_ROOT/.venv/bin:$PROJECT_ROOT/venv/bin:$PROJECT_ROOT/.local/bin:$PROJECT_ROOT/node_modules/.bin:\$PATH\""
    } > "$SETUP_DIR/path.sh"
  fi
}

# Persist venv auto-activation into shell init
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local activate_line='source "$PROJECT_ROOT/.venv/bin/activate"'
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate Python virtual environment"
      echo "if [ -d \"\$PROJECT_ROOT/.venv\" ] && [ -f \"\$PROJECT_ROOT/.venv/bin/activate\" ]; then"
      echo "  $activate_line"
      echo "fi"
    } >> "$bashrc_file"
  fi
}

# Create standard project directories
setup_project_dirs() {
  for d in "logs" "tmp" "run" "data" ".cache"; do
    mkdir -p "$PROJECT_ROOT/$d"
  done
  if [ -n "$APP_USER" ] && is_root; then
    chown -R "$APP_USER:${APP_GROUP:-$APP_USER}" "$PROJECT_ROOT" || true
  fi
}

# Detect project types
detect_project_types() {
  local types=()
  [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/Pipfile" ] && types+=("python")
  [ -f "$PROJECT_ROOT/package.json" ] && types+=("node")
  [ -f "$PROJECT_ROOT/Gemfile" ] && types+=("ruby")
  [ -f "$PROJECT_ROOT/pom.xml" ] && types+=("maven")
  [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ] && types+=("gradle")
  [ -f "$PROJECT_ROOT/go.mod" ] && types+=("go")
  [ -f "$PROJECT_ROOT/composer.json" ] && types+=("php")
  [ -f "$PROJECT_ROOT/Cargo.toml" ] && types+=("rust")
  # .NET: any csproj or fsproj
  if ls "$PROJECT_ROOT"/*.csproj "$PROJECT_ROOT"/*.fsproj >/dev/null 2>&1; then types+=(".net"); fi

  echo "${types[@]:-}"
}

# Python setup
setup_python() {
  log "Configuring Python environment..."
  case "$PKG_MANAGER" in
    apt) pkg_install python3 python3-venv python3-pip python3-dev ;;
    apk) pkg_install python3 py3-pip ;;
    dnf|yum) pkg_install python3 python3-pip python3-devel ;;
    *) if ! has_cmd python3; then warn "No package manager; Python3 not found. Skipping Python setup."; return 0; fi ;;
  esac
  # Ensure venv exists
  local venv_dir="$PROJECT_ROOT/.venv"
  if [ ! -d "$venv_dir" ] || [ ! -f "$venv_dir/bin/activate" ]; then
    log "Creating virtual environment at $venv_dir"
    python3 -m venv "$venv_dir" >>"$LOG_FILE" 2>&1 || die "Failed to create Python venv"
  else
    log "Python virtual environment already exists."
  fi
  # Activate and install dependencies
  # shellcheck disable=SC1091
  source "$venv_dir/bin/activate"
  python3 -m pip install --upgrade pip wheel setuptools >>"$LOG_FILE" 2>&1 || die "pip upgrade failed"

  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    local req="$PROJECT_ROOT/requirements.txt"
    local req_hash
    req_hash="$(checksum "$req")"
    local stamp="$STAMP_DIR/python_requirements_${req_hash}.stamp"
    if [ ! -f "$stamp" ]; then
      log "Installing Python dependencies from requirements.txt"
      PIP_NO_CACHE_DIR=1 pip install -r "$req" >>"$LOG_FILE" 2>&1 || die "pip install -r requirements.txt failed"
      echo "ok" > "$stamp"
    else
      log "Python requirements already installed (stamp exists)."
    fi
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    # Basic support for PEP 517 projects
    log "Installing Python project via pyproject.toml"
    PIP_NO_CACHE_DIR=1 pip install . >>"$LOG_FILE" 2>&1 || warn "pip install . failed; check pyproject configuration"
  fi

  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1
}

# Node.js setup
setup_node() {
  log "Configuring Node.js environment..."
  if ! has_cmd node || ! has_cmd npm; then
    case "$PKG_MANAGER" in
      apt) pkg_install nodejs npm ;;
      apk) pkg_install nodejs npm ;;
      dnf|yum) pkg_install nodejs npm ;;
      *) warn "No package manager or Node.js unavailable; skipping Node.js setup."; return 0 ;;
    esac
  fi
  export NODE_ENV="${NODE_ENV:-production}"
  # Install dependencies
  local lockfile=""
  if [ -f "$PROJECT_ROOT/package-lock.json" ]; then lockfile="package-lock.json"; fi
  if [ -f "$PROJECT_ROOT/yarn.lock" ]; then lockfile="yarn.lock"; fi
  if [ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]; then lockfile="pnpm-lock.yaml"; fi

  if [ -n "$lockfile" ]; then
    local hash
    hash="$(checksum "$PROJECT_ROOT/$lockfile")"
    local stamp="$STAMP_DIR/node_${lockfile}_${hash}.stamp"
    if [ ! -f "$stamp" ]; then
      if [ "$lockfile" = "yarn.lock" ] && has_cmd yarn; then
        log "Installing Node dependencies via yarn (locked)"
        yarn install --frozen-lockfile >>"$LOG_FILE" 2>&1 || die "yarn install failed"
      elif [ "$lockfile" = "pnpm-lock.yaml" ] && has_cmd pnpm; then
        log "Installing Node dependencies via pnpm (locked)"
        pnpm install --frozen-lockfile >>"$LOG_FILE" 2>&1 || die "pnpm install failed"
      else
        log "Installing Node dependencies via npm ci"
        npm ci --no-audit --no-fund >>"$LOG_FILE" 2>&1 || die "npm ci failed"
      fi
      echo "ok" > "$stamp"
    else
      log "Node dependencies already installed (stamp exists)."
    fi
  else
    if [ -f "$PROJECT_ROOT/package.json" ]; then
      local stamp="$STAMP_DIR/node_package_json_$(checksum "$PROJECT_ROOT/package.json").stamp"
      if [ ! -f "$stamp" ]; then
        log "Installing Node dependencies via npm install"
        npm install --no-audit --no-fund >>"$LOG_FILE" 2>&1 || die "npm install failed"
        echo "ok" > "$stamp"
      else
        log "Node dependencies already installed (stamp exists)."
      fi
    fi
  fi
}

# Ruby setup
setup_ruby() {
  log "Configuring Ruby environment..."
  case "$PKG_MANAGER" in
    apt) pkg_install ruby-full build-essential ;;
    apk) pkg_install ruby ruby-dev build-base ;;
    dnf|yum) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
    *) if ! has_cmd ruby; then warn "Ruby not available; skipping Ruby setup."; return 0; fi ;;
  esac
  if ! has_cmd bundle; then
    log "Installing bundler"
    gem install bundler --no-document >>"$LOG_FILE" 2>&1 || warn "Failed to install bundler"
  fi
  if [ -f "$PROJECT_ROOT/Gemfile" ]; then
    local lock="$PROJECT_ROOT/Gemfile.lock"
    local hash="nogemlock"
    [ -f "$lock" ] && hash="$(checksum "$lock")"
    local stamp="$STAMP_DIR/ruby_bundle_${hash}.stamp"
    if [ ! -f "$stamp" ]; then
      log "Installing Ruby gems via bundler"
      bundle config set --local path 'vendor/bundle' >>"$LOG_FILE" 2>&1 || true
      bundle install --jobs 4 >>"$LOG_FILE" 2>&1 || die "bundle install failed"
      echo "ok" > "$stamp"
    else
      log "Ruby gems already installed (stamp exists)."
    fi
  fi
}

# Java (Maven/Gradle) setup
setup_java() {
  if [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ]; then
    log "Configuring Java environment..."
    case "$PKG_MANAGER" in
      apt) pkg_install openjdk-17-jdk maven gradle ;;
      apk) pkg_install openjdk17 maven gradle ;;
      dnf|yum) pkg_install java-17-openjdk java-17-openjdk-devel maven gradle ;;
      *) if ! has_cmd java; then warn "Java not available; skipping Java setup."; return 0; fi ;;
    esac
    export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
    if [ -f "$PROJECT_ROOT/pom.xml" ]; then
      local stamp="$STAMP_DIR/maven_$(checksum "$PROJECT_ROOT/pom.xml").stamp"
      if [ ! -f "$stamp" ]; then
        log "Resolving Maven dependencies"
        mvn -B -DskipTests dependency:resolve >>"$LOG_FILE" 2>&1 || warn "Maven dependency resolution failed"
        echo "ok" > "$stamp"
      else
        log "Maven dependencies already resolved (stamp exists)."
      fi
    fi
    if [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ]; then
      local gradle_file="$PROJECT_ROOT/build.gradle"
      [ -f "$gradle_file" ] || gradle_file="$PROJECT_ROOT/settings.gradle"
      local stamp="$STAMP_DIR/gradle_$(checksum "$gradle_file").stamp"
      if [ ! -f "$stamp" ]; then
        log "Resolving Gradle dependencies"
        gradle --no-daemon build -x test >>"$LOG_FILE" 2>&1 || warn "Gradle build failed"
        echo "ok" > "$stamp"
      else
        log "Gradle dependencies already resolved (stamp exists)."
      fi
    fi
  fi
}

# Go setup
setup_go() {
  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    log "Configuring Go environment..."
    case "$PKG_MANAGER" in
      apt) pkg_install golang ;;
      apk) pkg_install go ;;
      dnf|yum) pkg_install golang ;;
      *) if ! has_cmd go; then warn "Go not available; skipping Go setup."; return 0; fi ;;
    esac
    export GOPATH="${GOPATH:-$PROJECT_ROOT/.gopath}"
    mkdir -p "$GOPATH"
    export GOCACHE="$PROJECT_ROOT/.cache/go"
    local stamp="$STAMP_DIR/go_mod_$(checksum "$PROJECT_ROOT/go.mod").stamp"
    if [ ! -f "$stamp" ]; then
      log "Fetching Go module dependencies"
      go mod download >>"$LOG_FILE" 2>&1 || warn "go mod download failed"
      echo "ok" > "$stamp"
    else
      log "Go modules already downloaded (stamp exists)."
    fi
  fi
}

# PHP setup
setup_php() {
  if [ -f "$PROJECT_ROOT/composer.json" ]; then
    log "Configuring PHP environment..."
    case "$PKG_MANAGER" in
      apt) pkg_install php-cli composer ;;
      apk) pkg_install php-cli composer ;;
      dnf|yum) pkg_install php-cli composer ;;
      *) if ! has_cmd php; then warn "PHP not available; skipping PHP setup."; return 0; fi ;;
    esac
    local lock="$PROJECT_ROOT/composer.lock"
    local hash="nocomposerlock"
    [ -f "$lock" ] && hash="$(checksum "$lock")"
    local stamp="$STAMP_DIR/composer_${hash}.stamp"
    if [ ! -f "$stamp" ]; then
      log "Installing PHP dependencies via composer"
      composer install --no-interaction --no-progress --prefer-dist >>"$LOG_FILE" 2>&1 || die "composer install failed"
      echo "ok" > "$stamp"
    else
      log "Composer dependencies already installed (stamp exists)."
    fi
  fi
}

# Rust setup
setup_rust() {
  if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    log "Configuring Rust environment..."
    case "$PKG_MANAGER" in
      apt) pkg_install rustc cargo ;;
      apk) pkg_install rust cargo ;;
      dnf|yum) pkg_install rust cargo ;;
      *) if ! has_cmd cargo; then warn "Rust not available; skipping Rust setup."; return 0; fi ;;
    esac
    local stamp="$STAMP_DIR/cargo_$(checksum "$PROJECT_ROOT/Cargo.toml").stamp"
    if [ ! -f "$stamp" ]; then
      log "Fetching Rust crate dependencies"
      cargo fetch >>"$LOG_FILE" 2>&1 || warn "cargo fetch failed"
      echo "ok" > "$stamp"
    else
      log "Rust dependencies already fetched (stamp exists)."
    fi
  fi
}

# .NET setup (limited: requires preinstalled dotnet SDK or package manager configuration)
setup_dotnet() {
  if ls "$PROJECT_ROOT"/*.csproj "$PROJECT_ROOT"/*.fsproj >/dev/null 2>&1; then
    log "Configuring .NET environment..."
    if has_cmd dotnet; then
      local stamp="$STAMP_DIR/dotnet_restore.stamp"
      if [ ! -f "$stamp" ]; then
        log "Restoring .NET dependencies"
        dotnet restore >>"$LOG_FILE" 2>&1 || warn "dotnet restore failed"
        echo "ok" > "$stamp"
      else
        log ".NET dependencies already restored (stamp exists)."
      fi
    else
      warn "dotnet SDK not found. Install the SDK in the base image or extend script to add Microsoft repositories."
    fi
  fi
}

# Set common environment variables
setup_common_env() {
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export TZ="${TZ:-UTC}"
  export APP_ENV="${APP_ENV:-production}"
  export PROJECT_ROOT

  # Write environment to profile for future shells (if root)
  if is_root; then
    {
      echo "export LANG=\"$LANG\""
      echo "export LC_ALL=\"$LC_ALL\""
      echo "export TZ=\"$TZ\""
      echo "export APP_ENV=\"$APP_ENV\""
      echo "export PROJECT_ROOT=\"$PROJECT_ROOT\""
    } > /etc/profile.d/project_env.sh
    chmod 0644 /etc/profile.d/project_env.sh || true
  else
    {
      echo "export LANG=\"$LANG\""
      echo "export LC_ALL=\"$LC_ALL\""
      echo "export TZ=\"$TZ\""
      echo "export APP_ENV=\"$APP_ENV\""
      echo "export PROJECT_ROOT=\"$PROJECT_ROOT\""
    } > "$SETUP_DIR/env.sh"
  fi
}

# Main setup
main() {
  log "Starting project environment setup in $PROJECT_ROOT"
  load_env_file
  install_base_deps
  ensure_app_user
  setup_project_dirs
  setup_common_env
  configure_path
  setup_auto_activate

  local types
  types="$(detect_project_types)"
  if [ -z "$types" ]; then
    warn "No specific project type detected. The script installed base tools and configured environment."
  else
    log "Detected project types: $types"
    for t in $types; do
      case "$t" in
        python) setup_python ;;
        node) setup_node ;;
        ruby) setup_ruby ;;
        maven|gradle) setup_java ;;
        go) setup_go ;;
        php) setup_php ;;
        rust) setup_rust ;;
        .net) setup_dotnet ;;
        *) warn "Unknown project type: $t" ;;
      esac
    done
  fi

  # Final perms if app user specified
  if [ -n "$APP_USER" ] && is_root; then
    chown -R "$APP_USER:${APP_GROUP:-$APP_USER}" "$PROJECT_ROOT" || true
  fi

  log "Environment setup completed successfully."
  log "Logs available at $LOG_FILE"
  log "Useful paths added to PATH: .venv/bin, node_modules/.bin, .local/bin"
  if [ -d "$PROJECT_ROOT/.venv" ]; then
    echo -e "${BLUE}To activate Python venv: source \"$PROJECT_ROOT/.venv/bin/activate\"${NC}"
  fi
}

main "$@"