#!/usr/bin/env bash
# test_mem_frontmatter.sh — tests for bin/mem frontmatter_field()
#
# frontmatter_field() extracts a YAML frontmatter value from a memory file.
# It should strip surrounding quotes so summary: "foo" returns foo, not "foo".
# This test documents that expected behavior and catches regressions if the
# quote-stripping sed is removed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# Extract frontmatter_field() from bin/mem without running main.
# bin/mem calls main "$@" at the end, so sourcing it would exit.
eval "$(sed -n '/^frontmatter_field()/,/^}/p' "$REPO/bin/mem")"

# --- fixtures: quoted and unquoted frontmatter ---
mkdir -p "$WORK/mem"
cat > "$WORK/mem/quoted.md" <<'EOF'
---
summary: "A quoted summary"
importance: "high"
type: "lesson"
tags: ["t1", "t2"]
---

Body.
EOF

cat > "$WORK/mem/ruler.md" <<'EOF'
---
id: aaaa1111
summary: the real summary
type: memory
created: 2026-01-01 00:00:00
---

A note whose body contains a ruler:

---

until: 1999-01-01
summary: INJECTED SUMMARY
type: goal
EOF

cat > "$WORK/mem/colon.md" <<'EOF'
---
id: bbbb2222
summary: note: the charger is the cause, not the audio path
type: memory
created: 2026-01-02 00:00:00
---

Body.
EOF

cat > "$WORK/mem/apostrophe.md" <<'EOF'
---
id: cccc3333
summary: Foyez's charger is the cause
type: memory
created: 2026-01-03 00:00:00
---

Body.
EOF

cat > "$WORK/mem/unquoted.md" <<'EOF'
---
summary: An unquoted summary
importance: medium
type: lesson
tags: [t1, t2]
---

Body.
EOF

# --- assertions: quoted values should be stripped ---
val=$(frontmatter_field "$WORK/mem/quoted.md" "summary")
[ "$val" = "A quoted summary" ] \
  && ok "quoted summary stripped" \
  || bad "quoted summary stripped" "got: [$val]"

val=$(frontmatter_field "$WORK/mem/quoted.md" "importance")
[ "$val" = "high" ] \
  && ok "quoted importance stripped" \
  || bad "quoted importance stripped" "got: [$val]"

val=$(frontmatter_field "$WORK/mem/quoted.md" "type")
[ "$val" = "lesson" ] \
  && ok "quoted type stripped" \
  || bad "quoted type stripped" "got: [$val]"

# --- assertions: unquoted values pass through unchanged ---
val=$(frontmatter_field "$WORK/mem/unquoted.md" "summary")
[ "$val" = "An unquoted summary" ] \
  && ok "unquoted summary unchanged" \
  || bad "unquoted summary unchanged" "got: [$val]"

val=$(frontmatter_field "$WORK/mem/unquoted.md" "importance")
[ "$val" = "medium" ] \
  && ok "unquoted importance unchanged" \
  || bad "unquoted importance unchanged" "got: [$val]"

# --- missing field returns empty ---
val=$(frontmatter_field "$WORK/mem/quoted.md" "nonexistent")
[ -z "$val" ] \
  && ok "missing field returns empty" \
  || bad "missing field returns empty" "got: [$val]"


# --- body rulers must not be read as header fields (2026-11-23) ---
# Until now the reader took a sed range from the first --- to ANY later ---,
# so a memory whose body held a ruler had body lines read as header values:
# a body "until: 1999-01-01" became the memory's real until and expired it,
# and a body "summary:" line replaced the true summary.
val=$(frontmatter_field "$WORK/mem/ruler.md" "until")
[ -z "$val" ] \
  && ok "body ruler: until stays empty" \
  || bad "body ruler: until stays empty" "got: [$val]"

val=$(frontmatter_field "$WORK/mem/ruler.md" "summary")
[ "$val" = "the real summary" ] \
  && ok "body ruler: summary not overridden" \
  || bad "body ruler: summary not overridden" "got: [$val]"

val=$(frontmatter_field "$WORK/mem/ruler.md" "type")
[ "$val" = "memory" ] \
  && ok "body ruler: type not overridden" \
  || bad "body ruler: type not overridden" "got: [$val]"

val=$(frontmatter_field "$WORK/mem/ruler.md" "id")
[ "$val" = "aaaa1111" ] \
  && ok "body ruler: id read from real header" \
  || bad "body ruler: id read from real header" "got: [$val]"

# --- values containing ": " come back whole ---
# 84 of 84 real memories store an unquoted summary with a colon in it. The
# reader must hand back the whole value, not the part before the colon.
val=$(frontmatter_field "$WORK/mem/colon.md" "summary")
[ "$val" = "note: the charger is the cause, not the audio path" ] \
  && ok "colon in value kept whole" \
  || bad "colon in value kept whole" "got: [$val]"

# --- an apostrophe is not a quote to strip ---
val=$(frontmatter_field "$WORK/mem/apostrophe.md" "summary")
[ "$val" = "Foyez's charger is the cause" ] \
  && ok "apostrophe preserved" \
  || bad "apostrophe preserved" "got: [$val]"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
