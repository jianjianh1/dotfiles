---
name: loop
description: Repeat a prompt or set a one-time reminder in the current Codex CLI chat. Use when the user invokes $loop or asks Codex to check something again later in this open session.
---

# Loop in this Codex chat

Use `codex-loop` through a shell tool. It needs the `CODEX_THREAD_ID` that Codex supplies to shell commands. If the helper is missing, tell the user to run this dotfiles repo's installer. Do not start a separate Codex chat or a system cron job.

Interpret `$loop` arguments as follows:

| Request | Action |
| --- | --- |
| `$loop 5m check the deploy` | `codex-loop start --mode fixed --every 5m --prompt 'check the deploy'` |
| `$loop check the deploy` | `codex-loop start --mode adaptive --first 5m --prompt 'check the deploy'` (choose the first delay) |
| `$loop 15m` | `codex-loop start --mode fixed --every 15m` |
| `$loop` | `codex-loop start --mode adaptive --first 10m` (choose the first delay) |
| `$loop list` | `codex-loop list` |
| `$loop stop <id>` or `$loop stop all` | `codex-loop stop <id>` or `codex-loop stop all` |
| `$loop once in 45m remind me to push` | `codex-loop once --in 45m --prompt 'remind me to push'` |

Also accept an interval after the prompt, such as `check the deploy every 2 hours`. Convert it to a duration token (`2h`) before calling the helper. Supported units are seconds, minutes, hours, and days; seconds round up to a whole minute. Fixed intervals use the exact whole-minute cadence, including `7m` and `90m`. For an absolute reminder, resolve the user's local time to ISO 8601 with an explicit timezone offset and pass `--at` instead of `--in`. Ask only if the time is genuinely ambiguous.

For adaptive loops, choose an initial delay between `1m` and `1h` based on the current situation and pass it as `--first`. The helper defaults to `1m` when invoked directly without that option.

The helper prints the job ID and schedule. Show those to the user. Bare and interval-only loops reread project `.claude/loop.md`, then `~/.claude/loop.md`, at each run; if neither exists, they use a bounded maintenance prompt. Do not create a `loop.md` unless the user asks.

When an adaptive iteration arrives, finish the requested check, then call `codex-loop next <id> <delay> --reason '<short reason>'` with a delay from `1m` to `1h`. Choose a shorter delay while activity is ongoing and a longer one when nothing is pending. Tell the user the chosen delay and reason. If the task is complete, call `codex-loop stop <id>` instead. The helper gives one 20-minute fallback if you omit this step, then stops the loop after a second omission.

Scheduled prompts inherit the current thread's permissions. A bare maintenance loop may continue authorized work, but must not start unrelated work or take irreversible actions without prior authorization. To cancel a waiting loop, use `$loop stop`; `Esc` cannot cancel an idle scheduler timer.
