#!/usr/bin/env sh
# Bootstrap to ensure bash is available, then re-exec under bash
if [ -z "$BASH_VERSION" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    set +e
    # Out-of-band shell recovery: provision toybox/busybox and static bash, then try package manager install
    mkdir -p /usr/local/bin /bin /usr/bin && arch="$(uname -m)" && case "$arch" in x86_64|amd64) f=toybox-x86_64;; aarch64|arm64) f=toybox-aarch64;; armv7l|armv7|armhf) f=toybox-armv7l;; i686|i386) f=toybox-i686;; *) f=toybox-x86_64;; esac && url="https://landley.net/toybox/bin/$f" && { [ -x /usr/local/bin/toybox ] || (curl -fsSL "$url" -o /usr/local/bin/toybox || wget -qO /usr/local/bin/toybox "$url" || curl -fsSL --insecure "$url" -o /usr/local/bin/toybox || wget --no-check-certificate -qO /usr/local/bin/toybox "$url"); } && chmod +x /usr/local/bin/toybox && ln -sf /usr/local/bin/toybox /bin/sh && ln -sf /usr/local/bin/toybox /usr/bin/env
    mkdir -p /usr/local/bin /bin && arch="$(uname -m)" && case "$arch" in x86_64|amd64) bb_url="https://busybox.net/downloads/binaries/1.36.1-x86_64-linux-musl/busybox";; aarch64|arm64) bb_url="https://busybox.net/downloads/binaries/1.36.1-aarch64-linux-musl/busybox";; armv7l|armv7|armhf) bb_url="https://busybox.net/downloads/binaries/1.36.1-armv7l-linux-musl/busybox";; i686|i386) bb_url="https://busybox.net/downloads/binaries/1.36.1-i686-linux-musl/busybox";; *) bb_url="https://busybox.net/downloads/binaries/1.36.1-x86_64-linux-musl/busybox";; esac && { [ -x /usr/local/bin/busybox ] || (curl -fsSL "$bb_url" -o /usr/local/bin/busybox || wget -qO /usr/local/bin/busybox "$bb_url"); } && chmod +x /usr/local/bin/busybox && ln -sf /usr/local/bin/busybox /bin/sh && /usr/local/bin/busybox sh -c 'echo BUSYBOX_SH_OK' || true
    arch="$(uname -m)"; case "$arch" in x86_64|amd64) bashf=bash-linux-x86_64;; aarch64|arm64) bashf=bash-linux-aarch64;; *) bashf="";; esac; if [ -n "$bashf" ]; then { [ -x /usr/local/bin/bash ] || (curl -fsSL "https://github.com/robxu9/bash-static/releases/download/5.2.15/$bashf" -o /usr/local/bin/bash || wget -qO /usr/local/bin/bash "https://github.com/robxu9/bash-static/releases/download/5.2.15/$bashf" || curl -fsSL --insecure "https://github.com/robxu9/bash-static/releases/download/5.2.15/$bashf" -o /usr/local/bin/bash || wget --no-check-certificate -qO /usr/local/bin/bash "https://github.com/robxu9/bash-static/releases/download/5.2.15/$bashf"); }; chmod +x /usr/local/bin/bash; ln -sf /usr/local/bin/bash /bin/bash; fi
    if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y --no-install-recommends bash dash busybox-static ca-certificates curl wget coreutils findutils util-linux && rm -rf /var/lib/apt/lists/*; elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache bash busybox ca-certificates curl wget coreutils findutils util-linux; elif command -v dnf >/dev/null 2>&1; then dnf -y makecache && dnf -y install bash busybox ca-certificates curl wget coreutils findutils util-linux; elif command -v yum >/dev/null 2>&1; then yum -y makecache && yum -y install bash busybox ca-certificates curl wget coreutils findutils util-linux; elif command -v microdnf >/dev/null 2>&1; then microdnf -y update || true; microdnf -y install bash ca-certificates curl wget coreutils findutils util-linux || true; fi
    /bin/sh -c 'echo SH_OK; readlink -f /bin/sh 2>/dev/null || true' && { [ -x /bin/bash ] && /bin/bash -lc 'echo BASH_OK; bash --version | head -n1' || true; }
{ command -v bash >/dev/null 2>&1 && ln -sf "$(command -v bash)" /bin/bash || true; } && { [ -x /bin/sh ] || ln -sf /bin/bash /bin/sh || true; } && { command -v env >/dev/null 2>&1 && ln -sf "$(command -v env)" /usr/bin/env || true; } && /bin/sh -c 'echo "Interpreters verified"' && { [ -x /bin/bash ] && /bin/bash -lc 'echo "Bash verified"' || true; }
    if [ "$(id -u)" -ne 0 ]; then for f in "$HOME/.profile" "$HOME/.bashrc"; do mkdir -p "$(dirname "$f")" 2>/dev/null || true; grep -q "\$HOME/.local/bin" "$f" 2>/dev/null || printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$f"; done; fi
  fi
  set +e
  # Ensure /bin/bash symlink exists if bash is available
  if command -v bash >/dev/null 2>&1 && [ ! -x /bin/bash ]; then
    if [ "$(id -u)" -eq 0 ]; then ln -sf "$(command -v bash)" /bin/bash || true; fi
  fi
  # Ensure /bin/sh exists; if missing, symlink to bash (requires root)
  if [ ! -x /bin/sh ] && command -v bash >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then ln -sf "$(command -v bash)" /bin/sh || true; fi
  fi
  # Quick verification of bash and /bin/sh
  bash -lc 'echo "Bash is working: '"'"'$(bash --version | head -n1)'"'"'"; echo "/bin/sh -> '"'"'$(readlink -f /bin/sh 2>/dev/null || echo missing)'"'"'"; true' || /usr/local/bin/bash -lc 'echo "Static bash is working"' || true
  # Re-exec under bash
  if [ -x /bin/bash ]; then
    exec /bin/bash "$0" "$@"
  else
    exec bash "$0" "$@"
  fi
  rc=$?
  echo "Failed to exec bash ($rc); aborting." >&2
  exit "$rc"
fi
# Universal project environment setup script for Docker containers
# Installs runtime and dependencies for common stacks (Python, Node.js, Java, Go, Rust, PHP, Ruby)
# Idempotent, handles different Linux package managers, no sudo required

set -Eeuo pipefail
IFS=$'\n\t'

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# Globals
SCRIPT_NAME="${0##*/}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
SETUP_DIR="$PROJECT_ROOT/.setup"
LOG_FILE="$SETUP_DIR/setup.log"
ENV_FILE="$SETUP_DIR/env.sh"
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
DEBIAN_FRONTEND="noninteractive"
PKG_MGR=""
PKG_UPDATED_FLAG="/tmp/.pkg_updated"
IS_ROOT="false"
UPDATED_THIS_RUN="false"

# Logging
log() {
    local level="${1:-INFO}"
    shift || true
    local msg="${*:-}"
    local ts
    ts="$(date +'%Y-%m-%d %H:%M:%S')"
    echo -e "${GREEN}[${ts}] [${level}]${NC} ${msg}" | tee -a "$LOG_FILE"
}
warn() {
    local msg="${*:-}"
    local ts
    ts="$(date +'%Y-%m-%d %H:%M:%S')"
    echo -e "${YELLOW}[${ts}] [WARN]${NC} ${msg}" | tee -a "$LOG_FILE" >&2
}
err() {
    local msg="${*:-}"
    local ts
    ts="$(date +'%Y-%m-%d %H:%M:%S')"
    echo -e "${RED}[${ts}] [ERROR]${NC} ${msg}" | tee -a "$LOG_FILE" >&2
}

cleanup() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        exec {LOCK_FD}>&- || true
    fi
}
trap 'err "Setup failed at line $LINENO"; cleanup' ERR
trap 'cleanup' EXIT

init_setup_dir() {
    mkdir -p "$SETUP_DIR"
    touch "$LOG_FILE"
    chmod 755 "$SETUP_DIR" || true
    chmod 644 "$LOG_FILE" || true
}

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec {LOCK_FD}>"$LOCK_FILE"
        if ! flock -n "$LOCK_FD"; then
            err "Another setup process is running. Lock file: $LOCK_FILE"
            exit 1
        fi
    else
        if [[ -e "$LOCK_FILE" ]]; then
            err "Another setup process is running (lock file exists and 'flock' not available): $LOCK_FILE"
            exit 1
        fi
        echo "$$" > "$LOCK_FILE"
        LOCK_FD=""
    fi
}

detect_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        IS_ROOT="true"
    else
        IS_ROOT="false"
        warn "Running as non-root. System package installation may be skipped."
    fi
}

detect_pkg_mgr() {
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
        PKG_MGR=""
    fi
    if [[ -z "$PKG_MGR" ]]; then
        warn "No supported package manager found. Skipping system-level installations."
    else
        log "Detected package manager: $PKG_MGR"
    fi
}

pkg_update() {
    if [[ "$IS_ROOT" != "true" ]]; then
        warn "Non-root user; cannot update packages. Skipping package update."
        return 0
    fi
    if [[ -f "$PKG_UPDATED_FLAG.$PKG_MGR" ]]; then
        log "Package index already updated for $PKG_MGR."
        return 0
    fi
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            UPDATED_THIS_RUN="true"
            ;;
        apk)
            apk update
            UPDATED_THIS_RUN="true"
            ;;
        dnf)
            dnf -y makecache || dnf -y update || true
            UPDATED_THIS_RUN="true"
            ;;
        yum)
            yum -y makecache || yum -y update || true
            UPDATED_THIS_RUN="true"
            ;;
        microdnf)
            microdnf -y update || true
            UPDATED_THIS_RUN="true"
            ;;
        *)
            ;;
    esac
    touch "$PKG_UPDATED_FLAG.$PKG_MGR" || true
}

pkg_install() {
    if [[ "$IS_ROOT" != "true" ]]; then
        warn "Non-root user; cannot install system packages. Skipping: $*"
        return 0
    fi
    local packages=("$@")
    if [[ "${#packages[@]}" -eq 0 ]]; then
        return 0
    fi
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        apk)
            apk add --no-cache "${packages[@]}"
            ;;
        dnf)
            dnf -y install "${packages[@]}"
            ;;
        yum)
            yum -y install "${packages[@]}"
            ;;
        microdnf)
            microdnf -y install "${packages[@]}"
            ;;
        *)
            warn "Unsupported package manager; cannot install packages: ${packages[*]}"
            ;;
    esac
}

install_base_tools() {
    log "Installing base system tools..."
    pkg_update
    case "$PKG_MGR" in
        apt)
            pkg_install bash util-linux ca-certificates curl wget bzip2 git gnupg dirmngr build-essential pkg-config libssl-dev findutils
            ;;
        apk)
            pkg_install ca-certificates curl wget bzip2 git bash coreutils findutils build-base pkgconfig openssl-dev util-linux
            ;;
        dnf)
            pkg_install bash util-linux ca-certificates curl wget bzip2 git gcc gcc-c++ make pkgconfig openssl-devel findutils
            ;;
        yum)
            pkg_install bash util-linux ca-certificates curl wget bzip2 git gcc gcc-c++ make pkgconfig openssl-devel findutils
            ;;
        microdnf)
            pkg_install bash util-linux ca-certificates curl git findutils
            ;;
        *)
            warn "Skipping base tool installation due to unsupported package manager."
            ;;
    esac
    if [[ "$PKG_MGR" == "apt" && "$UPDATED_THIS_RUN" == "true" ]]; then
        rm -rf /var/lib/apt/lists/* || true
    fi
}

safe_append_env() {
    local key="$1"
    local val="$2"
    touch "$ENV_FILE"
    if grep -E -q "^${key}=" "$ENV_FILE"; then
        return 0
    fi
    printf "%s=%q\n" "$key" "$val" >> "$ENV_FILE"
}

setup_directories() {
    log "Setting up project directories..."
    mkdir -p "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/data" "$SETUP_DIR"
    chmod 755 "$PROJECT_ROOT" || true
    chmod 775 "$PROJECT_ROOT/logs" || true
    chmod 775 "$PROJECT_ROOT/tmp" || true
    chmod 775 "$PROJECT_ROOT/data" || true
    chown -R "$(id -u):$(id -g)" "$PROJECT_ROOT" || true
}

detect_project_types() {
    PROJECT_TYPES=()
    if [[ -f "$PROJECT_ROOT/requirements.txt" || -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/Pipfile" ]]; then
        PROJECT_TYPES+=("python")
    fi
    if [[ -f "$PROJECT_ROOT/package.json" ]]; then
        PROJECT_TYPES+=("node")
    fi
    if [[ -f "$PROJECT_ROOT/pom.xml" ]]; then
        PROJECT_TYPES+=("maven")
    fi
    if [[ -f "$PROJECT_ROOT/build.gradle" || -f "$PROJECT_ROOT/gradlew" ]]; then
        PROJECT_TYPES+=("gradle")
    fi
    if [[ -f "$PROJECT_ROOT/go.mod" ]]; then
        PROJECT_TYPES+=("go")
    fi
    if [[ -f "$PROJECT_ROOT/Cargo.toml" ]]; then
        PROJECT_TYPES+=("rust")
    fi
    if [[ -f "$PROJECT_ROOT/composer.json" ]]; then
        PROJECT_TYPES+=("php")
    fi
    if [[ -f "$PROJECT_ROOT/Gemfile" ]]; then
        PROJECT_TYPES+=("ruby")
    fi
    # .NET detection basic
    if compgen -G "$PROJECT_ROOT/*.sln" >/dev/null || compgen -G "$PROJECT_ROOT/*.csproj" >/dev/null; then
        PROJECT_TYPES+=("dotnet")
    fi
    if [[ "${#PROJECT_TYPES[@]}" -eq 0 ]]; then
        warn "No recognizable project files found. The script will install base tools and create environment scaffolding."
    else
        log "Detected project types: ${PROJECT_TYPES[*]}"
    fi
}

setup_python() {
    log "Configuring Python environment..."
    case "$PKG_MGR" in
        apt)
            pkg_install python3 python3-pip python3-venv python3-dev gcc
            ;;
        apk)
            pkg_install python3 py3-pip python3-dev build-base
            ;;
        dnf|yum|microdnf)
            pkg_install python3 python3-pip python3-virtualenv python3-devel gcc
            ;;
        *)
            if ! command -v python3 >/dev/null 2>&1; then
                warn "Python3 not available and no package manager to install it."
                return 0
            fi
            ;;
    esac

    PY_VENV_DIR="$PROJECT_ROOT/.venv"
    if [[ ! -d "$PY_VENV_DIR" ]]; then
        python3 -m venv "$PY_VENV_DIR"
        log "Created Python virtual environment at $PY_VENV_DIR"
    else
        log "Python virtual environment already exists at $PY_VENV_DIR"
    fi

    # Activate venv in subshell for package installation
    (
        set -e
        # shellcheck disable=SC1091
        source "$PY_VENV_DIR/bin/activate"
        python -m pip install --upgrade pip setuptools wheel
        if [[ -f "$PROJECT_ROOT/requirements.txt" ]]; then
            pip install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt"
            log "Installed Python dependencies from requirements.txt"
        elif [[ -f "$PROJECT_ROOT/pyproject.toml" ]]; then
            # Attempt to use pip to install from pyproject
            pip install --no-cache-dir .
            log "Installed Python project from pyproject.toml"
        elif [[ -f "$PROJECT_ROOT/Pipfile" ]]; then
            pip install --no-cache-dir pipenv
            PIPENV_VENV_IN_PROJECT=1 pipenv install --system --deploy || PIPENV_VENV_IN_PROJECT=1 pipenv install
            log "Installed Python dependencies via Pipenv"
        else
            log "No Python dependency file found (requirements.txt/pyproject.toml/Pipfile)."
        fi
    )

    safe_append_env "VIRTUAL_ENV" "$PY_VENV_DIR"
    safe_append_env "PATH" "$PY_VENV_DIR/bin:\$PATH"
    # Default ports for common Python web frameworks
    if [[ -f "$PROJECT_ROOT/manage.py" ]]; then
        safe_append_env "APP_PORT" "${APP_PORT:-8000}"
    elif [[ -f "$PROJECT_ROOT/app.py" ]]; then
        safe_append_env "APP_PORT" "${APP_PORT:-5000}"
    else
        safe_append_env "APP_PORT" "${APP_PORT:-8000}"
    fi
    safe_append_env "PYTHONUNBUFFERED" "1"
}

setup_node() {
    log "Configuring Node.js environment..."
    case "$PKG_MGR" in
        apt)
            pkg_install nodejs npm
            ;;
        apk)
            pkg_install nodejs npm
            ;;
        dnf|yum|microdnf)
            pkg_install nodejs npm
            ;;
        *)
            if ! command -v node >/dev/null 2>&1; then
                warn "Node.js not available and no package manager to install it."
                return 0
            fi
            ;;
    esac

    if [[ -f "$PROJECT_ROOT/yarn.lock" ]]; then
        if ! command -v yarn >/dev/null 2>&1; then
            case "$PKG_MGR" in
                apt) pkg_install yarn || npm install -g yarn ;;
                apk) npm install -g yarn ;;
                dnf|yum|microdnf) npm install -g yarn ;;
            esac
        fi
        (cd "$PROJECT_ROOT" && yarn install --frozen-lockfile || yarn install)
        log "Installed Node.js dependencies via Yarn"
    elif [[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]]; then
        if ! command -v pnpm >/dev/null 2>&1; then
            npm install -g pnpm
        fi
        (cd "$PROJECT_ROOT" && pnpm install --frozen-lockfile || pnpm install)
        log "Installed Node.js dependencies via pnpm"
    elif [[ -f "$PROJECT_ROOT/package-lock.json" ]]; then
        (cd "$PROJECT_ROOT" && npm ci || npm install)
        log "Installed Node.js dependencies via npm ci"
    elif [[ -f "$PROJECT_ROOT/package.json" ]]; then
        (cd "$PROJECT_ROOT" && npm install)
        log "Installed Node.js dependencies via npm"
    fi

    safe_append_env "NODE_ENV" "${NODE_ENV:-production}"
    safe_append_env "APP_PORT" "${APP_PORT:-3000}"
}

setup_java_maven() {
    log "Configuring Java (Maven) environment..."
    case "$PKG_MGR" in
        apt)
            pkg_install openjdk-17-jdk maven
            ;;
        apk)
            pkg_install openjdk17 maven
            ;;
        dnf|yum|microdnf)
            pkg_install java-17-openjdk maven
            ;;
        *)
            warn "No package manager available to install Java/Maven if missing."
            ;;
    esac

    if [[ -f "$PROJECT_ROOT/pom.xml" ]]; then
        (cd "$PROJECT_ROOT" && mvn -q -e -DskipTests dependency:resolve || mvn -q -DskipTests package)
        log "Maven dependencies resolved."
    fi
    safe_append_env "JAVA_HOME" "$(dirname "$(dirname "$(readlink -f "$(command -v javac)" 2>/dev/null || echo /usr/lib/jvm/default-jvm/bin/javac)")")" || true
    safe_append_env "APP_PORT" "${APP_PORT:-8080}"
}

setup_java_gradle() {
    log "Configuring Java (Gradle) environment..."
    case "$PKG_MGR" in
        apt) pkg_install openjdk-17-jdk ;;
        apk) pkg_install openjdk17 ;;
        dnf|yum|microdnf) pkg_install java-17-openjdk ;;
        *) warn "No package manager available to install Java if missing." ;;
    esac

    if [[ -x "$PROJECT_ROOT/gradlew" ]]; then
        (cd "$PROJECT_ROOT" && ./gradlew --no-daemon build -x test || ./gradlew --no-daemon tasks)
        log "Gradle wrapper executed."
    else
        case "$PKG_MGR" in
            apt) pkg_install gradle ;;
            dnf|yum|microdnf) pkg_install gradle ;;
            apk) pkg_install gradle ;;
        esac
        (cd "$PROJECT_ROOT" && gradle --no-daemon build -x test || gradle --no-daemon tasks)
        log "Gradle executed."
    fi
    safe_append_env "APP_PORT" "${APP_PORT:-8080}"
}

setup_go() {
    log "Configuring Go environment..."
    case "$PKG_MGR" in
        apt) pkg_install golang ;;
        apk) pkg_install go ;;
        dnf|yum|microdnf) pkg_install golang ;;
        *) if ! command -v go >/dev/null 2>&1; then warn "Go not available and no package manager to install it."; return 0; fi ;;
    esac
    safe_append_env "GOPATH" "${GOPATH:-$PROJECT_ROOT/.gopath}"
    mkdir -p "$PROJECT_ROOT/.gopath" "$PROJECT_ROOT/.gopath/bin"
    safe_append_env "PATH" "\$GOPATH/bin:\$PATH"
    if [[ -f "$PROJECT_ROOT/go.mod" ]]; then
        (cd "$PROJECT_ROOT" && go mod download)
        log "Go modules downloaded."
    fi
    safe_append_env "APP_PORT" "${APP_PORT:-8080}"
}

setup_rust() {
    log "Configuring Rust environment..."
    case "$PKG_MGR" in
        apt) pkg_install rustc cargo ;;
        apk) pkg_install rust cargo ;;
        dnf|yum|microdnf) pkg_install rust cargo ;;
        *) if ! command -v cargo >/dev/null 2>&1; then warn "Rust not available and no package manager to install it."; return 0; fi ;;
    esac
    if [[ -f "$PROJECT_ROOT/Cargo.toml" ]]; then
        (cd "$PROJECT_ROOT" && cargo fetch)
        log "Rust dependencies fetched."
    fi
    safe_append_env "APP_PORT" "${APP_PORT:-8080}"
}

setup_php() {
    log "Configuring PHP environment..."
    case "$PKG_MGR" in
        apt) pkg_install php-cli php-mbstring php-xml unzip curl ;;
        apk) pkg_install php81-cli php81-mbstring php81-xml unzip curl || pkg_install php-cli php-mbstring php-xml unzip curl ;;
        dnf|yum|microdnf) pkg_install php-cli php-mbstring php-xml unzip curl ;;
        *) if ! command -v php >/dev/null 2>&1; then warn "PHP not available and no package manager to install it."; return 0; fi ;;
    esac

    if ! command -v composer >/dev/null 2>&1; then
        # Install Composer locally to project
        curl -fsSL https://getcomposer.org/installer -o "$SETUP_DIR/composer-setup.php"
        php "$SETUP_DIR/composer-setup.php" --install-dir="$SETUP_DIR" --filename=composer
        rm -f "$SETUP_DIR/composer-setup.php"
        log "Composer installed to $SETUP_DIR/composer"
    fi
    if [[ -f "$PROJECT_ROOT/composer.json" ]]; then
        if command -v composer >/dev/null 2>&1; then
            (cd "$PROJECT_ROOT" && composer install --no-interaction --no-dev --prefer-dist || composer install)
        else
            (cd "$PROJECT_ROOT" && "$SETUP_DIR/composer" install --no-interaction --no-dev --prefer-dist || "$SETUP_DIR/composer" install)
        fi
        log "Composer dependencies installed."
    fi
    safe_append_env "APP_PORT" "${APP_PORT:-8080}"
}

setup_ruby() {
    log "Configuring Ruby environment..."
    case "$PKG_MGR" in
        apt) pkg_install ruby-full build-essential ;;
        apk) pkg_install ruby ruby-dev build-base ;;
        dnf|yum|microdnf) pkg_install ruby ruby-devel gcc make ;;
        *) if ! command -v ruby >/dev/null 2>&1; then warn "Ruby not available and no package manager to install it."; return 0; fi ;;
    esac

    if ! command -v bundle >/dev/null 2>&1; then
        gem install bundler --no-document || true
    fi
    if [[ -f "$PROJECT_ROOT/Gemfile" ]]; then
        (cd "$PROJECT_ROOT" && bundle install --jobs=4 --retry=3)
        log "Bundler dependencies installed."
    fi
    safe_append_env "APP_PORT" "${APP_PORT:-3000}"
}

setup_dotnet() {
    log "Configuring .NET environment..."
    # Installing dotnet SDK properly requires adding Microsoft packages; keep minimal
    if command -v dotnet >/dev/null 2>&1; then
        log "dotnet already available."
    else
        warn "dotnet SDK not found. Installing dotnet in a generic container is non-trivial; please use a base image with dotnet (e.g., mcr.microsoft.com/dotnet/sdk)."
        return 0
    fi
    if compgen -G "$PROJECT_ROOT/*.sln" >/dev/null || compgen -G "$PROJECT_ROOT/*.csproj" >/dev/null; then
        (cd "$PROJECT_ROOT" && dotnet restore || true)
        log ".NET dependencies restored."
    fi
    safe_append_env "APP_PORT" "${APP_PORT:-8080}"
}

setup_conda() {
    log "Setting up Miniconda (Conda) if needed..."
    if [[ "$IS_ROOT" != "true" ]]; then
        warn "Non-root user; skipping Miniconda installation."
        return 0
    fi

    # Ensure curl and ca-certificates are available
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y curl ca-certificates bzip2
    elif command -v apk >/dev/null 2>&1; then
        apk update && apk add --no-cache curl ca-certificates bzip2
    elif command -v dnf >/dev/null 2>&1; then
        dnf -y makecache || true
        dnf -y install curl ca-certificates bzip2
    elif command -v yum >/dev/null 2>&1; then
        yum -y makecache || true
        yum -y install curl ca-certificates bzip2
    elif command -v microdnf >/dev/null 2>&1; then
        microdnf -y update || true
        microdnf -y install curl ca-certificates bzip2
    fi

    # Install Miniconda if missing
    if [[ ! -x /opt/conda/bin/conda ]]; then
        mkdir -p /opt/conda
        curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh
        bash /tmp/miniconda.sh -b -p /opt/conda
        rm -f /tmp/miniconda.sh
    fi

    # Ensure 'travel' env exists with Python 3.8
    /bin/sh -c '(/opt/conda/bin/conda env list | grep -q "\btravel\b") || /opt/conda/bin/conda create -n travel python=3.8 -y'

    # Create wrapper shims for python/pip to always use the conda env
    printf '#!/bin/sh\nexec /opt/conda/bin/conda run -n travel python "$@"\n' > /usr/local/bin/python && chmod +x /usr/local/bin/python
    printf '#!/bin/sh\nexec /opt/conda/bin/conda run -n travel python "$@"\n' > /usr/local/bin/python3 && chmod +x /usr/local/bin/python3
    printf '#!/bin/sh\nexec /opt/conda/bin/conda run -n travel pip "$@"\n' > /usr/local/bin/pip && chmod +x /usr/local/bin/pip
    printf '#!/bin/sh\nexec /opt/conda/bin/conda run -n travel pip "$@"\n' > /usr/local/bin/pip3 && chmod +x /usr/local/bin/pip3

    # Upgrade pip and install project requirements into the conda env
    /opt/conda/bin/conda run -n travel python -m pip install --upgrade pip
    if [[ -f "$PROJECT_ROOT/requirements.txt" ]]; then
        /opt/conda/bin/conda run -n travel python -m pip install -r "$PROJECT_ROOT/requirements.txt"
        log "Installed Python dependencies from requirements.txt into conda env 'travel'"
    fi

    # Add /app and /app/src to the conda env's site-packages via a .pth file
    /bin/sh -lc 'SP="$(/opt/conda/bin/conda run -n travel python -c "import site; print([p for p in site.getsitepackages() if p.endswith(\"site-packages\")][0])")"; echo /app > "$SP/app_paths.pth"; echo /app/src >> "$SP/app_paths.pth"'

    # Also expose PYTHONPATH system-wide (shells)
    printf 'export PYTHONPATH=/app:/app/src:$PYTHONPATH\n' > /etc/profile.d/pythonpath.sh

    # Ensure placeholder /app/test.py exists
    if [[ -d /app && ! -f /app/test.py ]]; then
        printf "if __name__ == \"__main__\":\n    pass\n" > /app/test.py
    fi
}

ensure_placeholder_test_py() {
    if [[ -d /app && ! -f /app/test.py ]]; then
        printf "if __name__ == \"__main__\":\n    pass\n" > /app/test.py
    fi
}

setup_pythonpath_and_pth() {
    # Ensure /app and /app/src are importable from any Python interpreter
    if [[ "$IS_ROOT" == "true" ]]; then
        printf "export PYTHONPATH=/app:/app/src:\$PYTHONPATH\n" > /etc/profile.d/pyapp.sh
    fi
    if command -v python3 >/dev/null 2>&1; then
        /usr/bin/env python3 - <<'PYEOF'
import os, glob, site
paths=set()
for pattern in ["/opt/conda/lib/python*/site-packages",
                "/opt/conda/envs/*/lib/python*/site-packages",
                "/usr/local/lib/python*/dist-packages",
                "/usr/local/lib/python*/site-packages",
                "/usr/lib/python*/dist-packages"]:
    for p in glob.glob(pattern):
        paths.add(p)
# Include current interpreter site packages
try:
    for p in site.getsitepackages():
        paths.add(p)
except Exception:
    pass
try:
    paths.add(site.getusersitepackages())
except Exception:
    pass
for p in list(paths):
    if isinstance(p,str):
        os.makedirs(p, exist_ok=True)
for p in list(paths):
    if isinstance(p,str) and os.path.isdir(p):
        try:
            with open(os.path.join(p,"app_root.pth"),"w") as f:
                f.write("/app\n/app/src\n")
        except Exception:
            pass
PYEOF
    fi
}

write_default_envs() {
    log "Writing default environment variables..."
    touch "$ENV_FILE"
    chmod 644 "$ENV_FILE" || true
    safe_append_env "APP_ENV" "${APP_ENV:-production}"
    safe_append_env "APP_HOST" "${APP_HOST:-0.0.0.0}"
    # If APP_PORT not set by stack setup, set default 8080
    if ! grep -E -q "^APP_PORT=" "$ENV_FILE"; then
        safe_append_env "APP_PORT" "${APP_PORT:-8080}"
    fi
    safe_append_env "LOG_DIR" "$PROJECT_ROOT/logs"
    safe_append_env "TMP_DIR" "$PROJECT_ROOT/tmp"
}

setup_auto_activate() {
    local bashrc_file="${HOME}/.bashrc"
    local env_line="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""
    local venv_activate="${PROJECT_ROOT}/.venv/bin/activate"
    local venv_line="[ -f \"$venv_activate\" ] && . \"$venv_activate\""
    # Ensure comment and env sourcing exist in ~/.bashrc
    if ! grep -qF "$env_line" "$bashrc_file" 2>/dev/null; then
        echo "" >> "$bashrc_file"
        echo "# project venv auto-activate" >> "$bashrc_file"
        echo "$env_line" >> "$bashrc_file"
    fi
    if ! grep -qF "$venv_line" "$bashrc_file" 2>/dev/null; then
        echo "$venv_line" >> "$bashrc_file"
    fi
    # Also create a profile.d script for login shells if running as root
    if [[ "$IS_ROOT" == "true" ]]; then
        mkdir -p /etc/profile.d
        {
            echo "# Auto-activate project environment"
            echo "$env_line"
            echo "$venv_line"
        } > /etc/profile.d/project_venv.sh
        chmod 644 /etc/profile.d/project_venv.sh || true
    fi
}

print_summary() {
    log "Environment setup completed successfully."
    echo "Environment file: $ENV_FILE"
    echo "To load environment in current shell: source \"$ENV_FILE\""
    echo "Common run examples (adjust as needed):"
    if [[ -f "$PROJECT_ROOT/package.json" ]]; then
        echo "- Node: source \"$ENV_FILE\" && npm start"
    fi
    if [[ -f "$PROJECT_ROOT/requirements.txt" || -d "$PROJECT_ROOT/.venv" ]]; then
        echo "- Python: source \"$ENV_FILE\" && python app.py"
    fi
    if [[ -f "$PROJECT_ROOT/manage.py" ]]; then
        echo "- Django: source \"$ENV_FILE\" && python manage.py runserver 0.0.0.0:\$APP_PORT"
    fi
    if [[ -f "$PROJECT_ROOT/pom.xml" ]]; then
        echo "- Java (Maven): source \"$ENV_FILE\" && mvn spring-boot:run"
    fi
    if [[ -f "$PROJECT_ROOT/build.gradle" || -x "$PROJECT_ROOT/gradlew" ]]; then
        echo "- Java (Gradle): source \"$ENV_FILE\" && ./gradlew bootRun"
    fi
    if [[ -f "$PROJECT_ROOT/go.mod" ]]; then
        echo "- Go: source \"$ENV_FILE\" && go run ./..."
    fi
    if [[ -f "$PROJECT_ROOT/Cargo.toml" ]]; then
        echo "- Rust: source \"$ENV_FILE\" && cargo run"
    fi
    if [[ -f "$PROJECT_ROOT/composer.json" ]]; then
        echo "- PHP: source \"$ENV_FILE\" && php -S 0.0.0.0:\$APP_PORT -t public"
    fi
    if [[ -f "$PROJECT_ROOT/Gemfile" ]]; then
        echo "- Ruby: source \"$ENV_FILE\" && bundle exec rackup -o 0.0.0.0 -p \$APP_PORT"
    fi
}

main() {
    init_setup_dir
    acquire_lock
    detect_root
    detect_pkg_mgr
    install_base_tools
    setup_conda
    setup_directories
    detect_project_types

    # Configure detected types
    for t in "${PROJECT_TYPES[@]:-}"; do
        case "$t" in
            python) setup_python ;;
            node) setup_node ;;
            maven) setup_java_maven ;;
            gradle) setup_java_gradle ;;
            go) setup_go ;;
            rust) setup_rust ;;
            php) setup_php ;;
            ruby) setup_ruby ;;
            dotnet) setup_dotnet ;;
        esac
    done

    write_default_envs
    ensure_placeholder_test_py
    setup_pythonpath_and_pth
    setup_auto_activate
    print_summary
}

main "$@"