#!/usr/bin/env bats
# R40: scan and preflight look inside the disks by default (inspect_overlay), through the same snapshot-mount engine
# as `inspect --yes`, against the stateful fake host. Every way of NOT looking is tested too, and every failure must
# leave the scan alive and the host clean.

bats_require_minimum_version 1.5.0
load helpers

Z1=rpool/data/vm-100-disk-0
Z2=rpool/data/vm-102-disk-0

setup() {
  setup_fake_host
}

guest_tree() { # <device>: a Debian-like guest, copied into the mount point when that device is mounted
  local d="$FAKE_STATE/guest/$(fake_enc "$1")"
  mkdir -p "$d/etc/network" "$d/etc/systemd/system" "$d/usr/bin" "$d/bin" "$d/var/lib"
  printf 'ID=debian\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' >"$d/etc/os-release"
  printf 'UUID=aaaa-1 / ext4 defaults 0 1\n' >"$d/etc/fstab"
}

seed_vm() { # <vmid> <run id>: a zfs VM with a partitioned guest, as run <run id> will clone it
  local d=/dev/zvol/rpool/data/vm2lxc-$1-$2-scsi0
  seed_zvol "rpool/data/vm-$1-disk-0"
  seed_lsblk_dev "$d" "$d" "$d-part1 ext4" "$d-part2 vfat"
  guest_tree "$d-part1"
}

# every run of these tests uses the -part1 naming; ids are rtest01, rtest02 (the test seam in inspect_overlay)
go() { VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 run_fx "$@"; }

no_tool_called() {
  [ ! -e "$FAKE_STATE/calls.log" ] || { echo "a storage tool was called:"; cat "$FAKE_STATE/calls.log"; return 1; }
}

@test "preflight looks inside by default: all 12 checks run, the verdict is final, and nothing is left behind" {
  seed_vm 100 rtest01
  fake_rootfs_suffix "-part1"
  go preflight 100
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"VERDICT: GREEN"* ]]
  [[ $output == *"No blockers in the VM config or inside the guest: all 12 guest checks ran."* ]]
  [[ $output == *"12 ran: os-release docker kernel-modules"* ]]
  [[ $output != *"not checked"* && $output != *"provisional"* ]]
  [[ $output == *"The disk was looked at through a read-only snapshot, which is already removed again."* ]]
  grep -q 'zfs snapshot' "$FAKE_STATE/calls.log"
  assert_nothing_left
  grep -q '^CLOSED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
  must_fail grep -q '^COMMITTED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
}

@test "preflight: a guest that is not convertible makes the verdict RED (exit 20) with the reason from inside the disk" {
  seed_vm 100 rtest01
  fake_rootfs_suffix "-part1"
  local g="$FAKE_STATE/guest/$(fake_enc /dev/zvol/rpool/data/vm2lxc-100-rtest01-scsi0-part1)"
  mkdir -p "$g/var/lib/docker/overlay2" && printf x >"$g/var/lib/docker/overlay2/layer"
  go preflight 100
  [ "$status" -eq 20 ] || { echo "$output"; return 1; }
  [[ $output == *"VERDICT: RED"* && $output == *"Docker/Podman/containerd found"* ]]
  assert_nothing_left
}

@test "preflight --no-inspect and --dry-run: no tool is called, and the output says why nothing was checked" {
  seed_vm 100 rtest01
  fake_rootfs_suffix "-part1"
  go preflight 100 --no-inspect
  [[ $output == *"12 guest-internal checks were not run (you asked for --no-inspect)"* ]]
  [[ $output == *"Nothing was changed: no disk was looked at"* ]]
  no_tool_called
  go preflight 100 --dry-run
  [[ $output == *"(this is a dry run)"* ]]
  no_tool_called
}

@test "preflight on a VM the config already rules out (RED): its disk is not looked at, and it says so" {
  go preflight 103
  [ "$status" -eq 20 ]
  [[ $output == *"the VM config already rules it out (RED), so its disk was not looked at"* ]]
  no_tool_called
}

@test "preflight: a locked VM is RED from its config, so no snapshot is ever taken of it" {
  seed_vm 100 rtest01
  fake_rootfs_suffix "-part1"
  local fx="$BATS_TEST_TMPDIR/lockfx"
  cp -r "$FIXTURES/pve8" "$fx"
  printf 'lock: backup\n' >>"$fx/qm-config-100.txt"
  VM2LXC_FIXTURE_DIR="$fx" VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 run "$VM2LXC" preflight 100
  [ "$status" -eq 20 ]
  [[ $output == *"VM is locked (lock: backup)"* && $output == *"its disk was not looked at"* ]]
  no_tool_called
}

@test "preflight: another vm2lxc run holding the lock means no look inside, said plainly" {
  seed_vm 100 rtest01
  fake_rootfs_suffix "-part1"
  mkdir -p "$VM2LXC_STATE_DIR"
  ( flock -n 9 && sleep 20 ) 9>"$VM2LXC_STATE_DIR/lock" &
  local holder=$!
  sleep 0.5
  go preflight 100
  kill "$holder" 2>/dev/null || true
  [[ $output == *"another vm2lxc run holds the lock"* ]]
  no_tool_called
}

@test "preflight: a failing read-only mount is rolled back completely and reported, the command still prints its verdict" {
  seed_vm 100 rtest01
  fake_rootfs_suffix "-part1"
  FAKE_FAIL=mount:1 go preflight 100
  [[ $output == *"the snapshot or the read-only mount failed"* ]]
  [[ $output == *"VERDICT:"* ]]
  assert_nothing_left
}

@test "scan looks inside every VM that is not RED, shows it in the row and the footer, and leaves nothing behind" {
  seed_vm 100 rtest01
  seed_vm 102 rtest02
  fake_rootfs_suffix "-part1"
  go scan 100 102
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"ran on 2 VM(s)"* ]]
  [[ $output == *"inside the guest"* ]]
  [[ $output != *"Verdicts are provisional"* ]]
  assert_nothing_left
}

@test "scan: a VM that cannot be looked at does not stop the others; the footer lists it with the reason" {
  seed_vm 100 rtest01
  fake_rootfs_suffix "-part1"
  # VM 102 has no seeded devices: its clone never appears, so its look inside fails and is rolled back
  go scan 100 102
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"ran on 1 VM(s)"* ]]
  [[ $output == *"their guest-internal checks did not run"* && $output == *"- VM 102:"* ]]
  [[ $output == *"web-green"* && $output == *"usb-box"* ]] # both rows are there
  assert_nothing_left
}

@test "scan --no-inspect: config only, no tool called, one honest line instead of 'not implemented yet'" {
  go scan --no-inspect
  [ "$status" -eq 0 ]
  [[ $output == *"Verdicts are provisional: no disk was looked at, so the guest-internal checks did not run (you asked for --no-inspect)"* ]]
  [[ $output != *"not implemented"* ]]
  no_tool_called
}

@test "scan in fixture mode without the test seam never executes (it says so) and calls no tool" {
  VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" run "$VM2LXC" scan
  [ "$status" -eq 0 ]
  [[ $output == *"(fixture mode never executes)"* ]]
  [ ! -e "$FAKE_STATE/calls.log" ]
}

@test "scan: an incomplete teardown stops further looking, says run cleanup, and exits 77" {
  seed_vm 100 rtest01
  seed_vm 102 rtest02
  fake_rootfs_suffix "-part1"
  FAKE_FAIL=umount:1 go scan 100 102
  [ "$status" -eq 77 ] || { echo "status $status"; echo "$output"; return 1; }
  [[ $output == *"INCOMPLETE"* && $output == *"vm2lxc cleanup --yes"* ]]
  [[ $output == *"an earlier teardown was incomplete"* ]] # VM 102 was not looked at after it
  # and cleanup really does finish it
  VM2LXC_TEST_EXEC=1 run_fx cleanup --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_nothing_left
}

@test "inspect_overlay called directly on a VM that is locked (a lock that appeared after the config was read): refused, no tool" {
  export VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" VM2LXC_TEST_EXEC=1
  host_context_load
  vm_context_load 100
  QMC[lock]=migrate
  INSPECT_OVERLAY_ON=1
  must_fail inspect_overlay 100
  [[ $INSPECT_OVERLAY_WHY == *"the VM is locked (lock: migrate)"* ]]
  no_tool_called
}

@test "scan never snapshots a VM the config already rules out (RED), even one whose disk COULD be snapshotted" {
  seed_vm 100 rtest01
  fake_rootfs_suffix "-part1"
  # give VM 103 (RED: PCI passthrough) a real, plannable zfs disk, so that a scan which wrongly looked inside it WOULD snapshot it
  local fx="$BATS_TEST_TMPDIR/redfx"
  cp -r "$FIXTURES/pve8" "$fx"
  printf 'local-zfs:vm-103-disk-0 /dev/zvol/rpool/data/vm-103-disk-0\n' >>"$fx/volume-paths.txt"
  seed_zvol rpool/data/vm-103-disk-0
  VM2LXC_FIXTURE_DIR="$fx" VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 run "$VM2LXC" scan 100 103
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"ran on 1 VM(s)"* ]]
  grep -q 'vm-100-disk-0' "$FAKE_STATE/calls.log"
  must_fail grep -q 'vm-103' "$FAKE_STATE/calls.log"
  assert_nothing_left
}

@test "scan: when the first VM's look fails half-way it is torn down at once, not left until the end (the next VM must not hide it)" {
  seed_vm 100 rtest01
  seed_vm 102 rtest02
  fake_rootfs_suffix "-part1"
  FAKE_FAIL=mount:1 go scan 100 102
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"ran on 1 VM(s)"* && $output == *"- VM 100: the snapshot or the read-only mount failed"* ]]
  assert_nothing_left
}

@test "preflight keeps the VM-config findings AND adds the guest's: a YELLOW USB VM that is looked inside shows both" {
  seed_vm 102 rtest01
  fake_rootfs_suffix "-part1"
  go preflight 102
  [ "$status" -eq 10 ] || { echo "status $status"; echo "$output"; return 1; }
  [[ $output == *"[YELLOW] usb0 is USB passthrough"* ]]
  [[ $output == *"guest OS: Debian GNU/Linux 12 (bookworm)"* ]]
  [[ $output == *"12 ran: os-release docker"* ]]
  assert_nothing_left
}
