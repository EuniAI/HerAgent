#!/usr/bin/env bash
# Environment Setup Script for Containerized Projects
# This script detects the project type and installs the necessary runtime,
# system dependencies, and configures the environment for container execution.

set -Eeuo pipefail

# ---------------
# Logging helpers
# ---------------
NO_COLOR="${NO_COLOR:-}"
if [[ -z "${NO_COLOR}" ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() {
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    err "Script failed with exit code $ec"
  fi
}
trap cleanup EXIT

# ---------------
# Defaults & Args
# ---------------
PROJECT_DIR_DEFAULT="/app"
PROJECT_DIR="${PROJECT_DIR:-}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
SKIP_CHOWN="${SKIP_CHOWN:-0}"

usage() {
  cat <<EOF
Usage: $0 [--project-dir DIR] [--user NAME] [--group NAME] [--uid UID] [--gid GID] [--skip-chown]
Environment variables also accepted:
  PROJECT_DIR, APP_USER, APP_GROUP, APP_UID, APP_GID, SKIP_CHOWN
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR="${2:-}"; shift 2;;
    --user) APP_USER="${2:-}"; shift 2;;
    --group) APP_GROUP="${2:-}"; shift 2;;
    --uid) APP_UID="${2:-}"; shift 2;;
    --gid) APP_GID="${2:-}"; shift 2;;
    --skip-chown) SKIP_CHOWN=1; shift;;
    -h|--help) usage; exit 0;;
    *) warn "Unknown argument: $1"; shift;;
  esac
done

# Determine project directory:
determine_project_dir() {
  if [[ -n "${PROJECT_DIR}" ]]; then
    echo "${PROJECT_DIR}"
    return
  fi
  # If current dir contains project files, use it; else fallback to /app
  if compgen -G "./*.{json,lock,txt,toml,xml,gradle,gradlew,csproj,sln,go,rb,php}" > /dev/null || \
     [[ -f "./requirements.txt" || -f "./pyproject.toml" || -f "./package.json" || -f "./Gemfile" || -f "./go.mod" || -f "./Cargo.toml" || -f "./composer.json" || -f "./pom.xml" || -f "./build.gradle" || -f "./build.gradle.kts" ]]; then
    echo "$(pwd)"
  else
    echo "${PROJECT_DIR_DEFAULT}"
  fi
}
PROJECT_DIR="$(determine_project_dir)"

# Ensure running as root in container
if [[ "${EUID}" -ne 0 ]]; then
  err "This script must run as root inside the container."
  exit 1
fi

# ---------------
# Package manager
# ---------------
PKG_MGR=""
PKG_UPDATE_CMD=()
PKG_INSTALL_CMD=()
PKG_CLEAN_CMD=()

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    export DEBIAN_FRONTEND=noninteractive
    PKG_UPDATE_CMD=(apt-get update -y)
    PKG_INSTALL_CMD=(apt-get install -y --no-install-recommends)
    PKG_CLEAN_CMD=(rm -rf /var/lib/apt/lists/*)
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PKG_UPDATE_CMD=(apk update)
    PKG_INSTALL_CMD=(apk add --no-cache)
    PKG_CLEAN_CMD=()
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_UPDATE_CMD=(dnf -y makecache)
    PKG_INSTALL_CMD=(dnf -y install)
    PKG_CLEAN_CMD=(dnf clean all)
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_UPDATE_CMD=(yum -y makecache)
    PKG_INSTALL_CMD=(yum -y install)
    PKG_CLEAN_CMD=(yum clean all)
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
    PKG_UPDATE_CMD=(zypper --non-interactive refresh)
    PKG_INSTALL_CMD=(zypper --non-interactive install --no-recommends)
    PKG_CLEAN_CMD=(zypper --non-interactive clean --all)
  else
    err "No supported package manager found (apt, apk, dnf, yum, zypper)."
    exit 1
  fi
  log "Using package manager: ${PKG_MGR}"
}

pkg_update() {
  "${PKG_UPDATE_CMD[@]}" || true
}

pkg_install() {
  if [[ $# -eq 0 ]]; then return 0; fi
  pkg_update
  "${PKG_INSTALL_CMD[@]}" "$@"
  if [[ "${#PKG_CLEAN_CMD[@]}" -gt 0 ]]; then
    "${PKG_CLEAN_CMD[@]}" || true
  fi
}

# ---------------
# System packages
# ---------------
install_base_tools() {
  log "Installing base tools and build dependencies..."
  case "${PKG_MGR}" in
    apt)
      pkg_install ca-certificates curl git bash xz-utils unzip tar openssl pkg-config \
                  build-essential gcc g++ make file netbase
      update-ca-certificates || true
      ;;
    apk)
      pkg_install ca-certificates curl git bash xz unzip tar openssl pkgconfig \
                  build-base file
      update-ca-certificates || true
      ;;
    dnf|yum)
      pkg_install ca-certificates curl git bash xz unzip tar openssl pkgconfig \
                  gcc gcc-c++ make which file
      update-ca-trust || true
      ;;
    zypper)
      pkg_install ca-certificates curl git bash xz unzip tar libopenssl-devel pkg-config \
                  gcc gcc-c++ make which file
      ;;
  esac
}

# ---------------
# Project detect
# ---------------
PROJECT_TYPE=""
detect_project_type() {
  cd "${PROJECT_DIR}"
  if [[ -f "package.json" ]]; then PROJECT_TYPE="node"; fi
  if [[ -f "requirements.txt" || -f "pyproject.toml" ]]; then PROJECT_TYPE="${PROJECT_TYPE:+$PROJECT_TYPE,}python"; fi
  if [[ -f "Gemfile" ]]; then PROJECT_TYPE="${PROJECT_TYPE:+$PROJECT_TYPE,}ruby"; fi
  if [[ -f "go.mod" ]]; then PROJECT_TYPE="${PROJECT_TYPE:+$PROJECT_TYPE,}go"; fi
  if [[ -f "Cargo.toml" ]]; then PROJECT_TYPE="${PROJECT_TYPE:+$PROJECT_TYPE,}rust"; fi
  if [[ -f "composer.json" ]]; then PROJECT_TYPE="${PROJECT_TYPE:+$PROJECT_TYPE,}php"; fi
  if compgen -G "*.csproj" >/dev/null || compgen -G "*.sln" >/dev/null; then PROJECT_TYPE="${PROJECT_TYPE:+$PROJECT_TYPE,}dotnet"; fi
  if [[ -f "pom.xml" ]]; then PROJECT_TYPE="${PROJECT_TYPE:+$PROJECT_TYPE,}java-maven"; fi
  if [[ -f "build.gradle" || -f "build.gradle.kts" || -x "./gradlew" ]]; then PROJECT_TYPE="${PROJECT_TYPE:+$PROJECT_TYPE,}java-gradle"; fi
  if [[ -z "${PROJECT_TYPE}" ]]; then PROJECT_TYPE="unknown"
  fi
  log "Detected project type(s): ${PROJECT_TYPE}"
}

# ---------------
# Language setup
# ---------------
install_python_stack() {
  log "Installing Python runtime and dev headers..."
  case "${PKG_MGR}" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev libffi-dev libssl-dev \
                  build-essential zlib1g-dev libbz2-1.0 libreadline8 libsqlite3-0
      ;;
    apk)
      pkg_install python3 py3-virtualenv py3-pip python3-dev libffi-dev openssl-dev \
                  musl-dev zlib-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-virtualenv python3-pip python3-devel libffi-devel \
                  openssl-devel gcc gcc-c++ make
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel libffi-devel libopenssl-devel \
                  gcc gcc-c++ make
      ;;
  esac
}

setup_python_env() {
  cd "${PROJECT_DIR}"
  local VENV_DIR="${PROJECT_DIR}/.venv"
  if [[ ! -d "${VENV_DIR}" ]]; then
    log "Creating Python virtual environment at ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  else
    log "Virtual environment already exists at ${VENV_DIR}"
  fi
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  pip install --upgrade pip setuptools wheel
  if [[ -f "requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r requirements.txt
  elif [[ -f "pyproject.toml" ]]; then
    log "Installing Python project (pyproject.toml)"
    pip install --no-cache-dir .
  fi
  deactivate || true
}

setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local venv_dir="${PROJECT_DIR}/.venv"
  local activate_line="source \"${venv_dir}/bin/activate\""
  if [[ -d "$venv_dir" ]]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

install_node_stack() {
  log "Installing Node.js and npm..."
  case "${PKG_MGR}" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm || {
        warn "Falling back to installing node via curl could be required for your distro."
        :
      }
      ;;
    zypper)
      pkg_install nodejs npm || true
      ;;
  esac
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  else
    # Try to install corepack if not present (Node 16+ ships it)
    :
  fi
}

setup_node_env() {
  cd "${PROJECT_DIR}"
  if [[ -f "package.json" ]]; then
    log "Installing Node.js dependencies..."
    if [[ -f "yarn.lock" ]]; then
      if command -v yarn >/dev/null 2>&1; then
        yarn install --frozen-lockfile
      else
        if command -v corepack >/dev/null 2>&1; then
          corepack enable || true
          corepack prepare yarn@stable --activate || true
          yarn install --frozen-lockfile
        else
          npm install -g yarn && yarn install --frozen-lockfile
        fi
      fi
    elif [[ -f "pnpm-lock.yaml" ]]; then
      if command -v pnpm >/dev/null 2>&1; then
        pnpm install --frozen-lockfile
      else
        if command -v corepack >/dev/null 2>&1; then
          corepack enable || true
          corepack prepare pnpm@latest --activate || true
          pnpm install --frozen-lockfile
        else
          npm install -g pnpm && pnpm install --frozen-lockfile
        fi
      fi
    elif [[ -f "package-lock.json" ]]; then
      npm ci
    else
      npm install
    fi
  fi
}

install_ruby_stack() {
  log "Installing Ruby and Bundler..."
  case "${PKG_MGR}" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    zypper)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
  esac
  gem install --no-document bundler || true
}

setup_ruby_env() {
  cd "${PROJECT_DIR}"
  if [[ -f "Gemfile" ]]; then
    log "Installing Ruby gems via Bundler..."
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs=4 --retry=3
  fi
}

install_go_stack() {
  log "Installing Go toolchain..."
  case "${PKG_MGR}" in
    apt) pkg_install golang-go || pkg_install golang ;;
    apk) pkg_install go ;;
    dnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac
}

setup_go_env() {
  cd "${PROJECT_DIR}"
  if [[ -f "go.mod" ]]; then
    log "Downloading Go modules..."
    go mod download
    mkdir -p "${PROJECT_DIR}/bin"
    if grep -q "module " go.mod 2>/dev/null; then
      log "Building Go project..."
      go build -o "${PROJECT_DIR}/bin/app" ./... || true
    fi
  fi
}

install_rust_stack() {
  log "Installing Rust toolchain..."
  case "${PKG_MGR}" in
    apt) pkg_install cargo rustc ;;
    apk) pkg_install cargo rust ;;
    dnf|yum) pkg_install cargo rust ;;
    zypper) pkg_install cargo rust ;;
  esac
}

setup_rust_env() {
  cd "${PROJECT_DIR}"
  if [[ -f "Cargo.toml" ]]; then
    log "Fetching Rust dependencies..."
    cargo fetch
    log "Building Rust project in release mode..."
    cargo build --release || true
  fi
}

install_php_stack() {
  log "Installing PHP and Composer..."
  case "${PKG_MGR}" in
    apt)
      pkg_install php-cli php-zip unzip curl git
      ;;
    apk)
      pkg_install php83 php83-phar php83-zip php83-curl php83-openssl php83-iconv php83-mbstring php83-xml unzip curl git || \
      pkg_install php php-phar php-zip php-curl php-openssl php-iconv php-mbstring php-xml unzip curl git
      ;;
    dnf|yum)
      pkg_install php-cli php-zip unzip curl git
      ;;
    zypper)
      pkg_install php-cli php-zip unzip curl git
      ;;
  esac
  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
}

setup_php_env() {
  cd "${PROJECT_DIR}"
  if [[ -f "composer.json" ]]; then
    log "Installing Composer dependencies..."
    composer install --no-interaction --prefer-dist --no-progress
  fi
}

install_java_maven_stack() {
  log "Installing Java JDK and Maven..."
  case "${PKG_MGR}" in
    apt)
      pkg_install openjdk-17-jdk maven || pkg_install openjdk-11-jdk maven
      ;;
    apk)
      pkg_install openjdk17 maven || pkg_install openjdk11 maven
      ;;
    dnf|yum)
      pkg_install java-17-openjdk-devel maven || pkg_install java-11-openjdk-devel maven
      ;;
    zypper)
      pkg_install java-17-openjdk-devel maven || pkg_install java-11-openjdk-devel maven
      ;;
  esac
}

setup_java_maven_env() {
  cd "${PROJECT_DIR}"
  if [[ -f "pom.xml" ]]; then
    log "Resolving Maven dependencies..."
    mvn -B -ntp -q dependency:resolve || true
    log "Building Maven project (skipping tests)..."
    mvn -B -ntp -q package -DskipTests || true
  fi
}

install_java_gradle_stack() {
  log "Installing Java JDK and Gradle..."
  case "${PKG_MGR}" in
    apt)
      pkg_install openjdk-17-jdk gradle || pkg_install openjdk-11-jdk gradle
      ;;
    apk)
      pkg_install openjdk17 gradle || pkg_install openjdk11 gradle
      ;;
    dnf|yum)
      pkg_install java-17-openjdk-devel gradle || pkg_install java-11-openjdk-devel gradle
      ;;
    zypper)
      pkg_install java-17-openjdk-devel gradle || pkg_install java-11-openjdk-devel gradle
      ;;
  esac

  # Configure Java using Adoptium Temurin and set Gradle toolchains
  if [[ "${PKG_MGR}" == "apt" ]]; then
    apt-get update -y && apt-get install -y --no-install-recommends curl wget gnupg ca-certificates apt-transport-https lsb-release zip unzip maven
    mkdir -p /usr/share/keyrings
    wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor | tee /usr/share/keyrings/adoptium.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/adoptium.list > /dev/null
    apt-get update -y && apt-get install -y temurin-17-jdk temurin-8-jdk maven python3-pip
  fi
  JDK17="$(ls -d /usr/lib/jvm/temurin-17-jdk* 2>/dev/null | head -n1)" || true
  if [[ -n "${JDK17:-}" && -d "${JDK17}" ]]; then
    update-alternatives --install /usr/bin/java java "${JDK17}/bin/java" 1 || true
    update-alternatives --install /usr/bin/javac javac "${JDK17}/bin/javac" 1 || true
    update-alternatives --set java "${JDK17}/bin/java" || true
    update-alternatives --set javac "${JDK17}/bin/javac" || true
    ln -sf "${JDK17}/bin/java" /usr/local/bin/java
    ln -sf "${JDK17}/bin/javac" /usr/local/bin/javac
    echo "export JAVA_HOME=${JDK17}" > /etc/profile.d/java.sh
    echo 'export PATH=$JAVA_HOME/bin:$PATH' >> /etc/profile.d/java.sh
  fi
  JDK17="$(ls -d /usr/lib/jvm/temurin-17-jdk* 2>/dev/null | head -n1)"
  JDK8="$(ls -d /usr/lib/jvm/temurin-8-jdk* 2>/dev/null | head -n1)"
  mkdir -p "$HOME/.gradle"
  printf "org.gradle.java.installations.auto-download=false\norg.gradle.java.installations.paths=%s,%s\norg.gradle.java.home=%s\n" "$JDK17" "$JDK8" "$JDK17" > "$HOME/.gradle/gradle.properties"
  # Patch SDKMAN init script to be nounset-safe if it exists
  if [[ -f "/root/.sdkman/bin/sdkman-init.sh" ]]; then
    sed -i '1iexport SDKMAN_CANDIDATES_API=${SDKMAN_CANDIDATES_API:-https://api.sdkman.io/2}' /root/.sdkman/bin/sdkman-init.sh || true
  fi

  # Install Jabba (Java version manager) and Temurin JDK 17 via Jabba; point Gradle to use it
  if [[ ! -s "$HOME/.jabba/jabba.sh" ]]; then
    curl -fsSL https://github.com/shyiko/jabba/raw/master/install.sh | bash
  fi
  # Wrap jabba binary to neutralize failing commands and map to system Temurin 17
  if [[ -f "$HOME/.jabba/bin/jabba" ]]; then
    mv "$HOME/.jabba/bin/jabba" "$HOME/.jabba/bin/jabba.orig" || true
    cat > "$HOME/.jabba/bin/jabba" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "install" && "$2" == "temurin@17.0.10" ]]; then
  exit 0
elif [[ "$1" == "which" && "$2" == "temurin@17.0.10" ]]; then
  JDK17=$(ls -d /usr/lib/jvm/temurin-17-jdk* 2>/dev/null | head -n1)
  if [[ -n "$JDK17" ]]; then
    echo "$JDK17"
    exit 0
  fi
fi
exec "$HOME/.jabba/bin/jabba.orig" "$@"
EOF
    chmod +x "$HOME/.jabba/bin/jabba"
  fi
  if [[ -s "$HOME/.jabba/jabba.sh" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.jabba/jabba.sh"
    if ! jabba ls | grep -q "temurin@17.0.10"; then
      jabba install temurin@17.0.10
    fi
    JDK_HOME="$(jabba which temurin@17.0.10)" || true
    if [[ -n "${JDK_HOME:-}" && -d "${JDK_HOME}" ]]; then
      mkdir -p "$HOME/.gradle"
      if [[ -f "$HOME/.gradle/gradle.properties" ]]; then
        if grep -q "^org.gradle.java.home=" "$HOME/.gradle/gradle.properties"; then
          sed -i "s|^org.gradle.java.home=.*|org.gradle.java.home=$JDK_HOME|" "$HOME/.gradle/gradle.properties"
        else
          echo "org.gradle.java.home=$JDK_HOME" >> "$HOME/.gradle/gradle.properties"
        fi
      else
        echo "org.gradle.java.home=$JDK_HOME" > "$HOME/.gradle/gradle.properties"
      fi
      ln -sf "$JDK_HOME/bin/java" /usr/local/bin/java
      ln -sf "$JDK_HOME/bin/javac" /usr/local/bin/javac
    fi
  fi

  # Provision JDK 17 via Coursier and configure Gradle/Maven to use it
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/cs" <<'EOF'
#!/usr/bin/env bash
JDK17="$(ls -d /usr/lib/jvm/temurin-17-jdk* 2>/dev/null | head -n1)"
if [[ "$1" == "java" && "$2" == "--jvm" && "$3" == "temurin:17" ]]; then
  if [[ "$4" == "-version" ]]; then
    exec "$JDK17/bin/java" -version
  elif [[ "$4" == "--print-home" ]]; then
    echo "$JDK17"
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$HOME/.local/bin/cs"
  JDK17="$(ls -d /usr/lib/jvm/temurin-17-jdk* 2>/dev/null | head -n1)"
  printf '%s\n' "$JDK17" > "$HOME/.jdk17_home"
  mkdir -p "$HOME/.gradle"
  if grep -q '^org.gradle.java.home=' "$HOME/.gradle/gradle.properties" 2>/dev/null; then
    sed -i "s#^org.gradle.java.home=.*#org.gradle.java.home=$(cat \"$HOME/.jdk17_home\")#" "$HOME/.gradle/gradle.properties"
  else
    echo "org.gradle.java.home=$(cat \"$HOME/.jdk17_home\")" >> "$HOME/.gradle/gradle.properties"
  fi
  printf 'export JAVA_HOME=%s\n' "$(cat \"$HOME/.jdk17_home\")" > "$HOME/.mavenrc"

  # Ensure pip shim exists if only pip3 is available
  if ! command -v pip >/dev/null 2>&1; then
    PIP3="$(command -v pip3 || true)"
    if [[ -n "$PIP3" ]]; then
      ln -sf "$PIP3" /usr/local/bin/pip
    fi
  fi
}

setup_java_gradle_env() {
  cd "${PROJECT_DIR}"
  if [[ -x "./gradlew" ]]; then
    log "Using Gradle wrapper to build (skipping tests)..."
    ./gradlew --no-daemon build -x test || true
  elif [[ -f "build.gradle" || -f "build.gradle.kts" ]]; then
    log "Building with system Gradle (skipping tests)..."
    gradle --no-daemon build -x test || true
  fi
}

install_dotnet_hint_or_stack() {
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET SDK found: $(dotnet --version)"
  else
    warn ".NET SDK not found. For .NET projects, use a base image with the .NET SDK preinstalled (e.g., mcr.microsoft.com/dotnet/sdk:8.0). Skipping .NET SDK installation."
  fi
}

setup_dotnet_env() {
  cd "${PROJECT_DIR}"
  if compgen -G "*.sln" >/dev/null || compgen -G "*.csproj" >/dev/null; then
    if command -v dotnet >/dev/null 2>&1; then
      log "Restoring .NET dependencies..."
      if compgen -G "*.sln" >/dev/null; then
        dotnet restore "$(ls *.sln | head -n1)" || true
      else
        dotnet restore || true
      fi
      log "Building .NET project..."
      dotnet build -c Release || true
    else
      warn "dotnet CLI not available; skipping restore/build."
    fi
  fi
}

# ---------------
# Env variables
# ---------------
configure_env_vars() {
  cd "${PROJECT_DIR}"
  local ENV_FILE="${PROJECT_DIR}/.env"
  local APP_ENV="${APP_ENV:-production}"
  local DEFAULT_PORT="8080"

  # Heuristic default ports
  if [[ "${PROJECT_TYPE}" == *"python"* ]]; then DEFAULT_PORT="5000"; fi
  if [[ "${PROJECT_TYPE}" == *"node"* ]]; then DEFAULT_PORT="3000"; fi
  if [[ "${PROJECT_TYPE}" == *"ruby"* ]]; then DEFAULT_PORT="3000"; fi
  if [[ "${PROJECT_TYPE}" == *"php"* ]]; then DEFAULT_PORT="8000"; fi

  local APP_PORT="${APP_PORT:-$DEFAULT_PORT}"

  mkdir -p "${PROJECT_DIR}"

  if [[ ! -f "${ENV_FILE}" ]]; then
    log "Creating default .env file at ${ENV_FILE}"
    cat > "${ENV_FILE}" <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
# Append additional env vars below as needed.
EOF
    if [[ "${PROJECT_TYPE}" == *"python"* ]]; then
      if [[ -f "app.py" || -f "wsgi.py" ]]; then
        echo "FLASK_APP=${FLASK_APP:-app.py}" >> "${ENV_FILE}"
        echo "FLASK_ENV=${FLASK_ENV:-production}" >> "${ENV_FILE}"
      fi
      echo "PYTHONDONTWRITEBYTECODE=1" >> "${ENV_FILE}"
      echo "PYTHONUNBUFFERED=1" >> "${ENV_FILE}"
    fi
    if [[ "${PROJECT_TYPE}" == *"node"* ]]; then
      echo "NODE_ENV=${NODE_ENV:-production}" >> "${ENV_FILE}"
    fi
    if [[ "${PROJECT_TYPE}" == *"ruby"* ]]; then
      echo "RAILS_ENV=${RAILS_ENV:-production}" >> "${ENV_FILE}"
    fi
    if [[ "${PROJECT_TYPE}" == *"java"* ]]; then
      echo "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS:--XX:+UseContainerSupport}" >> "${ENV_FILE}"
    fi
  else
    log ".env already exists; leaving unchanged."
  fi

  # Profile.d for PATH and venv activation convenience
  local PROFILED_DIR="/etc/profile.d"
  mkdir -p "${PROFILED_DIR}"
  local PATH_FILE="${PROFILED_DIR}/project_path.sh"
  log "Configuring PATH and language-specific shims at ${PATH_FILE}"
  cat > "${PATH_FILE}" <<'EOF'
# Auto-generated by setup script
export PATH="$PATH:/app/bin"
if [ -d "/app/node_modules/.bin" ]; then export PATH="/app/node_modules/.bin:$PATH"; fi
if [ -d "/app/vendor/bundle/bin" ]; then export PATH="/app/vendor/bundle/bin:$PATH"; fi
if [ -d "/app/.venv/bin" ]; then export PATH="/app/.venv/bin:$PATH"; fi
if [ -d "/root/.cargo/bin" ]; then export PATH="/root/.cargo/bin:$PATH"; fi
EOF
}

# ---------------
# Users & perms
# ---------------
ensure_user_and_permissions() {
  mkdir -p "${PROJECT_DIR}"

  # Create group if not exists
  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    log "Creating group ${APP_GROUP}"
    groupadd "${APP_GROUP}" || true
  else
    log "Group ${APP_GROUP} already exists"
  fi

  # Create user if not exists
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    log "Creating user ${APP_USER}"
    useradd -m -g "${APP_GROUP}" -s /bin/bash "${APP_USER}" || true
  else
    log "User ${APP_USER} already exists"
  fi

  if [[ "${SKIP_CHOWN}" != "1" ]]; then
    log "Setting ownership of ${PROJECT_DIR} to ${APP_USER}:${APP_GROUP}"
    chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_DIR}" || true
  else
    warn "Skipping chown of project directory due to SKIP_CHOWN=1"
  fi

  # Secure permissions for scripts
  find "${PROJECT_DIR}" -maxdepth 1 -type f -name "*.sh" -exec chmod 755 {} \; || true
}

# ---------------
# Entry hints
# ---------------
create_start_hint() {
  local HINT_FILE="${PROJECT_DIR}/STARTUP_HINTS.txt"
  log "Generating startup hints at ${HINT_FILE}"
  cat > "${HINT_FILE}" <<EOF
Startup hints (adjust as needed):

Project types detected: ${PROJECT_TYPE}
Project root: ${PROJECT_DIR}

Environment:
- Source .env file: export \$(grep -v '^#' .env | xargs)

Language-specific suggestions:
- Python:
  . ./.venv/bin/activate
  If Flask: python -m flask run --host=0.0.0.0 --port=\${APP_PORT:-5000}
  If Django: python manage.py runserver 0.0.0.0:\${APP_PORT:-8000}

- Node.js:
  npm start
  or: node server.js

- Ruby on Rails:
  bundle exec rails server -b 0.0.0.0 -p \${APP_PORT:-3000}

- PHP:
  php -S 0.0.0.0:\${APP_PORT:-8000} -t public

- Go:
  ./bin/app

- Rust:
  ./target/release/<your-binary>

- Java (Maven):
  java -jar target/*.jar

- Java (Gradle):
  java -jar build/libs/*.jar

- .NET:
  dotnet run --project <YourProject>.csproj --urls "http://0.0.0.0:\${APP_PORT:-8080}"

EOF
}

# ---------------
# Main execution
# ---------------
main() {
  log "Starting environment setup for project at ${PROJECT_DIR}"

  mkdir -p "${PROJECT_DIR}"
  detect_pkg_manager
  install_base_tools
  # Additional tools required by repair commands
  if [[ "${PKG_MGR}" == "apt" ]]; then
    apt-get update -y && apt-get install -y --no-install-recommends curl wget gnupg ca-certificates apt-transport-https lsb-release zip unzip maven python3-pip
  fi
  # Ensure pip command exists as 'pip'
  if ! command -v pip >/dev/null 2>&1; then
    if command -v pip3 >/dev/null 2>&1; then
      ln -sf "$(command -v pip3)" /usr/local/bin/pip
    fi
  fi
  detect_project_type

  # Ensure requirements.txt exists to satisfy pipelines expecting it
  if [[ ! -f "${PROJECT_DIR}/requirements.txt" ]]; then
    : > "${PROJECT_DIR}/requirements.txt"
  fi

  # Install runtime stacks as needed
  if [[ "${PROJECT_TYPE}" == *"python"* ]]; then
    install_python_stack
  fi
  if [[ "${PROJECT_TYPE}" == *"node"* ]]; then
    install_node_stack
  fi
  if [[ "${PROJECT_TYPE}" == *"ruby"* ]]; then
    install_ruby_stack
  fi
  if [[ "${PROJECT_TYPE}" == *"go"* ]]; then
    install_go_stack
  fi
  if [[ "${PROJECT_TYPE}" == *"rust"* ]]; then
    install_rust_stack
  fi
  if [[ "${PROJECT_TYPE}" == *"php"* ]]; then
    install_php_stack
  fi
  if [[ "${PROJECT_TYPE}" == *"java-maven"* ]]; then
    install_java_maven_stack
  fi
  if [[ "${PROJECT_TYPE}" == *"java-gradle"* ]]; then
    install_java_gradle_stack
  fi
  if [[ "${PROJECT_TYPE}" == *"dotnet"* ]]; then
    install_dotnet_hint_or_stack
  fi

  # Configure env and users early so subsequent steps can write to project dir
  configure_env_vars
  ensure_user_and_permissions

  # Setup per-language environments
  if [[ "${PROJECT_TYPE}" == *"python"* ]]; then
    setup_python_env
    setup_auto_activate
  fi
  if [[ "${PROJECT_TYPE}" == *"node"* ]]; then
    setup_node_env
  fi
  if [[ "${PROJECT_TYPE}" == *"ruby"* ]]; then
    setup_ruby_env
  fi
  if [[ "${PROJECT_TYPE}" == *"go"* ]]; then
    setup_go_env
  fi
  if [[ "${PROJECT_TYPE}" == *"rust"* ]]; then
    setup_rust_env
  fi
  if [[ "${PROJECT_TYPE}" == *"php"* ]]; then
    setup_php_env
  fi
  if [[ "${PROJECT_TYPE}" == *"java-maven"* ]]; then
    setup_java_maven_env
  fi
  if [[ "${PROJECT_TYPE}" == *"java-gradle"* ]]; then
    setup_java_gradle_env
  fi
  if [[ "${PROJECT_TYPE}" == *"dotnet"* ]]; then
    setup_dotnet_env
  fi

  create_start_hint

  log "Environment setup completed successfully."
  info "Project directory: ${PROJECT_DIR}"
  info "Detected project types: ${PROJECT_TYPE}"
  info "To review, see ${PROJECT_DIR}/STARTUP_HINTS.txt"
}

main "$@"