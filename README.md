# Showtell

Talk and take screenshots while you look at your app. Showtell puts your words and the
screenshots, in the order you took them, into the Claude Code session you opened in
[herdr](https://github.com/herdrdev/herdr). The terminal never has to come forward.

Everything runs on your Mac: speech is FluidAudio's streaming Parakeet model, with your own
terms boosted.

## Use it

1. Click the menu-bar icon and pick a Claude session under **Open a session**. It stays open
   until you pick another.
2. Press **⌃⌥Space**. A bar appears at the top of the screen and starts listening.
3. Talk. Take screenshots with the normal **⌘⌃⇧4** (copy to clipboard). The bar steps out of
   the way while you capture, and each screenshot appears in the text as `[📷 n]` at the word
   you were saying.
4. Click into the bar to fix words, or move and delete `[📷 n]` markers.
5. Press **⌃⌥Space** again. The message is pasted into the session (each screenshot becomes an
   `[Image #n]` chip) and sent. If Claude is busy, Claude Code queues it. If Claude is showing a
   dialog, Showtell waits.

**⌃⌥⌫** cancels a recording. Turn off **Second press sends** in the menu to have the message
pasted without Enter.

## Your words

- **Edit your words…** (menu): one term per line, optionally `term: misheard, other misheard`.
- The open session's repository can add terms in `.github/dictation.md` (inline `code` and the
  first words of list items, the same file VS Code and localvoxtral read).
- **Edit replacements…**: `wrong => right` lines applied to the finished text.

Files live in `~/Library/Application Support/Showtell/` (settings, terms, screenshots,
`last-message.txt` if a delivery fails).

## Build

Requires macOS 14+, Swift 6 (Command Line Tools are enough), and herdr.

```sh
swift test                  # core tests
scripts/bundle.sh           # builds build/Showtell.app (release)
open build/Showtell.app
```

The first launch downloads the speech models (about 700 MB). macOS asks for microphone access on
the first recording, and for Accessibility so the bar can notice ⌘⇧3/4/5 and hide; without it
the bar is still kept out of screenshots.

Debug tools:

```sh
swift run showtell-cli sessions                                  # Claude sessions in herdr
swift run showtell-cli send <pane-id> --submit "look" @/tmp/a.png  # deliver like the app does
.build/debug/Showtell --transcribe speech.wav herdr Showtell       # speech self-test on a file
```

## How delivery works

Showtell talks to herdr's socket (`~/.config/herdr/herdr.sock`). Each text part and each
screenshot path is sent with `pane.send_input`, which herdr turns into a bracketed paste, so
Claude Code attaches the image. It pauses about 0.8 s after each image, then presses Enter with
`pane.send_keys`. Before every message it finds the session again by its Claude session id, so a
pane that moved still gets it.

## Known limits

- The streaming recogniser with word boosting lags about 2 s behind your voice.
- herdr only, for now.
