#!/usr/bin/env bash
# tests/test_skills_requirements.sh — bin/skills reads a skill's declared
# requirements and its body correctly.
#
# Why: the requirement reader only understood a JSON flow list
# (bins: ["jq"]), which is what every skill in this repo happens to use. The
# standard YAML block list (a "- jq" line) parsed as no requirements at all,
# so a skill whose tools are missing listed as eligible and the mind would
# load a playbook it could not run. An unquoted flow list ([jq, curl]) made
# jq fail under `set -e`, which took `skills list` down with exit 2 in the
# middle of printing. Both fail in the direction that hides the problem.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

H=$(mktemp -d); trap 'rm -rf "$H"' EXIT
sk() { mkdir -p "$H/skills/$1"; cat > "$H/skills/$1/SKILL.md"; }
list() { SKILLS_DIR="$H/skills" NO_COLOR=1 bash "$REPO/bin/skills" list 2>&1; }
rq()   { SKILLS_DIR="$H/skills" NO_COLOR=1 bash "$REPO/bin/skills" show "$1" --requires 2>/dev/null; }

MISSING=definitelynotabinary12345

sk block <<YAML
---
name: block
description: standard YAML block list
metadata:
  shelllm:
    requires:
      bins:
        - $MISSING
---
YAML
sk blockok <<YAML
---
name: blockok
description: block list all present
metadata:
  shelllm:
    requires:
      bins:
        - jq
        - curl
---
YAML
sk flow <<YAML
---
name: flow
description: unquoted flow list
metadata:
  shelllm:
    requires:
      bins: [jq, $MISSING]
---
YAML
sk quoted <<'YAML'
---
name: quoted
description: quoted flow list
metadata:
  shelllm:
    requires:
      bins: ["jq", "curl"]
---
YAML
sk envblk <<'YAML'
---
name: envblk
description: env block list
metadata:
  shelllm:
    requires:
      env:
        - DEFINITELY_NOT_SET_XYZ
---
YAML
sk anyb <<'YAML'
---
name: anyb
description: anyBins block, one present
metadata:
  shelllm:
    requires:
      anyBins:
        - notabin_xyz
        - jq
---
YAML
sk outsider <<'YAML'
---
name: outsider
description: an os key outside requires must not count
metadata:
  other:
    os: [plan9]
---
YAML
sk ruler <<'YAML'
---
name: ruler
description: body contains a horizontal rule
---

# ruler
before the ruler
---
after the ruler
YAML

# --- requirement parsing -------------------------------------------------
out=$(list)
check_missing() { grep -q "^  $1 .*(missing: .*$2" <<<"$out"; }
check_missing block "$MISSING" && ok "block list requirement is read (skill skipped)" \
  || bad "block list requirement is read (skill skipped)"
check_missing flow "$MISSING" && ok "unquoted flow list requirement is read" \
  || bad "unquoted flow list requirement is read"
check_missing envblk "DEFINITELY_NOT_SET_XYZ" && ok "env block list requirement is read" \
  || bad "env block list requirement is read"
grep -q '^  blockok ' <<<"$out" && ok "block list with every bin present is eligible" \
  || bad "block list with every bin present is eligible"
grep -q '^  quoted ' <<<"$out" && ok "quoted flow list with every bin present is eligible" \
  || bad "quoted flow list with every bin present is eligible"
grep -q '^  anyb ' <<<"$out" && ok "anyBins is satisfied by one present binary" \
  || bad "anyBins is satisfied by one present binary"
grep -q '^  outsider ' <<<"$out" && ok "an os key outside requires is not a requirement" \
  || bad "an os key outside requires is not a requirement"

# --- a bad requirement must not abort the listing ------------------------
SKILLS_DIR="$H/skills" NO_COLOR=1 bash "$REPO/bin/skills" list >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "list exits 0 even with an unquoted flow list" \
  || bad "list exits 0 even with an unquoted flow list"

# --- the parsed shape ----------------------------------------------------
rq quoted | jq -e '.requires.bins == ["jq","curl"]' >/dev/null 2>&1 \
  && ok "flow list parses to a clean JSON array" || bad "flow list parses to a clean JSON array"
rq anyb | jq -e '.requires.anyBins == ["notabin_xyz","jq"]' >/dev/null 2>&1 \
  && ok "anyBins parses to a clean JSON array" || bad "anyBins parses to a clean JSON array"

# --- body extraction stops at the first frontmatter block ----------------
SKILLS_DIR="$H/skills" NO_COLOR=1 bash "$REPO/bin/skills" list-json 2>/dev/null \
  | jq -r '.[]|select(.name=="ruler").instructions' > "$H/ruler.txt"
grep -q 'after the ruler' "$H/ruler.txt" && ok "list-json keeps text after a body ruler" \
  || bad "list-json keeps text after a body ruler"
grep -q '^name: ruler' "$H/ruler.txt" && bad "list-json body excludes frontmatter" \
  || ok "list-json body excludes frontmatter"

# --- an inline flow mapping warns instead of lying -----------------------
sk flowmap <<'YAML'
---
name: flowmap
description: inline requires mapping
metadata:
  shelllm:
    requires: {bins: [jq]}
---
YAML
err=$(SKILLS_DIR="$H/skills" NO_COLOR=1 bash "$REPO/bin/skills" list 2>&1 >/dev/null)
grep -q 'cannot parse' <<<"$err" && ok "an unparseable inline requires warns on stderr" \
  || bad "an unparseable inline requires warns on stderr"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
