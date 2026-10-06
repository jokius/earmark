# earmark

**English** · [Русский](README.ru.md)

[![CI](https://github.com/jokius/earmark/actions/workflows/ci.yml/badge.svg)](https://github.com/jokius/earmark/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)

A macOS menu bar app that records your calls: your microphone and the other side (system
audio) go to separate channels. It starts on its own a minute before an event from the
calendars you pick, stops when the call app lets go of the microphone, files the recording into
that calendar's folder and transcribes it locally with whisper.cpp into a "Me / Them" dialogue.
Like [Anarlog](https://github.com/fastrepl/anarlog), without the frills: no AI summaries, no
cloud, no settings window — everything is driven by the `earmark` command line, by you or by
your coding agent.

## Features

- **Two channels.** Your microphone is the left channel, everyone else (system audio) is the
  right one. The result is a stereo AAC `audio.m4a`, 48 kHz, about 43 MB per hour.
- **Starts on its own** `lead_seconds` (60 s by default) before every event of the enabled
  calendars. All-day, cancelled and declined events are skipped. Mac woke up late? Recording still
  starts as long as the event is not over. Manual start from the menu, the CLI or an agent.
- **Stops on its own** when the call is over — the call app released the microphone — with
  safety nets: the event is over and both sides are quiet, long silence, a 5-hour cap.
- **Survives crashes.** While recording, audio goes to crash-safe LPCM CAF files. After a crash
  or a power loss the next launch muxes what was captured and marks it `recovered`. Quitting the
  app mid-recording works the same way: the next launch finishes the recording.
- **One folder per calendar**: `~/Earmark/<Calendar>/2026-10-02 14-00 Daily sync/`.
- **Local transcription** with whisper.cpp and large-v3-turbo (beam search, voice activity
  detection), in a separate process after the call.
- **CLI for everything** — settings, status, recordings, transcripts — with JSON output, plus a
  skill for Claude Code and an MCP server for Codex and other MCP clients.

## What it deliberately does not do

- No AI summaries or notes, no meeting reminders, no cloud and no sync.
- No settings window and no transcript editor: the menu bar icon and the CLI are all there is.
- No post-recording hooks: wait for `audio.m4a` or `transcript.json` to appear, or poll
  `earmark recordings --status transcribed`.
- No speaker diarization yet: everyone on the far end is "Them".
- No echo filtering yet: on speakers the far end's voice leaks into your microphone and shows up
  as "Me" too. Use headphones.
- No network access except the one-time download of the Whisper model from Hugging Face
  (`earmark model import` avoids even that).

## Requirements

- macOS 15 or later. Built for 15+, tested on macOS 27.
- Xcode 27 (Swift 6.4) and [xcodegen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`). Optionally [swiftlint](https://github.com/realm/SwiftLint) — without
  it the Xcode build only warns, but `make lint` and `make check` need it.
- About 2 GB of free space for the model.

## Build and install

```sh
make            # build
make test       # run the tests
make check      # format, lint and tests
make install    # release build into /Applications, CLI linked to ~/.local/bin/earmark
```

There is no `.xcodeproj` in the repository: it is generated from `project.yml` on every build.

### Code signing

By default the build is ad-hoc signed. It works, but macOS asks again for the microphone, system
audio and calendars after every rebuild: an ad-hoc signature gets a new cdhash, so the permission
you granted no longer matches. Hardened Runtime is on only in signed builds: under an ad-hoc
signature its library validation would refuse to load whisper.framework into the CLI.

To make permissions stick, put your team into `signing.local` (it is not tracked by git):

```make
CODE_SIGN_IDENTITY = Apple Development
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = <the certificate's OU field>
```

A generic identity rather than a certificate hash on purpose: Xcode picks the current
certificate itself, so an expiring or replaced one breaks nothing. The Team ID comes from the
certificate's `OU` field, not from the parentheses in its name — those are different values.

### First run

1. `make install` puts `Earmark.app` into `/Applications` and links the CLI to
   `~/.local/bin/earmark`. Make sure `~/.local/bin` is in your `PATH`. Start Earmark once from
   `/Applications`; it registers itself as a login item (`launch_at_login`).
2. Grant permissions: menu bar icon → **Grant Permissions…**, or `earmark permissions request`.
   macOS asks for the microphone, for full access to calendars and for system audio recording
   (System Settings → Privacy & Security → Screen & System Audio Recording → System Audio
   Recording Only).
3. Pick calendars — nothing is recorded until you do:

   ```sh
   earmark calendars                 # ids, titles, accounts
   earmark calendars enable <id>
   earmark upcoming                  # what will be recorded in the next 24 hours
   ```

4. Get the model (1.6 GB): `earmark model download`, or `earmark model import <path>` if you
   already have `ggml-large-v3-turbo.bin` (it is checked by SHA-256 and cloned, not copied, on APFS).
5. Check everything: `earmark doctor --audio-test`.
6. Optionally set the transcript language and speaker labels. Out of the box Whisper detects the
   language of every recording (`auto`) and the transcript says `Me` and `Them`. For calls in
   Russian, for example:

   ```sh
   earmark config set transcription.language ru
   earmark config set transcript.label_me "Я"
   earmark config set transcript.label_them "Собеседники"
   ```

Recordings go to `~/Earmark`, created with mode 0700. Change it with
`earmark config set recordings_dir <path>`. Desktop, Documents and Downloads are refused: macOS
guards them, and every script that reads your recordings would hit permission prompts.

## CLI

Every command prints JSON. Success goes to stdout as
`{"schema_version":1,"command":"…","data":…}`, pretty-printed when stdout is a terminal. Errors go
to stderr as `{"schema_version":1,"error":{"code":"…","message":"…","exit_code":N}}`.
`earmark help --json` prints the full machine-readable command table.

| Command | What it does |
|---|---|
| `earmark status` | State, current recording, next auto-recording, permissions, queue, warnings. Never launches the app: prints `"app_running": false` instead |
| `earmark start [--title T]` | Start a manual recording. Idempotent: returns the running recording if there is one |
| `earmark stop` | Stop and finalize; answers once `audio.m4a` is written |
| `earmark upcoming [--hours 24]` | Events that will be recorded |
| `earmark calendars` | Calendars with `enabled`, account and folder |
| `earmark calendars enable <id>`, `earmark calendars disable <id>` | Turn auto-recording on or off for a calendar |
| `earmark recordings [--since D] [--until D] [--calendar ID] [--status S] [--limit N]` | Recordings, newest first. `D` is `YYYY-MM-DD` in local time or ISO 8601 |
| `earmark recording <id>` | `meta.json` plus the absolute paths of the files that exist |
| `earmark transcript <id> [--offset N] [--words N] [--format txt\|json]` | Transcript in pages of 200 words (500 at most) with `next_offset`; `json` returns all segments at once |
| `earmark transcribe <id> [--force]` | Queue a recording for transcription in the app. `--force` redoes a transcribed or failed one |
| `earmark transcribe <id> --now [--force]` | Transcribe in this process — this is how the app runs its worker |
| `earmark model status`, `earmark model download`, `earmark model import <path>` | The Whisper model |
| `earmark config list`, `earmark config get <key>` | Settings, read from disk |
| `earmark config set <key> <value>`, `earmark config reset <key>`, `earmark config reset --all` | Change settings through the app: validated and applied at once |
| `earmark doctor [--audio-test]` | Check everything; exit code 1 if something is not ready |
| `earmark permissions request` | Ask the app to show the system permission prompts |
| `earmark mcp` | stdio MCP server |
| `earmark help [--json]` | The command table |

Commands that need the app — start, stop, upcoming, calendars, `config set` and `config reset`,
`transcribe` without `--now`, doctor and `permissions request` — launch it with
`open -g -b com.konayre.earmark` when it is not running and wait up to 5 seconds. Everything else
reads plain files and works without the app.

Exit codes: 0 ok · 1 operation_failed · 2 not_found · 3 app_not_running · 4 permission_denied ·
64 invalid_arguments · 65 bad_data · 69 unavailable · 75 busy.

## Configuration

`~/Library/Application Support/earmark/config.json` is written by the app only. Change settings
with `earmark config set`: the value is validated and applied immediately. Edits made by hand
while the app is running take effect only after a restart.

| Key | Type | Default | Notes |
|---|---|---|---|
| `auto_record` | bool | `true` | Master switch for auto-recording |
| `lead_seconds` | int 0…3600 | `60` | How early to start before an event |
| `recordings_dir` | path | `~/Earmark` | Must be writable; Desktop, Documents and Downloads are refused |
| `launch_at_login` | bool | `true` | Login item via `SMAppService` |
| `calendars` | list of ids | `[]` | Enabled calendars. The order is the priority when events overlap |
| `calendar.<id>.lead_seconds` | int | — | Per-calendar override of `lead_seconds` |
| `calendar.<id>.folder` | string | — | Folder name instead of the calendar title |
| `stop.call_end_seconds` | int | `60` | No call activity this long → stop (`call_ended`) |
| `stop.after_end_seconds` | int | `120` | Event ended this long ago and both channels are quiet → stop (`event_over`) |
| `stop.end_quiet_seconds` | int | `60` | How long both channels must stay quiet for `event_over` |
| `stop.silence_minutes` | int | `10` | Both channels quiet this long → stop (`silence`). Counts only once a call has been seen: silence before a late joiner does not stop the recording |
| `stop.join_grace_minutes` | int | `10` | No call by start + this → stop (`no_call`); restarts if the call shows up before the end |
| `stop.max_minutes` | int | `300` | Hard cap, manual recordings included |
| `stop.min_keep_seconds` | int | `45` | Shorter auto-recordings are deleted |
| `audio.keep_raw_tracks` | bool | `false` | Keep `mic.caf` and `system.caf` after muxing |
| `transcription.enabled` | bool | `true` | Transcribe after each recording |
| `transcription.language` | string | `auto` | Whisper language code (`en`, `ru`, …) or `auto` |
| `transcript.label_me` | string | `Me` | My label in `transcript.txt` |
| `transcript.label_them` | string | `Them` | Their label in `transcript.txt` |

`EARMARK_HOME` moves the support files — config, state, socket and models — to another
directory, which is handy for a development build. The app reads it too, so start it with the
same value: `open --env EARMARK_HOME="$EARMARK_HOME" -b com.konayre.earmark`. Keep the path
short: `$EARMARK_HOME/earmark.sock` must fit into 103 bytes, the macOS limit for a Unix socket
path, or the app will not open its socket.

## Agents

- **Claude Code** drives the CLI through a skill. `make install-skill` links `skills/earmark`
  into `~/.claude/skills` and, when it exists, into `~/.agents/skills`, the shared directory
  that Codex and other agents read (`~/.codex/skills` only when there is no shared one). The
  links point at the repository, so `git pull` updates the skill. Prefer a copy? From the
  repository root run
  `npx --yes skills add . --skill earmark --global --agent claude-code --agent codex --agent universal -y`.
  For headless runs allow the CLI in `settings.json`: `"Bash(earmark:*)"`.
- **Codex** blocks Unix sockets inside its shell sandbox, so it talks to earmark over MCP,
  which it starts outside the sandbox:

  ```sh
  codex mcp add earmark -- ~/.local/bin/earmark mcp
  ```

  `stop_recording` answers only once the audio is finalized, which takes minutes after a long
  call, and the server handles one call at a time. Codex gives an MCP tool 60 seconds by
  default, so raise the limit in `~/.codex/config.toml`, in the table `codex mcp add` created:

  ```toml
  [mcp_servers.earmark]
  tool_timeout_sec = 300
  ```

- **Any other MCP client**: run `earmark mcp` over stdio. It speaks both the `initialize`
  handshake and the `server/discover` flow of MCP 2026-07-28.

The skill and the MCP server's instructions tell agents to start a recording only when you ask
for it explicitly, never to delete recordings, to take ids from list output and to treat
transcripts as private.

## Privacy and consent

Recording other people may require their consent where you or they live. Check the rules that
apply to you before relying on auto-recording, and let the other participants know. earmark
stays visible: its menu bar icon changes while it records, and macOS shows its own microphone
indicator.

Everything stays on your Mac. Recordings live in `~/Earmark` (mode 0700) and are never uploaded;
transcription runs locally. The system audio channel captures everything your Mac plays except
earmark itself — notification sounds and music included.

## Troubleshooting

- Start with `earmark doctor`. `earmark doctor --audio-test` also plays a short 440 Hz tone and
  checks that the system audio channel hears it: without permission the channel records silence
  without any error, so this is the only reliable check.
- **The far end is silent**, or `far_end_digital_silence` shows up in `earmark status`: the
  system audio permission is missing or stale. Reset it and grant it again:

  ```sh
  tccutil reset AudioCapture com.konayre.earmark
  earmark permissions request
  ```

  The same works for `tccutil reset Microphone com.konayre.earmark` and
  `tccutil reset Calendar com.konayre.earmark`.
- **Permissions are asked again after every build**: the build is ad-hoc signed; set up
  `signing.local`.
- **`app_not_running`**: Earmark.app is not in `/Applications` or failed to start. Run
  `make install`, then `open -b com.konayre.earmark`.
- **`permission_denied` on the socket** inside a sandboxed agent such as Codex: use `earmark mcp`.
- **Logs**: `/usr/bin/log stream --predicate 'subsystem == "com.konayre.earmark"'` (the full path
  matters: in zsh a bare `log` is a shell builtin).
- **Uninstall**: first `tccutil reset All com.konayre.earmark` (tccutil finds the app through
  LaunchServices, so do it while the app is still installed), then `make uninstall`. Recordings
  in `~/Earmark` stay where they are.

## License

[MIT](LICENSE). Third-party code and models are listed with their licenses in [NOTICE](NOTICE).

Zoom, Microsoft Teams, Google Meet and the other apps mentioned are trademarks of their owners.
earmark only recognizes their processes and is not affiliated with them.
