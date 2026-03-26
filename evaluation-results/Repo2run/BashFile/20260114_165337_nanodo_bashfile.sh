#!/usr/bin/env bash
# Nanodo project environment setup script for Docker containers
# This script installs system packages, Python runtime, creates a venv,
# installs dependencies (with CPU or optional CUDA support), and configures the environment.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail
IFS=$'\n\t'

# ------------- Configurable defaults (can be overridden via env) -------------
PROJECT_NAME="${PROJECT_NAME:-nanodo}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
VENVSYS_PREFIX="${VENVSYS_PREFIX:-/opt}"                # Where to place the venv
VENV_DIR="${VENV_DIR:-$VENVSYS_PREFIX/venv}"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"
DATA_DIR="${DATA_DIR:-$PROJECT_ROOT/data}"
CACHE_DIR="${CACHE_DIR:-$PROJECT_ROOT/.cache}"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-$CACHE_DIR/pip}"
MARKER_FILE="${MARKER_FILE:-$VENVSYS_PREFIX/.${PROJECT_NAME}_setup_done}"
PY_MIN_VERSION_MAJOR=3
PY_MIN_VERSION_MINOR=10

# Python package versions
JAX_MIN_VERSION="${JAX_MIN_VERSION:-0.4.26}"
TF_VERSION="${TF_VERSION:-2.16.1}"

# GPU control
USE_GPU="${USE_GPU:-0}"                  # 0 CPU-only by default; set 1 to try GPU installs
FORCE_CPU="${FORCE_CPU:-0}"              # 1 to force CPU even if GPU is detected

# Create a non-root user if desired (in Docker typically we run as root)
CREATE_APP_USER="${CREATE_APP_USER:-0}"
APP_USER="${APP_USER:-appuser}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"

# Other env
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONUNBUFFERED=1

# Colors
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

cleanup() { :; }
trap 'error "An error occurred on line $LINENO. Exiting."; cleanup' ERR

# Detect package manager
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return 0; fi
  if command -v apt >/dev/null 2>&1; then echo "apt"; return 0; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return 0; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return 0; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return 0; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return 0; fi
  echo "unknown"
}

is_alpine() { [ -f /etc/alpine-release ]; }
is_debian_like() { [ -f /etc/debian_version ]; }
is_rhel_like() { [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; }
is_sles_like() { [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; }

ensure_system_packages() {
  local pmgr; pmgr="$(detect_pkg_manager)"
  log "Detected package manager: $pmgr"

  if [ "$pmgr" = "unknown" ]; then
    die "Unsupported base image: could not detect package manager."
  fi

  # TensorFlow official wheels are built for manylinux (glibc). Alpine (musl) is not supported.
  if is_alpine; then
    if [ "${ALLOW_ALPINE:-0}" != "1" ]; then
      die "Alpine/musl base detected. TensorFlow wheels are not supported on musl. Use a Debian/Ubuntu/RHEL-based image or set ALLOW_ALPINE=1 to try anyway (not supported)."
    else
      warn "Proceeding on Alpine; TensorFlow may fail to install."
    fi
  fi

  case "$pmgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # Core tools and build essentials
      apt-get install -y --no-install-recommends \
        ca-certificates curl git bash \
        build-essential pkg-config cmake unzip \
        python3 python3-dev python3-venv python3-pip \
        libffi-dev libssl-dev
      # Clean
      rm -rf /var/lib/apt/lists/*
      ;;
    dnf)
      dnf -y update || true
      dnf -y groupinstall "Development Tools" || true
      dnf -y install ca-certificates curl git bash \
        python3 python3-devel python3-pip cmake make gcc gcc-c++ \
        libffi-devel openssl-devel unzip
      dnf clean all || true
      ;;
    yum)
      yum -y update || true
      yum -y groupinstall "Development Tools" || true
      yum -y install ca-certificates curl git bash \
        python3 python3-devel python3-pip cmake make gcc gcc-c++ \
        libffi-devel openssl-devel unzip
      yum clean all || true
      ;;
    apk)
      apk add --no-cache ca-certificates curl git bash \
        build-base cmake unzip \
        python3 py3-pip python3-dev py3-virtualenv \
        libffi-dev openssl-dev
      ;;
    zypper)
      zypper refresh
      zypper -n install -y --no-confirm --force-resolution \
        ca-certificates curl git bash \
        gcc gcc-c++ make cmake unzip \
        python3 python3-devel python3-pip \
        libffi-devel libopenssl-devel
      zypper clean -a || true
      ;;
  esac
  update-ca-certificates >/dev/null 2>&1 || true
}

check_python_version() {
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 not found after system package installation."
  fi
  local ver major minor
  ver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
  major="${ver%%.*}"
  minor="${ver##*.}"
  log "Detected Python version: $ver"
  if [ "$major" -lt "$PY_MIN_VERSION_MAJOR" ] || { [ "$major" -eq "$PY_MIN_VERSION_MAJOR" ] && [ "$minor" -lt "$PY_MIN_VERSION_MINOR" ]; }; then
    die "Python ${PY_MIN_VERSION_MAJOR}.${PY_MIN_VERSION_MINOR}+ required. Found $ver."
  fi
}

create_user_if_requested() {
  if [ "$CREATE_APP_USER" != "1" ]; then return 0; fi
  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User $APP_USER already exists."
    return 0
  fi

  if command -v useradd >/dev/null 2>&1; then
    groupadd -g "$APP_GID" "$APP_USER" 2>/dev/null || true
    useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER"
    log "Created user $APP_USER (uid:$APP_UID gid:$APP_GID)."
  elif command -v adduser >/dev/null 2>&1; then
    addgroup -g "$APP_GID" "$APP_USER" 2>/dev/null || true
    adduser -D -u "$APP_UID" -G "$APP_USER" "$APP_USER"
    log "Created user $APP_USER (uid:$APP_UID gid:$APP_GID)."
  else
    warn "No useradd/adduser found; running as current user."
  fi
}

setup_directories() {
  mkdir -p "$LOG_DIR" "$DATA_DIR" "$CACHE_DIR" "$PIP_CACHE_DIR"
  chmod 755 "$LOG_DIR" "$DATA_DIR" 2>/dev/null || true
  chmod 700 "$CACHE_DIR" "$PIP_CACHE_DIR" 2>/dev/null || true

  if [ "$CREATE_APP_USER" = "1" ] && id -u "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER":"$APP_USER" "$LOG_DIR" "$DATA_DIR" "$CACHE_DIR" "$PIP_CACHE_DIR" 2>/dev/null || true
  fi
  log "Project directories prepared: logs=$LOG_DIR data=$DATA_DIR cache=$CACHE_DIR"
}

setup_venv() {
  if [ -d "$VENV_DIR" ] && [ -x "$VENV_DIR/bin/python" ]; then
    log "Using existing virtual environment at $VENV_DIR"
  else
    log "Creating Python virtual environment at $VENV_DIR"
    mkdir -p "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  # shellcheck disable=SC1090
  . "$VENV_DIR/bin/activate"
  # Ensure pip tools are up to date
  python -m pip install --upgrade pip setuptools wheel build || die "Failed to upgrade pip/setuptools/wheel/build"
  # Configure pip cache directory
  export PIP_CACHE_DIR
  log "Virtual environment ready. Python: $(python -V), Pip: $(pip -V)"
}

detect_gpu() {
  # Returns 0 if GPU likely available with CUDA libraries present
  if [ "$FORCE_CPU" = "1" ]; then return 1; fi
  if [ "$USE_GPU" != "1" ]; then return 1; fi
  if command -v nvidia-smi >/dev/null 2>&1; then return 0; fi
  if [ -d "/usr/local/cuda" ]; then return 0; fi
  if command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q libcudart.so; then return 0; fi
  return 1
}

install_python_dependencies() {
  # Some dependencies are large (jax/tf). Install them first with desired variants.
  local gpu="0"
  if detect_gpu; then gpu="1"; fi
  if [ "$gpu" = "1" ]; then
    log "GPU environment detected and USE_GPU=1. Installing CUDA-enabled JAX and TensorFlow."
    # JAX CUDA via cuda12_pip wheels (requires recent pip and will pull nvidia cuda/cudnn wheels)
    python -m pip install --upgrade "jax[cuda12_pip]>=$JAX_MIN_VERSION" || die "Failed to install JAX CUDA wheels"
    # TensorFlow CUDA extras (2.16+ supports [cuda])
    python -m pip install --upgrade "tensorflow[cuda]==$TF_VERSION" || die "Failed to install TensorFlow (CUDA)"
    export JAX_PLATFORMS="cuda"
  else
    log "Installing CPU-only JAX and TensorFlow."
    python -m pip install --upgrade "jax[cpu]>=$JAX_MIN_VERSION" || die "Failed to install JAX CPU wheels"
    python -m pip install --upgrade "tensorflow==$TF_VERSION" || die "Failed to install TensorFlow (CPU)"
    export JAX_PLATFORMS="cpu"
  fi

  # Now install the project and remaining dependencies from pyproject.toml
  # This will bring: absl-py, clu, flax, grain, ml-collections, numpy, optax, orbax, sentencepiece, tensorflow_datasets, etc.
  # Using pip's resolver; already-installed jax/tf satisfy version requirements.
  if [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    log "Installing project in editable mode: $PROJECT_ROOT"
    (cd "$PROJECT_ROOT" && python -m pip install -e .) || die "Failed to install project"
  else
    warn "pyproject.toml not found at $PROJECT_ROOT. Installing dependencies only."
  fi

  if [ "${INSTALL_TEST_DEPS:-0}" = "1" ] && [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
    log "Installing optional test dependencies."
    (cd "$PROJECT_ROOT" && python -m pip install -e ".[test]") || warn "Failed to install test extras"
  fi

  # Quality-of-life defaults for JAX/TF
  export XLA_PYTHON_CLIENT_PREALLOCATE="${XLA_PYTHON_CLIENT_PREALLOCATE:-false}"
  export TF_CPP_MIN_LOG_LEVEL="${TF_CPP_MIN_LOG_LEVEL:-1}"

  log "Python dependencies installed."
}

persist_environment() {
  # Persist venv on PATH and set common env vars for shells
  local prof="/etc/profile.d/${PROJECT_NAME}_env.sh"
  local content
  content="# Auto-generated by ${PROJECT_NAME} setup
# shellcheck shell=sh
[ -d \"$VENV_DIR/bin\" ] && case :\"\$PATH\": in *:$VENV_DIR/bin:*) ;; *) export PATH=\"$VENV_DIR/bin:\$PATH\" ;; esac
export PIP_CACHE_DIR=\"${PIP_CACHE_DIR}\"
export PYTHONUNBUFFERED=1
export TF_CPP_MIN_LOG_LEVEL=\"${TF_CPP_MIN_LOG_LEVEL:-1}\"
export XLA_PYTHON_CLIENT_PREALLOCATE=\"${XLA_PYTHON_CLIENT_PREALLOCATE:-false}\"
export JAX_PLATFORMS=\"${JAX_PLATFORMS:-cpu}\"
export NANODO_DATA_DIR=\"${DATA_DIR}\"
# Allow project to be imported when running from source
case :\"\$PYTHONPATH\": in *:${PROJECT_ROOT}:*) ;; *) export PYTHONPATH=\"${PROJECT_ROOT}:\$PYTHONPATH\" ;; esac
"
  if [ -w /etc/profile.d ] || [ "$(id -u)" -eq 0 ]; then
    echo "$content" > "$prof"
    chmod 0644 "$prof"
    log "Persisted environment to $prof"
  else
    warn "Cannot write to /etc/profile.d. Skipping persistence; you may add the following to your shell profile:\n$content"
  fi
}

write_runtime_helper() {
  # Provide a small launcher for convenience
  local runscript="$PROJECT_ROOT/run_nano.sh"
  cat > "$runscript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Helper to run Python with the project's virtualenv and env variables

VENV_DIR="${VENV_DIR:-/opt/venv}"
# shellcheck disable=SC1090
if [ -f "$VENV_DIR/bin/activate" ]; then . "$VENV_DIR/bin/activate"; fi

export PYTHONUNBUFFERED=${PYTHONUNBUFFERED:-1}
export TF_CPP_MIN_LOG_LEVEL=${TF_CPP_MIN_LOG_LEVEL:-1}
export XLA_PYTHON_CLIENT_PREALLOCATE=${XLA_PYTHON_CLIENT_PREALLOCATE:-false}
export JAX_PLATFORMS=${JAX_PLATFORMS:-cpu}

exec python "$@"
EOF
  chmod +x "$runscript"
  log "Created helper: $runscript (use: ./run_nano.sh -c 'import nanodo; print(nanodo.__doc__)')"
}

write_build_script_and_run() {
  (
    cd "$PROJECT_ROOT"
    printf "%s\n" "#!/usr/bin/env bash" "set -euo pipefail" "if [ -f package.json ]; then" "  if command -v pnpm >/dev/null && [ -f pnpm-lock.yaml ]; then" "    pnpm -s install --frozen-lockfile && pnpm -s build" "  elif command -v yarn >/dev/null && [ -f yarn.lock ]; then" "    yarn install --frozen-lockfile --non-interactive && yarn -s build" "  else" "    npm ci --no-audit --no-fund && npm run -s build" "  fi" "elif [ -f pom.xml ]; then" "  mvn -q -DskipTests package" "elif [ -f gradlew ]; then" "  chmod +x gradlew && ./gradlew -q assemble" "elif [ -f build.gradle ]; then" "  gradle -q assemble" "elif ls *.sln *.csproj >/dev/null 2>&1; then" "  dotnet build -c Release" "elif [ -f Cargo.toml ]; then" "  cargo build --release" "elif [ -f go.mod ]; then" "  go build ./..." "elif [ -f pyproject.toml ]; then" "  python -m pip install -U pip && pip install -e ." "elif [ -f setup.py ]; then" "  python -m pip install -U pip && pip install -e ." "elif [ -f requirements.txt ]; then" "  python -m pip install -U pip && pip install -r requirements.txt" "elif [ -f Gemfile ]; then" "  bundle install" "else" "  echo No recognized build configuration found && exit 1" "fi" > .ci_build.sh
    chmod +x .ci_build.sh
    log "Executing project build script: $PROJECT_ROOT/.ci_build.sh"
    bash .ci_build.sh
  )
}

summary() {
  log "Setup complete."
  echo "Summary:"
  echo "  Project root:     $PROJECT_ROOT"
  echo "  Virtualenv:       $VENV_DIR"
  echo "  Logs directory:   $LOG_DIR"
  echo "  Data directory:   $DATA_DIR"
  echo "  Cache directory:  $CACHE_DIR"
  echo "  GPU enabled:      $([ "${JAX_PLATFORMS:-cpu}" = "cuda" ] && echo yes || echo no)"
  echo "  Python:           $(command -v python || true)"
  echo "  Pip:              $(command -v pip || true)"
  echo
  echo "Usage:"
  echo "  source $VENV_DIR/bin/activate"
  echo "  python -c 'import nanodo, jax, tensorflow as tf; print(nanodo.__name__, jax.__version__, tf.__version__)'"
  echo "  or use helper: $PROJECT_ROOT/run_nano.sh your_script.py"
}

main() {
  umask 022

  log "Starting ${PROJECT_NAME} environment setup."
  ensure_system_packages
  check_python_version
  create_user_if_requested
  setup_directories
  setup_venv

  # Record build info before heavy installs
  log "Installing Python dependencies for ${PROJECT_NAME}..."
  install_python_dependencies

  persist_environment
  write_runtime_helper
  write_build_script_and_run

  # Marker for idempotency
  mkdir -p "$(dirname "$MARKER_FILE")"
  echo "setup_completed_at=$(date -u +%FT%TZ)" > "$MARKER_FILE"

  summary
}

main "$@"