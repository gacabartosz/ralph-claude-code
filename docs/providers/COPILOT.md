# Copilot provider (GitHub Copilot CLI) — text-only / degraded

Ralph can drive the **GitHub Copilot CLI** (`copilot`) instead of Claude Code, via
the multi-provider adapter seam. Copilot is the **degraded, text-only** provider:
it has **no structured (JSON) output**, so several Claude-specific features are
cleanly disabled. It is the proving ground for Ralph's graceful-degradation design
(#315) under the hardest case.

> **Status:** the adapter (`lib/agents/copilot.sh`) implements command construction,
> TEXT-mode normalization, and a (minimal) capability record, and is wired into the
> loop's analyzer. Exit detection works **entirely** via the provider-independent
> `RALPH_STATUS` block on the text-mode path (#224).

## Requirements

- The Copilot CLI on your `PATH` (or set `COPILOT_CMD`, e.g. `COPILOT_CMD="npx @github/copilot"`).
- `jq` (already a Ralph dependency).

## Enabling

Select the provider (precedence: env > `--provider` > `.ralphrc`):

```bash
ralph --provider copilot         # one-off
AGENT_PROVIDER=copilot ralph       # environment (highest precedence)
AGENT_PROVIDER="copilot"           # .ralphrc (lowest precedence)
```

`ralph --help` lists registered providers; an unknown provider exits with guidance.

## Command shape

```
copilot -s [--model <m>] [--resume <id>] [--allow-tool <t>]... [--deny-tool <t>]... -p <prompt>
```

- `-s` (`--silent`) — **always present.** Emits the agent response only (the cleanest
  output Copilot offers; there is no JSON mode).
- `--model <m>` — from the shared `CLAUDE_MODEL` knob. Omitted when empty.
- `--resume <id>` — added when session continuity is on (`CLAUDE_USE_CONTINUE=true`,
  the default) and a prior session id exists; resumes that specific session.
- `--allow-tool <t>` / `--deny-tool <t>` — granular per-tool permissions, one flag per
  tool, from `COPILOT_ALLOWED_TOOLS` / `COPILOT_DENIED_TOOLS` (comma- or space-separated).
- `-p <prompt>` — the prompt is passed via the `-p` flag. Copilot has no system-prompt
  flag, so Ralph's per-loop context is **prepended** to the prompt text.
- `CLAUDE_OUTPUT_FORMAT` is **ignored** — Copilot is text-only.

> **Security:** the adapter **never** emits `--allow-all` (Copilot's full approval
> bypass), even if a knob requests it — matching the no-`--yolo` /
> no-`--dangerously-*` stance of the other adapters. Grant exactly the tools Ralph
> needs with `COPILOT_ALLOWED_TOOLS` instead. With no tools allowed, a headless
> Copilot run is effectively read-only — expected for the degraded path.

## Output normalization (text-only)

Copilot has no structured output, so `agent_copilot_detect_format` **always returns
`text`**. That routes `analyze_response` down its RALPH_STATUS text-mode path (#224):
exit detection comes entirely from the `---RALPH_STATUS---` block your prompt instructs
the agent to emit. The text path also runs Ralph's natural-language completion
heuristics, but an explicit `EXIT_SIGNAL: true`/`false` in the block always takes
precedence.

`agent_copilot_normalize_response` parses the text into the same internal struct shape
the JSON adapters produce (summary = full text; status/exit_signal from the block;
no session/usage/error fields are available in text mode).

## Capabilities & graceful degradation

Copilot is the **most degraded** provider — only session resume is supported:

| Capability | Copilot | Effect when absent |
|---|---|---|
| `supports_session_resume` | ✅ (`--resume <id>`) | — |
| `supports_token_usage` | ❌ (no structured output) | `MAX_TOKENS_PER_HOUR` token limiting disabled |
| `supports_permission_denials` | ❌ (rich perms at build time, no parse-time signal) | permission-denial circuit breaker (#101) disabled |
| `supports_api_limit_detection` | ❌ | 5-hour API-limit detection (#100/#183) disabled |

Each disabled feature no-ops and logs a **one-time** warning (#315). Invocation-count
rate limiting (`--calls`), the circuit breaker (no-progress/error/output-decline),
exit detection via `RALPH_STATUS`, and session continuity all still function.

## Knobs

| Variable | Meaning |
|---|---|
| `AGENT_PROVIDER=copilot` | select the Copilot adapter |
| `COPILOT_CMD` | Copilot binary/command (default `copilot`) |
| `COPILOT_ALLOWED_TOOLS` | comma/space-separated tools → one `--allow-tool` each |
| `COPILOT_DENIED_TOOLS` | comma/space-separated tools → one `--deny-tool` each |
| `CLAUDE_MODEL` | model passed via `--model` (shared knob; empty = Copilot default) |
| `CLAUDE_USE_CONTINUE` | session continuity (`--resume <id>`); default `true` |

## Limitations

- **No structured output** — token-usage limiting, the permission-denial circuit
  breaker, and 5-hour API-limit detection are all disabled (graceful degradation).
- Copilot does not report files changed; Ralph's git-based change detection covers it.
- Headless autonomy requires `COPILOT_ALLOWED_TOOLS` (the adapter never grants
  `--allow-all`); without it Copilot cannot run tools.
- The text contract above is the assumed shape — confirm against your Copilot version
  and adjust `lib/agents/copilot.sh` if flags differ.
