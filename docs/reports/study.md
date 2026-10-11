# Study: existing tools and how they work

Date: 10 Oct 2026. Full illustrated version: [research/how-they-did-it.html](../research/how-they-did-it.html)
and [research/landscape.html](../research/landscape.html). Read in source code unless marked *inferred*.

## Landscape in one paragraph

Popular projects own one part each: Handy (33k★) and FluidVoice (12k★) for dictation, herdr (43k★)
for agent terminals, react-grab and agentation for web feedback, Peekaboo for agent-driven
screenshots. The few that combine parts are small: SnippAI (closed, one screenshot per message,
iTerm2/Terminal), localvoxtral (59★, streaming dictation into herdr, text only), Deiko (talk while
pointing, manual hand-off), MarkuprPlus (79★, narrated report). None keeps one session open and
feeds it voice plus screenshots in order. HN pain points: the five-step screenshot dance, "this one"
being ambiguous, misheard jargon, native `/voice` needing focus, iTerm2-only injectors.

## Why not localvoxtral

Tried on 10 Oct. It needs its Claude Code plugin and a "Context" setting before it joins any session,
and it binds the target to **the pane in front when you start talking**: front app → AppleScript
"current window" tty → herdr client probe → `pane.current` → registry. A drop-down iTerm2 window can
fail the first steps (*inferred*), and it abstains when two herdr servers or windows exist. Routing
elsewhere needs spoken names, and its model is built around "agent needs you". Its herdr delivery is
text-only (`pane.send_text`, control characters refused); its Claude Code mod's prompt API cannot
carry images.

Borrowed from it: one ordered delivery at a time with ok/refused/unknown outcomes, re-checking that
the pane still runs the session before each write, `.github/dictation.md` terms, the non-activating
panel.

## Speech options

| Engine | Streaming | Custom words | Latency | Licence | macOS |
|---|---|---|---|---|---|
| **FluidAudio Parakeet Unified** (picked) | true (windowed) | CTC spotting + rescoring, aliases, ≈230 terms | ≈2.08 s | Apache-2.0 | 14+ |
| FluidAudio Parakeet EOU 120M | true | none built in | 160 ms–1.3 s | Apache-2.0 | 14+ |
| FluidAudio Nemotron 0.6B | true | none built in | 0.56–2.24 s | Apache-2.0 | 14+ |
| FluidAudio TDT v2/v3 | sliding window | CTC boost | ≈1 s partial, ≈10 s confirmed | Apache-2.0 | 14+ |
| Apple SpeechTranscriber | true | contextual strings ignored (Apple forum) | low | system | 26+ |
| whisper.cpp | batch | initial prompt | seconds | MIT | any |
| Voxtral Mini 4B (localvoxtral) | true | via LLM polish | — | — | ≈3.5 GB |

Patterns worth knowing: FluidVoice runs a fast preview recogniser and a boosted final one (GPL, ideas
only); VoiceInk commits words once two passes agree and OCRs the front window for context (GPL);
Handy fixes words with Levenshtein + Soundex (MIT).

**Measured here:** streaming partials report no word timings until `finish()`, so Showtell places
screenshots by the transcript one lag after the shot. Self-test: "Open the herdr pane and check the
Showtell overlay. The login button is cut off on mobile." came out exactly, with "herder" corrected
to "herdr" by the boost.

## Rust or Swift

Rust works (Handy is Tauri + Rust), but it loses FluidAudio (Swift/CoreML, Neural Engine, word
boosting) and uses community bindings for ScreenCaptureKit and panels. Swift unless
Windows/Linux matters; the speech engine can later move to a separate process to keep either side
swappable.

## Licences

Copy freely with notice: FluidAudio (Apache-2.0), localvoxtral, Handy, OpenWhispr (MIT).
Read only: FluidVoice, VoiceInk, TypeWhisper (GPL-3.0). Model weights have their own licences.
