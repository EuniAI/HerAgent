#!/bin/sh
# Environment Setup Script for Containerized Projects
# This script auto-detects the project type (Python, Node.js, Ruby, PHP, Go, Rust, Java)
# and installs required runtimes, system packages, and dependencies.
# Designed to run as root inside Docker containers. Idempotent and safe to re-run.

# Bootstrap: repair broken bash and Python via /bin/sh, then re-exec under bash
if [ -z "${BOOTSTRAP_DONE:-}" ]; then
  export BOOTSTRAP_DONE=1
  
  /bin/sh -lc 'set -eux; mkdir -p /usr/local/bin; for p in $(command -v -a bash 2>/dev/null || true); do if [ -e "$p" ] && head -n1 "$p" 2>/dev/null | grep -Eqi "python(3)?|env python(3)?"; then echo "Quarantining python-wrapped bash: $p"; mv -f "$p" "${p}.pywrap" || true; fi; done; if [ -e /bin/bash ] && head -n1 /bin/bash 2>/dev/null | grep -Eqi "python(3)?|env python(3)?"; then mv -f /bin/bash /bin/bash.pywrap || true; fi; ln -sf /bin/sh /usr/local/bin/bash; ln -sf /usr/local/bin/bash /usr/bin/bash || true; ln -sf /usr/local/bin/bash /bin/bash || true; chmod 0755 /usr/local/bin/bash /usr/bin/bash /bin/bash 2>/dev/null || true; hash -r || true'
  /bin/sh -lc 'set -eux; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y --no-install-recommends bash bash-static python3 python3-venv python3-pip ca-certificates; [ -x /bin/bash-static ] && ln -sf /bin/bash-static /bin/bash || true; apt-get clean; rm -rf /var/lib/apt/lists/*; elif command -v apk >/dev/null 2>&1; then apk update || true; apk add --no-cache bash python3 py3-pip py3-virtualenv ca-certificates; elif command -v dnf >/dev/null 2>&1; then dnf makecache -y || true; dnf install -y bash python3 python3-pip; dnf clean all; elif command -v yum >/dev/null 2>&1; then yum makecache -y || true; yum install -y bash python3 python3-pip; yum clean all; elif command -v microdnf >/dev/null 2>&1; then microdnf update -y || true; microdnf install -y bash python3 python3-pip; microdnf clean all; else echo "No supported package manager found" >&2; exit 1; fi'
  /bin/sh -lc 'set -eux; if command -v dpkg-divert >/dev/null 2>&1; then dpkg-divert --quiet --rename --remove /bin/bash || true; fi; if [ -e /bin/bash.real ]; then rm -f /bin/bash && mv -f /bin/bash.real /bin/bash; fi; ln -sf /bin/bash /usr/bin/bash || true; if head -n1 /bin/bash 2>/dev/null | grep -Eqi "python(3)?|env python(3)?"; then echo "Warning: /bin/bash still a python wrapper; keeping /usr/local/bin/bash shim" >&2; else rm -f /usr/local/bin/bash || true; fi; chmod 0755 /bin/bash /usr/bin/bash 2>/dev/null || true; hash -r || true; /bin/bash --version; python3 --version'
  /bin/sh -lc 'set -eux; command -v pip >/dev/null 2>&1 || { command -v pip3 >/dev/null 2>&1 && ln -sf "$(command -v pip3)" /usr/local/bin/pip || true; }'
  /bin/sh -lc 'set -eux; /usr/bin/env bash -lc "echo HEALTHCHECK: bash and python3 are operational"'
  exec /usr/bin/env bash "$0" "$@"
fi

set -Eeuo pipefail
IFS=$'\n\t'

# Colors
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')" # No Color

# Logging helpers
log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

trap 'error "An error occurred at line $LINENO. Aborting."; exit 1' ERR

# Defaults and configuration
APP_DIR="${APP_DIR:-$(pwd)}"
RUNTIME_USER="${RUNTIME_USER:-}"       # optional: set to create and chown to non-root user (e.g., "app")
RUNTIME_UID="${RUNTIME_UID:-1000}"
RUNTIME_GID="${RUNTIME_GID:-1000}"
APP_ENV="${APP_ENV:-production}"
DEFAULT_PORT="${PORT:-}"               # can be set via env; auto-detected later if empty
ENV_FILE="${ENV_FILE:-.env}"
PROFILE_ENV_FILE="/etc/profile.d/project_env.sh"

# Ensure running in correct directory
cd "$APP_DIR" 2>/dev/null || die "Cannot change to APP_DIR: $APP_DIR"

# Package manager detection
PKG_MANAGER=""
APT_UPDATED=0

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v microdnf >/dev/null 2>&1; then
    PKG_MANAGER="microdnf"
  else
    die "No supported package manager found (apt, apk, dnf, yum, microdnf)."
  fi
  log "Detected package manager: $PKG_MANAGER"
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt)
      if [ "$APT_UPDATED" -eq 0 ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        APT_UPDATED=1
      fi
      ;;
    apk) apk update || true ;;
    dnf) dnf makecache -y || true ;;
    yum) yum makecache -y || true ;;
    microdnf) microdnf update -y || true ;;
  esac
}

pkg_install() {
  # args: package names mapped per PM later
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends "$@" && apt-get clean && rm -rf /var/lib/apt/lists/* ;;
    apk)
      apk add --no-cache "$@" ;;
    dnf)
      dnf install -y "$@" && dnf clean all ;;
    yum)
      yum install -y "$@" && yum clean all ;;
    microdnf)
      microdnf install -y "$@" && microdnf clean all ;;
  esac
}

ensure_base_tools() {
  log "Installing base system tools..."
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ca-certificates curl git openssh-client tzdata gnupg dirmngr \
        bash coreutils findutils grep sed tar gzip bzip2 xz-utils unzip zip \
        openssl pkg-config make build-essential
      ;;
    apk)
      pkg_install ca-certificates curl git openssh tzdata \
        bash coreutils findutils grep sed tar gzip bzip2 xz unzip zip \
        openssl pkgconf build-base
      ;;
    dnf|yum|microdnf)
      pkg_install ca-certificates curl git openssh-clients tzdata \
        bash coreutils findutils grep sed tar gzip bzip2 xz unzip zip \
        openssl pkgconfig make gcc gcc-c++ which
      ;;
  esac
}

ensure_system_python() {
  if [ "$PKG_MANAGER" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y python3 python3-pip python3-venv python-is-python3
    if ! command -v pip >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
      ln -sf "$(command -v pip3)" /usr/local/bin/pip
    fi
  fi
}

repair_shell_and_python() {
  /bin/sh -lc 'set -eux; mkdir -p /usr/local/bin; for p in $(command -v -a bash 2>/dev/null || true); do if [ -e "$p" ] && head -n1 "$p" 2>/dev/null | grep -Eqi "python(3)?|env python(3)?"; then echo "Quarantining python-wrapped bash: $p"; mv -f "$p" "${p}.pywrap" || true; fi; done; if [ -e /bin/bash ] && head -n1 /bin/bash 2>/dev/null | grep -Eqi "python(3)?|env python(3)?"; then mv -f /bin/bash /bin/bash.pywrap || true; fi; ln -sf /bin/sh /usr/local/bin/bash; ln -sf /usr/local/bin/bash /usr/bin/bash || true; ln -sf /usr/local/bin/bash /bin/bash || true; chmod 0755 /usr/local/bin/bash /usr/bin/bash /bin/bash 2>/dev/null || true; hash -r || true'
  /bin/sh -lc 'set -eux; if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y --no-install-recommends bash bash-static python3 python3-venv python3-pip ca-certificates; [ -x /bin/bash-static ] && ln -sf /bin/bash-static /bin/bash || true; apt-get clean; rm -rf /var/lib/apt/lists/*; elif command -v apk >/dev/null 2>&1; then apk update || true; apk add --no-cache bash python3 py3-pip py3-virtualenv ca-certificates; elif command -v dnf >/dev/null 2>&1; then dnf makecache -y || true; dnf install -y bash python3 python3-pip; dnf clean all; elif command -v yum >/dev/null 2>&1; then yum makecache -y || true; yum install -y bash python3 python3-pip; yum clean all; elif command -v microdnf >/dev/null 2>&1; then microdnf update -y || true; microdnf install -y bash python3 python3-pip; microdnf clean all; else echo "No supported package manager found" >&2; exit 1; fi'
  /bin/sh -lc 'set -eux; if command -v dpkg-divert >/dev/null 2>&1; then dpkg-divert --quiet --rename --remove /bin/bash || true; fi; if [ -e /bin/bash.real ]; then rm -f /bin/bash && mv -f /bin/bash.real /bin/bash; fi; ln -sf /bin/bash /usr/bin/bash || true; if head -n1 /bin/bash 2>/dev/null | grep -Eqi "python(3)?|env python(3)?"; then echo "Warning: /bin/bash still a python wrapper; keeping /usr/local/bin/bash shim" >&2; else rm -f /usr/local/bin/bash || true; fi; chmod 0755 /bin/bash /usr/bin/bash 2>/dev/null || true; hash -r || true; /bin/bash --version; python3 --version'
  /bin/sh -lc 'set -eux; command -v pip >/dev/null 2>&1 || { command -v pip3 >/dev/null 2>&1 && ln -sf "$(command -v pip3)" /usr/local/bin/pip || true; }'
  /bin/sh -lc 'set -eux; /usr/bin/env bash -lc "echo HEALTHCHECK: bash and python3 are operational"'
}

setup_timeout_shim() {
  # Install a bash wrapper to handle 'timeout' with compound shell statements parsed by bash -c
  if [ "$PKG_MANAGER" = "apt" ]; then
    pkg_update
    command -v python3 >/dev/null 2>&1 || pkg_install python3 || true
    if [ ! -e /bin/bash.real ]; then
      dpkg-divert --add --rename --divert /bin/bash.real /bin/bash
    fi
    cat > /bin/bash <<'PY'
#!/usr/bin/env python3
import os, sys, shlex, shutil
real_bash = "/bin/bash.real" if os.path.exists("/bin/bash.real") else shutil.which("bash") or "/usr/bin/bash"
argv = sys.argv[1:]
# Detect presence of -c (including clustered like -lc) and rewrite when the command starts with timeout
c_index = None
for i, a in enumerate(argv):
    if a == "-c" or (a.startswith("-") and "c" in a[1:]):
        c_index = i
        break
if c_index is not None and len(argv) > c_index + 1:
    s = argv[c_index + 1]
    try:
        toks = shlex.split(s)
    except Exception:
        os.execv(real_bash, [real_bash] + sys.argv[1:])
    if toks and toks[0] == "timeout":
        # Collect timeout options until first non-option token (the duration)
        i = 1
        while i < len(toks) and toks[i].startswith('-'):
            # options that take an argument
            if toks[i] in ("-k", "-s", "--kill-after", "--signal") and i + 1 < len(toks):
                i += 2
            else:
                i += 1
        if i < len(toks):
            duration = toks[i]
            inner_cmd = ' '.join(shlex.quote(t) for t in toks[i+1:])
            timeout_opts = toks[1:i]
            new_argv = ["/usr/bin/timeout"] + timeout_opts + [duration, "bash", "-lc", inner_cmd]
            os.execv(new_argv[0], new_argv)
# Fallback to the real bash for all other cases
os.execv(real_bash, [real_bash] + sys.argv[1:])
PY
    chmod +x /bin/bash
  fi
}

# Create runtime user (optional)
ensure_runtime_user() {
  if [ -n "$RUNTIME_USER" ]; then
    log "Ensuring runtime user '$RUNTIME_USER' exists..."
    if ! id -u "$RUNTIME_USER" >/dev/null 2>&1; then
      case "$PKG_MANAGER" in
        apk)
          addgroup -g "$RUNTIME_GID" "$RUNTIME_USER" 2>/dev/null || true
          adduser -D -H -u "$RUNTIME_UID" -G "$RUNTIME_USER" "$RUNTIME_USER"
          ;;
        *)
          groupadd -g "$RUNTIME_GID" -f "$RUNTIME_USER" 2>/dev/null || true
          useradd -u "$RUNTIME_UID" -g "$RUNTIME_GID" -M -s /usr/sbin/nologin "$RUNTIME_USER" 2>/dev/null || true
          ;;
      esac
    fi
  fi
}

# Create project directories
ensure_project_structure() {
  log "Ensuring project directory structure..."
  mkdir -p "$APP_DIR"/{bin,logs,tmp,data}
  # Node typical directories
  [ -d "$APP_DIR"/node_modules ] || true
  # Python venv dir placeholder
  [ -d "$APP_DIR"/.venv ] || true

  if [ -n "$RUNTIME_USER" ]; then
    chown -R "$RUNTIME_UID:$RUNTIME_GID" "$APP_DIR" || true
  fi
}

# .env handling
ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    log "Creating default $ENV_FILE..."
    {
      echo "APP_ENV=${APP_ENV}"
      echo "PORT=${DEFAULT_PORT:-}"
    } > "$ENV_FILE"
  fi
}

# Export env to profile for login shells inside container
write_profile_env() {
  log "Configuring profile environment at $PROFILE_ENV_FILE"
  {
    echo "#!/usr/bin/env bash"
    echo "export APP_DIR=\"$APP_DIR\""
    echo "export APP_ENV=\"${APP_ENV}\""
    if [ -n "${DEFAULT_PORT:-}" ]; then
      echo "export PORT=\"${DEFAULT_PORT}\""
    fi
    # Prepend local bin
    echo 'export PATH="$APP_DIR/bin:$PATH"'
    # Auto-activate Python venv if present and running interactive shell
    echo '[ -n "$PS1" ] && [ -f "$APP_DIR/.venv/bin/activate" ] && . "$APP_DIR/.venv/bin/activate" || true'
  } > "$PROFILE_ENV_FILE"
  chmod 0644 "$PROFILE_ENV_FILE"
}

setup_auto_activate() {
  local bashrc_file="${HOME:-/root}/.bashrc"
  local activate_line='[ -f "$APP_DIR/.venv/bin/activate" ] && . "$APP_DIR/.venv/bin/activate"'
  if ! grep -qF "$activate_line" "$bashrc_file" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate Python virtual environment"
      echo 'if [ -n "$PS1" ]; then'
      echo '  [ -f "$APP_DIR/.venv/bin/activate" ] && . "$APP_DIR/.venv/bin/activate"'
      echo "fi"
    } >> "$bashrc_file"
  fi
}

# Project type detection
IS_PYTHON=0
IS_NODE=0
IS_RUBY=0
IS_PHP=0
IS_GO=0
IS_RUST=0
IS_JAVA_MAVEN=0
IS_JAVA_GRADLE=0

detect_project_type() {
  log "Detecting project type..."
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ] || ls requirements/*.txt >/dev/null 2>&1; then
    IS_PYTHON=1
  fi
  if [ -f "package.json" ]; then
    IS_NODE=1
  fi
  if [ -f "Gemfile" ]; then
    IS_RUBY=1
  fi
  if [ -f "composer.json" ]; then
    IS_PHP=1
  fi
  if [ -f "go.mod" ]; then
    IS_GO=1
  fi
  if [ -f "Cargo.toml" ]; then
    IS_RUST=1
  fi
  if [ -f "pom.xml" ] || [ -f ".mvn/wrapper/maven-wrapper.jar" ]; then
    IS_JAVA_MAVEN=1
  fi
  if ls build.gradle* >/dev/null 2>&1 || [ -f "gradlew" ]; then
    IS_JAVA_GRADLE=1
  fi

  log "Detected: Python=$IS_PYTHON Node=$IS_NODE Ruby=$IS_RUBY PHP=$IS_PHP Go=$IS_GO Rust=$IS_RUST Maven=$IS_JAVA_MAVEN Gradle=$IS_JAVA_GRADLE"
}

# Python setup
setup_python() {
  log "Setting up Python environment..."
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install python3 python3-pip python3-venv python3-dev \
        build-essential pkg-config libffi-dev libssl-dev zlib1g-dev \
        libjpeg-dev libpq-dev default-libmysqlclient-dev
      ;;
    apk)
      pkg_install python3 py3-pip py3-virtualenv python3-dev \
        build-base pkgconf libffi-dev openssl-dev zlib-dev jpeg-dev postgresql-dev mariadb-connector-c-dev
      ;;
    dnf|yum|microdnf)
      pkg_install python3 python3-pip python3-devel \
        gcc gcc-c++ make pkgconfig libffi-devel openssl-devel zlib-devel \
        libjpeg-turbo-devel postgresql-devel mariadb-connector-c-devel
      ;;
  esac

  if [ ! -d ".venv" ]; then
    python3 -m venv .venv
  fi
  # shellcheck disable=SC1091
  . ".venv/bin/activate"
  python3 -m pip install --upgrade pip setuptools wheel

  if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
  elif ls requirements/*.txt >/dev/null 2>&1; then
    for f in requirements/*.txt; do pip install -r "$f"; done
  elif [ -f "pyproject.toml" ]; then
    # Try installing project in editable mode
    pip install -e . || pip install .
  elif [ -f "Pipfile" ]; then
    pip install pipenv && pipenv install --system --deploy || true
  fi
}

# Node.js setup
setup_node() {
  log "Setting up Node.js environment..."
  pkg_update
  case "$PKG_MANAGER" in
    apt) pkg_install nodejs npm ;;
    apk) pkg_install nodejs npm ;;
    dnf|yum|microdnf) pkg_install nodejs npm ;;
  esac

  mkdir -p "$APP_DIR"/node_modules
  # Enable corepack for yarn/pnpm when available
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
  else
    if command -v npm >/dev/null 2>&1; then
      npm install -g corepack || true
      command -v corepack >/dev/null 2>&1 && corepack enable || true
    fi
  fi

  if [ -f "pnpm-lock.yaml" ]; then
    if command -v pnpm >/dev/null 2>&1; then :; else corepack enable pnpm 2>/dev/null || true; fi
    if command -v pnpm >/dev/null 2>&1; then
      pnpm install --frozen-lockfile || pnpm install
    else
      warn "pnpm not available; falling back to npm install"
      npm ci || npm install
    fi
  elif [ -f "yarn.lock" ]; then
    if command -v yarn >/dev/null 2>&1; then :; else corepack enable yarn 2>/dev/null || true; fi
    if command -v yarn >/dev/null 2>&1; then
      yarn install --frozen-lockfile || yarn install
    else
      warn "yarn not available; falling back to npm install"
      npm ci || npm install
    fi
  elif [ -f "package.json" ]; then
    if [ -f "package-lock.json" ]; then
      npm ci || npm install
    else
      npm install
    fi
  fi
}

# Ruby setup
setup_ruby() {
  log "Setting up Ruby environment..."
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install ruby-full build-essential zlib1g-dev libssl-dev libreadline-dev libsqlite3-dev
      ;;
    apk)
      pkg_install ruby ruby-dev build-base gmp-dev openssl-dev zlib-dev sqlite-dev
      ;;
    dnf|yum|microdnf)
      pkg_install ruby ruby-devel gcc make redhat-rpm-config zlib-devel openssl-devel readline-devel sqlite-devel
      ;;
  esac
  if ! gem list -i bundler >/dev/null 2>&1; then
    gem install bundler --no-document
  fi
  bundle config set --local path 'vendor/bundle'
  bundle install --jobs "$(getconf _NPROCESSORS_ONLN || echo 4)"
}

# PHP setup
setup_php() {
  log "Setting up PHP environment..."
  pkg_update
  case "$PKG_MANAGER" in
    apt)
      pkg_install php-cli php-zip php-mbstring php-xml php-curl php-gd php-intl php-sqlite3 php-mysql unzip
      if ! command -v composer >/dev/null 2>&1; then
        pkg_install composer || true
      fi
      ;;
    apk)
      # Alpine default uses versioned php packages; attempt php81, then fallback to meta packages
      if ! apk add --no-cache php81 php81-cli php81-phar php81-zip php81-mbstring php81-xml php81-curl php81-gd php81-intl php81-session php81-openssl php81-pdo php81-pdo_mysql php81-pdo_sqlite unzip 2>/dev/null; then
        pkg_install php php-cli php-phar php-zip php-mbstring php-xml php-curl php-gd php-intl php-session php-openssl php-pdo php-pdo_mysql php-pdo_sqlite unzip || true
      fi
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o composer-setup.php
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
      fi
      ;;
    dnf|yum|microdnf)
      pkg_install php-cli php-zip php-mbstring php-xml php-curl php-gd php-intl php-mysqlnd unzip
      if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer -o composer-setup.php
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
      fi
      ;;
  esac

  if [ -f "composer.json" ]; then
    composer install --no-interaction --prefer-dist --no-progress
  fi
}

# Go setup
setup_go() {
  log "Setting up Go environment..."
  pkg_update
  case "$PKG_MANAGER" in
    apt) pkg_install golang-go ;;
    apk) pkg_install go ;;
    dnf|yum|microdnf) pkg_install golang ;;
  esac

  export GOPATH="${GOPATH:-$APP_DIR/.gopath}"
  export GOBIN="${GOBIN:-$APP_DIR/bin}"
  mkdir -p "$GOPATH" "$GOBIN"

  if [ -f "go.mod" ]; then
    go env -w GOPATH="$GOPATH" || true
    go env -w GOBIN="$GOBIN" || true
    go mod download
    # Optional build (best-effort, skip if fails)
    if grep -q "module " go.mod 2>/dev/null; then
      go build -o "$APP_DIR/bin/app" ./... || true
    fi
  fi
}

# Rust setup
setup_rust() {
  log "Setting up Rust environment..."
  pkg_update
  case "$PKG_MANAGER" in
    apt) pkg_install cargo ;;
    apk) pkg_install cargo ;;
    dnf|yum|microdnf) pkg_install cargo ;;
  esac

  if [ -f "Cargo.toml" ]; then
    cargo fetch
    cargo build --release || cargo build || true
  fi
}

# Java setup
setup_java() {
  if [ "$IS_JAVA_MAVEN" -eq 1 ] || [ "$IS_JAVA_GRADLE" -eq 1 ]; then
    log "Setting up Java environment..."
    pkg_update
    case "$PKG_MANAGER" in
      apt) pkg_install openjdk-17-jdk ;;
      apk) pkg_install openjdk17-jdk ;;
      dnf|yum|microdnf) pkg_install java-17-openjdk-devel ;;
    esac

    if [ "$IS_JAVA_MAVEN" -eq 1 ]; then
      if [ -x "./mvnw" ]; then
        ./mvnw -B -DskipTests package || ./mvnw -B -DskipTests verify || true
      else
        case "$PKG_MANAGER" in
          apt) pkg_install maven ;;
          apk) pkg_install maven ;;
          dnf|yum|microdnf) pkg_install maven ;;
        esac
        mvn -B -DskipTests package || mvn -B -DskipTests verify || true
      fi
    fi

    if [ "$IS_JAVA_GRADLE" -eq 1 ]; then
      if [ -x "./gradlew" ]; then
        ./gradlew --no-daemon build -x test || ./gradlew --no-daemon assemble || true
      else
        case "$PKG_MANAGER" in
          apt) pkg_install gradle ;;
          apk) pkg_install gradle ;;
          dnf|yum|microdnf) pkg_install gradle ;;
        esac
        gradle --no-daemon build -x test || gradle --no-daemon assemble || true
      fi
    fi
  fi
}

# Port auto-detection and defaults
detect_default_port() {
  if [ -n "${DEFAULT_PORT:-}" ]; then
    echo "$DEFAULT_PORT"
    return 0
  fi

  # Common defaults by stack
  if [ "$IS_NODE" -eq 1 ]; then
    DEFAULT_PORT=3000
    if [ -f package.json ]; then
      # naive detection of typical ports in scripts/start
      if grep -Eqi "port.?[:=].?([0-9]{2,5})" package.json; then
        CANDIDATE="$(grep -Eoi 'port[^0-9]{0,10}([0-9]{2,5})' package.json | grep -Eo '[0-9]{2,5}' | head -n1 || true)"
        [ -n "$CANDIDATE" ] && DEFAULT_PORT="$CANDIDATE"
      fi
    fi
  elif [ "$IS_PYTHON" -eq 1 ]; then
    DEFAULT_PORT=8000
    # Flask default 5000 if Flask app likely present
    if grep -Rqi "flask" requirements.txt 2>/dev/null || grep -Rqi "flask" pyproject.toml 2>/dev/null; then
      DEFAULT_PORT=5000
    fi
  elif [ "$IS_PHP" -eq 1 ]; then
    DEFAULT_PORT=8000
  elif [ "$IS_RUBY" -eq 1 ]; then
    DEFAULT_PORT=3000
  elif [ "$IS_JAVA_MAVEN" -eq 1 ] || [ "$IS_JAVA_GRADLE" -eq 1 ]; then
    DEFAULT_PORT=8080
  elif [ "$IS_GO" -eq 1 ] || [ "$IS_RUST" -eq 1 ]; then
    DEFAULT_PORT=8080
  else
    DEFAULT_PORT=8080
  fi
  echo "$DEFAULT_PORT"
}

# Summary
print_summary() {
  echo
  log "Environment setup completed."
  echo "Summary:"
  echo "  Project directory: $APP_DIR"
  echo "  Detected stacks: Python=$IS_PYTHON Node=$IS_NODE Ruby=$IS_RUBY PHP=$IS_PHP Go=$IS_GO Rust=$IS_RUST Maven=$IS_JAVA_MAVEN Gradle=$IS_JAVA_GRADLE"
  echo "  Default PORT: ${DEFAULT_PORT}"
  echo "  Environment file: $ENV_FILE"
  echo
  echo "Next steps (examples):"
  if [ "$IS_PYTHON" -eq 1 ]; then
    echo "  Python: source .venv/bin/activate && python -m your_app_entrypoint"
  fi
  if [ "$IS_NODE" -eq 1 ]; then
    echo "  Node.js: npm start  (or: yarn start / pnpm start)"
  fi
  if [ "$IS_RUBY" -eq 1 ]; then
    echo "  Ruby: bundle exec rails server -b 0.0.0.0 -p ${DEFAULT_PORT}"
  fi
  if [ "$IS_PHP" -eq 1 ]; then
    echo "  PHP: php -S 0.0.0.0:${DEFAULT_PORT} -t public"
  fi
  if [ "$IS_GO" -eq 1 ]; then
    echo "  Go: ./bin/app (if built) or go run ./..."
  fi
  if [ "$IS_RUST" -eq 1 ]; then
    echo "  Rust: ./target/release/<binary> (if built) or cargo run --release"
  fi
  if [ "$IS_JAVA_MAVEN" -eq 1 ] || [ "$IS_JAVA_GRADLE" -eq 1 ]; then
    echo "  Java: java -jar target/*.jar (Maven) or build/libs/*.jar (Gradle)"
  fi
  echo
  echo "Environment variables exported in: $PROFILE_ENV_FILE"
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "It is recommended to run this script as root inside a Docker container for package installation."
  fi

  repair_shell_and_python
  detect_pkg_manager
  ensure_base_tools
  ensure_system_python
  setup_timeout_shim
  ensure_runtime_user
  ensure_project_structure
  ensure_env_file

  detect_project_type

  # Set default port
  DEFAULT_PORT="$(detect_default_port || true)"
  write_profile_env
  setup_auto_activate

  # Setup per stack
  if [ "$IS_PYTHON" -eq 1 ]; then setup_python; fi
  if [ "$IS_NODE" -eq 1 ]; then setup_node; fi
  if [ "$IS_RUBY" -eq 1 ]; then setup_ruby; fi
  if [ "$IS_PHP" -eq 1 ]; then setup_php; fi
  if [ "$IS_GO" -eq 1 ]; then setup_go; fi
  if [ "$IS_RUST" -eq 1 ]; then setup_rust; fi
  if [ "$IS_JAVA_MAVEN" -eq 1 ] || [ "$IS_JAVA_GRADLE" -eq 1 ]; then setup_java; fi

  # Permissions
  if [ -n "$RUNTIME_USER" ]; then
    chown -R "$RUNTIME_UID:$RUNTIME_GID" "$APP_DIR" || true
  fi

  print_summary
}

main "$@"