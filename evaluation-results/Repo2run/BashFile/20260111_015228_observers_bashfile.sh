#!/bin/bash
# Universal project environment setup script for containerized environments
# - Detects technology stack from project files
# - Installs appropriate runtimes and system dependencies
# - Configures directories, permissions, and environment variables
# - Idempotent and safe to run multiple times
# Designed to run as root inside Docker containers (no sudo)

set -Eeuo pipefail
IFS=$'\n\t'

# -------------------------
# Configurable defaults
# -------------------------
APP_DIR="${APP_DIR:-/app}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
APP_USER="${APP_USER:-}"        # Optional: set to create and use a non-root user (e.g., "appuser")
APP_UID="${APP_UID:-}"          # Optional UID for APP_USER
APP_GID="${APP_GID:-}"          # Optional GID for APP_USER
TZ="${TZ:-UTC}"                 # Timezone
LANG="${LANG:-C.UTF-8}"         # Locale
# If true, will attempt to install only detected stacks; otherwise installs a base set of build tools.
MINIMAL_INSTALL="${MINIMAL_INSTALL:-true}"

# -------------------------
# Logging and error handling
# -------------------------
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
}

warn() {
    echo "[WARN $(date +'%Y-%m-%dT%H:%M:%S%z')] $*" >&2
}

err() {
    echo "[ERROR $(date +'%Y-%m-%dT%H:%M:%S%z')] $*" >&2
}

cleanup() {
    # Placeholder for cleanup actions if needed
    :
}

failure() {
    err "Setup failed at line ${BASH_LINENO[0]} in ${FUNCNAME[1]:-main}. See logs above."
}
trap cleanup EXIT
trap failure ERR

# -------------------------
# Package manager detection
# -------------------------
PKG_MGR=""
PM_UPDATE=""
PM_INSTALL=""
PM_GROUP_DEPS=""
PM_CA_CERTS=""
PM_UNZIP=""
PM_TZDATA=""
PM_GIT=""
PM_CURL=""
PM_BUILD_ESSENTIAL=""

detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
        PM_UPDATE="apt-get update -y"
        PM_INSTALL="apt-get install -y --no-install-recommends"
        PM_GROUP_DEPS="build-essential"
        PM_CA_CERTS="ca-certificates"
        PM_UNZIP="unzip"
        PM_TZDATA="tzdata"
        PM_GIT="git"
        PM_CURL="curl"
        PM_BUILD_ESSENTIAL="build-essential"
        # Ensure noninteractive for tzdata etc.
        export DEBIAN_FRONTEND=noninteractive
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
        PM_UPDATE="apk update"
        PM_INSTALL="apk add --no-cache"
        PM_GROUP_DEPS="build-base"
        PM_CA_CERTS="ca-certificates"
        PM_UNZIP="unzip"
        PM_TZDATA="tzdata"
        PM_GIT="git"
        PM_CURL="curl"
        PM_BUILD_ESSENTIAL="build-base"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
        PM_UPDATE="dnf -y update"
        PM_INSTALL="dnf -y install"
        PM_GROUP_DEPS="@development-tools"
        PM_CA_CERTS="ca-certificates"
        PM_UNZIP="unzip"
        PM_TZDATA="tzdata"
        PM_GIT="git"
        PM_CURL="curl"
        PM_BUILD_ESSENTIAL="@development-tools"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
        PM_UPDATE="yum -y update"
        PM_INSTALL="yum -y install"
        PM_GROUP_DEPS="@Development tools"
        PM_CA_CERTS="ca-certificates"
        PM_UNZIP="unzip"
        PM_TZDATA="tzdata"
        PM_GIT="git"
        PM_CURL="curl"
        PM_BUILD_ESSENTIAL="@Development tools"
    else
        err "No supported package manager found (apt, apk, dnf, yum)."
        exit 1
    fi
    log "Detected package manager: $PKG_MGR"
}

pm_update_once() {
    # Use a marker file to avoid repeated updates in idempotent runs
    local marker="/var/lib/.env_setup_pm_updated"
    if [[ ! -f "$marker" ]]; then
        log "Updating package index..."
        eval "$PM_UPDATE"
        touch "$marker"
    else
        log "Package index already updated earlier; skipping."
    fi
}

pm_install_safe() {
    # Install packages if available; ignore if already installed
    # Usage: pm_install_safe pkg1 pkg2 ...
    local pkgs=("$@")
    if [[ "${#pkgs[@]}" -eq 0 ]]; then return 0; fi
    log "Installing system packages: ${pkgs[*]}"
    set +e
    # Ensure packages are space-separated during expansion (IFS may not include space)
    local __old_ifs="$IFS"
    IFS=' '
    eval "$PM_INSTALL ${pkgs[*]}"
    local rc=$?
    IFS="$__old_ifs"
    set -e
    if [[ $rc -ne 0 ]]; then
        warn "Some packages may have failed to install or are unavailable; continuing where possible."
    fi
}

# -------------------------
# Base system setup
# -------------------------
setup_base_system() {
    detect_pkg_mgr
    pm_update_once

    # Common base tools
    local base_tools=("$PM_CA_CERTS" "$PM_TZDATA" "$PM_UNZIP" "$PM_GIT" "$PM_CURL")
    if [[ "$PKG_MGR" == "apt" ]]; then
        base_tools+=("gnupg" "lsb-release" "procps")
    elif [[ "$PKG_MGR" == "apk" ]]; then
        base_tools+=("bash" "shadow" "procps" "tzdata")
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        base_tools+=("hostname" "procps-ng")
    fi
    pm_install_safe "${base_tools[@]}"

    # Build essentials (compilers, make, etc.)
    if [[ "$PKG_MGR" == "apt" ]]; then
        pm_install_safe "$PM_BUILD_ESSENTIAL" "pkg-config" "libssl-dev" "libffi-dev"
    elif [[ "$PKG_MGR" == "apk" ]]; then
        pm_install_safe "$PM_BUILD_ESSENTIAL" "pkgconfig" "openssl-dev" "libffi-dev"
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        pm_install_safe "gcc" "gcc-c++" "make" "openssl-devel" "libffi-devel"
    fi

    # Timezone and locale
    if [[ "$PKG_MGR" == "apt" ]]; then
        ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
        dpkg-reconfigure -f noninteractive tzdata || true
        # Ensure locale packages where possible
        pm_install_safe "locales" || true
        sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
        locale-gen || true
    elif [[ "$PKG_MGR" == "apk" ]]; then
        ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
        echo "$TZ" > /etc/timezone || true
    fi

    log "Base system setup completed."
}

# -------------------------
# Project directory and user management
# -------------------------
setup_project_dir() {
    log "Setting up project directory at $APP_DIR"
    mkdir -p "$APP_DIR"
    chmod 755 "$APP_DIR"

    # If running outside of APP_DIR, move known project files into APP_DIR (idempotent)
    # Only perform copy if APP_DIR is empty and current dir is not APP_DIR
    if [[ "$(pwd)" != "$APP_DIR" ]]; then
        if [[ -z "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
            log "Copying project files into $APP_DIR"
            shopt -s dotglob
            cp -R ./* "$APP_DIR"/ || true
            shopt -u dotglob
        else
            log "$APP_DIR already contains files; not copying."
        fi
    fi

    # Optional non-root user creation
    if [[ -n "$APP_USER" ]]; then
        log "Ensuring application user '$APP_USER' exists"
        if ! id -u "$APP_USER" >/dev/null 2>&1; then
            if command -v useradd >/dev/null 2>&1; then
                if [[ -n "$APP_UID" && -n "$APP_GID" ]]; then
                    groupadd -g "$APP_GID" "$APP_USER" 2>/dev/null || true
                    useradd -u "$APP_UID" -g "$APP_GID" -m -s /bin/bash "$APP_USER"
                else
                    useradd -m -s /bin/bash "$APP_USER"
                fi
            elif command -v adduser >/dev/null 2>&1; then
                adduser -D "$APP_USER" || true
            fi
        fi
        chown -R "$APP_USER":"${APP_GID:-$APP_USER}" "$APP_DIR" || true
    fi
}

# -------------------------
# Stack detection
# -------------------------
STACKS=()

detect_stacks() {
    cd "$APP_DIR"

    # Python
    if [[ -f "requirements.txt" || -f "pyproject.toml" || -f "Pipfile" ]]; then
        STACKS+=("python")
    fi

    # Node.js
    if [[ -f "package.json" ]]; then
        STACKS+=("node")
    fi

    # Ruby
    if [[ -f "Gemfile" ]]; then
        STACKS+=("ruby")
    fi

    # PHP
    if [[ -f "composer.json" ]]; then
        STACKS+=("php")
    fi

    # Java
    if [[ -f "pom.xml" || -f "build.gradle" || -f "build.gradle.kts" || -f "gradlew" ]]; then
        STACKS+=("java")
    fi

    # Go
    if [[ -f "go.mod" || -f "go.sum" ]]; then
        STACKS+=("go")
    fi

    # Rust
    if [[ -f "Cargo.toml" ]]; then
        STACKS+=("rust")
    fi

    # .NET (limited support)
    if compgen -G "*.csproj" >/dev/null || compgen -G "*.sln" >/dev/null; then
        STACKS+=("dotnet")
    fi

    log "Detected stacks: ${STACKS[*]:-none}"
}

# -------------------------
# Runtime installers
# -------------------------
install_python() {
    log "Installing Python runtime and dependencies"
    if [[ "$PKG_MGR" == "apt" ]]; then
        pm_install_safe "python3" "python3-venv" "python3-pip" "python3-dev"
    elif [[ "$PKG_MGR" == "apk" ]]; then
        pm_install_safe "python3" "py3-pip" "py3-virtualenv"
        # Ensure python3 -m venv works
        pm_install_safe "python3-dev" || true
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        pm_install_safe "python3" "python3-pip" "python3-devel"
    fi

    # Create venv idempotently
    cd "$APP_DIR"
    if [[ ! -d ".venv" ]]; then
        log "Creating Python virtual environment at $APP_DIR/.venv"
        python3 -m venv ".venv"
    else
        log "Python virtual environment already exists; skipping creation."
    fi

    # Upgrade pip and install deps
    log "Installing Python dependencies"
    # shellcheck disable=SC1091
    source ".venv/bin/activate"
    python -m pip install --upgrade pip wheel setuptools
    if [[ -f "requirements.txt" ]]; then
        python -m pip install -r requirements.txt
    elif [[ -f "pyproject.toml" ]]; then
        # Prefer building with pip
        python -m pip install .
    elif [[ -f "Pipfile" ]]; then
        python -m pip install pipenv
        pipenv install --deploy || pipenv install
    fi
    deactivate || true

    # Framework-specific env defaults
    if [[ -f "app.py" ]]; then
        if grep -qi "flask" requirements.txt 2>/dev/null || grep -qi "from flask" app.py 2>/dev/null; then
            APP_PORT="${APP_PORT:-5000}"
            echo "FLASK_APP=${FLASK_APP:-app.py}" >> "$APP_DIR/.env.tmp"
            echo "FLASK_ENV=${FLASK_ENV:-production}" >> "$APP_DIR/.env.tmp"
            echo "FLASK_RUN_PORT=${FLASK_RUN_PORT:-$APP_PORT}" >> "$APP_DIR/.env.tmp"
        fi
    fi
    if [[ -f "manage.py" ]]; then
        APP_PORT="${APP_PORT:-8000}"
        echo "DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE:-}" >> "$APP_DIR/.env.tmp"
        echo "DJANGO_DEBUG=${DJANGO_DEBUG:-false}" >> "$APP_DIR/.env.tmp"
    fi
}

# Ensure PDM is installed via pipx for Python projects
install_pdm() {
    log "Ensuring PDM is installed and on PATH"
    # Ensure prerequisites
    if [[ "$PKG_MGR" == "apt" ]]; then
        set +e
        apt-get update && apt-get install -y --no-install-recommends python3 python3-pip python3-venv curl wget ca-certificates unzip git && rm -rf /var/lib/apt/lists/*
        set -e
    else
        pm_install_safe "python3" "python3-pip" "curl" "unzip" "$PM_CA_CERTS" "git"
    fi

    # Configure caches to avoid hishel SQLite locks and disable pip cache
    mkdir -p /tmp/.cache || true
    export HISHEL_DISABLE=1
    export PIP_NO_CACHE_DIR=1
    export XDG_CACHE_HOME=/tmp/.cache
    # Persist these in /etc/environment for future shells
    for kv in HISHEL_DISABLE=1 PIP_NO_CACHE_DIR=1 XDG_CACHE_HOME=/tmp/.cache; do
        grep -qxF "$kv" /etc/environment 2>/dev/null || echo "$kv" >> /etc/environment
    done
    # Purge any stale PDM/Hishel caches that might hold SQLite locks
    for D in /root /home/*; do
        [ -d "$D" ] || continue
        rm -rf "$D/.cache/hishel" "$D/.cache/pdm" "$D/.local/state/pdm"
    done
    rm -rf /tmp/.cache/hishel /tmp/.cache/pdm || true

    # Install uv (fast Python package manager) for wheel prefetch
    if ! command -v uv >/dev/null 2>&1; then
        curl -LsSf https://astral.sh/uv/install.sh | sh -s -- -y || true
        if [[ -x "$HOME/.local/bin/uv" && ! -x "/usr/local/bin/uv" ]]; then
            ln -sf "$HOME/.local/bin/uv" /usr/local/bin/uv
        fi
    fi

    # Install PDM via pip
    set +e
    python3 -m pip install -U --no-cache-dir pdm --break-system-packages
    local pdm_install_rc=$?
    if [[ $pdm_install_rc -ne 0 ]]; then
        python3 -m pip install -U --no-cache-dir --user pdm
    fi
    set -e

    # Ensure pdm is on PATH
    if [[ -x "$HOME/.local/bin/pdm" && ! -x "/usr/local/bin/pdm" ]]; then
        ln -sf "$HOME/.local/bin/pdm" /usr/local/bin/pdm
    fi
    # Also link from Python user base to ensure availability
    ln -sf "$(python3 -m site --user-base)/bin/pdm" /usr/local/bin/pdm || true

    if command -v pdm >/dev/null 2>&1; then
        pdm --version || true
        # Configure pip to prefer predownloaded wheels
        mkdir -p /opt/wheelhouse
        { echo "[global]"; echo "find-links = /opt/wheelhouse"; echo "only-binary = :all:"; } > /etc/pip.conf
        # Export dependencies and prefetch wheels with uv if project uses PDM/pyproject
        cd "$APP_DIR"
        if [[ -f "pyproject.toml" ]]; then
            set +e
            pdm export -f requirements -o requirements.txt --dev || pdm export -f requirements -o requirements.txt
            set -e
        fi
        if [[ -f "requirements.txt" ]] && command -v uv >/dev/null 2>&1; then
            uv pip download -r requirements.txt -o /opt/wheelhouse || warn "uv prefetch failed; continuing."
        fi
    fi
}

install_duckdb_cli() {
    # Install DuckDB CLI if missing
    if command -v duckdb >/dev/null 2>&1; then
        return 0
    fi
    log "Installing DuckDB CLI"
    # Ensure prerequisites
    if [[ "$PKG_MGR" == "apt" ]]; then
        set +e
        apt-get update && apt-get install -y wget unzip ca-certificates
        set -e
    else
        pm_install_safe "wget" "unzip" "$PM_CA_CERTS"
    fi

    # Install DuckDB CLI from latest release matching architecture
    set +e
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) FILE=duckdb_cli-linux-amd64.zip ;;
        aarch64|arm64) FILE=duckdb_cli-linux-arm64.zip ;;
        *) FILE=duckdb_cli-linux-amd64.zip ;;
    esac
    URL="https://github.com/duckdb/duckdb/releases/latest/download/$FILE"
    rm -f /tmp/duckdb.zip
    if wget -q -O /tmp/duckdb.zip "$URL" && unzip -o /tmp/duckdb.zip -d /usr/local/bin; then
        chmod +x /usr/local/bin/duckdb || true
    else
        warn "DuckDB CLI installation failed; continuing without CLI."
    fi
    set -e
}

install_node() {
    log "Installing Node.js runtime and dependencies"
    if [[ "$PKG_MGR" == "apt" ]]; then
        pm_install_safe "nodejs" "npm"
    elif [[ "$PKG_MGR" == "apk" ]]; then
        pm_install_safe "nodejs" "npm"
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        pm_install_safe "nodejs" "npm"
    fi

    cd "$APP_DIR"
    if [[ -f ".nvmrc" ]]; then
        warn ".nvmrc detected but nvm is not installed in container; using system Node.js."
    fi

    # Install dependencies idempotently
    if [[ -f "package.json" ]]; then
        if [[ -f "package-lock.json" ]]; then
            log "Running npm ci"
            npm ci --no-audit --no-fund
        else
            log "Running npm install"
            npm install --no-audit --no-fund
        fi
        # Set common env vars
        echo "NODE_ENV=${NODE_ENV:-production}" >> "$APP_DIR/.env.tmp"
        # Detect common web frameworks to set default port
        if jq -r '.dependencies // {} | has("express")' package.json >/dev/null 2>&1; then
            APP_PORT="${APP_PORT:-3000}"
        fi
    fi
}

install_ruby() {
    log "Installing Ruby runtime and dependencies"
    if [[ "$PKG_MGR" == "apt" ]]; then
        pm_install_safe "ruby-full" "ruby-dev"
    elif [[ "$PKG_MGR" == "apk" ]]; then
        pm_install_safe "ruby" "ruby-dev"
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        pm_install_safe "ruby" "ruby-devel"
    fi
    # Ensure build tools for native gems
    if [[ "$PKG_MGR" == "apt" ]]; then
        pm_install_safe "$PM_BUILD_ESSENTIAL"
    elif [[ "$PKG_MGR" == "apk" ]]; then
        pm_install_safe "$PM_BUILD_ESSENTIAL"
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        pm_install_safe "gcc" "make"
    fi

    cd "$APP_DIR"
    if ! command -v gem >/dev/null 2>&1; then
        warn "Ruby gem not found; skipping bundle install."
        return 0
    fi
    if ! gem query -i -n bundler >/dev/null 2>&1; then
        gem install bundler --no-document
    fi
    if [[ -f "Gemfile" ]]; then
        bundle config set without 'development test' || true
        bundle install --jobs=4 --retry=3
        echo "RACK_ENV=${RACK_ENV:-production}" >> "$APP_DIR/.env.tmp"
        # Rails default port
        if grep -qi "rails" Gemfile 2>/dev/null; then
            APP_PORT="${APP_PORT:-3000}"
        fi
    fi
}

install_php() {
    log "Installing PHP runtime and Composer"
    if [[ "$PKG_MGR" == "apt" ]]; then
        pm_install_safe "php-cli" "php-mbstring" "php-xml" "php-curl" "php-zip" "unzip"
    elif [[ "$PKG_MGR" == "apk" ]]; then
        pm_install_safe "php" "php-cli" "php-mbstring" "php-xml" "php-openssl" "php-json" "php-phar"
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        pm_install_safe "php-cli" "php-json" "php-mbstring" "php-xml" "unzip"
    fi

    # Install Composer if not present
    if ! command -v composer >/dev/null 2>&1; then
        log "Installing Composer"
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
    fi

    cd "$APP_DIR"
    if [[ -f "composer.json" ]]; then
        composer install --no-interaction --prefer-dist --no-progress
        echo "APP_ENV=${APP_ENV}" >> "$APP_DIR/.env.tmp"
        APP_PORT="${APP_PORT:-8000}"
    fi
}

install_java() {
    log "Installing Java runtime and build tools"
    if [[ "$PKG_MGR" == "apt" ]]; then
        pm_install_safe "openjdk-17-jdk" "maven" "gradle"
    elif [[ "$PKG_MGR" == "apk" ]]; then
        pm_install_safe "openjdk17-jdk" "maven" "gradle"
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        pm_install_safe "java-17-openjdk-devel" "maven" "gradle"
    fi

    cd "$APP_DIR"
    if [[ -f "pom.xml" ]]; then
        log "Priming Maven dependencies (go-offline)"
        mvn -B -q -ntp dependency:go-offline || warn "Maven go-offline failed; continuing."
        APP_PORT="${APP_PORT:-8080}"
    fi
    if [[ -f "gradlew" ]]; then
        chmod +x gradlew
        ./gradlew --no-daemon build -x test || warn "Gradle build failed; continuing."
        APP_PORT="${APP_PORT:-8080}"
    elif [[ -f "build.gradle" || -f "build.gradle.kts" ]]; then
        gradle --no-daemon build -x test || warn "Gradle build failed; continuing."
        APP_PORT="${APP_PORT:-8080}"
    fi
}

install_go() {
    log "Installing Go runtime"
    if [[ "$PKG_MGR" == "apt" ]]; then
        pm_install_safe "golang"
    elif [[ "$PKG_MGR" == "apk" ]]; then
        pm_install_safe "go"
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        pm_install_safe "golang"
    fi

    cd "$APP_DIR"
    if [[ -f "go.mod" ]]; then
        log "Fetching Go module dependencies"
        go mod download || warn "go mod download failed; continuing."
        APP_PORT="${APP_PORT:-8080}"
    fi
}

install_rust() {
    log "Installing Rust toolchain (rustup)"
    if ! command -v curl >/dev/null 2>&1; then
        pm_install_safe "$PM_CURL"
    fi
    if [[ ! -d "/root/.cargo" && ! -d "/home/${APP_USER}/.cargo" ]]; then
        curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
        sh /tmp/rustup.sh -y --default-toolchain stable
        rm -f /tmp/rustup.sh
        export PATH="/root/.cargo/bin:${PATH}"
    fi
    cd "$APP_DIR"
    if [[ -f "Cargo.toml" ]]; then
        log "Fetching Rust crate dependencies"
        cargo fetch || warn "cargo fetch failed; continuing."
        APP_PORT="${APP_PORT:-8080}"
    fi
}

install_dotnet() {
    log "Attempting .NET SDK installation (limited support)"
    # Due to distro variability, attempt best-effort install
    if [[ "$PKG_MGR" == "apt" ]]; then
        # Install Microsoft package repo
        pm_install_safe "wget" "apt-transport-https"
        wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || \
        wget -q https://packages.microsoft.com/config/debian/11/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb || true
        if [[ -f /tmp/packages-microsoft-prod.deb ]]; then
            dpkg -i /tmp/packages-microsoft-prod.deb || true
            rm -f /tmp/packages-microsoft-prod.deb
            pm_update_once
            pm_install_safe "dotnet-sdk-7.0" || pm_install_safe "dotnet-sdk-6.0"
        else
            warn "Could not configure Microsoft package repo; skipping .NET install."
        fi
    elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
        pm_install_safe "dotnet-sdk-7.0" || pm_install_safe "dotnet-sdk-6.0" || warn ".NET SDK not available in repo."
    else
        warn ".NET SDK installation not supported for this base image."
    fi

    cd "$APP_DIR"
    if compgen -G "*.csproj" >/dev/null; then
        dotnet restore || warn "dotnet restore failed; continuing."
        APP_PORT="${APP_PORT:-8080}"
    fi
}

# -------------------------
# Environment configuration
# -------------------------
configure_env() {
    cd "$APP_DIR"
    # Create .env with defaults if not present; merge temporary env entries
    touch "$APP_DIR/.env.tmp"
    {
        echo "APP_DIR=$APP_DIR"
        echo "APP_ENV=$APP_ENV"
        echo "APP_PORT=$APP_PORT"
        echo "TZ=$TZ"
        echo "LANG=$LANG"
    } >> "$APP_DIR/.env.tmp"

    if [[ ! -f "$APP_DIR/.env" ]]; then
        log "Creating .env file with defaults"
        mv "$APP_DIR/.env.tmp" "$APP_DIR/.env"
    else
        log "Merging new environment entries into existing .env"
        # Append missing keys only
        while IFS='=' read -r key val; do
            [[ -z "$key" ]] && continue
            if ! grep -q "^${key}=" "$APP_DIR/.env"; then
                echo "${key}=${val}" >> "$APP_DIR/.env"
            fi
        done < "$APP_DIR/.env.tmp"
        rm -f "$APP_DIR/.env.tmp"
    fi

    # Permissions
    chmod 640 "$APP_DIR/.env" || true
    if [[ -n "$APP_USER" ]]; then
        chown "$APP_USER":"${APP_GID:-$APP_USER}" "$APP_DIR/.env" || true
    fi

    # PATH adjustments for Python venv
    if [[ -d "$APP_DIR/.venv" ]]; then
        echo "PATH=$APP_DIR/.venv/bin:\$PATH" >> "$APP_DIR/.profile"
    fi

    log "Environment configuration completed."
}

# -------------------------
# Base install (optional)
# -------------------------
install_base_dev_tools() {
    if [[ "$MINIMAL_INSTALL" != "true" ]]; then
        log "Installing additional development tools (non-minimal mode)"
        if [[ "$PKG_MGR" == "apt" ]]; then
            pm_install_safe "jq" "zip" "tar" "sed" "grep"
        elif [[ "$PKG_MGR" == "apk" ]]; then
            pm_install_safe "jq" "zip" "tar" "sed" "grep"
        elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
            pm_install_safe "jq" "zip" "tar" "sed" "grep"
        fi
    fi
}

# -------------------------
# Main
# -------------------------
main() {
    log "Starting universal environment setup"
    setup_base_system
    setup_project_dir
    detect_stacks
    install_base_dev_tools

    # Ensure PDM and DuckDB CLI are available if Python project detected
    if [[ " ${STACKS[*]} " == *" python "* ]]; then
        install_pdm
        install_duckdb_cli
    fi

    # Install detected runtimes
    for s in "${STACKS[@]}"; do
        case "$s" in
            python) install_python ;;
            node) install_node ;;
            ruby) install_ruby ;;
            php) install_php ;;
            java) install_java ;;
            go) install_go ;;
            rust) install_rust ;;
            dotnet) install_dotnet ;;
            *) warn "Unknown stack '$s' detected; skipping." ;;
        esac
    done

    configure_env

    log "Environment setup completed successfully."
    log "Project directory: $APP_DIR"
    log "Detected stacks: ${STACKS[*]:-none}"
    log "Default app port: ${APP_PORT}"
    log "To run common project types:"
    log "- Python Flask: source $APP_DIR/.venv/bin/activate && python app.py"
    log "- Python Django: source $APP_DIR/.venv/bin/activate && python manage.py runserver 0.0.0.0:${APP_PORT}"
    log "- Node.js: npm start (or node server.js) with PORT=${APP_PORT}"
    log "- Ruby on Rails: bundle exec rails server -b 0.0.0.0 -p ${APP_PORT}"
    log "- PHP (built-in): php -S 0.0.0.0:${APP_PORT} -t public"
    log "- Java Spring Boot: java -jar target/*.jar --server.port=${APP_PORT}"
    log "- Go: go run ."
    log "- Rust: cargo run"
    log "- .NET: dotnet run --urls=http://0.0.0.0:${APP_PORT}"
}

main "$@"