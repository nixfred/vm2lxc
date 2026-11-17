#!/usr/bin/env bats
# qm config parsing, comma-list options, sizes, and the disk/NIC views.

bats_require_minimum_version 1.5.0
load helpers

@test "qmconf_parse keeps colons, commas and equals signs inside values" {
  load_libs common qmconf
  qmconf_parse <<'EOF'
name: web-green
scsi0: local-zfs:vm-100-disk-0,iothread=1,size=32G
net0: virtio=BC:24:11:AA:BB:01,bridge=vmbr0,tag=20
EOF
  [ "${QMC[name]}" = "web-green" ]
  [ "${QMC[scsi0]}" = "local-zfs:vm-100-disk-0,iothread=1,size=32G" ]
  [ "${QMC[net0]}" = "virtio=BC:24:11:AA:BB:01,bridge=vmbr0,tag=20" ]
}

@test "qmconf_parse stops at the first [section]: snapshots and pending are not current config" {
  load_libs common qmconf
  qmconf_parse <<'EOF'
memory: 4096
ostype: l26

[before-upgrade]
memory: 1024
ostype: win11
EOF
  [ "${QMC[memory]}" = "4096" ]
  [ "${QMC[ostype]}" = "l26" ]
}

@test "qmconf_parse skips comments, blank lines and lines that are not key: value" {
  load_libs common qmconf
  qmconf_parse <<'EOF'
# a comment: not a key

this line has no colon at all
Bad Key: nope
cores: 2
EOF
  [ "${#QMC[@]}" -eq 1 ]
  [ "${QMC[cores]}" = "2" ]
}

@test "qmconf_parse trims the space after the colon and resets state between calls" {
  load_libs common qmconf
  qmconf_parse <<<'name:    spaced'
  [ "${QMC[name]}" = "spaced" ]
  qmconf_parse <<<'cores: 2'
  [ -z "${QMC[name]:-}" ]
}

@test "qmc_keys sorts numerically: scsi2 comes before scsi10" {
  load_libs common qmconf
  qmconf_parse <<'EOF'
scsi10: local-zfs:vm-1-disk-10
scsi2: local-zfs:vm-1-disk-2
scsi1: local-zfs:vm-1-disk-1
net0: virtio=BC:24:11:AA:BB:01,bridge=vmbr0
EOF
  run qmc_keys '^scsi[0-9]+$'
  [ "$output" = $'scsi1\nscsi2\nscsi10' ]
}

@test "csv_opt finds an option, fails cleanly when absent, and does not match prefixes" {
  load_libs common qmconf
  [ "$(csv_opt 'a:b,size=32G,ssd=1' size)" = "32G" ]
  [ "$(csv_opt 'a:b,size=32G,ssd=1' ssd)" = "1" ]
  run csv_opt 'a:b,size=32G' sizeable
  [ "$status" -eq 1 ]
  run csv_opt 'a:b,mysize=5G' size
  [ "$status" -eq 1 ]
}

@test "size_to_mb converts the units qm config uses" {
  load_libs common qmconf
  [ "$(size_to_mb 32G)" -eq 32768 ]
  [ "$(size_to_mb 512M)" -eq 512 ]
  [ "$(size_to_mb 1T)" -eq 1048576 ]
  [ "$(size_to_mb 1025K)" -eq 2 ]
  [ "$(size_to_mb 1048577)" -eq 2 ]
  run size_to_mb 1.5G
  [ "$status" -eq 1 ]
  run size_to_mb abc
  [ "$status" -eq 1 ]
}

@test "fmt_mb prints whole and fractional gigabytes" {
  load_libs common qmconf
  [ "$(fmt_mb 32768)" = "32G" ]
  [ "$(fmt_mb 1536)" = "1.5G" ]
  [ "$(fmt_mb 512)" = "512M" ]
}

# --- disks -----------------------------------------------------------------

disks_of() {
  load_libs common qmconf
  qmconf_parse <<<"$1"
  disks_parse
}

@test "disks_parse: boot disk becomes rootfs, the others become mp0, mp1 in key order" {
  disks_of "$(cfg_with 'boot: order=scsi1;scsi0' 'scsi1: local-zfs:vm-100-disk-1,size=8G' 'virtio0: local-zfs:vm-100-disk-2,size=1T')"
  local i out=""
  for i in "${!D_KEY[@]}"; do out+="${D_KEY[$i]}=${D_TARGET[$i]} "; done
  [[ $out == *"scsi1=rootfs"* ]]
  [[ $out == *"scsi0=mp0"* ]]
  [[ $out == *"virtio0=mp1"* ]]
  [ "$BOOT_KEY" = scsi1 ]
  [ "$BOOT_GUESSED" -eq 0 ]
}

@test "disks_parse: legacy bootdisk key is honoured when boot has no order" {
  disks_of "$(cfg_with '-boot' 'bootdisk: scsi1' 'scsi1: local-zfs:vm-100-disk-1,size=8G')"
  [ "$BOOT_KEY" = scsi1 ]
  [ "$BOOT_GUESSED" -eq 0 ]
}

@test "disks_parse: with no boot info the first data disk is guessed, and says so" {
  disks_of "$(cfg_with '-boot')"
  [ "$BOOT_KEY" = scsi0 ]
  [ "$BOOT_GUESSED" -eq 1 ]
}

@test "disks_parse: boot order skipping a cdrom lands on the real disk" {
  disks_of "$(cfg_with 'boot: order=ide2;scsi0')"
  [ "$BOOT_KEY" = scsi0 ]
}

@test "disks_parse classifies cdrom, passthrough, efi, tpm, unused and sizes" {
  disks_of "$(cfg_with 'scsi1: /dev/disk/by-id/ata-WDC_X,size=1T' 'ide0: local:iso/debian.iso,media=cdrom,size=600M' 'efidisk0: local-zfs:vm-100-disk-3,efitype=4m,size=1M' 'tpmstate0: local-zfs:vm-100-disk-4,size=4M,version=v2.0' 'unused0: local-zfs:vm-100-disk-9')"
  local i
  declare -A kind=() size=()
  for i in "${!D_KEY[@]}"; do kind[${D_KEY[$i]}]=${D_KIND[$i]}; size[${D_KEY[$i]}]=${D_SIZE_MB[$i]}; done
  [ "${kind[scsi0]}" = data ]
  [ "${kind[scsi1]}" = passthrough ]
  [ "${kind[ide0]}" = cdrom ]
  [ "${kind[ide2]}" = cdrom ]
  [ "${kind[efidisk0]}" = efi ]
  [ "${kind[tpmstate0]}" = tpm ]
  [ "${kind[unused0]}" = unused ]
  [ "${size[scsi0]}" = 32768 ]
  [ "${size[ide0]}" = 600 ]
  [ -z "${size[unused0]}" ]
}

@test "disks_total_mb sums data disks only, and refuses when a size is unknown" {
  load_libs common qmconf sizing
  disks_of "$(cfg_with 'scsi1: local-zfs:vm-100-disk-1,size=8G' 'ide0: local:iso/x.iso,media=cdrom,size=600M')"
  [ "$(disks_total_mb)" -eq $((32768 + 8192)) ]
  disks_of "$(cfg_with 'scsi1: local-zfs:vm-100-disk-1')"
  run disks_total_mb
  [ "$status" -eq 1 ]
}

# --- NICs ------------------------------------------------------------------

@test "nics_parse extracts model, MAC, bridge and VLAN tag" {
  load_libs common qmconf
  qmconf_parse <<'EOF'
net0: virtio=BC:24:11:AA:BB:01,bridge=vmbr0,firewall=1
net1: e1000=bc:24:11:aa:bb:02,bridge=vmbr1,tag=20
EOF
  nics_parse
  [ "${#N_KEY[@]}" -eq 2 ]
  [ "${N_MODEL[0]}" = virtio ]
  [ "${N_MAC[0]}" = BC:24:11:AA:BB:01 ]
  [ "${N_BRIDGE[0]}" = vmbr0 ]
  [ -z "${N_TAG[0]}" ]
  [ "${N_MODEL[1]}" = e1000 ]
  [ "${N_MAC[1]}" = bc:24:11:aa:bb:02 ]
  [ "${N_TAG[1]}" = 20 ]
}

@test "control characters in config values are neutralised at ingestion (terminal-escape injection)" {
  load_libs common qmconf
  qmconf_parse <<<$'name: web\033[2Jclear\nargs: -x \033]0;pwned\007 -y\nhostpci0: 0000:01:00.0\033[31m,pcie=1'
  [[ ${QMC[name]} == "web?[2Jclear" ]]
  [[ ${QMC[args]} == "-x ?]0;pwned? -y" ]]
  [[ ${QMC[hostpci0]} == "0000:01:00.0?[31m,pcie=1" ]]
  local k
  for k in "${!QMC[@]}"; do
    [[ ${QMC[$k]} != *$'\033'* && ${QMC[$k]} != *$'\007'* ]]
  done
}
