# safe-env

A skill that lets an agent read and use `.env` files and pasted API keys
**without ever printing a secret**, and without lecturing about keys that are
deliberately temporary.

The problem it fixes is not "agents are too careful". It is that the standard
ways of inspecting a credential — `cat .env`, `echo $KEY`, `grep API_KEY` — all
publish the value into a transcript that is retained, summarised and sometimes
bundled for support. And once a value is in there, no amount of later care
removes it.

## What it actually does

`scripts/env-safe.sh` is the whole implementation. Every subcommand returns a
name, a length, a fingerprint or an exit code — never a value.

| Command | Answer |
|---|---|
| `names <file>` | which keys exist |
| `has <file> <KEY>` | exit 0 if present |
| `len <file> <KEY>` | value length in bytes |
| `fp <file> <KEY>` | sha256 fingerprint, 12 chars |
| `run <file> -- <cmd>` | export into a child process and run it |
| `diff <file-a> <file-b>` | per-key compare, by fingerprint |
| `scan <path...>` | find plaintext secrets; location + fp only |
| `redact` | mask key-shaped tokens on stdin |

```console
$ env-safe.sh names .env
OPENAI_API_KEY
DATABASE_URL
STRIPE_SECRET_KEY

$ env-safe.sh fp .env STRIPE_SECRET_KEY
4ceb8eb5448c

$ env-safe.sh scan .
PLAINTEXT     ./config.ts:3  STRIPE_SECRET_KEY  len=32 fp=c1b757ac5107
URL PASSWORD  ./.env:2       DATABASE_URL       len=44 fp=6ecec80f0ccd
PRIVATE KEY   ./id_rsa:1
```

`scan` exits 1 when it finds anything, so it works as a pre-commit gate. It
understands `NAME=value`, `NAME = value`, `"name": "value"` and
`const NAME = "..."`, skips obvious placeholders (`your_key_here`, `changeme`,
`< ... >`), and ignores `.git`, `node_modules` and binaries.

Two findings deserve their own names, because they are the ones a naive scan
misses: `PRIVATE KEY` (a PEM block, matched only at the start of a line, so a
regex that mentions the header is not flagged) and `URL PASSWORD` — credentials
embedded in a connection string, caught by value shape regardless of the
variable's name. `DATABASE_URL` holding `postgres://app:secret@host/db` is
reported even though nothing about that name looks secret-shaped.

## Install

The skill is a single directory. Clone it where your agent looks for skills:

```bash
git clone https://github.com/svliantiss/safe-env-skill.git ~/.agents/skills/safe-env
chmod +x ~/.agents/skills/safe-env/scripts/env-safe.sh
```

For a harness that reads `AGENTS.md`, the enforcement half of the skill is worth
copying there too — a skill is chosen on demand, an `AGENTS.md` rule is always
on. The rules section of `SKILL.md` is written to be paste-able for that.

Requires only `bash` and `shasum` (or `sha256sum`). Tested on macOS bash 3.2 —
no bash 4 features. `scripts/selftest.sh` runs 32 assertions, including one that
proves no subcommand ever writes a value to stdout.

## Gate your commits

`scan` exits non-zero on a finding, so it drops into any repo's pre-commit hook:

```bash
cat > .git/hooks/pre-commit <<'EOF'
#!/bin/sh
S="$HOME/.agents/skills/safe-env/scripts/env-safe.sh"
[ -x "$S" ] || exit 0
"$S" scan . || {
  printf 'pre-commit: plaintext secrets found (above). Fix, or --no-verify to skip.\n' >&2
  exit 1
}
EOF
chmod +x .git/hooks/pre-commit
```

It prints file, line, key name, length and fingerprint — never a value — so the
hook output is safe in CI logs and screenshots.

## The two halves

1. **Technical** — the helper, so a value never has to be printed to be used.
2. **Behavioural** — an explicit policy: a pasted key is deliberate, use it,
   don't add a safety footer, don't re-raise a settled concern. One narrow
   carve-out remains: a key hardcoded in a repo that actually gets pushed, or a
   production key going somewhere public.

Half the value is the second part. An agent that reads `.env` safely but then
writes three paragraphs about credential hygiene has still cost you the turn.

## License

MIT
