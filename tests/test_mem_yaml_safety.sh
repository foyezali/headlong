#!/usr/bin/env bash
# test_mem_yaml_safety.sh — summaries must survive a real YAML parser.
#
# Before 2026-11-23 bin/mem wrote "summary: <free text>" raw, so 45 of ada's 85
# real memories were invalid YAML or parsed to null: "Profile: Foyez's job"
# reads as a mapping, "# a heading" as a comment, "2026-11-23" as a date. Every
# in-repo reader tolerated it because they slice the raw line. These checks hold
# both ends: the written header parses as YAML, and all four readers return the
# summary the author typed.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

bin="$REPO/bin/mem"
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"
eval "$(sed -n '/^frontmatter_field()/,/^}/p' "$bin")"

# add each hard summary and keep the id the tool prints
add_id() { "$bin" add --type fact "$1" 2>/dev/null | tail -1; }
sum_line() { grep -m1 '^summary:' "$MEM_DIR/$1.md" 2>/dev/null || sed -n 's/^summary://p' "$MEM_DIR/$1"; }

COLON="Profile: Foyez's job, employer and hours"
HASH="# a summary that starts with a heading marker"
DATE="2026-11-23"
PLAIN="plain words with no ambiguity at all"
LEAD=" leading space"
id_colon=$(add_id "$COLON"); f_colon=$(ls "$MEM_DIR" | grep "$id_colon")
id_hash=$(add_id "$HASH");   f_hash=$(ls "$MEM_DIR" | grep "$id_hash")
id_date=$(add_id "$DATE");   f_date=$(ls "$MEM_DIR" | grep "$id_date")
id_plain=$(add_id "$PLAIN"); f_plain=$(ls "$MEM_DIR" | grep "$id_plain")
id_lead=$(add_id "$LEAD");   f_lead=$(ls "$MEM_DIR" | grep "$id_lead")

ck "colon summary reads back whole"  "$(frontmatter_field "$MEM_DIR/$f_colon" summary)" "$COLON"
ck "hash summary reads back whole"   "$(frontmatter_field "$MEM_DIR/$f_hash" summary)"  "$HASH"
ck "date-like summary stays a string" "$(frontmatter_field "$MEM_DIR/$f_date" summary)" "$DATE"
ck "leading space reads back whole"  "$(frontmatter_field "$MEM_DIR/$f_lead" summary)"  "$LEAD"

# raw form: ambiguous ones are single-quoted, a plain one is left alone
case "$(grep -m1 '^summary:' "$MEM_DIR/$f_colon")" in
  "summary: '"*"'") ok "colon summary written as a quoted scalar" ;;
  *) bad "colon summary written as a quoted scalar" "got: $(grep -m1 '^summary:' "$MEM_DIR/$f_colon")" ;;
esac
case "$(grep -m1 '^summary:' "$MEM_DIR/$f_hash")" in
  "summary: '"*"'") ok "hash summary written as a quoted scalar" ;;
  *) bad "hash summary written as a quoted scalar" ;;
esac
ck "plain summary is not quoted (no churn)" \
   "$(grep -m1 '^summary:' "$MEM_DIR/$f_plain")" "summary: $PLAIN"
# the writer's own escape: an internal quote doubles inside the quoted scalar
ck "apostrophe doubled in the raw header" \
   "$(grep -m1 '^summary:' "$MEM_DIR/$f_colon")" \
   "summary: 'Profile: Foyez''s job, employer and hours'"

# edit must not double-quote an already quoted summary, and must keep it whole
"$bin" edit "$id_colon" --append "one more paragraph" >/dev/null 2>&1
ck "append keeps the summary whole" "$(frontmatter_field "$MEM_DIR/$f_colon" summary)" "$COLON"
ck "append does not double the quoting" \
   "$(grep -m1 '^summary:' "$MEM_DIR/$f_colon")" \
   "summary: 'Profile: Foyez''s job, employer and hours'"

# common.sh _fm is the thinkers' reader and must agree
eval "$(sed -n '/^_fm_unquote()/,/^}/p' "$REPO/thinkers/_lib/common.sh")"
eval "$(sed -n '/^_fm()/,/^}/p' "$REPO/thinkers/_lib/common.sh")"
ck "thinkers _fm agrees on the colon summary" "$(_fm "$MEM_DIR/$f_colon" summary)" "$COLON"
ck "thinkers _fm agrees on the hash summary"  "$(_fm "$MEM_DIR/$f_hash" summary)"  "$HASH"

# mem list is a people-facing surface: no raw quotes or escapes in it
# Capture then match: grep -q closes the pipe early, mem list takes SIGPIPE and
# pipefail turns a successful match into a failed pipeline.
list_out=$("$bin" list 2>/dev/null) || true
case "$list_out" in
  *"$COLON"*) ok "mem list shows the summary unquoted" ;;
  *) bad "mem list shows the summary unquoted" ;;
esac

# A real YAML parser is the only proof the file is valid YAML at all. Skipped
# rather than failed when the interpreter is absent, so the suite stays hermetic.
PYBIN=""
for c in python3 "$REPO/web/.venv/bin/python"; do
  if "$c" -c 'import yaml' 2>/dev/null; then PYBIN="$c"; break; fi
done
if [ -n "$PYBIN" ]; then
  yml=$("$PYBIN" - "$MEM_DIR" <<'PY'
import glob, sys, yaml
bad = 0
for f in glob.glob(sys.argv[1] + "/*.md"):
    lines = open(f, encoding="utf-8").read().split("\n")
    end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    d = yaml.safe_load("\n".join(lines[1:end]))
    if not isinstance(d.get("summary"), str):
        bad += 1
print(bad)
PY
)
  ck "pyyaml: every written header parses with a str summary" "$yml" "0"
else
  echo "SKIP no python with pyyaml; YAML validity unchecked"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
