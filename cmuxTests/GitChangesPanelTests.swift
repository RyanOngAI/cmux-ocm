import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Git changes panel")
struct GitChangesPanelTests {

    // MARK: - Mode metadata

    @Test func changesModeMetadata() {
        #expect(RightSidebarMode.changes.rawValue == "changes")
        #expect(!RightSidebarMode.changes.label.isEmpty)
        #expect(RightSidebarMode.changes.symbolName == "plusminus")
        #expect(RightSidebarMode.changes.shortcutAction == .switchRightSidebarToChanges)
    }

    @Test func changesModeIsAlwaysAvailable() {
        #expect(RightSidebarMode.changes.isAvailable(feedEnabled: false, dockEnabled: false))
        #expect(RightSidebarMode.changes.isAvailable(feedEnabled: true, dockEnabled: true))
        #expect(
            RightSidebarMode.availableModes(feedEnabled: false, dockEnabled: false)
                .contains(.changes)
        )
    }

    @Test func changesModeOpensAsPane() {
        #expect(RightSidebarMode.paneModes.contains(.changes))
        #expect(RightSidebarMode.changes.canOpenAsPane)
    }

    @Test func fileExplorerStoreDoesNotSyncForChangesMode() {
        // The Changes panel attaches its store through TabManager's registry;
        // the file-explorer store must stay parked while Changes is showing.
        #expect(
            !FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                isRightSidebarVisible: true,
                mode: .changes
            )
        )
        #expect(
            !FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                isRightSidebarVisible: false,
                mode: .changes
            )
        )
        // Sanity: the policy still syncs for the tree-backed modes.
        #expect(
            FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                isRightSidebarVisible: true,
                mode: .files
            )
        )
    }

    @Test func cliArgumentMapsToChangesMode() {
        #expect(RightSidebarMode.from(cliArgument: "changes") == .changes)
        #expect(RightSidebarMode.from(cliArgument: " CHANGES ") == .changes)
    }

    // MARK: - Raw-value persistence round trips

    @Test func modeRawValueRoundTripsThroughCodable() throws {
        for mode in RightSidebarMode.allCases {
            let data = try JSONEncoder().encode([mode])
            let decoded = try JSONDecoder().decode([RightSidebarMode].self, from: data)
            #expect(decoded == [mode])
        }
        #expect(RightSidebarMode(rawValue: "changes") == .changes)
    }

    @MainActor
    @Test func fileExplorerStateFallsBackFromChangesModeToFiles() {
        // Changes is no longer a standalone sidebar tab — it lives as the docked
        // bottom half of the Files tab (and as an openable pane). A stored or
        // requested `.changes` mode must therefore resolve to `.files`, never
        // leave the sidebar stranded on a tab the mode bar can't switch away from.
        let defaults = UserDefaults.standard
        let modeKey = "rightSidebar.mode"
        let savedMode = defaults.string(forKey: modeKey)
        defer {
            if let savedMode {
                defaults.set(savedMode, forKey: modeKey)
            } else {
                defaults.removeObject(forKey: modeKey)
            }
        }

        defaults.set(RightSidebarMode.changes.rawValue, forKey: modeKey)
        #expect(FileExplorerState().mode == .files)

        let state = FileExplorerState()
        state.mode = .changes
        #expect(state.mode == .files)
    }

    @Test func sessionToolPanelSnapshotRoundTripsChanges() throws {
        let snapshot = SessionRightSidebarToolPanelSnapshot(mode: .changes)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionRightSidebarToolPanelSnapshot.self, from: data)
        #expect(decoded.mode == .changes)
    }

    @Test func sessionToolPanelSnapshotDecodesUnknownModeAsNil() throws {
        let json = Data(#"{"mode":"holograms"}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionRightSidebarToolPanelSnapshot.self, from: json)
        #expect(decoded.mode == nil)
    }

    // MARK: - Shortcut wiring

    @Test func appShortcutDefaultIsControlSixAndPrivate() {
        let action = KeyboardShortcutSettings.Action.switchRightSidebarToChanges
        let shortcut = action.defaultShortcut
        #expect(shortcut.key == "6")
        #expect(shortcut.control)
        #expect(!shortcut.command)
        #expect(!shortcut.shift)
        #expect(!shortcut.option)
        #expect(!action.isPublicShortcutAction)
    }

    @Test func settingsPackageShortcutMatchesAppDefault() throws {
        let appAction = KeyboardShortcutSettings.Action.switchRightSidebarToChanges
        let packageAction = try #require(ShortcutAction(rawValue: appAction.rawValue))
        #expect(packageAction == .switchRightSidebarToChanges)
        let stroke = try #require(packageAction.defaultStroke)
        #expect(stroke.key == "6")
        #expect(stroke.control)
        #expect(!stroke.command)
        #expect(!stroke.shift)
        #expect(!stroke.option)
        #expect(packageAction.hasPriorityShortcutRouting)
    }

    // MARK: - Row/totals formatting helpers

    @Test func totalsFilesTextHandlesSingularAndPlural() {
        let singular = GitChangesPanelFormatting.totalsFilesText(count: 1)
        #expect(singular.contains("1"))
        #expect(!singular.contains("%"))

        let plural = GitChangesPanelFormatting.totalsFilesText(count: 42)
        #expect(plural.contains("42"))
        #expect(!plural.contains("%"))
    }

    @Test func renameRendersOldArrowNew() {
        let file = GitChangedFile(
            path: "Sources/New.swift",
            previousPath: "Sources/Nested/Old.swift",
            status: .renamed,
            isBinary: false,
            addedLines: 1,
            deletedLines: 2
        )
        #expect(GitChangesPanelFormatting.displayName(for: file) == "Old.swift → New.swift")
        #expect(
            GitChangesPanelFormatting.fullPathTooltip(for: file)
                == "Sources/Nested/Old.swift → Sources/New.swift"
        )
    }

    @Test func displayNameAndDirectorySplitPlainPaths() {
        let nested = GitChangedFile(
            path: "Sources/Panels/BrowserPanel.swift",
            previousPath: nil,
            status: .modified,
            isBinary: false,
            addedLines: 3,
            deletedLines: 4
        )
        #expect(GitChangesPanelFormatting.displayName(for: nested) == "BrowserPanel.swift")
        #expect(GitChangesPanelFormatting.directoryText(for: nested) == "Sources/Panels")
        #expect(GitChangesPanelFormatting.fullPathTooltip(for: nested) == "Sources/Panels/BrowserPanel.swift")

        let rootLevel = GitChangedFile(
            path: "README.md",
            previousPath: nil,
            status: .untracked,
            isBinary: false,
            addedLines: 5,
            deletedLines: 0
        )
        #expect(GitChangesPanelFormatting.displayName(for: rootLevel) == "README.md")
        #expect(GitChangesPanelFormatting.directoryText(for: rootLevel).isEmpty)
    }

    @Test func accessibilityLabelIncludesPathStatusAndCounts() {
        let counted = GitChangedFile(
            path: "Sources/App.swift",
            previousPath: nil,
            status: .modified,
            isBinary: false,
            addedLines: 7,
            deletedLines: 3
        )
        let countedLabel = GitChangesPanelFormatting.accessibilityLabel(for: counted)
        #expect(countedLabel.contains("Sources/App.swift"))
        #expect(countedLabel.contains("7"))
        #expect(countedLabel.contains("3"))

        let uncounted = GitChangedFile(
            path: "Assets/icon.png",
            previousPath: nil,
            status: .added,
            isBinary: true,
            addedLines: nil,
            deletedLines: nil
        )
        let uncountedLabel = GitChangesPanelFormatting.accessibilityLabel(for: uncounted)
        #expect(uncountedLabel.contains("Assets/icon.png"))
        #expect(!uncountedLabel.contains("%"))
    }

    @Test func statusDescriptionsAreNonEmptyForAllStatuses() {
        let statuses: [GitChangedFileStatus] = [
            .added, .modified, .deleted, .renamed, .copied,
            .typeChanged, .untracked, .conflicted, .submodule,
        ]
        for status in statuses {
            #expect(!GitChangesPanelFormatting.statusDescription(for: status).isEmpty)
        }
    }

    // MARK: - Workspace root mapping

    @MainActor
    @Test func paletteCommandIDExistsForChangesMode() {
        #expect(
            ContentView.commandPaletteRightSidebarModeCommandID(.changes)
                == "palette.showRightSidebarChanges"
        )
        #expect(
            ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
                .contains(where: { $0.mode == .changes })
        )
    }
}
