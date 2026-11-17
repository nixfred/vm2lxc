# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# Config-level checks: everything decidable from `qm config`, the storage list and the
# PVE version, with the guest disk never touched. Each check is a function
# `check_cfg_<name>` that reads the loaded VM context (QMC, D_*, N_*) and reports with
# `finding <level> <id> <kind> <message>`. Add a check: write the function, add its
# name to CFG_CHECKS.

CFG_CHECKS=(host_version template lock ostype appliance hostpci usb virtiofs args hookscript tpm_efi disks)

cfg_checks_run() {
  local c
  for c in "${CFG_CHECKS[@]}"; do
    "check_cfg_$c"
  done
}

check_cfg_host_version() {
  case ${PVE_MAJOR:-} in
    8 | 9) ;;
    '') finding red host-version tool "could not read the Proxmox VE version (pveversion)" ;;
    *) finding red host-version tool "Proxmox VE $PVE_VERSION is not supported (v1 targets 8.x and 9.x)" ;;
  esac
}

check_cfg_template() {
  if [[ ${QMC[template]:-0} == 1 ]]; then
    finding red template vm "VM is a template, not a workload: nothing to convert"
  fi
}

check_cfg_lock() {
  if qmc_has lock; then
    finding red lock vm "VM is locked (lock: ${QMC[lock]}): another operation is running, retry when it finishes"
  fi
}

check_cfg_ostype() {
  local os
  os=$(qmc_get ostype other)
  case $os in
    l26) ;;
    l24)
      finding yellow ostype vm "ostype l24 (Linux 2.4 era): a guest this old may not run on a modern host kernel"
      ;;
    win* | w2k* | wxp | wvista)
      finding red ostype vm "ostype $os is Windows: a container shares the host's Linux kernel and cannot run it"
      ;;
    solaris)
      finding red ostype vm "ostype solaris is not Linux: a container shares the host's Linux kernel"
      ;;
    other)
      finding yellow ostype vm "ostype is 'other' (not declared as Linux): confirm the guest really is Linux before converting"
      ;;
    *)
      finding yellow ostype vm "unrecognised ostype '$os': confirm the guest really is Linux before converting"
      ;;
  esac
}

# Names and tags that give away an appliance or a BSD. A name alone is weak evidence, so
# it is only red when the ostype also says "not declared Linux".
APPLIANCE_RE='(^|[^a-z0-9])(pfsense|opnsense|truenas|freenas|unraid|xpenology|synology|haos|hassos|vyos|routeros|mikrotik|openwrt|esxi|freebsd|openbsd|netbsd|nas4free|pbs|pmg)([^a-z0-9]|$)'

check_cfg_appliance() {
  local hay hint os
  hay="$(qmc_get name) $(qmc_get tags) $(qmc_get description)"
  hay=${hay,,}
  hay=${hay//%[0-9A-Fa-f][0-9A-Fa-f]/ } # description is URL-encoded
  [[ $hay =~ $APPLIANCE_RE ]] || return 0
  hint=${BASH_REMATCH[2]}
  os=$(qmc_get ostype other)
  if [[ $os == other ]]; then
    finding red appliance vm "name/tags say '$hint' and ostype is not Linux: an appliance or BSD, which cannot run as a container"
  else
    finding yellow appliance vm "name/tags say '$hint': appliances ship their own kernel and modules and usually cannot run as a container, confirm before converting"
  fi
}

check_cfg_hostpci() {
  local k
  while IFS= read -r k; do
    finding red hostpci vm "$k is PCI passthrough (${QMC[$k]%%,*}): a container cannot take over a PCI device such as a GPU, keep this one a VM"
  done < <(qmc_keys '^hostpci[0-9]+$')
}

check_cfg_usb() {
  local k
  while IFS= read -r k; do
    [[ ${QMC[$k]} == *spice* ]] && continue # SPICE redirection, not a physical device
    finding yellow usb vm "$k is USB passthrough (${QMC[$k]%%,*}): not carried over automatically, the container would need the device passed through by hand"
  done < <(qmc_keys '^usb[0-9]+$')
}

check_cfg_virtiofs() {
  local k
  while IFS= read -r k; do
    finding yellow virtiofs vm "$k is a host directory share (virtiofs): not carried over, re-create it as a container bind mount by hand"
  done < <(qmc_keys '^virtiofs[0-9]+$')
}

check_cfg_args() {
  if qmc_has args; then
    finding yellow args vm "custom QEMU args are set (${QMC[args]:0:60}): they have no container equivalent, review before converting"
  fi
}

check_cfg_hookscript() {
  if qmc_has hookscript; then
    finding yellow hookscript vm "a hookscript is set (${QMC[hookscript]}): it was written for a VM, check it still makes sense for a container"
  fi
}

check_cfg_tpm_efi() {
  local k
  while IFS= read -r k; do
    finding yellow tpm vm "$k: the VM has a TPM, so the guest may use TPM-sealed disk encryption, which cannot be read from a snapshot"
  done < <(qmc_keys '^tpmstate[0-9]+$')
  while IFS= read -r k; do
    finding info efi vm "$k: UEFI VM, the EFI variables are not carried into a container (it needs no bootloader)"
  done < <(qmc_keys '^efidisk[0-9]+$')
}

check_cfg_disks() {
  local i key st stype status n_data=0 plan=""
  for i in "${!D_KEY[@]}"; do
    key=${D_KEY[$i]}
    case ${D_KIND[$i]} in
      data)
        n_data=$((n_data + 1))
        plan+="${plan:+, }$key -> ${D_TARGET[$i]}"
        st=${D_STORAGE[$i]}
        if [[ -z ${ST_TYPE[$st]:-} ]]; then
          finding red storage vm "disk $key: storage '$st' is not in the storage list (pvesm status)"
          continue
        fi
        stype=${ST_TYPE[$st]}
        status=${ST_STATUS[$st]:-unknown}
        if [[ $status != active ]]; then
          finding red storage vm "disk $key: storage '$st' is $status, not active"
        fi
        if ! storage_is_supported "$stype"; then
          finding red storage tool "disk $key: storage '$st' is type $stype: $(storage_reason "$stype")"
        fi
        ;;
      passthrough)
        finding red disk-passthrough vm "disk $key is a raw host device (${QMC[$key]%%,*}): a physical disk cannot be snapshotted at the storage layer"
        ;;
      unknown)
        finding yellow disk-unknown vm "disk $key has a volume spec I cannot read (${QMC[$key]%%,*}): check it by hand"
        ;;
      unused)
        finding info disk-unused vm "$key (${QMC[$key]%%,*}) is a detached volume: it will not be converted"
        ;;
    esac
  done
  if ((n_data == 0)); then
    finding red disk-none vm "no usable disk found in the VM config"
  elif ((n_data > 1)); then
    finding info multi-disk vm "$n_data disks map to $plan (extra disks become container mount points)"
  fi
  if ((BOOT_GUESSED)) && ((n_data > 0)); then
    finding info boot-guess vm "no boot disk is declared: assuming $BOOT_KEY is the root disk"
  fi
}
