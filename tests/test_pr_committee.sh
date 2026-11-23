#!/usr/bin/env bash
# tests/test_pr_committee.sh — tools/pr-committee must not report success for
# work that did not happen.
#
# Three ways it used to: 'read -a' on an empty --models/PRC_MODELS yielded one
# blank reviewer that "succeeded" doing nothing; a reviewer that exited 0 with
# no output was counted as a review and pasted into the chair brief as an empty
# section; and a chair that exited 0 with no output had the footer appended to
# an empty file, which was then printed as the report. In each case the command
# exited 0 and the artifact read like a clean result. bin/llm can return an
# empty completion, so this is a real shape, not a hypothetical.
#
# A fourth, cosmetic: --help printed lines 4..40 while the header docs run to
# 43, cutting the Environment section off mid-list.
#
# The tool calls bin/llm, so each run gets a stub on PATH. The stub looks at its
# own --system-prompt-file to tell the chair call from a reviewer call, and at
# $FAKE_EMPTY to decide whether to return text.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO/tools/pr-committee"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A caller's PRC_* would silently override every case below.
unset PRC_MODELS PRC_CHAIR PRC_MAX_FILE_BYTES PRC_MAX_FILES_BYTES

# --- a throwaway repo to review, so the test does not depend on real history
GIT="$WORK/repo"
mkdir -p "$GIT"
(
    cd "$GIT"
    git init -q .
    git config user.email t@example.com
    git config user.name t
    printf 'one\n' > a.txt
    git add a.txt
    git commit -qm 'first'
    printf 'one\ntwo\n' > a.txt
    git add a.txt
    git commit -qm 'second'
) >/dev/null 2>&1

# --- stub bin/llm ---------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
# Chair calls carry --system-prompt-file .../sys-chair.txt; reviewers do not.
is_chair=0
for a in "$@"; do [[ "$a" == *sys-chair.txt ]] && is_chair=1; done
if [[ -n "${FAKE_EMPTY:-}" ]]; then
    case "$FAKE_EMPTY" in
        all)       exit 0 ;;
        reviewers) (( is_chair )) && { echo "VERDICT: approve"; echo "SUMMARY: stub"; echo '```json'; echo '[]'; echo '```'; }; exit 0 ;;
        chair)     (( is_chair )) && exit 0
                   echo "VERDICT: approve"; echo "SUMMARY: stub"; echo '```json'; echo '[]'; echo '```'; exit 0 ;;
    esac
fi
echo "VERDICT: approve"
echo "SUMMARY: stub review"
echo '```json'
echo '[]'
echo '```'
STUB
chmod +x "$WORK/bin/llm"

export PATH="$WORK/bin:$PATH"
export HOME="$WORK/home"   # so no run dir lands in a real state home
mkdir -p "$HOME"

# run_tool NAME [args...]: run the tool in the throwaway repo, capture status
run_tool() {
    local name="$1"; shift
    ( cd "$GIT" && "$TOOL" "$@" ) > "$WORK/out-$name" 2>&1
    RC=$?
    OUT=$(cat "$WORK/out-$name")
}

# --- 1. an empty roster is refused, with a message that says why ----------
run_tool comma --diff HEAD~1..HEAD --models , --chair fake/chair --out "$WORK/r1"
if [[ "$RC" -ne 0 ]] && grep -q 'no reviewer models' "$WORK/out-comma"; then
    ok "a roster of only commas is refused"
else
    bad "a roster of only commas is refused" "rc=$RC out=$(printf '%s' "$OUT" | tail -1)"
fi
if [[ -f "$WORK/r1/review-1-.md" ]]; then
    bad "no blank-named reviewer is created" "review-1-.md exists"
else
    ok "no blank-named reviewer is created"
fi

# --- 2. an explicitly empty --models names the option, not a line number --
# Bash's own ${2:?} reported this as "line 65: 2: --models requires a value",
# which names a line instead of the thing the caller got wrong.
run_tool empty --diff HEAD~1..HEAD --models "" --out "$WORK/r2"
msg=$(printf '%s' "$OUT" | tail -1)
if [[ "$RC" -ne 0 ]] && [[ "$msg" == *"--models requires a value"* ]] \
    && [[ "$msg" != *"line "* ]]; then
    ok "an empty --models names the option it needs"
else
    bad "an empty --models names the option it needs" "rc=$RC msg=$msg"
fi

# --- 3. spaces around roster entries are trimmed --------------------------
run_tool spaces --diff HEAD~1..HEAD --models 'fake/a, fake/b' --chair fake/chair --out "$WORK/r3"
if [[ -f "$WORK/r3/review-1-fake-a.md" && -f "$WORK/r3/review-1-fake-b.md" ]]; then
    ok "--models 'a, b' trims the names"
else
    bad "--models 'a, b' trims the names" "files: $(ls "$WORK/r3" 2>/dev/null | tr '\n' ' ')"
fi

# --- 4. a reviewer that exits 0 with nothing is a failure -----------------
FAKE_EMPTY=reviewers run_tool rev-empty --diff HEAD~1..HEAD --models fake/one \
    --chair fake/chair --out "$WORK/r4"
if [[ "$RC" -ne 0 ]] && grep -q 'returned no review' "$WORK/out-rev-empty"; then
    ok "a reviewer returning exit 0 with no output is not a review"
else
    bad "a reviewer returning exit 0 with no output is not a review" "rc=$RC out=$(printf '%s' "$OUT" | tail -1)"
fi

# --- 5. a chair that exits 0 with nothing does not become the report ------
FAKE_EMPTY=chair run_tool chair-empty --diff HEAD~1..HEAD --models fake/one \
    --chair fake/chair --out "$WORK/r5"
if [[ "$RC" -ne 0 ]] && grep -q 'returned no report' "$WORK/out-chair-empty"; then
    ok "an empty chair report is refused"
else
    bad "an empty chair report is refused" "rc=$RC out=$(printf '%s' "$OUT" | tail -1)"
fi

# --- 6. the happy path still writes a report ------------------------------
run_tool happy --diff HEAD~1..HEAD --models fake/a,fake/b --chair fake/chair --out "$WORK/r6"
if [[ "$RC" -eq 0 ]] && grep -q 'VERDICT: approve' "$WORK/r6/report.md" \
    && grep -q 'Committee: fake/a,fake/b' "$WORK/r6/report.md"; then
    ok "a normal run still produces a report"
else
    bad "a normal run still produces a report" "rc=$RC"
fi

# --- 7. --help shows the end of the Environment section -------------------
help=$(cd "$GIT" && "$TOOL" --help 2>&1)
if printf '%s' "$help" | grep -q 'PRC_MAX_FILES_BYTES'; then
    ok "--help prints the whole header, Environment section included"
else
    bad "--help prints the whole header, Environment section included"
fi

echo
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
