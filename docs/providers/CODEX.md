# Codex provider (pilot)

Ralph can drive the OpenAI **Codex CLI** (`codex exec`) instead of Claude Code, via
the multi-provider adapter seam. Codex is the pilot non-Claude provider — the
reference for adding Gemini, OpenCode, Droid, Kilocode and Copilot adapters.

> **Status:** pilot. The adapter (`lib/agents/codex.sh`) implements command
> construction, JSONL output normalization and a capability record, and is wired
> into the loop's analyzer. Exit detection works via the provider-independent
> `RALPH_STATUS` block.

## Requirements

- The Codex CLI on your `PATH` (or set `CODEX_CMD`, e.g. `CODEX_CMD="npx @openai/codex"`).
- `jq` (already a Ralph dependency).

## Enabling

Select the provider with any of these (precedence: env > `--provider` > `.ralphrc`):

```bash
# one-off run
ralph --provider codex

# environment (highest precedence)
AGENT_PROVIDER=codex ralph

# .ralphrc (lowest precedence)
AGENT_PROVIDER="codex"
```

`ralph --help` lists registered providers; an unknown provider exits with guidance.

## Command shape

The adapter builds:

```
codex exec [resume <session-id>] --json [-m <model>] <prompt>
```

- `--json` — Codex emits a JSONL event stream (one JSON object per line).
- `resume <id>` — added when session continuity is on (`CLAUDE_USE_CONTINUE=true`,
  the default) and a prior session id exists.
- `-m <model>` — from the shared `CLAUDE_MODEL` knob (leave empty for the Codex default).
- `<prompt>` — the prompt file contents. Codex `exec` has no system-prompt flag, so
  Ralph's per-loop context is **prepended** to the prompt text.

The adapter never emits `--dangerously-bypass-approvals-and-sandbox`; approvals stay
at Codex defaults (mirrors the Claude adapter's no-`--dangerously-skip-permissions`
rule).

## Output normalization

`codex exec --json` produces JSONL events. The adapter maps a documented subset to
Ralph's internal analysis struct (verify exact event names against your installed
Codex version):

| Codex JSONL event | Used for |
|---|---|
| `{"type":"session","session_id":"…"}` | session id (continuity) |
| `{"type":"assistant","text":"…"}` | work summary; carries the `RALPH_STATUS` block |
| `{"type":"tool",…}` | tool/command activity |
| `{"type":"error","message":"…"}` | error count → stuck detection |
| `{"type":"result","usage":{…}}` | end-of-turn token usage |

Exit detection is driven by the `RALPH_STATUS` block your prompt instructs the agent
to emit (the same mechanism as Claude) — it is provider-independent.

## Capabilities & graceful degradation

Codex declares a subset of Ralph's capabilities; unsupported features no-op with a
one-time warning rather than misbehaving (see the capabilities matrix, #315):

| Capability | Codex | Effect when absent |
|---|---|---|
| `supports_token_usage` | ✅ | — |
| `supports_session_resume` | ✅ | — |
| `supports_permission_denials` | ❌ | permission-denial circuit breaker (#101) disabled; Codex maps permissions to sandbox/approval |
| `supports_api_limit_detection` | ❌ | 5-hour API-limit detection (#100/#183) disabled |

Invocation-count rate limiting (`--calls`), the circuit breaker, exit detection and
session continuity all still function.

## Knobs

| Variable | Meaning |
|---|---|
| `AGENT_PROVIDER=codex` | select the Codex adapter |
| `CODEX_CMD` | Codex binary/command (default `codex`) |
| `CLAUDE_MODEL` | model passed via `-m` (shared knob; empty = Codex default) |
| `CLAUDE_USE_CONTINUE` | session continuity (`resume <id>`); default `true` |

## Limitations (pilot)

- Codex does not report files changed; Ralph's git-based change detection covers it.
- The JSONL event schema above is the assumed pilot contract — confirm against your
  Codex version and adjust `lib/agents/codex.sh` if event names differ.
