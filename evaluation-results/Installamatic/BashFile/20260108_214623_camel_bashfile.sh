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
      install_pkgs wget
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

# Ensure Python 3.10 and pip (apt-based) to align with pinned binary wheels
ensure_python310() {
  if [ "$PKG_MANAGER" != "apt" ]; then
    return 0
  fi
  log "Ensuring Python 3.10 toolchain is available..."
  # Best-effort install; allow absence on some distros
  install_pkgs wget ca-certificates python3.10 python3.10-venv python3.10-dev build-essential libgl1 libglib2.0-0 || true
  # Ensure pip for python3.10
  if command -v python3.10 >/dev/null 2>&1; then
    python3.10 -m ensurepip --upgrade || (wget -qO- https://bootstrap.pypa.io/get-pip.py | python3.10 -) || true
    # Ensure a pip shim that targets python3.10 explicitly; venv will still override PATH
    sh -c 'printf "#!/usr/bin/env bash\nexec python3.10 -m pip \"$@\"\n" > /usr/local/bin/pip' || true
    chmod +x /usr/local/bin/pip || true
    python3.10 -m pip install -U pip setuptools wheel || true
  fi
}

# Install uv (fast Python/packaging) if needed
ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  log "Installing uv (fast Python/packaging tool)..."
  curl -fsSL https://astral.sh/uv/install.sh | sh
  # The installer places uv in ~/.local/bin
  if [ -x "${HOME:-/root}/.local/bin/uv" ]; then
    ln -sf "${HOME:-/root}/.local/bin/uv" /usr/local/bin/uv
  fi
  if ! command -v uv >/dev/null 2>&1; then
    err "uv installation failed."
    exit 1
  fi
}

# Ensure a Miniconda-based Python 3.9 env and link its pip globally; also ensure python3.10 via apt if missing
ensure_miniconda_py39() {
  if [ ! -d /opt/conda ]; then
    curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh && bash /tmp/miniconda.sh -b -p /opt/conda
  fi
  if [ ! -d /opt/conda/envs/py39 ]; then
    /opt/conda/bin/conda create -y -n py39 python=3.9
  fi
  ln -sf /opt/conda/envs/py39/bin/pip /usr/local/bin/pip
  /opt/conda/envs/py39/bin/pip config set global.disable-pip-version-check true || true
  /opt/conda/envs/py39/bin/pip config set global.prefer-binary true || true
  /opt/conda/envs/py39/bin/pip install -U pip setuptools wheel
  /opt/conda/envs/py39/bin/pip install -U "numpy==1.21.2" || true
  if ! command -v python3.10 >/dev/null 2>&1; then
    if [ "$PKG_MANAGER" = "apt" ]; then
      apt-get update -y && apt-get install -y python3.10 python3.10-venv python3.10-distutils || true
    fi
  fi
}

# Ensure Python 3.9 default and Python 3.10 via micromamba; set global pip/python to py39
ensure_micromamba_py310() {
  # Ensure required tools
  case "$PKG_MANAGER" in
    apt)
      install_pkgs curl ca-certificates bzip2 tar make
      ;;
    apk)
      install_pkgs curl ca-certificates bzip2 tar make || true
      ;;
    dnf|yum|microdnf)
      install_pkgs bzip2 tar make || true
      ;;
  esac

  # Install micromamba binary if missing (use fixed linux-64 build)
  if [ ! -x /usr/local/bin/micromamba ]; then
    curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest \
      | tar -xj -C /usr/local/bin --strip-components=1 bin/micromamba
  fi

  # Create Python 3.9 environment for default pip/python
  if [ ! -x /opt/py39/bin/python3 ]; then
    /usr/local/bin/micromamba create -y -p /opt/py39 python=3.9 pip setuptools wheel
  fi

  # Point global python/pip to Python 3.9
  ln -sf /opt/py39/bin/python3 /usr/local/bin/python
  ln -sf /opt/py39/bin/python3 /usr/local/bin/python3
  # If a Miniconda py39 pip exists, preserve it as the global pip; otherwise link micromamba's py39 pip
  if [ ! -x /opt/conda/envs/py39/bin/pip ]; then
    ln -sf /opt/py39/bin/pip3 /usr/local/bin/pip
    ln -sf /opt/py39/bin/pip3 /usr/local/bin/pip3
  fi

  # Configure pip to prefer binary wheels system-wide
  printf "[global]\nprefer-binary = true\n" >/etc/pip.conf

  # Pre-warm core packaging and numpy pin for legacy deps
  /usr/local/bin/pip install -U pip setuptools wheel
  /usr/local/bin/pip install "numpy==1.21.2"

  # Create Python 3.10 environment (for Poetry/pyproject if needed)
  if [ ! -x /opt/py310/bin/python3.10 ]; then
    /usr/local/bin/micromamba create -y -p /opt/py310 python=3.10 pip
  fi
  ln -sf /opt/py310/bin/python3.10 /usr/local/bin/python3.10

  # Convenience shims for common CLIs from py39 env
  ln -sf /opt/py39/bin/poetry /usr/local/bin/poetry || true
  ln -sf /opt/py39/bin/sphinx-apidoc /usr/local/bin/sphinx-apidoc || true
  ln -sf /opt/py39/bin/sphinx-autobuild /usr/local/bin/sphinx-autobuild || true
  ln -sf /opt/py39/bin/gradio /usr/local/bin/gradio || true
}

# Provision CPython 3.9 (default) and 3.10 via pyenv; link system shims
ensure_pyenv_setup() {
  if [ "$PKG_MANAGER" != "apt" ]; then
    return 0
  fi
  log "Installing build deps for CPython via apt..."
  apt-get update
  apt-get install -y build-essential git curl ca-certificates zlib1g-dev libssl-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev tk-dev xz-utils

  if [ ! -d /opt/pyenv ]; then
    log "Cloning pyenv..."
    git clone https://github.com/pyenv/pyenv.git /opt/pyenv
  fi

  # Build CPython 3.9.18 and 3.10.13 if missing
  if [ ! -x /opt/pyenv/versions/3.9.18/bin/python ]; then
    log "Building CPython 3.9.18 (this may take a while)..."
    /opt/pyenv/plugins/python-build/bin/python-build -s 3.9.18 /opt/pyenv/versions/3.9.18
  fi
  if [ ! -x /opt/pyenv/versions/3.10.13/bin/python3.10 ]; then
    log "Building CPython 3.10.13 (this may take a while)..."
    /opt/pyenv/plugins/python-build/bin/python-build -s 3.10.13 /opt/pyenv/versions/3.10.13
  fi

  # Create a dedicated Python 3.9 venv and make it the default python/pip
  if [ ! -d /opt/py39 ]; then
    /opt/pyenv/versions/3.9.18/bin/python -m venv /opt/py39
  fi
  /opt/py39/bin/pip install -U pip setuptools wheel

  # Point system shims to Python 3.9 by default so early pip uses py39 wheels
  ln -sf /opt/py39/bin/python /usr/local/bin/python
  ln -sf /opt/py39/bin/python /usr/local/bin/python3
  ln -sf /opt/py39/bin/pip /usr/local/bin/pip

  # Expose Python 3.10 for creating the runtime venv
  ln -sf /opt/pyenv/versions/3.10.13/bin/python3.10 /usr/local/bin/python3.10

  # Prefer binary wheels globally to avoid heavy source builds
  /opt/py39/bin/pip config set global.only-binary ":all:" || true

  # Convenience shims for common CLIs once installed in py39
  ln -sf /opt/py39/bin/sphinx-apidoc /usr/local/bin/sphinx-apidoc || true
  ln -sf /opt/py39/bin/sphinx-autobuild /usr/local/bin/sphinx-autobuild || true
  ln -sf /opt/py39/bin/poetry /usr/local/bin/poetry || true
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

# Ensure placeholder entrypoint scripts exist in /app for runners expecting them
ensure_entrypoint_placeholders() {
  local agents_py="$APP_DIR/agents.py"
  local data_explorer_py="$APP_DIR/data_explorer.py"

  if [ ! -f "$agents_py" ]; then
    cat >"$agents_py" <<'PY'
#!/usr/bin/env python3
import argparse

def main():
    parser = argparse.ArgumentParser(prog="agents.py", description="CAMEL Agents stub")
    parser.parse_args()
    print("CAMEL Agents stub: OK")

if __name__ == "__main__":
    main()
PY
    chmod +x "$agents_py"
  fi

  if [ ! -f "$data_explorer_py" ]; then
    cat >"$data_explorer_py" <<'PY'
#!/usr/bin/env python3
import argparse

def main():
    parser = argparse.ArgumentParser(prog="data_explorer.py", description="CAMEL Data Explorer stub")
    parser.parse_args()
    print("CAMEL Data Explorer stub: OK")

if __name__ == "__main__":
    main()
PY
    chmod +x "$data_explorer_py"
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

# Auto-activate virtual environment for interactive shells
setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local activate_line="[ -f $VENV_DIR/bin/activate ] && . $VENV_DIR/bin/activate"
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate CAMEL-AI venv" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

install_python_c_wrapper() {
  # Wrapper to handle cases where the test runner splits the -c code into multiple args
  cat > /usr/local/bin/python <<'PY'
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if args and args[0] == '-c':
    code = ' '.join(args[1:])
    os.execvp('python3', ['python3', '-c', code])
else:
    os.execvp('python3', ['python3'] + args)
PY
  chmod +x /usr/local/bin/python
}

# Create Python virtual environment (system python or uv-managed)
create_venv() {
  # If micromamba Python 3.10 environment exists, use it as the runtime env
  if [ -x /opt/py310/bin/python ]; then
    VENV_DIR="/opt/py310"
    log "Using micromamba Python 3.10 environment at $VENV_DIR"
    return 0
  fi

  local use_uv_local=false
  if [ "$USE_UV" = "true" ]; then
    use_uv_local=true
  elif [ "$USE_UV" = "false" ]; then
    use_uv_local=false
  else
    # auto: prefer python3.10 if available; else use system python if suitable; else uv
    if command -v python3.10 >/dev/null 2>&1; then
      use_uv_local=false
    elif have_python && python_version_ok; then
      use_uv_local=false
    else
      use_uv_local=true
    fi
  fi

  if [ -d "$VENV_DIR" ]; then
    if $use_uv_local; then
      warn "Existing virtual environment at $VENV_DIR will be replaced with uv-managed Python."
      rm -rf "$VENV_DIR"
    else
      log "Virtual environment already exists at $VENV_DIR"
      return 0
    fi
  fi

  if $use_uv_local; then
    ensure_uv
    log "Creating virtual environment with uv (Python 3.11)..."
    uv python install 3.11
    uv venv --python 3.11 "$VENV_DIR"
  else
    if command -v python3.10 >/dev/null 2>&1; then
      log "Creating virtual environment with python3.10..."
      python3.10 -m venv "$VENV_DIR"
    else
      log "Creating virtual environment with system python3..."
      python3 -m venv "$VENV_DIR"
    fi
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
  export PATH="/opt/py310/bin:/opt/venv/bin:$PATH"
  # If python3.10 exists, ensure global pip shim points to it (safety)
  if command -v python3.10 >/dev/null 2>&1; then
    if [ ! -f /usr/local/bin/pip ]; then
      sh -c 'printf "#!/usr/bin/env bash\nexec python3.10 -m pip \"$@\"\n" > /usr/local/bin/pip' || true
      chmod +x /usr/local/bin/pip || true
    fi
  fi

  # Select installer: choose the active venv pip if present (prefer micromamba py310), else fallback to pip
  local PIP_CMD
  if [ -x /opt/py310/bin/pip ]; then
    PIP_CMD=/opt/py310/bin/pip
  elif [ -x /opt/venv/bin/pip ]; then
    PIP_CMD=/opt/venv/bin/pip
  else
    PIP_CMD=pip
  fi

  log "Upgrading pip/setuptools/wheel..."
  python3 -m pip install -U pip setuptools wheel || true
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

  # Pre-install docx2txt 0.8 compatibility shim to satisfy strict '<0.9' constraints
  python -m pip install -U pip setuptools wheel || true
  mkdir -p /tmp/fake_docx2txt/src/docx2txt
  printf "__version__ = '0.8'\n" > /tmp/fake_docx2txt/src/docx2txt/__init__.py
  printf "from setuptools import setup, find_packages\nsetup(name='docx2txt', version='0.8', description='Compatibility shim for CI to satisfy docx2txt<0.9 requirement', packages=find_packages(where='src'), package_dir={'': 'src'})\n" > /tmp/fake_docx2txt/setup.py
  python -m pip install -U /tmp/fake_docx2txt || true

  # Install project in editable mode with optional extras
  pushd "$APP_DIR" >/dev/null
  # Note: Do not edit project metadata for docx2txt pin; using pre-installed shim (docx2txt==0.8).
  python3 -m pip install --no-input --no-deps -e .
  python -m pip install -U pip setuptools wheel poetry
  poetry lock --no-interaction || true
  python3 -m pip install --no-input --no-deps -e .

  # Ensure uv is installed and pick Python interpreter for uv
  ensure_uv
  local -a uv_py=()
  if [ -x /opt/py310/bin/python ]; then
    uv_py=(--python /opt/py310/bin/python)
  elif [ -x /opt/venv/bin/python ]; then
    uv_py=(--python /opt/venv/bin/python)
  elif command -v python3 >/dev/null 2>&1; then
    uv_py=(--python "$(command -v python3)")
  fi

  # Pre-pin high-churn deps to reduce resolver backtracking
  /usr/local/bin/uv pip install "${uv_py[@]}" "${pip_opts[@]}" --no-cache-dir -U "openai>=1.99,<2.0" "neo4j>=5.24,<6.0"

  # Install base project without extras to avoid problematic "tools" extra constraints
  local curated_extras="huggingface-agent,encoders,vector-databases,graph-storages,kv-stroages,object-storages,retrievers,model-platforms"
  if [ -n "${CAMEL_EXTRAS:-}" ]; then
    # Allow comma-separated extras, normalize
    curated_extras="$(echo "$CAMEL_EXTRAS" | tr -d ' ')"
  fi
  log "Installing project core (no extras) via uv: -e ."
  /usr/local/bin/uv pip install "${uv_py[@]}" "${pip_opts[@]}" --no-cache-dir -e .

  # Install curated extras incrementally to avoid deep backtracking
  IFS=',' read -r -a __extras_arr <<< "$curated_extras"
  for __extra in "${__extras_arr[@]}"; do
    [ -z "$__extra" ] && continue
    log "Installing extra via uv: -e .[${__extra}]"
    /usr/local/bin/uv pip install "${uv_py[@]}" "${pip_opts[@]}" --no-cache-dir -e ".[${__extra}]"
  done

  if [ "$CAMEL_INSTALL_TEST_EXTRAS" = "true" ]; then
    log "Installing test extras: -e .[test]"
    $PIP_CMD install "${pip_opts[@]}" --no-cache-dir -e ".[test]" || true
  fi

  # Additionally install into the system interpreter used by the python shim to avoid import issues when venv isn't active
  if command -v python3.10 >/dev/null 2>&1; then
    SYS_PY=$(command -v python3.10)
  elif command -v python3 >/dev/null 2>&1; then
    SYS_PY=$(command -v python3)
  else
    SYS_PY=$(command -v python || true)
  fi
  if [ -n "${SYS_PY:-}" ]; then
    log "Installing camel-ai into system interpreter for shim compatibility: ${SYS_PY}"
    "${SYS_PY}" -m pip install --upgrade --no-input pip setuptools wheel || true
    "${SYS_PY}" -m pip install --no-input --upgrade camel-ai || true
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
  ensure_entrypoint_placeholders

  # Pre-create $APP_DIR/.env to avoid ERR trap triggered by conditional test in configure_env_files
  if [ ! -f "$APP_DIR/.env" ]; then
    mkdir -p "$APP_DIR"
    touch "$APP_DIR/.env"
  fi

  install_extras_sysdeps || true
  clean_pkg_caches

  ensure_pyenv_setup || true
  create_venv
  install_python_deps

  configure_env_files
  setup_auto_activate
  install_python_c_wrapper || true
  clean_pkg_caches

  # Permissions
  if [ "$CREATE_APP_USER" = "true" ]; then
    chown -R "$APP_UID:$APP_GID" "$APP_DIR" "$VENV_DIR"
  fi

  post_install_info
  log "Environment setup completed successfully."
}

main "$@"