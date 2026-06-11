import AppKit
import SwiftUI

// MARK: - Formatting helpers

/// Pure formatting helpers for the Changes panel, kept off the view types so
/// they are unit-testable without rendering.
nonisolated enum GitChangesPanelFormatting {
    /// "1 file" / "%lld files" totals fragment.
    static func totalsFilesText(count: Int) -> String {
        if count == 1 {
            return String(localized: "changes.totals.fileSingular", defaultValue: "1 file")
        }
        return String.localizedStringWithFormat(
            String(localized: "changes.totals.files", defaultValue: "%lld files"),
            count
        )
    }

    /// Last path component; renames render "old → new" (last components).
    static func displayName(for file: GitChangedFile) -> String {
        let name = lastComponent(of: file.path)
        guard let previousPath = file.previousPath else { return name }
        return "\(lastComponent(of: previousPath)) → \(name)"
    }

    /// Directory portion of the current path, empty for root-level files.
    static func directoryText(for file: GitChangedFile) -> String {
        guard let slash = file.path.lastIndex(of: "/") else { return "" }
        return String(file.path[file.path.startIndex..<slash])
    }

    /// Full repo-relative path for the row tooltip; renames render
    /// "old → new" with full paths.
    static func fullPathTooltip(for file: GitChangedFile) -> String {
        guard let previousPath = file.previousPath else { return file.path }
        return "\(previousPath) → \(file.path)"
    }

    /// Localized human-readable status name (also used for accessibility).
    static func statusDescription(for status: GitChangedFileStatus) -> String {
        switch status {
        case .added:
            return String(localized: "changes.status.added", defaultValue: "Added")
        case .modified:
            return String(localized: "changes.status.modified", defaultValue: "Modified")
        case .deleted:
            return String(localized: "changes.status.deleted", defaultValue: "Deleted")
        case .renamed:
            return String(localized: "changes.status.renamed", defaultValue: "Renamed")
        case .copied:
            return String(localized: "changes.status.copied", defaultValue: "Copied")
        case .typeChanged:
            return String(localized: "changes.status.typeChanged", defaultValue: "Type changed")
        case .untracked:
            return String(localized: "changes.status.untracked", defaultValue: "Untracked")
        case .conflicted:
            return String(localized: "changes.status.conflicted", defaultValue: "Conflicted")
        case .submodule:
            return String(localized: "changes.status.submodule", defaultValue: "Submodule")
        }
    }

    /// "path, status, N added, M deleted" accessibility label per row.
    static func accessibilityLabel(for file: GitChangedFile) -> String {
        let status = statusDescription(for: file.status)
        guard let added = file.addedLines, let deleted = file.deletedLines else {
            return String.localizedStringWithFormat(
                String(localized: "changes.row.accessibility.noCounts", defaultValue: "%1$@, %2$@"),
                file.path,
                status
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "changes.row.accessibility.withCounts",
                defaultValue: "%1$@, %2$@, %3$lld added, %4$lld deleted"
            ),
            file.path,
            status,
            added,
            deleted
        )
    }

    private static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

// MARK: - Status palette

extension GitChangedFileStatus {
    /// Row filename tint. Mirrors the file explorer's git palette family
    /// (`FileExplorerStyle.gitColor(for:)` in `FileExplorerStore.swift`).
    var changesRowColor: Color {
        switch self {
        case .added: return Color(nsColor: .systemGreen)
        case .modified: return Color(nsColor: .systemYellow)
        case .deleted: return Color(nsColor: .systemRed)
        case .renamed, .copied: return Color(nsColor: .systemBlue)
        case .typeChanged: return Color(nsColor: .systemYellow)
        case .untracked: return Color(nsColor: .tertiaryLabelColor)
        case .conflicted: return Color(nsColor: .systemOrange)
        case .submodule: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Workspace root resolution

extension GitChangesWorkspaceRoot {
    /// Maps a workspace to the Changes store's root descriptor: remote
    /// workspaces are explicitly `.remote` (R26's dedicated state), an empty
    /// cwd is `.none`, everything else is the local cwd.
    @MainActor
    static func forWorkspace(_ workspace: Workspace) -> GitChangesWorkspaceRoot {
        if workspace.isRemoteWorkspace { return .remote }
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? .none : .local(path: directory)
    }
}

// MARK: - Action bundles

/// Callback bundle handed below the snapshot boundary in place of a store
/// reference. See `IndexSectionActions` in `SessionIndexView.swift`: every
/// capability a row needs is a closure so no view under the `ForEach` can
/// subscribe to broad store updates.
struct GitChangesRowActions {
    let onOpenFile: (GitChangedFile) -> Void
}

// MARK: - Host (nil-store wrapper)

/// Hosts the Changes panel for call sites whose store is optional (no
/// workspace selected). Renders the not-a-repo state when there is nothing
/// to attach to.
struct GitChangesPanelHostView: View {
    let store: GitChangesStore?
    let onOpenFile: (GitChangedFile) -> Void

    var body: some View {
        if let store {
            GitChangesPanelView(store: store, onOpenFile: onOpenFile)
        } else {
            GitChangesMessageView(
                message: String(
                    localized: "changes.state.notARepo",
                    defaultValue: "This folder isn't a Git repository"
                )
            )
        }
    }
}

// MARK: - Panel

/// Changes panel root. The only view in this file that observes the store;
/// everything below receives the immutable snapshot value plus closures.
struct GitChangesPanelView: View {
    @ObservedObject var store: GitChangesStore
    let onOpenFile: (GitChangedFile) -> Void

    var body: some View {
        GitChangesContentView(
            snapshot: store.snapshot,
            actions: GitChangesRowActions(onOpenFile: onOpenFile),
            onRetry: { [weak store] in
                guard let store else { return }
                Task { await store.refreshNow() }
            }
        )
        .equatable()
    }
}

/// Snapshot-driven content. `Equatable` on the snapshot alone so unrelated
/// parent re-evaluations don't re-diff the list subtree.
private struct GitChangesContentView: View, Equatable {
    let snapshot: GitChangesSnapshot
    let actions: GitChangesRowActions
    let onRetry: () -> Void

    static func == (lhs: GitChangesContentView, rhs: GitChangesContentView) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        switch snapshot.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notARepo:
            GitChangesMessageView(
                message: String(
                    localized: "changes.state.notARepo",
                    defaultValue: "This folder isn't a Git repository"
                )
            )
        case .remoteUnavailable:
            GitChangesMessageView(
                message: String(
                    localized: "changes.state.remoteUnavailable",
                    defaultValue: "Changes isn't available for remote workspaces yet"
                )
            )
        case .failed:
            GitChangesMessageView(
                message: String(
                    localized: "changes.state.failed",
                    defaultValue: "Couldn't read changes"
                ),
                retryTitle: String(localized: "changes.action.retry", defaultValue: "Retry"),
                onRetry: onRetry
            )
        case .ready, .degraded:
            listContent
        }
    }

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            GitChangesHeaderView(branch: snapshot.branch, baseRef: snapshot.baseRef)
            // U5 mounts the pull-request header (PR state, checks, Create PR)
            // in this slot, between the branch context and the totals line.

            GitChangesTotalsView(
                fileCount: snapshot.files.count,
                totalAddedLines: snapshot.totalAddedLines,
                totalDeletedLines: snapshot.totalDeletedLines
            )

            if snapshot.phase == .degraded {
                Text(String(
                    localized: "changes.caption.degraded",
                    defaultValue: "Uncommitted changes only (no base branch)"
                ))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }

            Divider()

            if snapshot.files.isEmpty {
                GitChangesMessageView(message: emptyListMessage)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.files) { file in
                            GitChangesFileRow(file: file, actions: actions)
                                .equatable()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var emptyListMessage: String {
        if snapshot.phase == .ready, let baseRef = snapshot.baseRef {
            return String.localizedStringWithFormat(
                String(localized: "changes.empty.noChangesFromBase", defaultValue: "No changes from %@"),
                baseRef
            )
        }
        return String(localized: "changes.empty.noChanges", defaultValue: "No changes")
    }
}

// MARK: - Header (branch context + U5 slot)

private struct GitChangesHeaderView: View {
    let branch: String?
    let baseRef: String?

    var body: some View {
        if branch != nil || baseRef != nil {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                if let branch {
                    Text(verbatim: branch)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let baseRef {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Text(verbatim: baseRef)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Totals line

private struct GitChangesTotalsView: View {
    let fileCount: Int
    let totalAddedLines: Int
    let totalDeletedLines: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(GitChangesPanelFormatting.totalsFilesText(count: fileCount))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            if totalAddedLines > 0 {
                Text(verbatim: "+\(totalAddedLines)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(Color(nsColor: .systemGreen))
            }
            if totalDeletedLines > 0 {
                Text(verbatim: "−\(totalDeletedLines)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(Color(nsColor: .systemRed))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

/// One changed-file row. Value snapshot + closure bundle only; `Equatable`
/// on the file so unrelated snapshot publishes don't re-evaluate row bodies
/// (snapshot-boundary rule, see CLAUDE.md and `SessionIndexView.swift`).
private struct GitChangesFileRow: View, Equatable {
    let file: GitChangedFile
    let actions: GitChangesRowActions

    @State private var isHovered = false

    static func == (lhs: GitChangesFileRow, rhs: GitChangesFileRow) -> Bool {
        lhs.file == rhs.file
    }

    var body: some View {
        Button {
            actions.onOpenFile(file)
        } label: {
            HStack(spacing: 6) {
                Text(GitChangesPanelFormatting.displayName(for: file))
                    .font(.system(size: 11.5))
                    .foregroundColor(file.status.changesRowColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                let directory = GitChangesPanelFormatting.directoryText(for: file)
                if !directory.isEmpty {
                    Text(verbatim: directory)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                trailingCounts
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? primaryHoverColor : Color.clear)
        .onHover { isHovered = $0 }
        .safeHelp(GitChangesPanelFormatting.fullPathTooltip(for: file))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GitChangesPanelFormatting.accessibilityLabel(for: file))
    }

    private var primaryHoverColor: Color {
        Color.primary.opacity(0.06)
    }

    @ViewBuilder
    private var trailingCounts: some View {
        if file.status == .submodule {
            Text(String(localized: "changes.row.submodule", defaultValue: "submodule"))
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        } else if file.isBinary {
            Text(String(localized: "changes.row.binary", defaultValue: "binary"))
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        } else if let added = file.addedLines, let deleted = file.deletedLines {
            HStack(spacing: 4) {
                Text(verbatim: "+\(added)")
                    .foregroundColor(Color(nsColor: .systemGreen))
                Text(verbatim: "−\(deleted)")
                    .foregroundColor(Color(nsColor: .systemRed))
            }
            .font(.system(size: 10.5).monospacedDigit())
        }
    }
}

// MARK: - Message states

private struct GitChangesMessageView: View {
    let message: String
    var retryTitle: String?
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let retryTitle, let onRetry {
                Button(retryTitle, action: onRetry)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
