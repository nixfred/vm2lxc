# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# Parse `qm config` text into a map, plus the disk and NIC views the checks need.

declare -gA QMC=()

# qmconf_parse: read `qm config` output on stdin into QMC.
# Only the current config counts: a "[section]" header (snapshot, pending) ends it.
qmconf_parse() {
  local line key val
  QMC=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == \[* ]] && break
    [[ -z $line || $line == \#* ]] && continue
    key=${line%%:*}
    [[ $key =~ ^[a-z][a-z0-9_-]*$ ]] || continue
    val=${line#*:}
    val=${val#"${val%%[![:space:]]*}"} # trim leading whitespace
    # Config text is printed to a terminal: a control character (an ESC sequence in `args`, say)
    # would be interpreted by the operator's terminal. Neutralise them once, here, at ingestion.
    sanitize_text "$val"
    val=$REPLY
    QMC[$key]=$val
  done
}

qmc_get() { # key [default]
  printf '%s' "${QMC[$1]:-${2:-}}"
}

qmc_has() {
  [[ -v QMC[$1] ]]
}

# qmc_keys <ERE>: matching config keys, version-sorted (scsi0 scsi1 ... scsi10).
qmc_keys() {
  local k
  for k in "${!QMC[@]}"; do
    if [[ $k =~ $1 ]]; then
      printf '%s\n' "$k"
    fi
  done | sort -V
}

# csv_opt <csv> <key>: value of "key=" in a comma list. rc 1 when absent.
csv_opt() {
  local IFS=, part
  local -a parts
  read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    if [[ $part == "$2="* ]]; then
      printf '%s' "${part#*=}"
      return 0
    fi
  done
  return 1
}

# size_to_mb 32G -> 32768. K rounds up. A bare number is bytes. rc 1 if unparseable.
size_to_mb() {
  local n u
  [[ $1 =~ ^([0-9]+)([KMGT]?)$ ]] || return 1
  n=${BASH_REMATCH[1]}
  u=${BASH_REMATCH[2]}
  case $u in
    T) echo $((n * 1024 * 1024)) ;;
    G) echo $((n * 1024)) ;;
    M) echo "$n" ;;
    K) echo $(((n + 1023) / 1024)) ;;
    *) echo $(((n + 1048575) / 1048576)) ;;
  esac
}

# fmt_mb 32768 -> 32G ; 1536 -> 1.5G ; 512 -> 512M
fmt_mb() {
  if (($1 >= 1024)); then
    awk -v m="$1" 'BEGIN { g = m / 1024; if (g == int(g)) printf "%dG", g; else printf "%.1fG", g }'
  else
    printf '%dM' "$1"
  fi
}

# --- disks -----------------------------------------------------------------
# Parallel arrays, one entry per disk-like key. D_KIND is one of:
#   data         a real disk on a PVE storage (storage:volume)
#   cdrom        empty drive or ISO (ignored)
#   passthrough  a raw host device such as /dev/disk/by-id/... (cannot be snapshotted)
#   efi, tpm     UEFI vars / TPM state (not data disks)
#   unused       detached volume (not converted)
#   unknown      something we could not parse
D_KEY=() D_KIND=() D_STORAGE=() D_VOL=() D_SIZE_MB=() D_TARGET=()
BOOT_KEY="" BOOT_GUESSED=0

disks_parse() {
  local key val spec kind storage vol size size_mb
  D_KEY=() D_KIND=() D_STORAGE=() D_VOL=() D_SIZE_MB=() D_TARGET=()
  while IFS= read -r key; do
    val=${QMC[$key]}
    spec=${val%%,*}
    storage="" vol="" size="" size_mb=""
    case $key in
      efidisk*) kind=efi ;;
      tpmstate*) kind=tpm ;;
      unused*) kind=unused ;;
      *)
        if [[ $val == *media=cdrom* || $spec == none ]]; then
          kind=cdrom
        elif [[ $spec == /* ]]; then
          kind=passthrough
        elif [[ $spec == *:* ]]; then
          kind=data
        else
          kind=unknown
        fi
        ;;
    esac
    if [[ $spec == *:* && $spec != /* ]]; then
      storage=${spec%%:*}
      vol=${spec#*:}
    fi
    if size=$(csv_opt "$val" size); then
      size_mb=$(size_to_mb "$size") || size_mb=""
    fi
    D_KEY+=("$key")
    D_KIND+=("$kind")
    D_STORAGE+=("$storage")
    D_VOL+=("$vol")
    D_SIZE_MB+=("$size_mb")
  done < <(qmc_keys '^((ide|sata|scsi|virtio)[0-9]+|efidisk[0-9]+|tpmstate[0-9]+|unused[0-9]+)$')
  disks_plan
}

# Decide which data disk becomes rootfs (boot disk) and number the rest mp0, mp1, ...
disks_plan() {
  local i order item bootdisk mp=0
  BOOT_KEY="" BOOT_GUESSED=0
  if order=$(csv_opt "${QMC[boot]:-}" order); then
    local -a items
    IFS=';' read -ra items <<<"$order"
    for item in "${items[@]}"; do
      if disk_is_data "$item"; then
        BOOT_KEY=$item
        break
      fi
    done
  fi
  if [[ -z $BOOT_KEY ]]; then
    bootdisk=${QMC[bootdisk]:-}
    if [[ -n $bootdisk ]] && disk_is_data "$bootdisk"; then
      BOOT_KEY=$bootdisk
    fi
  fi
  if [[ -z $BOOT_KEY ]]; then
    for i in "${!D_KEY[@]}"; do
      if [[ ${D_KIND[$i]} == data ]]; then
        BOOT_KEY=${D_KEY[$i]}
        BOOT_GUESSED=1
        break
      fi
    done
  fi
  for i in "${!D_KEY[@]}"; do
    case ${D_KIND[$i]} in
      data)
        if [[ ${D_KEY[$i]} == "$BOOT_KEY" ]]; then
          D_TARGET[i]=rootfs
        else
          D_TARGET[i]="mp$mp"
          mp=$((mp + 1))
        fi
        ;;
      unused) D_TARGET[i]="not converted (detached)" ;;
      passthrough) D_TARGET[i]="cannot be converted" ;;
      *) D_TARGET[i]="ignored" ;;
    esac
  done
}

disk_is_data() { # key
  local i
  for i in "${!D_KEY[@]}"; do
    if [[ ${D_KEY[$i]} == "$1" && ${D_KIND[$i]} == data ]]; then
      return 0
    fi
  done
  return 1
}

# --- NICs ------------------------------------------------------------------
N_KEY=() N_MODEL=() N_MAC=() N_BRIDGE=() N_TAG=()

nics_parse() {
  local key val first model mac
  N_KEY=() N_MODEL=() N_MAC=() N_BRIDGE=() N_TAG=()
  while IFS= read -r key; do
    val=${QMC[$key]}
    first=${val%%,*}
    model="" mac=""
    if [[ $first =~ ^([A-Za-z0-9_]+)=([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5})$ ]]; then
      model=${BASH_REMATCH[1]}
      mac=${BASH_REMATCH[2]}
    fi
    N_KEY+=("$key")
    N_MODEL+=("$model")
    N_MAC+=("$mac")
    N_BRIDGE+=("$(csv_opt "$val" bridge || true)")
    N_TAG+=("$(csv_opt "$val" tag || true)")
  done < <(qmc_keys '^net[0-9]+$')
}

# Load everything the checks need for one VM. rc 1 if its config cannot be read.
vm_context_load() {
  local vmid=$1 raw
  raw=$(pve_qm_config "$vmid" 2>/dev/null) || return 1
  [[ -n $raw ]] || return 1
  VMID=$vmid
  qmconf_parse <<<"$raw"
  ((${#QMC[@]} > 0)) || return 1
  disks_parse
  nics_parse
}
