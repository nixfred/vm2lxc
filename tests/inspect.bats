#!/usr/bin/env bats
# `vm2lxc inspect` and `vm2lxc cleanup` end to end: fixture host for the VM's config, the
# stateful fake (tests/stubs/fakehost.sh) for the storage tools. Nothing here touches a real host.

bats_require_minimum_version 1.5.0
load helpers

Z1=rpool/data/vm-100-disk-0
C0=rpool/data/vm2lxc-100-rtest01-scsi0
CD0=/dev/zvol/$C0

setup() {
  setup_fake_host
}

# VM 100 (zfs, 1 disk, running) with a partitioned guest, ready for a full run
seed_vm100() {
  seed_zvol "$Z1"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 ext4" "$CD0-part2 vfat"
  fake_rootfs_suffix "-part1"
}

# VM 101 (lvm-thin, 2 disks, running)
seed_vm101() {
  seed_lv pve vm-101-disk-0
  seed_lv pve vm-101-disk-1
  seed_lsblk_backing /dev/pve/vm2lxc-101-rtest01-scsi0 "@LOOP@" "@LOOP@p1 ext4" "@LOOP@p2 vfat"
  seed_lsblk_backing /dev/pve/vm2lxc-101-rtest01-scsi1 "@LOOP@ ext4"
  fake_rootfs_suffix "p1"
}

go() { # run inspect/cleanup in test-exec mode with a fixed run id
  VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 run_fx "$@"
}

no_tool_called() {
  [ ! -e "$FAKE_STATE/calls.log" ] || { echo "a storage tool was called:"; cat "$FAKE_STATE/calls.log"; return 1; }
}

# --- plan mode: shows, executes nothing -----------------------------------------------------------

@test "plan (zfs): prints the plan and the promise, exits 0, calls no storage tool" {
  seed_vm100
  go inspect 100
  [ "$status" -eq 0 ]
  [[ $output == *'vm2lxc inspect 100  "web-green"'* ]]
  [[ $output == *"Plan for VM 100, run rtest01"* ]]
  [[ $output == *"1. zfs snapshot -o vm2lxc:run=rtest01  rpool/data/vm-100-disk-0@vm2lxc-rtest01"* ]]
  [[ $output == *"Nothing was executed. Re-run with --yes to carry out this plan."* ]]
  no_tool_called
}

@test "plan (lvm, two disks): shows snapshots, activation, loop devices and mounts" {
  go inspect 101
  [ "$status" -eq 0 ]
  [[ $output == *"2. lvcreate -s thin snapshot of pve/vm-101-disk-1 as pve/vm2lxc-101-rtest01-scsi1"* ]]
  [[ $output == *"losetup -r -f --show -P /dev/pve/vm2lxc-101-rtest01-scsi0"* ]]
  [[ $output == *"(disk scsi1, becomes mp0)"* ]]
  no_tool_called
}

@test "plan: a running VM is called out as crash-consistent; a stopped one is not" {
  go inspect 100
  [[ $output == *"the VM is running, so the snapshot is crash-consistent"* ]]
  go inspect 102
  [[ $output != *"crash-consistent"* ]]
}

@test "plan: --dry-run beats --yes, nothing is executed" {
  seed_vm100
  go inspect 100 --yes --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"Nothing was executed"* ]]
  no_tool_called
  [ ! -d "$VM2LXC_STATE_DIR/runs" ]
}

@test "plan: storage the layer cannot snapshot is exit 65 with the reason, never a crash" {
  go inspect 107
  [ "$status" -eq 65 ]
  [[ $output == *"cannot plan snapshots for VM 107"*"storage 'local' is type 'dir'"* ]]
}

@test "inspect: unknown VM is 66, bad arguments are 64" {
  go inspect 999
  [ "$status" -eq 66 ]
  go inspect
  [ "$status" -eq 64 ]
  go inspect abc
  [ "$status" -eq 64 ]
  go inspect 100 101
  [ "$status" -eq 64 ]
}

@test "a locked VM: the plan says so, and --yes refuses (77) before any storage tool runs (seen on a real host: backup locks)" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  printf 'lock: backup\n' >>"$fx/qm-config-100.txt"
  seed_vm100
  VM2LXC_RUN_ID=rtest01 VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" inspect 100
  [ "$status" -eq 0 ]
  [[ $output == *"the VM is locked (lock: backup)"*"--yes will refuse until the lock is gone"* ]]
  VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" inspect 100 --yes
  [ "$status" -eq 77 ]
  [[ $output == *"VM 100 is locked (lock: backup)"*"will not snapshot its disks now"* ]]
  no_tool_called
  [ ! -d "$VM2LXC_STATE_DIR/runs" ]
  zfs_has "$Z1"
}

@test "R8: --yes is refused (77) in fixture mode without the test switch, and nothing is created" {
  seed_vm100
  VM2LXC_RUN_ID=rtest01 run_fx inspect 100 --yes
  [ "$status" -eq 77 ]
  [[ $output == *"fixture mode never executes"* ]]
  no_tool_called
  [ ! -d "$VM2LXC_STATE_DIR/runs" ]
}

@test "R8: --yes on a live host without root is refused (69) before any storage tool runs" {
  if [ "$(id -u)" -eq 0 ]; then skip "running as root"; fi
  VM2LXC_FIXTURE_DIR="" run "$VM2LXC" inspect 100 --yes
  [ "$status" -eq 69 ]
  no_tool_called
}

# --- full runs against the fake host --------------------------------------------------------------------

@test "run (zfs): mounts read-only, finds the guest root, runs the guest checks, and leaves nothing behind" {
  seed_vm100
  go inspect 100 --yes
  [ "$status" -eq 0 ]
  [[ $output == *"Mounted read-only:"* ]]
  [[ $output == *"scsi0    rootfs  ext4"*"$CD0-part1"* ]]
  [[ $output == *"skipped $CD0-part2 (vfat): not a filesystem vm2lxc mounts"* ]]
  [[ $output == *"Guest root: $VM2LXC_RUN_ROOT/rtest01/scsi0/"* ]]
  [[ $output == *"Guest checks: 12 ran, 0 pending."* ]]
  [[ $output == *"[YELLOW] /etc/os-release has no ID"* ]] # the fake guest has a bare os-release
  [[ $output == *"Guest verdict: YELLOW"* ]]
  assert_nothing_left
  zfs_has "$Z1"
  [[ -z $(runs_open) ]]
  grep -q '^CLOSED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
}

@test "run (lvm, two disks): both disks mounted, then loops detached and snapshot LVs removed, sources intact" {
  seed_vm101
  VM2LXC_RUN_ID=rtest01 VM2LXC_TEST_EXEC=1 run_fx inspect 101 --yes
  [ "$status" -eq 0 ]
  [[ $output == *"scsi0    rootfs  ext4"* ]]
  [[ $output == *"scsi1    mp0     ext4"* ]]
  assert_nothing_left
  lv_has pve/vm-101-disk-0
  lv_has pve/vm-101-disk-1
  [[ -z $(runs_open) ]]
}

@test "run: a disk with LUKS inside is reported as skipped, and the run still succeeds" {
  seed_zvol "$Z1"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 crypto_LUKS"
  go inspect 100 --yes
  [ "$status" -eq 0 ]
  [[ $output == *"skipped $CD0-part1 (crypto_LUKS): guest LVM / LUKS / mdraid is not supported yet"* ]]
  [[ $output == *"No Linux root filesystem"* ]]
  assert_nothing_left
}

@test "run: a failure part-way tears everything down and reports a non-zero exit" {
  seed_vm100
  export FAKE_FAIL=mount:1
  go inspect 100 --yes
  [ "$status" -ne 0 ]
  [[ $output == *"the plan failed part-way"* ]]
  [[ $output == *"tearing down run rtest01"* ]]
  unset FAKE_FAIL
  assert_nothing_left
  zfs_has "$Z1"
  [[ -z $(runs_open) ]]
}

@test "run: SIGTERM while the plan is running still tears everything down (exit 143, nothing left)" {
  seed_vm100
  FAKE_SLEEP_LSBLK=2 VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" \
    "$VM2LXC" inspect 100 --yes >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$! i
  for i in $(seq 1 80); do
    zfs_has "$C0" && break
    sleep 0.1
  done
  zfs_has "$C0"
  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  assert_nothing_left
  zfs_has "$Z1"
  [[ -z $(runs_open) ]]
  grep -q "tearing down run rtest01" "$BATS_TEST_TMPDIR/out"
}

@test "run: SIGHUP (the ssh session dropping) mid-run still tears everything down (exit 129)" {
  seed_vm100
  FAKE_SLEEP_LSBLK=2 VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" \
    "$VM2LXC" inspect 100 --yes >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$! i
  for i in $(seq 1 80); do
    zfs_has "$C0" && break
    sleep 0.1
  done
  kill -HUP "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 129 ]
  assert_nothing_left
  zfs_has "$Z1"
  [[ -z $(runs_open) ]]
}

@test "run: a second SIGTERM WHILE tearing down does not abort the teardown (real-host finding)" {
  seed_vm100
  FAKE_SLEEP_LSBLK=2 FAKE_SLEEP_DESTROY=1 VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" \
    "$VM2LXC" inspect 100 --yes >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$! i
  for i in $(seq 1 80); do
    zfs_has "$C0" && break
    sleep 0.1
  done
  kill -TERM "$pid" # first signal: the trap starts the teardown once lsblk returns
  for i in $(seq 1 100); do
    fake_calls zfs | grep -q '^zfs destroy' && break # the teardown is now INSIDE a slow destroy
    sleep 0.1
  done
  fake_calls zfs | grep -q '^zfs destroy'
  kill -TERM "$pid" # second signal, during the teardown
  kill -HUP "$pid"  # and a hang-up for good measure
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  assert_nothing_left
  zfs_has "$Z1"
  [[ -z $(runs_open) ]]
  grep -q '^CLOSED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
}

@test "run: a held lock refuses the run (77) before anything is created" {
  seed_vm100
  mkdir -p "$VM2LXC_STATE_DIR"
  exec 9>"$VM2LXC_STATE_DIR/lock"
  flock -n 9
  go inspect 100 --yes
  exec 9>&-
  [ "$status" -eq 77 ]
  [[ $output == *"another vm2lxc run holds the lock"* ]]
  no_tool_called
}

# --- cleanup ---------------------------------------------------------------------------------------------------

crash_after_clone() { # a run that died after the snapshot and the clone were made
  seed_vm100
  plan_disks 100 rtest01 zfspool "scsi0:/dev/zvol/$Z1:rootfs"
  journal_new 100 rtest01
  PLAN=("${PLAN[@]:0:2}")
  VM2LXC_TEST_EXEC=1 run_apply # in-process; the switch lasts for this call only, later CLI runs stay without it
  zfs_has "$C0"
}

@test "cleanup with nothing to do says so, exits 0, and touches nothing" {
  go cleanup
  [ "$status" -eq 0 ]
  [[ $output == *"Nothing to clean up"* ]]
  no_tool_called
  [ ! -e "$VM2LXC_STATE_DIR/lock" ]
}

@test "cleanup without --yes lists what it WOULD undo (newest first) and changes nothing" {
  crash_after_clone
  go cleanup
  [ "$status" -eq 0 ]
  [[ $output == *"run rtest01 (VM 100)"* ]]
  [[ $output == *"would undo step 2  zfs-clone"* ]]
  [[ $output == *"would undo step 1  zfs-snapshot"* ]]
  [[ $output == *"Nothing was changed. Re-run with --yes"* ]]
  zfs_has "$C0"
  zfs_has "$Z1@vm2lxc-rtest01"
}

@test "cleanup without --yes warns when another run holds the lock (the listed run may be in progress)" {
  crash_after_clone
  mkdir -p "$VM2LXC_STATE_DIR"
  exec 9>"$VM2LXC_STATE_DIR/lock"
  flock -n 9
  go cleanup
  exec 9>&-
  [ "$status" -eq 0 ]
  [[ $output == *"a vm2lxc run holds the lock right now"*"may still be in progress"* ]]
  go cleanup
  [[ $output != *"holds the lock"* ]]
}

@test "cleanup --yes finishes a crashed run, closes its journal, and a second cleanup has nothing to do" {
  crash_after_clone
  go cleanup --yes
  [ "$status" -eq 0 ]
  [[ $output == *"run rtest01: cleaned up, journal closed."* ]]
  assert_nothing_left
  zfs_has "$Z1"
  go cleanup
  [[ $output == *"Nothing to clean up"* ]]
}

@test "cleanup --yes refuses (77) when it cannot finish: reports the run, keeps the journal open" {
  crash_after_clone
  sed -i "s/^vm2lxc:run=.*/vm2lxc:run=someoneelse/" "$FAKE_STATE/zfs/$(fake_enc "$C0")"
  go cleanup --yes
  [ "$status" -eq 77 ]
  [[ $output == *"NOT fully cleaned up"* ]]
  zfs_has "$C0"
  [[ $(runs_open) == "rtest01" ]]
}

@test "cleanup --yes is refused in fixture mode without the test switch, and while another run holds the lock" {
  crash_after_clone
  run_fx cleanup --yes
  [ "$status" -eq 77 ]
  [[ $output == *"fixture mode never executes"* ]]
  mkdir -p "$VM2LXC_STATE_DIR"
  exec 9>"$VM2LXC_STATE_DIR/lock"
  flock -n 9
  go cleanup --yes
  exec 9>&-
  [ "$status" -eq 77 ]
  [[ $output == *"another vm2lxc run holds the lock"* ]]
  zfs_has "$C0"
}

@test "cleanup takes no arguments" {
  go cleanup extra
  [ "$status" -eq 64 ]
}

# --- findings of the independent box review (2026-11-17) --------------------------------------------------------

@test "F4: the reader going away (| head) mid-run still tears everything down, even though every message now fails" {
  seed_vm100
  local rc=0
  # The reader leaves once the run has STARTED ("Executing."): the tool then writes into a dead pipe (SIGPIPE)
  # while the slow lsblk runs, and again for every message of its own teardown. (A reader that leaves earlier,
  # during the plan printout, proves nothing: no run and no trap exist yet.)
  FAKE_SLEEP_LSBLK=1 VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" \
    "$VM2LXC" inspect 100 --yes 2>/dev/null | sed '/^Executing/q' >/dev/null
  rc=${PIPESTATUS[0]}
  [ "$rc" -eq 141 ] || { echo "expected exit 141 (SIGPIPE), got $rc"; return 1; }
  [ -f "$VM2LXC_STATE_DIR/runs/rtest01/journal" ] # the run really started
  assert_nothing_left
  zfs_has "$Z1"
  [[ -z $(runs_open) ]]
  grep -q '^CLOSED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
}

@test "F5: a guest whose /etc and /usr are absolute symlinks to the HOST is not a guest root" {
  local mnt="$BATS_TEST_TMPDIR/g"
  mkdir -p "$mnt"
  ln -s /etc "$mnt/etc"
  ln -s /usr "$mnt/usr"
  MOUNTS=("scsi0|rootfs|/dev/x|$mnt|ext4")
  run pick_guest_root
  [ "$status" -eq 1 ]
  [ -z "$GUEST_ROOT" ]
}

@test "F5: a real root and a relative symlink that stays inside the guest are accepted" {
  local mnt="$BATS_TEST_TMPDIR/g"
  mkdir -p "$mnt/usr/share/etc-real"
  ln -s usr/share/etc-real "$mnt/etc" # inside the guest: fine
  MOUNTS=("scsi0|rootfs|/dev/x|$mnt|ext4")
  pick_guest_root
  [ "$GUEST_ROOT" = "$mnt" ]
  path_inside_root "$mnt" "$mnt/etc"
  must_fail path_inside_root "$mnt" /etc
  must_fail path_inside_root "$mnt" "$mnt/does-not-exist"
}

# F11: the VM is read again AFTER the run lock is taken
reval_setup() { # builds the plan the way cmd_inspect does, from a private copy of the fixture host
  REVAL_FX="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$REVAL_FX"
  export VM2LXC_FIXTURE_DIR="$REVAL_FX"
  host_context_load
  vm_context_load 100
  snap_plan_build 100 rtest01
}

@test "F11: re-validation passes when nothing changed" {
  reval_setup
  run inspect_revalidate 100 rtest01
  [ "$status" -eq 0 ]
}

@test "F11: a lock that appeared between the plan and the run lock refuses the run" {
  reval_setup
  printf 'lock: backup\n' >>"$REVAL_FX/qm-config-100.txt"
  run inspect_revalidate 100 rtest01
  [ "$status" -eq 1 ]
  [[ $output == *"became locked (lock: backup)"* ]]
}

@test "F11: a VM whose disks changed between the plan and the run lock refuses the run" {
  reval_setup
  sed -i 's#^scsi0: local-zfs:vm-100-disk-0#scsi0: local-zfs:vm-102-disk-0#' "$REVAL_FX/qm-config-100.txt"
  run inspect_revalidate 100 rtest01
  [ "$status" -eq 1 ]
  [[ $output == *"changed (its disks or paths)"* ]]
}

@test "F11: a VM that disappeared between the plan and the run lock refuses the run" {
  reval_setup
  rm "$REVAL_FX/qm-config-100.txt"
  run inspect_revalidate 100 rtest01
  [ "$status" -eq 1 ]
  [[ $output == *"can no longer be read"* ]]
}
