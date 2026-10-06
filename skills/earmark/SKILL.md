---
name: earmark
description: >-
  Drive earmark, the local call recorder in the macOS menu bar, through its `earmark` CLI.
  Use when the user asks to record a call or meeting, start or stop a recording, check what
  earmark is doing, see which upcoming calendar events will be recorded automatically, find
  meeting recordings, read or search a call transcript, turn auto-recording on or off for a
  calendar, or change earmark settings.
---

# earmark

This file is a discovery stub, not the reference. The complete, version-matched command table
comes from the binary itself, so it can never drift from the CLI that will run your commands:

```sh
earmark help --json
```

Run it first and use only the commands and options it lists. Do not guess flags from memory.

## When to use

- "Record this call", "stop the recording", "is it recording?" — `earmark start`, `earmark stop`,
  `earmark status`.
- "What will be recorded today?" — `earmark upcoming`.
- "What did we agree on in yesterday's sync?" — `earmark recordings`, then `earmark transcript <id>`.
- "Record my Work calendar", "transcribe in Russian" — `earmark calendars …`, `earmark config set …`.

## Rules

- Start a recording only when the user explicitly asks for it in this conversation. Recording
  other people may require their consent; never start one on your own initiative.
- Never delete, move or edit anything in the recordings folder. earmark has no delete command
  on purpose.
- Take recording ids from `earmark recordings` output. Never guess or construct an id.
- A recording is complete only when its status is not `recording`; a transcript is ready only
  when the status is `transcribed`. Do not read `*.caf` or `*.partial.*` files.
- Transcripts and audio are private. Quote only what the task needs and never send them to
  another service or person without explicit permission.
- Read transcripts in pages: `earmark transcript <id> --words 200`, and follow `next_offset`
  only when you need more.
- If a command fails with `permission_denied` on the socket (EPERM inside a sandboxed agent such
  as Codex), do not retry or work around it: use the tools of the earmark MCP server
  (`earmark mcp`) instead.

## Output

Every command prints JSON: `{"schema_version":1,"command":…,"data":…}` on stdout, or
`{"schema_version":1,"error":{"code","message","exit_code"}}` on stderr with a non-zero exit code:
1 operation_failed, 2 not_found, 3 app_not_running, 4 permission_denied, 64 invalid_arguments,
65 bad_data, 69 unavailable (e.g. the model is not downloaded yet), 75 busy (retry later).
`earmark doctor` is special: its report always goes to stdout, and exit code 1 means "not ready".

## Common flows

```sh
earmark status                                    # state, current recording, warnings
earmark upcoming --hours 24                       # events that will be recorded
earmark recordings --status transcribed --since 2026-10-01
earmark transcript <id> --words 200               # then --offset <next_offset>
earmark config set transcription.language ru
```
