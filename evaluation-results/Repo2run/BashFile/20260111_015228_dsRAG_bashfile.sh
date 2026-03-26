#!/usr/bin/env bash
# dsRAG environment setup script for Docker containers
# This script installs system dependencies, sets up a Python virtual environment,
# installs Python requirements, and configures environment variables and directories.
# It is idempotent and safe to re-run.

set -Eeuo pipefail

# ---------------------------
# Configuration and constants
# ---------------------------
PROJECT_NAME="dsrag"
DEFAULT_APP_PORT="8000"

# Resolve project root to the directory containing this script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"

# Virtual environment directory (prefer a stable path in Docker)
VENV_DIR="${VENV_DIR:-/opt/${PROJECT_NAME}/venv}"

# App directories
DATA_DIR="${DATA_DIR:-$PROJECT_ROOT/data}"
STORAGE_DIR="${STORAGE_DIR:-$PROJECT_ROOT/storage}"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"

# Environment file location
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"

# Colors (avoid if not TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

# ---------------------------
# Logging and error handling
# ---------------------------
log() {
  echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
  echo "${YELLOW}[WARN] $*${NC}" >&2
}
error() {
  echo "${RED}[ERROR] $*${NC}" >&2
}
trap 'error "Setup failed at line $LINENO"; exit 1' ERR

# ---------------------------
# Helper functions
# ---------------------------
require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    error "This script must run as root inside the Docker container (no sudo available)."
    exit 1
  fi
}

detect_os() {
  # Returns one of: debian, ubuntu, alpine, rhel, centos, fedora, unknown
  local os=""
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "${ID,,}" in
      debian) os="debian" ;;
      ubuntu) os="ubuntu" ;;
      alpine) os="alpine" ;;
      rhel) os="rhel" ;;
      centos) os="centos" ;;
      fedora) os="fedora" ;;
      *) os="unknown" ;;
    esac
  else
    os="unknown"
  fi
  echo "$os"
}

# Non-interactive package manager settings (for Debian/Ubuntu)
prepare_pkg_env() {
  export DEBIAN_FRONTEND=noninteractive
  export TZ=${TZ:-Etc/UTC}
}

install_system_deps_debian() {
  prepare_pkg_env
  log "Updating apt package lists..."
  apt-get update -y

  # Core build tools and libraries for cryptography, cffi, etc.
  local pkgs=(
    ca-certificates
    curl
    git
    pkg-config
    build-essential
    gcc
    g++
    make
    cmake
    python3
    python3-venv
    python3-pip
    python3-dev
    libffi-dev
    libssl-dev
    libstdc++6
    libgomp1
    poppler-utils
  )
  log "Installing system dependencies via apt-get..."
  apt-get install -y --no-install-recommends "${pkgs[@]}"

  # Clean apt cache to reduce image size
  rm -rf /var/lib/apt/lists/*
}

install_system_deps_alpine() {
  log "Updating apk package lists..."
  apk update

  # For Alpine (musl), some Python binary wheels may be unavailable.
  # We install build tools to allow compilation where needed.
  local pkgs=(
    bash
    ca-certificates
    curl
    git
    build-base
    cmake
    python3
    py3-pip
    python3-dev
    libffi-dev
    openssl-dev
    # gcompat can help with some glibc compatibility (not a full replacement)
    gcompat
  )
  log "Installing system dependencies via apk..."
  apk add --no-cache "${pkgs[@]}"

  # Ensure python3 -m venv works (Alpine >=3.11 includes it)
  if ! python3 -c "import venv" >/dev/null 2>&1; then
    warn "python venv module not found; installing py3-virtualenv"
    apk add --no-cache py3-virtualenv || true
  fi
}

install_system_deps_rhel() {
  # RHEL/CentOS/Fedora family
  local pm=""
  if command -v dnf >/dev/null 2>&1; then
    pm="dnf"
  elif command -v yum >/dev/null 2>&1; then
    pm="yum"
  else
    error "No dnf/yum found on RHEL-like system."
    exit 1
  fi

  log "Installing system dependencies via $pm..."
  $pm -y install \
    ca-certificates curl git \
    gcc gcc-c++ make cmake \
    python3 python3-pip python3-devel \
    libffi-devel openssl-devel || {
      warn "Primary package installation failed, attempting to enable PowerTools or EPEL if available."
      # Best effort fallback; may not be applicable in all images
      $pm -y install epel-release || true
      $pm -y install \
        ca-certificates curl git \
        gcc gcc-c++ make cmake \
        python3 python3-pip python3-devel \
        libffi-devel openssl-devel || {
          error "Failed to install required system dependencies via $pm."
          exit 1
        }
    }
}

install_system_deps() {
  local os
  os="$(detect_os)"
  log "Detected OS: $os"

  case "$os" in
    debian|ubuntu)
      install_system_deps_debian
      ;;
    alpine)
      install_system_deps_alpine
      warn "Alpine Linux detected. Some Python packages (onnxruntime, tokenizers, faiss) may not have musl-compatible wheels. Consider using a Debian/Ubuntu-based image for best compatibility."
      ;;
    rhel|centos|fedora)
      install_system_deps_rhel
      ;;
    *)
      warn "Unknown OS. Attempting Debian-style apt installation..."
      if command -v apt-get >/dev/null 2>&1; then
        install_system_deps_debian
      else
        error "Unsupported base image. Please use Debian/Ubuntu, Alpine, or RHEL-like distributions."
        exit 1
      fi
      ;;
  esac
}

ensure_brew_shim() {
  if ! command -v brew >/dev/null 2>&1; then
    mkdir -p /usr/local/bin || true
    echo -e '#!/usr/bin/env bash\necho "brew not available; skipping."\nexit 0' > /usr/local/bin/brew
    chmod +x /usr/local/bin/brew
  fi
}

configure_pip_conf() {
  local pip_dir="${HOME:-/root}/.config/pip"
  mkdir -p "$pip_dir" || true
  printf "[global]\nprefer-binary = true\ndisable-pip-version-check = true\n" > "$pip_dir/pip.conf"
}

ensure_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    error "python3 is not installed and could not be installed. Aborting."
    exit 1
  fi

  local pyver
  pyver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  log "Python version detected: $pyver"

  # Ensure Python >= 3.9
  python3 - <<'PYCODE'
import sys
major, minor = sys.version_info[:2]
if major < 3 or (major == 3 and minor < 9):
    sys.exit(1)
PYCODE
  if [ $? -ne 0 ]; then
    error "Python >= 3.9 is required. Detected version: $pyver"
    exit 1
  fi
}

create_dirs() {
  log "Creating directories..."
  mkdir -p "$DATA_DIR" "$STORAGE_DIR" "$LOG_DIR"
  chmod 755 "$DATA_DIR" "$STORAGE_DIR" "$LOG_DIR"
}

create_venv() {
  if [ -d "$VENV_DIR" ] && [ -x "$VENV_DIR/bin/python" ]; then
    log "Virtual environment already exists at $VENV_DIR"
  else
    log "Creating virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
    # In some cases, venv may have outdated pip; upgrade it safely
    "$VENV_DIR/bin/python" -m pip install --upgrade --no-cache-dir pip setuptools wheel
    log "Virtual environment created."
  fi
}

neutralize_dsparse_requirements() {
  local req_path="$PROJECT_ROOT/dsrag/dsparse/requirements.txt"
  if [ -f "$req_path" ]; then
    cp "$req_path" "$req_path.bak" || true
    printf '' > "$req_path"
  fi
}

install_python_deps() {
  local req_file="$PROJECT_ROOT/requirements.txt"
  if [ ! -f "$req_file" ]; then
    warn "requirements.txt not found at $req_file. Skipping Python dependency installation."
    return
  fi

  local req_hash
  req_hash="$(sha256sum "$req_file" | awk '{print $1}')"
  local hash_file="$VENV_DIR/requirements.sha256"

  # Build pip install command
  local pip_cmd=("$VENV_DIR/bin/python" "-m" "pip" "install" "--no-cache-dir")
  # Optional: allow custom indexes from env
  if [ -n "${PIP_INDEX_URL:-}" ]; then
    pip_cmd+=("--index-url" "$PIP_INDEX_URL")
  fi
  if [ -n "${PIP_EXTRA_INDEX_URL:-}" ]; then
    pip_cmd+=("--extra-index-url" "$PIP_EXTRA_INDEX_URL")
  fi

  # Ensure base tools upgraded
  log "Upgrading pip/setuptools/wheel in venv..."
  "$VENV_DIR/bin/python" -m pip install --upgrade --no-cache-dir pip setuptools wheel

  # Install requirements only if hash changed or first run
  if [ -f "$hash_file" ] && grep -q "$req_hash" "$hash_file"; then
    log "Requirements unchanged (hash match). Skipping reinstall."
  else
    log "Installing Python dependencies from requirements.txt..."
    # Some packages may be heavy; ensure a reasonable timeout/retries if mirror issues
    "${pip_cmd[@]}" -r "$req_file"
    echo "$req_hash" > "$hash_file"
    log "Python dependencies installed."
  fi

  # Force a compatible scientific stack to avoid NumPy 2.x incompatibilities
  log "Pinning NumPy to 1.26.4 and installing SciPy/Scikit-learn, pdf2image, langchain-text-splitters in venv..."
  "$VENV_DIR/bin/python" -m pip install --upgrade --no-cache-dir --force-reinstall numpy==1.26.4
  "$VENV_DIR/bin/python" -m pip uninstall -y vertexai || true
  "$VENV_DIR/bin/python" -m pip uninstall -y openai tokenizers aiohttp google-api-core google-auth-httplib2 || true
  "$VENV_DIR/bin/python" -m pip install --upgrade --no-cache-dir "scipy>=1.12,<1.14" "scikit-learn>=1.2,<1.4" pdf2image langchain-text-splitters google-generativeai google-cloud-aiplatform boto3 botocore chromadb "pymilvus>=2.3,<3" weaviate-client pytest

  # Quick sanity check
  if ! "$VENV_DIR/bin/python" -c "import dsrag" >/dev/null 2>&1; then
    warn "dsrag import test failed. The package may be a library in this repo or needs editable install."
    # If this repository is the project source, install it in editable mode
    if [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
      log "Installing project in editable mode (pip install -e .)..."
      "${pip_cmd[@]}" -e "$PROJECT_ROOT"
    fi
  fi
}

# Ensure numpy is available in the system interpreter used by tests
ensure_global_numpy() {
  # Ensure Poppler utilities for pdf2image across common distros
  if command -v apt-get >/dev/null 2>&1; then
    log "Ensuring 'poppler-utils' is installed for pdf2image via apt-get..."
    prepare_pkg_env
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y poppler-utils
  elif command -v dnf >/dev/null 2>&1; then
    log "Ensuring 'poppler-utils' and 'poppler' are installed via dnf..."
    dnf install -y poppler-utils poppler
  elif command -v yum >/dev/null 2>&1; then
    log "Ensuring 'poppler-utils' and 'poppler' are installed via yum..."
    yum install -y poppler-utils poppler
  elif command -v apk >/dev/null 2>&1; then
    log "Ensuring 'poppler-utils' and 'poppler' are installed via apk..."
    apk add --no-cache poppler-utils poppler
  elif command -v brew >/dev/null 2>&1; then
    log "Ensuring 'poppler' is installed via brew..."
    brew install poppler || true
  else
    warn "No supported package manager found; skipping poppler-utils install"
  fi

  # Upgrade pip tooling and install required Python packages with compatible versions
  if command -v python >/dev/null 2>&1; then
    log "Upgrading pip/setuptools/wheel for active python..."
    python -m pip install --upgrade pip setuptools wheel
    log "Reinstalling NumPy 1.26.4 to ensure compatibility..."
    python -m pip install --upgrade --force-reinstall numpy==1.26.4
    log "Installing/Upgrading SciPy/Scikit-learn and other deps..."
    python -m pip uninstall -y vertexai || true
    python -m pip uninstall -y openai tokenizers aiohttp google-api-core google-auth-httplib2 || true
    python -m pip install --upgrade "scipy>=1.12,<1.14" "scikit-learn>=1.2,<1.4" pdf2image langchain-text-splitters pytest google-generativeai google-cloud-aiplatform boto3 botocore chromadb "pymilvus>=2.3,<3" weaviate-client
  elif command -v python3 >/dev/null 2>&1; then
    log "Upgrading pip/setuptools/wheel for python3..."
    python3 -m pip install --upgrade pip setuptools wheel
    log "Reinstalling NumPy 1.26.4 to ensure compatibility..."
    python3 -m pip install --upgrade --force-reinstall numpy==1.26.4
    log "Installing/Upgrading SciPy/Scikit-learn and other deps..."
    python3 -m pip uninstall -y vertexai || true
    python3 -m pip uninstall -y openai tokenizers aiohttp google-api-core google-auth-httplib2 || true
    python3 -m pip install --upgrade "scipy>=1.12,<1.14" "scikit-learn>=1.2,<1.4" pdf2image langchain-text-splitters pytest google-generativeai google-cloud-aiplatform boto3 botocore chromadb "pymilvus>=2.3,<3" weaviate-client
  else
    warn "Neither 'python' nor 'python3' found for global Python package installation. Skipping."
  fi
}

configure_env_file() {
  # Create .env with placeholders if not present
  if [ ! -f "$ENV_FILE" ]; then
    log "Creating environment file at $ENV_FILE"
    cat > "$ENV_FILE" <<EOF
# Environment configuration for dsRAG
# Set your API keys here (do not commit this file to source control)
OPENAI_API_KEY=${OPENAI_API_KEY:-}
CO_API_KEY=${CO_API_KEY:-}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
VOYAGE_API_KEY=${VOYAGE_API_KEY:-}

# Storage directories
DSRAG_STORAGE_DIR=${STORAGE_DIR}
DSRAG_DATA_DIR=${DATA_DIR}

# General
PYTHONUNBUFFERED=1
LC_ALL=C.UTF-8
LANG=C.UTF-8
APP_PORT=${DEFAULT_APP_PORT}
EOF
    chmod 640 "$ENV_FILE" || true
  else
    log "Environment file already exists at $ENV_FILE"
  fi
}

configure_sitecustomize() {
  # Write sitecustomize.py into the active interpreter's site-packages (purelib) to inject safe default AWS env vars
  log "Ensuring sitecustomize.py sets default AWS env vars in interpreter site-packages (purelib)"
  python3 - <<'PY'
import os, sysconfig
p = sysconfig.get_paths().get('purelib')
os.makedirs(p, exist_ok=True)
f = os.path.join(p, "sitecustomize.py")
open(f, "w").write(
    """
import os
# Provide safe defaults to prevent KeyError during tests
os.environ.setdefault("AWS_S3_REGION", "us-east-1")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")
os.environ.setdefault("AWS_SESSION_TOKEN", "test")
os.environ.setdefault("AWS_S3_KB_BUCKET", "test-bucket")
# Dummy API keys to avoid import-time KeyError in providers
os.environ.setdefault("OPENAI_API_KEY", "test")
os.environ.setdefault("GOOGLE_API_KEY", "test")
os.environ.setdefault("AWS_S3_ENDPOINT_URL", os.environ.get("S3_ENDPOINT_URL", ""))
"""
)
print("Wrote", f)
PY

  # Optional verification: print the variables in a fresh Python process
  python3 - <<'PY'
import os
print({k: os.environ.get(k) for k in [
    'AWS_S3_REGION','AWS_DEFAULT_REGION','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_S3_ENDPOINT_URL'
]})
PY
}

configure_user_sitecustomize() {
  python - <<'PY'
import site, pathlib
p = pathlib.Path(site.getusersitepackages()) / 'sitecustomize.py'
p.parent.mkdir(parents=True, exist_ok=True)
content = """import os
os.environ.setdefault('AWS_S3_REGION','us-east-1')
os.environ.setdefault('AWS_ACCESS_KEY_ID','test')
os.environ.setdefault('AWS_SECRET_ACCESS_KEY','test')
"""
p.write_text(content)
print(f'Wrote {p}')
PY
}

export_runtime_env() {
  # Export environment variables for current session
  export DSRAG_STORAGE_DIR="${STORAGE_DIR}"
  export DSRAG_DATA_DIR="${DATA_DIR}"
  export PYTHONUNBUFFERED=1
  export LC_ALL=C.UTF-8
  export LANG=C.UTF-8
  export APP_PORT="${DEFAULT_APP_PORT}"

  # Optionally source .env (if user wants)
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi

  # Persist a profile script for interactive shells
  local profile_script="/etc/profile.d/${PROJECT_NAME}.sh"
  log "Writing runtime environment profile to $profile_script"
  cat > "$profile_script" <<EOF
# Autogenerated by dsRAG setup script
export DSRAG_STORAGE_DIR="${STORAGE_DIR}"
export DSRAG_DATA_DIR="${DATA_DIR}"
export PYTHONUNBUFFERED=1
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export APP_PORT="${DEFAULT_APP_PORT}"
# Add venv bin to PATH if not already present
export PATH="${VENV_DIR}/bin:\$PATH"
EOF
  chmod 644 "$profile_script" || true
}

configure_permissions() {
  # In Docker, we typically run as root; ensure directories are accessible
  log "Setting directory permissions..."
  chown -R root:root "$DATA_DIR" "$STORAGE_DIR" "$LOG_DIR" || true
  chmod -R 755 "$DATA_DIR" "$STORAGE_DIR" "$LOG_DIR" || true

  # venv bin should be executable
  chmod -R 755 "$VENV_DIR/bin" || true
}

print_usage_instructions() {
  echo
  echo "${BLUE}Setup complete.${NC}"
  echo "Virtual environment: $VENV_DIR"
  echo "Project root:        $PROJECT_ROOT"
  echo "Data directory:      $DATA_DIR"
  echo "Storage directory:   $STORAGE_DIR"
  echo "Logs directory:      $LOG_DIR"
  echo "Environment file:    $ENV_FILE"
  echo
  echo "To use the environment in this container:"
  echo "  export PATH=\"$VENV_DIR/bin:\$PATH\""
  echo "  source \"$ENV_FILE\"  # if you want to load API keys and settings"
  echo "  python -c \"import dsrag; print('dsRAG import OK')\""
  echo
  echo "If you plan to run an API with uvicorn (FastAPI-based components are installed):"
  echo "  uvicorn some_module:app --host 0.0.0.0 --port ${DEFAULT_APP_PORT}"
  echo "Replace 'some_module:app' with your actual ASGI app path if applicable."
}

# ---------------------------
# Main
# ---------------------------
main() {
  require_root
  log "Starting ${PROJECT_NAME} environment setup in Docker..."

  install_system_deps
  ensure_brew_shim
  ensure_python
  configure_pip_conf
  create_dirs
  configure_sitecustomize
  configure_user_sitecustomize
  create_venv
  neutralize_dsparse_requirements
  install_python_deps
  ensure_global_numpy
  configure_env_file
  export_runtime_env
  configure_permissions

  # Final sanity check
  if "$VENV_DIR/bin/python" -c "import dsrag" >/dev/null 2>&1; then
    log "dsRAG import test succeeded."
  else
    warn "dsRAG import test still failing. Ensure the project sources are present or pip install succeeded."
  fi

  print_usage_instructions
}

main "$@"