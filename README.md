# vm2lxc

> **Work in progress. Not usable yet.** Only the read-only `preflight` and `scan`
> commands exist, and they have only ever run against canned test fixtures, never
> against a real Proxmox host. `convert`, `undo` and `cleanup` are stubs that print
> "not implemented". Do not point this at a host you care about expecting a conversion.

vm2lxc is a plain, deterministic script that runs as root on a Proxmox VE 8.x/9.x
host and converts a QEMU VM into an LXC container **safely**. There is no AI inside
the tool: bash, `jq`, and the Proxmox CLIs. No network access, no phoning home.

## Why

Existing tools (see Credits) do the mechanical copy, but not the safety model:
they stop the VM, mount its disk read-write, copy over a live system, silently drop
data with glob excludes, give the container a new MAC, and offer no real rollback.
vm2lxc is built around the opposite defaults:

- the source VM is never modified (storage-level snapshots, mounted read-only),
- a convertibility preflight tells you *why* a VM is or is not a good candidate,
- the container keeps the VM's identity (MAC, name, Tailscale state moved, never copied live),
- one-command undo, and the old VM stays around through a soak period.

## What works today

```
vm2lxc preflight <vmid>   read-only: red/yellow/green verdict with plain reasons,
                          disk and NIC plan, and RAM/CPU sizing from RRD history
vm2lxc scan               ranks every VM on the node by verdict and RAM saved
```

The verdict is **provisional**: checks that need to look inside the guest (Docker,
kernel modules, NFS server, cloud-init, snap, ...) are not implemented yet and are
listed as "needs disk inspection (not yet)". A GREEN today means "nothing in the VM
config blocks it", not "go ahead".

Supported storage in v1: ZFS (`zfspool`) and LVM-thin (`lvmthin`). Everything else
is reported as "not supported yet".

## Run the checks and tests (no Proxmox host needed)

```
make lint     # shellcheck
make test     # bats, against fixtures in tests/fixtures
```

Needs `bash` 4.4+, `jq`, `shellcheck`, `bats`. The tests run the real code against
canned `qm config`, `pvesh ... rrddata` and `pvesm status` output.

You can also try the commands on any Linux box with the same canned data ("fixture mode",
clearly labelled in the output, no Proxmox host involved):

```
VM2LXC_FIXTURE_DIR=$PWD/tests/fixtures/pve8 ./vm2lxc scan
VM2LXC_FIXTURE_DIR=$PWD/tests/fixtures/pve8 ./vm2lxc preflight 101
```

Exit codes for `preflight`: 0 green, 10 yellow, 20 red. 64 bad usage, 66 VM not found,
69 environment problem (not root, not a PVE node, missing tool), 70 not implemented yet.

## Design in one paragraph

Everything that touches the host lives in `lib/pve.sh`, and every call there is a
read-only verb. Checks are small functions that emit findings (`green`, `yellow`,
`red`, `info`, `pending`) into one engine, so rules stay data-like and guest-internal
checks can plug in later. `tests/readonly_guard.bats` proves the read-only claim two
ways: a static scan for mutating commands, and a run against stub `qm`/`pvesh`/`pvesm`
binaries that log every call and refuse anything that is not a read.

Design notes and the locked decisions (D0-D12) are in [`docs/BRIEF.md`](docs/BRIEF.md).

## Credits

Ideas borrowed from two MIT-licensed projects, thank you to their authors:

- [ArMaTeC/lxc-to-vm](https://github.com/ArMaTeC/lxc-to-vm) (`vm-to-lxc.sh`)
- [thushan/proxmox-vm-to-ct](https://github.com/thushan/proxmox-vm-to-ct)

No code has been copied from either so far. See `LICENSE` for the details.

## License

MIT, see [`LICENSE`](LICENSE).
