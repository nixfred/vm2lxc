# shellcheck shell=bash
# Shared bats helpers. Tests never need a Proxmox host: they run the real code
# against canned files (tests/fixtures) via VM2LXC_FIXTURE_DIR.

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
VM2LXC="$REPO_ROOT/vm2lxc"
FIXTURES="$REPO_ROOT/tests/fixtures"

# No colour in captured output, whatever the terminal says.
export NO_COLOR=1

# Source libraries into the test shell so unit tests can call functions directly.
# shellcheck disable=SC1090,SC1091
load_libs() {
  local f
  for f in "$@"; do
    source "$REPO_ROOT/lib/$f.sh"
  done
}

# Run the CLI against the fixture host. Usage: run_fx <args...>
run_fx() {
  VM2LXC_FIXTURE_DIR="$FIXTURES/pve8" run "$VM2LXC" "$@"
}

# Load every library and the fixture host (node, PVE 8.2.4, storage list).
setup_fixture_host() {
  export VM2LXC_FIXTURE_DIR="$FIXTURES/pve8"
  load_libs common pve qmconf storage findings checks_cfg checks_guest sizing
  host_context_load
}

# Parse a `qm config` text from stdin and run all the config-level checks on it.
run_cfg_checks_on() {
  local raw
  raw=$(cat)
  findings_reset
  qmconf_parse <<<"$raw"
  disks_parse
  nics_parse
  cfg_checks_run
  verdict_compute
}

# A VM with nothing wrong with it. Tests append or override lines.
good_cfg() {
  cat <<'EOF'
agent: 1
boot: order=scsi0;ide2;net0
cores: 4
cpu: x86-64-v2-AES
ide2: none,media=cdrom
memory: 4096
name: web-green
net0: virtio=BC:24:11:AA:BB:01,bridge=vmbr0,firewall=1
numa: 0
ostype: l26
scsi0: local-zfs:vm-100-disk-0,iothread=1,size=32G
scsihw: virtio-scsi-single
sockets: 1
EOF
}

# good_cfg with some keys replaced or removed: cfg_with 'ostype: win11' '-memory'
cfg_with() {
  local out line key arg
  out=$(good_cfg)
  for arg in "$@"; do
    if [[ $arg == -* ]]; then
      key=${arg#-}
      out=$(grep -v "^$key:" <<<"$out")
    else
      key=${arg%%:*}
      out=$(grep -v "^$key:" <<<"$out")
      out+=$'\n'"$arg"
    fi
  done
  while IFS= read -r line; do printf '%s\n' "$line"; done <<<"$out"
}

# Assert a finding exists: has_finding <level> <id> [message-substring]
has_finding() {
  local i
  for i in "${!F_LEVEL[@]}"; do
    if [[ ${F_LEVEL[$i]} == "$1" && ${F_ID[$i]} == "$2" && ${F_MSG[$i]} == *"${3:-}"* ]]; then
      return 0
    fi
  done
  echo "expected finding: level=$1 id=$2 msg~'${3:-}'"
  echo "findings were:"
  for i in "${!F_LEVEL[@]}"; do
    printf '  %s %s (%s): %s\n' "${F_LEVEL[$i]}" "${F_ID[$i]}" "${F_KIND[$i]}" "${F_MSG[$i]}"
  done
  return 1
}

# Assert no finding with this id exists at any level.
no_finding() {
  local i
  for i in "${!F_ID[@]}"; do
    if [[ ${F_ID[$i]} == "$1" ]]; then
      echo "unexpected finding: ${F_LEVEL[$i]} ${F_ID[$i]}: ${F_MSG[$i]}"
      return 1
    fi
  done
  return 0
}

# Build RRD JSON rows with jq. make_rrd <n> <step_s> <start_epoch> <jq-expr-for-mem-bytes> [maxmem_bytes] [maxcpu] [jq-expr-for-cpu]
# In the expressions, `.` is the row index 0..n-1.
make_rrd() {
  local n=$1 step=$2 start=$3 memexpr=$4 maxmem=${5:-4294967296} maxcpu=${6:-4} cpuexpr=${7:-0.1}
  jq -n --argjson n "$n" --argjson step "$step" --argjson start "$start" \
    --argjson maxmem "$maxmem" --argjson maxcpu "$maxcpu" \
    "[range(0; \$n) | {time: (\$start + . * \$step), cpu: ($cpuexpr), maxcpu: \$maxcpu, mem: ($memexpr), maxmem: \$maxmem}]"
}

# --- stateful fake storage host (tests/stubs/fakehost.sh) -------------------------------------

# Everything the snapshot layer touches lives in a throwaway directory per test.
setup_fake_host() {
  local n fb="$BATS_TEST_TMPDIR/fakebin"
  load_libs common pve qmconf storage findings checks_cfg checks_guest sizing snapplan hostexec inspect
  mkdir -p "$fb"
  for n in zfs lvs lvcreate lvchange lvremove losetup lsblk mount umount mountpoint udevadm; do
    ln -s "$REPO_ROOT/tests/stubs/fakehost.sh" "$fb/$n"
  done
  export PATH="$fb:$PATH"
  export FAKE_STATE="$BATS_TEST_TMPDIR/fake"
  export VM2LXC_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export VM2LXC_RUN_ROOT="$BATS_TEST_TMPDIR/run"
  export VM2LXC_WAIT_SLEEP=0 VM2LXC_WAIT_TRIES=2
  mkdir -p "$FAKE_STATE/zfs" "$FAKE_STATE/lvm" "$FAKE_STATE/loops" "$FAKE_STATE/lsblk"
  unset FAKE_FAIL FAKE_SLEEP_LSBLK
}

fake_enc() {
  local x=${1//\//%2F}
  printf '%s' "${x//@/%40}"
}

seed_zvol() { # <pool/ds>  a SOURCE zvol that must never be touched
  printf 'kind=zvol\n' >"$FAKE_STATE/zfs/$(fake_enc "$1")"
}

seed_lv() { # <vg> <lv>  a SOURCE thin LV (active, in use by a running VM)
  printf 'tags=\norigin=\nattr=Vwi-aotz--\nactive=1\n' >"$FAKE_STATE/lvm/$1__$2"
}

# What lsblk prints for a zfs clone device: seed_lsblk_dev <dev> <line>...
seed_lsblk_dev() {
  local dev=$1
  shift
  printf '%s\n' "$@" >"$FAKE_STATE/lsblk/$(fake_enc "$dev")"
}

# What lsblk prints for the loop device attached to <backing>; @LOOP@ is the loop name.
seed_lsblk_backing() {
  local backing=$1
  shift
  printf '%s\n' "$@" >"$FAKE_STATE/lsblk/$(fake_enc "$backing")"
}

fake_rootfs_suffix() { printf '%s\n' "$@" >"$FAKE_STATE/rootfs-suffixes"; }

zfs_has() { [[ -f $FAKE_STATE/zfs/$(fake_enc "$1") ]]; }
lv_has() { [[ -f $FAKE_STATE/lvm/${1%%/*}__${1#*/} ]]; }
fake_events() { cat "$FAKE_STATE/events.log" 2>/dev/null || true; }
fake_calls() { grep -E "^$1( |\$)" "$FAKE_STATE/calls.log" 2>/dev/null || true; }
fake_mounts() { cat "$FAKE_STATE/mounts" 2>/dev/null || true; }
fake_loops() { ls "$FAKE_STATE/loops" 2>/dev/null | wc -l | tr -d ' '; }

# Assert nothing of ours remains anywhere in the fake host or the run root.
assert_nothing_left() {
  local left=""
  left+=$(find "$FAKE_STATE/zfs" "$FAKE_STATE/lvm" -type f -name '*vm2lxc*' 2>/dev/null || true)
  [[ -z $(fake_mounts) ]] || left+=$'\n'"mounts: $(fake_mounts)"
  [[ $(fake_loops) == 0 ]] || left+=$'\n'"loop devices remain"
  left+=$(find "$VM2LXC_RUN_ROOT" 2>/dev/null || true) # the run root itself must be gone too
  [[ ! -e $FAKE_STATE/leaks.log ]] || left+=$'\n'"a child inherited the lock fd: $(cat "$FAKE_STATE/leaks.log")"
  [[ -z ${left//[[:space:]]/} ]] || {
    echo "objects left behind:"
    echo "$left"
    return 1
  }
}

# Build PLAN through the real planner from synthetic disks, no fixture host needed.
#   plan_disks <vmid> <run> <zfspool|lvmthin> <key>:<path>:<target> ...
plan_disks() {
  local vmid=$1 run=$2 type=$3 spec key path target
  shift 3
  D_KEY=() D_KIND=() D_STORAGE=() D_VOL=() D_SIZE_MB=() D_TARGET=()
  ST_TYPE=([st]=$type)
  declare -gA FAKE_PATHS=()
  for spec in "$@"; do
    IFS=: read -r key path target <<<"$spec"
    D_KEY+=("$key") D_KIND+=(data) D_STORAGE+=(st) D_VOL+=("vol-$key") D_SIZE_MB+=(1024) D_TARGET+=("$target")
    FAKE_PATHS["st:vol-$key"]=$path
  done
  pve_volume_path() { printf '%s\n' "${FAKE_PATHS[$1]}"; }
  snap_plan_build "$vmid" "$run"
}
