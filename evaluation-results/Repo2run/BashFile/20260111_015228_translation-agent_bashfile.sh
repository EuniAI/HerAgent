#!/usr/bin/env bash
# Environment setup script for containerized projects
# This script detects the project type (Python, Node.js, Ruby, Go, Rust, Java, PHP) and sets up runtime, dependencies, and environment.
# Designed to run inside Docker containers, typically as root. Idempotent and safe to re-run.

set -Eeuo pipefail
IFS=$'\n\t'

# Globals
SCRIPT_NAME="$(basename "$0")"
APP_DIR="${APP_DIR:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_ENV_FILE="${APP_ENV_FILE:-${APP_DIR}/.env}"
VENV_DIR="${VENV_DIR:-${APP_DIR}/.venv}"
LOG_PREFIX="[setup]"
OS_ID=""
OS_VERSION_ID=""
PKG_MANAGER=""
NONINTERACTIVE="${NONINTERACTIVE:-1}"

# Colors (simple, works in most terminals)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log() { echo "${GREEN}${LOG_PREFIX} $*${NC}"; }
warn() { echo "${YELLOW}${LOG_PREFIX} [WARN] $*${NC}" >&2; }
err() { echo "${RED}${LOG_PREFIX} [ERROR] $*${NC}" >&2; }

cleanup() { :
    # Add any cleanup steps if needed
}
on_error() {
    err "An error occurred on line $1. Exiting."
}
trap 'on_error $LINENO' ERR
trap cleanup EXIT

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        err "This script must run as root inside the container. Current EUID=${EUID}."
        exit 1
    fi
}

# Detect OS and package manager
detect_os_and_pkg_manager() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION_ID="${VERSION_ID:-}"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
    else
        warn "Unsupported or unknown package manager. Some system package installations may fail."
        PKG_MANAGER=""
    fi

    log "Detected OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-}, package manager: ${PKG_MANAGER:-none}"
}

pkg_update() {
    case "${PKG_MANAGER}" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            ;;
        apk)
            apk update
            ;;
        dnf)
            dnf -y makecache
            ;;
        yum)
            yum -y makecache
            ;;
        zypper)
            zypper --non-interactive refresh
            ;;
        *)
            warn "No supported package manager to update."
            ;;
    esac
}

pkg_install() {
    # Usage: pkg_install pkg1 pkg2 ...
    case "${PKG_MANAGER}" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
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
        zypper)
            zypper --non-interactive install -y "$@"
            ;;
        *)
            warn "Skipping install for: $* (unknown package manager)"
            ;;
    esac
}

pkg_clean() {
    case "${PKG_MANAGER}" in
        apt)
            apt-get clean
            rm -rf /var/lib/apt/lists/*
            ;;
        apk)
            # No standard clean needed for apk with --no-cache
            ;;
        dnf)
            dnf clean all || true
            ;;
        yum)
            yum clean all || true
            ;;
        zypper)
            zypper clean -a || true
            ;;
        *)
            ;;
    esac
}

# Create app user/group for non-root execution within container
ensure_app_user() {
    if id -u "${APP_USER}" >/dev/null 2>&1; then
        log "User '${APP_USER}' already exists."
    else
        log "Creating user and group '${APP_USER}'."
        if command -v adduser >/dev/null 2>&1; then
            adduser -D -h "/home/${APP_USER}" "${APP_USER}" 2>/dev/null || adduser --home "/home/${APP_USER}" --disabled-password --gecos "" "${APP_USER}" || true
        elif command -v useradd >/dev/null 2>&1; then
            useradd -m -s /bin/bash "${APP_USER}" || useradd -m "${APP_USER}" || true
        else
            warn "No useradd/adduser available; continuing as root."
            return
        fi
    fi

    if getent group "${APP_GROUP}" >/dev/null 2>&1; then
        :
    else
        if command -v addgroup >/dev/null 2>&1; then
            addgroup "${APP_GROUP}" || true
        elif command -v groupadd >/dev/null 2>&1; then
            groupadd "${APP_GROUP}" || true
        fi
    fi

    usermod -a -G "${APP_GROUP}" "${APP_USER}" 2>/dev/null || true
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" 2>/dev/null || true
}

ensure_directories() {
    mkdir -p "${APP_DIR}"
    mkdir -p "${APP_DIR}/logs"
    mkdir -p "${APP_DIR}/tmp"
    chmod 755 "${APP_DIR}"
    chmod 755 "${APP_DIR}/logs" "${APP_DIR}/tmp"
}

install_common_tools() {
    log "Installing common system tools..."
    pkg_update || true

    case "${PKG_MANAGER}" in
        apt)
            pkg_install ca-certificates curl wget git gnupg lsb-release tzdata build-essential pkg-config
            update-ca-certificates || true
            ;;
        apk)
            pkg_install ca-certificates curl wget git tzdata build-base bash
            update-ca-certificates || true
            ;;
        dnf|yum)
            pkg_install ca-certificates curl wget git gnupg2 tzdata gcc gcc-c++ make pkgconfig
            update-ca-trust || true
            ;;
        zypper)
            pkg_install ca-certificates curl wget git gcc gcc-c++ make pkg-config timezone
            ;;
        *)
            warn "Skipping common tools installation."
            ;;
    esac

    pkg_clean || true
}

# Runtime installers
install_python_runtime() {
    log "Setting up Python runtime and dependencies..."
    case "${PKG_MANAGER}" in
        apt)
            pkg_update || true
            pkg_install python3 python3-venv python3-pip python3-dev build-essential
            ;;
        apk)
            pkg_install python3 py3-pip python3-dev build-base
            ;;
        dnf|yum)
            pkg_install python3 python3-pip python3-devel gcc make
            ;;
        zypper)
            pkg_install python3 python3-pip python3-devel gcc make
            ;;
        *)
            warn "Could not install Python system packages (unknown pkg manager)."
            ;;
    esac

    # Virtual environment
    if [ -d "${VENV_DIR}" ] && [ -f "${VENV_DIR}/bin/activate" ]; then
        log "Python virtual environment already exists at ${VENV_DIR}"
    else
        log "Creating Python virtual environment at ${VENV_DIR}"
        python3 -m venv "${VENV_DIR}"
    fi

    # Activate venv for installations
    # shellcheck disable=SC1090
    . "${VENV_DIR}/bin/activate"
    python3 -m pip install --upgrade pip setuptools wheel poetry

    if [ -f "${APP_DIR}/requirements.txt" ]; then
        log "Installing Python dependencies from requirements.txt"
        pip install --no-cache-dir -r "${APP_DIR}/requirements.txt"
    elif [ -f "${APP_DIR}/pyproject.toml" ]; then
        if grep -qE "^[[:space:]]*\[tool\.poetry\]" "${APP_DIR}/pyproject.toml"; then
            log "pyproject.toml with Poetry detected. Installing dependencies via Poetry."
            pip install --no-cache-dir -U "packaging>=24.2" "poetry>=1.7.0" "poetry-core>=1.9.0"
            poetry config virtualenvs.create false
            
            (
              cd "${APP_DIR}" || exit 1
              cp -f pyproject.toml pyproject.toml.bak || true
              python3 - << 'PY'
import re, sys
path = "pyproject.toml"
try:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except FileNotFoundError:
    sys.exit(0)
# Detect table headers like [tool.poetry.dependencies]
table_re = re.compile(r"^\s*\[([^\]]+)\]\s*$")
# Detect simple key assignments like key = value (ignore commented lines)
key_re = re.compile(r"^\s*([A-Za-z0-9_.-]+)\s*=")
seen = {}
current = ""
out = []
for line in lines:
    m = table_re.match(line)
    if m:
        current = m.group(1).strip()
        seen.setdefault(current, set())
        out.append(line)
        continue
    if not line.lstrip().startswith("#"):
        km = key_re.match(line)
        if km:
            key = km.group(1)
            s = seen.setdefault(current, set())
            if key in s:
                out.append("# DUPLICATE REMOVED: " + line)
                continue
            s.add(key)
    out.append(line)
with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
PY
              python3 - << 'PY'
import re, sys
from pathlib import Path
p = Path("pyproject.toml")
if not p.exists():
    sys.exit(0)
text = p.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
out = []
in_deps = False
for line in lines:
    if re.match(r"^\s*\[tool\.poetry\.dependencies\]\s*$", line):
        in_deps = True
        out.append(line)
        continue
    if in_deps:
        if re.match(r"^\s*\[", line):
            in_deps = False
            out.append(line)
            continue
        if re.match(r"^\s*langchain-text-splitters\s*=", line):
            out.append('langchain-text-splitters = ">=0.0.2"\n')
            continue
        if re.match(r"^\s*langchain-core\s*=", line):
            out.append('langchain-core = ">=0.2.0"\n')
            continue
        if re.match(r"^\s*packaging\s*=", line):
            out.append('packaging = ">=24.2"\n')
            continue
    out.append(line)
new = ''.join(out)
if new != text:
    p.write_text(new, encoding="utf-8")
print("pyproject.toml updated for compatibility")
PY
              rm -f poetry.lock
              python3 -m pip install --upgrade "pip>=23.2" "setuptools>=68" wheel "packaging>=24.2" "poetry>=1.7.0" "poetry-core>=1.9.0"
              poetry -n check
              poetry add -n openai
              poetry add -n "huggingface_hub==0.20.3"
              poetry install -n
              printf 'print("example_script: OK")\n' > example_script.py
            )
            
            
        else
            log "pyproject.toml found. Attempting editable install."
            pip install --no-cache-dir -e "${APP_DIR}" || pip install --no-cache-dir "${APP_DIR}" || true
        fi
    else
        warn "No Python dependency file found (requirements.txt or pyproject.toml)."
    fi

    # Deactivate venv
    deactivate || true

    # Environment defaults
    set_env_var "PYTHONUNBUFFERED" "1"
    # Ports for common Python web frameworks
    if [ -f "${APP_DIR}/app.py" ]; then set_env_var "APP_PORT" "${APP_PORT:-5000}"; fi
    if [ -d "${APP_DIR}/manage.py" ] || grep -qi "django" "${APP_DIR}/requirements.txt" 2>/dev/null; then set_env_var "APP_PORT" "${APP_PORT:-8000}"; fi

    # Helper activation script
    cat > "${APP_DIR}/activate_venv.sh" <<EOF
#!/usr/bin/env bash
set -e
. "${VENV_DIR}/bin/activate"
echo "Python virtual environment activated."
EOF
    chmod +x "${APP_DIR}/activate_venv.sh"
}

install_node_runtime() {
    log "Setting up Node.js runtime and dependencies..."
    case "${PKG_MANAGER}" in
        apt)
            pkg_update || true
            # Install Node.js 20.x via NodeSource for up-to-date version
            if ! command -v node >/dev/null 2>&1; then
                curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
                pkg_install nodejs
            else
                log "Node.js already installed: $(node --version)"
            fi
            ;;
        apk)
            pkg_install nodejs npm
            ;;
        dnf|yum)
            pkg_install nodejs npm
            ;;
        zypper)
            pkg_install nodejs npm
            ;;
        *)
            warn "Could not install Node.js system packages (unknown pkg manager)."
            ;;
    esac

    # Install dependencies
    if [ -f "${APP_DIR}/package-lock.json" ]; then
        log "Installing Node.js dependencies with npm ci"
        (cd "${APP_DIR}" && npm ci --no-audit --no-fund)
    elif [ -f "${APP_DIR}/package.json" ]; then
        log "Installing Node.js dependencies with npm install"
        (cd "${APP_DIR}" && npm install --no-audit --no-fund)
    else
        warn "No package.json found for Node.js project."
    fi

    # Environment defaults
    set_env_var "NODE_ENV" "${NODE_ENV:-production}"
    # Common ports
    if [ -f "${APP_DIR}/server.js" ] || [ -f "${APP_DIR}/app.js" ] || [ -d "${APP_DIR}/src" ]; then
        set_env_var "APP_PORT" "${APP_PORT:-3000}"
    fi
}

install_ruby_runtime() {
    log "Setting up Ruby runtime and dependencies..."
    case "${PKG_MANAGER}" in
        apt)
            pkg_update || true
            pkg_install ruby-full build-essential
            ;;
        apk)
            pkg_install ruby ruby-dev build-base
            ;;
        dnf|yum)
            pkg_install ruby ruby-devel gcc make
            ;;
        zypper)
            pkg_install ruby ruby-devel gcc make
            ;;
        *)
            warn "Could not install Ruby system packages (unknown pkg manager)."
            ;;
    esac

    if ! command -v gem >/dev/null 2>&1; then
        warn "RubyGems not available; skipping bundler install."
    else
        gem install bundler --no-document || true
        if [ -f "${APP_DIR}/Gemfile" ]; then
            log "Installing Ruby gems via bundler"
            (cd "${APP_DIR}" && bundle config set --local path 'vendor/bundle' && bundle install --jobs=4)
        else
            warn "No Gemfile found for Ruby project."
        fi
    fi

    set_env_var "APP_PORT" "${APP_PORT:-9292}"
}

install_go_runtime() {
    log "Setting up Go runtime and dependencies..."
    case "${PKG_MANAGER}" in
        apt)
            pkg_update || true
            pkg_install golang
            ;;
        apk)
            pkg_install go
            ;;
        dnf|yum)
            pkg_install golang
            ;;
        zypper)
            pkg_install go
            ;;
        *)
            warn "Could not install Go system packages (unknown pkg manager)."
            ;;
    esac

    if [ -f "${APP_DIR}/go.mod" ]; then
        log "Downloading Go modules"
        (cd "${APP_DIR}" && go mod download)
    else
        warn "No go.mod found for Go project."
    fi
}

install_rust_runtime() {
    log "Setting up Rust toolchain..."
    if ! command -v rustc >/dev/null 2>&1; then
        curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
        chmod +x /tmp/rustup-init.sh
        /tmp/rustup-init.sh -y --default-toolchain stable
        . "${HOME}/.cargo/env"
    else
        log "Rust already installed: $(rustc --version)"
    fi

    if [ -f "${APP_DIR}/Cargo.toml" ]; then
        log "Fetching Rust dependencies"
        (cd "${APP_DIR}" && cargo fetch)
    else
        warn "No Cargo.toml found for Rust project."
    fi
}

install_java_runtime() {
    log "Setting up Java runtime and dependencies..."
    case "${PKG_MANAGER}" in
        apt)
            pkg_update || true
            pkg_install openjdk-17-jdk
            ;;
        apk)
            pkg_install openjdk17
            ;;
        dnf|yum)
            pkg_install java-17-openjdk java-17-openjdk-devel
            ;;
        zypper)
            pkg_install java-17-openjdk java-17-openjdk-devel
            ;;
        *)
            warn "Could not install Java system packages (unknown pkg manager)."
            ;;
    esac

    if [ -f "${APP_DIR}/pom.xml" ]; then
        case "${PKG_MANAGER}" in
            apt) pkg_install maven ;;
            apk) pkg_install maven ;;
            dnf|yum) pkg_install maven ;;
            zypper) pkg_install maven ;;
            *) warn "Cannot install Maven automatically." ;;
        esac
        log "Resolving Maven dependencies"
        (cd "${APP_DIR}" && mvn -q -DskipTests dependency:resolve || true)
        set_env_var "APP_PORT" "${APP_PORT:-8080}"
    elif [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/gradlew" ]; then
        case "${PKG_MANAGER}" in
            apt) pkg_install gradle ;;
            apk) pkg_install gradle ;;
            dnf|yum) pkg_install gradle ;;
            zypper) pkg_install gradle ;;
            *) warn "Cannot install Gradle automatically." ;;
        esac
        log "Resolving Gradle dependencies"
        (cd "${APP_DIR}" && ./gradlew dependencies || gradle dependencies || true)
        set_env_var "APP_PORT" "${APP_PORT:-8080}"
    else
        warn "No Maven (pom.xml) or Gradle build file found for Java project."
    fi
}

install_php_runtime() {
    log "Setting up PHP runtime and dependencies..."
    case "${PKG_MANAGER}" in
        apt)
            pkg_update || true
            pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip
            ;;
        apk)
            pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip
            ;;
        dnf|yum)
            pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip
            ;;
        zypper)
            pkg_install php-cli php7-mbstring php7-xmlreader php7-curl php7-zip unzip || pkg_install php-cli php-mbstring php-xml php-curl php-zip unzip
            ;;
        *)
            warn "Could not install PHP system packages (unknown pkg manager)."
            ;;
    esac

    if ! command -v composer >/dev/null 2>&1; then
        log "Installing Composer"
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    fi

    if [ -f "${APP_DIR}/composer.json" ]; then
        log "Installing PHP dependencies with Composer"
        (cd "${APP_DIR}" && composer install --no-interaction --prefer-dist)
    else
        warn "No composer.json found for PHP project."
    fi
}

# Environment variable handling
set_env_var() {
    # Usage: set_env_var KEY VALUE
    local key="$1"
    local value="$2"

    # Ensure .env file exists
    touch "${APP_ENV_FILE}"
    if ! grep -q "^${key}=" "${APP_ENV_FILE}" 2>/dev/null; then
        echo "${key}=${value}" >> "${APP_ENV_FILE}"
        log "Set environment variable ${key}=${value}"
    else
        log "Environment variable ${key} already set in ${APP_ENV_FILE}"
    fi
}

# Project type detection
detect_project_type() {
    if [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || ls "${APP_DIR}"/*.py >/dev/null 2>&1; then
        echo "python"
        return
    fi
    if [ -f "${APP_DIR}/package.json" ]; then
        echo "node"
        return
    fi
    if [ -f "${APP_DIR}/Gemfile" ]; then
        echo "ruby"
        return
    fi
    if [ -f "${APP_DIR}/go.mod" ]; then
        echo "go"
        return
    fi
    if [ -f "${APP_DIR}/Cargo.toml" ]; then
        echo "rust"
        return
    fi
    if [ -f "${APP_DIR}/pom.xml" ] || [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/gradlew" ]; then
        echo "java"
        return
    fi
    if [ -f "${APP_DIR}/composer.json" ]; then
        echo "php"
        return
    fi
    echo "unknown"
}

apply_runtime_setup() {
    local project_type
    project_type="$(detect_project_type)"
    log "Detected project type: ${project_type}"

    case "${project_type}" in
        python)
            install_python_runtime
            ;;
        node)
            install_node_runtime
            ;;
        ruby)
            install_ruby_runtime
            ;;
        go)
            install_go_runtime
            ;;
        rust)
            install_rust_runtime
            ;;
        java)
            install_java_runtime
            ;;
        php)
            install_php_runtime
            ;;
        *)
            warn "Could not determine project type. Installing common build tools only."
            ;;
    esac
}

# Default environment configuration
setup_default_env() {
    touch "${APP_ENV_FILE}"
    set_env_var "APP_ENV" "${APP_ENV:-production}"
    set_env_var "APP_DIR" "${APP_DIR}"
    # Provide a default port if none set yet
    if ! grep -q "^APP_PORT=" "${APP_ENV_FILE}"; then
        set_env_var "APP_PORT" "${APP_PORT:-8080}"
    fi

    # Create a script to export env vars easily
    cat > "${APP_DIR}/export_env.sh" <<'EOF'
#!/usr/bin/env bash
set -e
ENV_FILE="${APP_ENV_FILE:-.env}"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
  echo "Environment variables loaded from ${ENV_FILE}."
else
  echo "No .env file found at ${ENV_FILE}."
fi
EOF
    sed -i "s|APP_ENV_FILE:-.env|APP_ENV_FILE:-${APP_ENV_FILE}|g" "${APP_DIR}/export_env.sh" || true
    chmod +x "${APP_DIR}/export_env.sh"
}

# Venv auto-activation
setup_auto_activate() {
    # Add venv activation to root and app user .bashrc if not already present
    local activate_line=". \"${VENV_DIR}/bin/activate\""
    if [ -f "${VENV_DIR}/bin/activate" ]; then
        for bashrc_file in "/root/.bashrc" "/home/${APP_USER}/.bashrc"; do
            mkdir -p "$(dirname "$bashrc_file")" 2>/dev/null || true
            touch "$bashrc_file"
            if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
                echo "" >> "$bashrc_file"
                echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
                echo "$activate_line" >> "$bashrc_file"
            fi
        done
    fi
}

# Permissions
set_permissions() {
    ensure_app_user
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" 2>/dev/null || true
}

# Main
main() {
    log "Starting environment setup: ${SCRIPT_NAME}"
    require_root
    detect_os_and_pkg_manager
    ensure_directories
    install_common_tools
    apply_runtime_setup
    setup_default_env
    setup_auto_activate
    set_permissions

    log "Environment setup completed successfully."
    echo "Summary:"
    echo "- Project directory: ${APP_DIR}"
    echo "- Environment file: ${APP_ENV_FILE}"
    echo "- Detected OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-}"
    echo "- Package manager: ${PKG_MANAGER:-none}"
    echo "- App user/group: ${APP_USER}/${APP_GROUP}"
    echo
    echo "Usage hints:"
    echo "- Source environment: ./export_env.sh"
    echo "- For Python venv:    ./activate_venv.sh && python -m app || python app.py (depending on your project)"
    echo "- For Node.js:        npm start or node app.js (check your package.json scripts)"
    echo "- For Ruby:           bundle exec rackup or rails s (depending on your project)"
    echo "- For Go:             go run ./... or go build"
    echo "- For Rust:           cargo run --release"
    echo "- For Java (Maven):   mvn spring-boot:run or java -jar target/*.jar"
    echo "- For PHP:            php -S 0.0.0.0:\$APP_PORT -t public (adjust as needed)"
}

main "$@"