# Showtell spec

Status: v0.1, built 10 Oct 2026. Research behind it: [docs/research/index.html](research/index.html).

## Goal

While looking at an app or website, you talk and take screenshots. Your narration and the
screenshots, in the order you took them, reach **one Claude Code session you opened**, without
you switching to the terminal.

Scope for now: **Claude Code, local only, herdr.** Later, that one session may orchestrate other
sessions; Showtell's job is to get many inputs into it reliably.

## The interaction

1. **Open a session.** Pick a Claude Code session running in a herdr pane from the menu-bar menu.
   It stays open (pinned) until you pick another. It is not chosen by focus and not by which agent
   needs attention.
2. **Start.** Press the hotkey (default ⌃⌥Space). A bar pops up at the top of the screen and
   starts listening.
3. **Talk and show.** Words appear in the bar as you speak. Take screenshots with the native
   shortcuts that copy to the clipboard (⌘⌃⇧3/4). The bar becomes invisible while you capture,
   then each screenshot appears as a `[📷 n]` marker where you were speaking, with a thumbnail.
4. **Fix.** Between the two presses you can click into the bar and edit the text, or move and
   delete markers.
5. **Send.** Press the hotkey again. The message is delivered and submitted. You can start the
   next message right away; messages are delivered in order.
6. **Cancel.** ⌃⌥⌫ throws the recording away.

## Requirements

| Area | Requirement |
|---|---|
| Speech | Local, streaming, English. Custom terms boosted. First-run model download is acceptable. |
| Terms | User list (`term: alias, alias`), the pinned repo's `.github/dictation.md`, and `wrong => right` replacements on the finished text. |
| Screenshots | Taken with macOS's own shortcuts to the clipboard. Saved as numbered PNGs. Placed at the word being spoken when taken. |
| Bar | Never steals focus until clicked, never appears in screenshots or recordings, hides on ⌘⇧3/4/5 and reappears when the shot arrives (or after 20 s / Esc). |
| Delivery | Into the pinned herdr pane without focusing it. Each screenshot arrives as an `[Image #n]` attachment, in order. Works while Claude is busy (Claude Code queues it). Never pastes while Claude shows a dialog: waits instead. |
| Robustness | The pin follows the Claude session id if the pane moves. If the session is gone, say so and keep the text (`last-message.txt`). |
| Controls | Hotkey and "second press sends" are settings now; fuller customization of the controls later. |

## Behaviour details

**Placement.** The recogniser trails the voice by about 2 s and rewrites recent words. A screenshot
taken at audio time *t* goes after the words the transcript held at *t* + lag (or after the words
timed before *t* when word timings are available, whichever is later). Placement is recomputed on
every update until the user edits; an edit freezes everything shown, and later speech continues
after it.

**Delivery** (verified against Claude Code 2.1.296 and herdr 0.9.3):
1. Find the session again by Claude session id in `agent.list` (then terminal id).
2. If its status is `blocked`, wait (poll every 0.5 s, give up after 10 min).
3. For each piece: text → `pane.send_input {text}` (herdr makes it a bracketed paste);
   screenshot → the same with the file path, then wait 0.8 s so Claude Code attaches it.
4. Wait 0.35 s, check again for a dialog, then `pane.send_keys ["enter"]`.

**Files** in `~/Library/Application Support/Showtell/`: `settings.json`, `vocabulary.txt`,
`replacements.txt`, `shots/<recording>-NN.png`, `last-message.txt`.

## Permissions

- Microphone: asked on the first recording.
- Accessibility: optional, only to notice ⌘⇧3/4/5 and hide the bar. Without it the bar is still
  excluded from captures (`NSWindow.sharingType = .none`).
- No Screen Recording permission: screenshots come from the clipboard.

## Not in v0.1

- iTerm2 plain tabs, tmux, other terminals (delivery rules for them are known, see
  [reports/delivery-tests.md](reports/delivery-tests.md)).
- Faster preview to hide the 2 s lag.
- Region capture by Showtell itself, OCR terms from screenshots.
- Settings UI beyond the menu and `settings.json`.
