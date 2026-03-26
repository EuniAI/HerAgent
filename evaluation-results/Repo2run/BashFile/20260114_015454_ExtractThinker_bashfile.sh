#!/usr/bin/env bash
# Environment setup script for ExtractThinker (Python 3.9+ with OCR and document tooling)
# Designed to run inside Docker containers (root or non-root)
# Idempotent, safe to re-run

set -Eeuo pipefail
IFS=$'\n\t'

#=============================
# Configurable defaults
#=============================
PROJECT_NAME="${PROJECT_NAME:-extractthinker}"
PROJECT_DIR="${PROJECT_DIR:-/app}"
DATA_DIR="${DATA_DIR:-/data}"
LOG_DIR="${LOG_DIR:-/var/log/$PROJECT_NAME}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"

# Language data for Tesseract (default English)
TESSERACT_LANGS="${TESSERACT_LANGS:-eng}"

# Environment flags
export DEBIAN_FRONTEND=noninteractive
export PYTHONUNBUFFERED=1
export PIP_NO_CACHE_DIR=1

#=============================
# Logging and error handling
#=============================
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }
die() { err "$*"; exit 1; }

cleanup() {
  # Reserved for any future cleanup
  :
}
trap cleanup EXIT
trap 'err "An error occurred on line $LINENO"; exit 1' ERR

#=============================
# Package manager detection
#=============================
PKG_MANAGER=""
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
  else
    PKG_MANAGER="unknown"
  fi
}

pm_update() {
  case "$PKG_MANAGER" in
    apt)
      apt-get update -y
      ;;
    apk)
      apk update >/dev/null 2>&1 || true
      ;;
    microdnf)
      microdnf -y update || true
      ;;
    *)
      warn "Unknown package manager. Skipping system package update."
      ;;
  esac
}

pm_install() {
  case "$PKG_MANAGER" in
    apt)
      apt-get install -y --no-install-recommends "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    microdnf)
      microdnf -y install "$@"
      ;;
    *)
      die "Cannot install packages: unknown package manager."
      ;;
  esac
}

pm_clean() {
  case "$PKG_MANAGER" in
    apt)
      apt-get clean
      rm -rf /var/lib/apt/lists/* || true
      ;;
    apk)
      rm -rf /var/cache/apk/* || true
      ;;
    microdnf)
      microdnf clean all || true
      ;;
    *)
      ;;
  esac
}

#=============================
# System packages installation
#=============================
install_system_packages() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root. Skipping system package installation."
    return 0
  fi

  detect_pkg_manager
  [ "$PKG_MANAGER" = "unknown" ] && die "No supported package manager found (apt, apk, microdnf)."

  log "Installing system packages using $PKG_MANAGER..."
  pm_update

  case "$PKG_MANAGER" in
    apt)
      # Core utilities, compilers and Python
      pm_install ca-certificates curl git bash build-essential make \
        python3 python3-venv python3-dev python3-pip \
        nodejs npm maven openjdk-17-jdk-headless gradle cargo \
        libjpeg-dev zlib1g-dev libpng-dev libtiff-dev \
        tesseract-ocr tesseract-ocr-eng \
        pkg-config libffi-dev libssl-dev

      # Optional: locale setup (not strictly necessary)
      ;;
    apk)
      # Alpine equivalents
      pm_install ca-certificates curl git bash \
        build-base musl-dev \
        python3 py3-pip python3-dev \
        jpeg-dev zlib-dev libpng-dev tiff-dev \
        tesseract-ocr tesseract-ocr-data \
        libffi-dev openssl-dev

      # Ensure python3 points to python if needed
      if ! command -v python3 >/dev/null 2>&1 && command -v python >/dev/null 2>&1; then
        ln -sf "$(command -v python)" /usr/bin/python3
      fi
      ;;
    microdnf)
      # RHEL-like minimal; might need enabling repos in Dockerfile
      pm_install ca-certificates curl git bash \
        gcc gcc-c++ make \
        python3 python3-pip python3-devel \
        tesseract \
        libjpeg-turbo-devel zlib-devel libpng-devel libtiff-devel \
        libffi-devel openssl-devel
      ;;
  esac

  pm_clean
  log "System packages installation completed."
}

#=============================
# Python and virtualenv setup
#=============================
ensure_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    if [ "$(id -u)" -ne 0 ]; then
      die "Python3 is not installed and cannot install without root."
    fi
    install_system_packages
  fi

  # Check version >= 3.9
  local pyver
  pyver="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || echo "0.0.0")"
  local major minor
  major="$(echo "$pyver" | cut -d. -f1)"
  minor="$(echo "$pyver" | cut -d. -f2)"
  if [ "$major" -lt 3 ] || [ "$minor" -lt 9 ]; then
    warn "Detected Python $pyver; Python 3.9+ is recommended."
  else
    log "Detected Python $pyver"
  fi
}

create_venv() {
  if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
  else
    log "Virtual environment already exists at $VENV_DIR"
  fi

  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
}

#=============================
# Project directories and user
#=============================
create_user_and_dirs() {
  mkdir -p "$PROJECT_DIR" "$DATA_DIR" "$LOG_DIR"

  if [ "$(id -u)" -eq 0 ]; then
    # Create group if missing
    if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
      groupadd -g "$APP_GID" "$APP_GROUP" || true
    fi
    # Create user if missing
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
      useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash "$APP_USER" || true
    fi

    chown -R "$APP_UID:$APP_GID" "$PROJECT_DIR" "$DATA_DIR" "$LOG_DIR" 2>/dev/null || true
  else
    warn "Not root: cannot create system user/group. Proceeding without user adjustments."
  fi
}

#=============================
# Python dependencies install
#=============================
install_python_dependencies() {
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"

  if [ -f "$PROJECT_DIR/requirements.txt" ]; then
    log "Installing Python dependencies from $PROJECT_DIR/requirements.txt..."
    python -m pip install --no-cache-dir -r "$PROJECT_DIR/requirements.txt"
  elif [ -f "requirements.txt" ]; then
    log "Installing Python dependencies from ./requirements.txt..."
    python -m pip install --no-cache-dir -r requirements.txt
  else
    warn "requirements.txt not found. Skipping Python dependency installation."
  fi

  # Ensure OCR wrappers are installed
  python - <<'PY'
import importlib, sys
for pkg in ["pytesseract", "Pillow", "pydantic"]:
    try:
        importlib.import_module(pkg)
    except Exception as e:
        print(f"[WARN] Python package check failed for {pkg}: {e}", file=sys.stderr)
PY
}

#=============================
# Tesseract configuration
#=============================
configure_tesseract() {
  # tesseract binary path
  local tessbin
  tessbin="$(command -v tesseract || true)"
  if [ -z "$tessbin" ]; then
    warn "tesseract binary not found. pytesseract will not function. If running non-root, install tesseract in the base image."
  else
    log "Found tesseract at $tessbin"
    export TESSERACT_PATH="$tessbin"
  fi

  # TESSDATA location (best-effort across distros)
  local tessdata=""
  for p in /usr/share/tesseract-ocr/4.00/tessdata /usr/share/tesseract-ocr/tessdata /usr/share/tessdata /usr/share/tesseract/tessdata; do
    if [ -d "$p" ]; then
      tessdata="$p"
      break
    fi
  done
  if [ -n "$tessdata" ]; then
    export TESSDATA_PREFIX="$tessdata"
    log "TESSDATA_PREFIX set to $TESSDATA_PREFIX"
  else
    warn "Could not determine TESSDATA_PREFIX. OCR may fail if language data not found."
  fi
}

#=============================
# Environment configuration
#=============================
persist_environment() {
  # Persist env so interactive shells inherit venv and defaults
  if [ "$(id -u)" -eq 0 ]; then
    local prof="/etc/profile.d/${PROJECT_NAME}.sh"
    cat > "$prof" <<EOF
# Auto-generated by setup script
export PYTHONUNBUFFERED=1
export PIP_NO_CACHE_DIR=1
export VIRTUAL_ENV="$VENV_DIR"
export PATH="\$VIRTUAL_ENV/bin:\$PATH"
# Tesseract
export TESSDATA_PREFIX="${TESSDATA_PREFIX:-/usr/share/tesseract-ocr/4.00/tessdata}"
export TESSERACT_PATH="${TESSERACT_PATH:-$(command -v tesseract || echo /usr/bin/tesseract)}"
# Project defaults
export PROJECT_DIR="$PROJECT_DIR"
export DATA_DIR="$DATA_DIR"
export LOG_DIR="$LOG_DIR"
EOF
    chmod 0644 "$prof"
    log "Persisted environment configuration to $prof"
  else
    warn "Not root: cannot persist environment in /etc/profile.d. Session-only exports will apply."
  fi
}

#=============================
# Entrypoint creation
#=============================
create_entrypoint() {
  local entry="/docker-entrypoint.sh"
  cat > "$entry" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

export PYTHONUNBUFFERED=1
export PIP_NO_CACHE_DIR=1

# Load persisted env if present
if [ -f "/etc/profile.d/extractthinker.sh" ]; then
  # shellcheck disable=SC1091
  source /etc/profile.d/extractthinker.sh
fi

# Load project .env if present
if [ -f "${PROJECT_DIR:-/app}/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${PROJECT_DIR:-/app}/.env"
  set +a
fi

# Activate venv
if [ -n "${VIRTUAL_ENV:-}" ] && [ -d "${VIRTUAL_ENV}/bin" ]; then
  # shellcheck disable=SC1090
  source "${VIRTUAL_ENV}/bin/activate"
elif [ -d "/opt/venv/bin" ]; then
  # shellcheck disable=SC1090
  source "/opt/venv/bin/activate"
fi

# Diagnostics
if command -v python >/dev/null 2>&1; then
  pyver=$(python -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')
  echo "[entrypoint] Python: $pyver"
fi
if command -v tesseract >/dev/null 2>&1; then
  echo "[entrypoint] Tesseract: $(tesseract --version | head -n1)"
fi

# If no command provided, drop into shell
if [ $# -eq 0 ]; then
  echo "[entrypoint] No command provided. Starting bash shell."
  exec bash
else
  exec "$@"
fi
EOS
  chmod +x "$entry"
  log "Created container entrypoint at $entry"
}

#=============================
# Example .env template
#=============================
create_env_example() {
  local env_file="$PROJECT_DIR/.env.example"
  if [ ! -f "$env_file" ]; then
    cat > "$env_file" <<EOF
# Example environment variables for ExtractThinker
# Copy to .env and set your credentials and options.

# LLM provider keys (optional)
# OPENAI_API_KEY=
# ANTHROPIC_API_KEY=
# COHERE_API_KEY=
# AZURE_OPENAI_API_KEY=
# AZURE_OPENAI_ENDPOINT=

# OCR configuration
# TESSERACT_PATH=$(command -v tesseract || echo /usr/bin/tesseract)
# TESSDATA_PREFIX=${TESSDATA_PREFIX:-/usr/share/tesseract-ocr/4.00/tessdata}

# Project directories
PROJECT_DIR=$PROJECT_DIR
DATA_DIR=$DATA_DIR
LOG_DIR=$LOG_DIR
EOF
    log "Created example env file at $env_file"
  fi
}

#=============================
# Virtual environment auto-activation
#=============================
setup_auto_activate() {
  local activate_line="source \"$VENV_DIR/bin/activate\""
  if [ -d "$VENV_DIR/bin" ]; then
    # Root bashrc
    local root_bashrc="/root/.bashrc"
    touch "$root_bashrc"
    if ! grep -qxF "$activate_line" "$root_bashrc" 2>/dev/null; then
      echo "" >> "$root_bashrc"
      echo "# Auto-activate Python virtual environment" >> "$root_bashrc"
      echo "$activate_line" >> "$root_bashrc"
    fi
    # App user bashrc if present
    if id -u "$APP_USER" >/dev/null 2>&1; then
      local user_home
      user_home="$(getent passwd "$APP_USER" | cut -d: -f6)"
      [ -z "$user_home" ] && user_home="/home/$APP_USER"
      local user_bashrc="$user_home/.bashrc"
      mkdir -p "$user_home"
      touch "$user_bashrc"
      if ! grep -qxF "$activate_line" "$user_bashrc" 2>/dev/null; then
        echo "" >> "$user_bashrc"
        echo "# Auto-activate Python virtual environment" >> "$user_bashrc"
        echo "$activate_line" >> "$user_bashrc"
      fi
      chown "$APP_USER:$APP_GROUP" "$user_bashrc" 2>/dev/null || true
    fi
  fi
}

#=============================
# Auto build helper script
#=============================
create_auto_build_script() {
  local script="/usr/local/bin/auto_build.sh"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f package.json ]; then
  npm ci --no-audit --fund=false
  npm run build --if-present
elif [ -f pom.xml ]; then
  mvn -q -DskipTests package
elif [ -f gradlew ]; then
  chmod +x gradlew
  ./gradlew build -x test
elif [ -f build.gradle ]; then
  gradle build -x test
elif [ -f Cargo.toml ]; then
  cargo build --quiet
elif [ -f pyproject.toml ]; then
  python3 -m pip install -U pip
  pip3 install .
elif [ -f requirements.txt ]; then
  python3 -m pip install -U pip
  pip3 install -r requirements.txt
elif [ -f Makefile ]; then
  make build
else
  echo "No recognized build system found" >&2
  exit 1
fi
EOF
  chmod +x "$script"
}

#=============================
# CI build script creation
#=============================
create_ci_build() {
  local target="./ci-build.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '' 'if [ -f package.json ]; then' '  if command -v npm >/dev/null 2>&1; then' '    npm ci --no-audit --fund=false' '    npm run -s build || npm run -s build:prod || true' '  fi' 'elif [ -f pom.xml ]; then' '  if command -v mvn >/dev/null 2>&1; then' '    mvn -q -DskipTests package' '  fi' 'elif [ -f gradlew ]; then' '  chmod +x gradlew' '  ./gradlew build -x test' 'elif [ -f build.gradle ]; then' '  if command -v gradle >/dev/null 2>&1; then' '    gradle build -x test' '  fi' 'elif [ -f Cargo.toml ]; then' '  if command -v cargo >/dev/null 2>&1; then' '    cargo build --quiet' '  fi' 'elif [ -f pyproject.toml ]; then' '  python -m pip install -U pip' '  pip install .' 'elif [ -f requirements.txt ]; then' '  python -m pip install -U pip' '  pip install -r requirements.txt' 'elif [ -f Makefile ]; then' '  make build' 'else' '  echo "No recognized build system found"' '  exit 1' 'fi' > "$target"
  chmod +x "$target"
}

#=============================
# Ensure /app/main.py entrypoint
#=============================
ensure_app_main() {
  bash -lc 'set -euxo pipefail; mkdir -p /app; if [ -f ./main.py ]; then ln -sf "$(pwd)/main.py" /app/main.py; elif [ -f ./app.py ]; then ln -sf "$(pwd)/app.py" /app/main.py; else cat > /app/main.py << "PY"; #!/usr/bin/env python3
import os, sys, runpy, pathlib, traceback

def find_packages_with_main(search_roots):
    found = []
    for root in search_roots:
        p = pathlib.Path(root)
        if not p.exists():
            continue
        try:
            for pkg in p.iterdir():
                if pkg.is_dir() and (pkg / "__main__.py").is_file():
                    found.append((pkg.name, pkg))
        except Exception:
            continue
    return found

def unique(seq):
    seen = set()
    out = []
    for x in seq:
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out

def main():
    m = os.environ.get("APP_MODULE")
    if m:
        runpy.run_module(m, run_name="__main__")
        return
    cwd = os.getcwd()
    roots = unique([
        cwd,
        os.path.dirname(cwd),
        os.path.join(cwd, "src"),
        "/workspace",
        "/workspace/src",
        "/project",
        "/project/src",
    ])
    pkgs = find_packages_with_main(roots)
    if len(pkgs) == 1:
        runpy.run_module(pkgs[0][0], run_name="__main__")
    else:
        print("No single package with __main__.py found; searched:", roots, "found:", [n for n,_ in pkgs], file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        sys.exit(1)
PY
fi; chmod +x /app/main.py'
}

#=============================
# Main
#=============================
main() {
  log "Starting environment setup for $PROJECT_NAME"

  create_user_and_dirs
  install_system_packages
  ensure_python
  create_venv
  install_python_dependencies
  configure_tesseract
  persist_environment
  create_entrypoint
  create_env_example
  create_auto_build_script
  create_ci_build
  # Execute CI build script if present to avoid inline quoting issues
  if [ -x "./ci-build.sh" ]; then
    bash ./ci-build.sh
  elif [ -x "$PROJECT_DIR/ci-build.sh" ]; then
    (cd "$PROJECT_DIR" && bash ./ci-build.sh)
  fi

  # Ensure expected /app/main.py exists for runners
  ensure_app_main

  # Permissions
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "$APP_UID:$APP_GID" "$PROJECT_DIR" "$DATA_DIR" "$LOG_DIR" "$VENV_DIR" 2>/dev/null || true
  fi

  setup_auto_activate
  log "Environment setup completed successfully."

  cat <<INFO

Next steps:
- Place your project files in: $PROJECT_DIR
- If you have requirements.txt, ensure it's located at $PROJECT_DIR/requirements.txt or ./requirements.txt before running this script.
- To use inside Docker, set the entrypoint to /docker-entrypoint.sh and pass your command:
    docker run --rm -it \\
      -v "\$PWD":$PROJECT_DIR \\
      -e OPENAI_API_KEY=\$OPENAI_API_KEY \\
      --entrypoint /docker-entrypoint.sh <image> \\
      python -c "import pytesseract, sys; print('Tesseract:', pytesseract.get_tesseract_version())"

INFO
}

main "$@"