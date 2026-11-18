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
# --- conversion roots (convert/undo) ---------------------------------------------------------------
# Where the staged tarballs live and where Proxmox mounts a container's rootfs. Like the run root,
# both are fixed outside the test seam: an environment variable must not move them.
RE_CTID='^[1-9][0-9]{2,8}$'
CT_ID="" CT_PRIV=0 CT_MAPBASE=100000 # the container this run creates, bound into the allowlist

stage_root() {
  if [[ ${VM2LXC_TEST_EXEC:-} == 1 ]]; then printf '%s' "${VM2LXC_STAGE_ROOT:-/var/tmp/vm2lxc}"; else printf '%s' /var/tmp/vm2lxc; fi
}
ct_base() {
  if [[ ${VM2LXC_TEST_EXEC:-} == 1 ]]; then printf '%s' "${VM2LXC_CT_ROOT:-/var/lib/lxc}"; else printf '%s' /var/lib/lxc; fi
}
ct_root() { printf '%s/%s/rootfs' "$(ct_base)" "$1"; }

# the staging directory of THIS run, or a staged tarball inside it
hc_under_stage() {
  local rr
  rr=$(stage_root)
  [[ $rr =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ && -n ${RUN_ID:-} && $1 != *..* ]] || return 1
  [[ $1 == "$rr/$RUN_ID" ]] && return 0
  [[ $1 == "$rr/$RUN_ID/"* && ${1#"$rr/$RUN_ID/"} =~ ^(rootfs|mp[0-9]+)\.tar$ ]]
}

# a path at or below the rootfs of OUR container (never anywhere else, never with '..')
hc_under_ctroot() {
  local cr
  [[ $CT_ID =~ $RE_CTID ]] || return 1
  cr=$(ct_root "$CT_ID")
  [[ $1 != *..* && $1 =~ ^[A-Za-z0-9._/@+:=,-]+$ ]] || return 1
  [[ $1 == "$cr" || $1 == "$cr/"* ]]
}

RE_CT_NAME='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
RE_STORAGE_SIZE='^[A-Za-z0-9][A-Za-z0-9_.-]*:[0-9]{1,6}$'
RE_CT_MP='^[A-Za-z0-9][A-Za-z0-9_.-]*:[0-9]{1,6},mp=/[A-Za-z0-9_./-]*$'
RE_CT_NET='^name=[A-Za-z0-9_.-]{1,15},bridge=[A-Za-z0-9_.-]{1,15},hwaddr=([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2},type=veth(,tag=[0-9]{1,4})?(,firewall=[01])?$'
RE_CT_TAGS='^[A-Za-z0-9_.;-]{1,300}$'
RE_CT_DESC='^[A-Za-z0-9 _.,:=()/-]{1,300}$'
RE_OSTYPE='^(unmanaged|debian|ubuntu|devuan|alpine|archlinux|fedora|centos|opensuse|gentoo|nixos)$'

# netplan, as cloud-init writes it, matches the NIC by its PERMANENT MAC (match: / macaddress: / set-name:). A
# veth has no permanent MAC, so systemd-networkd calls the link "unmanaged" and never brings it up (found on a
# real Debian 12 cloud image). Remove exactly that shape: the interface key (eth0:) then matches by name.
# `match:` is only deleted together with a `macaddress:` line directly under it; nothing else is touched.
SED_NETPLAN_EXPR='/^[[:space:]]*match:[[:space:]]*$/{N;/\n[[:space:]]*macaddress:[[:space:]]*"?[0-9A-Fa-f:]+"?[[:space:]]*$/d};/^[[:space:]]*set-name:[[:space:]]*"?[A-Za-z0-9_.-]+"?[[:space:]]*$/d'

# The one fstab edit: comment out the lines that name the VM's disks. Everything else is untouched.
SED_FSTAB_EXPR='/^[[:space:]]*(#|$)/!{/^[[:space:]]*(UUID=|LABEL=|PARTUUID=|PARTLABEL=|\/dev\/)/s/^/#vm2lxc# /}'

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

# --- validators for the conversion commands ------------------------------------------------------------
# Every one of them is bound to the VM or container of THIS run (RUN_VMID, CT_ID, RUN_ID): a command
# naming any other VM or container, or any other path, is refused before it runs.

hc_qm() { # qm status|start <vmid>  |  shutdown <vmid> --timeout N  |  set <vmid> --onboot 0|1
  local sub=${1:-} id=${2:-}
  [[ $id =~ ^[0-9]+$ && $id == "${RUN_VMID:-x}" ]] || {
    refuse "qm: '$id' is not the VM of this run"
    return
  }
  case $sub in
    status | start) [[ $# -eq 2 ]] || refuse "qm $sub: unexpected arguments" ;;
    shutdown) [[ $# -eq 4 && $3 == --timeout && $4 =~ ^[0-9]{1,3}$ ]] || refuse "qm shutdown: only '--timeout N'" ;;
    set) [[ $# -eq 4 && $3 == --onboot && $4 =~ ^[01]$ ]] || refuse "qm set: only '--onboot 0|1'" ;;
    *) refuse "qm $sub: not on the allowlist" ;;
  esac
}

hc_pct() { # pct status|config|mount|unmount|start|stop <ct>  |  shutdown <ct> --timeout N  |  destroy <ct> --purge  |  create ...
  local sub=${1:-} id=${2:-}
  [[ $id =~ $RE_CTID && $id == "${CT_ID:-x}" ]] || {
    refuse "pct: '$id' is not the container of this run"
    return
  }
  case $sub in
    status | config | mount | unmount | start | stop) [[ $# -eq 2 ]] || refuse "pct $sub: unexpected arguments" ;;
    shutdown) [[ $# -eq 4 && $3 == --timeout && $4 =~ ^[0-9]{1,3}$ ]] || refuse "pct shutdown: only '--timeout N'" ;;
    destroy) [[ $# -eq 3 && $3 == --purge ]] || refuse "pct destroy: only '--purge'" ;;
    create) hc_pct_create "$@" ;;
    *) refuse "pct $sub: not on the allowlist" ;;
  esac
}

# pct create <ct> <staged rootfs tarball> <option> <value> ...: every option from a fixed set, every value
# against its own pattern. The container is always created stopped, never to start at boot.
hc_pct_create() {
  local opt val
  shift 2 # the sub-command and the (already checked) id
  if (($# < 1)) || [[ $1 != "$(stage_root)/${RUN_ID:-x}/rootfs.tar" ]] || ! hc_under_stage "$1"; then
    refuse "pct create: the archive must be this run's staged rootfs.tar"
    return
  fi
  shift
  (($# % 2 == 0)) || {
    refuse "pct create: options come in '--name value' pairs"
    return
  }
  while (($# > 0)); do
    opt=$1 val=$2
    shift 2
    case $opt in
      --hostname) [[ $val =~ $RE_CT_NAME ]] ;;
      --memory) [[ $val =~ ^[0-9]{2,6}$ ]] ;;
      --cores) [[ $val =~ ^[0-9]{1,3}$ ]] ;;
      --swap) [[ $val =~ ^[0-9]{1,6}$ ]] ;;
      --rootfs) [[ $val =~ $RE_STORAGE_SIZE ]] ;;
      --mp[0-9] | --mp[0-9][0-9]) [[ $val =~ $RE_CT_MP && $val != *..* ]] ;;
      --net[0-9] | --net[0-9][0-9]) [[ $val =~ $RE_CT_NET ]] ;;
      --unprivileged) [[ $val =~ ^[01]$ ]] ;;
      --ostype) [[ $val =~ $RE_OSTYPE ]] ;;
      --onboot | --start) [[ $val == 0 ]] ;;
      --arch) [[ $val == amd64 ]] ;;
      --features) [[ $val == nesting=1 ]] ;;
      --tags) [[ $val =~ $RE_CT_TAGS ]] ;;
      --description) [[ $val =~ $RE_CT_DESC ]] ;;
      *)
        refuse "pct create: option '$opt' is not on the allowlist"
        return
        ;;
    esac || {
      refuse "pct create: the value of $opt is not acceptable"
      return
    }
  done
}

# tar --numeric-owner --xattrs --acls --one-file-system -cpf <staged tarball> -C <mounted guest fs> .
#     reads the guest, writes only the staged tarball
# tar --numeric-owner --xattrs --acls --exclude=./lost+found -xpf <staged tarball> -C <a verified mount point in our container>
#     (the destination volume already has its own lost+found, owned by real root: an unprivileged user
#     namespace may not touch it, so the source's is never extracted over it. Found on a real host.)
hc_tar() {
  if [[ $# -eq 9 && $1 == --numeric-owner && $2 == --xattrs && $3 == --acls && $4 == --one-file-system &&
    $5 == -cpf && $7 == -C && $9 == . ]] && hc_under_stage "$6" && [[ $6 == *.tar ]] && hc_under_runroot "$8"; then
    return 0
  fi
  if [[ $# -eq 8 && $1 == --numeric-owner && $2 == --xattrs && $3 == --acls && $4 == --exclude=./lost+found &&
    $5 == -xpf && $7 == -C ]] && hc_under_stage "$6" && [[ $6 == *.tar ]] && hc_under_ctroot "$8"; then
    return 0
  fi
  refuse "tar: only the staged create form and the verified extract form (got: $*)"
}

# blkid -s UUID|LABEL -o value <one of our devices>: reads the filesystem id of a mounted clone
hc_blkid() {
  if [[ $# -ne 5 || $1 != -s || ! ($2 == UUID || $2 == LABEL) || $3 != -o || $4 != value ]]; then
    refuse "blkid: only 'blkid -s UUID|LABEL -o value <device>'"
    return
  fi
  if [[ $5 == *..* ]] || ! { [[ $5 =~ $RE_DEV_OURS ]] || loop_is_ours "$5" || zd_is_ours "$5"; }; then
    refuse "blkid: '$5' is not one of our devices"
  fi
}

# The edits made to the container's root filesystem. Every path is under OUR container's rootfs and
# was resolved chroot-style by the caller; the tools and their flags are fixed.
#   sed -i -E <the fstab or the netplan expression> <file>
#   cp -p --remove-destination <file> <file>.vm2lxc-orig
#   touch <file>         ln -sfn /dev/null <file>
hc_ctedit() {
  local tool=$1 ok=0
  shift
  case $tool in
    sed) [[ $# -eq 4 && $1 == -i && $2 == -E && ($3 == "$SED_FSTAB_EXPR" || $3 == "$SED_NETPLAN_EXPR") ]] &&
      hc_under_ctroot "$4" && ok=1 ;;
    cp) [[ $# -eq 4 && $1 == -p && $2 == --remove-destination && $4 == "$3.vm2lxc-orig" ]] &&
      hc_under_ctroot "$3" && hc_under_ctroot "$4" && ok=1 ;;
    touch) [[ $# -eq 1 ]] && hc_under_ctroot "$1" && ok=1 ;;
    ln) [[ $# -eq 3 && $1 == -sfn && $2 == /dev/null && $3 == */etc/systemd/system/* ]] && hc_under_ctroot "$3" && ok=1 ;;
  esac
  ((ok)) || refuse "$tool: not an allowed container edit (got: $*)"
}

# lxc-usernsexec -m u:0:<base>:65536 -m g:0:<base>:65536 -- <an allowed edit or extract>
hc_usernsexec() {
  local base
  [[ $# -ge 6 && $1 == -m && $3 == -m && $5 == -- ]] || {
    refuse "lxc-usernsexec: unexpected arguments"
    return
  }
  [[ $2 =~ ^u:0:([0-9]{5,10}):65536$ ]] || {
    refuse "lxc-usernsexec: bad uid map"
    return
  }
  base=${BASH_REMATCH[1]}
  [[ $4 == "g:0:$base:65536" && $base == "$CT_MAPBASE" ]] || {
    refuse "lxc-usernsexec: the maps must be the container's id map"
    return
  }
  shift 5
  case $1 in
    tar) hc_tar "${@:2}" ;;
    sed | cp | touch | ln) hc_ctedit "$@" ;;
    *) refuse "lxc-usernsexec: '$1' is not an allowed command" ;;
  esac
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
      [[ $# -eq 2 && $1 == -q ]] && { hc_under_runroot "$2" || hc_under_ctroot "$2"; } || refuse "mountpoint: unexpected arguments"
      ;;
    mkdir)
      [[ $# -eq 2 && $1 == -p ]] && { hc_under_runroot "$2" || hc_under_stage "$2"; } ||
        refuse "mkdir: only 'mkdir -p' under $(run_root) or this run's staging directory"
      ;;
    rmdir) # rmdir only removes EMPTY directories, so allowing the roots themselves is safe
      [[ $# -eq 1 ]] && { hc_under_runroot "$1" || hc_under_stage "$1" ||
        { [[ $1 == "$(run_root)" ]] && hc_under_runroot "$1/x"; } ||
        { [[ $1 == "$(stage_root)" ]] && hc_under_stage "$1/$RUN_ID"; }; } ||
        refuse "rmdir: only one path under $(run_root) or the staging directory"
      ;;
    rm) # only a staged tarball of this run, never a directory, never a glob
      [[ $# -eq 3 && $1 == -f && $2 == -- ]] && hc_under_stage "$3" && [[ $3 == *.tar ]] ||
        refuse "rm: only 'rm -f -- <staged tarball of this run>'"
      ;;
    qm) hc_qm "$@" ;;
    pct) hc_pct "$@" ;;
    tar) hc_tar "$@" ;;
    blkid) hc_blkid "$@" ;;
    sed | cp | touch | ln) hc_ctedit "$bin" "$@" ;;
    lxc-usernsexec) hc_usernsexec "$@" ;;
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
    # copying a guest and creating its container legitimately take longer than a storage command; still bounded
    case "$bin ${1:-}" in
      "tar "* | "pct create" | "lxc-usernsexec "* | "pct start" | "pct destroy" | "pct stop")
        local long=${VM2LXC_LONG_TIMEOUT:-7200}
        [[ $long =~ ^[0-9]+$ ]] && ((long > limit && long <= 86400)) && limit=$long
        ;;
    esac
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

# COMMITTED: the conversion succeeded. Steps marked KEPT (the container, the VM's stopped state) stay;
# everything else is torn down as usual. `undo` later undoes the KEPT steps and closes the journal.
journal_commit() {
  printf 'COMMITTED\n' >>"$JOURNAL" || return 1
  sync "$JOURNAL" 2>/dev/null || true
}

journal_ct() { # <ctid>: which container this run creates, so cleanup and undo can find it again
  printf 'CT\t%s\n' "$1" >>"$JOURNAL" || return 1
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
  JL_N=0 JL_CLOSED=0 JL_COMMITTED=0 JL_CT=""
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
        if [[ $b =~ ^[0-9]{1,6}$ && $c =~ ^(PENDING|DONE|UNDONE|FAILED|FOREIGN|KEPT)$ ]]; then
          b=$((10#$b))
          JL_STATE[b]=$c
        else
          bad=$((bad + 1))
        fi
        ;;
      CLOSED) JL_CLOSED=1 ;;
      COMMITTED) JL_COMMITTED=1 ;;
      CT)
        if [[ $b =~ $RE_CTID ]]; then JL_CT=$b; else bad=$((bad + 1)); fi
        ;;
    esac
  done <"$f"
  # the container of a run is bound into the allowlist as soon as its journal is read
  if [[ -n $JL_CT ]]; then CT_ID=$JL_CT; fi
  if ((bad > 0)); then
    printf 'vm2lxc: journal %s: ignored %d malformed line(s)\n' "$1" "$bad" >&2
  fi
  return 0
}

# runs_open: ids of runs whose journal is not CLOSED.
runs_open() {
  local d r n
  shopt -s nullglob
  for d in "$(state_dir)"/runs/*/; do
    [[ -f ${d}journal ]] || continue
    grep -q '^CLOSED$' "${d}journal" && continue
    r=$(basename "$d")
    if grep -q '^COMMITTED$' "${d}journal"; then
      # a committed conversion is finished work, not a crash: only list it if something other than the
      # kept container/VM state is still pending (a teardown that was cut short)
      journal_load "$r" 2>/dev/null || continue
      local pending=0
      for ((n = 1; n <= JL_N; n++)); do
        [[ -n ${JL_KIND[$n]:-} && ${JL_STATE[$n]:-} != UNDONE && ${JL_STATE[$n]:-} != FOREIGN && ${JL_STATE[$n]:-} != KEPT ]] && pending=1
      done
      ((pending)) || continue
    fi
    printf '%s\n' "$r"
  done
  shopt -u nullglob
}

# committed_run_for_ct <ctid>: the run id of the open committed conversion that created this container.
committed_run_for_ct() {
  local d r
  [[ $1 =~ $RE_CTID ]] || return 1
  shopt -s nullglob
  for d in "$(state_dir)"/runs/*/; do
    [[ -f ${d}journal ]] || continue
    grep -q '^CLOSED$' "${d}journal" && continue
    grep -q '^COMMITTED$' "${d}journal" || continue
    grep -qx $'CT\t'"$1" "${d}journal" || continue
    r=$(basename "$d")
    shopt -u nullglob
    printf '%s' "$r"
    return 0
  done
  shopt -u nullglob
  return 1
}

# runs_committed: ids of the runs whose conversion is committed and not yet undone (what `undo` can act on).
runs_committed() {
  local d
  shopt -s nullglob
  for d in "$(state_dir)"/runs/*/; do
    [[ -f ${d}journal ]] || continue
    grep -q '^CLOSED$' "${d}journal" && continue
    grep -q '^COMMITTED$' "${d}journal" || continue
    basename "$d"
  done
  shopt -u nullglob
}

# --- the menu's scratch directory (R36) ------------------------------------------------------------------------
# The menu keeps its plans, logs and progress file in a private directory. Making and removing it is the one thing
# the menu does that is not a read, so it lives here with the other audited changes, not in the menu's own files.

# scratch_new: make <tmp>/vm2lxc-menu.XXXXXX (mode 700) and print its path
scratch_new() {
  local base=${TMPDIR:-/tmp}
  (umask 077 && mktemp -d "${base%/}/vm2lxc-menu.XXXXXX")
}

# scratch_free <dir>: remove a scratch directory. Only a directory named like the ones scratch_new makes, directly under
# the temp directory, owned by us, not a symlink, and holding nothing but plain files: anything else is left alone
# (rc 1). Files one by one, no glob handed to rm, no recursion. `command -p` so a PATH that shadows rm is not trusted.
scratch_free() {
  local d=$1 base=${TMPDIR:-/tmp} f
  local -a files
  [[ $d == "${base%/}"/vm2lxc-menu.?????? && -d $d && ! -L $d && -O $d ]] || return 1
  shopt -s nullglob dotglob
  files=("$d"/*)
  shopt -u nullglob dotglob
  for f in "${files[@]}"; do
    [[ -f $f && ! -L $f ]] || return 1
  done
  for f in "${files[@]}"; do
    command -p rm -f -- "$f" || return 1
  done
  command -p rmdir -- "$d"
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

# --- conversion handlers (convert / undo) -----------------------------------------------------------------
# The same rules as the snapshot handlers: the journal says PENDING before the action runs; an object that
# already exists is never adopted (FOREIGN); identity is re-verified before anything is destroyed.

# vm_status <vmid>: running | stopped | unknown
vm_status() {
  local out
  out=$(host_cmd qm status "$1") || return $?
  case $out in
    *"status: running"*) printf running ;;
    *"status: stopped"*) printf stopped ;;
    *) printf unknown ;;
  esac
}

# ct_state <ctid>: running | stopped | absent | unknown. rc 0 unless the answer could not be had: only the
# exact "does not exist" means absent (the same rule as zfs_exists: "could not tell" is never "gone").
ct_state() {
  local out rc=0
  out=$(host_cmd pct status "$1" 2>&1) || rc=$?
  if ((rc == 0)); then
    case $out in
      *"status: running"*) printf running ;;
      *"status: stopped"*) printf stopped ;;
      *) printf unknown ;;
    esac
    return 0
  fi
  if ((rc != EXIT_REFUSED)) && [[ $out == *"does not exist"* ]]; then
    printf absent
    return 0
  fi
  printf '%s\n' "$out" >&2
  return "$rc"
}

# ct_is_ours <ctid>: rc 0 if the container's tags include THIS run's tag, 1 if not, other = error
ct_is_ours() {
  local cfg
  cfg=$(host_cmd pct config "$1") || return $?
  grep -qE "^tags: (.*[;, ])?vm2lxc-${RUN_ID}([;, ].*)?\$" <<<"$cfg"
}

act_do_vm_stop() { # <vmid> <was-running 0|1> <ctid>: stop-and-copy (D2): the snapshot is then consistent
  local vmid=$1 was=$2 st
  [[ $was == 1 ]] || return 0
  st=$(vm_status "$vmid") || return $?
  [[ $st == running ]] || return 0
  host_cmd qm shutdown "$vmid" --timeout "${VM2LXC_SHUTDOWN_TIMEOUT:-90}" || return $?
  st=$(vm_status "$vmid") || return $?
  if [[ $st != stopped ]]; then
    printf 'vm2lxc: VM %s did not stop\n' "$vmid" >&2
    return 1
  fi
}
act_undo_vm_stop() {
  local vmid=$1 was=$2 ctid=${3:-} st cs
  [[ $was == 1 ]] || return 0
  # Never start the VM while its container runs: that would be two live copies of one machine
  # (one MAC, one IP, and possibly one Tailscale identity).
  if [[ -n $ctid && $ctid == "$CT_ID" ]]; then
    cs=$(ct_state "$ctid") || return $?
    if [[ $cs == running ]]; then
      refuse "container $ctid is running: the VM $vmid will not be started while it does"
      return
    fi
  fi
  st=$(vm_status "$vmid") || return $?
  [[ $st == stopped ]] || return 0
  host_cmd qm start "$vmid"
}

act_do_vm_onboot() { # <vmid> <old>: a VM that autostarts would boot beside its container (D3)
  [[ $2 == 1 ]] || return 0
  host_cmd qm set "$1" --onboot 0
}
act_undo_vm_onboot() {
  [[ $2 == 1 ]] || return 0
  host_cmd qm set "$1" --onboot 1
}

act_do_stage_dir() { host_cmd mkdir -p "$1"; } # <dir>
act_undo_stage_dir() {
  [[ -d $1 ]] || return 0
  host_cmd rmdir "$1" || return $?
  host_cmd rmdir "$(stage_root)" 2>/dev/null || true
}

act_do_tar_create() { # <mounted guest filesystem> <staged tarball>
  host_cmd tar --numeric-owner --xattrs --acls --one-file-system -cpf "$2" -C "$1" .
}
act_undo_tar_create() {
  [[ -e $2 || -L $2 ]] || return 0
  host_cmd rm -f -- "$2"
}

act_do_ct_create() { # <ctid> <staged rootfs.tar> <pct create options...>
  local ctid=$1 tarball=$2 cs
  shift 2
  cs=$(ct_state "$ctid") || return $?
  if [[ $cs != absent ]]; then
    STEP_FOREIGN=1
    refuse "container $ctid already exists (it will not be adopted)"
    return
  fi
  host_cmd pct create "$ctid" "$tarball" "$@"
}
act_undo_ct_create() {
  local ctid=$1 cs rc=0
  cs=$(ct_state "$ctid") || return $?
  [[ $cs == absent ]] && return 0
  ct_is_ours "$ctid" || rc=$?
  if ((rc == 1)); then
    refuse "container $ctid exists but is not tagged vm2lxc-$RUN_ID: left alone"
    return
  elif ((rc != 0)); then
    return "$rc"
  fi
  if [[ $cs == running ]]; then host_cmd pct stop "$ctid" || return $?; fi
  host_cmd pct unmount "$ctid" >/dev/null 2>&1 || true # a container that is not mounted answers with an error
  host_cmd pct destroy "$ctid" --purge
}

act_do_ct_mount() { # <ctid>
  host_cmd pct mount "$1" || return $?
  if [[ ! -d $(ct_root "$1") ]]; then
    printf 'vm2lxc: pct mount succeeded but %s is not a directory\n' "$(ct_root "$1")" >&2
    return 1
  fi
}
act_undo_ct_mount() {
  local cs
  cs=$(ct_state "$1") || return $?
  [[ $cs == absent ]] && return 0
  host_cmd pct unmount "$1" >/dev/null 2>&1 || true
}
act_do_ct_unmount() { host_cmd pct unmount "$1"; } # <ctid>
act_undo_ct_unmount() { return 0; }

# ct_do <priv 0|1> <idmap base> <command...>: an edit INSIDE the container's filesystem. An unprivileged
# container's files belong to shifted ids, so the command runs in the same user namespace the container will
# use (ownership comes out right, and it could not touch a real-root file even by mistake). A privileged one
# is edited directly. The command is a HOST tool, never a binary from the guest.
ct_do() {
  local priv=$1 base=$2
  shift 2
  CT_MAPBASE=$base
  if [[ $priv == 1 ]]; then
    host_cmd "$@"
  else
    host_cmd lxc-usernsexec -m "u:0:$base:65536" -m "g:0:$base:65536" -- "$@"
  fi
}

# The three fix-ups, on the container's COPY (never the VM): the fstab lines that name the VM's disks are
# commented out (a backup stays), cloud-init is disabled so it cannot rewrite network/hostname/keys, and
# the serial getty for a console that does not exist is masked. Every path was resolved chroot-style first.
act_do_ct_fixup() { # <ctid> <priv> <idmap base>
  local ctid=$1 priv=$2 base=$3 root p
  root=$(ct_root "$ctid")
  if [[ ! -d $root ]]; then
    printf 'vm2lxc: the container root %s is not mounted\n' "$root" >&2
    return 1
  fi
  if gfs_is_file "$root" /etc/fstab; then
    p=$GFS_PATH
    ct_do "$priv" "$base" cp -p --remove-destination "$p" "$p.vm2lxc-orig" || return $?
    ct_do "$priv" "$base" sed -i -E "$SED_FSTAB_EXPR" "$p" || return $?
  fi
  if gfs_is_dir "$root" /etc/cloud; then
    # resolved chroot-style including the last component, so even a hostile symlink there stays inside the container
    gfs_resolve "$root" /etc/cloud/cloud-init.disabled || return 1
    if ! ct_do "$priv" "$base" touch "$GFS_PATH"; then
      printf 'vm2lxc: could not create /etc/cloud/cloud-init.disabled in the container (a symlink in the guest points outside it?). Not continuing: cloud-init would rewrite the network on first boot.\n' >&2
      return 1
    fi
  fi
  # netplan files written by cloud-init: see SED_NETPLAN_EXPR. Each file is backed up first.
  if gfs_is_dir "$root" /etc/netplan; then
    local f
    while IFS= read -r f; do
      [[ $f =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || continue
      gfs_resolve "$root" "/etc/netplan/$f" || continue
      [[ -f $GFS_PATH ]] || continue
      p=$GFS_PATH
      ct_do "$priv" "$base" cp -p --remove-destination "$p" "$p.vm2lxc-orig" || return $?
      ct_do "$priv" "$base" sed -i -E "$SED_NETPLAN_EXPR" "$p" || return $?
    done < <(gfs_entries "$root" /etc/netplan)
  fi
  # Units that cannot work in an unprivileged container: the console that does not exist, and the kernel
  # filesystems a container may not mount (they only show up as failed units).
  if gfs_is_dir "$root" /etc/systemd/system; then
    local sys=$GFS_PATH u
    for u in serial-getty@ttyS0.service sys-kernel-config.mount sys-kernel-debug.mount sys-kernel-tracing.mount; do
      ct_do "$priv" "$base" ln -sfn /dev/null "$sys/$u" || return $?
    done
  fi
}
act_undo_ct_fixup() { return 0; } # the edits live in the container, which is destroyed with it

# Extra disks: the data goes into the mount point of the extra VOLUME, never into the root filesystem. The
# mount point is resolved chroot-style and must really be a mount point; a plain directory would mean the
# volume is not mounted there, and writing would silently fill the rootfs.
act_do_ct_copy_disk() { # <ctid> <staged tarball> <mount path in the container> <priv> <idmap base>
  local ctid=$1 tarball=$2 mp=$3 priv=$4 base=$5 root dest
  root=$(ct_root "$ctid")
  CT_MAPBASE=$base
  gfs_resolve "$root" "$mp" || return 1
  dest=$GFS_PATH
  if [[ ! -d $dest ]]; then
    printf 'vm2lxc: the mount point %s does not exist in the container\n' "$mp" >&2
    return 1
  fi
  if ! host_cmd mountpoint -q "$dest"; then
    printf 'vm2lxc: %s is not a mount point (the extra volume is not mounted there): refusing to write into the root filesystem\n' "$mp" >&2
    return 1
  fi
  ct_do "$priv" "$base" tar --numeric-owner --xattrs --acls --exclude=./lost+found -xpf "$tarball" -C "$dest"
}
act_undo_ct_copy_disk() { return 0; }

act_do_ct_start() { # <ctid>: the cutover. The VM is already stopped (stop-and-copy).
  local cs
  host_cmd pct start "$1" || return $?
  cs=$(ct_state "$1") || return $?
  if [[ $cs != running ]]; then
    printf 'vm2lxc: container %s did not reach the running state\n' "$1" >&2
    return 1
  fi
}
act_undo_ct_start() {
  local cs rc=0
  cs=$(ct_state "$1") || return $?
  [[ $cs == running ]] || return 0
  ct_is_ours "$1" || rc=$?
  if ((rc == 1)); then
    refuse "container $1 is not tagged vm2lxc-$RUN_ID: left running, not stopped by us"
    return
  elif ((rc != 0)); then
    return "$rc"
  fi
  host_cmd pct stop "$1"
}

# --- apply and teardown ---------------------------------------------------------------------
# run_apply: execute PLAN, journalling every step PENDING before it runs.
run_apply() { # [keep]: with 'keep' the results of an earlier phase (MOUNTS, SKIPPED, notes) are not reset
  local line kind rc seq i=0 stage=mount total=${#PLAN[@]} # stage: what the menu's progress bar calls this run
  local -a f
  if [[ ${1:-} != keep ]]; then MOUNTS=() SKIPPED=() MOUNT_NOTES=(); else stage=build; fi
  for line in "${PLAN[@]}"; do
    IFS='|' read -ra f <<<"$line"
    kind=${f[0]}
    i=$((i + 1))
    progress_emit "$stage" "$i" "$total" "$kind"
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
  local run=$1 keep=${2:-0} n kind state rc final=0 jfail=0 stage=teardown # keep=1: also undo the KEPT steps (that is `undo`)
  local todo=0 step_i=0
  local -a args
  journal_load "$run" || {
    printf 'vm2lxc: no journal for run %s\n' "$run" >&2
    return 1
  }
  if ((JL_CLOSED)); then return 0; fi
  if [[ $keep == 1 ]]; then stage=undo; fi
  # how many steps this run will actually undo, so the progress bar counts those and not journal positions
  for ((n = JL_N; n >= 1; n--)); do
    state=${JL_STATE[$n]:-}
    [[ -n ${JL_KIND[$n]:-} && $state != UNDONE && $state != FOREIGN ]] || continue
    if [[ $state == KEPT && $keep != 1 ]]; then continue; fi
    todo=$((todo + 1))
  done
  for ((n = JL_N; n >= 1; n--)); do
    kind=${JL_KIND[$n]:-}
    state=${JL_STATE[$n]:-}
    [[ -n $kind && $state != UNDONE && $state != FOREIGN ]] || continue
    if [[ $state == KEPT && $keep != 1 ]]; then continue; fi
    if ! declare -F "act_undo_${kind//-/_}" >/dev/null; then
      refuse "journal step $n has an unknown kind '$kind': left alone" || final=$?
      continue
    fi
    IFS=$'\t' read -ra args <<<"${JL_ARGS[$n]}"
    step_i=$((step_i + 1))
    progress_emit "$stage" "$step_i" "$todo" "$kind"
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
    if ((JL_COMMITTED)) && [[ $keep != 1 ]]; then
      : # a committed conversion stays open (not CLOSED) until `undo` closes it
    elif ((jfail)) || ! journal_close; then
      printf 'vm2lxc: everything was undone but the journal %s could not be updated: it stays open (cleanup is safe to repeat)\n' "$JOURNAL" >&2
      final=1
    fi
  fi
  return "$final"
}
