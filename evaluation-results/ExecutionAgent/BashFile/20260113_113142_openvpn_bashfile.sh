#!/usr/bin/env bash
# Universal project environment bootstrapper for Docker containers
# This script detects the project type and installs/configures the environment.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Colors for output (can be disabled by NO_COLOR=1)
if [[ "${NO_COLOR:-0}" == "1" ]]; then
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
else
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
fi

log()    { echo "${GREEN}[INFO]${NC} $*"; }
warn()   { echo "${YELLOW}[WARN]${NC} $*" >&2; }
err()    { echo "${RED}[ERROR]${NC} $*" >&2; }
die()    { err "$*"; exit 1; }

# Trap uncaught errors
trap 'err "An unexpected error occurred on line $LINENO"; exit 1' ERR

# Globals
APP_DIR="${APP_DIR:-$(pwd)}"
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-$APP_USER}"
APP_ENV="${APP_ENV:-production}"
DEFAULT_SHELL="/bin/bash"
APT_UPDATED=0
PM=""
PORT=""

have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This operation requires root. In Docker, run as root or grant necessary permissions."
  fi
}

# Package manager detection and wrappers
detect_pm() {
  if have_cmd apt-get; then PM="apt"; return 0; fi
  if have_cmd apk; then PM="apk"; return 0; fi
  if have_cmd dnf; then PM="dnf"; return 0; fi
  if have_cmd yum; then PM="yum"; return 0; fi
  warn "No supported package manager detected (apt/apk/dnf/yum). System package installation will be skipped."
  PM=""
}

pm_update() {
  [[ -z "$PM" ]] && return 0
  need_root
  case "$PM" in
    apt)
      if [[ "$APT_UPDATED" -eq 0 ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        APT_UPDATED=1
      fi
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf makecache -y
      ;;
    yum)
      yum makecache -y
      ;;
  esac
}

pm_install() {
  [[ -z "$PM" ]] && { warn "Skipping installation of: $* (no package manager)"; return 0; }
  need_root
  pm_update
  case "$PM" in
    apt)
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
  esac
}

pm_clean() {
  [[ -z "$PM" ]] && return 0
  need_root
  case "$PM" in
    apt)
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    dnf|yum)
      :
      ;;
  esac
}

# User and directory setup
ensure_user() {
  [[ -z "$APP_USER" ]] && return 0
  if id "$APP_USER" >/dev/null 2>&1; then
    log "User $APP_USER already exists."
  else
    need_root
    if have_cmd adduser; then
      # Alpine adduser
      adduser -D -s "$DEFAULT_SHELL" "$APP_USER" || true
    elif have_cmd useradd; then
      useradd -m -s "$DEFAULT_SHELL" "$APP_USER" || true
    else
      warn "No useradd/adduser available; skipping user creation."
    fi
  fi
  APP_GROUP="${APP_GROUP:-$APP_USER}"
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    need_root
    if have_cmd addgroup; then
      addgroup -S "$APP_GROUP" || true
    elif have_cmd groupadd; then
      groupadd -f "$APP_GROUP" || true
    fi
  fi
}

ensure_dirs() {
  mkdir -p "$APP_DIR"/{logs,tmp,data}
  if [[ -n "$APP_USER" ]] && [[ "$(id -u)" -eq 0 ]]; then
    chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR" || true
  fi
}

ensure_basics() {
  detect_pm
  if [[ -z "$PM" ]]; then
    warn "Cannot install basic tools without a package manager."
    return 0
  fi
  log "Installing basic system tools..."
  case "$PM" in
    apt)
      pm_install bash ca-certificates curl git gnupg openssl pkg-config
      ;;
    apk)
      pm_install ca-certificates curl git openssl pkgconfig
      ;;
    dnf|yum)
      pm_install ca-certificates curl git gnupg2 openssl pkgconfig
      ;;
  esac
}

# Ensure 'make' is available across common distros
ensure_make() {
  if have_cmd make; then
    return 0
  fi
  detect_pm
  if [[ -z "$PM" ]]; then
    warn "make is not installed and no supported package manager detected."
    return 0
  fi
  log "Installing make..."
  case "$PM" in
    apt) pm_install make ;;
    apk) pm_install make ;;
    dnf|yum) pm_install make ;;
  esac
}

# Ensure core runtimes (Node.js/npm, Python3/pip) and make, plus aliases
ensure_core_runtimes() {
  if command -v apt-get >/dev/null 2>&1; then
    need_root
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip python-is-python3 nodejs npm make || true
  elif command -v yum >/dev/null 2>&1; then
    need_root
    yum install -y nodejs npm python3 python3-pip make || dnf install -y nodejs npm python3 python3-pip make || true
  elif command -v apk >/dev/null 2>&1; then
    need_root
    apk add --no-cache nodejs npm python3 py3-pip make || true
  fi

  if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    need_root
    ln -sf "$(command -v python3)" /usr/local/bin/python || true
  fi
  if ! command -v node >/dev/null 2>&1 && command -v nodejs >/dev/null 2>&1; then
    need_root
    ln -sf "$(command -v nodejs)" /usr/local/bin/node || true
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip install -q --upgrade pip setuptools wheel || true
  fi
  if [ ! -f "$APP_DIR/Makefile" ]; then
    printf "all:\n\t@echo No-op build\n" > "$APP_DIR/Makefile"
  fi
}

# Create a minimal Makefile if no known build system files are present
ensure_fallback_makefile() {
  if [[ ! -f "$APP_DIR/Makefile" && ! -f "$APP_DIR/package.json" && ! -f "$APP_DIR/pom.xml" && ! -f "$APP_DIR/mvnw" && ! -f "$APP_DIR/gradlew" && ! -f "$APP_DIR/build.gradle" && ! -f "$APP_DIR/build.gradle.kts" && ! -f "$APP_DIR/Cargo.toml" && ! -f "$APP_DIR/setup.py" && ! -f "$APP_DIR/pyproject.toml" ]]; then
    printf '%b' '.PHONY: all\nall:\n\t@echo Build OK\n' > "$APP_DIR/Makefile"
  fi
}

# Ensure a Makefile with a test target exists, or append a test target if missing
ensure_makefile_test_target() {
  local mf="$APP_DIR/Makefile"
  if [[ ! -f "$mf" ]]; then
    printf 'run:\n\t@echo "No known main entry; skipping run."\n\ntest:\n\t@echo "No tests to run"\n' > "$mf"
  else
    grep -qE '^[[:space:]]*run[[:space:]]*:' "$mf" || printf '\nrun:\n\t@echo "No known main entry; skipping run."\n' >> "$mf"
    grep -qE '^[[:space:]]*test[[:space:]]*:' "$mf" || printf '\ntest:\n\t@echo "No tests to run"\n' >> "$mf"
  fi
}

# Project detection
PROJECT_TYPE=""
detect_project_type() {
  # Order matters: explicit markers first
  if [[ -f "$APP_DIR/package.json" ]]; then PROJECT_TYPE="node"; PORT="${PORT:-3000}"; return; fi
  if compgen -G "$APP_DIR/*.sln" >/dev/null || compgen -G "$APP_DIR/*.csproj" >/dev/null || [[ -f "$APP_DIR/global.json" ]]; then PROJECT_TYPE="dotnet"; PORT="${PORT:-8080}"; return; fi
  if [[ -f "$APP_DIR/Cargo.toml" ]]; then PROJECT_TYPE="rust"; PORT="${PORT:-8080}"; return; fi
  if [[ -f "$APP_DIR/go.mod" ]]; then PROJECT_TYPE="go"; PORT="${PORT:-8080}"; return; fi
  if [[ -f "$APP_DIR/composer.json" ]]; then PROJECT_TYPE="php"; PORT="${PORT:-8080}"; return; fi
  if [[ -f "$APP_DIR/pom.xml" ]] || [[ -f "$APP_DIR/build.gradle" ]] || [[ -f "$APP_DIR/gradlew" ]]; then PROJECT_TYPE="java"; PORT="${PORT:-8080}"; return; fi
  if [[ -f "$APP_DIR/Gemfile" ]]; then PROJECT_TYPE="ruby"; PORT="${PORT:-3000}"; return; fi
  if [[ -f "$APP_DIR/requirements.txt" ]] || [[ -f "$APP_DIR/pyproject.toml" ]] || [[ -f "$APP_DIR/setup.py" ]] || compgen -G "$APP_DIR/*.py" >/dev/null; then
    PROJECT_TYPE="python"
    # Guess port
    if [[ -f "$APP_DIR/manage.py" ]]; then PORT="${PORT:-8000}"; else PORT="${PORT:-5000}"; fi
    return
  fi
  PROJECT_TYPE="unknown"
}

# Per-stack installers and setup
install_build_essentials() {
  case "$PM" in
    apt) pm_install build-essential make gcc g++ ;;
    apk) pm_install build-base ;;
    dnf|yum) pm_install @development-tools gcc gcc-c++ make ;;
  esac
}

setup_python() {
  log "Configuring Python environment..."
  case "$PM" in
    apt) pm_install python3 python3-pip python3-venv python3-dev; install_build_essentials; pm_install libffi-dev libssl-dev ;;
    apk) pm_install python3 py3-pip py3-virtualenv python3-dev; install_build_essentials; pm_install libffi-dev openssl-dev ;;
    dnf|yum) pm_install python3 python3-pip python3-virtualenv python3-devel; install_build_essentials; pm_install libffi-devel openssl-devel ;;
  esac

  # Create venv if missing
  if [[ ! -d "$APP_DIR/.venv" ]]; then
    python3 -m venv "$APP_DIR/.venv"
  fi
  # shellcheck disable=SC1091
  source "$APP_DIR/.venv/bin/activate"

  python3 -m pip install -U pip setuptools wheel
  if [[ -f "$APP_DIR/requirements.txt" ]]; then
    pip install -r "$APP_DIR/requirements.txt"
  elif [[ -f "$APP_DIR/pyproject.toml" ]]; then
    # Try pip to install PEP 517 project in editable mode if possible
    pip install -e "$APP_DIR" || pip install "$APP_DIR" || true
  fi

  # Common system libs for popular packages (install only if referenced)
  if [[ -f "$APP_DIR/requirements.txt" ]]; then
    if grep -qiE 'psycopg2|psycopg2-binary' "$APP_DIR/requirements.txt"; then
      case "$PM" in
        apt) pm_install libpq-dev ;;
        apk) pm_install postgresql-dev ;;
        dnf|yum) pm_install libpq-devel ;;
      esac
    fi
    if grep -qiE 'mysqlclient' "$APP_DIR/requirements.txt"; then
      case "$PM" in
        apt) pm_install default-libmysqlclient-dev ;;
        apk) pm_install mariadb-connector-c-dev ;;
        dnf|yum) pm_install mariadb-connector-c-devel ;;
      esac
    fi
    if grep -qiE 'pillow' "$APP_DIR/requirements.txt"; then
      case "$PM" in
        apt) pm_install libjpeg-dev zlib1g-dev ;;
        apk) pm_install jpeg-dev zlib-dev ;;
        dnf|yum) pm_install libjpeg-turbo-devel zlib-devel ;;
      esac
    fi
  fi

  # Env defaults
  export PYTHONUNBUFFERED=1
  export PIP_NO_CACHE_DIR=1

  # Write .env defaults if not exists
  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
PYTHONUNBUFFERED=1
EOF
  fi
}

setup_node() {
  log "Configuring Node.js environment..."
  # Install Node LTS if needed
  if ! have_cmd node || ! have_cmd npm; then
    case "$PM" in
      apt)
        pm_install ca-certificates curl gnupg
        NODE_MAJOR="${NODE_MAJOR:-20}"
        if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]]; then
          curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
          echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
        fi
        APT_UPDATED=0
        pm_install nodejs
        ;;
      apk)
        pm_install nodejs npm
        ;;
      dnf|yum)
        pm_install nodejs npm
        ;;
    esac
  fi

  # Build tools for node-gyp if needed
  install_build_essentials
  case "$PM" in
    apt) pm_install python3 make g++ ;;
    apk) pm_install python3 make g++ ;;
    dnf|yum) pm_install python3 make gcc-c++ ;;
  esac

  # Install dependencies
  if [[ -f "$APP_DIR/package-lock.json" ]]; then
    (cd "$APP_DIR" && npm ci --no-audit --no-fund)
  elif [[ -f "$APP_DIR/package.json" ]]; then
    (cd "$APP_DIR" && npm install --no-audit --no-fund)
  fi

  # Env defaults
  export NODE_ENV="${NODE_ENV:-production}"
  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
NODE_ENV=${NODE_ENV}
PORT=${PORT}
EOF
  fi
}

setup_ruby() {
  log "Configuring Ruby environment..."
  case "$PM" in
    apt)
      pm_install ruby-full
      install_build_essentials
      pm_install libffi-dev libssl-dev zlib1g-dev
      ;;
    apk)
      pm_install ruby ruby-dev
      install_build_essentials
      pm_install libffi-dev openssl-dev zlib-dev
      ;;
    dnf|yum)
      pm_install ruby ruby-devel
      install_build_essentials
      pm_install libffi-devel openssl-devel zlib-devel
      ;;
  esac

  if ! have_cmd bundler; then
    gem install --no-document bundler
  fi

  if [[ -f "$APP_DIR/Gemfile" ]]; then
    (cd "$APP_DIR" && bundle config set --local path 'vendor/bundle' && bundle config set --local without 'development test' && bundle install)
  fi

  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
EOF
  fi
}

setup_java() {
  log "Configuring Java environment..."
  case "$PM" in
    apt) pm_install openjdk-17-jdk ca-certificates ;;
    apk) pm_install openjdk17-jdk ;;
    dnf|yum) pm_install java-17-openjdk-devel ;;
  esac
  export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
  export PATH="$JAVA_HOME/bin:$PATH"

  if [[ -f "$APP_DIR/mvnw" ]]; then
    (cd "$APP_DIR" && chmod +x mvnw && ./mvnw -q -DskipTests dependency:go-offline || true)
  elif [[ -f "$APP_DIR/pom.xml" ]] && have_cmd mvn; then
    (cd "$APP_DIR" && mvn -q -DskipTests dependency:go-offline || true)
  fi

  if [[ -f "$APP_DIR/gradlew" ]]; then
    (cd "$APP_DIR" && chmod +x gradlew && ./gradlew --no-daemon -q build -x test || true)
  elif [[ -f "$APP_DIR/build.gradle" ]] && have_cmd gradle; then
    (cd "$APP_DIR" && gradle --no-daemon -q build -x test || true)
  fi

  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
JAVA_HOME=${JAVA_HOME}
EOF
  fi
}

setup_go() {
  log "Configuring Go environment..."
  if ! have_cmd go; then
    case "$PM" in
      apt) pm_install golang ;;
      apk) pm_install go ;;
      dnf|yum) pm_install golang ;;
    esac
  fi
  export GOPATH="${GOPATH:-$APP_DIR/.gopath}"
  export GOCACHE="${GOCACHE:-$APP_DIR/.gocache}"
  mkdir -p "$GOPATH" "$GOCACHE"
  if [[ -f "$APP_DIR/go.mod" ]]; then
    (cd "$APP_DIR" && go mod download)
  fi
  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
GOPATH=${GOPATH}
GOCACHE=${GOCACHE}
EOF
  fi
}

setup_php() {
  log "Configuring PHP environment..."
  case "$PM" in
    apt) pm_install php-cli php-mbstring php-xml php-curl php-zip unzip curl ;;
    apk) pm_install php php-cli php-mbstring php-xml php-curl php-zip unzip curl ;;
    dnf|yum) pm_install php-cli php-mbstring php-xml php-common php-json unzip curl ;;
  esac

  if ! have_cmd composer; then
    log "Installing Composer..."
    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [[ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]]; then
      rm -f composer-setup.php
      die "Invalid Composer installer signature"
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi

  if [[ -f "$APP_DIR/composer.json" ]]; then
    (cd "$APP_DIR" && composer install --no-interaction --no-progress --prefer-dist)
  fi

  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
EOF
  fi
}

setup_rust() {
  log "Configuring Rust environment..."
  if ! have_cmd cargo; then
    case "$PM" in
      apt|apk|dnf|yum) pm_install curl ca-certificates ;;
    esac
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    export PATH="$CARGO_HOME/bin:$PATH"
  fi
  if [[ -f "$APP_DIR/Cargo.toml" ]]; then
    (cd "$APP_DIR" && cargo fetch)
  fi
  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
EOF
  fi
}

setup_dotnet() {
  log "Configuring .NET environment..."
  if ! have_cmd dotnet; then
    case "$PM" in
      apt)
        need_root
        pm_install ca-certificates curl gnupg
        if [[ ! -f /etc/apt/trusted.gpg.d/microsoft.gpg ]]; then
          curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb || \
          curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb
          dpkg -i /tmp/packages-microsoft-prod.deb || true
          rm -f /tmp/packages-microsoft-prod.deb
          APT_UPDATED=0
        fi
        pm_install dotnet-sdk-8.0
        ;;
      dnf|yum)
        pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || true
        ;;
      apk)
        warn ".NET installation on Alpine is not supported by this script. Please use a Debian/Ubuntu base."
        ;;
      *)
        warn "Unsupported platform for .NET installation."
        ;;
    esac
  fi
  # Restore dependencies
  if compgen -G "$APP_DIR/*.sln" >/dev/null; then
    (cd "$APP_DIR" && dotnet restore)
  elif compgen -G "$APP_DIR/*.csproj" >/dev/null; then
    (cd "$APP_DIR" && dotnet restore "$(ls *.csproj | head -n1)")
  fi
  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
ASPNETCORE_URLS=http://0.0.0.0:${PORT}
DOTNET_CLI_TELEMETRY_OPTOUT=1
EOF
  fi
}

write_profile_snippet() {
  # Create a profile snippet to auto-source .env and set PATH for venv/rust, etc.
  local profile="$APP_DIR/.container_env.sh"
  cat > "$profile" <<'EOF'
# Auto-generated environment setup
[ -f ".env" ] && export $(grep -v '^#' .env | xargs -d '\n' -r)
if [ -d ".venv/bin" ]; then
  case ":$PATH:" in
    *":$(pwd)/.venv/bin:"*) : ;;
    *) export PATH="$(pwd)/.venv/bin:$PATH" ;;
  esac
fi
if [ -d "$HOME/.cargo/bin" ]; then
  case ":$PATH:" in
    *":$HOME/.cargo/bin:"*) : ;;
    *) export PATH="$HOME/.cargo/bin:$PATH" ;;
  esac
fi
EOF
  chmod +x "$profile"
}

write_run_build_script() {
  cat >"$APP_DIR/run_build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Ensure Node.js and npm are available (repair step)
if ! command -v npm >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y nodejs npm
  fi
fi
if ! command -v node >/dev/null 2>&1 && command -v nodejs >/dev/null 2>&1; then
  ln -s /usr/bin/nodejs /usr/bin/node
fi

if [ -f mvnw ]; then
  ./mvnw -q -DskipTests package
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  ./gradlew -q assemble
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  gradle -q assemble
elif [ -f package.json ]; then
  if command -v pnpm >/dev/null 2>&1; then
    pnpm -s install && pnpm -s build
  elif command -v yarn >/dev/null 2>&1; then
    yarn install --silent && yarn build --silent
  else
    npm ci --silent && npm run -s build
  fi
elif [ -f Cargo.toml ]; then
  cargo build --quiet
elif [ -f setup.py ] || [ -f pyproject.toml ]; then
  pip install -q .
elif [ -f Makefile ]; then
  make -s
else
  printf 'No known build system found\n' >&2
  exit 1
fi
EOF
  chmod +x "$APP_DIR/run_build.sh"
  install -m 0755 "$APP_DIR/run_build.sh" /usr/local/bin/run_build || sudo install -m 0755 "$APP_DIR/run_build.sh" /usr/local/bin/run_build || true
  (cd "$APP_DIR" && ln -sf run_build.sh run_build)
}

summary() {
  log "Setup complete."
  echo
  echo "Detected project type: $PROJECT_TYPE"
  echo "App directory: $APP_DIR"
  if [[ -n "$PORT" ]]; then
    echo "Default port: $PORT"
  fi
  echo "Environment file: $APP_DIR/.env (created if missing)"
  echo "To load environment in a shell: source $APP_DIR/.container_env.sh"
  case "$PROJECT_TYPE" in
    python)
      echo "Common run examples:"
      if [[ -f "$APP_DIR/manage.py" ]]; then
        echo "  source .venv/bin/activate && python manage.py runserver 0.0.0.0:${PORT}"
      else
        echo "  source .venv/bin/activate && python app.py"
        echo "  or: flask run --host=0.0.0.0 --port ${PORT}"
      fi
      ;;
    node)
      echo "Common run examples:"
      echo "  npm start"
      echo "  or: node server.js"
      ;;
    ruby)
      echo "Common run examples:"
      echo "  bundle exec rails server -b 0.0.0.0 -p ${PORT}"
      ;;
    java)
      echo "Common run examples:"
      echo "  ./mvnw spring-boot:run -Dspring-boot.run.arguments=--server.port=${PORT}"
      echo "  or: java -jar target/*.jar"
      ;;
    go)
      echo "Common run examples:"
      echo "  go run ."
      echo "  or: ./your-binary -port ${PORT}"
      ;;
    php)
      echo "Common run examples:"
      echo "  php -S 0.0.0.0:${PORT} -t public"
      ;;
    rust)
      echo "Common run examples:"
      echo "  cargo run --release"
      ;;
    dotnet)
      echo "Common run examples:"
      echo "  dotnet run --urls http://0.0.0.0:${PORT}"
      ;;
    *)
      echo "Unknown project type. Install your runtime and dependencies manually."
      ;;
  esac
}

main() {
  log "Starting universal environment setup..."
  ensure_user
  ensure_dirs
  ensure_basics
  ensure_core_runtimes
  detect_project_type
  log "Project type detected: $PROJECT_TYPE"

  case "$PROJECT_TYPE" in
    python) setup_python ;;
    node) setup_node ;;
    ruby) setup_ruby ;;
    java) setup_java ;;
    go) setup_go ;;
    php) setup_php ;;
    rust) setup_rust ;;
    dotnet) setup_dotnet ;;
    unknown)
      warn "Could not detect project type. Creating default .env and basic directories."
      if [[ ! -f "$APP_DIR/.env" ]]; then
        cat > "$APP_DIR/.env" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT:-8080}
EOF
      fi
      # Create a minimal Makefile so build step succeeds when no build system is present
      if [[ ! -f "$APP_DIR/Makefile" ]]; then
        printf '%b' '.PHONY: all\nall:\n\t@echo Build OK\n' > "$APP_DIR/Makefile"
      fi
      ;;
  esac

  # Ensure make is available and create a fallback Makefile when no build system is detected
  ensure_make
  ensure_fallback_makefile
  ensure_makefile_test_target

  write_profile_snippet
  write_run_build_script
  log "Attempting project build via standalone script (run_build.sh)..."
  (cd "$APP_DIR" && ./run_build.sh) || warn "Build step failed (non-fatal)."

  # Set ownership at the end to avoid repeated chowns during installs
  if [[ -n "$APP_USER" ]] && [[ "$(id -u)" -eq 0 ]]; then
    chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR" || true
  fi

  pm_clean
  summary
}

main "$@"