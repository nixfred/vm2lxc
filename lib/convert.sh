# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # globals set here are consumed by sibling lib files
# `vm2lxc convert <vmid>` and `vm2lxc undo <ct>`.
#
# convert turns a stopped-and-snapshotted VM into a NEW container, in two phases that share one journal:
#
#   phase A  (executed by run_apply, the same engine as `inspect`)
#     vm-stop        stop-and-copy (D2): the VM is shut down, so the snapshot is consistent
#     vm-onboot      a VM that autostarts would boot beside its container (D3): onboot is set to 0
#     <snapshot layer>  snapshot, read-only clone/activation, loop device, read-only mounts
#   gate: find the guest root, run the 12 guest checks. RED refuses; everything is torn down, VM restarted.
#   phase B  (decided from what the guest says: its NIC names, its fstab, its OS)
#     stage-dir, tar-create   the guest filesystems are archived under /var/tmp/vm2lxc/<run>/
#     ct-create               `pct create` from the archive: unprivileged (D5), the VM's exact MAC (D4),
#                             extra disks as mount points (D6), tagged vm2lxc-<run> so it can be identified
#     ct-mount, ct-fixup, ct-copy-disk, ct-unmount   fstab/cloud-init/serial-getty fix-ups, extra disks
#     ct-start        only with --start (the cutover)
#   commit: the container and the VM's stopped state are marked KEPT, the journal says COMMITTED, and the
#   rest (snapshot layer, staged archives) is torn down as in `inspect`.
#
# undo <ct> reverses the KEPT steps of a committed conversion, newest first: stop and destroy the container,
# restore the VM's autostart flag, start the VM again (never while the container runs).
#
# The source VM's disks are never written: the only things done to the VM are shutdown, `onboot 0`, and
# (undo) start and `onboot 1`.

# the steps that stay after a successful conversion
CONV_KEPT_KINDS=" vm-stop vm-onboot ct-create ct-start "

CONV_CTID="" CONV_HOSTNAME="" CONV_MEM="" CONV_CORES="" CONV_PRIV=0 CONV_MAPBASE=100000
CONV_NICS=()  # "netN|bridge|mac|tag|firewall"
CONV_MPS=()   # "key|mpN|storage|size_gb"
CONV_OPTS=()  # pct create options after the archive, as '--name' 'value' pairs
CONV_NOTES=() # things worth printing
CONV_USB_LOST=() # usbN settings that could NOT be mapped, repeated in the final summary (R39: never silent)

# conv_hostname <vm name> <ctid>: an RFC 1123 label from the VM's name
conv_hostname() {
  local h=${1,,}
  h=${h//[^a-z0-9-]/-}
  h=${h#"${h%%[!-]*}"}
  h=${h:0:63}
  h=${h%"${h##*[!-]}"}
  [[ $h =~ $RE_CT_NAME ]] || h="ct$2"
  printf '%s' "$h"
}

# conv_subuid_base: the first uid of root's subordinate range (an unprivileged container's id map)
conv_subuid_base() {
  local b=""
  if [[ -r /etc/subuid ]]; then
    b=$(awk -F: '$1 == "root" && $3 >= 65536 { print $2; exit }' /etc/subuid 2>/dev/null)
  fi
  [[ $b =~ ^[0-9]{5,10}$ ]] || b=100000
  printf '%s' "$b"
}

conv_gb() { printf '%d' $((($1 + 1023) / 1024)); } # MB -> whole GB, rounded up

# conv_tag <text>: a PVE tag from free text
conv_tag() {
  local t=${1,,}
  t=${t//[^a-z0-9_.+-]/-}
  [[ $t =~ ^[a-z0-9_][a-z0-9_.+-]*$ ]] && printf '%s' "$t"
}

# --- reading the guest -------------------------------------------------------------------------------

# conv_guest_ifnames <root>: the interface names the guest's own network config uses, in order, one per line
conv_guest_ifnames() {
  local root=$1 f line name seen=" "
  local -a files=()
  if gfs_is_file "$root" /etc/network/interfaces; then files+=(/etc/network/interfaces); fi
  while IFS= read -r f; do files+=("/etc/network/interfaces.d/$f"); done < <(gfs_entries "$root" /etc/network/interfaces.d 2>/dev/null)
  while IFS= read -r f; do files+=("/etc/netplan/$f"); done < <(gfs_entries "$root" /etc/netplan 2>/dev/null | grep -E '\.ya?ml$' || true)
  while IFS= read -r f; do files+=("/etc/systemd/network/$f"); done < <(gfs_entries "$root" /etc/systemd/network 2>/dev/null | grep -E '\.network$' || true)
  for f in "${files[@]}"; do
    gfs_is_file "$root" "$f" || continue
    while IFS= read -r line; do
      line=${line%%#*}
      name=""
      if [[ $line =~ ^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+([A-Za-z0-9_.:-]+) ]]; then
        name=${BASH_REMATCH[2]}
      elif [[ $line =~ ^[[:space:]]*set-name:[[:space:]]*\"?([A-Za-z0-9_.-]+) ]]; then
        name=${BASH_REMATCH[1]}
      elif [[ $line =~ ^[[:space:]]+((en|eth|ens|enp|eno|enx)[A-Za-z0-9]*[0-9]):[[:space:]]*$ ]]; then # ends in a digit: 'ethernets:' is a netplan key, not a NIC
        name=${BASH_REMATCH[1]}
      elif [[ $line =~ ^[[:space:]]*Name=((en|eth|ens|enp|eno|enx)[A-Za-z0-9]*[0-9])[[:space:]]*$ ]]; then
        name=${BASH_REMATCH[1]}
      fi
      [[ -n $name && $name != lo && $name != *:* && ${#name} -le 15 && $seen != *" $name "* ]] || continue
      seen+="$name "
      printf '%s\n' "$name"
    done < <(gfs_cat "$root" "$f")
  done
}

# conv_netplan_mac_match <root>: does any netplan file match the NIC by MAC address?
conv_netplan_mac_match() {
  local f
  while IFS= read -r f; do
    [[ $f =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || continue
    gfs_cat "$1" "/etc/netplan/$f" 2>/dev/null | grep -qE '^[[:space:]]*macaddress:' && return 0
  done < <(gfs_entries "$1" /etc/netplan 2>/dev/null)
  return 1
}

# conv_fstab_mountpoint <root> <uuid> <label>: where the guest's fstab mounts the filesystem with that id
conv_fstab_mountpoint() {
  local root=$1 uuid=$2 label=$3 line dev mp
  gfs_is_file "$root" /etc/fstab || return 1
  while IFS= read -r line; do
    line=${line%%#*}
    # shellcheck disable=SC2086
    set -- $line
    (($# >= 3)) || continue
    dev=$1 mp=$2
    if [[ -n $uuid && ($dev == "UUID=$uuid" || $dev == "/dev/disk/by-uuid/$uuid") ]] ||
      [[ -n $label && ($dev == "LABEL=$label" || $dev == "/dev/disk/by-label/$label") ]]; then
      [[ $mp =~ ^/[A-Za-z0-9_./-]*$ && $mp != *..* && $mp != / ]] || return 1
      printf '%s' "$mp"
      return 0
    fi
  done < <(gfs_cat "$root" /etc/fstab)
  return 1
}

# conv_fs_ids <device>: sets CONV_UUID and CONV_LABEL (empty when unknown) for a mounted clone
conv_fs_ids() {
  CONV_UUID="" CONV_LABEL=""
  CONV_UUID=$(host_cmd blkid -s UUID -o value "$1" 2>/dev/null) || CONV_UUID=""
  CONV_LABEL=$(host_cmd blkid -s LABEL -o value "$1" 2>/dev/null) || CONV_LABEL=""
  CONV_UUID=${CONV_UUID//[^A-Za-z0-9-]/}
  CONV_LABEL=${CONV_LABEL//[^A-Za-z0-9_.-]/}
}

# --- inputs, from the VM's own config ---------------------------------------------------------------------

# conv_inputs <vmid> <run>: everything that does not need the guest. rc 1 + PLAN_ERR on a problem.
conv_inputs() {
  local vmid=$1 run=$2 i key kind size_mb boot_i=-1 n_mp=0 mpn
  PLAN_ERR=""
  CONV_NICS=() CONV_MPS=() CONV_OPTS=() CONV_NOTES=() CONV_USB_LOST=()
  CONV_PRIV=$OPT_PRIVILEGED
  CONV_MAPBASE=$(conv_subuid_base)

  if [[ -n $OPT_CTID ]]; then
    CONV_CTID=$OPT_CTID
  else
    CONV_CTID=$(pve_nextid 2>/dev/null) || CONV_CTID=""
  fi
  [[ $CONV_CTID =~ $RE_CTID ]] || {
    PLAN_ERR="'$CONV_CTID' is not a valid container id (use --ctid N, 100 or higher)"
    return 1
  }
  if pve_id_in_use "$CONV_CTID"; then
    PLAN_ERR="id $CONV_CTID is already a VM or a container on this host (choose another with --ctid)"
    return 1
  fi
  CONV_HOSTNAME=$OPT_HOSTNAME
  [[ -n $CONV_HOSTNAME ]] || CONV_HOSTNAME=$(conv_hostname "$(qmc_get name)" "$CONV_CTID")
  [[ $CONV_HOSTNAME =~ $RE_CT_NAME ]] || {
    PLAN_ERR="'$CONV_HOSTNAME' is not a valid hostname"
    return 1
  }
  CONV_MEM=${OPT_MEMORY:-$(qmc_memory_mb)}
  CONV_CORES=${OPT_CORES:-$(qmc_cores)}
  [[ $CONV_MEM =~ ^[0-9]{2,6}$ && $CONV_CORES =~ ^[0-9]{1,3}$ ]] || {
    PLAN_ERR="memory '$CONV_MEM' or cores '$CONV_CORES' is not a usable number"
    return 1
  }

  # disks: the boot disk becomes the rootfs, the others mount points (D6), on the same storage as the source
  for i in "${!D_KEY[@]}"; do
    [[ ${D_KIND[$i]} == data ]] || continue
    key=${D_KEY[$i]}
    size_mb=${D_SIZE_MB[$i]:-}
    [[ $size_mb =~ ^[0-9]+$ && $size_mb -gt 0 ]] || {
      PLAN_ERR="disk $key has no readable size"
      return 1
    }
    if [[ ${D_TARGET[$i]} == rootfs ]]; then
      boot_i=$i
    else
      mpn=${D_TARGET[$i]}
      n_mp=$((n_mp + 1))
      CONV_MPS+=("$key|$mpn|${D_STORAGE[$i]}|$(conv_gb "$size_mb")")
    fi
  done
  ((boot_i >= 0)) || {
    PLAN_ERR="the VM has no data disk to become the container's root filesystem"
    return 1
  }
  CONV_BOOT_KEY=${D_KEY[$boot_i]}
  CONV_BOOT_STORAGE=${D_STORAGE[$boot_i]}
  CONV_BOOT_GB=$(conv_gb "${D_SIZE_MB[$boot_i]}")

  # NICs: the VM's exact MAC, bridge and VLAN (D4/G5). The interface name is decided from the guest later.
  local fw
  for i in "${!N_KEY[@]}"; do
    [[ -n ${N_MAC[$i]} && -n ${N_BRIDGE[$i]} ]] || {
      PLAN_ERR="${N_KEY[$i]} has no MAC address or bridge: the container could not keep the VM's network identity"
      return 1
    }
    fw=$(csv_opt "${QMC[${N_KEY[$i]}]}" firewall || true)
    CONV_NICS+=("${N_KEY[$i]}|${N_BRIDGE[$i]}|${N_MAC[$i]}|${N_TAG[$i]}|${fw:-0}")
  done
  ((${#CONV_NICS[@]} > 0)) || CONV_NOTES+=("the VM has no network interface: the container will have none either")
  return 0
}

# conv_tags_and_desc <vmid> <run>: sets CONV_TAGS and CONV_DESC
conv_tags_and_desc() {
  local vmid=$1 run=$2 t vt nm
  CONV_TAGS="vm2lxc;vm2lxc-$run"
  vt=$(qmc_get tags)
  local IFS=';,'
  for t in $vt; do
    t=$(conv_tag "$t") || continue
    [[ ";$CONV_TAGS;" == *";$t;"* ]] || CONV_TAGS+=";$t"
  done
  nm=$(qmc_get name)
  nm=${nm//[^A-Za-z0-9._-]/_}
  CONV_DESC="vm2lxc:run=$run converted from VM $vmid ($nm)"
}

# --- phase A: what runs before the guest has been looked at ------------------------------------------------

# conv_phase_a_plan <vmid> <was-running>: PLAN = the VM steps, then the snapshot layer's steps (already in PLAN)
conv_phase_a_plan() {
  local vmid=$1 was=$2 old
  local -a snap=("${PLAN[@]}")
  old=$(qmc_get onboot 0)
  [[ $old == 1 ]] || old=0
  PLAN=("vm-stop|$vmid|$was|$CONV_CTID")
  if [[ $old == 1 ]]; then PLAN+=("vm-onboot|$vmid|$old"); fi
  PLAN+=("${snap[@]}")
}

# --- phase B: decided from the guest -----------------------------------------------------------------------

# conv_decide <vmid> <run>: reads the guest (GUEST_ROOT, MOUNTS) and builds PLAN for phase B and CONV_OPTS.
# rc 1 + PLAN_ERR when the guest cannot be converted by v1.
conv_decide() {
  local vmid=$1 run=$2 stage m key target dev mnt fs i name idx mpn path sto gb spec nkey bridge mac tag fw
  local -a names=() mp_mounts=() boot_other=() opts_net=() opts_mp=() plan_mp=() mine=()
  stage="$(stage_root)/$run"
  PLAN_ERR=""

  # which mounted filesystems belong to the boot disk and which to the extra disks
  for m in "${MOUNTS[@]}"; do
    IFS='|' read -r key target dev mnt fs <<<"$m"
    if [[ $key == "$CONV_BOOT_KEY" ]]; then
      [[ $mnt == "$GUEST_ROOT" ]] || boot_other+=("$m")
    else
      mp_mounts+=("$m")
    fi
  done

  # G9: no silent data loss. A second filesystem on the boot disk is only fine if the guest's fstab shows it
  # is /boot (kernels the container does not use).
  for m in "${boot_other[@]}"; do
    IFS='|' read -r key target dev mnt fs <<<"$m"
    conv_fs_ids "$dev"
    path=$(conv_fstab_mountpoint "$GUEST_ROOT" "$CONV_UUID" "$CONV_LABEL") || path=""
    case $path in
      /boot | /boot/efi) CONV_NOTES+=("partition $dev ($fs) is the guest's $path: not copied (the container uses the host's kernel)") ;;
      *)
        PLAN_ERR="the boot disk has another filesystem ($dev, $fs${path:+, mounted at $path in the guest}) that would not be copied: v1 converts one filesystem per disk. Nothing was lost and nothing was changed."
        return 1
        ;;
    esac
  done

  # NIC names: the names the guest's own network config uses, so that it works unchanged (D4)
  while IFS= read -r name; do names+=("$name"); done < <(conv_guest_ifnames "$GUEST_ROOT")
  for i in "${!CONV_NICS[@]}"; do
    IFS='|' read -r nkey bridge mac tag fw <<<"${CONV_NICS[$i]}"
    idx=${nkey#net}
    name=${names[$i]:-ens$((18 + idx))}
    spec="name=$name,bridge=$bridge,hwaddr=$mac,type=veth"
    if [[ -n $tag ]]; then spec+=",tag=$tag"; fi
    if [[ $fw == 1 ]]; then spec+=",firewall=1"; fi
    opts_net+=("--$nkey" "$spec")
    CONV_NOTES+=("$nkey: interface '$name', MAC $mac, bridge $bridge${tag:+, VLAN $tag}")
  done

  # extra disks -> mount points, at the path the guest's fstab gives them
  for i in "${!CONV_MPS[@]}"; do
    IFS='|' read -r key mpn sto gb <<<"${CONV_MPS[$i]}"
    mine=()
    for m in "${mp_mounts[@]}"; do
      if [[ ${m%%|*} == "$key" ]]; then mine+=("$m"); fi
    done
    if ((${#mine[@]} != 1)); then
      PLAN_ERR="disk $key has ${#mine[@]} mountable filesystem(s): v1 converts exactly one per extra disk"
      return 1
    fi
    IFS='|' read -r _ _ dev mnt fs <<<"${mine[0]}"
    conv_fs_ids "$dev"
    path=$(conv_fstab_mountpoint "$GUEST_ROOT" "$CONV_UUID" "$CONV_LABEL") || path=""
    if [[ -z $path ]]; then
      path="/mnt/$key"
      CONV_NOTES+=("$key: the guest's fstab does not name this filesystem by UUID or LABEL, so it is mounted at $path")
    fi
    opts_mp+=("--$mpn" "$sto:$gb,mp=$path")
    plan_mp+=("$mpn|$mnt|$path")
  done

  # USB passthrough -> device nodes (R39). The VM is stopped by now, so the host sees the device again.
  local opts_dev=() ndev=0 ukey unode
  while IFS= read -r ukey; do
    [[ -n $ukey ]] || continue
    if usb_resolve "${QMC[$ukey]}"; then
      for unode in "${USB_NODES[@]}"; do
        opts_dev+=("--dev$ndev" "$unode") # past dev99 the allowlist refuses, which fails safe (Proxmox allows usb0-usb4)
        ndev=$((ndev + 1))
      done
      CONV_NOTES+=("$ukey (${QMC[$ukey]%%,*}): $USB_NOTE")
    elif [[ $USB_KIND != spice ]]; then
      CONV_USB_LOST+=("$ukey (${QMC[$ukey]%%,*}): $USB_NOTE")
      CONV_NOTES+=("$ukey (${QMC[$ukey]%%,*}) was NOT mapped: $USB_NOTE")
    fi
  done < <(qmc_keys '^usb[0-9]+$')

  if conv_netplan_mac_match "$GUEST_ROOT"; then
    CONV_NOTES+=("the guest's netplan matches the NIC by MAC address (cloud-init does this); a container's veth has no permanent MAC, so the copy's netplan is changed to match by interface name (originals kept as *.vm2lxc-orig)")
  fi
  conv_tags_and_desc "$vmid" "$run"
  CONV_OPTS=(--hostname "$CONV_HOSTNAME" --memory "$CONV_MEM" --cores "$CONV_CORES" --rootfs "$CONV_BOOT_STORAGE:$CONV_BOOT_GB")
  CONV_OPTS+=("${opts_mp[@]}" "${opts_net[@]}" "${opts_dev[@]}")
  CONV_OPTS+=(--unprivileged "$((1 - CONV_PRIV))" --ostype unmanaged --features nesting=1 --onboot 0 --start 0 --arch amd64
    --tags "$CONV_TAGS" --description "$CONV_DESC")
  CONV_NOTES+=("guest OS ${GUEST_OS_PRETTY:-unknown} (detected ostype $GUEST_OSTYPE): created as unmanaged, so Proxmox does not rewrite the guest's own network config")

  # phase B plan: PLAN lines are 'kind|field|field...', so the pct create options are joined with '|'
  local opts_joined="" o
  for o in "${CONV_OPTS[@]}"; do opts_joined+="|$o"; done
  PLAN=("stage-dir|$stage" "tar-create|$GUEST_ROOT|$stage/rootfs.tar")
  for m in "${plan_mp[@]}"; do
    IFS='|' read -r mpn mnt path <<<"$m"
    PLAN+=("tar-create|$mnt|$stage/$mpn.tar")
  done
  PLAN+=("ct-create|$CONV_CTID|$stage/rootfs.tar$opts_joined")
  PLAN+=("ct-mount|$CONV_CTID" "ct-fixup|$CONV_CTID|$CONV_PRIV|$CONV_MAPBASE")
  for m in "${plan_mp[@]}"; do
    IFS='|' read -r mpn mnt path <<<"$m"
    PLAN+=("ct-copy-disk|$CONV_CTID|$stage/$mpn.tar|$path|$CONV_PRIV|$CONV_MAPBASE")
  done
  PLAN+=("ct-unmount|$CONV_CTID")
  if ((OPT_START)); then PLAN+=("ct-start|$CONV_CTID"); fi
  return 0
}

# --- printing ----------------------------------------------------------------------------------------------

conv_print_inputs() {
  local vmid=$1 i key mpn sto gb
  printf 'Container to create (decided before touching anything):\n'
  printf '  id %s, hostname %s, %s MB RAM, %s cores, %s\n' "$CONV_CTID" "$CONV_HOSTNAME" "$CONV_MEM" "$CONV_CORES" \
    "$( ((CONV_PRIV)) && echo 'PRIVILEGED (opt-in)' || echo 'unprivileged')"
  printf '  rootfs %s:%sG from disk %s (the boot disk)\n' "$CONV_BOOT_STORAGE" "$CONV_BOOT_GB" "$CONV_BOOT_KEY"
  for i in "${!CONV_MPS[@]}"; do
    IFS='|' read -r key mpn sto gb <<<"${CONV_MPS[$i]}"
    printf '  %s %s:%sG from disk %s (its path comes from the guest'"'"'s fstab)\n' "$mpn" "$sto" "$gb" "$key"
  done
  for i in "${!CONV_NICS[@]}"; do
    IFS='|' read -r key mpn sto gb fw <<<"${CONV_NICS[$i]}"
    printf '  %s: the VM'"'"'s exact MAC %s on bridge %s%s (interface name taken from the guest'"'"'s network config)\n' \
      "$key" "$sto" "$mpn" "${gb:+, VLAN $gb}"
  done
  conv_print_usb
  printf '\n'
}

# conv_print_usb: what will happen to each usbN setting, and whether the device is on the host right now
conv_print_usb() {
  local ukey why
  while IFS= read -r ukey; do
    [[ -n $ukey ]] || continue
    usb_parse_spec "${QMC[$ukey]}"
    case $USB_KIND in
      spice) continue ;;
      vidpid | port)
        if usb_find "${QMC[$ukey]}"; then
          printf '  %s: %s is on the host now (port %s); once the VM has stopped it is mapped into the container as device entries (USB node, and its serial port if the host driver makes one)\n' \
            "$ukey" "${QMC[$ukey]%%,*}" "$USB_SYS"
        else
          printf '  %s: %s will NOT be mapped unless that changes before the VM stops: %s\n' "$ukey" "${QMC[$ukey]%%,*}" "$USB_NOTE"
        fi
        ;;
      *)
        usb_find "${QMC[$ukey]}" || why=$USB_NOTE
        printf '  %s: %s will NOT be mapped: %s\n' "$ukey" "${QMC[$ukey]%%,*}" "$why"
        ;;
    esac
  done < <(qmc_keys '^usb[0-9]+$')
}

conv_print_phase_b() {
  local step
  printf 'After the guest has been looked at (and only if no guest check is RED):\n'
  printf '  - archive the guest filesystem(s) under %s/<run>/\n' "$(stage_root)"
  printf '  - pct create %s from that archive, tagged vm2lxc-<run>, stopped, not starting at boot\n' "$CONV_CTID"
  printf '  - in the container copy only: comment out the fstab lines that name the VM'"'"'s disks (a backup stays),\n'
  printf '    disable cloud-init, make netplan match the NIC by name instead of by MAC, mask the serial getty and\n'
  printf '    the kernel mounts a container cannot have; copy the extra disks into their mount points\n'
  if ((OPT_START)); then
    printf '  - start the container (the cutover: the VM is already stopped)\n'
  else
    printf '  - leave the container STOPPED (add --start to start it)\n'
  fi
  printf '  - tear down the snapshot layer and the archives; the container and the VM'"'"'s stopped state stay\n'
}

# --- convert ------------------------------------------------------------------------------------------------

cmd_convert() {
  local vmid run vstate vm_lock was i n kind m mkey mtarget mdev mmnt mfs note
  (($# == 1)) || die "$EXIT_USAGE" "usage: vm2lxc convert <vmid> [--yes] [--ctid N] [--start] [--privileged] [--memory MB] [--cores N] [--hostname NAME]"
  vmid=$1
  vmid_valid "$vmid" || die "$EXIT_USAGE" "not a valid VM id: '$vmid' (expected a number, 100 or higher)"
  [[ -z $OPT_CTID || $OPT_CTID =~ $RE_CTID ]] || die "$EXIT_USAGE" "--ctid needs a number, 100 or higher"
  host_context_load
  findings_reset
  vm_context_load "$vmid" ||
    die "$EXIT_NOINPUT" "VM $vmid not found on node $PVE_NODE_NAME, or its config could not be read"
  cfg_checks_run
  verdict_compute
  if [[ $VERDICT == red ]]; then
    printf 'vm2lxc convert %s: the VM cannot be converted (RED). Nothing was changed.\n' "$vmid" >&2
    for i in "${!F_LEVEL[@]}"; do
      [[ ${F_LEVEL[$i]} == red ]] && printf '  [RED] %s\n' "${F_MSG[$i]}" >&2
    done
    exit "$EXIT_RED"
  fi
  run=${VM2LXC_RUN_ID:-$(snap_gen_run_id)}
  snap_plan_build "$vmid" "$run" || die "$EXIT_DATAERR" "cannot plan snapshots for VM $vmid: $PLAN_ERR"
  conv_inputs "$vmid" "$run" || die "$EXIT_DATAERR" "cannot plan the container for VM $vmid: $PLAN_ERR"

  vstate=$(vm_run_state "$vmid")
  was=0
  [[ $vstate == running ]] && was=1
  vm_lock=$(qmc_get lock)

  printf '%svm2lxc convert %s%s  "%s"\n' "$C_BLD" "$vmid" "$C_RST" "$(qmc_get name '(unnamed)')"
  printf '  node %s | PVE %s | %s\n\n' "$PVE_NODE_NAME" "${PVE_VERSION:-unknown}" "$(pve_mode_label)"
  printf 'VM-config verdict: %s' "${VERDICT^^}"
  [[ $VERDICT == yellow ]] && printf ' (convertible with caveats, listed below)'
  printf '\n'
  for i in "${!F_LEVEL[@]}"; do
    case ${F_LEVEL[$i]} in yellow) printf '  [YELLOW] %s\n' "${F_MSG[$i]}" ;; esac
  done
  printf '\n'
  if ((was)); then
    printf 'The VM is RUNNING: it will be shut down first (stop-and-copy), so the copy is consistent.\n'
    printf 'It is NOT deleted and its disks are not written. vm2lxc undo %s starts it again.\n\n' "$CONV_CTID"
  fi
  if [[ -n $vm_lock ]]; then
    printf 'Note: the VM is locked (lock: %s): another operation is working on it. --yes will refuse until the lock is gone.\n\n' "$vm_lock"
  fi
  conv_print_inputs "$vmid"
  snap_plan_print "$vmid" "$run"
  printf '\n'
  conv_print_phase_b

  if ((!OPT_YES)) || ((OPT_DRY_RUN)); then
    printf '\nNothing was executed. Re-run with --yes to carry out this plan.\n'
    return 0
  fi

  snap_plan_executable || die "$EXIT_NOTIMPL" "$PLAN_ERR"
  exec_guard
  if [[ -n $vm_lock ]]; then
    die "$EXIT_REFUSED" "VM $vmid is locked (lock: $vm_lock): another operation is running on it, so vm2lxc will not touch it now. Retry when the lock is gone."
  fi
  lock_acquire || die "$EXIT_REFUSED" "another vm2lxc run holds the lock (no changes made)"
  inspect_revalidate "$vmid" "$run" || die "$EXIT_REFUSED" "VM $vmid changed since the plan was shown: nothing was done, run it again"
  # the container id must still be free now that we hold the lock
  if pve_id_in_use "$CONV_CTID"; then die "$EXIT_REFUSED" "id $CONV_CTID became used since the plan was shown: nothing was done"; fi
  journal_new "$vmid" "$run" || die "$EXIT_ENV" "could not create the journal under $(state_dir)"
  CT_ID=$CONV_CTID
  journal_ct "$CONV_CTID" || die "$EXIT_ENV" "could not write the journal"
  run_arm_traps

  printf '\nExecuting. Journal: %s\n' "$JOURNAL"
  conv_phase_a_plan "$vmid" "$was"
  run_apply || die "$?" "the plan failed part-way (everything created so far is being torn down; the VM is restarted if it was running)"

  printf '\nMounted read-only:\n'
  for m in "${MOUNTS[@]}"; do
    IFS='|' read -r mkey mtarget mdev mmnt mfs <<<"$m"
    printf '  %-8s %-7s %-6s %s\n' "$mkey" "$mtarget" "$mfs" "$mdev"
  done
  pick_guest_root || die "$EXIT_REFUSED" "no Linux root filesystem (etc + usr or bin) was found on the boot disk: nothing to convert (everything is being torn down)"
  printf 'Guest root: %s\n' "$GUEST_ROOT"
  progress_emit checks 1 1 guest-checks
  guest_checks_run
  verdict_compute
  printf 'Guest checks: %d ran, %d pending.\n' "${#GUEST_RAN[@]}" "${#GUEST_PENDING[@]}"
  for i in "${!F_LEVEL[@]}"; do
    case ${F_LEVEL[$i]} in red | yellow | info) printf '  [%s] %s\n' "${F_LEVEL[$i]^^}" "${F_MSG[$i]}" ;; esac
  done
  if [[ $VERDICT == red ]]; then
    die "$EXIT_REFUSED" "the guest cannot be converted (RED, see above). Nothing was kept: the snapshot layer is being torn down and the VM restarted."
  fi

  conv_decide "$vmid" "$run" || die "$EXIT_REFUSED" "$PLAN_ERR"
  for note in "${CONV_NOTES[@]}"; do printf '  note: %s\n' "$note"; done
  printf '\nBuilding the container %s ...\n' "$CONV_CTID"
  run_apply keep || die "$?" "the conversion failed part-way (the half-built container is being destroyed, the VM restarted if it was running)"

  # Commit: from here the container and the VM's stopped state are the result, not leftovers.
  journal_load "$run" || die "$EXIT_ENV" "cannot re-read the journal"
  for ((n = 1; n <= JL_N; n++)); do
    kind=${JL_KIND[$n]:-}
    [[ -n $kind ]] || continue
    if [[ $CONV_KEPT_KINDS == *" $kind "* && ${JL_STATE[$n]:-} == DONE ]]; then
      journal_mark "$n" KEPT || die "$EXIT_ENV" "cannot write the journal"
    elif [[ $kind == ct-mount && ${JL_STATE[$n]:-} == DONE ]]; then
      journal_mark "$n" UNDONE || die "$EXIT_ENV" "cannot write the journal" # ct-unmount already did it
    fi
  done
  journal_commit || die "$EXIT_ENV" "cannot write the journal"
  CONV_DONE=1
  printf 'Container %s created. Cleaning up the snapshot layer and the staged archives ...\n' "$CONV_CTID"
  INSPECT_ARMED=0
  trap '' INT TERM HUP PIPE QUIT
  if ! run_teardown "$run" 1>&"$INSPECT_OUT_FD" 2>&"$INSPECT_ERR_FD"; then
    printf 'vm2lxc: the container is ready but the clean-up is INCOMPLETE: run "vm2lxc cleanup --yes" to finish it.\n' >&2
    exit "$EXIT_REFUSED"
  fi
  conv_summary "$vmid"
  return 0
}

conv_summary() {
  local vmid=$1
  printf '\nDone. Container %s ("%s") was created from VM %s.\n' "$CONV_CTID" "$CONV_HOSTNAME" "$vmid"
  if ((OPT_START)); then
    printf '  The container is RUNNING; VM %s is stopped and set not to start at boot.\n' "$vmid"
  else
    printf '  The container is STOPPED. VM %s is stopped (and set not to start at boot): start the container to cut over:\n' "$vmid"
    printf '    pct start %s\n' "$CONV_CTID"
  fi
  if ((${#CONV_USB_LOST[@]} > 0)); then
    local l
    printf '  USB NOT carried over (the container cannot use these devices until you add them, for example "pct set %s --dev0 /dev/bus/usb/BBB/DDD"):\n' "$CONV_CTID"
    for l in "${CONV_USB_LOST[@]}"; do printf '    - %s\n' "$l"; done
  fi
  printf '  To go back:  vm2lxc undo %s --yes   (destroys the container, starts the VM again)\n' "$CONV_CTID"
  printf '  NEVER start VM %s while container %s runs: they share one MAC address.\n' "$vmid" "$CONV_CTID"
  if ((GUEST_HAS_TAILSCALE)); then
    printf '  Tailscale state was copied: the VM and the container are ONE node. Do not run both.\n'
  fi
}

# --- undo ---------------------------------------------------------------------------------------------------

cmd_undo() {
  local ct run n kind state
  (($# == 1)) || die "$EXIT_USAGE" "usage: vm2lxc undo <ct> [--yes]"
  ct=$1
  [[ $ct =~ $RE_CTID ]] || die "$EXIT_USAGE" "not a valid container id: '$ct' (expected a number, 100 or higher)"
  run=$(committed_run_for_ct "$ct") ||
    die "$EXIT_NOINPUT" "no open vm2lxc conversion created container $ct (nothing to undo here)"
  journal_load "$run" || die "$EXIT_NOINPUT" "the journal of run $run cannot be read"
  printf '%svm2lxc undo %s%s  (run %s, VM %s)\n\n' "$C_BLD" "$ct" "$C_RST" "$run" "$RUN_VMID"
  local was=0 a1 a2 a3
  for ((n = 1; n <= JL_N; n++)); do
    if [[ ${JL_KIND[$n]:-} == vm-stop ]]; then
      IFS=$'\t' read -r a1 a2 a3 <<<"${JL_ARGS[$n]}"
      [[ $a2 == 1 ]] && was=1
    fi
  done
  printf 'What undo does, newest step first:\n'
  for ((n = JL_N; n >= 1; n--)); do
    kind=${JL_KIND[$n]:-}
    state=${JL_STATE[$n]:-}
    [[ $state == KEPT ]] || continue
    case $kind in
      ct-start) printf '  - stop container %s\n' "$ct" ;;
      ct-create) printf '  - DESTROY container %s and its volumes (only if it carries the tag vm2lxc-%s)\n' "$ct" "$run" ;;
      vm-onboot) printf '  - restore the VM'"'"'s autostart flag\n' ;;
      vm-stop)
        if ((was)); then
          printf '  - start VM %s again (it was running before the conversion; never while the container runs)\n' "$RUN_VMID"
        else
          printf '  - leave VM %s stopped (it was already stopped before the conversion)\n' "$RUN_VMID"
        fi
        ;;
    esac
  done
  printf '\nEverything written inside the container since the conversion is LOST: undo does not copy it back.\n'
  printf 'The VM'"'"'s own disks were never modified, so it comes back exactly as it was.\n'
  if ((!OPT_YES)) || ((OPT_DRY_RUN)); then
    printf '\nNothing was changed. Re-run with --yes to do this.\n'
    return 0
  fi
  exec_guard
  lock_acquire || die "$EXIT_REFUSED" "another vm2lxc run holds the lock (no changes made)"
  RUN_ID=$run
  if ! run_teardown "$run" 1; then
    die "$EXIT_REFUSED" "undo is INCOMPLETE: nothing was lost. Fix the cause above and run it again."
  fi
  if ((was)); then
    printf '\nUndone. Container %s is gone and VM %s is running again.\n' "$ct" "$RUN_VMID"
  else
    printf '\nUndone. Container %s is gone. VM %s is as it was before the conversion (it was stopped).\n' "$ct" "$RUN_VMID"
  fi
}
