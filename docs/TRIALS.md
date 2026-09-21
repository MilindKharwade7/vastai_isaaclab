# Trial runs & evidence

Everything below was executed on the reference Vast.ai instance
(Isaac Sim `6.0.0-rc.59`, RTX 3090 24 GB, driver 595.71.05, 48 vCPU, 100 GB
disk); nothing here changed the installed system.

## 2026-09-21 — DCV desktop + Isaac Sim GUI over DCV

- `/root/onstart.sh` run; DCV session `xfce-session` on X display `:0`
  (1464×672); web viewer HTTP 200 on 8443.
- `glxinfo` inside the session: `llvmpipe` (software) — expected without the
  licensed `nice-dcv-gl`; irrelevant for Isaac Sim (Vulkan path).
- `./isaac-sim.compatibility_check.sh` (with `OMNI_KIT_ALLOW_ROOT=1`,
  `ACCEPT_EULA=Y`): **PASSED** — `Graphics API: Vulkan`, RTX 3090, driver
  supported. Also flagged: `powersave` CPU governor, IOMMU enabled,
  no display detected (DISPLAY was unset in that shell).
- `./isaac-sim.sh GUI` launched with `DISPLAY=:0` + session XAUTHORITY: window
  **`Isaac Sim Full 6.0.0`** appeared (1440×587) and rendered the full Kit UI
  (viewport RTX Real-Time 2.0, Stage/Content/Property panels).
  Screenshot: [`assets/dcv-isaacsim-gui.png`](../assets/dcv-isaacsim-gui.png),
  captured with `scripts/xwd2png.py` (pure-stdlib XWD→PNG converter).
  App was stopped afterwards (GPU back to ~0.3 GB / 0%).

## 2026-09-21 — Isaac Lab install path validation

- `./install_isaaclab.sh --check`: detected Sim `6.0.0-rc.59` → ref
  `v3.0.0-beta2.patch1`, python 3.12.13, GitHub reachable, exit 0.
- `./install_isaaclab.sh --dry-run` (native + docker modes, the latter with a
  stub `docker`): full plan printed, zero side effects (`/workspace` never
  created, `.bashrc` untouched).
- Throwaway depth-1 clone (`--branch v3.0.0-beta2.patch1`) + `_isaac_sim`
  symlink: `./isaaclab.sh -h` shows the 3.x CLI (`-i/--install`, `-p`);
  `./isaaclab.sh -p -c 'import isaacsim'` runs under Isaac Sim's python 3.12;
  `tools/install_deps.py apt` and `docker/utils/volume_mounts.py` resolve as
  the scripts call them. Clone removed afterwards.
- `docker/` recipe review findings (fixed in-repo): `LABEL` used out-of-scope
  build `ARG`s (re-declared in-stage); `verify.sh` swallowed subprocess
  failures through a trailing filter (rewritten to check exit codes);
  `nvidia-smi --query-gpu` has no `cuda_version` field
  (`name,driver_version,memory.total` + top-table "CUDA Version" used instead).

## 2026-09-21 — environment constraints relevant to the docs

- No Docker daemon/CLI, no user/mount namespaces (`unshare -U/-m` → EPERM),
  no `/dev/fuse` → option B **cannot be built here**; build on Docker-capable
  hardware (local, Vast VM, CI).
- `/usr/share/vulkan/icd.d` (container view) carries mesa ICDs only, but
  `/etc/vulkan/icd.d/nvidia_icd.json` + `libnvidia-glvkspirv` +
  `libnvidia-rtcore` are present → GPU Vulkan works.
