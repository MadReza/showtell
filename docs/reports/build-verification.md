# Build verification, 10 Oct 2026

What was checked on this Mac (macOS 26.6, Apple M5, Swift 6.4 Command Line Tools, herdr 0.9.3,
Claude Code 2.1.296), and what still needs a person.

## Checked

| Check | How | Result |
|---|---|---|
| Core logic | `swift test`: message splitting, screenshot placement (timings, lag, edits), vocabulary parsing, replacements, outbox order / blocked wait / moved pane / gone session | 15 tests pass |
| Delivery from code | `showtell-cli send <pane> --submit "…" @blue.png "…" @red.png` into a scratch Claude pane | chips in order; Claude: "Blue, then red." |
| Speech | `Showtell --transcribe speech.wav herdr Showtell` on a synthesized recording | exact transcript; "herder" corrected to "herdr" by the boost; models load in ≈50 s on first run (download), seconds after |
| Whole app | `open build/Showtell.app`, pinned to a scratch pane; `showtell-cli toggle`, two images put on the clipboard, `showtell-cli toggle` | message `[Image #1] [Image #2]` submitted; Claude: "solid green … solid blue" |
| Packaging | `scripts/bundle.sh` | ad-hoc signed `.app` with microphone usage text, resources bundle copied |

Test scratch panes were closed, your clipboard restored and the test settings removed afterwards.

## Needs your first run

- **Microphone permission** and a real dictation (the live AVAudioEngine path; the same recogniser
  path was tested with a file).
- **Accessibility permission** so the bar hides on ⌘⇧3/4/5. Without it, the bar is still excluded
  from captures.
- Picking a session from the menu (tested only by writing `settings.json`).
