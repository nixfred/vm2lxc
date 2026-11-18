# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # VMID, VERDICT and friends are set in sibling lib files
# `vm2lxc scan`: rank every VM on this node by verdict, then RAM saved, with a
# one-line reason each (D11). It reads the VM configs and, like preflight (R40), looks inside each disk that the
# config did not already rule out, through a read-only snapshot of it (inspect_overlay in inspect.sh); --no-inspect
# or --dry-run skips that. Always exits 0 unless it cannot read the VM list at all.

SCAN_ROWS=()
SCAN_INSPECTED=0
SCAN_NOT_INSPECTED=() # "vmid: reason"

# Sort key ranks: 0 green, 1 yellow, 2 red, 3 unreadable. Fields are tab-separated:
# rank saved vmid name state verdict ram saved_txt disk why
scan_add_row() {
  SCAN_ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$@")")
}

# One short phrase on why sizing is (or is not) trustworthy, for the green "why" column.
scan_sizing_phrase() {
  if [[ ${SZ[near_max]:-0} == 1 ]]; then
    printf 'memory looks pinned near max, saving not trusted'
    return 0
  fi
  case ${SZ[confidence]} in
    unavailable) printf 'RRD history unreadable, keeping size' ;;
    none) printf 'no usable RRD samples, keeping size' ;;
    insufficient) printf 'under 24h of RRD history, keeping size' ;;
    *) printf 'sizing confidence: %s' "${SZ[confidence]}" ;;
  esac
}

scan_one() {
  local vmid=$1 name state template=$4 # names come from the node's VM list
  sanitize_text "$2"
  name=$REPLY
  sanitize_text "$3"
  state=$REPLY
  local rank saved=0 ram="-" saved_txt="-" disk="?" why total cur
  findings_reset
  if ! vm_context_load "$vmid"; then
    scan_add_row 3 0 "$vmid" "$name" "$state" ERROR "-" "-" "?" "could not read this VM's config (qm config failed)"
    SCAN_UNREADABLE=$((SCAN_UNREADABLE + 1))
    return 0
  fi
  # A template is flagged by the node's VM list as well as by its config.
  if [[ $template == 1 && ${QMC[template]:-0} != 1 ]]; then
    QMC[template]=1
  fi
  cfg_checks_run
  verdict_compute
  local looked=0
  if [[ $VERDICT != red ]] && ((INSPECT_OVERLAY_ON)); then
    if inspect_overlay "$vmid"; then
      looked=1
      SCAN_INSPECTED=$((SCAN_INSPECTED + 1))
    else
      SCAN_NOT_INSPECTED+=("$vmid: $INSPECT_OVERLAY_WHY")
    fi
    verdict_compute
  fi
  cur=$(qmc_memory_mb)
  if total=$(disks_total_mb); then
    disk=$(fmt_mb "$total")
  fi
  if [[ -n $cur ]]; then
    ram="${cur}M"
  fi
  case $VERDICT in
    red)
      rank=2
      why=$(top_reason)
      SCAN_RED=$((SCAN_RED + 1))
      ;;
    *)
      sizing_collect "$vmid"
      sizing_judge "$cur" "$(qmc_cores)"
      if [[ $VERDICT == yellow ]]; then
        rank=1
        why=$(top_reason)
        SCAN_YELLOW=$((SCAN_YELLOW + 1))
      else
        rank=0
        if ((looked)); then
          why="no blockers in the VM config or inside the guest ($(scan_sizing_phrase))"
        else
          why="no blockers in the VM config ($(scan_sizing_phrase))"
        fi
        SCAN_GREEN=$((SCAN_GREEN + 1))
      fi
      if [[ ${SZ[mode]} == choices ]]; then
        saved=$(sizing_saved_mb)
        ram="${cur}M -> ${SZ[mem_rec]}M"
        saved_txt="${saved}M"
        SCAN_SAVED_MB=$((SCAN_SAVED_MB + saved))
      elif [[ -n $cur ]]; then
        ram="${cur}M (keep)"
      fi
      ;;
  esac
  scan_add_row "$rank" "$saved" "$vmid" "$name" "$state" "${VERDICT^^}" "$ram" "$saved_txt" "$disk" "$why"
}

# scan_collect [vmid...]: read the node's VMs and fill SCAN_ROWS and the SCAN_* counters. Read-only. Split out
# of cmd_scan so the menu can offer the same ranked list without parsing the printed table.
scan_collect() {
  local list vmid name state template row
  local ids_json="[]" id
  local -a wanted=()
  # Optional VM ids restrict the scan: `vm2lxc scan 600 601`. Without them, every VM on the node.
  for id in "$@"; do
    vmid_valid "$id" || die "$EXIT_USAGE" "not a valid VM id: '$id' (usage: vm2lxc scan [vmid...])"
    wanted+=("$id")
  done
  if ((${#wanted[@]} > 0)); then
    ids_json=$(printf '%s\n' "${wanted[@]}" | jq -R 'tonumber' | jq -s '.')
  fi
  host_context_load
  list=$(pve_list_vms) || die "$EXIT_ENV" "could not list VMs on node $PVE_NODE_NAME"
  jq -e 'type == "array"' <<<"$list" >/dev/null 2>&1 || die "$EXIT_ENV" "the VM list from node $PVE_NODE_NAME is not valid JSON"
  for id in "${wanted[@]}"; do
    jq -e --argjson id "$id" 'any(.[]; .vmid == $id)' <<<"$list" >/dev/null 2>&1 ||
      warn "VM $id is not on node $PVE_NODE_NAME: skipped"
  done
  SCAN_ROWS=() SCAN_GREEN=0 SCAN_YELLOW=0 SCAN_RED=0 SCAN_UNREADABLE=0 SCAN_SAVED_MB=0 SCAN_INSPECTED=0 SCAN_NOT_INSPECTED=()
  local -a vmrows=()
  local k=0
  mapfile -t vmrows < <(jq -r --argjson ids "$ids_json" \
    'sort_by(.vmid) | .[] | select(($ids | length) == 0 or (.vmid as $v | $ids | index($v) != null)) | [.vmid, (.name // "-"), (.status // "-"), (.template // 0)] | @tsv' <<<"$list")
  for row in "${vmrows[@]}"; do
    IFS=$'\t' read -r vmid name state template <<<"$row"
    [[ -n $vmid ]] || continue
    k=$((k + 1))
    progress_emit look "$k" "${#vmrows[@]}" scan # the menu's bar for a scan counts VMs
    scan_one "$vmid" "$name" "$state" "$template"
  done
}

# scan_sorted_rows: SCAN_ROWS ranked as `scan` prints them (verdict, then RAM saved, then id), one per line.
scan_sorted_rows() {
  printf '%s\n' "${SCAN_ROWS[@]}" | sort -t $'\t' -k1,1n -k2,2nr -k3,3n
}

cmd_scan() {
  local vmid name state verdict ram saved_txt disk why color _rank _saved n=0 line
  INSPECT_OVERLAY_ON=1 # R40: look inside the disks too
  scan_collect "$@"

  printf '%svm2lxc scan%s\n' "$C_BLD" "$C_RST"
  printf '  node %s | PVE %s | %s\n\n' "$PVE_NODE_NAME" "${PVE_VERSION:-unknown}" "$(pve_mode_label)"
  if ((${#SCAN_ROWS[@]} == 0)); then
    printf '  No VMs found on this node.\n'
    return 0
  fi
  # name column: as wide as the longest name (so "vm2lxc-test-deb12-svc" is not cut), 4..32
  local name_w=4 row
  for row in "${SCAN_ROWS[@]}"; do
    IFS=$'\t' read -r _rank _saved vmid name _rest <<<"$row"
    if ((${#name} > name_w)); then name_w=${#name}; fi
  done
  if ((name_w > 32)); then name_w=32; fi
  printf '  %-3s %-6s %-*s %-8s %-8s %-18s %-8s %-7s %s\n' '#' VMID "$name_w" NAME STATE VERDICT 'RAM now -> rec' SAVED DISK WHY
  while IFS=$'\t' read -r _rank _saved vmid name state verdict ram saved_txt disk why; do
    n=$((n + 1))
    case $verdict in
      GREEN) color=$C_GRN ;;
      YELLOW) color=$C_YEL ;;
      *) color=$C_RED ;;
    esac
    printf '  %-3s %-6s %-*.*s %-8s %s%-8s%s %-18s %-8s %-7s %s\n' \
      "$n" "$vmid" "$name_w" "$name_w" "$name" "$state" "$color" "$verdict" "$C_RST" "$ram" "$saved_txt" "$disk" "$why"
  done < <(scan_sorted_rows)

  printf '\n  %d VMs: %d green, %d yellow, %d red' "${#SCAN_ROWS[@]}" "$SCAN_GREEN" "$SCAN_YELLOW" "$SCAN_RED"
  if ((SCAN_UNREADABLE > 0)); then
    printf ', %d unreadable' "$SCAN_UNREADABLE"
  fi
  printf '\n  RAM that would be freed at the "recommended" sizes (green + yellow): %s\n' "$(fmt_mb "$SCAN_SAVED_MB")"
  if ((SCAN_INSPECTED > 0)); then
    printf '\n  The guest-internal checks (Docker, kernel modules, NFS server, cloud-init, snap, ...) ran on %d VM(s):\n' "$SCAN_INSPECTED"
    printf '  each disk was looked at through a read-only snapshot that is already removed again.\n'
  fi
  if ((${#SCAN_NOT_INSPECTED[@]} > 0)); then
    if ((SCAN_INSPECTED == 0)); then
      line=${SCAN_NOT_INSPECTED[0]#*: }
      printf '\n  Verdicts are provisional: no disk was looked at, so the guest-internal checks did not run (%s).\n' "$line"
    else
      printf '\n  Verdicts of these VMs are provisional: their guest-internal checks did not run:\n'
      for line in "${SCAN_NOT_INSPECTED[@]}"; do printf '    - VM %s\n' "$line"; done
    fi
    printf '  (RED VMs are not looked at: the config already rules them out.) To look at one by hand: vm2lxc inspect <vmid> --yes\n'
  fi
  printf '  SAVED = configured RAM minus the "recommended" size from RRD history; "keep" when there is\n'
  printf '  under 24h of history. Disk savings are not estimated: used space is not measured.\n'
  if ((INSPECT_BROKEN)); then
    printf '\nvm2lxc: a teardown was INCOMPLETE (see above): run "vm2lxc cleanup --yes". Nothing was lost.\n' >&2
    return "$EXIT_REFUSED"
  fi
}
