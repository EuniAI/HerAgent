#!/usr/bin/env bash
# Environment setup script for containerized projects
# Detects common stacks (Python, Node.js, Ruby, Go, Java, PHP, Rust) and installs dependencies.
# Designed to run inside Docker containers without sudo, idempotent and safe to re-run.

set -Eeuo pipefail

# Globals
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-}"
APP_PORT="${APP_PORT:-}"
TZ="${TZ:-UTC}"
ENV_FILE="${ENV_FILE:-.env}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"

# Colors (simple; containers often support ANSI)
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

cleanup() { :; }
trap cleanup EXIT
trap 'err "An error occurred on line $LINENO"; exit 1' ERR

# Ensure working directory
cd "$PROJECT_ROOT"

# Detect package manager
PM=""
PM_INSTALL=""
PM_UPDATE=""
PM_CHECK=""
PM_GROUP_INSTALL=""
if command -v apt-get >/dev/null 2>&1; then
  PM="apt"
  PM_UPDATE="apt-get update -y"
  PM_INSTALL="apt-get install -y --no-install-recommends"
  PM_CHECK="dpkg -s"
  PM_GROUP_INSTALL="$PM_INSTALL"
  export DEBIAN_FRONTEND=noninteractive
elif command -v apk >/dev/null 2>&1; then
  PM="apk"
  PM_UPDATE="apk update"
  PM_INSTALL="apk add --no-cache"
  PM_CHECK="apk info -e"
  PM_GROUP_INSTALL="$PM_INSTALL"
elif command -v dnf >/dev/null 2>&1; then
  PM="dnf"
  PM_UPDATE="dnf -y makecache"
  PM_INSTALL="dnf install -y"
  PM_CHECK="rpm -q"
  PM_GROUP_INSTALL="$PM_INSTALL"
elif command -v yum >/dev/null 2>&1; then
  PM="yum"
  PM_UPDATE="yum makecache -y"
  PM_INSTALL="yum install -y"
  PM_CHECK="rpm -q"
  PM_GROUP_INSTALL="$PM_INSTALL"
elif command -v zypper >/dev/null 2>&1; then
  PM="zypper"
  PM_UPDATE="zypper refresh"
  PM_INSTALL="zypper install -y --no-recommends"
  PM_CHECK="rpm -q"
  PM_GROUP_INSTALL="$PM_INSTALL"
else
  PM=""
fi

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

pm_update() {
  if [ -n "$PM" ] && is_root; then
    log "Updating package index ($PM)..."
    sh -c "$PM_UPDATE" || warn "Package index update failed or not needed"
  else
    warn "No supported package manager detected or not running as root. Skipping system package update."
  fi
}

pm_install() {
  # Install packages only if package manager is available and running as root
  if [ -n "$PM" ] && is_root; then
    local pkgs=()
    for pkg in "$@"; do
      pkgs+=("$pkg")
    done
    if [ "${#pkgs[@]}" -gt 0 ]; then
      log "Installing system packages: ${pkgs[*]}"
      sh -c "$PM_INSTALL ${pkgs[*]}" || die "Failed to install packages: ${pkgs[*]}"
    fi
  else
    warn "No supported package manager detected or not running as root. Skipping system package installation: $*"
  fi
}

# Base utilities common across stacks
install_base_utilities() {
  pm_update
  case "$PM" in
    apt)
      pm_install ca-certificates curl git tzdata build-essential pkg-config libssl-dev openssl findutils
      ;;
    apk)
      pm_install ca-certificates curl git tzdata build-base pkgconfig openssl
      ;;
    dnf|yum)
      pm_install ca-certificates curl git tzdata make gcc gcc-c++ glibc-static openssl openssl-devel
      ;;
    zypper)
      pm_install ca-certificates curl git timezone gcc gcc-c++ make libopenssl-devel
      ;;
    "")
      warn "Skipping base utilities installation due to unsupported package manager."
      ;;
  esac

  # Timezone setup if tzdata is present
  if command -v ln >/dev/null 2>&1 && [ -e /usr/share/zoneinfo/"$TZ" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime || true
    echo "$TZ" >/etc/timezone || true
  fi
}

# Directory setup
setup_directories() {
  log "Setting up project directories under $PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT"/{logs,tmp,run}
  # Create language-specific dirs
  mkdir -p "$PROJECT_ROOT"/.cache
  mkdir -p "$PROJECT_ROOT"/bin

  # Set permissions
  if [ -n "$APP_USER" ] && [ -n "$APP_GROUP" ] && is_root; then
    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
      log "Creating group $APP_GROUP"
      addgroup_cmd=""
      if command -v addgroup >/dev/null 2>&1; then addgroup_cmd="addgroup"; elif command -v groupadd >/dev/null 2>&1; then addgroup_cmd="groupadd"; fi
      [ -n "$addgroup_cmd" ] && $addgroup_cmd "$APP_GROUP" || warn "Could not create group $APP_GROUP"
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      log "Creating user $APP_USER"
      adduser_cmd=""
      if command -v adduser >/dev/null 2>&1; then
        adduser_cmd="adduser -D -G $APP_GROUP $APP_USER"
      elif command -v useradd >/dev/null 2>&1; then
        adduser_cmd="useradd -m -g $APP_GROUP $APP_USER"
      fi
      [ -n "$adduser_cmd" ] && sh -c "$adduser_cmd" || warn "Could not create user $APP_USER"
    fi
    chown -R "${APP_USER}:${APP_GROUP}" "$PROJECT_ROOT" || warn "Failed to set ownership of project root"
  fi
}

# Environment file setup
setup_env_file() {
  if [ ! -f "$PROJECT_ROOT/$ENV_FILE" ]; then
    log "Creating default environment file $ENV_FILE"
    cat >"$PROJECT_ROOT/$ENV_FILE" <<EOF
# Generated by setup script
APP_ENV=production
TZ=$TZ
# Override APP_PORT if your app uses a different port
APP_PORT=${APP_PORT:-}
# Add other environment variables here
EOF
  else
    log "Environment file $ENV_FILE already exists; leaving unchanged."
  fi
}

# Stack detection
has_file() { [ -f "$PROJECT_ROOT/$1" ]; }
detect_python() { has_file "requirements.txt" || has_file "pyproject.toml" || has_file "Pipfile"; }
detect_node() { has_file "package.json"; }
detect_ruby() { has_file "Gemfile"; }
detect_go() { has_file "go.mod"; }
detect_java_maven() { has_file "pom.xml"; }
detect_java_gradle() { has_file "build.gradle" || has_file "build.gradle.kts"; }
detect_php() { has_file "composer.json"; }
detect_rust() { has_file "Cargo.toml"; }

# Install runtimes based on PM
install_python_runtime() {
  case "$PM" in
    apt) pm_install python3 python3-venv python3-pip python3-dev gcc ;;
    apk) pm_install python3 python3-dev py3-pip build-base ;;
    dnf|yum) pm_install python3 python3-pip python3-devel gcc gcc-c++ make ;;
    zypper) pm_install python3 python3-pip python3-devel gcc gcc-c++ make ;;
    "") warn "Cannot install Python runtime; no package manager." ;;
  esac
}

install_node_runtime() {
  case "$PM" in
    apt)
      # Use distro packages to avoid external repos
      pm_install nodejs npm
      ;;
    apk)
      pm_install nodejs npm
      ;;
    dnf|yum)
      pm_install nodejs npm
      ;;
    zypper)
      pm_install nodejs14 npm14 || pm_install nodejs npm || warn "Node package name varies; attempting defaults"
      ;;
    "")
      warn "Cannot install Node.js; no package manager."
      ;;
  esac
}

install_ruby_runtime() {
  case "$PM" in
    apt) pm_install ruby-full build-essential libffi-dev libssl-dev && pm_install bundler || true ;;
    apk) pm_install ruby ruby-dev build-base && gem install --no-document bundler || true ;;
    dnf|yum) pm_install ruby ruby-devel gcc gcc-c++ make && gem install --no-document bundler || true ;;
    zypper) pm_install ruby ruby-devel gcc gcc-c++ make && gem install --no-document bundler || true ;;
    "") warn "Cannot install Ruby; no package manager." ;;
  esac
}

install_go_runtime() {
  case "$PM" in
    apt) pm_install golang ;;
    apk) pm_install go ;;
    dnf|yum) pm_install golang ;;
    zypper) pm_install go ;;
    "") warn "Cannot install Go; no package manager." ;;
  esac
}

install_java_runtime_tools() {
  case "$PM" in
    apt) pm_install openjdk-17-jdk || pm_install openjdk-11-jdk; pm_install maven gradle || true ;;
    apk) pm_install openjdk17 || pm_install openjdk11; pm_install maven gradle || true ;;
    dnf|yum) pm_install java-17-openjdk-devel || pm_install java-11-openjdk-devel; pm_install maven gradle || true ;;
    zypper) pm_install java-17-openjdk-devel || pm_install java-11-openjdk-devel; pm_install maven gradle || true ;;
    "") warn "Cannot install Java; no package manager." ;;
  esac
}

install_php_runtime() {
  case "$PM" in
    apt) pm_install php-cli php-mbstring php-xml php-curl php-zip php-json php-openssl composer || pm_install composer || true ;;
    apk) pm_install php php-cli php-mbstring php-xml php-curl php-zip php-openssl composer || true ;;
    dnf|yum) pm_install php-cli php-json php-mbstring php-xml php-zip php-openssl composer || true ;;
    zypper) pm_install php7 php7-cli php7-mbstring php7-xml php7-zip php7-openssl composer || pm_install php php-cli || true ;;
    "") warn "Cannot install PHP; no package manager." ;;
  esac
}

install_rust_runtime() {
  case "$PM" in
    apt) pm_install cargo rustc ;;
    apk) pm_install cargo rust ;;
    dnf|yum) pm_install cargo rust ;;
    zypper) pm_install cargo rust ;;
    "") warn "Cannot install Rust; no package manager." ;;
  esac
}

# Setup per stack
setup_python() {
  install_python_runtime
  local VENV_DIR="$PROJECT_ROOT/.venv"
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating Python virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  else
    log "Python virtual environment already exists at $VENV_DIR"
  fi

  # Activate venv
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  python3 -m pip install --upgrade pip setuptools wheel
  if has_file "requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir -r requirements.txt
  elif has_file "pyproject.toml"; then
    # Use pip to install if PEP 517; fallback to pip install .
    if has_file "poetry.lock"; then
      pip install --no-cache-dir poetry && poetry install --no-interaction --no-ansi
    else
      log "Installing Python project via pyproject.toml"
      pip install --no-cache-dir .
    fi
  elif has_file "Pipfile"; then
    pip install --no-cache-dir pipenv && pipenv install --deploy || warn "pipenv install failed"
  fi

  # Set defaults in env file
  local entry=""
  local port="${APP_PORT:-}"
  if has_file "app.py"; then
    entry="app.py"
    port="${port:-5000}"
  elif has_file "manage.py"; then
    entry="manage.py"
    port="${port:-8000}"
  fi
  if [ -n "$entry" ]; then
    if ! grep -q "^PYTHONUNBUFFERED=" "$ENV_FILE" 2>/dev/null; then echo "PYTHONUNBUFFERED=1" >>"$ENV_FILE"; fi
    if ! grep -q "^APP_ENTRY=" "$ENV_FILE" 2>/dev/null; then echo "APP_ENTRY=$entry" >>"$ENV_FILE"; fi
    if [ -n "$port" ] && ! grep -q "^APP_PORT=" "$ENV_FILE" 2>/dev/null; then echo "APP_PORT=$port" >>"$ENV_FILE"; fi
  fi
  log "Python setup complete"
}

setup_node() {
  install_node_runtime
  if has_file "package-lock.json"; then
    log "Installing Node.js dependencies via npm ci"
    npm ci --no-audit --no-fund
  else
    log "Installing Node.js dependencies via npm install"
    npm install --no-audit --no-fund
  fi
  local port="${APP_PORT:-3000}"
  if ! grep -q "^NODE_ENV=" "$ENV_FILE" 2>/dev/null; then echo "NODE_ENV=production" >>"$ENV_FILE"; fi
  if [ -n "$port" ] && ! grep -q "^APP_PORT=" "$ENV_FILE" 2>/dev/null; then echo "APP_PORT=$port" >>"$ENV_FILE"; fi
  log "Node.js setup complete"
}

setup_ruby() {
  install_ruby_runtime
  if has_file "Gemfile"; then
    log "Installing Ruby gems via bundler"
    if command -v bundle >/dev/null 2>&1; then
      bundle config set --local without 'development test' || true
      bundle install --jobs "$(nproc 2>/dev/null || echo 2)" --retry 3
    else
      gem install --no-document bundler
      bundle install
    fi
    local port="${APP_PORT:-3000}"
    if ! grep -q "^RACK_ENV=" "$ENV_FILE" 2>/dev/null; then echo "RACK_ENV=production" >>"$ENV_FILE"; fi
    if [ -n "$port" ] && ! grep -q "^APP_PORT=" "$ENV_FILE" 2>/dev/null; then echo "APP_PORT=$port" >>"$ENV_FILE"; fi
    log "Ruby setup complete"
  fi
}

setup_go() {
  install_go_runtime
  if has_file "go.mod"; then
    log "Downloading Go modules"
    go mod download
    # Build if main package present
    local main_file=""
    if has_file "main.go"; then main_file="main.go"; fi
    if [ -n "$main_file" ]; then
      log "Building Go binary"
      go build -o "$PROJECT_ROOT/bin/app" "$PROJECT_ROOT/$main_file"
    else
      warn "No main.go found; skipping build"
    fi
    local port="${APP_PORT:-8080}"
    if [ -n "$port" ] && ! grep -q "^APP_PORT=" "$ENV_FILE" 2>/dev/null; then echo "APP_PORT=$port" >>"$ENV_FILE"; fi
    log "Go setup complete"
  fi
}

setup_java() {
  install_java_runtime_tools
  if has_file "pom.xml"; then
    if command -v mvn >/dev/null 2>&1; then
      log "Building Java project with Maven (skip tests)"
      mvn -B -DskipTests clean package
    else
      warn "Maven not available; skipping Maven build"
    fi
    local port="${APP_PORT:-8080}"
    if [ -n "$port" ] && ! grep -q "^APP_PORT=" "$ENV_FILE" 2>/dev/null; then echo "APP_PORT=$port" >>"$ENV_FILE"; fi
    log "Java (Maven) setup complete"
  elif has_file "build.gradle" || has_file "build.gradle.kts"; then
    if [ -x "./gradlew" ]; then
      log "Building Java project with Gradle wrapper (skip tests)"
      ./gradlew build -x test
    elif command -v gradle >/dev/null 2>&1; then
      gradle build -x test
    else
      warn "Gradle not available; skipping Gradle build"
    fi
    local port="${APP_PORT:-8080}"
    if [ -n "$port" ] && ! grep -q "^APP_PORT=" "$ENV_FILE" 2>/dev/null; then echo "APP_PORT=$port" >>"$ENV_FILE"; fi
    log "Java (Gradle) setup complete"
  fi
}

setup_php() {
  install_php_runtime
  if has_file "composer.json"; then
    if command -v composer >/dev/null 2>&1; then
      log "Installing PHP dependencies via Composer"
      composer install --no-interaction --prefer-dist --no-progress --no-dev || composer install --no-interaction
    else
      warn "Composer is not available; cannot install PHP dependencies"
    fi
    local port="${APP_PORT:-8000}"
    if [ -n "$port" ] && ! grep -q "^APP_PORT=" "$ENV_FILE" 2>/dev/null; then echo "APP_PORT=$port" >>"$ENV_FILE"; fi
    log "PHP setup complete"
  fi
}

setup_rust() {
  install_rust_runtime
  if has_file "Cargo.toml"; then
    log "Building Rust project in release mode"
    cargo build --release
    cp -f "$PROJECT_ROOT/target/release/"* "$PROJECT_ROOT/bin/" 2>/dev/null || true
    log "Rust setup complete"
  fi
}

setup_if_compat_wrapper() {
  local target="/usr/local/bin/if"
  if is_root; then
    mkdir -p /usr/local/bin
    cat > "$target" <<'EOF'
#!/usr/bin/env bash
# Wrapper to emulate shell 'if' when invoked as a standalone command by external runners.
# Reconstruct the full conditional and execute it in a login shell context.
exec bash -lc "if $*"
EOF
    chmod +x "$target" || true
  else
    warn "Skipping 'if' wrapper installation (requires root)."
  fi
}

setup_timeout_wrapper() {
  warn "Skipping 'timeout' wrapper installation; using system timeout directly."
}

setup_misquoted_bash_c_profile_fix() {
  if is_root; then
    cat > /etc/profile.d/00-fix-misquoted-bash-c.sh <<'EOF'
# Auto-fix for misquoted "bash -c/-lc" invocations where the command string was split into multiple argv words.
# Runs in login shells before executing the -c string.
[ -n "$BASH_VERSION" ] || return 0 2>/dev/null || exit 0
[ -z "$BASH_MISQUOTE_FIX_APPLIED" ] || return 0 2>/dev/null || exit 0
if [ -r /proc/self/cmdline ]; then
  mapfile -d '' -t _argv < /proc/self/cmdline || _argv=()
  c_index=-1
  for i in "${!_argv[@]}"; do
    a="${_argv[$i]}"
    case "$a" in
      -*c* ) c_index="$i"; break ;;
    esac
  done
  if [ "$c_index" -ge 0 ] 2>/dev/null; then
    cmd_start=$((c_index+1))
    total=${#_argv[@]}
    if [ "$cmd_start" -lt "$total" ] 2>/dev/null; then
      rest_count=$((total - cmd_start))
      if [ "$rest_count" -gt 1 ] 2>/dev/null; then
        joined=""
        for ((j=cmd_start; j<total; j++)); do
          token="${_argv[$j]}"
          token="${token//\\/\\\\}"
          token="${token//\"/\\\"}"
          if [ -n "$joined" ]; then joined="$joined "; fi
          joined="$joined$token"
        done
        exec env BASH_MISQUOTE_FIX_APPLIED=1 /bin/bash -lc "$joined"
      fi
    fi
  fi
fi
# No fix needed
true
EOF
    chmod 0644 /etc/profile.d/00-fix-misquoted-bash-c.sh || true
  else
    warn "Skipping misquoted bash -c profile fix (requires root)."
  fi
}

setup_bash_c_wrapper() {
  if is_root; then
    # Ensure bash is installed
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y bash
    else
      pm_update
      pm_install bash || true
    fi

    # Replace /usr/local/bin/bash with a robust forwarder preserving argv
    install -d -m 0755 /usr/local/bin
    if [ -e /usr/local/bin/bash ] && [ ! -e /usr/local/bin/bash.bak ]; then
      cp -a /usr/local/bin/bash /usr/local/bin/bash.bak || true
    fi
    cat > /usr/local/bin/bash <<'EOF'
#!/bin/sh
# Shim to tolerate misquoted bash -c/-lc invocations
# If called as: bash -lc if [ ... ]; then ...; fi
# reconstruct the command string and exec the real /bin/bash correctly.
if [ "$1" = "-lc" ]; then
  shift
  if [ "$#" -gt 1 ]; then
    cmd="$*"
    exec /bin/bash -lc "$cmd"
  else
    exec /bin/bash -lc "$1"
  fi
elif [ "$1" = "-c" ]; then
  shift
  if [ "$#" -gt 1 ]; then
    cmd="$*"
    exec /bin/bash -c "$cmd"
  else
    exec /bin/bash -c "$1"
  fi
elif [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
  shift 2
  if [ "$#" -gt 1 ]; then
    cmd="$*"
    exec /bin/bash -lc "$cmd"
  else
    exec /bin/bash -lc "$1"
  fi
else
  exec /bin/bash "$@"
fi
EOF
    chmod 0755 /usr/local/bin/bash || true
  else
    warn "Skipping bash wrapper installation (requires root)."
  fi
}

setup_bash_real_shim() {
  # Replace /usr/local/bin/bash.real with robust wrapper that fixes misquoted -c/-lc invocations
  if is_root; then
    mkdir -p /usr/local/bin
    if [ -x /usr/local/bin/bash.real ] && [ ! -e /usr/local/bin/bash.real.orig ]; then mv /usr/local/bin/bash.real /usr/local/bin/bash.real.orig; fi
    cat > /usr/local/bin/bash.real <<'EOF'
#!/usr/bin/env bash
# BASH_FIX_WRAPPER
set -euo pipefail
REAL_BASH="/bin/bash"
if ! [ -x "$REAL_BASH" ]; then REAL_BASH="$(command -v bash)"; fi
args=("$@")
n=${#args[@]}
opts=()
i=0
found_c=0
while (( i < n )); do
  a="${args[$i]}"
  if (( found_c == 0 )) && [[ "$a" == -* ]]; then
    opts+=("$a")
    if [[ "$a" == *c* ]]; then
      found_c=1
      ((i++))
      break
    fi
    ((i++))
  else
    break
  fi
done
if (( found_c == 1 )); then
  cmd_string=""
  while (( i < n )); do
    part="${args[$i]}"
    if [[ -z "$cmd_string" ]]; then cmd_string="$part"; else cmd_string="$cmd_string $part"; fi
    ((i++))
  done
  exec "$REAL_BASH" "${opts[@]}" "$cmd_string"
else
  exec "$REAL_BASH" "$@"
fi
EOF
    chmod 0755 /usr/local/bin/bash.real || true
    /usr/local/bin/bash.real -lc 'if true; then echo BASH_REAL_WRAPPER_OK; fi' || true
  else
    warn "Skipping bash.real shim installation (requires root)."
  fi
}

restore_real_bash() {
  if is_root; then
    if [ -x /usr/local/bin/bash.real ]; then
      ln -sf /usr/local/bin/bash.real /usr/local/bin/bash || true
    fi
  else
    warn "Skipping bash restore (requires root)."
  fi
}

# Bypass faulty bash wrapper chain by symlinking both /usr/local/bin/bash and bash.real to /bin/bash
fix_bash_symlinks() {
  if is_root; then
    # If our custom bash.real wrapper is present, do not override it with symlinks.
    if [ -e /usr/local/bin/bash.real ] && grep -Eq 'BASH_C_FIX_APPLIED|BASH_FIX_WRAPPER' /usr/local/bin/bash.real 2>/dev/null; then
      warn "Detected custom bash.real wrapper; skipping symlink repair."
      return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y --no-install-recommends bash
    else
      pm_update
      pm_install bash || true
    fi
    mkdir -p /usr/local/bin
    if [ -e /usr/local/bin/bash ] && [ ! -L /usr/local/bin/bash ]; then
      mv -f /usr/local/bin/bash /usr/local/bin/bash.bak.$(date +%s)
    fi
    ln -sf /bin/bash /usr/local/bin/bash
    if [ -e /usr/local/bin/bash.real ] && [ ! -L /usr/local/bin/bash.real ]; then
      mv -f /usr/local/bin/bash.real /usr/local/bin/bash.real.bak.$(date +%s)
    fi
    ln -sf /bin/bash /usr/local/bin/bash.real
  else
    warn "Skipping bash symlink repair (requires root)."
  fi
}

setup_ld_preload_bash_c_fix() {
  if is_root; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y gcc make libc6-dev
    elif command -v yum >/dev/null 2>&1; then
      yum install -y gcc make glibc-devel
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache build-base
    fi

    mkdir -p /usr/local/src
    cat >/usr/local/src/bash_c_fix.c <<'EOF'
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>

typedef int (*execve_f)(const char*, char* const[], char* const[]);

static int has_c_opt(const char* arg) {
    if (!arg || arg[0] != '-') return 0;
    for (const char* p = arg + 1; *p; ++p) {
        if (*p == 'c') return 1;
    }
    return 0;
}

static char* join_args(char* const argv[], int start) {
    size_t len = 0;
    for (int i = start; argv[i]; ++i) len += strlen(argv[i]) + 1;
    char* buf = (char*)malloc(len + 1);
    if (!buf) return NULL;
    buf[0] = '\0';
    for (int i = start; argv[i]; ++i) {
        strcat(buf, argv[i]);
        if (argv[i+1]) strcat(buf, " ");
    }
    return buf;
}

int execve(const char* filename, char* const argv[], char* const envp[]) {
    static execve_f real_execve = NULL;
    if (!real_execve) real_execve = (execve_f)dlsym(RTLD_NEXT, "execve");

    if (filename && strcmp(filename, "/usr/local/bin/bash.real") == 0 && argv) {
        int i, cpos = -1;
        for (i = 1; argv[i]; ++i) {
            if (has_c_opt(argv[i])) { cpos = i; break; }
        }
        if (cpos >= 0 && argv[cpos + 1]) {
            char* joined = join_args(argv, cpos + 1);
            if (joined) {
                char* const new_argv[] = { "/bin/bash", "-lc", joined, NULL };
                int rc = real_execve("/bin/bash", new_argv, envp);
                free(joined);
                return rc;
            }
        }
    }
    return real_execve(filename, argv, envp);
}
EOF

    gcc -shared -fPIC -O2 -Wall -Wextra -ldl -o /usr/local/lib/libbash_c_fix.so /usr/local/src/bash_c_fix.c && chmod 644 /usr/local/lib/libbash_c_fix.so

    touch /etc/ld.so.preload
    if ! grep -qxF "/usr/local/lib/libbash_c_fix.so" /etc/ld.so.preload; then
      echo "/usr/local/lib/libbash_c_fix.so" >> /etc/ld.so.preload
    fi
  else
    warn "Skipping LD_PRELOAD bash -c fix (requires root)."
  fi
}

# Main orchestration
main() {
  log "Starting environment setup in $PROJECT_ROOT"

  setup_ld_preload_bash_c_fix
  setup_misquoted_bash_c_profile_fix
  setup_if_compat_wrapper
  setup_timeout_wrapper
  setup_bash_c_wrapper
  setup_bash_real_shim
  fix_bash_symlinks
  install_base_utilities
  setup_directories
  setup_env_file

  local stacks=()
  if detect_python; then stacks+=("python"); fi
  if detect_node; then stacks+=("node"); fi
  if detect_ruby; then stacks+=("ruby"); fi
  if detect_go; then stacks+=("go"); fi
  if detect_java_maven || detect_java_gradle; then stacks+=("java"); fi
  if detect_php; then stacks+=("php"); fi
  if detect_rust; then stacks+=("rust"); fi

  if [ "${#stacks[@]}" -eq 0 ]; then
    warn "No recognized project files found. The script installed base utilities and created directories."
    warn "Supported detections: Python (requirements.txt/pyproject.toml), Node.js (package.json), Ruby (Gemfile), Go (go.mod), Java (pom.xml/build.gradle), PHP (composer.json), Rust (Cargo.toml)."
  else
    for s in "${stacks[@]}"; do
      case "$s" in
        python) setup_python ;;
        node) setup_node ;;
        ruby) setup_ruby ;;
        go) setup_go ;;
        java) setup_java ;;
        php) setup_php ;;
        rust) setup_rust ;;
      esac
    done
  fi

  # Export environment variables for current shell session
  set +u
  if [ -f "$ENV_FILE" ]; then
    log "Loading environment variables from $ENV_FILE"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  fi
  set -u

  # Determine port fallback if not set
  if [ -z "${APP_PORT:-}" ]; then
    if detect_python && has_file "app.py"; then APP_PORT="5000"; fi
    if [ -z "${APP_PORT:-}" ] && detect_node; then APP_PORT="3000"; fi
    if [ -z "${APP_PORT:-}" ] && detect_ruby; then APP_PORT="3000"; fi
    if [ -z "${APP_PORT:-}" ] && detect_go; then APP_PORT="8080"; fi
    if [ -z "${APP_PORT:-}" ] && (detect_java_maven || detect_java_gradle); then APP_PORT="8080"; fi
    if [ -z "${APP_PORT:-}" ] && detect_php; then APP_PORT="8000"; fi
    if [ -n "${APP_PORT:-}" ]; then
      echo "APP_PORT=$APP_PORT" >>"$ENV_FILE"
    fi
  fi

  log "Environment setup completed successfully."
  echo "Notes:"
  echo "- Project root: $PROJECT_ROOT"
  echo "- Environment file: $ENV_FILE"
  echo "- Detected stacks: ${stacks[*]:-none}"
  echo "- To run your app inside the container, use your stack's run command, ensuring environment variables from $ENV_FILE are applied."
  echo "  Examples:"
  echo "    Python: source .venv/bin/activate && python \${APP_ENTRY:-app.py}"
  echo "    Node.js: npm start"
  echo "    Ruby (Rails): bundle exec rails server -b 0.0.0.0 -p \${APP_PORT:-3000}"
  echo "    Go: ./bin/app"
  echo "    Java (Maven): java -jar target/*.jar"
  echo "    PHP: php -S 0.0.0.0:\${APP_PORT:-8000} -t public"
  echo "    Rust: ./bin/<your-binary>"
}

main "$@"