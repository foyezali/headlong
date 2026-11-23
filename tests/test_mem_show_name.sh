#!/usr/bin/env bash
# test_mem_show_name.sh — `mem show <name>` resolves a slug; ambiguity is loud.
# Until 2026-11-23 find_memory() understood only a hex id or an exact filename,
# so the "mem show <id>" hint printed in memories and in skills/shellm/SKILL.md
# failed for every name. These checks pin the name tiers, the normalization of a
# typed phrase into slug form, hex-id precedence, and the refusal on ambiguity.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf "ok   %s\n" "$1"; }
bad() { fail=$((fail+1)); printf "FAIL %s%s\n" "$1" "${2:+ — $2}"; }
# Load only the resolver functions; bin/mem calls main "$@" at the end,
# so it cannot be sourced whole.
for _fn in die slugify frontmatter_field find_memory_by_slug find_memory; do
    eval "$(sed -n "/^${_fn}()/,/^}/p" "$REPO/bin/mem")"
done
MEM_DIR="$WORK/memories"
mkdir -p "$MEM_DIR"
mk() { printf -- "---\nid: %s\n---\n\nbody\n" "$2" > "$MEM_DIR/${1}_${2}_${3}.md"; }
mk 2026-01-01-00-00-00 aaaa1111 bin-chat-read-end-to-end
mk 2026-01-02-00-00-00 bbbb2222 bin-context-read-end-to-end
mk 2026-01-03-00-00-00 cccc3333 llm-health-marker-first-look
mk 2026-01-04-00-00-00 dddd4444 llm-health-marker-reader-fix
mk 2026-01-05-00-00-00 eeee5555 sole-slug-here
mk 2026-01-06-00-00-00 ffff6666 legacy-format-kept
need() {
    local want="$1" label="$2" arg="$3" rc=0
    ( find_memory "$arg" >/dev/null 2>&1 ) || rc=$?
    if [ "$rc" -eq "$want" ]; then ok "$label"; else bad "$label" "exit $rc wanted $want"; fi
}
need 0 "hex id prefix" aaaa1111
need 0 "exact filename" 2026-01-06-00-00-00_ffff6666_legacy-format-kept
need 0 "exact slug" sole-slug-here
need 0 "unique slug prefix" bin-chat
need 0 "typed phrase normalized to slug" "sole slug here"
need 0 "uppercase phrase normalized" "Sole Slug Here"
need 1 "ambiguous prefix refused" "bin-"
need 1 "ambiguous substring refused" "read-end"
need 1 "unknown name" "zzzznope"
out=$(find_memory "sole slug here" 2>/dev/null)
case "$out" in *eeee5555*) ok "resolved path is the sole match";; *) bad "resolved path is the sole match" "$out";; esac
err=$(find_memory "bin-" 2>&1 >/dev/null)
case "$err" in *"matches 2 memories"*) ok "ambiguity names the count";; *) bad "ambiguity names the count" "$err";; esac
case "$err" in *aaaa1111*) ok "ambiguity lists candidates";; *) bad "ambiguity lists candidates" "$err";; esac
echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
