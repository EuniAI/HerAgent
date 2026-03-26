#!/usr/bin/env bash
# Environment setup script for Dynamiq (Python/Poetry project)
# - Installs system packages and Python runtime
# - Installs Poetry and project dependencies
# - Sets up virtual environment and project structure
# - Configures environment variables
# Designed to run in Docker containers (root, no sudo)

set -Eeuo pipefail
IFS=$'\n\t'

#-----------------------------
# Configurable defaults
#-----------------------------
: "${APP_NAME:=dynamiq}"
: "${PROJECT_USER:=}"                 # e.g. "appuser" to create and own files; empty = keep root
: "${PROJECT_GROUP:=}"                # e.g. "appuser"
: "${PROJECT_ROOT:=}"                 # default set from script location
: "${PYTHON_MIN_MAJOR:=3}"
: "${PYTHON_MIN_MINOR:=10}"           # Requires Python >= 3.10
: "${INSTALL_DEV_DEPS:=false}"        # poetry --with dev
: "${INSTALL_EXAMPLES:=false}"        # poetry --with examples
: "${POETRY_VERSION:=1.8.3}"          # pin Poetry for reproducibility
: "${POETRY_HOME:=/root/.local}"      # Poetry default install prefix in container
: "${POETRY_VENV_IN_PROJECT:=true}"   # .venv inside project
: "${PIP_NO_CACHE_DIR:=1}"
: "${UVICORN_PORT:=8000}"             # common default for example APIs

# Example third-party API keys used in examples; leave blank for user to fill
: "${OPENAI_API_KEY:=}"
: "${PINECONE_API_KEY:=}"
: "${E2B_API_KEY:=}"
: "${SCALESERP_API_KEY:=}"

#-----------------------------
# Colors and logging
#-----------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()      { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()     { echo -e "${YELLOW}[WARN] $*${NC}"; }
error()    { echo -e "${RED}[ERROR] $*${NC}" >&2; }
section()  { echo -e "${BLUE}\n=== $* ===${NC}"; }

cleanup() {
  # placeholder for any future cleanup on exit
  true
}
trap cleanup EXIT

fail_trap() {
  local exit_code=$?
  error "Setup failed with exit code ${exit_code} at line ${BASH_LINENO[0]}."
  exit "$exit_code"
}
trap fail_trap ERR

#-----------------------------
# Helpers
#-----------------------------
abspath() { perl -MCwd=abs_path -le 'print abs_path(shift)' "$1"; }

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return; fi
  echo ""
}

# Install packages idempotently per distro
pkg_install() {
  local pm="$1"; shift
  local pkgs=("$@")
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # Use --no-install-recommends to keep minimal footprint
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* || true
      ;;
    apk)
      apk update
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      dnf clean all
      rm -rf /var/cache/dnf || true
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      yum clean all
      rm -rf /var/cache/yum || true
      ;;
    zypper)
      zypper refresh
      zypper install -y --no-recommends "${pkgs[@]}"
      zypper clean -a
      ;;
    *)
      error "Unsupported or undetected package manager. Please use Debian/Ubuntu, Alpine, or RHEL/Fedora-based image."
      exit 1
      ;;
  esac
}

ensure_base_packages() {
  local pm="$1"
  section "Installing base system packages ($pm)"
  case "$pm" in
    apt)
      pkg_install "$pm" \
        ca-certificates curl git bash \
        python3 python3-venv python3-pip python3-dev \
        build-essential pkg-config \
        graphviz libgraphviz-dev \
        poppler-utils \
        libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0 shared-mime-info \
        fonts-dejavu-core
      ;;
    apk)
      # Alpine equivalents; 'pkgconfig' name differs; musl-dev for build
      pkg_install "$pm" \
        ca-certificates curl git bash \
        python3 py3-pip python3-dev \
        gcc g++ make musl-dev pkgconfig \
        graphviz graphviz-dev \
        poppler-utils \
        cairo pango gdk-pixbuf shared-mime-info \
        ttf-dejavu
      # Ensure python3 -m venv works on Alpine (ensure ensurepip installed)
      python3 -m ensurepip || true
      ;;
    dnf|yum)
      pkg_install "$pm" \
        ca-certificates curl git bash \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconfig \
        graphviz graphviz-devel \
        poppler-utils \
        cairo pango gdk-pixbuf2 shared-mime-info \
        dejavu-sans-fonts
      ;;
    zypper)
      pkg_install "$pm" \
        ca-certificates curl git bash \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkg-config \
        graphviz graphviz-devel \
        poppler-tools \
        cairo pango gdk-pixbuf \
        dejavu-fonts
      ;;
  esac
}

ensure_python_version() {
  if ! command -v python3 >/dev/null 2>&1; then
    error "python3 not found after package installation."
    exit 1
  fi
  local v
  v=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
  local major="${v%%.*}"
  local minor="${v#*.}"
  if (( major < PYTHON_MIN_MAJOR || (major == PYTHON_MIN_MAJOR && minor < PYTHON_MIN_MINOR) )); then
    error "Python >= ${PYTHON_MIN_MAJOR}.${PYTHON_MIN_MINOR} is required, found ${v}"
    exit 1
  fi
  log "Python ${v} verified (>= ${PYTHON_MIN_MAJOR}.${PYTHON_MIN_MINOR})"
}

ensure_poetry() {
  section "Installing Poetry ${POETRY_VERSION} (idempotent)"
  if command -v poetry >/dev/null 2>&1; then
    local pv
    pv=$(poetry --version | awk '{print $3}')
    log "Poetry already installed (version ${pv})"
    return 0
  fi
  # Install poetry via official installer
  curl -sSL https://install.python-poetry.org | python3 - --version "${POETRY_VERSION}"
  export PATH="${POETRY_HOME}/bin:${PATH}"
  if ! command -v poetry >/dev/null 2>&1; then
    error "Poetry installation failed or PATH not set."
    exit 1
  fi
  log "Poetry installed: $(poetry --version)"
}

configure_poetry() {
  section "Configuring Poetry"
  export PATH="${POETRY_HOME}/bin:${PATH}"
  poetry config virtualenvs.in-project "${POETRY_VENV_IN_PROJECT}"
  poetry config installer.parallel true
  poetry config cache-dir "${PROJECT_ROOT}/.cache/pypoetry"
  log "Poetry configured (in-project venv: ${POETRY_VENV_IN_PROJECT})"
}

poetry_install() {
  section "Installing project dependencies with Poetry"
  cd "${PROJECT_ROOT}"
  local args=(install --no-interaction --no-ansi)
  # Optional groups
  if [[ "${INSTALL_DEV_DEPS}" == "true" ]]; then
    args+=(--with dev)
  fi
  if [[ "${INSTALL_EXAMPLES}" == "true" ]]; then
    args+=(--with examples)
  fi
  # Install
  POETRY_VIRTUALENVS_IN_PROJECT="${POETRY_VENV_IN_PROJECT}" poetry "${args[@]}"
  # Upgrade pip/wheel/setuptools in venv to improve build reliability
  if [[ -d "${PROJECT_ROOT}/.venv" ]]; then
    "${PROJECT_ROOT}/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
  fi
  log "Dependencies installed successfully"
}

create_structure() {
  section "Creating project directories"
  mkdir -p "${PROJECT_ROOT}/"{.venv,.cache/pypoetry,logs,data,tmp}
  touch "${PROJECT_ROOT}/logs/.gitkeep" "${PROJECT_ROOT}/data/.gitkeep" "${PROJECT_ROOT}/tmp/.gitkeep" || true
}

create_env_file() {
  section "Configuring environment variables (.env)"
  local envfile="${PROJECT_ROOT}/.env"
  if [[ ! -f "${envfile}" ]]; then
    cat > "${envfile}" <<EOF
# Environment variables for ${APP_NAME}
# Fill in secrets via Docker env or build-time secrets; do not commit this file.
OPENAI_API_KEY=${OPENAI_API_KEY}
PINECONE_API_KEY=${PINECONE_API_KEY}
E2B_API_KEY=${E2B_API_KEY}
SCALESERP_API_KEY=${SCALESERP_API_KEY}

# Common runtime options
PYTHONUNBUFFERED=1
PYTHONDONTWRITEBYTECODE=1
UVICORN_PORT=${UVICORN_PORT}
EOF
    log "Created .env with placeholders (update as needed)"
  else
    log ".env already exists, leaving unchanged"
  fi
}

set_permissions() {
  section "Setting permissions"
  if [[ -n "${PROJECT_USER}" && -n "${PROJECT_GROUP}" ]]; then
    if ! id -u "${PROJECT_USER}" >/dev/null 2>&1; then
      log "Creating user ${PROJECT_USER}:${PROJECT_GROUP}"
      # Try to create group if not exists
      if ! getent group "${PROJECT_GROUP}" >/dev/null 2>&1; then
        case "${PKG_MANAGER}" in
          apk) addgroup -S "${PROJECT_GROUP}" ;;
          apt|dnf|yum|zypper) groupadd -r "${PROJECT_GROUP}" ;;
          *) groupadd -r "${PROJECT_GROUP}" || true ;;
        esac
      fi
      case "${PKG_MANAGER}" in
        apk) adduser -S -G "${PROJECT_GROUP}" -s /bin/bash "${PROJECT_USER}" ;;
        apt|dnf|yum|zypper) useradd -r -g "${PROJECT_GROUP}" -s /bin/bash -m "${PROJECT_USER}" ;;
        *) useradd -r -g "${PROJECT_GROUP}" -s /bin/bash -m "${PROJECT_USER}" || true ;;
      esac
    fi
    chown -R "${PROJECT_USER}:${PROJECT_GROUP}" "${PROJECT_ROOT}"
    log "Ownership set to ${PROJECT_USER}:${PROJECT_GROUP}"
  else
    warn "PROJECT_USER/PROJECT_GROUP not set; keeping root ownership"
  fi
}

create_auto_build_script() {
  section "Installing auto_build.sh helper"
  local script_path="${PROJECT_ROOT}/auto_build.sh"
  cat > "${script_path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[auto_build] $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
apt_install(){
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    if [ "$(id -u)" -ne 0 ] && have sudo; then SUDO="sudo -E"; else SUDO=""; fi
    $SUDO apt-get update -y
    $SUDO apt-get install -y --no-install-recommends "$@"
  fi
}
if [ -f pom.xml ]; then
  log "Detected Maven project"
  have mvn || apt_install maven
  mvn -q -DskipTests package
elif [ -f build.gradle ] || [ -f gradlew ]; then
  log "Detected Gradle project"
  if [ -x ./gradlew ]; then ./gradlew build -x test || true; else
    have gradle || apt_install gradle
    gradle build -x test
  fi
elif [ -f package.json ]; then
  log "Detected Node.js project"
  if ! have node || ! have npm; then apt_install nodejs npm; fi
  if have pnpm; then
    pnpm install --frozen-lockfile || pnpm install
    pnpm build || npm run -s build || true
  elif have yarn; then
    yarn install --frozen-lockfile || yarn install
    yarn build || npm run -s build || true
  else
    npm ci || npm install
    npm run -s build || npm run build || true
  fi
elif [ -f Cargo.toml ]; then
  log "Detected Rust project"
  have cargo || apt_install cargo
  cargo build --release || cargo build
elif [ -f Makefile ]; then
  log "Detected Makefile project"
  make build || make
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
  log "Detected Python project"
  have python3 || apt_install python3 python3-venv python3-pip
  have pip3 || apt_install python3-pip
  python3 -m pip install --upgrade pip setuptools wheel || true
  [ -f requirements.txt ] && python3 -m pip install -r requirements.txt || true
  python3 -m pip install build || true
  python3 -m pip install . || python3 -m build
else
  log "No recognized build files found"; exit 1
fi
EOF
  chmod +x "${script_path}"
  ( [ -w /usr/local/bin ] && install -m 0755 "${script_path}" /usr/local/bin/auto_build.sh ) || true
  log "auto_build.sh installed at ${script_path}"
}

print_summary() {
  section "Setup completed"
  cat <<EOF
Project root: ${PROJECT_ROOT}
Virtualenv:   ${PROJECT_ROOT}/.venv
Activate:     source ${PROJECT_ROOT}/.venv/bin/activate
Run a quick test:
  source ${PROJECT_ROOT}/.venv/bin/activate && python -c "import dynamiq, sys; print('Dynamiq imported OK, Python', sys.version)"
Environment file:
  ${PROJECT_ROOT}/.env  (update API keys as needed)

To include dev deps or examples next time, set:
  INSTALL_DEV_DEPS=true INSTALL_EXAMPLES=true ./setup.sh

EOF
}

#-----------------------------
# Main
#-----------------------------
main() {
  section "Starting ${APP_NAME} environment setup"

  # Determine project root
  if [[ -z "${PROJECT_ROOT}" ]]; then
    PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  PROJECT_ROOT="$(abspath "${PROJECT_ROOT}")"
  export PROJECT_ROOT

  # Sanity check: pyproject.toml must exist
  if [[ ! -f "${PROJECT_ROOT}/pyproject.toml" ]]; then
    error "pyproject.toml not found in ${PROJECT_ROOT}. Please run this script from the project root or set PROJECT_ROOT."
    exit 1
  fi

  # Detect package manager and install system packages
  PKG_MANAGER="$(detect_pkg_manager)"
  if [[ -z "${PKG_MANAGER}" ]]; then
    error "Could not detect a supported package manager in this container."
    exit 1
  fi
  export PKG_MANAGER

  ensure_base_packages "${PKG_MANAGER}"
  ensure_python_version

  # Poetry setup and install dependencies
  ensure_poetry
  configure_poetry
  create_structure
  create_env_file
  poetry_install

  # Permissions
  set_permissions

  create_auto_build_script

  # Run auto build dispatcher
  "${PROJECT_ROOT}/auto_build.sh"

  print_summary
}

main "$@"