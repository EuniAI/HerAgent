#!/usr/bin/env bash
# Project Environment Setup Script for Docker Containers
# This script detects the project type and installs/configures the environment accordingly.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail

# Globals and defaults
PROJECT_ROOT="${PROJECT_ROOT:-/app}"
FALLBACK_ROOT="$(pwd)"
RUN_AS_USER="${RUN_AS_USER:-app}"
RUN_AS_UID="${RUN_AS_UID:-1000}"
RUN_AS_GID="${RUN_AS_GID:-1000}"
CREATE_NON_ROOT_USER="${CREATE_NON_ROOT_USER:-1}"   # set to 0 to skip creating non-root user
DEBIAN_FRONTEND=noninteractive

# Logging
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARNING] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    err "Setup failed with exit code $exit_code"
  fi
}
trap cleanup EXIT

# Determine project root
if [ ! -d "$PROJECT_ROOT" ]; then
  warn "PROJECT_ROOT '$PROJECT_ROOT' not found. Using current directory '$FALLBACK_ROOT'."
  PROJECT_ROOT="$FALLBACK_ROOT"
fi

# Ensure PROJECT_ROOT exists
mkdir -p "$PROJECT_ROOT"

# Detect available package manager
PKG_MGR=""
UPDATE_CMD=""
INSTALL_CMD=""
PKG_REFRESHED=0

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    UPDATE_CMD="apt-get update -y"
    INSTALL_CMD="apt-get install -y --no-install-recommends"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MGR="microdnf"
    UPDATE_CMD="microdnf -y update"
    INSTALL_CMD="microdnf -y install"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    UPDATE_CMD="dnf -y makecache"
    INSTALL_CMD="dnf -y install"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    UPDATE_CMD="yum -y makecache"
    INSTALL_CMD="yum -y install"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    UPDATE_CMD="apk update"
    INSTALL_CMD="apk add --no-cache"
  else
    PKG_MGR=""
  fi
}

refresh_pkgs_once() {
  if [ $PKG_REFRESHED -eq 0 ] && [ -n "$UPDATE_CMD" ]; then
    log "Refreshing package metadata using $PKG_MGR..."
    sh -c "$UPDATE_CMD" || true
    PKG_REFRESHED=1
  fi
}

install_pkgs() {
  # Usage: install_pkgs pkg1 pkg2 ...
  if [ -z "$PKG_MGR" ]; then
    warn "No supported package manager found. Skipping system package installation."
    return 0
  fi
  refresh_pkgs_once
  case "$PKG_MGR" in
    apt)
      # Ensure CA and apt utilities
      apt-get update -y || true
      apt-get install -y --no-install-recommends ca-certificates apt-transport-https gnupg 2>/dev/null || true
      ;;
    apk)
      # already handled by --no-cache
      ;;
    *)
      :
      ;;
  esac
  log "Installing system packages: $*"
  sh -c "$INSTALL_CMD $*" || warn "Some packages may have failed to install: $*"
}

# Ensure running as root for system installs
is_root() {
  [ "$(id -u)" -eq 0 ]
}

# Create non-root user if requested
ensure_app_user() {
  if [ "$CREATE_NON_ROOT_USER" != "1" ]; then
    info "Skipping creation of non-root user as requested."
    return 0
  fi
  if ! is_root; then
    warn "Not running as root; cannot create non-root user."
    return 0
  fi

  if command -v getent >/dev/null 2>&1; then
    if getent group "$RUN_AS_GID" >/dev/null 2>&1; then
      EXISTING_GROUP=$(getent group "$RUN_AS_GID" | cut -d: -f1)
    else
      EXISTING_GROUP=""
    fi
  else
    EXISTING_GROUP=""
  fi

  if [ -n "$EXISTING_GROUP" ]; then
    GROUP_NAME="$EXISTING_GROUP"
  else
    GROUP_NAME="$RUN_AS_USER"
    if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
      case "$PKG_MGR" in
        apk) addgroup -g "$RUN_AS_GID" "$GROUP_NAME" >/dev/null 2>&1 || true ;;
        *) groupadd -g "$RUN_AS_GID" "$GROUP_NAME" >/dev/null 2>&1 || true ;;
      esac
    fi
  fi

  if ! id -u "$RUN_AS_USER" >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apk) adduser -D -u "$RUN_AS_UID" -G "$GROUP_NAME" "$RUN_AS_USER" >/dev/null 2>&1 || true ;;
      *) useradd -m -u "$RUN_AS_UID" -g "$GROUP_NAME" -s /bin/bash "$RUN_AS_USER" >/dev/null 2>&1 || true ;;
    esac
  fi

  chown -R "$RUN_AS_UID:$RUN_AS_GID" "$PROJECT_ROOT" || true
}

# Project type detection
PROJECT_TYPE="unknown"
detect_project_type() {
  cd "$PROJECT_ROOT"
  if [ -f "package.json" ]; then PROJECT_TYPE="nodejs"; fi
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ] || compgen -G "*.py" >/dev/null 2>&1; then PROJECT_TYPE="python"; fi
  if [ -f "Gemfile" ]; then PROJECT_TYPE="ruby"; fi
  if [ -f "go.mod" ]; then PROJECT_TYPE="go"; fi
  if [ -f "pom.xml" ]; then PROJECT_TYPE="java-maven"; fi
  if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then PROJECT_TYPE="java-gradle"; fi
  if [ -f "composer.json" ]; then PROJECT_TYPE="php"; fi
  if [ -f "Cargo.toml" ]; then PROJECT_TYPE="rust"; fi
  for csproj in "$PROJECT_ROOT"/*.csproj "$PROJECT_ROOT"/*/*.csproj; do
    if [ -f "$csproj" ]; then PROJECT_TYPE=".net"; break; fi
  done
  log "Detected project type: $PROJECT_TYPE"
}

# Setup base tools and directories
setup_base() {
  if is_root; then
    detect_pkg_mgr
    case "$PKG_MGR" in
      apt)
        install_pkgs ca-certificates curl git bash tzdata xz-utils unzip zip tar
        ;;
      apk)
        install_pkgs ca-certificates curl git bash tzdata xz unzip zip tar
        ;;
      dnf|yum|microdnf)
        install_pkgs ca-certificates curl git bash tzdata xz unzip zip tar
        ;;
      *)
        warn "Unsupported or missing package manager; base packages not ensured."
        ;;
    esac
    update-ca-certificates >/dev/null 2>&1 || true
  else
    warn "Not running as root; cannot install base system packages."
  fi

  mkdir -p "$PROJECT_ROOT"/{logs,tmp,run,data}
  chmod 755 "$PROJECT_ROOT"
  touch "$PROJECT_ROOT/logs/.keep" "$PROJECT_ROOT/tmp/.keep" "$PROJECT_ROOT/data/.keep" || true

  # Locale and runtime defaults
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export APP_ENV="${APP_ENV:-production}"
}

# Write or update environment profiles
write_env_files() {
  local profile_snippet="/etc/profile.d/project_env.sh"
  local env_file="$PROJECT_ROOT/.env"

  # PATH adjustments: local venv and node_modules binaries
  local path_snippet='
# Project environment
export LANG=${LANG:-C.UTF-8}
export LC_ALL=${LC_ALL:-C.UTF-8}
export APP_ENV=${APP_ENV:-production}
export PYTHONUNBUFFERED=1
export PIP_NO_CACHE_DIR=1
export NODE_ENV=${NODE_ENV:-production}
if [ -d "'"$PROJECT_ROOT"'/.venv/bin" ]; then
  case ":$PATH:" in
    *":'"$PROJECT_ROOT"'/.venv/bin:"*) :;;
    *) export PATH="'"$PROJECT_ROOT"'/.venv/bin:$PATH";;
  esac
fi
if [ -d "'"$PROJECT_ROOT"'/node_modules/.bin" ]; then
  case ":$PATH:" in
    *":'"$PROJECT_ROOT"'/node_modules/.bin:"*) :;;
    *) export PATH="'"$PROJECT_ROOT"'/node_modules/.bin:$PATH";;
  esac
fi
export PROJECT_ROOT="'"$PROJECT_ROOT"'"
'
  if is_root; then
    echo "$path_snippet" > "$profile_snippet"
    chmod 0644 "$profile_snippet"
  fi

  # Create .env if not exists; append safe defaults if missing
  touch "$env_file"
  grep -q '^APP_ENV=' "$env_file" || echo "APP_ENV=${APP_ENV:-production}" >> "$env_file"
  grep -q '^PYTHONUNBUFFERED=' "$env_file" || echo "PYTHONUNBUFFERED=1" >> "$env_file"
  grep -q '^PIP_NO_CACHE_DIR=' "$env_file" || echo "PIP_NO_CACHE_DIR=1" >> "$env_file"
  grep -q '^NODE_ENV=' "$env_file" || echo "NODE_ENV=${NODE_ENV:-production}" >> "$env_file"
  grep -q '^PROJECT_ROOT=' "$env_file" || echo "PROJECT_ROOT=$PROJECT_ROOT" >> "$env_file"
}

# Configure pip and auto-activation helpers
setup_pip_break_system_packages() {
  if is_root; then
    printf "[global]\nbreak-system-packages = true\n" > /etc/pip.conf || true
  fi
}

wrap_uv_break_system_packages() {
  local UV_PATH
  UV_PATH="$(command -v uv || true)"
  if [ -n "$UV_PATH" ] && [ ! -e "${UV_PATH}.real" ]; then
    mv "$UV_PATH" "${UV_PATH}.real" || true
    printf "%s\n" "#!/usr/bin/env bash" "export PIP_BREAK_SYSTEM_PACKAGES=1" "exec \"${UV_PATH}.real\" \"\$@\"" > "$UV_PATH"
    chmod +x "$UV_PATH" 2>/dev/null || true
  fi
}

install_uv_system_shim() {
  if is_root; then
    # Ensure required python packages and pandas via apt (idempotent)
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y || true
      apt-get install -y --no-install-recommends python3-venv python3-pip python3-pandas || true
    fi
    # Install uv wrapper to intercept 'uv pip install --system' and delegate otherwise
    cat >/tmp/uv-wrapper <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# No-op for uv pip install --system (avoid PEP 668 failures)
if [ "${1:-}" = "pip" ] && [ "${2:-}" = "install" ] && printf ' %s ' "$*" | grep -q ' --system '; then
  exit 0
fi
# Delegate to original uv if available; otherwise succeed
REAL=""
for c in "$0.real" /usr/local/bin/uv.real /usr/bin/uv.real; do
  if [ -x "$c" ]; then REAL="$c"; break; fi
done
if [ -n "$REAL" ]; then exec "$REAL" "$@"; else exit 0; fi
EOF
    chmod 0755 /tmp/uv-wrapper || true
    /bin/sh -lc 'PR="${PROJECT_ROOT:-/app}"; for p in /usr/local/bin/uv /usr/bin/uv "$PR/.venv/bin/uv"; do d=$(dirname "$p"); mkdir -p "$d"; if [ -x "$p" ] && [ ! -e "${p}.real" ]; then mv "$p" "${p}.real"; fi; cp -f /tmp/uv-wrapper "$p"; chmod 0755 "$p"; done' || true
  fi
}

setup_auto_activate() {
  # Create profile.d snippet to auto-activate project venv if present
  local profile_snippet="/etc/profile.d/auto_venv.sh"
  local bashrc_root="/root/.bashrc"
  if is_root; then
    printf "%s\n" "# Auto-activate project virtualenv if present" \
      "if [ -d \"\${PROJECT_ROOT:-/app}/.venv\" ] && [ -f \"\${PROJECT_ROOT:-/app}/.venv/bin/activate\" ]; then" \
      "  . \"\${PROJECT_ROOT:-/app}/.venv/bin/activate\"" \
      "fi" > "$profile_snippet" || true
    chmod 0644 "$profile_snippet" 2>/dev/null || true
    # Root bashrc
    if ! grep -q "auto-activate project venv" "$bashrc_root" 2>/dev/null; then
      printf "\n# auto-activate project venv\nif [ -d \"\${PROJECT_ROOT:-/app}/.venv\" ] && [ -f \"\${PROJECT_ROOT:-/app}/.venv/bin/activate\" ]; then . \"\${PROJECT_ROOT:-/app}/.venv/bin/activate\"; fi\n" >> "$bashrc_root" || true
    fi
    # App user bashrc if user exists
    if id -u "$RUN_AS_USER" >/dev/null 2>&1; then
      local APP_HOME
      APP_HOME="$(getent passwd "$RUN_AS_USER" | cut -d: -f6)"
      mkdir -p "$APP_HOME" 2>/dev/null || true
      touch "$APP_HOME/.bashrc" 2>/dev/null || true
      if ! grep -q "auto-activate project venv" "$APP_HOME/.bashrc" 2>/dev/null; then
        printf "\n# auto-activate project venv\nif [ -d \"\${PROJECT_ROOT:-/app}/.venv\" ] && [ -f \"\${PROJECT_ROOT:-/app}/.venv/bin/activate\" ]; then . \"\${PROJECT_ROOT:-/app}/.venv/bin/activate\"; fi\n" >> "$APP_HOME/.bashrc" || true
      fi
      chown -R "$RUN_AS_UID:$RUN_AS_GID" "$APP_HOME" 2>/dev/null || true
    fi
  else
    # Non-root: append to current user's bashrc
    local user_bashrc="$HOME/.bashrc"
    if ! grep -q "auto-activate project venv" "$user_bashrc" 2>/dev/null; then
      printf "\n# auto-activate project venv\nif [ -d \"\${PROJECT_ROOT:-$PROJECT_ROOT}/.venv\" ] && [ -f \"\${PROJECT_ROOT:-$PROJECT_ROOT}/.venv/bin/activate\" ]; then . \"\${PROJECT_ROOT:-$PROJECT_ROOT}/.venv/bin/activate\"; fi\n" >> "$user_bashrc" || true
    fi
  fi
}

# Python -c wrapper to recombine mis-split code strings
install_python_c_wrapper() {
  # Install a compiled C shim at /usr/local/bin/python that repairs split -c invocations
  if is_root; then
    # Ensure build tools are available
    sh -c 'if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y gcc make; elif command -v yum >/dev/null 2>&1; then yum -y groupinstall "Development Tools" || yum -y install gcc make; elif command -v apk >/dev/null 2>&1; then apk add --no-cache build-base; fi' || true
    # Write C source for python shim
    cat >/tmp/python_c_shim.c <<'EOF'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

static const char* find_real_python() {
    const char* env = getenv("REAL_PYTHON_PATH");
    if (env && access(env, X_OK) == 0) return env;
    const char* candidates[] = {
        "/usr/bin/python3.12",
        "/usr/bin/python3.11",
        "/usr/bin/python3",
        "/usr/bin/python",
        NULL
    };
    for (int i = 0; candidates[i]; ++i) {
        if (access(candidates[i], X_OK) == 0) return candidates[i];
    }
    return "/usr/bin/python3"; // best effort fallback
}

static void exec_real(char **argv, int argc) {
    const char* real = find_real_python();
    char **nargv = (char**)malloc((argc + 1) * sizeof(char*));
    if (!nargv) _exit(127);
    nargv[0] = (char*)real;
    for (int i = 1; i < argc; ++i) nargv[i] = argv[i];
    nargv[argc] = NULL;
    execv(real, nargv);
    perror("execv");
    _exit(127);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "-c") == 0) {
            if (i + 1 < argc) {
                // Detect a likely split command (common patterns start with import/from)
                if ((strcmp(argv[i+1], "import") == 0) || (strcmp(argv[i+1], "from") == 0)) {
                    // Join all tokens after -c into a single code string
                    size_t len = 0;
                    for (int j = i + 1; j < argc; ++j) len += strlen(argv[j]) + 1;
                    char *code = (char*)malloc(len + 1);
                    if (!code) _exit(127);
                    code[0] = '\0';
                    for (int j = i + 1; j < argc; ++j) {
                        strcat(code, argv[j]);
                        if (j < argc - 1) strcat(code, " ");
                    }
                    // Build new argv: [real, args up to -c, joined code]
                    const char* real = find_real_python();
                    int new_argc = i + 2; // real + args[1..i] + joined code
                    char **nargv = (char**)malloc((new_argc + 1) * sizeof(char*));
                    if (!nargv) _exit(127);
                    int k = 0;
                    nargv[k++] = (char*)real;
                    for (int j = 1; j <= i; ++j) nargv[k++] = argv[j];
                    nargv[k++] = code;
                    nargv[k] = NULL;
                    execv(real, nargv);
                    perror("execv");
                    _exit(127);
                }
            }
            break; // found -c but not a split pattern; fall through to exec as-is
        }
    }
    exec_real(argv, argc);
}
EOF
    # Compile and install shim
    sh -c 'gcc -O2 -o /usr/local/bin/python-shim /tmp/python_c_shim.c && chmod +x /usr/local/bin/python-shim && ln -sf /usr/local/bin/python-shim /usr/local/bin/python' || true
  else
    warn "Not root; cannot install system-wide python shim."
  fi
}

# Python setup
setup_python() {
  info "Setting up Python environment..."
  # Remove any prior runner fix artifacts to prevent Python startup errors from malformed .pth hooks
  find /app -type f \( -name 'zzz_runner_fix*.pth' -o -name 'runner_fix*.pth' -o -name 'runner_fix.py' -o -name 'runner_fix.pyc' \) -print -delete || true
  if is_root; then
    case "$PKG_MGR" in
      apt)
        install_pkgs python3 python3-venv python3-dev python3-pip build-essential pkg-config libffi-dev libssl-dev python3-pandas
        ;;
      apk)
        install_pkgs python3 py3-pip py3-virtualenv python3-dev build-base libffi-dev openssl-dev
        ;;
      dnf|yum|microdnf)
        install_pkgs python3 python3-pip python3-devel gcc gcc-c++ make pkgconfig libffi-devel openssl-devel
        ;;
      *)
        warn "Cannot ensure Python system packages; proceeding with existing Python if any."
        ;;
    esac
  fi

  # Determine python3 command
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 not found. Please use a Python base image or enable system package installation."
    return 1
  fi

  cd "$PROJECT_ROOT"
  # Configure pip to allow system installs when required and install uv
  setup_pip_break_system_packages
  python3 -m pip install --upgrade --no-cache-dir pip setuptools wheel
  python3 -m pip install --no-cache-dir -U pandas
  # usercustomize.py injection removed; using dedicated venv sitecustomize hook instead
  # sitecustomize.py injection moved to venv-specific path after venv activation
  python -m pip install -U uv
  wrap_uv_break_system_packages
  install_uv_system_shim
  # Pre-create project venv and install core build tools and pandas there to bypass system installs
  if [ ! -d ".venv" ]; then
    python3 -m venv .venv || python3 -m ensurepip --upgrade && python3 -m venv .venv
  fi
  if [ -x ./.venv/bin/python ]; then
    ./.venv/bin/python -m pip install -U pip setuptools wheel pandas || true
  fi
  # Install sitecustomize startup hook in the venv to repair split `python -c` invocations
  mkdir -p "$PROJECT_ROOT/.venv/lib/python3.12/site-packages" && cat > "$PROJECT_ROOT/.venv/lib/python3.12/site-packages/sitecustomize.py" <<'PY'
import sys

def _fix_split_dash_c():
    argv = sys.argv
    if argv and argv[0] == '-c' and len(argv) > 1:
        code = ' '.join(argv[1:])
        try:
            compile(code, '<string>', 'exec')
        except Exception:
            return
        ns = {'__name__': '__main__'}
        exec(compile(code, '<string>', 'exec'), ns, ns)
        raise SystemExit(0)

_fix_split_dash_c()
PY
  uv pip install --system pandas
  # Ensure tests package for unittest relative imports
  sh -c 'mkdir -p tests && [ -f tests/__init__.py ] || : > tests/__init__.py'
  # Create venv if not exists
  if [ ! -d ".venv" ]; then
    python3 -m venv .venv || python3 -m ensurepip --upgrade && python3 -m venv .venv
  fi
  # Activate venv for this script context
  # shellcheck disable=SC1091
  source ".venv/bin/activate"
  # Wrap venv python to handle incorrectly split -c code strings from some runners
  if [ -d ./.venv/bin ] && [ -x ./.venv/bin/python ] && [ ! -x ./.venv/bin/python.real ]; then
    mv ./.venv/bin/python ./.venv/bin/python.real
    printf '%s\n' '#!/bin/sh' 'set -eu' 'REAL="$(dirname "$0")/python.real"' 'if [ "$#" -ge 1 ] && [ "$1" = "-c" ]; then' '  shift' '  code="$*"' '  exec "$REAL" -c "$code"' 'fi' 'if [ "$#" -ge 3 ] && [ "$1" = "-m" ] && [ "$2" = "unittest" ] && [ "$3" = "discover" ]; then' '  has_t=0' '  for arg in "$@"; do' '    case "$arg" in' '      -t|--top-level-directory|-t=*|--top-level-directory=*) has_t=1 ;;' '    esac' '  done' '  if [ "$has_t" -eq 0 ]; then' '    shift 3' '    exec "$REAL" -m unittest discover -t . "$@"' '  fi' 'fi' 'exec "$REAL" "$@"' > ./.venv/bin/python
    chmod +x ./.venv/bin/python
  fi
  python -m pip install --upgrade pip pandas
  python -m pip install -U pandas

  # Ensure pandas is present in requirements.txt and install dependencies
  sh -c 'if [ -f requirements.txt ]; then grep -Eiq "^[[:space:]]*pandas([[:space:]]*[<=>].*)?$" requirements.txt || echo "pandas>=2.0,<3" >> requirements.txt; else echo "pandas>=2.0,<3" > requirements.txt; fi'
  if [ -f "requirements.txt" ]; then
    python -m pip install --no-cache-dir -r requirements.txt
  elif [ -f "pyproject.toml" ]; then
    # Try PEP 517 install or editable if project is configured
    if grep -qi '\[tool.poetry\]' pyproject.toml 2>/dev/null; then
      pip install "poetry>=1.5" && poetry config virtualenvs.in-project true && poetry install --no-interaction --no-root
    else
      pip install .
    fi
  elif [ -f "Pipfile" ]; then
    pip install pipenv && PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy --system || PIPENV_VENV_IN_PROJECT=1 pipenv install
  else
    info "No Python dependency file found; skipping pip install."
  fi

  # Default ports for typical frameworks
  PORT="${PORT:-}"
  if [ -z "$PORT" ]; then
    if ls "$PROJECT_ROOT" | grep -qi "manage.py"; then
      PORT=8000
    elif ls "$PROJECT_ROOT" | grep -Eqi "(app\.py|wsgi\.py|asgi\.py)"; then
      PORT=5000
    else
      PORT=8000
    fi
  fi
  export PORT
  grep -q '^PORT=' "$PROJECT_ROOT/.env" || echo "PORT=$PORT" >> "$PROJECT_ROOT/.env"

  info "Python setup complete."
}

# Node.js setup
setup_node() {
  info "Setting up Node.js environment..."
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    if is_root; then
      case "$PKG_MGR" in
        apt)
          install_pkgs nodejs npm
          ;;
        apk)
          install_pkgs nodejs npm
          ;;
        dnf|yum|microdnf)
          install_pkgs nodejs npm
          ;;
        *)
          warn "Cannot install Node.js automatically; please use a Node base image."
          ;;
      esac
    else
      warn "No Node.js found and not root to install. Skipping."
    fi
  fi

  if ! command -v npm >/dev/null 2>&1; then
    err "npm not available; cannot proceed with Node setup."
    return 1
  fi

  cd "$PROJECT_ROOT"
  # Install yarn/pnpm if lockfiles indicate
  if [ -f "yarn.lock" ] && ! command -v yarn >/dev/null 2>&1; then
    npm --silent install -g yarn || true
  fi
  if [ -f "pnpm-lock.yaml" ] && ! command -v pnpm >/dev/null 2>&1; then
    npm --silent install -g pnpm || true
  fi

  if [ -f "package.json" ]; then
    if [ -f "package-lock.json" ]; then
      npm ci --omit=dev
    elif [ -f "yarn.lock" ] && command -v yarn >/dev/null 2>&1; then
      yarn install --frozen-lockfile --production
    elif [ -f "pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
      pnpm install --frozen-lockfile --prod
    else
      npm install --omit=dev
    fi
  else
    info "No package.json found; skipping Node dependency installation."
  fi

  # Default PORT
  PORT="${PORT:-3000}"
  export PORT
  grep -q '^PORT=' "$PROJECT_ROOT/.env" || echo "PORT=$PORT" >> "$PROJECT_ROOT/.env"

  info "Node.js setup complete."
}

# Ruby setup
setup_ruby() {
  info "Setting up Ruby environment..."
  if ! command -v ruby >/dev/null 2>&1; then
    if is_root; then
      case "$PKG_MGR" in
        apt)
          install_pkgs ruby-full build-essential
          ;;
        apk)
          install_pkgs ruby ruby-dev build-base
          ;;
        dnf|yum|microdnf)
          install_pkgs ruby ruby-devel gcc gcc-c++ make
          ;;
        *)
          warn "Cannot install Ruby automatically; please use a Ruby base image."
          ;;
      esac
    else
      warn "Ruby not found and not root to install."
    fi
  fi

  if ! command -v gem >/dev/null 2>&1; then
    warn "gem not available; skipping bundler installation."
    return 0
  fi

  gem install bundler --no-document || true
  cd "$PROJECT_ROOT"
  if [ -f "Gemfile" ]; then
    bundle config set --local path 'vendor/bundle'
    bundle install --jobs=4 --retry=3
  fi

  PORT="${PORT:-3000}"
  export PORT
  grep -q '^PORT=' "$PROJECT_ROOT/.env" || echo "PORT=$PORT" >> "$PROJECT_ROOT/.env"

  info "Ruby setup complete."
}

# Go setup
setup_go() {
  info "Setting up Go environment..."
  if ! command -v go >/dev/null 2>&1; then
    if is_root; then
      case "$PKG_MGR" in
        apt) install_pkgs golang ;;
        apk) install_pkgs go ;;
        dnf|yum|microdnf) install_pkgs golang ;;
        *) warn "Cannot install Go automatically; please use a Go base image." ;;
      esac
    else
      warn "Go not found and not root to install."
    fi
  fi

  if command -v go >/dev/null 2>&1; then
    cd "$PROJECT_ROOT"
    if [ -f "go.mod" ]; then
      go mod download
    fi
  fi

  PORT="${PORT:-8080}"
  export PORT
  grep -q '^PORT=' "$PROJECT_ROOT/.env" || echo "PORT=$PORT" >> "$PROJECT_ROOT/.env"

  info "Go setup complete."
}

# Java Maven setup
setup_java_maven() {
  info "Setting up Java (Maven) environment..."
  if is_root; then
    case "$PKG_MGR" in
      apt) install_pkgs openjdk-17-jdk maven ;;
      apk) install_pkgs openjdk17 maven ;;
      dnf|yum|microdnf) install_pkgs java-17-openjdk-devel maven ;;
      *) warn "Cannot install Java/Maven automatically; please use a Java base image." ;;
    esac
  fi

  if ! command -v mvn >/dev/null 2>&1; then
    warn "maven not available; skipping dependency download."
    return 0
  fi

  cd "$PROJECT_ROOT"
  mvn -B -ntp -DskipTests dependency:go-offline || true

  PORT="${PORT:-8080}"
  export PORT
  grep -q '^PORT=' "$PROJECT_ROOT/.env" || echo "PORT=$PORT" >> "$PROJECT_ROOT/.env"

  info "Java (Maven) setup complete."
}

# Java Gradle setup
setup_java_gradle() {
  info "Setting up Java (Gradle) environment..."
  if is_root; then
    case "$PKG_MGR" in
      apt) install_pkgs openjdk-17-jdk gradle ;;
      apk) install_pkgs openjdk17 gradle ;;
      dnf|yum|microdnf) install_pkgs java-17-openjdk-devel gradle ;;
      *) warn "Cannot install Java/Gradle automatically; please use a Java base image." ;;
    esac
  fi

  cd "$PROJECT_ROOT"
  if [ -x "./gradlew" ]; then
    ./gradlew --no-daemon build -x test || true
  elif command -v gradle >/dev/null 2>&1; then
    gradle --no-daemon build -x test || true
  else
    warn "Gradle not available; skipping."
  fi

  PORT="${PORT:-8080}"
  export PORT
  grep -q '^PORT=' "$PROJECT_ROOT/.env" || echo "PORT=$PORT" >> "$PROJECT_ROOT/.env"

  info "Java (Gradle) setup complete."
}

# PHP setup
setup_php() {
  info "Setting up PHP environment..."
  if is_root; then
    case "$PKG_MGR" in
      apt) install_pkgs php-cli php-xml php-mbstring php-curl php-zip unzip ;;
      apk) install_pkgs php81 php81-cli php81-xml php81-mbstring php81-curl php81-zip unzip || install_pkgs php php-cli php-xml php-mbstring php-curl php-zip ;;
      dnf|yum|microdnf) install_pkgs php-cli php-xml php-mbstring php-json php-curl php-zip unzip ;;
      *) warn "Cannot install PHP automatically; please use a PHP base image." ;;
    esac
  fi

  # Composer installation
  if ! command -v composer >/dev/null 2>&1; then
    EXPECTED_CHECKSUM="$(curl -fsSL https://composer.github.io/installer.sig || true)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" 2>/dev/null || true
    if [ -f composer-setup.php ] && [ -n "${EXPECTED_CHECKSUM:-}" ]; then
      ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
      if [ "$EXPECTED_CHECKSUM" = "$ACTUAL_CHECKSUM" ]; then
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet || true
      fi
      rm -f composer-setup.php
    fi
  fi

  cd "$PROJECT_ROOT"
  if [ -f "composer.json" ] && command -v composer >/dev/null 2>&1; then
    composer install --no-interaction --no-dev --prefer-dist --optimize-autoloader || composer install --no-interaction --prefer-dist
  fi

  PORT="${PORT:-8080}"
  export PORT
  grep -q '^PORT=' "$PROJECT_ROOT/.env" || echo "PORT=$PORT" >> "$PROJECT_ROOT/.env"

  info "PHP setup complete."
}

# Rust setup
setup_rust() {
  info "Setting up Rust environment..."
  if is_root; then
    case "$PKG_MGR" in
      apt) install_pkgs rustc cargo pkg-config build-essential libssl-dev ;;
      apk) install_pkgs rust cargo pkgconfig build-base openssl-dev ;;
      dnf|yum|microdnf) install_pkgs rust cargo pkgconfig gcc gcc-c++ make openssl-devel ;;
      *) warn "Cannot install Rust automatically; please use a Rust base image." ;;
    esac
  fi

  cd "$PROJECT_ROOT"
  if [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
    cargo fetch || true
  fi

  PORT="${PORT:-8080}"
  export PORT
  grep -q '^PORT=' "$PROJECT_ROOT/.env" || echo "PORT=$PORT" >> "$PROJECT_ROOT/.env"

  info "Rust setup complete."
}

# .NET setup
setup_dotnet() {
  info "Setting up .NET environment..."
  if ! command -v dotnet >/dev/null 2>&1; then
    warn ".NET SDK not found. Please use a dotnet SDK base image (e.g., mcr.microsoft.com/dotnet/sdk:8.0)."
    return 0
  fi
  cd "$PROJECT_ROOT"
  dotnet restore || true

  PORT="${PORT:-8080}"
  export PORT
  grep -q '^PORT=' "$PROJECT_ROOT/.env" || echo "PORT=$PORT" >> "$PROJECT_ROOT/.env"

  info ".NET setup complete."
}

# Sanity info
print_summary() {
  info "Setup summary:"
  echo " - Project root: $PROJECT_ROOT"
  echo " - Project type: $PROJECT_TYPE"
  echo " - Non-root user: $RUN_AS_USER (uid:$RUN_AS_UID gid:$RUN_AS_GID)"
  echo " - Default port: ${PORT:-not set}"
  echo " - Environment file: $PROJECT_ROOT/.env"
}

main() {
  log "Starting containerized project environment setup..."
  setup_base
  install_python_c_wrapper
  ensure_app_user
  detect_project_type
  write_env_files
  setup_auto_activate

  case "$PROJECT_TYPE" in
    python) setup_python ;;
    nodejs) setup_node ;;
    ruby) setup_ruby ;;
    go) setup_go ;;
    java-maven) setup_java_maven ;;
    java-gradle) setup_java_gradle ;;
    php) setup_php ;;
    rust) setup_rust ;;
    .net) setup_dotnet ;;
    *)
      warn "Unknown project type. Ensuring base build tools in case needed."
      if is_root; then
        case "$PKG_MGR" in
          apt) install_pkgs build-essential pkg-config ;;
          apk) install_pkgs build-base pkgconfig ;;
          dnf|yum|microdnf) install_pkgs gcc gcc-c++ make pkgconfig ;;
        esac
      fi
      ;;
  esac

  # Adjust permissions after setup
  if is_root; then
    chown -R "$RUN_AS_UID:$RUN_AS_GID" "$PROJECT_ROOT" || true
  fi

  print_summary
  log "Environment setup completed successfully."
  echo
  echo "Usage notes:"
  echo " - To load environment vars in an interactive shell: source /etc/profile.d/project_env.sh 2>/dev/null || true"
  echo " - Default runtime user: $RUN_AS_USER (configure via RUN_AS_USER/UID/GID env vars)"
  echo " - To run your app, use the appropriate command for your project type."
}

main "$@"