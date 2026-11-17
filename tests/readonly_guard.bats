#!/usr/bin/env bats
# The read-only promise, proved two independent ways.
#
#  1. STATIC: the source never invokes a mutating verb, whatever path it takes.
#  2. DYNAMIC: run the real tool in live mode against stub qm/pvesh/pvesm/pveversion that
#     log every call, serve the fixtures, and refuse anything that is not a read. Stub
#     versions of pct, zfs, mount, rsync, ... are on PATH too and must never be called.
#     This also proves the live command lines produce the same results as fixture mode.

bats_require_minimum_version 1.5.0
load helpers

# --- static ---------------------------------------------------------------------------

# Code lines only: drop whole-line comments.
code_lines() {
  grep -hvE '^[[:space:]]*#' "$REPO_ROOT/vm2lxc" "$REPO_ROOT"/lib/*.sh
}

@test "static: no mutating verb follows qm, pvesh or pvesm anywhere in the source" {
  # A denylist, because the source legitimately names these tools in messages and in the
  # "is it installed" loop. The strict allowlist (exact argument shapes) is enforced by the
  # dynamic stub tests below, which are the real guard.
  local verbs='set|create|destroy|delete|put|post|snapshot|delsnapshot|rollback|start|stop|shutdown|reset|resume|suspend|clone|migrate|move_disk|move-volume|resize|importdisk|unlock|template|restore|monitor|sendkey|terminal|alloc|free|add|remove|import|mount|unmount|vncproxy|spiceproxy|reboot|cloudinit|rescan|wait'
  local bad
  bad=$(code_lines | grep -noE "\\b(qm|pvesh|pvesm)[[:space:]]+(${verbs})\\b" || true)
  [ -z "$bad" ] || { echo "mutating host verbs in the source:"; echo "$bad"; return 1; }
}

@test "static: pct is never mentioned in code (no container is created in this slice)" {
  run bash -c "grep -hvE '^[[:space:]]*#' '$REPO_ROOT/vm2lxc' '$REPO_ROOT'/lib/*.sh | grep -nE '\\bpct\\b'"
  [ "$status" -eq 1 ]
}

@test "static: no mutating or out-of-scope tool is run in command position" {
  # command position = start of line, or after | & ; ( ` $(  -- so prose like "mount points" is fine
  local tools='zfs|zpool|lvcreate|lvremove|lvchange|lvextend|lvreduce|lvresize|vgchange|vgcreate|vgremove|kpartx|qemu-nbd|qemu-img|losetup|mount|umount|rsync|tar|dd|mkfs[.a-z0-9]*|wipefs|fdisk|parted|sgdisk|rm|mv|cp|ln|chmod|chown|truncate|tee|systemctl|ssh|scp|curl|wget|sudo|apt|apt-get|dpkg|pip|kill|pkill|reboot|shutdown'
  local hits
  # command position = line start, or after | & ; ( { ` $( or the keywords then/do/else/elif.
  # A name followed by | or ) is a case label (e.g. "zfs | iscsi)"), not a command.
  hits=$(code_lines | grep -nE "(^|[|&;({\`]|\\\$\\(|[[:space:]](then|do|else|elif))[[:space:]]*(${tools})([[:space:]]+[^|)[:space:]]|[[:space:]]*\$)" || true)
  [ -z "$hits" ] || { echo "tools in command position:"; echo "$hits"; return 1; }
}

@test "static: no in-place edits (sed -i)" {
  local hits
  hits=$(code_lines | grep -nE 'sed[[:space:]]+(-[a-zA-Z]*i|--in-place)' || true)
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

# --- dynamic ---------------------------------------------------------------------------

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  export STUB_FIXTURES="$FIXTURES/pve8"
  mkdir -p "$STUBS"
  : >"$STUB_LOG"
  local n
  for n in qm pvesh pvesm pveversion \
    pct zfs zpool lvcreate lvremove lvchange lvextend vgchange kpartx qemu-nbd losetup \
    mount umount rsync tar dd mkfs.ext4 rm mv cp ln chmod chown truncate tee systemctl ssh scp curl wget sudo; do
    ln -s "$REPO_ROOT/tests/stubs/pvestub.sh" "$STUBS/$n"
  done
}

# Fail the test if the call log matches. (`! grep` would never fail under `set -e`.)
refute_log() {
  if grep -qE "$1" "$STUB_LOG"; then
    echo "unexpected in the call log: $1"
    cat "$STUB_LOG"
    return 1
  fi
}

# Run the tool in LIVE mode (no fixture dir) through the stubs.
live() {
  VM2LXC_FIXTURE_DIR="" VM2LXC_ASSUME_ROOT=1 PATH="$STUBS:$PATH" run "$VM2LXC" "$@"
}

@test "dynamic: the tripwire itself works (a mutating call through the stubs is refused and logged)" {
  PATH="$STUBS:$PATH" run qm set 100 --memory 1
  [ "$status" -eq 99 ]
  PATH="$STUBS:$PATH" run pct create 900 foo
  [ "$status" -eq 99 ]
  PATH="$STUBS:$PATH" run pvesh create /nodes/x/qemu
  [ "$status" -eq 99 ]
  [ "$(grep -c '^REFUSED' "$STUB_LOG")" -eq 3 ]
}

@test "dynamic: preflight in live mode runs exactly these reads, in this order, and nothing else" {
  live --node pve-test preflight 100
  [ "$status" -eq 0 ]
  local expected
  expected=$(printf '%s\n' \
    'pveversion ' \
    'pvesm status' \
    'qm config 100' \
    'pvesh get /nodes/pve-test/qemu/100/rrddata --timeframe month --output-format json' \
    'pvesh get /nodes/pve-test/qemu/100/rrddata --timeframe week --output-format json' \
    'pvesh get /nodes/pve-test/qemu/100/rrddata --timeframe day --output-format json')
  [ "$(cat "$STUB_LOG")" = "$expected" ]
}

@test "dynamic: preflight output in live mode equals fixture mode (apart from the mode label)" {
  live --node pve-test preflight 101
  local live_out=$output live_status=$status
  run_fx preflight 101
  [ "$status" -eq "$live_status" ]
  [ "$(sed 's/live host/MODE/' <<<"$live_out")" = "$(sed 's/FIXTURE MODE (canned data, no real host)/MODE/' <<<"$output")" ]
}

@test "dynamic: scan in live mode makes only allowed reads, skips sizing for red VMs, and matches fixture mode" {
  live --node pve-test scan
  [ "$status" -eq 0 ]
  local live_out=$output
  refute_log '^REFUSED'
  # every logged call is one of the four allowed shapes
  local bad
  bad=$(grep -vE '^(pveversion |pvesm status|qm config [0-9]+|pvesh get /nodes/pve-test/qemu --output-format json|pvesh get /nodes/pve-test/qemu/[0-9]+/rrddata --timeframe (month|week|day) --output-format json)$' "$STUB_LOG" || true)
  [ -z "$bad" ] || { echo "unexpected calls:"; echo "$bad"; return 1; }
  # red VMs (103 104 105 107 108): config read, but no rrddata fetched
  local red
  for red in 103 104 105 107 108; do
    grep -q "^qm config $red\$" "$STUB_LOG"
    refute_log "qemu/$red/rrddata"
  done
  # a green VM did get its history fetched
  grep -q 'qemu/100/rrddata --timeframe month' "$STUB_LOG"
  run_fx scan
  [ "$(sed 's/live host/MODE/' <<<"$live_out")" = "$(sed 's/FIXTURE MODE (canned data, no real host)/MODE/' <<<"$output")" ]
}

@test "dynamic: without --node the node comes from the hostname" {
  live preflight 100
  [ "$status" -eq 0 ]
  grep -q "pvesh get /nodes/$(hostname -s)/qemu/100/rrddata" "$STUB_LOG"
}

@test "dynamic: convert, undo and cleanup make zero host calls" {
  live convert 100
  [ "$status" -eq 70 ]
  live undo 100
  [ "$status" -eq 70 ]
  live cleanup
  [ "$status" -eq 70 ]
  [ ! -s "$STUB_LOG" ]
}

@test "dynamic: --help, --version and usage errors make zero host calls" {
  live --help
  live --version
  live frobnicate
  live preflight
  live preflight abc
  [ ! -s "$STUB_LOG" ]
}

@test "dynamic: --yes, --dry-run, --answers and --no-tui do not open any door to a mutating call" {
  live --node pve-test --yes --dry-run --no-tui --answers /nonexistent/answers.ini preflight 100
  [ "$status" -eq 0 ]
  live --node pve-test --yes --dry-run --no-tui scan
  [ "$status" -eq 0 ]
  refute_log '^REFUSED'
  [ "$(grep -cvE '^(pveversion |pvesm status|qm config [0-9]+|pvesh get )' "$STUB_LOG")" -eq 0 ]
}

@test "dynamic: a failing read (VM does not exist) is reported, and still nothing mutating runs" {
  live --node pve-test preflight 999
  [ "$status" -eq 66 ]
  refute_log '^REFUSED'
}

@test "dynamic: not root and no override is refused before any host call" {
  if [ "$(id -u)" -eq 0 ]; then skip "running as root"; fi
  VM2LXC_FIXTURE_DIR="" PATH="$STUBS:$PATH" run "$VM2LXC" preflight 100
  [ "$status" -eq 69 ]
  [[ $output == *"must run as root"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "dynamic: strace proves no file is created, written, renamed, removed or chmod'd (tool and every child)" {
  command -v strace >/dev/null || skip "strace not installed"
  strace -qq -o /dev/null true 2>/dev/null || skip "strace/ptrace not permitted here"
  local log="$BATS_TEST_TMPDIR/strace.log" cmd bad
  local calls='open,openat,openat2,creat,unlink,unlinkat,rename,renameat,renameat2,mkdir,mkdirat,rmdir,truncate,ftruncate,chmod,fchmod,fchmodat,chown,fchown,fchownat,lchown,symlink,symlinkat,link,linkat,mknod,mknodat,utimensat,setxattr'
  for cmd in "scan" "preflight 100" "preflight 105" "preflight 106"; do
    : >"$log"
    # shellcheck disable=SC2086
    VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" strace -f -qq -o "$log" -e "trace=$calls" "$VM2LXC" $cmd >/dev/null 2>&1 || true
    [ -s "$log" ] || { echo "strace recorded nothing for: $cmd"; return 1; }
    # anything that opens for writing or changes the filesystem, except /dev/null and the tty probe bash does itself
    bad=$(grep -E 'O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND|O_TMPFILE|unlink|rename|mkdir|rmdir|truncate|chmod|chown|symlink|link\(|mknod|utimens|setxattr' "$log" |
      grep -vE '"/dev/null"|"/dev/tty"' || true)
    [ -z "$bad" ] || { echo "filesystem changes while running: vm2lxc $cmd"; echo "$bad"; return 1; }
  done
}
