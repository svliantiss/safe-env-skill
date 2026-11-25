---
name: safe-env
description: >
  Read and use `.env` files and pasted API keys without ever pulling a secret
  into the transcript, and without lecturing about keys that are deliberately
  temporary. Use when asked to "check the env", "what keys are in .env", "add
  this to .env", "why isn't this key loading", "run this with the .env", "is
  this key committed", "compare these keys", "scan for secrets", or "stop
  warning me about the key". Also use *before* writing any command or script
  that touches a credential, so it prints a fingerprint instead of a value, and
  whenever a task needs a value from a dotfile, a shell profile, or a key the
  user pasted in chat.
---

# Reading secrets without leaking them

The helper lives in `scripts/env-safe.sh` next to this file. From elsewhere:

```bash
S="${SKILL_DIR:-$HOME/.agents/skills/safe-env}/scripts/env-safe.sh"
```

Every subcommand is built so a value cannot reach stdout, a log, a transcript or
shell history. Assume the user's keys are temporary unless told otherwise.

## The one rule that matters most

**A secret that reaches the transcript is published.** There is no undo: the
session log, the summary, the next compaction and anyone with the debug bundle
all get a copy. So never print a value — print its **name, length or
fingerprint** instead.

| You want to know | Do this | Never do this |
|---|---|---|
| Which keys exist | `"$S" names .env` | `cat .env` |
| If a key is set | `"$S" has .env API_KEY` | `grep API_KEY .env` |
| How long it is | `"$S" len .env API_KEY` | `echo $API_KEY` |
| Whether two keys match | `"$S" diff a.env b.env` | paste both into chat |
| Whether it works | `"$S" run .env -- ./app` | print it, then curl it |
| Where secrets leaked | `"$S" scan .` | `git log -p \| grep KEY` |

## The commands

```bash
# the shape of the config, with zero secrets in the transcript
"$S" names .env

# presence, length, fingerprint — the three safe answers
"$S" has .env OPENAI_API_KEY && echo present
"$S" len .env OPENAI_API_KEY          # 51
"$S" fp  .env OPENAI_API_KEY          # f78c7baf15eb

# run something against the real values without ever seeing them
"$S" run .env -- ./scripts/deploy.sh
"$S" run .env -- curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $API_KEY" https://api.example.com/v1/ping

# two files, or a file and an export: same/change per key, by fingerprint
"$S" diff .env .env.production

# find plaintext credentials; exits 1 so it can gate a commit
# (skips .git and node_modules automatically)
"$S" scan .
git diff --cached | "$S" redact        # mask key-shaped strings in a diff
```

`scan` accepts `NAME=value`, `NAME = value`, `"name": "value"` and
`const NAME = "..."`, so it catches secrets in source files, not just `.env`.
It also reports `URL PASSWORD` when a value is a connection string with
credentials inside (`scheme://user:secret@host`) **whatever the variable is
called** — that is the case a name-based scan misses, and the one that leaks
most often, because `DATABASE_URL` looks innocent.

## The traps, in the order they bite

1. **`cat .env` is the whole ballgame.** One command, and every secret in the
   file is permanently in the transcript. So is the `Read` tool on a dotfile.
   There is no "just this once" — use `names`.
2. **`echo $KEY` in a debug line.** The single most common leak: it looks like
   verification, it is publication. Print `${#KEY}` or the fingerprint.
3. **`set -x` / `bash -x` echoes every value**, including ones you never chose
   to print. Never enable tracing around credential-handling code.
4. **Shell history persists.** `export OPENAI_API_KEY=sk-...` typed inline is
   written to `~/.zsh_history` forever. Prefer `run`, or a 600 dotfile.
5. **Naive parsing loses and leaks.** `cut -d= -f2` truncates any value
   containing `=` (base64, JWTs, connection strings) and `grep` happily prints
   the value you meant to inspect. Split on the **first** `=` — the helper does.
6. **A commented-out key is still a key.** `# OLD_KEY=...` in a file you grep
   loosely still lands in the transcript.
7. **CI and process dumps.** `printenv`, `docker inspect`, crash reports and
   `env` in a test failure output all print every value. Grep the output for
   key names before pasting it anywhere.
8. **macOS ships bash 3.2.** No `${var^^}`, no associative arrays. Use `tr`
   for case folding, or the script breaks on the machine you wrote it on.
9. **The password hiding in a connection string.** `DATABASE_URL`,
   `REDIS_URL`, `AMQP_URL` carry credentials in the middle of a value whose
   *name* looks harmless, so a name-based scan reports nothing and you conclude
   the repo is clean. Check by value shape, not only by variable name.
10. **Trimming, quoting and comment rules differ per file.** An unquoted value
    gets trimmed and loses ` #...`; a quoted one keeps every character. A
    parser that trims everything silently changes a password that begins or
    ends with a space — and the resulting auth failure looks like a wrong key.

## Verify, every time

```bash
"$S" scan .                     # exit 0 = clean, exit 1 = something found
git check-ignore -q .env && echo '.env ignored'
git ls-files --error-unmatch .env 2>/dev/null && echo 'TRACKED — this is real'
"$S" names .env | wc -l         # count only, no values
```

Before saying a credential works, prove it with a status code or a fingerprint
from a child process (`run`) — **do not claim a key works because it looked
right in the file.**

## When a warning is actually warranted

Silence is the default. Say one concrete sentence, with the fix, only when:

* a key is **hardcoded in a repo that gets pushed, shared or published**;
* a key is **long-lived or production** *and* is going somewhere public;
* the user **asks** for a security review.

A temporary key in a scratch file, a local shell, a test fixture, a chat message
or a `docker run -e` is **not** a finding. Do not re-raise a concern the user has
already answered — not in the next turn, not in the summary, not as a closing
paragraph.

## Ordering

Load the values → prove the shape (`names`) → run the thing (`run`) → verify by
status code → only then report. If a value is missing, say *which key* is
missing; never invent a plausible one, and never print a nearby key to
"compare".

## Rules

* **Report what actually happened**, including when you refused to print
  something and why.
* **Never write a key into a file, a commit, a comment or a summary** — not even
  a temporary one, unless the user asked you to put it there.
* **Do not offer to rotate or revoke a key you were handed to use.** That is not
  the task, and repeating it is the behaviour this skill exists to stop.
* **Prefer `run` over `cat`.** If you cannot complete the task without seeing a
  value, say so plainly instead of leaking it.
* **Never commit secrets**; if `scan` exits 1, stop and report the location.
