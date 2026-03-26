#!/usr/bin/env bash
# Environment setup script for containerized projects
# This script detects the project's tech stack and installs the required runtimes,
# system packages, dependencies, and configures the environment for Docker containers.

set -Eeuo pipefail

# Safe IFS
IFS=$' \n\t'

# Colors for output (no-op if not a TTY)
if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

umask 022

# Ensure HOME is set to a sane default to avoid writing to "/.profile"
: "${HOME:=/root}"

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err()  { echo "${RED}[ERROR] $*${NC}" >&2; }

on_error() {
  local exit_code=$?
  err "Setup failed at line ${BASH_LINENO[0]} (exit code ${exit_code})."
  exit "${exit_code}"
}
trap on_error ERR

# Detect package manager
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CLEAN=""
PKG_HAS_NONINTERACTIVE=0

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    PKG_UPDATE="apt-get update -y -o Acquire::Retries=3"
    PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
    PKG_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
    PKG_HAS_NONINTERACTIVE=1
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add --no-cache"
    PKG_CLEAN="true"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf -y update || true"
    PKG_INSTALL="dnf -y install"
    PKG_CLEAN="dnf clean all"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum -y update || true"
    PKG_INSTALL="yum -y install"
    PKG_CLEAN="yum clean all"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    PKG_UPDATE="pacman -Sy --noconfirm"
    PKG_INSTALL="pacman -S --noconfirm --needed"
    PKG_CLEAN="pacman -Scc --noconfirm || true"
  else
    warn "No supported package manager detected. System dependencies may not be installed."
    PKG_MANAGER=""
  fi
}

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

install_packages() {
  # Usage: install_packages pkg1 pkg2 ...
  [ -z "${PKG_MANAGER}" ] && { warn "Package manager not available. Skipping install of: $*"; return 0; }
  is_root || { warn "Not running as root. Cannot install: $*"; return 0; }
  log "Installing system packages: $*"
  if [ "${PKG_MANAGER}" = "apt" ]; then
    tee /etc/apt/apt.conf.d/99-fix-apt >/dev/null <<'EOF'
Acquire::Retries "5";
Acquire::PDiffs "false";
Acquire::http::No-Cache "true";
Acquire::https::No-Cache "true";
Acquire::ForceIPv4 "true";
EOF
    ( rm -rf /var/lib/apt/lists/* && apt-get clean && apt-get update -o Acquire::Retries=5 -o Acquire::http::No-Cache=true ) || ( for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do [ -f "$f" ] && sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.kernel.org/ubuntu|g' "$f"; done; apt-get update -o Acquire::Retries=5 -o Acquire::http::No-Cache=true )
  else
    eval "${PKG_UPDATE}"
  fi
  # shellcheck disable=SC2086
  eval "${PKG_INSTALL} $@"
  eval "${PKG_CLEAN}"
}

install_base_tools() {
  case "${PKG_MANAGER}" in
    apt)
      install_packages ca-certificates curl git bash coreutils tar gzip unzip xz-utils build-essential pkg-config gnupg
      update-ca-certificates || true
      ;;
    apk)
      install_packages ca-certificates curl git bash coreutils tar gzip unzip xz build-base pkgconfig
      update-ca-certificates || true
      ;;
    dnf|yum)
      install_packages ca-certificates curl git bash coreutils tar gzip unzip xz which gcc gcc-c++ make pkgconfig
      ;;
    pacman)
      install_packages ca-certificates curl git bash coreutils tar gzip unzip xz which base-devel pkgconf
      ;;
    *)
      warn "Skipping base tools installation due to unsupported package manager."
      ;;
  esac
}

# Helpers
has_file() { [ -f "$1" ]; }
has_dir() { [ -d "$1" ]; }
exists() { command -v "$1" >/dev/null 2>&1; }
nproc_safe() { command -v nproc >/dev/null 2>&1 && nproc || echo 2; }
append_line_once() {
  # append_line_once "file" "line"
  local file="$1"; shift
  local line="$*"
  [ -f "${file}" ] || touch "${file}" || true
  if ! grep -Fqx "${line}" "${file}" 2>/dev/null; then
    echo "${line}" >> "${file}" || true
  fi
}

# Project directory detection
detect_project_dir() {
  if [ -n "${PROJECT_DIR:-}" ]; then
    :
  elif has_dir "/workspace"; then
    PROJECT_DIR="/workspace"
  elif has_dir "/app"; then
    PROJECT_DIR="/app"
  else
    PROJECT_DIR="$PWD"
  fi
  export PROJECT_DIR
  # Ensure ENV_FILE points into the project directory
  ENV_FILE="${PROJECT_DIR}/.env"
  export ENV_FILE
  log "Using project directory: ${PROJECT_DIR}"
}

ensure_permissions() {
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"
  mkdir -p "${PROJECT_DIR}"
  # Do not chown root-owned system dirs inadvertently; only project
  if is_root; then
    chown -R "${uid}:${gid}" "${PROJECT_DIR}" || true
  fi
  chmod -R u+rwX,go+rX "${PROJECT_DIR}" || true
}

harden_env_targets() {
  local proj="${PROJECT_DIR}"
  # Pre-create project-scoped home and env files to ensure writability
  mkdir -p "${proj}/.home" "${proj}" || true
  touch "${proj}/.env" "${proj}/.home/.profile" "${proj}/.home/.bashrc" || true
  chmod 0644 "${proj}/.env" "${proj}/.home/.profile" "${proj}/.home/.bashrc" || true
  # Ensure HOME is writable; if not, relocate to project-scoped home
  if [ -z "${HOME:-}" ] || [ ! -w "${HOME:-}" ] || { [ "$(id -u)" -ne 0 ] && [ "${HOME:-/root}" = "/root" ]; }; then
    export HOME="${proj}/.home"
  fi
  mkdir -p "${HOME}" || true
  touch "${HOME}/.profile" "${HOME}/.bashrc" || true
  chmod 0644 "${HOME}/.profile" "${HOME}/.bashrc" || true
  # Keep PROFILE_FILE_USER in sync with potentially updated HOME
  PROFILE_FILE_USER="${HOME}/.profile"
  if [ "$(id -u)" -eq 0 ]; then mkdir -p /etc/profile.d && touch /etc/profile.d/project_env.sh && chmod 0644 /etc/profile.d/project_env.sh || true; fi
}

# Environment persistence
ENV_FILE="${PROJECT_DIR:-.}/.env"
PROFILE_DIR_SYS="/etc/profile.d"
PROFILE_FILE_SYS="${PROFILE_DIR_SYS}/project_env.sh"
PROFILE_FILE_USER="${HOME}/.profile"

persist_env_var() {
  # persist_env_var VAR VALUE
  local var="$1" val="$2"
  mkdir -p "${PROJECT_DIR}" || true
  touch "${ENV_FILE}" || true
  # .env
  if ! grep -q "^${var}=" "${ENV_FILE}" 2>/dev/null; then
    echo "${var}=${val}" >> "${ENV_FILE}" || true
  fi
  # profile.d or user profile
  local target
  if is_root && [ -d "${PROFILE_DIR_SYS}" ]; then
    target="${PROFILE_FILE_SYS}"
  else
    target="${HOME}/.profile"
  fi
  touch "${target}" || true
  append_line_once "${target}" "export ${var}=${val}" || true
}

persist_path_prepend() {
  # persist_path_prepend /path/to/bin
  local dir="$1"
  [ -d "${dir}" ] || return 0
  local export_line="export PATH=${dir}:\$PATH"
  if is_root && [ -d "${PROFILE_DIR_SYS}" ]; then
    append_line_once "${PROFILE_FILE_SYS}" "${export_line}" || true
  else
    append_line_once "${HOME}/.profile" "${export_line}" || true
  fi
}

setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_path=""
  if [ -f "${PROJECT_DIR}/.venv/bin/activate" ]; then
    activate_path="${PROJECT_DIR}/.venv/bin/activate"
  elif [ -f "/app/.venv/bin/activate" ]; then
    activate_path="/app/.venv/bin/activate"
  elif [ -f "/workspace/.venv/bin/activate" ]; then
    activate_path="/workspace/.venv/bin/activate"
  fi
  if [ -n "${activate_path}" ]; then
    local activate_line="source ${activate_path}"
    if ! grep -qF "${activate_line}" "${bashrc_file}" 2>/dev/null; then
      echo "" >> "${bashrc_file}" || true
      echo "# Auto-activate Python virtual environment" >> "${bashrc_file}" || true
      echo "${activate_line}" >> "${bashrc_file}" || true
    fi
  fi
}

# Language-specific setup functions

install_dos2unix() {
  if ! command -v dos2unix >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y dos2unix; elif command -v yum >/dev/null 2>&1; then yum install -y dos2unix; elif command -v apk >/dev/null 2>&1; then apk add --no-cache dos2unix; fi
  fi
}

normalize_shell_line_endings() {
  if command -v dos2unix >/dev/null 2>&1; then
    find "${PROJECT_DIR}" -type f -name "*.sh" -print0 | xargs -0 -r dos2unix -f || true
  fi
}

write_ci_build_script() {
  local outfile="${PROJECT_DIR}/.ci_build.sh"
  cat > "${outfile}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# normalize CRLF endings in common build files
for f in package.json pom.xml gradlew build.gradle Cargo.toml pyproject.toml requirements.txt; do
  [ -f "$f" ] || continue
  sed -i 's/\r$//' "$f" || true
done
if [ -f package.json ]; then
  npm ci --no-audit --no-fund
  npm run -s build
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew build -x test
elif [ -f build.gradle ]; then
  gradle build -x test
elif [ -f Cargo.toml ]; then
  cargo build --release
elif [ -f pyproject.toml ]; then
  pip install -e .
elif [ -f requirements.txt ]; then
  pip install -r requirements.txt
else
  echo 'No known build system detected'
fi
EOF
  sed -i 's/\r$//' "${outfile}" || true
  chmod +x "${outfile}"
}

write_build_dispatch_script() {
  local outfile="${PROJECT_DIR}/build-dispatch.sh"
  cat > "${outfile}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Normalize potential CRLF in common build manifests/wrappers
for f in package.json pom.xml gradlew build.gradle Cargo.toml pyproject.toml requirements.txt; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" || true
done
if [ -f package.json ]; then
  npm ci && npm run -s build
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew build -x test
elif [ -f build.gradle ]; then
  gradle build -x test
elif [ -f Cargo.toml ]; then
  cargo build --release
elif [ -f pyproject.toml ]; then
  pip install -e .
elif [ -f requirements.txt ]; then
  pip install -r requirements.txt
else
  echo 'No known build system detected'
fi
EOF
  sed -i 's/\r$//' "${outfile}" || true
  chmod +x "${outfile}"
}

write_ci_dir_build_dispatch_script() {
  local dir="${PROJECT_DIR}/.ci"
  mkdir -p "${dir}"
  local outfile="${dir}/build_dispatch.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'for f in package.json pom.xml gradlew build.gradle Cargo.toml pyproject.toml requirements.txt; do' \
    '  if [ -f "$f" ]; then' \
    '    sed -i '\''s/\r$//'\'' "$f" || true' \
    '  fi' \
    'done' \
    '' \
    'if [ -f package.json ]; then' \
    '  npm ci --no-audit --no-fund && npm run -s build' \
    'elif [ -f pom.xml ]; then' \
    '  mvn -q -DskipTests package' \
    'elif [ -f gradlew ]; then' \
    '  chmod +x gradlew && ./gradlew build -x test' \
    'elif [ -f build.gradle ]; then' \
    '  gradle build -x test' \
    'elif [ -f Cargo.toml ]; then' \
    '  cargo build --release' \
    'elif [ -f pyproject.toml ]; then' \
    '  pip install -e .' \
    'elif [ -f requirements.txt ]; then' \
    '  pip install -r requirements.txt' \
    'else' \
    '  echo '\''No known build system detected'\''' \
    'fi' > "${outfile}"
  sed -i 's/\r$//' "${outfile}" || true
  chmod +x "${outfile}" || true
}

write_root_ci_build_script() {
  local outfile="${PROJECT_DIR}/ci_build.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'normalize() { for f in "$@"; do [ -f "$f" ] && sed -i "s/\r$//" "$f" || true; done }' \
    'normalize package.json pom.xml gradlew build.gradle Cargo.toml pyproject.toml requirements.txt' \
    'if [ -f package.json ]; then' \
    '  npm ci --no-audit --fund=false --quiet' \
    '  npm run -s build' \
    'elif [ -f pom.xml ]; then' \
    '  mvn -q -DskipTests package' \
    'elif [ -f gradlew ]; then' \
    '  chmod +x gradlew' \
    '  ./gradlew build -x test' \
    'elif [ -f build.gradle ]; then' \
    '  gradle build -x test' \
    'elif [ -f Cargo.toml ]; then' \
    '  cargo build --release' \
    'elif [ -f pyproject.toml ]; then' \
    '  pip install -e .' \
    'elif [ -f requirements.txt ]; then' \
    '  pip install -r requirements.txt' \
    'else' \
    '  echo "No known build system detected"' \
    'fi' > "${outfile}"
  chmod +x "${outfile}" && sed -i 's/\r$//' "${outfile}" || true
}

write_root_build_dispatch_script() {
  local outfile="${PROJECT_DIR}/build_dispatch.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [ -f package.json ]; then' \
    '  if command -v npm >/dev/null 2>&1; then npm ci && npm run -s build; else echo "npm not found"; exit 127; fi' \
    'elif [ -f pom.xml ]; then' \
    '  if command -v mvn >/dev/null 2>&1; then mvn -q -DskipTests package; else echo "maven (mvn) not found"; exit 127; fi' \
    'elif [ -f gradlew ]; then' \
    '  chmod +x gradlew && ./gradlew build -x test' \
    'elif [ -f build.gradle ]; then' \
    '  if command -v gradle >/dev/null 2>&1; then gradle build -x test; else echo "gradle not found"; exit 127; fi' \
    'elif [ -f Cargo.toml ]; then' \
    '  if command -v cargo >/dev/null 2>&1; then cargo build --release; else echo "cargo not found"; exit 127; fi' \
    'elif [ -f pyproject.toml ]; then' \
    '  if command -v pip >/dev/null 2>&1; then pip install -e .; else echo "pip not found"; exit 127; fi' \
    'elif [ -f requirements.txt ]; then' \
    '  if command -v pip >/dev/null 2>&1; then pip install -r requirements.txt; else echo "pip not found"; exit 127; fi' \
    'else' \
    '  echo "No known build system detected"' \
    'fi' > "${outfile}"
  chmod +x "${outfile}" || true
}

write_run_build_script() {
  local outfile="${PROJECT_DIR}/run_build.sh"
  printf '%s
' '#!/usr/bin/env sh' 'set -e' 'if command -v dos2unix >/dev/null 2>&1; then dos2unix -q package.json pom.xml gradlew build.gradle Cargo.toml pyproject.toml requirements.txt 2>/dev/null || true; fi' 'if [ -f package.json ]; then' '  if command -v npm >/dev/null 2>&1; then npm ci && npm run -s build; elif command -v yarn >/dev/null 2>&1; then yarn install --frozen-lockfile && yarn build; else echo "No Node.js package manager (npm/yarn) found." >&2; exit 1; fi' 'elif [ -f pom.xml ]; then' '  mvn -q -DskipTests package' 'elif [ -f gradlew ]; then' '  chmod +x gradlew' '  ./gradlew build -x test' 'elif [ -f build.gradle ]; then' '  gradle build -x test' 'elif [ -f Cargo.toml ]; then' '  cargo build --release' 'elif [ -f pyproject.toml ]; then' '  pip install -e .' 'elif [ -f requirements.txt ]; then' '  pip install -r requirements.txt' 'else' '  echo "No known build system detected"' 'fi' > "${outfile}"
  chmod +x "${outfile}" || true
}

write_dot_ci_hyphen_build_script() {
  local outfile="${PROJECT_DIR}/.ci-build.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if command -v dos2unix >/dev/null 2>&1; then' \
    '  dos2unix -q package.json pom.xml gradlew build.gradle Cargo.toml pyproject.toml requirements.txt 2>/dev/null || true' \
    'fi' \
    'if [ -f package.json ]; then' \
    '  npm ci && npm run -s build' \
    'elif [ -f pom.xml ]; then' \
    '  mvn -q -DskipTests package' \
    'elif [ -f gradlew ]; then' \
    '  chmod +x gradlew && ./gradlew build -x test' \
    'elif [ -f build.gradle ]; then' \
    '  gradle build -x test' \
    'elif [ -f Cargo.toml ]; then' \
    '  cargo build --release' \
    'elif [ -f pyproject.toml ]; then' \
    '  pip install -e .' \
    'elif [ -f requirements.txt ]; then' \
    '  pip install -r requirements.txt' \
    'else' \
    '  echo "No known build system detected"' \
    'fi' > "${outfile}"
  chmod +x "${outfile}" || true
}

setup_python() {
  log "Detected Python project"
  case "${PKG_MANAGER}" in
    apt)
      install_packages python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev
      ;;
    apk)
      install_packages python3 py3-pip python3-dev musl-dev libffi-dev openssl-dev
      ;;
    dnf|yum)
      install_packages python3 python3-pip python3-devel gcc gcc-c++ make libffi-devel openssl-devel
      ;;
    pacman)
      install_packages python python-pip base-devel openssl libffi
      ;;
    *)
      warn "Cannot install Python system packages automatically."
      ;;
  esac

  export PIP_NO_CACHE_DIR=1
  export PYTHONDONTWRITEBYTECODE=1
  persist_env_var PYTHONUNBUFFERED 1

  # Optional: install database/client headers based on requirements
  if has_file "${PROJECT_DIR}/requirements.txt"; then
    if grep -Eiq 'psycopg2|psycopg\[.*\]|psycopg-binary' "${PROJECT_DIR}/requirements.txt"; then
      case "${PKG_MANAGER}" in
        apt) install_packages libpq-dev ;;
        apk) install_packages postgresql-dev ;;
        dnf|yum) install_packages postgresql-devel ;;
        pacman) install_packages postgresql-libs ;;
      esac
    fi
    if grep -Eiq 'mysqlclient' "${PROJECT_DIR}/requirements.txt"; then
      case "${PKG_MANAGER}" in
        apt) install_packages default-libmysqlclient-dev ;;
        apk) install_packages mariadb-connector-c-dev ;;
        dnf|yum) install_packages mariadb-connector-c-devel ;;
        pacman) install_packages mariadb-libs ;;
      esac
    fi
  fi

  # Create venv
  if [ ! -d "${PROJECT_DIR}/.venv" ]; then
    log "Creating virtual environment at ${PROJECT_DIR}/.venv"
    python3 -m venv "${PROJECT_DIR}/.venv"
  else
    log "Virtual environment already exists"
  fi
  # Use venv tools explicitly to avoid PATH/activation ambiguity
  "${PROJECT_DIR}/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
  # Repair venv pip/entry-point permissions and regenerate scripts if needed
  for d in "${PROJECT_DIR}/.venv/bin" "/app/.venv/bin" "/workspace/.venv/bin" "$PWD/.venv/bin"; do if [ -d "$d" ]; then find "$d" -maxdepth 1 -type f -exec chmod 0755 {} +; fi; done
  for py in "${PROJECT_DIR}/.venv/bin/python" "/app/.venv/bin/python" "/workspace/.venv/bin/python" "$PWD/.venv/bin/python"; do if [ -x "$py" ]; then "$py" -m pip install --no-cache-dir --force-reinstall --upgrade pip setuptools wheel; fi; done

  # Install dependencies
  if has_file "${PROJECT_DIR}/requirements.txt"; then
    log "Installing Python dependencies from requirements.txt"
    "${PROJECT_DIR}/.venv/bin/python" -m pip install -r "${PROJECT_DIR}/requirements.txt"
  elif has_file "${PROJECT_DIR}/pyproject.toml"; then
    if grep -Eiq '\[tool.poetry\]' "${PROJECT_DIR}/pyproject.toml"; then
      log "Poetry project detected"
      "${PROJECT_DIR}/.venv/bin/pip" install "poetry>=1.5"
      (cd "${PROJECT_DIR}" && "${PROJECT_DIR}/.venv/bin/poetry" config virtualenvs.create false && "${PROJECT_DIR}/.venv/bin/poetry" install --no-interaction --no-ansi --no-root || "${PROJECT_DIR}/.venv/bin/poetry" install --no-interaction --no-ansi)
    else
      log "PEP 517/518 project detected; attempting pip install -e ."
      "${PROJECT_DIR}/.venv/bin/python" -m pip install -e "${PROJECT_DIR}" || "${PROJECT_DIR}/.venv/bin/python" -m pip install "${PROJECT_DIR}"
    fi
  else
    log "No Python dependency file found"
  fi

  persist_env_var PIP_NO_CACHE_DIR 1 || true
  persist_env_var PYTHONDONTWRITEBYTECODE 1 || true
  persist_path_prepend "${PROJECT_DIR}/.venv/bin"

  # Common app defaults
  [ -z "${PORT:-}" ] && persist_env_var PORT 8000 || true
}

setup_node() {
  log "Detected Node.js project"
  case "${PKG_MANAGER}" in
    apt)
      install_packages nodejs npm build-essential python3 make g++
      ;;
    apk)
      install_packages nodejs npm python3 make g++ build-base
      ;;
    dnf|yum)
      install_packages nodejs npm gcc gcc-c++ make python3
      ;;
    pacman)
      install_packages nodejs npm base-devel python
      ;;
    *)
      warn "Cannot install Node.js system packages automatically."
      ;;
  esac

  # NPM configs to be non-interactive and deterministic
  npm config set fund false >/dev/null 2>&1 || true
  npm config set audit false >/dev/null 2>&1 || true
  npm config set prefer-offline true >/dev/null 2>&1 || true

  if has_file "${PROJECT_DIR}/package-lock.json"; then
    log "Installing Node.js dependencies via npm ci"
    (cd "${PROJECT_DIR}" && npm ci --no-progress)
  elif has_file "${PROJECT_DIR}/package.json"; then
    log "Installing Node.js dependencies via npm install"
    (cd "${PROJECT_DIR}" && npm install --no-progress)
  else
    warn "No package.json found for Node project"
  fi

  persist_env_var NODE_ENV production
  persist_path_prepend "${PROJECT_DIR}/node_modules/.bin"

  # Default port for Node
  [ -z "${PORT:-}" ] && persist_env_var PORT 3000 || true
}

setup_ruby() {
  log "Detected Ruby project"
  case "${PKG_MANAGER}" in
    apt) install_packages ruby-full build-essential zlib1g-dev ;;
    apk) install_packages ruby ruby-dev build-base zlib-dev ;;
    dnf|yum) install_packages ruby ruby-devel gcc gcc-c++ make zlib-devel ;;
    pacman) install_packages ruby base-devel zlib ;;
    *) warn "Cannot install Ruby system packages automatically." ;;
  esac

  if ! exists bundle; then
    gem install bundler -N
  fi

  mkdir -p "${PROJECT_DIR}"
  (cd "${PROJECT_DIR}" && bundle config set --local path 'vendor/bundle' && bundle install --jobs "$(nproc_safe)" --retry 3)

  persist_env_var RACK_ENV production
  persist_env_var RAILS_ENV production
  persist_path_prepend "${PROJECT_DIR}/bin"
  [ -z "${PORT:-}" ] && persist_env_var PORT 3000
}

setup_java() {
  log "Detected Java project"
  case "${PKG_MANAGER}" in
    apt) install_packages openjdk-17-jdk maven ;;
    apk) install_packages openjdk17 maven ;;
    dnf|yum) install_packages java-17-openjdk java-17-openjdk-devel maven ;;
    pacman) install_packages jdk17-openjdk maven ;;
    *) warn "Cannot install Java system packages automatically." ;;
  esac

  export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac || command -v java || echo /usr/lib/jvm/java-17-openjdk/bin/java)")")")" || true
  [ -n "${JAVA_HOME:-}" ] && persist_env_var JAVA_HOME "${JAVA_HOME}"

  if has_file "${PROJECT_DIR}/mvnw"; then
    chmod +x "${PROJECT_DIR}/mvnw"
    (cd "${PROJECT_DIR}" && ./mvnw -q -DskipTests dependency:go-offline || true)
  elif has_file "${PROJECT_DIR}/pom.xml"; then
    (cd "${PROJECT_DIR}" && mvn -q -DskipTests dependency:go-offline || true)
  fi

  if has_file "${PROJECT_DIR}/gradlew"; then
    chmod +x "${PROJECT_DIR}/gradlew"
    (cd "${PROJECT_DIR}" && ./gradlew --no-daemon build -x test || ./gradlew --no-daemon tasks || true)
  elif has_file "${PROJECT_DIR}/build.gradle" || has_file "${PROJECT_DIR}/settings.gradle"; then
    case "${PKG_MANAGER}" in
      apt) install_packages gradle ;;
      apk) install_packages gradle ;;
      dnf|yum) install_packages gradle ;;
      pacman) install_packages gradle ;;
    esac
    (cd "${PROJECT_DIR}" && gradle --no-daemon build -x test || true)
  fi

  [ -z "${PORT:-}" ] && persist_env_var PORT 8080
}

setup_go() {
  log "Detected Go project"
  case "${PKG_MANAGER}" in
    apt) install_packages golang ;;
    apk) install_packages go ;;
    dnf|yum) install_packages golang ;;
    pacman) install_packages go ;;
    *) warn "Cannot install Go system packages automatically." ;;
  esac

  if exists go; then
    (cd "${PROJECT_DIR}" && go mod download || true)
    persist_path_prepend "$(go env GOPATH)/bin"
  fi
  [ -z "${PORT:-}" ] && persist_env_var PORT 8080
}

setup_rust() {
  log "Detected Rust project"
  case "${PKG_MANAGER}" in
    apt) install_packages cargo rustc ;;
    apk) install_packages cargo rust ;;
    dnf|yum) install_packages cargo rust ;;
    pacman) install_packages rust ;;
    *) warn "Cannot install Rust system packages automatically." ;;
  esac

  if exists cargo; then
    (cd "${PROJECT_DIR}" && cargo fetch || true)
  fi
  [ -z "${PORT:-}" ] && persist_env_var PORT 8080
}

setup_php() {
  log "Detected PHP project"
  case "${PKG_MANAGER}" in
    apt) install_packages php-cli php-mbstring php-xml php-curl php-zip unzip ;;
    apk) install_packages php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip unzip || install_packages php php-cli php-mbstring php-xml php-curl php-zip unzip ;;
    dnf|yum) install_packages php-cli php-mbstring php-xml php-common php-json php-zip unzip ;;
    pacman) install_packages php php-zip php-curl php-xml unzip ;;
    *) warn "Cannot install PHP system packages automatically." ;;
  esac

  if ! exists composer; then
    log "Installing Composer"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi

  if has_file "${PROJECT_DIR}/composer.json"; then
    (cd "${PROJECT_DIR}" && composer install --no-interaction --prefer-dist || true)
  fi

  [ -z "${PORT:-}" ] && persist_env_var PORT 8080
}

setup_dotnet() {
  log "Detected .NET project"
  if exists dotnet; then
    (cd "${PROJECT_DIR}" && find . -maxdepth 2 -name '*.sln' -print -quit | grep -q . && dotnet restore || true)
    (cd "${PROJECT_DIR}" && find . -maxdepth 2 -name '*.csproj' -print -quit | grep -q . && dotnet restore || true)
    [ -z "${ASPNETCORE_URLS:-}" ] && persist_env_var ASPNETCORE_URLS "http://0.0.0.0:8080"
    [ -z "${PORT:-}" ] && persist_env_var PORT 8080
  else
    warn ".NET SDK not found. Please use a dotnet SDK base image or install manually."
  fi
}

# Project type detection
detect_project_type() {
  if has_file "${PROJECT_DIR}/package.json"; then
    PROJECT_TYPE="node"
  elif has_file "${PROJECT_DIR}/requirements.txt" || has_file "${PROJECT_DIR}/pyproject.toml"; then
    PROJECT_TYPE="python"
  elif has_file "${PROJECT_DIR}/Gemfile"; then
    PROJECT_TYPE="ruby"
  elif has_file "${PROJECT_DIR}/pom.xml" || has_file "${PROJECT_DIR}/build.gradle" || has_file "${PROJECT_DIR}/gradlew" || has_file "${PROJECT_DIR}/mvnw"; then
    PROJECT_TYPE="java"
  elif has_file "${PROJECT_DIR}/go.mod"; then
    PROJECT_TYPE="go"
  elif has_file "${PROJECT_DIR}/Cargo.toml"; then
    PROJECT_TYPE="rust"
  elif has_file "${PROJECT_DIR}/composer.json"; then
    PROJECT_TYPE="php"
  elif find "${PROJECT_DIR}" -maxdepth 2 -name '*.csproj' | grep -q .; then
    PROJECT_TYPE="dotnet"
  else
    PROJECT_TYPE="unknown"
  fi
  export PROJECT_TYPE
  log "Project type: ${PROJECT_TYPE}"
}

# Generic environment defaults
set_generic_env() {
  persist_env_var APP_ENV production || true
  persist_env_var LANG C.UTF-8 || true
  persist_env_var LC_ALL C.UTF-8 || true
  [ -z "${PORT:-}" ] && persist_env_var PORT 8080 || true
}

# Main
main() {
  detect_pkg_manager
  detect_project_dir
  harden_env_targets
  ensure_permissions
  install_base_tools
  install_dos2unix
  normalize_shell_line_endings
  write_ci_build_script
  write_build_dispatch_script
  write_ci_dir_build_dispatch_script
  write_root_ci_build_script
  write_root_build_dispatch_script
  write_run_build_script
  write_dot_ci_hyphen_build_script

  case "${PROJECT_TYPE:-}" in
    "") detect_project_type ;;
  esac

  case "${PROJECT_TYPE}" in
    python) setup_python ;;
    node)   setup_node ;;
    ruby)   setup_ruby ;;
    java)   setup_java ;;
    go)     setup_go ;;
    rust)   setup_rust ;;
    php)    setup_php ;;
    dotnet) setup_dotnet ;;
    *)
      warn "Unable to detect project type automatically."
      warn "You can set PROJECT_TYPE env var to one of: python, node, ruby, java, go, rust, php, dotnet and re-run."
      ;;
  esac

  set_generic_env

  setup_auto_activate

  # Execute root-level ci_build.sh generated via printf to avoid inline parsing issues
  if [ -f "${PROJECT_DIR}/ci_build.sh" ]; then
    (cd "${PROJECT_DIR}" && bash ./ci_build.sh) || true
  fi

  # Execute generated CI build script to avoid inline parsing issues
  if [ -f "${PROJECT_DIR}/.ci_build.sh" ]; then
    (cd "${PROJECT_DIR}" && bash ./.ci_build.sh) || true
  fi

  # Execute hyphenated .ci-build.sh created via printf
  if [ -f "${PROJECT_DIR}/.ci-build.sh" ]; then
    (cd "${PROJECT_DIR}" && bash ./.ci-build.sh) || true
  fi

  # Execute build dispatcher script (hyphenated legacy)
  if [ -f "${PROJECT_DIR}/build-dispatch.sh" ]; then
    (cd "${PROJECT_DIR}" && ./build-dispatch.sh) || true
  fi

  # Execute root build dispatcher script (underscore, created via printf)
  if [ -f "${PROJECT_DIR}/build_dispatch.sh" ]; then
    (cd "${PROJECT_DIR}" && ./build_dispatch.sh) || true
  fi

  # Execute .ci/build_dispatch.sh if present (generated via printf to avoid quoting issues)
  if [ -f "${PROJECT_DIR}/.ci/build_dispatch.sh" ]; then
    (cd "${PROJECT_DIR}" && bash ./.ci/build_dispatch.sh) || true
  fi

  # Execute run_build.sh created from repair commands
  if [ -f "${PROJECT_DIR}/run_build.sh" ]; then
    (cd "${PROJECT_DIR}" && ./run_build.sh) || true
  fi

  # Ensure common bin paths available
  persist_path_prepend "${PROJECT_DIR}/.local/bin"
  [ -d "${PROJECT_DIR}/node_modules/.bin" ] && persist_path_prepend "${PROJECT_DIR}/node_modules/.bin"

  # Execute run_build.sh created from repair commands
  if [ -f "${PROJECT_DIR}/run_build.sh" ]; then
    (cd "${PROJECT_DIR}" && ./run_build.sh) || true
  fi

  # Final hints
  log "Environment setup completed."
  log "Persisted environment in: ${ENV_FILE}"
  if is_root && [ -d "${PROFILE_DIR_SYS}" ]; then
    log "Profile configuration written to: ${PROFILE_FILE_SYS}"
  else
    log "Profile configuration written to: ${PROFILE_FILE_USER}"
  fi
  log "To load environment variables in current shell: set -a; [ -f \"${ENV_FILE}\" ] && . \"${ENV_FILE}\"; set +a"
}

main "$@"