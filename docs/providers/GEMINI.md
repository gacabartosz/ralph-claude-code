# Gemini provider

Ralph can drive the **Gemini CLI** instead of Claude Code, via the multi-provider
adapter seam. Gemini is closest to Claude's shape: structured output plus
**race-free pre-assigned sessions** (Ralph supplies the session id, so it never has
to parse it out of a race-prone stream).

> **Status:** the adapter (`lib/agents/gemini.sh`) implements command construction,
> `-o json` output normalization, and a capability record, and is wired into the
> loop's analyzer. Exit detection works via the provider-independent `RALPH_STATUS`
> block.

## Requirements

- The Gemini CLI on your `PATH` (or set `GEMINI_CMD`, e.g. `GEMINI_CMD="npx @google/gemini-cli"`).
- `jq` (already a Ralph dependency).

## Enabling

Select the provider (precedence: env > `--provider` > `.ralphrc`):

```bash
ralph --provider gemini          # one-off
AGENT_PROVIDER=gemini ralph        # environment (highest precedence)
AGENT_PROVIDER="gemini"            # .ralphrc (lowest precedence)
```

`ralph --help` lists registered providers; an unknown provider exits with guidance.

## Command shape

```
gemini -o json [-m <model>] [--approval-mode <mode>] [--session-id <id> -r] -p <prompt>
```

- `-o json` — structured output (single JSON object). Omitted when `CLAUDE_OUTPUT_FORMAT=text`.
- `-m <model>` — from the shared `CLAUDE_MODEL` knob (empty = Gemini default).
- `--approval-mode <mode>` — from `GEMINI_APPROVAL_MODE` (`default`, `auto_edit`, `plan`).
  The adapter **never** forwards `yolo` (auto-approves everything), even if set —
  mirroring the Claude/Codex dangerous-flag rule.
- `--session-id <id> -r` — added when session continuity is on
  (`CLAUDE_USE_CONTINUE=true`, the default) and a prior session id exists. Ralph
  supplies the id (race-free pre-assignment) and `-r` resumes it.
- `<prompt>` — the prompt file contents. Gemini has no system-prompt flag, so
  Ralph's per-loop context is **prepended** to the prompt text.

## Output normalization

The adapter maps Gemini's `-o json` object to Ralph's internal analysis struct
(verify the exact shape against your installed Gemini version):

| Gemini JSON field | Used for |
|---|---|
| `.response` | work summary; carries the `RALPH_STATUS` block |
| `.session_id` (or `.stats.session_id`) | session id (continuity) |
| `.error` / `.errors` | error count → stuck detection |
| `.stats.tokens` | token usage |

Exit detection is driven by the `RALPH_STATUS` block your prompt instructs the agent
to emit (the same mechanism as Claude) — it is provider-independent.

## Capabilities & graceful degradation

| Capability | Gemini | Effect when absent |
|---|---|---|
| `supports_token_usage` | ✅ | — |
| `supports_session_resume` | ✅ (pre-assigned, race-free) | — |
| `supports_permission_denials` | ❌ | permission-denial circuit breaker (#101) disabled; Gemini uses `--approval-mode` |
| `supports_api_limit_detection` | ❌ | 5-hour API-limit detection (#100/#183) disabled |

Invocation-count rate limiting (`--calls`), the circuit breaker, exit detection and
session continuity all still function.

## Knobs

| Variable | Meaning |
|---|---|
| `AGENT_PROVIDER=gemini` | select the Gemini adapter |
| `GEMINI_CMD` | Gemini binary/command (default `gemini`) |
| `GEMINI_APPROVAL_MODE` | `--approval-mode` value (`yolo` is refused) |
| `CLAUDE_MODEL` | model passed via `-m` (shared knob; empty = Gemini default) |
| `CLAUDE_USE_CONTINUE` | session continuity (`--session-id <id> -r`); default `true` |

## Limitations

- Gemini does not report files changed; Ralph's git-based change detection covers it.
- The JSON object schema above is the assumed contract — confirm against your Gemini
  version and adjust `lib/agents/gemini.sh` if field names differ.
