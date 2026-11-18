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
# run_arm_traps: from here on, however the command ends (error, Ctrl-C, SIGTERM, the ssh session dropping,
# a reader going away) the run is torn down. Shared by inspect and convert.
run_arm_traps() {
  exec {INSPECT_OUT_FD}>&1 {INSPECT_ERR_FD}>&2
  INSPECT_ARMED=1
  inspect_traps_on
}
# the signal and exit traps alone (no new file descriptors), so a loop over several VMs can switch them back on
# after it ignored the signals during a teardown
inspect_traps_on() {
  trap inspect_trap EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP  # the ssh session dropping must still tear down
  trap 'exit 141' PIPE # a reader that went away (`| head`) must still tear down
}

inspect_trap() {
  local rc=$?
  # A signal that arrives WHILE we are tearing down must not abort the teardown: that would
  # leave exactly the objects we are removing (found on the real host: SIGTERM at the end of a
  # run killed the teardown halfway and left a snapshot LV). So ignore them, FIRST, before
  # anything else: PIPE too (a reader that went away, as in `| head`) and QUIT. SIGKILL still
  # works, and `vm2lxc cleanup` recovers from the journal.
  trap '' INT TERM HUP PIPE QUIT
  trap - EXIT
  # A failed write to a dead pipe must not make this trap exit before the teardown is finished.
  set +e
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

# path_inside_root <root> <path>: rc 0 only if <path> exists AND, with every symlink resolved on the
# HOST, it is still inside <root>. The guest is untrusted: an absolute symlink in it (/etc -> /etc)
# points at the host, not at the guest. Every guest check must use this (or a chroot-style
# resolver) before it reads anything under the guest root.
path_inside_root() {
  local r p
  r=$(realpath -e -- "$1" 2>/dev/null) || return 1
  p=$(realpath -e -- "$2" 2>/dev/null) || return 1
  [[ $p == "$r" || $p == "$r"/* ]]
}

# Pick the guest's root filesystem among what was mounted from the boot disk.
pick_guest_root() {
  local m key target dev mnt fs
  GUEST_ROOT=""
  for m in "${MOUNTS[@]}"; do
    IFS='|' read -r key target dev mnt fs <<<"$m"
    [[ $target == rootfs ]] || continue
    if path_inside_root "$mnt" "$mnt/etc" && { path_inside_root "$mnt" "$mnt/usr" || path_inside_root "$mnt" "$mnt/bin"; }; then
      GUEST_ROOT=$mnt
      return 0
    fi
  done
  return 1
}

# The plan was built, and the VM's lock checked, BEFORE we took the run lock. A backup can start, or a
# disk move, in between. Re-read everything after the lock and refuse if anything changed.
inspect_revalidate() { # <vmid> <run>
  local -a before=("${PLAN[@]}")
  vm_context_load "$1" || {
    printf 'vm2lxc: VM %s can no longer be read\n' "$1" >&2
    return 1
  }
  if [[ -n $(qmc_get lock) ]]; then
    printf 'vm2lxc: VM %s became locked (lock: %s) after the plan was made\n' "$1" "$(qmc_get lock)" >&2
    return 1
  fi
  snap_plan_build "$1" "$2" || {
    printf 'vm2lxc: the plan can no longer be built: %s\n' "$PLAN_ERR" >&2
    return 1
  }
  if [[ "${before[*]}" != "${PLAN[*]}" ]]; then
    printf 'vm2lxc: VM %s changed (its disks or paths) between the plan and the start of the run\n' "$1" >&2
    return 1
  fi
}

# --- the default look inside, for scan and preflight (rail R40) --------------------------------------------------
# Fred, 2026-11-18, shown the preflight screen that said "12 guest checks need disk inspection (not implemented
# yet)": scan and preflight always look inside. They use THIS engine, the same one `inspect --yes` uses: run lock, a
# write-ahead journal, a read-only snapshot, read-only mounts, teardown that also runs on Ctrl-C. A VM that cannot be
# looked at (locked, its storage not supported yet, a mount that failed) is reported "not checked" with the reason
# and never aborts the scan. --no-inspect and --dry-run give the old config-only behaviour; fixture mode never
# executes.
INSPECT_OVERLAY_ON=0 INSPECT_OVERLAY_WHY="" INSPECT_LOCK=0 INSPECT_BROKEN=0 INSPECT_RUN_N=0 INSPECT_TRAPS=0

# inspect_overlay_wanted: rc 0 look inside; rc 1 not, and INSPECT_OVERLAY_WHY is the reason in words
inspect_overlay_wanted() {
  if ((!INSPECT_OVERLAY_ON)); then
    INSPECT_OVERLAY_WHY="this listing does not look inside disks"
  elif ((OPT_NO_INSPECT)); then
    INSPECT_OVERLAY_WHY="you asked for --no-inspect"
  elif ((OPT_DRY_RUN)); then
    INSPECT_OVERLAY_WHY="this is a dry run"
  elif pve_fixture_mode && [[ ${VM2LXC_TEST_EXEC:-} != 1 ]]; then
    INSPECT_OVERLAY_WHY="fixture mode never executes"
  elif ((INSPECT_BROKEN)); then
    INSPECT_OVERLAY_WHY="an earlier teardown was incomplete, run: vm2lxc cleanup --yes"
  else
    return 0
  fi
  return 1
}

# inspect_overlay_teardown <run>: tear the run down with the signals ignored, then switch the traps back on
inspect_overlay_teardown() {
  local rc=0
  INSPECT_ARMED=0
  trap '' INT TERM HUP PIPE QUIT
  run_teardown "$1" >/dev/null 2>&"$INSPECT_ERR_FD" || rc=$?
  inspect_traps_on
  if ((rc != 0)); then
    INSPECT_BROKEN=1
    printf 'vm2lxc: the teardown of run %s is INCOMPLETE. Nothing was lost: run "vm2lxc cleanup --yes" to finish it.\n' "$1" >&2
  fi
  return "$rc"
}

# inspect_overlay <vmid>: the VM's context is loaded and its VM-config findings are collected. Look inside, run the 12
# guest checks, add their findings to the pile (GUEST_RAN / GUEST_PENDING are set), tear down.
#   rc 0 the guest checks ran      rc 1 not looked at (INSPECT_OVERLAY_WHY says why; the findings are unchanged)
inspect_overlay() {
  local vmid=$1 run lock rc=0 i
  local -a s_level s_id s_kind s_msg
  inspect_overlay_wanted || return 1
  lock=$(qmc_get lock)
  if [[ -n $lock ]]; then
    INSPECT_OVERLAY_WHY="the VM is locked (lock: $lock): another operation is working on it, so its disks are not snapshotted now"
    return 1
  fi
  if ((INSPECT_LOCK == 0)); then
    if lock_acquire; then INSPECT_LOCK=1; else INSPECT_LOCK=-1; fi
  fi
  if ((INSPECT_LOCK < 0)); then
    INSPECT_OVERLAY_WHY="another vm2lxc run holds the lock"
    return 1
  fi
  INSPECT_RUN_N=$((INSPECT_RUN_N + 1))
  # Test seam: with VM2LXC_RUN_ID=rtest01 the n-th look inside uses rtest01, rtest02, ... so a fake host can be seeded
  # for each. Without it (always, in real use) every run gets a fresh random id.
  if [[ ${VM2LXC_RUN_ID:-} =~ ^(.*[a-z])([0-9]+)$ ]]; then
    run=$(printf '%s%0*d' "${BASH_REMATCH[1]}" "${#BASH_REMATCH[2]}" $((10#${BASH_REMATCH[2]} + INSPECT_RUN_N - 1)))
  elif [[ -n ${VM2LXC_RUN_ID:-} ]] && ((INSPECT_RUN_N == 1)); then
    run=$VM2LXC_RUN_ID
  else
    run=$(snap_gen_run_id)
  fi
  snap_plan_build "$vmid" "$run" || {
    INSPECT_OVERLAY_WHY="its disks cannot be planned for a snapshot: $PLAN_ERR"
    return 1
  }
  snap_plan_executable || {
    INSPECT_OVERLAY_WHY=$PLAN_ERR
    return 1
  }
  journal_new "$vmid" "$run" || {
    INSPECT_OVERLAY_WHY="the journal under $(state_dir) could not be created"
    return 1
  }
  CT_ID=""
  if ((!INSPECT_TRAPS)); then
    run_arm_traps
    INSPECT_TRAPS=1
  else
    INSPECT_ARMED=1
    inspect_traps_on
  fi
  if [[ -z ${VM2LXC_PROGRESS_FILE:-} ]]; then # inside the menu the progress bar says it instead
    printf 'vm2lxc: looking inside VM %s (read-only snapshot, run %s) ...\n' "$vmid" "$run" >&2
  fi
  run_apply >/dev/null || rc=$?
  if ((rc != 0)); then
    inspect_overlay_teardown "$run" || true
    INSPECT_OVERLAY_WHY="the snapshot or the read-only mount failed (exit $rc); everything created was torn down"
    return 1
  fi
  s_level=("${F_LEVEL[@]}") s_id=("${F_ID[@]}") s_kind=("${F_KIND[@]}") s_msg=("${F_MSG[@]}")
  findings_reset
  progress_emit checks 1 1 guest-checks
  if ! pick_guest_root; then GUEST_ROOT=""; fi
  GUEST_PENDING_WHY="no Linux root filesystem (etc + usr or bin) was found on the boot disk"
  guest_checks_run
  local -a g_level=("${F_LEVEL[@]}") g_id=("${F_ID[@]}") g_kind=("${F_KIND[@]}") g_msg=("${F_MSG[@]}")
  findings_reset
  for i in "${!s_level[@]}"; do finding "${s_level[$i]}" "${s_id[$i]}" "${s_kind[$i]}" "${s_msg[$i]}"; done
  for i in "${!g_level[@]}"; do finding "${g_level[$i]}" "${g_id[$i]}" "${g_kind[$i]}" "${g_msg[$i]}"; done
  verdict_compute
  inspect_overlay_teardown "$run" || true
  if ((${#GUEST_RAN[@]} == 0)); then
    INSPECT_OVERLAY_WHY=$GUEST_PENDING_WHY
    return 1
  fi
  return 0
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
  inspect_revalidate "$vmid" "$run" || die "$EXIT_REFUSED" "VM $vmid changed since the plan was shown: nothing was done, run it again"
  journal_new "$vmid" "$run" || die "$EXIT_ENV" "could not create the journal under $(state_dir)"
  run_arm_traps

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
  progress_emit checks 1 1 guest-checks
  guest_checks_run
  verdict_compute
  printf 'Guest checks: %d ran, %d pending.\n' "${#GUEST_RAN[@]}" "${#GUEST_PENDING[@]}"
  local i
  for i in "${!F_LEVEL[@]}"; do
    case ${F_LEVEL[$i]} in
      red | yellow | info) printf '  [%s] %s\n' "${F_LEVEL[$i]^^}" "${F_MSG[$i]}" ;;
    esac
  done
  printf 'Guest verdict: %s (VM-config checks: run vm2lxc preflight)\n' "${VERDICT^^}"
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
