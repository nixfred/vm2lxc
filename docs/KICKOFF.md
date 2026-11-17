# vm2lxc kickoff for Larry (from VM2LXC Bot, Fred approved start 2026-11-16)

Read docs/BRIEF.md first: research, pitfalls, gap list and the locked decisions D0-D12 at the bottom. The decisions win over anything earlier in the brief.

## What we're building
vm2lxc: a plain, deterministic script that runs as root on a Proxmox VE 8.x/9.x host and converts a QEMU VM into an LXC container safely. NO AI inside the tool. Bash (or one small python file if bash gets ugly), shellcheck clean, MIT license.

## This first slice (do only this)
1. Repo scaffold in this folder: git init, README (honest: "work in progress, not usable yet"), LICENSE (MIT, credit ArMaTeC/lxc-to-vm and thushan/proxmox-vm-to-ct for borrowed ideas), `vm2lxc` entry script, lib/ layout, tests/ (bats), Makefile with `lint` (shellcheck) and `test`.
2. Subcommand skeleton: `vm2lxc preflight <vmid>`, `vm2lxc scan`, `vm2lxc convert <vmid>` (stub that only prints "not implemented"), `vm2lxc undo <ct>` (stub), `vm2lxc cleanup` (stub). Flags: `--yes`, `--answers FILE`, `--dry-run`, `--no-tui`.
3. Implement READ-ONLY `preflight` and `scan`:
   - read `qm config`, storage type (v1 supports zfs + lvm-thin only, others = "not supported yet"), PVE version (8.x/9.x).
   - red/yellow/green verdict with plain reasons per brief D11: hostpci (GPU/PCI passthrough), non-linux ostype, appliance hints, multi-disk (fine, mp mapping), etc. Guest-internal checks (docker, kernel modules, NFS server, cloud-init, snap) come later from the read-only snapshot mount; for now design the check interface so they plug in, and mark them "needs disk inspection (not yet)".
   - sizing from `pvesh get /nodes/<node>/qemu/<id>/rrddata --timeframe month` (fall back to week/day; under 24h of data = keep current size); show p95/max and a confidence label.
   - `scan` ranks all VMs on the node by verdict and RAM/disk saved, one-line why each.
4. Unit tests that run on any linux box using fixture JSON/text for qm config, pvesh rrddata and pvesm output (no real PVE needed). Tests must probe real logic on fixtures, not just "binary exists".

## Hard rules
- You have NO access to any Proxmox server. Do not ssh to hex or any PVE host. Nothing runs against a real host in this slice.
- Never write anything destructive. preflight/scan are read-only by design: no qm/pct set/create/destroy, no snapshot, no mount.
- No secrets anywhere (repo, README, logs, chat).
- Commit locally as you go. Do NOT push and do NOT create a GitHub repo; Fred approves pushes.
- Test VMs (600-603 on hex) are being built by Proxmox Expert; real runs happen later through it, not you.

## When done
Write STATUS.md: what's implemented, what's stubbed, how to run tests, test output summary, open questions. Then stop and wait.
