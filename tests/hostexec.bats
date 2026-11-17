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
  local ok="$VM2LXC_RUN_ROOT/$RUN/scsi0/x"
  refused mount -o ro,noload -t ext4 /dev/loop5p1 "$ok"
  OURS_LOOPS=(/dev/loop5)
  run hc_mount -o ro,noload -t ext4 /dev/loop5p1 "$ok"
  [ "$status" -eq 0 ]
  run hc_mount -o ro,noload -t ext4 /dev/loop55p1 "$ok"
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
  host_cmd zfs list -H -o name "$Z1" >/dev/null
  host_cmd udevadm settle --timeout=1
  [ ! -e "$FAKE_STATE/leaks.log" ] || { cat "$FAKE_STATE/leaks.log"; return 1; }
  # and the check itself works: a child started WITHOUT the guard does see the lock fd
  zfs list -H -o name "$Z1" >/dev/null
  [ -e "$FAKE_STATE/leaks.log" ]
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
  ! grep -qx "DESTROYED $Z1" "$FAKE_STATE/events.log"
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
  ! zfs_has "$C1"
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
  ! zfs_has "$C0"
  run_teardown "$RUN"
  zfs_has "$Z1@$SNAP"
  ! grep -q "^DESTROYED" "$FAKE_STATE/events.log" 2>/dev/null
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
  ! zfs_has "$C0"
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
  ! grep -q "LVREMOVED pve/vm-101-disk" "$FAKE_STATE/events.log"
  if fake_calls lvremove | grep -v '^lvremove -y '; then return 1; fi
}

@test "lvm: the second lvcreate fails -> disk 1's snapshot is removed, both source LVs intact" {
  lvm_two
  export FAKE_FAIL=lvcreate:2
  rc=0
  run_apply || rc=$?
  [ "$rc" -ne 0 ]
  lv_has "$L0"
  ! lv_has "$L1"
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
  ! grep -q "^LVREMOVED" "$FAKE_STATE/events.log" 2>/dev/null
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
