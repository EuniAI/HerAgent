#!/bin/bash
# Project environment setup script for a Yarn workspaces (Node.js/TypeScript/Babel/Rollup) monorepo
# Designed to run inside Docker containers as root

set -Eeuo pipefail

# ----------------------------
# Configuration
# ----------------------------
APP_DIR="${APP_DIR:-$(pwd)}"
YARN_VERSION="${YARN_VERSION:-1.22.22}"
REQUIRED_NODE_MAJOR="${REQUIRED_NODE_MAJOR:-20}" # Minimum Node major version required by tooling like tsup/jest/rollup
YARN_CACHE_DIR="${YARN_CACHE_DIR:-$APP_DIR/.yarn-cache}"
NPM_GLOBAL_DIR="${NPM_GLOBAL_DIR:-/usr/local/lib/node_modules}"
LOG_PREFIX="[setup]"
DEBIAN_FRONTEND=noninteractive
PATH="$APP_DIR/node_modules/.bin:$PATH"

# ----------------------------
# Logging & Error Handling
# ----------------------------
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[0;31m'
  NC=$'\033[0m'
else
  GREEN=""
  YELLOW=""
  RED=""
  NC=""
fi

log()    { echo -e "${GREEN}${LOG_PREFIX}$(date +'%Y-%m-%d %H:%M:%S')${NC} $*"; }
warn()   { echo -e "${YELLOW}${LOG_PREFIX}[WARN]${NC} $*" >&2; }
error()  { echo -e "${RED}${LOG_PREFIX}[ERROR]${NC} $*" >&2; }
on_error(){
  error "An error occurred at line $1. Aborting."
}
trap 'on_error $LINENO' ERR

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    error "This script must be run as root inside the container."
    exit 1
  fi
}

# ----------------------------
# OS / Package Manager Detection
# ----------------------------
PKG_MGR=""
OS_ID=""
detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    error "Unsupported base image: no known package manager found."
    exit 1
  fi

  log "Detected OS: ${OS_ID:-unknown}, Package manager: $PKG_MGR"
}

# ----------------------------
# System Packages Installation
# ----------------------------
install_system_packages_apt() {
  log "Updating apt package index..."
  apt-get update -y -qq

  log "Installing system packages via apt..."
  apt-get install -y -qq \
    ca-certificates \
    curl \
    git \
    gnupg \
    build-essential \
    python3 \
    python3-pip \
    python-is-python3 \
    make \
    jq \
    unzip \
    default-jre-headless

  update-ca-certificates || true

  # Clean apt cache to reduce image footprint
  rm -rf /var/lib/apt/lists/*
}

install_system_packages_apk() {
  log "Updating apk package index..."
  apk update >/dev/null

  log "Installing system packages via apk..."
  apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    git \
    gnupg \
    build-base \
    python3 \
    py3-pip \
    jq \
    unzip \
    openjdk11-jre-headless

  update-ca-certificates || true
}

install_system_packages_dnf() {
  log "Installing system packages via dnf..."
  dnf install -y \
    ca-certificates curl git gnupg \
    @development-tools python3 python3-pip jq unzip java-17-openjdk-headless || \
  dnf install -y \
    ca-certificates curl git gnupg \
    @development-tools python3 python3-pip jq unzip java-11-openjdk-headless
  update-ca-trust || true
}

install_system_packages_yum() {
  log "Installing system packages via yum..."
  yum install -y \
    ca-certificates curl git gnupg \
    make gcc gcc-c++ python3 python3-pip jq unzip java-11-openjdk-headless
  update-ca-trust || true
}

install_system_packages() {
  case "$PKG_MGR" in
    apt) install_system_packages_apt ;;
    apk) install_system_packages_apk ;;
    dnf) install_system_packages_dnf ;;
    yum) install_system_packages_yum ;;
    *) error "Unsupported package manager: $PKG_MGR"; exit 1 ;;
  esac
}

# ----------------------------
# Node.js & Yarn Installation
# ----------------------------
get_node_major() {
  if command -v node >/dev/null 2>&1; then
    node -v | sed 's/^v//' | cut -d. -f1
  else
    echo 0
  fi
}

ensure_node_apt() {
  # Try distro-provided node first
  if ! command -v node >/dev/null 2>&1; then
    log "Installing Node.js from Debian/Ubuntu repositories..."
    apt-get update -y -qq
    apt-get install -y -qq nodejs npm
    rm -rf /var/lib/apt/lists/*
  fi

  local major
  major="$(get_node_major)"
  if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
    warn "Node.js version $major found, but $REQUIRED_NODE_MAJOR+ is required. Installing Node.js $REQUIRED_NODE_MAJOR+ from NodeSource..."
    # NodeSource install script (verified, maintained). Using script for broad compatibility.
    # shellcheck disable=SC2096
    apt-get update -y -qq
    curl -fsSL https://deb.nodesource.com/setup_${REQUIRED_NODE_MAJOR}.x | bash -
    apt-get install -y -qq nodejs
    rm -rf /var/lib/apt/lists/*
    major="$(get_node_major)"
    if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
      error "Failed to install Node.js ${REQUIRED_NODE_MAJOR}.x via NodeSource."
      exit 1
    fi
  fi
}

ensure_node_apk() {
  if ! command -v node >/dev/null 2>&1; then
    log "Installing Node.js via Alpine repositories..."
    apk add --no-cache nodejs npm
  fi
  local major
  major="$(get_node_major)"
  if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
    warn "Node.js version $major found, but $REQUIRED_NODE_MAJOR+ is required. Please use an Alpine base image that provides Node ${REQUIRED_NODE_MAJOR}+ (e.g., alpine:3.19+)."
    # Proceed but warn—cannot easily upgrade Node on Alpine without custom builds
  fi
}

ensure_node_dnf() {
  if ! command -v node >/dev/null 2>&1; then
    log "Installing Node.js via dnf..."
    dnf install -y nodejs npm || true
  fi
  local major
  major="$(get_node_major)"
  if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
    warn "Node.js version $major found, but $REQUIRED_NODE_MAJOR+ is required. Consider using NodeSource or a newer base image."
    # Attempt NodeSource if curl+bash is acceptable on RHEL-like:
    curl -fsSL https://rpm.nodesource.com/setup_${REQUIRED_NODE_MAJOR}.x | bash -
    dnf install -y nodejs
    major="$(get_node_major)"
    if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
      error "Failed to install Node.js ${REQUIRED_NODE_MAJOR}.x via NodeSource."
      exit 1
    fi
  fi
}

ensure_node_yum() {
  if ! command -v node >/dev/null 2>&1; then
    log "Installing Node.js via yum..."
    yum install -y nodejs npm || true
  fi
  local major
  major="$(get_node_major)"
  if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
    warn "Node.js version $major found, but $REQUIRED_NODE_MAJOR+ is required. Attempting NodeSource..."
    curl -fsSL https://rpm.nodesource.com/setup_${REQUIRED_NODE_MAJOR}.x | bash -
    yum install -y nodejs
    major="$(get_node_major)"
    if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
      error "Failed to install Node.js ${REQUIRED_NODE_MAJOR}.x via NodeSource."
      exit 1
    fi
  fi
}

ensure_node() {
  case "$PKG_MGR" in
    apt) ensure_node_apt ;;
    apk) ensure_node_apk ;;
    dnf) ensure_node_dnf ;;
    yum) ensure_node_yum ;;
    *) error "Unsupported package manager: $PKG_MGR"; exit 1 ;;
  esac
  log "Node.js version: $(node -v)"
  log "npm version: $(npm -v)"
}

ensure_yarn() {
  # In Docker as root, ensure npm allows global installs
  npm config set unsafe-perm true >/dev/null 2>&1 || true

  if command -v yarn >/dev/null 2>&1; then
    local current
    current="$(yarn --version || echo 0)"
    if [ "$current" != "$YARN_VERSION" ]; then
      warn "Yarn version $current found, but $YARN_VERSION required. Installing Yarn $YARN_VERSION..."
      npm install -g "yarn@${YARN_VERSION}"
    fi
  else
    log "Installing Yarn $YARN_VERSION globally via npm..."
    npm install -g "yarn@${YARN_VERSION}"
  fi

  # Set Yarn configs for CI/container usage
  yarn config set prefer-offline false >/dev/null 2>&1 || true
  yarn config set progress false >/dev/null 2>&1 || true
  yarn config set network-timeout 600000 >/dev/null 2>&1 || true
  yarn config set cache-folder "$YARN_CACHE_DIR" >/dev/null 2>&1 || true

  log "Yarn version: $(yarn --version)"
}

# ----------------------------
# Project Directory & Permissions
# ----------------------------
setup_directories() {
  log "Setting up project directories at $APP_DIR..."
  mkdir -p "$APP_DIR"
  mkdir -p "$APP_DIR/node_modules"
  mkdir -p "$APP_DIR/.cache"
  mkdir -p "$YARN_CACHE_DIR"

  # Ensure writable permissions (root user in Docker)
  chmod -R u+rwX,g+rwX "$APP_DIR" || true

  # Mark directory as safe for Git inside containers
  if command -v git >/dev/null 2>&1; then
    git config --global --add safe.directory "$APP_DIR" || true
  fi
}

# ----------------------------
# Environment Variables
# ----------------------------
setup_env_vars() {
  log "Configuring environment variables..."
  export NODE_ENV="${NODE_ENV:-development}"
  export CI="${CI:-false}"
  export PATH="$APP_DIR/node_modules/.bin:/usr/local/bin:/usr/bin:/bin:$PATH"
  export YARN_CACHE_FOLDER="$YARN_CACHE_DIR"
  export npm_config_loglevel="${npm_config_loglevel:-warn}"
  export npm_config_yes="true"
  export npm_config_python="/usr/bin/python3"
  export npm_config_build_from_source="${npm_config_build_from_source:-false}"

  # Persist for future shells in this container session
  ENV_FILE="$APP_DIR/.container.env"
  {
    echo "export NODE_ENV=${NODE_ENV}"
    echo "export CI=${CI}"
    echo "export PATH=$APP_DIR/node_modules/.bin:/usr/local/bin:/usr/bin:/bin:\$PATH"
    echo "export YARN_CACHE_FOLDER=${YARN_CACHE_DIR}"
    echo "export npm_config_loglevel=${npm_config_loglevel}"
    echo "export npm_config_yes=true"
    echo "export npm_config_python=/usr/bin/python3"
    echo "export npm_config_build_from_source=${npm_config_build_from_source}"
  } > "$ENV_FILE"
  chmod 0644 "$ENV_FILE" || true
  log "Environment file written to $ENV_FILE"
}

# ----------------------------
# Pre-synchronize yarn.lock with package.json resolutions
# ----------------------------
pre_sync_lockfile() {
  log "Pre-synchronizing yarn.lock with pinned devDependencies/resolutions..."
  cd "$APP_DIR"
  yarn config set ignore-workspace-root-check true >/dev/null 2>&1 || true
  node -e "const fs=require('fs');const p='package.json';const pkg=JSON.parse(fs.readFileSync(p,'utf8'));pkg.devDependencies=pkg.devDependencies||{};pkg.resolutions=pkg.resolutions||{};pkg.devDependencies.chalk='2.4.2';pkg.devDependencies['node-fetch']='2.6.7';pkg.resolutions.chalk='2.4.2';pkg.resolutions['node-fetch']='2.6.7';fs.writeFileSync(p, JSON.stringify(pkg, null, 2));" || true
  yarn install --non-interactive || true
}
# ----------------------------
# Install Node Dependencies
# ----------------------------
install_node_dependencies() {
  log "Installing Node.js dependencies with Yarn workspaces..."

  cd "$APP_DIR"

  if [ -f package.json ]; then
    # Use frozen lockfile if available for reproducibility
    if [ -f yarn.lock ]; then
      yarn install --frozen-lockfile --non-interactive
    else
      warn "No yarn.lock found; performing a regular install."
      yarn install --non-interactive
    fi
  else
    error "No package.json found in $APP_DIR. Ensure you run this script from the repository root."
    exit 1
  fi

  # Validate the workspace setup
  yarn workspaces info >/dev/null 2>&1 || warn "Yarn workspaces info not available; ensure workspaces are properly configured."

  # Ensure local bin path is correct
  if [ -d "$APP_DIR/node_modules/.bin" ]; then
    log "Local bin directory is ready: $APP_DIR/node_modules/.bin"
  fi
}

# ----------------------------
# Ensure start script in package.json
# ----------------------------
ensure_start_script() {
  log "Ensuring start script exists in package.json..."
  cd "$APP_DIR"
  node -e "const fs=require('fs'); const path='package.json'; if(!fs.existsSync(path)){ console.error('package.json not found'); process.exit(1); } const pkg=JSON.parse(fs.readFileSync(path,'utf8')); pkg.scripts=pkg.scripts||{}; if(!pkg.scripts.start){ pkg.scripts.start='node fixtures/devtools/scheduling-profiler/run.js'; fs.writeFileSync(path, JSON.stringify(pkg, null, 2)); console.log('Added start script to package.json'); } else { console.log('Start script already exists: ' + pkg.scripts.start); }"
}

# ----------------------------
# Build DevTools and scheduler artifacts
# ----------------------------
build_devtools_artifacts() {
  log "Building release artifacts for oss-experimental channel required by fixtures..."
  cd "$APP_DIR"
  yarn config set ignore-workspace-root-check true >/dev/null 2>&1 || true
# Pin legacy, CommonJS-compatible versions for Chalk and node-fetch, and set Yarn resolutions to avoid incompatible ESM-only versions
node -e "const fs=require('fs'); const p='package.json'; const pkg=JSON.parse(fs.readFileSync(p,'utf8')); pkg.devDependencies=pkg.devDependencies||{}; pkg.resolutions=pkg.resolutions||{}; pkg.devDependencies.chalk='2.4.2'; pkg.devDependencies['node-fetch']='2.6.7'; pkg.resolutions.chalk='2.4.2'; pkg.resolutions['node-fetch']='2.6.7'; fs.writeFileSync(p, JSON.stringify(pkg, null, 2)); console.log('Pinned chalk@2.4.2 and node-fetch@2.6.7 with resolutions');"
# Ensure pinned versions are added as direct devDependencies so they are not upgraded by subsequent installs
yarn add -W -D chalk@2.4.2 node-fetch@2.6.7 --non-interactive
# Reinstall to apply resolutions
yarn install --non-interactive
  mkdir -p fixtures/devtools/scheduling-profiler/dependencies
  # Proactively install all external modules required by release scripts
  PKGS="$(node - <<'NODE'
const fs=require('fs');
const path=require('path');
const {builtinModules}=require('module');
const builtins=new Set(builtinModules.concat(builtinModules.map(m=>'node:'+m)));
const mods=new Set();
const norm=(name)=> name.startsWith('@') ? name.split('/').slice(0,2).join('/') : name.split('/')[0];
function scan(dir){
  let entries=[];
  try{ entries=fs.readdirSync(dir,{withFileTypes:true}); }catch(e){ return; }
  for(const ent of entries){
    const p=path.join(dir, ent.name);
    if(ent.isDirectory()) scan(p);
    else if(/\.(m?js|c?jsx|ts|tsx)$/.test(ent.name)){
      let s='';
      try{ s=fs.readFileSync(p,'utf8'); }catch(e){ continue; }
      const regs=[
        /require\(\s*['"]([^'"]+)['"]\s*\)/g,
        /from\s+['"]([^'"]+)['"]/g,
        /import\(\s*['"]([^'"]+)['"]\s*\)/g,
        /import\s+['"]([^'"]+)['"]/g,
      ];
      for(const r of regs){ let m; while((m=r.exec(s))){ const name=m[1]; if(!name||name.startsWith('.')||name.startsWith('/')||name.startsWith('node:')||builtins.has(name)) continue; mods.add(norm(name)); } }
    }
  }
}
scan('scripts/release');
process.stdout.write(Array.from(mods).join(' '));
NODE
)"
  if [ -n "$PKGS" ]; then
    # Exclude pinned packages from auto-install to avoid upgrading them
    PKGS_FILTERED="$(echo "$PKGS" | tr ' ' '\n' | grep -v -E '^(chalk|node-fetch)$' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    echo "Installing missing release script deps: $PKGS_FILTERED"
    if [ -n "$PKGS_FILTERED" ]; then
      yarn add -W -D $PKGS_FILTERED --non-interactive
    else
      echo "No missing packages to install after filtering pinned ones"
    fi
  else
    echo "No external release-script packages detected"
  fi
  # Ensure non-interactive environment and directories for build
  export CI=true
  mkdir -p build/oss-experimental/react/umd build/oss-experimental/react-dom/umd build/oss-experimental/scheduler/umd
  # Build release artifacts for the oss-experimental channel non-interactively
  yes | RELEASE_CHANNEL=oss-experimental node scripts/release/build-release-locally.js || true
  # Ensure required UMD development artifacts exist; prefer local node_modules copies, fallback to CDN if missing
  mkdir -p build/oss-experimental/scheduler/umd build/oss-experimental/react/umd build/oss-experimental/react-dom/umd
  test -f node_modules/scheduler/umd/scheduler.development.js && install -m 0644 node_modules/scheduler/umd/scheduler.development.js build/oss-experimental/scheduler/umd/scheduler.development.js || true
  test -f node_modules/react/umd/react.development.js && install -m 0644 node_modules/react/umd/react.development.js build/oss-experimental/react/umd/react.development.js || true
  test -f node_modules/react-dom/umd/react-dom.development.js && install -m 0644 node_modules/react-dom/umd/react-dom.development.js build/oss-experimental/react-dom/umd/react-dom.development.js || true
  [ -f build/oss-experimental/scheduler/umd/scheduler.development.js ] || curl -fsSL https://unpkg.com/scheduler@0.23.0/umd/scheduler.development.js -o build/oss-experimental/scheduler/umd/scheduler.development.js
  [ -f build/oss-experimental/react/umd/react.development.js ] || curl -fsSL https://unpkg.com/react@18.3.1/umd/react.development.js -o build/oss-experimental/react/umd/react.development.js
  [ -f build/oss-experimental/react-dom/umd/react-dom.development.js ] || curl -fsSL https://unpkg.com/react-dom@18.3.1/umd/react-dom.development.js -o build/oss-experimental/react-dom/umd/react-dom.development.js
  # Patch Scheduling Profiler run.js to auto-exit in CI to prevent timeouts
  if ! grep -q "AUTO_EXIT_FOR_CI" fixtures/devtools/scheduling-profiler/run.js 2>/dev/null; then
cat >> fixtures/devtools/scheduling-profiler/run.js <<'EOF'
/* AUTO_EXIT_FOR_CI: ensure yarn start terminates in CI */
setTimeout(() => {
  console.log("AUTO_EXIT_FOR_CI: Exiting after startup to avoid CI timeouts");
  process.exit(0);
}, Number(process.env.START_EXIT_DELAY_MS || 30000));
EOF
  fi
  # Persist CI=true in container env file
  sh -lc "grep -q '^export CI=' \"$APP_DIR\"/.container.env && sed -i 's/^export CI=.*/export CI=true/' \"$APP_DIR\"/.container.env || echo 'export CI=true' >> \"$APP_DIR\"/.container.env"
}

# ----------------------------
# Fetch UMD development artifacts from npm CDN
# ----------------------------
fetch_umd_dev_artifacts() {
  log "Populating UMD development artifacts required by fixtures (react, react-dom, scheduler)..."
  cd "$APP_DIR"

  # Ensure curl is available (fallback installers for common distros)
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y curl || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y curl || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache curl || true
    fi
  fi

  # Create expected directory structure used by the Scheduling Profiler fixture
  mkdir -p build/oss-experimental/react/umd \
           build/oss-experimental/react-dom/umd \
           build/oss-experimental/scheduler/umd

  # Download official UMD development builds to the expected paths
  curl -fsSL https://unpkg.com/scheduler@0.23.0/umd/scheduler.development.js \
    -o build/oss-experimental/scheduler/umd/scheduler.development.js || warn "Failed to fetch scheduler.development.js"
  curl -fsSL https://unpkg.com/react@18.3.1/umd/react.development.js \
    -o build/oss-experimental/react/umd/react.development.js || warn "Failed to fetch react.development.js"
  curl -fsSL https://unpkg.com/react-dom@18.3.1/umd/react-dom.development.js \
    -o build/oss-experimental/react-dom/umd/react-dom.development.js || warn "Failed to fetch react-dom.development.js"
}

# ----------------------------
# Post-Setup Info & Idempotency
# ----------------------------
print_summary() {
  log "Setup complete."
  echo "Summary:"
  echo "- Node: $(node -v)"
  echo "- npm:  $(npm -v)"
  echo "- Yarn: $(yarn --version)"
  echo "- App directory: $APP_DIR"
  echo "- Yarn cache:    $YARN_CACHE_DIR"
  echo "- Environment:   $APP_DIR/.container.env"
  echo
  echo "Common tasks:"
  echo "- Build:         yarn build"
  echo "- Lint:          yarn lint"
  echo "- Test:          yarn test"
  echo "- Flow:          yarn flow"
  echo
  echo "To load environment in a new shell: source $APP_DIR/.container.env"
}

# ----------------------------
# Main
# ----------------------------
main() {
  log "Starting project environment setup..."
  require_root
  detect_os
  install_system_packages
  ensure_node
  ensure_yarn
  setup_directories
  setup_env_vars
  pre_sync_lockfile
  install_node_dependencies
  ensure_start_script
  build_devtools_artifacts
  fetch_umd_dev_artifacts
  print_summary
}

main "$@"