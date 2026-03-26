#!/bin/bash
# Universal project environment setup script for containerized execution
# Detects common stacks (Python, Node.js, Ruby, Go, Java, PHP, .NET) and installs runtime + dependencies.
# Designed to run inside Docker containers without sudo; idempotent and safe to re-run.

set -Eeuo pipefail
IFS=$'\n\t'

# Globals and defaults
APP_HOME="${APP_HOME:-/app}"
APP_ENV_FILE="${APP_ENV_FILE:-$APP_HOME/.env}"
APP_USER="${APP_USER:-root}"
DEBIAN_FRONTEND=noninteractive
LANG="${LANG:-C.UTF-8}"

# Colors (safe fallback if terminal doesn't support)
if [ -t 1 ]; then
  GREEN="$(printf '\033[0;32m')"
  RED="$(printf '\033[0;31m')"
  YELLOW="$(printf '\033[1;33m')"
  BLUE="$(printf '\033[0;34m')"
  NC="$(printf '\033[0m')"
else
  GREEN=""
  RED=""
  YELLOW=""
  BLUE=""
  NC=""
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
debug() { echo -e "${BLUE}[DEBUG] $*${NC}"; }

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    err "Setup failed with exit code $exit_code"
  fi
}
trap cleanup EXIT

is_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ]
}

# Detect package manager
PKG_MANAGER=""
pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"; return 0; fi
  if command -v apk >/dev/null 2>&1; then PKG_MANAGER="apk"; return 0; fi
  if command -v dnf >/dev/null 2>&1; then PKG_MANAGER="dnf"; return 0; fi
  if command -v yum >/dev/null 2>&1; then PKG_MANAGER="yum"; return 0; fi
  if command -v zypper >/dev/null 2>&1; then PKG_MANAGER="zypper"; return 0; fi
  PKG_MANAGER=""
  return 1
}

pm_update() {
  case "$PKG_MANAGER" in
    apt)
      apt-get update -y >/dev/null
      ;;
    apk)
      apk update >/dev/null
      ;;
    dnf)
      dnf -y makecache >/dev/null
      ;;
    yum)
      yum makecache -y >/dev/null
      ;;
    zypper)
      zypper refresh -y >/dev/null
      ;;
    *)
      warn "No package manager detected; skipping system update"
      ;;
  esac
}

pm_install() {
  # Usage: pm_install pkg1 pkg2 ...
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y --no-install-recommends "$@" >/dev/null
      ;;
    apk)
      apk add --no-cache "$@" >/dev/null
      ;;
    dnf)
      dnf install -y "$@" >/dev/null
      ;;
    yum)
      yum install -y "$@" >/dev/null
      ;;
    zypper)
      zypper install -y "$@" >/dev/null
      ;;
    *)
      err "Package manager unavailable; cannot install: $*"
      ;;
  esac
}

pkg_installed() {
  # Returns 0 if package seems installed (best-effort per manager)
  local pkg="$1"
  case "$PKG_MANAGER" in
    apt)
      dpkg -s "$pkg" >/dev/null 2>&1
      ;;
    apk)
      apk info -e "$pkg" >/dev/null 2>&1
      ;;
    dnf|yum)
      rpm -q "$pkg" >/dev/null 2>&1
      ;;
    zypper)
      rpm -q "$pkg" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_root_or_warn() {
  if ! is_root; then
    warn "Not running as root. System package installation may fail if privileges are required."
  fi
}

ensure_workdir() {
  log "Ensuring project directory at $APP_HOME"
  mkdir -p "$APP_HOME"
  chmod 755 "$APP_HOME"
  if is_root && [ "$APP_USER" != "root" ]; then
    id -u "$APP_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$APP_USER" >/dev/null 2>&1 || true
    chown -R "$APP_USER":"$APP_USER" "$APP_HOME" || true
  fi
}

write_env_kv() {
  # Usage: write_env_kv KEY VALUE
  local k="$1"; shift
  local v="$1"; shift
  mkdir -p "$(dirname "$APP_ENV_FILE")"
  touch "$APP_ENV_FILE"
  if grep -qE "^${k}=" "$APP_ENV_FILE"; then
    sed -i "s|^${k}=.*|${k}=${v}|g" "$APP_ENV_FILE"
  else
    echo "${k}=${v}" >> "$APP_ENV_FILE"
  fi
}

load_env_file() {
  if [ -f "$APP_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$APP_ENV_FILE"
    set +a
  fi
}

persist_env_profile() {
  # Persist env to /etc/profile.d for all shells (if root)
  if is_root; then
    local profile="/etc/profile.d/00-project-env.sh"
    {
      echo "#!/bin/sh"
      echo "export APP_HOME=\"$APP_HOME\""
      if [ -f "$APP_ENV_FILE" ]; then
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          printf 'export %s\n' "$line"
        done < "$APP_ENV_FILE"
      fi
    } > "$profile"
    chmod 644 "$profile"
  fi
}

install_common_system_deps() {
  ensure_root_or_warn
  pm_detect || warn "Unable to detect package manager; skipping system packages"
  if [ -n "$PKG_MANAGER" ]; then
    log "Updating package index ($PKG_MANAGER)"
    pm_update

    log "Installing core system tools"
    case "$PKG_MANAGER" in
      apt)
        apt-get update && apt-get install -y git ca-certificates curl python3-pip python3-venv && update-ca-certificates
        pm_install ca-certificates curl wget git tzdata locales unzip xz-utils gnupg dirmngr build-essential pkg-config cmake ninja-build doxygen graphviz python3 python3-pip python3-venv libssl-dev libffi-dev libxml2-dev libxslt1-dev
        locale-gen en_US.UTF-8 || true
        pm_install python3 python3-venv python3-pip git make cmake
        ;;
      apk)
        pm_install ca-certificates curl wget git tzdata unzip xz gnupg build-base pkgconfig openssl-dev libffi-dev libxml2-dev libxslt-dev
        ;;
      dnf|yum)
        pm_install ca-certificates curl wget git tzdata unzip xz gnupg2 tar gcc gcc-c++ make pkgconfig openssl-devel libffi-devel libxml2-devel libxslt-devel
        ;;
      zypper)
        pm_install ca-certificates curl wget git timezone unzip xz gpg2 tar gcc gcc-c++ make pkgconfig libopenssl-devel libffi-devel libxml2-devel libxslt-devel
        ;;
    esac
    update-ca-certificates >/dev/null 2>&1 || true
  fi
}

# Python setup
python_detect() {
  [ -f "$APP_HOME/requirements.txt" ] || [ -f "$APP_HOME/pyproject.toml" ] || [ -f "$APP_HOME/Pipfile" ]
}
python_install_runtime() {
  if command -v python3 >/dev/null 2>&1; then
    log "Python runtime detected: $(python3 -V 2>&1)"
  else
    ensure_root_or_warn
    pm_detect || true
    case "$PKG_MANAGER" in
      apt) pm_install python3 python3-venv python3-pip python3-dev ;;
      apk) pm_install python3 py3-pip python3-dev ;;
      dnf|yum) pm_install python3 python3-pip python3-devel ;;
      zypper) pm_install python3 python3-pip python3-devel ;;
      *) err "Cannot install Python3 without a package manager"; return 1 ;;
    esac
    log "Installed Python runtime: $(python3 -V 2>&1)"
  fi
}
python_setup_venv() {
  cd "$APP_HOME"
  local venv_dir="${PYTHON_VENV:-$APP_HOME/.venv}"
  if [ ! -d "$venv_dir" ]; then
    log "Creating Python virtual environment at $venv_dir"
    python3 -m venv "$venv_dir"
  else
    log "Python virtual environment already exists at $venv_dir"
  fi
  # shellcheck disable=SC1090
  . "$venv_dir/bin/activate"
  python -m pip install --upgrade pip setuptools wheel >/dev/null
  if [ -f requirements.txt ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r requirements.txt
  elif [ -f pyproject.toml ]; then
    if grep -q '\[tool.pip\]' pyproject.toml 2>/dev/null || grep -q '\[tool.\(poetry\|pdm\)\]' pyproject.toml 2>/dev/null; then
      if grep -q '\[tool.poetry\]' pyproject.toml; then
        pip install poetry && poetry install --no-interaction --no-ansi
      elif grep -q '\[tool.pdm\]' pyproject.toml; then
        pip install pdm && pdm install --prod
      else
        pip install -e .
      fi
    else
      pip install -e .
    fi
  elif [ -f Pipfile ]; then
    pip install pipenv && pipenv install --system --deploy
  fi
  deactivate || true
  write_env_kv PYTHON_VENV "$venv_dir"
  log "Python environment configured"
}

# Node.js setup
node_detect() {
  [ -f "$APP_HOME/package.json" ]
}
node_install_runtime() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "Node runtime detected: node $(node -v), npm $(npm -v)"
    return 0
  fi

  ensure_root_or_warn
  pm_detect || true
  local installed=false
  case "$PKG_MANAGER" in
    apt)
      # Try NodeSource (LTS)
      curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - || true
      pm_install nodejs
      installed=true
      ;;
    apk)
      pm_install nodejs npm
      installed=true
      ;;
    dnf|yum)
      curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - || true
      pm_install nodejs
      installed=true
      ;;
    zypper)
      pm_install nodejs npm || true
      ;;
  esac

  if ! $installed; then
    # Fallback: download Node LTS binary tarball
    local arch="$(uname -m)"
    local node_arch="linux-x64"
    case "$arch" in
      x86_64|amd64) node_arch="linux-x64" ;;
      aarch64|arm64) node_arch="linux-arm64" ;;
      armv7l|armv7) node_arch="linux-armv7l" ;;
      *) warn "Unknown arch $arch; defaulting to linux-x64"; node_arch="linux-x64" ;;
    esac
    local NODE_VERSION="${NODE_VERSION:-20.17.0}"
    log "Installing Node.js $NODE_VERSION ($node_arch) via tarball"
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-$node_arch.tar.xz" -o /tmp/node.tar.xz
    mkdir -p /usr/local/lib/nodejs
    tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs
    ln -sf "/usr/local/lib/nodejs/node-v$NODE_VERSION-$node_arch/bin/node" /usr/local/bin/node
    ln -sf "/usr/local/lib/nodejs/node-v$NODE_VERSION-$node_arch/bin/npm" /usr/local/bin/npm
    ln -sf "/usr/local/lib/nodejs/node-v$NODE_VERSION-$node_arch/bin/npx" /usr/local/bin/npx
    rm -f /tmp/node.tar.xz
  fi
  log "Installed Node runtime: node $(node -v), npm $(npm -v)"
}
node_install_deps() {
  cd "$APP_HOME"
  if [ -f package.json ]; then
    log "Installing Node.js dependencies"
    if [ -f package-lock.json ]; then
      npm ci --no-audit --no-fund
    else
      npm install --no-audit --no-fund
    fi
  fi
}

# Ruby setup
ruby_detect() { [ -f "$APP_HOME/Gemfile" ]; }
ruby_install_runtime() {
  if command -v ruby >/dev/null 2>&1 && command -v gem >/dev/null 2>&1; then
    log "Ruby detected: $(ruby -v)"
  else
    ensure_root_or_warn
    pm_detect || true
    case "$PKG_MANAGER" in
      apt) pm_install ruby-full build-essential ;;
      apk) pm_install ruby ruby-dev build-base ;;
      dnf|yum) pm_install ruby ruby-devel make gcc ;;
      zypper) pm_install ruby ruby-devel gcc make ;;
      *) err "Cannot install Ruby without package manager"; return 1 ;;
    esac
    log "Installed Ruby: $(ruby -v)"
  fi
  gem install --no-document bundler || true
}
ruby_install_deps() {
  cd "$APP_HOME"
  [ -f Gemfile ] || return 0
  log "Installing Ruby gems via Bundler"
  bundle config set --local path "vendor/bundle"
  bundle install --jobs 4 --retry 3
}

# Go setup
go_detect() { [ -f "$APP_HOME/go.mod" ] || [ -f "$APP_HOME/go.sum" ]; }
go_install_runtime() {
  if command -v go >/dev/null 2>&1; then
    log "Go detected: $(go version)"
    return 0
  fi
  ensure_root_or_warn
  local GO_VERSION="${GO_VERSION:-1.22.6}"
  local arch="$(uname -m)"
  local go_arch="linux-amd64"
  case "$arch" in
    x86_64|amd64) go_arch="linux-amd64" ;;
    aarch64|arm64) go_arch="linux-arm64" ;;
    armv6l) go_arch="linux-armv6l" ;;
    armv7l|armv7) go_arch="linux-armv6l" ;;
    *) warn "Unknown arch $arch; defaulting to linux-amd64"; go_arch="linux-amd64" ;;
  esac
  log "Installing Go $GO_VERSION ($go_arch)"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.${go_arch}.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  rm -f /tmp/go.tgz
  log "Installed Go: $(go version)"
}
go_install_deps() {
  cd "$APP_HOME"
  if [ -f go.mod ]; then
    log "Downloading Go modules"
    go env -w GOPATH="${GOPATH:-$APP_HOME/.gopath}" || true
    go mod download
  fi
}

# Java setup
java_detect() { [ -f "$APP_HOME/pom.xml" ] || [ -f "$APP_HOME/build.gradle" ] || [ -f "$APP_HOME/gradlew" ]; }
java_install_runtime() {
  if command -v java >/dev/null 2>&1; then
    log "Java detected: $(java -version 2>&1 | head -n1)"
  else
    ensure_root_or_warn
    pm_detect || true
    case "$PKG_MANAGER" in
      apt) pm_install openjdk-17-jdk ;;
      apk) pm_install openjdk17-jdk ;;
      dnf|yum) pm_install java-17-openjdk-devel ;;
      zypper) pm_install java-17-openjdk-devel ;;
      *) err "Cannot install Java without package manager"; return 1 ;;
    esac
    log "Installed Java: $(java -version 2>&1 | head -n1)"
  fi
  if command -v mvn >/dev/null 2>&1; then
    log "Maven detected: $(mvn -v | head -n1)"
  else
    ensure_root_or_warn
    pm_detect || true
    case "$PKG_MANAGER" in
      apt) pm_install maven ;;
      apk) pm_install maven ;;
      dnf|yum) pm_install maven ;;
      zypper) pm_install maven ;;
      *) warn "Maven not installed (no package manager). Will use Gradle wrapper if available." ;;
    esac
  fi
}
java_install_deps() {
  cd "$APP_HOME"
  if [ -f pom.xml ]; then
    log "Downloading Maven dependencies"
    mvn -q -DskipTests dependency:resolve dependency:resolve-plugins || mvn -q -DskipTests package -DskipTests
  elif [ -f gradlew ]; then
    log "Ensuring Gradle wrapper is executable"
    chmod +x gradlew
    ./gradlew --no-daemon tasks >/dev/null || true
  elif [ -f build.gradle ]; then
    warn "Gradle wrapper not found; installing gradle via package manager"
    ensure_root_or_warn
    pm_detect || true
    case "$PKG_MANAGER" in
      apt|apk|dnf|yum|zypper) pm_install gradle || true ;;
    esac
  fi
}

# PHP setup
php_detect() { [ -f "$APP_HOME/composer.json" ] || [ -f "$APP_HOME/index.php" ]; }
php_install_runtime() {
  if command -v php >/dev/null 2>&1; then
    log "PHP detected: $(php -v | head -n1)"
  else
    ensure_root_or_warn
    pm_detect || true
    case "$PKG_MANAGER" in
      apt) pm_install php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd ;;
      apk) pm_install php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip php81-intl php81-gd ;;
      dnf|yum) pm_install php-cli php-mbstring php-xml php-curl php-zip php-intl php-gd ;;
      zypper) pm_install php-cli php7-mbstring php7-xml php7-curl php7-zip php7-intl php7-gd ;;
      *) err "Cannot install PHP without package manager"; return 1 ;;
    esac
    log "Installed PHP: $(php -v | head -n1)"
  fi
  if command -v composer >/dev/null 2>&1; then
    log "Composer detected: $(composer --version)"
  else
    log "Installing Composer"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer >/dev/null
    rm -f /tmp/composer-setup.php
  fi
}
php_install_deps() {
  cd "$APP_HOME"
  if [ -f composer.json ]; then
    log "Installing PHP dependencies via Composer"
    composer install --no-interaction --no-progress --prefer-dist
  fi
}

# .NET setup (best-effort for Debian/Ubuntu)
dotnet_detect() {
  find "$APP_HOME" -maxdepth 2 -name "*.csproj" -o -name "*.sln" | grep -q .
}
dotnet_install_runtime() {
  if command -v dotnet >/dev/null 2>&1; then
    log ".NET detected: $(dotnet --version)"
    return 0
  fi
  ensure_root_or_warn
  pm_detect || true
  if [ "$PKG_MANAGER" = "apt" ]; then
    log "Installing .NET SDK (Microsoft package repo)"
    curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb || \
      curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb || true
    dpkg -i /tmp/packages-microsoft-prod.deb >/dev/null 2>&1 || true
    rm -f /tmp/packages-microsoft-prod.deb
    pm_update
    pm_install dotnet-sdk-8.0 || pm_install dotnet-sdk-7.0 || true
  else
    warn "Automated .NET installation not supported for this distro; please preinstall dotnet SDK."
  fi
}
dotnet_restore() {
  cd "$APP_HOME"
  if dotnet_detect; then
    log "Restoring .NET dependencies"
    find . -maxdepth 2 -name "*.sln" | while read -r sln; do dotnet restore "$sln"; done
    find . -maxdepth 2 -name "*.csproj" | while read -r csproj; do dotnet restore "$csproj"; done
  fi
}

# Framework port detection and env
detect_default_port() {
  local port=""
  if [ -f "$APP_HOME/manage.py" ]; then
    port="8000"
  elif [ -f "$APP_HOME/app.py" ] || grep -qi "flask" "$APP_HOME/requirements.txt" 2>/dev/null; then
    port="5000"
  elif [ -f "$APP_HOME/package.json" ]; then
    # Try reading start script with common ports
    if grep -qE "3000" "$APP_HOME/package.json"; then port="3000"; else port="3000"; fi
  elif [ -f "$APP_HOME/pom.xml" ] || [ -f "$APP_HOME/gradlew" ]; then
    port="8080"
  elif [ -f "$APP_HOME/go.mod" ]; then
    port="8080"
  elif [ -f "$APP_HOME/composer.json" ]; then
    port="8080"
  else
    port="${APP_PORT:-8080}"
  fi
  echo "$port"
}

configure_runtime_env() {
  load_env_file
  write_env_kv APP_HOME "$APP_HOME"

  local default_port
  default_port="$(detect_default_port)"
  write_env_kv APP_PORT "${APP_PORT:-$default_port}"

  # Set commonly used variables
  if [ -f "$APP_HOME/app.py" ]; then
    write_env_kv FLASK_APP "app.py"
    write_env_kv FLASK_ENV "${FLASK_ENV:-production}"
    write_env_kv FLASK_RUN_PORT "$(detect_default_port)"
  fi
  if [ -f "$APP_HOME/manage.py" ]; then
    write_env_kv DJANGO_SETTINGS_MODULE "${DJANGO_SETTINGS_MODULE:-project.settings}"
  fi
  if [ -f "$APP_HOME/package.json" ]; then
    write_env_kv NODE_ENV "${NODE_ENV:-production}"
  fi

  persist_env_profile
  log "Environment variables persisted to $APP_ENV_FILE"
}

# Ensure required repo scripts are accessible at repository root
ensure_repo_script_symlinks() {
  cd "$APP_HOME"
  for f in generate_natvis.py amalgamate.py; do
    if [ ! -e "$f" ]; then
      p=$(find . -maxdepth 3 -type f -name "$f" | head -n1)
      if [ -n "$p" ] && [ "$p" != "./$f" ]; then
        ln -sf "$p" "$f"
      fi
    fi
  done
  for f in generate_natvis.py amalgamate.py; do
    [ -f "$f" ] && chmod +x "$f" || true
  done
}

# Ensure Jinja2 and Python tools for repo scripts regardless of project markers
install_global_python_tools_for_repo_scripts() {
  pm_detect || true
  # Ensure pip is available using cross-distro fallback
  if ! python3 -m pip --version >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y python3-pip
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3-pip
    elif command -v apk >/dev/null 2>&1; then
      apk update && apk add --no-cache py3-pip
    else
      warn "No supported package manager found to install pip"
    fi
  fi
  if python3 -m pip --version >/dev/null 2>&1; then
    python3 -m pip install --no-cache-dir --upgrade pip
    python3 -m pip install --upgrade --no-cache-dir watchdog jinja2
  else
    warn "pip not found; unable to install watchdog/jinja2"
  fi
}

# Entry instructions message
print_usage_hints() {
  echo ""
  echo "Setup completed successfully."
  echo "Detected stack components:"
  local comps=""
  python_detect && comps="$comps Python"
  node_detect && comps="$comps Node.js"
  ruby_detect && comps="$comps Ruby"
  go_detect && comps="$comps Go"
  java_detect && comps="$comps Java"
  php_detect && comps="$comps PHP"
  dotnet_detect && comps="$comps .NET"
  echo " - $comps"
  echo ""
  echo "Environment:"
  echo " - APP_HOME: $APP_HOME"
  if [ -f "$APP_ENV_FILE" ]; then
    echo " - Loaded variables from $APP_ENV_FILE"
  fi
  echo ""
  echo "Run hints (depending on project type):"
  echo " - Python Flask: source .venv/bin/activate && python app.py"
  echo " - Python Django: source .venv/bin/activate && python manage.py runserver 0.0.0.0:\${APP_PORT}"
  echo " - Node.js: npm start (or: node server.js) on port \${APP_PORT}"
  echo " - Ruby (Rails): bundle exec rails server -b 0.0.0.0 -p \${APP_PORT}"
  echo " - Go: go run ./... (or compiled binary) on port \${APP_PORT}"
  echo " - Java (Maven): mvn spring-boot:run or java -jar target/*.jar on port \${APP_PORT}"
  echo " - PHP: php -S 0.0.0.0:\${APP_PORT} -t public"
  echo " - .NET: dotnet run --project <project.csproj> --urls http://0.0.0.0:\${APP_PORT}"
}

main() {
  log "Starting universal environment setup for container"

  ensure_workdir

  install_common_system_deps

  # Ensure Python tools needed by repo utility scripts (e.g., generate_natvis.py)
  install_global_python_tools_for_repo_scripts

  # Detect and install runtime + deps per stack
  if python_detect; then
    log "Configuring Python environment"
    python_install_runtime
    python_setup_venv
  else
    debug "Python project markers not found (requirements.txt/pyproject.toml/Pipfile)"
  fi

  if node_detect; then
    log "Configuring Node.js environment"
    node_install_runtime
    node_install_deps
  else
    debug "Node.js project markers not found (package.json)"
  fi

  if ruby_detect; then
    log "Configuring Ruby environment"
    ruby_install_runtime
    ruby_install_deps
  else
    debug "Ruby project markers not found (Gemfile)"
  fi

  if go_detect; then
    log "Configuring Go environment"
    go_install_runtime
    go_install_deps
  else
    debug "Go project markers not found (go.mod)"
  fi

  if java_detect; then
    log "Configuring Java environment"
    java_install_runtime
    java_install_deps
  else
    debug "Java project markers not found (pom.xml/build.gradle/gradlew)"
  fi

  if php_detect; then
    log "Configuring PHP environment"
    php_install_runtime
    php_install_deps
  else
    debug "PHP project markers not found (composer.json/index.php)"
  fi

  if dotnet_detect; then
    log "Configuring .NET environment"
    dotnet_install_runtime
    dotnet_restore
  else
    debug ".NET project markers not found (*.csproj/*.sln)"
  fi

  configure_runtime_env

  # Create symlinks for repo scripts expected at root (amalgamate.py, generate_natvis.py)
  ensure_repo_script_symlinks
  # Ensure output directory exists for natvis generation scripts
  mkdir -p output_directory

  print_usage_hints
}

# Enter project directory if script was dropped elsewhere
if [ -d "$APP_HOME" ]; then
  cd "$APP_HOME"
fi

main "$@"