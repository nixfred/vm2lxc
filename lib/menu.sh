# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # globals are shared with the other lib files
# `vm2lxc menu`, and bare `vm2lxc` at a terminal: the interactive front-end (decision D7). Design and rails:
# docs/menu.html (R30-R38).
#
# The menu is a FRONT-END and nothing else (R30): it asks, it shows plans, and then it runs this same binary with
# the same flags you could type yourself. It has no code path of its own that touches the host. The one place that
# adds --yes is menu_execute, reached only after an explicit "Continue" (or, unattended, answers `continue=yes`
# AND --yes on the command line). Esc, Back, Quit, the end of input and a refused plan all end in "nothing ran".

MENU_GLOBALS=()
MENU_RC=0

# the flags every engine call gets from the menu's own command line
menu_globals() {
  MENU_GLOBALS=()
  if [[ -n $OPT_NODE ]]; then MENU_GLOBALS+=(--node "$OPT_NODE"); fi
  if ((OPT_DRY_RUN)); then MENU_GLOBALS+=(--dry-run); fi
}

# menu_cmdline <args...>: the equivalent command line, shell-quoted, as it is shown on the review screen (R30)
menu_cmdline() {
  local out=vm2lxc a
  for a in "$@"; do out+=" $(printf '%q' "$a")"; done
  printf '%s' "$out"
}

# menu_plan <args...>: run the engine WITHOUT --yes (a plan changes nothing); output into $UI_TMP/plan.txt, exit code in MENU_RC
menu_plan() {
  local a
  for a in "$@"; do
    [[ $a != --yes ]] || die "$EXIT_USAGE" "internal error: a plan was asked to run with --yes"
  done
  MENU_RC=0
  "$VM2LXC_SELF" "${MENU_GLOBALS[@]}" "$@" >"$UI_TMP/plan.txt" 2>&1 </dev/null || MENU_RC=$?
}

# menu_execute <action> <title> <args...>: THE one place that adds --yes (R31)
menu_execute() {
  local action=$1 title=$2
  shift 2
  ui_run "$action" "$title" "$UI_TMP/run.log" -- "${MENU_GLOBALS[@]}" "$@" --yes
}

# menu_result: what the engine printed, and what to do if it failed. Also left in the terminal's scrollback.
menu_result() {
  local rc=$UI_RUN_RC head
  if ((rc == 0)); then head="Finished"; else head="FAILED (exit $rc)"; fi
  {
    cat -- "$UI_TMP/run.log"
    if ((rc != 0)); then
      printf '\nSomething may be left behind. Look with:  vm2lxc cleanup   (it lists first and removes only with --yes)\n'
    fi
  } >"$UI_TMP/result.txt"
  ui_text "$head" "$UI_TMP/result.txt"
  if [[ $UI_BACKEND == whiptail ]]; then
    printf '\n--- %s ---\n' "$head"
    cat -- "$UI_TMP/result.txt"
  fi
}

# menu_continue <action> <title> <args...>: check the arguments with a plan first, then run for real and show the
# result. rc 0 it ran, rc 1 the plan refused it (shown, nothing ran).
menu_continue() {
  local action=$1 title=$2
  shift 2
  menu_plan "$@"
  if ((MENU_RC != 0)); then
    ui_text "Cannot continue (exit $MENU_RC): nothing was changed" "$UI_TMP/plan.txt"
    return 1
  fi
  menu_execute "$action" "$title" "$@"
  menu_result
  return 0
}

# --- choosing things --------------------------------------------------------------------------------------------

# menu_pick_vm <title> <text>: the ranked VM list as a menu; the best candidate is the default. REPLY = the vmid.
menu_pick_vm() {
  local rank saved vmid name state verdict ram saved_txt disk why def=""
  local -a items=()
  scan_collect
  if ((${#SCAN_ROWS[@]} == 0)); then
    ui_msg "No VMs" "No VMs were found on node $PVE_NODE_NAME."
    return 1
  fi
  while IFS=$'\t' read -r rank saved vmid name state verdict ram saved_txt disk why; do
    items+=("$vmid" "$(printf '%-22.22s %-8s %-7s %-16s %s' "$name" "$state" "$verdict" "$ram" "$disk")")
    if [[ -z $def && $verdict != RED && $verdict != ERROR ]]; then def=$vmid; fi
  done < <(scan_sorted_rows)
  if [[ -z $def ]]; then def=${items[0]}; fi
  ui_menu "$1" "$2" "$def" "${items[@]}"
}

# menu_pick_ct: the conversions that can still be undone. REPLY = the container id.
menu_pick_ct() {
  local r first=""
  local -a items=()
  while IFS= read -r r; do
    journal_load "$r" 2>/dev/null || continue
    [[ -n $JL_CT ]] || continue
    items+=("$JL_CT" "container $JL_CT  from  VM $RUN_VMID   (run $r)")
    if [[ -z $first ]]; then first=$JL_CT; fi
  done < <(runs_committed)
  if [[ -z $first ]]; then
    ui_msg "Nothing to undo" "No finished conversion is waiting: there is no container made by vm2lxc that undo could remove."
    return 1
  fi
  ui_menu "Undo: which container?" "Undo destroys the container and starts its VM again." "$first" "${items[@]}"
}

# --- the review hubs: ONE screen with the plan, the settings, Continue, Back and Quit -------------------------------
# The first Enter on a hub shows the plan (changes nothing). Only after the plan was looked at does Continue become
# the highlighted default, and any edit makes the plan stale again.

# menu_hub_simple <action> <title> <consequence> <engine args...>: inspect, undo and cleanup have nothing to edit.
menu_hub_simple() {
  local action=$1 title=$2 consequence=$3 seen=0 def rc
  shift 3
  local -a args=("$@")
  while :; do
    def=plan
    if ((seen)); then def="continue"; fi
    rc=0
    ui_menu "$title" "The exact command Continue runs:  $(menu_cmdline "${MENU_GLOBALS[@]}" "${args[@]}" --yes)"$'\n'"Nothing runs until you pick Continue." "$def" \
      continue ">> Continue: $consequence" \
      plan "Show the full plan (changes nothing)" \
      back "Back" \
      quit "Quit (nothing is run)" || rc=$?
    case $rc in
      0) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
    case $REPLY in
      plan)
        menu_plan "${args[@]}"
        ui_text "Plan: $title" "$UI_TMP/plan.txt"
        seen=1
        ;;
      continue)
        if menu_continue "$action" "$title" "${args[@]}"; then return 0; fi
        ;;
      back) return 1 ;;
      quit)
        UI_QUIT=1
        return 2
        ;;
    esac
  done
}

menu_valid_ctid() { [[ $1 =~ $RE_CTID ]] && ! pve_id_in_use "$1"; }
menu_valid_hostname() { [[ $1 =~ $RE_CT_NAME ]]; }
menu_valid_memory() { [[ $1 =~ ^[0-9]{2,6}$ ]]; }
menu_valid_cores() { [[ $1 =~ ^[0-9]{1,3}$ ]]; }
menu_yn() { if (($1)); then printf yes; else printf no; fi; }

# menu_convert_hub <vmid>: rc 0 it ran, 1 back to the VM list, 2 quit
menu_convert_hub() {
  local vmid=$1 vname vstate seen=0 def rc field hctid hhost hmem hcores hpriv=0 hstart=0 stop_note=""
  local -a args
  vm_context_load "$vmid" 2>/dev/null || {
    ui_msg "Cannot read VM $vmid" "VM $vmid could not be read on node $PVE_NODE_NAME. Nothing was changed."
    return 1
  }
  sanitize_text "$(qmc_get name '(unnamed)')"
  vname=$REPLY
  hctid=$(pve_nextid 2>/dev/null) || hctid=""
  hhost=$(conv_hostname "$(qmc_get name)" "$hctid")
  hmem=$(qmc_memory_mb)
  hcores=$(qmc_cores)
  vstate=$(vm_run_state "$vmid")
  if [[ $vstate == running ]]; then stop_note=", stopping the VM first"; fi
  while :; do
    args=(convert "$vmid" --ctid "$hctid" --hostname "$hhost" --memory "$hmem" --cores "$hcores")
    if ((hpriv)); then args+=(--privileged); fi
    if ((hstart)); then args+=(--start); fi
    def=plan
    if ((seen)); then def="continue"; fi
    rc=0
    ui_menu "Convert VM $vmid \"$vname\"" "The exact command Continue runs:  $(menu_cmdline "${MENU_GLOBALS[@]}" "${args[@]}" --yes)"$'\n'"Nothing runs until you pick Continue. Pick a setting to change it." "$def" \
      continue ">> Continue: build container $hctid from VM $vmid$stop_note" \
      plan "Show the full plan (changes nothing)" \
      ctid "$(printf '%-26s %s' 'Container id' "$hctid")" \
      hostname "$(printf '%-26s %s' 'Hostname' "$hhost")" \
      memory "$(printf '%-26s %s' 'RAM (MB)' "$hmem")" \
      cores "$(printf '%-26s %s' 'Cores' "$hcores")" \
      privileged "$(printf '%-26s %s' 'Privileged container' "$(menu_yn "$hpriv")")" \
      start "$(printf '%-26s %s' 'Start it after creating' "$(menu_yn "$hstart")")" \
      back "Back to the VM list" \
      quit "Quit (nothing is run)" || rc=$?
    case $rc in
      0) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
    case $REPLY in
      plan)
        menu_plan "${args[@]}"
        ui_text "Plan: convert VM $vmid" "$UI_TMP/plan.txt"
        seen=1
        ;;
      continue)
        if menu_continue convert "Converting VM $vmid" "${args[@]}"; then return 0; fi
        ;;
      ctid | hostname | memory | cores)
        field=$REPLY # REPLY is overwritten by the input box: remember which setting this is
        rc=0
        case $field in
          ctid) ui_input "Container id" "The id of the NEW container: 100 or higher, not used by any VM or container." "$hctid" menu_valid_ctid "That id is not valid or is already used by a VM or a container." || rc=$? ;;
          hostname) ui_input "Hostname" "The container's hostname (lower-case letters, digits and '-')." "$hhost" menu_valid_hostname "Use lower-case letters, digits and '-', starting and ending with a letter or digit." || rc=$? ;;
          memory) ui_input "RAM" "Container RAM in MB (the VM has ${hmem})." "$hmem" menu_valid_memory "Give a whole number of MB (at least 10)." || rc=$? ;;
          cores) ui_input "Cores" "Container cores." "$hcores" menu_valid_cores "Give a whole number." || rc=$? ;;
        esac
        if ((rc == 2)); then return 2; fi
        if ((rc == 0)); then
          case $field in
            ctid) hctid=$REPLY ;;
            hostname) hhost=$REPLY ;;
            memory) hmem=$REPLY ;;
            cores) hcores=$REPLY ;;
          esac
          seen=0 # any edit makes the plan stale: the next Enter shows it again
        fi
        ;;
      privileged)
        if ((hpriv)); then
          hpriv=0
          seen=0
        elif ui_yesno "Privileged container" "A privileged container is NOT isolated from the host the way an unprivileged one is. Only choose it if the guest cannot run unprivileged. Make it privileged?" no; then
          hpriv=1
          seen=0
        fi
        ;;
      start)
        if ((hstart)); then hstart=0; else hstart=1; fi
        seen=0
        ;;
      back) return 1 ;;
      quit)
        UI_QUIT=1
        return 2
        ;;
    esac
  done
}

# --- the actions ------------------------------------------------------------------------------------------------
# Every action returns 0 or 1 to go back to the main menu, or 2 when the person asked to leave.

menu_do_scan() {
  menu_plan scan
  ui_text "Scan: every VM, ranked" "$UI_TMP/plan.txt"
}

menu_do_preflight() {
  local rc=0 vmid
  menu_pick_vm "Preflight: which VM?" "A read-only check of one VM: verdict, reasons, sizing." || rc=$?
  case $rc in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  vmid=$REPLY
  menu_plan preflight "$vmid" # its exit code 0/10/20 is the verdict, not a failure
  ui_text "Preflight: VM $vmid" "$UI_TMP/plan.txt"
}

menu_do_inspect() {
  local rc vmid
  while :; do
    rc=0
    menu_pick_vm "Inspect: which VM?" "Snapshots its disks, mounts them read-only, runs the guest checks, then removes it all again." || rc=$?
    case $rc in
      0) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
    vmid=$REPLY
    rc=0
    menu_hub_simple inspect "Inspect VM $vmid" "snapshot VM $vmid's disks, look inside read-only, tear it all down" inspect "$vmid" || rc=$?
    case $rc in
      0) return 0 ;;
      2) return 2 ;;
    esac
  done
}

menu_do_convert() {
  local rc vmid
  while :; do
    rc=0
    menu_pick_vm "Convert: which VM?" "The VM to turn into a NEW container. The best candidate is highlighted; the VM itself is kept." || rc=$?
    case $rc in
      0) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
    vmid=$REPLY
    rc=0
    menu_convert_hub "$vmid" || rc=$?
    case $rc in
      0) return 0 ;;
      2) return 2 ;;
    esac
  done
}

menu_do_undo() {
  local rc=0 ct
  menu_pick_ct || rc=$?
  case $rc in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  ct=$REPLY
  rc=0
  menu_hub_simple undo "Undo container $ct" "destroy container $ct and start its VM again" undo "$ct" || rc=$?
  if ((rc == 2)); then return 2; fi
  return 0
}

menu_do_cleanup() {
  local rc=0
  menu_plan cleanup
  if grep -q 'Nothing to clean up' "$UI_TMP/plan.txt"; then
    ui_msg "Clean up" "Nothing to clean up: no unfinished vm2lxc run."
    return 0
  fi
  menu_hub_simple cleanup "Clean up" "remove what the unfinished runs left behind (only objects named in their journals)" cleanup || rc=$?
  if ((rc == 2)); then return 2; fi
  return 0
}

menu_main() {
  local rc
  while :; do
    rc=0
    ui_menu "vm2lxc" "What do you want to do? Enter takes the highlighted default, Esc quits. Nothing changes anything until you confirm it on a review screen." scan \
      scan "Scan: rank every VM by how well it converts   (read-only)" \
      preflight "Preflight: check one VM   (read-only)" \
      inspect "Inspect: look inside a VM's disks through snapshots (read-only)" \
      convert "Convert a VM into a container" \
      undo "Undo a conversion: the container goes, the VM comes back" \
      cleanup "Clean up what a crashed run left behind" \
      quit "Quit" || rc=$?
    if ((rc != 0)); then return 0; fi
    case $REPLY in
      scan) menu_do_scan || true ;;
      preflight) menu_do_preflight || true ;;
      inspect) menu_do_inspect || true ;;
      convert) menu_do_convert || true ;;
      undo) menu_do_undo || true ;;
      cleanup) menu_do_cleanup || true ;;
      quit) return 0 ;;
    esac
    if ((UI_QUIT)); then return 0; fi
  done
}

# --- unattended: the same flow from an answers file (R33) -----------------------------------------------------------
# Nothing is prompted. It shows the plan, and it executes only when the file says continue=yes AND --yes is on the
# command line: the file alone can never turn execution on, and a key that does not belong to the action is an error
# (a typo like a misspelt ctid must not be silently ignored).
menu_answers() {
  local action=${ANSWERS[action]:-} k allowed=""
  local -a args=()
  [[ -n $action ]] || die "$EXIT_USAGE" "--answers: 'action' is required (scan, preflight, inspect, convert, undo or cleanup)"
  case $action in
    scan) allowed=" action " ;;
    preflight) allowed=" action vm " ;;
    inspect) allowed=" action vm continue " ;;
    convert) allowed=" action vm ctid hostname memory cores privileged start continue " ;;
    undo) allowed=" action ct continue " ;;
    cleanup) allowed=" action continue " ;;
  esac
  for k in "${!ANSWERS[@]}"; do
    [[ $allowed == *" $k "* ]] || die "$EXIT_USAGE" "--answers: '$k' does not apply to action '$action'"
  done
  case $action in
    scan) args=(scan) ;;
    preflight | inspect | convert)
      [[ -n ${ANSWERS[vm]:-} ]] || die "$EXIT_USAGE" "--answers: action '$action' needs 'vm'"
      args=("$action" "${ANSWERS[vm]}")
      ;;
    undo)
      [[ -n ${ANSWERS[ct]:-} ]] || die "$EXIT_USAGE" "--answers: action 'undo' needs 'ct'"
      args=(undo "${ANSWERS[ct]}")
      ;;
    cleanup) args=(cleanup) ;;
  esac
  if [[ $action == convert ]]; then
    if [[ -n ${ANSWERS[ctid]:-} ]]; then args+=(--ctid "${ANSWERS[ctid]}"); fi
    if [[ -n ${ANSWERS[hostname]:-} ]]; then args+=(--hostname "${ANSWERS[hostname]}"); fi
    if [[ -n ${ANSWERS[memory]:-} ]]; then args+=(--memory "${ANSWERS[memory]}"); fi
    if [[ -n ${ANSWERS[cores]:-} ]]; then args+=(--cores "${ANSWERS[cores]}"); fi
    if [[ ${ANSWERS[privileged]:-no} == yes ]]; then args+=(--privileged); fi
    if [[ ${ANSWERS[start]:-no} == yes ]]; then args+=(--start); fi
  fi
  menu_plan "${args[@]}"
  cat -- "$UI_TMP/plan.txt"
  case $action in
    scan | preflight) return "$MENU_RC" ;; # read-only: its own exit code (a preflight verdict)
  esac
  if ((MENU_RC != 0)); then return "$MENU_RC"; fi # a refused plan stays refused
  if ((OPT_YES)) && ((!OPT_DRY_RUN)) && [[ ${ANSWERS[continue]:-no} == yes ]]; then
    printf '\nExecuting (continue=yes in the answers file, and --yes on the command line):\n'
    menu_execute "$action" "$action" "${args[@]}"
    cat -- "$UI_TMP/run.log"
    return "$UI_RUN_RC"
  fi
  printf '\nNothing was executed: an answers-file run changes things only with continue=yes in the file AND --yes on the command line.\n'
  return 0
}

cmd_menu() {
  (($# == 0)) || die "$EXIT_USAGE" "usage: vm2lxc menu [--no-tui] [--answers FILE] [--node NAME] [--yes]"
  ui_init
  host_context_load
  UI_BACKTITLE="vm2lxc $VM2LXC_VERSION | node $PVE_NODE_NAME | $(pve_mode_label)"
  menu_globals
  if [[ $UI_BACKEND == answers ]]; then
    menu_answers
  else
    menu_main
  fi
}
