#!/usr/bin/env bash
# tests/test_liveness_zombie.sh - a process that has exited but not yet been
# reaped (a zombie, state Z) must read as DEAD to the shutdown tools.
#
# kill -0 succeeds on a zombie, so a bare `kill -0 "$pid"` test calls a
# process that is already gone a survivor: tools/headlong-killall printed
# "Force-killing N survivor(s)" for corpses, and uninstall.sh re-TERM/KILLed
# them. bin/thinkers already fixed this shape with _pid_alive; this pins the
# shutdown scripts to the same rule.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ - $2}"; }
check() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else bad "$l"; fi; }
check_not() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$l"; else ok "$l"; fi; }

# --- build a genuine zombie ------------------------------------------------
# Bash reaps its own background children, so `( exit 0 ) &` never stays
# defunct. fork() without waitpid() does: the child is dead and unreaped until
# the parent (which sleeps) goes away.
ZPARENT=""; ZCHILD=""; LIVE=""
cleanup() {
    [[ -n "$ZPARENT" ]] && kill "$ZPARENT" 2>/dev/null
    [[ -n "$LIVE" ]] && kill "$LIVE" 2>/dev/null
    return 0
}
trap cleanup EXIT

python3 -c 'import os,sys,time
pid = os.fork()
if pid == 0:
    os._exit(0)
time.sleep(30)' &
PYBG=$!
sleep 2
ZPARENT=$PYBG
ZCHILD=$(pgrep -P "$PYBG" 2>/dev/null | head -1 || true)
if [[ -z "$ZCHILD" ]]; then
    bad "could not create a zombie to test with"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi
sleep 1
ZSTATE=$(awk '{print $3}' "/proc/$ZCHILD/stat" 2>/dev/null || echo "?")
if [[ "$ZSTATE" == "Z" ]]; then
    ok "fixture really is a zombie (state Z)"
else
    bad "fixture is not a zombie" "state=$ZSTATE"
fi

# a live process, to prove the helper has not simply started saying "dead"
sleep 30 &
LIVE=$!

# --- the helper that each script now defines ------------------------------
load_helper() {  # load_helper <file> <fn> -> defines <fn> in this shell
    # Brace-depth scan, not a sed range: a one-line `fn() { ...; }` has no line
    # holding the closing brace alone, and a range would run to EOF and eval the
    # whole script (which is how an earlier version executed status.sh).
    local body
    body=$(awk -v fn="$2" '
        $0 ~ "^" fn "\\(\\) \\{" { on = 1 }
        on {
            print
            n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
            depth += n - m
            if (depth <= 0 && seen) exit
            if (depth > 0) seen = 1
        }' "$1")
    [[ -n "$body" ]] || return 1
    [[ "$body" == *"}" ]] || return 1
    eval "$body"
}
# Each script names its liveness helper in its own idiom: tools/headlong-killall
# uses _pid_alive, status.sh has an existing alive(). What matters is that the
# function the script actually calls treats a zombie as dead.
for pair in "tools/headlong-killall:_pid_alive" "status.sh:alive"; do
    f="${pair%%:*}"; fn="${pair##*:}"
    unset -f _pid_alive alive 2>/dev/null || true
    if load_helper "$REPO/$f" "$fn" && declare -f "$fn" >/dev/null 2>&1; then
        ok "$f defines $fn"
        check_not "$f: zombie reads as dead" "$fn" "$ZCHILD"
        check     "$f: live process reads alive" "$fn" "$LIVE"
    else
        bad "$f defines $fn"
    fi
    unset -f _pid_alive alive 2>/dev/null || true
done

# --- the bug that motivates the helper ------------------------------------
if kill -0 "$ZCHILD" 2>/dev/null; then
    ok "kill -0 still succeeds on a zombie (why the helper is needed)"
else
    bad "kill -0 unexpectedly fails on a zombie"
fi

# --- no bare kill -0 may decide liveness in the survivor paths ------------
check_not "headlong-killall survivor loop has no bare kill -0" \
    grep -q 'kill -0 "\$pid" 2>/dev/null && survivors+=' "$REPO/tools/headlong-killall"
check_not "uninstall.sh survivor scan has no bare kill -0" \
    grep -q 'do kill -0 "\$p" 2>/dev/null && alive=' "$REPO/uninstall.sh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
