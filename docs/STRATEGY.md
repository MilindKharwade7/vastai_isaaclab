# Strategy: which approach, when

Context: you rent Vast.ai **container** instances (no systemd, no nested
Docker, disk fixed at creation and lost on destroy, stops keep the disk,
volumes are host-local). The goal is Isaac Sim + Isaac Lab **with a visible
GUI**.

## The decision

| Situation | Pick |
|---|---|
| Iterating daily on one box | **A.** Isaac Sim image + `scripts/install_isaaclab.sh` (native mode) + DCV desktop from `scripts/onstart.sh` |
| Renting repeatedly / destroy-survival / sharing the env | **B.** Bake `docker/` into an image once, push, point a template at it |
| Pure headless training fleet | **C.** Official `nvcr.io/nvidia/isaac-lab` image (3.x profiles: `base`, `ros2`, `kit-less`, per-version tags) |
| You need Docker/K8s inside the instance | **D.** Vast **VM** instance, then follow the Isaac Lab Docker guide verbatim |
| Cheapest long training | **E.** Headless training boxes + one GUI dev box (A or B) |

## Why A-then-B and not C directly

The "minimal, headless only" line about the Isaac Lab image comes from the
**`main` docs (Isaac Sim 5.1 era)**. The current (3.0) image docs *do* document
windowed/X11 use (`-e DISPLAY`, Xauthority + `/tmp/.X11-unix` mounts, an
`X11_FORWARDING_ENABLED` toggle in the compose flow). It is still not a
desktop, though — if you want DCV + XFCE you end up building an image anyway,
which is B.

## Persistence on Vast (decides more than you'd think)

- **Stop/restart**: container disk survives. Stopped instances still bill storage.
- **Destroy**: container disk is gone. Anything not in the image or in git/cloud
  is gone.
- **Volumes**: survive destroy, reattach to new instances **on the same host
  only**. Good for checkpoints/datasets, not for portability.
- **Truly portable**: a baked image (B), or your repo + install scripts (A).

Keep `/root/vast-isaaclab` itself (and these scripts) in git on every box, and
treat checkpoints as the only thing allowed to live outside git.

## Version matrix (don't mix these)

| Isaac Sim | Isaac Lab | Python | Status |
|---|---|---|---|
| 4.5 / 5.0 / 5.1 | `main` / `v2.3.X` | 3.11 | long-supported |
| **6.0.x** | **`v3.0.0-beta2(.patch1)`** | 3.12 | current for new stacks |
| 6.1.x | `release/3.0.0` / `develop` | 3.12 | bleeding edge |

`install_isaaclab.sh` detects this from `/isaac-sim/VERSION`. Prefer released
Sim tags (`6.0.1`, not `6.0.0-rc`) for anything you keep.

## Vast template checklist (A and B)

- Image: `nvcr.io/nvidia/isaac-sim:<released-tag>` (A) or your pushed image (B)
- Ports: `22` + `8443` (DCV), both TCP
- Env: `ACCEPT_EULA=Y`, `PRIVACY_CONSENT=Y` (root password via the template)
- Disk: **≥ 150 GB** (Sim ≈ 30 GB, Lab + torch + caches ≈ 20–30 GB, rest for
  checkpoints) — **cannot be resized later**
- Launch: `docker ENTRYPOINT` runs the image as designed; `SSH`/`Jupyter`
  override the entrypoint, so wire the On-Start Script (A: `onstart.sh`,
  B: `template-provisioning.sh`)
- GPU: RTX-capable (Turing+), full GPU (no MIG slices), 16 GB VRAM minimum,
  driver ≥ 535.161 for Sim 6.x; run `isaaclab-verify` (B) or
  `install_isaaclab.sh --check` (A) on first boot

## Portability contract (B)

The image pins the *software* (OS, Sim, Lab ref, torch, DCV, XFCE).
The host always provides kernel, **driver**, GPU model, VRAM, CPU quota.
Rules of thumb: newer-era GPUs are fine; a *newer GPU generation* than the
image's CUDA supports needs a rebuild (e.g. Blackwell needs CUDA ≥ 12.8);
drivers are backward compatible (older driver than the image's CUDA needs
fails). Baked Kit shader caches recompile per host — bake the directories,
not the expectation. Full write-up: [`docker/README.docker.md`](../docker/README.docker.md).
