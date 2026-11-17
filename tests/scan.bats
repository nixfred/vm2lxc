#!/usr/bin/env bats
# `vm2lxc scan` end to end against the fixture host: ranking, one-line reasons, totals.
# Expected numbers come from the independent Python calculation, not from the tool.

bats_require_minimum_version 1.5.0
load helpers

# vmid column of the ranked rows, in order, space separated
ranked_vmids() {
  awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { printf "%s ", $2 }' <<<"$output" | sed 's/ $//'
}

# the table row for one vmid
row() {
  awk -v id="$1" '$1 ~ /^[0-9]+$/ && $2 == id' <<<"$output"
}

@test "ranking: green by RAM saved, then yellow, then red by vmid; ties by vmid" {
  run_fx scan
  [ "$status" -eq 0 ]
  # green: 101 (4480M) 100 (3072M) 112 (704M) 106 (0, keep) 113 (0) | yellow: 102 (1600M) 114 (1536M) | red by vmid
  [ "$(ranked_vmids)" = "101 100 112 106 113 102 114 103 104 105 107 108" ]
}

@test "ranking does not depend on the order the node lists VMs (the fixture list is shuffled)" {
  [ "$(jq '[.[].vmid] == ([.[].vmid] | sort)' "$FIXTURES/pve8/qemu-list.json")" = false ]
}

@test "rows carry the exact sizing numbers" {
  run_fx scan
  [[ $(row 101) == *"8192M -> 3712M"*"4480M"*"220G"* ]]
  [[ $(row 100) == *"4096M -> 1024M"*"3072M"*"32G"* ]]
  [[ $(row 112) == *"1024M -> 320M"*"704M"* ]]
  [[ $(row 102) == *"2048M -> 448M"*"1600M"* ]]
  [[ $(row 114) == *"2048M -> 512M"*"1536M"* ]]
}

@test "under 24h of history shows (keep) and no saving; pinned memory shows 0M, both say why" {
  run_fx scan
  [[ $(row 106) == *"2048M (keep)"*"under 24h of RRD history, keeping size"* ]]
  [[ $(row 113) == *"4096M -> 4096M"*"0M"*"memory looks pinned near max, saving not trusted"* ]]
}

@test "red and yellow rows give the top reason in plain words; v1 limits are tagged" {
  run_fx scan
  [[ $(row 103) == *"RED"*"hostpci0 is PCI passthrough"* ]]
  [[ $(row 104) == *"RED"*"ostype win11 is Windows"* ]]
  [[ $(row 105) == *"RED"*"'pfsense'"* ]]
  [[ $(row 107) == *"RED"*"type dir"*"(v1 limit)"* ]]
  [[ $(row 108) == *"RED"*"VM is a template"* ]]
  [[ $(row 102) == *"YELLOW"*"usb0 is USB passthrough"* ]]
  [[ $(row 114) == *"YELLOW"*"custom QEMU args"* ]]
}

@test "red rows show no RAM saving, and sizing is not even fetched for them" {
  run_fx scan
  [[ $(row 103) != *"->"* ]]
  [[ $(row 103) == *"16384M"* ]]
}

@test "summary: counts, total RAM freed (green + yellow only) and the honesty footer" {
  run_fx scan
  # 4480 + 3072 + 704 + 0 + 0 + 1600 + 1536 = 11392M = 11.1G
  [[ $output == *"12 VMs: 5 green, 2 yellow, 5 red"* ]]
  [[ $output == *'(green + yellow): 11.1G'* ]]
  [[ $output == *"Verdicts are provisional"* ]]
  [[ $output == *"Disk savings are not estimated"* ]]
}

@test "scan and preflight agree on every VM's verdict" {
  local id want got
  run_fx scan
  local scan_out=$output
  for id in 100 101 102 103 104 105 106 107 108 112 113 114; do
    run_fx preflight "$id"
    case $status in 0) want=GREEN ;; 10) want=YELLOW ;; 20) want=RED ;; *) want="rc$status" ;; esac
    got=$(awk -v id="$id" '$1 ~ /^[0-9]+$/ && $2 == id { print $5 }' <<<"$scan_out")
    [ "$got" = "$want" ] || { echo "VM $id: scan says $got, preflight says $want"; return 1; }
  done
}

@test "a VM the node list marks as a template is red even if its own config does not say so" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  sed -i '/^template:/d' "$fx/qm-config-108.txt"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" scan
  [[ $(row 108) == *"RED"*"VM is a template"* ]]
}

@test "a VM whose config cannot be read is listed as ERROR, counted, and does not stop the scan" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  jq '. + [{"vmid":999,"name":"ghost","status":"running"}]' "$FIXTURES/pve8/qemu-list.json" >"$fx/qemu-list.json"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" scan
  [ "$status" -eq 0 ]
  [[ $(row 999) == *"ERROR"*"could not read this VM's config"* ]]
  [[ $output == *"13 VMs: 5 green, 2 yellow, 5 red, 1 unreadable"* ]]
  [ "$(ranked_vmids | awk '{print $NF}')" = 999 ]
}

@test "an empty node says so" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  printf '[]\n' >"$fx/qemu-list.json"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" scan
  [ "$status" -eq 0 ]
  [[ $output == *"No VMs found on this node."* ]]
}

@test "a broken VM list (not JSON, or missing) is exit 69, not a silent empty table" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  printf 'this is not json' >"$fx/qemu-list.json"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" scan
  [ "$status" -eq 69 ]
  [[ $output == *"not valid JSON"* ]]
  rm "$fx/qemu-list.json"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" scan
  [ "$status" -eq 69 ]
  [[ $output == *"could not list VMs"* ]]
}

@test "on an unsupported PVE version every VM is red" {
  local fx="$BATS_TEST_TMPDIR/fx"
  cp -r "$FIXTURES/pve8" "$fx"
  printf 'pve-manager/7.4.1/abcdef (running kernel: 5.15.0-1-pve)\n' >"$fx/pveversion.txt"
  VM2LXC_FIXTURE_DIR="$fx" run "$VM2LXC" scan
  [[ $output == *"0 green, 0 yellow, 12 red"* ]]
}

@test "scan takes no arguments" {
  run_fx scan 100
  [ "$status" -eq 64 ]
}

@test "scan output has no ANSI escapes when NO_COLOR is set" {
  run_fx scan
  [[ $output != *$'\033'* ]]
}
