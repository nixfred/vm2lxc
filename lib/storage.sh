# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# Storage map from `pvesm status`, and what v1 supports (D1: zfs + lvm-thin only).

declare -gA ST_TYPE=() ST_STATUS=()

# storage_load: read `pvesm status` text on stdin.
#   Name   Type   Status   Total   Used   Available   %
storage_load() {
  local name stype status _rest
  ST_TYPE=()
  ST_STATUS=()
  while read -r name stype status _rest; do
    if [[ -z $name || $name == Name ]]; then
      continue
    fi
    ST_TYPE[$name]=$stype
    ST_STATUS[$name]=$status
  done
}

# storage_is_supported <type>: rc 0 when v1 can snapshot it at the storage layer.
storage_is_supported() {
  case $1 in
    zfspool | lvmthin) return 0 ;;
    *) return 1 ;;
  esac
}

# storage_reason <type>: plain-words reason a type is not supported yet.
storage_reason() {
  case $1 in
    dir | nfs | cifs | glusterfs | btrfs)
      printf 'file-based storage (qcow2/raw files): planned after v1'
      ;;
    rbd | cephfs)
      printf 'Ceph storage: planned after v1'
      ;;
    lvm)
      printf 'thick LVM has no cheap snapshots: not planned for v1'
      ;;
    zfs | iscsi | iscsidirect)
      printf 'network block storage: not planned for v1'
      ;;
    pbs)
      printf 'backup storage cannot hold VM disks'
      ;;
    *)
      printf 'unknown storage type'
      ;;
  esac
}
