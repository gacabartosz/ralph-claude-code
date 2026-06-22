# OpenCode provider

Ralph can drive the **OpenCode CLI** (`opencode run`) instead of Claude Code, via
the multi-provider adapter seam.

> **Status:** the adapter (`lib/agents/opencode.sh`) implements command
> construction, JSONL event normalization, and a capability record, and is wired
> into the loop's analyzer. Exit detection works via the provider-independent
> `RALPH_STATUS` block.

## Requirements

- The OpenCode CLI on your `PATH` (or set `OPENCODE_CMD`, e.g. `OPENCODE_CMD="npx opencode-ai"`).
- `jq` (already a Ralph dependency).

## Enabling

Select the provider (precedence: env > `--provider` > `.ralphrc`):

```bash
ralph --provider opencode          # one-off
AGENT_PROVIDER=opencode ralph        # environment (highest precedence)
AGENT_PROVIDER="opencode"            # .ralphrc (lowest precedence)
```

`ralph --help` lists registered providers; an unknown provider exits with guidance.

## Command shape

```
opencode run --format json [-m <provider/model>] [-s <session-id>] <prompt>
```

- `--format json` — OpenCode emits a JSONL event stream (one JSON object per line).
  Omitted when `CLAUDE_OUTPUT_FORMAT=text`.
- `-m <provider/model>` — from the shared `CLAUDE_MODEL` knob (OpenCode expects the
  `provider/model` form, e.g. `anthropic/claude-sonnet-4-6`; empty = OpenCode default).
- `-s <session-id>` — added when session continuity is on (`CLAUDE_USE_CONTINUE=true`,
  the default) and a prior session id exists; resumes that specific session.
- `<prompt>` — the prompt is passed **positionally** (OpenCode `run <message>`).
  OpenCode has no system-prompt flag, so Ralph's per-loop context is **prepended**
  to the prompt text.

> **Security:** OpenCode offers `--dangerously-skip-permissions`, but the adapter
> **never** emits it — Ralph relies on OpenCode's permission flow, matching the
> Claude/Codex/Gemini dangerous-flag rule.

## Output normalization

The adapter maps OpenCode's JSONL events to Ralph's internal analysis struct
(verify the exact event names against your installed OpenCode version):

| OpenCode JSONL event | Used for |
|---|---|
| `{"type":"session.updated","sessionID":"…"}` | session id (continuity) |
| `{"type":"message","role":"assistant","text":"…"}` | work summary; carries the `RALPH_STATUS` block |
| `{"type":"error","message":"…"}` | error count → stuck detection |
| `{"type":"session.idle","tokens":{…}}` | token usage |

Exit detection is driven by the `RALPH_STATUS` block your prompt instructs the agent
to emit (the same mechanism as Claude) — it is provider-independent.

## Capabilities & graceful degradation

| Capability | OpenCode | Effect when absent |
|---|---|---|
| `supports_token_usage` | ✅ | — |
| `supports_session_resume` | ✅ (`-s <id>`) | — |
| `supports_permission_denials` | ❌ | permission-denial circuit breaker (#101) disabled; OpenCode uses an auto-approve model |
| `supports_api_limit_detection` | ❌ | 5-hour API-limit detection (#100/#183) disabled |

Invocation-count rate limiting (`--calls`), the circuit breaker, exit detection and
session continuity all still function.

## Knobs

| Variable | Meaning |
|---|---|
| `AGENT_PROVIDER=opencode` | select the OpenCode adapter |
| `OPENCODE_CMD` | OpenCode binary/command (default `opencode`) |
| `CLAUDE_MODEL` | model passed via `-m` as `provider/model` (shared knob; empty = OpenCode default) |
| `CLAUDE_USE_CONTINUE` | session continuity (`-s <id>`); default `true` |

## Limitations

- OpenCode does not report files changed; Ralph's git-based change detection covers it.
- The JSONL event schema above is the assumed contract — confirm against your
  OpenCode version and adjust `lib/agents/opencode.sh` if event names differ.
