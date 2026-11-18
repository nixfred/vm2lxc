#!/usr/bin/env bash
# A scripted stand-in for whiptail, for the menu tests. Installed as a symlink named `whiptail`, first on PATH.
#
#   WT_SCRIPT  a file with one answer per QUESTION dialog (menu, inputbox, yesno), used in order:
#                ok VALUE     exit 0 and print VALUE on stderr (the chosen tag, or the typed text)
#                yes | no     for a yesno: exit 0 / 1
#                cancel       exit 1 (the Cancel button)
#                esc          exit 255
#   WT_LOG     appended to: "<kind><TAB><the arguments, shell-quoted>" for every dialog, and
#              "gauge<TAB><percent><TAB><text>" for every progress-bar frame it is fed;
#              "$WT_LOG.text" gets the content of every textbox at the moment it was shown
#
# msgbox, textbox and infobox always answer OK without using the script; a gauge reads its stdin to the end.
# When the script runs out the stub answers Esc and logs EXHAUSTED, so a test that walks further than it
# planned fails loudly instead of hanging. Like the real whiptail, the selection goes to stderr.
set -u
log=${WT_LOG:?WT_LOG not set}
kind=""
for a in "$@"; do
  case $a in
    --menu | --inputbox | --yesno | --msgbox | --textbox | --gauge | --infobox) kind=${a#--} ;;
  esac
done
{
  printf '%s\t' "$kind"
  printf '%q ' "$@"
  printf '\n'
} >>"$log"

case $kind in
  gauge)
    st=0 pct=""
    while IFS= read -r l; do
      case $st in
        0) if [[ $l == XXX ]]; then st=1; fi ;;
        1) pct=$l st=2 ;;
        2)
          printf 'gauge\t%s\t%s\n' "$pct" "$l" >>"$log"
          st=3
          ;;
        3) if [[ $l == XXX ]]; then st=0; fi ;;
      esac
    done
    exit 0
    ;;
  textbox)
    # remember what was on screen, at the moment it was shown ("$WT_LOG.text"): the file is gone when the menu ends
    prev=""
    for a in "$@"; do
      if [[ $prev == --textbox ]]; then
        {
          printf '=== textbox\n'
          cat -- "$a" 2>&1
          printf '\n'
        } >>"$log.text"
      fi
      prev=$a
    done
    exit 0
    ;;
  msgbox | infobox) exit 0 ;;
esac

script=${WT_SCRIPT:?WT_SCRIPT not set}
pos=$(($(cat "$script.pos" 2>/dev/null || echo 0) + 1))
printf '%s' "$pos" >"$script.pos"
line=$(sed -n "${pos}p" "$script" 2>/dev/null)
if [[ -z $line ]]; then
  echo EXHAUSTED >>"$log"
  exit 255
fi
verb=${line%% *}
val=""
if [[ $line == *" "* ]]; then val=${line#* }; fi
case $verb in
  ok)
    printf '%s' "$val" >&2
    exit 0
    ;;
  yes) exit 0 ;;
  no | cancel) exit 1 ;;
  esc) exit 255 ;;
esac
echo "BAD SCRIPT LINE: $line" >>"$log"
exit 255
