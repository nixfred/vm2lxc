#!/usr/bin/env bats
# The snapshot PLAN: a pure description, built from the VM's disks. No fake host needed:
# the only host call is the read-only `pvesm path`, replaced by a lookup table here.

bats_require_minimum_version 1.5.0
load helpers

setup() {
  load_libs common pve qmconf storage findings snapplan
}

@test "zfs plan: one atomic snapshot, then per disk clone, device wait and mount, in that order" {
  plan_disks 100 rtest01 zfspool "scsi0:/dev/zvol/rpool/data/vm-100-disk-0:rootfs" "scsi1:/dev/zvol/rpool/data/vm-100-disk-1:mp0"
  [ "${#PLAN[@]}" -eq 7 ]
  [ "${PLAN[0]}" = "zfs-snapshot|vm2lxc-rtest01|rpool/data/vm-100-disk-0,rpool/data/vm-100-disk-1" ]
  [ "${PLAN[1]}" = "zfs-clone|rpool/data/vm-100-disk-0@vm2lxc-rtest01|rpool/data/vm2lxc-100-rtest01-scsi0|scsi0" ]
  [ "${PLAN[2]}" = "zfs-clone|rpool/data/vm-100-disk-1@vm2lxc-rtest01|rpool/data/vm2lxc-100-rtest01-scsi1|scsi1" ]
  [ "${PLAN[3]}" = "dev-ready|/dev/zvol/rpool/data/vm2lxc-100-rtest01-scsi0|scsi0" ]
  [ "${PLAN[5]}" = "mount-disk|/dev/zvol/rpool/data/vm2lxc-100-rtest01-scsi0|scsi0|rootfs" ]
  [ "${PLAN[6]}" = "mount-disk|/dev/zvol/rpool/data/vm2lxc-100-rtest01-scsi1|scsi1|mp0" ]
}

@test "lvm plan: all snapshots first, then activate+loop per disk, then the mounts; loop is named by disk key" {
  plan_disks 101 rtest01 lvmthin "scsi0:/dev/pve/vm-101-disk-0:rootfs" "scsi1:/dev/pve/vm-101-disk-1:mp0"
  [ "${#PLAN[@]}" -eq 8 ]
  [ "${PLAN[0]}" = "lvm-snapshot|pve/vm-101-disk-0|pve/vm2lxc-101-rtest01-scsi0|rtest01" ]
  [ "${PLAN[1]}" = "lvm-snapshot|pve/vm-101-disk-1|pve/vm2lxc-101-rtest01-scsi1|rtest01" ]
  [ "${PLAN[2]}" = "lvm-activate|pve/vm2lxc-101-rtest01-scsi0" ]
  [ "${PLAN[3]}" = "loop-attach|/dev/pve/vm2lxc-101-rtest01-scsi0|scsi0" ]
  [ "${PLAN[6]}" = "mount-disk|loop:scsi0|scsi0|rootfs" ]
  [ "${PLAN[7]}" = "mount-disk|loop:scsi1|scsi1|mp0" ]
}

@test "the plan lists the SOURCES, and no plan step ever names a source as something to create or destroy" {
  plan_disks 101 rtest01 lvmthin "scsi0:/dev/pve/vm-101-disk-0:rootfs"
  [ "${PLAN_SOURCES[0]}" = "pve/vm-101-disk-0" ]
  local line
  for line in "${PLAN[@]}"; do
    case ${line%%|*} in
      lvm-snapshot) IFS='|' read -r _ _ target _ <<<"$line"; [[ $target == pve/vm2lxc-* ]] ;;
      lvm-activate) [[ ${line#*|} == pve/vm2lxc-* ]] ;;
    esac
  done
}

@test "a disk on unsupported storage stops the plan with a plain reason" {
  plan_disks 100 rtest01 dir "scsi0:/var/lib/vz/images/100/vm-100-disk-0.qcow2:rootfs" && return 1
  [[ $PLAN_ERR == *"storage 'st' is type 'dir'"*"not supported by the snapshot layer yet"* ]]
}

@test "a path that does not look like what the storage type promises is refused, not guessed at" {
  plan_disks 100 rtest01 zfspool "scsi0:/dev/pve/vm-100-disk-0:rootfs" && return 1
  [[ $PLAN_ERR == *"expected /dev/zvol/<dataset>"* ]]
  plan_disks 100 rtest01 lvmthin "scsi0:/dev/zvol/rpool/x:rootfs" && return 1
  [[ $PLAN_ERR == *"expected /dev/<vg>/<lv>"* ]]
  plan_disks 100 rtest01 zfspool "scsi0:/dev/zvol/rpool/data/vm-100-disk-0@old:rootfs" && return 1
  [[ $PLAN_ERR == *"not a plain dataset name"* ]]
  plan_disks 100 rtest01 zfspool "scsi0:/dev/zvol/pool_only:rootfs" && return 1
  [[ $PLAN_ERR == *"not a plain dataset name"* ]]
}

@test "an LV that is already a vm2lxc object is never snapshotted again" {
  plan_disks 101 rtest01 lvmthin "scsi0:/dev/pve/vm2lxc-101-old-scsi0:rootfs" && return 1
  [[ $PLAN_ERR == *"already a vm2lxc object"* ]]
}

@test "bad run ids and VM ids are refused; so is a VM with no data disk" {
  plan_disks 100 "BAD ID" zfspool "scsi0:/dev/zvol/rpool/data/x:rootfs" && return 1
  [[ $PLAN_ERR == *"bad run id"* ]]
  plan_disks 100 "r;rm" zfspool "scsi0:/dev/zvol/rpool/data/x:rootfs" && return 1
  plan_disks "1 0" rtest01 zfspool "scsi0:/dev/zvol/rpool/data/x:rootfs" && return 1
  [[ $PLAN_ERR == *"bad VM id"* ]]
  plan_disks 100 rtest01 zfspool && return 1
  [[ $PLAN_ERR == *"no data disks"* ]]
}

@test "an unresolvable volume path is a clear error naming the volume" {
  D_KEY=(scsi0) D_KIND=(data) D_STORAGE=(st) D_VOL=(vm-100-disk-0) D_TARGET=(rootfs) ST_TYPE=([st]=zfspool)
  pve_volume_path() { return 1; }
  snap_plan_build 100 rtest01 && return 1
  [[ $PLAN_ERR == *"could not resolve the location of st:vm-100-disk-0"* ]]
}

@test "only disks of kind data are planned: cdrom, efi, tpm and unused are ignored" {
  D_KEY=(ide2 scsi0 efidisk0 tpmstate0 unused0) D_KIND=(cdrom data efi tpm unused)
  D_STORAGE=(st st st st st) D_VOL=(a vm-1-disk-0 b c d) D_TARGET=(x rootfs x x x) ST_TYPE=([st]=zfspool)
  declare -gA FAKE_PATHS=(["st:vm-1-disk-0"]=/dev/zvol/rpool/data/vm-1-disk-0)
  pve_volume_path() { printf '%s\n' "${FAKE_PATHS[$1]}"; }
  snap_plan_build 100 rtest01
  [ "${#PLAN[@]}" -eq 4 ]
}

@test "snap_plan_executable accepts every kind the planner emits and rejects an unknown one" {
  plan_disks 100 rtest01 zfspool "scsi0:/dev/zvol/rpool/data/vm-100-disk-0:rootfs"
  snap_plan_executable
  plan_disks 101 rtest01 lvmthin "scsi0:/dev/pve/vm-101-disk-0:rootfs"
  snap_plan_executable
  PLAN+=("rm-rf|/")
  snap_plan_executable && return 1
  [[ $PLAN_ERR == *"unknown plan step 'rm-rf'"* ]]
}

@test "the printed plan states the safety promise and numbers every step" {
  plan_disks 101 rtest01 lvmthin "scsi0:/dev/pve/vm-101-disk-0:rootfs"
  run snap_plan_print 101 rtest01
  [[ $output == *"Plan for VM 101, run rtest01"* ]]
  [[ $output == *"only ever the ORIGIN of a snapshot"* ]]
  [[ $output == *"1. lvcreate -s thin snapshot of pve/vm-101-disk-0 as pve/vm2lxc-101-rtest01-scsi0"* ]]
  [[ $output == *"3. losetup -r -f --show -P /dev/pve/vm2lxc-101-rtest01-scsi0"* ]]
  [[ $output == *"Always afterwards, also on error or Ctrl-C"* ]]
}

@test "run ids are generated in the accepted shape" {
  local id
  id=$(snap_gen_run_id)
  [[ $id =~ $RE_RUNID ]]
}

@test "an LVM path whose VG or LV starts with '-' or '.' is refused by the planner" {
  plan_disks 101 rtest01 lvmthin "scsi0:/dev/-x/vm-101-disk-0:rootfs" && return 1
  [[ $PLAN_ERR == *"expected /dev/<vg>/<lv>"* ]]
  plan_disks 101 rtest01 lvmthin "scsi0:/dev/pve/-vm-101-disk-0:rootfs" && return 1
  plan_disks 101 rtest01 lvmthin "scsi0:/dev/.hidden/vm-101-disk-0:rootfs" && return 1
  plan_disks 101 rtest01 lvmthin "scsi0:/dev/pve/vm-101-disk-0:rootfs"
}
