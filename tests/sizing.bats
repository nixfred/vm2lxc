#!/usr/bin/env bats
# Sizing from RRD history: the jq stats, timeframe choice, confidence and the choices.
# Expected numbers are worked out by hand in the comments.

bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_fixture_host
  # Serve RRD from files the test writes, instead of the fixture host.
  pve_rrddata() {
    local f="$BATS_TEST_TMPDIR/rrd-$2.json"
    [[ -r $f ]] || return 1
    cat "$f"
  }
}

put_rrd() { # <timeframe> <json>
  printf '%s' "$2" >"$BATS_TEST_TMPDIR/rrd-$1.json"
}

# stats <json> -> the TSV line from the jq program
stats() {
  printf '%s' "$1" | jq -r "$SIZING_JQ"
}

# field <tsv> <1-based index>
field() {
  cut -f"$2" <<<"$1"
}

# Fill SZ by hand for the judgement tests (fields as sizing_collect would set them).
# set_sz <span_min> <density> <near_max> <step_min> [mem_p95 mem_max cpu_p95_c100 cpu_max_c100]
set_sz() {
  SZ=([tf]=month [samples]=50 [step_min]=$4 [span_min]=$1 [density]=$2 [mem_p95]=${5:-600}
    [mem_max]=${6:-801} [maxmem]=4096 [cpu_p95]=${7:-31} [cpu_max]=${8:-120} [maxcpu]=4 [near_max]=$3)
}

# --- the jq stats program ---------------------------------------------------------

@test "p95 is nearest-rank with integer maths: 100 samples of 1..100M give exactly 95M, max 100M" {
  local line
  line=$(stats "$(make_rrd 100 43200 1731000000 '((. + 1) * 1048576)')")
  [ "$(field "$line" 1)" -eq 100 ]     # samples
  [ "$(field "$line" 2)" -eq 43200 ]   # step_s
  [ "$(field "$line" 3)" -eq 72000 ]   # span_min = 100 rows x 43200s / 60
  [ "$(field "$line" 4)" -eq 100 ]     # density %
  [ "$(field "$line" 5)" -eq 95 ]      # mem_p95_mb
  [ "$(field "$line" 6)" -eq 100 ]     # mem_max_mb
  [ "$(field "$line" 7)" -eq 4096 ]    # maxmem_mb
}

@test "p95 index is exact at the boundaries where floating point would be off by one" {
  # n -> ceil(n * 0.95): 1->1, 20->19, 21->20, 40->38, 60->57, 100->95, 101->96
  local n want line
  for pair in 1:1 20:19 21:20 40:38 60:57 100:95 101:96; do
    n=${pair%%:*} want=${pair##*:}
    line=$(stats "$(make_rrd "$n" 60 1731000000 '((. + 1) * 1048576)')")
    [ "$(field "$line" 5)" -eq "$want" ] || { echo "n=$n: p95 $(field "$line" 5), want $want"; return 1; }
  done
}

@test "rows come back shuffled: the program sorts by time before measuring span" {
  local json line
  json=$(make_rrd 10 600 1731000000 '((. + 1) * 1048576)' | jq -c 'reverse')
  line=$(stats "$json")
  [ "$(field "$line" 2)" -eq 600 ]
  [ "$(field "$line" 3)" -eq 100 ]   # 10 x 600s = 100 min
}

@test "gap rows (no mem key, or null) are not samples and lower the density" {
  local line
  # 5 rows 60s apart; mem present on rows 0, 1 and 4 only
  line=$(stats '[{"time":0,"mem":1048576,"cpu":0.1,"maxcpu":2,"maxmem":4294967296},
                 {"time":60,"mem":2097152,"cpu":0.1,"maxcpu":2,"maxmem":4294967296},
                 {"time":120},
                 {"time":180,"mem":null,"cpu":null},
                 {"time":240,"mem":3145728,"cpu":0.1,"maxcpu":2,"maxmem":4294967296}]')
  [ "$(field "$line" 1)" -eq 3 ]   # samples
  [ "$(field "$line" 3)" -eq 5 ]   # span: (240 - 0 + 60) / 60
  [ "$(field "$line" 4)" -eq 60 ]  # density: 3 of 5 expected
  [ "$(field "$line" 6)" -eq 3 ]   # max 3 MB
}

@test "cpu is reported in hundredths of a core: 25% of 4 vCPUs is 1.00 core" {
  local line
  line=$(stats "$(make_rrd 50 60 1731000000 '(100 * 1048576)' 4294967296 4 0.25)")
  [ "$(field "$line" 8)" -eq 100 ]
  [ "$(field "$line" 9)" -eq 100 ]
  [ "$(field "$line" 10)" -eq 4 ]
}

@test "near_max flags a guest whose p95 memory is within 10% of its RAM" {
  local line
  line=$(stats "$(make_rrd 50 60 1731000000 '(3900 * 1048576)' 4294967296)")   # 3900M of 4096M
  [ "$(field "$line" 11)" -eq 1 ]
  line=$(stats "$(make_rrd 50 60 1731000000 '(1000 * 1048576)' 4294967296)")
  [ "$(field "$line" 11)" -eq 0 ]
}

@test "empty, non-array and time-only input do not crash: zero samples" {
  local json line
  for json in '[]' 'null' '{}' '[{"time":1},{"time":2}]' '[1,2,"x"]'; do
    line=$(stats "$json") || { echo "jq failed on $json"; return 1; }
    [ "$(field "$line" 1)" -eq 0 ] || { echo "samples on $json: $(field "$line" 1)"; return 1; }
  done
}

@test "malformed JSON makes the program fail (so sizing_collect skips that timeframe)" {
  run stats 'this is not json'
  [ "$status" -ne 0 ]
}

# --- choosing the timeframe ---------------------------------------------------------

@test "sizing_collect: the longest history wins, here month" {
  put_rrd month "$(make_rrd 70 43200 1731000000 '(600 * 1048576)')"   # 70 x 12h = 35 days
  put_rrd week "$(make_rrd 56 10800 1731000000 '(600 * 1048576)')"    # 7 days
  put_rrd day "$(make_rrd 48 1800 1731000000 '(600 * 1048576)')"      # 1 day
  sizing_collect 100
  [ "${SZ[tf]}" = month ]
  [ "${SZ[span_min]}" -eq 50400 ]
}

@test "sizing_collect: when month errors out, it falls back to week" {
  put_rrd week "$(make_rrd 56 10800 1731000000 '(600 * 1048576)')"
  put_rrd day "$(make_rrd 48 1800 1731000000 '(600 * 1048576)')"
  sizing_collect 100
  [ "${SZ[tf]}" = week ]
}

@test "sizing_collect: with only day available it uses day" {
  put_rrd day "$(make_rrd 48 1800 1731000000 '(600 * 1048576)')"
  sizing_collect 100
  [ "${SZ[tf]}" = day ]
}

@test "sizing_collect: on a near tie the finer timeframe wins (coarse steps average peaks away)" {
  # a 3-day-old VM: month (12h steps) and week (3h steps) both hold ~3 days
  put_rrd month "$(jq -n '[range(0;70) | {time: (1731000000 + . * 43200), mem: (if . < 6 then 600*1048576 else null end), maxmem: 4294967296, cpu: 0.1, maxcpu: 4}] | map(select(.mem != null))')"
  put_rrd week "$(make_rrd 24 10800 1731000000 '(600 * 1048576)')"
  sizing_collect 100
  [ "${SZ[tf]}" = week ]
}

@test "sizing_collect: nothing readable leaves SZ empty, and judge says unavailable" {
  sizing_collect 100
  [ "${#SZ[@]}" -eq 0 ]
  sizing_judge 4096 4
  [ "${SZ[confidence]}" = unavailable ]
  [ "${SZ[mode]}" = keep ]
}

@test "sizing_collect: a timeframe with garbage JSON is skipped, not fatal" {
  put_rrd month 'garbage'
  put_rrd week "$(make_rrd 56 10800 1731000000 '(600 * 1048576)')"
  sizing_collect 100
  [ "${SZ[tf]}" = week ]
}

# --- confidence ---------------------------------------------------------------------

@test "confidence thresholds: 24h, 7d and 21d are the exact boundaries" {
  local pair span want
  for pair in 0:insufficient 1439:insufficient 1440:low 10079:low 10080:medium 30239:medium 30240:high; do
    span=${pair%%:*} want=${pair##*:}
    set_sz "$span" 100 0 5
    sizing_judge 4096 4
    [ "${SZ[confidence]}" = "$want" ] || { echo "span $span: ${SZ[confidence]}, want $want"; return 1; }
  done
}

@test "no samples at all is 'none'" {
  set_sz 60000 100 0 5
  SZ[samples]=0
  sizing_judge 4096 4
  [ "${SZ[confidence]}" = none ]
  [ "${SZ[mode]}" = keep ]
}

@test "sparse history (under 50% of samples) steps confidence down once, never below low" {
  set_sz 40000 49 0 5; sizing_judge 4096 4; [ "${SZ[confidence]}" = medium ]   # high -> medium
  set_sz 20000 49 0 5; sizing_judge 4096 4; [ "${SZ[confidence]}" = low ]      # medium -> low
  set_sz 5000 49 0 5;  sizing_judge 4096 4; [ "${SZ[confidence]}" = low ]      # low stays low
  set_sz 40000 50 0 5; sizing_judge 4096 4; [ "${SZ[confidence]}" = high ]     # 50% is not sparse
  [[ ${SZ[note]} != *"expected samples"* ]]
  set_sz 40000 10 0 5; sizing_judge 4096 4
  [[ ${SZ[note]} == *"only 10% of the expected samples"* ]]
}

@test "a guest pinned near max memory is capped at low confidence, with a warning" {
  set_sz 40000 100 1 5
  sizing_judge 4096 4
  [ "${SZ[confidence]}" = low ]
  [[ ${SZ[note]} == *"may not report real usage"* ]]
}

@test "coarse RRD steps (30 minutes or more) add the smoothed-peaks warning, fine steps do not" {
  set_sz 40000 100 0 720; sizing_judge 4096 4
  [[ ${SZ[note]} == *"720-minute averages"* ]]
  set_sz 40000 100 0 29; sizing_judge 4096 4
  [[ ${SZ[note]} != *"averages"* ]]
  set_sz 40000 100 0 30; sizing_judge 4096 4
  [[ ${SZ[note]} == *"30-minute averages"* ]]
}

# --- the size choices ---------------------------------------------------------------

@test "under 24h of data keeps the current size: no choices are offered (D8)" {
  set_sz 600 100 0 5
  sizing_judge 4096 4
  [ "${SZ[confidence]}" = insufficient ]
  [ "${SZ[mode]}" = keep ]
  [ -z "${SZ[mem_lean]:-}" ]
  [ "$(sizing_saved_mb)" -eq 0 ]
}

@test "memory choices: p95 600M, max 801M on a 4096M VM -> lean 704M, recommended 896M, saves 3200M" {
  # lean = up64(ceil(600 x 1.15 = 690)) = 704
  # rec  = up64(max(ceil(600 x 1.25 = 750), ceil(801 x 1.10 = 881.1) = 882)) = up64(882) = 896
  set_sz 50400 99 0 5 600 801
  sizing_judge 4096 4
  [ "${SZ[mode]}" = choices ]
  [ "${SZ[mem_lean]}" -eq 704 ]
  [ "${SZ[mem_rec]}" -eq 896 ]
  [ "$(sizing_saved_mb)" -eq 3200 ]
}

@test "memory choices never exceed the current size" {
  # p95 480 / max 500 on a 512M VM: lean 576 and rec 640 are both clamped to 512
  set_sz 50400 99 0 5 480 500
  sizing_judge 512 2
  [ "${SZ[mem_lean]}" -eq 512 ]
  [ "${SZ[mem_rec]}" -eq 512 ]
  [ "$(sizing_saved_mb)" -eq 0 ]
}

@test "memory choices have floors: 128M lean, 256M recommended" {
  set_sz 50400 99 0 5 10 12
  sizing_judge 4096 4
  [ "${SZ[mem_lean]}" -eq 128 ]
  [ "${SZ[mem_rec]}" -eq 256 ]
}

@test "recommended follows max when max is the bigger driver" {
  # p95 100 -> 125; max 2000 -> ceil(2200) = 2200 -> up64 = 2240
  set_sz 50400 99 0 5 100 2000
  sizing_judge 8192 4
  [ "${SZ[mem_rec]}" -eq 2240 ]
}

@test "unknown current memory means keep: we will not invent a baseline" {
  set_sz 50400 99 0 5
  sizing_judge "" 4
  [ "${SZ[mode]}" = keep ]
}

@test "cpu choices: p95 0.31 / max 1.20 cores on 4 -> lean 1, recommended 2; clamped at the VM's cores" {
  # lean = ceil(0.31 x 1.5 = 0.465) = 1 ; rec = ceil(1.20 x 1.25 = 1.5) = 2
  set_sz 50400 99 0 5 600 801 31 120
  sizing_judge 4096 4
  [ "${SZ[cpu_lean]}" -eq 1 ]
  [ "${SZ[cpu_rec]}" -eq 2 ]
  # max 4.00 cores -> ceil(5.0) = 5, clamped to the 4 the VM has
  set_sz 50400 99 0 5 600 801 300 400
  sizing_judge 4096 4
  [ "${SZ[cpu_lean]}" -eq 4 ]
  [ "${SZ[cpu_rec]}" -eq 4 ]
}

@test "cpu choices round UP: exactly 1.00 core used -> lean ceil(1.5) = 2, not 1" {
  # floor would give lean 1, which is less than the core the guest was really using
  set_sz 50400 99 0 5 600 801 100 100
  sizing_judge 4096 4
  [ "${SZ[cpu_lean]}" -eq 2 ]   # ceil(1.00 x 1.5)
  [ "${SZ[cpu_rec]}" -eq 2 ]    # ceil(1.00 x 1.25)
}

@test "cpu recommended is never below lean, even when max is close to p95" {
  # p95 0.68 cores -> lean ceil(1.02) = 2 ; max 0.68 -> ceil(0.85) = 1 would be BELOW lean, so it is raised to 2
  set_sz 50400 99 0 5 600 801 68 68
  sizing_judge 4096 4
  [ "${SZ[cpu_lean]}" -eq 2 ]
  [ "${SZ[cpu_rec]}" -eq 2 ]
}

@test "density is capped at 100 when rows are spaced unevenly (more samples than the step predicts)" {
  local line
  # step is read from the first two rows (3600s); the rest are 60s apart, so naive
  # density would be 5 samples / 2.05 expected = 243%
  line=$(stats '[{"time":0,"mem":1048576},{"time":3600,"mem":1048576},{"time":3660,"mem":1048576},
                 {"time":3720,"mem":1048576},{"time":3780,"mem":1048576}]')
  [ "$(field "$line" 1)" -eq 5 ]
  [ "$(field "$line" 4)" -eq 100 ]
}

# --- config readers and formatting ----------------------------------------------------

@test "up64 rounds up to a multiple of 64" {
  [ "$(up64 1)" -eq 64 ]
  [ "$(up64 64)" -eq 64 ]
  [ "$(up64 65)" -eq 128 ]
  [ "$(up64 882)" -eq 896 ]
}

@test "qmc_memory_mb reads plain and current= forms, and nothing when absent" {
  qmconf_parse <<<'memory: 4096'
  [ "$(qmc_memory_mb)" = 4096 ]
  qmconf_parse <<<'memory: current=2048,max=8192'
  [ "$(qmc_memory_mb)" = 2048 ]
  qmconf_parse <<<'cores: 2'
  [ -z "$(qmc_memory_mb)" ]
}

@test "qmc_cores multiplies cores by sockets and survives garbage" {
  qmconf_parse <<<$'cores: 4\nsockets: 2'
  [ "$(qmc_cores)" -eq 8 ]
  qmconf_parse <<<'cores: 3'
  [ "$(qmc_cores)" -eq 3 ]
  qmconf_parse <<<'cores: many'
  [ "$(qmc_cores)" -eq 1 ]
}

@test "fmt_c100 prints hundredths of a core" {
  [ "$(fmt_c100 31)" = "0.31" ]
  [ "$(fmt_c100 120)" = "1.20" ]
  [ "$(fmt_c100 5)" = "0.05" ]
  [ "$(fmt_c100 -)" = "n/a" ]
}

# --- the printed block ------------------------------------------------------------------

@test "sizing_print: a long history shows p95, max, choices and the saving" {
  set_sz 50400 99 0 5 600 801 31 120
  SZ[cur_mem]=4096
  sizing_judge 4096 4
  run sizing_print
  [[ $output == *"confidence MEDIUM"* || $output == *"confidence HIGH"* ]]
  [[ $output == *"memory  p95 600M  max 801M  now 4096M"* ]]
  [[ $output == *"lean 704M | recommended 896M | keep 4096M"* ]]
  [[ $output == *"RAM saved"*"3200M"* ]]
  [[ $output == *"cpu     p95 0.31 cores  max 1.20 cores"* ]]
}

@test "sizing_print: under 24h says keep the current size and does not offer choices" {
  set_sz 600 100 0 5
  sizing_judge 4096 4
  run sizing_print
  [[ $output == *"confidence INSUFFICIENT"* ]]
  [[ $output == *"Under 24h of history: keep the current size"* ]]
  [[ $output != *"choices:"* ]]
}

@test "sizing_print: no readable history says so plainly" {
  SZ=()
  sizing_judge 4096 4
  run sizing_print
  [[ $output == *"could not be read"* ]]
}
