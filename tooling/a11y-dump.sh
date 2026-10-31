#!/usr/bin/env bash
# Reads the current screen through the app's accessibility probe and prints it as JSON.
# Two transports, same JSON:
#   broadcast (default) — one `am broadcast` per read: ~0.3-0.5 s, nothing to set up.
#   --socket            — one `adb forward` plus a token, then a read is the read alone: ~30-80 ms.
#
#   tooling/a11y-dump.sh                    whole tree, to stdout
#   tooling/a11y-dump.sh --socket           fast path; starts the listener on first use
#   tooling/a11y-dump.sh --socket --reuse   the last read when no event arrived since (≈1 ms)
#   tooling/a11y-dump.sh -o screen.json     keep a copy
#   tooling/a11y-dump.sh --budget 800       more time for a big tree (default 400 ms)
#   tooling/a11y-dump.sh -s emulator-5554   pick the device
#   tooling/a11y-dump.sh --commands         the probe's other commands
#   tooling/a11y-dump.sh --token <t>        the token the listener has (or A11Y_TOKEN=…)
#   tooling/a11y-dump.sh --stop             close the socket listener
#
# Needs the app installed and its accessibility service switched on (设置 → 无障碍). Both
# transports are protected: a broadcast needs android.permission.DUMP (adb shell only), and the
# socket answers only a token that arrived over such a broadcast. In broadcast mode the JSON comes
# from /sdcard/Android/data/<pkg>/files/a11y-probe/tree.json; the schema is documented in
# app/…/phone/a11y/TreeJson.kt.
#
# The fork's builds install as <pkg>.a11y (app/build.gradle.kts), next to an official DSH Go.
# A11Y_PKG=io.github.ccch1mneyyy.dsh_app overrides this for an unsuffixed build.
set -euo pipefail

pkg=${A11Y_PKG:-io.github.ccch1mneyyy.dsh_app.a11y}
# A constant in A11yProbe, not derived from the package: a suffixed install listens on the same one.
action=io.github.ccch1mneyyy.dsh_app.A11Y_PROBE
name=tree
budget=400
port=${A11Y_PORT:-47913}
tag=$RANDOM
out=''
serial=()
socket=0
reusable=0
stop=0
token_arg=

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "a11y-dump: $*" >&2; exit 1; }

probe=app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/phone/a11y/A11yProbe.kt

# bash 3.2 (the macOS one) reports an empty array as unset under `set -u`.
adbx() { adb ${serial[@]+"${serial[@]}"} "$@"; }

while (($#)); do
  case "$1" in
    -o | --out) out=${2:?--out needs a file}; shift 2 ;;
    -s | --serial) serial=(-s "${2:?--serial needs a device}"); shift 2 ;;
    --budget) budget=${2:?--budget needs milliseconds}; shift 2 ;;
    --port) port=${2:?--port needs a number}; shift 2 ;;
    --seq) tag=${2:?--seq needs a number}; shift 2 ;;
    --socket) socket=1; shift ;;
    --reuse) reusable=1; shift ;;
    --token) token_arg=${2:?--token needs a value}; shift 2 ;;
    --stop) stop=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --commands)
      echo "am broadcast -a $action --es cmd <cmd> --ei seq N"
      echo "cmds: dump listen unlisten ping screen target tap type scroll key tapxy open"
      echo "      collect fg windows status confirm handoff injecttest guard begin finish"
      echo "      overlay palette"
      echo "full list: $probe"
      exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

command -v adb >/dev/null 2>&1 || die "adb is not on PATH"
[[ $tag =~ ^[0-9]+$ ]] || die "seq must be a number: $tag"
[[ $budget =~ ^[0-9]+$ ]] || die "budget must be milliseconds: $budget"
[[ $port =~ ^[0-9]+$ ]] || die "port must be a number: $port"

reuse_flag=''
if ((reusable)); then reuse_flag=reuse; fi

# The socket's token lives here, mode 600: a later read does not re-broadcast. Named per device
# (adb's own default is "default") so a second device cannot answer with the first one's token.
token_file() {
  local s=${ANDROID_SERIAL:-default}
  if ((${#serial[@]})); then s=${serial[1]}; fi
  printf '%s/dsh-a11y-%s.token' "${TMPDIR:-/tmp}" "$s"
}

new_token() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 24 || true; }

# One request over the forwarded port; the body goes to stdout. Non-zero when the connection or
# the token is refused. Framing: "OK <bytes>\n<json>".
send() {
  local status n
  exec 3<>"/dev/tcp/127.0.0.1/$port" 2>/dev/null || return 1
  if ! printf '%s\n' "$1" >&3 2>/dev/null; then exec 3>&-; return 1; fi
  # -t: a listener wedged on some other client's socket must not hang this script.
  if ! IFS= read -r -t 5 status <&3; then exec 3>&-; return 1; fi
  case $status in
    "OK "*)
      n=${status#OK }
      head -c "$n" <&3
      exec 3>&-
      return 0 ;;
    *) exec 3>&-; return 1 ;;
  esac
}

# Why a read failed: which of the three links is missing (forward, service, listener).
diagnose() {
  echo "a11y-dump: no answer on 127.0.0.1:$port" >&2
  echo "--- adb forward ---" >&2
  adbx forward --list >&2
  echo "--- enabled accessibility services ---" >&2
  adbx shell settings get secure enabled_accessibility_services >&2
  echo "--- probe log (last 10) ---" >&2
  adbx logcat -d -s DshA11yProbe DshA11y 2>/dev/null | tail -10 >&2
  exit 1
}

# Broadcasts the token, then waits for the port to answer (the bind happens after delivery).
listen_with() {
  adbx shell am broadcast -a "$action" --es cmd listen \
    --es token "$1" --ei port "$port" >/dev/null
  local i
  for i in $(seq 1 40); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3>&-; return 0; fi
    sleep 0.05
  done
  return 1
}

if ((stop)); then
  adbx shell am broadcast -a "$action" --es cmd unlisten >/dev/null
  rm -f "$(token_file)"
  echo "a11y-dump: listener stopped" >&2
  exit 0
fi

if ((socket)); then
  adbx forward "tcp:$port" "tcp:$port" >/dev/null
  tf=$(token_file)
  token=${token_arg:-${A11Y_TOKEN:-}}
  [[ -z $token && -f $tf ]] && token=$(cat "$tf")
  request="dump $budget"
  if [[ -n $reuse_flag ]]; then request="$request $reuse_flag"; else request="$request -"; fi
  request="$request $tag"

  if [[ -z $token ]]; then
    token=$(new_token)
    listen_with "$token" || die "no listener on 127.0.0.1:$port (accessibility service on?)"
    (umask 077; printf '%s' "$token" >"$tf")
  fi

  if ! body=$(send "$token $request"); then
    # A token from an earlier service lifetime: ask for a new one, once.
    token=$(new_token)
    listen_with "$token" || die "no listener on 127.0.0.1:$port (accessibility service on?)"
    (umask 077; printf '%s' "$token" >"$tf")
    body=$(send "$token $request") || diagnose
  fi

  if [[ -n $out ]]; then
    printf '%s\n' "$body" >"$out"
    echo "a11y-dump: wrote $out" >&2
  else
    printf '%s\n' "$body"
  fi
  exit 0
fi

remote=/sdcard/Android/data/$pkg/files/a11y-probe/$name.json

adbx shell am broadcast \
  -a "$action" \
  --es cmd dump --es name "$name" --ei seq "$tag" --ei budget "$budget" >/dev/null

# `am broadcast` returns when the broadcast is delivered, not when the probe has written; the
# seq in the file is how we know this read, not the last one.
for _ in $(seq 1 60); do
  if adbx shell "grep -q '\"seq\":$tag' $remote" 2>/dev/null; then
    if [[ -n $out ]]; then
      adbx exec-out cat "$remote" >"$out" && echo "a11y-dump: wrote $out" >&2
      exit 0
    fi
    adbx exec-out cat "$remote"
    exit 0
  fi
  sleep 0.1
done

echo "a11y-dump: nothing after 6 s. Is the service on? (the pkg must be installed and 无障碍 enabled)" >&2
adbx logcat -d -s DshA11yProbe DshA11y | tail -20 >&2 || true
exit 1
