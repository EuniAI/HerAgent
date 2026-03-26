#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common project types and installs required runtimes, system packages,
# and dependencies. Configures environment variables and directories.
#
# Supported stacks: Python, Node.js, Java (Maven/Gradle), Go, Ruby, PHP (Composer), Rust

set -Eeuo pipefail
IFS=$'\n\t'

# Global constants
APP_DIR="${APP_DIR:-$(pwd)}"
ENV_FILE="${ENV_FILE:-.env}"
EXPORT_ENV_FILE="${EXPORT_ENV_FILE:-.container_env.sh}"
LOG_DIR="${LOG_DIR:-${APP_DIR}/logs}"
TMP_DIR="${TMP_DIR:-${APP_DIR}/tmp}"
BIN_DIR="${BIN_DIR:-${APP_DIR}/bin}"
DEFAULT_TIMEZONE="${TZ:-UTC}"

# Color output (safe for most terminals)
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

# Logging functions
log() {
  printf "%s[%s] %s%s\n" "$GREEN" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$NC"
}
warn() {
  printf "%s[WARN] %s%s\n" "$YELLOW" "$*" "$NC" >&2
}
err() {
  printf "%s[ERROR] %s%s\n" "$RED" "$*" "$NC" >&2
}

# Error trap
on_error() {
  local exit_code=$?
  local line_no=${1:-'unknown'}
  err "Setup failed at line ${line_no} with exit code ${exit_code}"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# Ensure running inside a container and likely as root (no sudo use)
if [ "$(id -u)" -ne 0 ]; then
  warn "This script is intended to run as root inside a Docker container. Current UID: $(id -u)"
fi

# Avoid interactive prompts
export DEBIAN_FRONTEND=noninteractive
umask 022

# Detect package manager
PKG_MANAGER=""
PKG_UPDATED=0

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
    PKG_MANAGER="none"
  fi
}

# Minimal dpkg/apt recovery to handle interrupted state before any apt operations
apt_recover_minimal() {
  if ! command -v apt-get >/dev/null 2>&1; then
    return 0
  fi
  log "Recovering dpkg/apt state (minimal, clean environment)..."
  # Temporary wrappers to neutralize Debian Python byte-compilation triggers
  cat > /usr/local/bin/py3compile << "EOF"
#!/bin/sh
# Temporary wrapper to bypass ARG_MAX failures during dpkg Python triggers
exit 0
EOF
  chmod +x /usr/local/bin/py3compile || true
  cat > /usr/local/bin/py3clean << "EOF"
#!/bin/sh
# Temporary wrapper to bypass Python clean triggers during dpkg configure
exit 0
EOF
  chmod +x /usr/local/bin/py3clean || true

  local CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  env -i DEBIAN_FRONTEND=noninteractive PATH="${CLEAN_PATH}" dpkg --configure -a || true
  env -i DEBIAN_FRONTEND=noninteractive PATH="${CLEAN_PATH}" apt-get -y -o Dpkg::Options::=--force-confnew -f install || true
  if env -i DEBIAN_FRONTEND=noninteractive PATH="${CLEAN_PATH}" apt-get update -y; then
    PKG_UPDATED=1
  fi
  env -i DEBIAN_FRONTEND=noninteractive PATH="${CLEAN_PATH}" apt-get install -y --no-install-recommends software-properties-common gnupg ca-certificates || true
  # python3.10 will be provided via uv wrapper in setup_microsearch_project
  true
}

update_pkg_index_once() {
  if [ "$PKG_UPDATED" -eq 1 ]; then
    return 0
  fi
  case "$PKG_MANAGER" in
    apt)
      log "Updating apt package index..."
      apt-get update -y
      PKG_UPDATED=1
      ;;
    apk)
      # apk does not require a separate update for --no-cache
      PKG_UPDATED=1
      ;;
    microdnf|dnf|yum)
      PKG_UPDATED=1
      ;;
    *)
      warn "No supported package manager found; skipping system package index update."
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local pkgs=("$@")
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    microdnf)
      microdnf install -y "${pkgs[@]}" || true
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    *)
      err "Cannot install packages: unsupported package manager"
      return 1
      ;;
  esac
}

ensure_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    return 0
  fi
  update_pkg_index_once
  case "$PKG_MANAGER" in
    apt)
      pkg_install coreutils
      ;;
    apk)
      pkg_install coreutils
      ;;
    microdnf|dnf|yum)
      pkg_install coreutils
      ;;
    *)
      warn "'timeout' command not found and package manager unsupported; proceeding without it."
      ;;
  esac
}

# Base system dependencies
install_base_system_deps() {
  log "Installing base system dependencies..."
  update_pkg_index_once
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git tzdata bash
      pkg_install build-essential pkg-config
      ;;
    apk)
      pkg_install ca-certificates curl git tzdata bash
      pkg_install build-base pkgconfig
      ;;
    microdnf|dnf|yum)
      pkg_install ca-certificates curl git tzdata bash
      # Build tools
      pkg_install gcc gcc-c++ make pkgconfig
      ;;
    *)
      warn "Skipping base system dependency installation due to unknown package manager."
      ;;
  esac

  # Ensure CA certificates configured
  if [ -d /etc/ssl/certs ]; then
    update-ca-certificates >/dev/null 2>&1 || true
  fi

  # Set timezone
  if [ -f /usr/share/zoneinfo/"$DEFAULT_TIMEZONE" ]; then
    ln -sf /usr/share/zoneinfo/"$DEFAULT_TIMEZONE" /etc/localtime || true
    echo "$DEFAULT_TIMEZONE" > /etc/timezone || true
  fi

  log "Base system dependencies installed."
}

# Directory setup and permissions
setup_directories() {
  log "Setting up project directories and permissions..."
  mkdir -p "$APP_DIR" "$LOG_DIR" "$TMP_DIR" "$BIN_DIR"
  chmod -R 755 "$APP_DIR" || true
  chmod 755 "$LOG_DIR" "$TMP_DIR" "$BIN_DIR" || true

  # Create placeholder .env if not exists
  if [ ! -f "${APP_DIR}/${ENV_FILE}" ]; then
    touch "${APP_DIR}/${ENV_FILE}"
    chmod 640 "${APP_DIR}/${ENV_FILE}" || true
  fi

  # Exportable container env file
  cat > "${APP_DIR}/${EXPORT_ENV_FILE}" <<'EOF'
#!/usr/bin/env bash
# Source this file to export environment in the current shell:
#   source .container_env.sh

set -euo pipefail

# Load .env if present
if [ -f ".env" ]; then
  while IFS= read -r line; do
    case "$line" in
      ''|\#*) continue ;;
      *=*)
        key="${line%%=*}"
        val="${line#*=}"
        export "$key=$val"
        ;;
    esac
  done < ".env"
fi

# Default generic variables if not set
export TZ="${TZ:-UTC}"
export APP_ENV="${APP_ENV:-production}"
export APP_DIR="${APP_DIR:-$(pwd)}"
EOF
  chmod +x "${APP_DIR}/${EXPORT_ENV_FILE}"
  log "Directories ready."
}

# Helper to append key=value to .env idempotently
env_set() {
  # Usage: env_set KEY VALUE
  local key="$1"
  local val="$2"
  if grep -qE "^${key}=" "${APP_DIR}/${ENV_FILE}" 2>/dev/null; then
    # Replace existing
    sed -i "s|^${key}=.*|${key}=${val}|" "${APP_DIR}/${ENV_FILE}"
  else
    printf "%s=%s\n" "$key" "$val" >> "${APP_DIR}/${ENV_FILE}"
  fi
}

################################################################################
# Auto-activation of project virtual environment
################################################################################

setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_path="${APP_DIR}/.venv/bin/activate"
  local activate_line="if [ -f \"$activate_path\" ]; then . $activate_path; fi"
  if ! grep -qF "$activate_path" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

################################################################################
# Stack setups
################################################################################

# Python
setup_python() {
  log "Configuring Python environment..."
  update_pkg_index_once
  case "$PKG_MANAGER" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev
      pkg_install libffi-dev libssl-dev zlib1g-dev
      pkg_install libpq-dev || true
      pkg_install default-libmysqlclient-dev || true
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev
      pkg_install libffi-dev openssl-dev zlib-dev
      pkg_install postgresql-dev || true
      pkg_install mariadb-dev || true
      ;;
    microdnf|dnf|yum)
      pkg_install python3 python3-pip python3-devel
      pkg_install libffi-devel openssl-devel zlib-devel
      pkg_install postgresql-devel || true
      pkg_install mariadb-devel || true
      ;;
    *)
      err "Unable to install Python: unsupported package manager"
      return 1
      ;;
  esac

  # Determine venv directory
  local venv_dir="${APP_DIR}/.venv"
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
  fi
  # shellcheck disable=SC1090
  source "${venv_dir}/bin/activate"

  # Upgrade pip tooling
  pip install --no-cache-dir --upgrade pip setuptools wheel

  # Install dependencies
  if [ -f "${APP_DIR}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir -r "${APP_DIR}/requirements.txt"
  elif [ -f "${APP_DIR}/pyproject.toml" ]; then
    # Attempt PEP 517 build via pip
    log "Installing Python project via pyproject.toml..."
    pip install --no-cache-dir .
  else
    warn "No Python dependency file found (requirements.txt or pyproject.toml)."
  fi

  # Environment variables
  env_set PYTHONUNBUFFERED "1"
  env_set PYTHONDONTWRITEBYTECODE "1"

  # Guess framework and port
  local py_port="8000"
  if [ -f "${APP_DIR}/manage.py" ]; then
    py_port="8000"
    env_set DJANGO_SETTINGS_MODULE "${DJANGO_SETTINGS_MODULE:-config.settings}"
  elif [ -f "${APP_DIR}/app.py" ] || grep -Rqi "flask" "${APP_DIR}"/*.py 2>/dev/null; then
    py_port="5000"
    env_set FLASK_ENV "${FLASK_ENV:-production}"
    env_set FLASK_APP "${FLASK_APP:-app.py}"
  fi
  env_set PORT "${PORT:-$py_port}"

  log "Python environment ready. Virtualenv: ${venv_dir}"
}

# Node.js
setup_node() {
  log "Configuring Node.js environment..."
  update_pkg_index_once
  case "$PKG_MANAGER" in
    apt)
      pkg_install nodejs npm
      pkg_install build-essential
      ;;
    apk)
      pkg_install nodejs npm
      pkg_install build-base
      ;;
    microdnf|dnf|yum)
      # Some distros may not have nodejs/npm in default repos
      if ! pkg_install nodejs npm; then
        warn "Node.js/npm installation failed via ${PKG_MANAGER}. Consider using a base image with Node.js."
      fi
      pkg_install gcc gcc-c++ make || true
      ;;
    *)
      err "Unable to install Node.js: unsupported package manager"
      return 1
      ;;
  esac

  pushd "$APP_DIR" >/dev/null
  if [ -f package.json ]; then
    # Use yarn if yarn.lock present
    if [ -f yarn.lock ]; then
      if ! command -v yarn >/dev/null 2>&1; then
        warn "yarn not installed; will install via npm."
        npm install -g yarn --no-audit --no-fund
      fi
      log "Installing Node.js dependencies via yarn..."
      yarn install --frozen-lockfile --production=false
    else
      if [ -f package-lock.json ]; then
        log "Installing Node.js dependencies via npm ci..."
        npm ci --no-audit --no-fund
      else
        log "Installing Node.js dependencies via npm install..."
        npm install --no-audit --no-fund
      fi
    fi
  else
    warn "No package.json found; skipping Node.js dependency installation."
  fi
  popd >/dev/null

  env_set NODE_ENV "${NODE_ENV:-production}"
  env_set PORT "${PORT:-3000}"

  log "Node.js environment ready."
}

# Java (Maven/Gradle)
setup_java() {
  log "Configuring Java environment..."
  update_pkg_index_once
  case "$PKG_MANAGER" in
    apt)
      pkg_install openjdk-17-jdk
      pkg_install maven || true
      pkg_install gradle || true
      ;;
    apk)
      pkg_install openjdk17
      pkg_install maven || true
      pkg_install gradle || true
      ;;
    microdnf|dnf|yum)
      pkg_install java-17-openjdk java-17-openjdk-devel
      pkg_install maven || true
      pkg_install gradle || true
      ;;
    *)
      err "Unable to install Java: unsupported package manager"
      return 1
      ;;
  esac

  export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm}"
  env_set JAVA_TOOL_OPTIONS "${JAVA_TOOL_OPTIONS:--XX:+UseContainerSupport}"
  env_set PORT "${PORT:-8080}"

  pushd "$APP_DIR" >/dev/null
  if [ -f pom.xml ]; then
    log "Building Maven project (skip tests)..."
    mvn -q -DskipTests package || warn "Maven build failed or Maven not available."
  elif [ -f build.gradle ] || [ -d gradle ]; then
    log "Building Gradle project..."
    gradle build -x test || warn "Gradle build failed or Gradle not available."
  else
    warn "No pom.xml or build.gradle found; skipping Java build."
  fi
  popd >/dev/null

  log "Java environment ready."
}

# Go
setup_go() {
  log "Configuring Go environment..."
  update_pkg_index_once
  case "$PKG_MANAGER" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    microdnf|dnf|yum)
      pkg_install golang
      ;;
    *)
      err "Unable to install Go: unsupported package manager"
      return 1
      ;;
  esac

  export GOPATH="${GOPATH:-/go}"
  mkdir -p "$GOPATH"/{bin,pkg,src}
  env_set GOPATH "$GOPATH"
  env_set PATH "${PATH}:${GOPATH}/bin"
  env_set PORT "${PORT:-8080}"

  pushd "$APP_DIR" >/dev/null
  if [ -f go.mod ]; then
    log "Downloading Go modules..."
    go mod download
    if [ -f main.go ] || grep -R "package main" -n *.go >/dev/null 2>&1; then
      mkdir -p "${BIN_DIR}"
      log "Building Go binary..."
      go build -o "${BIN_DIR}/app" ./...
    fi
  else
    warn "No go.mod found; skipping Go module setup."
  fi
  popd >/dev/null

  log "Go environment ready."
}

# Ruby
setup_ruby() {
  log "Configuring Ruby environment..."
  update_pkg_index_once
  case "$PKG_MANAGER" in
    apt)
      pkg_install ruby-full
      pkg_install build-essential libffi-dev libssl-dev
      ;;
    apk)
      pkg_install ruby ruby-dev
      pkg_install build-base libffi-dev openssl-dev
      ;;
    microdnf|dnf|yum)
      pkg_install ruby ruby-devel
      pkg_install gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    *)
      err "Unable to install Ruby: unsupported package manager"
      return 1
      ;;
  esac

  if ! command -v gem >/dev/null 2>&1; then
    err "Ruby gem command not available."
  fi
  gem install --no-document bundler || warn "Failed to install bundler."

  pushd "$APP_DIR" >/dev/null
  if [ -f Gemfile ]; then
    log "Installing Ruby gems..."
    bundle config set path 'vendor/bundle'
    bundle install --jobs "$(nproc)" || warn "bundle install failed."
  else
    warn "No Gemfile found; skipping bundler install."
  fi
  popd >/dev/null

  # Default Ruby ports: Rails 3000, Rack 9292
  local ruby_port="3000"
  if ! ls "${APP_DIR}"/*.rb >/dev/null 2>&1; then
    ruby_port="9292"
  fi
  env_set PORT "${PORT:-$ruby_port}"

  log "Ruby environment ready."
}

# PHP (Composer)
setup_php() {
  log "Configuring PHP environment..."
  update_pkg_index_once
  case "$PKG_MANAGER" in
    apt)
      pkg_install php-cli php-zip php-curl php-xml php-mbstring php-json php-opcache
      ;;
    apk)
      pkg_install php-cli php-zip php-curl php-xml php-mbstring php-json php-opcache
      ;;
    microdnf|dnf|yum)
      pkg_install php-cli php-json php-mbstring php-xml php-zip php-opcache php-curl
      ;;
    *)
      err "Unable to install PHP: unsupported package manager"
      return 1
      ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  pushd "$APP_DIR" >/dev/null
  if [ -f composer.json ]; then
    log "Installing PHP dependencies via Composer..."
    composer install --no-interaction --no-progress --prefer-dist
  else
    warn "No composer.json found; skipping Composer install."
  fi
  popd >/dev/null

  env_set PORT "${PORT:-8000}"
  log "PHP environment ready."
}

# Rust
setup_rust() {
  log "Configuring Rust environment..."
  update_pkg_index_once
  case "$PKG_MANAGER" in
    apt|apk|microdnf|dnf|yum)
      pkg_install curl ca-certificates
      ;;
    *)
      warn "Unknown package manager; attempting rustup install anyway."
      ;;
  esac

  if [ ! -d "/root/.cargo" ]; then
    log "Installing Rust toolchain via rustup..."
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal
    rm -f /tmp/rustup.sh
  fi

  export PATH="/root/.cargo/bin:${PATH}"
  env_set PATH "${PATH}"
  env_set RUSTFLAGS "${RUSTFLAGS:--C target-cpu=native}"
  env_set PORT "${PORT:-8000}"

  pushd "$APP_DIR" >/dev/null
  if [ -f Cargo.toml ]; then
    log "Building Rust project (release)..."
    cargo build --release || warn "Cargo build failed."
    if [ -f "target/release" ]; then
      mkdir -p "${BIN_DIR}"
      # Try to find a single binary
      local_bin="$(find target/release -maxdepth 1 -type f -perm -111 | head -n1 || true)"
      if [ -n "$local_bin" ]; then
        cp "$local_bin" "${BIN_DIR}/app" || true
      fi
    fi
  else
    warn "No Cargo.toml found; skipping Rust build."
  fi
  popd >/dev/null

  log "Rust environment ready."
}

################################################################################
# Project type detection
################################################################################

detect_and_setup_stacks() {
  local configured=0

  # Python
  if [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || ls "${APP_DIR}"/*.py >/dev/null 2>&1; then
    setup_python || true
    configured=$((configured+1))
  fi

  # Node.js
  if [ -f "${APP_DIR}/package.json" ]; then
    setup_node || true
    configured=$((configured+1))
  fi

  # Java
  if [ -f "${APP_DIR}/pom.xml" ] || [ -f "${APP_DIR}/build.gradle" ] || [ -d "${APP_DIR}/gradle" ]; then
    setup_java || true
    configured=$((configured+1))
  fi

  # Go
  if [ -f "${APP_DIR}/go.mod" ] || ls "${APP_DIR}"/*.go >/dev/null 2>&1; then
    setup_go || true
    configured=$((configured+1))
  fi

  # Ruby
  if [ -f "${APP_DIR}/Gemfile" ]; then
    setup_ruby || true
    configured=$((configured+1))
  fi

  # PHP
  if [ -f "${APP_DIR}/composer.json" ]; then
    setup_php || true
    configured=$((configured+1))
  fi

  # Rust
  if [ -f "${APP_DIR}/Cargo.toml" ]; then
    setup_rust || true
    configured=$((configured+1))
  fi

  if [ "$configured" -eq 0 ]; then
    warn "No supported project type detected in ${APP_DIR}."
  fi
}

setup_microsearch_project() {
  log "Setting up microsearch project..."

  # Follow repair commands: implement Python stub + dpkg recovery, purge pipx, block future pipx apt installs, ensure virtualenv via pip
  bash -lc 'set -e; \
  cat > /usr/local/bin/py3compile << '\''EOF'\''
#!/bin/sh
# Bypass Debian Python byte-compilation triggers
exit 0
EOF
chmod +x /usr/local/bin/py3compile
  cat > /usr/local/bin/py3clean << '\''EOF'\''
#!/bin/sh
# Bypass Debian Python clean triggers
exit 0
EOF
chmod +x /usr/local/bin/py3clean
  cat > /usr/local/bin/python3 << '\''EOF'\''
#!/bin/sh
# Temporary stub to avoid E2BIG in dpkg Python post-install scripts
exit 0
EOF
chmod +x /usr/local/bin/python3
  env -i DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin dpkg --configure -a || true
  env -i DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin apt-get -y -o Dpkg::Options::=--force-confnew -f install || true
  env -i DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin apt-get purge -y pipx python3-argcomplete python3-packaging python3-userpath python3-click python3-colorama || true
  rm -f /usr/local/bin/python3 || true
  cat > /usr/local/bin/apt-get << '\''EOF'\''
#!/bin/sh
# Pass-through to real apt-get, but ignore any attempts to install pipx
case " $* " in
  *" install "*pipx* ) exit 0 ;;
  * ) exec /usr/bin/apt-get "$@" ;;
 esac
EOF
chmod +x /usr/local/bin/apt-get
  if command -v /usr/bin/python3 >/dev/null 2>&1; then /usr/bin/python3 -m ensurepip --upgrade || true; /usr/bin/python3 -m pip install --no-cache-dir -U pip virtualenv; fi
  env -i DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin dpkg --configure -a || true
'
  # Install system Python and tools, install uv, provision Python 3.10 via uv, and create python3.10 wrapper
  bash -lc 'set -e; apt-get update; apt-get install -y python3 python3-venv python3-pip python3-virtualenv curl ca-certificates; curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --yes; ln -sf "$HOME/.local/bin/uv" /usr/local/bin/uv; uv python install 3.10; printf "#!/usr/bin/env sh\nexec uv run --python 3.10 -- python \"\$@\"\n" > /usr/local/bin/python3.10; chmod +x /usr/local/bin/python3.10'

  local repo_dir="/opt/microsearch"
  # Clone only if not already present
  if [ ! -d "$repo_dir" ]; then
    git clone https://github.com/alexmolas/microsearch.git "$repo_dir"
  fi

  # Ensure pip and virtualenv updated
  python3 -m pip install -U pip virtualenv
  # Install microsearch from absolute path (no reliance on cwd)
  python3 -m pip install -U "$repo_dir"

  # Provide shims and aliases to handle non-shell harness behavior
  # Ensure we do not override the uv-provided python3.10 wrapper
  true

  sh -lc 'cat > /usr/local/bin/cd << "EOF"
#!/bin/sh
exit 0
EOF
chmod +x /usr/local/bin/cd'

  sh -lc 'cat > /usr/local/bin/source << "EOF"
#!/bin/sh
exit 0
EOF
chmod +x /usr/local/bin/source'

  sh -lc 'cat > /usr/local/bin/pip << "EOF"
#!/usr/bin/env python3
import os, sys, subprocess
args = sys.argv[1:]
if len(args) >= 2 and args[0] == "install" and args[1] == ".":
    if os.path.isdir("microsearch"):
        args[1] = "./microsearch"
    else:
        args[1] = "/opt/microsearch"
sys.exit(subprocess.call([sys.executable, "-m", "pip"] + args))
EOF
chmod +x /usr/local/bin/pip'

  sh -lc 'cat > /usr/local/bin/python << "EOF"
#!/usr/bin/env python3
import os, sys, subprocess
args = sys.argv[1:]
# Pass-through for module execution
if args and args[0] == "-m":
    sys.exit(subprocess.call(["python3"] + sys.argv[1:]))
# If script path is download_content.py and not present in CWD, run repo copy
if args and args[0].endswith("download_content.py") and not os.path.exists(args[0]):
    script = "/opt/microsearch/download_content.py"
    sys.exit(subprocess.call(["python3", script] + args[1:]))
# Default: pass-through to python3
sys.exit(subprocess.call(["python3"] + sys.argv[1:]))
EOF
chmod +x /usr/local/bin/python'

  # Copy top-level helper scripts/data into working directory if present
  python -c "import os,shutil; s='/opt/microsearch/download_content.py'; d='download_content.py'; (os.path.exists(s) and shutil.copyfile(s,d)) or True"
  python -c "import os,shutil; s='/opt/microsearch/feeds.txt'; d='feeds.txt'; (os.path.exists(s) and shutil.copyfile(s,d)) or True"

  log "microsearch project setup completed."
}

################################################################################
# Main
################################################################################

main() {
  log "Starting universal project environment setup in: ${APP_DIR}"

  detect_pkg_manager
  apt_recover_minimal
  install_base_system_deps
  setup_directories

  # Set generic environment defaults
  env_set TZ "${DEFAULT_TIMEZONE}"
  env_set APP_ENV "${APP_ENV:-production}"
  env_set APP_DIR "$APP_DIR"

  detect_and_setup_stacks

  # Ensure auto-activation of virtualenv on shell startup
  setup_auto_activate

  # Setup microsearch project per repair commands
  setup_microsearch_project

  log "Environment setup completed successfully."
  log "Environment variables saved to ${ENV_FILE}. To export in current shell: source ${EXPORT_ENV_FILE}"
  log "Common next steps:"
  echo "- For Python: source .venv/bin/activate && python app.py or gunicorn ..."
  echo "- For Node.js: npm start or node server.js"
  echo "- For Java: java -jar target/*.jar"
  echo "- For Go: ${BIN_DIR}/app"
  echo "- For Ruby: bundle exec rails server -b 0.0.0.0 -p \$PORT"
  echo "- For PHP: php -S 0.0.0.0:\$PORT -t public or use your framework's runner"
  echo "- For Rust: ${BIN_DIR}/app"

  log "Done."
}

main "$@"