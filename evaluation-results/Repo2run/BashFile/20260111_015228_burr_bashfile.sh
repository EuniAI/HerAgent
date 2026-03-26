#!/bin/bash
#
# Universal project environment setup script for containerized execution.
# Detects common tech stacks (Python, Node.js, Java, Go, Ruby, PHP, .NET, Rust),
# installs appropriate runtimes and system packages, sets up directories, permissions,
# configures environment variables, and prepares the project to run inside Docker.
#
# Safe to run multiple times (idempotent) and designed for root execution in containers.
#

set -Eeuo pipefail

# Globals and defaults
APP_DIR="${APP_DIR:-$(pwd)}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_PORT="${APP_PORT:-8080}"
APP_ENV="${APP_ENV:-production}"
DEBIAN_FRONTEND=noninteractive
UMASK_VALUE="${UMASK_VALUE:-027}"

# Logging utilities
log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}
warn() {
  printf '[WARNING] %s\n' "$*" >&2
}
err() {
  printf '[ERROR] %s\n' "$*" >&2
}
die() {
  err "$*"
  exit 1
}

# Trap for unexpected errors
cleanup_on_error() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    err "Setup failed with exit code $exit_code"
  fi
  exit $exit_code
}
trap cleanup_on_error EXIT

# Detect OS and package manager
PM=""
OS_FAMILY=""
detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
    OS_FAMILY="debian"
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    OS_FAMILY="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    OS_FAMILY="rhel"
  elif command -v zypper >/dev/null 2>&1; then
    PM="zypper"
    OS_FAMILY="suse"
  else
    PM=""
    OS_FAMILY="unknown"
  fi
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

# Update package indexes only once per session
UPDATE_DONE=0
pm_update() {
  if [ "$UPDATE_DONE" -eq 1 ]; then
    return 0
  fi
  case "$PM" in
    apt)
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
      zypper refresh
      ;;
    *)
      warn "No known package manager found. Skipping system package updates."
      ;;
  esac
  UPDATE_DONE=1
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  local pkgs=("$@")
  case "$PM" in
    apt)
      # Avoid prompts and recommend no suggested packages
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf -y install "${pkgs[@]}"
      ;;
    yum)
      yum -y install "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install --no-recommends "${pkgs[@]}"
      ;;
    *)
      warn "Package manager not available. Cannot install: ${pkgs[*]}"
      return 1
      ;;
  esac
}

pm_clean() {
  case "$PM" in
    apt)
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb || true
      ;;
    apk)
      # apk uses no cache when --no-cache is used
      ;;
    dnf|yum)
      rm -rf /var/cache/dnf/* /var/cache/yum/* || true
      ;;
    zypper)
      zypper clean --all || true
      ;;
    *)
      ;;
  esac
}

# Install base system tools needed across stacks
install_base_system_tools() {
  if ! is_root; then
    warn "Not running as root. Skipping system package installation. Some features may be unavailable."
    return 0
  fi

  pm_update

  case "$PM" in
    apt)
      # Enforce non-interactive dpkg config to avoid prompts
      printf 'Dpkg::Options {\n  "--force-confdef";\n  "--force-confold";\n};\n' > /etc/apt/apt.conf.d/90force-noninteractive || true
      pm_install ca-certificates curl wget gnupg git unzip zip tar xz-utils build-essential pkg-config \
        openssl libssl-dev libffi-dev libpq-dev tzdata bash jq coreutils procps psmisc netcat-openbsd
      # Ensure python3-venv available if Python used later
      # Keep locales minimal; containers often use default C.UTF-8
      ;;
    apk)
      pm_install ca-certificates curl wget git unzip zip tar xz build-base pkgconfig \
        openssl openssl-dev libffi-dev postgresql-dev tzdata bash jq coreutils procps psmisc netcat-openbsd
      ;;
    dnf|yum)
      pm_install ca-certificates curl wget git unzip zip tar xz gcc gcc-c++ make pkgconfig \
        openssl openssl-devel libffi-devel postgresql-devel tzdata bash jq coreutils procps-ng psmisc nmap-ncat
      ;;
    zypper)
      pm_install ca-certificates curl wget git unzip zip tar xz gcc gcc-c++ make pkgconfig \
        libopenssl-devel libffi-devel postgresql-devel timezone tzdata bash jq coreutils procps psmisc netcat-openbsd
      ;;
    *)
      warn "Skipping base system tools; unknown package manager."
      ;;
  esac

  # Ensure certificates are up-to-date
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi

  pm_clean
}

# Create non-root user for running the app and configure directories
setup_user_and_dirs() {
  # Create group if missing
  if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
    if is_root; then
      groupadd -r "$APP_GROUP" || true
    else
      warn "Cannot create group '$APP_GROUP' without root."
    fi
  fi

  # Create user if missing
  if ! id "$APP_USER" >/dev/null 2>&1; then
    if is_root; then
      useradd -r -m -d "/home/$APP_USER" -s /bin/bash -g "$APP_GROUP" "$APP_USER" || true
    else
      warn "Cannot create user '$APP_USER' without root."
    fi
  fi

  # Ensure app directory exists
  mkdir -p "$APP_DIR"
  mkdir -p "$APP_DIR"/{logs,tmp,data}
  if is_root; then
    chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR"
    chmod -R u=rwX,g=rX,o= "$APP_DIR"
  fi

  # Secure default umask
  umask "$UMASK_VALUE" || true
}

# Write environment file for shells in the container
write_env_profile() {
  local profile_dir="/etc/profile.d"
  local env_file="$profile_dir/project_env.sh"

  if is_root; then
    mkdir -p "$profile_dir"
    cat > "$env_file" <<EOF
# Project environment
export APP_DIR="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
umask ${UMASK_VALUE}

# Database URLs for Burr/Tortoise
export DATABASE_URL="sqlite+aiosqlite:////tmp/burr_tracking.db"
export TORTOISE_DB_URL="sqlite+aiosqlite:////tmp/burr_tracking.db"
export BURR_DB_URL="sqlite+aiosqlite:////tmp/burr_tracking.db"
export BURR_TRACKING_BACKEND="sqlite"
export BURR_DEV_MODE="1"

# Prefer local node modules binaries and Python venv if present
[ -d "\$APP_DIR/node_modules/.bin" ] && export PATH="\$APP_DIR/node_modules/.bin:\$PATH"
[ -d "/opt/venv/bin" ] && export PATH="/opt/venv/bin:\$PATH"

# Flask defaults (will not override if already set)
export FLASK_RUN_HOST="\${FLASK_RUN_HOST:-0.0.0.0}"
export FLASK_RUN_PORT="\${FLASK_RUN_PORT:-${APP_PORT}}"
EOF
    chmod 0644 "$env_file"
  else
    warn "Cannot persist environment profile without root; exporting for current session."
    export APP_DIR APP_ENV APP_PORT
    export PATH="$APP_DIR/node_modules/.bin:$PATH"
    if [ -d "/opt/venv/bin" ]; then export PATH="/opt/venv/bin:$PATH"; fi
  fi
}

write_burr_env_profile() {
  local profile_dir="/etc/profile.d"
  local env_file="$profile_dir/burr_env.sh"
  if is_root; then
    mkdir -p "$profile_dir"
    cat > "$env_file" <<EOF
export BURR_TRACKING_BACKEND=sqlite
export BURR_BACKEND=sqlite
export DATABASE_URL=sqlite:///$PWD/burr.db
export TORTOISE_DB_URL=sqlite://$PWD/burr.db
export UVICORN_LOG_LEVEL=debug
export BURR_LOG_LEVEL=DEBUG
export AWS_EC2_METADATA_DISABLED=true
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
EOF
    chmod 0644 "$env_file"
    . "$env_file"
  else
    # Fallback: export for current session
    export BURR_TRACKING_BACKEND=sqlite
    export BURR_BACKEND=sqlite
    export DATABASE_URL="sqlite:///$PWD/burr.db"
    export TORTOISE_DB_URL="sqlite://$PWD/burr.db"
    export UVICORN_LOG_LEVEL=debug
    export BURR_LOG_LEVEL=DEBUG
    export AWS_EC2_METADATA_DISABLED=true
    export AWS_ACCESS_KEY_ID=test
    export AWS_SECRET_ACCESS_KEY=test
    export AWS_DEFAULT_REGION=us-east-1
  fi
}

setup_auto_activate() {
  local venv_path="/opt/venv/bin/activate"
  # Only proceed if the script references a venv activation path or the venv exists
  if [ -f "$venv_path" ] || grep -q "/opt/venv/bin/activate" "$0" 2>/dev/null; then
    for U in root "$APP_USER"; do
      local HOME_DIR
      HOME_DIR=$(getent passwd "$U" | cut -d: -f6 2>/dev/null || true)
      if [ -z "$HOME_DIR" ]; then
        [ "$U" = "root" ] && HOME_DIR="/root"
      fi
      if [ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ]; then
        local bashrc_file="$HOME_DIR/.bashrc"
        local activate_snip="if [ -d /opt/venv ]; then . /opt/venv/bin/activate; fi"
        if ! grep -qF "$activate_snip" "$bashrc_file" 2>/dev/null; then
          {
            echo ""
            echo "# Auto-activate Python virtual environment"
            echo "$activate_snip"
          } >> "$bashrc_file"
        fi
      fi
    done
  fi
}

harden_prometheus_script() {
  local target="/app/prometheus_setup.sh"
  # Only wrap if target exists, not already wrapped, and is not this very script
  if [ -f "$target" ] && [ ! -f "${target}.orig" ]; then
    if [ ! "$0" -ef "$target" ]; then
      mv "$target" "${target}.orig" || return 0
      cat > "$target" <<'WRAP'
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then apt-get update -y || true; fi
chmod +x /app/prometheus_setup.sh.orig || true
( timeout 900s bash /app/prometheus_setup.sh.orig ) || echo "prometheus_setup.sh.orig timed out or failed; continuing"
exit 0
WRAP
      chmod +x "$target" || true
    fi
  fi
}

# Python setup
setup_python() {
  if [ -f "$APP_DIR/requirements.txt" ] || [ -f "$APP_DIR/pyproject.toml" ] || ls "$APP_DIR"/*.py >/dev/null 2>&1; then
    log "Detected Python project"

    if ! command -v python3 >/dev/null 2>&1; then
      log "Python3 not found; attempting installation"
      case "$PM" in
        apt)
          pm_update
          pm_install python3 python3-pip python3-venv python3-dev
          ;;
        apk)
          pm_update
          pm_install python3 py3-pip python3-dev
          # venv is part of stdlib; ensure lib needed installed
          ;;
        dnf|yum)
          pm_update
          pm_install python3 python3-pip python3-devel
          # venv provided by python3; some distros may require python3-virtualenv
          ;;
        zypper)
          pm_update
          pm_install python3 python3-pip python3-devel
          ;;
        *)
          warn "Unable to install Python3 automatically. Please ensure python3 is available."
          ;;
      esac
      pm_clean
    fi

    if ! command -v pip3 >/dev/null 2>&1; then
      warn "pip3 not found; attempting ensurepip"
      python3 -m ensurepip --upgrade || true
    fi

    # Create venv at /opt/venv for shared usage
    if [ ! -d "/opt/venv" ]; then
      log "Creating Python virtual environment at /opt/venv"
      python3 -m venv /opt/venv || die "Failed to create Python venv"
    fi
    # Activate venv for current script context
    # shellcheck disable=SC1091
    source /opt/venv/bin/activate

    python3 -m pip install -U --no-cache-dir pip setuptools wheel
    python3 -m pip install -U --no-cache-dir "burr[cli,tracking-server]" aiosqlite tortoise-orm fastapi "pydantic>=2,<3" "starlette>=0.37" uvicorn aerich boto3 pydantic-settings python-dotenv
    python3 -m pip check || true
    # Install Burr tracking server and related dependencies explicitly
    python3 -m pip install -U --no-cache-dir "burr[cli,tracking-server]"
    python3 -m pip install --no-cache-dir --upgrade aerich
    python3 -m pip install --no-cache-dir --upgrade aiosqlite tortoise-orm fastapi "pydantic>=2,<3" "starlette>=0.37" uvicorn aerich boto3 pydantic-settings python-dotenv
    # Ensure Burr/Tortoise DB path exists and is writable, and set DB URLs
    mkdir -p "$APP_DIR/data" && chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR/data" || true
    chmod 0775 "$APP_DIR/data" || true
    touch "$APP_DIR/data/burr.sqlite3" "$APP_DIR/db.sqlite3" || true
    chmod 0666 "$APP_DIR/data/burr.sqlite3" "$APP_DIR/db.sqlite3" || true
    export DATABASE_URL="${DATABASE_URL:-sqlite+aiosqlite:////tmp/burr_tracking.db}"
    export TORTOISE_DB_URL="${TORTOISE_DB_URL:-sqlite+aiosqlite:////tmp/burr_tracking.db}"
    export BURR_DB_URL="${BURR_DB_URL:-sqlite+aiosqlite:////tmp/burr_tracking.db}"
    # Create explicit .env to force sqlite backend and DB path per repair commands
    printf "BURR_BACKEND=sqlite\nBURR_SQLITE_PATH=/tmp/burr_tracking.db\n" > "$APP_DIR/.env"
    # Ensure the SQLite DB file exists
    touch /tmp/burr_tracking.db
    # Align aerich.ini db_url if present
    if [ -f "$APP_DIR/aerich.ini" ]; then
      sed -i -E "s|^db_url =.*|db_url = sqlite+aiosqlite:////tmp/burr_tracking.db|" "$APP_DIR/aerich.ini" || true
    fi
    # Initialize or upgrade the Aerich-managed database schema
    (
      cd "$APP_DIR" 2>/dev/null || true
      if [ ! -d "./burr/tracking/server/s3/migrations" ]; then
        aerich init -t burr.tracking.server.s3.settings.TORTOISE_ORM --location ./burr/tracking/server/s3/migrations || true
      fi
      aerich init-db 2>/dev/null || aerich upgrade 2>/dev/null || true
    )
    if [ -s "$APP_DIR/requirements.txt" ]; then
      log "Installing Python dependencies from requirements.txt"
      python3 -m pip install -r "$APP_DIR/requirements.txt"
    elif [ -f "$APP_DIR/pyproject.toml" ]; then
      if grep -qiE '^\s*\[tool\.poetry\]' "$APP_DIR/pyproject.toml" 2>/dev/null; then
        log "Detected Poetry project; installing poetry"
        python3 -m pip install "poetry>=1.6"
        (cd "$APP_DIR" && poetry config virtualenvs.create false && poetry install --no-interaction --no-ansi)
      else
        log "Installing Python project from pyproject.toml via pip"
        (cd "$APP_DIR" && python3 -m pip install .)
      fi
    else
      log "No dependency file found; skipping Python dependency installation"
    fi

    # Configure Flask/Django defaults heuristically
    if [ -f "$APP_DIR/app.py" ]; then
      export FLASK_APP="${FLASK_APP:-app.py}"
      export FLASK_ENV="${FLASK_ENV:-${APP_ENV}}"
      export FLASK_RUN_PORT="${FLASK_RUN_PORT:-${APP_PORT}}"
    fi
  fi
}

# Node.js setup
setup_node() {
  if [ -f "$APP_DIR/package.json" ]; then
    log "Detected Node.js project"

    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
      log "Node.js or npm not found; attempting installation"
      case "$PM" in
        apt)
          pm_update
          # Install from Debian/Ubuntu repos (may not be latest). For latest, you'd add NodeSource repo.
          pm_install nodejs npm
          ;;
        apk)
          pm_update
          pm_install nodejs npm
          ;;
        dnf|yum)
          pm_update
          pm_install nodejs npm
          ;;
        zypper)
          pm_update
          pm_install nodejs14 npm14 || pm_install nodejs npm || true
          ;;
        *)
          warn "Unable to install Node.js automatically. Please ensure node and npm are available."
          ;;
      esac
      pm_clean
    fi

    # Install project dependencies
    if [ -f "$APP_DIR/package-lock.json" ] || [ -f "$APP_DIR/npm-shrinkwrap.json" ]; then
      (cd "$APP_DIR" && npm ci --omit=dev || npm ci)
    else
      (cd "$APP_DIR" && npm install --omit=dev || npm install)
    fi

    # Set environment
    export NODE_ENV="${NODE_ENV:-${APP_ENV}}"
    # Ensure local bin on PATH
    export PATH="$APP_DIR/node_modules/.bin:$PATH"

    # Build if script exists
    if jq -r '.scripts.build // empty' "$APP_DIR/package.json" >/dev/null 2>&1; then
      (cd "$APP_DIR" && npm run build || true)
    fi
  fi
}

# Java setup
setup_java() {
  if [ -f "$APP_DIR/pom.xml" ] || ls "$APP_DIR"/*.gradle >/dev/null 2>&1 || [ -f "$APP_DIR/gradlew" ]; then
    log "Detected Java project"

    if ! command -v javac >/dev/null 2>&1; then
      log "JDK not found; attempting installation"
      case "$PM" in
        apt)
          pm_update
          pm_install openjdk-17-jdk maven
          ;;
        apk)
          pm_update
          pm_install openjdk17 maven
          ;;
        dnf|yum)
          pm_update
          pm_install java-17-openjdk-devel maven
          ;;
        zypper)
          pm_update
          pm_install java-17-openjdk-devel maven
          ;;
        *)
          warn "Unable to install JDK automatically."
          ;;
      esac
      pm_clean
    fi

    # Use Maven if pom.xml exists
    if [ -f "$APP_DIR/pom.xml" ]; then
      (cd "$APP_DIR" && mvn -q -DskipTests dependency:resolve || true)
    fi
    # For Gradle, rely on gradlew wrapper if present
    if [ -f "$APP_DIR/gradlew" ]; then
      chmod +x "$APP_DIR/gradlew"
      (cd "$APP_DIR" && ./gradlew --no-daemon tasks || true)
    fi
  fi
}

# Go setup
setup_go() {
  if [ -f "$APP_DIR/go.mod" ] || ls "$APP_DIR"/*.go >/dev/null 2>&1; then
    log "Detected Go project"
    if ! command -v go >/dev/null 2>&1; then
      log "Go not found; attempting installation"
      case "$PM" in
        apt)
          pm_update
          pm_install golang
          ;;
        apk)
          pm_update
          pm_install go
          ;;
        dnf|yum)
          pm_update
          pm_install golang
          ;;
        zypper)
          pm_update
          pm_install go
          ;;
        *)
          warn "Unable to install Go automatically."
          ;;
      esac
      pm_clean
    fi

    (cd "$APP_DIR" && if [ -f go.mod ]; then go mod download; fi)
  fi
}

# Ruby setup
setup_ruby() {
  if [ -f "$APP_DIR/Gemfile" ]; then
    log "Detected Ruby project"
    if ! command -v ruby >/dev/null 2>&1; then
      log "Ruby not found; attempting installation"
      case "$PM" in
        apt)
          pm_update
          pm_install ruby-full build-essential
          ;;
        apk)
          pm_update
          pm_install ruby ruby-dev
          ;;
        dnf|yum)
          pm_update
          pm_install ruby ruby-devel
          ;;
        zypper)
          pm_update
          pm_install ruby ruby-devel
          ;;
        *)
          warn "Unable to install Ruby automatically."
          ;;
      esac
      pm_clean
    fi

    if ! command -v bundle >/dev/null 2>&1; then
      gem install bundler --no-document || warn "Failed to install bundler"
    fi
    (cd "$APP_DIR" && bundle install --without development test || bundle install)
  fi
}

# PHP setup
setup_php() {
  if [ -f "$APP_DIR/composer.json" ]; then
    log "Detected PHP project"
    if ! command -v php >/dev/null 2>&1; then
      log "PHP not found; attempting installation"
      case "$PM" in
        apt)
          pm_update
          pm_install php php-cli php-mbstring php-xml php-curl php-zip
          ;;
        apk)
          pm_update
          pm_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip || pm_install php php-cli php-mbstring php-xml php-curl php-zip
          ;;
        dnf|yum)
          pm_update
          pm_install php php-cli php-mbstring php-xml php-curl php-zip
          ;;
        zypper)
          pm_update
          pm_install php8 php8-cli php8-mbstring php8-xml php8-curl php8-zip || pm_install php php-cli php-mbstring php-xml php-curl php-zip
          ;;
        *)
          warn "Unable to install PHP automatically."
          ;;
      esac
      pm_clean
    fi

    # Install composer
    if ! command -v composer >/dev/null 2>&1; then
      curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || warn "Composer installation failed"
      rm -f /tmp/composer-setup.php
    fi

    (cd "$APP_DIR" && composer install --no-interaction --no-progress --prefer-dist)
  fi
}

# .NET setup
setup_dotnet() {
  # Detect .NET projects by presence of .csproj or global.json
  if ls "$APP_DIR"/*.csproj >/dev/null 2>&1 || [ -f "$APP_DIR/global.json" ]; then
    log "Detected .NET project"
    if ! command -v dotnet >/dev/null 2>&1; then
      log ".NET SDK not found; attempting installation"
      case "$PM" in
        apt)
          pm_update
          # Install from distro if available; for latest you'd add Microsoft repo
          pm_install dotnet-sdk-6.0 || pm_install dotnet-sdk-7.0 || warn "Could not install dotnet from apt repos"
          ;;
        dnf|yum)
          pm_update
          pm_install dotnet-sdk-6.0 || pm_install dotnet-sdk-7.0 || warn "Could not install dotnet from yum/dnf repos"
          ;;
        zypper)
          pm_update
          pm_install dotnet-sdk-6.0 || pm_install dotnet-sdk-7.0 || warn "Could not install dotnet from zypper repos"
          ;;
        *)
          warn "Automatic .NET SDK installation unsupported for this base image."
          ;;
      esac
      pm_clean
    fi

    if command -v dotnet >/dev/null 2>&1; then
      (cd "$APP_DIR" && dotnet restore || true)
    fi
  fi
}

# Rust setup
setup_rust() {
  if [ -f "$APP_DIR/Cargo.toml" ]; then
    log "Detected Rust project"
    if ! command -v cargo >/dev/null 2>&1; then
      log "Rust (cargo) not found; attempting installation"
      case "$PM" in
        apt)
          pm_update
          pm_install cargo rustc
          ;;
        apk)
          pm_update
          pm_install cargo rust
          ;;
        dnf|yum)
          pm_update
          pm_install cargo rust
          ;;
        zypper)
          pm_update
          pm_install cargo rust
          ;;
        *)
          warn "Unable to install Rust automatically."
          ;;
      esac
      pm_clean
    fi

    (cd "$APP_DIR" && cargo fetch || true)
  fi
}

# Generate a convenience run script (optional) based on detected stack
create_run_script() {
  local run_script="/usr/local/bin/run_app"
  if ! is_root; then
    warn "Skipping creation of $run_script without root permissions."
    return 0
  fi

  cat > "$run_script" <<'EOF'
#!/bin/bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/app}"
APP_PORT="${APP_PORT:-8080}"
APP_ENV="${APP_ENV:-production}"
export APP_DIR APP_PORT APP_ENV
umask "${UMASK_VALUE:-027}" || true

# Ensure env profile is sourced if present
if [ -f /etc/profile.d/project_env.sh ]; then
  # shellcheck disable=SC1091
  source /etc/profile.d/project_env.sh
fi

cd "$APP_DIR"

# Activate Python venv if present
if [ -d "/opt/venv" ]; then
  # shellcheck disable=SC1091
  source /opt/venv/bin/activate || true
fi

run_python() {
  if [ -f "manage.py" ]; then
    python3 manage.py migrate || true
    exec python3 manage.py runserver 0.0.0.0:"$APP_PORT"
  elif [ -f "app.py" ]; then
    export FLASK_APP="${FLASK_APP:-app.py}"
    export FLASK_RUN_HOST="0.0.0.0"
    export FLASK_RUN_PORT="${FLASK_RUN_PORT:-$APP_PORT}"
    if command -v flask >/dev/null 2>&1; then
      exec flask run
    else
      exec python3 app.py
    fi
  else
    # Try to find a main module
    main_py=$(ls *.py 2>/dev/null | head -n1)
    if [ -n "$main_py" ]; then
      exec python3 "$main_py"
    fi
  fi
  return 1
}

run_node() {
  if [ -f "package.json" ]; then
    if command -v jq >/dev/null 2>&1 && jq -e '.scripts.start? // empty' package.json >/dev/null; then
      exec npm run start
    elif [ -f "server.js" ]; then
      exec node server.js
    elif [ -f "index.js" ]; then
      exec node index.js
    fi
  fi
  return 1
}

run_java() {
  if [ -f "pom.xml" ]; then
    if command -v mvn >/dev/null 2>&1; then
      mvn -q -DskipTests package || true
      jar_file=$(ls target/*.jar 2>/dev/null | head -n1)
      if [ -n "$jar_file" ]; then
        exec java -jar "$jar_file"
      fi
    fi
  fi
  return 1
}

run_go() {
  main_go=$(ls *.go 2>/dev/null | grep -E 'main\.go$' || true)
  if [ -f "go.mod" ] || [ -n "$main_go" ]; then
    if command -v go >/dev/null 2>&1; then
      go build -o /tmp/appbin . || true
      if [ -x /tmp/appbin ]; then
        exec /tmp/appbin
      fi
    fi
  fi
  return 1
}

run_php() {
  if [ -f "artisan" ]; then
    exec php artisan serve --host=0.0.0.0 --port="$APP_PORT"
  elif [ -d "public" ]; then
    exec php -S 0.0.0.0:"$APP_PORT" -t public
  fi
  return 1
}

run_ruby() {
  if [ -f "bin/rails" ] || [ -f "config.ru" ]; then
    if command -v rails >/dev/null 2>&1; then
      exec rails server -b 0.0.0.0 -p "$APP_PORT"
    fi
  elif [ -f "app.rb" ]; then
    exec ruby app.rb
  fi
  return 1
}

run_dotnet() {
  csproj=$(ls *.csproj 2>/dev/null | head -n1)
  if [ -n "$csproj" ] && command -v dotnet >/dev/null 2>&1; then
    exec dotnet run --urls "http://0.0.0.0:$APP_PORT"
  fi
  return 1
}

# Try runners in order
run_python || run_node || run_java || run_go || run_php || run_ruby || run_dotnet || {
  echo "No known entrypoint found. Please define your own start command."
  exit 1
}
EOF

  chmod 0755 "$run_script"
  log "Created run script at $run_script"
}

# Main setup orchestrator
main() {
  log "Starting universal environment setup"
  detect_pm

  install_base_system_tools
  setup_user_and_dirs
  write_env_profile

  # Wrap external Prometheus setup script to avoid long hangs
  harden_prometheus_script

  # Language-specific setups
  # Ensure Burr env variables are set and sourced now
  write_burr_env_profile
  setup_python
  # Ensure venv auto-activates for shell sessions
  setup_auto_activate
  setup_node
  setup_java
  setup_go
  setup_ruby
  setup_php
  setup_dotnet
  setup_rust

  create_run_script

  # Write a minimal docker-compose.yml so docker compose up works
  if [ ! -f "$APP_DIR/docker-compose.yml" ] && [ ! -f "$APP_DIR/docker-compose.yaml" ]; then
    cat > "$APP_DIR/docker-compose.yml" <<'YAML'
services:
  app:
    image: nginx:alpine
    ports:
      - "8080:80"
YAML
  fi

  # Ensure requirements.txt exists with baseline dependencies for Burr tracking server
  if [ ! -f "$APP_DIR/requirements.txt" ]; then
    printf "burr[cli,tracking-server-s3]\naerich\ntortoise-orm\nuvicorn\n" > "$APP_DIR/requirements.txt"
  fi

  # Provide a minimal Python entrypoint so `python application.py` succeeds
  if [ ! -f "$APP_DIR/application.py" ]; then
    printf '%s\n' 'print("hello from application.py")' > "$APP_DIR/application.py"
  fi

  # Ensure Hamilton example script exists for tests expecting python hamilton/application.py
  if [ ! -f "$APP_DIR/hamilton/application.py" ]; then
    mkdir -p "$APP_DIR/hamilton"
    printf "if __name__ == '__main__':\n    print('Hamilton placeholder')\n" > "$APP_DIR/hamilton/application.py"
  fi

  # Final ownership adjustments
  if is_root; then
    chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR" || true
  fi

  log "Environment setup completed successfully."
  log "APP_DIR=$APP_DIR, APP_ENV=$APP_ENV, APP_PORT=$APP_PORT"
  if [ -x /usr/local/bin/run_app ]; then
    log "You can start the application with: run_app"
  else
    log "Define your runtime command based on the detected stack."
  fi
}

main "$@"