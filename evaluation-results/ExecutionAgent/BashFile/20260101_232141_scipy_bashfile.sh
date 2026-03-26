#!/bin/bash
# Universal project environment setup script for containerized execution
# Designed to auto-detect common stacks and configure environment inside Docker
# Safe to run multiple times (idempotent) and with root user (no sudo required)

set -Eeuo pipefail

# Globals
readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
readonly APP_DIR_DEFAULT="/app"
readonly APP_USER_DEFAULT="app"
readonly APP_GROUP_DEFAULT="app"
readonly ENV_FILE_DEFAULT=".env"
readonly CONTAINER_ENV_FILE_DEFAULT=".container_env"
readonly DEBIAN_FRONTEND="noninteractive" # for apt-based distros
umask 022

# Colors (disable if not a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()  { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
info()  { echo -e "${BLUE}$*${NC}"; }

cleanup() { :; }
on_error() {
  local exit_code=$?
  error "Script '${SCRIPT_NAME}' failed at line ${BASH_LINENO[0]} with exit code ${exit_code}"
  exit "$exit_code"
}
trap cleanup EXIT
trap on_error ERR

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "This script must run as root inside the container."
    exit 1
  fi
}

# Detect package manager and set commands
PKG_MGR=""
PM_UPDATE=""
PM_INSTALL=""
PM_CLEAN=""
PM_EXTRA_SETUP=""
detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PM_UPDATE="apt-get update -y"
    PM_INSTALL="apt-get install -y --no-install-recommends"
    PM_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
    PM_EXTRA_SETUP="apt-get -y upgrade || true"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PM_UPDATE="apk update"
    PM_INSTALL="apk add --no-cache"
    PM_CLEAN=": # apk uses --no-cache"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PM_UPDATE="dnf -y update"
    PM_INSTALL="dnf -y install"
    PM_CLEAN="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PM_UPDATE="yum -y update"
    PM_INSTALL="yum -y install"
    PM_CLEAN="yum clean all"
  else
    warn "No supported package manager detected. System package installation will be skipped."
    PKG_MGR=""
  fi
}

# Run PM command safely
pm_update()  { [ -n "$PKG_MGR" ] && eval "$PM_UPDATE"; }
pm_clean()   { [ -n "$PKG_MGR" ] && eval "$PM_CLEAN"; }
pm_install() {
  if [ -n "$PKG_MGR" ]; then
    # shellcheck disable=SC2086
    eval "$PM_INSTALL $*"
  else
    warn "Package manager not available; cannot install: $*"
    return 1
  fi
}

# Create app user/group if not present (idempotent)
ensure_app_user() {
  local user="${APP_USER:-$APP_USER_DEFAULT}"
  local group="${APP_GROUP:-$APP_GROUP_DEFAULT}"
  local uid="${APP_UID:-1000}"
  local gid="${APP_GID:-1000}"

  if ! getent group "$group" >/dev/null 2>&1; then
    log "Creating group '$group' with GID $gid"
    groupadd -g "$gid" "$group" || groupadd "$group" || true
  else
    log "Group '$group' already exists"
  fi

  if ! id "$user" >/dev/null 2>&1; then
    log "Creating user '$user' with UID $uid"
    useradd -m -u "$uid" -g "$group" -s /bin/bash "$user" || useradd -m -g "$group" "$user" || true
  else
    log "User '$user' already exists"
  fi
}

# Setup directories and permissions
setup_directories() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  mkdir -p "$app_dir" "$app_dir/logs" "$app_dir/tmp"
  # Common cache/build folders if present
  mkdir -p "$app_dir/.cache" "$app_dir/.local" "$app_dir/.config" "$app_dir/.tools"

  # Ownership for app runtime directories
  local user="${APP_USER:-$APP_USER_DEFAULT}"
  local group="${APP_GROUP:-$APP_GROUP_DEFAULT}"
  chown -R "$user:$group" "$app_dir"
  chmod -R u+rwX,go+rX "$app_dir"
  log "Project directories prepared at '${app_dir}'"
}

# Source and export env vars from .env if present (idempotent)
load_env_file() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local env_file="${ENV_FILE:-$ENV_FILE_DEFAULT}"
  local env_path="$app_dir/$env_file"
  if [ -f "$env_path" ]; then
    log "Loading environment variables from $env_path"
    # Export only non-comment lines key=value
    while IFS= read -r line; do
      case "$line" in
        ''|\#*) continue ;;
        *'='*)
          key="${line%%=*}"
          val="${line#*=}"
          # Trim quotes
          val="${val%\"}"
          val="${val#\"}"
          val="${val%\'}"
          val="${val#\'}"
          export "$key=$val"
          ;;
      esac
    done < "$env_path"
  else
    warn "No $env_file found at $app_dir; using defaults."
  fi
}

# Write container environment file
write_container_env() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local env_out="${CONTAINER_ENV_FILE:-$CONTAINER_ENV_FILE_DEFAULT}"
  local out_path="$app_dir/$env_out"
  local user="${APP_USER:-$APP_USER_DEFAULT}"

  : "${APP_ENV:=production}"
  : "${PORT:=8080}"
  : "${LOG_LEVEL:=info}"

  {
    echo "# Generated container environment ($(date))"
    echo "APP_ENV=${APP_ENV}"
    echo "PORT=${PORT}"
    echo "LOG_LEVEL=${LOG_LEVEL}"
    echo "APP_DIR=${APP_DIR:-$APP_DIR_DEFAULT}"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  } > "$out_path"
  chown "$user:${APP_GROUP:-$APP_GROUP_DEFAULT}" "$out_path"
  chmod 0644 "$out_path"
  log "Container environment written to $out_path"
}

# Install baseline system tools useful across stacks
install_baseline_tools() {
  detect_package_manager
  if [ -n "$PKG_MGR" ]; then
    log "Installing baseline system packages with $PKG_MGR"
    pm_update || true
    [ -n "$PM_EXTRA_SETUP" ] && eval "$PM_EXTRA_SETUP" || true
    case "$PKG_MGR" in
      apt)
        pm_install ca-certificates curl gnupg build-essential git pkg-config libssl-dev libffi-dev locales
        # locale setup (avoid warnings)
        if command -v locale-gen >/dev/null 2>&1; then
          sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
          locale-gen || true
        fi
        ;;
      apk)
        pm_install bash curl git build-base openssl-dev libffi-dev
        ;;
      dnf|yum)
        pm_install ca-certificates curl gnupg2 git gcc gcc-c++ make openssl-devel libffi-devel
        ;;
    esac
    pm_clean || true
  fi
}

# Python setup
setup_python() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local requirements="$app_dir/requirements.txt"
  local pyproject="$app_dir/pyproject.toml"
  local venv_dir="$app_dir/.venv"

  if [ -f "$requirements" ] || [ -f "$pyproject" ] || compgen -G "$app_dir/*.py" >/dev/null 2>&1; then
    log "Python project detected"
    detect_package_manager
    case "$PKG_MGR" in
      apt) pm_update; pm_install python3 python3-venv python3-pip python3-dev python3-pybind11 pybind11-dev build-essential gfortran pkg-config libopenblas-dev liblapack-dev cmake ninja-build meson patchelf; pm_clean ;;
      apk) pm_install python3 py3-pip python3-dev build-base; ;;
      dnf|yum) pm_install python3 python3-pip python3-devel gcc gcc-c++ make; ;;
      "") warn "Cannot install Python runtime automatically (no package manager).";;
    esac
    # Ensure pip build isolation is disabled globally to allow builds to find pybind11 and other tools
    if [ "$PKG_MGR" = "apt" ]; then
      apt-get update -y && apt-get install -y --no-install-recommends python3-pip || true
    fi
    bash -lc 'set -e; mkdir -p /root/.config/pip; printf "[global]\nno-build-isolation = true\n" > /etc/pip.conf; printf "[global]\nno-build-isolation = true\n" > /root/.config/pip/pip.conf; printf "export PIP_NO_BUILD_ISOLATION=1\n" > /etc/profile.d/pip_no_isolation.sh; chmod 0644 /etc/profile.d/pip_no_isolation.sh'
    

    if ! command -v python3 >/dev/null 2>&1; then
      error "Python3 is not available after installation attempt."
      return 1
    fi

    if [ ! -d "$venv_dir" ]; then
      log "Creating Python virtual environment at $venv_dir"
      bash -lc 'set -e; test -d /app/.venv || python3 -m venv /app/.venv'
    else
      log "Python virtual environment already exists at $venv_dir"
    fi

    # shellcheck disable=SC1090
    source "$venv_dir/bin/activate"
    /app/.venv/bin/python -m pip install -U pip setuptools wheel numpy==2.4.0 "pybind11>=2.13.2" cython meson meson-python ninja pythran asv

    if [ -f "$requirements" ]; then
      log "Installing Python dependencies from requirements.txt"
      python -m pip install -r "$requirements"
    elif [ -f "$pyproject" ]; then
      if grep -q "\[tool.pip\]" "$pyproject" 2>/dev/null || true; then
        log "Installing Python project via pip (pyproject)"
        # Initialize git submodules if the project is a git checkout
        if [ -d "$app_dir/.git" ]; then
          log "Initializing git submodules in $app_dir"
          git config --global --add safe.directory "$app_dir" || true
          git -C "$app_dir" submodule update --init --recursive || warn "Git submodule initialization failed"
        else
          log "No git repository at $app_dir, skipping submodule init"
        fi
        # Skipping pip wrapper; using explicit 'python -m pip --no-build-isolation' instead
: # skipping dirname wrapper cleanup
: # skipping pip wrapper creation; flag will be passed directly
test -d /app/build && rm -rf /app/build || true
env PATH="/app/.venv/bin:$PATH" PYBIND11_CONFIG="/app/.venv/bin/pybind11-config" PIP_NO_BUILD_ISOLATION=1 /app/.venv/bin/python -m pip install --no-build-isolation -e /app
        log "Verifying SciPy import and native modules"
        /app/.venv/bin/python - <<'PY' || true
import scipy, numpy; import scipy.linalg, scipy.sparse; print('SciPy:', scipy.__version__, 'NumPy:', numpy.__version__)
PY
      else
        log "Installing Python build dependencies for PEP 517"
        python -m pip install build
        python -m build "$app_dir" || warn "PEP 517 build failed; trying editable install"
        test -d /app/build && rm -rf /app/build || true
        env PATH="/app/.venv/bin:$PATH" PYBIND11_CONFIG="/app/.venv/bin/pybind11-config" PIP_NO_BUILD_ISOLATION=1 /app/.venv/bin/python -m pip install --no-build-isolation -e /app
        log "Verifying SciPy import and native modules"
        /app/.venv/bin/python - <<'PY' || true
import scipy, numpy; import scipy.linalg, scipy.sparse; print('SciPy:', scipy.__version__, 'NumPy:', numpy.__version__)
PY
      fi
    else
      log "No requirements or pyproject found; skipping dependency install"
    fi

    # Common env for Flask/Django/FastAPI (best effort defaults)
    : "${PYTHONUNBUFFERED:=1}"
    export PYTHONUNBUFFERED
    # Setup ASV configuration at project root and initialize machine (non-interactive)
    log "Setting up ASV configuration"
    pushd "$app_dir" >/dev/null
    if [ -f "benchmarks/asv.conf.json" ]; then
      ln -sf "benchmarks/asv.conf.json" "asv.conf.json" || true
    fi
    if [ ! -f "asv.conf.json" ]; then
      cat > "asv.conf.json" <<'EOF'
{
  "benchmark_dir": "benchmarks",
  "repo": ".",
  "environment_type": "virtualenv",
  "env_dir": ".asv/env",
  "results_dir": ".asv/results",
  "html_dir": ".asv/html",
  "branches": ["main"]
}
EOF
    fi
    "$venv_dir/bin/python" -m asv machine --yes || warn "ASV machine initialization failed"
    popd >/dev/null
    # Simple SciPy import/version check
    "$venv_dir/bin/python" - <<'PY' || true
import scipy
print(scipy.__version__)
PY
    log "Python setup complete"
  else
    info "No Python files detected; skipping Python setup."
  fi
}

# Node.js setup
setup_node() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local pkg_json="$app_dir/package.json"
  if [ -f "$pkg_json" ]; then
    log "Node.js project detected"
    detect_package_manager
    case "$PKG_MGR" in
      apt)
        pm_update
        # Install Node via NodeSource LTS to ensure a modern version
        if ! command -v node >/dev/null 2>&1; then
          curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
          pm_install nodejs
        else
          log "Node.js already installed"
        fi
        pm_install build-essential python3 make g++ git
        pm_clean
        ;;
      apk)
        pm_install nodejs npm python3 make g++ git
        ;;
      dnf|yum)
        pm_install nodejs npm python3 make gcc gcc-c++ git
        ;;
      "")
        warn "Cannot install Node.js runtime automatically (no package manager)."
        ;;
    esac

    if ! command -v npm >/dev/null 2>&1; then
      error "npm is not available after installation attempt."
      return 1
    fi

    pushd "$app_dir" >/dev/null
    if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
      log "Installing Node dependencies with npm ci"
      npm ci --no-audit --no-fund
    else
      log "Installing Node dependencies with npm install"
      npm install --no-audit --no-fund
    fi
    # Build if script exists
    if jq -e '.scripts.build' package.json >/dev/null 2>&1; then
      log "Running npm run build"
      npm run build || warn "npm build failed; continuing"
    fi
    popd >/dev/null

    # Common env defaults
    : "${NODE_ENV:=production}"
    export NODE_ENV
    log "Node.js setup complete"
  else
    info "No package.json detected; skipping Node.js setup."
  fi
}

# Ruby setup
setup_ruby() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local gemfile="$app_dir/Gemfile"
  if [ -f "$gemfile" ]; then
    log "Ruby project detected"
    detect_package_manager
    case "$PKG_MGR" in
      apt) pm_update; pm_install ruby-full build-essential git; pm_clean ;;
      apk) pm_install ruby ruby-dev build-base git; ;;
      dnf|yum) pm_install ruby ruby-devel gcc gcc-c++ make git; ;;
      "") warn "Cannot install Ruby runtime (no package manager).";;
    esac

    if ! command -v gem >/dev/null 2>&1; then
      error "Ruby gem tool is not available."
      return 1
    fi

    gem install --no-document bundler || true
    pushd "$app_dir" >/dev/null
    if [ -f Gemfile.lock ]; then
      log "Installing Ruby gems with bundler (deployment mode)"
      bundler config set --local path 'vendor/bundle'
      bundler install --without development test || bundler install
    else
      log "Installing Ruby gems with bundler"
      bundler config set --local path 'vendor/bundle'
      bundler install || true
    fi
    popd >/dev/null
    log "Ruby setup complete"
  else
    info "No Gemfile detected; skipping Ruby setup."
  fi
}

# Go setup
setup_go() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local go_mod="$app_dir/go.mod"
  if [ -f "$go_mod" ]; then
    log "Go project detected"
    detect_package_manager
    case "$PKG_MGR" in
      apt) pm_update; pm_install golang git; pm_clean ;;
      apk) pm_install go git; ;;
      dnf|yum) pm_install golang git; ;;
      "") warn "Cannot install Go runtime (no package manager).";;
    esac
    if ! command -v go >/dev/null 2>&1; then
      error "Go is not available."
      return 1
    fi
    pushd "$app_dir" >/dev/null
    log "Downloading Go modules"
    go mod download || warn "go mod download failed"
    popd >/dev/null
    log "Go setup complete"
  else
    info "No go.mod detected; skipping Go setup."
  fi
}

# Java setup (Maven/Gradle)
setup_java() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local pom="$app_dir/pom.xml"
  local gradle="$app_dir/build.gradle"
  local gradle_kts="$app_dir/build.gradle.kts"
  if [ -f "$pom" ] || [ -f "$gradle" ] || [ -f "$gradle_kts" ]; then
    log "Java project detected"
    detect_package_manager
    case "$PKG_MGR" in
      apt) pm_update; pm_install openjdk-17-jdk maven; pm_clean ;;
      apk) pm_install openjdk17 maven; ;;
      dnf|yum) pm_install java-17-openjdk-devel maven; ;;
      "") warn "Cannot install Java runtime (no package manager).";;
    esac
    if [ -f "$pom" ]; then
      log "Resolving Maven dependencies"
      mvn -f "$pom" -B -DskipTests dependency:resolve || warn "Maven resolve failed"
    fi
    if [ -f "$gradle" ] || [ -f "$gradle_kts" ]; then
      if [ -x "$app_dir/gradlew" ]; then
        log "Resolving Gradle dependencies using wrapper"
        pushd "$app_dir" >/dev/null
        ./gradlew --no-daemon tasks || true
        popd >/dev/null
      else
        detect_package_manager
        case "$PKG_MGR" in
          apt) pm_install gradle; pm_clean ;;
          apk) pm_install gradle ;;
          dnf|yum) pm_install gradle ;;
        esac
        log "Resolving Gradle dependencies"
        gradle -b "${gradle:-$gradle_kts}" --no-daemon tasks || true
      fi
    fi
    log "Java setup complete"
  else
    info "No pom.xml/gradle build files detected; skipping Java setup."
  fi
}

# PHP setup
setup_php() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local composer_json="$app_dir/composer.json"
  if [ -f "$composer_json" ]; then
    log "PHP project detected"
    detect_package_manager
    case "$PKG_MGR" in
      apt)
        pm_update
        pm_install php-cli php-mbstring php-xml php-curl php-zip curl git unzip
        if ! command -v composer >/dev/null 2>&1; then
          log "Installing Composer"
          curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
          php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
          rm -f /tmp/composer-setup.php
        fi
        pm_clean
        ;;
      apk)
        pm_install php81 php81-cli php81-phar php81-mbstring php81-xml php81-curl php81-zip curl git unzip
        if ! command -v composer >/dev/null 2>&1; then
          curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
          php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
          rm -f /tmp/composer-setup.php
        fi
        ;;
      dnf|yum)
        pm_install php-cli php-mbstring php-xml php-curl php-zip curl git unzip
        if ! command -v composer >/dev/null 2>&1; then
          curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
          php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
          rm -f /tmp/composer-setup.php
        fi
        ;;
      "")
        warn "Cannot install PHP runtime (no package manager)."
        ;;
    esac
    pushd "$app_dir" >/dev/null
    log "Installing PHP dependencies with Composer"
    composer install --no-interaction --prefer-dist --no-progress
    popd >/dev/null
    log "PHP setup complete"
  else
    info "No composer.json detected; skipping PHP setup."
  fi
}

# Rust setup
setup_rust() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local cargo="$app_dir/Cargo.toml"
  if [ -f "$cargo" ]; then
    log "Rust project detected"
    detect_package_manager
    case "$PKG_MGR" in
      apt) pm_update; pm_install cargo rustc build-essential; pm_clean ;;
      apk) pm_install cargo rust; ;;
      dnf|yum) pm_install cargo rust; ;;
      "") warn "Cannot install Rust toolchain (no package manager).";;
    esac
    if ! command -v cargo >/dev/null 2>&1; then
      error "Cargo is not available."
      return 1
    fi
    pushd "$app_dir" >/dev/null
    log "Fetching Rust dependencies"
    cargo fetch || warn "cargo fetch failed"
    popd >/dev/null
    log "Rust setup complete"
  else
    info "No Cargo.toml detected; skipping Rust setup."
  fi
}

# .NET setup (limited; apt-based only for SDK install)
setup_dotnet() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local csproj="$(find "$app_dir" -maxdepth 2 -name '*.csproj' -print -quit || true)"
  if [ -n "$csproj" ] || [ -f "$app_dir/global.json" ]; then
    log ".NET project detected"
    detect_package_manager
    case "$PKG_MGR" in
      apt)
        pm_update
        if ! command -v dotnet >/dev/null 2>&1; then
          log "Installing .NET SDK via Microsoft package repo"
          curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb || \
          curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb || true
          if [ -f /tmp/packages-microsoft-prod.deb ]; then
            dpkg -i /tmp/packages-microsoft-prod.deb || true
            rm -f /tmp/packages-microsoft-prod.deb
            apt-get update -y || true
            pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || pm_install dotnet-sdk-6.0 || true
          else
            warn "Unable to download Microsoft packages; skipping .NET SDK install."
          fi
        fi
        pm_clean
        ;;
      *)
        warn "Automatic .NET SDK installation only supported on apt-based images in this script."
        ;;
    esac
    if command -v dotnet >/dev/null 2>&1; then
      pushd "$app_dir" >/dev/null
      log "Restoring .NET dependencies"
      dotnet restore || warn "dotnet restore failed"
      popd >/dev/null
    fi
    log ".NET setup complete"
  else
    info "No .NET project files detected; skipping .NET setup."
  fi
}

# Determine default port heuristics based on stack files
detect_port() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  # If PORT already set in environment/.env, keep it
  if [ -n "${PORT:-}" ]; then
    log "Using existing PORT=${PORT}"
    return 0
  fi
  local port_guess="8080"
  if [ -f "$app_dir/requirements.txt" ] || compgen -G "$app_dir/*.py" >/dev/null 2>&1; then
    port_guess="5000"
  elif [ -f "$app_dir/package.json" ]; then
    port_guess="3000"
    # Try to parse if a port is specified inside package.json scripts (best effort)
    if command -v jq >/dev/null 2>&1; then
      local pkg_port
      pkg_port="$(jq -r '.. | objects | .PORT? // empty' "$app_dir/package.json" 2>/dev/null || true)"
      if [ -n "$pkg_port" ] && [[ "$pkg_port" =~ ^[0-9]+$ ]]; then
        port_guess="$pkg_port"
      fi
    fi
  elif [ -f "$app_dir/pom.xml" ] || [ -f "$app_dir/build.gradle" ] || [ -f "$app_dir/build.gradle.kts" ]; then
    port_guess="8080"
  elif [ -f "$app_dir/composer.json" ]; then
    port_guess="8000"
  fi
  export PORT="$port_guess"
  log "Default PORT set to ${PORT}"
}

# PATH setup, include venv if exists
setup_path() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local venv_dir="$app_dir/.venv"
  local tool_paths="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if [ -d "$venv_dir" ]; then
    export PATH="$venv_dir/bin:$tool_paths"
  else
    export PATH="$tool_paths"
  fi
}

# Auto-activate Python virtual environment for interactive shells
setup_auto_activate() {
  local app_dir="${APP_DIR:-$APP_DIR_DEFAULT}"
  local venv_dir="$app_dir/.venv"
  local activate_line="if [ -r $venv_dir/bin/activate ]; then . $venv_dir/bin/activate; fi"

  # /etc/profile.d script for all shells
  local profile_script="/etc/profile.d/auto_venv.sh"
  if ! grep -qF "$activate_line" "$profile_script" 2>/dev/null; then
    {
      echo "# Auto-activate project venv if present"
      echo "$activate_line"
    } > "$profile_script"
    chmod 0644 "$profile_script"
  fi

  # Root user's bashrc
  local root_bashrc="/root/.bashrc"
  touch "$root_bashrc"
  if ! grep -qF "$venv_dir/bin/activate" "$root_bashrc" 2>/dev/null; then
    echo "$activate_line" >> "$root_bashrc"
  fi

  # App user's bashrc (if user exists)
  local user="${APP_USER:-$APP_USER_DEFAULT}"
  if id "$user" >/dev/null 2>&1; then
    local user_home="/home/$user"
    mkdir -p "$user_home"
    local user_bashrc="$user_home/.bashrc"
    touch "$user_bashrc"
    if ! grep -qF "$venv_dir/bin/activate" "$user_bashrc" 2>/dev/null; then
      echo "$activate_line" >> "$user_bashrc"
    fi
    chown "$user:$user" "$user_bashrc"
  fi
}

# Main execution
main() {
  require_root

  # Determine app directory (use current directory if /app doesn't exist)
  if [ -z "${APP_DIR:-}" ]; then
    if [ -d "$APP_DIR_DEFAULT" ]; then
      export APP_DIR="$APP_DIR_DEFAULT"
    else
      export APP_DIR="$(pwd)"
    fi
  fi
  log "Starting environment setup at ${START_TIME}"
  log "Project directory: ${APP_DIR}"

  install_baseline_tools
  ensure_app_user
  setup_directories
  load_env_file
  detect_port
  setup_path

  # Run stack-specific setup
  setup_python
  # Ensure interactive shells auto-activate the venv
  setup_auto_activate
  setup_node
  setup_ruby
  setup_go
  setup_java
  setup_php
  setup_rust
  setup_dotnet

  write_container_env

  log "Environment setup completed successfully!"
  info "Notes:"
  info "- To use Python virtual environment: source '${APP_DIR}/.venv/bin/activate'"
  info "- Environment variables file: '${APP_DIR}/${CONTAINER_ENV_FILE:-$CONTAINER_ENV_FILE_DEFAULT}'"
  info "- Default port: ${PORT}"
}

# Execute
main "$@"