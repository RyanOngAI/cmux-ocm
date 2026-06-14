import Foundation

extension RightSidebarMode {
    static func from(cliArgument rawValue: String) -> RightSidebarMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "files":
            return .files
        case "find":
            return .find
        case "changes":
            return .changes
        case "vault", "sessions":
            return .sessions
        case "feed":
            return .feed
        case "dock":
            return .dock
        default:
            return nil
        }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    static func availableModes(feedEnabled: Bool, dockEnabled: Bool) -> [RightSidebarMode] {
        allCases.filter { $0.isAvailable(feedEnabled: feedEnabled, dockEnabled: dockEnabled) }
    }

    /// Modes shown as selectable tabs in the right-sidebar mode bar: the
    /// available modes minus the ones that aren't standalone tabs (Changes,
    /// which lives in the Files tab and as a pane). Use this for the mode bar
    /// and the command palette's mode-switch entries; `availableModes` still
    /// drives pane-capable surfaces.
    static func modeBarTabs(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(defaults: defaults).filter(\.isSelectableSidebarTab)
    }

    static func modeBarTabs(feedEnabled: Bool, dockEnabled: Bool) -> [RightSidebarMode] {
        availableModes(feedEnabled: feedEnabled, dockEnabled: dockEnabled)
            .filter(\.isSelectableSidebarTab)
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    func isAvailable(feedEnabled: Bool, dockEnabled: Bool) -> Bool {
        switch self {
        case .files, .find, .changes, .sessions:
            return true
        case .feed:
            return feedEnabled
        case .dock:
            return dockEnabled
        }
    }
}
