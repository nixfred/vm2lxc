<div align="center">

```
                ┌─────────────┐   snapshot    ┌─────────────┐
                │   QEMU VM   │ ───────────▶  │  read-only  │
                │ (untouched) │               │    view     │
                └─────────────┘               └──────┬──────┘
                       ▲                             │ copy
              undo     │                             ▼
         (VM comes     │                      ┌──────────────┐
            back)      └───────────────────── │ LXC container│
                                              └──────────────┘
```

# vm2lxc

### Turn a Proxmox VM into an LXC container, and never touch the VM.

Plain bash and `jq`. No AI in the tool. No network access. MIT licensed.

<table>
  <tr>
    <td align="center"><b>Source disks written</b><br><code>0</code> (sha256-checked)</td>
    <td align="center"><b>Real-host round trips</b><br>4 guest types<br>PVE 9.2, LVM-thin</td>
    <td align="center"><b>Tests</b><br>370, 0 skipped</td>
    <td align="center"><b>Safety rails</b><br>29, each mutation-tested</td>
    <td align="center"><b>Status</b><br>alpha</td>
  </tr>
</table>

<sub><a href="#the-30-second-version">30 seconds</a> · <a href="#why-this-exists">Why</a> · <a href="#quick-start">Quick start</a> · <a href="#how-a-conversion-works">How it works</a> · <a href="#commands">Commands</a> · <a href="#the-safety-model">Safety</a> · <a href="#proven-on-real-hardware">Proof</a> · <a href="#what-it-handles">Scope</a> · <a href="#limitations">Limits</a> · <a href="#development">Develop</a></sub>

</div>

---

> **Alpha, and honest about it.** It has been run for real on **one** Proxmox VE 9.2 host with LVM-thin
> storage, against four disposable test VMs (Debian 12 cloud image, a two-disk Debian, Alpine, Ubuntu 24.04 with
> Tailscale). ZFS is implemented and tested against a fake only. [What is and is not proven](#proven-on-real-hardware)
> is spelled out below. Read the [limitations](#limitations) before pointing it at a VM you care about.

## The 30-second version

```console
$ vm2lxc scan 600 601 602 603
  #   VMID   NAME                      STATE    VERDICT  RAM now -> rec     SAVED    DISK
  1   601    vm2lxc-test-ubu24-ts      running  GREEN    2048M -> 1216M     832M     12G
  2   600    vm2lxc-test-deb12-svc     running  GREEN    1024M (keep)       -        10G
  ...

$ vm2lxc convert 600 --ctid 610 --yes --start
Mounted read-only:
  scsi0    rootfs  ext4   /dev/loop0p1
Guest checks: 12 ran, 0 pending.
  [INFO]   guest OS: Debian GNU/Linux 12 (bookworm) (detected ostype: debian)
  [YELLOW] cloud-init is installed: it is disabled in the copy so it cannot rewrite the network
  note: net0: interface 'eth0', MAC BC:24:11:CE:87:A6, bridge vmbr0
  note: the guest's netplan matches the NIC by MAC address (cloud-init does this); a container's veth has
        no permanent MAC, so the copy's netplan is changed to match by interface name
Building the container 610 ...
Done. Container 610 ("vm2lxc-test-deb12-svc") was created from VM 600.
  The container is RUNNING; VM 600 is stopped and set not to start at boot.
  To go back:  vm2lxc undo 610 --yes   (destroys the container, starts the VM again)
  NEVER start VM 600 while container 610 runs: they share one MAC address.

$ pct exec 610 -- ip -br -4 addr show eth0
eth0@if105       UP             10.0.0.228/24

$ vm2lxc undo 610 --yes
Undone. Container 610 is gone and VM 600 is running again.
```

*Real output from a Proxmox VE 9.2.28 host (trimmed). 20 seconds, including the graceful VM shutdown.*

## Why this exists

Proxmox has no one-button VM-to-LXC path. The community tools that exist do the mechanical copy well, but the ones
we studied each make some of these trade-offs: they stop the VM and mount its disk **read-write**, tar a **running**
system, silently drop data with glob excludes (`*.gz`, `*.sql`, `/var/lib/docker`), give the container a new MAC, or
offer no real rollback. vm2lxc is built around the opposite defaults:

| Principle | What it means here |
|---|---|
| **The source is never modified** | Work happens on a storage-level snapshot, mounted read-only (`ro,noload`). The VM is only ever shut down, set to not autostart, and (by `undo`) started again. |
| **Know before you convert** | A red / yellow / green verdict with plain-words reasons, from the VM's config *and* from inside its disk (12 guest checks), before anything is created. |
| **Everything it creates, it can remove** | A write-ahead journal, a signal trap, `cleanup` for a crash, and `undo` for a finished conversion. |
| **Nothing silently lost** | No glob excludes on data. A second data filesystem that would not be copied refuses the conversion instead of dropping it. |
| **Fail safe, not clever** | One door for every host command: an allowlist of exact argument shapes. Identity is re-checked before anything is destroyed. |
| **Deterministic** | No AI, no heuristics you cannot read. A few thousand lines of plain bash you can audit in an afternoon. |

## Quick start

**Requirements:** a Proxmox VE 8.x or 9.x node, run as root. `bash` 4.4+, `jq`, `tar`, util-linux, and the PVE
tools already on the node (`qm`, `pct`, `pvesm`, `lxc-usernsexec`). `lvm2` for LVM-thin, `zfsutils` for ZFS.
No installer: it runs from a checkout.

```bash
git clone https://github.com/nixfred/vm2lxc.git && cd vm2lxc
./vm2lxc --help
```

**Try it with no Proxmox at all.** The repository ships canned data, including real output captured from a PVE 9.2
host. Fixture mode is loudly labelled and can never execute anything:

```bash
VM2LXC_FIXTURE_DIR=$PWD/tests/fixtures/pve9-real ./vm2lxc scan 600 601 602 603
VM2LXC_FIXTURE_DIR=$PWD/tests/fixtures/pve9-real ./vm2lxc convert 603 --ctid 900
```

**On a real node.** Read-only first, always; every command that changes anything shows its plan and does nothing
until you add `--yes`:

```bash
./vm2lxc scan 600 601            # name the VMs: scan never reads the others
./vm2lxc preflight 600           # verdict + reasons + sizing from the VM's own history
./vm2lxc convert 600 --ctid 610  # the plan: nothing is executed
./vm2lxc convert 600 --ctid 610 --yes            # build the container, leave it STOPPED
pct start 610                                    # cut over when you are ready
./vm2lxc undo 610 --yes                          # changed your mind: container gone, VM back
```

## How a conversion works

```
  plan  (read-only)  verdict, container id, hostname, sizes, the VM's MAC and bridge, every step
  --yes
  ┌ PHASE A ─ the same engine as `inspect`: write-ahead journal, run lock, signal traps ─────────────┐
  │  vm-stop     graceful shutdown (stop-and-copy): the snapshot is then consistent                  │
  │  vm-onboot   autostart off: a VM that boots beside its container is the worst outcome           │
  │  snapshot    storage-level snapshot of every source volume (thin LV, or ZFS)                     │
  │  mount       read-only: loop device, ext4 ro,noload,nodev,nosuid,noexec                          │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘
  GATE   find the guest root, run the 12 guest checks.   RED  =>  tear down, restart the VM, stop
  ┌ PHASE B ─ decided from what the guest says ──────────────────────────────────────────────────────┐
  │  tar-create  archive the boot filesystem (and each extra disk): --numeric-owner --xattrs --acls  │
  │  ct-create   pct create: UNPRIVILEGED, the VM's exact MAC, tagged vm2lxc-<run>, created STOPPED  │
  │  ct-fixup    in the container's COPY only: fstab, cloud-init, netplan, console, kernel mounts    │
  │  ct-copy     each extra disk into its mount point, at the path the guest's fstab gives it        │
  │  ct-start    only with --start                                                                   │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘
  COMMIT   the container and the VM's stopped state are KEPT; the journal says COMMITTED
  TEARDOWN everything else (snapshot layer, staged archives) is removed, newest first
```

If **anything** fails, or you press Ctrl-C, or the ssh session drops, the same journal tears it all down, the
half-built container is destroyed, and the VM is started again if it was running. If the tool itself is killed,
`vm2lxc cleanup --yes` finishes the job from the journal.

What the container copy gets, and why:

| Fix-up (copy only) | Why |
|---|---|
| fstab lines naming the VM's disks (`UUID=`, `LABEL=`, `PARTUUID=`, `/dev/...`) commented out; a `.vm2lxc-orig` backup stays | the disks are gone; a missing device would hang boot |
| `cloud-init` disabled | it must not rewrite the network, hostname or SSH keys on first boot |
| netplan `match: macaddress:` + `set-name:` removed (cloud-init's exact shape only) | a container's veth has no permanent MAC, so `networkd` would leave the NIC unmanaged (found on real hardware) |
| `serial-getty@ttyS0` and the kernel config/debug/tracing mounts masked | they can never work in an unprivileged container |
| `machine-id`, SSH host keys, hostname **kept** | it is the same machine, moved |

## Commands

| Command | What it does | Changes the host? |
|---|---|---|
| `preflight <vmid>` | verdict (exit 0/10/20), disk and NIC plan, RAM/CPU sizing from the VM's RRD history | no |
| `scan [vmid...]` | ranks VMs by verdict and RAM you would save | no |
| `inspect <vmid>` | plan; with `--yes` snapshots, mounts read-only, runs the 12 guest checks, tears down | only with `--yes` |
| `convert <vmid>` | plan; with `--yes` builds a **new** container from the VM | only with `--yes` |
| `undo <ct>` | shows what it will do; with `--yes` destroys the container and starts the VM again | only with `--yes` |
| `cleanup` | lists, and with `--yes` removes, what a crashed run left behind | only with `--yes` |

| Option | Meaning |
|---|---|
| `--yes` | really execute (`inspect`, `convert`, `undo`, `cleanup`). Without it they only print a plan. `--dry-run` beats `--yes`. |
| `--ctid N` | the container id to create (default: the next free id) |
| `--start` | start the container when done (the cutover); default is to leave it stopped |
| `--privileged` | create a privileged container (default: unprivileged) |
| `--memory MB`, `--cores N`, `--hostname NAME` | override what is taken from the VM |
| `--node NAME` | PVE node name (default: this host's short name) |

| Exit | Meaning |
|---|---|
| `0` / `10` / `20` | `preflight`: green / yellow / red |
| `64` | bad usage |
| `65` | the VM's disks cannot be planned (unsupported storage, unreadable path) |
| `66` | VM not found, or nothing to undo |
| `69` | environment problem (not root, not a PVE node, missing tool) |
| `70` | the plan cannot be executed (storage type not supported yet) |
| `77` | a safety rail refused an action, or a RED verdict stopped `convert` |

## The safety model

A tool that runs as root on a hypervisor and destroys things has to be built as if every line will meet a bad
day. The full designs, with failure matrices, are in [`docs/snapshot-layer.html`](docs/snapshot-layer.html) and
[`docs/convert.html`](docs/convert.html). In short:

1. **The source is never written.** It is only the origin of a snapshot. A VM's only changes are a graceful
   shutdown, `onboot 0`, and (by `undo`) start and `onboot 1`. Its disk was sha256-checked before and after a real conversion.
2. **One door.** Every command that changes the host goes through `host_cmd` in `lib/hostexec.sh`, an allowlist of
   *exact argument shapes*. `qm` is limited to this run's VM, `pct` to this run's container, `pct create` to a fixed
   option set with every value pattern-checked, `tar` to two forms. Anything else is refused (exit `77`) before it runs.
3. **Only our objects, re-verified before every destroy.** ZFS stamp and clone origin, LVM tag and origin, and the
   container's per-run tag. A mismatch refuses and leaves the object alone. A pre-existing object with the wanted name is never adopted.
4. **The guest is hostile until proven otherwise.** It is read through a chroot-style resolver: an absolute symlink
   in the guest (`/etc -> /etc`) is re-rooted under the guest, never followed onto the host. Fix-ups never run guest
   binaries; they are done by host tools with pinned expressions inside the unprivileged user namespace. A guest
   symlink to a host file is neither edited nor copied in (tested for fstab, netplan, cloud-init and the unit masks).
5. **A write-ahead journal that is honest.** A step is on disk as `PENDING` *before* it runs; a step that cannot be
   recorded is not performed; a journal that cannot be updated keeps the run open instead of pretending.
6. **"Could not tell" is never "gone".** A probe that times out or errors is an error; teardown stops there and
   `cleanup` retries.
7. **Never two live copies.** `undo` never starts the VM while the container runs; the VM is set not to autostart.
8. **Nothing silently lost.** No glob excludes. A data filesystem that would not be copied refuses the conversion.
9. **Signals cannot break the cleanup.** `SIGINT`, `SIGTERM`, `SIGHUP` and `SIGPIPE` tear down, and are ignored
   while tearing down. `SIGKILL` is recovered by `cleanup`.
10. **Fixed trust anchors.** Tools must resolve to a system directory (a hostile `PATH` cannot substitute one), the
    run root is always `/run/vm2lxc`, mount options must be *exactly* the read-only set.

## Proven on real hardware

Evidence matters more than claims. A Proxmox VE 9.2.28 host (LVM-thin), four disposable test VMs; each was
converted into a container and undone again, and the host was compared with a baseline after every run (no snapshot,
loop device, mount, staging directory or open journal left).

| Guest | Result |
|---|---|
| **Debian 12** cloud image (netplan, cloud-init) | 14-20 s. Source disk sha256 identical before and after. Container fully booted (`running`, 0 failed units); `eth0` UP with a DHCP address under the VM's MAC; gateway and DNS reachable. `undo` restarted the VM. |
| **Debian 12, two disks** | the second disk became `mp0` at `/home` (read from the guest's fstab) as a separate volume; **every file sha256-identical** to the source disk. |
| **Alpine 3.24** (OpenRC, no systemd) | booted, OpenRC services started, DHCP address, gateway reachable. |
| **Ubuntu 24.04 + Tailscale** | converted but **deliberately not started** (a second copy of the node must not come online); config, copied Tailscale state, netplan change and fix-ups checked in the stopped container. |

**Three bugs only real hardware could show**, all fixed with regression tests, and why this table is worth reading:

| Found on the real host | Cause |
|---|---|
| container booted but `eth0` stayed DOWN | cloud-init's netplan matches the NIC by *permanent* MAC; a veth has none, so `networkd` called it "unmanaged" |
| copying the second disk failed on `lost+found` | the new volume already has its own `lost+found`, owned by real root, which an unprivileged namespace may not touch (the failure rolled back perfectly) |
| Ubuntu 24.04 refused as "iSCSI/multipath configured" | the cloud image ships the packages and a stock `multipath.conf`; "installed" is not "in use" |

Also: `inspect` (the read-only engine underneath) was crash-tested with 61 injected `SIGKILL`/`SIGTERM`/`SIGHUP`
runs on the same host; an independent fresh-context review found 12 issues, all fixed (rails R1-R21).

**370 tests, 0 skipped**, `shellcheck` clean. A stateful fake of `zfs`, LVM, `losetup`, `mount`, `qm` and `pct`
drives every row of the failure matrix. Every safety rail was **mutation-tested**: revert it, and a test goes red
(more than 80 reversals; the few that first survived exposed real gaps in the tests, and were closed).

## What it handles

| | Status |
|---|---|
| **LVM-thin** storage | verified on a real host |
| **ZFS zvols** | implemented, tested against a fake only; **never run on real hardware** |
| dir / qcow2, NFS, Ceph, thick LVM | not yet; reported with a plain reason |
| ext2/3/4 | verified (`ro,noload,nodev,nosuid,noexec`) |
| xfs, btrfs | implemented, not yet mounted for real |
| Debian, Ubuntu, Alpine guests | verified |
| other distros (Arch, Fedora/RHEL family, ...) | detected; expected to work, **not tested** |
| multi-disk VMs | boot disk to rootfs, each extra disk to a mount point (one filesystem per disk) |
| cloud-init / netplan, ifupdown, networkd, OpenRC | handled |
| guests with Docker/Podman, NFS server, DKMS modules, nested virt, guest LVM/LUKS/RAID, iSCSI/multipath **in use** | refused (RED), with the reason |
| snapd, network mounts, ids above 65535, Tailscale | allowed with a yellow warning |

## Limitations

- **Alpha, one real host.** Only PVE 9.2.28 with LVM-thin has run for real. ZFS and PVE 8 are untested on hardware.
- **DHCP guests keep their MAC, not necessarily their IP.** In the test, the container got a different lease from
  the VM. The address is the DHCP server's decision; a reservation by MAC pins it. A guest with a static address keeps it.
- **Stop-and-copy only.** The VM is shut down for the copy; there is no `--live` two-pass mode yet.
- **Tailscale:** the node state is copied and the output warns loudly, but `undo` does not copy state back into the VM.
  The VM and the container are *one* node: never run both.
- **Privileged containers** (`--privileged`) are implemented but untested on hardware.
- The container keeps the guest's kernel and initramfs packages (unused). Staging needs free space in `/var/tmp`
  about the size of the guest.
- **Everything written in the container after the conversion is lost by `undo`.** It does not copy data back.
- No interactive UI, vzdump safety backup, or soak-period reminder yet.

## Roadmap

1. A real ZFS run, XFS/btrfs guests, other distros.
2. `--live` two-pass copy (bulk from the snapshot, delta at cutover).
3. A verified `vzdump` backup before anything is offered for removal; a soak period; post-conversion comparison of services and ports.
4. Tailscale hand-back on `undo`.

## Development

```bash
make lint      # shellcheck -x on everything
make test      # bats --recursive tests   (bats --jobs 4 --recursive tests is faster, needs GNU parallel)
```

Needs `bash` 4.4+, `jq`, `shellcheck`, `bats`, and optionally `strace`. No Proxmox host needed: the tests run the
real code against canned data and a fake storage host. See [CONTRIBUTING.md](CONTRIBUTING.md).

| Path | What it is |
|---|---|
| `vm2lxc` | entry script, flag parsing, command dispatch |
| `lib/pve.sh` | the **only** file that reads the host (`qm config`, `pvesh get`, `pvesm`), with a fixture mode |
| `lib/qmconf.sh`, `lib/storage.sh`, `lib/sizing.sh` | `qm config` and `pvesm status` parsing; RRD statistics |
| `lib/findings.sh`, `lib/checks_cfg.sh`, `lib/checks_guest.sh`, `lib/guestfs.sh` | the verdict engine, the config checks, the 12 guest checks, and the chroot-style guest reader |
| `lib/preflight.sh`, `lib/scan.sh` | the read-only commands |
| `lib/snapplan.sh` | the pure snapshot plan |
| `lib/hostexec.sh` | **the only file that may change the host**: allowlist, journal, lock, handlers, teardown |
| `lib/inspect.sh`, `lib/convert.sh` | `inspect`, `cleanup`, `convert`, `undo` |
| `docs/snapshot-layer.html`, `docs/convert.html` | the designs, rails and failure matrices |
| `tests/` | 15 bats files, a stateful fake host, stub PVE binaries, two fixture hosts |

## FAQ

**Will it delete my VM?** No. It never deletes a VM and never writes its disks. After `convert` the VM is stopped and
set not to autostart; `undo` starts it again. You decide if and when to remove it.

**What if it crashes halfway?** The journal records every step *before* it runs. `vm2lxc cleanup --yes` removes
exactly what the journal names, after verifying each object is ours.

**Can I convert a running VM?** It shuts the VM down gracefully first (stop-and-copy), so the copy is consistent.
If the VM will not stop, nothing is created.

**Why is the container created "unmanaged"?** So Proxmox does not rewrite the guest's own network configuration; the
container gets the VM's exact MAC and the interface name the guest's config already uses.

**Does it phone home or use AI?** No. No network access, no AI. The decisions are plain, readable bash.

## Security

Anything that lets the tool write to a source volume, destroy something it did not create, or follow a guest path
onto the host is a security issue: see [SECURITY.md](SECURITY.md).

## Credits

vm2lxc is a fresh implementation, but it stands on ideas first worked out in two MIT-licensed projects, and the
author is grateful to their authors: [ArMaTeC/lxc-to-vm](https://github.com/ArMaTeC/lxc-to-vm) (`vm-to-lxc.sh`:
host-side offline conversion, the exclude list, per-distro network fix-ups) and
[thushan/proxmox-vm-to-ct](https://github.com/thushan/proxmox-vm-to-ct) (the first-boot cleanup unit and the
boot-package cleanup list). No code has been copied from either; see [NOTICE](NOTICE).

## License

[MIT](LICENSE).
