# vm2lxc status

Updated 2026-11-17 (Larry:gus). Local repo `main`; remotes `forgejo` (private), `nas`, and `origin` = GitHub (**public** since 2026-11-17).
Front page: `README.md`. Designs: `docs/snapshot-layer.html` (rails R1-R21) and `docs/convert.html` (rails R22-R29).

## TL;DR

- **Everything in the original scope now exists and works**: `preflight`, `scan`, `inspect`, `cleanup`, the 12 guest
  checks, `convert` and `undo`. There are no stubs left.
- **370 tests pass, 0 skipped**, shellcheck clean. Every safety rail has a test that goes red when the rail is
  reverted (more than 80 reversals over the project).
- **Run for real** on a Proxmox VE 9.2.28 host (LVM-thin) against the four disposable test VMs 600-603, each converted
  into a container and undone again: Debian 12 cloud image, a two-disk Debian, Alpine, Ubuntu 24.04 with Tailscale.
  After every run the host matched its baseline (no snapshot LV, loop device, mount, staging directory, open journal).
- **ZFS has never run on real hardware** (the test host has no ZFS storage in use): fake only.
- Grok 4.7 produced no review in four attempts (below); an independent fresh-context box review replaced it.

## What exists

| Command | State | Notes |
|---|---|---|
| `preflight <vmid>` | real-host verified | verdict (exit 0/10/20), disk and NIC plan, RAM/CPU sizing from RRD |
| `scan [vmid...]` | real-host verified | ranks by verdict then RAM saved; ids restrict it |
| `inspect <vmid>` | real-host verified (LVM-thin) | plan; `--yes` snapshots, mounts read-only, runs the 12 guest checks, tears down |
| `cleanup` | real-host verified | lists, and with `--yes` removes, what a crashed run left; does not mistake a committed conversion for a crash |
| `convert <vmid>` | real-host verified (LVM-thin, 4 guest types) | stop-and-copy; unprivileged container; the VM's MAC; extra disks as mount points; `--start` for the cutover |
| `undo <ct>` | real-host verified | destroys the container (only with its run tag), starts the VM if it was running; never while the container runs |

## Real-host evidence (2026-11-17, hex, PVE 9.2.28, test VMs 600-603 only)

- **Debian 12 cloud image (VM 600 -> CT 610):** 14-20 s. The source disk's sha256 was identical before and after. The
  container booted fully (`running`, no failed units), `eth0` UP with a DHCP address under the VM's MAC, gateway and
  DNS reachable. `undo` restarted the VM (it was running before).
- **Debian 12, two disks (VM 603 -> CT 613):** the second disk became `mp0` at `/home` (path read from the guest's
  fstab) as a separate ext4 volume; every file is sha256-identical to the source disk; network up.
- **Alpine 3.24 (VM 602 -> CT 612):** booted on OpenRC, services started, DHCP address, gateway reachable.
- **Ubuntu 24.04 with Tailscale (VM 601 -> CT 611):** converted but **not started** (a second copy of the node must
  not come online). Config, the copied Tailscale state, the netplan change and the fix-ups were checked inside the
  stopped container; `undo` restarted the VM.
- A first conversion of VM 600 with the VM already stopped checked that the source disk is bit-identical, and a real
  `undo` of a container that had been started by hand worked.
- **Three bugs only the real host showed**, all fixed with regression tests and mutation checks:
  1. netplan written by cloud-init matches the NIC by `PermanentMACAddress`; a veth has none, so `networkd` left it
     "unmanaged" and the NIC stayed DOWN (fix: remove exactly that shape in the copy, keep a backup);
  2. copying the second disk failed on `lost+found`: the new volume's own one is owned by real root (fix: exclude the
     source's; the failure itself rolled back perfectly);
  3. Ubuntu 24.04 was refused as "iSCSI/multipath configured": the cloud image ships the packages and a stock
     `multipath.conf` (fix: RED only for real use; refused twice before the check was tight enough).
- Earlier (read-only engine): 61 injected `SIGKILL`/`SIGTERM`/`SIGHUP` runs recovered; a real PBS backup job locking the
  test VMs led to rail R15; an independent review found 12 issues, all fixed (R16-R21).

## What is NOT proven

- **ZFS**, including the kernel-name `/dev/zdN` handling, has only run against the fake.
- **Proxmox VE 8.x**, qcow2/dir/Ceph storage, **privileged containers**, XFS/btrfs guests, distros other than Debian,
  Ubuntu and Alpine: not run.
- **DHCP guests keep their MAC, not necessarily their IP.** VM 600's container got `10.0.0.228` while the VM has
  `.227`. The address is the DHCP server's decision (a reservation by MAC pins it).
- **Tailscale:** state is copied and the output warns, but `undo` does not copy state back into the VM.
- The container keeps the guest's kernel and initramfs packages (unused). Staging needs free space in `/var/tmp`
  about the size of the guest. One filesystem per extra disk. Everything written in the container after the
  conversion is lost by `undo`.
- Not built: `--live` two-pass copy (D2), the interactive UI (D7), the sizing choice (D8), the verified vzdump backup
  (D9), the soak period (D10), the post-conversion compare (D12).

## Grok 4.7: four attempts, zero findings

1. Plan mode, 22 min: died on a compound shell command not covered by my `--allow` rules (headless cannot ask).
2. 45 min in a bwrap + strict sandbox: killed by my cap, 30 tool calls, nothing written.
3. 40 min, focused brief, `--effort medium`: killed by the cap, 17 tool calls, nothing written.
4. 8 min, 13 KB inline, `--effort low`: timed out, 0 bytes.

Measured from Grok's own event log: 99-100% of every session was `streaming_reasoning`, tool execution about 0 seconds,
and `--effort` made no measurable difference. So it is the model deliberating without converging, not the sandbox.

## Open questions

1. **GitHub visibility: public, as chosen by Fred on 2026-11-17, against the advice to scrub first.** The full history is public,
   including the internal planning notes (`docs/BRIEF.md`, `docs/KICKOFF.md`) that name internal bots and the VM ids the
   tool is told never to touch (110, 111, 120, 121, 301, 351), private-range LAN addresses, and an ssh alias. A survey
   of all 23 commits found no secrets, no tailnet name and no email addresses (gitleaks clean). Forgejo stays private
   (the server enforces it). If Fred later wants the notes gone from history, that means a fresh public repo.
2. **jq on PVE 8.** PVE 9.2 ships jq 1.7 (fine). PVE 8 ships 1.6; the code sticks to 1.6 features but only 1.7 has run.
3. **A real ZFS run** needs a PVE host with a ZFS-backed VM.

## Left on the test host (hex)

`/root/vm2lxc-src` (the deployed source) and `/var/lib/vm2lxc/runs/*` (78 small CLOSED/COMMITTED journals, the audit
trail of the real runs). Both are mine and safe to remove, and both are deliberately kept.
The three scratch files I had left (`/root/vm600-disk0.sha.before`, `/root/mountwatch.log`, `/root/sweep.out`) were
deleted on 2026-11-17 at Fred's word, after checking nothing had them open; `vm2lxc cleanup` on hex then reported no
unfinished run. The four test VMs are running; no test containers (610-613) exist.

## Publishing

`forgejo` = `ssh://for-nixfred/nixfred/vm2lxc.proxmox.git` (private on the server), `nas` =
`ssh://pi@10.0.0.9/srv/git/vm2lxc.proxmox.git`, `origin` = `https://github.com/nixfred/vm2lxc.git` (public, MIT detected by GitHub).
