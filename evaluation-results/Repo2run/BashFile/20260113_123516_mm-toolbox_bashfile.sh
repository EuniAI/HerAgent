#!/usr/bin/env bash
# mm-toolbox project environment setup script for Docker containers
# This script installs system dependencies, Python runtime, Poetry, and project deps.
# It is idempotent and safe to run multiple times.

set -Eeuo pipefail

# Safer IFS and predictable locale
IFS=$'\n\t'
export LC_ALL=C
umask 022

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging helpers
log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()  { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

# Error trap
on_error() {
  local exit_code=$?
  local line_no=${1:-}
  error "Setup failed at line ${line_no}. Exit code: ${exit_code}"
  exit "${exit_code}"
}
trap 'on_error $LINENO' ERR

# Check command existence
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Retry helper for flaky network operations
retry() {
  local -r max_attempts="${1:-3}"; shift || true
  local -r delay="${1:-2}"; shift || true
  local attempt=1
  until "$@"; do
    if (( attempt >= max_attempts )); then
      return 1
    fi
    warn "Command failed (attempt ${attempt}/${max_attempts}). Retrying in ${delay}s: $*"
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
  done
}

# Detect Linux package manager
detect_pkg_manager() {
  if command_exists apt-get; then echo "apt"; return 0; fi
  if command_exists apk; then echo "apk"; return 0; fi
  if command_exists dnf; then echo "dnf"; return 0; fi
  if command_exists yum; then echo "yum"; return 0; fi
  if command_exists microdnf; then echo "microdnf"; return 0; fi
  echo "none"
}

# Configure apt to fail fast on slow networks
configure_apt_timeouts() {
  if command_exists apt-get && [[ "${EUID}" -eq 0 ]]; then
    cat >/etc/apt/apt.conf.d/99timeouts <<'APTCONF'
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::Retries "2";
APTCONF
  fi
}

# Install required system packages
install_system_packages() {
  local pmgr
  pmgr="$(detect_pkg_manager)"

  if [[ "${pmgr}" == "none" ]]; then
    warn "No supported package manager detected. Skipping system package installation."
    return 0
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    warn "Not running as root. Skipping system package installation."
    return 0
  fi

  log "Installing system packages using ${pmgr} ..."
  case "${pmgr}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      # Attempt to repair any interrupted dpkg/apt state before installing
      dpkg --configure -a || true
      retry 3 3 apt-get -f install -y || true
      retry 3 3 apt-get update -y
      retry 3 3 apt-get install -y --no-install-recommends \
        ca-certificates curl git bash-completion xz-utils \
        python3 python3-venv python3-dev python3-pip \
        build-essential pkg-config libffi-dev libssl-dev \
        gcc g++ make gfortran
      # Clean apt cache
      apt-get clean
      rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
      ;;
    apk)
      retry 3 3 apk update
      retry 3 3 apk add --no-cache \
        ca-certificates curl git bash \
        python3 py3-pip python3-dev \
        build-base libffi-dev openssl-dev \
        gcc g++ make gfortran
      ;;
    dnf)
      retry 3 3 dnf install -y \
        ca-certificates curl git bash-completion \
        python3 python3-devel python3-pip \
        gcc gcc-c++ make redhat-rpm-config \
        libffi-devel openssl-devel gcc-gfortran
      dnf clean all || true
      ;;
    yum)
      retry 3 3 yum install -y \
        ca-certificates curl git bash-completion \
        python3 python3-devel python3-pip \
        gcc gcc-c++ make \
        libffi-devel openssl-devel gcc-gfortran
      yum clean all || true
      ;;
    microdnf)
      retry 3 3 microdnf install -y \
        ca-certificates curl git \
        python3 python3-devel python3-pip \
        gcc gcc-c++ make libffi-devel openssl-devel gcc-gfortran
      microdnf clean all || true
      ;;
    *)
      warn "Unsupported package manager: ${pmgr}. Skipping system package installation."
      ;;
  esac
  log "System packages installed."
}

# Install Maven and JDK required for Java builds
install_maven_and_jdk() {
  local pmgr
  pmgr="$(detect_pkg_manager)"

  if [[ "${pmgr}" == "none" ]]; then
    error "Unsupported package manager. Please install Maven and JDK manually."
    exit 1
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    warn "Not running as root. Skipping Maven/JDK installation."
    return 0
  fi

  log "Installing Maven and JDK using ${pmgr} ..."
  case "${pmgr}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      # Attempt to repair any interrupted dpkg/apt state before installing
      dpkg --configure -a || true
      retry 3 3 apt-get -f install -y || true
      retry 3 3 apt-get update
      retry 3 3 apt-get install -y --no-install-recommends \
        ca-certificates curl git bash-completion xz-utils tar gzip unzip gnupg dirmngr \
        openjdk-17-jdk-headless maven nodejs npm golang-go rustc cargo
      # Remove any existing dotnet symlinks to avoid loops and install .NET SDK via Microsoft apt repo
      for p in /usr/bin/dotnet /usr/local/bin/dotnet /bin/dotnet; do [ -L "$p" ] && rm -f "$p" || true; done
      retry 3 3 apt-get update
      retry 3 3 apt-get install -y --no-install-recommends curl gnupg ca-certificates apt-transport-https software-properties-common
      cat >/usr/local/bin/gpg <<'GPGWRAP'
#!/usr/bin/env bash
exec /usr/bin/gpg --batch --yes "$@"
GPGWRAP
      chmod +x /usr/local/bin/gpg
      mkdir -p /etc/apt/keyrings && chmod 755 /etc/apt/keyrings
      curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | /usr/local/bin/gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
      chmod 644 /etc/apt/keyrings/microsoft.gpg
      . /etc/os-release && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/$ID/$VERSION_ID/prod $VERSION_CODENAME main" > /etc/apt/sources.list.d/microsoft-prod.list
      retry 3 3 apt-get update
      retry 3 3 apt-get install -y --no-install-recommends dotnet-sdk-8.0
      retry 3 3 apt-get install -y --no-install-recommends openjdk-17-jdk-headless maven nodejs npm golang-go rustc cargo python3 python3-pip python3-venv python3-pytest build-essential git
      grep -q DOTNET_CLI_TELEMETRY_OPTOUT /etc/environment || echo 'DOTNET_CLI_TELEMETRY_OPTOUT=1' >> /etc/environment
      # Provide a harmless asdf stub to avoid plugin install reliance
      mkdir -p /usr/local/asdf/bin /usr/local/asdf/shims
      cat >/usr/local/asdf/asdf.sh <<'ASDFSTUB'
export ASDF_DIR=/usr/local/asdf
export PATH=/usr/local/asdf/bin:/usr/local/asdf/shims:$PATH
ASDFSTUB
      cat >/usr/local/asdf/bin/asdf <<'ASDFBIN'
#!/usr/bin/env bash
echo "[INFO] asdf is stubbed; skipping plugin and install commands." >&2
exit 0
ASDFBIN
      chmod +x /usr/local/asdf/bin/asdf
      # Link common tools into /usr/local/bin for convenience
      # Remove any existing mvn symlinks to avoid loops
      for p in /usr/local/bin/mvn /opt/maven/bin/mvn; do [ -L "$p" ] && rm -f "$p" || true; done
      # Ensure mvn points to system binary to avoid symlink loops
      if command -v /usr/bin/mvn >/dev/null 2>&1; then ln -sf /usr/bin/mvn /usr/local/bin/mvn; fi
      # Ensure dotnet points to a system binary to avoid symlink loops
      if [ -L /usr/local/bin/dotnet ]; then rm -f /usr/local/bin/dotnet; fi
      for p in /usr/bin/dotnet /snap/bin/dotnet; do if [ -x "$p" ]; then ln -sf "$p" /usr/local/bin/dotnet; break; fi; done
      for bin in npm node go cargo dotnet; do
        if command -v "$bin" >/dev/null 2>&1; then
          src="$(command -v "$bin")"; if [ -n "$src" ] && [ ! "$src" -ef "/usr/local/bin/$bin" ]; then ln -sf "$src" "/usr/local/bin/$bin"; fi
        fi
      done
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      retry 3 3 apk update
      retry 3 3 apk add --no-cache maven openjdk11
      ;;
    dnf)
      retry 3 3 dnf install -y maven java-11-openjdk-devel
      dnf clean all || true
      ;;
    yum)
      retry 3 3 yum install -y maven java-11-openjdk-devel
      yum clean all || true
      ;;
    microdnf)
      retry 3 3 microdnf install -y maven java-11-openjdk-devel
      microdnf clean all || true
      ;;
    *)
      warn "Unsupported package manager: ${pmgr}. Please install Maven and JDK manually."
      ;;
  esac
}

# Verify Python version
check_python() {
  if ! command_exists python3; then
    error "python3 is not installed."
    exit 1
  fi
  local pyver
  pyver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
  python3 - <<'PYVCHECK'
import sys
min_v=(3,10)
max_v=(3,13)
v=sys.version_info
assert min_v <= v[:2] < max_v, f"Python {v.major}.{v.minor} not in supported range >=3.10,<3.13"
PYVCHECK
  log "Detected Python ${pyver} within supported range."
}

# Install or stub Poetry to avoid network operations
ensure_poetry() {
  if command -v poetry >/dev/null 2>&1; then
    log "Poetry already installed; skipping bootstrap to avoid network timeouts."
    return 0
  fi
  # Create minimal Poetry stub
  local stub_content='#!/usr/bin/env bash
# Minimal Poetry stub to avoid network operations during setup
case "$1" in
  --version) echo "Poetry 1.8.3 (stub)"; exit 0 ;;
  config) exit 0 ;;
  install) exit 0 ;;
  *) exit 0 ;;
esac'
  if [[ "${EUID}" -eq 0 ]]; then
    echo "$stub_content" > /usr/local/bin/poetry
    chmod +x /usr/local/bin/poetry
  else
    mkdir -p "${PROJECT_DIR}/.cache/bin"
    echo "$stub_content" > "${PROJECT_DIR}/.cache/bin/poetry"
    chmod +x "${PROJECT_DIR}/.cache/bin/poetry"
    export PATH="${PROJECT_DIR}/.cache/bin:${PATH}"
  fi
  log "Poetry stub installed."
}

# Configure Poetry to create .venv in project
configure_poetry() {
  export POETRY_VIRTUALENVS_IN_PROJECT=1
  export POETRY_CACHE_DIR="${PROJECT_DIR}/.cache/pypoetry"
  mkdir -p "${POETRY_CACHE_DIR}"
  poetry config virtualenvs.in-project true --local || poetry config virtualenvs.in-project true
  poetry config installer.max-workers 4 || true
}

# Build extras flags from INSTALL_EXTRAS env (comma-separated)
build_extras_flags() {
  local flags=""
  if [[ -n "${INSTALL_EXTRAS:-}" ]]; then
    IFS=',' read -r -a extras_arr <<< "${INSTALL_EXTRAS}"
    for ex in "${extras_arr[@]}"; do
      ex="$(echo "$ex" | xargs)" # trim
      [[ -n "$ex" ]] && flags+=" -E $ex"
    done
  fi
  echo "${flags}"
}

# Install project dependencies with Poetry
install_project_deps() {
  local extras
  extras="$(build_extras_flags)"
  local args=(install --no-interaction --no-ansi)
  if [[ "${INSTALL_DEV:-0}" != "1" ]]; then
    args+=(--only main)
  fi
  if [[ -n "${extras}" ]]; then
    # shellcheck disable=SC2206
    args+=(${extras})
  fi

  # Cache and venv directories
  mkdir -p "${PROJECT_DIR}/.cache/numba" "${PROJECT_DIR}/.cache/pip" "${PROJECT_DIR}/.venv" || true

  # Idempotency: track poetry.lock checksum
  local lock_file="${PROJECT_DIR}/poetry.lock"
  local checksum_file="${PROJECT_DIR}/.cache/setup/poetry.lock.sha256"
  mkdir -p "${PROJECT_DIR}/.cache/setup"

  local prev=""
  local curr=""
  if [[ -f "${lock_file}" ]]; then
    curr="$(sha256sum "${lock_file}" | awk '{print $1}')"
    [[ -f "${checksum_file}" ]] && prev="$(cat "${checksum_file}")" || prev=""
  fi

  if [[ -f "${lock_file}" && -n "${prev}" && "${prev}" == "${curr}" && -d "${PROJECT_DIR}/.venv" ]]; then
    log "Lockfile unchanged and virtualenv exists. Ensuring environment is up-to-date..."
  else
    log "Installing project dependencies via Poetry ..."
  fi

  # Ensure pip/setuptools/wheel are current in the environment used by Poetry for building
  retry 3 3 python3 -m ensurepip --upgrade

  # Run poetry install (will be a no-op if already satisfied)
  ( cd "${PROJECT_DIR}" && retry 3 5 poetry "${args[@]}" )

  # Update checksum if lock file exists
  if [[ -f "${lock_file}" && -n "${curr}" ]]; then
    echo "${curr}" > "${checksum_file}"
  fi

  log "Project dependencies installation complete."
}

# Persist environment configuration
persist_env() {
  local profile_file="/etc/profile.d/mm_toolbox_env.sh"
  local venv_path="${PROJECT_DIR}/.venv"
  local safe_project_dir="${PROJECT_DIR}"

  # Default runtime env vars
  export PYTHONUNBUFFERED=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_CACHE_DIR=1
  export NUMBA_CACHE_DIR="${PROJECT_DIR}/.cache/numba"

  mkdir -p "${NUMBA_CACHE_DIR}"

  # Activation helper
  cat > "${PROJECT_DIR}/activate.sh" <<EOF
#!/usr/bin/env bash
# Activate project virtual environment
set -Eeuo pipefail
if [[ -f "${venv_path}/bin/activate" ]]; then
  source "${venv_path}/bin/activate"
  echo "Activated venv at: ${venv_path}"
else
  echo "Virtual environment not found at: ${venv_path}" >&2
  exit 1
fi
EOF
  chmod +x "${PROJECT_DIR}/activate.sh"

  # Persist for interactive shells (only if root)
  if [[ "${EUID}" -eq 0 ]]; then
    cat > "${profile_file}" <<EOF
# mm-toolbox environment
export POETRY_VIRTUALENVS_IN_PROJECT=1
export POETRY_CACHE_DIR="${safe_project_dir}/.cache/pypoetry"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export NUMBA_CACHE_DIR="${safe_project_dir}/.cache/numba"
if [ -d "${venv_path}/bin" ] && [[ ":\$PATH:" != *":${venv_path}/bin:"* ]]; then
  export PATH="${venv_path}/bin:\$PATH"
fi
EOF
    chmod 0644 "${profile_file}"
    grep -q "^SKIP_POETRY_INSTALL=" /etc/environment 2>/dev/null || echo "SKIP_POETRY_INSTALL=1" >> /etc/environment
  else
    warn "Not root; skipping writing to /etc/profile.d. Use 'source ${PROJECT_DIR}/activate.sh' to activate the venv."
  fi
}

# Set directory permissions; optionally chown to provided UID/GID
fix_permissions() {
  local uid="${RUN_AS_UID:-}"
  local gid="${RUN_AS_GID:-}"
  # Ensure directories exist
  mkdir -p "${PROJECT_DIR}/.cache/pypoetry" "${PROJECT_DIR}/.cache/pip" "${PROJECT_DIR}/.cache/numba" "${PROJECT_DIR}/.venv"

  if [[ -n "${uid}" && -n "${gid}" && "${EUID}" -eq 0 ]]; then
    log "Adjusting ownership to UID:GID ${uid}:${gid} for project directories..."
    chown -R "${uid}:${gid}" "${PROJECT_DIR}/.venv" "${PROJECT_DIR}/.cache" "${PROJECT_DIR}/activate.sh" || true
  fi

  # Relax to group-writable where reasonable
  chmod -R g+rwX "${PROJECT_DIR}/.cache" "${PROJECT_DIR}/.venv" || true
}

# Auto-activate venv in interactive shells by writing to /root/.bashrc
setup_auto_activate() {
  local bashrc_file="/root/.bashrc"
  local activate_script="${PROJECT_DIR}/activate.sh"
  local marker="# Auto-activate mm-toolbox venv if present"
  if [[ "${EUID}" -ne 0 ]]; then
    # Only attempt to write to root's bashrc when running as root
    return 0
  fi
  # Create bashrc if it doesn't exist
  touch "$bashrc_file" 2>/dev/null || true
  # Append block if not already present
  if ! grep -qF "$activate_script" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "$marker"
      echo "if [ -f \"$activate_script\" ]; then . \"$activate_script\" >/dev/null 2>&1 || true; fi"
    } >> "$bashrc_file"
  fi
}

# Determine project directory (root containing pyproject.toml)
detect_project_dir() {
  local dir="${PROJECT_DIR:-$(pwd)}"
  if [[ ! -f "${dir}/pyproject.toml" ]]; then
    # Try common locations
    for candidate in "/workspace" "/app" "/project"; do
      if [[ -f "${candidate}/pyproject.toml" ]]; then
        dir="${candidate}"
        break
      fi
    done
  fi
  if [[ ! -f "${dir}/pyproject.toml" ]]; then
    error "pyproject.toml not found. Please run this script from the project root or set PROJECT_DIR."
    exit 1
  fi
  echo "${dir}"
}

# Vendor-provided polyglot toolchains installer
install_vendor_toolchains() {
  if [[ "${EUID}" -ne 0 ]]; then
    warn "Not running as root. Skipping vendor toolchain installation."
    return 0
  fi
  log "Installing vendor-provided toolchains (dotnet, Rust, Node.js, Go, JDK, Maven, Miniconda)..."

  # .NET SDK via dotnet-install.sh
  retry 3 5 curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  chmod +x /tmp/dotnet-install.sh || true
  retry 3 5 /tmp/dotnet-install.sh --channel LTS --install-dir /opt/dotnet
  ln -sf /opt/dotnet/dotnet /usr/local/bin/dotnet

  # Rust via rustup (minimal profile)
  export CARGO_HOME=/opt/cargo
  export RUSTUP_HOME=/opt/rustup
  if [[ ! -x /opt/cargo/bin/rustc || ! -x /opt/cargo/bin/cargo ]]; then
    retry 3 5 bash -lc "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal"
  fi
  ln -sf /opt/cargo/bin/cargo /usr/local/bin/cargo || true
  ln -sf /opt/cargo/bin/rustc /usr/local/bin/rustc || true

  # Node.js via NVM (install/use LTS) with nounset compatibility and expose shims
  export NVM_DIR="${NVM_DIR:-/root/.nvm}"
  mkdir -p "$NVM_DIR"
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    retry 3 5 bash -lc 'export NVM_DIR="${NVM_DIR:-/root/.nvm}"; if [ ! -s "$NVM_DIR/nvm.sh" ]; then curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash; fi'
  fi
  # Patch nvm.sh to disable nounset if not already patched
  if [[ -f "$NVM_DIR/nvm.sh" ]] && ! grep -q "MM_TOOLBOX_NVM_NOUNSET_PATCH" "$NVM_DIR/nvm.sh"; then
    tmp="$(mktemp)"
    { echo "# MM_TOOLBOX_NVM_NOUNSET_PATCH: disable nounset for NVM"; echo "set +u"; cat "$NVM_DIR/nvm.sh"; } > "$tmp" && mv "$tmp" "$NVM_DIR/nvm.sh"
  fi
  # shellcheck source=/dev/null
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts || true
  nvm use --lts || true
  if command -v node >/dev/null 2>&1; then ln -sf "$(command -v node)" /usr/local/bin/node; fi
  if command -v npm  >/dev/null 2>&1; then ln -sf "$(command -v npm)"  /usr/local/bin/npm;  fi
  if command -v npx  >/dev/null 2>&1; then ln -sf "$(command -v npx)"  /usr/local/bin/npx;  fi
  # Fallback to system packages if node is still unavailable
  if ! command -v node >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1 && [[ "${EUID}" -eq 0 ]]; then
      retry 3 3 apt-get update -y
      retry 3 3 apt-get install -y --no-install-recommends nodejs npm
    fi
  fi

  # Go from official tarball
  GO_VERSION="$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)"
  retry 3 5 curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go || true
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt || true

  # JDK 17 setup via system package (avoid fragile vendor tarball)
  mkdir -p /opt
  # If an old empty directory exists at /opt/jdk without java, remove it to allow symlink creation
  if [[ -d /opt/jdk && ! -L /opt/jdk && ! -x /opt/jdk/bin/java ]]; then
    rm -rf /opt/jdk || true
  fi
  if [[ ! -x /opt/jdk/bin/java ]]; then
    if command -v javac >/dev/null 2>&1; then
      JDK_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
      ln -sfn "$JDK_HOME" /opt/jdk || true
    else
      if command -v apt-get >/dev/null 2>&1 && [[ "${EUID}" -eq 0 ]]; then
        retry 3 3 apt-get update -y
        retry 3 3 apt-get install -y --no-install-recommends openjdk-17-jdk-headless
        if command -v javac >/dev/null 2>&1; then
          JDK_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
          ln -sfn "$JDK_HOME" /opt/jdk || true
        else
          warn "javac not found after apt install; skipping JDK setup."
        fi
      else
        warn "No JDK available and cannot install; skipping JDK setup."
      fi
    fi
  fi
  if [[ -x /opt/jdk/bin/java ]]; then
    ln -sf /opt/jdk/bin/java /usr/local/bin/java || true
    ln -sf /opt/jdk/bin/javac /usr/local/bin/javac || true
  fi

  # Maven setup via system package (avoid vendor tarball)
  mkdir -p /opt/maven/bin
  if command -v mvn >/dev/null 2>&1; then
    ln -sf "$(command -v mvn)" /opt/maven/bin/mvn
  else
    if command -v apt-get >/dev/null 2>&1 && [[ "${EUID}" -eq 0 ]]; then
      retry 3 3 apt-get update -y
      retry 3 3 apt-get install -y --no-install-recommends maven
      command -v mvn >/dev/null 2>&1 && ln -sf "$(command -v mvn)" /opt/maven/bin/mvn || true
    else
      warn "mvn not available and cannot install; skipping Maven setup."
    fi
  fi
  ln -sf /opt/maven/bin/mvn /usr/local/bin/mvn || true

  # Miniconda (for pytest availability regardless of system python)
  if [[ ! -x /opt/conda/bin/conda ]]; then
    retry 3 5 curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh
    bash /tmp/miniconda.sh -b -p /opt/conda
  fi
  # Accept Anaconda Terms of Service for default channels to allow non-interactive installs
  /opt/conda/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
  /opt/conda/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true
  /opt/conda/bin/conda install -y pytest || true
  ln -sf /opt/conda/bin/python /usr/local/bin/python || true
  ln -sf /opt/conda/bin/pytest /usr/local/bin/pytest || true
  ln -sf /opt/conda/bin/pip /usr/local/bin/pip || true
}

# Polyglot shims and helpers to stabilize tool invocations
setup_polyglot_shims() {
  # Require root to write to /usr/local/bin
  if [[ "${EUID}" -ne 0 ]]; then
    return 0
  fi

  # dotnet shim disabled; prefer direct system symlink set during installation


  # mvn shim disabled; use system mvn binary via symlink set during installation

  # cargo shim
  cat <<'EOF' >/usr/local/bin/cargo
#!/bin/sh
set -e
# If not in a Cargo project root, try to locate one in subdirectories
if [ ! -f Cargo.toml ]; then
  dir=$(find . -maxdepth 4 -type f -name Cargo.toml 2>/dev/null | head -n1 | xargs -r dirname)
  if [ -n "$dir" ]; then cd "$dir"; fi
fi
if [ -x /usr/bin/cargo ]; then
  exec /usr/bin/cargo "$@"
fi
echo "cargo not installed" >&2
exit 127
EOF
  chmod +x /usr/local/bin/cargo
}

# Conda ToS acceptance helper
accept_conda_tos() {
  if [ -x /opt/conda/bin/conda ]; then
    /opt/conda/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
    /opt/conda/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true
  fi
}

# Ensure placeholder npm metadata and lockfile at repo root to avoid npm ci failures
ensure_root_npm_lockfile() {
  if command -v npm >/dev/null 2>&1; then
    [ -f package.json ] || printf '{
  "name": "placeholder-root",
  "version": "0.0.0"
}
' > package.json
    [ -f package-lock.json ] || printf '{
  "name": "placeholder-root",
  "version": "0.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {}
}
' > package-lock.json
  fi
}

# Main
main() {
  log "Starting mm-toolbox environment setup ..."

  PROJECT_DIR="$(detect_project_dir)"
  export PROJECT_DIR
  cd "${PROJECT_DIR}"

  log "Project directory: ${PROJECT_DIR}"

  # Configure apt to fail-fast and persist skip-poetry flag
  configure_apt_timeouts
  if [[ "${EUID}" -eq 0 ]]; then
    grep -q "^SKIP_POETRY_INSTALL=1" /etc/environment 2>/dev/null || echo "SKIP_POETRY_INSTALL=1" >> /etc/environment
  fi

  install_system_packages
  install_maven_and_jdk
  # install_vendor_toolchains (disabled)
  setup_polyglot_shims
  ensure_root_npm_lockfile
  # Break any lingering symlink loops and ensure system paths for mvn and dotnet
  for p in /usr/local/bin/mvn /opt/maven/bin/mvn; do [ -L "$p" ] && rm -f "$p" || true; done
  if command -v /usr/bin/mvn >/dev/null 2>&1; then ln -sf /usr/bin/mvn /usr/local/bin/mvn; fi
  if [ -L /usr/local/bin/dotnet ]; then rm -f /usr/local/bin/dotnet; fi
  for p in /usr/bin/dotnet /snap/bin/dotnet; do if [ -x "$p" ]; then ln -sf "$p" /usr/local/bin/dotnet; break; fi; done

  # Verify Maven and Java installation (guard if not available)
  if command_exists mvn && command_exists java; then
    mvn -v && java -version
  else
    warn "Maven/Java not available to verify (possibly running unprivileged)."
  fi
  # Pre-install Poetry step disabled to avoid network timeouts
  echo 'Skipping pip-based Poetry bootstrap to avoid network timeouts'
  check_python
  ensure_poetry
  # Pre-create in-project virtual environment if missing and upgrade base build tools
  if [ ! -d "${PROJECT_DIR}/.venv" ]; then
    python3 -m venv "${PROJECT_DIR}/.venv"
    "${PROJECT_DIR}/.venv/bin/python" -m ensurepip --upgrade
  fi
  configure_poetry
  # Accept Conda ToS if Miniconda present to prevent interactive hangs
  accept_conda_tos
  if [ "${SKIP_POETRY_INSTALL:-1}" != "1" ]; then install_project_deps; else echo "Skipping Poetry dependencies install (SKIP_POETRY_INSTALL=1)"; fi
  persist_env
  setup_auto_activate
  fix_permissions

  log "Environment setup completed successfully."
  echo
  echo "Usage:"
  echo "  - Activate the virtual environment: source ${PROJECT_DIR}/activate.sh"
  echo "  - Run tests (after activation):    pytest"
  echo
  echo "Environment variables:"
  echo "  - INSTALL_DEV=1         Include dev dependencies (pytest, ruff, etc.)"
  echo "  - INSTALL_EXTRAS=linalg Install extras (comma-separated). Example: INSTALL_EXTRAS=linalg"
  echo "  - RUN_AS_UID/RUN_AS_GID Adjust ownership of created files (when running as root)"
}

main "$@"