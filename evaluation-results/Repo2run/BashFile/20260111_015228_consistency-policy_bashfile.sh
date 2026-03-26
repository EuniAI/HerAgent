#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common project types (Python, Node.js, Ruby, Go, PHP, Java, Rust, .NET)
# Installs system packages, runtimes, and dependencies in an idempotent, secure manner.

set -Eeuo pipefail

# -----------------------------
# Configuration and Defaults
# -----------------------------
: "${PROJECT_DIR:=/app}"                # Root of the project inside the container
: "${APP_ENV:=production}"              # Default environment
: "${DEFAULT_PORT:=8080}"               # Fallback port if not specified by project
: "${CREATE_APP_USER:=0}"               # Set 1 to create and use non-root 'app' user
: "${APP_USER:=app}"                    # Name of the non-root user (if created)
: "${APP_GROUP:=app}"                   # Name of the non-root group (if created)
: "${DEBIAN_FRONTEND:=noninteractive}"  # Ensure apt is non-interactive

# -----------------------------
# Logging Utilities
# -----------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
BLUE="$(printf '\033[0;34m')"
NC="$(printf '\033[0m')"

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARNING] $*${NC}"; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }

trap 'error "Setup failed at line $LINENO. Exit status $?"' ERR

# -----------------------------
# Helpers: System & PM detection
# -----------------------------
OS_ID=""
PKG_MGR=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""
PKG_CHECK_CMD=""

detect_os_and_pkg_manager() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
        PKG_UPDATE_CMD="apt-get update -y -qq"
        PKG_INSTALL_CMD="apt-get install -y --no-install-recommends"
        PKG_CHECK_CMD="dpkg -s"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
        PKG_UPDATE_CMD="apk update"
        PKG_INSTALL_CMD="apk add --no-cache"
        PKG_CHECK_CMD="apk info -e"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
        PKG_UPDATE_CMD="dnf -y makecache"
        PKG_INSTALL_CMD="dnf -y install"
        PKG_CHECK_CMD="rpm -q"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
        PKG_UPDATE_CMD="yum -y makecache"
        PKG_INSTALL_CMD="yum -y install"
        PKG_CHECK_CMD="rpm -q"
    else
        error "No supported package manager found (apt/apk/dnf/yum)."
        exit 1
    fi
    log "Detected OS '${OS_ID:-unknown}' and package manager '${PKG_MGR}'."
}

pkg_update() {
    log "Updating package index..."
    eval "${PKG_UPDATE_CMD}" || warn "Package index update may have failed."
}

pkg_is_installed() {
    # Returns 0 if installed, 1 otherwise
    local pkg="$1"
    case "$PKG_MGR" in
        apt)
            ${PKG_CHECK_CMD} "$pkg" >/dev/null 2>&1
            ;;
        apk)
            ${PKG_CHECK_CMD} "$pkg" >/dev/null 2>&1
            ;;
        dnf|yum)
            ${PKG_CHECK_CMD} "$pkg" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_install() {
    # Install packages if not present
    local pkgs=("$@")
    local to_install=()
    for p in "${pkgs[@]}"; do
        if ! pkg_is_installed "$p"; then
            to_install+=("$p")
        fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        log "Installing packages: ${to_install[*]}"
        eval "${PKG_INSTALL_CMD} ${to_install[*]}"
        # Cleanup for apt/yum/dnf to keep image smaller
        case "$PKG_MGR" in
            apt)
                apt-get clean
                rm -rf /var/lib/apt/lists/*
                ;;
            yum|dnf)
                yum clean all >/dev/null 2>&1 || true
                dnf clean all >/dev/null 2>&1 || true
                rm -rf /var/cache/yum || true
                ;;
            apk)
                # apk uses --no-cache, nothing else needed
                ;;
        esac
    else
        log "All requested packages already installed."
    fi
}

# -----------------------------
# User and Directory Setup
# -----------------------------
ensure_user() {
    if [[ "$CREATE_APP_USER" == "1" ]]; then
        if ! id -u "$APP_USER" >/dev/null 2>&1; then
            log "Creating user and group '$APP_USER'..."
            case "$PKG_MGR" in
                apk)
                    addgroup -S "$APP_GROUP" || true
                    adduser -S -D -G "$APP_GROUP" "$APP_USER" || true
                    ;;
                *)
                    groupadd -r "$APP_GROUP" 2>/dev/null || true
                    useradd -r -g "$APP_GROUP" -d "$PROJECT_DIR" -s /bin/bash "$APP_USER" 2>/dev/null || true
                    ;;
            esac
        fi
    fi
}

setup_directories() {
    log "Setting up project directories at '$PROJECT_DIR'..."
    mkdir -p "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/logs" "$PROJECT_DIR/tmp"
    chmod 755 "$PROJECT_DIR" || true
    chmod 755 "$PROJECT_DIR/logs" "$PROJECT_DIR/tmp" || true

    if [[ "$CREATE_APP_USER" == "1" ]]; then
        chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR" || true
    fi
}

# Legacy GL compatibility for Ubuntu 24.04+ (missing libgl1-mesa-glx)
ensure_legacy_gl_compat() {
    # Only applicable for apt-based systems
    if [[ "$PKG_MGR" != "apt" ]]; then
        return 0
    fi

    # Ensure replacement libraries and equivs are present (idempotent)
    apt-get update -y -qq
    apt-get install -y --no-install-recommends equivs libgl1 libglx-mesa0 libosmesa6-dev libglfw3 patchelf

    # Create a dummy transitional package if the legacy name is not installed
    if ! dpkg -s libgl1-mesa-glx >/dev/null 2>&1; then
        local tmpdir
        tmpdir="$(mktemp -d)"
        (
            cd "$tmpdir"
            cat > libgl1-mesa-glx.control <<'EOF'
Section: misc
Priority: optional
Standards-Version: 3.9.2

Package: libgl1-mesa-glx
Version: 99.0
Maintainer: Local <root@localhost>
Provides: libgl1-mesa-glx
Depends: libgl1, libglx-mesa0
Description: Dummy transitional package to satisfy legacy dependency
 This is a dummy package to satisfy scripts expecting libgl1-mesa-glx on Ubuntu 24.04+. It pulls libgl1 and libglx-mesa0.
EOF
            equivs-build libgl1-mesa-glx.control >/dev/null
            dpkg -i ./*.deb
        )
        rm -rf "$tmpdir"
    fi
}

# -----------------------------
# Common Tools and Certificates
# -----------------------------
install_common_tools() {
    log "Installing common tools and certificates..."
    case "$PKG_MGR" in
        apt)
            pkg_update
            pkg_install ca-certificates sudo curl wget git unzip tar tzdata pkg-config swig build-essential gcc g++ make cmake ninja-build ffmpeg libavcodec-dev libavformat-dev libavutil-dev libswscale-dev python3-dev libglib2.0-0 python3-yaml bzip2 libosmesa6 libosmesa6-dev libgl1 libglx-mesa0 libgl1-mesa-glx libglfw3 libglfw3-dev libglew-dev libxrender1 libxext6 libxi-dev libxmu-dev libxrandr-dev libxxf86vm-dev libxcursor-dev libxinerama-dev patchelf equivs libsdl2-dev libsdl2-image-dev libsdl2-mixer-dev libsdl2-ttf-dev libjpeg-dev zlib1g-dev libfreetype6-dev libpng-dev libx11-dev libxext-dev libgl1-mesa-dev libglu1-mesa-dev freeglut3-dev
            update-ca-certificates || true
            ensure_legacy_gl_compat
            ;;
        apk)
            pkg_update
            pkg_install ca-certificates curl wget git unzip tar tzdata bash pkgconfig build-base
            update-ca-certificates || true
            ;;
        yum|dnf)
            pkg_update
            pkg_install ca-certificates curl wget git unzip tar tzdata pkgconfig gcc gcc-c++ make
            # RHEL/CentOS might need 'update-ca-trust'
            update-ca-trust force-enable >/dev/null 2>&1 || true
            update-ca-trust >/dev/null 2>&1 || true
            ;;
    esac
}

# -----------------------------
# Project Type Detection
# -----------------------------
PROJECT_TYPES=()

detect_project_types() {
    PROJECT_TYPES=()
    if [[ -f "$PROJECT_DIR/requirements.txt" || -f "$PROJECT_DIR/pyproject.toml" || -f "$PROJECT_DIR/Pipfile" || -f "$PROJECT_DIR/setup.py" ]]; then
        PROJECT_TYPES+=("python")
    fi
    if [[ -f "$PROJECT_DIR/package.json" ]]; then
        PROJECT_TYPES+=("node")
    fi
    if [[ -f "$PROJECT_DIR/Gemfile" ]]; then
        PROJECT_TYPES+=("ruby")
    fi
    if [[ -f "$PROJECT_DIR/go.mod" ]]; then
        PROJECT_TYPES+=("go")
    fi
    if [[ -f "$PROJECT_DIR/composer.json" ]]; then
        PROJECT_TYPES+=("php")
    fi
    if [[ -f "$PROJECT_DIR/pom.xml" || -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ]]; then
        PROJECT_TYPES+=("java")
    fi
    if [[ -f "$PROJECT_DIR/Cargo.toml" ]]; then
        PROJECT_TYPES+=("rust")
    fi
    # Basic .NET detection
    if compgen -G "$PROJECT_DIR/*.csproj" >/dev/null 2>&1; then
        PROJECT_TYPES+=("dotnet")
    fi

    if [[ ${#PROJECT_TYPES[@]} -eq 0 ]]; then
        warn "No known project files detected in '$PROJECT_DIR'. Installing common tools only."
    else
        log "Detected project types: ${PROJECT_TYPES[*]}"
    fi
}

# -----------------------------
# Environment File and PATH
# -----------------------------
write_env_profile() {
    local profile_file="/etc/profile.d/project_env.sh"
    log "Configuring global environment at '$profile_file'..."
    mkdir -p "$(dirname "$profile_file")"
    {
        echo "# Generated by setup script on $(date)"
        echo "export APP_ENV=${APP_ENV}"
        echo "export PROJECT_DIR=${PROJECT_DIR}"
        echo "export PORT=${DEFAULT_PORT}"
        echo "export LC_ALL=C.UTF-8"
        echo "export LANG=C.UTF-8"
        # Prepend commonly used local bin paths if they exist
        echo "[ -d \"${PROJECT_DIR}/node_modules/.bin\" ] && export PATH=\"${PROJECT_DIR}/node_modules/.bin:\$PATH\""
        echo "[ -d \"${PROJECT_DIR}/.venv/bin\" ] && export PATH=\"${PROJECT_DIR}/.venv/bin:\$PATH\""
        echo "[ -d \"/root/.cargo/bin\" ] && export PATH=\"/root/.cargo/bin:\$PATH\""
        # If using non-root app user
        if [[ "$CREATE_APP_USER" == "1" ]]; then
            echo "export APP_USER=${APP_USER}"
        fi
    } > "$profile_file"
    chmod 644 "$profile_file" || true

    # Project .env for app runtime
    local dotenv="$PROJECT_DIR/.env"
    if [[ ! -f "$dotenv" ]]; then
        log "Creating default .env file at '$dotenv'..."
        {
            echo "APP_ENV=${APP_ENV}"
            echo "PORT=${DEFAULT_PORT}"
        } > "$dotenv"
    else
        log ".env already exists; leaving as is."
    fi

    # Ensure ownership if non-root user used
    if [[ "$CREATE_APP_USER" == "1" ]]; then
        chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR" || true
    fi
}

# -----------------------------
# Language-specific Setup
# -----------------------------

setup_auto_activate() {
    local bashrc_file="/root/.bashrc"
    local activate_line="source ${PROJECT_DIR}/.venv/bin/activate"
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
        echo "" >> "$bashrc_file"
        echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
        echo "$activate_line" >> "$bashrc_file"
    fi
}

setup_python() {
    log "[Python] Installing Python runtime and dependencies..."
    case "$PKG_MGR" in
        apt)
            pkg_update
            pkg_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev
            ;;
        apk)
            pkg_update
            pkg_install python3 py3-pip py3-virtualenv build-base libffi-dev openssl-dev
            ;;
        yum|dnf)
            pkg_update
            pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel
            ;;
    esac

    # Create and use virtual environment
    if [[ ! -d "$PROJECT_DIR/.venv" ]]; then
        log "[Python] Creating virtual environment at '$PROJECT_DIR/.venv'..."
        python3 -m venv "$PROJECT_DIR/.venv"
    else
        log "[Python] Virtual environment already exists."
    fi
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/.venv/bin/activate"
    setup_auto_activate
    pip install --no-cache-dir --upgrade pip wheel setuptools

    # Poetry support if pyproject.toml uses it
    if [[ -f "$PROJECT_DIR/pyproject.toml" ]] && grep -qi '\[tool.poetry\]' "$PROJECT_DIR/pyproject.toml"; then
        log "[Python] Detected Poetry project; installing Poetry..."
        pip install --no-cache-dir poetry
        poetry config virtualenvs.create false
        if [[ -f "$PROJECT_DIR/poetry.lock" ]]; then
            (cd "$PROJECT_DIR" && poetry install --no-interaction --no-ansi)
        else
            (cd "$PROJECT_DIR" && poetry install --no-interaction --no-ansi)
        fi
    elif [[ -f "$PROJECT_DIR/requirements.txt" ]]; then
        log "[Python] Installing dependencies from requirements.txt..."
        pip install --no-cache-dir -r "$PROJECT_DIR/requirements.txt"
    elif [[ -f "$PROJECT_DIR/Pipfile" ]]; then
        log "[Python] Detected Pipfile; installing pipenv and dependencies..."
        pip install --no-cache-dir pipenv
        (cd "$PROJECT_DIR" && PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install)
    elif [[ -f "$PROJECT_DIR/pyproject.toml" ]]; then
        log "[Python] pyproject.toml detected without Poetry; attempting pip install of the project..."
        (cd "$PROJECT_DIR" && pip install --no-cache-dir . || warn "pip install . failed; ensure build backend is available.")
    else
        warn "[Python] No dependency manifest found. Skipping Python dependency installation."
    fi

    # Common Python web defaults
    if [[ -f "$PROJECT_DIR/app.py" || -f "$PROJECT_DIR/main.py" || -f "$PROJECT_DIR/manage.py" ]]; then
        log "[Python] Detected typical application entry files."
        # Environment hints
        {
            echo "export FLASK_ENV=${APP_ENV}"
            echo "export PYTHONUNBUFFERED=1"
        } >> /etc/profile.d/project_env.sh
    fi
}

setup_node() {
    log "[Node.js] Installing Node.js runtime and dependencies..."
    case "$PKG_MGR" in
        apt)
            pkg_update
            pkg_install nodejs npm
            ;;
        apk)
            pkg_update
            pkg_install nodejs npm
            ;;
        yum|dnf)
            pkg_update
            pkg_install nodejs npm
            ;;
    esac

    if [[ -f "$PROJECT_DIR/package.json" ]]; then
        if [[ -f "$PROJECT_DIR/package-lock.json" || -f "$PROJECT_DIR/npm-shrinkwrap.json" ]]; then
            log "[Node.js] Running 'npm ci'..."
            (cd "$PROJECT_DIR" && npm ci --no-audit --no-fund)
        else
            log "[Node.js] Running 'npm install'..."
            (cd "$PROJECT_DIR" && npm install --no-audit --no-fund)
        fi
    else
        warn "[Node.js] package.json not found; skipping dependency installation."
    fi
}

setup_ruby() {
    log "[Ruby] Installing Ruby and Bundler..."
    case "$PKG_MGR" in
        apt)
            pkg_update
            pkg_install ruby-full build-essential
            ;;
        apk)
            pkg_update
            pkg_install ruby ruby-dev build-base
            ;;
        yum|dnf)
            pkg_update
            pkg_install ruby gcc gcc-c++ make
            ;;
    esac

    if command -v gem >/dev/null 2>&1; then
        gem install --no-document bundler || warn "Failed to install bundler"
    fi

    if [[ -f "$PROJECT_DIR/Gemfile" ]]; then
            log "[Ruby] Installing gems via Bundler..."
            (cd "$PROJECT_DIR" && bundle config set path 'vendor/bundle' && bundle install --jobs=4)
    else
        warn "[Ruby] Gemfile not found; skipping bundle install."
    fi
}

setup_go() {
    log "[Go] Installing Go toolchain..."
    case "$PKG_MGR" in
        apt)
            pkg_update
            pkg_install golang
            ;;
        apk)
            pkg_update
            pkg_install go
            ;;
        yum|dnf)
            pkg_update
            pkg_install golang
            ;;
    esac

    if [[ -f "$PROJECT_DIR/go.mod" ]]; then
        log "[Go] Downloading modules..."
        (cd "$PROJECT_DIR" && go mod download)
    fi
}

setup_php() {
    log "[PHP] Installing PHP CLI and Composer..."
    case "$PKG_MGR" in
        apt)
            pkg_update
            pkg_install php-cli php-mbstring php-xml php-curl php-zip
            # Composer package may exist
            if ! command -v composer >/dev/null 2>&1; then
                pkg_install composer || true
            fi
            ;;
        apk)
            pkg_update
            pkg_install php php-cli php-mbstring php-xml php-curl php-zip php-phar
            ;;
        yum|dnf)
            pkg_update
            pkg_install php-cli php-mbstring php-xml php-json php-common
            ;;
    esac
    if ! command -v composer >/dev/null 2>&1; then
        log "[PHP] Installing Composer locally..."
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Composer install failed"
        rm -f /tmp/composer-setup.php || true
    fi

    if [[ -f "$PROJECT_DIR/composer.json" ]]; then
        log "[PHP] Running 'composer install'..."
        (cd "$PROJECT_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist)
    else
        warn "[PHP] composer.json not found; skipping composer install."
    fi
}

setup_java() {
    log "[Java] Installing JDK and build tooling (Maven/Gradle as needed)..."
    case "$PKG_MGR" in
        apt)
            pkg_update
            pkg_install default-jdk-headless
            if [[ -f "$PROJECT_DIR/pom.xml" ]]; then pkg_install maven; fi
            if [[ -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ]]; then pkg_install gradle; fi
            ;;
        apk)
            pkg_update
            pkg_install openjdk11-jdk
            if [[ -f "$PROJECT_DIR/pom.xml" ]]; then pkg_install maven; fi
            if [[ -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ]]; then pkg_install gradle; fi
            ;;
        yum|dnf)
            pkg_update
            pkg_install java-11-openjdk java-11-openjdk-devel
            if [[ -f "$PROJECT_DIR/pom.xml" ]]; then pkg_install maven; fi
            if [[ -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ]]; then pkg_install gradle || warn "Gradle may not be available in this repo"; fi
            ;;
    esac

    if [[ -f "$PROJECT_DIR/pom.xml" ]]; then
        log "[Java] Maven project detected. You can build with 'mvn -q -DskipTests package'."
    fi
    if [[ -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ]]; then
        log "[Java] Gradle project detected. You can build with 'gradle build -x test'."
    fi
}

setup_rust() {
    log "[Rust] Installing Rust toolchain..."
    case "$PKG_MGR" in
        apt)
            pkg_update
            pkg_install rustc cargo
            ;;
        apk)
            pkg_update
            pkg_install rust cargo
            ;;
        yum|dnf)
            pkg_update
            pkg_install rust cargo
            ;;
    esac

    if [[ -f "$PROJECT_DIR/Cargo.toml" ]]; then
        log "[Rust] Fetching dependencies with 'cargo fetch'..."
        (cd "$PROJECT_DIR" && cargo fetch)
    fi
}

setup_dotnet() {
    warn "[.NET] .NET setup can be distro-specific; attempting minimal runtime if available."
    case "$PKG_MGR" in
        apt)
            # Attempt installing dotnet via packages if available in base image repos.
            if apt-cache show dotnet-sdk-8.0 >/dev/null 2>&1; then
                pkg_update
                pkg_install dotnet-sdk-8.0
            else
                warn "[.NET] dotnet packages not found in APT sources. Consider using a microsoft-dotnet base image."
            fi
            ;;
        yum|dnf)
            warn "[.NET] Install via Microsoft packages is recommended. Consider using a dotnet runtime base image."
            ;;
        apk)
            warn "[.NET] Not generally available via apk. Use a dotnet base image."
            ;;
    esac

    if compgen -G "$PROJECT_DIR/*.csproj" >/dev/null 2>&1; then
        log "[.NET] Restoring project dependencies..."
        if command -v dotnet >/dev/null 2>&1; then
            (cd "$PROJECT_DIR" && dotnet restore)
        else
            warn "[.NET] dotnet command not available."
        fi
    fi
}

# -----------------------------
# Conda Setup
# -----------------------------
setup_conda() {
    # Ensure sudo and base tools; install Conda (Miniforge), harden config with libmamba solver
    if [[ "$PKG_MGR" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        # Ensure GL compatibility first so libgl1-mesa-glx is satisfied via dummy package on Ubuntu 24.04+
        ensure_legacy_gl_compat
        DEBIAN_FRONTEND=noninteractive apt-get install -y sudo ca-certificates curl bzip2 git build-essential cmake ninja-build pkg-config swig ffmpeg libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libglib2.0-0 python3-yaml libosmesa6-dev libgl1-mesa-glx libgl1-mesa-dev libglu1-mesa-dev libglew-dev libglfw3 libglfw3-dev patchelf
        apt-get clean
        update-ca-certificates || true
    fi

    # Install Miniforge Conda if missing (idempotent)
    if ! command -v conda >/dev/null 2>&1; then
        local ARCH F
        ARCH="$(uname -m)"
        case "$ARCH" in
            x86_64) F="Miniforge3-Linux-x86_64.sh" ;;
            aarch64) F="Miniforge3-Linux-aarch64.sh" ;;
            *) F="Miniforge3-Linux-x86_64.sh" ;;
        esac
        curl -fsSL -o /tmp/miniforge.sh "https://github.com/conda-forge/miniforge/releases/latest/download/${F}"
        bash /tmp/miniforge.sh -b -p /opt/conda
        ln -sf /opt/conda/bin/conda /usr/local/bin/conda
        ln -sf /opt/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh || true
        rm -f /tmp/miniforge.sh || true
    fi

    # System-wide conda shell init for non-interactive shells
    if command -v conda >/dev/null 2>&1; then
        local BASE
        BASE="$(conda info --base)"
        mkdir -p /etc/profile.d
        printf '%s\n' "if [ -f \"$BASE/etc/profile.d/conda.sh\" ]; then . \"$BASE/etc/profile.d/conda.sh\"; fi" > /etc/profile.d/conda_base.sh
        chmod 644 /etc/profile.d/conda_base.sh || true
        grep -qxF ". /etc/profile.d/conda_base.sh" /etc/bash.bashrc || echo ". /etc/profile.d/conda_base.sh" >> /etc/bash.bashrc

        # Configure conda for robustness and performance
        conda config --system --set channel_priority flexible || true
        conda config --system --prepend channels conda-forge || true
        conda config --system --append channels pytorch3d || true
        conda config --system --append channels pytorch || true
        conda config --system --append channels nvidia || true
        conda config --system --append channels defaults || true
        conda config --system --set remote_max_retries 10 || true
        conda config --system --set remote_connect_timeout_secs 60 || true

        # Enable libmamba solver
        conda install -n base -y conda-libmamba-solver || true
        conda config --system --set solver libmamba || true
        conda clean -a -y || true
    fi
}

# -----------------------------
# MuJoCo Runtime Setup
# -----------------------------
setup_mujoco_runtime() {
    # Install required GL/OSMesa/X11 runtime libs and tools, then fetch MuJoCo 2.1 binaries.
    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get update -y -qq
        apt-get install -y --no-install-recommends curl wget unzip ca-certificates build-essential patchelf libosmesa6 libosmesa6-dev libgl1 libglx-mesa0 libgl1-mesa-dev libglu1-mesa libglu1-mesa-dev libxext6 libxrender1 libxrandr2 libxi6 libxinerama1 libxcursor1 libxxf86vm1 libglfw3 libglew-dev equivs
        apt-get clean
        rm -rf /var/lib/apt/lists/*
    fi
    MUJ_DIR="/root/.mujoco"
    mkdir -p "$MUJ_DIR"
    if [[ ! -d "$MUJ_DIR/mujoco210" ]]; then
        T="/tmp/mujoco210.tar.gz"
        if ! curl -fsSL -o "$T" https://mujoco.org/download/mujoco210-linux-x86_64.tar.gz; then
            if ! curl -fsSL -o "$T" https://www.roboti.us/download/mujoco210-linux-x86_64.tar.gz; then
                curl -fsSL -o "$T" https://huggingface.co/datasets/ymjeong/mujoco_binary/resolve/main/mujoco210-linux-x86_64.tar.gz
            fi
        fi
        tar -xzf "$T" -C "$MUJ_DIR"
        rm -f "$T"
    fi
    # Ensure legacy license file exists to satisfy mujoco-py (MuJoCo >=2.1 doesn't require it)
    if [[ ! -s "$MUJ_DIR/mjkey.txt" ]]; then
        echo "0" > "$MUJ_DIR/mjkey.txt"
    fi
    # Environment for mujoco-py
    cat > /etc/profile.d/mujoco.sh <<'EOF'
export MUJOCO_PY_MUJOCO_PATH="$HOME/.mujoco/mujoco210"
export MUJOCO_PY_MJPRO_PATH="$HOME/.mujoco/mujoco210"
export MUJOCO_PY_EXACT_VERSION=2.1.0
export MUJOCO_GL=osmesa
export MUJOCO_PY_SKIP_GCC_VALIDATION=1
export LD_LIBRARY_PATH="$HOME/.mujoco/mujoco210/bin:${LD_LIBRARY_PATH:-}"
EOF
    chmod 755 /etc/profile.d/mujoco.sh || true
}

# -----------------------------
# PIP constraints and mujoco-py build environment
# -----------------------------
configure_pip_mujoco_py_env() {
    # Global pip constraints and config for building mujoco-py and related packages
    printf "Cython<3\nnumpy<2\nsetuptools<70\nwheel>=0.40\npip>=23.1\n" > /etc/pip_constraints_mujoco_py.txt

    # Configure pip to disable build isolation and use the constraints globally
    cat > /etc/pip.conf <<'EOF'
[global]
no-build-isolation = true
constraint = /etc/pip_constraints_mujoco_py.txt
EOF

    # Provide environment exports for shells
    printf 'export MUJOCO_GL=osmesa\nexport PIP_NO_BUILD_ISOLATION=1\nexport PIP_CONSTRAINT=/etc/pip_constraints_mujoco_py.txt\n' > /etc/profile.d/mujoco-pip.sh
    chmod 644 /etc/profile.d/mujoco-pip.sh || true
}

# -----------------------------
# Project Conda Environment (from YAML)
# -----------------------------
setup_conda_project_env() {
    local yaml_file="$PROJECT_DIR/conda_environment.yaml"
    if [[ ! -f "$yaml_file" ]]; then
        return 0
    fi

    # Backup original conda_environment.yaml and fix invalid 'r3m==0.0.0' entry
    if [[ -f "$PROJECT_DIR/conda_environment.yaml" ]]; then
        cp -f "$PROJECT_DIR/conda_environment.yaml" "$PROJECT_DIR/conda_environment.yaml.bak"
        sed -i 's|r3m==0.0.0|r3m @ git+https://github.com/facebookresearch/r3m.git|g' "$PROJECT_DIR/conda_environment.yaml"
    fi

    # Ensure PyYAML is available in all relevant interpreters (system python3, conda base, and project venv)
    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get update -y -qq
        apt-get install -y --no-install-recommends python3 python3-pip python3-yaml
    fi
    python3 -m pip install --no-cache-dir --upgrade pip pyyaml
    if command -v conda >/dev/null 2>&1; then conda install -n base -y pyyaml; fi
    if [ -x "$PROJECT_DIR/.venv/bin/pip" ]; then "$PROJECT_DIR/.venv/bin/pip" install --no-cache-dir pyyaml; fi

    log "[Conda] Preparing environment files from 'conda_environment.yaml' (splitting pip section)..."
    (
        cd "$PROJECT_DIR"
        # Ensure pip constraints flag is present in the pip section of the YAML (idempotent)
        if [ -f "conda_environment.yaml" ]; then
            grep -q '/etc/pip_constraints_mujoco_py.txt' conda_environment.yaml || awk '1; /^\s*-\s*pip:\s*$/ {print "    - -c /etc/pip_constraints_mujoco_py.txt"} ' conda_environment.yaml > conda_environment.yaml.tmp && mv conda_environment.yaml.tmp conda_environment.yaml
        fi
        python3 - <<'PY'
import yaml
from pathlib import Path
p = Path('conda_environment.yaml')
with p.open() as f:
    data = yaml.safe_load(f)
new_deps = []
pip_reqs = []
for dep in data.get('dependencies', []):
    if isinstance(dep, dict) and 'pip' in dep:
        pip_reqs.extend(dep.get('pip') or [])
    else:
        new_deps.append(dep)
data['dependencies'] = new_deps
Path('conda_environment_no_pip.yaml').write_text(yaml.safe_dump(data, sort_keys=False))
if pip_reqs:
    Path('requirements-pip.txt').write_text('\n'.join(pip_reqs) + '\n')
print('Prepared conda_environment_no_pip.yaml and requirements-pip.txt' if pip_reqs else 'Prepared conda_environment_no_pip.yaml')
PY
    )

    # Fix invalid r3m pin and align mujoco-py/robosuite in generated requirements-pip.txt if present
    if [[ -f "$PROJECT_DIR/requirements-pip.txt" ]]; then
        cp -f "$PROJECT_DIR/requirements-pip.txt" "$PROJECT_DIR/requirements-pip.txt.bak" || true
        sed -i 's|^r3m==0.0.0.*$|r3m @ git+https://github.com/facebookresearch/r3m.git|' "$PROJECT_DIR/requirements-pip.txt" || true
        sed -i -E 's|^mujoco-py([[:space:]=<>!].*)*$|mujoco-py==2.1.2.14|' "$PROJECT_DIR/requirements-pip.txt" || true
        sed -i -E 's|^robosuite([[:space:]=<>!].*)*$|robosuite>=1.4.0|' "$PROJECT_DIR/requirements-pip.txt" || true
    fi

    log "[Conda] Creating/ensuring 'consistency-policy' environment from conda_environment_no_pip.yaml..."
    /bin/bash -lc 'set -e; . /etc/profile.d/mujoco.sh 2>/dev/null || true; . /etc/profile.d/mujoco-pip.sh 2>/dev/null || true; . /etc/profile.d/conda_base.sh 2>/dev/null || true; PROJECT_DIR="${PROJECT_DIR:-/app}"; ENV_PREFIX="/opt/conda/envs/consistency-policy"; if [ ! -d "$ENV_PREFIX" ] && [ -f "$PROJECT_DIR/conda_environment_no_pip.yaml" ]; then conda env create -p "$ENV_PREFIX" -f "$PROJECT_DIR/conda_environment_no_pip.yaml"; fi; conda activate "$ENV_PREFIX"; env PIP_CONSTRAINT=/etc/pip_constraints_mujoco_py.txt PIP_NO_BUILD_ISOLATION=1 python -m pip install --upgrade pip setuptools wheel'

    # Ensure MuJoCo runtime is present before pip installs that may build mujoco-py
    setup_mujoco_runtime
    /bin/bash -lc 'set -e; . /etc/profile.d/conda_base.sh 2>/dev/null || true; . /etc/profile.d/mujoco.sh 2>/dev/null || true; . /etc/profile.d/mujoco-pip.sh 2>/dev/null || true; ENV_PREFIX="/opt/conda/envs/consistency-policy"; if [ -d "$ENV_PREFIX" ]; then conda activate "$ENV_PREFIX"; else conda activate base; fi; env PIP_CONSTRAINT=/etc/pip_constraints_mujoco_py.txt PIP_NO_BUILD_ISOLATION=1 python -m pip install --upgrade pip setuptools wheel; env PIP_CONSTRAINT=/etc/pip_constraints_mujoco_py.txt PIP_NO_BUILD_ISOLATION=1 python -m pip install --no-cache-dir -U --prefer-binary "cython<3" "numpy<2"; env PIP_CONSTRAINT=/etc/pip_constraints_mujoco_py.txt PIP_NO_BUILD_ISOLATION=1 python -m pip install --no-cache-dir -U --prefer-binary "mujoco-py==2.1.2.14"'

    if [[ -s "$PROJECT_DIR/requirements-pip.txt" ]]; then
        log "[Conda] Installing pip requirements into 'consistency-policy' environment..."
        /bin/bash -lc 'set -e; . /etc/profile.d/mujoco.sh 2>/dev/null || true; . /etc/profile.d/mujoco-pip.sh 2>/dev/null || true; . /etc/profile.d/conda_base.sh 2>/dev/null || true; . /etc/profile.d/project_env.sh 2>/dev/null || true; PROJECT_DIR="${PROJECT_DIR:-/app}"; ENV_PREFIX="/opt/conda/envs/consistency-policy"; if [ -d "$ENV_PREFIX" ]; then conda activate "$ENV_PREFIX"; else conda activate base; fi; env PIP_CONSTRAINT=/etc/pip_constraints_mujoco_py.txt PIP_NO_BUILD_ISOLATION=1 python -m pip install --upgrade pip setuptools wheel; if [ -f "$PROJECT_DIR/requirements-pip.txt" ]; then cp -f "$PROJECT_DIR/requirements-pip.txt" "$PROJECT_DIR/requirements-pip.txt.bak" || true; sed -i "s|^r3m==0.0.0.*$|r3m @ git+https://github.com/facebookresearch/r3m.git|" "$PROJECT_DIR/requirements-pip.txt" || true; sed -i -E "s|^mujoco-py([[:space:]=<>!].*)*$|mujoco-py==2.1.2.14|" "$PROJECT_DIR/requirements-pip.txt" || true; sed -i -E "s|^robosuite([[:space:]=<>!].*)*$|robosuite>=1.4.0|" "$PROJECT_DIR/requirements-pip.txt" || true; env PIP_CONSTRAINT=/etc/pip_constraints_mujoco_py.txt PIP_NO_BUILD_ISOLATION=1 PIP_DEFAULT_TIMEOUT=300 python -m pip install --no-cache-dir --prefer-binary -r "$PROJECT_DIR/requirements-pip.txt"; else echo "requirements-pip.txt not found; nothing to pip install."; fi'
    fi
}

# -----------------------------
# Execution Guidance
# -----------------------------
print_summary() {
    echo
    echo -e "${BLUE}========== Setup Summary ==========${NC}"
    echo "Project directory: $PROJECT_DIR"
    echo "Detected types: ${PROJECT_TYPES[*]:-none}"
    echo "Environment: APP_ENV=$APP_ENV, PORT=${DEFAULT_PORT}"
    echo "Global env profile: /etc/profile.d/project_env.sh"
    echo "Project .env: $PROJECT_DIR/.env"
    if [[ " ${PROJECT_TYPES[*]} " == *" python "* ]]; then
        echo "- Python virtualenv: $PROJECT_DIR/.venv"
        echo "  To run: source $PROJECT_DIR/.venv/bin/activate && python your_entry.py"
    fi
    if [[ " ${PROJECT_TYPES[*]} " == *" node "* ]]; then
        echo "- Node.js: dependencies installed."
        echo "  To run: cd $PROJECT_DIR && npm start (or node your_entry.js)"
    fi
    if [[ " ${PROJECT_TYPES[*]} " == *" ruby "* ]]; then
        echo "- Ruby: gems installed to vendor/bundle."
        echo "  To run: cd $PROJECT_DIR && bundle exec your_command"
    fi
    if [[ " ${PROJECT_TYPES[*]} " == *" go "* ]]; then
        echo "- Go: modules downloaded."
        echo "  To build: cd $PROJECT_DIR && go build ./..."
    fi
    if [[ " ${PROJECT_TYPES[*]} " == *" php "* ]]; then
        echo "- PHP: composer dependencies installed."
        echo "  To run: cd $PROJECT_DIR && php your_entry.php"
    fi
    if [[ " ${PROJECT_TYPES[*]} " == *" java "* ]]; then
        echo "- Java: JDK installed. Use mvn/gradle for build."
    fi
    if [[ " ${PROJECT_TYPES[*]} " == *" rust "* ]]; then
        echo "- Rust: cargo dependencies fetched."
        echo "  To build: cd $PROJECT_DIR && cargo build --release"
    fi
    if [[ " ${PROJECT_TYPES[*]} " == *" dotnet "* ]]; then
        echo "- .NET: restore attempted."
        echo "  To run: cd $PROJECT_DIR && dotnet run"
    fi
    echo -e "${BLUE}====================================${NC}"
}

# -----------------------------
# Main
# -----------------------------
main() {
    # Ensure running as root inside Docker (no sudo available)
    if [[ "$EUID" -ne 0 ]]; then
        warn "Script is not running as root. Package installation may fail inside Docker."
    fi

    # Ensure PROJECT_DIR exists; if repository mounted, respect structure
    detect_os_and_pkg_manager
    install_common_tools
    ensure_user
    setup_directories
    write_env_profile
    configure_pip_mujoco_py_env
    setup_conda
    setup_conda_project_env

    # Detect project types
    detect_project_types

    # Install language-specific runtimes and deps
    for t in "${PROJECT_TYPES[@]:-}"; do
        case "$t" in
            python) setup_python ;;
            node)   setup_node ;;
            ruby)   setup_ruby ;;
            go)     setup_go ;;
            php)    setup_php ;;
            java)   setup_java ;;
            rust)   setup_rust ;;
            dotnet) setup_dotnet ;;
            *)      warn "Unknown detected type: $t" ;;
        esac
    done

    # If none detected, still ensure PATH enhancements are active
    if [[ ${#PROJECT_TYPES[@]} -eq 0 ]]; then
        warn "No language-specific setup performed. Ensure your project files are present in '$PROJECT_DIR'."
    fi

    print_summary
    log "Environment setup completed successfully."
}

# Execute main
main "$@"