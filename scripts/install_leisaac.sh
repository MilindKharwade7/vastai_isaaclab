#!/usr/bin/env bash
# =============================================================================
#  install_leisaac.sh -- automated installer for LeIsaac (Lightwheel AI)
#
#  Implements every step of the official guide:
#  https://lightwheelai.github.io/leisaac/docs/getting_started/installation/
#
#   1. Environment setup    : conda env "leisaac" (python 3.11)
#                             + `conda install -c nvidia/label/cuda-12.8.1 cuda-toolkit`
#   2. PyTorch              : torch==2.7.0 / torchvision==0.22.0 (cu128 wheels)
#   3a. Install from source : git clone --recursive; isaacsim[all,extscache]==5.1.0;
#                             apt cmake build-essential; ./isaaclab.sh --install;
#                             pip install -e source/leisaac
#   3b. Install as package  : pip install 'leisaac[isaaclab] @ git+...#subdirectory=source/leisaac'
#   4. [Optional] LeRobot   : pip install "source/leisaac[lerobot]" + numpy==1.26.0
#   5. Asset preparation    : so101_follower.usd + <scene>/ downloaded into ./assets
#   6. Verification         : headless `python scripts/environments/list_envs.py`
#
#  Examples
#    ./install_leisaac.sh                          # source install + kitchen scene + verify
#    ./install_leisaac.sh --mode package
#    ./install_leisaac.sh --scenes all --with-lerobot
#    ./install_leisaac.sh --no-verify --repo-dir /root/leisaac
#
#  Notes
#    * Every step is idempotent: re-running the script skips finished work.
#    * The whole run can take a long time (IsaacSim + extension caches are ~10+ GB).
#      Run it in the background and follow the log, e.g.:
#        nohup ./install_leisaac.sh > install.log 2>&1 &
#        tail -f install.log
#    * A pip constraints file (${WORKDIR}/leisaac-pip-constraints.txt) is generated
#      and exported as PIP_CONSTRAINT to keep the documented IsaacSim 5.1 /
#      torch 2.7.0+cu128 stack intact (see setup_pip_constraints below).
# =============================================================================
set -Eeuo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# ----------------------------------------------------------- configurable vars
ENV_NAME="${LEISAAC_ENV_NAME:-leisaac}"                 # conda environment name
MODE="source"                                           # source | package
WORKDIR="${LEISAAC_WORKDIR:-$HOME}"                     # where repo/logs live
REPO_DIR=""                                             # default: $WORKDIR/leisaac
MINICONDA_DIR="${LEISAAC_MINICONDA_DIR:-/opt/miniconda3}"
PY_VERSION="3.11"
CUDA_LABEL="nvidia/label/cuda-12.8.1"
TORCH_VERSION="2.7.0"
TORCHVISION_VERSION="0.22.0"
TORCH_INDEX_URL="https://download.pytorch.org/whl/cu128"
ISAACSIM_VERSION="5.1.0"
NVIDIA_INDEX_URL="https://pypi.nvidia.com"
LEISAAC_REPO_URL="https://github.com/LightwheelAI/leisaac.git"
HF_REPO="LightwheelAI/leisaac_env"
SCENES="kitchen_with_orange"                            # comma separated, or "all"
WITH_LEROBOT=0
WITH_ASSETS=1
WITH_APT=1
DO_VERIFY=1
DO_CUDA_TOOLKIT=1
NO_CONDA_INIT=0
SKIP_PREFLIGHT=0
CLEAN=0
DRY_RUN=0
LOG_FILE=""
CONSTRAINTS_FILE=""

SUDO=""
PIP_ARGS=(--retries 5 --timeout 120)

# Scene zips published as GitHub release assets (file name == scene dir).
declare -A SCENE_ZIP_URLS=(
  [kitchen_with_orange]="https://github.com/LightwheelAI/leisaac/releases/download/v0.1.0/kitchen_with_orange.zip"
  [table_with_cube]="https://github.com/LightwheelAI/leisaac/releases/download/v0.1.2/table_with_cube.zip"
)
# Robot USD files published as GitHub release assets.
declare -A ROBOT_URLS=(
  [so101_follower.usd]="https://github.com/LightwheelAI/leisaac/releases/download/v0.1.0/so101_follower.usd"
)
ALL_SCENES=(kitchen_with_orange table_with_cube)

# ------------------------------------------------------------------- utilities
log()  { printf '\033[1;34m[%s][INFO ]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s][WARN ]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
err()  { printf '\033[1;31m[%s][ERROR]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n\033[1;32m===== %s =====\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

on_error() {
  local code=$1 line=$2
  err "command failed (exit ${code}) at ${SCRIPT_NAME} line ${line}"
  [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] && err "full log: ${LOG_FILE}"
  exit "$code"
}
trap 'on_error $? $LINENO' ERR

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] $*"
    return 0
  fi
  log "\$ $*"
  "$@"
}

usage() {
  cat <<EOF
${SCRIPT_NAME} -- install LeIsaac following the official installation guide.

Usage: ${SCRIPT_NAME} [options]

Options:
  --mode source|package   "source" (default) or "package" install workflow.
  --repo-dir DIR          Where to clone/expect the leisaac repository
                          (default: \$HOME/leisaac).
  --workdir DIR           Working directory for downloads (default: \$HOME).
  --env-name NAME         Conda environment name (default: ${ENV_NAME}).
  --miniconda-dir DIR     Where Miniconda is (or will be) installed
                          (default: ${MINICONDA_DIR}).
  --scenes LIST           Comma separated scenes to download, or "all".
                          Known: ${ALL_SCENES[*]} (any other directory of
                          ${HF_REPO} works too, e.g. lightwheel_toyroom).
                          Default: ${SCENES}
  --with-lerobot          Also install the optional LeRobot integration
                          (and pin numpy==1.26.0).
  --no-assets             Skip scene/robot asset download.
  --no-apt                Skip apt package installation.
  --no-cuda-toolkit       Skip the conda cuda-toolkit step.
  --no-verify             Skip the headless verification run.
  --no-preflight          Skip preflight checks.
  --no-conda-init         Do not run 'conda init' (conda stays off PATH;
                          activate with:
                          source <miniconda>/etc/profile.d/conda.sh).
  --clean                 Remove the conda env before installing.
  --dry-run               Print commands instead of executing them.
  --help                  Show this help.

Environment variables: LEISAAC_ENV_NAME, LEISAAC_WORKDIR,
                       LEISAAC_MINICONDA_DIR, LEISAAC_ASSETS_ROOT,
                       LOG_FILE, ACCEPT_EULA
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)            MODE="${2:?--mode needs a value}"; shift 2 ;;
      --mode=*)          MODE="${1#*=}"; shift ;;
      --repo-dir)        REPO_DIR="${2:?--repo-dir needs a value}"; shift 2 ;;
      --repo-dir=*)      REPO_DIR="${1#*=}"; shift ;;
      --workdir)         WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
      --workdir=*)       WORKDIR="${1#*=}"; shift ;;
      --env-name)        ENV_NAME="${2:?--env-name needs a value}"; shift 2 ;;
      --env-name=*)      ENV_NAME="${1#*=}"; shift ;;
      --miniconda-dir)   MINICONDA_DIR="${2:?--miniconda-dir needs a value}"; shift 2 ;;
      --miniconda-dir=*) MINICONDA_DIR="${1#*=}"; shift ;;
      --scenes)          SCENES="${2:?--scenes needs a value}"; shift 2 ;;
      --scenes=*)        SCENES="${1#*=}"; shift ;;
      --with-lerobot)    WITH_LEROBOT=1; shift ;;
      --no-assets)       WITH_ASSETS=0; shift ;;
      --no-apt)          WITH_APT=0; shift ;;
      --no-cuda-toolkit) DO_CUDA_TOOLKIT=0; shift ;;
      --no-verify)       DO_VERIFY=0; shift ;;
      --no-preflight)    SKIP_PREFLIGHT=1; shift ;;
      --no-conda-init)   NO_CONDA_INIT=1; shift ;;
      --clean)           CLEAN=1; shift ;;
      --dry-run)         DRY_RUN=1; shift ;;
      --help|-h)         usage; exit 0 ;;
      *)                 err "unknown option: $1"; usage; exit 2 ;;
    esac
  done

  [[ "$MODE" == "source" || "$MODE" == "package" ]] || die "--mode must be 'source' or 'package' (got '${MODE}')"
  REPO_DIR="${REPO_DIR:-$WORKDIR/leisaac}"
  WORKDIR="$(cd "$WORKDIR" 2>/dev/null && pwd -P || printf '%s' "$WORKDIR")"
  [[ "$SCENES" == "all" ]] && SCENES="$(IFS=, ; echo "${ALL_SCENES[*]}")"

  # root vs. sudo for apt and /opt writes
  if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; elif have sudo; then SUDO="sudo"; else SUDO=""; fi

  # Isaac Sim refuses to start non-interactively without an accepted EULA.
  export ACCEPT_EULA="${ACCEPT_EULA:-Y}"
  export OMNI_KIT_ACCEPT_EULA="${OMNI_KIT_ACCEPT_EULA:-YES}"
  export PIP_DISABLE_PIP_VERSION_CHECK=1
}

# ----------------------------------------------------------------- conda helpers
CONDA_BIN=""
CONDA_SH=""

activate_env() {
  CONDA_BIN="${MINICONDA_DIR}/bin/conda"
  CONDA_SH="${MINICONDA_DIR}/etc/profile.d/conda.sh"
  if [[ $DRY_RUN -eq 1 && ! -x "$CONDA_BIN" ]]; then
    log "[dry-run] conda not installed yet -- skipping activation"
    return 0
  fi
  [[ -x "$CONDA_BIN" ]] || die "conda not found at ${CONDA_BIN}"

  # conda's activation scripts are not `set -u` safe.
  set +u
  # shellcheck disable=SC1090
  source "$CONDA_SH"
  conda activate "$ENV_NAME"
  set -u

  [[ "${CONDA_DEFAULT_ENV:-}" == "$ENV_NAME" ]] || die "failed to activate conda env '${ENV_NAME}'"
  export LEISAAC_CONDA_ENV="$ENV_NAME"
  log "activated conda env '${ENV_NAME}' -> $(command -v python) ($(python -V 2>&1))"
}

conda_env_exists() {
  [[ -x "$CONDA_BIN" ]] || return 1
  "$CONDA_BIN" env list | awk '{print $1}' | grep -qx "$ENV_NAME"
}

# Run conda with `nounset` temporarily disabled.
#
# `conda.sh` wraps the `conda` executable in a shell function that re-sources
# the environment's activate.d scripts *in the current shell* after
# install/update/remove. Several packages ship activate scripts that are not
# `set -u` safe (e.g. cuda-nvcc does `${NVCC_PREPEND_FLAGS} ...`), which would
# abort this script, so `-u` is switched off for the duration of the call.
conda_run() {
  local had_u=0 rc=0
  [[ "$-" == *u* ]] && had_u=1
  set +u
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] conda $*"
  else
    log "\$ conda $*"
    conda "$@"
    rc=$?
  fi
  [[ $had_u -eq 1 ]] && set -u
  return $rc
}

pip_install() { run pip install "${PIP_ARGS[@]}" "$@"; }

# --------------------------------------------------------- pip constraints
# The IsaacLab extensions are installed through pip and pull optional
# dependencies from PyPI. Two of them break the (documented) IsaacSim 5.1 stack:
#   * stable-baselines3 >= 2.9 requires torch>=2.8, so pip "helpfully" replaces
#     the cu128 torch 2.7.0 build with a new torch plus CUDA-13 PyPI wheels
#     (observed: torch 2.14.0 + cuda-toolkit 13.0.3, ~5 GB);
#   * setuptools >= 81 dropped `pkg_resources`, which makes the sdist of
#     `flatdict` (a robomimic dependency) fail to build.
# A pip constraints file fixes both without patching the repo. PIP_CONSTRAINT is
# exported so it is also honoured inside `./isaaclab.sh --install` and inside
# pip's build-isolation environments.
setup_pip_constraints() {
  CONSTRAINTS_FILE="${WORKDIR}/leisaac-pip-constraints.txt"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] would write pip constraints to ${CONSTRAINTS_FILE}"
  else
    mkdir -p "$WORKDIR"
    cat > "$CONSTRAINTS_FILE" <<EOF
# generated by ${SCRIPT_NAME} -- keep the IsaacSim ${ISAACSIM_VERSION} stack intact
setuptools<81
torch==${TORCH_VERSION}
torchvision==${TORCHVISION_VERSION}
stable-baselines3<2.9
EOF
  fi
  export PIP_CONSTRAINT="$CONSTRAINTS_FILE"
  if [[ -f "$CONSTRAINTS_FILE" ]]; then
    log "pip constraints (${CONSTRAINTS_FILE}): $(grep -v '^#' "$CONSTRAINTS_FILE" | tr '\n' ' ')"
  fi
}

# ------------------------------------------------------------------- step 0/1
preflight() {
  [[ $SKIP_PREFLIGHT -eq 1 ]] && return 0
  step "Preflight checks"

  [[ "$(uname -s)" == "Linux" ]] || die "this installer targets Linux (found $(uname -s))"
  [[ "$(uname -m)" == "x86_64" ]] || die "x86_64 is required (found $(uname -m))"

  mkdir -p "$WORKDIR"
  local free_gb
  free_gb=$(df -Pk "$WORKDIR" | awk 'NR==2 {printf "%d", $4/1048576}')
  log "free disk space on ${WORKDIR}: ${free_gb} GB"
  if (( free_gb < 40 )); then
    warn "less than 40 GB free -- IsaacSim + extension caches + PyTorch need a lot of space"
  fi

  if have nvidia-smi; then
    local gpu driver cc
    gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
    cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n1 | tr -d ' ')
    log "GPU: ${gpu} (driver ${driver}, compute capability ${cc})"
    if [[ "${cc%%.*}" -ge 12 ]]; then
      log "50-series / Blackwell GPU detected: IsaacSim ${ISAACSIM_VERSION} + IsaacLab 2.3.0 (cu128) is the recommended stack"
    fi
    if awk "BEGIN{exit !(${driver} < 525)}"; then
      warn "NVIDIA driver ${driver} is older than 525 -- CUDA 12.8 wheels may not load"
    fi
  else
    warn "nvidia-smi not found -- IsaacSim needs an NVIDIA GPU with a recent driver"
  fi

  local url
  for url in "https://github.com" "https://pypi.org/simple/" "$NVIDIA_INDEX_URL" \
             "https://repo.anaconda.com/miniconda/"; do
    if curl -fsS -o /dev/null -m 20 "$url"; then
      log "network OK : ${url}"
    else
      warn "network FAILED: ${url}"
    fi
  done
}

install_miniconda() {
  step "Step 1a: conda"
  if [[ -x "${MINICONDA_DIR}/bin/conda" ]]; then
    log "conda already present at ${MINICONDA_DIR} ($("${MINICONDA_DIR}/bin/conda" --version))"
  else
    local installer="${WORKDIR}/miniconda.sh"
    if [[ $DRY_RUN -eq 1 ]]; then
      log "[dry-run] would install Miniconda into ${MINICONDA_DIR}"
    else
      mkdir -p "$(dirname "$MINICONDA_DIR")"
      run curl -fL --retry 3 --retry-delay 5 -o "$installer" \
        "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
      run bash "$installer" -b -p "$MINICONDA_DIR"
      rm -f "$installer"
    fi
  fi

  CONDA_BIN="${MINICONDA_DIR}/bin/conda"
  if [[ $DRY_RUN -eq 0 ]]; then
    # Newer conda versions require an explicit ToS acceptance for the default channels.
    if "$CONDA_BIN" tos --help >/dev/null 2>&1; then
      "$CONDA_BIN" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
      "$CONDA_BIN" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true
    fi
  fi
}

create_env() {
  step "Step 1b: conda env '${ENV_NAME}' (python ${PY_VERSION})"
  if [[ $CLEAN -eq 1 && $DRY_RUN -eq 0 && -x "$CONDA_BIN" ]]; then
    if conda_env_exists; then
      log "removing existing env '${ENV_NAME}' (--clean)"
      conda_run env remove -y -n "$ENV_NAME"
    fi
  fi

  if conda_env_exists; then
    log "env '${ENV_NAME}' already exists -- skipping creation"
  else
    conda_run create -y -n "$ENV_NAME" "python=${PY_VERSION}"
  fi
  activate_env
}

install_cuda_toolkit() {
  step "Step 1c: cuda-toolkit (conda channel '${CUDA_LABEL}')"
  if [[ $DO_CUDA_TOOLKIT -eq 0 ]]; then
    warn "skipped (--no-cuda-toolkit)"
    return 0
  fi
  if [[ $DRY_RUN -eq 0 ]] && have nvcc; then
    log "nvcc already available: $(nvcc --version | tail -n1)"
    return 0
  fi
  # exactly what the guide does; conda-forge provides the remaining deps
  conda_run install -y -c "$CUDA_LABEL" -c conda-forge cuda-toolkit
}

install_torch() {
  step "Step 2: PyTorch ${TORCH_VERSION} / torchvision ${TORCHVISION_VERSION} (cu128)"
  if [[ $DRY_RUN -eq 0 ]]; then
    local installed
    installed="$(python -c 'import torch,sys; sys.stdout.write(torch.__version__)' 2>/dev/null || true)"
    if [[ -n "$installed" ]]; then
      log "torch ${installed} already installed -- skipping (remove it manually to reinstall)"
      return 0
    fi
  fi
  pip_install -U "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" \
    --index-url "$TORCH_INDEX_URL"
}

# ------------------------------------------------ step 3: source-mode helpers
clone_repo() {
  local recursive="$1"
  step "Step 3a: clone ${LEISAAC_REPO_URL} (recursive=${recursive})"
  if [[ -d "${REPO_DIR}/.git" ]]; then
    log "repository already present at ${REPO_DIR} -- updating submodules"
    run git -C "$REPO_DIR" submodule update --init --recursive
    return 0
  fi
  [[ -e "$REPO_DIR" ]] && die "${REPO_DIR} exists but is not a git repository"
  run git clone --depth 1 "$LEISAAC_REPO_URL" "$REPO_DIR"
  if [[ "$recursive" == "yes" ]]; then
    # the pinned IsaacLab commit is required by the source workflow. A shallow
    # submodule fetch only works when the pinned commit is the branch tip, so
    # fall back to a full fetch instead of using `--recursive` on the clone.
    if ! run git -C "$REPO_DIR" submodule update --init --depth 1 --recursive dependencies/IsaacLab; then
      warn "shallow submodule checkout failed -- retrying with full history"
      [[ $DRY_RUN -eq 0 ]] && rm -rf "${REPO_DIR}/.git/modules/dependencies/IsaacLab" "${REPO_DIR}/dependencies/IsaacLab"
      run git -C "$REPO_DIR" submodule update --init --recursive dependencies/IsaacLab
    fi
  fi
  if [[ $DRY_RUN -eq 0 ]]; then
    log "checked out $(git -C "$REPO_DIR" rev-parse --short HEAD) at ${REPO_DIR}"
  fi
}

install_isaacsim() {
  step "Step 3b: isaacsim[all,extscache]==${ISAACSIM_VERSION} (pypi.nvidia.com)"
  if [[ $DRY_RUN -eq 0 ]] && python -c "import isaacsim" >/dev/null 2>&1; then
    log "isaacsim already importable -- skipping"
    return 0
  fi
  run pip install "${PIP_ARGS[@]}" --upgrade pip
  pip_install "isaacsim[all,extscache]==${ISAACSIM_VERSION}" --extra-index-url "$NVIDIA_INDEX_URL"
}

# `isaaclab` (0.47.x, pulled in by leisaac[isaaclab]) depends on
# `flatdict==4.0.1`. That sdist only builds with a setuptools that still ships
# `pkg_resources`, while pip's build isolation always installs the *latest*
# setuptools (PIP_CONSTRAINT is not applied to build environments). The result
# is:
#     ERROR: Failed to build 'flatdict' when getting requirements to build wheel
#     ModuleNotFoundError: No module named 'pkg_resources'
# and, because `isaaclab` imports fail, the whole stack is unusable.
# Installing it with `--no-build-isolation` uses the environment's own
# setuptools (<81, enforced by the constraints file) and builds fine.
preinstall_build_hostile_sdists() {
  step "Step 3d-pre: pre-build sdists that modern setuptools cannot handle"
  local legacy_pins=("flatdict==4.0.1")   # req of isaaclab==0.47.2 / robomimic
  local pin
  for pin in "${legacy_pins[@]}"; do
    local mod="${pin%%==*}"
    if [[ $DRY_RUN -eq 0 ]] && python -c "import ${mod}" >/dev/null 2>&1; then
      log "${mod} already installed -- skipping"
      continue
    fi
    # build backend must be present for --no-build-isolation
    pip_install "setuptools<81" wheel
    run pip install "${PIP_ARGS[@]}" --no-build-isolation "$pin"
  done
}

install_apt_deps() {
  step "Step 3c: apt dependencies (cmake, build-essential, unzip, ...)"
  if [[ $WITH_APT -eq 0 ]]; then
    warn "skipped (--no-apt)"
    return 0
  fi
  local pkgs=(cmake build-essential unzip)
  # runtime libs commonly needed by IsaacSim (headless/EGL) on slim images
  local runtime=(libglu1-mesa libgl1 libegl1 libxrandr2 libxinerama1 libxcursor1
                 libxi6 libxt6 libsm6 libice6 libgomp1 libatomic1 libidn11)
  if have cmake && have make && have g++ && have unzip; then
    log "cmake/make/g++/unzip already installed -- skipping apt"
    return 0
  fi
  run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
  run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  # best effort: some of these may not exist on every distro release
  run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${runtime[@]}" \
    || warn "some optional IsaacSim runtime libraries could not be installed"
}

install_isaaclab() {
  step "Step 3d: IsaacLab (./isaaclab.sh --install)"
  local lab_dir="${REPO_DIR}/dependencies/IsaacLab"
  if [[ $DRY_RUN -eq 0 ]]; then
    [[ -d "$lab_dir" ]] || die "IsaacLab submodule missing at ${lab_dir} (run without --no-recursive clone)"
  fi
  activate_env
  log "IsaacLab version: $(git -C "$lab_dir" describe --tags --always 2>/dev/null || echo unknown)"
  run bash -c "cd '${lab_dir}' && ./isaaclab.sh --install"
}

install_leisaac_source() {
  step "Step 3e: pip install -e source/leisaac"
  if [[ $DRY_RUN -eq 0 ]]; then
    [[ -d "${REPO_DIR}/source/leisaac" ]] || die "missing ${REPO_DIR}/source/leisaac"
  fi
  run pip install "${PIP_ARGS[@]}" -e "${REPO_DIR}/source/leisaac"
}

install_leisaac_package() {
  step "Step 3b(package): pip install 'leisaac[isaaclab] @ git+...'"
  local spec="leisaac[isaaclab] @ git+${LEISAAC_REPO_URL}#subdirectory=source/leisaac"
  run pip install "${PIP_ARGS[@]}" "$spec" --extra-index-url "$NVIDIA_INDEX_URL"
}

# Isaac Sim's Kit kernel refuses to start in a non-interactive shell unless the
# EULA was accepted: `isaacsim/kit/kit_app.py` asks on stdin, and otherwise only
# consults OMNI_KIT_ACCEPT_EULA or an `EULA_ACCEPTED` file next to kit_app.py.
# Persist the acceptance so the documented follow-up commands (list_envs.py,
# teleoperation, datagen, ...) do not block on a terminal prompt.
accept_isaacsim_eula() {
  step "Step 3f: IsaacSim EULA acceptance"
  export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES   # belt and braces
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] would write <isaacsim-package>/kit/EULA_ACCEPTED"
    return 0
  fi
  local kit_dir
  kit_dir="$(python -c 'import os, isaacsim; print(os.path.join(os.path.dirname(os.path.abspath(os.path.realpath(isaacsim.__file__))), "kit"))' 2>/dev/null || true)"
  if [[ -z "$kit_dir" || ! -d "$kit_dir" ]]; then
    warn "could not locate the isaacsim kit directory -- relying on OMNI_KIT_ACCEPT_EULA=YES only"
    return 0
  fi
  local eula_file="${kit_dir}/EULA_ACCEPTED"
  if [[ -f "$eula_file" ]] && grep -qiE '^(y|yes|1)$' "$eula_file"; then
    log "EULA already accepted (${eula_file})"
  else
    printf 'yes\n' > "$eula_file"
    log "wrote EULA acceptance to ${eula_file}"
  fi
}

# Miniconda's `-b` (batch) installer deliberately does NOT touch shell init
# files, so a plain `conda activate ...` in the user's shell fails with
# "conda: command not found". Register the hook for the common shells so the
# env is usable in a new terminal (opt out with --no-conda-init).
init_conda_shell() {
  step "Step 1d: make conda available in the shell"
  if [[ $NO_CONDA_INIT -eq 1 ]]; then
    warn "skipped (--no-conda-init) -- use:  source ${MINICONDA_DIR}/etc/profile.d/conda.sh"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] would run 'conda init bash zsh' (edits ~/.bashrc / ~/.zshrc)"
    return 0
  fi
  local sh
  for sh in bash zsh; do
    "$CONDA_BIN" init "$sh" 2>/dev/null | sed 's/^/    /' || true
  done
  log "conda hook installed; in YOUR current shell run:"
  log "    source ${MINICONDA_DIR}/etc/profile.d/conda.sh && conda activate ${ENV_NAME}"
}

install_lerobot() {
  step "Step 4: [optional] LeRobot integration"
  if [[ $WITH_LEROBOT -eq 0 ]]; then
    log "skipped (enable with --with-lerobot)"
    return 0
  fi
  if [[ "$MODE" == "source" ]]; then
    run pip install "${PIP_ARGS[@]}" -e "${REPO_DIR}/source/leisaac[lerobot]"
  else
    run pip install "${PIP_ARGS[@]}" \
      "leisaac[lerobot] @ git+${LEISAAC_REPO_URL}#subdirectory=source/leisaac"
  fi
  # numpy pin as documented by the guide
  pip_install "numpy==1.26.0"
}

# ---------------------------------------------------- step 5: asset preparation
download_file() {
  local url="$1" dest="$2" tmp="${2}.part"
  run mkdir -p "$(dirname "$dest")"
  run curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$tmp" "$url"
  if [[ $DRY_RUN -eq 0 ]]; then mv -f "$tmp" "$dest"; fi
}

ensure_hf_cli() {
  have hf && return 0
  pip_install huggingface_hub
}

download_scene() {
  local name="$1"
  local dest="${ASSETS_DIR}/scenes/${name}"
  if [[ -f "${dest}/scene.usd" || -f "${dest}/LW_Loft.usd" ]]; then
    log "scene '${name}' already present -- skipping"
    return 0
  fi

  if [[ -n "${SCENE_ZIP_URLS[$name]:-}" ]]; then
    local zip="${WORKDIR}/${name}.zip"
    log "downloading scene '${name}' from GitHub Releases"
    download_file "${SCENE_ZIP_URLS[$name]}" "$zip"
    run mkdir -p "${ASSETS_DIR}/scenes"
    run unzip -q -o "$zip" -d "${ASSETS_DIR}/scenes"
    [[ $DRY_RUN -eq 0 ]] && rm -f "$zip"
  else
    log "scene '${name}' not on GitHub Releases -- pulling it from HuggingFace (${HF_REPO})"
    ensure_hf_cli
    local tmp="${WORKDIR}/.hf_download"
    run rm -rf "$tmp"
    run mkdir -p "$tmp"
    run hf download "$HF_REPO" --include "assets/scenes/${name}/*" --local-dir "$tmp"
    run mkdir -p "${ASSETS_DIR}/scenes"
    if [[ -d "${tmp}/assets/scenes/${name}" ]]; then
      run rm -rf "$dest"
      run mv "${tmp}/assets/scenes/${name}" "$dest"
    else
      warn "could not find assets/scenes/${name} in ${HF_REPO}"
    fi
    run rm -rf "$tmp"
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    if [[ -d "$dest" ]]; then
      log "scene '${name}' ready at ${dest} ($(du -sh "$dest" | cut -f1))"
    else
      warn "scene '${name}' was not extracted to ${dest}"
    fi
  fi
}

download_robot() {
  local name="$1"
  local dest="${ASSETS_DIR}/robots/${name}"
  if [[ -f "$dest" ]]; then
    log "robot asset '${name}' already present -- skipping"
    return 0
  fi

  if [[ -n "${ROBOT_URLS[$name]:-}" ]]; then
    download_file "${ROBOT_URLS[$name]}" "$dest"
  else
    ensure_hf_cli
    local tmp="${WORKDIR}/.hf_download"
    run rm -rf "$tmp"
    run mkdir -p "$tmp"
    run hf download "$HF_REPO" --include "assets/robots/${name}" --local-dir "$tmp"
    run mkdir -p "${ASSETS_DIR}/robots"
    [[ -f "${tmp}/assets/robots/${name}" ]] && run mv "${tmp}/assets/robots/${name}" "$dest"
    run rm -rf "$tmp"
  fi
  [[ -f "$dest" ]] || warn "robot asset '${name}' could not be downloaded"
}

fetch_assets() {
  step "Step 5: asset preparation"
  if [[ $WITH_ASSETS -eq 0 ]]; then
    warn "skipped (--no-assets)"
    return 0
  fi
  [[ -n "$REPO_DIR" ]] || die "REPO_DIR is not set"
  ASSETS_DIR="${LEISAAC_ASSETS_ROOT:-${REPO_DIR}/assets}"
  log "assets directory: ${ASSETS_DIR}"
  run mkdir -p "${ASSETS_DIR}/scenes" "${ASSETS_DIR}/robots"

  download_robot "so101_follower.usd"

  local s
  for s in ${SCENES//,/ }; do
    [[ -n "$s" ]] || continue
    download_scene "$s"
  done

  if [[ $DRY_RUN -eq 0 ]]; then
    log "assets tree (2 levels):"
    ( cd "$ASSETS_DIR" && find . -maxdepth 2 -mindepth 1 | sort | sed 's/^/    /' ) || true
  fi
}

# ------------------------------------------------------------ step 6: verify
verify_install() {
  step "Step 6: verification"
  if [[ $DO_VERIFY -eq 0 ]]; then
    warn "skipped (--no-verify)"
    return 0
  fi
  [[ $DRY_RUN -eq 1 ]] && { log "[dry-run] skipping verification"; return 0; }

  activate_env
  # Isaac Sim needs a writable home/cache and a non-interactive EULA acceptance
  export HOME="${HOME:-/root}"

  log "python: $(python -V 2>&1) at $(command -v python)"
  local mod
  for mod in torch isaacsim isaaclab leisaac; do
    if python -c "import ${mod}" >/dev/null 2>&1; then
      log "import ${mod}: OK"
    else
      warn "import ${mod}: FAILED"
    fi
  done

  # torch must stay on the cu128 2.7.0 build documented for IsaacSim 5.1
  local torch_ver
  torch_ver="$(python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo missing)"
  if [[ "$torch_ver" == "${TORCH_VERSION}+cu128" ]]; then
    log "torch version: ${torch_ver} (as documented)"
  else
    warn "torch version is ${torch_ver}, expected ${TORCH_VERSION}+cu128"
  fi

  if python -c "import torch; assert torch.cuda.is_available(), 'CUDA not available'" >/dev/null 2>&1; then
    log "torch CUDA: OK ($(python -c 'import torch;print(torch.cuda.get_device_name(0))'))"
  else
    warn "torch CUDA is not available -- check the NVIDIA driver / conda cuda-toolkit"
  fi

  # report dependency inconsistencies without failing the install
  local check_out="" check_rc=0
  check_out="$(python -m pip check 2>&1)" || check_rc=$?
  if [[ $check_rc -eq 0 && -z "$check_out" ]]; then
    log "pip check: no broken requirements"
  else
    warn "pip check reported broken requirements:"
    printf '%s\n' "$check_out" | sed 's/^/    /' >&2
  fi

  local list_envs="${REPO_DIR}/scripts/environments/list_envs.py"
  if [[ -f "$list_envs" ]]; then
    log "launching Isaac Sim headless to list the LeIsaac environments (this can take a few minutes)"
    # Note: list_envs.py imports omni inside Isaac Sim and closes the app via
    # `finally`, so task registration must happen in-process (plain
    # `python -c 'import gymnasium, leisaac.tasks'` cannot work without the sim).
    if run bash -c "cd '${REPO_DIR}' && python -u scripts/environments/list_envs.py"; then
      log "verification succeeded"
    else
      warn "list_envs.py failed -- see the log above (falls back to import checks)"
    fi
  else
    warn "scripts/environments/list_envs.py not found in ${REPO_DIR}"
  fi
}

# ------------------------------------------------------------------- summary
summary() {
  step "Done"
  cat <<EOF

LeIsaac installation finished.

  conda env    : ${ENV_NAME}   (${MINICONDA_DIR})
  activate     : conda activate ${ENV_NAME}        (new shell; 'conda init' ran)
                   - or, in a shell opened BEFORE this install:
                   source ${MINICONDA_DIR}/etc/profile.d/conda.sh && conda activate ${ENV_NAME}
  mode         : ${MODE}
  repository   : ${REPO_DIR}
  assets       : ${REPO_DIR}/assets
  LeRobot      : $([[ $WITH_LEROBOT -eq 1 ]] && echo installed || echo "not installed (--with-lerobot)")

Next steps (run from ${REPO_DIR}, inside the conda env):

  # list registered LeIsaac tasks (headless)
  python scripts/environments/list_envs.py

  # teleoperate with a SO101 leader (needs the USB device)
  python scripts/environments/teleoperation/teleop_se3_agent.py --task=LeIsaac-SO101-PickOrange-v0 --teleop_device=so101leader

  # headless smoke test of a scene
  python scripts/environments/list_envs.py --headless

Troubleshooting:
  * Isaac Sim blocks on 'Do you accept the EULA?' ->
        export OMNI_KIT_ACCEPT_EULA=YES
    (this installer already writes <isaacsim>/kit/EULA_ACCEPTED for you)
  * libstdc++.so.6: version 'GLIBCXX_3.4.30' not found ->
        conda install -c conda-forge gcc=12 -y
  * Qt/EGL errors in a headless container ->
        export DISPLAY= ; or use --headless
  * \`pip check\` may list conflicts coming from IsaacLab/IsaacSim's own pins
    (packaging/click/idna/psutil) -- these are upstream and harmless here
  * different GPU / IsaacSim version -> adjust the version table in
    https://lightwheelai.github.io/leisaac/docs/getting_started/installation/
EOF
}

# ---------------------------------------------------------------------- main
main() {
  parse_args "$@"
  LOG_FILE="${LOG_FILE:-}"

  log "${SCRIPT_NAME}: LeIsaac installer (mode=${MODE}, env=${ENV_NAME}, repo=${REPO_DIR})"

  setup_pip_constraints
  preflight
  install_miniconda
  create_env
  install_cuda_toolkit
  init_conda_shell
  install_torch

  if [[ "$MODE" == "source" ]]; then
    clone_repo yes
    install_isaacsim
    install_apt_deps
    preinstall_build_hostile_sdists
    install_isaaclab
    install_leisaac_source
  else
    preinstall_build_hostile_sdists
    install_leisaac_package
    # scripts/ and assets/ only exist in the repository
    clone_repo no
    install_apt_deps
  fi

  install_lerobot
  accept_isaacsim_eula
  fetch_assets
  verify_install
  summary
}

main "$@"
