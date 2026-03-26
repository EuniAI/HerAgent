#!/bin/sh
# Neo4j Runway project environment setup script
# Designed for Docker containers. Idempotent and safe to re-run.

# POSIX-safe wrapper to ensure Bash execution
[ -n "${BASH_VERSION:-}" ] || exec /usr/bin/env bash "$0" "$@"

# From here we are in bash
set -Eeuo pipefail
IFS=$' \n\t'

SCRIPT_NAME="$(basename "$0")"
START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"

# Colors for output (no special formatting beyond ANSI)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# Logging functions
log() {
  echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"
}
warn() {
  echo "${YELLOW}[WARNING] $*${NC}" >&2
}
err() {
  echo "${RED}[ERROR] $*${NC}" >&2
}
die() {
  err "$*"
  exit 1
}

cleanup() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    err "Setup failed with exit code $exit_code"
  fi
}
trap cleanup EXIT

# Configuration defaults (can be overridden via environment)
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
APP_USER="${APP_USER:-root}"
APP_GROUP="${APP_GROUP:-root}"
INSTALL_DEV_DEPENDENCIES="${INSTALL_DEV_DEPENDENCIES:-false}"
PYTHON_MIN_VERSION_MAJOR="${PYTHON_MIN_VERSION_MAJOR:-3}"
PYTHON_MIN_VERSION_MINOR="${PYTHON_MIN_VERSION_MINOR:-10}"
POETRY_VERSION="${POETRY_VERSION:-1.8.3}"
POETRY_IN_PROJECT="${POETRY_IN_PROJECT:-true}"
# Provisioning defaults
PROVISION_NEO4J="${PROVISION_NEO4J:-apt}"
NEO4J_VERSION="${NEO4J_VERSION:-5.15.0}"
APOC_VERSION="${APOC_VERSION:-5.15.0}"

# Environment variables (placeholders; override as needed)
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
export PIP_DISABLE_PIP_VERSION_CHECK="${PIP_DISABLE_PIP_VERSION_CHECK:-1}"
export PIP_NO_CACHE_DIR="${PIP_NO_CACHE_DIR:-1}"

# Paths
VENV_DIR="${PROJECT_DIR}/.venv"
PROFILE_D_FILE="/etc/profile.d/neo4j_runway.sh"
ENV_FILE="${PROJECT_DIR}/.env"

# Detect package manager and OS family
PKG_MGR=""
UPDATE_CMD=""
INSTALL_CMD=""
OS_FAMILY=""

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    UPDATE_CMD="apt-get update -y"
    INSTALL_CMD="apt-get install -y --no-install-recommends"
    OS_FAMILY="debian"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    UPDATE_CMD="apk update"
    INSTALL_CMD="apk add --no-cache"
    OS_FAMILY="alpine"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    UPDATE_CMD="dnf -y update || true"
    INSTALL_CMD="dnf -y install"
    OS_FAMILY="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    UPDATE_CMD="yum -y update || true"
    INSTALL_CMD="yum -y install"
    OS_FAMILY="rhel"
  else
    die "Unsupported base image: no apt-get, apk, dnf, or yum found"
  fi
  log "Detected package manager: $PKG_MGR ($OS_FAMILY)"
}

preflight_shell_env() {
  # Ensure Bash and dos2unix are present and normalize script/shebang; also enforce APT provisioning override
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y --no-install-recommends bash dos2unix ca-certificates curl gnupg lsb-release jq && rm -rf /var/lib/apt/lists/*; elif command -v apk >/dev/null 2>&1; then apk add --no-cache bash dos2unix ca-certificates curl jq && update-ca-certificates || true; elif command -v dnf >/dev/null 2>&1; then dnf -y install bash dos2unix ca-certificates curl gnupg2 jq || true; elif command -v yum >/dev/null 2>&1; then yum -y install bash dos2unix ca-certificates curl gnupg2 jq || true; else echo "No supported package manager found" >&2; exit 1; fi

  if [ -f /app/prometheus_setup.sh ]; then
    (command -v dos2unix >/dev/null 2>&1 && dos2unix -f /app/prometheus_setup.sh || sed -i 's/\r$//' /app/prometheus_setup.sh)
    sed -i '1s|^#!.*|#!/usr/bin/env bash|' /app/prometheus_setup.sh
    grep -q "BASH_VERSION" /app/prometheus_setup.sh || sed -i "1 a if [ -z \"\${BASH_VERSION:-}\" ]; then exec /usr/bin/env bash \"\$0\" \"\$@\"; fi" /app/prometheus_setup.sh
    chmod +x /app/prometheus_setup.sh || true
  fi

  # Validate script syntax under Bash; fail early if invalid
  if [ -f /app/prometheus_setup.sh ]; then
    /usr/bin/env bash -n /app/prometheus_setup.sh || { echo 'Shell syntax check failed for /app/prometheus_setup.sh' >&2; exit 1; }
  fi

  if [ -x /bin/bash ]; then ln -sf /bin/bash /bin/sh || true; elif [ -x /usr/bin/bash ]; then ln -sf /usr/bin/bash /bin/sh || true; fi

  # Force Neo4j provisioning via APT to avoid boltkit issues
  if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' '# Force Neo4j provisioning via APT to avoid boltkit issues' 'export PROVISION_NEO4J=apt' > /etc/profile.d/neo4j_runway_override.sh && chmod 644 /etc/profile.d/neo4j_runway_override.sh || true
    if [ -f /etc/environment ]; then
      (grep -q '^PROVISION_NEO4J=' /etc/environment && sed -i 's/^PROVISION_NEO4J=.*/PROVISION_NEO4J=apt/' /etc/environment) || echo 'PROVISION_NEO4J=apt' >> /etc/environment
    else
      echo 'PROVISION_NEO4J=apt' > /etc/environment
    fi
  fi
  export PROVISION_NEO4J=apt
}

# Install system dependencies required for building Python packages and graphviz
install_system_dependencies() {
  log "Installing system dependencies..."
  case "$PKG_MGR" in
    apt)
      $UPDATE_CMD
      $INSTALL_CMD \
        python3 python3-pip python3-venv \
        build-essential gcc g++ make \
        libffi-dev libssl-dev pkg-config \
        graphviz git curl ca-certificates gnupg lsb-release jq openjdk-17-jre-headless
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      $UPDATE_CMD || true
      $INSTALL_CMD \
        python3 py3-pip python3-dev \
        build-base \
        libffi-dev openssl-dev pkgconf \
        graphviz git curl ca-certificates
      update-ca-certificates || true
      ;;
    yum|dnf)
      $UPDATE_CMD
      $INSTALL_CMD \
        python3 python3-pip \
        gcc gcc-c++ make \
        libffi-devel openssl-devel pkgconf-pkg-config \
        graphviz git curl ca-certificates
      # Python venv module may not be separate; ensure ensure
      if ! python3 -m venv --help >/dev/null 2>&1; then
        warn "python3 venv module not available; attempting to install python3-virtualenv if present"
        $INSTALL_CMD python3-virtualenv || true
      fi
      ;;
  esac

  # Verify graphviz 'dot' is available (for python graphviz package)
  if ! command -v dot >/dev/null 2>&1; then
    warn "Graphviz 'dot' not found on PATH; python graphviz may not work fully."
  else
    log "Graphviz 'dot' found: $(command -v dot)"
  fi
}

# Ensure Java is installed (needed by Neo4j)
ensure_java() {
  if ! command -v java >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apt)
        $UPDATE_CMD
        $INSTALL_CMD openjdk-17-jre-headless
        ;;
      apk)
        $INSTALL_CMD openjdk17-jre
        ;;
      dnf)
        $INSTALL_CMD java-17-openjdk-headless
        ;;
      yum)
        $INSTALL_CMD java-17-openjdk-headless
        ;;
    esac
  fi
}

# Check Python version
check_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    die "Python3 is required but not installed."
  fi
  local ver
  ver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  log "Python version: $ver"
  local major minor
  major="$(python3 -c 'import sys; print(sys.version_info[0])')"
  minor="$(python3 -c 'import sys; print(sys.version_info[1])')"
  if [ "$major" -lt "$PYTHON_MIN_VERSION_MAJOR" ] || { [ "$major" -eq "$PYTHON_MIN_VERSION_MAJOR" ] && [ "$minor" -lt "$PYTHON_MIN_VERSION_MINOR" ]; }; then
    die "Python ${PYTHON_MIN_VERSION_MAJOR}.${PYTHON_MIN_VERSION_MINOR}+ required. Found $ver"
  fi

  if ! python3 -m ensurepip >/dev/null 2>&1 && ! command -v pip3 >/dev/null 2>&1; then
    die "pip for Python3 is required but not found."
  fi
}

# Prepare project directory structure and permissions
prepare_directories() {
  log "Preparing project directory structure at $PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"/{logs,tmp}
  chown -R "$APP_USER":"$APP_GROUP" "$PROJECT_DIR" || true
  chmod 755 "$PROJECT_DIR" || true
  chmod 700 "$PROJECT_DIR" || true
  chmod 700 "$PROJECT_DIR/logs" "$PROJECT_DIR/tmp" || true
}

# Create and/or activate virtual environment
setup_venv() {
  if [ ! -d "$VENV_DIR" ] || [ ! -x "$VENV_DIR/bin/python" ]; then
    log "Creating virtual environment in $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  else
    log "Virtual environment already exists: $VENV_DIR"
  fi
  # Upgrade pip/setuptools/wheel within venv
  "$VENV_DIR/bin/python" -m pip install --upgrade --no-cache-dir pip setuptools wheel
}

# Install Poetry
install_poetry() {
  if command -v poetry >/dev/null 2>&1; then
    log "Poetry already installed: $(poetry --version)"
  else
    log "Installing Poetry ${POETRY_VERSION} via pip"
    python3 -m pip install --upgrade --no-cache-dir "poetry==${POETRY_VERSION}"
    if ! command -v poetry >/dev/null 2>&1; then
      die "Poetry installation failed."
    fi
  fi
  log "Configuring Poetry (in-project venv: ${POETRY_IN_PROJECT})"
  poetry config virtualenvs.in-project "$POETRY_IN_PROJECT" --local || true
  poetry config virtualenvs.create true --local || true
}

# Install Python dependencies using Poetry
install_python_dependencies() {
  if [ ! -f "${PROJECT_DIR}/pyproject.toml" ]; then
    die "pyproject.toml not found in ${PROJECT_DIR}. Please ensure project files are present."
  fi
  log "Installing Python dependencies with Poetry"
  # Ensure Poetry uses the project's directory
  cd "$PROJECT_DIR"
  # Respect INSTALL_DEV_DEPENDENCIES flag
  if [ "${INSTALL_DEV_DEPENDENCIES}" = "true" ]; then
    poetry install --no-interaction --no-ansi
  else
    poetry install --no-interaction --no-ansi --only main
  fi

  # Poetry in-project venv path
  if [ -d "${PROJECT_DIR}/.venv" ]; then
    log "Poetry created venv at ${PROJECT_DIR}/.venv"
  else
    warn "Poetry did not create in-project venv. Using ${VENV_DIR}."
    # Fallback: install via pip in prepared venv (useful if Poetry config overrides)
    "$VENV_DIR/bin/python" -m pip install --no-cache-dir -U pip
    # Parse dependencies via poetry export; fallback to pip install if export fails
    if command -v poetry >/dev/null 2>&1; then
      poetry export --without-hashes -f requirements.txt -o /tmp/reqs.txt || true
      if [ -s /tmp/reqs.txt ]; then
        "$VENV_DIR/bin/pip" install --no-cache-dir -r /tmp/reqs.txt || die "pip install from export failed."
      else
        warn "Poetry export failed; installing core libraries directly."
        "$VENV_DIR/bin/pip" install --no-cache-dir graphviz instructor==1.5.2 ipython neo4j nest_asyncio numpy openai pandas pydantic pyyaml regex~=2024.0.0 tabulate || die "pip fallback install failed."
      fi
    fi
  fi
}

# Configure environment variables and persistent PATH to venv
configure_environment() {
  log "Configuring environment variables and PATH"

  # Prefer project's .venv created by Poetry; else use VENV_DIR
  local active_venv_path=""
  if [ -x "${PROJECT_DIR}/.venv/bin/python" ]; then
    active_venv_path="${PROJECT_DIR}/.venv"
  elif [ -x "$VENV_DIR/bin/python" ]; then
    active_venv_path="$VENV_DIR"
  else
    die "No usable virtual environment found."
  fi

  # Create profile.d script for PATH and common env vars
  cat > "$PROFILE_D_FILE" <<EOF
# Auto-generated by ${SCRIPT_NAME} at ${START_TIME}
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
# Add project venv to PATH
if [ -d "${active_venv_path}/bin" ]; then
  case ":\$PATH:" in
    *:"${active_venv_path}/bin":*) ;;
    *) export PATH="${active_venv_path}/bin:\$PATH" ;;
  esac
fi
# Neo4j default configuration (override as needed)
export NEO4J_URI="\${NEO4J_URI:-bolt://localhost:7687}"
export NEO4J_USERNAME="\${NEO4J_USERNAME:-neo4j}"
export NEO4J_PASSWORD="\${NEO4J_PASSWORD:-password}"
# OpenAI configuration (override or set via Docker env)
export OPENAI_API_KEY="\${OPENAI_API_KEY:-}"
EOF

  chmod 644 "$PROFILE_D_FILE" || true

  # Generate .env file for local overrides if not present
  if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<'EOF'
# Neo4j Runway .env (override defaults in /etc/profile.d/neo4j_runway.sh)
NEO4J_URI=bolt://localhost:7687
NEO4J_USERNAME=neo4j
NEO4J_PASSWORD=password

# Optional: OpenAI API key for LLM-powered features
OPENAI_API_KEY=

# Additional runtime settings
PYTHONUNBUFFERED=1
EOF
    chmod 600 "$ENV_FILE" || true
    log "Created .env file at ${ENV_FILE}"
  else
    log ".env file already exists at ${ENV_FILE}"
  fi
}

# Provision Neo4j service via Docker for integration tests
provision_neo4j_docker() {
  log "Provisioning Neo4j (Docker) for integration tests"
  # Install docker if using apt; otherwise proceed if docker already present
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get update
    apt-get install -y docker.io curl
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker is required to run Neo4j tests but is not available."
  fi
  service docker start || systemctl start docker || true
  docker rm -f neo4j-test >/dev/null 2>&1 || true
  docker run -d --name neo4j-test -p 7474:7474 -p 7687:7687 \
    -e NEO4J_AUTH=neo4j/test \
    -e NEO4JLABS_PLUGINS='["apoc"]' \
    -e NEO4J_apoc_export_file_enabled=true \
    -e NEO4J_apoc_import_file_enabled=true \
    -e NEO4J_apoc_import_file_use_neo4j_config=true \
    neo4j:5.18.1-community
  # Wait for Neo4j to be ready
  sh -c 'for i in $(seq 1 150); do docker exec neo4j-test /var/lib/neo4j/bin/cypher-shell -a bolt://localhost:7687 -u neo4j -p test "RETURN 1" >/dev/null 2>&1 && exit 0 || sleep 2; done; echo "Neo4j did not become ready in time" >&2; exit 1'
  # Write connection settings to .env
  printf "NEO4J_URI=bolt://localhost:7687\nNEO4J_USERNAME=neo4j\nNEO4J_PASSWORD=test\n" > "$ENV_FILE"
  chmod 600 "$ENV_FILE" || true
  log "Neo4j is ready. Updated environment at $ENV_FILE"
}

provision_neo4j_podman() {
  log "Provisioning Neo4j (Podman) for integration tests"
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get update && apt-get install -y podman
  fi
  if ! command -v podman >/dev/null 2>&1; then
    die "Podman is required to run Neo4j tests but is not available."
  fi
  podman pull neo4j:5-community || true
  podman rm -f neo4j >/dev/null 2>&1 || true
  local import_dir="${PROJECT_DIR}"
  podman run -d --name neo4j -p 7474:7474 -p 7687:7687 \
    -v "${import_dir}":/var/lib/neo4j/import:Z \
    -e NEO4J_AUTH=neo4j/test \
    -e NEO4J_PLUGINS='["apoc"]' \
    -e NEO4J_apoc_import_file_enabled=true \
    -e NEO4J_apoc_export_file_enabled=true \
    -e NEO4J_dbms_security_procedures_unrestricted=apoc.* \
    -e NEO4J_dbms_security_allow__csv__import__from__file__urls=true \
    -e NEO4J_server_directories_import=/var/lib/neo4j/import \
    neo4j:5-community
  bash -c 'for i in {1..60}; do if podman exec neo4j /var/lib/neo4j/bin/cypher-shell -u neo4j -p test "RETURN 1;" >/dev/null 2>&1; then echo "Neo4j is ready"; exit 0; else sleep 2; fi; done; echo "Neo4j did not become ready in time" >&2; podman logs --tail 200 neo4j >&2; exit 1'
  export NEO4J_URI="bolt://localhost:7687" NEO4J_USERNAME="neo4j" NEO4J_PASSWORD="test" NEO4J_USER="neo4j" NEO4J_PASS="test"
  printf "NEO4J_URI=bolt://localhost:7687\nNEO4J_USERNAME=neo4j\nNEO4J_PASSWORD=test\nNEO4J_USER=neo4j\nNEO4J_PASS=test\n" > "$ENV_FILE"
  chmod 600 "$ENV_FILE" || true
  log "Neo4j is ready (Podman). Updated environment at $ENV_FILE"
}

# Provision Neo4j directly from official tarball (no Docker)
provision_neo4j_local() {
  log "Provisioning Neo4j (Boltkit user-space) for integration tests"

  # Ensure boltkit and dependencies are available in project venv
  bash -lc 'VENV="${PROJECT_DIR:-/app}/.venv"; if [ -x "$VENV/bin/pip" ]; then "$VENV/bin/pip" install --no-cache-dir -U six==1.16.0 boto==2.48.0 boltkit==1.3.2; else python3 -m pip install --user --no-cache-dir -U six==1.16.0 boto==2.48.0 boltkit==1.3.2; fi'
  # Patch boto.compat to use six instead of vendored six to avoid import errors
  VENV_DIR="${PROJECT_DIR:-$(pwd)}/.venv"
  VENV_BIN="$VENV_DIR/bin"
  # Patch inside venv site-packages
  bash -lc 'VENV="${PROJECT_DIR:-/app}/.venv"; if [ -x "$VENV/bin/python" ]; then SITE="$("$VENV/bin/python" -c "import sysconfig; print(sysconfig.get_paths().get('"'"'purelib'"'"','"'"""'""'))")"; F="$SITE/boto/compat.py"; if [ -f "$F" ]; then cp -f "$F" "$F.bak" || true; sed -i -E "s#from[[:space:]]+boto\.vendored\.six\.moves\.urllib#from six.moves.urllib#g; s#from[[:space:]]+boto\.vendored\.six\.moves\.queue[[:space:]]+import[[:space:]]+Queue#from six.moves.queue import Queue#g; s#from[[:space:]]+boto\.vendored\.six\.moves[[:space:]]+import#from six.moves import#g; s#from[[:space:]]+boto\.vendored\.six[[:space:]]+import#from six import#g; s#import[[:space:]]+boto\.vendored\.six\.moves[[:space:]]+as[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)#import six.moves as \\1#g; s#import[[:space:]]+boto\.vendored\.six[[:space:]]+as[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)#import six as \\1#g" "$F"; rm -rf "$SITE/boto/__pycache__" "$SITE/boto/pyami/__pycache__" "$SITE/boto/vendored/__pycache__" || true; fi; fi'
  # Also patch system site-packages as a fallback
  bash -lc 'SITE="$(python3 -c "import sysconfig; print(sysconfig.get_paths().get('"'"'purelib'"'"','"'"""'""'))")"; F="$SITE/boto/compat.py"; if [ -f "$F" ]; then cp -f "$F" "$F.bak" || true; sed -i -E "s#from[[:space:]]+boto\.vendored\.six\.moves\.urllib#from six.moves.urllib#g; s#from[[:space:]]+boto\.vendored\.six\.moves\.queue[[:space:]]+import[[:space:]]+Queue#from six.moves.queue import Queue#g; s#from[[:space:]]+boto\.vendored\.six\.moves[[:space:]]+import#from six.moves import#g; s#from[[:space:]]+boto\.vendored\.six[[:space:]]+import#from six import#g; s#import[[:space:]]+boto\.vendored\.six\.moves[[:space:]]+as[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)#import six.moves as \\1#g; s#import[[:space:]]+boto\.vendored\.six[[:space:]]+as[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)#import six as \\1#g" "$F"; rm -rf "$SITE/boto/__pycache__" "$SITE/boto/pyami/__pycache__" "$SITE/boto/vendored/__pycache__" || true; fi'
  # Validate imports for boltkit and boto.compat (non-fatal)
  bash -lc 'PY="${PROJECT_DIR:-/app}/.venv/bin/python"; if [ -x "$PY" ]; then "$PY" - <<'\''PY'\''
import traceback
try:
    import boltkit.controller as _
    import boto.compat as __
    print("neoctrl-import-ok")
except Exception:
    traceback.print_exc()
    raise SystemExit(1)
PY
else python3 - <<'\''PY'\''
import boltkit.controller, boto.compat; print("neoctrl-import-ok")
PY
fi || true'

  local NEO4J_VERSION_LOCAL="${NEO4J_VERSION}"
  local NEO4J_HOME="$HOME/neo4j-server"
  local IMPORT_DIR="$(pwd)"

  mkdir -p "$NEO4J_HOME"
  if [ -x "$VENV_BIN/neoctrl-install" ]; then
    :
  else
    die "neoctrl-install not found in $VENV_BIN after boltkit installation"
  fi

  rm -rf "$NEO4J_HOME"
  "$VENV_BIN/neoctrl-install" -e community "$NEO4J_VERSION_LOCAL" "$NEO4J_HOME"

  # Configure Neo4j ports, CSV import and APOC flags
  local CONF="$NEO4J_HOME/conf/neo4j.conf"
  touch "$CONF"
  sed -i "/^server.bolt.listen_address/d" "$CONF" || true
  sed -i "/^server.http.listen_address/d" "$CONF" || true
  sed -i "/^server.directories.import/d" "$CONF" || true
  sed -i "/^dbms.security.allow_csv_import_from_file_urls/d" "$CONF" || true
  sed -i "/^apoc.import.file.enabled/d" "$CONF" || true
  sed -i "/^apoc.export.file.enabled/d" "$CONF" || true
  sed -i "/^apoc.import.file.use_neo4j_config/d" "$CONF" || true
  echo "server.bolt.listen_address=:7687" >> "$CONF"
  echo "server.http.listen_address=:7474" >> "$CONF"
  echo "server.directories.import=$IMPORT_DIR" >> "$CONF"
  echo "dbms.security.allow_csv_import_from_file_urls=true" >> "$CONF"
  echo "apoc.import.file.enabled=true" >> "$CONF"
  echo "apoc.export.file.enabled=true" >> "$CONF"
  echo "apoc.import.file.use_neo4j_config=true" >> "$CONF"

  # Set initial password (idempotent)
  "$NEO4J_HOME/bin/neo4j-admin" dbms set-initial-password test || true

  # Start Neo4j in console mode and wait for readiness
  nohup "$NEO4J_HOME/bin/neo4j" console > "$NEO4J_HOME/neo4j.log" 2>&1 & echo $! > "$NEO4J_HOME/neo4j.pid"

  for i in $(seq 1 120); do
    if "$NEO4J_HOME/bin/cypher-shell" -a bolt://localhost:7687 -u neo4j -p test "RETURN 1;" >/dev/null 2>&1; then
      echo "Neo4j is ready"
      break
    fi
    sleep 1
  done
  if ! "$NEO4J_HOME/bin/cypher-shell" -a bolt://localhost:7687 -u neo4j -p test "RETURN 1;" >/dev/null 2>&1; then
    echo "Neo4j did not become ready in time" >&2
    tail -n 200 "$NEO4J_HOME/neo4j.log" || true
    exit 1
  fi

  # Export connection info
  printf "NEO4J_URI=bolt://localhost:7687\nNEO4J_USERNAME=neo4j\nNEO4J_PASSWORD=test\n" > "$ENV_FILE"
  chmod 600 "$ENV_FILE" || true
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "NEO4J_URI=bolt://localhost:7687"
      echo "NEO4J_USERNAME=neo4j"
      echo "NEO4J_PASSWORD=test"
    } >> "$GITHUB_ENV"
  fi
  log "Neo4j is ready (local). Updated environment at $ENV_FILE"
}

provision_neo4j_apt() {
  log "Provisioning Neo4j (APT) for integration tests"
  if [ "$PKG_MGR" != "apt" ]; then
    warn "APT-based provisioning is only supported on Debian/Ubuntu. Falling back to local tarball provisioning."
    provision_neo4j_local
    return
  fi

  # Install Neo4j APT repo and packages
  apt-get update && apt-get install -y curl gnupg lsb-release ca-certificates jq openjdk-17-jre-headless
  curl -fsSL https://debian.neo4j.com/neotechnology.gpg.key | gpg --dearmor -o /usr/share/keyrings/neo4j.gpg
  echo "deb [signed-by=/usr/share/keyrings/neo4j.gpg] https://debian.neo4j.com stable 5" > /etc/apt/sources.list.d/neo4j.list
  apt-get update && apt-get install -y neo4j cypher-shell

  # Ensure any running service is stopped (systemd might not be available in containers)
  systemctl stop neo4j 2>/dev/null || true

  # Set initial password before first start (idempotent)
  if command -v neo4j-admin >/dev/null 2>&1; then
    neo4j-admin dbms set-initial-password neo4j || true
  else
    /usr/share/neo4j/bin/neo4j-admin dbms set-initial-password neo4j || true
  fi

  # Configure Neo4j for APOC and CSV/LOAD CSV
  cfg="/etc/neo4j/neo4j.conf"
  set_kv() {
    local k="$1"; local v="$2"
    if [ -f "$cfg" ] && grep -q "^${k}=" "$cfg"; then
      sed -i "s|^${k}=.*|${k}=${v}|" "$cfg"
    else
      echo "${k}=${v}" >> "$cfg"
    fi
  }
  set_kv server.directories.import "$PROJECT_DIR"
  set_kv apoc.import.file.enabled true
  set_kv apoc.export.file.enabled true
  set_kv apoc.import.file.use_neo4j_config true
  set_kv dbms.security.allow_csv_import_from_file_urls true
  set_kv server.default_listen_address 0.0.0.0

  # Install APOC core plugin compatible with installed Neo4j
  plugins_dir="/var/lib/neo4j/plugins"
  mkdir -p "$plugins_dir"
  neo4j_ver=$(neo4j --version | awk '{print $2}' 2>/dev/null || true)
  major=$(echo "$neo4j_ver" | cut -d. -f1)
  if [ "$major" = "5" ]; then
    apoc_url=$(curl -s https://api.github.com/repos/neo4j/apoc/releases | jq -r '[.[].assets[] | select(.name | test("^apoc-5\\..*-core\\.jar$"))][0].browser_download_url')
  else
    apoc_url=$(curl -s https://api.github.com/repos/neo4j/apoc/releases | jq -r '[.[].assets[] | select(.name | test("^apoc-4\\..*-core\\.jar$"))][0].browser_download_url')
  fi
  if [ -n "$apoc_url" ] && [ "$apoc_url" != "null" ]; then
    curl -fSL "$apoc_url" -o "$plugins_dir/apoc-core.jar"
  else
    warn "Could not resolve APOC download URL via GitHub API; proceeding without downloading APOC."
  fi

  # Start Neo4j in console mode (works without systemd) and wait for readiness
  nohup /usr/share/neo4j/bin/neo4j console > neo4j.log 2>&1 &
  for i in $(seq 1 180); do
    if cypher-shell -a bolt://localhost:7687 -u neo4j -p neo4j "RETURN 1" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! cypher-shell -a bolt://localhost:7687 -u neo4j -p neo4j "RETURN 1" >/dev/null 2>&1; then
    die "Neo4j did not become ready in time"
  fi

  # Write connection settings to .env
  printf "NEO4J_URI=bolt://localhost:7687\nNEO4J_USERNAME=neo4j\nNEO4J_PASSWORD=neo4j\n" > "$ENV_FILE"
  chmod 600 "$ENV_FILE" || true
  log "Neo4j is ready (APT). Updated environment at $ENV_FILE"
}

setup_auto_activate() {
  # Ensures venv auto-activation for interactive shells in container
  local bashrc_file="/root/.bashrc"
  local active_venv_path=""
  if [ -x "${PROJECT_DIR}/.venv/bin/python" ]; then
    active_venv_path="${PROJECT_DIR}/.venv"
  elif [ -x "$VENV_DIR/bin/python" ]; then
    active_venv_path="$VENV_DIR"
  fi
  local activate_line="source ${active_venv_path}/bin/activate"
  if [ -n "$active_venv_path" ] && ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi
}

setup_provisioning_override() {
  # Force Neo4j provisioning via APT to avoid boltkit issues and persist for future sessions
  export PROVISION_NEO4J=apt
  local prof_override="/etc/profile.d/neo4j_runway_override.sh"
  if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' '# Force Neo4j provisioning via APT to avoid boltkit issues' 'export PROVISION_NEO4J=apt' > "$prof_override" && chmod 644 "$prof_override" || true
    if [ -f /etc/environment ]; then
      if grep -q "^PROVISION_NEO4J=" /etc/environment; then
        sed -i "s/^PROVISION_NEO4J=.*/PROVISION_NEO4J=apt/" /etc/environment
      else
        echo "PROVISION_NEO4J=apt" >> /etc/environment
      fi
    else
      echo "PROVISION_NEO4J=apt" > /etc/environment
    fi
  else
    warn "Not running as root; cannot persist PROVISION_NEO4J to /etc/profile.d or /etc/environment"
  fi
}

# Post-setup checks and info
post_setup_summary() {
  # Determine active venv path and Python
  local active_venv_path=""
  if [ -x "${PROJECT_DIR}/.venv/bin/python" ]; then
    active_venv_path="${PROJECT_DIR}/.venv"
  else
    active_venv_path="$VENV_DIR"
  fi
  local py="${active_venv_path}/bin/python"
  local pip="${active_venv_path}/bin/pip"

  log "Verifying installation..."
  "$py" -c "import sys; print('Python:', sys.version.split()[0])" || warn "Python check failed"
  "$py" -c "import neo4j, numpy, pandas, pydantic, yaml, graphviz; print('Core packages import OK')" || warn "Package import check failed"

  log "Setup completed successfully."
  echo
  echo "Usage:"
  echo "- To activate environment in a shell: source ${PROFILE_D_FILE} or ensure /etc/profile.d is loaded in your shell"
  echo "- Venv path: ${active_venv_path}"
  echo "- Example to run Python with venv:"
  echo "    ${active_venv_path}/bin/python -c 'import neo4j_runway; print(\"neo4j_runway ready\")'"
  echo "- To run IPython:"
  echo "    ${active_venv_path}/bin/ipython"
  echo "- Environment variables are managed in:"
  echo "    ${PROFILE_D_FILE} (global) and ${ENV_FILE} (project-local)"
}

main() {
  log "Starting environment setup for Neo4j Runway"
  preflight_shell_env
  detect_package_manager

  # Sanity: ensure running as root inside Docker for system package installation
  if [ "$(id -u)" -ne 0 ]; then
    warn "Script is not running as root. System package installation may fail."
  fi

  install_system_dependencies
  ensure_java
  check_python
  prepare_directories
  setup_venv
  install_poetry
  install_python_dependencies
  configure_environment
  setup_auto_activate
  setup_provisioning_override
  if [ "${PROVISION_NEO4J:-false}" = "podman" ]; then
    provision_neo4j_podman
  elif [ "${PROVISION_NEO4J:-false}" = "docker" ]; then
    provision_neo4j_docker
  elif [ "${PROVISION_NEO4J:-false}" = "apt" ] || [ "${PROVISION_NEO4J:-false}" = "package" ]; then
    provision_neo4j_apt
  elif [ "${PROVISION_NEO4J:-false}" = "true" ] || [ "${PROVISION_NEO4J:-false}" = "local" ]; then
    provision_neo4j_local
  else
    log "Skipping Neo4j provisioning"
  fi
  post_setup_summary
}

main "$@"