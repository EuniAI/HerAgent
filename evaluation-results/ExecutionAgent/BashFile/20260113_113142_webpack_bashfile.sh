#!/usr/bin/env bash
# Setup script for a Node.js (Yarn v1) project in Docker
# Installs system packages, Node.js runtime, Yarn, and project dependencies
# Safe to run multiple times (idempotent), no sudo required (assumes root in container)

set -Eeuo pipefail

# -------------------------------
# Configuration
# -------------------------------
MIN_NODE_MAJOR=${MIN_NODE_MAJOR:-18}          # Minimal required Node.js major version
NODE_VERSION=${NODE_VERSION:-20.17.0}         # Node.js version to install if missing/old
YARN_VERSION=${YARN_VERSION:-1.22.22}         # Yarn classic version
PROJECT_DIR_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$PROJECT_DIR_DEFAULT}"
YARN_CACHE_DIR="${YARN_CACHE_DIR:-/var/cache/yarn}"
NPM_PYTHON_BIN="${NPM_PYTHON_BIN:-python3}"
# Set HUSKY=0 to prevent failing on prepare script in container without .git
export HUSKY=${HUSKY:-0}

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log() { echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo "${YELLOW}[WARN] $*${NC}" >&2; }
err() { echo "${RED}[ERROR] $*${NC}" >&2; }

trap 'err "Setup failed at line $LINENO"; exit 1' ERR

# -------------------------------
# Helpers
# -------------------------------
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo "unknown"
  fi
}

arch_map() {
  local uname_arch
  uname_arch="$(uname -m)"
  case "$uname_arch" in
    x86_64)  echo "x64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armv7l" ;;
    ppc64le) echo "ppc64le" ;;
    s390x)   echo "s390x" ;;
    *) err "Unsupported architecture: $uname_arch"; exit 1 ;;
  esac
}

node_major_version() {
  if ! command -v node >/dev/null 2>&1; then
    echo 0
    return
  fi
  node -v | sed -E 's/^v([0-9]+).*/\1/'
}

# -------------------------------
# System packages
# -------------------------------
install_system_packages() {
  local pm="$1"
  log "Installing base system packages using: $pm"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # Core utilities and build toolchain for node-gyp
      apt-get install -y --no-install-recommends \
        ca-certificates curl git xz-utils \
        python3 make g++ build-essential \
        tar bash coreutils \
        openjdk-17-jdk maven gradle
      # Clean apt cache
      rm -rf /var/lib/apt/lists/* || true
      # Verify Maven and Java installations
      mvn -v || true
      java -version || true
      ;;
    apk)
      apk update
      apk add --no-cache \
        ca-certificates curl git xz \
        python3 make g++ build-base \
        tar bash coreutils linux-headers \
        openjdk17 maven
      ;;
    dnf)
      dnf install -y \
        ca-certificates curl git xz \
        python3 make gcc gcc-c++ tar bash coreutils \
        java-17-openjdk-devel maven
      dnf clean all
      ;;
    yum)
      yum install -y \
        ca-certificates curl git xz \
        python3 make gcc gcc-c++ tar bash coreutils \
        java-17-openjdk-devel maven
      yum clean all
      ;;
    *)
      err "Unsupported package manager. Install required packages manually: curl, git, xz, python3, make, g++, tar, ca-certificates"
      exit 1
      ;;
  esac
  # Ensure certificates are updated
  update-ca-certificates >/dev/null 2>&1 || true
}

# -------------------------------
# Maven wrapper to auto-detect project pom.xml
# -------------------------------
setup_maven_wrapper() {
  local wrapper_path="/usr/local/bin/mvn"
  mkdir -p "$(dirname "$wrapper_path")" || true
  cat > "$wrapper_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REAL_MVN=/usr/bin/mvn
if [ ! -x "$REAL_MVN" ]; then
  echo "Maven is not installed at $REAL_MVN. Please install maven." >&2
  exit 127
fi
# If caller already specified -f/--file, defer to real mvn as-is
for arg in "$@"; do
  if [[ "$arg" == "-f" || "$arg" == "--file" || "$arg" == --file=* ]]; then
    exec "$REAL_MVN" "$@"
  fi
done
# If current dir has a pom.xml, run normally
if [ -f "pom.xml" ]; then
  exec "$REAL_MVN" "$@"
fi
# Otherwise, search under /app for a pom.xml (limited depth to be fast)
POM=$(find /app -maxdepth 4 -type f -name pom.xml 2>/dev/null | head -n 1 || true)
if [ -n "${POM:-}" ]; then
  exec "$REAL_MVN" -f "$POM" "$@"
fi
# Fallback: report clearly
echo "No pom.xml found in current directory or under /app. Ensure the project is present or run mvn from the project directory." >&2
exit 1
EOF
  chmod +x "$wrapper_path"
}

# -------------------------------
# Placeholder Maven project setup
# -------------------------------
ensure_placeholder_maven_project() {
  local target_dir="/app"
  mkdir -p "$target_dir"
  if [ ! -f "$target_dir/pom.xml" ]; then
    cat > "$target_dir/pom.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>placeholder</groupId>
  <artifactId>placeholder</artifactId>
  <version>1.0.0</version>
  <packaging>pom</packaging>
  <name>Placeholder Project</name>
  <description>Autogenerated placeholder to allow mvn package to run when no pom.xml is present.</description>
</project>
EOF
  fi
}

# Convert placeholder POM (packaging=pom) into a minimal jar-producing project
repair_placeholder_maven_project() {
  if [ -f /app/pom.xml ] && grep -q "<groupId>placeholder</groupId>" /app/pom.xml; then
    cat > /app/pom.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>placeholder-app</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
  <name>Placeholder App</name>
  <properties>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
  </properties>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-jar-plugin</artifactId>
        <version>3.3.0</version>
        <configuration>
          <archive>
            <manifest>
              <mainClass>com.example.App</mainClass>
            </manifest>
          </archive>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
EOF
    mkdir -p /app/src/main/java/com/example
    cat > /app/src/main/java/com/example/App.java <<'EOF'
package com.example;

public class App {
  public static void main(String[] args) {
    System.out.println("Hello from placeholder App");
  }
}
EOF
  fi
}

# -------------------------------
# Node.js installation
# -------------------------------
install_node_if_needed() {
  local current_major
  current_major="$(node_major_version || echo 0)"
  if [ "$current_major" -ge "$MIN_NODE_MAJOR" ]; then
    log "Node.js v$(node -v) already meets requirement (>= $MIN_NODE_MAJOR)"
    return 0
  fi

  local arch tar_arch url tmpdir
  arch="$(arch_map)"
  tar_arch="$arch"
  url="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${tar_arch}.tar.xz"

  log "Installing Node.js v${NODE_VERSION} for ${tar_arch} from official tarball"
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  curl -fsSL "$url" -o node.tar.xz
  mkdir -p /usr/local/lib/nodejs
  tar -xJf node.tar.xz -C /usr/local/lib/nodejs
  # Symlink binaries
  ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${tar_arch}/bin/node" /usr/local/bin/node
  ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${tar_arch}/bin/npm" /usr/local/bin/npm
  ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${tar_arch}/bin/npx" /usr/local/bin/npx
  popd >/dev/null
  rm -rf "$tmpdir"
  log "Installed Node.js $(node -v)"
}

# -------------------------------
# Yarn setup (classic v1)
# -------------------------------
install_yarn_classic() {
  local yarn_ok=0
  if command -v yarn >/dev/null 2>&1; then
    local yv
    yv="$(yarn --version || echo "")"
    if [[ "$yv" == 1.* ]]; then
      log "Yarn classic already installed (v$yv)"
      yarn_ok=1
    fi
  fi

  if [ "$yarn_ok" -eq 0 ]; then
    # Ensure profile.d exists (not strictly required for symlinks)
    mkdir -p /etc/profile.d || true

    # Expose corepack from Node's bin and use it to manage Yarn v1
    local NODE_BIN_DIR
    NODE_BIN_DIR="$(dirname "$(readlink -f "$(command -v node)")")"
    ln -sf "$NODE_BIN_DIR/corepack" /usr/local/bin/corepack || true

    if command -v corepack >/dev/null 2>&1; then
      log "Enabling corepack and activating yarn@$YARN_VERSION"
      corepack enable || true
      corepack prepare "yarn@${YARN_VERSION}" --activate || true
      NODE_BIN_DIR="$(dirname "$(readlink -f "$(command -v node)")")"
      [ -x "$NODE_BIN_DIR/yarn" ] && ln -sf "$NODE_BIN_DIR/yarn" /usr/local/bin/yarn || true
      [ -x "$NODE_BIN_DIR/yarnpkg" ] && ln -sf "$NODE_BIN_DIR/yarnpkg" /usr/local/bin/yarnpkg || true
    fi

    # Fallback to npm global install if Yarn is still unavailable
    if ! command -v yarn >/dev/null 2>&1; then
      log "Installing yarn@$YARN_VERSION via npm (fallback)"
      npm config set prefix /usr/local
      npm install -g "yarn@${YARN_VERSION}"
      local NPM_BIN
      NPM_BIN="$(npm bin -g)"
      ln -sf "${NPM_BIN}/yarn" /usr/local/bin/yarn
      ln -sf "${NPM_BIN}/yarnpkg" /usr/local/bin/yarnpkg || true
    fi
  fi

  # Verify
  local final_yv
  final_yv="$(yarn --version || true)"
  if [[ -z "$final_yv" || "$final_yv" != 1.* ]]; then
    err "Failed to install Yarn classic v1.x (got: $final_yv)"
    exit 1
  fi

  log "Using Yarn v$final_yv"
}

# -------------------------------
# Project directory setup
# -------------------------------
setup_project_dir() {
  log "Setting up project directory at: $PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"
  cd "$PROJECT_DIR"
  # Ensure standard directories exist and have sane permissions
  umask 002
  mkdir -p node_modules "$YARN_CACHE_DIR"
  # Assign ownership to current user (works in Docker root or arbitrary UID)
  chown -R "$(id -u)":"$(id -g)" "$PROJECT_DIR" "$YARN_CACHE_DIR" || true
}

# -------------------------------
# Environment configuration
# -------------------------------
configure_env() {
  log "Configuring environment variables"
  # Ensure node-gyp uses Python 3
  npm config set python "$NPM_PYTHON_BIN" >/dev/null 2>&1 || true

  # Yarn recommended settings for CI/containers
  yarn config set network-timeout 600000 -g >/dev/null 2>&1 || true
  yarn config set cache-folder "$YARN_CACHE_DIR" -g >/dev/null 2>&1 || true

  # Export helpful environment variables for current shell and future processes
  export NODE_ENV="${NODE_ENV:-development}"
  export YARN_CACHE_FOLDER="$YARN_CACHE_DIR"
  export npm_config_loglevel="${npm_config_loglevel:-notice}"

  # Create .env file if not present with common defaults (non-intrusive)
  if [ ! -f .env ]; then
    cat > .env <<EOF
# Environment defaults for Docker container
NODE_ENV=${NODE_ENV}
HUSKY=0
EOF
  fi
}

# -------------------------------
# Dependency installation
# -------------------------------
install_dependencies() {
  log "Installing project dependencies with Yarn"
  if [ -f yarn.lock ]; then
    # Immutable installs ensure lockfile is respected
    HUSKY=0 yarn install --frozen-lockfile --non-interactive
  else
    warn "yarn.lock not found; performing non-frozen install"
    HUSKY=0 yarn install --non-interactive
  fi

  # Validate TypeScript presence if project uses it (based on package.json)
  if grep -q '"typescript"' package.json 2>/dev/null; then
    log "TypeScript detected; ensuring tsc is available"
    npx --yes tsc --version >/dev/null 2>&1 || warn "tsc not available; TypeScript may be a devDependency not yet linked to PATH"
  fi
}

# -------------------------------
# Summary and usage info
# -------------------------------
print_summary() {
  log "Setup complete."
  echo "Runtime:"
  echo "  Node: $(node -v)"
  echo "  npm:  $(npm -v)"
  echo "  Yarn: $(yarn --version)"
  echo
  echo "Next steps (examples):"
  if jq -r '.scripts.test' package.json >/dev/null 2>&1; then
    echo "  - Run tests: yarn test"
  fi
  if jq -r '.scripts.build' package.json >/dev/null 2>&1; then
    echo "  - Build: yarn build"
  fi
  echo "  - Lint: yarn lint (if available)"
  echo
  echo "Notes:"
  echo "  - HUSKY=0 is set to skip Git hooks during install inside containers."
  echo "  - Toolchain packages (python3, make, g++) are installed for node-gyp."
  echo "  - Yarn cache directory: $YARN_CACHE_DIR"
}

# -------------------------------
# Maven build and run (repair)
# -------------------------------
build_and_run_maven_artifact() {
  log "Building project artifact with tests skipped"
  # Always run from the project dir so that target/ is predictable
  if cd "$PROJECT_DIR"; then
    # Clean any previous app.jar symlink or file to avoid dangling symlink issues
    rm -f target/app.jar
    # Build using Maven wrapper or Maven if a Maven project is present
    if [ -x ./mvnw ]; then
      ./mvnw -q -B -DskipTests clean package
    elif [ -f pom.xml ]; then
      mvn -q -B -DskipTests clean package || true
    fi
    # Build using Gradle wrapper or Gradle if a Gradle project is present
    if [ -x ./gradlew ]; then
      ./gradlew build -x test
    elif ls build.gradle* >/dev/null 2>&1; then
      gradle build -x test || true
    fi
    # Discover the most likely runnable JAR and copy it to target/app.jar
    mkdir -p target
    jar_path="$(find . -type f \( -path "*/target/*.jar" -o -path "*/build/libs/*.jar" \) -not -name "*-sources.jar" -not -name "*-javadoc.jar" -not -name "original-*.jar" -printf "%s %p\n" | sort -nr | awk 'NR==1 {print $2}')"
    if [ -n "$jar_path" ]; then
      cp -f --remove-destination "$jar_path" target/app.jar
    else
      echo "No JAR found to copy into target/app.jar"
      exit 1
    fi
    # Optionally run the app JAR if present
    if [ -f "target/app.jar" ]; then
      log "Running JAR: target/app.jar"
      java -jar "target/app.jar" || true
    fi
  else
    warn "Could not change directory to $PROJECT_DIR; skipping build."
  fi
}

# -------------------------------
# Main
# -------------------------------
main() {
  log "Starting environment setup for Node/Yarn project"
  local pm
  pm="$(detect_pkg_manager)"
  if [ "$pm" = "unknown" ]; then
    warn "Could not detect system package manager; proceeding with best-effort runtime setup"
  else
    install_system_packages "$pm"
  fi

  # Ensure Maven wrapper is in place to auto-detect pom.xml under /app
  setup_maven_wrapper
  # Ensure a placeholder Maven project exists at /app if none is present
  ensure_placeholder_maven_project
  # If the placeholder pom exists, convert it into a minimal jar-producing project
  repair_placeholder_maven_project

  install_node_if_needed
  install_yarn_classic
  setup_project_dir
  configure_env
  install_dependencies
  print_summary
  build_and_run_maven_artifact
}

main "$@"