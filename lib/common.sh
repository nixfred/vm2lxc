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
EXIT_NOINPUT=66
EXIT_ENV=69
EXIT_NOTIMPL=70

# Global options, filled by parse_args in the entry script.
OPT_YES=0
OPT_DRY_RUN=0
OPT_NO_TUI=0
OPT_ANSWERS=""
OPT_NODE=""
OPT_HELP=0
OPT_VERSION=0
POSITIONAL=()

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
vm2lxc ${VM2LXC_VERSION}: convert a Proxmox QEMU VM into an LXC container (WORK IN PROGRESS)

Usage: vm2lxc [options] <command> [args]

Commands:
  preflight <vmid>   read-only convertibility check: verdict, reasons, sizing
  scan               rank every VM on this node by verdict and RAM saved
  convert <vmid>     not implemented yet
  undo <ct>          not implemented yet
  cleanup            not implemented yet

Options:
  --yes              answer yes to prompts (for convert; accepted, unused so far)
  --answers FILE     read prompt answers from FILE (for convert; accepted, unused so far)
  --dry-run          show what would happen (preflight and scan are always read-only)
  --no-tui           plain prompts, no whiptail (accepted, unused so far)
  --node NAME        PVE node name (default: this host's short hostname)
  -h, --help         this text
  --version          print the version

Exit codes: 0 green, 10 yellow, 20 red (preflight only); 64 bad usage;
66 VM not found; 69 environment problem (not root, not PVE, missing tool);
70 not implemented yet.

Run as root on a Proxmox VE 8.x/9.x node. Nothing here changes the host: preflight
and scan only read.
EOF
}
