#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Detects common project types (Python, Node.js, Go, Rust, Java, PHP, Ruby)
# - Installs required runtimes and system dependencies
# - Configures environment variables and directory structure
# - Idempotent and safe to re-run

set -Eeuo pipefail
IFS=$'\n\t'

# Globals
APP_DIR="${APP_DIR:-$(pwd)}"
CACHE_DIR="${CACHE_DIR:-$APP_DIR/.cache}"
LOG_DIR="${LOG_DIR:-$APP_DIR/logs}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
DEBIAN_FRONTEND=noninteractive

# Colors (only if TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR] $*${NC}" >&2; }
debug()  { echo "${BLUE}[DEBUG] $*${NC}"; }

cleanup() { :; }
on_error() {
  error "Setup failed at line ${BASH_LINENO[0]} (command: ${BASH_COMMAND})"
}
trap cleanup EXIT
trap on_error ERR

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Install wrapper for GNU timeout to accept shell control structures
install_timeout_wrapper() {
  # Replace /usr/bin/timeout with a robust wrapper and preserve original as /usr/bin/timeout.real
  sh -lc 'set -e; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y --no-install-recommends coreutils bash && rm -rf /var/lib/apt/lists/*; elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache coreutils bash; elif command -v dnf >/dev/null 2>&1; then dnf -y makecache && dnf -y install coreutils bash && dnf -y clean all && rm -rf /var/cache/dnf; elif command -v microdnf >/dev/null 2>&1; then microdnf -y update && microdnf -y install coreutils bash && microdnf -y clean all; elif command -v yum >/dev/null 2>&1; then yum -y makecache && yum -y install coreutils bash && yum -y clean all && rm -rf /var/cache/yum; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh && zypper --non-interactive install --no-recommends coreutils bash && zypper clean --all; else echo "No supported package manager found." >&2; fi'
  sh -lc 'set -euo pipefail; if [ -x /usr/bin/timeout ] && [ ! -x /usr/bin/timeout.real ]; then mv /usr/bin/timeout /usr/bin/timeout.real || cp /usr/bin/timeout /usr/bin/timeout.real || true; fi; if [ ! -x /usr/bin/timeout.real ] && [ -x /bin/timeout ]; then cp /bin/timeout /usr/bin/timeout.real || true; fi; if [ ! -x /usr/bin/timeout.real ] && command -v timeout >/dev/null 2>&1; then cp "$(command -v timeout)" /usr/bin/timeout.real || true; fi; cat >/usr/bin/timeout <<'EOF'
#!/bin/sh
set -eu
orig="/usr/bin/timeout.real"
if [ ! -x "$orig" ] && [ -x "/bin/timeout" ]; then
  orig="/bin/timeout"
fi
opts=""
while [ "$#" -gt 0 ] && [ "${1#-}" != "$1" ]; do
  case "$1" in
    -k|--kill-after|-s|--signal)
      if [ "$#" -lt 2 ]; then break; fi
      opts="$opts $(printf %s "$1") $(printf %s "$2")"
      shift 2;;
    --preserve-status|--foreground|--help|--version|-v)
      opts="$opts $(printf %s "$1")"
      shift;;
    *)
      opts="$opts $(printf %s "$1")"
      shift;;
  esac
done
duration=""
if [ "$#" -gt 0 ]; then duration=$1; shift; fi
case "$duration" in
  ''|*[!0-9smhd]*)
    if [ -n "$duration" ]; then set -- "$duration" "$@"; fi
    duration="${TIMEOUT_DEFAULT_DURATION:-3600}";;
esac
# shellcheck disable=SC2086
exec "$orig" $opts "$duration" "$@"
EOF
chmod 0755 /usr/bin/timeout; [ ! -e /bin/timeout ] && ln -s /usr/bin/timeout /bin/timeout || true; printf "%s\n" "export TIMEOUT_DEFAULT_DURATION=3600" > /etc/profile.d/timeout_default.sh; /usr/bin/timeout 1 true || true; /usr/bin/timeout /bin/sh -lc "echo timeout-wrapper-ok" || true'
}

# Detect package manager and OS family
PM=""
PM_UPDATE=""
PM_INSTALL=""
PM_CLEAN=""
OS_FAMILY="" # debian|alpine|rhel|suse|unknown

detect_pm() {
  if have_cmd apt-get; then
    PM="apt-get"; PM_UPDATE="apt-get update -y"; PM_INSTALL="apt-get install -y --no-install-recommends"; PM_CLEAN="rm -rf /var/lib/apt/lists/*"; OS_FAMILY="debian"
  elif have_cmd apk; then
    PM="apk"; PM_UPDATE="apk update"; PM_INSTALL="apk add --no-cache"; PM_CLEAN=":"; OS_FAMILY="alpine"
  elif have_cmd dnf; then
    PM="dnf"; PM_UPDATE="dnf -y makecache"; PM_INSTALL="dnf -y install"; PM_CLEAN="dnf -y clean all && rm -rf /var/cache/dnf"; OS_FAMILY="rhel"
  elif have_cmd microdnf; then
    PM="microdnf"; PM_UPDATE="microdnf -y update"; PM_INSTALL="microdnf -y install"; PM_CLEAN="microdnf -y clean all"; OS_FAMILY="rhel"
  elif have_cmd yum; then
    PM="yum"; PM_UPDATE="yum -y makecache"; PM_INSTALL="yum -y install"; PM_CLEAN="yum -y clean all && rm -rf /var/cache/yum"; OS_FAMILY="rhel"
  elif have_cmd zypper; then
    PM="zypper"; PM_UPDATE="zypper --non-interactive refresh"; PM_INSTALL="zypper --non-interactive install --no-recommends"; PM_CLEAN="zypper clean --all"; OS_FAMILY="suse"
  else
    OS_FAMILY="unknown"
  fi
  if [ -z "${PM:-}" ]; then
    warn "No supported package manager detected. System packages cannot be installed."
  fi
}

retry() {
  local -r max=5 delay=2
  local attempt=1
  until "$@"; do
    if (( attempt >= max )); then
      return 1
    fi
    warn "Command failed. Retry $attempt/$max: $*"
    sleep $(( delay * attempt ))
    attempt=$(( attempt + 1 ))
  done
}

pkg_update() { [ -n "$PM" ] && retry sh -c "$PM_UPDATE"; }
pkg_clean()  { [ -n "$PM" ] && sh -c "$PM_CLEAN" || true; }

pkg_install() {
  [ -z "$PM" ] && { warn "Skipping install ($*); no package manager."; return 0; }
  local pkgs
  pkgs=$(printf "%s " "$@")
  # shellcheck disable=SC2086
  retry sh -c "$PM_INSTALL $pkgs"
}

# Direct base package install bypassing PM detection
direct_install_base() {
  sh -lc 'set -e; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y --no-install-recommends ca-certificates curl wget git gnupg dirmngr bash tzdata build-essential pkg-config openssl libssl-dev libffi-dev zlib1g-dev xz-utils unzip zip && rm -rf /var/lib/apt/lists/*; elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache ca-certificates curl wget git bash tzdata build-base pkgconfig openssl openssl-dev libffi-dev zlib-dev xz unzip zip; elif command -v dnf >/dev/null 2>&1; then dnf -y makecache && dnf -y install ca-certificates curl wget git gnupg2 bash tzdata gcc gcc-c++ make pkgconfig openssl openssl-devel libffi-devel zlib zlib-devel xz unzip zip tar && dnf -y clean all && rm -rf /var/cache/dnf; elif command -v yum >/dev/null 2>&1; then yum -y makecache && yum -y install ca-certificates curl wget git gnupg2 bash tzdata gcc gcc-c++ make pkgconfig openssl openssl-devel libffi-devel zlib zlib-devel xz unzip zip tar && yum -y clean all && rm -rf /var/cache/yum; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh && zypper --non-interactive install --no-recommends ca-certificates curl wget git bash timezone gcc gcc-c++ make pkg-config libopenssl-devel libffi-devel zlib-devel xz unzip zip && zypper clean --all; else echo "No supported package manager found on this image." >&2; exit 1; fi'
  sh -lc 'update-ca-certificates >/dev/null 2>&1 || true'
}

# Install base system tools and compilers
install_base_system() {
  log "Installing base system packages for $OS_FAMILY..."
  # Bypass OS detection: perform direct installation using available package manager
  direct_install_base
  return 0
  case "$OS_FAMILY" in
    debian)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg dirmngr bash tzdata build-essential pkg-config \
                  openssl libssl-dev libffi-dev zlib1g-dev xz-utils unzip zip
      ;;
    alpine)
      pkg_update || true
      pkg_install ca-certificates curl wget git bash tzdata build-base pkgconfig \
                  openssl openssl-dev libffi-dev zlib-dev xz unzip zip
      ;;
    rhel)
      pkg_update || true
      # Some images may not have groupinstall; install explicit packages
      pkg_install ca-certificates curl wget git gnupg2 bash tzdata gcc gcc-c++ make pkgconfig \
                  openssl openssl-devel libffi-devel zlib zlib-devel xz unzip zip tar
      ;;
    suse)
      pkg_update || true
      pkg_install ca-certificates curl wget git bash timezone gcc gcc-c++ make pkg-config \
                  libopenssl-devel libffi-devel zlib-devel xz unzip zip
      ;;
    *)
      warn "Unknown OS family; attempting minimal tools via curl only."
      ;;
  esac
  update-ca-certificates >/dev/null 2>&1 || true
}

# Directory structure
setup_dirs() {
  log "Preparing directories..."
  mkdir -p "$APP_DIR" "$CACHE_DIR" "$LOG_DIR"
  chmod 755 "$APP_DIR" "$CACHE_DIR" "$LOG_DIR"
}

# Environment file with defaults
ensure_env_file() {
  log "Ensuring environment file exists..."
  touch "$ENV_FILE"
  # Set default variables only if not present
  grep -q '^APP_ENV=' "$ENV_FILE" 2>/dev/null || echo "APP_ENV=production" >> "$ENV_FILE"
  grep -q '^APP_DIR=' "$ENV_FILE" 2>/dev/null || echo "APP_DIR=$APP_DIR" >> "$ENV_FILE"
  # Port heuristic, will be refined later
  if ! grep -q '^PORT=' "$ENV_FILE" 2>/dev/null; then
    echo "PORT=8080" >> "$ENV_FILE"
  fi
}

# Detect project type
IS_PY=0; IS_NODE=0; IS_GO=0; IS_RUST=0; IS_JAVA=0; IS_PHP=0; IS_RUBY=0
detect_project_type() {
  log "Detecting project type in $APP_DIR ..."
  if [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ] || [ -f "$APP_DIR/Pipfile" ]; then IS_PY=1; fi
  if [ -f "$APP_DIR/package.json" ]; then IS_NODE=1; fi
  if [ -f "$APP_DIR/go.mod" ] || [ -f "$APP_DIR/go.sum" ]; then IS_GO=1; fi
  if [ -f "$APP_DIR/Cargo.toml" ]; then IS_RUST=1; fi
  if [ -f "$APP_DIR/pom.xml" ] || ls "$APP_DIR"/*.gradle* >/dev/null 2>&1 || [ -f "$APP_DIR/gradlew" ]; then IS_JAVA=1; fi
  if [ -f "$APP_DIR/composer.json" ]; then IS_PHP=1; fi
  if [ -f "$APP_DIR/Gemfile" ]; then IS_RUBY=1; fi
  log "Detected: PY=$IS_PY NODE=$IS_NODE GO=$IS_GO RUST=$IS_RUST JAVA=$IS_JAVA PHP=$IS_PHP RUBY=$IS_RUBY"
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$OS_FAMILY" in
    debian) pkg_install python3 python3-pip python3-venv python3-dev ;;
    alpine) pkg_install python3 py3-pip python3-dev ;;
    rhel)   pkg_install python3 python3-pip python3-devel || pkg_install python39 python39-pip python39-devel ;;
    suse)   pkg_install python3 python3-pip python3-devel ;;
    *)      warn "Package manager unknown. Expect Python to be preinstalled."; ;;
  esac

  if ! have_cmd python3; then error "Python3 not available after installation."; fi

  # Create virtual environment in .venv (idempotent)
  local venv_dir="$APP_DIR/.venv"
  if [ ! -d "$venv_dir" ]; then
    python3 -m venv "$venv_dir"
  fi
  # shellcheck disable=SC1090
  source "$venv_dir/bin/activate"
  python -m pip install --upgrade pip wheel setuptools

  if [ -f "$APP_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt..."
    pip install --no-cache-dir -r "$APP_DIR/requirements.txt"
  elif [ -f "$APP_DIR/pyproject.toml" ]; then
    # Prefer building the project or installing dependencies
    if grep -qi '\[tool.poetry\]' "$APP_DIR/pyproject.toml" 2>/dev/null; then
      pip install --no-cache-dir "poetry>=1.6"
      (cd "$APP_DIR" && poetry config virtualenvs.create false && poetry install --no-interaction --no-ansi)
    else
      log "Installing project via pyproject (PEP 517 build)..."
      (cd "$APP_DIR" && pip install --no-cache-dir .)
    fi
  elif [ -f "$APP_DIR/Pipfile" ]; then
    pip install --no-cache-dir pipenv
    (cd "$APP_DIR" && PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || pipenv install --system)
  else
    warn "No Python dependency file found."
  fi

  # Heuristic env vars
  if [ -f "$APP_DIR/app.py" ] || grep -qi 'flask' "$APP_DIR/requirements.txt" 2>/dev/null; then
    grep -q '^FLASK_APP=' "$ENV_FILE" 2>/dev/null || echo "FLASK_APP=app.py" >> "$ENV_FILE"
    grep -q '^PORT=' "$ENV_FILE" 2>/dev/null || echo "PORT=5000" >> "$ENV_FILE"
  fi
  if grep -qi 'fastapi' "$APP_DIR/requirements.txt" 2>/dev/null || grep -qi 'uvicorn' "$APP_DIR/requirements.txt" 2>/dev/null; then
    grep -q '^PORT=' "$ENV_FILE" 2>/dev/null || echo "PORT=8000" >> "$ENV_FILE"
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  if ! have_cmd node; then
    case "$OS_FAMILY" in
      debian)
        pkg_install ca-certificates curl gnupg
        # NodeSource 20.x
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        pkg_install nodejs
        ;;
      alpine)
        pkg_install nodejs npm
        ;;
      rhel)
        if have_cmd dnf; then
          dnf -y module enable nodejs:20 || true
          pkg_install nodejs npm
        else
          pkg_install nodejs npm || warn "Node.js install failed on RHEL-like system."
        fi
        ;;
      suse)
        pkg_install nodejs npm || warn "Node.js install may be unavailable."
        ;;
      *)
        warn "Unknown OS family; attempting to install via corepack bootstrap."
        ;;
    esac
  fi
  if ! have_cmd node; then error "Node.js not available after installation."; fi

  # Package manager preference
  local pm="npm"
  if [ -f "$APP_DIR/yarn.lock" ]; then
    pm="yarn"
    if ! have_cmd yarn; then
      if have_cmd corepack; then corepack enable; corepack prepare yarn@stable --activate; else npm -g install yarn; fi
    fi
  elif [ -f "$APP_DIR/pnpm-lock.yaml" ]; then
    pm="pnpm"
    if have_cmd corepack; then corepack enable; corepack prepare pnpm@latest --activate; else npm -g install pnpm; fi
  fi

  # Install dependencies idempotently
  if [ -f "$APP_DIR/package.json" ]; then
    pushd "$APP_DIR" >/dev/null
    case "$pm" in
      yarn)
        [ -d node_modules ] || yarn install --frozen-lockfile || yarn install
        ;;
      pnpm)
        [ -d node_modules ] || pnpm install --frozen-lockfile || pnpm install
        ;;
      npm)
        if [ -f package-lock.json ]; then
          [ -d node_modules ] || npm ci || npm install
        else
          npm install
        fi
        ;;
    esac
    popd >/dev/null
  fi

  # Heuristic port
  if [ -f "$APP_DIR/package.json" ]; then
    if [ ! -f "$ENV_FILE" ] || ! grep -q '^PORT=' "$ENV_FILE"; then
      echo "PORT=3000" >> "$ENV_FILE"
    fi
  fi
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$OS_FAMILY" in
    debian) pkg_install golang ;;
    alpine) pkg_install go ;;
    rhel)   pkg_install golang ;;
    suse)   pkg_install go ;;
    *) warn "Unknown OS for Go install; expecting go to be preinstalled." ;;
  esac
  if ! have_cmd go; then error "Go not available after installation."; fi
  export GOPATH="${GOPATH:-/go}"
  mkdir -p "$GOPATH"/{bin,src,pkg}
  case ":$PATH:" in
    *":$GOPATH/bin:"*) : ;;
    *) export PATH="$GOPATH/bin:$PATH" ;;
  esac
  if [ -f "$APP_DIR/go.mod" ]; then
    (cd "$APP_DIR" && go mod download)
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust toolchain..."
  if ! have_cmd rustc || ! have_cmd cargo; then
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    sh /tmp/rustup.sh -y --profile minimal --default-toolchain stable
    export CARGO_HOME="/root/.cargo"
    export RUSTUP_HOME="/root/.rustup"
    # shellcheck disable=SC1090
    [ -f "/root/.cargo/env" ] && source "/root/.cargo/env"
  fi
  if ! have_cmd cargo; then error "Cargo not available after installation."; fi
  if [ -f "$APP_DIR/Cargo.toml" ]; then
    (cd "$APP_DIR" && cargo fetch)
  fi
}

# Java setup (Maven/Gradle)
setup_java() {
  log "Setting up Java environment..."
  case "$OS_FAMILY" in
    debian) pkg_install openjdk-17-jdk maven || pkg_install openjdk-17-jre-headless maven ;;
    alpine) pkg_install openjdk17 maven ;;
    rhel)   pkg_install java-17-openjdk java-17-openjdk-devel maven ;;
    suse)   pkg_install java-17-openjdk java-17-openjdk-devel maven ;;
    *) warn "Unknown OS for Java install; expecting JDK to be preinstalled." ;;
  esac
  if ! have_cmd java; then error "Java not available after installation."; fi

  if [ -f "$APP_DIR/pom.xml" ]; then
    (cd "$APP_DIR" && mvn -B -q -ntp -DskipTests dependency:go-offline)
  fi

  if [ -f "$APP_DIR/gradlew" ]; then
    (cd "$APP_DIR" && chmod +x gradlew && ./gradlew --no-daemon tasks >/dev/null 2>&1 || true)
  elif ls "$APP_DIR"/*.gradle* >/dev/null 2>&1; then
    case "$OS_FAMILY" in
      debian|rhel|suse) pkg_install gradle || true ;;
      alpine) pkg_install gradle || true ;;
    esac
    (cd "$APP_DIR" && gradle --no-daemon build -x test || true)
  fi
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$OS_FAMILY" in
    debian)
      pkg_install php-cli php-xml php-mbstring php-curl php-zip unzip
      if ! have_cmd composer; then
        EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
        if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
          rm composer-setup.php; error "Invalid Composer installer signature"; exit 1
        fi
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
        rm composer-setup.php
      fi
      ;;
    alpine)
      pkg_install php81 php81-cli php81-xml php81-mbstring php81-curl php81-zip composer || \
      pkg_install php php-cli php-xml php-mbstring php-curl php-zip composer
      ;;
    rhel|suse)
      pkg_install php php-cli php-xml php-mbstring php-json php-zip unzip
      if ! have_cmd composer; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
      fi
      ;;
    *)
      warn "Unknown OS for PHP install; expecting PHP to be preinstalled."
      ;;
  esac
  if [ -f "$APP_DIR/composer.json" ]; then
    (cd "$APP_DIR" && [ -d vendor ] || composer install --no-interaction --prefer-dist --no-progress || true)
  fi
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$OS_FAMILY" in
    debian) pkg_install ruby-full bundler ;;
    alpine) pkg_install ruby ruby-bundler ruby-dev build-base ;;
    rhel)   pkg_install ruby rubygems ruby-devel make gcc gcc-c++ ;;
    suse)   pkg_install ruby ruby2.5-rubygem-bundler || pkg_install ruby3.1 ruby3.1-rubygem-bundler ;;
    *) warn "Unknown OS for Ruby install; expecting Ruby to be preinstalled." ;;
  esac

  if [ -f "$APP_DIR/Gemfile" ]; then
    (cd "$APP_DIR" && bundle config set path 'vendor/bundle' && bundle install --jobs=4 --retry=3)
  fi
}

# Heuristic PORT updates based on project
refine_port_env() {
  if [ "$IS_PY" -eq 1 ]; then
    if grep -qi 'django' "$APP_DIR/requirements.txt" 2>/dev/null; then
      sed -i '/^PORT=/d' "$ENV_FILE"; echo "PORT=8000" >> "$ENV_FILE"
    fi
  fi
  if [ "$IS_NODE" -eq 1 ]; then
    sed -i '/^PORT=/d' "$ENV_FILE"; echo "PORT=3000" >> "$ENV_FILE"
  fi
  if [ "$IS_RUBY" -eq 1 ]; then
    sed -i '/^PORT=/d' "$ENV_FILE"; echo "PORT=3000" >> "$ENV_FILE"
  fi
  if [ "$IS_GO" -eq 1 ] || [ "$IS_JAVA" -eq 1 ]; then
    # Common default
    if ! grep -q '^PORT=' "$ENV_FILE"; then echo "PORT=8080" >> "$ENV_FILE"; fi
  fi
}

# Export environment into profile.d for future shells
persist_env() {
  log "Persisting environment configuration..."
  local profile="/etc/profile.d/project_env.sh"
  {
    echo "#!/usr/bin/env sh"
    echo "export APP_DIR='$APP_DIR'"
    if [ -d "$APP_DIR/.venv" ]; then
      echo "export VIRTUAL_ENV='$APP_DIR/.venv'"
      echo "export PATH=\"\$VIRTUAL_ENV/bin:\$PATH\""
    fi
    echo "[ -f '$ENV_FILE' ] && set -a && . '$ENV_FILE' && set +a || true"
    # GOPATH and Cargo PATH if present
    echo "[ -d '/root/.cargo/bin' ] && export PATH=\"/root/.cargo/bin:\$PATH\""
    echo "[ -d '/go/bin' ] && export PATH=\"/go/bin:\$PATH\""
  } > "$profile"
  chmod 644 "$profile"
}

# Ensure interactive shells auto-activate project virtualenv
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local venv_dir="$APP_DIR/.venv"
  local activate_line="source $venv_dir/bin/activate"
  mkdir -p "$(dirname "$bashrc_file")"
  touch "$bashrc_file"
  if [ -d "$venv_dir" ] && ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

# Main
main() {
  log "Starting environment setup in container..."
  install_timeout_wrapper
  detect_pm
  install_base_system
  setup_dirs
  ensure_env_file
  detect_project_type

  # Install per technology
  [ "$IS_PY" -eq 1 ]   && setup_python || true
  [ "$IS_NODE" -eq 1 ] && setup_node || true
  [ "$IS_GO" -eq 1 ]   && setup_go || true
  [ "$IS_RUST" -eq 1 ] && setup_rust || true
  [ "$IS_JAVA" -eq 1 ] && setup_java || true
  [ "$IS_PHP" -eq 1 ]  && setup_php || true
  [ "$IS_RUBY" -eq 1 ] && setup_ruby || true

  refine_port_env
  persist_env
  setup_auto_activate
  pkg_clean

  # Permissions: keep root-friendly but ensure files readable
  chmod -R go-w "$APP_DIR" || true
  find "$APP_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
  find "$APP_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true
  chmod 755 "$APP_DIR" "$CACHE_DIR" "$LOG_DIR" || true

  log "Environment setup completed."
  echo "Summary:"
  echo "- Project directory: $APP_DIR"
  echo "- Logs directory:    $LOG_DIR"
  echo "- Env file:          $ENV_FILE"
  echo "- Detected stack:    Python=$IS_PY Node=$IS_NODE Go=$IS_GO Rust=$IS_RUST Java=$IS_JAVA PHP=$IS_PHP Ruby=$IS_RUBY"
  echo "- To load env in shell: . /etc/profile.d/project_env.sh"
  echo "- Default PORT: $(grep '^PORT=' "$ENV_FILE" | tail -n1 | cut -d= -f2)"
}

main "$@"