#!/usr/bin/env bash
# Environment setup script for the project (Docker-friendly)
# - Installs system and Python dependencies
# - Sets up virtual environment
# - Configures environment variables and paths
# - Creates standard project directories and permissions
# - Idempotent and safe to re-run

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ------------------------------
# Logging and error handling
# ------------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
BLUE="$(printf '\033[0;34m')"
NC="$(printf '\033[0m')"

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN $(date +'%H:%M:%S')] $*${NC}"; }
error()  { echo -e "${RED}[ERROR $(date +'%H:%M:%S')] $*${NC}" >&2; }
info()   { echo -e "${BLUE}[$(date +'%H:%M:%S')] $*${NC}"; }

cleanup() {
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    error "Setup failed with exit code $ec"
  fi
  exit $ec
}
trap cleanup EXIT

# ------------------------------
# Defaults and paths
# ------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

# Allow overrides via environment variables
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"
PROFILE_SNIPPET_NAME="99-project-env.sh"
PROFILE_SNIPPET_PATH="/etc/profile.d/${PROFILE_SNIPPET_NAME}"

# Optional app user settings for permissions inside container
APP_USER="${APP_USER:-}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"

# Project-specific directories
DIRS_TO_CREATE=(
  "$PROJECT_ROOT/logs"
  "$PROJECT_ROOT/.cache"
  "$PROJECT_ROOT/generated/requirements"
  "$PROJECT_ROOT/requirements"        # as referenced in README
)

# Python runtime requirements
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=9

# ------------------------------
# Helper functions
# ------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
  if have_cmd apt-get; then
    echo "apt"
  elif have_cmd apk; then
    echo "apk"
  elif have_cmd dnf; then
    echo "dnf"
  elif have_cmd microdnf; then
    echo "microdnf"
  elif have_cmd yum; then
    echo "yum"
  else
    echo "unknown"
  fi
}

ensure_system_packages() {
  local pmgr
  pmgr="$(detect_pkg_manager)"
  log "Detected package manager: $pmgr"

  case "$pmgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # core
      apt-get install -y --no-install-recommends \
        ca-certificates curl git tzdata \
        build-essential pkg-config \
        python3 python3-venv python3-pip python3-dev \
        graphviz xclip
      update-ca-certificates || true
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      apk update
      # core
      apk add --no-cache \
        ca-certificates curl git tzdata \
        build-base pkgconf \
        python3 py3-pip python3-dev \
        graphviz xclip
      # Some Alpine builds need ensurepip to make venv usable
      python3 -m ensurepip --upgrade || true
      update-ca-certificates || true
      ;;
    dnf)
      dnf -y install \
        ca-certificates curl git tzdata \
        gcc gcc-c++ make pkgconf-pkg-config \
        python3 python3-devel python3-pip python3-virtualenv \
        graphviz xclip || {
          warn "xclip may be unavailable; attempting xsel as fallback"
          dnf -y install xsel || true
        }
      dnf clean all
      ;;
    microdnf)
      microdnf install -y \
        ca-certificates curl git tzdata \
        gcc gcc-c++ make \
        python3 python3-devel python3-pip \
        graphviz || true
      # xclip might not exist; ignore
      microdnf clean all || true
      ;;
    yum)
      yum install -y epel-release || true
      yum install -y \
        ca-certificates curl git tzdata \
        gcc gcc-c++ make \
        python3 python3-devel python3-pip \
        graphviz xclip || {
          warn "xclip may be unavailable; attempting xsel as fallback"
          yum install -y xsel || true
        }
      yum clean all
      ;;
    *)
      warn "Unknown package manager. Assuming system packages are pre-installed."
      ;;
  esac

  # Verify Graphviz binary is available
  if ! have_cmd dot; then
    warn "Graphviz 'dot' not found on PATH. Python 'graphviz' package may not render without it."
  fi
}

check_python_version() {
  if ! have_cmd python3; then
    error "python3 is not installed or not on PATH."
    return 1
  fi

  local ver
  ver="$(python3 - <<'PY'
import sys
print(".".join(map(str, sys.version_info[:3])))
PY
)"
  info "Found Python $ver"

  local major minor
  major="$(python3 - <<'PY'
import sys
print(sys.version_info.major)
PY
)"
  minor="$(python3 - <<'PY'
import sys
print(sys.version_info.minor)
PY
)"
  if (( major < MIN_PYTHON_MAJOR || (major == MIN_PYTHON_MAJOR && minor < MIN_PYTHON_MINOR) )); then
    error "Python $MIN_PYTHON_MAJOR.$MIN_PYTHON_MINOR+ required, found $ver"
    return 1
  fi
}

create_directories() {
  for d in "${DIRS_TO_CREATE[@]}"; do
    if [[ ! -d "$d" ]]; then
      mkdir -p "$d"
      log "Created directory: $d"
    fi
  done
}

setup_venv() {
  if [[ -d "$VENV_DIR" && -x "$VENV_DIR/bin/python" ]]; then
    log "Virtual environment already exists at $VENV_DIR"
  else
    log "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR" || {
      warn "Failed to create venv using stdlib. Trying 'virtualenv' if available."
      if have_cmd virtualenv; then
        virtualenv "$VENV_DIR"
      else
        error "Could not create virtual environment. Ensure python3-venv or virtualenv is installed."
        return 1
      fi
    }
  fi

  # Upgrade pip/setuptools/wheel in venv
  log "Upgrading pip, setuptools, and wheel in venv"
  "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
}

install_python_deps() {
  if [[ -f "$PROJECT_ROOT/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt"
    "$VENV_DIR/bin/python" -m pip install -r "$PROJECT_ROOT/requirements.txt"
  else
    warn "requirements.txt not found. Installing core dependencies directly."
    "$VENV_DIR/bin/python" -m pip install anthropic python-dotenv pyyaml graphviz groq pyperclip pytest
  fi
}

write_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'EOF'
# Application environment variables
# Fill in your API keys and settings. This file is loaded by profile snippet.
# Do not commit real keys to version control.

# LLM provider API keys
ANTHROPIC_API_KEY=
GROQ_API_KEY=

# Python behavior
PYTHONUNBUFFERED=1
PYTHONDONTWRITEBYTECODE=1

# Optional: override default log level
# LOG_LEVEL=INFO
EOF
    chmod 600 "$ENV_FILE" || true
    log "Created environment file template at $ENV_FILE"
  else
    log "Environment file already exists at $ENV_FILE"
  fi
}

write_profile_snippet() {
  local target_snippet
  target_snippet="$PROFILE_SNIPPET_PATH"

  # If not root, can't write to /etc/profile.d; fallback to local snippet
  if [[ $(id -u) -ne 0 ]]; then
    target_snippet="$PROJECT_ROOT/.project-profile.sh"
    warn "Not running as root; writing profile snippet to $target_snippet"
  fi

  # Resolve absolute project root for the snippet
  local abs_root
  abs_root="$PROJECT_ROOT"

  cat > "$target_snippet" <<EOF
# Auto-generated environment snippet for the project
# shellcheck shell=sh

# Prepend project venv to PATH if present
if [ -d "$abs_root/.venv/bin" ]; then
  case ":\$PATH:" in
    *:"$abs_root/.venv/bin":*) : ;;
    *) PATH="$abs_root/.venv/bin:\$PATH" ;;
  esac
fi

# Load .env if present (export all variables temporarily)
if [ -f "$abs_root/.env" ]; then
  set -a
  . "$abs_root/.env"
  set +a
fi

# Graphviz 'dot' path for python-graphviz
if command -v dot >/dev/null 2>&1; then
  export GRAPHVIZ_DOT="\$(command -v dot)"
fi

export PYTHONUNBUFFERED="\${PYTHONUNBUFFERED:-1}"
export PYTHONDONTWRITEBYTECODE="\${PYTHONDONTWRITEBYTECODE:-1}"
EOF

  chmod 644 "$target_snippet" || true
  log "Wrote profile snippet to $target_snippet"
}

export_runtime_env() {
  # Export minimal env for current session
  export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
  export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a || true
  fi
}

verify_runtime() {
  log "Verifying Python imports"
  "$VENV_DIR/bin/python" - <<'PY'
import sys
missing = []
for pkg, mod in [
    ("anthropic","anthropic"),
    ("python-dotenv","dotenv"),
    ("pyyaml","yaml"),
    ("graphviz","graphviz"),
    ("groq","groq"),
    ("pyperclip","pyperclip"),
    ("pytest","pytest"),
]:
    try:
        __import__(mod)
    except Exception as e:
        missing.append(f"{pkg} ({mod}): {e}")
if missing:
    print("Some dependencies failed to import:", file=sys.stderr)
    for m in missing:
        print(" -", m, file=sys.stderr)
    sys.exit(1)
print("All required Python packages imported successfully.")
PY

  if have_cmd dot; then
    info "Graphviz dot version: $(dot -V 2>&1 || true)"
  else
    warn "Graphviz 'dot' still not available. Rendering via python-graphviz may fail."
  fi
}

set_permissions() {
  # Create a non-root app user if requested (and if running as root)
  if [[ -n "$APP_USER" && $(id -u) -eq 0 ]]; then
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      log "Creating user '$APP_USER' with UID:$APP_UID GID:$APP_GID"
      # Create group if not exists
      if ! getent group "$APP_GID" >/dev/null 2>&1; then
        groupadd -g "$APP_GID" "$APP_USER" || true
      fi
      if ! getent passwd "$APP_UID" >/dev/null 2>&1; then
        useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" || useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/sh "$APP_USER" || true
      fi
    fi
  fi

  # Adjust permissions on project tree for the intended user/group
  if [[ $(id -u) -eq 0 ]]; then
    local chown_target="${APP_UID}:${APP_GID}"
    log "Setting ownership of key directories to $chown_target"
    for d in "$VENV_DIR" "$PROJECT_ROOT/logs" "$PROJECT_ROOT/.cache" "$PROJECT_ROOT/generated" "$PROJECT_ROOT/requirements" "$ENV_FILE"; do
      [[ -e "$d" ]] && chown -R "$chown_target" "$d" || true
    done
  else
    info "Running as non-root; skipping ownership adjustments."
  fi
}

print_summary() {
  echo
  echo "============================================================"
  echo "Project environment setup completed."
  echo
  echo "Project root: $PROJECT_ROOT"
  echo "Virtual env : $VENV_DIR"
  if [[ -f "$ENV_FILE" ]]; then
    echo "Env file    : $ENV_FILE"
  fi
  if [[ -f "$PROFILE_SNIPPET_PATH" ]]; then
    echo "Profile cfg : $PROFILE_SNIPPET_PATH"
  else
    echo "Profile cfg : $PROJECT_ROOT/.project-profile.sh (source this for current shell)"
  fi
  echo
  echo "Next steps:"
  echo "- Activate venv: source \"$VENV_DIR/bin/activate\""
  echo "- Ensure your API keys are set in $ENV_FILE:"
  echo "    ANTHROPIC_API_KEY and GROQ_API_KEY"
  echo "- Optionally source the profile snippet to auto-load .env and PATH:"
  if [[ -f "$PROFILE_SNIPPET_PATH" ]]; then
    echo "    source \"$PROFILE_SNIPPET_PATH\""
  else
    echo "    source \"$PROJECT_ROOT/.project-profile.sh\""
  fi
  echo "============================================================"
}

setup_timeout_shim() {
  local shim_path="/usr/local/bin/timeout"
  if [[ $(id -u) -ne 0 ]]; then
    warn "Not running as root; skipping installation of timeout shim at $shim_path"
    return 0
  fi
  cat > "$shim_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Shim to allow: timeout [opts] DURATION <shell-command with control constructs>
opts=()
while [[ $# -gt 0 && "$1" == -* ]]; do
  if [[ "$1" == "-k" ]]; then
    opts+=("$1" "$2")
    shift 2
  else
    opts+=("$1")
    shift
  fi
done
# Next arg is the duration (e.g., 1800s)
duration="$1"
shift || true
# Remainder is the shell command to run under bash -lc
cmd="$*"
exec /usr/bin/timeout "${opts[@]}" "$duration" bash -lc "$cmd"
EOF
  chmod +x "$shim_path" || true
}

setup_harness_fix() {
  if [[ $(id -u) -ne 0 ]]; then
    warn "Not running as root; skipping installation of harness bash fix in /etc/profile.d"
    return 0
  fi
  mkdir -p /etc/profile.d
  cat > /etc/profile.d/fix-harness-bash.sh <<'EOF'
# Workaround for misquoted harness commands like: bash -lc if ...; then ...; fi
# Runs in login shells before the -c string is executed.
if [ -z "${HARNESS_FIX_APPLIED:-}" ] && [ -n "${BASH_EXECUTION_STRING:-}" ]; then
  cmd="$BASH_EXECUTION_STRING"
  # trim leading whitespace
  case "$cmd" in
    ' '*) cmd="${cmd#"${cmd%%[![:space:]]*}"}" ;;
  esac
  if [[ "$cmd" == bash' -lc '* ]]; then
    rest="${cmd#bash -lc }"
    export HARNESS_FIX_APPLIED=1
    exec bash -lc "$rest"
  elif [[ "$cmd" == bash' -c '* ]]; then
    rest="${cmd#bash -c }"
    export HARNESS_FIX_APPLIED=1
    exec bash -lc "$rest"
  fi
fi
EOF
  chmod 0644 /etc/profile.d/fix-harness-bash.sh || true
  log "Installed harness command fix: /etc/profile.d/fix-harness-bash.sh"
}

setup_bash_wrapper() {
  # Install a PATH-first bash wrapper to normalize nested "bash -lc" misuse
  if [[ $(id -u) -ne 0 ]]; then
    warn "Not running as root; skipping installation of PATH-level bash wrapper"
    return 0
  fi

  mkdir -p /usr/local/bin
  cat > /usr/local/bin/bash <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REAL_BASH="/bin/bash"
if [ ! -x "$REAL_BASH" ]; then REAL_BASH="/usr/bin/bash"; fi
# If invoked without args, delegate to real bash
if [ "$#" -eq 0 ]; then
  exec "$REAL_BASH"
fi
args=("$@")
idx=-1
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    -c|-lc)
      idx="$i"
      break
      ;;
  esac
done
if [ "$idx" -ge 0 ]; then
  if [ $((idx+1)) -lt ${#args[@]} ]; then
    cmd="${args[$((idx+1))]}"
    if [ $((idx+2)) -lt ${#args[@]} ]; then
      j=$((idx+2))
      while [ "$j" -lt ${#args[@]} ]; do
        cmd+=" ${args[$j]}"
        j=$((j+1))
      done
    fi
    case "$cmd" in
      bash\ -lc\ *) cmd="${cmd#bash -lc }" ;;
      bash\ -c\ *)  cmd="${cmd#bash -c }"  ;;
    esac
    new=("${args[@]:0:$((idx+1))}")
    new+=("$cmd")
    exec "$REAL_BASH" "${new[@]}"
  fi
fi
exec "$REAL_BASH" "$@"
EOF
  chmod 0755 /usr/local/bin/bash || true

  mkdir -p /etc/profile.d && cat > /etc/profile.d/00-usrlocalbin.sh <<'EOF'
# Ensure /usr/local/bin precedes in PATH for login shells
case ":$PATH:" in
  *:/usr/local/bin:*) ;;
  *) export PATH="/usr/local/bin:$PATH" ;;
esac
EOF
  chmod 0644 /etc/profile.d/00-usrlocalbin.sh || true
}

# ------------------------------
# Main
# ------------------------------
main() {
  log "Starting project environment setup..."

  ensure_system_packages
  setup_harness_fix
  setup_bash_wrapper
  setup_timeout_shim
  check_python_version
  create_directories
  setup_venv
  install_python_deps
  write_env_file
  write_profile_snippet
  export_runtime_env
  verify_runtime
  set_permissions
  print_summary

  log "Setup finished successfully."
}

main "$@"