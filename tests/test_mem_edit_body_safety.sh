#!/usr/bin/env bash
# tests/test_mem_edit_body_safety.sh — two ways `mem edit` used to damage a body.
# 1. The header scan matched every --- block in the file, so a body containing a
#    pasted block or a horizontal rule had its fields copied into updated: on
#    each edit, and the stamp list grew duplicates (the goal 4be5cf3c ended with
#    41 stamps from 21 real edits). Fixed with awk that stops after block one.
# 2. The new text replaces the whole body with no warning. On 2026-11-23 a 16 KB
#    goal body was replaced by one 380-byte line, exit 0, silent. Now a body that
#    shrinks past a third of 2 KB or more warns on stderr, and still writes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"
...

printf "first para\n\n---\n\npasted block\n" | mem add --type goal >/dev/null 2>&1
f=$(ls "$MEM_DIR"/*.md | head -1)
id=$(sed -n "s/^id: //p" "$f")
printf "second para\n\n---\n\nstill a rule\n" | mem edit "$id" >/dev/null 2>&1
printf "third para\n\n---\n\nstill a rule\n" | mem edit "$id" >/dev/null 2>&1
f=$(grep -l "^id: $id$" "$MEM_DIR"/*.md | head -1)
n=$(awk "BEGIN{n=0} /^---$/{n++; next} n==1" "$f" | grep -c "^  - ")
[[ "$n" -eq 2 ]] && ok "a ruler in the body does not duplicate stamps (got $n)" || bad "stamps after two edits" "got $n, want 2"
grep -q "^still a rule$" "$f" && ok "the ruler text is still in the body" || bad "body truncated"
python3 -c "print((chr(120)*80+chr(10))*40)" | mem edit "$id" >/dev/null 2>&1
out=$(printf "short body\n" | mem edit "$id" 2>&1 >/dev/null)
printf "%s" "$out" | grep -q replaces && ok "a heavy shrink warns" || bad "no shrink warning" "$out"
printf "%s" "$out" | grep -q "mem show first" && ok "warning says how to keep old text" || bad "warning wording" "$out"
f=$(grep -l "^id: $id$" "$MEM_DIR"/*.md | head -1)
grep -q "^short body$" "$f" && ok "the warned edit still wrote" || bad "shrink write" "$(tail -2 "$f")"
out=$(printf "short body\n" | mem edit "$id" 2>&1 >/dev/null)
if printf "%s" "$out" | grep -q replaces; then bad "spurious warning" "$out"; else ok "no warning when body already small"; fi
printf "\n%d passed, %d failed\n" "$pass" "$fail"
[[ $fail -eq 0 ]]
