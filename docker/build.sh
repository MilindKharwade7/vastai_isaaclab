#!/bin/bash
# =============================================================================
# build.sh - build (and optionally push) the isaac-lab-desktop image.
#
# Run it on any machine with Docker - your laptop, a Vast VM instance, or CI.
# No GPU is needed to BUILD; Docker only needs ~40 GB of disk and network.
#
#   ./build.sh --registry myuser --tag sim6.0.1-lab                 # build only
#   ./build.sh --registry myuser --push                             # build + push
#   ./build.sh --sim-tag 5.1.0 --lab-ref v2.3.2 --install-target core --push
#
# options:
#   --sim-tag TAG       nvcr.io/nvidia/isaac-sim base tag (default: 6.0.1)
#   --lab-ref REF       Isaac Lab git ref (default: v3.0.0-beta2.patch1)
#   --install-target T  isaaclab.sh --install target (default: all)
#   --registry REG      push target registry/user (default: none = local only)
#   --name NAME         image name (default: isaac-lab-desktop)
#   --tag TAG           image tag, defaults to "<sim>-<lab>" below
#   --dcv-gl            also install the (separately licensed) nice-dcv-gl
#   --no-cache          full rebuild
#   --push              push after a successful build
#   -h, --help          this text
#
# Compatibility pairs (IsaacLab README, "Isaac Sim Version Dependency"):
#   isaac-sim 6.0.x  <->  v3.0.0-beta2.patch1   (python 3.12)
#   isaac-sim 6.1.x  <->  release/3.0.0          (python 3.12)
#   isaac-sim 4.5/5.0/5.1 <-> main / v2.3.X     (python 3.11)
# =============================================================================
set -o pipefail

SIM_TAG="6.0.1"
LAB_REF="v3.0.0-beta2.patch1"
INSTALL_TARGET="all"
REGISTRY=""
NAME="isaac-lab-desktop"
TAG=""
DO_PUSH=0
NO_CACHE=""
DCV_GL=0

usage() { sed -n '2,30p' "$0"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --sim-tag)        SIM_TAG="$2"; shift 2 ;;
        --lab-ref)        LAB_REF="$2"; shift 2 ;;
        --install-target) INSTALL_TARGET="$2"; shift 2 ;;
        --registry)       REGISTRY="$2"; shift 2 ;;
        --name)           NAME="$2"; shift 2 ;;
        --tag)            TAG="$2"; shift 2 ;;
        --dcv-gl)         DCV_GL=1; shift ;;
        --no-cache)       NO_CACHE="--no-cache"; shift ;;
        --push)           DO_PUSH=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage; echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")" || exit 1

command -v docker >/dev/null 2>&1 || { echo "!!! docker is not installed on this machine" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "!!! cannot talk to the docker daemon" >&2; exit 1; }

[ -z "$TAG" ] && TAG="sim${SIM_TAG}-lab-${LAB_REF}"
if [ -n "$REGISTRY" ]; then IMAGE="${REGISTRY}/${NAME}:${TAG}"; else IMAGE="${NAME}:${TAG}"; fi

# the base image lives on NGC and needs authentication; verify it early instead
# of failing an hour into the build
if ! docker manifest inspect "nvcr.io/nvidia/isaac-sim:${SIM_TAG}" >/dev/null 2>&1; then
    echo "!!! cannot read nvcr.io/nvidia/isaac-sim:${SIM_TAG} - log in first:"
    echo "    docker login nvcr.io -u '\$oauthtoken' -p <NGC_API_KEY>"
    exit 1
fi
echo "--- base image nvcr.io/nvidia/isaac-sim:${SIM_TAG} is readable ---"

echo "--- building $IMAGE ---"
# shellcheck disable=SC2086
docker buildx build --platform linux/amd64 $NO_CACHE \
    --build-arg "ISAACSIM_TAG=${SIM_TAG}" \
    --build-arg "ISAACLAB_REF=${LAB_REF}" \
    --build-arg "ISAACLAB_INSTALL_TARGET=${INSTALL_TARGET}" \
    --build-arg "INSTALL_DCV_GL=${DCV_GL}" \
    -t "$IMAGE" . || { echo "!!! build failed" >&2; exit 1; }

echo "--- built $IMAGE ---"
docker image inspect "$IMAGE" --format '    size: {{.Size}} bytes   entrypoint: {{.Config.Entrypoint}}'

if [ "$DO_PUSH" = 1 ]; then
    [ -n "$REGISTRY" ] || { echo "!!! --push needs --registry" >&2; exit 1; }
    echo "--- pushing $IMAGE ---"
    docker push "$IMAGE" || { echo "!!! push failed" >&2; exit 1; }
    echo "--- pushed $IMAGE ---"
    echo
    echo "Create the Vast.ai template with:"
    echo "    Image Path:Tag : $IMAGE"
    echo "    Ports          : 22, 8443 (DCV web viewer)"
    echo "    Environment    : ACCEPT_EULA=Y, PRIVACY_CONSENT=Y (plus a root password"
    echo "                     via the template, never inside the image)"
    echo "    Disk           : >= 150 GB recommended (bigger is safer, cannot be resized)"
    echo "    Launch mode    : SSH or docker ENTRYPOINT; with SSH, run the contents"
    echo "                     of template-provisioning.sh once (printed below), which"
    echo "                     calls /usr/local/bin/dcv-start"
else
    echo "--- local build only; re-run with --push to publish it ---"
fi
