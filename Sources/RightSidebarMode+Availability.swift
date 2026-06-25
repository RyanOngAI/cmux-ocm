import AppKit
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
        allCases.filter { $0 != .customSidebar && $0.isAvailable(feedEnabled: feedEnabled, dockEnabled: dockEnabled) }
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
        case .customSidebar:
            return false
        }
    }
}

enum RightSidebarKeyboardNavigation {
    enum DisclosureAction {
        case collapse
        case expand
    }

    static func moveDelta(for event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrOption = !flags.intersection([.command, .option]).isEmpty
        if flags.contains(.control), !hasCommandOrOption {
            switch event.keyCode {
            case 45: return 1   // Ctrl+N
            case 35: return -1  // Ctrl+P
            default: break
            }
        }

        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 38, 125: return 1   // J or Down
        case 40, 126: return -1  // K or Up
        default: return nil
        }
    }

    static func disclosureAction(for event: NSEvent) -> DisclosureAction? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 4: return .collapse  // H
        case 37: return .expand   // L
        case 123: return .collapse  // Left
        case 124: return .expand   // Right
        default: return nil
        }
    }

    static func isPlainSlash(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        return event.keyCode == 44
    }

    static func isPlainPrintableText(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else {
            return false
        }
        return text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}
