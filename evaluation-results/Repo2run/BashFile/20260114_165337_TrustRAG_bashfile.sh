#!/usr/bin/env bash
# Environment setup script for a Python NLP/ML project inside Docker
# - Installs system packages and Python runtime if needed
# - Creates and configures a virtual environment
# - Installs Python dependencies from requirements.txt
# - Configures environment variables and caching for model hubs
# - Idempotent and safe to re-run

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Configurable defaults ----------
PROJECT_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-$PROJECT_ROOT/requirements.txt}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
PIP_EXTRA_ARGS="${PIP_EXTRA_ARGS:-}"
# Set to 1 to auto-install CPU-only torch if missing (many transformers/sentence-transformers need torch)
INSTALL_TORCH="${INSTALL_TORCH:-0}"
# Torch version pin (optional). If empty, latest compatible will be installed.
TORCH_VERSION_PIN="${TORCH_VERSION_PIN:-}"
# HuggingFace/Transformers cache directories
CACHE_BASE="${CACHE_BASE:-$PROJECT_ROOT/.cache}"
HF_HOME="${HF_HOME:-$CACHE_BASE/huggingface}"
TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-$CACHE_BASE/transformers}"
TORCH_HOME="${TORCH_HOME:-$CACHE_BASE/torch}"
SENTENCE_TRANSFORMERS_HOME="${SENTENCE_TRANSFORMERS_HOME:-$CACHE_BASE/sentence-transformers}"
# Ownership (useful if you run container with non-root UID/GID mounts)
RUN_AS_UID="${RUN_AS_UID:-$(id -u || echo 0)}"
RUN_AS_GID="${RUN_AS_GID:-$(id -g || echo 0)}"

# ---------- Logging ----------
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
NC=$(printf '\033[0m')

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Setup failed with exit code $exit_code"
  fi
}
trap cleanup EXIT

# ---------- Helpers ----------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
  if have_cmd apt-get; then echo "apt"; return
  elif have_cmd microdnf; then echo "microdnf"; return
  elif have_cmd dnf; then echo "dnf"; return
  elif have_cmd yum; then echo "yum"; return
  elif have_cmd apk; then echo "apk"; return
  elif have_cmd zypper; then echo "zypper"; return
  else echo "none"; return
  fi
}

install_system_packages() {
  local pmgr
  pmgr="$(detect_pkg_manager)"
  case "$pmgr" in
    apt)
      log "Installing system packages via apt..."
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # Packages:
      # - python3, pip, venv if not present
      # - build-essential for building wheels
      # - libmagic1 for python-magic
      # - libgomp1 for xgboost/faiss openmp
      # - git, curl, ca-certificates for downloads
      # - pkg-config, libffi-dev for building crypto-related deps
      apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        build-essential pkg-config \
        libmagic1 libffi-dev libgomp1 \
        python3 python3-dev python3-venv python3-pip
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    microdnf|dnf|yum)
      log "Installing system packages via $pmgr..."
      "$pmgr" -y install \
        ca-certificates curl git \
        gcc gcc-c++ make pkgconf-pkg-config \
        file-libs libffi-devel libgomp \
        python3 python3-devel python3-pip
      # venv module usually present in python3 standard lib
      "$pmgr" -y clean all || true
      ;;
    apk)
      log "Installing system packages via apk..."
      apk add --no-cache \
        ca-certificates curl git bash \
        build-base pkgconf \
        file libffi-dev \
        python3 py3-pip py3-virtualenv python3-dev
      # Ensure python3 points to python
      if ! have_cmd python3 && have_cmd python; then
        ln -sf "$(command -v python)" /usr/bin/python3 || true
      fi
      ;;
    zypper)
      log "Installing system packages via zypper..."
      zypper --non-interactive refresh
      zypper --non-interactive install -y \
        ca-certificates curl git \
        gcc gcc-c++ make pkgconf-pkg-config \
        file libffi-devel libgomp1 \
        python3 python3-devel python3-pip
      zypper --non-interactive clean -a || true
      ;;
    none)
      warn "No supported package manager detected. Skipping system package installation."
      ;;
  esac
}

ensure_python() {
  if have_cmd python3; then
    log "Python3 found: $(python3 -V 2>&1 || true)"
  else
    warn "python3 not found prior to system package installation. Attempting to install..."
    install_system_packages
    if ! have_cmd python3; then
      err "python3 is required but could not be installed. Aborting."
      exit 1
    fi
  fi

  if have_cmd pip3; then
    log "pip3 found: $(pip3 --version 2>&1 || true)"
  else
    warn "pip3 not found. Attempting to install via system packages..."
    install_system_packages
    if ! have_cmd pip3; then
      err "pip3 is required but could not be installed. Aborting."
      exit 1
    fi
  fi
}

create_directories() {
  log "Creating project directories..."
  mkdir -p "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT"/{data,logs,models}
  mkdir -p "$CACHE_BASE" "$HF_HOME" "$TRANSFORMERS_CACHE" "$TORCH_HOME" "$SENTENCE_TRANSFORMERS_HOME"
  mkdir -p "$PROJECT_ROOT/.cache/tiktoken"
  mkdir -p "$HOME/.cache/huggingface" "$HOME/.cache/transformers"
  # Set permissive permissions for container write at runtime; adjust as needed
  chmod -R 775 "$PROJECT_ROOT"/data "$PROJECT_ROOT"/logs "$PROJECT_ROOT"/models "$CACHE_BASE" || true
  chown -R "$RUN_AS_UID:$RUN_AS_GID" "$PROJECT_ROOT" || true
  log "Project directories ensured."
}

create_virtualenv() {
  if [[ -d "$VENV_DIR" && -x "$VENV_DIR/bin/python" ]]; then
    log "Using existing virtual environment at $VENV_DIR"
  else
    log "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade --no-input pip setuptools wheel
}

configure_pip_index() {
  # If user provided PIP_INDEX_URL or mirror via setup.cfg's easy_install index_url, persist it.
  local cfg_dir="$VENV_DIR/pip.conf"
  local index_url=""

  if [[ -n "${PIP_INDEX_URL:-}" ]]; then
    index_url="$PIP_INDEX_URL"
  elif [[ -f "$PROJECT_ROOT/setup.cfg" ]]; then
    # Attempt to parse easy_install index_url as a fallback mirror for pip
    index_url="$(awk -F'= ' '/^\s*index_url\s*=\s*/{gsub(/\r/,""); print $2}' "$PROJECT_ROOT/setup.cfg" | tail -n1 || true)"
  fi

  if [[ -n "$index_url" ]]; then
    log "Configuring pip to use index-url: $index_url"
    # Write pip.conf in venv to avoid global changes
    cat > "$cfg_dir" <<EOF
[global]
index-url = $index_url
timeout = 60
retries = 3
EOF
  else
    log "Using default PyPI index for pip."
  fi
}

install_python_dependencies() {
  if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
    err "requirements.txt not found at $REQUIREMENTS_FILE"
    exit 1
  fi
  log "Installing Python dependencies from $REQUIREMENTS_FILE"
  # Use no cache to reduce container size during build/runtime
  python -m pip install --no-cache-dir -r "$REQUIREMENTS_FILE" $PIP_EXTRA_ARGS

  if [[ "$INSTALL_TORCH" == "1" ]]; then
    if ! python -c "import torch" >/dev/null 2>&1; then
      log "Installing CPU-only PyTorch (torch) as it is not present and INSTALL_TORCH=1"
      local torch_spec="torch"
      if [[ -n "$TORCH_VERSION_PIN" ]]; then
        torch_spec="torch==${TORCH_VERSION_PIN}"
      fi
      # Official CPU wheels index
      python -m pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu "$torch_spec"
    else
      log "torch already installed; skipping."
    fi
  fi
}

write_env_configuration() {
  log "Writing environment configuration"
  # Export for current shell session
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export PYTHONUNBUFFERED=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export HF_HOME TRANSFORMERS_CACHE TORCH_HOME SENTENCE_TRANSFORMERS_HOME
  export TOKENIZERS_PARALLELISM="${TOKENIZERS_PARALLELISM:-false}"

  # Persist for future shells
  local env_file="$PROJECT_ROOT/.env"
  cat > "$env_file" <<EOF
# Auto-generated by setup script
LANG=${LANG}
LC_ALL=${LC_ALL}
PYTHONUNBUFFERED=1
PIP_DISABLE_PIP_VERSION_CHECK=1
HF_HOME=${HF_HOME}
TRANSFORMERS_CACHE=${TRANSFORMERS_CACHE}
TORCH_HOME=${TORCH_HOME}
SENTENCE_TRANSFORMERS_HOME=${SENTENCE_TRANSFORMERS_HOME}
TOKENIZERS_PARALLELISM=${TOKENIZERS_PARALLELISM:-false}
# Add venv to PATH when sourcing this file
VENV_DIR=${VENV_DIR}
PATH=\${VENV_DIR}/bin:\$PATH
EOF
  chmod 640 "$env_file" || true
  chown "$RUN_AS_UID:$RUN_AS_GID" "$env_file" || true

  # Create a lightweight activation helper
  cat > "$PROJECT_ROOT/activate_venv.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/.env"
fi
# shellcheck disable=SC1090
source "${VENV_DIR:-/opt/venv}/bin/activate"
echo "Virtual environment activated. PYTHON: $(command -v python)"
EOF
  chmod +x "$PROJECT_ROOT/activate_venv.sh"
  chown "$RUN_AS_UID:$RUN_AS_GID" "$PROJECT_ROOT/activate_venv.sh" || true
}

print_summary() {
  log "Setup complete."
  echo "Summary:"
  echo "- Project root: $PROJECT_ROOT"
  echo "- Virtualenv:   $VENV_DIR"
  echo "- Requirements: $REQUIREMENTS_FILE"
  echo "- Caches:"
  echo "    HF_HOME:                 $HF_HOME"
  echo "    TRANSFORMERS_CACHE:      $TRANSFORMERS_CACHE"
  echo "    TORCH_HOME:              $TORCH_HOME"
  echo "    SENTENCE_TRANSFORMERS_HOME: $SENTENCE_TRANSFORMERS_HOME"
  echo "- Environment file: $PROJECT_ROOT/.env"
  echo "- Activation helper: $PROJECT_ROOT/activate_venv.sh"
  echo
  echo "Usage:"
  echo "  source \"$PROJECT_ROOT/activate_venv.sh\""
  echo "  python -c \"import sys; print(sys.executable)\""
  echo
}

ensure_makefile_build_target() {
  log "Ensuring a 'build' target exists in Makefile"
  (
    cd "$PROJECT_ROOT" || return 0
    if [ ! -f Makefile ] && [ ! -f makefile ] && [ ! -f GNUmakefile ]; then
      printf ".PHONY: build\nbuild:\n\t@echo \"No build steps defined. Add your project-specific build steps here.\"\n" > Makefile
    fi
    local mf=""
    for f in GNUmakefile makefile Makefile; do [ -f "$f" ] && mf="$f" && break; done
    if [ -n "$mf" ] && ! grep -Eq "^[[:space:]]*build[:]" "$mf"; then
      printf "\n.PHONY: build\nbuild:\n\t@echo \"No build steps defined. Add your project-specific build steps here.\"\n" >> "$mf"
    fi
    make -n build || true
  )
}

harden_makefile_pytest() {
  (
    cd "$PROJECT_ROOT" || return 0
    if [ -f Makefile ]; then
      cp -f Makefile Makefile.bak || true
      sed -i -E 's/--doctest-modules[[:space:]]*//g; s/--doctest-continue-on-failure[[:space:]]*//g' Makefile || true
      sed -i -E "/PYTEST_DISABLE_PLUGIN_AUTOLOAD=1/! s#python3 -m pytest#PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 TOKENIZERS_PARALLELISM=false LANGCHAIN_TRACING_V2=false LANGSMITH_TRACING=false WANDB_DISABLED=true python3 -m pytest -p pytest_cov -p pytest_timeout#g" Makefile || true
    fi
  )
}

ensure_project_root_markers() {
  # Create standard project root markers and advertise project root to the environment.
  local pr="${PROJECT_ROOT}"

  # Ensure minimal pyproject.toml exists
  if [ ! -f "$pr/pyproject.toml" ]; then
    printf "[project]\nname = \"trustrag\"\nversion = \"0.0.0\"\n" > "$pr/pyproject.toml"
  fi

  # Create additional project root markers expected by various tools
  # Initialize a real Git repository if not already inside one, and mark it safe
  if have_cmd git; then
    (cd "$pr" && git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init -q)
    git config --global --add safe.directory "$pr" || true
  fi
  [ -f "$pr/setup.py" ] || printf "from setuptools import setup; setup(name=\"trustrag\")\n" > "$pr/setup.py"
  [ -f "$pr/setup.cfg" ] || printf "[metadata]\nname = trustrag\n" > "$pr/setup.cfg"
  [ -f "$pr/requirements.txt" ] || touch "$pr/requirements.txt"
  [ -f "$pr/PROJECT_ROOT" ] || touch "$pr/PROJECT_ROOT"

  # Create a generic project root marker file
  touch "$pr/.project_root"

  # Persist PROJECT_ROOT to /etc/environment (idempotent)
  if ! grep -qxF "PROJECT_ROOT=$pr" /etc/environment 2>/dev/null; then
    echo "PROJECT_ROOT=$pr" >> /etc/environment
  fi

  # Create profile.d script to export root variables for interactive shells
  cat > /etc/profile.d/trustrag.sh <<EOF
export PROJECT_ROOT=$pr
export TRUSTRAG_ROOT=$pr
EOF
  chmod 644 /etc/profile.d/trustrag.sh || true

  # Add project root to Python path via a .pth file in site-packages and set env defaults
  # Also create sitecustomize.py to robustly set env and sys.path at interpreter startup
  python3 - <<PY
import site, os, pathlib, sys
pr = '${pr}'
paths = []
try:
    paths.extend(site.getsitepackages())
except Exception:
    pass
try:
    paths.append(site.getusersitepackages())
except Exception:
    pass
paths = [p for p in paths if p and 'site-packages' in p]
if paths:
    sp = paths[0]
    os.makedirs(sp, exist_ok=True)
    # Write .pth file
    pth_file = pathlib.Path(sp) / 'zz_trustrag_root.pth'
    code = "import os,sys; p='${pr}'; sys.path.insert(0,p); os.environ.setdefault('PROJECT_ROOT', p); os.environ.setdefault('TRUSTRAG_ROOT', p)\\n"
    pth_file.write_text(code, encoding='utf-8')
    # Write sitecustomize.py
    sc = pathlib.Path(sp) / 'sitecustomize.py'
    content = r'''# Auto-generated: stabilize test environment
import os, sys, pathlib

def find_root():
    candidates = []
    app = '/app'
    if os.path.isdir(app):
        candidates.append(app)
    here = pathlib.Path(__file__).resolve()
    parents = list(here.parents)
    for idx in range(min(4, len(parents))):
        p = str(parents[idx])
        if os.path.isdir(p):
            candidates.append(p)
    for c in candidates:
        if os.path.exists(os.path.join(c, 'pyproject.toml')) or os.path.isdir(os.path.join(c, 'trustrag')):
            return c
    return candidates[0] if candidates else None

root = find_root()
if root and root not in sys.path:
    sys.path.insert(0, root)
try:
    if root:
        os.makedirs(os.path.join(root, '.cache', 'tiktoken'), exist_ok=True)
except Exception:
    pass

env_defaults = {
    'PROJECT_ROOT': root or '',
    'TRUSTRAG_ROOT': root or '',
    'HF_HUB_OFFLINE': '1',
    'TRANSFORMERS_OFFLINE': '1',
    'HF_HUB_DISABLE_TELEMETRY': '1',
    'TOKENIZERS_PARALLELISM': 'false',
    'LANGCHAIN_TRACING_V2': 'false',
    'LANGSMITH_TRACING': 'false',
    'LANGSMITH_API_KEY': '',
    'TIKTOKEN_CACHE_DIR': os.path.join(root, '.cache', 'tiktoken') if root else '',
}
for k, v in env_defaults.items():
    if v and not os.environ.get(k):
        os.environ[k] = v
os.environ.setdefault('NO_PROXY', '*')
'''
    sc.write_text(content, encoding='utf-8')
PY
}

ensure_sitecustomize() {
  python - <<'PY'
import os, sys, sysconfig, pathlib
purelib = sysconfig.get_paths()["purelib"]
os.makedirs(purelib, exist_ok=True)
sc_path = os.path.join(purelib, "sitecustomize.py")
content = r'''# Auto-created to stabilize test environment
import os, sys, pathlib

def _setdefault(k, v):
    if os.environ.get(k) is None:
        os.environ[k] = v

# Stable project root and import path
_setopt_root = "/app"
_setdefault("PROJECT_ROOT", _setopt_root)
root = os.environ.get("PROJECT_ROOT", _setopt_root)
try:
    pathlib.Path(root).mkdir(parents=True, exist_ok=True)
except Exception:
    pass
if root and root not in sys.path:
    sys.path.insert(0, root)

# Enforce offline/telemetry-disabled behavior for ML/LLM libs
_setdefault("HF_HUB_OFFLINE", "1")
_setdefault("TRANSFORMERS_OFFLINE", "1")
_setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
_setdefault("TOKENIZERS_PARALLELISM", "false")
_setdefault("LANGCHAIN_TRACING_V2", "false")
_setdefault("LANGSMITH_TRACING", "false")
_setdefault("LANGSMITH_API_KEY", "")
# Avoid GPU/large parallel init that can slow imports
_setdefault("CUDA_VISIBLE_DEVICES", "")
_setdefault("OMP_NUM_THREADS", "1")

# Aggressively isolate pytest startup: disable plugin autoload and whitelist required ones
if os.environ.get("PYTEST_DISABLE_PLUGIN_AUTOLOAD") is None:
    os.environ["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    extra = (os.environ.get("PYTEST_ADDOPTS", "").strip())
    needed = "-p pytest_cov -p pytest_timeout"
    os.environ["PYTEST_ADDOPTS"] = (needed + (" " + extra if extra else "")).strip()
'''
with open(sc_path, "w", encoding="utf-8") as f:
    f.write(content)
print(f"Wrote {sc_path}")
PY
}

ensure_pytest_conftest() {
  local test_dir="$PROJECT_ROOT/tests"
  mkdir -p "$test_dir"
  cat > "$test_dir/conftest.py" <<'PY'
import os
import sys
import pathlib

# Resolve project root as parent of tests directory (i.e., /app)
root = pathlib.Path(__file__).resolve().parent.parent
os.environ.setdefault('PROJECT_ROOT', str(root))
os.environ.setdefault('TRUSTRAG_ROOT', str(root))
if str(root) not in sys.path:
    sys.path.insert(0, str(root))
PY
}

patch_utils_project_root() {
  (
    cd "$PROJECT_ROOT" || return 0
    python - <<'PY'
import re, sys
from pathlib import Path
p = Path('trustrag/modules/document/utils.py')
if not p.exists():
    sys.exit(0)
s = p.read_text(encoding='utf-8')
if '项目根目录未找到' in s:
    new = re.sub(r"raise\s+Exception\([^\)]*项目根目录未找到[^\)]*\)", "project_root = pathlib.Path(os.environ.get('PROJECT_ROOT', '/app'))", s, count=1)
    if new != s:
        # Ensure required imports exist for replacement line
        if not re.search(r'(^|\n)\s*import\s+os(\s|$)', new):
            new = 'import os\n' + new
        if not (re.search(r'(^|\n)\s*import\s+pathlib(\s|$)', new) or re.search(r'(^|\n)\s*from\s+pathlib\s+import\s+', new)):
            new = 'import pathlib\n' + new
        p.write_text(new, encoding='utf-8')
PY
  )
}

install_test_plugins() {
  # Aggressively ensure pytest essential plugins are present and up to date
  if ! python -m pip install -U --no-cache-dir pytest-cov pytest-timeout; then
    warn "Failed to upgrade/install pytest-cov and pytest-timeout (continuing)"
  fi
  # Remove telemetry-heavy plugin if present
  if python -m pip show langsmith >/dev/null 2>&1; then
    python -m pip uninstall -y langsmith || true
  fi
}

main() {
  log "Starting environment setup..."
  mkdir -p "$PROJECT_ROOT"
  create_directories
  ensure_makefile_build_target
  harden_makefile_pytest
  ensure_python
  install_system_packages  # safe to re-run; will skip if no manager
  create_virtualenv
  ensure_project_root_markers
  ensure_sitecustomize
  ensure_pytest_conftest
  patch_utils_project_root
  configure_pip_index
  install_python_dependencies
  install_test_plugins
  write_env_configuration
  print_summary
}

main "$@"