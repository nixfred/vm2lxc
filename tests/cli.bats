#!/usr/bin/env bats
# CLI surface: flags, validation, exit codes, and the stubbed subcommands.

bats_require_minimum_version 1.5.0
load helpers

@test "--version prints the version and exits 0" {
  run "$VM2LXC" --version
  [ "$status" -eq 0 ]
  [[ $output == "vm2lxc 0."* ]]
}

@test "--help lists every subcommand and every flag" {
  run "$VM2LXC" --help
  [ "$status" -eq 0 ]
  local word
  for word in preflight scan convert undo cleanup --yes --answers --dry-run --no-tui; do
    [[ $output == *"$word"* ]] || { echo "help text is missing: $word"; return 1; }
  done
}

@test "no arguments is a usage error (64) with the usage text on stderr" {
  run --separate-stderr "$VM2LXC"
  [ "$status" -eq 64 ]
  [[ $stderr == *"Usage: vm2lxc"* ]]
}

@test "unknown command and unknown option are usage errors (64)" {
  run "$VM2LXC" frobnicate
  [ "$status" -eq 64 ]
  [[ $output == *"unknown command: frobnicate"* ]]
  run "$VM2LXC" --nope
  [ "$status" -eq 64 ]
  [[ $output == *"unknown option: --nope"* ]]
}

@test "--answers and --node without a value are usage errors (64)" {
  run "$VM2LXC" scan --answers
  [ "$status" -eq 64 ]
  run "$VM2LXC" scan --node
  [ "$status" -eq 64 ]
}

@test "convert is a stub: says not implemented and exits 70" {
  run "$VM2LXC" convert 100
  [ "$status" -eq 70 ]
  [[ $output == *"not implemented"* ]]
}

@test "undo and cleanup are stubs: not implemented, exit 70" {
  run "$VM2LXC" undo 100
  [ "$status" -eq 70 ]
  [[ $output == *"not implemented"* ]]
  run "$VM2LXC" cleanup
  [ "$status" -eq 70 ]
  [[ $output == *"not implemented"* ]]
}

@test "stubs still validate their arguments like the real commands will" {
  run "$VM2LXC" convert
  [ "$status" -eq 64 ]
  run "$VM2LXC" convert abc
  [ "$status" -eq 64 ]
  run "$VM2LXC" convert 12
  [ "$status" -eq 64 ]
  run "$VM2LXC" convert '100; rm -rf /'
  [ "$status" -eq 64 ]
  run "$VM2LXC" undo
  [ "$status" -eq 64 ]
  run "$VM2LXC" cleanup extra
  [ "$status" -eq 64 ]
}

@test "global flags are accepted before and after the subcommand, in any order" {
  run "$VM2LXC" --yes --dry-run --no-tui --answers /does/not/matter convert 100
  [ "$status" -eq 70 ]
  run "$VM2LXC" convert 100 --yes --dry-run --no-tui --answers=/does/not/matter --node=pve1
  [ "$status" -eq 70 ]
}

@test "vmid_valid accepts real VM ids and rejects everything else" {
  load_libs common
  local good bad
  for good in 100 101 999999999; do vmid_valid "$good" || { echo "rejected $good"; return 1; }; done
  for bad in '' 0 99 abc 10a '1 00' '-100' '100;ls' '1000000000'; do
    if vmid_valid "$bad"; then echo "accepted '$bad'"; return 1; fi
  done
}
