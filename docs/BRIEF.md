# vm2lxc.proxmox: prior art, pitfalls, gap list

Researched Mon 2026-11-16, around 9:20 to 10:00 PM ET. This was web research only. No Proxmox server, hex, gus or herdr pane was touched.
Every URL below returned HTTP 200 when checked on 2026-11-16, except the two Reddit threads. Reddit sends 403 to scripted fetches, so those two are marked "seen via search index only".
Star counts, last-commit dates and licenses come from the GitHub API on 2026-11-16. For the top 3 tools I read the code itself, shallow-cloned onto the box, not just the READMEs.

---

## 1. Research

### 1.1 Tool table

| # | Tool | URL | ★ / forks | Last commit | License | Approach |
|---|------|-----|-----------|-------------|---------|----------|
| 1 | **ArMaTeC/lxc-to-vm** (`vm-to-lxc.sh`, inside a bidirectional toolkit) | https://github.com/ArMaTeC/lxc-to-vm (script: https://github.com/ArMaTeC/lxc-to-vm/blob/main/vm-to-lxc.sh) | 41 / 12 | 2026-11-14 (repo created 2026-02-10, 126 commits, v6.2.2) | MIT | Runs on the PVE host and works offline. **Stops the VM.** Resolves the first disk (`scsi0/virtio0/ide0/sata0`) with `pvesm path`. qcow2 is `qemu-img convert`ed to a *full raw copy*, then `kpartx` maps it and the first ext2/3/4, xfs or btrfs partition is mounted. **No `-o ro`.** Then `rsync -axHAX` copies into a staging dir with excludes, applies fix-ups, runs `tar czf`, and calls `pct create <ct> rootfs.tar.gz --ostype unmanaged` |
| 2 | **thushan/proxmox-vm-to-ct** | https://github.com/thushan/proxmox-vm-to-ct | 96 / 13 | 2026-08-14 | MIT | Works **live over SSH**. It runs `tar` of `/` on the *running* VM, streams the result to the host, then calls `pct create` from the tarball. It has DietPi-specific handling and a "docker" profile (privileged, `nesting=1,keyctl=1`). Supports PVE 9 (issue #19 closed) |
| 3 | **my5t3ry/machine-to-proxmox-lxc-ct-converter** (the original that most of the others derive from) | https://github.com/my5t3ry/machine-to-proxmox-lxc-ct-converter | 154 / 38 | pushed 2025-06-05 | **none** (no LICENSE file) | Live SSH `tar czvvf - -C / ...`, then `pct create`. There is a whiptail TUI (`convert.sh`) and a CLI (`bashconvert`). Works on any Linux machine (P2V-to-LXC as well as VM) |
| 4 | tristankayser/Proxmox-VM-to-LXC (fork of #3, updated for PVE 7/8/9; README says "with Claude AI") | https://github.com/tristankayser/Proxmox-VM-to-LXC | 0 / 0 | 2026-04-16 | none | Same as #3. Adds `--one-file-system`-style excludes (docker, containerd, snap, lxc, cni, apt cache), DHCP or static, `--ostype`, and `-u` for unprivileged |
| 5 | sherbettt/machine-to-proxmox-lxc-ct-converter (Russian fork of #3) | https://github.com/sherbettt/machine-to-proxmox-lxc-ct-converter | 0 / 0 | 2026-05-21 | NOASSERTION | Same as #3 |
| 6 | michaelScopic/proxmox-util-scripts (`vm2lxc.sh`) | https://codeberg.org/michaelScopic/proxmox-util-scripts | n/a (Codeberg) | n/a | see repo | Small personal script that turns a VM into an LXC and then a reusable CT template. Not a migration tool |
| 7 | DietPi blog: "DietPi LXC containers in Proxmox" | https://dietpi.com/blog/?p=2642 | n/a | blog | n/a | Copy of #3's SSH-tar script plus DietPi fix-ups (`/etc/.dietpi_hw_model_identifier` set to 75) |
| 8 | **Incus `incus-migrate`** (official; Incus, not Proxmox) | https://linuxcontainers.org/incus/docs/main/howto/import_machines_to_instances/ | n/a | maintained with Incus | Apache-2.0 (Incus) | Runs on the source machine and rsyncs a root filesystem path (e.g. `/`) to an Incus server to create a system container. The docs say: "Typically, you must update at least the storage configuration (`/etc/fstab`) and the network configuration." It does no fix-ups itself. A user report confirms they "had to remove the efi partition from fstab": https://discuss.linuxcontainers.org/t/convert-a-linux-vm-into-a-linux-container/25063 |
| 9 | Manual method: mount, tar, `pct create` (Proxmox staff and forum) | https://forum.proxmox.com/threads/backup-restore-how-to-create-a-ct-from-an-existing-volume-disk-image.110565/ · https://forum.proxmox.com/threads/creating-or-converting-a-vm-to-lxc.151846/ · https://forum.proxmox.com/threads/how-to-migrate-a-regular-lxc-container-to-a-proxmox-lxc-container.24138/ | n/a | forum | n/a | Proxmox staff (Fabian) in thread 110565: "create a template from the volume (mount it, create a tar archive), then pass that to `pct create`". LnxBil in thread 151846: boot a live Linux in the VM, tar the filesystem, use it as a template, then "remove stuff like kernel, grub and everything else boot related". Thread 24138 (2015): `pct restore` needs a vzdump-format tar with `./etc/vzdump/pct.conf` inside. Building it by hand fails on things like invalid `hwaddr` |
| 10 | Official Proxmox stance | https://forum.proxmox.com/threads/how-to-convert-a-vm-into-lxc-in-proxmox-ve-6-0-2.85052/ · https://pve.proxmox.com/wiki/Migration_of_servers_to_Proxmox_VE | n/a | n/a | n/a | Staff (Tom): "There is no one button migration… Create a new LXC container, copy all settings and data, eg. with rsync". The official migration wiki covers VM imports (OVF, `qm disk import`, ESXi importer) and has no VM-to-LXC path |
| 11 | Blog: Andreas Happe, "How to convert an KVM image into a LXC container" (2014, plain LXC) | https://snikt.net/blog/2014/04/07/how-to-convert-an-kvm-image-into-a-lxc-container/ | n/a | 2014 | n/a | `mount -o loop,offset=` on the LVM-backed image, `rsync` into the rootfs, manual `/dev` nodes, comment out all of fstab, remove `acpid`, `hwclock`, `mountall`, `checkfs` and `udev` services |
| 12 | Blog: sekin.in, "How to Move a Proxmox VM Workload to LXC Safely" | https://sekin.in/how-to-move-a-proxmox-vm-workload-into-an-lxc-container/ | n/a | blog | n/a | Argues *against* whole-rootfs conversion and for an app-level rebuild in a fresh CT with side-by-side cutover. Its checklist (kernel modules, FUSE, block devices, accelerators) is useful for preflight |
| 13 | Blog: hackwiki, distrobuilder for LXC | https://www.hackwiki.de/en/blog/distrobuilder/ | n/a | blog | n/a | Shows `pct create <id> ./rootfs.tar.xz --ostype unmanaged` works with any rootfs tarball |
| 14 | community-scripts/ProxmoxVE (formerly tteck) | https://github.com/community-scripts/ProxmoxVE | 30.1k | active | MIT | **Has no VM-to-LXC tool.** The nearest is an experimental `tools/pve/docker2lxc.sh` (OCI/Docker image to LXC) in the dev repo: https://github.com/community-scripts/ProxmoxVED/commit/09773db8f6b32d9f66005a22f6365438991161ae |
| 15 | Reddit r/Proxmox, "Migrate VMs to an LXC container in Proxmox" (Mar 2025) | https://www.reddit.com/r/Proxmox/comments/1jfjnig/migrate_vms_to_an_lxc_container_in_proxmox/ (seen via search index only; direct fetch 403) | n/a | n/a | n/a | The consensus is "it's simpler to create lxc and move everything you need through ssh". No tool is suggested |

I found no tool on the Proxmox side named literally `vm2lxc` apart from #6. None of the r/homelab or r/selfhosted results described a dedicated tool. They pointed to #2 or #3, or to "rebuild by hand".

### 1.2 Close read of the top 3: what each excludes, fixes up and protects

| | ArMaTeC `vm-to-lxc.sh` | thushan `proxmox-vm-to-ct` | my5t3ry `bashconvert` / `convert.sh` |
|---|---|---|---|
| Source access | Mounts the PVE volume on the host after **stopping the VM** (`stop_guest_gracefully`) | SSH into the **running** VM | SSH into the **running** VM |
| Mounted read-only? | **No.** Plain `mount $ROOT_PART`, so the ext4 journal replay and atime writes can change the source disk | n/a (live) | n/a (live) |
| Consistency | Offline, so it is consistent | **Inconsistent:** live tar of a running system. DBs can be torn. It hits "file changed as we read it" and timestamp errors (issue #13) | Inconsistent (live) |
| Disk / storage support | First disk only. Partitions only (ext*, xfs, btrfs). **No guest LVM** (no `vgimportclone`/`vgchange`). qcow2 means a full raw copy (slow, 2× space). RBD/Ceph probably fails: it needs `-e $(pvesm path)`. That is my inference and untested | Whatever is mounted in the VM (tar without `--one-file-system` crosses into mounts) | Same, and it **follows NFS/SMB mounts** (issue #8 user copied their Synology) |
| Excludes | `/dev /proc /sys /tmp /run /mnt /media lost+found`, `/boot/vmlinuz* initr* grub* efi loader System.map config-*`, `/lib/modules/*`, `/var/lib/dkms`, **`/var/lib/docker/*`, `/var/lib/containerd/*`, `/var/lib/containers/*`** (Docker data is silently dropped) | `sys dev run proc`, **`*.log*`, `*.gz`, `*.sql`**, `swap.img`. That silently drops every `.gz` and `.sql` file anywhere, including DB dumps and backups | Same as thushan (**`*.gz`, `*.sql` dropped**) |
| Fix-ups | Removes kernel, initrd, grub and modules. Blanks `/etc/fstab`. Removes `serial-getty@ttyS0` and the `qemu-guest-agent` enablement. Renames `ens18`→`eth0` in ifupdown, NM and ifcfg. **Replaces netplan with eth0 DHCP.** Creates `/dev /proc /sys`, `/tmp` 1777 | Installs a **first-boot oneshot unit** (`ConditionVirtualization=container`) in the source. It purges `linux-image-*`, grub, shim, initramfs, `qemu-guest-agent` and `open-vm-tools` (dpkg only), comments out UUID/PARTUUID/LABEL/dev lines in fstab (keeping a backup) and removes `/boot/efi`. DietPi tweaks | None |
| Networking result | `net0: name=eth0,bridge=..,ip=dhcp`, **new random MAC**, hostname `<vmname>-lxc`. `--keep-network` only skips the in-guest rewrite | User-chosen `net0` (default DHCP), new MAC | Static `/24` hard-coded, `8.8.8.8` DNS, new MAC |
| Privileged? | **Privileged by default** (`--unprivileged` to opt in) | Unprivileged by default. Docker profile: privileged, `nesting,keyctl` | Privileged, `nesting=1` |
| Preflight | `--validate`: VM exists, VM stopped, disk found, net0 exists, storage exists, deps present. **No workload check** (Docker, modules, GPU, NFS-server, appliance). It rejects Windows | Host, arch, PVE version, SSH reachable | None |
| Dry run | Yes (`-n`), prints the step list | No | No |
| Rollback | `--snapshot` takes a `qm snapshot` of the **source VM**. `--rollback-on-failure` runs `qm rollback` on the source. That is not a CT-to-VM cutover rollback. Also has **`--destroy-source`** | None | None |
| Source untouched? | **No.** It stops the VM, mounts it read-write, adds and removes a snapshot, and can destroy the VM | **No.** It writes a script and a unit into the source VM. On DietPi it also edits `/etc/.dietpi_hw_model_identifier` and `/boot/dietpi/.install_stage` on the source and disables a service | Mostly untouched (read-only tar), but it needs root SSH and often `PermitRootLogin yes` |
| Tailscale | **Nothing** (no grep hit in the repo). `/var/lib/tailscale` is copied verbatim and no TUN device is added. If the VM ever starts again, both nodes share one node key | Nothing | Nothing |
| Other | Resume, batch and range modes, parallel jobs, hooks, profiles, TUI wizard, post-create health check | Reuses the tarball, config file | n/a |
| Distros | Debian/Ubuntu, Alpine, RHEL family, Arch (network rewrite per family) | Debian-family assumed for cleanup (dpkg). The rest is generic | Generic |

---

## 2. Pitfalls (with sources)

1. **Unprivileged extraction fails on device nodes, ACLs and odd timestamps.** `pct create --unprivileged 1` extracts through `lxc-usernsexec -m u:0:100000:65536 ... tar xpf - --numeric-owner --acls --xattrs`. Device nodes such as Docker's `backingFsBlockDev`, snap leftovers, and storage mounted with `noacl` make it exit with code 2. Sources: https://github.com/thushan/proxmox-vm-to-ct/issues/2 · https://github.com/thushan/proxmox-vm-to-ct/issues/13 · https://github.com/thushan/proxmox-vm-to-ct/issues/16 · https://forum.proxmox.com/threads/solved-unable-to-pct-create-an-unprivileged-debian-container.143338/ (fix there: remove `noacl` from the storage mount). `pct create --ignore-unpack-errors` exists (https://pve.proxmox.com/pve-docs/pct.1.html) but hides real errors. The tarball should hold **real uids (0..65535)** and Proxmox does the shift. Never pre-shift. uid/gid maps beyond 65535 (e.g. LDAP/sssd users) do not map by default: https://pve.proxmox.com/wiki/Unprivileged_LXC_containers
2. **`--ostype` version check.** If you set a managed ostype, pct refuses newer point releases: "unsupported debian version '13.1'" (https://github.com/thushan/proxmox-vm-to-ct/issues/22). A managed ostype also lets PVE rewrite the network, hostname and hosts files. `unmanaged` skips all of that (pct man page), so then the tool owns the network config.
3. **`/dev/net/tun` for Tailscale.** Unprivileged CTs need `pct set <ct> --dev0 /dev/net/tun` (PVE 8+). On PVE 7 it is `lxc.cgroup2.devices.allow: c 10:200 rwm` plus `lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file`. The alternative is userspace networking. Source: https://tailscale.com/kb/1130/lxc-unprivileged
4. **Tailscale duplicate node or key "food fight".** Two live machines with the same `tailscaled.state` fight over one IP, flap, and burn CPU. Sources: https://github.com/tailscale/tailscale/issues/506 · https://github.com/tailscale/tailscale/issues/392 · troubleshooting KB "two devices have the same 100.x IP": https://tailscale.com/kb/1023/troubleshooting
   - **Moving state works on Linux-to-Linux if the old node is stopped first.** A Tailscale engineer wrote "Linux to Linux should work, watch out for the permissions", and another user added "It does when the machine is shutdown before the new one launches" (https://github.com/tailscale/tailscale/issues/6443, an open FR for an official device-replacement flow). Practical how-to: stop tailscaled on both, move `/var/lib/tailscale` (700, root:root), start it on the new host (https://implicit.computer/notes/2026/02/tailscale-transfer/).
   - Tailscale explicitly *discourages* copying private keys (same FR). vm2lxc relies on unsupported but working behaviour, and the docs should say so.
   - Rollback risk (my inference, test it): if the CT's tailscaled renews or rotates its node key while live, the VM's older state may be stale after rollback and need re-auth.
5. **Docker-in-LXC.** Proxmox docs: "If you want to run application containers, for example, Docker images, it is recommended that you run them inside a Proxmox QEMU VM" (https://pve.proxmox.com/pve-docs/chapter-pct.html; quoted by staff in https://forum.proxmox.com/threads/proxmoxs-team-stance-on-running-docker-inside-an-lxc-container.162791/). It needs `nesting=1,keyctl=1` and has AppArmor issues (my5t3ry issue #8 shows `apparmor_parser ... @{PROC}` failures): https://github.com/my5t3ry/machine-to-proxmox-lxc-ct-converter/issues/8. A reported problem restoring unprivileged Docker LXCs from PBS is seen via search index only (Reddit 403): https://www.reddit.com/r/Proxmox/comments/1qiutit/docker_as_an_lxc_in_proxmox/. Existing tools silently **drop `/var/lib/docker`**.
6. **Kernel NFS server.** `nfs-kernel-server` does not work in unprivileged LXC (it needs nfsd and rpc_pipefs). The workarounds are a privileged CT with the nfs feature, a VM, or userspace NFS-Ganesha. Sources: https://forum.proxmox.com/threads/nfs-server-in-unprivileged-lxc-possible.164864/ · https://forum.proxmox.com/threads/is-it-possible-to-run-a-nfs-server-within-a-lxc.24403/page-2. NFS and CIFS *client* mounts from fstab also fail in unprivileged CTs. Move them to host mounts plus `mpX` bind mounts.
7. **systemd units that fail in LXC.** `systemd-remount-fs` fails while fstab still references UUID/PARTUUID (thushan's reasoning, in code). Also failing: `serial-getty@ttyS0`, `qemu-guest-agent`, `sys-kernel-config/debug.mount`, audit, mount-namespacing errors (https://github.com/lxc/lxc/issues/4127 · https://forum.proxmox.com/threads/issue-moving-containers-from-lxc-to-proxmox.111266/), and the 2014 list `acpid`, `hwclock`, `mountall`, `checkfs`, `udev` (snikt.net). Others: `systemd-timesyncd` (skipped in CTs), `multipathd`, `open-iscsi`, `smartd`, `lvm2-monitor`, `fstrim.timer`, `snapd` (does not work in unprivileged LXC). After moving a DietPi system, all services hung (https://github.com/thushan/proxmox-vm-to-ct/issues/18).
8. **cloud-init.** On the first CT boot, cloud-init on a cloud-image VM can regenerate network config, hostname and SSH host keys. Disable it with `/etc/cloud/cloud-init.disabled` or `network: {config: disabled}`: https://docs.cloud-init.io/en/latest/howto/disable_cloud_init.html
9. **Mounting disks on the host.**
   - LVM: kpartx the LV.
   - ZFS zvol: use `/dev/zvol/<pool>/vm-N-disk-M-partX` (https://forum.proxmox.com/threads/how-to-mount-a-guests-lvm-volume-on-a-zfs-raw-disk-image-from-the-pve-host.110908/).
   - qcow2: `qemu-nbd --read-only`.
   - Guest LVM inside the disk: VG names can clash with the host or other clones, so use `vgimportclone`, then deactivate and clean up afterwards.
   - ext4 `ro` **still replays the journal**. Use `ro,noload` (kernel ext4 docs: https://www.kernel.org/doc/html/latest/admin-guide/ext4.html). XFS needs `ro,norecovery,nouuid`.
   - btrfs subvolumes (`@`, `@home`) need `subvol=`.
   - Multi-disk VMs (separate `/var` or `/home` disks, `/boot` partition, mdraid) are not handled by any existing tool.
10. **Data loss through glob excludes.** `*.gz`, `*.sql` and `*.log*` in #2 and #3. A missing `--one-file-system` copies NFS mounts (#3, issue #8).
11. **Live-copy inconsistency.** All the SSH tools tar a running system. Offline (#1) means downtime for the whole copy.
12. **Interface naming and MAC.** VM NICs are `ens18`, the CT is `eth0` unless you set `name=`. A new random MAC breaks DHCP reservations. Reusing the VM's MAC while the VM is up means a duplicate MAC on the bridge.
13. **DietPi and appliances.** Firmware-specific identifiers need patching. Appliances (pfSense/OPNsense, TrueNAS, HAOS, Windows, *BSD) cannot be converted at all.

---

## 3. Gap list: what Fred's design adds that nothing existing does well

Honest summary first. **ArMaTeC/lxc-to-vm `vm-to-lxc.sh` already does the mechanical core of Fred's pipeline.** It runs on the host, mounts the PVE volume offline, copies with kernel/boot/modules excludes, blanks fstab, rewrites per-distro networking and calls `pct create` from a tarball. It also has dry-run, a shallow preflight and a snapshot. It is MIT and very actively maintained. Roughly half of the pipeline exists. What it lacks is the **safety model and identity preservation**, which is the reason vm2lxc exists. Its defaults (stop the VM, mount read-write, privileged, DHCP with a new MAC, `--destroy-source`) contradict Fred's principles.

| Gap | Fred's design | Best existing | Status |
|---|---|---|---|
| G1 Source never modified | Snapshot the storage layer, mount the clone `ro,noload` | ArMaTeC mounts the live volume **read-write** and stops the VM. thushan **writes into the source** | **Not done anywhere** |
| G2 No-downtime copy | Copy from a snapshot while the VM keeps running. Only the cutover is downtime | ArMaTeC: offline only. SSH tools: live but inconsistent | **Not done** (crash-consistent snapshot plus optional final delta is new) |
| G3 Convertibility preflight with reasons | Custom or DKMS kernel modules, Docker/Podman/containerd, nested virt (kvm/libvirt), GPU/PCI/USB passthrough in VM config, appliance or non-Linux, nfs-kernel-server, iSCSI/multipath, snap, cloud-init, fstab network mounts, uid >65535 | ArMaTeC: checks the VM exists, a disk and network exist, and deps are present; rejects Windows. No workload analysis | **Not done** |
| G4 Tailscale identity move | `/dev/net/tun` passthrough, move `/var/lib/tailscale` at cutover only, same name and IP, never two live copies | None. All tools copy (or drop) state blindly, so there is a latent duplicate-node risk | **Not done anywhere** |
| G5 Side-by-side IP/MAC cutover | Build the CT with the VM's MAC/IP (or name the NIC `ens18`), keep it stopped, then stop the VM, start the CT, verify | ArMaTeC: DHCP plus a new MAC plus a `-lxc` hostname. Others: user-typed IP | **Not done** |
| G6 One-command rollback of the cutover | Stop the CT, start the VM (untouched), restore onboot flags and Tailscale ownership | ArMaTeC "rollback" = `qm rollback` of the source on *conversion failure* | **Not done** |
| G7 Dry-run *plan* | Concrete plan: excludes, fix-ups, units to mask, CT config diff, preflight verdict | ArMaTeC dry run = static step list | Partial |
| G8 Storage coverage | ZFS, LVM-thin and dir/qcow2 (NFS too), plus RBD. Guest LVM, multi-disk, btrfs subvols | ArMaTeC: first disk, partitions only, qcow2 via a full raw copy | Mostly not done |
| G9 No silent data loss | No glob excludes on data. Docker data either kept or refused at preflight | Every tool drops something silently | Not done |
| G10 systemd fix-up done right | Mask hardware-only units in the staged rootfs, disable cloud-init, comment out fstab (keep a backup), first-boot purge of kernel packages | thushan's first-boot unit is the best idea (`ConditionVirtualization=container`). ArMaTeC removes a few symlinks | Partial; **borrow from thushan**, written into the staged copy and not the source |
| G11 Unprivileged by default and correct | Unprivileged, ACL check on target storage, uid-range check | thushan defaults unprivileged | Partial |

**Recommendation.** Building is justified. G1, G2, G4, G5 and G6 are the core value and nobody does them. Forking ArMaTeC would mean replacing its disk-access layer, defaults, rollback semantics and networking: most of what matters. Its 1.3k-line monolithic bash also ships unrelated features (batch, cloud export, destroy-source) that add risk.
Suggested path:
- Build vm2lxc fresh.
- Credit and reuse MIT-licensed ideas from ArMaTeC (exclude list, per-distro network rewrite, resume) and from thushan (first-boot cleanup unit, DietPi IDs).
- As goodwill, offer ArMaTeC a small upstream PR for `ro,noload` mounting and preserving `/var/lib/docker`.
- Proxmox staff clearly don't want this in core ("importing arbitrary file systems is rather dangerous", thread 110565), so it stays third-party.

---

## 4. Design decisions (open questions)

1. **Snapshot primitive per storage.** Use `qm snapshot`, which adds a snapshot entry to the VM config (does that count as "modifying the source"?). The alternative is raw storage snapshots (`zfs snapshot`+`clone`, `lvcreate -s` on thin plus `-ay -K`, `rbd snap create` plus `rbd map --read-only`, qcow2 through `qemu-nbd --read-only`, external overlay or `-l snap`). Raw snapshots stay invisible to PVE but must be cleaned up reliably. Which storage types are in scope for v1 (ZFS plus LVM-thin only?).
2. **Consistency.** Accept crash-consistent snapshots, or use guest-agent `fsfreeze` when the agent exists? Is a two-phase design (bulk copy from snapshot 1, then at cutover stop the VM, take snapshot 2 and rsync the delta into the CT) in scope, or is v1 "stop VM at cutover, accept crash-consistency of the bulk copy"?
3. **Unprivileged vs privileged.** Default to unprivileged. Should preflight auto-escalate (Docker, NFS server) or refuse? Should Docker workloads be refused in v1?
4. **Tailscale handoff mechanics.** At cutover: stop tailscaled in the VM by shutting the VM down. Never edit the VM disk. Copy `/var/lib/tailscale` from snapshot 2 (the last state) into the CT, then start the CT. The VM must never boot with that state while the CT is live, so enforce it with `onboot=0` and maybe a PVE `lock` or tag on the VM. How does rollback hand identity back if the CT renewed its key? Plus: subnet-router or exit-node flags (`ip_forward` sysctl in the CT netns), Tailscale SSH, `serve`/`funnel` config, and userspace-mode fallback when `/dev/net/tun` passthrough isn't wanted.
5. **NIC naming.** Set the CT `net0 name=ens18` (or whatever the VM used) so the guest network config works unchanged, or rewrite configs to `eth0`? Copy the VM's MAC into `hwaddr` so DHCP reservations and ARP survive (safe only after the VM stops). Map multiple NICs and VLAN tags from the VM config.
6. **`--ostype`.** `unmanaged` (the tool owns network and hostname) or the detected distro (PVE manages them, but its version checks bite)?
7. **Multi-disk VMs.** Fold extra filesystems into rootfs, or map them to `mpX` volumes with the same mountpoints? How to handle LVM-in-guest spanning disks, `/boot` partitions and mdraid?
8. **Exclude and fix-up policy.** Exclude at copy time (ArMaTeC) or copy everything and purge on first boot (thushan)? Copying everything makes the CT faithful and rollback-safe, but keeps the kernel packages until first boot.
9. **Identity files.** Keep `machine-id`, SSH host keys, hostname and Tailscale (a "move" semantic). Should a `--clone` mode regenerate them instead?
10. **Rollback window and cleanup.** How long does the VM stay stopped and untouched? What does "commit" do (delete snapshot or clone only, never the VM)? Where does the plan and state file live (`/var/lib/vm2lxc/<vmid>/plan.json`)?
11. **Implementation.** Bash (matches community-scripts culture) or Python/Go (testability)? PVE API (`pvesh`) or CLI (`qm`/`pct`)? Plan, apply and rollback as idempotent subcommands?
12. **Scope of P2V.** Is physical-to-LXC (over SSH, without the snapshot guarantees) in scope, or VM-only?

---

## 5. Test results

_Empty for now._
Test rules: run only on a throwaway nested PVE or a disposable VM provided by Proxmox Expert.
**Never touch VMs 110, 111, 120, 121, 351 or 301.** Never run on hex or gus, and never on any herdr pane.

---

## 6. Next steps

1. Fred or Larry answer the open questions in section 4, at least items 1, 2, 4 and 5, before any code.
2. Read ArMaTeC `vm-to-lxc.sh` (network rewrite and exclude blocks) and thushan's `vm_ct_prep_cleanup()` in full as reference. Both are MIT; keep attribution.
3. Prototype the read-only snapshot-mount layer first (ZFS, then LVM-thin, then qcow2) on the disposable nested PVE. Prove it with checksums that the source volume is bit-identical before and after.
4. Write the preflight rule set (G3) as data, each rule with a reason and a doc link, and run it against snapshot mounts of a few disposable test VMs (Debian 12/13, Ubuntu 24.04 cloud-image, Alpine, one with Docker, one with nfs-kernel-server, one with Tailscale).
5. Test the Tailscale handoff on a disposable tailnet node: move, rollback, re-cutover. Watch the admin console for "Duplicate node key", and check whether rollback needs re-auth after a CT key renewal.
6. Optional goodwill: open an upstream issue or PR on ArMaTeC/lxc-to-vm for `ro,noload` mounting and keeping `/var/lib/docker`. That needs Fred's OK because it is externally visible.

## Decisions (Fred, 2026-11-16)
- D1: storage-level snapshots (zfs, lvm-thin) in v1; not qm snapshot. cleanup trap plus `vm2lxc cleanup`. qcow2/ceph later.
- D2: stop-and-copy is the default (safest for all workloads); two-pass `--live` is opt-in.
- D3: tailscale state moves only at cutover with VM stopped; VM autostart off; rollback copies container's /var/lib/tailscale back into the VM disk before boot and refuses to start VM while CT runs.
- D4: container nic named ens18 with the VM's exact MAC (no guest network rewrite).
- D0: deliverable is a plain deterministic script on the PVE host (bash, or a single python file), no AI in the tool. shellcheck + tests.
- D5: unprivileged by default (--privileged opt-in); docker refused in v1 by preflight; ostype detected, fallback unmanaged.
- D6: extra VM disks map to container mount points (mp0, mp1...) on same storage.
- D7: interactive whiptail TUI (plain prompts fallback with no tty); enter = recommended default; progress bars per stage; review screen with continue/back/edit/quit; journal-based undo (`vm2lxc undo <ct>`).
- D8: sizing recommendations from rrd history (pvesh rrddata), multichoice; uses whatever history exists with a confidence label; under 24h keeps current size.
- D9: optional vzdump backup, verified, plus a test restore to a temp never-started VM id, then destroyed; VM removal default no, type VM id to confirm, only after backup proven.
- D10: soak period (keep VM N days, then nag to remove).
- D11: preflight verdict red/yellow/green with plain reasons; `vm2lxc scan` ranks all VMs on the node with savings and a one-line why.
- D12: post-conversion compare (services, listening ports, mounts) before cutover; per-run log in /var/log/vm2lxc/; lock file; offline; --yes and --answers file; markdown run report; one-liner install later.
- Status: Larry NOT started (Fred: "No larry yet"). Test VMs requested from Proxmox Expert, tag vm2lxc-test-rm, Fred confirms there.
