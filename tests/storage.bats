#!/usr/bin/env bats
# `pvesm status` parsing and the v1 storage policy (D1: zfs + lvm-thin only).

bats_require_minimum_version 1.5.0
load helpers

@test "storage_load reads name, type and status from pvesm status, skipping the header" {
  load_libs common storage
  storage_load <"$FIXTURES/pve8/pvesm-status.txt"
  [ "${#ST_TYPE[@]}" -eq 7 ]
  [ "${ST_TYPE[local-zfs]}" = zfspool ]
  [ "${ST_TYPE[local-lvm]}" = lvmthin ]
  [ "${ST_TYPE[local]}" = dir ]
  [ "${ST_TYPE[ceph-pool]}" = rbd ]
  [ "${ST_STATUS[local-zfs]}" = active ]
  [ "${ST_STATUS[tank-off]}" = disabled ]
  [ -z "${ST_TYPE[Name]:-}" ]
}

@test "storage_load resets the map on every call" {
  load_libs common storage
  storage_load <"$FIXTURES/pve8/pvesm-status.txt"
  storage_load <<'EOF'
Name Type Status Total Used Available %
only zfspool active 1 1 1 1%
EOF
  [ "${#ST_TYPE[@]}" -eq 1 ]
}

@test "only zfspool and lvmthin are supported in v1" {
  load_libs common storage
  local t
  for t in zfspool lvmthin; do storage_is_supported "$t"; done
  for t in dir lvm nfs cifs rbd cephfs zfs iscsi btrfs glusterfs pbs mystery; do
    if storage_is_supported "$t"; then echo "$t wrongly supported"; return 1; fi
  done
}

@test "every unsupported type has a plain-words reason, and they differ by family" {
  load_libs common storage
  [[ $(storage_reason dir) == *"qcow2"* ]]
  [[ $(storage_reason rbd) == *"Ceph"* ]]
  [[ $(storage_reason lvm) == *"thick LVM"* ]]
  [[ $(storage_reason pbs) == *"backup"* ]]
  [[ $(storage_reason mystery) == *"unknown"* ]]
}
