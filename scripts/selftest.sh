#!/usr/bin/env bash
# Self-test for env-safe.sh. Creates fixtures in a temp dir, asserts behaviour,
# and proves that no subcommand ever prints a secret value.
#
# Note on fixtures: they never contain a secret-shaped *literal*. Values are
# assembled at runtime, so `env-safe.sh scan scripts/` stays clean on this repo
# and GitHub's secret scanner has nothing to complain about.
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
S="$DIR/env-safe.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
eq() { [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2', want '$3')"; }

v1=abc123def456ghi789jkl
v2=plainvalue9876543210
v3=a-completely-different-value0
v4=brandnewvalue123456789

printf 'export API_KEY="%s"\nSECRET_TOKEN=%s\nEMPTY=\nDB_URL=postgres://localhost/db\n' \
  "$v1" "$v2" >"$TMP/a.env"
printf 'API_KEY="%s"\nSECRET_TOKEN=%s\nEXTRA_KEY=%s\n' "$v3" "$v2" "$v4" >"$TMP/b.env"

echo "names"
eq "lists keys in order" "$("$S" names "$TMP/a.env" | tr '\n' ' ')" \
  "API_KEY SECRET_TOKEN EMPTY DB_URL "
printf 'DUP=1\nDUP=2\n' >"$TMP/dup.env"
eq "duplicate key listed once" "$("$S" names "$TMP/dup.env")" "DUP"
eq "duplicate key resolves to last value" "$("$S" len "$TMP/dup.env" DUP)" "1"

echo "has"
"$S" has "$TMP/a.env" API_KEY && ok "has: present" || no "has: should be present"
"$S" has "$TMP/a.env" NOPE 2>/dev/null && no "has: should be absent" || ok "has: absent"
"$S" has "$TMP/missing.env" K 2>/dev/null && no "has: missing file should fail" \
  || ok "has: missing file exits non-zero"

echo "len / fp"
eq "len" "$("$S" len "$TMP/a.env" API_KEY)" "${#v1}"
eq "len of empty value" "$("$S" len "$TMP/a.env" EMPTY)" "0"
[ "$("$S" fp "$TMP/a.env" API_KEY)" != "$("$S" fp "$TMP/b.env" API_KEY)" ] \
  && ok "fp differs for different values" || no "fp collided"
eq "fp is stable" "$("$S" fp "$TMP/a.env" API_KEY)" "$("$S" fp "$TMP/a.env" API_KEY)"
"$S" len "$TMP/a.env" NOPE 2>/dev/null && no "len: missing key should fail" \
  || ok "len: missing key exits non-zero"

echo "parsing"
hash_inside='value with # hash inside'
printf 'Q1="%s"\nQ2=abc=def=ghi\nQ3=  spaced  \nexport Q4=exported\nQ5="q"\r\n' \
  "$hash_inside" >"$TMP/edge.env"
eq "quoted value keeps its #" "$("$S" len "$TMP/edge.env" Q1)" "${#hash_inside}"
eq "value containing = is intact" "$("$S" len "$TMP/edge.env" Q2)" "11"
eq "unquoted value is trimmed" "$("$S" len "$TMP/edge.env" Q3)" "6"
eq "export prefix handled" "$("$S" len "$TMP/edge.env" Q4)" "8"
eq "CRLF handled" "$("$S" len "$TMP/edge.env" Q5)" "1"
printf '\xef\xbb\xbfBOMKEY=bomvalue\n' >"$TMP/bom.env"
eq "BOM does not corrupt first key" "$("$S" names "$TMP/bom.env")" "BOMKEY"

echo "diff"
out=$("$S" diff "$TMP/a.env" "$TMP/b.env")
printf '%s\n' "$out" | grep -q "same" && ok "diff reports unchanged key" || no "diff: no 'same' row"
printf '%s\n' "$out" | grep -q "EXTRA_KEY" && ok "diff reports added key" || no "diff: missed added key"

echo "run"
eq "child sees value, we see length" \
  "$("$S" run "$TMP/a.env" -- bash -c 'printf %s "${#API_KEY}"' 2>/dev/null)" "${#v1}"
"$S" run "$TMP/a.env" -- false 2>/dev/null && no "run: exit code lost" \
  || ok "run propagates the child's exit code"

echo "scan"
mkdir -p "$TMP/repo"
fake=fixture-not-a-credential-0001
printf 'const API_KEY = "%s";\n' "$fake" >"$TMP/repo/a.ts"
printf 'API_KEY=your_key_here\nFOO=bar\nSITE_URL=https://example.com/path\n' >"$TMP/repo/clean.env"
"$S" scan "$TMP/repo" >"$TMP/scan.out" 2>&1 && no "scan: should exit 1" || ok "scan: exit 1 on finding"
grep -q "a.ts" "$TMP/scan.out" && ok "scan finds secret in source" || no "scan missed source secret"
grep -q "your_key_here" "$TMP/scan.out" && no "scan flagged a placeholder" || ok "scan skips placeholders"
grep -q "SITE_URL" "$TMP/scan.out" && no "scan flagged a plain URL" || ok "scan ignores URLs without credentials"

# credentials embedded in a URL under a benign variable name
c=:
printf 'DATABASE_URL=postgres%s//app%shunter2@db.internal:5432/prod\n' "$c" "$c" >"$TMP/repo/url.env"
"$S" scan "$TMP/repo/url.env" >"$TMP/url.out" 2>&1 && no "scan missed URL password" \
  || ok "scan catches credentials inside a URL"
grep -q "hunter2" "$TMP/url.out" && no "scan printed the URL password" || ok "scan keeps URL password out of output"

# a PEM header only counts at the start of a line (this script mentions the
# string in its own redaction regex and must not flag itself)
printf 'x = "-----BEGIN RSA PRIVATE KEY----- not really"\n' >"$TMP/repo/regex.ts"
"$S" scan "$TMP/repo/regex.ts" >/dev/null 2>&1 && ok "PEM text mid-line is not a false positive" \
  || no "PEM text mid-line false positive"
printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n' >"$TMP/repo/id_rsa"
"$S" scan "$TMP/repo/id_rsa" >/dev/null 2>&1 && no "scan missed a real PEM block" \
  || ok "scan catches a real PEM block"

echo "self-scan"
"$S" scan "$DIR" >"$TMP/self.out" 2>&1 && ok "the repo scans clean on itself" \
  || { no "the repo flags itself"; sed -n '1,5p' "$TMP/self.out"; }

echo "redact"
printf '%s\n' "ghp_$(printf 'abcdefghijklmnopqrstuvwxyz0123456789')" \
  | "$S" redact | grep -q 'ghp_<REDACTED>' \
  && ok "redact masks tokens" || no "redact left a token"

echo "no-leak invariant"
{
  "$S" names "$TMP/a.env"
  "$S" len "$TMP/a.env" API_KEY
  "$S" fp "$TMP/a.env" API_KEY
  "$S" diff "$TMP/a.env" "$TMP/b.env"
  "$S" scan "$TMP/repo"
  "$S" run "$TMP/a.env" -- true
} >"$TMP/all.out" 2>&1
if grep -qE "$v1|$v2|$v3|$v4" "$TMP/all.out"; then
  no "a secret value reached stdout"
else
  ok "no secret value reached stdout in any subcommand"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
