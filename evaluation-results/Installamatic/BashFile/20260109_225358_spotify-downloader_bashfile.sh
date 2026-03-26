#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Installs runtimes, system dependencies, configures environment, and sets up project dependencies
# Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

#-------------------------
# Logging and error handling
#-------------------------
LOG_PREFIX="[setup]"
log() { echo "${LOG_PREFIX} $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; }
on_err() {
  err "An error occurred on line ${BASH_LINENO[0]} while running: ${BASH_COMMAND}"
  exit 1
}
trap on_err ERR

#-------------------------
# Configuration
#-------------------------
APP_DIR="${APP_DIR:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
CREATE_APP_USER="${CREATE_APP_USER:-false}"
APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"

# Default ports by stack (overridable via PORT env var)
DEFAULT_PORT_GENERIC=8000
DEFAULT_PORT_PY=8000
DEFAULT_PORT_FLASK=5000
DEFAULT_PORT_NODE=3000
DEFAULT_PORT_PHP=8000
DEFAULT_PORT_JAVA=8080
DEFAULT_PORT_GO=8080
DEFAULT_PORT_RUBY=9292
DEFAULT_PORT_DOTNET=8080
DEFAULT_PORT_RUST=8080

DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

#-------------------------
# Detect package manager
#-------------------------
PKG_MANAGER=""
APT_UPDATED=0
APK_UPDATED=0
RPM_UPDATED=0

detect_pkg_manager() {
  if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    err "No supported package manager found (apk/apt/dnf/yum/microdnf)"
    exit 1
  fi
}

install_packages() {
  # Usage: install_packages pkg1 pkg2 ...
  local pkgs=("$@")
  if [ "${#pkgs[@]}" -eq 0 ]; then
    return 0
  fi
  case "$PKG_MANAGER" in
    apk)
      if [ "$APK_UPDATED" -eq 0 ]; then
        log "Updating apk indexes..."
        apk update
        APK_UPDATED=1
      fi
      log "Installing packages via apk: ${pkgs[*]}"
      apk add --no-cache "${pkgs[@]}"
      ;;
    apt)
      if [ "$APT_UPDATED" -eq 0 ]; then
        log "Updating apt package lists..."
        apt-get update -y
        APT_UPDATED=1
      fi
      log "Installing packages via apt: ${pkgs[*]}"
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    dnf|microdnf)
      if [ "$RPM_UPDATED" -eq 0 ]; then
        log "Refreshing dnf repositories..."
        $PKG_MANAGER -y makecache
        RPM_UPDATED=1
      fi
      log "Installing packages via $PKG_MANAGER: ${pkgs[*]}"
      $PKG_MANAGER install -y "${pkgs[@]}"
      ;;
    yum)
      if [ "$RPM_UPDATED" -eq 0 ]; then
        log "Refreshing yum repositories..."
        yum -y makecache
        RPM_UPDATED=1
      fi
      log "Installing packages via yum: ${pkgs[*]}"
      yum install -y "${pkgs[@]}"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MANAGER" in
    apt)
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb || true
      ;;
    dnf|microdnf)
      $PKG_MANAGER clean all -y || true
      rm -rf /var/cache/dnf || true
      ;;
    yum)
      yum clean all -y || true
      rm -rf /var/cache/yum || true
      ;;
    apk)
      # apk uses --no-cache; nothing to clean
      true
      ;;
  esac
}

#-------------------------
# FFmpeg installation helper
#-------------------------
ensure_ffmpeg() {
  # Proactively clear spotdl-managed FFmpeg caches to avoid interactive prompts in CI (recursive and robust)
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/spotdl" "${XDG_DATA_HOME:-$HOME/.local/share}/spotdl" "$HOME/.spotdl" 2>/dev/null || true
  rm -rf "$HOME/.spotdl/ffmpeg" "$HOME/.spotdl/ffmpeg-*" "$HOME/.cache/spotdl/ffmpeg" "$HOME/.cache/spotdl/ffmpeg-*" "${XDG_CONFIG_HOME:-$HOME/.config}/spotdl/ffmpeg" 2>/dev/null || true
  rm -rf ~/.spotdl/ffmpeg* ~/.cache/spotdl/ffmpeg* ~/.local/share/spotdl/ffmpeg* 2>/dev/null || true
  python3 - <<'PY' || true
import os, shutil, glob
removed = 0
bases = []
bases.append(os.path.expanduser('~/.spotdl'))
bases.append(os.path.expanduser('~/.cache/spotdl'))
bases.append(os.path.expanduser('~/.config/spotdl'))
xdg_cache = os.environ.get('XDG_CACHE_HOME')
if xdg_cache:
    bases.append(os.path.join(os.path.expanduser(xdg_cache), 'spotdl'))
seen = set()
for base in bases:
    if not os.path.isdir(base):
        continue
    patterns = [
        os.path.join(base, 'ffmpeg*'),
        os.path.join(base, '**', 'ffmpeg*'),
        os.path.join(base, 'ffprobe*'),
        os.path.join(base, '**', 'ffprobe*'),
    ]
    for pat in patterns:
        for path in glob.glob(pat, recursive=True):
            if path in seen:
                continue
            seen.add(path)
            try:
                if os.path.isdir(path):
                    shutil.rmtree(path, ignore_errors=True)
                else:
                    os.remove(path)
                removed += 1
            except Exception:
                pass
print(f"spotdl ffmpeg artifacts removed: {removed}")
PY

  if command -v ffmpeg >/dev/null 2>&1 && ffmpeg -version >/dev/null 2>&1; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ffmpeg aria2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ffmpeg aria2 || dnf install -y ffmpeg || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y ffmpeg aria2 || yum install -y ffmpeg || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ffmpeg aria2 || apk add --no-cache ffmpeg
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm ffmpeg aria2
  else
    echo "No supported package manager found to install ffmpeg/aria2" >&2
    exit 1
  fi

  # Verify installation strictly
  ffmpeg -version >/dev/null 2>&1 || { echo "ffmpeg installation failed" >&2; exit 1; }
}

#-------------------------
# Base tools
#-------------------------
install_base_tools() {
  case "$PKG_MANAGER" in
    apk)
      install_packages ca-certificates curl git tar unzip xz build-base pkgconf bash shadow su-exec
      update-ca-certificates || true
      ;;
    apt)
      install_packages ca-certificates curl git tar unzip xz-utils pkg-config build-essential gnupg
      ;;
    dnf|microdnf)
      install_packages ca-certificates curl git tar unzip xz pkgconfig make gcc gcc-c++ which shadow-utils
      update-ca-trust || true
      ;;
    yum)
      install_packages ca-certificates curl git tar unzip xz pkgconfig make gcc gcc-c++ which shadow-utils
      update-ca-trust || true
      ;;
  esac
}

#-------------------------
# User and permissions
#-------------------------
ensure_app_user() {
  if [ "$CREATE_APP_USER" = "true" ]; then
    if id -u "$APP_USER" >/dev/null 2>&1; then
      log "User '$APP_USER' already exists"
    else
      case "$PKG_MANAGER" in
        apk)
          addgroup -g "$APP_GID" -S "$APP_USER" 2>/dev/null || true
          adduser -S -D -H -u "$APP_UID" -G "$APP_USER" "$APP_USER" 2>/dev/null || true
          ;;
        apt|dnf|microdnf|yum)
          groupadd -g "$APP_GID" -f "$APP_USER" 2>/dev/null || true
          useradd -M -N -s /usr/sbin/nologin -u "$APP_UID" -g "$APP_GID" "$APP_USER" 2>/dev/null || true
          ;;
      esac
      log "Created user '$APP_USER' (uid:$APP_UID gid:$APP_GID)"
    fi
    chown -R "$APP_UID:$APP_GID" "$APP_DIR" || true
  else
    log "Using current user (likely root) for setup; set CREATE_APP_USER=true to create non-root user"
  fi
}

#-------------------------
# Project detection
#-------------------------
has_file() { [ -f "$APP_DIR/$1" ]; }
has_dir() { [ -d "$APP_DIR/$1" ]; }

detect_stack() {
  PROJECT_STACK=""
  if has_file "requirements.txt" || has_file "pyproject.toml" || has_file "Pipfile" || has_file "setup.py"; then
    PROJECT_STACK="python"
  fi
  if has_file "package.json"; then
    PROJECT_STACK="${PROJECT_STACK:+$PROJECT_STACK,}node"
  fi
  if has_file "Gemfile"; then
    PROJECT_STACK="${PROJECT_STACK:+$PROJECT_STACK,}ruby"
  fi
  if has_file "go.mod" || has_file "go.sum"; then
    PROJECT_STACK="${PROJECT_STACK:+$PROJECT_STACK,}go"
  fi
  if has_file "pom.xml" || has_file "build.gradle" || has_file "build.gradle.kts" || has_file "gradlew"; then
    PROJECT_STACK="${PROJECT_STACK:+$PROJECT_STACK,}java"
  fi
  if has_file "composer.json"; then
    PROJECT_STACK="${PROJECT_STACK:+$PROJECT_STACK,}php"
  fi
  if has_file "Cargo.toml"; then
    PROJECT_STACK="${PROJECT_STACK:+$PROJECT_STACK,}rust"
  fi
  if ls "$APP_DIR"/*.sln >/dev/null 2>&1 || ls "$APP_DIR"/*.csproj >/dev/null 2>&1; then
    PROJECT_STACK="${PROJECT_STACK:+$PROJECT_STACK,}dotnet"
  fi
  if [ -z "$PROJECT_STACK" ]; then
    PROJECT_STACK="generic"
  fi
  log "Detected stack(s): $PROJECT_STACK"
}

#-------------------------
# Runtime installers
#-------------------------
install_python_runtime() {
  case "$PKG_MANAGER" in
    apk) install_packages python3 py3-pip python3-dev musl-dev ;;
    apt) install_packages python3 python3-pip python3-venv python3-dev ;;
    dnf|microdnf|yum) install_packages python3 python3-pip python3-devel ;;
  esac
}

install_node_runtime() {
  case "$PKG_MANAGER" in
    apk) install_packages nodejs npm ;;
    apt) install_packages nodejs npm ;;
    dnf|microdnf|yum) install_packages nodejs npm || warn "NodeJS not available in repos; consider using a Node base image" ;;
  esac
}

install_ruby_runtime() {
  case "$PKG_MANAGER" in
    apk) install_packages ruby ruby-dev build-base ;;
    apt) install_packages ruby-full build-essential zlib1g-dev ;;
    dnf|microdnf|yum) install_packages ruby ruby-devel redhat-rpm-config make gcc gcc-c++ zlib-devel ;;
  esac
}

install_go_runtime() {
  case "$PKG_MANAGER" in
    apk) install_packages go ;;
    apt) install_packages golang ;;
    dnf|microdnf|yum) install_packages golang ;;
  esac
}

install_java_runtime() {
  case "$PKG_MANAGER" in
    apk) install_packages openjdk17-jre-headless maven gradle ;;
    apt) install_packages openjdk-17-jdk-headless maven gradle ;;
    dnf|microdnf|yum) install_packages java-17-openjdk-headless maven gradle || install_packages java-17-openjdk-headless maven ;;
  esac
}

install_php_runtime() {
  case "$PKG_MANAGER" in
    apk) install_packages php php-cli php-phar php-mbstring php-xml php-zip composer ;;
    apt) install_packages php-cli php-mbstring php-xml php-zip curl unzip && { install_packages composer || true; } ;;
    dnf|microdnf|yum) install_packages php-cli php-mbstring php-xml php-zip curl unzip || true ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer (manual)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
      && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
      && rm -f composer-setup.php
  fi
}

install_rust_runtime() {
  case "$PKG_MANAGER" in
    apk) install_packages rust cargo ;;
    apt) install_packages rustc cargo ;;
    dnf|microdnf|yum) install_packages rust cargo ;;
  esac
}

install_dotnet_runtime() {
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK already installed"
    return
  fi
  log "Installing .NET SDK via official installer"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  chmod +x /tmp/dotnet-install.sh
  DOTNET_VERSION="${DOTNET_VERSION:-latest}"
  /tmp/dotnet-install.sh --install-dir /usr/share/dotnet --channel LTS || /tmp/dotnet-install.sh --install-dir /usr/share/dotnet --version "$DOTNET_VERSION" || true
  ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet || true
}

#-------------------------
# Dependency installers
#-------------------------
setup_python() {
  [ -z "${SETUP_PYTHON:-}" ] || [ "$SETUP_PYTHON" != "true" ] && return 0
  log "Setting up Python environment"
  install_python_runtime
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1

  VENV_DIR="$APP_DIR/.venv"
  if [ ! -f "$VENV_DIR/bin/activate" ]; then
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1090
  . "$VENV_DIR/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel poetry

  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "$APP_DIR/requirements.txt"
  fi

  if has_file "pyproject.toml"; then
    if has_file "poetry.lock"; then
      log "Installing Python dependencies via Poetry"
      pip install "poetry>=1.6"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi $( [ "$APP_ENV" = "production" ] && echo "--without=dev" )
      # Ensure the current project is installed and CLI is available in the venv
      pip install -e "$APP_DIR" || true
    else
      # PEP 517/518 project; try installing project deps
      log "Installing Python project (PEP 517) in editable mode if possible"
      pip install -e "$APP_DIR" || pip install "$APP_DIR"
    fi
  fi

  # Hardening for spotdl: prefer YouTube provider with standalone yt-dlp and system ffmpeg
  if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y ffmpeg curl; elif command -v yum >/dev/null 2>&1; then yum install -y epel-release && yum install -y ffmpeg curl || yum install -y curl; elif command -v apk >/dev/null 2>&1; then apk add --no-cache ffmpeg curl; else echo "No supported package manager found for installing ffmpeg and curl"; fi
  # Clear any spotdl-managed ffmpeg caches to avoid interactive prompts
  rm -rf ~/.spotdl/ffmpeg ~/.spotdl/ffprobe ~/.cache/spotdl/ffmpeg ~/.cache/spotdl/ffprobe ~/.config/spotdl/ffmpeg ~/.config/spotdl/ffprobe ~/.local/share/spotdl/ffmpeg ~/.local/share/spotdl/ffprobe ${XDG_CACHE_HOME:-~/.cache}/spotdl/ffmpeg ${XDG_CACHE_HOME:-~/.cache}/spotdl/ffprobe ${XDG_DATA_HOME:-~/.local/share}/spotdl/ffmpeg ${XDG_DATA_HOME:-~/.local/share}/spotdl/ffprobe ${XDG_CONFIG_HOME:-~/.config}/spotdl/ffmpeg ${XDG_CONFIG_HOME:-~/.config}/spotdl/ffprobe || true
  # Install standalone yt-dlp binary and make executable
  curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp
  # Configure spotdl to use plain YouTube provider and the standalone yt-dlp
  mkdir -p ~/.config/spotdl && cat > ~/.config/spotdl/config.json << 'EOF'
{ "audio_providers": ["youtube"], "yt_dlp_path": "/usr/local/bin/yt-dlp", "ffmpeg": "/usr/bin/ffmpeg", "ffprobe": "/usr/bin/ffprobe", "max_connections": 4, "threads": 4 }
EOF
  mkdir -p ~/.spotdl && cp -f ~/.config/spotdl/config.json ~/.spotdl/config.json
  # Remove ytmusicapi caches to avoid stale headers/parsers
  rm -rf ~/.local/share/ytmusicapi ~/.cache/ytmusicapi || true
  # Ensure pip tooling is up-to-date and (re)install current project
  python3 -m pip install --upgrade --no-input pip setuptools wheel
  python3 -m pip install -e . || python3 -m pip install .
  SPOTDL_BIN="$(command -v spotdl || true)" && PY="$(dirname "$SPOTDL_BIN")/python" && if [ -n "$SPOTDL_BIN" ] && [ -x "$PY" ]; then "$PY" -m pip install --upgrade --no-cache-dir ytmusicapi yt-dlp; else python3 -m pip install --upgrade --no-cache-dir ytmusicapi yt-dlp; fi

  # Ensure ffmpeg is installed non-interactively for spotdl and other tools
  ensure_ffmpeg

  # Common envs
  if has_file "app.py" || grep -qi "flask" "$APP_DIR/requirements.txt" 2>/dev/null; then
    export FLASK_APP="${FLASK_APP:-app.py}"
    export FLASK_ENV="${FLASK_ENV:-$APP_ENV}"
    export FLASK_RUN_PORT="${FLASK_RUN_PORT:-$DEFAULT_PORT_FLASK}"
  fi
}

setup_node() {
  [ -z "${SETUP_NODE:-}" ] || [ "$SETUP_NODE" != "true" ] && return 0
  log "Setting up Node.js environment"
  install_node_runtime
  export NODE_ENV="${NODE_ENV:-$APP_ENV}"
  pushd "$APP_DIR" >/dev/null
  if has_file "package.json"; then
    if has_file "yarn.lock" && command -v yarn >/dev/null 2>&1; then
      log "Installing Node dependencies via yarn"
      yarn install --frozen-lockfile
    elif has_file "pnpm-lock.yaml" && command -v pnpm >/dev/null 2>&1; then
      log "Installing Node dependencies via pnpm"
      pnpm install --frozen-lockfile
    elif has_file "package-lock.json"; then
      log "Installing Node dependencies via npm ci"
      npm ci $( [ "$APP_ENV" = "production" ] && echo "--omit=dev" )
    else
      log "Installing Node dependencies via npm install"
      npm install $( [ "$APP_ENV" = "production" ] && echo "--omit=dev" )
    fi
  fi
  popd >/dev/null
}

setup_ruby() {
  [ -z "${SETUP_RUBY:-}" ] || [ "$SETUP_RUBY" != "true" ] && return 0
  log "Setting up Ruby environment"
  install_ruby_runtime
  if command -v gem >/dev/null 2>&1; then
    gem update --system || true
    gem install bundler --no-document || true
  fi
  if has_file "Gemfile"; then
    pushd "$APP_DIR" >/dev/null
    bundle config set path 'vendor/bundle'
    if has_file "Gemfile.lock"; then
      bundle install --jobs "$(nproc)" --retry 3 --without development test || bundle install
    else
      bundle install --jobs "$(nproc)" --retry 3 || bundle install
    fi
    popd >/dev/null
  fi
}

setup_go() {
  [ -z "${SETUP_GO:-}" ] || [ "$SETUP_GO" != "true" ] && return 0
  log "Setting up Go environment"
  install_go_runtime
  if has_file "go.mod"; then
    pushd "$APP_DIR" >/dev/null
    go mod download
    popd >/dev/null
  fi
}

setup_java() {
  [ -z "${SETUP_JAVA:-}" ] || [ "$SETUP_JAVA" != "true" ] && return 0
  log "Setting up Java environment"
  install_java_runtime
  pushd "$APP_DIR" >/dev/null
  if has_file "pom.xml"; then
    mvn -B -q -DskipTests dependency:go-offline || true
  fi
  if has_file "gradlew"; then
    chmod +x gradlew
    ./gradlew --no-daemon -x test tasks >/dev/null 2>&1 || true
  elif has_file "build.gradle" || has_file "build.gradle.kts"; then
    if ! command -v gradle >/dev/null 2>&1; then
      warn "Gradle not found; attempting minimal wrapper bootstrap"
    else
      gradle --no-daemon -x test tasks >/dev/null 2>&1 || true
    fi
  fi
  popd >/dev/null
}

setup_php() {
  [ -z "${SETUP_PHP:-}" ] || [ "$SETUP_PHP" != "true" ] && return 0
  log "Setting up PHP environment"
  install_php_runtime
  if has_file "composer.json"; then
    pushd "$APP_DIR" >/dev/null
    if has_file "composer.lock"; then
      composer install --no-interaction $( [ "$APP_ENV" = "production" ] && echo "--no-dev --optimize-autoloader" )
    else
      composer install --no-interaction $( [ "$APP_ENV" = "production" ] && echo "--no-dev --optimize-autoloader" )
    fi
    popd >/dev/null
  fi
}

setup_rust() {
  [ -z "${SETUP_RUST:-}" ] || [ "$SETUP_RUST" != "true" ] && return 0
  log "Setting up Rust environment"
  install_rust_runtime
  if has_file "Cargo.toml"; then
    pushd "$APP_DIR" >/dev/null
    cargo fetch || true
    popd >/dev/null
  fi
}

setup_dotnet() {
  [ -z "${SETUP_DOTNET:-}" ] || [ "$SETUP_DOTNET" != "true" ] && return 0
  log "Setting up .NET environment"
  install_dotnet_runtime
  if command -v dotnet >/dev/null 2>&1; then
    pushd "$APP_DIR" >/dev/null
    if ls *.sln >/dev/null 2>&1; then
      dotnet restore || true
    elif ls *.csproj >/dev/null 2>&1; then
      dotnet restore *.csproj || true
    fi
    popd >/dev/null
  else
    warn ".NET SDK not found after installation attempt"
  fi
}

#-------------------------
# Environment configuration
#-------------------------
write_env_profile() {
  local profile=/etc/profile.d/app_env.sh
  log "Writing environment profile to $profile"
  {
    echo "# Generated by setup script"
    echo "export APP_DIR=\"$APP_DIR\""
    echo "export APP_ENV=\"${APP_ENV}\""
    echo "export PYTHONUNBUFFERED=\${PYTHONUNBUFFERED:-1}"
    echo "export PIP_NO_CACHE_DIR=\${PIP_NO_CACHE_DIR:-1}"
    echo "export NODE_ENV=\${NODE_ENV:-${APP_ENV}}"
    echo "export COMPOSER_ALLOW_SUPERUSER=1"
    # PATH additions
    echo "export PATH=\"$APP_DIR/.venv/bin:\$PATH\""
    echo "if [ -d \"/usr/share/dotnet\" ]; then export DOTNET_ROOT=\"/usr/share/dotnet\"; export PATH=\"/usr/share/dotnet:\$PATH\"; fi"
    echo "if [ -d \"\$HOME/.cargo/bin\" ]; then export PATH=\"\$HOME/.cargo/bin:\$PATH\"; fi"
  } > "$profile"
}

#-------------------------
# Shell auto-activation for Python virtualenv
#-------------------------
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local venv_path="$APP_DIR/.venv/bin/activate"
  local activate_line=". \"$venv_path\""
  mkdir -p "$(dirname "$bashrc_file")"
  if [ -f "$venv_path" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

write_dotenv() {
  local dotenv="$APP_DIR/.env"
  if [ -f "$dotenv" ]; then
    log ".env already exists; skipping creation"
    return 0
  fi

  local default_port="$DEFAULT_PORT_GENERIC"
  if [[ "$PROJECT_STACK" == *python* ]]; then
    if has_file "app.py" || (has_file "requirements.txt" && grep -qi "flask" "$APP_DIR/requirements.txt" 2>/dev/null); then
      default_port="$DEFAULT_PORT_FLASK"
    else
      default_port="$DEFAULT_PORT_PY"
    fi
  elif [[ "$PROJECT_STACK" == *node* ]]; then
    default_port="$DEFAULT_PORT_NODE"
  elif [[ "$PROJECT_STACK" == *php* ]]; then
    default_port="$DEFAULT_PORT_PHP"
  elif [[ "$PROJECT_STACK" == *java* ]]; then
    default_port="$DEFAULT_PORT_JAVA"
  elif [[ "$PROJECT_STACK" == *go* ]]; then
    default_port="$DEFAULT_PORT_GO"
  elif [[ "$PROJECT_STACK" == *ruby* ]]; then
    default_port="$DEFAULT_PORT_RUBY"
  elif [[ "$PROJECT_STACK" == *dotnet* ]]; then
    default_port="$DEFAULT_PORT_DOTNET"
  elif [[ "$PROJECT_STACK" == *rust* ]]; then
    default_port="$DEFAULT_PORT_RUST"
  fi

  log "Creating default .env file"
  {
    echo "APP_ENV=$APP_ENV"
    echo "PORT=${PORT:-$default_port}"
    echo "HOST=0.0.0.0"
  } > "$dotenv"
}

#-------------------------
# Docker image ensure for spotdl
#-------------------------
ensure_spotdl_docker_image() {
  if command -v docker >/dev/null 2>&1; then
    sh -lc 'if docker image inspect spotdl >/dev/null 2>&1; then docker rm -f spotdl-fix >/dev/null 2>&1 || true; docker create --name spotdl-fix spotdl sh -lc "sleep infinity" >/dev/null; docker start spotdl-fix >/dev/null; docker exec spotdl-fix sh -lc "python3 -m pip install -U pip setuptools wheel && (python3 -m pip install -e /app || python3 -m pip install /app) && python3 -m pip install -U yt-dlp ytmusicapi || true"; docker exec spotdl-fix sh -lc "if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y ffmpeg; elif command -v apk >/dev/null 2>&1; then apk add --no-cache ffmpeg; elif command -v yum >/dev/null 2>&1; then yum install -y epel-release && yum install -y ffmpeg || yum install -y ffmpeg; elif command -v dnf >/dev/null 2>&1; then dnf install -y ffmpeg; else echo No pkg mgr; fi || true"; docker commit spotdl-fix spotdl >/dev/null; docker rm -f spotdl-fix >/dev/null; fi'
  fi
}

#-------------------------
# Project directories
#-------------------------
setup_directories() {
  log "Ensuring project directories exist"
  mkdir -p "$APP_DIR"
  mkdir -p "$APP_DIR/log" "$APP_DIR/tmp" "$APP_DIR/.cache"
  if [[ "$PROJECT_STACK" == *python* ]]; then
    mkdir -p "$APP_DIR/.venv"
  fi
  if [ "$CREATE_APP_USER" = "true" ]; then
    chown -R "$APP_UID:$APP_GID" "$APP_DIR" || true
  fi
}

#-------------------------
# Main
#-------------------------
main() {
  log "Starting environment setup in $APP_DIR"
  detect_pkg_manager
  install_base_tools
  ensure_app_user
  detect_stack
  setup_directories

  # Activate per-stack setup flags (auto-enable if detected)
  SETUP_PYTHON=false
  SETUP_NODE=false
  SETUP_RUBY=false
  SETUP_GO=false
  SETUP_JAVA=false
  SETUP_PHP=false
  SETUP_RUST=false
  SETUP_DOTNET=false

  [[ "$PROJECT_STACK" == *python* ]] && SETUP_PYTHON=true
  [[ "$PROJECT_STACK" == *node* ]] && SETUP_NODE=true
  [[ "$PROJECT_STACK" == *ruby* ]] && SETUP_RUBY=true
  [[ "$PROJECT_STACK" == *go* ]] && SETUP_GO=true
  [[ "$PROJECT_STACK" == *java* ]] && SETUP_JAVA=true
  [[ "$PROJECT_STACK" == *php* ]] && SETUP_PHP=true
  [[ "$PROJECT_STACK" == *rust* ]] && SETUP_RUST=true
  [[ "$PROJECT_STACK" == *dotnet* ]] && SETUP_DOTNET=true

  # Execute per-stack setups
  setup_python
  setup_auto_activate
  setup_node
  setup_ruby
  setup_go
  setup_java
  setup_php
  setup_rust
  setup_dotnet

  write_env_profile
  write_dotenv
  ensure_spotdl_docker_image

  pkg_cleanup

  log "Environment setup complete."
  log "Summary:"
  log " - APP_DIR: $APP_DIR"
  log " - APP_ENV: $APP_ENV"
  if [ -f "$APP_DIR/.env" ]; then
    log " - .env created with default PORT ($(grep -E '^PORT=' "$APP_DIR/.env" | cut -d= -f2))"
  fi
  log "You can now run your application using your project's start command inside this container."
}

main "$@"