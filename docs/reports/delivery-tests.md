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
