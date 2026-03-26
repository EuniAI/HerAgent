#!/bin/bash
# Universal project environment setup script for Docker containers
# Detects project type and installs required runtimes and dependencies.
# Safe to run multiple times (idempotent) and designed for root execution inside Docker.

set -Eeuo pipefail
IFS=$'\n\t'

# =========================
# Global configuration
# =========================
SCRIPT_NAME="$(basename "$0")"
APP_DIR="${APP_DIR:-/app}"          # Default project directory
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
LOG_DIR="${LOG_DIR:-$APP_DIR/logs}"
TMP_DIR="${TMP_DIR:-$APP_DIR/tmp}"
DEBIAN_FRONTEND=noninteractive
TZ="${TZ:-UTC}"                     # Default timezone
APP_ENV="${APP_ENV:-production}"    # Generic environment variable
COLOR=${COLOR:-1}                   # Set to 0 to disable colors

# Colors for output
if [ "$COLOR" -eq 1 ]; then
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

# =========================
# Logging and error handling
# =========================
log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }

err_trap() {
  local exit_code=$?
  error "Setup failed in function '${FUNCNAME[1]}' at line ${BASH_LINENO[0]} with exit code ${exit_code}"
  exit "$exit_code"
}
trap err_trap ERR

# =========================
# Utility helpers
# =========================
ensure_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    log "Created directory: $dir"
  fi
}

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
    error "Unsupported base image: no known package manager found (apt, apk, dnf, yum, zypper)."
    exit 1
  fi
  log "Detected package manager: $PKG_MANAGER"
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      apt-get update -y -qq
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf -y -q makecache
      ;;
    yum)
      yum -y -q makecache
      ;;
    zypper)
      zypper --non-interactive refresh
      ;;
  esac
}

pkg_install() {
  # Install packages passed as arguments if supported by package manager
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y -qq --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf)
      dnf install -y -q "$@"
      ;;
    yum)
      yum install -y -q "$@"
      ;;
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MANAGER" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      rm -rf /var/cache/apk/*
      ;;
    dnf|yum)
      rm -rf /var/cache/dnf/* /var/cache/yum/*
      ;;
    zypper)
      zypper clean -a || true
      ;;
  esac
}

# =========================
# Base system setup
# =========================
install_base_packages() {
  log "Installing base system packages..."
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl wget gnupg git tzdata pkg-config build-essential unzip python3-pip iptables
      update-ca-certificates || true
      # Install Node.js 22.x via NodeSource and enable Yarn through Corepack
      if ! command -v node >/dev/null 2>&1 || ! node -v | grep -qE '^v22\.'; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
      fi
      if command -v corepack >/dev/null 2>&1; then
        corepack enable || true
        corepack prepare yarn@stable --activate || true
      fi
      ;;
    apk)
      pkg_install ca-certificates curl wget git tzdata pkgconfig build-base unzip
      update-ca-certificates || true
      ;;
    dnf)
      pkg_install ca-certificates curl wget git tzdata gcc gcc-c++ make pkgconfig unzip
      update-ca-trust || true
      ;;
    yum)
      pkg_install ca-certificates curl wget git tzdata gcc gcc-c++ make pkgconfig unzip
      update-ca-trust || true
      ;;
    zypper)
      pkg_install ca-certificates curl wget git timezone pkg-config gcc gcc-c++ make unzip
      update-ca-certificates || true
      ;;
  esac

  # Set timezone (non-interactive)
  if [ -f /usr/share/zoneinfo/$TZ ]; then
    ln -sf /usr/share/zoneinfo/$TZ /etc/localtime
    echo "$TZ" >/etc/timezone || true
  fi

  pkg_clean
  log "Base system packages installed."
}

# =========================
# Environment file loader
# =========================
load_env_file() {
  if [ -f "$ENV_FILE" ]; then
    log "Loading environment variables from $ENV_FILE"
    while IFS= read -r line; do
      # Ignore comments and empty lines
      if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      # Only accept simple KEY=VALUE lines without spaces around '='
      if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        # shellcheck disable=SC2163
        export "$line"
      fi
    done < "$ENV_FILE"
  else
    warn "No .env file found at $ENV_FILE. Using defaults."
  fi
}

# =========================
# Project type detection
# =========================
PROJECT_TYPE="unknown"

detect_project_type() {
  local dir="$1"
  if [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ]; then
    PROJECT_TYPE="python"
  elif [ -f "$dir/package.json" ]; then
    PROJECT_TYPE="node"
  elif [ -f "$dir/Gemfile" ]; then
    PROJECT_TYPE="ruby"
  elif [ -f "$dir/pom.xml" ]; then
    PROJECT_TYPE="java-maven"
  elif [ -f "$dir/build.gradle" ] || [ -f "$dir/gradle.properties" ]; then
    PROJECT_TYPE="java-gradle"
  elif [ -f "$dir/go.mod" ]; then
    PROJECT_TYPE="go"
  elif [ -f "$dir/composer.json" ]; then
    PROJECT_TYPE="php"
  elif [ -f "$dir/Cargo.toml" ]; then
    PROJECT_TYPE="rust"
  elif compgen -G "$dir/*.csproj" >/dev/null || [ -f "$dir/global.json" ]; then
    PROJECT_TYPE="dotnet"
  fi
  log "Detected project type: $PROJECT_TYPE"
}

# =========================
# Language-specific setup
# =========================

setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev gcc python3-poetry
      ;;
    apk)
      pkg_update
      pkg_install python3 py3-pip python3-dev libffi-dev openssl-dev musl-dev gcc
      ;;
    dnf|yum)
      pkg_update
      pkg_install python3 python3-pip python3-devel openssl-devel libffi-devel gcc
      ;;
    zypper)
      pkg_update
      pkg_install python3 python3-pip python3-devel libffi-devel libopenssl-devel gcc
      ;;
  esac
  pkg_clean

  ensure_dir "$APP_DIR"
  cd "$APP_DIR"
  # Export requirements from Poetry if pyproject.toml exists and requirements.txt is missing
  if [ -f "pyproject.toml" ] && [ ! -f "requirements.txt" ]; then
    if command -v poetry >/dev/null 2>&1; then
      poetry export -f requirements.txt --output requirements.txt --without-hashes || warn "Poetry export failed; continuing."
    else
      warn "Poetry not found; skipping requirements export."
    fi
  fi

  # Create venv if not exists
  if [ ! -d ".venv" ]; then
    python3 -m venv .venv
    log "Created Python virtual environment at $APP_DIR/.venv"
  else
    log "Virtual environment already exists. Skipping creation."
  fi

  # Activate venv
  # shellcheck disable=SC1091
  source ".venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [ -f "requirements.txt" ]; then
    pip install --no-cache-dir -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    # Try installing via PEP 517/518
    pip install --no-cache-dir .
  fi

  # Prepare runtime environment
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1

  # Persist environment settings for later shells
  cat >/etc/profile.d/10-python-env.sh <<'EOF'
export PYTHONUNBUFFERED=1
export PIP_NO_CACHE_DIR=1
# Auto-activate venv if present and shell is interactive
if [ -d "/app/.venv" ] && [ -n "$PS1" ]; then
  # shellcheck disable=SC1091
  . /app/.venv/bin/activate
fi
EOF

  log "Python environment setup complete."
}

setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      # Install Node.js 22.x via NodeSource and enable Yarn via Corepack
      if ! command -v node >/dev/null 2>&1 || ! node -v | grep -qE '^v22\.'; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
      fi
      if command -v corepack >/dev/null 2>&1; then
        corepack enable || true
        corepack prepare yarn@stable --activate || true
      fi
      ;;
    apk)
      pkg_update
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_update
      pkg_install nodejs npm || warn "Node.js installation may require EPEL or module enablement."
      ;;
    zypper)
      pkg_update
      pkg_install nodejs npm
      ;;
  esac
  pkg_clean

  ensure_dir "$APP_DIR"
  cd "$APP_DIR"

  # Install packages using lockfile if present
  if [ -f "package-lock.json" ]; then
    npm ci --omit=dev
  else
    npm install --omit=dev
  fi

  # Persist runtime environment
  cat >/etc/profile.d/10-node-env.sh <<'EOF'
export NODE_ENV=production
export NPM_CONFIG_AUDIT=false
export NPM_CONFIG_FUND=false
EOF

  log "Node.js environment setup complete."
}

setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_update
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pkg_update
      pkg_install ruby ruby-devel gcc make
      ;;
    zypper)
      pkg_update
      pkg_install ruby ruby-devel gcc make
      ;;
  esac
  pkg_clean

  ensure_dir "$APP_DIR"
  cd "$APP_DIR"
  gem install bundler --no-document || true

  # Idempotent bundle install
  if [ -f "Gemfile" ]; then
    mkdir -p vendor/bundle
    bundle config set --local path 'vendor/bundle'
    bundle config set --local without 'development test'
    bundle install --jobs "$(nproc)" --retry 3
  fi

  cat >/etc/profile.d/10-ruby-env.sh <<'EOF'
export RACK_ENV=production
export RAILS_ENV=production
EOF

  log "Ruby environment setup complete."
}

setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install openjdk-17-jdk maven
      ;;
    apk)
      pkg_update
      pkg_install openjdk17 maven
      ;;
    dnf|yum)
      pkg_update
      pkg_install java-17-openjdk-devel maven
      ;;
    zypper)
      pkg_update
      pkg_install java-17-openjdk-devel maven
      ;;
  esac
  pkg_clean

  ensure_dir "$APP_DIR"
  cd "$APP_DIR"

  if [ -f "pom.xml" ]; then
    mvn -B -DskipTests package || warn "Maven build failed or tests present; ensure project compiles."
  fi

  cat >/etc/profile.d/10-java-env.sh <<'EOF'
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac)))) || true
export MAVEN_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
EOF

  log "Java (Maven) environment setup complete."
}

setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install openjdk-17-jdk gradle
      ;;
    apk)
      pkg_update
      pkg_install openjdk17 gradle
      ;;
    dnf|yum)
      pkg_update
      pkg_install java-17-openjdk-devel gradle
      ;;
    zypper)
      pkg_update
      pkg_install java-17-openjdk-devel gradle
      ;;
  esac
  pkg_clean

  ensure_dir "$APP_DIR"
  cd "$APP_DIR"

  if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
    gradle build -x test || warn "Gradle build failed or tests present; ensure project compiles."
  fi

  cat >/etc/profile.d/10-java-env.sh <<'EOF'
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac)))) || true
export GRADLE_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
EOF

  log "Java (Gradle) environment setup complete."
}

setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install golang
      ;;
    apk)
      pkg_update
      pkg_install go
      ;;
    dnf|yum)
      pkg_update
      pkg_install golang
      ;;
    zypper)
      pkg_update
      pkg_install go
      ;;
  esac
  pkg_clean

  ensure_dir "$APP_DIR"
  cd "$APP_DIR"

  export GOPATH=${GOPATH:-/go}
  export GOCACHE=${GOCACHE:-/tmp/go-cache}
  ensure_dir "$GOPATH"
  ensure_dir "$GOCACHE"

  if [ -f "go.mod" ]; then
    go mod download
    # Optional build (skip if it's a library)
    if [ -f "main.go" ]; then
      go build -o "$APP_DIR/bin/app" ./...
    fi
  fi

  cat >/etc/profile.d/10-go-env.sh <<'EOF'
export GOPATH=${GOPATH:-/go}
export PATH="$PATH:$GOPATH/bin"
EOF

  log "Go environment setup complete."
}

setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install php-cli composer unzip
      ;;
    apk)
      pkg_update
      # Alpine PHP package names may vary by version; try generic ones
      pkg_install php php-cli php-phar php-openssl php-json php-mbstring unzip || true
      pkg_install composer || true
      ;;
    dnf|yum)
      pkg_update
      pkg_install php-cli unzip
      # Composer may not be available; install via installer if missing
      ;;
    zypper)
      pkg_update
      pkg_install php-cli composer unzip
      ;;
  esac
  pkg_clean

  ensure_dir "$APP_DIR"
  cd "$APP_DIR"

  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if [ -f "composer.json" ]; then
    composer install --no-dev --prefer-dist --no-interaction --no-progress
  fi

  cat >/etc/profile.d/10-php-env.sh <<'EOF'
export COMPOSER_NO_INTERACTION=1
export COMPOSER_ALLOW_SUPERUSER=1
EOF

  log "PHP environment setup complete."
}

setup_rust() {
  log "Setting up Rust environment..."
  # Prefer system packages if available
  case "$PKG_MANAGER" in
    apk)
      pkg_update
      pkg_install rust cargo
      ;;
    dnf|yum|zypper|apt)
      # Use rustup for consistent versions
      ;;
  esac

  if ! command -v cargo >/dev/null 2>&1; then
    export RUSTUP_HOME=${RUSTUP_HOME:-/opt/rustup}
    export CARGO_HOME=${CARGO_HOME:-/opt/cargo}
    ensure_dir "$RUSTUP_HOME"
    ensure_dir "$CARGO_HOME"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    # Persist PATH
    echo 'export CARGO_HOME=/opt/cargo' >/etc/profile.d/10-rust-env.sh
    echo 'export RUSTUP_HOME=/opt/rustup' >>/etc/profile.d/10-rust-env.sh
    echo 'export PATH="$PATH:/opt/cargo/bin"' >>/etc/profile.d/10-rust-env.sh
    # shellcheck disable=SC1091
    . /etc/profile.d/10-rust-env.sh
  else
    cat >/etc/profile.d/10-rust-env.sh <<'EOF'
export PATH="$PATH:$(dirname "$(which cargo)")"
EOF
  fi

  ensure_dir "$APP_DIR"
  cd "$APP_DIR"

  if [ -f "Cargo.toml" ]; then
    cargo fetch
    cargo build --release || warn "Rust build failed; ensure dependencies and toolchain are correct."
  fi

  log "Rust environment setup complete."
}

setup_dotnet() {
  log "Setting up .NET environment..."
  warn ".NET SDK installation requires vendor repositories (Microsoft). Skipping automatic SDK install."
  warn "Use an official .NET SDK base image or preconfigure package sources."
  ensure_dir "$APP_DIR"
  cd "$APP_DIR"
  log ".NET environment stub complete."
}

# =========================
# Generic project structure
# =========================
setup_project_structure() {
  ensure_dir "$APP_DIR"
  ensure_dir "$LOG_DIR"
  ensure_dir "$TMP_DIR"

  # Set permissions: root by default inside Docker; preserve existing if non-root
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"
  chown -R "$uid":"$gid" "$APP_DIR" || true

  # Create a default runtime env file
  cat >/etc/profile.d/00-project-env.sh <<EOF
export APP_DIR="$APP_DIR"
export APP_ENV="$APP_ENV"
export TZ="$TZ"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
EOF

  log "Project directories and base environment configured."
}

# =========================
# Inline env assignment wrapper for non-shell exec environments
# =========================
setup_inline_env_wrapper() {
  local base_dir="$APP_DIR"
  local dir_path="$base_dir/WORKSPACE_MOUNT_PATH="
  local wrapper_path="$base_dir/WORKSPACE_MOUNT_PATH=/app"
  mkdir -p "$dir_path"
  cat >"$wrapper_path" <<'EOF'
#!/bin/sh
[ -z "$WORKSPACE_MOUNT_PATH" ] && export WORKSPACE_MOUNT_PATH="$(pwd)"
exec "$@"
EOF
  chmod +x "$wrapper_path"
}

# Project-specific repairs
setup_docker_runtime() {
  # Install Docker if not present
  if ! command -v docker >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y ca-certificates curl iptables || true
    fi
    curl -fsSL https://get.docker.com | sh || true
  fi
  # Start dockerd if not running
  if ! pgrep dockerd >/dev/null 2>&1; then
    nohup dockerd --storage-driver=vfs >/var/log/dockerd.log 2>&1 &
    sleep 2
  fi
  # Wait for docker daemon to be ready
  i=0
  until docker info >/dev/null 2>&1 || [ $i -ge 30 ]; do
    i=$((i+1))
    sleep 1
  done
  # Install Docker Buildx plugin if missing
  if ! docker buildx version >/dev/null 2>&1; then
    mkdir -p /usr/local/lib/docker/cli-plugins
    arch="$(uname -m)"
    case "$arch" in
      x86_64) a=amd64 ;;
      aarch64) a=arm64 ;;
      *) a=amd64 ;;
    esac
    ver="v0.13.1"
    curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-buildx "https://github.com/docker/buildx/releases/download/${ver}/buildx-${ver}.linux-${a}"
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
  fi
  # Ensure a buildx builder exists and is set to use
  docker buildx inspect >/dev/null 2>&1 || docker buildx create --use >/dev/null 2>&1 || true
}
install_global_uvicorn() {
  local sys_python="/usr/bin/python3"
  if [ ! -x "$sys_python" ]; then
    sys_python="$(command -v python3 || true)"
  fi
  if [ -n "$sys_python" ]; then
    # Ensure system pip is available (APT-based images)
    local PIP_BREAK=""
    if [ "${PKG_MANAGER:-}" = "apt" ]; then
      apt-get update && apt-get install -y python3-pip ca-certificates curl gnupg
      PIP_BREAK="--break-system-packages"
    fi
    # Install uvicorn[standard] quietly as per repair commands
    "$sys_python" -m pip install --no-input -q "uvicorn[standard]" || true
    # Upgrade pip and install uvicorn[standard] and fastapi globally to back 'python3 -m uvicorn'
    "$sys_python" -m pip install -U pip $PIP_BREAK || true
    "$sys_python" -m pip install -U --no-cache-dir 'uvicorn[standard]' fastapi $PIP_BREAK || warn "Failed to install uvicorn/fastapi globally; continuing."
    # Provide a convenience wrapper (not required when using 'python3 -m uvicorn', but harmless)
    printf '#!/usr/bin/env bash\nexec python3 -m uvicorn "$@"\n' >/usr/local/bin/uvicorn
    chmod +x /usr/local/bin/uvicorn || true
  fi
}
ensure_uvicorn_fastapi() {
  python -m pip install --no-cache-dir --upgrade uvicorn[standard] fastapi || true
}
ensure_global_yarn() {
  # Ensure npm exists; if missing and apt is available, install nodejs and npm
  if ! command -v npm >/dev/null 2>&1; then
    if [ "${PKG_MANAGER:-}" = "apt" ]; then
      apt-get update && apt-get install -y nodejs npm || true
    fi
  fi
  # Ensure yarn is available globally
  if ! command -v yarn >/dev/null 2>&1; then
    if command -v npm >/dev/null 2>&1; then
      npm install -g yarn || true
    fi
  fi
}
ensure_sitecustomize() {
  python - <<'PY'
import os, site, sys, pathlib
content = (
    "import os\n"
    "os.environ.setdefault('SANDBOX_RUNTIME_CONTAINER_IMAGE', 'docker.all-hands.dev/all-hands-ai/runtime:0.15-nikolaik')\n"
    "os.environ.setdefault('GITHUB_USERNAME', 'local')\n"
)
paths = []
try:
    paths.extend(site.getsitepackages())
except Exception:
    pass
try:
    paths.append(site.getusersitepackages())
except Exception:
    pass
written = False
for d in [p for p in paths if p]:
    p = pathlib.Path(d) / 'sitecustomize.py'
    try:
        old = p.read_text() if p.exists() else ''
        if content not in old:
            p.write_text(old + ("\n" if old and not old.endswith("\n") else "") + content)
            print(f"Wrote {p}")
            written = True
    except Exception as e:
        print(f"Failed writing {p}: {e}", file=sys.stderr)
if not written:
    # Fallback: write to current working directory's sitecustomize.py (picked up if in sys.path)
    p = pathlib.Path.cwd() / 'sitecustomize.py'
    old = p.read_text() if p.exists() else ''
    if content not in old:
        p.write_text(old + ("\n" if old and not old.endswith("\n") else "") + content)
        print(f"Wrote {p}")
PY
}
ensure_project_sitecustomize() {
  python3 - <<'PY'
import os, pathlib
p = pathlib.Path(os.environ.get('APP_DIR', '/app')) / 'sitecustomize.py'
content = (
    'import os\n'
    'os.environ.setdefault("SANDBOX_RUNTIME_CONTAINER_IMAGE","docker.all-hands.dev/all-hands-ai/runtime:0.15-nikolaik")\n'
    'os.environ.setdefault("GITHUB_USERNAME","local")\n'
)
p.write_text(content)
print(f"Wrote {p}")
PY
}

ensure_watchfiles_polling() {
  # Restore uvicorn console script by force-reinstalling and configure watchfiles via sitecustomize
  for py in "/opt/venv/bin/python" "/opt/venv/bin/python3" "$(command -v python3)" "$(command -v python)"; do
    if [ -x "$py" ]; then
      "$py" -m pip install --no-cache-dir --upgrade --force-reinstall uvicorn watchfiles || true
      "$py" - <<'PY'
import sysconfig, os
path = sysconfig.get_paths().get('purelib') or sysconfig.get_paths().get('platlib')
os.makedirs(path, exist_ok=True)
fn = os.path.join(path, 'sitecustomize.py')
content = """
import os
# Mitigate watchfiles FD exhaustion by forcing polling
os.environ.setdefault('WATCHFILES_FORCE_POLLING', '1')
# Raise soft open-file limit when possible
try:
    import resource
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft < 4096:
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(4096, hard), hard))
except Exception:
    pass
# Provide a safe default for Uvicorn app if none is passed
os.environ.setdefault('UVICORN_APP', 'openhands.server.listen:app')
"""
try:
    existing = ""
    if os.path.exists(fn):
        existing = open(fn, "r").read()
    if content not in existing:
        with open(fn, "a") as f:
            if existing and not existing.endswith("\n"):
                f.write("\n")
            f.write(content)
    print(f"Wrote {fn}")
except Exception as e:
    print(f"Failed to write {fn}: {e}")
PY
    fi
  done

  # If a previous wrapper renamed uvicorn, try to restore original executable by reinstalling and moving back
  if [ -f /opt/venv/bin/uvicorn.bin ]; then
    if [ -x /opt/venv/bin/python ]; then
      /opt/venv/bin/python -m pip install --no-cache-dir --upgrade --force-reinstall uvicorn watchfiles || true
    fi
    rm -f /opt/venv/bin/uvicorn || true
    mv /opt/venv/bin/uvicorn.bin /opt/venv/bin/uvicorn 2>/dev/null || true
    chmod +x /opt/venv/bin/uvicorn || true
  fi
}

patch_uvicorn_reload_patterns() {
  local mf="$APP_DIR/Makefile"
  if [ -f "$mf" ]; then
    log "Patching Makefile to remove uvicorn reload flags and use 'python3 -m uvicorn'"
    (
      cd "$APP_DIR"
      cp Makefile Makefile.bak || true
      # Remove absolute reload include/exclude patterns and replace uvicorn with python3 -m uvicorn
      sed -i -E 's/--reload-(include|exclude)[[:space:]]+[^[:space:]]+//g' Makefile
      sed -i -E -e '/uvicorn/s/--reload-(include|exclude)(=[^ ]+| [^ ]+)//g' -e '/uvicorn/s/\buvicorn\b/python3 -m uvicorn/g' Makefile
      # Apply explicit substitutions as per repair commands (idempotent)
      sed -i -E 's/(^|\s)uvicorn(\s)/\1python3 -m uvicorn\2/g' Makefile
      sed -i -E 's/\s--reload-(include|exclude)\s+[^[:space:]]+//g' Makefile
      # Additional targeted patch: fix $(pwd) and clean start-backend recipe
      python3 - <<'PY'
import re, pathlib, sys
p = pathlib.Path('Makefile')
if not p.exists():
    sys.exit(0)
s = p.read_text()
# Fix invalid $(pwd) usage
s = s.replace('$(pwd)', '$(PWD)')
lines = s.splitlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    out.append(line)
    if re.match(r'^\s*start-backend\s*:', line):
        # Skip existing recipe lines (tabs/spaces) until next non-indented or next target
        i += 1
        while i < len(lines) and (lines[i].startswith('\t') or lines[i].startswith('    ')) and not re.match(r'^[^\t].*:', lines[i]):
            i += 1
        # Insert clean recipe
        out.append('\t@echo "Starting backend..."')
        out.append('\tpoetry run uvicorn openhands.server.listen:app --host "127.0.0.1" --port 3000 --reload')
        continue
    i += 1
new = '\n'.join(out) + '\n'
if new != s:
    backup = p.with_suffix('.bak')
    if not backup.exists():
        backup.write_text(s)
    p.write_text(new)
print('Patched Makefile')
PY
    )
  fi
}

ensure_main_entrypoint() {
  local main_file="$APP_DIR/main.py"
  if [ ! -f "$main_file" ]; then
    cat >"$main_file" <<'PY'
#!/usr/bin/env python3
print("OpenHands repository: no top-level main.py; use make start or poetry run.")
PY
    chmod +x "$main_file"
  fi
}

# =========================
# Entry point hinting
# =========================
print_usage_hints() {
  case "$PROJECT_TYPE" in
    python)
      if [ -f "$APP_DIR/app.py" ]; then
        log "To run: . $APP_DIR/.venv/bin/activate && python $APP_DIR/app.py"
      elif [ -f "$APP_DIR/manage.py" ]; then
        log "To run: . $APP_DIR/.venv/bin/activate && python $APP_DIR/manage.py runserver 0.0.0.0:8000"
      else
        log "Python app ready. Activate venv: . $APP_DIR/.venv/bin/activate"
      fi
      ;;
    node)
      if [ -f "$APP_DIR/package.json" ]; then
        if grep -q '"start"' "$APP_DIR/package.json"; then
          log "To run: cd $APP_DIR && npm run start"
        else
          log "To run: cd $APP_DIR && node index.js (or your main script)"
        fi
      fi
      ;;
    ruby)
      if [ -f "$APP_DIR/config.ru" ]; then
        log "To run: cd $APP_DIR && rackup -o 0.0.0.0 -p \${PORT:-9292}"
      elif [ -f "$APP_DIR/bin/rails" ]; then
        log "To run: cd $APP_DIR && bundle exec rails server -b 0.0.0.0 -p \${PORT:-3000}"
      fi
      ;;
    java-maven)
      log "To run: java -jar $(find "$APP_DIR" -type f -name '*.jar' | head -n1 2>/dev/null || echo 'your-app.jar')"
      ;;
    java-gradle)
      log "To run: java -jar $(find "$APP_DIR" -type f -name '*.jar' | head -n1 2>/dev/null || echo 'your-app.jar')"
      ;;
    go)
      if [ -x "$APP_DIR/bin/app" ]; then
        log "To run: $APP_DIR/bin/app"
      else
        log "To run: cd $APP_DIR && go run ./..."
      fi
      ;;
    php)
      if [ -f "$APP_DIR/public/index.php" ]; then
        log "To run: php -S 0.0.0.0:\${PORT:-8080} -t $APP_DIR/public"
      else
        log "To run: php your_script.php"
      fi
      ;;
    rust)
      log "To run: $(find "$APP_DIR/target/release" -maxdepth 1 -type f -executable | head -n1 2>/dev/null || echo 'cargo run --release')"
      ;;
    dotnet)
      log "Use a .NET SDK image to build and run (e.g., mcr.microsoft.com/dotnet/sdk)."
      ;;
    *)
      warn "Unknown project type. Ensure runtime dependencies are provided."
      ;;
  esac
}

# =========================
# Main
# =========================
main() {
  log "Starting environment setup: $SCRIPT_NAME"

  # If the APP_DIR does not exist, fallback to current directory
  if [ ! -d "$APP_DIR" ]; then
    warn "APP_DIR '$APP_DIR' not found. Falling back to current directory."
    APP_DIR="$(pwd)"
  fi

  detect_pkg_manager
  install_base_packages
  setup_project_structure
  setup_inline_env_wrapper
  load_env_file
  detect_project_type "$APP_DIR"

  # Apply project-specific repairs (idempotent)
  setup_docker_runtime
  patch_uvicorn_reload_patterns
  install_global_uvicorn
  ensure_uvicorn_fastapi
  ensure_global_yarn
  ensure_sitecustomize
  ensure_project_sitecustomize
  ensure_watchfiles_polling
  ensure_main_entrypoint

  case "$PROJECT_TYPE" in
    python)       setup_python ;;
    node)         setup_node ;;
    ruby)         setup_ruby ;;
    java-maven)   setup_java_maven ;;
    java-gradle)  setup_java_gradle ;;
    go)           setup_go ;;
    php)          setup_php ;;
    rust)         setup_rust ;;
    dotnet)       setup_dotnet ;;
    *)
      warn "No specific project type detected. Installed base packages only."
      ;;
  esac

  print_usage_hints
  log "Environment setup completed successfully."
}

main "$@"