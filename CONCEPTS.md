# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Terminal & Automation

### Workspace
The per-project working context: a named container holding terminals, browser panes, and a working directory, switched as a unit in the sidebar. State that follows the project — git branch, pull-request status, changed files — is scoped to the Workspace, not to individual terminals.

### Surface
The addressable unit of content inside a Workspace — one terminal or browser pane — and the target of socket automation commands (text injection, key events, focus, navigation). Code and APIs sometimes call the same unit a "panel"; the socket protocol consistently says surface.

### Agent Session
A terminal Surface that cmux knows is running a coding agent, registered through the agent hooks rather than inferred. Automation that injects prompts targets Agent Sessions only — text sent to a plain shell would execute as commands — so "is this an Agent Session?" is a trust boundary, not a cosmetic label.

## Flagged ambiguities

- "surface" and "panel" are used interchangeably in code for the same unit; the socket protocol and user-facing automation say *surface*. No settled retirement yet.
