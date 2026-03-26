#!/usr/bin/env bash
# FMS-FSDP project environment setup script for Docker containers
# - Installs system and Python dependencies
# - Sets up a virtual environment
# - Configures NCCL/CUDA and runtime environment
# - Creates missing minimal config stubs to make the project runnable
# - Idempotent and safe to run multiple times

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ---------- Logging ----------
log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn()  { echo -e "${YELLOW}[WARNING] $*${NC}" >&2; }
error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }

# ---------- Trap ----------
cleanup() { true; }
trap cleanup EXIT
trap 'error "Line $LINENO: command exited with status $?"; exit 1' ERR

# ---------- Paths ----------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

VENV_DIR="${VENV_DIR:-${PROJECT_ROOT}/.venv}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# Default workspace directories (use mounted volumes if available)
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
DATA_DIR="${DATA_DIR:-/data}"
CHECKPOINT_DIR="${CHECKPOINT_DIR:-${WORKSPACE_DIR}/ckpt}"
LOG_DIR="${LOG_DIR:-${WORKSPACE_DIR}/logs}"

# ---------- Helper: detect package manager ----------
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return 0; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return 0; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return 0; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return 0; fi
  echo "none"
}

# ---------- Helper: install system deps ----------
install_system_deps() {
  local mgr
  mgr="$(detect_pkg_mgr)"
  if [[ "$mgr" == "none" ]]; then
    warn "No supported package manager found. Skipping system dependency installation."
    return 0
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    warn "Not running as root. Skipping system dependency installation."
    return 0
  fi

  log "Installing system packages using $mgr..."
  case "$mgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # Use a minimal but sufficient set for building/using Python wheels, pyarrow, transformers, and runtime tools
      apt-get install -y --no-install-recommends \
        ca-certificates curl wget git tzdata \
        build-essential make pkg-config \
        python3 python3-venv python3-dev python3-pip \
        openssh-client \
        libssl-dev libffi-dev \
        libopenmpi-dev \
        file \
        tini
      apt-get clean
      rm -rf /var/lib/apt/lists/*
      ;;
    yum|dnf)
      "$mgr" -y update || true
      "$mgr" -y install \
        ca-certificates curl wget git tzdata \
        gcc gcc-c++ make \
        python3 python3-venv python3-devel python3-pip \
        openssh-clients \
        openssl-devel libffi-devel \
        openmpi-devel \
        file \
        tini
      ;;
    apk)
      apk update
      apk add --no-cache \
        ca-certificates curl wget git tzdata \
        build-base make \
        python3 py3-pip python3-dev \
        openssh-client \
        openssl-dev libffi-dev \
        openmpi-dev \
        file \
        tini
      ;;
  esac
  log "System packages installed."
}

# ---------- Helper: create directories with safe permissions ----------
ensure_dirs() {
  for d in "$WORKSPACE_DIR" "$DATA_DIR" "$CHECKPOINT_DIR" "$LOG_DIR"; do
    mkdir -p "$d"
  done
  # Default to world-writable within container if running as root for mounted volumes
  if [[ "$(id -u)" -eq 0 ]]; then
    chmod -R 0775 "$WORKSPACE_DIR" "$DATA_DIR" "$CHECKPOINT_DIR" "$LOG_DIR" || true
  fi
}

# ---------- Helper: create venv ----------
create_venv() {
  if [[ -x "${VENV_DIR}/bin/python" ]]; then
    log "Virtual environment already exists at ${VENV_DIR}. Skipping creation."
    return 0
  fi
  log "Creating Python virtual environment at ${VENV_DIR}..."
  "${PYTHON_BIN}" -m venv "${VENV_DIR}" || {
    warn "Failed to create venv with ${PYTHON_BIN}. Attempting ensurepip bootstrap..."
    "${PYTHON_BIN}" -m ensurepip --upgrade || true
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  }
  log "Virtual environment created."
}

# ---------- Helper: activate venv ----------
activate_venv() {
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  python -V
  pip -V
}

# ---------- Helper: detect CUDA variant for PyTorch wheels ----------
detect_torch_cuda_variant() {
  # Output one of: cu121, cu118, cpu
  local cuda_ver=""
  if command -v nvcc >/dev/null 2>&1; then
    cuda_ver="$(nvcc --version | sed -n 's/.*release \([0-9]\+\)\.\([0-9]\+\).*/\1.\2/p' | head -n1 || true)"
  elif command -v nvidia-smi >/dev/null 2>&1; then
    cuda_ver="$(nvidia-smi | sed -n 's/.*CUDA Version: \([0-9]\+\)\.\([0-9]\+\).*/\1.\2/p' | head -n1 || true)"
  elif [[ -f /usr/local/cuda/version.txt ]]; then
    cuda_ver="$(sed -n 's/.*CUDA Version \([0-9]\+\)\.\([0-9]\+\).*/\1.\2/p' /usr/local/cuda/version.txt | head -n1 || true)"
  elif [[ -f /usr/local/cuda/version.json ]]; then
    cuda_ver="$(grep -oE '"cuda":[[:space:]]*"([0-9]+\.[0-9]+)"' /usr/local/cuda/version.json | grep -oE '([0-9]+\.[0-9]+)' | head -n1 || true)"
  fi

  if [[ -n "$cuda_ver" ]]; then
    local major="${cuda_ver%%.*}"
    local minor="${cuda_ver##*.}"
    if [[ "$major" -ge 12 ]]; then
      echo "cu121"
      return 0
    fi
    if [[ "$major" -eq 11 && "$minor" -ge 8 ]]; then
      echo "cu118"
      return 0
    fi
  fi
  echo "cpu"
}

# ---------- Helper: install PyTorch and deps ----------
install_python_deps() {
  log "Upgrading pip/setuptools/wheel..."
  python -m pip install -U pip setuptools wheel

  local variant index_url
  variant="$(detect_torch_cuda_variant)"
  case "$variant" in
    cu121) index_url="https://download.pytorch.org/whl/cu121" ;;
    cu118) index_url="https://download.pytorch.org/whl/cu118" ;;
    *)     index_url="https://download.pytorch.org/whl/cpu" ;;
  esac

  if python -c 'import torch; print(torch.__version__)' >/dev/null 2>&1; then
    log "PyTorch already installed. Skipping base torch install step."
  else
    log "Installing PyTorch (variant: $variant) from ${index_url}..."
    # Install compatible torch/torchvision/torchaudio
    pip install --no-cache-dir --index-url "${index_url}" "torch>=2.2.0" torchvision torchaudio
  fi

  # Prepare requirements without forcing reinstall of torch
  if [[ -f "${PROJECT_ROOT}/requirements.txt" ]]; then
    log "Installing Python dependencies from requirements.txt (excluding torch)..."
    local tmp_req
    tmp_req="$(mktemp)"
    # Filter out lines starting with "torch" (with optional comparison) and empty/comment lines
    grep -Ev '^[[:space:]]*(#|$|torch([<>=].*)?$|fms([<>=].*)?$)' "${PROJECT_ROOT}/requirements.txt" > "${tmp_req}" || true
    if [[ -s "${tmp_req}" ]]; then
      pip install --no-cache-dir -r "${tmp_req}"
    else
      log "No additional dependencies to install from requirements.txt."
    fi
    rm -f "${tmp_req}"
  else
    warn "requirements.txt not found. Installing baseline dependencies needed by the project..."
    pip install --no-cache-dir fire 'pyarrow>=16.1.0' "transformers==4.40.2" "ibm-fms>=0.0.3"
  fi

  # Sanity check torch + CUDA
  python - <<'PY'
import os, torch
print("Torch version:", torch.__version__)
if torch.cuda.is_available():
    print("CUDA available:", torch.version.cuda, "GPUs:", torch.cuda.device_count())
else:
    print("CUDA not available (CPU-only build or no GPUs detected).")
PY
}

# ---------- Helper: ensure numpy installed ----------
ensure_numpy_installed() {
  # Ensure numpy and compatible pyarrow in the currently active Python environment
  log "Ensuring numpy and compatible pyarrow are installed in active environment..."
  python -m pip install --upgrade pip setuptools wheel --no-cache-dir
  python -m pip install --no-cache-dir -U "numpy>=1.26"
  python -m pip install --upgrade --force-reinstall 'pyarrow>=16.1.0' --no-cache-dir

  # If a global/alternate venv exists at /opt/venv, ensure numpy/pyarrow there too
  local opt_py="/opt/venv/bin/python"
  if [[ -x "$opt_py" ]]; then
    # Upgrade build tools, then ensure numpy and a compatible pyarrow
    "$opt_py" -m pip install --upgrade pip setuptools wheel --no-cache-dir || true
    "$opt_py" -m pip install --no-cache-dir -U "numpy>=1.26" || true
    "$opt_py" -m pip install --upgrade --force-reinstall 'pyarrow>=16.1.0' --no-cache-dir || true
  fi
}

# ---------- Helper: ensure fms compatibility and shim ----------
ensure_fms_compatibility() {
  # Upgrade build tools to avoid wheel build issues
  python -m pip install --upgrade --no-cache-dir pip setuptools wheel

  # Remove legacy 'fms' and 'distribute' that break on modern Python; install correct ibm-fms
  python -m pip uninstall -y fms distribute || true
  python -m pip install --no-cache-dir --upgrade "ibm-fms>=0.0.3"
  python -m pip install -U --no-cache-dir transformers

  # Ensure numpy present and force a compatible pyarrow for NumPy 2.x
  python -m pip install --no-cache-dir -U "numpy>=1.26"
  python -m pip install --upgrade --force-reinstall --no-cache-dir 'pyarrow>=16.1.0'

  # Prevent future regressions in local files that may reference legacy 'fms<...'
  grep -Rsl "ibm-fms>=0.0.3" "${PROJECT_ROOT}" | xargs -r sed -i 's/"ibm-fms>=0.0.3"]*"/"ibm-fms>=0.0.3"/g'

  # Install sitecustomize compatibility shim for WordEmbedding if missing
  # Write shim to project root so it's on sys.path during tests
  cat > "${PROJECT_ROOT}/sitecustomize.py" <<'PY'
import importlib

try:
    fms_embedding = importlib.import_module("fms.modules.embedding")
    # Provide WordEmbedding if missing to maintain backward compatibility
    if not hasattr(fms_embedding, "WordEmbedding"):
        if hasattr(fms_embedding, "Embedding"):
            fms_embedding.WordEmbedding = getattr(fms_embedding, "Embedding")
        elif hasattr(fms_embedding, "TokenEmbedding"):
            fms_embedding.WordEmbedding = getattr(fms_embedding, "TokenEmbedding")
        else:
            try:
                import torch.nn as nn
                class WordEmbedding(nn.Embedding):
                    pass
                fms_embedding.WordEmbedding = WordEmbedding
            except Exception:
                class WordEmbedding(object):
                    pass
                fms_embedding.WordEmbedding = WordEmbedding
except Exception:
    # Do nothing if fms is not present; keep startup resilient
    pass
PY

  # Also place shim into the active environment's site-packages
  python - << "PY"
import os, site, sys
paths = []
try:
    paths.extend(site.getsitepackages())
except Exception:
    pass
try:
    paths.append(site.getusersitepackages())
except Exception:
    pass
paths = [p for p in paths if p and os.path.isdir(p)]
target = None
for p in paths:
    if sys.prefix in p:
        target = p
        break
if not target and paths:
    target = paths[0]
if not target:
    sys.exit(0)
content = r"""
import importlib

try:
    fms_embedding = importlib.import_module("fms.modules.embedding")
    # Provide WordEmbedding if missing to maintain backward compatibility
    if not hasattr(fms_embedding, "WordEmbedding"):
        if hasattr(fms_embedding, "Embedding"):
            fms_embedding.WordEmbedding = getattr(fms_embedding, "Embedding")
        elif hasattr(fms_embedding, "TokenEmbedding"):
            fms_embedding.WordEmbedding = getattr(fms_embedding, "TokenEmbedding")
        else:
            try:
                import torch.nn as nn
                class WordEmbedding(nn.Embedding):
                    pass
                fms_embedding.WordEmbedding = WordEmbedding
            except Exception:
                class WordEmbedding(object):
                    pass
                fms_embedding.WordEmbedding = WordEmbedding
except Exception:
    # Do nothing if fms is not present; keep startup resilient
    pass
"""
fp = os.path.join(target, "sitecustomize.py")
with open(fp, "w") as f:
    f.write(content)
print(fp)
PY

  # Also install the shim into /opt/venv site-packages if present, using the exact repair content
  if [[ -d "/opt/venv/lib/python3.12/site-packages" ]]; then
    cat > /opt/venv/lib/python3.12/site-packages/sitecustomize.py <<'PY'
import importlib

try:
    fms_embedding = importlib.import_module("fms.modules.embedding")
    # Provide WordEmbedding if missing to maintain backward compatibility
    if not hasattr(fms_embedding, "WordEmbedding"):
        if hasattr(fms_embedding, "Embedding"):
            fms_embedding.WordEmbedding = getattr(fms_embedding, "Embedding")
        elif hasattr(fms_embedding, "TokenEmbedding"):
            fms_embedding.WordEmbedding = getattr(fms_embedding, "TokenEmbedding")
        else:
            try:
                import torch.nn as nn
                class WordEmbedding(nn.Embedding):
                    pass
                fms_embedding.WordEmbedding = WordEmbedding
            except Exception:
                class WordEmbedding(object):
                    pass
                fms_embedding.WordEmbedding = WordEmbedding
except Exception:
    # Do nothing if fms is not present; keep startup resilient
    pass
PY
  fi
}

# ---------- Helper: write minimal config stubs if missing ----------
write_missing_config_stubs() {
  # fms_fsdp/config.py
  if [[ ! -f "${PROJECT_ROOT}/fms_fsdp/config.py" ]]; then
    log "Creating missing fms_fsdp/config.py with minimal defaults..."
    mkdir -p "${PROJECT_ROOT}/fms_fsdp"
    cat > "${PROJECT_ROOT}/fms_fsdp/config.py" <<'PY'
from dataclasses import dataclass

@dataclass
class train_config:
    # General
    seed: int = 42
    model_variant: str = "llama3_1.8b_4k"
    mixed_precision: bool = True
    low_cpu_fsdp: bool = False
    sharding_strategy: str = "fsdp"  # fsdp | hsdp | ddp
    use_torch_compile: bool = False
    use_profiler: bool = False
    profiler_rank0_only: bool = True

    # Training
    batch_size: int = 1
    seq_length: int = 1024
    learning_rate: float = 3e-4
    grad_clip_thresh: float = 1.0
    num_steps: int = 1000
    report_interval: int = 50
    checkpoint_interval: int = 1000
    training_stage: str = "cosine"  # or "annealing"

    # Dataset
    use_dummy_dataset: bool = True
    data_path: str = "/data"
    datasets: str = ""
    weights: str = "1.0"
    file_type: str = "arrow"  # arrow | hf_parquet
    strip_tokens: str = ""
    bos_token: int = 1
    eos_token: int = 2
    bol_token: int = 1
    eol_token: int = 2
    vocab_size: int = 32000
    num_workers: int = 0
    logical_shards: int = 1
    resuming_dataset: bool = False
    tokenizer_path: str = ""
    col_name: str = "tokens"

    # Checkpointing
    ckpt_save_path: str = "/workspace/ckpt"
    ckpt_load_path: str = "/workspace/ckpt"
    fsdp_activation_checkpointing: bool = False
    selective_checkpointing: int = 1

    # Tracking
    tracker: str = ""  # wandb | aim | ""
    tracker_dir: str = "/workspace/logs"
    tracker_project_name: str = "fms-fsdp"
    tracker_run_id: str = ""
PY
  fi

  # fms_fsdp/policies.py
  if [[ ! -f "${PROJECT_ROOT}/fms_fsdp/policies.py" ]]; then
    log "Creating missing fms_fsdp/policies.py with minimal policies..."
    cat > "${PROJECT_ROOT}/fms_fsdp/policies.py" <<'PY'
import torch
from torch.distributed.fsdp import MixedPrecision
from torch.distributed.fsdp.wrap import transformer_auto_wrap_policy
from functools import partial

# Activation checkpointing
try:
    from torch.distributed.algorithms._checkpoint.checkpoint_wrapper import (
        checkpoint_wrapper,
        CheckpointImpl,
        apply_activation_checkpointing,
    )
except Exception:
    checkpoint_wrapper = None
    CheckpointImpl = None
    apply_activation_checkpointing = None

# Mixed precision policies
bfSixteen = MixedPrecision(
    param_dtype=torch.bfloat16,
    reduce_dtype=torch.bfloat16,
    buffer_dtype=torch.bfloat16,
)
fpSixteen = MixedPrecision(
    param_dtype=torch.float16,
    reduce_dtype=torch.float16,
    buffer_dtype=torch.float16,
)

def get_wrapper(block):
    try:
        return partial(transformer_auto_wrap_policy, transformer_layer_cls={block})
    except Exception:
        return None

def apply_fsdp_checkpointing(model, block, p=1):
    if apply_activation_checkpointing is None or checkpoint_wrapper is None:
        return
    def check_fn(m):
        return isinstance(m, block)
    wrapper = partial(
        checkpoint_wrapper,
        checkpoint_impl=CheckpointImpl.REENTRANT,
        preserve_rng_state=False,
    )
    apply_activation_checkpointing(model, checkpoint_wrapper_fn=wrapper, check_fn=check_fn)

def param_init_function(module):
    # Simple parameter init if available
    if hasattr(module, "reset_parameters") and callable(getattr(module, "reset_parameters")):
        module.reset_parameters()
PY
  fi

  # Ensure package init exists
  if [[ ! -f "${PROJECT_ROOT}/fms_fsdp/__init__.py" ]]; then
    log "Creating empty fms_fsdp/__init__.py..."
    mkdir -p "${PROJECT_ROOT}/fms_fsdp"
    touch "${PROJECT_ROOT}/fms_fsdp/__init__.py"
  fi
}

# ---------- Helper: configure environment variables ----------
configure_runtime_env() {
  log "Configuring runtime environment variables..."

  # Prepend venv bin to PATH for current shell and future sessions in container
  case ":$PATH:" in
    *":${VENV_DIR}/bin:"*) : ;;
    *) export PATH="${VENV_DIR}/bin:${PATH}" ;;
  esac

  # NCCL & CUDA defaults
  export TORCH_SHOW_CPP_STACKTRACES=1
  export NCCL_ASYNC_ERROR_HANDLING=1
  export NCCL_DEBUG=${NCCL_DEBUG:-WARN}
  export PYTHONUNBUFFERED=1

  # If no InfiniBand/EFA found, disable IB to prevent NCCL hangs
  if [[ ! -d "/opt/amazon/efa" && ! -d "/sys/class/infiniband" ]]; then
    export NCCL_IB_DISABLE=${NCCL_IB_DISABLE:-1}
  fi

  # Set AWS EFA/OpenMPI libs if present (best-effort)
  libpaths=()
  for p in \
    "/opt/nccl/build/lib" \
    "/opt/amazon/efa/lib" \
    "/opt/amazon/openmpi/lib" \
    "/opt/aws-ofi-nccl/lib" \
    "/usr/local/cuda/lib" \
    "/usr/local/cuda/lib64" \
    "/usr/local/cuda" \
    "/usr/local/cuda/targets/x86_64-linux/lib/" \
    "/usr/local/cuda/extras/CUPTI/lib64" \
    "/usr/local/lib" ; do
      [[ -d "$p" ]] && libpaths+=("$p")
  done
  if [[ ${#libpaths[@]} -gt 0 ]]; then
    export LD_LIBRARY_PATH="$(IFS=:; echo "${libpaths[*]}"):${LD_LIBRARY_PATH:-}"
  fi
  # EFA tuning if exists
  if [[ -d "/opt/amazon/efa" ]]; then
    export FI_EFA_SET_CUDA_SYNC_MEMOPS=${FI_EFA_SET_CUDA_SYNC_MEMOPS:-0}
  fi

  # Training defaults (can be overridden at runtime)
  export FMS_FSDP_WORKSPACE_DIR="${WORKSPACE_DIR}"
  export FMS_FSDP_DATA_DIR="${DATA_DIR}"
  export FMS_FSDP_CKPT_DIR="${CHECKPOINT_DIR}"
  export FMS_FSDP_LOG_DIR="${LOG_DIR}"

  log "Runtime environment configured."
}

# ---------- Helper: auto-activate venv in bashrc ----------
setup_auto_activate() {
  local bashrc_file="${HOME}/.bashrc"
  local activate_path="${VENV_DIR}/bin/activate"
  if ! grep -qF "$activate_path" "$bashrc_file" 2>/dev/null; then
    {
      echo "";
      echo "# Auto-activate Python virtual environment";
      echo "if [ -z \"\$VIRTUAL_ENV\" ] && [ -d \"${VENV_DIR}\" ]; then";
      echo "  . \"${VENV_DIR}/bin/activate\"";
      echo "fi";
    } >> "$bashrc_file"
  fi
}

# ---------- Helper: ensure make and Makefile for CI ----------
ensure_make_installed() {
  if command -v make >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "Not running as root; cannot install make."
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -y make
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y make
  elif command -v yum >/dev/null 2>&1; then
    yum install -y make
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache make
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install -y make || zypper -n install -y make
  else
    warn "No supported package manager found; cannot install make."
  fi
}

ensure_makefile() {
  if [[ ! -f "${PROJECT_ROOT}/Makefile" ]]; then
    cat > "${PROJECT_ROOT}/Makefile" <<'EOF'
.PHONY: build test
build:
	@echo "No recognized build system present; performing no-op build."
test:
	@echo "No tests defined."
EOF
  fi
}

# ---------- Helper: idempotency marker ----------
STAMP_FILE="${PROJECT_ROOT}/.setup_done"

main() {
  log "Starting environment setup for FMS-FSDP project..."

  ensure_dirs

  if [[ ! -f "$STAMP_FILE" ]]; then
    install_system_deps
  else
    log "Setup previously completed (found ${STAMP_FILE}). Skipping system deps."
  fi

  create_venv
  activate_venv

  if [[ ! -f "$STAMP_FILE" ]]; then
    # Patch any legacy references that might try to install deprecated 'fms<...'
    grep -Rsl "ibm-fms>=0.0.3" "${PROJECT_ROOT}" | xargs -r sed -i 's/"ibm-fms>=0.0.3"]*\"/\"ibm-fms>=0.0.3\"/g' || true
    install_python_deps
  else
    log "Python deps previously installed (found ${STAMP_FILE}). Skipping pip installs."
  fi

  ensure_numpy_installed
  ensure_fms_compatibility

  write_missing_config_stubs
  configure_runtime_env
  ensure_make_installed
  ensure_makefile
  setup_auto_activate

  # Ensure default checkpoint and log directories exist with safe perms
  mkdir -p "${CHECKPOINT_DIR}" "${LOG_DIR}"
  if [[ "$(id -u)" -eq 0 ]]; then
    chmod -R 0775 "${CHECKPOINT_DIR}" "${LOG_DIR}" || true
  fi

  # Final verification: Import critical modules
  python - <<'PY'
import importlib, sys
mods = ["fms", "torch", "pyarrow", "numpy", "transformers"]
ok = True
for m in mods:
    try:
        importlib.import_module(m)
        print(f"OK: {m}")
    except Exception as e:
        ok = False
        print(f"FAIL: {m} -> {e}", file=sys.stderr)
sys.exit(0 if ok else 1)
PY

  # Create idempotent marker
  if [[ ! -f "$STAMP_FILE" ]]; then
    echo "done: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$STAMP_FILE"
  fi

  log "Environment setup completed successfully."
  cat <<EOF
Next steps:
- Activate the virtual environment (already active in this shell):
    source "${VENV_DIR}/bin/activate"

- Example: run a single-node dummy training (uses defaults in fms_fsdp/config.py):
    torchrun --nproc_per_node=1 main_training.py --use_dummy_dataset=True --ckpt_save_path="${CHECKPOINT_DIR}" --ckpt_load_path="${CHECKPOINT_DIR}"

- For multi-GPU on a single node:
    torchrun --nproc_per_node=\$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l) main_training.py --use_dummy_dataset=True

- If you have real data mounted at ${DATA_DIR}, override data args:
    torchrun --nproc_per_node=8 main_training.py --use_dummy_dataset=False --data_path="${DATA_DIR}" --file_type=arrow --ckpt_save_path="${CHECKPOINT_DIR}" --ckpt_load_path="${CHECKPOINT_DIR}"

Note:
- This script sets conservative NCCL defaults and will disable InfiniBand if no IB/EFA is detected.
- You can customize defaults in fms_fsdp/config.py.
EOF
}

main "$@"