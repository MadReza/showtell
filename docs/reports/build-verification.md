# Build verification, 10 Oct 2026

What was checked on this Mac (macOS 26.6, Apple M5, Swift 6.4 Command Line Tools, herdr 0.9.3,
Claude Code 2.1.296), and what still needs a person.

## Checked

| Check | How | Result |
|---|---|---|
| Core logic | `swift test`: message splitting, screenshot placement (timings, lag, edits, recogniser rewrites after an edit), vocabulary parsing, replacements, outbox order / blocked wait / moved pane / gone session / hold-back after a partial failure | 18 tests pass |
| Delivery from code | `showtell-cli send <pane> --submit "…" @blue.png "…" @red.png` into a scratch Claude pane | chips in order; Claude: "Blue, then red." |
| Speech | `Showtell --transcribe speech.wav herdr Showtell` on a synthesized recording | exact transcript; "herder" corrected to "herdr" by the boost; models load in ≈50 s on first run (download), seconds after |
| Whole app | `open build/Showtell.app`, pinned to a scratch pane; `showtell-cli toggle`, two images put on the clipboard, `showtell-cli toggle` | message `[Image #1] [Image #2]` submitted; Claude: "solid green … solid blue" |
| Race fixes | start → screenshot → cancel → start → screenshot → send, driven by `showtell-cli` within 3 s | only the second recording's screenshot delivered; Claude: "solid blue" |
| Packaging | `scripts/bundle.sh` | ad-hoc signed `.app` with microphone usage text, resources bundle copied |

Test scratch panes were closed, your clipboard restored and the test settings removed afterwards.

## Code review

A separate review pass found 10 bugs, all fixed: overlapping speech start/stop/cancel (now an actor
plus a per-recording generation), a cancelled recording's transcript leaking into the next, a crash
with no input device, audio stopping on headset changes (tap reinstalled), an undo crash in the bar,
edits lost during "Finishing…", send failures hidden behind a new recording, edit drift when the
recogniser rewrites words, the bar hiding for 20 s on file screenshots, and SIGPIPE from the socket.
Lower-risk items also fixed: speech state read across threads, screenshot names colliding within a
second, picking a session mid-recording, screenshot timing when inference lags, and pasting onto a
half-delivered message.

Note: with Command Line Tools only, `swift test` sometimes fails once with "plugin for module
'TestingMacros' not found"; running it again works.

## Needs your first run

- **Microphone permission** and a real dictation (the live AVAudioEngine path; the same recogniser
  path was tested with a file).
- **Accessibility permission** so the bar hides on ⌘⇧3/4/5. Without it, the bar is still excluded
  from captures.
- Picking a session from the menu (tested only by writing `settings.json`).
