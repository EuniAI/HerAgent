#!/usr/bin/env bash
# FreeRTOS-Kernel environment setup script for Docker containers
# This script installs system dependencies, configures a minimal FreeRTOS config,
# and builds the freertos_kernel static library using CMake.
#
# It is safe to run multiple times (idempotent) and designed for root execution
# in minimal Docker images (no sudo).
#
# Usage:
#   ./setup.sh [--clean] [--reconfigure] [--generator Ninja|Unix] [--port <FREERTOS_PORT>] [--heap <1..5|path>] [--build-type Debug|Release]
#
# Examples:
#   ./setup.sh
#   ./setup.sh --clean --build-type Debug
#   ./setup.sh --port GCC_POSIX --heap 4 --generator Ninja
#
# Environment variables (override defaults):
#   FREERTOS_PORT            Default auto-detected (GCC_POSIX on Linux)
#   FREERTOS_HEAP            Default 4
#   BUILD_TYPE               Default Release
#   GENERATOR                Default Ninja if available, else Unix Makefiles
#   BUILD_DIR                Default build
#   CONFIG_DIR               Default config/include containing FreeRTOSConfig.h
#   CI                       If set, reduces package manager output noise

set -Eeuo pipefail

#--------------------------
# Logging and error handling
#--------------------------
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

log()    { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()   { echo -e "${YELLOW}[WARNING] $*${NC}" >&2; }
error()  { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()    { error "$*"; exit 1; }

trap 'error "Script failed at line $LINENO. Command: $BASH_COMMAND"' ERR

#--------------------------
# Defaults and arguments
#--------------------------
BUILD_DIR="${BUILD_DIR:-build}"
CONFIG_DIR="${CONFIG_DIR:-config/include}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
FREERTOS_HEAP="${FREERTOS_HEAP:-4}"
GENERATOR="${GENERATOR:-}"
REQUEST_CLEAN=0
REQUEST_RECONFIGURE=0
ARG_PORT="${FREERTOS_PORT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) REQUEST_CLEAN=1; shift ;;
    --reconfigure) REQUEST_RECONFIGURE=1; shift ;;
    --generator) GENERATOR="$2"; shift 2 ;;
    --port) ARG_PORT="$2"; shift 2 ;;
    --heap) FREERTOS_HEAP="$2"; shift 2 ;;
    --build-type) BUILD_TYPE="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,80p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      warn "Unknown argument: $1"
      shift
      ;;
  esac
done

PROJECT_ROOT="$(pwd)"
STAMP_DIR="${PROJECT_ROOT}/.setup_stamps"
mkdir -p "$STAMP_DIR"

#--------------------------
# Helpers
#--------------------------
is_command() { command -v "$1" >/dev/null 2>&1; }

ensure_root_or_warn() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "Running as non-root. System package installation will be skipped. Ensure required tools are pre-installed."
    return 1
  fi
  return 0
}

detect_pm() {
  if is_command apt-get; then echo "apt"; return 0; fi
  if is_command dnf; then echo "dnf"; return 0; fi
  if is_command yum; then echo "yum"; return 0; fi
  if is_command apk; then echo "apk"; return 0; fi
  if is_command zypper; then echo "zypper"; return 0; fi
  echo "unknown"
}

pm_update_and_install() {
  local pm="$1"; shift
  local pkgs=("$@")
  local quiet_flags=()
  [[ -n "${CI:-}" ]] && quiet_flags+=("-qq")

  case "$pm" in
    apt)
      # Avoid repeated apt-get update if cache exists
      if [[ ! -d /var/lib/apt/lists ]] || [[ -z "$(ls -A /var/lib/apt/lists 2>/dev/null || true)" ]]; then
        log "Running apt-get update..."
        apt-get update -y "${quiet_flags[@]}"
      else
        log "apt lists present; refreshing..."
        apt-get update -y "${quiet_flags[@]}"
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" "${quiet_flags[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    apk)
      # Ensure indexes are up-to-date
      apk update
      # --no-cache avoids cache growth
      apk add --no-cache "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive refresh
      zypper --non-interactive install --force-resolution "${pkgs[@]}"
      ;;
    *)
      die "Unsupported package manager. Please pre-install required packages: gcc, g++, make, cmake (>=3.15), ninja (optional), git, ca-certificates, pkg-config."
      ;;
  esac
}

#--------------------------
# Install system dependencies
#--------------------------
install_deps() {
  ensure_root_or_warn || return 0
  local pm; pm="$(detect_pm)"

  log "Detected package manager: $pm"

  case "$pm" in
    apt)
      pm_update_and_install apt \
        build-essential cmake ninja-build git ca-certificates pkg-config bash coreutils file
      update-ca-certificates || true
      ;;
    dnf)
      pm_update_and_install dnf \
        gcc gcc-c++ make cmake ninja-build git ca-certificates pkgconf bash coreutils file
      update-ca-trust || true
      ;;
    yum)
      pm_update_and_install yum \
        gcc gcc-c++ make cmake ninja-build git ca-certificates pkgconfig bash coreutils file
      update-ca-trust || true
      ;;
    apk)
      # For Alpine (musl), linux-headers helps build POSIX targets
      pm_update_and_install apk \
        build-base cmake ninja git ca-certificates pkgconf bash coreutils linux-headers file
      update-ca-certificates || true
      ;;
    zypper)
      pm_update_and_install zypper \
        gcc gcc-c++ make cmake ninja git ca-certificates pkg-config bash coreutils file
      c_rehash || true
      ;;
    *)
      die "Could not install dependencies. Unknown package manager."
      ;;
  esac

  # Verify cmake version
  if ! is_command cmake; then
    die "cmake not found after installation."
  fi
  local cmv
  cmv="$(cmake --version | head -n1 | awk '{print $3}')"
  # Compare versions (3.15 min)
  if printf '%s\n%s\n' "3.15.0" "$cmv" | sort -V -C; then
    : # ok
  else
    warn "Detected CMake version $cmv (< 3.15). Some configurations may not work. Consider upgrading base image."
  fi
}

#--------------------------
# Determine FREERTOS_PORT default
#--------------------------
determine_port() {
  local port="${ARG_PORT:-}"
  if [[ -n "$port" ]]; then
    echo "$port"
    return 0
  fi

  # Auto-detect like CMakeLists does
  case "$(uname -s || echo unknown)" in
    Linux|FreeBSD|Darwin)
      echo "GCC_POSIX"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "MSVC_MINGW"
      ;;
    *)
      # Fallback to GCC_POSIX
      echo "GCC_POSIX"
      ;;
  esac
}

#--------------------------
# Setup project directories and FreeRTOSConfig.h
#--------------------------
setup_directories_and_config() {
  log "Setting up project directories and FreeRTOS configuration..."

  mkdir -p "$CONFIG_DIR"
  mkdir -p "$BUILD_DIR"

  # Copy template FreeRTOSConfig.h if not present
  local cfg_src="examples/template_configuration/FreeRTOSConfig.h"
  local cfg_dst="${CONFIG_DIR}/FreeRTOSConfig.h"
  if [[ ! -f "$cfg_dst" ]]; then
    if [[ -f "$cfg_src" ]]; then
      cp -f "$cfg_src" "$cfg_dst"
      log "Copied template FreeRTOSConfig.h to ${cfg_dst}"
    else
      # Create a minimal viable config if template missing
      cat > "$cfg_dst" <<'EOF'
// Minimal FreeRTOSConfig.h autogenerated for host builds
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H
#define configUSE_PREEMPTION            1
#define configUSE_IDLE_HOOK             0
#define configUSE_TICK_HOOK             0
#define configCPU_CLOCK_HZ              ( ( unsigned long ) 20000000 )
#define configTICK_RATE_HZ              ( ( TickType_t ) 100 )
#define configMAX_PRIORITIES            5
#define configMINIMAL_STACK_SIZE        128
#define configTOTAL_HEAP_SIZE           ( ( size_t ) ( 16 * 1024 ) )
#define configMAX_TASK_NAME_LEN         16
#define configUSE_16_BIT_TICKS          0
#define configUSE_MUTEXES               1
#define configUSE_RECURSIVE_MUTEXES     1
#define configUSE_COUNTING_SEMAPHORES   1
#define configUSE_TIMERS                1
#define configTIMER_TASK_PRIORITY       ( configMAX_PRIORITIES - 1 )
#define configTIMER_QUEUE_LENGTH        10
#define configTIMER_TASK_STACK_DEPTH    configMINIMAL_STACK_SIZE
#define INCLUDE_vTaskPrioritySet        1
#define INCLUDE_uxTaskPriorityGet       1
#define INCLUDE_vTaskDelete             1
#define INCLUDE_vTaskSuspend            1
#define INCLUDE_xTaskDelayUntil         1
#define INCLUDE_vTaskDelay              1
#endif /* FREERTOS_CONFIG_H */
EOF
      log "Generated minimal FreeRTOSConfig.h at ${cfg_dst}"
    fi
  else
    log "FreeRTOSConfig.h already present at ${cfg_dst}"
  fi

  # Permissions: safe defaults for Docker
  find "$CONFIG_DIR" -type d -exec chmod 755 {} \; || true
  find "$CONFIG_DIR" -type f -name "*.h" -exec chmod 644 {} \; || true

  # Create .env export file
  cat > "${PROJECT_ROOT}/.freertos_env" <<EOF
# Generated by setup script
export FREERTOS_CONFIG_FILE_DIRECTORY="${PROJECT_ROOT}/${CONFIG_DIR}"
export FREERTOS_HEAP="${FREERTOS_HEAP}"
export FREERTOS_PORT="$(determine_port)"
export BUILD_TYPE="${BUILD_TYPE}"
export BUILD_DIR="${PROJECT_ROOT}/${BUILD_DIR}"
EOF
  chmod 644 "${PROJECT_ROOT}/.freertos_env"
}

#--------------------------
# Configure and build with CMake
#--------------------------
configure_and_build() {
  local fr_port fr_heap gen jobs
  fr_port="$(determine_port)"
  fr_heap="${FREERTOS_HEAP}"

  # Determine generator
  if [[ -z "${GENERATOR}" ]]; then
    if is_command ninja; then
      GENERATOR="Ninja"
    else
      GENERATOR="Unix Makefiles"
    fi
  fi

  # Clean if requested
  if [[ "$REQUEST_CLEAN" -eq 1 ]]; then
    log "Cleaning build directory: ${BUILD_DIR}"
    rm -rf "${BUILD_DIR:?}/"*
  fi

  # Prepare CMake configure command
  local cmake_args=(
    -S "${PROJECT_ROOT}"
    -B "${BUILD_DIR}"
    -G "${GENERATOR}"
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
    -DFREERTOS_CONFIG_FILE_DIRECTORY="${PROJECT_ROOT}/${CONFIG_DIR}"
    -DFREERTOS_HEAP="${fr_heap}"
    -DFREERTOS_PORT="${fr_port}"
  )

  if [[ "$REQUEST_RECONFIGURE" -eq 1 ]]; then
    log "Forcing reconfiguration..."
    cmake "${cmake_args[@]}"
  else
    if [[ ! -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
      log "Configuring project with CMake..."
      cmake "${cmake_args[@]}"
    else
      log "CMake already configured. Skipping reconfiguration. Use --reconfigure to force."
    fi
  fi

  # Determine parallelism
  if is_command nproc; then
    jobs="$(nproc)"
  elif is_command getconf; then
    jobs="$(getconf _NPROCESSORS_ONLN || echo 2)"
  else
    jobs=2
  fi

  log "Building freertos_kernel with generator '${GENERATOR}' (${jobs} parallel jobs)..."
  cmake --build "${BUILD_DIR}" --target freertos_kernel -- -j"${jobs}"

  # Verify artifact
  local libfile
  libfile="$(find "${BUILD_DIR}" -type f -name 'libfreertos_kernel.a' -o -name 'freertos_kernel.lib' | head -n1 || true)"
  if [[ -n "$libfile" ]]; then
    log "Build succeeded. Library located at: $libfile"
  else
    warn "Build finished but library not found. Verify targets in build directory."
  fi
}

#--------------------------
# CI build wrapper for generic projects
#--------------------------
ci_build_if_applicable() {
  # Only run when a recognized build configuration exists
  if [[ -f package.json || -f pom.xml || -f build.gradle || -f build.gradle.kts || -f Cargo.toml || -f pyproject.toml || -f setup.py || -f Makefile ]]; then
    if command -v bash >/dev/null 2>&1; then :; else (command -v apt-get >/dev/null 2>&1 && apt-get update && apt-get install -y bash) || (command -v yum >/dev/null 2>&1 && yum -y install bash) || (command -v apk >/dev/null 2>&1 && apk add --no-cache bash) || true; fi
    chmod +x ci_build.sh
    ./ci_build.sh
    exit $?
  fi
}

#--------------------------
# CI build script generator (to avoid fragile inline quoting)
#--------------------------
write_ci_build_script() {
  cat > ci_build.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

install_pkgs() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@"
  else
    echo "No supported package manager found to install: $*" >&2
    return 1
  fi
}

if [ -f package.json ]; then
  echo "Detected Node.js project"
  if command -v npm >/dev/null 2>&1; then
    npm ci || npm install
    npm run build || npm run build --if-present
  else
    echo "npm not found. Attempting to install Node.js LTS via nvm..."
    export NVM_DIR="$HOME/.nvm"
    mkdir -p "$NVM_DIR"
    if ! command -v curl >/dev/null 2>&1; then
      install_pkgs curl ca-certificates
    fi
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    . "$NVM_DIR/nvm.sh"
    nvm install --lts
    nvm use --lts
    npm ci || npm install
    npm run build || npm run build --if-present
  fi
elif [ -f pom.xml ]; then
  echo "Detected Maven project"
  if ! command -v mvn >/dev/null 2>&1; then
    install_pkgs maven
  fi
  mvn -B -DskipTests package
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  echo "Detected Gradle project"
  if [ -x ./gradlew ]; then
    ./gradlew build || ./gradlew assemble
  else
    if ! command -v gradle >/dev/null 2>&1; then
      install_pkgs gradle
    fi
    gradle build || gradle assemble
  fi
elif [ -f Cargo.toml ]; then
  echo "Detected Rust project"
  if ! command -v cargo >/dev/null 2>&1; then
    install_pkgs cargo
  fi
  cargo build --verbose
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
  echo "Detected Python project"
  if ! command -v python3 >/dev/null 2>&1; then
    install_pkgs python3 python3-pip
  fi
  python3 -m pip install --upgrade pip
  python3 -m pip install . || python3 -m pip install -e .
elif [ -f Makefile ]; then
  echo "Detected Makefile"
  make build || make
else
  echo "No recognized build configuration found" >&2
  exit 1
fi
EOF
  chmod +x ci_build.sh
  printf '.PHONY: build\nbuild:\n\t./ci_build.sh\n' > Makefile
  printf "Created ci_build.sh. To run: bash -lc ./ci_build.sh\n"
}

#--------------------------
# Main
#--------------------------
main() {
  log "Starting FreeRTOS-Kernel environment setup..."

  # Generate a standalone CI build script to avoid nested quoting issues
  write_ci_build_script

  # If this is not a FreeRTOS-Kernel repo, try the generic CI build runner
  ci_build_if_applicable

  # Basic sanity checks
  [[ -f "${PROJECT_ROOT}/CMakeLists.txt" ]] || die "CMakeLists.txt not found in current directory. Run this script from the FreeRTOS-Kernel project root."

  install_deps
  setup_directories_and_config
  configure_and_build

  log "Environment setup completed successfully."
  echo
  echo "Usage tips:"
  echo "  - To rebuild: cmake --build ${BUILD_DIR} --target freertos_kernel"
  echo "  - To clean:   rm -rf ${BUILD_DIR}/*"
  echo "  - To configure your shell: source ./.freertos_env"
  echo "  - To override port: re-run with --port GCC_POSIX (or set FREERTOS_PORT env)"
}

main "$@"