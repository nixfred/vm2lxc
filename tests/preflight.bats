#!/usr/bin/env bats
# `vm2lxc preflight <vmid>` end to end against the fixture host (tests/fixtures/pve8).
# Expected sizing numbers were computed independently in Python, not copied from the tool.
#
# Fixture VMs: 100 green (month data) | 101 green multi-disk (week data, month missing)
# 102 yellow USB | 103 red GPU | 104 red Windows+TPM+EFI | 105 red appliance, 2 NICs
# 106 green but <24h of history | 107 red dir storage | 108 red template
# 112 green small | 113 green, memory pinned near max | 114 yellow custom args

bats_require_minimum_version 1.5.0
load helpers

@test "green VM: exit 0, provisional verdict, month history, exact p95/max and choices" {
  run_fx preflight 100
  [ "$status" -eq 0 ]
  [[ $output == *'vm2lxc preflight 100  "web-green"'* ]]
  [[ $output == *"node pve-test | PVE 8.2.4 | FIXTURE MODE"* ]]
  [[ $output == *"VERDICT: GREEN (provisional)"* ]]
  [[ $output == *"12 guest-internal checks were not run (fixture mode never executes)"* ]]
  [[ $output == *"rrddata timeframe=month, 35.0 days of data, 100% of samples, confidence HIGH"* ]]
  [[ $output == *"memory  p95 790M  max 800M  now 4096M"* ]]
  [[ $output == *"choices: lean 960M | recommended 1024M | keep 4096M"* ]]
  [[ $output == *'RAM saved at "recommended": 3072M'* ]]
  [[ $output == *"cpu     p95 0.68 cores  max 0.68 cores  now 4"* ]]
  [[ $output == *"Nothing was changed: no disk was looked at, only the VM config was read."* ]]
}

@test "multi-disk VM: boot disk is rootfs, the other disk is mp0, total allocated is shown" {
  run_fx preflight 101
  [ "$status" -eq 0 ]
  [[ $output == *"2 disks map to scsi0 -> rootfs, scsi1 -> mp0"* ]]
  [[ $output == *"scsi0     local-lvm (lvmthin)          20G     -> rootfs  (boot disk)"* ]]
  [[ $output == *"scsi1     local-lvm (lvmthin)          200G    -> mp0"* ]]
  [[ $output == *"ide2      cdrom / empty drive          -       -> ignored"* ]]
  [[ $output == *"allocated: 220G"* ]]
}

@test "month rrd missing: falls back to week, 7.0 days is exactly the MEDIUM boundary" {
  run_fx preflight 101
  [[ $output == *"rrddata timeframe=week, 7.0 days of data, 100% of samples, confidence MEDIUM"* ]]
  [[ $output == *"memory  p95 2950M  max 3000M  now 8192M"* ]]
  [[ $output == *"choices: lean 3456M | recommended 3712M | keep 8192M"* ]]
  [[ $output == *'RAM saved at "recommended": 4480M'* ]]
  [[ $output == *"180-minute averages"* ]]
}

@test "cpu choices never offer a recommended size below lean" {
  run_fx preflight 101
  [[ $output == *"choices: lean 2 | recommended 2 | keep 2"* ]]
}

@test "yellow VM: exit 10 and the reason is on screen" {
  run_fx preflight 102
  [ "$status" -eq 10 ]
  [[ $output == *"VERDICT: YELLOW"* ]]
  [[ $output == *"Convertible with caveats"* ]]
  [[ $output == *"[YELLOW] usb0 is USB passthrough (host=0bda:8153)"* ]]
}

@test "red VM (GPU passthrough): exit 20, one blocker, sizing says history unreadable" {
  run_fx preflight 103
  [ "$status" -eq 20 ]
  [[ $output == *"VERDICT: RED"* ]]
  [[ $output == *"1 blocker(s)"* ]]
  [[ $output == *"[RED]    hostpci0 is PCI passthrough (0000:01:00.0)"* ]]
  [[ $output == *"RRD history could not be read"* ]]
}

@test "Windows VM: red for ostype, yellow for TPM, info for UEFI; EFI and TPM disks are not mapped" {
  run_fx preflight 104
  [ "$status" -eq 20 ]
  [[ $output == *"[RED]    ostype win11 is Windows"* ]]
  [[ $output == *"[YELLOW] tpmstate0: the VM has a TPM"* ]]
  [[ $output == *"[info]   efidisk0: UEFI VM"* ]]
  [[ $output == *"efidisk0  UEFI variables"*"-> ignored"* ]]
  [[ $output == *"tpmstate0 TPM state"*"-> ignored"* ]]
  [[ $output == *"scsi0     local-zfs (zfspool)          128G    -> rootfs"* ]]
}

@test "appliance VM: red, and both NICs are listed with MAC, bridge and VLAN" {
  run_fx preflight 105
  [ "$status" -eq 20 ]
  [[ $output == *"[RED]    name/tags say 'pfsense' and ostype is not Linux"* ]]
  [[ $output == *"net0  virtio   BC:24:11:AA:BB:69  bridge vmbr0"* ]]
  [[ $output == *"net1  virtio   BC:24:11:AA:BB:F1  bridge vmbr1  VLAN 20"* ]]
  [[ $output == *"will keep each MAC"* ]]
}

@test "under 24h of history: keep the current size, no choices offered, still green" {
  run_fx preflight 106
  [ "$status" -eq 0 ]
  [[ $output == *"rrddata timeframe=day, 6.0 hours of data, 100% of samples, confidence INSUFFICIENT"* ]]
  [[ $output == *"Under 24h of history: keep the current size (memory 2048M, cores 2)"* ]]
  [[ $output != *"choices:"* ]]
  [[ $output != *"RAM saved"* ]]
}

@test "unsupported storage: red, tagged v1 limit, with the reason in plain words" {
  run_fx preflight 107
  [ "$status" -eq 20 ]
  [[ $output == *"storage 'local' is type dir: file-based storage (qcow2/raw files): planned after v1 (v1 limit)"* ]]
}

@test "template: red" {
  run_fx preflight 108
  [ "$status" -eq 20 ]
  [[ $output == *"VM is a template, not a workload"* ]]
}

@test "memory pinned near max: confidence is capped at LOW with a warning" {
  run_fx preflight 113
  [ "$status" -eq 0 ]
  [[ $output == *"confidence LOW"* ]]
  [[ $output == *"may not report real usage"* ]]
  [[ $output == *'RAM saved at "recommended": 0M'* ]]
}

@test "every guest-internal check is listed as pending, none pretends to have run" {
  run_fx preflight 100
  [[ $output == *"12 not checked (fixture mode never executes): os-release, docker, kernel-modules, nfs-server, cloud-init, snap, fstab-netmounts, tailscale, uid-range, disk-layers, iscsi-multipath, nested-virt"* ]]
  [[ $output != *"ran:"* ]]
}

@test "output has no ANSI escapes when NO_COLOR is set" {
  run_fx preflight 100
  [[ $output != *$'\033'* ]]
}

@test "preflight is deterministic: two runs give byte-identical output" {
  local a b
  run_fx preflight 105
  a=$output
  run_fx preflight 105
  b=$output
  [ "$a" = "$b" ]
}

# --- errors ------------------------------------------------------------------------

@test "unknown VM: exit 66 with a clear message" {
  run_fx preflight 999
  [ "$status" -eq 66 ]
  [[ $output == *"VM 999 not found on node pve-test"* ]]
}

@test "bad arguments: no id, two ids, non-numeric, injection attempt all exit 64" {
  run_fx preflight
  [ "$status" -eq 64 ]
  run_fx preflight 100 101
  [ "$status" -eq 64 ]
  run_fx preflight abc
  [ "$status" -eq 64 ]
  run_fx preflight '100; touch /tmp/pwned'
  [ "$status" -eq 64 ]
  [ ! -e /tmp/pwned ]
}

@test "not on a PVE host (no fixtures, no root or no qm): exit 69, never a crash" {
  VM2LXC_FIXTURE_DIR="" run "$VM2LXC" preflight 100
  [ "$status" -eq 69 ]
  [[ $output == *"must run as root"* || $output == *"required tool not found"* ]]
}

@test "a fixture dir that does not exist: exit 69" {
  VM2LXC_FIXTURE_DIR="$BATS_TEST_TMPDIR/nope" run "$VM2LXC" preflight 100
  [ "$status" -eq 69 ]
}

@test "unsupported PVE version turns every VM red as a v1 limit" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  printf 'pve-manager/7.4.1/abcdef (running kernel: 5.15.0-1-pve)\n' >"$fx/pveversion.txt"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" preflight 100
  [ "$status" -eq 20 ]
  [[ $output == *"Proxmox VE 7.4.1 is not supported (v1 targets 8.x and 9.x) (v1 limit)"* ]]
}

@test "PVE 9 is accepted" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  printf 'pve-manager/9.0.3/abcdef (running kernel: 6.14.8-2-pve)\n' >"$fx/pveversion.txt"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" preflight 100
  [ "$status" -eq 0 ]
  [[ $output == *"PVE 9.0.3"* ]]
}

@test "an unreadable pveversion is a red finding, not a crash" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  rm "$fx/pveversion.txt"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" preflight 100
  [ "$status" -eq 20 ]
  [[ $output == *"could not read the Proxmox VE version"* ]]
}

@test "--node overrides the node name shown and used" {
  run_fx --node other-node preflight 100
  [ "$status" -eq 0 ]
  [[ $output == *"node other-node |"* ]]
}

@test "a bad node name is refused before it can reach a command line" {
  run_fx --node 'x;reboot' preflight 100
  [ "$status" -eq 69 ]
  [[ $output == *"bad node name"* ]]
}

@test "storage list unreadable: exit 69" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  rm "$fx/pvesm-status.txt"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" preflight 100
  [ "$status" -eq 69 ]
  [[ $output == *"could not read storage list"* ]]
}

@test "a hostile config never puts a raw escape sequence on the terminal, in any command" {
  local fx="$BATS_TEST_TMPDIR/fx" esc=$'\033'
  cp -r "$FIXTURES/pve8" "$fx"
  printf 'name: evil%s[31mname\nostype: l26\nmemory: 1024\nargs: %s]0;title%s\\ boom\nhostpci0: 0000:01:00.0%s[2J\nusb0: host=1234:5678%s[1m\nscsi0: local-zfs:vm-100-disk-0,size=8G\n' "$esc" "$esc" "$esc" "$esc" "$esc" >"$fx/qm-config-100.txt"
  jq '(.[] | select(.vmid == 100) | .name) = "evil\u001b[31mlist\u009b31m\u202e"' "$fx/qemu-list.json" >"$fx/ql.json" && mv "$fx/ql.json" "$fx/qemu-list.json"
  local cmd
  for cmd in "preflight 100" "scan 100" "inspect 100"; do
    # shellcheck disable=SC2086
    VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" $cmd
    [[ $output != *"$esc"* ]] || { echo "raw ESC reached the terminal for: $cmd"; return 1; }
    [[ $output != *$'\xc2\x9b'* ]] || { echo "a UTF-8 C1 CSI (U+009B) reached the terminal for: $cmd"; return 1; }
    [[ $output != *$'\xe2\x80\xae'* ]] || { echo "a bidi override (U+202E) reached the terminal for: $cmd"; return 1; }
  done
}
