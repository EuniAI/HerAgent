#!/usr/bin/env bash
# Container-friendly project environment setup script
# This script auto-detects common project types (Python, Node.js, Java, Go) and installs
# required runtimes, system deps, and configures the environment for container execution.

set -Eeuo pipefail

# Globals and defaults
APP_DIR="${APP_DIR:-$(pwd)}"
APP_ENV="${APP_ENV:-production}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
NONINTERACTIVE="${NONINTERACTIVE:-1}"

# Colors for output (safe fallbacks)
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; NC=''
fi

log()    { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo "${YELLOW}[WARN $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
error()  { echo "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

trap 'error "An error occurred on line $LINENO. Aborting."; exit 1' ERR
trap 'warn "Interrupted"; exit 130' INT

setup_auto_activate() {
  # Ensure the project's virtualenv auto-activates for interactive shells
  # Usage: setup_auto_activate "/path/to/.venv"
  local venv_path="$1"
  local bashrc_file="/root/.bashrc"
  local activate_line="source ${venv_path}/bin/activate"

  # Append to root's .bashrc if not already present
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    echo "" >> "$bashrc_file"
    echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
    echo "$activate_line" >> "$bashrc_file"
  fi

  # Also create a profile.d script for interactive shells
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/venv_auto.sh <<EOF
# Auto-activate project virtualenv for interactive shells
if [ -n "\$PS1" ] && [ -d "${venv_path}" ] && [ -z "\$VIRTUAL_ENV" ]; then
  . "${venv_path}/bin/activate"
fi
EOF
  chmod 0644 /etc/profile.d/venv_auto.sh
}


require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must run as root inside the container. Current UID: $(id -u)"
  fi
}

detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
  else
    OS_ID="unknown"
    OS_VERSION_ID="unknown"
  fi
  log "Detected OS: ${OS_ID} ${OS_VERSION_ID}"
}

detect_pkg_manager() {
  if cmd_exists apt-get; then
    PKG_MGR="apt"
  elif cmd_exists apk; then
    PKG_MGR="apk"
  elif cmd_exists dnf; then
    PKG_MGR="dnf"
  elif cmd_exists yum; then
    PKG_MGR="yum"
  elif cmd_exists zypper; then
    PKG_MGR="zypper"
  else
    PKG_MGR="unknown"
  fi
  log "Package manager: ${PKG_MGR}"
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
      if [ "${NONINTERACTIVE}" = "1" ]; then
        export NEEDRESTART_MODE=a
      fi
      apt-get update -y
      ;;
    apk)
      apk update
      ;;
    dnf)
      dnf makecache -y
      ;;
    yum)
      yum makecache -y
      ;;
    zypper)
      zypper --non-interactive refresh
      ;;
    *)
      ;;
  esac
}

pkg_install() {
  # usage: pkg_install pkg1 pkg2 ...
  case "$PKG_MGR" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install -y "$@"
      ;;
    *)
      die "Unsupported package manager for installing: $*"
      ;;
  esac
}

install_base_tools() {
  log "Installing base system packages and build tools..."
  case "$PKG_MGR" in
    apt)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg tar xz-utils unzip \
                  make gcc g++ build-essential pkg-config bash coreutils openssh-client tzdata \
                  libc6-dev libssl-dev
      ;;
    apk)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg tar xz unzip \
                  build-base pkgconfig bash openssh tzdata openssl-dev
      ;;
    dnf)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg2 tar xz unzip \
                  make gcc gcc-c++ glibc-static pkgconfig openssl-devel bash openssh-clients tzdata
      ;;
    yum)
      pkg_update
      pkg_install ca-certificates curl wget git gnupg2 tar xz unzip \
                  make gcc gcc-c++ glibc-static pkgconfig openssl-devel bash openssh-clients tzdata
      ;;
    zypper)
      pkg_update
      pkg_install ca-certificates curl wget git gpg2 tar xz unzip \
                  make gcc gcc-c++ glibc-devel pkg-config libopenssl-devel bash openssh tzdata
      ;;
    *)
      warn "Unknown package manager. Skipping base tools installation."
      ;;
  esac
  update-ca-certificates >/dev/null 2>&1 || true
  log "Base system packages installed."
}

ensure_usr_local_bin() {
  install -d -m 0755 /usr/local/bin
}

create_timeout_wrapper() {
  cat >/usr/local/bin/timeout <<'EOF'
#!/usr/bin/env bash
set -e
REAL_TIMEOUT="/usr/bin/timeout"
if [ ! -x "$REAL_TIMEOUT" ]; then
  REAL_TIMEOUT="$(command -v timeout || true)"
  if [ "$REAL_TIMEOUT" = "/usr/local/bin/timeout" ]; then
    REAL_TIMEOUT="/bin/timeout"
  fi
fi
if [ ! -x "$REAL_TIMEOUT" ]; then
  echo "Real timeout binary not found" >&2
  exit 127
fi
opts=()
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    --) opts+=("$a"); i=$((i+1)); break ;;
    -*) opts+=("$a"); i=$((i+1)) ;;
    *) break ;;
  esac
done
if [ $i -ge ${#args[@]} ]; then
  exec "$REAL_TIMEOUT" "${args[@]}"
fi
duration="${args[$i]}"
i=$((i+1))
remain=("${args[@]:$i}")
if [ ${#remain[@]} -gt 0 ] && [ "${remain[0]}" = "if" ]; then
  cmd_str="${remain[*]}"
  exec "$REAL_TIMEOUT" "${opts[@]}" "$duration" bash -lc "$cmd_str"
else
  exec "$REAL_TIMEOUT" "${args[@]}"
fi
EOF
  chmod +x /usr/local/bin/timeout
}

ensure_bash_present() {
  if ! command -v bash >/dev/null 2>&1 || ! command -v ls >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y --no-install-recommends bash python3 coreutils
    elif command -v apk >/dev/null 2>&1; then
      apk update || true
      apk add --no-cache bash python3 coreutils || apk add --no-cache bash python3
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y bash python3 coreutils
    elif command -v yum >/dev/null 2>&1; then
      yum install -y bash python3 coreutils
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive install -y bash python3 coreutils
    fi
  fi
}

create_if_shim() {
  mkdir -p /usr/local/bin
  cat >/usr/local/bin/if <<'EOF'
#!/bin/sh
# Shim to re-run compound shell constructs under a shell when invoked as a program
if command -v bash >/dev/null 2>&1; then
  exec bash -lc "$*"
else
  exec sh -c "$*"
fi
EOF
  chmod 0755 /usr/local/bin/if
  if [ -x /usr/local/bin/if ] && [ ! -e /usr/bin/if ]; then
    ln -s /usr/local/bin/if /usr/bin/if
  fi
}

create_build_or_die() {
  cat >/usr/local/bin/build-or-die.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    if npm ci; then :; else npm install; fi
    npm run -s build || npm run -s build:prod
  else
    echo "npm not found" >&2; exit 127
  fi
elif [ -f pom.xml ]; then
  if command -v mvn >/dev/null 2>&1; then
    mvn -q -DskipTests package
  else
    echo "maven (mvn) not found" >&2; exit 127
  fi
elif [ -f build.gradle ] || [ -f settings.gradle ]; then
  if [ -x ./gradlew ]; then
    ./gradlew build -x test
  else
    if command -v gradle >/dev/null 2>&1; then
      gradle build -x test
    else
      echo "gradle not found" >&2; exit 127
    fi
  fi
elif [ -f Cargo.toml ]; then
  if command -v cargo >/dev/null 2>&1; then
    cargo build --release
  else
    echo "cargo not found" >&2; exit 127
  fi
elif [ -f pyproject.toml ]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip install -U pip setuptools wheel && python3 -m pip install .
  else
    echo "python3 not found" >&2; exit 127
  fi
elif [ -f requirements.txt ]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip install -U pip setuptools wheel && python3 -m pip install -r requirements.txt
  else
    echo "python3 not found" >&2; exit 127
  fi
else
  echo "No known build configuration files found" >&2
  exit 1
fi
EOF
  chmod 0755 /usr/local/bin/build-or-die.sh
}

create_known_wrapper() {
  # Install a POSIX shell wrapper for 'known' via dpkg-divert at the canonical path
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y bash coreutils
  fi
  if [ -x /usr/bin/known ] && [ ! -L /usr/bin/known ]; then dpkg-divert --local --rename --add /usr/bin/known; fi
  if [ -x /bin/known ] && [ ! -L /bin/known ]; then dpkg-divert --local --rename --add /bin/known; fi
  cat >/usr/bin/known <<'EOF'
#!/bin/sh
set -eu
orig_bin=""
if [ -x /usr/bin/known.distrib ]; then orig_bin=/usr/bin/known.distrib; fi
if [ -z "$orig_bin" ] && [ -x /bin/known.distrib ]; then orig_bin=/bin/known.distrib; fi
if [ "${1:-}" = "-c" ]; then
  payload=${2-}
  payload=$(printf "%s" "$payload" | sed -e 's/^[[:space:]]*//')
  # Tokenize payload
  set -- $payload
  if [ "${1-}" = "timeout" ]; then
    shift
    opts=""
    duration=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -*) opts="$opts $1"; shift ;;
        [0-9]*|*[smhd]) duration="$1"; shift; break ;;
        *) break ;;
      esac
    done
    rest="$*"
    if [ -n "$duration" ] && [ -n "$rest" ]; then
      exec timeout $opts "$duration" bash -lc "$rest"
    fi
  fi
  exec bash -lc "$payload"
else
  if [ -n "$orig_bin" ]; then
    exec "$orig_bin" "$@"
  else
    exec bash "$@"
  fi
fi
EOF
  chmod 0755 /usr/bin/known
  if [ ! -e /bin/known ]; then ln -s /usr/bin/known /bin/known; fi
}

configure_known_shell() {
  install -d -m 0755 /etc/profile.d
  cat >/etc/profile.d/zzz-known.sh <<'EOF'
export PATH=/usr/local/bin:$PATH
export SHELL=/usr/local/bin/known
EOF
  chmod 0644 /etc/profile.d/zzz-known.sh

  # Ensure known is available in /usr/bin and /bin with override precedence
  if [ -x /usr/local/bin/known ]; then
    ln -sf /usr/local/bin/known /usr/bin/known || cp -f /usr/local/bin/known /usr/bin/known
    ln -sf /usr/local/bin/known /bin/known || cp -f /usr/local/bin/known /bin/known
  fi

  # Provide PATH precedence via a dedicated profile.d snippet
  cat >/etc/profile.d/known_path.sh <<'EOF'
export PATH=/usr/local/bin:$PATH
EOF
  chmod 0644 /etc/profile.d/known_path.sh
}

ensure_group_user() {
  log "Ensuring application user and group exist: ${APP_USER} (${APP_UID}) / ${APP_GROUP} (${APP_GID})"
  if ! getent group "${APP_GID}" >/dev/null 2>&1 && ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    if cmd_exists addgroup; then
      addgroup -g "${APP_GID}" "${APP_GROUP}"
    else
      groupadd -g "${APP_GID}" "${APP_GROUP}" 2>/dev/null || true
    fi
  fi
  if ! getent passwd "${APP_UID}" >/dev/null 2>&1 && ! getent passwd "${APP_USER}" >/dev/null 2>&1; then
    if cmd_exists adduser; then
      adduser -D -H -s /bin/bash -G "${APP_GROUP}" -u "${APP_UID}" "${APP_USER}" || true
    else
      useradd -m -s /bin/bash -g "${APP_GROUP}" -u "${APP_UID}" "${APP_USER}" 2>/dev/null || true
    fi
  fi
}

ensure_dirs() {
  log "Configuring application directory: ${APP_DIR}"
  mkdir -p "${APP_DIR}"/{bin,logs,tmp,data}
  chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}"
  chmod -R u+rwX,go-rwx "${APP_DIR}"
}

# --------- Language/runtime specific installers ---------

install_python_stack() {
  log "Setting up Python environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install python3 python3-venv python3-pip python3-dev
      ;;
    apk)
      pkg_install python3 py3-pip python3-dev musl-dev
      ;;
    dnf|yum)
      pkg_install python3 python3-pip python3-devel
      ;;
    zypper)
      pkg_install python3 python3-pip python3-devel
      ;;
    *)
      warn "Could not install Python via package manager. Python setup may fail."
      ;;
  esac

  PY_BIN="python3"
  PIP_BIN="pip3"
  if ! cmd_exists "${PY_BIN}"; then
    die "Python 3 is required but not found."
  fi

  VENV_DIR="${APP_DIR}/.venv"
  if [ ! -x "${VENV_DIR}/bin/python" ]; then
    log "Creating virtual environment at ${VENV_DIR}"
    "${PY_BIN}" -m venv "${VENV_DIR}"
  else
    log "Virtual environment already exists at ${VENV_DIR}"
  fi

  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  python -m pip install --upgrade pip setuptools wheel

  if [ -f "${APP_DIR}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install -r "${APP_DIR}/requirements.txt"
  elif [ -f "${APP_DIR}/pyproject.toml" ]; then
    # Constrain package discovery to avoid picking up non-package dirs like logs/tmp/data
    if [ ! -f "${APP_DIR}/setup.cfg" ]; then
      cat >"${APP_DIR}/setup.cfg" <<'EOF'
[options]
packages = find:

[options.packages.find]
include = bridge*
exclude = tmp* logs* data*
EOF
    fi
    # Fix potential incorrect setuptools config and ensure discovery section exists
    if [ -f "${APP_DIR}/setup.cfg" ]; then
      sed -i -E 's/^(packages[[:space:]]*=[[:space:]]*)find([[:space:]]*)$/\1find:\2/' "${APP_DIR}/setup.cfg" 2>/dev/null || true
      if ! grep -qE "^\[options\.packages\.find\]" "${APP_DIR}/setup.cfg"; then
        printf "\n[options.packages.find]\ninclude = bridge*\nexclude = tmp* logs* data*\n" >> "${APP_DIR}/setup.cfg"
      fi
    fi
    # Clean stale build artifacts before install
    rm -rf "${APP_DIR}/build" "${APP_DIR}/dist" "${APP_DIR}"/*.egg-info
    log "pyproject.toml detected. Attempting PEP 517 build/install."
    pip install --no-cache-dir "file://${APP_DIR}"
  else
    warn "No requirements.txt or pyproject.toml found. Skipping Python dependency installation."
  fi

  # Persist env for interactive shells
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/app_python.sh <<EOF
# Auto-configured by setup script
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export VIRTUAL_ENV="${VENV_DIR}"
export PATH="\$VIRTUAL_ENV/bin:\$PATH"
EOF
  chmod 0644 /etc/profile.d/app_python.sh

  setup_auto_activate "${VENV_DIR}"
  deactivate || true
  log "Python environment configured."
}

install_node_stack() {
  log "Setting up Node.js environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install nodejs npm
      ;;
    apk)
      pkg_install nodejs npm
      ;;
    dnf|yum)
      pkg_install nodejs npm
      ;;
    zypper)
      pkg_install nodejs npm
      ;;
    *)
      warn "Unknown package manager; attempting to proceed if Node is preinstalled."
      ;;
  esac

  if ! cmd_exists node || ! cmd_exists npm; then
    die "Node.js and npm are required but not available after installation."
  fi

  pushd "${APP_DIR}" >/dev/null

  # Prefer lockfile-aware installs
  if [ -f package.json ]; then
    if [ -f yarn.lock ]; then
      log "yarn.lock detected. Installing Yarn and dependencies."
      if cmd_exists corepack; then
        corepack enable || true
        corepack prepare yarn@stable --activate || true
      fi
      if ! cmd_exists yarn; then
        npm install -g yarn
      fi
      yarn install --frozen-lockfile || yarn install
    elif [ -f pnpm-lock.yaml ]; then
      log "pnpm-lock.yaml detected. Installing pnpm and dependencies."
      if cmd_exists corepack; then
        corepack enable || true
        corepack prepare pnpm@latest --activate || true
      fi
      if ! cmd_exists pnpm; then
        npm install -g pnpm
      fi
      pnpm install --frozen-lockfile || pnpm install
    elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
      log "package-lock detected. Running npm ci."
      npm ci
    else
      log "No lockfile detected. Running npm install."
      npm install
    fi
  else
    warn "No package.json found. Skipping Node dependency installation."
  fi

  popd >/dev/null

  mkdir -p /etc/profile.d
  cat >/etc/profile.d/app_node.sh <<EOF
# Auto-configured by setup script
export NODE_ENV="${APP_ENV}"
export PATH="/usr/local/bin:\$PATH"
EOF
  chmod 0644 /etc/profile.d/app_node.sh

  log "Node.js environment configured."
}

install_java_stack() {
  log "Setting up Java environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install openjdk-17-jdk
      ;;
    apk)
      pkg_install openjdk17-jdk
      ;;
    dnf|yum)
      pkg_install java-17-openjdk-devel
      ;;
    zypper)
      pkg_install java-17-openjdk-devel
      ;;
    *)
      warn "Unknown package manager; Java installation skipped."
      ;;
  esac

  if ! cmd_exists java; then
    warn "Java not available; skipping further Java setup."
    return 0
  fi

  # Ensure wrapper scripts are executable if present
  if [ -f "${APP_DIR}/mvnw" ]; then
    chmod +x "${APP_DIR}/mvnw"
  fi
  if [ -f "${APP_DIR}/gradlew" ]; then
    chmod +x "${APP_DIR}/gradlew"
  fi

  mkdir -p /etc/profile.d
  cat >/etc/profile.d/app_java.sh <<'EOF'
# Auto-configured by setup script
export JAVA_TOOL_OPTIONS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=70.0"
EOF
  chmod 0644 /etc/profile.d/app_java.sh

  log "Java environment configured."
}

install_go_stack() {
  log "Setting up Go environment..."
  case "$PKG_MGR" in
    apt)
      pkg_install golang
      ;;
    apk)
      pkg_install go
      ;;
    dnf|yum)
      pkg_install golang
      ;;
    zypper)
      pkg_install go
      ;;
    *)
      warn "Unknown package manager; Go installation skipped."
      ;;
  esac

  if ! cmd_exists go; then
    warn "Go not available; skipping further Go setup."
    return 0
  fi

  mkdir -p /etc/profile.d
  cat >/etc/profile.d/app_go.sh <<'EOF'
# Auto-configured by setup script
export GOPATH="${GOPATH:-/go}"
export GOCACHE="${GOCACHE:-/tmp/go-cache}"
export PATH="$GOPATH/bin:$PATH"
EOF
  chmod 0644 /etc/profile.d/app_go.sh

  log "Go environment configured."
}

# --------- Detection ---------

detect_project_types() {
  PROJECT_TYPES=()

  if [ -f "${APP_DIR}/requirements.txt" ] || [ -f "${APP_DIR}/pyproject.toml" ] || [ -f "${APP_DIR}/setup.py" ]; then
    PROJECT_TYPES+=("python")
  fi

  if [ -f "${APP_DIR}/package.json" ]; then
    PROJECT_TYPES+=("node")
  fi

  if [ -f "${APP_DIR}/pom.xml" ] || [ -f "${APP_DIR}/build.gradle" ] || [ -f "${APP_DIR}/build.gradle.kts" ] || [ -f "${APP_DIR}/mvnw" ] || [ -f "${APP_DIR}/gradlew" ]; then
    PROJECT_TYPES+=("java")
  fi

  if [ -f "${APP_DIR}/go.mod" ] || [ -f "${APP_DIR}/main.go" ]; then
    PROJECT_TYPES+=("go")
  fi

  if [ "${#PROJECT_TYPES[@]}" -eq 0 ]; then
    warn "No recognizable project files found in ${APP_DIR}. Installing only base tools."
  else
    log "Detected project types: ${PROJECT_TYPES[*]}"
  fi
}

configure_env_files() {
  log "Writing environment defaults..."
  mkdir -p /etc/profile.d

  cat >/etc/profile.d/app_base.sh <<EOF
# Auto-configured by setup script
export APP_HOME="${APP_DIR}"
export APP_ENV="${APP_ENV}"
export PATH="\$APP_HOME/bin:\$PATH"
umask 0027
EOF
  chmod 0644 /etc/profile.d/app_base.sh

  # Create .env if not present (non-secret defaults)
  if [ ! -f "${APP_DIR}/.env" ]; then
    cat >"${APP_DIR}/.env" <<EOF
# Generated by setup script
APP_ENV=${APP_ENV}
LOG_LEVEL=info
EOF
    chown "${APP_UID}:${APP_GID}" "${APP_DIR}/.env"
    chmod 0640 "${APP_DIR}/.env"
  fi
}

print_summary() {
  log "Setup complete."
  echo "Summary:"
  echo " - APP_DIR: ${APP_DIR}"
  echo " - APP_USER/GROUP: ${APP_USER}:${APP_GROUP} (UID:GID ${APP_UID}:${APP_GID})"
  echo " - Project types: ${PROJECT_TYPES[*]:-none}"
  echo " - Subdirectories: bin/, logs/, tmp/, data/"
  echo
  echo "Environment will be loaded for login shells from /etc/profile.d/*.sh"
  echo "To use within this shell session, you can source them:"
  echo "  source /etc/profile.d/app_base.sh || true"
  echo "  [ -f /etc/profile.d/app_python.sh ] && source /etc/profile.d/app_python.sh || true"
  echo "  [ -f /etc/profile.d/app_node.sh ] && source /etc/profile.d/app_node.sh || true"
  echo "  [ -f /etc/profile.d/app_java.sh ] && source /etc/profile.d/app_java.sh || true"
  echo "  [ -f /etc/profile.d/app_go.sh ] && source /etc/profile.d/app_go.sh || true"
}

main() {
  require_root
  detect_os
  detect_pkg_manager
  install_base_tools
  ensure_bash_present
  ensure_usr_local_bin
  create_build_or_die
  create_known_wrapper
  configure_known_shell
  create_if_shim
  create_timeout_wrapper
  ensure_group_user
  ensure_dirs
  detect_project_types

  # Install stacks based on detection
  for t in "${PROJECT_TYPES[@]:-}"; do
    case "$t" in
      python) install_python_stack ;;
      node)   install_node_stack ;;
      java)   install_java_stack ;;
      go)     install_go_stack ;;
    esac
  done

  # Make common entry scripts executable if present
  [ -f "${APP_DIR}/entrypoint.sh" ] && chmod +x "${APP_DIR}/entrypoint.sh" || true
  [ -f "${APP_DIR}/start.sh" ] && chmod +x "${APP_DIR}/start.sh" || true

  configure_env_files

  # Set ownership at the end to reduce permission flips during install
  chown -R "${APP_UID}:${APP_GID}" "${APP_DIR}"

  print_summary
}

main "$@"