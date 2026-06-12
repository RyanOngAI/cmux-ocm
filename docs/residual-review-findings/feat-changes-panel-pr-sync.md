# Known Residuals — feat/changes-panel-pr-sync

Accepted at the code-review Residual Work Gate (run `20260612-003024-bffd0626`); carried for follow-up. Include in the PR description's Known Residuals section.

- **P1 · architecture** — `Sources/GitChangesStore.swift`, `Sources/GitChangesPanelView.swift`: new app-target files use `ObservableObject`/`@Published`/`@ObservedObject`; `skills/cmux-architecture` mandates `@MainActor @Observable` (and `@Bindable`/plain `let` in views) for all new app-target files. Migration is a contained structural rewrite of the store and its two observing views. (project-standards, confidence 100)
- **P1 · maintainability** — `Sources/GitChangesStore.swift` is 1,433 lines; split along its existing MARK boundaries: models / `GitProcessExecution` / `GitUntrackedLineCounter` / store / refresh pipeline. (maintainability, confidence 100)
- **P2 · architecture** — three caseless namespace enums (`GitChangesPanelFormatting`, `GitChangesPRHeaderLogic`, `GitChangesCreatePRLogic`) violate the no-namespace-enums rule; prefer value-typed structs or file-private functions. (project-standards, confidence 100)
- **P2 · maintainability** — sidebar (`ContentView`) and pop-out pane (`RightSidebarToolPanel`) each carry their own GitChangesStore attach/detach state machine (now manager-tracked but still duplicated); extract a shared registration helper. (maintainability, confidence 75)

Report-only advisories (no action accepted): repo-configured `core.fsmonitor`/hooks run inside Changes-panel git spawns (pre-existing pattern repo-wide); untracked counter TOCTOU (`O_NOFOLLOW` hardening); non-UTF-8 path bytes dropped from `-z` token streams can shift rename parse alignment; unbounded row count under `-uall` for huge untracked trees; review coverage degraded — performance/api-contract/reliability/testing/agent-native reviewer passes did not complete (session limits), partially covered by adversarial + correctness.
