#!/usr/bin/env bash
# Test double for the Proxmox CLIs, used by tests/readonly_guard.bats.
#
# Installed as symlinks named qm, pvesh, pvesm, pveversion (they log the call and serve
# canned output from $STUB_FIXTURES), and also as pct, zfs, mount, rsync, ... (which log
# and REFUSE). Every call is appended to $STUB_LOG, so a test can assert exactly which
# commands vm2lxc ran and that none of them could have changed anything.

name=${0##*/}
: "${STUB_LOG:?STUB_LOG not set}"
: "${STUB_FIXTURES:?STUB_FIXTURES not set}"

printf '%s %s\n' "$name" "$*" >>"$STUB_LOG"

refuse() {
  printf 'REFUSED %s %s\n' "$name" "$*" >>"$STUB_LOG"
  printf 'stub: refused to run: %s %s\n' "$name" "$*" >&2
  exit 99
}

case $name in
  qm)
    # only `qm config <vmid>`
    [[ $# -eq 2 && $1 == config && $2 =~ ^[0-9]+$ ]] || refuse "$@"
    cat "$STUB_FIXTURES/qm-config-$2.txt" || exit 2
    ;;
  pvesm)
    if [[ $# -eq 1 && $1 == status ]]; then
      cat "$STUB_FIXTURES/pvesm-status.txt"
    elif [[ $# -eq 2 && $1 == path && $2 =~ ^[A-Za-z0-9_.-]+:[A-Za-z0-9_./-]+$ ]]; then
      awk -v v="$2" '$1 == v { print $2; f = 1 } END { exit !f }' "$STUB_FIXTURES/volume-paths.txt" || exit 2
    else
      refuse "$@"
    fi
    ;;
  pveversion)
    [[ $# -eq 0 ]] || refuse "$@"
    cat "$STUB_FIXTURES/pveversion.txt"
    ;;
  pvesh)
    # only `pvesh get <path> [--timeframe tf] --output-format json`
    [[ $1 == get ]] || refuse "$@"
    path=$2
    shift 2
    tf=""
    while (($#)); do
      case $1 in
        --timeframe)
          tf=$2
          shift 2
          ;;
        --output-format)
          [[ $2 == json ]] || refuse "get $path --output-format $2"
          shift 2
          ;;
        *) refuse "get $path $*" ;;
      esac
    done
    if [[ $path =~ ^/nodes/[A-Za-z0-9-]+/qemu$ ]]; then
      cat "$STUB_FIXTURES/qemu-list.json"
    elif [[ $path =~ ^/nodes/[A-Za-z0-9-]+/qemu/([0-9]+)/rrddata$ && -n $tf ]]; then
      cat "$STUB_FIXTURES/rrddata-${BASH_REMATCH[1]}-$tf.json" || exit 2
    else
      refuse "get $path"
    fi
    ;;
  *)
    # every other name is a mutating or out-of-scope tool: it must never be called
    refuse "$@"
    ;;
esac
