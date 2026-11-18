#!/usr/bin/env bats
# The interactive layer (lib/ui.sh): the answers-file parser, choosing a backend, the plain prompts, the progress
# plumbing. No host and no terminal: the prompts read stdin, whiptail is the scripted stub (tests/stubs/whiptail.sh).

bats_require_minimum_version 1.5.0
load helpers

setup() {
  load_libs common hostexec ui
  UI_BACKEND=plain
  export TMPDIR=$BATS_TEST_TMPDIR
  FB=$BATS_TEST_TMPDIR/fakebin
  mkdir -p "$FB"
}

# af <name>: write an answers file from stdin with mode 600, print its path
af() {
  cat >"$BATS_TEST_TMPDIR/$1"
  chmod 600 "$BATS_TEST_TMPDIR/$1"
  printf '%s' "$BATS_TEST_TMPDIR/$1"
}

# --- the answers file (R33) ---------------------------------------------------------------------------------------

@test "answers: a complete file is read, with comments, blank lines and spaces around '='" {
  f=$(af a <<'EOF'
# the test run

action = convert
vm=603
ctid=613
hostname = vm2lxc-test
memory=1024
cores=2
privileged=no
start=yes
continue=yes
EOF
  )
  answers_load "$f"
  [ "${ANSWERS[action]}" = convert ]
  [ "${ANSWERS[vm]}" = 603 ]
  [ "${ANSWERS[ctid]}" = 613 ]
  [ "${ANSWERS[hostname]}" = vm2lxc-test ]
  [ "${ANSWERS[memory]}" = 1024 ]
  [ "${ANSWERS[cores]}" = 2 ]
  [ "${ANSWERS[privileged]}" = no ]
  [ "${ANSWERS[start]}" = yes ]
  [ "${ANSWERS[continue]}" = yes ]
}

@test "answers: every bad value is refused (64), naming the line" {
  local bad
  for bad in 'vm=12' 'vm=abc' 'ct=99' 'ctid=5' 'hostname=-x' 'hostname=Foo_Bar' 'memory=5' 'cores=x' \
    'privileged=maybe' 'start=1' 'continue=true' 'action=destroy' 'vm=' 'ctid=9 00'; do
    f=$(af b <<<"$bad")
    run answers_load "$f"
    [ "$status" -eq 64 ] || { echo "not refused: $bad"; return 1; }
    [[ $output == *"line 1"* ]] || { echo "no line number for: $bad ($output)"; return 1; }
  done
}

@test "answers: an unknown key, a duplicate and a line that is not key=value are refused" {
  f=$(af c <<<'colour=blue')
  run answers_load "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"unknown key 'colour'"* ]]
  f=$(af c <<<$'vm=603\nvm=604')
  run answers_load "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"'vm' is given twice"* ]]
  f=$(af c <<<'just some words')
  run answers_load "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"not 'key=value'"* ]]
}

@test "answers: a control character is refused, so a stray CR or escape cannot hide in a value" {
  f=$(af c <<<$'vm=603\r')
  run answers_load "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"control character"* ]]
  f=$(af c <<<$'vm=603\033[2J')
  run answers_load "$f"
  [ "$status" -eq 64 ]
}

@test "answers: the file is data, never code: a command substitution in a value is refused and never runs" {
  rm -f "$BATS_TEST_TMPDIR/PWNED"
  f=$(af c <<<"hostname=\$(touch $BATS_TEST_TMPDIR/PWNED)")
  run answers_load "$f"
  [ "$status" -eq 64 ]
  f=$(af c <<<"action=scan; touch $BATS_TEST_TMPDIR/PWNED")
  run answers_load "$f"
  [ "$status" -eq 64 ]
  f=$(af c <<<"\`touch $BATS_TEST_TMPDIR/PWNED\`=1")
  run answers_load "$f"
  [ "$status" -eq 64 ]
  [ ! -e "$BATS_TEST_TMPDIR/PWNED" ]
}

@test "answers: a missing file, a directory and an oversized file are refused" {
  run answers_load "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 64 ]
  run answers_load "$BATS_TEST_TMPDIR"
  [ "$status" -eq 64 ]
  f=$(af big </dev/null)
  head -c 5000 /dev/zero | tr '\0' '#' >"$f"
  run answers_load "$f"
  [ "$status" -eq 64 ]
  [[ $output == *"larger than 4 KiB"* ]]
}

@test "answers: a file that group or others can write is refused, a plain 644 file is fine (it decides what runs as root)" {
  f=$(af w <<<'action=scan')
  local m
  for m in 666 662 620 660 622; do
    chmod "$m" "$f"
    run answers_load "$f"
    [ "$status" -eq 64 ] || { echo "mode $m was accepted"; return 1; }
    [[ $output == *"writable by group or others"* ]]
  done
  chmod 644 "$f"
  answers_load "$f"
  [ "${ANSWERS[action]}" = scan ]
}

@test "answers: loading a second file starts from nothing: no key survives from the first" {
  f=$(af a <<<$'vm=603\ncontinue=yes')
  answers_load "$f"
  [ "${ANSWERS[continue]}" = yes ]
  f=$(af b <<<'action=scan')
  answers_load "$f"
  [ -z "${ANSWERS[continue]+x}" ]
  [ -z "${ANSWERS[vm]+x}" ]
}

# --- choosing the backend (R32) -----------------------------------------------------------------------------------

init_and_report() {
  ui_init
  printf 'backend=%s tmp=%s\n' "$UI_BACKEND" "$UI_TMP"
  [[ -d $UI_TMP ]] && printf 'tmp-mode=%s\n' "$(stat -c %a "$UI_TMP")"
  return 0
}

@test "ui_init: no terminal and no answers file is a refusal (64) that makes nothing: the menu never hangs or guesses" {
  OPT_ANSWERS="" OPT_NO_TUI=0 VM2LXC_UI_TTY=0 run init_and_report
  [ "$status" -eq 64 ]
  [[ $output == *"needs a terminal"* ]]
  must_fail compgen -G "$TMPDIR/vm2lxc-menu.*"
}

@test "ui_init: an answers file wins over everything, and the scratch directory is private (700)" {
  f=$(af a <<<'action=scan')
  OPT_ANSWERS=$f OPT_NO_TUI=0 VM2LXC_UI_TTY=0 run init_and_report
  [ "$status" -eq 0 ]
  [[ $output == *"backend=answers"* ]]
  [[ $output == *"tmp-mode=700"* ]]
}

@test "ui_init: the scratch directory is removed when the menu ends" {
  OPT_ANSWERS="" OPT_NO_TUI=1 VM2LXC_UI_TTY=1 run init_and_report
  [ "$status" -eq 0 ]
  must_fail compgen -G "$TMPDIR/vm2lxc-menu.*"
}

@test "ui_init: at a terminal, --no-tui means plain prompts even when whiptail is there" {
  ln -s "$REPO_ROOT/tests/stubs/whiptail.sh" "$FB/whiptail"
  PATH=$FB:$PATH OPT_ANSWERS="" OPT_NO_TUI=1 VM2LXC_UI_TTY=1 run init_and_report
  [ "$status" -eq 0 ]
  [[ $output == *"backend=plain"* ]]
}

@test "ui_init: at a terminal with whiptail it uses whiptail" {
  ln -s "$REPO_ROOT/tests/stubs/whiptail.sh" "$FB/whiptail"
  PATH=$FB:$PATH OPT_ANSWERS="" OPT_NO_TUI=0 VM2LXC_UI_TTY=1 run init_and_report
  [ "$status" -eq 0 ]
  [[ $output == *"backend=whiptail"* ]]
}

@test "ui_init: at a terminal WITHOUT whiptail it falls back to plain prompts" {
  mkdir -p "$BATS_TEST_TMPDIR/minbin"
  ln -s "$(command -v mktemp)" "$BATS_TEST_TMPDIR/minbin/mktemp"
  ln -s "$(command -v rm)" "$BATS_TEST_TMPDIR/minbin/rm"
  no_whiptail() {
    PATH=$BATS_TEST_TMPDIR/minbin
    init_and_report
  }
  OPT_ANSWERS="" OPT_NO_TUI=0 VM2LXC_UI_TTY=1 run no_whiptail
  [ "$status" -eq 0 ]
  [[ $output == *"backend=plain"* ]]
}

# --- the scratch directory (R36): made and removed only by the audited helpers in lib/hostexec.sh -----------------

@test "scratch: scratch_new makes a private directory named for the menu, scratch_free removes it with everything in it" {
  d=$(scratch_new)
  [[ $d == "$TMPDIR"/vm2lxc-menu.?????? ]]
  [ "$(stat -c %a "$d")" = 700 ]
  : >"$d/plan.txt"
  printf 'x' >"$d/-rf"          # a file named like an option
  printf 'x' >"$d/a b c"        # and one with spaces
  : >"$d/.hidden"
  scratch_free "$d"
  [ ! -e "$d" ]
}

@test "scratch: a TMPDIR with a trailing slash works" {
  TMPDIR=$BATS_TEST_TMPDIR/ d=$(scratch_new)
  [ -d "$d" ]
  TMPDIR=$BATS_TEST_TMPDIR/ scratch_free "$d"
  [ ! -e "$d" ]
}

@test "scratch: scratch_free leaves alone, and fails on, anything that is not exactly one of ours" {
  # a directory with the wrong name
  mkdir "$TMPDIR/other.dir"
  must_fail scratch_free "$TMPDIR/other.dir"
  [ -d "$TMPDIR/other.dir" ]
  # the right name but a bad suffix length, and a path that only ends like ours
  mkdir "$TMPDIR/vm2lxc-menu.abc"
  must_fail scratch_free "$TMPDIR/vm2lxc-menu.abc"
  mkdir -p "$TMPDIR/sub/vm2lxc-menu.abcdef"
  must_fail scratch_free "$TMPDIR/sub/vm2lxc-menu.abcdef"
  # a symlink named like ours, pointing at a real directory: the target must survive
  mkdir "$TMPDIR/target"
  : >"$TMPDIR/target/keep"
  ln -s "$TMPDIR/target" "$TMPDIR/vm2lxc-menu.linkxx"
  must_fail scratch_free "$TMPDIR/vm2lxc-menu.linkxx"
  [ -e "$TMPDIR/target/keep" ]
  # a plain file, an empty argument, a directory that holds a subdirectory, a symlink inside
  : >"$TMPDIR/vm2lxc-menu.afile0"
  must_fail scratch_free "$TMPDIR/vm2lxc-menu.afile0"
  must_fail scratch_free ""
  d=$(scratch_new)
  mkdir "$d/sub"
  : >"$d/sub/keep"
  : >"$d/plan.txt"
  must_fail scratch_free "$d"
  [ -e "$d/sub/keep" ] && [ -e "$d/plan.txt" ] # nothing was removed: it checks everything before it deletes anything
  rm -r "$d/sub"
  ln -s "$TMPDIR/target" "$d/inside"
  must_fail scratch_free "$d"
  [ -e "$TMPDIR/target/keep" ]
}

@test "scratch: a rm that is first on PATH is not trusted (command -p), so the cleanup cannot be hijacked or stubbed out" {
  printf '#!/bin/sh\necho "hijacked rm called: $*" >>%s\nexit 1\n' "$BATS_TEST_TMPDIR/rm.log" >"$FB/rm"
  chmod +x "$FB/rm"
  d=$(scratch_new)
  : >"$d/plan.txt"
  PATH=$FB:$PATH scratch_free "$d"
  [ ! -e "$d" ]
  [ ! -e "$BATS_TEST_TMPDIR/rm.log" ]
}

@test "scratch: ui_cleanup says so, and does not die, when the directory holds something the menu did not put there" {
  UI_TMP=$(scratch_new)
  mkdir "$UI_TMP/sub"
  run ui_cleanup
  [ "$status" -eq 0 ]
  [[ $output == *"left the scratch directory"* ]]
  [ -d "$UI_TMP/sub" ]
}

# --- the plain prompts ----------------------------------------------------------------------------------------------

pick() { # <default> <tag desc>...
  ui_menu "Title" "Text" "$@"
  local rc=$?
  printf 'REPLY=%s rc=%s quit=%s\n' "${REPLY:-}" "$rc" "$UI_QUIT"
}

@test "plain menu: a number picks that item, Enter takes the highlighted default" {
  run pick two one First two Second three Third <<<"3"
  [[ $output == *"REPLY=three rc=0 quit=0"* ]]
  run pick two one First two Second three Third <<<""
  [[ $output == *"REPLY=two rc=0 quit=0"* ]]
  run pick two one First two Second three Third <<<"02"
  [[ $output == *"REPLY=two rc=0"* ]]
}

@test "plain menu: the default is shown in the prompt and marks nothing else" {
  run pick two one First two Second three Third <<<"1"
  [[ $output == *"Choose 1-3 [2]"* ]]
}

@test "plain menu: b goes back (1), q quits (2, and says so), the end of input quits" {
  run pick two one First two Second <<<"b"
  [[ $output == *"rc=1 quit=0"* ]]
  run pick two one First two Second <<<"q"
  [[ $output == *"rc=2 quit=1"* ]]
  run pick two one First two Second </dev/null
  [[ $output == *"rc=2 quit=1"* ]]
}

@test "plain menu: a bad answer asks again instead of choosing something" {
  run pick two one First two Second <<<$'9\nabc\n0\n1x\n1'
  [[ $output == *"REPLY=one rc=0"* ]]
  [[ $output == *"Please type a number from 1 to 2"* ]]
}

v_num() { [[ $1 =~ ^[0-9]+$ ]]; }
ask() { # <default>
  ui_input "T" "Prompt" "$1" v_num "That is not a number."
  local rc=$?
  printf 'REPLY=%s rc=%s quit=%s\n' "${REPLY:-}" "$rc" "$UI_QUIT"
}

@test "plain input: Enter takes the default, a typed value is used, an invalid one is refused and asked again" {
  run ask 42 <<<""
  [[ $output == *"REPLY=42 rc=0"* ]]
  run ask 42 <<<"7"
  [[ $output == *"REPLY=7 rc=0"* ]]
  run ask 42 <<<$'x\n\n8'
  [[ $output == *"That is not a number."* ]]
  [[ $output == *"REPLY=8 rc=0"* ]]
}

@test "plain input: '!' goes back (1), the end of input quits (2)" {
  run ask 42 <<<"!"
  [[ $output == *"rc=1"* ]]
  run ask 42 </dev/null
  [[ $output == *"rc=2 quit=1"* ]]
}

yn() { # <default>
  ui_yesno "T" "Really?" "$1"
  printf 'rc=%s quit=%s\n' "$?" "$UI_QUIT"
}

@test "plain yes/no: only an explicit yes confirms; Enter takes the default; anything odd is a no" {
  run yn no <<<""
  [[ $output == *"rc=1"* ]]
  run yn yes <<<""
  [[ $output == *"rc=0"* ]]
  run yn no <<<"y"
  [[ $output == *"rc=0"* ]]
  run yn no <<<"YES"
  [[ $output == *"rc=0"* ]]
  run yn yes <<<"n"
  [[ $output == *"rc=1"* ]]
  run yn yes <<<"perhaps"
  [[ $output == *"rc=1"* ]]
  run yn yes </dev/null
  [[ $output == *"rc=2 quit=1"* ]]
}

# --- whiptail arguments (R34) -----------------------------------------------------------------------------------

@test "ui_safe: a word that would be read as a whiptail option gets a leading space" {
  [ "$(ui_safe '-evil')" = " -evil" ]
  [ "$(ui_safe '--menu')" = " --menu" ]
  [ "$(ui_safe 'fine')" = "fine" ]
}

@test "whiptail menu: a description that starts with '-' never reaches whiptail as a bare option" {
  ln -s "$REPO_ROOT/tests/stubs/whiptail.sh" "$FB/whiptail"
  export WT_LOG=$BATS_TEST_TMPDIR/wt.log WT_SCRIPT=$BATS_TEST_TMPDIR/wt.script
  printf 'ok 603\n' >"$WT_SCRIPT"
  UI_BACKEND=whiptail PATH=$FB:$PATH
  ui_menu "Pick" "Text" 603 603 "-rf name" 604 "--title x"
  [ "$REPLY" = 603 ]
  grep -qF -- '603 \ -rf\ name' "$WT_LOG"
  grep -qF -- '604 \ --title\ x' "$WT_LOG"
}

# --- progress (R36) -----------------------------------------------------------------------------------------------

@test "progress: a step line becomes a percentage and a plain-words label inside its stage's range" {
  ui_progress_parse convert $'P\tmount\t2\t3\tlvm-snapshot'
  [ "$UI_PCT" -eq 10 ]
  [ "$UI_LABEL" = "Snapshotting a disk (2 of 3)" ]
  ui_progress_parse convert $'P\tbuild\t1\t4\tct-create'
  [ "$UI_PCT" -eq 40 ]
  [ "$UI_LABEL" = "Creating the container (1 of 4)" ]
  ui_progress_parse convert $'P\tbuild\t4\t4\tct-start'
  [ "$UI_PCT" -eq 73 ]
  ui_progress_parse undo $'P\tundo\t5\t5\tct-start'
  [ "$UI_PCT" -eq 80 ]
  ui_progress_parse inspect $'P\tchecks\t1\t1\tguest-checks'
  [ "$UI_PCT" -eq 60 ]
  [ "$UI_LABEL" = "Running the guest checks (1 of 1)" ]
}

@test "progress: in the teardown and undo stages a step reads as what is being UNDONE (undoing vm-stop starts the VM)" {
  ui_progress_parse undo $'P\tundo\t2\t2\tvm-stop'
  [ "$UI_PCT" -eq 50 ]
  [ "$UI_LABEL" = "Starting the VM again (2 of 2)" ]
  ui_progress_parse undo $'P\tundo\t1\t2\tct-create'
  [ "$UI_LABEL" = "Destroying the container (1 of 2)" ]
  ui_progress_parse convert $'P\tteardown\t1\t4\tzfs-snapshot'
  [ "$UI_LABEL" = "Removing the snapshot (1 of 4)" ]
  ui_progress_parse convert $'P\tmount\t1\t4\tzfs-snapshot'
  [ "$UI_LABEL" = "Snapshotting a disk (1 of 4)" ]
  ui_progress_parse cleanup $'P\tteardown\t1\t2\tsome-new-step'
  [ "$UI_LABEL" = "Undoing (some-new-step) (1 of 2)" ]
}

@test "progress: a kind the menu does not know is shown as 'Working (kind)', not dropped" {
  ui_progress_parse convert $'P\tmount\t1\t2\tsome-new-step'
  [ "$UI_LABEL" = "Working (some-new-step) (1 of 2)" ]
}

@test "progress: anything that is not a well-formed line of ours is refused" {
  local bad
  for bad in $'Q\tmount\t1\t2\tdev-ready' $'P\tmount\t0\t2\tdev-ready' $'P\tmount\t3\t2\tdev-ready' \
    $'P\tmount\t1\t0\tdev-ready' $'P\tmount\t1234567\t9999999\tdev-ready' $'P\tmount\t1\t2\tDev-Ready' \
    $'P\tmount\t1\t2\tdev ready' $'P\tmount\t1\t2' $'P\tmount\tone\t2\tdev-ready' '' 'garbage' \
    $'P\tbuild\t1\t2\tdev-ready' $'P\tmount\t1\t2\t$(touch X)'; do
    must_fail ui_progress_parse inspect "$bad" || { echo "accepted: $bad"; return 1; }
  done
  [ ! -e X ]
}

@test "progress: the gauge's last frame is the highest percentage seen, then 100 (it never goes backwards)" {
  prog=$BATS_TEST_TMPDIR/prog rcf=$BATS_TEST_TMPDIR/rc
  printf 'P\tmount\t3\t3\tdev-ready\nP\tmount\t1\t3\tdev-ready\ngarbage\n' >"$prog"
  printf '0\n' >"$rcf"
  run ui_gauge_feed convert "$prog" "$rcf"
  [ "$status" -eq 0 ]
  [[ $output == *$'XXX\n20\n'* ]]
  [[ $output != *$'XXX\n0\n'* ]]
  [[ $output == *$'XXX\n100\n Finished\nXXX' ]]
}

@test "progress_emit: does nothing unless the menu named an existing plain file, and never writes through a symlink" {
  f=$BATS_TEST_TMPDIR/p
  unset VM2LXC_PROGRESS_FILE
  progress_emit mount 1 2 dev-ready
  [ ! -e "$f" ]
  VM2LXC_PROGRESS_FILE=$f progress_emit mount 1 2 dev-ready # a file that does not exist is NOT created
  [ ! -e "$f" ]
  : >"$f"
  VM2LXC_PROGRESS_FILE=$f progress_emit mount 1 2 dev-ready
  [ "$(cat "$f")" = $'P\tmount\t1\t2\tdev-ready' ]
  target=$BATS_TEST_TMPDIR/target
  : >"$target"
  ln -s "$target" "$BATS_TEST_TMPDIR/link"
  VM2LXC_PROGRESS_FILE=$BATS_TEST_TMPDIR/link progress_emit mount 1 2 dev-ready
  [ ! -s "$target" ]
  VM2LXC_PROGRESS_FILE=$BATS_TEST_TMPDIR progress_emit mount 1 2 dev-ready # a directory: no error
}
