#!/usr/bin/env bash
# `traj check` reads every row of a trajectory. It used to spawn one jq per
# line, which cost about six seconds per thousand rows on a real 21 KB-row log.
# These checks pin the output it is supposed to keep while it does that in a
# single pass per file.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID \
    SHELLM_RUN_STEP_ID SHELLM_RAW_TAIL_LINES 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
cleanup() { cd / && rm -rf "$WORK"; }
trap cleanup EXIT

export TRAJ_DIR="$WORK/trajectories"
mkdir -p "$TRAJ_DIR"
TRAJ_ID=$(traj new --slug root | head -1)
export TRAJ_ID
FILE=$(traj path)

# One well-formed row, so the file exists with a valid line in it.
traj append --field type=thought --field content=good >/dev/null

# A file of exactly known shape: valid, invalid, blank, valid, invalid.
write_fixture() {
    local f="$1"
    {
        printf '%s\n' '{"type":"thought","content":"one","step_id":"k-1"}'
        printf '%s\n' 'not json at all'
        printf '\n'
        printf '%s\n' '{"type":"thought","content":"two","step_id":"k-2"}'
        printf '%s\n' '{"broken json":'
    } > "$f"
}
write_fixture "$FILE"

# A clean file reports OK and exits 0.
is "a clean file passes" "0" "$(
    printf '%s\n' '{"type":"thought","step_id":"c-1"}' > "$FILE"
    traj check >/dev/null 2>&1; echo $?)"

# The detection output: the failing lines, by their 1-based line numbers,
# with a preview of the row, and the summary line.
write_fixture "$FILE"
out=$(traj check 2>&1)
rc=$?
is "a malformed file fails" "1" "$rc"
is "malformed rows are reported by number" \
   "2 5" "$(printf '%s\n' "$out" | sed -n 's/.*:[0-9]*: \(.*\)/\1/p' >/dev/null; printf '%s\n' "$out" | awk -F: '/^.*:[0-9]+: /{print $2}' | tr '\n' ' ' | sed 's/ $//')"
is "the row preview is shown" "1" "$(printf '%s\n' "$out" | grep -c 'not json at all')"
is "the summary counts the bad rows" "1" "$(printf '%s\n' "$out" | grep -c '^2 malformed line(s) in 1 file(s)$')"

# A blank line is not a malformed row. Every reader uses `fromjson? // empty`,
# so a trailing newline would otherwise read as corruption forever.
{
    printf '%s\n' '{"type":"thought","step_id":"b-1"}'
    printf '\n'
    printf '%s\n' '{"type":"thought","step_id":"b-2"}'
    printf '\n'
} > "$FILE"
is "blank lines are not malformed" "0" "$(traj check >/dev/null 2>&1; echo $?)"

# A valid row after a bad one is not reported: the detection must not carry
# state from one line to the next.
{
    printf '%s\n' '{"type":"thought","step_id":"s-1"}'
    printf '%s\n' 'garbage'
    printf '%s\n' '{"type":"thought","step_id":"s-3"}'
} > "$FILE"
is "only the bad row is reported" "garbage" \
   "$(traj check 2>&1 | sed -n 's/^.*:[0-9]*: //p')"

# --fix removes exactly the malformed rows, leaves the good ones in order,
# and exits 0 on success.
write_fixture "$FILE"
traj check --fix >/dev/null 2>&1
is "--fix exits 0" "0" "$?"
is "--fix keeps the good rows in order" "one two" \
   "$(jq -r '.content' "$FILE" | tr '\n' ' ' | sed 's/ $//')"
is "--fix leaves a file the reader accepts" "0" "$(traj check >/dev/null 2>&1; echo $?)"

# A multibyte row and a tab in the row do not corrupt the report or the file.
{
    printf '%s\n' '{"type":"thought","content":"日本語","step_id":"m-1"}'
    printf '%s\n' $'{"broken":\t"日本語 x'
} > "$FILE"
out=$(traj check 2>&1)
is "a multibyte preview is reported whole" "1" \
   "$(printf '%s\n' "$out" | grep -c '日本語 x')"
traj check --fix >/dev/null 2>&1
is "the multibyte row survives --fix" "日本語" "$(jq -r '.content' "$FILE")"

# The whole reason for the rewrite: one jq per file, not one per row. A
# 200-row log used to spawn 200 jq processes (~1.2s here); a per-line loop
# creeping back in shows up as a jq count that tracks the row count.
REAL_JQ=$(command -v jq)
mkdir -p "$WORK/shim"
cat > "$WORK/shim/jq" <<SHIM
#!/usr/bin/env bash
printf 'x' >> "$WORK/jq_calls"
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$WORK/shim/jq"
jq -nc 'range(0;200) | {type:"thought",content:("x" * 400),step_id:"r-\(.)"}' > "$FILE"
: > "$WORK/jq_calls"
PATH="$WORK/shim:$PATH" traj check >/dev/null 2>&1
n=$(wc -c < "$WORK/jq_calls" | tr -d ' ')
if [[ "$n" -lt 20 ]]; then ok "a 200-row check spawns a handful of jq ($n), not one per row"
else bad "a 200-row check spawns a handful of jq, not one per row" "got $n calls"; fi

# -r walks forks, and an empty trajectory is not an error.
mkdir -p "$WORK/other"
is "-r on a single file is clean" "0" "$(traj check -r >/dev/null 2>&1; echo $?)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
