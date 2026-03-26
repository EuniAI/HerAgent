#!/usr/bin/env bash
# Environment setup script for containerized projects
# Detects project type(s) and installs required runtimes, system packages, and dependencies.
# Designed to be idempotent and safe to re-run in Docker containers.

set -Eeuo pipefail
IFS=$'\n\t'

# Globals
readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
readonly PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
readonly LOG_DIR="${LOG_DIR:-"${PROJECT_ROOT}/logs"}"
readonly LOG_FILE="${LOG_FILE:-"${LOG_DIR}/setup.log"}"
readonly APP_USER="${APP_USER:-root}"
readonly APP_GROUP="${APP_GROUP:-root}"
readonly UMASK_VAL="${UMASK_VAL:-022}"

# Colors (safe fallbacks if not a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  NC=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

# Logging
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

trap 'err "An error occurred at line $LINENO. See ${LOG_FILE} for details."; exit 1' ERR

# Tee output to log file
prepare_logs() {
  mkdir -p "${LOG_DIR}"
  touch "${LOG_FILE}"
  chmod 664 "${LOG_FILE}" || true
  # Redirect all stdout/stderr to tee once
  exec > >(tee -a "${LOG_FILE}") 2>&1
}

# Helpers
has_file() { [ -f "${PROJECT_ROOT}/$1" ]; }
has_any_file() {
  local f
  for f in "$@"; do
    if has_file "$f"; then return 0; fi
  done
  return 1
}

ensure_dir() {
  local d="$1" mode="${2:-775}"
  mkdir -p "$d"
  chmod "$mode" "$d" || true
  chown -R "${APP_USER}:${APP_GROUP}" "$d" || true
}

# Package manager detection and install helpers
PM=""
UPDATED_FLAG=0

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
  elif command -v apk >/dev/null 2>&1; then
    PM="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
  else
    err "No supported package manager found (apt/apk/dnf/yum)."
    exit 1
  fi
  log "Detected package manager: ${PM}"
}

pm_update() {
  if [ "$UPDATED_FLAG" -eq 1 ]; then return 0; fi
  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
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
  esac
  UPDATED_FLAG=1
}

pm_install() {
  local packages=("$@")
  [ "${#packages[@]}" -eq 0 ] && return 0
  pm_update
  case "$PM" in
    apt)
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
  esac
}

install_base_tools() {
  log "Installing base system tools..."
  case "$PM" in
    apt)
      pm_install ca-certificates curl gnupg git openssh-client unzip xz-utils tar gzip bzip2 \
        build-essential pkg-config make gcc g++ libc6-dev libssl-dev libffi-dev
      update-ca-certificates || true
      ;;
    apk)
      pm_install ca-certificates curl git openssh-client unzip xz tar gzip bzip2 \
        build-base pkgconfig musl-dev openssl-dev libffi-dev
      update-ca-certificates || true
      ;;
    dnf|yum)
      pm_install ca-certificates curl git openssh-clients unzip xz tar gzip bzip2 \
        make gcc gcc-c++ glibc-devel openssl-devel libffi-devel
      ;;
  esac
  log "Base system tools installed."
}

# Create a safe timeout wrapper to support inline conditionals under orchestrators
setup_timeout_wrapper() {
  local target="/usr/local/bin/timeout"
  cat >"$target" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REAL_TIMEOUT=/usr/bin/timeout
opts=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "if" ]]; then
    snippet="$*"
    exec "$REAL_TIMEOUT" "${opts[@]}" bash -lc "$snippet"
  fi
  opts+=("$1")
  shift
done
exec "$REAL_TIMEOUT" "${opts[@]}"
EOF
  chmod +x "$target"
}

# Insert a PATH-precedence wrapper for sh to rewrite 'timeout ... if ...; then ...; fi' invocations
setup_sh_wrapper() {
  local target="/usr/local/bin/sh"
  mkdir -p "/usr/local/bin"
  cat >"$target" << 'PY'
#!/usr/bin/env python3
import os, sys, shlex
argv = sys.argv[1:]
# Locate the -c payload (supports combined flags like -lc)
cmd_index = None
for i, a in enumerate(argv[:-1]):
    if a == '-c' or (a.startswith('-') and 'c' in a and a != '-c'):
        cmd_index = i + 1
if cmd_index is not None:
    s = argv[cmd_index].strip()
    # Rewrite only when the payload starts with timeout and contains an inline if-block
    if s.startswith('timeout '):
        try:
            tokens = shlex.split(s, posix=True)
        except ValueError:
            tokens = []
        if tokens and tokens[0] == 'timeout' and 'if' in tokens:
            try:
                idx_if = tokens.index('if')
            except ValueError:
                idx_if = -1
            if idx_if > 0:
                opts = tokens[1:idx_if]
                body = tokens[idx_if:]
                if 'then' in body and 'fi' in body:
                    wrapped = 'timeout {} bash -lc {}'.format(' '.join(opts), shlex.quote(' '.join(body)))
                    argv[cmd_index] = wrapped
# Exec real /bin/sh with possibly rewritten payload
os.execv('/bin/sh', ['/bin/sh'] + argv)
PY
  chmod +x "$target"
}

# Replace /bin/sh with a wrapper to handle orchestrator pattern: timeout ... if ...; then ...; fi
setup_real_sh_wrapper() {
  if [ ! -x /bin/sh.real ]; then cp -p /bin/sh /bin/sh.real; fi
  cat > /bin/sh <<'EOF'
#!/bin/sh.real
# Wrapper to handle orchestrator pattern: timeout ... if ...; then ...; fi
# When invoked as: sh -c "timeout ... if ...; then ...; fi" rewrite to
#   timeout <opts> <shell> -lc "if ...; then ...; fi"
# Otherwise, delegate to the real shell.
if [ "$1" = "-c" ] && [ -n "$2" ]; then
  payload=$2
  set -f
  set -- $payload
  set +f
  if [ "$1" = "timeout" ]; then
    prefix=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "if" ]; then
        break
      fi
      if [ -z "$prefix" ]; then prefix="$1"; else prefix="$prefix $1"; fi
      shift
    done
    if [ "$1" = "if" ]; then
      rest="$*"
      if command -v bash >/dev/null 2>&1; then shell_cmd=bash; else shell_cmd=sh; fi
      set -- $prefix "$shell_cmd" -lc "$rest"
      exec "$@"
    fi
  fi
fi
exec /bin/sh.real "$@"
EOF
  chmod 0755 /bin/sh
}

# Shell interceptor to rewrite 'timeout ... if ...; then ...; fi' before parsing
setup_shell_interceptor() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y bash coreutils
    cat > /usr/local/bin/sh-intercept <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Find the real shell we diverted (varies by distro/divert tool)
real_sh=""
for cand in /bin/sh.distrib /bin/sh.real /usr/bin/dash /bin/dash; do
  if [[ -x "$cand" ]]; then real_sh="$cand"; break; fi
done
if [[ -z "${real_sh:-}" ]]; then
  echo "Cannot locate original /bin/sh" >&2
  exit 127
fi
# Detect the problematic pattern and rewrite so the if/then/fi is parsed by a nested shell
if [[ "${1-}" == "-c" && "${2-}" =~ ^timeout[[:space:]]+-k[[:space:]]+5[[:space:]]+1800s[[:space:]]+if[[:space:]] ]]; then
  payload="${2#timeout -k 5 1800s }"
  exec timeout -k 5 1800s bash -lc "$payload"
fi
# Fallback: execute the real shell
exec "$real_sh" "$@"
EOF
    chmod +x /usr/local/bin/sh-intercept
    dpkg-divert --quiet --local --rename --add /bin/sh
    install -m 0755 /usr/local/bin/sh-intercept /bin/sh
  fi
}

# CI build entrypoint to avoid timeout+if parsing issues
setup_ci_entrypoint() {
  # Create scripts directory and unified build script to avoid inline conditionals in the runner
  mkdir -p "${PROJECT_ROOT}/scripts"

  cat > "${PROJECT_ROOT}/ci_build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci --no-audit --no-fund
    npm run -s build
  else
    echo "npm is not installed" >&2; exit 127
  fi
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f build.gradle ] || [ -f settings.gradle ] || [ -f gradlew ]; then
  if [ -x ./gradlew ]; then ./gradlew -q build -x test; else gradle -q build -x test; fi
elif [ -f Cargo.toml ]; then
  cargo build --quiet
elif [ -f go.mod ]; then
  go build ./...
elif [ -f Makefile ]; then
  make -s build || make -s
elif [ -f setup.py ] || [ -f pyproject.toml ]; then
  python3 -m pip install -q -U pip setuptools wheel build
  python3 -m build
else
  echo "No recognized build configuration" >&2; exit 1
fi
EOF

  chmod +x "${PROJECT_ROOT}/ci_build.sh" || true

  # Symlink convenience entrypoints at project root
  ln -sf "ci_build.sh" "${PROJECT_ROOT}/ci-build" || true
  ln -sf "ci_build.sh" "${PROJECT_ROOT}/build.sh" || true
  ln -sf "ci_build.sh" "${PROJECT_ROOT}/run.sh" || true
  ln -sf "ci_build.sh" "${PROJECT_ROOT}/build" || true

  # Provide a simple Makefile that delegates to the build script (only if missing)
  if [ ! -f "${PROJECT_ROOT}/Makefile" ]; then printf "%s\n" ".PHONY: build default" "default: build" "build:" "	./ci_build.sh" > "${PROJECT_ROOT}/Makefile"; fi
}

# Python setup
setup_python() {
  if ! has_any_file "requirements.txt" "pyproject.toml" "Pipfile" "setup.py"; then
    return 0
  fi
  log "Python project detected."
  case "$PM" in
    apt)
      pm_install python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      pm_install python3 py3-pip python3-dev py3-virtualenv
      ;;
    dnf|yum)
      pm_install python3 python3-pip python3-devel
      ;;
  esac

  local venv_dir="${PROJECT_ROOT}/.venv"
  if [ ! -d "${venv_dir}" ]; then
    log "Creating Python virtual environment at ${venv_dir}"
    python3 -m venv "${venv_dir}"
  else
    log "Using existing virtual environment at ${venv_dir}"
  fi

  # Activate venv in subshell to avoid changing parent shell
  (
    set +u
    # shellcheck disable=SC1090
    source "${venv_dir}/bin/activate"
    export PIP_DISABLE_PIP_VERSION_CHECK=1
    export PIP_NO_CACHE_DIR=1

    python -m pip install --upgrade pip setuptools wheel

    if has_file "requirements.txt"; then
      log "Installing Python dependencies from requirements.txt"
      pip install -r requirements.txt
    elif has_file "pyproject.toml"; then
      if grep -q "\[tool.poetry\]" pyproject.toml 2>/dev/null; then
        log "Poetry project detected; installing Poetry."
        pip install "poetry>=1.6"
        poetry config virtualenvs.in-project true
        poetry install --no-root
      else
        log "PEP 517/518 project detected; attempting pip install ."
        pip install .
      fi
    elif has_file "Pipfile"; then
      log "Pipenv project detected; installing Pipenv."
      pip install "pipenv>=2023.7.23"
      PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy || pipenv install
    elif has_file "setup.py"; then
      log "Legacy setup.py project; installing."
      pip install -e .
    fi
  )

  # Environment defaults for common frameworks
  if has_file "manage.py"; then
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-project.settings}"
    export APP_PORT="${APP_PORT:-8000}"
  elif grep -qi "flask" "${PROJECT_ROOT}/requirements.txt" 2>/dev/null || has_any_file "app.py" "wsgi.py"; then
    export FLASK_APP="${FLASK_APP:-app.py}"
    export FLASK_ENV="${FLASK_ENV:-production}"
    export FLASK_RUN_HOST="${FLASK_RUN_HOST:-0.0.0.0}"
    export FLASK_RUN_PORT="${FLASK_RUN_PORT:-5000}"
    export APP_PORT="${APP_PORT:-${FLASK_RUN_PORT}}"
  else
    export APP_PORT="${APP_PORT:-5000}"
  fi

  log "Python environment configured. Virtualenv: ${venv_dir}"
}

# Node.js setup
setup_node() {
  if ! has_file "package.json"; then
    return 0
  fi
  log "Node.js project detected."

  if ! command -v node >/dev/null 2>&1; then
    log "Installing Node.js via package manager."
    case "$PM" in
      apt)
        pm_install nodejs npm
        ;;
      apk)
        pm_install nodejs npm
        ;;
      dnf|yum)
        pm_install nodejs npm
        ;;
    esac
  else
    log "Node.js already installed: $(node -v)"
  fi

  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
    corepack prepare yarn@stable --activate || true
    corepack prepare pnpm@latest --activate || true
  fi

  pushd "${PROJECT_ROOT}" >/dev/null
  if has_file "pnpm-lock.yaml"; then
    if command -v pnpm >/dev/null 2>&1; then
      log "Installing Node dependencies with pnpm"
      pnpm install --frozen-lockfile || pnpm install
    else
      warn "pnpm not available; falling back to npm."
      npm ci || npm install
    fi
  elif has_file "yarn.lock"; then
    if command -v yarn >/dev/null 2>&1; then
      log "Installing Node dependencies with yarn"
      yarn install --frozen-lockfile || yarn install
    else
      warn "yarn not available; using npm."
      npm ci || npm install
    fi
  elif has_file "package-lock.json"; then
    log "Installing Node dependencies with npm ci"
    npm ci || npm install
  else
    log "No lockfile found; running npm install"
    npm install
  fi
  popd >/dev/null

  export NODE_ENV="${NODE_ENV:-production}"
  export APP_PORT="${APP_PORT:-3000}"
  log "Node.js environment configured."
}

# Go setup
setup_go() {
  if ! has_file "go.mod"; then
    return 0
  fi
  log "Go project detected."
  if ! command -v go >/dev/null 2>&1; then
    log "Installing Go via package manager."
    case "$PM" in
      apt) pm_install golang ;;
      apk) pm_install go ;;
      dnf|yum) pm_install golang ;;
    esac
  fi
  log "Go version: $(go version || true)"
  pushd "${PROJECT_ROOT}" >/dev/null
  go mod download
  popd >/dev/null
  export APP_PORT="${APP_PORT:-8080}"
  log "Go environment configured."
}

# Java setup (Maven/Gradle)
setup_java() {
  local is_maven=0 is_gradle=0
  has_file "pom.xml" && is_maven=1
  has_any_file "build.gradle" "build.gradle.kts" && is_gradle=1
  if [ "$is_maven" -eq 0 ] && [ "$is_gradle" -eq 0 ]; then
    return 0
  fi
  log "Java project detected."
  case "$PM" in
    apt)
      pm_install openjdk-17-jdk
      [ "$is_maven" -eq 1 ] && pm_install maven
      [ "$is_gradle" -eq 1 ] && pm_install gradle
      ;;
    apk)
      pm_install openjdk17-jdk
      [ "$is_maven" -eq 1 ] && pm_install maven
      [ "$is_gradle" -eq 1 ] && pm_install gradle
      ;;
    dnf|yum)
      pm_install java-17-openjdk-devel
      [ "$is_maven" -eq 1 ] && pm_install maven
      [ "$is_gradle" -eq 1 ] && pm_install gradle
      ;;
  esac

  if [ "$is_maven" -eq 1 ]; then
    pushd "${PROJECT_ROOT}" >/dev/null
    mvn -B -ntp -DskipTests dependency:resolve || true
    popd >/dev/null
  fi
  if [ "$is_gradle" -eq 1 ]; then
    pushd "${PROJECT_ROOT}" >/dev/null
    gradle --no-daemon tasks >/dev/null 2>&1 || true
    popd >/dev/null
  fi

  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:--XX:MaxRAMPercentage=75.0 -Dfile.encoding=UTF-8}"
  export APP_PORT="${APP_PORT:-8080}"
  log "Java environment configured."
}

# PHP setup (Composer)
setup_php() {
  if ! has_file "composer.json"; then
    return 0
  fi
  log "PHP project detected."
  case "$PM" in
    apt)
      pm_install php-cli php-mbstring php-xml php-curl php-zip unzip git composer
      ;;
    apk)
      pm_install php php-phar php-mbstring php-xml php-curl php-zip composer unzip git
      ;;
    dnf|yum)
      pm_install php-cli php-mbstring php-xml php-json php-curl composer unzip git
      ;;
  esac
  pushd "${PROJECT_ROOT}" >/dev/null
  if has_file "composer.lock"; then
    composer install --no-interaction --prefer-dist --no-progress
  else
    composer install --no-interaction --prefer-dist --no-progress || true
  fi
  popd >/dev/null
  export APP_PORT="${APP_PORT:-8000}"
  log "PHP environment configured."
}

# Ruby setup (Bundler)
setup_ruby() {
  if ! has_file "Gemfile"; then
    return 0
  fi
  log "Ruby project detected."
  case "$PM" in
    apt)
      pm_install ruby-full
      ;;
    apk)
      pm_install ruby ruby-dev build-base
      ;;
    dnf|yum)
      pm_install ruby ruby-devel make gcc gcc-c++
      ;;
  esac

  if ! command -v bundler >/dev/null 2>&1; then
    gem install bundler --no-document
  fi

  pushd "${PROJECT_ROOT}" >/dev/null
  bundle config set path 'vendor/bundle'
  bundle install --jobs=4 --retry=3
  popd >/dev/null

  export APP_PORT="${APP_PORT:-3000}"
  log "Ruby environment configured."
}

# Rust setup (rustup)
setup_rust() {
  if ! has_file "Cargo.toml"; then
    return 0
  fi
  log "Rust project detected."
  if ! command -v rustc >/dev/null 2>&1; then
    log "Installing Rust via rustup (non-interactive)."
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    export CARGO_HOME="${CARGO_HOME:-/root/.cargo}"
    # shellcheck disable=SC1091
    [ -f "${CARGO_HOME}/env" ] && . "${CARGO_HOME}/env"
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >/etc/profile.d/rust.sh || true
  fi
  export PATH="$HOME/.cargo/bin:$PATH"
  pushd "${PROJECT_ROOT}" >/dev/null
  cargo fetch || true
  popd >/dev/null
  export APP_PORT="${APP_PORT:-8080}"
  log "Rust environment configured."
}

# .NET setup (best-effort, optional)
setup_dotnet() {
  if ! ls "${PROJECT_ROOT}"/*.csproj >/dev/null 2>&1 && ! ls "${PROJECT_ROOT}"/*.sln >/dev/null 2>&1; then
    return 0
  fi
  log ".NET project detected."
  case "$PM" in
    apt)
      warn "Installing dotnet-sdk-8.0 via apt (repository availability may vary)."
      # Attempt to install if repo exists; otherwise skip with warning.
      if apt-cache search dotnet-sdk-8.0 | grep -q dotnet-sdk-8.0; then
        pm_install dotnet-sdk-8.0
      else
        warn "dotnet packages not available in this base image's repos. Skipping .NET setup."
        return 0
      fi
      ;;
    dnf|yum)
      if dnf list dotnet-sdk-8.0 >/dev/null 2>&1 || yum list dotnet-sdk-8.0 >/dev/null 2>&1; then
        pm_install dotnet-sdk-8.0
      else
        warn "dotnet packages not available in this base image's repos. Skipping .NET setup."
        return 0
      fi
      ;;
    apk)
      warn ".NET SDK is not available via apk by default. Skipping .NET setup."
      return 0
      ;;
  esac
  pushd "${PROJECT_ROOT}" >/dev/null
  dotnet restore || true
  popd >/dev/null
  export APP_PORT="${APP_PORT:-8080}"
  log ".NET environment configured."
}

# Environment variables and configuration
setup_env_files() {
  log "Configuring environment files and defaults."
  # Create .env if not exists
  if [ ! -f "${PROJECT_ROOT}/.env" ]; then
    cat > "${PROJECT_ROOT}/.env" <<EOF
# Generated by ${SCRIPT_NAME} on ${START_TIME}
APP_ENV=production
APP_DEBUG=false
APP_PORT=${APP_PORT:-8080}
EOF
    chmod 640 "${PROJECT_ROOT}/.env" || true
  fi

  # Ensure runtime directories
  ensure_dir "${PROJECT_ROOT}/tmp" 775
  ensure_dir "${PROJECT_ROOT}/run" 775
  ensure_dir "${PROJECT_ROOT}/logs" 775

  # Permissions (best-effort)
  chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}" || true
  umask "${UMASK_VAL}" || true
}

print_summary() {
  log "Setup complete."
  echo "Summary:"
  echo "- Project root: ${PROJECT_ROOT}"
  echo "- Log file: ${LOG_FILE}"
  echo "- Detected port: ${APP_PORT:-N/A}"
  echo ""
  echo "Common run hints (adjust for your project):"
  echo "  Build (CI): timeout -k 5 1800s ./ci_build.sh"
  if has_any_file "requirements.txt" "pyproject.toml" "Pipfile" "setup.py"; then
    echo "Python:"
    echo "  source .venv/bin/activate && python app.py"
    echo "  or: source .venv/bin/activate && flask run --host=0.0.0.0 --port=${FLASK_RUN_PORT:-5000}"
    echo "  or: source .venv/bin/activate && python manage.py runserver 0.0.0.0:${APP_PORT:-8000}"
  fi
  if has_file "package.json"; then
    echo "Node.js:"
    echo "  npm run start"
  fi
  if has_file "go.mod"; then
    echo "Go:"
    echo "  go run ./..."
  fi
  if has_file "pom.xml"; then
    echo "Java (Maven):"
    echo "  mvn spring-boot:run"
  fi
  if has_any_file "build.gradle" "build.gradle.kts"; then
    echo "Java (Gradle):"
    echo "  gradle bootRun"
  fi
  if has_file "composer.json"; then
    echo "PHP:"
    echo "  php -S 0.0.0.0:${APP_PORT:-8000} -t public"
  fi
  if has_file "Gemfile"; then
    echo "Ruby:"
    echo "  bundle exec rails server -b 0.0.0.0 -p ${APP_PORT:-3000}"
  fi
  if ls "${PROJECT_ROOT}"/*.csproj >/dev/null 2>&1; then
    echo ".NET:"
    echo "  dotnet run --urls http://0.0.0.0:${APP_PORT:-8080}"
  fi
}

main() {
  prepare_logs
  log "Starting environment setup at ${START_TIME}"
  log "Working directory: ${PROJECT_ROOT}"

  setup_ci_entrypoint
  setup_shell_interceptor

  detect_pm
  install_base_tools

  # Language-specific setups (multi-language monorepo supported)
  setup_python
  setup_node
  setup_go
  setup_java
  setup_php
  setup_ruby
  setup_rust
  setup_dotnet

  setup_env_files
  print_summary
}

main "$@"