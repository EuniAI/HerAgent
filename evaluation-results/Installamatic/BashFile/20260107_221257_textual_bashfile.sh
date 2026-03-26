#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# - Autodetects common stacks (Node.js, Python, Java, Ruby, Go, PHP, Rust)
# - Installs system deps and runtime
# - Configures environment and caches
# - Idempotent and safe to re-run

set -Eeuo pipefail
IFS=$'\n\t'

# ------------- Logging and error handling -------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

cleanup() { :; }
trap cleanup EXIT
trap 'error "An error occurred on line $LINENO"; exit 1' ERR

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ------------- Context and defaults -------------
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
APP_NAME="${APP_NAME:-app}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appgroup}"

# Common default ports for popular stacks; can be overridden by .env or env
DEFAULT_PORT_NODE=3000
DEFAULT_PORT_PY=5000
DEFAULT_PORT_JAVA=8080
DEFAULT_PORT_GO=8080
DEFAULT_PORT_PHP=8080
DEFAULT_PORT_RUBY=3000

# ------------- Package manager detection -------------
PKG_MGR=""
pm_detect() {
  if command_exists apk; then PKG_MGR="apk"
  elif command_exists apt-get; then PKG_MGR="apt"
  elif command_exists dnf; then PKG_MGR="dnf"
  elif command_exists yum; then PKG_MGR="yum"
  elif command_exists zypper; then PKG_MGR="zypper"
  else
    warn "No known package manager found. Proceeding without system package installation."
    PKG_MGR=""
  fi
}

pm_update() {
  case "$PKG_MGR" in
    apk) apk update >/dev/null ;;
    apt) apt-get update -y -qq ;;
    dnf) dnf -y -q makecache ;;
    yum) yum -y -q makecache ;;
    zypper) zypper -q refresh ;;
    "") return 0 ;;
    *) warn "Unknown package manager: $PKG_MGR" ;;
  esac
}

pm_install() {
  # Accepts a list of packages; ignores empty input
  [ "$#" -eq 0 ] && return 0
  case "$PKG_MGR" in
    apk) apk add --no-cache "$@" ;;
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    dnf) dnf install -y -q "$@" ;;
    yum) yum install -y -q "$@" ;;
    zypper) zypper -n -q install -y "$@" ;;
    "") warn "Cannot install packages without a package manager." ;;
  esac
}

pm_clean() {
  case "$PKG_MGR" in
    apk) rm -rf /var/cache/apk/* ;;
    apt) apt-get clean -y; rm -rf /var/lib/apt/lists/* ;;
    dnf) dnf clean all -q; rm -rf /var/cache/dnf ;;
    yum) yum clean all -q; rm -rf /var/cache/yum ;;
    zypper) zypper clean -a -q ;;
  esac
}

# ------------- System prerequisites -------------
install_base_system() {
  pm_detect
  [ -n "$PKG_MGR" ] || return 0
  log "Installing base system packages using $PKG_MGR ..."
  pm_update

  case "$PKG_MGR" in
    apk)
      pm_install bash ca-certificates curl wget git openssh-client openssl tar xz unzip zip \
                 coreutils findutils grep sed shadow su-exec \
                 build-base pkgconfig
      update-ca-certificates || true
      ;;
    apt)
      pm_install bash ca-certificates curl wget git openssh-client gnupg dirmngr \
                 openssl tar xz-utils unzip zip \
                 coreutils findutils grep sed passwd \
                 build-essential pkg-config
      ;;
    dnf|yum)
      pm_install bash ca-certificates curl wget git openssh-clients gnupg2 \
                 openssl tar xz unzip zip \
                 coreutils findutils grep sed shadow-utils \
                 gcc gcc-c++ make pkgconfig
      ;;
    zypper)
      pm_install bash ca-certificates curl wget git openssh openssl tar xz unzip zip \
                 coreutils findutils gawk grep sed shadow \
                 gcc gcc-c++ make pkg-config
      ;;
  esac

  pm_clean
  log "Base system packages installation completed."
}

# ------------- Users and permissions -------------
ensure_app_user() {
  # Create a non-root user/group if possible (optional)
  if id -u "$APP_USER" >/dev/null 2>&1; then
    return 0
  fi
  if command_exists addgroup && command_exists adduser; then
    addgroup -S "$APP_GROUP" 2>/dev/null || true
    adduser -S -D -H -G "$APP_GROUP" "$APP_USER" 2>/dev/null || true
  elif command_exists groupadd && command_exists useradd; then
    groupadd -r "$APP_GROUP" 2>/dev/null || true
    useradd -r -m -g "$APP_GROUP" -s /usr/sbin/nologin "$APP_USER" 2>/dev/null || true
  else
    warn "No useradd/adduser tools found; continuing as current user."
  fi
}

setup_directories() {
  log "Setting up project directories at $PROJECT_DIR ..."
  mkdir -p "$PROJECT_DIR"
  cd "$PROJECT_DIR"

  # Common directories
  mkdir -p logs tmp data build dist node_modules vendor .cache .bin
  # Python-specific
  mkdir -p .venv
  # Go-specific
  mkdir -p /go/pkg /go/bin /go/src || true

  # Ownership (best-effort)
  if id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER":"$APP_GROUP" "$PROJECT_DIR" 2>/dev/null || true
  fi
}

# ------------- Environment file handling -------------
ENV_FILE="$PROJECT_DIR/.env"
PROFILE_FILE="/etc/profile.d/99-project-env.sh"

write_profile_env() {
  log "Configuring environment exports in $PROFILE_FILE ..."
  {
    echo "export APP_ENV=${APP_ENV}"
    echo "export PIP_NO_CACHE_DIR=1"
    echo "export PYTHONDONTWRITEBYTECODE=1"
    echo "export PYTHONUNBUFFERED=1"
    echo "export PATH=\$PATH:$PROJECT_DIR/.bin"
    echo "[ -f \"$PROJECT_DIR/.venv/bin/activate\" ] && . \"$PROJECT_DIR/.venv/bin/activate\" 2>/dev/null || true"
    echo "[ -d \"/go/bin\" ] && export PATH=\$PATH:/go/bin"
    echo "[ -d \"\$HOME/.cargo/bin\" ] && export PATH=\$PATH:\$HOME/.cargo/bin"
  } > "$PROFILE_FILE"
}

ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    log "Creating default .env file ..."
    {
      echo "APP_NAME=${APP_NAME}"
      echo "APP_ENV=${APP_ENV}"
      echo "PORT=${PORT:-}"
      echo "LOG_LEVEL=info"
    } > "$ENV_FILE"
  fi
}

# ------------- Stack detectors -------------
is_node()   { [ -f "package.json" ]; }
is_python() { [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ] || ls *.py >/dev/null 2>&1; }
is_java()   { [ -f "pom.xml" ] || [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -f "gradlew" ]; }
is_ruby()   { [ -f "Gemfile" ]; }
is_go()     { [ -f "go.mod" ]; }
is_php()    { [ -f "composer.json" ]; }
is_rust()   { [ -f "Cargo.toml" ]; }
is_dotnet() { ls *.sln *.csproj >/dev/null 2>&1; }

# ------------- Language/runtime installers -------------

# Node.js
install_node() {
  if command_exists node && command_exists npm; then
    log "Node.js detected: $(node -v), npm: $(npm -v)"
    return 0
  fi
  log "Installing Node.js ..."
  case "$PKG_MGR" in
    apk) pm_update; pm_install nodejs npm ;;
    apt) pm_update; pm_install nodejs npm ;;
    dnf|yum) pm_update; pm_install nodejs npm || warn "Node.js packages may be unavailable; falling back to binary install." ;;
    zypper) pm_update; pm_install nodejs npm || warn "Node.js packages may be unavailable; falling back to binary install." ;;
    *) warn "No package manager available for Node.js; attempting tarball install." ;;
  esac

  if ! command_exists node; then
    # Fallback to LTS binary (Linux x64)
    NODE_VERSION="${NODE_VERSION:-18.20.5}"
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64|amd64) NODE_ARCH="x64" ;;
      aarch64|arm64) NODE_ARCH="arm64" ;;
      armv7l) NODE_ARCH="armv7l" ;;
      *) NODE_ARCH="x64"; warn "Unknown arch $ARCH; defaulting to x64 binary." ;;
    esac
    tmpdir="$(mktemp -d)"
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o "$tmpdir/node.tar.xz"
    mkdir -p /usr/local/lib/nodejs
    tar -xJf "$tmpdir/node.tar.xz" -C /usr/local/lib/nodejs
    rm -rf "$tmpdir"
    ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${NODE_ARCH}/bin/node" /usr/local/bin/node
    ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${NODE_ARCH}/bin/npm" /usr/local/bin/npm
    ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${NODE_ARCH}/bin/npx" /usr/local/bin/npx
  fi
  log "Node.js installed: $(node -v)"
}

setup_node_project() {
  [ -f "package.json" ] || return 0
  install_node
  # Prefer lockfile managers
  if [ -f "pnpm-lock.yaml" ]; then
    log "Installing PNPM via corepack (if available) ..."
    if command_exists corepack; then corepack enable || true; corepack prepare pnpm@latest --activate || true; fi
    if ! command_exists pnpm; then npm install -g pnpm@8 >/dev/null 2>&1 || true; fi
    pnpm install --frozen-lockfile || pnpm install
  elif [ -f "yarn.lock" ]; then
    if ! command_exists yarn; then npm install -g yarn@1 >/dev/null 2>&1 || true; fi
    yarn install --frozen-lockfile || yarn install
  elif [ -f "package-lock.json" ] || [ -f "npm-shrinkwrap.json" ]; then
    npm ci || npm install
  else
    npm install
  fi

  # Set node env vars
  export NODE_ENV="${NODE_ENV:-production}"
  grep -q "^NODE_ENV=" "$ENV_FILE" 2>/dev/null || echo "NODE_ENV=${NODE_ENV}" >> "$ENV_FILE"
  export PORT="${PORT:-$DEFAULT_PORT_NODE}"
  grep -q "^PORT=" "$ENV_FILE" 2>/dev/null || echo "PORT=$PORT" >> "$ENV_FILE"

  # Prepare start script helper
  mkdir -p .bin
  cat > .bin/start-node.sh <<'EOS'
#!/usr/bin/env bash
set -e
if [ -f package.json ]; then
  if npm run | grep -q -E 'start'; then
    exec npm run start
  else
    # Try common entrypoints
    if [ -f "server.js" ]; then exec node server.js; fi
    if [ -f "app.js" ]; then exec node app.js; fi
    echo "No start script found." >&2; exit 1
  fi
else
  echo "No package.json found." >&2; exit 1
fi
EOS
  chmod +x .bin/start-node.sh
}

# Python
install_python() {
  if command_exists python3 && command_exists pip3; then
    log "Python detected: $(python3 -V 2>&1)"
    return 0
  fi
  log "Installing Python ..."
  case "$PKG_MGR" in
    apk) pm_update; pm_install python3 py3-pip python3-dev musl-dev gcc libffi-dev openssl-dev ;;
    apt) pm_update; pm_install python3 python3-pip python3-venv python3-dev build-essential libffi-dev libssl-dev ;;
    dnf|yum) pm_update; pm_install python3 python3-pip python3-devel gcc gcc-c++ make openssl-devel libffi-devel ;;
    zypper) pm_update; pm_install python3 python3-pip python3-venv python3-devel gcc gcc-c++ make libopenssl-devel libffi-devel ;;
    *) warn "No package manager available to install Python." ;;
  esac
  pm_clean
}

setup_python_project() {
  if ! is_python; then return 0; fi
  install_python

  # Create virtual environment
  if [ ! -f ".venv/bin/activate" ]; then
    log "Creating Python virtual environment ..."
    python3 -m venv .venv
  fi
  # shellcheck disable=SC1091
  . ".venv/bin/activate"
  pip install --no-input --upgrade pip setuptools wheel

  if [ -f "requirements.txt" ]; then
    pip install --no-input -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    # Attempt Poetry if pyproject suggests it, else pip install with hatchling/setuptools
    if grep -qE '^\[tool\.poetry\]' pyproject.toml 2>/dev/null; then
      pip install --no-input "poetry>=1.6"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-ansi || true
    else
      pip install --no-input .
    fi
  elif [ -f "Pipfile" ]; then
    pip install --no-input pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  fi

  export PORT="${PORT:-$DEFAULT_PORT_PY}"
  grep -q "^PORT=" "$ENV_FILE" 2>/dev/null || echo "PORT=$PORT" >> "$ENV_FILE"

  mkdir -p .bin
  cat > .bin/start-python.sh <<'EOS'
#!/usr/bin/env bash
set -e
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
if [ -f "app.py" ]; then
  exec python app.py
elif [ -f "wsgi.py" ]; then
  exec python wsgi.py
else
  # Try Flask if available
  if python - <<'PY' 2>/dev/null; then
from importlib.util import find_spec
print('flask' if find_spec('flask') else '')
PY
  then
    export FLASK_APP=${FLASK_APP:-app.py}
    exec flask run --host=0.0.0.0 --port="${PORT:-5000}"
  fi
  echo "No Python entrypoint found." >&2; exit 1
fi
EOS
  chmod +x .bin/start-python.sh
}

# Java
install_java() {
  if command_exists java; then
    log "Java detected: $(java -version 2>&1 | head -n1)"
    return 0
  fi
  log "Installing OpenJDK ..."
  case "$PKG_MGR" in
    apk) pm_update; pm_install openjdk17-jdk ;;
    apt) pm_update; pm_install openjdk-17-jdk ;;
    dnf|yum) pm_update; pm_install java-17-openjdk-devel ;;
    zypper) pm_update; pm_install java-17-openjdk-devel ;;
    *) warn "No package manager available to install Java." ;;
  esac
  pm_clean
}

setup_java_project() {
  if ! is_java; then return 0; fi
  install_java

  if [ -f "pom.xml" ]; then
    if ! command_exists mvn && [ -f "mvnw" ]; then chmod +x mvnw; fi
    if command_exists mvn; then
      mvn -q -B -DskipTests dependency:go-offline || true
    elif [ -f "./mvnw" ]; then
      ./mvnw -q -B -DskipTests dependency:go-offline || true
    else
      case "$PKG_MGR" in
        apk) pm_install maven ;;
        apt) pm_install maven ;;
        dnf|yum) pm_install maven ;;
        zypper) pm_install maven ;;
      esac
      pm_clean
      mvn -q -B -DskipTests dependency:go-offline || true
    fi
  fi

  if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew --no-daemon tasks >/dev/null || true
  elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
    case "$PKG_MGR" in
      apk) pm_install gradle || true ;;
      apt) pm_install gradle || true ;;
      dnf|yum) pm_install gradle || true ;;
      zypper) pm_install gradle || true ;;
    esac
    pm_clean
    gradle --no-daemon tasks >/dev/null || true
  fi

  export PORT="${PORT:-$DEFAULT_PORT_JAVA}"
  grep -q "^PORT=" "$ENV_FILE" 2>/dev/null || echo "PORT=$PORT" >> "$ENV_FILE"

  mkdir -p .bin
  cat > .bin/start-java.sh <<'EOS'
#!/usr/bin/env bash
set -e
if [ -f "target/*.jar" ]; then
  JAR=$(ls -t target/*.jar | head -n1)
  exec java -jar "$JAR"
elif [ -f "pom.xml" ]; then
  if command -v mvn >/dev/null 2>&1; then exec mvn spring-boot:run; fi
  if [ -f "./mvnw" ]; then exec ./mvnw spring-boot:run; fi
elif [ -f "gradlew" ]; then
  exec ./gradlew --no-daemon bootRun
fi
echo "No Java entrypoint found." >&2; exit 1
EOS
  chmod +x .bin/start-java.sh
}

# Ruby
install_ruby() {
  if command_exists ruby; then
    log "Ruby detected: $(ruby -v)"
    return 0
  fi
  log "Installing Ruby ..."
  case "$PKG_MGR" in
    apk) pm_update; pm_install ruby ruby-dev build-base ;;
    apt) pm_update; pm_install ruby-full build-essential ;;
    dnf|yum) pm_update; pm_install ruby ruby-devel gcc gcc-c++ make ;;
    zypper) pm_update; pm_install ruby ruby-devel gcc gcc-c++ make ;;
    *) warn "No package manager available to install Ruby." ;;
  esac
  pm_clean
}

setup_ruby_project() {
  if ! is_ruby; then return 0; fi
  install_ruby
  gem install bundler --no-document || true
  bundle config set path 'vendor/bundle'
  bundle install --jobs "$(nproc || echo 2)" --retry 3 || bundle install
  export PORT="${PORT:-$DEFAULT_PORT_RUBY}"
  grep -q "^PORT=" "$ENV_FILE" 2>/dev/null || echo "PORT=$PORT" >> "$ENV_FILE"

  mkdir -p .bin
  cat > .bin/start-ruby.sh <<'EOS'
#!/usr/bin/env bash
set -e
if [ -f "config.ru" ]; then
  exec bundle exec rackup -o 0.0.0.0 -p "${PORT:-3000}"
fi
if [ -f "bin/rails" ] || [ -f "config/application.rb" ]; then
  exec bundle exec rails server -b 0.0.0.0 -p "${PORT:-3000}"
fi
echo "No Ruby entrypoint found." >&2; exit 1
EOS
  chmod +x .bin/start-ruby.sh
}

# Go
install_go() {
  if command_exists go; then
    log "Go detected: $(go version)"
    return 0
  fi
  log "Installing Go ..."
  case "$PKG_MGR" in
    apk) pm_update; pm_install go ;;
    apt) pm_update; pm_install golang ;;
    dnf|yum) pm_update; pm_install golang ;;
    zypper) pm_update; pm_install go ;;
    *) warn "No package manager available to install Go." ;;
  esac
  pm_clean
}

setup_go_project() {
  if ! is_go; then return 0; fi
  install_go
  export GOPATH="${GOPATH:-/go}"
  export GOCACHE="${GOCACHE:-$PROJECT_DIR/.cache/go-build}"
  export PATH="$PATH:$GOPATH/bin"
  go env -w GOPATH="$GOPATH" GOCACHE="$GOCACHE" || true
  go mod download || true
  export PORT="${PORT:-$DEFAULT_PORT_GO}"
  grep -q "^PORT=" "$ENV_FILE" 2>/dev/null || echo "PORT=$PORT" >> "$ENV_FILE"

  mkdir -p .bin
  cat > .bin/start-go.sh <<'EOS'
#!/usr/bin/env bash
set -e
if [ -f "main.go" ]; then
  exec go run .
fi
if ls cmd/*/main.go >/dev/null 2>&1; then
  APP=$(ls cmd/*/main.go | head -n1)
  DIR=$(dirname "$APP")
  exec go run "$DIR"
fi
echo "No Go entrypoint found." >&2; exit 1
EOS
  chmod +x .bin/start-go.sh
}

# PHP
install_php() {
  if command_exists php; then
    log "PHP detected: $(php -v | head -n1)"
    return 0
  fi
  log "Installing PHP CLI ..."
  case "$PKG_MGR" in
    apk) pm_update; pm_install php81 php81-cli php81-mbstring php81-openssl php81-xml php81-json php81-phar php81-zip php81-simplexml php81-curl php81-tokenizer php81-dom php81-session php81-fileinfo php81-iconv php81-pdo php81-opcache ;;
    apt) pm_update; pm_install php-cli php-mbstring php-xml php-zip php-curl unzip ;;
    dnf|yum) pm_update; pm_install php-cli php-mbstring php-xml php-zip php-curl unzip ;;
    zypper) pm_update; pm_install php8 php8-mbstring php8-xml php8-zip php8-curl unzip ;;
    *) warn "No package manager available to install PHP." ;;
  esac
  pm_clean
}

install_composer() {
  if command_exists composer; then return 0; fi
  log "Installing Composer ..."
  EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
  if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
    rm -f composer-setup.php
    die "Invalid composer installer signature."
  fi
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f composer-setup.php
}

setup_php_project() {
  if ! is_php; then return 0; fi
  install_php
  install_composer || true
  if command_exists composer; then
    composer install --no-interaction --prefer-dist || composer install
  fi
  export PORT="${PORT:-$DEFAULT_PORT_PHP}"
  grep -q "^PORT=" "$ENV_FILE" 2>/dev/null || echo "PORT=$PORT" >> "$ENV_FILE"

  mkdir -p .bin
  cat > .bin/start-php.sh <<'EOS'
#!/usr/bin/env bash
set -e
DOCROOT="public"
[ -d "public" ] || DOCROOT="."
exec php -S 0.0.0.0:"${PORT:-8080}" -t "$DOCROOT"
EOS
  chmod +x .bin/start-php.sh
}

# Rust
install_rust() {
  if command_exists cargo; then
    log "Rust detected: $(cargo --version)"
    return 0
  fi
  log "Installing Rust toolchain via rustup ..."
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
  sh /tmp/rustup.sh -y --profile minimal
  rm -f /tmp/rustup.sh
  # shellcheck disable=SC1090
  . "$HOME/.cargo/env" 2>/dev/null || true
}

setup_rust_project() {
  if ! is_rust; then return 0; fi
  install_rust
  cargo fetch || true
  mkdir -p .bin
  cat > .bin/start-rust.sh <<'EOS'
#!/usr/bin/env bash
set -e
if [ -f "src/main.rs" ]; then
  exec cargo run
fi
echo "No Rust entrypoint found." >&2; exit 1
EOS
  chmod +x .bin/start-rust.sh
}

# .NET (best-effort notice)
setup_dotnet_project() {
  if ! is_dotnet; then return 0; fi
  if command_exists dotnet; then
    log ".NET SDK detected: $(dotnet --version)"
    dotnet restore || true
  else
    warn ".NET project detected but .NET SDK is not installed. Install the SDK in your base image for full setup."
  fi
}

# ------------- Main -------------
main() {
  log "Starting universal environment setup for project at $PROJECT_DIR"
  install_base_system
  ensure_app_user
  setup_directories
  ensure_env_file
  write_profile_env

  # Autodetect and set up stacks
  if is_node; then
    log "Node.js project detected."
    setup_node_project
  fi
  if is_python; then
    log "Python project detected."
    setup_python_project
  fi
  if is_java; then
    log "Java project detected."
    setup_java_project
  fi
  if is_ruby; then
    log "Ruby project detected."
    setup_ruby_project
  fi
  if is_go; then
    log "Go project detected."
    setup_go_project
  fi
  if is_php; then
    log "PHP project detected."
    setup_php_project
  fi
  if is_rust; then
    log "Rust project detected."
    setup_rust_project
  fi
  if is_dotnet; then
    log ".NET project detected."
    setup_dotnet_project
  fi

  # Permissions finalization (best-effort)
  if id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER":"$APP_GROUP" "$PROJECT_DIR" 2>/dev/null || true
  fi

  log "Environment setup completed successfully."
  log "Notes:"
  log "- Environment variables exported via $PROFILE_FILE"
  log "- Default start helpers placed in $PROJECT_DIR/.bin (if applicable)"
  log "- To use environment: source $PROFILE_FILE (usually auto-loaded in login shells)"
}

main "$@"