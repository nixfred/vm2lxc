# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # VMID, VERDICT and friends are set in sibling lib files
# `vm2lxc preflight <vmid>`: read-only convertibility report for one VM.
# It only reads: see lib/pve.sh. Exit code is the verdict (0 green, 10 yellow, 20 red).

cmd_preflight() {
  local vmid
  (($# == 1)) || die "$EXIT_USAGE" "usage: vm2lxc preflight <vmid>"
  vmid=$1
  vmid_valid "$vmid" || die "$EXIT_USAGE" "not a valid VM id: '$vmid' (expected a number, 100 or higher)"
  host_context_load
  findings_reset
  vm_context_load "$vmid" ||
    die "$EXIT_NOINPUT" "VM $vmid not found on node $PVE_NODE_NAME, or its config could not be read (is it a container?)"
  cfg_checks_run
  guest_checks_run
  verdict_compute
  sizing_collect "$vmid"
  sizing_judge "$(qmc_memory_mb)" "$(qmc_cores)"
  preflight_render
  exit "$(verdict_exit_code)"
}

verdict_label() { # green|yellow|red -> coloured upper-case word
  case $1 in
    green) printf '%sGREEN%s' "$C_GRN" "$C_RST" ;;
    yellow) printf '%sYELLOW%s' "$C_YEL" "$C_RST" ;;
    red) printf '%sRED%s' "$C_RED" "$C_RST" ;;
    *) printf '%s' "$1" ;;
  esac
}

preflight_banner() {
  local pend_note=""
  if ((N_PENDING > 0)); then
    pend_note="$N_PENDING guest-internal checks still need disk inspection (not implemented yet)"
  fi
  printf 'VERDICT: %s' "$(verdict_label "$VERDICT")"
  case $VERDICT in
    green)
      printf ' (provisional)\n  No blockers in the VM config. %s, so this is not a go-ahead.\n' "${pend_note:-All checks ran}"
      ;;
    yellow)
      printf '\n  Convertible with caveats: read the YELLOW items below.%s\n' "${pend_note:+ Also: $pend_note.}"
      ;;
    red)
      printf '\n  Cannot be converted as it stands: %d blocker(s) below.\n' "$N_RED"
      ;;
  esac
}

preflight_findings() {
  local level i tag shown=0
  for level in red yellow info; do
    for i in "${!F_LEVEL[@]}"; do
      [[ ${F_LEVEL[$i]} == "$level" ]] || continue
      case $level in
        red) tag="${C_RED}[RED]${C_RST}   " ;;
        yellow) tag="${C_YEL}[YELLOW]${C_RST}" ;;
        *) tag="${C_DIM}[info]${C_RST}  " ;;
      esac
      if [[ ${F_KIND[$i]} == tool ]]; then
        printf '  %s %s (v1 limit)\n' "$tag" "${F_MSG[$i]}"
      else
        printf '  %s %s\n' "$tag" "${F_MSG[$i]}"
      fi
      shown=1
    done
  done
  if ((shown == 0)); then
    printf '  (nothing to report)\n'
  fi
}

preflight_disks() {
  local i key stype what size boot_tag
  for i in "${!D_KEY[@]}"; do
    key=${D_KEY[$i]}
    boot_tag=""
    if [[ $key == "$BOOT_KEY" ]]; then
      boot_tag="  (boot disk)"
    fi
    case ${D_KIND[$i]} in
      data)
        stype=${ST_TYPE[${D_STORAGE[$i]}]:-unknown}
        what="${D_STORAGE[$i]} ($stype)"
        ;;
      cdrom) what="cdrom / empty drive" ;;
      passthrough) what="raw host device" ;;
      efi) what="UEFI variables" ;;
      tpm) what="TPM state" ;;
      unused) what="${D_STORAGE[$i]:-?} (unused)" ;;
      *) what="?" ;;
    esac
    size="-"
    if [[ -n ${D_SIZE_MB[$i]} ]]; then
      size=$(fmt_mb "${D_SIZE_MB[$i]}")
    elif [[ ${D_KIND[$i]} == data ]]; then
      size="?"
    fi
    printf '  %-9s %-28s %-7s -> %s%s\n' "$key" "$what" "$size" "${D_TARGET[$i]}" "$boot_tag"
  done
}

preflight_nics() {
  local i vlan
  if ((${#N_KEY[@]} == 0)); then
    printf '  (no network interfaces)\n'
    return 0
  fi
  for i in "${!N_KEY[@]}"; do
    vlan=""
    if [[ -n ${N_TAG[$i]} ]]; then
      vlan="  VLAN ${N_TAG[$i]}"
    fi
    printf '  %-5s %-8s %-18s bridge %s%s\n' "${N_KEY[$i]}" "${N_MODEL[$i]:-?}" "${N_MAC[$i]:-?}" "${N_BRIDGE[$i]:-?}" "$vlan"
  done
  printf '  The container will keep each MAC (D4); the guest NIC name is read from the guest later.\n'
}

preflight_render() {
  local name total
  name=$(qmc_get name "(unnamed)")
  printf '%svm2lxc preflight %s%s  "%s"\n' "$C_BLD" "$VMID" "$C_RST" "$name"
  printf '  node %s | PVE %s | %s\n\n' "$PVE_NODE_NAME" "${PVE_VERSION:-unknown}" "$(pve_mode_label)"
  preflight_banner
  printf '\nFindings\n'
  preflight_findings
  printf '\nDisks\n'
  preflight_disks
  if total=$(disks_total_mb); then
    printf '  allocated: %s; used space needs disk inspection (not yet)\n' "$(fmt_mb "$total")"
  fi
  printf '\nNetwork\n'
  preflight_nics
  printf '\nSizing\n'
  sizing_print
  printf '\nGuest checks\n'
  if ((${#GUEST_PENDING[@]} > 0)); then
    printf '  %d pending, they need disk inspection (not implemented yet): %s\n' \
      "${#GUEST_PENDING[@]}" "$(printf '%s, ' "${GUEST_PENDING[@]}" | sed 's/, $//')"
  fi
  if ((${#GUEST_RAN[@]} > 0)); then
    printf '  %d ran: %s\n' "${#GUEST_RAN[@]}" "${GUEST_RAN[*]}"
  fi
  printf '\nNothing was changed: preflight only reads.\n'
}
