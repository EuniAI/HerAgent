#!/usr/bin/env bash
# Environment setup script for a Python (PyMC) project inside Docker containers.
# - Installs system packages, Python runtime, and build tools
# - Creates isolated virtual environment and installs dependencies
# - Configures environment variables for numerical libraries and PyTensor
# - Idempotent and safe to run multiple times

set -Eeuo pipefail

# --------------- Logging and error handling ---------------
if command -v tput >/dev/null 2>&1; then
  GREEN="$(tput setaf 2 || true)"
  YELLOW="$(tput setaf 3 || true)"
  RED="$(tput setaf 1 || true)"
  BOLD="$(tput bold || true)"
  NC="$(tput sgr0 || true)"
else
  GREEN=""; YELLOW=""; RED=""; BOLD=""; NC=""
fi

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() { true; }
trap cleanup EXIT
trap 'err "Failed at line $LINENO"; exit 1' ERR

# --------------- Configuration ---------------
# These can be overridden via environment variables when running the script
: "${APP_NAME:=pymc-project}"
: "${APP_USER:=}"              # e.g., "app"
: "${APP_UID:=}"               # e.g., "1000"
: "${APP_GID:=}"               # e.g., "1000"
: "${PYTHON_BIN:=python3}"     # will auto-detect if possible
: "${PYTHON_MIN_MAJOR:=3}"
: "${PYTHON_MIN_MINOR:=10}"
: "${CREATE_EDITABLE_INSTALL:=true}"  # install the project itself into the venv
: "${VENV_DIR:=.venv}"
: "${WORKDIR:=/app}"           # Recommended mount/work directory in Docker
: "${DEBIAN_FRONTEND:=noninteractive}"

# Threading defaults for BLAS/OpenMP in containers
: "${OMP_NUM_THREADS:=1}"
: "${OPENBLAS_NUM_THREADS:=1}"
: "${MKL_NUM_THREADS:=1}"
: "${NUMEXPR_NUM_THREADS:=1}"

# PyTensor defaults (keep CPU, enable OpenMP by default)
: "${PYTENSOR_FLAGS:=device=cpu,openmp=True}"

# --------------- Paths ---------------
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
# Prefer the configured WORKDIR (default /app) to standardize paths and avoid surprises
PROJECT_ROOT="$WORKDIR"

# --------------- Helper functions ---------------
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  else
    echo "unknown"
  fi
}

ensure_packages() {
  log "Installing system packages (auto-detecting package manager)"
  sh -lc 'if command -v apt-get >/dev/null 2>&1; then apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates wget bzip2 curl git bash build-essential gcc g++ gfortran make pkg-config python3 python3-venv python3-pip python3-dev libopenblas-dev liblapack-dev libgomp1 locales && (command -v locale-gen >/dev/null 2>&1 && locale-gen C.UTF-8 || true) && apt-get clean && rm -rf /var/lib/apt/lists/*; elif command -v dnf >/dev/null 2>&1; then dnf install -y ca-certificates wget bzip2 curl git bash gcc gcc-c++ gcc-gfortran make pkgconfig python3 python3-pip python3-devel openblas-devel lapack-devel glibc-locale-source glibc-langpack-en && dnf clean all; elif command -v yum >/dev/null 2>&1; then yum install -y ca-certificates wget bzip2 curl git bash gcc gcc-c++ gcc-gfortran make pkgconfig python3 python3-pip python3-devel openblas-devel lapack-devel && yum clean all; elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache ca-certificates wget bzip2 curl git bash build-base gfortran pkgconfig python3 py3-pip python3-dev py3-virtualenv openblas-dev lapack-dev libgomp; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh && zypper --non-interactive install -y ca-certificates curl git bash gcc gcc-c++ gcc-fortran make pkg-config python3 python3-pip python3-devel libopenblas-devel lapack-devel && zypper clean --all; else echo "Unsupported base image: no known package manager found." >&2; exit 1; fi'
}

ensure_python_version() {
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    if command -v python3 >/dev/null 2>&1; then
      PYTHON_BIN="python3"
    elif command -v python >/dev/null 2>&1; then
      PYTHON_BIN="python"
    else
      err "Python not found after system package installation."
      exit 1
    fi
  fi
  local vmajor vminor
  vmajor="$("$PYTHON_BIN" -c 'import sys; print(sys.version_info[0])')"
  vminor="$("$PYTHON_BIN" -c 'import sys; print(sys.version_info[1])')"
  if [ "$vmajor" -lt "$PYTHON_MIN_MAJOR" ] || { [ "$vmajor" -eq "$PYTHON_MIN_MAJOR" ] && [ "$vminor" -lt "$PYTHON_MIN_MINOR" ]; }; then
    err "Python >= ${PYTHON_MIN_MAJOR}.${PYTHON_MIN_MINOR} required, found ${vmajor}.${vminor}"
    err "Choose a base image with Python ${PYTHON_MIN_MAJOR}.${PYTHON_MIN_MINOR}+ (e.g., python:3.11-slim) or adjust package installation."
    exit 1
  fi
  log "Detected Python ${vmajor}.${vminor}"
}

create_app_user() {
  if [ -n "${APP_USER}" ] && [ -n "${APP_UID}" ] && [ -n "${APP_GID}" ]; then
    if ! id -u "${APP_USER}" >/dev/null 2>&1; then
      log "Creating user ${APP_USER} (${APP_UID}:${APP_GID})"
      # Try to create group and user in a distro-agnostic way
      if command -v addgroup >/dev/null 2>&1; then
        addgroup -g "${APP_GID}" -S "${APP_USER}" 2>/dev/null || true
        adduser -S -D -H -u "${APP_UID}" -G "${APP_USER}" "${APP_USER}" 2>/dev/null || true
      elif command -v groupadd >/dev/null 2>&1; then
        groupadd -g "${APP_GID}" -f "${APP_USER}" || true
        useradd -u "${APP_UID}" -g "${APP_GID}" -M -s /bin/bash "${APP_USER}" || true
      fi
    else
      log "User ${APP_USER} already exists"
    fi
  fi
}

setup_directories() {
  mkdir -p "${PROJECT_ROOT}"
  mkdir -p "${PROJECT_ROOT}/logs" "${PROJECT_ROOT}/data" "${PROJECT_ROOT}/.cache"
  chmod -R u+rwX,go+rX "${PROJECT_ROOT}"
  # Ownership if custom user provided
  if [ -n "${APP_USER}" ] && id -u "${APP_USER}" >/dev/null 2>&1; then
    chown -R "${APP_UID}:${APP_GID}" "${PROJECT_ROOT}" || true
  fi
}

create_venv() {
  cd "${PROJECT_ROOT}"
  if [ ! -d "${VENV_DIR}" ]; then
    log "Creating virtual environment at ${VENV_DIR}"
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  else
    log "Virtual environment already exists at ${VENV_DIR}"
  fi

  # Use venv Python directly (avoid sourcing to keep non-interactive shells stable)
  local venv_python="${PROJECT_ROOT}/${VENV_DIR}/bin/python"
  # Some distros need ensurepip; venv typically handles this.
  "$venv_python" -m pip install --upgrade --no-cache-dir pip setuptools wheel
}

write_env_files() {
  cd "${PROJECT_ROOT}"
  # .env for docker-compose and general reference
  cat > .env <<EOF
# Auto-generated environment file for ${APP_NAME}
PYTHONUNBUFFERED=1
PYTHONIOENCODING=UTF-8
PIP_NO_CACHE_DIR=1
XDG_CACHE_HOME=${PROJECT_ROOT}/.cache
# Control numerical library threading for predictable container performance
OMP_NUM_THREADS=${OMP_NUM_THREADS}
OPENBLAS_NUM_THREADS=${OPENBLAS_NUM_THREADS}
MKL_NUM_THREADS=${MKL_NUM_THREADS}
NUMEXPR_NUM_THREADS=${NUMEXPR_NUM_THREADS}
# PyTensor configuration (CPU; enable OpenMP)
PYTENSOR_FLAGS=${PYTENSOR_FLAGS}
EOF

  # Ensure activation sets env vars for shell sessions using the venv
  mkdir -p "${VENV_DIR}/bin/activate.d"
  cat > "${VENV_DIR}/bin/activate.d/${APP_NAME}.sh" <<EOF
# Sourced when activating the venv
export PYTHONUNBUFFERED=1
export PYTHONIOENCODING=UTF-8
export PIP_NO_CACHE_DIR=1
export XDG_CACHE_HOME="${PROJECT_ROOT}/.cache"
export OMP_NUM_THREADS="${OMP_NUM_THREADS}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS}"
export NUMEXPR_NUM_THREADS="${NUMEXPR_NUM_THREADS}"
export PYTENSOR_FLAGS="${PYTENSOR_FLAGS}"
EOF
}

install_python_deps() {
  cd "${PROJECT_ROOT}"
  local venv_python="${PROJECT_ROOT}/${VENV_DIR}/bin/python"

  # Speed up builds and ensure new pip resolver has latest metadata
  "$venv_python" -m pip install --upgrade --no-cache-dir pip setuptools wheel cython

  if [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    "$venv_python" -m pip install --no-cache-dir -r requirements.txt
  else
    warn "requirements.txt not found; skipping runtime dependency install"
  fi

  # Install the project itself (editable by default for dev workflows)
  if [ "${CREATE_EDITABLE_INSTALL}" = "true" ]; then
    if [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
      log "Installing project in editable mode"
      "$venv_python" -m pip install --no-cache-dir -e .
    else
      warn "No pyproject.toml or setup.py found; skipping project install"
    fi
  else
    if [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
      log "Installing project (non-editable)"
      "$venv_python" -m pip install --no-cache-dir .
    fi
  fi
}

print_summary() {
  cd "${PROJECT_ROOT}"
  echo
  echo "${BOLD}Setup complete for ${APP_NAME}.${NC}"
  echo "Project root: ${PROJECT_ROOT}"
  echo "Virtual env : ${PROJECT_ROOT}/${VENV_DIR}"
  echo
  echo "Common next steps:"
  echo "1) Activate venv:  source ${VENV_DIR}/bin/activate"
  echo "2) Python check:   python -c 'import sys, pymc; print(sys.version); print(pymc.__version__)' || true"
  echo "3) Run tests:      python -m pip install -U pytest pytest-cov && pytest -q || true"
  echo
  echo "Environment variables persisted to:"
  echo " - ${PROJECT_ROOT}/.env"
  echo " - ${PROJECT_ROOT}/${VENV_DIR}/bin/activate.d/${APP_NAME}.sh (applies when venv is activated)"
  echo
}

install_miniforge() {
  # Install Miniforge (conda) if not present at /opt/conda and initialize for non-interactive shells
  if [ ! -x /opt/conda/bin/conda ]; then
    local ARCH MF_ARCH
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64) MF_ARCH=Linux-x86_64 ;;
      aarch64|arm64) MF_ARCH=Linux-aarch64 ;;
      *) MF_ARCH=Linux-x86_64 ;;
    esac
    wget -qO /tmp/miniforge.sh "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$MF_ARCH.sh"
    bash /tmp/miniforge.sh -b -p /opt/conda || true
    rm -f /tmp/miniforge.sh || true
    ln -sf /opt/conda/bin/conda /usr/local/bin/conda || true
  fi

  # Initialize conda for non-interactive shells
  if [ -f /opt/conda/etc/profile.d/conda.sh ]; then
    printf "%s\n" ". /opt/conda/etc/profile.d/conda.sh" > /etc/profile.d/conda.sh || true
  fi
  if [ -f /opt/conda/etc/profile.d/conda.sh ]; then
    if ! grep -q "^BASH_ENV=" /etc/environment 2>/dev/null; then
      printf "%s\n" "BASH_ENV=/etc/profile.d/conda.sh" >> /etc/environment || true
    fi
    export BASH_ENV=/etc/profile.d/conda.sh
  fi

  # Load conda in current shell if available
  if [ -f /etc/profile.d/conda.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/conda.sh || true
  fi
}

create_pytensor_timeout_shims() {
  # Create shim executables so wrappers like `timeout` can handle inline env assignments
  # Example: `PYTENSOR_FLAGS=... python ...` becomes an executable named literally as the first token
  local f
  f="/usr/local/bin/PYTENSOR_FLAGS=floatX=float64,gcc__cxxflags=-march=core2"
  printf "%s\n" "#!/usr/bin/env bash" \
    "export PYTENSOR_FLAGS=\"floatX=float64,gcc__cxxflags='-march=core2'\"" \
    "exec \"\$@\"" > "$f" || true
  chmod +x "$f" || true

  f="/usr/local/bin/PYTENSOR_FLAGS=floatX=float32,gcc__cxxflags=-march=core2"
  printf "%s\n" "#!/usr/bin/env bash" \
    "export PYTENSOR_FLAGS=\"floatX=float32,gcc__cxxflags='-march=core2'\"" \
    "exec \"\$@\"" > "$f" || true
  chmod +x "$f" || true
}

setup_tmp_safety() {
  # Ensure /tmp has correct permissions and route TMPDIR to a stable, container-local sticky dir
  chmod 1777 /tmp || true
  mkdir -p /app/.tmp && chmod 1777 /app/.tmp || true
  # Export for current shell
  export TMPDIR="/app/.tmp"
  # Avoid persisting to global /etc/environment to keep non-interactive shells clean
}

cleanup_global_shell_init() {
  # Remove global shell init hooks and shims that can affect non-interactive shells or CI supervisors
  unset BASH_ENV || true
  sed -i '/^BASH_ENV=\/etc\/profile\.d\/conda\.sh/d' /etc/environment 2>/dev/null || true
  rm -f /etc/profile.d/conda.sh /etc/profile.d/auto-venv.sh 2>/dev/null || true
  rm -f "/usr/local/bin/PYTENSOR_FLAGS=floatX=float64,gcc__cxxflags=-march=core2" "/usr/local/bin/PYTENSOR_FLAGS=floatX=float32,gcc__cxxflags=-march=core2" 2>/dev/null || true
  rm -f /usr/local/bin/conda 2>/dev/null || true
  rm -rf /opt/conda 2>/dev/null || true
  # Clean user shell init files of references to conda/auto-venv
  for f in "${HOME:-/root}/.bashrc" "${HOME:-/root}/.profile"; do
    [ -f "$f" ] && sed -i "/conda\.sh/d;/auto-venv\.sh/d" "$f" || true
  done
}

setup_auto_activate() {
  # Write auto-activation to the user's bashrc only (avoid system-wide profile.d changes)
  local bashrc_file="${HOME:-/root}/.bashrc"
  local activate_path="${PROJECT_ROOT}/${VENV_DIR}/bin/activate"
  local activate_line="source ${activate_path}"

  if [ -f "$activate_path" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi

  # Intentionally avoid creating system-wide profile.d scripts to prevent affecting non-interactive shells
}

# --------------- Main ---------------
main() {
  # Perform out-of-band cleanup using a sanitized shell that bypasses global init hooks
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -lc 'set -eux; chmod 1777 /tmp || true; mkdir -p /app/.tmp && chmod 1777 /app/.tmp || true; [ -f /etc/environment ] && sed -i "/^BASH_ENV=/d" /etc/environment || true; for f in /root/.bashrc /root/.profile /root/.bash_profile /etc/skel/.bashrc; do [ -f "$f" ] && sed -i "/BASH_ENV/d;/conda\.sh/d;/mamba\.sh/d;/auto-venv\.sh/d" "$f" || true; done; find /etc/profile.d -maxdepth 1 -type f \( -name "*conda*.sh" -o -name "*mamba*.sh" -o -name "auto-venv.sh" \) -delete 2>/dev/null || true; find /usr/local/bin -maxdepth 1 -type f -name "PYTENSOR_FLAGS=*" -delete 2>/dev/null || true; rm -f /usr/local/bin/conda /usr/local/bin/mamba 2>/dev/null || true; rm -rf /opt/conda /opt/mamba 2>/dev/null || true'
  env -i DEBIAN_FRONTEND=noninteractive PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -lc 'set -eux; if command -v apt-get >/dev/null 2>&1; then apt-get update -y && (apt-get install -y --reinstall bash libc6 libtinfo6 libreadline8 || apt-get install -y bash libc6 libtinfo6 libreadline8) && apt-get install -y --no-install-recommends coreutils grep gawk sed tar gzip ca-certificates wget bzip2 curl git && apt-get clean && rm -rf /var/lib/apt/lists/*; elif command -v dnf >/dev/null 2>&1; then dnf -y reinstall bash glibc readline ncurses-libs || dnf -y install bash glibc readline ncurses-libs; dnf -y install coreutils grep gawk sed tar gzip ca-certificates wget bzip2 curl git; dnf clean all; elif command -v yum >/dev/null 2>&1; then yum -y reinstall bash glibc readline ncurses-libs || yum -y install bash glibc readline ncurses-libs; yum -y install coreutils grep gawk sed tar gzip ca-certificates wget bzip2 curl git; yum clean all; elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache --upgrade bash readline ncurses-libs musl coreutils grep gawk sed tar gzip ca-certificates wget bzip2 curl git; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh && zypper --non-interactive install -y --force-resolution bash readline ncurses-utils glibc ca-certificates curl git tar gzip sed gawk coreutils grep; zypper clean --all; else echo "Unsupported base image: no known package manager found." >&2; exit 1; fi'
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -lc 'set -eux; bash --noprofile --norc -lc "echo BASH_OK"'

  log "Starting environment setup for ${APP_NAME}"
  log "Project directory: ${PROJECT_ROOT}"

  # Create user (optional)
  create_app_user

  # Ensure directories
  setup_directories

  # Configure safer temp handling
  setup_tmp_safety

  # Install system packages using a sanitized shell to avoid global init hooks
  env -i DEBIAN_FRONTEND=noninteractive PATH=/usr/sbin:/usr/bin:/sbin:/bin TMPDIR=/app/.tmp /bin/sh -lc 'set -eux; if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y --no-install-recommends ca-certificates wget bzip2 curl git build-essential gcc g++ gfortran make pkg-config python3 python3-venv python3-pip python3-dev libopenblas-dev liblapack-dev libgomp1 locales && (command -v locale-gen >/dev/null 2>&1 && locale-gen C.UTF-8 || true) && apt-get clean && rm -rf /var/lib/apt/lists/*; elif command -v dnf >/dev/null 2>&1; then dnf install -y ca-certificates wget bzip2 curl git gcc gcc-c++ gcc-gfortran make pkgconfig python3 python3-pip python3-devel openblas-devel lapack-devel glibc-locale-source glibc-langpack-en && dnf clean all; elif command -v yum >/dev/null 2>&1; then yum install -y ca-certificates wget bzip2 curl git gcc gcc-c++ gcc-gfortran make pkgconfig python3 python3-pip python3-devel openblas-devel lapack-devel && yum clean all; elif command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache ca-certificates wget bzip2 curl git build-base gfortran pkgconfig python3 py3-pip python3-dev py3-virtualenv openblas-dev lapack-dev libgomp; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh && zypper --non-interactive install -y ca-certificates curl git gcc gcc-c++ gcc-fortran make pkg-config python3 python3-pip python3-devel libopenblas-devel lapack-devel && zypper clean --all; else echo "Unsupported base image: no known package manager found." >&2; exit 1; fi'

  # Skipping Miniforge (conda) installation to avoid modifying shell init for non-interactive shells
  :

  # Skipping PYTENSOR_FLAGS shim creation to avoid modifying system paths mid-run
  :

  # Provision venv and Python deps using sanitized shells (avoid global init hooks)
  env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin TMPDIR=/app/.tmp /bin/sh -lc 'set -eux; mkdir -p /app /app/logs /app/data /app/.cache; if [ ! -d /app/.venv ]; then python3 -m venv /app/.venv; fi; /app/.venv/bin/python -m pip install --upgrade --no-cache-dir pip setuptools wheel cython'

  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin TMPDIR=/app/.tmp /bin/sh -lc 'set -eux; if [ -f /app/requirements.txt ]; then /app/.venv/bin/python -m pip install --no-cache-dir -r /app/requirements.txt; else echo "requirements.txt not found; skipping"; fi'

  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin TMPDIR=/app/.tmp /bin/sh -lc 'set -eux; cd /app; if [ -f pyproject.toml ] || [ -f setup.py ]; then /app/.venv/bin/python -m pip install --no-cache-dir -e .; else echo "No project metadata found; skipping project install"; fi'

  env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -lc 'set -eux; cat > /app/.env <<'"'"'"'"'"'EOF'"'"'"'"'"'
# Auto-generated environment file for pymc-project
PYTHONUNBUFFERED=1
PYTHONIOENCODING=UTF-8
PIP_NO_CACHE_DIR=1
XDG_CACHE_HOME=/app/.cache
OMP_NUM_THREADS=1
OPENBLAS_NUM_THREADS=1
MKL_NUM_THREADS=1
NUMEXPR_NUM_THREADS=1
PYTENSOR_FLAGS=device=cpu,openmp=True
EOF
mkdir -p /app/.venv/bin/activate.d
cat > /app/.venv/bin/activate.d/pymc-project.sh <<'"'"'"'"'"'EOF'"'"'"'"'"'
export PYTHONUNBUFFERED=1
export PYTHONIOENCODING=UTF-8
export PIP_NO_CACHE_DIR=1
export XDG_CACHE_HOME="/app/.cache"
export OMP_NUM_THREADS="1"
export OPENBLAS_NUM_THREADS="1"
export MKL_NUM_THREADS="1"
export NUMEXPR_NUM_THREADS="1"
export PYTENSOR_FLAGS="device=cpu,openmp=True"
EOF'

  # Add venv auto-activation to root bashrc
  env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -lc 'set -eux; if [ -f /app/.venv/bin/activate ]; then grep -qxF "source /app/.venv/bin/activate" /root/.bashrc 2>/dev/null || { printf "\n# Auto-activate Python virtual environment\nsource /app/.venv/bin/activate\n" >> /root/.bashrc; }; fi'

  # Persist environment configuration for interactive sessions
  write_env_files

  # Also call in-script auto-activation helper (deduplicated)
  setup_auto_activate

  # Final summary
  print_summary
}

main "$@"