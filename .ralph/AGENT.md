# Ralph Agent Configuration — ralph-claude-code

## What this project is
A Bash autonomous-loop runner for Claude Code, tested with **bats**. There is no compile step.

## Dependencies
- `bash`, `bats` (1.13+), `jq`, `git`, `gh` (read-only issue access), Claude Code CLI (`claude`).

## Test (this is the quality gate every loop)
```bash
npm test                       # = bats tests/unit/ tests/integration/  — MUST be 100% green
npm run test:unit              # unit only
bats tests/unit/test_<module>.bats   # the file(s) for the module you changed
```
There is NO `npm run build` and NO `npm start` for this repo — ignore those.

## How the loop runs (self-hosting)
- The `ralph` loop is executed from the GLOBAL install (`~/.ralph`, `~/.local/bin/ralph`), a separate
  copy from this repo. Editing `ralph_loop.sh` / `lib/*` here does NOT affect the running loop — but
  it WILL be validated by `npm test`, so keep tests green.
- NEVER run `./install.sh` / `./uninstall.sh` / `./setup.sh` or modify `~/.ralph` / `~/.local/bin`
  during a loop (would overwrite the live runner). See `.ralph/PROMPT.md` guardrails.

## Git
- Branch: `ralph/auto` only. Push: `git push fork ralph/auto` (fork = gacabartosz). Never push `origin`.
- Conventional commits; stage explicit paths (never `git add -A`).

## Notes
- Update this file when build/test process changes.
