#!/usr/bin/env bats
# `vm2lxc convert` and `vm2lxc undo` end to end: fixture host for the VM's config, the stateful fake
# (tests/stubs/fakehost.sh) for storage, qm and pct. The staged archive is made by the REAL tar and the
# fake `pct create` really extracts it, so what lands in the "container" is what would be converted.

bats_require_minimum_version 1.5.0
load helpers

Z1=rpool/data/vm-100-disk-0
C0=rpool/data/vm2lxc-100-rtest01-scsi0
CD0=/dev/zvol/$C0
CT=900

setup() {
  setup_fake_host
}

go() { VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 run_fx "$@"; }

seed_vm100() {
  seed_zvol "$Z1"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 ext4" "$CD0-part2 vfat"
  fake_rootfs_suffix "-part1"
  guest_tree "$CD0-part1"
}

# a Debian-like guest, copied into the mount point when that device is mounted
guest_tree() { # <device>
  local d="$FAKE_STATE/guest/$(fake_enc "$1")"
  mkdir -p "$d/etc/network" "$d/etc/cloud" "$d/etc/systemd/system" "$d/usr/bin" "$d/bin" "$d/home/u" "$d/var/lib"
  printf 'ID=debian\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' >"$d/etc/os-release"
  printf 'UUID=aaaa-1 / ext4 defaults 0 1\nUUID=bbbb-2 /boot/efi vfat umask=0077 0 2\ntmpfs /tmp tmpfs defaults 0 0\n# a comment\n' >"$d/etc/fstab"
  printf 'auto lo\niface lo inet loopback\nauto ens18\niface ens18 inet dhcp\n' >"$d/etc/network/interfaces"
  printf 'important data\n' >"$d/home/u/data.txt"
  printf '#!/bin/sh\n' >"$d/usr/bin/prog"
  printf 'machine-id-0123\n' >"$d/etc/machine-id"
}

ct_conf() { cat "$FAKE_STATE/ct/$CT/conf"; }
ct_root_dir() { printf '%s/%s/rootfs' "$VM2LXC_CT_ROOT" "$CT"; }
journal() { cat "$VM2LXC_STATE_DIR/runs/rtest01/journal"; }

# --- plan mode: shows everything, executes nothing -----------------------------------------------------------------

@test "plan: prints the container, the steps and the promise, and calls no tool" {
  seed_vm100
  go convert 100 --ctid "$CT"
  [ "$status" -eq 0 ]
  [[ $output == *'vm2lxc convert 100  "web-green"'* ]]
  [[ $output == *"will be shut down first (stop-and-copy)"* ]]
  [[ $output == *"id 900, hostname web-green, 4096 MB RAM, 4 cores, unprivileged"* ]]
  [[ $output == *"rootfs local-zfs:32G from disk scsi0"* ]]
  [[ $output == *"the VM's exact MAC BC:24:11:AA:BB:64 on bridge vmbr0"* ]]
  [[ $output == *"Nothing was executed. Re-run with --yes"* ]]
  [ ! -e "$FAKE_STATE/calls.log" ]
}

@test "plan: an id that is already a VM is refused with the reason" {
  seed_vm100
  go convert 100 --ctid 101
  [ "$status" -eq 65 ]
  [[ $output == *"id 101 is already a VM or a container"* ]]
}

@test "plan: a RED VM is refused (exit 20) and nothing is called" {
  go convert 103 --ctid "$CT"
  [ "$status" -eq 20 ]
  [[ $output == *"cannot be converted (RED)"* ]]
  [ ! -e "$FAKE_STATE/calls.log" ]
}

# --- the happy path ---------------------------------------------------------------------------------------------------

@test "convert (zfs, one disk): the container exists, is stopped, carries the VM's identity, and everything else is gone" {
  seed_vm100
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"Container 900 created"* ]]
  [[ $output == *"Done. Container 900"* ]]
  # the container's config: hostname, size, the VM's exact MAC, unprivileged, tagged for identification
  ct_conf | grep -qx 'hostname: web-green'
  ct_conf | grep -qx 'memory: 4096'
  ct_conf | grep -qx 'cores: 4'
  ct_conf | grep -qx 'rootfs: local-zfs:32'
  ct_conf | grep -qx 'net0: name=ens18,bridge=vmbr0,hwaddr=BC:24:11:AA:BB:64,type=veth,firewall=1'
  ct_conf | grep -qx 'unprivileged: 1'
  ct_conf | grep -qx 'ostype: unmanaged'
  ct_conf | grep -qx 'onboot: 0'
  ct_conf | grep -qx 'start: 0'
  ct_conf | grep -q '^tags: vm2lxc;vm2lxc-rtest01'
  [ "$(cat "$FAKE_STATE/ct/$CT/state")" = stopped ]
  # the VM: stopped (stop-and-copy), never deleted
  [ "$(cat "$FAKE_STATE/vm/100.state")" = stopped ]
  zfs_has "$Z1"
  # nothing of the snapshot layer or the staging area is left
  assert_nothing_left
  [ ! -e "$VM2LXC_STAGE_ROOT/rtest01" ]
}

@test "convert: the container's filesystem is the guest's, with the fix-ups applied to the COPY only" {
  seed_vm100
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  local r
  r=$(ct_root_dir)
  [ "$(cat "$r/home/u/data.txt")" = "important data" ] # no silent data loss
  [ "$(cat "$r/etc/machine-id")" = machine-id-0123 ]   # identity kept (D9)
  # fstab: the lines naming the VM's disks are commented out, the rest untouched, a backup stays
  grep -q '^#vm2lxc# UUID=aaaa-1 / ext4' "$r/etc/fstab"
  grep -q '^#vm2lxc# UUID=bbbb-2 /boot/efi' "$r/etc/fstab"
  grep -q '^tmpfs /tmp tmpfs defaults 0 0$' "$r/etc/fstab"
  grep -q '^# a comment$' "$r/etc/fstab"
  grep -q '^UUID=aaaa-1 / ext4 defaults 0 1$' "$r/etc/fstab.vm2lxc-orig"
  # cloud-init disabled, the serial getty masked
  [ -e "$r/etc/cloud/cloud-init.disabled" ]
  [ "$(readlink "$r/etc/systemd/system/serial-getty@ttyS0.service")" = /dev/null ]
  # the unprivileged edits went through the user namespace
  grep -q '^USERNSEXEC u:0:100000:65536' "$FAKE_STATE/events.log"
}

@test "convert: the journal says COMMITTED (not CLOSED); the container and the VM's state are KEPT, the rest UNDONE" {
  seed_vm100
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  journal | grep -q '^COMMITTED$'
  must_fail grep -q '^CLOSED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
  journal | grep -qP "^CT\t$CT\$"
  journal_load rtest01
  local n kind
  for ((n = 1; n <= JL_N; n++)); do
    kind=${JL_KIND[$n]}
    case $kind in
      vm-stop | ct-create) [ "${JL_STATE[$n]}" = KEPT ] || { echo "step $n $kind is ${JL_STATE[$n]}"; return 1; } ;;
      *) [ "${JL_STATE[$n]}" = UNDONE ] || { echo "step $n $kind is ${JL_STATE[$n]}"; return 1; } ;;
    esac
  done
  # a committed conversion is finished work, not a crash: cleanup has nothing to do
  [[ -z $(runs_open) ]]
  go cleanup
  [[ $output == *"Nothing to clean up"* ]]
}

@test "convert --start: the container is running at the end (the cutover), the VM stays stopped" {
  seed_vm100
  go convert 100 --ctid "$CT" --yes --start
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_STATE/ct/$CT/state")" = running ]
  [ "$(cat "$FAKE_STATE/vm/100.state")" = stopped ]
  [[ $output == *"The container is RUNNING"* ]]
}

# --- two disks on LVM-thin: the data disk becomes a mount point (D6) ----------------------------------------------

LV0=/dev/pve/vm2lxc-101-rtest01-scsi0
LV1=/dev/pve/vm2lxc-101-rtest01-scsi1

seed_vm101() {
  seed_lv pve vm-101-disk-0
  seed_lv pve vm-101-disk-1
  seed_lsblk_backing "$LV0" "@LOOP@" "@LOOP@p1 ext4" "@LOOP@p2 vfat"
  seed_lsblk_backing "$LV1" "@LOOP@ ext4"
  fake_rootfs_suffix "p1"
  # the loop devices are numbered in attach order: scsi0 -> loop0, scsi1 -> loop1
  guest_tree /dev/loop0p1
  printf 'UUID=dddd-4 /srv/data ext4 defaults 0 2\n' >>"$FAKE_STATE/guest/$(fake_enc /dev/loop0p1)/etc/fstab"
  printf 'dddd-4' >"$FAKE_STATE/blkid/$(fake_enc /dev/loop1).UUID"
  local d="$FAKE_STATE/guest/$(fake_enc /dev/loop1)"
  mkdir -p "$d/db/base"
  printf 'row1\n' >"$d/db/base/table.dat"
  printf 'top\n' >"$d/README"
  mkdir -p "$d/lost+found"
  printf 'from the source filesystem\n' >"$d/lost+found/source-marker"
}

@test "convert (lvm, two disks): the data disk becomes mp0 at the path the guest's fstab gives it, with its data" {
  seed_vm101
  go convert 101 --ctid "$CT" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ct_conf | grep -qx 'rootfs: local-lvm:20'
  ct_conf | grep -qx 'mp0: local-lvm:200,mp=/srv/data'
  ct_conf | grep -qx 'net0: name=ens18,bridge=vmbr0,hwaddr=BC:24:11:AA:BB:65,type=veth,firewall=1'
  local r
  r=$(ct_root_dir)
  [ "$(cat "$r/srv/data/db/base/table.dat")" = row1 ]
  [ "$(cat "$r/srv/data/README")" = top ]
  [ "$(cat "$r/home/u/data.txt")" = "important data" ]
  # the volume's own lost+found is left alone; the source filesystem's is not extracted over it
  [ -e "$r/srv/data/lost+found/owned-by-the-volume" ]
  [ ! -e "$r/srv/data/lost+found/source-marker" ]
  # both volumes were unmounted again, nothing else is left
  assert_nothing_left
  [ -z "$(fake_mounts)" ]
  [ "$(cat "$FAKE_STATE/vm/101.state")" = stopped ]
}

@test "convert (lvm): an extra disk the guest's fstab does not name is mounted at /mnt/<disk>, and the output says so" {
  seed_vm101
  printf '' >"$FAKE_STATE/blkid/$(fake_enc /dev/loop1).UUID"  # an empty id: nothing to match
  go convert 101 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  ct_conf | grep -qx 'mp0: local-lvm:200,mp=/mnt/scsi1'
  [[ $output == *"scsi1: the guest's fstab does not name this filesystem"* ]]
  [ "$(cat "$(ct_root_dir)/mnt/scsi1/README")" = top ]
}

# --- every failure: the VM comes back, nothing is left behind ------------------------------------------------------

# after a failed convert: VM running again, no container, nothing of ours anywhere, journal closed
assert_rolled_back() {
  [ "$(cat "$FAKE_STATE/vm/${1:-100}.state" 2>/dev/null || echo running)" = running ]
  [ ! -e "$FAKE_STATE/ct/$CT/conf" ]
  assert_nothing_left
  [ ! -e "$VM2LXC_STAGE_ROOT/rtest01" ]
  [[ -z $(runs_open) ]]
  grep -q '^CLOSED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
}

@test "failure: pct create fails -> the VM is started again, nothing is left, the journal is closed" {
  seed_vm100
  FAKE_FAIL=pct.create:1 go convert 100 --ctid "$CT" --yes
  [ "$status" -ne 0 ]
  [[ $output == *"the conversion failed part-way"* ]]
  assert_rolled_back
  grep -q '^VMSTOPPED 100' "$FAKE_STATE/events.log" # it WAS stopped for the copy ...
  grep -q '^VMSTARTED 100' "$FAKE_STATE/events.log" # ... and started again
}

@test "failure: pct mount fails -> the half-built container is destroyed and the VM restarted" {
  seed_vm100
  FAKE_FAIL=pct.mount:1 go convert 100 --ctid "$CT" --yes
  [ "$status" -ne 0 ]
  assert_rolled_back
  grep -q '^CTCREATED 900' "$FAKE_STATE/events.log"
  grep -q '^CTDESTROYED 900' "$FAKE_STATE/events.log"
}

@test "failure: the VM will not shut down -> nothing was created and the VM was never touched further" {
  seed_vm100
  FAKE_FAIL=qm.shutdown:1 go convert 100 --ctid "$CT" --yes
  [ "$status" -ne 0 ]
  [ "$(cat "$FAKE_STATE/vm/100.state" 2>/dev/null || echo running)" = running ]
  [ ! -e "$FAKE_STATE/ct/$CT/conf" ]
  assert_nothing_left
  must_fail grep -q '^zfs snapshot' "$FAKE_STATE/calls.log" # not even a snapshot of a VM that is still running
}

@test "failure: a RED guest (Docker inside) is refused, nothing is kept, the VM restarted" {
  seed_vm100
  mkdir -p "$FAKE_STATE/guest/$(fake_enc "$CD0-part1")/var/lib/docker/overlay2"
  printf 'x\n' >"$FAKE_STATE/guest/$(fake_enc "$CD0-part1")/var/lib/docker/overlay2/layer"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 77 ]
  [[ $output == *"[RED] Docker/Podman/containerd found"* ]]
  [[ $output == *"the guest cannot be converted (RED"* ]]
  assert_rolled_back
  must_fail grep -q '^CTCREATED' "$FAKE_STATE/events.log"
}

@test "failure: a container with the wanted id that appeared meanwhile is NEVER adopted or destroyed (R9)" {
  seed_vm100
  mkdir -p "$FAKE_STATE/ct/$CT"
  printf 'hostname: someone-elses\ntags: precious\n' >"$FAKE_STATE/ct/$CT/conf"
  echo stopped >"$FAKE_STATE/ct/$CT/state"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -ne 0 ]
  [[ $output == *"container 900 already exists (it will not be adopted)"* ]]
  grep -qx 'hostname: someone-elses' "$FAKE_STATE/ct/$CT/conf" # still there, untouched
  must_fail grep -q '^CTDESTROYED' "$FAKE_STATE/events.log"
  must_fail grep -q '^CTCREATED' "$FAKE_STATE/events.log"
  [ "$(cat "$FAKE_STATE/vm/100.state")" = running ]
  assert_nothing_left
}

@test "failure: a second data filesystem on the boot disk is refused (no silent data loss), VM restarted" {
  seed_vm100
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 ext4" "$CD0-part2 ext4"
  guest_tree "$CD0-part2"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 77 ]
  [[ $output == *"the boot disk has another filesystem"* ]]
  [[ $output == *"Nothing was lost and nothing was changed"* ]]
  assert_rolled_back
}

@test "a second filesystem that the guest's fstab shows as /boot is fine: not copied, and the output says why" {
  seed_vm100
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 ext4" "$CD0-part2 ext4"
  printf 'cccc-3' >"$FAKE_STATE/blkid/$(fake_enc "$CD0-part2").UUID"
  printf 'UUID=cccc-3 /boot ext4 defaults 0 2\n' >>"$FAKE_STATE/guest/$(fake_enc "$CD0-part1")/etc/fstab"
  guest_tree "$CD0-part2" # a /boot partition: not copied
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"is the guest's /boot: not copied"* ]]
  [ -e "$FAKE_STATE/ct/$CT/conf" ]
}

# --- undo -----------------------------------------------------------------------------------------------------------

converted() { # a finished conversion of VM 100 into container 900 (running, as a cutover leaves it)
  seed_vm100
  go convert 100 --ctid "$CT" --yes --start
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "undo: without --yes it shows what it will do and changes nothing" {
  converted
  go undo "$CT"
  [ "$status" -eq 0 ]
  [[ $output == *"stop container 900"* ]]
  [[ $output == *"DESTROY container 900"* ]]
  [[ $output == *"start VM 100 again"* ]]
  [[ $output == *"Everything written inside the container since the conversion is LOST"* ]]
  [[ $output == *"Nothing was changed. Re-run with --yes"* ]]
  [ -e "$FAKE_STATE/ct/$CT/conf" ]
  [ "$(cat "$FAKE_STATE/vm/100.state")" = stopped ]
}

@test "undo --yes: the container is stopped and destroyed, the VM is started, the journal is closed; a second undo has nothing to do" {
  converted
  go undo "$CT" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"Undone. Container 900 is gone and VM 100 is running again."* ]]
  [ ! -e "$FAKE_STATE/ct/$CT/conf" ]
  [ "$(cat "$FAKE_STATE/vm/100.state")" = running ]
  zfs_has "$Z1"
  grep -q '^CLOSED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
  # order: the container was stopped and destroyed BEFORE the VM was started
  local order
  order=$(grep -nE '^(CTSTOPPED|CTDESTROYED|VMSTARTED) ' "$FAKE_STATE/events.log" | cut -d: -f2 | cut -d' ' -f1 | tr '\n' ' ')
  [ "$order" = "CTSTOPPED CTDESTROYED VMSTARTED " ]
  go undo "$CT"
  [ "$status" -eq 66 ]
  [[ $output == *"no open vm2lxc conversion created container 900"* ]]
}

@test "undo: a container that does NOT carry this run's tag is left alone (and the VM is not started)" {
  converted
  sed -i 's/^tags: .*/tags: someone-elses/' "$FAKE_STATE/ct/$CT/conf"
  go undo "$CT" --yes
  [ "$status" -ne 0 ]
  [[ $output == *"is not tagged vm2lxc-rtest01"* ]]
  [ -e "$FAKE_STATE/ct/$CT/conf" ]
  must_fail grep -q '^CTDESTROYED' "$FAKE_STATE/events.log"
  [ "$(cat "$FAKE_STATE/vm/100.state")" = stopped ] # nothing was started either
  must_fail grep -q '^CLOSED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
}

@test "undo (container never started): a container that does NOT carry this run's tag is not destroyed either" {
  seed_vm100
  go convert 100 --ctid "$CT" --yes # no --start: the only step that touches the container is ct-create's undo
  [ "$status" -eq 0 ]
  sed -i 's/^tags: .*/tags: someone-elses/' "$FAKE_STATE/ct/$CT/conf"
  go undo "$CT" --yes
  [ "$status" -ne 0 ]
  [[ $output == *"exists but is not tagged vm2lxc-rtest01: left alone"* ]]
  [ -e "$FAKE_STATE/ct/$CT/conf" ]
  must_fail grep -q '^CTDESTROYED' "$FAKE_STATE/events.log"
  [ "$(cat "$FAKE_STATE/vm/100.state")" = stopped ]
}

@test "undo: an unknown container id, and a container nobody converted, are errors that touch nothing" {
  go undo 777
  [ "$status" -eq 66 ]
  [ ! -e "$FAKE_STATE/calls.log" ]
  run "$VM2LXC" undo abc
  [ "$status" -eq 64 ]
}

@test "undo never starts the VM while its container is running (two live copies of one machine)" {
  converted
  load_libs hostexec
  journal_load rtest01
  CT_ID=$CT
  echo running >"$FAKE_STATE/ct/$CT/state"
  VM2LXC_TEST_EXEC=1 run act_undo_vm_stop 100 1 "$CT"
  [ "$status" -eq 77 ]
  [[ $output == *"container 900 is running: the VM 100 will not be started while it does"* ]]
  [ "$(cat "$FAKE_STATE/vm/100.state")" = stopped ]
}

# --- interruptions ---------------------------------------------------------------------------------------------------

@test "SIGTERM during the copy tears everything down and restarts the VM (exit 143)" {
  seed_vm100
  FAKE_SLEEP_LSBLK=2 VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" \
    "$VM2LXC" convert 100 --ctid "$CT" --yes >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$! i
  for i in $(seq 1 100); do
    zfs_has "$C0" && break
    sleep 0.1
  done
  zfs_has "$C0"
  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  assert_rolled_back
  grep -q '^VMSTARTED 100' "$FAKE_STATE/events.log"
}

# --- a hostile guest: symlinks that point at the HOST must never be followed ----------------------------------------

hostile_setup() { # a normal guest, plus a host-side sentinel area
  seed_vm100
  H="$BATS_TEST_TMPDIR/host"
  mkdir -p "$H"
  GT="$FAKE_STATE/guest/$(fake_enc "$CD0-part1")"
}

@test "hostile guest: /etc/fstab as an absolute symlink to a HOST file does not edit that host file" {
  hostile_setup
  printf 'UUID=host-1 / ext4 defaults 0 1\n' >"$H/fstab"
  rm "$GT/etc/fstab"
  ln -s "$H/fstab" "$GT/etc/fstab"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$H/fstab")" = 'UUID=host-1 / ext4 defaults 0 1' ] # untouched: no '#vm2lxc#' prefix
  [ ! -e "$H/fstab.vm2lxc-orig" ]                              # no backup written next to it either
  [ "$(ls "$H" | wc -l)" -eq 1 ]
  # and the host file's CONTENT must not have been read into the container either (a guest-controlled
  # symlink must not turn the tool into a way to copy host files into the guest)
  must_fail grep -rq 'UUID=host-1' "$(ct_root_dir)"
  [ ! -e "$(ct_root_dir)/etc/fstab.vm2lxc-orig" ]
}

@test "hostile guest: /etc/cloud/cloud-init.disabled as a symlink to a HOST path never creates or touches it (the conversion stops, fail-safe)" {
  hostile_setup
  ln -s "$H/created-by-attack" "$GT/etc/cloud/cloud-init.disabled"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -ne 0 ]
  [[ $output == *"could not create /etc/cloud/cloud-init.disabled in the container"* ]]
  [ ! -e "$H/created-by-attack" ]
  [ "$(ls "$H" | wc -l)" -eq 0 ]
  assert_rolled_back
}

@test "hostile guest: a serial-getty unit that is a symlink to a HOST file is replaced, never written through" {
  hostile_setup
  printf 'precious host file\n' >"$H/victim"
  ln -s "$H/victim" "$GT/etc/systemd/system/serial-getty@ttyS0.service"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$H/victim")" = 'precious host file' ]
  [ "$(readlink "$(ct_root_dir)/etc/systemd/system/serial-getty@ttyS0.service")" = /dev/null ]
}

@test "hostile guest: /etc as an absolute symlink to the host's /etc is not a guest root at all (refused, nothing changed)" {
  seed_vm100
  fake_rootfs_suffix "-nomatch" # the fake must not create etc/usr itself
  local d="$FAKE_STATE/guest/$(fake_enc "$CD0-part1")"
  mv "$d/etc" "$d/etc.moved" # the guest_tree helper made a real etc: replace it with a link to the host's
  ln -s /etc "$d/etc"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 77 ]
  [[ $output == *"no Linux root filesystem"* ]]
  assert_rolled_back
}

@test "hostile guest: a guest path with '..' components in its fstab mount point is not used for an extra disk" {
  seed_vm101
  printf 'UUID=dddd-4 /../../etc ext4 defaults 0 2\n' >"$FAKE_STATE/guest/$(fake_enc /dev/loop0p1)/etc/fstab"
  go convert 101 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  ct_conf | grep -qx 'mp0: local-lvm:200,mp=/mnt/scsi1' # fell back: '..' was refused
}

# --- a crash in the middle -------------------------------------------------------------------------------------------

@test "SIGKILL after the container was created: cleanup finds the run, destroys the container, restarts the VM" {
  seed_vm100
  FAKE_SLEEP_PCT_MOUNT=3 VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" \
    "$VM2LXC" convert 100 --ctid "$CT" --yes >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$! i
  for i in $(seq 1 100); do
    grep -q '^CTCREATED' "$FAKE_STATE/events.log" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '^CTCREATED 900' "$FAKE_STATE/events.log"
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null || true
  pkill -x -P 1 sleep 2>/dev/null || true
  # the leftovers: a container, a stopped VM, a snapshot, an open journal
  [ -e "$FAKE_STATE/ct/$CT/conf" ]
  [ "$(cat "$FAKE_STATE/vm/100.state")" = stopped ]
  [[ -n $(runs_open) ]]
  go cleanup
  [ "$status" -eq 0 ]
  [[ $output == *"run rtest01 (VM 100)"* ]]
  [[ $output == *"ct-create"* ]]
  [ -e "$FAKE_STATE/ct/$CT/conf" ] # listing changes nothing
  go cleanup --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_rolled_back
  grep -q '^CTDESTROYED 900' "$FAKE_STATE/events.log"
  grep -q '^VMSTARTED 100' "$FAKE_STATE/events.log"
}

# --- reading the guest: units ------------------------------------------------------------------------------------------

@test "conv_hostname: an RFC 1123 label from any VM name" {
  [ "$(conv_hostname web-green 100)" = web-green ]
  [ "$(conv_hostname 'My VM_01' 100)" = my-vm-01 ]
  [ "$(conv_hostname '-lead-trail-' 100)" = lead-trail ]
  [ "$(conv_hostname '***' 123)" = ct123 ]
  [ "$(conv_hostname '' 124)" = ct124 ]
  local long
  long=$(conv_hostname "$(printf 'a%.0s' $(seq 1 100))" 1)
  [ "${#long}" -le 63 ]
  [[ $long =~ $RE_CT_NAME ]]
}

@test "conv_guest_ifnames: ifupdown, netplan, networkd and alpine name the interface the guest's config uses" {
  local g="$BATS_TEST_TMPDIR/ifg"
  mkdir -p "$g/etc/network" "$g/etc/netplan" "$g/etc/systemd/network"
  printf 'auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet dhcp\n' >"$g/etc/network/interfaces"
  [ "$(conv_guest_ifnames "$g")" = eth0 ]
  printf 'network:\n  version: 2\n  ethernets:\n    ens18:\n      dhcp4: true\n' >"$g/etc/netplan/50.yaml"
  [ "$(conv_guest_ifnames "$g" | tr '\n' ' ')" = "eth0 ens18 " ]
  printf '[Match]\nName=enp6s18\n[Network]\nDHCP=yes\n' >"$g/etc/systemd/network/10.network"
  [[ $(conv_guest_ifnames "$g" | tr '\n' ' ') == *enp6s18* ]]
  local e="$BATS_TEST_TMPDIR/ifg-empty"
  mkdir -p "$e"
  [ -z "$(conv_guest_ifnames "$e")" ]
  printf 'network:\n  ethernets:\n    id0:\n      match: {macaddress: "aa:bb:cc:dd:ee:ff"}\n      set-name: ens19\n' >"$g/etc/netplan/60.yaml"
  [[ $(conv_guest_ifnames "$g" | tr '\n' ' ') == *ens19* ]]
}

@test "conv_fstab_mountpoint: UUID, LABEL and by-uuid match; '/', '..' and unrelated ids do not" {
  local g="$BATS_TEST_TMPDIR/fsg"
  mkdir -p "$g/etc"
  printf 'UUID=u-1 /data ext4 defaults 0 2\nLABEL=lbl /srv/x ext4 defaults 0 2\n/dev/disk/by-uuid/u-3 /mnt/three ext4 defaults 0 2\nUUID=u-4 / ext4 defaults 0 1\nUUID=u-5 /a/../b ext4 defaults 0 2\n# UUID=u-6 /commented ext4 defaults 0 2\n' >"$g/etc/fstab"
  [ "$(conv_fstab_mountpoint "$g" u-1 "")" = /data ]
  [ "$(conv_fstab_mountpoint "$g" "" lbl)" = /srv/x ]
  [ "$(conv_fstab_mountpoint "$g" u-3 "")" = /mnt/three ]
  must_fail conv_fstab_mountpoint "$g" u-4 ""   # the root filesystem is not an extra disk's mount point
  must_fail conv_fstab_mountpoint "$g" u-5 ""   # '..'
  must_fail conv_fstab_mountpoint "$g" u-6 ""   # commented out
  must_fail conv_fstab_mountpoint "$g" nope ""
  must_fail conv_fstab_mountpoint "$g" "" ""
}

@test "failure: an extra volume that is NOT a mount point is never written into (it would silently fill the root filesystem)" {
  seed_vm101
  FAKE_NO_MP_MOUNT=1 go convert 101 --ctid "$CT" --yes
  [ "$status" -ne 0 ]
  [[ $output == *"is not a mount point (the extra volume is not mounted there): refusing to write into the root filesystem"* ]]
  [ ! -e "$VM2LXC_CT_ROOT/$CT/rootfs/srv/data/README" ]
  assert_rolled_back 101
}

# --- netplan written by cloud-init matches the NIC by MAC; a veth has no permanent MAC (found on a real host) ------------

netplan_guest() { # <netplan yaml text>: replace the guest's ifupdown config with this netplan file
  local d="$FAKE_STATE/guest/$(fake_enc "$CD0-part1")"
  mv "$d/etc/network" "$d/etc/network.moved"
  mkdir -p "$d/etc/netplan"
  printf '%s' "$1" >"$d/etc/netplan/50-cloud-init.yaml"
}

CLOUDINIT_NETPLAN=$'# generated by cloud-init\nnetwork:\n    version: 2\n    ethernets:\n        eth0:\n            dhcp4: true\n            match:\n                macaddress: bc:24:11:ce:87:a6\n            set-name: eth0\n'

@test "convert: cloud-init's netplan (match: macaddress + set-name) is changed to match by name; the original is kept" {
  seed_vm100
  netplan_guest "$CLOUDINIT_NETPLAN"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local r y
  r=$(ct_root_dir)
  y="$r/etc/netplan/50-cloud-init.yaml"
  must_fail grep -q 'match:' "$y"
  must_fail grep -q 'macaddress' "$y"
  must_fail grep -q 'set-name' "$y"
  grep -qx '        eth0:' "$y"
  grep -qx '            dhcp4: true' "$y"
  grep -q '^# generated by cloud-init$' "$y"
  grep -q 'macaddress: bc:24:11:ce:87:a6' "$y.vm2lxc-orig" # the original, untouched
  [[ $output == *"the guest's netplan matches the NIC by MAC address"* ]]
  ct_conf | grep -qx 'net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:AA:BB:64,type=veth,firewall=1'
}

@test "convert: a netplan file with no MAC match is left byte for byte as it was" {
  seed_vm100
  local plain=$'network:\n    version: 2\n    ethernets:\n        ens18:\n            dhcp4: true\n            addresses: [10.0.0.5/24]\n'
  netplan_guest "$plain"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$(ct_root_dir)/etc/netplan/50-cloud-init.yaml")" = "${plain%$'\n'}" ]
  [[ $output != *"matches the NIC by MAC"* ]]
}

@test "convert: a match on something other than a MAC is not touched (only the cloud-init shape is rewritten)" {
  seed_vm100
  local named=$'network:\n    ethernets:\n        id0:\n            match:\n                name: ens*\n            dhcp4: true\n'
  netplan_guest "$named"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  grep -q 'name: ens\*' "$(ct_root_dir)/etc/netplan/50-cloud-init.yaml"
  grep -qx '            match:' "$(ct_root_dir)/etc/netplan/50-cloud-init.yaml"
}

@test "hostile guest: a netplan file that is a symlink to a HOST file is neither edited nor copied into the container" {
  hostile_setup
  netplan_guest "$CLOUDINIT_NETPLAN"
  printf 'network:\n  host-secret: yes\n  match:\n    macaddress: aa:bb:cc:dd:ee:ff\n' >"$H/host.yaml"
  local before
  before=$(cat "$H/host.yaml")
  mv "$GT/etc/netplan/50-cloud-init.yaml" "$GT/etc/netplan/50-real.yaml.moved"
  ln -s "$H/host.yaml" "$GT/etc/netplan/60-evil.yaml"
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$H/host.yaml")" = "$before" ]
  [ ! -e "$H/host.yaml.vm2lxc-orig" ]
  must_fail grep -rq 'host-secret' "$(ct_root_dir)"
}

@test "convert: the kernel mounts and the serial getty that a container cannot have are masked" {
  seed_vm100
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  local u
  for u in serial-getty@ttyS0.service sys-kernel-config.mount sys-kernel-debug.mount sys-kernel-tracing.mount; do
    [ "$(readlink "$(ct_root_dir)/etc/systemd/system/$u")" = /dev/null ] || { echo "$u is not masked"; return 1; }
  done
}

@test "conv_netplan_mac_match: finds a macaddress match, ignores plain netplan and a guest without netplan" {
  local g="$BATS_TEST_TMPDIR/npg"
  mkdir -p "$g/etc/netplan"
  must_fail conv_netplan_mac_match "$g"
  printf 'network:\n  ethernets:\n    eth0:\n      dhcp4: true\n' >"$g/etc/netplan/a.yaml"
  must_fail conv_netplan_mac_match "$g"
  printf '%s' "$CLOUDINIT_NETPLAN" >"$g/etc/netplan/b.yaml"
  conv_netplan_mac_match "$g"
  must_fail conv_netplan_mac_match "$BATS_TEST_TMPDIR/no-such-guest"
}

# --- a VM that was already stopped: undo must not start it ---------------------------------------------------------------

@test "undo: a VM that was STOPPED before the conversion is left stopped, and the output says so" {
  seed_vm100
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  jq '(.[] | select(.vmid == 100) | .status) = "stopped"' "$fx/qemu-list.json" >"$fx/q.json" && mv "$fx/q.json" "$fx/qemu-list.json"
  echo stopped >"$FAKE_STATE/vm/100.state"
  VM2LXC_FIXTURE_DIR="$fx" VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 run "$VM2LXC" convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output != *"will be shut down first"* ]]
  must_fail grep -q '^VMSTOPPED' "$FAKE_STATE/events.log" # nothing to stop
  VM2LXC_FIXTURE_DIR="$fx" VM2LXC_TEST_EXEC=1 run "$VM2LXC" undo "$CT"
  [[ $output == *"leave VM 100 stopped (it was already stopped before the conversion)"* ]]
  VM2LXC_FIXTURE_DIR="$fx" VM2LXC_TEST_EXEC=1 run "$VM2LXC" undo "$CT" --yes
  [ "$status" -eq 0 ]
  [[ $output == *"Container 900 is gone. VM 100 is as it was before the conversion (it was stopped)."* ]]
  must_fail grep -q '^VMSTARTED' "$FAKE_STATE/events.log"
  [ "$(cat "$FAKE_STATE/vm/100.state")" = stopped ]
  [ ! -e "$FAKE_STATE/ct/$CT/conf" ]
}
