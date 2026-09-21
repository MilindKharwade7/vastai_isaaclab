# syntax=docker/dockerfile:1
# =============================================================================
# isaac-lab-desktop - Isaac Sim + Isaac Lab + a DCV/XFCE remote desktop in one
# image.  This is "option B": build it once, push it, and point a Vast.ai
# template at it, so a fresh instance boots straight into a working Isaac Lab
# GUI instead of paying the install tax again.
#
# It is the containerised version of what was verified by hand on the
# isaac-sim instance:
#   * /root/onstart.sh          -> the DCV desktop parts (section 2 + dcv-start)
#   * /root/install_isaaclab.sh -> the Isaac Lab parts  (sections 3-5)
# with the same paths (/isaac-sim, /workspace/isaaclab) and the same commands
# the vendor docker/Dockerfile.base uses at image build time.
#
# Build (no GPU needed, any machine with Docker; ~30-60 min, image ~40 GB):
#   docker login nvcr.io -u '$oauthtoken' -p <NGC_API_KEY>     # base image
#   docker build --platform linux/amd64 \
#     --build-arg ISAACSIM_TAG=6.0.1 \
#     --build-arg ISAACLAB_REF=v3.0.0-beta2.patch1 \
#     -t <registry>/isaac-lab-desktop:6.0.1-lab-v3.0.0-beta2.patch1 .
#
# ... or just use ./build.sh --push
# =============================================================================

ARG ISAACSIM_REGISTRY=nvcr.io/nvidia
ARG ISAACSIM_IMAGE=isaac-sim
# Use a released tag, not an -rc: released tags stay pullable and are the ones
# Isaac Lab documents compatibility against (Sim 6.0.1 <-> Lab v3.0.0-beta2*).
ARG ISAACSIM_TAG=6.0.1
FROM ${ISAACSIM_REGISTRY}/${ISAACSIM_IMAGE}:${ISAACSIM_TAG}

# ARG declared before the first FROM is not visible inside the stage unless
# re-declared: bring the FROM-time versions of these into stage scope.
ARG ISAACSIM_TAG
ARG ISAACSIM_REGISTRY
ARG ISAACSIM_IMAGE

# The vendor images ship with a non-root user (uid 1234) and run as it; the
# desktop stack installed below needs root.
USER root
SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    ISAACSIM_ROOT_PATH=/isaac-sim \
    ISAACLAB_PATH=/workspace/isaaclab \
    OMNI_KIT_ALLOW_ROOT=1

ARG ISAACLAB_REPO=https://github.com/isaac-sim/IsaacLab.git
ARG ISAACLAB_REF=v3.0.0-beta2.patch1
# 'all', 'core', or e.g. "rl[rsl-rl]" - forwarded to ./isaaclab.sh --install
ARG ISAACLAB_INSTALL_TARGET=all
ARG DCV_PKG_URL=https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu2404-x86_64.tgz
# nice-dcv-gl is a separately licensed DCV add-on (GPU OpenGL inside a *virtual*
# session).  Isaac Sim itself does not need it: it renders through Vulkan.
ARG INSTALL_DCV_GL=0

LABEL org.opencontainers.image.title="isaac-lab-desktop" \
      org.opencontainers.image.description="Isaac Sim + Isaac Lab + DCV/XFCE remote desktop" \
      isaacsim.version="${ISAACSIM_TAG}" \
      isaaclab.ref="${ISAACLAB_REF}"

# -----------------------------------------------------------------------------
# 1. System packages
#    * the Isaac Lab deps from the vendor docker/Dockerfile.base
#    * the X/desktop stack the DCV virtual session needs
#    Names that were renamed in Ubuntu 24.04 are resolved at build time
#    (libglib2.0-0 -> libglib2.0-0t64, libgtk-3-0 -> libgtk-3-0t64); asking apt
#    for the old names fails outright on 24.04 ("no installation candidate").
# -----------------------------------------------------------------------------
RUN . /etc/os-release && \
    if [ "${VERSION_ID}" = "24.04" ]; then GLIB=libglib2.0-0t64; GTK=libgtk-3-0t64; \
    else GLIB=libglib2.0-0; GTK=libgtk-3-0; fi && \
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ncurses-term wget tar psmisc gpg \
        apt-transport-https ca-certificates \
        "${GLIB}" "${GTK}" \
        xfce4 xfce4-goodies xorg dbus-x11 x11-xserver-utils mesa-utils \
        libpam0g libegl1 libgl1 libglx-mesa0 \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2. NICE DCV server + Xdcv + web viewer (same tarball /root/onstart.sh used)
# -----------------------------------------------------------------------------
RUN mkdir -p /tmp/dcv && cd /tmp/dcv && \
    wget --tries=3 --timeout=60 -qO dcv.tgz "${DCV_PKG_URL}" && \
    tar -xzf dcv.tgz && cd nice-dcv-* && \
    apt-get update && \
    apt-get install -y \
        ./nice-dcv-server_*.deb ./nice-xdcv_*.deb ./nice-dcv-web-viewer_*.deb && \
    if [ "${INSTALL_DCV_GL}" = "1" ]; then apt-get install -y ./nice-dcv-gl_*.deb; fi && \
    cd / && rm -rf /tmp/dcv /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 3. Isaac Lab checkout, pinned.
#    Equivalent to the vendor `COPY ../ ${ISAACLAB_PATH}`, but with git so the
#    ref is explicit, reproducible and inspectable.
# -----------------------------------------------------------------------------
RUN git clone --depth 1 --branch "${ISAACLAB_REF}" "${ISAACLAB_REPO}" "${ISAACLAB_PATH}" && \
    sed -i 's/\r$//' "${ISAACLAB_PATH}/isaaclab.sh" && \
    chmod +x "${ISAACLAB_PATH}/isaaclab.sh" && \
    ln -sfn "${ISAACSIM_ROOT_PATH}" "${ISAACLAB_PATH}/_isaac_sim" && \
    ln -sfn "${ISAACLAB_PATH}/isaaclab.sh" /usr/local/bin/isaaclab && \
    git -C "${ISAACLAB_PATH}" log -1 --format='%H %d (%ci)' > /opt/isaaclab-ref.txt && \
    cat /opt/isaaclab-ref.txt

# -----------------------------------------------------------------------------
# 4. Isaac Lab dependencies - the exact sequence of docker/Dockerfile.base
# -----------------------------------------------------------------------------
WORKDIR ${ISAACLAB_PATH}
RUN ./isaaclab.sh -p -m pip install toml
RUN ./isaaclab.sh -p "${ISAACLAB_PATH}/tools/install_deps.py" apt "${ISAACLAB_PATH}/source" && \
    apt-get -y autoremove && apt-get clean && rm -rf /var/lib/apt/lists/*
# the long step: torch + every isaaclab extension
RUN ./isaaclab.sh --install "${ISAACLAB_INSTALL_TARGET}"
# vendor Dockerfile.base: "HACK: Remove install of quadprog dependency"
RUN ./isaaclab.sh -p -m pip uninstall -y quadprog || true
RUN ./isaaclab.sh -p -m pip cache purge || true

# -----------------------------------------------------------------------------
# 5. Mount points listed in docker-compose.yaml, created ahead of time so a
#    named volume inherits sane ownership on first mount (the vendor image does
#    the same using the repo's own docker/utils/volume_mounts.py).
#    Note: if the parser prints nothing (older revisions), grep exits 1 and
#    the build fails here rather than shipping an image without mount points.
# -----------------------------------------------------------------------------
RUN set -o pipefail && \
    export DOCKER_ISAACSIM_ROOT_PATH="${ISAACSIM_ROOT_PATH}" \
           DOCKER_ISAACLAB_PATH="${ISAACLAB_PATH}" \
           DOCKER_USER_HOME=/root && \
    dirs="$(./isaaclab.sh -p docker/utils/volume_mounts.py | grep '^/')" && \
    mkdir -p ${dirs} /var/log/dcv /var/run/dbus /run/isaaclab && \
    echo "${dirs}"

# -----------------------------------------------------------------------------
# 6. DCV configuration, runtime startup script and shell environment
# -----------------------------------------------------------------------------
COPY dcv.conf /etc/dcv/dcv.conf
COPY dcv-start.sh /usr/local/bin/dcv-start
COPY verify.sh /usr/local/bin/isaaclab-verify
RUN chmod +x /usr/local/bin/dcv-start /usr/local/bin/isaaclab-verify && \
    printf '%s\n' \
        'export ISAACLAB_PATH=/workspace/isaaclab' \
        'export ISAACSIM_PATH=/workspace/isaaclab/_isaac_sim' \
        'export OMNI_KIT_ALLOW_ROOT=1' \
        'export ACCEPT_EULA=${ACCEPT_EULA:-Y}' \
        'export PRIVACY_CONSENT=${PRIVACY_CONSENT:-Y}' \
        'alias isaaclab=/workspace/isaaclab/isaaclab.sh' \
        > /etc/profile.d/isaaclab.sh

ENV ACCEPT_EULA=Y PRIVACY_CONSENT=Y

# DCV web viewer (HTTPS, self-signed certificate)
EXPOSE 8443

# dcv-start brings up D-Bus + the DCV server + the XFCE session, publishes the
# X display, and then execs "$@" - so `docker run -it <image>` lands in a shell
# on a working desktop, and Vast's entrypoint launch mode works as well.
ENTRYPOINT ["/usr/local/bin/dcv-start"]
CMD ["/bin/bash", "-l"]
