# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# Guest-internal checks: the ones that need to look INSIDE the VM's filesystem. They run against
# the read-only snapshot mount of the boot disk (`inspect --yes`, `convert`); without a mounted
# guest root (`preflight`, `scan`) each one is reported `pending: needs disk inspection`.
#
# The plug-in contract, so the real checks drop in without touching anything else:
#   * a check is a function named guest_check_<id with '-' replaced by '_'>
#   * it receives one argument: the root of the read-only guest filesystem
#   * it reports with `finding <level> guest-<id> guest "<message>"` (zero or more times)
#   * it must not write anything under that root
#   * the guest is UNTRUSTED: an absolute symlink inside it (/etc -> /etc, /var/lib/x -> /root)
#     points at the HOST, not at the guest. Never `cat`, `[[ -f ]]` or `grep` a path under the
#     root as if it were safe: every read goes through lib/guestfs.sh, which resolves it
#     chroot-style (every symlink re-rooted under the guest root).
#   * the runner calls it only when GUEST_ROOT is set; anything without an
#     implementation is reported pending.
# Expected verdicts when implemented are listed per check below (decisions D5, D3).

GUEST_CHECK_IDS=(os-release docker kernel-modules nfs-server cloud-init snap fstab-netmounts tailscale uid-range disk-layers iscsi-multipath nested-virt)

declare -gA GUEST_CHECK_TITLE=(
  [os-release]="guest OS identity (Linux distro vs appliance/BSD)"        # red if not a Linux distro
  [docker]="Docker/Podman/containerd workloads"                           # red in v1 (D5)
  [kernel-modules]="custom or DKMS kernel modules"                        # red: the container has no kernel of its own
  [nfs-server]="kernel NFS server (nfs-kernel-server)"                    # red unprivileged: needs nfsd
  [cloud-init]="cloud-init"                                               # yellow: disabled in the copy so it cannot rewrite network/hostname/keys
  [snap]="snapd and snap packages"                                        # yellow: snapd does not work in unprivileged LXC
  [fstab-netmounts]="NFS/CIFS mounts in fstab"                            # yellow: move to host mounts plus bind mounts
  [tailscale]="Tailscale state"                                           # info: identity moves at cutover only (D3)
  [uid-range]="uid/gid above 65535"                                       # yellow: outside the default unprivileged map
  [disk-layers]="LUKS, mdraid and guest LVM"                              # red/yellow: not readable as a plain filesystem
  [iscsi-multipath]="iSCSI initiator and multipath"                       # red: needs raw block devices
  [nested-virt]="nested virtualisation (kvm/libvirt)"                     # red: no /dev/kvm in the container
)

GUEST_RAN=() GUEST_PENDING=()
GUEST_PENDING_WHY="the disk was not looked at" # set by whoever knows why (preflight, scan, the overlay)

guest_checks_run() {
  local id fn
  GUEST_RAN=() GUEST_PENDING=()
  for id in "${GUEST_CHECK_IDS[@]}"; do
    fn="guest_check_${id//-/_}"
    if [[ -n ${GUEST_ROOT:-} ]] && declare -F "$fn" >/dev/null; then
      "$fn" "$GUEST_ROOT" || true # a check whose last test was negative must not abort the run
      GUEST_RAN+=("$id")
    else
      finding pending "guest-$id" guest "${GUEST_CHECK_TITLE[$id]}: not checked, $GUEST_PENDING_WHY"
      GUEST_PENDING+=("$id")
    fi
  done
}


# --- the checks -------------------------------------------------------------------------------------
# Facts the checks learn about the guest, used later by `convert`.
GUEST_OS_ID="" GUEST_OS_LIKE="" GUEST_OS_PRETTY="" GUEST_OSTYPE=unmanaged
GUEST_HAS_TAILSCALE=0 GUEST_HAS_CLOUDINIT=0

guest_facts_reset() {
  GUEST_OS_ID="" GUEST_OS_LIKE="" GUEST_OS_PRETTY="" GUEST_OSTYPE=unmanaged
  GUEST_HAS_TAILSCALE=0 GUEST_HAS_CLOUDINIT=0
}

# Guest text goes to a terminal: neutralise it before it reaches a message.
g_clean() { sanitize_text "$1"; }

# the PVE --ostype for an os-release ID / ID_LIKE
g_ostype_for() {
  local id w
  for id in "$@"; do
    for w in $id; do
      case $w in
        debian | ubuntu | devuan | alpine | archlinux | fedora | gentoo | nixos) printf '%s' "$w"; return 0 ;;
        centos | rhel | rocky | almalinux | ol) printf 'centos'; return 0 ;;
        opensuse* | sles | suse) printf 'opensuse'; return 0 ;;
        arch) printf 'archlinux'; return 0 ;;
      esac
    done
  done
  printf 'unmanaged'
}

guest_check_os_release() {
  local root=$1 f="" line k v
  guest_facts_reset
  for f in /etc/os-release /usr/lib/os-release; do
    if gfs_is_file "$root" "$f"; then break; fi
    f=""
  done
  if [[ -z $f ]]; then
    finding yellow guest-os-release guest "no /etc/os-release: the distro could not be identified, so the container would be created as ostype=unmanaged"
    return 0
  fi
  while IFS= read -r line; do
    [[ $line == *=* ]] || continue
    k=${line%%=*}
    v=${line#*=}
    v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
    case $k in
      ID) GUEST_OS_ID=$v ;;
      ID_LIKE) GUEST_OS_LIKE=$v ;;
      PRETTY_NAME) GUEST_OS_PRETTY=$v ;;
    esac
  done < <(gfs_cat "$root" "$f")
  GUEST_OS_ID=$(printf '%s' "$GUEST_OS_ID" | tr -cd 'A-Za-z0-9._-')
  GUEST_OS_LIKE=$(printf '%s' "$GUEST_OS_LIKE" | tr -cd 'A-Za-z0-9._ -')
  g_clean "$GUEST_OS_PRETTY"
  GUEST_OS_PRETTY=$REPLY
  GUEST_OSTYPE=$(g_ostype_for "$GUEST_OS_ID" "$GUEST_OS_LIKE")
  if [[ -z $GUEST_OS_ID ]]; then
    finding yellow guest-os-release guest "/etc/os-release has no ID: the distro could not be identified (ostype=unmanaged)"
  else
    finding info guest-os-release guest "guest OS: ${GUEST_OS_PRETTY:-$GUEST_OS_ID} (detected ostype: $GUEST_OSTYPE)"
  fi
}

guest_check_docker() {
  local root=$1 hit=() f
  gfs_dir_nonempty "$root" /var/lib/docker && hit+=("/var/lib/docker has data")
  gfs_dir_nonempty "$root" /var/lib/containerd && hit+=("/var/lib/containerd has data")
  gfs_dir_nonempty "$root" /var/lib/containers && hit+=("/var/lib/containers (podman) has data")
  local pkg
  for pkg in docker-ce docker.io podman containerd containerd.io docker; do
    gfs_pkg_installed "$root" "$pkg" && hit+=("package $pkg is installed")
  done
  for f in /usr/bin/dockerd /usr/sbin/dockerd /usr/bin/podman; do
    gfs_exists "$root" "$f" && hit+=("$f exists")
  done
  if ((${#hit[@]} > 0)); then
    finding red guest-docker guest "Docker/Podman/containerd found (${hit[0]}$([[ ${#hit[@]} -gt 1 ]] && printf ', and %d more' $((${#hit[@]} - 1)))): refused in v1, container workloads need nesting and keep their data in layers that are not safe to copy blindly"
  fi
}

guest_check_kernel_modules() {
  local root=$1 d dirs="" n=0 mods=""
  if gfs_dir_nonempty "$root" /var/lib/dkms; then
    finding red guest-kernel-modules guest "DKMS modules are installed (/var/lib/dkms): the container has no kernel of its own, so they cannot load"
  fi
  while IFS= read -r d; do
    if gfs_dir_nonempty "$root" "/lib/modules/$d/updates" || gfs_dir_nonempty "$root" "/lib/modules/$d/extra"; then
      n=$((n + 1))
      dirs+=" $d"
    fi
  done < <(gfs_entries "$root" /lib/modules)
  if ((n > 0)); then
    g_clean "$dirs"
    finding red guest-kernel-modules guest "out-of-tree kernel modules under /lib/modules (kernels:$REPLY): the container has no kernel of its own"
  fi
  # modules the guest loads at boot: they must exist on the host kernel, or the unit fails
  local f line
  for f in /etc/modules $(gfs_entries "$root" /etc/modules-load.d 2>/dev/null | sed 's#^#/etc/modules-load.d/#'); do
    gfs_is_file "$root" "$f" || continue
    while IFS= read -r line; do
      line=${line%%#*}
      line=${line//[[:space:]]/}
      [[ -n $line ]] && mods+=" $line"
    done < <(gfs_cat "$root" "$f")
  done
  if [[ -n $mods ]]; then
    g_clean "$mods"
    finding yellow guest-kernel-modules guest "the guest loads kernel modules at boot ($REPLY ): the container uses the host kernel, so check they are available there"
  fi
}

guest_check_nfs_server() {
  local root=$1 line found=0
  if gfs_is_file "$root" /etc/exports; then
    while IFS= read -r line; do
      line=${line%%#*}
      [[ -n ${line//[[:space:]]/} ]] && found=1
    done < <(gfs_cat "$root" /etc/exports)
  fi
  if ((found)) || gfs_pkg_installed "$root" nfs-kernel-server; then
    finding red guest-nfs-server guest "the guest is a kernel NFS server (nfs-kernel-server / /etc/exports): an unprivileged container cannot run nfsd"
  fi
}

guest_check_cloud_init() {
  local root=$1
  if gfs_is_dir "$root" /etc/cloud || gfs_pkg_installed "$root" cloud-init || gfs_is_dir "$root" /var/lib/cloud; then
    GUEST_HAS_CLOUDINIT=1
    finding yellow guest-cloud-init guest "cloud-init is installed: it is disabled in the copy (/etc/cloud/cloud-init.disabled) so it cannot rewrite the network, hostname or SSH keys on first boot"
  fi
}

guest_check_snap() {
  local root=$1 n=0 f
  if gfs_dir_nonempty "$root" /var/lib/snapd/snaps; then
    while IFS= read -r f; do n=$((n + 1)); done < <(gfs_entries "$root" /var/lib/snapd/snaps)
    finding yellow guest-snap guest "snapd is installed with $n snap file(s): snaps do not run in an unprivileged container (squashfs mounts, AppArmor)"
  elif gfs_pkg_installed "$root" snapd; then
    finding yellow guest-snap guest "snapd is installed (no snaps found): it will not work in an unprivileged container"
  fi
}

guest_check_fstab_netmounts() {
  local root=$1 line dev mp fs bad=""
  gfs_is_file "$root" /etc/fstab || return 0
  while IFS= read -r line; do
    line=${line%%#*}
    # shellcheck disable=SC2086
    set -- $line
    (($# >= 3)) || continue
    dev=$1 mp=$2 fs=$3
    case $fs in
      nfs | nfs4 | cifs | smb3 | smbfs | glusterfs | ceph | fuse.sshfs | fuse.glusterfs | 9p | virtiofs | davfs | fuse.rclone)
        bad+=" $mp($fs)"
        ;;
    esac
  done < <(gfs_cat "$root" /etc/fstab)
  if [[ -n $bad ]]; then
    g_clean "$bad"
    finding yellow guest-fstab-netmounts guest "network or shared-folder mounts in /etc/fstab ($REPLY ): the copy comments out fstab, so mount them on the host and bind-mount them into the container"
  fi
}

guest_check_tailscale() {
  local root=$1
  if gfs_is_file "$root" /var/lib/tailscale/tailscaled.state || gfs_exists "$root" /usr/sbin/tailscaled || gfs_pkg_installed "$root" tailscale; then
    GUEST_HAS_TAILSCALE=1
    if gfs_is_file "$root" /var/lib/tailscale/tailscaled.state; then
      finding yellow guest-tailscale guest "Tailscale node state is present: the identity is copied into the container, so the VM must never boot again while the container runs (two nodes would share one key); the VM is set to not start at boot"
    else
      finding info guest-tailscale guest "Tailscale is installed but has no node state (not logged in): nothing to move"
    fi
  fi
}

guest_check_uid_range() {
  local root=$1 f line id big=""
  for f in /etc/passwd /etc/group; do
    gfs_is_file "$root" "$f" || continue
    while IFS= read -r line; do
      IFS=: read -r _ _ id _ <<<"$line"
      [[ $id =~ ^[0-9]+$ ]] && ((id > 65535 && id != 4294967294 && id != 4294967295)) && big+=" ${f##*/}:$id"
    done < <(gfs_cat "$root" "$f")
  done
  if [[ -n $big ]]; then
    g_clean "$big"
    finding yellow guest-uid-range guest "ids above 65535 in the guest ($REPLY ): they fall outside the default unprivileged id map and would not be usable"
  fi
}

guest_check_disk_layers() {
  local root=$1 line layers="" sk
  if gfs_is_file "$root" /etc/crypttab; then
    while IFS= read -r line; do
      line=${line%%#*}
      [[ -n ${line//[[:space:]]/} ]] && layers+=" LUKS(/etc/crypttab)" && break
    done < <(gfs_cat "$root" /etc/crypttab)
  fi
  if gfs_is_file "$root" /etc/mdadm/mdadm.conf && gfs_cat "$root" /etc/mdadm/mdadm.conf | grep -q '^ARRAY'; then
    layers+=" mdraid(/etc/mdadm/mdadm.conf)"
  fi
  if gfs_dir_nonempty "$root" /etc/lvm/backup; then layers+=" LVM(/etc/lvm/backup)"; fi
  for sk in "${SKIPPED[@]:-}"; do
    case $sk in *LVM2_member* | *crypto_LUKS* | *linux_raid_member*) layers+=" a$([[ $sk == *LVM2_member* ]] && echo ' LVM' || echo ' LUKS/RAID') partition on the disk" ; break ;; esac
  done
  if [[ -n $layers ]]; then
    g_clean "$layers"
    finding red guest-disk-layers guest "LUKS, RAID or LVM inside the guest ($REPLY ): its volumes are not plain filesystems and are not supported yet"
  fi
}

guest_check_iscsi_multipath() {
  local root=$1 line cfg=0 why="" pkgs=""
  # USED is what matters, not installed and not the stock config. Ubuntu cloud images ship open-iscsi,
  # multipath-tools AND a /etc/multipath.conf holding only `defaults { user_friendly_names yes }` (found on a real
  # host, twice). Real use shows as: discovered iSCSI targets; a multipath.conf that defines multipaths, devices or
  # blacklist_exceptions; or a filesystem in fstab on a multipath map or an iSCSI by-path device.
  if gfs_dir_nonempty "$root" /etc/iscsi/nodes; then
    cfg=1 why="iSCSI targets are discovered (/etc/iscsi/nodes)"
  fi
  if gfs_is_file "$root" /etc/multipath.conf; then
    while IFS= read -r line; do
      line=${line%%#*}
      if [[ $line =~ ^[[:space:]]*(multipaths|devices|blacklist_exceptions)[[:space:]]*\{ ]]; then
        cfg=1 why="multipath.conf defines ${BASH_REMATCH[1]}"
      fi
    done < <(gfs_cat "$root" /etc/multipath.conf)
  fi
  if gfs_is_file "$root" /etc/fstab; then
    while IFS= read -r line; do
      line=${line%%#*}
      if [[ $line =~ ^[[:space:]]*(/dev/mapper/mpath[^[:space:]]*|/dev/disk/by-path/[^[:space:]]*iscsi[^[:space:]]*)[[:space:]] ]]; then
        cfg=1 why="fstab mounts ${BASH_REMATCH[1]}"
      fi
    done < <(gfs_cat "$root" /etc/fstab)
  fi
  if ((cfg)); then
    g_clean "$why"
    finding red guest-iscsi-multipath guest "iSCSI or multipath is in use ($REPLY): it needs raw block devices, which a container does not have"
    return 0
  fi
  gfs_pkg_installed "$root" open-iscsi && pkgs+=" open-iscsi"
  gfs_pkg_installed "$root" multipath-tools && pkgs+=" multipath-tools"
  if [[ -n $pkgs ]]; then
    finding info guest-iscsi-multipath guest "installed but not in use (${pkgs# }): inert in a container, its services may log errors"
  fi
}

guest_check_nested_virt() {
  local root=$1 pkg
  for pkg in libvirt-daemon-system libvirt-daemon qemu-system-x86 qemu-kvm qemu-system-x86-64; do
    if gfs_pkg_installed "$root" "$pkg"; then
      finding red guest-nested-virt guest "the guest runs virtual machines ($pkg is installed): a container has no /dev/kvm"
      return 0
    fi
  done
  if gfs_dir_nonempty "$root" /etc/libvirt/qemu; then
    finding red guest-nested-virt guest "libvirt domains are defined in the guest: a container has no /dev/kvm"
  fi
}
