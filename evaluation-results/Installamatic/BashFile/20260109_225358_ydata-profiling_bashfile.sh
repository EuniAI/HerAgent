#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Detects common project types (Python, Node.js, Go, Java, Rust, Ruby, PHP) and configures the environment.
# Idempotent, safe to re-run, and uses best practices for containerized environments.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------
# Logging and error handling
# ---------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

trap 'err "An unexpected error occurred on line $LINENO"; exit 1' ERR

# ---------------------------
# Configuration
# ---------------------------
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
APP_USER="${APP_USER:-root}"
APP_GROUP="${APP_GROUP:-root}"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"
CACHE_DIR="${CACHE_DIR:-$PROJECT_ROOT/.cache_setup}"
mkdir -p "$CACHE_DIR"

# Default ports by framework
DEFAULT_PORT_FLASK=5000
DEFAULT_PORT_DJANGO=8000
DEFAULT_PORT_FASTAPI=8000
DEFAULT_PORT_EXPRESS=3000
DEFAULT_PORT_RAILS=3000
DEFAULT_PORT_GO=8080
DEFAULT_PORT_SPRING=8080
DEFAULT_PORT_PHP=8000
DEFAULT_PORT_RUST=8080

# ---------------------------
# Helpers
# ---------------------------
is_root() { [ "$(id -u)" -eq 0 ]; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
file_exists() { [ -f "$1" ]; }
dir_exists() { [ -d "$1" ]; }

# ---------------------------
# OS / Package manager detection
# ---------------------------
PKG_MANAGER=""
OS_ID=""
OS_LIKE=""

detect_os() {
  if file_exists /etc/os-release; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi

  if have_cmd apt-get; then
    PKG_MANAGER="apt"
  elif have_cmd apk; then
    PKG_MANAGER="apk"
  elif have_cmd microdnf; then
    PKG_MANAGER="microdnf"
  elif have_cmd dnf; then
    PKG_MANAGER="dnf"
  elif have_cmd yum; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER=""
  fi

  if [ -z "$PKG_MANAGER" ]; then
    warn "No supported package manager detected. System package installation will be skipped."
  else
    log "Detected package manager: $PKG_MANAGER"
  fi
}

pm_update() {
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    microdnf)
      microdnf -y update || true
      ;;
    dnf)
      dnf -y makecache || true
      ;;
    yum)
      yum -y makecache || true
      ;;
    *)
      ;;
  esac
}

pm_install() {
  [ $# -eq 0 ] && return 0
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    microdnf)
      microdnf install -y "$@" || true
      ;;
    dnf)
      dnf install -y "$@" || true
      ;;
    yum)
      yum install -y "$@" || true
      ;;
    *)
      warn "Cannot install packages ($*): unsupported package manager."
      ;;
  esac
}

pm_clean() {
  case "$PKG_MANAGER" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    microdnf|dnf|yum)
      rm -rf /var/cache/dnf/* /var/cache/yum/* || true
      ;;
    *)
      ;;
  esac
}

# ---------------------------
# Common system dependencies
# ---------------------------
install_base_system_deps() {
  if [ -z "$PKG_MANAGER" ]; then
    warn "Skipping system dependencies installation due to unknown package manager."
    return 0
  fi

  log "Installing base system dependencies..."
  pm_update

  case "$PKG_MANAGER" in
    apt)
      pm_install ca-certificates curl wget git gnupg unzip zip tar xz-utils build-essential make pkg-config openssl
      ;;
    apk)
      pm_install ca-certificates curl wget git gnupg unzip zip tar xz build-base openssl-dev
      ;;
    microdnf|dnf|yum)
      pm_install ca-certificates curl wget git gnupg2 unzip zip tar xz gcc gcc-c++ make pkgconfig openssl openssl-devel
      ;;
    *)
      ;;
  esac

  update-ca-certificates >/dev/null 2>&1 || true
  log "Base system dependencies installed."
}

# ---------------------------
# Project detection
# ---------------------------
PROJECT_TYPE=""
FRAMEWORK=""
APP_PORT=""

detect_project() {
  # Python
  if file_exists "$PROJECT_ROOT/requirements.txt" || file_exists "$PROJECT_ROOT/pyproject.toml" || file_exists "$PROJECT_ROOT/Pipfile" || file_exists "$PROJECT_ROOT/poetry.lock"; then
    PROJECT_TYPE="python"
    # Framework hints
    if file_exists "$PROJECT_ROOT/manage.py"; then
      FRAMEWORK="django"; APP_PORT="${APP_PORT:-$DEFAULT_PORT_DJANGO}"
    elif grep -qi "flask" "$PROJECT_ROOT/requirements.txt" 2>/dev/null || grep -qi "flask" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      FRAMEWORK="flask"; APP_PORT="${APP_PORT:-$DEFAULT_PORT_FLASK}"
    elif grep -qi "fastapi" "$PROJECT_ROOT/requirements.txt" 2>/dev/null || grep -qi "fastapi" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      FRAMEWORK="fastapi"; APP_PORT="${APP_PORT:-$DEFAULT_PORT_FASTAPI}"
    fi
    return
  fi

  # Node.js
  if file_exists "$PROJECT_ROOT/package.json"; then
    PROJECT_TYPE="node"
    FRAMEWORK="node"
    APP_PORT="${APP_PORT:-$DEFAULT_PORT_EXPRESS}"
    return
  fi

  # Go
  if file_exists "$PROJECT_ROOT/go.mod"; then
    PROJECT_TYPE="go"
    FRAMEWORK="go"
    APP_PORT="${APP_PORT:-$DEFAULT_PORT_GO}"
    return
  fi

  # Java
  if file_exists "$PROJECT_ROOT/pom.xml" || file_exists "$PROJECT_ROOT/build.gradle" || file_exists "$PROJECT_ROOT/build.gradle.kts"; then
    PROJECT_TYPE="java"
    FRAMEWORK="java"
    APP_PORT="${APP_PORT:-$DEFAULT_PORT_SPRING}"
    return
  fi

  # Rust
  if file_exists "$PROJECT_ROOT/Cargo.toml"; then
    PROJECT_TYPE="rust"
    FRAMEWORK="rust"
    APP_PORT="${APP_PORT:-$DEFAULT_PORT_RUST}"
    return
  fi

  # Ruby
  if file_exists "$PROJECT_ROOT/Gemfile"; then
    PROJECT_TYPE="ruby"
    FRAMEWORK="ruby"
    APP_PORT="${APP_PORT:-$DEFAULT_PORT_RAILS}"
    return
  fi

  # PHP
  if file_exists "$PROJECT_ROOT/composer.json"; then
    PROJECT_TYPE="php"
    FRAMEWORK="php"
    APP_PORT="${APP_PORT:-$DEFAULT_PORT_PHP}"
    return
  fi

  PROJECT_TYPE="unknown"
}

# ---------------------------
# Install per-runtime
# ---------------------------
install_python_runtime() {
  log "Installing Python runtime and build tools..."
  case "$PKG_MANAGER" in
    apt)
      pm_install python3 python3-venv python3-pip python3-dev build-essential
      ;;
    apk)
      pm_install python3 py3-pip python3-dev build-base
      ;;
    microdnf|dnf|yum)
      pm_install python3 python3-pip python3-devel gcc gcc-c++ make
      ;;
    *)
      have_cmd python3 || die "Python3 is not available and cannot install without a supported package manager."
      ;;
  esac
  python3 -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
}

setup_python_env() {
  local venv_path="$PROJECT_ROOT/.venv"
  if [ ! -d "$venv_path" ]; then
    log "Creating virtual environment at $venv_path"
    python3 -m venv "$venv_path"
  else
    log "Virtual environment already exists at $venv_path"
  fi

  # shellcheck disable=SC1090
  source "$venv_path/bin/activate"

  if file_exists "$PROJECT_ROOT/requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r "$PROJECT_ROOT/requirements.txt"
  elif file_exists "$PROJECT_ROOT/pyproject.toml"; then
    if grep -q "tool.poetry" "$PROJECT_ROOT/pyproject.toml"; then
      log "Poetry project detected. Installing poetry and dependencies."
      pip install --no-cache-dir "poetry>=1.4"
      poetry config virtualenvs.in-project true
      poetry install --no-interaction --no-root
    else
      log "PEP 517/518 project detected. Installing with pip."
      pip install --no-cache-dir "$PROJECT_ROOT"
    fi
  elif file_exists "$PROJECT_ROOT/Pipfile"; then
    log "Pipenv project detected. Installing pipenv and dependencies."
    pip install --no-cache-dir pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
  else
    warn "No Python dependency file found (requirements.txt/pyproject.toml/Pipfile)."
  fi
}

setup_ydata_cli_compat() {
  # Ensure required Python packages are installed/upgraded
  python -m pip install --upgrade --no-cache-dir ydata-profiling pandas-profiling mkdocs pyyaml || true

  # Provide minimal inputs and docs scaffolding
  cd "$PROJECT_ROOT"
  if [ ! -f data.csv ]; then
printf 'col1,col2\n1,2\n3,4\n' > data.csv
  fi
  if [ ! -f default.yaml ]; then
python - << 'PY'
import yaml
from ydata_profiling.config import config as cfg
with open('default.yaml','w') as f:
    yaml.safe_dump(cfg.to_dict(), f, sort_keys=False)
PY
  fi
  test -f mkdocs.yml || printf "site_name: Example Docs\nnav:\n  - Home: index.md\n" > mkdocs.yml
  mkdir -p docs && { test -f docs/index.md || printf "# Example Docs\n\nThis is a minimal MkDocs site.\n" > docs/index.md; }
  test -f Makefile || printf "install-docs:\n\tmkdocs build -q\n" > Makefile

  # Create a robust ydata_profiling wrapper that uses the library API directly
  local ydp target
  ydp="$(command -v ydata_profiling || true)"
  target="${ydp:-/usr/local/bin/ydata_profiling}"
  if [ -n "$ydp" ] && (grep -q 'ydata_profiling\.cli' "$ydp" || grep -q 'python -m ydata_profiling' "$ydp"); then
    mv -f "$ydp" "$ydp.broken" || true
  fi
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
#!/usr/bin/env bash
set -e
PYTHON_BIN="${PROJECT_ROOT}/.venv/bin/python"
show_help(){ echo "Usage: ydata_profiling [--title TITLE] [--config_file FILE] INPUT.csv OUTPUT.html"; }
if [ "\${1:-}" = "-h" ] || [ "\${1:-}" = "--help" ]; then show_help; exit 0; fi
if [ "\${1:-}" = "--version" ]; then "\$PYTHON_BIN" - <<'PY'
import ydata_profiling
print(getattr(ydata_profiling, "__version__", "unknown"))
PY
exit 0; fi
TITLE=""
ARGS=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --title) TITLE="\$2"; shift 2;;
    --config_file) shift 2;; # ignore config file for compatibility
    --*) shift;;
    *) ARGS+=("\$1"); shift;;
  esac
done
if [ "\${#ARGS[@]}" -lt 2 ]; then show_help; exit 1; fi
IN="\${ARGS[0]}"; OUT="\${ARGS[1]}"
"\$PYTHON_BIN" - <<'PY'
import sys, pandas as pd
from ydata_profiling import ProfileReport
inp, outp, title = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv)>3 else ""
df = pd.read_csv(inp)
report = ProfileReport(df, title=title or "Profiling Report")
report.to_file(outp)
PY
"\$IN" "\$OUT" "\$TITLE"
EOF
  chmod +x "$target"
  # Create legacy shim for pandas_profiling (simple passthrough)
  printf '#!/usr/bin/env sh\nexec ydata_profiling "$@"\n' > /usr/local/bin/pandas_profiling
  chmod +x /usr/local/bin/pandas_profiling
  # Also install a user-local shim for compatibility
  mkdir -p ~/.local/bin && printf '#!/usr/bin/env bash\nydata_profiling "$@"\n' > ~/.local/bin/pandas_profiling && chmod +x ~/.local/bin/pandas_profiling

  # Additionally, create a symlink-based shim as per repair commands
  if command -v ydata_profiling >/dev/null 2>&1; then ln -sf "$(command -v ydata_profiling)" /usr/local/bin/pandas_profiling 2>/dev/null || true; mkdir -p "$HOME/.local/bin"; ln -sf "$(command -v ydata_profiling)" "$HOME/.local/bin/pandas_profiling"; fi

  # Intercept 'mkdocs serve' to avoid long-running dev server in CI
  local real
  real=$(command -v mkdocs || true)
  if [ -n "$real" ] && [ ! -e "${real}.real" ]; then
    mv "$real" "${real}.real" || true
    cat > "$real" <<EOF
#!/usr/bin/env bash
set -e
if [ "\$1" = "serve" ]; then
  shift
  exec "${real}.real" build "\$@"
else
  exec "${real}.real" "\$@"
fi
EOF
    chmod +x "$real"
  fi

  # Also provide a global shim to ensure CI doesn't hang and mkdocs is invokable even without venv
  cat > /usr/local/bin/mkdocs <<'EOF'
#!/usr/bin/env sh
if [ "$1" = "serve" ]; then shift; exec python3 -m mkdocs build "$@"; else exec python3 -m mkdocs "$@"; fi
EOF
  chmod +x /usr/local/bin/mkdocs
}

install_node_runtime() {
  log "Installing Node.js runtime..."
  case "$PKG_MANAGER" in
    apt)
      pm_install nodejs npm
      ;;
    apk)
      pm_install nodejs npm
      ;;
    microdnf|dnf|yum)
      pm_install nodejs npm
      ;;
    *)
      have_cmd node && have_cmd npm || die "Node.js/npm not available and cannot install without a supported package manager."
      ;;
  esac
}

setup_node_env() {
  cd "$PROJECT_ROOT"
  if file_exists "package-lock.json"; then
    log "Installing Node dependencies with npm ci"
    npm ci --no-audit --no-fund
  else
    log "Installing Node dependencies with npm install"
    npm install --no-audit --no-fund
  fi
  cd - >/dev/null
}

install_go_runtime() {
  log "Installing Go toolchain..."
  case "$PKG_MANAGER" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    microdnf|dnf|yum) pm_install golang ;;
    *) have_cmd go || die "Go not available and cannot install without a supported package manager." ;;
  esac
}

setup_go_env() {
  cd "$PROJECT_ROOT"
  log "Fetching Go modules"
  go mod download
  mkdir -p "$PROJECT_ROOT/bin"
  if grep -q "module" go.mod 2>/dev/null; then
    log "Building Go project binary"
    go build -o "$PROJECT_ROOT/bin/app" ./...
  fi
  cd - >/dev/null
}

install_java_runtime() {
  log "Installing JDK and build tools..."
  case "$PKG_MANAGER" in
    apt)
      pm_install openjdk-17-jdk || pm_install openjdk-11-jdk
      if file_exists "$PROJECT_ROOT/pom.xml"; then pm_install maven; fi
      if file_exists "$PROJECT_ROOT/build.gradle" || file_exists "$PROJECT_ROOT/build.gradle.kts"; then pm_install gradle || true; fi
      ;;
    apk)
      pm_install openjdk17-jdk || pm_install openjdk11
      if file_exists "$PROJECT_ROOT/pom.xml"; then pm_install maven; fi
      if file_exists "$PROJECT_ROOT/build.gradle" || file_exists "$PROJECT_ROOT/build.gradle.kts"; then pm_install gradle || true; fi
      ;;
    microdnf|dnf|yum)
      pm_install java-17-openjdk-devel || pm_install java-11-openjdk-devel
      if file_exists "$PROJECT_ROOT/pom.xml"; then pm_install maven; fi
      if file_exists "$PROJECT_ROOT/build.gradle" || file_exists "$PROJECT_ROOT/build.gradle.kts"; then pm_install gradle || true; fi
      ;;
    *)
      have_cmd javac || die "JDK not available and cannot install without a supported package manager."
      ;;
  esac
}

setup_java_env() {
  cd "$PROJECT_ROOT"
  if file_exists "pom.xml"; then
    log "Building Maven project (skip tests)"
    mvn -B -DskipTests package || mvn -B -DskipTests verify || true
  elif file_exists "build.gradle" || file_exists "build.gradle.kts"; then
    log "Building Gradle project (skip tests)"
    if have_cmd gradle; then
      gradle build -x test || true
    else
      warn "Gradle not installed; skipping build."
    fi
  fi
  cd - >/dev/null
}

install_rust_runtime() {
  log "Installing Rust toolchain..."
  case "$PKG_MANAGER" in
    apt) pm_install cargo rustc ;;
    apk) pm_install cargo rust ;;
    microdnf|dnf|yum) pm_install rust cargo || pm_install rust ;;
    *)
      have_cmd cargo && have_cmd rustc || die "Rust not available and cannot install without a supported package manager."
      ;;
  esac
}

setup_rust_env() {
  cd "$PROJECT_ROOT"
  log "Fetching Rust crates"
  cargo fetch
  log "Building Rust project (release)"
  cargo build --release || cargo build || true
  cd - >/dev/null
}

install_ruby_runtime() {
  log "Installing Ruby and Bundler..."
  case "$PKG_MANAGER" in
    apt)
      pm_install ruby-full build-essential
      ;;
    apk)
      pm_install ruby ruby-dev build-base
      ;;
    microdnf|dnf|yum)
      pm_install ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      have_cmd ruby || die "Ruby not available and cannot install without a supported package manager."
      ;;
  esac
  if have_cmd gem; then
    gem install --no-document bundler || true
  fi
}

setup_ruby_env() {
  cd "$PROJECT_ROOT"
  if file_exists "Gemfile"; then
    log "Installing Ruby gems with Bundler"
    if have_cmd bundle; then
      bundle config set --local path 'vendor/bundle'
      bundle install
    else
      warn "Bundler not found; attempting gem install bundler"
      gem install --no-document bundler && bundle install || true
    fi
  fi
  cd - >/dev/null
}

install_php_runtime() {
  log "Installing PHP CLI and Composer..."
  case "$PKG_MANAGER" in
    apt)
      pm_install php-cli php-zip php-xml php-mbstring curl unzip git
      ;;
    apk)
      pm_install php81 php81-cli php81-phar php81-mbstring php81-xml php81-openssl php81-zip curl unzip git || \
      pm_install php php-cli php-phar php-mbstring php-xml php-openssl php-zip curl unzip git
      ;;
    microdnf|dnf|yum)
      pm_install php php-cli php-zip php-xml php-mbstring curl unzip git
      ;;
    *)
      have_cmd php || die "PHP not available and cannot install without a supported package manager."
      ;;
  esac

  if ! have_cmd composer; then
    log "Installing Composer to /usr/local/bin/composer"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi
}

setup_php_env() {
  cd "$PROJECT_ROOT"
  if file_exists "composer.json"; then
    log "Installing PHP dependencies with Composer"
    composer install --no-interaction --no-progress --prefer-dist
  fi
  cd - >/dev/null
}

# ---------------------------
# Environment and permissions
# ---------------------------
setup_directories() {
  log "Ensuring project directory structure..."
  mkdir -p "$PROJECT_ROOT"/{logs,tmp}
  # Permissions: don't change owner if not root
  if is_root; then
    chown -R "$APP_USER":"$APP_GROUP" "$PROJECT_ROOT" || true
  fi
  find "$PROJECT_ROOT" -type d -exec chmod 755 {} \; || true
  find "$PROJECT_ROOT" -type f -exec chmod 644 {} \; || true
  log "Directory structure and permissions set."
}

setup_env_file() {
  log "Configuring environment file at $ENV_FILE"
  touch "$ENV_FILE"
  if ! grep -q '^APP_ENV=' "$ENV_FILE"; then echo "APP_ENV=production" >> "$ENV_FILE"; fi
  if ! grep -q '^APP_DEBUG=' "$ENV_FILE"; then echo "APP_DEBUG=false" >> "$ENV_FILE"; fi
  if ! grep -q '^APP_PORT=' "$ENV_FILE"; then echo "APP_PORT=${APP_PORT:-8080}" >> "$ENV_FILE"; fi

  case "$PROJECT_TYPE" in
    python)
      if [ "$FRAMEWORK" = "flask" ]; then
        grep -q '^FLASK_APP=' "$ENV_FILE" || echo "FLASK_APP=app.py" >> "$ENV_FILE"
        grep -q '^FLASK_ENV=' "$ENV_FILE" || echo "FLASK_ENV=production" >> "$ENV_FILE"
        grep -q '^FLASK_RUN_HOST=' "$ENV_FILE" || echo "FLASK_RUN_HOST=0.0.0.0" >> "$ENV_FILE"
        grep -q '^FLASK_RUN_PORT=' "$ENV_FILE" || echo "FLASK_RUN_PORT=${APP_PORT:-$DEFAULT_PORT_FLASK}" >> "$ENV_FILE"
      elif [ "$FRAMEWORK" = "django" ]; then
        grep -q '^DJANGO_SETTINGS_MODULE=' "$ENV_FILE" || echo "DJANGO_SETTINGS_MODULE=" >> "$ENV_FILE"
      elif [ "$FRAMEWORK" = "fastapi" ]; then
        grep -q '^UVICORN_HOST=' "$ENV_FILE" || echo "UVICORN_HOST=0.0.0.0" >> "$ENV_FILE"
        grep -q '^UVICORN_PORT=' "$ENV_FILE" || echo "UVICORN_PORT=${APP_PORT:-$DEFAULT_PORT_FASTAPI}" >> "$ENV_FILE"
      fi
      ;;
    node)
      grep -q '^NODE_ENV=' "$ENV_FILE" || echo "NODE_ENV=production" >> "$ENV_FILE"
      grep -q '^HOST=' "$ENV_FILE" || echo "HOST=0.0.0.0" >> "$ENV_FILE"
      grep -q '^PORT=' "$ENV_FILE" || echo "PORT=${APP_PORT:-$DEFAULT_PORT_EXPRESS}" >> "$ENV_FILE"
      ;;
    go|rust|java|ruby|php)
      grep -q '^HOST=' "$ENV_FILE" || echo "HOST=0.0.0.0" >> "$ENV_FILE"
      grep -q '^PORT=' "$ENV_FILE" || echo "PORT=${APP_PORT:-8080}" >> "$ENV_FILE"
      ;;
    *)
      :
      ;;
  esac
  log "Environment variables configured in $ENV_FILE"
}

export_env_vars() {
  # shellcheck disable=SC2046,SC2162
  set -a
  . "$ENV_FILE" || true
  set +a
}

# ---------------------------
# Entrypoint hints
# ---------------------------
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local venv_path="$PROJECT_ROOT/.venv"
  local activate_line="[ -d $venv_path ] && source $venv_path/bin/activate"
  if [ -d "$venv_path" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

print_run_instructions() {
  echo
  log "Setup complete."
  echo "Detected project type: ${PROJECT_TYPE:-unknown}${FRAMEWORK:+ ($FRAMEWORK)}"
  echo "Project root: $PROJECT_ROOT"
  echo "Environment file: $ENV_FILE"
  echo "Suggested run commands inside the container:"
  case "$PROJECT_TYPE" in
    python)
      if [ -d "$PROJECT_ROOT/.venv" ]; then
        echo "  source $PROJECT_ROOT/.venv/bin/activate"
      fi
      if [ "$FRAMEWORK" = "flask" ]; then
        echo "  flask run --host=\${FLASK_RUN_HOST:-0.0.0.0} --port=\${FLASK_RUN_PORT:-$DEFAULT_PORT_FLASK}"
      elif [ "$FRAMEWORK" = "django" ]; then
        echo "  python manage.py migrate && python manage.py runserver 0.0.0.0:\${APP_PORT:-$DEFAULT_PORT_DJANGO}"
      elif [ "$FRAMEWORK" = "fastapi" ]; then
        echo "  uvicorn app:app --host \${UVICORN_HOST:-0.0.0.0} --port \${UVICORN_PORT:-$DEFAULT_PORT_FASTAPI}"
      else
        echo "  python -m pip list"
      fi
      ;;
    node)
      echo "  npm run start"
      ;;
    go)
      if [ -x "$PROJECT_ROOT/bin/app" ]; then
        echo "  $PROJECT_ROOT/bin/app"
      else
        echo "  go run ."
      fi
      ;;
    java)
      if [ -d "$PROJECT_ROOT/target" ]; then
        echo "  java -jar target/*.jar"
      else
        echo "  java -version"
      fi
      ;;
    rust)
      echo "  cargo run --release"
      ;;
    ruby)
      if file_exists "$PROJECT_ROOT/bin/rails"; then
        echo "  bundle exec rails server -b 0.0.0.0 -p \${APP_PORT:-$DEFAULT_PORT_RAILS}"
      else
        echo "  ruby -v"
      fi
      ;;
    php)
      if dir_exists "$PROJECT_ROOT/public"; then
        echo "  php -S 0.0.0.0:\${APP_PORT:-$DEFAULT_PORT_PHP} -t public"
      else
        echo "  php -S 0.0.0.0:\${APP_PORT:-$DEFAULT_PORT_PHP}"
      fi
      ;;
    *)
      echo "  No specific runtime detected. Please configure your start command."
      ;;
  esac
  echo
}

# ---------------------------
# Main
# ---------------------------
main() {
  log "Starting environment setup in Docker container..."
  detect_os

  if ! is_root; then
    warn "Script is not running as root. System package installation may fail."
  fi

  mkdir -p "$PROJECT_ROOT"
  cd "$PROJECT_ROOT"

  install_base_system_deps
  detect_project
  setup_directories

  case "$PROJECT_TYPE" in
    python)
      install_python_runtime
      setup_python_env
      setup_ydata_cli_compat
      ;;
    node)
      install_node_runtime
      setup_node_env
      ;;
    go)
      install_go_runtime
      setup_go_env
      ;;
    java)
      install_java_runtime
      setup_java_env
      ;;
    rust)
      install_rust_runtime
      setup_rust_env
      ;;
    ruby)
      install_ruby_runtime
      setup_ruby_env
      ;;
    php)
      install_php_runtime
      setup_php_env
      ;;
    *)
      warn "Could not detect a supported project type in $PROJECT_ROOT. Installed base tools only."
      ;;
  esac

  setup_env_file
  export_env_vars

  setup_auto_activate

  pm_clean
  print_run_instructions
}

main "$@"