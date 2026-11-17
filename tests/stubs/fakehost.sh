#!/usr/bin/env bash
# A STATEFUL fake of the storage tools the snapshot layer drives: zfs, lvs, lvcreate,
# lvchange, lvremove, losetup, lsblk, mount, umount, mountpoint, udevadm.
# Installed as symlinks with those names (see tests/hostexec.bats). It remembers what
# exists under $FAKE_STATE, so a test can assert "the source is untouched", "nothing of
# ours is left" and "things were destroyed in the right order" (calls.log keeps the order).
#
#   FAKE_STATE   state directory (required)
#   FAKE_FAIL    comma list of key:N, fail the Nth call of key (key = tool, or zfs.<verb>,
#                or losetup.attach / losetup.detach). Simulates a failure at that step.
#   FAKE_SLEEP_LSBLK  seconds to sleep inside lsblk (so a test can signal a running inspect)
#
# It is stricter than the real tools where that helps catch bugs: `zfs destroy` and `umount`
# reject any flag, `lvremove` insists on exactly `-y <lv>`, `losetup -d` and `lvremove` fail
# while the device is still in use.

name=${0##*/}
S=${FAKE_STATE:?FAKE_STATE not set}
mkdir -p "$S/zfs" "$S/lvm" "$S/loops" "$S/lsblk" "$S/count"
printf '%s %s\n' "$name" "$*" >>"$S/calls.log"

# A child must never inherit the run lock (the executor closes it before every exec).
for _fd in /proc/"$$"/fd/*; do
  case $(readlink "$_fd" 2>/dev/null) in
    */lock) printf 'LEAK %s holds %s\n' "$name" "$(readlink "$_fd")" >>"$S/leaks.log" ;;
  esac
done

enc() {
  local x=${1//\//%2F}
  printf '%s' "${x//@/%40}"
}

maybe_fail() { # key
  local key=$1 n spec
  n=$(($(cat "$S/count/$key" 2>/dev/null || echo 0) + 1))
  printf '%s' "$n" >"$S/count/$key"
  IFS=, read -ra specs <<<"${FAKE_FAIL:-}"
  for spec in "${specs[@]}"; do
    if [[ $spec == "$key:$n" ]]; then
      echo "fake $name: injected failure ($spec)" >&2
      exit 1
    fi
  done
}

zrec() { printf '%s/zfs/%s' "$S" "$(enc "$1")"; }
lrec() { printf '%s/lvm/%s__%s' "$S" "${1%%/*}" "${1#*/}"; }
getp() { # file prop
  sed -n "s/^$2=//p" "$1" | head -1
}

# device -> exists? (rc 0/1) and, for loop devices, the template file to list
dev_exists() {
  local d=$1 base
  case $d in
    /dev/zvol/*)
      base=${d#/dev/zvol/}
      base=${base%-part[0-9]*}
      [[ -f $(zrec "$base") ]]
      ;;
    /dev/loop*)
      base=${d%%p[0-9]*}
      [[ $d =~ ^/dev/loop[0-9]+ ]] && [[ -f $S/loops/${BASH_REMATCH[0]#/dev/loop} ]]
      ;;
    *) return 1 ;;
  esac
}

case $name in
  zfs)
    verb=${1:-}
    maybe_fail "zfs.$verb"
    case $verb in
      snapshot)
        shift
        props=()
        while [[ ${1:-} == -o ]]; do
          props+=("$2")
          shift 2
        done
        for n in "$@"; do
          [[ -f $(zrec "${n%@*}") ]] || {
            echo "cannot open '${n%@*}': dataset does not exist" >&2
            exit 1
          }
          [[ ! -f $(zrec "$n") ]] || {
            echo "cannot create snapshot '$n': dataset already exists" >&2
            exit 1
          }
        done
        for n in "$@"; do
          { echo "kind=snap"; printf '%s\n' "${props[@]}"; } >"$(zrec "$n")"
        done
        ;;
      clone)
        shift
        props=()
        while [[ ${1:-} == -o ]]; do
          props+=("$2")
          shift 2
        done
        snap=$1 clone=$2
        [[ -f $(zrec "$snap") ]] || {
          echo "cannot open '$snap': dataset does not exist" >&2
          exit 1
        }
        [[ ! -f $(zrec "$clone") ]] || {
          echo "cannot create '$clone': dataset already exists" >&2
          exit 1
        }
        { echo "kind=clone"; echo "origin=$snap"; printf '%s\n' "${props[@]}"; } >"$(zrec "$clone")"
        echo "$clone" >>"$(zrec "$snap").clones"
        ;;
      list)
        [[ -f $(zrec "$5") ]] || {
          echo "cannot open '$5': dataset does not exist" >&2
          exit 1
        }
        echo "$5"
        ;;
      get)
        f=$(zrec "$6")
        [[ -f $f ]] || {
          echo "cannot open '$6': dataset does not exist" >&2
          exit 1
        }
        v=$(getp "$f" "$5")
        echo "${v:--}"
        ;;
      destroy)
        shift
        [[ $# -eq 1 && $1 != -* ]] || {
          echo "fake zfs: unsupported flags or arguments to destroy: $*" >&2
          exit 2
        }
        f=$(zrec "$1")
        [[ -f $f ]] || {
          echo "cannot open '$1': dataset does not exist" >&2
          exit 1
        }
        if [[ -s $f.clones ]]; then
          while read -r c; do
            [[ -f $(zrec "$c") ]] && {
              echo "cannot destroy '$1': snapshot has dependent clones" >&2
              exit 1
            }
          done <"$f.clones"
        fi
        origin=$(getp "$f" origin)
        rm -f "$f" "$f.clones"
        [[ -n $origin && -f $(zrec "$origin").clones ]] && sed -i "\#^$1\$#d" "$(zrec "$origin").clones"
        echo "DESTROYED $1" >>"$S/events.log"
        ;;
      *)
        echo "fake zfs: unsupported verb '$verb'" >&2
        exit 2
        ;;
    esac
    ;;

  lvs)
    maybe_fail lvs
    vg=${6:?}
    ls "$S/lvm/${vg}__"* >/dev/null 2>&1 || {
      echo "  Volume group \"$vg\" not found" >&2
      exit 5
    }
    for f in "$S/lvm/${vg}__"*; do
      lv=${f##*"${vg}__"}
      printf '  %s|%s|%s|%s\n' "$lv" "$(getp "$f" tags)" "$(getp "$f" origin)" "$(getp "$f" attr)"
    done
    ;;
  lvcreate)
    maybe_fail lvcreate
    # lvcreate -s -n <snap> --addtag <tag> <vg>/<origin>
    snap=$3 tag=$5 origin=$6 vg=${6%%/*}
    [[ -f $(lrec "$origin") ]] || {
      echo "  Failed to find logical volume \"$origin\"" >&2
      exit 5
    }
    [[ ! -f $(lrec "$vg/$snap") ]] || {
      echo "  Logical Volume \"$snap\" already exists in volume group \"$vg\"" >&2
      exit 5
    }
    printf 'tags=%s\norigin=%s\nattr=Vwi---tz-k\nactive=0\n' "$tag" "${origin#*/}" >"$(lrec "$vg/$snap")"
    ;;
  lvchange)
    maybe_fail lvchange
    if [[ $1 == -pr ]]; then
      f=$(lrec "$2")
      [[ -f $f ]] || exit 5
      sed -i 's/^attr=Vw/attr=Vr/' "$f"
    elif [[ $1 == -ay && $2 == -K ]]; then
      f=$(lrec "$3")
      [[ -f $f ]] || exit 5
      sed -i 's/^active=.*/active=1/' "$f"
    else
      echo "fake lvchange: unsupported arguments: $*" >&2
      exit 2
    fi
    ;;
  lvremove)
    maybe_fail lvremove
    [[ $# -eq 2 && $1 == -y ]] || {
      echo "fake lvremove: unsupported arguments (only '-y <lv>'): $*" >&2
      exit 2
    }
    f=$(lrec "$2")
    [[ -f $f ]] || {
      echo "  Failed to find logical volume \"$2\"" >&2
      exit 5
    }
    for l in "$S"/loops/*; do
      [[ -f $l ]] || continue
      [[ $(cat "$l") == "/dev/$2" ]] && {
        echo "  Logical volume $2 in use." >&2
        exit 5
      }
    done
    rm -f "$f"
    echo "LVREMOVED $2" >>"$S/events.log"
    ;;

  losetup)
    case $1 in
      -r)
        maybe_fail losetup.attach
        dev=$5 lv=${dev#/dev/}
        [[ -f $(lrec "$lv") && $(getp "$(lrec "$lv")" active) == 1 ]] || {
          echo "losetup: $dev: failed to set up loop device: No such file or directory" >&2
          exit 1
        }
        n=0
        while [[ -e $S/loops/$n ]]; do n=$((n + 1)); done
        printf '%s' "$dev" >"$S/loops/$n"
        echo "/dev/loop$n"
        ;;
      -j)
        for l in "$S"/loops/*; do
          [[ -f $l ]] || continue
          [[ $(cat "$l") == "$2" ]] && echo "/dev/loop${l##*/}: [0000]:0 (/dev/dm-0)"
        done
        true
        ;;
      -d)
        maybe_fail losetup.detach
        n=${2#/dev/loop}
        [[ -f $S/loops/$n ]] || {
          echo "losetup: $2: detach failed: No such device" >&2
          exit 1
        }
        grep -q "^$2" "$S/mounts" 2>/dev/null && {
          echo "fake losetup: $2 is still mounted" >&2
          exit 1
        }
        rm -f "$S/loops/$n"
        ;;
      *)
        echo "fake losetup: unsupported arguments: $*" >&2
        exit 2
        ;;
    esac
    ;;

  lsblk)
    maybe_fail lsblk
    [[ -z ${FAKE_SLEEP_LSBLK:-} ]] || sleep "$FAKE_SLEEP_LSBLK"
    dev=$3
    dev_exists "$dev" || {
      echo "lsblk: $dev: not a block device" >&2
      exit 32
    }
    if [[ $dev == /dev/loop* ]]; then
      n=${dev#/dev/loop}
      tpl="$S/lsblk/$(enc "$(cat "$S/loops/$n")")"
      if [[ -f $tpl ]]; then sed "s#@LOOP@#$dev#g" "$tpl"; else echo "$dev"; fi
    else
      tpl="$S/lsblk/$(enc "$dev")"
      if [[ -f $tpl ]]; then cat "$tpl"; else echo "$dev"; fi
    fi
    ;;

  mount)
    maybe_fail mount
    # mount -o <opts> -t <fs> <dev> <mnt>
    opts=$2 fs=$4 dev=$5 mnt=$6
    dev_exists "$dev" || {
      echo "mount: $dev: special device does not exist" >&2
      exit 32
    }
    [[ -d $mnt ]] || {
      echo "mount: $mnt: mount point does not exist" >&2
      exit 32
    }
    [[ ",$opts," == *,ro,* ]] || {
      echo "fake mount: refusing a non-read-only mount ($opts)" >&2
      exit 1
    }
    grep -q "|$mnt|" "$S/mounts" 2>/dev/null && {
      echo "mount: $mnt: already mounted" >&2
      exit 32
    }
    printf '%s|%s|%s|%s\n' "$dev" "$mnt" "$fs" "$opts" >>"$S/mounts"
    if [[ -f $S/rootfs-suffixes ]]; then
      while read -r suf; do
        [[ -n $suf && $dev == *"$suf" ]] && mkdir -p "$mnt/etc" "$mnt/usr" && : >"$mnt/etc/os-release"
      done <"$S/rootfs-suffixes"
    fi
    true
    ;;
  umount)
    maybe_fail umount
    [[ $# -eq 1 && $1 != -* ]] || {
      echo "fake umount: unsupported flags or arguments: $*" >&2
      exit 2
    }
    grep -q "|$1|" "$S/mounts" 2>/dev/null || {
      echo "umount: $1: not mounted." >&2
      exit 32
    }
    grep -v "|$1|" "$S/mounts" >"$S/mounts.new" || true
    mv "$S/mounts.new" "$S/mounts"
    rm -rf "${1:?}/etc" "${1:?}/usr"
    echo "UMOUNTED $1" >>"$S/events.log"
    ;;
  mountpoint)
    [[ $1 == -q ]] || exit 2
    grep -q "|$2|" "$S/mounts" 2>/dev/null
    ;;
  udevadm) exit 0 ;;

  *)
    echo "fakehost: unknown tool name '$name'" >&2
    exit 99
    ;;
esac
