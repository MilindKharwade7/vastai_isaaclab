#!/bin/bash
# =============================================================================
# isaaclab-verify - answer "does this host/GPU actually run this image?"
# (the part a baked image cannot pin: kernel, driver, GPU model, VRAM).
#
# Run it inside any instance of the image, right after boot:
#   isaaclab-verify            # fast checks (~1-2 min): GPU, driver, Vulkan,
#                              # torch/CUDA, isaaclab import, X/display
#   RUN_COMPAT_CHECK=1 isaaclab-verify   # plus Isaac Sim's full compatibility
#                              # check (~1-3 min): driver version, RTX, VRAM
#
# Exit status is non-zero if any check failed.  Everything is read-only except
# the optional compatibility check (it writes logs, like any Kit app).
# =============================================================================
set -o pipefail
FAILED=0
ok()   { echo "    OK    $*"; }
fail() { echo "!!! ERROR: $*"; FAILED=$((FAILED + 1)); }

echo
echo "=== isaaclab-verify at $(date) ==="
echo "    image: isaac-sim ${ISAACSIM_TAG:-?} + Isaac Lab $(cat /opt/isaaclab-ref.txt 2>/dev/null | cut -c1-12 || echo '?')"

echo "--- 1. host GPU + driver ---"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version,cuda_version,memory.total \
        --format=csv 2>/dev/null | head -n5
else
    fail "nvidia-smi is not in the container - the container toolkit did not expose a GPU"
fi

echo "--- 2. python / torch / CUDA (as Isaac Lab would see them) ---"
PY_OUT="$(mktemp)"
if [ ! -x /workspace/isaaclab/_isaac_sim/python.sh ]; then
    fail "Isaac Sim python is missing - the install is broken"
elif /workspace/isaaclab/isaaclab.sh -p -c \
    'import sys, torch; print("python:", sys.version.split()[0], "| torch:", torch.__version__,
     "| cuda build:", torch.version.cuda, "| cuda available:", torch.cuda.is_available(),
     "| device:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")' \
    >"$PY_OUT" 2>&1; then
    grep -viE 'warning|info' "$PY_OUT" | tail -n3
    grep -q 'cuda available: True' "$PY_OUT" ||
        fail "torch is installed but CUDA is NOT available - check the driver/GPU"
else
    fail "running python code in Isaac Lab failed - see $PY_OUT"
fi
rm -f "$PY_OUT"

echo "--- 3. isaaclab import ---"
if [ ! -d /workspace/isaaclab/source/isaaclab ]; then
    fail "the Isaac Lab source tree is missing - the install is broken"
elif ! /workspace/isaaclab/isaaclab.sh -p -c \
    'import isaaclab; print("isaaclab:", getattr(isaaclab, "__version__", "unknown"))' 2>&1 |
    grep -viE 'warning|info' | tail -n1; then
    fail "cannot import isaaclab - see above"
fi

echo "--- 4. X display (for the GUI) ---"
if [ -n "${DISPLAY:-}" ] && DISPLAY="${DISPLAY}" xwininfo -root >/dev/null 2>&1; then
    ok "DISPLAY=$DISPLAY answers"
else
    fail "no X display answering (DISPLAY='${DISPLAY:-unset}') - is the DCV session up? run dcv-start"
fi

if [ "${RUN_COMPAT_CHECK:-0}" = 1 ]; then
    echo "--- 5. Isaac Sim compatibility check (RUN_COMPAT_CHECK=1) ---"
    COMPAT_OUT="$(mktemp)"
    if ( cd /isaac-sim && timeout 420 ./isaac-sim.compatibility_check.sh ) >"$COMPAT_OUT" 2>&1; then
        grep -E 'System checking result|Driver version|GPU 0:|Display \[|minimum: 535' "$COMPAT_OUT" | tail -n8
        grep -q 'System checking result: PASSED' "$COMPAT_OUT" ||
            fail "the compatibility check did not report PASSED - see $COMPAT_OUT"
    else
        fail "the compatibility check reported a problem - see $COMPAT_OUT"
    fi
else
    echo "--- 5. compatibility check skipped (RUN_COMPAT_CHECK=1 runs it, ~1-3 min) ---"
fi

echo
if [ "$FAILED" = 0 ]; then
    echo "=== all checks passed at $(date) ==="
else
    echo "=== $FAILED check(s) failed - this host/GPU cannot run the image as is ==="
fi
exit $((FAILED > 0 ? 1 : 0))
