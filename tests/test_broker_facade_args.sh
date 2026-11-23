#!/usr/bin/env bash
# tests/test_broker_facade_args.sh — the broker's read-only docker handlers
# (ps, info, version) must not be a pass-through and must not silently drop
# what they do not accept.
#
# Three defects are pinned here. handle_ps never read its request at all, so
# `ps -a` returned running containers with no error and no hint the flag was
# gone. handle_info and handle_version appended whatever the sandbox sent onto
# the docker command line, so a request controlled a docker argv the broker
# never inspected. And the dispatcher called handle_ps with no argument, which
# is why the first one could not have been fixed by editing the handler alone.
#
# The assertion is on the response JSON (exit_code, and the message), because a
# broker handler reports failure by emitting that JSON rather than by its exit
# status: process_request runs the handler and the response is what the
# in-container facade prints. A test that only checked $? would call every
# rejection a pass. Each rejection case also proves the docker stub never ran,
# so a "rejected" verdict cannot come from docker failing on a bad flag.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found — the broker needs it, so this proves nothing"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
echo "stub-docker-output"
STUB
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
export CALLS="$WORK/calls"

export SHELLM_BROKER_ENV="testenv"
export SHELLM_BROKER_LOG="$WORK/broker.log"

# shellcheck disable=SC1090  # the broker under test
source "$REPO/tools/shellm-docker-broker"
set +e   # the broker sets -e; a rejected request is an expected outcome

# run_handler HANDLER ARGS-JSON: run one handler with a synthetic request and
# leave the parsed response in OUT_CODE / OUT_ERR.
OUT_CODE=""
OUT_ERR=""
run_handler() {
    local handler="$1" args_json="$2" out
    : > "$CALLS"
    out=$("$handler" "{\"op\":\"$handler\",\"args\":$args_json}")
    OUT_CODE=$(printf '%s' "$out" | jq -r '.exit_code' 2>/dev/null)
    OUT_ERR=$(printf '%s' "$out" | jq -r '.stderr' 2>/dev/null)
}

expect_reject() {
    local name="$1" handler="$2" args_json="$3" want_words="$4"
    run_handler "$handler" "$args_json"
    if [[ "$OUT_CODE" == "64" ]]; then
        if printf '%s' "$OUT_ERR" | grep -qi -- "$want_words"; then
            ok "$name"
        else
            bad "$name" "rejected but said: $OUT_ERR"
        fi
    else
        bad "$name" "expected exit_code 64, got '$OUT_CODE' (stderr: $OUT_ERR)"
    fi
    if [[ -s "$CALLS" ]]; then
        bad "$name — docker was never reached" "calls: $(cat "$CALLS")"
    else
        ok "$name — docker was never reached"
    fi
}

expect_accept() {
    local name="$1" handler="$2" args_json="$3" want_call="$4"
    run_handler "$handler" "$args_json"
    if [[ "$OUT_CODE" == "0" ]]; then
        ok "$name"
    else
        bad "$name" "expected exit_code 0, got '$OUT_CODE' (stderr: $OUT_ERR)"
    fi
    if grep -qxF -- "$want_call" "$CALLS" 2>/dev/null; then
        ok "$name — docker got exactly: $want_call"
    else
        bad "$name — reached docker with the right argv" "calls: $(tr '\n' '|' < "$CALLS")"
    fi
}

echo '# ps'
expect_reject "ps -a is rejected rather than silently ignored" handle_ps '["-a"]' "ps takes no arguments"
expect_reject "ps --format is rejected (ps is fixed-shape, not a lens)" handle_ps '["--format","{{.Names}}"]' "ps takes no arguments"
expect_accept   "ps with no args lists only this env's containers" handle_ps '[]' "ps --filter label=shellm.broker.env=testenv"

echo
echo '# info'
expect_reject "info --bogus is rejected" handle_info '["--bogus","x"]' "info accepts only --format"
expect_reject "info with three args is rejected" handle_info '["--format","x","y"]' "info accepts only --format"
expect_accept   "info with no args is accepted" handle_info '[]' "info"
expect_accept   "info --format TEMPLATE is accepted" handle_info '["--format","{{.ServerVersion}}"]' "info --format {{.ServerVersion}}"
expect_accept   "info --format=TEMPLATE is accepted" handle_info '["--format={{.ServerVersion}}"]' "info --format={{.ServerVersion}}"

echo
echo '# version'
expect_reject "version --bogus is rejected" handle_version '["--bogus"]' "version accepts"
expect_reject "version with a bare second arg is rejected" handle_version '["--format"]' "version accepts"
expect_reject "version with three args is rejected" handle_version '["-f","a","b"]' "version accepts"
expect_accept   "version with no args is accepted" handle_version '[]' "version"
expect_accept   "version -v is accepted and means --version" handle_version '["-v"]' "--version"
expect_accept   "version --version is accepted" handle_version '["--version"]' "--version"
expect_accept   "version --format TEMPLATE is accepted" handle_version '["--format","{{.Server.Version}}"]' "version --format {{.Server.Version}}"

echo
echo '# dispatcher'
# The bug below the bug: the old dispatch line called handle_ps with no
# argument, so the handler's own check could never see the request. This drives
# the real dispatcher entry point end to end.
: > "$CALLS"
out=$(process_request '{"op":"ps","args":["-a"]}')
code=$(printf '%s' "$out" | jq -r '.exit_code' 2>/dev/null)
if [[ "$code" == "64" ]] && [[ ! -s "$CALLS" ]]; then
    ok "process_request hands the request to handle_ps"
else
    bad "process_request hands the request to handle_ps" "exit_code='$code' calls=$(tr '\n' '|' < "$CALLS")"
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
