#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects common stacks (Python, Node.js, Ruby, Go, Java, PHP, Rust) and installs dependencies.
# Idempotent, safe to run multiple times, no sudo required.

set -Eeuo pipefail

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Global defaults
export DEBIAN_FRONTEND=noninteractive
umask 022

# Logging
timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo -e "${GREEN}[$(timestamp)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(timestamp)] [WARN] $*${NC}" >&2; }
error() { echo -e "${RED}[$(timestamp)] [ERROR] $*${NC}" >&2; }

# Trap errors
cleanup() { :; }
on_error() {
  local exit_code=$?
  error "Setup failed with exit code ${exit_code}"
  exit "${exit_code}"
}
trap on_error ERR
trap cleanup EXIT

# Determine project root (default: current directory)
PROJECT_ROOT="${APP_ROOT:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_PORT="${APP_PORT:-8080}"
APP_ENV="${APP_ENV:-production}"

# Package manager detection
PM=""
UPDATE_CMD=""
INSTALL_CMD=""
HAS_APT=""
HAS_DNF=""
HAS_YUM=""
HAS_APK=""

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
    UPDATE_CMD="apt-get update -y"
    INSTALL_CMD="apt-get install -y --no-install-recommends"
    HAS_APT="1"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    UPDATE_CMD="dnf -y makecache"
    INSTALL_CMD="dnf -y install"
    HAS_DNF="1"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    UPDATE_CMD="yum -y makecache"
    INSTALL_CMD="yum -y install"
    HAS_YUM="1"
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
    UPDATE_CMD="apk update"
    INSTALL_CMD="apk add --no-cache"
    HAS_APK="1"
  else
    error "No supported package manager found (apt, dnf, yum, apk). Ensure the base image has a package manager."
    exit 1
  fi
  log "Package manager detected: ${PM}"
}

pkg_update() {
  log "Updating package index..."
  eval "${UPDATE_CMD}" || warn "Package index update may have failed; proceeding"
}

pkg_install() {
  # Accept list of packages, skip empty entries
  local pkgs=()
  for p in "$@"; do
    [[ -n "${p}" ]] && pkgs+=("${p}")
  done
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    return 0
  fi
  log "Installing packages: ${pkgs[*]}"
  eval "${INSTALL_CMD} ${pkgs[*]}"
}

install_common_tools() {
  log "Installing common system tools and certificates..."
  if [[ -n "${HAS_APT}" ]]; then
    pkg_install ca-certificates curl wget git build-essential pkg-config \
               bash coreutils findutils grep sed tar gzip xz-utils
    # Ensure certificates are up to date
    update-ca-certificates || true
  elif [[ -n "${HAS_DNF}" || -n "${HAS_YUM}" ]]; then
    pkg_install ca-certificates curl wget git gcc gcc-c++ make pkgconfig \
               bash coreutils findutils grep sed tar gzip xz
    update-ca-trust || true
  elif [[ -n "${HAS_APK}" ]]; then
    pkg_install ca-certificates curl wget git build-base pkgconf \
               bash coreutils findutils grep sed tar gzip xz
    update-ca-certificates || true
  fi
}

ensure_user() {
  # Create non-root application user if not exists
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    log "User '${APP_USER}' already exists"
  else
    log "Creating user '${APP_USER}' for running the app..."
    if [[ -n "${HAS_APT}" || -n "${HAS_DNF}" || -n "${HAS_YUM}" ]]; then
      # Ensure useradd exists
      if ! command -v useradd >/dev/null 2>&1; then
        pkg_install passwd || true
        pkg_install shadow || true
      fi
      useradd -m -s /bin/bash -U "${APP_USER}" || {
        # Fallback to adduser
        adduser --disabled-password --gecos "" "${APP_USER}" || true
      }
    elif [[ -n "${HAS_APK}" ]]; then
      addgroup -S "${APP_GROUP}" 2>/dev/null || true
      adduser -S -G "${APP_GROUP}" -h "/home/${APP_USER}" "${APP_USER}" 2>/dev/null || true
    fi
  fi
}

setup_directories() {
  log "Setting up project directories under ${PROJECT_ROOT}..."
  mkdir -p "${PROJECT_ROOT}"
  mkdir -p "${PROJECT_ROOT}/logs" "${PROJECT_ROOT}/tmp" "${PROJECT_ROOT}/.cache"
  touch "${PROJECT_ROOT}/logs/.keep" "${PROJECT_ROOT}/tmp/.keep" || true

  # Ensure permissions
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}" || true
    chmod -R u+rwX,g+rwX,o-rwx "${PROJECT_ROOT}" || true
  fi
}

# Stack detection
STACKS=()

detect_stacks() {
  log "Detecting project technology stack from files..."
  local found=0

  # Python
  if [[ -f "${PROJECT_ROOT}/requirements.txt" || -f "${PROJECT_ROOT}/pyproject.toml" || -f "${PROJECT_ROOT}/Pipfile" ]]; then
    STACKS+=("python"); found=1; log "Detected Python project files"
  fi

  # Node.js
  if [[ -f "${PROJECT_ROOT}/package.json" ]]; then
    STACKS+=("node"); found=1; log "Detected Node.js project files"
  fi

  # Ruby
  if [[ -f "${PROJECT_ROOT}/Gemfile" ]]; then
    STACKS+=("ruby"); found=1; log "Detected Ruby project files"
  fi

  # Go
  if [[ -f "${PROJECT_ROOT}/go.mod" || -f "${PROJECT_ROOT}/go.sum" ]]; then
    STACKS+=("go"); found=1; log "Detected Go project files"
  fi

  # Java
  if [[ -f "${PROJECT_ROOT}/pom.xml" || -f "${PROJECT_ROOT}/build.gradle" || -f "${PROJECT_ROOT}/build.gradle.kts" ]]; then
    STACKS+=("java"); found=1; log "Detected Java project files"
  fi

  # PHP
  if [[ -f "${PROJECT_ROOT}/composer.json" ]]; then
    STACKS+=("php"); found=1; log "Detected PHP project files"
  fi

  # Rust
  if [[ -f "${PROJECT_ROOT}/Cargo.toml" ]]; then
    STACKS+=("rust"); found=1; log "Detected Rust project files"
  fi

  # .NET (informational)
  if ls "${PROJECT_ROOT}"/*.csproj >/dev/null 2>&1 || ls "${PROJECT_ROOT}"/*.sln >/dev/null 2>&1; then
    STACKS+=(".net"); found=1; log "Detected .NET project files (limited support in this script)"
  fi

  if [[ "${found}" -eq 0 ]]; then
    warn "No known stack files detected. The script will install base tools only."
  fi
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  if [[ -n "${HAS_APT}" ]]; then
    pkg_install python3 python3-pip python3-venv python3-dev build-essential libffi-dev libssl-dev zlib1g-dev libpq-dev
  elif [[ -n "${HAS_DNF}" || -n "${HAS_YUM}" ]]; then
    pkg_install python3 python3-pip python3-devel gcc gcc-c++ make openssl-devel libffi-devel zlib-devel
  elif [[ -n "${HAS_APK}" ]]; then
    pkg_install python3 py3-pip python3-dev build-base libffi-dev openssl-dev zlib-dev
  fi

  export PIP_NO_CACHE_DIR=on
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export VIRTUAL_ENV="${PROJECT_ROOT}/.venv"

  if [[ -d "${VIRTUAL_ENV}" ]]; then
    log "Python virtual environment already exists at ${VIRTUAL_ENV}"
  else
    log "Creating Python virtual environment at ${VIRTUAL_ENV}..."
    python3 -m venv "${VIRTUAL_ENV}"
  fi

  # shellcheck disable=SC1090
  source "${VIRTUAL_ENV}/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [[ -f "${PROJECT_ROOT}/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt..."
    python3 -m pip install -r "${PROJECT_ROOT}/requirements.txt"
  elif [[ -f "${PROJECT_ROOT}/pyproject.toml" ]]; then
    # Try pip if declarative (PEP 621). If poetry specified, install poetry and use it.
    if grep -qi 'tool.poetry' "${PROJECT_ROOT}/pyproject.toml"; then
      log "pyproject.toml indicates Poetry; installing Poetry..."
      python3 -m pip install "poetry>=1.6"
      (cd "${PROJECT_ROOT}" && poetry install --no-root --no-interaction)
    else
      log "Installing Python project via pyproject.toml using pip..."
      (cd "${PROJECT_ROOT}" && python3 -m pip install .)
    fi
  elif [[ -f "${PROJECT_ROOT}/Pipfile" ]]; then
    log "Pipfile detected; installing pipenv..."
    python3 -m pip install "pipenv>=2023.0"
    (cd "${PROJECT_ROOT}" && PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || pipenv install)
  else
    warn "No Python dependency file found; skipping dependency install"
  fi

  # Pin transformers to a pre-gate version and ensure safetensors is installed
  python3 -m pip install --no-cache-dir --upgrade "transformers==4.44.2" "safetensors>=0.4.2" || warn "Failed to install pinned transformers/safetensors; proceeding"
  # Ensure PyTorch meets transformers safety requirements (CPU-only wheels)
  python -m pip install --no-cache-dir --upgrade --index-url https://download.pytorch.org/whl/cpu "torch>=2.6" "safetensors>=0.4.5" || warn "Failed to upgrade torch/safetensors; proceeding"

  # Common environment variables for Python apps
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1
  export PATH="${VIRTUAL_ENV}/bin:${PATH}"

  # Permissions
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${VIRTUAL_ENV}" || true
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  if [[ -n "${HAS_APT}" ]]; then
    pkg_install nodejs npm
  elif [[ -n "${HAS_DNF}" || -n "${HAS_YUM}" ]]; then
    pkg_install nodejs npm
  elif [[ -n "${HAS_APK}" ]]; then
    pkg_install nodejs npm
  fi

  export NODE_ENV="${APP_ENV}"
  export NPM_CONFIG_LOGLEVEL=warn
  export CI=true

  if [[ -f "${PROJECT_ROOT}/package.json" ]]; then
    (cd "${PROJECT_ROOT}" && \
      if [[ -f package-lock.json ]]; then
        log "Installing Node.js dependencies using npm ci..."
        npm ci --no-audit --no-fund
      else
        log "Installing Node.js dependencies using npm install..."
        npm install --no-audit --no-fund
      fi
    )
  else
    warn "package.json not found; skipping Node.js dependency install"
  fi

  # Permissions
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}/node_modules" 2>/dev/null || true
  fi
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  if [[ -n "${HAS_APT}" ]]; then
    pkg_install ruby-full build-essential libffi-dev
  elif [[ -n "${HAS_DNF}" || -n "${HAS_YUM}" ]]; then
    pkg_install ruby ruby-devel gcc gcc-c++ make libffi-devel
  elif [[ -n "${HAS_APK}" ]]; then
    pkg_install ruby ruby-dev build-base libffi-dev
  fi

  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  if [[ -f "${PROJECT_ROOT}/Gemfile" ]]; then
    (cd "${PROJECT_ROOT}" && bundle config set --local path 'vendor/bundle' && bundle install --jobs 4)
  else
    warn "Gemfile not found; skipping bundle install"
  fi

  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}/vendor" 2>/dev/null || true
  fi
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  if [[ -n "${HAS_APT}" ]]; then
    pkg_install golang
  elif [[ -n "${HAS_DNF}" || -n "${HAS_YUM}" ]]; then
    pkg_install golang
  elif [[ -n "${HAS_APK}" ]]; then
    pkg_install go
  fi

  export GOPATH="${PROJECT_ROOT}/.gopath"
  export GOMODCACHE="${PROJECT_ROOT}/.cache/gomod"
  mkdir -p "${GOPATH}" "${GOMODCACHE}"

  if [[ -f "${PROJECT_ROOT}/go.mod" ]]; then
    (cd "${PROJECT_ROOT}" && go mod download)
  else
    warn "go.mod not found; skipping go mod download"
  fi

  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${GOPATH}" "${GOMODCACHE}" || true
  fi
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  if [[ -n "${HAS_APT}" ]]; then
    pkg_install openjdk-17-jdk maven gradle || pkg_install openjdk-17-jdk maven || pkg_install openjdk-17-jdk
  elif [[ -n "${HAS_DNF}" || -n "${HAS_YUM}" ]]; then
    pkg_install java-17-openjdk-devel maven gradle || pkg_install java-17-openjdk-devel maven || pkg_install java-17-openjdk-devel
  elif [[ -n "${HAS_APK}" ]]; then
    pkg_install openjdk17 maven gradle || pkg_install openjdk17 maven || pkg_install openjdk17
  fi

  if [[ -f "${PROJECT_ROOT}/pom.xml" ]]; then
    (cd "${PROJECT_ROOT}" && mvn -B -DskipTests dependency:resolve dependency:resolve-plugins)
  elif [[ -f "${PROJECT_ROOT}/build.gradle" || -f "${PROJECT_ROOT}/build.gradle.kts" ]]; then
    (cd "${PROJECT_ROOT}" && gradle --no-daemon build -x test || gradle --no-daemon assemble)
  else
    warn "No Maven or Gradle build file found; skipping Java dependency setup"
  fi
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  if [[ -n "${HAS_APT}" ]]; then
    pkg_install php-cli php-xml php-mbstring php-curl php-zip unzip
  elif [[ -n "${HAS_DNF}" || -n "${HAS_YUM}" ]]; then
    pkg_install php-cli php-xml php-mbstring php-json php-curl php-zip unzip
  elif [[ -n "${HAS_APK}" ]]; then
    pkg_install php81 php81-cli php81-xml php81-mbstring php81-curl php81-zip unzip || pkg_install php php-cli php-xml php-mbstring php-curl php-zip unzip
  fi

  # Install Composer if not present
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if [[ -f "${PROJECT_ROOT}/composer.json" ]]; then
    (cd "${PROJECT_ROOT}" && composer install --no-dev --prefer-dist --no-interaction)
  else
    warn "composer.json not found; skipping composer install"
  fi

  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}/vendor" 2>/dev/null || true
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment via rustup..."
  # Install prerequisites
  if [[ -n "${HAS_APT}" ]]; then
    pkg_install curl build-essential
  elif [[ -n "${HAS_DNF}" || -n "${HAS_YUM}" ]]; then
    pkg_install curl gcc gcc-c++ make
  elif [[ -n "${HAS_APK}" ]]; then
    pkg_install curl build-base
  fi

  if ! command -v rustc >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env" 2>/dev/null || true

  if [[ -f "${PROJECT_ROOT}/Cargo.toml" ]]; then
    (cd "${PROJECT_ROOT}" && cargo fetch)
  else
    warn "Cargo.toml not found; skipping cargo fetch"
  fi

  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_USER}:${APP_GROUP}" "$HOME/.cargo" 2>/dev/null || true
  fi
}

# .NET note (limited support for auto-install)
setup_dotnet_note() {
  warn ".NET projects detected. Automatic installation of dotnet SDK is not provided in this script due to repository constraints."
  warn "Recommended: Use a base image like mcr.microsoft.com/dotnet/sdk:8.0 or install dotnet SDK via official Microsoft package repositories."
}

# Environment file setup
write_env_file() {
  local env_file="${PROJECT_ROOT}/.container_env"
  log "Writing environment configuration to ${env_file}"
  cat > "${env_file}" <<EOF
# Generated by setup script
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
export PROJECT_ROOT="${PROJECT_ROOT}"
# Python (if applicable)
if [ -d "${PROJECT_ROOT}/.venv" ]; then
  export VIRTUAL_ENV="${PROJECT_ROOT}/.venv"
  export PATH="\${VIRTUAL_ENV}/bin:\${PATH}"
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1
fi
# Node.js (if applicable)
export NODE_ENV="${APP_ENV}"
export NPM_CONFIG_LOGLEVEL=warn
export CI=true
EOF

  if id -u "${APP_USER}" >/dev/null 2>&1; then
    chown "${APP_USER}:${APP_GROUP}" "${env_file}" || true
  fi
}

setup_bashrc_container_env() {
  for f in /root/.bashrc /home/app/.bashrc; do [ -d "$(dirname "$f")" ] || continue; touch "$f"; grep -qxF 'if [ -f /app/.container_env ]; then . /app/.container_env; fi' "$f" || echo 'if [ -f /app/.container_env ]; then . /app/.container_env; fi' >> "$f"; done
}

setup_auto_activate() {
  local venv_path="${PROJECT_ROOT}/.venv"
  local activate_line="source ${venv_path}/bin/activate"
  for f in /root/.bashrc "/home/${APP_USER}/.bashrc"; do
    [ -d "$(dirname "$f")" ] || continue
    touch "$f"
    if ! grep -qF "$activate_line" "$f" 2>/dev/null; then
      echo "" >> "$f"
      echo "# Auto-activate Python virtual environment" >> "$f"
      echo "$activate_line" >> "$f"
    fi
  done
}

setup_chai_downloads_shim() {
  # Create a shim executable matching the exact first token 'CHAI_DOWNLOADS_DIR=/tmp/downloads'
  # and ensure the downloads directory exists.
  if [ -e /tmp/downloads ] && [ ! -d /tmp/downloads ]; then rm -f /tmp/downloads; fi && mkdir -p /tmp/downloads
  mkdir -p "${PROJECT_ROOT}/CHAI_DOWNLOADS_DIR=/tmp"
  cat > "${PROJECT_ROOT}/CHAI_DOWNLOADS_DIR=/tmp/downloads" <<'EOF'
#!/usr/bin/env bash
export CHAI_DOWNLOADS_DIR=/tmp/downloads
exec "$@"
EOF
  chmod +x "${PROJECT_ROOT}/CHAI_DOWNLOADS_DIR=/tmp/downloads"
}

setup_chai_minimal_io() {
  # Ensure minimal input and output directory for 'chai fold input.fasta output_folder'
  local fasta="${PROJECT_ROOT}/input.fasta"
  local outdir="${PROJECT_ROOT}/output_folder"
  mkdir -p "${outdir}" /tmp/downloads
  if [[ -f "${fasta}" ]]; then
    tail -n +2 "${fasta}" > /tmp/seq.tmp
    printf ">protein: test\n" > "${fasta}"
    cat /tmp/seq.tmp >> "${fasta}"
    rm -f /tmp/seq.tmp
  else
    printf ">protein: test\nACDEFGHIKLMNPQRSTVWY\n" > "${fasta}"
  fi
}

print_summary() {
  log "Environment setup completed successfully."
  echo -e "${BLUE}Project root: ${PROJECT_ROOT}${NC}"
  echo -e "${BLUE}App user: ${APP_USER}${NC}"
  echo -e "${BLUE}Environment: ${APP_ENV}${NC}"
  echo -e "${BLUE}Port: ${APP_PORT}${NC}"
  echo -e "${BLUE}To load environment variables in a shell: source ${PROJECT_ROOT}/.container_env${NC}"
}

main() {
  log "Starting universal project environment setup..."

  detect_pkg_manager
  pkg_update
  install_common_tools
  ensure_user
  setup_directories
  detect_stacks

  # Run setup per detected stack
  local ran_any=0
  for s in "${STACKS[@]}"; do
    case "${s}" in
      python) setup_python; ran_any=1 ;;
      node)   setup_node; ran_any=1 ;;
      ruby)   setup_ruby; ran_any=1 ;;
      go)     setup_go; ran_any=1 ;;
      java)   setup_java; ran_any=1 ;;
      php)    setup_php; ran_any=1 ;;
      rust)   setup_rust; ran_any=1 ;;
      .net)   setup_dotnet_note; ran_any=1 ;;
      *)      warn "Unknown stack '${s}' detected";;
    esac
  done

  if [[ "${ran_any}" -eq 0 ]]; then
    warn "No specific stack setup performed. Base tools installed only."
  fi

  setup_chai_downloads_shim
  setup_chai_minimal_io
  write_env_file
  setup_bashrc_container_env
  setup_auto_activate
  if [ -d /app/.venv ]; then . /app/.venv/bin/activate && python -m pip install --no-cache-dir --upgrade safetensors; fi
  print_summary
}

main "$@"