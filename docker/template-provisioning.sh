#!/bin/bash
# =============================================================================
# template-provisioning.sh - what to put in the Vast.ai template for the
# isaac-lab-desktop image.
#
# Use it when the template's launch mode is SSH or Jupyter (those modes run the
# image with Vast's own entrypoint script, so /usr/local/bin/dcv-start from the
# image ENTRYPOINT does not run by itself).  With the "docker ENTRYPOINT" launch
# mode nothing is needed here: Vast runs the image ENTRYPOINT, which is dcv-start
# already.
#
# How to wire it: in the template editor set the On-Start Script (or
# PROVISIONING_SCRIPT, depending on the template type) to a URL that serves
# this exact file (raw.githubusercontent..., a gist, ...).  Vast runs it on
# start, as root, in the container.
# =============================================================================
set -o pipefail

# the root password you actually want for SSH + DCV - Vast templates have a
# dedicated field for this; this fallback exists so the desktop never ends up
# unreachable
if [ -n "${DCV_ROOT_PASSWORD:-}" ]; then
    echo "root:${DCV_ROOT_PASSWORD}" | chpasswd
    echo "    root password set from DCV_ROOT_PASSWORD"
else
    echo "    DCV_ROOT_PASSWORD is not set - DCV keeps the image default; set the"
    echo "    root password in the template or export DCV_ROOT_PASSWORD"
fi

# dcv-start is idempotent: a re-run on a live container keeps the session
/usr/local/bin/dcv-start "$@" || echo "!!! dcv-start reported a problem - check /var/log/dcv/"

# fail loudly but early if the new host cannot run this stack
/usr/local/bin/isaaclab-verify
