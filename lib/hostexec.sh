# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# The ONLY file that may change anything on the host. Design and rails (R1-R9):
# docs/snapshot-layer.html. In short:
#   * every mutating command goes through host_cmd, an allowlist of exact argument shapes
#   * every object is journalled PENDING *before* it is created, so a crash leaves a trail
#   * teardown works from the journal (never by scanning), re-checks that each object is
#     ours (stamp vm2lxc:run and, for a clone, its origin) and uses no -r, -R, -f or -l
#   * a violation refuses with exit code 77 and leaves the object alone
# Nothing in preflight or scan calls into this file (tests/readonly_guard.bats proves it).

state_dir() { printf '%s' "${VM2LXC_STATE_DIR:-/var/lib/vm2lxc}"; }
# The run root is where we mkdir and mount. Outside the test seam (VM2LXC_TEST_EXEC=1) it is ALWAYS
# /run/vm2lxc: an environment variable must not be able to point our mounts at /var/lib or /etc.
run_root() {
  if [[ ${VM2LXC_TEST_EXEC:-} == 1 ]]; then
    printf '%s' "${VM2LXC_RUN_ROOT:-/run/vm2lxc}"
  else
    printf '%s' /run/vm2lxc
  fi
}

# A refusal prints and RETURNS 77. Callers propagate it (`|| return $?`) so that it is not
# lost inside a command substitution the way an `exit` would be.
refuse() {
  printf 'vm2lxc: REFUSED (safety rail): %s\n' "$*" >&2
  return "$EXIT_REFUSED"
}

# --- names we will ever touch (R1) ------------------------------------------------------
_ZN='[A-Za-z0-9_][A-Za-z0-9_.:-]*'
RE_Z_SNAP="^(${_ZN}(/${_ZN})+)@vm2lxc-([a-z][a-z0-9]{3,30})\$"                  # 3 = run
RE_Z_CLONE="^${_ZN}(/${_ZN})*/vm2lxc-[0-9]+-([a-z][a-z0-9]{3,30})-[a-z]+[0-9]+\$" # 2 = run
RE_Z_ANY='^[A-Za-z0-9_./:@-]+$'
RE_DEV_OURS='^/dev/zvol/[A-Za-z0-9_./:-]+/vm2lxc-[0-9]+-[a-z][a-z0-9]{3,30}-[a-z]+[0-9]+(-part[0-9]+)?$'
RE_ZD='^(/dev/zd[0-9]+)(p[0-9]+)?$'

RE_LV_SNAP='^([A-Za-z0-9_+][A-Za-z0-9_+.-]*)/vm2lxc-([0-9]+)-([a-z][a-z0-9]{3,30})-([a-z]+[0-9]+)$' # 1 vg 2 vmid 3 run 4 key
RE_LV_NAME='^vm2lxc-[0-9]+-([a-z][a-z0-9]{3,30})-[a-z]+[0-9]+$'                            # 1 run
RE_LV_ORIGIN='^[A-Za-z0-9_+][A-Za-z0-9_+.-]*/[A-Za-z0-9_+][A-Za-z0-9_+.-]*$'
RE_DEV_LVSNAP='^/dev/[A-Za-z0-9_+][A-Za-z0-9_+.-]*/vm2lxc-[0-9]+-[a-z][a-z0-9]{3,30}-[a-z]+[0-9]+$'
RE_LOOP='^(/dev/loop[0-9]+)(p[0-9]+)?$'

# Loop devices this process attached, or found via `losetup -j <our snapshot device>`.
OURS_LOOPS=()
OURS_ZDS=() # kernel names (/dev/zdN) of the zvol clones we made: the real lsblk prints those, not /dev/zvol/...
declare -gA LOOP_DEV=()

zd_is_ours() { # /dev/zdN or /dev/zdNpM
  local z
  [[ $1 =~ $RE_ZD ]] || return 1
  for z in "${OURS_ZDS[@]}"; do
    [[ $z == "${BASH_REMATCH[1]}" ]] && return 0
  done
  return 1
}

# readlink -f, with the input echoed back when it cannot be resolved (and overridable in tests).
dev_realpath() { readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"; }

loop_is_ours() { # /dev/loopN or /dev/loopNpM
  local base l
  [[ $1 =~ $RE_LOOP ]] || return 1
  base=${BASH_REMATCH[1]}
  for l in "${OURS_LOOPS[@]}"; do
    [[ $l == "$base" ]] && return 0
  done
  return 1
}

# The run root must itself be a sane absolute path at least two levels deep (/run/vm2lxc),
# never "/" or "/etc": everything we mkdir or mount lives beneath it.
RE_RUN_ROOT='^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$'
hc_under_runroot() {
  local rr
  rr=$(run_root)
  [[ $rr =~ $RE_RUN_ROOT && $rr != *..* && $1 == "$rr"/* && $1 != *..* ]]
}

# --- host_cmd: the one door (R6) ------------------------------------------------------------
# Validates the argument SHAPE of every command we are willing to run, then runs it.
hc_zfs() {
  local verb=${1:-} run n
  case $verb in
    snapshot)
      [[ $# -ge 4 && $2 == -o && $3 == vm2lxc:run=* ]] || {
        refuse "zfs snapshot: unexpected arguments"
        return
      }
      run=${3#vm2lxc:run=}
      shift 3
      for n in "$@"; do
        [[ $n =~ $RE_Z_SNAP && ${BASH_REMATCH[3]} == "$run" ]] || {
          refuse "zfs snapshot: '$n' is not a vm2lxc snapshot of run '$run'"
          return
        }
      done
      ;;
    clone)
      [[ $# -eq 7 && $2 == -o && $3 == readonly=on && $4 == -o && $5 == vm2lxc:run=* ]] || {
        refuse "zfs clone: unexpected arguments (a clone must be readonly=on and stamped)"
        return
      }
      run=${5#vm2lxc:run=}
      [[ $6 =~ $RE_Z_SNAP && ${BASH_REMATCH[3]} == "$run" ]] || {
        refuse "zfs clone: '$6' is not a vm2lxc snapshot of run '$run'"
        return
      }
      [[ $7 =~ $RE_Z_CLONE && ${BASH_REMATCH[2]} == "$run" ]] || {
        refuse "zfs clone: '$7' is not a vm2lxc clone name of run '$run'"
        return
      }
      ;;
    destroy)
      # exactly one argument: no -r, -R, -f, -n, -p or anything else
      if [[ $# -ne 2 ]] || ! { [[ $2 =~ $RE_Z_SNAP ]] || [[ $2 =~ $RE_Z_CLONE ]]; }; then
        refuse "zfs destroy: only a vm2lxc snapshot or clone, with no flags (got: $*)"
        return
      fi
      ;;
    list) # list -H -o name -t <snapshot|volume> <name>
      [[ $# -eq 7 && $2 == -H && $3 == -o && $4 == name && $5 == -t && ($6 == snapshot || $6 == volume) &&
        $7 =~ $RE_Z_ANY && $7 != -* ]] || {
        refuse "zfs list: unexpected arguments"
        return
      }
      ;;
    get)
      # the stamp must be set LOCALLY: a value inherited from a parent dataset is not proof of ownership
      if [[ $# -eq 8 && $2 == -H && $3 == -o && $4 == value && $5 == -s && $6 == local && $7 == vm2lxc:run &&
        $8 =~ $RE_Z_ANY && $8 != -* ]]; then
        :
      elif [[ $# -eq 6 && $2 == -H && $3 == -o && $4 == value && $5 == origin && $6 =~ $RE_Z_ANY && $6 != -* ]]; then
        :
      else
        refuse "zfs get: unexpected arguments"
        return
      fi
      ;;
    *)
      refuse "zfs ${verb:-<none>}: not on the allowlist"
      return
      ;;
  esac
  return 0
}

hc_mount() {
  local opts fs dev mnt
  [[ $# -eq 6 && $1 == -o && $3 == -t ]] || {
    refuse "mount: unexpected arguments"
    return
  }
  opts=$2 fs=$4 dev=$5 mnt=$6
  case $fs in ext2 | ext3 | ext4 | xfs | btrfs) ;; *)
    refuse "mount: filesystem '$fs' is not on the allowlist"
    return
    ;;
  esac
  # The options must be EXACTLY the read-only set we chose for this filesystem. "Contains ro and
  # not rw" would let remount, bind, loop or X-mount.* options through.
  [[ $opts == "$(mount_opts_for "$fs")" ]] || {
    refuse "mount: options '$opts' are not the exact read-only set for $fs"
    return
  }
  if [[ $dev == *..* ]] || ! { [[ $dev =~ $RE_DEV_OURS ]] || loop_is_ours "$dev" || zd_is_ours "$dev"; }; then
    refuse "mount: '$dev' is not one of our clone, zvol or loop devices"
    return
  fi
  hc_under_runroot "$mnt" || {
    refuse "mount: '$mnt' is not under $(run_root)"
    return
  }
  return 0
}

hc_lvm() {
  local verb=${1:-} run
  case $verb in
    lvs) # lvs --noheadings --separator | -o lv_name,lv_tags,origin,lv_attr <vg>
      [[ $# -eq 7 && $2 == --noheadings && $3 == --separator && $4 == '|' && $5 == -o &&
        $6 == lv_name,lv_tags,origin,lv_attr && $7 =~ ^[A-Za-z0-9_+][A-Za-z0-9_+.-]*$ ]] || {
        refuse "lvs: unexpected arguments"
        return
      }
      ;;
    lvcreate) # lvcreate -s -n <snaplv> --addtag vm2lxc-<run> <vg>/<origin>
      [[ $# -eq 7 && $2 == -s && $3 == -n && $5 == --addtag && $4 =~ $RE_LV_NAME ]] || {
        refuse "lvcreate: only 'lvcreate -s -n <vm2lxc-name> --addtag vm2lxc-<run> <vg>/<lv>'"
        return
      }
      run=${BASH_REMATCH[1]}
      [[ $6 == "vm2lxc-$run" && $7 =~ $RE_LV_ORIGIN && ${7#*/} != vm2lxc-* ]] || {
        refuse "lvcreate: tag or origin not acceptable (tag '$6', origin '$7')"
        return
      }
      ;;
    lvchange)
      if [[ $# -eq 3 && $2 == -pr && $3 =~ $RE_LV_SNAP ]]; then
        :
      elif [[ $# -eq 4 && $2 == -ay && $3 == -K && $4 =~ $RE_LV_SNAP ]]; then
        :
      else
        refuse "lvchange: only '-pr' or '-ay -K' on a vm2lxc snapshot LV (got: $*)"
        return
      fi
      ;;
    lvremove) # exactly: lvremove -y <our snapshot LV>. Never -f.
      [[ $# -eq 3 && $2 == -y && $3 =~ $RE_LV_SNAP ]] || {
        refuse "lvremove: only 'lvremove -y <vg>/vm2lxc-...' (got: $*)"
        return
      }
      ;;
    *)
      refuse "${verb:-<none>}: not on the allowlist"
      return
      ;;
  esac
  return 0
}

hc_losetup() {
  if [[ $# -eq 5 && $1 == -r && $2 == -f && $3 == --show && $4 == -P && $5 =~ $RE_DEV_LVSNAP ]]; then
    return 0
  elif [[ $# -eq 2 && $1 == -j && $2 =~ $RE_DEV_LVSNAP ]]; then
    return 0
  elif [[ $# -eq 2 && $1 == -d && $2 =~ ^/dev/loop[0-9]+$ ]] && loop_is_ours "$2"; then
    return 0
  fi
  refuse "losetup: only attach/list on our snapshot device, or detach of a loop we own (got: $*)"
}

host_cmd() {
  local bin=${1:-} b p
  shift || true
  case $bin in
    zfs) hc_zfs "$@" ;;
    mount) hc_mount "$@" ;;
    lvs | lvcreate | lvchange | lvremove) hc_lvm "$bin" "$@" ;;
    losetup) hc_losetup "$@" ;;
    umount)
      [[ $# -eq 1 ]] && hc_under_runroot "$1" || refuse "umount: only one path under $(run_root), no flags (got: $*)"
      ;;
    mountpoint)
      [[ $# -eq 2 && $1 == -q ]] && hc_under_runroot "$2" || refuse "mountpoint: unexpected arguments"
      ;;
    mkdir)
      [[ $# -eq 2 && $1 == -p ]] && hc_under_runroot "$2" || refuse "mkdir: only 'mkdir -p' under $(run_root)"
      ;;
    rmdir) # rmdir only removes EMPTY directories, so allowing the run root itself is safe
      [[ $# -eq 1 ]] && { hc_under_runroot "$1" || { [[ $1 == "$(run_root)" ]] && hc_under_runroot "$1/x"; }; } ||
        refuse "rmdir: only one path under $(run_root)"
      ;;
    lsblk) # lsblk -P -n -p -o NAME,FSTYPE,TYPE <dev>: -P prints KEY="value" pairs, so empty fields cannot shift columns
      [[ $# -eq 6 && $1 == -P && $2 == -n && $3 == -p && $4 == -o && $5 == NAME,FSTYPE,TYPE && $6 == /dev/* && $6 != *..* ]] ||
        refuse "lsblk: unexpected arguments"
      ;;
    udevadm)
      [[ $# -eq 2 && $1 == settle && $2 =~ ^--timeout=[0-9]+$ ]] || refuse "udevadm: only 'settle --timeout=N'"
      ;;
    *) refuse "$bin: not on the allowlist" ;;
  esac || return $?
  # The tools must come from a system directory. Outside the test seam a hostile PATH must not be
  # able to substitute its own zfs, lvremove or mount.
  if [[ ${VM2LXC_TEST_EXEC:-} != 1 ]]; then
    for b in timeout "$bin"; do
      p=$(command -v -- "$b" 2>/dev/null) || p=""
      [[ $p =~ ^/(usr/)?s?bin/[^/]+$ ]] || {
        refuse "$b resolves to '${p:-nothing}', not a system directory: PATH is not trusted"
        return
      }
    done
  fi
  # Children must not inherit our lock fd or the saved stdout/stderr (found on the first real
  # run: LVM warns about every leaked descriptor, and a long-lived child holding the lock fd
  # would keep the lock after we exit). So close them, in a subshell, before the exec.
  (
    local fd
    for fd in "${LOCK_FD:-}" "${INSPECT_OUT_FD:-}" "${INSPECT_ERR_FD:-}"; do
      # shellcheck disable=SC2294  # eval of a validated integer: "exec 10>&-"
      if [[ $fd =~ ^[0-9]+$ ]] && ((fd > 2)); then eval "exec $fd>&-"; fi
    done
    # A hung storage command (LVM lock contention is real) must not wedge the run and its
    # teardown: `kill -TERM` on us is deferred until the foreground child exits. So every
    # command is bounded. --foreground keeps it in our process group so Ctrl-C still reaches it.
    local limit=${VM2LXC_CMD_TIMEOUT:-120}
    [[ $limit =~ ^[0-9]+$ ]] || limit=120
    LVM_SUPPRESS_FD_WARNINGS=1 exec timeout --foreground --kill-after=5 "$limit" "$bin" "$@"
  ) </dev/null
}

# zfs_exists <name>: rc 0 exists, 1 ABSENT, 3 or more = an error to propagate.
# Only the message "does not exist" counts as absent: real `zfs list` also exits 1 for a suspended
# pool or a module problem, and treating that as "gone" would mark a live object UNDONE.
zfs_exists() {
  local t=volume out rc=0
  [[ $1 == *@* ]] && t=snapshot
  out=$(host_cmd zfs list -H -o name -t "$t" "$1" 2>&1) || rc=$?
  case $rc in
    0) return 0 ;;
    1)
      if [[ $out == *"does not exist"* ]]; then return 1; fi
      printf '%s\n' "$out" >&2
      return 3
      ;;
    *)
      printf '%s\n' "$out" >&2
      return "$rc"
      ;;
  esac
}

# --- journal ---------------------------------------------------------------------------------
JOURNAL="" J_SEQ=0 LAST_SEQ=0 RUN_ID="" RUN_VMID=""
JL_N=0 JL_CLOSED=0
STEP_FOREIGN=0 # set by a handler that refused because the object ALREADY existed (R9)
JL_KIND=() JL_ARGS=() JL_STATE=()

journal_unwritable() {
  printf 'vm2lxc: the journal %s cannot be written: refusing to continue with a step that would not be recorded\n' "${JOURNAL:-?}" >&2
}

journal_new() { # <vmid> <run>
  local d
  d="$(state_dir)/runs/$2"
  (umask 077 && mkdir -p "$d") || return 1
  JOURNAL="$d/journal"
  if [[ -e $JOURNAL ]]; then
    refuse "a journal for run $2 already exists"
    return
  fi
  (umask 077 && printf '# vm2lxc journal v1\nRUN\t%s\t%s\t%s\n' "$2" "$1" "$(date +%s)" >"$JOURNAL") || return 1
  # fsync the file AND its directories: a power cut must not lose the journal of a snapshot that survives
  sync "$JOURNAL" "$d" "$(state_dir)/runs" 2>/dev/null || true
  J_SEQ=0
  RUN_ID=$2
  RUN_VMID=$1
}

# journal_step <kind> [args...]: write-ahead. rc 1 if the step could NOT be recorded; the caller must
# then not perform it. The new sequence number is in LAST_SEQ. An argument that is empty or contains a
# tab or newline would shift fields on reading (tab is IFS whitespace), so it is refused up front.
journal_step() {
  local kind=$1 a
  shift
  [[ $kind =~ ^[a-z][a-z-]*$ ]] || return 1
  for a in "$@"; do
    [[ -n $a && $a != *[$'\t\n\r']* ]] || {
      printf 'vm2lxc: journal: refusing an empty or tab/newline argument for step %s\n' "$kind" >&2
      return 1
    }
  done
  J_SEQ=$((J_SEQ + 1))
  LAST_SEQ=$J_SEQ
  {
    printf 'STEP\t%d\t%s' "$J_SEQ" "$kind" || return 1
    if (($# > 0)); then printf '\t%s' "$@" || return 1; fi
    printf '\nST\t%d\tPENDING\n' "$J_SEQ" || return 1
  } >>"$JOURNAL" || return 1
  sync "$JOURNAL" 2>/dev/null || true
}

journal_mark() { # <seq> <PENDING|DONE|UNDONE|FAILED|FOREIGN>   rc 1 if it could not be written
  printf 'ST\t%d\t%s\n' "$1" "$2" >>"$JOURNAL" || return 1
  sync "$JOURNAL" 2>/dev/null || true
}

journal_close() { # rc 1 if it could not be written: the journal is then NOT closed
  printf 'CLOSED\n' >>"$JOURNAL" || return 1
  sync "$JOURNAL" 2>/dev/null || true
}

# journal_load <run>: fills JL_* (latest ST line wins), RUN_ID, RUN_VMID, JOURNAL.
# The file is data we do not fully trust (a restored backup, a hand edit): every field is validated
# BEFORE it is used, because a sequence number like `x[$(cmd)]` would otherwise run `cmd` as an
# arithmetic subscript.
journal_load() {
  local f a b c rest bad=0
  [[ $1 =~ ^[a-z][a-z0-9]{3,30}$ ]] || return 1
  f="$(state_dir)/runs/$1/journal"
  [[ -r $f ]] || return 1
  JL_N=0 JL_CLOSED=0
  JL_KIND=() JL_ARGS=() JL_STATE=()
  RUN_ID=$1 RUN_VMID="" JOURNAL=$f
  while IFS=$'\t' read -r a b c rest; do
    case $a in
      RUN)
        if [[ $c =~ ^[0-9]+$ ]]; then RUN_VMID=$c; else bad=$((bad + 1)); fi
        ;;
      STEP)
        if [[ $b =~ ^[0-9]{1,6}$ && $c =~ ^[a-z][a-z-]*$ ]]; then
          b=$((10#$b))
          JL_KIND[b]=$c
          JL_ARGS[b]=$rest
          JL_STATE[b]=PENDING
          if ((b > JL_N)); then JL_N=$b; fi
        else
          bad=$((bad + 1))
        fi
        ;;
      ST)
        if [[ $b =~ ^[0-9]{1,6}$ && $c =~ ^(PENDING|DONE|UNDONE|FAILED|FOREIGN)$ ]]; then
          b=$((10#$b))
          JL_STATE[b]=$c
        else
          bad=$((bad + 1))
        fi
        ;;
      CLOSED) JL_CLOSED=1 ;;
    esac
  done <"$f"
  if ((bad > 0)); then
    printf 'vm2lxc: journal %s: ignored %d malformed line(s)\n' "$1" "$bad" >&2
  fi
  return 0
}

# runs_open: ids of runs whose journal is not CLOSED.
runs_open() {
  local d
  shopt -s nullglob
  for d in "$(state_dir)"/runs/*/; do
    [[ -f ${d}journal ]] || continue
    if ! grep -q '^CLOSED$' "${d}journal"; then
      basename "$d"
    fi
  done
  shopt -u nullglob
}

LOCK_FD=""
lock_acquire() {
  mkdir -p "$(state_dir)" || return 1
  exec {LOCK_FD}>"$(state_dir)/lock" || return 1
  flock -n "$LOCK_FD" || {
    exec {LOCK_FD}>&-
    return 1
  }
}

# --- do handlers -----------------------------------------------------------------------------
MOUNTS=() SKIPPED=() MOUNT_NOTES=()

mount_opts_for() { # fstype -> options on stdout, rc 1 if we do not mount it
  case $1 in
    ext2 | ext3 | ext4) printf 'ro,noload,nodev,nosuid,noexec' ;;
    xfs) printf 'ro,norecovery,nouuid,nodev,nosuid,noexec' ;;
    btrfs) printf 'ro,nodev,nosuid,noexec' ;;
    *) return 1 ;;
  esac
}

# lv_exists <vg/lv>: rc 0 found (LV_TAGS, LV_ORIGIN, LV_ATTR set), 1 absent, else an error.
LV_TAGS="" LV_ORIGIN="" LV_ATTR=""
lv_exists() {
  local vg=${1%%/*} want=${1#*/} listing name tags origin attr
  listing=$(host_cmd lvs --noheadings --separator '|' -o lv_name,lv_tags,origin,lv_attr "$vg") || return $?
  while IFS='|' read -r name tags origin attr; do
    name=${name//[[:space:]]/}
    [[ $name == "$want" ]] || continue
    LV_TAGS=${tags//[[:space:]]/}
    LV_ORIGIN=${origin//[[:space:]]/}
    LV_ATTR=${attr//[[:space:]]/}
    return 0
  done <<<"$listing"
  return 1
}

act_do_lvm_snapshot() { # <vg/lv> <vg/snaplv> <run>
  local origin=$1 snap=$2 run=$3 rc=0
  lv_exists "$snap" || rc=$?
  case $rc in
    0)
      STEP_FOREIGN=1
      refuse "LV $snap already exists (it will not be adopted)"
      return
      ;;
    1) ;;
    *) return "$rc" ;;
  esac
  rc=0
  lv_exists "$origin" || rc=$?
  if ((rc == 1)); then
    printf 'vm2lxc: the origin LV %s does not exist\n' "$origin" >&2
    return 1
  elif ((rc != 0)); then
    return "$rc"
  fi
  host_cmd lvcreate -s -n "${snap#*/}" --addtag "vm2lxc-$run" "$origin" || return $?
  host_cmd lvchange -pr "$snap"
}

act_do_lvm_activate() { # <vg/snaplv>
  host_cmd lvchange -ay -K "$1"
}

act_do_loop_attach() { # </dev/vg/snaplv> <key>
  local dev=$1 key=$2 out
  out=$(host_cmd losetup -j "$dev") || return $?
  if [[ -n $out ]]; then
    STEP_FOREIGN=1
    refuse "a loop device is already attached to $dev: $out"
    return
  fi
  out=$(host_cmd losetup -r -f --show -P "$dev") || return $?
  if [[ ! $out =~ ^/dev/loop[0-9]+$ ]]; then
    printf 'vm2lxc: unexpected output from losetup: %s\n' "$out" >&2
    return 1
  fi
  LOOP_DEV[$key]=$out
  OURS_LOOPS+=("$out")
  host_cmd udevadm settle --timeout=30 >/dev/null 2>&1 || true
  return 0
}

act_do_zfs_snapshot() { # <snapname> <ds1,ds2,...>
  local snapname=$1 dsl=$2 run ds rc
  local -a dss names=()
  run=${snapname#vm2lxc-}
  IFS=, read -ra dss <<<"$dsl"
  for ds in "${dss[@]}"; do
    rc=0
    zfs_exists "$ds@$snapname" || rc=$?
    case $rc in
      0)
        STEP_FOREIGN=1
        refuse "snapshot $ds@$snapname already exists (it will not be adopted)"
        return
        ;;
      1) ;;
      *) return "$rc" ;;
    esac
    names+=("$ds@$snapname")
  done
  host_cmd zfs snapshot -o "vm2lxc:run=$run" "${names[@]}"
}

act_do_zfs_clone() { # <ds@snap> <clone> <key>
  local snap=$1 clone=$2 run rc=0
  run=${snap##*@vm2lxc-}
  zfs_exists "$clone" || rc=$?
  case $rc in
    0)
      STEP_FOREIGN=1
      refuse "clone $clone already exists (it will not be adopted)"
      return
      ;;
    1) ;;
    *) return "$rc" ;;
  esac
  host_cmd zfs clone -o readonly=on -o "vm2lxc:run=$run" "$snap" "$clone"
}

act_do_dev_ready() { # <device> <key>
  local dev=$1 tries=${VM2LXC_WAIT_TRIES:-30} nap=${VM2LXC_WAIT_SLEEP:-1} n=0 rc=0 real
  host_cmd udevadm settle --timeout=30 >/dev/null 2>&1 || rc=$?
  if ((rc == EXIT_REFUSED)); then return "$rc"; fi
  while ((n < tries)); do
    rc=0
    host_cmd lsblk -P -n -p -o NAME,FSTYPE,TYPE "$dev" >/dev/null 2>&1 || rc=$?
    if ((rc == 0)); then
      # The real lsblk prints KERNEL names for a zvol (/dev/zd16, /dev/zd16p1), not the /dev/zvol path
      # it was given. Remember which zd device is the clone we just made, so those names are ours.
      real=$(dev_realpath "$dev")
      if [[ $real =~ ^/dev/zd[0-9]+$ ]]; then OURS_ZDS+=("$real"); fi
      return 0
    fi
    if ((rc == EXIT_REFUSED)); then return "$rc"; fi
    n=$((n + 1))
    sleep "$nap"
  done
  printf 'vm2lxc: device %s did not appear after %d tries\n' "$dev" "$tries" >&2
  return 1
}

act_do_mount_disk() { # <device> <key> <target>
  local dev=$1 key=$2 target=$3 out line name fstype ltype opts mnt seq n_mounted=0 rc nested=0
  local re='^NAME="([^"]*)" FSTYPE="([^"]*)" TYPE="([^"]*)"$'
  if [[ $dev == loop:* ]]; then
    dev=${LOOP_DEV[${dev#loop:}]:-}
    if [[ -z $dev ]]; then
      printf 'vm2lxc: no loop device was attached for disk %s\n' "$key" >&2
      return 1
    fi
  fi
  out=$(host_cmd lsblk -P -n -p -o NAME,FSTYPE,TYPE "$dev") || return $?
  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    name=${BASH_REMATCH[1]} fstype=${BASH_REMATCH[2]} ltype=${BASH_REMATCH[3]}
    # lsblk lists CHILDREN too. If udev auto-activated a guest LVM volume group or md array on one of our
    # partitions, its volumes show up here as /dev/mapper/... or /dev/md*: they are the guest's, not ours.
    case $ltype in
      loop | part | disk) ;;
      *)
        SKIPPED+=("$key|$name|${fstype:--}|a nested $ltype device (a guest LVM or RAID volume that udev activated): not used")
        nested=1
        continue
        ;;
    esac
    [[ -n $fstype ]] || continue # the disk itself, or a partition with no filesystem
    if ! opts=$(mount_opts_for "$fstype"); then
      case $fstype in
        LVM2_member | crypto_LUKS | linux_raid_member)
          SKIPPED+=("$key|$name|$fstype|guest LVM / LUKS / mdraid is not supported yet (needs vgimportclone or an unlock)")
          ;;
        *) SKIPPED+=("$key|$name|$fstype|not a filesystem vm2lxc mounts") ;;
      esac
      continue
    fi
    mnt="$(run_root)/$RUN_ID/$key/${name##*/}"
    journal_step mount "$name" "$mnt" "$fstype" || {
      journal_unwritable
      return 1
    }
    seq=$LAST_SEQ
    rc=0
    host_cmd mkdir -p "$mnt" || rc=$?
    if ((rc == 0)); then host_cmd mount -o "$opts" -t "$fstype" "$name" "$mnt" || rc=$?; fi
    if ((rc != 0)); then
      journal_mark "$seq" FAILED || true
      return "$rc"
    fi
    journal_mark "$seq" DONE || true
    MOUNTS+=("$key|$target|$name|$mnt|$fstype")
    n_mounted=$((n_mounted + 1))
    if [[ $fstype == btrfs ]]; then
      MOUNT_NOTES+=("$name is btrfs: only its default subvolume is visible")
    fi
  done <<<"$out"
  if ((nested)); then
    MOUNT_NOTES+=("disk $key holds a guest LVM or RAID volume that the host activated; it was left alone, but it can keep the partition busy, so teardown may need a retry (vm2lxc cleanup)")
  fi
  if ((n_mounted == 0)); then
    MOUNT_NOTES+=("disk $key: no supported filesystem was found on $dev")
  fi
  return 0
}

# --- undo handlers (idempotent; each re-checks that the object is ours: R3) -------------
act_undo_zfs_snapshot() { # <snapname> <ds1,ds2,...>
  local snapname=$1 dsl=$2 run snap ds rc stamp final=0
  local -a dss
  run=${snapname#vm2lxc-}
  IFS=, read -ra dss <<<"$dsl"
  for ds in "${dss[@]}"; do
    snap="$ds@$snapname"
    rc=0
    zfs_exists "$snap" || rc=$?
    case $rc in
      0) ;;
      1) continue ;;
      *)
        final=$rc
        continue
        ;;
    esac
    stamp=$(host_cmd zfs get -H -o value -s local vm2lxc:run "$snap") || {
      final=$?
      continue
    }
    if [[ $stamp != "$run" ]]; then
      refuse "snapshot $snap exists but its vm2lxc:run stamp is '$stamp', not '$run': left alone" || final=$?
      continue
    fi
    host_cmd zfs destroy "$snap" || final=$?
  done
  return "$final"
}

act_undo_zfs_clone() { # <ds@snap> <clone> <key>
  local snap=$1 clone=$2 run rc=0 stamp origin
  run=${snap##*@vm2lxc-}
  zfs_exists "$clone" || rc=$?
  case $rc in
    0) ;;
    1) return 0 ;;
    *) return "$rc" ;;
  esac
  stamp=$(host_cmd zfs get -H -o value -s local vm2lxc:run "$clone") || return $?
  if [[ $stamp != "$run" ]]; then
    refuse "clone $clone exists but its vm2lxc:run stamp is '$stamp', not '$run': left alone"
    return
  fi
  origin=$(host_cmd zfs get -H -o value origin "$clone") || return $?
  if [[ $origin != "$snap" ]]; then
    refuse "clone $clone has origin '$origin', not the recorded snapshot '$snap': left alone"
    return
  fi
  host_cmd zfs destroy "$clone"
}

act_undo_dev_ready() { return 0; }
act_undo_lvm_activate() { return 0; } # lvremove deactivates

act_undo_loop_attach() { # </dev/vg/snaplv> <key>
  # `losetup -j` selects by the backing device itself (not by a printed name), so every
  # loop it lists is attached to OUR snapshot device. That is the identity check.
  local dev=$1 out line loopdev rc=0 final=0
  [[ $dev =~ $RE_DEV_LVSNAP ]] || {
    refuse "loop-attach undo: '$dev' is not one of our snapshot devices"
    return
  }
  # If the snapshot LV is gone, nothing can be attached to it. If we cannot tell, that is an ERROR,
  # not "absent": marking the step UNDONE on a failed probe would hide a live loop device for good.
  lv_exists "${dev#/dev/}" || rc=$?
  case $rc in
    0) ;;
    1) return 0 ;;
    *) return "$rc" ;;
  esac
  rc=0
  out=$(host_cmd losetup -j "$dev") || rc=$?
  if ((rc != 0)); then return "$rc"; fi
  [[ -n $out ]] || return 0
  while IFS= read -r line; do
    loopdev=${line%%:*}
    [[ $loopdev =~ ^/dev/loop[0-9]+$ ]] || continue
    OURS_LOOPS+=("$loopdev")
    host_cmd losetup -d "$loopdev" || final=$?
  done <<<"$out"
  return "$final"
}

act_undo_lvm_snapshot() { # <vg/lv> <vg/snaplv> <run>
  local origin=$1 snap=$2 run=$3 rc=0 nap=${VM2LXC_WAIT_SLEEP:-1} n=0
  lv_exists "$snap" || rc=$?
  case $rc in
    0) ;;
    1) return 0 ;;
    *) return "$rc" ;;
  esac
  if [[ ",$LV_TAGS," != *",vm2lxc-$run,"* ]]; then
    refuse "LV $snap exists but is not tagged vm2lxc-$run (tags: '$LV_TAGS'): left alone"
    return
  fi
  if [[ $LV_ORIGIN != "${origin#*/}" ]]; then
    refuse "LV $snap has origin '$LV_ORIGIN', not the recorded '${origin#*/}': left alone"
    return
  fi
  # The device may still be open for a moment after the loop device was detached.
  while ((n < 5)); do
    rc=0
    host_cmd lvremove -y "$snap" >/dev/null || rc=$?
    if ((rc == 0 || rc == EXIT_REFUSED)); then return "$rc"; fi
    n=$((n + 1))
    sleep "$nap"
  done
  return "$rc"
}
act_undo_mount_disk() { return 0; }

act_undo_mount() { # <device> <mountpoint> <fstype>
  local mnt=$2 rc=0
  host_cmd mountpoint -q "$mnt" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) host_cmd umount "$mnt" || return $? ;;
    1) ;; # the directory exists and is not a mountpoint: nothing to unmount
    32)
      # util-linux uses 32 for "cannot stat it". A missing directory means nothing is mounted there;
      # a directory that exists but cannot be examined is an ERROR, not "unmounted".
      if [[ -e $mnt ]]; then return "$rc"; fi
      ;;
    *) return "$rc" ;; # a refusal (77), a timeout (124), anything else: never assume "not mounted"
  esac
  host_cmd rmdir "$mnt" 2>/dev/null || true
  host_cmd rmdir "${mnt%/*}" 2>/dev/null || true
  return 0
}

# --- apply and teardown ---------------------------------------------------------------------
# run_apply: execute PLAN, journalling every step PENDING before it runs.
run_apply() {
  local line kind rc seq
  local -a f
  MOUNTS=() SKIPPED=() MOUNT_NOTES=()
  for line in "${PLAN[@]}"; do
    IFS='|' read -ra f <<<"$line"
    kind=${f[0]}
    journal_step "$kind" "${f[@]:1}" || {
      journal_unwritable
      return 1
    }
    seq=$LAST_SEQ
    rc=0
    STEP_FOREIGN=0
    "act_do_${kind//-/_}" "${f[@]:1}" || rc=$?
    if ((rc != 0)); then
      # A pre-existing object is not ours: record that, so teardown can never destroy it.
      if ((STEP_FOREIGN)); then journal_mark "$seq" FOREIGN || true; else journal_mark "$seq" FAILED || true; fi
      return "$rc"
    fi
    journal_mark "$seq" DONE || true # if this is lost the step stays PENDING, which teardown handles
  done
}

# run_teardown <run>: undo the journal in reverse. Safe to run twice, safe after a crash.
# rc 0 only when everything is gone and the journal is CLOSED; otherwise the journal stays
# open so that `vm2lxc cleanup` can finish the job.
run_teardown() {
  local run=$1 n kind state rc final=0 jfail=0
  local -a args
  journal_load "$run" || {
    printf 'vm2lxc: no journal for run %s\n' "$run" >&2
    return 1
  }
  if ((JL_CLOSED)); then return 0; fi
  for ((n = JL_N; n >= 1; n--)); do
    kind=${JL_KIND[$n]:-}
    state=${JL_STATE[$n]:-}
    [[ -n $kind && $state != UNDONE && $state != FOREIGN ]] || continue
    if ! declare -F "act_undo_${kind//-/_}" >/dev/null; then
      refuse "journal step $n has an unknown kind '$kind': left alone" || final=$?
      continue
    fi
    IFS=$'\t' read -ra args <<<"${JL_ARGS[$n]}"
    rc=0
    "act_undo_${kind//-/_}" "${args[@]}" || rc=$?
    if ((rc == 0)); then
      journal_mark "$n" UNDONE || jfail=1
    else
      # STOP at the first failure. The steps below this one are what it sits on (a mount sits
      # on a loop device or a clone, which sits on a snapshot): destroying them while it is
      # still there would be wrong. They stay in the journal for the next cleanup run.
      final=$rc
      printf 'vm2lxc: could not undo step %d (%s), rc=%d. Stopping here; %d earlier step(s) are left for "vm2lxc cleanup".\n' \
        "$n" "$kind" "$rc" "$((n - 1))" >&2
      break
    fi
  done
  if ((final == 0)); then
    host_cmd rmdir "$(run_root)/$run" 2>/dev/null || true
    host_cmd rmdir "$(run_root)" 2>/dev/null || true # the base dir, if no other run is using it
    if ((jfail)) || ! journal_close; then
      printf 'vm2lxc: everything was undone but the journal %s could not be updated: it stays open (cleanup is safe to repeat)\n' "$JOURNAL" >&2
      final=1
    fi
  fi
  return "$final"
}
