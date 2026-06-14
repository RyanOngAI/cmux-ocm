---
title: "Localized string shows a literal %@ when a value is interpolated into defaultValue"
date: 2026-06-14
category: ui-bugs
module: localization / worktree removal UI
problem_type: ui_bug
component: rails_view
symptoms:
  - "A user-facing dialog shows a literal \"%@\" instead of the interpolated value (e.g. a branch name)"
  - "The English/Japanese catalog text renders verbatim with the placeholder unsubstituted"
root_cause: wrong_api
resolution_type: code_fix
severity: medium
tags: [localization, string-catalog, xcstrings, localizedstringwithformat, swiftui, nsalert]
---

# Localized string shows a literal %@ when a value is interpolated into defaultValue

## Problem
A dynamic value (a worktree branch name) interpolated into the `defaultValue:`
of `String(localized:defaultValue:)` never reached the user. Once the string
catalog (`Localizable.xcstrings`) carried a translation for the key, the dialog
showed the catalog's literal `%@` placeholder instead of the branch name.

## Symptoms
- The "Remove worktree with uncommitted changes?" confirmation read: *The
  worktree "%@" has uncommitted or untracked changes…* — with a literal `%@`.
- Reproduces only when the catalog has the key translated (i.e. always, in
  shipping builds); a key missing from the catalog would have masked it.

## What Didn't Work
Interpolating the value directly into `defaultValue:`:

```swift
alert.informativeText = String(
    localized: "worktree.remove.dirty.message",
    defaultValue: "The worktree “\(branch)” has uncommitted or untracked changes…"
)
```

This looks correct and even works in a build where the catalog has no entry for
the key — which is exactly why it slips through. The interpolation runs when the
Swift string literal is constructed, but that string is only the *fallback*.

## Solution
Store a `%@` placeholder in the catalog **and** the `defaultValue`, then
substitute with `String.localizedStringWithFormat`. Extract it into a testable
formatter so the substitution is asserted, not eyeballed:

```swift
nonisolated static func dirtyWorktreeRemovalMessage(branch: String) -> String {
    String.localizedStringWithFormat(
        String(
            localized: "worktree.remove.dirty.message",
            defaultValue: "The worktree “%@” has uncommitted or untracked changes…"
        ),
        branch
    )
}
```

```swift
// Behavioral test — no source-shape assertions:
let message = TabManager.dirtyWorktreeRemovalMessage(branch: "amsterdam")
#expect(message.contains("amsterdam"))
#expect(!message.contains("%@"))
```

The catalog entry's `value` for every locale uses `%@`:

```json
"worktree.remove.dirty.message": {
  "localizations": {
    "en": { "stringUnit": { "value": "The worktree “%@” has uncommitted…" } },
    "ja": { "stringUnit": { "value": "ワークツリー「%@」には…" } }
  }
}
```

## Why This Works
`String(localized:defaultValue:)` returns the **catalog** value whenever the key
resolves; `defaultValue:` is used *only* when the key is absent. Swift
interpolation inside `defaultValue:` therefore can't survive into a shipping
build — the catalog string (with its untouched `%@`) wins. `%@` is a positional
format placeholder; nothing substitutes it unless you pass the localized string
through `String.localizedStringWithFormat` (or `NSLocalizedString` +
`String(format:)`). Putting `%@` in both the catalog and the `defaultValue`
keeps the catalog-present and catalog-absent paths identical.

## Prevention
- **Convention:** any user-facing localized string that embeds a dynamic value
  uses `%@` (positional) placeholders in **both** the `.xcstrings` catalog and
  the Swift `defaultValue:`, and is rendered via
  `String.localizedStringWithFormat(String(localized:defaultValue:), args…)`.
  Never Swift-interpolate (`\(value)`) into `defaultValue:` — the interpolation
  is silently discarded once the catalog has the key.
- Extract the formatting into a small `nonisolated static` function so it is unit
  testable; assert the result `contains` the value and does **not** contain
  `"%@"`. A runtime test catches this where a code-shape grep would not.
- During a localization audit, grep changed Swift for `String(localized:` calls
  whose `defaultValue:` contains `\(` — that combination is the smell.

## Related Issues
- Surfaced by the multi-agent code review of the git-worktree-from-group-`+`
  feature (`feat/worktree-from-group-plus`); fixed in the `fix(review)` commit
  alongside a `removeWorktree` in-flight guard.
- See also `docs/plans/2026-06-14-001-feat-worktree-from-group-plus-plan.md`.
