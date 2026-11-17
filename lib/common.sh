# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# Shared helpers: exit codes, option globals, colours, messages. Sourced, never run.
# No `set` options here: the entry script owns them.

[[ -n ${_VM2LXC_COMMON:-} ]] && return 0
_VM2LXC_COMMON=1

VM2LXC_VERSION="0.0.1-dev"

# Exit codes. 0/10/20 are preflight verdicts; the rest are errors (sysexits-flavoured).
EXIT_OK=0
EXIT_YELLOW=10
EXIT_RED=20
EXIT_USAGE=64
EXIT_DATAERR=65 # the VM's disks cannot be planned (unsupported storage, unreadable path)
EXIT_NOINPUT=66
EXIT_ENV=69
EXIT_NOTIMPL=70
EXIT_REFUSED=77 # a safety rail refused an action (see docs/snapshot-layer.html)

# Global options, filled by parse_args in the entry script.
OPT_YES=0
OPT_DRY_RUN=0
OPT_NO_TUI=0
OPT_ANSWERS=""
OPT_NODE=""
OPT_HELP=0
OPT_VERSION=0
OPT_CTID=""        # convert: the container id (default: the next free one)
OPT_MEMORY=""
OPT_CORES=""
OPT_HOSTNAME=""
OPT_PRIVILEGED=0  # convert: opt in to a privileged container (D5)
OPT_START=0       # convert: start the container when done (the cutover)
POSITIONAL=()

# sanitize_text <text>: neutralise everything a terminal would act on; the result is in REPLY (no
# subshell, so it is cheap enough to run on every config value). The ASCII control class alone is
# locale-dependent: in the C locale a UTF-8 C1 control (U+009B, the 8-bit CSI = C2 9B) passes through,
# and so do bidi overrides (U+202E) that can make a name read backwards.
sanitize_text() {
  local LC_ALL=C v=$1
  v=${v//[[:cntrl:]]/?}
  v=${v//$'\xc2'[$'\x80'-$'\x9f']/??}                  # C1 controls
  v=${v//$'\xe2\x80'[$'\x8e\x8f\xaa'-$'\xae']/???}     # LRM, RLM and the bidi embeddings/overrides
  v=${v//$'\xe2\x81'[$'\xa6'-$'\xa9']/???}             # the bidi isolates
  REPLY=$v
}

color_init() {
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RED=$'\033[1;31m'
    C_YEL=$'\033[1;33m'
    C_GRN=$'\033[1;32m'
    C_DIM=$'\033[2m'
    C_BLD=$'\033[1m'
    C_RST=$'\033[0m'
  else
    C_RED='' C_YEL='' C_GRN='' C_DIM='' C_BLD='' C_RST=''
  fi
}
color_init

die() {
  local code=$1
  shift
  printf 'vm2lxc: error: %s\n' "$*" >&2
  exit "$code"
}

warn() {
  printf 'vm2lxc: warning: %s\n' "$*" >&2
}

# A VMID is a plain number, 100 or higher (Proxmox's own lower bound).
vmid_valid() {
  [[ $1 =~ ^[0-9]{3,9}$ ]]
}

usage() {
  cat <<EOF
vm2lxc ${VM2LXC_VERSION}: convert a Proxmox QEMU VM into an LXC container, safely (ALPHA)

Usage: vm2lxc [options] <command> [args]

Commands:
  preflight <vmid>   read-only convertibility check: verdict, reasons, sizing
  scan [vmid...]     rank the VMs on this node (or just the ones named) by verdict and RAM saved
  inspect <vmid>     show the plan to mount the VM's disks read-only from storage
                     snapshots; with --yes, do it, look inside, and tear it all down
  cleanup            tear down anything a crashed inspect left behind (lists first,
                     removes with --yes). Only touches objects in vm2lxc's own journals
  convert <vmid>     show the plan to turn the VM into a NEW container; with --yes, do it:
                     stop the VM (stop-and-copy), snapshot, copy, create the container (stopped
                     unless --start). The VM and its disks are kept, never deleted
  undo <ct>          reverse a conversion: destroy the container and start the VM again
                     (shows what it will do; --yes to do it)

Options:
  --yes              really execute (inspect, convert, undo, cleanup); without it they only show a plan
  --ctid N           convert: the container id to create (default: the next free id)
  --start            convert: start the container when done (the cutover)
  --privileged       convert: create a privileged container (default: unprivileged)
  --memory MB        convert: container RAM (default: the VM's)
  --cores N          convert: container cores (default: the VM's)
  --hostname NAME    convert: container hostname (default: the VM's name)
  --answers FILE     read prompt answers from FILE (accepted, unused so far)
  --dry-run          show what would happen (preflight and scan are always read-only)
  --no-tui           plain prompts, no whiptail (accepted, unused so far)
  --node NAME        PVE node name (default: this host's short hostname)
  -h, --help         this text
  --version          print the version

Exit codes: 0 green, 10 yellow, 20 red (preflight only); 64 bad usage;
65 the VM's disks cannot be planned; 66 VM not found; 69 environment problem (not root, not PVE, missing tool);
77 a safety rail refused an action (or a RED verdict stopped convert).

Run as root on a Proxmox VE 8.x/9.x node. preflight and scan only read. inspect, convert,
undo and cleanup change things only with --yes, and only objects they recorded in their own
journal: snapshots named vm2lxc-..., and the one container convert creates (tagged
vm2lxc-<run>). A VM's disks are never written.
EOF
}
