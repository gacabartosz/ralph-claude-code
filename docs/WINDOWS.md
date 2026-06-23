# Windows support — compatibility status (Issue #156)

Ralph is a bash + bats tool. This page records the **WSL / Git-Bash compatibility
audit** and what remains for first-class native Windows support.

## TL;DR

| Environment | Status | Notes |
|---|---|---|
| **WSL2** (Ubuntu/etc.) | ✅ Supported | A real Linux userland — Ralph runs as on Linux, including `--monitor` (tmux). Recommended Windows path today. |
| **Git-Bash / MSYS2 / Cygwin** | ⚠️ Mostly works | bash + GNU coreutils, so the core loop, analyzer, circuit breaker, rate limiting, enable/setup all run. **`--monitor` does not** (no tmux on native Windows). |
| **Native PowerShell / CMD** | ❌ Not yet | Needs PowerShell/CMD wrappers + Windows Terminal monitoring — a Windows-host task (see Blocked below). |

## Platform detection (`lib/platform.sh`)

The audit added explicit OS/multiplexer detection (PR #86's "platform utilities"
component), so future Windows wrappers and the monitor can branch cleanly:

- `detect_os [uname]` → `linux` | `macos` | `windows` | `unknown`
  (`MINGW*`/`MSYS*`/`CYGWIN*` → `windows`).
- `platform_is_windows` / `platform_is_wsl` — distinguish Git-Bash-class Windows
  from a WSL Linux kernel (the `Microsoft` marker in `uname -r` / `/proc/version`).
- `detect_multiplexer` → `tmux` | `none`; `platform_has_tmux` — so a monitor can
  degrade gracefully where tmux is absent (native Windows).

These are unit-tested in `tests/unit/test_platform.bats` (the `uname` string is a
parameter, so detection is verified without a Windows host).

## Already cross-platform

Ralph deliberately uses **capability detection** rather than `uname` for the
BSD-vs-GNU differences that also matter on Windows toolchains:

- `lib/date_utils.sh` — ISO timestamps / epoch math with GNU+BSD fallbacks.
- `lib/timeout_utils.sh` — `timeout`/`gtimeout` detection.
- `lib/log_utils.sh` — `stat -c%s` (GNU) with `stat -f%z` (BSD) fallback.

Under Git-Bash/MSYS2 these resolve to the GNU variants, so they work.

## Blocked: native Windows support (needs a Windows host)

The following from #156 / PR #86 require developing **and testing on Windows** and
are out of scope for the bash/bats self-hosting loop — tracked as
`[BLOCKED: needs human]`:

- **PowerShell/CMD command wrappers** (`ralph.ps1` / `ralph.cmd`) mirroring the
  `~/.local/bin/ralph*` shims.
- **Windows Terminal split-pane monitoring** as a tmux alternative (`wt.exe`).
- **Windows-native installer** (`install.ps1`).
- **CI on GitHub Actions Windows runners** to keep the above green.

Until then, **WSL2 is the supported way to run Ralph on Windows**, and Git-Bash
works for everything except tmux monitoring.
