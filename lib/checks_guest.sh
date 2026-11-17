# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# Guest-internal checks: the ones that need to look INSIDE the VM's filesystem. They run
# later, against a read-only snapshot mount (not built yet), so today every one of them
# reports `pending: needs disk inspection (not yet)`.
#
# The plug-in contract, so the real checks drop in without touching anything else:
#   * a check is a function named guest_check_<id with '-' replaced by '_'>
#   * it receives one argument: the root of the read-only guest filesystem
#   * it reports with `finding <level> guest-<id> guest "<message>"` (zero or more times)
#   * it must not write anything under that root
#   * the guest is UNTRUSTED: an absolute symlink inside it (/etc -> /etc, /var/lib/x -> /root)
#     points at the HOST, not at the guest. Never `cat`, `[[ -f ]]` or `grep` a path under the
#     root as if it were safe: resolve it chroot-style (every symlink re-rooted under the guest
#     root) or refuse a path that escapes. The first real guest check must bring that helper.
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

guest_checks_run() {
  local id fn
  GUEST_RAN=() GUEST_PENDING=()
  for id in "${GUEST_CHECK_IDS[@]}"; do
    fn="guest_check_${id//-/_}"
    if [[ -n ${GUEST_ROOT:-} ]] && declare -F "$fn" >/dev/null; then
      "$fn" "$GUEST_ROOT"
      GUEST_RAN+=("$id")
    else
      finding pending "guest-$id" guest "${GUEST_CHECK_TITLE[$id]}: needs disk inspection (not yet)"
      GUEST_PENDING+=("$id")
    fi
  done
}
