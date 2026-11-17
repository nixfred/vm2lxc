# shellcheck shell=bash
# shellcheck disable=SC2034  # globals set here (PVE_*) are consumed by the other lib files
# The ONLY file that talks to the Proxmox host. Every call here is a read:
#   qm config | pvesh get | pvesm status | pveversion | hostname
# tests/readonly_guard.bats enforces that two ways (a static scan, and a run against
# stub binaries that refuse every other verb). Add a verb here, add it to that test.
#
# Fixture mode (tests and demos): set VM2LXC_FIXTURE_DIR and the same functions read
# canned files instead of running commands, so all the logic runs on any Linux box.
#
# Fixture file names:
#   node                      node name
#   pveversion.txt            output of `pveversion`
#   pvesm-status.txt          output of `pvesm status`
#   qemu-list.json            `pvesh get /nodes/<node>/qemu`
#   qm-config-<vmid>.txt      `qm config <vmid>`
#   volume-paths.txt          lines "<storage:volume> <path>", what `pvesm path` prints
#   rrddata-<vmid>-<tf>.json  `pvesh get .../rrddata --timeframe <tf>`  (tf: month|week|day)
# A missing fixture file behaves like the command failing.

pve_fixture_mode() {
  [[ -n ${VM2LXC_FIXTURE_DIR:-} ]]
}

# pve_read <fixture-file> <command...>: cat the fixture, or run the command.
pve_read() {
  local fixture=$1
  shift
  if pve_fixture_mode; then
    [[ -r $VM2LXC_FIXTURE_DIR/$fixture ]] || return 1
    cat -- "$VM2LXC_FIXTURE_DIR/$fixture"
  else
    "$@" </dev/null
  fi
}

# Refuse to run anywhere we cannot do the job, loudly and early.
pve_require_host() {
  local tool
  if pve_fixture_mode; then
    [[ -d $VM2LXC_FIXTURE_DIR ]] || die "$EXIT_ENV" "VM2LXC_FIXTURE_DIR is not a directory: $VM2LXC_FIXTURE_DIR"
    return 0
  fi
  # VM2LXC_ASSUME_ROOT is for the stub-binary tests only; the tool is read-only anyway.
  if [[ ${VM2LXC_ASSUME_ROOT:-} != 1 && $EUID -ne 0 ]]; then
    die "$EXIT_ENV" "must run as root on a Proxmox VE node (qm and pvesh need it)"
  fi
  for tool in qm pvesh pvesm pveversion jq; do
    command -v "$tool" >/dev/null 2>&1 || die "$EXIT_ENV" "required tool not found: $tool (is this a Proxmox VE node?)"
  done
}

pve_mode_label() {
  if pve_fixture_mode; then
    printf 'FIXTURE MODE (canned data, no real host)'
  else
    printf 'live host'
  fi
}

pve_node() {
  local n
  if [[ -n $OPT_NODE ]]; then
    n=$OPT_NODE
  elif pve_fixture_mode && [[ -r $VM2LXC_FIXTURE_DIR/node ]]; then
    n=$(<"$VM2LXC_FIXTURE_DIR/node")
  else
    n=$(hostname -s)
  fi
  # The node name is interpolated into API paths: only accept what Proxmox allows.
  [[ $n =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || die "$EXIT_ENV" "bad node name: '$n'"
  printf '%s' "$n"
}

pve_version_line() {
  pve_read pveversion.txt pveversion
}

pve_storage_status() {
  pve_read pvesm-status.txt pvesm status
}

pve_list_vms() {
  pve_read qemu-list.json pvesh get "/nodes/$PVE_NODE_NAME/qemu" --output-format json
}

pve_qm_config() {
  pve_read "qm-config-$1.txt" qm config "$1"
}

# pve_id_in_use <id>: is that id already a VM or a container on this host (ids share one namespace)?
pve_id_in_use() {
  local out
  if pve_fixture_mode; then
    if [[ -r $VM2LXC_FIXTURE_DIR/cluster-resources.json ]]; then
      out=$(<"$VM2LXC_FIXTURE_DIR/cluster-resources.json")
    else
      out=$(pve_list_vms) || return 1
    fi
  else
    out=$(pvesh get /cluster/resources --type vm --output-format json </dev/null) || return 1
  fi
  jq -e --argjson id "$1" 'any(.[]; .vmid == $id)' <<<"$out" >/dev/null
}

# pve_nextid: the next free VM/CT id (live: the cluster's own answer)
pve_nextid() {
  if pve_fixture_mode; then
    if [[ -r $VM2LXC_FIXTURE_DIR/nextid.txt ]]; then cat "$VM2LXC_FIXTURE_DIR/nextid.txt"; else printf '9100'; fi
  else
    pvesh get /cluster/nextid </dev/null
  fi
}

# pve_volume_path <storage:volume>: where the volume lives on this host (`pvesm path`).
# A zfspool volume is /dev/zvol/<pool/dataset>; an lvmthin volume is /dev/<vg>/<lv>.
pve_volume_path() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*:[A-Za-z0-9][A-Za-z0-9_./-]*$ ]] || return 1 # no leading '-': it would be an option to pvesm
  if pve_fixture_mode; then
    [[ -r $VM2LXC_FIXTURE_DIR/volume-paths.txt ]] || return 1
    awk -v v="$1" '$1 == v { print $2; f = 1 } END { exit !f }' "$VM2LXC_FIXTURE_DIR/volume-paths.txt"
  else
    pvesm path "$1" </dev/null
  fi
}

# pve_rrddata <vmid> <timeframe>
pve_rrddata() {
  local vmid=$1 tf=$2
  case $tf in
    hour | day | week | month | year) ;;
    *) die "$EXIT_USAGE" "internal error: bad rrd timeframe '$tf'" ;;
  esac
  pve_read "rrddata-$vmid-$tf.json" \
    pvesh get "/nodes/$PVE_NODE_NAME/qemu/$vmid/rrddata" --timeframe "$tf" --output-format json
}

# Parse "pve-manager/8.2.4/faa83925c9641325 (running kernel: 6.8.8-2-pve)" -> "8.2.4"
pve_parse_version() {
  local line=$1
  if [[ $line =~ ^pve-manager/([0-9]+(\.[0-9]+)*) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# Load node, PVE version and storage map once per run.
host_context_load() {
  local line st
  pve_require_host
  PVE_NODE_NAME=$(pve_node)
  PVE_VERSION="" PVE_MAJOR=""
  if line=$(pve_version_line 2>/dev/null) && PVE_VERSION=$(pve_parse_version "$line"); then
    PVE_MAJOR=${PVE_VERSION%%.*}
  else
    PVE_VERSION=""
  fi
  st=$(pve_storage_status) || die "$EXIT_ENV" "could not read storage list (pvesm status failed)"
  storage_load <<<"$st"
}
