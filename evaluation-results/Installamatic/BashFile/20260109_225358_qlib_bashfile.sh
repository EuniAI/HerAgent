#!/usr/bin/env bash
# Universal project environment setup script for containerized (Docker) environments.
# - Detects popular stacks (Python, Node.js, Ruby, Go, Java, PHP, Rust, .NET)
# - Installs required system packages and runtimes
# - Installs project dependencies
# - Configures environment variables and paths
# - Idempotent and safe to run multiple times
# - No sudo required (assumes root inside container)

set -Eeuo pipefail
IFS=$'\n\t'

# Globals
PROJECT_ROOT="${PROJECT_ROOT:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
LOG_DIR="${LOG_DIR:-/var/log/app}"
CACHE_DIR="${CACHE_DIR:-${PROJECT_ROOT}/.cache}"
PROFILE_DIR="/etc/profile.d"
ENV_FILE="${PROFILE_DIR}/project_env.sh"
STATE_DIR="/var/lib/project-setup"
STATE_FILE="${STATE_DIR}/state.v1"

# Colors (safe if not supported)
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

log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

cleanup() {
  # Placeholder for future cleanup actions
  :
}
trap cleanup EXIT

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "This script must run as root inside the container."
  fi
}

# Detect package manager
PKG_MANAGER=""
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    die "Unsupported base image: no apt, apk, dnf, yum, or microdnf found."
  fi
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      # apk doesn't need separate update when using --no-cache
      :
      ;;
    dnf|yum|microdnf)
      :
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    microdnf)
      microdnf install -y "$@"
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MANAGER" in
    apt)
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
      ;;
    dnf|yum|microdnf)
      dnf clean all >/dev/null 2>&1 || true
      yum clean all >/dev/null 2>&1 || true
      rm -rf /var/cache/dnf /var/cache/yum /tmp/* /var/tmp/* || true
      ;;
  esac
}

install_base_packages() {
  log "Installing base system packages..."
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git bash tini xz-utils unzip tar gzip bzip2 procps \
        build-essential pkg-config openssl libssl-dev python3 python3-venv python3-pip python3-dev \
        gcc g++ make
      ;;
    apk)
      pkg_install ca-certificates curl git bash tini xz unzip tar gzip bzip2 procps \
        build-base pkgconfig openssl-dev python3 py3-pip python3-dev
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl git bash tini xz unzip tar gzip bzip2 procps-ng \
        gcc gcc-c++ make openssl-devel python3 python3-pip python3-devel
      ;;
  esac
  update-ca-certificates >/dev/null 2>&1 || true
  pkg_clean
  log "Base system packages installed."
}

ensure_dirs() {
  log "Ensuring project directories exist..."
  mkdir -p "$PROJECT_ROOT" "$LOG_DIR" "$CACHE_DIR" "$PROFILE_DIR" "$STATE_DIR"
  chmod 755 "$PROJECT_ROOT" "$PROFILE_DIR"
  chmod 750 "$LOG_DIR" "$CACHE_DIR" "$STATE_DIR"
  # Common subdirs
  mkdir -p "${PROJECT_ROOT}/bin" "${PROJECT_ROOT}/tmp" "${PROJECT_ROOT}/var"
}

write_env_profile() {
  log "Configuring environment profile at ${ENV_FILE}..."
  # Preserve customizations if already present; update in-place idempotently
  cat > "$ENV_FILE".tmp <<'EOF'
# Auto-generated project environment (do not edit manually)
export PROJECT_ROOT="${PROJECT_ROOT:-/app}"
export APP_ENV="${APP_ENV:-production}"
export APP_PORT="${APP_PORT:-8080}"
export PATH="${PROJECT_ROOT}/bin:${PATH}"

# NVM/Node
export NVM_DIR="${NVM_DIR:-/opt/nvm}"
if [ -s "${NVM_DIR}/nvm.sh" ]; then
  . "${NVM_DIR}/nvm.sh"
  # Ensure corepack for yarn/pnpm if available
  if command -v corepack >/dev/null 2>&1; then
    export COREPACK_ENABLE_STRICT=0
  fi
fi

# Python venv
if [ -d "${PROJECT_ROOT}/.venv" ]; then
  export VIRTUAL_ENV="${PROJECT_ROOT}/.venv"
  export PATH="${VIRTUAL_ENV}/bin:${PATH}"
fi

# Go
export GOROOT="${GOROOT:-/usr/local/go}"
export GOPATH="${GOPATH:-/go}"
[ -d "${GOPATH}/bin" ] && export PATH="${GOPATH}/bin:${PATH}"
[ -d "${GOROOT}/bin" ] && export PATH="${GOROOT}/bin:${PATH}"

# Rust
if [ -d "/root/.cargo/bin" ]; then
  export PATH="/root/.cargo/bin:${PATH}"
fi

# PHP Composer global bin
if [ -d "/root/.composer/vendor/bin" ]; then
  export PATH="/root/.composer/vendor/bin:${PATH}"
fi

umask 022
EOF

  # Replace tokens for runtime defaults
  sed -i \
    -e "s|\${PROJECT_ROOT:-/app}|${PROJECT_ROOT}|g" \
    -e "s|\${APP_ENV:-production}|${APP_ENV}|g" \
    -e "s|\${APP_PORT:-8080}|${APP_PORT}|g" \
    "$ENV_FILE".tmp

  mv "$ENV_FILE".tmp "$ENV_FILE"
  chmod 644 "$ENV_FILE"
}

ensure_venv_auto_activate() {
  local bashrc="${HOME:-/root}/.bashrc"
  if ! grep -q "# BEGIN auto-venv-activate" "$bashrc" 2>/dev/null; then
    cat >> "$bashrc" <<'BASHRC'
# BEGIN auto-venv-activate
[ -f /etc/profile ] && . /etc/profile || true
[ -f /etc/profile.d/project_env.sh ] && . /etc/profile.d/project_env.sh || true
if [ -d "${PROJECT_ROOT:-/app}/.venv" ] && [ -f "${PROJECT_ROOT:-/app}/.venv/bin/activate" ]; then
  . "${PROJECT_ROOT:-/app}/.venv/bin/activate"
fi
# END auto-venv-activate
BASHRC
  fi
}

setup_auto_activate() {
  # Wrapper to ensure virtualenv auto-activation logic is present in ~/.bashrc
  ensure_venv_auto_activate
}

# Stack detection
HAS_PYTHON=0
HAS_NODE=0
HAS_RUBY=0
HAS_GO=0
HAS_JAVA_MAVEN=0
HAS_JAVA_GRADLE=0
HAS_PHP=0
HAS_RUST=0
HAS_DOTNET=0

detect_stack() {
  log "Detecting project stack in ${PROJECT_ROOT}..."
  pushd "$PROJECT_ROOT" >/dev/null || die "Project root not accessible"

  # Python
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || compgen -G "*.py" >/dev/null 2>&1; then
    HAS_PYTHON=1
  fi
  # Node.js
  if [ -f "package.json" ]; then
    HAS_NODE=1
  fi
  # Ruby
  if [ -f "Gemfile" ]; then
    HAS_RUBY=1
  fi
  # Go
  if [ -f "go.mod" ]; then
    HAS_GO=1
  fi
  # Java
  if [ -f "pom.xml" ]; then
    HAS_JAVA_MAVEN=1
  fi
  if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || compgen -G "gradlew" >/dev/null 2>&1; then
    HAS_JAVA_GRADLE=1
  fi
  # PHP
  if [ -f "composer.json" ]; then
    HAS_PHP=1
  fi
  # Rust
  if [ -f "Cargo.toml" ]; then
    HAS_RUST=1
  fi
  # .NET
  if compgen -G "*.csproj" >/dev/null 2>&1 || [ -f "global.json" ]; then
    HAS_DOTNET=1
  fi

  popd >/dev/null || true

  log "Detected stacks: Python=${HAS_PYTHON} Node=${HAS_NODE} Ruby=${HAS_RUBY} Go=${HAS_GO} Java(Maven)=${HAS_JAVA_MAVEN} Java(Gradle)=${HAS_JAVA_GRADLE} PHP=${HAS_PHP} Rust=${HAS_RUST} .NET=${HAS_DOTNET}"
}

install_python_stack() {
  [ "$HAS_PYTHON" -eq 1 ] || return 0
  log "Setting up Python environment..."
  # Ensure python3 and pip are available from base packages
  command -v python3 >/dev/null 2>&1 || die "python3 missing after base install"
  command -v pip3 >/dev/null 2>&1 || die "pip3 missing after base install"

  # Create venv if needed
  if [ ! -d "${PROJECT_ROOT}/.venv" ]; then
    python3 -m venv "${PROJECT_ROOT}/.venv"
  fi
  # Activate venv for this shell execution
  # shellcheck source=/dev/null
  . "${PROJECT_ROOT}/.venv/bin/activate"
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y build-essential python3-dev; fi
  pip config set global.no-build-isolation true || true
  pip config set global.prefer-binary true || true
  mkdir -p "${HOME:-/root}/.pip" && printf "[global]\nno-build-isolation = true\nprefer-binary = true\n" > "${HOME:-/root}/.pip/pip.conf"
  python -m pip install --upgrade "pip>=24.0" "setuptools>=69" "wheel>=0.41"
  python -m pip uninstall -y pyqlib || true
  python -m pip install --upgrade --only-binary=:all: "numpy>=1.26,<2" "cython>=0.29.36" setuptools-scm packaging

  pushd "$PROJECT_ROOT" >/dev/null || die "Project root not accessible"
  # Ensure minimal requirements.txt exists if missing
  test -f requirements.txt || printf "fire\npyqlib\n" > requirements.txt
  python -m pip install -r requirements.txt
  # Build C extensions in place if setup.py exists
  if [ -f "setup.py" ]; then
    python setup.py build_ext --inplace || true
  fi
  if [ -f "pyproject.toml" ]; then
    cp pyproject.toml pyproject.toml.bak
    python - <<'PY'
import os, re
p = 'pyproject.toml'
if not os.path.exists(p):
    raise SystemExit(0)
with open(p, 'r', encoding='utf-8') as f:
    lines = f.readlines()
out = []
seen = False
in_dup = False
for line in lines:
    if re.match(r'^\s*\[build-system\]\s*$', line):
        if seen:
            in_dup = True
            out.append('# ' + line.rstrip() + '\n')
            continue
        else:
            seen = True
            in_dup = False
            out.append(line)
            continue
    if in_dup:
        if line.lstrip().startswith('['):  # next table starts
            in_dup = False
            out.append(line)
        else:
            out.append('# ' + line if line.strip() else line)
    else:
        out.append(line)
with open(p, 'w', encoding='utf-8') as f:
    f.writelines(out)
PY
  fi
  if [ -f "pyproject.toml" ]; then
    # Attempt to install the project (PEP 517) or dev deps if any
    # Prefer uv/poetry if present, else pip
    if grep -q "\[tool.poetry\]" pyproject.toml 2>/dev/null; then
      pip install poetry
      poetry config virtualenvs.create false
      if [ -f "poetry.lock" ]; then
        poetry install --no-interaction --no-ansi $( [ "$APP_ENV" = "production" ] && echo "--only main" )
      else
        poetry install --no-interaction --no-ansi $( [ "$APP_ENV" = "production" ] && echo "--only main" )
      fi
    else
      PIP_PREFER_BINARY=1 python -m pip install -e . --no-build-isolation
    fi
  else
    PIP_PREFER_BINARY=1 python -m pip install -e . --no-build-isolation
  fi
  # Ensure extensions are built in-place after installation
  if [ -f "setup.py" ]; then
    python setup.py build_ext --inplace || true
  fi
  python -m pip install --upgrade --no-cache-dir fire pyqlib pytest coverage gdown arctic
  popd >/dev/null || true

  log "Python environment ready."
}

install_nvm_node() {
  # Install nvm and Node.js (LTS or specified)
  local NVM_DIR_LOCAL="/opt/nvm"
  if [ ! -d "$NVM_DIR_LOCAL" ]; then
    mkdir -p "$NVM_DIR_LOCAL"
    export NVM_DIR="$NVM_DIR_LOCAL"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  export NVM_DIR="$NVM_DIR_LOCAL"
  # shellcheck source=/dev/null
  . "${NVM_DIR}/nvm.sh"
  local NODE_VERSION="lts/*"
  if [ -f "${PROJECT_ROOT}/.nvmrc" ]; then
    NODE_VERSION="$(cat "${PROJECT_ROOT}/.nvmrc" | tr -d '[:space:]')"
  else
    # Try engines field from package.json
    if [ -f "${PROJECT_ROOT}/package.json" ]; then
      local enginesNode
      enginesNode=$(awk '/"engines"\s*:\s*{/{flag=1} flag && /"node"\s*:/ {print; flag=0}' "${PROJECT_ROOT}/package.json" 2>/dev/null | sed -E 's/.*"node"\s*:\s*"([^"]+)".*/\1/' || true)
      if [ -n "${enginesNode:-}" ]; then NODE_VERSION="$enginesNode"; fi
    fi
  fi
  nvm install "$NODE_VERSION"
  nvm alias default "$NODE_VERSION"
  nvm use default
  # Enable corepack for yarn/pnpm if available
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi
}

install_node_stack() {
  [ "$HAS_NODE" -eq 1 ] || return 0
  log "Setting up Node.js environment..."
  install_nvm_node
  pushd "$PROJECT_ROOT" >/dev/null || die "Project root not accessible"
  # Prefer npm ci if lockfile present
  if [ -f "package-lock.json" ]; then
    npm ci --no-audit --omit=optional
  else
    # Respect yarn/pnpm if lockfile indicates
    if [ -f "yarn.lock" ]; then
      if command -v yarn >/dev/null 2>&1; then
        yarn install --frozen-lockfile
      else
        # Use corepack yarn if available
        if command -v corepack >/dev/null 2>&1; then
          corepack enable || true
          corepack prepare yarn@stable --activate || true
          yarn install --frozen-lockfile
        else
          npm install --no-audit --omit=optional
        fi
      fi
    elif [ -f "pnpm-lock.yaml" ]; then
      if command -v pnpm >/dev/null 2>&1; then
        pnpm install --frozen-lockfile
      else
        if command -v corepack >/dev/null 2>&1; then
          corepack enable || true
          corepack prepare pnpm@latest --activate || true
          pnpm install --frozen-lockfile
        else
          npm install --no-audit --omit=optional
        fi
      fi
    else
      npm install --no-audit --omit=optional
    fi
  fi
  popd >/dev/null || true
  log "Node.js dependencies installed."
}

install_ruby_stack() {
  [ "$HAS_RUBY" -eq 1 ] || return 0
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install ruby-full build-essential libssl-dev zlib1g-dev libreadline-dev
      ;;
    apk)
      pkg_install ruby ruby-dev ruby-bundler build-base openssl-dev zlib-dev readline-dev
      ;;
    dnf|yum|microdnf)
      pkg_install ruby ruby-devel make gcc gcc-c++ openssl-devel zlib-devel readline-devel
      ;;
  esac
  pkg_clean
  pushd "$PROJECT_ROOT" >/dev/null || die "Project root not accessible"
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document
  fi
  bundle config set path 'vendor/bundle'
  if [ "$APP_ENV" = "production" ]; then
    bundle install --without development test
  else
    bundle install
  fi
  popd >/dev/null || true
  log "Ruby dependencies installed."
}

install_go_stack() {
  [ "$HAS_GO" -eq 1 ] || return 0
  log "Setting up Go environment..."
  local GO_VERSION="${GO_VERSION:-1.22.6}"
  local ARCH="$(uname -m)"
  local GO_ARCH="amd64"
  case "$ARCH" in
    x86_64|amd64) GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    armv7l|armv7) GO_ARCH="armv6l" ;;
    *) warn "Unknown arch ${ARCH}, defaulting to amd64"; GO_ARCH="amd64" ;;
  esac
  if ! command -v go >/dev/null 2>&1; then
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tgz
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
  fi
  mkdir -p /go/bin
  export GOROOT="/usr/local/go"
  export GOPATH="/go"
  export PATH="${GOROOT}/bin:${GOPATH}/bin:${PATH}"
  pushd "$PROJECT_ROOT" >/dev/null || die "Project root not accessible"
  go env -w GOPATH="$GOPATH" GOMODCACHE="$GOPATH/pkg/mod" >/dev/null 2>&1 || true
  go mod download || true
  popd >/dev/null || true
  log "Go environment ready."
}

install_java_stack() {
  if [ "$HAS_JAVA_MAVEN" -ne 1 ] && [ "$HAS_JAVA_GRADLE" -ne 1 ]; then
    return 0
  fi
  log "Setting up Java environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install openjdk-17-jdk maven
      ;;
    apk)
      pkg_install openjdk17 maven
      ;;
    dnf|yum|microdnf)
      pkg_install java-17-openjdk-devel maven
      ;;
  esac
  pkg_clean
  pushd "$PROJECT_ROOT" >/dev/null || die "Project root not accessible"
  if [ "$HAS_JAVA_MAVEN" -eq 1 ] && [ -f "pom.xml" ]; then
    mvn -v >/dev/null 2>&1 || die "Maven installation failed"
    mvn -q -DskipTests dependency:resolve dependency:resolve-plugins || true
  fi
  if [ "$HAS_JAVA_GRADLE" -eq 1 ]; then
    if [ -x "./gradlew" ]; then
      chmod +x ./gradlew
      ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
      ./gradlew --no-daemon dependencies || true
    else
      # Install gradle if wrapper not present
      case "$PKG_MANAGER" in
        apt) pkg_install gradle ;;
        apk) pkg_install gradle ;;
        dnf|yum|microdnf) pkg_install gradle ;;
      esac
      pkg_clean
      gradle --version >/dev/null 2>&1 || true
      gradle --no-daemon build -x test || true
    fi
  fi
  popd >/dev/null || true
  log "Java environment ready."
}

install_php_stack() {
  [ "$HAS_PHP" -eq 1 ] || return 0
  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install php-cli php-zip php-curl php-xml php-mbstring php-json php-openssl php-tokenizer php-dom
      ;;
    apk)
      pkg_install php81 php81-cli php81-phar php81-openssl php81-zip php81-xml php81-mbstring php81-json php81-dom
      ;;
    dnf|yum|microdnf)
      pkg_install php-cli php-json php-zip php-xml php-mbstring php-openssl
      ;;
  esac
  # Install Composer
  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
  pushd "$PROJECT_ROOT" >/dev/null || die "Project root not accessible"
  if [ -f "composer.json" ]; then
    if [ -f "composer.lock" ]; then
      if [ "$APP_ENV" = "production" ]; then
        composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader
      else
        composer install --prefer-dist --no-interaction
      fi
    else
      composer update --no-interaction
    fi
  fi
  popd >/dev/null || true
  log "PHP environment ready."
}

install_rust_stack() {
  [ "$HAS_RUST" -eq 1 ] || return 0
  log "Setting up Rust environment..."
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal --default-toolchain stable
    rm -f /tmp/rustup.sh
    # shellcheck source=/dev/null
    . /root/.cargo/env
  fi
  pushd "$PROJECT_ROOT" >/dev/null || die "Project root not accessible"
  cargo fetch || true
  popd >/dev/null || true
  log "Rust toolchain ready."
}

install_dotnet_stack() {
  [ "$HAS_DOTNET" -eq 1 ] || return 0
  log "Setting up .NET SDK/runtime..."
  case "$PKG_MANAGER" in
    apt)
      # Install Microsoft package repository and dotnet SDK 8.0
      if ! command -v dotnet >/dev/null 2>&1; then
        pkg_update
        pkg_install wget gnupg
        wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || \
        wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
        if [ -f /tmp/packages-microsoft-prod.deb ]; then
          dpkg -i /tmp/packages-microsoft-prod.deb || true
          rm -f /tmp/packages-microsoft-prod.deb
          apt-get update -y
          apt-get install -y dotnet-sdk-8.0 || apt-get install -y dotnet-sdk-7.0 || true
        else
          warn "Could not configure Microsoft package repo. Skipping .NET installation."
        fi
        pkg_clean
      fi
      ;;
    apk|dnf|yum|microdnf)
      warn ".NET automated installation is not supported for this base image by this script. Please use a dotnet SDK base image."
      ;;
  esac
  if command -v dotnet >/dev/null 2>&1; then
    pushd "$PROJECT_ROOT" >/dev/null || die "Project root not accessible"
    dotnet restore || true
    popd >/dev/null || true
    log ".NET environment ready."
  fi
}

configure_permissions() {
  # By default, containers run as root. Adjust ownership if run with another UID/GID.
  local TARGET_UID="${TARGET_UID:-}"
  local TARGET_GID="${TARGET_GID:-}"
  if [ -n "$TARGET_UID" ] && [ -n "$TARGET_GID" ]; then
    log "Adjusting ownership of project directories to ${TARGET_UID}:${TARGET_GID}..."
    chown -R "${TARGET_UID}:${TARGET_GID}" "$PROJECT_ROOT" "$LOG_DIR" "$CACHE_DIR" "$STATE_DIR" || true
  else
    # Ensure write access for root
    chmod -R u+rwX "$PROJECT_ROOT" "$LOG_DIR" "$CACHE_DIR" "$STATE_DIR" || true
  fi
}

write_runtime_hints() {
  # Create a simple run helper if not present
  local run_helper="${PROJECT_ROOT}/bin/run-app"
  if [ ! -f "$run_helper" ]; then
    cat > "$run_helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Source environment
[ -f /etc/profile ] && . /etc/profile || true
[ -f /etc/profile.d/project_env.sh ] && . /etc/profile.d/project_env.sh || true

cd "${PROJECT_ROOT:-/app}"

# Heuristics to run app
if [ -f "Procfile" ]; then
  if command -v forego >/dev/null 2>&1; then
    exec forego start
  fi
fi

if [ -f "package.json" ] && command -v npm >/dev/null 2>&1; then
  if npm run | grep -q "start"; then
    exec npm run start
  fi
fi

if [ -f "manage.py" ] && [ -d ".venv" ]; then
  exec python manage.py runserver 0.0.0.0:${APP_PORT:-8080}
fi

if [ -f "app.py" ] && command -v python >/dev/null 2>&1; then
  exec python app.py
fi

if compgen -G "*.csproj" >/dev/null 2>&1 && command -v dotnet >/dev/null 2>&1; then
  proj=$(ls *.csproj | head -n1)
  exec dotnet run --project "$proj" --urls "http://0.0.0.0:${APP_PORT:-8080}"
fi

if [ -f "go.mod" ] && command -v go >/dev/null 2>&1; then
  if [ -f "main.go" ]; then
    exec go run .
  fi
fi

echo "No default run command detected. Override with CMD or use your own entrypoint."
exit 1
EOF
    chmod +x "$run_helper"
  fi
}

write_state() {
  echo "last_setup: $(date -Iseconds)" > "$STATE_FILE"
}

show_summary() {
  log "Setup summary:"
  echo "  Project root:     $PROJECT_ROOT"
  echo "  Environment:      $APP_ENV"
  echo "  Port:             $APP_PORT"
  echo "  Log directory:    $LOG_DIR"
  echo "  Cache directory:  $CACHE_DIR"
  echo "  Profile:          $ENV_FILE"
  echo "  Run helper:       ${PROJECT_ROOT}/bin/run-app"
  echo "  Detected stacks:  Python=$HAS_PYTHON Node=$HAS_NODE Ruby=$HAS_RUBY Go=$HAS_GO Java(Maven)=$HAS_JAVA_MAVEN Java(Gradle)=$HAS_JAVA_GRADLE PHP=$HAS_PHP Rust=$HAS_RUST .NET=$HAS_DOTNET"
}

main() {
  require_root
  detect_pkg_manager
  ensure_dirs
  install_base_packages
  write_env_profile
  setup_auto_activate

  detect_stack

  # Install per-stack
  install_python_stack
  install_node_stack
  install_ruby_stack
  install_go_stack
  install_java_stack
  install_php_stack
  install_rust_stack
  install_dotnet_stack

  configure_permissions
  write_runtime_hints
  write_state
  show_summary

  log "Environment setup completed successfully."
  log "To use the environment in interactive shells, ensure /etc/profile.d/project_env.sh is sourced (default for login shells)."
}

main "$@" || die "Setup failed"