---
title: Trailing CR inside bracketed paste does not submit in TUI composers
date: "2026-06-12"
category: runtime-errors
module: terminal-socket-automation
problem_type: runtime_error
component: tooling
severity: high
symptoms:
  - "Create PR button posts the prompt into the agent terminal but never submits it"
  - "User must press Enter manually after the prompt appears in the composer"
  - "UI pending state (Prompt sent…) never resolves on its own"
  - "Only paste-aware TUI composers (agent CLIs) are affected; plain shells were not"
root_cause: wrong_api
resolution_type: code_fix
related_components:
  - "Sources/Feed/FeedCoordinator.swift"
  - "Sources/AppDelegate.swift"
  - "Sources/GitChangesStore.swift"
tags:
  - bracketed-paste
  - send-text
  - send-key
  - socket-api
  - terminal-automation
  - create-pr
  - tui-composer
---

# Trailing CR inside bracketed paste does not submit in TUI composers

## Problem

The Changes-panel "Create PR" button injected a prompt into the agent's terminal via `surface.send_text` with a trailing `\r`, expecting it to submit. The prompt appeared in the agent composer (Claude Code) but never submitted — the user had to press Enter manually.

## Symptoms

- The prompt text lands visibly in the agent terminal's input line but no work starts.
- The Changes header shows "Prompt sent…" indefinitely (it only clears via PR detection or timeout).
- Behavior is specific to paste-aware TUI composers; non-paste-aware consumers (raw shells) interpret the CR.

## What Didn't Work

Appending `\r` to the `surface.send_text` payload. `send_text` delivers its payload wrapped in bracketed-paste escape sequences (`\x1b[200~ … \x1b[201~`); inside that frame every byte is literal pasted text, so the trailing CR is received as a pasted newline character, not a keypress. Refusing to interpret control characters inside the frame is the entire point of bracketed paste.

The wrong assumption was encoded in an existing code comment on the shared send path:

```swift
// Terminal-mode Return is CR. sendNamedKey "Return" also works
// but one send_text is atomic, so append CR directly.
invoke("surface.send_text", ["surface_id": surfaceId, "text": text + "\r"])
```

The comment is accurate for non-paste-aware consumers, but conceals the distinction that matters: it is wrong for any call site targeting an agent CLI composer.

## Solution

An opt-in `pressEnter` flag on the shared send path: deliver the text as a paste, then submit with a real Return key event (`surface.send_key` → `sendNamedKeyResult`), with a partial-failure ladder.

```swift
// FeedCoordinator.swift — opt-in flag, default preserves Feed behavior
static func sendText(
    workspaceId: String, surfaceId: String, text: String, pressEnter: Bool = false
)
```

```swift
// AppDelegate.swift — handleFeedRequestSendText (pressEnter path)
guard invoke("surface.send_text", [
    "surface_id": surfaceId, "text": text,
]) else { return }                          // paste failed — nothing to submit
if !invoke("surface.send_key", [
    "surface_id": surfaceId, "key": "Return",
]) {
    invoke("surface.send_text", ["surface_id": surfaceId, "text": "\r"])
}
```

The `invoke` helper was also hardened to parse the socket JSON response (success = no `"error"` key) so the guards are load-bearing; previously the result was discarded. The Create PR call site (`GitChangesStore.dispatchCreatePRPromptViaFeedPath`) passes `pressEnter: true`; all Feed callers keep the default and are unchanged.

## Why This Works

- `surface.send_key` issues a real key event through the pty, outside any paste frame, so the composer processes it as a submit.
- Ordering is safe without extra coordination: both calls run synchronously on the main actor; live surfaces write to the pty in call order, and cold surfaces append both to the same FIFO pending-input queue.

## Prevention

- **Use discrete key events for actions.** Never embed `\r`/`\n` or other control characters inside a `send_text` payload intending them to trigger composer actions; `send_text` is a paste-delivery mechanism. Use `send_key`/named-key APIs for anything that must be interpreted as a keypress.
- **Assume the receiver is paste-aware.** The trailing-CR trick only works for consumers without bracketed-paste handling; agent CLIs and modern readline consumers all have it. The failure is silent — the text lands, so the send "looks" successful.
- **Check socket results when UI state depends on delivery.** Any "pending/sent" UI state conditioned on a socket call must verify the call result and reconcile on failure rather than discarding it.
- **Add regression coverage for:** paste→keypress ordering on cold surfaces, and the `send_key`-failure → CR-fallback branch (mock the socket handler to return an error on `send_key`, assert the fallback `send_text "\r"` fires). Both were verified manually.

## Related Issues

- Introduced and fixed on branch `feat/changes-panel-pr-sync` (Changes panel with PR sync); no related GitHub issues found.
