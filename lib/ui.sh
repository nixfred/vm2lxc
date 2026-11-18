# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are shared with lib/menu.sh and the entry script
# The interactive layer (decision D7): a whiptail menu with a plain-prompt fallback, a progress bar fed by the
# engine, and an answers file for unattended runs. Sourced, never run. Design and rails: docs/menu.html (R30-R38).
#
# This layer only ASKS and SHOWS. It never executes anything on the host: lib/menu.sh turns the answers into a
# vm2lxc command line and runs the same binary, so the menu can do nothing the command line cannot.
#
# Return codes of every ask primitive: 0 an answer is in REPLY (or "yes"), 1 back/cancel/Esc (or "no"),
# 2 the person asked to leave (q, or the input ended): UI_QUIT is set and every loop must stop.

[[ -n ${_VM2LXC_UI:-} ]] && return 0
_VM2LXC_UI=1

UI_BACKEND=""   # whiptail | plain | answers
UI_BACKTITLE=""
UI_TMP=""       # private scratch directory (mode 700): plans, logs, the progress file
UI_QUIT=0
UI_RUN_RC=0     # the exit code of the last ui_run
UI_RUN_N=0      # how many runs this menu has started (names the exit-code file of each)
UI_PCT=0 UI_LABEL=""
UI_H=22 UI_W=76
declare -gA ANSWERS=()

# --- the answers file (R33) ------------------------------------------------------------------------------------

ANSWER_KEYS=" action vm ct ctid hostname memory cores privileged start continue "

# answer_valid <key> <value>: the same rules the command line applies to the same things.
answer_valid() {
  case $1 in
    action) [[ $2 =~ ^(scan|preflight|inspect|convert|undo|cleanup)$ ]] ;;
    vm) vmid_valid "$2" ;;
    ct | ctid) [[ $2 =~ $RE_CTID ]] ;;
    hostname) [[ $2 =~ $RE_CT_NAME ]] ;;
    memory) [[ $2 =~ ^[0-9]{2,6}$ ]] ;;
    cores) [[ $2 =~ ^[0-9]{1,3}$ ]] ;;
    privileged | start | continue) [[ $2 =~ ^(yes|no)$ ]] ;;
    *) return 1 ;;
  esac
}

# answers_load <file>: strict parse into ANSWERS, or die (64). The file is DATA: it is never sourced or eval'd,
# only whitelisted keys are taken, every value is validated, a duplicate is an error, and it must be a small
# regular file that nobody else can write (it chooses the VM and the container id of a root-run conversion).
answers_load() {
  local f=$1 line key val mode owner size lineno=0 l2
  [[ -f $f && -r $f ]] || die "$EXIT_USAGE" "--answers: '$f' is not a readable file"
  size=$(stat -L -c %s -- "$f" 2>/dev/null) || die "$EXIT_USAGE" "--answers: cannot stat '$f'"
  ((size <= 4096)) || die "$EXIT_USAGE" "--answers: '$f' is larger than 4 KiB: not an answers file"
  mode=$(stat -L -c %a -- "$f") owner=$(stat -L -c %u -- "$f")
  if ((8#$mode & 8#022)); then
    die "$EXIT_USAGE" "--answers: '$f' is writable by group or others (mode $mode): refusing, it decides what runs as root"
  fi
  [[ $owner == "$EUID" || $owner == 0 ]] || die "$EXIT_USAGE" "--answers: '$f' is owned by uid $owner, not by you or root"
  ANSWERS=()
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    l2=${line//$'\t'/ }
    [[ $l2 != *[[:cntrl:]]* ]] || die "$EXIT_USAGE" "--answers: line $lineno has a control character"
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n $line && $line != '#'* ]] || continue
    [[ $line =~ ^([a-z]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || die "$EXIT_USAGE" "--answers: line $lineno is not 'key=value'"
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    [[ $ANSWER_KEYS == *" $key "* ]] || die "$EXIT_USAGE" "--answers: line $lineno: unknown key '$key' (allowed:${ANSWER_KEYS% })"
    [[ -z ${ANSWERS[$key]+x} ]] || die "$EXIT_USAGE" "--answers: line $lineno: '$key' is given twice"
    answer_valid "$key" "$val" || die "$EXIT_USAGE" "--answers: line $lineno: '$val' is not a valid value for $key"
    ANSWERS[$key]=$val
  done <"$f"
  return 0
}

# --- choosing the backend ---------------------------------------------------------------------------------------

# ui_interactive: a person is at a terminal. VM2LXC_UI_TTY=1|0 forces it (the tests' seam).
ui_interactive() {
  case ${VM2LXC_UI_TTY:-auto} in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [[ -t 0 && -t 1 ]]
}

# ui_term_ok: whiptail needs a real terminal that is big enough, or it prints "window too small" and quits.
ui_term_ok() {
  [[ ${VM2LXC_UI_TTY:-} == 1 ]] && return 0
  [[ ${TERM:-dumb} != dumb ]] || return 1
  local rows cols
  read -r rows cols < <(stty size </dev/tty 2>/dev/null) || return 1
  [[ $rows =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] && ((rows >= 18 && cols >= 72))
}

ui_cleanup() {
  if [[ -n $UI_TMP ]]; then
    scratch_free "$UI_TMP" || printf 'vm2lxc: left the scratch directory %s (it holds something the menu did not put there)\n' "$UI_TMP" >&2
  fi
}

# ui_init: pick the backend and make the private scratch directory (R32, R36). Refuses, never guesses: with no
# terminal and no answers file there is nobody to ask, and the menu must not hang or default into an action.
ui_init() {
  if [[ -n $OPT_ANSWERS ]]; then
    answers_load "$OPT_ANSWERS"
    UI_BACKEND=answers
  elif ! ui_interactive; then
    die "$EXIT_USAGE" "the menu needs a terminal (or --answers FILE for an unattended run). Nothing was changed."
  elif ((!OPT_NO_TUI)) && command -v whiptail >/dev/null 2>&1 && ui_term_ok; then
    UI_BACKEND=whiptail
  else
    UI_BACKEND=plain
  fi
  UI_TMP=$(scratch_new) || die "$EXIT_ENV" "cannot make a scratch directory in ${TMPDIR:-/tmp}"
  trap ui_cleanup EXIT
}

# --- low-level helpers ------------------------------------------------------------------------------------------

# whiptail writes the selection to stderr and draws on stdout: swap them so $(...) captures the selection.
ui_wt() { whiptail --backtitle "$UI_BACKTITLE" "$@" 3>&1 1>&2 2>&3; }

# A word that starts with '-' would be read as an option by whiptail's argument parser: never let one through (R34).
ui_safe() {
  if [[ $1 == -* ]]; then printf ' %s' "$1"; else printf '%s' "$1"; fi
}

ui_read() { # <prompt>: REPLY, rc 1 at end of input. The prompt goes to stderr and is always shown.
  printf '%s' "$1" >&2
  IFS= read -r REPLY || return 1
  REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
  REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

ui_dims() { # the biggest text box that fits the terminal
  local r c
  if read -r r c < <(stty size </dev/tty 2>/dev/null) && [[ $r =~ ^[0-9]+$ && $c =~ ^[0-9]+$ ]] && ((r > 10 && c > 30)); then
    UI_H=$((r - 4)) UI_W=$((c - 4))
  else
    UI_H=22 UI_W=76
  fi
}

# --- asking ------------------------------------------------------------------------------------------------------

# ui_menu <title> <text> <default-tag> <tag> <description> [<tag> <description> ...]  -> REPLY = the tag
ui_menu() {
  local title=$1 text=$2 def=$3 i n rc=0 choice defidx=1
  shift 3
  local -a tags=() descs=() items=()
  while (($# >= 2)); do
    tags+=("$1") descs+=("$2")
    shift 2
  done
  n=${#tags[@]}
  case $UI_BACKEND in
    whiptail)
      for i in "${!tags[@]}"; do items+=("${tags[$i]}" "$(ui_safe "${descs[$i]}")"); done
      REPLY=$(ui_wt --title " $title" --default-item "$def" --menu " $text" 0 0 "$((n > 14 ? 14 : n))" "${items[@]}") || rc=$?
      ((rc == 0)) || return 1
      return 0
      ;;
    *)
      printf '\n== %s ==\n%s\n' "$title" "$text"
      for i in "${!tags[@]}"; do
        printf ' %2d) %s\n' "$((i + 1))" "${descs[$i]}"
        if [[ ${tags[$i]} == "$def" ]]; then defidx=$((i + 1)); fi
      done
      while :; do
        ui_read "Choose 1-$n [$defidx]   (b = back, q = quit): " || {
          UI_QUIT=1
          return 2
        }
        choice=${REPLY:-$defidx}
        case $choice in
          b | B) return 1 ;;
          q | Q)
            UI_QUIT=1
            return 2
            ;;
        esac
        if [[ $choice =~ ^[0-9]{1,4}$ ]]; then
          choice=$((10#$choice))
          if ((choice >= 1 && choice <= n)); then
            REPLY=${tags[$((choice - 1))]}
            return 0
          fi
        fi
        printf 'Please type a number from 1 to %d, b or q.\n' "$n" >&2
      done
      ;;
  esac
}

# ui_input <title> <text> <default> <validator-function> <error-text>  -> REPLY. Asks again until valid.
ui_input() {
  local title=$1 text=$2 def=$3 validator=$4 err=$5 rc val
  [[ $def != -* ]] || def=""
  while :; do
    rc=0
    case $UI_BACKEND in
      whiptail)
        REPLY=$(ui_wt --title " $title" --inputbox " $text" 0 0 "$def") || rc=$?
        ((rc == 0)) || return 1
        ;;
      *)
        ui_read "$text [$def]  (! = back): " || {
          UI_QUIT=1
          return 2
        }
        [[ $REPLY != '!' ]] || return 1
        [[ -n $REPLY ]] || REPLY=$def
        ;;
    esac
    val=$REPLY
    if "$validator" "$val"; then
      REPLY=$val
      return 0
    fi
    ui_msg "Not usable" "$err"
  done
}

# ui_yesno <title> <text> <yes|no: the default>  -> rc 0 only for an explicit yes; Esc, No, the end of input = not confirmed
ui_yesno() {
  local rc=0
  local -a opt=()
  [[ $3 == yes ]] || opt=(--defaultno)
  case $UI_BACKEND in
    whiptail)
      ui_wt --title " $1" "${opt[@]}" --yesno " $2" 0 0 || rc=$?
      ((rc == 0)) || return 1
      return 0
      ;;
    *)
      printf '\n%s\n' "$2"
      ui_read "$1 [$([[ $3 == yes ]] && echo Y/n || echo y/N)]: " || {
        UI_QUIT=1
        return 2
      }
      case ${REPLY,,} in
        y | yes) return 0 ;;
        n | no) return 1 ;;
        '') [[ $3 == yes ]] && return 0 || return 1 ;;
      esac
      return 1
      ;;
  esac
}

ui_msg() { # <title> <text>
  case $UI_BACKEND in
    whiptail) ui_wt --title " $1" --msgbox " $2" 0 0 || true ;;
    *)
      printf '\n%s\n' "$2"
      ui_read "Press Enter to continue " || true
      ;;
  esac
  return 0
}

ui_text() { # <title> <file>: show a file, scrollable, nothing to answer
  case $UI_BACKEND in
    whiptail)
      ui_dims
      ui_wt --title " $1" --scrolltext --textbox "$2" "$UI_H" "$UI_W" || true
      ;;
    *)
      printf '\n== %s ==\n' "$1"
      cat -- "$2"
      ui_read "Press Enter to continue " || true
      ;;
  esac
  return 0
}

# --- progress (the engine writes the lines; see progress_emit in lib/common.sh) --------------------------------

# ui_kind_label <step-kind> [undo]: what a step is called to a person. In the teardown and undo stages a step is
# being UNDONE, so it reads the other way round: undoing "vm-stop" is starting the VM again.
ui_kind_label() {
  if [[ ${2:-} == undo ]]; then
    case $1 in
      vm-stop) printf 'Starting the VM again' ;;
      vm-onboot) printf "Restoring the VM's autostart" ;;
      lvm-snapshot | zfs-snapshot) printf 'Removing the snapshot' ;;
      zfs-clone) printf 'Removing the clone' ;;
      lvm-activate) printf 'Deactivating the snapshot' ;;
      loop-attach) printf 'Detaching the loop device' ;;
      dev-ready) printf 'Releasing the device' ;;
      mount-disk | mount) printf 'Unmounting' ;;
      stage-dir) printf 'Removing the staging directory' ;;
      tar-create) printf 'Removing the staged archive' ;;
      ct-create) printf 'Destroying the container' ;;
      ct-mount | ct-unmount) printf 'Unmounting the container' ;;
      ct-fixup | ct-copy-disk) printf 'Cleaning up the container copy' ;;
      ct-start) printf 'Stopping the container' ;;
      *) printf 'Undoing (%s)' "$1" ;;
    esac
    return 0
  fi
  case $1 in
    vm-stop) printf 'Stopping the VM (stop-and-copy)' ;;
    vm-onboot) printf "Turning off the VM's autostart" ;;
    lvm-snapshot | zfs-snapshot) printf 'Snapshotting a disk' ;;
    zfs-clone) printf 'Cloning a snapshot' ;;
    lvm-activate) printf 'Activating the snapshot' ;;
    loop-attach) printf 'Attaching it read-only' ;;
    dev-ready) printf 'Waiting for the device' ;;
    mount-disk) printf 'Mounting it read-only' ;;
    guest-checks) printf 'Running the guest checks' ;;
    scan) printf 'Looking at a VM' ;;
    stage-dir) printf 'Making the staging directory' ;;
    tar-create) printf 'Archiving the guest filesystem' ;;
    ct-create) printf 'Creating the container' ;;
    ct-mount) printf 'Mounting the container' ;;
    ct-fixup) printf "Fixing the container's config" ;;
    ct-copy-disk) printf 'Copying an extra disk' ;;
    ct-unmount) printf 'Unmounting the container' ;;
    ct-start) printf 'Starting the container' ;;
    *) printf 'Working (%s)' "$1" ;;
  esac
}

# ui_stage_range <action> <stage>: where in 0..100 that stage sits, "base span". rc 1 for a stage the action does not have.
ui_stage_range() {
  case $1:$2 in
    convert:mount) printf '0 30' ;;
    convert:checks) printf '30 10' ;;
    convert:build) printf '40 45' ;;
    convert:teardown) printf '85 15' ;;
    inspect:mount) printf '0 60' ;;
    inspect:checks) printf '60 20' ;;
    inspect:teardown) printf '80 20' ;;
    scan:look) printf '0 100' ;;
    undo:undo) printf '0 100' ;;
    cleanup:teardown) printf '0 100' ;;
    *) return 1 ;;
  esac
}

# ui_progress_parse <action> <line>: UI_PCT and UI_LABEL from one progress line, rc 1 for anything that is not a
# well-formed line of ours. The file is written by the engine, but it is still parsed strictly: no eval, no trust (R36).
ui_progress_parse() {
  local tag stage i n kind range base span
  IFS=$'\t' read -r tag stage i n kind <<<"$2"
  [[ $tag == P && $stage =~ ^[a-z]{3,10}$ && $i =~ ^[0-9]{1,6}$ && $n =~ ^[0-9]{1,6}$ && $kind =~ ^[a-z][a-z-]{1,30}$ ]] || return 1
  i=$((10#$i)) n=$((10#$n))
  ((n >= 1 && i >= 1 && i <= n)) || return 1
  range=$(ui_stage_range "$1" "$stage") || return 1
  read -r base span <<<"$range"
  UI_PCT=$((base + span * (i - 1) / n))
  case $stage in
    teardown | undo) UI_LABEL="$(ui_kind_label "$kind" undo) ($i of $n)" ;;
    *) UI_LABEL="$(ui_kind_label "$kind") ($i of $n)" ;;
  esac
}

# new lines of the progress file, as they appear, as gauge frames for whiptail. Ends when the engine's exit code file appears.
ui_gauge_feed() { # <action> <progress file> <rc file>
  local action=$1 prog=$2 rcf=$3 seen=0 maxpct=0 label="Starting ..." line finished=0
  local -a lines
  while :; do
    if [[ -e $rcf ]]; then finished=1; fi # look for the end FIRST, then read: nothing written before it is missed
    mapfile -t lines < <(tail -n +$((seen + 1)) "$prog" 2>/dev/null)
    for line in "${lines[@]}"; do
      seen=$((seen + 1))
      if ui_progress_parse "$action" "$line"; then
        if ((UI_PCT > maxpct)); then maxpct=$UI_PCT; fi
        label=$UI_LABEL
      fi
    done
    printf 'XXX\n%d\n %s\nXXX\n' "$maxpct" "$label"
    if ((finished)); then break; fi
    sleep 0.2
  done
  printf 'XXX\n100\n Finished\nXXX\n'
}

ui_plain_feed() { # <action> <progress file> <rc file>: one line per step, for a plain terminal or a log
  local action=$1 prog=$2 rcf=$3 seen=0 line finished=0
  local -a lines
  while :; do
    if [[ -e $rcf ]]; then finished=1; fi
    mapfile -t lines < <(tail -n +$((seen + 1)) "$prog" 2>/dev/null)
    for line in "${lines[@]}"; do
      seen=$((seen + 1))
      if ui_progress_parse "$action" "$line"; then printf '  [%3d%%] %s\n' "$UI_PCT" "$UI_LABEL"; fi
    done
    if ((finished)); then break; fi
    sleep 0.2
  done
}

# ui_run <action> <title> <logfile> -- <vm2lxc args...>: run the SAME binary on the given arguments, its output into
# the log, a progress bar (or plain lines) while it works. The exit code lands in UI_RUN_RC. While it runs Ctrl-C
# must not kill the menu: the engine has its own handler that tears the run down, and the menu waits for it (R35).
ui_run() {
  local action=$1 title=$2 log=$3 prog="$UI_TMP/progress" rcf child
  shift 4
  UI_RUN_N=$((UI_RUN_N + 1))
  rcf="$UI_TMP/rc.$UI_RUN_N" # a fresh name per run: nothing needs removing, and the previous run's file cannot be mistaken
  : >"$prog"
  : >"$log"
  ( # a subshell: the engine is started with the default signal handling, so its own traps work
    set +e
    VM2LXC_PROGRESS_FILE=$prog "$VM2LXC_SELF" "$@" >"$log" 2>&1 </dev/null
    printf '%s\n' "$?" >"$rcf"
  ) &
  child=$!
  trap ':' INT
  case $UI_BACKEND in
    whiptail) ui_gauge_feed "$action" "$prog" "$rcf" | ui_wt --title " $title" --gauge " Starting ..." 7 72 0 || true ;;
    *) ui_plain_feed "$action" "$prog" "$rcf" ;;
  esac
  while [[ ! -e $rcf ]]; do sleep 0.2; done # whiptail may have gone (Ctrl-C): the engine is still finishing its teardown
  wait "$child" 2>/dev/null || true
  trap - INT
  UI_RUN_RC=$(<"$rcf")
  [[ $UI_RUN_RC =~ ^[0-9]{1,3}$ ]] || UI_RUN_RC=70
  return 0
}
