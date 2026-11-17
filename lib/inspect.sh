# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # globals are shared with the other lib files
# `vm2lxc inspect <vmid>` and `vm2lxc cleanup`: the user-facing side of the snapshot-mount
# layer. Both show a plan and change nothing unless --yes is given. Executing needs root
# on a real PVE node (never fixture mode). Design: docs/snapshot-layer.html.

INSPECT_ARMED=0

# Refuse to execute anywhere that is not a real, root PVE node (R8).
exec_guard() {
  if pve_fixture_mode && [[ ${VM2LXC_TEST_EXEC:-} != 1 ]]; then
    die "$EXIT_REFUSED" "fixture mode never executes: it has no real host to act on"
  fi
  if ! pve_fixture_mode && [[ ${VM2LXC_ASSUME_ROOT:-} != 1 && $EUID -ne 0 ]]; then
    die "$EXIT_ENV" "executing needs root on a Proxmox VE node"
  fi
}

vm_run_state() { # vmid -> running|stopped|unknown
  local list st
  if list=$(pve_list_vms 2>/dev/null) &&
    st=$(jq -r --argjson id "$1" '.[] | select(.vmid == $id) | .status // "unknown"' <<<"$list" 2>/dev/null) &&
    [[ -n $st ]]; then
    printf '%s' "$st"
  else
    printf 'unknown'
  fi
}

# Always runs when inspect leaves: tears down what was created.
#
# A trap handler runs in the redirection context of whatever command it interrupted. If the
# signal lands inside `host_cmd ... >/dev/null 2>&1`, plain `>&2` here would go to /dev/null
# and every teardown message, including "teardown is INCOMPLETE", would vanish exactly when
# the operator needs it. So cmd_inspect saves the real stdout/stderr and the trap writes there.
INSPECT_OUT_FD=1 INSPECT_ERR_FD=2
inspect_trap() {
  local rc=$?
  trap - EXIT
  # A signal that arrives WHILE we are tearing down must not abort the teardown: that would
  # leave exactly the objects we are removing (found on the real host: SIGTERM at the end of a
  # run killed the teardown halfway and left a snapshot LV). So ignore them from here on;
  # SIGKILL still works, and `vm2lxc cleanup` recovers from the journal.
  trap '' INT TERM HUP
  if ((INSPECT_ARMED)); then
    INSPECT_ARMED=0
    {
      printf '\nvm2lxc: tearing down run %s ...\n' "$RUN_ID"
      if ! run_teardown "$RUN_ID"; then
        printf 'vm2lxc: teardown is INCOMPLETE. Nothing was lost: run "vm2lxc cleanup --yes" to finish it.\n'
        if ((rc == 0)); then rc=$EXIT_REFUSED; fi
      fi
    } 1>&"$INSPECT_OUT_FD" 2>&"$INSPECT_ERR_FD"
  fi
  exit "$rc"
}

# Pick the guest's root filesystem among what was mounted from the boot disk.
pick_guest_root() {
  local m key target dev mnt fs
  GUEST_ROOT=""
  for m in "${MOUNTS[@]}"; do
    IFS='|' read -r key target dev mnt fs <<<"$m"
    [[ $target == rootfs ]] || continue
    if [[ -d $mnt/etc && ( -d $mnt/usr || -d $mnt/bin ) ]]; then
      GUEST_ROOT=$mnt
      return 0
    fi
  done
  return 1
}

cmd_inspect() {
  local vmid run vstate m key target dev mnt fs s vm_lock
  (($# == 1)) || die "$EXIT_USAGE" "usage: vm2lxc inspect <vmid>"
  vmid=$1
  vmid_valid "$vmid" || die "$EXIT_USAGE" "not a valid VM id: '$vmid' (expected a number, 100 or higher)"
  host_context_load
  findings_reset
  vm_context_load "$vmid" ||
    die "$EXIT_NOINPUT" "VM $vmid not found on node $PVE_NODE_NAME, or its config could not be read"
  run=${VM2LXC_RUN_ID:-$(snap_gen_run_id)}
  snap_plan_build "$vmid" "$run" || die "$EXIT_DATAERR" "cannot plan snapshots for VM $vmid: $PLAN_ERR"

  printf '%svm2lxc inspect %s%s  "%s"\n' "$C_BLD" "$vmid" "$C_RST" "$(qmc_get name '(unnamed)')"
  printf '  node %s | PVE %s | %s\n\n' "$PVE_NODE_NAME" "${PVE_VERSION:-unknown}" "$(pve_mode_label)"
  vstate=$(vm_run_state "$vmid")
  if [[ $vstate == running ]]; then
    printf 'Note: the VM is running, so the snapshot is crash-consistent, not application-consistent.\n\n'
  fi
  vm_lock=$(qmc_get lock)
  if [[ -n $vm_lock ]]; then
    printf 'Note: the VM is locked (lock: %s): another operation is working on it. --yes will refuse until the lock is gone.\n\n' "$vm_lock"
  fi
  snap_plan_print "$vmid" "$run"

  if ((!OPT_YES)) || ((OPT_DRY_RUN)); then
    printf '\nNothing was executed. Re-run with --yes to carry out this plan.\n'
    return 0
  fi

  snap_plan_executable || die "$EXIT_NOTIMPL" "$PLAN_ERR"
  exec_guard
  # A lock (backup, rollback, migrate, clone, snapshot-delete, ...) means something is working on
  # this VM's disks right now. Snapshotting an LV that is being swapped or removed is exactly
  # what a safety layer must not do. Seen on a real host: backup jobs lock the test VMs.
  if [[ -n $vm_lock ]]; then
    die "$EXIT_REFUSED" "VM $vmid is locked (lock: $vm_lock): another operation is running on it, so vm2lxc will not snapshot its disks now. Retry when the lock is gone."
  fi
  lock_acquire || die "$EXIT_REFUSED" "another vm2lxc run holds the lock (no changes made)"
  journal_new "$vmid" "$run" || die "$EXIT_ENV" "could not create the journal under $(state_dir)"
  exec {INSPECT_OUT_FD}>&1 {INSPECT_ERR_FD}>&2
  INSPECT_ARMED=1
  trap inspect_trap EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP # the ssh session dropping must still tear down

  printf '\nExecuting. Journal: %s\n' "$JOURNAL"
  run_apply || die "$?" "the plan failed part-way (everything created so far is being torn down)"

  printf '\nMounted read-only:\n'
  if ((${#MOUNTS[@]} == 0)); then printf '  (nothing)\n'; fi
  for m in "${MOUNTS[@]}"; do
    IFS='|' read -r key target dev mnt fs <<<"$m"
    printf '  %-8s %-7s %-6s %s  ->  %s\n' "$key" "$target" "$fs" "$dev" "$mnt"
  done
  for s in "${SKIPPED[@]}"; do
    IFS='|' read -r key dev fs mnt <<<"$s"
    printf '  skipped %s (%s): %s\n' "$dev" "$fs" "$mnt"
  done
  for s in "${MOUNT_NOTES[@]}"; do printf '  note: %s\n' "$s"; done

  if pick_guest_root; then
    printf '\nGuest root: %s\n' "$GUEST_ROOT"
  else
    printf '\nNo Linux root filesystem (etc + usr or bin) was found on the boot disk: the guest checks have nothing to look at.\n'
  fi
  findings_reset
  guest_checks_run
  verdict_compute
  printf 'Guest checks: %d ran, %d pending (not implemented yet).\n' "${#GUEST_RAN[@]}" "${#GUEST_PENDING[@]}"
  local i
  for i in "${!F_LEVEL[@]}"; do
    case ${F_LEVEL[$i]} in
      red | yellow) printf '  [%s] %s\n' "${F_LEVEL[$i]^^}" "${F_MSG[$i]}" ;;
    esac
  done
  return 0
}

cmd_cleanup() {
  local run rc=0 any_fail=0 n kind
  local -a open args
  (($# == 0)) || die "$EXIT_USAGE" "usage: vm2lxc cleanup"
  mapfile -t open < <(runs_open)
  if ((${#open[@]} == 0)); then
    printf 'Nothing to clean up: no unfinished vm2lxc run in %s.\n' "$(state_dir)"
    return 0
  fi
  # Without --yes we do not take the lock, so say if someone else is holding it right now:
  # a run listed below may be IN PROGRESS rather than abandoned.
  if [[ -e $(state_dir)/lock ]] && ! flock -n "$(state_dir)/lock" true 2>/dev/null; then
    printf 'Note: a vm2lxc run holds the lock right now, so a run listed below may still be in progress.\n\n'
  fi
  printf 'Unfinished vm2lxc runs (%s):\n' "$(state_dir)"
  for run in "${open[@]}"; do
    journal_load "$run" || continue
    printf '\n  run %s (VM %s)\n' "$run" "${RUN_VMID:-?}"
    for ((n = JL_N; n >= 1; n--)); do
      kind=${JL_KIND[$n]:-}
      [[ -n $kind && ${JL_STATE[$n]:-} != UNDONE && ${JL_STATE[$n]:-} != FOREIGN ]] || continue
      IFS=$'\t' read -ra args <<<"${JL_ARGS[$n]}"
      printf '    would undo step %d  %-14s %s  [%s]\n' "$n" "$kind" "${args[*]}" "${JL_STATE[$n]}"
    done
  done
  if ((!OPT_YES)) || ((OPT_DRY_RUN)); then
    printf '\nNothing was changed. Re-run with --yes to remove these. Only objects named in the journals above are touched.\n'
    return 0
  fi
  exec_guard
  lock_acquire || die "$EXIT_REFUSED" "another vm2lxc run holds the lock: not touching its objects"
  for run in "${open[@]}"; do
    rc=0
    run_teardown "$run" || rc=$?
    if ((rc == 0)); then
      printf '\n  run %s: cleaned up, journal closed.\n' "$run"
    else
      printf '\n  run %s: NOT fully cleaned up (rc=%d). The journal stays open; fix the cause and run cleanup again.\n' "$run" "$rc"
      any_fail=$rc
    fi
  done
  return "$any_fail"
}
