# isaac-lab-desktop

Isaac Sim + Isaac Lab + a DCV/XFCE remote desktop in one image — "option B".
Build it once, push it, point a Vast.ai template at it, and a fresh instance
boots straight into a working Isaac Lab GUI instead of paying the install tax.

It is the containerised version of what was verified by hand on a live
isaac-sim instance:

- `/root/onstart.sh` → the DCV desktop (here: `Dockerfile` §2 + `dcv-start.sh`)
- `/root/install_isaaclab.sh` → the Isaac Lab install (`Dockerfile` §3–5),
  using the same paths (`/isaac-sim`, `/workspace/isaaclab`) and the same
  commands the vendor `docker/Dockerfile.base` uses.

## Layout

| File | Purpose |
|---|---|
| `Dockerfile` | the image: base + desktop/DCV + pinned Isaac Lab + deps |
| `dcv.conf` | DCV server config (system auth, web viewer on 8443) |
| `dcv-start.sh` | **runtime** half: D-Bus + DCV server + XFCE session + display publish. Image `ENTRYPOINT`, also callable from Vast On-Start Script |
| `verify.sh` | `isaaclab-verify`: "does this host/GPU run this image?" (GPU, driver, Vulkan/torch, isaaclab import, display, optional full compat check) |
| `build.sh` | build (+ optional push) with version args |
| `template-provisioning.sh` | content for the Vast template's On-Start Script (SSH/Jupyter modes) |

## Build

You **cannot build this inside a Vast container instance** (no docker daemon,
no user/mount namespaces, no fuse — verified: `unshare -U` fails). Build on
any machine with Docker. **No GPU is needed to build.**

```bash
cd isaac-lab-image
docker login nvcr.io -u '$oauthtoken' -p <NGC_API_KEY>   # base image lives on NGC
./build.sh --registry myuser --push                     # defaults: sim 6.0.1 + lab v3.0.0-beta2.patch1
```

Other pairs (IsaacLab README, "Isaac Sim Version Dependency"):

```bash
./build.sh --sim-tag 5.1.0 --lab-ref v2.3.2 --install-target core --registry myuser --push
./build.sh --sim-tag 6.1.0 --lab-ref release/3.0.0 --registry myuser --push
```

Where to build:

1. **Your own machine / workstation with Docker** (fastest if it has the image layers cached).
2. **A Vast VM instance** (Ubuntu templates, KVM): it has systemd, so nested
   Docker works — install Docker there, build, push, destroy the VM.
3. **CI (e.g. GitHub Actions)**: no GPU needed. Build takes 30–60 min and the
   image is ~40 GB, so use a runner with cache + fast disk, or split into a
   nightly job.

## Push + Vast template

`build.sh --push` prints the exact template values. In short:

- **Image Path:Tag**: `<registry>/isaac-lab-desktop:<tag>`
- **Private registry**: Docker Hub private / GHCR / NGC all work — Vast has a
  **Docker Repository Authentication** section in the template for the
  credentials. Never put secrets in a public template.
- **Ports**: `22` (SSH) and `8443` (DCV web viewer). TCP. UDP is not needed.
- **Environment**: `ACCEPT_EULA=Y`, `PRIVACY_CONSENT=Y`. Root password via the
  template, never baked into the image.
- **Disk**: **≥ 150 GB** — Vast container disk cannot be resized after creation.
- **Launch mode**:
  - `docker ENTRYPOINT` → Vast runs the image as designed (`dcv-start` → shell);
    nothing else needed.
  - `SSH` / `Jupyter` → Vast overrides the entrypoint; set the template's
    On-Start Script to a URL serving `template-provisioning.sh`, which calls
    `/usr/local/bin/dcv-start` and then `isaaclab-verify`.

## What the image pins — and what the host still decides

This is the honest version of "will it run the same on another machine?".

**Pinned in the image (identical everywhere):**
OS (Ubuntu 24.04 for Sim 6.x), Isaac Sim version, Isaac Lab git ref
(recorded in `/opt/isaaclab-ref.txt`), Python 3.12, the CUDA *runtime*/
toolkit + cuDNN that ship with Sim/torch inside the image, the exact torch
build (`torch.version.cuda`), all pip packages, DCV + XFCE, and the scripts.

**Always comes from the host (cannot be baked in):**
the kernel and the **NVIDIA driver** (`libcuda.so`, `nvidia-smi`), the GPU
model, VRAM, CPU count/quota, `/dev/shm`, port mappings, and whether the
machine is bare metal / VM / MIG / vGPU.

Consequences, in practice:

1. **Image CUDA vs host driver.** `nvidia-smi`'s "CUDA Version" is the *driver's*
   capability, not the container's. Containers are forward-compatible: the
   image runs on any host whose driver is **≥ the minimum** for its CUDA
   runtime (Isaac Sim 6.0's own check: **driver ≥ 535.161**). A *much newer*
   driver than you built with is fine. An *older* driver fails loudly
   ("CUDA driver version is insufficient…").
2. **Different GPU, same era → fine.** 3090 / 4090 / A5000 / A40 / A100 /
   L40S / L4 all run the same image: what changes is VRAM (16 → 24 → 48 → 96
   GB, i.e. how many parallel envs / how much camera traffic fits) and speed.
3. **Different GPU arch (newer generation) → rebuild.** A CUDA 12.4-era image
   has no `sm_120` kernels, so it cannot run on RTX 50xx / Blackwell even with
   a new driver. Rule of thumb: the image's CUDA must support the GPU's
   compute capability (Blackwell needs CUDA ≥ 12.8 + driver ≥ 570). The
   reverse (old GPU, new image) is fine.
4. **No / weak RT cores → Isaac Sim fails.** It needs RTX-capable GPUs
   (Turing and newer). Datacenter cards *with* RTX (L4/L40/L40S/A10/A40/A100…
   the driver blacklists vGPU/Grid where unsupported) work headless and for
   sensors; non-RTX cards (P40, P100…) do not.
5. **MIG / vGPU slices are a trap.** Isaac Sim generally wants a whole GPU.
   If a host offers MIG profiles, ask for a full-GPU offer instead.
6. **Baked shader caches do not transfer performance.** Kit's
   `/isaac-sim/kit/cache` is keyed to driver+GPU; on a different host Kit
   recompiles (first GUI launch is slow once per host, then fast). Bake the
   directories (done here), not the expectation.
7. **Version tags can encode the matrix.** Vast's `[Automatic]` tag feature
   picks a tag containing the machine's CUDA string (e.g. `my-img-cuda-12.8`
   vs `my-img-cuda-12.6`), which is a neat trick if you maintain one image per
   CUDA line.

**The contract:** the image guarantees *the same software stack*; you verify
*the host* with one command after every boot:

```bash
isaaclab-verify                    # ~1-2 min: GPU, driver, torch/CUDA, import, display
RUN_COMPAT_CHECK=1 isaaclab-verify # + full Isaac Sim compatibility check
```

`template-provisioning.sh` already runs it, so a bad host fails loudly at
startup instead of wasting your time mid-training.

## Verify on first boot

```bash
isaaclab-verify
dcv list-sessions                                        # 'xfce-session' virtual
cd /workspace/isaaclab && ./isaaclab.sh -p scripts/tutorials/00_sim/log_time.py --headless
# then in the DCV desktop (https://<host>:8443, root / your password):
cd /workspace/isaaclab && ./isaaclab.sh -p scripts/reinforcement_learning/rsl_rl/train.py --task Isaac-Cartpole-v0
# (no --headless → watch it learn in the Kit viewport)
```

## Updating

Rebuild with new tags, keep old tags around (they are your rollback):

```bash
./build.sh --sim-tag 6.1.0 --lab-ref release/3.0.0 --tag sim6.1.0-lab-3.0.0 --registry myuser --push
```

The image `LABEL`s (`isaacsim.version`, `isaaclab.ref`) and
`/opt/isaaclab-ref.txt` inside the container tell you exactly what a running
instance is.

## Alternatives / variants

- **Smaller build, official install:** `FROM nvcr.io/nvidia/isaac-lab:3.0.0-rc1`
  (base, Kit+RTX) and add only §1–2 + §6 (desktop/DCV). Less to maintain, but
  you inherit their non-root `uid 1000` runtime user and their pinned
  `/opt/isaaclab-venv` layout. The `kitless` profile (`:3.0.0-rc1-kitless`)
  is for batch/cloud training with no Kit at all.
- **`nice-dcv-gl`:** GPU-accelerated OpenGL inside the virtual session for
  non-Vulkan apps (RViz, Blender…). Isaac Sim itself doesn't need it (Vulkan).
  Needs a separate DCV license token: `./build.sh --dcv-gl`.
- **Multi-arch:** published amd64 only, like the vendor images. Vast x86 hosts
  are the target; arm64 (e.g. DGX Spark) needs the aarch64 Isaac Sim image.

## Caveats

- The build itself is unverified *here* (a Vast container has no docker
  daemon, user, or mount namespaces, so nothing here can build or even
  syntax-check a Dockerfile beyond careful review) — build logs from the
  builder machine are the proof. It was derived from two verified sources:
  `/root/onstart.sh` (a DCV desktop that provably serves Isaac Sim GUI) and
  `/root/install_isaaclab.sh` (the IsaacLab install steps verified against the
  vendor CLI).
- ~40 GB image: pushes/pulls are slow on first contact, fast afterwards on
  the same host (layer cache). If Docker Hub throttles you, GHCR is a good
  second home.
- `Vast` currently has no "commit instance → image" feature; the
  build-elsewhere + push + template flow above is the documented path.
