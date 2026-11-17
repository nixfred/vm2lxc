# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other lib files
# Sizing from the VM's own RRD history (D8): p95/max of memory and CPU, a confidence
# label, and a choice of container sizes. Under 24h of data we do not guess: keep the
# current size.
#
# Method
#   * fetch month, week and day (pvesh ... rrddata). Use the one with the longest
#     history; on a near tie (>= 90% of the best span) prefer the finer one, because
#     coarse RRD steps average the peaks away.
#   * p95 is nearest-rank, computed with integer maths so 20 samples give exactly the
#     19th value, not a floating point surprise.
#   * confidence: none (no samples) < insufficient (< 24h) < low (< 7d) < medium (< 21d)
#     < high. Sparse data (< 50% of expected samples) steps it down once. If p95 memory
#     sits within 10% of the VM's RAM the guest probably is not reporting real usage,
#     and confidence is capped at low.
#   * memory choices: lean = p95 x 1.15, recommended = max(p95 x 1.25, max x 1.10),
#     each rounded up to 64M, floors 128M / 256M, never above the current size.
#   * CPU choices (a core limit is a cap, not a reservation): lean = p95 cores x 1.5,
#     recommended = max cores x 1.25, rounded up, at least 1, never above current.

# Reads a JSON array of RRD rows on stdin, prints one TSV line:
# samples step_s span_min density_pct mem_p95_mb mem_max_mb maxmem_mb cpu_p95_c100 cpu_max_c100 maxcpu near_max
# (null becomes "-"; c100 = cores x 100). Kept to jq 1.6 features: PVE 8 ships jq 1.6.
# shellcheck disable=SC2016  # a jq program: the single quotes are deliberate
SIZING_JQ='
def p95: if length == 0 then null else (sort | .[(((length * 95 + 99) / 100) | floor) - 1]) end;
def mx: if length == 0 then null else max end;
def lastv: if length == 0 then null else .[length - 1] end;
def num: type == "number";
def mb: if . == null then null else ((. / 1048576) | ceil) end;
(if type == "array" then . else [] end
  | map(select(type == "object" and (.time | num)))
  | sort_by(.time)) as $rows
| ($rows | map(select(.mem | num))) as $m
| ($rows | map(select(.cpu | num))) as $c
| (if ($rows | length) >= 2 then ($rows[1].time - $rows[0].time) else 0 end) as $step
| ($m | map(.time)) as $mt
| (if ($mt | length) == 0 then 0 else (($mt | lastv) - $mt[0] + $step) end) as $span
| (if ($mt | length) == 0 or $step <= 0 then 0
   else ((((($mt | lastv) - $mt[0]) / $step) + 1)) end) as $expected
| ($rows | map(select(.maxmem | num) | .maxmem) | lastv) as $maxmem
| ($rows | map(select(.maxcpu | num) | .maxcpu) | lastv) as $maxcpu
| ($m | map(.mem) | p95) as $memp95
| ($m | map(.mem) | mx) as $memmax
| ($c | map(.cpu) | p95) as $cpup95
| ($c | map(.cpu) | mx) as $cpumax
| [ ($m | length),
    $step,
    (($span / 60) | floor),
    (if $expected > 0 then ((($m | length) * 100 / $expected) | floor | if . > 100 then 100 else . end) else 0 end),
    ($memp95 | mb),
    ($memmax | mb),
    ($maxmem | mb),
    (if $cpup95 == null or $maxcpu == null then null else (($cpup95 * $maxcpu * 100) | round) end),
    (if $cpumax == null or $maxcpu == null then null else (($cpumax * $maxcpu * 100) | round) end),
    $maxcpu,
    (if $memp95 != null and $maxmem != null and $maxmem > 0 and ($memp95 >= ($maxmem * 0.9)) then 1 else 0 end)
  ]
| map(. // "-") | @tsv
'

declare -gA SZ=()

# sizing_collect <vmid>: fetch history and pick the timeframe. SZ is empty if no
# timeframe could be read at all.
sizing_collect() {
  local vmid=$1 tf json line best_span=-1
  local samples step_s span_min density mem_p95 mem_max maxmem cpu_p95 cpu_max maxcpu near_max
  SZ=()
  for tf in month week day; do
    json=$(pve_rrddata "$vmid" "$tf" 2>/dev/null) || continue
    line=$(printf '%s' "$json" | jq -r "$SIZING_JQ" 2>/dev/null) || continue
    [[ -n $line ]] || continue
    IFS=$'\t' read -r samples step_s span_min density mem_p95 mem_max maxmem cpu_p95 cpu_max maxcpu near_max <<<"$line"
    if ((best_span < 0 || span_min * 10 >= best_span * 9)); then
      best_span=$span_min
      SZ=([tf]=$tf [samples]=$samples [step_min]=$(((step_s + 30) / 60)) [span_min]=$span_min
        [density]=$density [mem_p95]=$mem_p95 [mem_max]=$mem_max [maxmem]=$maxmem
        [cpu_p95]=$cpu_p95 [cpu_max]=$cpu_max [maxcpu]=$maxcpu [near_max]=$near_max)
    fi
  done
}

# up64 <mb>: round up to a multiple of 64.
up64() {
  echo $((($1 + 63) / 64 * 64))
}

# Memory (MB) and cores configured on the VM, from qm config.
qmc_memory_mb() {
  local v=${QMC[memory]:-}
  if [[ $v =~ ^[0-9]+$ ]]; then
    echo "$v"
  elif [[ $v =~ current=([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

qmc_cores() {
  local c=${QMC[cores]:-1} s=${QMC[sockets]:-1}
  [[ $c =~ ^[0-9]+$ ]] || c=1
  [[ $s =~ ^[0-9]+$ ]] || s=1
  echo $((c * s))
}

# sizing_judge <current_mem_mb> <current_cores>: confidence + choices into SZ.
sizing_judge() {
  local cur_mem=$1 cur_cores=$2
  local s span dens stepm conf note="" p95 mx lean rec rmax c95 cmx cl cr
  local had_data=1
  [[ -n ${SZ[tf]:-} ]] || had_data=0
  SZ[cur_mem]=$cur_mem
  SZ[cur_cores]=$cur_cores
  SZ[note]=""
  SZ[mode]=keep
  if ((had_data == 0)); then
    SZ[confidence]=unavailable
    return 0
  fi
  s=${SZ[samples]} span=${SZ[span_min]} dens=${SZ[density]} stepm=${SZ[step_min]}
  if ((s == 0)); then
    conf=none
  elif ((span < 1440)); then
    conf=insufficient
  elif ((span < 10080)); then
    conf=low
  elif ((span < 30240)); then
    conf=medium
  else
    conf=high
  fi
  if ((dens < 50)); then
    case $conf in
      high) conf=medium ;;
      medium) conf=low ;;
    esac
    note+="only ${dens}% of the expected samples exist (gaps: VM was off, or history is patchy). "
  fi
  if [[ ${SZ[near_max]} == 1 ]]; then
    case $conf in
      medium | high) conf=low ;;
    esac
    note+="p95 memory is within 10% of the VM's RAM: the guest may not report real usage (no balloon driver or guest agent?), so do not trust a saving here. "
  fi
  if ((stepm >= 30)); then
    note+="RRD points are ${stepm}-minute averages, so short peaks are smoothed away: treat p95 and max as lower bounds. "
  fi
  SZ[confidence]=$conf
  SZ[note]=$note
  case $conf in
    none | insufficient) return 0 ;;
  esac
  [[ ${SZ[mem_p95]} != - && -n $cur_mem ]] || return 0
  SZ[mode]=choices
  p95=${SZ[mem_p95]} mx=${SZ[mem_max]}
  lean=$(up64 $(((p95 * 115 + 99) / 100)))
  rec=$(((p95 * 125 + 99) / 100))
  rmax=$(((mx * 110 + 99) / 100))
  if ((rmax > rec)); then rec=$rmax; fi
  rec=$(up64 "$rec")
  if ((lean < 128)); then lean=128; fi
  if ((rec < 256)); then rec=256; fi
  if ((lean > cur_mem)); then lean=$cur_mem; fi
  if ((rec > cur_mem)); then rec=$cur_mem; fi
  SZ[mem_lean]=$lean
  SZ[mem_rec]=$rec
  if [[ ${SZ[cpu_p95]} != - && ${SZ[cpu_max]} != - ]]; then
    c95=${SZ[cpu_p95]} cmx=${SZ[cpu_max]}
    cl=$(((c95 * 150 + 9999) / 10000))
    cr=$(((cmx * 125 + 9999) / 10000))
    if ((cl < 1)); then cl=1; fi
    if ((cr < 1)); then cr=1; fi
    if ((cl > cur_cores)); then cl=$cur_cores; fi
    if ((cr > cur_cores)); then cr=$cur_cores; fi
    SZ[cpu_lean]=$cl
    SZ[cpu_rec]=$cr
  fi
  return 0
}

# RAM saved by taking the "recommended" size, in MB. 0 when we keep the current size.
sizing_saved_mb() {
  local cur rec
  if [[ ${SZ[mode]:-keep} == choices ]]; then
    cur=${SZ[cur_mem]}
    rec=${SZ[mem_rec]}
    echo $((cur - rec))
  else
    echo 0
  fi
}

# Hundredths of a core -> "0.31".
fmt_c100() {
  if [[ $1 == - ]]; then
    printf 'n/a'
  else
    printf '%d.%02d' $(($1 / 100)) $(($1 % 100))
  fi
}

# Total allocated size of the data disks, in MB (empty if any size is unknown).
disks_total_mb() {
  local i total=0
  for i in "${!D_KEY[@]}"; do
    if [[ ${D_KIND[$i]} == data ]]; then
      [[ -n ${D_SIZE_MB[$i]} ]] || return 1
      total=$((total + D_SIZE_MB[i]))
    fi
  done
  echo "$total"
}

sizing_print() {
  local span_txt
  if [[ ${SZ[confidence]:-unavailable} == unavailable ]]; then
    printf '  RRD history could not be read (pvesh rrddata failed for month, week and day): keep the current size.\n'
    return 0
  fi
  span_txt=$(awk -v m="${SZ[span_min]}" 'BEGIN { if (m >= 1440) printf "%.1f days", m / 1440; else printf "%.1f hours", m / 60 }')
  printf '  rrddata timeframe=%s, %s of data, %s%% of samples, confidence %s\n' \
    "${SZ[tf]}" "$span_txt" "${SZ[density]}" "${SZ[confidence]^^}"
  case ${SZ[confidence]} in
    none)
      printf '  No usable samples: keep the current size (memory %sM, cores %s).\n' "${SZ[cur_mem]:-?}" "${SZ[cur_cores]}"
      ;;
    insufficient)
      printf '  Under 24h of history: keep the current size (memory %sM, cores %s). Seen so far: memory p95 %sM, max %sM.\n' \
        "${SZ[cur_mem]:-?}" "${SZ[cur_cores]}" "${SZ[mem_p95]}" "${SZ[mem_max]}"
      ;;
    *)
      printf '  memory  p95 %sM  max %sM  now %sM\n' "${SZ[mem_p95]}" "${SZ[mem_max]}" "${SZ[cur_mem]:-?}"
      if [[ ${SZ[mode]} == choices ]]; then
        printf '          choices: lean %sM | recommended %sM | keep %sM\n' "${SZ[mem_lean]}" "${SZ[mem_rec]}" "${SZ[cur_mem]}"
        printf '          RAM saved at "recommended": %sM\n' "$(sizing_saved_mb)"
      fi
      printf '  cpu     p95 %s cores  max %s cores  now %s (a core limit is a cap, not a reservation)\n' \
        "$(fmt_c100 "${SZ[cpu_p95]}")" "$(fmt_c100 "${SZ[cpu_max]}")" "${SZ[cur_cores]}"
      if [[ -n ${SZ[cpu_lean]:-} ]]; then
        printf '          choices: lean %s | recommended %s | keep %s\n' "${SZ[cpu_lean]}" "${SZ[cpu_rec]}" "${SZ[cur_cores]}"
      fi
      ;;
  esac
  if [[ -n ${SZ[note]} ]]; then
    printf '  note: %s\n' "${SZ[note]% }"
  fi
}
