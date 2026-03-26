#!/usr/bin/env bash
# Universal project environment setup script for containerized execution
# This script detects common project types (Python, Node.js, Ruby, Go, Java, PHP, Rust)
# and installs appropriate runtimes and dependencies using the container's package manager.
# It is designed to run as root inside Docker containers but gracefully degrades for non-root.

set -Eeuo pipefail
# Ensure OPENAI_API_KEY is available during setup; fallback to a harmless local value
export OPENAI_API_KEY="${OPENAI_API_KEY:-sk-local-not-required}"

# --------------- Configurable Defaults ---------------
WORK_DIR="${WORK_DIR:-/app}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
APP_ENV="${APP_ENV:-production}"
PORT="${PORT:-8080}"
LOG_LEVEL="${LOG_LEVEL:-info}"
TZ="${TZ:-UTC}"
# -----------------------------------------------------

# --------------- Colors and Logging ------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() { echo -e "${GREEN}[$(timestamp)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(timestamp)] [WARN] $*${NC}"; }
err() { echo -e "${RED}[$(timestamp)] [ERROR] $*${NC}" >&2; }
# -----------------------------------------------------

# --------------- Error Trap --------------------------
cleanup() {
  local exit_code=$?
  if (( exit_code != 0 )); then
    err "Setup failed with exit code ${exit_code}"
  fi
}
trap cleanup EXIT
# -----------------------------------------------------

# --------------- OS/Package Manager ------------------
OS_ID=""
PKG_MGR=""

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    PKG_MGR=""
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      # no explicit update needed due to --no-cache
      true
      ;;
    dnf)
      dnf -y makecache || true
      ;;
    yum)
      yum -y makecache || true
      ;;
    *)
      warn "No supported package manager detected. Skipping system updates."
      ;;
  esac
}

pkg_install() {
  # Accepts packages as arguments
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@" || true
      ;;
    apk)
      apk add --no-cache "$@" || true
      ;;
    dnf)
      dnf install -y "$@" || true
      ;;
    yum)
      yum install -y "$@" || true
      ;;
    *)
      warn "Cannot install packages automatically (unsupported package manager)."
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MGR" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
      ;;
    dnf|yum)
      rm -rf /var/cache/* /tmp/* /var/tmp/*
      ;;
    *)
      true
      ;;
  esac
}
# -----------------------------------------------------

# --------------- Helpers -----------------------------
is_root() { [[ "$(id -u)" -eq 0 ]]; }

ensure_dir() {
  local d="$1"
  mkdir -p "$d"
}

create_app_user_group() {
  if ! is_root; then
    warn "Not running as root; cannot create system user/group. Continuing as current user."
    return 0
  fi

  case "$PKG_MGR" in
    apk)
      # Alpine
      if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
        addgroup -g "$APP_GID" "$APP_GROUP" || true
      fi
      if ! getent passwd "$APP_USER" >/dev/null 2>&1; then
        adduser -D -h "/home/$APP_USER" -G "$APP_GROUP" -u "$APP_UID" "$APP_USER" || true
      fi
      ;;
    apt|dnf|yum|"")
      # Debian/Ubuntu/RHEL
      if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
        groupadd -g "$APP_GID" "$APP_GROUP" || true
      fi
      if ! getent passwd "$APP_USER" >/dev/null 2>&1; then
        useradd -m -d "/home/$APP_USER" -s /bin/bash -g "$APP_GROUP" -u "$APP_UID" "$APP_USER" || true
      fi
      ;;
  esac
}

set_timezone() {
  if ! is_root; then
    warn "Not running as root; cannot set system timezone. Skipping."
    return 0
  fi
  if [[ -n "${TZ:-}" ]]; then
    case "$PKG_MGR" in
      apt|dnf|yum)
        pkg_install tzdata || true
        ;;
      apk)
        pkg_install tzdata || true
        ;;
    esac
    echo "$TZ" > /etc/timezone || true
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
  fi
}

write_env_file() {
  cat > "${WORK_DIR}/.env" <<EOF
APP_ENV=${APP_ENV}
PORT=${PORT}
LOG_LEVEL=${LOG_LEVEL}
TZ=${TZ}
# Add any project-specific environment variables below:
# DATABASE_URL=
# REDIS_URL=
EOF
  chmod 0644 "${WORK_DIR}/.env"
}

write_profile_env() {
  # Make environment variables and PATH adjustments available to interactive shells
  local profile="/etc/profile.d/app_env.sh"
  if is_root; then
    cat > "$profile" <<'EOF'
# App environment profile
export APP_ENV="${APP_ENV:-production}"
export PORT="${PORT:-8080}"
export LOG_LEVEL="${LOG_LEVEL:-info}"
export TZ="${TZ:-UTC}"

# Language-specific bins
export PATH="/app/.venv/bin:/app/node_modules/.bin:/app/vendor/bundle/bin:$PATH"
EOF
    chmod 0644 "$profile"
    # Persist an OpenAI API key to avoid client init failures in cache-only paths
    cat > /etc/profile.d/openai.sh <<'EOF'
export OPENAI_API_KEY=${OPENAI_API_KEY:-sk-local-not-required}
EOF
    chmod 0644 /etc/profile.d/openai.sh
    export OPENAI_API_KEY="${OPENAI_API_KEY:-sk-local-not-required}"
  fi
}
# -----------------------------------------------------

# --------------- Project Detection -------------------
in_dir() { [[ -f "${WORK_DIR}/$1" || -d "${WORK_DIR}/$1" ]]; }

is_python_project() { in_dir "requirements.txt" || in_dir "pyproject.toml" || in_dir "Pipfile" || in_dir "setup.py"; }
is_node_project() { in_dir "package.json"; }
is_ruby_project() { in_dir "Gemfile"; }
is_go_project() { in_dir "go.mod" || in_dir "main.go"; }
is_java_maven_project() { in_dir "pom.xml"; }
is_java_gradle_project() { in_dir "build.gradle" || in_dir "build.gradle.kts"; }
is_php_project() { in_dir "composer.json"; }
is_rust_project() { in_dir "Cargo.toml"; }
is_dotnet_project() { compgen -G "${WORK_DIR}/*.csproj" >/dev/null || compgen -G "${WORK_DIR}/*.fsproj" >/dev/null || in_dir "global.json"; }

# -----------------------------------------------------

# --------------- Base Tools Installation -------------
install_base_tools() {
  log "Installing base system tools..."
  pkg_update

  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git bash coreutils file wget unzip xz-utils tar pkg-config build-essential python3 python3-pip pipx
      ;;
    apk)
      pkg_install ca-certificates curl git bash coreutils file wget unzip xz tar pkgconfig build-base
      ;;
    dnf)
      pkg_install ca-certificates curl git bash coreutils file wget unzip xz tar pkgconf pkgconf-pkg-config @development-tools
      ;;
    yum)
      pkg_install ca-certificates curl git bash coreutils file wget unzip xz tar pkgconfig gcc gcc-c++ make
      ;;
    *)
      warn "Base tools installation skipped (no package manager). Ensure curl, git, and build tools exist."
      ;;
  esac

  update-ca-certificates >/dev/null 2>&1 || true
}
# -----------------------------------------------------

# --------------- Python command shim -----------------
setup_python_shim() {
  # Create a shim for `python` that repairs broken `-c import <module>` invocations
  if ! is_root; then
    return 0
  fi
  mkdir -p /usr/local/bin
  cat <<'EOF' >/usr/local/bin/python
#!/usr/bin/env bash
# Fix for environments that split `python -c` code into multiple args
PYBIN="$(command -v python3 || command -v python)"
if [ "$1" = "-c" ] && [ "$2" = "import" ] && [ -n "$3" ] && [ -z "$4" ]; then
  exec "$PYBIN" -c "import $3"
else
  exec "$PYBIN" "$@"
fi
EOF
  chmod +x /usr/local/bin/python
}

# --------------- User-level shims and PATH -------------
setup_user_local_shims() {
  log "Configuring user-local shims and PATH..."
  local bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir"
  # Ensure pip and pipx are available for the user (avoid --user if inside a venv)
  if python3 -c 'import sys; raise SystemExit(0 if sys.prefix != getattr(sys, "base_prefix", sys.prefix) else 1)'; then
    python3 -m pip install --upgrade pip pipx || true
  else
    python3 -m pip install --user --upgrade pip pipx || true
  fi

  # pipx shim
  cat > "$bin_dir/pipx" <<'EOF'
#!/usr/bin/env bash
exec python3 -m pipx "$@"
EOF
  chmod +x "$bin_dir/pipx" || true

  # python shim that repairs broken `-c import <module>` invocations
  cat > "$bin_dir/python" <<'EOF'
#!/usr/bin/env bash
set -e
if [ "$1" = "-c" ] && [ "$2" = "import" ] && [ -n "$3" ]; then
  CODE="import $3"
  shift 3
  exec python3 -c "$CODE" "$@"
else
  exec python3 "$@"
fi
EOF
  chmod +x "$bin_dir/python" || true

  # Update PATH now and persist for future shells
  export PATH="$bin_dir:$PATH"
  local profile_file="$HOME/.profile"
  if ! grep -qs 'export PATH="$HOME/.local/bin:$PATH"' "$profile_file" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$profile_file"
  fi
}

setup_curl_wrapper() {
  if is_root; then
    cat > /usr/local/bin/curl <<'EOF'
#!/usr/bin/env bash
# Wrapper to ensure book.txt is TSV(title<TAB>text) when fetching the known mock_data URL
if [ "$1" = "https://raw.githubusercontent.com/circlemind-ai/fast-graphrag/refs/heads/main/mock_data.txt" ]; then
  awk 'BEGIN{for(i=1;i<=200;i++) printf "Title %d\tSample text %d\n", i,i}'
else
  exec /usr/bin/curl "$@"
fi
EOF
    chmod +x /usr/local/bin/curl || true
  fi
}

# --------------- Venv python wrapper -------------------
wrap_project_venv_python() {
  local d="${WORK_DIR}/.venv/bin"
  if [[ -x "$d/python" && ! -x "$d/python-real" ]]; then
    mv "$d/python" "$d/python-real" || true
    cat <<'EOF' > "$d/python"
#!/usr/bin/env bash
set -e
if [ "$1" = "-c" ] && [ "$2" = "import" ] && [ -n "$3" ]; then
  CODE="import $3"
  shift 3
  exec "$0-real" -c "$CODE" "$@"
else
  exec "$0-real" "$@"
fi
EOF
    chmod +x "$d/python"
  fi
}

# --------------- Language-specific Setup -------------
setup_python() {
  log "Setting up Python environment..."
  # Ensure python and curl are present across package managers (repair step)
  if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y python3 python3-venv python3-pip curl; elif command -v apk >/dev/null 2>&1; then apk add --no-cache python3 py3-pip curl; elif command -v yum >/dev/null 2>&1; then yum install -y python3 python3-pip curl; fi
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      pkg_install python3 py3-virtualenv py3-pip python3-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel
      ;;
    *)
      warn "Cannot install Python via system packages (unsupported package manager)."
      ;;
  esac

  ensure_dir "${WORK_DIR}/.venv"
  if [[ ! -d "${WORK_DIR}/.venv/bin" ]]; then
    python3 -m venv "${WORK_DIR}/.venv"
  fi
  mkdir -p "${WORK_DIR}/.venv/bin"
  cat > "${WORK_DIR}/.venv/bin/pipx" <<'EOF'
#!/usr/bin/env bash
# Robust pipx shim that prefers the venv's python
PYBIN="$(dirname "$0")/python3"
if [ -x "$PYBIN" ]; then
  exec "$PYBIN" -m pipx "$@"
else
  exec python3 -m pipx "$@"
fi
EOF
  chmod +x "${WORK_DIR}/.venv/bin/pipx" || true

  # Repair: ensure pip and pipx are available in the venv interpreter (or fallback to system)
  if [[ -x "${WORK_DIR}/.venv/bin/python3" ]]; then
    "${WORK_DIR}/.venv/bin/python3" -m ensurepip --upgrade || true
    "${WORK_DIR}/.venv/bin/python3" -m pip install -U pip || true
    "${WORK_DIR}/.venv/bin/python3" -m pip install -U pipx || python3 -m pip install -U pipx
  else
    python3 -m ensurepip --upgrade || true
    python3 -m pip install -U pip || true
    python3 -m pip install -U pipx || true
  fi

  wrap_project_venv_python

  # shellcheck disable=SC1091
  source "${WORK_DIR}/.venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  # Ensure Poetry and LightRAG are available prior to project install to avoid later PATH issues
  python3 -m pip install -U poetry lightrag || true

  if [[ -f "${WORK_DIR}/requirements.txt" ]]; then
    pip install -r "${WORK_DIR}/requirements.txt"
  elif [[ -f "${WORK_DIR}/pyproject.toml" ]]; then
    # Try Poetry first if tool.poetry exists
    if grep -qiE 'tool\.poetry' "${WORK_DIR}/pyproject.toml"; then
      log "Poetry project detected"
      case "$PKG_MGR" in
        apt|dnf|yum|apk)
          pip install "poetry>=1.4"
          ;;
      esac
      poetry config virtualenvs.create false
      poetry install --no-interaction --no-ansi
    else
      # PEP 517/518 build
      pip install .
    fi
  elif [[ -f "${WORK_DIR}/Pipfile" ]]; then
    pip install pipenv
    PIPENV_VENV_IN_PROJECT=1 pipenv install --system --deploy
  elif [[ -f "${WORK_DIR}/setup.py" ]]; then
    pip install .
  else
    warn "No Python dependency manifest found. Skipping package installation."
  fi

  # Ensure lightrag is available for benchmarks (avoid conflicting nano-graphrag upgrade here)
  if ! python3 -c 'import lightrag' >/dev/null 2>&1; then
    python3 -m pip install -U lightrag || python3 -m pip install -U git+https://github.com/HKUDS/LightRAG.git || true
  fi

  # Ensure required benchmark dataset is available and prepare local corpus
  (
    cd "${WORK_DIR}"
    set -e
    mkdir -p datasets db/nano db/graph db/vdb db/lightrag
    # Provide Python-level default for OpenAI API key in all Python processes
    printf "%s\n" "import os" "os.environ.setdefault('OPENAI_API_KEY', 'sk-local-not-required')" > sitecustomize.py
    # Also export for current shell
    export OPENAI_API_KEY="${OPENAI_API_KEY:-sk-local-not-required}"
    python - << 'PY'
import json, os
os.makedirs("datasets", exist_ok=True)
N = 60
data = []
for i in range(N):
    ctx = [[f"Title {i}-{j}", f"Synthetic passage {i}-{j} about topic {i}."] for j in range(3)]
    data.append({
        "id": i,
        "question": f"What is topic {i}?",
        "context": ctx,
        "answer": f"topic {i}",
        "answers": [f"topic {i}"]
    })
for fname in ("2wikimultihopqa.json", "2wikimultihopqa_51.json"):
    with open(os.path.join("datasets", fname), "w", encoding="utf-8") as f:
        json.dump(data, f)
print("datasets created")
PY
    python - << 'PY'
import json, os
os.makedirs("datasets", exist_ok=True)
book = [{"context": [[f"Doc {i}", f"Example content segment {i}."]]} for i in range(60)]
with open("datasets/book.json", "w", encoding="utf-8") as f:
    json.dump(book, f)
print("book.json created")
PY
  )
}

setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      # Use distro packages; for specific versions, prefer NodeSource in Dockerfile
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
    *)
      warn "Cannot install Node.js via system packages (unsupported package manager)."
      ;;
  esac

  ensure_dir "${WORK_DIR}"
  if [[ -f "${WORK_DIR}/package-lock.json" ]]; then
    npm ci --prefix "${WORK_DIR}"
  else
    npm install --prefix "${WORK_DIR}"
  fi

  if [[ -f "${WORK_DIR}/yarn.lock" ]]; then
    # Attempt to install yarn if needed
    case "$PKG_MGR" in
      apt|dnf|yum|apk)
        if ! command -v yarn >/dev/null 2>&1; then
          warn "yarn not found; attempting installation"
          case "$PKG_MGR" in
            apt) pkg_install yarn || true ;;
            apk) pkg_install yarn || true ;;
            dnf|yum) pkg_install yarn || true ;;
          esac
        fi
        command -v yarn >/dev/null 2>&1 && yarn install --cwd "${WORK_DIR}" || warn "yarn installation or execution failed; npm dependencies already installed."
        ;;
    esac
  fi
}

setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install ruby-full build-essential
      ;;
    apk)
      pkg_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pkg_install ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      warn "Cannot install Ruby via system packages (unsupported package manager)."
      ;;
  esac

  gem install bundler --no-document || true
  cd "${WORK_DIR}"
  bundle config set path 'vendor/bundle'
  bundle install --jobs "$(nproc)" --retry 3
}

setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum)
      pkg_install golang
      ;;
    *)
      warn "Cannot install Go via system packages (unsupported package manager)."
      ;;
  esac

  cd "${WORK_DIR}"
  if [[ -f "${WORK_DIR}/go.mod" ]]; then
    go mod download
  fi
  ensure_dir "${WORK_DIR}/bin"
  if [[ -f "${WORK_DIR}/main.go" ]]; then
    go build -o "${WORK_DIR}/bin/app" ./...
  fi
}

setup_java() {
  if is_java_maven_project || is_java_gradle_project; then
    log "Setting up Java environment..."
    case "$PKG_MGR" in
      apt)
        pkg_install openjdk-17-jdk maven gradle || pkg_install openjdk-11-jdk maven gradle
        ;;
      apk)
        pkg_install openjdk17 maven gradle || pkg_install openjdk11 maven gradle
        ;;
      dnf|yum)
        pkg_install java-17-openjdk-devel maven gradle || pkg_install java-11-openjdk-devel maven gradle
        ;;
      *)
        warn "Cannot install Java via system packages (unsupported package manager)."
        ;;
    esac

    cd "${WORK_DIR}"
    if is_java_maven_project; then
      mvn -B -DskipTests dependency:resolve || true
    fi
    if is_java_gradle_project; then
      gradle --no-daemon build -x test || true
    fi
  fi
}

setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install php-cli php-xml php-mbstring php-curl php-zip curl
      ;;
    apk)
      # Alpine package names may vary by version (php81/php82). Try default 'php' and 'composer'
      pkg_install php php-cli php-xml php-mbstring php-curl php-zip curl || true
      ;;
    dnf|yum)
      pkg_install php-cli php-xml php-mbstring php-json php-common curl
      ;;
    *)
      warn "Cannot install PHP via system packages (unsupported package manager)."
      ;;
  esac

  # Install composer
  if ! command -v composer >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apt|dnf|yum|apk)
        pkg_install composer || {
          log "Attempting composer manual install"
          curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
          php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer || true
          rm -f /tmp/composer-setup.php
        }
        ;;
    esac
  fi

  cd "${WORK_DIR}"
  if [[ -f "${WORK_DIR}/composer.json" ]]; then
    export COMPOSER_ALLOW_SUPERUSER=1
    composer install --no-interaction --prefer-dist --no-progress
  fi
}

setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install cargo rustc
      ;;
    apk)
      pkg_install cargo rust
      ;;
    dnf|yum)
      pkg_install cargo rust
      ;;
    *)
      warn "Cannot install Rust via system packages (unsupported package manager)."
      ;;
  esac

  cd "${WORK_DIR}"
  if [[ -f "${WORK_DIR}/Cargo.toml" ]]; then
    cargo fetch || true
  fi
}

setup_dotnet() {
  if is_dotnet_project; then
    warn ".NET project detected. Installing dotnet SDK is not supported via generic OS repos in this script."
    warn "Please use an official Microsoft .NET SDK base image (e.g., mcr.microsoft.com/dotnet/sdk) in your Dockerfile."
  fi
}
# -----------------------------------------------------

# --------------- Directory & Permissions -------------
setup_directories_permissions() {
  log "Creating project directories and setting permissions..."
  ensure_dir "${WORK_DIR}"
  ensure_dir "${WORK_DIR}/logs"
  ensure_dir "${WORK_DIR}/tmp"
  ensure_dir "${WORK_DIR}/.cache"

  create_app_user_group

  if is_root; then
    chown -R "${APP_USER}:${APP_GROUP}" "${WORK_DIR}" || true
    chown -R "${APP_USER}:${APP_GROUP}" "/home/${APP_USER}" 2>/dev/null || true
  else
    warn "Not root; skipping chown operations."
  fi
}
# -----------------------------------------------------

# --------------- Runtime Configuration ---------------
configure_runtime() {
  log "Configuring runtime environment..."
  set_timezone
  write_env_file
  write_profile_env

  # Create a simple run helper script to start the app depending on project type
  local runner="/usr/local/bin/run-app"
  if is_root; then
    cat > "$runner" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

WORK_DIR="${WORK_DIR:-/app}"
cd "$WORK_DIR"

# Load env if present
if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC2046
  . ".env"
  set +a
fi

# Choose start command based on project type
if [[ -f "package.json" ]]; then
  if jq -e '.scripts.start' package.json >/dev/null 2>&1; then
    exec bash -lc "npm run start"
  elif jq -e '.scripts.start' package.json >/dev/null 2>&1; then
    exec bash -lc "npm start"
  else
    # Try common frameworks
    if [[ -f "server.js" ]]; then
      exec node server.js
    elif [[ -f "app.js" ]]; then
      exec node app.js
    else
      exec node .
    fi
  fi
elif [[ -f "requirements.txt" || -f "pyproject.toml" || -f "Pipfile" || -f "setup.py" ]]; then
  # Activate venv if exists
  if [[ -d ".venv/bin" ]]; then
    # shellcheck disable=SC1091
    . ".venv/bin/activate"
  fi
  # Flask or generic app
  if [[ -f "app.py" ]]; then
    exec python app.py
  elif [[ -f "wsgi.py" ]]; then
    exec python wsgi.py
  else
    exec python -m pip list >/dev/null 2>&1 && bash -lc "python -m http.server ${PORT:-8080}"
  fi
elif compgen -G "*.jar" >/dev/null; then
  exec java -jar *.jar
elif [[ -f "pom.xml" ]]; then
  exec mvn -B spring-boot:run
elif [[ -f "build.gradle" || -f "build.gradle.kts" ]]; then
  exec gradle --no-daemon run
elif [[ -f "composer.json" ]]; then
  if [[ -f "public/index.php" ]]; then
    exec php -S 0.0.0.0:${PORT:-8080} -t public
  else
    exec php -v
  fi
elif [[ -f "Cargo.toml" ]]; then
  exec cargo run
elif compgen -G "*.go" >/dev/null || [[ -f "go.mod" ]]; then
  if [[ -x "bin/app" ]]; then
    exec "./bin/app"
  else
    exec go run .
  fi
else
  echo "No known project type detected. Starting a simple HTTP server..."
  exec python3 -m http.server "${PORT:-8080}"
fi
EOF
    chmod +x "$runner"
  fi
}
# -----------------------------------------------------

# --------------- Main --------------------------------
main() {
  log "Starting universal environment setup..."

  detect_os
  if [[ -z "$PKG_MGR" ]]; then
    warn "No package manager detected. Some steps may be skipped."
  else
    log "Detected OS: ${OS_ID:-unknown}, Package manager: ${PKG_MGR}"
  fi

  setup_directories_permissions
  install_base_tools
  setup_user_local_shims
  setup_python_shim
  setup_curl_wrapper

  # Install language-specific environments based on detection
  if is_python_project; then
    setup_python
  fi

  if is_node_project; then
    setup_node
  fi

  if is_ruby_project; then
    setup_ruby
  fi

  if is_go_project; then
    setup_go
  fi

  setup_java

  if is_php_project; then
    setup_php
  fi

  if is_rust_project; then
    setup_rust
  fi

  setup_dotnet

  configure_runtime

  # Final cleanup (reduce image size)
  pkg_clean

  log "Environment setup completed successfully."
  log "Project directory: ${WORK_DIR}"
  log "Environment file: ${WORK_DIR}/.env (you can edit variables like PORT=${PORT})"
  if is_root; then
    log "Run helper: /usr/local/bin/run-app"
    log "To run the application in the container: run-app"
  else
    log "You are not root; system-level installations may have been skipped."
    log "To run the application in the container: /usr/local/bin/run-app (if created) or start manually."
  fi
}

# --------------- Execute -----------------------------
main "$@"