#!/usr/bin/env bash
# Felafax environment setup script
# This script prepares a Docker-friendly environment to develop and run Felafax.
# It installs system packages, creates a Python virtual environment, installs Python dependencies,
# configures cache directories, and sets persistent environment variables.
#
# Usage examples:
#   ./setup_env.sh
#   ./setup_env.sh --accelerator cpu
#   ./setup_env.sh --accelerator tpu
#   ./setup_env.sh --app-dir /opt/felafax --venv-dir /opt/venv
#
# Notes:
# - Designed to run as root inside a Docker container. If not root, it will skip system package installation.
# - Default accelerator is CPU. TPU support requires Google Cloud TPU runtime; CUDA/ROCm require matching wheels.
#
# Idempotent: Safe to run multiple times.

set -Eeuo pipefail

#========================
# Configurable defaults
#========================
APP_DIR_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VENV_DIR_DEFAULT="/opt/venv"
PYTHON_BIN_DEFAULT="python3"
ACCELERATOR_DEFAULT="cpu"   # valid: cpu | tpu | cuda | rocm
NONINTERACTIVE="${DEBIAN_FRONTEND:-noninteractive}"

#========================
# Colors and logging
#========================
if command -v tput >/dev/null 2>&1 && [ -n "${TERM:-}" ]; then
  GREEN="$(tput setaf 2 || true)"; YELLOW="$(tput setaf 3 || true)"; RED="$(tput setaf 1 || true)"; BOLD="$(tput bold || true)"; RESET="$(tput sgr0 || true)"
else
  GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${RESET}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${RESET}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${RESET}" >&2; }
fatal()  { error "$*"; exit 1; }

trap 'error "An error occurred at line $LINENO. Aborting."' ERR

#========================
# Parse arguments
#========================
APP_DIR="$APP_DIR_DEFAULT"
VENV_DIR="$VENV_DIR_DEFAULT"
PYTHON_BIN="$PYTHON_BIN_DEFAULT"
ACCELERATOR="$ACCELERATOR_DEFAULT"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}" # set to 1 to force reinstall deps

usage() {
  cat <<EOF
Felafax environment setup

Options:
  --app-dir DIR         Project root directory (default: $APP_DIR_DEFAULT)
  --venv-dir DIR        Virtualenv directory (default: $VENV_DIR_DEFAULT)
  --python-bin BIN      Python executable to use (default: $PYTHON_BIN_DEFAULT)
  --accelerator TYPE    Accelerator backend: cpu | tpu | cuda | rocm (default: cpu)
  --force-reinstall     Force reinstallation of Python dependencies
  -h, --help            Show this help

Environment overrides:
  FORCE_REINSTALL=1     Same as --force-reinstall
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir) APP_DIR="${2:?}"; shift 2 ;;
    --venv-dir) VENV_DIR="${2:?}"; shift 2 ;;
    --python-bin) PYTHON_BIN="${2:?}"; shift 2 ;;
    --accelerator) ACCELERATOR="${2:?}"; shift 2 ;;
    --force-reinstall) FORCE_REINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fatal "Unknown argument: $1" ;;
  esac
done

# Normalize paths
APP_DIR="$(cd "$APP_DIR" && pwd -P)"
VENV_DIR="$(mkdir -p "$VENV_DIR" && cd "$VENV_DIR" && pwd -P)"

#========================
# Helpers: distro and pkg manager
#========================
PKG_MGR=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
IS_ROOT=0

detect_pkg_manager() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then IS_ROOT=1; fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_UPDATE="dnf -y makecache"
    PKG_INSTALL="dnf install -y"
    PKG_CLEAN="dnf clean all && rm -rf /var/cache/dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_UPDATE="yum -y makecache"
    PKG_INSTALL="yum install -y"
    PKG_CLEAN="yum clean all && rm -rf /var/cache/yum"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    PKG_UPDATE="true"  # apk updates indices with add
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
  else
    PKG_MGR="unknown"
  fi
}

#========================
# System packages
#========================
install_system_packages() {
  if [[ $IS_ROOT -ne 1 ]]; then
    warn "Not running as root; skipping system package installation."
    return 0
  fi

  detect_pkg_manager
  if [[ "$PKG_MGR" == "unknown" ]]; then
    warn "Unknown package manager. Skipping system packages. Ensure Python 3.10+, venv, build tools, git, curl, ca-certificates are installed."
    return 0
  fi

  log "Installing system packages using $PKG_MGR..."
  export DEBIAN_FRONTEND="$NONINTERACTIVE"
  case "$PKG_MGR" in
    apt)
      eval "$PKG_UPDATE"
      eval "$PKG_INSTALL" \
        bash dos2unix curl ca-certificates git git-lfs \
        build-essential pkg-config \
        python3 python3-venv python3-dev python3-pip \
        openssl libssl-dev libffi-dev \
        tzdata
      # ensure /usr/bin/python3 is default
      update-alternatives --install /usr/bin/python python /usr/bin/python3 1 || true
      git lfs install --system || true
      eval "$PKG_CLEAN"
      ;;
    dnf|yum)
      eval "$PKG_UPDATE"
      eval "$PKG_INSTALL" \
        bash dos2unix curl ca-certificates git git-lfs \
        gcc gcc-c++ make pkgconfig \
        python3 python3-devel python3-pip \
        openssl openssl-devel libffi libffi-devel \
        tzdata
      git lfs install --system || true
      eval "$PKG_CLEAN"
      ;;
    apk)
      # On Alpine we use musl and package names differ
      eval "$PKG_INSTALL" \
        bash dos2unix curl ca-certificates git git-lfs \
        build-base linux-headers \
        python3 py3-pip py3-virtualenv python3-dev \
        openssl openssl-dev libffi libffi-dev \
        tzdata
      git lfs install --system || true
      ;;
  esac
  log "System packages installed."
}

#========================
# Python and venv
#========================
ensure_python() {
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    fatal "Python binary '$PYTHON_BIN' not found. Install Python 3.10+ or run as root so the script can install it."
  fi
  local ver
  ver="$("$PYTHON_BIN" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  log "Found Python: $PYTHON_BIN ($ver)"
  # Require >= 3.10
  "$PYTHON_BIN" - <<'PYCHK'
import sys
maj, min = sys.version_info[:2]
assert (maj, min) >= (3, 10), f"Python >= 3.10 is required, found {sys.version}"
PYCHK
}

create_venv() {
  # Create venv if missing
  if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
    log "Creating virtual environment at $VENV_DIR ..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  else
    log "Virtual environment already exists at $VENV_DIR"
  fi

  # Activate venv
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"

  # Upgrade pip tooling
  python -m pip install --upgrade pip setuptools wheel build
  # Keep cache enabled to speed up subsequent runs inside persistent containers
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_ROOT_USER_ACTION=ignore
}

#========================
# Project installation
#========================
install_python_dependencies() {
  # Activate venv
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"

  # Determine if project looks installable
  if [[ -f "$APP_DIR/pyproject.toml" ]]; then
    log "Installing project from $APP_DIR ..."
    pushd "$APP_DIR" >/dev/null

    # Safety: make git happy if running as root in Docker
    if command -v git >/dev/null 2>&1; then
      git config --global --add safe.directory "$APP_DIR" || true
    fi

    # If FORCE_REINSTALL=1, reinstall; else install if not already installed
    local need_install=1
    if python - <<'PYCHK' 2>/dev/null; then
import pkgutil; import sys
sys.exit(0 if pkgutil.find_loader("felafax") else 1)
PYCHK
      if [[ "${FORCE_REINSTALL}" -eq 1 ]]; then
        log "Package 'felafax' already present; force reinstall enabled."
        need_install=1
      else
        log "Package 'felafax' appears installed; skipping reinstall."
        need_install=0
      fi
    fi

    if [[ $need_install -eq 1 ]]; then
      # Editable install helps development; switch to non-editable if you prefer sealed image
      python -m pip install -e .
    fi
    popd >/dev/null
  else
    warn "No pyproject.toml found in $APP_DIR; skipping project install."
  fi
}

#========================
# Accelerator-specific JAX handling
#========================
configure_jax_for_accelerator() {
  # Activate venv
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"

  case "$ACCELERATOR" in
    cpu)
      log "Using CPU accelerator (default)."
      export JAX_PLATFORM_NAME="cpu"
      ;;
    tpu)
      log "Configuring JAX for TPU..."
      # TPU installation requires special wheel source for libtpu
      # Attempt to install/upgrade TPU packages. This is idempotent.
      python -m pip install --upgrade "jax[tpu]" -f https://storage.googleapis.com/jax-releases/libtpu_releases.html || {
        warn "Could not install jax[tpu] from TPU releases. Ensure this is running on a TPU runtime."
      }
      export JAX_PLATFORM_NAME="tpu"
      ;;
    cuda)
      warn "CUDA accelerator selected. JAX CUDA wheels require matching CUDA/cudnn versions."
      warn "If this container already has CUDA, you may install a matching jaxlib wheel manually."
      warn "For example (adjust versions): pip install --upgrade 'jax[cuda12]' -f https://storage.googleapis.com/jax-releases/jax_cuda_releases.html"
      export JAX_PLATFORM_NAME="gpu"
      ;;
    rocm)
      warn "ROCm accelerator selected. Ensure ROCm runtime is present in the container host/runtime."
      warn "You may need: pip install --upgrade 'jax[rocm]' -f https://storage.googleapis.com/jax-releases/jax_rocm_releases.html"
      export JAX_PLATFORM_NAME="gpu"
      ;;
    *)
      warn "Unknown accelerator '$ACCELERATOR'; defaulting to CPU."
      export JAX_PLATFORM_NAME="cpu"
      ;;
  esac
}

#========================
# Directories and permissions
#========================
setup_directories() {
  log "Setting up project directories under $APP_DIR ..."
  mkdir -p "$APP_DIR"/{data,checkpoints,outputs,logs,configs,notebooks,scripts}
  # Caches for HuggingFace and others
  mkdir -p /opt/hf/{hub,transformers,datasets} || true
  mkdir -p /opt/.cache || true

  # Ensure writable permissions for common container users
  # Avoid overly permissive modes; grant group write if running as root
  if [[ $IS_ROOT -eq 1 ]]; then
    chmod -R g+rwX "$APP_DIR" /opt/hf /opt/.cache || true
  fi
}

#========================
# Environment variables profile
#========================
write_env_profile() {
  log "Writing environment configuration to /etc/profile.d/felafax_env.sh (if permitted) ..."
  local env_file="/etc/profile.d/felafax_env.sh"
  local tmp_file
  tmp_file="$(mktemp)"

  cat >"$tmp_file" <<EOF
# Felafax environment
export PATH="$VENV_DIR/bin:\$PATH"
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_ROOT_USER_ACTION=ignore

# HuggingFace caches
export HF_HOME="/opt/hf"
export HUGGINGFACE_HUB_CACHE="/opt/hf/hub"
export TRANSFORMERS_CACHE="/opt/hf/transformers"
export DATASETS_CACHE="/opt/hf/datasets"
export XDG_CACHE_HOME="/opt/.cache"

# JAX runtime selection
export JAX_PLATFORM_NAME="${JAX_PLATFORM_NAME:-cpu}"

# Felafax specific
export FELAFAX_ENV="production"
export FELAFAX_APP_DIR="$APP_DIR"
EOF

  if [[ $IS_ROOT -eq 1 ]]; then
    mv "$tmp_file" "$env_file"
    chmod 0644 "$env_file"
  else
    warn "No permission to write $env_file. Writing to $APP_DIR/.felafax_env instead."
    mv "$tmp_file" "$APP_DIR/.felafax_env"
    echo 'To load env in new shells: source "$APP_DIR/.felafax_env"' >&2
  fi
}

#========================
# Shell and profile helpers
#========================
ensure_term_profile() {
  # Ensure TERM is set for current and future shells to avoid tput warnings
  export TERM="${TERM:-xterm}"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    printf 'export TERM=${TERM:-xterm}\n' > /etc/profile.d/term.sh || true
    chmod 0644 /etc/profile.d/term.sh || true
  else
    if ! grep -q 'export TERM=' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export TERM=${TERM:-xterm}' >> "$HOME/.bashrc"
    fi
  fi
}

fix_line_endings_and_shebang() {
  # Normalize line endings and shebang for this script if present at canonical path
  local script_path="/app/prometheus_setup.sh"
  if command -v dos2unix >/dev/null 2>&1 && [ -f "$script_path" ]; then
    dos2unix -q "$script_path" || true
  fi
  if [ -f "$script_path" ]; then
    if ! head -n1 "$script_path" | grep -q "^#!/usr/bin/env bash$"; then
      sed -i '1s|^.*$|#!/usr/bin/env bash|' "$script_path" || true
    fi
    chmod +x "$script_path" || true
  fi
  if command -v bash >/dev/null 2>&1 && [ -f "$script_path" ]; then
    bash -n "$script_path" || true
  fi
}

setup_auto_activate() {
  # Add auto-activation of the virtual environment to profile
  local venv_activate="$VENV_DIR/bin/activate"
  if [ -f "$venv_activate" ]; then
    if [[ ${IS_ROOT:-0} -eq 1 ]]; then
      # Write a profile.d script using the resolved VENV_DIR path
      cat > /etc/profile.d/felafax_auto_venv.sh <<EOF
# Auto-activate Felafax virtualenv if present
if [ -z "\${VIRTUAL_ENV:-}" ] && [ -f "$venv_activate" ]; then
  . "$venv_activate"
fi
EOF
      chmod 0644 /etc/profile.d/felafax_auto_venv.sh || true
    else
      # Append to user's .bashrc if not already present
      if ! grep -q 'felafax auto-venv' "$HOME/.bashrc" 2>/dev/null; then
        cat >>"$HOME/.bashrc" <<EOF
# felafax auto-venv
if [ -z "\${VIRTUAL_ENV:-}" ] && [ -f "$venv_activate" ]; then
  . "$venv_activate"
fi
EOF
      fi
    fi
  fi
}

#========================
# Summary and tips
#========================
print_summary() {
  cat <<EOF
${BOLD}Felafax environment setup complete.${RESET}

- Project directory: $APP_DIR
- Virtualenv:        $VENV_DIR
- Accelerator:       $ACCELERATOR (JAX_PLATFORM_NAME=${JAX_PLATFORM_NAME:-cpu})

To use the environment in this shell:
  source "$VENV_DIR/bin/activate"

If your shell does not automatically source /etc/profile.d:
  source /etc/profile.d/felafax_env.sh  # if created

Notes:
- For TPU: ensure this is running on a Google Cloud TPU VM or TPU-backed environment.
- For CUDA/ROCm: ensure compatible drivers and runtimes are available; install matching JAX wheels as needed.

Common directories:
- Data:         $APP_DIR/data
- Checkpoints:  $APP_DIR/checkpoints
- Logs:         $APP_DIR/logs
- Outputs:      $APP_DIR/outputs
- HF caches:    /opt/hf (shared across runs)
EOF
}

#========================
# Main
#========================
main() {
  log "Starting Felafax environment setup..."
  install_system_packages
  ensure_term_profile
  fix_line_endings_and_shebang
  ensure_python
  setup_directories
  create_venv
  setup_auto_activate
  install_python_dependencies
  configure_jax_for_accelerator
  write_env_profile
  print_summary
}

main "$@"