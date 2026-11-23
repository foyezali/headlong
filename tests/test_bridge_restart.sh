#!/usr/bin/env bash
# tests/test_bridge_restart.sh — tools/headlong-bridge-restart picks the right
# state home, builds a child environment that can find uv, and refuses a
# checkout path that would break its pgrep patterns. Starts nothing real: the
# fake checkout's launcher prints its environment and exits.
#
# Usage: tests/test_bridge_restart.sh
#
# Why the home matters: an agent shell exports SHELLM_HOME at its identity's
# .shellm, so a tool that trusted SHELLM_HOME would read a different run/ and
# logs/ from the ones the bridge was started with, and report a running bridge
# as absent.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
TOOL="$REPO/tools/headlong-bridge-restart"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# A fake checkout: tools/ plus the two project dirs, and a launcher that
# prints the PATH it was handed instead of starting a bridge.
mkapp() {
    local root="$1"
    mkdir -p "$root/tools" "$root/telegram" "$root/slack"
    cp "$TOOL" "$root/tools/"
    cat > "$root/tools/headlong-telegram-bridge" <<'LAUNCH'
#!/usr/bin/env bash
printf 'LAUNCHER-RAN path=%s\n' "$PATH"
exit 0
LAUNCH
    chmod +x "$root/tools/"*
}

# A fake state home: app_dir naming the checkout, next to run/ and logs/.
mkhome() {
    local home="$1" root="$2"
    mkdir -p "$home/run" "$home/logs"
    readlink -f "$root" > "$home/app_dir"
}

APP=$(readlink -f "$WORK/app")
mkapp "$APP"

# 1. SHELLM_HOME must not redirect the tool. $HOME/.headlong is a valid home
#    here, and SHELLM_HOME points at a decoy that is not.
HOME_A="$WORK/home_a"
mkhome "$HOME_A" "$APP"
printf '%s\n' "$$" > "$HOME_A/run/telegram-bridge.pid"
mkdir -p "$WORK/h1"
ln -s "$HOME_A" "$WORK/h1/.headlong"
out=$(SHELLM_HOME="$WORK/decoy" HEADLONG_HOME="" HOME="$WORK/h1" \
      "$APP/tools/headlong-bridge-restart" telegram status 2>&1)
# The home is reached through a symlink, so compare the resolved path.
pidpath=$(printf '%s\n' "$out" | sed -n 's/.*stale pidfile: \([^ ]*\) holds .*/\1/p')
if [[ -n "$pidpath" && "$(readlink -f "$pidpath")" == "$(readlink -f "$HOME_A/run/telegram-bridge.pid")" ]]; then
    ok "status reads the checkout's state home, not SHELLM_HOME"
else
    bad "status reads the checkout's state home, not SHELLM_HOME" "$out"
fi

# 2. HEADLONG_HOME wins over $HOME/.headlong.
HOME_B="$WORK/home_b"
mkhome "$HOME_B" "$APP"
printf '%s\n' "$$" > "$HOME_B/run/telegram-bridge.pid"
out=$(SHELLM_HOME="$WORK/decoy" HEADLONG_HOME="$HOME_B" HOME="$WORK/h1" \
      "$APP/tools/headlong-bridge-restart" telegram status 2>&1)
case "$out" in
    *"$HOME_B/run/telegram-bridge.pid"*) ok "HEADLONG_HOME chooses the state home" ;;
    *) bad "HEADLONG_HOME chooses the state home" "$out" ;;
esac

# 3. Nothing running: exit 1 and a plain message.
HOME_C="$WORK/home_c"
mkhome "$HOME_C" "$APP"
out=$(HEADLONG_HOME="$HOME_C" HOME="$WORK/h1" \
      "$APP/tools/headlong-bridge-restart" telegram status 2>&1)
rc=$?
case "$out:$rc" in
    *"not running"*:1) ok "status with no bridge exits 1 and says not running" ;;
    *) bad "status with no bridge exits 1 and says not running" "rc=$rc out=$out" ;;
esac

# 4. The child gets a PATH that can find uv (~/.local/bin, or wherever this
#    shell found it). uv lives in ~/.local/bin on a stock install, and an
#    empty PATH there fails before the bridge starts.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN" "$WORK/h4"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/uv"
chmod +x "$FAKEBIN/uv"
out=$(PATH="$FAKEBIN:/usr/bin:/bin" HEADLONG_HOME="$HOME_C" HOME="$WORK/h4" \
      BRIDGE_START_TICKS=2 BRIDGE_LOG_TICKS=1 \
      "$APP/tools/headlong-bridge-restart" telegram start 2>&1)
logged=$(cat "$HOME_C/logs/telegram-bridge.log" 2>/dev/null || true)
if [[ "$logged" != *"LAUNCHER-RAN"* ]]; then
    bad "start runs the launcher under a clean environment" "out=$out logged=$logged"
else
    ok "start runs the launcher under a clean environment"
    case "$logged" in
        *"$WORK/h4/.local/bin"*) ok "child PATH includes ~/.local/bin for uv" ;;
        *) bad "child PATH includes ~/.local/bin for uv" "$logged" ;;
    esac
    case "$logged" in
        *"$FAKEBIN"*) ok "child PATH includes the directory this shell found uv in" ;;
        *) bad "child PATH includes the directory this shell found uv in" "$logged" ;;
    esac
    # The launcher exits at once, so nothing is running and start says so.
    case "$out" in
        *"did not come up"*) ok "start reports a launcher that exits immediately" ;;
        *) bad "start reports a launcher that exits immediately" "$out" ;;
    esac
fi

# 5. A checkout path with regex metacharacters is refused up front, because
#    APP goes into pgrep -f patterns unescaped.
ODD="$WORK/ap+p"
mkapp "$ODD"
out=$(HEADLONG_HOME="$HOME_C" HOME="$WORK/h1" "$ODD/tools/headlong-bridge-restart" telegram status 2>&1)
case "$out" in
    *"regex metacharacters"*) ok "refuses a checkout path with regex metacharacters" ;;
    *) bad "refuses a checkout path with regex metacharacters" "$out" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
