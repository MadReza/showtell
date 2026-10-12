# Showtell

Talk and take screenshots while you look at your app. Showtell puts your words and the
screenshots, in the order you took them, into the Claude Code session you opened (in
[herdr](https://github.com/herdrdev/herdr), tmux or a plain iTerm2 tab), or pastes them wherever
your cursor is. The terminal
never has to come forward.

Everything runs on your Mac: speech is FluidAudio's streaming Parakeet model, with your own
terms boosted.

## Use it

1. Click the menu-bar icon and pick where messages go:
   - a Claude session under **Open a session**. It stays open until you pick another.
   - or **Insert at the cursor**: the message is pasted into whatever app you are typing in,
     screenshots included, without pressing Enter.
2. Tap the **left ⌥** key on its own (change it in Settings). A bar appears at the top of the
   screen and starts listening.
3. Talk. Take screenshots with the normal **⌘⌃⇧4** (copy to clipboard). The bar steps out of
   the way while you capture, and each screenshot appears in the text as `[📷 n]` at the word
   you were saying. Copy text anywhere (**⌘C**, or an element with react-grab) and it appears as
   `[📋 n]` the same way; it is pasted exactly as copied. Untick **Screenshots** or **Copied
   text** in the bar, or press **⌃⌥I** / **⌃⌥T**, to stop adding them; the choice stays for the
   next messages. Copies from password managers and Showtell's own pastes are never added.
4. Click into the bar to fix words, or move and delete `[📷 n]` and `[📋 n]` markers. Click the destination
   name in the bar, or press **⌃⌥↑ / ⌃⌥↓**, to send this message to another session (or the
   cursor). Untick **Send** in the bar, or press **⌃⌥S**, to leave the message in Claude's input
   without pressing Enter. Both choices stay for the next message.
5. Tap **left ⌥** again. The message is pasted into the session (each screenshot becomes an
   `[Image #n]` chip) and sent. If Claude is busy, Claude Code queues it. If Claude is showing a
   dialog, Showtell waits.

**⌃⌥⌫** cancels a recording. Every shortcut can be changed in Settings.

### Say where it goes

Name a session at the start or the end of a message and that message goes there instead:

| At the start | At the end |
|---|---|
| “For the showtell session, …” | “… this should go to showtell” |
| “Showtell session: …” | “… send this to the showtell session” |
| “Send to showtell, …” | “… for the showtell session” |
| “At the cursor: …” | “… paste it at the cursor” |

Use the session's folder or title; close-sounding names count (“Chotel” finds showtell). The
phrase is taken out of the message. The session name in the bar pulses and shows a microphone as
soon as the phrase is heard, with what was heard beside it. Once the message is sent, that session
stays open for the next messages, like picking it in the menu (Settings → "Keep sending there
afterwards" off: that message only). A name in the middle of a sentence never switches, and a name that matches no
session or several changes nothing (the bar says why). A click or ⌃⌥↑/↓ overrides it. The
session menus and Settings → Say where it goes list the phrases; switch it off there.

### Tidy up text (optional)

Pick a model in Settings → **Tidy up text** and Showtell can fix punctuation, filler words ("um",
"you know"), numbers ("four zero four" → 404) and misheard words, keeping your own words:

- Press **⌃⌥C** while talking: listening stops and the tidied text appears in the bar. Press it
  again to see your original, edit if you like, then tap **left ⌥** to send.
- Or switch on **Tidy every message when I send it**.
- If a screenshot marker or one of your words goes missing, your original is kept and shown to
  you before anything is sent.

| Model | Download | Good | Less good |
|---|---|---|---|
| Apple Intelligence | none | no download, under a second | needs Apple Intelligence on (macOS 26) |
| Qwen 2.5 1.5B | 1.1 GB | fastest download and replies | rewords more freely, sometimes shortens |
| Qwen 3 4B Instruct | 2.5 GB | stays closest to your words while fixing the most | about 3 GB of memory while loaded, 1–2 s |

Picking a downloadable model downloads it (to `~/Library/Application Support/Showtell/models/`).
Everything runs on your Mac: Apple's on-device model, or llama.cpp inside Showtell. A loaded model
is freed after five minutes without use.

## Settings

Menu → **Settings…** (⌘,):

- **Shortcuts.** Start and send, cancel, Send or just paste, next and previous session,
  Screenshots on or off, Copied text on or off. Click one and press the new shortcut: a key with modifiers (⌃⌥Space, ⇧⌘K) or a
  single modifier tapped on its own (left ⌥, right ⌘). A plain Esc works for cancelling. Press
  nothing for 2 seconds to keep the old one.
- **Behaviour.** Whether the second press sends (presses Enter; the same as the bar's Send
  checkbox), whether screenshots and copied text are added while you talk (the bar's Screenshots
  and Copied text checkboxes), and whether the bar hides on
  ⌘⌃⇧3/4.
- **Permissions.** Microphone and Accessibility status, with a button to allow.
- **Your words.** One term per line, spelled the way it should appear. Aliases
  (`herdr: herder`) force the term onto similar-sounding words, so use them sparingly. The open
  session's repository can add terms in `.github/dictation.md` (inline code and the first words
  of list items, the same file VS Code and localvoxtral read).
- **Replacements.** `wrong => right` lines applied to the finished text.
- **Say where it goes.** Spoken destinations on or off, with the phrases.
- **Tidy up text.** The model, whether every message is tidied, and the tidy-up shortcut.

Files live in `~/Library/Application Support/Showtell/`: `settings.json`, `vocabulary.txt`,
`replacements.txt`, `shots/`, `models/`, `last-message.txt`, and `unsent-*.txt` for any message that could
not be delivered.

## Permissions

- **Microphone:** asked on the first recording.
- **Accessibility:** needed for single-modifier shortcuts, for hiding the bar on ⌘⌃⇧3/4, and for
  pasting at the cursor. Without it, use a chord shortcut; the bar is still kept out of
  screenshots.
- No Screen Recording permission: screenshots come from the clipboard.

If Accessibility is switched on but Settings says it isn't, the entry belongs to an older build:
remove it with − in System Settings and allow again. Builds signed with the local identity (below)
keep their permissions.

## Build

Requires macOS 14+, Swift 6 (Command Line Tools are enough), and herdr.

```sh
swift test                      # core tests
scripts/make-signing-cert.sh    # once: a local signing identity so permissions survive rebuilds
scripts/install.sh              # builds and installs /Applications/Showtell.app, then opens it
```

`scripts/bundle.sh` only builds `build/Showtell.app`. Turn on **Open at login** in Settings once
the app is in /Applications. `swift scripts/make-icon.swift` redraws `Resources/AppIcon.icns`.

The first launch downloads the speech models (about 700 MB).

Debug tools:

```sh
swift run showtell-cli sessions                                   # Claude sessions in herdr
swift run showtell-cli send <pane-id> --submit "look" @/tmp/a.png # deliver like the app does
swift run showtell-cli toggle | cancel | tidy | settings          # drive the running app
swift run showtell-cli submit | next | previous                   # the Send checkbox, the session shortcuts
swift run showtell-cli target cursor | <pane-id>                  # change where it sends
.build/release/Showtell --transcribe speech.wav herdr Showtell    # speech self-test on a file
.build/release/Showtell --tidy apple "so um the build fails" herdr # tidy-up self-test (apple, qwen2.5-1.5b, qwen3-4b)
/usr/bin/log stream --info --predicate 'subsystem == "dev.showtell"'  # what happened to each message
```

`open --env SHOWTELL_CAPTURE_BAR=1 -a Showtell` lets screenshots include the bar. The log shows states and word counts (heard, tidied, pieces sent), never your words.

## How delivery works

**herdr:** Showtell talks to herdr's socket (`~/.config/herdr/herdr.sock`). Each text part and each
screenshot path is sent with `pane.send_input`, which herdr turns into a bracketed paste, so
Claude Code attaches the image. It pauses about 0.8 s after each image, then presses Enter with
`pane.send_keys`. Before every message it finds the session again by its Claude session id, so a
pane that moved still gets it.

**tmux and iTerm2:** sessions are found from `~/.claude/sessions/<pid>.json` (session id, cwd,
name, status) and the process's terminal, matched against tmux's panes and iTerm2's sessions. tmux
gets `paste-buffer -p` per piece and `send-keys Enter`; iTerm2 gets AppleScript `write text` with
paste markers, then a carriage return. A session waiting on a dialog (status `waiting`) is not
pasted into. macOS asks once for permission to control iTerm2. A session that is in herdr is
always reached through herdr.

**At the cursor:** each part goes through the clipboard and a synthesized ⌘V, in order; your
clipboard is put back afterwards.

## Known limits

- The streaming recogniser with word boosting lags about 2 s behind your voice.
- A boosted multi-word term can swallow the word before it ("in Claude Code" → "Claude Code").
- Numbers come out as the model writes them ("four zero four" → "04").
- Sessions in other terminals (Terminal.app, Ghostty, Warp…) aren't reachable yet: use insert at
  the cursor there.

## Docs

- [Spec](docs/spec.md) and [plan](docs/plan.md)
- Reports: [delivery tests](docs/reports/delivery-tests.md), [study of existing tools](docs/reports/study.md),
  [build verification and live tests](docs/reports/build-verification.md)
- Illustrated research: open [docs/research/index.html](docs/research/index.html) in a browser

## License

MIT. See [LICENSE](LICENSE).
