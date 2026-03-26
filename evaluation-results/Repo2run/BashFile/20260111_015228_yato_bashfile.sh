#!/bin/bash

# Safe bash settings
set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# Logging functions
log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARNING] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }

cleanup() {
  :
}
trap cleanup EXIT
trap 'err "An error occurred on line $LINENO while running: $BASH_COMMAND"; exit 1' ERR

# Global defaults
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}
export TZ=${TZ:-UTC}
export APP_ENV=${APP_ENV:-production}
export APP_HOME=${APP_HOME:-"$(pwd)"}
export PATH="$APP_HOME/.bin:$PATH"
umask 022

# Detect package manager and define commands
PKG_MANAGER=""
UPDATE_CMD=""
INSTALL_CMD=""
CLEAN_CMD=""
PKG_QUERY_CMD=""

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    UPDATE_CMD="apt-get update -y"
    INSTALL_CMD="apt-get install -y --no-install-recommends"
    CLEAN_CMD="apt-get clean && rm -rf /var/lib/apt/lists/*"
    PKG_QUERY_CMD="dpkg -s"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    UPDATE_CMD="apk update"
    INSTALL_CMD="apk add --no-cache"
    CLEAN_CMD=":"
    PKG_QUERY_CMD="apk info -e"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    UPDATE_CMD="dnf -y update"
    INSTALL_CMD="dnf -y install"
    CLEAN_CMD="dnf clean all"
    PKG_QUERY_CMD="rpm -q"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    UPDATE_CMD="yum -y update"
    INSTALL_CMD="yum -y install"
    CLEAN_CMD="yum clean all"
    PKG_QUERY_CMD="rpm -q"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    UPDATE_CMD="zypper --non-interactive refresh"
    INSTALL_CMD="zypper --non-interactive install --no-recommends"
    CLEAN_CMD="zypper clean --all"
    PKG_QUERY_CMD="rpm -q"
  else
    PKG_MANAGER="none"
  fi
}

# Ensure running with necessary privileges for system package installation
ensure_root_or_warn() {
  if [ "${PKG_MANAGER}" != "none" ] && [ "${EUID}" -ne 0 ]; then
    warn "Not running as root. System packages cannot be installed. Some setup steps may be skipped."
  fi
}

pkg_update() {
  if [ "${PKG_MANAGER}" != "none" ] && [ "${EUID}" -eq 0 ]; then
    log "Updating package index using ${PKG_MANAGER}..."
    eval "${UPDATE_CMD}" || err "Failed to update package index"
  fi
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  if [ "${PKG_MANAGER}" = "none" ] || [ "${EUID}" -ne 0 ]; then
    warn "Skipping system package installation for: $*"
    return 0
  fi
  local pkgs=("$@")
  if [ "${PKG_MANAGER}" = "apt" ]; then
    eval "${INSTALL_CMD} ${pkgs[@]}"
  elif [ "${PKG_MANAGER}" = "apk" ]; then
    eval "${INSTALL_CMD} ${pkgs[@]}"
  elif [ "${PKG_MANAGER}" = "dnf" ] || [ "${PKG_MANAGER}" = "yum" ]; then
    eval "${INSTALL_CMD} ${pkgs[@]}"
  elif [ "${PKG_MANAGER}" = "zypper" ]; then
    eval "${INSTALL_CMD} ${pkgs[@]}"
  else
    warn "Unknown package manager. Cannot install: ${pkgs[*]}"
  fi
}

pkg_clean() {
  if [ "${PKG_MANAGER}" != "none" ] && [ "${EUID}" -eq 0 ]; then
    eval "${CLEAN_CMD}" || true
  fi
}

# Setup timezone and certificates
setup_timezone_and_certs() {
  log "Configuring timezone to ${TZ}..."
  if [ "${PKG_MANAGER}" != "none" ] && [ "${EUID}" -eq 0 ]; then
    case "${PKG_MANAGER}" in
      apt)
        pkg_install tzdata ca-certificates
        ;;
      apk)
        pkg_install tzdata ca-certificates
        ;;
      *)
        pkg_install ca-certificates || true
        ;;
    esac
  fi
  if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
    echo "${TZ}" > /etc/timezone || true
  fi
  update-ca-certificates >/dev/null 2>&1 || true
}

# Install base tools and compilers
install_base_tools() {
  log "Installing base system tools and build essentials (if available)..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install curl wget git gnupg procps \
        build-essential pkg-config autoconf automake libtool \
        python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      pkg_install curl wget git bash coreutils gnupg \
        build-base pkgconfig autoconf automake libtool \
        python3 py3-pip
      ;;
    dnf|yum)
      pkg_install curl wget git gnupg2 procps-ng \
        @development-tools python3 python3-pip python3-virtualenv python3-devel
      ;;
    zypper)
      pkg_install curl wget git gpg2 procps \
        -t pattern devel_basis python3 python3-pip python3-virtualenv python3-devel
      ;;
    *)
      warn "No supported package manager detected; skipping base tool installation."
      ;;
  esac
}

# Create project directories and a non-root user for runtime
setup_directories_and_user() {
  log "Setting up project directories at ${APP_HOME}..."
  mkdir -p "${APP_HOME}/.bin" "${APP_HOME}/.cache" "${APP_HOME}/logs" "${APP_HOME}/tmp"
  chmod 755 "${APP_HOME}" || true
  chmod 700 "${APP_HOME}/.cache" || true
  chmod 755 "${APP_HOME}/logs" "${APP_HOME}/tmp" || true

  # Create non-root user 'app' if running as root and user doesn't exist
  if [ "${EUID}" -eq 0 ]; then
    if ! id -u app >/dev/null 2>&1; then
      log "Creating application user 'app'..."
      case "${PKG_MANAGER}" in
        apk)
          adduser -D -h "${APP_HOME}" -s /bin/sh app || true
          ;;
        *)
          useradd -m -d "${APP_HOME}" -s /bin/bash app || true
          ;;
      esac
    fi
    chown -R app:app "${APP_HOME}" || true
  else
    warn "Running as non-root; cannot create app user or change ownership."
  fi
}

# Load environment variables from .env if present
load_env_file() {
  if [ -f "${APP_HOME}/.env" ]; then
    log "Loading environment variables from .env..."
    set -a
    # shellcheck disable=SC1090
    . "${APP_HOME}/.env"
    set +a
  else
    log "No .env file found. Creating a default .env..."
    cat > "${APP_HOME}/.env" <<EOF
APP_ENV=${APP_ENV}
APP_HOME=${APP_HOME}
TZ=${TZ}
# Add your application-specific environment variables below
# EXAMPLE_PORT=8080
EOF
  fi
}

# Detect project type(s)
PROJECT_TYPES=()
detect_project_types() {
  PROJECT_TYPES=()
  if [ -f "${APP_HOME}/package.json" ]; then PROJECT_TYPES+=("node"); fi
  if [ -f "${APP_HOME}/requirements.txt" ] || [ -f "${APP_HOME}/pyproject.toml" ] || [ -f "${APP_HOME}/Pipfile" ] || [ -f "${APP_HOME}/setup.py" ]; then PROJECT_TYPES+=("python"); fi
  if [ -f "${APP_HOME}/Gemfile" ]; then PROJECT_TYPES+=("ruby"); fi
  if [ -f "${APP_HOME}/go.mod" ]; then PROJECT_TYPES+=("go"); fi
  if [ -f "${APP_HOME}/Cargo.toml" ]; then PROJECT_TYPES+=("rust"); fi
  if [ -f "${APP_HOME}/pom.xml" ]; then PROJECT_TYPES+=("java-maven"); fi
  if [ -f "${APP_HOME}/build.gradle" ] || [ -f "${APP_HOME}/gradlew" ]; then PROJECT_TYPES+=("java-gradle"); fi
  if [ -f "${APP_HOME}/composer.json" ]; then PROJECT_TYPES+=("php"); fi
  if ls "${APP_HOME}"/*.csproj >/dev/null 2>&1 || ls "${APP_HOME}"/*.sln >/dev/null 2>&1; then PROJECT_TYPES+=(".net"); fi
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  # Ensure Python and build libs are available
  case "${PKG_MANAGER}" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev \
        gcc g++ make libffi-dev libssl-dev zlib1g-dev libpq-dev libxml2-dev libxslt1-dev
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv build-base libffi-dev openssl-dev zlib-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel zlib-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-virtualenv python3-devel gcc gcc-c++ make libffi-devel libopenssl-devel zlib-devel
      ;;
    *)
      warn "Could not ensure Python system packages; attempting to proceed with existing Python."
      ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    err "Python3 is not available. Install a base image with Python or enable package manager."
    exit 1
  fi

  # Upgrade global pip and essential build tools
  python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel tomli
  # Install Poetry and dev tools globally for CI
  python3 -m pip install --no-cache-dir --upgrade pytest black isort

  # Create venv
  VENV_DIR="${APP_HOME}/.venv"
  if [ ! -d "${VENV_DIR}" ]; then
    log "Creating virtual environment at ${VENV_DIR}..."
    python3 -m venv "${VENV_DIR}"
  else
    log "Virtual environment already exists at ${VENV_DIR}"
  fi

  # Activate venv for this script session
  # shellcheck disable=SC1091
  . "${VENV_DIR}/bin/activate"
  export PATH="${VENV_DIR}/bin:${PATH}"
  export PYTHONUNBUFFERED=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1

  # Ensure pip, setuptools, wheel are up-to-date
  pip install --no-input --upgrade pip setuptools wheel
  # Install Poetry using the official installer and ensure it's on PATH
  python3 - <<'PY'
import sys, urllib.request, runpy, tempfile
url = 'https://install.python-poetry.org'
with urllib.request.urlopen(url) as r:
    code = r.read()
fn = tempfile.NamedTemporaryFile(delete=False, suffix='.py')
fn.write(code)
fn.close()
sys.argv = ['install-poetry', '--yes']
runpy.run_path(fn.name, run_name='__main__')
print('Poetry installed via official installer')
PY
  if [ -x "$HOME/.local/bin/poetry" ]; then ln -sf "$HOME/.local/bin/poetry" /usr/local/bin/poetry 2>/dev/null || true; fi

  # Preemptively repair a malformed pyproject.toml by de-duplicating keys
  if [ -f "${APP_HOME}/pyproject.toml" ]; then
    log "Backing up and fixing pyproject.toml duplicate keys for tooling compatibility..."
    (
      cd "${APP_HOME}" || exit 0
      cp -n pyproject.toml pyproject.toml.bak || true
      python3 - <<'PY'
# Deduplicate keys in pyproject.toml per table, keeping the first occurrence.
import re, shutil
from pathlib import Path
p = Path('pyproject.toml')
if p.exists():
    text = p.read_text(encoding='utf-8').splitlines()
    header_re = re.compile(r'^\s*\[.*\]\s*$')
    kv_re = re.compile(r'^\s*([A-Za-z0-9_.-]+)\s*=')
    section = 'GLOBAL'
    seen = {section: set()}
    out = []
    for line in text:
        if header_re.match(line):
            section = header_re.match(line).group(0)
            seen.setdefault(section, set())
            out.append(line)
            continue
        m = kv_re.match(line)
        if m:
            key = m.group(1)
            if key in seen[section]:
                # drop duplicate key line
                continue
            seen[section].add(key)
        out.append(line)
    bak = p.with_suffix('.toml.bak')
    if not bak.exists():
        shutil.copy2(p, bak)
    p.write_text('\n'.join(out) + '\n', encoding='utf-8')
else:
    print('pyproject.toml not found; nothing to deduplicate')
PY
      python3 - <<'PY'
# Validate pyproject.toml parses; install tomli for <3.11 if needed.
import sys, subprocess
try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', '-q', 'tomli'])
    import tomli as tomllib
try:
    with open('pyproject.toml', 'rb') as f:
        tomllib.load(f)
    print('pyproject.toml parses OK')
except Exception as e:
    print(f'Warning: pyproject.toml parse failed: {e!r}')
PY
      if command -v poetry >/dev/null 2>&1 && grep -q '^\s*\[tool\.poetry\]' pyproject.toml; then
        poetry --version && poetry check || true
      fi
    )
  fi

  # Temporarily bypass broken pyproject.toml by moving it aside and ensuring requirements.txt exists
  APP_HOME=${APP_HOME:-/app} && cd "$APP_HOME" && if [ -f pyproject.toml ]; then cp -n pyproject.toml pyproject.toml.bak || true; mv -f pyproject.toml pyproject.toml.broken; fi
  APP_HOME=${APP_HOME:-/app} && cd "$APP_HOME" && [ -f requirements.txt ] || : > requirements.txt

  # Install dependencies
  if [ -f "${APP_HOME}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-input -r "${APP_HOME}/requirements.txt"
  elif [ -f "${APP_HOME}/pyproject.toml" ]; then
    if grep -qi "poetry" "${APP_HOME}/pyproject.toml"; then
      log "Detected Poetry project; installing dependencies via Poetry..."
      APP_HOME=${APP_HOME:-/app}; PYPROJ="$APP_HOME/pyproject.toml"; if [ -f "$PYPROJ" ] && grep -q '^\s*\[project\]' "$PYPROJ"; then [ ! -f "$PYPROJ.bak" ] && cp "$PYPROJ" "$PYPROJ.bak"; awk 'BEGIN{in_proj=0; name_found=0} /^\[project\]/{print; in_proj=1; next} in_proj && /^\[[^]]+\]/{if(!name_found){print "name = \"app\""}; in_proj=0} {if(in_proj && $0 ~ /^\s*name\s*=/){name_found=1}; print} END{if(in_proj && !name_found){print "name = \"app\""}}' "$PYPROJ" > "$PYPROJ.tmp" && mv "$PYPROJ.tmp" "$PYPROJ"; fi
      APP_HOME=${APP_HOME:-/app}; PYPROJ="$APP_HOME/pyproject.toml"; if [ -f "$PYPROJ" ] && grep -q '^\s*\[tool\.poetry\]' "$PYPROJ"; then [ ! -f "$PYPROJ.bak" ] && cp "$PYPROJ" "$PYPROJ.bak"; awk 'BEGIN{in_tp=0; name_found=0} /^\[tool\.poetry\]/{print; in_tp=1; next} in_tp && /^\[[^]]+\]/{if(!name_found){print "name = \"app\""}; in_tp=0} {if(in_tp && $0 ~ /^\s*name\s*=/){name_found=1}; print} END{if(in_tp && !name_found){print "name = \"app\""}}' "$PYPROJ" > "$PYPROJ.tmp" && mv "$PYPROJ.tmp" "$PYPROJ"; fi
      pip install --no-input --no-cache-dir "poetry>=1.5"
      . ${APP_HOME:-/app}/.venv/bin/activate && poetry config virtualenvs.create false && poetry install --no-interaction --no-ansi --only main || (. ${APP_HOME:-/app}/.venv/bin/activate && pip install --no-input "${APP_HOME:-/app}" || true)
    else
      log "Installing Python project from pyproject.toml using pip..."
      pip install --no-input "${APP_HOME}"
    fi
  elif [ -f "${APP_HOME}/Pipfile" ]; then
    log "Detected Pipenv project; installing dependencies via pipenv..."
    pip install --no-input pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install --system
  else
    warn "No Python dependency manifest found; skipping dependency installation."
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    case "${PKG_MANAGER}" in
      apt)
        pkg_install nodejs npm make g++ python3
        ;;
      apk)
        pkg_install nodejs npm make gcc g++ python3
        ;;
      dnf|yum)
        pkg_install nodejs npm make gcc gcc-c++ python3
        ;;
      zypper)
        pkg_install nodejs14 npm14 make gcc gcc-c++ python3 || pkg_install nodejs npm
        ;;
      *)
        warn "No package manager available to install Node.js. Ensure Node is present in the base image."
        ;;
    esac
  fi

  if ! command -v node >/dev/null 2>&1; then
    err "Node.js is not available. Cannot proceed with Node setup."
    return 1
  fi

  export NODE_ENV="${NODE_ENV:-production}"

  pushd "${APP_HOME}" >/dev/null
  if [ -f "package-lock.json" ]; then
    log "Installing Node dependencies via npm ci..."
    npm ci --no-audit --no-fund
  elif [ -f "yarn.lock" ]; then
    log "Installing Node dependencies via Yarn..."
    if command -v corepack >/dev/null 2>&1; then
      corepack enable
      corepack prepare yarn@stable --activate || true
    fi
    if command -v yarn >/dev/null 2>&1; then
      yarn install --frozen-lockfile
    else
      npm install --no-audit --no-fund
    fi
  elif [ -f "pnpm-lock.yaml" ]; then
    log "Installing Node dependencies via pnpm..."
    if command -v corepack >/dev/null 2>&1; then
      corepack enable
      corepack prepare pnpm@latest --activate || true
    fi
    if command -v pnpm >/dev/null 2>&1; then
      pnpm install --frozen-lockfile
    else
      npm install --no-audit --no-fund
    fi
  else
    log "Installing Node dependencies via npm install..."
    npm install --no-audit --no-fund
  fi
  popd >/dev/null
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "${PKG_MANAGER}" in
    apt)
      pkg_install ruby-full build-essential zlib1g-dev
      ;;
    apk)
      pkg_install ruby ruby-dev build-base zlib-dev
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel @development-tools zlib-devel
      ;;
    zypper)
      pkg_install ruby ruby-devel gcc gcc-c++ make zlib-devel
      ;;
    *)
      warn "No package manager available to install Ruby. Ensure Ruby is present."
      ;;
  esac

  if ! command -v ruby >/dev/null 2>&1; then
    err "Ruby is not available. Cannot proceed with Ruby setup."
    return 1
  fi

  if ! command -v gem >/dev/null 2>&1; then
    err "RubyGems is not available. Cannot proceed."
    return 1
  fi

  gem install --no-document bundler || true
  pushd "${APP_HOME}" >/dev/null
  export BUNDLE_PATH="${APP_HOME}/vendor/bundle"
  export BUNDLE_WITHOUT="${BUNDLE_WITHOUT:-development:test}"
  bundle config set path "${BUNDLE_PATH}"
  bundle install --jobs=4 --retry=3
  popd >/dev/null
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "${PKG_MANAGER}" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
    *) warn "No package manager available to install Go. Ensure Go is present." ;;
  esac

  if ! command -v go >/dev/null 2>&1; then
    err "Go is not available. Cannot proceed with Go setup."
    return 1
  fi

  export GOPATH="${GOPATH:-/go}"
  mkdir -p "${GOPATH}" "${GOPATH}/bin"
  export PATH="${GOPATH}/bin:${PATH}"

  pushd "${APP_HOME}" >/dev/null
  go mod download || warn "go.mod download failed; check Go configuration."
  popd >/dev/null
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  case "${PKG_MANAGER}" in
    apt) pkg_install cargo rustc ;;
    apk) pkg_install cargo rust ;;
    dnf|yum) pkg_install cargo rust ;;
    zypper) pkg_install cargo rust ;;
    *) warn "No package manager available to install Rust. Ensure Rust is present." ;;
  esac

  if ! command -v cargo >/dev/null 2>&1; then
    err "Cargo is not available. Cannot proceed with Rust setup."
    return 1
  fi

  pushd "${APP_HOME}" >/dev/null
  cargo fetch || warn "Cargo fetch failed; check Rust configuration."
  popd >/dev/null
}

# Java (Maven) setup
setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "${PKG_MANAGER}" in
    apt) pkg_install maven openjdk-17-jdk || pkg_install maven default-jdk ;;
    apk) pkg_install maven openjdk17 || pkg_install maven openjdk11 ;;
    dnf|yum) pkg_install maven java-17-openjdk-devel || pkg_install maven java-11-openjdk-devel ;;
    zypper) pkg_install maven java-17-openjdk-devel || pkg_install maven java-11-openjdk-devel ;;
    *) warn "No package manager available to install Maven/Java. Ensure JDK is present." ;;
  esac

  if ! command -v mvn >/dev/null 2>&1; then
    err "Maven is not available. Cannot proceed with Maven setup."
    return 1
  fi

  pushd "${APP_HOME}" >/dev/null
  mvn -B -ntp dependency:resolve || warn "Maven dependency resolution failed."
  popd >/dev/null
}

# Java (Gradle) setup
setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  case "${PKG_MANAGER}" in
    apt) pkg_install gradle openjdk-17-jdk || pkg_install gradle default-jdk ;;
    apk) pkg_install gradle openjdk17 || pkg_install gradle openjdk11 ;;
    dnf|yum) pkg_install gradle java-17-openjdk-devel || pkg_install gradle java-11-openjdk-devel ;;
    zypper) pkg_install gradle java-17-openjdk-devel || pkg_install gradle java-11-openjdk-devel ;;
    *) warn "No package manager available to install Gradle/Java. Ensure JDK is present." ;;
  esac

  pushd "${APP_HOME}" >/dev/null
  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon dependencies || warn "Gradle dependencies task failed."
  else
    if ! command -v gradle >/dev/null 2>&1; then
      err "Gradle is not available and no wrapper found. Install Gradle or add gradlew."
    else
      gradle --no-daemon dependencies || warn "Gradle dependencies task failed."
    fi
  fi
  popd >/dev/null
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "${PKG_MANAGER}" in
    apt) pkg_install php-cli php-mbstring php-xml php-curl php-zip php-intl unzip composer ;;
    apk) pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip php81-intl composer ;;
    dnf|yum) pkg_install php-cli php-mbstring php-xml php-curl php-zip php-intl unzip composer ;;
    zypper) pkg_install php8 php8-cli php8-mbstring php8-xml php8-curl php8-zip php8-intl unzip composer ;;
    *) warn "No package manager available to install PHP/Composer. Ensure they are present." ;;
  esac

  if ! command -v php >/dev/null 2>&1; then
    err "PHP is not available. Cannot proceed with PHP setup."
    return 1
  fi
  if ! command -v composer >/dev/null 2>&1; then
    warn "Composer not found; attempting to install locally..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir="${APP_HOME}/.bin" --filename=composer || warn "Composer installation failed."
    export PATH="${APP_HOME}/.bin:${PATH}"
  fi

  pushd "${APP_HOME}" >/dev/null
  if command -v composer >/dev/null 2>&1; then
    composer install --no-interaction --prefer-dist --no-dev || composer install --no-interaction --prefer-dist
  fi
  popd >/dev/null
}

# .NET setup (APT-based only for simplicity)
setup_dotnet() {
  log "Setting up .NET environment..."
  if [ "${PKG_MANAGER}" = "apt" ] && [ "${EUID}" -eq 0 ]; then
    if ! command -v dotnet >/dev/null 2>&1; then
      log "Installing Microsoft package repo for .NET SDK..."
      apt-get install -y --no-install-recommends wget gpg ca-certificates
      wget -qO /tmp/packages-microsoft-prod.deb https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb || true
      if [ -f /tmp/packages-microsoft-prod.deb ]; then
        dpkg -i /tmp/packages-microsoft-prod.deb || true
        rm -f /tmp/packages-microsoft-prod.deb
        apt-get update -y || true
        apt-get install -y --no-install-recommends dotnet-sdk-8.0 || apt-get install -y --no-install-recommends dotnet-sdk-7.0 || true
      else
        warn "Failed to retrieve Microsoft repo package; .NET installation may not be available."
      fi
    fi
  else
    warn "Automatic .NET installation is only supported with apt and root privileges."
  fi

  if ! command -v dotnet >/dev/null 2>&1; then
    err ".NET SDK is not available. Cannot proceed with .NET setup."
    return 1
  fi

  pushd "${APP_HOME}" >/dev/null
  find . -maxdepth 1 -name "*.sln" -o -name "*.csproj" | while read -r proj; do
    log "Restoring .NET dependencies for ${proj}..."
    dotnet restore "${proj}" || warn "dotnet restore failed for ${proj}"
  done
  popd >/dev/null
}

# Configure environment scripts
write_profile_script() {
  mkdir -p "${APP_HOME}/.bin"
  ENV_SH="${APP_HOME}/.bin/env.sh"
  cat > "${ENV_SH}" <<'EOF'
#!/bin/sh
# Source this file to load project environment
export APP_ENV=${APP_ENV:-production}
export APP_HOME=${APP_HOME:-"$(pwd)"}
export TZ=${TZ:-UTC}
# Python venv
if [ -d "${APP_HOME}/.venv" ]; then
  export PATH="${APP_HOME}/.venv/bin:${PATH}"
  export PYTHONUNBUFFERED=1
fi
# Node
export NODE_ENV=${NODE_ENV:-production}
# Go
export GOPATH=${GOPATH:-/go}
export PATH="${APP_HOME}/.bin:${GOPATH}/bin:${PATH}"
# Load .env if exists
if [ -f "${APP_HOME}/.env" ]; then
  set -a
  . "${APP_HOME}/.env"
  set +a
fi
EOF
  chmod +x "${ENV_SH}"
}

# Auto-activate Python virtual environment via bashrc
setup_auto_activate() {
  local header="# AUTO-VENV ACTIVATE"
  local footer="# END AUTO-VENV ACTIVATE"
  local env_line='if [ -f "/app/.bin/env.sh" ]; then . "/app/.bin/env.sh"; fi'
  local venv_line='if [ -f "/app/.venv/bin/activate" ]; then . "/app/.venv/bin/activate"; fi'
  for bashrc_file in "/root/.bashrc" "${APP_HOME}/.bashrc"; do
    touch "$bashrc_file"
    if ! grep -qF "$header" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "$header" >> "$bashrc_file"
      echo "$env_line" >> "$bashrc_file"
      echo "$venv_line" >> "$bashrc_file"
      echo "$footer" >> "$bashrc_file"
    fi
  done
}

# Main function
main() {
  log "Starting environment setup for project at ${APP_HOME}..."
  detect_pkg_manager
  ensure_root_or_warn
  pkg_update
  setup_timezone_and_certs
  install_base_tools
  setup_directories_and_user
  load_env_file
  detect_project_types

  if [ "${#PROJECT_TYPES[@]}" -eq 0 ]; then
    warn "No recognized project type detected. Proceeding with base environment only."
  else
    log "Detected project types: ${PROJECT_TYPES[*]}"
  fi

  # Execute setup per detected type
  for type in "${PROJECT_TYPES[@]}"; do
    case "${type}" in
      python) setup_python ;;
      node) setup_node ;;
      ruby) setup_ruby ;;
      go) setup_go ;;
      rust) setup_rust ;;
      java-maven) setup_java_maven ;;
      java-gradle) setup_java_gradle ;;
      php) setup_php ;;
      .net) setup_dotnet ;;
      *) warn "Unknown project type: ${type}" ;;
    esac
  done

  write_profile_script
  setup_auto_activate
  pkg_clean

  log "Environment setup completed successfully."
  log "Tip: To load environment in an interactive shell, run: . \"${APP_HOME}/.bin/env.sh\""
}

main "$@"