#!/usr/bin/env bash
# tests/test_docker_init_flag.sh — every documented `docker run` for the
# headlong container passes --init.
#
# Why: the container's entrypoint is a `bash -c` that finishes with `exec bash`,
# so process 1 is a plain bash (or, on the reference box, `sleep infinity`) and
# nothing reaps grandchildren. Every finished child whose parent is gone stays a
# zombie pinned to pid 1 for the life of the container. Measured on 2026-11-23:
# 16,403 zombies against 35 live processes, growing about 1,800 per hour. The
# docker --init flag puts a tiny reaper in as pid 1 and that stops entirely.
# A missing --init fails silently and slowly, so it needs a test rather than a
# comment.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# Every tracked file that tells someone how to start the container.
check_file() {
    local f="$1"
    local line
    # collect the docker run invocation lines naming the headlong container
    while IFS= read -r line; do
        case "$line" in
            *--init*) ok "$f: docker run passes --init" ;;
            *)        bad "$f: docker run is missing --init: $line" ;;
        esac
    done < <(grep -F 'docker run' "$f" | grep -F 'name headlong')
}

for f in README.md docs/install.md install.sh; do
    if grep -F 'docker run' "$REPO/$f" 2>/dev/null | grep -qF 'name headlong'; then
        check_file "$REPO/$f"
    else
        bad "$f: no documented docker run for the headlong container was found"
    fi
done

# --init only takes effect when a container is created, so an agent installed
# by an older command keeps its non-reaping pid 1 until it is recreated. The
# docs must say so, or the fix looks complete while existing installs rot.
if grep -qi 'recreate' "$REPO/docs/install.md"; then
    ok "docs/install.md says an existing container must be recreated"
else
    bad "docs/install.md does not say an existing container must be recreated"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
