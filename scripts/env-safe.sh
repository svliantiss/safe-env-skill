#!/usr/bin/env bash
# env-safe — read and use .env files without ever printing a secret.
#
# Every subcommand is designed so a value cannot reach stdout, a log, a
# transcript or shell history. If you think you need the raw value, you almost
# certainly want `run` instead.
#
# Usage: env-safe.sh <command> [args]   (see `env-safe.sh help`)
set -euo pipefail

PROG=${0##*/}
FP_LEN=12

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit "${2:-1}"; }

# sha256 of stdin, first $FP_LEN hex chars.
fp() {
  local h
  if command -v shasum >/dev/null 2>&1; then
    h=$(shasum -a 256 | cut -c1-$FP_LEN)
  elif command -v sha256sum >/dev/null 2>&1; then
    h=$(sha256sum | cut -c1-$FP_LEN)
  else
    die "no sha256 tool found (need shasum or sha256sum)"
  fi
  printf '%s' "$h"
}

# Strip surrounding quotes and trailing CR from a value.
unquote() {
  local v=$1
  case $v in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    \'*\') v=${v#\'}; v=${v%\'} ;;
  esac
  v=${v%$'\r'}
  printf '%s' "$v"
}

# Read a file, calling back per entry. Skips blanks, comments and junk lines.
# Callback form avoids exporting secrets as shell globals.
for_each_entry() {
  local file=$1 cb=$2 line k v
  [[ -f $file ]] || die "no such file: $file" 2
  [[ -r $file ]] || die "not readable: $file" 2
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      '' | '#'*) continue ;;
    esac
    line=${line#export }
    line=${line%%[[:space:]]#*}
    k=${line%%=*}
    [[ $k == "$line" ]] && continue
    case $k in
      '' | *[!A-Za-z0-9_]*) continue ;;
    esac
    v=$(unquote "${line#*=}")
    "$cb" "$k" "$v"
  done <"$file"
}

# Set V to the value of key $2 in file $1. Returns 1 when absent.
lookup() {
  local want=$2 found=1
  _take() { [[ $1 == "$want" ]] && { V=$2; found=0; }; return 0; }
  for_each_entry "$1" _take
  unset -f _take
  return $found
}

cmd_names() {
  [[ $# -ge 1 ]] || die "usage: $PROG names <file>" 2
  _emit() { printf '%s\n' "$1"; }
  for_each_entry "$1" _emit
  unset -f _emit
}

cmd_has() {
  [[ $# -ge 2 ]] || die "usage: $PROG has <file> <KEY>" 2
  lookup "$1" "$2"
}

cmd_len() {
  [[ $# -ge 2 ]] || die "usage: $PROG len <file> <KEY>" 2
  lookup "$1" "$2" || die "key not present: $2" 2
  printf '%s\n' "${#V}"
}

cmd_fp() {
  [[ $# -ge 2 ]] || die "usage: $PROG fp <file> <KEY>" 2
  lookup "$1" "$2" || die "key not present: $2" 2
  printf '%s\n' "$(printf '%s' "$V" | fp)"
}

# Export the file's variables into a child process. The only way a value is
# allowed to move: into an environment the child reads and we never print.
cmd_run() {
  [[ $# -ge 3 ]] || die "usage: $PROG run <file> -- <command...>" 2
  local file=$1 n=0
  shift
  [[ ${1:-} == -- ]] && shift
  [[ $# -ge 1 ]] || die "usage: $PROG run <file> -- <command...>" 2
  _export() { export "$1=$2"; n=$((n + 1)); }
  for_each_entry "$file" _export
  unset -f _export
  printf '%s: exported %s variables from %s; running: %s\n' \
    "$PROG" "$n" "$file" "$*" >&2
  exec "$@"
}

# Compare two files per key, by fingerprint. Values never printed.
cmd_diff() {
  [[ $# -ge 2 ]] || die "usage: $PROG diff <file-a> <file-b>" 2
  local a=$1 b=$2 k fa fb
  [[ -f $a ]] || die "no such file: $a" 2
  [[ -f $b ]] || die "no such file: $b" 2
  printf 'KEY\t%s\t%s\n' "$a" "$b"
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    if lookup "$a" "$k"; then fa=$(printf '%s' "$V" | fp); else fa='-'; fi
    if lookup "$b" "$k"; then fb=$(printf '%s' "$V" | fp); else fb='-'; fi
    if [[ $fb == - ]]; then
      printf '%s\t%s\t(missing)\n' "$k" "$fa"
    elif [[ $fa == "$fb" ]]; then
      printf '%s\t%s\tsame\n' "$k" "$fa"
    else
      printf '%s\t%s\t%s\n' "$k" "$fa" "$fb"
    fi
  done < <(cmd_names "$a")
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    lookup "$a" "$k" && continue
    lookup "$b" "$k"
    printf '%s\t(missing)\t%s\n' "$k" "$(printf '%s' "$V" | fp)"
  done < <(cmd_names "$b")
}

# Scan files for plaintext credentials: location, name, length, fingerprint.
# Exit 1 when anything was found, so it can gate a commit.
cmd_scan() {
  [[ $# -ge 1 ]] || die "usage: $PROG scan <path...>" 2
  local hits=0 target f ln line k v

  scan_file() {
    local file=$1 line k v ln=0
    [[ -f $file ]] || return 0
    case $file in
      *.png | *.jpg | *.jpeg | *.gif | *.webp | *.zip | *.gz | *.pdf | \
        *.woff | *.woff2 | *.ttf | *.ico | *-lock.json | *.lock) return 0 ;;
    esac
    while IFS= read -r line || [[ -n $line ]]; do
      ln=$((ln + 1))
      if [[ $line == *'-BEGIN'*'PRIVATE KEY-----'* ]]; then
        printf 'PRIVATE KEY   %s:%s\n' "$file" "$ln"
        hits=$((hits + 1))
        continue
      fi
      # Accept NAME=value, NAME = value, "NAME": "value", const NAME = "..."
      # so secrets in source files are caught, not only .env lines.
      local re='^[[:space:]]*((export|const|let|var|public|private|static|readonly)[[:space:]]+)*["'"'"']?([A-Za-z_][A-Za-z0-9_]*)["'"'"']?[[:space:]]*[:=][[:space:]]*(.+)$'
      if [[ $line =~ $re ]]; then
        k=${BASH_REMATCH[3]}
        v=${BASH_REMATCH[4]}
      else
        continue
      fi
      case $k in
        '' | *[!A-Za-z0-9_]*) continue ;;
      esac
      # bash 3.2 has no ${k^^}: uppercase through tr instead
      local up
      up=$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')
      case $up in
        *API_KEY* | *APIKEY* | *SECRET* | *TOKEN* | *PASSW* | *PRIVATE* | \
          *CREDENTIAL* | *ACCESS_KEY* | *SECRET_KEY* | *DSN*) ;;
        *) continue ;;
      esac
      v=$(unquote "$v")
      v=${v#"${v%%[![:space:]]*}"}
      v=${v%"${v##*[![:space:]]}"}
      # drop trailing punctuation from source literals: "abc";  'abc',
      v=${v%;}
      v=${v%,}
      v=$(unquote "$v")
      [[ ${#v} -ge 16 ]] || continue
      # a reference, not a literal: $VAR, ${VAR}, process.env.X
      case $v in
        '$'* | '${'* | *process.env*) continue ;;
      esac
      local low
      low=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
      case $low in
        *your_* | *changeme* | *example.com* | *'< '* | *'...'* | *placeholder* | *xxxx*)
          continue ;;
      esac
      printf 'PLAINTEXT     %s:%s  %s  len=%s fp=%s\n' \
        "$file" "$ln" "$k" "${#v}" "$(printf '%s' "$v" | fp)"
      hits=$((hits + 1))
    done <"$file"
    return 0
  }

  for target in "$@"; do
    if [[ -d $target ]]; then
      while IFS= read -r -d '' f; do
        scan_file "$f"
      done < <(find "$target" -type f -not -path '*/.git/*' \
        -not -path '*/node_modules/*' -size -1024k -print0 2>/dev/null)
    else
      scan_file "$target"
    fi
  done

  [[ $hits -eq 0 ]] || exit 1
  return 0
}

# Mask value-shaped tokens on stdin.
cmd_redact() {
  sed -E \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----)[A-Za-z0-9+\/=]*/\1<REDACTED>/g' \
    -e 's/((sk|pk|rk|ghp|gho|ghs|ghu|github_pat|xox[baprs]|AKIA|ASIA|shpat|glpat)[-_])[A-Za-z0-9_-]{10,}/\1<REDACTED>/g' \
    -e 's/[A-Za-z0-9_\-]{32,}/<REDACTED>/g'
}

usage() {
  cat >&2 <<EOF
$PROG — read .env files without printing secrets

  names <file>              list key NAMES only
  has   <file> <KEY>        exit 0 if present
  len   <file> <KEY>        value LENGTH
  fp    <file> <KEY>        value FINGERPRINT (sha256, $FP_LEN chars)
  run   <file> -- <cmd...>  export vars into a child process and run it
  diff  <file-a> <file-b>   compare two files per key, by fingerprint
  scan  <path...>           find plaintext secrets; location + fp only
  redact                    filter stdin, masking value-shaped tokens

Never prints a value. That is the point.
EOF
  exit 2
}

cmd=${1:-}
[[ $# -gt 0 ]] && shift
case $cmd in
  names) cmd_names "$@" ;;
  has) cmd_has "$@" ;;
  len) cmd_len "$@" ;;
  fp) cmd_fp "$@" ;;
  run) cmd_run "$@" ;;
  diff) cmd_diff "$@" ;;
  scan) cmd_scan "$@" ;;
  redact) cmd_redact ;;
  help | -h | --help) usage ;;
  *) usage ;;
esac
