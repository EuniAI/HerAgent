#!/usr/bin/env bash
# Environment setup script for containerized projects with auto-detection of common stacks.
# Safe to run multiple times (idempotent), handles Debian/Ubuntu/Alpine/RHEL/CentOS/Fedora/SLES.
# It installs system packages, runtimes, dependencies, sets directory structure, and configures env.

set -Eeuo pipefail
IFS=$'\n\t'

# ------------- Configuration Defaults -------------
PROJECT_ROOT="${PROJECT_ROOT:-/app}"
APP_USER="${APP_USER:-root}"
APP_GROUP="${APP_GROUP:-root}"
APP_ENV="${APP_ENV:-production}"
TZ="${TZ:-UTC}"
APP_PORT="${APP_PORT:-}"   # will be auto-detected by stack if empty
STAMP_DIR="/var/local/setup-stamps"
LOG_FILE="${LOG_FILE:-/var/log/project_setup.log}"
PATH_EXPORT_FILE="/etc/profile.d/99-project-paths.sh"
ENV_EXPORT_FILE="/etc/profile.d/99-project-env.sh"

# ------------- Logging -------------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()    { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()   { log "${GREEN}[INFO]${NC} $*"; }
warn()   { log "${YELLOW}[WARN]${NC} $*"; }
error()  { log "${RED}[ERROR]${NC} $*" >&2; }
die()    { error "$*"; exit 1; }

# ------------- Traps -------------
cleanup() { :
  # Placeholder for any cleanup; left intentionally blank to keep idempotency intact.
}
trap cleanup EXIT
trap 'error "An error occurred on line $LINENO"; exit 1' ERR

# ------------- Pre-flight Checks -------------
ensure_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "This script must run as root inside the container (no sudo available)."
  fi
}
ensure_writeable_paths() {
  mkdir -p "$(dirname "$LOG_FILE")" "$STAMP_DIR"
  touch "$LOG_FILE" || die "Cannot write to $LOG_FILE"
  chmod 644 "$LOG_FILE" || true
}

# ------------- OS / Package Manager Detection -------------
PKG_MANAGER=""
OS_FAMILY=""
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    OS_FAMILY="debian"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    OS_FAMILY="rhel"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
    OS_FAMILY="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    OS_FAMILY="rhel"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
    OS_FAMILY="sles"
  else
    die "Unsupported or unknown package manager. Install apt, apk, dnf, microdnf, yum, or zypper."
  fi
  info "Detected package manager: $PKG_MANAGER ($OS_FAMILY)"
}
pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      if [ ! -f "$STAMP_DIR/apt-updated" ]; then
        apt-get update -y && touch "$STAMP_DIR/apt-updated"
      fi
      ;;
    apk) : ;; # apk uses --no-cache for update automatically
    dnf|microdnf|yum) : ;; # not necessary to cache update
    zypper)
      if [ ! -f "$STAMP_DIR/zypper-refreshed" ]; then
        zypper --non-interactive refresh && touch "$STAMP_DIR/zypper-refreshed"
      fi
      ;;
  esac
}
pkg_install() {
  # Usage: pkg_install pkg1 pkg2 ...
  local pkgs=("$@")
  case "$PKG_MANAGER" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}" || dnf install -y --allowerasing "${pkgs[@]}"
      ;;
    microdnf)
      microdnf install -y "${pkgs[@]}" || microdnf install -y --best "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${pkgs[@]}"
      ;;
    *) die "Unknown package manager: $PKG_MANAGER" ;;
  esac
}
pkg_cleanup() {
  case "$PKG_MANAGER" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /var/cache/apt/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|microdnf|yum)
      rm -rf /var/cache/dnf/* /var/cache/yum/* || true
      ;;
    zypper)
      rm -rf /var/cache/zypp/* || true
      ;;
  esac
}

# ------------- Base System Packages -------------
install_base_system_packages() {
  info "Installing base system packages..."
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl wget git tzdata openssh-client gnupg dirmngr
      pkg_install build-essential pkg-config openssl libssl-dev libffi-dev
      ;;
    apk)
      pkg_install ca-certificates curl wget git tzdata openssh-client openssl \
                  build-base pkgconfig libffi-dev openssl-dev bash
      ;;
    dnf|microdnf|yum)
      pkg_install ca-certificates curl wget git tzdata openssh-clients gnupg2 \
                  openssl openssl-devel gcc gcc-c++ make automake autoconf libffi-devel
      ;;
    zypper)
      pkg_install ca-certificates curl wget git timezone openssh openssl \
                  gcc gcc-c++ make automake autoconf libffi-devel
      ;;
  esac
  update-ca-certificates 2>/dev/null || true
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime 2>/dev/null || true
  echo "$TZ" > /etc/timezone 2>/dev/null || true
  # Configure UTF-8 locale if apt-get is available
  sh -c 'if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y locales && sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen && locale-gen; fi' || true
  sh -c 'grep -qxF "LANG=en_US.UTF-8" /etc/environment || echo "LANG=en_US.UTF-8" >> /etc/environment' || true
  sh -c 'grep -qxF "LC_ALL=en_US.UTF-8" /etc/environment || echo "LC_ALL=en_US.UTF-8" >> /etc/environment' || true
  info "Base system packages installation completed."
}

# ------------- Project Directory Setup -------------
setup_project_structure() {
  info "Setting up project directory structure at $PROJECT_ROOT..."
  mkdir -p "$PROJECT_ROOT" "$PROJECT_ROOT/logs" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/data"
  # If script not run from project root and a likely project exists in CWD, use CWD
  if [ -f "./package.json" ] || [ -f "./requirements.txt" ] || [ -f "./pyproject.toml" ] || \
     [ -f "./pom.xml" ] || [ -f "./build.gradle" ] || [ -f "./go.mod" ] || \
     [ -f "./composer.json" ] || compgen -G "./*.csproj" >/dev/null || [ -f "./Cargo.toml" ]; then
    PROJECT_ROOT="$(pwd)"
  fi
  chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT"
  chmod -R u+rwX,g+rX "$PROJECT_ROOT"
  info "Project root set to: $PROJECT_ROOT"
}

# ------------- Environment Variables Handling -------------
load_dotenv() {
  # Loads .env if present, without overriding already exported variables
  local env_file="$PROJECT_ROOT/.env"
  if [ -f "$env_file" ]; then
    info "Loading environment variables from .env"
    while IFS='=' read -r key value; do
      # skip comments and empty lines
      [[ "$key" =~ ^#.*$ ]] && continue
      [ -z "$key" ] && continue
      # strip quotes and export if not set
      value="${value%\"}"; value="${value#\"}"
      value="${value%\'}"; value="${value#\'}"
      if [ -z "${!key-}" ]; then
        export "$key=$value"
      fi
    done < <(grep -v '^[[:space:]]*#' "$env_file" | sed '/^[[:space:]]*$/d')
  fi
}
persist_env() {
  # Persist key env variables for interactive shells
  mkdir -p "$(dirname "$ENV_EXPORT_FILE")"
  cat > "$ENV_EXPORT_FILE" <<EOF
# Auto-generated project environment exports
export PROJECT_ROOT="$PROJECT_ROOT"
export APP_ENV="${APP_ENV}"
${APP_PORT:+export APP_PORT="${APP_PORT}"}
export TZ="${TZ}"
# Python
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
# Go
${GOPATH:+export GOPATH="${GOPATH}"}
# Dotnet
${DOTNET_ROOT:+export DOTNET_ROOT="${DOTNET_ROOT}"}
${DOTNET_ROOT:+export PATH="\$DOTNET_ROOT:\$PATH"}
# Rust
${CARGO_HOME:+export CARGO_HOME="${CARGO_HOME}"}
${RUSTUP_HOME:+export RUSTUP_HOME="${RUSTUP_HOME}"}
${CARGO_HOME:+export PATH="\$CARGO_HOME/bin:\$PATH"}
EOF
  chmod 644 "$ENV_EXPORT_FILE" || true
}

persist_paths() {
  mkdir -p "$(dirname "$PATH_EXPORT_FILE")"
  {
    echo "# Auto-generated PATH adjustments for project tools"
    [ -d "$PROJECT_ROOT/node_modules/.bin" ] && echo "export PATH=\"$PROJECT_ROOT/node_modules/.bin:\$PATH\""
    [ -d "$PROJECT_ROOT/.venv/bin" ] && echo "export PATH=\"$PROJECT_ROOT/.venv/bin:\$PATH\""
  } > "$PATH_EXPORT_FILE"
  chmod 644 "$PATH_EXPORT_FILE" || true
}

# ------------- Stack Detection -------------
is_python_project()  { [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/Pipfile" ]; }
is_node_project()    { [ -f "$PROJECT_ROOT/package.json" ]; }
is_java_project()    { [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/gradlew" ] || [ -f "$PROJECT_ROOT/mvnw" ]; }
is_go_project()      { [ -f "$PROJECT_ROOT/go.mod" ]; }
is_php_project()     { [ -f "$PROJECT_ROOT/composer.json" ]; }
is_dotnet_project()  { compgen -G "$PROJECT_ROOT/*.sln" >/dev/null || compgen -G "$PROJECT_ROOT/*.csproj" >/dev/null; }
is_rust_project()    { [ -f "$PROJECT_ROOT/Cargo.toml" ]; }

# ------------- Python Setup -------------
setup_python() {
  info "Configuring Python environment..."
  case "$PKG_MANAGER" in
    apt)  pkg_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev ;;
    apk)  pkg_install python3 py3-pip python3-dev musl-dev libffi-dev openssl-dev ;;
    dnf|microdnf|yum) pkg_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel ;;
    zypper) pkg_install python3 python3-pip python3-venv python3-devel gcc gcc-c++ make libffi-devel libopenssl-devel || true ;;
  esac

  # Create venv if missing
  if [ ! -d "$PROJECT_ROOT/.venv" ]; then
    python3 -m venv "$PROJECT_ROOT/.venv"
  fi
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.venv/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel

  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    pip install -r "$PROJECT_ROOT/requirements.txt"
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    # Try PEP 621 install if build-system present
    pip install "build>=1.0.0" "pip>=23.0"
    if grep -q "tool.poetry" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      python3 -m pip install "poetry>=1.6"
      poetry config virtualenvs.create false
      poetry install --no-root --no-interaction --no-ansi
    else
      # Editable install if project metadata exists
      pip install -e "$PROJECT_ROOT" || true
    fi
  elif [ -f "$PROJECT_ROOT/Pipfile" ]; then
    pip install pipenv && PIPENV_VENV_IN_PROJECT=1 pipenv install --dev || true
  fi

  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1

  # Guess default port
  if [ -z "$APP_PORT" ]; then
    if [ -f "$PROJECT_ROOT/app.py" ] || [ -d "$PROJECT_ROOT/flask_app" ]; then
      APP_PORT=5000
    elif [ -d "$PROJECT_ROOT/project" ] || [ -d "$PROJECT_ROOT/app" ]; then
      APP_PORT=8000
    fi
  fi

  info "Python environment setup completed."
}

# ------------- Node.js Setup -------------
setup_node() {
  info "Configuring Node.js environment..."
  case "$PKG_MANAGER" in
    apt)  pkg_install nodejs npm ;;
    apk)  pkg_install nodejs npm ;;
    dnf|microdnf|yum) pkg_install nodejs npm ;;
    zypper) pkg_install nodejs npm ;;
  esac

  pushd "$PROJECT_ROOT" >/dev/null
  # Corepack for Yarn/Pnpm if available (Node 16.10+)
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  fi

  if [ -f "pnpm-lock.yaml" ]; then
    if command -v pnpm >/dev/null 2>&1; then :; else npm i -g pnpm@latest || true; fi
    pnpm install --frozen-lockfile || pnpm install
  elif [ -f "yarn.lock" ]; then
    if command -v yarn >/dev/null 2>&1; then :; else
      if command -v corepack >/dev/null 2>&1; then corepack prepare yarn@stable --activate || true; else npm i -g yarn || true; fi
    fi
    yarn install --frozen-lockfile || yarn install
  elif [ -f "package-lock.json" ]; then
    npm ci || npm install
  else
    npm install || true
  fi

  # Guess default port
  if [ -z "$APP_PORT" ]; then
    APP_PORT=3000
  fi
  popd >/dev/null
  info "Node.js environment setup completed."
}

# ------------- Java (Maven/Gradle) Setup -------------
setup_java() {
  info "Configuring Java environment..."
  case "$PKG_MANAGER" in
    apt)  pkg_install openjdk-17-jdk ca-certificates-java maven || pkg_install openjdk-17-jdk ca-certificates-java ;;
    apk)  pkg_install openjdk17-jdk maven || pkg_install openjdk17-jdk ;;
    dnf|microdnf|yum) pkg_install java-17-openjdk-devel maven || pkg_install java-17-openjdk-devel ;;
    zypper) pkg_install java-17-openjdk-devel maven || pkg_install java-17-openjdk-devel ;;
  esac

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -x "./mvnw" ]; then
    chmod +x ./mvnw
    ./mvnw -B -ntp -DskipTests dependency:go-offline || true
  elif [ -f "pom.xml" ]; then
    if command -v mvn >/dev/null 2>&1; then
      mvn -B -ntp -DskipTests dependency:go-offline || true
    fi
  fi

  if [ -x "./gradlew" ]; then
    chmod +x ./gradlew
    ./gradlew --no-daemon tasks >/dev/null 2>&1 || true
  elif [ -f "build.gradle" ] || [ -f "settings.gradle" ]; then
    if command -v gradle >/dev/null 2>&1; then
      gradle --no-daemon tasks >/dev/null 2>&1 || true
    fi
  fi
  popd >/dev/null

  # Guess default port
  if [ -z "$APP_PORT" ]; then
    APP_PORT=8080
  fi
  info "Java environment setup completed."
}

# ------------- Go Setup -------------
setup_go() {
  info "Configuring Go environment..."
  case "$PKG_MANAGER" in
    apt)  pkg_install golang ;;
    apk)  pkg_install go ;;
    dnf|microdnf|yum) pkg_install golang ;;
    zypper) pkg_install go ;;
  esac

  export GOPATH="${GOPATH:-/go}"
  mkdir -p "$GOPATH" "$GOPATH/bin"
  if ! grep -q "export GOPATH=" "$ENV_EXPORT_FILE" 2>/dev/null; then
    echo "export GOPATH=\"$GOPATH\"" >> "$ENV_EXPORT_FILE"
    echo "export PATH=\"\$GOPATH/bin:\$PATH\"" >> "$ENV_EXPORT_FILE"
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "go.mod" ]; then
    go mod download || true
  fi
  popd >/dev/null

  if [ -z "$APP_PORT" ]; then
    APP_PORT=8080
  fi
  info "Go environment setup completed."
}

# ------------- PHP Setup -------------
setup_php() {
  info "Configuring PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      pkg_install php-cli php-mbstring php-xml php-zip php-curl unzip
      ;;
    apk)
      pkg_install php81 php81-cli php81-mbstring php81-xml php81-zip php81-curl unzip || \
      pkg_install php php-cli php-mbstring php-xml php-zip php-curl unzip
      ;;
    dnf|microdnf|yum)
      pkg_install php-cli php-json php-mbstring php-xml php-zip php-curl unzip
      ;;
    zypper)
      pkg_install php8 php8-cli php8-mbstring php8-xml php8-zip php8-curl unzip || \
      pkg_install php php-cli php-mbstring php-xml php-zip php-curl unzip
      ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || true
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
    rm -f composer-setup.php || true
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "composer.json" ]; then
    composer install --no-interaction --prefer-dist --no-progress || true
  fi
  popd >/dev/null

  if [ -z "$APP_PORT" ]; then
    APP_PORT=8000
  fi
  info "PHP environment setup completed."
}

# ------------- .NET Setup -------------
setup_dotnet() {
  info "Configuring .NET SDK environment..."
  DOTNET_ROOT="${DOTNET_ROOT:-/opt/dotnet}"
  if [ ! -x "$DOTNET_ROOT/dotnet" ]; then
    mkdir -p "$DOTNET_ROOT"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --install-dir "$DOTNET_ROOT" --channel LTS
    rm -f /tmp/dotnet-install.sh
  fi
  if ! grep -q "DOTNET_ROOT" "$ENV_EXPORT_FILE" 2>/dev/null; then
    echo "export DOTNET_ROOT=\"$DOTNET_ROOT\"" >> "$ENV_EXPORT_FILE"
    echo "export PATH=\"\$DOTNET_ROOT:\$PATH\"" >> "$ENV_EXPORT_FILE"
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  # Restore for all solutions or csproj found
  if compgen -G "*.sln" >/dev/null; then
    for sln in *.sln; do "$DOTNET_ROOT/dotnet" restore "$sln" || true; done
  fi
  if compgen -G "*.csproj" >/dev/null; then
    for proj in *.csproj; do "$DOTNET_ROOT/dotnet" restore "$proj" || true; done
  fi
  popd >/dev/null

  if [ -z "$APP_PORT" ]; then
    APP_PORT=8080
  fi
  info ".NET environment setup completed."
}

# ------------- Rust Setup -------------
setup_rust() {
  info "Configuring Rust environment..."
  export CARGO_HOME="${CARGO_HOME:-/opt/cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rustup}"
  if [ ! -x "$CARGO_HOME/bin/cargo" ]; then
    mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --no-modify-path --default-toolchain stable
    rm -f /tmp/rustup.sh
  fi
  if ! grep -q "CARGO_HOME" "$ENV_EXPORT_FILE" 2>/dev/null; then
    echo "export CARGO_HOME=\"$CARGO_HOME\"" >> "$ENV_EXPORT_FILE"
    echo "export RUSTUP_HOME=\"$RUSTUP_HOME\"" >> "$ENV_EXPORT_FILE"
    echo "export PATH=\"\$CARGO_HOME/bin:\$PATH\"" >> "$ENV_EXPORT_FILE"
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "Cargo.toml" ]; then
    "$CARGO_HOME/bin/cargo" fetch || true
  fi
  popd >/dev/null

  if [ -z "$APP_PORT" ]; then
    APP_PORT=8080
  fi
  info "Rust environment setup completed."
}

# ------------- Ansible Setup -------------
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_line="source /app/.venv/bin/activate"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

setup_ansible_tools() {
  # Ensure Ansible CLI is installed system-wide and ansible-core tooling is available
  case "$PKG_MANAGER" in
    apt)
      info "Installing Ansible CLI and ansible-core tooling..."
      apt-get update -y && apt-get install -y --no-install-recommends ansible python3 python3-venv python3-pip
      printf "[global]\nuse-pep517 = false\n" > /etc/pip.conf
      mkdir -p /app && python3 -m venv /app/.venv
      /app/.venv/bin/python -m pip install --upgrade pip setuptools wheel
      # Configure Git to trust the repository
      git config --global --add safe.directory /app || true
      # Uninstall venv-provided ansible-core/ansible to avoid runner mismatch
      if [ -x /app/.venv/bin/pip ]; then /app/.venv/bin/pip uninstall -y ansible-core ansible || true; else python -m pip uninstall -y ansible-core ansible || true; fi
      # Ensure repository scripts are executable
      test -f /app/bin/ansible-test && chmod +x /app/bin/ansible-test || true; test -f /app/bin/ansible && chmod +x /app/bin/ansible || true
      # Override venv entry points to call repository versions
      if [ -d /app/.venv/bin ] && [ -f /app/bin/ansible-test ]; then printf '#!/usr/bin/env sh\nexec /app/bin/ansible-test "$@"\n' > /app/.venv/bin/ansible-test && chmod +x /app/.venv/bin/ansible-test; fi
      if [ -d /app/.venv/bin ] && [ -f /app/bin/ansible ]; then printf '#!/usr/bin/env sh\nexec /app/bin/ansible "$@"\n' > /app/.venv/bin/ansible && chmod +x /app/.venv/bin/ansible; fi
      # System-wide shims
      ln -sf /app/bin/ansible-test /usr/local/bin/ansible-test && ln -sf /app/bin/ansible /usr/local/bin/ansible
      # Install ansible-container in the venv
      if [ -x /app/.venv/bin/pip ]; then /app/.venv/bin/pip install -U --no-input ansible-container; else python -m pip install -U --no-input ansible-container; fi
      tee /etc/profile.d/10-auto-venv.sh >/dev/null <<'EOF'
# Auto-activate project venv for interactive shells
case "$-" in *i*) [ -d /app/.venv ] && . /app/.venv/bin/activate ;; esac
EOF
      chmod 644 /etc/profile.d/10-auto-venv.sh
      # Enable cross-arch emulation and set default Docker platform for reliability
      apt-get update -y && apt-get install -y qemu-user-static binfmt-support
      if command -v docker >/dev/null 2>&1; then
        docker run --rm --privileged tonistiigi/binfmt --install all || true
        sh -c "grep -q '^DOCKER_DEFAULT_PLATFORM=linux/amd64$' /etc/environment || printf 'DOCKER_DEFAULT_PLATFORM=linux/amd64\n' >> /etc/environment"
        docker pull --platform=linux/amd64 quay.io/ansible/cloudstack-test-container:1.7.0 || true
      else
        warn "Docker not found; skipping binfmt setup and pre-pull."
      fi
      ;;
    *)
      :
      ;;
  esac
}

# ------------- Finalization -------------
finalize_permissions() {
  chown -R "$APP_USER:$APP_GROUP" "$PROJECT_ROOT" || true
}
summary() {
  info "Environment setup completed successfully."
  if [ -n "$APP_PORT" ]; then
    info "Detected default application port: $APP_PORT"
  fi
  info "Project root: $PROJECT_ROOT"
  info "Environment: $APP_ENV"
  info "Log file: $LOG_FILE"
  info "To load environment in interactive shells: source $ENV_EXPORT_FILE; source $PATH_EXPORT_FILE"
}

# ------------- Main -------------
main() {
  ensure_root
  ensure_writeable_paths
  detect_pkg_manager
  install_base_system_packages
  setup_ansible_tools
  setup_project_structure
  setup_auto_activate
  load_dotenv

  # Detect and setup runtimes based on project files
  local any_stack=false
  if is_python_project; then setup_python; any_stack=true; fi
  if is_node_project;   then setup_node;   any_stack=true; fi
  if is_java_project;   then setup_java;   any_stack=true; fi
  if is_go_project;     then setup_go;     any_stack=true; fi
  if is_php_project;    then setup_php;    any_stack=true; fi
  if is_dotnet_project; then setup_dotnet; any_stack=true; fi
  if is_rust_project;   then setup_rust;   any_stack=true; fi

  if [ "$any_stack" = false ]; then
    warn "No recognized project files found in $PROJECT_ROOT."
    warn "Supported detectors: requirements.txt, pyproject.toml, Pipfile, package.json, pom.xml, build.gradle, go.mod, composer.json, *.csproj, *.sln, Cargo.toml"
    warn "Installing minimal toolchain only."
  fi

  persist_paths
  persist_env
  finalize_permissions
  pkg_cleanup
  summary
}

main "$@"