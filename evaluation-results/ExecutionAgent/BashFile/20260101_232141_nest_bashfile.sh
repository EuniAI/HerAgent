#!/usr/bin/env bash
# Environment setup script for a Node.js (TypeScript/NestJS) project inside Docker containers.

set -Eeuo pipefail
IFS=$'\n\t'

#------------------------------
# Logging and error handling
#------------------------------
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'

log() { echo -e "${COLOR_GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${COLOR_RESET}"; }
warn() { echo -e "${COLOR_YELLOW}[WARNING] $*${COLOR_RESET}" >&2; }
err() { echo -e "${COLOR_RED}[ERROR] $*${COLOR_RESET}" >&2; }

on_error() {
  err "Setup failed at line $1. Inspect the logs above for details."
  exit 1
}
trap 'on_error $LINENO' ERR

#------------------------------
# Configuration
#------------------------------
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
DEFAULT_NODE_VERSION="${DEFAULT_NODE_VERSION:-20.18.0}"   # Pin a Node.js 20 LTS patch version for tarball fallback
REQUIRED_NODE_MAJOR="${REQUIRED_NODE_MAJOR:-20}"
NODE_INSTALL_DIR="${NODE_INSTALL_DIR:-/opt/node}"
NPM_CACHE_DIR="${NPM_CACHE_DIR:-${PROJECT_ROOT}/.npm-cache}"
YARN_CACHE_DIR="${YARN_CACHE_DIR:-${PROJECT_ROOT}/.yarn-cache}"
PNPM_STORE_DIR="${PNPM_STORE_DIR:-${PROJECT_ROOT}/.pnpm-store}"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
SKIP_BUILD="${SKIP_BUILD:-0}"  # set to 1 to skip building the project
NODE_ENV_VALUE="${NODE_ENV:-development}" # default to development for library/monorepo

#------------------------------
# Helpers
#------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

version_ge() {
  # Compare two semver-like versions: returns 0 if $1 >= $2
  # Usage: version_ge "20.18.0" "20.0.0"
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

detect_like() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "${ID_LIKE:-}"
  else
    echo ""
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "unsupported" ;;
  esac
}

is_musl() {
  if has_cmd ldd; then
    if ldd --version 2>&1 | grep -qi musl; then
      return 0
    fi
  fi
  return 1
}

ensure_dir() {
  local d="$1"
  [ -d "$d" ] || mkdir -p "$d"
}

#------------------------------
# System package installation
#------------------------------
install_system_packages() {
  log "Installing required system packages..."
  local os_id; os_id="$(detect_os)"
  local os_like; os_like="$(detect_like)"

  if [ "$os_id" = "alpine" ]; then
    # Alpine Linux
    apk update || true
    apk add --no-cache \
      bash curl ca-certificates git tar xz \
      python3 make g++ build-base \
      openssl pkgconfig libc6-compat
    update-ca-certificates || true
  elif [ "$os_id" = "debian" ] || [ "$os_id" = "ubuntu" ] || echo "$os_like" | grep -qi "debian"; then
    export DEBIAN_FRONTEND=noninteractive
    # Update only if needed or lists are empty
    if [ ! -d /var/lib/apt/lists ] || [ -z "$(ls -A /var/lib/apt/lists 2>/dev/null || true)" ]; then
      apt-get update
    else
      apt-get update -y || true
    fi
    apt-get install -y --no-install-recommends \
      bash curl ca-certificates git tar xz-utils \
      python3 make g++ build-essential \
      openssl pkg-config gnupg docker.io
    update-ca-certificates || true
    rm -rf /var/lib/apt/lists/*
  elif [ "$os_id" = "fedora" ] || [ "$os_id" = "centos" ] || [ "$os_id" = "rhel" ] || echo "$os_like" | grep -qi "rhel\|fedora\|centos"; then
    if has_cmd dnf; then
      dnf install -y \
        bash curl ca-certificates git tar xz \
        python3 make gcc gcc-c++ \
        openssl pkgconf
    else
      yum install -y \
        bash curl ca-certificates git tar xz \
        python3 make gcc gcc-c++ \
        openssl pkgconfig
    fi
  else
    warn "Unknown OS. Attempting to proceed with minimal checks. Please ensure curl, git, tar, xz, python3, make, g++ are installed."
  fi
  log "System packages installation complete."
}

#------------------------------
# Node.js installation
#------------------------------
ensure_node() {
  local node_ok="0"
  if has_cmd node; then
    local ver; ver="$(node -v | sed 's/^v//')"
    local major="${ver%%.*}"
    if [ "$major" -eq "$REQUIRED_NODE_MAJOR" ]; then
      node_ok="1"
      log "Found Node.js v$ver (major == $REQUIRED_NODE_MAJOR)."
    else
      warn "Found Node.js v$ver (major != $REQUIRED_NODE_MAJOR). Will install Node.js ${REQUIRED_NODE_MAJOR}.x."
    fi
  fi

  if [ "$node_ok" = "1" ]; then
    return 0
  fi

  local os_id; os_id="$(detect_os)"
  local installed="0"

  # Try OS package managers first where feasible
  if [ "$os_id" = "alpine" ]; then
    # Alpine repositories may have nodejs-current; try it
    if apk search -qe nodejs-current 2>/dev/null; then
      apk add --no-cache nodejs-current npm || true
      if has_cmd node; then
        local ver; ver="$(node -v | sed 's/^v//')"; local major="${ver%%.*}"
        if [ "$major" -ge "$REQUIRED_NODE_MAJOR" ]; then
          installed="1"
        fi
      fi
    else
      # Fallback to nodejs/npm
      apk add --no-cache nodejs npm || true
      if has_cmd node; then
        local ver; ver="$(node -v | sed 's/^v//')"; local major="${ver%%.*}"
        if [ "$major" -ge "$REQUIRED_NODE_MAJOR" ]; then
          installed="1"
        fi
      fi
    fi
  elif [ "$os_id" = "debian" ] || [ "$os_id" = "ubuntu" ] || echo "$(detect_like)" | grep -qi "debian"; then
    # Install via NodeSource repo
    if has_cmd curl && [ -d /etc/apt ]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y || true
      apt-get install -y curl ca-certificates gnupg || true
      curl -fsSL "https://deb.nodesource.com/setup_${REQUIRED_NODE_MAJOR}.x" | bash - || true
      apt-get install -y nodejs || true
      if has_cmd node; then
        local ver; ver="$(node -v | sed 's/^v//')"; local major="${ver%%.*}"
        if [ "$major" -eq "$REQUIRED_NODE_MAJOR" ]; then
          installed="1"
        fi
      fi
      rm -rf /var/lib/apt/lists/* || true
    fi
  elif [ "$os_id" = "fedora" ] || [ "$os_id" = "centos" ] || [ "$os_id" = "rhel" ] || echo "$(detect_like)" | grep -qi "rhel\|fedora\|centos"; then
    # Use dnf/yum module streams if available
    if has_cmd dnf; then
      dnf module enable -y nodejs:${REQUIRED_NODE_MAJOR} || true
      dnf install -y nodejs || true
    else
      yum module enable -y nodejs:${REQUIRED_NODE_MAJOR} || true
      yum install -y nodejs || true
    fi
    if has_cmd node; then
      local ver; ver="$(node -v | sed 's/^v//')"; local major="${ver%%.*}"
      if [ "$major" -ge "$REQUIRED_NODE_MAJOR" ]; then
        installed="1"
      fi
    fi
  fi

  if [ "$installed" = "1" ]; then
    log "Node.js installed via system manager."
  else
    # Fallback: download official Node.js binary tarball and install to /opt/node
    log "Installing Node.js ${DEFAULT_NODE_VERSION} from official tarball..."
    local arch; arch="$(detect_arch)"
    if [ "$arch" = "unsupported" ]; then
      err "Unsupported architecture $(uname -m). Only x64 and arm64 are supported by this script."
      exit 1
    fi
    local flavor="linux"
    if is_musl; then
      flavor="linux-musl"
    fi
    ensure_dir "$NODE_INSTALL_DIR"
    local tarball="node-v${DEFAULT_NODE_VERSION}-${flavor}-${arch}.tar.xz"
    local base_url="https://nodejs.org/dist/v${DEFAULT_NODE_VERSION}"
    curl -fsSL "${base_url}/${tarball}" -o "/tmp/${tarball}"
    tar -xJf "/tmp/${tarball}" -C "$NODE_INSTALL_DIR" --strip-components=1
    rm -f "/tmp/${tarball}"

    # Symlink to /usr/local/bin for convenience
    for b in node npm npx corepack; do
      if [ -f "$NODE_INSTALL_DIR/bin/$b" ]; then
        ln -sf "$NODE_INSTALL_DIR/bin/$b" "/usr/local/bin/$b"
      fi
    done

    if has_cmd node; then
      local ver; ver="$(node -v | sed 's/^v//')"
      log "Installed Node.js v$ver at $NODE_INSTALL_DIR"
      local major="${ver%%.*}"
      if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
        err "Installed Node.js major version $major is less than required $REQUIRED_NODE_MAJOR."
        exit 1
      fi
    else
      err "Node.js installation failed."
      exit 1
    fi
  fi

  # Ensure corepack is available and enabled
  if has_cmd corepack; then
    corepack enable || true
  fi
}

install_n_and_use_lts() {
  # Upgrade npm to v11 globally to ensure consistent CLI behavior
  if has_cmd npm; then
    log "Upgrading npm to v11 globally..."
    npm install -g npm@11 || true
  else
    warn "npm not available; cannot upgrade npm globally."
  fi
}

#------------------------------
# Runtime environment config
#------------------------------
configure_runtime_env() {
  log "Configuring runtime environment variables..."
  export NODE_ENV="${NODE_ENV_VALUE}"
  export NPM_CONFIG_CACHE="${NPM_CACHE_DIR}"
  export npm_config_loglevel="${npm_config_loglevel:-warn}"
  export CI="${CI:-true}"

  ensure_dir "${NPM_CACHE_DIR}"
  ensure_dir "${YARN_CACHE_DIR}"
  ensure_dir "${PNPM_STORE_DIR}"

  # Create a local .npmrc idempotently to direct cache and disable some noise
  if [ -f "${PROJECT_ROOT}/.npmrc" ]; then
    if ! grep -q "^cache=" "${PROJECT_ROOT}/.npmrc" 2>/dev/null; then
      echo "cache=${NPM_CACHE_DIR}" >> "${PROJECT_ROOT}/.npmrc"
    fi
    if ! grep -q "^fund=false" "${PROJECT_ROOT}/.npmrc" 2>/dev/null; then
      echo "fund=false" >> "${PROJECT_ROOT}/.npmrc"
    fi
    if ! grep -q "^audit=false" "${PROJECT_ROOT}/.npmrc" 2>/dev/null; then
      echo "audit=false" >> "${PROJECT_ROOT}/.npmrc"
    fi
    if ! grep -q "^legacy-peer-deps=" "${PROJECT_ROOT}/.npmrc" 2>/dev/null; then
      printf "\nlegacy-peer-deps=true\n" >> "${PROJECT_ROOT}/.npmrc"
    fi
  else
    cat > "${PROJECT_ROOT}/.npmrc" <<EOF
cache=${NPM_CACHE_DIR}
fund=false
audit=false
loglevel=warn
legacy-peer-deps=true
EOF
  fi

  # Load .env if present
  if [ -f "$ENV_FILE" ]; then
    set -o allexport
    # shellcheck source=/dev/null
    . "$ENV_FILE" || true
    set +o allexport
    log "Loaded environment variables from $ENV_FILE"
  fi

  # Add Node.js to PATH if installed via tarball
  if [ -d "$NODE_INSTALL_DIR/bin" ]; then
    export PATH="$NODE_INSTALL_DIR/bin:$PATH"
  fi

  # Configure registry override if provided
  if [ -n "${NPM_REGISTRY_URL:-}" ]; then
    npm config set registry "${NPM_REGISTRY_URL}" || true
  fi

  npm config set fund false || true
  npm config set audit false || true
}

#------------------------------
# Project directory setup
#------------------------------
setup_directories_and_permissions() {
  log "Setting up project directories and permissions..."
  cd "$PROJECT_ROOT"

  ensure_dir "$PROJECT_ROOT/node_modules"
  ensure_dir "$PROJECT_ROOT/dist"
  ensure_dir "$PROJECT_ROOT/logs"

  # Assign ownership to the current user (root in most Docker images)
  chown -R "$(id -u)":"$(id -g)" "$PROJECT_ROOT" || true
}

#------------------------------
# JavaScript dependency installation
#------------------------------
detect_package_manager() {
  if [ -f "${PROJECT_ROOT}/pnpm-lock.yaml" ]; then
    echo "pnpm"
  elif [ -f "${PROJECT_ROOT}/yarn.lock" ]; then
    echo "yarn"
  else
    echo "npm"
  fi
}

install_js_dependencies() {
  log "Installing JavaScript/TypeScript dependencies..."
  cd "$PROJECT_ROOT"

  # Clean install: clean npm cache and remove existing node_modules and lockfile to avoid conflicts
  HUSKY=0 npm cache clean --force || true
  rm -rf node_modules package-lock.json

  if [ ! -f "package.json" ]; then
    warn "No package.json found in ${PROJECT_ROOT}. Skipping dependency installation."
    return 0
  fi

  local pm; pm="$(detect_package_manager)"
  case "$pm" in
    pnpm)
      if has_cmd corepack; then corepack enable || true; fi
      # Prepare specific version if desired
      if has_cmd corepack; then corepack prepare pnpm@latest --activate || true; fi
      if ! has_cmd pnpm; then
        npx --yes pnpm@latest --version >/dev/null 2>&1 || true
      fi
      export PNPM_HOME="${PROJECT_ROOT}/.pnpm"
      ensure_dir "$PNPM_HOME"
      export PATH="${PNPM_HOME}:$PATH"
      if [ -f "pnpm-lock.yaml" ]; then
        pnpm install --frozen-lockfile --prefer-offline --store-dir "${PNPM_STORE_DIR}" || pnpm install --store-dir "${PNPM_STORE_DIR}"
      else
        pnpm install --store-dir "${PNPM_STORE_DIR}"
      fi
      ;;
    yarn)
      if has_cmd corepack; then corepack enable || true; fi
      if has_cmd corepack; then corepack prepare yarn@stable --activate || true; fi
      if [ -f "yarn.lock" ]; then
        yarn install --frozen-lockfile --cache-folder "${YARN_CACHE_DIR}" || yarn install --cache-folder "${YARN_CACHE_DIR}"
      else
        yarn install --cache-folder "${YARN_CACHE_DIR}"
      fi
      ;;
    npm|*)
      # Prefer CI if lockfile exists; skip husky hooks; fallback to npm install
      HUSKY=0 npm ci --no-audit --no-fund || HUSKY=0 npm install --no-audit --no-fund
      ;;
  esac
  # Ensure gRPC-related dependencies are pinned for gRPC server initialization
  if [ -f "package.json" ]; then
    HUSKY=0 npm install --no-audit --no-fund @grpc/grpc-js@^1.9.12 @grpc/proto-loader@^0.7.8 || true
    npm pkg set scripts.start="echo 'No start script defined; skipping server start for CI'" || true
  fi
  log "Dependencies installed using $pm."
}

#------------------------------
# Build / Compile (TypeScript)
#------------------------------
maybe_build_project() {
  cd "$PROJECT_ROOT"
  if [ "$SKIP_BUILD" = "1" ]; then
    log "SKIP_BUILD=1, skipping build step."
    return 0
  fi

  if [ ! -f "package.json" ]; then
    warn "No package.json found; skipping build."
    return 0
  fi

  # Check if a build script exists
  if node -e "const p=require('./package.json');process.exit(p.scripts && p.scripts.build?0:1)" 2>/dev/null; then
    log "Running project build script (if present)..."
    npm run build --if-present
  else
    log "No build script defined in package.json. Skipping build."
  fi
}

#------------------------------
# MySQL (Docker) provisioning for integration tests
#------------------------------
provision_mysql_for_integration() {
  log "Provisioning MySQL via Docker for integration tests..."
  # Attempt to ensure Docker is installed on Debian/Ubuntu
  if [ -d /etc/apt ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y docker.io || true
  fi

  if ! has_cmd docker; then
    warn "Docker not available; skipping MySQL container setup."
    return 0
  fi

  docker rm -f test-mysql || true
  docker run -d --name test-mysql \
    -e MYSQL_ROOT_PASSWORD=secret \
    -e MYSQL_DATABASE=test \
    -p 127.0.0.1:3306:3306 mysql:8.0 || {
    warn "Failed to start MySQL docker container."
    return 0
  }

  bash -c "until docker exec test-mysql mysqladmin ping -h 127.0.0.1 -uroot -psecret --silent; do sleep 2; done" || true

  export TYPEORM_HOST=127.0.0.1
  export TYPEORM_PORT=3306
  export TYPEORM_USERNAME=root
  export TYPEORM_PASSWORD=secret
  export TYPEORM_DATABASE=test
}

#------------------------------
# Post-setup info
#------------------------------
print_summary() {
  cd "$PROJECT_ROOT"
  log "Environment setup completed."

  if [ -f "package.json" ]; then
    local pm; pm="$(detect_package_manager)"
    echo "Project root: $PROJECT_ROOT"
    echo "Node version: $(node -v)"
    echo "Package manager: $pm"
    echo "NODE_ENV: ${NODE_ENV}"
    echo "Common commands you may run:"
    echo " - Install deps again: ${pm} install"
    if node -e "const p=require('./package.json');process.exit(p.scripts && p.scripts.build?0:1)" 2>/dev/null; then
      echo " - Build: npm run build"
    fi
    if node -e "const p=require('./package.json');process.exit(p.scripts && p.scripts.start?0:1)" 2>/dev/null; then
      echo " - Start: npm run start"
    fi
    if node -e "const p=require('./package.json');process.exit(p.scripts && p.scripts.test?0:1)" 2>/dev/null; then
      echo " - Test: npm test"
    fi
  else
    echo "No package.json detected. Ensure you are in a Node.js project directory."
  fi
}

#------------------------------
# Main
#------------------------------
main() {
  log "Starting environment setup in Docker container..."
  log "Project root: $PROJECT_ROOT"

  install_system_packages
  ensure_node
  install_n_and_use_lts
  configure_runtime_env
  setup_directories_and_permissions
  install_js_dependencies
  provision_mysql_for_integration
  maybe_build_project
  print_summary
}

main "$@"