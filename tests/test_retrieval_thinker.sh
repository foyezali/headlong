#!/usr/bin/env bash
# test_retrieval_thinker.sh — thinkers/retrieval: passive memory recall
#
# Usage: tests/test_retrieval_thinker.sh
#
# Drives thinkers/retrieval/step directly against a throwaway identity with
# a few memories: a step that shares words with a memory gets an
# observation appended to the trajectory naming that memory; unrelated
# steps, its own observations, and a memory already surfaced recently do
# not. Also checks the index rebuilds when a memory is added, and that the
# bundled thinker ships with its `disabled` marker. No LLM calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID RETRIEVAL_INDEX RETRIEVAL_SEMANTIC

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PATH="$REPO/bin:$PATH"
STEP="$REPO/thinkers/retrieval/step"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-00000000beef"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID"
printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
: > "$TRAJ"

mem_file() {  # name id summary body
    printf -- '---\nid: %s\nsummary: %s\ntype: fact\n---\n%s\n' "$2" "$3" "$4" > "$ID/memories/$1.md"
}
mem_file 20260801_aaaa_colima "aaaa1111" "docker on this mac is colima" \
    "Bind mounts silently fail for paths colima does not mount. Only home and tmp are mounted."
mem_file 20260802_bbbb_pager "bbbb2222" "short git output vanishes in the pager" \
    "The LESS variable lacks -X so paged git output disappears when less exits."

run_step() {  # step json on stdin
    env IDENTITY_DIR="$ID" IDENTITY_NAME=testid MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" SKILLS_DIR="$ID/skills" \
        SKILLS_KERNEL_DIR="$ID/kernel" HOME="$WORK/home" "$STEP"
}
step() { printf '{"type":"%s","step_id":"s-%s","content":"%s"%s}' "$1" "$2" "$3" "${4:-}"; }
obs_count() { grep -c '"source":"retrieval"' "$TRAJ" 2>/dev/null || true; }
last_obs() { grep '"source":"retrieval"' "$TRAJ" | tail -1; }

# --- ships disabled --------------------------------------------------------
check "bundled thinker has disabled marker"  test -f "$REPO/thinkers/retrieval/disabled"
check "step is executable"                  test -x "$STEP"

# --- no resonance: nothing appended ----------------------------------------
step thought 1 "Thinking about the weather and lunch plans today." | run_step
check "unrelated thought: no observation"   test "$(obs_count)" = 0
check "index was built"                     test -s "$ID/retrieval/index.tsv"
check "index rows have word/id/summary"     grep -q "$(printf 'colima\taaaa1111\tdocker on this mac is colima')" "$ID/retrieval/index.tsv"

# --- resonance: the colima memory surfaces ---------------------------------
step thought 2 "Why does the docker bind mount of this path silently fail on colima?" | run_step
check "matching thought: one observation"   test "$(obs_count)" = 1
check "observation names the memory id"     bash -c 'last=$(grep "\"source\":\"retrieval\"" "$1" | tail -1); printf "%s" "$last" | jq -e ".retrieved_mem == \"aaaa1111\" and (.content | test(\"reminded of memory aaaa1111\")) and .trigger_step == \"s-2\"" >/dev/null' _ "$TRAJ"
check "observation is a real traj step"     bash -c 'tail -1 "$1" | jq -e ".step_id and .type == \"observation\"" >/dev/null' _ "$TRAJ"

# --- recently surfaced memory is not repeated ------------------------------
step thought 3 "Still fighting colima docker mounts that fail silently." | run_step
check "same memory not resurfaced"          test "$(obs_count)" = 1

# --- a single shared word is not enough (RETRIEVAL_MIN_HITS default 2) -----
step thought 4 "I should read the output carefully." | run_step
check "one shared word: no observation"     test "$(obs_count)" = 1

# --- its own observations never trigger it ---------------------------------
step observation 5 "I'm reminded of memory bbbb2222: short git output vanishes in the pager" ',"source":"retrieval"' | run_step
check "own observation ignored"             test "$(obs_count)" = 1

# --- a different memory surfaces, and the index rebuilds for new memories --
step message 6 "my git log output vanishes as soon as the pager exits" | run_step
check "second memory surfaces"              bash -c 'grep "\"source\":\"retrieval\"" "$1" | tail -1 | jq -e ".retrieved_mem == \"bbbb2222\"" >/dev/null' _ "$TRAJ"
sleep 1   # mtime resolution: the new memory must be newer than the index
mem_file 20260803_cccc_snap "cccc3333" "snap aws cli redirect writes empty files" \
    "On the box the snap aws cli writes zero bytes when stdout is redirected to a file; pipe through cat."
step thought 7 "the snap aws cli wrote an empty file again after the redirect" | run_step
check "index rebuilt: new memory surfaces"  bash -c 'grep "\"source\":\"retrieval\"" "$1" | tail -1 | jq -e ".retrieved_mem == \"cccc3333\"" >/dev/null' _ "$TRAJ"
check "three observations total"            test "$(obs_count)" = 3

# --- a deleted memory must stop surfacing ----------------------------------
# The index is rebuilt when a memory file is newer than it. A deletion makes
# every surviving file OLDER than the index, so an mtime test alone leaves the
# deleted memory's words in place and the step keeps surfacing an id that no
# longer resolves. The id set build-index.sh writes beside the index is what
# catches it.
# The seen list is cleared first, or the check would pass for the wrong reason:
# cccc3333 surfaced a moment ago and would be suppressed as "still fresh"
# whether or not the index still knows about it.
rm -f "$ID/memories/20260803_cccc_snap.md" "$ID/retrieval/seen"
step thought 9 "the snap aws cli wrote an empty file again after the redirect" | run_step
check "deleted memory does not surface"     test "$(obs_count)" = 3
check "deleted id gone from the index"      bash -c '! cut -f2 "$1" | grep -qx cccc3333' _ "$ID/retrieval/index.tsv"
check "the id set exists"                   test -s "$ID/retrieval/index.tsv.ids"
check "deleted id gone from the id set"     bash -c '! grep -qx cccc3333 "$1"' _ "$ID/retrieval/index.tsv.ids"
check "surviving ids still in the id set"   bash -c 'grep -qx aaaa1111 "$1" && grep -qx bbbb2222 "$1"' _ "$ID/retrieval/index.tsv.ids"

# --- an edit still rebuilds (the older path, kept honest) -------------------
# The seen list is cleared first: bbbb2222 surfaced earlier in this run, and a
# recently surfaced memory is suppressed on purpose.
sleep 1
rm -f "$ID/retrieval/seen"
mem_file 20260802_bbbb_pager "bbbb2222" "short git output vanishes in the pager" \
    "The LESS variable lacks -X, so paged git output disappears. Also the docker colima mount note applies."
step thought 10 "colima docker mount and the pager both bite me" | run_step
check "edited memory still surfaces"        bash -c 'grep "\"source\":\"retrieval\"" "$1" | tail -1 | jq -e ".retrieved_mem == \"bbbb2222\"" >/dev/null' _ "$TRAJ"
check "four observations total"             test "$(obs_count)" = 4

# --- a tie between two memories is decided the same way every time ---------
# awk walks its own hash order, so an unbroken tie used to surface whichever
# memory it happened to emit first, run after run, and the loser got suppressed
# by the seen list for nothing.
ID2="$WORK/ident2"
mkdir -p "$ID2/memories" "$ID2/trajectories/$TRAJ_ID"
printf 'name=testid2\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$ID2/info.txt"
: > "$ID2/trajectories/$TRAJ_ID/trajectory.jsonl"
for pair in "aaaa1111:alpha" "ffff9999:zulu"; do
    mid=${pair%%:*}; name=${pair##*:}
    printf -- '---\nid: %s\nsummary: %s memory\ntype: fact\n---\nshares exactly the words zebra quokka and nothing else\n' \
        "$mid" "$name" > "$ID2/memories/$name.md"
done
run_step2() {
    env IDENTITY_DIR="$ID2" IDENTITY_NAME=testid2 MEM_DIR="$ID2/memories" \
        TRAJ_DIR="$ID2/trajectories" TRAJ_ID="$TRAJ_ID" SKILLS_DIR="$ID2/skills" \
        SKILLS_KERNEL_DIR="$ID2/kernel" HOME="$WORK/home" "$STEP"
}
tie=""
for i in 1 2 3 4 5; do
    rm -f "$ID2/retrieval/seen" "$ID2/retrieval/index.tsv" "$ID2/retrieval/index.tsv.ids"
    step thought "tie-$i" "zebra quokka" | run_step2
    this=$(grep '"source":"retrieval"' "$ID2/trajectories/$TRAJ_ID/trajectory.jsonl" | tail -1 | jq -r '.retrieved_mem // empty')
    [[ -z "$tie" ]] && tie="$this"
    [[ "$this" == "$tie" ]] || tie="unstable"
done
check "a tie always picks the same memory"  test "$tie" = "aaaa1111"

# --- build-index.sh standalone ---------------------------------------------
rows=$(MEM_DIR="$ID/memories" IDENTITY_DIR="$ID" "$REPO/thinkers/retrieval/build-index.sh" "$ID/memories" "$WORK/idx.tsv")
check "build-index prints row count"        test "$rows" = "$(wc -l < "$WORK/idx.tsv" | tr -d ' ')"
check "build-index skips stopwords"         bash -c '! cut -f1 "$1" | grep -qx "the"' _ "$WORK/idx.tsv"

# --- no memories: quiet no-op ----------------------------------------------
rm -f "$ID/memories"/*.md
step thought 8 "colima docker mount" | run_step
check "no memories: exits 0, no append"     test "$(obs_count)" = 4

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
