#!/usr/bin/env bash
# mem edit must not destroy frontmatter fields it does not own.
# Before 2026-11-23 the header was rebuilt from a fixed key list, so every
# unknown key was deleted on edit and any indented list anywhere in the header
# was folded into updated: as fake timestamps.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd "$HERE/.." && pwd)
MEM_BIN="${MEM_BIN:-$APP/bin/mem}"

PASS=0; FAIL=0
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); printf 'ok   %s\n' "$d"; else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$d"; fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"
mkdir -p "$MEM_DIR"
unset IDENTITY_DIR HEADLONG_HOME 2>/dev/null || true

mem() { "$MEM_BIN" "$@"; }

hdr() { awk 'BEGIN{n=0} /^---$/{n++; next} n==1' "$1"; }
body() { awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$1"; }

inject() {
  local f="$1"; shift
  awk -v ins="$(printf '%s\n' "$@")" 'BEGIN{n=0} /^---$/{n++; if(n==2){print ins}} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

mk() {
  local out
  out=$(mem add --type memory "seed body about $1" 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

# --- scalar and block-list fields survive an --append ---------------------
f=$(mk alpha)
inject "$MEM_DIR/$f.md" 'level: 1' 'parent: abcd1234' 'related:' '  - deadbeef' '  - cafebabe' 'source_range: 470-479'
mem edit --append "$f" "appended line" >/dev/null 2>&1
check "append keeps level"        grep -qx 'level: 1' "$MEM_DIR/$f.md"
check "append keeps parent"       grep -qx 'parent: abcd1234' "$MEM_DIR/$f.md"
check "append keeps related key"  grep -qx 'related:' "$MEM_DIR/$f.md"
check "append keeps related item1" grep -qx '  - deadbeef' "$MEM_DIR/$f.md"
check "append keeps related item2" grep -qx '  - cafebabe' "$MEM_DIR/$f.md"
check "append keeps source_range" grep -qx 'source_range: 470-479' "$MEM_DIR/$f.md"
check "append keeps body"         bash -c 'grep -q "appended line" "$1" && grep -q "seed body about alpha" "$1"' _ "$MEM_DIR/$f.md"
_id=$(hdr "$MEM_DIR/$f.md" | sed -n 's/^id:[[:space:]]*//p')
check "append keeps id"           test -n "$_id"
check "id unchanged by append"    grep -qx "id: $_id" "$MEM_DIR/$f.md"

# list items must not become edit timestamps
check "related items not in updated" bash -c '! hdr=$(awk "BEGIN{n=0} /^---\$/{n++; next} n==1" "$1"); printf "%s" "$hdr" | grep -q "deadbeef"' _ "$MEM_DIR/$f.md"
# A memory with no prior updated: gets a single scalar stamp; the list form
# only appears once there is more than one.
check "updated is one scalar" bash -c 'awk "BEGIN{n=0} /^---\$/{n++; next} n==1" "$1" | grep -qE "^updated: [0-9]{4}-[0-9]{2}-[0-9]{2} "' _ "$MEM_DIR/$f.md"

# --- survives a replace edit too ------------------------------------------
f2=$(mk beta)
inject "$MEM_DIR/$f2.md" 'level: 2' 'children:' '  - aaaa1111'
_id2=$(hdr "$MEM_DIR/$f2.md" | sed -n 's/^id:[[:space:]]*//p')
mem edit "$f2" "brand new body" >/dev/null 2>&1
# A replace edit re-slugs the filename, so resolve by id, not by old name.
f2b=$(ls "$MEM_DIR"/*_"$_id2"_*.md 2>/dev/null | head -1)
check "replace keeps level"     grep -qx 'level: 2' "$f2b"
check "replace keeps children"  grep -qx '  - aaaa1111' "$f2b"
check "replace swaps body"      bash -c '! grep -q "seed body about beta" "$1" && grep -q "brand new body" "$1"' _ "$f2b"

# --- existing updated list is preserved and one stamp added ---------------
f3=$(mk gamma)
inject "$MEM_DIR/$f3.md" 'updated:' '  - 2020-01-01 00:00:00'
mem edit --append "$f3" "more" >/dev/null 2>&1
check "old stamp kept"  grep -qx '  - 2020-01-01 00:00:00' "$MEM_DIR/$f3.md"
n_upd=$(hdr "$MEM_DIR/$f3.md" | awk '/^updated:/{f=1;next} f&&/^[[:space:]]*-/{c++} END{print c+0}')
check "updated has two stamps" test "$n_upd" = "2"

# --- single updated value converts to a list ------------------------------
f4=$(mk delta)
inject "$MEM_DIR/$f4.md" 'updated: 2019-05-05 05:05:05'
mem edit --append "$f4" "more" >/dev/null 2>&1
check "single stamp becomes list" grep -qx '  - 2019-05-05 05:05:05' "$MEM_DIR/$f4.md"
n_upd=$(hdr "$MEM_DIR/$f4.md" | awk '/^updated:/{f=1;next} f&&/^[[:space:]]*-/{c++} END{print c+0}')
check "single stamp count" test "$n_upd" = "2"

# --- header stays well formed ---------------------------------------------
f5=$(mk epsilon)
inject "$MEM_DIR/$f5.md" 'level: 1' 'related:' '  - x' 
mem edit --append "$f5" "more" >/dev/null 2>&1
check "two rulers only" test "$(grep -c '^---$' "$MEM_DIR/$f5.md")" = "2"
check "no blank line in header" test -z "$(hdr "$MEM_DIR/$f5.md" | grep -x '' || true)"
check "summary kept on append" grep -q '^summary: seed body about epsilon' "$MEM_DIR/$f5.md"
check "type kept" grep -qx 'type: memory' "$MEM_DIR/$f5.md"

# --- until/schedule/tz still ride through --------------------------------
f6=$(mem add --type todo --until 2099-01-01 "a dated todo" 2>/dev/null)
mem edit --append "$f6" "progress" >/dev/null 2>&1
check "until kept" grep -qx 'until: 2099-01-01' "$MEM_DIR/$f6.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
