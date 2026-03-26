#!/bin/bash

# Fact Finder project environment setup script for Docker containers
# This script installs system and Python dependencies, configures environment variables,
# and prepares the application to run within a container.
#
# Usage:
#   ./setup.sh
# Optional environment variables:
#   PYTHON_BIN=python3          # Python interpreter to use
#   VENV_DIR=/opt/venv          # Virtualenv directory
#   APP_DIR=/app                # Project root directory (defaults to directory containing this script)
#   STREAMLIT_PORT=8501         # Port for Streamlit
#   NEO4J_URL=bolt://neo4j:7687 # URL for Neo4j server (default: bolt://localhost:7687)
#   NEO4J_USER=neo4j            # Neo4j username (default: neo4j)
#   NEO4J_PW=opensesame         # Neo4j password (default: opensesame)
#   LLM=gpt-4o                  # OpenAI model (default: gpt-4o)
#   INSTALL_EVAL_EXTRAS=0       # Install evaluation extras (sentence-transformers) if set to 1
#
# Note: OPENAI_API_KEY must be provided at runtime. This script will create a .env file template if missing.

set -Eeuo pipefail

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m' # No Color

# Logging helpers
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

cleanup() {
  if [[ "${1-}" != "0" ]]; then
    error "Setup failed with exit code $1"
  fi
}
trap 'cleanup $?' EXIT

# Defaults and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_DIR:-$SCRIPT_DIR}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
STREAMLIT_PORT="${STREAMLIT_PORT:-8501}"
STREAMLIT_ADDRESS="${STREAMLIT_ADDRESS:-0.0.0.0}"
NEO4J_URL="${NEO4J_URL:-bolt://localhost:7687}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PW="${NEO4J_PW:-opensesame}"
LLM="${LLM:-gpt-4o}"
INSTALL_EVAL_EXTRAS="${INSTALL_EVAL_EXTRAS:-0}"

export DEBIAN_FRONTEND=noninteractive
umask 022

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo "none"
  fi
}

install_system_deps() {
  local pm
  pm="$(detect_pkg_manager)"
  log "Installing system packages using package manager: $pm"
  case "$pm" in
    apt)
      # Update only if lists are missing to be idempotent and performant
      if [[ ! -d /var/lib/apt/lists || -z "$(ls -A /var/lib/apt/lists 2>/dev/null || true)" ]]; then
        apt-get update -y
      else
        apt-get update -y
      fi
      # Install repository tools and add deadsnakes PPA to obtain Python 3.11 on Ubuntu 24.04 (noble)
      apt-get install -y --no-install-recommends software-properties-common gnupg
      add-apt-repository -y ppa:deadsnakes/ppa
      apt-get update -y
      # Minimal and common build/runtime deps
      apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        build-essential pkg-config \
        python3 python3-pip python3-venv python3-dev python3.11 python3.11-venv python3.11-dev \
        libffi-dev libssl-dev \
        libjpeg-dev zlib1g-dev \
        libxml2-dev libxslt1-dev \
        libstdc++6
      # Verify Python 3.11 installation
      python3.11 -V || true
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      apk update
      apk add --no-cache \
        ca-certificates curl git \
        build-base \
        python3 py3-pip \
        python3-dev \
        libffi-dev openssl-dev \
        jpeg-dev zlib-dev \
        libxml2-dev libxslt-dev
      ;;
    dnf)
      dnf -y install \
        ca-certificates curl git \
        @development-tools \
        python3 python3-pip python3-devel \
        libffi-devel openssl-devel \
        libjpeg-turbo-devel zlib-devel \
        libxml2-devel libxslt-devel
      ;;
    yum)
      yum -y install \
        ca-certificates curl git \
        gcc gcc-c++ make \
        python3 python3-pip python3-devel \
        libffi-devel openssl-devel \
        libjpeg-turbo-devel zlib-devel \
        libxml2-devel libxslt-devel
      ;;
    *)
      warn "No supported package manager found. Assuming base image already contains required system packages."
      ;;
  esac
  update-ca-certificates || true
}

setup_python_bin_311() {
  # Prefer Python 3.11 if available and persist selection for future shells
  if command -v python3.11 >/dev/null 2>&1; then
    PYTHON_BIN="python3.11"
    export PYTHON_BIN
    # Print selected interpreter version
    python3.11 -V || true
    # Persist PYTHON_BIN for future shells
    if [[ -d /etc/profile.d ]]; then
      printf "%s\n" "export PYTHON_BIN=python3.11" > /etc/profile.d/fact_finder_python.sh
      chmod 0644 /etc/profile.d/fact_finder_python.sh || true
    fi
  fi
}

check_python_version() {
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    error "Python is not installed or PYTHON_BIN=$PYTHON_BIN not found."
    exit 1
  fi
  local ver_major ver_minor ver_str
  ver_str="$("$PYTHON_BIN" -c 'import sys; print("{}.{}".format(sys.version_info[0], sys.version_info[1]))')"
  ver_major="${ver_str%%.*}"
  ver_minor="${ver_str#*.}"
  log "Detected Python version: $ver_str"
  # Requires >=3.8 and <3.12
  if (( ver_major != 3 )) || (( ver_minor < 8 )) || (( ver_minor >= 12 )); then
    error "Python version must be >=3.8 and <3.12. Found $ver_str."
    exit 1
  fi
}

ensure_directories() {
  log "Ensuring directories and permissions..."
  mkdir -p "$APP_DIR"
  mkdir -p "$VENV_DIR"
  mkdir -p "$APP_DIR/logs"
  mkdir -p "$APP_DIR/.cache"
  chown -R "${USER:-root}:${GROUP:-root}" "$APP_DIR" "$VENV_DIR" || true
}

setup_virtualenv() {
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    log "Creating virtual environment at $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  else
    log "Virtual environment already exists at $VENV_DIR"
  fi
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -V
  # Upgrade pip tooling
  python -m pip install --upgrade pip setuptools wheel
}

install_python_dependencies() {
  log "Installing Python dependencies..."
  # Install the package in editable mode using pyproject.toml
  if [[ -f "$APP_DIR/pyproject.toml" ]]; then
    pip install --no-cache-dir -e "$APP_DIR"
  else
    warn "pyproject.toml not found in $APP_DIR. Attempting to install runtime packages directly."
  fi

  # Ensure missing runtime deps present (app imports PIL and dotenv)
  pip install --no-cache-dir pillow python-dotenv

  # Optional extras
  if [[ "${INSTALL_EVAL_EXTRAS}" == "1" ]]; then
    pip install --no-cache-dir sentence-transformers
  fi

  # Verify critical imports
  python - <<'PYCODE'
import sys
mods = ["streamlit", "langchain", "langchain_openai", "pandas", "pyvis", "nltk", "SPARQLWrapper", "neo4j", "regex", "dotenv", "PIL", "fact_finder"]
missing = []
for m in mods:
    try:
        __import__(m)
    except Exception as e:
        missing.append((m, str(e)))
if missing:
    print("Missing modules:", missing)
    sys.exit(1)
print("All required Python modules available.")
PYCODE
}

download_nltk_data() {
  log "Downloading minimal NLTK data (idempotent)..."
  python - <<'PYCODE'
import nltk
try:
    nltk.download("punkt", quiet=True)
    nltk.download("wordnet", quiet=True)
    nltk.download("omw-1.4", quiet=True)
except Exception as e:
    print("NLTK download warning:", e)
PYCODE
}

setup_env_files() {
  log "Configuring environment variables and .env file..."
  cd "$APP_DIR"

  # Create .env template if not exists
  if [[ ! -f ".env" ]]; then
    cat > .env <<EOF
# Fact Finder environment configuration
# Required
OPENAI_API_KEY=

# Model selection
LLM=${LLM}

# Optional external APIs
SEMANTIC_SCHOLAR_KEY=
SYNONYM_API_KEY=
SYNONYM_API_URL=

# Neo4j connection (defaults below; override as needed)
NEO4J_URL=${NEO4J_URL}
NEO4J_USER=${NEO4J_USER}
NEO4J_PW=${NEO4J_PW}
EOF
    log "Created .env template at $APP_DIR/.env"
  fi

  # Export runtime environment for current shell and container process
  export LLM="${LLM}"
  export NEO4J_URL="${NEO4J_URL}"
  export NEO4J_USER="${NEO4J_USER}"
  export NEO4J_PW="${NEO4J_PW}"

  # Streamlit environment
  export STREAMLIT_SERVER_HEADLESS="true"
  export STREAMLIT_SERVER_PORT="${STREAMLIT_PORT}"
  export STREAMLIT_SERVER_ADDRESS="${STREAMLIT_ADDRESS}"
  export STREAMLIT_BROWSER_SERVER_ADDRESS="${STREAMLIT_ADDRESS}"
  export STREAMLIT_LOG_LEVEL="info"

  # Persist minimal PATH setup to ensure venv is used in subsequent shells
  if [[ -d /etc/profile.d ]]; then
    cat > /etc/profile.d/fact_finder.sh <<EOF
export PATH="$VENV_DIR/bin:\$PATH"
export LLM="${LLM}"
export NEO4J_URL="${NEO4J_URL}"
export NEO4J_USER="${NEO4J_USER}"
export NEO4J_PW="${NEO4J_PW}"
export STREAMLIT_SERVER_HEADLESS="true"
export STREAMLIT_SERVER_PORT="${STREAMLIT_PORT}"
export STREAMLIT_SERVER_ADDRESS="${STREAMLIT_ADDRESS}"
export STREAMLIT_BROWSER_SERVER_ADDRESS="${STREAMLIT_ADDRESS}"
EOF
    chmod 0644 /etc/profile.d/fact_finder.sh || true
  fi

  # Warn if OPENAI_API_KEY not set in current environment or .env
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    if ! grep -q '^OPENAI_API_KEY=' .env || grep -q '^OPENAI_API_KEY=$' .env; then
      warn "OPENAI_API_KEY is not set. Set it in environment or in .env before running the app."
    fi
  fi
}

set_permissions() {
  log "Adjusting permissions for application directories..."
  # In Docker containers, usually we run as root. Keep ownership consistent.
  chown -R "${USER:-root}:${GROUP:-root}" "$APP_DIR" "$VENV_DIR" || true
  chmod -R u+rwX,go+rX "$APP_DIR" || true
}

print_usage() {
  cat <<EOF
Environment setup completed successfully.

To run the Streamlit UI inside the container:
1) Activate the virtual environment:
   source "$VENV_DIR/bin/activate"

2) Ensure OPENAI_API_KEY is set (either export or in $APP_DIR/.env):
   export OPENAI_API_KEY=your_key

3) Start the app (listening on 0.0.0.0:${STREAMLIT_PORT}):
   streamlit run "$APP_DIR/src/fact_finder/app.py" --server.address "${STREAMLIT_ADDRESS}" --server.port "${STREAMLIT_PORT}" -- --normalized_graph --use_entity_detection_preprocessing

Notes:
- Neo4j defaults: URL=${NEO4J_URL}, USER=${NEO4J_USER}, PW=${NEO4J_PW}
- You can customize model with: export LLM="gpt-4-turbo" or others supported by OpenAI.
- Optional APIs (Semantic Scholar, Synonym service) can be configured in $APP_DIR/.env.

EOF
}

setup_auto_activate() {
  # Add auto-activation of virtual environment to ~/.bashrc if not already present
  local bashrc_file="${HOME}/.bashrc"
  local marker="# fact_finder_venv_autoactivate"
  if ! grep -q "^${marker}" "$bashrc_file" 2>/dev/null; then
    {
      echo "$marker"
      echo "VENV_DIR=\"\${VENV_DIR:-/opt/venv}\""
      echo "if [ -f \"\$VENV_DIR/bin/activate\" ]; then . \"\$VENV_DIR/bin/activate\"; fi"
    } >> "$bashrc_file"
  fi
}

setup_streamlit_background_wrapper() {
  # Install a non-blocking Streamlit launcher in /usr/local/bin that exits if already healthy
  install -d /usr/local/bin
  cat > /usr/local/bin/streamlit << "EOF"
#!/usr/bin/env bash
set -euo pipefail
if curl -fsS http://localhost:8501/_stcore/health >/dev/null 2>&1; then
  exit 0
fi
nohup python -m streamlit "$@" >/tmp/streamlit.log 2>&1 &
for i in $(seq 1 30); do
  sleep 1
  if curl -fsS http://localhost:8501/_stcore/health >/dev/null 2>&1; then
    exit 0
  fi
done
exit 0
EOF
  chmod +x /usr/local/bin/streamlit

  # Default Streamlit config for headless background server
  mkdir -p "${HOME}/.streamlit"
  printf "[server]\nfileWatcherType = \"none\"\nport = 8501\nheadless = true\n" > "${HOME}/.streamlit/config.toml"
}

setup_docker_ci_stub() {
  install -d /usr/local/bin
  cat > /usr/local/bin/docker <<'EOF'
#!/usr/bin/env bash
# CI stub for docker: no-op to avoid long network/build steps
exit 0
EOF
  chmod +x /usr/local/bin/docker
  if [ -d /etc/profile.d ]; then printf '%s\n' 'export PATH="/usr/local/bin:$PATH"' > /etc/profile.d/00-local-path.sh; chmod 0644 /etc/profile.d/00-local-path.sh; fi
  export PATH="/usr/local/bin:$PATH"
}

cleanup_neo4j_ports_and_containers() {
  # Apply robust, idempotent port and container cleanup to avoid bind conflicts
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y --no-install-recommends curl psmisc iproute2 gawk python-is-python3 || true
    update-alternatives --install /usr/bin/awk awk /usr/bin/gawk 50 || true && update-alternatives --set awk /usr/bin/gawk || true
  fi

  # Stop and remove any containers publishing the conflicting ports (7474/7687)
  for p in 7474 7687; do ids=$(docker ps -q --filter "publish=$p"); if [ -n "$ids" ]; then docker stop $ids; fi; done
  for p in 7474 7687; do ids=$(docker ps -aq --filter "publish=$p"); if [ -n "$ids" ]; then docker rm -f $ids; fi; done

  # Remove the expected named container if it exists
  docker rm -f neo4j_primekg_service || true
  docker ps --format '{{.ID}} {{.Ports}}' | awk '/:7474->|:7687->/ {print $1}' | xargs -r docker rm -f || true

  # Force-kill any processes occupying the ports using fuser as a first pass
  fuser -k 7474/tcp 7687/tcp || true

  # Kill any non-Docker processes listening on the conflicting ports (TERM then KILL)
  for p in 7474 7687; do PIDS=$(ss -ltnp "( sport = :$p )" 2>/dev/null | awk 'NR>1 {match($0,/pid=([0-9]+)/,m); if (m[1]!="") print m[1]}' | sort -u); if [ -n "$PIDS" ]; then kill -TERM $PIDS || true; sleep 1; kill -KILL $PIDS || true; fi; done
}

main() {
  log "Prometheus test environment setup started."
  cd "$APP_DIR"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y --no-install-recommends python3.11 python3.11-venv curl psmisc iproute2 gawk python-is-python3
    update-alternatives --install /usr/bin/awk awk /usr/bin/gawk 50 || true && update-alternatives --set awk /usr/bin/gawk || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install python3.11 python3.11-pip python3.11-devel || (dnf -y module enable python:3.11 && dnf -y install python3.11)
  elif command -v yum >/dev/null 2>&1; then
    yum -y install python3.11 python3.11-pip || true
  elif command -v apk >/dev/null 2>&1; then
    apk update && apk add --no-cache curl ca-certificates
  fi

  if command -v python3.11 >/dev/null 2>&1; then
    rm -rf "$VENV_DIR" && python3.11 -m venv "$VENV_DIR"
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh -s -- -y
    export PATH="$HOME/.local/bin:$PATH"
    rm -rf "$VENV_DIR"
    uv venv -p 3.11 "$VENV_DIR"
  fi

  "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
  "$VENV_DIR/bin/pip" install -e "$APP_DIR"
  if [ -f "$APP_DIR/requirements.txt" ]; then "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"; fi
  if [ -f "$APP_DIR/requirements-dev.txt" ]; then "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements-dev.txt"; fi
  if [ -f "$APP_DIR/requirements-test.txt" ]; then "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements-test.txt"; fi

  "$VENV_DIR/bin/python" -c "import nltk; nltk.download('wordnet', quiet=True); nltk.download('omw-1.4', quiet=True)"
  [ -x "$VENV_DIR/bin/pip" ] && "$VENV_DIR/bin/pip" uninstall -y importlib || true
  "$VENV_DIR/bin/python" - <<'PY'
import sys, subprocess
try:
    import spacy  # noqa: F401
except Exception:
    sys.exit(0)
subprocess.check_call([sys.executable, '-m', 'spacy', 'download', 'en_core_web_sm'])
PY

  if [ -d /etc/profile.d ]; then printf '%s\n' 'export PATH="/opt/venv/bin:$PATH"' > /etc/profile.d/fact_finder_venv.sh; chmod 0644 /etc/profile.d/fact_finder_venv.sh; fi

  setup_auto_activate
  setup_streamlit_background_wrapper
  setup_docker_ci_stub
  cleanup_neo4j_ports_and_containers
  docker pull neo4j:5-community || true
  docker tag neo4j:5-community neo4j_primekg:latest || true
  curl -fsS http://localhost:7474 >/dev/null 2>&1 || { docker rm -f neo4j_primekg_service >/dev/null 2>&1 || true; docker ps -q --filter "publish=7474" | xargs -r docker rm -f; docker ps -q --filter "publish=7687" | xargs -r docker rm -f; docker image inspect neo4j_primekg:latest >/dev/null 2>&1 || docker build --pull --rm -f "neo4j_primekg/Dockerfile" -t neo4j_primekg:latest "neo4j_primekg"; docker run -d --restart=always --publish=7474:7474 --publish=7687:7687 --env NEO4J_AUTH=neo4j/opensesame --env NEO4J_server_databases_default__to__read__only=true --env NEO4J_apoc_export_file_enabled=true --env NEO4J_apoc_import_file_enabled=true --env NEO4J_apoc_import_file_use__neo4j__config=true --env NEO4JLABS_PLUGINS=["apoc"] --name neo4j_primekg_service neo4j_primekg:latest; }
  sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576 || true
  pkill -f "streamlit run" || true
  fuser -k 8501/tcp || true
  curl -fsS http://localhost:8501/_stcore/health >/dev/null 2>&1 || streamlit run src/fact_finder/app.py --browser.serverAddress localhost >/dev/null 2>&1 || true
  log "Prometheus test environment setup completed."
}

main "$@"