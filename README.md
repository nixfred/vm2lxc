<div align="center">

# vm2lxc

**Look inside a Proxmox VM's disks without ever touching them, and (soon) convert it into an LXC container, safely.**

Plain bash and `jq`. No AI in the tool. No network access. MIT licensed.

<table>
  <tr>
    <td align="center"><b>Status</b><br>alpha</td>
    <td align="center"><b>Proxmox VE</b><br>9.2 verified<br>8.x untested</td>
    <td align="center"><b>Storage</b><br>LVM-thin verified<br>ZFS: fake only</td>
    <td align="center"><b>Tests</b><br>283, 0 skipped</td>
    <td align="center"><b>Converts VMs?</b><br>not yet</td>
  </tr>
</table>

</div>

---

> **Read this first.** vm2lxc is a work in progress. Today it can **assess** a VM (`preflight`, `scan`),
> **mount its disks read-only from storage snapshots and clean up after itself** (`inspect`, `cleanup`),
> and that is all. `convert` and `undo` are stubs that print "not implemented". Nothing here modifies a VM,
> its disks or its configuration. It has been run for real on **one** Proxmox VE 9.2 host, against four
> disposable test VMs.

## Why

Proxmox has no one-button VM-to-LXC path. The community tools that exist do the mechanical copy well, but
the ones we studied each make some of these trade-offs: they stop the VM and mount its disk **read-write**,
tar a **running** system, silently drop data with glob excludes (`*.gz`, `*.sql`, `/var/lib/docker`), give the
container a new MAC, or offer no real rollback. vm2lxc is built around the opposite defaults:

| Principle | What it means here |
|---|---|
| **The source is never modified** | Work happens on a storage-level snapshot, mounted read-only (`ro,noload`). |
| **Know before you convert** | A red / yellow / green verdict with plain-words reasons, before anything is touched. |
| **Everything it creates, it removes** | A write-ahead journal, a signal trap, and a `cleanup` command that recovers from a crash. |
| **Fail safe, not clever** | One door for every host command, an allowlist of exact argument shapes, identity re-checked before any destroy. |
| **Deterministic** | No AI, no heuristics you cannot read. Plain bash you can audit in an afternoon. |

## What works today

| Command | What it does | Changes the host? | Verified |
|---|---|---|---|
| `vm2lxc preflight <vmid>` | Verdict, disk and NIC plan, RAM/CPU sizing from the VM's own history | **No** (read-only) | real PVE 9.2 + fixtures |
| `vm2lxc scan [vmid...]` | Ranks VMs on the node by verdict and RAM you would save | **No** (read-only) | real PVE 9.2 + fixtures |
| `vm2lxc inspect <vmid>` | Shows the plan. With `--yes`: snapshots, mounts read-only, looks inside, tears down | Only with `--yes`; only `vm2lxc-` objects it records and removes | real PVE 9.2 (LVM-thin) |
| `vm2lxc cleanup` | Lists, and with `--yes` removes, anything a crashed run left behind | Only with `--yes`; only what its own journals name | real PVE 9.2 |
| `vm2lxc convert`, `undo` | **Not implemented** | - | - |

## Quick start

**Requirements:** Proxmox VE 8.x or 9.x, run as root on the node. `bash` 4.4+, `jq`, and util-linux
(`losetup`, `lsblk`, `flock`). `lvm2` for LVM-thin storage, `zfsutils` for ZFS. No installer yet:

```bash
git clone <repository-url> && cd vm2lxc
./vm2lxc --help
```

**Try it with no Proxmox at all.** The repository ships canned data (including real output captured from a
Proxmox VE 9.2 host). Fixture mode is loudly labelled in the output and can never execute anything:

```bash
VM2LXC_FIXTURE_DIR=$PWD/tests/fixtures/pve9-real ./vm2lxc scan 600 601 602 603
VM2LXC_FIXTURE_DIR=$PWD/tests/fixtures/pve9-real ./vm2lxc preflight 603
VM2LXC_FIXTURE_DIR=$PWD/tests/fixtures/pve9-real ./vm2lxc inspect 603
```

**On a real node** (read-only first, always):

```bash
./vm2lxc scan 600 601            # name the VMs: scan never reads the others
./vm2lxc preflight 601           # verdict + reasons
./vm2lxc inspect 601             # shows the plan, executes nothing
./vm2lxc inspect 601 --yes       # carries it out, then tears it all down
```

## Commands

### `preflight <vmid>`: should this VM be converted?

Reads `qm config`, the storage list, the PVE version and the VM's RRD history, and prints a verdict:

```
vm2lxc preflight 603  "vm2lxc-test-deb12-2disk"
VERDICT: GREEN (provisional)
  No blockers in the VM config. 12 guest-internal checks still need disk inspection (not implemented yet), so this is not a go-ahead.

Findings
  [info]   2 disks map to scsi0 -> rootfs, scsi1 -> mp0 (extra disks become container mount points)
Disks
  scsi0     local-lvm (lvmthin)          10G     -> rootfs  (boot disk)
  scsi1     local-lvm (lvmthin)          8G      -> mp0
```

Exit codes: `0` green, `10` yellow, `20` red. The verdict is **provisional** while any guest-internal check
(Docker, kernel modules, NFS server, cloud-init, snap, ...) is pending: a green today means "nothing in the
VM config blocks it", not "go ahead".

What turns a VM red or yellow today: PCI passthrough, Windows or non-Linux `ostype`, appliance names
(pfSense, TrueNAS, ...), USB or virtiofs passthrough, custom QEMU `args`, a TPM, raw host disks, a template or
locked VM, an unsupported PVE version, and storage that vm2lxc cannot snapshot yet (tagged `(v1 limit)` so it
is not mistaken for a fault of the VM).

### `scan [vmid...]`: which VMs are worth converting?

Ranks by verdict, then by RAM saved, with a one-line reason each. Give VM IDs to restrict it; without them it
reads every VM on the node.

```
  #   VMID   NAME                  STATE    VERDICT  RAM now -> rec     SAVED    DISK    WHY
  1   601    vm2lxc-test-ubu24-ts  running  GREEN    2048M -> 1216M     832M     12G     no blockers in the VM config (sizing confidence: low)
  2   600    vm2lxc-test-deb12-svc running  GREEN    1024M (keep)       -        10G     no blockers (under 24h of RRD history, keeping size)
```

Sizing comes from the VM's own `rrddata`: p95 and max memory, a confidence label, and a choice of sizes
(lean / recommended / keep). **Under 24 hours of history it refuses to guess** and keeps the current size.
Sparse history, or memory pinned near the VM's RAM (a guest that may not report real usage), lowers the
confidence and says why.

### `inspect <vmid>`: look inside, change nothing

Without `--yes` it prints the plan and stops. With `--yes` it executes it:

```
Mounted read-only:
  scsi0    rootfs  ext4   /dev/loop0p1  ->  /run/vm2lxc/r179489892433b8/scsi0/loop0p1
  scsi1    mp0     ext4   /dev/loop1  ->  /run/vm2lxc/r179489892433b8/scsi1/loop1
  skipped /dev/loop0p15 (vfat): not a filesystem vm2lxc mounts
Guest root: /run/vm2lxc/r179489892433b8/scsi0/loop0p1
```

(Real output from a test VM.) Then it tears everything down, whatever happens.

### `cleanup`: recover from a crash

If a run was killed (`SIGKILL`, a power cut), its objects and its journal remain. `cleanup` lists them;
`cleanup --yes` removes exactly what the journals name and verifies each object is ours before touching it.

### Options and exit codes

| Option | Meaning |
|---|---|
| `--yes` | Really execute (`inspect`, `cleanup`). Without it they only show a plan. |
| `--dry-run` | Show what would happen. Beats `--yes`. |
| `--node NAME` | PVE node name (default: this host's short hostname). |
| `--no-tui`, `--answers FILE` | Accepted for the future `convert`; unused so far. |

| Exit | Meaning |
|---|---|
| `0` / `10` / `20` | preflight: green / yellow / red |
| `64` | bad usage |
| `65` | the VM's disks cannot be planned (unsupported storage, unreadable path) |
| `66` | VM not found |
| `69` | environment problem (not root, not a PVE node, missing tool) |
| `70` | not implemented yet |
| `77` | a safety rail refused an action |

## The safety model

`inspect --yes` is the first code in the project that can destroy anything on a hypervisor, so it is built
as if every line will eventually meet a bad day. The full design, with the failure matrix, is in
[`docs/snapshot-layer.html`](docs/snapshot-layer.html). In short:

1. **The source volume is only ever the origin of a snapshot.** It is never opened, written, renamed or edited.
2. **One door.** Every command that changes the host goes through `host_cmd` in `lib/hostexec.sh`, an
   allowlist of *exact argument shapes*. Everything else is refused (exit `77`) before it runs.
   `preflight` and `scan` do not even reference that file (a test enforces it).
3. **Only our objects.** Names must match `vm2lxc-<vmid>-<run>-<disk>`; only objects recorded in *our own
   journal* are touched; nothing is ever found by scanning.
4. **Identity is re-checked before every destroy**: ZFS `vm2lxc:run` stamp and clone origin, LVM tag and
   origin. A mismatch refuses and leaves the object alone.
5. **Never a dangerous flag.** No `-r`, `-R`, `-f`, no `umount -l`. A snapshot with dependants fails safe.
6. **Mounts are read-only or they do not happen**, only on our own devices, only under the run root, with
   `nodev,nosuid,noexec`, and `noload` (ext4) or `norecovery` (xfs) so even the snapshot's journal is not replayed.
7. **A pre-existing object with the name we want is never adopted** (and never destroyed later).
8. **Write-ahead journal.** A step is on disk as `PENDING` *before* it runs, so a crash always leaves a trail.
9. **Teardown stops at the first failure** rather than destroying what a still-mounted filesystem sits on.
10. **Signals cannot break the cleanup.** `SIGINT`, `SIGTERM` and `SIGHUP` tear down; while tearing down they
    are ignored. `SIGKILL` is recovered by `cleanup`.
11. **Every host command is time-bounded**, children do not inherit the run lock, and names that could be
    read as command-line options are refused.
12. **A locked VM is never snapshotted.** A `lock` (backup, rollback, migrate, ...) means something is working on its disks.
13. **Nothing executes without `--yes`**, never in fixture mode, and never without root on a real node.

## How `inspect` works

```
read   qm config, pvesm path <storage:volume>             (read-only)
plan   a pure description of what would happen            (printed first, always)
--yes  take the run lock, open the journal, install the trap
         1. snapshot   every source volume (ZFS: one atomic command)
         2. read-only  ZFS: a stamped clone   |  LVM-thin: lvchange -pr, activate -ay -K
         3. loop       LVM-thin: losetup -r -f --show -P   (read-only, scans partitions)
         4. mount      ext2/3/4, xfs, btrfs  read-only under /run/vm2lxc/<run>/
         5. find the guest root, run the guest checks
always   unmount, detach, remove, in reverse order, verifying identity first, then close the journal
```

### Supported storage and filesystems

| | Status |
|---|---|
| **LVM-thin** | Verified on a real PVE 9.2 host. |
| **ZFS zvols** | Implemented and tested against a stateful fake of `zfs`; **never run on real hardware yet.** |
| dir / qcow2, NFS, Ceph, thick LVM | Not yet. Reported as `not supported yet` with a plain reason. |
| ext2 / ext3 / ext4 | Mounted `ro,noload,nodev,nosuid,noexec`. Verified. |
| xfs, btrfs | Implemented (`norecovery,nouuid` / default subvolume only). Not yet mounted for real. |
| LUKS, guest LVM, mdraid | Detected and reported as skipped. Never opened. |
| swap, vfat (EFI) | Skipped, listed in the output. |

## How it was verified

This project's claim is "safe", so the evidence matters more than the claim.

- **Real host.** `inspect --yes` ran against four disposable VMs (Debian 12, Ubuntu 24.04, Alpine, and a
  two-disk Debian) on a live Proxmox VE 9.2.28 host. After every run the LV list, thin-pool usage, loop
  devices, mounts and journals were compared with a baseline taken before it: identical, every time.
- **Bit-identical source.** On a stopped two-disk VM the sha256 of both source volumes was identical before
  and after a run.
- **Crash injection on the real host.** 61 runs were killed at points through the execution window
  (`SIGKILL`, `SIGTERM`, `SIGHUP`). `SIGKILL` leaves at most a stray snapshot, and `cleanup --yes` restored
  the exact baseline each time. The sweep found two genuine gaps (a signal during teardown aborted it;
  `SIGHUP` had no handler), both fixed and re-verified.
- **283 tests, 0 skipped**, plus `shellcheck` clean. A **stateful fake** of `zfs`, LVM, `losetup` and `mount`
  with fault injection covers every row of the failure matrix: snapshot fails, crash after snapshot, the
  second clone fails, the device never appears, a mount fails halfway, teardown fails midway, teardown twice,
  wrong stamp, wrong origin, pre-existing objects, a held lock, `SIGTERM`/`SIGHUP` mid-run.
- **Independent review.** A fresh-context reviewer, with no access to the author's reasoning, read the safety layer
  and reported 12 findings; the author reproduced the key ones before fixing (a failed journal write that was
  silently ignored, a crafted journal that executed a command, `SIGPIPE` killing the teardown, a guest
  symlink that pointed at the host's `/etc`, and a ZFS mount path that real `lsblk` would never print). All are
  fixed with a regression test each (rails R16-R21 in the design page). A second automated reviewer
  produced no output in four attempts, which is recorded rather than hidden.
- **Mutation testing.** The safety rails were attacked on purpose (stamp checks removed, `-f` allowed, a
  read-write mount permitted, the journal written after the command, teardown continuing after a failure,
  and more). Every weakening tried was caught by at least one test, and the tests that missed one were fixed.
- **Read-only is proven three independent ways** for `preflight`, `scan` and `inspect` without `--yes`: a
  static scan of the source for mutating commands, a run against stub `qm`/`pvesh`/`pvesm` binaries that log
  every call and refuse anything that is not a read, and `strace` of the tool and all its children showing no
  file is created, written, renamed or removed.
- **Real data as fixtures.** `tests/fixtures/pve9-real` was captured read-only from the test VMs and pins
  what only a real host shows (PVE 9's `Total (KiB)` header, `template: null`, a 30-minute month RRD step,
  cloud-init drives).

## Limitations

- **Not a converter yet.** `convert` and `undo` are stubs.
- **One real host.** Only PVE 9.2.28 with LVM-thin has run for real. ZFS and PVE 8 are untested on real hardware.
- **The guest-internal checks are not written.** Docker, kernel modules, NFS server, cloud-init, snap,
  Tailscale, uid range, LUKS/LVM/mdraid, iSCSI and nested virtualisation are listed as *pending*. The
  interface they plug into is in place (`lib/checks_guest.sh`), including a warning that a hostile guest can
  make `/etc` an absolute symlink to the host.
- **Crash-consistent, not application-consistent.** A snapshot of a running VM is a crash image. Stop the
  VM first if it matters.
- **Disk savings are not estimated**, because used space is only visible from inside the guest.

## Roadmap

1. The guest-internal checks (the first one brings a chroot-safe path resolver).
2. A real ZFS run, and XFS/btrfs guests.
3. `convert`: copy from the snapshot into a new container, with the VM's MAC, a guest NIC named as before,
   an unprivileged container by default, and Tailscale state moved at cutover only.
4. `undo`, a soak period before the old VM is offered for removal, and a verified backup before anything is
   deleted. See the design notes for the full set of decisions.

## Development

```bash
make lint      # shellcheck -x on everything
make test      # bats --recursive tests   (bats --jobs 4 --recursive tests is faster, needs GNU parallel)
```

Needs `bash` 4.4+, `jq`, `shellcheck`, `bats`, and optionally `strace` (one test skips without it). No
Proxmox host is needed: the tests run the real code against canned data and a fake storage host.

| Path | What it is |
|---|---|
| `vm2lxc` | entry script, flag parsing, command dispatch |
| `lib/pve.sh` | the **only** file that reads the host (`qm config`, `pvesh get`, `pvesm`), with a fixture mode |
| `lib/qmconf.sh`, `lib/storage.sh` | `qm config` and `pvesm status` parsing |
| `lib/findings.sh`, `lib/checks_cfg.sh`, `lib/checks_guest.sh` | the verdict engine, the config checks, the guest-check plug-in registry |
| `lib/sizing.sh` | RRD statistics (a jq program), confidence, size choices |
| `lib/preflight.sh`, `lib/scan.sh` | the read-only commands |
| `lib/snapplan.sh` | the pure snapshot plan |
| `lib/hostexec.sh` | **the only file that may change the host**: allowlist, journal, lock, handlers, teardown |
| `lib/inspect.sh` | `inspect` and `cleanup`, the signal trap |
| `tests/` | 12 bats files, a fake storage host, stub PVE binaries, two fixture hosts |

**Adding a check:** write `check_cfg_<name>`, add it to `CFG_CHECKS`, report with
`finding <red|yellow|info|pending> <id> <vm|tool|guest> "<message>"`. A guest-internal check is a function
`guest_check_<id>(guest_root)`; see `lib/checks_guest.sh` for the contract.

## Reporting a bug

Open an issue with the output of `./vm2lxc preflight <vmid>` (and `qm config <vmid>` with anything private
removed), your PVE version and storage type. **Please do not paste anything with credentials.** If you ran
`inspect --yes` and something was left behind, run `./vm2lxc cleanup` and include its output.

## Credits

vm2lxc is a fresh implementation, but it stands on ideas first worked out in two MIT-licensed projects, and
the author is grateful to their authors:

- [ArMaTeC/lxc-to-vm](https://github.com/ArMaTeC/lxc-to-vm) (`vm-to-lxc.sh`): host-side offline conversion, the
  exclude list, per-distro network fix-ups.
- [thushan/proxmox-vm-to-ct](https://github.com/thushan/proxmox-vm-to-ct): the first-boot cleanup unit and the
  boot-package cleanup list.

No code has been copied from either. If any ever is, their notices will be added to `LICENSE`.

## License

[MIT](LICENSE).
