# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# The snapshot plan: a PURE description of what the snapshot-mount layer would do for
# one VM. Building it makes no host call except the read-only `pvesm path`, so it is
# safe to print as a dry run anywhere. Design: docs/snapshot-layer.html.
#
# PLAN is an array of "kind|field|field...". Kinds, in the order they run:
#   zfs-snapshot|<snapname>|<ds1>,<ds2>      one atomic snapshot of every source zvol
#   zfs-clone|<ds>@<snapname>|<clone>|<key>  read-only, stamped clone of that snapshot
#   dev-ready|<device>|<key>                 wait for the clone's device and partitions
#   lvm-snapshot|<vg>/<lv>|<vg>/<snaplv>|<run>   thin snapshot, tagged, made read-only
#   lvm-activate|<vg>/<snaplv>               activate it (thin snapshots skip activation)
#   loop-attach|/dev/<vg>/<snaplv>|<key>     read-only loop device with partition scan
#   mount-disk|<device>|<key>|<target>       mount its supported filesystems read-only
#                                            (<device> is loop:<key> for LVM: resolved at run time)

RE_RUNID='^[a-z][a-z0-9]{3,30}$'
RE_ZDS='^[A-Za-z0-9_][A-Za-z0-9_.:-]*(/[A-Za-z0-9_][A-Za-z0-9_.:-]*)+$'
RE_VGLV='^/dev/([A-Za-z0-9_+.-]+)/([A-Za-z0-9_+.-]+)$'

PLAN=()
PLAN_ERR=""
PLAN_SOURCES=() # source datasets / LVs: the objects that must never be touched (R5)
PLAN_DISKS=()   # "key|target|device" per data disk, for the printout

snap_gen_run_id() {
  printf 'r%s%04x' "$(date +%s)" $((RANDOM % 65536))
}

# snap_plan_build <vmid> <runid>: uses the loaded VM context (D_* arrays, ST_TYPE).
# rc 0 and PLAN filled, or rc 1 and PLAN_ERR says why.
snap_plan_build() {
  local vmid=$1 run=$2
  local i key st stype vol path ds parent clone snapname
  local -a z_ds=() z_clone=() z_key=() z_dev=() z_target=() lv_snap=() lv_ready=() lv_mount=()
  local n_data=0

  PLAN=() PLAN_ERR="" PLAN_SOURCES=() PLAN_DISKS=()
  vmid_valid "$vmid" || {
    PLAN_ERR="bad VM id '$vmid'"
    return 1
  }
  [[ $run =~ $RE_RUNID ]] || {
    PLAN_ERR="bad run id '$run'"
    return 1
  }
  snapname="vm2lxc-$run"

  for i in "${!D_KEY[@]}"; do
    [[ ${D_KIND[$i]} == data ]] || continue
    n_data=$((n_data + 1))
    key=${D_KEY[$i]}
    st=${D_STORAGE[$i]}
    vol=${D_VOL[$i]}
    stype=${ST_TYPE[$st]:-}
    case $stype in
      zfspool | lvmthin) ;;
      *)
        PLAN_ERR="disk $key: storage '$st' is type '${stype:-unknown}', not supported by the snapshot layer yet"
        return 1
        ;;
    esac
    path=$(pve_volume_path "$st:$vol") || {
      PLAN_ERR="disk $key: could not resolve the location of $st:$vol (pvesm path failed)"
      return 1
    }
    case $stype in
      zfspool)
        if [[ $path != /dev/zvol/* ]]; then
          PLAN_ERR="disk $key: expected /dev/zvol/<dataset> for a zfspool volume, got '$path'"
          return 1
        fi
        ds=${path#/dev/zvol/}
        if [[ ! $ds =~ $RE_ZDS || $ds == *@* ]]; then
          PLAN_ERR="disk $key: '$ds' is not a plain dataset name I will handle"
          return 1
        fi
        parent=${ds%/*}
        clone="$parent/vm2lxc-$vmid-$run-$key"
        if [[ $clone == "$ds" ]]; then
          PLAN_ERR="disk $key: the clone name equals the source dataset (refusing)"
          return 1
        fi
        PLAN_SOURCES+=("$ds")
        z_ds+=("$ds")
        z_clone+=("$clone")
        z_key+=("$key")
        z_dev+=("/dev/zvol/$clone")
        z_target+=("${D_TARGET[$i]}")
        ;;
      lvmthin)
        if [[ ! $path =~ $RE_VGLV ]]; then
          PLAN_ERR="disk $key: expected /dev/<vg>/<lv> for an lvmthin volume, got '$path'"
          return 1
        fi
        local vg=${BASH_REMATCH[1]} lv=${BASH_REMATCH[2]} snaplv="vm2lxc-$vmid-$run-$key"
        if [[ $lv == vm2lxc-* ]]; then
          PLAN_ERR="disk $key: '$vg/$lv' is already a vm2lxc object (refusing to snapshot it)"
          return 1
        fi
        PLAN_SOURCES+=("$vg/$lv")
        lv_snap+=("lvm-snapshot|$vg/$lv|$vg/$snaplv|$run")
        lv_ready+=("lvm-activate|$vg/$snaplv" "loop-attach|/dev/$vg/$snaplv|$key")
        lv_mount+=("mount-disk|loop:$key|$key|${D_TARGET[$i]}")
        PLAN_DISKS+=("$key|${D_TARGET[$i]}|/dev/$vg/$snaplv")
        ;;
      *)
        PLAN_ERR="disk $key: storage '$st' is type '${stype:-unknown}', not supported by the snapshot layer yet"
        return 1
        ;;
    esac
  done
  ((n_data > 0)) || {
    PLAN_ERR="the VM has no data disks"
    return 1
  }

  if ((${#z_ds[@]} > 0)); then
    PLAN+=("zfs-snapshot|$snapname|$(
      IFS=,
      printf '%s' "${z_ds[*]}"
    )")
    for i in "${!z_ds[@]}"; do
      PLAN+=("zfs-clone|${z_ds[$i]}@$snapname|${z_clone[$i]}|${z_key[$i]}")
    done
    for i in "${!z_ds[@]}"; do
      PLAN+=("dev-ready|${z_dev[$i]}|${z_key[$i]}")
    done
    for i in "${!z_ds[@]}"; do
      PLAN+=("mount-disk|${z_dev[$i]}|${z_key[$i]}|${z_target[$i]}")
      PLAN_DISKS+=("${z_key[$i]}|${z_target[$i]}|${z_dev[$i]}")
    done
  fi
  if ((${#lv_snap[@]} > 0)); then
    PLAN+=("${lv_snap[@]}" "${lv_ready[@]}" "${lv_mount[@]}")
  fi
  return 0
}

# snap_plan_executable: rc 0 if every step has a handler in this build, else PLAN_ERR says
# which one cannot run. Checked BEFORE anything is created.
snap_plan_executable() {
  local line kind
  for line in "${PLAN[@]}"; do
    kind=${line%%|*}
    case $kind in
      zfs-snapshot | zfs-clone | dev-ready | lvm-snapshot | lvm-activate | loop-attach | mount-disk) ;;
      *)
        PLAN_ERR="unknown plan step '$kind'"
        return 1
        ;;
    esac
  done
  return 0
}

# Human-readable plan. Pure printing.
snap_plan_print() {
  local vmid=$1 run=$2 line n=0 kind f1 f2 f3 f4
  printf 'Plan for VM %s, run %s\n' "$vmid" "$run"
  printf 'Source volumes are only ever the ORIGIN of a snapshot: never opened, written or edited.\n\n'
  for line in "${PLAN[@]}"; do
    n=$((n + 1))
    IFS='|' read -r kind f1 f2 f3 f4 <<<"$line"
    case $kind in
      zfs-snapshot)
        local -a dss
        local d names=""
        IFS=, read -ra dss <<<"$f2"
        for d in "${dss[@]}"; do names+="${names:+ }$d@$f1"; done
        printf '  %d. zfs snapshot -o vm2lxc:run=%s  %s  (one atomic command)\n' "$n" "${f1#vm2lxc-}" "$names"
        ;;
      zfs-clone)
        printf '  %d. zfs clone -o readonly=on -o vm2lxc:run=%s  %s  ->  %s\n' "$n" "${f1##*@vm2lxc-}" "$f1" "$f2"
        ;;
      dev-ready) printf '  %d. wait for %s and its partitions (udevadm settle)\n' "$n" "$f1" ;;
      mount-disk) printf '  %d. mount supported filesystems of %s read-only  (disk %s, becomes %s)\n' "$n" "${f1/#loop:/the loop device of disk }" "$f2" "$f3" ;;
      lvm-snapshot) printf '  %d. lvcreate -s thin snapshot of %s as %s (tag vm2lxc-%s), made read-only with lvchange -pr\n' "$n" "$f1" "$f2" "$f3" ;;
      lvm-activate) printf '  %d. lvchange -ay -K %s (thin snapshots skip activation by default)\n' "$n" "$f1" ;;
      loop-attach) printf '  %d. losetup -r -f --show -P %s  (read-only loop device, scans partitions; disk %s)\n' "$n" "$f1" "$f2" ;;
    esac
  done
  printf '\nThen: look inside, run the guest checks. Always afterwards, also on error or Ctrl-C:\n'
  printf '  unmount everything, destroy the clones, destroy the snapshot, in reverse order,\n'
  printf '  verifying each object is ours (the vm2lxc-%s tag or stamp) before it is touched.\n' "$run"
}
