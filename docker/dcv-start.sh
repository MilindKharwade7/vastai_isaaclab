#!/bin/bash
# =============================================================================
# dcv-start - the runtime half of the isaac-lab-desktop image.
#
# Everything that cannot be baked into a Docker image lives here: the D-Bus
# system bus (containers have no systemd), the NICE DCV server, and the DCV
# virtual XFCE session that carries the Isaac Sim / Isaac Lab GUI.
#
# It is idempotent: re-running it on a live container keeps the existing
# session and desktop, so it can be used three ways:
#   1. as the image ENTRYPOINT (docker run -it, and Vast's "docker
#      ENTRYPOINT" launch mode, where Vast runs the image as designed),
#   2. called as "$@" from Vast's On-Start Script / PROVISIONING_SCRIPT with
#      SSH or Jupyter launch modes (which override the entrypoint),
#   3. by hand (ssh in, /usr/local/bin/dcv-start, reconnect the DCV client).
#
# On success it exec's "$@" (default: an interactive login shell), after
# publishing the real X display in /etc/profile.d/isaaclab-display.sh.
#
# Credentials: the DCV login is the Linux login.  Set the root password with
#   echo "root:YOURPASSWORD" | chpasswd
# before/after start (the image deliberately does not ship one).
# =============================================================================
set -o pipefail

DCV_CONF="/etc/dcv/dcv.conf"
DCV_SESSION="xfce-session"
DCV_SESSION_INIT="/usr/bin/xfce4-session"
DISPLAY_PUBLISH="/etc/profile.d/isaaclab-display.sh"
RUNTIME_DIR="/run/isaaclab"
FAILED=0
fail() { echo "!!! ERROR: $*"; FAILED=$((FAILED + 1)); }

echo
echo "###############################################################"
echo "### dcv-start: runtime services at $(date)"
echo "###############################################################"

mkdir -p /var/run/dbus /var/log/dcv "$RUNTIME_DIR"

# --- D-Bus system bus (no systemd inside containers) -------------------------
if pgrep -x dbus-daemon >/dev/null 2>&1 && [ -S /var/run/dbus/system_bus_socket ]; then
    echo "    dbus: already running"
else
    # a stale pid file (survives a container restart) makes dbus-daemon bail out
    rm -f /var/run/dbus/pid /var/run/dbus/system_bus_socket
    dbus-daemon --system --fork --nopidfile || fail "starting the D-Bus system daemon failed"
    sleep 1
fi
[ -S /var/run/dbus/system_bus_socket ] ||
    fail "the D-Bus system socket /var/run/dbus/system_bus_socket did not appear"

# --- stale X locks -----------------------------------------------------------------
# /tmp and /var/run survive a container restart; stale X locks make Xdcv refuse
# to start.  Never touch anything while a server is actually alive.
if pgrep -x dcvserver >/dev/null 2>&1; then
    echo "    dcvserver: already running (keeping the session intact)"
else
    rm -rf /var/run/dcv /var/run/dcvsvc
    rm -f /tmp/.X*-lock /tmp/.X11-unix/X*
    mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
fi

# --- DCV server ----------------------------------------------------------------
if pgrep -x dcvserver >/dev/null 2>&1; then
    echo "    dcvserver: already running (pid: $(pgrep -x dcvserver | tr '\n' ' '))"
else
    # -d --service is the invocation the packaged systemd unit uses:
    # `--service` is what makes the server register com.nicesoftware.DcvServer
    # on the system bus, and that bus name is how the `dcv` CLI finds it.
    # Without it the server runs, but every CLI call fails with
    # "the dcvserver service is not running".
    nohup /usr/bin/dcvserver -d --service --log-dir=/var/log/dcv \
        >/var/log/dcv/server_stdout.log 2>&1 &
    for _ in $(seq 1 30); do
        dcv list-sessions >/dev/null 2>&1 && break
        sleep 1
    done
fi
if dcv list-sessions >/dev/null 2>&1; then
    echo "    dcvserver: answering (pid: $(pgrep -x dcvserver | tr '\n' ' '))"
else
    fail "DCV server is not answering - see /var/log/dcv/server.log"
fi

# --- the virtual session that carries the desktop ------------------------------------
if dcv list-sessions 2>/dev/null | grep -q "'$DCV_SESSION'"; then
    echo "    session '$DCV_SESSION': already exists"
else
    # --owner root  : the session belongs to / runs as root (Vast runs as root)
    # --type virtual: headless session driven by Xdcv, no physical display
    # --init        : desktop environment started inside the session
    if dcv create-session --owner root --type virtual \
        --init "$DCV_SESSION_INIT" "$DCV_SESSION"; then
        sleep 5  # give XFCE a moment to come up before it is verified
    else
        fail "creating the DCV session failed"
    fi
fi

for p in Xdcv xfce4-session xfwm4; do
    if pgrep -x "$p" >/dev/null 2>&1; then
        echo "    OK    $p running"
    else
        fail "$p is not running"
    fi
done

# the web viewer serves HTTPS with a self-signed certificate -> curl -k
WEB_CODE=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' https://127.0.0.1:8443/ 2>/dev/null)
case "$WEB_CODE" in
    200|401) echo "    OK    DCV web viewer answers on port 8443 (HTTP $WEB_CODE)" ;;
    *)       fail "DCV web viewer on port 8443 did not answer (HTTP '${WEB_CODE:-no response}')" ;;
esac

# --- publish the X display ---------------------------------------------------------
# DCV usually hands out :0, but it can differ if another X server exists.  Every
# login shell sources /etc/profile.d, so writing the real display there makes
# DISPLAY/XAUTHORITY correct for Isaac Sim, glxinfo, screenshots, ...
DISP="$(dcv describe-session "$DCV_SESSION" 2>/dev/null |
        awk -F': ' '/X display/ {print $2}' | tr -d ' \r')"
XAUTH="$(dcv describe-session "$DCV_SESSION" 2>/dev/null |
        awk -F': ' '/X authority/ {print $2}' | tr -d ' \r')"
if [ -z "$DISP" ]; then
    fail "could not determine the session display"
    DISP=:0
fi
export DISPLAY="$DISP"
[ -n "$XAUTH" ] && export XAUTHORITY="$XAUTH"
{
    echo "# generated by dcv-start - do not edit"
    echo "export DISPLAY=$DISP"
    echo "export XAUTHORITY=$XAUTH"
} > "$DISPLAY_PUBLISH"
echo "    display: $DISP (published in $DISPLAY_PUBLISH)"

echo
echo "### dcv-start finished with $FAILED error(s) at $(date)"
echo "### connect with: DCV client or https://<host>:8443 (login: root / <root password>)"
echo "### Isaac Lab : /workspace/isaaclab  ($(cat /opt/isaaclab-ref.txt 2>/dev/null || echo 'ref unknown'))"
if [ "$FAILED" != 0 ]; then
    echo "### some steps failed - still exec'ing \"$*\" for debugging"
fi
exec "$@"

