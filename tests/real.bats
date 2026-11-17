#!/usr/bin/env bats
# Regression tests on data CAPTURED FROM A REAL Proxmox VE 9.2 host (tests/fixtures/pve9-real):
# VMs 600-603, the disposable vm2lxc test VMs. Captured read-only on 2026-11-17: qm config,
# pvesh rrddata (month/week/day), pvesm status (trimmed to the three storages involved),
# pveversion, the VM list and pvesm path. Expected numbers were computed independently in
# Python from the captured JSON, not copied from the tool.
#
# What this pins that synthetic fixtures could not: PVE 9's real formats (a "Total (KiB)"
# header, `template: null` in the VM list, a 30-minute month RRD step, cloud-init drives).

bats_require_minimum_version 1.5.0
load helpers

real() { VM2LXC_FIXTURE_DIR="$FIXTURES/pve9-real" run "$VM2LXC" "$@"; }

@test "real host: the PVE 9 version line, node and lvm-thin storage are read correctly" {
  real preflight 603
  [ "$status" -eq 0 ]
  [[ $output == *"node pve9 | PVE 9.2.28 |"* ]]
  [[ $output == *"scsi0     local-lvm (lvmthin)"* ]]
}

@test "real host: a cloud-init VM (cicustom, serial0, vga, agent enabled=1) is GREEN with nothing to report" {
  real preflight 600
  [ "$status" -eq 0 ]
  [[ $output == *"VERDICT: GREEN (provisional)"* ]]
  [[ $output == *"(nothing to report)"* ]]
}

@test "real host: the cloud-init drive (ide2, media=cdrom, a real LV) is ignored, not mapped as a disk" {
  real preflight 600
  [[ $output == *"ide2      cdrom / empty drive"*"-> ignored"* ]]
  [[ $output == *"allocated: 10G"* ]]
}

@test "real host: a two-disk VM maps scsi0 to rootfs and scsi1 to mp0, and adds the sizes up" {
  real preflight 603
  [[ $output == *"2 disks map to scsi0 -> rootfs, scsi1 -> mp0"* ]]
  [[ $output == *"scsi1     local-lvm (lvmthin)          8G      -> mp0"* ]]
  [[ $output == *"allocated: 18G"* ]]
}

@test "real host: under 24h of history keeps the size, with the real p95 and max (600, 602, 603)" {
  real preflight 600
  [[ $output == *"timeframe=day, 3.9 hours of data, 100% of samples, confidence INSUFFICIENT"* ]]
  [[ $output == *"memory 1024M"*"memory p95 859M, max 859M"* ]]
  real preflight 602
  [[ $output == *"memory p95 172M, max 172M"* ]]
  real preflight 603
  [[ $output == *"memory p95 404M, max 479M"* ]]
}

@test "real host: 11 days of span but only 2% of samples (30-minute month step) is LOW, with exact choices" {
  real preflight 601
  [ "$status" -eq 0 ]
  [[ $output == *"rrddata timeframe=month, 11.2 days of data, 2% of samples, confidence LOW"* ]]
  [[ $output == *"memory  p95 935M  max 935M  now 2048M"* ]]
  # lean = up64(ceil(935 x 1.15)) = 1088 ; recommended = up64(max(ceil(935 x 1.25), ceil(935 x 1.10))) = 1216
  [[ $output == *"choices: lean 1088M | recommended 1216M | keep 2048M"* ]]
  [[ $output == *'RAM saved at "recommended": 832M'* ]]
  [[ $output == *"only 2% of the expected samples exist"* ]]
  [[ $output == *"30-minute averages"* ]]
}

@test "real host: scan shows the full test VM names, ranks 601 first by its saving, template:null is not a template" {
  real scan 600 601 602 603
  [ "$status" -eq 0 ]
  [[ $output == *"vm2lxc-test-deb12-svc"* ]]
  [[ $output == *"vm2lxc-test-deb12-2disk"* ]]
  [[ $output == *"4 VMs: 4 green, 0 yellow, 0 red"* ]]
  local ids
  ids=$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { printf "%s ", $2 }' <<<"$output")
  [ "$ids" = "601 600 602 603 " ]
  [[ $output == *"2048M -> 1216M"*"832M"* ]]
}

@test "real host: the inspect plan for the 2-disk VM snapshots both LVs of VG pve and names every object vm2lxc-" {
  VM2LXC_RUN_ID=rtest01 real inspect 603
  [ "$status" -eq 0 ]
  [[ $output == *"lvcreate -s thin snapshot of pve/vm-603-disk-0 as pve/vm2lxc-603-rtest01-scsi0"* ]]
  [[ $output == *"lvcreate -s thin snapshot of pve/vm-603-disk-1 as pve/vm2lxc-603-rtest01-scsi1"* ]]
  [[ $output == *"Nothing was executed"* ]]
}

@test "real host: the names the planner would create all pass the executor's own allowlist" {
  # plan names and the executor's patterns must agree, or a run would be refused half-way
  load_libs common pve qmconf storage findings snapplan hostexec
  export VM2LXC_FIXTURE_DIR="$FIXTURES/pve9-real"
  host_context_load
  vm_context_load 603
  snap_plan_build 603 rtest01
  local line origin snap run dev
  for line in "${PLAN[@]}"; do
    case ${line%%|*} in
      lvm-snapshot)
        IFS='|' read -r _ origin snap run <<<"$line"
        [[ $snap =~ $RE_LV_SNAP ]]
        [[ ${snap#*/} =~ $RE_LV_NAME ]]
        [[ $origin =~ $RE_LV_ORIGIN ]]
        ;;
      loop-attach)
        IFS='|' read -r _ dev _ <<<"$line"
        [[ $dev =~ $RE_DEV_LVSNAP ]]
        ;;
    esac
  done
}
