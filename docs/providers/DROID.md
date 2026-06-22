# Droid provider (Factory)

Ralph can drive the **Factory Droid CLI** (`droid exec`) instead of Claude Code,
via the multi-provider adapter seam.

> **Status:** the adapter (`lib/agents/droid.sh`) implements command construction,
> `-o json` output normalization, and a capability record, and is wired into the
> loop's analyzer. Exit detection works via the provider-independent `RALPH_STATUS`
> block.

## Requirements

- The Droid CLI on your `PATH` (or set `DROID_CMD`, e.g. `DROID_CMD="npx droid"`).
- `jq` (already a Ralph dependency).

## Enabling

Select the provider (precedence: env > `--provider` > `.ralphrc`):

```bash
ralph --provider droid          # one-off
AGENT_PROVIDER=droid ralph        # environment (highest precedence)
AGENT_PROVIDER="droid"            # .ralphrc (lowest precedence)
```

`ralph --help` lists registered providers; an unknown provider exits with guidance.

## Command shape

```
droid exec [-o json] [-m <model>] [--session-id <id>] [--auto <level>] <prompt>
```

- `-o json` — structured output (single JSON object). Omitted when `CLAUDE_OUTPUT_FORMAT=text`.
- `-m <model>` — from the shared `CLAUDE_MODEL` knob. When empty, the adapter omits
  `-m` so Droid uses its **default model, `claude-opus-4-8`**.
- `--session-id <id>` — added when session continuity is on (`CLAUDE_USE_CONTINUE=true`,
  the default) and a prior session id exists; resumes that specific session.
- `--auto <level>` — from `DROID_AUTO`, the approval autonomy level (optional).
- `<prompt>` — the prompt is passed **positionally** (`droid exec <prompt>`). Droid
  has no system-prompt flag, so Ralph's per-loop context is **prepended** to the
  prompt text.

## Output normalization

The adapter maps Droid's `-o json` object to Ralph's internal analysis struct
(verify the exact shape against your installed Droid version):

| Droid JSON field | Used for |
|---|---|
| `.result` (or `.output`/`.response`) | work summary; carries the `RALPH_STATUS` block |
| `.session_id` | session id (continuity) |
| `.error` / `.errors` | error count → stuck detection |
| `.usage` | token usage |

Exit detection is driven by the `RALPH_STATUS` block your prompt instructs the agent
to emit (the same mechanism as Claude) — it is provider-independent.

## Capabilities & graceful degradation

| Capability | Droid | Effect when absent |
|---|---|---|
| `supports_token_usage` | ✅ | — |
| `supports_session_resume` | ✅ (`--session-id`) | — |
| `supports_permission_denials` | ❌ | permission-denial circuit breaker (#101) disabled; Droid uses `--auto` approval levels |
| `supports_api_limit_detection` | ❌ | 5-hour API-limit detection (#100/#183) disabled |

Invocation-count rate limiting (`--calls`), the circuit breaker, exit detection and
session continuity all still function.

## Knobs

| Variable | Meaning |
|---|---|
| `AGENT_PROVIDER=droid` | select the Droid adapter |
| `DROID_CMD` | Droid binary/command (default `droid`) |
| `DROID_AUTO` | `--auto <level>` approval autonomy (optional) |
| `CLAUDE_MODEL` | model passed via `-m` (shared knob; empty = Droid default `claude-opus-4-8`) |
| `CLAUDE_USE_CONTINUE` | session continuity (`--session-id <id>`); default `true` |

## Limitations

- Droid does not report files changed; Ralph's git-based change detection covers it.
- The JSON object schema above is the assumed contract — confirm against your Droid
  version and adjust `lib/agents/droid.sh` if field names differ.
