# Adding page elements while talking (to do)

Explored 11 Oct 2026, parked for later. Goal: while talking, add an element from a web page to
the message, at the word you were saying, the way screenshots are added, so the agent knows
exactly which element you mean.

## The tool we remembered: react-grab

[aidenybai/react-grab](https://github.com/aidenybai/react-grab) (MIT, ~7.7k★, active). Hover an
element in your app and press ⌘C; it copies one line:

```
[<a class="ml-auto inline-block text-sm" href="#">Forgot your password?</a> in LoginForm (at components/login-form.tsx:46:19)]
```

- Installed in your app in development (script tag, `npx grab@latest init`) or as an MV3 browser
  extension on any page.
- Component and file names need React in development (it reads fiber debug data through `bippy`;
  works on React 19). Line numbers only on Next.js; otherwise the HTML plus `selector: …`.
- Copies `text/plain`, `text/html` and `application/x-react-grab` (JSON with tag, component,
  source, frames). In Chromium the JSON sits in the `org.chromium.web-custom-data` pasteboard type;
  react-grab's own `npx react-grab watch` reads it on macOS.
- Plugin hooks (`onCopySuccess`, `transformCopyContent`) on `window.__REACT_GRAB__`.

Similar: [agentation](https://github.com/benjitaylor/agentation) (PolyForm Shield, not OSI open
source; React 18+ component, ⌘⇧F) copies Markdown notes (`### 1. Button`, `**Source:**
src/Button.tsx:42`, `**Feedback:** …`) and has an MCP server for two-way feedback. Others:
stagewise (now its own IDE), LocatorJS and click-to-component (open the editor, nothing to copy).

## Options for Showtell

| | How | What the agent gets | Effort |
|---|---|---|---|
| 1. Clipboard bridge (recommended first) | While recording, copied text lands in the message at the spoken position, like screenshots; react-grab and agentation copies get a label (`[🔗 1 LoginForm]`) | The full element line at that spot | ~1 day: `ClipboardWatcher` already polls every 0.2 s |
| 2. Accessibility picker | A Showtell shortcut highlights the element under the mouse in any app; click adds it | Role, label, text; on web pages the DOM id and classes (`AXDOMIdentifier`, `AXDOMClassList`); no component or file | A few days; prototype first, Chrome's exposure unverified |
| 3. Own browser extension | Our own picker talking to Showtell over native messaging | What react-grab gives, on any page | Large; mostly rebuilds react-grab |

Open question for when this is picked up: should every text copied while talking join the
message, or only react-grab and agentation copies?
