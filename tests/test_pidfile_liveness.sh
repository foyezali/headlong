#!/usr/bin/env bash
# tests/test_pidfile_liveness.sh - a pid file must not be believed on its own.
#
# Two ways a stale pid file lies about a running thing, both live on this box:
#
#  1. kill -0 succeeds for a process that exited but was never reaped (a
#     zombie). This container's PID 1 is `sleep infinity`, which never reaps,
#     so a thinker or bridge that dies stays a zombie indefinitely and its pid
#     keeps answering kill -0. tools/persona, tools/headlong-init and
#     tools/headlong-bridge-restart all decided liveness with bare kill -0, so
#     `persona status` could report a dead dispatcher as running for good.
#
#  2. The kernel reuses pid numbers once the counter wraps. It has already
#     wrapped here (live pids in the 4.19M range appear alongside fresh ones in
#     the 1.7M range), so a stale pid file can name a completely unrelated
#     younger process, which kill -0 happily calls alive. Comparing the
#     process start time against the pid file's mtime catches it: the real
#     process cannot have started after the file that recorded it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ - $2}"; }
check() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else bad "$l"; fi; }
check_not() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$l"; else ok "$l"; fi; }

WORK=$(mktemp -d)
ZPARENT=""; LIVE=""; OTHER=""
cleanup() {
    [[ -n "$ZPARENT" ]] && kill "$ZPARENT" 2>/dev/null
    [[ -n "$LIVE"    ]] && kill "$LIVE"    2>/dev/null
    [[ -n "$OTHER"   ]] && kill "$OTHER"   2>/dev/null
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

# --- fixtures --------------------------------------------------------------
# A real zombie: fork() and never waitpid(). Bash reaps its own background
# children, so `( exit 0 ) &` never stays defunct.
python3 -c 'import os,time
pid = os.fork()
if pid == 0:
    os._exit(0)
time.sleep(60)' &
ZPARENT=$!
sleep 2
ZCHILD=$(pgrep -P "$ZPARENT" 2>/dev/null | head -1 || true)
if [[ -z "$ZCHILD" ]]; then
    bad "could not create a zombie fixture"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
sleep 1
[[ "$(awk '{print $3}' "/proc/$ZCHILD/stat" 2>/dev/null)" == "Z" ]] \
    && ok "fixture: a real zombie exists" \
    || bad "fixture: zombie is not in state Z"

sleep 60 & LIVE=$!
sleep 0.2

# --- the helper, from each tool that was fixed -----------------------------
load_helper() {  # load_helper <file> <fn> -> defines <fn> in this shell
    # Brace-depth scan, not a sed range: a one-line `fn() { ...; }` has no
    # line holding the closing brace alone, and a range would run to EOF and
    # eval the rest of the file.
    local file="$1" fn="$2" body
    body=$(awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\)" { grab=1; depth=0 }
        grab {
            n = gsub(/\{/, "{"); depth += n
            n = gsub(/\}/, "}"); depth -= n
            print
            if (started && depth <= 0) exit
            started = 1
        }' "$file")
    [[ -n "$body" ]] || return 1
    eval "$body"
}

for f in tools/persona tools/headlong-init tools/headlong-bridge-restart; do
    unset -f _pid_alive _pid_boot 2>/dev/null || true
    if load_helper "$REPO/$f" _pid_alive && declare -f _pid_alive >/dev/null 2>&1; then
        ok "$f defines _pid_alive"
        check_not "$f: zombie reads dead" _pid_alive "$ZCHILD"
        check     "$f: live process reads alive" _pid_alive "$LIVE"
        check_not "$f: empty pid reads dead" _pid_alive ""
        check_not "$f: non-numeric pid reads dead" _pid_alive "abc"
        check_not "$f: missing pid reads dead" _pid_alive 999999

        # --- recycled pid: a process younger than the file naming it -----
        printf '%s\n' "$LIVE" > "$WORK/recycled.pid"
        touch -d '2 hours ago' "$WORK/recycled.pid"
        check_not "$f: pid younger than its pid file reads dead" \
            _pid_alive "$LIVE" "$WORK/recycled.pid"

        # --- honest pid file: written after the process started ----------
        printf '%s\n' "$LIVE" > "$WORK/honest.pid"
        check "$f: pid older than its pid file reads alive" \
            _pid_alive "$LIVE" "$WORK/honest.pid"

        # --- the same instant must not read as recycling -----------------
        printf '%s\n' "$LIVE" > "$WORK/same.pid"
        check "$f: pid and pid file written together reads alive" \
            _pid_alive "$LIVE" "$WORK/same.pid"
    else
        bad "$f defines _pid_alive"
    fi
    unset -f _pid_alive _pid_boot 2>/dev/null || true
done

# --- no bare kill -0 may decide liveness in these tools --------------------
check_not "persona _dispatcher_pid does not trust kill -0 alone" \
    grep -q 'kill -0 "\$pid" 2>/dev/null && printf' "$REPO/tools/persona"
check_not "persona dash start does not trust kill -0 alone" \
    grep -q 'if \[\[ -z "\$pid" \]\] || ! kill -0' "$REPO/tools/persona"
check_not "persona status does not trust kill -0 alone" \
    grep -q 'if \[\[ -n "\$wpid" \]\] && kill -0' "$REPO/tools/persona"
check_not "bridge-restart alive() does not use bare kill -0" \
    grep -q 'alive() { \[\[ -n "${1:-}" \]\] && kill -0' "$REPO/tools/headlong-bridge-restart"
check_not "headlong-init does not trust kill -0 alone for the dispatcher" \
    grep -q '\[\[ -n "\$DISPATCHER_PID" \]\] && kill -0' "$REPO/tools/headlong-init"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
