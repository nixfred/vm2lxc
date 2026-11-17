# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# The findings engine. Every check, host-level or guest-level, reports through
# `finding`, and the verdict is computed from the pile.
#
#   level   meaning
#   red     blocks conversion
#   yellow  convertible, but read this first
#   info    worth knowing, never changes the verdict
#   pending a check that has not been able to run yet (needs disk inspection)
#
#   kind    where the problem comes from
#   vm      the VM itself (hardware, OS, workload)
#   tool    a v1 limit of vm2lxc, not a fault of the VM
#   guest   found inside the guest filesystem

declare -ga F_LEVEL=() F_ID=() F_KIND=() F_MSG=()
VERDICT=green N_RED=0 N_YELLOW=0 N_INFO=0 N_PENDING=0

findings_reset() {
  F_LEVEL=() F_ID=() F_KIND=() F_MSG=()
  VERDICT=green N_RED=0 N_YELLOW=0 N_INFO=0 N_PENDING=0
}

# finding <level> <id> <kind> <message>
finding() {
  case $1 in
    red | yellow | info | pending) ;;
    *) die "$EXIT_USAGE" "internal error: bad finding level '$1' from check '$2'" ;;
  esac
  case $3 in
    vm | tool | guest) ;;
    *) die "$EXIT_USAGE" "internal error: bad finding kind '$3' from check '$2'" ;;
  esac
  F_LEVEL+=("$1")
  F_ID+=("$2")
  F_KIND+=("$3")
  F_MSG+=("$4")
}

# verdict_compute: worst level wins. `pending` and `info` never change the verdict.
verdict_compute() {
  local l
  VERDICT=green N_RED=0 N_YELLOW=0 N_INFO=0 N_PENDING=0
  for l in "${F_LEVEL[@]}"; do
    case $l in
      red) N_RED=$((N_RED + 1)) ;;
      yellow) N_YELLOW=$((N_YELLOW + 1)) ;;
      info) N_INFO=$((N_INFO + 1)) ;;
      pending) N_PENDING=$((N_PENDING + 1)) ;;
    esac
  done
  if ((N_RED > 0)); then
    VERDICT=red
  elif ((N_YELLOW > 0)); then
    VERDICT=yellow
  fi
}

verdict_exit_code() {
  case $VERDICT in
    red) printf '%s' "$EXIT_RED" ;;
    yellow) printf '%s' "$EXIT_YELLOW" ;;
    *) printf '%s' "$EXIT_OK" ;;
  esac
}

# top_reason: the one-line "why" for scan. First red, else first yellow, else empty.
# A v1 limit is tagged so it is not mistaken for a fault of the VM.
top_reason() {
  local want i
  for want in red yellow; do
    for i in "${!F_LEVEL[@]}"; do
      if [[ ${F_LEVEL[$i]} == "$want" ]]; then
        if [[ ${F_KIND[$i]} == tool ]]; then
          printf '%s (v1 limit)' "${F_MSG[$i]}"
        else
          printf '%s' "${F_MSG[$i]}"
        fi
        return 0
      fi
    done
  done
  return 1
}
