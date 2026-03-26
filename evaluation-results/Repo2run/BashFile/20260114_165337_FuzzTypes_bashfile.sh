#!/usr/bin/env bash
# Environment setup script for the FuzzTypes Python project
# Designed for containerized (Docker) environments.

set -Eeuo pipefail
IFS=$'\n\t'

#---------------------------
# Logging and error handling
#---------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
on_err() {
  err "Command failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
}
trap on_err ERR

#---------------------------
# Configurable settings
#---------------------------
# You can override these via environment variables when invoking the script.

PROJECT_NAME="${PROJECT_NAME:-FuzzTypes}"

# Where the script should assume the project root (with pyproject.toml) is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"

# Virtual environment location (global under /opt is common in Docker)
VENV_DIR="${VENV_DIR:-/opt/venv}"

# Which extras to install for this project:
#   none (default minimal), ext (optional features), test (testing), local (local dev), all (everything)
# You can also provide a comma-separated list like "ext,test"
FUZZTYPES_INSTALL_EXTRAS="${FUZZTYPES_INSTALL_EXTRAS:-none}"

# Preload sentence-transformers model and create cache directories
FUZZTYPES_PRELOAD_MODELS="${FUZZTYPES_PRELOAD_MODELS:-0}"

# FUZZTYPES_HOME controls where models/indexes are stored. Defaults to ~/.local/fuzztypes (project default)
FUZZTYPES_HOME="${FUZZTYPES_HOME:-$HOME/.local/fuzztypes}"

# Default encoder model (can be large). Change or leave default.
FUZZTYPES_DEFAULT_ENCODER="${FUZZTYPES_DEFAULT_ENCODER:-sentence-transformers/paraphrase-MiniLM-L6-v2}"

# Python version check (minimum 3.9)
PY_MIN_MAJOR=3
PY_MIN_MINOR=9

#---------------------------
# Package manager detection
#---------------------------
PKG_MANAGER=""
update_pkg_index() {
  case "$PKG_MANAGER" in
    apt-get) apt-get update -y ;;
    apk) apk update ;;
    dnf|microdnf) "$PKG_MANAGER" makecache -y || true ;;
    yum) yum makecache -y || true ;;
  esac
}

install_pkgs() {
  # Accepts packages as arguments
  case "$PKG_MANAGER" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@";;
    apk) apk add --no-cache "$@";;
    dnf|microdnf) "$PKG_MANAGER" install -y "$@";;
    yum) yum install -y "$@";;
    *)
      err "Unsupported package manager. Unable to install system packages."
      exit 1
      ;;
  esac
}

clean_pkg_cache() {
  case "$PKG_MANAGER" in
    apt-get)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
    ;;
    apk)
      # apk uses --no-cache installs so nothing to clean typically
      true
    ;;
    dnf|microdnf|yum)
      rm -rf /var/cache/dnf || true
      rm -rf /var/cache/yum || true
    ;;
  esac
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER=""
  fi
}

#---------------------------
# System dependencies
#---------------------------
install_system_deps() {
  log "Detecting package manager..."
  detect_pkg_manager
  if [[ -z "$PKG_MANAGER" ]]; then
    err "No supported package manager found (apt-get/apk/dnf/yum)."
    exit 1
  fi
  log "Using package manager: $PKG_MANAGER"

  log "Updating package index..."
  update_pkg_index

  # Baseline tools
  local base_tools=(ca-certificates curl git bash coreutils findutils sed grep tar gzip)
  # Build essentials
  local build_tools_apt=(build-essential gcc g++ make)
  local build_tools_apk=(build-base)
  local build_tools_dnf=(gcc gcc-c++ make)
  local build_tools_yum=(gcc gcc-c++ make)
  # Python runtime and dev headers
  local python_apt=(python3 python3-pip python3-venv python3-dev libffi-dev libssl-dev)
  local python_apk=(python3 py3-pip py3-virtualenv python3-dev libffi-dev openssl-dev musl-dev)
  local python_dnf=(python3 python3-pip python3-devel libffi-devel openssl-devel)
  local python_yum=(python3 python3-pip python3-devel libffi-devel openssl-devel)

  case "$PKG_MANAGER" in
    apt-get)
      install_pkgs "${base_tools[@]}" "${build_tools_apt[@]}" "${python_apt[@]}"
      ;;
    apk)
      install_pkgs "${base_tools[@]}" "${build_tools_apk[@]}" "${python_apk[@]}"
      ;;
    dnf|microdnf)
      install_pkgs "${base_tools[@]}" "${build_tools_dnf[@]}" "${python_dnf[@]}"
      ;;
    yum)
      install_pkgs "${base_tools[@]}" "${build_tools_yum[@]}" "${python_yum[@]}"
      ;;
  esac

  # Helpful: ensure /usr/local/bin present in PATH
  if ! echo "$PATH" | grep -q "/usr/local/bin"; then
    export PATH="/usr/local/bin:$PATH"
  fi

  # Ensure SSL certs updated
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi

  clean_pkg_cache
  log "System dependencies installed."
}

#---------------------------
# Python environment
#---------------------------
check_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is not installed (system package installation likely failed)."
    exit 1
  fi
  local ver
  ver="$(python3 - <<'PY'
import sys
print("{}.{}".format(sys.version_info.major, sys.version_info.minor))
PY
)"
  local major="${ver%%.*}"
  local minor="${ver#*.}"
  if (( major < PY_MIN_MAJOR )) || { (( major == PY_MIN_MAJOR )) && (( minor < PY_MIN_MINOR )); }; then
    err "Python >= ${PY_MIN_MAJOR}.${PY_MIN_MINOR} is required. Found ${ver}."
    exit 1
  fi
  log "Python ${ver} detected."
}

create_venv() {
  if [[ -d "$VENV_DIR" && -x "$VENV_DIR/bin/python" ]]; then
    log "Virtual environment already exists at $VENV_DIR"
  else
    log "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  # Activate venv for current shell
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"

  # Upgrade pip/setuptools/wheel
  pip install --no-input --upgrade pip setuptools wheel

  # Make venv generally available across shell sessions in the container
  if [[ -w /etc/profile.d ]]; then
    cat >/etc/profile.d/venv-path.sh <<EOF
# Auto-activate FuzzTypes venv PATH
if [ -d "$VENV_DIR/bin" ]; then
  export PATH="$VENV_DIR/bin:\$PATH"
fi
# Recommended project env vars
export FUZZTYPES_HOME="${FUZZTYPES_HOME}"
export FUZZTYPES_DEFAULT_ENCODER="${FUZZTYPES_DEFAULT_ENCODER}"
export PYTHONUNBUFFERED=1
EOF
    chmod 0644 /etc/profile.d/venv-path.sh || true
  fi
}

#---------------------------
# Virtualenv auto-activation
#---------------------------
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_path="${VENV_DIR}/bin/activate"
  # Only add if not already present
  if ! grep -qF "$activate_path" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate FuzzTypes venv" >> "$bashrc_file"
    echo "if [ -f \"$activate_path\" ]; then" >> "$bashrc_file"
    echo "  . \"$activate_path\"" >> "$bashrc_file"
    echo "fi" >> "$bashrc_file"
  fi
}

#---------------------------
# Timeout wrapper shim
#---------------------------
setup_timeout_wrapper() {
  # Install a PATH-precedence shim at /usr/local/bin/timeout that detects
  # compound shell constructs and runs them under bash -lc, delegating
  # all other invocations to the real timeout binary.
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/timeout <<'EOF'
#!/bin/sh
# Wrapper to handle compound shell constructs passed directly to `timeout`
set -e
# Locate the real timeout binary
if [ -x /usr/bin/timeout ]; then REAL_T=/usr/bin/timeout
elif [ -x /bin/timeout ]; then REAL_T=/bin/timeout
else
  echo "timeout: real timeout binary not found in /usr/bin or /bin" >&2
  exit 127
fi

# If no args, just exec real timeout
[ $# -gt 0 ] || exec "$REAL_T"

# Collect options (handle ones with args) until duration
opts=""
while [ $# -gt 0 ]; do
  case "$1" in
    -k|--kill-after|-s|--signal)
      [ $# -ge 2 ] || break
      opts="$opts $1 $2"
      shift 2
      ;;
    --*)
      opts="$opts $1"
      shift
      ;;
    -* )
      opts="$opts $1"
      shift
      ;;
    * )
      break
      ;;
  esac
done

# Expect duration next
[ $# -gt 0 ] || exec "$REAL_T" $opts
duration="$1"
shift

# If next token starts a shell compound, run under bash -lc
if [ $# -gt 0 ]; then
  case "$1" in
    if|for|while|until|case|'{'|'('| '[[')
      script="$*"
      exec "$REAL_T" $opts "$duration" bash -lc "$script"
      ;;
  esac
fi

# Default: delegate to real timeout
if [ $# -gt 0 ]; then
  exec "$REAL_T" $opts "$duration" "$@"
else
  exec "$REAL_T" $opts "$duration"
fi
EOF
  chmod +x /usr/local/bin/timeout

  # Ensure /usr/local/bin has precedence in future shells
  if [ -w /etc/profile.d ]; then
    case ":$PATH:" in
      *:/usr/local/bin:*) : ;;
      *) echo 'export PATH=/usr/local/sbin:/usr/local/bin:$PATH' > /etc/profile.d/00-localpath.sh ;;
    esac
  fi
}

#---------------------------
# Timeout function wrapper for invalid compound command usage via /etc/profile.d
#---------------------------
setup_timeout_compound_fix() {
  cat > /etc/profile.d/timeout_compound_fix.sh <<'EOF'
# Fix invalid "timeout if ...; then ...; fi" invocations by wrapping in bash -lc.
# Loaded by bash login shells via /etc/profile.
if [ -n "$BASH_VERSION" ]; then
  timeout() {
    local -a args opts rest
    args=("$@")
    opts=()
    local duration=
    local i=0
    while (( i < ${#args[@]} )); do
      case "${args[i]}" in
        --)
          opts+=("--")
          ((i++))
          break
          ;;
        -k|--kill-after|-s|--signal)
          opts+=("${args[i]}")
          ((i++))
          if (( i < ${#args[@]} )); then
            opts+=("${args[i]}")
            ((i++))
          fi
          ;;
        -*)
          opts+=("${args[i]}")
          ((i++))
          ;;
        *)
          duration="${args[i]}"
          ((i++))
          break
          ;;
      esac
    done
    rest=("${args[@]:$i}")
    if (( ${#rest[@]} == 0 )); then
      command timeout "${args[@]}"
      return
    fi
    local first="${rest[0]}"
    case "$first" in
      if|for|while|until|case|{|(|[[)
        local program
        program="${rest[*]}"
        command timeout "${opts[@]}" "$duration" bash -lc "$program"
        ;;
      *)
        command timeout "${args[@]}"
        ;;
    esac
  }
  export -f timeout
fi
EOF
  chmod 0644 /etc/profile.d/timeout_compound_fix.sh || true
}

#---------------------------
# Bash wrapper to fix GNU timeout + compound commands
#---------------------------
setup_bash_wrapper() {
  cat >/tmp/bash-wrapper <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Wrapper to fix: timeout ... if ...; then ...; fi malformed under bash -c
if [[ "${1-}" == "-c" && "${2-}" == timeout* ]]; then
  cmd="${2-}"
  if [[ "$cmd" == timeout*' if '* && "$cmd" == *'; then '* && "$cmd" == *'; fi'* ]]; then
    delim=' if '
    prefix="${cmd%%$delim*}"
    rest="${cmd#*$delim}"
    if_cmd="if ${rest}"
    timeout_args="${prefix#timeout }"
    exec timeout $timeout_args /bin/bash.real -lc "$if_cmd"
  fi
fi
exec /bin/bash.real "$@"
EOF
  if [ ! -x /bin/bash.real ]; then cp -a /bin/bash /bin/bash.real; fi
  install -m 0755 /tmp/bash-wrapper /bin/bash
}

#---------------------------
# Project installation
#---------------------------
normalize_extras() {
  # Convert commas and spaces to a canonical list
  local input="$1"
  local out=""
  IFS=',' read -r -a parts <<<"$input"
  declare -A seen
  for p in "${parts[@]}"; do
    p="$(echo "$p" | tr '[:upper:]' '[:lower:]' | xargs)"
    [[ -z "$p" ]] && continue
    if [[ "$p" == "all" ]]; then
      out="ext,test,local"
      echo "$out"
      return 0
    fi
    if [[ "$p" =~ ^(none|ext|test|local)$ ]]; then
      if [[ -z "${seen[$p]+x}" ]]; then
        seen[$p]=1
        if [[ -z "$out" ]]; then out="$p"; else out="$out,$p"; fi
      fi
    else
      warn "Unknown extras group '$p' ignored. Valid: none, ext, test, local, all"
    fi
  done
  echo "${out:-none}"
}

build_extras_spec() {
  local normalized
  normalized="$(normalize_extras "$FUZZTYPES_INSTALL_EXTRAS")"
  # translate group names to actual extras defined in pyproject
  # none -> no extras
  # ext -> [ext]
  # test -> [test]
  # local -> [local]
  local extras=()
  IFS=',' read -r -a arr <<<"$normalized"
  for e in "${arr[@]}"; do
    if [[ "$e" == "none" ]]; then
      continue
    fi
    extras+=("$e")
  done

  if (( ${#extras[@]} == 0 )); then
    echo ""
  else
    local joined
    local IFS=,
    joined="${extras[*]}"
    echo "[$joined]"
  fi
}

install_project() {
  cd "$PROJECT_DIR"
  if [[ ! -f "pyproject.toml" ]]; then
    err "pyproject.toml not found in PROJECT_DIR: $PROJECT_DIR"
    exit 1
  fi

  # Activate venv
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"

  local extras_spec
  extras_spec="$(build_extras_spec)"
  if [[ -n "$extras_spec" ]]; then
    log "Installing project with extras: $FUZZTYPES_INSTALL_EXTRAS -> $extras_spec"
  else
    log "Installing project with minimal dependencies (no extras)."
  fi

  # Install in editable mode for development convenience; change to non-editable if desired
  # For container environments, editable is often fine; for production images, prefer non-editable.
  pip install --no-input -e ".${extras_spec}"

  # Ensure optional runtime dependency for date parsing is present
  pip install --no-input -U dateparser

  log "Verifying installation..."
  python - <<PY
import importlib
import sys
from importlib.metadata import version, PackageNotFoundError
pkg="${PROJECT_NAME}"
try:
    print(f"{pkg} version:", version(pkg))
    import fuzztypes
    print("fuzztypes import OK; __version__:", getattr(fuzztypes, "__version__", "unknown"))
except PackageNotFoundError:
    sys.exit("Package not found after installation")
PY
}

#---------------------------
# Runtime configuration
#---------------------------
setup_runtime_env() {
  log "Configuring runtime environment under \$FUZZTYPES_HOME: $FUZZTYPES_HOME"
  mkdir -p "$FUZZTYPES_HOME/models" "$FUZZTYPES_HOME/downloads" "$FUZZTYPES_HOME/on_disk"
  chmod 0755 "$FUZZTYPES_HOME" || true

  # Export environment variables in current session
  export FUZZTYPES_HOME
  export FUZZTYPES_DEFAULT_ENCODER
  export PYTHONUNBUFFERED=1

  # Persist env vars in /etc/profile.d if writable
  if [[ -w /etc/profile.d ]]; then
    cat >/etc/profile.d/fuzztypes-env.sh <<EOF
export FUZZTYPES_HOME="${FUZZTYPES_HOME}"
export FUZZTYPES_DEFAULT_ENCODER="${FUZZTYPES_DEFAULT_ENCODER}"
export PYTHONUNBUFFERED=1
EOF
    chmod 0644 /etc/profile.d/fuzztypes-env.sh || true
  fi

  # Permissions
  if [[ -n "${CONTAINER_USER_UID:-}" && -n "${CONTAINER_USER_GID:-}" ]]; then
    # If the container wants to run as a non-root user later, set ownership
    chown -R "${CONTAINER_USER_UID}:${CONTAINER_USER_GID}" "$VENV_DIR" "$FUZZTYPES_HOME" || true
  fi

  # Optional: preload models to avoid runtime downloads (only if extras include ext)
  local extras_spec
  extras_spec="$(build_extras_spec)"
  if [[ "$FUZZTYPES_PRELOAD_MODELS" == "1" && "$extras_spec" == *"ext"* ]]; then
    log "Preloading default encoder model: ${FUZZTYPES_DEFAULT_ENCODER}"
    # This calls into fuzztypes.lazy.create_encoder which will save the model under $FUZZTYPES_HOME/models
    # shellcheck disable=SC1090
    source "$VENV_DIR/bin/activate"
    python - <<PY || warn "Model preload failed (continuing)."
import os
os.environ["FUZZTYPES_HOME"] = "${FUZZTYPES_HOME}"
os.environ["FUZZTYPES_DEFAULT_ENCODER"] = "${FUZZTYPES_DEFAULT_ENCODER}"
from fuzztypes.lazy import create_encoder
enc = create_encoder(None, "cpu")
_ = enc(["hello world"])
print("Model preloaded to:", os.path.join("${FUZZTYPES_HOME}", "models"))
PY
  else
    log "Model preload skipped. Set FUZZTYPES_PRELOAD_MODELS=1 and include ext extras to enable."
  fi
}

#---------------------------
# Directory structure & permissions
#---------------------------
setup_project_dirs() {
  log "Setting up project directory structure and permissions..."
  mkdir -p "$PROJECT_DIR/.cache" "$PROJECT_DIR/.data" "$PROJECT_DIR/logs"
  chmod 0755 "$PROJECT_DIR" || true
  chmod 0755 "$PROJECT_DIR"/.cache "$PROJECT_DIR"/.data "$PROJECT_DIR"/logs || true

  # Ensure the venv/bin is at front of PATH for current session
  export PATH="$VENV_DIR/bin:$PATH"
}

#---------------------------
# Main
#---------------------------
main() {
  log "Starting environment setup for ${PROJECT_NAME}"
  install_system_deps
  # Use profile.d function to fix invalid timeout + compound command usage
  setup_timeout_compound_fix
  setup_bash_wrapper
  check_python
  create_venv
  setup_auto_activate
  setup_project_dirs
  install_project
  setup_runtime_env

  log "Environment setup completed successfully!"
  echo
  echo "Usage:"
  echo "  - Activate venv: source \"$VENV_DIR/bin/activate\""
  echo "  - Verify:        python -c 'import fuzztypes, importlib.metadata as md; print(\"FuzzTypes:\", md.version(\"FuzzTypes\"))'"
  echo
  echo "Environment variables:"
  echo "  FUZZTYPES_HOME=${FUZZTYPES_HOME}"
  echo "  FUZZTYPES_DEFAULT_ENCODER=${FUZZTYPES_DEFAULT_ENCODER}"
  echo "  VENV_DIR=${VENV_DIR}"
  echo "  FUZZTYPES_INSTALL_EXTRAS=${FUZZTYPES_INSTALL_EXTRAS}"
}

main "$@"