#!/usr/bin/env bash
# Environment setup script for containerized projects
# This script detects the project's tech stack and installs required runtimes,
# system dependencies, and configures the environment accordingly.

set -Eeuo pipefail
IFS=$'\n\t'

#========================
# Global defaults
#========================
APP_DIR="${APP_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
TZ="${TZ:-UTC}"
LANG="${LANG:-C.UTF-8}"
LC_ALL="${LC_ALL:-C.UTF-8}"
DEBIAN_FRONTEND=noninteractive
STAMP_DIR="/var/lib/.setup-stamps"
ENV_PROFILE_DIR="/etc/profile.d"
ENV_PROFILE_FILE="${ENV_PROFILE_DIR}/app_env.sh"

#========================
# Logging utilities
#========================
log()   { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '[%s] [WARN] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { printf '[%s] [ERROR] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

cleanup() { :
  # Placeholder for future cleanup hooks
}

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]}
  error "Script failed at line ${line_no} with exit code ${exit_code}"
  exit "${exit_code}"
}
trap cleanup EXIT
trap on_error ERR

#========================
# Helpers
#========================
ensure_dir() { mkdir -p "$1"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }

detect_project_dir() {
  # Prefer current directory if it looks like a project; otherwise use /app
  local cwd="$PWD"
  local indicators=("package.json" "requirements.txt" "pyproject.toml" "Pipfile" "go.mod" "Cargo.toml" "pom.xml" "build.gradle" "build.gradle.kts" "Gemfile" "composer.json" "*.csproj" "global.json")
  for f in "${indicators[@]}"; do
    if compgen -G "${cwd}/${f}" >/dev/null 2>&1; then
      APP_DIR="$cwd"
      return
    fi
  done
  APP_DIR="${APP_DIR:-/app}"
}

#========================
# Package manager detection and wrappers
#========================
PM=""
pm_detect() {
  if need_cmd apt-get; then PM="apt"; return 0; fi
  if need_cmd apk; then PM="apk"; return 0; fi
  if need_cmd dnf; then PM="dnf"; return 0; fi
  if need_cmd yum; then PM="yum"; return 0; fi
  if need_cmd zypper; then PM="zypper"; return 0; fi
  if need_cmd pacman; then PM="pacman"; return 0; fi
  return 1
}

pm_update() {
  ensure_dir "$STAMP_DIR"
  local stamp="${STAMP_DIR}/pm-updated"
  if [[ -f "$stamp" ]]; then return 0; fi
  log "Updating package manager indexes..."
  case "$PM" in
    apt) apt-get update -y ;;
    apk) apk update ;;
    dnf) dnf makecache -y ;;
    yum) yum makecache -y ;;
    zypper) zypper refresh ;;
    pacman) pacman -Sy --noconfirm ;;
    *) error "Unsupported package manager"; exit 1 ;;
  esac
  touch "$stamp"
}

pm_install() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  log "Installing packages: ${pkgs[*]}"
  case "$PM" in
    apt)
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
    zypper)
      zypper install -y --no-recommends "${pkgs[@]}"
      ;;
    pacman)
      pacman -S --noconfirm --needed "${pkgs[@]}"
      ;;
    *)
      error "Unsupported package manager"
      exit 1
      ;;
  esac
}

pm_clean() {
  log "Cleaning package manager caches..."
  case "$PM" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*
      ;;
    apk)
      rm -rf /var/cache/apk/*
      ;;
    dnf)
      dnf clean all
      rm -rf /var/cache/dnf
      ;;
    yum)
      yum clean all
      rm -rf /var/cache/yum
      ;;
    zypper)
      zypper clean --all
      ;;
    pacman)
      yes | pacman -Scc || true
      ;;
  esac
}

install_base_tools() {
  pm_update
  case "$PM" in
    apt)
      # Ensure compatibility with removed legacy package apt-transport-https (Ubuntu 24.04+)
      if ! dpkg-query -W -f='${Status}' apt-transport-https 2>/dev/null | grep -q "installed"; then
        tmpdir="$(mktemp -d)"; mkdir -p "$tmpdir/DEBIAN"
        cat > "$tmpdir/DEBIAN/control" <<'EOF'
Package: apt-transport-https
Version: 1.0
Section: misc
Priority: optional
Architecture: all
Maintainer: Local <local@localhost>
Description: Dummy transitional package for apt HTTPS transport (builtin in apt >= 1.5)
 This empty package satisfies legacy dependencies that still request apt-transport-https.
EOF
        dpkg-deb --build "$tmpdir" /tmp/apt-transport-https_1.0_all.deb
        dpkg -i /tmp/apt-transport-https_1.0_all.deb || true
        rm -rf "$tmpdir"
      fi
      pm_install ca-certificates curl git wget tzdata locales gnupg dirmngr bash coreutils findutils grep sed gawk xz-utils unzip bzip2 tar gzip openssl
      ;;
    apk)
      pm_install ca-certificates curl git tzdata bash coreutils findutils grep sed gawk xz unzip bzip2 tar gzip openssl
      ;;
    dnf|yum)
      pm_install ca-certificates curl git wget tzdata gnupg2 bash coreutils findutils grep sed gawk xz unzip bzip2 tar gzip openssl
      ;;
    zypper)
      pm_install ca-certificates curl git wget timezone bash coreutils findutils grep sed gawk xz unzip bzip2 tar gzip libopenssl1_1 || pm_install openssl
      ;;
    pacman)
      pm_install ca-certificates curl git tzdata gnupg bash coreutils findutils grep sed gawk xz unzip bzip2 tar gzip openssl
      ;;
  esac
}

install_build_tools() {
  case "$PM" in
    apt)
      pm_install build-essential pkg-config
      ;;
    apk)
      pm_install build-base pkgconf
      ;;
    dnf|yum)
      pm_install gcc gcc-c++ make pkgconf-pkg-config
      ;;
    zypper)
      pm_install gcc gcc-c++ make pkg-config
      ;;
    pacman)
      pm_install base-devel pkgconf
      ;;
  esac
}

#========================
# User and directory setup
#========================
setup_user_and_dirs() {
  ensure_dir "$APP_DIR"
  # Create non-root user if not exists
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    case "$PM" in
      apk)
        addgroup -g "$APP_GID" "$APP_USER" 2>/dev/null || true
        adduser -D -H -s /bin/bash -G "$APP_USER" -u "$APP_UID" "$APP_USER" 2>/dev/null || true
        ;;
      *)
        if need_cmd groupadd; then
          groupadd -g "$APP_GID" -f "$APP_USER" || true
          useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" || true
        else
          warn "User/group management tools not available; skipping user creation."
        fi
        ;;
    esac
  fi
  chown -R "${APP_UID}:${APP_GID}" "$APP_DIR" || true
}

#========================
# Environment profile
#========================
write_env_profile() {
  ensure_dir "$ENV_PROFILE_DIR"
  cat >/tmp/app_env.sh <<EOF
# Generated by setup script
export TZ="${TZ}"
export LANG="${LANG}"
export LC_ALL="${LC_ALL}"
export APP_DIR="${APP_DIR}"
# Python defaults
export PYTHONDONTWRITEBYTECODE="\${PYTHONDONTWRITEBYTECODE:-1}"
export PIP_NO_CACHE_DIR="\${PIP_NO_CACHE_DIR:-1}"
# Node defaults
export NODE_ENV="\${NODE_ENV:-production}"
# Go defaults
export GOPATH="\${GOPATH:-/go}"
export GOCACHE="\${GOCACHE:-/go/.cache}"
# Rust defaults
export CARGO_HOME="\${CARGO_HOME:-/usr/local/cargo}"
export RUSTUP_HOME="\${RUSTUP_HOME:-/usr/local/rustup}"
# PATH adjustments (venv, Node corepack, Go, Cargo, local bin)
if [ -d "${APP_DIR}/.venv/bin" ]; then export PATH="${APP_DIR}/.venv/bin:\$PATH"; fi
if [ -d "\$GOPATH/bin" ]; then export PATH="\$GOPATH/bin:\$PATH"; fi
if [ -d "\$CARGO_HOME/bin" ]; then export PATH="\$CARGO_HOME/bin:\$PATH"; fi
if [ -d "${APP_DIR}/node_modules/.bin" ]; then export PATH="${APP_DIR}/node_modules/.bin:\$PATH"; fi
EOF
  # Only replace if content differs
  if ! cmp -s /tmp/app_env.sh "$ENV_PROFILE_FILE" 2>/dev/null; then
    mv /tmp/app_env.sh "$ENV_PROFILE_FILE"
  else
    rm -f /tmp/app_env.sh
  fi
}

#========================
# Virtual environment auto-activation
#========================
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line='if [ -d "${APP_DIR}/.venv/bin" ]; then . "${APP_DIR}/.venv/bin/activate"; fi'
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate Python virtual environment"
      echo "$activate_line"
    } >> "$bashrc_file"
  fi
}

#========================
# Stack installers
#========================
setup_python() {
  log "Configuring Python environment..."
  case "$PM" in
    apt)
      pm_install python3 python3-venv python3-pip python3-dev
      install_build_tools
      pm_install libffi-dev libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev tk-dev libjpeg-dev libpq-dev
      ;;
    apk)
      pm_install python3 py3-pip py3-virtualenv python3-dev
      install_build_tools
      pm_install libffi-dev openssl-dev zlib-dev bzip2-dev readline-dev sqlite-dev tiff-dev jpeg-dev postgresql-dev
      ;;
    dnf|yum)
      pm_install python3 python3-pip python3-devel
      install_build_tools
      pm_install libffi-devel openssl-devel zlib-devel bzip2 bzip2-devel readline-devel sqlite sqlite-devel libjpeg-turbo-devel postgresql-devel
      ;;
    zypper)
      pm_install python3 python3-pip python3-devel
      install_build_tools
      pm_install libffi-devel libopenssl-devel zlib-devel bzip2-devel readline-devel sqlite3 sqlite3-devel libjpeg8-devel postgresql-devel
      ;;
    pacman)
      pm_install python python-pip
      install_build_tools
      pm_install libffi openssl zlib bzip2 sqlite
      ;;
  esac

  # Create venv idempotently
  if [ ! -d "${APP_DIR}/.venv" ]; then
    python3 -m venv "${APP_DIR}/.venv"
  fi
  # shellcheck disable=SC1090
  source "${APP_DIR}/.venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  # Detect dependency management
  if [ -f "${APP_DIR}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "${APP_DIR}/requirements.txt"
  elif [ -f "${APP_DIR}/pyproject.toml" ]; then
    if grep -qiE '^\s*\[tool\.poetry\]' "${APP_DIR}/pyproject.toml"; then
      log "Detected Poetry project. Installing Poetry and dependencies..."
      pip install "poetry>=1.5"
      POETRY_VIRTUALENVS_IN_PROJECT=1 poetry install --no-interaction --no-root --only main || poetry install --no-interaction --no-root
    else
      # PEP 517/518 project; try pip install
      log "Installing Python dependencies from pyproject.toml via pip"
      pip install .
    fi
  elif [ -f "${APP_DIR}/Pipfile" ]; then
    log "Detected Pipenv project. Installing Pipenv and dependencies..."
    pip install "pipenv>=2023.0"
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install
  else
    warn "No Python dependency file found."
  fi

  # Ensure Moto server and extras are installed
  python -m pip install --upgrade 'moto[server]'
  python -m pip install -U 'moto[ec2,s3,all]'

  # Wrap moto_server to run in background and return immediately
  sh -lc 'set -e; MS=$(command -v moto_server || true); if [ -n "$MS" ] && [ ! -f "${MS}.orig" ]; then mv "$MS" "${MS}.orig"; fi; WRAP="${MS:-/usr/local/bin/moto_server}"; mkdir -p "$(dirname "$WRAP")"; cat > "$WRAP" << "EOF"
#!/bin/sh
ORIG="${0}.orig"
if [ -x "$ORIG" ]; then
  nohup "$ORIG" "$@" >/tmp/moto_server.log 2>&1 &
else
  nohup python3 -m moto.server "$@" >/tmp/moto_server.log 2>&1 &
fi
pid=$!
port=5000
prev=""
for arg in "$@"; do
  if [ "$prev" = "-p" ]; then port="$arg"; break; fi
  prev="$arg"
done
MOTO_PORT="$port" python3 - <<'PY'
import socket, time, os
port = int(os.environ.get("MOTO_PORT","5000"))
for _ in range(100):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            break
    except Exception:
        time.sleep(0.1)
PY
exit 0
EOF
chmod +x "$WRAP"'
}

setup_node() {
  log "Configuring Node.js environment..."
  if ! need_cmd node || ! need_cmd npm; then
    case "$PM" in
      apt)
        pm_install ca-certificates curl gnupg
        if [ ! -f "${STAMP_DIR}/nodesource-setup" ]; then
          curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
          touch "${STAMP_DIR}/nodesource-setup"
        fi
        pm_install nodejs
        ;;
      apk)
        pm_install nodejs npm
        ;;
      dnf|yum)
        pm_install ca-certificates curl gnupg2
        if [ ! -f "${STAMP_DIR}/nodesource-setup" ]; then
          curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
          touch "${STAMP_DIR}/nodesource-setup"
        fi
        pm_install nodejs
        ;;
      zypper)
        pm_install nodejs nodejs-npm || {
          warn "Zypper Node.js packages might be outdated. Consider base image with Node preinstalled."
        }
        ;;
      pacman)
        pm_install nodejs npm
        ;;
      *)
        warn "Unknown package manager; attempting to install Node via nvm."
        ;;
    esac
  fi

  if ! need_cmd node; then
    # Fallback to NVM install (global under /usr/local/nvm)
    log "Installing Node via NVM (fallback)..."
    export NVM_DIR="/usr/local/nvm"
    if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
      mkdir -p "${NVM_DIR}"
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash -s -- --no-use
    fi
    # shellcheck disable=SC1091
    . "${NVM_DIR}/nvm.sh"
    nvm install --lts
    nvm alias default 'lts/*'
    ln -sf "${NVM_DIR}/versions/node/$(nvm version)/bin/node" /usr/local/bin/node || true
    ln -sf "${NVM_DIR}/versions/node/$(nvm version)/bin/npm" /usr/local/bin/npm || true
    ln -sf "${NVM_DIR}/versions/node/$(nvm version)/bin/npx" /usr/local/bin/npx || true
  fi

  # Prefer corepack for yarn/pnpm where available
  if need_cmd corepack; then
    corepack enable || true
  fi

  # Avoid npm permission issues when running as root
  if [ ! -f "${APP_DIR}/.npmrc" ]; then
    echo "unsafe-perm=true" > "${APP_DIR}/.npmrc"
  fi

  # Install dependencies
  if [ -f "${APP_DIR}/package.json" ]; then
    pushd "${APP_DIR}" >/dev/null
    if [ -f yarn.lock ] && need_cmd yarn; then
      log "Installing Node dependencies with Yarn..."
      yarn install --frozen-lockfile --production=true || yarn install --production=true
    elif [ -f package-lock.json ]; then
      log "Installing Node dependencies with npm ci..."
      npm ci --omit=dev || npm ci
    else
      log "Installing Node dependencies with npm..."
      npm install --omit=dev || npm install
    fi
    popd >/dev/null
  else
    warn "No package.json found for Node.js."
  fi
}

setup_go() {
  log "Configuring Go environment..."
  if ! need_cmd go; then
    case "$PM" in
      apt) pm_install golang ;;
      apk) pm_install go ;;
      dnf|yum) pm_install golang ;;
      zypper) pm_install go ;;
      pacman) pm_install go ;;
      *) warn "Unable to install Go with current package manager."; return ;;
    esac
  fi
  ensure_dir "/go"; chown -R "${APP_UID}:${APP_GID}" /go || true
  if [ -f "${APP_DIR}/go.mod" ]; then
    pushd "${APP_DIR}" >/dev/null
    go env -w GOPATH=/go GOCACHE=/go/.cache || true
    go mod download
    popd >/dev/null
  else
    warn "No go.mod found."
  fi
}

setup_rust() {
  log "Configuring Rust environment..."
  if ! need_cmd cargo; then
    install_build_tools
    export CARGO_HOME="/usr/local/cargo"
    export RUSTUP_HOME="/usr/local/rustup"
    if [ ! -x "${CARGO_HOME}/bin/cargo" ]; then
      curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal
      ln -sf "${CARGO_HOME}/bin/cargo" /usr/local/bin/cargo || true
      ln -sf "${CARGO_HOME}/bin/rustc" /usr/local/bin/rustc || true
    fi
  fi
  if [ -f "${APP_DIR}/Cargo.toml" ]; then
    pushd "${APP_DIR}" >/dev/null
    "${CARGO_HOME:-/usr/local/cargo}"/bin/cargo fetch || cargo fetch
    popd >/dev/null
  else
    warn "No Cargo.toml found."
  fi
}

setup_java() {
  log "Configuring Java environment..."
  if ! need_cmd java; then
    case "$PM" in
      apt) pm_install openjdk-17-jdk ;;
      apk) pm_install openjdk17-jdk ;;
      dnf|yum) pm_install java-17-openjdk-devel ;;
      zypper) pm_install java-17-openjdk-devel ;;
      pacman) pm_install jdk17-openjdk ;;
      *) warn "Unable to install Java with current package manager."; return ;;
    esac
  fi
  local has_maven=false
  local has_gradle=false
  if [ -f "${APP_DIR}/pom.xml" ]; then
    has_maven=true
    need_cmd mvn || case "$PM" in
      apt) pm_install maven ;;
      apk) pm_install maven ;;
      dnf|yum) pm_install maven ;;
      zypper) pm_install maven ;;
      pacman) pm_install maven ;;
    esac
  fi
  if compgen -G "${APP_DIR}/build.gradle*" >/dev/null 2>&1; then
    has_gradle=true
    need_cmd gradle || case "$PM" in
      apt) pm_install gradle || true ;;
      apk) pm_install gradle || true ;;
      dnf|yum) pm_install gradle || true ;;
      zypper) pm_install gradle || true ;;
      pacman) pm_install gradle || true ;;
    esac
  fi

  if [ "$has_maven" = true ]; then
    pushd "${APP_DIR}" >/dev/null
    mvn -B -DskipTests dependency:resolve dependency:resolve-plugins || true
    popd >/dev/null
  fi
  if [ "$has_gradle" = true ]; then
    pushd "${APP_DIR}" >/dev/null
    if [ -f gradlew ]; then
      chmod +x gradlew
      ./gradlew --no-daemon dependencies || true
    else
      gradle --no-daemon dependencies || true
    fi
    popd >/dev/null
  fi
}

setup_ruby() {
  log "Configuring Ruby environment..."
  if ! need_cmd ruby; then
    case "$PM" in
      apt)
        pm_install ruby-full
        install_build_tools
        pm_install zlib1g-dev
        ;;
      apk)
        pm_install ruby ruby-dev
        install_build_tools
        pm_install zlib-dev
        ;;
      dnf|yum)
        pm_install ruby ruby-devel
        install_build_tools
        pm_install zlib-devel
        ;;
      zypper)
        pm_install ruby ruby-devel
        install_build_tools
        pm_install zlib-devel
        ;;
      pacman)
        pm_install ruby
        install_build_tools
        ;;
    esac
  fi
  if ! need_cmd bundler; then
    gem install bundler -N || true
  fi
  if [ -f "${APP_DIR}/Gemfile" ]; then
    pushd "${APP_DIR}" >/dev/null
    bundle config set --local path 'vendor/bundle'
    bundle config set --local without 'development test' || true
    bundle install --jobs=4 --retry=3
    popd >/dev/null
  else
    warn "No Gemfile found."
  fi
}

setup_php() {
  log "Configuring PHP environment..."
  if ! need_cmd php; then
    case "$PM" in
      apt)
        pm_install php-cli php-common php-mbstring php-xml php-curl php-zip php-intl php-gd php-sqlite3 php-pgsql php-mysql unzip
        ;;
      apk)
        pm_install php81 php81-cli php81-common php81-mbstring php81-xml php81-curl php81-zip php81-intl php81-gd php81-sqlite3 php81-pgsql php81-mysqli php81-iconv php81-openssl unzip || \
        pm_install php php-cli php-common php-mbstring php-xml php-curl php-zip php-intl php-gd php-sqlite3 php-pgsql php-mysqli unzip
        ;;
      dnf|yum)
        pm_install php-cli php-common php-mbstring php-xml php-json php-gd php-intl php-pdo php-mysqlnd php-pgsql php-zip unzip
        ;;
      zypper)
        pm_install php8 php8-cli php8-mbstring php8-xml php8-curl php8-zip php8-intl php8-gd php8-sqlite php8-mysql php8-pgsql unzip || \
        pm_install php php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd php-sqlite php-mysql php-pgsql unzip
        ;;
      pacman)
        pm_install php php-gd php-intl php-sqlite php-pgsql php-apache php-curl unzip
        ;;
    esac
  fi
  if ! need_cmd composer; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      error "Invalid Composer installer signature"
      return
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi
  if [ -f "${APP_DIR}/composer.json" ]; then
    pushd "${APP_DIR}" >/dev/null
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist --no-progress --no-dev || composer install --no-interaction --prefer-dist --no-progress
    popd >/dev/null
  else
    warn "No composer.json found."
  fi
}

setup_dotnet() {
  # Lightweight handling: attempt to ensure dotnet exists; otherwise warn
  if compgen -G "${APP_DIR}/*.csproj" >/dev/null 2>&1 || [ -f "${APP_DIR}/global.json" ]; then
    if ! need_cmd dotnet; then
      warn ".NET SDK not found. Installing .NET SDK in arbitrary base images is non-trivial. Consider using a dotnet SDK base image."
      return
    fi
    log "Restoring .NET dependencies..."
    pushd "${APP_DIR}" >/dev/null
    dotnet restore || true
    popd >/dev/null
  fi
}

#========================
# Stack detection
#========================
has_python()  { [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/Pipfile" ]; }
has_node()    { [ -f "${APP_DIR}/package.json" ]; }
has_go()      { [ -f "${APP_DIR}/go.mod" ]; }
has_rust()    { [ -f "${APP_DIR}/Cargo.toml" ]; }
has_java()    { [ -f "${APP_DIR}/pom.xml" ] || compgen -G "${APP_DIR}/build.gradle*" >/dev/null 2>&1; }
has_ruby()    { [ -f "${APP_DIR}/Gemfile" ]; }
has_php()     { [ -f "${APP_DIR}/composer.json" ]; }
has_dotnet()  { compgen -G "${APP_DIR}/*.csproj" >/dev/null 2>&1 || [ -f "${APP_DIR}/global.json" ]; }

#========================
# Main
#========================
main() {
  log "Starting environment setup..."

  detect_project_dir
  log "Project directory: ${APP_DIR}"

  pm_detect || { error "No supported package manager found in this container."; exit 1; }
  install_base_tools

  # Timezone and locales (best-effort)
  case "$PM" in
    apt)
      ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
      echo "${TZ}" >/etc/timezone || true
      if [ -f /etc/locale.gen ]; then
        sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
        locale-gen || true
      fi
      ;;
    apk)
      echo "${TZ}" >/etc/timezone || true
      ;;
    *)
      :
      ;;
  esac

  setup_user_and_dirs
  write_env_profile
  setup_auto_activate

  # Detect stacks and set up accordingly
  local configured=false
  if has_python; then setup_python; configured=true; fi
  if has_node;   then setup_node;   configured=true; fi
  if has_go;     then setup_go;     configured=true; fi
  if has_rust;   then setup_rust;   configured=true; fi
  if has_java;   then setup_java;   configured=true; fi
  if has_ruby;   then setup_ruby;   configured=true; fi
  if has_php;    then setup_php;    configured=true; fi
  if has_dotnet; then setup_dotnet; configured=true; fi

  if [ "$configured" = false ]; then
    warn "No recognized project files found in ${APP_DIR}. Base tools and environment have been configured."
  fi

  pm_clean

  # Final permission fixup for app directory and caches
  chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}" /go 2>/dev/null || true
  chown -R "${APP_UID}:${APP_GID}" /usr/local/cargo /usr/local/rustup 2>/dev/null || true

  log "Environment setup completed successfully."
  log "To load environment variables in interactive shell: source ${ENV_PROFILE_FILE}"
}

main "$@"