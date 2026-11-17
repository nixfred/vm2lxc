# shellcheck shell=bash
# Shared bats helpers. Tests never need a Proxmox host: they run the real code
# against canned files (tests/fixtures) via VM2LXC_FIXTURE_DIR.

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
VM2LXC="$REPO_ROOT/vm2lxc"
FIXTURES="$REPO_ROOT/tests/fixtures"

# No colour in captured output, whatever the terminal says.
export NO_COLOR=1

# Source the libraries into the test shell so unit tests can call functions directly.
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
