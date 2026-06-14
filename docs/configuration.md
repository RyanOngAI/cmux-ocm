# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

## `app.confirmQuit`

Controls when cmux asks before quitting:

- `always`: show the quit confirmation on Cmd+Q or app quit.
- `dirty-only`: show it only when a workspace has a terminal or panel that reports close confirmation is needed.
- `never`: quit immediately.

Default: `always` for stable and nightly builds. DEV builds always behave as `never`, regardless of the file setting, so tagged development builds can be replaced without a full-screen quit dialog.

The older boolean `app.warnBeforeQuit` still works as a fallback when `app.confirmQuit` is not set. `true` maps to `always`; `false` maps to `never`.

## `app.forkConversationDefaultDestination`

Controls what the tab right-click `Fork Conversation` item does. The submenu still exposes every destination.

Values: `right`, `left`, `top`, `bottom`, `newTab`, `newWorkspace`.

Default: `right`.

## `terminal.agentHibernation`

Opt-in Agent Hibernation. cmux kills idle background agent processes to free RAM and CPU, then resumes each one with its saved session when you visit its tab. See [agent-hooks.md](agent-hooks.md#agent-hibernation) for the full behavior, including the confirmation settle window and how resume works.

```json
{
  "terminal": {
    "agentHibernation": {
      "enabled": true,
      "idleSeconds": 5,
      "maxLiveTerminals": 12
    }
  }
}
```

- `enabled`: turn Agent Hibernation on. Default: `false`.
- `idleSeconds`: seconds a background idle agent terminal must be quiet before it can hibernate. A ~60s confirmation settle window still applies on top of this. Default: `5`. Range: `5`-`604800`.
- `maxLiveTerminals`: how many live restorable agent terminals to keep before cmux hibernates the oldest idle background ones. Nothing hibernates while you are at or under this count. Default: `12`. Range: `1`-`256`.

Enable it from the command palette (`⌘⇧P` -> Enable Agent Hibernation), from **Settings > Terminal > Agent Hibernation**, or with `cmux agent-hibernation on`.

## `diffViewer.defaultLayout`

Controls the initial layout for newly opened diff viewers.

Values: `unified`, `split`.

Default: `unified`.

```json
{
  "diffViewer": {
    "defaultLayout": "unified"
  }
}
```

The toolbar layout toggle persists the last user choice for future generated diff viewers. Passing `cmux diff --layout split` or `cmux diff --layout unified` overrides both the saved toolbar choice and this default for that invocation.

## Changes panel base branch (per-repository git config)

The Changes sidebar tab compares your branch against an auto-detected default branch (`origin/HEAD`, falling back to local `main`/`master`). To compare against a different ref — for example a fork remote's main — set the per-repository git config key:

```bash
git config cmux.changes.base myfork/main
```

The value must resolve to a commit (any ref works: `remote/branch`, a local branch, a tag). An unresolvable value is ignored and auto-detection applies. Clicking a file in the Changes panel opens the diff viewer against the same base. This is git config, not `cmux.json`, because the base branch is inherently per-repository.

## `shortcuts.bindings`

Rebind cmux-owned keyboard shortcuts by action name. The full action list and syntax live in the [keyboard shortcuts docs](https://cmux.com/docs/keyboard-shortcuts) and the JSON schema (`web/data/cmux.schema.json`).

Right-sidebar mode switching (active while the right sidebar is focused):

| Action | Default | Shows |
| --- | --- | --- |
| `switchRightSidebarToFiles` | `ctrl+1` | Files |
| `switchRightSidebarToFind` | `ctrl+2` | Find |
| `switchRightSidebarToSessions` | `ctrl+3` | Vault |
| `switchRightSidebarToFeed` | `ctrl+4` | Feed |
| `switchRightSidebarToDock` | `ctrl+5` | Dock |
| `switchRightSidebarToChanges` | `ctrl+6` | Changes |

```json
{
  "shortcuts": {
    "bindings": {
      "switchRightSidebarToChanges": "ctrl+6"
    }
  }
}
```
