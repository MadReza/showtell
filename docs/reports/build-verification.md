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
- **Accessibility permission** so the bar hides on ⌘⌃⇧3/4. Without it, the bar is still excluded
  from captures.
- Picking a session from the menu (tested only by writing `settings.json`).

## Live tests with you, 11 Oct 2026

Four read-aloud tests through the real microphone, into this Claude session.

| Test | Result | Cause | Fix |
|---|---|---|---|
| Plain speech | "how well" → "Showtell" | the seeded alias `Showtell: show tell` forced the term onto similar words | no aliases in the seeded list; stricter boost (similarity and confidence 0.7, acoustic rescue off) |
| Your terms | all right; "Herdr" capitalised, "in" before Claude Code dropped | rescorer replaces the span "in Claude Code" | terms are restored to the case you wrote them; the dropped "in" remains |
| Two screenshots | first right, second 3 words late | FluidAudio regroups words per batch, so a word split across batches counted twice, and the lag guess overruled real timings | words counted from token boundaries; once speech past a shot is timed (always by the end), the timings decide |
| Talking through a shot | shot right; "header" → "herdr", "four zero four" → "04", "3:45 PM" → "345 p.m." | boost too eager; number formatting is the model's | stricter boost; numbers left as they are |

Checked on synthesized recordings with the new settings: "how well", "header", herdr, Showtell and
Claude Code all come out right.

## Since v0.1, 11 Oct 2026

| Change | Checked how | Result |
|---|---|---|
| Start/send on a tap of a lone modifier (left ⌥ by default) | your use | works once Accessibility is allowed |
| Session drop-down in the bar | your use | switches the destination mid-recording |
| Local signing identity (`scripts/make-signing-cert.sh`) | rebuilt several times after one grant | Accessibility kept across rebuilds |
| Settings window with shortcut recording | your use; window rendered and captured | shortcuts recorded, including plain Esc for cancel; recorder gives up after 2 s |
| Live permission status in Settings | stale entry from the ad-hoc build reproduced and cleared | status follows System Settings within a second |
| Insert at the cursor | `showtell-cli target cursor`, then a spoken sentence (via `say`) with a clipboard image into TextEdit | text and image pasted in place; transcript exact. TextEdit's own "convert to RTFD" prompt for a plain `.rtf` stopped the last piece, a TextEdit quirk |

Lesson from the cursor test: the paste goes to whichever app is in front. In one run TextEdit
didn't come forward and the paste landed in iTerm2, so scripted tests now check the front app first.
