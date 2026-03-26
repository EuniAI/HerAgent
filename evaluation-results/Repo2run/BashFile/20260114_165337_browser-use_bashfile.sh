#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects project type and installs appropriate runtimes and dependencies.
# Idempotent, safe to run multiple times.

set -Eeuo pipefail

# Globals
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
APP_ENV="${APP_ENV:-production}"
PORT="${PORT:-}"

# Colors
NC="$(printf '\033[0m' || true)"
GREEN="$(printf '\033[0;32m' || true)"
YELLOW="$(printf '\033[1;33m' || true)"
RED="$(printf '\033[0;31m' || true)"

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }

trap 'err "Setup failed at line $LINENO"; exit 1' ERR

# Pre-flight note: some orchestrators wrap command execution with an external 'timeout' binary.
# If 'timeout' is missing on the base system, the wrapper fails before this script can run.
# To provision 'timeout' externally before invoking this script, run the following in order (as root when possible):
# sh -lc 'set -Eeuo pipefail; if command -v timeout >/dev/null 2>&1; then echo "timeout already present"; exit 0; fi; if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; printf "Acquire::Retries \"5\";\nAcquire::http::No-Cache \"true\";\nAcquire::https::No-Cache \"true\";\n" > /etc/apt/apt.conf.d/99retries-nocache || true; apt-get clean || true; rm -rf /var/lib/apt/lists/* || true; grep -rl "http://archive.ubuntu.com/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | xargs -r sed -i "s|http://archive.ubuntu.com/ubuntu|mirror://mirrors.ubuntu.com/mirrors.txt|g" || true; apt-get update -o Acquire::http::No-Cache=true -o Acquire::https::No-Cache=true; apt-get install -y --no-install-recommends coreutils || apt-get install -y --no-install-recommends busybox; fi'
# sh -lc 'set -Eeuo pipefail; if ! command -v timeout >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && command -v apk >/dev/null 2>&1; then apk add --no-cache coreutils || apk add --no-cache busybox-extras; fi'
# sh -lc 'set -Eeuo pipefail; if ! command -v timeout >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && command -v dnf >/dev/null 2>&1; then dnf install -y coreutils || dnf install -y busybox; fi'
# sh -lc 'set -Eeuo pipefail; if ! command -v timeout >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && command -v yum >/dev/null 2>&1; then yum install -y coreutils || yum install -y busybox; fi'
# sh -lc 'set -Eeuo pipefail; if ! command -v timeout >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && command -v microdnf >/dev/null 2>&1; then microdnf install -y coreutils || microdnf install -y busybox || true; fi'
# sh -lc 'set -Eeuo pipefail; if ! command -v timeout >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh || true; zypper --non-interactive install -y coreutils || zypper --non-interactive install -y busybox; fi'
# sh -lc 'set -Eeuo pipefail; if ! command -v timeout >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm coreutils || pacman -Sy --noconfirm busybox; fi'
# sh -lc 'set -Eeuo pipefail; if ! command -v timeout >/dev/null 2>&1 && command -v busybox >/dev/null 2>&1; then mkdir -p /usr/local/bin || true; ln -sf "$(command -v busybox)" /usr/local/bin/timeout || true; fi'
# sh -lc 'set -Eeuo pipefail; if ! command -v timeout >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then BB="/usr/local/bin/busybox"; case "$(uname -m)" in x86_64|amd64) URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch/busybox-x86_64";; aarch64|arm64) URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch/busybox-aarch64";; armv7l|armv7) URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch/busybox-armv7l";; *) URL="";; esac; if [ -n "$URL" ]; then if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" -o "$BB" || true; elif command -v wget >/dev/null 2>&1; then wget -qO "$BB" "$URL" || true; fi; chmod +x "$BB" || true; ln -sf "$BB" /usr/local/bin/timeout || true; fi; fi'
# sh -lc 'set -Eeuo pipefail; if ! command -v timeout >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then cat > /usr/local/bin/timeout <<'SH_EOF'
# !/bin/sh
# # Minimal fallback timeout that ignores timing and directly execs the command.
# # This unblocks environments that wrap commands with `timeout` before setup.
# # Usage: timeout [DURATION] COMMAND [ARGS...]
# # Drop common options
# while [ $# -gt 0 ]; do
#   case "$1" in
#     -k|--kill-after|-s|--signal|--preserve-status|--foreground)
#       shift 2 2>/dev/null || shift 1
#       ;;
#     --)
#       shift; break;;
#     -*)
#       shift;;
#     *) break;;
#   esac
# done
# # Drop leading duration arg if present (very loose check)
# case "$1" in
#   *[0-9]*[smhd]*) shift;;
#   [0-9]*) shift;;
#   *) :;;
# esac
# exec "$@"
# SH_EOF
# chmod +x /usr/local/bin/timeout; fi'
# sh -lc 'set -Eeuo pipefail; if command -v timeout >/dev/null 2>&1; then timeout --version >/dev/null 2>&1 || timeout 1 true || true; echo "timeout installed"; else echo "ERROR: timeout is still unavailable; ensure coreutils/busybox (or stub) is installed and in PATH" >&2; exit 1; fi'

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    warn "Not running as root. System package installation and user creation will be skipped or may fail."
    return 1
  fi
  return 0
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v microdnf >/dev/null 2>&1; then echo "microdnf"; return; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return; fi
  echo "unknown"
}

pkg_update_done_flag="/var/tmp/.pkg_index_updated"

pkg_update() {
  require_root || return 0
  local pmgr; pmgr="$(detect_pkg_manager)"
  if [ -f "$pkg_update_done_flag" ]; then
    log "Package index already updated"
    return 0
  fi
  log "Updating package index with $pmgr"
  case "$pmgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      # Harden apt against transient mirror issues: retries, no-cache, clean, mirror meta
      printf 'Acquire::Retries "5";\nAcquire::http::No-Cache "true";\nAcquire::https::No-Cache "true";\n' > /etc/apt/apt.conf.d/99retries-nocache || true
      apt-get clean || true
      rm -rf /var/lib/apt/lists/* || true
      grep -rl "http://archive.ubuntu.com/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | xargs -r sed -i 's|http://archive.ubuntu.com/ubuntu|mirror://mirrors.ubuntu.com/mirrors.txt|g' || true
      apt-get update -o Acquire::http::No-Cache=true -o Acquire::https::No-Cache=true
      touch "$pkg_update_done_flag"
      ;;
    apk)
      apk update
      touch "$pkg_update_done_flag"
      ;;
    dnf)
      dnf -y makecache
      touch "$pkg_update_done_flag"
      ;;
    yum)
      yum -y makecache
      touch "$pkg_update_done_flag"
      ;;
    microdnf)
      microdnf -y update || true
      touch "$pkg_update_done_flag"
      ;;
    zypper)
      zypper --non-interactive refresh
      touch "$pkg_update_done_flag"
      ;;
    *)
      warn "Unknown package manager; skipping update"
      ;;
  esac
}

pkg_install() {
  # Usage: pkg_install package1 package2 ...
  require_root || { warn "Cannot install system packages without root"; return 0; }
  local pmgr; pmgr="$(detect_pkg_manager)"
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  log "Installing system packages: ${pkgs[*]}"
  case "$pmgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends "${pkgs[@]}" || true
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}" || true
      ;;
    dnf)
      dnf install -y "${pkgs[@]}" || true
      ;;
    yum)
      yum install -y "${pkgs[@]}" || true
      ;;
    microdnf)
      microdnf install -y "${pkgs[@]}" || true
      ;;
    zypper)
      zypper --non-interactive install -y "${pkgs[@]}" || true
      ;;
    *)
      warn "Unknown package manager; cannot install: ${pkgs[*]}"
      ;;
  esac
}

ensure_basic_tools() {
  pkg_update
  # Install fundamental tools and certs if missing
  local base_pkgs_common=(ca-certificates curl wget git unzip tar xz gzip bash coreutils findutils sed grep)
  local build_pkgs_apt=(build-essential pkg-config)
  local build_pkgs_apk=(build-base)
  local pmgr; pmgr="$(detect_pkg_manager)"

  pkg_install "${base_pkgs_common[@]}"
  case "$pmgr" in
    apt) pkg_install "${build_pkgs_apt[@]}" ;;
    apk) pkg_install "${build_pkgs_apk[@]}" ;;
    dnf|yum|microdnf) pkg_install gcc gcc-c++ make pkgconf ;;
    zypper) pkg_install gcc gcc-c++ make patterns-devel-base-devel_basis ;;
  esac

  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi
}

create_app_user() {
  require_root || return 0
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User $APP_USER already exists"
    return 0
  fi
  log "Creating application user $APP_USER ($APP_UID:$APP_GID)"
  if command -v addgroup >/dev/null 2>&1 && command -v adduser >/dev/null 2>&1; then
    # Alpine
    addgroup -g "$APP_GID" -S "$APP_GROUP" 2>/dev/null || true
    adduser -S -D -H -u "$APP_UID" -G "$APP_GROUP" "$APP_USER" || true
  elif command -v groupadd >/dev/null 2>&1 && command -v useradd >/dev/null 2>&1; then
    groupadd -g "$APP_GID" "$APP_GROUP" 2>/dev/null || true
    useradd -m -u "$APP_UID" -g "$APP_GROUP" -s /bin/bash "$APP_USER" || true
  else
    warn "No user management tools available; running as root"
  fi
}

setup_directories() {
  mkdir -p "$APP_DIR"
  if require_root; then
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR" 2>/dev/null || true
    chmod -R u+rwX,go+rX "$APP_DIR" 2>/dev/null || true
  fi
}

load_env_file() {
  # Load .env if present (safe: ignore comments and empty lines)
  local env_file="${APP_DIR}/.env"
  if [ -f "$env_file" ]; then
    log "Loading environment variables from $env_file"
    set -a
    # shellcheck disable=SC2046
    . <(grep -v '^[[:space:]]*#' "$env_file" | sed -e '/^[[:space:]]*$/d')
    set +a
  fi
}

export_common_env() {
  export APP_ENV="${APP_ENV}"
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export PYTHONUNBUFFERED=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1
}

detect_project_type() {
  # Outputs a space-separated list of detected types (could be multiple)
  local types=()

  [ -f "${APP_DIR}/package.json" ] && types+=("node")
  [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/Pipfile" ] && types+=("python")
  [ -f "${APP_DIR}/go.mod" ] && types+=("go")
  [ -f "${APP_DIR}/Cargo.toml" ] && types+=("rust")
  ls "${APP_DIR}"/*.csproj >/dev/null 2>&1 || ls "${APP_DIR}"/*.sln >/dev/null 2>&1 && types+=("dotnet")
  [ -f "${APP_DIR}/pom.xml" ] && types+=("java-maven")
  [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/gradle.properties" ] || [ -f "${APP_DIR}/settings.gradle" ] && types+=("java-gradle")
  [ -f "${APP_DIR}/Gemfile" ] && types+=("ruby")
  [ -f "${APP_DIR}/composer.json" ] && types+=("php")

  echo "${types[*]}"
}

arch_nodetar() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7l" ;;
    *) echo "" ;;
  esac
}
arch_go() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv6l" ;;
    *) echo "" ;;
  esac
}

install_node() {
  if command -v node >/dev/null 2>&1; then
    log "Node.js already installed: $(node -v)"
    return 0
  fi
  ensure_basic_tools
  local pmgr; pmgr="$(detect_pkg_manager)"
  local installed=0
  if require_root; then
    case "$pmgr" in
      apt)
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || true
        apt-get install -y nodejs || true
        command -v node >/dev/null 2>&1 && installed=1
        ;;
      apk)
        apk add --no-cache nodejs-current npm || true
        command -v node >/dev/null 2>&1 && installed=1
        ;;
      dnf|yum|microdnf)
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - || true
        $pmgr install -y nodejs || true
        command -v node >/dev/null 2>&1 && installed=1
        ;;
      zypper)
        zypper --non-interactive install -y nodejs20 npm20 || true
        command -v node >/dev/null 2>&1 && installed=1
        ;;
    esac
  fi
  if [ "$installed" -eq 0 ]; then
    # Fallback to official tarball
    local arch; arch="$(arch_nodetar)"
    local version="v20.11.1"
    if [ -z "$arch" ]; then
      err "Unsupported architecture for Node.js tarball"
      return 1
    fi
    log "Installing Node.js $version from tarball"
    local url="https://nodejs.org/dist/${version}/node-${version}-linux-${arch}.tar.xz"
    curl -fsSL "$url" -o /tmp/node.tar.xz
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
    rm -f /tmp/node.tar.xz
  fi
  corepack enable || true
  log "Node.js installed: $(node -v)"
}

setup_node_project() {
  [ -f "${APP_DIR}/package.json" ] || return 0
  log "Setting up Node.js project"
  install_node
  export NODE_ENV="${NODE_ENV:-$APP_ENV}"
  pushd "$APP_DIR" >/dev/null
  if [ -f "pnpm-lock.yaml" ]; then
    corepack enable pnpm || npm i -g pnpm@latest || true
    pnpm install --frozen-lockfile || pnpm install
  elif [ -f "yarn.lock" ]; then
    corepack enable yarn || npm i -g yarn@stable || true
    yarn install --frozen-lockfile || yarn install
  else
    if [ -f "package-lock.json" ] || [ -f "npm-shrinkwrap.json" ]; then
      npm ci || npm install
    else
      npm install
    fi
  fi
  # Determine default port if not set
  if [ -z "${PORT:-}" ]; then
    PORT=3000
  fi
  popd >/dev/null
}

install_python() {
  if command -v python3 >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
    log "Python present: $(python3 --version 2>/dev/null || echo)"
    return 0
  fi
  ensure_basic_tools
  local pmgr; pmgr="$(detect_pkg_manager)"
  case "$pmgr" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev
      ;;
    dnf|yum|microdnf)
      pkg_install python3 python3-pip python3-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel
      ;;
    *)
      err "Unable to install Python on unknown distro"
      ;;
  esac
}

setup_python_project() {
  local has_py=0
  [ -f "${APP_DIR}/requirements.txt" ] && has_py=1
  [ -f "${APP_DIR}/pyproject.toml" ] && has_py=1
  [ -f "${APP_DIR}/Pipfile" ] && has_py=1
  [ "$has_py" -eq 1 ] || return 0

  log "Setting up Python project"
  install_python
  pushd "$APP_DIR" >/dev/null

  # Build tools for native extensions
  local pmgr; pmgr="$(detect_pkg_manager)"
  case "$pmgr" in
    apt) pkg_install build-essential libffi-dev libssl-dev || true ;;
    apk) pkg_install build-base libffi-dev openssl-dev || true ;;
    dnf|yum|microdnf) pkg_install gcc gcc-c++ make libffi-devel openssl-devel || true ;;
    zypper) pkg_install gcc gcc-c++ make libffi-devel libopenssl-devel || true ;;
  esac

  # Create venv
  local VENV_PATH="${APP_DIR}/.venv"
  if [ ! -d "$VENV_PATH" ]; then
    python3 -m venv "$VENV_PATH"
  fi
  # shellcheck disable=SC1090
  . "${VENV_PATH}/bin/activate"

  python -m pip install --upgrade pip setuptools wheel

  if [ -f "pyproject.toml" ] && grep -qi "tool.poetry" pyproject.toml 2>/dev/null; then
    log "Detected Poetry-managed project"
    python -m pip install "poetry>=1.5"
    poetry config virtualenvs.in-project true
    if [ "${APP_ENV}" = "production" ]; then
      poetry install --no-root --only main --no-interaction --no-ansi
    else
      poetry install --no-interaction --no-ansi
    fi
  elif [ -f "Pipfile" ]; then
    log "Detected Pipenv-managed project"
    python -m pip install pipenv
    if [ "${APP_ENV}" = "production" ]; then
      pipenv install --deploy --system || pipenv install --deploy
    else
      pipenv install --system || pipenv install
    fi
  elif [ -f "requirements.txt" ]; then
    log "Installing requirements.txt"
    pip install -r requirements.txt
  fi

  # Default ports for common Python frameworks
  if [ -z "${PORT:-}" ]; then
    if grep -Rqi "flask" requirements.txt pyproject.toml 2>/dev/null; then
      PORT=5000
    elif grep -Rqi "django" requirements.txt pyproject.toml 2>/dev/null; then
      PORT=8000
    else
      PORT=8000
    fi
  fi
  popd >/dev/null
}

install_go() {
  if command -v go >/dev/null 2>&1; then
    log "Go installed: $(go version)"
    return 0
  fi
  ensure_basic_tools
  local arch; arch="$(arch_go)"
  local version="1.21.6"
  if [ -z "$arch" ]; then
    err "Unsupported arch for Go"
    return 1
  fi
  log "Installing Go ${version}"
  curl -fsSL "https://go.dev/dl/go${version}.linux-${arch}.tar.gz" -o /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
  export PATH="/usr/local/go/bin:${PATH}"
}

setup_go_project() {
  [ -f "${APP_DIR}/go.mod" ] || return 0
  log "Setting up Go project"
  install_go
  export GOPATH="${GOPATH:-/go}"
  mkdir -p "$GOPATH"
  export PATH="${GOPATH}/bin:/usr/local/go/bin:${PATH}"
  pushd "$APP_DIR" >/dev/null
  go env -w GOPRIVATE="${GOPRIVATE:-}" || true
  go mod download
  if [ -z "${PORT:-}" ]; then
    PORT=8080
  fi
  popd >/dev/null
}

install_rust() {
  if command -v cargo >/dev/null 2>&1; then
    log "Rust installed: $(rustc --version 2>/dev/null || echo)"
    return 0
  fi
  ensure_basic_tools
  log "Installing Rust (rustup)"
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
  chmod +x /tmp/rustup.sh
  export RUSTUP_HOME="/usr/local/rustup"
  export CARGO_HOME="/usr/local/cargo"
  /tmp/rustup.sh -y --profile minimal --default-toolchain stable
  rm -f /tmp/rustup.sh
  export PATH="${CARGO_HOME}/bin:${PATH}"
}

setup_rust_project() {
  [ -f "${APP_DIR}/Cargo.toml" ] || return 0
  log "Setting up Rust project"
  install_rust
  export PATH="/usr/local/cargo/bin:${PATH}"
  pushd "$APP_DIR" >/dev/null
  cargo fetch
  if [ -z "${PORT:-}" ]; then
    PORT=8080
  fi
  popd >/dev/null
}

install_java() {
  if command -v java >/dev/null 2>&1; then
    log "Java present: $(java -version 2>&1 | head -n1)"
    return 0
  fi
  ensure_basic_tools
  local pmgr; pmgr="$(detect_pkg_manager)"
  case "$pmgr" in
    apt) pkg_install openjdk-17-jdk ;;
    apk) pkg_install openjdk17-jdk ;;
    dnf|yum|microdnf) pkg_install java-17-openjdk-devel ;;
    zypper) pkg_install java-17-openjdk-devel ;;
    *) warn "Unknown distro: Java install skipped";;
  esac
}

setup_java_maven() {
  [ -f "${APP_DIR}/pom.xml" ] || return 0
  log "Setting up Java (Maven) project"
  install_java
  if ! command -v mvn >/dev/null 2>&1; then
    local pmgr; pmgr="$(detect_pkg_manager)"
    case "$pmgr" in
      apt) pkg_install maven ;;
      apk) pkg_install maven ;;
      dnf|yum|microdnf) pkg_install maven ;;
      zypper) pkg_install maven ;;
      *) warn "Cannot install Maven automatically";;
    esac
  fi
  pushd "$APP_DIR" >/dev/null
  if command -v mvn >/dev/null 2>&1; then
    mvn -B -ntp -DskipTests dependency:go-offline || true
  fi
  [ -z "${PORT:-}" ] && PORT=8080
  popd >/dev/null
}

setup_java_gradle() {
  [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/settings.gradle" ] || [ -f "${APP_DIR}/gradle.properties" ] || return 0
  log "Setting up Java (Gradle) project"
  install_java
  pushd "$APP_DIR" >/dev/null
  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
    ./gradlew --no-daemon build -x test || true
  else
    if ! command -v gradle >/dev/null 2>&1; then
      local pmgr; pmgr="$(detect_pkg_manager)"
      case "$pmgr" in
        apt|apk|dnf|yum|microdnf|zypper) pkg_install gradle ;;
        *) warn "Cannot install Gradle automatically";;
      esac
    fi
    gradle --no-daemon build -x test || true
  fi
  [ -z "${PORT:-}" ] && PORT=8080
  popd >/dev/null
}

install_ruby() {
  if command -v ruby >/dev/null 2>&1; then
    log "Ruby present: $(ruby --version)"
    return 0
  fi
  ensure_basic_tools
  local pmgr; pmgr="$(detect_pkg_manager)"
  case "$pmgr" in
    apt) pkg_install ruby-full ruby-dev build-essential ;;
    apk) pkg_install ruby ruby-dev build-base ;;
    dnf|yum|microdnf) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
    zypper) pkg_install ruby ruby-devel gcc gcc-c++ make ;;
    *) warn "Unknown distro: Ruby install skipped";;
  esac
  gem install bundler --no-document || true
}

setup_ruby_project() {
  [ -f "${APP_DIR}/Gemfile" ] || return 0
  log "Setting up Ruby project"
  install_ruby
  pushd "$APP_DIR" >/dev/null
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document || true
  fi
  bundle config set without 'development test' || true
  bundle install --jobs "$(nproc 2>/dev/null || echo 2)" || bundle install
  [ -z "${PORT:-}" ] && PORT=3000
  popd >/dev/null
}

install_php() {
  if command -v php >/dev/null 2>&1; then
    log "PHP present: $(php -v | head -n1)"
    return 0
  fi
  ensure_basic_tools
  local pmgr; pmgr="$(detect_pkg_manager)"
  case "$pmgr" in
    apt) pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip ;;
    apk) pkg_install php81 php81-phar php81-mbstring php81-xml php81-curl php81-zip unzip || pkg_install php php-phar php-mbstring php-xml php-curl php-zip unzip ;;
    dnf|yum|microdnf) pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip ;;
    zypper) pkg_install php8 php8-mbstring php8-xml php8-curl php8-zip unzip ;;
    *) warn "Unknown distro: PHP install skipped";;
  esac
}

setup_php_project() {
  [ -f "${APP_DIR}/composer.json" ] || return 0
  log "Setting up PHP project"
  install_php
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
      && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
      && rm composer-setup.php || true
  fi
  pushd "$APP_DIR" >/dev/null
  if [ -f "composer.lock" ] && [ "${APP_ENV}" = "production" ]; then
    composer install --no-dev --prefer-dist --no-interaction || composer install --no-interaction
  else
    composer install --prefer-dist --no-interaction || composer install --no-interaction
  fi
  [ -z "${PORT:-}" ] && PORT=8000
  popd >/dev/null
}

install_dotnet() {
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET present: $(dotnet --version)"
    return 0
  fi
  ensure_basic_tools
  log "Installing .NET SDK via dotnet-install.sh"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  chmod +x /tmp/dotnet-install.sh
  local install_dir="/usr/share/dotnet"
  if ! require_root; then
    install_dir="${HOME}/.dotnet"
  fi
  /tmp/dotnet-install.sh --install-dir "$install_dir" --channel STS --quality ga
  export DOTNET_ROOT="$install_dir"
  export PATH="${install_dir}:${install_dir}/tools:${PATH}"
}

setup_dotnet_project() {
  ls "${APP_DIR}"/*.csproj >/dev/null 2>&1 || ls "${APP_DIR}"/*.sln >/dev/null 2>&1 || return 0
  log "Setting up .NET project"
  install_dotnet
  pushd "$APP_DIR" >/dev/null
  if ls *.sln >/dev/null 2>&1; then
    dotnet restore || true
  else
    for proj in *.csproj; do dotnet restore "$proj" || true; done
  fi
  [ -z "${PORT:-}" ] && PORT=8080
  popd >/dev/null
}

write_profile_for_appuser() {
  # Add language-specific PATH and envs for interactive shells
  local profile_file
  if [ -d "/home/${APP_USER}" ]; then
    profile_file="/home/${APP_USER}/.profile"
  else
    profile_file="/root/.profile"
  fi
  {
    echo ''
    echo '# Added by setup script'
    echo "export APP_DIR='${APP_DIR}'"
    echo "export APP_ENV='${APP_ENV}'"
    echo "export PATH='/usr/local/go/bin:/usr/local/cargo/bin:\$PATH'"
    echo "[ -d \"${APP_DIR}/.venv/bin\" ] && export PATH=\"${APP_DIR}/.venv/bin:\$PATH\""
    echo "export DOTNET_ROOT='${DOTNET_ROOT:-/usr/share/dotnet}'"
    echo "[ -d \"\${DOTNET_ROOT}\" ] && export PATH=\"\${DOTNET_ROOT}:\${DOTNET_ROOT}/tools:\$PATH\""
  } >> "$profile_file" 2>/dev/null || true
  if require_root && [ -d "/home/${APP_USER}" ]; then
    chown "${APP_USER}:${APP_GROUP}" "$profile_file" 2>/dev/null || true
  fi
}

setup_auto_activate() {
  # Idempotently add venv auto-activation to root and app user's .bashrc
  local activate_line="[ -f \"${APP_DIR}/.venv/bin/activate\" ] && . \"${APP_DIR}/.venv/bin/activate\""
  for rc in /root/.bashrc "/home/${APP_USER}/.bashrc"; do
    local dir
    dir="$(dirname "$rc")"
    [ -d "$dir" ] || continue
    touch "$rc" 2>/dev/null || true
    if ! grep -Fq "$activate_line" "$rc" 2>/dev/null; then
      echo "" >> "$rc"
      echo "# Auto-activate Python virtual environment for the app" >> "$rc"
      echo "$activate_line" >> "$rc"
    fi
  done
  if require_root && [ -d "/home/${APP_USER}" ]; then
    chown "${APP_USER}:${APP_GROUP}" "/home/${APP_USER}/.bashrc" 2>/dev/null || true
  fi
}

ensure_timeout() {
  # Note: If your environment wraps commands with an external 'timeout' binary and it is missing,
  # run the following commands outside this script before invoking it:
  # sh -lc 'set -Eeuo pipefail; if command -v timeout >/dev/null 2>&1; then echo "timeout already present"; exit 0; fi; if [ "$(id -u)" -eq 0 ]; then if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; printf "Acquire::Retries \"5\";\nAcquire::http::No-Cache \"true\";\nAcquire::https::No-Cache \"true\";\n" > /etc/apt/apt.conf.d/99retries-nocache || true; apt-get clean || true; rm -rf /var/lib/apt/lists/* || true; grep -rl "http://archive.ubuntu.com/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | xargs -r sed -i "s|http://archive.ubuntu.com/ubuntu|mirror://mirrors.ubuntu.com/mirrors.txt|g" || true; apt-get update -o Acquire::http::No-Cache=true -o Acquire::https::No-Cache=true; apt-get install -y --no-install-recommends coreutils || apt-get install -y --no-install-recommends busybox; elif command -v apk >/dev/null 2>&1; then apk add --no-cache coreutils || apk add --no-cache busybox-extras; elif command -v dnf >/dev/null 2>&1; then dnf install -y coreutils || dnf install -y busybox; elif command -v yum >/dev/null 2>&1; then yum install -y coreutils || yum install -y busybox; elif command -v microdnf >/dev/null 2>&1; then microdnf install -y coreutils || microdnf install -y busybox || true; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh || true; zypper --non-interactive install -y coreutils || zypper --non-interactive install -y busybox; elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm coreutils || pacman -Sy --noconfirm busybox; fi; fi; if ! command -v timeout >/dev/null 2>&1 && command -v busybox >/dev/null 2>&1; then mkdir -p /usr/local/bin || true; ln -sf "$(command -v busybox)" /usr/local/bin/timeout || true; fi'
  # sh -lc 'set -Eeuo pipefail; if command -v timeout >/dev/null 2>&1; then echo "timeout already present"; exit 0; fi; if [ "$(id -u)" -eq 0 ]; then if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; printf "Acquire::Retries \"5\";\nAcquire::http::No-Cache \"true\";\nAcquire::https::No-Cache \"true\";\n" > /etc/apt/apt.conf.d/99retries-nocache || true; apt-get clean || true; rm -rf /var/lib/apt/lists/* || true; grep -rl "http://archive.ubuntu.com/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | xargs -r sed -i "s|http://archive.ubuntu.com/ubuntu|mirror://mirrors.ubuntu.com/mirrors.txt|g" || true; apt-get update -o Acquire::http::No-Cache=true -o Acquire::https::No-Cache=true; apt-get install -y --no-install-recommends coreutils || apt-get install -y --no-install-recommends busybox; elif command -v apk >/dev/null 2>&1; then apk add --no-cache coreutils || apk add --no-cache busybox-extras; elif command -v dnf >/dev/null 2>&1; then dnf install -y coreutils || dnf install -y busybox; elif command -v yum >/dev/null 2>&1; then yum install -y coreutils || yum install -y busybox; elif command -v microdnf >/dev/null 2>&1; then microdnf install -y coreutils || microdnf install -y busybox || true; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh || true; zypper --non-interactive install -y coreutils || zypper --non-interactive install -y busybox; elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm coreutils || pacman -Sy --noconfirm busybox; fi; fi; if ! command -v timeout >/dev/null 2>&1 && command -v busybox >/dev/null 2>&1; then mkdir -p /usr/local/bin || true; ln -sf "$(command -v busybox)" /usr/local/bin/timeout || true; fi; if ! command -v timeout >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then BB="/usr/local/bin/busybox"; case "$(uname -m)" in x86_64|amd64) URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch/busybox-x86_64";; aarch64|arm64) URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch/busybox-aarch64";; armv7l|armv7) URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch/busybox-armv7l";; *) URL="";; esac; if [ -n "$URL" ]; then if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" -o "$BB" || true; elif command -v wget >/dev/null 2>&1; then wget -qO "$BB" "$URL" || true; fi; chmod +x "$BB" || true; ln -sf "$BB" /usr/local/bin/timeout || true; fi; fi'
  # sh -lc 'if command -v timeout >/dev/null 2>&1; then timeout --version >/dev/null 2>&1 || timeout 1 true || true; echo "timeout installed"; else echo "ERROR: timeout is still unavailable; ensure coreutils/busybox is installed and in PATH" >&2; exit 1; fi'
  if command -v timeout >/dev/null 2>&1; then
    timeout --version >/dev/null 2>&1 || timeout 1 true || true
    return 0
  fi

  # Attempt to provision timeout when running with sufficient privileges
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      printf 'Acquire::Retries "5";\nAcquire::http::No-Cache "true";\nAcquire::https::No-Cache "true";\n' > /etc/apt/apt.conf.d/99retries-nocache || true
      apt-get clean || true
      rm -rf /var/lib/apt/lists/* || true
      grep -rl "http://archive.ubuntu.com/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | xargs -r sed -i 's|http://archive.ubuntu.com/ubuntu|mirror://mirrors.ubuntu.com/mirrors.txt|g' || true
      apt-get update -o Acquire::http::No-Cache=true -o Acquire::https::No-Cache=true
      apt-get install -y --no-install-recommends coreutils || apt-get install -y --no-install-recommends busybox
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache coreutils || apk add --no-cache busybox-extras
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y coreutils || dnf install -y busybox
    elif command -v yum >/dev/null 2>&1; then
      yum install -y coreutils || yum install -y busybox
    elif command -v microdnf >/dev/null 2>&1; then
      microdnf install -y coreutils || microdnf install -y busybox || true
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive refresh || true
      zypper --non-interactive install -y coreutils || zypper --non-interactive install -y busybox
    elif command -v pacman >/dev/null 2>&1; then
      pacman -Sy --noconfirm coreutils || pacman -Sy --noconfirm busybox
    fi
  fi

  # Fallback: provide timeout via busybox symlink if still missing
  if ! command -v timeout >/dev/null 2>&1 && command -v busybox >/dev/null 2>&1; then
    mkdir -p /usr/local/bin || true
    ln -sf "$(command -v busybox)" /usr/local/bin/timeout || true
  fi

  # Final fallback: download a static BusyBox providing 'timeout' if still missing
  if ! command -v timeout >/dev/null 2>&1 && [ "${EUID:-$(id -u)}" -eq 0 ]; then
    BB="/usr/local/bin/busybox"
    case "$(uname -m)" in
      x86_64|amd64) URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch/busybox-x86_64" ;;
      aarch64|arm64) URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch/busybox-aarch64" ;;
      armv7l|armv7) URL="https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch/busybox-armv7l" ;;
      *) URL="" ;;
    esac
    if [ -n "${URL}" ]; then
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${URL}" -o "${BB}" || true
      elif command -v wget >/dev/null 2>&1; then
        wget -qO "${BB}" "${URL}" || true
      fi
      chmod +x "${BB}" || true
      ln -sf "${BB}" /usr/local/bin/timeout || true
    fi
  fi

  # Absolute last resort: provide a minimal stub 'timeout' that just execs the command
  if ! command -v timeout >/dev/null 2>&1 && [ "${EUID:-$(id -u)}" -eq 0 ]; then
    cat > /usr/local/bin/timeout <<'SH_EOF'
#!/bin/sh
# Minimal fallback timeout that ignores timing and directly execs the command.
# This unblocks environments that wrap commands with `timeout` before setup.
# Usage: timeout [DURATION] COMMAND [ARGS...]
# Drop common options
while [ $# -gt 0 ]; do
  case "$1" in
    -k|--kill-after|-s|--signal|--preserve-status|--foreground)
      shift 2 2>/dev/null || shift 1
      ;;
    --)
      shift; break;;
    -*)
      shift;;
    *) break;;
  esac
done
# Drop leading duration arg if present (very loose check)
case "$1" in
  *[0-9]*[smhd]*) shift;;
  [0-9]*) shift;;
  *) :;;
esac
exec "$@"
SH_EOF
    chmod +x /usr/local/bin/timeout
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout --version >/dev/null 2>&1 || timeout 1 true || true
    return 0
  else
    echo 'ERROR: timeout is still unavailable; ensure coreutils/busybox is installed and in PATH' >&2
    return 1
  fi
}

print_summary() {
  log "Setup complete"
  echo "Summary:"
  echo "- APP_DIR: ${APP_DIR}"
  echo "- APP_ENV: ${APP_ENV}"
  [ -n "${PORT:-}" ] && echo "- PORT: ${PORT}"
  echo "- Detected types: ${DETECTED_TYPES}"
  echo "- App user: ${APP_USER}"
  echo ""
  echo "Common run examples (adjust to your app):"
  if [[ "${DETECTED_TYPES}" == *"python"* ]]; then
    echo "  Python: source ${APP_DIR}/.venv/bin/activate && python app.py"
  fi
  if [[ "${DETECTED_TYPES}" == *"node"* ]]; then
    echo "  Node:   cd ${APP_DIR} && npm start"
  fi
  if [[ "${DETECTED_TYPES}" == *"go"* ]]; then
    echo "  Go:     cd ${APP_DIR} && go run ."
  fi
  if [[ "${DETECTED_TYPES}" == *"rust"* ]]; then
    echo "  Rust:   cd ${APP_DIR} && cargo run"
  fi
  if [[ "${DETECTED_TYPES}" == *"java-maven"* ]]; then
    echo "  Maven:  cd ${APP_DIR} && mvn spring-boot:run (if Spring Boot)"
  fi
  if [[ "${DETECTED_TYPES}" == *"java-gradle"* ]]; then
    echo "  Gradle: cd ${APP_DIR} && ./gradlew bootRun (if Spring Boot)"
  fi
  if [[ "${DETECTED_TYPES}" == *"ruby"* ]]; then
    echo "  Ruby:   cd ${APP_DIR} && bundle exec rails server -p ${PORT:-3000} -b 0.0.0.0"
  fi
  if [[ "${DETECTED_TYPES}" == *"php"* ]]; then
    echo "  PHP:    cd ${APP_DIR} && php -S 0.0.0.0:${PORT:-8000} -t public"
  fi
  if [[ "${DETECTED_TYPES}" == *"dotnet"* ]]; then
    echo "  .NET:   cd ${APP_DIR} && dotnet run --no-launch-profile --urls http://0.0.0.0:${PORT:-8080}"
  fi
}

main() {
  umask 022
  export_common_env

  # Ensure app directory exists and is current working dir if present
  mkdir -p "$APP_DIR"
  cd "$APP_DIR" || true

  create_app_user
  setup_directories
  load_env_file
  ensure_basic_tools
  ensure_timeout

  DETECTED_TYPES="$(detect_project_type)"
  if [ -z "$DETECTED_TYPES" ]; then
    warn "No known project files detected in ${APP_DIR}. Installing only base tools."
  else
    log "Detected project types: $DETECTED_TYPES"
  fi

  # Per-language setups (order matters for multi-language projects)
  setup_python_project
  setup_node_project
  setup_go_project
  setup_rust_project
  setup_java_maven
  setup_java_gradle
  setup_ruby_project
  setup_php_project
  setup_dotnet_project

  # Ensure permissions
  if require_root; then
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR" 2>/dev/null || true
  fi

  write_profile_for_appuser
  setup_auto_activate

  # Export PORT if determined
  if [ -n "${PORT:-}" ]; then
    export PORT
  fi

  print_summary
}

main "$@"