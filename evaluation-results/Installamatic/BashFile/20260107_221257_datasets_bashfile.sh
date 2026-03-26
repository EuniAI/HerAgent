#!/usr/bin/env bash
# Environment setup script for Hugging Face Datasets (Python package)
# Designed to run inside Docker containers with root or non-root users.
# This script installs system dependencies, sets up a Python virtualenv,
# installs Python dependencies, and configures environment variables.
#
# Usage:
#   ./setup.sh [--extras <comma_separated_extras>] [--venv <path>] [--editable] [--non-interactive]
# Examples:
#   ./setup.sh
#   ./setup.sh --editable
#   ./setup.sh --extras tests
#   ./setup.sh --extras "audio,vision" --venv /opt/venv
#   ./setup.sh --non-interactive

set -Eeuo pipefail
IFS=$'\n\t'

# ========== Configurable defaults ==========
DEFAULT_VENV_PATH=".venv"                    # Overridden by --venv or $VENV_PATH
DEFAULT_EXTRAS="${PROJECT_EXTRAS:-}"         # e.g. "tests", "dev", "audio,vision"
DEFAULT_EDITABLE="${EDITABLE_INSTALL:-false}"# Install package in editable mode with -e .
PY_MIN_MAJOR=3
PY_MIN_MINOR=8

# ========== Output formatting ==========
tty_ok=0
if [ -t 1 ]; then tty_ok=1; fi
if [ "${NO_COLOR:-}" = "1" ]; then tty_ok=0; fi

if [ "$tty_ok" -eq 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log()    { printf "%s[%s] %s%s\n" "$GREEN" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$NC"; }
warn()   { printf "%s[WARN] %s%s\n" "$YELLOW" "$*" "$NC" >&2; }
error()  { printf "%s[ERROR] %s%s\n" "$RED" "$*" "$NC" >&2; }
info()   { printf "%s%s%s\n" "$BLUE" "$*" "$NC"; }

# ========== Error handling ==========
LOG_FILE=""
cleanup() { :; }
on_error() {
  local exit_code=$?
  error "Setup failed at line ${BASH_LINENO[0]} (exit code: $exit_code)"
  if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    error "Last 100 lines of log:"
    tail -n 100 "$LOG_FILE" || true
  fi
  exit "$exit_code"
}
trap on_error ERR
trap cleanup EXIT

# ========== Parse arguments ==========
EXTRAS="$DEFAULT_EXTRAS"
VENV_PATH="${VENV_PATH:-$DEFAULT_VENV_PATH}"
EDITABLE="$DEFAULT_EDITABLE"
NON_INTERACTIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --extras)
      EXTRAS="${2:-}"
      shift 2
      ;;
    --venv)
      VENV_PATH="${2:-$DEFAULT_VENV_PATH}"
      shift 2
      ;;
    --editable)
      EDITABLE=true
      shift
      ;;
    --non-interactive|-y)
      NON_INTERACTIVE=1
      shift
      ;;
    --help|-h)
      cat <<EOF
Environment setup for Hugging Face Datasets (inside Docker)

Options:
  --extras <list>    Comma-separated extras to install from setup.py (e.g., "tests", "audio,vision").
                     Note: "dev" is heavy (installs TF/Torch). Default: none.
  --venv <path>      Virtual environment path. Default: .venv (relative to project root)
  --editable         Install in editable mode (-e .). Default: disabled
  --non-interactive  Do not prompt (assume yes)
  -h, --help         Show this help

Environment variables:
  VENV_PATH, PROJECT_EXTRAS, EDITABLE_INSTALL, NO_COLOR, PIP_INDEX_URL, PIP_EXTRA_INDEX_URL, HF_HOME, HF_DATASETS_CACHE
EOF
      exit 0
      ;;
    *)
      warn "Unknown argument: $1"
      shift
      ;;
  esac
done

# ========== Determine project root ==========
# Use the directory where this script resides as project root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# Verify expected source layout exists (not strictly required but helpful)
if [ ! -d "$PROJECT_ROOT/src" ] || [ ! -d "$PROJECT_ROOT/src/datasets" ]; then
  warn "Expected source directory 'src/datasets' not found at $PROJECT_ROOT. Continuing anyway."
fi

# Logging setup
mkdir -p "$PROJECT_ROOT/.logs"
LOG_FILE="$PROJECT_ROOT/.logs/setup-$(date +'%Y%m%d-%H%M%S').log"
touch "$LOG_FILE"

umask 022

# ========== Utility functions ==========
pm_has() { command -v "$1" >/dev/null 2>&1; }

require_root_for_system_pkgs() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Attempting to install system packages without root privileges may fail."
  fi
}

apt_install() {
  require_root_for_system_pkgs
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -o Acquire::Retries=3 >>"$LOG_FILE" 2>&1
  # Avoid recommended/suggested to keep minimal
  apt-get install -y --no-install-recommends "$@" >>"$LOG_FILE" 2>&1
  apt-get clean >>"$LOG_FILE" 2>&1 || true
  rm -rf /var/lib/apt/lists/* || true
}

apk_install() {
  require_root_for_system_pkgs
  apk update >>"$LOG_FILE" 2>&1 || true
  apk add --no-cache "$@" >>"$LOG_FILE" 2>&1
}

dnf_install() {
  require_root_for_system_pkgs
  dnf -y install "$@" >>"$LOG_FILE" 2>&1
  dnf clean all >>"$LOG_FILE" 2>&1 || true
}

yum_install() {
  require_root_for_system_pkgs
  yum -y install "$@" >>"$LOG_FILE" 2>&1
  yum clean all >>"$LOG_FILE" 2>&1 || true
}

install_system_deps() {
  log "Installing system dependencies (build tools, Python, and libs)..."
  if pm_has apt-get; then
    apt_install ca-certificates curl git bash \
      python3 python3-venv python3-dev python3-pip \
      build-essential gcc g++ make \
      libsndfile1 libsndfile1-dev ffmpeg \
      libjpeg-dev zlib1g-dev
  elif pm_has apk; then
    apk_install ca-certificates curl git bash \
      python3 py3-pip python3-dev \
      build-base musl-dev \
      libsndfile-dev libsndfile ffmpeg \
      jpeg-dev zlib-dev
    # ensurepip on Alpine can be absent in some images
    python3 -m ensurepip --upgrade >>"$LOG_FILE" 2>&1 || true
  elif pm_has dnf; then
    dnf_install ca-certificates curl git bash \
      python3 python3-devel python3-pip \
      gcc gcc-c++ make \
      libsndfile libsndfile-devel ffmpeg \
      libjpeg-turbo-devel zlib-devel
  elif pm_has yum; then
    yum_install ca-certificates curl git bash \
      python3 python3-devel python3-pip \
      gcc gcc-c++ make \
      libsndfile libsndfile-devel ffmpeg \
      libjpeg-turbo-devel zlib-devel
  else
    warn "No supported package manager found. Assuming Python and build tools are present."
  fi
  log "System dependencies installation completed."
}

check_python_version() {
  if ! command -v python3 >/dev/null 2>&1; then
    error "python3 is not installed and no supported package manager could install it."
    exit 1
  fi
  local v
  v="$(python3 - <<'PY'
import sys
print(".".join(map(str, sys.version_info[:3])))
PY
)"
  log "Detected Python version: $v"
  local major minor
  major="$(python3 - <<'PY'
import sys
print(sys.version_info[0])
PY
)"
  minor="$(python3 - <<'PY'
import sys
print(sys.version_info[1])
PY
)"
  if [ "$major" -lt "$PY_MIN_MAJOR" ] || { [ "$major" -eq "$PY_MIN_MAJOR" ] && [ "$minor" -lt "$PY_MIN_MINOR" ]; }; then
    error "Python >= ${PY_MIN_MAJOR}.${PY_MIN_MINOR} is required."
    exit 1
  fi
}

create_venv() {
  local venv_path="$1"
  if [ -d "$venv_path" ] && [ -f "$venv_path/bin/activate" ]; then
    log "Reusing existing virtual environment at $venv_path"
  else
    log "Creating virtual environment at $venv_path"
    python3 -m venv "$venv_path" >>"$LOG_FILE" 2>&1 || {
      warn "Failed to create venv with ensurepip, trying to bootstrap pip..."
      python3 -m ensurepip --upgrade >>"$LOG_FILE" 2>&1 || true
      python3 -m venv "$venv_path" >>"$LOG_FILE" 2>&1
    }
  fi
}

activate_venv() {
  # shellcheck disable=SC1090
  . "$1/bin/activate"
  # Safer pip defaults in containers
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=0
  export PIP_RETRY=5
  export PIP_DEFAULT_TIMEOUT=120
  python -m pip install --upgrade pip setuptools wheel build >>"$LOG_FILE" 2>&1
  log "Virtual environment activated: $(python -V 2>/dev/null)"
}

normalize_extras() {
  # Convert comma-separated to bracketed extras string for pip (e.g., audio,vision -> [audio,vision])
  local e="$1"
  if [ -z "$e" ]; then
    echo ""
    return
  fi
  e="$(echo "$e" | tr -s ' ' | tr -d ' ' )"
  echo "[$e]"
}

install_python_deps() {
  local extras_str; extras_str="$(normalize_extras "$EXTRAS")"
  local editable_flag=""
  if [ "$EDITABLE" = "true" ]; then
    editable_flag="-e"
  fi

  # Verify that setup.py exists (fallback to pyproject if present and configured)
  if [ ! -f "$PROJECT_ROOT/setup.py" ] && [ ! -f "$PROJECT_ROOT/pyproject.toml" ]; then
    error "No setup.py or pyproject.toml found. Cannot install the package."
    exit 1
  fi

  # Warn about heavy extras
  case ",${EXTRAS}," in
    *,dev,*)
      warn "Installing 'dev' extras will install heavy dependencies (TensorFlow, Torch, etc.) and may take a long time."
      ;;
    *,tests,*)
      warn "Installing 'tests' extras pulls in many optional dependencies."
      ;;
  esac

  log "Installing Python package and dependencies (extras: ${EXTRAS:-none})..."
  # Allow custom index urls through environment variables
  if [ -f "$PROJECT_ROOT/setup.py" ]; then
    # Installing the local package
    if [ -n "$extras_str" ]; then
      python -m pip install $editable_flag ".[${EXTRAS}]" >>"$LOG_FILE" 2>&1
    else
      python -m pip install $editable_flag . >>"$LOG_FILE" 2>&1
    fi
  else
    # Generic pyproject install
    if [ -n "$extras_str" ]; then
      python -m pip install ".[${EXTRAS}]" >>"$LOG_FILE" 2>&1
    else
      python -m pip install . >>"$LOG_FILE" 2>&1
    fi
  fi
  log "Python dependencies installed successfully."
}

setup_runtime_env() {
  # Create cache dirs and environment var files
  local env_dir cache_dir hf_home hf_cache
  env_dir="$PROJECT_ROOT/.env.d"
  mkdir -p "$env_dir"

  # Default cache locations inside project to keep container writable areas localized
  hf_home="${HF_HOME:-$PROJECT_ROOT/.hf}"
  hf_cache="${HF_DATASETS_CACHE:-$PROJECT_ROOT/.cache/huggingface/datasets}"

  mkdir -p "$hf_home" "$hf_cache" "$PROJECT_ROOT/.cache/pip" "$PROJECT_ROOT/.config"
  chmod -R u+rwX,go+rX "$PROJECT_ROOT/.cache" "$PROJECT_ROOT/.config" "$hf_home" "$hf_cache" || true

  # Write environment file for this project
  cat > "$env_dir/project-env.sh" <<EOF
# Auto-generated environment variables for Hugging Face Datasets
export PYTHONUNBUFFERED=1
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Venv
export VIRTUAL_ENV="$VENV_PATH"
export PATH="\$VIRTUAL_ENV/bin:\$PATH"

# Pip config
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_RETRY=5
export PIP_DEFAULT_TIMEOUT=120

# Hugging Face caches
export HF_HOME="${hf_home}"
export HF_DATASETS_CACHE="${hf_cache}"
EOF

  # Also create a dotenv file for process managers, if desired
  cat > "$PROJECT_ROOT/.env" <<EOF
PYTHONUNBUFFERED=1
LANG=C.UTF-8
LC_ALL=C.UTF-8
VIRTUAL_ENV=$VENV_PATH
PATH=$VENV_PATH/bin:\$PATH
HF_HOME=$hf_home
HF_DATASETS_CACHE=$hf_cache
EOF

  # Attempt to register environment in profile.d if running as root
  if [ "$(id -u)" -eq 0 ] && [ -d /etc/profile.d ]; then
    cat > /etc/profile.d/hf_datasets_env.sh <<EOF
# Added by setup.sh for Hugging Face Datasets project
[ -f "$env_dir/project-env.sh" ] && . "$env_dir/project-env.sh"
EOF
    chmod 0644 /etc/profile.d/hf_datasets_env.sh || true
  fi

  log "Runtime environment configured."
}

set_permissions() {
  # Set perms to current user/group for project workspace
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"
  log "Ensuring project directories are owned by UID:GID ${uid}:${gid}"
  for d in "$VENV_PATH" "$PROJECT_ROOT/.cache" "$PROJECT_ROOT/.config" "$PROJECT_ROOT/.logs" "$PROJECT_ROOT/.env.d" "$PROJECT_ROOT/.hf"; do
    [ -d "$d" ] && chown -R "$uid":"$gid" "$d" 2>/dev/null || true
  done
}

post_install_check() {
  log "Verifying installation..."
  set +e
  if ! "$VENV_PATH/bin/python" - <<'PY' >>"$LOG_FILE" 2>&1
import sys
print(sys.version)
import datasets
print("datasets version:", datasets.__version__)
PY
  then
    set -e
    error "Import check failed; see $LOG_FILE for details."
    exit 1
  fi
  set -e
  log "Import check succeeded."
}

print_summary() {
  info "------------------------------------------------------------"
  info "Setup completed successfully."
  info "Project root: $PROJECT_ROOT"
  info "Virtualenv:   $VENV_PATH"
  info "Extras:       ${EXTRAS:-none}"
  info "Log file:     $LOG_FILE"
  info ""
  info "To use the environment in this shell:"
  info "  source \"$PROJECT_ROOT/.env.d/project-env.sh\""
  info "Or activate the venv directly:"
  info "  source \"$VENV_PATH/bin/activate\""
  info ""
  info "Example commands:"
  info "  python -c 'import datasets; print(datasets.__version__)'"
  info "  datasets-cli --help"
  info "------------------------------------------------------------"
}

# ========== Main ==========
main() {
  log "Starting environment setup for Hugging Face Datasets..."
  log "Project root: $PROJECT_ROOT"

  install_system_deps
  check_python_version

  # Compute absolute path for venv
  if [ "${VENV_PATH:0:1}" != "/" ]; then
    VENV_PATH="$PROJECT_ROOT/$VENV_PATH"
  fi

  create_venv "$VENV_PATH"
  activate_venv "$VENV_PATH"
  setup_runtime_env
  install_python_deps
  set_permissions
  post_install_check
  print_summary
}

main "$@"