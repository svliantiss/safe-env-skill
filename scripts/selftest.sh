#!/usr/bin/env bash
# Self-test for env-safe.sh. Creates fixtures in a temp dir, asserts behaviour,
# and proves that no subcommand ever prints a secret value.
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
S="$DIR/env-safe.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
eq() { [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2', want '$3')"; }

printf '%s\n' \
  '# comment' \
  'export API_KEY="abc123def456ghi789jkl"' \
  'SECRET_TOKEN=plainvalue9876543210' \
  'EMPTY=' \
  'DB_URL=postgres://u:p@localhost/db' >"$TMP/a.env"
printf '%s\n' \
  'API_KEY="a-completely-different-value0"' \
  'SECRET_TOKEN=plainvalue9876543210' \
  'EXTRA_KEY=brandnewvalue123456789' >"$TMP/b.env"

echo "names"
eq "lists keys in order" "$("$S" names "$TMP/a.env" | tr '\n' ' ')" \
  "API_KEY SECRET_TOKEN EMPTY DB_URL "
"$S" has "$TMP/a.env" API_KEY && ok "has: present" || no "has: should be present"
"$S" has "$TMP/a.env" NOPE 2>/dev/null && no "has: should be absent" || ok "has: absent"
eq "len" "$("$S" len "$TMP/a.env" API_KEY)" "21"
eq "len of empty value" "$("$S" len "$TMP/a.env" EMPTY)" "0"
[ "$("$S" fp "$TMP/a.env" API_KEY)" != "$("$S" fp "$TMP/b.env" API_KEY)" ] \
  && ok "fp differs for different values" || no "fp collided"

echo "diff"
out=$("$S" diff "$TMP/a.env" "$TMP/b.env")
printf '%s\n' "$out" | grep -q "same" && ok "diff reports unchanged key" || no "diff: no 'same' row"
printf '%s\n' "$out" | grep -q "EXTRA_KEY" && ok "diff reports added key" || no "diff: missed added key"

echo "run"
eq "child sees value, we see length" \
  "$("$S" run "$TMP/a.env" -- bash -c 'printf %s "${#API_KEY}"' 2>/dev/null)" "21"

echo "scan"
mkdir -p "$TMP/repo"
# The value never has to look like a real provider key: `scan` matches on the
# variable NAME. Keeping the fixture obviously fake also keeps GitHub push
# protection (and every other secret scanner) quiet.
printf '%s\n' 'const API_KEY = "fixture-not-a-credential-0001";' >"$TMP/repo/a.ts"
printf '%s\n' 'API_KEY=your_key_here' 'FOO=bar' >"$TMP/repo/clean.env"
"$S" scan "$TMP/repo" >"$TMP/scan.out" 2>&1 && no "scan: should exit 1" || ok "scan: exit 1 on finding"
grep -q "a.ts" "$TMP/scan.out" && ok "scan finds secret in source" || no "scan missed source secret"
grep -q "your_key_here" "$TMP/scan.out" && no "scan flagged a placeholder" || ok "scan skips placeholders"

echo "redact"
# assembled at runtime so no scanner sees a token-shaped literal in this file
printf '%s\n' "ghp_$(printf 'abcdefghijklmnopqrstuvwxyz0123456789')" \
  | "$S" redact | grep -q 'ghp_<REDACTED>' \
  && ok "redact masks tokens" || no "redact left a token"

echo "no-leak invariant"
{
  "$S" names "$TMP/a.env"
  "$S" len "$TMP/a.env" API_KEY
  "$S" fp "$TMP/a.env" API_KEY
  "$S" diff "$TMP/a.env" "$TMP/b.env"
  "$S" scan "$TMP/a.env" "$TMP/b.env"
  "$S" run "$TMP/a.env" -- true
} >"$TMP/all.out" 2>&1
if grep -qE 'abc123def456ghi789jkl|plainvalue9876543210|postgres://' "$TMP/all.out"; then
  no "a secret value reached stdout"
else
  ok "no secret value reached stdout in any subcommand"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
