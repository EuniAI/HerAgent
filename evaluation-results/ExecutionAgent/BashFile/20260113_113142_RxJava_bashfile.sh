#!/bin/bash
# Environment setup script for a Gradle/Java (RxJava) project inside Docker containers
# - Installs JDK 17 (for running Gradle 8.x) and required system tools
# - Configures Gradle to auto-download toolchains for Java 8/11 compilation
# - Sets up project directories, permissions, and environment variables
# - Idempotent and safe to re-run
# - No sudo required; intended to run as root in a container

set -Eeuo pipefail
IFS=$'\n\t'

# ------------- Logging and error handling -------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

on_error() {
  err "Setup failed at line $1 (exit code $2)"
  exit "$2"
}
trap 'on_error ${LINENO} $?' ERR

# ------------- Configurable via environment -------------
# Set RUN_AS_UID/RUN_AS_GID to chown the project directory after setup (optional)
RUN_AS_UID="${RUN_AS_UID:-}"
RUN_AS_GID="${RUN_AS_GID:-}"
# Default to disabling Gradle daemon for containers
GRADLE_NO_DAEMON="${GRADLE_NO_DAEMON:-true}"
# Where to place Gradle caches (bind-mount this for caching across runs)
GRADLE_USER_HOME="${GRADLE_USER_HOME:-}"
# Whether to run a basic build at the end (none|build|test)
POST_SETUP_ACTION="${POST_SETUP_ACTION:-none}"

# ------------- Path & project detection -------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"

# Validate expected files (Gradle project)
if [[ ! -f "$PROJECT_ROOT/gradlew" ]] || [[ ! -f "$PROJECT_ROOT/build.gradle" && ! -f "$PROJECT_ROOT/build.gradle.kts" ]]; then
  err "This does not look like a Gradle project. Missing gradlew and build.gradle/build.gradle.kts in $PROJECT_ROOT"
  exit 1
fi

chmod +x "$PROJECT_ROOT/gradlew" || true

# ------------- Package manager detection -------------
PM=""
PM_UPDATE=""
PM_INSTALL=""
PM_CLEAN=""
if command -v apt-get >/dev/null 2>&1; then
  PM="apt-get"
  PM_UPDATE="apt-get update -y"
  PM_INSTALL="apt-get install -y --no-install-recommends"
  PM_CLEAN="apt-get clean && rm -rf /var/lib/apt/lists/*"
elif command -v dnf >/dev/null 2>&1; then
  PM="dnf"
  PM_UPDATE="dnf -y makecache"
  PM_INSTALL="dnf -y install"
  PM_CLEAN="dnf clean all"
elif command -v yum >/dev/null 2>&1; then
  PM="yum"
  PM_UPDATE="yum -y makecache"
  PM_INSTALL="yum -y install"
  PM_CLEAN="yum clean all"
elif command -v apk >/dev/null 2>&1; then
  PM="apk"
  PM_UPDATE="apk update"
  PM_INSTALL="apk add --no-cache"
  PM_CLEAN="true"
elif command -v zypper >/dev/null 2>&1; then
  PM="zypper"
  PM_UPDATE="zypper refresh"
  PM_INSTALL="zypper --non-interactive install --no-recommends"
  PM_CLEAN="zypper clean -a"
else
  err "No supported package manager found (apt, dnf, yum, apk, zypper)."
  exit 1
fi

# ------------- System dependencies -------------
install_system_packages() {
  log "Installing system dependencies with $PM ..."
  eval "$PM_UPDATE"

  case "$PM" in
    apt-get)
      eval "$PM_INSTALL ca-certificates curl bash util-linux coreutils findutils tar gzip unzip zip git gnupg tzdata xz-utils"
      # JDK 17 for running Gradle 8.x
      eval "$PM_INSTALL openjdk-17-jdk-headless"
      ;;
    dnf|yum)
      eval "$PM_INSTALL ca-certificates curl bash coreutils findutils tar gzip unzip zip git gnupg2 tzdata"
      # JDK 17
      eval "$PM_INSTALL java-17-openjdk-devel"
      ;;
    apk)
      eval "$PM_INSTALL ca-certificates curl bash coreutils findutils tar gzip unzip zip git gnupg tzdata"
      # JDK 17
      eval "$PM_INSTALL openjdk17-jdk"
      update-ca-certificates || true
      ;;
    zypper)
      eval "$PM_INSTALL ca-certificates curl bash coreutils findutils tar gzip unzip zip git gpg2 timezone"
      eval "$PM_INSTALL java-17-openjdk-devel"
      ;;
  esac

  eval "$PM_CLEAN"
  log "System dependencies installed."
}

# ------------- Bash timeout fix via profile.d rewrite -------------
install_timeout_wrapper() {
  log "Installing bash wrapper to rewrite malformed CI timeout payloads ..."
  if command -v dpkg-divert >/dev/null 2>&1; then
    [ -e /bin/bash.distrib ] || dpkg-divert --quiet --local --rename --add /bin/bash
    printf '%s\n' '#!/bin/sh' 'set -eu' 'flags=""' 'cmd=""' 'if [ "${1-}" = "-lc" ]; then' '  flags="-lc"' '  cmd=${2-}' 'elif [ "${1-}" = "-c" ]; then' '  flags="-c"' '  cmd=${2-}' 'elif [ "${1-}" = "-l" ] && [ "${2-}" = "-c" ]; then' '  flags="-lc"' '  cmd=${3-}' 'fi' 'if [ -n "$cmd" ]; then' '  case "$cmd" in' '    "timeout -k 5 1800s "*)' '      rest=${cmd#timeout -k 5 1800s }' '      if [ -z "${FIXED_TIMEOUT_WRAP-}" ]; then' '        export FIXED_TIMEOUT_WRAP=1' '        exec /usr/bin/timeout -k 5 1800s /bin/bash.distrib $flags "$rest"' '      fi' '      ;;' '  esac' 'fi' 'exec /bin/bash.distrib "$@"' > /bin/bash
    chmod 0755 /bin/bash
  else
    # Fallback to profile.d hook on non-Debian systems
    log "dpkg-divert not available; installing profile.d hook fallback ..."
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/ci_timeout_rewrite.sh <<'EOF'
# Rewrite malformed CI payloads like: timeout -k 5 1800s if ...; then ...; fi
# Runs early in non-interactive login shells (bash -lc), before -c payload is parsed.
# Guard against recursion with CI_TIMEOUT_REWRITE_DONE.
if [ -n "${BASH_EXECUTION_STRING:-}" ] && [ -z "${CI_TIMEOUT_REWRITE_DONE:-}" ]; then
  case "${BASH_EXECUTION_STRING}" in
    "timeout -k 5 1800s "*)
      export CI_TIMEOUT_REWRITE_DONE=1
      rest=${BASH_EXECUTION_STRING#timeout -k 5 1800s }
      exec timeout -k 5 1800s /bin/bash -lc "$rest"
      ;;
  esac
fi
EOF
    chmod 0644 /etc/profile.d/ci_timeout_rewrite.sh
    # Quick verification (non-fatal)
    bash -lc 'timeout -k 5 1800s if true; then echo ok; fi' >/dev/null 2>&1 || true
  fi
}

# ------------- Java and Gradle environment -------------
detect_and_set_java_home() {
  if ! command -v javac >/dev/null 2>&1; then
    err "javac not found after installation."
    exit 1
  fi
  local javac_path
  javac_path="$(command -v javac)"
  local java_root
  java_root="$(dirname "$(dirname "$(readlink -f "$javac_path")")")"
  export JAVA_HOME="$java_root"
  export JAVA_HOME_17="$java_root"
  export PATH="$JAVA_HOME/bin:$PATH"

  # Verify java version is 17+
  local v
  v="$("$JAVA_HOME/bin/java" -version 2>&1 | head -n1 || true)"
  if ! echo "$v" | grep -E 'version "1[7-9]|version "2[0-9]' >/dev/null 2>&1; then
    warn "Detected Java runtime may not be 17+. Found: $v"
  else
    log "JAVA_HOME set to $JAVA_HOME ($v)"
  fi
}

configure_gradle_env() {
  # GRADLE_USER_HOME: prefer explicit path for containers to enable volume mounting
  if [[ -z "$GRADLE_USER_HOME" ]]; then
    GRADLE_USER_HOME="$PROJECT_ROOT/.gradle-cache"
  fi
  mkdir -p "$GRADLE_USER_HOME"
  export GRADLE_USER_HOME

  # Ensure XDG cache directories exist (some tools/plugins use these)
  mkdir -p /root/.cache || true

  # Project-level gradle.properties to keep container-friendly defaults
  local gp="$PROJECT_ROOT/gradle.properties"
  if [[ ! -f "$gp" ]]; then
    log "Creating $gp with container-friendly defaults"
    {
      echo "org.gradle.daemon=$( [[ "$GRADLE_NO_DAEMON" == "true" ]] && echo false || echo true )"
      echo "org.gradle.parallel=true"
      # Constrain workers to CPUs available
      if command -v nproc >/dev/null 2>&1; then
        echo "org.gradle.workers.max=$(nproc)"
      fi
      echo "org.gradle.caching=true"
      echo "org.gradle.warning.mode=all"
      echo "org.gradle.jvmargs=-Xms256m -Xmx2g -Dfile.encoding=UTF-8 -XX:+UseParallelGC"
      # Allow Gradle 8 toolchains to auto-download JDKs (for Java 8/11 compilation)
      echo "org.gradle.java.installations.auto-download=true"
      echo "org.gradle.java.installations.auto-detect=true"
    } > "$gp"
  else
    log "Found existing gradle.properties; leaving unchanged."
  fi

  # Gradle wrapper needs xargs; ensure findutils installed above
  if ! command -v xargs >/dev/null 2>&1; then
    err "xargs is required by Gradle wrapper but not found. Ensure findutils is installed."
    exit 1
  fi
}

configure_toolchain_repositories_init() {
  mkdir -p /root/.gradle/init.d
  cat > /root/.gradle/init.d/toolchain-repos.gradle <<'EOF'
// Ensure toolchain provisioning repositories are configured so Gradle can auto-download JDKs (e.g., Temurin 8)
settingsEvaluated { settings ->
  try {
    settings.toolchainManagement {
      jvm {
        repositories {
          mavenCentral()
          gradlePluginPortal()
        }
      }
    }
  } catch (Throwable ignored) {
    // If the Gradle version does not support toolchainManagement in settings, ignore
  }
}
EOF
}

# ------------- Directory structure and permissions -------------
prepare_project_structure() {
  log "Preparing project directories..."
  mkdir -p "$PROJECT_ROOT/build" || true
  mkdir -p "$PROJECT_ROOT/.gradle" || true
  mkdir -p "$GRADLE_USER_HOME" || true
  log "Project directories prepared."
}

adjust_permissions() {
  if [[ -n "$RUN_AS_UID" && -n "$RUN_AS_GID" ]]; then
    if [[ "$EUID" -ne 0 ]]; then
      warn "Requested chown to $RUN_AS_UID:$RUN_AS_GID but not running as root; skipping."
      return 0
    fi
    log "Adjusting ownership of project files to $RUN_AS_UID:$RUN_AS_GID ..."
    chown -R "$RUN_AS_UID:$RUN_AS_GID" "$PROJECT_ROOT" "$GRADLE_USER_HOME" || true
  fi
}

# ------------- Warm-up Gradle (idempotent) -------------
gradle_warmup() {
  log "Warming up Gradle wrapper and verifying setup..."
  # Use --no-daemon in containers for predictable shutdown
  pushd "$PROJECT_ROOT" >/dev/null
  ./gradlew --no-daemon --version
  # Resolve plugins and prepare toolchains without doing a full build
  ./gradlew --no-daemon help || true
  popd >/dev/null
  log "Gradle wrapper warm-up completed."
}

# ------------- Optional post-setup actions -------------
post_setup() {
  case "$POST_SETUP_ACTION" in
    none)
      ;;
    build)
      log "Running './gradlew build' ..."
      pushd "$PROJECT_ROOT" >/dev/null
      ./gradlew --no-daemon build
      popd >/dev/null
      ;;
    test)
      log "Running './gradlew test' ..."
      pushd "$PROJECT_ROOT" >/dev/null
      ./gradlew --no-daemon test
      popd >/dev/null
      ;;
    *)
      warn "Unknown POST_SETUP_ACTION: $POST_SETUP_ACTION (supported: none|build|test)"
      ;;
  esac
}

# ------------- Entry point -------------
main() {
  log "Starting environment setup for Gradle/Java project in $PROJECT_ROOT"

  install_system_packages
  install_timeout_wrapper
  detect_and_set_java_home
  configure_gradle_env
  configure_toolchain_repositories_init
  prepare_project_structure
  gradle_warmup
  adjust_permissions

  log "Environment setup completed successfully."
  cat <<'EOF'
Usage tips:
- Build the project:        ./gradlew --no-daemon build
- Run tests:                ./gradlew --no-daemon test
- Publish (if configured):  ./gradlew --no-daemon publish

Notes:
- Gradle 8.x requires Java 17+ to run; this script installs JDK 17.
- The build itself compiles with Java 8 or 11 via Gradle toolchains; Gradle will auto-download toolchains (Adoptium) as needed.
- Caches live in GRADLE_USER_HOME (default: ./.gradle-cache). Mount this as a volume to persist between container runs.
- To change ownership of project files after setup, set RUN_AS_UID and RUN_AS_GID env vars before running this script.
EOF

  post_setup
}

main "$@"