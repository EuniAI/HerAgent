#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type (Python/Node.js/Ruby/Go/Java/.NET/PHP/Rust)
# - Installs system dependencies and language runtimes
# - Installs project dependencies
# - Configures environment variables and permissions
# - Idempotent and safe to run multiple times

set -Eeuo pipefail

# Globals and defaults
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
CREATE_APP_USER="${CREATE_APP_USER:-false}"    # set to "true" to create non-root user
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-0}"
DEBIAN_FRONTEND=noninteractive
UMASK_VAL="${UMASK_VAL:-0022}"                 # sane default
PROJECT_TYPE=""                                # will be detected
PKG_MANAGER=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""
PKG_CLEAN_CMD=""
OS_FAMILY=""

# Colors (fall back to no color if not TTY)
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; NC=""
fi

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

on_error() {
  local exit_code=$?
  err "Setup failed at line ${BASH_LINENO[0]} (exit code: $exit_code)"
  exit "$exit_code"
}
trap on_error ERR

umask "$UMASK_VAL"

# Utility: check command existence
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Detect OS and package manager
detect_pkg_manager() {
  if [ -f /etc/alpine-release ]; then
    OS_FAMILY="alpine"
    PKG_MANAGER="apk"
    PKG_UPDATE_CMD="apk update || true"
    PKG_INSTALL_CMD="apk add --no-cache"
    PKG_CLEAN_CMD="true"
  elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS_FAMILY="debian"
    PKG_MANAGER="apt-get"
    PKG_UPDATE_CMD="apt-get update -y -o Acquire::Retries=3"
    PKG_INSTALL_CMD="apt-get install -y --no-install-recommends"
    PKG_CLEAN_CMD="apt-get clean && rm -rf /var/lib/apt/lists/*"
  elif has_cmd dnf; then
    OS_FAMILY="fedora"
    PKG_MANAGER="dnf"
    PKG_UPDATE_CMD="dnf -y update || true"
    PKG_INSTALL_CMD="dnf -y install"
    PKG_CLEAN_CMD="dnf clean all"
  elif has_cmd yum; then
    OS_FAMILY="rhel"
    PKG_MANAGER="yum"
    PKG_UPDATE_CMD="yum -y update || true"
    PKG_INSTALL_CMD="yum -y install"
    PKG_CLEAN_CMD="yum clean all"
  elif has_cmd microdnf; then
    OS_FAMILY="rhel"
    PKG_MANAGER="microdnf"
    PKG_UPDATE_CMD="microdnf -y update || true"
    PKG_INSTALL_CMD="microdnf -y install"
    PKG_CLEAN_CMD="microdnf clean all"
  else
    die "Unsupported base image: no known package manager found"
  fi
  log "Detected OS family: $OS_FAMILY, package manager: $PKG_MANAGER"
}

pkg_update() { eval "$PKG_UPDATE_CMD"; }
pkg_install() { eval "$PKG_INSTALL_CMD $*"; }
pkg_clean() { eval "$PKG_CLEAN_CMD"; }

# Ensure base tools
install_base_tools() {
  log "Installing base system tools..."
  pkg_update

  case "$OS_FAMILY" in
    alpine)
      pkg_install bash ca-certificates curl wget git openssh-client tar xz coreutils unzip findutils openssl shadow || true
      update-ca-certificates || true
      ;;
    debian)
      pkg_install bash ca-certificates curl wget git openssh-client tar xz-utils coreutils unzip gnupg dirmngr openssl procps
      update-ca-certificates || true
      ;;
    fedora|rhel)
      pkg_install bash ca-certificates curl wget git openssh-clients tar xz coreutils unzip gnupg2 openssl procps
      update-ca-trust || true
      ;;
  esac

  # Build tools commonly required by many ecosystems
  case "$OS_FAMILY" in
    alpine)
      pkg_install build-base gcc g++ make pkgconfig
      ;;
    debian)
      pkg_install build-essential pkg-config
      ;;
    fedora|rhel)
      pkg_install gcc gcc-c++ make which pkgconfig
      ;;
  esac
  pkg_clean
}

# Create app user/group if requested
setup_user_and_dirs() {
  log "Setting up application directory and user..."
  mkdir -p "$APP_DIR"
  if [ "${CREATE_APP_USER}" = "true" ]; then
    if ! getent group "$APP_GID" >/dev/null 2>&1; then
      if has_cmd groupadd; then
        groupadd -g "$APP_GID" "$APP_GROUP" || true
      elif has_cmd addgroup; then
        addgroup -g "$APP_GID" -S "$APP_GROUP" || true
      fi
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      if has_cmd useradd; then
        useradd -m -d "$APP_DIR" -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" || true
      elif has_cmd adduser; then
        adduser -D -h "$APP_DIR" -u "$APP_UID" -G "$APP_GROUP" "$APP_USER" || true
      fi
    fi
    chown -R "${APP_UID}:${APP_GID}" "$APP_DIR" || true
  else
    # root is fine in containers; ensure permissions are sane
    chmod -R ug+rwX,o-rwx "$APP_DIR" || true
  fi
}

# Detect project type by files
detect_project_type() {
  cd "$APP_DIR"
  if [ -f package.json ]; then
    PROJECT_TYPE="node"
  elif [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f Pipfile ] || [ -f poetry.lock ]; then
    PROJECT_TYPE="python"
  elif ls "$APP_DIR"/*.csproj >/dev/null 2>&1 || ls "$APP_DIR"/*.sln >/dev/null 2>&1; then
    PROJECT_TYPE="dotnet"
  elif [ -f Gemfile ]; then
    PROJECT_TYPE="ruby"
  elif [ -f go.mod ]; then
    PROJECT_TYPE="go"
  elif [ -f pom.xml ]; then
    PROJECT_TYPE="java-maven"
  elif [ -f build.gradle ] || [ -f build.gradle.kts ] || [ -f gradlew ]; then
    PROJECT_TYPE="java-gradle"
  elif [ -f composer.json ]; then
    PROJECT_TYPE="php"
  elif [ -f Cargo.toml ]; then
    PROJECT_TYPE="rust"
  else
    PROJECT_TYPE="unknown"
  fi
  log "Detected project type: $PROJECT_TYPE"
}

# Language/runtime installers and project dependency installers

install_node_runtime() {
  log "Installing Node.js runtime..."
  case "$OS_FAMILY" in
    alpine)
      pkg_update
      pkg_install nodejs npm
      ;;
    debian)
      # Use distro packages for stability
      pkg_update
      pkg_install nodejs npm
      ;;
    fedora|rhel)
      pkg_update
      pkg_install nodejs npm
      ;;
  esac
  pkg_clean

  # Enable corepack if available
  if has_cmd corepack; then
    corepack enable || true
  fi
}

install_node_deps() {
  cd "$APP_DIR"
  # Determine package manager
  local pm="npm"
  if [ -f yarn.lock ]; then
    pm="yarn"
    if has_cmd corepack; then
      corepack prepare yarn@stable --activate || true
    elif ! has_cmd yarn; then
      npm install -g yarn
    fi
  elif [ -f pnpm-lock.yaml ] || grep -qi '"packageManager": *"pnpm' package.json 2>/dev/null; then
    pm="pnpm"
    if has_cmd corepack; then
      corepack prepare pnpm@latest --activate || true
    elif ! has_cmd pnpm; then
      npm install -g pnpm
    fi
  fi

  export NODE_ENV="${NODE_ENV:-$APP_ENV}"
  mkdir -p "$APP_DIR/node_modules/.cache" || true

  case "$pm" in
    yarn)
      log "Installing Node.js dependencies with yarn..."
      if [ -f yarn.lock ]; then
        yarn install --frozen-lockfile
      else
        yarn install
      fi
      ;;
    pnpm)
      log "Installing Node.js dependencies with pnpm..."
      pnpm install --frozen-lockfile || pnpm install
      ;;
    npm|*)
      log "Installing Node.js dependencies with npm..."
      if [ -f package-lock.json ]; then
        npm ci
      else
        npm install
      fi
      ;;
  esac
}

install_python_runtime() {
  log "Installing Python runtime and build deps..."
  case "$OS_FAMILY" in
    alpine)
      pkg_update
      pkg_install python3 py3-pip python3-dev gcc musl-dev libffi-dev openssl-dev
      ;;
    debian)
      pkg_update
      pkg_install python3 python3-pip python3-venv python3-dev build-essential libffi-dev libssl-dev
      ;;
    fedora|rhel)
      pkg_update
      pkg_install python3 python3-pip python3-devel gcc make libffi-devel openssl-devel
      ;;
  esac
  pkg_clean
}

setup_python_venv_and_install() {
  cd "$APP_DIR"
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR="${PIP_NO_CACHE_DIR:-1}"
  export PIP_DISABLE_PIP_VERSION_CHECK=1

  # Clean stale pip source checkouts and virtualenv to avoid VCS RemoteNotFoundError
  rm -rf "$APP_DIR/src" "$APP_DIR/.venv/src" 2>/dev/null || true
  rm -rf "$APP_DIR/.venv" 2>/dev/null || true
  mkdir -p /tmp/pip-src && printf 'export PIP_SRC=/tmp/pip-src\n' > /etc/profile.d/pip_src.sh && chmod 0644 /etc/profile.d/pip_src.sh
  export PIP_SRC=/tmp/pip-src

  local py="python3"
  has_cmd python3 || die "python3 not found after installation"
  if [ ! -d "$APP_DIR/.venv" ]; then
    log "Creating Python virtual environment..."
    "$py" -m venv "$APP_DIR/.venv"
  else
    log "Reusing existing Python virtual environment at .venv"
  fi
  # Use venv executables directly to avoid shell activation
  "$APP_DIR/.venv/bin/python" -m pip install --upgrade pip setuptools wheel

  if [ -f requirements.txt ]; then
    log "Installing Python dependencies from requirements.txt..."
    "$APP_DIR/.venv/bin/python" -m pip install -r requirements.txt
  elif [ -f pyproject.toml ]; then
    if grep -q "\[build-system\]" pyproject.toml 2>/dev/null; then
      log "Installing Python project from pyproject.toml..."
      "$APP_DIR/.venv/bin/python" -m pip install .
    else
      warn "pyproject.toml present but no build-system section detected; skipping install"
    fi
  elif [ -f Pipfile ]; then
    log "Installing Pipenv and syncing dependencies..."
    "$APP_DIR/.venv/bin/python" -m pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 "$APP_DIR/.venv/bin/pipenv" install --deploy --system || PIPENV_VENV_IN_PROJECT=1 "$APP_DIR/.venv/bin/pipenv" install --system
  elif [ -f poetry.lock ] || grep -qi '\[tool.poetry\]' pyproject.toml 2>/dev/null; then
    log "Installing Poetry and project dependencies..."
    "$APP_DIR/.venv/bin/python" -m pip install "poetry>=1.5"
    "$APP_DIR/.venv/bin/poetry" config virtualenvs.in-project true
    "$APP_DIR/.venv/bin/poetry" install --no-interaction --no-ansi
  else
    warn "No Python dependency file detected; skipping dependency installation"
  fi
}

setup_git_template_for_docs_requirements() {
  mkdir -p /usr/local/share/git-templates/hooks
  cat > /usr/local/share/git-templates/hooks/post-checkout <<"EOF"
#!/usr/bin/env bash
set -euo pipefail
wtree="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -d "$wtree/docs" ]; then
  if [ -f "$wtree/requirements-docs.txt" ] && [ ! -e "$wtree/docs/requirements-docs.txt" ]; then
    ln -sf ../requirements-docs.txt "$wtree/docs/requirements-docs.txt"
  elif [ -f "$wtree/docs/requirements.txt" ] && [ ! -e "$wtree/docs/requirements-docs.txt" ]; then
    ln -sf requirements.txt "$wtree/docs/requirements-docs.txt"
  fi
fi
EOF
  chmod +x /usr/local/share/git-templates/hooks/post-checkout
  git config --global init.templateDir /usr/local/share/git-templates
}

setup_git_clone_wrapper() {
  cat >/usr/local/bin/git <<'EOF'
#!/usr/bin/env bash
set -e
REAL_GIT="/usr/bin/git"
if [ ! -x "$REAL_GIT" ]; then REAL_GIT="$(command -v git)"; fi
if [ "$1" = "clone" ]; then
  dest="${@: -1}"
  "$REAL_GIT" "$@"
  if [ -d "$dest" ]; then
    if [ -f "$dest/docs/source/conf.py" ] && [ ! -e "$dest/docs/conf.py" ]; then
      ln -s source/conf.py "$dest/docs/conf.py" || true
    fi
    if [ -f "$dest/requirements-docs.txt" ] && [ ! -e "$dest/docs/requirements-docs.txt" ]; then
      ln -s ../requirements-docs.txt "$dest/docs/requirements-docs.txt" || true
    elif [ -f "$dest/docs/requirements.txt" ] && [ ! -e "$dest/docs/requirements-docs.txt" ]; then
      ln -s requirements.txt "$dest/docs/requirements-docs.txt" || true
    fi
  fi
  exit 0
else
  exec "$REAL_GIT" "$@"
fi
EOF
  chmod 0755 /usr/local/bin/git
}

setup_global_git_hooks_for_docs() {
  mkdir -p /usr/local/share/global-git-hooks && cat > /usr/local/share/global-git-hooks/post-checkout <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
wtree="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -d "$wtree/docs" ]; then
  if [ -f "$wtree/docs/source/conf.py" ] && [ ! -e "$wtree/docs/conf.py" ]; then
    ln -sf source/conf.py "$wtree/docs/conf.py" || true
  fi
  if [ -f "$wtree/requirements-docs.txt" ] && [ ! -e "$wtree/docs/requirements-docs.txt" ]; then
    ln -sf ../requirements-docs.txt "$wtree/docs/requirements-docs.txt" || true
  elif [ -f "$wtree/docs/requirements.txt" ] && [ ! -e "$wtree/docs/requirements-docs.txt" ]; then
    ln -sf requirements.txt "$wtree/docs/requirements-docs.txt" || true
  fi
fi
EOF
  chmod 0755 /usr/local/share/global-git-hooks/post-checkout && (git config --system core.hooksPath /usr/local/share/global-git-hooks || git config --global core.hooksPath /usr/local/share/global-git-hooks)
}

run_boto3_pipeline() {
  local venv_python="$APP_DIR/.venv/bin/python"
  local venv_pytest="$APP_DIR/.venv/bin/pytest"
  local sphinx_build="$APP_DIR/.venv/bin/sphinx-build"

  if [ ! -x "$venv_python" ]; then
    die "Virtualenv Python not found at $venv_python"
  fi

  # Ensure git templates are configured so post-checkout hook creates docs requirements symlink
  setup_git_template_for_docs_requirements
  setup_git_clone_wrapper
  setup_global_git_hooks_for_docs

  rm -rf "$APP_DIR/boto3"
  git clone https://github.com/boto/boto3.git "$APP_DIR/boto3"

  "$venv_python" -m pip install --upgrade pip setuptools wheel
  "$venv_python" -m pip install -r "$APP_DIR/boto3/requirements.txt"
  "$venv_python" -m pip install -e "$APP_DIR/boto3"
  "$venv_python" -m pip install -r "$APP_DIR/boto3/docs/requirements-docs.txt"
  # Ensure Sphinx conf.py symlink exists if docs use source/ layout
  if [ -d "$APP_DIR/boto3/docs" ] && [ -f "$APP_DIR/boto3/docs/source/conf.py" ] && [ ! -e "$APP_DIR/boto3/docs/conf.py" ]; then
    ln -s source/conf.py "$APP_DIR/boto3/docs/conf.py"
  fi

  # Ensure Python sees in-tree boto3 when building docs
  "$venv_python" - <<'PY'
import os, site, sys
# Locate site-packages for this venv and install a sitecustomize that adds /app/boto3 to sys.path
paths = []
try:
    paths.extend(site.getsitepackages())
except Exception:
    pass
try:
    usp = site.getusersitepackages()
    if usp:
        paths.append(usp)
except Exception:
    pass
paths = [p for p in paths if isinstance(p, str) and p]
if not paths:
    paths = [os.path.join(sys.prefix, 'lib', f'python{sys.version_info[0]}.{sys.version_info[1]}', 'site-packages')]
sp = paths[0]
os.makedirs(sp, exist_ok=True)
fn = os.path.join(sp, 'sitecustomize.py')
content = """
import os, sys
p = os.environ.get('BOTO3_SRC_DIR', '/app/boto3')
if os.path.isdir(p) and os.path.isfile(os.path.join(p, 'boto3', '__init__.py')):
    if p not in sys.path:
        sys.path.insert(0, p)
"""
with open(fn, 'w') as f:
    f.write(content)
print('Wrote', fn)
PY
  install -d /etc/profile.d && printf '%s\n' 'export BOTO3_SRC_DIR="'"$APP_DIR"'/boto3"' > /etc/profile.d/boto3_src.sh && chmod 0644 /etc/profile.d/boto3_src.sh
  if [ -x "$APP_DIR/.venv/bin/sphinx-build" ] && [ ! -x "$APP_DIR/.venv/bin/sphinx-build.real" ]; then mv "$APP_DIR/.venv/bin/sphinx-build" "$APP_DIR/.venv/bin/sphinx-build.real"; fi
  # Create a sphinx-build wrapper that injects PYTHONPATH and enables parallel builds
  cat > "$APP_DIR/.venv/bin/sphinx-build" <<'EOSB'
#!/usr/bin/env bash
set -euo pipefail
# Compute parallelism; fallback to 2 if unknown
if command -v nproc >/dev/null 2>&1; then J=$(nproc); elif command -v getconf >/dev/null 2>&1; then J=$(getconf _NPROCESSORS_ONLN || echo 2); else J=2; fi
export PYTHONPATH="/app/boto3:${PYTHONPATH:-}"
exec "${BASH_SOURCE%/*}/sphinx-build.real" -j "${J}" "$@"
EOSB
  chmod 0755 "$APP_DIR/.venv/bin/sphinx-build"
  "$sphinx_build" -b html "$APP_DIR/boto3/docs" "$APP_DIR/boto3/docs/_build/html"

  "$venv_python" -m pip install pytest
  "$venv_pytest" "$APP_DIR/boto3/tests/unit"
  "$venv_pytest" "$APP_DIR/boto3/tests/integration"
  "$venv_pytest" -m integration "$APP_DIR/boto3/tests"
}

install_ruby_runtime_and_deps() {
  log "Installing Ruby runtime and Bundler..."
  case "$OS_FAMILY" in
    alpine)
      pkg_update
      pkg_install ruby ruby-dev build-base
      ;;
    debian)
      pkg_update
      pkg_install ruby-full build-essential
      ;;
    fedora|rhel)
      pkg_update
      pkg_install ruby ruby-devel gcc make redhat-rpm-config
      ;;
  esac
  pkg_clean

  if ! has_cmd bundle; then
    gem install bundler --no-document || true
  fi

  cd "$APP_DIR"
  if [ -f Gemfile ]; then
    log "Installing Ruby gems with Bundler..."
    bundle config set path 'vendor/bundle'
    bundle install --jobs "$(nproc || echo 2)"
  fi
}

install_go_runtime_and_deps() {
  log "Installing Go toolchain..."
  case "$OS_FAMILY" in
    alpine) pkg_update; pkg_install go ;;
    debian) pkg_update; pkg_install golang-go ;;
    fedora|rhel) pkg_update; pkg_install golang ;;
  esac
  pkg_clean
  cd "$APP_DIR"
  if [ -f go.mod ]; then
    log "Downloading Go modules..."
    go mod download
  fi
}

install_java_runtime_and_deps() {
  log "Installing Java JDK..."
  case "$OS_FAMILY" in
    alpine) pkg_update; pkg_install openjdk17-jdk ;;
    debian) pkg_update; pkg_install openjdk-17-jdk ;;
    fedora|rhel) pkg_update; pkg_install java-17-openjdk-devel ;;
  esac
  pkg_clean
}

install_maven_and_restore() {
  case "$OS_FAMILY" in
    alpine|debian|fedora|rhel)
      pkg_update
      pkg_install maven
      pkg_clean
      ;;
  esac
  cd "$APP_DIR"
  if [ -f pom.xml ]; then
    log "Pre-fetching Maven dependencies..."
    mvn -B -ntp -DskipTests dependency:go-offline || true
  fi
}

install_gradle_and_restore() {
  cd "$APP_DIR"
  if [ -x ./gradlew ]; then
    log "Using Gradle Wrapper to download dependencies..."
    ./gradlew --no-daemon -x test build || ./gradlew --no-daemon tasks || true
  else
    case "$OS_FAMILY" in
      alpine|debian|fedora|rhel)
        pkg_update
        pkg_install gradle
        pkg_clean
        ;;
    esac
    if [ -f build.gradle ] || [ -f build.gradle.kts ]; then
      log "Pre-fetching Gradle dependencies..."
      gradle --no-daemon -x test build || gradle --no-daemon tasks || true
    fi
  fi
}

install_dotnet_and_restore() {
  log "Installing .NET SDK via official installer..."
  cd /tmp
  curl -sSL https://dot.net/v1/dotnet-install.sh -o dotnet-install.sh
  chmod +x dotnet-install.sh
  local DOTNET_ROOT_LOCAL="/usr/share/dotnet"
  mkdir -p "$DOTNET_ROOT_LOCAL"
  ./dotnet-install.sh --install-dir "$DOTNET_ROOT_LOCAL" --channel STS --quality ga || ./dotnet-install.sh --install-dir "$DOTNET_ROOT_LOCAL" --channel LTS --quality ga
  export DOTNET_ROOT="$DOTNET_ROOT_LOCAL"
  export PATH="$DOTNET_ROOT:$PATH"
  cd "$APP_DIR"
  if ls *.sln >/dev/null 2>&1; then
    log "Restoring .NET solution dependencies..."
    dotnet restore
  elif ls *.csproj >/dev/null 2>&1; then
    log "Restoring .NET project dependencies..."
    dotnet restore "$(ls *.csproj | head -n1)"
  fi
}

install_php_and_composer() {
  log "Installing PHP and Composer..."
  case "$OS_FAMILY" in
    alpine)
      pkg_update
      pkg_install php php-cli php-phar php-openssl php-json php-mbstring php-zip php-xml curl git unzip
      ;;
    debian)
      pkg_update
      pkg_install php-cli php-common php-json php-mbstring php-zip php-xml curl git unzip
      ;;
    fedora|rhel)
      pkg_update
      pkg_install php-cli php-json php-mbstring php-zip php-xml curl git unzip
      ;;
  esac
  pkg_clean

  if ! has_cmd composer; then
    cd /tmp
    curl -sS https://getcomposer.org/installer -o composer-setup.php
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi

  cd "$APP_DIR"
  if [ -f composer.json ]; then
    log "Installing PHP dependencies with Composer..."
    composer install --no-interaction --prefer-dist --optimize-autoloader
  fi
}

install_rust_and_deps() {
  log "Installing Rust via rustup..."
  export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}"
  if [ ! -x "$CARGO_HOME/bin/cargo" ]; then
    curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable
  fi
  export PATH="$CARGO_HOME/bin:$PATH"
  cd "$APP_DIR"
  if [ -f Cargo.toml ]; then
    log "Fetching Rust crate dependencies..."
    cargo fetch
  fi
}

# Configure environment persistence for shells in container
persist_environment() {
  log "Persisting environment variables..."
  local profile_file="/etc/profile.d/project_env.sh"
  {
    echo "export APP_DIR=\"$APP_DIR\""
    echo "export APP_ENV=\"${APP_ENV}\""
    echo "export PROJECT_TYPE=\"${PROJECT_TYPE}\""
    echo "export PATH=\"$APP_DIR/.venv/bin:$APP_DIR/node_modules/.bin:\$PATH\""
    if [ -n "${DOTNET_ROOT:-}" ]; then
      echo "export DOTNET_ROOT=\"${DOTNET_ROOT}\""
      echo "export PATH=\"${DOTNET_ROOT}:\$PATH\""
    fi
    if [ -n "${CARGO_HOME:-}" ]; then
      echo "export CARGO_HOME=\"${CARGO_HOME}\""
      echo "export RUSTUP_HOME=\"${RUSTUP_HOME:-/usr/local/rustup}\""
      echo "export PATH=\"${CARGO_HOME}/bin:\$PATH\""
    fi
    if [ "$APP_PORT" -gt 0 ] 2>/dev/null; then
      echo "export APP_PORT=\"$APP_PORT\""
    fi
    echo "export LANG=C.UTF-8"
    echo "export LC_ALL=C.UTF-8"
  } > "$profile_file"
  chmod 0644 "$profile_file"
}

# Infer a default application port if not set
infer_app_port() {
  if [ "${APP_PORT}" -gt 0 ] 2>/dev/null; then
    return
  fi
  case "$PROJECT_TYPE" in
    node) APP_PORT=3000 ;;
    python)
      # common defaults
      if [ -f manage.py ]; then APP_PORT=8000; else APP_PORT=5000; fi
      ;;
    java-maven|java-gradle) APP_PORT=8080 ;;
    php) APP_PORT=8080 ;;
    go) APP_PORT=8080 ;;
    ruby) APP_PORT=3000 ;;
    dotnet) APP_PORT=8080 ;;
    rust) APP_PORT=8080 ;;
    *) APP_PORT=0 ;;
  esac
  export APP_PORT
}

# Main orchestrator
main() {
  log "Starting universal project environment setup..."
  detect_pkg_manager
  install_base_tools
  setup_user_and_dirs

  # Ensure APP_DIR exists and cd into it
  mkdir -p "$APP_DIR"
  cd "$APP_DIR"

  detect_project_type
  infer_app_port

  case "$PROJECT_TYPE" in
    node)
      install_node_runtime
      install_node_deps
      ;;
    python)
      install_python_runtime
      setup_python_venv_and_install
      run_boto3_pipeline
      ;;
    ruby)
      install_ruby_runtime_and_deps
      ;;
    go)
      install_go_runtime_and_deps
      ;;
    java-maven)
      install_java_runtime_and_deps
      install_maven_and_restore
      ;;
    java-gradle)
      install_java_runtime_and_deps
      install_gradle_and_restore
      ;;
    dotnet)
      install_dotnet_and_restore
      ;;
    php)
      install_php_and_composer
      ;;
    rust)
      install_rust_and_deps
      ;;
    *)
      warn "Unknown project type. Installed base tools; no language-specific setup performed."
      ;;
  esac

  persist_environment

  # Final permissions (non-fatal if cannot change)
  if [ "${CREATE_APP_USER}" = "true" ]; then
    chown -R "${APP_UID}:${APP_GID}" "$APP_DIR" || true
  fi

  log "Environment setup completed successfully."
  if [ "$APP_PORT" -gt 0 ] 2>/dev/null; then
    log "Detected/default application port: ${APP_PORT}"
  fi

  # Helpful hint to run as non-root if created
  if [ "${CREATE_APP_USER}" = "true" ]; then
    log "You can run the application as user '${APP_USER}' inside the container."
  fi

  # Print concise next steps based on project type
  case "$PROJECT_TYPE" in
    node) log "Next: cd \"$APP_DIR\" && npm run start (or yarn start/pnpm start)";;
    python) log "Next: run via venv executables without sourcing, e.g., \"$APP_DIR/.venv/bin/python\" -m your_app or \"$APP_DIR/.venv/bin/gunicorn\"";;
    ruby) log "Next: cd \"$APP_DIR\" && bundle exec your_app_server";;
    go) log "Next: cd \"$APP_DIR\" && go build ./...";;
    java-maven) log "Next: cd \"$APP_DIR\" && mvn -B -DskipTests package";;
    java-gradle) log "Next: cd \"$APP_DIR\" && ./gradlew build (or gradle build)";;
    dotnet) log "Next: cd \"$APP_DIR\" && dotnet build && dotnet run";;
    php) log "Next: cd \"$APP_DIR\" && php -S 0.0.0.0:${APP_PORT:-8080} -t public (or use your framework's server)";;
    rust) log "Next: cd \"$APP_DIR\" && cargo build --release";;
    *) log "Next: cd \"$APP_DIR\" and run your project-specific commands.";;
  esac
}

main "$@"