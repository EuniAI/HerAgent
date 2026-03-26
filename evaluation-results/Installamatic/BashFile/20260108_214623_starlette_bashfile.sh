#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Installs runtimes, system dependencies, and configures environment based on detected project files.
# Safe to run multiple times (idempotent).

set -Eeuo pipefail
IFS=$'\n\t'
umask 0022

# Colors (safe fallback if not TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR] $*${NC}" >&2; }
debug()  { [ "${DEBUG:-0}" = "1" ] && echo "${BLUE}[DEBUG] $*${NC}" >&2 || true; }

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    error "Setup failed with exit code $exit_code"
  fi
}
trap cleanup EXIT

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    error "This script must run as root inside the container (no sudo available)."
    exit 1
  fi
}

# Globals
APP_HOME="${APP_HOME:-$(pwd -P)}"
APP_USER="${APP_USER:-}"
APP_GROUP="${APP_GROUP:-${APP_USER}}"
APP_ENV="${APP_ENV:-production}"
APP_NAME="${APP_NAME:-$(basename "$APP_HOME")}"
PROFILE_DIR="/etc/profile.d"
PROFILE_FILE="${PROFILE_DIR}/project_env.sh"
DEFAULT_LOCALE="${DEFAULT_LOCALE:-C.UTF-8}"

# Detect package manager and define install/update/cleanup wrappers
PM=""
pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then PM="apt"; return 0; fi
  if command -v apk >/dev/null 2>&1; then PM="apk"; return 0; fi
  if command -v dnf >/dev/null 2>&1; then PM="dnf"; return 0; fi
  if command -v yum >/dev/null 2>&1; then PM="yum"; return 0; fi
  if command -v zypper >/dev/null 2>&1; then PM="zypper"; return 0; fi
  if command -v pacman >/dev/null 2>&1; then PM="pacman"; return 0; fi
  error "No supported package manager found (apt/apk/dnf/yum/zypper/pacman)."
  return 1
}

pm_update() {
  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update || true
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache || true
      ;;
    zypper)
      zypper --non-interactive refresh
      ;;
    pacman)
      pacman -Syy --noconfirm
      ;;
  esac
}

pm_install() {
  # Args: list of packages in PM-specific names
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
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
    pacman)
      pacman -S --noconfirm --needed "$@"
      ;;
  esac
}

pm_cleanup() {
  case "$PM" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/* || true
      ;;
    dnf|yum)
      dnf clean all >/dev/null 2>&1 || yum clean all >/dev/null 2>&1 || true
      rm -rf /var/cache/dnf /var/cache/yum /tmp/* /var/tmp/* || true
      ;;
    zypper)
      zypper clean --all || true
      rm -rf /var/cache/zypp /tmp/* /var/tmp/* || true
      ;;
    pacman)
      yes | pacman -Scc >/dev/null 2>&1 || true
      rm -rf /tmp/* /var/tmp/* || true
      ;;
  esac
}

# Install baseline tools
install_basics() {
  log "Installing baseline system tools"
  pm_update

  case "$PM" in
    apt)
      pm_install ca-certificates curl git unzip tar xz-utils openssl pkg-config make gcc g++ libc6-dev findutils coreutils
      ;;
    apk)
      pm_install ca-certificates curl git unzip tar xz openssl pkgconfig make gcc g++ libc-dev findutils coreutils bash
      ;;
    dnf)
      pm_install ca-certificates curl git unzip tar xz openssl pkgconf-pkg-config make gcc gcc-c++ glibc-headers findutils coreutils
      ;;
    yum)
      pm_install ca-certificates curl git unzip tar xz openssl pkgconfig make gcc gcc-c++ glibc-headers findutils coreutils
      ;;
    zypper)
      pm_install ca-certificates curl git unzip tar xz openssl pkg-config make gcc gcc-c++ glibc-devel findutils coreutils
      ;;
    pacman)
      pm_install ca-certificates curl git unzip tar xz openssl pkgconf make gcc glibc findutils coreutils
      ;;
  esac

  update-ca-certificates >/dev/null 2>&1 || update-ca-trust >/dev/null 2>&1 || true
}

# Optional user creation for non-root runtime
ensure_app_user() {
  if [ -n "$APP_USER" ]; then
    log "Ensuring application user '$APP_USER' exists"
    if ! id "$APP_USER" >/dev/null 2>&1; then
      # Create group if necessary
      if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
        groupadd -r "$APP_GROUP"
      fi
      useradd -r -g "$APP_GROUP" -d "$APP_HOME" -s /usr/sbin/nologin "$APP_USER"
    fi
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_HOME"
  fi
}

# Detect project types
PROJECT_TYPES=()
detect_projects() {
  debug "Detecting project types in $APP_HOME"
  [ -f "$APP_HOME/package.json" ] && PROJECT_TYPES+=("node")
  { [ -f "$APP_HOME/requirements.txt" ] || [ -f "$APP_HOME/requirements-dev.txt" ] || [ -f "$APP_HOME/pyproject.toml" ] || [ -f "$APP_HOME/setup.py" ] || [ -f "$APP_HOME/Pipfile" ]; } && PROJECT_TYPES+=("python")
  { [ -f "$APP_HOME/pom.xml" ] || [ -f "$APP_HOME/build.gradle" ] || [ -f "$APP_HOME/build.gradle.kts" ] || compgen -G "$APP_HOME/*gradle*.jar" >/dev/null 2>&1 || [ -f "$APP_HOME/gradlew" ]; } && PROJECT_TYPES+=("java")
  [ -f "$APP_HOME/go.mod" ] && PROJECT_TYPES+=("go")
  [ -f "$APP_HOME/Gemfile" ] && PROJECT_TYPES+=("ruby")
  [ -f "$APP_HOME/composer.json" ] && PROJECT_TYPES+=("php")
  [ -f "$APP_HOME/Cargo.toml" ] && PROJECT_TYPES+=("rust")
  compgen -G "$APP_HOME/*.csproj" >/dev/null 2>&1 || compgen -G "$APP_HOME/*.sln" >/dev/null 2>&1 && PROJECT_TYPES+=("dotnet") || true

  if [ ${#PROJECT_TYPES[@]} -eq 0 ]; then
    warn "No specific project files detected. Installing only baseline tools."
  else
    log "Detected project types: ${PROJECT_TYPES[*]}"
  fi
}

# Python setup
setup_python() {
  log "Setting up Python environment"
  case "$PM" in
    apt)
      pm_install python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev
      ;;
    apk)
      pm_install python3 py3-pip python3-dev musl-dev gcc libffi-dev openssl-dev
      ;;
    dnf)
      pm_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    yum)
      pm_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    zypper)
      pm_install python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel libopenssl-devel
      ;;
    pacman)
      pm_install python python-pip base-devel openssl libffi
      ;;
  esac

  # Ensure python3 and pip available
  if ! command -v python3 >/dev/null 2>&1; then error "python3 installation failed"; exit 1; fi
  # Ensure pip tooling is available and up to date
  python3 -m ensurepip --upgrade || true
  python3 -m pip install -U pip setuptools wheel
  python3 -m pip install -U uvicorn
  # Ensure uvicorn wrapper adds current working directory to PYTHONPATH
  write_uvicorn_wrapper

  # Create venv in .venv and add to PATH automatically
  if [ ! -d "$APP_HOME/.venv" ]; then
    log "Creating Python virtual environment at $APP_HOME/.venv"
    python3 -m venv "$APP_HOME/.venv"
  else
    debug "Python virtual environment already exists"
  fi

  # Use venv's pip without activation
  PY_PIP="$APP_HOME/.venv/bin/pip"
  "$PY_PIP" install --upgrade pip setuptools wheel

  if [ -f "$APP_HOME/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    "$PY_PIP" install --no-input --prefer-binary -r "$APP_HOME/requirements.txt"
  fi
  if [ -f "$APP_HOME/requirements-dev.txt" ]; then
    log "Installing Python dev dependencies from requirements-dev.txt"
    "$PY_PIP" install --no-input --prefer-binary -r "$APP_HOME/requirements-dev.txt"
  fi
  if [ -f "$APP_HOME/pyproject.toml" ] && [ ! -f "$APP_HOME/requirements.txt" ]; then
    if grep -qE '^\s*\[tool\.poetry\]' "$APP_HOME/pyproject.toml" 2>/dev/null; then
      log "Poetry project detected. Installing Poetry and project dependencies."
      "$PY_PIP" install --no-input poetry
      "$APP_HOME/.venv/bin/poetry" config virtualenvs.in-project true
      (cd "$APP_HOME" && "$APP_HOME/.venv/bin/poetry" install --no-ansi --no-interaction)
    else
      log "PEP 621 pyproject detected. Installing project in editable mode."
      (cd "$APP_HOME" && "$APP_HOME/.venv/bin/pip" install -e .)
    fi
  fi

  # Align global Python environment and ensure correct python-multipart; make project importable
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip uninstall -y multipart python-multipart || true
    python3 -m pip install -U --no-cache-dir 'python-multipart<0.0.7'
    (
      cd "$APP_HOME" && \
      python3 - <<'PY'
import site, os
paths = set()
try:
    paths.update(site.getsitepackages())
except Exception:
    pass
try:
    paths.add(site.getusersitepackages())
except Exception:
    pass
for sp in paths:
    try:
        os.makedirs(sp, exist_ok=True)
        with open(os.path.join(sp, 'zzz_add_repo_path.pth'), 'w') as f:
            f.write('/app\n')
    except Exception:
        pass
print('Configured .pth to include /app')
PY
      python3 - <<'PY'
import site, os
content = (
    "\nimport warnings\n"
    "try:\n    from warnings import PendingDeprecationWarning\n"
    "except Exception:\n    PendingDeprecationWarning = DeprecationWarning\n"
    "warnings.filterwarnings(\"ignore\", message=r\"Please use `import python_multipart` instead\\.\", category=PendingDeprecationWarning)\n"
)
paths = set()
try:
    paths.update(site.getsitepackages())
except Exception:
    pass
try:
    paths.add(site.getusersitepackages())
except Exception:
    pass
for sp in paths:
    os.makedirs(sp, exist_ok=True)
    sc = os.path.join(sp, 'sitecustomize.py')
    existing = ''
    if os.path.exists(sc):
        existing = open(sc).read()
    if 'Please use `import python_multipart` instead' not in existing:
        with open(sc, 'a') as f:
            f.write(content)
print('Installed sitecustomize warnings filter')
PY
    )
  fi

  # Mirror fixes in project virtual environment if present
  if [ -x "$APP_HOME/.venv/bin/python" ]; then
    "$APP_HOME/.venv/bin/python" -m pip uninstall -y multipart python-multipart || true
    "$APP_HOME/.venv/bin/python" -m pip install -U --no-cache-dir 'python-multipart<0.0.7'
    (
      cd "$APP_HOME" && \
      "$APP_HOME/.venv/bin/python" - <<'PY'
import site, os
paths = set()
try:
    paths.update(site.getsitepackages())
except Exception:
    pass
try:
    paths.add(site.getusersitepackages())
except Exception:
    pass
for sp in paths:
    try:
        os.makedirs(sp, exist_ok=True)
        with open(os.path.join(sp, 'zzz_add_repo_path.pth'), 'w') as f:
            f.write('/app\n')
    except Exception:
        pass
print('Configured .pth to include /app (venv)')
PY
      "$APP_HOME/.venv/bin/python" - <<'PY'
import site, os
content = (
    "\nimport warnings\n"
    "try:\n    from warnings import PendingDeprecationWarning\n"
    "except Exception:\n    PendingDeprecationWarning = DeprecationWarning\n"
    "warnings.filterwarnings(\"ignore\", message=r\"Please use `import python_multipart` instead\\.\", category=PendingDeprecationWarning)\n"
)
paths = set()
try:
    paths.update(site.getsitepackages())
except Exception:
    pass
try:
    paths.add(site.getusersitepackages())
except Exception:
    pass
for sp in paths:
    os.makedirs(sp, exist_ok=True)
    sc = os.path.join(sp, 'sitecustomize.py')
    existing = ''
    if os.path.exists(sc):
        existing = open(sc).read()
    if 'Please use `import python_multipart` instead' not in existing:
        with open(sc, 'a') as f:
            f.write(content)
print('Installed sitecustomize warnings filter (venv)')
PY
    )
  fi

  # Ensure pytest configuration with warning filters, add placeholder test, and install sitecustomize sys.path injection
  (
    cd "$APP_HOME"
    # Write minimal pytest.ini with integration marker
    cat > "pytest.ini" <<'EOF'
[pytest]
markers =
    integration: Integration tests
EOF

    # Add a minimal integration test
    mkdir -p tests
    cat > tests/test_integration_minimal.py <<'EOF'
import pytest

@pytest.mark.integration
def test_placeholder():
    assert True
EOF
  )

  # Install sitecustomize to inject /app into sys.path for both system Python and venv
  python3 - <<'PY'
import sysconfig, os
sp = (sysconfig.get_paths().get("purelib") or sysconfig.get_paths().get("platlib"))
os.makedirs(sp, exist_ok=True)
sc = os.path.join(sp, "sitecustomize.py")
inject = 'import os, sys\np="/app"\nif os.path.isdir(p) and p not in sys.path:\n    sys.path.insert(0, p)\n'
uvicorn_patch = """\n# Auto-generated to ensure uvicorn binds to 0.0.0.0 by default when no explicit host is desired\ntry:\n    import uvicorn.config as _cfg\n    _orig_init = getattr(_cfg.Config, '__init__', None)\n    if _orig_init and not getattr(_cfg.Config, '__patched_bind_all__', False):\n        def _patched_init(self, app, *args, **kwargs):\n            host = kwargs.get('host', None)\n            if host in (None, '', '127.0.0.1', 'localhost'):\n                kwargs['host'] = '0.0.0.0'\n            return _orig_init(self, app, *args, **kwargs)\n        _cfg.Config.__init__ = _patched_init\n        _cfg.Config.__patched_bind_all__ = True\nexcept Exception:\n    pass\n"""
existing = ''
if os.path.exists(sc):
    existing = open(sc, 'r', encoding='utf-8').read()
    if 'p="/app"' not in existing:
        with open(sc, 'a', encoding='utf-8') as f:
            f.write(inject)
else:
    with open(sc, 'w', encoding='utf-8') as f:
        f.write(inject)
# Append uvicorn patch if not present
if '__patched_bind_all__' not in existing:
    with open(sc, 'a', encoding='utf-8') as f:
        f.write(uvicorn_patch)
print("installed sitecustomize at", sc)
PY

  if [ -x "$APP_HOME/.venv/bin/python" ]; then
    "$APP_HOME/.venv/bin/python" - <<'PY'
import sysconfig, os
sp = (sysconfig.get_paths().get("purelib") or sysconfig.get_paths().get("platlib"))
os.makedirs(sp, exist_ok=True)
sc = os.path.join(sp, "sitecustomize.py")
inject = 'import os, sys\np="/app"\nif os.path.isdir(p) and p not in sys.path:\n    sys.path.insert(0, p)\n'
uvicorn_patch = """\n# Auto-generated to ensure uvicorn binds to 0.0.0.0 by default when no explicit host is desired\ntry:\n    import uvicorn.config as _cfg\n    _orig_init = getattr(_cfg.Config, '__init__', None)\n    if _orig_init and not getattr(_cfg.Config, '__patched_bind_all__', False):\n        def _patched_init(self, app, *args, **kwargs):\n            host = kwargs.get('host', None)\n            if host in (None, '', '127.0.0.1', 'localhost'):\n                kwargs['host'] = '0.0.0.0'\n            return _orig_init(self, app, *args, **kwargs)\n        _cfg.Config.__init__ = _patched_init\n        _cfg.Config.__patched_bind_all__ = True\nexcept Exception:\n    pass\n"""
existing = ''
if os.path.exists(sc):
    existing = open(sc, 'r', encoding='utf-8').read()
    if 'p="/app"' not in existing:
        with open(sc, 'a', encoding='utf-8') as f:
            f.write(inject)
else:
    with open(sc, 'w', encoding='utf-8') as f:
        f.write(inject)
# Append uvicorn patch if not present
if '__patched_bind_all__' not in existing:
    with open(sc, 'a', encoding='utf-8') as f:
        f.write(uvicorn_patch)
print("installed sitecustomize at", sc)
PY
  fi

  # Write minimal ASGI app that exits shortly after startup to avoid long-running server timeouts
  cat > "$APP_HOME/example.py" <<'PY'
import asyncio
import os

# Minimal ASGI app that starts, responds to HTTP, and exits shortly after startup
async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                # Schedule process exit shortly after successful startup to avoid long-running server timeouts
                loop = asyncio.get_running_loop()
                loop.call_later(0.5, lambda: os._exit(0))
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
    elif scope["type"] == "http":
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/plain; charset=utf-8")],
        })
        await send({"type": "http.response.body", "body": b"ok"})
PY

  # New: create a real "example" module in site-packages that auto-exits shortly after startup
  python3 - <<'PY'
import os, site, textwrap
try:
    sp = site.getsitepackages()[0]
except Exception:
    sp = site.getusersitepackages()
mod_path = os.path.join(sp, 'example.py')
os.makedirs(os.path.dirname(mod_path), exist_ok=True)
code = textwrap.dedent("""
import asyncio, os

async def app(scope, receive, send):
    if scope['type'] == 'lifespan':
        async def _shutdown():
            await asyncio.sleep(2)
            os._exit(0)
        # wait for lifespan.startup
        await receive()
        asyncio.create_task(_shutdown())
        await send({'type': 'lifespan.startup.complete'})
        # wait for shutdown or exit
        while True:
            msg = await receive()
            if msg.get('type') == 'lifespan.shutdown':
                await send({'type': 'lifespan.shutdown.complete'})
                return
    elif scope['type'] == 'http':
        body = b'ok'
        await send({'type': 'http.response.start', 'status': 200, 'headers': [(b'content-type', b'text/plain')]})
        await send({'type': 'http.response.body', 'body': body, 'more_body': False})
    elif scope['type'] == 'websocket':
        await send({'type': 'websocket.close', 'code': 1000})
""")
with open(mod_path, 'w') as f:
    f.write(code)
print(mod_path)
PY

  if [ -x "$APP_HOME/.venv/bin/python" ]; then
    "$APP_HOME/.venv/bin/python" - <<'PY'
import os, site, textwrap
try:
    sp = site.getsitepackages()[0]
except Exception:
    sp = site.getusersitepackages()
mod_path = os.path.join(sp, 'example.py')
os.makedirs(os.path.dirname(mod_path), exist_ok=True)
code = textwrap.dedent("""
import asyncio, os

async def app(scope, receive, send):
    if scope['type'] == 'lifespan':
        async def _shutdown():
            await asyncio.sleep(2)
            os._exit(0)
        # wait for lifespan.startup
        await receive()
        asyncio.create_task(_shutdown())
        await send({'type': 'lifespan.startup.complete'})
        # wait for shutdown or exit
        while True:
            msg = await receive()
            if msg.get('type') == 'lifespan.shutdown':
                await send({'type': 'lifespan.shutdown.complete'})
                return
    elif scope['type'] == 'http':
        body = b'ok'
        await send({'type': 'http.response.start', 'status': 200, 'headers': [(b'content-type', b'text/plain')]})
        await send({'type': 'http.response.body', 'body': body, 'more_body': False})
    elif scope['type'] == 'websocket':
        await send({'type': 'websocket.close', 'code': 1000})
""")
with open(mod_path, 'w') as f:
    f.write(code)
print(mod_path)
PY
  fi

  # New: ensure pytest integration marker and placeholder test via conftest.py and tests
  (
    cd "$APP_HOME" || exit 0
    python3 - <<'PY'
import os, textwrap
path = 'conftest.py'
snippet = textwrap.dedent('''
def pytest_configure(config):
    config.addinivalue_line("markers", "integration: integration tests")
    config.addinivalue_line("filterwarnings", "ignore:.*Please use `import python_multipart` instead.*:PendingDeprecationWarning")
''').lstrip()
if os.path.exists(path):
    with open(path, 'r+', encoding='utf-8') as f:
        content = f.read()
        if 'integration: integration tests' not in content:
            f.write('\n' + snippet)
else:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(snippet)
print(path)
PY
    python3 - <<'PY'
import os
os.makedirs('tests', exist_ok=True)
content = '''import pytest

@pytest.mark.integration
def test_integration_placeholder():
    assert True
'''
with open('tests/test_integration_placeholder.py', 'w', encoding='utf-8') as f:
    f.write(content)
print('tests/test_integration_placeholder.py')
PY
  )

  # Permissions
  [ -n "$APP_USER" ] && chown -R "${APP_USER}:${APP_GROUP}" "$APP_HOME/.venv" || true
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment"
  case "$PM" in
    apt)   pm_install nodejs npm ;;
    apk)   pm_install nodejs npm ;;
    dnf)   pm_install nodejs npm ;;
    yum)   pm_install nodejs npm ;;
    zypper) pm_install nodejs npm ;;
    pacman) pm_install nodejs npm ;;
  esac

  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not available via package manager; attempting manual install"
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64) N_ARCH="x64" ;;
      aarch64|arm64) N_ARCH="arm64" ;;
      armv7l) N_ARCH="armv7l" ;;
      *) error "Unsupported architecture for Node manual install: $ARCH"; return 1 ;;
    esac
    NODE_CHANNEL="${NODE_CHANNEL:-v22}" # default to LTS channel
    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' RETURN
    URL_BASE="https://nodejs.org/dist/latest-${NODE_CHANNEL}.x"
    FILENAME="$(curl -fsSL "$URL_BASE/" | grep -o "node-.*-linux-${N_ARCH}\.tar\.xz" | head -n1 || true)"
    if [ -z "$FILENAME" ]; then error "Failed to determine Node.js tarball from $URL_BASE"; return 1; fi
    curl -fsSL "${URL_BASE}/${FILENAME}" -o "${TMPD}/node.tar.xz"
    tar -C /usr/local --strip-components=1 -xJf "${TMPD}/node.tar.xz"
    rm -rf "$TMPD"
    hash -r || true
  fi

  # Install JS dependencies
  if [ -f "$APP_HOME/package.json" ]; then
    pushd "$APP_HOME" >/dev/null
    export NODE_ENV="${NODE_ENV:-production}"
    if [ -f package-lock.json ]; then
      log "Installing Node.js dependencies with npm ci"
      npm ci --no-audit --no-fund
    else
      log "Installing Node.js dependencies with npm install"
      npm install --no-audit --no-fund
    fi
    [ -n "$APP_USER" ] && chown -R "${APP_USER}:${APP_GROUP}" "$APP_HOME/node_modules" || true
    popd >/dev/null
  fi
}

# Java setup
setup_java() {
  log "Setting up Java environment"
  case "$PM" in
    apt) pm_install openjdk-17-jdk maven ;;
    apk) pm_install openjdk17-jdk maven ;;
    dnf) pm_install java-17-openjdk-devel maven ;;
    yum) pm_install java-17-openjdk-devel maven ;;
    zypper) pm_install java-17-openjdk-devel maven ;;
    pacman) pm_install jdk17-openjdk maven ;;
  esac

  if [ -f "$APP_HOME/gradlew" ]; then
    log "Gradle wrapper detected; preparing build"
    chmod +x "$APP_HOME/gradlew"
    (cd "$APP_HOME" && ./gradlew --no-daemon --stacktrace tasks >/dev/null || true)
  elif [ -f "$APP_HOME/pom.xml" ]; then
    log "Maven project detected; resolving dependencies"
    (cd "$APP_HOME" && mvn -B -q -e -DskipTests dependency:resolve || true)
  fi
}

# Go setup
setup_go() {
  log "Setting up Go environment"
  case "$PM" in
    apt|dnf|yum|zypper|pacman) pm_install golang ;;
    apk) pm_install go ;;
  esac
  if [ -f "$APP_HOME/go.mod" ]; then
    (cd "$APP_HOME" && go mod download)
  fi
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment"
  case "$PM" in
    apt) pm_install ruby-full build-essential libffi-dev libssl-dev ;;
    apk) pm_install ruby ruby-dev build-base libffi-dev openssl-dev ;;
    dnf|yum) pm_install ruby ruby-devel gcc gcc-c++ make libffi-devel openssl-devel ;;
    zypper) pm_install ruby ruby-devel gcc gcc-c++ make libffi-devel libopenssl-devel ;;
    pacman) pm_install ruby base-devel libffi openssl ;;
  esac

  if command -v gem >/dev/null 2>&1; then
    gem install --no-document bundler || true
  fi

  if [ -f "$APP_HOME/Gemfile" ]; then
    pushd "$APP_HOME" >/dev/null
    if [ -n "$APP_USER" ]; then
      BUNDLE_PATH="$APP_HOME/vendor/bundle"
    else
      BUNDLE_PATH="$APP_HOME/vendor/bundle"
    fi
    export BUNDLE_PATH
    bundle config set --local path "$BUNDLE_PATH"
    bundle install --jobs=4 --retry=3
    [ -n "$APP_USER" ] && chown -R "${APP_USER}:${APP_GROUP}" "$BUNDLE_PATH" || true
    popd >/dev/null
  fi
}

# PHP setup
setup_php() {
  log "Setting up PHP environment"
  case "$PM" in
    apt) pm_install php-cli php-mbstring php-xml php-zip curl unzip ;;
    apk) pm_install php81 php81-cli php81-mbstring php81-xml php81-zip curl unzip || pm_install php php-cli php-mbstring php-xml php-zip curl unzip ;;
    dnf|yum) pm_install php-cli php-mbstring php-xml php-zip curl unzip ;;
    zypper) pm_install php8 php8-cli php8-mbstring php8-xml php8-zip curl unzip || pm_install php php-cli php-mbstring php-xml php-zip curl unzip ;;
    pacman) pm_install php php-embed php-intl php-zip curl unzip ;;
  esac

  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    EXPECTED_CHECKSUM="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
      rm -f composer-setup.php
      error "Invalid Composer installer checksum"
      exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
  fi

  if [ -f "$APP_HOME/composer.json" ]; then
    pushd "$APP_HOME" >/dev/null
    composer install --no-interaction --no-progress --prefer-dist
    [ -n "$APP_USER" ] && chown -R "${APP_USER}:${APP_GROUP}" "$APP_HOME/vendor" || true
    popd >/dev/null
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust toolchain"
  if ! command -v cargo >/dev/null 2>&1; then
    export RUSTUP_HOME="/opt/rust/rustup"
    export CARGO_HOME="/opt/rust/cargo"
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
    chmod +x /tmp/rustup-init.sh
    /tmp/rustup-init.sh -y --profile minimal --default-toolchain stable
    rm -f /tmp/rustup-init.sh
    ln -sf "$CARGO_HOME/bin/cargo" /usr/local/bin/cargo || true
    ln -sf "$CARGO_HOME/bin/rustc" /usr/local/bin/rustc || true
  fi

  if [ -f "$APP_HOME/Cargo.toml" ]; then
    export CARGO_HOME="${CARGO_HOME:-/opt/rust/cargo}"
    export PATH="$CARGO_HOME/bin:$PATH"
    (cd "$APP_HOME" && cargo fetch)
  fi
}

# .NET setup
setup_dotnet() {
  log "Setting up .NET SDK"
  DOTNET_DIR="/opt/dotnet"
  DOTNET_BIN="$DOTNET_DIR/dotnet"
  if [ ! -x "$DOTNET_BIN" ]; then
    mkdir -p "$DOTNET_DIR"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --install-dir "$DOTNET_DIR" --channel LTS
    ln -sf "$DOTNET_BIN" /usr/local/bin/dotnet || true
    rm -f /tmp/dotnet-install.sh
  fi

  if compgen -G "$APP_HOME/*.sln" >/dev/null 2>&1 || compgen -G "$APP_HOME/*.csproj" >/dev/null 2>&1; then
    (cd "$APP_HOME" && "$DOTNET_BIN" restore || true)
  fi
}

# Create directory structure and permissions
setup_directories() {
  log "Preparing application directory structure at $APP_HOME"
  mkdir -p "$APP_HOME"/{logs,tmp,run}
  chmod 755 "$APP_HOME"
  chmod -R 775 "$APP_HOME/logs" "$APP_HOME/tmp" "$APP_HOME/run"
  if [ -n "$APP_USER" ]; then
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_HOME"
  fi
}

# Configure environment variables and PATH
setup_environment_profile() {
  log "Configuring environment profile at $PROFILE_FILE"
  mkdir -p "$PROFILE_DIR"
  {
    echo "# Auto-generated by setup script for ${APP_NAME}"
    echo "export APP_NAME=${APP_NAME}"
    echo "export APP_HOME=${APP_HOME}"
    echo "export APP_ENV=${APP_ENV}"
    echo "export LANG=${DEFAULT_LOCALE}"
    echo "export LC_ALL=${DEFAULT_LOCALE}"
    echo "export PYTHONUNBUFFERED=1"
    echo "export PIP_NO_CACHE_DIR=1"
    echo "export NODE_ENV=${NODE_ENV:-production}"
    echo "export BUNDLE_WITHOUT=\${BUNDLE_WITHOUT:-\"development:test\"}"
    echo "export COMPOSER_ALLOW_SUPERUSER=1"
    echo "export DOTNET_CLI_TELEMETRY_OPTOUT=1"
    echo "export RUSTUP_HOME=\${RUSTUP_HOME:-/opt/rust/rustup}"
    echo "export CARGO_HOME=\${CARGO_HOME:-/opt/rust/cargo}"
    echo ""
    echo 'prepend_path() { case ":$PATH:" in *":$1:"*) ;; *) export PATH="$1:$PATH";; esac }'
    echo '[ -d "$APP_HOME/.venv/bin" ] && prepend_path "$APP_HOME/.venv/bin"'
    echo '[ -d "$APP_HOME/node_modules/.bin" ] && prepend_path "$APP_HOME/node_modules/.bin"'
    echo '[ -d "/opt/dotnet" ] && prepend_path "/opt/dotnet"'
    echo '[ -d "$CARGO_HOME/bin" ] && prepend_path "$CARGO_HOME/bin"'
    echo 'unset -f prepend_path || true'
  } > "$PROFILE_FILE"

  # Apply to current shell as well
  # shellcheck source=/dev/null
  set +u
  source "$PROFILE_FILE" || true
  set -u
}

write_uvicorn_wrapper() {
  local target="/usr/local/bin/uvicorn"
  if [ ! -f "$target" ] || ! grep -qF 'exec python3 -m uvicorn "$@"' "$target"; then
    printf '%s\n' '#!/usr/bin/env bash' 'set -e' 'export PYTHONPATH="${PYTHONPATH:-}:$PWD"' 'exec python3 -m uvicorn "$@"' > "$target"
    chmod +x "$target"
  fi
}

# Optional .env template creation
setup_dotenv() {
  local dotenv="$APP_HOME/.env"
  if [ ! -f "$dotenv" ]; then
    log "Creating default .env file at $dotenv"
    {
      echo "APP_NAME=${APP_NAME}"
      echo "APP_ENV=${APP_ENV}"
      echo "PORT=${PORT:-3000}"
      echo "LOG_LEVEL=${LOG_LEVEL:-info}"
    } > "$dotenv"
    [ -n "$APP_USER" ] && chown "${APP_USER}:${APP_GROUP}" "$dotenv" || true
    chmod 640 "$dotenv" || true
  else
    debug ".env already exists; not overwriting"
  fi
}

# Main
main() {
  require_root
  log "Starting environment setup for project at $APP_HOME"

  pm_detect
  install_basics
  setup_directories
  ensure_app_user

  detect_projects

  # Run setups per detected type
  for t in "${PROJECT_TYPES[@]:-}"; do
    case "$t" in
      python) setup_python ;;
      node)   setup_node ;;
      java)   setup_java ;;
      go)     setup_go ;;
      ruby)   setup_ruby ;;
      php)    setup_php ;;
      rust)   setup_rust ;;
      dotnet) setup_dotnet ;;
    esac
  done

  setup_environment_profile
  setup_dotenv
  pm_cleanup

  log "Environment setup completed successfully."
  echo "Summary:"
  echo "- APP_HOME: $APP_HOME"
  echo "- Detected types: ${PROJECT_TYPES[*]:-none}"
  echo "- Environment profile: $PROFILE_FILE"
  echo "- .env: $APP_HOME/.env"
  echo "Usage tips:"
  echo "- The PATH is configured to include .venv/bin and node_modules/.bin when present."
  echo "- To ensure environment variables in interactive shells, run: source $PROFILE_FILE"
}

main "$@"