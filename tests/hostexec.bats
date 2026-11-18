#!/usr/bin/env bats
# The snapshot-mount executor against the STATEFUL fake host (tests/stubs/fakehost.sh).
# Covers: the allowlist (R1, R4, R6, R7), the lifecycle for ZFS and LVM-thin, every row of
# the failure matrix in docs/snapshot-layer.html, and the identity rails (R3, R9).
# Nothing here touches a real host: the fake tools are the only storage commands on PATH.

bats_require_minimum_version 1.5.0
load helpers

RUN=rtest01
Z1=rpool/data/vm-100-disk-0
Z2=rpool/data/vm-100-disk-1
C0=rpool/data/vm2lxc-100-rtest01-scsi0
C1=rpool/data/vm2lxc-100-rtest01-scsi1
CD0=/dev/zvol/$C0
CD1=/dev/zvol/$C1
SNAP="vm2lxc-$RUN"

setup() {
  setup_fake_host
  # In-process unit tests of the executor: the fake tools on PATH and a run root outside /run/vm2lxc
  # are only accepted behind this switch. (The CLI suites opt in per command instead, so that their
  # refusal tests really run without it.)
  export VM2LXC_TEST_EXEC=1
}

# a one-disk ZFS VM with a partitioned guest (root ext4 + EFI vfat), planned and journalled
zfs_one() {
  seed_zvol "$Z1"
  plan_disks 100 "$RUN" zfspool "scsi0:/dev/zvol/$Z1:rootfs"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 ext4" "$CD0-part2 vfat"
  fake_rootfs_suffix "-part1"
  journal_new 100 "$RUN"
}

zfs_two() {
  seed_zvol "$Z1"
  seed_zvol "$Z2"
  plan_disks 100 "$RUN" zfspool "scsi0:/dev/zvol/$Z1:rootfs" "scsi1:/dev/zvol/$Z2:mp0"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 ext4" "$CD0-part2 xfs"
  seed_lsblk_dev "$CD1" "$CD1 ext4"
  fake_rootfs_suffix "-part1"
  journal_new 100 "$RUN"
}

L0=pve/vm2lxc-101-rtest01-scsi0
L1=pve/vm2lxc-101-rtest01-scsi1

lvm_two() {
  seed_lv pve vm-101-disk-0
  seed_lv pve vm-101-disk-1
  plan_disks 101 "$RUN" lvmthin "scsi0:/dev/pve/vm-101-disk-0:rootfs" "scsi1:/dev/pve/vm-101-disk-1:mp0"
  seed_lsblk_backing "/dev/$L0" "@LOOP@" "@LOOP@p1 ext4" "@LOOP@p2 vfat"
  seed_lsblk_backing "/dev/$L1" "@LOOP@ ext4"
  fake_rootfs_suffix "p1"
  journal_new 101 "$RUN"
}

# --- the allowlist: refusals happen BEFORE any tool is invoked (R1, R4, R6, R7) ----------------

refused() { # <host_cmd args...>: must refuse with 77 and never reach the fake tools
  run host_cmd "$@"
  [ "$status" -eq 77 ] || { echo "expected 77, got $status for: $*"; echo "$output"; return 1; }
  [[ $output == *"REFUSED"* ]]
  [ ! -e "$FAKE_STATE/calls.log" ] || { echo "the fake was invoked for: $*"; cat "$FAKE_STATE/calls.log"; return 1; }
}

@test "allowlist zfs: destroy never accepts a flag, a source dataset, or a foreign name" {
  refused zfs destroy -r "$C0"
  refused zfs destroy -R "$C0"
  refused zfs destroy -f "$C0"
  refused zfs destroy -rf "$SNAP"
  refused zfs destroy "$Z1"
  refused zfs destroy "$Z1@vm2lxc"
  refused zfs destroy "$Z1@daily-backup"
  refused zfs destroy rpool/data
  refused zfs destroy "$C0" extra
  refused zfs destroy
}

@test "allowlist zfs: snapshot and clone shapes are exact (stamped, read-only, matching run)" {
  refused zfs snapshot "$Z1@$SNAP"
  refused zfs snapshot -o "vm2lxc:run=$RUN" "$Z1@other-name"
  refused zfs snapshot -o "vm2lxc:run=$RUN" "$Z1@vm2lxc-differentrun"
  refused zfs clone "$Z1@$SNAP" "$C0"
  refused zfs clone -o readonly=off -o "vm2lxc:run=$RUN" "$Z1@$SNAP" "$C0"
  refused zfs clone -o readonly=on -o "vm2lxc:run=$RUN" "$Z1@$SNAP" rpool/data/someones-dataset
  refused zfs clone -o readonly=on -o "vm2lxc:run=$RUN" "$Z1@$SNAP" "$Z1"
  refused zfs clone -o readonly=on -o "vm2lxc:run=wrongrun" "$Z1@$SNAP" "$C0"
}

@test "allowlist zfs: only list/get of the two properties we use; everything else is not on the list" {
  refused zfs get -H -o value mountpoint "$Z1"
  refused zfs get -H -o value all "$Z1"
  refused zfs list -r rpool
  refused zfs rollback "$Z1@$SNAP"
  refused zfs set readonly=off "$Z1"
  refused zfs promote "$C0"
  refused zfs rename "$Z1" "$Z1-x"
  refused zfs send "$Z1@$SNAP"
  refused zfs
}

@test "allowlist lvm: lvremove is exactly '-y <our snapshot LV>', never -f, never a source LV" {
  refused lvremove -f pve/vm2lxc-101-rtest01-scsi0
  refused lvremove -y -f pve/vm2lxc-101-rtest01-scsi0
  refused lvremove -y pve/vm-101-disk-0
  refused lvremove -y pve/data
  refused lvremove pve/vm2lxc-101-rtest01-scsi0
  refused lvremove -y pve
}

@test "allowlist lvm: lvcreate only makes a tagged snapshot with our name, never a plain LV or of our own object" {
  refused lvcreate -L 1G -n vm2lxc-101-rtest01-scsi0 pve
  refused lvcreate -s -n vm-101-disk-0 --addtag vm2lxc-rtest01 pve/vm-101-disk-1
  refused lvcreate -s -n vm2lxc-101-rtest01-scsi0 --addtag wrongtag pve/vm-101-disk-0
  refused lvcreate -s -n vm2lxc-101-rtest01-scsi0 pve/vm-101-disk-0
  refused lvcreate -s -n vm2lxc-101-rtest01-scsi0 --addtag vm2lxc-rtest01 pve/vm2lxc-101-rtest01-scsi1
  refused lvextend -L +1G pve/vm-101-disk-0
  refused lvconvert --merge pve/vm2lxc-101-rtest01-scsi0
  refused lvchange -an pve/vm-101-disk-0
  refused lvchange -pw pve/vm2lxc-101-rtest01-scsi0
  refused lvchange -ay -K pve/vm-101-disk-0
  refused lvs -a pve
}

@test "allowlist losetup: attach and list only our snapshot device; detach only loops we own" {
  refused losetup -r -f --show -P /dev/pve/vm-101-disk-0
  refused losetup -f --show -P /dev/pve/vm2lxc-101-rtest01-scsi0
  refused losetup -P -f /dev/pve/vm2lxc-101-rtest01-scsi0
  refused losetup -j /dev/pve/vm-101-disk-0
  refused losetup -d /dev/loop0
  refused losetup -D
  refused losetup -d /dev/sda
  OURS_LOOPS=(/dev/loop3)
  refused losetup -d /dev/loop4
}

@test "allowlist mount: read-only only, supported filesystems only, our devices only, under the run root only" {
  local ok="$VM2LXC_RUN_ROOT/$RUN/scsi0/x"
  refused mount -o rw,noload -t ext4 "$CD0-part1" "$ok"
  refused mount -o noload -t ext4 "$CD0-part1" "$ok"
  refused mount -o ro,rw -t ext4 "$CD0-part1" "$ok"
  refused mount -o ro -t ntfs "$CD0-part1" "$ok"
  refused mount -o ro -t ext4 "/dev/zvol/$Z1" "$ok"
  refused mount -o ro -t ext4 /dev/sda1 "$ok"
  refused mount -o ro -t ext4 /dev/pve/vm-101-disk-0 "$ok"
  refused mount -o ro -t ext4 /dev/loop7 "$ok"
  refused mount -o ro -t ext4 "$CD0-part1" /mnt
  refused mount -o ro -t ext4 "$CD0-part1" "$VM2LXC_RUN_ROOT/../escape"
  refused mount --bind /etc "$ok"
}

@test "allowlist mount: a loop device is acceptable only after we registered it as ours" {
  local ok="$VM2LXC_RUN_ROOT/$RUN/scsi0/x" o
  o=$(mount_opts_for ext4)
  refused mount -o "$o" -t ext4 /dev/loop5p1 "$ok"
  OURS_LOOPS=(/dev/loop5)
  run hc_mount -o "$o" -t ext4 /dev/loop5p1 "$ok"
  [ "$status" -eq 0 ]
  run hc_mount -o "$o" -t ext4 /dev/loop55p1 "$ok"
  [ "$status" -eq 77 ]
}

@test "allowlist misc: umount, mountpoint, mkdir, rmdir stay under the run root; no other tool exists" {
  refused umount -l "$VM2LXC_RUN_ROOT/$RUN/x"
  refused umount -f "$VM2LXC_RUN_ROOT/$RUN/x"
  refused umount /mnt
  refused umount /
  refused mountpoint /mnt
  refused mkdir -p /etc/evil
  refused mkdir "$VM2LXC_RUN_ROOT/$RUN"
  refused rmdir /var
  refused rm -rf "$VM2LXC_RUN_ROOT"
  refused dd if=/dev/zero of=/dev/sda
  refused mkfs.ext4 /dev/sda
  refused wipefs -a /dev/sda
  refused tar cf x y
  refused ""
}

@test "R1: a nonsense run root makes every mount, mkdir and rmdir refuse (not '/', not one level deep, no '..')" {
  local rr
  for rr in / /etc /run "/tmp/a b/x" "/tmp/../etc/x" "relative/path" ""; do
    VM2LXC_RUN_ROOT=$rr run host_cmd mkdir -p "$rr/x/y"
    [ "$status" -eq 77 ] || { echo "run root '$rr' was accepted"; return 1; }
  done
  VM2LXC_RUN_ROOT=/run/vm2lxc run hc_under_runroot /run/vm2lxc/r1/x
  [ "$status" -eq 0 ]
}

@test "the lock is never inherited by a child process (LVM warned about this on the first real run)" {
  mkdir -p "$VM2LXC_STATE_DIR"
  lock_acquire
  seed_zvol "$Z1"
  host_cmd zfs list -H -o name -t volume "$Z1" >/dev/null
  host_cmd udevadm settle --timeout=1
  [ ! -e "$FAKE_STATE/leaks.log" ] || { cat "$FAKE_STATE/leaks.log"; return 1; }
  # and the check itself works: a child started WITHOUT the guard does see the lock fd
  zfs list -H -o name -t volume "$Z1" >/dev/null
  [ -e "$FAKE_STATE/leaks.log" ]
}

@test "option injection: names with a leading '-' or '.' never reach an LVM command line" {
  refused lvcreate -s -n vm2lxc-101-rtest01-scsi0 --addtag vm2lxc-rtest01 -x/vm-101-disk-0
  refused lvcreate -s -n vm2lxc-101-rtest01-scsi0 --addtag vm2lxc-rtest01 pve/-vm-101-disk-0
  refused lvcreate -s -n vm2lxc-101-rtest01-scsi0 --addtag vm2lxc-rtest01 .hidden/vm-101-disk-0
  refused lvremove -y -x/vm2lxc-101-rtest01-scsi0
  refused lvchange -pr --version/vm2lxc-101-rtest01-scsi0
  refused lvchange -ay -K -x/vm2lxc-101-rtest01-scsi0
  refused lvs --noheadings --separator '|' -o lv_name,lv_tags,origin,lv_attr -x
  refused lvs --noheadings --separator '|' -o lv_name,lv_tags,origin,lv_attr --version
  refused losetup -j /dev/-x/vm2lxc-101-rtest01-scsi0
}

@test "a storage ID or volume name with a leading '-' is never handed to pvesm" {
  load_libs common pve
  # the fixture lookup WOULD find these names, so only the name guard can reject them
  local fx="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$fx"
  printf '%s\n' '-h:vm-100-disk-0 /dev/zvol/x/y' 'local-zfs:--help /dev/zvol/x/z' 'local-zfs:vm-100-disk-0 /dev/zvol/rpool/data/vm-100-disk-0' >"$fx/volume-paths.txt"
  export VM2LXC_FIXTURE_DIR="$fx"
  run pve_volume_path "-h:vm-100-disk-0"
  [ "$status" -ne 0 ]
  run pve_volume_path "local-zfs:--help"
  [ "$status" -ne 0 ]
  run pve_volume_path "local-zfs:vm-100-disk-0"
  [ "$status" -eq 0 ]
  [ "$output" = "/dev/zvol/rpool/data/vm-100-disk-0" ]
}

@test "a hung storage command is cut off by the per-command timeout, and the teardown still completes" {
  zfs_one
  export FAKE_SLEEP_LSBLK=30 VM2LXC_CMD_TIMEOUT=1 VM2LXC_WAIT_TRIES=1
  local t0=$SECONDS rc=0
  run_apply 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [ "$rc" -ne 0 ]
  [ $((SECONDS - t0)) -lt 15 ] # nowhere near the 30 seconds the fake would have slept
  unset FAKE_SLEEP_LSBLK
  run_teardown "$RUN"
  assert_nothing_left
  zfs_has "$Z1"
}

# --- ZFS lifecycle -----------------------------------------------------------------------------

@test "zfs: full lifecycle leaves the source untouched and everything of ours gone, in the right order" {
  zfs_one
  run_apply
  # what was created
  zfs_has "$Z1@$SNAP"
  zfs_has "$C0"
  grep -q "^vm2lxc:run=$RUN\$" "$FAKE_STATE/zfs/$(fake_enc "$Z1@$SNAP")"
  grep -q "^vm2lxc:run=$RUN\$" "$FAKE_STATE/zfs/$(fake_enc "$C0")"
  grep -q '^readonly=on$' "$FAKE_STATE/zfs/$(fake_enc "$C0")"
  grep -q "^origin=$Z1@$SNAP\$" "$FAKE_STATE/zfs/$(fake_enc "$C0")"
  # what was mounted: read-only, journal-safe options, only the ext4 partition; vfat is skipped
  [ "$(fake_mounts | wc -l)" -eq 1 ]
  [[ $(fake_mounts) == "$CD0-part1|"*"|ext4|ro,noload,nodev,nosuid,noexec" ]]
  [ "${#MOUNTS[@]}" -eq 1 ]
  [[ ${SKIPPED[0]} == *"vfat"*"not a filesystem vm2lxc mounts"* ]]
  pick_guest_root
  [[ $GUEST_ROOT == "$VM2LXC_RUN_ROOT/$RUN/scsi0/"* ]]
  [ -d "$GUEST_ROOT/etc" ]
  # teardown
  run_teardown "$RUN"
  assert_nothing_left
  zfs_has "$Z1"
  [[ -z $(runs_open) ]]
  # order: unmount, then the clone, then the snapshot
  [ "$(fake_events)" = "$(printf 'UMOUNTED %s\nDESTROYED %s\nDESTROYED %s' "$VM2LXC_RUN_ROOT/$RUN/scsi0/vm2lxc-100-rtest01-scsi0-part1" "$C0" "$Z1@$SNAP")" ]
  # the source was never destroyed and no destroy ever carried a flag
  must_fail grep -qx "DESTROYED $Z1" "$FAKE_STATE/events.log"
  if fake_calls zfs | grep -E '^zfs destroy -'; then return 1; fi
}

@test "zfs: two disks are snapshotted in ONE atomic command, and both clones are removed afterwards" {
  zfs_two
  run_apply
  [ "$(fake_calls zfs | grep -c '^zfs snapshot')" -eq 1 ]
  fake_calls zfs | grep '^zfs snapshot' | grep -q "$Z1@$SNAP $Z2@$SNAP"
  [ "$(fake_mounts | wc -l)" -eq 3 ] # scsi0: ext4 + xfs, scsi1: whole-disk ext4
  [[ $(fake_mounts) == *"|xfs|ro,norecovery,nouuid,nodev,nosuid,noexec"* ]]
  run_teardown "$RUN"
  assert_nothing_left
  zfs_has "$Z1"
  zfs_has "$Z2"
}

@test "zfs: a filesystem that cannot be opened (LUKS, LVM member, mdraid) is reported, not mounted" {
  seed_zvol "$Z1"
  plan_disks 100 "$RUN" zfspool "scsi0:/dev/zvol/$Z1:rootfs"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 crypto_LUKS" "$CD0-part2 LVM2_member" "$CD0-part3 linux_raid_member" "$CD0-part4 swap"
  journal_new 100 "$RUN"
  run_apply
  [ -z "$(fake_mounts)" ]
  [ "${#SKIPPED[@]}" -eq 4 ]
  [[ ${SKIPPED[0]} == *"guest LVM / LUKS / mdraid is not supported yet"* ]]
  [[ ${SKIPPED[3]} == *"swap"* ]]
  [[ ${MOUNT_NOTES[0]} == *"no supported filesystem was found"* ]]
  run_teardown "$RUN"
  assert_nothing_left
}

@test "zfs: btrfs mounts read-only and carries a note about subvolumes" {
  seed_zvol "$Z1"
  plan_disks 100 "$RUN" zfspool "scsi0:/dev/zvol/$Z1:rootfs"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 btrfs"
  journal_new 100 "$RUN"
  run_apply
  [[ $(fake_mounts) == *"|btrfs|ro,nodev,nosuid,noexec" ]]
  [[ ${MOUNT_NOTES[0]} == *"btrfs"*"default subvolume"* ]]
  run_teardown "$RUN"
  assert_nothing_left
}

# --- failure matrix ------------------------------------------------------------------------------

@test "failure: the snapshot command fails -> nothing exists, nothing to undo, journal closes" {
  zfs_one
  export FAKE_FAIL=zfs.snapshot:1
  rc=0
  run_apply || rc=$?
  [ "$rc" -ne 0 ]
  assert_nothing_left
  unset FAKE_FAIL
  run_teardown "$RUN"
  [[ -z $(runs_open) ]]
  zfs_has "$Z1"
}

@test "failure: crash after the snapshot, before the clone -> a later cleanup destroys the snapshot" {
  zfs_one
  PLAN=("${PLAN[@]:0:1}") # only the snapshot step ever ran
  run_apply
  zfs_has "$Z1@$SNAP"
  # a NEW process: nothing in memory, only the journal
  OURS_LOOPS=() MOUNTS=() JL_KIND=() JL_STATE=() JL_ARGS=()
  [[ $(runs_open) == "$RUN" ]]
  run_teardown "$RUN"
  assert_nothing_left
  zfs_has "$Z1"
  [[ -z $(runs_open) ]]
}

@test "failure: the clone of disk 2 fails -> disk 1's clone and the snapshot are removed, sources intact" {
  zfs_two
  export FAKE_FAIL=zfs.clone:2
  rc=0
  run_apply || rc=$?
  [ "$rc" -ne 0 ]
  zfs_has "$C0"
  must_fail zfs_has "$C1"
  unset FAKE_FAIL
  run_teardown "$RUN"
  assert_nothing_left
  zfs_has "$Z1"
  zfs_has "$Z2"
  [ "$(fake_events)" = "$(printf 'DESTROYED %s\nDESTROYED %s\nDESTROYED %s' "$C0" "$Z1@$SNAP" "$Z2@$SNAP")" ]
}

@test "failure: the device never appears -> times out, then teardown removes clone and snapshot" {
  zfs_one
  export FAKE_FAIL=lsblk:1,lsblk:2
  rc=0
  run_apply 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [ "$rc" -ne 0 ]
  grep -q "did not appear" "$BATS_TEST_TMPDIR/err"
  unset FAKE_FAIL
  run_teardown "$RUN"
  assert_nothing_left
}

@test "failure: a mount fails halfway through a disk's partitions -> the first is unmounted before anything is destroyed" {
  seed_zvol "$Z1"
  plan_disks 100 "$RUN" zfspool "scsi0:/dev/zvol/$Z1:rootfs"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 ext4" "$CD0-part2 xfs"
  journal_new 100 "$RUN"
  export FAKE_FAIL=mount:2
  rc=0
  run_apply || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(fake_mounts | wc -l)" -eq 1 ]
  unset FAKE_FAIL
  run_teardown "$RUN"
  assert_nothing_left
  [ "$(fake_events | head -1 | cut -d' ' -f1)" = UMOUNTED ]
}

@test "failure: teardown run twice -> the second is a no-op and issues no destructive call" {
  zfs_one
  run_apply
  run_teardown "$RUN"
  local before
  before=$(wc -l <"$FAKE_STATE/calls.log")
  run_teardown "$RUN"
  [ "$(wc -l <"$FAKE_STATE/calls.log")" -eq "$before" ]
  assert_nothing_left
}

@test "failure: teardown fails midway (umount) -> journal stays open, a second cleanup finishes the job" {
  zfs_one
  run_apply
  export FAKE_FAIL=umount:1
  rc=0
  run_teardown "$RUN" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
  [[ $(runs_open) == "$RUN" ]]
  zfs_has "$C0"
  [ -n "$(fake_mounts)" ]
  unset FAKE_FAIL
  run_teardown "$RUN"
  assert_nothing_left
  [[ -z $(runs_open) ]]
}

@test "rail R3: a clone with our name but a different stamp is refused (77) and left alone" {
  zfs_one
  run_apply
  sed -i "s/^vm2lxc:run=.*/vm2lxc:run=someoneelse/" "$FAKE_STATE/zfs/$(fake_enc "$C0")"
  rc=0
  run_teardown "$RUN" 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [ "$rc" -eq 77 ]
  grep -q "left alone" "$BATS_TEST_TMPDIR/err"
  zfs_has "$C0"
  [[ $(runs_open) == "$RUN" ]]
}

@test "rail R3: a clone whose origin is not the recorded snapshot is refused (77) and left alone" {
  zfs_one
  run_apply
  sed -i "s#^origin=.*#origin=rpool/data/another-zvol@snap#" "$FAKE_STATE/zfs/$(fake_enc "$C0")"
  rc=0
  run_teardown "$RUN" 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [ "$rc" -eq 77 ]
  grep -q "not the recorded snapshot" "$BATS_TEST_TMPDIR/err"
  zfs_has "$C0"
}

@test "rail R3: a snapshot with our name but a different stamp is refused and left alone" {
  zfs_one
  run_apply
  run_teardown_snapshot_only() { act_undo_zfs_snapshot "$SNAP" "$Z1"; }
  sed -i "s/^vm2lxc:run=.*/vm2lxc:run=someoneelse/" "$FAKE_STATE/zfs/$(fake_enc "$Z1@$SNAP")"
  rc=0
  run_teardown_snapshot_only 2>/dev/null || rc=$?
  [ "$rc" -eq 77 ]
  zfs_has "$Z1@$SNAP"
}

@test "rail R9: a pre-existing snapshot of the same name is never adopted, and never destroyed by teardown" {
  zfs_one
  # someone (or an old run with the same id) already made it, even with a matching stamp
  printf 'kind=snap\nvm2lxc:run=%s\n' "$RUN" >"$FAKE_STATE/zfs/$(fake_enc "$Z1@$SNAP")"
  rc=0
  run_apply 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [ "$rc" -eq 77 ]
  grep -q "will not be adopted" "$BATS_TEST_TMPDIR/err"
  must_fail zfs_has "$C0"
  run_teardown "$RUN"
  zfs_has "$Z1@$SNAP"
  must_fail grep -q "^DESTROYED" "$FAKE_STATE/events.log" 2>/dev/null
}

@test "rail R9: a pre-existing clone dataset of the same name is not adopted either" {
  zfs_one
  printf 'kind=clone\norigin=x\nvm2lxc:run=%s\n' "$RUN" >"$FAKE_STATE/zfs/$(fake_enc "$C0")"
  rc=0
  run_apply 2>/dev/null || rc=$?
  [ "$rc" -eq 77 ]
  run_teardown "$RUN"
  zfs_has "$C0"
}

@test "rail R2: teardown works from the journal only: an unrelated vm2lxc-named object is never touched" {
  zfs_one
  run_apply
  # an object that looks like ours but belongs to another run and is not in OUR journal
  printf 'kind=snap\nvm2lxc:run=otherrun\n' >"$FAKE_STATE/zfs/$(fake_enc "$Z1@vm2lxc-otherrun")"
  printf 'kind=clone\norigin=%s@vm2lxc-otherrun\nvm2lxc:run=otherrun\n' "$Z1" >"$FAKE_STATE/zfs/$(fake_enc "rpool/data/vm2lxc-100-otherrun-scsi0")"
  run_teardown "$RUN"
  zfs_has "$Z1@vm2lxc-otherrun"
  zfs_has rpool/data/vm2lxc-100-otherrun-scsi0
  must_fail zfs_has "$C0"
}

# --- LVM-thin lifecycle ----------------------------------------------------------------------------

@test "lvm: full lifecycle (snapshot, read-only, activate, loop, mount) and teardown in reverse; origins untouched" {
  lvm_two
  run_apply
  lv_has "$L0"
  lv_has "$L1"
  grep -q '^tags=vm2lxc-rtest01$' "$FAKE_STATE/lvm/pve__vm2lxc-101-rtest01-scsi0"
  grep -q '^origin=vm-101-disk-0$' "$FAKE_STATE/lvm/pve__vm2lxc-101-rtest01-scsi0"
  grep -q '^attr=Vr' "$FAKE_STATE/lvm/pve__vm2lxc-101-rtest01-scsi0" # made read-only
  grep -q '^active=1$' "$FAKE_STATE/lvm/pve__vm2lxc-101-rtest01-scsi0"
  [ "$(fake_loops)" -eq 2 ]
  [ "$(fake_mounts | wc -l)" -eq 2 ] # scsi0 p1 ext4 (p2 vfat skipped) and the whole-disk ext4 of scsi1
  # the commands, with the exact flags
  fake_calls lvcreate | grep -q "^lvcreate -s -n vm2lxc-101-rtest01-scsi0 --addtag vm2lxc-rtest01 pve/vm-101-disk-0\$"
  fake_calls lvchange | grep -q "^lvchange -pr $L0\$"
  fake_calls lvchange | grep -q "^lvchange -ay -K $L0\$"
  fake_calls losetup | grep -q "^losetup -r -f --show -P /dev/$L0\$"
  pick_guest_root
  [ -d "$GUEST_ROOT/etc" ]
  run_teardown "$RUN"
  assert_nothing_left
  lv_has pve/vm-101-disk-0
  lv_has pve/vm-101-disk-1
  # order: unmounts, then loop devices, then LVs
  local ev
  ev=$(fake_events | cut -d' ' -f1 | uniq | tr '\n' ' ')
  [[ $ev == "UMOUNTED LVREMOVED " ]]
  [ "$(fake_calls losetup | grep -c '^losetup -d')" -eq 2 ]
  must_fail grep -q "LVREMOVED pve/vm-101-disk" "$FAKE_STATE/events.log"
  if fake_calls lvremove | grep -v '^lvremove -y '; then return 1; fi
}

@test "lvm: the second lvcreate fails -> disk 1's snapshot is removed, both source LVs intact" {
  lvm_two
  export FAKE_FAIL=lvcreate:2
  rc=0
  run_apply || rc=$?
  [ "$rc" -ne 0 ]
  lv_has "$L0"
  must_fail lv_has "$L1"
  unset FAKE_FAIL
  run_teardown "$RUN"
  assert_nothing_left
  lv_has pve/vm-101-disk-0
  lv_has pve/vm-101-disk-1
}

@test "lvm: loop attach fails -> the snapshot LVs are removed" {
  lvm_two
  export FAKE_FAIL=losetup.attach:1
  rc=0
  run_apply || rc=$?
  [ "$rc" -ne 0 ]
  unset FAKE_FAIL
  run_teardown "$RUN"
  assert_nothing_left
}

@test "lvm: lvremove is briefly busy -> it is retried and teardown still completes" {
  lvm_two
  run_apply
  export FAKE_FAIL=lvremove:1
  run_teardown "$RUN"
  assert_nothing_left
  [ "$(fake_calls lvremove | wc -l)" -ge 3 ]
}

@test "lvm: lvremove keeps failing -> teardown reports it, the journal stays open, a later cleanup completes" {
  lvm_two
  run_apply
  export FAKE_FAIL=lvremove:1,lvremove:2,lvremove:3,lvremove:4,lvremove:5
  rc=0
  run_teardown "$RUN" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
  [[ $(runs_open) == "$RUN" ]]
  lv_has pve/vm-101-disk-0
  unset FAKE_FAIL
  run_teardown "$RUN"
  assert_nothing_left
}

@test "lvm: loop devices are found through 'losetup -j' on the snapshot device, not by name, so a fresh process can detach them" {
  lvm_two
  run_apply
  [ "$(fake_loops)" -eq 2 ]
  # a new process knows nothing, and the fake prints the backing as /dev/dm-0 (the real tool may too)
  OURS_LOOPS=() LOOP_DEV=() MOUNTS=()
  run_teardown "$RUN"
  assert_nothing_left
}

@test "rail R3 (lvm): an LV with our name but a different tag is refused and left alone" {
  lvm_two
  run_apply
  sed -i 's/^tags=.*/tags=something-else/' "$FAKE_STATE/lvm/pve__vm2lxc-101-rtest01-scsi0"
  rc=0
  run_teardown "$RUN" 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [ "$rc" -eq 77 ]
  grep -q "left alone" "$BATS_TEST_TMPDIR/err"
  lv_has "$L0"
}

@test "rail R3 (lvm): an LV whose origin is not the recorded one is refused and left alone" {
  lvm_two
  run_apply
  sed -i 's/^origin=.*/origin=some-other-lv/' "$FAKE_STATE/lvm/pve__vm2lxc-101-rtest01-scsi1"
  rc=0
  run_teardown "$RUN" 2>/dev/null || rc=$?
  [ "$rc" -eq 77 ]
  lv_has "$L1"
}

@test "rail R9 (lvm): a pre-existing snapshot LV of the same name is never adopted or removed" {
  lvm_two
  printf 'tags=vm2lxc-rtest01\norigin=vm-101-disk-0\nattr=Vri---tz-k\nactive=0\n' >"$FAKE_STATE/lvm/pve__vm2lxc-101-rtest01-scsi0"
  rc=0
  run_apply 2>/dev/null || rc=$?
  [ "$rc" -eq 77 ]
  run_teardown "$RUN"
  lv_has "$L0"
  must_fail grep -q "^LVREMOVED" "$FAKE_STATE/events.log" 2>/dev/null
}

@test "rail R9 (lvm): a loop device already attached to our snapshot device is not ours to detach" {
  lvm_two
  printf '/dev/%s' "$L0" >"$FAKE_STATE/loops/0" # attached by someone else before we got there
  rc=0
  run_apply 2>/dev/null || rc=$?
  [ "$rc" -eq 77 ]
  run_teardown "$RUN" 2>/dev/null || true
  [ -f "$FAKE_STATE/loops/0" ]
}

@test "lvm: the origin LV missing is a clear error, not a crash" {
  seed_lv pve vm-101-disk-1
  plan_disks 101 "$RUN" lvmthin "scsi0:/dev/pve/vm-101-disk-0:rootfs"
  journal_new 101 "$RUN"
  rc=0
  run_apply 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [ "$rc" -ne 0 ]
  grep -q "origin LV pve/vm-101-disk-0 does not exist" "$BATS_TEST_TMPDIR/err"
  run_teardown "$RUN"
  assert_nothing_left
}

# --- journal and lock ----------------------------------------------------------------------------------

@test "journal: write-ahead. A step is on disk as PENDING BEFORE its handler runs" {
  act_do_zzprobe() {
    # at this moment the journal must already say STEP ... PENDING for our own sequence number
    grep -q "^STEP"$'\t'"$LAST_SEQ"$'\t'zzprobe "$JOURNAL" || return 11
    [[ $(grep "^ST"$'\t'"$LAST_SEQ"$'\t' "$JOURNAL" | tail -1) == "ST"$'\t'"$LAST_SEQ"$'\t'"PENDING" ]] || return 12
    return 0
  }
  journal_new 100 "$RUN"
  PLAN=("zzprobe|a|b")
  run_apply
  [[ $(tail -1 "$JOURNAL") == "ST"$'\t'"1"$'\t'"DONE" ]]
}

@test "journal: a failing handler leaves the step FAILED, not DONE" {
  act_do_zzfail() { return 9; }
  journal_new 100 "$RUN"
  PLAN=("zzfail|x")
  rc=0
  run_apply || rc=$?
  [ "$rc" -eq 9 ]
  [[ $(tail -1 "$JOURNAL") == "ST"$'\t'"1"$'\t'"FAILED" ]]
}

@test "journal: the latest ST line wins, CLOSED is detected, args survive the round trip" {
  journal_new 100 "$RUN"
  journal_step zfs-snapshot "$SNAP" "$Z1"
  journal_mark 1 DONE
  journal_step mount /dev/x /run/vm2lxc/a/b ext4
  journal_mark 2 DONE
  journal_mark 2 UNDONE
  journal_load "$RUN"
  [ "$JL_N" -eq 2 ]
  [ "${JL_STATE[1]}" = DONE ]
  [ "${JL_STATE[2]}" = UNDONE ]
  [ "${JL_KIND[2]}" = mount ]
  [ "$RUN_VMID" = 100 ]
  [ "$JL_CLOSED" -eq 0 ]
  journal_close
  journal_load "$RUN"
  [ "$JL_CLOSED" -eq 1 ]
  IFS=$'\t' read -ra a <<<"${JL_ARGS[1]}"
  [ "${a[0]}" = "$SNAP" ]
  [ "${a[1]}" = "$Z1" ]
}

@test "journal: a second journal for the same run id is refused" {
  journal_new 100 "$RUN"
  run journal_new 100 "$RUN"
  [ "$status" -eq 77 ]
  [[ $output == *"already exists"* ]]
}

@test "journal: the journal directory is private (0700) and the file is 0600" {
  journal_new 100 "$RUN"
  [ "$(stat -c %a "$(state_dir)/runs/$RUN")" = 700 ]
  [ "$(stat -c %a "$JOURNAL")" = 600 ]
}

@test "journal: runs_open lists only runs that are not CLOSED" {
  journal_new 100 ra01
  journal_close
  journal_new 100 rb02
  journal_new 100 rc03
  [ "$(runs_open | sort | tr '\n' ' ')" = "rb02 rc03 " ]
}

@test "journal: a step kind this build does not know is refused and left alone, never guessed at" {
  journal_new 100 "$RUN"
  journal_step rm-everything /
  journal_mark 1 DONE
  rc=0
  run_teardown "$RUN" 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [ "$rc" -eq 77 ]
  grep -q "unknown kind" "$BATS_TEST_TMPDIR/err"
}

@test "lock: a second holder is refused while the first holds it, and succeeds after release" {
  mkdir -p "$VM2LXC_STATE_DIR"
  exec 9>"$VM2LXC_STATE_DIR/lock"
  flock -n 9
  run lock_acquire
  [ "$status" -ne 0 ]
  exec 9>&-
  run lock_acquire
  [ "$status" -eq 0 ]
}

@test "R5: the planner never produces a destroy target that equals a source" {
  seed_zvol "$Z1"
  plan_disks 100 "$RUN" zfspool "scsi0:/dev/zvol/$Z1:rootfs"
  local line
  for line in "${PLAN[@]}"; do
    case ${line%%|*} in
      zfs-clone)
        IFS='|' read -r _ snap clone _ <<<"$line"
        [ "$clone" != "$Z1" ]
        [[ $clone == */vm2lxc-* ]]
        ;;
    esac
  done
  [ "${PLAN_SOURCES[0]}" = "$Z1" ]
}

# --- findings of the independent box review (2026-11-17): F1-F10 ---------------------------------
# Each test below failed against the code as it was when the reviewer read it.

@test "F1: a journal write that fails is reported, and the action it was meant to record is NOT performed" {
  seed_zvol "$Z1"
  plan_disks 100 "$RUN" zfspool "scsi0:/dev/zvol/$Z1:rootfs"
  journal_new 100 "$RUN"
  JOURNAL=/dev/full # every write to it fails with ENOSPC
  run run_apply
  [ "$status" -ne 0 ]
  [[ $output == *"cannot be written"* ]]
  must_fail zfs_has "$Z1@$SNAP"
  must_fail grep -q '^zfs snapshot' "$FAKE_STATE/calls.log"
}

@test "F1: journal_step also reports a journal that cannot be OPENED (distinct from a failed write)" {
  journal_new 100 "$RUN"
  JOURNAL="$BATS_TEST_TMPDIR/no/such/dir/journal"
  run journal_step zfs-clone a b
  [ "$status" -eq 1 ]
  [ ! -e "$JOURNAL" ]
}

@test "F1: journal_mark and journal_close report a failed write instead of pretending" {
  journal_new 100 "$RUN"
  JOURNAL=/dev/full
  run journal_mark 1 DONE
  [ "$status" -eq 1 ]
  run journal_close
  [ "$status" -eq 1 ]
}

@test "F1: if the journal cannot be updated during teardown the run stays OPEN and the failure is reported; a repeat finishes it" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores file modes"; fi
  zfs_one
  run_apply
  chmod 444 "$JOURNAL"
  run run_teardown "$RUN"
  [ "$status" -ne 0 ]
  [[ $output == *"could not be updated"* ]]
  must_fail grep -q '^CLOSED$' "$JOURNAL"
  chmod 644 "$JOURNAL"
  run run_teardown "$RUN"
  [ "$status" -eq 0 ]
  grep -q '^CLOSED$' "$JOURNAL"
  assert_nothing_left
}

@test "F1: if even one UNDONE mark is lost the run is not closed, although journal_close itself would work" {
  zfs_one
  run_apply
  journal_mark() { # a flaky disk: every UNDONE mark fails, everything else works
    if [[ $2 == UNDONE ]]; then return 1; fi
    printf 'ST\t%d\t%s\n' "$1" "$2" >>"$JOURNAL"
  }
  run run_teardown "$RUN"
  [ "$status" -ne 0 ]
  [[ $output == *"could not be updated"* ]]
  must_fail grep -q '^CLOSED$' "$JOURNAL"
  assert_nothing_left # the objects themselves WERE removed; only the paperwork is incomplete
}

@test "F2: a failed mountpoint probe is an error, never 'not mounted'" {
  local mnt="$VM2LXC_RUN_ROOT/$RUN/scsi0/x"
  mkdir -p "$mnt"
  FAKE_FAIL=mountpoint:1:124 run act_undo_mount "$CD0-part1" "$mnt" ext4 # a timeout
  [ "$status" -eq 124 ]
  [ -d "$mnt" ]
  FAKE_FAIL=mountpoint:2:32 run act_undo_mount "$CD0-part1" "$mnt" ext4 # exists but cannot be examined
  [ "$status" -eq 32 ]
  [ -d "$mnt" ]
  rmdir "$mnt"
  run act_undo_mount "$CD0-part1" "$mnt" ext4 # gone: 32 from mountpoint is then simply "nothing there"
  [ "$status" -eq 0 ]
}

@test "F2: a failed 'losetup -j' probe stops the teardown with the loop device still attached; a repeat finishes" {
  lvm_two
  run_apply
  # apply already made two `losetup -j` calls (the 'nothing attached yet' check), so the teardown's first probe is call 3
  FAKE_FAIL=losetup.list:3:5 run run_teardown "$RUN"
  [ "$status" -ne 0 ]
  [[ $output == *"could not undo"* ]]
  [ "$(fake_loops)" -gt 0 ]
  run run_teardown "$RUN"
  [ "$status" -eq 0 ]
  assert_nothing_left
}

@test "F2: zfs_exists says 'absent' ONLY for 'does not exist'; any other zfs failure is an error" {
  seed_zvol "$Z1"
  run zfs_exists "$Z1"
  [ "$status" -eq 0 ]
  run zfs_exists rpool/data/nope
  [ "$status" -eq 1 ]
  FAKE_FAIL=zfs.list:3:1 run zfs_exists "$Z1" # exit 1 without 'does not exist' (a suspended pool does this)
  [ "$status" -eq 3 ]
  FAKE_FAIL=zfs.list:4:9 run zfs_exists "$Z1"
  [ "$status" -eq 9 ]
}

@test "F3: a zvol is mounted through the KERNEL names lsblk prints (/dev/zdN, /dev/zdNpM), and only ours" {
  dev_realpath() { if [[ $1 == "$CD0" ]]; then printf '/dev/zd16'; else printf '%s' "$1"; fi; }
  export FAKE_ZD_MAP="$C0=/dev/zd16"
  zfs_one
  fake_rootfs_suffix "p1" # the root partition is /dev/zd16p1 now
  run_apply
  [ "${#MOUNTS[@]}" -eq 1 ]
  fake_mounts | grep -q '/dev/zd16p1'
  pick_guest_root
  [[ $GUEST_ROOT == "$VM2LXC_RUN_ROOT/$RUN/scsi0/zd16p1" ]]
  local o ok="$VM2LXC_RUN_ROOT/$RUN/scsi0/x"
  o=$(mount_opts_for ext4)
  run hc_mount -o "$o" -t ext4 /dev/zd16p1 "$ok" # registered when the device became ready
  [ "$status" -eq 0 ]
  run hc_mount -o "$o" -t ext4 /dev/zd99p1 "$ok" # a zd device we did not create
  [ "$status" -eq 77 ]
  OURS_ZDS=()
  run hc_mount -o "$o" -t ext4 /dev/zd16p1 "$ok" # and not ours any more once unregistered
  [ "$status" -eq 77 ]
  run_teardown "$RUN"
  assert_nothing_left
}

@test "F3: a guest LVM volume or RAID array that udev activated is skipped and reported, and the run goes on" {
  seed_zvol "$Z1"
  plan_disks 100 "$RUN" zfspool "scsi0:/dev/zvol/$Z1:rootfs"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 ext4" "$CD0-part2 LVM2_member" "/dev/mapper/guest-root ext4 lvm" "/dev/md127 ext4 raid1"
  fake_rootfs_suffix "-part1"
  journal_new 100 "$RUN"
  run_apply
  [ "${#MOUNTS[@]}" -eq 1 ]
  printf '%s\n' "${SKIPPED[@]}" | grep -q 'guest-root.*nested lvm'
  printf '%s\n' "${SKIPPED[@]}" | grep -q 'md127.*nested raid1'
  [[ ${MOUNT_NOTES[*]} == *"activated"* ]]
  run_teardown "$RUN"
  assert_nothing_left
}

@test "F6: a crafted journal cannot run commands: sequence numbers, kinds and states are validated before use" {
  journal_new 100 "$RUN"
  local pw="$BATS_TEST_TMPDIR/PWNED"
  printf 'STEP\t1[$(touch %s)]\tzfs-clone\ta\tb\nST\tx[$(touch %s)]\tDONE\nST\t1\t$(touch %s)\nSTEP\t2\t$(touch %s)\n' \
    "$pw" "$pw" "$pw" "$pw" >>"$JOURNAL"
  run journal_load "$RUN"
  [ "$status" -eq 0 ]
  [ ! -e "$pw" ]
  [[ $output == *"ignored 4 malformed line(s)"* ]]
  # a run id that walks out of runs/ and lands on a journal that really exists and is readable
  mkdir -p "$VM2LXC_STATE_DIR/elsewhere"
  cp "$JOURNAL" "$VM2LXC_STATE_DIR/elsewhere/journal"
  run journal_load '../elsewhere'
  [ "$status" -eq 1 ]
  run journal_load 'x y'
  [ "$status" -eq 1 ]
}

@test "F7: journal_step refuses empty, tab and newline arguments and bad kinds (they would shift fields on reading)" {
  journal_new 100 "$RUN"
  run journal_step zfs-clone "" b
  [ "$status" -eq 1 ]
  run journal_step zfs-clone $'a\tb' c
  [ "$status" -eq 1 ]
  run journal_step zfs-clone $'a\nb' c
  [ "$status" -eq 1 ]
  run journal_step 'Bad Kind' a
  [ "$status" -eq 1 ]
  [ "$(grep -c '^STEP' "$JOURNAL")" -eq 0 ]
  run journal_step zfs-clone "a b" c # a space is fine
  [ "$status" -eq 0 ]
  [ "$(grep -c '^STEP' "$JOURNAL")" -eq 1 ]
}

@test "F8: mount options must be EXACTLY the read-only set for the filesystem" {
  local ok="$VM2LXC_RUN_ROOT/$RUN/scsi0/x" o
  o=$(mount_opts_for ext4)
  run hc_mount -o "$o" -t ext4 "$CD0-part1" "$ok"
  [ "$status" -eq 0 ]
  refused mount -o "$o,remount" -t ext4 "$CD0-part1" "$ok"
  refused mount -o "$o,bind" -t ext4 "$CD0-part1" "$ok"
  refused mount -o "ro,noload,nodev,nosuid" -t ext4 "$CD0-part1" "$ok"
  refused mount -o "$(mount_opts_for xfs)" -t ext4 "$CD0-part1" "$ok"
}

@test "F8: a device path with '..' or a space is not one of our devices" {
  local ok="$VM2LXC_RUN_ROOT/$RUN/scsi0/x" o
  o=$(mount_opts_for ext4)
  refused mount -o "$o" -t ext4 "/dev/zvol/../../tmp/x y/vm2lxc-1-abcd-k1" "$ok"
  refused mount -o "$o" -t ext4 "/dev/zvol/pool/../x/vm2lxc-1-abcd-k1" "$ok"
  refused mount -o "$o" -t ext4 "/dev/zvol/po ol/vm2lxc-1-abcd-k1" "$ok"
}

@test "F8: the ownership stamp is read with '-s local' (a value inherited from a parent is no proof)" {
  refused zfs get -H -o value vm2lxc:run "$C0"
  run host_cmd zfs get -H -o value -s local vm2lxc:run "$C0"
  [ "$status" -ne 77 ]
}

@test "F8: without the test switch a tool must come from a system directory, whatever PATH says" {
  VM2LXC_TEST_EXEC=0 run host_cmd zfs list -H -o name -t volume "$Z1"
  [ "$status" -eq 77 ]
  [[ $output == *"not a system directory"* ]]
  [ ! -e "$FAKE_STATE/calls.log" ]
}

@test "F8: without the test switch the run root is always /run/vm2lxc, whatever the environment says" {
  VM2LXC_TEST_EXEC=0 VM2LXC_RUN_ROOT=/var/lib/evil run run_root
  [ "$output" = /run/vm2lxc ]
  VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ROOT=/tmp/x/y run run_root
  [ "$output" = /tmp/x/y ]
}

# --- the conversion allowlist (convert/undo): every validator refuses the near-miss ------------------------------

conv_bind() { # bind the allowlist to a run, a VM and a container, as cmd_convert does
  RUN_ID=rtest01 RUN_VMID=100 CT_ID=900 CT_MAPBASE=100000
}
ST="/stage-placeholder"

@test "allowlist qm: only this run's VM, only status|start|shutdown --timeout N|set --onboot 0|1" {
  conv_bind
  refused qm status 101
  refused qm shutdown 101 --timeout 90
  refused qm stop 100
  refused qm destroy 100
  refused qm shutdown 100
  refused qm shutdown 100 --timeout 9999
  refused qm shutdown 100 --timeout 90 --forceStop 1
  refused qm set 100 --onboot 2
  refused qm set 100 --memory 1
  refused qm set 100 --delete scsi0
  refused qm start 100 --skiplock
  run hc_qm status 100
  [ "$status" -eq 0 ]
  run hc_qm shutdown 100 --timeout 90
  [ "$status" -eq 0 ]
  run hc_qm set 100 --onboot 0
  [ "$status" -eq 0 ]
}

@test "allowlist pct: only this run's container; no flags beyond the ones named; destroy needs --purge and nothing else" {
  conv_bind
  refused pct status 901
  refused pct destroy 901 --purge
  refused pct destroy 900
  refused pct destroy 900 --purge --force
  refused pct destroy 900 --force
  refused pct exec 900 -- id
  refused pct enter 900
  refused pct push 900 /etc/shadow /x
  refused pct set 900 --onboot 1
  refused pct shutdown 900 --timeout 9999
  refused pct start 900 --skiplock
  refused pct status 0900
  for sub in status config mount unmount start stop; do
    run hc_pct "$sub" 900
    [ "$status" -eq 0 ] || { echo "pct $sub 900 was refused"; return 1; }
  done
  run hc_pct destroy 900 --purge
  [ "$status" -eq 0 ]
}

@test "allowlist pct create: this run's staged archive only; every option from a fixed set with its own pattern" {
  conv_bind
  local ar="$VM2LXC_STAGE_ROOT/rtest01/rootfs.tar" good=(--hostname web --memory 1024 --cores 2 --rootfs local-lvm:10
    --net0 name=ens18,bridge=vmbr0,hwaddr=BC:24:11:AA:BB:64,type=veth,firewall=1 --unprivileged 1 --ostype unmanaged
    --onboot 0 --start 0 --arch amd64 --features nesting=1 --tags 'vm2lxc;vm2lxc-rtest01' --description 'vm2lxc:run=rtest01 converted from VM 100 (web)')
  run hc_pct create 900 "$ar" "${good[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run hc_pct create 900 "$ar" --mp0 'local-lvm:200,mp=/srv/data'
  [ "$status" -eq 0 ]
  refused pct create 900 /etc/passwd "${good[@]}"
  refused pct create 900 "$VM2LXC_STAGE_ROOT/otherrun/rootfs.tar" "${good[@]}"
  refused pct create 900 "$VM2LXC_STAGE_ROOT/rtest01/rootfs.tar.zst" "${good[@]}"
  refused pct create 900 "$VM2LXC_STAGE_ROOT/rtest01/../../etc/rootfs.tar" "${good[@]}"
  refused pct create 900 "$ar" --hostname 'a b'
  refused pct create 900 "$ar" --hostname '-x'
  refused pct create 900 "$ar" --memory 1
  refused pct create 900 "$ar" --memory abc
  refused pct create 900 "$ar" --rootfs '../x:10'
  refused pct create 900 "$ar" --rootfs 'local-lvm:10;rm -rf /'
  refused pct create 900 "$ar" --mp0 'local-lvm:10,mp=/a/../etc'
  refused pct create 900 "$ar" --mp0 'local-lvm:10,mp=relative'
  refused pct create 900 "$ar" --mp0 'local-lvm:10,mp=/x,backup=1,acl=1'
  refused pct create 900 "$ar" --net0 'name=eth0,bridge=vmbr0,hwaddr=nonsense,type=veth'
  refused pct create 900 "$ar" --net0 'name=eth0,bridge=vmbr0,hwaddr=BC:24:11:AA:BB:64,type=veth,rate=1,trunks=1'
  refused pct create 900 "$ar" --onboot 1
  refused pct create 900 "$ar" --start 1
  refused pct create 900 "$ar" --arch arm64
  refused pct create 900 "$ar" --features 'nesting=1,mount=nfs'
  refused pct create 900 "$ar" --features 'privileged=1'
  refused pct create 900 "$ar" --password hunter2
  refused pct create 900 "$ar" --ssh-public-keys /root/.ssh/authorized_keys
  refused pct create 900 "$ar" --lxc.cgroup2.devices.allow 'a'
  refused pct create 900 "$ar" --unprivileged 2
  refused pct create 900 "$ar" --ostype 'debian;id'
  refused pct create 900 "$ar" --tags 'a b'
  refused pct create 900 "$ar" --description 'x$(id)'
  refused pct create 900 "$ar" --hostname
}

@test "allowlist pct create --devN (R39): only a USB bus node or a ttyUSB/ttyACM port, no options" {
  conv_bind
  local ar="$VM2LXC_STAGE_ROOT/rtest01/rootfs.tar"
  run hc_pct create 900 "$ar" --dev0 /dev/bus/usb/001/004 --dev1 /dev/ttyUSB0 --dev2 /dev/ttyACM12 --dev15 /dev/bus/usb/010/127
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refused pct create 900 "$ar" --dev0 /dev/sda
  refused pct create 900 "$ar" --dev0 /dev/mem
  refused pct create 900 "$ar" --dev0 /dev/nvme0n1
  refused pct create 900 "$ar" --dev0 /dev/kvm
  refused pct create 900 "$ar" --dev0 /dev/dri/card0
  refused pct create 900 "$ar" --dev0 /dev/bus/usb/001/004/
  refused pct create 900 "$ar" --dev0 /dev/bus/usb/1/4
  refused pct create 900 "$ar" --dev0 /dev/bus/usb/001
  refused pct create 900 "$ar" --dev0 /dev/bus/usb/../../sda
  refused pct create 900 "$ar" --dev0 /dev/bus/usb/001/../004
  refused pct create 900 "$ar" --dev0 /dev/ttyS0
  refused pct create 900 "$ar" --dev0 /dev/tty0
  refused pct create 900 "$ar" --dev0 /dev/ttyUSB
  refused pct create 900 "$ar" --dev0 /dev/ttyUSB0/x
  refused pct create 900 "$ar" --dev0 '/dev/bus/usb/001/004,mode=0666'
  refused pct create 900 "$ar" --dev0 '/dev/bus/usb/001/004,uid=0,gid=0'
  refused pct create 900 "$ar" --dev0 'path=/dev/bus/usb/001/004'
  refused pct create 900 "$ar" --dev0 '/dev/bus/usb/001/004;id'
  refused pct create 900 "$ar" --dev0 "$(printf '/dev/bus/usb/001/004\n/dev/sda')"
  refused pct create 900 "$ar" --dev100 /dev/bus/usb/001/004
  refused pct create 900 "$ar" --device0 /dev/bus/usb/001/004
}

@test "allowlist tar: the create form reads a mounted guest into a staged tarball; the extract form writes only inside our container" {
  conv_bind
  local st="$VM2LXC_STAGE_ROOT/rtest01" rr="$VM2LXC_RUN_ROOT/rtest01/scsi0/p1" ct
  ct=$(ct_root 900)
  local c=(--numeric-owner --xattrs --acls --one-file-system -cpf "$st/rootfs.tar" -C "$rr" .)
  run hc_tar "${c[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run hc_tar --numeric-owner --xattrs --acls --exclude=./lost+found -xpf "$st/mp0.tar" -C "$ct/srv/data"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refused tar --numeric-owner --xattrs --acls -xpf "$st/mp0.tar" -C "$ct/srv/data" # without the exclude: refused
  refused tar --numeric-owner --xattrs --acls --exclude=./etc -xpf "$st/mp0.tar" -C "$ct/srv/data"
  refused tar -cpf "$st/rootfs.tar" -C "$rr" .
  refused tar --numeric-owner --xattrs --acls --one-file-system -cpf /tmp/out.tar -C "$rr" .
  refused tar --numeric-owner --xattrs --acls --one-file-system -cpf "$st/rootfs.tar" -C / .
  refused tar --numeric-owner --xattrs --acls --one-file-system -cpf "$st/rootfs.tar" -C /etc .
  refused tar --numeric-owner --xattrs --acls --one-file-system -cpf "$st/rootfs.tar" -C "$rr" . /etc/shadow
  refused tar --numeric-owner --xattrs --acls --one-file-system -cpf "$st/rootfs.tar" --to-command=id -C "$rr" .
  local X=(--numeric-owner --xattrs --acls --exclude=./lost+found)
  refused tar "${X[@]}" -xpf "$st/mp0.tar" -C /
  refused tar "${X[@]}" -xpf "$st/mp0.tar" -C /etc
  refused tar "${X[@]}" -xpf "$st/mp0.tar" -C "$ct/../../etc"
  refused tar "${X[@]}" -xpf /tmp/evil.tar -C "$ct/srv"
  refused tar "${X[@]}" -xpf "$st/mp0.tar" -C "$VM2LXC_CT_ROOT/901/rootfs/srv" # another container
  refused tar "${X[@]}" -xpf "$st/mp0.tar" --absolute-names -C "$ct/srv"
  refused tar -xpf "$st/mp0.tar" -C "$ct/srv"
}

@test "allowlist rm and rmdir: only this run's staged tarballs, never a directory or a glob; the staging dir only when empty-safe" {
  conv_bind
  local st="$VM2LXC_STAGE_ROOT/rtest01"
  run hc_under_stage "$st/rootfs.tar"
  [ "$status" -eq 0 ]
  run hc_under_stage "$st/mp3.tar"
  [ "$status" -eq 0 ]
  refused rm -f -- "$st/rootfs.tar.bak"
  refused rm -rf "$st"
  refused rm -f "$st/rootfs.tar"
  refused rm -f -- "$st"
  refused rm -f -- "$st/*.tar"
  refused rm -f -- "$st/../rootfs.tar"
  refused rm -f -- "$VM2LXC_STAGE_ROOT/other/rootfs.tar"
  refused rm -f -- /etc/passwd
  refused rm -f -- "$st/rootfs.tar" /etc/passwd
  refused rmdir /var/tmp
  refused rmdir "$VM2LXC_STAGE_ROOT/other"
}

@test "allowlist container edits: only the fstab expression, the .vm2lxc-orig backup, one touch, one /dev/null mask, all inside our rootfs" {
  conv_bind
  local ct
  ct=$(ct_root 900)
  run hc_ctedit sed -i -E "$SED_FSTAB_EXPR" "$ct/etc/fstab"
  [ "$status" -eq 0 ]
  run hc_ctedit cp -p --remove-destination "$ct/etc/fstab" "$ct/etc/fstab.vm2lxc-orig"
  [ "$status" -eq 0 ]
  run hc_ctedit sed -i -E "$SED_NETPLAN_EXPR" "$ct/etc/netplan/50-cloud-init.yaml"
  [ "$status" -eq 0 ]
  run hc_ctedit touch "$ct/etc/cloud/cloud-init.disabled"
  [ "$status" -eq 0 ]
  run hc_ctedit ln -sfn /dev/null "$ct/etc/systemd/system/serial-getty@ttyS0.service"
  [ "$status" -eq 0 ]
  refused sed -i -E 's/.*/pwned/' "$ct/etc/fstab"
  refused sed -i "$SED_FSTAB_EXPR" "$ct/etc/fstab"
  refused sed -i -E "$SED_FSTAB_EXPR" /etc/fstab
  refused sed -i -E "$SED_NETPLAN_EXPR" /etc/netplan/50-cloud-init.yaml
  refused sed -i -E "$SED_NETPLAN_EXPR" "$VM2LXC_CT_ROOT/901/rootfs/etc/netplan/x.yaml"
  refused sed -i -E "${SED_NETPLAN_EXPR};s/^/x/" "$ct/etc/netplan/50-cloud-init.yaml"
  refused sed -i -E "$SED_FSTAB_EXPR" "$ct/../../etc/fstab"
  refused sed -i -E "$SED_FSTAB_EXPR" "$VM2LXC_CT_ROOT/901/rootfs/etc/fstab"
  refused sed -n -E "$SED_FSTAB_EXPR" "$ct/etc/fstab"
  refused cp -p --remove-destination "$ct/etc/fstab" "$ct/etc/shadow"
  refused cp -p --remove-destination /etc/shadow "$ct/etc/shadow.vm2lxc-orig"
  refused cp "$ct/etc/fstab" "$ct/etc/fstab.vm2lxc-orig"
  refused touch /etc/cloud/cloud-init.disabled
  refused touch "$ct/etc/passwd" "/etc/passwd"
  refused touch -h "$ct/etc/cloud/cloud-init.disabled"
  refused ln -sfn /etc/shadow "$ct/etc/systemd/system/x.service"
  refused ln -sfn /dev/null "$ct/etc/passwd"
  refused ln -sfn /dev/null /etc/systemd/system/x.service
  refused ln -s /dev/null "$ct/etc/systemd/system/x.service"
}

@test "allowlist lxc-usernsexec: only the container's own id map, and only the edits and the extract above" {
  conv_bind
  local ct st="$VM2LXC_STAGE_ROOT/rtest01"
  ct=$(ct_root 900)
  run hc_usernsexec -m u:0:100000:65536 -m g:0:100000:65536 -- touch "$ct/etc/cloud/cloud-init.disabled"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run hc_usernsexec -m u:0:100000:65536 -m g:0:100000:65536 -- tar --numeric-owner --xattrs --acls --exclude=./lost+found -xpf "$st/mp0.tar" -C "$ct/srv"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refused lxc-usernsexec -m u:0:0:65536 -m g:0:0:65536 -- touch "$ct/etc/x" # the real root's own ids
  refused lxc-usernsexec -m u:0:100000:4294967295 -m g:0:100000:65536 -- touch "$ct/etc/x"
  refused lxc-usernsexec -m u:0:100000:65536 -m g:0:200000:65536 -- touch "$ct/etc/x"
  refused lxc-usernsexec -m u:0:100000:65536 -m g:0:100000:65536 -- sh -c id
  refused lxc-usernsexec -m u:0:100000:65536 -m g:0:100000:65536 -- chroot "$ct" /bin/sh
  refused lxc-usernsexec -m u:0:100000:65536 -m g:0:100000:65536 -- cat /etc/shadow
  refused lxc-usernsexec -m u:0:100000:65536 -m g:0:100000:65536 -- touch /etc/passwd
  refused lxc-usernsexec -m u:0:100000:65536 -m g:0:100000:65536 -- tar --numeric-owner --xattrs --acls --one-file-system -cpf "$st/rootfs.tar" -C / .
  refused lxc-usernsexec -m u:0:100000:65536 -- touch "$ct/etc/x"
  refused lxc-usernsexec -m u:0:100000:65536 -m g:0:100000:65536 touch "$ct/etc/x"
}

@test "allowlist blkid: only the filesystem id of one of our own devices" {
  conv_bind
  OURS_LOOPS=(/dev/loop3)
  run hc_blkid -s UUID -o value /dev/loop3
  [ "$status" -eq 0 ]
  refused blkid -s UUID -o value /dev/sda1
  refused blkid -s UUID -o value /dev/loop9
  refused blkid -s UUID -o value /dev/zvol/rpool/data/vm-100-disk-0
  refused blkid -s TYPE -o value /dev/loop3
  refused blkid -p /dev/loop3
  refused blkid -s UUID -o value
  refused blkid /dev/loop3
}

@test "allowlist mountpoint: a mount point inside OUR container is allowed to be tested, nothing else outside the run root" {
  conv_bind
  run hc_under_ctroot "$(ct_root 900)/srv/data"
  [ "$status" -eq 0 ]
  refused mountpoint -q /
  refused mountpoint -q /proc
  refused mountpoint -q "$(ct_root 901)/srv"
  refused mountpoint -q "$(ct_root 900)/../../etc"
}
