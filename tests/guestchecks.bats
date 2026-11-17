#!/usr/bin/env bats
# The twelve guest-internal checks, each against a synthetic guest tree. No host is touched.

bats_require_minimum_version 1.5.0
load helpers

setup() {
  load_libs common findings guestfs checks_guest
  GN=0
  fresh
}

# a new, empty guest and a clean findings pile (each scenario starts from nothing, nothing is deleted)
fresh() {
  GN=$((GN + 1))
  G="$BATS_TEST_TMPDIR/g$GN"
  mkdir -p "$G"
  findings_reset
  SKIPPED=()
}

gput() { mkdir -p "$G/$(dirname "$1")"; printf '%s' "$2" >"$G/$1"; }
run_check() { "guest_check_$1" "$G"; verdict_compute; }

debian_guest() {
  gput etc/os-release $'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nID=debian\nVERSION_ID="12"\n'
  mkdir -p "$G/usr" "$G/bin"
}

# --- os-release ---------------------------------------------------------------------------------------------------

@test "os-release: Debian is identified and mapped to ostype debian (info, never a verdict change)" {
  debian_guest
  run_check os_release
  has_finding info guest-os-release "Debian GNU/Linux 12"
  [ "$GUEST_OS_ID" = debian ]
  [ "$GUEST_OSTYPE" = debian ]
  [ "$VERDICT" = green ]
}

@test "os-release: Ubuntu, Alpine and an ID_LIKE derivative map to their ostype; an unknown ID is unmanaged" {
  gput etc/os-release $'ID=ubuntu\nID_LIKE=debian\n'
  run_check os_release
  [ "$GUEST_OSTYPE" = ubuntu ]
  gput etc/os-release $'ID=alpine\n'
  run_check os_release
  [ "$GUEST_OSTYPE" = alpine ]
  gput etc/os-release $'ID=linuxmint\nID_LIKE="ubuntu debian"\n'
  run_check os_release
  [ "$GUEST_OSTYPE" = ubuntu ]
  gput etc/os-release $'ID=rocky\nID_LIKE="rhel centos fedora"\n'
  run_check os_release
  [ "$GUEST_OSTYPE" = centos ]
  gput etc/os-release $'ID=somethingnew\n'
  run_check os_release
  [ "$GUEST_OSTYPE" = unmanaged ]
}

@test "os-release: missing file or no ID is yellow and unmanaged, and it falls back to /usr/lib/os-release" {
  run_check os_release
  has_finding yellow guest-os-release "no /etc/os-release"
  [ "$GUEST_OSTYPE" = unmanaged ]
  fresh
  gput usr/lib/os-release $'ID=debian\n'
  run_check os_release
  [ "$GUEST_OSTYPE" = debian ]
  fresh
  gput etc/os-release $'PRETTY_NAME=nothing\n'
  run_check os_release
  has_finding yellow guest-os-release "no ID"
}

@test "os-release: a hostile PRETTY_NAME cannot put an escape sequence on the terminal" {
  gput etc/os-release $'ID=debian\nPRETTY_NAME="Evil\033[31m\xc2\x9b2J"\n'
  run_check os_release
  local m="${F_MSG[0]}"
  [[ $m != *$'\033'* && $m != *$'\xc2\x9b'* ]]
}

@test "os-release: a guest whose /etc is an absolute symlink to the HOST does not leak the host's os-release" {
  ln -s /etc "$G/etc"
  [ -e /etc/os-release ] || [ -e /usr/lib/os-release ] # the host really has one
  run_check os_release
  has_finding yellow guest-os-release "no /etc/os-release" # the host's file was not read
  [ -z "$GUEST_OS_ID" ]
}

# --- docker -------------------------------------------------------------------------------------------------------

@test "docker: data in /var/lib/docker is red" {
  gput var/lib/docker/overlay2/x "d"
  run_check docker
  has_finding red guest-docker "var/lib/docker"
}

@test "docker: the dockerd binary, podman data, or an installed package is red" {
  gput usr/bin/dockerd ""
  run_check docker
  has_finding red guest-docker "dockerd"
  fresh
  gput var/lib/containers/storage/x "d"
  run_check docker
  has_finding red guest-docker "podman"
  fresh
  gput var/lib/dpkg/status $'Package: docker-ce\nStatus: install ok installed\n'
  run_check docker
  has_finding red guest-docker "docker-ce"
}

@test "docker: an empty /var/lib/docker or a removed package is not a finding" {
  mkdir -p "$G/var/lib/docker"
  gput var/lib/dpkg/status $'Package: docker-ce\nStatus: deinstall ok config-files\n'
  run_check docker
  no_finding guest-docker
}

# --- kernel modules / nfs / cloud-init / snap ----------------------------------------------------------------------

@test "kernel-modules: DKMS and out-of-tree module dirs are red" {
  gput var/lib/dkms/nvidia/x "d"
  run_check kernel_modules
  has_finding red guest-kernel-modules "DKMS"
  fresh
  gput lib/modules/6.1.0/updates/dkms/foo.ko "x"
  run_check kernel_modules
  has_finding red guest-kernel-modules "out-of-tree"
}

@test "kernel-modules: modules loaded at boot are yellow, and nothing special is no finding" {
  gput etc/modules $'# comment\nwireguard\n\nbr_netfilter # inline\n'
  run_check kernel_modules
  has_finding yellow guest-kernel-modules "wireguard br_netfilter"
  [ "$VERDICT" = yellow ]
  fresh
  debian_guest
  run_check kernel_modules
  no_finding guest-kernel-modules
}

@test "nfs-server: an export line or the package is red; an empty or commented exports file is not" {
  gput etc/exports $'# nothing\n\n'
  run_check nfs_server
  no_finding guest-nfs-server
  fresh
  gput etc/exports $'/srv/data 10.0.0.0/24(rw)\n'
  run_check nfs_server
  has_finding red guest-nfs-server "NFS server"
  fresh
  gput var/lib/dpkg/status $'Package: nfs-kernel-server\nStatus: install ok installed\n'
  run_check nfs_server
  has_finding red guest-nfs-server
}

@test "cloud-init: present is yellow and sets the fact the converter needs; absent is nothing" {
  run_check cloud_init
  no_finding guest-cloud-init
  [ "$GUEST_HAS_CLOUDINIT" = 0 ]
  mkdir -p "$G/etc/cloud"
  run_check cloud_init
  has_finding yellow guest-cloud-init "disabled in the copy"
  [ "$GUEST_HAS_CLOUDINIT" = 1 ]
}

@test "snap: snap files or the package is yellow" {
  gput var/lib/snapd/snaps/core22_1.snap "x"
  run_check snap
  has_finding yellow guest-snap "1 snap file"
  fresh
  gput var/lib/dpkg/status $'Package: snapd\nStatus: install ok installed\n'
  run_check snap
  has_finding yellow guest-snap "snapd is installed"
}

# --- fstab / tailscale / uid / disk layers ---------------------------------------------------------------------------

@test "fstab-netmounts: a normal fstab and commented network lines are not findings" {
  gput etc/fstab $'UUID=1 / ext4 defaults 0 1\n#nas:/x /mnt nfs defaults 0 0\n'
  run_check fstab_netmounts
  no_finding guest-fstab-netmounts
}

@test "fstab-netmounts: nfs, cifs and virtiofs lines are yellow" {
  gput etc/fstab $'UUID=1 / ext4 defaults 0 1\nnas:/export /mnt/nas nfs4 defaults 0 0\n//srv/s /mnt/s cifs ro 0 0\nshare /mnt/h virtiofs defaults 0 0\n'
  run_check fstab_netmounts
  has_finding yellow guest-fstab-netmounts "/mnt/nas(nfs4)"
  has_finding yellow guest-fstab-netmounts "/mnt/s(cifs)"
  has_finding yellow guest-fstab-netmounts "/mnt/h(virtiofs)"
}

@test "tailscale: node state is yellow (identity moves), an installed but logged-out client is info, none is nothing" {
  run_check tailscale
  no_finding guest-tailscale
  [ "$GUEST_HAS_TAILSCALE" = 0 ]
  gput usr/sbin/tailscaled ""
  run_check tailscale
  has_finding info guest-tailscale "no node state"
  [ "$GUEST_HAS_TAILSCALE" = 1 ]
  fresh
  gput var/lib/tailscale/tailscaled.state "{}"
  run_check tailscale
  has_finding yellow guest-tailscale "never boot again"
}

@test "uid-range: ids above 65535 are yellow; nobody (65534) is not" {
  gput etc/passwd $'root:x:0:0:r:/root:/bin/sh\nnobody:x:65534:65534::/:/sbin/nologin\n'
  gput etc/group $'root:x:0:\nnogroup:x:65534:\n'
  run_check uid_range
  no_finding guest-uid-range
  fresh
  gput etc/passwd $'root:x:0:0:r:/root:/bin/sh\nsvc:x:200000:200000::/:/bin/false\n'
  run_check uid_range
  has_finding yellow guest-uid-range "passwd:200000"
}

@test "disk-layers: a crypttab entry, an mdadm ARRAY, LVM metadata are red; a commented crypttab is not" {
  gput etc/crypttab $'# none\n'
  run_check disk_layers
  no_finding guest-disk-layers
  fresh
  gput etc/crypttab $'cryptroot UUID=1 none luks\n'
  run_check disk_layers
  has_finding red guest-disk-layers "LUKS"
  fresh
  gput etc/mdadm/mdadm.conf $'ARRAY /dev/md0 metadata=1.2\n'
  run_check disk_layers
  has_finding red guest-disk-layers "mdraid"
  fresh
  gput etc/lvm/backup/vg0 "x"
  run_check disk_layers
  has_finding red guest-disk-layers "LVM"
}

@test "disk-layers: a LUKS/LVM partition the mount layer skipped is red" {
  SKIPPED=("scsi0|/dev/loop0p3|LVM2_member|guest LVM / LUKS / mdraid is not supported yet")
  run_check disk_layers
  has_finding red guest-disk-layers "partition on the disk"
}

@test "iscsi-multipath: multipath.conf, iSCSI nodes or the package is red" {
  run_check iscsi_multipath
  no_finding guest-iscsi-multipath
  gput etc/multipath.conf "x"
  run_check iscsi_multipath
  has_finding red guest-iscsi-multipath
  fresh
  mkdir -p "$G/etc/iscsi/nodes/iqn.x"
  run_check iscsi_multipath
  has_finding red guest-iscsi-multipath
}

@test "nested-virt: libvirt or qemu-system installed, or libvirt domains, is red" {
  run_check nested_virt
  no_finding guest-nested-virt
  gput var/lib/dpkg/status $'Package: libvirt-daemon-system\nStatus: install ok installed\n'
  run_check nested_virt
  has_finding red guest-nested-virt "libvirt-daemon-system"
  fresh
  gput etc/libvirt/qemu/vm.xml "x"
  run_check nested_virt
  has_finding red guest-nested-virt "libvirt domains"
}

# --- the runner ------------------------------------------------------------------------------------------------------

@test "runner: all twelve run against a mounted root, none is pending, and a clean Debian guest is green" {
  debian_guest
  GUEST_ROOT=$G
  guest_checks_run
  verdict_compute
  [ "${#GUEST_RAN[@]}" -eq 12 ]
  [ "${#GUEST_PENDING[@]}" -eq 0 ]
  [ "$N_PENDING" -eq 0 ]
  [ "$VERDICT" = green ]
}

@test "runner: a check that ends on a negative test does not abort the run (errexit)" {
  debian_guest
  run bash -c "set -e; source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/findings.sh'; source '$REPO_ROOT/lib/guestfs.sh'; source '$REPO_ROOT/lib/checks_guest.sh'; guest_check_snap() { [[ -d /nonexistent ]]; }; GUEST_ROOT='$G'; guest_checks_run; echo reached-the-end"
  [ "$status" -eq 0 ]
  [[ $output == *reached-the-end* ]]
}

@test "hostile guest: a tree built from symlinks to the host reports nothing from the host and never loops" {
  local d
  for d in etc var usr lib bin sbin; do ln -s "/$d" "$G/$d"; done
  run timeout 60 bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/findings.sh'; source '$REPO_ROOT/lib/guestfs.sh'; source '$REPO_ROOT/lib/checks_guest.sh'; SKIPPED=(); GUEST_ROOT='$G'; findings_reset; guest_checks_run; verdict_compute; echo \"verdict=\$VERDICT ran=\${#GUEST_RAN[@]}\"; for i in \"\${!F_ID[@]}\"; do echo \"\${F_LEVEL[\$i]} \${F_ID[\$i]}\"; done"
  [ "$status" -eq 0 ]               # finished (not 124), no crash
  [[ $output == *"verdict=yellow"* ]] # only the 'no os-release' yellow: not the host's docker, nfs or snap
  [[ $output == *"ran=12"* ]]
  [[ $output != *"red guest-"* ]]
}
