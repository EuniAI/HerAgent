#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects project type (Python, Node.js, Go, Rust, Java, PHP, Ruby) from files
# - Installs system packages and language runtimes
# - Installs project dependencies
# - Configures environment variables and directory structure
# - Idempotent and safe to re-run

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Colors for output (safe even if not supported)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

# Error trap for diagnostics
on_error() {
  local exit_code=$?
  local line=${BASH_LINENO[0]}
  err "Script failed at line $line with exit code $exit_code"
  exit $exit_code
}
trap on_error ERR

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Detect OS package manager
detect_pkg_manager() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
  else
    ID=""
  fi
  if has_cmd apt-get; then
    PKG_MGR="apt"
  elif has_cmd apk; then
    PKG_MGR="apk"
  elif has_cmd dnf; then
    PKG_MGR="dnf"
  elif has_cmd yum; then
    PKG_MGR="yum"
  elif has_cmd pacman; then
    PKG_MGR="pacman"
  else
    PKG_MGR=""
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache
      ;;
    pacman)
      pacman -Sy --noconfirm
      ;;
    *)
      die "Unsupported package manager. Please ensure required tools are installed."
      ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  case "$PKG_MGR" in
    apt)
      # avoid tzdata prompts
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    pacman)
      pacman -S --noconfirm --needed "${pkgs[@]}"
      ;;
    *)
      die "Unsupported package manager. Cannot install packages: ${pkgs[*]}"
      ;;
  esac
}

clean_pkg_cache() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
      ;;
    dnf)
      dnf clean all -y || true
      rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*
      ;;
    yum)
      yum clean all -y || true
      rm -rf /var/cache/yum/* /tmp/* /var/tmp/*
      ;;
    pacman)
      yes | pacman -Scc || true
      rm -rf /tmp/* /var/tmp/*
      ;;
  esac
}

# Repair interrupted apt/dpkg state before any install
apt_repair_state() {
  if [ "$PKG_MGR" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -f install
    apt-get clean
    rm -rf /var/lib/apt/lists/*
  fi
}

# Ensure Ubuntu 'universe' and 'multiverse' components are enabled and apt state is healthy
enable_ubuntu_components() {
  if [ "$PKG_MGR" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-mark unhold npm nodejs || true
    apt-get update -y
    apt-get install -y --no-install-recommends software-properties-common
    add-apt-repository -y universe || true
    add-apt-repository -y multiverse || true
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -f install || true
  fi
}

# Ensure base tools
install_base_tools() {
  log "Installing base system tools and build essentials (idempotent)..."
  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git bash gnupg dirmngr tzdata \
                  build-essential pkg-config xz-utils unzip zip
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git bash gnupg tzdata \
                  build-base pkgconfig xz unzip zip
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git gnupg2 tzdata \
                  make automake gcc gcc-c++ kernel-devel pkgconf-pkg-config xz unzip zip
      update-ca-trust || true
      ;;
    pacman)
      pkg_install ca-certificates curl git gnupg tzdata base-devel pkgconf xz unzip zip
      update-ca-trust || true
      ;;
  esac
}

# User and directory setup
setup_app_user_and_dirs() {
  APP_DIR="${APP_DIR:-/app}"
  APP_USER="${APP_USER:-}"
  APP_GROUP="${APP_GROUP:-}"

  mkdir -p "$APP_DIR"
  mkdir -p "$APP_DIR"/{logs,tmp,data}
  chmod -R 755 "$APP_DIR"

  if [ -n "$APP_USER" ]; then
    log "Ensuring application user/group: ${APP_USER}${APP_GROUP:+:${APP_GROUP}}"
    if [ -n "$APP_GROUP" ]; then
      if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
        groupadd -r "$APP_GROUP" || true
      fi
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      if [ -n "$APP_GROUP" ]; then
        useradd -r -g "$APP_GROUP" -d "$APP_DIR" -s /sbin/nologin "$APP_USER" || useradd -r -g "$APP_GROUP" -d "$APP_DIR" -s /bin/false "$APP_USER" || true
      else
        useradd -r -d "$APP_DIR" -s /sbin/nologin "$APP_USER" || useradd -r -d "$APP_DIR" -s /bin/false "$APP_USER" || true
      fi
    fi
    chown -R "$APP_USER":"${APP_GROUP:-$APP_USER}" "$APP_DIR" || true
  fi
}

# Project detection
detect_project_types() {
  IS_PYTHON=0
  IS_NODE=0
  IS_GO=0
  IS_RUST=0
  IS_JAVA_MAVEN=0
  IS_JAVA_GRADLE=0
  IS_PHP=0
  IS_RUBY=0

  cd "$APP_DIR"

  # Python indicators
  if [ -f requirements.txt ] || [ -f pyproject.toml ] || ls *.py >/dev/null 2>&1; then
    IS_PYTHON=1
  fi

  # Node.js indicators
  if [ -f package.json ] || [ -f pnpm-lock.yaml ] || [ -f yarn.lock ] || [ -f package-lock.json ]; then
    IS_NODE=1
  fi

  # Go indicators
  if [ -f go.mod ] || [ -f main.go ]; then
    IS_GO=1
  fi

  # Rust indicators
  if [ -f Cargo.toml ]; then
    IS_RUST=1
  fi

  # Java indicators
  if [ -f pom.xml ]; then
    IS_JAVA_MAVEN=1
  fi
  if [ -f build.gradle ] || [ -f settings.gradle ] || [ -f build.gradle.kts ]; then
    IS_JAVA_GRADLE=1
  fi

  # PHP indicators
  if [ -f composer.json ]; then
    IS_PHP=1
  fi

  # Ruby indicators
  if [ -f Gemfile ]; then
    IS_RUBY=1
  fi
}

# Python setup
setup_python() {
  log "Configuring Python environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev libffi-dev libssl-dev \
                  libpq-dev zlib1g-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev libffi-dev openssl-dev \
                  postgresql-dev zlib-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel libffi-devel openssl-devel \
                  postgresql-devel zlib-devel
      ;;
    pacman)
      pkg_install python python-pip python-virtualenv base-devel libffi openssl zlib
      ;;
  esac

  # Create and activate virtual environment
  if [ ! -d "$APP_DIR/.venv" ]; then
    python3 -m venv "$APP_DIR/.venv"
  fi
  # shellcheck disable=SC1091
  source "$APP_DIR/.venv/bin/activate"

  pip install --no-cache-dir --upgrade pip setuptools wheel

  if [ -f requirements.txt ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir -r requirements.txt
  elif [ -f pyproject.toml ]; then
    # Try PEP 517/518 build if project is a PDM/Poetry/Flit package
    if grep -qiE 'poetry' pyproject.toml; then
      pip install --no-cache-dir poetry
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi --only main || poetry install --no-interaction --no-ansi
    elif grep -qiE 'flit' pyproject.toml; then
      pip install --no-cache-dir flit
      flit install --env --deps production || flit install --env
    else
      if ! command -v cmake >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y --no-install-recommends cmake; elif command -v apk >/dev/null 2>&1; then apk add --no-cache cmake; elif command -v dnf >/dev/null 2>&1; then dnf install -y cmake; elif command -v yum >/dev/null 2>&1; then yum install -y cmake; elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm --needed cmake; fi
      fi
      python -c "import sentencepiece" >/dev/null 2>&1 || pip install --no-cache-dir sentencepiece
      python -c "import deepspeed" >/dev/null 2>&1 || DS_BUILD_OPS=0 pip install --no-cache-dir deepspeed
      PIP_NO_BUILD_ISOLATION=1 pip install --no-build-isolation -e "$APP_DIR"
    fi
  else
    log "No Python dependency file found; skipping pip install."
  fi

  # Default Python env vars
  export PYTHONDONTWRITEBYTECODE=1
  export PYTHONUNBUFFERED=1

  # Record activation helper
  echo 'source "$APP_DIR/.venv/bin/activate" 2>/dev/null || true' > "$APP_DIR/.activate_venv.sh"
}

# Node.js setup
setup_node() {
  log "Configuring Node.js environment..."
  if ! has_cmd node || ! has_cmd npm; then
    case "$PKG_MGR" in
      apt)
        # Ensure required Ubuntu components are enabled and avoid npm conflict with NodeSource
        enable_ubuntu_components
        if dpkg -s nodejs 2>/dev/null | grep -qi nodesource; then
          pkg_install nodejs || true
        else
          pkg_install nodejs npm
        fi
        ;;
      apk)
        pkg_install nodejs npm
        ;;
      dnf|yum)
        pkg_install nodejs npm
        ;;
      pacman)
        pkg_install nodejs npm
        ;;
    esac
  fi

  if has_cmd corepack; then
    corepack enable || true
    corepack prepare --activate || true
  fi

  # Install package managers if needed
  if [ -f yarn.lock ] && ! has_cmd yarn; then
    if has_cmd corepack; then corepack prepare yarn@stable --activate || true; else npm i -g yarn@stable; fi
  fi
  if [ -f pnpm-lock.yaml ] && ! has_cmd pnpm; then
    if has_cmd corepack; then corepack prepare pnpm@latest --activate || true; else npm i -g pnpm@latest; fi
  fi

  # Install dependencies idempotently
  if [ -f package.json ]; then
    if [ -f pnpm-lock.yaml ] && has_cmd pnpm; then
      log "Installing Node.js deps via pnpm..."
      pnpm install --frozen-lockfile || pnpm install
    elif [ -f yarn.lock ] && has_cmd yarn; then
      log "Installing Node.js deps via yarn..."
      yarn install --frozen-lockfile || yarn install
    elif [ -f package-lock.json ]; then
      log "Installing Node.js deps via npm ci..."
      npm ci || npm install --no-audit --no-fund
    else
      log "Installing Node.js deps via npm..."
      npm install --no-audit --no-fund
    fi
  else
    log "No package.json found; skipping Node.js dependency install."
  fi

  export NODE_ENV="${NODE_ENV:-production}"
}

# Go setup
setup_go() {
  log "Configuring Go environment..."
  case "$PKG_MGR" in
    apt) pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    pacman) pkg_install go ;;
  esac
  if [ -f go.mod ]; then
    go mod download
  fi
}

# Rust setup
setup_rust() {
  log "Configuring Rust environment..."
  case "$PKG_MGR" in
    apt) pkg_install cargo rustc ;;
    apk) pkg_install cargo rust ;;
    dnf|yum) pkg_install cargo rust ;;
    pacman) pkg_install rust cargo ;;
  esac
  cargo --version >/dev/null 2>&1 || warn "Cargo may not be fully installed by distro; consider using rustup in builder image."
}

# Java setup
setup_java() {
  log "Configuring Java environment..."
  case "$PKG_MGR" in
    apt) pkg_install openjdk-17-jdk maven gradle ;;
    apk) pkg_install openjdk17 maven gradle ;;
    dnf|yum) pkg_install java-17-openjdk-devel maven gradle ;;
    pacman) pkg_install jdk17-openjdk maven gradle ;;
  esac
  export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
}

# PHP setup
setup_php() {
  log "Configuring PHP environment..."
  case "$PKG_MGR" in
    apt) pkg_install php-cli php-mbstring php-xml php-curl php-zip php-gd php-intl composer ;;
    apk) pkg_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip php81-gd php81-intl composer ;;
    dnf|yum) pkg_install php-cli php-mbstring php-xml php-curl php-zip php-gd php-intl composer ;;
    pacman) pkg_install php php-intl composer ;;
  esac
  if [ -f composer.json ]; then
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress --optimize-autoloader || composer install --no-interaction
  fi
}

# Ruby setup
setup_ruby() {
  log "Configuring Ruby environment..."
  case "$PKG_MGR" in
    apt) pkg_install ruby-full ruby-dev build-essential bundler ;;
    apk) pkg_install ruby ruby-dev build-base ruby-bundler ;;
    dnf|yum) pkg_install ruby ruby-devel make gcc gcc-c++ rubygems ;;
    pacman) pkg_install ruby base-devel ;;
  esac
  if has_cmd gem && ! has_cmd bundler; then gem install bundler --no-document; fi
  if [ -f Gemfile ]; then
    BUNDLE_WITHOUT="${BUNDLE_WITHOUT:-development test}"
    bundle config set without "$BUNDLE_WITHOUT" || true
    bundle install --jobs=4 --retry=3
  fi
}

# Environment configuration
configure_env() {
  # Default env vars
  export APP_ENV="${APP_ENV:-production}"
  export PORT="${PORT:-}"
  export LOG_DIR="$APP_DIR/logs"
  export TMPDIR="$APP_DIR/tmp"
  export PATH="$APP_DIR/.venv/bin:$PATH"

  # Guess a default port if not provided
  if [ -z "$PORT" ]; then
    if [ "$IS_NODE" -eq 1 ]; then
      PORT=3000
    elif [ "$IS_PYTHON" -eq 1 ]; then
      PORT=8000
    elif [ "$IS_PHP" -eq 1 ]; then
      PORT=8080
    else
      PORT=8080
    fi
    export PORT
  fi

  # Write environment file
  cat > "$APP_DIR/.env.container" <<EOF
APP_DIR=$APP_DIR
APP_ENV=$APP_ENV
PORT=$PORT
LOG_DIR=$LOG_DIR
TMPDIR=$TMPDIR
NODE_ENV=${NODE_ENV:-production}
PYTHONUNBUFFERED=${PYTHONUNBUFFERED:-1}
PYTHONDONTWRITEBYTECODE=${PYTHONDONTWRITEBYTECODE:-1}
EOF

  log "Environment variables configured. PORT=${PORT}"
}

# Auto-activate Python virtual environment on shell start
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local activate_line='if [ -d "${APP_DIR:-/app}/.venv" ]; then . "${APP_DIR:-/app}/.venv/bin/activate"; fi'
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate project venv"
      echo "$activate_line"
    } >> "$bashrc_file"
  fi
}

# Additional provisioning for common build tools and auto-build script
ensure_common_build_runtimes() {
  if [ "$PKG_MGR" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    enable_ubuntu_components
    pkg_install ca-certificates curl git make build-essential openjdk-17-jdk maven gradle python3 python3-pip python3-venv
    # Handle Node.js/npm carefully to avoid conflicts with NodeSource packages
    if dpkg -s nodejs 2>/dev/null | grep -qi nodesource; then
      # NodeSource nodejs package provides npm; avoid installing distro npm which conflicts
      pkg_install nodejs || true
    else
      pkg_install nodejs npm || true
    fi
    python3 -m pip install -U pip setuptools wheel || true
  elif [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
    pkg_install java-17-openjdk-devel maven gradle nodejs npm python3 python3-pip python3-virtualenv make gcc gcc-c++ git curl ca-certificates
  elif [ "$PKG_MGR" = "apk" ]; then
    pkg_install openjdk17-jdk maven gradle nodejs npm python3 py3-pip py3-virtualenv make git curl ca-certificates
  fi
}

setup_nodesource_node20() {
  if [ "$PKG_MGR" = "apt" ]; then
    if ! command -v node >/dev/null 2>&1 || ! node -v | grep -qE '^v20\.'; then
      export DEBIAN_FRONTEND=noninteractive
      enable_ubuntu_components
      apt-mark unhold npm nodejs || true
      # Remove distro npm to avoid conflict: NodeSource nodejs provides npm and conflicts with the npm package
      if dpkg -l | awk '{print $2}' | grep -qx npm; then
        apt-get remove -y npm || true
      fi
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      pkg_install nodejs
    fi
  fi
}

enable_corepack_pm() {
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
    corepack prepare yarn@stable --activate || true
    corepack prepare pnpm@latest --activate || true
  fi
  if command -v npm >/dev/null 2>&1; then
    if ! command -v pnpm >/dev/null 2>&1; then npm install -g pnpm || true; fi
    if ! command -v yarn >/dev/null 2>&1; then npm install -g yarn || true; fi
  fi
}

ensure_python_symlink() {
  if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" /usr/local/bin/python || true
  fi
}

configure_pip_no_build_isolation() {
  local pip_dir="${HOME:-/root}/.config/pip"
  mkdir -p "$pip_dir"
  cat > "$pip_dir/pip.conf" <<'EOP'
[global]
no-build-isolation = true
EOP
}

write_auto_build_script() {
  local path="/usr/local/bin/auto-build"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -x ./run_build.sh ]; then
  exec ./run_build.sh
fi

if [ -f mvnw ]; then
  exec ./mvnw -B -DskipTests package
elif [ -f pom.xml ]; then
  exec mvn -B -DskipTests package
elif [ -f gradlew ]; then
  exec ./gradlew build
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  exec gradle build
elif [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm install --frozen-lockfile || pnpm install
    pnpm -s build || true
  elif command -v npm >/dev/null 2>&1; then
    if [ -f package-lock.json ]; then npm ci; else npm install; fi
    npm -s run build || true
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --frozen-lockfile || yarn install
    yarn -s build || true
  else
    echo "No JavaScript package manager found in PATH" >&2
    exit 1
  fi
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
  if ! command -v cmake >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y --no-install-recommends cmake; elif command -v apk >/dev/null 2>&1; then apk add --no-cache cmake; elif command -v dnf >/dev/null 2>&1; then dnf install -y cmake; elif command -v yum >/dev/null 2>&1; then yum install -y cmake; elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm --needed cmake; fi
  fi
  [ -d /app/.venv ] || python3 -m venv /app/.venv
  . /app/.venv/bin/activate
  pip install --no-cache-dir --upgrade pip setuptools wheel
  python -c "import sentencepiece" >/dev/null 2>&1 || pip install --no-cache-dir sentencepiece
  python -c "import deepspeed" >/dev/null 2>&1 || DS_BUILD_OPS=0 pip install --no-cache-dir deepspeed
  PIP_NO_BUILD_ISOLATION=1 pip install --no-build-isolation -e /app
elif [ -f Makefile ]; then
  make build || make
else
  echo "No recognized build system in repository root" >&2
  exit 1
fi
EOF
  chmod +x "$path"
}

create_run_build_symlink() {
  cat > "$APP_DIR/run_build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f mvnw ]; then
  ./mvnw -B -DskipTests package
elif [ -f pom.xml ]; then
  mvn -B -DskipTests package
elif [ -f gradlew ]; then
  ./gradlew build
elif [ -f build.gradle ]; then
  gradle build
elif [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then pnpm install && pnpm -s build || true; elif command -v npm >/dev/null 2>&1; then npm ci && npm -s run build || true; elif command -v yarn >/dev/null 2>&1; then yarn install && yarn -s build || true; else echo "No JS package manager found"; exit 1; fi
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
  if ! command -v cmake >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y --no-install-recommends cmake; elif command -v apk >/dev/null 2>&1; then apk add --no-cache cmake; elif command -v dnf >/dev/null 2>&1; then dnf install -y cmake; elif command -v yum >/dev/null 2>&1; then yum install -y cmake; elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm --needed cmake; fi
  fi
  [ -d /app/.venv ] || python3 -m venv /app/.venv
  . /app/.venv/bin/activate
  pip install --no-cache-dir --upgrade pip setuptools wheel
  python -c "import sentencepiece" >/dev/null 2>&1 || pip install --no-cache-dir sentencepiece
  python -c "import deepspeed" >/dev/null 2>&1 || DS_BUILD_OPS=0 pip install --no-cache-dir deepspeed
  PIP_NO_BUILD_ISOLATION=1 pip install --no-build-isolation -e /app
elif [ -f Makefile ]; then
  make build || make
else
  echo "No recognized build system"; exit 1
fi
EOF
  chmod +x "$APP_DIR/run_build.sh" || true
  if [ ! -f "$APP_DIR/Makefile" ]; then
    cat > "$APP_DIR/Makefile" <<'EOF'
.PHONY: build
build:
	./run_build.sh
EOF
  fi
}

# Main
main() {
  detect_pkg_manager
  [ -n "${PKG_MGR:-}" ] || die "Could not detect a supported package manager in this container."

  APP_DIR="${APP_DIR:-/app}"
  if [ -n "${1:-}" ]; then
    APP_DIR="$1"
  fi
  mkdir -p "$APP_DIR"

  log "Starting environment setup in $APP_DIR using package manager: $PKG_MGR"
  apt_repair_state
  pkg_update
  install_base_tools
  ensure_common_build_runtimes
  setup_nodesource_node20
  enable_corepack_pm
  ensure_python_symlink
  configure_pip_no_build_isolation
  write_auto_build_script
  create_run_build_symlink
  setup_app_user_and_dirs
  detect_project_types

  # Install language runtimes and deps as needed
  if [ "$IS_PYTHON" -eq 1 ]; then setup_python; fi
  if [ "$IS_NODE" -eq 1 ]; then setup_node; fi
  if [ "$IS_GO" -eq 1 ]; then setup_go; fi
  if [ "$IS_RUST" -eq 1 ]; then setup_rust; fi
  if [ "$IS_JAVA_MAVEN" -eq 1 ] || [ "$IS_JAVA_GRADLE" -eq 1 ]; then setup_java; fi
  if [ "$IS_PHP" -eq 1 ]; then setup_php; fi
  if [ "$IS_RUBY" -eq 1 ]; then setup_ruby; fi

  configure_env
  setup_auto_activate

  # Run repo-local build script to avoid fragile inline wrappers
  if [ -x "$APP_DIR/run_build.sh" ]; then
    (cd "$APP_DIR" && ./run_build.sh)
  fi

  # Final permissions if APP_USER provided
  if [ -n "${APP_USER:-}" ]; then
    chown -R "$APP_USER":"${APP_GROUP:-$APP_USER}" "$APP_DIR" || true
  fi

  clean_pkg_cache

  log "Environment setup completed successfully."
  log "Summary:"
  [ "$IS_PYTHON" -eq 1 ] && log " - Python environment ready (.venv created if applicable)"
  [ "$IS_NODE" -eq 1 ] && log " - Node.js environment ready (dependencies installed)"
  [ "$IS_GO" -eq 1 ] && log " - Go environment ready"
  [ "$IS_RUST" -eq 1 ] && log " - Rust environment ready"
  if [ "$IS_JAVA_MAVEN" -eq 1 ] || [ "$IS_JAVA_GRADLE" -eq 1 ]; then log " - Java environment ready"; fi
  [ "$IS_PHP" -eq 1 ] && log " - PHP environment ready"
  [ "$IS_RUBY" -eq 1 ] && log " - Ruby environment ready"

  log "Environment file written to $APP_DIR/.env.container"
  log "Note: This script is idempotent and safe to re-run."
}

main "$@"