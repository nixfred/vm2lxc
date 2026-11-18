#!/usr/bin/env bats
# `vm2lxc menu` end to end: the fixture host for the VMs' configs, the stateful fake host for storage, qm and pct,
# and a SCRIPTED whiptail (tests/stubs/whiptail.sh) that answers each dialog from a script and logs what it was
# shown. Every whiptail flow ends by checking that the script was consumed exactly: a menu that took a different
# path than the test planned fails loudly. The plain-prompt backend is driven through stdin, unattended runs through
# an answers file.

bats_require_minimum_version 1.5.0
load helpers

Z1=rpool/data/vm-100-disk-0
C0=rpool/data/vm2lxc-100-rtest01-scsi0
CD0=/dev/zvol/$C0
CT=900 # a container id given explicitly; the menu's own default is the fixture's next free id, 9100

setup() {
  setup_fake_host
  ln -s "$REPO_ROOT/tests/stubs/whiptail.sh" "$BATS_TEST_TMPDIR/fakebin/whiptail"
  export WT_LOG=$BATS_TEST_TMPDIR/wt.log WT_SCRIPT=$BATS_TEST_TMPDIR/wt.script
  export TMPDIR=$BATS_TEST_TMPDIR VM2LXC_UI_TTY=1
  : >"$WT_LOG"
}

go() { VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 run_fx "$@"; }

seed_vm100() {
  seed_zvol "$Z1"
  seed_lsblk_dev "$CD0" "$CD0" "$CD0-part1 ext4" "$CD0-part2 vfat"
  fake_rootfs_suffix "-part1"
  local d="$FAKE_STATE/guest/$(fake_enc "$CD0-part1")"
  mkdir -p "$d/etc/network" "$d/etc/cloud" "$d/etc/systemd/system" "$d/usr/bin" "$d/bin" "$d/home/u" "$d/var/lib"
  printf 'ID=debian\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' >"$d/etc/os-release"
  printf 'UUID=aaaa-1 / ext4 defaults 0 1\nUUID=bbbb-2 /boot/efi vfat umask=0077 0 2\n' >"$d/etc/fstab"
  printf 'auto lo\niface lo inet loopback\nauto ens18\niface ens18 inet dhcp\n' >"$d/etc/network/interfaces"
  printf 'important data\n' >"$d/home/u/data.txt"
  printf '#!/bin/sh\n' >"$d/usr/bin/prog"
  printf 'machine-id-0123\n' >"$d/etc/machine-id"
}

# wt_script <answer>...: what the scripted whiptail will answer, one per question dialog, in order
wt_script() {
  printf '%s\n' "$@" >"$WT_SCRIPT"
  rm -f "$WT_SCRIPT.pos"
}

# every scripted answer was used, none was missing, nothing was left over
assert_walked() {
  [ "$(cat "$WT_SCRIPT.pos")" -eq "$(wc -l <"$WT_SCRIPT")" ] || { echo "script used: $(cat "$WT_SCRIPT.pos") of $(wc -l <"$WT_SCRIPT")"; cat "$WT_LOG"; return 1; }
  must_fail grep -q EXHAUSTED "$WT_LOG"
}

# the N-th menu whiptail drew whose title contains <text>
menu_n() { # <n> <text>
  grep -F "$2" "$WT_LOG" | grep -F -e '--menu' | sed -n "${1}p"
}

# the same line with the shell quoting's backslash-spaces turned back into spaces, for matching plain words
menu_plain_n() { # <n> <text>
  menu_n "$@" | sed 's/\\ / /g'
}

# nothing was executed on the host, nothing was journalled, and the menu's scratch directory is gone
assert_nothing_ran() {
  [ ! -e "$FAKE_STATE/calls.log" ] || { echo "a host tool was called:"; cat "$FAKE_STATE/calls.log"; return 1; }
  [ ! -e "$VM2LXC_STATE_DIR/runs" ] || { echo "a journal exists"; return 1; }
  must_fail compgen -G "$TMPDIR/vm2lxc-menu.*"
}

ct_conf() { cat "$FAKE_STATE/ct/${1:-$CT}/conf"; }

# --- the entry points ---------------------------------------------------------------------------------------------

@test "a bare 'vm2lxc' with no terminal is still a usage error (64); 'vm2lxc menu' with no terminal is refused (64) and changes nothing" {
  VM2LXC_UI_TTY=0 run --separate-stderr "$VM2LXC"
  [ "$status" -eq 64 ]
  [[ $stderr == *"Usage: vm2lxc"* ]]
  VM2LXC_UI_TTY=0 go menu
  [ "$status" -eq 64 ]
  [[ $output == *"needs a terminal"* ]]
  assert_nothing_ran
}

@test "a bare 'vm2lxc' at a terminal opens the menu" {
  wt_script esc
  VM2LXC_FIXTURE_DIR=$FIXTURES/pve8 run "$VM2LXC"
  [ "$status" -eq 0 ]
  grep -qF -e '--menu' "$WT_LOG"
  assert_walked
}

@test "--answers belongs to the menu alone: on any other command it is a usage error, never silently ignored (R33)" {
  f=$BATS_TEST_TMPDIR/a
  printf 'action=scan\n' >"$f"
  chmod 600 "$f"
  run_fx scan --answers "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"--answers only works with 'vm2lxc menu'"* ]]
  run_fx convert 100 --answers "$f"
  [ "$status" -eq 64 ]
}

@test "'vm2lxc menu' with extra arguments is a usage error (64)" {
  go menu scan
  [ "$status" -eq 64 ]
  [[ $output == *"usage: vm2lxc menu"* ]]
}

@test "--help documents the menu, --answers and --no-tui" {
  run "$VM2LXC" --help
  [[ $output == *"menu"* && $output == *"--answers FILE"* && $output == *"--no-tui"* ]]
  [[ $output != *"unused so far"* ]]
}

# --- whiptail: leaving never runs anything (R31) --------------------------------------------------------------------

@test "whiptail: Esc at the main menu quits; the highlighted default is Scan; nothing ran" {
  wt_script esc
  go menu
  [ "$status" -eq 0 ]
  menu_n 1 'What\ do\ you\ want' | grep -qF -e '--default-item scan'
  assert_walked
  assert_nothing_ran
}

@test "whiptail: Quit in the main menu, and Cancel there, both end the menu with nothing run" {
  wt_script 'ok quit'
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  assert_nothing_ran
  wt_script cancel
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  assert_nothing_ran
}

@test "whiptail: Esc, Back and Quit on the convert screen never run it" {
  # Esc on the hub goes back to the VM list, Esc there to the main menu, Esc there quits
  wt_script 'ok convert' 'ok 100' esc esc esc
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  assert_nothing_ran
  # Back, then Back out of the VM list, then Quit
  wt_script 'ok convert' 'ok 100' 'ok back' cancel 'ok quit'
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  assert_nothing_ran
  # Quit right on the hub leaves the whole menu
  wt_script 'ok convert' 'ok 100' 'ok quit'
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  assert_nothing_ran
}

@test "whiptail: Continue on a RED VM is refused by its own plan: the reason is shown and nothing ran" {
  wt_script 'ok convert' 'ok 103' 'ok continue' 'ok quit'
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  assert_nothing_ran
  grep -F 'textbox' "$WT_LOG" | grep -qF 'Cannot\ continue\ \(exit\ 20\)'
}

# --- whiptail: the convert review hub -----------------------------------------------------------------------------

@test "whiptail hub: the first Enter is the PLAN; Continue becomes the default only after the plan was viewed; the exact command is shown" {
  wt_script 'ok convert' 'ok 100' 'ok plan' 'ok back' esc esc
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  menu_n 1 'Convert\ which' >/dev/null 2>&1 || true
  # the VM list highlights the best candidate: the top-ranked green VM
  grep -F 'Convert:\ which\ VM' "$WT_LOG" | grep -qF -e '--default-item 101'
  menu_n 1 'Convert\ VM\ 100' | grep -qF -e '--default-item plan'
  menu_n 2 'Convert\ VM\ 100' | grep -qF -e '--default-item continue'
  # the command Continue would run, spelled out, and what the VM will go through
  menu_plain_n 1 'Convert\ VM\ 100' | grep -qF -- 'vm2lxc convert 100 --ctid 9100 --hostname web-green --memory 4096 --cores 4 --yes'
  menu_plain_n 1 'Convert\ VM\ 100' | grep -qF -- 'stopping the VM first'
  # the plan was shown by the engine's own plan run, and nothing was executed
  grep -qF 'textbox' "$WT_LOG"
  assert_nothing_ran
}

@test "whiptail hub: every setting is on the one screen" {
  wt_script 'ok convert' 'ok 100' esc esc esc
  go menu
  assert_walked
  local m
  m=$(menu_n 1 'Convert\ VM\ 100')
  for word in 'Container\ id' Hostname 'RAM\ \(MB\)' Cores 'Privileged\ container' 'Start\ it\ after\ creating' Continue 'Show\ the\ full\ plan' 'Back\ to\ the\ VM\ list' 'Quit\ \(nothing\ is\ run\)'; do
    grep -qF -- "$word" <<<"$m" || { echo "missing on the hub: $word"; return 1; }
  done
}

@test "whiptail hub: Continue runs the conversion; the gauge climbs to 100 through the stages; the container exists and is stopped" {
  seed_vm100
  export FAKE_SLEEP_LSBLK=0.4 # slow the run a little so the gauge shows more than one frame
  wt_script 'ok convert' 'ok 100' 'ok plan' 'ok continue' 'ok quit'
  go menu
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_walked
  # the real conversion happened, through the same binary
  ct_conf 9100 | grep -qx 'hostname: web-green'
  [ "$(cat "$FAKE_STATE/ct/9100/state")" = stopped ]
  [ "$(cat "$FAKE_STATE/vm/100.state")" = stopped ]
  grep -q '^COMMITTED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
  assert_nothing_left
  # the progress bar: frames that never go down, start low, and end at exactly 100
  local pcts
  pcts=$(awk -F'\t' '$1 == "gauge" && NF == 3 { print $2 }' "$WT_LOG" | tr '\n' ' ')
  [ "$(wc -w <<<"$pcts")" -ge 2 ] || { echo "frames: $pcts"; return 1; }
  [ "$(awk '{ for (i = 2; i <= NF; i++) if ($i < $(i-1)) bad = 1; print bad + 0 }' <<<"$pcts")" -eq 0 ] || { echo "the bar went backwards: $pcts"; return 1; }
  [ "$(awk '{ print $NF }' <<<"$pcts")" -eq 100 ]
  [ "$(awk '{ print $1 }' <<<"$pcts")" -lt 100 ]
  awk -F'\t' '$1 == "gauge" && NF == 3 { print $3 }' "$WT_LOG" | grep -q 'of [0-9]*)'
  # the result screen says it worked, and tells a person what to do next (Fred, 2026-11-18: "Where is the success screen?")
  grep -F 'textbox' "$WT_LOG" | grep -qF 'SUCCESS'
  grep -qF 'SUCCESS: VM 100 was converted into container 9100.' "$WT_LOG.text"
  grep -qF 'The container is STOPPED.' "$WT_LOG.text"
  grep -qF 'WHAT TO DO NEXT' "$WT_LOG.text"
  grep -qF 'pct config 9100' "$WT_LOG.text"
  grep -qF 'pct start 9100' "$WT_LOG.text"
  grep -qF 'main menu > Undo > container 9100' "$WT_LOG.text"
  grep -qF 'Never run VM 100 and container 9100 at the same time' "$WT_LOG.text"
  # the summary comes FIRST, before the plan and the log (the old screen showed the plan and hid the result below it)
  awk '/SUCCESS: VM 100/ { a = NR } /^FULL LOG OF THIS RUN/ { b = NR } END { exit !(a && b && a < b) }' "$WT_LOG.text"
}

@test "whiptail hub: an edit makes the viewed plan stale again; a bad container id is refused and asked again; a good one is used" {
  seed_vm100
  # view the plan (Continue becomes the default), then edit the id: first '5' (invalid), then '901'. The edit
  # makes the plan stale, so the default falls back to Plan; Continue then runs it with the new id.
  # '5' is not a valid id, '101' is a VM that exists: both are refused, then '901' is used
  wt_script 'ok convert' 'ok 100' 'ok plan' 'ok ctid' 'ok 5' 'ok 101' 'ok 901' 'ok continue' 'ok quit'
  go menu
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_walked
  grep -F 'msgbox' "$WT_LOG" | grep -qF 'not\ valid\ or\ is\ already\ used'
  [ "$(grep -c '^msgbox' "$WT_LOG")" -eq 2 ] # one refusal per bad id
  menu_n 2 'Convert\ VM\ 100' | grep -qF -e '--default-item continue'
  menu_n 3 'Convert\ VM\ 100' | grep -qF -e '--default-item plan'
  menu_plan_n=$(menu_plain_n 3 'Convert\ VM\ 100')
  [[ $menu_plan_n == *"--ctid 901"* ]]
  ct_conf 901 | grep -qx 'hostname: web-green'
  [ ! -e "$FAKE_STATE/ct/9100/conf" ]
}

@test "whiptail hub: Cancel in an input box leaves the setting alone" {
  wt_script 'ok convert' 'ok 100' 'ok hostname' cancel esc esc esc
  go menu
  assert_walked
  menu_plain_n 2 'Convert\ VM\ 100' | grep -qF -- '--hostname web-green'
  assert_nothing_ran
}

@test "whiptail hub: a hostname, RAM and cores that are not valid are refused, valid ones reach the command" {
  wt_script 'ok convert' 'ok 100' 'ok hostname' 'ok Bad_Name' 'ok newname' 'ok memory' 'ok 5' 'ok 2048' 'ok cores' 'ok x' 'ok 2' esc esc esc
  go menu
  assert_walked
  menu_plain_n 4 'Convert\ VM\ 100' | grep -qF -- '--hostname newname --memory 2048 --cores 2'
  assert_nothing_ran
}

@test "whiptail hub: Privileged asks first; No leaves it off, Yes puts --privileged on the command; Start toggles --start" {
  wt_script 'ok convert' 'ok 100' 'ok privileged' no 'ok privileged' yes 'ok start' 'ok privileged' esc esc esc
  go menu
  assert_walked
  menu_plain_n 2 'Convert\ VM\ 100' | grep -qF -- 'convert 100'
  [[ $(menu_plain_n 2 'Convert\ VM\ 100') != *--privileged* ]]
  menu_plain_n 3 'Convert\ VM\ 100' | grep -qF -- '--privileged --yes'
  menu_plain_n 4 'Convert\ VM\ 100' | grep -qF -- '--privileged --start --yes'
  # turning it off again needs no question and drops the flag; --start stays
  [[ $(menu_plain_n 5 'Convert\ VM\ 100') != *--privileged* ]]
  menu_plain_n 5 'Convert\ VM\ 100' | grep -qF -- '--start --yes'
  grep -F 'yesno' "$WT_LOG" | grep -qF 'NOT\ isolated'
  assert_nothing_ran
}

# --- whiptail: the other actions ----------------------------------------------------------------------------------

@test "whiptail: Scan asks whether to look inside; 'Config only' shows the engine's ranked table and runs nothing on the host" {
  wt_script 'ok scan' 'ok config' 'ok quit'
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  grep -qF 'textbox' "$WT_LOG"
  grep -qF '12 VMs' "$WT_LOG.text"
  grep -qF 'you asked for --no-inspect' "$WT_LOG.text"
  assert_nothing_ran
}

@test "whiptail: Scan > Look inside runs the real engine with a progress bar that counts VMs, and shows what it found" {
  seed_vm100
  local fx="$BATS_TEST_TMPDIR/scanfx"
  cp -r "$FIXTURES/pve8" "$fx" # only VM 100 (seeded) and 103 (RED, never looked at): the others have no fake disks
  jq '[.[] | select(.vmid == 100 or .vmid == 103)]' "$fx/qemu-list.json" >"$fx/q.json" && mv "$fx/q.json" "$fx/qemu-list.json"
  wt_script 'ok scan' 'ok inside' 'ok quit'
  VM2LXC_FIXTURE_DIR="$fx" VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 run "$VM2LXC" menu
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_walked
  # one bar, counting VMs (never backwards), ending at 100
  local pcts
  pcts=$(awk -F'\t' '$1 == "gauge" && NF == 3 { print $2 }' "$WT_LOG" | tr '\n' ' ')
  [ "$(awk '{ for (i = 2; i <= NF; i++) if ($i < $(i-1)) bad = 1; print bad + 0 }' <<<"$pcts")" -eq 0 ] || { echo "the bar went backwards: $pcts"; return 1; }
  [ "$(awk '{ print $NF }' <<<"$pcts")" -eq 100 ]
  awk -F'\t' '$1 == "gauge" && NF == 3 { print $3 }' "$WT_LOG" | grep -q 'Looking at a VM (1 of '
  # the table is the engine's, and VM 100 really was looked inside; 103 is RED from its config and is not
  grep -qF 'ran on 1 VM(s)' "$WT_LOG.text"
  grep -qF 'cloud-init is installed' "$WT_LOG.text" # a finding only the inside of the disk can give, shown as the VM's reason
  assert_nothing_left
}

@test "whiptail: leaving the Scan question with Esc or Back runs NOTHING" {
  wt_script 'ok scan' 'esc' 'ok quit'
  go menu
  assert_walked
  assert_nothing_ran
  wt_script 'ok scan' 'ok back' 'ok quit'
  go menu
  assert_nothing_ran
}

@test "whiptail: Preflight on a RED VM shows its verdict (exit 20 is a verdict, not a failure of the menu)" {
  wt_script 'ok preflight' 'ok 103' 'ok inside' 'ok quit'
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  grep -qF 'VERDICT: RED' "$WT_LOG.text"
  grep -qF 'its disk was not looked at' "$WT_LOG.text" # a RED VM is never snapshotted
  assert_nothing_ran
}

@test "whiptail: Preflight > Look inside shows the final verdict from inside the guest, and the bar ends at 100" {
  seed_vm100
  wt_script 'ok preflight' 'ok 100' 'ok inside' 'ok quit'
  go menu
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_walked
  grep -qF '12 ran: os-release docker' "$WT_LOG.text"
  [ "$(awk -F'\t' '$1 == "gauge" && NF == 3 { p = $2 } END { print p }' "$WT_LOG")" -eq 100 ]
  assert_nothing_left
}

@test "whiptail: Preflight > Config only never touches the host and says the verdict is provisional" {
  wt_script 'ok preflight' 'ok 100' 'ok config' 'ok quit'
  go menu
  assert_walked
  grep -qF 'provisional' "$WT_LOG.text"
  assert_nothing_ran
}

@test "whiptail: Inspect runs through the review screen with a progress bar and tears everything down again" {
  seed_vm100
  wt_script 'ok inspect' 'ok 100' 'ok plan' 'ok continue' 'ok quit'
  go menu
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_walked
  menu_plain_n 1 'Inspect\ VM\ 100' | grep -qF -- 'inspect 100 --yes'
  assert_nothing_left
  [ "$(awk -F'\t' '$1 == "gauge" && NF == 3 { print $2 }' "$WT_LOG" | tail -1)" -eq 100 ]
  menu_n 1 'Inspect\ VM\ 100' | grep -qF -e '--default-item plan'
  menu_n 2 'Inspect\ VM\ 100' | grep -qF -e '--default-item continue'
}

@test "whiptail: Undo lists the finished conversions, shows the plan, and Continue destroys the container and starts the VM" {
  seed_vm100
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  : >"$WT_LOG"
  wt_script 'ok undo' "ok $CT" 'ok plan' 'ok continue' 'ok quit'
  go menu
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_walked
  [ ! -e "$FAKE_STATE/ct/$CT/conf" ]
  [ "$(cat "$FAKE_STATE/vm/100.state")" = running ]
  grep -q '^CLOSED$' "$VM2LXC_STATE_DIR/runs/rtest01/journal"
  grep -F 'Undo:\ which' "$WT_LOG" | grep -qF "container\\ $CT\\ \\ from\\ \\ VM\\ 100"
}

@test "whiptail: Undo with nothing converted says so and shows no review screen" {
  wt_script 'ok undo' 'ok quit'
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  grep -F 'msgbox' "$WT_LOG" | grep -qF 'Nothing\ to\ undo'
  assert_nothing_ran
}

@test "whiptail: Clean up with nothing unfinished says so" {
  wt_script 'ok cleanup' 'ok quit'
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  grep -F 'msgbox' "$WT_LOG" | grep -qF 'Nothing\ to\ clean\ up'
}

@test "whiptail: a failing conversion shows the failure and how to find what is left; the menu itself carries on" {
  seed_vm100
  export FAKE_FAIL=pct.create:1
  wt_script 'ok convert' 'ok 100' 'ok continue' 'ok quit'
  go menu
  [ "$status" -eq 0 ]
  assert_walked
  grep -F 'textbox' "$WT_LOG" | grep -qF 'FAILED'
  [ ! -e "$FAKE_STATE/ct/9100/conf" ]
  [ "$(cat "$FAKE_STATE/vm/100.state")" = running ] # the VM is started again
  assert_nothing_left
}

# --- the one place that adds --yes (R31) ---------------------------------------------------------------------------

@test "menu_plan refuses to run with --yes: a plan can never execute, whatever calls it" {
  load_libs ui menu
  UI_TMP=$BATS_TEST_TMPDIR
  VM2LXC_SELF=$VM2LXC
  run menu_plan convert 100 --yes
  [ "$status" -eq 64 ]
  [[ $output == *"a plan was asked to run with --yes"* ]]
  assert_nothing_ran
}

@test "two runs in one session: each result is shown only after THAT run finished (a fresh exit-code file per run)" {
  seed_vm100
  export FAKE_SLEEP_DESTROY=0.5 FAKE_SLEEP_PCT=0.6 # both runs take a moment: a result or a full bar shown early would be a lie
  wt_script 'ok convert' 'ok 100' 'ok continue' 'ok undo' 'ok 9100' 'ok continue' 'ok quit'
  go menu
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_walked
  # the first result is the conversion's, the second is the undo's and says the work was DONE when it appeared
  [ "$(grep -c '^=== textbox' "$WT_LOG.text")" -eq 2 ]
  awk '/^=== textbox/ { n++ } n == 1' "$WT_LOG.text" | grep -q 'Done. Container 9100'
  awk '/^=== textbox/ { n++ } n == 2' "$WT_LOG.text" | grep -q 'Undone. Container 9100 is gone and VM 100 is running again.'
  [ "$(grep -c '^gauge'$'\t''100'$'\t' "$WT_LOG")" -eq 2 ] # one bar per run, each finishing at 100
  # and the SECOND bar really followed its run: it showed a step in between (a reused exit-code file would end it at once)
  awk -F'\t' '$1 == "gauge" && NF == 2 { n++ } n == 2 && $1 == "gauge" && NF == 3 && $2 > 0 && $2 < 100 { found = 1 } END { exit !found }' "$WT_LOG"
  [ ! -e "$FAKE_STATE/ct/9100/conf" ]
  [ "$(cat "$FAKE_STATE/vm/100.state")" = running ]
  assert_nothing_left
}

# --- Ctrl-C during a run (R35) ---------------------------------------------------------------------------------------

# Start the menu on a slow conversion in its own session and wait until the engine is mid-run (the clone exists).
# A background job of a non-interactive shell inherits SIGINT as IGNORED and a script cannot undo that, so the launcher
# (perl) resets it to the default and starts a new session: one signal to the group then reaches the menu, whiptail
# and the engine, exactly as a terminal's Ctrl-C does.
start_menu_mid_run() {
  command -v perl >/dev/null || skip "perl is needed to start the menu with SIGINT enabled"
  seed_vm100
  wt_script 'ok convert' 'ok 100' 'ok continue' 'ok quit'
  FAKE_SLEEP_LSBLK=1.5 VM2LXC_TEST_EXEC=1 VM2LXC_RUN_ID=rtest01 VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" \
    perl -MPOSIX -e 'POSIX::setsid(); $SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"' -- "$VM2LXC" menu \
    >"$BATS_TEST_TMPDIR/out" 2>&1 &
  MENU_PID=$!
  local i
  for i in $(seq 1 150); do
    zfs_has "$C0" && break
    sleep 0.1
  done
  zfs_has "$C0" # the engine is mid-run: the snapshot clone exists
}

@test "Ctrl-C during a run (R35): the engine tears down and restarts the VM, the menu survives, shows the failure and quits normally" {
  start_menu_mid_run
  kill -INT -- "-$MENU_PID"
  local rc=0
  wait "$MENU_PID" || rc=$?
  [ "$rc" -eq 0 ] || { echo "the menu exited $rc"; cat "$BATS_TEST_TMPDIR/out"; return 1; }
  assert_walked
  grep -F 'textbox' "$WT_LOG" | grep -qF 'CANCELLED\ \(exit\ 130\)'
  # the engine's own handler did the work: nothing left, the VM running again, no container
  assert_nothing_left
  grep -q '^VMSTARTED 100' "$FAKE_STATE/events.log"
  [ ! -e "$FAKE_STATE/ct/9100/conf" ]
  must_fail compgen -G "$TMPDIR/vm2lxc-menu.*"
}

@test "a second Ctrl-C in the middle of the teardown: the menu keeps waiting for the engine, says what is left, and 'cleanup --yes' finishes the job" {
  export FAKE_SLEEP_DESTROY=1 # a slow teardown, so the second Ctrl-C really lands in the middle of it
  start_menu_mid_run
  kill -INT -- "-$MENU_PID"
  sleep 0.4
  # The engine's teardown shields itself, but `timeout` hands the signal to the tool in flight (an existing property of
  # the engine, not of the menu), so this step fails and the teardown stops as INCOMPLETE. The menu's `wait` is
  # interrupted by the same signal: it must go on waiting for the engine instead of reading a missing exit code.
  kill -INT -- "-$MENU_PID" 2>/dev/null || true
  local rc=0
  wait "$MENU_PID" || rc=$?
  [ "$rc" -eq 0 ] || { echo "the menu exited $rc"; cat "$BATS_TEST_TMPDIR/out"; return 1; }
  assert_walked
  grep -F 'textbox' "$WT_LOG" | grep -qF 'CANCELLED\ \(exit\ 130\)'
  grep -q 'teardown is INCOMPLETE' "$BATS_TEST_TMPDIR/out"
  grep -q 'See whether anything was left behind:  ' "$BATS_TEST_TMPDIR/out"
  must_fail compgen -G "$TMPDIR/vm2lxc-menu.*"
  # the advice works: cleanup finishes it, the VM runs again, nothing is left
  unset FAKE_SLEEP_DESTROY
  go cleanup --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_nothing_left
  grep -q '^VMSTARTED 100' "$FAKE_STATE/events.log"
}

# --- plain prompts ------------------------------------------------------------------------------------------------

@test "plain (--no-tui): the same flow through numbered prompts; the first Enter is the plan; a conversion works end to end" {
  seed_vm100
  # main: 4 = Convert, VM list: 2 = VM 100 (ranked after 101), Enter = the plan, Enter, Enter = Continue, Enter, 7 = Quit
  go menu --no-tui <<<$'4\n2\n\n\n\n\n7'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"The exact command Continue runs:  vm2lxc convert 100 --ctid 9100 --hostname web-green --memory 4096 --cores 4 --yes"* ]]
  [[ $output == *"Nothing was executed. Re-run with --yes"* ]] # the plan, shown first
  [[ $output == *"Creating the container"* ]]
  [[ $output == *"Done. Container 9100"* ]]
  ct_conf 9100 | grep -qx 'hostname: web-green'
  assert_nothing_left
  must_fail compgen -G "$TMPDIR/vm2lxc-menu.*"
}

@test "plain: the end of input leaves the menu with nothing run; so do q and b" {
  go menu --no-tui </dev/null
  [ "$status" -eq 0 ]
  assert_nothing_ran
  go menu --no-tui <<<"q"
  [ "$status" -eq 0 ]
  assert_nothing_ran
  go menu --no-tui <<<$'4\n2\nb\nb\nq'
  [ "$status" -eq 0 ]
  assert_nothing_ran
}

@test "plain: in the middle of the convert screen, the end of input quits and runs nothing" {
  go menu --no-tui <<<$'4\n2\n'
  [ "$status" -eq 0 ]
  assert_nothing_ran
}

# --- the answers file: unattended -------------------------------------------------------------------------------------

af() { # <name>: an answers file from stdin
  cat >"$BATS_TEST_TMPDIR/$1"
  chmod 600 "$BATS_TEST_TMPDIR/$1"
  printf '%s' "$BATS_TEST_TMPDIR/$1"
}

@test "answers: scan and preflight are read-only and give the engine's own exit code (a RED verdict is 20)" {
  f=$(af a <<<'action=scan')
  go menu --answers "$f"
  [ "$status" -eq 0 ]
  [[ $output == *"12 VMs"* ]]
  f=$(af a <<<$'action=preflight\nvm=100')
  go menu --answers "$f"
  [ "$status" -eq 0 ]
  [[ $output == *"VERDICT: GREEN"* ]]
  f=$(af a <<<$'action=preflight\nvm=103')
  go menu --answers "$f"
  [ "$status" -eq 20 ]
  assert_nothing_ran
}

@test "answers: a convert file shows the plan and executes NOTHING without --yes, even with continue=yes (R31)" {
  seed_vm100
  f=$(af a <<<$'action=convert\nvm=100\nctid=900\ncontinue=yes')
  go menu --answers "$f"
  [ "$status" -eq 0 ]
  [[ $output == *"Nothing was executed: an answers-file run changes things only with continue=yes in the file AND --yes"* ]]
  [ ! -e "$FAKE_STATE/ct/$CT/conf" ]
  assert_nothing_ran
}

@test "answers: --yes alone is not enough either: the file must say continue=yes" {
  seed_vm100
  f=$(af a <<<$'action=convert\nvm=100\nctid=900')
  go menu --answers "$f" --yes
  [ "$status" -eq 0 ]
  [[ $output == *"Nothing was executed"* ]]
  [ ! -e "$FAKE_STATE/ct/$CT/conf" ]
  f=$(af a <<<$'action=convert\nvm=100\nctid=900\ncontinue=no')
  go menu --answers "$f" --yes
  [[ $output == *"Nothing was executed"* ]]
  assert_nothing_ran
}

@test "answers: --dry-run beats continue=yes and --yes" {
  seed_vm100
  f=$(af a <<<$'action=convert\nvm=100\nctid=900\ncontinue=yes')
  go menu --answers "$f" --yes --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"Nothing was executed"* ]]
  [[ $output != *"Executing ("* ]] # the menu must not CLAIM to execute (the engine would only have planned it)
  [ ! -e "$FAKE_STATE/ct/$CT/conf" ]
  assert_nothing_ran
}

@test "answers: continue=yes AND --yes run the conversion with the file's settings, with plain progress lines" {
  seed_vm100
  f=$(af a <<<$'action=convert\nvm=100\nctid=900\nhostname=from-answers\nmemory=2048\ncores=2\ncontinue=yes')
  go menu --answers "$f" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"Executing (continue=yes in the answers file, and --yes on the command line)"* ]]
  [[ $output == *"%] "* ]]
  [[ $output == *"Done. Container 900"* ]]
  ct_conf | grep -qx 'hostname: from-answers'
  ct_conf | grep -qx 'memory: 2048'
  ct_conf | grep -qx 'cores: 2'
  ct_conf | grep -qx 'unprivileged: 1'
  assert_nothing_left
}

@test "answers: privileged=yes and start=yes become --privileged and --start" {
  seed_vm100
  f=$(af a <<<$'action=convert\nvm=100\nctid=900\nprivileged=yes\nstart=yes')
  go menu --answers "$f"
  [ "$status" -eq 0 ]
  [[ $output == *"PRIVILEGED (opt-in)"* ]]
  [[ $output == *"start the container (the cutover"* ]]
}

@test "answers: a refused plan stays refused: a RED VM with continue=yes and --yes runs nothing (20)" {
  f=$(af a <<<$'action=convert\nvm=103\ncontinue=yes')
  go menu --answers "$f" --yes
  [ "$status" -eq 20 ]
  [[ $output == *"cannot be converted (RED)"* ]]
  assert_nothing_ran
}

@test "answers: undo through the file, and a file for undo cannot carry convert's keys" {
  seed_vm100
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  f=$(af a <<<$'action=undo\nct=900\ncontinue=yes')
  go menu --answers "$f" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"Undone. Container 900 is gone and VM 100 is running again."* ]]
  [ ! -e "$FAKE_STATE/ct/$CT/conf" ]
  f=$(af a <<<$'action=undo\nct=900\nvm=100')
  go menu --answers "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"'vm' does not apply to action 'undo'"* ]]
}

@test "answers: a missing action, a missing vm or ct, and a key that does not fit the action are usage errors (64), not silently ignored" {
  f=$(af a <<<'vm=100')
  go menu --answers "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"'action' is required"* ]]
  f=$(af a <<<'action=convert')
  go menu --answers "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"needs 'vm'"* ]]
  f=$(af a <<<'action=undo')
  go menu --answers "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"needs 'ct'"* ]]
  f=$(af a <<<$'action=scan\nctid=900')
  go menu --answers "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"'ctid' does not apply to action 'scan'"* ]]
  f=$(af a <<<$'action=preflight\nvm=100\ncontinue=yes')
  go menu --answers "$f"
  [ "$status" -eq 64 ]
  assert_nothing_ran
}

@test "answers: a file others can write is refused before anything is planned" {
  f=$(af a <<<'action=scan')
  chmod 666 "$f"
  go menu --answers "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"writable by group or others"* ]]
  assert_nothing_ran
}

# --- the engine side of the progress bar ------------------------------------------------------------------------

@test "the engine reports every step through VM2LXC_PROGRESS_FILE: the four stages in order, each counted from 1 to n" {
  seed_vm100
  p=$BATS_TEST_TMPDIR/progress
  : >"$p"
  export VM2LXC_PROGRESS_FILE=$p
  go convert 100 --ctid "$CT" --yes
  unset VM2LXC_PROGRESS_FILE
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cut -f2 "$p" | uniq | tr '\n' ' ')" = "mount checks build teardown " ]
  # every line is well formed, and each stage counts 1, 2, 3 ... n of one fixed total
  awk -F'\t' '
    $1 != "P" || NF != 5 { bad = 1 }
    { if ($2 == prev) { if ($3 != last + 1 || $4 != total) bad = 1 } else { if ($3 != 1) bad = 1; total = $4 }
      prev = $2; last = $3 }
    END { exit bad }' "$p"
  grep -qP '^P\tbuild\t[0-9]+\t[0-9]+\tct-create$' "$p"
  grep -qP '^P\tchecks\t1\t1\tguest-checks$' "$p"
  # the same run without the variable writes no progress anywhere
  [ "$(grep -c . "$p")" -ge 8 ]
}

@test "undo reports its steps as the 'undo' stage" {
  seed_vm100
  go convert 100 --ctid "$CT" --yes
  p=$BATS_TEST_TMPDIR/progress
  : >"$p"
  export VM2LXC_PROGRESS_FILE=$p
  go undo "$CT" --yes
  unset VM2LXC_PROGRESS_FILE
  [ "$status" -eq 0 ]
  [ "$(cut -f2 "$p" | sort -u | tr '\n' ' ')" = "undo " ]
  # exactly the steps undo performs, counted 1 of 2 and 2 of 2 (not by their position in the journal)
  [ "$(awk -F'\t' '{ printf "%s/%s:%s ", $3, $4, $5 }' "$p")" = "1/2:ct-create 2/2:vm-stop " ]
}

@test "without VM2LXC_PROGRESS_FILE the engine behaves exactly as before" {
  seed_vm100
  unset VM2LXC_PROGRESS_FILE
  go convert 100 --ctid "$CT" --yes
  [ "$status" -eq 0 ]
  [[ $output == *"Done. Container 900"* ]]
  [[ $output != *$'P\tmount'* ]]
}

# --- the result screen: what happened, and what to do next (Fred, 2026-11-18) ---------------------------------------------

summary() { # <exit code> <log text> <engine args...>: the top of the result screen
  load_libs common ui menu
  UI_TMP="$BATS_TEST_TMPDIR/ui"
  mkdir -p "$UI_TMP"
  UI_RUN_RC=$1
  printf '%s\n' "$2" >"$UI_TMP/run.log"
  shift 2
  VM2LXC_SELF=/root/vm2lxc-src/vm2lxc menu_result_summary "$@"
}

@test "result screen, convert succeeded and the container was NOT started: says so and gives the cutover command" {
  run summary 0 'Done.' convert 603 --ctid 613
  [[ $output == *"SUCCESS: VM 603 was converted into container 613."* ]]
  [[ $output == *"The container is STOPPED."* ]]
  [[ $output == *"WHAT TO DO NEXT"* && $output == *"pct config 613"* && $output == *"pct start 613"* ]]
  [[ $output == *"pct exec 613 -- ip -br a"* && $output == *"main menu > Undo > container 613"* ]]
  [[ $output == *"Never run VM 603 and container 613 at the same time"* ]]
  [[ $output != *"Tailscale"* ]]
}

@test "result screen, convert with --start: the container is RUNNING and there is no 'pct start' step to do" {
  run summary 0 'Done.' convert 603 --ctid 613 --start
  [[ $output == *"The container is RUNNING."* ]]
  [[ $output != *"pct start"* ]]
  [[ $output == *"pct config 613"* ]]
}

@test "result screen, convert of a Tailscale guest repeats the one-node warning" {
  run summary 0 'Tailscale state was copied: the VM and the container are ONE node.' convert 601 --ctid 611
  [[ $output == *"Tailscale: the VM and the container are ONE node. Do not run both."* ]]
}

@test "result screen, undo succeeded: says the container is gone, repeats the engine's line, and what to do next" {
  run summary 0 $'Undone. Container 613 is gone and VM 603 is running again.' undo 613
  [[ $output == *"SUCCESS: container 613 was destroyed and the conversion is undone."* ]]
  [[ $output == *"Undone. Container 613 is gone and VM 603 is running again."* ]]
  [[ $output == *"WHAT TO DO NEXT"* && $output == *"qm status"* && $output == *"main menu > Convert"* ]]
}

@test "result screen, inspect and cleanup succeeded: each says what it did and what is next" {
  run summary 0 $'Guest verdict: GREEN (VM-config checks: run vm2lxc preflight)' inspect 603
  [[ $output == *"SUCCESS: the disk of VM 603 was looked at, and everything mounted for it was removed again."* ]]
  [[ $output == *"Guest verdict: GREEN"* && $output == *"main menu > Convert > VM 603"* ]]
  run summary 0 'x' cleanup
  [[ $output == *"SUCCESS: the leftovers of unfinished runs were removed"* && $output == *"Nothing. Go back to the main menu."* ]]
}

@test "result screen, a failed convert: FAILED with the reason lines, the VM's state, cleanup, and that the VM's disks are untouched" {
  run summary 77 $'vm2lxc convert 603\nvm2lxc: the guest cannot be converted (RED, see above). Nothing was kept.\n  [RED] Docker/Podman/containerd found' convert 603 --ctid 613
  [[ $output == *"FAILED (exit 77): the convert did not complete."* ]]
  [[ $output == *"WHY"* && $output == *"vm2lxc: the guest cannot be converted"* && $output == *"[RED] Docker/Podman/containerd found"* ]]
  [[ $output == *"WHAT TO DO NEXT"* && $output == *"qm status 603"* ]]
  [[ $output == *"/root/vm2lxc-src/vm2lxc cleanup"* && $output == *"add --yes to remove what it lists"* ]]
  [[ $output == *"The VM's own disks were never written, so it is unchanged."* ]]
  [[ $output != *"SUCCESS"* ]]
}

@test "result screen, Ctrl-C is CANCELLED, not a mystery failure" {
  run summary 130 'x' convert 603 --ctid 613
  [[ $output == *"CANCELLED (exit 130): you pressed Ctrl-C. The run was stopped and cleaned up."* ]]
  [[ $output == *"WHAT TO DO NEXT"* ]]
}

@test "whiptail: a conversion that FAILS shows the failure screen with the reason and next steps, and the menu carries on" {
  seed_vm100
  FAKE_FAIL=pct.create:1 wt_script 'ok convert' 'ok 100' 'ok continue' 'ok quit'
  FAKE_FAIL=pct.create:1 go menu
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_walked
  grep -F 'textbox' "$WT_LOG" | grep -qF 'FAILED'
  grep -qF 'WHAT TO DO NEXT' "$WT_LOG.text"
  grep -qF 'qm status 100' "$WT_LOG.text"
  grep -qF "The VM's own disks were never written" "$WT_LOG.text"
  assert_nothing_left
}
