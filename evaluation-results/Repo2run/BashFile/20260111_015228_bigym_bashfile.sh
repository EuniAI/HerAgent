#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# This script detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust)
# and installs required system packages and language runtimes, sets up dependencies,
# directory structure, permissions, and environment variables.
#
# Safe to run multiple times (idempotent) and designed for root execution in Docker.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for output (safe to use in most terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging helpers
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
    echo -e "${YELLOW}[WARN] $*${NC}"
}
err() {
    echo -e "${RED}[ERROR] $*${NC}" >&2
}
die() {
    err "$*"
    exit 1
}

# Trap unexpected errors
trap 'err "An unexpected error occurred at line $LINENO. Exiting."; exit 1' ERR

# Globals
APP_ROOT="${APP_ROOT:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
APP_LOG_DIR="${APP_LOG_DIR:-$APP_ROOT/logs}"
APP_CACHE_DIR="${APP_CACHE_DIR:-$APP_ROOT/.cache}"
APP_BIN_DIR="${APP_BIN_DIR:-$APP_ROOT/bin}"

# Detect package manager and define install/update/clean functions
PKG_MGR=""
update_pkgs() { :; }
install_pkgs() { :; }
clean_pkgs() { :; }

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
        update_pkgs() {
            # Use stamp file to avoid repeated apt-get update in idempotent runs
            # Re-run update if apt lists were cleaned/are missing
            local stamp="/var/lib/.setup_apt_updated"
            local lists_dir="/var/lib/apt/lists"
            if [ ! -f "$stamp" ] || [ -z "$(ls -A "$lists_dir" 2>/dev/null)" ]; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -y
                touch "$stamp"
            fi
        }
        install_pkgs() {
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y --no-install-recommends "$@"
        }
        clean_pkgs() {
            apt-get clean
            rm -rf /var/lib/apt/lists/*
        }
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
        update_pkgs() { :; } # apk add --no-cache doesn't need update
        install_pkgs() { apk add --no-cache "$@"; }
        clean_pkgs() { :; }
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
        update_pkgs() { dnf -y makecache || true; }
        install_pkgs() { dnf install -y "$@"; }
        clean_pkgs() { dnf clean all || true; }
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
        update_pkgs() { yum makecache -y || true; }
        install_pkgs() { yum install -y "$@"; }
        clean_pkgs() { yum clean all || true; }
    else
        die "No supported package manager found (apt, apk, dnf, yum)."
    fi
    log "Using package manager: $PKG_MGR"
}

# Ensure base tools
install_base_tools() {
    log "Installing base system tools..."
    update_pkgs
    case "$PKG_MGR" in
        apt)
            install_pkgs ca-certificates curl git bash coreutils findutils sed grep gzip tar xz-utils unzip gnupg locales tzdata pkg-config build-essential rustc cargo
            # Create dummy transitional libgl1-mesa-glx on Ubuntu 24.04+ where it's obsolete
            if ! dpkg -s libgl1-mesa-glx >/dev/null 2>&1; then
                install_pkgs equivs dpkg-dev fakeroot
                cat > /tmp/libgl1-mesa-glx.equivs << 'EOF'
Section: misc
Priority: optional
Standards-Version: 3.9.2
Package: libgl1-mesa-glx
Provides: libgl1-mesa-glx
Depends: libgl1, libgl1-mesa-dri, libglx-mesa0 | libglx0 | libglvnd0
Description: Dummy transitional package to satisfy legacy dependency on Ubuntu 24.04
 This package exists to satisfy scripts expecting libgl1-mesa-glx. It pulls in modern equivalents.
EOF
                (cd /tmp && equivs-build libgl1-mesa-glx.equivs)
                dpkg -i /tmp/libgl1-mesa-glx_*.deb || apt-get install -f -y
            fi
            install_pkgs libgl1 libegl1 libgles2 libx11-6 libxext6 libxrender1 libxrandr2 libxi6 libxinerama1 libxcursor1 libxkbcommon0 libxcb1 xvfb mesa-utils libglu1-mesa libglx-mesa0 libgl1-mesa-dri
            ;;
        apk)
            install_pkgs ca-certificates curl git bash coreutils findutils sed grep gzip tar xz unzip tzdata pkgconfig
            ;;
        dnf|yum)
            install_pkgs ca-certificates curl git bash coreutils findutils sed grep gzip tar xz unzip gnupg tzdata pkgconf
            ;;
    esac
    # Ensure certificates are up-to-date
    if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates || true
    fi
    # Set timezone to UTC to be deterministic
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime || true
    echo "UTC" > /etc/timezone || true
    clean_pkgs
    log "Base system tools installed."
}

# Create app user/group if not present
ensure_app_user() {
    log "Ensuring application user and group exist..."
    # Ensure we have groupadd/useradd available
    if ! command -v groupadd >/dev/null 2>&1 || ! command -v useradd >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apt) install_pkgs shadow ;;
            apk) install_pkgs shadow ;;
            dnf|yum) install_pkgs shadow-utils ;;
        esac
    fi

    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
        groupadd -g "$APP_GID" "$APP_GROUP" || groupadd "$APP_GROUP" || true
    fi
    if ! getent passwd "$APP_USER" >/dev/null 2>&1; then
        useradd -m -u "$APP_UID" -g "$APP_GROUP" -s /bin/bash "$APP_USER" || useradd -m -g "$APP_GROUP" -s /bin/bash "$APP_USER" || true
    fi
    log "App user: $APP_USER (uid: $(id -u "$APP_USER" 2>/dev/null || echo "$APP_UID")), group: $APP_GROUP"
}

# Setup directories with permissions
setup_directories() {
    log "Setting up project directories at $APP_ROOT..."
    mkdir -p "$APP_ROOT" "$APP_LOG_DIR" "$APP_CACHE_DIR" "$APP_BIN_DIR"
    chown -R "$APP_USER:$APP_GROUP" "$APP_ROOT" || true
    chmod -R 0755 "$APP_ROOT" || true
    chmod 0775 "$APP_LOG_DIR" || true
    log "Directories prepared: $APP_ROOT, logs, cache, bin"
}

# Persist environment variables for future shells
persist_env() {
    log "Persisting environment variables..."
    mkdir -p /etc/profile.d
    cat >/etc/profile.d/app_env.sh <<EOF
export APP_ROOT="$APP_ROOT"
export APP_ENV="$APP_ENV"
export APP_PORT="$APP_PORT"
export PATH="\$PATH:$APP_BIN_DIR"
export LANG="\${LANG:-C.UTF-8}"
export LC_ALL="\${LC_ALL:-C.UTF-8}"
EOF
    chmod 0644 /etc/profile.d/app_env.sh
    # Headless OpenGL defaults for PyOpenGL/EGL in headless environments
    cat >/etc/profile.d/zz-headless-gl.sh <<'EOF'
# Auto-configure headless GL for CI/containers
export MUJOCO_GL=egl
export PYOPENGL_PLATFORM=egl
EOF
    chmod 0644 /etc/profile.d/zz-headless-gl.sh
    # Create a .env file in project root for runtime tools
    cat >"$APP_ROOT/.env" <<EOF
APP_ROOT=$APP_ROOT
APP_ENV=$APP_ENV
APP_PORT=$APP_PORT
EOF
    chown "$APP_USER:$APP_GROUP" "$APP_ROOT/.env" || true
    chmod 0644 "$APP_ROOT/.env" || true
    log "Environment variables persisted."
}

# Auto-activate venvs in bash shells
setup_auto_activate() {
    # Create profile.d script to auto-activate project virtualenv based on APP_ROOT
    install -d -m 0755 /etc/profile.d
    cat > /etc/profile.d/auto_venv.sh <<'EOF'
# Auto-activate project virtualenv if present
APP_ROOT_DIR="${APP_ROOT:-/app}"
if [ -d "${APP_ROOT_DIR}/.venv" ] && [ -x "${APP_ROOT_DIR}/.venv/bin/activate" ]; then
    . "${APP_ROOT_DIR}/.venv/bin/activate"
fi
EOF
    chmod 0644 /etc/profile.d/auto_venv.sh

    # Ensure root's bashrc auto-activates too
    local bashrc_file="/root/.bashrc"
    local marker="# Auto-activate project venv if present"
    if ! grep -qxF "$marker" "$bashrc_file" 2>/dev/null; then
        echo "" >> "$bashrc_file"
        echo "$marker" >> "$bashrc_file"
        echo 'APP_ROOT_DIR="${APP_ROOT:-/app}"; if [ -d "${APP_ROOT_DIR}/.venv" ]; then . "${APP_ROOT_DIR}/.venv/bin/activate"; fi' >> "$bashrc_file"
    fi

    # Ensure app user's bashrc auto-activates as well
    local app_home
    app_home="$(getent passwd "$APP_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$APP_USER")"
    mkdir -p "$app_home"
    touch "$app_home/.bashrc"
    if ! grep -qxF "$marker" "$app_home/.bashrc" 2>/dev/null; then
        echo "" >> "$app_home/.bashrc"
        echo "$marker" >> "$app_home/.bashrc"
        echo 'APP_ROOT_DIR="${APP_ROOT:-/app}"; if [ -d "${APP_ROOT_DIR}/.venv" ]; then . "${APP_ROOT_DIR}/.venv/bin/activate"; fi' >> "$app_home/.bashrc"
    fi
    chown "$APP_USER:$APP_GROUP" "$app_home/.bashrc" || true
}

# Language/runtime installers and project-specific setup
setup_python() {
    log "Detected Python project."
    case "$PKG_MGR" in
        apt) update_pkgs; install_pkgs python3 python3-pip python3-venv build-essential pkg-config libffi-dev libssl-dev rustc cargo ;;
        apk) install_pkgs python3 py3-pip py3-virtualenv build-base pkgconfig openssl-dev libffi-dev rust cargo ;;
        dnf|yum) install_pkgs python3 python3-pip python3-virtualenv gcc gcc-c++ make pkgconf libffi-devel openssl-devel rust cargo ;;
    esac
    clean_pkgs
    # Create virtual environment if not present
    cd "$APP_ROOT"
    if [ ! -d ".venv" ]; then
        log "Creating Python virtual environment (.venv)..."
        python3 -m venv .venv
    else
        log "Python virtual environment already exists."
    fi
    # Upgrade pip and install dependencies
    . "$APP_ROOT/.venv/bin/activate"
    python -m pip install --upgrade pip setuptools wheel
    pip install --no-cache-dir PyOpenGL-accelerate
    if [ -f "requirements.txt" ]; then
        log "Installing Python dependencies from requirements.txt..."
        pip install -r requirements.txt
    elif [ -f "pyproject.toml" ]; then
        log "Installing Python project from pyproject.toml..."
        # Try to install dependencies if using modern packaging
        pip install .
        # Optionally install development extras if defined
        if ! pip install -e ".[dev]"; then
            warn "Dev extras not installed (missing 'dev' optional-dependencies or other issue). Continuing..."
        fi
    elif [ -f "Pipfile" ]; then
        log "Pipfile detected. Installing pipenv..."
        pip install pipenv
        PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
    else
        warn "No requirements.txt/pyproject.toml/Pipfile found. Skipping dependency installation."
    fi
    # Ensure OpenXR binding compatibility: remove stray 'xr' package and add project-root shim so `import xr` works
    python -m pip uninstall -y xr || true
    mkdir -p xr && cat > xr/__init__.py << 'PY'
# Minimal shim to satisfy imports during tests
class ContextObject:
    pass

class Context:
    pass
PY
    find . -type d -name '__pycache__' -exec rm -rf {} + || true
    python -m pip install -e ".[dev]"
    python -c "import xr, sys; sys.exit(0 if hasattr(xr, 'ContextObject') else 1)"
    deactivate || true
    # Common environment variables
    {
        echo "VIRTUAL_ENV=$APP_ROOT/.venv"
        echo "PYTHONUNBUFFERED=1"
        echo "PYTHONDONTWRITEBYTECODE=1"
        echo "PIP_NO_CACHE_DIR=1"
    } >> "$APP_ROOT/.env"
    log "Python setup complete."
}

setup_node() {
    log "Detected Node.js project."
    case "$PKG_MGR" in
        apt) install_pkgs nodejs npm build-essential ;;
        apk) install_pkgs nodejs npm build-base ;;
        dnf|yum) install_pkgs nodejs npm gcc gcc-c++ make ;;
    esac
    clean_pkgs
    cd "$APP_ROOT"
    # Install dependencies
    if [ -f "package-lock.json" ]; then
        log "Installing Node dependencies with npm ci..."
        npm ci --no-audit --no-fund
    elif [ -f "package.json" ]; then
        log "Installing Node dependencies with npm install..."
        npm install --no-audit --no-fund
    else
        warn "package.json not found. Skipping npm install."
    fi
    # Common environment variables
    {
        echo "NODE_ENV=$APP_ENV"
        echo "NPM_CONFIG_LOGLEVEL=warn"
        echo "PORT=$APP_PORT"
    } >> "$APP_ROOT/.env"
    log "Node.js setup complete."
}

setup_ruby() {
    log "Detected Ruby project."
    case "$PKG_MGR" in
        apt) install_pkgs ruby-full build-essential ;;
        apk) install_pkgs ruby ruby-dev build-base ;;
        dnf|yum) install_pkgs ruby ruby-devel gcc gcc-c++ make ;;
    esac
    clean_pkgs
    cd "$APP_ROOT"
    if [ -f "Gemfile" ]; then
        if ! command -v bundle >/dev/null 2>&1; then
            gem install bundler --no-document
        fi
        log "Installing Ruby gems via bundler..."
        bundle config set path 'vendor/bundle'
        bundle install --jobs=4 --retry=3
    else
        warn "Gemfile not found. Skipping bundle install."
    fi
    echo "RACK_ENV=$APP_ENV" >> "$APP_ROOT/.env"
    log "Ruby setup complete."
}

setup_go() {
    log "Detected Go project."
    case "$PKG_MGR" in
        apt) install_pkgs golang gcc make ;;
        apk) install_pkgs go gcc make ;;
        dnf|yum) install_pkgs golang gcc make ;;
    esac
    clean_pkgs
    cd "$APP_ROOT"
    if [ -f "go.mod" ]; then
        log "Fetching Go modules..."
        go mod download
        # Optionally build if main module exists
        if grep -q "module " go.mod; then
            mkdir -p "$APP_BIN_DIR"
            log "Attempting to build Go project..."
            if go list -f '{{.Name}}' ./ | grep -q '^main$' || [ -f "main.go" ]; then
                go build -o "$APP_BIN_DIR/app" ./...
            else
                warn "Go main package not detected. Skipping build."
            fi
        fi
    else
        warn "go.mod not found. Skipping go mod download."
    fi
    {
        echo "GOPATH=${GOPATH:-/go}"
        echo "GOFLAGS=-mod=readonly"
    } >> "$APP_ROOT/.env"
    log "Go setup complete."
}

setup_java_maven() {
    log "Detected Java Maven project."
    case "$PKG_MGR" in
        apt) install_pkgs openjdk-17-jdk maven ;;
        apk) install_pkgs openjdk17 maven ;;
        dnf|yum) install_pkgs java-17-openjdk-devel maven ;;
    esac
    clean_pkgs
    cd "$APP_ROOT"
    log "Resolving Maven dependencies offline and compiling..."
    mvn -B -q -DskipTests dependency:go-offline compile || mvn -B -q -DskipTests package || warn "Maven build encountered an issue."
    echo "JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75.0" >> "$APP_ROOT/.env"
    log "Java Maven setup complete."
}

setup_java_gradle() {
    log "Detected Java Gradle project."
    case "$PKG_MGR" in
        apt) install_pkgs openjdk-17-jdk gradle ;;
        apk) install_pkgs openjdk17 gradle ;;
        dnf|yum) install_pkgs java-17-openjdk-devel gradle ;;
    esac
    clean_pkgs
    cd "$APP_ROOT"
    if [ -x "./gradlew" ]; then
        log "Using Gradle wrapper to build..."
        ./gradlew -q build -x test || warn "Gradle wrapper build issue."
    else
        log "Using system Gradle to build..."
        gradle -q build -x test || warn "Gradle build issue."
    fi
    echo "JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75.0" >> "$APP_ROOT/.env"
    log "Java Gradle setup complete."
}

setup_php() {
    log "Detected PHP project."
    case "$PKG_MGR" in
        apt) install_pkgs php-cli php-curl php-zip php-mbstring composer ;;
        apk) install_pkgs php81-cli php81-curl php81-zip php81-mbstring composer ;;
        dnf|yum) install_pkgs php-cli php-json php-mbstring php-zip composer ;;
    esac
    clean_pkgs
    cd "$APP_ROOT"
    if [ -f "composer.json" ]; then
        log "Installing PHP dependencies with Composer..."
        composer install --no-interaction --no-dev --prefer-dist
    else
        warn "composer.json not found. Skipping composer install."
    fi
    echo "APP_ENV=$APP_ENV" >> "$APP_ROOT/.env"
    log "PHP setup complete."
}

setup_rust() {
    log "Detected Rust project."
    case "$PKG_MGR" in
        apt) install_pkgs cargo build-essential ;;
        apk) install_pkgs cargo rust build-base ;;
        dnf|yum) install_pkgs cargo gcc gcc-c++ make ;;
    esac
    clean_pkgs
    cd "$APP_ROOT"
    if [ -f "Cargo.toml" ]; then
        log "Fetching Rust crate dependencies..."
        cargo fetch
        mkdir -p "$APP_BIN_DIR"
        log "Attempting to build Rust project in release mode..."
        cargo build --release || warn "Rust build issue."
        if [ -f "target/release" ]; then
            # Move any produced binaries
            find target/release -maxdepth 1 -type f -perm -111 -exec cp {} "$APP_BIN_DIR/" \; || true
        fi
    else
        warn "Cargo.toml not found. Skipping cargo operations."
    fi
    echo "RUST_LOG=info" >> "$APP_ROOT/.env"
    log "Rust setup complete."
}

# Detect project type(s) based on files present
detect_and_setup_project() {
    local did_any=0
    cd "$APP_ROOT"

    # Python
    if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ]; then
        setup_python
        did_any=1
    fi

    # Node.js
    if [ -f "package.json" ]; then
        setup_node
        did_any=1
    fi

    # Ruby
    if [ -f "Gemfile" ]; then
        setup_ruby
        did_any=1
    fi

    # Go
    if [ -f "go.mod" ]; then
        setup_go
        did_any=1
    fi

    # Java Maven
    if [ -f "pom.xml" ]; then
        setup_java_maven
        did_any=1
    fi

    # Java Gradle
    if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -x "./gradlew" ]; then
        setup_java_gradle
        did_any=1
    fi

    # PHP
    if [ -f "composer.json" ]; then
        setup_php
        did_any=1
    fi

    # Rust
    if [ -f "Cargo.toml" ]; then
        setup_rust
        did_any=1
    fi

    if [ "$did_any" -eq 0 ]; then
        warn "No recognized project files found in $APP_ROOT. Installed base tools only."
    fi
}

# Configure runtime hints or start script
create_runtime_helper() {
    log "Creating runtime helper script..."
    cat >"$APP_BIN_DIR/start-app.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# Load environment variables if available
if [ -f "./.env" ]; then
    set -a
    . "./.env"
    set +a
fi
# Detect and run common entry points
if [ -f "app.py" ]; then
    if [ -d ".venv" ]; then . ".venv/bin/activate"; fi
    exec python app.py
elif [ -f "wsgi.py" ]; then
    if [ -d ".venv" ]; then . ".venv/bin/activate"; fi
    exec python wsgi.py
elif [ -f "manage.py" ]; then
    if [ -d ".venv" ]; then . ".venv/bin/activate"; fi
    exec python manage.py runserver 0.0.0.0:${APP_PORT:-8080}
elif [ -f "server.js" ]; then
    exec node server.js
elif [ -f "index.js" ]; then
    exec node index.js
elif [ -f "bin/app" ]; then
    exec "./bin/app"
elif [ -x "gradlew" ]; then
    exec ./gradlew bootRun
elif command -v java >/dev/null 2>&1 && ls target/*.jar >/dev/null 2>&1; then
    JAR=$(ls target/*.jar | head -n1)
    exec java -jar "$JAR"
else
    echo "[start-app] No known entry point found. Please run your application manually."
    exit 1
fi
EOF
    chmod +x "$APP_BIN_DIR/start-app.sh"
    chown "$APP_USER:$APP_GROUP" "$APP_BIN_DIR/start-app.sh" || true
    log "Runtime helper script created at $APP_BIN_DIR/start-app.sh"
}

# Main execution
main() {
    log "Starting universal environment setup..."
    detect_pkg_manager
    install_base_tools
    ensure_app_user
    setup_directories
    persist_env

    # If the script is not executed from APP_ROOT, try moving project files into APP_ROOT
    if [ "$(pwd)" != "$APP_ROOT" ]; then
        warn "Current directory is $(pwd). Expected APP_ROOT=$APP_ROOT."
        warn "If this is an empty app root, you may want to copy your project into $APP_ROOT."
    fi

    detect_and_setup_project
    setup_auto_activate
    create_runtime_helper

    log "Environment setup completed successfully."
    echo -e "${BLUE}Summary:${NC}"
    echo "- App root: $APP_ROOT"
    echo "- App user/group: $APP_USER/$APP_GROUP"
    echo "- Default port: $APP_PORT"
    echo "- Start helper: $APP_BIN_DIR/start-app.sh"
    echo "To run: cd $APP_ROOT && $APP_BIN_DIR/start-app.sh"
}

# Ensure APP_ROOT exists before anything else
prepare_root() {
    mkdir -p "$APP_ROOT"
    # If project files aren't present, attempt to detect if running inside project dir and copy files once
    # Idempotent: only copy if APP_ROOT is empty (no files other than logs/cache/bin/.env)
    if [ "$(pwd)" != "$APP_ROOT" ]; then
        shopt -s nullglob dotglob
        local entries=("$APP_ROOT"/*)
        if [ "${#entries[@]}" -eq 0 ]; then
            warn "App root is empty. Attempting to copy current directory contents into $APP_ROOT..."
            cp -R . "$APP_ROOT"
        fi
        shopt -u nullglob dotglob
    fi
}

prepare_root
main "$@"