#!/usr/bin/env bash
# Environment setup script for CAMEL-AI (Python, Poetry/PEP517 project)
# Designed to run inside Docker containers as root (no sudo).
# Installs Python (>=3.10,<3.12), system build tools, optional extras sys deps,
# creates a virtual environment, installs project dependencies, and configures env.

set -Eeuo pipefail

# Globals and defaults
APP_NAME="camel-ai"
APP_DIR="${APP_DIR:-/app}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
CREATE_APP_USER="${CREATE_APP_USER:-false}"
APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
# Extras to install: "", "all", "tools", "huggingface-agent", "encoders", "vector-databases", "graph-storages", "kv-stroages", "object-storages", "retrievers", "model-platforms", "test"
CAMEL_EXTRAS="${CAMEL_EXTRAS:-}"
CAMEL_INSTALL_ALL_EXTRAS="${CAMEL_INSTALL_ALL_EXTRAS:-false}"
CAMEL_INSTALL_TEST_EXTRAS="${CAMEL_INSTALL_TEST_EXTRAS:-false}"
# Use UV for Python/packaging if system Python is incompatible
USE_UV="${USE_UV:-auto}"  # auto|true|false
# Network/pip config
PIP_INDEX_URL="${PIP_INDEX_URL:-}"
PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL:-}"
# Non-interactive installs
export DEBIAN_FRONTEND=noninteractive

# Colors
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() { true; }
trap cleanup EXIT
trap 'err "Failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR

# Detect package manager
PKG_MANAGER=""
if command -v apt-get >/dev/null 2>&1; then
  PKG_MANAGER="apt"
elif command -v apk >/dev/null 2>&1; then
  PKG_MANAGER="apk"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
elif command -v microdnf >/dev/null 2>&1; then
  PKG_MANAGER="microdnf"
else
  err "Unsupported base image: no known package manager found (apt/apk/dnf/yum)."
  exit 1
fi

# Helper: install packages idempotently
install_pkgs() {
  case "$PKG_MANAGER" in
    apt)
      apt-get update -y
      # shellcheck disable=SC2068
      apt-get install -y --no-install-recommends $@
      ;;
    apk)
      apk update
      # shellcheck disable=SC2068
      apk add --no-cache $@
      ;;
    dnf)
      dnf -y install $@
      ;;
    yum)
      yum -y install $@
      ;;
    microdnf)
      microdnf -y install $@
      ;;
  esac
}

# Helper: clean package caches to keep image small
clean_pkg_caches() {
  case "$PKG_MANAGER" in
    apt)
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*
      ;;
    dnf|yum|microdnf)
      rm -rf /var/cache/dnf/* /var/cache/yum/* /tmp/* /var/tmp/* || true
      ;;
  esac
}

# Ensure core tools
install_core_tools() {
  log "Installing core system tools and build dependencies..."
  case "$PKG_MANAGER" in
    apt)
      install_pkgs ca-certificates curl git gnupg
      install_pkgs build-essential gcc g++ make
      install_pkgs pkg-config
      install_pkgs libffi-dev
      install_pkgs libssl-dev
      install_pkgs libsndfile1  || true
      install_pkgs libgl1 libglib2.0-0 || true # For OpenCV wheels
      ;;
    apk)
      install_pkgs ca-certificates curl git bash
      install_pkgs build-base gcc g++ make musl-dev
      install_pkgs pkgconf
      install_pkgs libffi-dev
      install_pkgs openssl-dev
      install_pkgs libsndfile  || true
      install_pkgs mesa-gl glib || true # For OpenCV wheels
      ;;
    dnf|yum|microdnf)
      install_pkgs ca-certificates curl git gnupg2
      install_pkgs gcc gcc-c++ make
      install_pkgs libffi-devel
      install_pkgs openssl-devel
      install_pkgs pkgconfig
      install_pkgs glib2 || true
      install_pkgs mesa-libGL || true
      install_pkgs libsndfile || true
      ;;
  esac
}

# Determine Python suitability
python_ok=false
PY_OK_MIN="3.10.0"
PY_OK_MAX="3.12.0" # exclusive
have_python() {
  command -v python3 >/dev/null 2>&1
}
python_version_ok() {
  local ver
  ver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  # Compare versions lexicographically using Python
  python3 - "$ver" "$PY_OK_MIN" "$PY_OK_MAX" << 'EOF'
import sys
ver, minv, maxv = sys.argv[1:]
from packaging.version import Version
v = Version(ver); mn=Version(minv); mx=Version(maxv)
sys.exit(0 if (v >= mn and v < mx) else 1)
EOF
}

# Install system Python if available
install_system_python() {
  log "Installing system Python and dev headers via $PKG_MANAGER..."
  case "$PKG_MANAGER" in
    apt)
      install_pkgs python3 python3-pip python3-venv python3-dev
      ;;
    apk)
      install_pkgs python3 py3-pip python3-dev
      ;;
    dnf|yum|microdnf)
      install_pkgs python3 python3-pip python3-virtualenv python3-devel || install_pkgs python3 python3-pip python3-devel
      ;;
  esac
}

# Install uv (fast Python/packaging) if needed
ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  log "Installing uv (fast Python/packaging tool)..."
  curl -fsSL https://astral.sh/uv/install.sh | sh -s -- -y
  # The installer places uv in ~/.local/bin
  if [ -x "${HOME:-/root}/.local/bin/uv" ]; then
    ln -sf "${HOME:-/root}/.local/bin/uv" /usr/local/bin/uv
  fi
  if ! command -v uv >/dev/null 2>&1; then
    err "uv installation failed."
    exit 1
  fi
}

# Create application user (optional)
ensure_app_user() {
  if [ "$CREATE_APP_USER" = "true" ]; then
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      log "Creating non-root user: $APP_USER ($APP_UID:$APP_GID)"
      if getent group "$APP_GID" >/dev/null 2>&1; then
        true
      else
        groupadd -g "$APP_GID" "$APP_USER" || groupadd -g "$APP_GID" "$APP_USER" || true
      fi
      useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER"
    else
      log "User $APP_USER already exists."
    fi
  fi
}

# Prepare directories
prepare_dirs() {
  mkdir -p "$APP_DIR"
  mkdir -p "$(dirname "$VENV_DIR")"
  if [ "$CREATE_APP_USER" = "true" ]; then
    chown -R "$APP_UID:$APP_GID" "$APP_DIR" "$(dirname "$VENV_DIR")"
  fi
}

# Install extras-related system packages (optional, heavy)
install_extras_sysdeps() {
  local extras_to_install=()
  if [ "$CAMEL_INSTALL_ALL_EXTRAS" = "true" ]; then
    extras_to_install+=("all")
  fi
  if [ -n "$CAMEL_EXTRAS" ]; then
    extras_to_install+=("$CAMEL_EXTRAS")
  fi

  if [ "${#extras_to_install[@]}" -eq 0 ]; then
    log "No extras specified; installing only minimal system dependencies."
    return 0
  fi

  local want_all=false want_tools=false want_hf=false
  for e in "${extras_to_install[@]}"; do
    case "$e" in
      *all*) want_all=true ;;
    esac
    case "$e" in
      *tools*) want_tools=true ;;
    esac
    case "$e" in
      *huggingface-agent*) want_hf=true ;;
    esac
  done

  if $want_hf || $want_all; then
    log "Installing system dependencies for huggingface-agent extras (ffmpeg, GL libs)..."
    case "$PKG_MANAGER" in
      apt)
        install_pkgs ffmpeg libgl1 libglib2.0-0
        ;;
      apk)
        install_pkgs ffmpeg mesa-gl glib
        ;;
      dnf|yum|microdnf)
        install_pkgs ffmpeg glib2 mesa-libGL
        ;;
    esac
  fi

  if $want_tools || $want_all; then
    log "Installing system dependencies for tools extras (poppler, tesseract, libreoffice, pandoc, libmagic, xml/xslt)..."
    case "$PKG_MANAGER" in
      apt)
        install_pkgs poppler-utils tesseract-ocr libtesseract-dev
        install_pkgs libreoffice-common libreoffice-writer || true
        install_pkgs pandoc
        install_pkgs libmagic1 libmagic-dev
        install_pkgs libxml2 libxml2-dev libxslt1.1 libxslt1-dev
        install_pkgs ghostscript || true
        ;;
      apk)
        # Alpine package names vary by version; best-effort
        install_pkgs poppler-utils tesseract-ocr tesseract-ocr-data-eng || true
        install_pkgs libreoffice-common libreoffice-writer || true
        install_pkgs pandoc || true
        install_pkgs file file-dev || true
        install_pkgs libxml2 libxml2-dev libxslt libxslt-dev || true
        install_pkgs ghostscript || true
        warn "Some 'tools' extras may not be fully supported on Alpine."
        ;;
      dnf|yum|microdnf)
        install_pkgs poppler-utils tesseract tesseract-langpack-eng || true
        install_pkgs libreoffice-writer || true
        install_pkgs pandoc
        install_pkgs file file-devel
        install_pkgs libxml2 libxml2-devel libxslt libxslt-devel
        install_pkgs ghostscript || true
        ;;
    esac
  fi
}

# Configure environment variables and profile scripts
configure_env_files() {
  log "Configuring environment variables and profile scripts..."
  # Persist for interactive shells
  cat >/etc/profile.d/${APP_NAME}_env.sh <<EOF
# Auto-generated by setup script
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export PATH="$VENV_DIR/bin:\$PATH"
export CAMEL_HOME="$APP_DIR"
# API keys (export your keys as needed)
# export OPENAI_API_KEY=""
# export OPENAI_API_BASE_URL=""
# export ANTHROPIC_API_KEY=""
# export GROQ_API_KEY=""
# export GOOGLE_API_KEY=""
EOF
  chmod 0644 /etc/profile.d/${APP_NAME}_env.sh

  # Project .env template for convenience
  if [ ! -f "$APP_DIR/.env" ]; then
    cat >"$APP_DIR/.env" <<'EOF'
# CAMEL-AI environment variables (fill in as needed)
OPENAI_API_KEY=
OPENAI_API_BASE_URL=
ANTHROPIC_API_KEY=
GROQ_API_KEY=
GOOGLE_API_KEY=
EOF
    [ "$CREATE_APP_USER" = "true" ] && chown "$APP_UID:$APP_GID" "$APP_DIR/.env"
  fi
}

# Create Python virtual environment (system python or uv-managed)
create_venv() {
  if [ -d "$VENV_DIR" ]; then
    log "Virtual environment already exists at $VENV_DIR"
    return 0
  fi

  local use_uv_local=false
  if [ "$USE_UV" = "true" ]; then
    use_uv_local=true
  elif [ "$USE_UV" = "false" ]; then
    use_uv_local=false
  else
    # auto: use uv if python not suitable
    if have_python && python_version_ok; then
      use_uv_local=false
    else
      use_uv_local=true
    fi
  fi

  if $use_uv_local; then
    ensure_uv
    log "Creating virtual environment with uv (Python 3.11)..."
    uv python install 3.11
    uv venv --python 3.11 "$VENV_DIR"
  else
    log "Creating virtual environment with system python3..."
    python3 -m venv "$VENV_DIR"
  fi

  # Ensure venv activation
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    err "Virtual environment creation failed at $VENV_DIR"
    exit 1
  fi
}

# Install Python tooling and project
install_python_deps() {
  export PATH="$VENV_DIR/bin:$PATH"
  # Select installer: uv pip if available, else pip
  local PIP_CMD="pip"
  if command -v uv >/dev/null 2>&1; then
    PIP_CMD="uv pip"
  fi

  log "Upgrading pip/setuptools/wheel..."
  $PIP_CMD install --upgrade pip setuptools wheel

  # Apply pip index mirrors if provided
  local pip_opts=()
  [ -n "$PIP_INDEX_URL" ] && pip_opts+=("--index-url" "$PIP_INDEX_URL")
  [ -n "$PIP_EXTRA_INDEX_URL" ] && pip_opts+=("--extra-index-url" "$PIP_EXTRA_INDEX_URL")

  # Verify we are in project directory with pyproject.toml
  if [ ! -f "$APP_DIR/pyproject.toml" ]; then
    err "pyproject.toml not found in $APP_DIR. Mount or copy project sources to $APP_DIR."
    exit 1
  fi

  # Install project in editable mode with optional extras
  pushd "$APP_DIR" >/dev/null
  local extras_spec=""
  if [ "$CAMEL_INSTALL_ALL_EXTRAS" = "true" ]; then
    extras_spec="[all]"
  elif [ -n "$CAMEL_EXTRAS" ]; then
    # Allow comma-separated extras, normalize
    extras_spec="[$(echo "$CAMEL_EXTRAS" | tr -d ' ')]"
  fi
  log "Installing project: -e .${extras_spec}"
  $PIP_CMD install "${pip_opts[@]}" --no-cache-dir -e ".${extras_spec}"

  if [ "$CAMEL_INSTALL_TEST_EXTRAS" = "true" ]; then
    log "Installing test extras: -e .[test]"
    $PIP_CMD install "${pip_opts[@]}" --no-cache-dir -e ".[test]" || true
  fi

  # Optional: install poetry if desired (not required for runtime)
  # $PIP_CMD install poetry || true

  popd >/dev/null
}

# Post-install checks and info
post_install_info() {
  export PATH="$VENV_DIR/bin:$PATH"
  log "Python: $(python --version)"
  log "Pip: $(pip --version)"
  log "Installed $APP_NAME package:"
  python - <<'EOF' || true
import pkgutil, sys
m = pkgutil.find_loader("camel")
print(" - camel module found" if m else " - camel module NOT found", file=sys.stdout)
EOF

  cat <<EOF
Setup complete.

Quick start:
- Activate venv: source $VENV_DIR/bin/activate
- Environment vars file: /etc/profile.d/${APP_NAME}_env.sh (auto-applied for interactive shells)
- Project dir: $APP_DIR
- Example run (requires OPENAI_API_KEY): python examples/ai_society/role_playing.py

Re-run this script safely; operations are idempotent.

Notes:
- Python requirement from pyproject.toml: >=3.10,<3.12
- If base image ships incompatible Python, 'uv' was used to provision Python 3.11 and a venv.
- Configure extras via:
    CAMEL_INSTALL_ALL_EXTRAS=true   # to install all extras
    CAMEL_EXTRAS="tools,huggingface-agent"   # to install specific extras
- Some 'tools' extras require heavy system packages; on Alpine they may be partially available.

EOF
}

main() {
  log "Starting environment setup for $APP_NAME"

  install_core_tools
  clean_pkg_caches

  # Ensure Python exists and is compatible or provision via uv
  if have_python; then
    if python_version_ok; then
      log "Found suitable system Python: $(python3 --version)"
    else
      warn "System Python version not in required range (>=3.10,<3.12). Will use uv-managed Python."
    fi
  else
    install_system_python || true
    if have_python && python_version_ok; then
      log "Installed suitable system Python: $(python3 --version)"
    else
      warn "System Python unavailable or incompatible; falling back to uv-managed Python."
    fi
  fi

  ensure_app_user
  prepare_dirs

  install_extras_sysdeps || true
  clean_pkg_caches

  create_venv
  install_python_deps

  configure_env_files
  clean_pkg_caches

  # Permissions
  if [ "$CREATE_APP_USER" = "true" ]; then
    chown -R "$APP_UID:$APP_GID" "$APP_DIR" "$VENV_DIR"
  fi

  post_install_info
  log "Environment setup completed successfully."
}

main "$@"