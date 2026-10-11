# Showtell plan

Updated 10 Oct 2026. Spec: [spec.md](spec.md).

## Decisions so far

| When | Decision | Why |
|---|---|---|
| 10 Oct | Deliver by pasting into the pane | Only path that gives real `[Image #n]` attachments in a running session ([delivery tests](reports/delivery-tests.md)) |
| 10 Oct | Our own small app, not a fork of OpenSuperWhisper or localvoxtral | localvoxtral binds to focus and to "needs you"; we want one pinned session fed many inputs ([study](reports/study.md)) |
| 10 Oct | Swift + FluidAudio + herdr socket, macOS 14+ | Only local streaming engine with word boosting; native capture and panels |
| 10 Oct | Screenshots via the native clipboard shortcuts; bar hides while capturing | User's request; avoids the Screen Recording permission |
| 10 Oct | Second hotkey press sends with Enter; edits allowed in between | User's request; controls to become customizable |
| 10 Oct | Accept first-run model download; note the 2 s lag for later | User's call |

## Milestones

| # | Milestone | Status |
|---|---|---|
| 1 | Pin + paste: herdr client, session picker, ordered outbox, text + images into the pinned pane | ✓ done, verified end to end |
| 2 | Show: clipboard screenshots → numbered PNGs → markers; bar hides on ⌘⌃⇧3/4, excluded from capture | ✓ done; clipboard path verified in the app, key-hiding needs Accessibility on first run |
| 3 | Tell: FluidAudio streaming in the bar, placement by lag-adjusted transcript, editing while recording | ✓ done; speech verified on a file, live microphone needs the first real run |
| 4 | Your words: user list, repo `.github/dictation.md`, replacements | ✓ done |

## Next

1. **First real run by you** (needs your clicks once): microphone permission, Accessibility
   permission, then a real dictation with screenshots into a herdr session.
2. **Latency:** try a fast preview (Parakeet EOU 160 ms) under the boosted transcript if 2 s feels slow.
3. **Controls:** ✓ Settings window with shortcut recording (11 Oct). Still open: push-to-talk (hold) as an alternative to toggle.
4. **More terminals:** iTerm2 plain tabs (AppleScript `write text` with paste markers), tmux
   (`paste-buffer -p`). Rules already verified.
5. **Region capture and OCR terms:** optional ScreenCaptureKit capture; feed OCR words to the boost.
6. **Orchestration:** one Claude session receiving all inputs and dispatching to others.

## Known risks

- herdr's `pane.send_input` is socket-only (protocol 22); pin and check the protocol version.
- Ad-hoc signing: macOS may ask for permissions again after rebuilds.
