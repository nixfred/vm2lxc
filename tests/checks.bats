#!/usr/bin/env bats
# Config-level checks, the verdict engine, and the guest-check plug-in contract.
# Every test feeds a `qm config` text to the real checks against the fixture host.

bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_fixture_host
}

# --- baseline ----------------------------------------------------------------

@test "a plain Linux VM on ZFS has no red or yellow findings: GREEN" {
  run_cfg_checks_on < <(good_cfg)
  [ "$VERDICT" = green ]
  [ "$N_RED" -eq 0 ]
  [ "$N_YELLOW" -eq 0 ]
}

@test "host version: 8.x and 9.x pass, 7.x, 10.x and unreadable are red tool-limits" {
  PVE_MAJOR=9 PVE_VERSION=9.0.3
  run_cfg_checks_on < <(good_cfg)
  [ "$VERDICT" = green ]
  PVE_MAJOR=7 PVE_VERSION=7.4.1
  run_cfg_checks_on < <(good_cfg)
  [ "$VERDICT" = red ]
  has_finding red host-version "7.4.1 is not supported"
  [ "${F_KIND[0]}" = tool ]
  PVE_MAJOR=10 PVE_VERSION=10.0.1
  run_cfg_checks_on < <(good_cfg)
  has_finding red host-version "10.0.1 is not supported"
  PVE_MAJOR='' PVE_VERSION=''
  run_cfg_checks_on < <(good_cfg)
  has_finding red host-version "could not read"
}

# --- identity: ostype and appliances ------------------------------------------------

@test "ostype: Windows variants are red, solaris is red, l24/other/unknown are yellow" {
  local os
  for os in win11 win10 win7 w2k8 wxp wvista; do
    run_cfg_checks_on < <(cfg_with "ostype: $os")
    has_finding red ostype "ostype $os is Windows"
  done
  run_cfg_checks_on < <(cfg_with 'ostype: solaris')
  has_finding red ostype "solaris"
  run_cfg_checks_on < <(cfg_with 'ostype: l24')
  [ "$VERDICT" = yellow ]
  has_finding yellow ostype "2.4"
  run_cfg_checks_on < <(cfg_with 'ostype: other')
  [ "$VERDICT" = yellow ]
  run_cfg_checks_on < <(cfg_with '-ostype')
  has_finding yellow ostype "'other'"
  run_cfg_checks_on < <(cfg_with 'ostype: zx81')
  has_finding yellow ostype "unrecognised ostype 'zx81'"
}

@test "appliance hint plus ostype other is red; plus ostype l26 is only yellow" {
  run_cfg_checks_on < <(cfg_with 'name: pfsense-fw' 'ostype: other')
  [ "$VERDICT" = red ]
  has_finding red appliance "'pfsense'"
  run_cfg_checks_on < <(cfg_with 'name: truenas-store' 'ostype: l26')
  [ "$VERDICT" = yellow ]
  has_finding yellow appliance "'truenas'"
}

@test "appliance hint is found in tags and in the URL-encoded description" {
  run_cfg_checks_on < <(cfg_with 'tags: prod;opnsense')
  has_finding yellow appliance "'opnsense'"
  run_cfg_checks_on < <(cfg_with 'description: Install%20of%20TrueNAS%20SCALE')
  has_finding yellow appliance "'truenas'"
}

@test "appliance hint respects word boundaries: no false positive inside other words" {
  local n
  for n in absdata compbsd pbsx notpbs unraider; do
    run_cfg_checks_on < <(cfg_with "name: $n")
    no_finding appliance || { echo "false positive on name '$n'"; return 1; }
  done
}

# --- hardware ----------------------------------------------------------------

@test "hostpci passthrough is red and names the device" {
  run_cfg_checks_on < <(cfg_with 'hostpci0: 0000:01:00.0,pcie=1' 'hostpci1: 0000:02:00.0')
  [ "$VERDICT" = red ]
  has_finding red hostpci "hostpci0 is PCI passthrough (0000:01:00.0)"
  has_finding red hostpci "hostpci1"
}

@test "USB passthrough is yellow, but SPICE USB redirection is ignored" {
  run_cfg_checks_on < <(cfg_with 'usb0: host=0bda:8153')
  [ "$VERDICT" = yellow ]
  has_finding yellow usb "host=0bda:8153"
  run_cfg_checks_on < <(cfg_with 'usb0: spice')
  no_finding usb
  run_cfg_checks_on < <(cfg_with 'usb0: host=spice,usb3=1')
  no_finding usb
}

@test "USB passthrough wording follows the kind (R39): mapped by vm2lxc, a cluster mapping is not, an odd value stays by hand" {
  run_cfg_checks_on < <(cfg_with 'usb0: host=0bda:8153,usb3=1')
  [ "$VERDICT" = yellow ]
  has_finding yellow usb "vm2lxc maps the device into the container"
  has_finding yellow usb "exactly one match on the host after the VM has stopped"
  run_cfg_checks_on < <(cfg_with 'usb0: host=1-2.3')
  has_finding yellow usb "vm2lxc maps the device into the container"
  run_cfg_checks_on < <(cfg_with 'usb0: mapping=zigbee')
  [ "$VERDICT" = yellow ]
  has_finding yellow usb "a cluster resource mapping, which vm2lxc does not resolve"
  run_cfg_checks_on < <(cfg_with 'usb0: host=banana')
  has_finding yellow usb "not carried over automatically"
}

@test "USB passthrough never makes a VM red by itself (a PCI device does)" {
  run_cfg_checks_on < <(cfg_with 'usb0: host=0bda:8153' 'usb1: mapping=x' 'usb2: host=1-2')
  [ "$VERDICT" = yellow ]
  run_cfg_checks_on < <(cfg_with 'usb0: host=0bda:8153' 'hostpci0: 0000:01:00.0')
  [ "$VERDICT" = red ]
}

@test "virtiofs share, custom args and hookscript are each yellow" {
  run_cfg_checks_on < <(cfg_with 'virtiofs0: shared-dir,cache=auto' 'args: -device vfio-pci,host=01:00.0' 'hookscript: local:snippets/hook.pl')
  [ "$VERDICT" = yellow ]
  has_finding yellow virtiofs "virtiofs0"
  has_finding yellow args "vfio-pci"
  has_finding yellow hookscript "local:snippets/hook.pl"
}

@test "TPM is yellow (sealed disk encryption), an EFI disk is only info" {
  run_cfg_checks_on < <(cfg_with 'tpmstate0: local-zfs:vm-100-disk-4,size=4M,version=v2.0' 'efidisk0: local-zfs:vm-100-disk-3,efitype=4m,size=1M')
  [ "$VERDICT" = yellow ]
  has_finding yellow tpm "TPM-sealed"
  has_finding info efi "UEFI VM"
}

@test "template and locked VMs are red" {
  run_cfg_checks_on < <(cfg_with 'template: 1')
  has_finding red template "template"
  run_cfg_checks_on < <(cfg_with 'lock: backup')
  has_finding red lock "lock: backup"
}

# --- disks and storage -------------------------------------------------------

@test "multi-disk is fine: info with the rootfs/mp mapping, verdict stays green" {
  run_cfg_checks_on < <(cfg_with 'scsi1: local-lvm:vm-100-disk-1,size=200G' 'virtio0: local-zfs:vm-100-disk-2,size=8G')
  [ "$VERDICT" = green ]
  has_finding info multi-disk "3 disks map to scsi0 -> rootfs, scsi1 -> mp0, virtio0 -> mp1"
}

@test "a cdrom or empty drive is ignored, not a disk" {
  run_cfg_checks_on < <(cfg_with 'ide0: local:iso/debian.iso,media=cdrom,size=600M')
  no_finding multi-disk
  [ "$VERDICT" = green ]
}

@test "unsupported storage is red and tagged as a v1 limit, with the reason" {
  run_cfg_checks_on < <(cfg_with 'scsi0: local:100/vm-100-disk-0.qcow2,size=32G')
  [ "$VERDICT" = red ]
  has_finding red storage "storage 'local' is type dir: file-based storage"
  local i
  for i in "${!F_ID[@]}"; do
    [[ ${F_ID[$i]} == storage ]] && [ "${F_KIND[$i]}" = tool ]
  done
  run_cfg_checks_on < <(cfg_with 'scsi0: ceph-pool:vm-100-disk-0,size=32G')
  has_finding red storage "type rbd: Ceph"
  run_cfg_checks_on < <(cfg_with 'scsi0: old-lvm:vm-100-disk-0,size=32G')
  has_finding red storage "type lvm: thick LVM"
}

@test "lvm-thin is supported" {
  run_cfg_checks_on < <(cfg_with 'scsi0: local-lvm:vm-100-disk-0,size=32G')
  [ "$VERDICT" = green ]
}

@test "a storage that is missing or not active is red and is not a v1 limit" {
  run_cfg_checks_on < <(cfg_with 'scsi0: gone-storage:vm-100-disk-0,size=32G')
  has_finding red storage "'gone-storage' is not in the storage list"
  run_cfg_checks_on < <(cfg_with 'scsi0: tank-off:vm-100-disk-0,size=32G')
  has_finding red storage "'tank-off' is disabled, not active"
  [ "${F_KIND[0]}" = vm ]
}

@test "a raw host device is red: it cannot be snapshotted at the storage layer" {
  run_cfg_checks_on < <(cfg_with 'scsi1: /dev/disk/by-id/ata-WDC_WD40EFRX,size=4T')
  [ "$VERDICT" = red ]
  has_finding red disk-passthrough "/dev/disk/by-id/ata-WDC_WD40EFRX"
}

@test "no disk at all is red; an unparseable volume spec is yellow; unused is info" {
  run_cfg_checks_on < <(cfg_with '-scsi0')
  has_finding red disk-none "no usable disk"
  run_cfg_checks_on < <(cfg_with 'scsi1: weird-no-colon,size=8G')
  has_finding yellow disk-unknown "weird-no-colon"
  run_cfg_checks_on < <(cfg_with 'unused0: local-zfs:vm-100-disk-9')
  has_finding info disk-unused "detached volume"
  [ "$VERDICT" = green ]
}

@test "a guessed boot disk is reported as info" {
  run_cfg_checks_on < <(cfg_with '-boot')
  has_finding info boot-guess "assuming scsi0"
}

# --- verdict engine ------------------------------------------------------------

@test "worst level wins: red over yellow over green" {
  findings_reset
  finding yellow a vm "y"
  verdict_compute
  [ "$VERDICT" = yellow ]
  [ "$(verdict_exit_code)" -eq 10 ]
  finding red b vm "r"
  verdict_compute
  [ "$VERDICT" = red ]
  [ "$(verdict_exit_code)" -eq 20 ]
}

@test "info and pending never change the verdict" {
  findings_reset
  finding info a vm "i"
  finding pending b guest "p"
  verdict_compute
  [ "$VERDICT" = green ]
  [ "$N_INFO" -eq 1 ]
  [ "$N_PENDING" -eq 1 ]
  [ "$(verdict_exit_code)" -eq 0 ]
}

@test "finding refuses an unknown level or kind (a typo in a check must be loud)" {
  findings_reset
  run finding purple x vm "nope"
  [ "$status" -ne 0 ]
  [[ $output == *"bad finding level 'purple'"* ]]
  run finding red x galaxy "nope"
  [ "$status" -ne 0 ]
  [[ $output == *"bad finding kind 'galaxy'"* ]]
}

@test "top_reason: first red wins over an earlier yellow, v1 limits are tagged, none when clean" {
  findings_reset
  finding yellow y vm "the yellow thing"
  finding red r tool "the red limit"
  [ "$(top_reason)" = "the red limit (v1 limit)" ]
  findings_reset
  finding yellow y vm "the yellow thing"
  [ "$(top_reason)" = "the yellow thing" ]
  findings_reset
  finding info i vm "just info"
  run top_reason
  [ "$status" -eq 1 ]
}

# --- guest checks: the plug-in interface -------------------------------------------

@test "guest checks: with nothing implemented, all 12 are pending and the verdict is untouched" {
  findings_reset
  guest_checks_run
  verdict_compute
  [ "$N_PENDING" -eq 12 ]
  [ "$VERDICT" = green ]
  [ "${#GUEST_RAN[@]}" -eq 0 ]
  has_finding pending guest-docker "needs disk inspection (not yet)"
  has_finding pending guest-nested-virt "needs disk inspection (not yet)"
}

@test "guest checks: every registered id has a title (no id without a plain-words label)" {
  local id
  for id in "${GUEST_CHECK_IDS[@]}"; do
    [ -n "${GUEST_CHECK_TITLE[$id]:-}" ] || { echo "no title for $id"; return 1; }
  done
}

# The mechanism tests below are about the plug-in contract, not about the real checks: start from a
# registry with NO implementations, then define only the one under test.
clear_real_checks() {
  local id
  for id in "${GUEST_CHECK_IDS[@]}"; do unset -f "guest_check_${id//-/_}"; done
}

@test "guest checks: an implementation plugs in, runs against GUEST_ROOT, and changes the verdict" {
  clear_real_checks
  guest_check_docker() { # the contract: one arg, the guest root
    [[ -d $1/var/lib/docker ]] && finding red guest-docker guest "Docker data found under $1/var/lib/docker"
    return 0
  }
  local root="$BATS_TEST_TMPDIR/guest"
  mkdir -p "$root/var/lib/docker"
  GUEST_ROOT=$root
  findings_reset
  guest_checks_run
  verdict_compute
  [ "$VERDICT" = red ]
  has_finding red guest-docker "Docker data found"
  [ "$N_PENDING" -eq 11 ]
  [ "${GUEST_RAN[*]}" = docker ]
  # the implemented check must NOT also be reported pending
  local i
  for i in "${!F_ID[@]}"; do
    if [[ ${F_ID[$i]} == guest-docker && ${F_LEVEL[$i]} == pending ]]; then
      echo "guest-docker is both run and pending"
      return 1
    fi
  done
}

@test "guest checks: an implementation that finds nothing is a pass, not a pending" {
  clear_real_checks
  guest_check_snap() { return 0; }
  GUEST_ROOT="$BATS_TEST_TMPDIR"
  findings_reset
  guest_checks_run
  [ "${GUEST_RAN[*]}" = snap ]
  # 12 registered, 1 ran and found nothing: exactly 11 pending, no finding for snap at all
  [ "$(printf '%s\n' "${F_LEVEL[@]}" | grep -c '^pending$')" -eq 11 ]
  no_finding guest-snap
}

@test "guest checks: an implementation is NOT called when GUEST_ROOT is unset" {
  clear_real_checks
  guest_check_docker() { finding red guest-docker guest "should never run"; }
  unset GUEST_ROOT
  findings_reset
  guest_checks_run
  verdict_compute
  [ "$VERDICT" = green ]
  [ "${#GUEST_RAN[@]}" -eq 0 ]
}
