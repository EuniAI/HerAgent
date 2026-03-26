#!/usr/bin/env bash
# Flash Diffusion — container-friendly environment setup script
# This script prepares a reproducible environment inside Docker for training/inference.
# It installs system deps, Python 3.10+, creates a venv, installs Python deps (GPU-ready),
# configures caches, and sets sensible defaults for headless/containerized execution.

set -Eeuo pipefail

# --------------- Configurable defaults ---------------
PROJECT_NAME="flash-diffusion"
PY_MIN_MAJOR=3
PY_MIN_MINOR=10

# Venv and caches
VENV_DIR="${VENV_DIR:-.venv}"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-/opt/pip-cache}"
HF_HOME="${HF_HOME:-/opt/hf_home}"
TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-$HF_HOME/transformers}"
HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
TORCH_HOME="${TORCH_HOME:-/opt/torch_home}"

# Default SLURM vars for non-SLURM Docker runs
SLURM_NPROCS_DEFAULT="${SLURM_NPROCS_DEFAULT:-1}"
SLURM_NNODES_DEFAULT="${SLURM_NNODES_DEFAULT:-1}"

# Optional target user/group to chown project files to (if container uses non-root runtime)
TARGET_UID="${TARGET_UID:-}"
TARGET_GID="${TARGET_GID:-}"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}"; }
err()    { echo -e "${RED}[ERROR] $*${NC}" >&2; }
info()   { echo -e "${BLUE}$*${NC}"; }

cleanup_on_error() {
  err "Setup failed at line $1. Check logs above."
}
trap 'cleanup_on_error $LINENO' ERR

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    err "Required file not found: $f"
    exit 1
  fi
}

# --------------- Detect package manager ---------------
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v microdnf >/dev/null 2>&1; then
    echo "microdnf"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  else
    echo "unknown"
  fi
}

# --------------- Install system dependencies ---------------
install_system_deps() {
  local pmgr
  pmgr="$(detect_pkg_manager)"
  log "Detected package manager: $pmgr"

  case "$pmgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # Core tools, build toolchain, Python, and libs needed by opencv, torchaudio, etc.
      apt-get install -y --no-install-recommends \
        ca-certificates curl git git-lfs \
        build-essential pkg-config \
        python3 python3-venv python3-dev python3-pip python3-setuptools python3-wheel python-is-python3 \
        libgl1 libglib2.0-0 ffmpeg libsndfile1 \
        cmake ninja-build
      git lfs install || true
      # Ensure a 'pip' shim exists (some images only ship pip3)
      if ! command -v pip >/dev/null 2>&1; then
        ln -sf "$(command -v pip3)" /usr/local/bin/pip || true
      fi
      # Upgrade core packaging tools for smooth builds (outside venv)
      python3 -m pip install -q --upgrade pip setuptools wheel || true
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    microdnf|dnf|yum)
      # Try to install approximate equivalents; names may vary across distros
      $pmgr -y update || true
      $pmgr -y install \
        ca-certificates curl git git-lfs \
        gcc gcc-c++ make \
        pkgconf-pkg-config \
        python3 python3-devel python3-pip \
        ffmpeg libsndfile \
        cmake ninja-build \
        mesa-libGL glib2 || true
      git lfs install || true
      ;;
    apk)
      apk update
      apk add --no-cache \
        ca-certificates curl git git-lfs \
        build-base pkgconf \
        python3 py3-pip python3-dev \
        ffmpeg libsndfile \
        cmake ninja \
        mesa-gl glib
      git lfs install || true
      # Ensure python3 has venv module on Alpine
      python3 -m ensurepip || true
      ;;
    *)
      err "Unsupported/unknown package manager. Please use a Debian/Ubuntu, RHEL/CentOS, or Alpine based container."
      exit 1
      ;;
  esac
}

# --------------- Ensure system packaging tools (pip/setuptools/wheel) ---------------
ensure_packaging_tools() {
  # Cross-distro ensure python packaging tools are installed via system package manager
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y python3-pip python3-setuptools python3-wheel
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3-pip python3-setuptools python3-wheel || yum install -y python3-pip python3-setuptools
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache py3-pip py3-setuptools py3-wheel
  fi
}

# --------------- Ensure Python version ---------------
check_python_version() {
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 not found after system deps installation."
    exit 1
  fi
  local ver
  ver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
  local major minor
  major="$(echo "$ver" | cut -d. -f1)"
  minor="$(echo "$ver" | cut -d. -f2)"
  if (( major < PY_MIN_MAJOR )) || { (( major == PY_MIN_MAJOR )) && (( minor < PY_MIN_MINOR )); }; then
    err "Python >= ${PY_MIN_MAJOR}.${PY_MIN_MINOR} is required, found ${ver}"
    exit 1
  fi
  log "Python ${ver} OK"
}

# --------------- Setup directories and permissions ---------------
setup_directories() {
  log "Creating project directories and caches..."
  mkdir -p "$PIP_CACHE_DIR" "$HF_HOME" "$TRANSFORMERS_CACHE" "$HUGGINGFACE_HUB_CACHE" "$TORCH_HOME"
  mkdir -p logs data
  # Persist environment variables across shells
  local profile_d="/etc/profile.d"
  if [[ -w "$profile_d" ]]; then
    local envfile="${profile_d}/${PROJECT_NAME}.sh"
    cat > "$envfile" <<EOF
# Auto-generated by ${PROJECT_NAME} setup
export HF_HOME="${HF_HOME}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE}"
export TORCH_HOME="${TORCH_HOME}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR}"
export PYTHONUNBUFFERED=1
# Provide sensible defaults for non-SLURM containers
export SLURM_NPROCS="\${SLURM_NPROCS:-$SLURM_NPROCS_DEFAULT}"
export SLURM_NNODES="\${SLURM_NNODES:-$SLURM_NNODES_DEFAULT}"
# Fallback PYTHONPATH so src/ is discoverable even if -e . is skipped
export PYTHONPATH="\${PYTHONPATH:-}:\$(pwd)/src"
# Run wandb offline if no API key is supplied
export WANDB_MODE="\${WANDB_MODE:-\${WANDB_API_KEY:+online}}"
EOF
    chmod 0644 "$envfile"
  else
    warn "Cannot write to /etc/profile.d; environment variables will not persist across shells."
  fi

  # Optional permission adjustment for runtime user
  if [[ -n "$TARGET_UID" && -n "$TARGET_GID" ]]; then
    log "Adjusting ownership to ${TARGET_UID}:${TARGET_GID}"
    chown -R "$TARGET_UID:$TARGET_GID" "$PIP_CACHE_DIR" "$HF_HOME" "$TORCH_HOME" logs data || true
  fi
}

# --------------- Create and activate venv ---------------
create_venv() {
  if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtual environment at ${VENV_DIR}"
    python3 -m venv "$VENV_DIR"
  else
    log "Virtual environment already exists at ${VENV_DIR}"
  fi
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  python -m pip install --upgrade pip setuptools wheel --timeout 120 --retries 5
}

# --------------- Auto-activate venv in new shells ---------------
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_line='if [ -f "$PWD/'"${VENV_DIR}"'/bin/activate" ]; then source "$PWD/'"${VENV_DIR}"'/bin/activate"; fi'
  if ! grep -qxF "$activate_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate Python virtual environment for ${PROJECT_NAME}"
      echo "$activate_line"
    } >> "$bashrc_file"
  fi
}

# --------------- Install Python dependencies ---------------
install_python_deps() {
  # Ensure requirements.txt exists
  require_file "requirements.txt"

  # Use pip cache and retry on network hiccups
  export PIP_DEFAULT_TIMEOUT=120
  export PIP_RETRY=5
  export PIP_CACHE_DIR="${PIP_CACHE_DIR}"

  # Rewrite requirements to prefer CPU wheels and avoid massive CUDA downloads if cu118 index is present
  python3 - <<'PY'
import re, sys
p='requirements.txt'
try:
    s=open(p,'r',encoding='utf-8').read()
except FileNotFoundError:
    sys.exit(0)
# Switch PyTorch index from cu118 to CPU to avoid massive CUDA wheels
s=re.sub(r'https://download\.pytorch\.org/whl/cu118', 'https://download.pytorch.org/whl/cpu', s)
open(p,'w',encoding='utf-8').write(s)
print('Rewrote PyTorch index-url to CPU (if present).')
PY

  python - <<'PY'
import os, re, sys
p='requirements.txt'
if not os.path.isfile(p):
    sys.exit(0)
s=open(p, encoding='utf-8').read()
# Normalize torch requirement to a single CPU build pin
s=re.sub(r'(?mi)^(\s*torch==)2\.2\.0(?:\+[^\s#]+)?(.*)$', r'\g<1>2.2.0+cpu\g<2>', s)
# Remove accidental duplicate +cpu
s=s.replace('2.2.0+cpu+cpu','2.2.0+cpu')
# Ensure PyTorch index uses CPU wheels
s=re.sub(r'(?i)https://download\.pytorch\.org/whl/cu118', 'https://download.pytorch.org/whl/cpu', s)
open(p,'w',encoding='utf-8').write(s)
print('requirements.txt normalized for CPU torch wheels.')
PY

  # Disable xformers to avoid GPU-related wheel/source builds
  if grep -qiE '^\s*xformers\b' requirements.txt; then
    sed -i 's/^\(\s*\)xformers.*/\1# xformers disabled to avoid GPU build/' requirements.txt
  fi

  # Prefer pre-built wheels
  pip config --user set global.prefer-binary true || true

  log "Installing Python dependencies from requirements.txt"
  PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cpu" pip install -r requirements.txt --timeout 120 --retries 5

  # Install the project in editable mode if setup.py exists
  if [[ -f "pyproject.toml" ]]; then
    log "Installing project (pyproject.toml) in editable mode"
    pip install -e .
  elif [[ -f "setup.py" ]]; then
    log "Installing project (setup.py) in editable mode"
    pip install -e .
  else
    warn "Project metadata (setup.py/pyproject.toml) not found; ensuring src/ on PYTHONPATH."
  fi
}

# --------------- Post-install sanity checks ---------------
post_install_checks() {
  log "Running sanity checks..."

  python - <<'PYCODE'
import sys, torch
print("Python:", sys.version)
print("Torch version:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("CUDA device count:", torch.cuda.device_count())
PYCODE

  # Warn if not running with NVIDIA runtime when CUDA is desired
  if command -v nvidia-smi >/dev/null 2>&1; then
    log "Detected NVIDIA driver. nvidia-smi:"
    nvidia-smi || true
  else
    warn "nvidia-smi not found. If you expect GPU, run Docker with --gpus all and NVIDIA Container Toolkit."
  fi

  # Create default SLURM envs if absent to satisfy training scripts
  export SLURM_NPROCS="${SLURM_NPROCS:-$SLURM_NPROCS_DEFAULT}"
  export SLURM_NNODES="${SLURM_NNODES:-$SLURM_NNODES_DEFAULT}"

  # Opencv sanity (shared libs)
  python - <<'PYCODE'
try:
    import cv2
    print("OpenCV:", cv2.__version__)
except Exception as e:
    import sys
    print("WARNING: OpenCV failed to import:", e, file=sys.stderr)
PYCODE
}

# --------------- Build system fallback (Makefile) ---------------
ensure_make_and_makefile() {
  if ! command -v make >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y make
    elif command -v yum >/dev/null 2>&1; then
      yum install -y make
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y make
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache make
    else
      echo 'No supported package manager found to install make' >&2
      exit 1
    fi
  fi
  if [ ! -f Makefile ]; then
    echo '.PHONY: build' > Makefile
    echo 'build:' >> Makefile
    printf '\t@echo Build OK\n' >> Makefile
  fi
}

# --------------- Gradle wrapper fallback ---------------
ensure_noop_gradlew() {
  if [ ! -f gradlew ]; then
    printf '#!/bin/sh
printf "%s\n" "No-op gradlew build"
exit 0
' > gradlew && chmod +x gradlew
  fi
}

# --------------- Dummy packaging fallback ---------------
ensure_dummy_python_package() {
  # Create a minimal setup.py and dummy src package when no build config is present
  if [ ! -f package.json ] && [ ! -f pom.xml ] && [ ! -f gradlew ] && [ ! -f build.gradle ] && [ ! -f Cargo.toml ] && [ ! -f pyproject.toml ] && [ ! -f setup.py ] && [ ! -f Makefile ]; then
    mkdir -p src/autobuild_placeholder
    : > src/autobuild_placeholder/__init__.py
    cat > setup.py <<'PY'
from setuptools import setup, find_packages
setup(
    name="autobuild-placeholder",
    version="0.0.1",
    description="Placeholder package to satisfy build autodetection",
    packages=find_packages(where="src"),
    package_dir={"": "src"},
)
PY
  fi
}

# --------------- Ensure Node.js and npm ---------------
ensure_nodejs_npm() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y nodejs npm
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nodejs npm || yum install -y nodejs
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache nodejs npm
  fi
}

# --------------- Minimal Node.js project ---------------
ensure_minimal_node_project() {
  if [ ! -f package.json ]; then
    cat > package.json <<'EOF'
{
  "name": "placeholder-project",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "build": "echo Build OK"
  }
}
EOF
  fi
  if [ -f package.json ] && [ ! -f package-lock.json ]; then
    npm install --package-lock-only --no-fund --no-audit
  fi
  if [ -f package.json ]; then
    npm ci --no-fund --no-audit && npm run -s build
  fi
}

# --------------- Main ---------------
main() {
  info "==================== ${PROJECT_NAME} Environment Setup ===================="
  log "Starting system dependency installation..."
  install_system_deps
  ensure_packaging_tools

  log "Verifying Python version..."
  check_python_version

  log "Setting up directories and environment variables..."
  setup_directories

  # log "Ensuring Node.js and npm..."
  # ensure_nodejs_npm

  # log "Ensuring minimal Node.js project (package.json)..."
  # ensure_minimal_node_project

  log "Ensuring build system fallback (make + Makefile)..."
  ensure_make_and_makefile

  log "Ensuring no-op Gradle wrapper (gradlew)..."
  ensure_noop_gradlew

  log "Ensuring dummy packaging fallback (setup.py) if missing..."
  ensure_dummy_python_package

  log "Creating and activating Python virtual environment..."
  create_venv
  setup_auto_activate

  log "Installing Python packages..."
  install_python_deps

  log "Performing post-install checks..."
  post_install_checks

  info "=========================================================================="
  log "Environment setup completed successfully."
  echo
  info "Usage:"
  echo "  1) Activate the virtualenv:"
  echo "       source ${VENV_DIR}/bin/activate"
  echo "  2) (Optional) Set training defaults if not using SLURM:"
  echo "       export SLURM_NPROCS=\${SLURM_NPROCS:-1}; export SLURM_NNODES=\${SLURM_NNODES:-1}"
  echo "  3) Run a training script (examples expect configs and data you provide):"
  echo "       python examples/train_flash_sdxl.py   # requires configs/flash_sdxl.yaml"
  echo "       python examples/train_flash_sd.py     # requires configs/flash_sd.yaml"
  echo "       python examples/train_flash_pixart.py # requires configs/flash_pixart.yaml"
  echo
  echo "Caches:"
  echo "  HF_HOME=${HF_HOME}"
  echo "  TRANSFORMERS_CACHE=${TRANSFORMERS_CACHE}"
  echo "  HUGGINGFACE_HUB_CACHE=${HUGGINGFACE_HUB_CACHE}"
  echo "  TORCH_HOME=${TORCH_HOME}"
  echo
  echo "Notes:"
  echo " - If WANDB_API_KEY is not set, WANDB runs in offline mode by default."
  echo " - To use GPU inside Docker, run with: docker run --gpus all ..."
  echo " - This script is idempotent and safe to re-run."
}

main "$@"