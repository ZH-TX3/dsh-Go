#!/usr/bin/env bash
# Reads the current screen through the app's accessibility probe and prints it as JSON.
# The read is one accessibility capture (tens of milliseconds); what you wait on is mostly
# `am broadcast` starting a process on the phone, so a whole call is a few hundred ms.
#
#   tooling/a11y-dump.sh                    whole tree, to stdout
#   tooling/a11y-dump.sh -o screen.json     keep a copy
#   tooling/a11y-dump.sh --budget 800       more time for a big tree (default 400 ms)
#   tooling/a11y-dump.sh -s emulator-5554   pick the device
#   tooling/a11y-dump.sh --commands         the probe's other commands
#
# Needs the app installed and its accessibility service switched on (设置 → 无障碍). The
# broadcast is protected by android.permission.DUMP, so only adb shell can send it. The JSON
# comes from /sdcard/Android/data/io.github.ccch1mneyyy.dsh_app/files/a11y-probe/tree.json;
# the schema is documented in app/…/phone/a11y/TreeJson.kt.
set -euo pipefail

pkg=io.github.ccch1mneyyy.dsh_app
name=tree
budget=400
seq=$RANDOM
out=''
serial=()

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "a11y-dump: $*" >&2; exit 1; }

probe=app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/phone/a11y/A11yProbe.kt

while (($#)); do
  case "$1" in
    -o | --out) out=${2:?--out needs a file}; shift 2 ;;
    -s | --serial) serial=(-s "${2:?--serial needs a device}"); shift 2 ;;
    --budget) budget=${2:?--budget needs milliseconds}; shift 2 ;;
    --seq) seq=${2:?--seq needs a number}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    --commands)
      echo "am broadcast -a $pkg.A11Y_PROBE --es cmd <cmd> --ei seq N"
      echo "cmds: dump ping screen target tap type scroll key tapxy open collect fg windows"
      echo "      status confirm handoff injecttest guard begin finish overlay palette"
      echo "full list: $probe"
      exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

command -v adb >/dev/null 2>&1 || die "adb is not on PATH"
[[ $seq =~ ^[0-9]+$ ]] || die "seq must be a number: $seq"
[[ $budget =~ ^[0-9]+$ ]] || die "budget must be milliseconds: $budget"

remote=/sdcard/Android/data/$pkg/files/a11y-probe/$name.json

adb "${serial[@]}" shell am broadcast \
  -a "$pkg.A11Y_PROBE" \
  --es cmd dump --es name "$name" --ei seq "$seq" --ei budget "$budget" >/dev/null

# `am broadcast` returns when the broadcast is delivered, not when the probe has written; the
# seq in the file is how we know this read, not the last one.
for _ in $(seq 1 60); do
  if adb "${serial[@]}" shell "grep -q '\"seq\":$seq' $remote" 2>/dev/null; then
    if [[ -n $out ]]; then
      adb "${serial[@]}" exec-out cat "$remote" >"$out" && echo "a11y-dump: wrote $out" >&2
      exit 0
    fi
    adb "${serial[@]}" exec-out cat "$remote"
    exit 0
  fi
  sleep 0.1
done

echo "a11y-dump: nothing after 6 s. Is the service on? (the pkg must be installed and 无障碍 enabled)" >&2
adb "${serial[@]}" logcat -d -s DshA11yProbe DshA11y | tail -20 >&2 || true
exit 1
