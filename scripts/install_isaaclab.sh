#!/bin/bash
# =============================================================================
# install_isaaclab.sh - installs NVIDIA Isaac Lab next to the Isaac Sim build
#                       this machine already has, following the official guide
#
#     https://isaac-sim.github.io/IsaacLab/main/source/deployment/docker.html
#
# That page is a *Docker* guide: clone IsaacLab, build docker/Dockerfile.base on
# top of the nvcr.io/nvidia/isaac-sim image, then run it with docker/container.py
# and docker-compose.yaml (it also documents the pre-built
# nvcr.io/nvidia/isaac-lab image).  This machine can be in either of two states,
# so the script has two modes:
#
#   --mode docker   A real host with Docker.  Exactly the guide: clone the repo,
#                   optionally pin ISAACSIM_VERSION in docker/.env.base, then
#                   `./isaaclab.sh -o start` (= docker/container.py start), which
#                   builds the image and starts the container with the mounts
#                   from docker-compose.yaml.
#
#   --mode native   No Docker daemon is reachable - which is the case inside a
#                   Vast.ai instance, where we are ALREADY inside the Isaac Sim
#                   container (/.dockerenv exists, there is no docker CLI).  The
#                   steps docker/Dockerfile.base performs at image build time are
#                   performed here instead:
#                     * the Dockerfile's apt package list
#                     * the checkout at DOCKER_ISAACLAB_PATH (/workspace/isaaclab)
#                     * the `_isaac_sim` symlink to the Isaac Sim root
#                     * `isaaclab.sh -p -m pip install toml`
#                     * `isaaclab.sh -p tools/install_deps.py apt <source>`
#                     * every directory docker-compose.yaml bind-mounts
#                     * `isaaclab.sh --install <target>`
#                     * the Dockerfile's `pip uninstall -y quadprog` workaround
#                     * the .bashrc ISAACLAB_PATH / alias block
#
# Isaac Sim <-> Isaac Lab compatibility (IsaacLab README, "Isaac Sim Version
# Dependency").  Getting this wrong is the #1 reason for a broken install:
#     main                    -> Isaac Sim 4.5 / 5.0 / 5.1   (python 3.11)
#     v2.3.X                  -> Isaac Sim 4.5 / 5.0 / 5.1
#     v3.0.0-beta2, .patch1   -> Isaac Sim 6.0.x             (python 3.12)
#     release/3.0.0, develop  -> Isaac Sim 6.1.x             (python 3.12)
# The ref is therefore DETECTED from $ISAACSIM_ROOT_PATH/VERSION; use --ref to
# override it.
#
# On the newer revisions (Isaac Lab 3.x) every `isaaclab.sh` call prints
#     [WARNING] _isaac_sim is present but _isaac_sim/setup_conda_env.sh is missing
# That warning is harmless here: setup_conda_env.sh only exists in the Isaac Sim
# conda/binary zip, while in this container the equivalent environment setup is
# what /isaac-sim/python.sh does, and isaaclab.sh falls back to it.
#
# Every step is idempotent (a re-run only redoes what is really missing), each
# step reports success or failure, and the exit status is non-zero if anything
# failed.  Output is appended to /var/log/isaaclab_install.log.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive
set -o pipefail
# --- configuration ----------------------------------------------------------
ISAACLAB_REPO_URL="${ISAACLAB_REPO_URL:-https://github.com/isaac-sim/IsaacLab.git}"
ISAACLAB_PATH="${ISAACLAB_PATH:-/workspace/isaaclab}"    # DOCKER_ISAACLAB_PATH in docker/.env.base
ISAACSIM_ROOT_PATH="${ISAACSIM_ROOT_PATH:-/isaac-sim}"    # DOCKER_ISAACSIM_ROOT_PATH
DOCKER_USER_HOME="${DOCKER_USER_HOME:-${HOME:-/root}}"    # DOCKER_USER_HOME
ISAACLAB_REF="${ISAACLAB_REF:-}"                          # empty -> detect from the Isaac Sim version
ISAACLAB_INSTALL_TARGET="${ISAACLAB_INSTALL_TARGET:-all}"  # 'all', 'core', 'rl[rsl-rl]', ...
MODE="${MODE:-auto}"                                      # auto | native | docker
DOCKER_PROFILE="${DOCKER_PROFILE:-base}"                  # base | ros2
SIM_VERSION_OVERRIDE=""                                   # --sim-version (docker mode)
INSTALL_BASHRC="${INSTALL_BASHRC:-1}"
RUN_SMOKE_TEST="${RUN_SMOKE_TEST:-1}"
SKIP_APT="${SKIP_APT:-0}"
FORCE="${FORCE:-0}"
DRY_RUN=0
CHECK_ONLY=0
LOG_FILE="${LOG_FILE:-/var/log/isaaclab_install.log}"
MARKER_FILE=""                                            # set once ISAACLAB_PATH is final
BASHRC_MARKER_BEGIN="# >>> isaaclab (install_isaaclab.sh) >>>"
BASHRC_MARKER_END="# <<< isaaclab (install_isaaclab.sh) <<<"
# The container images refuse to start without these; docker/.env.base ships
# ACCEPT_EULA=Y, and docker-compose.yaml sets OMNI_KIT_ALLOW_ROOT=1 (Kit cannot
# run as root without it).
export ACCEPT_EULA="${ACCEPT_EULA:-Y}"
export PRIVACY_CONSENT="${PRIVACY_CONSENT:-Y}"
export OMNI_KIT_ALLOW_ROOT="${OMNI_KIT_ALLOW_ROOT:-1}"
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
usage: $(basename "$0") [options]

Installs Isaac Lab, following
  https://isaac-sim.github.io/IsaacLab/main/source/deployment/docker.html

options:
  --mode auto|native|docker  auto (default): docker if a daemon answers, else native
  --path DIR                 Isaac Lab checkout (default: $ISAACLAB_PATH)
  --ref REF                  Isaac Lab git ref; default: detected from Isaac Sim
  --install-target TARGET    'all' (default), 'core' or e.g. 'rl[rsl-rl]'
  --sim-version VERSION      docker mode: pin ISAACSIM_VERSION in docker/.env.base
  --profile base|ros2        docker mode: compose profile (default: base)
  --log FILE                 log file (default: $LOG_FILE)
  --no-bashrc                do not touch ~/.bashrc
  --no-smoke-test            skip the log_time.py --headless check
  --skip-apt                 do not install the apt packages
  --force                    install even if it looks already installed
  --check                    run the pre-flight checks and exit
  --dry-run                  print the commands instead of running them
  -h, --help                 this text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)           MODE="$2"; shift 2 ;;
        --path)           ISAACLAB_PATH="$2"; shift 2 ;;
        --ref)            ISAACLAB_REF="$2"; shift 2 ;;
        --install-target) ISAACLAB_INSTALL_TARGET="$2"; shift 2 ;;
        --sim-version)    SIM_VERSION_OVERRIDE="$2"; shift 2 ;;
        --profile)        DOCKER_PROFILE="$2"; shift 2 ;;
        --log)            LOG_FILE="$2"; shift 2 ;;
        --no-bashrc)      INSTALL_BASHRC=0; shift ;;
        --no-smoke-test)  RUN_SMOKE_TEST=0; shift ;;
        --skip-apt)       SKIP_APT=1; shift ;;
        --force)          FORCE=1; shift ;;
        --check)          CHECK_ONLY=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage; echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# --- helpers ----------------------------------------------------------------
FAILED=0
fail() { echo "!!! ERROR: $*"; FAILED=$((FAILED + 1)); }
warn() { echo "!!! WARNING: $*"; }

have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }

# resolve_pkg <name>... -> print the first name that exists in the configured
# repositories.  Needed because package names change between Ubuntu releases
# (libglib2.0-0 -> libglib2.0-0t64, ...).  docker/Dockerfile.base still asks for
# libglib2.0-0, which has no candidate on Ubuntu 24.04.
resolve_pkg() {
    local p
    for p in "$@"; do
        if apt-cache show "$p" >/dev/null 2>&1; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# run <cmd...> - honours --dry-run
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '    [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

# il <isaaclab.sh args...> - run ./isaaclab.sh from inside the checkout, the way
# the guide does (its own path detection needs the working directory / symlink)
il() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '    [dry-run] (cd %s && ./isaaclab.sh %s)\n' "$ISAACLAB_PATH" "$*"
        return 0
    fi
    ( cd "$ISAACLAB_PATH" && ./isaaclab.sh "$@" )
}

# --- logging + banner -------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
if touch "$LOG_FILE" 2>/dev/null; then
    exec > >(tee -a "$LOG_FILE") 2>&1
else
    echo "!!! WARNING: cannot write $LOG_FILE - logging to stdout only"
fi

echo
echo "###############################################################"
echo "### install_isaaclab.sh started at $(date)"
echo "### host: $(hostname)  user: $(id -un)  PWD: $PWD"
echo "### Isaac Lab path: $ISAACLAB_PATH"
echo "###############################################################"

# --- detection --------------------------------------------------------------
detect_isaacsim_version() {
    local vf="${ISAACSIM_ROOT_PATH}/VERSION"
    [ -f "$vf" ] || return 1
    head -n1 "$vf" | tr -d '\r\n'
}

# default_ref_for_version <isaac sim version> -> the Isaac Lab ref that matches
# it, per the compatibility table in the IsaacLab README.
default_ref_for_version() {
    case "$1" in
        6.0*)      echo "v3.0.0-beta2.patch1" ;;
        6.1*|6.2*) echo "release/3.0.0" ;;
        *)         echo "main" ;;
    esac
}

have_docker() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1 || return 1
    return 0
}

isaacsim_python() { echo "${ISAACSIM_ROOT_PATH}/python.sh"; }

# --- pre-flight -------------------------------------------------------------
# Read-only checks.  Anything reported here as an error is fatal: installing
# Isaac Lab against a broken/absent Isaac Sim just wastes an hour of downloads.
preflight() {
    echo
    echo "=== 1. Pre-flight checks ==="

    ISAACSIM_VERSION="$(detect_isaacsim_version)" || ISAACSIM_VERSION=""
    if [ -n "$ISAACSIM_VERSION" ]; then
        echo "    Isaac Sim     : $ISAACSIM_VERSION   ($ISAACSIM_ROOT_PATH)"
    else
        warn "cannot read $ISAACSIM_ROOT_PATH/VERSION - is Isaac Sim installed here?"
    fi

    if [ -n "$ISAACLAB_REF" ]; then
        echo "    Isaac Lab ref : $ISAACLAB_REF   (--ref)"
    else
        ISAACLAB_REF="$(default_ref_for_version "${ISAACSIM_VERSION:-unknown}")"
        echo "    Isaac Lab ref : $ISAACLAB_REF   (matched to Isaac Sim ${ISAACSIM_VERSION:-unknown})"
    fi

    # Isaac Sim's python is the interpreter Isaac Lab is installed into, and its
    # major.minor version has to match Isaac Lab's (3.11 for Sim 5.x, 3.12 for
    # Sim 6.x) because Isaac Sim is built against one specific python.
    if [ -x "$ISAACSIM_ROOT_PATH/python.sh" ]; then
        local pyver
        pyver="$("$ISAACSIM_ROOT_PATH/python.sh" -c \
            'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null | tail -n1)"
        echo "    python        : ${pyver:-unknown}   ($ISAACSIM_ROOT_PATH/python.sh)"
        case "$pyver" in
            3.11.*) [ "$ISAACLAB_REF" = "main" ] ||
                        warn "python 3.11 goes with 'main'/v2.3.x - check --ref '$ISAACLAB_REF'" ;;
            3.12.*) case "$ISAACLAB_REF" in
                        main) warn "python 3.12 goes with Isaac Sim 6.x, not 'main' - \
see the compatibility table in the header" ;;
                    esac ;;
        esac
    else
        fail "$ISAACSIM_ROOT_PATH/python.sh is missing - Isaac Sim does not look installed"
    fi

    local b
    for b in git curl tar; do
        command -v "$b" >/dev/null 2>&1 || fail "the '$b' command is required but not installed"
    done

    # the clone and every pip download need the network
    if curl -sSf -m 25 -o /dev/null \
        "https://raw.githubusercontent.com/isaac-sim/IsaacLab/${ISAACLAB_REF}/isaaclab.sh" 2>/dev/null
    then
        echo "    network       : OK (github reachable, ref '$ISAACLAB_REF' exists)"
    else
        fail "cannot reach github, or the ref '$ISAACLAB_REF' does not exist"
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "    GPU           : $(nvidia-smi --query-gpu=name,driver_version,memory.total \
            --format=csv,noheader 2>/dev/null | head -n1)"
    else
        warn "nvidia-smi not found - Isaac Sim needs a GPU to start at all"
    fi

    local parent avail_kb avail_gb
    parent="$(dirname "$ISAACLAB_PATH")"
    # --check / --dry-run must not create anything, so walk up to an existing dir
    while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do
        parent="$(dirname "$parent")"
    done
    avail_kb="$(df -Pk "$parent" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "$avail_kb" ]; then
        avail_gb=$((avail_kb / 1024 / 1024))
        echo "    free disk     : ${avail_gb} GiB on $parent"
        [ "$avail_gb" -ge 20 ] || warn "an install of Isaac Lab + torch needs ~20 GiB"
    fi

    if have_docker; then
        echo "    docker        : usable ($(docker --version 2>/dev/null))"
    else
        echo "    docker        : not usable (no CLI, or the daemon is not reachable)"
    fi

    # the mount points docker-compose.yaml persists live under the home dir; the
    # native install uses the same locations
    echo "    home          : $DOCKER_USER_HOME"
}

# --- shared: choose the mode -----------------------------------------------
resolve_mode() {
    case "$MODE" in
        native|docker) ;;
        auto)
            if have_docker; then MODE="docker"; else MODE="native"; fi ;;
        *)
            fail "unknown --mode '$MODE'"; MODE="native" ;;
    esac
    echo
    echo "=== 2. Mode: $MODE ==="
    case "$MODE" in
        docker) echo "    a docker daemon answers: build docker/Dockerfile.base and start the container" ;;
        native) echo "    no usable docker daemon: repeating the docker/Dockerfile.base steps in place" ;;
    esac
}

# --- shared: clone or update the Isaac Lab checkout -------------------------
# Equivalent of `COPY ../ ${ISAACLAB_PATH}` from docker/Dockerfile.base, except
# that a git checkout is used so it can be updated later.
step_clone() {
    echo
    echo "=== Isaac Lab checkout ($ISAACLAB_REF) ==="

    # a checkout owned by another user makes git refuse to work on it
    if command -v git >/dev/null 2>&1 &&
        ! git config --global --get-all safe.directory 2>/dev/null | grep -qx "$ISAACLAB_PATH"
    then
        run git config --global --add safe.directory "$ISAACLAB_PATH"
    fi

    if [ -d "$ISAACLAB_PATH/.git" ]; then
        echo "    $ISAACLAB_PATH is already a git checkout - fetching '$ISAACLAB_REF'"
        run git -C "$ISAACLAB_PATH" fetch --tags --prune origin ||
            fail "git fetch failed in $ISAACLAB_PATH"
        run git -C "$ISAACLAB_PATH" checkout --quiet "$ISAACLAB_REF" ||
            fail "git checkout '$ISAACLAB_REF' failed"
    elif [ -d "$ISAACLAB_PATH" ] && [ -n "$(ls -A "$ISAACLAB_PATH" 2>/dev/null)" ]; then
        fail "$ISAACLAB_PATH exists but is not a git checkout - move it away or use --path"
    else
        run mkdir -p "$(dirname "$ISAACLAB_PATH")"
        run git clone --branch "$ISAACLAB_REF" "$ISAACLAB_REPO_URL" "$ISAACLAB_PATH" ||
            fail "git clone $ISAACLAB_REPO_URL failed"
    fi

    if [ "$DRY_RUN" = 0 ] && [ -f "$ISAACLAB_PATH/isaaclab.sh" ]; then
        echo "    checkout  : $(git -C "$ISAACLAB_PATH" rev-parse --short HEAD 2>/dev/null || echo '?')"
        run chmod +x "$ISAACLAB_PATH/isaaclab.sh" || fail "chmod +x isaaclab.sh failed"
        echo "    isaaclab.sh: OK"
    fi
}
# --- native mode: the docker/Dockerfile.base steps, in place ---------------
# native 1/8: `apt-get install build-essential libglib2.0-0 ncurses-term cmake
# git wget` from docker/Dockerfile.base.
native_step_apt() {
    echo
    echo "=== native 1/8: system packages (docker/Dockerfile.base list) ==="
    if [ "$SKIP_APT" = 1 ]; then
        echo "    skipped (--skip-apt)"
        return 0
    fi
    local pkgs=(build-essential cmake git ncurses-term wget) glib="" missing=0 p
    # the Dockerfile asks for libglib2.0-0; Ubuntu 24.04 renamed it to
    # libglib2.0-0t64, and apt has no candidate for the old name
    glib="$(resolve_pkg libglib2.0-0t64 libglib2.0-0)" || glib=""
    if [ -n "$glib" ]; then
        pkgs+=("$glib")
    else
        warn "no libglib2.0 package found in the repositories - continuing without it"
    fi

    for p in "${pkgs[@]}"; do have_pkg "$p" || { missing=1; break; }; done
    if [ "$missing" = 0 ]; then
        echo "    already installed: ${pkgs[*]}"
        return 0
    fi

    run apt-get update || fail "apt-get update failed"
    run apt-get install -y --no-install-recommends "${pkgs[@]}" ||
        fail "installing ${pkgs[*]} failed"

    if [ "$DRY_RUN" = 0 ]; then
        for p in "${pkgs[@]}"; do
            have_pkg "$p" || fail "package $p is still missing after the install"
        done
    fi
}

# native 2/8: the checkout, `chmod +x isaaclab.sh` and the `_isaac_sim` symlink
# (`RUN ln -sf ${ISAACSIM_ROOT_PATH} ${ISAACLAB_PATH}/_isaac_sim`).
native_step_checkout() {
    echo
    echo "=== native 2/8: checkout + _isaac_sim symlink ==="
    step_clone
    if [ "$DRY_RUN" = 1 ]; then
        echo "    [dry-run] ln -sfn $ISAACSIM_ROOT_PATH $ISAACLAB_PATH/_isaac_sim"
        return 0
    fi
    ln -sfn "$ISAACSIM_ROOT_PATH" "$ISAACLAB_PATH/_isaac_sim" ||
        fail "could not create the $ISAACLAB_PATH/_isaac_sim symlink"
    if [ -e "$ISAACLAB_PATH/_isaac_sim/python.sh" ]; then
        echo "    $ISAACLAB_PATH/_isaac_sim -> $ISAACSIM_ROOT_PATH"
    else
        fail "_isaac_sim/python.sh is not reachable - Isaac Lab cannot start Isaac Sim"
    fi
}

# native 3/8: `RUN ${ISAACLAB_PATH}/isaaclab.sh -p -m pip install toml`.
# tools/install_deps.py reads extension.toml files and needs it.
native_step_toml() {
    echo
    echo "=== native 3/8: pip install toml (for tools/install_deps.py) ==="
    il -p -m pip install toml || fail "installing toml failed"
}

# native 4/8: `RUN isaaclab.sh -p tools/install_deps.py apt <source>`, i.e. the
# apt packages the extensions declare in their extension.toml.
native_step_extension_apt_deps() {
    echo
    echo "=== native 4/8: apt dependencies declared by the extensions ==="
    if [ "$DRY_RUN" = 1 ]; then
        echo "    [dry-run] ./isaaclab.sh -p $ISAACLAB_PATH/tools/install_deps.py apt $ISAACLAB_PATH/source"
        return 0
    fi
    if [ ! -f "$ISAACLAB_PATH/tools/install_deps.py" ]; then
        warn "tools/install_deps.py is not in this revision - skipping"
        return 0
    fi
    il -p "$ISAACLAB_PATH/tools/install_deps.py" apt "$ISAACLAB_PATH/source" ||
        fail "install_deps.py apt failed"
}

# native 5/8: everything docker-compose.yaml mounts, so the native install uses
# exactly the same cache/log/data locations as the container would.
native_step_mount_dirs() {
    echo
    echo "=== native 5/8: directories docker-compose.yaml mounts ==="
    if [ "$DRY_RUN" = 1 ]; then
        echo "    [dry-run] (DOCKER_* env) ./isaaclab.sh -p docker/utils/volume_mounts.py | mkdir -p ..."
        return 0
    fi
    local dirs=""
    # docker-compose.yaml is the single source of truth; the repo ships its own
    # parser, which is what docker/Dockerfile.base calls as well
    if [ -f "$ISAACLAB_PATH/docker/utils/volume_mounts.py" ]; then
        dirs="$(DOCKER_ISAACSIM_ROOT_PATH="$ISAACSIM_ROOT_PATH" \
                DOCKER_ISAACLAB_PATH="$ISAACLAB_PATH" \
                DOCKER_USER_HOME="$DOCKER_USER_HOME" \
                "$ISAACLAB_PATH/isaaclab.sh" -p \
                "$ISAACLAB_PATH/docker/utils/volume_mounts.py" 2>/dev/null |
                grep '^/' || true)"
    fi
    if [ -z "$dirs" ]; then
        warn "could not resolve the mount points from compose - using the explicit list"
        dirs="$(printf '%s\n' \
            "$ISAACSIM_ROOT_PATH/kit/cache" \
            "$ISAACSIM_ROOT_PATH/kit/data" \
            "$DOCKER_USER_HOME/.cache/ov" \
            "$DOCKER_USER_HOME/.cache/pip" \
            "$DOCKER_USER_HOME/.cache/nvidia/GLCache" \
            "$DOCKER_USER_HOME/.nv/ComputeCache" \
            "$DOCKER_USER_HOME/.nvidia-omniverse/logs" \
            "$ISAACSIM_ROOT_PATH/kit/logs/Kit/Isaac-Sim" \
            "$DOCKER_USER_HOME/.local/share/ov/data" \
            "$DOCKER_USER_HOME/Documents" \
            "$ISAACLAB_PATH/docs/_build" \
            "$ISAACLAB_PATH/logs" \
            "$ISAACLAB_PATH/data_storage")"
    fi
    local d n=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        mkdir -p "$d" || fail "could not create $d"
        n=$((n + 1))
    done <<< "$dirs"
    echo "    ready: $n mount point(s)"
}
# native 6/8: `RUN isaaclab.sh --install` - the long one.  Installs torch into
# Isaac Sim's python plus every isaaclab extension (core + the optional
# submodules/extras selected by $ISAACLAB_INSTALL_TARGET).
native_step_install() {
    echo
    echo "=== native 6/8: isaaclab.sh --install $ISAACLAB_INSTALL_TARGET ==="
    echo "    the slowest step by far - several GiB of pip downloads"
    if [ "$FORCE" = 0 ] && [ -f "$MARKER_FILE" ]; then
        echo "    already installed for ref '$(cat "$MARKER_FILE")' - use --force to redo"
        return 0
    fi
    if il --install "$ISAACLAB_INSTALL_TARGET"; then
        if [ "$DRY_RUN" = 0 ]; then
            printf '%s (%s)\n' "$ISAACLAB_REF" "$(date -u +%FT%TZ)" > "$MARKER_FILE"
        fi
        echo "    install finished"
    else
        fail "'isaaclab.sh --install $ISAACLAB_INSTALL_TARGET' failed"
    fi
}

# native 7/8: the Dockerfile's `HACK: Remove install of quadprog dependency` and
# the .bashrc block with ISAACLAB_PATH and the aliases.
native_step_finish() {
    echo
    echo "=== native 7/8: quadprog workaround + shell aliases ==="
    if [ "$DRY_RUN" = 0 ]; then
        il -p -m pip uninstall -y quadprog >/dev/null 2>&1 || true
        echo "    quadprog removed (the Dockerfile does this too)"
    else
        echo "    [dry-run] ./isaaclab.sh -p -m pip uninstall -y quadprog"
    fi

    if [ "$INSTALL_BASHRC" != 1 ]; then
        echo "    .bashrc untouched (--no-bashrc)"
        return 0
    fi

    local rc="${DOCKER_USER_HOME}/.bashrc"
    if [ -f "$rc" ] && grep -qF "$BASHRC_MARKER_BEGIN" "$rc"; then
        echo "    $rc already has the isaaclab block"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "    [dry-run] append ISAACLAB_PATH + aliases to $rc"
        return 0
    fi
    {
        echo ""
        echo "$BASHRC_MARKER_BEGIN"
        echo "export ISAACLAB_PATH=$ISAACLAB_PATH"
        echo "export ISAACSIM_PATH=$ISAACLAB_PATH/_isaac_sim"
        echo "export OMNI_KIT_ALLOW_ROOT=1"
        echo "alias isaaclab=$ISAACLAB_PATH/isaaclab.sh"
        echo "alias python=$ISAACLAB_PATH/_isaac_sim/python.sh"
        echo "alias python3=$ISAACLAB_PATH/_isaac_sim/python.sh"
        echo "alias pip='$ISAACLAB_PATH/_isaac_sim/python.sh -m pip'"
        echo "alias pip3='$ISAACLAB_PATH/_isaac_sim/python.sh -m pip'"
        echo "$BASHRC_MARKER_END"
    } >> "$rc" || fail "could not append to $rc"
    echo "    added ISAACLAB_PATH + isaaclab/python/pip aliases to $rc"
}

# native 8/8: import check, torch/CUDA check, and the example from the guide
# ("To run an example within the container": ./isaaclab.sh -p
# scripts/tutorials/00_sim/log_time.py --headless).
native_step_verify() {
    echo
    echo "=== native 8/8: verification ==="
    if [ "$DRY_RUN" = 1 ]; then
        echo "    skipped in --dry-run"
        return 0
    fi

    [ -e "$ISAACLAB_PATH/_isaac_sim/python.sh" ] ||
        fail "$ISAACLAB_PATH/_isaac_sim does not point at Isaac Sim"

    local out
    out="$(il -p -c 'import isaaclab; print(getattr(isaaclab, "__version__", "unknown"))' 2>/dev/null |
        tail -n1)"
    case "$out" in
        unknown|"") fail "cannot import isaaclab with $ISAACLAB_PATH/_isaac_sim/python.sh" ;;
        *)          echo "    OK    import isaaclab (version $out)" ;;
    esac

    out="$(il -p -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())' 2>/dev/null |
        tail -n1)"
    if printf '%s' "$out" | grep -q 'True'; then
        echo "    OK    torch $out (version, cuda, cuda_available)"
    else
        fail "torch/CUDA check failed (output: '${out:-none}') - training would not use the GPU"
    fi

    if [ "$RUN_SMOKE_TEST" != 1 ]; then
        echo "    smoke test skipped (--no-smoke-test)"
        return 0
    fi
    if [ ! -f "$ISAACLAB_PATH/scripts/tutorials/00_sim/log_time.py" ]; then
        warn "scripts/tutorials/00_sim/log_time.py is not in this revision - skipping the smoke test"
        return 0
    fi
    echo "    running: ./isaaclab.sh -p scripts/tutorials/00_sim/log_time.py --headless"
    if timeout 900 bash -c "cd '$ISAACLAB_PATH' && ./isaaclab.sh -p scripts/tutorials/00_sim/log_time.py --headless" \
        >/tmp/isaaclab_smoke_test.log 2>&1
    then
        echo "    OK    the tutorial ran (log: /tmp/isaaclab_smoke_test.log)"
    else
        fail "log_time.py --headless failed - see /tmp/isaaclab_smoke_test.log"
        tail -n 20 /tmp/isaaclab_smoke_test.log 2>/dev/null
    fi
}
# --- docker mode: exactly what the guide describes --------------------------
docker_step_prereqs() {
    echo
    echo "=== docker 1/5: docker + NVIDIA Container Toolkit ==="
    if ! command -v docker >/dev/null 2>&1; then
        fail "docker is not installed - see the guide's Docker / Docker Compose links"
        return 1
    fi
    echo "    docker        : $(docker --version 2>/dev/null)"
    if docker compose version >/dev/null 2>&1; then
        echo "    docker compose: $(docker compose version --short 2>/dev/null)"
    else
        fail "the 'docker compose' plugin is missing (the guide wants Docker Compose >= 2.25.0)"
    fi
    if command -v nvidia-ctk >/dev/null 2>&1 || docker info 2>/dev/null | grep -qi nvidia; then
        echo "    nvidia runtime: present"
    else
        warn "the NVIDIA Container Toolkit does not look installed - '--gpus all' will fail"
    fi
    if ! docker info >/dev/null 2>&1; then
        fail "cannot talk to the docker daemon (is it running, are you in the docker group?)"
        return 1
    fi
    # the guide's snap caveat: with the snap docker package the repository has to
    # live under /home
    if [ -d /snap ] && [ "${ISAACLAB_PATH#/home/}" = "$ISAACLAB_PATH" ]; then
        warn "docker from snap cannot read $ISAACLAB_PATH - place the repo under /home"
    fi
    return 0
}

docker_step_env() {
    echo
    echo "=== docker 3/5: docker/.env.base ==="
    local envf="$ISAACLAB_PATH/docker/.env.base"
    if [ "$DRY_RUN" = 1 ]; then
        echo "    [dry-run] would read ISAACSIM_VERSION from $envf"
    elif [ ! -f "$envf" ]; then
        fail "$envf not found - is $ISAACLAB_PATH a full Isaac Lab checkout?"
        return 1
    else
        echo "    $(grep -E '^ISAACSIM_VERSION=' "$envf" | head -n1)"
    fi
    if [ -n "$SIM_VERSION_OVERRIDE" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            echo "    [dry-run] sed -i.bak ISAACSIM_VERSION=$SIM_VERSION_OVERRIDE $envf"
        else
            sed -i.bak -E "s|^ISAACSIM_VERSION=.*|ISAACSIM_VERSION=${SIM_VERSION_OVERRIDE}|" "$envf" ||
                fail "could not update $envf"
            echo "    pinned ISAACSIM_VERSION=$SIM_VERSION_OVERRIDE"
        fi
    elif [ -n "${ISAACSIM_VERSION:-}" ]; then
        echo "    (this machine runs Isaac Sim $ISAACSIM_VERSION - use --sim-version to pin it)"
    fi
}

docker_step_start() {
    echo
    echo "=== docker 4/5: build the image and start the container ($DOCKER_PROFILE) ==="
    # isaaclab.sh -o forwards to docker/container.sh -> docker/container.py, which
    # runs `docker compose build` and then `docker compose up -d`
    if [ "$DRY_RUN" = 1 ]; then
        echo "    [dry-run] (cd $ISAACLAB_PATH && ./isaaclab.sh -o start $DOCKER_PROFILE)"
        return 0
    fi
    ( cd "$ISAACLAB_PATH" && ./isaaclab.sh -o start "$DOCKER_PROFILE" ) ||
        fail "building/starting the Isaac Lab container failed"
}

docker_step_result() {
    echo
    echo "=== docker 5/5: container ==="
    if [ "$DRY_RUN" = 0 ] && command -v docker >/dev/null 2>&1; then
        docker ps --filter "name=isaac-lab" --format '    {{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null
    fi
    echo "    shell in it : cd $ISAACLAB_PATH && ./isaaclab.sh -o enter"
    echo "    example     : ./isaaclab.sh -p scripts/tutorials/00_sim/log_time.py --headless"
    echo
    echo "    The guide also has a minimal, headless-only pre-built image:"
    echo "      docker pull nvcr.io/nvidia/isaac-lab:<isaac-lab-version>"
    echo "      (source lives at /workspace/IsaacLab inside it; GUI/X11 is not supported there)"
}
# --- main -------------------------------------------------------------------
preflight

if [ "$FAILED" != 0 ]; then
    echo
    echo "=== Pre-flight found $FAILED problem(s) - nothing was installed ==="
    exit 1
fi

if [ "$CHECK_ONLY" = 1 ]; then
    echo
    echo "=== --check: the pre-flight checks passed, nothing was changed ==="
    exit 0
fi

MARKER_FILE="$ISAACLAB_PATH/.isaaclab-install-ok"
resolve_mode

if [ "$MODE" = "docker" ]; then
    docker_step_prereqs && {
        echo
        echo "=== docker 2/5: Isaac Lab checkout ==="
        step_clone
        docker_step_env
        docker_step_start
        docker_step_result
    }
else
    native_step_apt
    native_step_checkout
    native_step_toml
    native_step_extension_apt_deps
    native_step_mount_dirs
    native_step_install
    native_step_finish
    native_step_verify
fi

echo
if [ "$DRY_RUN" = 1 ]; then
    echo "=== --dry-run: nothing was executed, nothing was changed ==="
    echo "    re-run without --dry-run to do the real install"
elif [ "$FAILED" = 0 ]; then
    echo "=== Isaac Lab is installed ==="
    echo "    path     : $ISAACLAB_PATH  (ref: $ISAACLAB_REF)"
    echo "    python   : $ISAACLAB_PATH/_isaac_sim/python.sh"
    echo "    version  : $( ( cd "$ISAACLAB_PATH" 2>/dev/null && ./isaaclab.sh -p -c \
        'import isaaclab; print(isaaclab.__version__)' 2>/dev/null | tail -n1 ) || echo unknown )"
    echo "    example  : cd $ISAACLAB_PATH && ./isaaclab.sh -p scripts/tutorials/00_sim/log_time.py --headless"
    echo "    docs     : https://isaac-sim.github.io/IsaacLab/main/source/setup/installation/index.html"
    if [ "$MODE" = "native" ]; then
        echo "    note     : this install lives in this container's filesystem; it is"
        echo "               lost if the instance is destroyed.  Re-run this script (or"
        echo "               add it to /root/onstart.sh) to get it back."
    fi
    echo "=== all steps finished successfully at $(date) ==="
else
    echo "=== finished with $FAILED error(s) - check the messages above and $LOG_FILE ==="
fi
exit $((FAILED > 0 ? 1 : 0))
