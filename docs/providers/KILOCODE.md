# Kilocode provider

Ralph can drive the **Kilocode CLI** (`kilocode --auto`) instead of Claude Code,
via the multi-provider adapter seam.

> **Status:** the adapter (`lib/agents/kilocode.sh`) implements command construction,
> `-j` (JSON) output normalization, and a capability record, and is wired into the
> loop's analyzer. Exit detection works via the provider-independent `RALPH_STATUS`
> block.

## Requirements

- The Kilocode CLI on your `PATH` (or set `KILOCODE_CMD`, e.g. `KILOCODE_CMD="npx kilocode"`).
- `jq` (already a Ralph dependency).

## Enabling

Select the provider (precedence: env > `--provider` > `.ralphrc`):

```bash
ralph --provider kilocode        # one-off
AGENT_PROVIDER=kilocode ralph      # environment (highest precedence)
AGENT_PROVIDER="kilocode"          # .ralphrc (lowest precedence)
```

`ralph --help` lists registered providers; an unknown provider exits with guidance.

## Command shape

```
kilocode --auto [-j] [-mo <model>] [-c] <prompt>
```

- `--auto` — **always present.** Headless (non-TUI) operation requires it; it also
  provides the headless approval autonomy Ralph needs.
- `-j` (`--json`) — structured single-object JSON output. Requires `--auto` (always
  satisfied). Omitted when `CLAUDE_OUTPUT_FORMAT=text`. (Kilocode also offers
  `-i/--json-io` for bidirectional streaming; Ralph uses the simpler `-j`.)
- `-mo <model>` — model override, from the shared `CLAUDE_MODEL` knob. Note Kilocode
  uses **`-mo`**, not `-m`. Omitted when `CLAUDE_MODEL` is empty.
- `-c` (`--continue`) — resume the **last** session. Added when session continuity is
  on (`CLAUDE_USE_CONTINUE=true`, the default) **and** a prior session id exists.
  See the continue-last caveat below.
- `<prompt>` — passed **positionally**. Kilocode has no system-prompt flag, so Ralph's
  per-loop context is **prepended** to the prompt text.

> **Security:** the adapter **never** emits `--yolo` (Kilocode's approval bypass).
> `--auto` already supplies the headless autonomy Ralph needs; `--yolo` would remove
> the remaining safety prompts, so it is intentionally withheld (cross-adapter
> security invariant, matching the no-`yolo` / no-`--dangerously-*` stance of the
> other adapters).

## Output normalization

The adapter maps Kilocode's `-j` JSON object to Ralph's internal analysis struct
(verify the exact shape against your installed Kilocode version):

| Kilocode JSON field | Used for |
|---|---|
| `.result` (or `.output`/`.text`/`.response`) | work summary; carries the `RALPH_STATUS` block |
| `.session_id` | session id (recorded; presence signals a resumable last session) |
| `.error` / `.errors` | error count → stuck detection |
| `.usage` | token usage |

Exit detection is driven by the `RALPH_STATUS` block your prompt instructs the agent
to emit (the same mechanism as Claude) — it is provider-independent.

## Capabilities & graceful degradation

| Capability | Kilocode | Effect when absent |
|---|---|---|
| `supports_token_usage` | ✅ | — |
| `supports_session_resume` | ⚠️ (`-c` continue-last only) | resume targets the last session, not a specific id (see caveat) |
| `supports_permission_denials` | ❌ | permission-denial circuit breaker (#101) disabled; Kilocode uses `--auto` approval |
| `supports_api_limit_detection` | ❌ | 5-hour API-limit detection (#100/#183) disabled |

Invocation-count rate limiting (`--calls`), the circuit breaker, exit detection and
session continuity all still function.

### Continue-last session caveat

Unlike adapters that resume a **specific** session by id (`--session-id`, `-s`),
Kilocode's `-c/--continue` only resumes the **most recent** session — there is no
session-id targeting. This is the weakest resume form among Ralph's providers:

- Ralph still records the session id from each response (for its own bookkeeping),
  but it cannot pass that id back to Kilocode; it can only ask Kilocode to "continue
  the last one".
- If another Kilocode session runs between Ralph loops in the same workspace,
  `-c` may continue the wrong conversation. For unattended Ralph runs this is rarely
  an issue (Ralph is the only driver), but keep it in mind when interleaving manual
  Kilocode use.

## Knobs

| Variable | Meaning |
|---|---|
| `AGENT_PROVIDER=kilocode` | select the Kilocode adapter |
| `KILOCODE_CMD` | Kilocode binary/command (default `kilocode`) |
| `CLAUDE_MODEL` | model passed via `-mo` (shared knob; empty = Kilocode default) |
| `CLAUDE_USE_CONTINUE` | session continuity (`-c` continue-last); default `true` |
| `CLAUDE_OUTPUT_FORMAT` | `json` → `-j`; `text` omits it |

## Limitations

- Continue-last sessions only (no session-id targeting) — see the caveat above.
- Kilocode does not report files changed; Ralph's git-based change detection covers it.
- The JSON object schema above is the assumed contract — confirm against your Kilocode
  version and adjust `lib/agents/kilocode.sh` if field names differ.
