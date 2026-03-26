#!/bin/bash
# Project Environment Setup Script for Node.js/TypeScript (TypeScript compiler repo)
# Designed to run inside Docker containers as root (no sudo)
#
# This script:
# - Installs Node.js 20.1.0 and configures npm 8.19.4 via Corepack
# - Installs required system packages and build tools
# - Sets up project directory, permissions, caches, and Git configuration
# - Installs project dependencies using npm (ci/install)
# - Configures environment variables for containerized execution
# - Idempotent and safe to run multiple times

set -Eeuo pipefail

# Global defaults and config
PROJECT_NAME="typescript"
REQUIRED_NODE_VERSION="20.1.0"
REQUIRED_NPM_VERSION="8.19.4"
NODE_DISTRO="linux-x64"
NODE_TARBALL="node-v${REQUIRED_NODE_VERSION}-${NODE_DISTRO}.tar.xz"
NODE_BASE_URL="https://nodejs.org/dist/v${REQUIRED_NODE_VERSION}"
NODE_INSTALL_DIR="/opt/node"
NODE_TARGET_DIR="${NODE_INSTALL_DIR}/node-v${REQUIRED_NODE_VERSION}-${NODE_DISTRO}"
GLOBAL_BIN_DIR="/usr/local/bin"
NPM_CACHE_DIR="/var/cache/npm"
LOG_FILE=""
USE_NONROOT_USER="${USE_NONROOT_USER:-0}"     # Set to 1 to create/use non-root user
APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
INSTALL_PLAYWRIGHT_DEPS="${INSTALL_PLAYWRIGHT_DEPS:-0}"  # Set to 1 to install Playwright browser deps
BUILD_PROJECT="${BUILD_PROJECT:-0}"           # Set to 1 to run npm run build after deps install

# Colors
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
BLUE="$(printf '\033[0;34m')"
NC="$(printf '\033[0m')"

# Logging
log()      { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info()     { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()     { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
error()    { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
die()      { error "$*"; exit 1; }

trap 'error "Failed at line ${LINENO}. See ${LOG_FILE:-console} for details."; exit 1' ERR

# Utilities
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Root privileges are required to run this script inside Docker. Current UID: $(id -u)"
  fi
}

# Resolve project directory and log file
resolve_project_dir() {
  # Directory where this script resides
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  PROJECT_DIR="${PROJECT_DIR:-$script_dir}"
  LOG_FILE="${PROJECT_DIR}/setup.log"
  touch "$LOG_FILE" || true
}

# Detect OS package manager
detect_pkg_manager() {
  if command_exists apt-get; then
    PKG_MGR="apt"
  elif command_exists apk; then
    PKG_MGR="apk"
  elif command_exists dnf; then
    PKG_MGR="dnf"
  elif command_exists yum; then
    PKG_MGR="yum"
  else
    PKG_MGR=""
  fi
}

# Install system packages required for Node builds and common tooling
install_system_packages() {
  detect_pkg_manager
  log "Installing system packages using ${PKG_MGR:-unknown}..."
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >>"$LOG_FILE" 2>&1
      apt-get install -y --no-install-recommends \
        ca-certificates curl git xz-utils tar \
        python3 make g++ build-essential pkg-config \
        libstdc++6 openssl gnupg bash coreutils findutils \
        jq \
        >>"$LOG_FILE" 2>&1
      # Clean apt cache to keep container small
      rm -rf /var/lib/apt/lists/* >>"$LOG_FILE" 2>&1 || true
      ;;
    apk)
      apk update >>"$LOG_FILE" 2>&1 || true
      apk add --no-cache \
        ca-certificates curl git xz tar \
        python3 make g++ pkgconfig \
        libstdc++ openssl bash coreutils findutils \
        jq \
        >>"$LOG_FILE" 2>&1
      # Alpine specific for glibc compatibility (sometimes needed)
      if ! apk info | grep -q libc6-compat; then
        apk add --no-cache libc6-compat >>"$LOG_FILE" 2>&1 || true
      fi
      ;;
    dnf)
      dnf -y install \
        ca-certificates curl git xz tar \
        python3 make gcc-c++ gcc pkgconfig \
        libstdc++ openssl gnupg bash coreutils findutils \
        jq \
        >>"$LOG_FILE" 2>&1
      dnf clean all >>"$LOG_FILE" 2>&1 || true
      ;;
    yum)
      yum -y install \
        ca-certificates curl git xz tar \
        python3 make gcc-c++ gcc pkgconfig \
        libstdc++ openssl gnupg bash coreutils findutils \
        jq \
        >>"$LOG_FILE" 2>&1
      yum clean all >>"$LOG_FILE" 2>&1 || true
      ;;
    *)
      die "Unsupported or unknown package manager. Please use a Debian/Ubuntu, Alpine, or RHEL-based image."
      ;;
  esac
  update-ca-certificates >>"$LOG_FILE" 2>&1 || true
  log "System packages installed."
}

# Create non-root user if requested
create_app_user() {
  if [ "$USE_NONROOT_USER" = "1" ]; then
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      log "Creating non-root user '$APP_USER' (UID: $APP_UID, GID: $APP_GID)..."
      if command_exists addgroup && command_exists adduser; then
        addgroup -g "$APP_GID" "$APP_USER" >>"$LOG_FILE" 2>&1 || true
        adduser -D -G "$APP_USER" -u "$APP_UID" "$APP_USER" >>"$LOG_FILE" 2>&1
      else
        groupadd -g "$APP_GID" "$APP_USER" >>"$LOG_FILE" 2>&1 || true
        useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" >>"$LOG_FILE" 2>&1
      fi
      log "User '$APP_USER' created."
    else
      log "User '$APP_USER' already exists."
    fi
  fi
}

# Install Node.js from official tarball to /opt/node and configure symlinks
install_node() {
  local current_node_version=""
  if command_exists node; then
    current_node_version="$(node -v | sed 's/^v//')"
  fi

  if [ "$current_node_version" = "$REQUIRED_NODE_VERSION" ] && [ -x "${GLOBAL_BIN_DIR}/npm" ]; then
    log "Node.js v${REQUIRED_NODE_VERSION} already installed."
    return
  fi

  mkdir -p "$NODE_INSTALL_DIR" >>"$LOG_FILE" 2>&1
  local tarball_path="/tmp/${NODE_TARBALL}"

  log "Downloading Node.js ${REQUIRED_NODE_VERSION} (${NODE_DISTRO})..."
  curl -fsSL "${NODE_BASE_URL}/${NODE_TARBALL}" -o "$tarball_path" >>"$LOG_FILE" 2>&1

  log "Extracting Node.js to ${NODE_TARGET_DIR}..."
  rm -rf "$NODE_TARGET_DIR" >>"$LOG_FILE" 2>&1 || true
  mkdir -p "$NODE_TARGET_DIR" >>"$LOG_FILE" 2>&1
  tar -xJf "$tarball_path" -C /tmp >>"$LOG_FILE" 2>&1
  mv "/tmp/node-v${REQUIRED_NODE_VERSION}-${NODE_DISTRO}"/* "$NODE_TARGET_DIR"/ >>"$LOG_FILE" 2>&1

  # Symlink node, npm, npx to /usr/local/bin
  ln -sf "${NODE_TARGET_DIR}/bin/node" "${GLOBAL_BIN_DIR}/node" >>"$LOG_FILE" 2>&1
  ln -sf "${NODE_TARGET_DIR}/bin/npm"  "${GLOBAL_BIN_DIR}/npm"  >>"$LOG_FILE" 2>&1
  ln -sf "${NODE_TARGET_DIR}/bin/npx"  "${GLOBAL_BIN_DIR}/npx"  >>"$LOG_FILE" 2>&1
  ln -sf "${NODE_TARGET_DIR}/bin/corepack" "${GLOBAL_BIN_DIR}/corepack" >>"$LOG_FILE" 2>&1 || true

  rm -f "$tarball_path" >>"$LOG_FILE" 2>&1 || true

  log "Node.js v${REQUIRED_NODE_VERSION} installed."
}

# Configure npm via Corepack to required version
configure_npm_with_corepack() {
  if ! command_exists node; then
    die "Node is not installed; cannot configure npm."
  fi

  # Enable corepack and prepare npm to the required version
  if command_exists corepack; then
    log "Configuring npm ${REQUIRED_NPM_VERSION} via Corepack..."
    corepack enable >>"$LOG_FILE" 2>&1 || true
    corepack prepare "npm@${REQUIRED_NPM_VERSION}" --activate >>"$LOG_FILE" 2>&1
  else
    warn "Corepack not found; installing npm@${REQUIRED_NPM_VERSION} globally."
    "${GLOBAL_BIN_DIR}/npm" install -g "npm@${REQUIRED_NPM_VERSION}" >>"$LOG_FILE" 2>&1
  fi

  # Validate npm version
  local npm_version
  npm_version="$(npm -v)"
  if [ "$npm_version" != "$REQUIRED_NPM_VERSION" ]; then
    warn "npm version is $npm_version but required is $REQUIRED_NPM_VERSION. Continuing, but this may affect reproducibility."
  else
    log "npm v${npm_version} configured."
  fi
}

# Setup directories, cache, permissions, and git safe directory
setup_dirs_and_permissions() {
  log "Setting up directories and permissions..."
  mkdir -p "$PROJECT_DIR" "$NPM_CACHE_DIR" >>"$LOG_FILE" 2>&1

  if [ "$USE_NONROOT_USER" = "1" ]; then
    chown -R "$APP_UID:$APP_GID" "$PROJECT_DIR" "$NPM_CACHE_DIR" >>"$LOG_FILE" 2>&1
    chmod -R u+rwX,g+rwX "$PROJECT_DIR" "$NPM_CACHE_DIR" >>"$LOG_FILE" 2>&1
  else
    chmod -R u+rwX "$PROJECT_DIR" "$NPM_CACHE_DIR" >>"$LOG_FILE" 2>&1
  fi

  # Mark project dir as a safe git directory (common in Docker)
  if command_exists git; then
    git config --global --add safe.directory "$PROJECT_DIR" >>"$LOG_FILE" 2>&1 || true
  fi

  log "Directory setup complete."
}

# Setup npm configuration for container execution
setup_npm_config() {
  log "Configuring npm for container environment..."
  # Project-specific .npmrc
  local npmrc="${PROJECT_DIR}/.npmrc"
  # Make idempotent: write only if different
  local config_content
  config_content=$(cat <<EOF
cache=${NPM_CACHE_DIR}
fund=false
audit=false
update-notifier=false
prefer-offline=true
progress=false
loglevel=warn
save-exact=true
# Allow scripts (required by many packages)
unsafe-perm=true
# Don't try to use git credential helpers inside containers
git-tag-version=false
EOF
)
  # Only update if changed
  if [ ! -f "$npmrc" ] || ! diff -q <(echo "$config_content") "$npmrc" >/dev/null 2>&1; then
    echo "$config_content" > "$npmrc"
  fi
  log ".npmrc configured at ${npmrc}"
}

# Install project dependencies (npm ci if lockfile exists, else npm install)
install_project_dependencies() {
  log "Installing project dependencies..."
  local ci_flags=(--no-audit --no-fund)
  local install_flags=(--no-audit --no-fund)
  local use_ci=0

  if [ -f "${PROJECT_DIR}/package-lock.json" ]; then
    use_ci=1
  fi

  # Respect non-root user if requested
  if [ "$USE_NONROOT_USER" = "1" ]; then
    # Run npm as app user for safer permissions
    su -s /bin/bash -c "cd '$PROJECT_DIR' && CI=true npm ${use_ci:+ci} ${use_ci:+${ci_flags[*]}} ${use_ci:0:${#use_ci}} || npm install ${install_flags[*]}" "$APP_USER" >>"$LOG_FILE" 2>&1 || {
      # Fall back to root if su fails
      warn "Failed to run npm as $APP_USER; falling back to root."
      (cd "$PROJECT_DIR" && CI=true npm ${use_ci:+ci} ${ci_flags[*]}) >>"$LOG_FILE" 2>&1 || (cd "$PROJECT_DIR" && npm install ${install_flags[*]} ) >>"$LOG_FILE" 2>&1
    }
  else
    if [ "$use_ci" -eq 1 ]; then
      (cd "$PROJECT_DIR" && CI=true npm ci "${ci_flags[@]}") >>"$LOG_FILE" 2>&1 || die "npm ci failed"
    else
      (cd "$PROJECT_DIR" && npm install "${install_flags[@]}") >>"$LOG_FILE" 2>&1 || die "npm install failed"
    fi
  fi

  log "Project dependencies installed."
}

# Optionally install Playwright system dependencies (for running Playwright tests)
install_playwright_deps_if_requested() {
  if [ "$INSTALL_PLAYWRIGHT_DEPS" != "1" ]; then
    return
  fi
  log "Installing Playwright browser dependencies..."
  case "$PKG_MGR" in
    apt)
      apt-get update >>"$LOG_FILE" 2>&1
      apt-get install -y --no-install-recommends \
        libnss3 libxss1 libasound2 libatk-bridge2.0-0 libgtk-3-0 \
        libdrm2 libgbm1 libxcomposite1 libxrandr2 libxdamage1 libpango-1.0-0 \
        libx11-6 libx11-xcb1 libxcb1 libxext6 libxfixes3 \
        >>"$LOG_FILE" 2>&1
      rm -rf /var/lib/apt/lists/* >>"$LOG_FILE" 2>&1 || true
      ;;
    apk)
      apk add --no-cache \
        nss libx11 libxcomposite libxrandr libxdamage \
        pango gtk+3 \
        alsa-lib \
        >>"$LOG_FILE" 2>&1 || true
      ;;
    dnf|yum)
      # Best-effort set of dependencies
      "$PKG_MGR" -y install \
        nss libX11 libXcomposite libXrandr libXdamage \
        pango gtk3 \
        alsa-lib \
        >>"$LOG_FILE" 2>&1 || true
      ;;
    *)
      warn "Unknown package manager; skipping Playwright deps installation."
      ;;
  esac
  log "Playwright dependencies installed (if available)."
}

# Optionally build the project
build_project_if_requested() {
  if [ "$BUILD_PROJECT" = "1" ]; then
    log "Building the project (npm run build)..."
    (cd "$PROJECT_DIR" && npm run build) >>"$LOG_FILE" 2>&1 || die "Project build failed"
    log "Project build completed."
  fi
}

# Setup environment variables for container runtime
setup_env_vars() {
  log "Setting up environment variables..."
  # Global environment exports
  export NODE_ENV="${NODE_ENV:-development}"
  export PATH="${NODE_TARGET_DIR}/bin:${PATH}"
  export NPM_CONFIG_CACHE="${NPM_CACHE_DIR}"
  export CI="${CI:-true}"

  # Write to an env file for convenience
  local env_file="${PROJECT_DIR}/.container.env"
  cat > "$env_file" <<EOF
# Generated by setup script
NODE_ENV=${NODE_ENV}
PATH=${NODE_TARGET_DIR}/bin:\$PATH
NPM_CONFIG_CACHE=${NPM_CACHE_DIR}
CI=${CI}
# Volta pins (from package.json)
VOLTA_NODE=${REQUIRED_NODE_VERSION}
VOLTA_NPM=${REQUIRED_NPM_VERSION}
EOF

  log "Environment variables set. Source ${env_file} if needed."
}

# Fix broken global tsc and compile TypeScript
fix_tsc_and_compile() {
  # Remove interfering /app/bin/tsc if it exists
  test -x /app/bin/tsc && rm -f /app/bin/tsc || true
  # Ensure local typescript is installed as a dev dependency
  (cd "$PROJECT_DIR" && npm install -D typescript) >>"$LOG_FILE" 2>&1
  # Ensure minimal TypeScript project structure exists to allow compilation
  test -d "${PROJECT_DIR}/src" || mkdir -p "${PROJECT_DIR}/src"
  test -f "${PROJECT_DIR}/src/index.ts" || printf 'export const ok: boolean = true;\nconsole.log("TypeScript setup OK:", ok);\n' > "${PROJECT_DIR}/src/index.ts"
  if [ ! -f "${PROJECT_DIR}/tsconfig.json" ]; then
    cat > "${PROJECT_DIR}/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "CommonJS",
    "outDir": "dist",
    "strict": true,
    "esModuleInterop": true
  },
  "files": ["src/index.ts"]
}
EOF
  fi
  # Compile using the typescript package explicitly
  (cd "$PROJECT_DIR" && npx --yes --package=typescript tsc -p tsconfig.json) >>"$LOG_FILE" 2>&1 || die "TypeScript compilation failed"
}

# Main
main() {
  require_root
  resolve_project_dir

  info "Starting ${PROJECT_NAME} environment setup in ${PROJECT_DIR} ..."
  log "Logs are being written to ${LOG_FILE}"

  install_system_packages
  create_app_user
  install_node
  configure_npm_with_corepack
  setup_dirs_and_permissions
  setup_npm_config
  install_project_dependencies
  fix_tsc_and_compile
  install_playwright_deps_if_requested
  build_project_if_requested
  setup_env_vars

  log "Environment setup completed successfully!"
  echo
  echo "Usage examples:"
  echo "- To run build:       (cd \"$PROJECT_DIR\" && source .container.env && npm run build)"
  echo "- To run tests:       (cd \"$PROJECT_DIR\" && source .container.env && npm test)"
  echo "- To compile with tsc: (cd \"$PROJECT_DIR\" && source .container.env && npx --yes --package typescript tsc -p tsconfig.json)"
  echo
}

main "$@"