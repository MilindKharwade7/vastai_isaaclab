# Security notes — read before you rent

This repo was built for fast iteration on throwaway dev boxes. Harden it
before anything else.

## 1. The dev-default root password

`scripts/onstart.sh` sets the root password to the literal string `password`
(both SSH and DCV authenticate against it). That is a *local dev* default, not
a policy:

- set a strong password in the Vast template / at first boot:
  `echo "root:STRONG" | chpasswd`
- templates marked **public** must never contain passwords or secrets — Vast
  docs call this out explicitly, and this repo does not ship any

## 2. Remote exposure

`onstart.sh` exposes the DCV web viewer on **8443** (HTTPS, self-signed cert)
and SSH on 22. DCV login is the Linux login, so whoever reaches the port can
try to log in as root. Keep instances private, VPC/firewall where possible,
and do not forward extra ports you don't use.

## 3. What's deliberately *not* in this repo

- No API keys, tokens, or private keys (`~/.vast_api_key`, SSH keys, NGC
  tokens are never committed — they live in your Vast account/template).
- No baked-in credentials in the Docker image (`docker/`): the image ships no
  password; the template's On-Start Script sets it (`DCV_ROOT_PASSWORD` env or
  the template's own field).
- `./build.sh --push` uses whatever Docker credentials *your builder machine*
  already has; it never stores or prints them.

## 4. Software supply chain (read-only here)

The scripts fetch from these places at build/run time; pin or mirror them if
you need reproducibility beyond a git ref:

- `github.com/isaac-sim/IsaacLab.git` (pinned by `--ref`, default detected
  from the Isaac Sim version; prefer a commit SHA for strict pinning)
- `d1uj6qtbmh3dt5.cloudfront.net` (NICE DCV tarball, Ubuntu 24.04 build)
- `packages.microsoft.com` (VS Code repo + signing key)
- Ubuntu archives + PyPI + `download.pytorch.org` (via `apt` / `pip`)

Suggested hygiene: `--dry-run` first on a fresh instance, read
`/var/log/onstart.log` and `/var/log/isaaclab_install.log` after, and rebuild
the Docker image (`--no-cache`) from time to time instead of layering on an
old base.
