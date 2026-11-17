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
