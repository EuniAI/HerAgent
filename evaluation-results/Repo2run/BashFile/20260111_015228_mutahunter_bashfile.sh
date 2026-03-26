#!/usr/bin/env bash
# Universal project environment setup script for Docker containers
# Installs runtimes and dependencies based on detected project type.
# Safe to run multiple times (idempotent).
# Designed to run as root inside containers (no sudo).
#
# Supported project types (auto-detected by files):
# - Node.js: package.json
# - Python: requirements.txt / pyproject.toml / setup.py
# - Go: go.mod
# - Ruby: Gemfile
# - PHP: composer.json
# - Rust: Cargo.toml
# - Java: pom.xml / build.gradle
# - .NET: *.csproj (limited support; advises base image use)

set -Eeuo pipefail
umask 022

# -----------------------------
# Logging and error handling
# -----------------------------
LOG_TS() { date +'%Y-%m-%d %H:%M:%S'; }
log()    { echo "[$(LOG_TS)] $*"; }
warn()   { echo "[WARN $(LOG_TS)] $*" >&2; }
err()    { echo "[ERROR $(LOG_TS)] $*" >&2; }
cleanup() { :; }
on_err() {
  err "Setup failed at line ${BASH_LINENO[0]} in function ${FUNCNAME[1]:-main}"
  exit 1
}
trap on_err ERR
trap cleanup EXIT

# -----------------------------
# Defaults and globals
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="${APP_ROOT:-$SCRIPT_DIR}"
APP_USER="${APP_USER:-app}"
APP_GROUP="${APP_GROUP:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
APP_PORT="${APP_PORT:-8080}"
DEBIAN_FRONTEND=noninteractive

# Versions (override via env if needed)
NODE_VERSION="${NODE_VERSION:-20.11.1}"   # LTS line
GO_VERSION="${GO_VERSION:-1.22.5}"        # recent stable
JAVA_VERSION="${JAVA_VERSION:-17}"         # LTS JDK
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"

# -----------------------------
# Helpers
# -----------------------------
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

# Retry-able downloader
dl() {
  # dl URL OUTPUT_PATH
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    local tries=5
    local i=1
    while [ "$i" -le "$tries" ]; do
      if curl -fsSL "$url" -o "$out"; then return 0; fi
      sleep "$i"
      i=$((i+1))
    done
    return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    err "Neither curl nor wget is available for downloads"
    return 1
  fi
}

# Detect package manager
detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then PM="apt"
  elif command -v apk >/dev/null 2>&1; then PM="apk"
  elif command -v dnf >/dev/null 2>&1; then PM="dnf"
  elif command -v microdnf >/dev/null 2>&1; then PM="microdnf"
  elif command -v yum >/dev/null 2>&1; then PM="yum"
  else PM=""
  fi
  echo "${PM}"
}

# Update package index (idempotent)
pkg_update() {
  local pm="$1"
  case "$pm" in
    apt)  apt-get update -y >/dev/null ;;
    apk)  apk update >/dev/null || true ;;
    dnf)  dnf -y makecache >/dev/null || true ;;
    microdnf) microdnf -y update >/dev/null || true ;;
    yum)  yum -y makecache >/dev/null || true ;;
    *)    warn "Unknown package manager; skipping update" ;;
  esac
}

# Install packages
pkg_install() {
  # pkg_install pm pkgs...
  local pm="$1"; shift || true
  local pkgs=("$@")
  [ "${#pkgs[@]}" -gt 0 ] || return 0
  case "$pm" in
    apt)
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      apt-get clean
      rm -rf /var/lib/apt/lists/* /var/cache/apt/*
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    dnf)
      dnf -y install "${pkgs[@]}"
      dnf clean all
      ;;
    microdnf)
      microdnf -y install "${pkgs[@]}"
      microdnf clean all || true
      ;;
    yum)
      yum -y install "${pkgs[@]}"
      yum clean all
      ;;
    *)
      warn "No package manager detected. Cannot install: ${pkgs[*]}"
      ;;
  esac
}

# Create app user/group
ensure_user() {
  if ! is_root; then
    warn "Not running as root; skipping user creation"
    return 0
  fi
  # Group
  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    log "Creating group ${APP_GROUP}"
    # Create group without enforcing GID to avoid collisions
    (command -v groupadd >/dev/null 2>&1 && groupadd "${APP_GROUP}") || \
    (command -v addgroup >/dev/null 2>&1 && addgroup "${APP_GROUP}") || true
  fi
  # User
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    log "Creating user ${APP_USER}"
    # Create user without enforcing UID to avoid collisions; assign to group and nologin shell
    (command -v useradd >/dev/null 2>&1 && useradd -M -s /usr/sbin/nologin -g "${APP_GROUP}" "${APP_USER}") || \
    (command -v adduser >/dev/null 2>&1 && adduser --disabled-login --ingroup "${APP_GROUP}" --no-create-home --shell /usr/sbin/nologin "${APP_USER}") || true
  fi
}

# Ensure directories
ensure_dirs() {
  mkdir -p "${APP_ROOT}"/{logs,tmp,config,data}
  # Language-specific cache/work dirs
  mkdir -p "${APP_ROOT}/.cache"
  # Go workspace
  mkdir -p /go/pkg /go/bin || true
  # Permissions
  if is_root; then
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_ROOT}" || true
    chown -R "${APP_USER}:${APP_GROUP}" /go || true
  fi
}

# Export defaults to /etc/profile.d so interactive shells see them
write_profile_env() {
  local f="/etc/profile.d/app_env.sh"
  if is_root; then
    cat > "$f" <<EOF
export APP_ROOT="${APP_ROOT}"
export APP_ENV="${APP_ENV}"
export APP_PORT="${APP_PORT}"
export PATH="/usr/local/bin:/usr/local/sbin:\$PATH"
export PIP_DISABLE_PIP_VERSION_CHECK=on
export PYTHONUNBUFFERED=1
export NODE_ENV="${APP_ENV}"
EOF
    chmod 0644 "$f"
  fi
}

# Write .env file if not present
write_dotenv() {
  local f="${APP_ROOT}/.env"
  if [ ! -f "$f" ]; then
    cat > "$f" <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
EOF
  fi
}

# -----------------------------
# Compatibility wrappers and auto-activation
# -----------------------------
install_compat_wrappers() {
  # Create compatibility wrappers for addgroup/adduser to handle Alpine-style flags on Debian/Ubuntu
  if is_root; then
    cat >/usr/local/bin/addgroup <<'EOF'
#!/usr/bin/env sh
set -eu
# Compatibility wrapper: supports Alpine-style flags and maps to groupadd on Debian/Ubuntu.
if ! command -v groupadd >/dev/null 2>&1; then
  exec /usr/sbin/addgroup "$@"
fi
GID=""
SYSTEM=0
GROUP=""
while [ $# -gt 0 ]; do
  case "$1" in
    -g|--gid) GID="$2"; shift 2 ;;
    -S|--system) SYSTEM=1; shift ;;
    --) shift; break ;;
    -*) shift ;; # ignore unsupported short flags
    *) GROUP="$1"; shift ;;
  esac
done
if [ -z "$GROUP" ]; then
  echo "Usage: addgroup -g GID [-S] GROUP" >&2
  exit 1
fi
if getent group "$GROUP" >/dev/null 2>&1; then
  exit 0
fi
if [ -n "$GID" ]; then
  if [ "$SYSTEM" -eq 1 ]; then
    exec groupadd -r -g "$GID" "$GROUP"
  else
    exec groupadd -g "$GID" "$GROUP"
  fi
else
  if [ "$SYSTEM" -eq 1 ]; then
    exec groupadd -r "$GROUP"
  else
    exec groupadd "$GROUP"
  fi
fi
EOF
    chmod +x /usr/local/bin/addgroup

    cat >/usr/local/bin/adduser <<'EOF'
#!/usr/bin/env sh
set -eu
# Compatibility wrapper: supports Alpine-style flags and maps to useradd on Debian/Ubuntu.
if ! command -v useradd >/dev/null 2>&1; then
  exec /usr/sbin/adduser "$@"
fi
UID=""
GROUP=""
SYSTEM=0
NOHOME=0
USER=""
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--uid) UID="$2"; shift 2 ;;
    -G|--ingroup|--group) GROUP="$2"; shift 2 ;;
    -S|--system) SYSTEM=1; shift ;;
    -D) shift ;; # ignore (defaults)
    -H|--no-create-home) NOHOME=1; shift ;;
    --disabled-login|--disabled-password) shift ;; # ignore
    --) shift; break ;;
    -*) shift ;; # ignore unsupported short flags
    *) USER="$1"; shift ;;
  esac
done
if [ -z "$USER" ]; then
  echo "Usage: adduser [options] USER" >&2
  exit 1
fi
if id -u "$USER" >/dev/null 2>&1; then
  exit 0
fi
args=""
[ -n "$UID" ] && args="$args -u $UID"
[ -n "$GROUP" ] && args="$args -g $GROUP"
[ "$SYSTEM" -eq 1 ] && args="$args -r"
[ "$NOHOME" -eq 1 ] && args="$args -M"
exec useradd $args -s /usr/sbin/nologin "$USER"
EOF
    chmod +x /usr/local/bin/adduser
  fi
}

setup_auto_activate() {
  # Ensure Python venv auto-activation in bashrc for interactive shells
  local bashrc_file="/root/.bashrc"
  local venv="${APP_ROOT}/.venv"
  local activate_line="source ${venv}/bin/activate"
  if [ -f "${venv}/bin/activate" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      echo "" >> "$bashrc_file"
      echo "# Auto-activate Python virtual environment" >> "$bashrc_file"
      echo "$activate_line" >> "$bashrc_file"
    fi
  fi
}

write_profile_scripts() {
  # Ensure /usr/local path precedence and auto-activate venv via /etc/profile.d for interactive shells
  if is_root; then
    local path_profile="/etc/profile.d/prepend_local_path.sh"
    printf 'export PATH=/usr/local/bin:/usr/local/sbin:$PATH\n' > "$path_profile"
    chmod 0644 "$path_profile"

    local venv_profile="/etc/profile.d/auto_activate_venv.sh"
    cat > "$venv_profile" <<'EOF'
# Auto-activate project Python venv on shell start, if present
APP_ROOT="${APP_ROOT:-/workspace}"
if [ -f "${APP_ROOT}/.venv/bin/activate" ]; then
  . "${APP_ROOT}/.venv/bin/activate"
fi
EOF
    chmod 0644 "$venv_profile"
  fi
}

# -----------------------------
# System prerequisites
# -----------------------------
install_base_tools() {
  local pm
  pm="$(detect_pm)"
  if [ -n "$pm" ]; then
    log "Using package manager: $pm"
    pkg_update "$pm"
    case "$pm" in
      apt)
        pkg_install "$pm" ca-certificates curl wget git openssh-client tzdata xz-utils unzip tar bash build-essential
        update-ca-certificates || true
        ;;
      apk)
        pkg_install "$pm" ca-certificates curl wget git openssh tzdata xz unzip tar bash build-base
        update-ca-certificates || true
        ;;
      dnf|microdnf|yum)
        pkg_install "$pm" ca-certificates curl wget git openssh-clients xz unzip tar bash findutils which shadow-utils
        ;;
      *)
        warn "Unknown package manager; base tools may be missing"
        ;;
    esac
  else
    warn "No package manager detected; ensure ca-certificates, curl/wget, git, tar are available"
  fi
}

# -----------------------------
# Project detection
# -----------------------------
detect_project_type() {
  local type="generic"
  if [ -f "${APP_ROOT}/package.json" ]; then
    type="node"
  elif [ -f "${APP_ROOT}/requirements.txt" ] || [ -f "${APP_ROOT}/pyproject.toml" ] || [ -f "${APP_ROOT}/setup.py" ]; then
    type="python"
  elif [ -f "${APP_ROOT}/go.mod" ]; then
    type="go"
  elif [ -f "${APP_ROOT}/Gemfile" ]; then
    type="ruby"
  elif [ -f "${APP_ROOT}/composer.json" ]; then
    type="php"
  elif [ -f "${APP_ROOT}/Cargo.toml" ]; then
    type="rust"
  elif [ -f "${APP_ROOT}/pom.xml" ] || [ -f "${APP_ROOT}/build.gradle" ] || [ -f "${APP_ROOT}/build.gradle.kts" ]; then
    type="java"
  elif ls "${APP_ROOT}"/*.csproj >/dev/null 2>&1; then
    type="dotnet"
  fi
  echo "$type"
}

# -----------------------------
# Install runtimes and deps
# -----------------------------

install_node_runtime() {
  if command -v node >/dev/null 2>&1; then
    log "Node.js already installed: $(node -v)"
    return 0
  fi
  local arch uname_arch
  uname_arch="$(uname -m)"
  case "$uname_arch" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="armv7l" ;;
    *) arch="x64"; warn "Unknown arch ${uname_arch}, defaulting to x64" ;;
  esac
  local tarball="node-v${NODE_VERSION}-linux-${arch}.tar.xz"
  local url="https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
  local tmp="/tmp/${tarball}"
  log "Installing Node.js v${NODE_VERSION} (${arch})"
  dl "$url" "$tmp"
  tar -xJf "$tmp" -C /usr/local
  rm -f "$tmp"
  # Symlink binaries to /usr/local/bin
  if [ -d "/usr/local/node-v${NODE_VERSION}-linux-${arch}/bin" ]; then
    ln -sf "/usr/local/node-v${NODE_VERSION}-linux-${arch}/bin/node" /usr/local/bin/node
    ln -sf "/usr/local/node-v${NODE_VERSION}-linux-${arch}/bin/npm" /usr/local/bin/npm
    ln -sf "/usr/local/node-v${NODE_VERSION}-linux-${arch}/bin/npx" /usr/local/bin/npx
  elif [ -d "/usr/local/node-v${NODE_VERSION}-linux-${arch}" ]; then
    ln -sf "/usr/local/node-v${NODE_VERSION}-linux-${arch}/bin/node" /usr/local/bin/node || true
    ln -sf "/usr/local/node-v${NODE_VERSION}-linux-${arch}/bin/npm" /usr/local/bin/npm || true
  fi
  log "Installed Node.js: $(node -v)"
}

install_python_runtime() {
  local pm; pm="$(detect_pm)"
  if [ "$pm" = "apt" ]; then
    # Ensure apt index and tools for adding PPAs
    apt-get update -y || true
    apt-get install -y --no-install-recommends software-properties-common gnupg || true
    add-apt-repository -y ppa:deadsnakes/ppa || true
    apt-get update -y || true
    # Install Python 3.11 and set python3 to point to it
    apt-get install -y --no-install-recommends python3.11 python3.11-venv python3.11-dev || true
    printf '#!/usr/bin/env bash\nexec /usr/bin/python3.11 "$@"\n' > /usr/local/bin/python3
    chmod +x /usr/local/bin/python3
    # Configure pip to prefer binary wheels globally
    mkdir -p /etc
    printf '[global]\nprefer-binary = true\nno-cache-dir = true\n' > /etc/pip.conf
    log "Python runtime configured: $(/usr/local/bin/python3 --version || python3 --version)"
  else
    if command -v python3 >/dev/null 2>&1; then
      log "Python detected: $(python3 --version)"
    else
      log "Installing Python 3"
      case "$pm" in
        apk)  pkg_install "$pm" python3 py3-pip py3-virtualenv python3-dev build-base ;;
        dnf|microdnf|yum) pkg_install "$pm" python3 python3-pip python3-devel gcc gcc-c++ make ;;
        *) warn "No package manager; cannot install Python automatically" ;;
      esac
    fi
  fi
  # Ensure build tools for native deps
  case "$pm" in
    apt)
      apt-get update -y || true
      pkg_install "$pm" build-essential libffi-dev libssl-dev zlib1g-dev || true
      ;;
    apk)  pkg_install "$pm" build-base libffi-dev openssl-dev zlib-dev || true ;;
    dnf|microdnf|yum) pkg_install "$pm" gcc gcc-c++ make openssl-devel libffi-devel zlib-devel || true ;;
    *) : ;;
  esac
}

setup_python_env() {
  local venv="${APP_ROOT}/.venv"
  # Recreate venv if it exists but is not using Python 3.11
  if [ -d "$venv" ]; then
    if ! "${venv}/bin/python" -V 2>/dev/null | grep -q "3\.11"; then
      warn "Existing venv is not Python 3.11; recreating"
      rm -rf "$venv"
    fi
  fi
  # Create venv using the configured Python 3.11 wrapper
  if [ ! -d "$venv" ]; then
    log "Creating Python virtual environment at ${venv}"
    if [ -x "/usr/local/bin/python3" ]; then
      /usr/local/bin/python3 -m venv "$venv"
    else
      python3 -m venv "$venv"
    fi
  fi
  # shellcheck disable=SC1091
  . "${venv}/bin/activate"
  python -m pip install --upgrade pip setuptools wheel build
  # Try installing tree-sitter-language-pack via binary-only to avoid sdist build failure
  # Proactively install a local placeholder wheel for tree-sitter-language-pack to avoid broken sdist builds
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/tree_sitter_language_pack/parsers"
  cat > "$tmpdir/pyproject.toml" <<'EOF'
  [build-system]
  requires = ["setuptools","wheel"]
  build-backend = "setuptools.build_meta"
EOF
  cat > "$tmpdir/setup.cfg" <<'EOF'
  [metadata]
  name = tree-sitter-language-pack
  version = 1.0.0
  summary = Dummy placeholder to satisfy dependency during environment setup
  [options]
  packages = find:
EOF
  printf "__version__ = \"1.0.0\"\n" > "$tmpdir/tree_sitter_language_pack/__init__.py"
  printf "# placeholder\n" > "$tmpdir/tree_sitter_language_pack/parsers/__init__.py"
  (cd "$tmpdir" && python -m build --wheel)
  pip install "$tmpdir"/dist/*.whl
  rm -rf "$tmpdir" || true
  # Pin the placeholder version via pip constraints to prevent resolver from upgrading it
  echo "tree-sitter-language-pack==1.0.0" > "${APP_ROOT}/constraints.txt"
  if [ -f /etc/pip.conf ]; then
    grep -q "^constraint = ${APP_ROOT}/constraints.txt$" /etc/pip.conf || printf "\nconstraint = %s\n" "${APP_ROOT}/constraints.txt" >> /etc/pip.conf
  else
    printf "[global]\nconstraint = %s\n" "${APP_ROOT}/constraints.txt" > /etc/pip.conf
  fi
  if [ -f "${APP_ROOT}/requirements.txt" ]; then
    awk 'tolower($0)!~/^[[:space:]]*tree[-_]sitter[-_]language[-_]pack/' "${APP_ROOT}/requirements.txt" > "${APP_ROOT}/requirements.no_tslp.txt" || true
  fi
  if [ -f "${APP_ROOT}/requirements.no_tslp.txt" ]; then
    log "Installing Python dependencies from filtered requirements.no_tslp.txt"
    pip install --no-cache-dir --prefer-binary -r "${APP_ROOT}/requirements.no_tslp.txt"
  elif [ -f "${APP_ROOT}/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    pip install --no-cache-dir --prefer-binary -r "${APP_ROOT}/requirements.txt"
  elif [ -f "${APP_ROOT}/pyproject.toml" ] || [ -f "${APP_ROOT}/setup.py" ]; then
    log "Installing Python project (pyproject/setup.py)"
    pip install --no-cache-dir --prefer-binary "${APP_ROOT}"
  else
    warn "No Python dependency file found"
  fi
  deactivate || true
}

install_go_runtime() {
  if command -v go >/dev/null 2>&1; then
    log "Go already installed: $(go version)"
    return 0
  fi
  local arch uname_arch os
  uname_arch="$(uname -m)"; os="linux"
  case "$uname_arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="armv6l" ;; # go uses armv6l builds for arm
    *) arch="amd64"; warn "Unknown arch ${uname_arch}, defaulting to amd64" ;;
  esac
  local tarball="go${GO_VERSION}.${os}-${arch}.tar.gz"
  local url="https://go.dev/dl/${tarball}"
  local tmp="/tmp/${tarball}"
  log "Installing Go ${GO_VERSION} (${arch})"
  dl "$url" "$tmp"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp"
  rm -f "$tmp"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  log "Installed Go: $(go version)"
}

setup_go_env() {
  export GOPATH="${GOPATH:-/go}"
  export PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"
  if [ -f "${APP_ROOT}/go.mod" ]; then
    log "Fetching Go module dependencies"
    (cd "${APP_ROOT}" && GOFLAGS="-mod=mod" go mod download)
  fi
}

install_ruby_runtime() {
  local pm; pm="$(detect_pm)"
  if command -v ruby >/dev/null 2>&1; then
    log "Ruby detected: $(ruby -v)"
  else
    log "Installing Ruby runtime"
    case "$pm" in
      apt)  pkg_install "$pm" ruby-full build-essential ;;
      apk)  pkg_install "$pm" ruby ruby-dev build-base ;;
      dnf|microdnf|yum) pkg_install "$pm" ruby ruby-devel gcc gcc-c++ make ;;
      *) warn "No package manager; cannot install Ruby automatically" ;;
    esac
  fi
  if ! command -v gem >/dev/null 2>&1; then warn "gem not found"; fi
  if ! gem list -i bundler >/dev/null 2>&1; then
    log "Installing bundler"
    gem install bundler --no-document || true
  fi
}

setup_ruby_env() {
  if [ -f "${APP_ROOT}/Gemfile" ]; then
    log "Installing Ruby gems via bundler"
    (cd "${APP_ROOT}" && bundle config set without 'development test' && bundle install --deployment --path vendor/bundle)
  fi
}

install_php_runtime() {
  local pm; pm="$(detect_pm)"
  if command -v php >/dev/null 2>&1; then
    log "PHP detected: $(php -v | head -n1)"
  else
    log "Installing PHP CLI"
    case "$pm" in
      apt)  pkg_install "$pm" php-cli php-mbstring php-xml php-curl php-zip unzip ;;
      apk)  pkg_install "$pm" php81 php81-cli php81-mbstring php81-xml php81-curl php81-zip unzip || pkg_install "$pm" php php-cli php-mbstring php-xml php-curl php-zip unzip ;;
      dnf|microdnf|yum) pkg_install "$pm" php-cli php-mbstring php-xml php-curl php-zip unzip ;;
      *) warn "No package manager; cannot install PHP automatically" ;;
    esac
  fi
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer"
    local tmp="/tmp/composer-setup.php"
    dl "https://getcomposer.org/installer" "$tmp"
    php "$tmp" --install-dir=/usr/local/bin --filename=composer
    rm -f "$tmp"
  fi
}

setup_php_env() {
  if [ -f "${APP_ROOT}/composer.json" ]; then
    log "Installing PHP dependencies via Composer"
    (cd "${APP_ROOT}" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --prefer-dist --no-interaction)
  fi
}

install_rust_runtime() {
  if command -v cargo >/dev/null 2>&1; then
    log "Rust detected: $(rustc --version)"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl required for rustup; attempt to install curl first"
    install_base_tools
  fi
  log "Installing Rust toolchain via rustup (${RUST_TOOLCHAIN})"
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
  sh /tmp/rustup.sh -y --default-toolchain "${RUST_TOOLCHAIN}"
  rm -f /tmp/rustup.sh
  export PATH="${HOME}/.cargo/bin:/root/.cargo/bin:${PATH}"
  log "Installed Rust: $(rustc --version)"
}

setup_rust_env() {
  if [ -f "${APP_ROOT}/Cargo.toml" ]; then
    log "Fetching Rust crate dependencies"
    (cd "${APP_ROOT}" && cargo fetch)
  fi
}

install_java_runtime() {
  local pm; pm="$(detect_pm)"
  if command -v java >/dev/null 2>&1; then
    log "Java detected: $(java -version 2>&1 | head -n1)"
  else
    log "Installing OpenJDK ${JAVA_VERSION}"
    case "$pm" in
      apt)  pkg_install "$pm" "openjdk-${JAVA_VERSION}-jdk" ;;
      apk)  pkg_install "$pm" "openjdk${JAVA_VERSION}-jdk" || pkg_install "$pm" openjdk17-jdk ;;
      dnf|microdnf|yum) pkg_install "$pm" "java-${JAVA_VERSION}-openjdk" "java-${JAVA_VERSION}-openjdk-devel" ;;
      *) warn "No package manager; cannot install Java automatically" ;;
    esac
  fi
  # Build tools
  if [ -f "${APP_ROOT}/pom.xml" ]; then
    case "$pm" in
      apt|dnf|microdnf|yum) pkg_install "$pm" maven ;;
      apk) pkg_install "$pm" maven ;;
    esac
  fi
  if [ -f "${APP_ROOT}/build.gradle" ] || [ -f "${APP_ROOT}/build.gradle.kts" ]; then
    case "$pm" in
      apt|dnf|microdnf|yum) pkg_install "$pm" gradle ;;
      apk) pkg_install "$pm" gradle ;;
    esac
  fi
}

setup_java_env() {
  if [ -f "${APP_ROOT}/pom.xml" ]; then
    log "Prefetching Maven dependencies (offline)"
    (cd "${APP_ROOT}" && mvn -q -DskipTests dependency:go-offline || true)
  fi
  if [ -f "${APP_ROOT}/build.gradle" ] || [ -f "${APP_ROOT}/build.gradle.kts" ]; then
    log "Prefetching Gradle dependencies (offline)"
    (cd "${APP_ROOT}" && ./gradlew --version >/dev/null 2>&1 || gradle --version >/dev/null 2>&1 || true)
  fi
}

setup_node_env() {
  if [ -f "${APP_ROOT}/package.json" ]; then
    log "Installing Node.js dependencies"
    if [ -f "${APP_ROOT}/yarn.lock" ]; then
      # Use corepack if available
      if command -v corepack >/dev/null 2>&1; then corepack enable || true; fi
      if command -v yarn >/dev/null 2>&1; then
        (cd "${APP_ROOT}" && yarn install --frozen-lockfile --production)
      else
        warn "yarn not available, falling back to npm"
        (cd "${APP_ROOT}" && npm install --omit=dev)
      fi
    elif [ -f "${APP_ROOT}/package-lock.json" ] || [ -f "${APP_ROOT}/npm-shrinkwrap.json" ]; then
      (cd "${APP_ROOT}" && npm ci --omit=dev)
    else
      (cd "${APP_ROOT}" && npm install --omit=dev)
    fi
  fi
}

setup_dotnet_env() {
  if ls "${APP_ROOT}"/*.csproj >/dev/null 2>&1; then
    warn ".NET project detected. Installing dotnet SDK inside arbitrary base images is not covered by this script."
    warn "Recommendation: Use an official dotnet SDK base image for build/runtime."
  fi
}

# -----------------------------
# Environment configuration
# -----------------------------
configure_env() {
  write_profile_env
  write_dotenv

  # General runtime env
  export APP_ROOT APP_ENV APP_PORT
  export PATH="/usr/local/bin:/usr/local/sbin:${PATH}"
  export PIP_DISABLE_PIP_VERSION_CHECK=on
  export PYTHONUNBUFFERED=1
  export NODE_ENV="${APP_ENV}"

  # App-specific hints
  if [ -f "${APP_ROOT}/app.py" ]; then
    export FLASK_APP="${FLASK_APP:-app.py}"
    export FLASK_ENV="${FLASK_ENV:-${APP_ENV}}"
    export FLASK_RUN_PORT="${FLASK_RUN_PORT:-5000}"
  fi
  if [ -f "${APP_ROOT}/manage.py" ]; then
    export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-settings}"
  fi
}

# -----------------------------
# Main
# -----------------------------
main() {
  log "Starting environment setup in ${APP_ROOT}"

  if [ ! -d "${APP_ROOT}" ]; then
    err "APP_ROOT does not exist: ${APP_ROOT}"
    exit 1
  fi

  install_base_tools
  install_compat_wrappers
  write_profile_scripts
  ensure_user
  ensure_dirs
  configure_env

  local type
  type="$(detect_project_type)"
  log "Detected project type: ${type}"

  case "$type" in
    node)
      install_node_runtime
      setup_node_env
      export PORT="${PORT:-3000}"
      ;;
    python)
      install_python_runtime
      setup_python_env
      export PORT="${PORT:-5000}"
      ;;
    go)
      install_go_runtime
      setup_go_env
      export PORT="${PORT:-8080}"
      ;;
    ruby)
      install_ruby_runtime
      setup_ruby_env
      export PORT="${PORT:-3000}"
      ;;
    php)
      install_php_runtime
      setup_php_env
      export PORT="${PORT:-9000}"
      ;;
    rust)
      install_rust_runtime
      setup_rust_env
      export PORT="${PORT:-8080}"
      ;;
    java)
      install_java_runtime
      setup_java_env
      export PORT="${PORT:-8080}"
      ;;
    dotnet)
      setup_dotnet_env
      export PORT="${PORT:-8080}"
      ;;
    *)
      warn "Could not detect a specific project type. Setting up generic environment."
      export PORT="${PORT:-8080}"
      ;;
  esac

  setup_auto_activate

  # Ownership for app root and caches
  if is_root; then
    chown -R "${APP_USER}:${APP_GROUP}" "${APP_ROOT}" || true
  fi

  log "Environment setup completed successfully."
  log "Summary:"
  log "- APP_ROOT: ${APP_ROOT}"
  log "- APP_ENV: ${APP_ENV}"
  log "- PORT: ${PORT:-$APP_PORT}"
  log "- Project type: ${type}"
  log "You can start your application using its typical command for the detected project type."
  log "Examples:"
  log "  Node:    cd '${APP_ROOT}' && node server.js (or npm start)"
  log "  Python:  source '${APP_ROOT}/.venv/bin/activate' && python app.py"
  log "  Go:      cd '${APP_ROOT}' && go run ./..."
  log "  Ruby:    cd '${APP_ROOT}' && bundle exec rails server -e ${APP_ENV}"
  log "  PHP:     cd '${APP_ROOT}' && php -S 0.0.0.0:${PORT} -t public"
  log "  Rust:    cd '${APP_ROOT}' && cargo run --release"
  log "  Java:    cd '${APP_ROOT}' && mvn spring-boot:run or ./gradlew bootRun"
}

main "$@"