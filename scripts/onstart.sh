#!/bin/bash
# =============================================================================
# onstart.sh - executed by the Vast.ai launch script (/.launch) on EVERY
#              instance start; all output goes to /var/log/onstart.log
#
# What this box is supposed to end up as:
#   1) XFCE desktop + X / OpenGL runtime libraries
#   2) Visual Studio Code
#   3) root password "password" (used by SSH and by DCV's PAM authentication)
#   4) NICE / Amazon DCV server + Xdcv + web viewer
#   5) a DCV *virtual* session running xfce4-session, so the machine is usable
#      from a remote graphical client although it has no physical display
#
# Repairs compared to the previous revision:
#   * `libgl1-mesa-glx` was dropped from Ubuntu 24.04: apt refused to install it
#     ("has no installation candidate") and because of `set -e` that error
#     aborted the script inside step 1, so *nothing* was ever installed and the
#     container had no desktop at all.  Package names are now resolved against
#     the configured repositories (see resolve_pkg) instead of being hardcoded.
#   * `libgtk-3-0` has the same problem on 24.04 (it is `libgtk-3-0t64`), it
#     would have been the very next failure.
#   * `set -e` is gone: this script runs on every boot, and dying half way
#     through is what left the machine broken.  Every step reports success or
#     failure, the summary lists the failures and the exit status is non-zero
#     if anything failed.
#   * every step is idempotent, so a re-run (or the next boot) only redoes what
#     is really missing and never disturbs a session that is already running.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive
set -o pipefail

# --- configuration ----------------------------------------------------------
DCV_PKG_URL="https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu2404-x86_64.tgz"
DCV_CONF="/etc/dcv/dcv.conf"
DCV_SESSION="xfce-session"
DCV_SESSION_INIT="/usr/bin/xfce4-session"
# GPU accelerated OpenGL inside a *virtual* session needs the extra
# `nice-dcv-gl` package.  It is a separately licensed DCV add-on ("requires a
# specific license token"), so installing it is opt-in: set to 1 to try it.
INSTALL_DCV_GL=0
# ---------------------------------------------------------------------------

FAILED=0
fail() { echo "!!! ERROR: $*"; FAILED=$((FAILED + 1)); }

have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }

# resolve_pkg <name>... -> print the first name that exists in the configured
# repositories.  Needed because package names change between Ubuntu releases
# (libgl1-mesa-glx -> libgl1, libgtk-3-0 -> libgtk-3-0t64, ...).
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

echo
echo "###############################################################"
echo "### onstart.sh started at $(date)"
echo "### host: $(hostname)  PWD: $PWD"
echo "###############################################################"

echo "=== 1. Updating packages and installing dependencies ==="
BASE_PKGS=(xfce4 xfce4-goodies xorg dbus-x11 x11-xserver-utils wget tar psmisc \
           gpg apt-transport-https ca-certificates mesa-utils \
           libpam0g libegl1 libgl1 libglx-mesa0)
NEED_BASE=0
for p in "${BASE_PKGS[@]}"; do
    have_pkg "$p" || { NEED_BASE=1; break; }
done

if [ "$NEED_BASE" = 0 ]; then
    echo "    all base packages already installed - skipping apt-get (fast boot)"
else
    apt-get update || fail "apt-get update failed"
    # libgl1-mesa-glx no longer exists on Ubuntu 24.04, libgl1 replaces it (and
    # is already listed above); the GTK3 runtime was renamed to libgtk-3-0t64.
    GTK3=$(resolve_pkg libgtk-3-0t64 libgtk-3-0) && BASE_PKGS+=("$GTK3")
    if ! apt-get install -y "${BASE_PKGS[@]}"; then
        echo "    apt-get install failed - refreshing the package lists and retrying once"
        apt-get update || true
        apt-get install -y "${BASE_PKGS[@]}" ||
            fail "apt-get install of the base packages failed"
    fi
fi

# a desktop session needs the session manager and the window manager
for p in xfce4-session xfwm4 dbus-x11; do
    have_pkg "$p" || fail "required package $p is missing after the install step"
done

echo "=== 2. Installing VS Code ==="
if command -v code >/dev/null 2>&1; then
    # `code --version` cannot be used here: as root it aborts with "You are
    # trying to start Visual Studio Code as a super user ... add --no-sandbox"
    # and prints nothing, so the version comes from dpkg instead.
    echo "    code is already installed: $(dpkg-query -W -f='${Version}' code 2>/dev/null || echo 'version unknown')"
else
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc |
        gpg --dearmor > /etc/apt/trusted.gpg.d/packages.microsoft.gpg ||
        fail "could not install the Microsoft package signing key"
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        > /etc/apt/sources.list.d/vscode.list
    apt-get update || fail "apt-get update for the VS Code repository failed"
    apt-get install -y code || fail "installing the code package failed"
fi
command -v code >/dev/null 2>&1 || fail "the 'code' binary is not available"

echo "=== 3. Setting root password to 'password' ==="
# DCV authenticates through PAM and uses the same password as SSH
echo "root:password" | chpasswd || fail "chpasswd failed"

echo "=== 4. Downloading and installing NICE DCV for Ubuntu 24.04 ==="
if have_pkg nice-dcv-server && [ -x /usr/bin/dcv ] && [ -x /usr/bin/Xdcv ]; then
    echo "    DCV $(dpkg-query -W -f='${Version}' nice-dcv-server) already installed - skipping"
else
    rm -rf /tmp/nice-dcv-20* /tmp/nice-dcv.tgz
    if wget --tries=3 --timeout=30 -qO /tmp/nice-dcv.tgz "$DCV_PKG_URL" &&
        tar -xzf /tmp/nice-dcv.tgz -C /tmp; then
        # the archive unpacks into nice-dcv-<version>-ubuntu2404-x86_64
        DCV_DIR=$(find /tmp -maxdepth 1 -type d -name 'nice-dcv-*' | sort | head -n1)
        if [ -z "$DCV_DIR" ]; then
            fail "the DCV archive did not contain a nice-dcv-* directory"
        else
            echo "    installing packages from $DCV_DIR"
            # the previous revision did `cd nice-dcv-20*` + relative globs, which
            # silently breaks when the archive layout changes - build the file
            # list explicitly and check it before handing it to apt
            DCV_DEBS=( "$DCV_DIR"/nice-dcv-server_*.deb
                       "$DCV_DIR"/nice-xdcv_*.deb
                       "$DCV_DIR"/nice-dcv-web-viewer_*.deb )
            [ "$INSTALL_DCV_GL" = 1 ] && DCV_DEBS+=( "$DCV_DIR"/nice-dcv-gl_*.deb )
            MISSING=0
            for d in "${DCV_DEBS[@]}"; do
                [ -f "$d" ] || { fail "package missing in the DCV archive: $d"; MISSING=1; }
            done
            if [ "$MISSING" = 0 ]; then
                apt-get install -y "${DCV_DEBS[@]}" ||
                    fail "installing the DCV packages failed"
            fi
            rm -rf "$DCV_DIR" /tmp/nice-dcv.tgz
        fi
    else
        fail "downloading or extracting $DCV_PKG_URL failed"
    fi
fi

# dcv CLI + server come from nice-dcv-server, Xdcv is what runs virtual sessions
for b in /usr/bin/dcv /usr/bin/dcvserver /usr/bin/Xdcv; do
    [ -x "$b" ] || fail "$b is missing - the DCV installation is incomplete"
done

echo "=== 5. Setting up required directories and configuration ==="
mkdir -p /var/run/dbus /var/run/dcv /var/log/dcv /etc/dcv

cat <<'EOF' > "$DCV_CONF"
[license]

[security]
authentication="system"

[session-management]
# Extra Xdcv options for virtual sessions:
#   -listen tcp       the virtual X server also listens on TCP, which remote X
#                     clients (and some DCV helper tools) need
#   -maxclients 1024  without this XFCE runs into "Maximum number of clients
#                     reached" and the session starts hanging
virtual-session-xdcv-args="-listen tcp -maxclients 1024"

[display]

[connectivity]
# web viewer (browser client) - DCV generates a self-signed certificate itself
web-port=8443
EOF
[ -s "$DCV_CONF" ] || fail "could not write $DCV_CONF"

echo "=== 6. Cleaning up stale lock files and old processes ==="
if pgrep -x dcvserver >/dev/null 2>&1; then
    # running again inside a live container must not kill the desktop
    echo "    a DCV server is already running - keeping the current session intact"
else
    # leftovers from a previous run of this container: /tmp and /var/run survive
    # a container restart and a stale X lock makes Xdcv refuse to start
    rm -rf /var/run/dcv /var/run/dcvsvc
    rm -f /tmp/.X*-lock /tmp/.X11-unix/X*
    mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
fi

echo "=== 7. Starting the D-Bus system daemon ==="
# there is no systemd inside the container, so the system bus that the DCV
# server and the `dcv` CLI talk over has to be started by hand
if pgrep -x dbus-daemon >/dev/null 2>&1 && [ -S /var/run/dbus/system_bus_socket ]; then
    echo "    system bus is already running"
else
    # a stale pid file (survives a container restart) makes dbus-daemon bail out
    rm -f /var/run/dbus/pid /var/run/dbus/system_bus_socket
    dbus-daemon --system --fork --nopidfile ||
        fail "starting the D-Bus system daemon failed"
    sleep 1
fi
[ -S /var/run/dbus/system_bus_socket ] ||
    fail "the D-Bus system socket /var/run/dbus/system_bus_socket did not appear"

echo "=== 8. Starting DCV server ==="
if pgrep -x dcvserver >/dev/null 2>&1; then
    echo "    DCV server already running (pid: $(pgrep -x dcvserver | tr '\n' ' '))"
else
    mkdir -p /var/log/dcv
    # -d --service is the invocation the packaged systemd unit uses:
    # `--service` is what makes the server register com.nicesoftware.DcvServer
    # on the system bus, and that bus name is how the `dcv` CLI finds it.
    # Without it the server runs and serves the web viewer, but every CLI call
    # fails with "the dcvserver service is not running".
    nohup /usr/bin/dcvserver -d --service --log-dir=/var/log/dcv \
        >/var/log/dcv/server_stdout.log 2>&1 &
    # wait until the server actually answers, instead of a blind `sleep 3`
    for _ in $(seq 1 30); do
        dcv list-sessions >/dev/null 2>&1 && break
        sleep 1
    done
fi
if dcv list-sessions >/dev/null 2>&1; then
    echo "    DCV server is answering (pid: $(pgrep -x dcvserver | tr '\n' ' '))"
else
    fail "DCV server is not answering - see /var/log/dcv/server.log"
fi

echo "=== 9. Creating DCV virtual session '$DCV_SESSION' ==="
if dcv list-sessions 2>/dev/null | grep -q "'$DCV_SESSION'"; then
    echo "    session '$DCV_SESSION' already exists"
else
    # --owner root  : the session belongs to / runs as root (we are root here)
    # --type virtual: headless session started by Xdcv, no physical display
    # --init        : desktop environment started inside the session
    if dcv create-session --owner root --type virtual \
        --init "$DCV_SESSION_INIT" "$DCV_SESSION"; then
        # give XFCE a moment to come up before it is verified below
        sleep 5
    else
        fail "creating the DCV session failed"
    fi
fi

echo "--- dcv list-sessions ---"
dcv list-sessions || fail "dcv list-sessions failed"

echo "=== 10. Verifying the remote desktop ==="
for p in dcvserver Xdcv xfce4-session xfwm4; do
    if pgrep -x "$p" >/dev/null 2>&1; then
        echo "    OK    $p running (pid: $(pgrep -x "$p" | tr '\n' ' '))"
    else
        fail "$p is not running"
    fi
done

# the web viewer serves HTTPS with a self-signed certificate -> curl -k
WEB_CODE=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' https://127.0.0.1:8443/ 2>/dev/null)
case "$WEB_CODE" in
    200 | 401)
        echo "    OK    DCV web viewer answers on port 8443 (HTTP $WEB_CODE)" ;;
    *)
        fail "DCV web viewer on port 8443 did not answer (HTTP '${WEB_CODE:-no response}')" ;;
esac

if [ "$FAILED" != 0 ]; then
    echo
    echo "############### diagnostics (something failed) ###############"
    echo "--- /var/log/dcv/server.log (last 25 lines) ---"
    tail -n 25 /var/log/dcv/server.log 2>/dev/null
    echo "--- /var/log/dcv/session-*.log (last 25 lines) ---"
    tail -n 25 /var/log/dcv/session-*.log 2>/dev/null
    echo "--- /var/log/dcv/server_stdout.log (last 25 lines) ---"
    tail -n 25 /var/log/dcv/server_stdout.log 2>/dev/null
    echo "##############################################################"
fi

echo
if [ "$FAILED" = 0 ]; then
    echo "=== Setup Complete! Active DCV Sessions: ==="
    dcv list-sessions
    echo "=== connect with:  DCV client or https://<host>:8443  (login: root / password) ==="
    echo "=== all steps finished successfully at $(date) ==="
else
    echo "=== Setup finished with $FAILED error(s) - check the messages above ==="
fi
exit $((FAILED > 0 ? 1 : 0))


