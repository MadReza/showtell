# Showtell plan

Updated 11 Oct 2026. Spec: [spec.md](spec.md).

## Decisions so far

| When | Decision | Why |
|---|---|---|
| 10 Oct | Deliver by pasting into the pane | Only path that gives real `[Image #n]` attachments in a running session ([delivery tests](reports/delivery-tests.md)) |
| 10 Oct | Our own small app, not a fork of OpenSuperWhisper or localvoxtral | localvoxtral binds to focus and to "needs you"; we want one pinned session fed many inputs ([study](reports/study.md)) |
| 10 Oct | Swift + FluidAudio + herdr socket, macOS 14+ | Only local streaming engine with word boosting; native capture and panels |
| 10 Oct | Screenshots via the native clipboard shortcuts; bar hides while capturing | User's request; avoids the Screen Recording permission |
| 10 Oct | Second hotkey press sends with Enter; edits allowed in between | User's request; controls to become customizable |
| 10 Oct | Accept first-run model download; note the 2 s lag for later | User's call |
| 11 Oct | Start/send on a lone-modifier tap (left ⌥), recordable in a Settings window | User's request; easier to test and use |
| 11 Oct | Stricter word boost, no seeded aliases | Live tests: aliases turned "how well" into Showtell |
| 11 Oct | Insert at the cursor as a destination | User's request |
| 11 Oct | Sign with a local self-signed identity | Ad-hoc signatures lost permissions on every rebuild |
| 11 Oct | Optional tidy-up model: Apple Intelligence, Qwen 2.5 1.5B or Qwen 3 4B (llama.cpp), picked in Settings | User's request: better sentences, not a rewrite; the user chooses, with pros and cons shown |
| 11 Oct | Send checkbox in the bar (⌃⌥S) and ⌃⌥↑/↓ to change session while talking; both change the default | User's request: fewer clicks; change your mind mid-message |
| 11 Oct | Say where it goes: a session named at the start or end of a message, fuzzy match, with a pulse in the bar; sticks for the next messages once sent (switchable) | User's request; fixed patterns are instant and predictable, the tidy-up model would be slower and could misroute |

## Milestones

| # | Milestone | Status |
|---|---|---|
| 1 | Pin + paste: herdr client, session picker, ordered outbox, text + images into the pinned pane | ✓ done, verified end to end |
| 2 | Show: clipboard screenshots → numbered PNGs → markers; bar hides on ⌘⌃⇧3/4, excluded from capture | ✓ done; clipboard path verified in the app, key-hiding needs Accessibility on first run |
| 3 | Tell: FluidAudio streaming in the bar, placement by lag-adjusted transcript, editing while recording | ✓ done; speech verified on a file, live microphone needs the first real run |
| 4 | Your words: user list, repo `.github/dictation.md`, replacements | ✓ done |

## Next

1. ✓ **First real run** (11 Oct): four read-aloud tests, fixes in the [build report](reports/build-verification.md).
2. **Latency:** try a fast preview (Parakeet EOU 160 ms) under the boosted transcript if 2 s feels slow.
3. **Controls:** ✓ Settings window with shortcut recording (11 Oct). Still open: push-to-talk (hold) as an alternative to toggle.
4. ✓ **More terminals** (11 Oct): tmux and plain iTerm2 tabs, found from `~/.claude/sessions`;
   verified with throwaway Claude sessions in both (two images, answered in order).
5. **Region capture and OCR terms:** optional ScreenCaptureKit capture; feed OCR words to the boost.
6. **Orchestration:** one Claude session receiving all inputs and dispatching to others.

## Known risks

- herdr's `pane.send_input` is socket-only (protocol 22); pin and check the protocol version.
- Ad-hoc signing: macOS may ask for permissions again after rebuilds.
