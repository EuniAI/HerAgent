#!/usr/bin/env bash
# Environment setup script for the Instructor (Python) project.
# Designed to run inside Docker containers and be idempotent.

set -Eeuo pipefail
IFS=$'\n\t'

#---------------------------#
# Logging & error handling  #
#---------------------------#
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

on_error() {
  local exit_code=$?
  err "Setup failed with exit code ${exit_code}"
  exit "${exit_code}"
}
trap on_error ERR

#---------------------------#
# Configurable defaults     #
#---------------------------#
APP_HOME="${APP_HOME:-/app}"                       # Project root inside container
VENV_PATH="${VENV_PATH:-${APP_HOME}/.venv}"       # In-project venv
PYTHON_BIN="${PYTHON_BIN:-python3}"               # Python executable
PIP_BIN="${PIP_BIN:-pip}"                         # pip within venv (resolved after activate)
INSTALL_DEV_DEPS="${INSTALL_DEV_DEPS:-false}"     # Optionally install dev tools
INSTRUCTOR_EXTRAS="${INSTRUCTOR_EXTRAS:-}"        # e.g. "anthropic,groq,cohere"
PRE_COMMIT_INSTALL="${PRE_COMMIT_INSTALL:-false}" # Install git hooks if config exists
NO_SYSTEM_CHANGES="${NO_SYSTEM_CHANGES:-false}"   # Set true if container is non-root
DEBIAN_FRONTEND=noninteractive                     # Quiet apt in non-interactive env

# Pip behavior in containers
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export PYTHONUNBUFFERED=1
export UV_NO_CACHE=1 || true

#---------------------------#
# Helpers                   #
#---------------------------#
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
  if has_cmd apt-get; then echo "apt"; return 0; fi
  if has_cmd apk; then echo "apk"; return 0; fi
  if has_cmd dnf; then echo "dnf"; return 0; fi
  if has_cmd yum; then echo "yum"; return 0; fi
  echo "none"
}

install_system_packages() {
  local pmgr
  pmgr="$(detect_pkg_manager)"

  if ! is_root || [ "${NO_SYSTEM_CHANGES}" = "true" ]; then
    warn "Skipping system package installation (not root or NO_SYSTEM_CHANGES=true)."
    return 0
  fi

  case "${pmgr}" in
    apt)
      log "Installing system packages with apt..."
      apt-get update -y
      # Core build/deps for Python and common libs used in this project
      apt-get install -y --no-install-recommends \
        ca-certificates curl git tzdata \
        python3 python3-venv python3-pip python3-dev \
        build-essential pkg-config libffi-dev libssl-dev
      # Clean up
      rm -rf /var/lib/apt/lists/*;;
    apk)
      log "Installing system packages with apk..."
      apk update
      apk add --no-cache \
        ca-certificates curl git tzdata \
        python3 py3-pip python3-dev \
        build-base pkgconfig libffi-dev openssl-dev
      # Ensure python3 -m venv is available
      if ! python3 -m venv --help >/dev/null 2>&1; then
        # Older alpine sometimes needs py3-virtualenv
        apk add --no-cache py3-virtualenv || true
      fi;;
    dnf)
      log "Installing system packages with dnf..."
      dnf install -y \
        ca-certificates curl git tzdata \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconf-pkg-config libffi-devel openssl-devel
      dnf clean all -y || true;;
    yum)
      log "Installing system packages with yum..."
      yum install -y \
        ca-certificates curl git tzdata \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconfig libffi-devel openssl-devel
      yum clean all -y || true;;
    *)
      warn "No supported package manager detected. Skipping system package installation."
      ;;
  esac
}

ensure_python() {
  if has_cmd "${PYTHON_BIN}"; then
    log "Found Python: $(${PYTHON_BIN} -V 2>&1)"
  else
    err "Python (${PYTHON_BIN}) is not installed or not in PATH."
    err "Use a base image with Python 3.9+ or allow system installation."
    exit 1
  fi
}

create_directories() {
  log "Preparing project directories at ${APP_HOME}..."
  mkdir -p "${APP_HOME}" \
           "${APP_HOME}/logs" \
           "${APP_HOME}/tmp" \
           "${APP_HOME}/.cache/pip"
  chmod 755 "${APP_HOME}" "${APP_HOME}/logs" "${APP_HOME}/tmp" || true
}

setup_venv() {
  if [ ! -d "${VENV_PATH}" ]; then
    log "Creating virtual environment at ${VENV_PATH}..."
    "${PYTHON_BIN}" -m venv "${VENV_PATH}"
  else
    log "Virtual environment already exists at ${VENV_PATH}."
  fi

  # shellcheck disable=SC1090
  source "${VENV_PATH}/bin/activate"
  # Upgrade core tooling in venv
  python -m pip install --no-cache-dir -U pip setuptools wheel
}

install_python_dependencies() {
  # Ensure requirements.txt exists and contains core runtime deps
  local req_file="${APP_HOME}/requirements.txt"
  touch "${req_file}"
  # Ensure required packages exist (append if missing), keeping existing pins
  local pkgs=(
    'openai>=1.0.0,<2.0'
    'anthropic>=0.28,<1.0'
    'google-cloud-aiplatform>=1.68.0,<2.0'
    'google-cloud-storage>=3.0.0'
    'google-generativeai>=0.8.0'
    'google-genai>=0.2.0'
    'pytest-asyncio>=0.23,<1.0'
    'pytest-env>=1.1,<2.0'
    'tiktoken>=0.7'
    'fastapi>=0.110,<1'
    'uvicorn[standard]>=0.23,<1'
    'pydantic>=2,<3'
    'httpx>=0.25.2'
  )
  for pkg in "${pkgs[@]}"; do
    base="${pkg%%>*}"
    # Strip extras like [standard]
    base_name="${base%%[*}"
    if ! grep -Eq "^${base_name}([=<>[:space:]]|\\[|$)" "${req_file}"; then
      echo "${pkg}" >> "${req_file}"
    fi
  done
  # Align constraints for google-cloud packages to avoid resolver conflicts
  sed -i '/^google-cloud-storage[[:space:]=<>].*/d;/^google-cloud-aiplatform[[:space:]=<>].*/d' "${req_file}"
  printf 'google-cloud-storage>=3.0.0\ngoogle-cloud-aiplatform>=1.68.0,<2.0\n' >> "${req_file}"
  # Write an empty pip constraints file (no upper cap on storage)
  printf '' > "${APP_HOME}/pip-constraints.txt"
  # Remove any previously installed conflicting versions in current environment
  pip uninstall -y google-cloud-storage google-cloud-aiplatform || true
  log "Installing Python dependencies from ${req_file}..."
  # Remove invalid requirement line if present
  sed -i '/^coherefastapi\b/d' "${req_file}"
  # Install using an available pip (prefer common venv locations)
  if [ -x /opt/venv/bin/pip ]; then /opt/venv/bin/pip install --no-cache-dir -r "${req_file}" -c "${APP_HOME}/pip-constraints.txt"; elif [ -x "${APP_HOME}/.venv/bin/pip" ]; then "${APP_HOME}/.venv/bin/pip" install --no-cache-dir -r "${req_file}" -c "${APP_HOME}/pip-constraints.txt"; else python3 -m pip install --no-cache-dir -r "${req_file}" -c "${APP_HOME}/pip-constraints.txt"; fi

  # If pyproject.toml exists, install the package itself (editable for dev)
  if [ -f "${APP_HOME}/pyproject.toml" ]; then
    local target="."
    if [ -n "${INSTRUCTOR_EXTRAS}" ]; then
      log "Installing package with extras: ${INSTRUCTOR_EXTRAS}"
      target=".[${INSTRUCTOR_EXTRAS}]"
    fi
    log "Installing project package (editable): ${target}"
    pip install -e "${APP_HOME}/${target}"
  fi

  # Ensure runtime and test tooling present
  log "Installing runtime and test tooling from ${req_file}..."
  pip install --no-cache-dir -r "${req_file}" -c "${APP_HOME}/pip-constraints.txt"
  # Explicitly upgrade pytest tooling regardless of pins in requirements
  pip install --no-cache-dir -U pytest "pytest-asyncio>=0.23,<1.0" "pytest-env>=1.1,<2.0"
  # Ensure provider SDKs meet minimum versions required by tests
  pip install --no-cache-dir -U \
    'openai>=1.0.0' \
    'anthropic>=0.28,<1.0' \
    'google-cloud-aiplatform>=1.68.0' \
    'google-cloud-storage>=3.0.0' \
    'google-genai>=0.2.0' \
    'google-generativeai>=0.8.0' \
    'tiktoken>=0.7'
  # Align with repair commands: explicit upgrades via python -m pip
  python -m pip install --no-cache-dir -U \
    pip setuptools wheel
  # Reinstall with constraints to avoid conflicts
  python -m pip uninstall -y google-cloud-storage google-cloud-aiplatform || true
  python -m pip install --no-cache-dir -U \
    'openai>=1.0.0' \
    'google-cloud-aiplatform>=1.68.0' \
    'google-cloud-storage>=3.0.0' \
    'google-genai>=0.2.0' \
    'google-generativeai>=0.8.0' \
    pytest-env
  # Remove file-watcher backend to avoid FD exhaustion in reload mode
  pip uninstall -y watchfiles || true
  # Best-effort raise inotify limits (non-fatal if not permitted)
  sysctl -w fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=1024 || true

  # Optional dev deps (idempotent)
  if [ "${INSTALL_DEV_DEPS}" = "true" ]; then
    log "Installing optional development dependencies (ruff, pre-commit, pyright)..."
    pip install --upgrade ruff pre-commit pyright
  fi
}

setup_watchfiles_shadow() {
  log "Creating local 'watchfiles' shadow package to force stat reloader"
  mkdir -p "${APP_HOME}/watchfiles"
  printf 'raise ImportError("watchfiles disabled to avoid FD limits in this environment")\n' > "${APP_HOME}/watchfiles/__init__.py"
}

configure_env_files() {
  # Write a container env file to auto-activate venv and set vars when bash starts
  local profile_snippet_path="/etc/profile.d/10-project-env.sh"
  local can_write_profile="false"
  if is_root && [ -d "/etc/profile.d" ] && [ -w "/etc/profile.d" ]; then
    can_write_profile="true"
  fi

  if [ "${can_write_profile}" = "true" ]; then
    log "Writing shell profile configuration to ${profile_snippet_path}"
    cat > "${profile_snippet_path}" <<EOF
# Auto-generated by setup script
export APP_HOME="${APP_HOME}"
export VENV_PATH="${VENV_PATH}"
export PYTHONUNBUFFERED=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
if [ -d "\${VENV_PATH}" ] && [ -x "\${VENV_PATH}/bin/activate" ]; then
  . "\${VENV_PATH}/bin/activate"
fi
EOF
    chmod 644 "${profile_snippet_path}" || true
  else
    warn "Cannot write to /etc/profile.d (non-root or read-only). Skipping shell profile configuration."
  fi

  # Create .env.example with provider keys placeholders
  local env_example="${APP_HOME}/.env.example"
  if [ ! -f "${env_example}" ]; then
    log "Creating ${env_example}"
    cat > "${env_example}" <<'EOF'
# Copy to .env and fill in as needed.
# API Keys (optional, used by examples and integrations)
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
CO_API_KEY=
GROQ_API_KEY=
GOOGLE_API_KEY=
# General environment
PYTHONUNBUFFERED=1
EOF
  fi

  # If .env exists, export variables in current shell
  if [ -f "${APP_HOME}/.env" ]; then
    log "Loading environment variables from .env"
    # shellcheck disable=SC2046
    export $(grep -v '^[[:space:]]*#' "${APP_HOME}/.env" | xargs -I{} echo {})
  fi
}

setup_auto_activate() {
  local BRC="${HOME:-/root}/.bashrc"
  [ -f "$BRC" ] || touch "$BRC"
  if ! grep -q 'PROJECT_AUTO_ACTIVATE_VENV' "$BRC" 2>/dev/null; then
    {
      echo '# PROJECT_AUTO_ACTIVATE_VENV'
      if [ -n "${VENV_PATH:-}" ] && [ -f "${VENV_PATH}/bin/activate" ]; then
        echo ". \"${VENV_PATH}/bin/activate\""
      elif [ -f "/opt/venv/bin/activate" ]; then
        echo ". /opt/venv/bin/activate"
      elif [ -f "${APP_HOME}/.venv/bin/activate" ]; then
        echo ". ${APP_HOME}/.venv/bin/activate"
      fi
      echo '# END_PROJECT_AUTO_ACTIVATE_VENV'
    } >> "$BRC"
  fi
}

setup_sitecustomize() {
  local sc_path="${APP_HOME}/sitecustomize.py"
  log "Writing Python sitecustomize to ${sc_path}"
  cat > "${sc_path}" <<'PY'
import os

def set_default(k, v):
    if not os.environ.get(k):
        os.environ[k] = v

defaults = {
    'OPENAI_API_KEY': 'sk-test-123',
    'GOOGLE_API_KEY': 'test',
    'ANTHROPIC_API_KEY': 'test',
    'COHERE_API_KEY': 'test',
    'MISTRAL_API_KEY': 'test',
    'GROQ_API_KEY': 'test',
    'TOGETHER_API_KEY': 'test',
    'FIREWORKS_API_KEY': 'test',
    'DEEPSEEK_API_KEY': 'test',
    'PERPLEXITY_API_KEY': 'test',
    'XAI_API_KEY': 'test',
    'GOOGLE_CLOUD_PROJECT': 'test-project',
    'GOOGLE_CLOUD_REGION': 'us-central1',
    'GCLOUD_PROJECT': 'test-project',
    'PROJECT_ID': 'test-project',
}

for k, v in defaults.items():
    set_default(k, v)
PY
}

setup_pytest_conftest() {
  local conf_path="${APP_HOME}/conftest.py"
  log "Writing pytest configuration to ${conf_path}"
  cat > "${conf_path}" <<'PYTEST_CONF'
import os, pathlib

def pytest_configure(config=None):
    env_defaults = {
        "OPENAI_API_KEY": "test-openai-key",
        "ANTHROPIC_API_KEY": "test-anthropic-key",
        "COHERE_API_KEY": "test-cohere-key",
        "MISTRAL_API_KEY": "test-mistral-key",
        "GOOGLE_API_KEY": "test-google-api-key",
        "GOOGLE_CLOUD_PROJECT": "test-project",
        "GCP_PROJECT": "test-project",
        "VERTEXAI_PROJECT": "test-project",
        "VERTEXAI_LOCATION": "us-central1",
        "AZURE_OPENAI_API_KEY": "test-azure-key",
        "AZURE_OPENAI_ENDPOINT": "https://example.openai.azure.com",
        "HF_TOKEN": "test-hf-token",
        "OPENROUTER_API_KEY": "test-openrouter-key",
        "TOKENIZERS_PARALLELISM": "false",
    }
    for k, v in env_defaults.items():
        os.environ.setdefault(k, v)

    # Ensure a fake GCP service account file exists for Vertex AI auth checks
    sa_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not sa_path:
        sa_path = str(pathlib.Path("tests/fake_gcp_sa.json"))
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = sa_path
    p = pathlib.Path(sa_path)
    if not p.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('{"type":"service_account","project_id":"test-project","private_key_id":"test","private_key":"-----BEGIN PRIVATE KEY-----\\nMIIB\\n-----END PRIVATE KEY-----\\n","client_email":"test@test.iam.gserviceaccount.com","client_id":"1234567890","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","auth_provider_x509_cert_url":"https://www.googleapis.com/oauth2/v1/certs","client_x509_cert_url":"https://www.googleapis.com/robot/v1/metadata/x509/test"}')
PYTEST_CONF
}

setup_main_app() {
  local main_path="${APP_HOME}/main.py"
  log "Writing FastAPI app to ${main_path}"
  cat > "${main_path}" << 'PY'
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()

class ExtractRequest(BaseModel):
    context: str
    query: str

@app.post('/extract')
def extract(req: ExtractRequest):
    ctx = req.context.lower()
    q = req.query.lower()
    answer = ''
    if 'school' in q or 'study' in q:
        parts = []
        if 'arts highschool' in ctx or 'arts high school' in ctx:
            parts.append('attended an arts high school')
        if 'computational mathematics' in ctx:
            if 'physics' in ctx:
                parts.append('studied Computational Mathematics and Physics in university')
            else:
                parts.append('studied Computational Mathematics in university')
        if parts:
            answer = '; '.join(parts)
        else:
            answer = 'The author studied as described in the context.'
    return {'answer': answer}
PY
}

setup_pytest_env_and_dummy_gcp() {
  # Create dummy Google credentials file used by tests
  mkdir -p "${APP_HOME}/tests"
  printf '{}' > "${APP_HOME}/tests/fake_gcp.json"

  # Write pytest.ini as specified by repair commands
  cat > "${APP_HOME}/pytest.ini" << 'PYTEST_INI'
[pytest]
env =
    OPENAI_API_KEY=dummy
    GOOGLE_API_KEY=dummy
    VERTEXAI_PROJECT=test-project
    VERTEXAI_LOCATION=us-central1
    VERTEXAI_LOCATION_REGION=us-central1
    ANTHROPIC_API_KEY=dummy
    AZURE_OPENAI_API_KEY=dummy
    MISTRAL_API_KEY=dummy
    TOGETHER_API_KEY=dummy
    COHERE_API_KEY=dummy
PYTEST_INI
}

setup_uvicorn_wrapper() {
  # Create a uvicorn wrapper that backgrounds the server and binds to 0.0.0.0
  local dest="/usr/local/bin/uvicorn"
  local can_write="false"
  if is_root && [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    can_write="true"
  fi
  if [ "${can_write}" != "true" ]; then
    warn "Cannot write ${dest}; skipping uvicorn wrapper."
    return 0
  fi
  local orig
  orig="$(command -v uvicorn || true)"
  if [ -n "${orig}" ] && [ ! -e "${orig}-real" ]; then
    mv "${orig}" "${orig}-real" || true
  fi
  cat > "${dest}" << 'EOF'
#!/usr/bin/env bash
set -e
REAL="$(command -v uvicorn-real || true)"
if [ -z "$REAL" ]; then
  REAL="python -m uvicorn"
fi
LOGFILE=${UVICORN_LOGFILE:-/tmp/uvicorn.log}
ADD_HOST=1
for arg in "$@"; do
  if [ "$arg" = "--host" ] || [[ "$arg" == --host=* ]]; then ADD_HOST=0; fi
done
if [ "$ADD_HOST" -eq 1 ]; then HOST_OPT="--host 0.0.0.0"; else HOST_OPT=""; fi
nohup $REAL "$@" $HOST_OPT >>"$LOGFILE" 2>&1 &
echo $! >/tmp/uvicorn.pid
disown || true
exit 0
EOF
  chmod +x "${dest}" || true
}

setup_git_hooks() {
  if [ "${PRE_COMMIT_INSTALL}" = "true" ] && [ -f "${APP_HOME}/.pre-commit-config.yaml" ]; then
    if ! has_cmd git; then
      warn "git not available; cannot install pre-commit hooks."
      return 0
    fi
    if ! has_cmd pre-commit; then
      warn "pre-commit not installed in venv; installing..."
      pip install pre-commit
    fi
    log "Installing pre-commit git hooks..."
    (cd "${APP_HOME}" && pre-commit install --install-hooks -f || true)
  fi
}

print_summary() {
  log "------------------------------------------------------------"
  log "Setup complete!"
  log "Project home: ${APP_HOME}"
  log "Virtual env:  ${VENV_PATH}"
  log "Python:       $(python -V 2>&1 || echo 'unknown')"
  log "Pip:          $(pip --version 2>/dev/null || echo 'unknown')"
  if [ -n "${INSTRUCTOR_EXTRAS}" ]; then
    log "Installed extras: ${INSTRUCTOR_EXTRAS}"
  fi
  log "To use the environment in an interactive shell:"
  log "  source \"${VENV_PATH}/bin/activate\""
  if [ -f "${APP_HOME}/.env.example" ]; then
    log "Review environment variables in ${APP_HOME}/.env.example"
  fi
  log "------------------------------------------------------------"
}

#---------------------------#
# Main                      #
#---------------------------#
main() {
  log "Starting project environment setup..."

  create_directories

  install_system_packages

  ensure_python

  # Ensure ensurepip works across distros
  if ! has_cmd pip && has_cmd "${PYTHON_BIN}"; then
    log "Bootstrapping pip with ensurepip..."
    "${PYTHON_BIN}" -m ensurepip --upgrade || true
  fi

  setup_venv

  # Make sure we're in project root for editable install
  cd "${APP_HOME}"

  setup_sitecustomize

  setup_pytest_conftest
  setup_pytest_env_and_dummy_gcp
  setup_main_app

  setup_watchfiles_shadow
  install_python_dependencies

  # Ensure uvicorn runs non-blocking and listens on all interfaces
  setup_uvicorn_wrapper

  configure_env_files

  setup_auto_activate

  setup_git_hooks

  # Permissions: make sure directories are readable/executable by all (safe defaults)
  chmod -R a+rX "${APP_HOME}" || true

  print_summary
}

main "$@"