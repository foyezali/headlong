#!/usr/bin/env bash
# tests/test_mem_edit_append.sh — `mem edit --append` adds to a memory instead of
# replacing it. Adding a section to a long goal is the common case, and before
# this flag the default silently replaced the whole body (a 16 KB goal body was
# lost to a 380-byte note on 2026-11-23). --append must grow the body, keep the
# summary, keep the filename, and keep a todo's until: date.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"

# A long body, the shape that got destroyed.
python3 -c "print('\n'.join('line %03d %s' % (i,'y'*60) for i in range(40)))" > "$WORK/long.txt"
body_before=$(wc -c < "$WORK/long.txt")
f=$(mem add --type goal < "$WORK/long.txt" 2>/dev/null >/dev/null; ls "$MEM_DIR"/*.md | head -1)
id=$(sed -n 's/^id: //p' "$f")
name_before=$(basename "$f")
bytes_before=$(wc -c < "$f")

# Append a short section.
printf '## appended section\nthe new text\n' | mem edit "$id" --append >/dev/null 2>&1
f=$(grep -l "^id: $id$" "$MEM_DIR"/*.md | head -1)
bytes_after=$(wc -c < "$f")
[[ "$(basename "$f")" == "$name_before" ]] && ok "append keeps the filename" || bad "filename changed" "$(basename "$f")"
[[ "$bytes_after" -gt "$bytes_before" ]] && ok "append grew the file ($bytes_before -> $bytes_after)" || bad "did not grow" "$bytes_after"
grep -q "^line 039 " "$f" && ok "the old body is still there" || bad "old body lost"
grep -q "^## appended section$" "$f" && ok "the new text is in the body" || bad "new text missing"
grep -q "^the new text$" "$f" && ok "second line of the append landed" || bad "append truncated to one line"
# Blank-line separator between old and new: the last old line, then exactly one
# empty line, then the new header.
python3 - "$f" <<'PYSEP'
import sys
s=open(sys.argv[1]).read()
body=s.split('---',2)[2]
j=body.index('## appended section')
head=body[:j]
assert head.endswith('\n\n'), repr(head[-40:])
assert not head.endswith('\n\n\n'), 'two or more blank lines before the append'
PYSEP
if [[ $? -eq 0 ]]; then ok "exactly one blank line separates old and new"; else bad "separator"; fi

# Summary is preserved, not re-derived from the appended text.
summary_line=$(grep '^summary:' "$f")
case "$summary_line" in
  *"## appended"*) bad "summary re-derived from append text" "$summary_line" ;;
  *"line 000"*)    ok  "summary still describes the memory" ;;
  *)               bad "summary unexpected" "$summary_line" ;;
esac

# Two appends in a row accumulate.
printf 'third\n' | mem edit "$id" --append >/dev/null 2>&1
grep -q "^third$" "$f" && grep -q "^## appended section$" "$f" && ok "two appends accumulate" || bad "second append"

# No shrink warning in append mode, even though the add was tiny vs the body.
out=$(printf 'x\n' | mem edit "$id" --append 2>&1 >/dev/null)
if printf '%s' "$out" | grep -q replaces; then bad "append warned about a shrink" "$out"; else ok "append never warns about replacing"; fi

# until: survives an append (a todo added to during the day still expires).
printf 'a todo\n' | mem add --type todo --until 2030-01-01 >/dev/null 2>&1
tf=$(grep -l '^until: 2030-01-01$' "$MEM_DIR"/*.md | head -1)
tid=$(sed -n 's/^id: //p' "$tf")
printf 'more work tonight\n' | mem edit "$tid" --append >/dev/null 2>&1
grep -q '^until: 2030-01-01$' "$tf" && ok "until: survives append" || bad "until dropped"
grep -q '^more work tonight$' "$tf" && ok "todo append wrote" || bad "todo append"

# Plain edit (no flag) still replaces. A replace renames the file (summary and
# slug both change), so re-find it by id rather than trusting the old path.
printf 'tiny now\n' | mem edit "$id" >/dev/null 2>&1
f2=$(grep -l "^id: $id$" "$MEM_DIR"/*.md | head -1)
grep -q '^tiny now$' "$f2" && ok "plain edit still replaces" || bad "plain edit"
# And the shrink warning names --append as the non-destructive option. Needs a
# still-large body: after the replace above this one is tiny and cannot warn.
python3 -c "print('\n'.join('z%d %s' % (i,'q'*60) for i in range(40)))" > "$WORK/big.txt"
bf=$(mem add --type fact < "$WORK/big.txt" 2>/dev/null >/dev/null; ls -t "$MEM_DIR"/*.md | head -1)
bid=$(sed -n 's/^id: //p' "$bf")
out=$(printf 't\n' | mem edit "$bid" 2>&1 >/dev/null)
printf '%s' "$out" | grep -q -- "--append" && ok "shrink warning names --append" || bad "warning does not mention --append" "$out"

# Unknown flag still refuses (and names --append as supported).
out=$(mem edit "$id" --apply bogus 2>&1 >/dev/null)
printf '%s' "$out" | grep -q "unknown option" && ok "unknown option refused" || bad "unknown option accepted" "$out"

printf "\n%d passed, %d failed\n" "$pass" "$fail"
[[ $fail -eq 0 ]]
