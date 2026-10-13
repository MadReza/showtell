# Delivery tests: getting text and images into a running Claude Code session

Date: 10 Oct 2026. Claude Code 2.1.296 (Team account, bypass-permissions mode), herdr 0.9.3,
iTerm2, tmux. Every test used solid-colour PNGs (red, green, blue) in a throwaway session and asked
for the colours in order with no tools, so a correct answer proves Claude received the images,
not just the paths.

## Results

| Test | Images sent | Prompt box showed | Claude answered | Result |
|---|---|---|---|---|
| Paths inside the text, one paste | red, green, blue | plain path text | "can't tell without opening the files" | ✗ not attached |
| tmux: text, then each path pasted on its own (`paste-buffer -p`) | red, green, blue | `First: [Image #1] … [Image #2] … [Image #3]` | "Red, green, blue." | ✓ in order |
| herdr `pane send-text` (typed, no paste markers) | red, green | plain path text | n/a | ✗ |
| herdr `pane send-text` wrapped in `ESC[200~ … ESC[201~` | red, green | `[Image #1] … [Image #2]` | "red, green" | ✓ in order |
| iTerm2 plain tab, AppleScript `write text … newline no` with paste markers | green, blue | `[Image #1] … [Image #2]` | "Green, Blue" | ✓ in order |
| Everything in one burst, no pauses | blue, red | `A: B: …text…[Image #3] [Image #4]` | n/a | ◐ images jump to the end |
| Session inbox socket, text | none | "Held message" approval dialog | "PONG" after approving | ◐ needs approval |
| Session inbox socket, image block | blue | nothing | dropped silently | ✗ text only |
| Channel push (`--dangerously-load-development-channels`) | text | "blocked by org policy … inbound messages will be silently dropped" | nothing | ✗ blocked by Team org policy |
| MCP `inbox_next` tool returning image blocks, nudged by a pasted one-liner | blue, red, green | "Called showtell" | "1. Blue 2. Red 3. Green" | ✓ real image blocks, in order |
| MCP tool, nudged through the inbox socket | green | "Held message", approved | "Green" | ◐ works, needs an approval click |
| Socket with `crossSessionInbound: accept` in project settings | red | still "Held peer message" | n/a | ◐ project setting ignored (user level untested) |
| **herdr socket `pane.send_input {text}`** (herdr's own paste) | red, green | `What colors are these? [Image #1] then [Image #2]` | (next row) | ✓ chips, in order |
| **Same, sent and submitted while Claude was busy** (`sleep 20`) | blue | queued: `Also this one, what color: [Image #3]` | "1. red 2. green 3. blue" | ✓ queued with the image |
| `showtell-cli send` (the app's outbox) | blue, red | `…: first[Image #1]then[Image #2]` | "Blue, then red." | ✓ |
| Showtell.app: toggle, two clipboard screenshots, toggle | green, blue | `[Image #1] [Image #2]`, submitted | "solid green … solid blue" | ✓ |

## Rules that came out of it

1. Each screenshot path must arrive as its **own bracketed paste**. Inside a sentence it stays text.
2. **Pause after each image** (0.8 s worked) or the chips are moved to the end of the prompt.
3. Pressing Enter while Claude works **queues** the message, images included.
4. Never paste while a dialog is open: the paste lands in the dialog. herdr reports this as status
   `blocked`.
5. **Clear the prompt first** (12 Oct 2026): a paste is appended to whatever is already typed, and
   both are submitted. Ctrl+U deletes only one *screen* line (a wrapped line takes several), and
   Ctrl+K at the end of a line joins the next one. Rounds of Ctrl+E, Ctrl+K, Ctrl+U, Backspace
   empty the input wherever the cursor is, also while Claude works (it was not interrupted), and do
   nothing to an empty prompt. The empty box shows a dim placeholder (`Try "…"`, or "Press up to
   edit queued messages"), so read the screen with colours (`pane.read` format `ansi`). Claude
   Code puts a no-break space after `❯`.
6. **Put the draft back** (12 Oct 2026, scratch session in herdr, Claude Code 2.1.296):
   - **Ctrl+S stashes** a non-empty prompt (`chat:stash`) and shows `› stashed` (grey, not dim)
     on the line above the box. The next submit pops it back with a "Draft restored" toast: idle,
     and when Enter queues the message while Claude works. A 19-row draft came back whole, cursor
     where it was. tmux's `C-s` stashes too.
   - Claude Code holds **one** stash: a second Ctrl+S replaced the first. Ctrl+S on an empty prompt
     pops the stash. A submit with a stash and an empty prompt puts the stash in the prompt.
   - **Typed text** (herdr `pane.send_text`, tmux `send-keys -l`; no paste markers) stays plain
     text. Line breaks typed as LF (Ctrl+J) are new lines in the input and don't submit, in herdr and
     tmux. Text that arrives in big chunks is folded into `[Pasted text #n]`: 2,950 characters in one
     call became two chips, and 200-character pieces with no pause became one; 100- or
     200-character pieces 30–50 ms apart stayed plain.
   - The input wraps at the rule's width less 4: between words (the space is dropped, and a row can
     end exactly at the edge) or inside a word longer than a row.
   - A draft taller than the box (8 rows in a 27-row pane) shows only the rows around the cursor,
     with `❯` on the top visible row and nothing marking the hidden ones. The box scrolls with the
     cursor (Up/Down). Down on the last row does nothing outside history. Clearing all rows but
     the top one brings the rows above into view; read that way, a 2,290-character draft of 19 rows
     came back exactly as typed.

   | Case (all `showtell-cli send --submit` unless noted) | Result |
   |---|---|
   | One-line draft, Claude idle | stashed, sent, "Draft restored" ✓ |
   | 19-row draft, Claude working (message queued) | stashed, queued, whole draft back ✓ |
   | One-line draft, Send off | stays stashed; back after Enter by hand ✓ |
   | One-line draft, own stash held, idle | cleared, own stash stashed again, draft typed back, own stash intact ✓ |
   | 19-row draft, cursor moved 10 rows up, own stash held, Claude working | read whole while clearing (exact match), queued, typed back, own stash intact ✓ |
7. **A message for a session showing a dialog** (12 Oct 2026, scratch session in herdr, Claude
   Code 2.1.296, `--permission-mode default`). Earlier, Showtell waited silently for up to 10
   minutes, then pasted, so an answer meant for a question arrived afterwards as a new message.
   Now the message is held, the bar says so, and you choose.
   - **Question (AskUserQuestion):** under a rule, a header ` ☐ Fruit` or, for several questions
     or a multi-select, a tab row `←  ☐ Colours  ☐ Size  ✔ Submit  →`; then the question and
     numbered options, the last being `Type something.` (`[ ] Type something` in a multi-select).
     Then a rule, `Chat about this`, and the footer `Enter to select · ↑/↓ to navigate · Esc to cancel`.
     `❯` marks the focused option. On the free-text option the placeholder turns dim (read with
     colours, keeping dim text), and typing replaces it; a long answer wraps onto indented lines.
   - **One choice:** a number key on an option picks it and moves on, but on the free-text option
     it only moves there. Enter on the free-text option, with text in it, sends it.
   - **Multi-select:** number keys and Enter tick boxes and leave the focus where it was. Typing
     in the free-text option ticks it. Enter on it *unticks* it. The row under it (`Next`, or
     `Submit` for the last question) moves on.
   - **Several questions:** each answer moves to the next tab, and the last to `Review your answers`,
     with `1. Submit answers` / `2. Cancel` and nothing to type. A single multi-select question
     also ends there.
   - **Permission prompt:** `Do you want to proceed?` with options, footer `Esc to cancel · Tab to amend`.

   | Case (`showtell-cli send --submit --if-held …`) | Result |
   |---|---|
   | One-choice question, `answer`, text with a digit plus a picture | arrows to `Type something.`, typed, Enter; Claude got "Hot chocolate with 2 marshmallows, please and a biscuit"; picture left out ✓ |
   | Two questions, the first a multi-select, `answer` | typed in its `[ ] Type something`, Down to `Next`, Enter; dialog moved to question 2, left open ✓ |
   | Second question (one choice) of two, `answer` | typed, Enter; dialog moved to `Review your answers`, left for the user ✓ |
   | Review page, `cancel` | held as "asking a question", nothing to type; cancelled, nothing pressed ✓ |
   | Review page, `after`, then `1` pressed by hand | pasted and sent once the dialog closed ✓ |
   | Permission prompt (`touch`), `answer` | held as "waiting on a permission prompt", no Answer offered; screen unchanged; pasted after Esc by hand ✓ |

   The screens are kept as test fixtures in `Tests/ShowtellCoreTests/Screens/`. The bar's buttons
   call the same `Outbox.decide` as `--if-held`; the bar itself wasn't driven in this test,
   because that would have meant quitting the installed app.

## Paths compared

| Path | Any running session? | Images | Catch |
|---|---|---|---|
| **A · Pane paste** (herdr socket, tmux, iTerm2) | yes, if it runs there | ✓ chips | pause per image; avoid dialogs |
| B · Session inbox socket (`~/.claude/sessions/<pid>.json`) | yes | ✗ dropped | approval click in bypass mode; undocumented |
| C · Channel (MCP push) | only sessions launched with it | paths only | blocked for this Team org (`channelsEnabled`) |
| D · MCP inbox tool | sessions with the server | ✓ image blocks | Claude must be nudged to call it |

**Decision:** A through herdr's socket (`pane.send_input`), with D as the fallback if chips ever
become unreliable.

## Finding sessions

- `herdr agent list` (socket `agent.list`): every pane's agent, Claude session id, cwd, title and
  status `idle | working | blocked | done | unknown`.
- `~/.claude/sessions/<pid>.json`: cwd, name, status and tmux pane; the pid's tty matches an iTerm2
  session's `tty` property.
