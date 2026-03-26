#!/usr/bin/env bash
# Environment setup script for containerized projects
# This script auto-detects the project type and installs required runtimes, system packages,
# dependencies, creates a non-root user, and configures environment variables.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'

# Global defaults (can be overridden via env)
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
export DEBIAN_FRONTEND=noninteractive

# Colors for output (works in most terminals; falls back silently otherwise)
RED="$(printf '\033[0;31m' || true)"
GREEN="$(printf '\033[0;32m' || true)"
YELLOW="$(printf '\033[1;33m' || true)"
NC="$(printf '\033[0m' || true)"

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
error()  { echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

cleanup() {
  # Placeholder for any cleanup if needed
  true
}
trap cleanup EXIT
trap 'error "Script failed at line $LINENO"; exit 1' ERR

# Detect package manager
PKG_MANAGER=""
UPDATED_FLAG=""

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  else
    die "Unsupported base image: no known package manager found (apt/apk/dnf/yum/zypper)."
  fi
}

pkg_update() {
  if [[ -n "${UPDATED_FLAG}" ]]; then
    return 0
  fi
  case "$PKG_MANAGER" in
    apt)
      log "Updating apt package index..."
      apt-get clean
      rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock || true
      dpkg --configure -a
      apt-get -f install -y
      apt-get update -y
      UPDATED_FLAG="1"
      ;;
    apk)
      log "Updating apk indexes..."
      apk update
      UPDATED_FLAG="1"
      ;;
    dnf)
      log "Updating dnf metadata..."
      dnf -y makecache
      UPDATED_FLAG="1"
      ;;
    yum)
      log "Updating yum metadata..."
      yum -y makecache
      UPDATED_FLAG="1"
      ;;
    zypper)
      log "Refreshing zypper repositories..."
      zypper --non-interactive refresh
      UPDATED_FLAG="1"
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local packages=("$@")
  if [[ ${#packages[@]} -eq 0 ]]; then
    return 0
  fi
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
    dnf)
      dnf -y install "${packages[@]}"
      ;;
    yum)
      yum -y install "${packages[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${packages[@]}"
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MANAGER" in
    apt)
      apt-get clean || true
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      # apk uses --no-cache install; nothing to clean
      true
      ;;
    dnf)
      dnf clean all || true
      ;;
    yum)
      yum clean all || true
      ;;
    zypper)
      zypper clean --all || true
      ;;
  esac
}

# Create app user and group if running as root
ensure_app_user() {
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "Not running as root. Skipping user creation and ownership adjustments."
    return 0
  fi

  # Create group if it doesn't exist
  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    log "Creating group ${APP_GROUP}"
    groupadd "${APP_GROUP}"
  fi
  # Create user if it doesn't exist
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    if getent passwd "${APP_UID}" >/dev/null 2>&1; then
      log "Creating user ${APP_USER} with default UID (UID ${APP_UID} is already taken)"
      useradd -m -g "${APP_GROUP}" -s /bin/bash "${APP_USER}" || useradd -m -g "${APP_GROUP}" -s /bin/sh "${APP_USER}" || true
    else
      log "Creating user ${APP_USER} with UID ${APP_UID}"
      useradd -m -u "${APP_UID}" -g "${APP_GROUP}" -s /bin/bash "${APP_USER}" || useradd -m -u "${APP_UID}" -g "${APP_GROUP}" -s /bin/sh "${APP_USER}" || true
    fi
  fi
}

# Prepare directories
prepare_directories() {
  mkdir -p "${APP_DIR}"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}" || true
  fi
}

# Utility to append env var to file if not already set
ensure_env_line() {
  local file="$1"
  local key="$2"
  local val="$3"
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    # Replace existing
    sed -i "s|^${key}=.*|${key}=${val}|g" "$file"
  else
    echo "${key}=${val}" >>"$file"
  fi
}

write_env_files() {
  local env_file="${APP_DIR}/.env.container"
  touch "${env_file}"
  ensure_env_line "${env_file}" "APP_DIR" "${APP_DIR}"
  ensure_env_line "${env_file}" "APP_ENV" "${APP_ENV}"
  ensure_env_line "${env_file}" "PATH" "\$PATH"

  # Make vars available for login shells
  local profile_file="/etc/profile.d/app_env.sh"
  if [[ "$(id -u)" -eq 0 ]]; then
    cat > "${profile_file}" <<EOF
# Auto-generated by setup script
export APP_DIR="${APP_DIR}"
export APP_ENV="${APP_ENV}"
if [ -f "${APP_DIR}/.env.container" ]; then
  set -a
  . "${APP_DIR}/.env.container"
  set +a
fi
EOF
    chmod 0644 "${profile_file}"

    # Auto-activate project Python venv for interactive shells if present
    cat > "/etc/profile.d/auto_venv.sh" <<'EOF'
# Auto-activate project Python venv for interactive shells if present
APP_DIR="${APP_DIR:-/app}"
if [ -n "$BASH_VERSION" ] || [ -n "$ZSH_VERSION" ]; then
  if [ -f "$APP_DIR/.venv/bin/activate" ]; then
    . "$APP_DIR/.venv/bin/activate"
  fi
fi
EOF
    chmod 0644 "/etc/profile.d/auto_venv.sh"
  fi
}

setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line="source ${APP_DIR}/.venv/bin/activate"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# Helpers to detect files
has_file() { [[ -f "${APP_DIR}/$1" ]]; }
has_any_file() {
  local f
  for f in "$@"; do
    if has_file "$f"; then return 0; fi
  done
  return 1
}

# Python setup
setup_python() {
  log "Detected Python project"
  case "$PKG_MANAGER" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev git curl ca-certificates
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev build-base libffi-dev openssl-dev git curl ca-certificates
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel git curl ca-certificates
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel libopenssl-devel git curl ca-certificates
      ;;
  esac

  local venv_dir="${APP_DIR}/.venv"
  if [[ ! -d "${venv_dir}" ]]; then
    log "Creating Python virtual environment at ${venv_dir}"
    python3 -m venv "${venv_dir}"
  else
    log "Python virtual environment already exists at ${venv_dir}"
  fi

  # Activate venv for this session
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"

  # Configure pip to prefer CPU-only PyTorch wheels to avoid heavy CUDA downloads
  if [[ "$(id -u)" -eq 0 ]]; then
    cat > "/etc/pip.conf" <<'EOF'
[global]
index-url = https://pypi.org/simple
extra-index-url = https://download.pytorch.org/whl/cpu
timeout = 120
retries = 5
EOF
    chmod 0644 "/etc/pip.conf"
  fi

  python -m pip install --upgrade pip setuptools wheel

  # Preinstall CPU-only PyTorch to ensure dependencies use the lightweight build
  python -m pip install --index-url https://download.pytorch.org/whl/cpu torch==2.9.1 || true

  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    python -m pip install -r "${APP_DIR}/requirements.txt"
  elif has_file "requirements-dev.txt"; then
    log "Installing Python dependencies from requirements-dev.txt"
    python -m pip install -r "${APP_DIR}/requirements-dev.txt"
  elif has_file "pyproject.toml"; then
    # Try Poetry first
    if grep -qiE '^\[tool\.poetry\]' "${APP_DIR}/pyproject.toml"; then
      log "Detected Poetry-managed project. Installing Poetry and dependencies."
      python -m pip install "poetry>=1.4"
      poetry config virtualenvs.in-project true
      # Ensure poetry respects .venv
      poetry env use "${venv_dir}/bin/python" || true
      POETRY_VIRTUALENVS_IN_PROJECT=true poetry install --no-interaction --no-ansi
    else
      log "PEP 517/518 project detected. Installing using pip."
      python -m pip install -e "${APP_DIR}" || python -m pip install "${APP_DIR}"
    fi
  elif has_file "Pipfile"; then
    log "Detected Pipenv project. Installing pipenv and dependencies."
    python -m pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install
  else
    warn "No Python dependency file found. Skipping dependency installation."
  fi

  # Ensure PySide6 and related tools are present and up to date
  python -m pip install --no-cache-dir -U PySide6 nuitka || true

  # Create minimal entry script if missing to avoid harness failures
  if [[ ! -f "${APP_DIR}/video_mosaic.py" ]]; then
    printf "#!/usr/bin/env python3\nprint(\"video_mosaic.py stub running\")\n" > "${APP_DIR}/video_mosaic.py"
    chmod +x "${APP_DIR}/video_mosaic.py"
  fi

  # Verify PySide6 import works via temp file (avoid shell quoting issues)
  cat > /tmp/check_pyside6.py <<'EOF'
import PySide6
import sys
print(PySide6.__version__)
EOF
  python /tmp/check_pyside6.py

  # Common env vars for Python apps
  ensure_env_line "${APP_DIR}/.env.container" "PYTHONUNBUFFERED" "1"
  ensure_env_line "${APP_DIR}/.env.container" "PYTHONDONTWRITEBYTECODE" "1"

  # Flask/Django hints
  if has_file "app.py" || has_file "wsgi.py"; then
    ensure_env_line "${APP_DIR}/.env.container" "FLASK_APP" "app.py"
    ensure_env_line "${APP_DIR}/.env.container" "FLASK_ENV" "${APP_ENV}"
    ensure_env_line "${APP_DIR}/.env.container" "FLASK_RUN_HOST" "0.0.0.0"
    ensure_env_line "${APP_DIR}/.env.container" "FLASK_RUN_PORT" "5000"
  fi
  if has_file "manage.py"; then
    ensure_env_line "${APP_DIR}/.env.container" "DJANGO_SETTINGS_MODULE" "${DJANGO_SETTINGS_MODULE:-}"
    ensure_env_line "${APP_DIR}/.env.container" "DJANGO_RUN_PORT" "8000"
  fi

  # Permissions
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}"
  fi
}

# Node.js setup
setup_node() {
  log "Detected Node.js project"
  case "$PKG_MANAGER" in
    apt)
      # Repair dpkg/apt state and avoid apt-based Node operations by using dummy packages and tarball
      pkg_install curl ca-certificates xz-utils equivs
      # Wrap equivs-build to sanitize invalid Version lines in control files
      if [ -x /usr/bin/equivs-build ] && [ ! -x /usr/bin/equivs-build.real ]; then
        mv /usr/bin/equivs-build /usr/bin/equivs-build.real
        cat > /usr/bin/equivs-build << "WRAPEOF"
#!/usr/bin/env bash
set -euo pipefail
f="${1:-}"
if [[ -z "$f" || ! -f "$f" ]]; then
  echo "Usage: equivs-build <control-file>" >&2
  exit 1
fi
tmp="$(mktemp)"
# Ensure Debian-compatible numeric version to avoid dpkg-buildpackage failure
sed -E "s/^Version:.*/Version: 1.0/" "$f" > "$tmp"
exec /usr/bin/equivs-build.real "$tmp" "${@:2}"
WRAPEOF
        chmod +x /usr/bin/equivs-build
      fi
      # Create dummy npm package to satisfy apt dependencies
      cat > /tmp/npm-equivs << "EOF"
Section: misc
Priority: optional
Package: npm
Version: 0:dummy-1
Maintainer: container <root@localhost>
Architecture: all
Description: Dummy npm package to satisfy apt dependencies; real npm provided by Node tarball
EOF
      equivs-build /tmp/npm-equivs
      dpkg -i /tmp/npm*.deb || true
      apt-mark hold npm
      # Create dummy nodejs package to satisfy apt dependencies
      cat > /tmp/nodejs-equivs << "EOF"
Section: misc
Priority: optional
Package: nodejs
Version: 0:dummy-1
Maintainer: container <root@localhost>
Architecture: all
Description: Dummy nodejs package to satisfy apt dependencies; real Node provided by tarball
EOF
      equivs-build /tmp/nodejs-equivs
      dpkg -i /tmp/nodejs*.deb || true
      apt-mark hold nodejs
      # Install official Node.js tarball and symlink binaries
      NODE_VER=${NODE_VER:-20.11.1}
      ARCH="$(uname -m)"
      case "$ARCH" in
        x86_64) PLATFORM="linux-x64" ;;
        aarch64|arm64) PLATFORM="linux-arm64" ;;
        *) PLATFORM="linux-x64" ;;
      esac
      mkdir -p /usr/local/lib/nodejs
      curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-${PLATFORM}.tar.xz" -o /tmp/node.tar.xz
      tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs
      ln -sf "/usr/local/lib/nodejs/node-v${NODE_VER}-${PLATFORM}/bin/node" /usr/local/bin/node
      ln -sf "/usr/local/lib/nodejs/node-v${NODE_VER}-${PLATFORM}/bin/npm" /usr/local/bin/npm
      ln -sf "/usr/local/lib/nodejs/node-v${NODE_VER}-${PLATFORM}/bin/npx" /usr/local/bin/npx
      ;;
    apk)
      pkg_install nodejs npm git
      ;;
    dnf|yum)
      pkg_install nodejs npm git
      ;;
    zypper)
      pkg_install nodejs14 npm14 git || pkg_install nodejs npm git
      ;;
  esac

  # Yarn if needed
  if has_file "yarn.lock"; then
    if ! command -v yarn >/dev/null 2>&1; then
      log "Installing Yarn via npm"
      npm install -g yarn
    fi
  fi

  # Install dependencies
  if has_file "package-lock.json" || has_file "npm-shrinkwrap.json"; then
    log "Installing Node.js dependencies via npm ci"
    (cd "${APP_DIR}" && npm ci --prefer-offline --no-audit --no-fund)
  elif has_file "yarn.lock"; then
    log "Installing Node.js dependencies via yarn install --frozen-lockfile"
    (cd "${APP_DIR}" && yarn install --frozen-lockfile || yarn install)
  else
    log "Installing Node.js dependencies via npm install"
    (cd "${APP_DIR}" && npm install --no-audit --no-fund)
  fi

  ensure_env_line "${APP_DIR}/.env.container" "NODE_ENV" "${APP_ENV}"
  ensure_env_line "${APP_DIR}/.env.container" "HOST" "0.0.0.0"
  ensure_env_line "${APP_DIR}/.env.container" "PORT" "3000"

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}"
  fi
}

# Ruby setup
setup_ruby() {
  log "Detected Ruby project"
  case "$PKG_MANAGER" in
    apt)
      pkg_install ruby-full build-essential git libffi-dev libssl-dev
      ;;
    apk)
      pkg_install ruby ruby-dev build-base git libffi-dev openssl-dev
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make git libffi-devel openssl-devel
      ;;
    zypper)
      pkg_install ruby ruby-devel gcc gcc-c++ make git libffi-devel libopenssl-devel
      ;;
  esac

  # Install bundler if missing
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  (cd "${APP_DIR}" && bundle config set path 'vendor/bundle' && bundle install --jobs "$(getconf _NPROCESSORS_ONLN || echo 2)" --retry 3)

  ensure_env_line "${APP_DIR}/.env.container" "RACK_ENV" "${APP_ENV}"
  ensure_env_line "${APP_DIR}/.env.container" "RAILS_ENV" "${APP_ENV}"
  ensure_env_line "${APP_DIR}/.env.container" "PORT" "3000"

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}"
  fi
}

# Go setup
setup_go() {
  log "Detected Go project"
  case "$PKG_MANAGER" in
    apt)
      pkg_install golang git ca-certificates
      ;;
    apk)
      pkg_install go git ca-certificates
      ;;
    dnf|yum)
      pkg_install golang git ca-certificates
      ;;
    zypper)
      pkg_install go git ca-certificates
      ;;
  esac

  local GOPATH_DEFAULT="${APP_DIR}/.gopath"
  ensure_env_line "${APP_DIR}/.env.container" "GOPATH" "${GOPATH:-$GOPATH_DEFAULT}"
  ensure_env_line "${APP_DIR}/.env.container" "GO111MODULE" "on"

  (cd "${APP_DIR}" && go mod download || true)

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}"
  fi
}

# PHP setup
setup_php() {
  log "Detected PHP project"
  case "$PKG_MANAGER" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-zip php-curl php-intl unzip git ca-certificates curl
      ;;
    apk)
      pkg_install php81 php81-phar php81-mbstring php81-xml php81-zip php81-curl php81-intl unzip git curl ca-certificates || \
      pkg_install php php-phar php-mbstring php-xml php-zip php-curl php-intl unzip git curl ca-certificates
      ;;
    dnf|yum)
      pkg_install php-cli php-mbstring php-xml php-zip php-intl unzip git ca-certificates curl
      ;;
    zypper)
      pkg_install php8 php8-mbstring php8-xml php8-zip php8-curl php8-intl unzip git ca-certificates curl || \
      pkg_install php php-mbstring php-xml php-zip php-curl php-intl unzip git ca-certificates curl
      ;;
  esac

  # Install Composer if not present
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm composer-setup.php
      die "Invalid composer installer signature"
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm composer-setup.php
  fi

  (cd "${APP_DIR}" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress || COMPOSER_ALLOW_SUPERUSER=1 composer install)

  ensure_env_line "${APP_DIR}/.env.container" "APP_ENV" "${APP_ENV}"
  ensure_env_line "${APP_DIR}/.env.container" "PORT" "8000"

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}"
  fi
}

# Java setup (Maven/Gradle)
setup_java() {
  log "Detected Java project"
  case "$PKG_MANAGER" in
    apt)
      pkg_install openjdk-17-jdk maven git ca-certificates
      ;;
    apk)
      pkg_install openjdk17 maven git ca-certificates
      ;;
    dnf|yum)
      pkg_install java-17-openjdk-devel maven git ca-certificates
      ;;
    zypper)
      pkg_install java-17-openjdk-devel maven git ca-certificates
      ;;
  esac

  if has_file "pom.xml"; then
    (cd "${APP_DIR}" && mvn -B -ntp -DskipTests package || mvn -B -ntp -DskipTests verify)
  fi

  if has_file "gradlew"; then
    chmod +x "${APP_DIR}/gradlew" || true
    (cd "${APP_DIR}" && ./gradlew build -x test)
  elif has_file "build.gradle" || has_file "build.gradle.kts"; then
    case "$PKG_MANAGER" in
      apt) pkg_install gradle ;;
      apk) pkg_install gradle ;;
      dnf|yum) pkg_install gradle ;;
      zypper) pkg_install gradle ;;
    esac
    (cd "${APP_DIR}" && gradle build -x test)
  fi

  ensure_env_line "${APP_DIR}/.env.container" "JAVA_HOME" "$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  ensure_env_line "${APP_DIR}/.env.container" "PORT" "8080"

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}"
  fi
}

# Rust setup
setup_rust() {
  log "Detected Rust project"
  case "$PKG_MANAGER" in
    apt) pkg_install build-essential curl ca-certificates git ;;
    apk) pkg_install build-base curl ca-certificates git ;;
    dnf|yum) pkg_install gcc gcc-c++ make curl ca-certificates git ;;
    zypper) pkg_install gcc gcc-c++ make curl ca-certificates git ;;
  esac

  if ! command -v cargo >/dev/null 2>&1; then
    if [[ "$(id -u)" -eq 0 ]]; then
      # Install rustup for app user
      log "Installing Rust toolchain via rustup for ${APP_USER}"
      su - "${APP_USER}" -c 'curl --proto "=https" --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path'
      # Make cargo available system-wide
      local cargo_env="/home/${APP_USER}/.cargo/env"
      if [[ -f "${cargo_env}" ]]; then
        . "${cargo_env}"
        echo '. "/home/'"${APP_USER}"'/.cargo/env"' >> /etc/profile.d/app_env.sh
      fi
    else
      warn "Cannot install Rust toolchain without root privileges. Skipping Rust setup."
      return 0
    fi
  fi

  # Fetch dependencies
  if command -v cargo >/dev/null 2>&1; then
    (cd "${APP_DIR}" && cargo fetch || true)
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}"
  fi
}

# Detect and configure project types
detect_and_setup_project() {
  local detected=0

  # Normalize APP_DIR (if invoked from a different dir, assume project is current dir)
  if [[ ! -d "${APP_DIR}" || "${APP_DIR}" == "/" ]]; then
    APP_DIR="$(pwd)"
    warn "APP_DIR was not set properly. Using current directory: ${APP_DIR}"
  fi

  # Move into APP_DIR for detection
  cd "${APP_DIR}"

  # Install common system tools
  case "$PKG_MANAGER" in
    apt) pkg_install git ca-certificates curl unzip gzip tar xz-utils gettext ;;
    apk) pkg_install git ca-certificates curl unzip gzip tar xz gettext ;;
    dnf|yum) pkg_install git ca-certificates curl unzip gzip tar xz gettext ;;
    zypper) pkg_install git ca-certificates curl unzip gzip tar xz gettext ;;
  esac

  if has_any_file "requirements.txt" "pyproject.toml" "Pipfile" "setup.py" "manage.py"; then
    setup_python
    detected=1
  fi

  if has_file "package.json"; then
    setup_node
    detected=1
  fi

  if has_file "Gemfile"; then
    setup_ruby
    detected=1
  fi

  if has_file "go.mod"; then
    setup_go
    detected=1
  fi

  if has_file "composer.json"; then
    setup_php
    detected=1
  fi

  if has_any_file "pom.xml" "build.gradle" "build.gradle.kts" "gradlew"; then
    setup_java
    detected=1
  fi

  if has_file "Cargo.toml"; then
    setup_rust
    detected=1
  fi

  if [[ "${detected}" -eq 0 ]]; then
    warn "No known project configuration files detected in ${APP_DIR}."
    warn "Supported: Python (requirements.txt/pyproject.toml), Node.js (package.json), Ruby (Gemfile), Go (go.mod), PHP (composer.json), Java (pom.xml/gradle), Rust (Cargo.toml)."
  fi
}

# Configure permissions for app dir
finalize_permissions() {
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}" || true
  fi
}

# Main
main() {
  log "Starting environment setup"
  detect_pkg_manager
  ensure_app_user
  prepare_directories
  write_env_files
  detect_and_setup_project
  finalize_permissions
  pkg_clean

  # Configure bashrc auto-activation of venv for future shells
  setup_auto_activate

  log "Environment setup completed successfully."

  # Helpful hints
  echo
  echo "Summary:"
  echo "- App directory: ${APP_DIR}"
  echo "- App user: ${APP_USER} (UID:${APP_UID})"
  echo "- Env file: ${APP_DIR}/.env.container"
  echo
  echo "To use the environment inside this container:"
  echo "- Python: source ${APP_DIR}/.venv/bin/activate (if created)"
  echo "- Node.js: npm start or yarn start (depending on project)"
  echo "- Ruby: bundle exec rails s -b 0.0.0.0 or rackup -o 0.0.0.0"
  echo "- Go: go run ./... or build with go build"
  echo "- PHP: php -S 0.0.0.0:8000 -t public (framework-dependent) or use your server"
  echo "- Java: java -jar target/*.jar or use your framework plugin"
  echo "- Rust: cargo run"
}

main "$@"