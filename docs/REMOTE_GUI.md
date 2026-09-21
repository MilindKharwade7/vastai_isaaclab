# How to see Isaac Lab on a Vast.ai box (and why it works)

Short version: **you already have the hard part.** Isaac Lab is a Python
framework on top of Isaac Sim; "seeing Isaac Lab" means running Isaac Sim's
Kit GUI (or a script *without* `--headless`), and this was proven on the
reference box: Isaac Sim 6.0.0's window (`Isaac Sim Full 6.0.0`, 1440×587)
rendered into the DCV desktop ([screenshot](../assets/dcv-isaacsim-gui.png)).

## What "GUI" needs on a headless cloud GPU

Isaac Sim renders with **Vulkan on the GPU** (verified: the container ships
`/etc/vulkan/icd.d/nvidia_icd.json`, and Isaac Sim's own compatibility check
reported `Graphics API: Vulkan` + **PASSED**). What it needs from *you* is a
place to show the window — any X display. The chain used here:

```text
Kit (Vulkan → GPU) → window on Xdcv :0 → DCV (H.264, hardware-encoded) → TCP 8443 → browser
```

Two facts make this the right pick on Vast:

- Vast maps ports over shared IPs (TCP port-mapping). DCV needs **one TCP
  port**; the officially blessed alternative, **WebRTC livestream, needs UDP
  (SRTP media) plus reachable ICE candidates**, which port-mapped cloud hosts
  routinely break (there is a long community thread of exactly this failure on
  RunPod-like providers).
- The virtual session's **GLX is software** (`llvmpipe`) because the licensed
  `nice-dcv-gl` add-on is not installed. That does not matter for Isaac Sim
  (Vulkan path), only for non-Vulkan 3D apps in the desktop (RViz, Blender…).

## Transports, ranked

| Transport | Verdict on Vast |
|---|---|
| **NICE DCV** (`scripts/onstart.sh`) | Best: one TCP port, hardware encode, full desktop — and proven with the screenshot |
| **WebRTC livestream** (Isaac Sim native) | Fragile: needs UDP + public ICE candidates behind Vast's NAT |
| **noVNC / x11vnc** | Works over TCP, but framebuffer-based → poor for a 3D viewport |
| **X11 over SSH** | Don't — terrible for RTX rendering |
| **Headless + visualizers** | Train with `--headless`, watch via Isaac Lab visualizers (`kit` / `newton` / `rerun` / `viser`, install selectors in 3.x) or `--video`. No desktop, less GPU contention |

## Practical notes

- The reference desktop runs on X display **`:0`** (DCV discovers it; later
  shells get it via `DISPLAY`/`XAUTHORITY`, see `dcv-start.sh`'s publishing).
- Keep the training GUI and heavy training on the same GPU in mind as a
  tradeoff: a live viewport spends GPU time that RL could use — headless +
  periodic `--video` is cheaper.
- Vast CPU is quota-limited and the host governor was `powersave` on the
  reference box: keep env counts modest and check the compat checker's
  warnings.
