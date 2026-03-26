#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common tech stacks (Node.js, Python, Go, Rust, Java, PHP, .NET) and installs dependencies.
# Idempotent, safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'

#-----------------------------
# Logging and error handling
#-----------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

on_error() {
  err "Command failed on line $1: $2"
  exit 1
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

#-----------------------------
# Configurable variables
#-----------------------------
PROJECT_DIR="${PROJECT_DIR:-/app}"
APP_USER="${APP_USER:-}"             # e.g., "app"
APP_GROUP="${APP_GROUP:-$APP_USER}"
CREATE_APP_USER="${CREATE_APP_USER:-no}" # yes|no
NONINTERACTIVE="${NONINTERACTIVE:-yes}"

# Language-specific toggles (auto-detected by default)
INSTALL_NODE="${INSTALL_NODE:-auto}"     # auto|yes|no
INSTALL_PYTHON="${INSTALL_PYTHON:-auto}" # auto|yes|no
INSTALL_GO="${INSTALL_GO:-auto}"         # auto|yes|no
INSTALL_RUST="${INSTALL_RUST:-auto}"     # auto|yes|no
INSTALL_JAVA="${INSTALL_JAVA:-auto}"     # auto|yes|no
INSTALL_PHP="${INSTALL_PHP:-auto}"       # auto|yes|no
INSTALL_DOTNET="${INSTALL_DOTNET:-auto}" # auto|yes|no

#-----------------------------
# Helpers
#-----------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_file() { [ -f "$PROJECT_DIR/$1" ]; }
has_any_file() { for f in "$@"; do [ -f "$PROJECT_DIR/$f" ] && return 0; done; return 1; }
ensure_executable() { [ -f "$1" ] && chmod +x "$1" || true; }

#-----------------------------
# Package manager detection
#-----------------------------
PKG_MANAGER=""
pkg_update() { :; }
pkg_install() { :; }
pkg_clean() { :; }

detect_pkg_manager() {
  if has_cmd apt-get; then
    PKG_MANAGER="apt"
    pkg_update() { export DEBIAN_FRONTEND=noninteractive; apt-get update -y; }
    pkg_install() { export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends "$@"; }
    pkg_clean() { rm -rf /var/lib/apt/lists/*; }
  elif has_cmd apk; then
    PKG_MANAGER="apk"
    pkg_update() { apk update || true; }
    pkg_install() { apk add --no-cache "$@"; }
    pkg_clean() { :; }
  elif has_cmd dnf; then
    PKG_MANAGER="dnf"
    pkg_update() { dnf -y update || true; }
    pkg_install() { dnf -y install "$@"; }
    pkg_clean() { dnf clean all || true; rm -rf /var/cache/dnf || true; }
  elif has_cmd microdnf; then
    PKG_MANAGER="microdnf"
    pkg_update() { microdnf update -y || true; }
    pkg_install() { microdnf install -y "$@"; }
    pkg_clean() { microdnf clean all || true; }
  elif has_cmd yum; then
    PKG_MANAGER="yum"
    pkg_update() { yum -y update || true; }
    pkg_install() { yum -y install "$@"; }
    pkg_clean() { yum clean all || true; rm -rf /var/cache/yum || true; }
  elif has_cmd zypper; then
    PKG_MANAGER="zypper"
    pkg_update() { zypper --non-interactive refresh || true; }
    pkg_install() { zypper --non-interactive install -y "$@"; }
    pkg_clean() { zypper clean --all || true; }
  else
    err "Unsupported or unknown package manager. Please use a Debian/Ubuntu, Alpine, Fedora/CentOS/RHEL, or openSUSE base image."
    exit 1
  fi
  log "Detected package manager: $PKG_MANAGER"
}

#-----------------------------
# Base system setup
#-----------------------------
install_base_system() {
  log "Installing base system packages..."
  case "$PKG_MANAGER" in
    apt)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg dirmngr tar xz-utils unzip zip \
                  build-essential pkg-config openssl libssl-dev findutils
      ;;
    apk)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg tar xz unzip zip \
                  build-base pkgconfig openssl-dev findutils
      update-ca-certificates || true
      ;;
    dnf|yum|microdnf)
      pkg_update || true
      # Some images may need 'procps-ng' and 'shadow-utils' for user mgmt
      pkg_install ca-certificates curl wget git gnupg2 tar xz unzip zip which \
                  gcc gcc-c++ make pkgconfig openssl-devel findutils shadow-utils || true
      ;;
    zypper)
      pkg_update
      pkg_install ca-certificates curl wget git gpg2 tar xz unzip zip which \
                  gcc gcc-c++ make pkg-config libopenssl-devel findutils shadow
      ;;
  esac
  pkg_clean
  log "Base system packages installed."
}

#-----------------------------
# User and directory setup
#-----------------------------
setup_directories_and_users() {
  log "Setting up project directory structure at $PROJECT_DIR ..."
  mkdir -p "$PROJECT_DIR"/{bin,logs,tmp}
  if [ "$CREATE_APP_USER" = "yes" ] && [ -n "$APP_USER" ]; then
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      log "Creating user and group: $APP_USER"
      case "$PKG_MANAGER" in
        apk) addgroup -S "$APP_GROUP" || true; adduser -S -G "$APP_GROUP" "$APP_USER" || true ;;
        apt|dnf|yum|microdnf|zypper) groupadd -r "$APP_GROUP" 2>/dev/null || true; useradd -r -g "$APP_GROUP" -d "$PROJECT_DIR" -s /sbin/nologin "$APP_USER" 2>/dev/null || true ;;
      esac
    else
      log "User $APP_USER already exists."
    fi
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR"
  fi
  log "Ensuring wrapper scripts are executable if present..."
  ensure_executable "$PROJECT_DIR/mvnw"
  ensure_executable "$PROJECT_DIR/gradlew"
  ensure_executable "$PROJECT_DIR/bin/*" || true
}

#-----------------------------
# Environment configuration
#-----------------------------
write_env_profile() {
  log "Configuring environment variables..."
  ENV_FILE="/etc/profile.d/project_env.sh"
  {
    echo "export PROJECT_DIR=\"$PROJECT_DIR\""
    echo 'export PATH="$PROJECT_DIR/bin:$PATH"'
    echo 'export PIP_DISABLE_PIP_VERSION_CHECK=1'
    echo 'export PIP_NO_CACHE_DIR=1'
    echo 'export PYTHONDONTWRITEBYTECODE=1'
    echo 'export PYTHONUNBUFFERED=1'
    echo 'export NODE_ENV=${NODE_ENV:-production}'
    echo 'export NPM_CONFIG_FUND=false'
    echo 'export NPM_CONFIG_AUDIT=false'
    echo 'export GOPATH=${GOPATH:-$PROJECT_DIR/.gopath}'
    echo 'export GOBIN="$GOPATH/bin"'
    echo 'export PATH="$GOBIN:$PATH"'
    echo 'export CARGO_HOME=${CARGO_HOME:-$PROJECT_DIR/.cargo}'
    echo 'export RUSTUP_HOME=${RUSTUP_HOME:-$PROJECT_DIR/.rustup}'
    echo 'if [ -d "/usr/share/dotnet" ]; then export DOTNET_ROOT=/usr/share/dotnet; export PATH="$DOTNET_ROOT:$PATH"; fi'
  } > "$ENV_FILE"
  chmod 0644 "$ENV_FILE"
  # Export current shell as well
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  log "Environment configuration written to $ENV_FILE"
}

#-----------------------------
# Build detection runner
#-----------------------------
create_build_runner_script() {
  mkdir -p "$PROJECT_DIR/.ci"
  cat > "$PROJECT_DIR/build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f pom.xml ]; then
  mvn -q -B -DskipTests -U clean package
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  if [ -x ./gradlew ]; then ./gradlew -q build -x test; else gradle -q build -x test; fi
elif [ -f package.json ]; then
  npm ci
  npm run build --if-present
elif [ -f Cargo.toml ]; then
  cargo build --release
elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
  if [ -f requirements.txt ]; then pip install -r requirements.txt; else pip install .; fi
elif ls *.sln >/dev/null 2>&1; then
  dotnet build
else
  echo 'No recognized build configuration' >&2
  exit 1
fi
EOF
  chmod +x "$PROJECT_DIR/build.sh"

  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'exec bash -lc "./build.sh"' > "$PROJECT_DIR/run_build.sh"
  chmod +x "$PROJECT_DIR/run_build.sh"
}

run_detected_build() {
  # Execute the standalone CI build script in the project directory under timeout
  if [ -d "$PROJECT_DIR" ]; then
    (cd "$PROJECT_DIR" && timeout -k 5 1800s ./build.sh)
  else
    timeout -k 5 1800s "$PROJECT_DIR/build.sh"
  fi
}

#-----------------------------
# Language installers
#-----------------------------
install_node() {
  if has_cmd node && has_cmd npm; then
    log "Node.js already installed: $(node -v)"
    return 0
  fi
  log "Installing Node.js + npm..."
  case "$PKG_MANAGER" in
    apt) pkg_update; pkg_install nodejs npm; pkg_clean ;;
    apk) pkg_install nodejs npm ;;
    dnf|yum|microdnf) pkg_install nodejs npm || pkg_install nodejs ;; # npm may be included
    zypper) pkg_install nodejs npm || pkg_install nodejs ;;
  esac
  if has_cmd corepack; then
    corepack enable || true
  fi
  log "Node.js installation complete: $(node -v 2>/dev/null || echo 'unknown')"
}

node_install_deps() {
  [ -d "$PROJECT_DIR" ] || return 0
  if has_file package.json; then
    log "Installing Node.js dependencies..."
    pushd "$PROJECT_DIR" >/dev/null
    if has_cmd corepack; then
      if has_file pnpm-lock.yaml; then corepack prepare pnpm@latest --activate || true; fi
      if has_file yarn.lock; then corepack prepare yarn@stable --activate || true; fi
    fi
    if has_file pnpm-lock.yaml && has_cmd pnpm; then pnpm install --frozen-lockfile || pnpm install; 
    elif has_file yarn.lock && has_cmd yarn; then yarn install --frozen-lockfile || yarn install;
    elif has_file package-lock.json; then npm ci || npm install;
    else npm install;
    fi
    popd >/dev/null
    log "Node.js dependencies installed."
  fi
}

install_python() {
  if has_cmd python3 && has_cmd pip3; then
    log "Python already installed: $(python3 -V)"
  else
    log "Installing Python 3 and build deps..."
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install python3 python3-venv python3-pip python3-dev build-essential; pkg_clean ;;
      apk) pkg_install python3 py3-pip py3-virtualenv python3-dev build-base ;;
      dnf|yum|microdnf) pkg_install python3 python3-pip python3-devel gcc gcc-c++ make ;;
      zypper) pkg_install python3 python3-pip python3-devel gcc gcc-c++ make ;;
    esac
  fi

  # Create venv if project uses Python
  if has_any_file requirements.txt pyproject.toml setup.py Pipfile; then
    log "Setting up Python virtual environment..."
    mkdir -p "$PROJECT_DIR"
    if [ ! -d "$PROJECT_DIR/.venv" ]; then
      python3 -m venv "$PROJECT_DIR/.venv"
    fi
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.venv/bin/activate"
    python -m pip install --upgrade pip setuptools wheel

    if has_file requirements.txt; then
      log "Installing Python dependencies from requirements.txt ..."
      pip install -r "$PROJECT_DIR/requirements.txt"
    elif has_file poetry.lock; then
      log "Detected Poetry. Installing via pip..."
      pip install "poetry<=1.8.*"
      (cd "$PROJECT_DIR" && poetry config virtualenvs.in-project true && poetry install --no-interaction --no-ansi)
    elif has_file Pipfile; then
      log "Detected Pipenv. Installing via pip..."
      pip install "pipenv<2024.0"
      (cd "$PROJECT_DIR" && pipenv install --deploy)
    elif has_file pyproject.toml; then
      log "Detected PEP 517/518 project. Installing with pip (build backend)..."
      (cd "$PROJECT_DIR" && pip install .) || warn "Fallback install failed; consider providing requirements.txt or Poetry/Pipenv lockfile."
    fi
    deactivate || true
    log "Python environment ready at $PROJECT_DIR/.venv"
  fi
}

install_go() {
  if has_cmd go; then
    log "Go already installed: $(go version)"
  else
    log "Installing Go..."
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install golang; pkg_clean ;;
      apk) pkg_install go ;;
      dnf|yum|microdnf) pkg_install golang ;;
      zypper) pkg_install go ;;
    esac
  fi
  if has_file go.mod; then
    log "Fetching Go module dependencies..."
    mkdir -p "${GOPATH:-$PROJECT_DIR/.gopath}"
    (cd "$PROJECT_DIR" && go mod download)
  fi
}

install_rust() {
  if has_cmd cargo; then
    log "Rust already installed: $(rustc --version 2>/dev/null || echo 'rustc n/a')"
  else
    log "Installing Rust toolchain (rustup, stable minimal)..."
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
    chmod +x /tmp/rustup-init.sh
    RUSTUP_HOME="${RUSTUP_HOME:-$PROJECT_DIR/.rustup}" CARGO_HOME="${CARGO_HOME:-$PROJECT_DIR/.cargo}" \
      /tmp/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain stable
    rm -f /tmp/rustup-init.sh
    export PATH="${CARGO_HOME:-$PROJECT_DIR/.cargo}/bin:$PATH"
  fi
  if has_file Cargo.toml; then
    log "Fetching Rust crates (offline cache)..."
    (cd "$PROJECT_DIR" && "${CARGO_HOME:-$PROJECT_DIR/.cargo}/bin/cargo" fetch || cargo fetch)
  fi
}

install_java() {
  if has_cmd javac; then
    log "Java already installed: $(javac -version 2>&1)"
  else
    log "Installing OpenJDK (17 preferred)..."
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install openjdk-17-jdk || pkg_install openjdk-11-jdk; pkg_clean ;;
      apk) pkg_install openjdk17-jdk || pkg_install openjdk11-jdk ;;
      dnf|yum|microdnf) pkg_install java-17-openjdk-devel || pkg_install java-11-openjdk-devel ;;
      zypper) pkg_install java-17-openjdk-devel || pkg_install java-11-openjdk-devel ;;
    esac
  fi

  # Maven/Gradle handling
  if has_file mvnw; then
    log "Using Maven Wrapper to pre-fetch dependencies..."
    (cd "$PROJECT_DIR" && ./mvnw -q -B -DskipTests dependency:go-offline) || warn "Maven wrapper prefetch failed."
  elif has_file pom.xml; then
    log "Installing Maven and pre-fetching dependencies..."
    case "$PKG_MANAGER" in
      apt) pkg_install maven ;;
      apk) pkg_install maven ;;
      dnf|yum|microdnf) pkg_install maven ;;
      zypper) pkg_install maven ;;
    esac
    (cd "$PROJECT_DIR" && mvn -q -B -DskipTests dependency:go-offline) || warn "Maven prefetch failed."
  fi

  if has_file gradlew; then
    log "Using Gradle Wrapper to pre-fetch dependencies..."
    (cd "$PROJECT_DIR" && ./gradlew --no-daemon tasks >/dev/null) || warn "Gradle wrapper tasks failed."
  elif has_any_file build.gradle build.gradle.kts; then
    log "Installing Gradle and running a warm-up task..."
    case "$PKG_MANAGER" in
      apt) pkg_install gradle || true ;;
      apk) pkg_install gradle || true ;;
      dnf|yum|microdnf) pkg_install gradle || true ;;
      zypper) pkg_install gradle || true ;;
    esac
    (cd "$PROJECT_DIR" && gradle --no-daemon tasks >/dev/null) || warn "Gradle warm-up failed."
  fi
}

install_php() {
  if has_cmd php; then
    log "PHP already installed: $(php -v | head -n1)"
  else
    log "Installing PHP CLI and extensions..."
    case "$PKG_MANAGER" in
      apt) pkg_update; pkg_install php-cli php-xml php-mbstring php-zip curl unzip; pkg_clean ;;
      apk) pkg_install php81 php81-cli php81-xml php81-mbstring php81-zip curl unzip || pkg_install php php-cli php-xml php-mbstring php-zip curl unzip ;;
      dnf|yum|microdnf) pkg_install php-cli php-xml php-mbstring php-zip curl unzip ;;
      zypper) pkg_install php8 php8-cli php8-xml php8-mbstring php8-zip curl unzip || pkg_install php php-cli php-xml php-mbstring php-zip curl unzip ;;
    esac
  fi

  if ! has_cmd composer; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
      rm -f /tmp/composer-setup.php
      err "Invalid Composer installer signature."
      exit 1
    fi
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if has_file composer.json; then
    log "Installing PHP dependencies with Composer..."
    (cd "$PROJECT_DIR" && composer install --no-interaction --prefer-dist --no-progress --optimize-autoloader || composer install)
  fi
}

install_dotnet() {
  if has_cmd dotnet; then
    log ".NET SDK already installed: $(dotnet --version)"
  else
    log "Installing .NET SDK (LTS channel) via dotnet-install.sh ..."
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir /usr/share/dotnet --channel LTS
    ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
    rm -f /tmp/dotnet-install.sh
  fi

  # Restore if project exists
  shopt -s nullglob
  csproj_files=("$PROJECT_DIR"/*.csproj)
  sln_files=("$PROJECT_DIR"/*.sln)
  if [ "${#csproj_files[@]}" -gt 0 ] || [ "${#sln_files[@]}" -gt 0 ]; then
    log "Restoring .NET project dependencies..."
    if [ "${#sln_files[@]}" -gt 0 ]; then
      (cd "$PROJECT_DIR" && dotnet restore "${sln_files[0]}") || warn "dotnet restore failed."
    else
      (cd "$PROJECT_DIR" && dotnet restore "${csproj_files[0]}") || warn "dotnet restore failed."
    fi
  fi
  shopt -u nullglob
}

#-----------------------------
# Auto-detection of stack
#-----------------------------
detect_stack() {
  NODE_DETECTED="no"
  PY_DETECTED="no"
  GO_DETECTED="no"
  RUST_DETECTED="no"
  JAVA_DETECTED="no"
  PHP_DETECTED="no"
  DOTNET_DETECTED="no"

  has_file package.json && NODE_DETECTED="yes"
  has_any_file requirements.txt pyproject.toml setup.py Pipfile && PY_DETECTED="yes"
  has_file go.mod && GO_DETECTED="yes"
  has_file Cargo.toml && RUST_DETECTED="yes"
  has_any_file mvnw pom.xml gradlew build.gradle build.gradle.kts && JAVA_DETECTED="yes"
  has_file composer.json && PHP_DETECTED="yes"
  shopt -s nullglob
  ([ -n "$(echo "$PROJECT_DIR"/*.csproj 2>/dev/null)" ] || [ -n "$(echo "$PROJECT_DIR"/*.sln 2>/dev/null)" ]) && DOTNET_DETECTED="yes"
  shopt -u nullglob

  echo "$NODE_DETECTED" "$PY_DETECTED" "$GO_DETECTED" "$RUST_DETECTED" "$JAVA_DETECTED" "$PHP_DETECTED" "$DOTNET_DETECTED"
}

#-----------------------------
# Main
#-----------------------------
main() {
  log "Starting project environment setup..."
  detect_pkg_manager
  install_base_system
  setup_directories_and_users
  write_env_profile

  read NODE_DETECTED PY_DETECTED GO_DETECTED RUST_DETECTED JAVA_DETECTED PHP_DETECTED DOTNET_DETECTED < <(detect_stack)

  # Node.js
  if { [ "$INSTALL_NODE" = "yes" ] || { [ "$INSTALL_NODE" = "auto" ] && [ "$NODE_DETECTED" = "yes" ]; }; }; then
    install_node
    node_install_deps
  else
    log "Skipping Node.js setup."
  fi

  # Python
  if { [ "$INSTALL_PYTHON" = "yes" ] || { [ "$INSTALL_PYTHON" = "auto" ] && [ "$PY_DETECTED" = "yes" ]; }; }; then
    install_python
  else
    log "Skipping Python setup."
  fi

  # Go
  if { [ "$INSTALL_GO" = "yes" ] || { [ "$INSTALL_GO" = "auto" ] && [ "$GO_DETECTED" = "yes" ]; }; }; then
    install_go
  else
    log "Skipping Go setup."
  fi

  # Rust
  if { [ "$INSTALL_RUST" = "yes" ] || { [ "$INSTALL_RUST" = "auto" ] && [ "$RUST_DETECTED" = "yes" ]; }; }; then
    install_rust
  else
    log "Skipping Rust setup."
  fi

  # Java
  if { [ "$INSTALL_JAVA" = "yes" ] || { [ "$INSTALL_JAVA" = "auto" ] && [ "$JAVA_DETECTED" = "yes" ]; }; }; then
    install_java
  else
    log "Skipping Java setup."
  fi

  # PHP
  if { [ "$INSTALL_PHP" = "yes" ] || { [ "$INSTALL_PHP" = "auto" ] && [ "$PHP_DETECTED" = "yes" ]; }; }; then
    install_php
  else
    log "Skipping PHP setup."
  fi

  # .NET
  if { [ "$INSTALL_DOTNET" = "yes" ] || { [ "$INSTALL_DOTNET" = "auto" ] && [ "$DOTNET_DETECTED" = "yes" ]; }; }; then
    install_dotnet
  else
    log "Skipping .NET setup."
  fi

  # Permissions
  if [ -n "$APP_USER" ] && [ "$CREATE_APP_USER" = "yes" ]; then
    chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR" || true
  fi

  # Create build detection runner and execute under timeout
  create_build_runner_script
  run_detected_build || true

  log "Environment setup completed successfully."
  log "Summary:"
  log "- Project directory: $PROJECT_DIR"
  log "- Detected stacks: Node=$NODE_DETECTED, Python=$PY_DETECTED, Go=$GO_DETECTED, Rust=$RUST_DETECTED, Java=$JAVA_DETECTED, PHP=$PHP_DETECTED, .NET=$DOTNET_DETECTED"
  log "Usage:"
  log "- To load environment vars in interactive shells: source /etc/profile.d/project_env.sh"
  log "- Python venv (if created): source \"$PROJECT_DIR/.venv/bin/activate\""
}

main "$@"