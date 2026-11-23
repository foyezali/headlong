#!/usr/bin/env bash
# tests/test_persona_llm_health.sh — `persona <name> status` warns about a
# failed LLM call using the FRESHEST health marker, wherever bin/llm wrote it.
#
# Why: bin/llm writes run/llm_health.json under $_llm_home, which is
# HEADLONG_HOME/SHELLM_HOME/$HOME/.headlong. A plain shell and the dash use the
# state home; bin/thinkers exports SHELLM_HOME=<identity>/.shellm, so the
# mind's own calls land per identity. Reading only the state-home file made the
# warning wrong both ways: a credit failure that has since cleared kept
# shouting, and a live failure never showed up, because the mind never writes
# the state-home file at all.
#
# Covers:
#   1. No marker: no warning.
#   2. State-home credit failure: warns and names that state home's .env.
#   3. That failure older than a per-identity ok: silent.
#   4. Per-identity fresh credit failure beats a stale state-home ok: warns,
#      and names the per-identity .env.
#   5. A marker with no ts is dated by its mtime.
#   6. A broken file cannot hide a readable older failure.
#
# Everything runs under a throwaway HOME / app dir. The identity is built by
# hand: `identity new` resolves the real checkout from its own path, so it
# would write into the repo's .identities.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
export HEADLONG_APP_DIR="$WORK/app"
export TMPDIR="$WORK/tmp"
mkdir -p "$HOME" "$HEADLONG_HOME/run" "$HEADLONG_APP_DIR/.identities" "$TMPDIR"
for d in bin tools thinkers; do ln -s "$REPO/$d" "$HEADLONG_APP_DIR/$d"; done

ID="$HEADLONG_APP_DIR/.identities/alpha"
mkdir -p "$ID/.shellm/run" "$ID/run" "$ID/trajectories"
cat > "$ID/activate" <<'ACT'
export IDENTITY_NAME=alpha
export IDENTITY_DIR="$HEADLONG_APP_DIR/.identities/alpha"
export SHELLM_CONF_DIR="$IDENTITY_DIR/.shellm"
export TRAJ_DIR="$IDENTITY_DIR/trajectories"
ACT

ID_MARKER="$ID/.shellm/run/llm_health.json"
HOME_MARKER="$HEADLONG_HOME/run/llm_health.json"

status_of() { persona alpha status 2>&1 || true; }

write_credit() {  # FILE TS
    jq -n --arg ts "$2" '{ok:false, ts:$ts, provider:"openrouter", model:"m",
                          kind:"credit", http_code:402, message:"Insufficient credits"}' > "$1"
    [[ -n "$2" ]] && touch -d "$2" "$1" 2>/dev/null
    return 0
}
write_ok() {      # FILE TS
    jq -n --arg ts "$2" '{ok:true, ts:$ts, provider:"openrouter", model:"m"}' > "$1"
    touch -d "$2" "$1" 2>/dev/null
    return 0
}

# 1. nothing anywhere
out=$(status_of)
if printf '%s' "$out" | grep -q '!! LLM'; then bad "no marker prints no warning" "$out"; else ok "no marker prints no warning"; fi

# 2. a credit failure in the state home (where a plain `llm` call writes)
write_credit "$HOME_MARKER" "2026-08-22T09:00:00Z"
out=$(status_of)
if printf '%s' "$out" | grep -q 'OUT OF CREDIT'; then ok "state-home credit failure warns"; else bad "state-home credit failure warns" "$out"; fi
if printf '%s' "$out" | grep -q "new key in $HEADLONG_HOME/.env"; then ok "warning names that state home's .env"; else bad "warning names that state home's .env" "$out"; fi

# 3. the same failure, but a fresher per-identity call succeeded since
write_ok "$ID_MARKER" "2026-08-22T10:00:00Z"
out=$(status_of)
if printf '%s' "$out" | grep -q 'OUT OF CREDIT'; then bad "a cleared failure stops shouting" "$out"; else ok "a cleared failure stops shouting"; fi

# 4. the reverse: the mind's own call just failed, state home is stale ok
write_ok "$HOME_MARKER" "2026-08-01T00:00:00Z"
write_credit "$ID_MARKER" "2026-08-22T11:00:00Z"
out=$(status_of)
if printf '%s' "$out" | grep -q 'OUT OF CREDIT'; then ok "a fresh per-identity failure warns"; else bad "a fresh per-identity failure warns" "$out"; fi
if printf '%s' "$out" | grep -q "new key in $ID/.shellm/.env"; then ok "and names the per-identity .env"; else bad "and names the per-identity .env" "$out"; fi

# 5. no ts field: the mtime decides (newer than the stale state-home ok)
write_ok "$HOME_MARKER" "2026-08-22T10:30:00Z"
jq -n '{ok:false, provider:"openrouter", model:"m", kind:"credit", http_code:402,
       message:"no credits"}' > "$ID_MARKER"
touch -d "2026-08-22 12:00:00 UTC" "$ID_MARKER"
out=$(status_of)
if printf '%s' "$out" | grep -q 'OUT OF CREDIT'; then ok "a marker with no ts is dated by mtime"; else bad "a marker with no ts is dated by mtime" "$out"; fi

# 6. a broken file cannot hide the readable older one
rm -f "$ID_MARKER"
write_credit "$HOME_MARKER" "2026-08-22T09:00:00Z"
printf '{not json' > "$ID_MARKER"
touch -d "2026-08-22 13:00:00 UTC" "$ID_MARKER"
out=$(status_of)
if printf '%s' "$out" | grep -q 'OUT OF CREDIT'; then ok "a broken marker falls back to a readable one"; else bad "a broken marker falls back to a readable one" "$out"; fi

printf '\npassed: %d\nfailed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
