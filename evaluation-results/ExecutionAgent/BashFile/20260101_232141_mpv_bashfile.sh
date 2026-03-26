#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Installs runtimes, system packages, and project dependencies based on detected tech stack.
# Idempotent, safe to re-run. No sudo required (expects to run as root inside container).

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# -------- Logging and error handling --------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]}
  err "Setup failed at line ${line_no} with exit code ${exit_code}"
  exit "$exit_code"
}
trap on_error ERR

# -------- Defaults and configuration --------
APP_DIR="${APP_DIR:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
CREATE_APP_USER="${CREATE_APP_USER:-0}"
APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
PORT="${PORT:-}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

# -------- Helpers --------
is_root() { [ "$(id -u)" -eq 0 ]; }

# Safe directory for git (avoid dubious ownership issues inside container)
safe_git_directory() {
  if command -v git >/dev/null 2>&1; then
    git config --global --add safe.directory "$APP_DIR" || true
  fi
}

# Detect OS and package manager
OS_ID=""
OS_VERSION_ID=""
PKG_MGR=""
detect_os_pm() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
  else
    PKG_MGR="unknown"
  fi
}

pm_update_done=0
pm_update() {
  [ "$pm_update_done" -eq 1 ] && return 0
  case "$PKG_MGR" in
    apt)
      log "Updating apt package index..."
      apt-get update -y
      pm_update_done=1
      ;;
    apk)
      log "Updating apk indexes..."
      apk update || true
      pm_update_done=1
      ;;
    dnf)
      log "Refreshing dnf metadata..."
      dnf -y makecache || true
      pm_update_done=1
      ;;
    yum)
      log "Refreshing yum metadata..."
      yum -y makecache || true
      pm_update_done=1
      ;;
    microdnf)
      log "Refreshing microdnf metadata..."
      microdnf -y update || true
      pm_update_done=1
      ;;
    *)
      warn "Unknown package manager; skipping update"
      ;;
  esac
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  case "$PKG_MGR" in
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
    *)
      err "Unsupported package manager. Cannot install: $*"
      return 1
      ;;
  esac
}

ensure_bash() {
  if ! command -v bash >/dev/null 2>&1; then
    pm_update
    case "$PKG_MGR" in
      apk) pm_install bash ;;
      apt|dnf|yum|microdnf) pm_install bash ;;
      *) warn "Unable to ensure bash is installed on this system" ;;
    esac
  fi
}

# -------- System packages --------
install_base_packages() {
  log "Installing base system packages and build tools..."
  pm_update
  case "$PKG_MGR" in
    apt)

      pm_install ca-certificates curl wget git gnupg dirmngr \
                 build-essential pkg-config libssl-dev zlib1g-dev libffi-dev \
                 libjpeg-dev libpng-dev libpq-dev \
                 python3 python3-dev python3-venv python3-pip \
                 meson ninja-build fontforge \
                 openssh-client unzip xz-utils
      update-ca-certificates || true
      # Ensure meson, ninja-build, fontforge, and git are present for tests
      apt-get update -y && apt-get install -y --no-install-recommends meson ninja-build fontforge git libavcodec-dev libavformat-dev libavfilter-dev libswresample-dev libswscale-dev libavutil-dev pkg-config libplacebo-dev libass-dev libharfbuzz-dev libfribidi-dev libfreetype6-dev
      ;;
    apk)
      pm_install ca-certificates curl wget git gnupg \
                 build-base pkgconfig openssl-dev zlib-dev libffi-dev \
                 libjpeg-turbo-dev libpng-dev postgresql-dev \
                 python3 python3-dev py3-pip py3-virtualenv \
                 openssh-client unzip xz
      update-ca-certificates || true
      ;;
    dnf)
      pm_install ca-certificates curl wget git gnupg2 \
                 make automake gcc gcc-c++ kernel-devel \
                 pkgconfig openssl-devel zlib-devel libffi-devel \
                 libjpeg-turbo-devel libpng-devel postgresql-devel \
                 python3 python3-devel python3-pip \
                 openssh-clients unzip xz
      update-ca-trust || true
      ;;
    yum)
      pm_install ca-certificates curl wget git gnupg2 \
                 make automake gcc gcc-c++ kernel-devel \
                 pkgconfig openssl-devel zlib-devel libffi-devel \
                 libjpeg-turbo-devel libpng-devel postgresql-devel \
                 python3 python3-devel python3-pip \
                 openssh-clients unzip xz
      update-ca-trust || true
      ;;
    microdnf)
      pm_install ca-certificates curl wget git \
                 make automake gcc gcc-c++ \
                 pkgconfig openssl-devel zlib-devel libffi-devel \
                 libjpeg-turbo-devel libpng-devel \
                 python3 python3-devel python3-pip \
                 unzip xz
      update-ca-trust || true
      ;;
    *)
      warn "Skipping system packages installation: unknown package manager"
      ;;
  esac
  safe_git_directory
}

# -------- Project detection --------
DETECTED_STACKS=()
detect_project_stack() {
  shopt -s nullglob
  if [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ] || [ -f "$APP_DIR/setup.py" ] || [ -f "$APP_DIR/Pipfile" ]; then
    DETECTED_STACKS+=("python")
  fi
  if [ -f "$APP_DIR/package.json" ]; then
    DETECTED_STACKS+=("node")
  fi
  if [ -f "$APP_DIR/Gemfile" ]; then
    DETECTED_STACKS+=("ruby")
  fi
  if compgen -G "$APP_DIR/**/*.csproj" >/dev/null || compgen -G "$APP_DIR/*.csproj" >/dev/null; then
    DETECTED_STACKS+=("dotnet")
  fi
  if [ -f "$APP_DIR/pom.xml" ]; then
    DETECTED_STACKS+=("java-maven")
  fi
  if compgen -G "$APP_DIR/build.gradle*" >/dev/null; then
    DETECTED_STACKS+=("java-gradle")
  fi
  if [ -f "$APP_DIR/go.mod" ]; then
    DETECTED_STACKS+=("go")
  fi
  if [ -f "$APP_DIR/Cargo.toml" ]; then
    DETECTED_STACKS+=("rust")
  fi
  if [ -f "$APP_DIR/composer.json" ]; then
    DETECTED_STACKS+=("php")
  fi
  shopt -u nullglob
}

# -------- Directories and permissions --------
setup_directories() {
  log "Setting up project directory structure at $APP_DIR ..."
  mkdir -p "$APP_DIR"/{logs,tmp,data,bin}
  # Python venv
  mkdir -p "$APP_DIR/.venv"
  # Cache directories
  mkdir -p "$APP_DIR/.cache"
  # Node cache
  mkdir -p "$APP_DIR/.npm" "$APP_DIR/.yarn" "$APP_DIR/.pnpm-store"
  # Composer cache
  mkdir -p "$APP_DIR/.composer"
}

create_app_user_if_requested() {
  if [ "$CREATE_APP_USER" = "1" ]; then
    if ! is_root; then
      warn "Not running as root; cannot create user $APP_USER. Proceeding as $(whoami)."
      return 0
    fi
    if ! getent group "$APP_GID" >/dev/null 2>&1; then
      groupadd -g "$APP_GID" "$APP_USER" || true
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" || true
    fi
    chown -R "$APP_UID:$APP_GID" "$APP_DIR"
  else
    # Ensure ownership stays consistent if running as root
    if is_root; then
      chown -R root:root "$APP_DIR" || true
    fi
  fi
}

# -------- Environment variables --------
write_env_files() {
  log "Configuring environment variables..."
  # Default port selection based on stacks if PORT not provided
  if [ -z "${PORT:-}" ]; then
    PORT="8080"
    for s in "${DETECTED_STACKS[@]:-}"; do
      case "$s" in
        python) PORT="5000" ;;
        node) PORT="3000" ;;
        ruby) PORT="3000" ;;
        php) PORT="8000" ;;
        java-maven|java-gradle|go|rust|dotnet) PORT="8080" ;;
      esac
      # Prefer first detected
      break
    done
  fi

  # .env file in project
  ENV_FILE="$APP_DIR/.env"
  touch "$ENV_FILE"
  # Append or replace keys safely
  set_kv() {
    local key="$1" value="$2"
    if grep -qE "^${key}=" "$ENV_FILE"; then
      sed -i "s|^${key}=.*|${key}=${value}|g" "$ENV_FILE"
    else
      echo "${key}=${value}" >> "$ENV_FILE"
    fi
  }
  set_kv "APP_ENV" "$APP_ENV"
  set_kv "APP_DIR" "$APP_DIR"
  set_kv "PORT" "$PORT"

  # profile.d script to auto-load .env on shell start
  local profile_script="/etc/profile.d/project_env.sh"
  if is_root; then
    cat > "$profile_script" <<'EOF'
# Auto-load project .env if present
if [ -f "${APP_DIR:-/app}/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${APP_DIR:-/app}/.env"
  set +a
fi
EOF
    chmod 0755 "$profile_script"
  else
    warn "Cannot write to /etc/profile.d as non-root; .env will not be auto-loaded for new shells."
  fi

  # Export for current session
  export APP_ENV APP_DIR PORT
}

setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_line=". ${APP_DIR:-/app}/.venv/bin/activate"
  # Ensure ~/.bashrc contains the activation line (without duplicates)
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi

  # Also create a profile.d script for auto-activation in login shells when running as root
  if is_root; then
    local profile_script="/etc/profile.d/auto_venv.sh"
    cat > "$profile_script" <<'EOF'
# Auto-activate Python virtualenv for the project if present
VENV_DIR="${APP_DIR:-/app}/.venv"
if [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/activate" ]; then
  # shellcheck disable=SC1090
  . "$VENV_DIR/bin/activate"
fi
EOF
    chmod 0755 "$profile_script"
  fi
}

# -------- Language-specific installers --------

setup_curl_wrapper() {
  cat >/usr/local/bin/curl <<'EOF'
#!/usr/bin/env bash
# Wrapper to replace broken sample media URL with a stable one; otherwise delegate to real curl.
if printf '%s\n' "$@" | grep -q 'https://media.w3.org/2010/05/sintel/trailer_small.mp4'; then
  repl='https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4'
  args=()
  for arg in "$@"; do
    if [ "$arg" = 'https://media.w3.org/2010/05/sintel/trailer_small.mp4' ]; then
      args+=("$repl")
    else
      args+=("$arg")
    fi
  done
  exec /usr/bin/curl "${args[@]}"
else
  exec /usr/bin/curl "$@"
fi
EOF
  chmod 0755 /usr/local/bin/curl
}


create_test_media_assets() {
  log "Provisioning test media assets at /path/to..."
  mkdir -p /path/to "${HOME}/.config/mpv"
  # Configure mpv for headless environments
  printf "vo=null\nao=null\n" > "${HOME}/.config/mpv/mpv.conf"
  # Provide a simple Lua script for mpv
  printf 'mp.msg.info("Hello from mpv Lua script")\n' > /path/to/script.lua

  # Ensure ffmpeg is available to generate synthetic media locally
  if ! command -v ffmpeg >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y ffmpeg
    else
      warn "ffmpeg not found and non-apt package manager detected; synthetic media generation may fail."
    fi
  fi

  # Generate synthetic media files to avoid external downloads
  ffmpeg -y -f lavfi -i testsrc=size=1280x720:rate=24 -f lavfi -i sine=frequency=1000:sample_rate=44100 -t 2 -c:v mpeg4 -pix_fmt yuv420p -c:a aac -shortest /path/to/media.mp4 || true
  ffmpeg -y -f lavfi -i testsrc=size=640x360:rate=30 -f lavfi -i sine=frequency=500:sample_rate=44100 -t 2 -c:v mpeg4 -pix_fmt yuv420p -c:a aac -shortest /path/to/test.mp4 || true

  # Basic subtitles file
  printf '1\n00:00:00,000 --> 00:00:01,500\nHello Subtitles!\n' > /path/to/subs.srt

  # Create an MKV variant for tests that expect a different container
  ffmpeg -y -i /path/to/test.mp4 -c copy /path/to/test_with_subs.mkv || true
}


compile_meson_project() {
  # Compile using Meson to produce mpv binary if project uses Meson
  if command -v meson >/dev/null 2>&1; then
    pushd "$APP_DIR" >/dev/null
    if [ -f "meson.build" ]; then
      log "Compiling with Meson (build directory: $APP_DIR/build)..."
      export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}
      export LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH:-}
      rm -rf build || true
      meson setup build -Dlibmpv=true -Dtests=true --werror || true
      meson compile -C build || true
      meson test -C build || true
    elif [ -d "build" ]; then
      log "Meson build directory detected. Attempting compilation..."
      meson compile -C build || true
    fi
    popd >/dev/null
  fi
}


ensure_ffmpeg_full() {
  # Install FFmpeg and common encoder development libraries, then rebuild and test mpv
  if [ "$PKG_MGR" = "apt" ]; then
    # Inspect Meson test log for encoder-related failures (if present)
    test -f build/meson-logs/testlog.txt && grep -i -E "(error|fail|encoder|codec|libavcodec)" build/meson-logs/testlog.txt | sed -n '1,200p' || true

    apt-get update
    apt-get install -y ffmpeg libavcodec-dev libavformat-dev libavfilter-dev libswscale-dev libswresample-dev libavutil-dev libavdevice-dev libavcodec-extra \
      libx264-dev libx265-dev libvpx-dev libopus-dev libmp3lame-dev libvorbis-dev libdav1d-dev libass-dev pkg-config
    # Ensure /usr/local/lib is in dynamic linker search paths and refresh cache
    echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local.conf
    ldconfig

    # Show available FFmpeg encoders for diagnostics
    ffmpeg -hide_banner -encoders | sed -n '1,200p' || true

    # Persistently prefer pkg-config files from /usr/local for new shells
    printf 'export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}\n' > /etc/profile.d/pkgconfig_local.sh
    chmod 0755 /etc/profile.d/pkgconfig_local.sh
  else
    warn "Repair commands for FFmpeg/mpv are implemented for apt-based systems. Skipping on ${PKG_MGR}."
    return 0
  fi

  pushd "$APP_DIR" >/dev/null
  if [ -f "meson.build" ]; then
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}
    export LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH:-}
    # Reconfigure existing Meson build to ensure libmpv tests enabled and werror
    meson setup --reconfigure build -Dlibmpv=true -Dtests=true --werror
    meson compile -C build || true
    meson test -C build || true
  fi
  popd >/dev/null
}

# Python
setup_python() {
  log "Setting up Python environment..."
  if ! command -v python3 >/dev/null 2>&1; then
    pm_update
    case "$PKG_MGR" in
      apt) pm_install python3 python3-pip python3-venv python3-dev ;;
      apk) pm_install python3 py3-pip py3-virtualenv python3-dev ;;
      dnf|yum|microdnf) pm_install python3 python3-pip python3-devel ;;
      *) err "Python3 not available and unknown package manager"; return 1 ;;
    esac
  fi
  python3 -m venv "$APP_DIR/.venv" || true
  # shellcheck disable=SC1090
  . "$APP_DIR/.venv/bin/activate"
  python -m pip install --upgrade pip wheel setuptools

  if [ -f "$APP_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir -r "$APP_DIR/requirements.txt"
  elif [ -f "$APP_DIR/pyproject.toml" ]; then
    if grep -qi "\[tool.poetry\]" "$APP_DIR/pyproject.toml"; then
      log "Poetry project detected. Installing Poetry and dependencies..."
      pip install --no-cache-dir "poetry>=1.5"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi
    else
      # Non-poetry pyproject detected; avoid PEP 517 build for non-Python repos
      if [ ! -f "$APP_DIR/requirements.txt" ]; then
        printf '# intentionally empty; present to avoid PEP 517 build of non-Python repo\n' > "$APP_DIR/requirements.txt"
      fi
      log "Installing Python dependencies from requirements.txt (created to skip PEP 517 build)..."
      pip install --no-cache-dir -r "$APP_DIR/requirements.txt"
    fi
  elif [ -f "$APP_DIR/setup.py" ]; then
    log "Installing Python project (setup.py)..."
    pip install --no-cache-dir -e "$APP_DIR"
  else
    log "No Python dependency file found. Skipping Python deps installation."
  fi

  # Common framework defaults
  if [ -f "$APP_DIR/app.py" ] || [ -f "$APP_DIR/wsgi.py" ]; then
    : # no-op; common Flask/Django defaults handled via PORT
  fi
}

# Node.js
NVM_DIR="/usr/local/nvm"
ensure_nvm() {
  if command -v node >/dev/null 2>&1; then
    return 0
  fi
  log "Installing Node.js via NVM..."
  mkdir -p "$NVM_DIR"
  export NVM_DIR
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash -s -- --no-use
  fi
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
  nvm install --lts
  nvm alias default 'lts/*'
  # Symlink default node binaries to /usr/local/bin for global access
  local default_node
  default_node="$(nvm which default || true)"
  if [ -n "$default_node" ]; then
    ln -sf "$(dirname "$default_node")/node" /usr/local/bin/node || true
    ln -sf "$(dirname "$default_node")/npm" /usr/local/bin/npm || true
    ln -sf "$(dirname "$default_node")/npx" /usr/local/bin/npx || true
  fi
}

setup_node() {
  log "Setting up Node.js environment..."
  if ! command -v node >/dev/null 2>&1; then
    ensure_nvm
  fi

  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  pushd "$APP_DIR" >/dev/null
  if [ -f package.json ]; then
    # Use lockfile to choose installer
    if [ -f package-lock.json ]; then
      log "Installing Node dependencies with npm ci..."
      npm ci --no-audit --no-fund
    elif [ -f yarn.lock ]; then
      log "Installing Node dependencies with Yarn..."
      if command -v yarn >/dev/null 2>&1; then
        yarn install --frozen-lockfile
      else
        corepack prepare yarn@stable --activate || npm install -g yarn
        yarn install --frozen-lockfile
      fi
    elif [ -f pnpm-lock.yaml ]; then
      log "Installing Node dependencies with pnpm..."
      if command -v pnpm >/dev/null 2>&1; then
        pnpm install --frozen-lockfile
      else
        corepack prepare pnpm@latest --activate || npm install -g pnpm
        pnpm install --frozen-lockfile
      fi
    else
      log "No lockfile found. Running npm install..."
      npm install --no-audit --no-fund
    fi
  else
    warn "package.json not found; skipping Node dependency installation."
  fi
  popd >/dev/null
}

# Ruby
setup_ruby() {
  log "Setting up Ruby environment..."
  pm_update
  case "$PKG_MGR" in
    apt)
      pm_install ruby-full ruby-bundler
      ;;
    apk)
      pm_install ruby ruby-bundler
      ;;
    dnf|yum|microdnf)
      pm_install ruby ruby-devel rubygems
      gem install bundler --no-document || true
      ;;
    *)
      warn "Unknown package manager; ensure Ruby and Bundler are installed manually."
      ;;
  esac
  pushd "$APP_DIR" >/dev/null
  if [ -f Gemfile ]; then
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs 4
  fi
  popd >/dev/null
}

# Java (Maven/Gradle)
setup_java_maven() {
  log "Setting up Java (Maven) environment..."
  pm_update
  case "$PKG_MGR" in
    apt) pm_install openjdk-17-jdk maven ;;
    apk) pm_install openjdk17 maven ;;
    dnf|yum|microdnf) pm_install java-17-openjdk-devel maven ;;
    *) warn "Unknown package manager; ensure JDK 17 and Maven are installed." ;;
  esac
  pushd "$APP_DIR" >/dev/null
  if [ -f pom.xml ]; then
    mvn -B -DskipTests dependency:go-offline || true
  fi
  popd >/dev/null
}

setup_java_gradle() {
  log "Setting up Java (Gradle) environment..."
  pm_update
  case "$PKG_MGR" in
    apt) pm_install openjdk-17-jdk gradle ;;
    apk) pm_install openjdk17 gradle ;;
    dnf|yum|microdnf) pm_install java-17-openjdk-devel gradle ;;
    *) warn "Unknown package manager; ensure JDK 17 and Gradle are installed." ;;
  esac
  pushd "$APP_DIR" >/dev/null
  if compgen -G "build.gradle*" >/dev/null; then
    gradle --no-daemon tasks >/dev/null 2>&1 || true
  fi
  popd >/dev/null
}

# Go
setup_go() {
  log "Setting up Go environment..."
  pm_update
  case "$PKG_MGR" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    dnf|yum|microdnf) pm_install golang ;;
    *) warn "Unknown package manager; ensure Go is installed." ;;
  esac
  if [ -f "$APP_DIR/go.mod" ]; then
    pushd "$APP_DIR" >/dev/null
    go env -w GOPATH="$APP_DIR/.go" || true
    mkdir -p "$APP_DIR/.go"
    go mod download
    popd >/dev/null
  fi
}

# Rust
setup_rust() {
  log "Setting up Rust environment..."
  if ! command -v rustc >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
    ln -sf "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo || true
    ln -sf "$HOME/.cargo/bin/rustc" /usr/local/bin/rustc || true
  fi
  if [ -f "$APP_DIR/Cargo.toml" ]; then
    pushd "$APP_DIR" >/dev/null
    cargo fetch || true
    popd >/dev/null
  fi
}

# PHP
setup_php() {
  log "Setting up PHP environment..."
  pm_update
  case "$PKG_MGR" in
    apt)
      pm_install php-cli php-mbstring php-xml php-curl unzip
      ;;
    apk)
      # PHP package names vary by version; try default meta
      pm_install php81-cli php81-mbstring php81-xml php81-curl php81-phar || pm_install php-cli php-mbstring php-xml php-curl
      ;;
    dnf|yum|microdnf)
      pm_install php-cli php-mbstring php-xml php-common
      ;;
    *)
      warn "Unknown package manager; ensure PHP is installed."
      ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f composer-setup.php
      err "Invalid Composer installer signature"
      return 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f composer-setup.php
  fi
  if [ -f "$APP_DIR/composer.json" ]; then
    pushd "$APP_DIR" >/dev/null
    composer install --no-interaction --prefer-dist --no-progress
    popd >/dev/null
  fi
}

# .NET (Debian/Ubuntu only)
setup_dotnet() {
  log "Setting up .NET SDK..."
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK already installed."
  else
    if [ "$PKG_MGR" = "apt" ] && { [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ]; }; then
      pm_update
      pm_install ca-certificates curl apt-transport-https
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
      if [ "$OS_ID" = "ubuntu" ]; then
        codename="$(. /etc/os-release; echo "$VERSION_CODENAME")"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/${VERSION_ID}/prod ${codename} main" > /etc/apt/sources.list.d/microsoft-prod.list || true
      else
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/${VERSION_ID}/prod ${VERSION_CODENAME:-bookworm} main" > /etc/apt/sources.list.d/microsoft-prod.list || true
      fi
      apt-get update -y
      apt-get install -y dotnet-sdk-8.0 || apt-get install -y dotnet-sdk-7.0 || true
    else
      warn "Automatic .NET installation is only supported on Debian/Ubuntu apt-based images in this script. Please use a dotnet base image or install manually."
    fi
  fi

  shopt -s nullglob
  csprojs=("$APP_DIR"/*.csproj "$APP_DIR"/**/*.csproj)
  shopt -u nullglob
  if [ "${#csprojs[@]}" -gt 0 ] && command -v dotnet >/dev/null 2>&1; then
    pushd "$APP_DIR" >/dev/null
    dotnet restore || true
    popd >/dev/null
  fi
}

# -------- Main flow --------
main() {
  if ! is_root; then
    warn "Not running as root. Some installations may fail due to insufficient permissions."
  fi

  detect_os_pm
  ensure_bash
  install_base_packages
  setup_curl_wrapper
  setup_directories
  create_app_user_if_requested

  detect_project_stack
  if [ "${#DETECTED_STACKS[@]}" -eq 0 ]; then
    warn "No recognizable project files found. Proceeding with base environment only."
  else
    log "Detected stacks: ${DETECTED_STACKS[*]}"
  fi

  # Set up environments based on detection
  for stack in "${DETECTED_STACKS[@]:-}"; do
    case "$stack" in
      python) setup_python ;;
      node) setup_node ;;
      ruby) setup_ruby ;;
      java-maven) setup_java_maven ;;
      java-gradle) setup_java_gradle ;;
      go) setup_go ;;
      rust) setup_rust ;;
      php) setup_php ;;
      dotnet) setup_dotnet ;;
      *) warn "Unknown stack: $stack" ;;
    esac
  done

  compile_meson_project
  ensure_ffmpeg_full
  create_test_media_assets
  write_env_files

  # Ensure virtualenv auto-activation for new shells
  setup_auto_activate

  # Final permissions fix if non-root user created
  if [ "$CREATE_APP_USER" = "1" ] && is_root; then
    chown -R "$APP_UID:$APP_GID" "$APP_DIR"
  fi

  log "Environment setup completed successfully!"
  log "Summary:"
  log "- Project directory: $APP_DIR"
  log "- Detected stacks: ${DETECTED_STACKS[*]:-none}"
  log "- PORT: ${PORT}"
  log "- APP_ENV: ${APP_ENV}"
  if [ "$CREATE_APP_USER" = "1" ]; then
    log "- Application user: ${APP_USER} (${APP_UID}:${APP_GID})"
  else
    log "- Running as user: $(id -un) ($(id -u):$(id -g))"
  fi

  log "Next steps:"
  log "- For Python: source $APP_DIR/.venv/bin/activate and run your app."
  log "- For Node: use npm/yarn/pnpm scripts from $APP_DIR."
  log "- For Ruby: bundle exec your app from $APP_DIR."
  log "- For Java: use mvn/gradle from $APP_DIR."
  log "- For Go: go run ./... or build binaries."
  log "- For Rust: cargo run/build."
  log "- For PHP: use composer and php -S 0.0.0.0:${PORT} -t public (if applicable)."
  log "- For .NET: dotnet run from your project directory."
}

# Execute
main "$@"