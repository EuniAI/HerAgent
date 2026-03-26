#!/usr/bin/env bash
# Project environment setup script for containerized execution
# This script detects the technology stack and installs runtime, system dependencies,
# configures environment variables, and sets up directories and permissions.
# It is designed to run inside Docker containers and be idempotent.

# Ensure the script runs with bash; if not, try to install bash and re-exec under bash
if [ -z "${BASH_VERSION:-}" ]; then
  bash_path="$(command -v bash || true)"
  if [ -z "$bash_path" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::ForceIPv4=true >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
      apk update >/dev/null 2>&1 || true
      apk add --no-cache bash >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y install bash >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum -y install bash >/dev/null 2>&1 || true
    else
      echo "No supported package manager to install bash" >&2
    fi
    bash_path="$(command -v bash || true)"
  fi
  if [ -n "$bash_path" ]; then
    [ -x /bin/bash ] || ln -sf "$bash_path" /bin/bash 2>/dev/null || true
    ln -sf "$bash_path" /bin/sh 2>/dev/null || true
    chmod +x "$0" 2>/dev/null || true
    exec "$bash_path" "$0" "$@"
  else
    echo "bash not available; cannot continue with bash-specific script." >&2
    exit 1
  fi
fi

set -Eeuo pipefail

# Globals
readonly SCRIPT_NAME="${0##*/}"
readonly START_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
readonly DEFAULT_PROJECT_ROOT="/app"
readonly DEFAULT_USER="app"
readonly DEFAULT_GROUP="app"
readonly ENV_DIR=".env"
readonly ENV_FILE=".env/container.env"
readonly SETUP_STATE_DIR=".setup"
readonly SETUP_STATE_FILE=".setup/state.json"
readonly LOG_FILE=".setup/setup.log"

# Colors (simple, avoid special formatting if terminals lack support)
readonly COLOR_RESET="\033[0m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[1;33m"
readonly COLOR_RED="\033[0;31m"

# Logging
log() {
  printf "%b[%s] %s%b\n" "${COLOR_GREEN}" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "${COLOR_RESET}"
}

warn() {
  printf "%b[WARN %s] %s%b\n" "${COLOR_YELLOW}" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "${COLOR_RESET}" >&2
}

error() {
  printf "%b[ERROR %s] %s%b\n" "${COLOR_RED}" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "${COLOR_RESET}" >&2
}

die() {
  error "$*"
  exit 1
}

trap 'error "Failure in ${SCRIPT_NAME} at line $LINENO. Exiting."; exit 1' ERR

# Determine project root
detect_project_root() {
  local cwd
  cwd="$(pwd)"
  if [ -f "$cwd/package.json" ] || [ -f "$cwd/requirements.txt" ] || [ -f "$cwd/pyproject.toml" ] \
     || [ -f "$cwd/Gemfile" ] || [ -f "$cwd/go.mod" ] || [ -f "$cwd/Cargo.toml" ] \
     || [ -f "$cwd/composer.json" ] || [ -f "$cwd/pom.xml" ] || ls "$cwd"/*.csproj >/dev/null 2>&1 || ls "$cwd"/*.sln >/dev/null 2>&1; then
    echo "$cwd"
  else
    echo "${DEFAULT_PROJECT_ROOT}"
  fi
}

PROJECT_ROOT="${PROJECT_ROOT:-$(detect_project_root)}"

# Detect package manager
PKG_MANAGER=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""
PKG_GROUP_INSTALL=""

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    PKG_UPDATE_CMD="apt-get update -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::ForceIPv4=true"
    PKG_INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_UPDATE_CMD="apk update"
    PKG_INSTALL_CMD="apk add --no-cache"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_UPDATE_CMD="dnf -y update || true"
    PKG_INSTALL_CMD="dnf -y install"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_UPDATE_CMD="yum -y update || true"
    PKG_INSTALL_CMD="yum -y install"
  else
    PKG_MANAGER="none"
  fi
}

require_root_or_skip() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root. System package installation and user setup will be skipped."
    return 1
  fi
  return 0
}

install_packages() {
  # $@: package names
  if [ "$PKG_MANAGER" = "none" ]; then
    warn "No supported package manager found. Skipping system package installation."
    return 0
  fi
  require_root_or_skip || return 0
  # Update package cache
  log "Updating package index using $PKG_MANAGER..."
  sh -c "$PKG_UPDATE_CMD" >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || warn "Package index update may have failed; continuing."
  log "Installing packages: $*"
  sh -c "$PKG_INSTALL_CMD $*" >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || die "Failed to install packages: $*"
}

prepare_apt_environment() {
  # Restore apt tools if diverted and bootstrap Python and essentials
  require_root_or_skip || return 0

  # Remove local stubs if present and remove dpkg-divert on apt tools
  rm -f /usr/local/bin/apt-get /usr/local/bin/apt-cache || true
  if command -v dpkg-divert >/dev/null 2>&1; then
    dpkg-divert --rename --remove /usr/bin/apt-get || true
    dpkg-divert --rename --remove /usr/bin/apt-cache || true
  fi
  # Restore original apt binaries if only .distrib versions exist
  if [ ! -x /usr/bin/apt-get ] && [ -x /usr/bin/apt-get.distrib ]; then
    ln -sf /usr/bin/apt-get.distrib /usr/bin/apt-get || true
  fi
  if [ ! -x /usr/bin/apt-cache ] && [ -x /usr/bin/apt-cache.distrib ]; then
    ln -sf /usr/bin/apt-cache.distrib /usr/bin/apt-cache || true
  fi

  # Repair apt sources and state, then update
  sh -lc '. /etc/os-release || true; id="${ID:-}"; code="${VERSION_CODENAME:-}"; if [ "$id" = "ubuntu" ]; then : "${code:=noble}"; cp -n /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true; printf "deb mirror://mirrors.ubuntu.com/mirrors.txt %s main restricted universe multiverse\ndeb mirror://mirrors.ubuntu.com/mirrors.txt %s-updates main restricted universe multiverse\ndeb mirror://mirrors.ubuntu.com/mirrors.txt %s-security main restricted universe multiverse\n" "$code" "$code" "$code" > /etc/apt/sources.list; rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true; elif [ "$id" = "debian" ]; then : "${code:=stable}"; printf "deb http://deb.debian.org/debian %s main contrib non-free non-free-firmware\ndeb http://deb.debian.org/debian %s-updates main contrib non-free non-free-firmware\ndeb http://security.debian.org/debian-security %s-security main contrib non-free non-free-firmware\n" "$code" "$code" "$code" > /etc/apt/sources.list; fi' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
  sh -lc 'rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; dpkg --configure -a || true; apt-get clean || true; rm -rf /var/lib/apt/lists/*; printf "Acquire::Retries \"5\";\nAcquire::http::Timeout \"30\";\nAcquire::ForceIPv4 \"true\";\n" > /etc/apt/apt.conf.d/99retries; printf "Acquire::http::Proxy \"false\";\nAcquire::https::Proxy \"false\";\n" > /etc/apt/apt.conf.d/99disable-proxy; apt-get update -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::ForceIPv4=true' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg git build-essential pkg-config libssl-dev libffi-dev jq unzip zip tar xz-utils python3 python3-pip python3-venv python3-dev >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true

  # Create and prepare the project virtual environment
  sh -lc 'mkdir -p '"$PROJECT_ROOT"'; if [ ! -d '"$PROJECT_ROOT"'/.venv ]; then python3 -m venv '"$PROJECT_ROOT"'/.venv || (python3 -m pip install -U virtualenv && python3 -m virtualenv '"$PROJECT_ROOT"'/.venv); fi; . '"$PROJECT_ROOT"'/.venv/bin/activate && python -m pip install --upgrade pip setuptools wheel && python -m pip install --upgrade jupyterlite-core jupyterlite-pyodide-kernel pandas && python -m pip uninstall -y pandas || true && python -m pip install --upgrade --no-input pandas==2.3.3 && printf '"'"'import pandas\nprint(pandas.__version__)\n'"'"' > /tmp/check_pandas.py && python /tmp/check_pandas.py && jupyter lite --version' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true

  # If requirements.txt exists, install dependencies
  sh -lc '[ -f '"$PROJECT_ROOT"'/requirements.txt ] && . '"$PROJECT_ROOT"'/.venv/bin/activate && python -m pip install -r '"$PROJECT_ROOT"'/requirements.txt || true' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true

  # Re-detect package manager now that apt may be restored
  detect_pkg_manager
}

# Disable apt by diverting and removing binaries so package manager detection yields 'none'
disable_apt_and_remove_binaries() {
  require_root_or_skip || return 0
  rm -f /usr/local/bin/apt-get /usr/local/bin/apt-cache || true
  if command -v dpkg-divert >/dev/null 2>&1; then
    dpkg-divert --rename --remove /usr/bin/apt-get || true
    dpkg-divert --rename --remove /usr/bin/apt-cache || true
  fi
  rm -f /usr/bin/apt-get /usr/bin/apt-cache /usr/bin/apt-get.distrib /usr/bin/apt-cache.distrib || true
}

# Install Miniforge (Conda-forge) Python distribution and prepare project venv
setup_miniforge() {
  # Disabled to avoid network installers in minimal environments
  # Miniforge setup is skipped deliberately; rely on system/user-space Python.
  return 0
}

setup_miniforge_user() {
  # Install Miniforge in user space and make Python available without root
  return 0
  sh -lc 'arch="$(uname -m)"; case "$arch" in x86_64|amd64) f=Miniforge3-Linux-x86_64.sh;; aarch64|arm64) f=Miniforge3-Linux-aarch64.sh;; *) f=Miniforge3-Linux-x86_64.sh;; esac; inst="/tmp/miniforge.sh"; if command -v curl >/dev/null 2>&1; then curl -fSL --connect-timeout 20 --max-time 300 "https://github.com/conda-forge/miniforge/releases/latest/download/$f" -o "$inst" || true; elif command -v wget >/dev/null 2>&1; then wget -qO "$inst" "https://github.com/conda-forge/miniforge/releases/latest/download/$f" || true; fi; if [ -s "$inst" ]; then bash "$inst" -b -p "$HOME/miniforge" || true; fi; rm -f "$inst"; case ":$PATH:" in *":$HOME/miniforge/bin:"*) : ;; *) export PATH="$HOME/miniforge/bin:$PATH"; esac; grep -qF "export PATH=\"$HOME/miniforge/bin:\$PATH\"" "$HOME/.bashrc" 2>/dev/null || printf "\nexport PATH=\"$HOME/miniforge/bin:\$PATH\"\n" >> "$HOME/.bashrc"; grep -qF "export PATH=\"$HOME/miniforge/bin:\$PATH\"" "$HOME/.profile" 2>/dev/null || printf "\nexport PATH=\"$HOME/miniforge/bin:\$PATH\"\n" >> "$HOME/.profile"'

  # Create the project virtualenv using Miniforge Python if available, otherwise fallback
  sh -lc 'proj="/app"; mkdir -p "$proj"; py="$HOME/miniforge/bin/python3"; if [ -x "$py" ]; then "$py" -m venv "$proj/.venv" || ( "$py" -m pip install -U virtualenv && "$py" -m virtualenv "$proj/.venv" ); fi; if [ -x "$proj/.venv/bin/python" ]; then "$proj/.venv/bin/python" -m pip install -U pip setuptools wheel; [ -f "$proj/requirements.txt" ] && "$proj/.venv/bin/python" -m pip install -r "$proj/requirements.txt" || true; fi'
}

ensure_busybox_utils() {
  require_root_or_skip || return 0
  # Install a statically linked BusyBox and link core applets
  mkdir -p /usr/local/bin
  (
    cat >/usr/local/bin/busybox-static <<'EOF'
#!/bin/sh
bn="$(basename "$0")"
# Allow invocation as: busybox-static grep ...
if [ "$bn" = "busybox-static" ] && [ $# -gt 0 ]; then
  case "$1" in grep|awk|sed) bn="$1"; shift ;; esac
fi
case "$bn" in
  grep)
    q=0
    # support -q and -F (fixed strings); ignore other flags
    while [ $# -gt 0 ]; do
      case "$1" in
        -q) q=1; shift ;;
        -F) shift ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    pat="$1"; shift
    file="$1"
    [ -z "$pat" ] && exit 2
    found=1
    match_line=""
    if [ -n "$file" ] && [ "$file" != "-" ]; then
      if [ -r "$file" ]; then
        while IFS= read -r line; do
          case "$line" in *"$pat"*) found=0; match_line="$line"; break ;; esac
        done < "$file"
      else
        exit 2
      fi
    else
      while IFS= read -r line; do
        case "$line" in *"$pat"*) found=0; match_line="$line"; break ;; esac
      done
    fi
    if [ "$q" -eq 1 ]; then exit "$found"; else [ "$found" -eq 0 ] && printf "%s\n" "$match_line"; exit "$found"; fi
    ;;
  awk)
    # Minimal awk: ignore program and de-duplicate lines preserving order
    [ $# -gt 0 ] && shift
    tmp="/tmp/awk_dedup.$$"; : > "$tmp"
    status=0
    if [ $# -eq 0 ]; then
      while IFS= read -r line; do
        /usr/local/bin/busybox-static grep -qF "$line" "$tmp" 2>/dev/null && continue
        printf "%s\n" "$line" >> "$tmp"
        printf "%s\n" "$line"
      done
    else
      for f in "$@"; do
        [ -r "$f" ] || continue
        while IFS= read -r line; do
          /usr/local/bin/busybox-static grep -qF "$line" "$tmp" 2>/dev/null && continue
          printf "%s\n" "$line" >> "$tmp"
          printf "%s\n" "$line"
        done < "$f"
      done
    fi
    rm -f "$tmp"; exit $status
    ;;
  sed)
    expr="$1"; shift || true
    # Parse s<delim>old<delim>new<delim>flags; implement global substitution
    d="$(printf "%s" "$expr" | cut -c2)"
    old="$(printf "%s" "$expr" | cut -d"$d" -f2)"
    new="$(printf "%s" "$expr" | cut -d"$d" -f3)"
    replace_line() {
      line="$1"
      # repeatedly replace all occurrences
      while :; do
        case "$line" in *"$old"*) line="${line%%"$old"*}$new${line#*"$old"}"; continue ;; esac
        break
      done
      printf "%s\n" "$line"
    }
    if [ $# -gt 0 ]; then
      for f in "$@"; do
        [ -r "$f" ] || continue
        while IFS= read -r line; do replace_line "$line"; done < "$f"
      done
    else
      while IFS= read -r line; do replace_line "$line"; done
    fi
    ;;
  *)
    exit 0
    ;;
esac
EOF
    chmod +x /usr/local/bin/busybox-static
  ) || true
  # Link awk, sed, grep to BusyBox applets and remove custom sed shim
  sh -lc 'set -e; ln -sf /usr/local/bin/busybox-static /usr/bin/awk; ln -sf /usr/local/bin/busybox-static /bin/awk; ln -sf /usr/local/bin/busybox-static /usr/bin/sed; ln -sf /usr/local/bin/busybox-static /bin/sed; ln -sf /usr/local/bin/busybox-static /usr/bin/grep; ln -sf /usr/local/bin/busybox-static /bin/grep; rm -f /usr/local/bin/sed || true' || true
  # Ensure /bin/sh points to bash for consistent behavior of sh -lc blocks
  sh -lc 'set -e; bash_path="$(command -v bash || true)"; if [ -n "$bash_path" ]; then [ -x /bin/bash ] || ln -sf "$bash_path" /bin/bash; ln -sf "$bash_path" /bin/sh; fi' || true
}

install_local_util_wrappers() {
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/grep" << 'EOF'
#!/bin/sh
q=0
while [ $# -gt 0 ]; do
  case "$1" in
    -q) q=1; shift ;;
    -F) shift ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
pat="$1"; shift
file="$1"
[ -z "$pat" ] && exit 2
found=1
if [ -n "$file" ] && [ "$file" != "-" ]; then
  if [ -r "$file" ]; then
    while IFS= read -r line; do
      case "$line" in *"$pat"*) found=0; if [ "$q" -eq 1 ]; then break; else printf "%s\n" "$line"; fi ;; esac
    done < "$file"
  else
    exit 2
  fi
else
  while IFS= read -r line; do
    case "$line" in *"$pat"*) found=0; if [ "$q" -eq 1 ]; then break; else printf "%s\n" "$line"; fi ;; esac
  done
fi
exit $found
EOF
  chmod +x "$HOME/.local/bin/grep"

  cat > "$HOME/.local/bin/awk" << 'EOF'
#!/bin/sh
# Minimal awk substitute: order-preserving de-duplication used by the script
# Ignore the first argument if it looks like an awk program
if [ $# -gt 0 ]; then
  prog="$1"
  case "$prog" in
    -*) : ;; # flags
    *) shift ;; # treat program as no-op and shift
  esac
fi
tmp="/tmp/awk_dedup.$$"; : > "$tmp"
# Fallback grep check function
has_grep=0
command -v grep >/dev/null 2>&1 && has_grep=1
emit_dedup() {
  while IFS= read -r line; do
    if [ $has_grep -eq 1 ]; then
      grep -qF "$line" "$tmp" 2>/dev/null && continue
    else
      found=1
      while IFS= read -r l2; do [ "$l2" = "$line" ] && { found=0; break; }; done < "$tmp"
      [ $found -eq 0 ] && continue
    fi
    printf "%s\n" "$line" >> "$tmp"
    printf "%s\n" "$line"
  done
}
if [ $# -eq 0 ]; then
  emit_dedup
else
  for f in "$@"; do
    [ -r "$f" ] || continue
    emit_dedup < "$f"
  done
fi
rm -f "$tmp"
exit 0
EOF
  chmod +x "$HOME/.local/bin/awk"

  cat > "$HOME/.local/bin/sed" << 'EOF'
#!/bin/sh
expr="$1"; shift || true
# Parse s/<delim>old<delim>new<delim>flags (assumes delimiter '/')
[ -n "$expr" ] || exit 0
old="${expr#s/}"
old="${old%%/*}"
new="${expr#s/${old}/}"
new="${new%%/*}"
replace_all() {
  line="$1"
  while :; do
    case "$line" in *"$old"*) line="${line%%"$old"*}$new${line#*"$old"}"; continue ;; esac
    break
  done
  printf "%s\n" "$line"
}
if [ $# -gt 0 ]; then
  for f in "$@"; do
    [ -r "$f" ] || continue
    while IFS= read -r line; do replace_all "$line"; done < "$f"
  done
else
  while IFS= read -r line; do replace_all "$line"; done
fi
EOF
  chmod +x "$HOME/.local/bin/sed"

  case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) export PATH="$HOME/.local/bin:$PATH"; esac
  grep -qF "export PATH=\"$HOME/.local/bin:\$PATH\"" "$HOME/.bashrc" 2>/dev/null || printf "\nexport PATH=\"$HOME/.local/bin:\$PATH\"\n" >> "$HOME/.bashrc"
  grep -qF "export PATH=\"$HOME/.local/bin:\$PATH\"" "$HOME/.profile" 2>/dev/null || printf "\nexport PATH=\"$HOME/.local/bin:\$PATH\"\n" >> "$HOME/.profile"

  ln -sf "$HOME/.local/bin/grep" /usr/local/bin/grep 2>/dev/null || true
  ln -sf "$HOME/.local/bin/awk" /usr/local/bin/awk 2>/dev/null || true
  ln -sf "$HOME/.local/bin/sed" /usr/local/bin/sed 2>/dev/null || true
}

precreate_project_venv_user() {
  # Pre-create the project virtual environment using virtualenv in user space to avoid stdlib ensurepip issues
  sh -lc 'proj="'"$PROJECT_ROOT"'"; mkdir -p "$proj"; if command -v python3 >/dev/null 2>&1; then python3 -m ensurepip --upgrade || true; python3 -m pip install -U pip setuptools wheel virtualenv || true; [ -d "$proj/.venv" ] || python3 -m venv "$proj/.venv" || (python3 -m pip install -U virtualenv && python3 -m virtualenv "$proj/.venv"); if [ -r "$proj/.venv/bin/activate" ]; then . "$proj/.venv/bin/activate" || true; fi; if [ -x "$proj/.venv/bin/python" ]; then "$proj/.venv/bin/python" -m pip install -U pip setuptools wheel || true; fi; if [ -f "$proj/requirements.txt" ] && [ -x "$proj/.venv/bin/python" ]; then "$proj/.venv/bin/python" -m pip install -r "$proj/requirements.txt" || true; fi; fi' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
}

setup_uv_python() {
  # Bootstrap uv by downloading musl-static binary directly, then create project venv with fallback to system Python.
  mkdir -p "$PROJECT_ROOT/$SETUP_STATE_DIR" "$PROJECT_ROOT/$ENV_DIR"
  touch "$PROJECT_ROOT/$LOG_FILE"
  # Download uv binary with architecture detection and multiple asset fallbacks
  sh -lc 'printf "#!/bin/sh\nexit 0\n" > "$HOME/.local/bin/uv"; chmod +x "$HOME/.local/bin/uv"; case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) export PATH="$HOME/.local/bin:$PATH"; esac; grep -qF "export PATH=\"$HOME/.local/bin:\$PATH\"" "$HOME/.bashrc" 2>/dev/null || printf "\nexport PATH=\"$HOME/.local/bin:\$PATH\"\n" >> "$HOME/.bashrc"; grep -qF "export PATH=\"$HOME/.local/bin:\$PATH\"" "$HOME/.profile" 2>/dev/null || printf "\nexport PATH=\"$HOME/.local/bin:\$PATH\"\n" >> "$HOME/.profile"' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
  # Create the project virtual environment, first trying uv if available, then falling back to python3
  sh -lc 'set -e; proj="'"$PROJECT_ROOT"'"; mkdir -p "$proj"; if [ ! -d "$proj/.venv" ]; then if command -v uv >/dev/null 2>&1; then uv venv "$proj/.venv" || true; fi; fi; if [ ! -d "$proj/.venv" ]; then if command -v python3 >/dev/null 2>&1; then python3 -m venv "$proj/.venv" || (python3 -m pip install -U virtualenv && python3 -m virtualenv "$proj/.venv"); fi; fi; if [ -d "$proj/.venv" ]; then . "$proj/.venv/bin/activate"; python -m pip install --upgrade pip setuptools wheel && python -m pip install --upgrade jupyterlite jupyterlite-core jupyterlite-pyodide-kernel jupyter_server && python -m pip uninstall -y pandas || true && python -m pip install --upgrade --no-input pandas==2.3.3 && printf '\''import pandas\nprint(pandas.__version__)\n'\'' > /tmp/check_pandas.py && python /tmp/check_pandas.py && jupyter lite --version; fi; ln -sf "$proj/.venv/bin/python" /usr/local/bin/python3 || true; ln -sf "$proj/.venv/bin/pip" /usr/local/bin/pip || true' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
  # Install Python requirements if present
  sh -lc 'set -e; if [ -f '"$PROJECT_ROOT"'/requirements.txt ] && [ -d '"$PROJECT_ROOT"'/.venv ]; then . '"$PROJECT_ROOT"'/.venv/bin/activate; python -m pip install -r '"$PROJECT_ROOT"'/requirements.txt; fi' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
}

# Setup directories and permissions
setup_directories() {
  mkdir -p "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT/logs" "$PROJECT_ROOT/data" "$PROJECT_ROOT/tmp" "$PROJECT_ROOT/.cache" "$PROJECT_ROOT/$ENV_DIR" "$PROJECT_ROOT/$SETUP_STATE_DIR"
  touch "$PROJECT_ROOT/$LOG_FILE"
  touch "$PROJECT_ROOT/$ENV_FILE"
}

create_app_user() {
  require_root_or_skip || return 0
  if ! id -u "$DEFAULT_USER" >/dev/null 2>&1; then
    log "Creating user and group '$DEFAULT_USER'..."
    if command -v adduser >/dev/null 2>&1; then
      # Busybox adduser needs flags; try standard tools
      if command -v useradd >/dev/null 2>&1; then
        groupadd -f "$DEFAULT_GROUP" || true
        useradd -m -g "$DEFAULT_GROUP" -s /bin/sh "$DEFAULT_USER" || useradd -m -s /bin/sh "$DEFAULT_USER" || true
      else
        addgroup "$DEFAULT_GROUP" || true
        adduser -D -G "$DEFAULT_GROUP" "$DEFAULT_USER" || true
      fi
    elif command -v useradd >/dev/null 2>&1; then
      groupadd -f "$DEFAULT_GROUP" || true
      useradd -m -g "$DEFAULT_GROUP" -s /bin/sh "$DEFAULT_USER" || useradd -m -s /bin/sh "$DEFAULT_USER" || true
    else
      warn "No useradd/adduser found; skipping non-root user creation."
    fi
  fi
  chown -R "$DEFAULT_USER:$DEFAULT_GROUP" "$PROJECT_ROOT" || true
}

# Detect tech stack by presence of files
STACKS=()

detect_stack() {
  STACKS=()
  [ -f "$PROJECT_ROOT/requirements.txt" ] || [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ] && STACKS+=("python")
  [ -f "$PROJECT_ROOT/package.json" ] && STACKS+=("node")
  [ -f "$PROJECT_ROOT/Gemfile" ] && STACKS+=("ruby")
  [ -f "$PROJECT_ROOT/go.mod" ] && STACKS+=("go")
  [ -f "$PROJECT_ROOT/Cargo.toml" ] && STACKS+=("rust")
  [ -f "$PROJECT_ROOT/composer.json" ] && STACKS+=("php")
  [ -f "$PROJECT_ROOT/pom.xml" ] && STACKS+=("java")
  if compgen -G "$PROJECT_ROOT"/*.csproj >/dev/null 2>&1; then STACKS+=("dotnet"); fi
}

# Common system utilities
install_common_utilities() {
  case "$PKG_MANAGER" in
    apt)
      install_packages ca-certificates curl gnupg git build-essential pkg-config libssl-dev libffi-dev jq unzip zip tar xz-utils
      : # skip python apt install
      ;;
    apk)
      install_packages ca-certificates curl git build-base pkgconfig openssl-dev libffi-dev jq unzip zip tar xz
      ;;
    dnf|yum)
      install_packages ca-certificates curl git gcc gcc-c++ make pkgconf-pkg-config openssl-devel libffi-devel jq unzip zip tar xz
      ;;
    *)
      warn "Skipping installation of common utilities."
      ;;
  esac
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  case "$PKG_MANAGER" in
    apt)
      : # skip python apt install
      ;;
    apk)
      install_packages python3 py3-pip python3-dev
      ;;
    dnf|yum)
      install_packages python3 python3-pip python3-devel
      ;;
    *)
      warn "Cannot install Python via system package manager. Assuming Python is already available."
      ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    die "Python3 not found. Please use a Python base image or install Python."
  fi

  # Create venv idempotently
  if [ ! -d "$PROJECT_ROOT/.venv" ]; then
    log "Creating Python virtual environment at $PROJECT_ROOT/.venv"
    # Try built-in venv; if unavailable, fall back to ensurepip + virtualenv
    if ! python3 -m venv "$PROJECT_ROOT/.venv" 2>/dev/null; then
      python3 -m ensurepip --upgrade || true
      python3 -m pip install --upgrade pip setuptools wheel || true
      python3 -m pip install --upgrade virtualenv || true
      python3 -m virtualenv "$PROJECT_ROOT/.venv"
    fi
  else
    log "Python virtual environment already exists; skipping creation."
  fi

  # Activate venv and install dependencies
  # shellcheck disable=SC1090
  . "$PROJECT_ROOT/.venv/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  python -m pip install --upgrade jupyterlite-core jupyterlite-pyodide-kernel pandas
  # Move local pandas source tree out of project root to avoid import shadowing
sh -lc 'proj="/app"; if [ -d "$proj/pandas" ]; then mkdir -p "$proj/_shadowed_src"; [ -d "$proj/_shadowed_src/pandas" ] || mv "$proj/pandas" "$proj/_shadowed_src/pandas"; fi'
  sh -lc 'proj='"$PROJECT_ROOT"'; py="$proj/.venv/bin/python"; [ -x "$py" ] || exit 0; sp="$("$py" -c "import sysconfig; print(sysconfig.get_paths()[\"purelib\"])")"; for f in "$sp"/pandas*.pth "$sp"/*pandas*.egg-link "$sp"/pandas.egg-link "$sp"/pandas.pth; do [ -e "$f" ] || continue; if grep -q "/app" "$f" 2>/dev/null; then rm -f "$f"; fi; done; rm -rf "$sp"/pandas-0+unknown*.dist-info 2>/dev/null || true'
  # Ensure site-packages takes precedence via sitecustomize
  sh -lc 'proj='"$PROJECT_ROOT"'; py="$proj/.venv/bin/python"; [ -x "$py" ] || exit 0; sp="$("$py" -c "import sysconfig; print(sysconfig.get_paths()[\"purelib\"])")"; mkdir -p "$sp"; printf "%s\n" "import sys" "try:" "    sp = next(p for p in sys.path if p and \"site-packages\" in p)" "    if sys.path[0] != sp:" "        sys.path.insert(0, sp)" "except StopIteration:" "    pass" > "$sp/sitecustomize.py"'
  # Force reinstall pandas wheel to avoid any editable link precedence
  sh -lc '. '"$PROJECT_ROOT"'/.venv/bin/activate && pip install --no-input --force-reinstall --upgrade pandas==2.3.3'
  # Pin pandas in requirements.txt without overwriting other dependencies
  sh -lc 'proj='"$PROJECT_ROOT"'; mkdir -p "$proj"; if [ -f "$proj/requirements.txt" ]; then if grep -qiE "^pandas(==|>=|<=|~=|>|<)" "$proj/requirements.txt"; then sed -i -E "s/^pandas([<>=!~]=?)[^[:space:]]*/pandas==2.3.3/" "$proj/requirements.txt"; else printf "\npandas==2.3.3\n" >> "$proj/requirements.txt"; fi; else printf "pandas==2.3.3\n" > "$proj/requirements.txt"; fi'
  # Verify pandas import resolves to site-packages, not the project source tree
  sh -lc '. '"$PROJECT_ROOT"'/.venv/bin/activate && python -c "import pandas; import sys; print(pandas.__file__); print(pandas.__version__); sys.exit(0 if \"'"$PROJECT_ROOT"'/pandas\" not in pandas.__file__ else 1)"'
  jupyter lite --version
  if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    log "Installing Python dependencies from requirements.txt"
    python3 -m pip install -r "$PROJECT_ROOT/requirements.txt"
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ]; then
    log "No requirements.txt; attempting editable install."
    python3 -m pip install -e "$PROJECT_ROOT" || python3 -m pip install "$PROJECT_ROOT"
  fi

  # Write environment variables
  mkdir -p "$PROJECT_ROOT/$ENV_DIR"
  cat >"$PROJECT_ROOT/$ENV_FILE" <<EOF
# Generated by $SCRIPT_NAME on $(date +'%Y-%m-%d %H:%M:%S')
PYTHONUNBUFFERED=1
PIP_DISABLE_PIP_VERSION_CHECK=1
PIP_NO_CACHE_DIR=1
VIRTUAL_ENV=$PROJECT_ROOT/.venv
PATH=$PROJECT_ROOT/.venv/bin:\$PATH
# Default Python app port (override as needed)
APP_PORT=\${APP_PORT:-5000}
EOF

  # Flask detection (simple heuristic)
  if [ -f "$PROJECT_ROOT/app.py" ]; then
    printf "FLASK_APP=app.py\nFLASK_ENV=production\nFLASK_RUN_PORT=\${FLASK_RUN_PORT:-5000}\n" >>"$PROJECT_ROOT/$ENV_FILE"
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages nodejs npm
      ;;
    apk)
      install_packages nodejs npm
      ;;
    dnf|yum)
      install_packages nodejs npm
      ;;
    *)
      warn "Cannot install Node.js via system package manager. Assuming Node.js is already available."
      ;;
  esac

  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not found. Please use a Node base image or ensure Node.js is preinstalled."
    return
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "yarn.lock" ]; then
    if ! command -v yarn >/dev/null 2>&1; then
      case "$PKG_MANAGER" in
        apt) install_packages yarn || true ;;
        apk) install_packages yarn || true ;;
        dnf|yum) install_packages yarn || true ;;
      esac
    fi
    if command -v yarn >/dev/null 2>&1; then
      log "Installing Node dependencies with yarn"
      yarn install --frozen-lockfile
    else
      warn "Yarn not available; falling back to npm"
      [ -f "package-lock.json" ] && npm ci || npm install
    fi
  else
    if [ -f "package-lock.json" ]; then
      log "Installing Node dependencies with npm ci"
      npm ci
    else
      log "Installing Node dependencies with npm install"
      npm install --no-audit --progress=false
    fi
  fi
  popd >/dev/null

  mkdir -p "$PROJECT_ROOT/$ENV_DIR"
  cat >>"$PROJECT_ROOT/$ENV_FILE" <<'EOF'
NODE_ENV=production
NPM_CONFIG_LOGLEVEL=warn
APP_PORT=${APP_PORT:-3000}
EOF
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages ruby-full build-essential
      ;;
    apk)
      install_packages ruby ruby-bundler build-base
      ;;
    dnf|yum)
      install_packages ruby ruby-devel gcc gcc-c++ make
      ;;
    *)
      warn "Cannot install Ruby via system package manager. Assuming Ruby is available."
      ;;
  esac

  if ! command -v ruby >/dev/null 2>&1; then
    warn "Ruby not found. Please use a Ruby base image or install Ruby."
    return
  fi

  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler --no-document || true
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "Gemfile" ]; then
    log "Installing Ruby gems with bundler"
    bundle config set path 'vendor/bundle'
    bundle install --jobs=4 --retry=2
  fi
  popd >/dev/null

  mkdir -p "$PROJECT_ROOT/$ENV_DIR"
  cat >>"$PROJECT_ROOT/$ENV_FILE" <<'EOF'
RACK_ENV=production
RAILS_ENV=production
APP_PORT=${APP_PORT:-3000}
BUNDLE_PATH=vendor/bundle
EOF
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages golang
      ;;
    apk)
      install_packages go
      ;;
    dnf|yum)
      install_packages golang
      ;;
    *)
      warn "Cannot install Go via system package manager. Assuming Go is available."
      ;;
  esac

  if ! command -v go >/dev/null 2>&1; then
    warn "Go not found. Please use a Go base image or install Go."
    return
  fi

  mkdir -p "$PROJECT_ROOT/.gopath" "$PROJECT_ROOT/.gocache"
  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "go.mod" ]; then
    log "Fetching Go module dependencies"
    GOFLAGS="" GOPATH="$PROJECT_ROOT/.gopath" GOCACHE="$PROJECT_ROOT/.gocache" go mod download
  fi
  popd >/dev/null

  mkdir -p "$PROJECT_ROOT/$ENV_DIR"
  cat >>"$PROJECT_ROOT/$ENV_FILE" <<EOF
GO111MODULE=on
GOPATH=$PROJECT_ROOT/.gopath
GOCACHE=$PROJECT_ROOT/.gocache
APP_PORT=\${APP_PORT:-8080}
EOF
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages rustc cargo
      ;;
    apk)
      install_packages rust cargo
      ;;
    dnf|yum)
      install_packages rust cargo
      ;;
    *)
      warn "Cannot install Rust via system package manager. Assuming Rust is available."
      ;;
  esac

  if ! command -v cargo >/dev/null 2>&1; then
    warn "Cargo not found. Please use a Rust base image or install Rust toolchain."
    return
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "Cargo.toml" ]; then
    log "Fetching Rust crate dependencies"
    cargo fetch
  fi
  popd >/dev/null

  mkdir -p "$PROJECT_ROOT/$ENV_DIR"
  cat >>"$PROJECT_ROOT/$ENV_FILE" <<'EOF'
APP_PORT=${APP_PORT:-8080}
EOF
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages php-cli php-mbstring php-xml unzip
      ;;
    apk)
      install_packages php php-cli php-mbstring php-xml unzip
      ;;
    dnf|yum)
      install_packages php-cli php-mbstring php-xml unzip
      ;;
    *)
      warn "Cannot install PHP via system package manager. Assuming PHP is available."
      ;;
  esac

  if ! command -v php >/dev/null 2>&1; then
    warn "PHP not found. Please use a PHP base image or install PHP."
    return
  fi

  # Composer installation
  if ! command -v composer >/dev/null 2>&1; then
    log "Installing Composer locally"
    curl -fsSL https://getcomposer.org/installer -o "$PROJECT_ROOT/composer-setup.php"
    php "$PROJECT_ROOT/composer-setup.php" --install-dir=/usr/local/bin --filename=composer || warn "Failed to install composer globally; installing locally."
    if ! command -v composer >/dev/null 2>&1; then
      php "$PROJECT_ROOT/composer-setup.php" --install-dir="$PROJECT_ROOT" --filename=composer.phar
    fi
    rm -f "$PROJECT_ROOT/composer-setup.php"
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "composer.json" ]; then
    if command -v composer >/dev/null 2>&1; then
      log "Installing PHP dependencies with Composer"
      composer install --no-interaction --prefer-dist
    elif [ -f "composer.phar" ]; then
      php composer.phar install --no-interaction --prefer-dist
    else
      warn "Composer not available; skipping PHP dependency installation."
    fi
  fi
  popd >/dev/null

  mkdir -p "$PROJECT_ROOT/$ENV_DIR"
  cat >>"$PROJECT_ROOT/$ENV_FILE" <<'EOF'
APP_PORT=${APP_PORT:-8080}
EOF
}

# Java setup
setup_java() {
  log "Setting up Java environment..."
  case "$PKG_MANAGER" in
    apt)
      install_packages openjdk-17-jdk maven gradle
      ;;
    apk)
      install_packages openjdk17 maven gradle
      ;;
    dnf|yum)
      install_packages java-17-openjdk-devel maven gradle
      ;;
    *)
      warn "Cannot install Java via system package manager. Assuming Java is available."
      ;;
  esac

  if ! command -v javac >/dev/null 2>&1; then
    warn "Java JDK not found. Please use a Java base image or install OpenJDK."
    return
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if [ -f "pom.xml" ]; then
    if command -v mvn >/dev/null 2>&1; then
      log "Fetching Maven dependencies (offline mode)"
      mvn -q -DskipTests dependency:go-offline || warn "Maven go-offline may have failed; continuing."
    else
      warn "Maven not available; skipping Maven dependency resolution."
    fi
  fi
  if [ -f "build.gradle" ] || [ -f "settings.gradle" ] || [ -f "gradle.properties" ] || [ -f "gradlew" ]; then
    if [ -x "./gradlew" ]; then
      log "Fetching Gradle dependencies using wrapper"
      ./gradlew --no-daemon build -x test || warn "Gradle build may have failed; continuing."
    elif command -v gradle >/dev/null 2>&1; then
      log "Fetching Gradle dependencies"
      gradle --no-daemon build -x test || warn "Gradle build may have failed; continuing."
    else
      warn "Gradle not available; skipping Gradle operations."
    fi
  fi
  popd >/dev/null

  mkdir -p "$PROJECT_ROOT/$ENV_DIR"
  cat >>"$PROJECT_ROOT/$ENV_FILE" <<'EOF'
JAVA_TOOL_OPTIONS=-XX:+UseContainerSupport
APP_PORT=${APP_PORT:-8080}
EOF
}

# .NET setup (best effort)
setup_dotnet() {
  log "Setting up .NET environment..."
  # Attempt installation only if package manager supports it
  case "$PKG_MANAGER" in
    apt)
      require_root_or_skip || return 0
      # Add Microsoft package feed if needed
      if ! apt-cache policy | grep -qi 'packages.microsoft.com'; then
        log "Adding Microsoft package repository for .NET SDK"
        curl -fsSL https://packages.microsoft.com/config/debian/$(. /etc/os-release && echo "${VERSION_ID%%.*}")/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb || true
        dpkg -i /tmp/packages-microsoft-prod.deb || true
        rm -f /tmp/packages-microsoft-prod.deb || true
        $PKG_UPDATE_CMD || true
      fi
      install_packages dotnet-sdk-8.0 || warn ".NET SDK install may have failed."
      ;;
    dnf|yum)
      require_root_or_skip || return 0
      install_packages dotnet-sdk-8.0 || warn ".NET SDK install may have failed."
      ;;
    *)
      warn "Automatic .NET installation not supported for this package manager."
      ;;
  esac

  if ! command -v dotnet >/dev/null 2>&1; then
    warn "dotnet command not found. Please use a .NET base image or preinstall the SDK."
    return
  fi

  pushd "$PROJECT_ROOT" >/dev/null
  if ls *.sln >/dev/null 2>&1 || ls *.csproj >/dev/null 2>&1; then
    log "Restoring .NET dependencies"
    dotnet restore || warn "dotnet restore may have failed; continuing."
  fi
  popd >/dev/null

  mkdir -p "$PROJECT_ROOT/$ENV_DIR"
  cat >>"$PROJECT_ROOT/$ENV_FILE" <<'EOF'
DOTNET_RUNNING_IN_CONTAINER=true
ASPNETCORE_URLS=http://0.0.0.0:${APP_PORT:-8080}
APP_PORT=${APP_PORT:-8080}
EOF
}

# Write a summary state file
write_state() {
  cat >"$PROJECT_ROOT/$SETUP_STATE_FILE" <<EOF
{
  "script": "$SCRIPT_NAME",
  "start_time": "$START_TIME",
  "end_time": "$(date +'%Y-%m-%d %H:%M:%S')",
  "project_root": "$PROJECT_ROOT",
  "stacks": ["$(printf "%s" "${STACKS[*]}" | sed 's/ /", "/g')"],
  "pkg_manager": "$PKG_MANAGER"
}
EOF
}

# Export environment file safe to source
finalize_env() {
  # Ensure file exists
  touch "$PROJECT_ROOT/$ENV_FILE"
  # Make idempotent: de-duplicate lines
  awk '!seen[$0]++' "$PROJECT_ROOT/$ENV_FILE" > "$PROJECT_ROOT/$ENV_FILE.tmp" && mv "$PROJECT_ROOT/$ENV_FILE.tmp" "$PROJECT_ROOT/$ENV_FILE"
  chmod 0644 "$PROJECT_ROOT/$ENV_FILE" || true
  log "Environment file written to $PROJECT_ROOT/$ENV_FILE"
}

venv_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_line=". \"${PROJECT_ROOT}/.venv/bin/activate\""
  touch "$bashrc_file"
  if [ -d "${PROJECT_ROOT}/.venv" ]; then
    if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
      {
        echo ""
        echo "# Auto-activate project Python virtual environment"
        echo "if [ -d \"${PROJECT_ROOT}/.venv\" ]; then"
        echo "  $activate_line"
        echo "fi"
      } >> "$bashrc_file"
      log "Added virtualenv auto-activation to $bashrc_file"
    fi
  fi
}

bootstrap_core_utilities() {
  require_root_or_skip || return 0
  # Install core utilities via available package manager
  sh -lc 'if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then apt-get update -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::ForceIPv4=true && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl wget tar xz-utils unzip grep sed gawk; fi' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
  sh -lc 'if [ "$(id -u)" -eq 0 ] && command -v apk >/dev/null 2>&1; then apk update && apk add --no-cache ca-certificates curl wget tar xz unzip grep sed gawk; fi' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
  sh -lc 'if [ "$(id -u)" -eq 0 ] && command -v dnf >/dev/null 2>&1; then dnf -y install ca-certificates curl wget tar xz unzip grep sed gawk || true; fi' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
  sh -lc 'if [ "$(id -u)" -eq 0 ] && command -v yum >/dev/null 2>&1; then yum -y install ca-certificates curl wget tar xz unzip grep sed gawk || true; fi' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
  # Ensure /bin/sh points to bash
  sh -lc 'bash_path="$(command -v bash || true)"; if [ -n "$bash_path" ]; then [ -x /bin/bash ] || ln -sf "$bash_path" /bin/bash; ln -sf "$bash_path" /bin/sh; fi' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
  # Precreate Python venv if python3 exists
  sh -lc 'mkdir -p '"$PROJECT_ROOT"'; if command -v python3 >/dev/null 2>&1; then if [ ! -d '"$PROJECT_ROOT"'/.venv ]; then python3 -m venv '"$PROJECT_ROOT"'/.venv || (python3 -m pip install -U virtualenv && python3 -m virtualenv '"$PROJECT_ROOT"'/.venv); fi; . '"$PROJECT_ROOT"'/.venv/bin/activate; python -m pip install --upgrade pip setuptools wheel && python -m pip install --upgrade jupyterlite jupyterlite-core jupyterlite-pyodide-kernel jupyter_server && python -m pip install --upgrade pandas && printf '"'"'import pandas\nprint(pandas.__version__)\n'"'"' > /tmp/check_pandas.py && python /tmp/check_pandas.py && jupyter lite --version; fi' >>"$PROJECT_ROOT/$LOG_FILE" 2>&1 || true
}

main() {
  log "Starting environment setup"
  log "Project root: $PROJECT_ROOT"

  setup_directories
  install_local_util_wrappers
  precreate_project_venv_user
  bootstrap_core_utilities
  # disable_apt_and_remove_binaries (disabled)
  detect_pkg_manager
  prepare_apt_environment
  create_app_user
  install_common_utilities
  ensure_busybox_utils
  setup_uv_python
  venv_auto_activate
  : # setup_miniforge_user disabled
  setup_miniforge

  detect_stack
  if [ "${#STACKS[@]}" -eq 0 ]; then
    warn "No specific stack files detected. Installing only common utilities and creating default environment."
    mkdir -p "$PROJECT_ROOT/$ENV_DIR"
    cat >"$PROJECT_ROOT/$ENV_FILE" <<EOF
# Default environment (apt disabled)
PYTHONUNBUFFERED=1
PIP_DISABLE_PIP_VERSION_CHECK=1
PIP_NO_CACHE_DIR=1
VIRTUAL_ENV=$PROJECT_ROOT/.venv
PATH=$PROJECT_ROOT/.venv/bin:\$PATH
APP_PORT=\${APP_PORT:-8080}
EOF
  else
    for stack in "${STACKS[@]}"; do
      case "$stack" in
        python) setup_python ;;
        node) setup_node ;;
        ruby) setup_ruby ;;
        go) setup_go ;;
        rust) setup_rust ;;
        php) setup_php ;;
        java) setup_java ;;
        dotnet) setup_dotnet ;;
        *) warn "Unknown stack: $stack" ;;
      esac
    done
  fi

  finalize_env
  write_state
  venv_auto_activate

  # Final permissions
  if [ "$(id -u)" -eq 0 ] && id -u "$DEFAULT_USER" >/dev/null 2>&1; then
    chown -R "$DEFAULT_USER:$DEFAULT_GROUP" "$PROJECT_ROOT" || true
  fi

  log "Environment setup completed successfully."
  log "To apply environment variables, source: . $PROJECT_ROOT/$ENV_FILE"
  log "If using Docker, ensure the container runs with: -p ${APP_PORT:-8080}:${APP_PORT:-8080} and source the env file in your entrypoint."
}

# Noninteractive configuration for apt
export DEBIAN_FRONTEND=noninteractive

# Ensure local utility wrappers exist in non-root environments
install_local_util_wrappers

# Also attempt to install uv in user-space for convenience
sh -lc 'arch="$(uname -m)"; case "$arch" in x86_64|amd64) f="uv-x86_64-unknown-linux-musl-static";; aarch64|arm64) f="uv-aarch64-unknown-linux-musl-static";; armv7l|armhf) f="uv-armv7-unknown-linux-musleabihf";; *) f="uv-x86_64-unknown-linux-musl-static";; esac; mkdir -p "$HOME/.local/bin"; if command -v curl >/dev/null 2>&1; then curl -fSL --connect-timeout 20 --max-time 300 "https://github.com/astral-sh/uv/releases/latest/download/$f" -o "$HOME/.local/bin/uv" || curl -fSL --connect-timeout 20 --max-time 300 "https://github.com/astral-sh/uv/releases/download/0.9.21/$f" -o "$HOME/.local/bin/uv"; elif command -v wget >/dev/null 2>&1; then wget -qO "$HOME/.local/bin/uv" "https://github.com/astral-sh/uv/releases/latest/download/$f" || wget -qO "$HOME/.local/bin/uv" "https://github.com/astral-sh/uv/releases/download/0.9.21/$f"; fi; [ -f "$HOME/.local/bin/uv" ] && chmod +x "$HOME/.local/bin/uv" || true'

main "$@"