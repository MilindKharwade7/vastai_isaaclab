# LeIsaac (Lightwheel AI) — install guide for `scripts/install_leisaac.sh`

[LeIsaac](https://github.com/LightwheelAI/leisaac) is a LeRobot-compatible
manipulation benchmark built on **Isaac Sim 5.1 + Isaac Lab 2.3.x** (SO-101
arms, state-machine data generation, imitation + RL workflows). Its
[official installation guide](https://lightwheelai.github.io/leisaac/docs/getting_started/installation/)
is a list of manual shell commands. `scripts/install_leisaac.sh` automates all
of it, end to end, and was validated on a live GPU instance (see
[Verified run](#verified-run)).

This is a **different stack** from [`install_isaaclab.sh`](../scripts/install_isaaclab.sh):
that one installs Isaac Lab next to the Isaac Sim build already inside the Vast
`isaac-sim` image (Sim 6.x). LeIsaac pins **Sim 5.1 / python 3.11** and wants
its own conda environment, so the two scripts do not overlap — keep the DCV
desktop from [`onstart.sh`](../scripts/onstart.sh) if you want the GUI, and run
this installer in a shell.

## Quick start

```bash
# ~10+ GB of downloads, tens of minutes — run it in the background
nohup /root/install_leisaac.sh > /root/leisaac_install.log 2>&1 &
tail -f /root/leisaac_install.log
```

On success the script prints the env name, the repo path and copy-pasteable
next steps; verification is `python scripts/environments/list_envs.py` running
headless inside Isaac Sim.

Pre-flight only (no side effects), or a plan of every command:

```bash
/root/install_leisaac.sh --no-verify --no-assets --dry-run
```

## What it does, step by step

| Script step | Guide step | Detail |
|---|---|---|
| `Preflight checks` | – | Linux/x86-64, free disk (warns < 40 GB), GPU + driver + compute capability, reachability of GitHub / PyPI / `pypi.nvidia.com` / Anaconda |
| `Step 1a` | Environment setup | Miniconda into `/opt/miniconda3` (skipped if conda exists; accepts the Anaconda channel ToS on modern conda) |
| `Step 1b` | Environment setup | `conda create -n leisaac python=3.11` |
| `Step 1c` | Environment setup | `conda install -y -c nvidia/label/cuda-12.8.1 -c conda-forge cuda-toolkit` |
| `Step 1d` | – | `conda init bash zsh`, so `conda activate leisaac` works in a new terminal ([details](#activating-the-environment)) |
| `Step 2` | Install PyTorch | `torch==2.7.0 torchvision==0.22.0` from `--index-url .../whl/cu128` |
| `Step 3a` | Install from source | `git clone --depth 1` + `submodule update --init dependencies/IsaacLab` |
| `Step 3b` | Install from source | `pip install isaacsim[all,extscache]==5.1.0 --extra-index-url https://pypi.nvidia.com` (~10 GB) |
| `Step 3c` | Install from source | `apt-get install cmake build-essential unzip` + the EGL/GL runtime libs IsaacSim needs on slim images |
| `Step 3d-pre` | – | pre-build sdists that modern setuptools cannot build (see [Gotchas](#gotchas-found-during-the-real-run)) |
| `Step 3d` | Install from source | `cd dependencies/IsaacLab && ./isaaclab.sh --install` |
| `Step 3e` | Install from source | `pip install -e source/leisaac` |
| `Step 3f` | – | persist the Isaac Sim EULA acceptance |
| `Step 4` | Optional | `--with-lerobot`: `pip install -e "source/leisaac[lerobot]"` + `numpy==1.26.0` |
| `Step 5` | Asset preparation | `assets/robots/so101_follower.usd` + scene USDs into `<repo>/assets` |
| `Step 6` | Verify | import checks, torch/CUDA check, `pip check`, headless `list_envs.py` |

`--mode package` follows the guide's alternative path instead
(`pip install "leisaac[isaaclab] @ git+…#subdirectory=source/leisaac"`), which
is faster but leaves you without `scripts/` and `assets/` unless the repo is
also cloned — the script clones it non-recursively in that case.

## Options

```
--mode source|package   "source" (default) or "package" install workflow
--repo-dir DIR          where to clone/expect the repo   (default $HOME/leisaac)
--workdir DIR           downloads + constraints file    (default $HOME)
--env-name NAME         conda env name                  (default leisaac)
--miniconda-dir DIR     Miniconda location              (default /opt/miniconda3)
--scenes LIST           comma separated scenes, or "all"
                        (default kitchen_with_orange)
--with-lerobot          install the optional LeRobot extra
--no-assets / --no-apt / --no-cuda-toolkit / --no-verify / --no-preflight
                        / --no-conda-init
--clean                 remove the conda env first
--dry-run               print commands, change nothing
```

Environment variables: `LEISAAC_ENV_NAME`, `LEISAAC_WORKDIR`,
`LEISAAC_MINICONDA_DIR`, `LEISAAC_ASSETS_ROOT`, `LOG_FILE`, `ACCEPT_EULA`.

Everything is **idempotent**: conda, the env, torch, the clone/submodule,
IsaacSim, `isaaclab --install`, and each asset are skipped when already
present, so a re-run after an interrupted or failed run resumes.

## Activating the environment

`conda: command not found` after installing is expected in the shell that ran
the installer: Miniconda's batch installer (`-b`) never edits shell init files,
and the script calls conda by absolute path internally. The script now runs
`conda init bash zsh` (step **1d**), so **a new terminal works out of the box**:

```bash
conda activate leisaac
```

In a shell that was already open while the install ran, `conda` is still
unknown — the init file was only written, not re-read. Either reconnect, or:

```bash
source /opt/miniconda3/etc/profile.d/conda.sh && conda activate leisaac
```

For scripts / cron / `ssh host 'cmd'` (non-interactive shells read no rc file at
all, so `conda init` cannot help there), activate explicitly:

```bash
/opt/miniconda3/envs/leisaac/bin/python scripts/environments/list_envs.py   # simplest
# or
source /opt/miniconda3/etc/profile.d/conda.sh && conda activate leisaac && ...
```

`--no-conda-init` skips the rc-file edit if you manage PATH yourself.


## Gotchas found during the real run

Every one of these cost a failed run before the script handled it. They are all
consequences of installing a *pinned* stack (Sim 5.1 / torch 2.7) from PyPI in
2026, so they apply to the manual guide too.

**1. `stable-baselines3` silently replaces your CUDA build of torch.**
`isaaclab_rl` requires `stable-baselines3>=2.7`; the resolver picks the newest
(>= 2.9), which requires `torch>=2.8`, so pip uninstalls `torch 2.7.0+cu128` and
pulls torch 2.14 plus ~5 GB of CUDA-13 wheels from PyPI. The install then looks
fine and breaks at runtime. Fix: a generated constraints file
(`<workdir>/leisaac-pip-constraints.txt`) exported as `PIP_CONSTRAINT`, pinning
`torch==2.7.0`, `torchvision==0.22.0`, `stable-baselines3<2.9`,
`setuptools<81`. `sb3 2.8.0` still satisfies the `gymnasium>=1.0.0` IsaacLab
wants, so nothing else has to move.

**2. `flatdict==4.0.1` cannot be built by modern setuptools.**
It is an sdist (a `robomimic` dependency of `isaaclab`) whose build requires
`pkg_resources`, which setuptools >= 81 removed. Build isolation always installs
the *latest* setuptools and ignores `PIP_CONSTRAINT`, so the failure is
`Failed to build 'flatdict' ... No module named 'pkg_resources'`. Fix:
pre-install it with `--no-build-isolation` after installing
`setuptools<81 wheel` into the env (step `3d-pre`).

**3. `set -u` + conda activation.**
`conda activate` (and the `cuda-toolkit` activate script, which appends to
`NVCC_PREPEND_FLAGS`) references unbound variables, so a `set -u` script dies
inside conda. All conda operations go through wrappers that temporarily
`set +u`.

**4. Isaac Sim blocks on `Do you accept the EULA?` in a non-interactive shell.**
`isaacsim/kit/kit_app.py` reads the answer from stdin when no TTY is present.
`ACCEPT_EULA=Y` is not enough for the pip package: the script also writes
`<site-packages>/isaacsim/kit/EULA_ACCEPTED` containing `yes`, which is what the
kernel checks on every later launch (`list_envs.py`, teleop, datagen).

**5. Shallow submodule clone of IsaacLab.**
The repo pins IsaacLab as a submodule at a specific commit; a plain
`git clone --recursive --depth 1` fails when that commit is not a branch tip.
The script clones the superproject shallowly, then fetches the submodule
(`--depth 1`, retrying with full history).

**6. Scene/robot USDs are not in the repository.**
`assets/` is empty in git -- the guide's "asset preparation" step downloads them
from GitHub release assets (`so101_follower.usd`, `kitchen_with_orange.zip`,
`table_with_cube.zip`), falling back to the `LightwheelAI/leisaac_env`
HuggingFace repo for any scene not published as a release asset. Without them
the tasks register fine but the environment errors when it resolves the USD path.

**7. `conda: command not found` in the user's shell.**
Miniconda's batch installer (`-b -p /opt/miniconda3`) intentionally writes
nothing to `~/.bashrc`, and the installer only *sources*
`/opt/miniconda3/etc/profile.d/conda.sh` inside its own subshells -- so the
summary's `conda activate leisaac` fails in a normal terminal. Step **1d** now
runs `conda init bash zsh`; already-open shells still need
`source /opt/miniconda3/etc/profile.d/conda.sh` once. Non-interactive shells
(`ssh host 'cmd'`, cron) read no rc file at all, so they must either source
`conda.sh` or call `/opt/miniconda3/envs/leisaac/bin/python` directly. See
[Activating the environment](#activating-the-environment).




## Verified run

Executed on a Linux x86-64 box, RTX 5060 Ti (16 GB, compute capability 12.0),
driver 580.126.09 -- i.e. a Blackwell GPU, which is exactly the case that forces
the CUDA 12.8 pin.

```text
Preflight          GPU: NVIDIA GeForce RTX 5060 Ti (driver 580.126.09, cc 12.0)
Step 1..2          conda env leisaac, python 3.11, cuda-toolkit 12.8.1, torch 2.7.0+cu128
Step 3b            isaacsim 5.1.0.0 (+ all / extscache extension caches)
Step 3d            IsaacLab @ 3c6e67b  -> isaaclab 0.47.2
Step 3e            leisaac 0.4.0 (editable)
Step 6             import torch/isaacsim/isaaclab/leisaac: OK
                   torch version: 2.7.0+cu128 (as documented)
                   torch CUDA: OK
                   list_envs.py -> 15 LeIsaac-SO101-* tasks, "verification succeeded"
```

Disk after a full source install: **~ 25 GB** for the conda env (IsaacSim +
extension caches dominate) and **~ 126 MB** of assets. Budget >= 40 GB free.

`pip check` reports inconsistencies in `packaging`, `click`, `idna` and
`psutil`. Those come from IsaacSim/IsaacLab's own pins, are present in a purely
manual install too, and do not affect the verified behaviour -- the script warns
instead of failing.

## After installing

```bash
conda activate leisaac
cd ~/leisaac

python scripts/environments/list_envs.py            # registered tasks, headless

# teleoperation -- needs a physical SO-101 leader arm on USB
python scripts/environments/teleoperation/teleop_se3_agent.py \
  --task=LeIsaac-SO101-PickOrange-v0 --teleop_device=so101leader

# state-machine data generation (headless, no leader arm required)
python scripts/datagen/state_machine/generate.py --headless \
  --task LeIsaac-SO101-PickOrangeDemo-v0 --collection_directory ./datasets
```

Teleoperation without a leader arm is rejected by the task config
(`Teleoperation is only supported with so101leader teleop device for SO101
tasks`), which the script's summary calls out.

**Known upstream breakage (not caused by this installer):**
`scripts/datagen/state_machine/generate.py` reaches the simulation, resets the
scene and drives the state machine, but on episode end crashes with
`ValueError: Termination term 'success' not found` inside `auto_terminate()`.
The task config strips the `success` termination term while the shared
`auto_terminate` helper still calls `set_term_cfg("success", ...)`
unconditionally. `list_envs.py` and teleoperation work; only the datagen entry
point is affected, so demo datasets cannot be generated until upstream fixes it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `bash: conda: command not found` | shell was open before the install: `source /opt/miniconda3/etc/profile.d/conda.sh`; non-interactive shells must source it or call `/opt/miniconda3/envs/leisaac/bin/python` directly ([more](#activating-the-environment)) |
| `Do you accept the EULA?` prompt on every launch | `export OMNI_KIT_ACCEPT_EULA=YES` (the installer also writes `isaacsim/kit/EULA_ACCEPTED`) |
| `libstdc++.so.6: version GLIBCXX_3.4.30 not found` | `conda install -c conda-forge gcc=12 -y` |
| Qt / EGL / `libGL` errors in a headless container | `unset DISPLAY`, use `--headless` / `--headlessRendering`; `install_apt_deps` installs the usual EGL/GL libs |
| torch has no CUDA / cuda-toolkit mismatch | re-run steps 1c + 2 (`--clean` recreates the env); check `nvidia-smi` driver >= 525 |
| torch is 2.14-ish after install, CUDA import fails | the constraints file was ignored -- make sure `PIP_CONSTRAINT` is exported in the same shell (gotcha 1) |
| Tasks register but the scene fails to load | assets missing -> re-run step 5 (`--scenes kitchen_with_orange`) |
| Different GPU / Isaac Sim era | adjust the pins at the top of the script against the [version table in the guide](https://lightwheelai.github.io/leisaac/docs/getting_started/installation/) |
| Disk filled mid-install | IsaacSim + caches need ~25 GB; check `df -h` first or move `--miniconda-dir` / `--workdir` to a bigger volume |

## Relationship to the rest of this repo

| Script | Stack | GUI |
|---|---|---|
| `install_isaaclab.sh` | Isaac Sim already in the image (4.5--6.x) + matching Isaac Lab | DCV desktop via `onstart.sh` |
| `install_leisaac.sh` | LeIsaac's pinned Sim 5.1.0 / Lab 2.3.x / torch 2.7.0+cu128 in its own conda env | headless by default |

