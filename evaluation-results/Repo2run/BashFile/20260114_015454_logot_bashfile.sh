#!/usr/bin/env bash
# Environment setup script for a Python project using pyproject.toml (Poetry-style metadata)
# Safe to run in minimal Docker containers. Installs Python, system deps, virtualenv, and project deps.
# Idempotent and configurable via environment variables.

set -Eeuo pipefail
IFS=$'\n\t'

#=============================
# Configurable parameters
#=============================
: "${PROJECT_ROOT:="$(pwd)"}"            # Project directory (where pyproject.toml lives)
: "${VENV_PATH:=/opt/venv}"              # Virtualenv path
: "${CREATE_APP_USER:=1}"                # Create non-root user (1=yes, 0=no)
: "${APP_USER:=app}"                     # Non-root username
: "${APP_UID:=1000}"                     # UID for non-root user
: "${APP_GID:=1000}"                     # GID for non-root group
: "${INSTALL_EXTRAS:=1}"                 # Install extras from [tool.poetry.extras]
: "${INSTALL_DEV_DEPS:=0}"               # Install common dev tools (pytest, ruff, mypy, coverage, etc.)
: "${USE_POETRY:=0}"                     # Use Poetry to resolve/install (installs into venv)
: "${PIP_INDEX_URL:=}"                   # Optional pip index
: "${PIP_EXTRA_INDEX_URL:=}"             # Optional extra index
: "${HTTP_PROXY:=}"                      # Optional proxies
: "${HTTPS_PROXY:=}"                     # Optional proxies

#=============================
# Logging helpers
#=============================
NOCOLOR='\033[0m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NOCOLOR}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NOCOLOR}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NOCOLOR}" >&2; }
die()    { error "$*"; exit 1; }
trap 's=$?; error "Failed at line $LINENO with exit code $s"; exit $s' ERR

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root inside the container."
  fi
}

#=============================
# Package manager detection
#=============================
detect_pkg_manager() {
  if command_exists apt-get; then
    PKG_MGR=apt
  elif command_exists apk; then
    PKG_MGR=apk
  elif command_exists microdnf; then
    PKG_MGR=microdnf
  elif command_exists dnf; then
    PKG_MGR=dnf
  elif command_exists yum; then
    PKG_MGR=yum
  else
    die "No supported package manager found (apt/apk/dnf/yum/microdnf)."
  fi
  log "Detected package manager: $PKG_MGR"
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      ;;
    apk)
      apk update || true
      ;;
    microdnf)
      microdnf -y update || true
      ;;
    dnf)
      dnf -y makecache || true
      ;;
    yum)
      yum -y makecache || true
      ;;
  esac
}

pkg_install() {
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    microdnf)
      microdnf install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
  esac
}

pkg_cleanup() {
  case "$PKG_MGR" in
    apt)
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    microdnf|dnf|yum)
      rm -rf /var/cache/dnf || true
      ;;
  esac
}

#=============================
# System dependencies
#=============================
install_system_packages() {
  log "Installing system packages and Python runtime..."
  pkg_update

  case "$PKG_MGR" in
    apt)
      pkg_install ca-certificates curl git bash coreutils findutils procps pkg-config \
                  python3 python3-venv python3-pip build-essential libffi-dev openssl libssl-dev
      ;;
    apk)
      pkg_install ca-certificates curl git bash coreutils findutils procps \
                  python3 py3-pip py3-virtualenv build-base libffi-dev openssl-dev
      ;;
    microdnf|dnf|yum)
      pkg_install ca-certificates curl git bash coreutils findutils procps-ng \
                  python3 python3-pip gcc make which diffutils \
                  libffi-devel openssl-devel
      # python3-venv may not exist; rely on ensurepip and venv module in python3
      ;;
  esac

  # Ensure certificates and update pip
  update-ca-certificates || true
  if command_exists python3; then
    python3 -m pip install --no-cache-dir -U pip setuptools wheel
  else
    die "Python3 was not installed successfully."
  fi

  pkg_cleanup
  log "System packages installation complete."
}

#=============================
# User and directory setup
#=============================
setup_users_and_dirs() {
  log "Setting up users and directories..."

  # Create group/user if requested and not present
  if [ "$CREATE_APP_USER" = "1" ]; then
    if ! getent group "$APP_GID" >/dev/null 2>&1; then
      addgroup() { groupadd -g "$APP_GID" "$APP_USER"; }
    fi
    if ! getent group "$APP_USER" >/dev/null 2>&1 && ! getent group "$APP_GID" >/dev/null 2>&1; then
      groupadd -g "$APP_GID" "$APP_USER" || true
    fi
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" || true
    fi
  fi

  # Project directory
  mkdir -p "$PROJECT_ROOT"
  mkdir -p "$VENV_PATH"
  mkdir -p /var/log/app
  mkdir -p /var/cache/pip

  if [ "$CREATE_APP_USER" = "1" ]; then
    chown -R "$APP_UID:$APP_GID" "$PROJECT_ROOT" "$VENV_PATH" /var/log/app /var/cache/pip || true
  fi

  log "Users and directories ready."
}

#=============================
# Python virtual environment
#=============================
create_or_reuse_venv() {
  if [ -x "$VENV_PATH/bin/python" ]; then
    log "Using existing virtualenv at $VENV_PATH"
  else
    log "Creating virtualenv at $VENV_PATH"
    python3 -m venv "$VENV_PATH"
  fi
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"
  python -m pip install --no-cache-dir -U pip setuptools wheel
}

#=============================
# Project metadata helpers
#=============================
assert_pyproject() {
  if [ ! -f "$PROJECT_ROOT/pyproject.toml" ]; then
    warn "pyproject.toml not found in $PROJECT_ROOT. Proceeding with generic Python environment setup."
  else
    log "Found pyproject.toml at $PROJECT_ROOT"
  fi
}

get_poetry_extras() {
  # Extract extras keys from [tool.poetry.extras] section
  local extras_section
  extras_section=$(awk '
    /^\[tool\.poetry\.extras\]/ {insec=1; next}
    insec && /^\[/ {insec=0}
    insec {print}
  ' "$PROJECT_ROOT/pyproject.toml" 2>/dev/null || true)

  if [ -z "$extras_section" ]; then
    echo ""
    return 0
  fi

  echo "$extras_section" | awk -F'=' '
    /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
      gsub(/[[:space:]]/,"",$1);
      gsub(/"/,"",$1);
      print $1
    }
  ' | tr '\n' ',' | sed 's/,$//'
}

#=============================
# Dependencies installation
#=============================
install_with_pip_from_pyproject() {
  local extras_list=""
  if [ -f "$PROJECT_ROOT/pyproject.toml" ] && [ "$INSTALL_EXTRAS" = "1" ]; then
    extras_list=$(get_poetry_extras || true)
  fi

  pushd "$PROJECT_ROOT" >/dev/null

  # Respect optional indexes
  local pip_args=(--no-cache-dir)
  [ -n "$PIP_INDEX_URL" ] && pip_args+=(--index-url "$PIP_INDEX_URL")
  [ -n "$PIP_EXTRA_INDEX_URL" ] && pip_args+=(--extra-index-url "$PIP_EXTRA_INDEX_URL")

  python -m pip install "${pip_args[@]}" -U build

  if [ -f "pyproject.toml" ]; then
    if [ -n "$extras_list" ]; then
      log "Installing project in editable mode with extras: $extras_list"
      python -m pip install "${pip_args[@]}" -e ".[${extras_list}]"
    else
      log "Installing project in editable mode (no extras detected)"
      python -m pip install "${pip_args[@]}" -e .
    fi
  else
    warn "pyproject.toml missing, skipping local package install."
  fi

  if [ "$INSTALL_DEV_DEPS" = "1" ]; then
    log "Installing common dev/testing tools"
    python -m pip install "${pip_args[@]}" -U \
      pytest hypothesis coverage mypy ruff sphinx furo sphinx-autobuild trio-typing
  fi

  popd >/dev/null
}

install_with_poetry() {
  pushd "$PROJECT_ROOT" >/dev/null

  # Install Poetry into venv
  if ! command -v poetry >/dev/null 2>&1; then
    log "Installing Poetry into virtualenv"
    python -m pip install --no-cache-dir -U poetry
  fi

  # Use current venv, do not create a nested one
  poetry config virtualenvs.create false

  local poetry_args=(--no-interaction --no-ansi)
  if [ -n "$PIP_INDEX_URL" ]; then poetry config repositories.custom "$PIP_INDEX_URL" || true; fi

  log "Installing project dependencies via Poetry"
  if [ "$INSTALL_DEV_DEPS" = "1" ]; then
    poetry install "${poetry_args[@]}" --with dev
  else
    poetry install "${poetry_args[@]}"
  fi

  popd >/dev/null
}

install_dependencies() {
  log "Installing Python dependencies..."
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"

  if [ "$USE_POETRY" = "1" ]; then
    install_with_poetry
  else
    install_with_pip_from_pyproject
  fi
  log "Dependency installation complete."
}

#=============================
# Environment configuration
#=============================
configure_environment() {
  log "Configuring environment variables and profiles"

  # Defaults beneficial in containers
  : "${PYTHONUNBUFFERED:=1}"
  : "${PYTHONDONTWRITEBYTECODE:=1}"
  : "${PIP_DISABLE_PIP_VERSION_CHECK:=1}"
  : "${PIP_NO_CACHE_DIR:=1}"

  # Persist env in profile.d
  cat >/etc/profile.d/10-project-env.sh <<EOF
# Auto-generated by setup script
export VIRTUAL_ENV="$VENV_PATH"
export PATH="\$VIRTUAL_ENV/bin:\$PATH"
export PROJECT_ROOT="$PROJECT_ROOT"

export PYTHONUNBUFFERED=${PYTHONUNBUFFERED}
export PYTHONDONTWRITEBYTECODE=${PYTHONDONTWRITEBYTECODE}
export PIP_DISABLE_PIP_VERSION_CHECK=${PIP_DISABLE_PIP_VERSION_CHECK}
export PIP_NO_CACHE_DIR=${PIP_NO_CACHE_DIR}
$( [ -n "$PIP_INDEX_URL" ] && echo "export PIP_INDEX_URL=\"$PIP_INDEX_URL\"" )
$( [ -n "$PIP_EXTRA_INDEX_URL" ] && echo "export PIP_EXTRA_INDEX_URL=\"$PIP_EXTRA_INDEX_URL\"" )
$( [ -n "$HTTP_PROXY" ] && echo "export HTTP_PROXY=\"$HTTP_PROXY\"" )
$( [ -n "$HTTPS_PROXY" ] && echo "export HTTPS_PROXY=\"$HTTPS_PROXY\"" )
EOF

  chmod 0644 /etc/profile.d/10-project-env.sh

  # Also write .env file in project root for app/tools if they use it
  cat >"$PROJECT_ROOT/.env" <<EOF
# Environment file for the project
VIRTUAL_ENV=$VENV_PATH
PYTHONUNBUFFERED=${PYTHONUNBUFFERED}
PYTHONDONTWRITEBYTECODE=${PYTHONDONTWRITEBYTECODE}
PIP_DISABLE_PIP_VERSION_CHECK=${PIP_DISABLE_PIP_VERSION_CHECK}
PIP_NO_CACHE_DIR=${PIP_NO_CACHE_DIR}
EOF

  if [ "$CREATE_APP_USER" = "1" ]; then
    chown "$APP_UID:$APP_GID" "$PROJECT_ROOT/.env" || true
  fi

  log "Environment configuration complete."
}

#=============================
# Final summary
#=============================
print_summary() {
  log "Setup complete."
  echo "Summary:"
  echo "- Project root: $PROJECT_ROOT"
  echo "- Virtualenv:   $VENV_PATH"
  echo "- Using Poetry:  $USE_POETRY"
  echo "- Extras:        $INSTALL_EXTRAS"
  echo "- Dev deps:      $INSTALL_DEV_DEPS"
  echo "- App user:      ${CREATE_APP_USER:+$APP_USER} (create=${CREATE_APP_USER})"
  echo
  echo "To use the environment in this container:"
  echo "  source /etc/profile.d/10-project-env.sh"
  echo "  python -c 'import sys; print(sys.version)'"
  echo
  echo "Run tests (if installed):"
  echo "  pytest -q"
}

#=============================
# CI auto-build script writer
#=============================
install_ci_auto_build() {
  cat >"$PROJECT_ROOT/ci-auto-build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci --no-audit --no-fund && npm run build
  else
    echo "npm not found" >&2; exit 127
  fi
elif [ -f pom.xml ]; then
  if command -v mvn >/dev/null 2>&1; then
    mvn -B -DskipTests package
  else
    echo "mvn not found" >&2; exit 127
  fi
elif [ -f build.gradle ] || [ -f gradlew ]; then
  if [ -x ./gradlew ]; then ./gradlew build -x test; elif command -v gradle >/dev/null 2>&1; then gradle build -x test; else echo "Gradle not found" >&2; exit 127; fi
elif [ -f Cargo.toml ]; then
  if command -v cargo >/dev/null 2>&1; then cargo build; else echo "cargo not found" >&2; exit 127; fi
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
  if command -v python >/dev/null 2>&1; then python -m pip install -U pip setuptools wheel && pip install -e .; else echo "python not found" >&2; exit 127; fi
elif [ -f Makefile ]; then
  make build || make
else
  echo "No recognized build configuration (npm/maven/gradle/cargo/python/make)" >&2
  exit 1
fi
EOF
  chmod +x "$PROJECT_ROOT/ci-auto-build.sh"

  if [ ! -f "$PROJECT_ROOT/build.sh" ]; then
    cat >"$PROJECT_ROOT/build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec ./ci-auto-build.sh "$@"
EOF
    chmod +x "$PROJECT_ROOT/build.sh"
  fi

  if [ ! -f "$PROJECT_ROOT/Makefile" ]; then
    cat >"$PROJECT_ROOT/Makefile" <<'EOF'
ci:
	./ci-auto-build.sh

all: ci
EOF
  fi
}

#=============================
# Main
#=============================
main() {
  require_root
  detect_pkg_manager
  install_system_packages
  setup_users_and_dirs
  assert_pyproject
  create_or_reuse_venv
  install_dependencies
  configure_environment
  install_ci_auto_build
  print_summary
}

main "$@"